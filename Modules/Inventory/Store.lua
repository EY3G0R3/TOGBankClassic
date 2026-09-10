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
--       sources = { bank = { <tuple>, ... }, bags = { ... }, mail = { ... } },
--       money   = <copper>,
--       updated = <server time>,
--       schema  = <Store.SCHEMA at write time>,
--   }
--
-- STORED PER SOURCE, and that is the fix for INV2-VAULT-001 rather than a tidier shape. The vault
-- can only be read at a banker; bags and mail can be read anywhere. A single flat record set forces
-- a writer that is away from the vault to choose between overwriting the stored vault with nothing
-- and skipping the write entirely -- and skipping means bag and mail changes never land either, so
-- the record silently stops tracking the character. The legacy DB has always kept its three sources
-- apart (`alt.bank.items` / `alt.bags.items` / `alt.mail.items`) and aggregated on the way out,
-- which is exactly why it never had this defect. This mirrors that.
--
-- Reads are unchanged: GetAltRecords still returns one flat, aggregated array.

TOGBankClassic_Inventory_Store = {}
local Store = TOGBankClassic_Inventory_Store

--- Which SOURCES a stored record set was built from. Bumped when the scan gains a source, NOT when
--- the tuple layout changes -- Record.lua owns that, and the two version independently because they
--- fail differently: a layout change makes rows unreadable, a source change makes totals SHORT.
---
---   1 (or absent) -- bags + bank. Everything written before INV2-MAIL-001.
---   2             -- bags + bank + mail.
---
--- INV2-STALE-001 is why this exists. `updated` records WHEN a record was written and cannot answer
--- what it covers, so a reader had no way to distinguish "V2 is complete" from "V2 has some rows".
Store.SCHEMA = 2

local Record  = TOGBankClassic_Inventory_Record
local Resolve = TOGBankClassic_Inventory_Resolve

-- Materialised UI views, keyed guild\altName. Rebuilt on demand, dropped on write.
-- Purely derived: nothing here is persisted and losing it costs one rebuild.
local viewCache = {}

-- The flattened, aggregated record array per alt — the same derivation, one level below the view.
-- Separate cache because the two have different lifetimes in principle (a locale change drops
-- views and leaves records untouched); both are dropped together on write.
local recordCache = {}

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
--- Aggregate one source's records into a stably-ordered array.
--- @return table bucket
--- @return number skipped
local function bucketOf(records)
	local map, skipped = Record.aggregate(records)
	local out = {}
	for _, rec in pairs(map) do out[#out + 1] = rec end
	-- Stable order so the SavedVariables file does not churn between saves for unchanged data.
	table.sort(out, function(a, b) return Record.key(a) < Record.key(b) end)
	return out, skipped
end

--- Replace SOME of an alt's sources, keeping the rest.
---
--- A source present in `sources` is replaced. A source ABSENT from it is kept exactly as stored --
--- which is how a scan away from a banker refreshes bags and mail without erasing the vault. An
--- empty table is not the same as absent: it means that source was read and is genuinely empty.
---
--- INV2-VAULT-001. The previous arrangement had the caller skip the whole write when the vault was
--- out of reach, to protect the stored vault contents. It protected them and froze everything else:
--- a character who opened their mailbox anywhere but a bank NPC updated the legacy record to 71 and
--- left the V2 record at 68, permanently, because the next write was skipped for the same reason.
--- Deciding per source here rather than per write is what removes the choice.
--- @return number stored, number skipped
function Store:SetAltSources(guild, altName, sources, money)
	local g = guildTable(self, guild, true)
	if not g or not altName or type(sources) ~= "table" then return 0, 0 end

	local prev = g.alts[altName]
	local out, skipped = {}, 0
	-- Carry forward every bucket the caller did not mention.
	if prev and prev.sources then
		for name, bucket in pairs(prev.sources) do out[name] = bucket end
	end
	for name, records in pairs(sources) do
		local bucket, s = bucketOf(records)
		out[name], skipped = bucket, skipped + s
	end

	g.alts[altName] = {
		sources = out,
		money   = tonumber(money) or (prev and prev.money) or 0,
		updated = GetServerTime(),
		-- Stamped on every write, so a record's coverage travels with it rather than being inferred
		-- from its age.
		schema  = Store.SCHEMA,
	}
	self:InvalidateView(guild, altName)
	return #self:GetAltRecords(guild, altName), skipped
end

--- Replace an alt's inventory wholesale, discarding every stored source.
---
--- The single-source entry point, for a caller that has one complete record set and no notion of
--- where the rows came from. Distinct from SetAltSources on purpose: this one CANNOT preserve a
--- vault, so a caller that might be away from a banker wants the other.
--- @return number stored, number skipped
function Store:SetAltRecords(guild, altName, records, money)
	local g = guildTable(self, guild, true)
	if not g or not altName then return 0, 0 end
	local prev = g.alts[altName]
	-- Wholesale replace: drop every existing bucket first, so nothing is carried forward.
	g.alts[altName] = nil
	return self:SetAltSources(guild, altName, { all = records or {} },
		money or (prev and prev.money))
end

--- An alt's stored tuples as ONE flat, aggregated array, or an empty table. Never nil, so callers
--- need no guard.
---
--- The per-source split is a storage detail: an item held in both bags and mail is one row here
--- with the counts summed, exactly as it was when a single flat set was stored. Cached because
--- every read would otherwise re-aggregate, and the tooltip path reads this per hover.
function Store:GetAltRecords(guild, altName)
	local g = guildTable(self, guild, false)
	local alt = g and g.alts[altName]
	if not alt then return {} end

	-- Written before the per-source split (INV2-VAULT-001): already flat, nothing to aggregate.
	if not alt.sources then return alt.records or {} end

	local key = viewKey(guild, altName)
	local cached = recordCache[key]
	if cached then return cached end

	local all = {}
	for _, bucket in pairs(alt.sources) do
		for _, rec in ipairs(bucket) do all[#all + 1] = rec end
	end
	local out = bucketOf(all)
	recordCache[key] = out
	return out
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

--- Was this alt's stored record set built from every source the current scan reads?
---
--- `HasAlt` answers "is there a record". This answers "is that record built from today's sources",
--- and the two disagree for every alt scanned before INV2-MAIL-001: those hold bags + bank and no
--- mail, so their totals are SHORT rather than wrong. A short total is the worst shape to fall back
--- on, because it looks like data rather than like an absence -- the reader shows 68 where the
--- legacy record has 71 and nothing marks the difference.
---
--- Absent stamp means schema 1, not "unknown": the field was added with schema 2, so anything
--- without it was written by a scan that predates mail.
--- @return boolean
function Store:IsAltComplete(guild, altName)
	local g = guildTable(self, guild, false)
	local alt = g and g.alts[altName]
	if not alt then return false end
	return (tonumber(alt.schema) or 1) >= Store.SCHEMA
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
		local key = viewKey(guild, altName)
		viewCache[key] = nil
		recordCache[key] = nil
	else
		viewCache = {}
		recordCache = {}
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
