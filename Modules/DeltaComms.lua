-- DeltaComms.lua
-- Handles all delta synchronization communication and protocol logic for TOGBankClassic v0.7.0+
-- This includes delta validation, computation, application, error tracking, and protocol coordination

TOGBankClassic_DeltaComms = {}

-- NS-001: aliased as file-scope locals so a foreign global of the same name cannot be read
-- instead. See the header of Modules/Constants.lua.
local PROTOCOL = TOGBankClassic_Constants.PROTOCOL
local FEATURES = TOGBankClassic_Constants.FEATURES

-- INV2 step 10: `ValidateDeltaStructure` and `ValidateItemDelta` were deleted here. They validated
-- the `alt-delta` envelope and its added/modified/removed arrays -- a message shape this addon no
-- longer sends or accepts. The tuple payload is validated by `Wire.isV2`/`Wire.decode` on the
-- receive side, which checks the positional shape rather than a named-field contract.

--- Hash one items array into a stable, order-independent string.
---
--- ONE implementation. ComputeInventoryHash carried two byte-identical copies of this, one per
--- calling convention, so a correction had to be made twice or the two conventions would hash the
--- same inventory differently -- the "same behaviour implemented more than once" finding with a
--- live cost rather than a stylistic one.
---
--- AUDIT FINDING 31 (HIGH): the old body was `string.format("%d:%d", item.ID, item.Count or 0)`.
--- Suffix and enchant were absent, so an inventory holding a Spiked Club of the Tiger hashed
--- IDENTICALLY to one holding a Spiked Club of the Monkey. A banker swapping one suffix variant for
--- another at the same stack count produced an unchanged hash, Bank:Scan never bumped the version,
--- and NO DELTA WAS EVER COMPUTED -- peers kept showing the old variant not until the next scan but
--- until some unrelated change happened to move the hash. Improving the delta's identity resolution
--- could not help, because the better delta was never reached.
---
--- AUDIT FINDING 32 (HIGH): the guard was `if item and item.ID then`. A tuple record is positional
--- and has no `.ID`, so once records become tuples EVERY row fails that guard, `sorted` stays empty,
--- and the hash collapses to money-only -- every inventory change hashing the same as no change,
--- silently. Accepting both shapes here is what stops that arriving with the switch.
---
--- Identity comes from Record.keyFor, so the hash and the delta agree on what "the same item" is by
--- construction rather than by two functions being kept in step.
local function hashInventoryItems(itemsArray)
	if not itemsArray or type(itemsArray) ~= "table" then
		return ""
	end
	local Record = TOGBankClassic_Inventory_Record
	local Scan   = TOGBankClassic_Inventory_Scan

	local sorted = {}
	for _, item in ipairs(itemsArray) do
		if type(item) == "table" then
			local id, count, suffix, enchant

			if item.ID then
				-- Legacy row. Suffix and enchant live in the link, the only place a pre-tuple row
				-- records them; a linkless row (mail) reads 0/0, which is exactly the tuple a
				-- linkless row produces, so the two shapes agree rather than merely coexisting.
				id, count = tonumber(item.ID), tonumber(item.Count) or 0
				local link = item.Link or item.ItemString
				if link and Scan and Scan.parseLink then
					enchant, suffix = Scan.parseLink(link)
				end
			elseif type(item[1]) == "number" then
				-- Tuple record {id, count, suffix, enchant}.
				id, count, suffix, enchant = item[1], item[2] or 0, item[3], item[4]
			end

			if id then
				-- AUDIT FINDING 36: this had an `or string.format("%d:%d:%d", ...)` fallback for a
				-- missing Record, which re-implemented Record.keyFor's body inline. The two agreed
				-- byte-for-byte, so there was no live defect -- but NOTHING COULD KEEP THEM
				-- AGREEING: add a field to the key, change the separator or widen the format and
				-- keyFor moves while that string does not. The failure would be a hash that depends
				-- on whether Record happened to be loaded, and the divergent path is the one nobody
				-- exercises. That is the same "one constant in two places" class the consolidation
				-- above just removed, reintroduced by the same change.
				--
				-- Dropped rather than asserted-equal: Record is declared in both TOCs and loads
				-- before this module, so its absence is a LOAD-ORDER DEFECT and a hard error is the
				-- right outcome. A fallback papers over exactly the failure worth seeing.
				local key = Record.keyFor(id, suffix or 0, enchant or 0)
				if key then
					table.insert(sorted, key .. ":" .. tostring(count))
				end
			end
		end
	end
	table.sort(sorted)
	return table.concat(sorted, ",")
end

