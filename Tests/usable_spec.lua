-- BROWSE-004 -- "Usable by me" is DATA: Dibs' gate, ported (Modules/Usable.lua).
--
-- The operator, a level-60 hunter on the Guild Bank window: "the usable by me filter still isn't
-- working. as a hunter i can't use hammers, you may want to use some of what dibs did for the
-- filtering". Four layers: level, LibItemDB's class obtainability, the proficiency rules, the
-- tooltip's Classes:/Races: tags. USABLE-LIBITEMDB-001: the proficiency rules are LibItemDB's
-- (ItemDB v0.10.0, MINOR 27), no longer a copy here, so the proficiency examples run against the
-- INSTALLED library. ItemDB's own suite pins the table values (ported from this file); what stays
-- here is TOGBank's behaviour through it.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")
local libs = require("env.libs")

--- The real LibItemDB, registered fresh; pending when ItemDB is not installed beside this addon.
local function realItemDB()
	if not libs.available("LibItemDB-1.0") then pending("ItemDB is not installed beside this addon") end
	libs.fresh("LibItemDB-1.0")
	local lib = LibStub("LibItemDB-1.0")
	assert.is_function(lib.ClassProficient, "the installed ItemDB is older than MINOR 27 -- no ClassProficient")
	return lib
end

local WARRIOR, PALADIN, HUNTER, ROGUE, PRIEST, SHAMAN, MAGE, WARLOCK, DRUID = 1, 2, 3, 4, 5, 7, 8, 9, 11
local ARMOR, WEAPON = 4, 2
local CLOTH, LEATHER, MAIL, PLATE, SHIELD = 1, 2, 3, 4, 6
local AXE1, MACE1, MACE2, POLEARM, SWORD1, STAFF, DAGGER, WAND, BOW = 0, 4, 5, 6, 7, 10, 15, 19, 2

local U

describe("Usable.ClassProficient -- LibItemDB's rules, through TOGBank", function()
	before_each(function()
		env.reset()
		env.loadFile("Modules/Usable.lua")
		U = TOGBankClassic_Usable
		realItemDB()
	end)
	-- The real library must not outlive this file (SPEC-ORDER-001): another spec that feature-detects
	-- LibItemDB would silently find it.
	after_each(function() libs.forget("LibItemDB-1.0") end)

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
		assert.is_false(U.ClassProficient(HUNTER, ARMOR, MAIL, "INVTYPE_CHEST", 13))
		assert.is_true(U.ClassProficient(HUNTER, ARMOR, MAIL, "INVTYPE_CHEST", 40))
		assert.is_true(U.ClassProficient(HUNTER, ARMOR, MAIL, "INVTYPE_CHEST"), "no level means the trained cap")
		assert.is_true(U.ClassProficient(HUNTER, ARMOR, LEATHER, "INVTYPE_CHEST", 13))
		assert.is_false(U.ClassProficient(WARRIOR, ARMOR, PLATE, "INVTYPE_HEAD", 39))
		assert.is_true(U.ClassProficient(WARRIOR, ARMOR, PLATE, "INVTYPE_HEAD", 60))
		assert.is_true(U.ClassProficient(ROGUE, ARMOR, LEATHER, "INVTYPE_LEGS", 5), "leather is never level-gated")
	end)

	it("has no opinion on what it does not know: no class, a class off the table, trade goods, string ids", function()
		assert.is_true(U.ClassProficient(nil, WEAPON, MACE1, "INVTYPE_WEAPON"))
		assert.is_true(U.ClassProficient(99, WEAPON, MACE1, "INVTYPE_WEAPON"))
		assert.is_true(U.ClassProficient(HUNTER, 7, 0, ""), "trade goods are not gated")
		assert.is_true(U.ClassProficient(HUNTER, 0, 0, ""))
		assert.is_false(U.ClassProficient(HUNTER, "2", "4", "INVTYPE_WEAPON"), "the store's ids arrive as strings sometimes")
	end)

	it("subclass 0 is a real value (a one-handed axe), and a nil subclass is 'cannot say', allowed", function()
		assert.is_false(U.ClassProficient(PRIEST, WEAPON, 0, "INVTYPE_WEAPON"), "a priest was allowed a 1H axe: 0 read as unknown")
		assert.is_true(U.ClassProficient(PRIEST, WEAPON, nil, "INVTYPE_WEAPON"))
		assert.is_true(U.ClassProficient(MAGE, ARMOR, nil, "INVTYPE_CHEST"))
	end)

	-- The one answer the switch changed, on purpose (LibItemDB-1.0.lua:2121-2125): TOGBank's copy
	-- said a class off the table could not hold a shield while allowing it everything else.
	it("a class the tables do not know may hold a shield, like everything else it is not refused", function()
		assert.is_true(U.ClassProficient(99, ARMOR, SHIELD, "INVTYPE_SHIELD"))
		assert.is_false(U.ClassProficient(MAGE, ARMOR, SHIELD, "INVTYPE_SHIELD"), "a known class without shields was allowed one")
	end)

	it("keeps no copy of the rules: the module holds no proficiency tables of its own", function()
		for _, name in ipairs({ "CLASS_ARMOR", "CLASS_SHIELD", "CLASS_WEAPONS", "BODY_ARMOR_LOC", "ArmorCap" }) do
			assert.is_nil(U[name], "Usable still carries " .. name)
		end
	end)
end)

describe("Usable.ClassProficient without LibItemDB's rules", function()
	before_each(function()
		env.reset()
		env.loadFile("Modules/Usable.lua")
		U = TOGBankClassic_Usable
	end)
	after_each(function() LibStub.libs["LibItemDB-1.0"] = nil end)

	it("allows everything when the library is missing or older than MINOR 27 -- a browse never hides on missing data", function()
		LibStub.libs["LibItemDB-1.0"] = nil
		assert.is_true(U.ClassProficient(HUNTER, WEAPON, MACE1, "INVTYPE_WEAPON"))
		LibStub.libs["LibItemDB-1.0"] = { ClassUsable = function() return true end }
		assert.is_true(U.ClassProficient(HUNTER, WEAPON, MACE1, "INVTYPE_WEAPON"))
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
	-- One example registers the real library; it must not outlive this file (SPEC-ORDER-001).
	after_each(function() libs.forget("LibItemDB-1.0") end)

	it("level first: an item above the character's level is out before any other question is asked", function()
		local asked = false
		U.TooltipTexts = function() asked = true return {} end
		assert.is_false(U.CanUse({ ID = 1, class = 7, subClass = 0, reqLevel = 61 }, hunter))
		assert.is_false(asked, "the tooltip was read for an item the level already excludes")
		assert.is_true(U.CanUse({ ID = 1, class = 7, subClass = 0, reqLevel = 60 }, hunter))
		assert.is_true(U.CanUse({ ID = 1, class = 7, subClass = 0 }, hunter), "no required level is no requirement")
	end)

	it("proficiency: the mace the report was about", function()
		local lib = realItemDB()
		-- Isolate the proficiency layer: the real ClassUsable would ask the item data for ids 2 and 3.
		lib.ClassUsable = function() return true end
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
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_TBC.toc", "TOGBankClassic_Mists.toc" }) do
			local src = env.readFile(toc)
			local usable, ui = src:find("Modules/Usable.lua", 1, true), src:find("Modules/UI.lua", 1, true)
			assert.is_not_nil(usable, toc .. " does not load Usable.lua")
			assert.is_true(usable < ui, toc .. " loads Usable.lua after the UI")
		end
	end)
end)
