-- Inventory/Wire.lua — V2 payload encode/decode.
--
-- See docs/INVENTORY_V2.md §6. The asymmetry here is deliberate and permanent:
--
--   SEND    switchable (sendV2Wire). Safely reversible: flip it off and old clients keep working.
--   RECEIVE never switchable. Both formats are always accepted.
--
-- Receiving both is not a migration aid to be removed later -- it is what lets a guild run mixed
-- versions at all. A client that only understood tuples would silently ignore every peer still
-- sending links, and "ignored" looks exactly like "that banker has no items".
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

local F_VERSION, F_ALT, F_MONEY, F_RECORDS = 1, 2, 3, 4

--- Build a V2 payload. Returns nil when there is nothing sendable, so callers never transmit an
--- empty envelope that a receiver would apply as "this alt has no items".
function Wire.encode(altName, records, money)
	if type(altName) ~= "string" or altName == "" then return nil end
	local out = {}
	for _, rec in ipairs(records or {}) do
		if Record.isValid(rec) then out[#out + 1] = rec end
	end
	return { Wire.VERSION, altName, tonumber(money) or 0, out }
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
--- @return string|nil altName, table records, number money
local function decodeV2(payload)
	local version = payload[F_VERSION]
	-- A newer major layout cannot be read positionally, and guessing would apply wrong values
	-- silently. Refusing is the safe failure: the sender retries as the receiver upgrades.
	if version > Wire.VERSION then return nil, {}, 0 end

	local records = {}
	for _, rec in ipairs(payload[F_RECORDS] or {}) do
		-- Rebuild through Record.new rather than trusting the wire: a malformed tuple from a
		-- buggy or hostile peer must not reach the store.
		local clean = Record.new(rec[1], rec[2], rec[3], rec[4])
		if clean then records[#records + 1] = clean end
	end
	return payload[F_ALT], records, tonumber(payload[F_MONEY]) or 0
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

--- Decode either format. Callers do not need to know which arrived.
--- @return string|nil altName, table records, number money, string format
function Wire.decode(payload)
	if type(payload) ~= "table" then return nil, {}, 0, "invalid" end
	if Wire.isV2(payload) then
		local alt, records, money = decodeV2(payload)
		return alt, records, money, "v2"
	end
	local alt, records, money = decodeLegacy(payload)
	return alt, records, money, "legacy"
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
