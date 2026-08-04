-- Inventory/Store.lua — the V2 tuple store.
--
-- See docs/INVENTORY_V2.md §5 and §7.1. This owns a SEPARATE SavedVariable from the legacy
-- inventory DB. The two never exchange data in either direction:
--
--   > No data is ever TRANSLATED between formats. Each DB is written only by its own native
--   > path, from the same source scan. Nothing reads v1 data to produce v2 data, or the reverse.
--
-- That is the property that removes the corruption class. A migration rewrites data in place, so
-- a wrong conversion destroys the original and the only evidence is corrupted player data —
-- MIGRATE-001 in the audit is exactly that, a conversion that computed the wrong thing and gave
-- every pre-v0.8 character a bogus hash. Here the worst case is an empty V2 DB and a switch
-- flipped back.
--
-- Storage shape, mirroring the legacy scoping so nothing new has to be learned:
--   TOGBankClassicInvDB.faction[guildName].alts[altName] = {
--       records = { <tuple>, ... },   -- see Record.lua
--       money   = <copper>,
--       updated = <server time>,
--   }

TOGBankClassic_Inventory_Store = {}
local Store = TOGBankClassic_Inventory_Store

local Record  = TOGBankClassic_Inventory_Record
local Resolve = TOGBankClassic_Inventory_Resolve

-- Materialised UI views, keyed guild\altName. Rebuilt on demand, dropped on write.
-- Purely derived: nothing here is persisted and losing it costs one rebuild.
local viewCache = {}

--- Attach to the SavedVariable. Kept separate from Database:Init so the legacy DB's lifecycle
--- is untouched — this module is inert until something calls into it.
function Store:Init(db)
	self.db = db or self.db
	if not self.db then
		TOGBankClassicInvDB = TOGBankClassicInvDB or {}
		TOGBankClassicInvDB.faction = TOGBankClassicInvDB.faction or {}
		self.db = TOGBankClassicInvDB
	end
	self.db.faction = self.db.faction or {}
	return self.db
end

local function guildTable(self, guild, create)
	if not guild or not self.db then return nil end
	local f = self.db.faction
	if not f[guild] then
		if not create then return nil end
		f[guild] = { alts = {} }
	end
	f[guild].alts = f[guild].alts or {}
	return f[guild]
end

local function viewKey(guild, altName) return tostring(guild) .. "\031" .. tostring(altName) end

--- Replace an alt's inventory with `records`.
---
--- Aggregates on the way in so the stored array holds one row per distinct item. Doing it here
--- rather than at read time means the miscount cannot be reintroduced by a caller that forgets:
--- whatever a scan hands over, what lands in the DB is already deduplicated by tuple key.
--- @return number stored, number skipped
function Store:SetAltRecords(guild, altName, records, money)
	local g = guildTable(self, guild, true)
	if not g or not altName then return 0, 0 end

	local map, skipped = Record.aggregate(records)
	local out = {}
	for _, rec in pairs(map) do out[#out + 1] = rec end
	-- Stable order so the SavedVariables file does not churn between saves for unchanged data.
	table.sort(out, function(a, b) return Record.key(a) < Record.key(b) end)

	g.alts[altName] = {
		records = out,
		money   = tonumber(money) or (g.alts[altName] and g.alts[altName].money) or 0,
		updated = GetServerTime(),
	}
	self:InvalidateView(guild, altName)
	return #out, skipped
end

--- An alt's stored tuples, or an empty table. Never nil, so callers need no guard.
function Store:GetAltRecords(guild, altName)
	local g = guildTable(self, guild, false)
	local alt = g and g.alts[altName]
	return (alt and alt.records) or {}
end

function Store:GetAltMoney(guild, altName)
	local g = guildTable(self, guild, false)
	local alt = g and g.alts[altName]
	return (alt and alt.money) or 0
end

function Store:HasAlt(guild, altName)
	local g = guildTable(self, guild, false)
	return (g and g.alts[altName]) ~= nil
end

function Store:GetAltNames(guild)
	local g = guildTable(self, guild, false)
	local out = {}
	if g then for name in pairs(g.alts) do out[#out + 1] = name end end
	table.sort(out)
	return out
end

function Store:RemoveAlt(guild, altName)
	local g = guildTable(self, guild, false)
	if not g or not g.alts[altName] then return false end
	g.alts[altName] = nil
	self:InvalidateView(guild, altName)
	return true
end

-- ---------------------------------------------------------------------------
-- UI-compatibility view (§7.1)
-- ---------------------------------------------------------------------------

--- Present an alt's inventory in the shape the existing UI already consumes, so the first cut
--- of V2 needs no UI changes:
---
---     { { ID = <id>, Count = <n>, Link = <link|nil>, Info = { ... } }, ... }
---
--- Cached because resolving ~10k rows on every draw would be worse than the link storage it
--- replaces. Dropped on any write to that alt — see InvalidateView.
function Store:GetAltView(guild, altName)
	local key = viewKey(guild, altName)
	local cached = viewCache[key]
	if cached then return cached end

	local out = {}
	for _, rec in ipairs(self:GetAltRecords(guild, altName)) do
		local d = Resolve.describe(rec)
		out[#out + 1] = {
			ID    = Record.id(rec),
			Count = Record.count(rec),
			Link  = d.link,
			Info  = {
				name     = d.name,
				icon     = d.icon,
				rarity   = d.quality,
				level    = d.itemLevel,
				reqLevel = d.reqLevel,
				class    = d.class,
				subClass = d.subClass,
				equipId  = d.equipLoc,
			},
		}
	end
	viewCache[key] = out
	return out
end

--- Drop a cached view. Called on every write; exposed because a change to the *resolution*
--- inputs (the library loading late, a locale switch) invalidates views without touching stored
--- records, and nothing else would notice.
function Store:InvalidateView(guild, altName)
	if guild and altName then
		viewCache[viewKey(guild, altName)] = nil
	else
		viewCache = {}
	end
end

--- Test/diagnostic hook: how many views are currently materialised.
function Store:CachedViewCount()
	local n = 0
	for _ in pairs(viewCache) do n = n + 1 end
	return n
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Total quantity of an item across every alt in a guild, ignoring suffix/enchant variants.
function Store:GetGuildTotal(guild, itemID)
	itemID = tonumber(itemID)
	if not itemID then return 0 end
	local total = 0
	for _, altName in ipairs(self:GetAltNames(guild)) do
		for _, rec in ipairs(self:GetAltRecords(guild, altName)) do
			if Record.id(rec) == itemID then total = total + Record.count(rec) end
		end
	end
	return total
end

--- Which alts hold an item, and how many each. Sorted most-stock-first, then by name — the
--- order the tooltip and search results want.
function Store:FindItem(guild, itemID)
	itemID = tonumber(itemID)
	if not itemID then return {} end
	local out = {}
	for _, altName in ipairs(self:GetAltNames(guild)) do
		local n = 0
		for _, rec in ipairs(self:GetAltRecords(guild, altName)) do
			if Record.id(rec) == itemID then n = n + Record.count(rec) end
		end
		if n > 0 then out[#out + 1] = { name = altName, count = n } end
	end
	table.sort(out, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.name < b.name
	end)
	return out
end
