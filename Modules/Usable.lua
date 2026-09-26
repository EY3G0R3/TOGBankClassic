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
--   3. PROFICIENCY -- which armour material a class may wear, who can hold a shield, which weapon
--      subclasses each class can wield. A hunter and a mace: this is the layer that says no.
--      LibItemDB's `ClassProficient` (ItemDB v0.10.0, MINOR 27) since USABLE-LIBITEMDB-001.
--   4. The tooltip's "Classes:" / "Races:" tags, remembered per item and character. Through
--      C_TooltipInfo where the client has it; on Classic Era assume it does not -- Blizzard's own
--      Blizzard_SharedXMLGame.toc loads TooltipUtil and TooltipComparisonManager for mainline
--      only and excludes TooltipDataHandler on vanilla, so not one line of Era's UI calls it --
--      and read a hidden scanning tooltip instead (TooltipTexts).
-- USABLE-LIBITEMDB-001: the proficiency tables were a copy of Dibs', kept here until they had a
-- proper home. ItemDB v0.10.0 took them (the same values, level-aware armour cap included), so
-- this file asks the library and keeps no copy. The one difference the library made on purpose:
-- a class its tables do not know is allowed a SHIELD too (this copy said no), matching the other
-- proficiency answers for that class. An ItemDB older than MINOR 27 has no `ClassProficient`, and
-- then this layer allows everything -- fail-open, like every other layer here. The gate still has
-- no FACTION layer (LibItemDB GetItemFaction): a guild bank is one faction.
-- Why the first cut (a red-line scan of the tooltip) let a hunter see maces, most likely: the
-- slot and type are ONE double line -- "Main Hand" on the LEFT, "Mace" on the RIGHT -- and the
-- red is on the RIGHT text; that scan read TextLeft only. Classes:/Races: are left-side lines,
-- so the reader below is the right one for the tags.
-- THE subClass EDGE (peer review, self-audits 1 and 2 -- recorded here so it outlives the inbox):
-- subclass 0 is a REAL value, not "unknown" -- weapon 0 is a one-handed Axe, armour 0 is
-- Miscellaneous (shirts, tabards) -- so ClassProficient must never treat 0 as absent. LibItemDB's
-- does not (its doc comment says so, LibItemDB-1.0.lua:2114), and `Tests/usable_spec.lua` pins
-- both edges against the installed library. A nil subclass -- an item the offline database and
-- the client both lack info for -- passes every proficiency layer: fail-OPEN, the same rule as an
-- uncached tooltip, so a bank browse never hides an item on missing data. Not measured in game.

TOGBankClassic_Usable = {}
local Usable = TOGBankClassic_Usable

--- The installed LibItemDB, or nil. Looked up per call: a spec swaps it, and so could a reload.
local function itemDB()
	return LibStub and LibStub:GetLibrary("LibItemDB-1.0", true)
end

--- Does `classID` have the ARMOUR / SHIELD / WEAPON proficiency for an item of
--- (itemClassID, subClassID, equipLoc) at `level`? LibItemDB's answer (USABLE-LIBITEMDB-001);
--- true when the library cannot say.
function Usable.ClassProficient(classID, itemClassID, subClassID, equipLoc, level)
	local lib = itemDB()
	if not (lib and lib.ClassProficient) then return true end
	return lib:ClassProficient(classID, itemClassID, subClassID, equipLoc, level) and true or false
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
	local lib = itemDB()
	if lib and lib.ClassUsable and player.classID and item.ID then
		if not lib:ClassUsable(item.ID, player.classID) then return false end
	end
	if not Usable.ClassProficient(player.classID, item.class, item.subClass, item.equipLoc, player.level) then return false end
	if item.ID and not Usable.TagsAllow(item.ID, player.className, player.raceName) then return false end
	return true
end
