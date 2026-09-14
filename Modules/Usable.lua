-- Modules/Usable.lua -- can THIS character use an item? (the Guild Bank window's "Usable by me")
--
-- BROWSE-004. The first two cuts were wrong in the same way: the required level alone filters
-- nothing at 60, and a scan of the item tooltip for red lines was not finding the weapon line a
-- hunter cannot use -- the operator: "the usable by me filter still isn't working. as a hunter i
-- can't use hammers, you may want to use some of what dibs did for the filtering". So this is
-- Dibs' gate (Dibs/Data/ItemSources.lua, Items:CanUse), ported: a DATA answer built from the
-- item's class / subclass / slot and the character's class, in four layers, cheapest first --
--   1. LEVEL: the item's required level against the character's.
--   2. CLASS OBTAINABILITY from LibItemDB (`ClassUsable`): the tier and dungeon sets, Atiesh, the
--      items Blizzard's own tag mis-flags as usable by everyone. Feature-detected.
--   3. PROFICIENCY -- the rules LibItemDB does not carry and Dibs keeps as logic: which armour
--      material a class may wear, who can hold a shield, which weapon subclasses each class can
--      wield. Vanilla's tables. A hunter and a mace: this is the layer that says no.
--   4. The tooltip's "Classes:" / "Races:" tags, remembered per item and character. Through
--      C_TooltipInfo where the client has it; on Classic Era assume it does not -- Blizzard's own
--      Blizzard_SharedXMLGame.toc loads TooltipUtil and TooltipComparisonManager for mainline
--      only and excludes TooltipDataHandler on vanilla, so not one line of Era's UI calls it --
--      and read a hidden scanning tooltip instead (TooltipTexts).
-- TABLES COPIED, GATE RE-DERIVED. The five tables are character-for-character Dibs' (a second
-- addon, not a library, so they cannot be loaded from it; their proper home is LibItemDB, raised
-- there rather than moved) and `Tests/usable_spec.lua` pins the values so a drift in either addon
-- shows. The GATE is not Dibs' verbatim, on purpose: (a) Dibs' ClassProficient reads the armour
-- cap raw and keeps the level-40 step for "what does this class GEAR in"; here the cap is
-- level-aware, because for a bank browse a level-39 hunter cannot wear mail and that is the
-- question. (b) Dibs' CanUse has a FACTION layer (LibItemDB GetItemFaction); a guild bank is one
-- faction, so it is left out. Neither is a slip to "fix" in either direction.
-- Why the first cut (a red-line scan of the tooltip) let a hunter see maces, most likely: the
-- slot and type are ONE double line -- "Main Hand" on the LEFT, "Mace" on the RIGHT -- and the
-- red is on the RIGHT text; that scan read TextLeft only. Classes:/Races: are left-side lines,
-- so the reader below is the right one for the tags.
-- THE subClass EDGE (peer review, self-audits 1 and 2 -- recorded here so it outlives the inbox):
-- subclass 0 is a REAL value, not "unknown" -- weapon 0 is a one-handed Axe, armour 0 is
-- Miscellaneous (shirts, tabards) -- so ClassProficient must never treat 0 as absent; it does not
-- (`tonumber`, then `subClassID and ...` for weapons, `(subClassID or 0) > cap` for armour, where
-- the `or 0` only stands in for a NIL subclass). A nil subclass -- an item the offline database
-- and the client both lack info for -- passes every proficiency layer: fail-OPEN, the same rule as
-- an uncached tooltip, so a bank browse never hides an item on missing data. Not measured in game.

TOGBankClassic_Usable = {}
local Usable = TOGBankClassic_Usable

local function idset(...)
	local t = {}
	for i = 1, select("#", ...) do t[select(i, ...)] = true end
	return t
end

