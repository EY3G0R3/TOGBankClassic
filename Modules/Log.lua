-- Modules/Log.lua
-- LOGAPI-001: the "bank log" API. The operator, 2026-08-17: "create a 'log' API to allow TOGTools
-- to pull data for the bank log" -- and on the shape, 2026-09-11: "it should work like the in game
-- bank log". The in-game guild bank log (Blizzard_GuildBankUI.lua, GetGuildBankTransaction) is a
-- list of TRANSACTIONS -- "Name deposited [Item] x20, 3 days ago" -- newest first, one per thing
-- that happened. So this is a transaction FEED, recorded as things happen, not a view derived
-- from the current state (which cannot say what moved, only what is there).
--
-- A SMALL, CAPPED BUFFER IS PERSISTED; THE HISTORY IS NOT. The operator's first rule: "the log can't
-- persist, i don't want to use SV space on it, why it needs to integrate with TOGTools, who will
-- persist it" -- amended on 2026-09-12, on a Log tab empty after /reload: "some small amount of the
-- bank log to persist in TOGBank, but not a lot" (LOG-PERSIST-001, at MAX_ENTRIES). So entries are
-- PUSHED to registered consumers as they are recorded (`RegisterCallback`), and the capped buffer --
-- the last MAX_ENTRIES per guild, saved on the account -- holds recent entries for the Log tab and
-- for a consumer that registers late (`GetEntries`). Beyond the cap, the consumer is the one that
-- stores.
--
-- A READ-ONLY, VERSIONED surface for other addons. Nothing here is on the wire and a consumer that
-- only ever calls this table cannot be broken by the internals moving (TOGProfessionMaster reads
-- `TOGBankClassic_Guild.Info.alts[...].items` directly and has read stale data since the V2 store
-- arrived -- the failure this file exists to prevent for the next consumer).
--
-- WHERE ENTRIES COME FROM. Every client records the SAME entries from the SAME transitions, so the
-- log agrees across the guild without a wire change:
--   * A banker's contents: each new VERSION of a bank -- the banker's own scan, or a delivery a
--     viewer receives -- is diffed against the version held before it. A count that rose is a
--     `deposit`, one that fell a `withdraw`, money likewise (`money-deposit` / `money-withdraw`).
--     Stamped with the AUTHOR's publish time (the front of the canon, HASH-CANON-005), so a viewer
--     and the banker log the identical entry. A client that missed intermediate versions logs the
--     net change at the later time -- true, if coarser.
--   * Requests: every mutation, local or received, is a transition from the record held before to
--     the record after: `requested`, `mailed` (the Sent count rose by n), `handed` (marked done by
--     hand), `cancelled` (the reason is the note), `reopened`. Delta-based, so a mutation applied
--     twice -- our own broadcast echoed back -- records nothing the second time.
--
-- Entries are newest first. Every call returns a fresh table; a consumer may keep or mutate it.

TOGBankClassic_Log = {}
local Log = TOGBankClassic_Log

-- LOG-DEBUG-001: the operator, watching "the bank data from the banker hasn't been sent to galdof",
-- asked "is there debugging for the new log sync? is it exposed as a type in the debug tab so i can
-- select it so we can watch just it" -- there was not: the only lines were failures under
-- SYNC/LOGAPI. Every line here goes under the LOG category (Debug tab row of its own), tagged
-- RECORD (what was recorded and why), DELIVER (what went out, to whom, and what TOGTools said) or
-- FAIL (a consumer threw). Output is read at call time: Log loads before Output's consumers exist.
local function debug(tag, fmt, ...)
	local Output = TOGBankClassic_Output
	if Output and Output.Debug then Output:Debug("LOG", tag, fmt, ...) end
end

--- Bump when a field is renamed or removed, or an entry type changes meaning. Adding a field or a
--- type does not bump it; consumers must tolerate fields and types they do not know.
Log.API_VERSION = 1

--- Every entry type this version can emit. A consumer filters with `types = { mailed = true }`.
---   deposit / withdraw           name=banker, item, itemID, suffixID, count
---                                plus, when the banker's client knew it (section 3.6 of
---                                docs/DELTA_RELEASE.md): `to` = the requester a withdrawal was
---                                mailed or handed to; `from` = the member whose mail a deposit
---                                arrived in. Absent for a trade, a vendor, a bag shuffle.
---   money-deposit / money-withdraw  name=banker, money (copper)
--- Every bank-contents entry also carries:
---   fromCanon / toCanon          the version diffed FROM and TO (nil when the older copy had none).
---                                A reader can tell a span from a single event: when an entry's
---                                fromCanon is not the previous entry's toCanon for that banker, a
---                                version was missed in between (a delivery that decoded with
---                                dropped rows is stored but never logged) and this entry is the
---                                NET change across both.
---   firstThisSession = true      on the first diff for that banker since login. Its "before" is
---                                the copy this client held when it last looked, so the entry is
---                                "since you last looked", not a deposit at that instant.
---   requested                    name=requester, to=banker, item, count, requestId
---   mailed / handed              name=banker, to=requester, item, count (this transaction's), requestId
---   cancelled                    name=banker, to=requester, item, requestId, note (the reason)
---   reopened                     name=banker, to=requester, item, requestId
Log.TYPES = {
	deposit = true, withdraw = true, ["money-deposit"] = true, ["money-withdraw"] = true,
	requested = true, mailed = true, handed = true, cancelled = true, reopened = true,
}

--- The buffer's cap; the oldest go first. A consumer that wants more than this keeps its own store
--- and registers a callback.
---
--- LOG-PERSIST-001: THE BUFFER IS SAVED, SMALL. The header above says nothing is persisted, and
--- that was the operator's rule when the API was designed. On seeing the Log tab empty after a
--- /reload (2026-09-12): "i think we do need some small amount of the bank log to persist in
--- TOGBank, but not a lot. we need to ensure it's getting passed around." So the buffer lives on
--- the V2 SavedVariable's guild table (`<guild>.log`, beside the delta chain that already keeps
--- the last 25 versions per banker) and the cap is what bounds it: 250 entries of ~100 bytes is
--- ~25 KB per guild, the order of one banker's record. "Passed around" is unchanged and needs no
--- wire of its own: every client records the same entries from the same transitions -- a version's
--- chain link or snapshot, a request mutation -- so what a client missed while offline arrives as
--- the sync it was always going to do. TOGTools remains the long history.
Log.MAX_ENTRIES = 250

