-- BROWSE-001 -- the guild bank as one list, with the bankers as a column.
--
-- crimsonmane (Discord, 2026-09-07): browsing tab-by-tab is "a wall of icons which carry very
-- little meaning"; the operator: "make it look more like the FGI's scan tab in layout ... 'filter
-- stuff' across the top, and rows of things across the bottom, then a banker tab", "requests
-- isn't a separate window, it's just another tab", "follow the look and feel of FGI, with the
-- zebra stripped rows ... the same font size/style".
--
-- Three layers, specced apart: the ROW LIST (FGI's, ported: banding, header, sort, virtual
-- scroll), the DATA (rows from the same accessor every window reads, the filters, the banker
-- summary), and the WINDOW (tabs, the filter strip, the wiring into the rest of the addon).
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local G = "Testguild"

-- ─── The row list ───────────────────────────────────────────────────────────────

describe("BROWSE-001: the row list (FGI's, ported)", function()
	local RowList, parent

	before_each(function()
		env.reset(); env.stubOutput()
		require("env.frames").reset()
		env.loadFile("Modules/UI/RowList.lua")
		RowList = TOGBankClassic_UI_RowList
		parent = CreateFrame("Frame", nil, UIParent)
		parent:SetSize(400, 20 + 16 * 5)   -- header + five rows
	end)

	local COLS = {
		{ key = "icon", header = "", width = 16, icon = true, sortable = false },
		{ key = "name", header = "Item" },
		{ key = "qty",  header = "Qty", width = 40, justify = "RIGHT" },
	}

	local function rows(n)
		local out = {}
		for i = 1, n do out[i] = { icon = 100 + i, name = "Item " .. string.char(64 + i), qty = i, _id = tostring(i) } end
		return out
	end

	it("keeps FGI's visual contract: 16px rows, every second row banded at 4% white, a 20px header at 8% with a gold rule", function()
		assert.equal(16, RowList.ROW_HEIGHT)
		assert.equal(20, RowList.HEADER_HEIGHT)
		assert.equal(0.04, RowList.BAND_ALPHA)
		assert.equal(0.08, RowList.HEADER_ALPHA)
		local rl = RowList:New(parent, { columns = COLS })
		rl:SetData(rows(3))
		assert.equal(5, rl.visibleRowCount, "the pool is not sized to the parent's height minus the header")
		-- Band on even rows only: an even row carries one more region (the band texture) than an
		-- odd one, built at pool time.
		assert.equal(rl.rows[1]:GetNumRegions() + 1, rl.rows[2]:GetNumRegions(), "row 2 has no band, or row 1 has one")
		assert.equal(rl.rows[1]:GetNumRegions(), rl.rows[3]:GetNumRegions())
		assert.equal(16, rl.rows[1]:GetHeight())
		assert.equal(20, rl.header:GetHeight())
		-- FGI's fonts: GameFontHighlightSmall cells, GameFontNormalSmall headers.
		assert.same({ "GameFontHighlightSmall" }, rl.rows[1].cells.name._templates)
		assert.same({ "GameFontNormalSmall" }, rl.headerCells.name.fs._templates)
		-- Header text is the addon's gold.
		assert.equal("|cffffd100Item|r", rl.headerCells.name.fs:GetText())
	end)

	it("renders the visible window of the data, hides the rest, and shows the scrollbar only when it must", function()
		local rl = RowList:New(parent, { columns = COLS })
		rl:SetData(rows(3))
		assert.equal("Item A", rl.rows[1].cells.name:GetText())
		assert.equal("3", rl.rows[3].cells.qty:GetText())
		assert.is_true(rl.rows[3]:IsShown())
		assert.is_false(rl.rows[4]:IsShown(), "an empty pool row is shown")
		assert.is_false(rl.scrollbar:IsShown(), "the scrollbar shows when everything fits")
		assert.equal(101, rl.rows[1].cells.icon:GetTexture())

		rl:SetData(rows(12))
		assert.is_true(rl.scrollbar:IsShown())
		local _, maxOffset = rl.scrollbar:GetMinMaxValues()
		assert.equal(7, maxOffset, "12 rows, 5 visible: 7 offsets")
		rl.scrollbar:SetValue(7)
		assert.equal(7, rl.listOffset)
		assert.equal("Item H", rl.rows[1].cells.name:GetText(), "scrolling did not move the window")
		assert.equal("Item L", rl.rows[5].cells.name:GetText())
		-- The wheel drives the bar.
		parent:Fire("OnMouseWheel", 1)
		assert.equal(6, rl.listOffset)
	end)

	it("grows the pool when the parent gets taller, and re-renders", function()
		local rl = RowList:New(parent, { columns = COLS })
		rl:SetData(rows(12))
		assert.equal(5, #rl.rows)
		parent:SetHeight(20 + 16 * 10)
		parent:Fire("OnSizeChanged")
		assert.equal(10, #rl.rows, "the pool did not grow")
		assert.equal(10, rl.visibleRowCount)
		assert.is_true(rl.rows[10]:IsShown())
		assert.equal("Item J", rl.rows[10].cells.name:GetText())
	end)

	it("sorts on a header click -- ascending, then descending -- numerically for numbers, case-blind for text, and via _sort_ overrides", function()
		local rl = RowList:New(parent, { columns = COLS })
		local data = rows(3)
		data[1].name, data[1]._sort_name = "|cffff0000zed|r", "zed"
		data[2].name, data[2]._sort_name = "Apple", "apple"
		data[3].name, data[3]._sort_name = "mango", "mango"
		rl:SetData(data)
		rl.headerCells.name.btn:Fire("OnClick")
		assert.equal("name", rl.sortKey); assert.is_false(rl.sortDesc)
		assert.equal("Apple", rl.rows[1].cells.name:GetText())
		assert.equal("mango", rl.rows[2].cells.name:GetText())
		assert.equal("|cffff0000zed|r", rl.rows[3].cells.name:GetText(), "the colour-coded display text was sorted instead of the plain override")
		assert.is_true(rl.headerCells.name.arrow:IsShown(), "no sort arrow on the active column")
		rl.headerCells.name.btn:Fire("OnClick")
		assert.is_true(rl.sortDesc)
		assert.equal("|cffff0000zed|r", rl.rows[1].cells.name:GetText())
		rl.headerCells.qty.btn:Fire("OnClick")
		assert.equal("qty", rl.sortKey)
		assert.is_false(rl.headerCells.name.arrow:IsShown(), "the arrow stayed on the old column")
		assert.equal("1", rl.rows[1].cells.qty:GetText())
		-- The icon column opted out of sorting.
		assert.is_nil(rl.headerCells.icon.btn:GetScript("OnClick"))
	end)

	it("with no auto column, chains every column from the right edge, rightmost first", function()
		local rl = RowList:New(parent, { columns = {
			{ key = "a", header = "A", width = 50 },
			{ key = "b", header = "B", width = 30 },
		} })
		assert.is_nil(rl:_autoIndex())
		rl:SetData(rows(1))
		local _, _, rp, x = rl.rows[1].cells.b:GetPoint(1)
		assert.equal("RIGHT", rp); assert.equal(-RowList.COL_GAP, x)
		local _, _, rpA, xA = rl.rows[1].cells.a:GetPoint(1)
		assert.equal("RIGHT", rpA); assert.equal(-(RowList.COL_GAP + 30 + RowList.COL_GAP), xA)
		assert.equal(50, rl.rows[1].cells.a:GetWidth())
	end)

	it("hands a row click the entry, its index and the mouse button, and enter/leave the entry", function()
		local got, entered, left = {}, nil, 0
		local rl = RowList:New(parent, {
			columns = COLS,
			onRowClick = function(entry, idx, button) got = { entry.name, idx, button } end,
			onRowEnter = function(entry) entered = entry.name end,
			onRowLeave = function() left = left + 1 end,
		})
		rl:SetData(rows(12))
		rl.scrollbar:SetValue(2)
		rl.rows[2]:Fire("OnClick", "RightButton")
		assert.same({ "Item D", 4, "RightButton" }, got, "the click did not resolve through the scroll offset")
		assert.same({ "LeftButtonUp", "RightButtonUp" }, rl.rows[2]._clickTypes)
		rl.rows[1]:Fire("OnEnter")
		assert.equal("Item C", entered)
		rl.rows[1]:Fire("OnLeave")
		assert.equal(1, left)
	end)

	it("keeps the scroll position on a preserving SetData, clamped to the new length", function()
		local rl = RowList:New(parent, { columns = COLS })
		rl:SetData(rows(12))
		rl.scrollbar:SetValue(7)
		rl:SetData(rows(12), true)
		assert.equal(7, rl.listOffset, "a preserving refresh jumped to the top")
		rl:SetData(rows(8), true)
		assert.equal(3, rl.listOffset, "the offset was not clamped to the shorter data")
		rl:SetData(rows(12))
		assert.equal(0, rl.listOffset, "a plain SetData did not return to the top")
	end)
end)

-- ─── The data ───────────────────────────────────────────────────────────────────

local function stubItemDB(items)
	LibStub.libs["LibItemDB-1.0"] = {
		HasItem = function(_, id) return items[id] ~= nil end,
		GetInfo = function(_, id)
			local d = items[id]
			if not d then return nil end
			return d.name, d.quality, d.class, d.subClass, d.equipLoc, d.itemLevel
		end,
		GetSuffixLink = function(_, id) return "|cffffffff|Hitem:" .. id .. "|h[" .. items[id].name .. "]|h|r" end,
		GetRequiredLevel = function(_, id) return items[id] and items[id].reqLevel or 0 end,
	}
	LibStub.minors["LibItemDB-1.0"] = 15
end

local ITEMS = {
	[2589]  = { name = "Linen Cloth",   quality = 1, class = 7, subClass = 0, equipLoc = "",             itemLevel = 5,  reqLevel = 0 },
	[19019] = { name = "Thunderfury",   quality = 5, class = 2, subClass = 7, equipLoc = "INVTYPE_WEAPON", itemLevel = 80, reqLevel = 60 },
	[10132] = { name = "Spiked Club",   quality = 2, class = 2, subClass = 4, equipLoc = "INVTYPE_WEAPON", itemLevel = 20, reqLevel = 15 },
	[2575]  = { name = "Red Linen Shirt", quality = 1, class = 4, subClass = 0, equipLoc = "INVTYPE_BODY", itemLevel = 10, reqLevel = 0 },
	[7048]  = { name = "Robe of Power", quality = 2, class = 4, subClass = 1, equipLoc = "INVTYPE_ROBE", itemLevel = 33, reqLevel = 28 },
}

local ALICE, BOB, VIEW = "Alice-Testrealm", "Bob-Testrealm", "Viewonly-Testrealm"

local Browse, Store, Record

--- Real Store, Record, Resolve, Search's filter lists and the Browse module; a Guild stub whose
--- accessors read the store the way the real ones do.
local function loadBrowse(opts)
	opts = opts or {}
	env.stubOutput()
	stubItemDB(ITEMS)
	-- The addon's search box library: SearchMatch is per-word through it, substring without.
	local libs = require("env.libs")
	libs.load("LibAceGUIWidgets-1.0")
	-- LOG-FILTER-002: the date picker is a satellite file the harness manifest does not list yet
	-- (WoWAPITesting thread 1a7caf76); until it does, load it the way the manifest will.
	local satellite = loadfile(libs.pathOf("LibAceGUIWidgets-1.0", "LibAceGUIWidgets-DatePicker.lua"))
	assert(satellite, "LibAceGUIWidgets-DatePicker.lua is not beside the library")
	satellite("LibAceGUIWidgets", {})
	env.loadFile("Modules/Constants.lua")
	env.loadModules({ "Modules/Inventory/Record.lua", "Modules/Inventory/Resolve.lua", "Modules/Inventory/Store.lua" })
	-- HIDDEN-MERGE-001: the rows a window draws come from the REAL Guild:GetAltItemsWithOwnHidden,
	-- lifted off the real module onto the steerable stub below, so the merge under test is the
	-- shipped one and not a copy of it. Guild.lua needs Item.lua loaded first.
	env.loadModules({ "Modules/Item.lua", "Modules/Guild.lua" })
	local realWithOwnHidden = TOGBankClassic_Guild.GetAltItemsWithOwnHidden
	assert(type(realWithOwnHidden) == "function", "Guild:GetAltItemsWithOwnHidden is missing")
	env.loadUI()
	env.loadFile("Modules/UI/Search.lua")
	env.loadFile("Modules/UI/RowList.lua")
	env.loadFile("Modules/Usable.lua")
	env.loadFile("Modules/UI/Browse.lua")
	Browse, Store, Record = TOGBankClassic_UI_Browse, TOGBankClassic_Inventory_Store, TOGBankClassic_Inventory_Record
	-- The usable gate's outside edges: no tooltip data offline, and a warrior (every proficiency)
	-- unless an example says otherwise.
	TOGBankClassic_Usable.TooltipTexts = function() return nil end
	_G.UnitClass = function() return "Warrior", "WARRIOR", 1 end
	TOGBankClassicInvDB = nil
	Store.db = nil
	Store:Init()
	Store:InvalidateView()
	local states = opts.states or {}
	local online = opts.online or {}
	TOGBankClassic_Guild = {
		Info = { name = G, alts = { [ALICE] = {}, [BOB] = {}, [VIEW] = {} }, roster = { alts = { ALICE, BOB, VIEW } } },
		GetRosterAlts = function(self) return { unpack(self.Info.roster.alts) } end,
		NormalizeName = function(_, n) return n and (n:find("-") and n or n .. "-Testrealm") or nil end,
		GetNormalizedPlayer = function() return opts.me or "Someone-Testrealm" end,
		IsBank = function(_, n) return n == ALICE or n == BOB or n == VIEW end,
		IsViewOnlyBank = function(_, n) return n == VIEW end,
		IsPlayerOnline = function(_, n) return online[n] == true end,
		GetAltStaleness = function(_, n)
			local s = states[n] or { "current", 1757000000, 1757000000 }
			return s[1], s[2], s[3], s[4], s[5]
		end,
		GetAltItems = function(_, n) return Store:GetAltView(G, n) end,
		GetAltItemsWithOwnHidden = realWithOwnHidden,
	}
	TOGBankClassic_Bank = TOGBankClassic_Bank or {}
	TOGBankClassic_Options = { db = { global = {}, char = {} } }
	Browse:Init()
	Browse.filters = { bank = "any", type = "any", subtype = "any", slot = "any", quality = "any" }
	return Browse
end

local function stock()
	Store:SetAltRecords(G, ALICE, { Record.new(2589, 40), Record.new(19019, 1), Record.new(2575, 2) }, 12345)
	Store:SetAltRecords(G, BOB,   { Record.new(2589, 5),  Record.new(10132, 1, 863), Record.new(7048, 1) }, 0)
	Store:SetAltRecords(G, VIEW,  { Record.new(2589, 100) }, 999999)
end

local function names(rows)
	local out = {}
	for _, r in ipairs(rows) do out[#out + 1] = r.plainName .. "@" .. r.player end
	table.sort(out)
	return out
end

describe("BROWSE-001: the rows", function()
	before_each(function()
		env.reset()
		-- The rich frame model BEFORE the widget library loads, in every describe of this file:
		-- Ace3's widget files capture `local CreateFrame = CreateFrame` at file scope and are loaded
		-- once per Lua state, so whichever spec loads them first fixes the binding for the whole
		-- run. Loaded here under the hollow env, every later window spec in the suite would build
		-- hollow AceGUI frames (statusbg:CreateFontString -> nil) -- found as this file's own window
		-- describe failing when run after this one.
		require("env.frames").reset()
		loadBrowse({ states = { [BOB] = { "behind", 1756000000, 1757000000 } } })
		stock()
	end)

	it("is one row per banker per item variant, from the same accessor every window reads", function()
		local rows = Browse:BuildRows()
		assert.equal(7, #rows)
		assert.same({
			"Linen Cloth@Alice-Testrealm", "Linen Cloth@Bob-Testrealm", "Linen Cloth@Viewonly-Testrealm",
			"Red Linen Shirt@Alice-Testrealm", "Robe of Power@Bob-Testrealm", "Spiked Club@Bob-Testrealm",
			"Thunderfury@Alice-Testrealm",
		}, names(rows))
		-- The accessor is Guild:GetAltItems, not a private read of the store.
		assert.truthy(env.readFile("Modules/UI/Browse.lua"):find("G:GetAltItems(norm)", 1, true))
	end)

	it("carries the columns: quality-coloured name, quantity, banker with the status dot, type text, required level", function()
		local byName = {}
		for _, r in ipairs(Browse:BuildRows()) do byName[r.plainName .. "@" .. r.player] = r end
		local tf = byName["Thunderfury@Alice-Testrealm"]
		assert.equal("|cffff8000Thunderfury|r", tf.name, "a legendary is not orange")
		assert.equal(1, tf.count)
		assert.equal("Weapon / Sword (1H)", tf.type)
		assert.equal(60, tf.level)
		assert.truthy(tf.bank:find("|cff00ff00", 1, true), "a current bank's dot is not green")
		assert.truthy(tf.bank:find("Alice-Testrealm", 1, true))
		local club = byName["Spiked Club@Bob-Testrealm"]
		assert.truthy(club.bank:find("|cffff0000", 1, true), "a behind bank's dot is not red")
		assert.equal(863, club.Suffix, "the suffix the request dialog mints from was dropped")
		assert.equal("Weapon / Mace (1H)", club.type)
		local cloth = byName["Linen Cloth@Viewonly-Testrealm"]
		assert.equal("Trade Goods", cloth.type, "'Trade Goods / Trade Goods' says it twice")
		assert.is_true(cloth.viewOnly)
		assert.truthy(cloth.bank:find("(view)", 1, true))
		assert.equal(0, cloth.level)
		-- The sort keys are the plain values, not the colour codes.
		assert.equal("thunderfury", tf._sort_name)
		assert.equal("alice-testrealm", tf._sort_bank)
	end)

	it("resolves the armour slot from the store's numeric equipId through Search's slot map", function()
		local byName = {}
		for _, r in ipairs(Browse:BuildRows()) do byName[r.plainName] = r end
		assert.equal("chest", byName["Robe of Power"].slot, "INVTYPE_ROBE did not collapse to chest")
		-- A shirt (INVTYPE_BODY) is not one of Search's filterable slots, so it has none.
		assert.is_nil(byName["Red Linen Shirt"].slot)
		assert.is_nil(byName["Linen Cloth"].slot)
	end)

	it("filters by bank, type, subtype, slot, quality, level range, usable-by-me and the search box, each on its own and together", function()
		local all = Browse:BuildRows()
		local function f(over)
			local base = { bank = "any", type = "any", subtype = "any", slot = "any", quality = "any" }
			for k, v in pairs(over) do base[k] = v end
			return names(Browse:FilterRows(all, base))
		end
		assert.equal(7, #f({}))
		assert.same({ "Linen Cloth@Bob-Testrealm", "Robe of Power@Bob-Testrealm", "Spiked Club@Bob-Testrealm" }, f({ bank = BOB }))
		assert.same({ "Spiked Club@Bob-Testrealm", "Thunderfury@Alice-Testrealm" }, f({ type = "2" }))
		assert.same({ "Spiked Club@Bob-Testrealm" }, f({ type = "2", subtype = "4" }))
		assert.same({ "Robe of Power@Bob-Testrealm" }, f({ type = "4", slot = "chest" }))
		assert.same({ "Thunderfury@Alice-Testrealm" }, f({ quality = "5" }))
		assert.same({ "Robe of Power@Bob-Testrealm", "Thunderfury@Alice-Testrealm" }, f({ minLevel = 20 }))
		assert.same({ "Spiked Club@Bob-Testrealm" }, f({ minLevel = 1, maxLevel = 20 }))
		_G.UnitLevel = function() return 30 end
		Browse.TooltipLines = function() return {} end
		assert.equal(6, #f({ usable = true }), "a level-60 item passed usable-by-me at level 30")
		assert.same({ "Linen Cloth@Alice-Testrealm", "Linen Cloth@Bob-Testrealm", "Linen Cloth@Viewonly-Testrealm" }, f({ text = "linen cloth" }))
		assert.same({ "Linen Cloth@Bob-Testrealm", "Robe of Power@Bob-Testrealm", "Spiked Club@Bob-Testrealm" }, f({ text = "bob" }), "the search does not match the banker column")
		assert.same({ "Spiked Club@Bob-Testrealm", "Thunderfury@Alice-Testrealm" }, f({ text = "weapon" }), "the search does not match the type column")
		assert.same({ "Spiked Club@Bob-Testrealm" }, f({ text = "weapon bob" }), "every word must match")
		assert.equal(7, #f({ text = "   " }), "a blank search filtered something out")
		assert.equal(7, #Browse:FilterRows(all, nil), "no filters at all filtered something out")
	end)

	-- writ-cannot: the two examples that stood here ("usable-by-me reads the item's tooltip: a red
	-- requirement line hides it" and "the default tooltip reader scans a hidden tooltip") covered
	-- Browse.TooltipLines, a red-line tooltip scan that was REMOVED on purpose an hour after it was
	-- written: on a live Classic Era client it let a hunter see maces as usable (the operator:
	-- "the usable by me filter still isn't working. as a hunter i can't use hammers"). The feature
	-- they pinned no longer exists; its replacement, the data-driven gate in Modules/Usable.lua, is
	-- pinned by Tests/usable_spec.lua, and its join into the filter by the example below.
	it("usable-by-me is the class's proficiency, not the level alone: a hunter sees no mace, nor does a mage", function()
		_G.UnitLevel = function() return 60 end
		_G.UnitClass = function() return "Hunter", "HUNTER", 3 end
		local all = Browse:BuildRows()
		local base = { bank = "any", type = "any", subtype = "any", slot = "any", quality = "any", usable = true }
		local shown = names(Browse:FilterRows(all, base))
		assert.equal(6, #shown)
		for _, n in ipairs(shown) do assert.is_nil(n:find("Spiked Club", 1, true), "a hunter was shown a mace as usable") end
		-- The row carries what the gate reads: the item's INVTYPE token beside the store's slot key.
		for _, r in ipairs(all) do if r.plainName == "Robe of Power" then assert.equal("INVTYPE_ROBE", r.equipLoc) end end
		_G.UnitClass = function() return "Mage", "MAGE", 8 end
		shown = names(Browse:FilterRows(all, base))
		assert.same({ "Linen Cloth@Alice-Testrealm", "Linen Cloth@Bob-Testrealm", "Linen Cloth@Viewonly-Testrealm",
			"Red Linen Shirt@Alice-Testrealm", "Robe of Power@Bob-Testrealm", "Thunderfury@Alice-Testrealm" }, shown)
		-- Level still gates first: at 10 nothing above it shows, whatever the class.
		_G.UnitLevel = function() return 10 end
		assert.same({ "Linen Cloth@Alice-Testrealm", "Linen Cloth@Bob-Testrealm", "Linen Cloth@Viewonly-Testrealm", "Red Linen Shirt@Alice-Testrealm" },
			names(Browse:FilterRows(all, base)))
		-- Without the module (a load-order slip) the filter passes everything rather than erroring.
		TOGBankClassic_Usable = nil
		assert.equal(7, #Browse:FilterRows(all, base))
	end)

	it("summarises the bankers: online, status in words and colour, when published, items, money", function()
		env.now = 1757000000 + 3600
		local rows = Browse:BankerRows()
		assert.equal(3, #rows)
		local by = {}
		for _, r in ipairs(rows) do by[r.player] = r end
		assert.equal("|cff00ff00Current|r", by[ALICE].status)
		assert.equal("|cffff0000Behind|r", by[BOB].status)
		assert.equal(3, by[ALICE].items)
		assert.equal(12345, by[ALICE].moneyCopper)
		assert.truthy(by[ALICE].money:find("1g", 1, true) or by[ALICE].money:find("12345", 1, true))
		assert.equal("|cff808080no|r", by[ALICE].online)
		assert.truthy(by[ALICE].published:find("ago", 1, true))
		assert.truthy(by[VIEW].name:find("(view only)", 1, true))
		assert.equal(1756000000, by[BOB]._sort_published)
	end)

	it("says 'never' for a bank that has not published", function()
		require("env.frames").reset()
		loadBrowse({ states = { [ALICE] = { "none", 0, 0 } } })
		stock()
		local by = {}
		for _, r in ipairs(Browse:BankerRows()) do by[r.player] = r end
		assert.equal("never", by[ALICE].published)
		assert.equal("|cff808080No data|r", by[ALICE].status)
	end)

	-- TAB-STATE-003: the grey state -- a newer copy held only where this release cannot fetch it --
	-- reads as such in the Status column, and the row's hover names the peer and its version in the
	-- ONE sentence the Inventory window's tab tooltip also uses.
	it("shows a newer copy that only an old-release peer holds as grey 'Newer copy unreachable', with the peer and version on hover", function()
		require("env.frames").reset()
		loadBrowse({ states = { [ALICE] = { "refused", 1756000000, 0, "Oldguy-Testrealm", "TOGBankClassic-v1.4.1" } } })
		stock()
		local by = {}
		for _, r in ipairs(Browse:BankerRows()) do by[r.player] = r end
		assert.equal("|cffa0a0a0Newer copy unreachable|r", by[ALICE].status)
		assert.equal("Oldguy-Testrealm", by[ALICE].refusedPeer); assert.equal("TOGBankClassic-v1.4.1", by[ALICE].refusedVersion)
		assert.is_nil(by[BOB].refusedPeer)
		local text = Browse.RefusedText(by[ALICE].refusedPeer, by[ALICE].refusedVersion)
		assert.truthy(text:find("Oldguy-Testrealm", 1, true)); assert.truthy(text:find("1.4.1", 1, true))
		assert.truthy(text:find("cannot send it to this release", 1, true))
		assert.truthy(text:find("an older version", 1, true) == nil)
		assert.truthy(Browse.RefusedText(nil, nil):find("an older version", 1, true))
		-- The hover on the Bankers list is that sentence, and only for the grey row.
		TOGBankClassic_UI_StatusBar = { AttachSides = function() return {} end }
		TOGBankClassic_UI_Requests = { Embed = function() end, Detach = function() end, AddHelpLines = function() end }
		Browse:Open("bankers")
		local list = Browse.BankerList
		assert.is_function(list.onRowEnter, "the Bankers list has no row hover")
		local shown
		rawset(GameTooltip, "SetText", function(_, t) shown = t end)   -- the hollow tooltip has no GetText
		_G.GameTooltip_SetDefaultAnchor = _G.GameTooltip_SetDefaultAnchor or function() end   -- harness gap (audit 1ebe87b4 F5)
		list.onRowEnter(by[ALICE])
		assert.equal(text, shown)
		list.onRowLeave(by[ALICE])
		shown = nil
		list.onRowEnter(by[BOB])
		assert.is_nil(shown, "a row that is not grey got the grey sentence")
		Browse:Close()
		TOGBankClassic_UI_Browse, TOGBankClassic_UI_Requests, TOGBankClassic_UI_StatusBar = nil, nil, nil
	end)
end)

-- ─── The window ─────────────────────────────────────────────────────────────────

describe("BROWSE-001: the window", function()
	before_each(function()
		env.reset()
		require("env.frames").reset()
		loadBrowse({ me = ALICE, states = { [BOB] = { "behind", 1756000000, 1757000000 } } })
		stock()
		TOGBankClassic_UI_StatusBar = { AttachSides = function() return {} end }
		TOGBankClassic_UI_Requests = {
			Embed = function(self, host, chrome, anchor) self.embedded = { host = host, chrome = chrome, anchor = anchor } end,
			-- Like the real one: nothing to do unless embedded.
			Detach = function(self) if self.embedded then self.detached = (self.detached or 0) + 1; self.embedded = nil end end,
			AddHelpLines = function() GameTooltip:AddLine("REQUESTS HELP") end,
		}
	end)

	after_each(function()
		TOGBankClassic_UI_Browse = nil
		TOGBankClassic_UI_Requests = nil
		TOGBankClassic_UI_StatusBar = nil
	end)

	it("opens on the Browse tab with the filter strip and every row, titled like the other windows", function()
		Browse:Open()
		assert.is_true(Browse.isOpen)
		assert.equal("browse", Browse.currentTab)
		assert.truthy(Browse.Window.titletext:GetText():find("Guild Bank", 1, true))
		assert.equal(7, #Browse.rowsShown)
		assert.is_true(Browse.BrowseList.parent:IsShown())
		assert.is_false(Browse.BankerList.parent:IsShown())
		assert.equal("Item", Browse.BROWSE_COLUMNS[2].header)
		-- Wired like every other window: its transparency key and the shared status bar.
		local found
		for _, e in ipairs(TOGBankClassic_UI.ALPHA_WINDOWS) do if e.key == "browse" then found = e end end
		assert.is_not_nil(found, "no transparency slider for the Guild Bank window")
		assert.equal("TOGBankClassic_UI_Browse", found.module)
	end)

	it("narrows as the filters change, without a submit, and says so in the status text", function()
		Browse:Open()
		Browse.filters.type = "2"
		Browse:DrawBrowse()
		assert.equal(2, #Browse.rowsShown)
		assert.truthy(Browse.statusText:find("2 of 7", 1, true))
		Browse.filters.type = "any"
		Browse:DrawBrowse()
		assert.truthy(Browse.statusText:find("7 items across 3 banks", 1, true))
	end)

	it("switches to the Bankers tab, and a banker row click browses that bank", function()
		Browse:Open("bankers")
		assert.equal("bankers", Browse.currentTab)
		assert.is_true(Browse.BankerList.parent:IsShown())
		assert.is_false(Browse.BrowseList.parent:IsShown())
		assert.equal(3, #Browse.BankerList.data)
		assert.truthy(Browse.statusText:find("3 bankers, 2 current", 1, true))
		Browse:BrowseBank(BOB)
		assert.equal("browse", Browse.currentTab)
		assert.equal(BOB, Browse.filters.bank)
		assert.equal(3, #Browse.rowsShown)
	end)

	-- BANKERS-FILTER-001: the operator, 2026-09-13: "add some filters to the top of the bankers tab
	-- like the browse tab? at a minimum we need the search filter ... it might be nice to be able to
	-- provide metadata for each banker, on the types of stuff they store". The metadata is the guild
	-- note beside the gbank marker; the strip is one search box over name, Stores and status.
	it("the Bankers tab has a search strip and a Stores column read from the banker's guild note", function()
		local G = TOGBankClassic_Guild
		-- Guild:BankerStores (the note-to-text rule) is guild_spec's; this stub answers what it would.
		local stores = { [ALICE] = "herbs & potions", [BOB] = "Raid mats", [VIEW] = "" }
		G.BankerStores = function(_, n) return stores[n] or "" end
		Browse:Open("bankers")
		-- The strip: one row, inset like Browse's, the list hung under it.
		assert.is_table(Browse.BankerStrip); assert.is_table(Browse.BankerSearch)
		assert.equal(Browse.BankerStrip, Browse.TabGroup.children[1])
		local sp, _, _, sx = Browse.BankerStrip.content:GetPoint(1)
		assert.equal("TOPLEFT", sp); assert.equal(8, sx)
		local _, _, _, _, ly = Browse.BankerList.parent:GetPoint(1)
		assert.equal(-Browse.SIMPLE_FILTER_H, ly, "the banker list does not start under the strip")
		local rows = Browse.BankerList.data
		assert.equal(3, #rows)
		local byNorm = {}
		for _, r in ipairs(rows) do byNorm[r.norm] = r end
		assert.equal("herbs & potions", byNorm[ALICE].stores)
		assert.equal("Raid mats", byNorm[BOB].stores)
		local col
		for _, c in ipairs(Browse.BANKER_COLUMNS) do if c.key == "stores" then col = c end end
		assert.is_table(col, "no Stores column"); assert.is_nil(col.width, "Stores is not the auto column")
		-- The search narrows by name, by what they store, and by status; the status line says so.
		Browse.BankerSearch:Fire("OnTextChanged", "herbs")
		assert.equal(1, #Browse.BankerList.data); assert.equal(ALICE, Browse.BankerList.data[1].norm)
		assert.truthy(Browse.statusText:find("1 of 3 bankers match", 1, true), Browse.statusText)
		Browse.BankerSearch:Fire("OnTextChanged", "bob")
		assert.equal(1, #Browse.BankerList.data); assert.equal(BOB, Browse.BankerList.data[1].norm)
		Browse.BankerSearch:Fire("OnTextChanged", "behind")
		assert.equal(1, #Browse.BankerList.data); assert.equal(BOB, Browse.BankerList.data[1].norm, "status text did not match")
		Browse.BankerSearch:Fire("OnTextChanged", "")
		assert.equal(3, #Browse.BankerList.data)
		assert.truthy(Browse.statusText:find("3 bankers, 2 current", 1, true))
	end)

	-- LOG-FILTER-001: "the filter search bar add it to the top of the logs as well, we'll need to
	-- search, and filter by start/stop date, filter by from, by to as well".
	-- LOG-FILTER-004: the From / To dropdowns are gone -- "the from and to filters on the log tab are
	-- going to be too unweildly. as long as the name is searchable and filters through the search
	-- bar, we can probably get rid of these two dropdown filters". A name in the search box is the
	-- filter, and a name whose first entry lands after the tab opened is found the same way.
	it("the Log tab has a strip: search (names included), Since and Until dates, and no From / To dropdowns", function()
		env.loadFile("Modules/Log.lua")
		local Log = TOGBankClassic_Log
		Log.callbacks = Log.callbacks or {}
		env.now = 1757003600   -- 2025-09-04 16:33 UTC-ish; the day boundary is what the dates test
		Log:RecordInventoryChange(BOB, { { ID = 2589, Count = 5 } }, { { ID = 2589, Count = 25 } }, 0, 0, 1757000000, nil, nil,
			{ ["2589:0"] = { { count = 20, from = "Donor-Testrealm" } } })
		Log:RecordRequestTransition(nil, { id = "r1", date = 1757003600, requester = "Asker-Testrealm", bank = BOB, item = "Linen Cloth", itemID = 2589, quantity = 3, fulfilled = 0, notes = "" })
		Log:RecordRequestTransition(nil, { id = "r2", date = 1756800000, requester = "Asker-Testrealm", bank = ALICE, item = "Wool Cloth", itemID = 2592, quantity = 1, fulfilled = 0, notes = "" })
		Browse:Open("log")
		assert.is_table(Browse.LogStrip)
		for _, w in ipairs({ "LogSearch", "LogSince", "LogUntil" }) do
			assert.is_table(Browse[w], "no " .. w .. " on the Log strip")
		end
		assert.is_nil(Browse.LogFrom); assert.is_nil(Browse.LogTo)
		assert.is_nil(Browse.LogNames); assert.is_nil(Browse.FillLogNameDropdown)
		assert.equal(3, #Browse.LogStrip.children, "the Log strip holds more than search, Since and Until")
		local _, _, _, _, ly = Browse.LogList.parent:GetPoint(1)
		assert.equal(-Browse.SIMPLE_FILTER_H, ly, "the log list does not start under the strip")
		assert.equal(3, #Browse.LogList.data)
		-- Search: every word must appear somewhere in from / action / item / to.
		Browse.LogSearch:Fire("OnTextChanged", "wool")
		assert.equal(1, #Browse.LogList.data); assert.equal("r2", Browse.LogList.data[1].entry.requestId)
		assert.truthy(Browse.statusText:find("1 of 3 recent entries match", 1, true), Browse.statusText)
		Browse.LogSearch:Fire("OnTextChanged", "donor deposited")
		assert.equal(1, #Browse.LogList.data); assert.equal("deposit", Browse.LogList.data[1].entry.type)
		-- LOG-FILTER-004: a NAME in the search box filters -- the From side, the To side, and both
		-- together (every word must match somewhere in the row).
		Browse.LogSearch:Fire("OnTextChanged", "asker")
		assert.equal(2, #Browse.LogList.data, "a requester's name in the search did not keep their two requests")
		Browse.LogSearch:Fire("OnTextChanged", "asker alice")
		assert.equal(1, #Browse.LogList.data); assert.equal("r2", Browse.LogList.data[1].entry.requestId)
		Browse.LogSearch:Fire("OnTextChanged", "bob")
		assert.equal(2, #Browse.LogList.data, "a banker's name did not match on both the From and the To side")
		Browse.LogSearch:Fire("OnTextChanged", "")
		assert.equal(3, #Browse.LogList.data)
		-- Since / Until: LOG-FILTER-002 -- the library's date pickers (a local-midnight timestamp or
		-- nil for no limit), a day inclusive at both ends.
		local DP = TOGBankClassic_UI.Widgets.DatePicker
		assert.is_not_nil(TOGBankClassic_UI:GetWidgetVersion("LAGW-DatePicker"), "the date picker widget is not registered")
		assert.equal("LAGW-DatePicker", Browse.LogSince.type); assert.equal("LAGW-DatePicker", Browse.LogUntil.type)
		-- LOG-FILTER-003: a click IN the field opens the calendar, not only the arrow button (the
		-- operator clicked the field and got nothing). The behaviour is the LIBRARY's (delivered on
		-- thread bb9c59be4d68, MINOR 28); this pins it from the consumer's side because the tooltip
		-- promises it. Driven through the field's own script; the arrow's OnClick still toggles.
		assert.is_false(Browse.LogSince:IsCalendarOpen())
		Browse.LogSince.editbox:GetScript("OnMouseDown")(Browse.LogSince.editbox, "LeftButton")
		assert.is_true(Browse.LogSince:IsCalendarOpen(), "a click in the Since field did not open its calendar")
		Browse.LogSince.editbox:GetScript("OnMouseDown")(Browse.LogSince.editbox, "LeftButton")
		assert.is_true(Browse.LogSince:IsCalendarOpen(), "a second click in the field closed the calendar it had just opened")
		Browse.LogSince.button:GetScript("OnClick")(Browse.LogSince.button)
		assert.is_false(Browse.LogSince:IsCalendarOpen(), "the arrow no longer toggles the calendar closed")
		local depositDay, olderDay = DP.snap(1757000000), DP.snap(1756800000)
		Browse.LogSince:Fire("OnValueChanged", depositDay)
		local n = #Browse.LogList.data
		assert.is_true(n >= 2 and n <= 3, "since the deposit's day should keep the deposit and the newer request")
		for _, r in ipairs(Browse.LogList.data) do assert.is_true(r._sort_when >= depositDay) end
		Browse.LogUntil:Fire("OnValueChanged", olderDay)
		assert.equal(0, #Browse.LogList.data, "a since after the until should keep nothing")
		Browse.LogSince:Fire("OnValueChanged", nil)
		assert.equal(1, #Browse.LogList.data); assert.equal("r2", Browse.LogList.data[1].entry.requestId)
		Browse.LogUntil:Fire("OnValueChanged", nil)
		assert.equal(3, #Browse.LogList.data)
		-- The filter's value survives a strip rebuild through the widget's SetValue (fires nothing).
		Browse.logFilter.since = depositDay
		Browse:Open("browse"); Browse:Open("log")
		assert.equal(depositDay, Browse.LogSince:GetValue(), "a rebuilt strip lost the picked day")
		Browse.logFilter.since = nil
		-- LOG-FILTER-004: a name whose first entry lands AFTER the tab opened is searchable on the
		-- next draw, with nothing to rebuild (the dropdowns this once had to keep in step are gone).
		Browse.LogSearch:Fire("OnTextChanged", "newcomer")
		assert.equal(0, #Browse.LogList.data)
		Log:RecordRequestTransition(nil, { id = "r3", date = 1757003700, requester = "Newcomer-Testrealm", bank = BOB, item = "Silk Cloth", itemID = 4306, quantity = 1, fulfilled = 0, notes = "" })
		Browse:DrawLog()
		assert.equal(1, #Browse.LogList.data); assert.equal("r3", Browse.LogList.data[1].entry.requestId)
		Browse.LogSearch:Fire("OnTextChanged", "")
		-- ParseDate: a number passes through; text is the LIBRARY's rule (one spelling of "a date").
		assert.equal(depositDay, Browse:ParseDate(depositDay))
		assert.is_nil(Browse:ParseDate("not a date")); assert.is_nil(Browse:ParseDate(""))
		assert.equal(DP.parse("2026-09-13"), Browse:ParseDate("2026-09-13"))
		assert.equal(Browse:ParseDate("2026-09-13"), Browse:ParseDate("2026-09-13 14:30"), "a typed time is dropped: the filter is by day")
	end)

	-- LOG-TAB-001: the operator: "for the bank log, lets add a bank log tab, perfect thing to add to
	-- our new window." The REAL log module records the entries; the tab reads them newest first,
	-- says whose, what, how many, with whom; an item hover shows its tooltip; a new entry landing
	-- through the log's own callback repaints the tab while it is showing.
	it("has a Log tab: the session's bank log as rows, newest first, repainted as entries land", function()
		env.loadFile("Modules/Log.lua")
		local Log = TOGBankClassic_Log
		Log.callbacks = Log.callbacks or {}
		env.now = 1757003600
		-- A deposit of 20 Linen Cloth and 100c on Bob, published an hour ago; a request placed now.
		local n = Log:RecordInventoryChange(BOB, { { ID = 2589, Count = 5 } }, { { ID = 2589, Count = 25 } }, 0, 100, 1757000000, nil, nil,
			{ ["2589:0"] = { { count = 20, from = "Donor-Testrealm" } } })
		assert.equal(2, n, "precondition: the deposit and the money were not recorded")
		Log:RecordRequestTransition(nil, { id = "r1", date = 1757003600, requester = "Asker-Testrealm", bank = BOB, item = "Linen Cloth", itemID = 2589, quantity = 3, fulfilled = 0, notes = "" })
		local tab = false
		for _, t in ipairs(Browse.TABS) do if t.value == "log" then tab = true end end
		assert.is_true(tab, "no Log tab in the strip")

		Browse:Open("log")
		assert.equal("log", Browse.currentTab)
		assert.is_true(Browse.LogList.parent:IsShown())
		assert.is_false(Browse.BankerList.parent:IsShown())
		local rows = Browse.LogList.data
		assert.equal(3, #rows)
		assert.truthy(Browse.statusText:find("3 recent entries (the last " .. Log.MAX_ENTRIES .. " are kept)", 1, true), Browse.statusText)
		-- Newest first: the request (now) before the deposit (an hour ago).
		assert.equal("requested", rows[1].entry.type)
		-- LOG-TAB-002: From and To, as the columns say -- a request goes from the requester to the
		-- bank; a deposit from the member who mailed it (when known) to the bank.
		assert.equal("Asker", rows[1].from); assert.equal("Bob", rows[1].to); assert.equal(3, rows[1].count)
		local deposit
		for _, r in ipairs(rows) do if r.entry.type == "deposit" then deposit = r end end
		assert.is_table(deposit)
		assert.equal("Donor", deposit.from)
		assert.equal("Bob", deposit.to)
		assert.truthy(deposit.action:find("deposited", 1, true))
		assert.equal(20, deposit.count)
		assert.truthy(deposit.item:find("|Hitem:2589", 1, true), "the item column is not a link: " .. tostring(deposit.item))
		assert.equal(deposit.item, deposit.link, "the hover tooltip's link is not the one drawn")
		assert.truthy(deposit.when:find("ago", 1, true))
		local money
		for _, r in ipairs(rows) do if r.entry.type == "money-deposit" then money = r end end
		assert.is_table(money); assert.equal("", money.count, "a money row has no quantity")
		-- A new entry lands through the log's own callback and the tab repaints itself.
		Log:RecordInventoryChange(BOB, { { ID = 2589, Count = 25 } }, { { ID = 2589, Count = 5 } }, 100, 100, 1757003700, nil, nil, nil)
		-- The log's coalescing timer. TWO clocks can own C_Timer in a full-suite run -- env_togbank's
		-- and the harness's (env.frames re-installs env.wow's) -- and which one Notify's After landed
		-- on depends on what loaded before this file. Passed alone, failed in the suite. Both are
		-- driven; the one that holds the timer fires it, the other has nothing due.
		env.advance(1)
		local wow = package.loaded["env.wow"]
		if wow and wow.advanceTime then wow.advanceTime(1) end
		assert.equal(4, #Browse.LogList.data, "a new log entry did not repaint the open Log tab")
		assert.equal("withdraw", Browse.LogList.data[1].entry.type)
		-- Empty log: the status says "recent", not "nothing ever". LOG-PERSIST-001: the buffer is the
		-- store's table, so emptying it means emptying both the cache and the saved copy.
		Log.buffers = {}
		Store:GuildTable(G, true).log = nil
		Browse:DrawLog()
		assert.truthy(Browse.statusText:find("No recent bank activity", 1, true), Browse.statusText)
		-- The help icon carries the tab's own text, and names the cap rather than "since login".
		Browse.HelpIcon:GetScript("OnEnter")(Browse.HelpIcon)
		local text = {}
		for _, l in ipairs(GameTooltip:GetLines()) do text[#text + 1] = l.left or "" end
		local joined = table.concat(text, "\n")
		assert.truthy(joined:find("most recent " .. Log.MAX_ENTRIES .. " entries", 1, true), "the Log tab's help does not name the cap")
		assert.is_nil(joined:find("since you logged in", 1, true), "the Log tab's help still says the log is since login")
	end)

	-- The operator, on the first cut: "the requests still pops up the window, and it's not inside
	-- the new UI". The Requests body is embedded IN the tab -- its widgets under our tab group, its
	-- icon cluster on our bottom row left of our help icon -- and let go when the tab changes.
	it("the Requests tab embeds the Requests body in this window, and detaches it on leaving the tab or closing", function()
		local R = TOGBankClassic_UI_Requests
		Browse:Open("requests")
		assert.is_table(R.embedded, "the Requests body was not embedded")
		assert.equal(Browse.TabGroup, R.embedded.host, "the host is not our tab group")
		assert.equal(Browse.Window, R.embedded.chrome, "the chrome is not our window")
		assert.equal(Browse.SettingsIcon, R.embedded.anchor, "the cluster is not hung off our gear, the leftmost of our own bottom icons")
		assert.is_false(Browse.BrowseList.parent:IsShown())
		-- Nothing docks beside us any more.
		local src = env.readFile("Modules/UI/Requests.lua")
		assert.is_nil(src:find("TOGBankClassic_UI_Browse.Window.frame", 1, true), "Requests still docks a window beside the Guild Bank window")
		-- Leaving the tab detaches BEFORE the tab group releases its children.
		local detachedBeforeRelease
		local release = Browse.TabGroup.ReleaseChildren
		Browse.TabGroup.ReleaseChildren = function(tg) detachedBeforeRelease = R.detached == 1; return release(tg) end
		Browse.TabGroup:SelectTab("browse")
		assert.equal(1, R.detached)
		assert.is_true(detachedBeforeRelease, "the tab group released the body's widgets before Requests let go of them")
		assert.is_nil(R.embedded)
		-- Back on the tab, then the window closes: detached again.
		Browse.TabGroup:SelectTab("requests")
		assert.is_table(R.embedded)
		Browse:Close()
		assert.is_false(Browse.isOpen)
		assert.equal(2, R.detached, "closing the window did not detach the body")
	end)

	-- The operator: "need to add the gear icon next to the close button like in the legacy version
	-- to open settings".
	it("has the gear left of the help icon, opening the options panel, and everything hangs left of it", function()
		local opened = 0
		TOGBankClassic_Options = { db = { global = {}, char = {} }, Open = function() opened = opened + 1 end }
		Browse:Open()
		local gear = Browse.SettingsIcon
		assert.is_not_nil(gear)
		assert.equal(Browse.Window.frame, gear:GetParent())
		local point, rel, relPoint, x, y = gear:GetPoint(1)
		assert.equal("BOTTOMRIGHT", point); assert.equal(Browse.Window.frame, rel); assert.equal("BOTTOMRIGHT", relPoint)
		assert.equal(-165, x); assert.equal(17, y)
		assert.equal(20, gear:GetWidth())
		gear:GetScript("OnClick")(gear)
		assert.equal(1, opened, "the gear did not open the options panel")
		-- The status bar ends at the gear, and the Requests cluster anchor is the gear.
		assert.equal(gear, Browse:BottomAnchor())
		local statusbg = Browse.Window.statustext:GetParent()
		local _, rel2 = statusbg:GetPoint(2)
		assert.equal(gear, rel2, "the status bar does not end at the gear")
	end)

	-- The operator: "we need the i info tooltip next to the close button like in all the other addons,
	-- explaining how the page works. and can you make it 'breath' like you did the old request rows?
	-- ... when someone mouses over it for the first time, it stops? i want to draw their attention
	-- to it, ONCE".
	it("has a help icon left of Close that breathes until its first mouseover, then never again on this account", function()
		Browse:Open()
		local icon = Browse.HelpIcon
		assert.is_not_nil(icon)
		assert.equal(Browse.Window.frame, icon:GetParent())
		local point, rel, relPoint, x, y = icon:GetPoint(1)
		assert.equal("BOTTOMRIGHT", point); assert.equal(Browse.Window.frame, rel); assert.equal("BOTTOMRIGHT", relPoint)
		assert.equal(-133, x); assert.equal(15, y)
		-- BREATH-001: the breath is the library's (W:Breathe, one AnimationGroup under its own key).
		local W = TOGBankClassic_UI.Widgets
		local breathing = function(f) return W:IsBreathing(f) end
		assert.is_true(breathing(icon), "the icon does not breathe on a first look")
		local fade = icon._lagwBreath:GetAnimations()
		assert.equal(0.35, fade:GetToAlpha()); assert.equal(1.0, fade:GetDuration()); assert.equal("BOUNCE", icon._lagwBreath:GetLooping())
		-- First hover: the tooltip explains the page, the breath stops, and the account remembers.
		icon:GetScript("OnEnter")(icon)
		assert.is_false(breathing(icon), "the breath did not stop on the first mouseover")
		assert.equal(1, icon:GetAlpha())
		assert.is_true(TOGBankClassic_Options.db.global.helpSeen.browse.browse)
		local text = {}
		for _, l in ipairs(GameTooltip:GetLines()) do text[#text + 1] = l.left or "" end
		assert.truthy(table.concat(text, "\n"):find("Clear", 1, true), "the Browse tab's help does not mention the Clear button")
		-- The next window on this account starts still.
		Browse:Close()
		Browse.Window:Release(); Browse.Window = nil
		Browse:Open()
		assert.is_false(breathing(Browse.HelpIcon), "a seen icon started breathing again")
		-- HELP-PULSE-002: "each i on each tab has different info. the 'breath' effect has to be on,
		-- for each one, until it's moused over. right now mousing over one, fills the stop breath
		-- effect for them all." The Requests tab's help has not been read: it breathes again.
		Browse.TabGroup:SelectTab("requests")
		assert.is_true(breathing(Browse.HelpIcon), "hovering the Browse tab's help silenced the Requests tab's -- different text, never read")
		-- On the Requests tab the icon carries the Requests body's own help.
		Browse.HelpIcon:GetScript("OnEnter")(Browse.HelpIcon)
		assert.equal("REQUESTS HELP", GameTooltip:GetLines()[1].left)
		assert.is_false(breathing(Browse.HelpIcon))
		assert.is_true(TOGBankClassic_Options.db.global.helpSeen.browse.requests)
		assert.is_nil(TOGBankClassic_Options.db.global.helpSeen.browse.bankers, "the Bankers tab was marked seen without ever being shown")
		-- Back to a seen tab: still. On to an unseen one: breathing.
		Browse.TabGroup:SelectTab("browse")
		assert.is_false(breathing(Browse.HelpIcon), "a seen tab's icon breathed again on return")
		Browse.TabGroup:SelectTab("bankers")
		assert.is_true(breathing(Browse.HelpIcon), "the Bankers tab's unread help does not breathe")
	end)

	-- The first cut stored ONE boolean for the window. An account that hovered it that day has
	-- `helpSeen.browse = true`; that reads as the Browse tab seen and nothing else -- the other two
	-- tabs' text was never in front of them.
	it("reads the first cut's single boolean as the Browse tab alone, and migrates it on the next mark", function()
		TOGBankClassic_Options.db.global.helpSeen = { browse = true }
		assert.is_true(Browse:HelpSeen("browse"))
		assert.is_false(Browse:HelpSeen("bankers"))
		assert.is_false(Browse:HelpSeen("requests"))
		Browse:MarkHelpSeen("bankers")
		local seen = TOGBankClassic_Options.db.global.helpSeen.browse
		assert.is_table(seen, "the boolean was not migrated to a per-tab table")
		assert.is_true(seen.browse, "migrating dropped the tab the account had already read")
		assert.is_true(seen.bankers)
		assert.is_nil(seen.requests)
	end)

	-- The operator: "the stuff at the top needs to align vertically, and the search bar is too close
	-- to the border" -- and "we also need a clear filters button on the browse page".
	it("lays the filter strip out as a bottom-aligned table inset from the border, with a Clear button that resets every filter", function()
		Browse:Open()
		local strip = Browse.FilterStrip
		assert.is_not_nil(strip, "no filter strip group")
		local t = strip:GetUserData("table")
		-- AceGUI's Table layout rewrites a bare width into `{ width = n }` on its first pass.
		local widths = {}
		for i, c in ipairs(t.columns) do widths[i] = type(c) == "table" and c.width or c end
		assert.same({ 220, 150, 130, 140, 110 }, widths)
		assert.equal("end", t.alignV, "cells are not bottom-aligned: a label-less search box top-aligns above the dropdown boxes")
		local _, _, _, x, y = strip.content:GetPoint(1)
		assert.equal(8, x, "the strip is not inset from the tab's left border"); assert.equal(-4, y)
		-- "the bottom row is too close to the column header row": the list starts 12px under the strip.
		assert.equal(100, Browse.STRIP_H); assert.equal(112, Browse.FILTER_H)
		local _, _, _, _, listY = Browse.BrowseList.parent:GetPoint(1)
		assert.equal(-112, listY, "the row list does not start a gap below the strip")
		assert.equal(10, #strip.children, "search, four dropdowns, quality, two level boxes, usable, Clear")
		assert.equal("Clear", Browse.ClearButton.text:GetText())

		_G.UnitLevel = function() return 60 end
		Browse.TooltipLines = function() return {} end
		Browse.filters.type = "2"; Browse.filters.text = "club"; Browse.filters.usable = true; Browse.filters.minLevel = 5
		Browse:DrawBrowse()
		assert.is_true(Browse:FiltersActive())
		assert.equal(1, #Browse.rowsShown)
		Browse.ClearButton:Fire("OnClick")
		assert.is_false(Browse:FiltersActive(), "Clear left a filter set")
		assert.same(Browse:DefaultFilters(), Browse.filters)
		assert.equal(7, #Browse.rowsShown, "the list was not redrawn after Clear")
		-- The strip is rebuilt (AceGUI may hand back the same pooled group), so the widgets show the reset.
		assert.equal("any", Browse.FilterStrip.children[3]:GetValue(), "the Type dropdown still shows the cleared value")
	end)

	it("a left click on a row requests it; a view-only bank's row does not; a right click on your own bank's row hides it", function()
		local requested, hidden
		TOGBankClassic_UI_Search.ShowRequestDialog = function(_, item, bank) requested = { item.ID, bank } end
		TOGBankClassic_Bank.SetHidden = function(_, id, suffix, enchant, on) hidden = { id, suffix, enchant, on } return true end
		Browse:Open()
		local by = {}
		for _, r in ipairs(Browse.rowsShown) do by[r.plainName .. "@" .. r.player] = r end
		Browse:OnBrowseRowClick(by["Spiked Club@Bob-Testrealm"], "LeftButton")
		assert.same({ 10132, BOB }, requested)
		requested = nil
		Browse:OnBrowseRowClick(by["Linen Cloth@Viewonly-Testrealm"], "LeftButton")
		assert.is_nil(requested, "a view-only bank's item opened the request dialog")
		assert.truthy(Browse.statusText:find("view-only", 1, true))
		-- Right click: only on the player's own bank (Alice here).
		Browse:OnBrowseRowClick(by["Linen Cloth@Bob-Testrealm"], "RightButton")
		assert.is_nil(hidden, "a right click on ANOTHER banker's row tried to hide it")
		Browse:OnBrowseRowClick(by["Thunderfury@Alice-Testrealm"], "RightButton")
		assert.same({ 19019, 0, 0, true }, hidden)
	end)

	-- HIDE-003. The operator, on the Guild Bank window: "by default right click on an item it 'just
	-- went away'. i don't see it and i can't unselect it. it was supposed to get the circle with a
	-- line through it." The Browse rows read the visible view only; the Inventory window's own tab
	-- was the one place the hidden rows were appended. Now they ride here too -- own bank only.
	it("keeps the banker's OWN hidden rows in the list, greyed with the red badge, so a right click can show them again", function()
		local hiddenKey = Record.key(Record.new(19019, 1))
		Store:SetAltSources(G, ALICE, {}, nil, { [hiddenKey] = true })   -- re-split Alice's stock on the hidden list
		local rows = Browse:BuildRows()
		local by = {}
		for _, r in ipairs(rows) do by[r.plainName .. "@" .. r.player] = r end
		local tf = by["Thunderfury@Alice-Testrealm"]
		assert.is_not_nil(tf, "the hidden row vanished from the banker's own list")
		assert.is_true(tf.Hidden)
		assert.is_true(tf._iconDesaturated)
		assert.truthy(tf.name:find("ReadyCheck-NotReady", 1, true), "no red badge on the hidden row")
		assert.truthy(tf.name:find("|cff808080Thunderfury", 1, true), "the hidden row is not greyed")
		assert.is_false(by["Linen Cloth@Alice-Testrealm"].Hidden or false, "a visible row was marked hidden")
		-- The hover says how to bring it back; a visible own row says how to hide it.
		local tips = {}
		TOGBankClassic_UI.ShowItemTooltip = function(_, link, lines) tips[#tips + 1] = { link, lines } end
		TOGBankClassic_Bank.HiddenReason = function() return "manual" end
		Browse:OnBrowseRowEnter(tf)
		assert.matches("right%-click to show it", tips[1][2][1][1])
		Browse:OnBrowseRowEnter(by["Linen Cloth@Alice-Testrealm"])
		assert.matches("Right%-click to hide", tips[2][2][1][1])
		-- HIDDEN-TEXT-001: the lines are UI.HIDDEN_TEXT's own entries (identity), not copies -- the
		-- Inventory window hands DrawItem the same tables, so the two windows cannot drift.
		local T = TOGBankClassic_UI.HIDDEN_TEXT
		assert.equal(T.tooltipHidden, tips[1][2], "Browse built its own hidden-row tooltip lines")
		assert.equal(T.tooltipShown,  tips[2][2], "Browse built its own shown-row tooltip lines")
		TOGBankClassic_Bank.HiddenReason = function() return "soulbound" end
		Browse:OnBrowseRowEnter(tf)
		assert.equal(T.tooltipSoulbound, tips[3][2])
		TOGBankClassic_Bank.HiddenReason = function() return "manual" end
		Browse:OnBrowseRowEnter(by["Linen Cloth@Bob-Testrealm"])
		assert.is_nil(tips[4][2], "another banker's row carries the hide hint")
		-- A right click on the hidden row SHOWS it (SetHidden false), and the list is redrawn.
		local call
		TOGBankClassic_Bank.SetHidden = function(_, id, suffix, enchant, on) call = { id, suffix, enchant, on } return true end
		Browse:Open()
		Browse:OnBrowseRowClick(tf, "RightButton")
		assert.same({ 19019, 0, 0, false }, call)
		-- LOG-HYGIENE-002 F3 (Peer Review db06c629): a LEFT click on the hidden row does not open a
		-- request dialog for your own hidden item; the status line says what the row is for.
		local dialogs = 0
		TOGBankClassic_UI_Search.ShowRequestDialog = function() dialogs = dialogs + 1 end
		Browse:OnBrowseRowClick(tf, "LeftButton")
		assert.equal(0, dialogs, "a left click on your own hidden row opened a request dialog")
		assert.truthy(Browse.statusText:find("Thunderfury is hidden from the guild", 1, true), Browse.statusText)
		Browse:OnBrowseRowClick(by["Linen Cloth@Alice-Testrealm"], "LeftButton")
		assert.equal(1, dialogs, "a left click on a visible own row no longer requests")
		-- Nobody else sees a banker's hidden rows: as a viewer, Alice's hidden Thunderfury is absent.
		TOGBankClassic_Guild.GetNormalizedPlayer = function() return "Someone-Testrealm" end
		assert.is_nil(names(Browse:BuildRows())[8], "a viewer's list carries a banker's hidden row")
		for _, r in ipairs(Browse:BuildRows()) do assert.is_not_equal("Thunderfury", r.plainName) end
	end)

	-- ENTRY-001 (operator 2026-09-13): "can you make the MMB open the new UI and browse open the
	-- legacy ui?" -- the minimap click is the Guild Bank window; `/togbank legacy` is the old
	-- Inventory window. Both driven, not grepped: the real LDB object's OnClick and the real
	-- command table's handler.
	it("is reachable: the minimap click opens it, /togbank legacy opens the OLD Inventory window (browse is no command), a Browse button on the Inventory window, Escape, both TOCs in order", function()
		local toggled = {}
		TOGBankClassic_UI_Browse.Toggle = function() toggled.browse = (toggled.browse or 0) + 1 end
		TOGBankClassic_UI_Inventory = { Toggle = function() toggled.inventory = (toggled.inventory or 0) + 1 end }
		-- The minimap button: a stand-in LibDBIcon/LDB that hands back the data object, the real
		-- AceDB it registers its position with, and the Options shape Init reads.
		local dataObject
		LibStub.libs["LibDBIcon-1.0"] = { Register = function() end, Show = function() end, Hide = function() end }
		LibStub.libs["LibDataBroker-1.1"] = { NewDataObject = function(_, _, obj) dataObject = obj return obj end }
		require("env.ace").load("AceDB-3.0")
		TOGBankClassic_Options = { db = { char = { minimap = { enabled = true } } }, Open = function() toggled.options = (toggled.options or 0) + 1 end }
		env.loadFile("Modules/UI/Minimap.lua")
		TOGBankClassic_UI_Minimap:Init()
		_G.IsShiftKeyDown = function() return false end
		dataObject.OnClick(nil, "LeftButton")
		assert.equal(1, toggled.browse, "the minimap click did not open the Guild Bank window")
		assert.is_nil(toggled.inventory, "the minimap click opened the old Inventory window")
		_G.IsShiftKeyDown = function() return true end
		dataObject.OnClick(nil, "LeftButton")
		assert.equal(1, toggled.options, "shift-click did not open the options")
		assert.equal(1, toggled.browse)
		-- The tooltip names what the click does.
		GameTooltip:ClearLines()
		TOGBankClassic_UI_Minimap:ShowTooltip()
		assert.equal("Guild Bank", GameTooltip._lines[2].right)
		-- /togbank legacy, typed (the operator: "rename it from togbank browse to togbank legacy"):
		-- the real dispatcher with the faithful GetArgs (chatcommand_spec's reason for
		-- env.stubCore), and `browse` no longer a command. ENTRY-002 (v1.5.1, the operator: "the
		-- /togbank command still brings up the old UI, we need it to bring up the new UI, we have a
		-- /togbank legacy for the old UI"): bare /togbank is the Guild Bank window too.
		env.loadModules({ "Modules/Switches.lua", "Modules/Chat.lua" })
		env.stubCore()
		TOGBankClassic_Database = { db = { global = {} } }
		TOGBankClassic_Chat:ChatCommand("legacy")
		assert.equal(1, toggled.inventory, "/togbank legacy did not open the old Inventory window")
		assert.equal(1, toggled.browse, "/togbank legacy opened the Guild Bank window")
		TOGBankClassic_Chat:ChatCommand("")
		assert.equal(2, toggled.browse, "bare /togbank did not open the Guild Bank window")
		assert.equal(1, toggled.inventory, "bare /togbank still opens the old Inventory window")
		local helped = 0
		TOGBankClassic_Chat.ShowHelp = function() helped = helped + 1 end
		TOGBankClassic_Chat:ChatCommand("browse")
		assert.equal(1, helped, "/togbank browse is still a command")
		assert.equal(1, toggled.inventory); assert.equal(2, toggled.browse)
		local chat = env.readFile("Modules/Chat.lua")
		assert.truthy(chat:find('help = "open the old Inventory window', 1, true), "the legacy help text does not say which window")
		local inv = env.readFile("Modules/UI/Inventory.lua")
		assert.truthy(inv:find('browseButton:SetText("Browse")', 1, true), "no Browse button on the Inventory window")
		local ui = env.readFile("Modules/UI.lua")
		assert.truthy(ui:find("TOGBankClassic_UI_Browse:Close()", 1, true), "Escape does not close the Guild Bank window")
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_BCC.toc" }) do
			local src = env.readFile(toc)
			local search, rowlist, browse = src:find("Modules/UI/Search.lua", 1, true), src:find("Modules/UI/RowList.lua", 1, true), src:find("Modules/UI/Browse.lua", 1, true)
			assert.is_not_nil(rowlist, toc .. " does not load RowList.lua")
			assert.is_not_nil(browse, toc .. " does not load Browse.lua")
			assert.is_true(search < rowlist and rowlist < browse, toc .. " loads Browse before the files it reads")
		end
	end)

	-- ENTRY-002 (v1.5.1, the operator: "the /togbank command still brings up the old UI, we need it
	-- to bring up the new UI"). END TO END, nothing stubbed between the typed command and the
	-- screen: the real dispatcher, the real Browse:Toggle, the real AceGUI window. The example above
	-- proves the routing with a counter; this one proves the window is actually up.
	it("bare /togbank opens the Guild Bank window on screen, again closes it, and /togbank legacy leaves it alone", function()
		local inventoryToggles = 0
		TOGBankClassic_UI_Inventory = { Toggle = function() inventoryToggles = inventoryToggles + 1 end }
		env.loadModules({ "Modules/Switches.lua", "Modules/Chat.lua" })
		env.stubCore()
		TOGBankClassic_Database = { db = { global = {} } }
		assert.is_falsy(Browse.isOpen)
		assert.is_nil(Browse.Window, "the window existed before anything opened it")

		TOGBankClassic_Chat:ChatCommand("")
		assert.is_true(Browse.isOpen, "bare /togbank did not open the Guild Bank window")
		assert.is_not_nil(Browse.Window, "no window was built")
		assert.is_true(Browse.Window.frame:IsShown(), "the window was built but is not showing")
		assert.equal(TOGBankClassic_UI:WindowTitle("Guild Bank"), Browse.Window.titletext:GetText())
		assert.is_not_nil(Browse.TabGroup, "the tab strip was not built")
		assert.equal(Browse.currentTab, Browse.TabGroup.localstatus.selected, "no tab is selected on open")
		assert.equal(0, inventoryToggles, "bare /togbank also touched the old Inventory window")

		-- A second bare /togbank is the toggle's other half.
		TOGBankClassic_Chat:ChatCommand("")
		assert.is_false(Browse.isOpen, "a second /togbank did not close the window")
		assert.is_false(Browse.Window.frame:IsShown(), "closed, but the frame is still showing")

		-- /togbank legacy is the OLD window only.
		TOGBankClassic_Chat:ChatCommand("legacy")
		assert.equal(1, inventoryToggles, "/togbank legacy did not toggle the old Inventory window")
		assert.is_false(Browse.isOpen, "/togbank legacy opened the Guild Bank window")

		-- The command's own help line names the window it opens.
		local src = env.readFile("Modules/Chat.lua")
		assert.truthy(src:find('"%s/togbank%s - open or close the Guild Bank window"', 1, true), "/togbank help still describes the old window")
	end)
end)

-- ─── The fold-in, with the REAL Requests body ────────────────────────────────────

describe("BROWSE-001: the Requests body inside the Guild Bank window", function()
	local R

	before_each(function()
		env.reset()
		require("env.frames").reset()
		loadBrowse({ me = ALICE, states = { [BOB] = { "behind", 1756000000, 1757000000 } } })
		stock()
		env.loadModules({ "Modules/Item.lua" })
		env.loadFile("Modules/UI/Requests.lua")
		R = TOGBankClassic_UI_Requests
		R:Init()
		TOGBankClassic_UI_StatusBar = { AttachSides = function() return {} end }
		TOGBankClassic_Mail = { isOpen = false, IsBankOpen = function() return false end }
		TOGBankClassic_ItemHighlight = nil
		TOGBankClassic_Options = {
			db = { global = { requests = {} }, char = { framePositions = {} } },
			GetAutoTombstoneDays = function() return 30 end, GetMaxRequestPercent = function() return 100 end,
		}
		local G = TOGBankClassic_Guild
		G.Info.settings = {}
		G.Info.requests = {}
		G.SenderIsGM = function() return false end
		G.QueryRequestsIndex = function(self) self.queried = (self.queried or 0) + 1 end
		TOGBankClassic_UI_Inventory = { isOpen = false }
		_G.CanViewOfficerNote = function() return false end
		_G.GetNumGuildMembers = function() return 3 end
	end)

	after_each(function()
		TOGBankClassic_UI_Browse = nil
		TOGBankClassic_UI_Requests = nil
		TOGBankClassic_UI_StatusBar = nil
		TOGBankClassic_UI_Inventory = nil
	end)

	it("renders the Requests body as children of the tab, with its icon cluster on this window's bottom row", function()
		Browse:Open("requests")
		assert.is_true(R.isOpen); assert.is_true(R.embedded)
		assert.equal(Browse.TabGroup, R.Host, "the body's host is not the tab group")
		assert.equal(Browse.Window, R.Chrome)
		assert.is_nil(R.Window, "a standalone window was created for an embedded body")
		-- The body's AceGUI widgets are the tab group's children: tab strip, search, filters. The
		-- list (REQUESTS-ROWLIST-001) is a RowList on a plain frame under the filter strip, hung off
		-- the strip's bottom edge and the tab body's bottom-right.
		-- REQUESTS-STRIP-001: two children -- the tab strip and ONE filter strip in the Browse tab's
		-- shape (a Table inset FILTER_INSET, the search box spanning its first row, the dropdowns on
		-- the second, cells bottom-aligned), with the list a clear gap under it.
		assert.equal(2, #Browse.TabGroup.children)
		assert.equal(R.TabGroup, Browse.TabGroup.children[1])
		assert.equal(R.FilterGroup, Browse.TabGroup.children[2])
		-- REQUESTS-STRIP-002: the sub-tab row keeps the height it is given. The host's Flow lays a
		-- full-width child out, and an auto-height TabGroup with no children then sets itself to
		-- 3 + borderoffset + 23 = 56 -- ~25px of dead space under the tabs. Auto-height off; 39 is
		-- the 24px tabs at y=-7 plus 8 of clearance.
		assert.is_true(R.TabGroup.noAutoHeight, "the sub-tab row still auto-adjusts its height (to 56)")
		assert.equal(39, R.TabGroup.frame:GetHeight(), "the sub-tab row is not the set height -- the dead space under the tabs is back")
		assert.equal(R.SearchBox, R.FilterGroup.children[1], "the search box is not the strip's first cell")
		assert.equal(R.FilterRequester, R.FilterGroup.children[2]); assert.equal(R.FilterBank, R.FilterGroup.children[3])
		local t = R.FilterGroup:GetUserData("table")
		assert.equal("end", t.alignV, "cells are not bottom-aligned as Browse's are")
		-- Second round: search and the two dropdowns on ONE row (Browse's row), fixed columns, so the
		-- dropdowns' box art never sits under the search box to misalign with it.
		local widths = {}
		for i, c in ipairs(t.columns) do widths[i] = type(c) == "table" and c.width or c end
		assert.same({ 220, 200, 200 }, widths)
		assert.is_nil(R.SearchBox:GetUserData("cell"), "the search box still spans columns")
		assert.equal(200, R.FilterRequester.frame:GetWidth()); assert.equal(200, R.FilterBank.frame:GetWidth())
		local sp, _, _, sx = R.FilterGroup.content:GetPoint(1)
		assert.equal("TOPLEFT", sp); assert.equal(8, sx, "the strip is not inset from the border like Browse's")
			assert.equal(TOGBankClassic_UI.FILTER_INSET, sx)
		local _, _, _, _, gapY = R.ListHost:GetPoint(1)
		assert.equal(-10, gapY, "the list is not a clear gap under the strip -- the dropdowns ran into the header row")
		assert.is_not_nil(R.List, "no RowList on the tab")
		assert.equal(Browse.TabGroup.content, R.ListHost:GetParent())
		local p1, rel1, rp1 = R.ListHost:GetPoint(1)
		assert.equal("TOPLEFT", p1); assert.equal(R.FilterGroup.frame, rel1); assert.equal("BOTTOMLEFT", rp1)
		local p2, rel2 = R.ListHost:GetPoint(2)
		assert.equal("BOTTOMRIGHT", p2); assert.equal(Browse.TabGroup.content, rel2)
		assert.is_true(R.EmptyText:IsShown(), "the empty list was not said on the tab")
		assert.equal("No requests yet.", R.EmptyText:GetText())
		-- The cluster hangs left of OUR help icon, on OUR frame (Alice is a banker: the broom).
		assert.equal(Browse.Window.frame, R.CancelStaleBtn:GetParent())
		local _, rel = R.CancelStaleBtn:GetPoint(1)
		assert.equal(Browse.SettingsIcon, rel, "the broom is not hung off the Guild Bank window's gear (its leftmost own icon)")
		assert.is_true(R.CancelStaleBtn:IsShown())
		-- Peer Review F3-b: the hitbox lift set on our frame carries OUR icons (help AND gear) with the
		-- cluster up, still carries them with it hidden, and standalone carries only the anchor.
		local function lifted(frame)
			local set = {}
			for _, f in pairs(frame.togHitboxButtons or {}) do set[f] = true end
			return set
		end
		local up = lifted(Browse.Window.frame)
		assert.is_true(up[Browse.HelpIcon] and up[Browse.SettingsIcon] and up[R.CancelStaleBtn] or false, "with the cluster up the lift set lost one of the window's own icons")
		R:ShowCluster(false)
		local down = lifted(Browse.Window.frame)
		assert.is_true(down[Browse.HelpIcon] and down[Browse.SettingsIcon] or false, "with the cluster hidden the lift set lost one of the window's own icons")
		assert.is_nil(down[R.CancelStaleBtn], "a hidden cluster is still in the lift set")
		R:ShowCluster(true)
		-- Its messages take our status bar.
		R:SetStatusText("hello from requests")
		assert.equal("hello from requests", Browse.statusText)
		assert.equal(1, TOGBankClassic_Guild.queried, "the request-index pull on open did not happen")
			-- The inset is ONE number (UI.FILTER_INSET) read by both files, not two literals that a
			-- comment says agree (self-audit 9bce8d86 F3): the Browse strip's content is inset the same,
			-- measured on that tab, and neither file carries its own `FILTER_INSET = 8`.
			Browse.TabGroup:SelectTab("browse")
			local bp, _, _, bx = Browse.FilterStrip.content:GetPoint(1)
			assert.equal("TOPLEFT", bp); assert.equal(sx, bx, "the Browse and Requests strips are inset differently")
			for _, path in ipairs({ "Modules/UI/Browse.lua", "Modules/UI/Requests.lua" }) do
				assert.is_nil(env.readFile(path):find("FILTER_INSET = 8", 1, true), path .. " carries its own inset literal")
			end
	end)

	-- SCROLLBAR-002 ("the reopen order button is overlapping the scroll bar") is the RowList's to
	-- keep now: its rows stop a gutter short of the host's right edge and its bar lives in that
	-- gutter, the same geometry the Browse tab has. REQUESTS-ROWLIST-001: the whole body is that
	-- list -- the same 16px banded rows, the same fonts and header as the Browse and Bankers tabs
	-- (the operator: "the same zebra striping/spaceing etc.").
	it("is the same RowList the Browse tab is: 16px banded rows under a gold header, the bar in the gutter", function()
		local G = TOGBankClassic_Guild
		G.Info.requests = {}
		for i = 1, 40 do
			G.Info.requests["r" .. i] = { id = "r" .. i, date = time() - 100 + i, requester = "Someone-Testrealm", bank = ALICE,
				item = "Linen Cloth", itemID = 2589, quantity = i, fulfilled = 0, status = "open" }
		end
		G.CanCancelRequest = function() return false end
		G.CanCompleteRequest = function() return false end
		G.CanDeleteRequest = function() return false end
		G.CanManageRequests = function() return false end
		G.RequestQuantityNeeded = function(_, req) return tonumber(req.quantity) or 0 end
		TOGBankClassic_Mail.CanFulfillRequest = function() return false, "not in bags", 0 end
		Browse:Open("requests")
		R.requesterFilter, R.bankFilter = nil, nil
		R:DrawRows()
		local list = R.List
		-- The fixture window's tab body leaves the list ~3 rows under the two-row strip; give it
		-- room to show a band (the rows are pooled to the parent's height).
		list.parent:SetHeight(20 + 16 * 8); list:Refresh()
		assert.equal(getmetatable(Browse.BrowseList), getmetatable(list), "the Requests tab is not on the same RowList class as Browse")
		assert.equal(TOGBankClassic_UI_RowList.ROW_HEIGHT, list.rows[1]:GetHeight())
		assert.equal(list.rows[1]:GetNumRegions() + 1, list.rows[2]:GetNumRegions(), "row 2 has no band")
		assert.same({ "GameFontHighlightSmall" }, list.rows[1].cells.requester._templates)
		assert.same({ "GameFontNormalSmall" }, list.headerCells.requester.fs._templates)
		assert.equal("|cffffd100Requester|r", list.headerCells.requester.fs:GetText())
		assert.equal(40, #list.data, "the whole set is one list, not a page")
		local _, rel, relPoint, x = list.rows[1]:GetPoint(2)
		assert.equal(R.ListHost, rel); assert.equal("TOPRIGHT", relPoint)
		assert.equal(-TOGBankClassic_UI_RowList.SCROLLBAR_GUTTER, x, "the rows run under the scrollbar gutter")
		assert.is_true(list.scrollbar:IsShown() or #list.data <= list.visibleRowCount)
	end)

	it("puts the date glyph, the coloured text, the item and the action icons on the row, and re-renders them on a scroll", function()
		local G = TOGBankClassic_Guild
		G.Info.requests = {}
		for i = 1, 40 do
			G.Info.requests["r" .. i] = { id = "r" .. i, date = time() - 100 + i, requester = "Someone-Testrealm", bank = ALICE,
				item = "Linen Cloth", itemID = 2589, quantity = i, fulfilled = 0, status = "open" }
		end
		G.Info.requests.r40.status = "cancelled"; G.Info.requests.r40.notes = "gone"
		G.CanCancelRequest = function() return true end
		G.CanCompleteRequest = function() return true end
		G.CanDeleteRequest = function() return false end
		G.CanManageRequests = function() return true end
		G.RequestQuantityNeeded = function(_, req) return (tonumber(req.quantity) or 0) - (tonumber(req.fulfilled) or 0) end
		TOGBankClassic_Mail.CanFulfillRequest = function() return false, "not in bags", 0 end
		Browse:Open("requests")
		R.requesterFilter, R.bankFilter = nil, nil
		R:DrawRows()
		local list = R.List
		list.parent:SetHeight(20 + 16 * 5); list:Refresh()
		-- Newest first: r40 (cancelled) is row 1.
		local row = list.rows[1]
		assert.equal("r40", row.togEntry.req.id)
		local dateCell, itemCell, actions = row.cells.date, row.cells.item, row.cells.actions
		assert.truthy(dateCell.label:GetText():find("ReadyCheck%-NotReady"), "a cancelled row's date has no glyph")
		assert.truthy(dateCell.label:GetText():find("|cffff6666", 1, true), "a cancelled row is not red")
		assert.is_true(dateCell.label.togCancelGlow, "the cancelled date does not glow")
		assert.equal("gone", dateCell._tipData.notes)
		assert.truthy(itemCell.label:GetText():find("Linen Cloth", 1, true))
		assert.equal("Linen Cloth", itemCell.editbox._itemName); assert.equal(2589, itemCell.editbox._itemID)
		-- The copy overlay's selection highlight must not paint (harness 1037beb models the setter).
		assert.same({ 0, 0, 0, 0 }, { itemCell.editbox:GetHighlightColor() }, "the copy overlay would paint a selection highlight")
		assert.is_false(actions.fulfill:IsShown(), "a completed row shows the fulfil icon")
		assert.is_false(actions.cancel:IsShown(), "a completed row shows cancel")
		assert.is_true(actions.reopen:IsShown(), "a completed row hides re-open")
		-- Row 2 is open: fulfil (dimmed: not in bags), hand-off, cancel; no re-open; the glow is off.
		local open = list.rows[2]
		assert.equal("r39", open.togEntry.req.id)
		assert.is_true(open.cells.actions.fulfill:IsShown()); assert.is_true(open.cells.actions.cancel:IsShown())
		assert.is_false(open.cells.actions.reopen:IsShown())
		assert.is_true(open.cells.actions.fulfill.togDisabled, "not in bags, yet the fulfil icon is live")
		assert.equal(0.4, open.cells.actions.fulfill:GetAlpha())
		assert.is_nil(open.cells.date.label.togCancelGlow)
		assert.truthy(open.cells.actions.fulfill.togTooltipDetail:find("not in bags", 1, true))
		-- Scroll: the pooled row 1 now shows r35 and its cells follow -- the glow it carried is off.
		list.scrollbar:SetValue(5)
		assert.equal("r35", list.rows[1].togEntry.req.id)
		assert.is_nil(list.rows[1].cells.date.label.togCancelGlow, "the glow stayed on a pooled row that scrolled to an open request")
		assert.is_true(list.rows[1].cells.actions.cancel:IsShown())
		-- An action icon acts on the request the cell shows NOW, not the one it was built for: the
		-- clicks read `cell.req`, and it followed the scroll.
		assert.equal(G.Info.requests.r35, list.rows[1].cells.actions.req)
		assert.equal(ALICE, list.rows[1].cells.actions.actor)
		-- The fulfil click goes through Mail with that request.
		local prepared
		TOGBankClassic_Mail.PrepareFulfillMail = function(_, req) prepared = req return true, "sent" end
		list.rows[1].cells.actions.fulfill.togDisabled = false
		list.rows[1].cells.actions.fulfill:Fire("OnClick")
		assert.equal(G.Info.requests.r35, prepared, "the fulfil icon acted on the request the row was built for, not the one it shows")
		assert.equal("sent", Browse.statusText)
	end)

	it("keeps the bag-update refresh on the fulfil icons of the rows in view only", function()
		local G = TOGBankClassic_Guild
		G.Info.requests = { r1 = { id = "r1", date = time() - 1, requester = "Someone-Testrealm", bank = ALICE,
			item = "Linen Cloth", itemID = 2589, quantity = 2, fulfilled = 0, status = "open" } }
		G.CanCancelRequest = function() return false end
		G.CanCompleteRequest = function() return false end
		G.CanDeleteRequest = function() return false end
		G.CanManageRequests = function() return false end
		G.RequestQuantityNeeded = function() return 2 end
		local verdict = { false, "not in bags", 0 }
		TOGBankClassic_Mail.CanFulfillRequest = function() return unpack(verdict) end
		Browse:Open("requests")
		R.requesterFilter, R.bankFilter = nil, nil
		-- The list's height resolves under the strip since harness ea9ad8d (contract b652437f: an
		-- edge anchor's implied centre no longer derives a size on an axis another anchor fixes).
		local fulfil = R.List.rows[1].cells.actions.fulfill
		assert.is_true(fulfil.togDisabled)
		verdict = { true, nil, 2 }
		R:_RefreshFulfillButtons(ALICE, true, true)
		assert.is_false(fulfil.togDisabled, "the bag update did not re-read the fulfil verdict")
		assert.equal(1, fulfil:GetAlpha())
		assert.truthy(fulfil.togTooltipDetail:find("Attach 2 Linen Cloth", 1, true))
		-- The request completed between draws: the icon hides here too.
		G.Info.requests.r1.fulfilled = 2
		R:_RefreshFulfillButtons(ALICE, true, true)
		assert.is_false(fulfil:IsShown())
	end)

	-- STALE-REQ-001: a request from a client too old to receive current bank contents (WIRE-SKEW-004's
	-- gate) is marked on its row and explained on the fulfil icon when the item is not found. The
	-- operator, 2026-09-13, on a v1.3.2 guildmate's request for a club the bank had not held since
	-- the night before: "the issue is the request came in from someone on v1.3.2 ... how can we
	-- handle this?"
	it("marks an open request from a requester on a pre-data-leg version, and says so on a not-found fulfil icon", function()
		local G = TOGBankClassic_Guild
		G.Info.requests = {
			r1 = { id = "r1", date = time() - 2, requester = "Oldguy-Testrealm", bank = ALICE,
				item = "Spiked Club", itemID = 4564, suffixID = 1180, quantity = 1, fulfilled = 0, status = "open" },
			r2 = { id = "r2", date = time() - 1, requester = "Newguy-Testrealm", bank = ALICE,
				item = "Linen Cloth", itemID = 2589, quantity = 1, fulfilled = 0, status = "open" },
			r3 = { id = "r3", date = time() - 3, requester = "Oldguy-Testrealm", bank = ALICE,
				item = "Wool Cloth", itemID = 2592, quantity = 1, fulfilled = 1, status = "fulfilled" },
			-- STALE-REQ-002: offline since the reload -- the live gate knows nothing, the guild's memory
			-- has him on v1.4.1; and one remembered on a CURRENT version, who must not be marked.
			r4 = { id = "r4", date = time() - 4, requester = "Gone-Testrealm", bank = ALICE,
				item = "Silk Cloth", itemID = 4306, quantity = 1, fulfilled = 0, status = "open" },
			r5 = { id = "r5", date = time() - 5, requester = "Fine-Testrealm", bank = ALICE,
				item = "Silk Cloth", itemID = 4306, quantity = 1, fulfilled = 0, status = "open" },
		}
		G.EncodeVersion = function(raw)
			local a, b, c = tostring(raw):match("(%d+)%.(%d+)%.(%d+)")
			return a and (tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)) or 0
		end
		G.LastSeenAddonVersion = function(_, name)
			if name == "Gone-Testrealm" then return "TOGBankClassic-v1.4.1", true end
			if name == "Fine-Testrealm" then return "TOGBankClassic-v1.5.0", true end
			return nil, false
		end
		G.CanCancelRequest = function() return false end
		G.CanCompleteRequest = function() return false end
		G.CanDeleteRequest = function() return false end
		G.CanManageRequests = function() return false end
		G.RequestQuantityNeeded = function(_, req) return (req.quantity or 0) - (req.fulfilled or 0) end
		-- The sync gate's answer, per peer: Oldguy runs the released v1.3.2, Newguy is unknown.
		G.PeerSpeaksDataLeg = function(_, name)
			if name == "Oldguy-Testrealm" then return false, "TOGBankClassic-v1.3.2" end
			return true, "unknown"
		end
		local NOT_FOUND = "Not in your bags, bank or mail (as of your last bank scan)."
		TOGBankClassic_Mail.CanFulfillRequest = function() return false, NOT_FOUND, 0 end
		Browse:Open("requests")
		R.requesterFilter, R.bankFilter = nil, nil
		local byId = {}
		for _, row in ipairs(R.List.rows) do
			if row:IsShown() and row.togEntry then byId[row.togEntry.req.id] = row end
		end
		assert.is_not_nil(byId.r1 and byId.r2 and byId.r4 and byId.r5, "the open rows did not draw")
		-- The old client's open request carries its version beside the name; the others do not.
		assert.truthy(byId.r1.togEntry.requester:find("|cffff9900v1.3.2|r", 1, true), byId.r1.togEntry.requester)
		assert.equal("1.3.2", byId.r1.togEntry.staleClient)
		assert.is_nil(byId.r2.togEntry.requester:find("v1.", 1, true), "an unknown-version requester was marked")
		assert.is_nil(byId.r2.togEntry.staleClient)
		-- STALE-REQ-002: the offline requester is marked from the guild's memory; the one last seen
		-- on a current version is not.
		assert.equal("1.4.1", byId.r4.togEntry.staleClient, "an offline requester remembered on v1.4.1 was not marked")
		assert.truthy(byId.r4.togEntry.requester:find("|cffff9900v1.4.1|r", 1, true))
		assert.is_nil(byId.r5.togEntry.staleClient, "a requester remembered on a current version was marked")
		-- Sorting by requester still sorts on the bare name.
		assert.equal("oldguy-testrealm", byId.r1.togEntry._sort_requester)
		-- The not-found tooltip names the requester, the version and the remedy; the capable one keeps
		-- the bare verdict.
		local tip = byId.r1.cells.actions.fulfill.togTooltipDetail
		assert.truthy(tip:find(NOT_FOUND, 1, true))
		assert.truthy(tip:find("Oldguy-Testrealm is on v1.3.2, which cannot receive current bank contents", 1, true), tip)
		assert.truthy(tip:find("Ask them to update TOG Bank", 1, true))
		assert.equal(NOT_FOUND, byId.r2.cells.actions.fulfill.togTooltipDetail)
		-- A finished request from the old client is not marked -- the mark is about what it can still
		-- request, not a badge on the person.
		assert.is_nil(TOGBankClassic_UI_Requests.StaleRequesterVersion(G.Info.requests.r3))
		-- Without the gate at all (a spec's bare Guild stub) nothing is marked and nothing errors.
		G.PeerSpeaksDataLeg = nil
		assert.is_nil(TOGBankClassic_UI_Requests.StaleRequesterVersion(G.Info.requests.r1))
	end)

	-- REQUESTS-ROWLIST-001: the three owned cells take the mouse themselves (the RowList's row
	-- enter/leave are not used here), so each must lock the row highlight while hovered and show
	-- its own tooltip: the date's timeline, the item's game tooltip, the action icon's name.
	it("the owned cells hover: the timeline on the date, the item tooltip and the copy overlay on the item, the name on an action icon -- each locking the row highlight", function()
		local G = TOGBankClassic_Guild
		local now = time()
		G.Info.requests = {
			r1 = { id = "r1", date = now - 30, updatedAt = now - 10, requester = "Someone-Testrealm", bank = ALICE,
				item = "Linen Cloth", itemID = 2589, quantity = 2, fulfilled = 0, status = "cancelled", notes = "gone" },
			r2 = { id = "r2", date = now - 20, updatedAt = now - 5, requester = "Someone-Testrealm", bank = ALICE,
				item = "Linen Cloth", itemID = 2589, quantity = 1, fulfilled = 1, status = "open" },
			r3 = { id = "r3", date = 0, requester = "Someone-Testrealm", bank = ALICE,
				item = "Old Request", quantity = 1, fulfilled = 0, status = "open" },
		}
		G.CanCancelRequest = function() return true end
		G.CanCompleteRequest = function() return true end
		G.CanDeleteRequest = function() return false end
		G.CanManageRequests = function() return true end
		G.RequestQuantityNeeded = function(_, req) return (tonumber(req.quantity) or 0) - (tonumber(req.fulfilled) or 0) end
		TOGBankClassic_Mail.CanFulfillRequest = function() return false, "not in bags", 0 end
		-- The rich frame model has no SetHyperlink (a harness gap other specs stub the same way).
		local shown
		local tip = _G.GameTooltip
		tip.SetHyperlink = function(_, link) shown = link end
		-- FrameXML's, which UI:HideTooltip calls on every leave; the frame model does not carry it.
		_G.GameTooltip_SetDefaultAnchor = _G.GameTooltip_SetDefaultAnchor or function() end
		Browse:Open("requests")
		R.requesterFilter, R.bankFilter = nil, nil
		R:DrawRows()
		local list = R.List
		list.parent:SetHeight(20 + 16 * 8); list:Refresh()   -- room for all three rows under the strip
		local byId = {}
		for _, row in ipairs(list.rows) do if row.togEntry then byId[row.togEntry.req.id] = row end end
		-- The cancelled row's date: submitted, cancelled, the reason; the row highlight locked while on it.
		local cancelled = byId.r1
		cancelled.cells.date:Fire("OnEnter")
		assert.is_true(cancelled:IsHighlightLocked(), "hovering the date cell did not lock the row highlight")
		assert.equal(cancelled.cells.date, GameTooltip:GetOwner())
		local lines = {}
		for i, l in ipairs(GameTooltip._lines) do lines[i] = l.left end
		assert.equal("Request Timeline", lines[1])
		assert.equal("Submitted:  " .. date("%Y-%m-%d %H:%M", now - 30), lines[2])
		assert.equal("Cancelled:  " .. date("%Y-%m-%d %H:%M", now - 10), lines[3])
		assert.equal("Reason:  gone", lines[4])
		cancelled.cells.date:Fire("OnLeave")
		assert.is_false(cancelled:IsHighlightLocked())
		-- The filled row's date: the fill time and the delivery note. The check glyph marks it.
		local filled = byId.r2
		assert.truthy(filled.cells.date.label:GetText():find("UI%-CheckBox%-Check"), "a filled row's date has no check glyph")
		filled.cells.date:Fire("OnEnter")
		assert.equal("Filled:  " .. date("%Y-%m-%d %H:%M", now - 5), GameTooltip._lines[3].left)
		assert.equal("Item arrives approx. 1 hour after sending.", GameTooltip._lines[4].left)
		filled.cells.date:Fire("OnLeave")
		-- A request with no date says so.
		byId.r3.cells.date:Fire("OnEnter")
		assert.equal("Submitted:  Unknown", GameTooltip._lines[2].left)
		byId.r3.cells.date:Fire("OnLeave")
		-- The item cell: hover shows the store's link for the request's itemID, from the copy overlay.
		local eb = cancelled.cells.item.editbox
		eb:Fire("OnEnter")
		assert.is_true(cancelled:IsHighlightLocked())
		assert.equal(eb, GameTooltip:GetOwner())
		assert.is_string(shown, "no item link reached the tooltip")
		assert.truthy(shown:find("item:2589", 1, true), "the tooltip link is not the request's item: " .. tostring(shown))
		eb:Fire("OnLeave")
		assert.is_false(cancelled:IsHighlightLocked())
		-- A legacy request (no itemID, name only) that no bank holds: the name alone, no link.
		shown = nil
		local legacy = byId.r3.cells.item.editbox
		legacy:Fire("OnEnter")
		assert.is_nil(shown)
		assert.equal("Old Request", GameTooltip._lines[1].left)
		legacy:Fire("OnLeave")
		-- The copy overlay: focus puts the name in and selects it; losing focus empties it (the
		-- overlay is invisible, so text left in it would be a stale copy target); Escape drops focus.
		eb:SetFocus()
		assert.equal("Linen Cloth", eb:GetText())
		eb:Fire("OnChar", "x")
		assert.equal("Linen Cloth", eb:GetText(), "typing into the overlay replaced the name")
		eb:Fire("OnKeyDown", "ESCAPE")
		assert.is_false(eb:HasFocus())
		assert.equal("", eb:GetText())
		-- The 5 s auto-clear: a focus still held when the timer lands is dropped.
		eb:SetFocus()
		env.advance(5)   -- both clocks, as the Log tab example explains
		local wow = package.loaded["env.wow"]
		if wow and wow.advanceTime then wow.advanceTime(5) end
		assert.is_false(eb:HasFocus(), "the overlay kept focus past the 5 s auto-clear")
		-- An action icon: its name and detail, the row highlight locked while on it.
		local cancelBtn = byId.r2.cells.actions.cancel
		cancelBtn:Fire("OnEnter")
		assert.is_true(byId.r2:IsHighlightLocked())
		assert.equal("Cancel request", GameTooltip._lines[1].left)
		assert.equal("Cancels the request without fulfilling it.", GameTooltip._lines[2].left)
		cancelBtn:Fire("OnLeave")
		assert.is_false(byId.r2:IsHighlightLocked())
		-- A disabled icon (the open r3's fulfil, not in bags) still answers its hover with the
		-- reason, and swallows the click. (r2 is filled: its fulfil icon is hidden, not dimmed.)
		assert.is_false(byId.r2.cells.actions.fulfill:IsShown())
		local fulfil = byId.r3.cells.actions.fulfill
		assert.is_true(fulfil.togDisabled)
		fulfil:Fire("OnEnter")
		assert.equal("Fulfill request", GameTooltip._lines[1].left)
		assert.truthy(GameTooltip._lines[2].left:find("not in bags", 1, true))
		fulfil:Fire("OnLeave")
		local prepared
		TOGBankClassic_Mail.PrepareFulfillMail = function(_, req) prepared = req return true, "sent" end
		fulfil:Fire("OnClick")
		assert.is_nil(prepared, "a dimmed fulfil icon still acted")
		-- No requests matching the search says so on the tab.
		R:SetSearch("zzz-nothing")
		assert.is_true(R.EmptyText:IsShown())
		assert.equal("No requests match the search or filters.", R.EmptyText:GetText())
	end)

	-- REQUESTS-ROWLIST-001: the RowList owns the header click AND the sort; the body only remembers
	-- it (sortColumn/sortDirection feed the list's SetSort on a rebuild), so the two must move
	-- together -- a click that sorted the list but not the body would snap back to date-descending
	-- on the next tab visit. The body used to sort the rows itself as well, for the list to sort
	-- them again (self-audit 1ebe87b4 F2); the tab-filter cache is keyed on the tab alone now.
	it("a header click sorts the list AND the body: the order survives a redraw and a tab revisit", function()
		local G = TOGBankClassic_Guild
		G.Info.requests = {}
		for i, qty in ipairs({ 2, 3, 1 }) do
			G.Info.requests["r" .. i] = { id = "r" .. i, date = time() - 100 + i, requester = "Someone-Testrealm", bank = ALICE,
				item = "Linen Cloth", itemID = 2589, quantity = qty, fulfilled = 0, status = "open" }
		end
		G.CanCancelRequest = function() return false end
		G.CanCompleteRequest = function() return false end
		G.CanDeleteRequest = function() return false end
		G.CanManageRequests = function() return false end
		G.RequestQuantityNeeded = function(_, req) return tonumber(req.quantity) or 0 end
		TOGBankClassic_Mail.CanFulfillRequest = function() return false, "not in bags", 0 end
		Browse:Open("requests")
		R.requesterFilter, R.bankFilter = nil, nil
		R:DrawRows()
		local list = R.List
		assert.equal("date", R.sortColumn); assert.equal("desc", R.sortDirection)
		assert.equal("r3", list.rows[1].togEntry.req.id, "the default is not newest first")
		list.headerCells.quantity.btn:Fire("OnClick")
		assert.equal("quantity", R.sortColumn, "the body did not follow the header click")
		assert.equal("asc", R.sortDirection)
		assert.equal("quantity", list.sortKey); assert.is_false(list.sortDesc)
		assert.equal(1, list.rows[1].togEntry.req.quantity)
		R:DrawRows()
		assert.equal(1, R.List.rows[1].togEntry.req.quantity, "a redraw lost the ascending sort")
		list.headerCells.quantity.btn:Fire("OnClick")
		assert.equal("desc", R.sortDirection)
		assert.equal(3, list.rows[1].togEntry.req.quantity)
		-- A redraw (a bag update, a filter change) reuses the tab-filtered set -- keyed on the tab,
		-- not the sort -- and the list keeps the clicked order.
		R:DrawRows()
		assert.equal(R.currentTab, R._cachedTabFilter)
		assert.is_nil(R._cachedSortColumn, "the tab-filter cache is keyed on a sort the list owns")
		assert.equal(3, R.List.rows[1].togEntry.req.quantity, "a redraw lost the clicked sort")
		-- Leaving the tab and coming back hands the list the body's sort, not the default.
		Browse.TabGroup:SelectTab("browse")
		Browse.TabGroup:SelectTab("requests")
		assert.equal("quantity", R.List.sortKey); assert.is_true(R.List.sortDesc)
		assert.equal(3, R.List.rows[1].togEntry.req.quantity, "a tab revisit lost the clicked sort")
		-- The Actions column opted out: no click script, so nothing to sort by.
		assert.is_nil(R.List.headerCells.actions.btn:GetScript("OnClick"))
		-- REQUESTS-ROWLIST-002: the tie-break is the inverted date as ten digits -- a number past a
		-- 32-bit int, which the client's `%d` refuses ("integer overflow attempting to store
		-- 8210744788") and this Lua casts silently, so the SHAPE is pinned: ten digits, then the id,
		-- and never a `%d`-family format on that value in the source.
		local newest = R.List.data[1]
		for _, e in ipairs(R.List.data) do if e.req.date > newest.req.date then newest = e end end
		assert.truthy(newest._id:match("^%d%d%d%d%d%d%d%d%d%d:" .. newest.req.id .. "$"), "tie-break id is not <10 digits>:<id>: " .. tostring(newest._id))
		assert.equal(string.format("%010.0f", 9999999999 - newest.req.date), newest._id:match("^(%d+):"))
		local src = env.readFile("Modules/UI/Requests.lua")
		assert.is_nil(src:match('"%%0?1?0?[di]:%%s", 9999999999'), "the tie-break formats the inverted date with %d again")
	end)

	-- CANCEL-GLOW-002: "can we add the 'breath' effect to the cancelled items? i'd like to apply what we
	-- did yesterday to the old cancelled items to make them more noticible to the new tab too." The
	-- glow was gated on a cancelled request HAVING A REASON; the ones cancelled before reasons existed
	-- have none and stayed unmarked. Pinned at the call site (the row draw needs the whole request
	-- pipeline under it; searchbox_spec drives the glow itself), the way the search columns are.
	it("glows every cancelled request's date, reason or not", function()
		local src = env.readFile("Modules/UI/Requests.lua")
		local call = src:match("self:SetCancelGlow%(label,%s*([^\n]-)%)\n")
		assert.is_string(call, "the row draw no longer switches the glow on the date cell")
		assert.equal('reqStatus == "cancelled"', call, "the glow is gated on something besides the request being cancelled")
		assert.truthy(src:find("A cancelled request's date breathes with a soft glow", 1, true), "the help text still says only reasoned cancellations glow")
	end)

	-- The operator: "the 'stuff' isn't fitting into the request tab page" -- AceGUI's TabGroup
	-- re-sizes itself to its content when a Flow layout finishes, so the body grew past the window.
	it("the tab group keeps the size the window gives it rather than growing to the Requests body", function()
		Browse:Open("requests")
		assert.is_true(Browse.TabGroup.noAutoHeight, "the tab group still auto-adjusts its height to its content")
	end)

	-- The operator: "settings is still popping up another window that overlaps the main window, it
	-- should just be a tab now".
	it("the Settings tab replaces the list inside the tab body instead of floating a panel over it", function()
		_G.CanViewOfficerNote = function() return true end
		_G.strtrim = _G.strtrim or function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
		Browse:Open("requests")
		assert.is_not_nil(R.SettingsOverlay, "an officer has no settings panel")
		local _, _, _, _, _ = R.SettingsOverlay:GetPoint(1)
		local _, rel2 = R.SettingsOverlay:GetPoint(2)
		assert.equal(Browse.TabGroup.content, rel2, "the panel's bottom-right is not the tab body's -- it was the window frame, and ran past the tab border")
		R.currentTab = "settings"
		R:DrawContent()
		assert.is_true(R.SettingsOverlay:IsShown())
		for _, w in ipairs({ R.SearchBox, R.FilterGroup }) do
			assert.is_false(w.frame:IsShown(), "the list showed through under the settings panel")
		end
		assert.is_false(R.ListHost:IsShown(), "the list showed through under the settings panel")
		assert.is_false(R.CancelStaleBtn:IsShown())
		R.currentTab = "active"
		R:DrawContent()
		assert.is_false(R.SettingsOverlay:IsShown())
		for _, w in ipairs({ R.SearchBox, R.FilterGroup }) do
			assert.is_true(w.frame:IsShown(), "the list did not come back after leaving Settings")
		end
		assert.is_true(R.ListHost:IsShown(), "the list did not come back after leaving Settings")
		assert.is_true(R.CancelStaleBtn:IsShown())
		-- The panel is found again on this window, not built a second time.
		local overlay = R.SettingsOverlay
		Browse.TabGroup:SelectTab("browse")
		Browse.TabGroup:SelectTab("requests")
		assert.equal(overlay, R.SettingsOverlay, "a second settings panel was built on the same frame")
	end)

	-- The operator, after Browse -> Requests -> Browse: a screenshot with the list and NO filter
	-- strip ("some kind of display bug").
	it("the filter strip comes back whole after a visit to the Requests tab", function()
		Browse:Open()
		local function stripState(pass)
			local strip = Browse.FilterStrip
			assert.is_not_nil(strip)
			assert.is_true(strip.frame:IsShown(), pass .. ": the strip group is hidden")
			-- AceGUI re-lays a container out whenever its content resizes; a layout that finished
			-- with no children yet sized the group to NOTHING when auto-height was switched off after
			-- the height was set. The strip keeps its fixed height on every build.
			assert.equal(100, strip.frame:GetHeight(), pass .. ": the strip group is not FILTER_H tall")
			assert.equal(10, #strip.children)
			for i, child in ipairs(strip.children) do
				assert.is_true(child.frame:IsShown(), "strip child " .. i .. " is hidden")
				assert.is_not_nil(child.frame:GetPoint(1), "strip child " .. i .. " has no anchor -- the table layout did not place it")
			end
			return strip
		end
		stripState("first open")
		Browse.TabGroup:SelectTab("requests")
		Browse.TabGroup:SelectTab("browse")
		stripState("back from Requests")
		Browse.TabGroup:SelectTab("bankers")
		Browse.TabGroup:SelectTab("browse")
		stripState("back from Bankers")
		-- The case that emptied the strip on screen: the Requests body hides its list widgets under
		-- the Settings panel by neutering their frames' Show; released like that and handed back by
		-- AceGUI's pool as the strip's own widgets, they could never be shown again.
		_G.CanViewOfficerNote = function() return true end
		_G.strtrim = _G.strtrim or function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
		Browse.TabGroup:SelectTab("requests")
		R.currentTab = "settings"
		R:DrawContent()
		assert.is_false(R.SearchBox.frame:IsShown(), "precondition: the list is hidden under Settings")
		Browse.TabGroup:SelectTab("browse")
		stripState("back from the Settings panel")
		for i, child in ipairs(Browse.FilterStrip.children) do
			assert.equal(1, child.frame:GetAlpha(), "strip child " .. i .. " came out of the pool dimmed")
		end
	end)

	it("Requests:Open() while this window is up goes to its tab rather than raising a window, and does not rebuild a body already there", function()
		Browse:Open()
		R:Open()
		assert.equal("requests", Browse.currentTab)
		assert.is_true(R.embedded)
		assert.is_nil(R.Window)
		-- Peer Review F4: AceGUI's SelectTab fires even for the selected tab; a second Open (the
		-- Inventory window's Requests button, Browse:Open itself) must not tear the body down.
		local builds = 0
		local build = R.BuildBody
		R.BuildBody = function(...) builds = builds + 1 return build(...) end
		R.List.listOffset = 3
		R:Open()
		Browse:Open("requests")
		assert.equal(0, builds, "the body was rebuilt on a re-select of its own tab")
		assert.equal(3, R.List.listOffset, "the scroll position was lost")
		-- After a CLOSE the body is detached while its widgets are still the tab group's children:
		-- that case must rebuild, not skip.
		Browse:Close()
		Browse:Open("requests")
		assert.is_true(R.embedded)
		assert.equal(1, builds, "a detached body was reused after the window was closed and reopened")
	end)

	it("leaving the tab lets go of every widget, parks the list and hides the cluster; coming back finds both again", function()
		Browse:Open("requests")
		local broom, listHost, list = R.CancelStaleBtn, R.ListHost, R.List
		Browse.TabGroup:SelectTab("browse")
		assert.is_false(R.isOpen); assert.is_false(R.embedded)
		assert.is_nil(R.List); assert.is_nil(R.ListHost); assert.is_nil(R.Host); assert.is_nil(R.TabGroup)
		assert.is_false(listHost:IsShown(), "the Requests list stayed showing on the Browse tab's body")
		assert.is_false(broom:IsShown(), "the cluster stayed on the Browse tab's bottom row")
		assert.is_true(Browse.BrowseList.parent:IsShown())
		Browse.TabGroup:SelectTab("requests")
		assert.is_true(R.embedded)
		assert.equal(broom, R.CancelStaleBtn, "a second cluster was built on the same frame")
		assert.is_true(broom:IsShown())
		-- REQUESTS-ROWLIST-001: one list per host frame -- frames cannot be destroyed, so a second
		-- visit must find the first one, not stack another under it.
		assert.equal(listHost, R.ListHost, "a second list was built on the same tab body")
		assert.equal(list, R.List)
		assert.is_true(listHost:IsShown())
	end)

	it("a standalone Requests window still opens when the Guild Bank window is closed, and moves into the tab when it opens", function()
		R:Open()
		assert.is_true(R.isOpen); assert.is_false(R.embedded or false)
		assert.is_not_nil(R.Window)
		assert.equal(R.Window, R.Host)
		assert.equal(R.Window.frame, R.CancelStaleBtn:GetParent())
		assert.equal(R.Window.content, R.ListHost:GetParent(), "the standalone list is not on the window's content")
		local win, standaloneList = R.Window, R.ListHost
		Browse:Open("requests")
		assert.is_true(R.embedded)
		assert.is_nil(R.Window, "the standalone window survived the embed")
		assert.is_false(win.frame:IsShown())
		assert.equal(Browse.Window.frame, R.CancelStaleBtn:GetParent())
		assert.is_not_equal(standaloneList, R.ListHost, "the tab reused the standalone window's list frame")
		-- Close the Guild Bank window: the body is detached; a standalone open works again.
		Browse:Close()
		assert.is_false(R.isOpen)
		R:Open()
		assert.is_not_nil(R.Window)
		assert.equal(R.Window.frame, R.CancelStaleBtn:GetParent())
	end)

	-- Peer Review, self-audit 2 F1: the embedded tab is never re-opened, so a 'gbank' note landing
	-- mid-session (the roster rebuild) must re-check the role where it happens, not on a tab switch.
	it("re-checks its role when the banker roster changes under the embedded tab (F1)", function()
		Browse:Open("requests")
		local G = TOGBankClassic_Guild
		assert.is_true(G:IsBank(ALICE), "fixture: Alice is the banker here")
		local envelope = R.FulfillOldestBtn
		assert.is_not_nil(envelope, "fixture: a banker has the envelope")
		-- Idempotent first: the same role again rebuilds nothing.
		R:OnBankerRosterChanged()
		assert.equal(envelope, R.FulfillOldestBtn, "an unchanged role rebuilt the cluster")
		-- Alice's 'gbank' tag is removed: the roster rebuild is what propagates a note edit.
		G.IsBank = function(_, n) return n == BOB or n == VIEW end
		R:OnBankerRosterChanged()
		assert.is_nil(R.FulfillOldestBtn, "the cluster kept the old role until a tab switch (F1)")
		assert.is_false(envelope:IsShown(), "the old envelope stayed on the window's bottom row")
		-- Neither officer nor banker now: the cluster is empty and the status bar meets the anchor.
		assert.is_nil(R.CancelStaleBtn)
		local statusbg = Browse.Window.statustext:GetParent()
		local _, rel = statusbg:GetPoint(2)
		assert.equal(Browse.SettingsIcon, rel, "an empty cluster did not hand the status bar's right edge back to the window's own icon")
		-- Not embedded: a no-op, never an error.
		Browse:Close()
		assert.has_no.errors(function() R:OnBankerRosterChanged() end)
	end)

	-- writ-cannot: the "Guild:RebuildBankerRoster reaches the embedded tab" example that stood here
	-- called a method this describe's Guild STUB does not have; the real Guild is under test in
	-- Tests/guild_spec.lua, and that example now lives there ("tells the Requests body when the
	-- banker list changed, and not otherwise").
end)
-- writ-cannot: the "old reachability checks" describe below this line was an accidental verbatim
-- duplicate of the "is reachable" example in the window describe above, created by an insertion
-- that landed mid-example; the original stands unchanged, so the copy must not exist.