-- Max armour subclass a class wears (Cloth 1 < Leather 2 < Mail 3 < Plate 4).
local CLASS_ARMOR = {
	[1] = 4, [2] = 4,           -- Warrior, Paladin -- Plate
	[3] = 3, [7] = 3,           -- Hunter, Shaman -- Mail
	[4] = 2, [11] = 2,          -- Rogue, Druid -- Leather
	[5] = 1, [8] = 1, [9] = 1,  -- Priest, Mage, Warlock -- Cloth
}
-- Vanilla grants Mail to hunters and shamans, and Plate to warriors and paladins, at level 40;
-- before that the cap is one tier down. A rule that always allowed the level-60 material would
-- call a level-13 hunter's mail drop usable.
local ARMOR_TRAINED_AT_40 = { [1] = 4, [2] = 4, [3] = 3, [7] = 3 }
-- Classes that can equip a shield (armour subclass 6).
local CLASS_SHIELD = { [1] = true, [2] = true, [7] = true }   -- Warrior, Paladin, Shaman
-- Weapon subclass ids each class can wield (LE_ITEM_WEAPON_*: 0 axe1H, 1 axe2H, 2 bow, 3 gun,
-- 4 mace1H, 5 mace2H, 6 polearm, 7 sword1H, 8 sword2H, 10 staff, 13 fist, 15 dagger, 16 thrown,
-- 18 crossbow, 19 wand).
local CLASS_WEAPONS = {
	[1]  = idset(0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18),  -- Warrior (all but wand)
	[2]  = idset(0, 1, 4, 5, 6, 7, 8),                            -- Paladin (1H+2H axe/mace/sword, polearm)
	[3]  = idset(0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18),        -- Hunter (no mace, no wand)
	[4]  = idset(0, 2, 3, 4, 7, 13, 15, 16, 18),                  -- Rogue (1H only; no polearm/staff/wand)
	[5]  = idset(4, 10, 15, 19),                                  -- Priest (1H mace, staff, dagger, wand)
	[7]  = idset(0, 1, 4, 5, 10, 13, 15),                         -- Shaman (1H+2H axe/mace, staff, fist, dagger)
	[8]  = idset(7, 10, 15, 19),                                  -- Mage (1H sword, staff, dagger, wand)
	[9]  = idset(7, 10, 15, 19),                                  -- Warlock (1H sword, staff, dagger, wand)
	[11] = idset(4, 5, 6, 10, 13, 15),                            -- Druid (1H+2H mace, polearm, staff, fist, dagger)
}
-- equipLocs that ARE body armour (bound by armour proficiency). Cloak / neck / finger / trinket /
-- held / relic are armour too but everyone wears them, so they are NOT here.
local BODY_ARMOR_LOC = {
	INVTYPE_HEAD = true, INVTYPE_SHOULDER = true, INVTYPE_CHEST = true, INVTYPE_ROBE = true,
	INVTYPE_WRIST = true, INVTYPE_HAND = true, INVTYPE_WAIST = true, INVTYPE_LEGS = true,
	INVTYPE_FEET = true,
}
Usable.CLASS_ARMOR, Usable.CLASS_SHIELD, Usable.CLASS_WEAPONS, Usable.BODY_ARMOR_LOC = CLASS_ARMOR, CLASS_SHIELD, CLASS_WEAPONS, BODY_ARMOR_LOC

--- The armour material `classID` may wear at `level`; nil for a class the table does not know.
function Usable.ArmorCap(classID, level)
	local cap = CLASS_ARMOR[classID]
	if not cap then return nil end
	if ARMOR_TRAINED_AT_40[classID] and level and level < 40 then return cap - 1 end
	return cap
end

--- Does `classID` have the ARMOUR / SHIELD / WEAPON proficiency for an item of
--- (itemClassID, subClassID, equipLoc)? Non-armour/weapon items (rings, trinkets, recipes, trade
--- goods) pass; so does a class the tables do not know. Pure.
function Usable.ClassProficient(classID, itemClassID, subClassID, equipLoc, level)
	if not classID then return true end
	itemClassID, subClassID = tonumber(itemClassID), tonumber(subClassID)
	if itemClassID == 4 then          -- armour
		if subClassID == 6 then                                   -- shield
			return CLASS_SHIELD[classID] and true or false
		elseif BODY_ARMOR_LOC[equipLoc] then                      -- body armour: cloth < leather < mail < plate
			local cap = Usable.ArmorCap(classID, level)
			return not (cap and (subClassID or 0) > cap)
		end
	elseif itemClassID == 2 then      -- weapon
		local allowed = CLASS_WEAPONS[classID]
		if allowed and subClassID and not allowed[subClassID] then return false end
	end
	return true
end

-- ─── The tooltip's Classes: / Races: tags ───────────────────────────────────────