--- HASH-REV-001 -- revision 1. **FROZEN. DO NOT FIX THIS FUNCTION.**
---
--- This is the pre-finding-31 identity, bugs included: `ID:Count` only, so it cannot see suffix or
--- enchant, and a positional tuple has no `.ID` so it contributes nothing. Both of those are real
--- defects and both are the point -- **this is what every unmigrated client in the wild computes**,
--- and its value crosses the wire to be compared against theirs.
---
--- `docs/LIBRARY_CONTRACTS.md` records the rule, in DeltaSync's words after they hit this exactly:
--- _"a value that crosses the wire is frozen the moment a second implementation computes it, and
--- neither a MINOR bump nor a changelog entry makes it safe to change."_ Audit finding 37 is that we
--- broke that rule by fixing findings 31/32 in place. The remedy is not to un-fix them -- it is for
--- the corrected hash to ride ALONGSIDE this one as revision 2 and be used only when both peers
--- advertise it, so a mixed-version guild needs no coordinated release.
---
--- "Keep the two in step" does NOT apply here and is the one case where duplication is correct: this
--- function is frozen by definition. It retires when no unmigrated client remains, not before, and
--- improving it would break the interop it exists to preserve.
local function hashInventoryItemsV1(itemsArray)
	if not itemsArray or type(itemsArray) ~= "table" then
		return ""
	end
	local sorted = {}
	for _, item in ipairs(itemsArray) do
		if type(item) == "table" and item.ID then
			table.insert(sorted, string.format("%d:%d",
				tonumber(item.ID) or 0, tonumber(item.Count) or 0))
		end
	end
	table.sort(sorted)
	return table.concat(sorted, ",")
end

--- The argument handling shared by both revisions. Extracted so the two hashes cannot disagree about
--- anything EXCEPT the item identity -- the calling-convention detection, the money type guard from
--- finding 26 and the checksum are one implementation, and only `hashItems` differs.
local function computeInventoryHashWith(hashItems, bank, bags, mailOrMoney, money)
	-- Handle multiple calling conventions:
	-- SYNC-006 (aggregated): ComputeInventoryHash(items, nil, nil, money) - items is direct array
	-- Pre-SYNC-006: ComputeInventoryHash(bank, bags, money) - bank/bags have .items, no mail

	-- Detect SYNC-006 aggregated call: first param is array, second is nil
	if bank and type(bank) == "table" and bags == nil and mailOrMoney == nil then
		-- SYNC-006: bank is actually the aggregated items array, money is the 4th param
		local items = bank
		local actualMoney = money or 0

		local parts = {}
		table.insert(parts, tostring(actualMoney))

		table.insert(parts, "I:" .. hashItems(items))
		local combined = table.concat(parts, "|")
		return TOGBankClassic_Core:Checksum(combined)
	end

	-- Pre-SYNC-006 calling convention: ComputeInventoryHash(bank, bags, money)
	-- mailOrMoney is actually money (number), no mail parameter exists
	--
	-- TYPE-GUARDED, and this is a real defence rather than tidiness (AUDIT finding 26). This slot
	-- is positional and overloaded, so a caller passing a table here is a live hazard: `or 0`
	-- accepted it without complaint, and line 190's tostring() then baked a TABLE ADDRESS into the
	-- hash. An address differs between sessions, so the hash matched nothing -- including itself an
	-- hour earlier -- and re-drove every sync comparison forever. That is exactly what
	-- MIGRATE-001's "fix" did before it was reverted.
	--
	-- Reverting the one call site worked around it; this removes the class. A non-number in the
	-- money slot now hashes as 0, so the value can never depend on a table's IDENTITY.
	local actualMoney = (type(mailOrMoney) == "number") and mailOrMoney or 0

	local parts = {}

	-- Include money
	table.insert(parts, tostring(actualMoney))

	-- Include bank items (pre-SYNC-006 structure: bank.items)
	if bank and bank.items then
		table.insert(parts, "B:" .. hashItems(bank.items))
	end

	-- Include bag items (pre-SYNC-006 structure: bags.items)
	if bags and bags.items then
		table.insert(parts, "G:" .. hashItems(bags.items))
	end

	-- Note: Pre-SYNC-006 clients never had mail, so no mail hashing

	-- Concatenate all parts and compute simple hash
	local combined = table.concat(parts, "|")

	-- Use same hash function as checksum for consistency
	local sum = 0
	local len = #combined
	for i = 1, len do
		local byte = string.byte(combined, i)
		sum = (sum * 31 + byte) % 2147483647
	end
	sum = (sum * 31 + len) % 2147483647

	return sum
end

--- Revision 2: the corrected identity (suffix- and enchant-aware, tuple-aware). This is the hash the
--- addon reasons with; it is only COMPARED against a peer that also advertises it.
-- Compute a hash of inventory state to detect actual changes (v0.8.0)
-- Only updates version timestamps when this hash changes
function TOGBankClassic_DeltaComms:ComputeInventoryHash(bank, bags, mailOrMoney, money)
	return computeInventoryHashWith(hashInventoryItems, bank, bags, mailOrMoney, money)
end

--- Revision 1: FROZEN. See `hashInventoryItemsV1`. This is what an unmigrated peer computes, so it
--- is what we must send them and what we must compare against theirs.
function TOGBankClassic_DeltaComms:ComputeLegacyInventoryHash(bank, bags, mailOrMoney, money)
	return computeInventoryHashWith(hashInventoryItemsV1, bank, bags, mailOrMoney, money)
end

