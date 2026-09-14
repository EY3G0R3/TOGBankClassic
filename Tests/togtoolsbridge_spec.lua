-- LOGAPI-002: the bridge that pushes bank movements into TOGTools' Guild Bank Log.
--
-- The contract is TOGTools' (docs/DEPENDENCY_CONTRACTS.md §1, raised 2026-08-18, moved to the
-- inbox 2026-09-11): TOGBankClassic calls
-- `TOGTools.addon.logCategories["guildbank"]:InjectEntry(guildKey, entry)` for every bank movement;
-- entry fields kind/type/name/itemLink/count/amount/ts (absolute); returns (stored, reason) with
-- reason one of "stored" | "duplicate" | "disabled" | "no-guild-key" | "no-entry" | "no-db";
-- "disabled" is the user having switched the log off and must not be retried; the table is copied.
--
-- THE RECEIVER HERE IS A FAKE BUILT TO THAT CONTRACT, stated plainly: TOGTools is an addon with its
-- own SavedVariables and UI, not an embeddable library, so it is not loaded from the sibling install.
-- The fake records every call, returns exactly the documented codes, and copies the row -- what the
-- contract guarantees. What the fake cannot prove is that TOGTools' real InjectEntry behaves as
-- documented; that is TOGTools' own guildbanklog_spec's job, and the contract says it pins it.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local T = 1757000000
local GUILD = "Testguild"
local BANKER, OTHER, PEER = "Bankchar-Testrealm", "Otherbanker-Testrealm", "Otherguy-Testrealm"

local Log, Guild, fake

