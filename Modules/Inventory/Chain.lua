-- Inventory/Chain.lua -- the per-version DELTA CHAIN: written first-hand at mint, kept in a window.
--
-- THE DELTA RELEASE, step 3 (docs/DELTA_RELEASE.md sections 3.1-3.3). The operator, 2026-09-11:
-- "we need to use the P2P deltasync with deltas, so we aren't transmitting a bunch of 'old' stuff"
-- and, on being told the V2 wire sent full snapshots: "v2 SHOULD be using deltas too".
--
-- WHAT A LINK IN THE CHAIN IS. When a banker's own client mints a new version (Bank:MintVersion), it
-- holds BOTH the records it published last time and the records it is publishing now -- it is the
-- one client that always does. It computes the difference with DeltaSync's own delta engine
-- (`host:ComputeStructuredDelta`, keyed by `Record.key` so a suffix variant is its own row),
-- labels it with the new version's canon and its PARENT canon, and keeps it here. Nobody else ever
-- derives anything: a viewer that missed a version applies the author's own delta.
--
-- WHY IT IS ALSO THE SYNC. A requester names the canon it holds; a provider that has that canon in
-- its window sends the links from there to the newest -- a few tuples per changed row instead of
-- the whole bank -- and the receiver applies them in order and then PROVES the result by
-- recomputing the content hash against the newest canon (`Chain.Verify`). A mismatch, or a held
-- canon outside the window, falls back to the full snapshot exactly as today. So the same object is
-- the delta, the integrity check's input, and (step 4) the bank-log entry.
--
-- THE WINDOW IS THE LAST 25 VERSIONS PER BANKER -- Blizzard's per-tab number, because in this addon
-- a banker IS a tab (the operator: "we don't have one bank, we have 10s of bankers"), and the cap
-- must scale with the roster the way the inventory store already does. A quiet banker holds months,
-- a busy one holds days, and the busy one is the one whose recent history matters. Beyond it: a
-- full snapshot. ONE SavedVariables LINE per banker: the links are serialized once, at mint, and
-- joined with a separator AceSerializer can never emit, so the SV cost is one string, not a tree --
-- the operator's rule is the SV's size ("to the point that it can crash the game if it's too large"),
-- and 25 links of a few dozen bytes each are on the order of the banker's own record.
--
-- Wire-facing entry format, one per link:  <parent canon>\028<canon>\028<AceSerialized delta>
-- and the banker's line is those joined with \029. Both bytes are control characters, which
-- AceSerializer ALWAYS escapes inside a payload (SerializeStringHelper, `[%c \94\126\127]`), so
-- neither can occur inside a serialized delta and a split is exact.

TOGBankClassic_Inventory_Chain = {}
local Chain = TOGBankClassic_Inventory_Chain

local Record = TOGBankClassic_Inventory_Record

Chain.WINDOW    = 25
Chain.LINK_SEP  = "\029"   -- between links on a banker's line
Chain.FIELD_SEP = "\028"   -- parent \028 canon \028 body, inside a link

--- The DeltaSync options that make the engine diff V2 tuples correctly. `keyFunc` is the identity
--- the addon uses everywhere (id, suffix, enchant); `keyFields` names every field the key reads,
--- which the library checks at compute time -- a removal is reduced to its key fields on the wire and
--- re-keyed on apply, so a missing one would make deletions linger silently (the library's own
--- warning, LIBREQ-DS-006). Field 2 (count) is the only thing a `modified` entry can carry besides
--- the key, so a link is a few integers per changed row.
local ARRAY_OPTIONS = {
	keyFunc   = function(rec) return Record.key(rec) end,
	keyFields = { 1, 3, 4 },
	strictKeys = true,
}
local DELTA_OPTIONS = {
	arrayFields  = { "records" },
	scalarFields = { "money" },
	arrayOptions = { records = ARRAY_OPTIONS },
}
Chain.DELTA_OPTIONS = DELTA_OPTIONS

local function host()
	return TOGBankClassic_Core:DeltaHost()
end