--- The AceEvent message fired after a batch of entries (see Notify). Any AceEvent-3.0 embed can
--- `RegisterMessage("TOGBANK_LOG_CHANGED", handler)`; the handler gets the message name and the
--- same array of new entries the callbacks get.
Log.MESSAGE = "TOGBANK_LOG_CHANGED"

-- Coalescing window: a fulfil of three orders, or a scan that moved forty items, is one delivery.
local NOTIFY_DELAY = 0.2

-- ─── The session buffer ──────────────────────────────────────────────────────

--- Keyed by guild so a character that swaps guilds does not carry the other guild's entries.
--- LOG-PERSIST-001: the buffer IS the store's `g.log` table when the store is up, read from the
--- store on EVERY call and never cached here. `Log.buffers` holds ONLY entries recorded before
--- Store:Init (this module loads first; a bare spec has no store at all) -- the one thing the
--- move-once below exists for.
---
--- LOG-WIPE-001 (Peer Review db06c629, 2026-09-13): the first cut cached the store's table too, and
--- nothing in production ever cleared the cache -- so after `/togbank wipe` replaced the guild
--- table, the next call found `log ~= g.log`, copied EVERY cached entry into the fresh table, and
--- the wiped log came back from the session cache. Reading `g.log` fresh each call (GuildTable is a
--- hash lookup) makes a wipe take effect by construction; the merge only ever moves pre-store
--- entries, once.
Log.buffers = {}

