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

-- PERF-022: per alt, `itemID -> total count` across every variant, derived from the record array
-- above on first ask and dropped with it. The tooltip hover asks "how many of X does each banker
-- hold" for every banker on every mouseover -- O(bankers x items) as a linear scan, one hash
-- lookup per banker with this. The hard part of an index is INVALIDATION (audit finding 13): this
-- one cannot miss a writer because it is dropped in the same call the record cache is, and every
-- writer of the store already goes through that call (INV2-ISOLATE-001 pins the writer set).
local totalsCache = {}

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
	self.repaired = self:RepairWholesaleBuckets()
	return self.db
end

--- DOUBLE-001, the repair for records already on disk: any alt holding a wholesale `all` bucket
--- BESIDE a named source has been double-counting since the day the two met, and nothing but a
--- wholesale delivery would ever have cleared it. The named sources are what this account's own
--- scans read from the real containers; `all` was a copy of them. Dropped, visible and hidden
--- halves, and the alt's caches with it. Returns how many alts were repaired, so the caller can say
--- so; safe to run every load (a clean store is a no-op).
---@return number repaired
function Store:RepairWholesaleBuckets()
	local repaired = 0
	for guild, g in pairs(self.db and self.db.faction or {}) do
		for altName, alt in pairs(g.alts or {}) do
			local sources = alt.sources
			if sources and sources.all then
				local named = false
				for name in pairs(sources) do if name ~= "all" then named = true break end end
				if named then
					sources.all = nil
					if alt.hidden then
						alt.hidden.all = nil
						if not next(alt.hidden) then alt.hidden = nil end
					end
					self:InvalidateView(guild, altName)
					repaired = repaired + 1
				end
			end
		end
	end
	return repaired
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

--- The guild's table on the V2 SavedVariable, for the sibling module that keeps its data beside
--- the records: Inventory/Chain.lua stores each banker's delta chain in `<guild>.chains`. Exposed
--- rather than giving Chain its own SavedVariable -- one V2 file, one lifecycle (Init, wipe).
---@param guild string
---@param create boolean create the guild table if absent
---@return table|nil
function Store:GuildTable(guild, create)
	return guildTable(self, guild, create)
end

local function viewKey(guild, altName) return tostring(guild) .. "\031" .. tostring(altName) end