--- The chains map for a guild, on the V2 SavedVariable beside the records it describes.
local function chains(guild, create)
	local Store = TOGBankClassic_Inventory_Store
	local g = Store and Store:GuildTable(guild, create)
	if not g then return nil end
	if create and not g.chains then g.chains = {} end
	return g.chains
end

--- Copy a record set so an apply never mutates the store's cached arrays or shared tuples.
local function copyRecords(records)
	local out = {}
	for i, rec in ipairs(records or {}) do
		local c = {}
		for k, v in pairs(rec) do c[k] = v end
		out[i] = c
	end
	return out
end

--- Split a banker's line into links: { { parent=, canon=, body= }, ... } oldest first.
function Chain:Links(guild, altName)
	local map = chains(guild, false)
	local line = map and map[altName]
	local out = {}
	if type(line) ~= "string" or line == "" then return out end
	for entry in (line .. self.LINK_SEP):gmatch("(.-)" .. self.LINK_SEP) do
		local parent, canon, body = entry:match("^(.-)" .. self.FIELD_SEP .. "(.-)" .. self.FIELD_SEP .. "(.*)$")
		if parent and canon and body then
			out[#out + 1] = { parent = parent, canon = canon, body = body }
		end
	end
	return out
end

local function joinLinks(links, from)
	local parts = {}
	for i = from or 1, #links do
		local l = links[i]
		parts[#parts + 1] = l.parent .. Chain.FIELD_SEP .. l.canon .. Chain.FIELD_SEP .. l.body
	end
	return table.concat(parts, Chain.LINK_SEP)
end

--- The serialized body carries ONLY what an apply needs: the `changes` table with its empty arrays
--- and the engine's zero metadata pruned. The canon and parent are the link's index fields, not
--- repeated inside the body, and the engine's `type`/`version`/`timestamp`/`hash` are constant or
--- zero here. Measured: a one-row count change was 209 bytes with all of it and is ~60 without --
--- the difference between a delta that beats a four-row snapshot and one that does not.
local function slim(delta)
	local out = { changes = {} }
	for field, change in pairs(delta.changes or {}) do
		if type(change) == "table" and (change.added or change.modified or change.removed) then
			local arr = {}
			if change.added    and #change.added    > 0 then arr.added    = change.added    end
			if change.modified and #change.modified > 0 then arr.modified = change.modified end
			if change.removed  and #change.removed  > 0 then arr.removed  = change.removed  end
			if next(arr) then out.changes[field] = arr end
		else
			out.changes[field] = change
		end
	end
	if delta.who then out.who = delta.who end
	if delta.log then out.log = delta.log end
	return out
end

--- Build one link: the delta from `before` to `after`, labelled. Returns the delta TABLE (for the
--- log and for specs) and the serialized body that is stored and shipped.
---@param before table { records=, money= } the version last published
---@param after table { records=, money= } the version being minted
---@param parentCanon string the canon of `before`
---@param canon string the canon of `after`
---@param who table|nil optional { to=, from= } annotations (step 4)
---@param log table|nil LOG-MAIL-001: the author's bank-log entries for this transition, packed
---       (Log:PackEntries) -- computed over what the banker HOLDS, so a receiver applies them
---       verbatim instead of diffing the full record sets (which carry the inbox rows)
---@return table delta, string body
function Chain:Compute(before, after, parentCanon, canon, who, log)
	local h = host()
	local delta = h:ComputeStructuredDelta(
		{ records = before.records or {}, money = before.money or 0 },
		{ records = after.records or {},  money = after.money or 0 },
		{ version = TOGBankClassic_DeltaComms:CanonPublishTime(canon) or 0 },
		DELTA_OPTIONS)
	delta.canon  = canon
	delta.parent = parentCanon
	if who then delta.who = who end
	if log then delta.log = log end
	local body = TOGBankClassic_Core:Serialize(slim(delta))
	return delta, body
end

--- LOG-MAIL-001: the window's bank-log entries, for a snapshot -- `{ { p = parent, c = canon, l =
--- packed }, ... }` oldest first, one per link that carries a log (the bodies are stored serialized,
--- so each is opened here; at most WINDOW of them, at send time). A receiver too far behind for the
--- chain still gets the author's entries for every version in the window (Log:ApplyWireLogs).
---@return table logs
function Chain:WireLogs(guild, altName)
	local out = {}
	for _, link in ipairs(self:Links(guild, altName)) do
		local ok, delta = TOGBankClassic_Core:Deserialize(link.body)
		if ok and type(delta) == "table" and type(delta.log) == "table" then
			out[#out + 1] = { p = link.parent, c = link.canon, l = delta.log }
		end
	end
	return out
end

--- Append links to the END of a banker's chain, dropping the oldest past the window. Two callers:
--- Record (the author's own link, first-hand) and the receive path in Inventory/Sync (the author's
--- links as they arrived, so a client that applied a chain can serve it onward -- a relay holds the
--- same links the author does, and the chain travels the mesh the way the data does).
---
--- The chain must CONNECT: the first new link's parent is the canon the chain currently ends at.
--- When it does not -- this client's copy of the banker jumped by a snapshot, or the chain was
--- cleared -- the old links describe versions this client's record has left behind, and they are
--- replaced rather than joined to; a Since() over a broken chain would serve links that do not
--- connect and every receiver would refuse them.
---@param links table array of { parent=, canon=, body= }, oldest first
---@return number held how many links the chain holds after the append
function Chain:Append(guild, altName, links)
	if type(links) ~= "table" or #links == 0 then return #self:Links(guild, altName) end
	local held = self:Links(guild, altName)
	local newest = held[#held] and held[#held].canon or nil
	if newest ~= nil and newest ~= links[1].parent then
		TOGBankClassic_Output:Debug("DELTA", "CHAIN",
			"[CHAIN] %s: chain ended at %s but the new links start from %s -- replacing it",
			altName, tostring(newest), tostring(links[1].parent))
		held = {}
	end
	for _, l in ipairs(links) do
		held[#held + 1] = { parent = l.parent, canon = l.canon, body = l.body }
	end
	local from = math.max(1, #held - self.WINDOW + 1)
	chains(guild, true)[altName] = joinLinks(held, from)
	return math.min(#held, self.WINDOW)
end

--- Record a link at the END of a banker's chain, dropping the oldest past the window. The one
--- production caller is Bank:MintVersion -- the author's own client, first-hand.
---@return table delta the link that was recorded
function Chain:Record(guild, altName, before, after, parentCanon, canon, who, log)
	local delta, body = self:Compute(before, after, parentCanon, canon, who, log)
	local held = self:Append(guild, altName, { { parent = parentCanon, canon = canon, body = body } })
	TOGBankClassic_Output:Debug("DELTA", "CHAIN",
		"[CHAIN] %s: link %s -> %s recorded (%d byte(s)), window holds %d",
		altName, tostring(parentCanon), tostring(canon), #body, held)
	return delta
end

--- The links AFTER `heldCanon`, oldest first, or nil when that canon is not in the window (the
--- requester is too far behind -- or has never held this banker -- and gets a full snapshot).
--- Holding the NEWEST canon answers an empty table: nothing to send.
---@return table|nil links array of { parent=, canon=, body= }
function Chain:Since(guild, altName, heldCanon)
	if type(heldCanon) ~= "string" then return nil end
	local links = self:Links(guild, altName)
	-- The newest canon is the last link's; every link's parent is the canon before it, so the
	-- oldest canon the window can serve FROM is the first link's parent.
	local start
	for i = #links, 1, -1 do
		if links[i].canon == heldCanon then start = i + 1 break end
		if links[i].parent == heldCanon then start = i break end
	end
	if not start then return nil end
	local out = {}
	for i = start, #links do out[#out + 1] = links[i] end
	return out
end

--- The canon the chain currently ends at, or nil for a banker with no chain.
function Chain:Newest(guild, altName)
	local links = self:Links(guild, altName)
	return links[#links] and links[#links].canon or nil
end

--- Apply one serialized link to a record set. Never mutates its inputs.
---@param records table the records held (the delta's parent version)
---@param money number
---@param body string the serialized delta
---@param link table|nil the link's index fields { parent=, canon= }, restored onto the delta
---@return table|nil newRecords, number newMoney, table|nil delta, string|nil err
function Chain:Apply(records, money, body, link)
	local ok, delta = TOGBankClassic_Core:Deserialize(body)
	if not ok or type(delta) ~= "table" or type(delta.changes) ~= "table" then
		return nil, money, nil, "link did not deserialize: " .. tostring(delta)
	end
	if link then delta.canon, delta.parent = link.canon, link.parent end
	local data = { records = copyRecords(records), money = money or 0 }
	local applied, err = host():ApplyStructuredDelta(data, delta, DELTA_OPTIONS)
	if not applied then return nil, money, delta, err end
	-- A modified entry re-keyed by the engine may carry only the changed fields; every row that
	-- survives must still be a whole tuple, and a row whose count reached zero is gone. Both are
	-- guaranteed by the engine (merge writes into the existing tuple; a removal drops the row), but
	-- a receiver applying a peer's link must not trust that -- validate before the hash check.
	local clean = {}
	for _, rec in ipairs(data.records) do
		if Record.isValid(rec) and Record.count(rec) > 0 then clean[#clean + 1] = rec end
	end
	return clean, data.money, delta, nil
end

--- Apply a whole chain in order and PROVE the result: the content hash of what the chain produced
--- must equal the content half of the newest link's canon. The canon is the author's own statement
--- of what its records hashed to (Bank:MintVersion); a chain that reproduces it is exact by
--- construction, and one that does not is refused whole -- the caller falls back to a snapshot.
---
--- THE DELTA RELEASE step 4: the fifth return is the chain as STEPS -- for each link, the record set
--- and money before and after it, and the delta it carried (with the author's `who`). A receiver
--- logs one version transition per step, stamped with that link's canon time, so its log matches the
--- author's row for row rather than showing the net of the whole chain at the newest time. Handed
--- back only when the whole chain verified: a chain refused whole logs nothing.
---@param records table held records (at the first link's parent)
---@param money number
---@param links table array of { parent=, canon=, body= } oldest first
---@return table|nil records, number|nil money, string|nil canon, string|nil err, table|nil steps
function Chain:ApplyAll(records, money, links)
	local cur, curMoney = records, money
	local last
	local steps = {}
	for i, link in ipairs(links) do
		if last and link.parent ~= last then
			return nil, nil, nil, string.format("link %d expects parent %s but the chain is at %s", i, tostring(link.parent), tostring(last))
		end
		local nextRecords, nextMoney, delta, err = self:Apply(cur, curMoney, link.body, link)
		if not nextRecords then return nil, nil, nil, string.format("link %d: %s", i, tostring(err)) end
		steps[#steps + 1] = { link = link, delta = delta, before = cur, moneyBefore = curMoney, after = nextRecords, moneyAfter = nextMoney }
		cur, curMoney, last = nextRecords, nextMoney, link.canon
	end
	if not last then return records, money, nil, "empty chain" end
	if not self:Verify(cur, curMoney, last) then
		return nil, nil, nil, "content hash after the chain does not match canon " .. tostring(last)
	end
	return cur, curMoney, last, nil, steps
end

--- Does this record set hash to the content half of `canon`? The check that makes a received chain
--- trustworthy: same hash function, same shape (V2 records), same author-minted number.
function Chain:Verify(records, money, canon)
	if type(canon) ~= "string" or #canon ~= 20 then return false end
	local content = TOGBankClassic_Core:ComputeInventoryHash(records, nil, nil, money or 0)
	return string.format("%010d", tonumber(content) or -1) == canon:sub(11)
end

--- Drop a banker's chain (the banker left, or a wipe).
function Chain:Clear(guild, altName)
	local map = chains(guild, false)
	if map then map[altName] = nil end
end
