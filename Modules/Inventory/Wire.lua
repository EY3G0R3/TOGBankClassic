-- Inventory/Wire.lua — V2 payload encode/decode.
--
-- See docs/INVENTORY_V2.md §6. The asymmetry here is deliberate and permanent:
--
--   SEND    switchable (sendV2Wire). The legacy send path is GONE, so off means send nothing.
--   RECEIVE never switchable -- but see the correction below about what that now means.
--
-- CORRECTION, AND IT MATTERS FOR ANYONE REASONING ABOUT MIXED VERSIONS. This header used to say
-- "Both formats are always accepted ... what lets a guild run mixed versions at all". THAT IS NO
-- LONGER TRUE AT THE CONSUMER. The 2026-09-09 directive deleted backwards compatibility on the
-- wire in both directions: `Modules/Chat.lua`'s `togbank-d4` handler now DROPS any payload that is
-- not a tuple payload, including an old client's delta, before `Wire.decode` is ever reached -- and
-- warns the user by name when the sender is a banker.
--
-- SO `decodeLegacy` BELOW IS REACHABLE ONLY THROUGH `Wire.decode` ITSELF, and the inventory path no
-- longer calls it that way. Do not read its continued existence as evidence that legacy inventory
-- is still accepted: it is not. Read Chat.lua's handler for what actually happens to an old
-- payload; this file describes only what the decoder is capable of.
--
-- Wire shape (positional, matching the togbank-ri / rd2 convention already used for requests):
--
--   { WIRE_VERSION, altName, money, { {id, count, suffix, enchant}, ... } }
--
-- Positional because this is the payload the whole rework exists to shrink: a full link is
-- ~70-90 bytes, a tuple is 2-4 integers. Named keys would put the saving back.
--
-- NOTE ON THE NO-TRANSLATION RULE (§5): that rule forbids reading one DB to produce the other.
-- Decoding an incoming legacy payload into tuples is not that -- it is parsing a message off the
-- wire, exactly as Scan parses a bag slot. Neither DB is read to produce the other.

TOGBankClassic_Inventory_Wire = {}
local Wire = TOGBankClassic_Inventory_Wire

local Record = TOGBankClassic_Inventory_Record

-- Bump only for a breaking change to the positional layout. Adding a trailing optional field is
-- not breaking: older receivers ignore it, newer ones tolerate its absence.
Wire.VERSION = 1

local F_VERSION, F_ALT, F_MONEY, F_RECORDS, F_HASH, F_HASHV2, F_UPDATEDAT, F_MAILHASH =
	1, 2, 3, 4, 5, 6, 7, 8