--- Aggregate one source's records into a stably-ordered array.
---
--- Aggregates on the way in so the stored array holds one row per distinct item. Doing it here
--- rather than at read time means the miscount cannot be reintroduced by a caller that forgets:
--- whatever a scan hands over, what lands in the DB is already deduplicated by tuple key.
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
---
--- HIDE-001: `hiddenKeys` (`Record.key -> true`) is the banker's own "not for the guild" list. Every
--- bucket -- the ones supplied AND the ones carried forward -- is split on it: rows whose key is
--- hidden go to `hidden[source]`, the rest to `sources[source]`. Only `sources` is what the store
--- reads back (GetAltRecords, the view, the totals), so a hidden row is absent from the hash, the
--- chain, the log, the snapshot and every viewer -- the addon acts as if the banker does not have
--- it. The hidden rows are KEPT, per source, beside the visible ones: that is what lets a banker
--- unhide an item while away from the vault (the carried-forward bank bucket still holds the row to
--- give back) and what the banker's own tab draws greyed out. Split here rather than in the scan so
--- the carry-forward cannot skip it. nil means "nothing hidden".
--- @return number stored, number skipped
function Store:SetAltSources(guild, altName, sources, money, hiddenKeys)
	local g = guildTable(self, guild, true)
	if not g or not altName or type(sources) ~= "table" then return 0, 0 end

	local prev = g.alts[altName]
	local full, skipped = {}, 0
	-- Carry forward every bucket the caller did not mention -- visible and hidden halves together,
	-- so a key that left the hidden list comes back into view without a re-read of that source.
	if prev and prev.sources then
		for name, bucket in pairs(prev.sources) do full[name] = bucket end
	end
	if prev and prev.hidden then
		for name, bucket in pairs(prev.hidden) do
			local merged = {}
			for _, rec in ipairs(full[name] or {}) do merged[#merged + 1] = rec end
			for _, rec in ipairs(bucket) do merged[#merged + 1] = rec end
			full[name] = merged
		end
	end
	for name, records in pairs(sources) do
		local bucket, s = bucketOf(records)
		full[name], skipped = bucket, skipped + s
	end

	-- DOUBLE-001: A WHOLESALE BUCKET AND PER-SOURCE BUCKETS NEVER COEXIST. `all` is what a delivery
	-- from the wire stores (SetAltRecords) -- the whole record, every source folded in. A scan writes
	-- named sources. The carry-forward above kept `all` beside them, and the view sums every bucket,
	-- so every item was counted from `all` AND from the bucket it now sits in. Read off the
	-- operator's own banker 2026-09-12: `all` 100 rows / 141 units beside bags 53 / bank 46 / mail 0,
	-- "i only have 3x archaic defenders. the ui is showing 6". The path is ordinary and will recur:
	-- the store is account-wide, so a viewer alt on the same account receives the banker's record
	-- as `all`, and the banker's next scan adds its sources next to it. The v1.1.0 ITEM-004 class --
	-- a source summed instead of replaced -- in the V2 store. So: a named source arriving REPLACES
	-- the wholesale bucket outright (the scan is reading the real containers; the delivery was a
	-- copy of them), visible and hidden halves both.
	local named = false
	for name in pairs(sources) do if name ~= "all" then named = true break end end
	if named and full.all then full.all = nil end

	local out, hidden, anyHidden = {}, {}, false
	for name, bucket in pairs(full) do
		if hiddenKeys and next(hiddenKeys) then
			local shown, kept = {}, {}
			for _, rec in ipairs(bucket) do
				if hiddenKeys[Record.key(rec)] then kept[#kept + 1] = rec else shown[#shown + 1] = rec end
			end
			-- Re-bucket so a carried-forward merge above is aggregated and ordered like a fresh write.
			out[name] = bucketOf(shown)
			if #kept > 0 then hidden[name], anyHidden = bucketOf(kept), true end
		else
			out[name] = bucketOf(bucket)
		end
	end

	g.alts[altName] = {
		sources = out,
		hidden  = anyHidden and hidden or nil,
		money   = tonumber(money) or (prev and prev.money) or 0,
		updated = GetServerTime(),
		-- Stamped on every write, so a record's coverage travels with it rather than being inferred
		-- from its age.
		schema  = Store.SCHEMA,
	}
	self:InvalidateView(guild, altName)
	return #self:GetAltRecords(guild, altName), skipped
end

--- HIDE-001: an alt's HIDDEN tuples as one flat, aggregated array -- the rows the banker keeps
--- from the guild. Empty for every alt but the banker's own (a received record carries none), and
--- read by exactly one thing: the banker's own tab, which draws them greyed so they can be unhidden.
--- Never nil. Not cached: one reader, on one tab, on draw.
---@return table records
function Store:GetAltHiddenRecords(guild, altName)
	local g = guildTable(self, guild, false)
	local alt = g and g.alts[altName]
	if not (alt and alt.hidden) then return {} end
	local all = {}
	for _, bucket in pairs(alt.hidden) do
		for _, rec in ipairs(bucket) do all[#all + 1] = rec end
	end
	return (bucketOf(all))
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

--- How many of `itemID` an alt holds, every suffix/enchant variant summed. O(1) after the first
--- ask per alt since its last write (PERF-022); 0 for an alt the store has not seen.
---@param guild string
---@param altName string
---@param itemID number
---@return number
function Store:GetAltItemTotal(guild, altName, itemID)
	itemID = tonumber(itemID)
	if not itemID then return 0 end
	local key = viewKey(guild, altName)
	local totals = totalsCache[key]
	if not totals then
		-- Nothing is cached for an alt the store has not seen: an empty index under that key would
		-- outlive a later InvalidateView(guild, alt) only by spelling, and GetAltRecords itself never
		-- caches the unknown case either.
		if not self:HasAlt(guild, altName) then return 0 end
		totals = {}
		for _, rec in ipairs(self:GetAltRecords(guild, altName)) do
			local id = Record.id(rec)
			totals[id] = (totals[id] or 0) + Record.count(rec)
		end
		totalsCache[key] = totals
	end
	return totals[itemID] or 0
end

function Store:GetAltMoney(guild, altName)
	local g = guildTable(self, guild, false)
	local alt = g and g.alts[altName]
	return (alt and alt.money) or 0
end

--- ONE source's records for an alt -- `"bank"`, `"bags"` or `"mail"` -- or an empty table. Never nil.
---
--- INV2-RETIRE-003. Two readers needed the split the legacy record kept (`alt.bank.items`,
--- `alt.mail.items`) and nothing here offered it: the fulfil path's "in mail" / "in bank" hint
--- (Mail.lua CanFulfillRequest) and the status bar's mail count. Both are about the LOCAL banker,
--- whose own scans write per source (SetAltSources), so the buckets are there to read. A record
--- written by SetAltRecords -- a received delivery -- holds one flat `all` bucket and answers empty
--- for every named source, which is right: a receiver was never told which source a row sat in.
---
--- RETURNS THE LIVE STORED BUCKET, not a copy -- deliberately (Peer Review, 55250c0f F5). Both
--- callers are read-only and one is on the fulfil path; a defensive copy per call is the wrong
--- trade there. A caller must not mutate what it gets back.
---@param source string "bank" | "bags" | "mail"
---@return table records
function Store:GetAltSourceRecords(guild, altName, source)
	local g = guildTable(self, guild, false)
	local alt = g and g.alts[altName]
	local bucket = alt and alt.sources and alt.sources[source]
	return bucket or {}
end

--- LOG-MAIL-001: what the banker HOLDS -- every source but `mail`, as one flat aggregated array.
--- The operator: "the log should only show the 'deposit' when it's taken from the mail, not when
--- it's scanned in the inbox. it may sit there and be sent back." An unopened mail is not the
--- bank's yet, so the bank LOG diffs this set (Bank:MintVersion), while the version, the hash and
--- every viewer's rows still carry the mail rows (a viewer may request what sits in the inbox).
--- A record written by SetAltRecords -- a received delivery, one `all` bucket -- answers everything,
--- which is right for the one caller that can meet it (a diff base fetched from a peer): a receiver
--- was never told which source a row sat in. A fresh array per call; not cached (one reader, at mint).
---@return table records
function Store:GetAltHeldRecords(guild, altName)
	local g = guildTable(self, guild, false)
	local alt = g and g.alts[altName]
	if not alt then return {} end
	if not alt.sources then return alt.records or {} end
	local all = {}
	for name, bucket in pairs(alt.sources) do
		if name ~= "mail" then
			for _, rec in ipairs(bucket) do all[#all + 1] = rec end
		end
	end
	return (bucketOf(all))
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
---     { { ID = <id>, Count = <n>, Suffix = <n>, Enchant = <n>, Link = <link|nil>, Info = { ... } }, ... }
---
--- INV2-SUFFIX-001: Suffix and Enchant are carried as first-class numbers (0 meaning "none")
--- rather than left to be parsed back out of Link. Only the FIRST step of Resolve.describe
--- preserves them in the link -- step 2 (Resolve.lua:187) emits a bare "item:<id>" and step 3
--- emits no link at all -- so a consumer recovering the suffix from the link silently loses it
--- on any client whose ItemDB lacks that id. The record held the value the whole time; this
--- stops the lossy round trip rather than working around it.
---
--- RESOLVE-002: `Info.equipId` is the NUMERIC Enum.InventoryType, as the legacy loader stores it
--- (Item.lua: `C_Item.GetItemInventoryTypeByID`). Resolve.describe hands back `equipLoc`, the
--- INVTYPE_* STRING that LibItemDB and GetItemInfoInstant both return, and this view used to copy
--- that string straight into `equipId`. The By-Type sort (Item.lua / UI/Search.lua) compares
--- equipId with `<`: on V2 rows that sorted slots alphabetically by token instead of in slot order,
--- and a Search result mixing a V2 alt with a legacy-only alt compared a string against a number
--- -- a Lua error in the comparator. Token -> enum value from Era's ItemConstantsDocumentation.lua
--- (Enum.InventoryType, 0..34); anything unknown or non-equippable is 0 (IndexNonEquipType), the
--- same value the legacy path stores for it.
local INVTYPE_TO_ID = {
	INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_BODY = 4, INVTYPE_CHEST = 5,
	INVTYPE_WAIST = 6, INVTYPE_LEGS = 7, INVTYPE_FEET = 8, INVTYPE_WRIST = 9, INVTYPE_HAND = 10,
	INVTYPE_FINGER = 11, INVTYPE_TRINKET = 12, INVTYPE_WEAPON = 13, INVTYPE_SHIELD = 14,
	INVTYPE_RANGED = 15, INVTYPE_CLOAK = 16, INVTYPE_2HWEAPON = 17, INVTYPE_BAG = 18,
	INVTYPE_TABARD = 19, INVTYPE_ROBE = 20, INVTYPE_WEAPONMAINHAND = 21, INVTYPE_WEAPONOFFHAND = 22,
	INVTYPE_HOLDABLE = 23, INVTYPE_AMMO = 24, INVTYPE_THROWN = 25, INVTYPE_RANGEDRIGHT = 26,
	INVTYPE_QUIVER = 27, INVTYPE_RELIC = 28,
}
Store.INVTYPE_TO_ID = INVTYPE_TO_ID

local function equipIdFor(equipLoc)
	if type(equipLoc) == "number" then return equipLoc end
	return INVTYPE_TO_ID[equipLoc] or 0
end

--- Cached because resolving ~10k rows on every draw would be worse than the link storage it
--- replaces. Dropped on any write to that alt — see InvalidateView.
---
--- An alt the store has never seen caches an EMPTY view under its name too (INV2-RETIRE-003:
--- `Guild:GetAltItems` reaches here for every name the UI asks about, with no `Info.alts` guard in
--- front). Bounded by the roster -- one empty array per name ever asked -- and dropped by that
--- alt's first write like any other entry. Not a leak; said so nobody "fixes" it with a copy.
local function viewRow(rec)
	local d = Resolve.describe(rec)
	return {
		ID      = Record.id(rec),
		Count   = Record.count(rec),
		Suffix  = Record.suffix(rec),
		Enchant = Record.enchant(rec),
		Link    = d.link,
		Info    = {
			name     = d.name,
			icon     = d.icon,
			rarity   = d.quality,
			level    = d.itemLevel,
			reqLevel = d.reqLevel,
			class    = d.class,
			subClass = d.subClass,
			equipId  = equipIdFor(d.equipLoc),
		},
	}
end

function Store:GetAltView(guild, altName)
	local key = viewKey(guild, altName)
	local cached = viewCache[key]
	if cached then return cached end

	local out = {}
	for _, rec in ipairs(self:GetAltRecords(guild, altName)) do
		out[#out + 1] = viewRow(rec)
	end
	viewCache[key] = out
	return out
end

--- HIDE-001: the hidden rows in the same shape as GetAltView, each flagged `Hidden = true`. NOT part
--- of GetAltView on purpose: that view feeds Search, the tooltips, the fulfil path and
--- TOGProfessionMaster, none of which may see a hidden item. The banker's own tab appends these.
---@return table rows
function Store:GetAltHiddenView(guild, altName)
	local out = {}
	for _, rec in ipairs(self:GetAltHiddenRecords(guild, altName)) do
		local row = viewRow(rec)
		row.Hidden = true
		out[#out + 1] = row
	end
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
		totalsCache[key] = nil
	else
		viewCache = {}
		recordCache = {}
		totalsCache = {}
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
		total = total + self:GetAltItemTotal(guild, altName, itemID)
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
		local n = self:GetAltItemTotal(guild, altName, itemID)
		if n > 0 then out[#out + 1] = { name = altName, count = n } end
	end
	table.sort(out, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.name < b.name
	end)
	return out
end
