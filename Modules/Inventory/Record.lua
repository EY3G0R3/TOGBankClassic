-- Inventory/Record.lua — the V2 item record: tuple encode/decode, identity, validation.
--
-- See docs/INVENTORY_V2.md §3. An item is four integers:
--
--     { id, count }                    plain item (the overwhelming majority)
--     { id, count, suffix }            random-suffix gear
--     { id, count, suffix, enchant }   enchanted
--
-- Positional, not named keys, because SavedVariables repeats every key string on every row.
-- `{12345,20}` against `{id=12345,count=20}` is a large multiple across ~10k rows, and an
-- oversized SV file has already caused a load freeze here once (PERF-012: 18k lines / 0.5 MB).
--
-- Why this exists at all: today an item's identity IS its link string, and two spellings of the
-- same link (`:0:0:0:0:0:` from the client vs `::::::` from a rebuild) key differently and
-- aggregate as two rows with split counts. Integers have one spelling. That removes the
-- miscount class outright rather than normalising around it.

TOGBankClassic_Inventory_Record = {}
local Record = TOGBankClassic_Inventory_Record

-- Field positions within the tuple.
local F_ID, F_COUNT, F_SUFFIX, F_ENCHANT = 1, 2, 3, 4

--- Build a record. Trailing zero/nil fields are omitted so the common case stays two elements.
--- Returns nil for anything that cannot be a real item, rather than a half-formed record —
--- callers can then skip it, which is what the legacy code's scattered `if not v.ID` guards
--- were doing by hand.
function Record.new(id, count, suffix, enchant)
	id = tonumber(id)
	if not id or id <= 0 then return nil end

	count = tonumber(count) or 0
	if count <= 0 then return nil end

	suffix  = tonumber(suffix) or 0
	enchant = tonumber(enchant) or 0

	if enchant ~= 0 then return { id, count, suffix, enchant } end
	if suffix  ~= 0 then return { id, count, suffix } end
	return { id, count }
end

function Record.id(rec)      return rec and rec[F_ID] end
function Record.count(rec)   return rec and rec[F_COUNT] or 0 end
--- Absent suffix/enchant read as 0, never nil, so arithmetic and comparison never need a guard.
function Record.suffix(rec)  return rec and rec[F_SUFFIX]  or 0 end
function Record.enchant(rec) return rec and rec[F_ENCHANT] or 0 end

--- Identity. Two records are the same item iff their keys match.
---
--- String rather than a packed integer: `suffix` is SIGNED (a negative value indexes the
--- random-property table rather than the random-suffix table, and dropping the sign merges two
--- genuinely different items), so numeric packing would need bias handling for no real gain.
--- Uniform shape, no branching, negative-safe.
---
--- DS-005: this is the function V2 must hand to DeltaSync's ComputeArrayDelta. Its
--- DefaultKeyFunc looks for `.id` / `.ID` / `.key` / `.name` and falls back to `tostring(obj)`
--- — a table ADDRESS, which its own comment concedes is not stable across sessions. A
--- positional record has none of those fields, so the default would silently pick the address
--- fallback: every record would key uniquely, every diff would report everything added and
--- everything removed, and the addon would full-resync forever with no error.
function Record.key(rec)
	if not rec then return nil end
	return string.format("%d:%d:%d", rec[F_ID], rec[F_SUFFIX] or 0, rec[F_ENCHANT] or 0)
end

--- Key from loose values, for lookups where no record exists yet (a request naming an item, a
--- bag slot being tested). Must produce byte-identical output to Record.key.
function Record.keyFor(id, suffix, enchant)
	id = tonumber(id)
	if not id then return nil end
	return string.format("%d:%d:%d", id, tonumber(suffix) or 0, tonumber(enchant) or 0)
end

--- Structural validity. Deliberately strict: a malformed record reaching the store is how
--- corruption spreads, and every field is cheap to check.
function Record.isValid(rec)
	if type(rec) ~= "table" then return false end
	local id, count = rec[F_ID], rec[F_COUNT]
	if type(id) ~= "number" or id <= 0 or id ~= math.floor(id) then return false end
	if type(count) ~= "number" or count <= 0 or count ~= math.floor(count) then return false end
	local suffix, enchant = rec[F_SUFFIX], rec[F_ENCHANT]
	if suffix ~= nil and (type(suffix) ~= "number" or suffix ~= math.floor(suffix)) then return false end
	if enchant ~= nil and (type(enchant) ~= "number" or enchant ~= math.floor(enchant)) then return false end
	-- An enchant with no suffix must still carry suffix 0 in slot 3, or the positions shift and
	-- the enchant would be read as a suffix.
	if enchant ~= nil and suffix == nil then return false end
	return true
end

--- Merge two records of the SAME item by summing counts. Returns nil if they are different
--- items — callers must not silently combine a Spiked Club of the Tiger with one of the Monkey,
--- which is precisely the bug link-keying produced.
function Record.merge(a, b)
	if not (Record.isValid(a) and Record.isValid(b)) then return nil end
	if Record.key(a) ~= Record.key(b) then return nil end
	return Record.new(Record.id(a), Record.count(a) + Record.count(b),
		Record.suffix(a), Record.enchant(a))
end

--- Aggregate an array of records into a key-indexed map, summing duplicates.
--- Invalid entries are skipped rather than aborting the batch: one bad row from an old client
--- must not discard the rest, which is the mistake ITEM-005 made in the legacy loader.
--- @return table map, number skipped
function Record.aggregate(records)
	local out, skipped = {}, 0
	for _, rec in ipairs(records or {}) do
		if Record.isValid(rec) then
			local k = Record.key(rec)
			local existing = out[k]
			out[k] = existing and Record.merge(existing, rec) or rec
		else
			skipped = skipped + 1
		end
	end
	return out, skipped
end

--- Total quantity of one item across an aggregated map, ignoring suffix/enchant variants.
--- Used where the question is "how many Felcloth are there", not "which exact Felcloth".
function Record.totalForItem(map, id)
	id = tonumber(id)
	if not id then return 0 end
	local total = 0
	for _, rec in pairs(map or {}) do
		if Record.id(rec) == id then total = total + Record.count(rec) end
	end
	return total
end