local CLASSES_PREFIX = ITEM_CLASSES_ALLOWED and ITEM_CLASSES_ALLOWED:gsub("%%s.*", "") or "Classes:"
local RACES_PREFIX   = ITEM_RACES_ALLOWED   and ITEM_RACES_ALLOWED:gsub("%%s.*", "")   or "Races:"
-- Per character (class|race), then by item id -- Dibs' shape -- so the hit path in the filter's
-- hot loop allocates nothing; a string key per row per keystroke was garbage for no reason.
local tagCache = {}
local function tagCacheFor(className, raceName)
	local key = tostring(className) .. "|" .. tostring(raceName)
	local t = tagCache[key]
	if not t then t = {}; tagCache[key] = t end
	return t
end

local SCAN_TOOLTIP = "TOGBankClassicUsableScanTooltip"

--- The text lines of an item's tooltip, or nil when the client cannot say yet (the item not
--- cached). Through C_TooltipInfo where the client has it; otherwise -- and Classic Era's API
--- documentation does not list C_TooltipInfo.GetItemByID, so assume it does not -- off a hidden
--- scanning tooltip, the way every Classic addon reads a tooltip. The seam a spec replaces.
---@return table|nil lines
function Usable.TooltipTexts(itemID)
	if C_TooltipInfo and C_TooltipInfo.GetItemByID then
		local data = C_TooltipInfo.GetItemByID(itemID)
		if not (data and data.lines) then return nil end
		local out = {}
		for _, line in ipairs(data.lines) do
			if line.leftText == nil and TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(line) end
			if line.leftText then out[#out + 1] = line.leftText end
		end
		return out
	end
	if not (CreateFrame and GetItemInfo) then return nil end
	-- Not cached: SetHyperlink would show a placeholder and answer nothing useful. GetItemInfo is
	-- nil for an uncached item and asks the server for it, so the next pass can read it.
	if not GetItemInfo(itemID) then return nil end
	local tip = _G[SCAN_TOOLTIP]
	if not tip then tip = CreateFrame("GameTooltip", SCAN_TOOLTIP, UIParent, "GameTooltipTemplate") end
	tip:SetOwner(UIParent, "ANCHOR_NONE")
	tip:ClearLines()
	tip:SetHyperlink("item:" .. tostring(itemID))
	local out = {}
	for i = 1, tip:NumLines() do
		local fs = _G[SCAN_TOOLTIP .. "TextLeft" .. i]
		local text = fs and fs:GetText()
		if text and text ~= "" then out[#out + 1] = text end
	end
	tip:Hide()
	return out
end

--- Do the item's "Classes:" / "Races:" tags allow `className` / `raceName` (localized, as
--- UnitClass / UnitRace report them)? True when the item carries no tag they fail, or when the
--- client cannot say yet (not cached and not remembered, so it is asked again next time).
function Usable.TagsAllow(itemID, className, raceName)
	local cache = tagCacheFor(className, raceName)
	local cached = cache[itemID]
	if cached ~= nil then return cached end
	local lines = Usable.TooltipTexts(itemID)
	if not lines then return true end
	local ok = true
	for _, text in ipairs(lines) do
		if text:find(CLASSES_PREFIX, 1, true) == 1 then
			if not (className and text:find(className, 1, true)) then ok = false break end
		elseif text:find(RACES_PREFIX, 1, true) == 1 then
			if not (raceName and text:find(raceName, 1, true)) then ok = false break end
		end
	end
	cache[itemID] = ok
	return ok
end

-- ─── The gate ──────────────────────────────────────────────────────────────────

--- The character as the gate sees them: class id and name, race name, level. Read live -- the
--- level changes, and a spec sets the globals.
function Usable.Player()
	local className, _, classID
	if UnitClass then className, _, classID = UnitClass("player") end
	return {
		classID = classID, className = className,
		raceName = UnitRace and UnitRace("player") or nil,
		level = (UnitLevel and UnitLevel("player")) or 60,
	}
end

--- Can the character use this item? `item` is `{ ID=, class=, subClass=, equipLoc=, reqLevel= }`
--- (a Browse row carries all five). `player` defaults to the live character.
---@return boolean
function Usable.CanUse(item, player)
	player = player or Usable.Player()
	if (tonumber(item.reqLevel) or 0) > (player.level or 60) then return false end
	local lib = LibStub and LibStub:GetLibrary("LibItemDB-1.0", true)
	if lib and lib.ClassUsable and player.classID and item.ID then
		if not lib:ClassUsable(item.ID, player.classID) then return false end
	end
	if not Usable.ClassProficient(player.classID, item.class, item.subClass, item.equipLoc, player.level) then return false end
	if item.ID and not Usable.TagsAllow(item.ID, player.className, player.raceName) then return false end
	return true
end