--- Build a V2 payload. Returns nil when there is nothing sendable, so callers never transmit an
--- empty envelope that a receiver would apply as "this alt has no items".
---
--- HASH-CANON-001. `hash` and `hashV2` are THE AUTHOR'S CANON travelling with the data they
--- describe, and carrying them is the whole point rather than an optimisation.
---
--- Before this the payload was { version, alt, money, records } and NOTHING ELSE -- no hash on the
--- wire at all. A receiver therefore had nothing to store and recomputed one from its own
--- materialised view. DeltaSync's canonical-hash rules (its README, "compute once, at save, and
--- never again") name that exact move and its cost: "recompute on receipt -- you overwrite the
--- author's statement with your own opinion of their data. Now nobody is authoritative and every
--- client can disagree with every other." The symptom it warns of is the one this guild has:
--- content present for every banker and hashes agreeing with almost none.
---
--- It matters beyond reporting, and this is the operator's point: THE HASH IS WHAT DECIDES WHAT
--- OVERWRITES WHAT. A recomputed hash means that decision rests on a number the author never
--- published.
---
--- Both revisions ride together for the reason HASH-REV-001 gives: revision 2 is what two migrated
--- clients compare on, revision 1 is what an unmigrated peer can still read, and splitting them
--- across messages is how they drift apart.
---
--- TRAILING AND OPTIONAL, which the header above already licenses -- "adding a trailing optional
--- field is not breaking: older receivers ignore it, newer ones tolerate its absence." So this does
--- not bump Wire.VERSION.
--- HASH-CANON-001 rule 7. `updatedAt` IS THE AUTHOR'S PUBLISH TIME and travels with the record for
--- the same reason the hashes do. Before this the payload carried no timestamp at all and the
--- receiver stamped its own `GetServerTime()` on arrival, which is the failure rule 7 names:
--- "ordering is a different question from identity... decide that at apply time, from the timestamp
--- INSIDE THE RECORD THAT ARRIVED".
---
--- WHAT THE MINTED TIMESTAMP ACTUALLY BROKE, which is worse than a reporting problem: every
--- receiver re-advertises what it holds (`Guild.lua:358`, `:1033`, `:1582`), and P2PSession sorts
--- candidate holders by `updatedAt` DESCENDING to pick the freshest (`P2PSession.lua:184-190`). With
--- a receive-time stamp, the peer who received a snapshot MOST RECENTLY advertises the NEWEST
--- timestamp -- so a relayed third-hand copy outranks the author's own record, and the later a copy
--- propagates the fresher it claims to be. That decides what overwrites what.
---
--- This is also why rule 6 ("do not send the datestamp as a separate field") cannot mean "never
--- transmit a timestamp": rule 7 needs it at apply time and a hash is one-way, so it could not be
--- recovered. Rule 6 forbids a SECOND INDEPENDENT identity that can drift. This one cannot drift --
--- `Bank.lua:417-420` stamps the timestamp and both hashes in one block from one scan, and they
--- travel together in one payload.
---
--- HASH-CANON-004: `mailHash` TRAVELS TOO, and leaving it off was a regression rather than an
--- omission. `Guild:HashesAgreeWith` requires BOTH the inventory hash and the mail hash to match
--- before it will call an alt in sync (`Guild.lua:1097`). Only the author's own scan stamps
--- `alt.mailHash` (`Bank.lua:454`), and the two paths that used to populate it for a REMOTE alt --
--- the query-path recompute and the no-change adoption -- were both deleted as hash-mutation sites
--- in HASH-CANON-002. Correctly deleted: they minted a number on a client that had not read that
--- mail. But nothing replaced them, so a receiving client held `nil` for every remote banker's mail
--- hash while the banker advertised a real one.
---
--- FAILURE THAT CAUSED: `mailHashMatches` compares the advertised value against `localAlt.mailHash
--- or 0`, so it is false forever. Every remote banker reads as permanently sync-pending and is
--- re-requested indefinitely -- a broadcast storm of exactly the shape this work exists to remove,
--- and it would have looked like the original complaint rather than like a new defect.
---
--- The fix is the same shape as the other two: the author stamps it, it rides with the data it
--- describes, and the receiver stores it verbatim rather than deriving one.
--- @param hash number|nil the author's revision-1 hash for this record set
--- @param hashV2 number|nil the author's revision-2 hash
--- @param updatedAt number|nil the author's publish time, from the scan that produced these records
--- @param mailHash number|nil the author's mail hash, stamped by the same scan
function Wire.encode(altName, records, money, hash, hashV2, updatedAt, mailHash)
	if type(altName) ~= "string" or altName == "" then return nil end
	local out = {}
	for _, rec in ipairs(records or {}) do
		if Record.isValid(rec) then out[#out + 1] = rec end
	end
	return { Wire.VERSION, altName, tonumber(money) or 0, out,
		tonumber(hash) or nil, tonumber(hashV2) or nil, tonumber(updatedAt) or nil,
		tonumber(mailHash) or nil }
end

--- True if `payload` looks like a V2 tuple payload rather than a legacy link payload.
---
--- Structural, not a flag: a legacy payload is a MAP with named fields (`name`, `items`), a V2
--- payload is an ARRAY whose first element is the version integer. Sniffing the shape means an
--- old client that never learned to set a marker is still classified correctly.
function Wire.isV2(payload)
	if type(payload) ~= "table" then return false end
	return type(payload[F_VERSION]) == "number" and type(payload[F_ALT]) == "string"
end

--- Decode a V2 payload.
---
--- HASH-CANON-001: the author's hashes come back as the 4th and 5th returns, NOT re-derived. They
--- are nil when the sender did not supply them, and nil is meaningful -- it means "this author
--- published no canon", which a receiver must be able to tell apart from "the author published
--- zero". Do not coerce them to 0.
--- @return string|nil altName, table records, number money, number|nil hash, number|nil hashV2, number dropped, number|nil updatedAt, number|nil mailHash
local function decodeV2(payload)
	local version = payload[F_VERSION]
	-- A newer major layout cannot be read positionally, and guessing would apply wrong values
	-- silently. Refusing is the safe failure: the sender retries as the receiver upgrades.
	if version > Wire.VERSION then return nil, {}, 0, nil, nil, 0, nil, nil end

	local records, dropped = {}, 0
	for _, rec in ipairs(payload[F_RECORDS] or {}) do
		-- Rebuild through Record.new rather than trusting the wire: a malformed tuple from a
		-- buggy or hostile peer must not reach the store.
		local clean = Record.new(rec[1], rec[2], rec[3], rec[4])
		if clean then
			records[#records + 1] = clean
		else
			dropped = dropped + 1
		end
	end
	-- The RECORDS are rebuilt through Record.new because a malformed tuple must not reach the
	-- store. The HASHES are not "rebuilt" -- there is nothing to validate them against, and
	-- computing one here would be the very recompute-on-receipt this change exists to remove.
	-- tonumber() only rejects a non-numeric; it does not invent a value.
	--
	-- `dropped` EXISTS BECAUSE OF THE HASH, and it is the answer to the objection the old receive
	-- path was built on. That code recomputed rather than storing the sender's hash, arguing that
	-- "a sender-supplied hash that disagrees with the stored rows produces a false in-sync state
	-- that silences future syncs while the data is wrong". The concern is REAL; the remedy was
	-- aimed at the wrong thing. The disagreement it feared can only arise when THIS LOOP SILENTLY
	-- DISCARDED SOMETHING -- and the fix for a lossy decode is to REPORT THE LOSS, not to paper
	-- over it by inventing a different number. A caller that hears dropped > 0 knows it does not
	-- hold the author's version and must not claim the author's hash.
	--
	-- `updatedAt` is returned as nil when absent, NOT defaulted to 0 or to now. nil means "this
	-- author published no time", which the caller must be able to tell from a real one -- the same
	-- reasoning as the hashes directly above.
	return payload[F_ALT], records, tonumber(payload[F_MONEY]) or 0,
		tonumber(payload[F_HASH]), tonumber(payload[F_HASHV2]), dropped,
		tonumber(payload[F_UPDATEDAT]), tonumber(payload[F_MAILHASH])
end

--- Decode a legacy link payload into tuples.
---
--- Accepts the shapes older clients send: `{ name = ..., items = { {ID=, Count=, Link=}, ... } }`.
--- Suffix and enchant come from the link via the same parser the scanner uses, so a legacy
--- payload and a local scan of the same item produce an identical tuple key.
local function decodeLegacy(payload)
	local altName = payload.name or payload.alt
	if type(altName) ~= "string" then return nil, {}, 0 end

	local Scan = TOGBankClassic_Inventory_Scan
	local records = {}
	for _, item in ipairs(payload.items or {}) do
		if type(item) == "table" and item.ID then
			local enchant, suffix = 0, 0
			if Scan and item.Link then enchant, suffix = Scan.parseLink(item.Link) end
			local rec = Record.new(item.ID, item.Count or 1, suffix, enchant)
			if rec then records[#records + 1] = rec end
		end
	end
	return altName, records, tonumber(payload.money) or 0
end

--- CMD-004: build the LEGACY payload these tuples would have been sent as, for size comparison.
---
--- Deliberately adjacent to `decodeLegacy` above, because the two are one contract seen from either
--- end and this is the only thing keeping them in step. `/togbank dev bandwidth` used to rebuild
--- this shape inline in `Modules/Chat.lua`, which made it a SECOND SPELLING of the legacy format
--- with nothing asserting the two agreed -- and the number it produces is published on the store
--- page, so a silent divergence would put a wrong figure in front of users.
---
--- `wire_spec` round-trips the output through `Wire.decode` and asserts the records come back
--- unchanged. That is what makes divergence loud: if this stops emitting a shape `decodeLegacy`
--- accepts, the round trip breaks rather than the measurement quietly moving.
---
--- NOT A SEND PATH. Nothing transmits this -- the legacy send path is deleted. It exists to be
--- MEASURED. Resolve is looked up at call time rather than held, so this file gains no load-order
--- dependency on it.
--- @return table payload, number resolvedLinks, number rows
function Wire.legacyShapeFor(altName, records, money)
	local Resolve = TOGBankClassic_Inventory_Resolve
	local items, resolved = {}, 0
	for _, rec in ipairs(records or {}) do
		local link
		if Resolve and Resolve.describe then
			local d = Resolve.describe(rec)
			link = d and d.link or nil
		end
		if link then resolved = resolved + 1 end
		items[#items + 1] = {
			ID    = Record.id(rec),
			Count = Record.count(rec),
			Link  = link,
		}
	end
	-- `resolved` is returned so a caller can tell "the legacy payload was genuinely this small"
	-- from "ItemDB could not resolve these items, so the links are missing and the comparison is
	-- measuring an absence". Without it a client with no ItemDB reports a spectacular saving.
	return { name = altName, items = items, money = tonumber(money) or 0 }, resolved, #items
end

--- Decode either format. Callers do not need to know which arrived.
---
--- HASH-CANON-001: `hash` and `hashV2` are the AUTHOR'S, forwarded verbatim, and are nil when the
--- sender published none. A legacy payload never carries them, which is correct rather than a gap
--- -- an author that did not publish a canon has not made a statement for anyone to store.
--- HASH-CANON-001 rule 7: `updatedAt` is the AUTHOR'S publish time, forwarded the same way, and is
--- nil when the sender published none. A caller must order by this rather than by its own receive
--- time -- see the note on `Wire.encode` for what the receive-time stamp broke.
--- HASH-CANON-004: `mailHash` is forwarded the same way and for the same reason -- see the note on
--- `Wire.encode`. Agreement needs it, and only the author may produce one.
---
--- THE POSITIONS ARE NOT THE SAME AS `decodeV2`'s. This wrapper inserts `format` at position 4, so
--- every later value sits one slot further right than the inner function returns it. Counting
--- underscores against `decodeV2` is how a caller lands on `updatedAt` while believing it read the
--- mail hash -- which happened while writing this, and the spec caught it only because it asserted
--- a distinctive value rather than merely "not nil".
--- @return string|nil altName, table records, number money, string format, number|nil hash, number|nil hashV2, number dropped, number|nil updatedAt, number|nil mailHash
function Wire.decode(payload)
	if type(payload) ~= "table" then return nil, {}, 0, "invalid", nil, nil, 0, nil, nil end
	if Wire.isV2(payload) then
		local alt, records, money, hash, hashV2, dropped, updatedAt, mailHash = decodeV2(payload)
		return alt, records, money, "v2", hash, hashV2, dropped, updatedAt, mailHash
	end
	local alt, records, money = decodeLegacy(payload)
	return alt, records, money, "legacy", nil, nil, 0, nil, nil
end

--- Should this client emit tuples? Send is switchable; receive never is.
function Wire.shouldSendV2()
	return TOGBankClassic_Switches
		and TOGBankClassic_Switches:IsEnabled("sendV2Wire")
		or false
end

--- Rough encoded size in bytes, for measuring the saving rather than asserting it.
--- INV2-DOC-001 pulled the bandwidth figures from the CurseForge page precisely because they
--- were unverified; this is what puts real numbers back.
function Wire.estimateSize(payload)
	if type(payload) ~= "table" then return 0 end
	local function measure(v)
		local t = type(v)
		if t == "number" then return #tostring(v) + 1 end
		if t == "string" then return #v + 3 end
		if t ~= "table" then return 4 end
		local n = 2
		for k, inner in pairs(v) do
			if type(k) == "string" then n = n + #k + 2 end
			n = n + measure(inner)
		end
		return n
	end
	return measure(payload)
end
