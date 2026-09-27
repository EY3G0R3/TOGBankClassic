-- GSL-MERGE-001 build step 3 (v1.7.0): the shopping list's two tabs in the Guild Bank window
-- (Modules/UI/CraftList.lua, wired into Modules/UI/Browse.lua). The operator, 2026-09-25: "make a tab
-- for the shopping list itself, and then an officer only tab to set it up with the same/improved
-- functionality in gsl. but i want to use the look and feel of the new bank for the tabs."
--
-- The REAL Guild (roster through the real LibGuildRoster), the real CraftList model, the real
-- LibProfessionDB-1.0 with its shipped Vanilla Alchemy data, the real AceGUI stack and the real Browse
-- window -- craftlist_spec's wire, with the window on top.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")
local wow = require("env.wow")

local GM, MEMBER, BANKER = "Gm-Testrealm", "Member-Testrealm", "Banker-Testrealm"
local ALCHEMY, FORTITUDE, FORTITUDE_ITEM = 171, 3450, 3825
local STEELBLOOM, VIAL, GOLDTHORN = 3355, 3372, 3821
local TURNIN = 10457

local Guild, CL, UICL, Browse, me

local function loadStack()
	env.stubOutput()
	require("env.frames").reset()   -- the rich frame model BEFORE the widget library (browse_spec's reason)
	require("env.ace").load("AceAddon-3.0", "AceComm-3.0", "AceConsole-3.0",
		"AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
	env.loadDeltaSync()
	local libs = require("env.libs")
	libs.forget("LibProfessionDB-1.0")
	libs.load("LibProfessionDB-1.0")
	for _, part in ipairs({ "_core", "enUS" }) do
		assert(loadfile(libs.pathOf("LibProfessionDB-1.0", "Data/Vanilla/" .. part .. "/Alchemy.lua")))("ProfessionDB", {})
	end
	libs.load("LibAceGUIWidgets-1.0")
	local satellite = loadfile(libs.pathOf("LibAceGUIWidgets-1.0", "LibAceGUIWidgets-DatePicker.lua"))
	assert(satellite, "LibAceGUIWidgets-DatePicker.lua is not beside the library")
	satellite("LibAceGUIWidgets", {})
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
		db = { global = {}, char = {} },
		IsIntegrityCheckDiagnosticsEnabled = function() return false end, IsSyncProgressMuted = function() return true end,
		GetBankEnabled = function() return true end, GetAutoTombstoneDays = function() return 30 end,
		GetMaxRequestPercent = function() return 100 end, GetBankReporting = function() return false end,
		IsOrderFulfillmentSoundEnabled = function() return false end,
	}
	TOGBankClassic_Performance = { RecordOperation = function() end }
	Guild, CL = TOGBankClassic_Guild, TOGBankClassic_CraftList
	Guild.Info = { name = "Testguild", alts = {}, roster = { alts = {} }, requests = {}, requestsTombstones = {}, settings = {} }
	Guild.memberRoster, Guild.onlineMembers, Guild.banksCache, Guild.lastSettingsPayload = {}, {}, nil, nil
	Guild.GetNormalizedPlayer = function() return me end
	Guild.GetPlayer = function() return me end
	TOGBankClassic_Chat.hashBroadcastQueue = {}
	TOGBankClassic_Core.SendCommMessage = function() end
	_G.LibGuildRosterDB = nil
	local lib = env.freshGuildRoster()
	env.readyGuildRoster(lib)
	Guild:RefreshOnlineCache()
	-- The window.
	env.loadUI()
	env.loadFile("Modules/UI/Search.lua")
	env.loadFile("Modules/UI/RowList.lua")
	env.loadFile("Modules/Usable.lua")
	env.loadFile("Modules/UI/Browse.lua")
	env.loadFile("Modules/UI/CraftList.lua")
	env.loadFile("Modules/UI/CraftTracker.lua")
	Browse, UICL = TOGBankClassic_UI_Browse, TOGBankClassic_UI_CraftList
	TOGBankClassic_UI_StatusBar = { AttachSides = function() return {} end }
	TOGBankClassic_UI_Requests = { Detach = function() end }
	-- C_TradeSkillUI (profession names) is the harness's own since ee56a45 (inbox b856f5a5).
	Browse:Init()
end

local function roster()
	env.reset()
	env.addGuildMember(GM, { rankIndex = 0, online = true })
	env.addGuildMember(MEMBER, { rankIndex = 4, online = true, note = "" })
	env.addGuildMember(BANKER, { rankIndex = 4, online = true, note = "gbank herbs" })
	_G.CanViewOfficerNote = function() return me == GM end
end

local function stockBank(records)
	local Record, Store = TOGBankClassic_Inventory_Record, TOGBankClassic_Inventory_Store
	local recs = {}
	for id, n in pairs(records) do recs[#recs + 1] = Record.new(id, n) end
	Store:SetAltRecords("Testguild", BANKER, recs, env.now)
	-- The banker roster Browse:BuildRows walks, built the way a live client builds it on
	-- GUILD_ROSTER_UPDATE: from BANKER's "gbank herbs" note (Peer Review on self-audit 93c01c04).
	Guild:RebuildBankerRoster()
end

local function tabValues()
	local out = {}
	for _, t in ipairs(Browse:TabList()) do out[#out + 1] = t.value end
	return out
end

local function teardown()
	if Browse and Browse.Window then env.releaseWindow(Browse.Window); Browse.Window = nil end
	local T = TOGBankClassic_UI_CraftTracker
	if T and T.Window then env.releaseWindow(T.Window); T.Window = nil end
	TOGBankClassic_UI_Browse, TOGBankClassic_UI_CraftList, TOGBankClassic_UI_CraftTracker = nil, nil, nil
	TOGBankClassic_UI_StatusBar, TOGBankClassic_UI_Requests = nil, nil
end

describe("GSL-MERGE-001 step 3: the tabs, by role", function()
	before_each(function() me = MEMBER; roster(); loadStack() end)
	after_each(teardown)

	it("everyone gets Shopping List after the existing tabs; only a writer gets List Setup", function()
		assert.same({ "browse", "bankers", "requests", "log", "shopping" }, tabValues())
		me = GM
		assert.same({ "browse", "bankers", "requests", "log", "shopping", "shoppingsetup" }, tabValues())
	end)

	it("re-renders the tab strip on open only when the set of tabs changed", function()
		Browse:Open()
		local calls = 0
		local real = Browse.TabGroup.SetTabs
		Browse.TabGroup.SetTabs = function(...) calls = calls + 1; return real(...) end
		Browse:Close(); Browse:Open()
		assert.equal(0, calls, "an unchanged tab set was rebuilt on open")
		me = GM
		Browse:Close(); Browse:Open()
		assert.equal(1, calls, "the new List Setup tab did not reach the strip")
		Browse.TabGroup.SetTabs = real
	end)

	it("a remembered List Setup tab falls back to Browse once its holder may no longer edit", function()
		me = GM
		Browse:Open("shoppingsetup")
		assert.equal("shoppingsetup", Browse.currentTab)
		me = MEMBER
		assert.equal("browse", Browse:RememberedTab(), "a tab the strip no longer carries was remembered")
	end)
end)

describe("GSL-MERGE-001 step 3: the Shopping List tab", function()
	before_each(function()
		me = GM; roster(); loadStack()
		CL:SetRecipe(ALCHEMY, FORTITUDE, 10)
		CL:SetItem(TURNIN, 4)
		stockBank({ [FORTITUDE_ITEM] = 2, [STEELBLOOM] = 5, [TURNIN] = 1 })
		wow.bags[0] = { slots = 4, [1] = { itemID = GOLDTHORN, count = 1 } }
		me = MEMBER
	end)
	after_each(teardown)

	-- SHOPLIST-SPLIT-001 (the operator 2026-09-26: "the shopping list tab needs to be like the list
	-- setup tab, the items on the top, but instead of a search bit on the bottom, the bottom rows
	-- should be all the reagents we need to make the items in the list").
	it("shows the wanted items in a box on top and every reagent under it, both at once", function()
		Browse:Open("shopping")
		assert.equal("shopping", Browse.currentTab)
		assert.is_true(UICL.WantedBox:IsShown())
		assert.is_true(UICL.ReagentList.parent:IsShown(), "the reagent roll-up is not on the tab")
		assert.is_false(Browse.BrowseList.parent:IsShown())
		local p, rel, relp = UICL.ReagentList.parent:GetPoint(1)
		assert.same({ "TOPLEFT", UICL.WantedBox, "BOTTOMLEFT" }, { p, rel, relp }, "the reagents are not under the wanted items")
		assert.equal(2, #UICL.wantedRowsShown)
		assert.equal(4, #UICL.reagentRowsShown)
		assert.truthy(Browse.statusText:find("2 wanted, 4 reagents, 4 still missing", 1, true), Browse.statusText)
		Browse:ShowTab("browse")
		assert.is_false(UICL.WantedBox:IsShown())
		assert.is_false(UICL.ReagentList.parent:IsShown())
	end)

	it("a crafted item's + opens the reagents the rest of it takes; a click on the row still orders", function()
		Browse:Open("shopping")
		local list = UICL.WantedList
		local function cellsFor(key)
			local data = list:_sortedData()
			for i, row in ipairs(list.rows) do
				local e = data[list.listOffset + i]
				if e and e.key == key then return row.cells end
			end
		end
		local cells = cellsFor("r171:3450")
		assert.equal("|cFFFFD100+|r", cells.arrow.label:GetText())
		assert.is_falsy(cellsFor("i10457").arrow.entry.expandable, "a plain item offered reagents")
		cells.arrow:GetScript("OnClick")()
		local kids = {}
		for _, r in ipairs(UICL.wantedRowsShown) do if r.child and r.parent == "r171:3450" then kids[r.itemID] = r end end
		-- Ten wanted, two already in the bank: eight still to make, one Steelbloom each.
		assert.equal(8, kids[STEELBLOOM] and kids[STEELBLOOM].count, "the reagent is not at what is still to make")
		assert.is_table(kids[GOLDTHORN]); assert.is_table(kids[VIAL])
		assert.truthy(Browse.statusText:find("2 wanted", 1, true), "opened reagents were counted as wanted items")
		assert.equal("|cFFFFD100-|r", cellsFor("r171:3450").arrow.label:GetText())
		cellsFor("r171:3450").arrow:GetScript("OnClick")()
		assert.equal(2, #UICL.wantedRowsShown, "it did not close")
	end)

	it("lists what the guild wants, its profession, and what the bank already holds", function()
		Browse:Open("shopping")
		local rows = {}
		for _, r in ipairs(UICL.wantedRowsShown) do rows[r.key] = r end
		local fort = rows["r171:3450"]
		assert.equal("Alchemy", fort.kind)
		assert.equal(10, fort.count); assert.equal(2, fort.bank); assert.equal(8, fort.short)
		local shell = rows["i10457"]
		assert.equal("Item", shell.kind)
		assert.equal(4, shell.count); assert.equal(1, shell.bank); assert.equal(3, shell.short)
		assert.truthy(Browse.statusText:find("2 wanted", 1, true))
	end)

	-- GSL-BANK-001: Missing is what the [GSL] character still lacks; Bank and You are shown beside it.
	-- This guild has no [GSL] character, so everything the list needs is missing.
	it("the reagent roll-up shows the bank and your bags beside what is still missing", function()
		Browse:Open("shopping")
		local byId = {}
		for _, r in ipairs(UICL.reagentRowsShown) do byId[r.itemID] = r end
		assert.same({ 8, 5, 0, 0, 8 }, { byId[STEELBLOOM].needed, byId[STEELBLOOM].bank, byId[STEELBLOOM].gsl, byId[STEELBLOOM].you, byId[STEELBLOOM].missing })
		assert.same({ 8, 0, 0, 1, 8 }, { byId[GOLDTHORN].needed, byId[GOLDTHORN].bank, byId[GOLDTHORN].gsl, byId[GOLDTHORN].you, byId[GOLDTHORN].missing })
		assert.equal(8, byId[VIAL].missing)
		assert.equal(4, byId[TURNIN].missing)
		assert.truthy(Browse.statusText:find("4 reagents, 4 still missing", 1, true))
	end)

	it("the search box narrows by name or profession", function()
		Browse:Open("shopping")
		UICL.filter.text = "alchemy"
		UICL:Draw("shopping")
		assert.equal(1, #UICL.wantedRowsShown)
		assert.equal("r171:3450", UICL.wantedRowsShown[1].key)
		assert.truthy(Browse.statusText:find("1 of 2 wanted", 1, true))
	end)
end)

-- GSL-BANK-001 (the operator 2026-09-26: "we also need what is on the GSL player (bank/bags/mail)
-- just like a banker. they are the 'special' banker for the shopping list" / "the missing tab
-- should be what the GSL banker is missing"). The [GSL] characters are on the guild roster before the
-- stack loads, as every member is, so the real roster library carries their notes.
describe("GSL-BANK-001: the [GSL] character is the shopping list's banker", function()
	before_each(function()
		me = GM; roster()
		env.addGuildMember("Gatherer-Testrealm", { rankIndex = 4, online = true, note = "[GSL] mats" })
		env.addGuildMember("Both-Testrealm", { rankIndex = 4, online = true, note = "gbank [GSL]" })
		env.addGuildMember("Officernote-Testrealm", { rankIndex = 4, online = true, note = "", officerNote = "[GSL]" })
		loadStack()
		CL:SetRecipe(ALCHEMY, FORTITUDE, 10)
		CL:SetItem(TURNIN, 4)
		stockBank({ [FORTITUDE_ITEM] = 2, [STEELBLOOM] = 5, [TURNIN] = 1 })
		wow.bags[0] = { slots = 4, [1] = { itemID = GOLDTHORN, count = 1 } }
		me = MEMBER
	end)
	after_each(teardown)

	it("the [GSL] character is a view-only banker, and a gbank note beside it keeps it orderable", function()
		assert.is_true(Guild:IsBank("Gatherer-Testrealm"), "the [GSL] character is not a banker, so nothing scans it")
		assert.is_true(Guild:IsViewOnlyBank("Gatherer-Testrealm"), "the guild could order the shopping list's stock back out")
		assert.is_true(Guild:IsGSLBank("Gatherer-Testrealm"))
		assert.is_true(Guild:IsBank("Both-Testrealm"))
		assert.is_false(Guild:IsViewOnlyBank("Both-Testrealm"), "gbank beside [GSL] lost its ordering")
		assert.is_true(Guild:IsGSLBank("Both-Testrealm"))
		assert.is_false(Guild:IsBank("Officernote-Testrealm"), "an officer-note [GSL] is not GuildShoppingList's marker")
		assert.is_false(Guild:IsGSLBank(BANKER))
		assert.equal("mats", Guild:BankerStores("Gatherer-Testrealm"))
		local banks = {}
		for _, b in ipairs(Guild:GetBanks() or {}) do banks[Guild:NormalizeName(b)] = true end
		assert.is_true(banks["Gatherer-Testrealm"], "the scan gate's banker list leaves the [GSL] character out")
	end)

	it("the GSL column is the [GSL] character's stock, kept out of Bank, and Missing is what they still lack", function()
		local Record, Store = TOGBankClassic_Inventory_Record, TOGBankClassic_Inventory_Store
		Store:SetAltRecords("Testguild", "Gatherer-Testrealm", { Record.new(STEELBLOOM, 3) }, env.now)
		Guild.Info.alts["Gatherer-Testrealm"] = Guild.Info.alts["Gatherer-Testrealm"] or {}
		Guild:RebuildBankerRoster()
		Browse:Open("shopping")
		local byId = {}
		for _, r in ipairs(UICL.reagentRowsShown) do byId[r.itemID] = r end
		local s = byId[STEELBLOOM]
		assert.equal(8, s.needed)
		assert.equal(5, s.bank, "the [GSL] character's stock was counted as guild bank stock")
		assert.equal(3, s.gsl, "the GSL column does not show the [GSL] character's stock")
		assert.equal(5, s.missing, "Missing is not what the [GSL] character still lacks (8 - 3)")
		-- Your own bags and the guild bank are shown, not netted out of Missing.
		assert.equal(1, byId[GOLDTHORN].you)
		assert.equal(8, byId[GOLDTHORN].missing)
	end)

	-- GSL-YOU-001 (the operator 2026-09-26: "when i'm on the GSL toon, the GSL and You columns should
	-- match"): on a bank character You is that character's own scanned bags, bank AND mail -- the
	-- total the GSL column reads -- not the client's bag count.
	it("on the [GSL] character, You equals GSL, mail included", function()
		local Record, Store = TOGBankClassic_Inventory_Record, TOGBankClassic_Inventory_Store
		Store:SetAltSources("Testguild", "Gatherer-Testrealm",
			{ bags = { Record.new(STEELBLOOM, 2) }, mail = { Record.new(STEELBLOOM, 1) } }, 0)
		Guild.Info.alts["Gatherer-Testrealm"] = Guild.Info.alts["Gatherer-Testrealm"] or {}
		Guild:RebuildBankerRoster()
		me = "Gatherer-Testrealm"
		Browse:Open("shopping")
		local byId = {}
		for _, r in ipairs(UICL.reagentRowsShown) do byId[r.itemID] = r end
		assert.equal(3, byId[STEELBLOOM].gsl, "the mailbox's Steelbloom is not in the GSL column")
		assert.equal(3, byId[STEELBLOOM].you, "You on the [GSL] character is not its own scanned total")
	end)
end)

describe("GSL-MERGE-001 step 3: the Shopping List tab, continued", function()
	before_each(function()
		me = GM; roster(); loadStack()
		CL:SetRecipe(ALCHEMY, FORTITUDE, 10)
		CL:SetItem(TURNIN, 4)
		stockBank({ [FORTITUDE_ITEM] = 2, [STEELBLOOM] = 5, [TURNIN] = 1 })
		wow.bags[0] = { slots = 4, [1] = { itemID = GOLDTHORN, count = 1 } }
		me = MEMBER
	end)
	after_each(teardown)

	-- WANTED-BREATH-001 (the operator 2026-09-26: "can you have the wanted stuff 'breath' using the
	-- function from the widgets library?"): Still needed breathes while it is above zero.
	local function shortCell(key)
		local list = UICL.WantedList
		local data = list:_sortedData()
		for i, row in ipairs(list.rows) do
			local e = data[list.listOffset + i]
			if e and e.key == key then return row.cells.short end
		end
	end

	it("Still needed breathes through the widgets library while the guild still needs some, and stops at zero", function()
		local W = TOGBankClassic_UI.Widgets
		assert.is_function(W and W.IsBreathing, "the widgets library's breath is not loaded")
		Browse:Open("shopping")
		local cell = shortCell("i10457")
		assert.is_table(cell, "the shell row was not rendered")
		assert.equal("3", cell.text:GetText())
		assert.is_true(W:IsBreathing(cell), "Still needed 3 does not breathe")
		-- The bank now holds all four: the same pooled cell must stop, at full alpha.
		stockBank({ [FORTITUDE_ITEM] = 2, [STEELBLOOM] = 5, [TURNIN] = 4 })
		UICL:Draw("shopping")
		cell = shortCell("i10457")
		assert.equal("0", cell.text:GetText())
		assert.is_false(W:IsBreathing(cell), "Still needed 0 kept breathing")
		assert.equal(1, cell:GetAlpha())
	end)

	-- GATHER-BREATH-001 (the operator 2026-09-26: "the date isn't breathing", of "3 wanted --
	-- gathering 2026-09-26 to 2026-10-03"): the status line breathes on the Shopping List tab while a
	-- gather window is set, and on no other tab.
	it("breathes the status line while a gather window is set, and only on the Shopping List tab", function()
		local breath
		TOGBankClassic_UI_StatusBar.AttachSides = function()
			return { SetLeftBreathing = function(_, on) breath = on end }
		end
		Browse:Open("shopping")
		assert.is_false(breath, "no gather window, but the line breathes")
		me = GM
		CL:SetGatherWindow("2026-10-01", "2026-10-08")
		me = MEMBER
		UICL:Draw("shopping")
		assert.is_true(breath, "the gather dates are on the line but it does not breathe")
		Browse:ShowTab("shopping")
		assert.is_true(breath, "reopening the tab lost the breath")
		Browse:ShowTab("browse")
		assert.is_false(breath, "the Browse tab's line kept breathing")
	end)

	-- GSL-SENDTO-001 (the operator 2026-09-26: "on the shopping list tab, we need to show who is the
	-- GSL character, so people know who to send items to").
	it("names the [GSL] character on the strip, online first, and says so when there is none", function()
		Browse:Open("shopping")
		assert.is_table(UICL.SendToLabel, "the strip has no send-to line")
		assert.truthy(UICL.sendToText:find("no one has [GSL]", 1, true), UICL.sendToText)
		env.addGuildMember("Zgather-Testrealm", { rankIndex = 4, online = true, note = "[GSL] mats here" })
		env.addGuildMember("Agather-Testrealm", { rankIndex = 4, online = false, note = "alt [GSL]" })
		UICL:Draw("shopping")
		local text = UICL.sendToText
		assert.truthy(text:find("Zgather-Testrealm", 1, true), text)
		assert.truthy(text:find("Agather-Testrealm (offline)", 1, true), text)
		assert.is_true(text:find("Zgather", 1, true) < text:find("Agather", 1, true), "the online character is not first")
		-- A member without the marker (the bank character's note is "gbank herbs") is not named.
		assert.is_nil(text:find("Banker-Testrealm", 1, true))
	end)

	it("shows the gather window on the status line, and repaints when the list changes under it", function()
		me = GM
		CL:SetGatherWindow("2026-10-01", "2026-10-08")
		me = MEMBER
		Browse:Open("shopping")
		assert.truthy(Browse.statusText:find("gathering 2026-10-01 to 2026-10-08", 1, true))
		me = GM
		CL:SetItem(TURNIN, 0)   -- a write here fires OnListChanged
		assert.equal(1, #UICL.wantedRowsShown, "the open tab did not repaint on the change")
	end)
end)

-- GSL-MERGE-001 build step 7 (D6): a Shopping List row orders its item through the existing
-- request dialog, from the bank character holding the most of it.
describe("GSL-MERGE-001 step 7: ordering from a Shopping List row", function()
	local asked, realShow
	before_each(function()
		me = GM; roster(); loadStack()
		CL:SetRecipe(ALCHEMY, FORTITUDE, 10)
		CL:SetItem(TURNIN, 4)
		stockBank({ [FORTITUDE_ITEM] = 2, [STEELBLOOM] = 5, [TURNIN] = 1 })
		me = MEMBER
		asked = nil
		realShow = TOGBankClassic_UI_Search.ShowRequestDialog
		TOGBankClassic_UI_Search.ShowRequestDialog = function(_, entry, bank) asked = { entry = entry, bank = bank } end
	end)
	after_each(function()
		TOGBankClassic_UI_Search.ShowRequestDialog = realShow
		teardown()
	end)

	local function rowById(rows, field, value)
		for _, r in ipairs(rows) do if r[field] == value then return r end end
	end

	it("a click on a wanted row opens the request dialog for that item on the bank character holding it", function()
		Browse:Open("shopping")
		local shell = rowById(UICL.wantedRowsShown, "key", "i10457")
		UICL.WantedList.onRowClick(shell, 1, "LeftButton")
		assert.is_table(asked, "the click did not open the request dialog")
		assert.equal(TURNIN, asked.entry.ID)
		assert.equal(BANKER, Guild:NormalizeName(asked.bank))
		assert.equal(1, asked.entry.Count)
	end)

	it("a wanted recipe orders the item it makes", function()
		Browse:Open("shopping")
		UICL.WantedList.onRowClick(rowById(UICL.wantedRowsShown, "key", "r171:3450"), 1, "LeftButton")
		assert.is_table(asked)
		assert.equal(FORTITUDE_ITEM, asked.entry.ID)
	end)

	it("a click on a reagent row orders that reagent", function()
		Browse:Open("shopping")
		UICL.ReagentList.onRowClick(rowById(UICL.reagentRowsShown, "itemID", STEELBLOOM), 1, "LeftButton")
		assert.is_table(asked)
		assert.equal(STEELBLOOM, asked.entry.ID)
		assert.equal(5, asked.entry.Count)
	end)

	it("an item no bank character holds opens nothing and says so on the status line", function()
		Browse:Open("shopping")
		UICL.ReagentList.onRowClick(rowById(UICL.reagentRowsShown, "itemID", GOLDTHORN), 1, "LeftButton")
		assert.is_nil(asked)
		assert.truthy(Browse.statusText:find("No bank character has", 1, true), Browse.statusText)
	end)

	it("a recipe that makes no item (an enchant) orders nothing and says why", function()
		Browse:Open("shopping")
		UICL:OnListRowClick({ plainName = "Enchant Bracer - Minor Health", entry = { kind = "recipe" } }, "LeftButton")
		assert.is_nil(asked)
		assert.truthy(Browse.statusText:find("makes no item", 1, true), Browse.statusText)
	end)

	it("a right-click orders nothing", function()
		Browse:Open("shopping")
		UICL.WantedList.onRowClick(rowById(UICL.wantedRowsShown, "key", "i10457"), 1, "RightButton")
		assert.is_nil(asked)
	end)

	it("picks the requestable bank character with the most, skipping a view-only bank and a hidden row", function()
		local realRows = Browse.BuildRows
		Browse.BuildRows = function()
			return {
				{ ID = STEELBLOOM, Count = 3, player = "A-Testrealm", norm = "A-Testrealm" },
				{ ID = STEELBLOOM, Count = 50, player = "V-Testrealm", norm = "V-Testrealm", viewOnly = true },
				{ ID = STEELBLOOM, Count = 40, player = "H-Testrealm", norm = "H-Testrealm", Hidden = true },
				{ ID = STEELBLOOM, Count = 7, player = "B-Testrealm", norm = "B-Testrealm" },
				{ ID = VIAL, Count = 99, player = "C-Testrealm", norm = "C-Testrealm" },
			}
		end
		local row = UICL:OrderSource(STEELBLOOM)
		Browse.BuildRows = realRows
		assert.equal("B-Testrealm", row.player)
	end)

	it("on a tie, keeps the first bank character in BuildRows' name order", function()
		local realRows = Browse.BuildRows
		Browse.BuildRows = function()
			return {
				{ ID = STEELBLOOM, Count = 6, player = "A-Testrealm", norm = "A-Testrealm" },
				{ ID = STEELBLOOM, Count = 6, player = "B-Testrealm", norm = "B-Testrealm" },
			}
		end
		local row = UICL:OrderSource(STEELBLOOM)
		Browse.BuildRows = realRows
		assert.equal("A-Testrealm", row.player)
	end)
end)

-- GSL-MERGE-001 build step 4 (D5): the detached Reagent Tracker.
describe("GSL-MERGE-001 step 4: the Reagent Tracker", function()
	local Tracker
	before_each(function()
		me = GM; roster(); loadStack()
		Tracker = TOGBankClassic_UI_CraftTracker
		CL:SetRecipe(ALCHEMY, FORTITUDE, 10)
		stockBank({ [FORTITUDE_ITEM] = 2, [STEELBLOOM] = 5 })
		me = MEMBER
	end)
	after_each(teardown)

	local function byId()
		local out = {}
		for _, r in ipairs(Tracker.rowsShown) do out[r.itemID] = r end
		return out
	end

	it("shows the Shopping List tab's reagent roll-up in a window of its own, and counts what is missing", function()
		Tracker:Open()
		assert.is_true(Tracker.isOpen)
		assert.is_true(Tracker.Window.frame:IsShown())
		assert.equal(3, #Tracker.rowsShown)
		assert.same({ 8, 5, 8 }, { byId()[STEELBLOOM].needed, byId()[STEELBLOOM].bank, byId()[STEELBLOOM].missing })
		assert.equal("3 of 3 reagents still missing", Tracker.statusText)
		assert.truthy(Tracker.Window.titletext:GetText():find("Reagent Tracker", 1, true))
	end)

	-- Peer Review (inbox a0556886, F5): the event is FIRED through the harness to whatever registered
	-- for it, and the registration itself is asserted -- calling OnEvent by hand proved the handler,
	-- not the wiring.
	-- GSL-BANK-001: what you carry moves You; Missing is the [GSL] character's and does not move with it.
	it("listens for bag updates only while shown: what you gather moves You", function()
		local frames = require("env.frames")
		Tracker:Open()
		assert.is_true(Tracker.Events:IsEventRegistered("BAG_UPDATE_DELAYED"), "the open tracker is not listening for bag updates")
		wow.bags[0] = { slots = 4, [1] = { itemID = GOLDTHORN, count = 8 } }
		frames.fireEvent("BAG_UPDATE_DELAYED")
		assert.same({ 8, 8 }, { byId()[GOLDTHORN].you, byId()[GOLDTHORN].missing })
		assert.equal("3 of 3 reagents still missing", Tracker.statusText)
		-- Closed, it stops listening, and the same event paints nothing.
		Tracker:Close()
		assert.is_false(Tracker.Events:IsEventRegistered("BAG_UPDATE_DELAYED"), "the closed tracker still listens for bag updates")
		wow.bags[0] = nil
		frames.fireEvent("BAG_UPDATE_DELAYED")
		assert.equal(8, byId()[GOLDTHORN].you, "a closed tracker repainted")
	end)

	-- ESC-SPLIT-001 (Peer Review, inbox a0556886): a transparency slider like every window, without
	-- being counted by the Escape stand-in.
	it("takes its own transparency setting, and does not hold the Escape stand-in up", function()
		Tracker:Open()
		assert.is_true(TOGBankClassic_UI:SetWindowAlpha("tracker", 0.5))
		assert.is_true(TOGBankClassic_UI:ApplyWindowAlpha("tracker"), "the tracker's slider reaches no window")
		assert.equal(0.5, select(4, Tracker.Window.frame.togOpaqueFill:GetColorTexture()))
		TOGBankClassic_UI:SyncEscape()
		assert.is_false(TOGBankClassic_UI:EscapeProxy():IsShown(), "Escape would close the tracker, not open the game menu")
	end)

	it("repaints when the list changes, and when bank data lands with the Guild Bank window closed", function()
		Tracker:Open()
		me = GM
		CL:SetItem(TURNIN, 2)
		assert.equal(4, #Tracker.rowsShown, "a list write did not reach the open tracker")
		stockBank({ [FORTITUDE_ITEM] = 2, [STEELBLOOM] = 5, [TURNIN] = 2 })
		assert.is_falsy(Browse.isOpen)
		-- The "data landed" signal every sync path raises (BROWSE-008), on its real debounce. The
		-- legacy window is not open either: the tracker must take the signal on its own.
		env.loadFile("Modules/UI/Inventory.lua")
		TOGBankClassic_UI_Inventory:RefreshSoon()
		env.advance(1)
		assert.equal(2, byId()[TURNIN].bank, "new bank data did not reach the open tracker")
		-- A roster change (the Guild Bank window's own Refresh path) reaches it too.
		stockBank({ [FORTITUDE_ITEM] = 2, [STEELBLOOM] = 5 })
		Browse:Refresh()
		assert.equal(0, byId()[TURNIN].bank, "a roster change did not reach the open tracker")
	end)

	it("/togbank tracker toggles it, and Escape's close-everything leaves it up", function()
		TOGBankClassic_Chat:ChatCommand("tracker")
		assert.is_true(Tracker.isOpen)
		TOGBankClassic_UI:CloseAllWindows()
		assert.is_true(Tracker.isOpen, "Escape closed the tracker a gatherer keeps up")
		TOGBankClassic_Chat:ChatCommand("tracker")
		assert.is_false(Tracker.isOpen)
		assert.is_false(Tracker.Window.frame:IsShown())
	end)

	it("says so when there is nothing to gather", function()
		me = GM
		CL:SetRecipe(ALCHEMY, FORTITUDE, 0)
		Tracker:Open()
		assert.equal(0, #Tracker.rowsShown)
		assert.truthy(Tracker.statusText:find("Nothing to gather", 1, true))
	end)
end)

describe("GSL-MERGE-001 step 3: the List Setup tab", function()
	before_each(function() me = GM; roster(); loadStack() end)
	after_each(teardown)

	it("finds a recipe by name in the real library, adds it at the How many count, and a right-click takes it off", function()
		Browse:Open("shoppingsetup")
		assert.is_true(UICL.SetupList.parent:IsShown())
		assert.truthy(Browse.statusText:find("0 on the list", 1, true))
		UICL.setupFilter.text = "fortitude"
		UICL.setupFilter.count = 5
		UICL:Draw("shoppingsetup")
		local hit
		for _, r in ipairs(UICL.setupRowsShown) do if r.key == "r171:3450" then hit = r end end
		assert.is_table(hit, "the search did not find Elixir of Fortitude")
		assert.equal("Alchemy", hit.kind)
		assert.equal("", hit.onlist)
		UICL:OnSetupRowClick(hit, "LeftButton")
		assert.equal(5, CL:GetList()["r171:3450"].n)
		-- The open tab repainted: the row now says it is on the list.
		for _, r in ipairs(UICL.setupRowsShown) do if r.key == "r171:3450" then hit = r end end
		assert.equal(5, hit.onlist)
		UICL:OnSetupRowClick(hit, "RightButton")
		assert.is_nil(CL:GetList()["r171:3450"])
	end)

	-- SETUP-SPLIT-001 (the operator 2026-09-26: "split the list setup into whats on the list on top
	-- and the selection bit on the bottom. lets make it look like TOGPM's 'shopping list' bit"):
	-- what is on the list is the bordered box on top; the search results sit under it.
	local function onListRow(key)
		for _, r in ipairs(UICL.onListRowsShown) do if r.key == key then return r end end
	end
	local function controlsFor(key)
		local list = UICL.OnListList
		local data = list:_sortedData()
		for i, row in ipairs(list.rows) do
			local e = data[list.listOffset + i]
			if e and e.key == key then return row.cells.ctl end
		end
	end

	it("puts what is on the list in a box on top, and the search results under it", function()
		CL:SetRecipe(ALCHEMY, FORTITUDE, 2)
		CL:SetItem(TURNIN, 3)
		Browse:Open("shoppingsetup")
		assert.is_true(UICL.SetupBox:IsShown())
		assert.is_true(UICL.SetupList.parent:IsShown())
		assert.equal(2, #UICL.onListRowsShown)
		assert.equal(0, #UICL.setupRowsShown, "an empty search still listed rows under the box")
		assert.truthy(Browse.statusText:find("2 on the list", 1, true))
		local p, rel, relp = UICL.SetupList.parent:GetPoint(1)
		assert.same({ "TOPLEFT", UICL.SetupBox, "BOTTOMLEFT" }, { p, rel, relp }, "the search results are not under the box")
		-- A search fills the bottom and leaves the box alone; a profession narrows the search only.
		UICL.setupFilter.text = "fortitude"
		UICL.setupFilter.prof = tostring(ALCHEMY)
		UICL:Draw("shoppingsetup")
		assert.equal(2, #UICL.onListRowsShown)
		assert.truthy(#UICL.setupRowsShown >= 1)
		for _, r in ipairs(UICL.setupRowsShown) do
			if r.recipe then assert.equal(ALCHEMY, r.recipe.profId) end
		end
		-- Leaving the tab hides the box with the lists.
		Browse:ShowTab("browse")
		assert.is_false(UICL.SetupBox:IsShown())
	end)

	it("the box's - and + change a count, - from 1 and x take it off, TOGPM's controls", function()
		CL:SetRecipe(ALCHEMY, FORTITUDE, 2)
		CL:SetItem(TURNIN, 1)
		Browse:Open("shoppingsetup")
		local ctl = controlsFor("r171:3450")
		assert.is_table(ctl, "the Fortitude row was not rendered in the box")
		assert.equal("2", ctl.count:GetText())
		ctl.plus:GetScript("OnClick")()
		assert.equal(3, CL:GetList()["r171:3450"].n)
		assert.equal("3", controlsFor("r171:3450").count:GetText(), "the box did not repaint")
		controlsFor("r171:3450").minus:GetScript("OnClick")()
		assert.equal(2, CL:GetList()["r171:3450"].n)
		controlsFor("i10457").minus:GetScript("OnClick")()
		assert.is_nil(CL:GetList()["i10457"], "- from 1 left the entry on the list")
		controlsFor("r171:3450").remove:GetScript("OnClick")()
		assert.is_nil(CL:GetList()["r171:3450"])
		assert.equal(0, #UICL.onListRowsShown)
	end)

	-- SETUP-REAGENTS-001 (the operator 2026-09-26: "i would like to do a TOGPM like thing, where each
	-- 'made' item shows the mats to make it"): TOGPM's expander on the box.
	it("a made item in the box expands to its reagents, at the count the list wants, and collapses again", function()
		CL:SetRecipe(ALCHEMY, FORTITUDE, 2)
		CL:SetItem(TURNIN, 3)
		Browse:Open("shoppingsetup")
		local fort = onListRow("r171:3450")
		assert.is_true(fort.expandable)
		assert.equal("|cFFFFD100+|r", fort.arrow)
		assert.is_falsy(onListRow("i10457").expandable, "a plain item offered reagents")
		assert.equal(2, #UICL.onListRowsShown)
		UICL.OnListList.onRowClick(fort, 1, "LeftButton")
		local rows = UICL.onListRowsShown
		assert.equal("r171:3450", rows[1].key, "the recipe moved")
		local kids = {}
		local i = 2
		while rows[i] and rows[i].child do kids[rows[i].itemID] = rows[i]; i = i + 1 end
		assert.is_table(kids[STEELBLOOM], "Steelbloom is not under the Elixir")
		assert.equal(2, kids[STEELBLOOM].count, "one per craft, two wanted")
		assert.is_table(kids[GOLDTHORN]); assert.is_table(kids[VIAL])
		assert.equal("|cFFFFD100-|r", onListRow("r171:3450").arrow)
		-- A reagent row shows its count and no controls.
		local list = UICL.OnListList
		local data = list:_sortedData()
		for r, row in ipairs(list.rows) do
			local e = data[list.listOffset + r]
			if e and e.child then
				assert.is_false(row.cells.ctl.plus:IsShown(), "a reagent row has a + button")
				assert.truthy(row.cells.ctl.count:GetText():find("x", 1, true))
			end
		end
		UICL.OnListList.onRowClick(onListRow("r171:3450"), 1, "LeftButton")
		assert.equal(2, #UICL.onListRowsShown, "it did not collapse")
	end)

	it("a member's click on the box's controls changes nothing and says why", function()
		CL:SetItem(TURNIN, 3)
		Browse:Open("shoppingsetup")
		me = MEMBER
		UICL:StepEntry(onListRow("i10457"), 1)
		UICL:RemoveEntry(onListRow("i10457"))
		assert.equal(3, CL:GetList()["i10457"].n)
		assert.equal(UICL.NOT_ALLOWED_TEXT, Browse.statusText)
	end)

	-- SETUP-SPLIT-002 (the operator 2026-09-26: "i don't mind the scrollbar, but we need to expand
	-- more than 3 items before we introduce it. how does TOGPM do it?"): TOGPM shows every row until
	-- the section reaches its 40% cap (BrowserTab.lua:1636). A box sized to EXACTLY its rows lost the
	-- last one to RowList's floor() the moment the client shaved a pixel off the frame, so the
	-- scrollbar came in at 3.
	it("shows every row and no scrollbar below the cap, even with a pixel shaved off the box", function()
		CL:SetRecipe(ALCHEMY, FORTITUDE, 2)
		CL:SetItem(TURNIN, 3)
		CL:SetItem(STEELBLOOM, 4)
		Browse:Open("shoppingsetup")
		local l = UICL.OnListList
		UICL.SetupBox:SetHeight(UICL:SetupBoxHeight(3) - 1)   -- the client's pixel snap
		l:Refresh()
		assert.is_true(l.visibleRowCount >= 3, "the third row was dropped: " .. tostring(l.visibleRowCount))
		assert.is_false(l.scrollbar:IsShown(), "a scrollbar at 3 rows")
	end)

	it("sizes the box to its rows, capped at a share of the tab, and never below one row", function()
		Browse:Open("shoppingsetup")
		local l = UICL.OnListList
		local pad = TOGBankClassic_UI:UIScaled(UICL.SETUP_BOX_PAD) * 2 + UICL.SETUP_BOX_SLACK
		local one = l.headerHeight + l.rowHeight + pad
		assert.equal(one, UICL:SetupBoxHeight(0), "an empty list lost its box")
		assert.equal(l.headerHeight + 3 * l.rowHeight + pad, UICL:SetupBoxHeight(3))
		local body = UICL.SetupBox:GetParent()
		body:SetHeight(400)
		local capped = UICL:SetupBoxHeight(500)
		assert.is_true(capped <= 400 * UICL.SETUP_BOX_SHARE + l.rowHeight, "the box grew past its share of the tab")
		assert.is_true(capped >= l.headerHeight + UICL.SETUP_BOX_MIN_ROWS * l.rowHeight + pad)
	end)

	-- Peer Review on 3197046a, F4(a): the item branch of the search, on the REAL LibItemDB with its
	-- shipped Vanilla Miscellaneous and enUS name data (craftlist_spec's F2 loading).
	it("finds an item by name through the real LibItemDB, marks it Item, and a click puts it on the list", function()
		local libs = require("env.libs")
		if not libs.available("LibItemDB-1.0") then pending("ItemDB is not installed beside this addon") end
		libs.fresh("LibItemDB-1.0")
		local ok, err = pcall(function()
			for _, part in ipairs({ "_core/Miscellaneous", "enUS/Names" }) do
				wow.loadAddonFile(libs.pathOf("LibItemDB-1.0", "Data/Vanilla/" .. part .. ".lua"), "ItemDB")
			end
			Browse:Open("shoppingsetup")
			UICL.setupFilter.text = "sea snail"
			UICL.setupFilter.count = 6
			UICL:Draw("shoppingsetup")
			local shell
			for _, r in ipairs(UICL.setupRowsShown) do if r.key == "i10457" then shell = r end end
			assert.is_table(shell, "LibItemDB's search did not find Empty Sea Snail Shell")
			assert.equal("Item", shell.kind)
			assert.equal("Empty Sea Snail Shell", shell.plainName)
			UICL:OnSetupRowClick(shell, "LeftButton")
			assert.equal(6, CL:GetList()["i10457"].n)
			-- ITEM-SEARCH-001 (the operator 2026-09-26: "why don't we just have the itemdb searchable
			-- on the GSL add list?"): a profession narrows the RECIPES; the items stay searchable.
			UICL.setupFilter.prof = tostring(ALCHEMY)
			UICL:Draw("shoppingsetup")
			local still
			for _, r in ipairs(UICL.setupRowsShown) do if r.key == "i10457" then still = r end end
			assert.is_table(still, "picking a profession hid the item search")
			for _, r in ipairs(UICL.setupRowsShown) do
				if r.recipe then assert.equal(ALCHEMY, r.recipe.profId, "a recipe from another profession") end
			end
		end)
		libs.forget("LibItemDB-1.0")
		_G.LibItemDB_PriceDB = nil
		assert(ok, err)
	end)

	-- ITEM-SEARCH-001: the operator's own case -- the E'kos (Quest items) that the Juju hand-ins take,
	-- found through the REAL LibItemDB with its shipped Quest data, with a profession picked.
	it("finds the E'kos through the real LibItemDB, even with a profession picked", function()
		local libs = require("env.libs")
		if not libs.available("LibItemDB-1.0") then pending("ItemDB is not installed beside this addon") end
		libs.fresh("LibItemDB-1.0")
		local ok, err = pcall(function()
			for _, part in ipairs({ "_core/Quest", "enUS/Names" }) do
				wow.loadAddonFile(libs.pathOf("LibItemDB-1.0", "Data/Vanilla/" .. part .. ".lua"), "ItemDB")
			end
			Browse:Open("shoppingsetup")
			UICL.setupFilter.text = "e'ko"
			UICL.setupFilter.prof = tostring(ALCHEMY)
			UICL:Draw("shoppingsetup")
			local found = {}
			for _, r in ipairs(UICL.setupRowsShown) do if r.itemID then found[r.itemID] = r end end
			for id = 12430, 12436 do assert.is_table(found[id], "E'ko " .. id .. " was not found") end
			assert.equal("Frostsaber E'ko", found[12430].plainName)
			UICL:OnSetupRowClick(found[12430], "LeftButton")
			assert.equal(1, CL:GetList()["i12430"].n)
		end)
		libs.forget("LibItemDB-1.0")
		_G.LibItemDB_PriceDB = nil
		assert(ok, err)
	end)

	-- F4(b): the gather window's two pickers, driven as the widget fires them.
	it("the gather pickers set the window, and an end before the start is refused and said", function()
		Browse:Open("shoppingsetup")
		assert.is_table(UICL.GatherFrom, "the date pickers were not built")
		UICL.GatherFrom:Fire("OnValueChanged", Browse:ParseDate("2026-10-01"))
		UICL.GatherUntil:Fire("OnValueChanged", Browse:ParseDate("2026-10-08"))
		assert.same({ "2026-10-01", "2026-10-08" }, { CL:GetGatherWindow() })
		UICL.GatherUntil:Fire("OnValueChanged", Browse:ParseDate("2026-09-01"))
		assert.same({ "2026-10-01", "2026-10-08" }, { CL:GetGatherWindow() })
		assert.truthy(Browse.statusText:find("end cannot be before the start", 1, true))
		UICL.GatherUntil:Fire("OnValueChanged", nil)   -- cleared: open-ended
		assert.same({ "2026-10-01", "" }, { CL:GetGatherWindow() })
	end)

	it("a member who opens it anyway can change nothing, and is told so", function()
		Browse:Open("shoppingsetup")
		me = MEMBER
		UICL.setupFilter.text = "fortitude"
		UICL:Draw("shoppingsetup")
		UICL:OnSetupRowClick(UICL.setupRowsShown[1], "LeftButton")
		assert.same({}, CL:GetList())
		assert.equal(UICL.NOT_ALLOWED_TEXT, Browse.statusText, "the refusal did not name its reason")
		-- The same click from the GM on a count the list already holds says "no change", not "not allowed".
		me = GM
		UICL.setupFilter.count = 1
		UICL:OnSetupRowClick(UICL.setupRowsShown[1], "LeftButton")
		UICL:OnSetupRowClick(UICL.setupRowsShown[1], "LeftButton")
		assert.truthy(Browse.statusText:find("already wants that many", 1, true))
	end)

	it("the help text is the shopping list's own on both tabs", function()
		Browse:Open("shoppingsetup")
		GameTooltip:ClearLines()
		Browse:AddHelpLines()
		local text = {}
		for _, l in ipairs(GameTooltip:GetLines()) do text[#text + 1] = l.left or "" end
		text = table.concat(text, "\n")
		assert.truthy(text:find("Shopping List", 1, true))
		assert.truthy(text:find("How many", 1, true))
	end)
end)
