-- GSL-MERGE-001 (v1.7.0): the guild's SHOPPING LIST -- what the guild wants crafted or gathered,
-- and the reagents that takes, checked against what the bank already holds. GuildShoppingList's one
-- genuinely new idea, rebuilt on this addon's rails (docs/GSL_MERGE.md). This file is the MODEL:
-- no frames.
--
-- THE LIST lives in the guild settings (`Info.settings.craftList`), so it rides the settings
-- broadcast, its per-field stamps and the ten-minute re-announcement with nothing new on the wire
-- (D1). Each ENTRY carries its own stamp (`craftListStamps[key]`) and a receiver merges entry by
-- entry -- two writers editing different entries both land -- and a removal keeps its stamp, so an
-- older copy cannot bring the entry back. The `bankerOwners` / `bankerOwnerStamps` pair is the
-- precedent, merge rule for merge rule.
--
-- An entry is either a RECIPE (`{ p = profId, r = recipeId, n = count }`, keyed "r<profId>:<recipeId>")
-- whose reagents LibProfessionDB-1.0 supplies, keyed by item id (D3), or a plain WANTED ITEM
-- (`{ i = itemID, n = count }`, keyed "i<itemID>") -- GuildShoppingList's Miscellaneous bucket, turn-in
-- items that are not recipes.
--
-- WHO WRITES (D2, the operator 2026-09-25: "so the GSL player is a tag like gbank, use what is in the
-- GSL app for that. the officers/gm should be able to edit the shopping list"): the GM, officers, and
-- any home-guild member whose PUBLIC note carries `[GSL]` -- GuildShoppingList's own marker, matched
-- as it matches it, so a guild's existing tag keeps working. Everyone reads it. A sister guild's list
-- is its own and never crosses (XGUILD-SETTINGS-001).
TOGBankClassic_CraftList = TOGBankClassic_CraftList or {}
local CraftList = TOGBankClassic_CraftList

-- Bounds, so a misbehaving sender cannot grow the settings broadcast. GuildShoppingList's lists run
-- to a few dozen entries; a removal keeps its stamp, hence twice the entry cap for the stamps.
CraftList.MAX_ENTRIES = 200
CraftList.MAX_STAMPS  = CraftList.MAX_ENTRIES * 2
CraftList.MAX_COUNT   = 9999
-- GSL-MERGE-001 step 5: the stamp an imported GuildShoppingList entry carries (see ImportGSL).
CraftList.IMPORT_STAMP = 1

--- The library, or nil when ProfessionDB is not installed. Looked up per call: a load-on-demand or
--- late-loading copy must be found once it is there.
local function DB()
	local db = LibStub and LibStub("LibProfessionDB-1.0", true)
	if db and db.IsReady and db:IsReady() then return db end
	return nil
end
CraftList.DB = DB

--- An item's descriptor (name, link, icon, quality, ...) through the addon's ONE item resolver --
--- LibItemDB first, the client second, a placeholder last (Modules/Inventory/Resolve.lua). The same
--- path every inventory window names its rows by; nothing here reads GetItemInfo itself.
local function describe(itemID)
	local Resolve, Record = TOGBankClassic_Inventory_Resolve, TOGBankClassic_Inventory_Record
	if not (Resolve and Record and itemID) then return { name = "Item " .. tostring(itemID) } end
	return Resolve.describe(Record.new(itemID, 1))
end
CraftList.Describe = describe

--- The key an entry is stored under.
function CraftList.RecipeKey(profId, recipeId) return "r" .. tostring(profId) .. ":" .. tostring(recipeId) end
function CraftList.ItemKey(itemID) return "i" .. tostring(itemID) end

local function wholePositive(v)
	v = tonumber(v)
	if not v or v ~= v or v < 1 then return nil end
	return math.floor(v)
end

--- One inbound entry in the canonical shape, or nil when malformed. The key must agree with the
--- entry, so a sender cannot file a recipe under another recipe's key.
local function sanitizeEntry(key, e)
	if type(key) ~= "string" or type(e) ~= "table" then return nil end
	local n = wholePositive(e.n)
	if not n then return nil end
	n = math.min(n, CraftList.MAX_COUNT)
	local p, r, i = wholePositive(e.p), wholePositive(e.r), wholePositive(e.i)
	if p and r and not i then
		if key ~= CraftList.RecipeKey(p, r) then return nil end
		return { p = p, r = r, n = n }
	elseif i and not p and not r then
		if key ~= CraftList.ItemKey(i) then return nil end
		return { i = i, n = n }
	end
	return nil
end

--- Sanitize an inbound list into `{ [key] = entry }`, capped. Returns a fresh table.
function CraftList.SanitizeList(list)
	local clean, count = {}, 0
	if type(list) ~= "table" then return clean end
	-- Sorted, so which entries survive the cap does not depend on `pairs` order.
	local keys = {}
	for key in pairs(list) do if type(key) == "string" then keys[#keys + 1] = key end end
	table.sort(keys)
	for _, key in ipairs(keys) do
		if count >= CraftList.MAX_ENTRIES then break end
		local e = sanitizeEntry(key, list[key])
		if e then
			clean[key] = e
			count = count + 1
		end
	end
	return clean
end

--- Sanitize an inbound per-entry stamp table into `{ [key] = number }`, capped; entries the list
--- names are kept first, so the cap only ever drops the stamp of a removal.
function CraftList.SanitizeStamps(stamps, list)
	local clean, count = {}, 0
	if type(stamps) ~= "table" then return clean end
	local keys = {}
	for key in pairs(stamps) do if type(key) == "string" then keys[#keys + 1] = key end end
	table.sort(keys)
	for pass = 1, 2 do
		for _, key in ipairs(keys) do
			local v = tonumber(stamps[key])
			local named = type(list) == "table" and list[key] ~= nil
			if v and v == v and v > 0 and (pass == 1) == named and clean[key] == nil and count < CraftList.MAX_STAMPS then
				clean[key] = math.floor(v)
				count = count + 1
			end
		end
	end
	return clean
end

-- A gather-window date: "YYYY-MM-DD", or "" for none.
local function sanitizeDate(d)
	if type(d) ~= "string" then return nil end
	if d == "" then return "" end
	local y, m, day = d:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	y, m, day = tonumber(y), tonumber(m), tonumber(day)
	if not (y and m and day) or m < 1 or m > 12 or day < 1 or day > 31 then return nil end
	return d
end
CraftList.SanitizeDate = sanitizeDate

-- ---------------------------------------------------------------------------
-- Who may write
-- ---------------------------------------------------------------------------

--- Does `player` (a home-guild member) carry GuildShoppingList's `[GSL]` marker in their PUBLIC
--- note? GuildShoppingList.lua:799 reads the public note with `note:find("%[GSL%]")`; the same test,
--- as a plain find. Read from the guild roster directly -- memberRoster keeps notes only for bank
--- characters, and this is asked on a write or a receive, not per frame.
---@param player string|nil
---@return boolean
function CraftList:IsGSLPlayer(player)
	local G = TOGBankClassic_Guild
	if not (player and G) then return false end
	local norm = G:NormalizeName(player) or player
	if G.IsHomeMember and G.RosterEntry and G:RosterEntry(norm) and not G:IsHomeMember(norm) then return false end
	for i = 1, (GetNumGuildMembers and GetNumGuildMembers() or 0) do
		local name, _, _, _, _, _, publicNote = GetGuildRosterInfo(i)
		if name and (G:NormalizeName(name) or name) == norm then
			return type(publicNote) == "string" and publicNote:find("[GSL]", 1, true) ~= nil
		end
	end
	return false
end

--- GSL-SENDTO-001 (the operator 2026-09-26: "on the shopping list tab, we need to show who is the
--- GSL character, so people know who to send items to"): every home-guild member carrying `[GSL]`
--- in their PUBLIC note -- IsGSLPlayer's test -- with whether they are online, sorted by name.
---@return table players { { name = string, online = boolean }, ... }
function CraftList:GSLPlayers()
	local out = {}
	for i = 1, (GetNumGuildMembers and GetNumGuildMembers() or 0) do
		local name, _, _, _, _, _, publicNote, _, online = GetGuildRosterInfo(i)
		if name and type(publicNote) == "string" and publicNote:find("[GSL]", 1, true) then
			out[#out + 1] = { name = name, online = online and true or false }
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

--- May `player` change the shopping list? The GM, an officer, or the `[GSL]`-tagged member.
---@param player string|nil
---@return boolean
function CraftList:CanEdit(player)
	local G = TOGBankClassic_Guild
	if not (player and G) then return false end
	if G:SenderIsGM(player) or G:SenderIsOfficer(player) then return true end
	return self:IsGSLPlayer(player)
end

--- May the player at the keyboard change it?
function CraftList:CanEditHere()
	local G = TOGBankClassic_Guild
	return G ~= nil and self:CanEdit(G:GetNormalizedPlayer())
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

local function settings()
	local G = TOGBankClassic_Guild
	return G and G.Info and G.Info.settings or nil
end

--- The list as held: `{ [key] = entry }` (sanitized; empty when none).
function CraftList:GetList()
	local s = settings()
	return CraftList.SanitizeList(s and s.craftList)
end

--- The gather window as held: start, finish ("YYYY-MM-DD" or "").
function CraftList:GetGatherWindow()
	local s = settings()
	return sanitizeDate(s and s.gatherStart) or "", sanitizeDate(s and s.gatherEnd) or ""
end

--- One display row per entry, sorted by name: `{ key, kind = "recipe"|"item", profId, recipeId,
--- itemID, item, name, count, known }`. `itemID` is the crafted item for a recipe (nil for an
--- enchant), `item` its descriptor from the item resolver; a recipe is named by LibProfessionDB.
--- `known` is false for a recipe the installed library does not carry.
function CraftList:Entries()
	local db = DB()
	local out = {}
	for key, e in pairs(self:GetList()) do
		if e.p then
			local r = db and db:GetRecipe(e.p, e.r)
			local crafted = r and r.craftedItemId or nil
			out[#out + 1] = {
				key = key, kind = "recipe", profId = e.p, recipeId = e.r, count = e.n,
				itemID = crafted, item = crafted and describe(crafted) or nil,
				name = r and r.name or ("Recipe " .. e.r), known = r ~= nil,
			}
		else
			local item = describe(e.i)
			out[#out + 1] = { key = key, kind = "item", itemID = e.i, item = item, count = e.n, name = item.name, known = true }
		end
	end
	table.sort(out, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.key < b.key
	end)
	return out
end

--- How many of `itemID` the HOME guild's bank characters hold between them (D4). A sister guild's
--- bank is theirs, not what this guild already has.
--- GSL-BANK-001: the [GSL] characters are bankers too (Guild's noteBankRole), but their stock is the
--- shopping list's, counted in GSLHolds and not here.
function CraftList:BankHolds(itemID)
	return self:HomeBankersHold(itemID, false)
end

--- GSL-BANK-001 (the operator 2026-09-26: "we also need what is on the GSL player (bank/bags/mail)
--- just like a banker. they are the 'special' banker for the shopping list"): how many of `itemID`
--- the home guild's [GSL] characters hold, from the same published inventory as any banker's.
function CraftList:GSLHolds(itemID)
	return self:HomeBankersHold(itemID, true)
end

--- The home guild's bank characters' total of `itemID`: the [GSL] ones when `gsl`, the rest when not.
function CraftList:HomeBankersHold(itemID, gsl)
	local G = TOGBankClassic_Guild
	if not (G and itemID) then return 0 end
	local total = 0
	for _, banker in ipairs(G:GetBanks() or {}) do
		local norm = G:NormalizeName(banker) or banker
		local isGSL = G.IsGSLBank and G:IsGSLBank(norm) or false
		if isGSL == gsl and (not G.IsHomeMember or G:IsHomeMember(banker)) then
			total = total + (G:GetAltItemTotal(norm, itemID) or 0)
		end
	end
	return total
end

--- How many of `itemID` the player holds. GSL-YOU-001 (the operator 2026-09-26: "when i'm on the GSL
--- toon, the GSL and You columns should match"): a bank character -- the [GSL] one included -- reads
--- its own scanned bags, bank and mail, the very total the GSL and Bank columns read for it; anyone
--- else gets bags plus bank from the client (`includeBank`, Classic Era ItemDocumentation.lua:242),
--- since only a bank character's mail is scanned.
function CraftList:YouHold(itemID)
	local G = TOGBankClassic_Guild
	local me = G and G.GetNormalizedPlayer and G:GetNormalizedPlayer()
	if me and G:IsBank(me) then return G:GetAltItemTotal(me, itemID) or 0 end
	if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(itemID, true) or 0 end
	return 0
end

--- The reagent roll-up: every reagent the whole list still needs, one row per item id -- `{ itemID,
--- needed, bank, gsl, you, missing }`, `missing` being what the [GSL] character does not yet hold
--- (GSL-BANK-001; the tab names a row through CraftList.Describe, the item resolver). A
--- recipe's demand is its reagents times (wanted minus what the bank already holds of the crafted
--- item); a wanted item's demand is itself. Recipes the library does not carry contribute nothing
--- and are listed in the second return, by key.
---@return table rows, table unknownKeys
function CraftList:Demand()
	local db = DB()
	local need, unknown = {}, {}
	for key, e in pairs(self:GetList()) do
		if e.p then
			local reagents = db and db:GetReagents(e.p, e.r)
			if type(reagents) == "table" then
				local crafted = db:GetCraftedItemID(e.p, e.r)
				local toMake = e.n - (crafted and self:BankHolds(crafted) or 0)
				if toMake > 0 then
					for itemID, per in pairs(reagents) do
						itemID, per = tonumber(itemID), tonumber(per) or 0
						if itemID and per > 0 then need[itemID] = (need[itemID] or 0) + per * toMake end
					end
				end
			else
				unknown[#unknown + 1] = key
			end
		else
			need[e.i] = (need[e.i] or 0) + e.n
		end
	end
	local rows = {}
	for itemID, needed in pairs(need) do
		local bank, gsl, you = self:BankHolds(itemID), self:GSLHolds(itemID), self:YouHold(itemID)
		-- GSL-BANK-001 (the operator 2026-09-26: "the missing tab should be what the GSL banker is
		-- missing"): Missing is what the shopping-list character still lacks. The guild bank and
		-- your own bags are shown beside it, not netted out of it.
		rows[#rows + 1] = { itemID = itemID, needed = needed, bank = bank, gsl = gsl, you = you,
			missing = math.max(0, needed - gsl) }
	end
	table.sort(rows, function(a, b) return a.itemID < b.itemID end)
	table.sort(unknown)
	return rows, unknown
end

-- ---------------------------------------------------------------------------
-- Writes -- THE ONE WRITER for each field. Each refuses a player who may not edit, stamps what it
-- changed, and publishes through the settings broadcast.
-- ---------------------------------------------------------------------------

local function publish()
	local G = TOGBankClassic_Guild
	G:BroadcastSettings("ALERT")
	local UI = TOGBankClassic_UI_CraftList
	if UI and UI.OnListChanged then UI:OnListChanged() end
end

--- Set one entry's count (`count` < 1 removes it). Returns true when the list changed.
local function setEntry(key, entry, count)
	local G = TOGBankClassic_Guild
	if not (G and G.Info) or not CraftList:CanEditHere() then return false end
	if not G.Info.settings then G.Info.settings = {} end
	local s = G.Info.settings
	local list = CraftList.SanitizeList(s.craftList)
	local n = wholePositive(count)
	n = n and math.min(n, CraftList.MAX_COUNT) or nil
	local had = list[key]
	if n then
		if had and had.n == n then return false end
		if not had then
			local size = 0
			for _ in pairs(list) do size = size + 1 end
			if size >= CraftList.MAX_ENTRIES then return false end
		end
		entry.n = n
		list[key] = entry
	else
		if not had then return false end
		list[key] = nil
	end
	local stamps = CraftList.SanitizeStamps(s.craftListStamps, list)
	stamps[key] = math.max(GetServerTime() or 0, (stamps[key] or 0) + 1)
	s.craftList = list
	s.craftListStamps = CraftList.SanitizeStamps(stamps, list)
	publish()
	return true
end

--- Want `count` of a recipe crafted (0 removes it). Refuses a recipe the library does not carry.
function CraftList:SetRecipe(profId, recipeId, count)
	profId, recipeId = wholePositive(profId), wholePositive(recipeId)
	if not (profId and recipeId) then return false end
	local db = DB()
	if (tonumber(count) or 0) >= 1 and not (db and db:GetRecipe(profId, recipeId)) then return false end
	return setEntry(CraftList.RecipeKey(profId, recipeId), { p = profId, r = recipeId }, count)
end

--- Want `count` of a plain item (0 removes it).
function CraftList:SetItem(itemID, count)
	itemID = wholePositive(itemID)
	if not itemID then return false end
	return setEntry(CraftList.ItemKey(itemID), { i = itemID }, count)
end

--- Remove an entry by key.
function CraftList:Remove(key)
	local e = self:GetList()[key]
	if not e then return false end
	return setEntry(key, e, 0)
end

--- Set the gather window ("YYYY-MM-DD" or "" each). Returns true when it changed.
function CraftList:SetGatherWindow(start, finish)
	local G = TOGBankClassic_Guild
	if not (G and G.Info) or not self:CanEditHere() then return false end
	start, finish = sanitizeDate(start), sanitizeDate(finish)
	if not (start and finish) then return false end
	if start ~= "" and finish ~= "" and finish < start then return false end
	local oldStart, oldFinish = self:GetGatherWindow()
	if oldStart == start and oldFinish == finish then return false end
	if not G.Info.settings then G.Info.settings = {} end
	G.Info.settings.gatherStart, G.Info.settings.gatherEnd = start, finish
	publish()
	return true
end

-- ---------------------------------------------------------------------------
-- GSL-MERGE-001 step 5 (D9): bringing a guild's GuildShoppingList list across, once
-- ---------------------------------------------------------------------------

-- Lowercased recipe name and effect -> { p, r }, or false when two recipes share the spelling.
local function recipeIndex(db)
	local byName, byEffect = {}, {}
	local function add(idx, text, p, r)
		if type(text) ~= "string" or text == "" then return end
		local k = text:lower()
		local had = idx[k]
		if had == nil then idx[k] = { p = p, r = r }
		elseif had and not (had.p == p and had.r == r) then idx[k] = false end
	end
	for p, r, e in db:Iterate() do
		if type(e) == "table" then
			add(byName, e.name, p, r)
			add(byEffect, e.effect, p, r)
		end
	end
	return byName, byEffect
end

-- The one item whose name is exactly `spelling` (lowercased), or nil when none or more than one
-- carries it -- item names are not unique (REQ-001), and a guess would put the wrong item on the list.
local function itemByExactName(spelling)
	local items = LibStub and LibStub("LibItemDB-1.0", true)
	if not (items and items.Search) then return nil end
	-- No cap: Search stops at `max` in table order and only then sorts, so a capped call can leave
	-- the exact name out.
	local found, id = items:Search({ query = spelling, max = math.huge }), nil
	for _, it in ipairs(found) do
		if type(it.name) == "string" and it.name:lower() == spelling and it.id ~= id then
			if id then return nil end
			id = it.id
		end
	end
	return id
end

--- One GuildShoppingList entry name -> the list key and entry, or nil. The spellings GuildShoppingList
--- actually uses (docs/GSL_MERGE.md 1.5): the recipe's name, then its effect ("Crusader" for
--- "Enchant Weapon - Crusader"), then both again with a trailing parenthetical stripped ("Crusader
--- (enchant)", "Blight (polearm)"); last, a plain item by its exact name -- GuildShoppingList's
--- Miscellaneous turn-in items, which are not recipes. A spelling two recipes share maps to neither.
---@return string|nil key, table|nil entry
function CraftList.ResolveGSLName(name, byName, byEffect)
	if type(name) ~= "string" then return nil end
	local full = name:match("^%s*(.-)%s*$"):lower()
	if full == "" then return nil end
	local spellings = { full }
	local stripped = full:match("^(.-)%s*%b()$")
	if stripped and stripped ~= "" then spellings[2] = stripped end
	for _, s in ipairs(spellings) do
		-- A name two recipes share (false) is a miss for this spelling; it does not fall through to
		-- the effect index, which could otherwise pick one of the two.
		local hit = byName and byName[s]
		if hit == nil then hit = byEffect and byEffect[s] end
		if hit then return CraftList.RecipeKey(hit.p, hit.r), { p = hit.p, r = hit.r } end
	end
	for _, s in ipairs(spellings) do
		local id = itemByExactName(s)
		if id then return CraftList.ItemKey(id), { i = id } end
	end
	return nil
end

--- Bring GuildShoppingList's saved list (and its gather dates) into this guild's shopping list.
---
--- ONCE PER ACCOUNT: GuildShoppingList keeps ONE list per account (its SavedVariables are not per
--- character or per guild), so the import is recorded in `db.global.gslImport` and not repeated on
--- another character. It runs on a roster refresh (Guild:RefreshOnlineCache), the first point the
--- player's role can be read, and only when all of these hold: GuildShoppingList's list is loaded and
--- non-empty; the player may edit this guild's list; and the guild has NEVER had a list (no entries
--- and no stamps -- a list emptied by removals keeps its stamps). Anyone else leaves it for a writer.
--- Entries that match nothing are named to the player, once; the two name-keyed bag and bank caches
--- are not read (D9).
---
--- The entries are stamped IMPORT_STAMP, older than any edit made in TOGBank (Peer Review F1 on the
--- step-5 self-audit): the first roster refresh can come before this client has heard the guild's
--- settings, and an import stamped "now" would have overwritten the guild's newer counts and brought
--- back entries it had removed. At 1 the guild's own entries and removals win the merge entry by
--- entry, and a client holding nothing still takes the import (Merge: a newer stamp than none).
---
--- KNOWN COST: on an account whose characters are writers in two guilds, the list goes to whichever
--- guild such a character logs into first, which may not be the guild it came from. The gather dates
--- ride the ordinary settings stamp, so the race above can still let imported dates replace a
--- guild's newer ones. And the "never had a list" test is this client's own view, which the race
--- makes stale (Peer Review on daa08281): on a client that has never held this guild's settings, an
--- import racing an existing list is MERGED, not refused -- every imported entry the guild never
--- stamped is added to its list (1 beats none), and past MAX_ENTRIES the cap drops by key order.
--- Skipping the import until a stamped payload is heard was rejected: a writer on a fresh install in
--- a guild where nobody has written settings yet would never import.
---@return number|nil imported, table|nil unmapped nil when nothing was attempted
function CraftList:ImportGSL()
	local src = _G.GuildShoppingList_SavedItems
	if type(src) ~= "table" or next(src) == nil then return nil end
	local Database = TOGBankClassic_Database
	local global = Database and Database.db and Database.db.global
	if not global or global.gslImport then return nil end
	local G = TOGBankClassic_Guild
	if not (G and G.Info and G.Info.name) then return nil end
	local s = G.Info.settings
	if s and (next(CraftList.SanitizeList(s.craftList)) or next(CraftList.SanitizeStamps(s.craftListStamps))) then return nil end
	local db = DB()
	if not db or not self:CanEditHere() then return nil end

	local byName, byEffect = recipeIndex(db)
	local list, unmapped, count = {}, {}, 0
	for _, line in ipairs(src) do
		local name, n = tostring(line):match("^(.-) x(%d+)$")
		n = wholePositive(n)
		local key, entry
		if name and n then key, entry = CraftList.ResolveGSLName(name, byName, byEffect) end
		if key and (list[key] or count < CraftList.MAX_ENTRIES) then
			if not list[key] then count = count + 1 end
			entry.n = math.min((list[key] and list[key].n or 0) + n, CraftList.MAX_COUNT)
			list[key] = entry
		else
			unmapped[#unmapped + 1] = name or tostring(line)
		end
	end

	if not G.Info.settings then G.Info.settings = {} end
	s = G.Info.settings
	local now, stamps = GetServerTime() or 0, {}
	for key in pairs(list) do stamps[key] = CraftList.IMPORT_STAMP end
	s.craftList, s.craftListStamps = list, stamps
	-- The gather window, when GuildShoppingList had one and this guild has none.
	local cfg = _G.GuildShoppingList_Config
	local start = type(cfg) == "table" and sanitizeDate(cfg.GatherStartDate)
	local finish = type(cfg) == "table" and sanitizeDate(cfg.GatherEndDate)
	local oldStart, oldFinish = self:GetGatherWindow()
	local dates = start and finish and start ~= "" and finish ~= "" and finish >= start
		and oldStart == "" and oldFinish == ""
	if dates then s.gatherStart, s.gatherEnd = start, finish end

	-- The names are kept as well as said: the report happens once per account.
	global.gslImport = { guild = G.Info.name, at = now, imported = count, unmapped = #unmapped, unmappedNames = unmapped }
	if count > 0 or dates then publish() end
	-- Response, not Info/Warn: it is said once, so a muted warning channel must not swallow it (F2).
	TOGBankClassic_Output:Response("Brought %d entr%s over from GuildShoppingList into the shopping list.", count, count == 1 and "y" or "ies")
	if #unmapped > 0 then
		TOGBankClassic_Output:Response("%d GuildShoppingList entr%s matched no recipe or item and %s left out: %s", #unmapped,
			#unmapped == 1 and "y" or "ies", #unmapped == 1 and "was" or "were", table.concat(unmapped, ", "))
	end
	return count, unmapped
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------

--- SETTINGS-TIE-001 for one entry: on an equal stamp the greater count wins and a removal counts as
--- 0, so two clients holding different copies at one stamp settle on the same one in either order.
--- KNOWN COST: a removal ALWAYS loses a tie -- a writer who takes an entry off in the same second
--- another raises it sees it come back, at the raised count.
local function entryWins(now, was)
	return (now and now.n or 0) > (was and was.n or 0)
end

--- Merge a received list entry by entry: an entry is taken when its stamp is newer than the one held
--- (a stamped absence is a removal), on an equal stamp by `entryWins`, or when neither side ever
--- stamped it and we hold nothing for it.
--- Returns true when anything changed. The caller has already authorized the sender.
function CraftList:Merge(inList, inStamps)
	local s = settings()
	if not s then return false end
	local list = CraftList.SanitizeList(s.craftList)
	local stamps = CraftList.SanitizeStamps(s.craftListStamps, list)
	inList = CraftList.SanitizeList(inList)
	inStamps = CraftList.SanitizeStamps(inStamps, inList)
	local keys = {}
	for key in pairs(inList) do keys[key] = true end
	for key in pairs(inStamps) do keys[key] = true end
	local changed = false
	for key in pairs(keys) do
		local theirs, ours = inStamps[key] or 0, stamps[key] or 0
		if theirs > ours or (theirs == ours and theirs > 0 and entryWins(inList[key], list[key]))
			or (theirs == 0 and ours == 0 and list[key] == nil and inList[key] ~= nil) then
			local was, now = list[key], inList[key]
			if (was == nil) ~= (now == nil) or (was and now and was.n ~= now.n) then changed = true end
			list[key] = now
			if theirs > 0 then stamps[key] = theirs end
		end
	end
	s.craftList = CraftList.SanitizeList(list)
	s.craftListStamps = CraftList.SanitizeStamps(stamps, s.craftList)
	if changed then
		local UI = TOGBankClassic_UI_CraftList
		if UI and UI.OnListChanged then UI:OnListChanged() end
	end
	return changed
end