--- HASH-CANON-003: THE CANON. Content PLUS the publish datestamp, hashed together.
---
--- This is the number that identifies a VERSION of a bank, and the operator's requirement in their
--- own words: "I NEED CANON hashes written ONCE by the banker, then passed around. NEVER mutated.
--- The hash HAS to have the DTS in it and the NEWER V2 Hash wins."
---
--- WHY THE DATESTAMP BELONGS INSIDE IT. Without it the hash identifies a PAYLOAD, not a publish, so
--- two scans of coincidentally identical contents collide as one version and the guild reports
--- itself converged across a change that really happened. With it, every publish is distinguishable
--- from every other, which is what lets "newer wins" mean anything.
---
--- THE CIRCULARITY THIS AVOIDS, and it is why `ComputeInventoryHash` still exists unchanged: you
--- cannot use a DTS-bearing hash as the change detector, because it differs on every call by
--- construction, so every scan would look like a change and republish to the whole guild. The
--- CONTENT hash (`ComputeInventoryHash`, no datestamp) stays the detector and is never sent; the
--- DTS only advances when the content hash moves; the canon is then computed over both. So an
--- unchanged bank produces the same canon it did before and generates no traffic.
---
--- HASH-CANON-005: THE SHAPE IS `<dts><hash>`, ONE STRING, and the operator's words are the spec:
--- "i wanted the hash to be <dts><hash> all one long string ... so you COULD read the DTS and do
--- quick/easy comparison without having to pull the hash apart."
---
--- Until 2026-09-10 this was `Checksum(content .. "@" .. dts)`: the datestamp went IN and came out
--- as an unreadable number. That made the canon unique per publish, which is half the point, but
--- nothing could ask two canons WHICH IS NEWER -- only whether they were the same publish. Every
--- "am I behind?" question therefore fell back to hash EQUALITY against whatever a peer last said,
--- and that is the mechanism that painted current bankers red for minutes (TABCOLOUR-002).
---
--- Now the publish time is the first ten characters and the content checksum the last ten, both
--- zero-padded, so:
---   * `canon:sub(1, 10)` is the publish time, no parsing beyond tonumber;
---   * two canons compare as plain strings and the LATER PUBLISH SORTS HIGHER, because the
---     datestamp is fixed-width and leads (`a < b` is "a was published first" for any two canons
---     until the year 2286);
---   * equality still identifies one exact publish, which is what "what overwrites what" needs.
--- A canon is a STRING from here on. A NUMBER in the revision-2 slot is a canon minted by v1.4.0
--- (the mixed-in form) and carries no readable time: it is treated as no canon at all -- red until
--- its author scans once on this build. That is the no-backwards-compatibility directive applied,
--- and it is the whole reason the format could change at all.
---@param updatedAt number the publish time stamped by the scan that produced these items
---@return string canon `<10-digit publish time><10-digit content checksum>`
function TOGBankClassic_DeltaComms:ComputeCanonHash(bank, bags, mailOrMoney, money, updatedAt)
	local content = self:ComputeInventoryHash(bank, bags, mailOrMoney, money)
	local stamp = math.floor(tonumber(updatedAt) or 0)
	if stamp < 0 then stamp = 0 end
	return string.format("%010d%010d", stamp, content)
end

--- THE canon, from whatever the revision-2 slot holds. One spelling of "is this a canon we carry".
---
--- Three inputs, three answers:
---   * a `<dts><hash>` string          -> itself;
---   * a v1.4.0 NUMERIC canon plus the author's publish time -> RE-ENCODED as `<dts><number>`;
---   * anything else                    -> nil.
---
--- THE RE-ENCODING IS NOT A MUTATION, and the distinction is the operator's rule ("NEVER mutated").
--- Both inputs are the author's own -- the number they minted and the time they stamped, carried
--- verbatim to every holder -- and the rule is deterministic, so every client that holds a copy of
--- one old publish, the author included, converges on the SAME string with no rescan and no
--- recompute of content. Rebuilding the content half instead was considered and rejected: the
--- author hashes its legacy aggregate (Bank.lua:470) and a receiver holds the V2 view, which can
--- legitimately differ (that is what `/togbank dev compare` exists to catch), so it would be a
--- recompute on receipt -- exactly what HASH-CANON-001 forbids. Without this, every V2 copy in the
--- guild would read as "no canon" the day this shipped and the whole guild would rehydrate; the
--- operator's words on hearing that: "fuck, so the v2 data i have now will be old again".
---
--- A numeric canon with NO publish time cannot be re-encoded -- there is no date to lead with --
--- and is nil: no readable version, red until its author scans.
---@param v any the revision-2 slot as held or as received
---@param updatedAt number|nil the author's publish time that travelled beside it
---@return string|nil canon
function TOGBankClassic_DeltaComms:CanonFrom(v, updatedAt)
	if type(v) == "string" then
		if #v == 20 and v:match("^%d+$") then return v end
		return nil
	end
	local n = tonumber(v)
	local at = tonumber(updatedAt)
	-- HASH-CANON-013: a v1.4.0 numeric canon is Core:Checksum output, `% 2147483647` (Core.lua:138),
	-- so it is below 2^31 -- which is also the most `string.format("%d")` can carry in this Lua
	-- without wrapping negative. A number ABOVE that range is a
	-- 20-digit string canon that went through `tonumber` on an old-build client and came back as a
	-- float with its low digits gone -- read off the live guild: `theirs=17890060850786974720` for a
	-- real canon ending `...974116`, re-advertised by a peer on the previous release. Re-encoding
	-- that produces a canon with the right date and a wrong checksum, which compares unequal to the
	-- real one forever. It is not a version anyone can place; it is nil.
	if n and at and at > 0 and n >= 0 and n <= 2147483646 then
		return string.format("%010d%010d", math.floor(at), math.floor(n) % 10000000000)
	end
	return nil
