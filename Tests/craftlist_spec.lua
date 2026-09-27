-- GSL-MERGE-001 build step 2 (v1.7.0): the shopping list's MODEL, Modules/CraftList.lua, and the
-- settings rail it rides (docs/GSL_MERGE.md D1-D4, D2 as the operator ruled it on 2026-09-25).
--
-- The REAL Guild (roster built by the real LibGuildRoster, its own SenderIsOfficer / SenderIsGM),
-- the real Chat dispatch and Core envelope, the send captured -- the shape settings_spec uses, so a
-- list payload is judged by the same receiving code every other setting is. The recipe data is the
-- REAL LibProfessionDB-1.0 with its own shipped Vanilla Alchemy files: Elixir of Fortitude
-- (Alchemy 171, recipe 3450) makes item 3825 from one each of 3355, 3372 and 3821
-- (ProfessionDB/Data/Vanilla/_core/Alchemy.lua).
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")
local wow = require("env.wow")

local GM, OFFICER, GSL, MEMBER, BANKER = "Gm-Testrealm", "Officer-Testrealm", "Gslplayer-Testrealm", "Member-Testrealm", "Banker-Testrealm"
local ALCHEMY, FORTITUDE, FORTITUDE_ITEM = 171, 3450, 3825
local STEELBLOOM, VIAL, GOLDTHORN = 3355, 3372, 3821
local TURNIN = 10457   -- a plain wanted item (GSL's Miscellaneous bucket), not a recipe

local Guild, CL, sent, me

local function loadProfessionDB()
	local libs = require("env.libs")
	libs.forget("LibProfessionDB-1.0")
	libs.load("LibProfessionDB-1.0")
	for _, part in ipairs({ "_core", "enUS" }) do
		local chunk = assert(loadfile(libs.pathOf("LibProfessionDB-1.0", "Data/Vanilla/" .. part .. "/Alchemy.lua")))
		chunk("ProfessionDB", {})
	end
	assert(LibStub("LibProfessionDB-1.0"):GetRecipe(ALCHEMY, FORTITUDE), "the shipped Alchemy data did not load")
end

local function loadWire()
	env.stubOutput()
	require("env.ace").load("AceAddon-3.0", "AceComm-3.0", "AceConsole-3.0",
		"AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
	env.loadDeltaSync()
	loadProfessionDB()
	env.loadModules({
		"Modules/Constants.lua", "Modules/Switches.lua", "Modules/Item.lua",
		"Modules/Inventory/Record.lua", "Modules/Inventory/Resolve.lua", "Modules/Inventory/Store.lua",
		"Modules/Inventory/Scan.lua", "Modules/Inventory/Wire.lua", "Modules/DeltaComms.lua",
		"Modules/Guild.lua", "Modules/RequestLog.lua", "Modules/Donations.lua", "Modules/CraftList.lua", "Modules/Chat.lua",
	})
	local AceAddon = LibStub("AceAddon-3.0")
	if AceAddon and AceAddon.addons then
		AceAddon.addons["TOGBankClassic"] = nil
		if AceAddon.addonstatus then AceAddon.addonstatus["TOGBankClassic"] = nil end
	end
	env.loadFile("Core.lua")
	env.now = 1757000000
	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	TOGBankClassic_Database = { db = { global = { switches = {} }, faction = {} }, RecordDeltaReceived = function() end, RecordNoChangeSent = function() end }
	TOGBankClassic_Options = {
		IsIntegrityCheckDiagnosticsEnabled = function() return false end, IsSyncProgressMuted = function() return true end,
		GetBankEnabled = function() return true end, GetAutoTombstoneDays = function() return 30 end,
		GetMaxRequestPercent = function() return 100 end, GetBankReporting = function() return false end,
		IsOrderFulfillmentSoundEnabled = function() return false end,
	}
	TOGBankClassic_Performance = { RecordOperation = function() end }
	Guild, CL = TOGBankClassic_Guild, TOGBankClassic_CraftList
	Guild.Info = { name = "Testguild", alts = {}, roster = { alts = {} }, requests = {}, requestsTombstones = {}, settings = { shopEnabled = true } }
	Guild.memberRoster, Guild.onlineMembers, Guild.banksCache, Guild.lastSettingsPayload = {}, {}, nil, nil
	Guild.GetNormalizedPlayer = function() return me end
	Guild.GetPlayer = function() return me end
	TOGBankClassic_Chat.hashBroadcastQueue = {}
	sent = {}
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, body, dist, target, prio, cb, cbArg)
		sent[#sent + 1] = { prefix = prefix, body = body, dist = dist, target = target, prio = prio }
		if cb then cb(cbArg, #tostring(body), #tostring(body), true) end
	end
	_G.LibGuildRosterDB = nil
	local lib = env.freshGuildRoster()
	env.readyGuildRoster(lib)
	Guild:RefreshOnlineCache()
end

local function roster()
	env.reset()
	env.addGuildMember(GM, { rankIndex = 0, online = true })
	env.addGuildMember(OFFICER, { rankIndex = 1, online = true })
	env.addGuildMember(GSL, { rankIndex = 4, online = true, note = "shopping [GSL] alt" })
	env.addGuildMember(MEMBER, { rankIndex = 4, online = true, note = "GSL fan, no tag" })
	env.addGuildMember(BANKER, { rankIndex = 4, online = true, note = "gbank herbs" })
	_G.CanViewOfficerNote = function() return me == GM or me == OFFICER end
end

--- The guild-settings payloads captured, decoded, oldest first.
local function settingsSent()
	local out = {}
	for _, msg in ipairs(sent) do
		if msg.prefix == "togbank-hl" then
			local ok, decoded = TOGBankClassic_Core:DeserializeWithChecksum(msg.body, { sender = me, prefix = msg.prefix })
			assert.is_true(ok)
			if decoded.type == "guild-settings" then out[#out + 1] = decoded.settings end
		end
	end
	return out
end

--- A guild-settings broadcast as `from` would send it.
local function hear(from, settings)
	TOGBankClassic_Chat:OnCommReceived("togbank-hl", TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = settings }), "GUILD", from)
end

local RKEY = "r" .. ALCHEMY .. ":" .. FORTITUDE
local IKEY = "i" .. TURNIN

describe("GSL-MERGE-001: who may write the shopping list", function()
	before_each(function() me = MEMBER; roster(); loadWire() end)

	it("the GM, an officer (once the GM's floor is heard) and the [GSL]-tagged member may; a plain member and a stranger may not", function()
		assert.is_true(CL:CanEdit(GM))
		assert.is_true(CL:CanEdit(GSL))
		assert.is_true(CL:IsGSLPlayer(GSL))
		assert.is_false(CL:IsGSLPlayer(MEMBER), "a note mentioning GSL without the tag counted")
		assert.is_false(CL:CanEdit(MEMBER))
		assert.is_false(CL:CanEdit("Stranger-Otherrealm"))
		assert.is_false(CL:CanEdit(nil))
		assert.is_false(CL:CanEdit(OFFICER), "the officer counted before the GM published a floor")
		hear(GM, { version = env.now, officerRankFloor = 1, stamps = { officerRankFloor = env.now } })
		assert.is_true(CL:CanEdit(OFFICER))
	end)

	it("a plain member's write is refused and nothing is sent", function()
		assert.is_false(CL:SetRecipe(ALCHEMY, FORTITUDE, 10))
		assert.is_false(CL:SetItem(TURNIN, 5))
		assert.is_false(CL:SetGatherWindow("2026-10-01", "2026-10-08"))
		assert.same({}, CL:GetList())
		assert.equal(0, #settingsSent())
	end)
end)

describe("GSL-MERGE-001: writing the list", function()
	before_each(function() me = GM; roster(); loadWire() end)

	it("SetRecipe / SetItem store the entry, stamp it, and publish it on the settings rail at ALERT", function()
		assert.is_true(CL:SetRecipe(ALCHEMY, FORTITUDE, 10))
		assert.is_true(CL:SetItem(TURNIN, 5))
		assert.same({ [RKEY] = { p = ALCHEMY, r = FORTITUDE, n = 10 }, [IKEY] = { i = TURNIN, n = 5 } }, CL:GetList())
		local payloads = settingsSent()
		assert.equal(2, #payloads)
		assert.equal("ALERT", sent[#sent].prio)
		local last = payloads[2]
		assert.same(CL:GetList(), last.craftList)
		assert.is_number(last.craftListStamps[RKEY]); assert.is_number(last.craftListStamps[IKEY])
		assert.is_true(last.craftListStamps[RKEY] >= env.now)
	end)

	it("changing a count re-stamps above the old stamp; the same count again is no write; 0 removes and keeps a stamp", function()
		CL:SetRecipe(ALCHEMY, FORTITUDE, 10)
		local s = Guild.Info.settings
		local first = s.craftListStamps[RKEY]
		assert.is_false(CL:SetRecipe(ALCHEMY, FORTITUDE, 10), "an unchanged count was a write")
		assert.is_true(CL:SetRecipe(ALCHEMY, FORTITUDE, 20))
		assert.is_true(s.craftListStamps[RKEY] > first)
		assert.equal(20, CL:GetList()[RKEY].n)
		local before = s.craftListStamps[RKEY]
		assert.is_true(CL:Remove(RKEY))
		assert.is_nil(CL:GetList()[RKEY])
		assert.is_true(s.craftListStamps[RKEY] > before, "the removal kept no newer stamp")
		assert.is_false(CL:Remove(RKEY), "removing an absent entry was a write")
	end)

	it("refuses a recipe the library does not carry, a bad id, and clamps a huge count", function()
		assert.is_false(CL:SetRecipe(ALCHEMY, 999999, 3))
		assert.is_false(CL:SetRecipe("x", FORTITUDE, 3))
		assert.is_false(CL:SetItem(-4, 3))
		assert.is_true(CL:SetItem(TURNIN, 123456))
		assert.equal(CL.MAX_COUNT, CL:GetList()[IKEY].n)
	end)

	it("stops at MAX_ENTRIES new entries, and still lets an existing one change", function()
		local saved = CL.MAX_ENTRIES
		CL.MAX_ENTRIES = 2
		local ok, err = pcall(function()
			assert.is_true(CL:SetItem(1001, 1))
			assert.is_true(CL:SetItem(1002, 1))
			assert.is_false(CL:SetItem(1003, 1), "a third entry went past the cap")
			assert.is_true(CL:SetItem(1002, 4))
		end)
		CL.MAX_ENTRIES = saved
		assert(ok, err)
	end)

	it("the gather window: two dates, end not before start, \"\" clears; a malformed date is refused", function()
		assert.is_true(CL:SetGatherWindow("2026-10-01", "2026-10-08"))
		assert.same({ "2026-10-01", "2026-10-08" }, { CL:GetGatherWindow() })
		assert.is_false(CL:SetGatherWindow("2026-10-01", "2026-10-08"), "an unchanged window was a write")
		assert.is_false(CL:SetGatherWindow("2026-10-09", "2026-10-08"))
		assert.is_false(CL:SetGatherWindow("10/01/2026", ""))
		assert.is_false(CL:SetGatherWindow("2026-13-01", ""))
		assert.is_true(CL:SetGatherWindow("", ""))
		assert.same({ "", "" }, { CL:GetGatherWindow() })
		local last = settingsSent()[#settingsSent()]
		assert.equal("", last.gatherStart); assert.equal("", last.gatherEnd)
	end)

	it("the [GSL]-tagged member's own client writes and publishes", function()
		me = GSL
		assert.is_true(CL:SetRecipe(ALCHEMY, FORTITUDE, 3))
		assert.equal(1, #settingsSent(), "a [GSL] member's write was not published")
		assert.same({ p = ALCHEMY, r = FORTITUDE, n = 3 }, settingsSent()[1].craftList[RKEY])
	end)

	-- The mixed-version cost this avoids: a v1.6.1 client's payload has no list fields, so a canon
	-- that hashed them would never match a v1.7.0 client's, and the pair would ask each other forever.
	it("leaves the settings canon unchanged, so a v1.6.1 client holding the same settings still matches", function()
		local before = Guild:SettingsCanon()
		CL:SetRecipe(ALCHEMY, FORTITUDE, 10)
		CL:SetGatherWindow("2026-10-01", "2026-10-08")
		assert.equal(before, Guild:SettingsCanon())
	end)
end)

describe("GSL-MERGE-001: receiving the list", function()
	before_each(function() me = MEMBER; roster(); loadWire() end)

	local function listPayload(entries, stamps, extra)
		local p = { version = env.now, craftList = entries, craftListStamps = stamps, stamps = {} }
		for k, v in pairs(extra or {}) do p[k] = v end
		return p
	end

	it("takes the GM's list entry by entry, and a newer stamp beats an older one per entry", function()
		hear(GM, listPayload({ [RKEY] = { p = ALCHEMY, r = FORTITUDE, n = 10 } }, { [RKEY] = env.now }))
		assert.equal(10, CL:GetList()[RKEY].n)
		-- Older for that entry: ignored. A different entry at the same time: added beside it.
		hear(GM, listPayload({ [RKEY] = { p = ALCHEMY, r = FORTITUDE, n = 99 }, [IKEY] = { i = TURNIN, n = 2 } },
			{ [RKEY] = env.now - 5, [IKEY] = env.now }))
		assert.equal(10, CL:GetList()[RKEY].n, "an older stamp overwrote the entry")
		assert.equal(2, CL:GetList()[IKEY].n)
	end)

	it("a stamped removal removes, and an older add cannot bring the entry back", function()
		hear(GM, listPayload({ [RKEY] = { p = ALCHEMY, r = FORTITUDE, n = 10 } }, { [RKEY] = env.now }))
		hear(GM, listPayload({}, { [RKEY] = env.now + 10 }))
		assert.is_nil(CL:GetList()[RKEY])
		hear(GM, listPayload({ [RKEY] = { p = ALCHEMY, r = FORTITUDE, n = 10 } }, { [RKEY] = env.now + 5 }))
		assert.is_nil(CL:GetList()[RKEY], "an older add resurrected a removed entry")
	end)

	it("takes ONLY the list from the [GSL] member: their other settings are ignored", function()
		assert.is_true(Guild:IsStoreOpen())
		hear(GSL, listPayload({ [IKEY] = { i = TURNIN, n = 7 } }, { [IKEY] = env.now },
			{ storeOpen = false, gatherStart = "2026-10-01", stamps = { storeOpen = env.now, gatherStart = env.now } }))
		assert.equal(7, CL:GetList()[IKEY].n)
		assert.equal("2026-10-01", (CL:GetGatherWindow()))
		assert.is_true(Guild:IsStoreOpen(), "a [GSL] member's payload closed the shop")
	end)

	it("ignores a plain member's list", function()
		hear(MEMBER, listPayload({ [IKEY] = { i = TURNIN, n = 7 } }, { [IKEY] = env.now }))
		assert.same({}, CL:GetList())
	end)

	it("keeps its list when a v1.6.1 client's payload (no list fields) is heard", function()
		hear(GM, listPayload({ [IKEY] = { i = TURNIN, n = 7 } }, { [IKEY] = env.now }))
		hear(GM, { version = env.now + 100, storeOpen = true, stamps = { storeOpen = env.now + 100 } })
		assert.equal(7, CL:GetList()[IKEY].n)
	end)

	-- SETTINGS-TIE-001 (Peer Review, F1): two clients holding different values at ONE stamp used to
	-- each take whichever payload arrived last and never agree. Each case runs as two clients: one
	-- holds A and hears B, the other holds B and hears A. They must end identical.
	local function bothOrders(field, a, b, from, extra)
		local S = env.now
		local function client(held, heard)
			Guild.Info.settings = { version = S, [field] = held, stamps = { [field] = S } }
			local p = { version = S, [field] = heard, stamps = { [field] = S } }
			for k, v in pairs(extra or {}) do p[k] = v end
			hear(from, p)
			return Guild.Info.settings[field]
		end
		local one, two = client(a, b), client(b, a)
		assert.equal(one, two, field .. ": the two clients disagree at an equal stamp")
		return one
	end

	it("an equal stamp picks the same winner in either order, from an officer's path and the [GSL] path alike", function()
		assert.equal(20, bothOrders("storeDiscountPercent", 10, 20, GM))
		assert.equal("2026-10-05", bothOrders("gatherStart", "2026-10-01", "2026-10-05", GSL))
		assert.equal("2026-10-05", bothOrders("gatherStart", "2026-10-05", "2026-10-01", GM))
	end)

	it("an entry held at the same stamp as the heard one settles on the greater count in either order; a removal counts as 0", function()
		local S = env.now
		local function client(held, heard)
			Guild.Info.settings = { craftList = held and { [IKEY] = { i = TURNIN, n = held } } or {}, craftListStamps = { [IKEY] = S } }
			hear(GM, listPayload(heard and { [IKEY] = { i = TURNIN, n = heard } } or {}, { [IKEY] = S }))
			local e = CL:GetList()[IKEY]
			return e and e.n or 0
		end
		assert.equal(client(3, 8), client(8, 3))
		assert.equal(8, client(3, 8))
		assert.equal(client(nil, 5), client(5, nil))
		assert.equal(5, client(nil, 5))
	end)

	it("a bank character's owner held at the same stamp as the heard one settles on one name in either order; a clear loses", function()
		local S = env.now
		local function client(held, heard)
			Guild.Info.settings = { bankerOwners = { [BANKER] = held }, bankerOwnerStamps = { [BANKER] = S } }
			hear(GM, { version = S, stamps = {}, bankerOwners = { [BANKER] = heard }, bankerOwnerStamps = { [BANKER] = S } })
			return Guild.Info.settings.bankerOwners[BANKER]
		end
		assert.equal(client("Alice", "Bob"), client("Bob", "Alice"))
		assert.equal("Bob", client("Alice", "Bob"))
		assert.equal(client(nil, "Carol"), client("Carol", nil))
		assert.equal("Carol", client(nil, "Carol"))
	end)

	it("an equal stamp still seeds a field this client has never held", function()
		Guild.Info.settings = { version = env.now, stamps = { storeDiscountPercent = env.now } }
		hear(GM, { version = env.now, storeDiscountPercent = 5, stamps = { storeDiscountPercent = env.now } })
		assert.equal(5, Guild.Info.settings.storeDiscountPercent)
	end)

	it("an older stamp still loses and a newer one still wins, whatever the values", function()
		Guild.Info.settings = { version = env.now, storeDiscountPercent = 10, stamps = { storeDiscountPercent = env.now } }
		hear(GM, { version = env.now, storeDiscountPercent = 90, stamps = { storeDiscountPercent = env.now - 1 } })
		assert.equal(10, Guild.Info.settings.storeDiscountPercent)
		hear(GM, { version = env.now + 1, storeDiscountPercent = 1, stamps = { storeDiscountPercent = env.now + 1 } })
		assert.equal(1, Guild.Info.settings.storeDiscountPercent)
	end)

	it("drops a malformed entry: a key that does not match its entry, a zero count, a mixed recipe/item", function()
		hear(GM, listPayload({
			[RKEY] = { p = ALCHEMY, r = FORTITUDE + 1, n = 1 },
			["i1"] = { i = 1, n = 0 },
			["i2"] = { i = 2, p = ALCHEMY, n = 1 },
			["i3"] = { i = 3, n = 4 },
		}, { [RKEY] = env.now, i1 = env.now, i2 = env.now, i3 = env.now }))
		assert.same({ i3 = { i = 3, n = 4 } }, CL:GetList())
	end)
end)

describe("GSL-MERGE-001: the reagent roll-up against the bank (D4)", function()
	before_each(function() me = GM; roster(); loadWire() end)

	local function stockBank(records)
		local Record, Store = TOGBankClassic_Inventory_Record, TOGBankClassic_Inventory_Store
		local recs = {}
		for id, n in pairs(records) do recs[#recs + 1] = Record.new(id, n) end
		Store:SetAltRecords("Testguild", BANKER, recs, env.now)
	end

	-- GSL-BANK-001 (the operator 2026-09-26: "the missing tab should be what the GSL banker is
	-- missing"): Missing is the need less what the [GSL] character holds; bank and bags are shown.
	-- This guild has no [GSL] character, so GSL is 0 and all of the need is missing.
	it("expands a recipe into its reagents, less finished items the bank already holds, and shows bank and bags", function()
		CL:SetRecipe(ALCHEMY, FORTITUDE, 10)
		stockBank({ [FORTITUDE_ITEM] = 2, [STEELBLOOM] = 5 })
		wow.bags[0] = { slots = 4, [1] = { itemID = GOLDTHORN, count = 1 } }
		local rows, unknown = CL:Demand()
		assert.same({}, unknown)
		local byId = {}
		for _, r in ipairs(rows) do byId[r.itemID] = r end
		-- 10 wanted, 2 already in the bank: 8 to make, one of each reagent apiece.
		assert.same({ itemID = STEELBLOOM, needed = 8, bank = 5, gsl = 0, you = 0, missing = 8 }, byId[STEELBLOOM])
		assert.same({ itemID = VIAL, needed = 8, bank = 0, gsl = 0, you = 0, missing = 8 }, byId[VIAL])
		assert.same({ itemID = GOLDTHORN, needed = 8, bank = 0, gsl = 0, you = 1, missing = 8 }, byId[GOLDTHORN])
		assert.equal(3, #rows)
	end)

	it("a recipe the bank already covers asks for nothing; a wanted item is its own demand", function()
		CL:SetRecipe(ALCHEMY, FORTITUDE, 2)
		CL:SetItem(TURNIN, 4)
		stockBank({ [FORTITUDE_ITEM] = 3, [TURNIN] = 1 })
		local rows = CL:Demand()
		assert.same({ { itemID = TURNIN, needed = 4, bank = 1, gsl = 0, you = 0, missing = 4 } }, rows)
	end)

	it("lists a recipe the installed library does not carry as unknown and demands nothing for it", function()
		me = MEMBER
		hear(GM, { version = env.now, craftList = { ["r171:999999"] = { p = 171, r = 999999, n = 5 } },
			craftListStamps = { ["r171:999999"] = env.now }, stamps = {} })
		local rows, unknown = CL:Demand()
		assert.same({}, rows)
		assert.same({ "r171:999999" }, unknown)
		local entries = CL:Entries()
		assert.equal(1, #entries)
		assert.is_false(entries[1].known)
		assert.equal("Recipe 999999", entries[1].name)
	end)

	it("counts only the HOME guild's bank characters", function()
		stockBank({ [TURNIN] = 6 })
		assert.equal(6, CL:BankHolds(TURNIN))
		Guild.IsHomeMember = function() return false end
		assert.equal(0, CL:BankHolds(TURNIN), "a bank character outside the home guild was counted")
	end)

	it("Entries names each row from the recipe library and, with no LibItemDB, the client's item cache, sorted by name", function()
		env.defineItem(TURNIN, { name = "Aaa Turn-in" })
		CL:SetRecipe(ALCHEMY, FORTITUDE, 1)
		CL:SetItem(TURNIN, 1)
		local entries = CL:Entries()
		assert.same({ "Aaa Turn-in", "Elixir of Fortitude" }, { entries[1].name, entries[2].name })
		assert.equal("recipe", entries[2].kind); assert.equal(FORTITUDE_ITEM, entries[2].itemID)
		assert.is_true(entries[2].known)
	end)
end)

-- GSL-MERGE-001 step 5 (D9): GuildShoppingList's saved list comes across once, by name, on the roster
-- refresh a writer's client runs anyway. Enchanting is loaded beside Alchemy for the effect spelling:
-- "Crusader" is the effect of Enchant Weapon - Crusader (333/20034), and "Health +5" the effect of
-- TWO recipes (7418, 7420), so it must map to neither (ProfessionDB/Data/Vanilla/enUS/Enchanting.lua).
describe("GSL-MERGE-001 step 5: bringing GuildShoppingList's list across (D9)", function()
	local CRUSADER = "r333:20034"

	local function loadEnchanting()
		local libs = require("env.libs")
		for _, part in ipairs({ "_core", "enUS" }) do
			assert(loadfile(libs.pathOf("LibProfessionDB-1.0", "Data/Vanilla/" .. part .. "/Enchanting.lua")))("ProfessionDB", {})
		end
		assert(LibStub("LibProfessionDB-1.0"):GetRecipe(333, 20034), "the shipped Enchanting data did not load")
	end

	--- What the player was told at `level`, formatted.
	local function told(level)
		local out = {}
		for _, c in ipairs(TOGBankClassic_Output.calls) do
			if c.level == level then out[#out + 1] = string.format(c[1], unpack(c, 2, c.n)) end
		end
		return out
	end

	before_each(function()
		me = GM; roster(); loadWire(); loadEnchanting()
		sent = {}
		_G.GuildShoppingList_SavedItems = {
			"Elixir of Fortitude x10", "elixir of fortitude x5", "Elixir of Fortitude (alchemy) x1",
			"Crusader (enchant) x2", "Health +5 x1", "Nightfall (axe) x3", "not an entry",
		}
		_G.GuildShoppingList_Config = { GatherStartDate = "2026-10-01", GatherEndDate = "2026-10-08" }
	end)
	after_each(function()
		_G.GuildShoppingList_SavedItems, _G.GuildShoppingList_Config = nil, nil
		-- The real library must not outlive the example that loaded it (SPEC-ORDER-001's class).
		require("env.libs").forget("LibItemDB-1.0")
		_G.LibItemDB_PriceDB = nil
	end)

	it("a writer's roster refresh brings it over by name, effect and stripped name, sums repeats, and names what matched nothing", function()
		Guild:RefreshOnlineCache()
		assert.same({ [RKEY] = { p = ALCHEMY, r = FORTITUDE, n = 16 }, [CRUSADER] = { p = 333, r = 20034, n = 2 } }, CL:GetList())
		assert.same({ "2026-10-01", "2026-10-08" }, { CL:GetGatherWindow() })
		local s = Guild.Info.settings
		assert.same({ [RKEY] = 1, [CRUSADER] = 1 }, s.craftListStamps, "the imported entries are not stamped older than any TOGBank edit")
		local out = settingsSent()
		assert.equal(1, #out, "the import was not published once")
		assert.same(s.craftList, out[1].craftList)
		local unmapped = { "Health +5", "Nightfall (axe)", "not an entry" }
		assert.same({ guild = "Testguild", at = env.now, imported = 2, unmapped = 3, unmappedNames = unmapped },
			TOGBankClassic_Database.db.global.gslImport, "the names left out were not kept")
		-- Response, which no setting mutes: the report is made once.
		assert.same({ "Brought 2 entries over from GuildShoppingList into the shopping list.",
			"3 GuildShoppingList entries matched no recipe or item and were left out: Health +5, Nightfall (axe), not an entry" }, told("Response"))
	end)

	-- Peer Review F1 on self-audit 13180dbf: the refresh can import before this client has heard the
	-- guild's list. The guild's own entries -- a count and a removal, both written in TOGBank -- must
	-- still win when they arrive, entry by entry.
	it("an import that raced the guild's own list loses to it: the guild's count and its removal both stand", function()
		Guild:RefreshOnlineCache()
		assert.equal(16, CL:GetList()[RKEY].n)
		hear(GSL, { version = env.now, stamps = {},
			craftList = { [CRUSADER] = { p = 333, r = 20034, n = 9 } },
			craftListStamps = { [CRUSADER] = env.now - 100, [RKEY] = env.now - 200 } })
		assert.same({ [CRUSADER] = { p = 333, r = 20034, n = 9 } }, CL:GetList(),
			"the import overrode the guild's own count or brought back an entry the guild had removed")
	end)

	it("happens once per account: a later refresh, or another guild's writer, brings nothing", function()
		Guild:RefreshOnlineCache()
		CL:Remove(CRUSADER)
		CL:Remove(RKEY)
		sent = {}
		Guild:RefreshOnlineCache()
		assert.same({}, CL:GetList(), "the import ran again over a list its writer had emptied")
		Guild.Info = { name = "Otherguild", alts = {}, roster = { alts = {} }, requests = {}, requestsTombstones = {}, settings = {} }
		Guild:RefreshOnlineCache()
		assert.same({}, CL:GetList(), "an account's one list was brought into a second guild")
		assert.equal(0, #settingsSent())
	end)

	it("a member who may not edit leaves it for a writer, and a guild that already has a list keeps it", function()
		me = MEMBER
		Guild:RefreshOnlineCache()
		assert.same({}, CL:GetList())
		assert.is_nil(TOGBankClassic_Database.db.global.gslImport, "a member's client used up the account's one import")
		-- A list removed down to nothing still has its stamps: the guild HAS a list, an empty one.
		me = GM
		Guild.Info.settings.craftList, Guild.Info.settings.craftListStamps = {}, { [IKEY] = env.now - 5 }
		Guild:RefreshOnlineCache()
		assert.same({}, CL:GetList(), "GuildShoppingList's list overwrote a guild's own")
		assert.equal(0, #settingsSent())
	end)

	it("with GuildShoppingList not loaded there is nothing to bring", function()
		_G.GuildShoppingList_SavedItems = nil
		Guild:RefreshOnlineCache()
		assert.same({}, CL:GetList())
		assert.is_nil(TOGBankClassic_Database.db.global.gslImport)
	end)

	it("a Miscellaneous turn-in item comes across as a wanted item through the real LibItemDB", function()
		local libs = require("env.libs")
		if not libs.available("LibItemDB-1.0") then pending("ItemDB is not installed beside this addon") end
		libs.fresh("LibItemDB-1.0")
		for _, part in ipairs({ "_core/Miscellaneous", "enUS/Names" }) do
			wow.loadAddonFile(libs.pathOf("LibItemDB-1.0", "Data/Vanilla/" .. part .. ".lua"), "ItemDB")
		end
		-- Punctured Voodoo Doll is nine items of one name (19813-19821, REQ-001): no guess.
		_G.GuildShoppingList_SavedItems = { "Empty Sea Snail Shell x4", "Punctured Voodoo Doll x2" }
		Guild:RefreshOnlineCache()
		assert.same({ [IKEY] = { i = TURNIN, n = 4 } }, CL:GetList())
		assert.same({ "Punctured Voodoo Doll" }, TOGBankClassic_Database.db.global.gslImport.unmappedNames,
			"a name nine items share was put on the list as one of them")
	end)
end)

-- Peer Review, F2: the operator asked for ItemDB FIRST, and the example above only proves the client
-- fallback. This loads the REAL LibItemDB-1.0 with its own shipped Vanilla data -- Empty Sea Snail
-- Shell (10457) from Miscellaneous, Elixir of Fortitude (3825) from Consumable, names from enUS.
describe("GSL-MERGE-001: names come from the real LibItemDB first", function()
	local libs = require("env.libs")

	before_each(function() me = GM; roster(); loadWire() end)
	after_each(function()
		-- The real library must not outlive this describe (SPEC-ORDER-001's class; pricelist_spec does the same).
		libs.forget("LibItemDB-1.0")
		_G.LibItemDB_PriceDB = nil
	end)

	it("an entry's item resolves through ItemDB, with no client cache behind it", function()
		if not libs.available("LibItemDB-1.0") then pending("ItemDB is not installed beside this addon") end
		libs.fresh("LibItemDB-1.0")
		for _, part in ipairs({ "_core/Miscellaneous", "_core/Consumable", "enUS/Names" }) do
			wow.loadAddonFile(libs.pathOf("LibItemDB-1.0", "Data/Vanilla/" .. part .. ".lua"), "ItemDB")
		end
		assert.is_true(LibStub("LibItemDB-1.0"):HasItem(TURNIN), "the shipped Miscellaneous data did not load")
		CL:SetRecipe(ALCHEMY, FORTITUDE, 1)
		CL:SetItem(TURNIN, 1)
		local entries = CL:Entries()
		assert.equal("Elixir of Fortitude", entries[1].name)
		assert.equal("itemdb", entries[1].item.resolved)
		assert.equal("Empty Sea Snail Shell", entries[2].name)
		assert.equal("itemdb", entries[2].item.resolved)
	end)
end)
