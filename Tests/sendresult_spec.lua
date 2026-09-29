-- ACQ-004 — how this addon reads the send verdict.
--
-- AceCommQueue-1.0 MINOR 5+ reports delivery in the callback's 4th argument, and only there:
--
--     true  = delivered (covers the WHOLE multipart message, not just its last chunk)
--     false = refused, after the library's own retry/backoff gave up
--     nil   = not attempted (our in-raid guard reports 0/0/nil to unblock the queue)
--
-- Every defect below was raised by the library owner after reading these call sites, and every
-- one was verified in the source before being fixed. They share a shape: the send fails, the
-- addon believes it succeeded, and nothing anywhere says otherwise. That is invisible to code
-- review and to in-game testing, so it is pinned here.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

--- Capture the callback a module hands to SendCommMessage, so a spec can drive it with a
--- verdict and observe what the addon does. Returns a table with `.cb` once a send happens.
local function captureSend()
	local sent = { calls = {} }
	TOGBankClassic_Core = TOGBankClassic_Core or {}
	TOGBankClassic_Core.SerializeWithChecksum = function(_, t) return "ser:" .. tostring(t and t.type) end
	-- Only prefix, prio and the callback are observed; the middle arguments are named `_` rather
	-- than kept for documentation, so an unused-argument warning stays a real signal in this file.
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, _, _, _, prio, cb)
		sent.calls[#sent.calls + 1] = { prefix = prefix, prio = prio }
		sent.cb = cb
		return nil   -- faithful: neither AceComm nor AceCommQueue returns anything
	end
	return sent
end

describe("SendCommMessage return value", function()
	before_each(function() env.reset() end)

	-- The bug at RequestLog.lua:1070 was reading this as if it meant something.
	it("is nil — the verdict never arrives as a return value", function()
		local sent = captureSend()
		local result = TOGBankClassic_Core:SendCommMessage("togbank-rm", "x", "GUILD", nil, "ALERT")
		assert.is_nil(result,
			"SendCommMessage must return nothing; a call site reading its return value is " ..
			"reading a value that has never existed (audit ACQ-004)")
		assert.equal(1, #sent.calls)
	end)
end)

describe("Guild send-result handling", function()
	-- No locals for the module or the capture: every guard in this block reads Guild.lua's SOURCE,
	-- because CreateOnChunkSentCallback is a `local function` no spec can invoke. The loads and the
	-- stubs still run, so the file is exercised rather than merely read.
	before_each(function()
		env.reset()
		env.stubOutput()
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/Guild.lua")
		captureSend()
		TOGBankClassic_Options = { IsSyncProgressMuted = function() return true end }
	end)

	-- The enum comparison could never match a boolean, so the throttled counter was frozen at
	-- zero while still being printed — a statistic that read as "no throttling" but measured
	-- nothing. It is gone; this asserts it does not come back.
	it("no longer compares the verdict against a SendAddonMessageResult enum", function()
		local src = io.open("Modules/Guild.lua", "rb"):read("*a")
		assert.falsy(src:find("SEND_RESULT.AddonMessageThrottle", 1, true),
			"an enum comparison against argument 4 has returned; argument 4 is a boolean and " ..
			"can never equal an enum member (audit ACQ-004)")
	end)

	-- `nil` means "not attempted" — our in-raid guard reports (0, 0, nil) to unblock the queue.
	-- Counting that as a failure would make every suppressed send look like a delivery error,
	-- which is how a real refusal gets lost in the noise.
	it("treats only false as a refusal, not nil", function()
		local src = io.open("Modules/Guild.lua", "rb"):read("*a")
		local body = src:match("local function CreateOnChunkSentCallback.-\nend\n")
		assert.is_not_nil(body, "could not find CreateOnChunkSentCallback")
		assert.truthy(body:find("sendResult == false", 1, true),
			"the send callback must test for `false` explicitly (audit ACQ-004)")
		assert.falsy(body:find("sendResult == nil", 1, true),
			"`nil` is 'not attempted', not a failure — counting it would flag every in-raid " ..
			"suppressed send as a delivery error (audit ACQ-004)")
	end)

	-- FINDING 28 pinned "releases the send slot at most once per send" here -- the completion path's
	-- once-per-send guard on ReleaseSendSlot. LIBREQ-DS-008: this callback no longer releases a
	-- slot at all -- its one caller is the manual GUILD share, which takes none; a whispered reply's
	-- slot is released by Inventory/Sync on the host's own per-send completion (DS-009), where the
	-- library's `ctx.completed` is the once-per-send guard. So the assertion inverts: a slot release
	-- reappearing in this callback would be a release for a slot never taken.
	it("releases no send slot -- the GUILD share takes none, and a reply's is Inventory/Sync's", function()
		local src = io.open("Modules/Guild.lua", "rb"):read("*a")
		local body = src:match("local function CreateOnChunkSentCallback.-\nend\n")
		assert.is_not_nil(body, "could not find CreateOnChunkSentCallback")
		assert.falsy(body:find("ReleaseSendSlot", 1, true),
			"the GUILD share's completion callback releases a P2P send slot it never acquired " ..
			"(LIBREQ-DS-008: the library's slots are taken on accept and released by Inventory/Sync)")
	end)

	it("no longer reports a throttled counter it cannot increment", function()
		local src = io.open("Modules/Guild.lua", "rb"):read("*a")
		local body = src:match("local function CreateOnChunkSentCallback.-\nend\n")
		assert.falsy(body:find("sendStats.throttled", 1, true),
			"the throttled counter was only reachable through the deleted enum comparison, so " ..
			"it printed a permanent 0 that read as 'no throttling occurred' (audit ACQ-004)")
	end)
end)

describe("RequestLog mutation broadcast", function()
	-- Same shape as the block above: the assertion reads RequestLog.lua's source, so the capture is
	-- installed for its stubbing side effect and its handle is never needed.
	before_each(function()
		env.reset()
		env.stubOutput()
		env.loadFile("Modules/Constants.lua")
		captureSend()
	end)

	-- togbank-rm carries request-state mutations at ALERT priority. A silent refusal here means
	-- other members' request lists diverge from ours permanently, with nothing in any log.
	it("passes a callback so a refusal can be detected at all", function()
		local src = io.open("Modules/RequestLog.lua", "rb"):read("*a")
		local call = src:match('SendCommMessage%("togbank%-rm".-%)')
		assert.is_not_nil(call, "could not find the togbank-rm send")
		assert.falsy(src:find("local sendResult = TOGBankClassic_Core:SendCommMessage", 1, true),
			"the togbank-rm send is still reading SendCommMessage's return value, which is " ..
			"always nil (audit ACQ-004)")
		assert.truthy(src:find("BroadcastRequestMutation REFUSED", 1, true),
			"the togbank-rm send has no refusal path; a refused request mutation would be lost " ..
			"silently (audit ACQ-004)")
	end)
end)

describe("collision-guard release", function()
	before_each(function() env.reset() end)

	-- DOC-001: both sites released the guard on the FIRST chunk while their comment claimed
	-- "once the final chunk is confirmed sent by CTL". With a real verdict available, the
	-- comment can now be true — but only if the callback actually accepts the arguments.
	it("both hash-list sends accept the callback arguments", function()
		for _, path in ipairs({ "Modules/Events.lua", "Modules/Guild.lua" }) do
			local src = io.open(path, "rb"):read("*a")
			assert.falsy(src:find('"togbank%-hl", data, "GUILD", nil, [^,]+, function%(%)'),
				path .. " still passes an argument-ignoring callback to a togbank-hl send. " ..
				"Supplying a callback tells AceCommQueue the caller handles the verdict, so " ..
				"the library will NOT report the refusal on our behalf (audit ACQ-004)")
		end
	end)

	-- LIBREQ-DS-008: the broadcast is the library's (p2p:Broadcast on the host's OFFER prefix) and
	-- the guard is released by the host's onSendComplete (Core.lua -> Events:OnBroadcastComplete)
	-- on the send's terminal verdict -- delivered, refused, or never attempted -- so this is driven
	-- through the real host with the transport's verdict, rather than read off the source.
	it("releases the guard on refusal and on a suppressed send as well as on completion, and holds it while the send is in flight", function()
		env.standUpClient("Bankchar", { { name = "Bankchar-Testrealm", note = "gbank" } }, "Testguild")
		local host = TOGBankClassic_Core:DeltaHost()
		local pending
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, text, _, _, _, cb, arg)
			if prefix == host.prefixes.OFFER then pending = { cb = cb, arg = arg, bytes = #text } end
		end
		local Events = TOGBankClassic_Events
		local function broadcast()
			pending = nil
			Events.hashBroadcastInProgress = false
			Events:SyncDeltaVersion("NORMAL")
			assert.is_table(pending, "no broadcast reached the transport")
			assert.is_true(Events.hashBroadcastInProgress, "the guard was not set for a send in flight")
		end
		-- Delivered.
		broadcast()
		pending.cb(pending.arg, pending.bytes, pending.bytes, true)
		assert.is_false(Events.hashBroadcastInProgress, "delivery did not release the guard")
		-- Refused by the client.
		broadcast()
		pending.cb(pending.arg, 0, pending.bytes, false, "rejected")
		assert.is_false(Events.hashBroadcastInProgress,
			"a refused broadcast did not release hashBroadcastInProgress -- the guard blocks every later broadcast for the rest of the session (audit ACQ-004)")
		-- Never attempted (Core's raid guard reports (0, 0, nil, "suppressed")).
		broadcast()
		pending.cb(pending.arg, 0, 0, nil, "suppressed")
		assert.is_false(Events.hashBroadcastInProgress, "a suppressed broadcast did not release the guard")
	end)
end)

describe("de-vendored AceCommQueue", function()
	before_each(function() env.reset() end)

	local function read(p)
		local fh = io.open(p, "rb"); if not fh then return "" end
		local s = fh:read("*a"); fh:close(); return s
	end

	-- The vendored copy had drifted to MINOR 2 while the standalone reached 5 — and MINOR 5 is
	-- where the whole-message verdict and the retry/backoff arrived. Trusting argument 4 while
	-- shipping MINOR 2 would be trusting a signal that copy does not send.
	it("is declared in both TOCs rather than vendored", function()
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_TBC.toc", "TOGBankClassic_Mists.toc", "TOGBankClassic_Camelot.toc" }) do
			local src = read(toc)
			assert.truthy(src:match("## Dependencies:[^\n]*AceCommQueue%-1%.0"),
				toc .. " does not declare AceCommQueue-1.0 as a dependency")
			assert.falsy(src:find("Libs/AceCommQueue", 1, true),
				toc .. " still loads a vendored AceCommQueue copy")
		end
	end)

	it("is listed in .pkgmeta so CurseForge installs it", function()
		assert.truthy(read(".pkgmeta"):find("acecommqueue", 1, true),
			".pkgmeta must list the slug 'acecommqueue' under required-dependencies")
	end)
end)

-- LIBDBICON-DEP-001 (TOGTools contract 1eab38f9, 2026-09-25): an embedded LibDBIcon only updates
-- for players of the addon that shipped it, so it is a required dependency instead. LibDataBroker
-- stays bundled on the operator's word ("change it to not get rid of libdatabroker").
describe("de-vendored LibDBIcon-1.0", function()
	before_each(function() env.reset() end)

	local function read(p)
		local fh = io.open(p, "rb"); if not fh then return "" end
		local s = fh:read("*a"); fh:close(); return s
	end

	-- The WoW Forever TOC is the one exception (FOREVER-001, pinned in wiring_spec.lua): LibDBIcon-1.0
	-- is not published for Forever, so that TOC embeds it until it is.
	it("is declared in both TOCs rather than vendored, and LibDataBroker is still bundled", function()
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_TBC.toc", "TOGBankClassic_Mists.toc" }) do
			local src = read(toc)
			assert.truthy(src:match("## Dependencies:[^\n]*LibDBIcon%-1%.0"),
				toc .. " does not declare LibDBIcon-1.0 as a dependency")
			assert.falsy(src:find("Libs/LibDBIcon", 1, true),
				toc .. " still loads a vendored LibDBIcon copy")
			assert.truthy(src:find("Libs/LibDataBroker-1.1/LibDataBroker-1.1.lua", 1, true),
				toc .. " no longer loads the bundled LibDataBroker-1.1")
		end
	end)

	it("is listed in .pkgmeta so CurseForge installs it", function()
		assert.truthy(read(".pkgmeta"):find("  - libdbicon-1-0\n", 1, true)
			or read(".pkgmeta"):find("  - libdbicon-1-0\r\n", 1, true),
			".pkgmeta must list the slug 'libdbicon-1-0' under required-dependencies")
	end)
end)