end

--- The publish time read off the front of a canon, or nil when `canon` is not one.
---
--- nil for anything that is not a 20-digit string: a v1.4.0 numeric canon, a revision-1 hash, a
--- missing value. Callers treat nil as "no readable version" -- never as zero, because zero would
--- compare as OLDER than everything and make a garbage value look like ancient data rather than
--- like no data.
---@param canon any
---@return number|nil publishedAt
function TOGBankClassic_DeltaComms:CanonPublishTime(canon)
	if type(canon) ~= "string" or #canon ~= 20 or not canon:match("^%d+$") then return nil end
	local at = tonumber(canon:sub(1, 10))
	if not at or at <= 0 then return nil end
	return at
end

--- Stamp BOTH revisions onto an alt record from one item set.
---
--- HASH-REV-001. Every site that used to write `alt.inventoryHash` calls this instead, so the two
--- revisions cannot drift apart by one stamp site being missed -- which is the failure mode that
--- would make a client advertise a revision-2 hash computed from one scan beside a revision-1 hash
--- computed from another, and disagree with everybody including itself.
---@param alt table the alt record to stamp
---@return number legacy revision-1 hash, also stored as alt.inventoryHash
---@return string canon the `<dts><hash>` revision-2 canon, also stored as alt.inventoryHashV2
---@return number content the datestamp-free change detector, stored as alt.inventoryContentHash
--- HASH-CANON-003: `updatedAt` makes `inventoryHashV2` the CANON rather than a content digest.
--- Revision 1 stays content-only and FROZEN -- it is what an unmigrated peer computes, and folding a
--- datestamp into it would change a number we do not own.
---
--- `inventoryContentHash` is stored alongside and is the CHANGE DETECTOR: it is what the next scan
--- compares against to decide whether anything actually moved. It is deliberately never sent -- it
--- is this client's private bookkeeping, not a statement about a version, and putting it on the wire
--- would give peers a second identity to disagree about.
function TOGBankClassic_DeltaComms:StampInventoryHashes(alt, bank, bags, mailOrMoney, money, updatedAt)
	local legacy  = self:ComputeLegacyInventoryHash(bank, bags, mailOrMoney, money)
	local content = self:ComputeInventoryHash(bank, bags, mailOrMoney, money)
	local canon   = self:ComputeCanonHash(bank, bags, mailOrMoney, money, updatedAt)
	if alt then
		alt.inventoryHash        = legacy
		alt.inventoryHashV2      = canon
		alt.inventoryContentHash = content
	end
	return legacy, canon, content
end

-- DELTA PROTOCOL FUNCTIONS --

-- Check if delta sync should be used
function TOGBankClassic_DeltaComms:ShouldUseDelta()
	-- Check force flags first (for testing)
	if FEATURES and FEATURES.FORCE_DELTA_SYNC then
		return true
	end

	-- Check feature flags
	if not FEATURES or not FEATURES.DELTA_ENABLED then
		return false
	end
	if FEATURES.FORCE_FULL_SYNC then
		return false
	end

	-- No guild support threshold - clients will use delta if both sides support it
	return PROTOCOL.SUPPORTS_DELTA
end

-- INV2 step 10: `StripDeltaLinks` WAS HERE, and it is deleted rather than bypassed, per the
-- standing directive.
--
-- What it did: for every item on the wire it guessed whether the RECEIVER could rebuild the link
-- from its own client cache -- keeping the full link for gear, uncached and `ForceLink` rows, and
-- substituting a bare `item:...` string otherwise. That is a decision made on one machine about a
-- different machine's cache, and getting it wrong is how link-bearing rows go bad. It is the
-- corruption the V2 rework exists to remove, so removing the guess is the fix; leaving the function
-- present but unreached would keep the next person from understanding why.
--
-- What replaces it: nothing on the V2 path, which sends `{id, count, suffix, enchant}` and rebuilds
-- the link from LibItemDB on arrival (Modules/Inventory/Resolve.lua) -- no link crosses the wire, so
-- there is no link to decide about. On the legacy fallback path the delta is now sent UNSTRIPPED,
-- which is strictly safer: the link that arrives is the one we hold.
--
-- It also silently dropped fields. It rebuilt the envelope by listing members, so anything added
-- later that nobody remembered to list was discarded -- which is exactly what happened to
-- HASH-REV-001's `inventoryHashV2`.
--
-- `Item:NeedsLink` went with it: this was its only caller.

-- DELTA COMPUTATION FUNCTIONS --

-- INV2 step 10: `ItemsEqual`, `GetChangedFields` and `BuildItemIndex` were deleted here with the
-- link protocol they served. All three existed to decide, for a row that might carry a full link, an
-- ItemString, or neither, which stored row it "really" was -- and BuildItemIndex's two key schemes
-- (normalised link key, then an ID-only fallback) are the ambiguity in its plainest form. Tuples
-- have one spelling, so there is nothing to reconcile.