local function buffer(create)
	local G = TOGBankClassic_Guild
	local guild = G and G.Info and G.Info.name
	if not guild then return nil end
	local pending = Log.buffers[guild]
	local Store = TOGBankClassic_Inventory_Store
	local g = Store and Store.GuildTable and Store:GuildTable(guild, create or pending ~= nil)
	if g then
		if not g.log and (create or pending) then g.log = {} end
		if pending and g.log then
			for _, e in ipairs(pending) do g.log[#g.log + 1] = e end
			Log.buffers[guild] = nil
		end
		return g.log
	end
	if not pending and create then
		pending = {}
		Log.buffers[guild] = pending
	end
	return pending
end

--- Append one entry to the session buffer (pruned to MAX_ENTRIES) and queue it for delivery.
---@param entry table
---@return boolean appended
function Log:Append(entry)
	local log = buffer(true)
	if not log or type(entry) ~= "table" or not entry.type or not entry.ts then
		debug("RECORD", "entry refused: %s (guild %s, type %s, ts %s)",
			not log and "no guild" or "malformed", tostring(TOGBankClassic_Guild and TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name),
			tostring(type(entry) == "table" and entry.type), tostring(type(entry) == "table" and entry.ts))
		return false
	end
	log[#log + 1] = entry
	debug("RECORD", "%s: %s%s%s x%s @%s%s", tostring(entry.type), tostring(entry.name),
		entry.to and (" -> " .. tostring(entry.to)) or "", entry.from and (" <- " .. tostring(entry.from)) or "",
		tostring(entry.count or entry.money or 0), tostring(entry.ts),
		entry.item and (" " .. tostring(entry.item)) or "")
	if #log > self.MAX_ENTRIES then
		table.sort(log, function(a, b) return a.ts < b.ts end)
		local excess = #log - self.MAX_ENTRIES
		for _ = 1, excess do table.remove(log, 1) end
	end
	self:Notify(entry)
	return true
end

-- ─── Recording: bank contents ────────────────────────────────────────────────

--- A flat, aggregated array of rows in either shape the addon holds -- V2 tuple records (Record)
--- or legacy `{ ID, Count, Link }` rows -- reduced to id+suffix -> count.
local function countsByKey(rows)
	local Record, Item = TOGBankClassic_Inventory_Record, TOGBankClassic_Item
	local out = {}
	for _, row in ipairs(rows or {}) do
		local id, count, suffix
		if type(row) == "table" and row.ID then
			id, count = tonumber(row.ID), tonumber(row.Count) or 0
			suffix = Item and Item.RowSuffixID and Item:RowSuffixID(row) or 0
		elseif Record and Record.isValid(row) then
			id, count, suffix = Record.id(row), Record.count(row), Record.suffix(row)
		end
		if id and count > 0 then
			local key = id .. ":" .. (suffix or 0)
			local e = out[key]
			if e then e.count = e.count + count
			else out[key] = { id = id, suffix = (suffix and suffix ~= 0) and suffix or nil, count = count } end
		end
	end
	return out
end

local function itemName(id, suffix)
	local Item = TOGBankClassic_Item
	if Item and Item.RequestDisplayName then
		return Item:RequestDisplayName({ item = "Item " .. id, itemID = id, suffixID = suffix })
	end
	return "Item " .. id
end

--- A banker's contents moved from `before` to `after` (either row shape, see countsByKey), money
--- from `moneyBefore` to `moneyAfter`, published at `ts`. Records one entry per item whose count
--- changed and one for money. Nothing is recorded for the FIRST version held (there is no before
--- to diff against -- a fresh install must not log a whole bank as a deposit).
---
--- THE "WHO" (THE DELTA RELEASE step 4, docs/DELTA_RELEASE.md section 3.6). Blizzard's log says who
--- deposited; ours has no shared tab, so every movement is a mail or a hand-off WITH a member, and
--- the banker's client knows the member on both sides: a withdrawal by fulfilment is a `mailed` /
--- `handed` request event (-> `to` = the requester), a deposit by mail is an inbox row whose sender
--- the mailbox scan saw (-> `from` = the sender). `who` is that knowledge, keyed like countsByKey
--- (`id:suffix`), each key an array of { count=, to= } or { count=, from= } parts. It is derived ONCE,
--- by the author at mint (AttributeChanges), rides inside the chain link (Chain:Compute's `who`), and
--- every receiver applies it here verbatim -- so a viewer's entry carries the same `to` as the
--- banker's and nobody derives it twice. A key with parts is split into one entry per part; a
--- remainder the parts do not account for is one plain entry; parts that claim MORE than moved are
--- ignored whole (the two records disagree and a wrong attribution is worse than none).
---@param bank string normalized banker name
---@param before table|nil rows held before, nil when none were held
---@param after table rows now held
---@param moneyBefore number|nil
---@param moneyAfter number|nil
---@param ts number the author's publish time
---@param fromCanon string|nil the version `before` was, if it had one
---@param toCanon string|nil the version `after` is
---@param who table|nil attributions, see above
---@return number recorded
function Log:RecordInventoryChange(bank, before, after, moneyBefore, moneyAfter, ts, fromCanon, toCanon, who)
	if not bank or not ts or ts <= 0 or before == nil then
		debug("RECORD", "inventory change for %s NOT diffed: %s (ts %s, from %s, to %s)", tostring(bank),
			before == nil and "no earlier copy held (first version -- nothing to diff against)"
				or (not ts or ts <= 0) and "no publish time" or "no banker name",
			tostring(ts), tostring(fromCanon), tostring(toCanon))
		return 0
	end
	debug("RECORD", "diffing %s: %d -> %d rows, money %s -> %s, version %s -> %s, who=%s",
		tostring(bank), #(before or {}), #(after or {}), tostring(moneyBefore), tostring(moneyAfter),
		tostring(fromCanon), tostring(toCanon), who and "attributed" or "none")
	return self:RecordEntries(bank, self:DiffEntries(bank, before, after, moneyBefore, moneyAfter, who), ts, fromCanon, toCanon)
end

--- LOG-MAIL-001: THE DIFF, as unstamped entries -- what moved between two record sets, one entry
--- per item whose count changed (split by `who` as RecordInventoryChange describes) and one for
--- money. The author computes this ONCE at mint over what the banker HOLDS (bags + bank, not the
--- inbox -- Store:GetAltHeldRecords), ships it in the chain link and the snapshot (PackEntries),
--- and every receiver appends it verbatim (RecordEntries) -- so a mail sitting unopened in the
--- banker's inbox is a deposit for nobody until the banker takes it. The operator: "the log should
--- only show the 'deposit' when it's taken from the mail, not when it's scanned in the inbox. it
--- may sit there and be sent back." Pure: touches nothing.
---@return table entries array of { type=, name=, item=, itemID=, suffixID=, count= | money=, to=, from= }
function Log:DiffEntries(bank, before, after, moneyBefore, moneyAfter, who)
	local entries = {}
	if not bank or before == nil then return entries end
	local was, now = countsByKey(before), countsByKey(after)
	local keys = {}
	for k in pairs(was) do keys[#keys + 1] = k end
	for k in pairs(now) do if not was[k] then keys[#keys + 1] = k end end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local b, a = was[k], now[k]
		local delta = (a and a.count or 0) - (b and b.count or 0)
		if delta ~= 0 then
			local ref = a or b
			local kind = delta > 0 and "deposit" or "withdraw"
			local function entry(count, part)
				local e = {
					type = kind, name = bank,
					item = itemName(ref.id, ref.suffix), itemID = ref.id, suffixID = ref.suffix,
					count = count,
				}
				if part then
					if kind == "withdraw" and part.to then e.to = part.to end
					if kind == "deposit" and part.from then e.from = part.from end
				end
				entries[#entries + 1] = e
			end
			local parts = type(who) == "table" and who[k] or nil
			local claimed = 0
			for _, p in ipairs(type(parts) == "table" and parts or {}) do claimed = claimed + (tonumber(p.count) or 0) end
			if type(parts) == "table" and claimed > 0 and claimed <= math.abs(delta) then
				for _, p in ipairs(parts) do
					if (tonumber(p.count) or 0) > 0 then entry(tonumber(p.count), p) end
				end
				if math.abs(delta) - claimed > 0 then entry(math.abs(delta) - claimed) end
			else
				entry(math.abs(delta))
			end
		end
	end
	local mb, ma = tonumber(moneyBefore), tonumber(moneyAfter)
	if mb and ma and ma ~= mb then
		entries[#entries + 1] = {
			type = ma > mb and "money-deposit" or "money-withdraw", name = bank,
			money = math.abs(ma - mb),
		}
	end
	return entries
end

--- Append the entries of ONE version transition, stamped with its publish time and the two canons.
--- The first transition recorded for a banker this session is marked (`firstThisSession`: "since
--- you last looked"); marked even when the list is empty, so the mark is not spent on nothing.
---@param bank string
---@param entries table from DiffEntries or UnpackEntries
---@param ts number the author's publish time
---@return number recorded
function Log:RecordEntries(bank, entries, ts, fromCanon, toCanon)
	if not bank or not ts or ts <= 0 then return 0 end
	self.diffedThisSession = self.diffedThisSession or {}
	local first = not self.diffedThisSession[bank]
	local recorded = 0
	for _, src in ipairs(entries or {}) do
		local e = {}
		for k, v in pairs(src) do e[k] = v end
		e.ts, e.name = ts, bank
		e.fromCanon, e.toCanon = fromCanon, toCanon
		if first then e.firstThisSession = true end
		self:Append(e)
		recorded = recorded + 1
	end
	self.diffedThisSession[bank] = true
	debug("RECORD", "%s: %d entr%s recorded%s", tostring(bank), recorded, recorded == 1 and "y" or "ies",
		first and " (first diff this session -- 'since you last looked')" or "")
	return recorded
end

-- The wire spelling of an entry: one letter per field, the item name left out (a receiver
-- resolves it from the id, as itemName does here). `t`: d = deposit, w = withdraw, D / W = money.
local PACK_TYPE   = { deposit = "d", withdraw = "w", ["money-deposit"] = "D", ["money-withdraw"] = "W" }
local UNPACK_TYPE = { d = "deposit", w = "withdraw", D = "money-deposit", W = "money-withdraw" }

--- Entries -> the compact array a chain link or snapshot carries. nil for none (nothing on the wire).
---@param entries table|nil
---@return table|nil packed
function Log:PackEntries(entries)
	if type(entries) ~= "table" or #entries == 0 then return nil end
	local out = {}
	for _, e in ipairs(entries) do
		local t = PACK_TYPE[e.type]
		if t then
			local p = { t = t }
			if e.itemID then p.i = e.itemID end
			if e.suffixID and e.suffixID ~= 0 then p.s = e.suffixID end
			if e.count then p.c = e.count end
			if e.money then p.m = e.money end
			if e.to then p.to = e.to end
			if e.from then p.from = e.from end
			out[#out + 1] = p
		end
	end
	return #out > 0 and out or nil
end

--- The compact wire array -> entries for `bank`, each validated field by field: a malformed element
--- from a peer is dropped, never appended half-read.
---@param packed table|nil
---@param bank string
---@return table entries
function Log:UnpackEntries(packed, bank)
	local out = {}
	for _, p in ipairs(type(packed) == "table" and packed or {}) do
		local kind = type(p) == "table" and UNPACK_TYPE[p.t] or nil
		if kind == "deposit" or kind == "withdraw" then
			local id, count = tonumber(p.i), tonumber(p.c)
			if id and count and count > 0 then
				local suffix = tonumber(p.s)
				if suffix == 0 then suffix = nil end
				local e = { type = kind, name = bank, item = itemName(id, suffix), itemID = id, suffixID = suffix, count = count }
				if kind == "withdraw" and type(p.to) == "string" then e.to = p.to end
				if kind == "deposit" and type(p.from) == "string" then e.from = p.from end
				out[#out + 1] = e
			end
		elseif kind then
			local money = tonumber(p.m)
			if money and money > 0 then out[#out + 1] = { type = kind, name = bank, money = money } end
		end
	end
	return out
end

--- A snapshot's log: the author's (or a relay's) chain window as `{ { p = parent, c = canon, l =
--- packed }, ... }`, oldest first. Apply the transitions this client has NOT seen -- every link whose
--- canon was published after `heldAt`, the publish time of the version held before the snapshot --
--- stamped with that link's own time. A client too far behind for the window gets the window's
--- entries and nothing for the gap before it (coarser, as a missed version always was); a client
--- with no earlier copy (`heldAt` nil) logs nothing, exactly as a first delivery never did.
---@param bank string
---@param logs table|nil
---@param heldAt number|nil publish time of the canon held before this delivery
---@return number recorded
function Log:ApplyWireLogs(bank, logs, heldAt)
	if not bank or not heldAt or type(logs) ~= "table" then return 0 end
	local DC = TOGBankClassic_DeltaComms
	local recorded = 0
	for _, l in ipairs(logs) do
		local canon = type(l) == "table" and l.c or nil
		local at = type(canon) == "string" and DC:CanonPublishTime(canon) or nil
		if at and at > heldAt then
			recorded = recorded + self:RecordEntries(bank, self:UnpackEntries(l.l, bank), at, l.p, canon)
		end
	end
	return recorded
end

--- THE AUTHOR'S SIDE OF THE "WHO": what the banker's own client knows about who moved what, for
--- the version it is about to mint. Called by Bank:MintVersion; the result rides in the chain link
--- and is applied by RecordInventoryChange on every client, this one included.
---
---   * Withdrawals: the `mailed` / `handed` request events this client recorded for `bank` since
---     the last version was minted -- each one names the requester (`to`) and the count. They are
---     matched to a key whose count FELL, and consumed, so the next version cannot claim them again.
---   * Deposits: `mailSenders` -- { key -> { sender -> count } } of what LEFT the inbox since the
---     last mint (MailInventory:TakenSenders: an attachment seen in one inbox read and gone from
---     the next was taken, or returned) -- for a key whose HELD count ROSE. LOG-MAIL-001: the take
---     is the deposit, not the arrival; `before`/`after` are the held sets (bags + bank), so a mail
---     still sitting in the inbox moves nothing here and attributes nothing.
---
--- Only what is known is attributed; a movement with no event behind it (a trade, a vendor, a bag
--- shuffle) stays a plain deposit/withdraw. Nothing is invented: a requester is named only from a
--- recorded fill, a sender only from a read inbox. KNOWN COST, stated: an attachment RETURNED to
--- its sender also left the inbox, so if the same item then rises by another route before the
--- mint, up to that count is credited to the returned mail's sender.
---@param bank string normalized banker name (this client's own character)
---@param before table|nil rows held before
---@param after table rows now held
---@param mailSenders table|nil { ["id:suffix"] = { [sender] = count } } taken from the inbox since the last mint
---@return table|nil who nil when nothing could be attributed
function Log:AttributeChanges(bank, before, after, mailSenders)
	if not bank or before == nil then return nil end
	local was, now = countsByKey(before), countsByKey(after)
	local who = {}
	local any = false
	local log = buffer(false) or {}
	-- Fills already claimed by an earlier version, kept OFF the entries so a consumer's copy never
	-- carries bookkeeping (weak keys: an entry pruned from the buffer is forgotten here too).
	self.attributed = self.attributed or setmetatable({}, { __mode = "k" })
	local claimedFills = self.attributed
	for k, a in pairs(now) do
		local b = was[k]
		local delta = a.count - (b and b.count or 0)
		if delta > 0 and type(mailSenders) == "table" and type(mailSenders[k]) == "table" then
			local parts, senders = {}, {}
			for sender in pairs(mailSenders[k]) do senders[#senders + 1] = sender end
			table.sort(senders)
			for _, sender in ipairs(senders) do
				local n = tonumber(mailSenders[k][sender]) or 0
				if n > 0 then parts[#parts + 1] = { count = math.min(n, delta), from = sender } end
			end
			if #parts > 0 then who[k] = parts; any = true end
		end
	end
	for k, b in pairs(was) do
		local a = now[k]
		local delta = (a and a.count or 0) - b.count
		if delta < 0 then
			local byRequester, order = {}, {}
			for _, e in ipairs(log) do
				if (e.type == "mailed" or e.type == "handed") and e.name == bank and not claimedFills[e]
						and e.itemID == b.id and (e.suffixID or 0) == (b.suffix or 0) and (tonumber(e.count) or 0) > 0 then
					claimedFills[e] = true
					if not byRequester[e.to] then order[#order + 1] = e.to; byRequester[e.to] = 0 end
					byRequester[e.to] = byRequester[e.to] + e.count
				end
			end
			if #order > 0 then
				table.sort(order)
				local parts = {}
				for _, to in ipairs(order) do parts[#parts + 1] = { count = byRequester[to], to = to } end
				who[k] = parts; any = true
			end
		end
	end
	return any and who or nil
end

-- ─── Recording: requests ─────────────────────────────────────────────────────

local function requestEntry(req, ts, entryType, extra)
	local Item = TOGBankClassic_Item
	local e = {
		ts = ts, type = entryType, name = req.bank, to = req.requester,
		item = Item and Item.RequestDisplayName and Item:RequestDisplayName(req) or req.item,
		itemID = req.itemID, suffixID = req.suffixID, requestId = req.id,
	}
	for k, v in pairs(extra or {}) do e[k] = v end
	return e
end

--- A request went from `before` (nil when it did not exist here) to `after`. Records what
--- changed and nothing else, so the same transition applied twice records nothing twice.
---@param before table|nil
---@param after table
---@return number recorded
function Log:RecordRequestTransition(before, after)
	if type(after) ~= "table" or not after.id then return 0 end
	local recorded = 0
	local at = tonumber(after.updatedAt) or tonumber(after.date) or 0
	local fBefore = before and (tonumber(before.fulfilled) or 0) or 0
	local fAfter = tonumber(after.fulfilled) or 0
	local sBefore = before and before.status or nil
	local sAfter = after.status or "open"
	-- "Done" as ReopenRequest defines it: a terminal status, or every unit sent.
	local qBefore = before and (tonumber(before.quantity) or 0) or 0
	local wasDone = before ~= nil and (sBefore == "cancelled" or sBefore == "complete" or sBefore == "fulfilled"
		or (qBefore > 0 and fBefore >= qBefore))

	if not before then
		local e = requestEntry(after, tonumber(after.date) or at, "requested",
			{ name = after.requester, to = after.bank, count = tonumber(after.quantity) or 0 })
		self:Append(e)
		recorded = recorded + 1
	end
	if fAfter > fBefore then
		-- Marked done by hand ("complete") is a hand-off; a rising Sent count otherwise is mail.
		local kind = (sAfter == "complete" and sBefore ~= "complete") and "handed" or "mailed"
		self:Append(requestEntry(after, at, kind, { count = fAfter - fBefore }))
		recorded = recorded + 1
	end
	if sAfter == "cancelled" and sBefore ~= "cancelled" then
		local note = (after.notes ~= nil and after.notes ~= "") and after.notes or nil
		self:Append(requestEntry(after, at, "cancelled", { note = note }))
		recorded = recorded + 1
	elseif sAfter == "complete" and sBefore ~= "complete" and fAfter <= fBefore then
		-- Completed without a new hand-off count (already fully sent, then closed).
		self:Append(requestEntry(after, at, "handed", { count = 0 }))
		recorded = recorded + 1
	elseif wasDone and sAfter == "open" then
		-- REOPEN-001 is the only way a finished order legitimately goes back to open. Decided on the
		-- STATE transition, not on reopenedAt rising: a reopen inside the same server second as the
		-- one it undoes would otherwise vanish from the log.
		self:Append(requestEntry(after, tonumber(after.reopenedAt) or at, "reopened"))
		recorded = recorded + 1
	end
	if recorded == 0 then
		-- The common no-op: our own broadcast echoed back, or a mutation that moved no logged field.
		debug("RECORD", "request %s (%s -> %s, sent %d -> %d): nothing new to log",
			tostring(after.id), tostring(sBefore), tostring(sAfter), fBefore, fAfter)
	end
	return recorded
end

-- ─── Reading ─────────────────────────────────────────────────────────────────

--- Ordering: newest first; ties broken so the order is reproducible.
local function newestFirst(a, b)
	if a.ts ~= b.ts then return a.ts > b.ts end
	if a.type ~= b.type then return a.type < b.type end
	return tostring(a.requestId or a.itemID or a.name) < tostring(b.requestId or b.itemID or b.name)
end

local function copyEntry(e)
	local c = {}
	for k, v in pairs(e) do c[k] = v end
	return c
end

local function passes(entry, opts)
	if opts.since and entry.ts <= opts.since then return false end
	if opts.types and not opts.types[entry.type] then return false end
	if opts.bank and entry.name ~= opts.bank and entry.to ~= opts.bank then return false end
	if opts.player and entry.name ~= opts.player and entry.to ~= opts.player then return false end
	return true
end

--- The recent entries for the current guild, newest first. Never nil. THIS IS NOT THE HISTORY --
--- it is the capped buffer (the last MAX_ENTRIES, persisted per LOG-PERSIST-001), for the Log tab
--- and for a consumer that registered late; the consumer's own store is the history.
---@param opts table|nil { since = serverTime, limit = n, types = { [type] = true }, bank = "Name-Realm", player = "Name-Realm" }
---@return table entries  copies; a consumer may keep or mutate them
function Log:GetEntries(opts)
	opts = opts or {}
	local G = TOGBankClassic_Guild
	local out = {}
	local log = buffer(false)
	if not log then return out end
	if opts.bank then opts.bank = G:NormalizeName(opts.bank) or opts.bank end
	if opts.player then opts.player = G:NormalizeName(opts.player) or opts.player end
	for _, e in ipairs(log) do
		if passes(e, opts) then out[#out + 1] = copyEntry(e) end
	end
	table.sort(out, newestFirst)
	local limit = tonumber(opts.limit)
	if limit and limit >= 0 and #out > limit then
		for i = #out, limit + 1, -1 do out[i] = nil end
	end
	return out
end

--- The guild's bank characters as this client knows them, A->Z. Never nil.
--- `number` is the P2P-035 banker number or nil while unnumbered; `lastScanned` is the publish
--- time of the copy we hold, or nil for a pre-canon copy; `state` is the Inventory tab's word for
--- how current our copy is ("current", "behind", "offered", "v1", "none").
---@return table bankers  array of { name, number, lastScanned, state, viewOnly }
function Log:GetBankers()
	local G = TOGBankClassic_Guild
	local out = {}
	if not (G and G.Info and G.GetBanks) then return out end
	local BN, DC = TOGBankClassic_BankerNumbers, TOGBankClassic_DeltaComms
	for _, name in ipairs(G:GetBanks() or {}) do
		local norm = G:NormalizeName(name) or name
		local alt = G.Info.alts and G.Info.alts[norm]
		out[#out + 1] = {
			name        = norm,
			number      = BN and BN:NumberOf(norm) or nil,
			lastScanned = alt and DC and DC:CanonPublishTime(alt.inventoryHashV2) or nil,
			state       = G.GetAltStaleness and (G:GetAltStaleness(norm)) or nil,
			viewOnly    = G.IsViewOnlyBank and G:IsViewOnlyBank(norm) or false,
		}
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

-- ─── Change notification ─────────────────────────────────────────────────────

Log.callbacks = {}

--- Receive entries as they are recorded. `fn(entries)` is called once per coalesced batch with an
--- array of NEW entries, oldest first, each a fresh copy the consumer may keep -- this is the
--- feed a consumer persists. One callback per owner; a second registration for the same owner
--- replaces the first. Register early: what was recorded before registering is only in the
--- session buffer (`GetEntries`).
---
--- CALLBACKS RUN FROM A TIMER, NEVER FROM A HARDWARE EVENT (peer review round 19). Delivery is
--- coalesced through C_Timer.After, so anything the client gates on a click -- sending a chat
--- line, casting, taking mail, SendMail -- is ADDON_ACTION_BLOCKED inside a callback. Store the
--- entries and repaint; do the gated thing from your own click handler.
---@param owner any a key identifying the consumer (its addon table, or a string)
---@param fn function
function Log:RegisterCallback(owner, fn)
	if owner == nil or type(fn) ~= "function" then return false end
	self.callbacks[owner] = fn
	return true
end

function Log:UnregisterCallback(owner)
	if owner == nil then return false end
	local had = self.callbacks[owner] ~= nil
	self.callbacks[owner] = nil
	return had
end

--- Queue an entry for delivery. Coalesces: every entry recorded inside NOTIFY_DELAY goes out in
--- one batch. `pending` is the latch (TIMER-002: C_Timer.After returns nothing, so the latch is
--- a flag, not a handle).
---@param entry table
function Log:Notify(entry)
	self.pendingEntries = self.pendingEntries or {}
	self.pendingEntries[#self.pendingEntries + 1] = entry
	if self.pending then return end
	self.pending = true
	C_Timer.After(NOTIFY_DELAY, function()
		Log.pending = nil
		local batch = Log.pendingEntries or {}
		Log.pendingEntries = nil
		Log:Deliver(batch)
	end)
end

--- Deliver a batch to every consumer. Each consumer gets its OWN copies (a consumer that stores
--- the table it was handed must not be able to alter another's), and each callback runs in its
--- own pcall so one consumer's error cannot silence the others or take TOGBank down; the error
--- is routed to the client's handler.
---@param batch table array of entries, oldest first
function Log:Deliver(batch)
	if #batch == 0 then return end
	local consumers = 0
	for owner, fn in pairs(self.callbacks) do
		consumers = consumers + 1
		local copies = {}
		for i, e in ipairs(batch) do copies[i] = copyEntry(e) end
		local ok, err = pcall(fn, copies)
		if not ok then
			debug("FAIL", "log callback for %s failed: %s", tostring(owner), tostring(err))
			if geterrorhandler then geterrorhandler()(err) end
		end
	end
	debug("DELIVER", "batch of %d entr%s to %d callback%s + %s", #batch, #batch == 1 and "y" or "ies",
		consumers, consumers == 1 and "" or "s", self.MESSAGE)
	if TOGBankClassic_Events and TOGBankClassic_Events.SendMessage then
		local copies = {}
		for i, e in ipairs(batch) do copies[i] = copyEntry(e) end
		TOGBankClassic_Events:SendMessage(self.MESSAGE, copies)
	end
	-- LOGAPI-002: TOGTools, when installed, is pushed to directly (see the bridge below). In its own
	-- pcall for the same reason as every other consumer.
	local ok, stored, why = pcall(self.PushToTOGTools, self, batch)
	if not ok then
		debug("FAIL", "TOGTools bridge failed: %s", tostring(stored))
		if geterrorhandler then geterrorhandler()(stored) end
	else
		debug("DELIVER", "TOGTools: %d row%s stored, %s", tonumber(stored) or 0, stored == 1 and "" or "s", tostring(why))
	end
end

-- ─── LOGAPI-002: the TOGTools bridge ─────────────────────────────────────────
--
-- TOGTools' Guild Bank Log (Modules/GuildBankLog/GuildBankLog.lua) reads Blizzard's
-- GetGuildBankTransaction buffer, which does not exist on Classic Era -- so its Guild Bank sub-tab
-- is empty on Era by construction, and TOGBankClassic is the thing that knows what moved. The
-- direction is the operator's, decided on the TOGTools side on 2026-08-18 and recorded in
-- TOGTools/docs/DEPENDENCY_CONTRACTS.md §1: "TOGBankClassic PUSHES into GuildBankLog:InjectEntry"
-- -- TOGBankClassic owns its schema, TOGTools stays a passive receiver that stores. Which is also
-- exactly LOGAPI-001's shape: nothing persisted here, the consumer is the one that stores.
--
-- What is pushed: the bank-CONTENTS entries -- deposit / withdraw as `kind = "item"`, the two money
-- types as `kind = "money"` -- because those are the guild bank movements the receiving log is
-- shaped for (it mirrors GetGuildBankTransaction: type, name, item, count, time). The request
-- entries are NOT pushed: a `mailed` fulfilment is already the `withdraw` the banker's next version
-- records, and pushing both would show one movement twice.
--
-- Pushed on BOTH flavours this addon ships. The contract says "only push on flavours where the
-- native bank does not exist, or accept duplicates" -- its concern being a transaction BOTH sides
-- see. TOGBankClassic never sees a real guild-bank transaction: it scans bank CHARACTERS, so on
-- TBC its rows are movements the native capture cannot see, not duplicates of it. Stated in the
-- contract reply so TOGTools can object.
--
-- Every call is guarded on `TOGTools.addon`, `logCategories.guildbank` and `InjectEntry` and on
-- nothing else, as the contract asks; `"disabled"` (the user switched that log off) stops the
-- batch and is not an error. TOGTools copies the row, so a scratch table per entry is fine.

--- TOGTools' guild bank log, when TOGTools is installed and carries the hook. nil otherwise.
---@return table|nil
function Log:TOGToolsLog()
	local ns = _G.TOGTools and _G.TOGTools.addon
	local log = ns and ns.logCategories and ns.logCategories["guildbank"]
	if log and log.InjectEntry then return log end
	return nil
end

--- TOGTools' guild bucket key. Its own spelling when it exposes it (`GetCurrentGuildKey`), else
--- the same shape built here: `GuildName-Realm`, realm with its spaces removed.
---@param log table the TOGTools log
---@return string|nil
function Log:TOGToolsGuildKey(log)
	if log and log.GetCurrentGuildKey then
		local key = log:GetCurrentGuildKey()
		if key then return key end
	end
	local G = TOGBankClassic_Guild
	local name = G and G.Info and G.Info.name
	if not name or name == "" then return nil end
	local realm = (GetRealmName and GetRealmName() or ""):gsub("%s+", "")
	return name .. "-" .. realm
end

--- An item link for a logged item: the client's when it has the item cached, else the same
--- synthetic link the Inventory window draws for an uncached one -- id and suffix in the right
--- fields, the display name in the brackets -- so TOGTools' `itemSig` (derived from the link) is
--- right and the row reads as the item.
---@param itemID number
---@param suffixID number|nil
---@param name string|nil
---@return string|nil
function Log:ItemLinkFor(itemID, suffixID, name)
	itemID = tonumber(itemID)
	if not itemID then return nil end
	local Record, Resolve = TOGBankClassic_Inventory_Record, TOGBankClassic_Inventory_Resolve
	local suffix = tonumber(suffixID) or 0
	-- LOG-TAB-002: THE CLIENT'S OWN LINK FIRST. The operator, on the Log tab: "the item should look
	-- exactly like the in game link, to include the right color, right now this one is white when
	-- it should be green. it's also missing the suffix". The synthetic link below is white and
	-- carries the base name; GetItemInfo on the full item string (id + suffix in the fields the game
	-- reads them from) returns the quality-coloured link with the suffixed name, whenever the
	-- client has the item cached -- which it has, for anything a scan or a delivery just named.
	-- Taken ONLY when the link that comes back carries the suffix asked for (its seventh field):
	-- a client answering for the base item drops the variant, and TOGTools' itemSig would then
	-- merge two variants -- the spec that pins that went red on the first cut of this.
	if GetItemInfo then
		local _, clientLink = GetItemInfo(string.format("item:%d:0:0:0:0:0:%d", itemID, suffix))
		if type(clientLink) == "string" then
			local linkSuffix = clientLink:match("|Hitem:%d+:[^:|]*:[^:|]*:[^:|]*:[^:|]*:[^:|]*:(%-?%d*)")
			if linkSuffix and (tonumber(linkSuffix) or 0) == suffix then return clientLink end
		end
	end
	if Record and Resolve and Record.new and Resolve.describe then
		local d = Resolve.describe(Record.new(itemID, 1, suffix))
		-- Resolve's second step emits a bare `item:<id>` link (INV2-SUFFIX-001), which would lose
		-- the suffix from TOGTools' itemSig; a suffixed item is always synthesised below.
		if d and d.link and suffix == 0 then return d.link end
		name = name or (d and d.name)
	end
	if not name and GetItemInfo then name = GetItemInfo(itemID) end
	return string.format("|cffffffff|Hitem:%d:0:0:0:0:0:%d:0:0|h[%s]|h|r", itemID, suffix, tostring(name or ("Item " .. itemID)))
end

--- One of this log's entries as a row for InjectEntry, or nil for a type that is not a bank
--- movement. Pure.
---
--- `occ` IS PASSED, AND IT IS THE VERSION'S PUBLISH TIME. TOGTools' dedupe is (base tuple + occ),
--- where the base tuple is type|itemSig|count|tab1|tab2|amount -- neither `ts` nor `name` is in
--- it -- and with `occ` omitted InjectEntry assigns the next ordinal for that tuple BEFORE the
--- dedupe check (GuildBankLog.lua:1186-1193, deliberate: an ordinal is a position, and dropping a
--- genuine repeat is the worse failure for a ledger). So an identical row injected twice on one
--- account -- the banker's own scan and the delivery a viewer alt on the same account receives
--- later, a re-delivery, a /reload replaying the batch -- would land TWICE. TOGTools' contract:
--- "a caller that knows the real ordinal may pass occ itself." This addon knows something better
--- than an ordinal: every entry is one version transition, and every client records the same
--- entry from the same transition stamped with the AUTHOR's publish time (LOGAPI-001), so that
--- time is identical on every client and differs between versions. A same-tuple row in a later
--- version is a different occ; the same row again is the same occ and comes back "duplicate".
--- One caveat, stated: TOGTools' itemSig is derived from the link, so two suffix variants of one
--- item moved by the same count in one version share a tuple and an occ -- the second is dropped
--- there. Rare, and the price of not persisting a counter here.
---
--- `source` TAGS THE ROW AS THIS ADDON'S. The operator, 2026-09-11: TOGTools' log "needs to do
--- native AND addon bank, we just need to tag TOGBANK transactions appropriately. TBH, we should do
--- that regardless, so it's apparent." TOGTools copies every field of the row, so the tag rides
--- with it; rendering it is TOGTools' side.
---@param entry table
---@return table|nil row
function Log:ToTOGToolsRow(entry)
	if type(entry) ~= "table" then return nil end
	if entry.type == "deposit" or entry.type == "withdraw" then
		return {
			kind = "item", type = entry.type, name = entry.name,
			itemLink = self:ItemLinkFor(entry.itemID, entry.suffixID, entry.item),
			count = entry.count, ts = entry.ts, occ = entry.ts,
			source = self.SOURCE_TAG,
			-- LOGAPI-004: the other party, when the banker's client knew it (step 4's `who`): the
			-- requester a withdrawal was mailed or handed to, the sender a deposit arrived from. The
			-- operator, reading TOGTools: "the mail item didn't end up there either" -- it had, as the
			-- withdraw, but with no one named. TOGTools copies every field; rendering these is its side.
			to = entry.to, from = entry.from,
		}
	elseif entry.type == "money-deposit" or entry.type == "money-withdraw" then
		return {
			kind = "money", type = entry.type == "money-deposit" and "deposit" or "withdraw",
			name = entry.name, amount = entry.money, ts = entry.ts, occ = entry.ts,
			source = self.SOURCE_TAG,
		}
	end
	return nil
end

--- LOGAPI-005: a REQUEST event as a row for InjectEntry -- `kind = "request"`, `type` one of
--- requested / mailed / handed / cancelled / reopened. The operator, reading TOGTools' Guild Bank
--- tab: "the requests aren't showing up in the togtools logs". They were never pushed: the bridge
--- carried bank movements only, on the reasoning that a `mailed` fill is the `withdraw` the next
--- rescan records -- true of `mailed`, and of nothing else in the list. Pushed ONLY when TOGTools
--- says it can take them (`ACCEPTS_REQUEST_ROWS` on its log, contract LOGAPI-005 in its inbox): a
--- row in a shape its reader does not know would be stored and never shown, or worse. `occ` is the
--- event time plus the request id, since two events on one request can share a second.
---@param entry table
---@return table|nil row
function Log:ToTOGToolsRequestRow(entry)
	if type(entry) ~= "table" or not entry.type then return nil end
	local t = entry.type
	if not (t == "requested" or t == "mailed" or t == "handed" or t == "cancelled" or t == "reopened") then return nil end
	return {
		kind = "request", type = t, name = entry.name, to = entry.to,
		itemLink = self:ItemLinkFor(entry.itemID, entry.suffixID, entry.item),
		count = entry.count, note = entry.note, requestId = entry.requestId,
		ts = entry.ts, occ = tostring(entry.ts) .. ":" .. tostring(entry.requestId),
		source = self.SOURCE_TAG,
	}
end

--- Does this TOGTools accept request rows? Its side declares it; absent means no.
---@param log table the TOGTools log
---@return boolean
function Log:TOGToolsAcceptsRequests(log)
	return log ~= nil and log.ACCEPTS_REQUEST_ROWS == true
end

--- The `source` value every pushed row carries. A consumer telling addon-bank rows from native
--- guild-bank rows compares against this, so it is a constant here and a contract with TOGTools.
--- Short on purpose -- the operator, on "TOGBankClassic": "thats a lot of text per line, maybe
--- something like [TOGB]" -- it is rendered on a log row, bracketed, next to the item.
Log.SOURCE_TAG = "TOGB"

--- Push a batch into TOGTools. Returns how many rows it stored and why it stopped:
--- "absent" (TOGTools not installed or no hook), "no-guild-key", "disabled" (the user has that
--- log switched off -- not an error, not retried), or "done".
---@param entries table array of entries
---@return number stored
---@return string why
function Log:PushToTOGTools(entries)
	local log = self:TOGToolsLog()
	if not log then return 0, "absent" end
	local key = self:TOGToolsGuildKey(log)
	if not key then return 0, "no-guild-key" end
	local stored = 0
	local requests = self:TOGToolsAcceptsRequests(log)
	for _, e in ipairs(entries or {}) do
		local row = self:ToTOGToolsRow(e) or (requests and self:ToTOGToolsRequestRow(e)) or nil
		if row then
			local ok, reason = log:InjectEntry(key, row)
			if ok then
				stored = stored + 1
			elseif reason == "disabled" then
				return stored, "disabled"
			else
				-- "duplicate" is the EXPECTED answer for a viewer re-injecting the banker's row
				-- (same tuple, same occ); the others name a TOGTools-side refusal. Debug, not error.
				debug("DELIVER", "TOGTools did not store a %s %s row: %s",
					tostring(row.kind), tostring(row.type), tostring(reason))
			end
		end
	end
	return stored, "done"
end
