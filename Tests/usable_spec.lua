-- BROWSE-004 -- "Usable by me" is DATA: Dibs' gate, ported (Modules/Usable.lua).
--
-- The operator, a level-60 hunter on the Guild Bank window: "the usable by me filter still isn't
-- working. as a hunter i can't use hammers, you may want to use some of what dibs did for the
-- filtering". Four layers: level, LibItemDB's class obtainability, the proficiency tables, the
-- tooltip's Classes:/Races: tags. The tables are a COPY of Dibs/Data/ItemSources.lua's and this file
-- pins their VALUES, so a drift in either addon shows up here.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local WARRIOR, PALADIN, HUNTER, ROGUE, PRIEST, SHAMAN, MAGE, WARLOCK, DRUID = 1, 2, 3, 4, 5, 7, 8, 9, 11
local ARMOR, WEAPON = 4, 2
local CLOTH, LEATHER, MAIL, PLATE, SHIELD = 1, 2, 3, 4, 6
local AXE1, MACE1, MACE2, POLEARM, SWORD1, STAFF, DAGGER, WAND, BOW = 0, 4, 5, 6, 7, 10, 15, 19, 2

local U

describe("Usable.ClassProficient -- Dibs' rules, the same values", function()
	before_each(function()
		env.reset()
		env.loadFile("Modules/Usable.lua")
		U = TOGBankClassic_Usable
	end)

	it("a hunter cannot wield a mace (the report), a wand either; can wield axes, bows, swords, polearms", function()
		assert.is_false(U.ClassProficient(HUNTER, WEAPON, MACE1, "INVTYPE_WEAPON"))
		assert.is_false(U.ClassProficient(HUNTER, WEAPON, MACE2, "INVTYPE_2HWEAPON"))
		assert.is_false(U.ClassProficient(HUNTER, WEAPON, WAND, "INVTYPE_RANGEDRIGHT"))
		assert.is_true(U.ClassProficient(HUNTER, WEAPON, AXE1, "INVTYPE_WEAPON"))
		assert.is_true(U.ClassProficient(HUNTER, WEAPON, BOW, "INVTYPE_RANGED"))
		assert.is_true(U.ClassProficient(HUNTER, WEAPON, SWORD1, "INVTYPE_WEAPON"))
		assert.is_true(U.ClassProficient(HUNTER, WEAPON, POLEARM, "INVTYPE_2HWEAPON"))
	end)

	it("weapons per class: mage/warlock swords-staves-daggers-wands, priest maces, rogue no polearm, druid no sword, warrior everything but wands", function()
		assert.is_true(U.ClassProficient(MAGE, WEAPON, SWORD1, "INVTYPE_WEAPON"))
		assert.is_false(U.ClassProficient(MAGE, WEAPON, MACE1, "INVTYPE_WEAPON"))
		assert.is_true(U.ClassProficient(WARLOCK, WEAPON, WAND, "INVTYPE_RANGEDRIGHT"))
		assert.is_true(U.ClassProficient(PRIEST, WEAPON, MACE1, "INVTYPE_WEAPON"))
		assert.is_false(U.ClassProficient(PRIEST, WEAPON, SWORD1, "INVTYPE_WEAPON"))
		assert.is_false(U.ClassProficient(ROGUE, WEAPON, POLEARM, "INVTYPE_2HWEAPON"))
		assert.is_true(U.ClassProficient(ROGUE, WEAPON, DAGGER, "INVTYPE_WEAPON"))
		assert.is_false(U.ClassProficient(DRUID, WEAPON, SWORD1, "INVTYPE_WEAPON"))
		assert.is_true(U.ClassProficient(DRUID, WEAPON, STAFF, "INVTYPE_2HWEAPON"))
		assert.is_true(U.ClassProficient(SHAMAN, WEAPON, MACE2, "INVTYPE_2HWEAPON"))
		assert.is_false(U.ClassProficient(SHAMAN, WEAPON, SWORD1, "INVTYPE_WEAPON"))
		assert.is_true(U.ClassProficient(WARRIOR, WEAPON, POLEARM, "INVTYPE_2HWEAPON"))
		assert.is_false(U.ClassProficient(WARRIOR, WEAPON, WAND, "INVTYPE_RANGEDRIGHT"))
		assert.is_true(U.ClassProficient(PALADIN, WEAPON, MACE2, "INVTYPE_2HWEAPON"))
		assert.is_false(U.ClassProficient(PALADIN, WEAPON, DAGGER, "INVTYPE_WEAPON"))
	end)

	it("armour: a mage cannot wear plate; a hunter can wear cloth (allowed, if not what they gear in); shields are warrior/paladin/shaman", function()
		assert.is_false(U.ClassProficient(MAGE, ARMOR, PLATE, "INVTYPE_CHEST"))
		assert.is_false(U.ClassProficient(ROGUE, ARMOR, MAIL, "INVTYPE_LEGS"))
		assert.is_true(U.ClassProficient(HUNTER, ARMOR, CLOTH, "INVTYPE_WRIST"))
		assert.is_true(U.ClassProficient(HUNTER, ARMOR, MAIL, "INVTYPE_CHEST", 60))
		assert.is_false(U.ClassProficient(HUNTER, ARMOR, SHIELD, "INVTYPE_SHIELD"))
		assert.is_true(U.ClassProficient(WARRIOR, ARMOR, SHIELD, "INVTYPE_SHIELD"))
		assert.is_true(U.ClassProficient(PALADIN, ARMOR, SHIELD, "INVTYPE_SHIELD"))
		assert.is_true(U.ClassProficient(SHAMAN, ARMOR, SHIELD, "INVTYPE_SHIELD"))
		-- Cloaks, rings, necks, trinkets and held items are armour class 4 everyone wears.
		assert.is_true(U.ClassProficient(MAGE, ARMOR, CLOTH, "INVTYPE_CLOAK"))
		assert.is_true(U.ClassProficient(MAGE, ARMOR, 0, "INVTYPE_FINGER"))
	end)

	it("mail and plate are trained at 40: a level-13 hunter cannot wear mail, a level-39 warrior cannot wear plate", function()
		assert.equal(2, U.ArmorCap(HUNTER, 13))
		assert.equal(3, U.ArmorCap(HUNTER, 40))
		assert.equal(3, U.ArmorCap(HUNTER, nil), "no level means the trained cap")
		assert.equal(3, U.ArmorCap(WARRIOR, 39))
		assert.equal(4, U.ArmorCap(WARRIOR, 60))
		assert.equal(2, U.ArmorCap(ROGUE, 5), "leather is never level-gated")
		assert.is_nil(U.ArmorCap(99))
		assert.is_false(U.ClassProficient(HUNTER, ARMOR, MAIL, "INVTYPE_CHEST", 13))
		assert.is_true(U.ClassProficient(HUNTER, ARMOR, LEATHER, "INVTYPE_CHEST", 13))
		assert.is_false(U.ClassProficient(WARRIOR, ARMOR, PLATE, "INVTYPE_HEAD", 39))
	end)

	it("has no opinion on what it does not know: no class, a class off the table, trade goods, string ids", function()
		assert.is_true(U.ClassProficient(nil, WEAPON, MACE1, "INVTYPE_WEAPON"))
		assert.is_true(U.ClassProficient(99, WEAPON, MACE1, "INVTYPE_WEAPON"))
		assert.is_true(U.ClassProficient(HUNTER, 7, 0, ""), "trade goods are not gated")
		assert.is_true(U.ClassProficient(HUNTER, 0, 0, ""))
		assert.is_false(U.ClassProficient(HUNTER, "2", "4", "INVTYPE_WEAPON"), "the store's ids arrive as strings sometimes")
	end)

	it("pins the tables Dibs keeps: armour caps, shield classes, every weapon list", function()
		assert.same({ [1] = 4, [2] = 4, [3] = 3, [7] = 3, [4] = 2, [11] = 2, [5] = 1, [8] = 1, [9] = 1 }, U.CLASS_ARMOR)
		assert.same({ [1] = true, [2] = true, [7] = true }, U.CLASS_SHIELD)
		local function ids(set) local out = {} for k in pairs(set) do out[#out + 1] = k end table.sort(out) return out end
		assert.same({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18 }, ids(U.CLASS_WEAPONS[WARRIOR]))
		assert.same({ 0, 1, 4, 5, 6, 7, 8 }, ids(U.CLASS_WEAPONS[PALADIN]))
		assert.same({ 0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18 }, ids(U.CLASS_WEAPONS[HUNTER]))
		assert.same({ 0, 2, 3, 4, 7, 13, 15, 16, 18 }, ids(U.CLASS_WEAPONS[ROGUE]))
		assert.same({ 4, 10, 15, 19 }, ids(U.CLASS_WEAPONS[PRIEST]))
		assert.same({ 0, 1, 4, 5, 10, 13, 15 }, ids(U.CLASS_WEAPONS[SHAMAN]))
		assert.same({ 7, 10, 15, 19 }, ids(U.CLASS_WEAPONS[MAGE]))
		assert.same({ 7, 10, 15, 19 }, ids(U.CLASS_WEAPONS[WARLOCK]))
		assert.same({ 4, 5, 6, 10, 13, 15 }, ids(U.CLASS_WEAPONS[DRUID]))
		assert.same({ "INVTYPE_CHEST", "INVTYPE_FEET", "INVTYPE_HAND", "INVTYPE_HEAD", "INVTYPE_LEGS", "INVTYPE_ROBE", "INVTYPE_SHOULDER", "INVTYPE_WAIST", "INVTYPE_WRIST" },
			(function() local out = {} for k in pairs(U.BODY_ARMOR_LOC) do out[#out + 1] = k end table.sort(out) return out end)())
	end)
end)

describe("Usable.CanUse -- the four layers, and the seams they read through", function()
	local hunter = { classID = HUNTER, className = "Hunter", raceName = "Night Elf", level = 60 }

	before_each(function()
		env.reset()
		env.loadFile("Modules/Usable.lua")
		U = TOGBankClassic_Usable
		U.TooltipTexts = function() return nil end
		LibStub.libs["LibItemDB-1.0"] = nil
	end)

	it("level first: an item above the character's level is out before any other question is asked", function()
		local asked = false
		U.TooltipTexts = function() asked = true return {} end
		assert.is_false(U.CanUse({ ID = 1, class = 7, subClass = 0, reqLevel = 61 }, hunter))
		assert.is_false(asked, "the tooltip was read for an item the level already excludes")
		assert.is_true(U.CanUse({ ID = 1, class = 7, subClass = 0, reqLevel = 60 }, hunter))
		assert.is_true(U.CanUse({ ID = 1, class = 7, subClass = 0 }, hunter), "no required level is no requirement")
	end)

	it("proficiency: the mace the report was about", function()
		assert.is_false(U.CanUse({ ID = 2, class = WEAPON, subClass = MACE1, equipLoc = "INVTYPE_WEAPON", reqLevel = 50 }, hunter))
		assert.is_true(U.CanUse({ ID = 3, class = WEAPON, subClass = AXE1, equipLoc = "INVTYPE_WEAPON", reqLevel = 50 }, hunter))
	end)

	it("LibItemDB's class obtainability is asked when the library carries it, and only then", function()
		local asked = {}
		LibStub.libs["LibItemDB-1.0"] = { ClassUsable = function(_, id, classID) asked[#asked + 1] = { id, classID } return id ~= 16963 end }
		LibStub.minors["LibItemDB-1.0"] = 15
		assert.is_false(U.CanUse({ ID = 16963, class = ARMOR, subClass = MAIL, equipLoc = "INVTYPE_HEAD", reqLevel = 60 }, hunter), "a warrior tier helm passed for a hunter")
		assert.is_true(U.CanUse({ ID = 16939, class = ARMOR, subClass = MAIL, equipLoc = "INVTYPE_HEAD", reqLevel = 60 }, hunter))
		assert.same({ { 16963, HUNTER }, { 16939, HUNTER } }, asked)
		-- A library without the method (an older ItemDB) is simply not asked.
		LibStub.libs["LibItemDB-1.0"] = {}
		assert.is_true(U.CanUse({ ID = 16963, class = ARMOR, subClass = MAIL, equipLoc = "INVTYPE_HEAD", reqLevel = 60 }, hunter))
	end)

	it("the tooltip's Classes: and Races: tags, through the seam, remembered per item and character", function()
		local reads = 0
		U.TooltipTexts = function(id)
			reads = reads + 1
			if id == 100 then return { "Thing", "Classes: Warrior, Paladin" } end
			if id == 101 then return { "Thing", "Races: Night Elf, Dwarf" } end
			if id == 102 then return { "Thing", "Classes: Hunter", "Races: Orc" } end
			return { "Thing" }
		end
		local item = function(id) return { ID = id, class = 7, subClass = 0, reqLevel = 1 } end
		assert.is_false(U.CanUse(item(100), hunter), "a warrior/paladin-only item passed for a hunter")
		assert.is_true(U.CanUse(item(101), hunter))
		assert.is_false(U.CanUse(item(102), hunter), "the race tag was not checked once the class tag passed")
		assert.is_true(U.CanUse(item(103), hunter))
		local before = reads
		U.CanUse(item(100), hunter); U.CanUse(item(103), hunter)
		assert.equal(before, reads, "a remembered verdict was read again")
		-- Another character's answer is its own.
		assert.is_true(U.CanUse(item(100), { classID = WARRIOR, className = "Warrior", raceName = "Human", level = 60 }))
	end)

	it("an item the client has not cached is allowed and NOT remembered, so it is asked again", function()
		local calls = 0
		U.TooltipTexts = function() calls = calls + 1 return nil end
		local it_ = { ID = 5, class = 7, subClass = 0, reqLevel = 1 }
		assert.is_true(U.CanUse(it_, hunter))
		assert.is_true(U.CanUse(it_, hunter))
		assert.equal(2, calls)
	end)

	it("the default tooltip reader goes through C_TooltipInfo when the client has it, surfacing args, and answers nil without it", function()
		env.loadFile("Modules/Usable.lua")   -- the module's own reader back
		U = TOGBankClassic_Usable
		_G.C_TooltipInfo = nil
		assert.is_nil(U.TooltipTexts(1))
		_G.C_TooltipInfo = { GetItemByID = function(id)
			if id == 7 then return nil end
			return { lines = { { leftText = "Robe" }, { args = { { field = "leftText", stringVal = "Classes: Mage" } } } } }
		end }
		_G.TooltipUtil = { SurfaceArgs = function(line) for _, a in ipairs(line.args or {}) do line[a.field] = a.stringVal end end }
		assert.is_nil(U.TooltipTexts(7), "an uncached item must read as 'cannot say', not as 'no tags'")
		assert.same({ "Robe", "Classes: Mage" }, U.TooltipTexts(8))
		_G.C_TooltipInfo, _G.TooltipUtil = nil, nil
	end)

	-- Classic Era's API documentation lists no C_TooltipInfo.GetItemByID, so the reader every
	-- Classic addon uses stands behind it: a hidden scanning tooltip, read line by line.
	it("without C_TooltipInfo, reads a hidden scanning tooltip -- and only for an item the client has cached", function()
		require("env.frames").reset()
		env.loadFile("Modules/Usable.lua")
		U = TOGBankClassic_Usable
		_G.C_TooltipInfo = nil
		local tip = CreateFrame("GameTooltip", "TOGBankClassicUsableScanTooltip", UIParent, "GameTooltipTemplate")
		local asked = {}
		tip.SetHyperlink = function(self, link)
			asked[#asked + 1] = link
			self:AddLine("Blesswind Hammer")
			self:AddLine("Classes: Warrior, Paladin")
		end
		-- The frame model's reset reinstalls the harness's own GetItemInfo over env_togbank's, so the
		-- cache is stood in for directly: item 9 is cached, nothing else is.
		_G.GetItemInfo = function(id) if id == 9 then return "Blesswind Hammer" end return nil end
		assert.equal(tip, _G.TOGBankClassicUsableScanTooltip, "fixture: the named tooltip is not the global")
		assert.same({ "Blesswind Hammer", "Classes: Warrior, Paladin" }, U.TooltipTexts(9))
		assert.same({ "item:9" }, asked)
		assert.is_false(tip:IsShown(), "the scanning tooltip was left showing")
		-- An item GetItemInfo does not know is 'cannot say', and the tooltip is not asked.
		assert.is_nil(U.TooltipTexts(424242))
		assert.equal(1, #asked)
		-- The whole gate, end to end, with no C_TooltipInfo: the class tag hides the hammer.
		assert.is_false(U.CanUse({ ID = 9, class = 7, subClass = 0, reqLevel = 1 }, hunter))
	end)

	it("Player() reads the live character, defaulting the level to 60 when the client cannot say", function()
		_G.UnitClass = function() return "Hunter", "HUNTER", 3 end
		_G.UnitRace = function() return "Night Elf" end
		_G.UnitLevel = function() return 42 end
		assert.same({ classID = 3, className = "Hunter", raceName = "Night Elf", level = 42 }, U.Player())
		_G.UnitLevel = nil
		assert.equal(60, U.Player().level)
	end)

	it("is loaded by both TOCs before the UI files that read it", function()
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_BCC.toc" }) do
			local src = env.readFile(toc)
			local usable, ui = src:find("Modules/Usable.lua", 1, true), src:find("Modules/UI.lua", 1, true)
			assert.is_not_nil(usable, toc .. " does not load Usable.lua")
			assert.is_true(usable < ui, toc .. " loads Usable.lua after the UI")
		end
	end)
end)
