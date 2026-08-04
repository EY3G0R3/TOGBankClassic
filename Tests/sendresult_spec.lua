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
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, text, dist, target, prio, cb)
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
		local result = TOGBankClassic_Core:SendCommMessage("togbank-rm", "x", "Guild", nil, "ALERT")
		assert.is_nil(result,
			"SendCommMessage must return nothing; a call site reading its return value is " ..
			"reading a value that has never existed (audit ACQ-004)")
		assert.equal(1, #sent.calls)
	end)
end)

describe("Guild send-result handling", function()
	local Guild, sent

	before_each(function()
		env.reset()
		env.stubOutput()
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/Guild.lua")
		Guild = TOGBankClassic_Guild
		sent = captureSend()
		TOGBankClassic_Options = { IsSyncProgressMuted = function() return true end }
		TOGBankClassic_P2PSession = { ReleaseSendSlot = function() end }
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

	it("no longer reports a throttled counter it cannot increment", function()
		local src = io.open("Modules/Guild.lua", "rb"):read("*a")
		local body = src:match("local function CreateOnChunkSentCallback.-\nend\n")
		assert.falsy(body:find("sendStats.throttled", 1, true),
			"the throttled counter was only reachable through the deleted enum comparison, so " ..
			"it printed a permanent 0 that read as 'no throttling occurred' (audit ACQ-004)")
	end)
end)

describe("RequestLog mutation broadcast", function()
	local sent

	before_each(function()
		env.reset()
		env.stubOutput()
		env.loadFile("Modules/Constants.lua")
		sent = captureSend()
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

	it("releases the guard on refusal as well as on completion", function()
		local src = io.open("Modules/Events.lua", "rb"):read("*a")
		local body = src:match("function TOGBankClassic_Events:SyncDeltaVersion.-\nend")
		assert.is_not_nil(body)
		assert.truthy(body:find("sendResult == false", 1, true),
			"a refused broadcast must still release hashBroadcastInProgress, or the guard " ..
			"blocks every later broadcast for the rest of the session (audit ACQ-004)")
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
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_BCC.toc" }) do
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