--- INV2: the tuple delta. Replaces ComputeItemDelta's identity machinery outright.
---
--- WHY THIS IS TWENTY LINES WHERE ComputeItemDelta IS TWO HUNDRED, because the difference is the
--- whole argument for the rework rather than a tidier implementation:
---
--- ComputeItemDelta derives an item's identity from its LINK -- `Item:GetItemKey(item.Link or
--- item.ItemString)`. A row may arrive carrying a full link, an ItemString, or neither (a minimal
--- baseline), and the same logical item keys DIFFERENTLY in each case. Everything built on top of
--- that is compensation for it: BuildItemIndex, a second ID-only index, a per-ID deep-fallback
--- candidate list, and `deepFallbackUsed` to stop two suffix variants of one base ID collapsing
--- onto the same old row. Each layer is a guess about which old row a new row "really" is.
---
--- A tuple has ONE spelling. `Record.key` is `id:suffix:enchant`, computed from integers that are
--- always present, so identity is a hash lookup and there is nothing to fall back to. The
--- ambiguity does not get handled better -- it stops existing.
---
--- Shape: `added` and `modified` carry whole tuples; `removed` carries KEYS only, because the key
--- is sufficient to find the row and a tuple would be three integers of waste per removal.
--- @return table delta { added = {rec,...}, modified = {rec,...}, removed = {key,...} }
function TOGBankClassic_DeltaComms:ComputeTupleDelta(oldRecords, newRecords)
	local Record = TOGBankClassic_Inventory_Record
	local delta = { added = {}, modified = {}, removed = {} }
	if not Record then return delta end

	-- Aggregate both sides first: two rows of the same item in one input must not read as a
	-- change. Record.aggregate also drops malformed rows rather than aborting the batch.
	local oldByKey = Record.aggregate(oldRecords or {})
	local newByKey = Record.aggregate(newRecords or {})

	for key, rec in pairs(newByKey) do
		local old = oldByKey[key]
		if not old then
			delta.added[#delta.added + 1] = rec
		elseif Record.count(old) ~= Record.count(rec) then
			-- Count is the only mutable field: id, suffix and enchant are the identity, so a
			-- change in any of them is a different item and shows up as an add plus a remove.
			delta.modified[#delta.modified + 1] = rec
		end
	end

	for key in pairs(oldByKey) do
		if not newByKey[key] then delta.removed[#delta.removed + 1] = key end
	end

	-- Stable order so an unchanged inventory serialises identically twice running, which is what
	-- lets a receiver's checksum mean anything.
	table.sort(delta.added,    function(a, b) return Record.key(a) < Record.key(b) end)
	table.sort(delta.modified, function(a, b) return Record.key(a) < Record.key(b) end)
	table.sort(delta.removed)
	return delta
end

--- Apply a tuple delta to a stored record array, returning the new array.
--- Mirrors ComputeTupleDelta exactly: same key, same three lists, no fallbacks.
function TOGBankClassic_DeltaComms:ApplyTupleDelta(records, delta)
	local Record = TOGBankClassic_Inventory_Record
	if not Record or type(delta) ~= "table" then return records or {} end

	local byKey = Record.aggregate(records or {})
	for _, key in ipairs(delta.removed or {}) do byKey[key] = nil end
	for _, rec in ipairs(delta.added or {}) do
		if Record.isValid(rec) then byKey[Record.key(rec)] = rec end
	end
	-- `modified` carries the WHOLE row, not a count difference, so applying it twice is
	-- idempotent. A delta that shipped a delta-of-count would not be, and a duplicated message
	-- would silently double a stack.
	for _, rec in ipairs(delta.modified or {}) do
		if Record.isValid(rec) then byKey[Record.key(rec)] = rec end
	end

	local out = {}
	for _, rec in pairs(byKey) do out[#out + 1] = rec end
	table.sort(out, function(a, b) return Record.key(a) < Record.key(b) end)
	return out
end

-- INV2 step 10: `ComputeItemDelta` was deleted here, and its shape is the clearest single argument
-- for the rework. It matched a new row to an old one through THREE successive guesses -- normalised
-- link key, then an ID-only index for minimal baselines, then a per-ID candidate list with a
-- `deepFallbackUsed` set to stop two suffix variants of one base ID collapsing onto the same old
-- row. Every layer was compensation for identity being derived from a LINK that may or may not be
-- present. `ComputeTupleDelta` above is thirty lines because `Record.key` is `id:suffix:enchant`
-- from integers that are always there: identity is a hash lookup and there is nothing to fall back
-- to. The ambiguity is not handled better; it stops existing.

-- INV2 step 10: `ComputeDelta` was deleted here. It built an `alt-delta` envelope by diffing the
-- banker's three containers against the REQUESTER's baseline, reconstructed from the state summary
-- via `expandMinimalItems` -- rows with an ID and a Count and no Link, which is where much of
-- ComputeItemDelta's fallback machinery came from. A V2 send is a full tuple snapshot and needs to
-- know nothing about what the requester holds, so the baseline, its expansion and the diff all go
-- together. `ComputeTupleDelta` is the replacement when `togbank-state` learns to carry a tuple
-- baseline; until then the snapshot is the whole message.

-- Estimate serialized size of a data structure
function TOGBankClassic_DeltaComms:EstimateSize(data)
	if not data then
		return 0
	end

	-- Rough estimate: serialize and measure length
	local serialized = TOGBankClassic_Core:SerializeWithChecksum(data)
	return string.len(serialized or "")
end

-- INV2 step 10: `DeltaHasChanges` went with `ComputeDelta`. Its only job was deciding whether a
-- computed `alt-delta` was empty enough to answer with a `togbank-nochange` correction instead, and
-- the delta is gone. The MESSAGE is not: `RespondToStateSummary` still sends `togbank-nochange`
-- when the hashes already match, which it decides from the hashes directly and never needed this.

-- INV2 step 10 / directive 2026-09-09: `ApplyItemDelta` and `ApplyDelta` WERE HERE, ~570 lines of
-- them, and they are deleted with the legacy link wire format they existed to apply.
--
-- They were the RECEIVE half of the link protocol: link-keyed identity via `Item:GetItemKey`, a
-- second ID-only index for linkless rows, the ITEM-003 ghost guards, the STALE-INDEX ordering, the
-- version/banker/newest-wins validation and the hash recompute. Every HIGH finding this codebase's
-- audit produced came out of this region -- findings 31, 32 and 34 among them -- which is the
-- argument for deleting it rather than keeping it warm for peers who no longer exist to us.
--
-- What replaces it: `ApplyTupleDelta` above, plus the direct `SetAltRecords` store in Chat.lua's
-- tuple receive branch. A tuple row is `{id, count, suffix, enchant}` and its identity is
-- `Record.keyFor` -- one function, shared with the hash, so there is no second index to keep in
-- step and no ghost class to guard against.
--
-- `Item:ItemClassNeedsLink` does NOT go with it, and an earlier draft of this note wrongly said it
-- did. The ITEM-003 guards here were not its last callers: `Database:PurgeLinklessGearGhosts` still
-- uses it to repair linkless gear ALREADY SITTING in players' SavedVariables from earlier versions,
-- and that runs at load. Deleting it would abandon that repair for anyone who has not loaded since.

-- ERROR TRACKING FUNCTIONS --

function TOGBankClassic_DeltaComms:RecordDeltaError(guildName, altName, errorType, errorMessage)
	local error = {
		altName = altName,
		errorType = errorType,
		message = errorMessage,
		timestamp = GetServerTime(),
	}

	-- Try to use database storage first
	if guildName then
		local db = TOGBankClassic_Database.db.faction[guildName]
		if db and db.deltaErrors then
			-- Use database storage
			table.insert(db.deltaErrors.lastErrors, 1, error)

			-- Keep only recent errors (max 10)
			while #db.deltaErrors.lastErrors > 10 do
				table.remove(db.deltaErrors.lastErrors)
			end

			-- Track failure count per alt
			if not db.deltaErrors.failureCounts[altName] then
				db.deltaErrors.failureCounts[altName] = 0
			end
			db.deltaErrors.failureCounts[altName] = db.deltaErrors.failureCounts[altName] + 1

			-- Notify user if repeated failures (3+ failures for same alt) and player is online
			if db.deltaErrors.failureCounts[altName] >= 3 and not db.deltaErrors.notifiedAlts[altName] then
				if TOGBankClassic_Guild:IsPlayerOnline(altName) then
					TOGBankClassic_Output:Warn(
						"Repeated delta sync failures for %s. Falling back to full sync.",
						altName
					)
					db.deltaErrors.notifiedAlts[altName] = true
				end
			end
			return
		end
	end

	-- Fallback: Use temporary in-memory storage
	TOGBankClassic_Output:Debug(
		"DELTA",
		"Using temporary error storage for %s (%s): Guild.Info not initialized",
		altName or "unknown",
		errorType or "unknown"
	)

	if not TOGBankClassic_Guild.tempDeltaErrors then
		TOGBankClassic_Guild.tempDeltaErrors = {
			lastErrors = {},
			failureCounts = {},
			notifiedAlts = {}
		}
	end

	table.insert(TOGBankClassic_Guild.tempDeltaErrors.lastErrors, 1, error)

	-- Keep only recent errors (max 10)
	while #TOGBankClassic_Guild.tempDeltaErrors.lastErrors > 10 do
		table.remove(TOGBankClassic_Guild.tempDeltaErrors.lastErrors)
	end

	-- Track failure count per alt
	if not TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] then
		TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] = 0
	end
	TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] = TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] + 1

	-- Notify user if repeated failures (3+ failures for same alt) and player is online
	if TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] >= 3 and not TOGBankClassic_Guild.tempDeltaErrors.notifiedAlts[altName] then
		if TOGBankClassic_Guild:IsPlayerOnline(altName) then
			TOGBankClassic_Output:Warn(
				"Repeated delta sync failures for %s. Falling back to full sync.",
				altName
			)
			TOGBankClassic_Guild.tempDeltaErrors.notifiedAlts[altName] = true
		end
	end
end

-- Reset failure count for an alt (called on successful sync)
function TOGBankClassic_DeltaComms:ResetDeltaErrorCount(guildName, altName)
	-- Reset in database if available
	if guildName then
		local db = TOGBankClassic_Database.db.faction[guildName]
		if db and db.deltaErrors then
			if db.deltaErrors.failureCounts[altName] then
				db.deltaErrors.failureCounts[altName] = 0
			end
			if db.deltaErrors.notifiedAlts[altName] then
				db.deltaErrors.notifiedAlts[altName] = nil
			end
		end
	end

	-- Also reset in temporary storage
	if TOGBankClassic_Guild.tempDeltaErrors then
		if TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] then
			TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] = 0
		end
		if TOGBankClassic_Guild.tempDeltaErrors.notifiedAlts[altName] then
			TOGBankClassic_Guild.tempDeltaErrors.notifiedAlts[altName] = nil
		end
	end
end

-- Get recent delta errors
function TOGBankClassic_DeltaComms:GetRecentDeltaErrors(guildName)
	-- Return from database if available
	if guildName then
		local db = TOGBankClassic_Database.db.faction[guildName]
		if db and db.deltaErrors then
			return db.deltaErrors.lastErrors
		end
	end

	-- Fallback to temporary storage
	if TOGBankClassic_Guild.tempDeltaErrors then
		return TOGBankClassic_Guild.tempDeltaErrors.lastErrors
	end

	return {}
end

-- Get failure count for an alt
function TOGBankClassic_DeltaComms:GetDeltaFailureCount(guildName, altName)
	-- Check database first if available
	if guildName then
		local db = TOGBankClassic_Database.db.faction[guildName]
		if db and db.deltaErrors then
			return db.deltaErrors.failureCounts[altName] or 0
		end
	end

	-- Fallback to temporary storage
	if TOGBankClassic_Guild.tempDeltaErrors then
		return TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] or 0
	end

	return 0
end

-- Clear error counters for all offline players (called on roster update)
function TOGBankClassic_DeltaComms:ClearOfflineErrorCounters(guildName)
	if not guildName then
		return
	end

	local db = TOGBankClassic_Database.db.faction[guildName]
	if not db or not db.deltaErrors then
		return
	end

	-- Check each alt with error counters
	for altName, _ in pairs(db.deltaErrors.failureCounts) do
		if not TOGBankClassic_Guild:IsPlayerOnline(altName) then
			db.deltaErrors.failureCounts[altName] = nil
			db.deltaErrors.notifiedAlts[altName] = nil
		end
	end
end

-- PULL-BASED PROTOCOL FUNCTIONS --

-- Fast-fill missing alts using pull-based protocol (v0.8.0)
function TOGBankClassic_DeltaComms:FastFillMissingAlts(guildInfo)
	if not guildInfo then
		return
	end

	-- HASH-REFORM: Do not fast-fill while the P2PSession collect window is open.
	-- Fast-fill uses whatever hashes are in latestBankerHashes right now, which may
	-- only reflect the first peer to respond. The collect window gathers ALL peer offers
	-- and picks the best (newest updatedAt) before dispatching. Firing early locks us
	-- into stale hashes and causes same-timestamp/different-hash mismatches.
	if TOGBankClassic_P2PSession and TOGBankClassic_P2PSession.isCollecting then
		TOGBankClassic_Output:Debug("DELTA", "FAST-FILL", "Fast-fill suppressed: P2PSession collect window is open (waiting for all peer offers)")
		return
	end

	-- SYNC-001 fix: Get live banker roster from current guild instead of using
	-- cached roster.alts which may contain stale cross-guild data
	local rosterAlts = TOGBankClassic_Guild:GetBanks()
	if not rosterAlts or #rosterAlts == 0 then
		return
	end

	local missing = {}
	local missingDebug = {}
	local missingInfo = {}
	TOGBankClassic_Output:Debug("PROTOCOL", "HLR-COMPARE", "FastFill: Starting check of %d roster alts", #rosterAlts)
	for _, altName in ipairs(rosterAlts) do
		local norm = TOGBankClassic_Guild:NormalizeName(altName)
		local localAlt = guildInfo.alts and norm and guildInfo.alts[norm]
		local hasEntry = localAlt ~= nil
		local hasContent = hasEntry and TOGBankClassic_Guild:HasAltContent(localAlt, norm)

		-- Check for hash mismatch (stale data)
		local bankerCache = TOGBankClassic_Guild.latestBankerHashes and TOGBankClassic_Guild.latestBankerHashes[norm]
		local hashMismatch = false
		local mismatchReason = nil
		if bankerCache and hasEntry and localAlt then
			-- HASH-CANON-006: through the ONE comparison. This was a fourth inline spelling of
			-- revision-1 equality (after HashesAgreeWith, the HLR compare and BroadcastP2PRequest),
			-- and every one of them called a pre-canon copy "in sync" with the banker's canon when
			-- the revision-1 numbers happened to agree -- so the copy was never replaced.
			local agree, localHash, localMailHash = TOGBankClassic_Guild:HashesAgreeWith(localAlt, bankerCache)
			if not agree then
				hashMismatch = true
				mismatchReason = string.format("version mismatch (local=%s/%s canon=%s, banker=%s/%s canon=%s)",
					tostring(localHash), tostring(localMailHash), tostring(localAlt.inventoryHashV2),
					tostring(bankerCache.hash), tostring(bankerCache.mailHash), tostring(bankerCache.hashV2))
			end
		end

		-- DEBUG: Log every alt to see what's happening
		TOGBankClassic_Output:Debug("PROTOCOL", "HLR-COMPARE", "FastFill check: %s hasEntry=%s hasContent=%s hashMismatch=%s",
			tostring(norm), tostring(hasEntry), tostring(hasContent), tostring(hashMismatch))

		-- Check if we need to request this alt: no entry, no content, OR hash mismatch
		if not hasEntry or not hasContent or hashMismatch then
			table.insert(missing, norm)
			local hasRaw = guildInfo.alts and guildInfo.alts[altName] ~= nil
			local reason = mismatchReason or (hasEntry and "no content" or "no entry")
			missingInfo[norm] = {
				reason = reason,
				hash = (bankerCache and bankerCache.hash) or (localAlt and localAlt.inventoryHash) or nil,
				hashV2 = (bankerCache and bankerCache.hashV2) or nil,
				updatedAt = (bankerCache and bankerCache.updatedAt) or (localAlt and (localAlt.inventoryUpdatedAt or localAlt.version)) or nil,
			}
			table.insert(
				missingDebug,
				string.format("%s (norm=%s, rawKey=%s, reason=%s)", tostring(altName), tostring(norm), tostring(hasRaw), reason)
			)
		end
	end

	if #missing == 0 then
		TOGBankClassic_Output:Debug("DELTA", "APPLY", "Fast-fill: All %d roster alts present locally", #rosterAlts)
		return
	end

	local haveCount, totalCount = TOGBankClassic_Guild:GetBankerDataProgress()
	TOGBankClassic_Output:Debug("DELTA", "FAST-FILL", "Fast-fill: Requesting %d missing alts (have %d/%d)", #missing, haveCount, totalCount)
	TOGBankClassic_Guild:ReportBankerDataProgress("fast-fill", true)
	if #missingDebug > 0 then
		TOGBankClassic_Output:Debug("DELTA", "APPLY", "Fast-fill missing alts: %s", table.concat(missingDebug, ", "))
	end

	local hasOnlineBanker = false
	for member, _ in pairs(TOGBankClassic_Guild.onlineMembers or {}) do
		if TOGBankClassic_Guild:IsBank(member) and TOGBankClassic_Guild:IsPlayerOnline(member) then
			hasOnlineBanker = true
			break
		end
	end
	if not hasOnlineBanker then
		GuildRoster()
		for i = 1, GetNumGuildMembers() do
			local rosterName, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
			if rosterName and online then
				local normRoster = TOGBankClassic_Guild:NormalizeName(rosterName)
				if TOGBankClassic_Guild:IsBank(normRoster) then
					hasOnlineBanker = true
					break
				end
			end
		end
	end

	-- NOTHING CONSUMES THIS ANSWER, and that is worth stating rather than quietly deleting.
	-- The two passes above -- including a GuildRoster() server refresh and a full
	-- GetNumGuildMembers() scan on the miss path -- compute whether any banker is online, and the
	-- loop below then queries every missing alt regardless. The flag clearly used to gate
	-- something (peer-vs-banker routing, most likely) and that gate is gone.
	--
	-- Kept rather than removed because GuildRoster() is a SIDE EFFECT on the server, and whether
	-- the refresh is still wanted here is a decision, not a cleanup. Logging it makes the computed
	-- fact visible instead of discarded, and changes no control flow.
	TOGBankClassic_Output:Debug("DELTA", "FAST-FILL",
		"Fast-fill proceeding for %d alt(s); banker online = %s (advisory only, nothing gates on it)",
		#missing, tostring(hasOnlineBanker))

	-- Query each missing alt using pull-based protocol
	for _, norm in ipairs(missing) do
		local info = missingInfo[norm]
		TOGBankClassic_Output:Debug(
			"PROTOCOL",
			"HLR-COMPARE",
			"Fast-fill processing: %s (info=%s, hash=%s, hasHash=%s, hashNotZero=%s)",
			tostring(norm),
			tostring(info ~= nil),
			tostring(info and info.hash),
			tostring(info and info.hash and true or false),
			tostring(info and info.hash and info.hash ~= 0 or false)
		)
		-- PERF-006: Use P2P whenever we have a hash, regardless of banker online status
		if info and info.hash and info.hash ~= 0 then
			-- We have hash but no content - broadcast P2P request (GUILD → timeout → banker fallback)
			TOGBankClassic_Output:Debug(
				"PROTOCOL",
				"HLR-COMPARE",
				"Fast-fill P2P broadcast: requesting %s (expectedHash=%s, updatedAt=%s)",
				tostring(norm),
				tostring(info.hash),
				tostring(info.updatedAt)
			)
			TOGBankClassic_Guild:BroadcastP2PRequest(norm, info.hash, info.updatedAt, nil, info.hashV2)
		-- No hash: skip; will be acquired in next SyncDeltaVersion cycle
		end
	end
end