--- The documented receiver.
local function fakeTOGTools(opts)
	opts = opts or {}
	local log = { calls = {}, stored = {} }
	function log:InjectEntry(guildKey, caller)
		self.calls[#self.calls + 1] = { key = guildKey, row = caller }
		if not guildKey then return false, "no-guild-key" end
		if not caller then return false, "no-entry" end
		if opts.disabled then return false, "disabled" end
		local copy = {}
		for k, v in pairs(caller) do copy[k] = v end
		-- TOGTools' dedupe, as its reply of 2026-09-11 describes GuildBankLog.lua:1186-1193: the
		-- base tuple is type|itemSig|count|tab1|tab2|amount -- NOT ts, NOT name -- and with `occ`
		-- omitted the next ordinal for that tuple is assigned BEFORE the check, so an identical row
		-- re-injected without occ is stored as the first's successor.
		local base = table.concat({ tostring(copy.type), tostring(copy.itemLink), tostring(copy.count),
			tostring(copy.tab1), tostring(copy.tab2), tostring(copy.amount) }, "|")
		if copy.occ == nil then
			local high = 0
			for _, s in ipairs(self.stored) do
				if s.base == base and s.row.occ > high then high = s.row.occ end
			end
			copy.occ = high + 1
		end
		for _, s in ipairs(self.stored) do
			if s.base == base and s.row.occ == copy.occ then return false, "duplicate" end
		end
		self.stored[#self.stored + 1] = { base = base, row = copy }
		return true, "stored"
	end
	if opts.guildKey ~= false then
		function log:GetCurrentGuildKey() return opts.guildKey or "Testguild-Testrealm" end
	end
	_G.TOGTools = { addon = { logCategories = { guildbank = log } } }
	return log
end

local function client(who)
	env.standUpClient(who, {
		{ name = BANKER, note = "gbank" }, { name = OTHER, note = "gbank" }, { name = PEER },
	}, GUILD)
	Log, Guild = TOGBankClassic_Log, TOGBankClassic_Guild
	Log.buffers = {}
	Log.diffedThisSession = nil
	env.now = T
	TOGBankClassic_Core.SendCommMessage = function() end
	TOGBankClassic_Core.SendWhisper = function() return true end
	env.defineItem(14256, { name = "Felcloth" })
	env.defineItem(10132, { name = "Spiked Club" })
end

local Rec = function(id, n, suffix) return TOGBankClassic_Inventory_Record.new(id, n, suffix) end

describe("LOGAPI-002: the TOGTools bridge", function()
	before_each(function()
		env.reset(); client("Bankchar")
		fake = fakeTOGTools()
	end)
	after_each(function() _G.TOGTools = nil end)

	it("finds TOGTools' log only through the documented path, and nil without it", function()
		assert.equal(fake, Log:TOGToolsLog())
		_G.TOGTools = { }                                            -- the bare table, no .addon
		assert.is_nil(Log:TOGToolsLog())
		_G.TOGTools = { addon = { modules = { guildbank = fake } } } -- wrong registry
		assert.is_nil(Log:TOGToolsLog())
		_G.TOGTools = { addon = { logCategories = { guildbanklog = fake } } } -- wrong name
		assert.is_nil(Log:TOGToolsLog())
		_G.TOGTools = nil
		assert.is_nil(Log:TOGToolsLog())
	end)

	it("uses TOGTools' own guild key when it exposes one, else builds the same shape", function()
		assert.equal("Testguild-Testrealm", Log:TOGToolsGuildKey(fake))
		fake.GetCurrentGuildKey = nil
		assert.equal("Testguild-Testrealm", Log:TOGToolsGuildKey(fake), "the fallback must be GuildName-Realm")
		Guild.Info.name = nil
		assert.is_nil(Log:TOGToolsGuildKey(fake))
	end)

	it("maps a deposit and a withdraw to item rows, and the money types to money rows", function()
		local d = Log:ToTOGToolsRow({ type = "deposit", name = BANKER, item = "Felcloth", itemID = 14256, count = 20, ts = T })
		assert.equal("item", d.kind)
		assert.equal("deposit", d.type)
		assert.equal(BANKER, d.name)
		assert.equal(20, d.count)
		assert.equal(T, d.ts, "ts must be the absolute publish time, not an offset")
		assert.equal(T, d.occ, "occ must be the version's publish time -- identical on every client, different per version")
		assert.equal("TOGB", d.source, "the row is not tagged as an addon-bank movement (short: it is rendered on a log row)")
		assert.truthy(d.itemLink and d.itemLink:find("item:14256", 1, true), "no link for TOGTools to derive its itemSig from")
		local w = Log:ToTOGToolsRow({ type = "withdraw", name = BANKER, item = "Felcloth", itemID = 14256, count = 5, ts = T, to = PEER })
		assert.equal("withdraw", w.type)
		-- LOGAPI-004: the other party rides on the row. The operator, reading TOGTools: "the mail
		-- item didn't end up there either" -- it had, as this withdraw, with nobody named on it.
		assert.equal(PEER, w.to, "the requester a withdrawal was mailed to is not on the pushed row")
		assert.is_nil(w.from)
		assert.is_nil(d.to); assert.is_nil(d.from)
		local dep = Log:ToTOGToolsRow({ type = "deposit", name = BANKER, item = "Felcloth", itemID = 14256, count = 2, ts = T, from = PEER })
		assert.equal(PEER, dep.from, "the sender a deposit arrived from is not on the pushed row")
		local m = Log:ToTOGToolsRow({ type = "money-withdraw", name = BANKER, money = 12345, ts = T })
		assert.equal("money", m.kind)
		assert.equal("withdraw", m.type)
		assert.equal(12345, m.amount)
		assert.is_nil(m.itemLink)
		assert.equal(T, m.occ)
		assert.equal("TOGB", m.source)
		assert.equal("deposit", Log:ToTOGToolsRow({ type = "money-deposit", name = BANKER, money = 1, ts = T }).type)
	end)

	it("does not push request events as bank MOVEMENTS -- a mailed order is already the withdraw the next version records", function()
		for _, t in ipairs({ "requested", "mailed", "handed", "cancelled", "reopened" }) do
			assert.is_nil(Log:ToTOGToolsRow({ type = t, name = BANKER, to = PEER, item = "Felcloth", count = 1, ts = T }), t)
		end
		assert.is_nil(Log:ToTOGToolsRow(nil))
	end)

	-- LOGAPI-005. The operator, reading TOGTools' Guild Bank tab: "the requests aren't showing up in
	-- the togtools logs". Request events go as `kind = "request"` rows -- but ONLY once TOGTools
	-- declares it can take them; a row its reader does not know would be stored and never shown.
	it("pushes request events as kind=request rows only when TOGTools declares ACCEPTS_REQUEST_ROWS", function()
		local r = Log:ToTOGToolsRequestRow({ type = "mailed", name = BANKER, to = PEER, item = "Felcloth", itemID = 14256, count = 3, ts = T, requestId = "r7" })
		assert.equal("request", r.kind); assert.equal("mailed", r.type)
		assert.equal(BANKER, r.name); assert.equal(PEER, r.to); assert.equal(3, r.count); assert.equal("r7", r.requestId)
		assert.equal(T, r.ts); assert.equal(tostring(T) .. ":r7", r.occ, "two events on one request in one second must not dedupe to one")
		assert.equal("TOGB", r.source)
		assert.truthy(r.itemLink:find("item:14256", 1, true))
		assert.equal("no longer needed", Log:ToTOGToolsRequestRow({ type = "cancelled", name = BANKER, to = PEER, ts = T, requestId = "r7", note = "no longer needed" }).note)
		assert.is_nil(Log:ToTOGToolsRequestRow({ type = "deposit", name = BANKER, ts = T }), "a bank movement is not a request row")
		assert.is_nil(Log:ToTOGToolsRequestRow(nil))

		-- Through the real feed: without the flag the request never reaches TOGTools; with it, it does.
		env.reset(); client("Otherguy"); fake = fakeTOGTools()
		assert.is_false(Log:TOGToolsAcceptsRequests(fake))
		local ok = Guild:AddRequest({ date = T, requester = PEER, bank = BANKER, item = "Felcloth", itemID = 14256, quantity = 20, fulfilled = 0, notes = "" })
		assert.is_true(ok)
		env.advance(1)
		assert.equal(0, #fake.calls, "a request row reached a TOGTools that never said it could take one")
		fake.ACCEPTS_REQUEST_ROWS = true
		assert.is_true(Log:TOGToolsAcceptsRequests(fake))
		Guild:AddRequest({ date = T + 1, requester = PEER, bank = BANKER, item = "Felcloth", itemID = 14256, quantity = 5, fulfilled = 0, notes = "" })
		env.advance(1)
		assert.equal(1, #fake.calls)
		assert.equal("request", fake.calls[1].row.kind); assert.equal("requested", fake.calls[1].row.type)
		assert.equal(PEER, fake.calls[1].row.name); assert.equal(BANKER, fake.calls[1].row.to)
	end)

	it("keeps a random suffix in the link, so TOGTools' itemSig tells the variants apart", function()
		local link = Log:ItemLinkFor(10132, 863, "Spiked Club of the Wolf")
		assert.truthy(link:find("item:10132:0:0:0:0:0:863:", 1, true), link)
		assert.truthy(link:find("[Spiked Club of the Wolf]", 1, true))
		local plain = Log:ItemLinkFor(14256, 0, "Felcloth")
		assert.truthy(plain:find("item:14256", 1, true))
		assert.is_nil(Log:ItemLinkFor(nil))
	end)

	it("pushes a delivered batch into TOGTools under the guild key, item and money alike", function()
		local stored, why = Log:PushToTOGTools({
			{ type = "deposit", name = BANKER, item = "Felcloth", itemID = 14256, count = 20, ts = T },
			{ type = "money-deposit", name = BANKER, money = 500, ts = T },
			{ type = "requested", name = PEER, to = BANKER, item = "Felcloth", count = 1, ts = T },
		})
		assert.equal(2, stored)
		assert.equal("done", why)
		assert.equal(2, #fake.calls)
		assert.equal("Testguild-Testrealm", fake.calls[1].key)
		assert.equal("item", fake.stored[1].row.kind)
		assert.equal("money", fake.stored[2].row.kind)
	end)

	it("injects the identical row ONCE per account: the viewer's copy of the banker's row is a duplicate, a later version is not", function()
		-- TOGTools' correction on the contract thread: without occ, an identical row re-injected
		-- would be stored as the next ordinal. With occ = the version's publish time it is not.
		local row = { type = "deposit", name = BANKER, item = "Felcloth", itemID = 14256, count = 20, ts = T + 60 }
		assert.same({ 1, "done" }, { Log:PushToTOGTools({ row }) })
		assert.same({ 0, "done" }, { Log:PushToTOGTools({ row }) }, "the same row again was stored a second time")
		assert.equal(1, #fake.stored)
		-- Same item, same count, a LATER version: a genuine second deposit, stored.
		local later = { type = "deposit", name = BANKER, item = "Felcloth", itemID = 14256, count = 20, ts = T + 600 }
		assert.same({ 1, "done" }, { Log:PushToTOGTools({ later }) })
		assert.equal(2, #fake.stored)
	end)

	it("treats 'disabled' as 'do not offer this now': stops the batch, no error, no retry", function()
		fake = fakeTOGTools({ disabled = true })
		local stored, why = Log:PushToTOGTools({
			{ type = "deposit", name = BANKER, item = "Felcloth", itemID = 14256, count = 20, ts = T },
			{ type = "withdraw", name = BANKER, item = "Felcloth", itemID = 14256, count = 2, ts = T },
		})
		assert.equal(0, stored)
		assert.equal("disabled", why)
		assert.equal(1, #fake.calls, "kept pushing after the user switched the log off")
	end)

	it("reports absence and a missing guild key without calling anything", function()
		_G.TOGTools = nil
		assert.same({ 0, "absent" }, { Log:PushToTOGTools({ { type = "deposit", name = BANKER, itemID = 14256, count = 1, ts = T } }) })
		fake = fakeTOGTools({ guildKey = false })
		Guild.Info.name = nil
		assert.same({ 0, "no-guild-key" }, { Log:PushToTOGTools({ { type = "deposit", name = BANKER, itemID = 14256, count = 1, ts = T } }) })
		assert.equal(0, #fake.calls)
	end)

	it("is driven by the real feed: a banker's rescan lands in TOGTools after the coalescing timer", function()
		-- The first version held records nothing (no before); the second is the diff.
		Log:RecordInventoryChange(BANKER, { Rec(14256, 5) }, { Rec(14256, 25) }, 0, 300, T + 60, "c1", "c2")
		assert.equal(0, #fake.calls, "delivery is coalesced through a timer, not immediate")
		env.advance(1)
		assert.equal(2, #fake.stored, "one deposit and one money row expected")
		assert.equal(20, fake.stored[1].row.count)
		assert.equal(T + 60, fake.stored[1].row.ts)
		assert.equal(300, fake.stored[2].row.amount)
	end)

	it("cannot take the other consumers down when TOGTools raises", function()
		fake.InjectEntry = function() error("boom") end
		local got
		Log:RegisterCallback("spec", function(entries) got = #entries end)
		_G.geterrorhandler = function() return function() end end
		Log:RecordInventoryChange(BANKER, { Rec(14256, 5) }, { Rec(14256, 6) }, 0, 0, T + 60, "c1", "c2")
		env.advance(1)
		assert.equal(1, got, "the registered consumer did not get its batch")
	end)

	it("declares TOGTools as an OPTIONAL dependency in both TOCs, never a required one", function()
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_BCC.toc" }) do
			local src = env.readFile(toc)
			local opt = src:match("## OptionalDeps:([^\n]*)")
			assert.truthy(opt and opt:find("TOGTools", 1, true), toc .. " does not list TOGTools under OptionalDeps")
			local req = src:match("## Dependencies:([^\n]*)")
			assert.is_falsy(req and req:find("TOGTools", 1, true), toc .. " makes TOGTools REQUIRED")
		end
	end)
end)
