-- STORE-007 (GUILD_STORE.md 4.7, build-order step 6): DONATION CREDIT.
--
-- What a member gives the bank is worth POINTS, and the points are a ledger of past events -- not
-- a live valuation. The rules this file is held to, from the design note, each one the answer to an
-- argument that would otherwise happen in guild chat:
--
--   * A donation's value is LOCKED at the moment it is received, permanently. Nothing here ever
--     re-prices an entry; a balance is a sum of numbers written once.
--   * The BANKER who receives it sets the value (the mailbox scan already runs there, Mail:Open),
--     from a CONSERVATIVE statistic of the price library -- minimum buyout, then historical, never
--     market value, which a thin market can be pushed to -- with the VENDOR SELL price as the floor
--     (nobody lists below what a vendor pays). Q7 of the design's open questions, the donation half,
--     is settled here rather than asked: an item no source can price is credited at its vendor sell
--     price, never refused and never silently zero; an item with no value at all (a quest item,
--     vendor 0) is logged at 0 points, so the receipt exists even when the credit does not.
--   * Points are written by BANKERS (a credit) and OFFICERS (an adjustment), never by the member
--     who earned them. Each writer keeps its OWN ledger and publishes only its own totals; a balance
--     shown anywhere is the sum across writers. No client ever writes another writer's bucket, so
--     there is nothing to reconcile and nothing a member's client can author.
--   * Adjustments exist and carry a REASON, so the first mistake does not poison the ledger.
--   * No retroactive valuation. The vendor-valued scores kept before this build (the old
--     `alt.ledger`) are carried forward as each banker's opening balance -- they were valued at
--     ingest too, at the vendor floor -- and never re-valued.
--   * Points are a RECORD, not a currency. Nothing here spends them (design 4.7, first version).
--
-- THE RATE, points per gold of value, is an officer setting on the guild-synced settings
-- (`donationRate`, default 1), the same plumbing as the shop's sign. It is applied at ingest and
-- written into the entry, so changing it changes future credits only.
--
-- STORAGE, all under the guild's own table (`Guild.Info`, which is `db.faction[guild]`). A WRITER
-- is a character ON A MACHINE, `Name-Realm@<machine id>` (LEDGER-PC-001, at D:Writer):
--   donationLedger[writer] = { opening = { [donor] = points }, entries = { ... }, version = epoch }
--       -- written ONLY by this machine's own characters, so a key here IS this machine's
--   donationPoints[writer] = { totals = { [donor] = points }, version = epoch }
--       -- what other writers published; replaced only by a newer version from that writer
-- An entry: { at, donor, kind = "item" | "money" | "adjust", itemID, name, count, copper, points,
--             source, statistic, reason, by }. The list is capped; what falls off the end is rolled
--             into `opening` first, so a total never changes because the log was trimmed.
--
-- The shop switch (SHOP-TAB-001) does NOT gate this. The scoreboard existed for plain banks before
-- the store did; valuing it better is not a purchasing rule.
TOGBankClassic_Donations = {}
local D = TOGBankClassic_Donations

D.DEFAULT_RATE = 1            -- points per gold of value
D.RATE_MIN, D.RATE_MAX = 0.01, 1000
D.ENTRIES_MAX = 300           -- per writer; older entries roll into the opening balance
D.DONORS_MAX = 500            -- per published bucket, on receive
D.REASON_MAX_LEN = 120
D.NAME_MAX_LEN = 64
D.BROADCAST_DELAY = 2         -- seconds; credits from one mail collapse into one broadcast
-- The conservative ladder, in order. Market value is deliberately absent (design 4.7: a thin
-- market's price can be inflated and then donated for inflated credit).
D.STATISTICS = { "minBuyout", "historical" }

-- ---------------------------------------------------------------------------
-- The rate
-- ---------------------------------------------------------------------------

--- Points per gold of value. A missing or malformed setting reads as the default.
function D:Rate()
	local G = TOGBankClassic_Guild
	local s = G and G.Info and G.Info.settings
	local r = s and tonumber(s.donationRate)
	if r and r >= self.RATE_MIN and r <= self.RATE_MAX then return r end
	return self.DEFAULT_RATE
end

--- Copper of value -> points at the current rate, to two decimals.
function D:PointsFor(copper)
	copper = tonumber(copper) or 0
	if copper <= 0 then return 0 end
	return math.floor(copper / 10000 * self:Rate() * 100 + 0.5) / 100
end

-- ---------------------------------------------------------------------------
-- Valuation
-- ---------------------------------------------------------------------------

--- The price library, when it can price. Feature-detected on the METHOD, never a MINOR compare.
function D:PriceLibrary()
	local lib = LibStub and LibStub("LibItemDB-1.0", true)
	if lib and type(lib.GetPrice) == "function" then return lib end
	return nil
end

--- The conservative ladder on THIS client's own price sources: the first of STATISTICS the library
--- answers, as copper per unit and `{ source, statistic, age }`, or nil when nothing answers. The
--- guild price list is built from this (PriceList:Build), so it must never read that list back.
function D:OwnValue(itemID)
	local lib = self:PriceLibrary()
	itemID = tonumber(itemID)
	if not (lib and itemID) then return nil end
	for _, stat in ipairs(self.STATISTICS) do
		local ok, copper, prov = pcall(lib.GetPrice, lib, itemID, stat)
		if ok and type(copper) == "number" and copper > 0 then
			return math.floor(copper), {
				source = prov and (prov.sourceName or prov.source) or "price library",
				statistic = prov and prov.statistic or stat,
				age = prov and prov.age or nil,
			}
		end
	end
	return nil
end

--- Value one stack: copper for `count` of `itemID`, and where the number came from.
--- `vendorSell` is the client's sell-to-vendor price per unit (GetItemInfo's 11th return), the floor.
--- STORE-002: the GUILD PRICE LIST is consulted FIRST (so every banker credits the same figure);
--- this client's own sources only for an item the list lacks. The floor applies to both.
--- Returns copper (0 when nothing values it) and { source=, statistic=, age=, unit= }.
function D:Value(itemID, count, vendorSell)
	count = tonumber(count) or 1
	if count < 1 then count = 1 end
	local floor = tonumber(vendorSell) or 0
	if floor < 0 then floor = 0 end
	local unit, info = floor, { source = "vendor", statistic = "vendorSell" }
	local PL = TOGBankClassic_PriceList
	local copper, prov = nil, nil
	if PL and PL.ValueInfo then copper, prov = PL:ValueInfo(itemID) end
	if copper then
		prov = { source = prov.sourceName, statistic = prov.statistic, age = prov.age }
	else
		copper, prov = self:OwnValue(itemID)
	end
	if copper and copper > unit then
		unit, info = copper, prov
	end
	if unit <= 0 then info = { source = "none", statistic = "none" } end
	info.unit = unit
	return unit * count, info
end

-- ---------------------------------------------------------------------------
-- The ledger
-- ---------------------------------------------------------------------------

local function now()
	return (GetServerTime and GetServerTime()) or (time and time()) or 0
end

local function round2(n)
	return math.floor((tonumber(n) or 0) * 100 + 0.5) / 100
end

--- This account's ledger for `writer`, created on first use. nil without a guild.
function D:Ledger(writer, create)
	local G = TOGBankClassic_Guild
	local info = G and G.Info
	if not info or not writer then return nil end
	if type(info.donationLedger) ~= "table" then
		if not create then return nil end
		info.donationLedger = {}
	end
	local L = info.donationLedger[writer]
	if not L and create then
		L = { opening = {}, entries = {}, version = 0 }
		info.donationLedger[writer] = L
	end
	if L then
		if type(L.opening) ~= "table" then L.opening = {} end
		if type(L.openingValue) ~= "table" then L.openingValue = {} end   -- DONATION-VALUE-001
		if type(L.entries) ~= "table" then L.entries = {} end
		L.version = tonumber(L.version) or 0
	end
	return L
end

--- The character this client is on, normalized. nil before the guild is known.
function D:Me()
	local G = TOGBankClassic_Guild
	return G and G.GetNormalizedPlayer and G:GetNormalizedPlayer() or nil
end

--- LEDGER-PC-001 (Peer Review f5e52bcf F2): THE WRITER IS THE CHARACTER *AND THE MACHINE*. The
--- operator's guild runs its banker as a SHARED ACCOUNT logged into from several PCs (MULTIPC-001),
--- and a ledger lives in one PC's SavedVariables: keyed by the character alone, PC2's first credit
--- published a bucket that REPLACED PC1's on every client (newer version, same writer), erasing
--- PC1's entries from every board -- and PC2 could never get them back, because the same account
--- is never online twice and a relay may not speak for another writer. So each PC is its own
--- writer, `Name-Realm@<machine id>`, the id minted once into the account-wide db; balances were
--- already the sum across writers, so nothing else moves. A PC's board lacks the OTHER PCs' credits
--- for its own character (nobody can hand them to it) -- KNOWN COST, and the small one; members
--- hold every PC's bucket. `by` on an entry stays the character; the machine is the bucket's business.
function D:MachineID()
	local DB = TOGBankClassic_Database
	local g = DB and DB.db and DB.db.global
	if not g then return "local" end
	if type(g.donationMachineID) ~= "string" or g.donationMachineID == "" then
		g.donationMachineID = string.format("%x%04x", (GetServerTime and GetServerTime()) or (time and time()) or 0, math.random(0, 0xFFFF))
	end
	return g.donationMachineID
end

--- This client's writer key: the character on this machine. nil before the guild is known.
function D:Writer()
	local me = self:Me()
	if not me then return nil end
	return me .. "@" .. self:MachineID()
end

--- The character behind a writer key (a pre-LEDGER-PC-001 key is the bare character).
function D:WriterCharacter(writer)
	if type(writer) ~= "string" then return nil end
	return writer:match("^(.-)@") or writer
end

--- Carry the pre-STORE-007 vendor-valued scores of THIS character (`Info.alts[me].ledger`, written
--- only ever on the character itself, so it is unambiguously ours) into its ledger as the opening
--- balance, once. They were valued at ingest, at the vendor floor; they are not re-valued.
function D:MigrateOwnLedger()
	local me = self:Me()
	local writer = self:Writer()
	local G = TOGBankClassic_Guild
	if not (me and writer and G.Info) then return false end
	-- LEDGER-PC-001: a ledger this PC wrote under the bare character key (the build before the
	-- machine id) is this PC's, and moves under its writer key once.
	local ledgers = type(G.Info.donationLedger) == "table" and G.Info.donationLedger or nil
	if ledgers and ledgers[me] and not ledgers[writer] then
		ledgers[writer] = ledgers[me]
		ledgers[me] = nil
		TOGBankClassic_Output:Debug("BANK", "DONATIONS", "moved %s's donation ledger under this machine's writer key", me)
	end
	local alt = G.Info.alts and G.Info.alts[me]
	local old = alt and alt.ledger
	if type(old) ~= "table" then return false end
	local L = self:Ledger(writer, true)
	if not L then return false end
	local moved = 0
	for donor, points in pairs(old) do
		local p = tonumber(points)
		if type(donor) == "string" and p and p > 0 then
			L.opening[donor] = round2((L.opening[donor] or 0) + p)
			moved = moved + 1
		end
	end
	alt.ledger = nil
	if moved > 0 then
		L.version = math.max(L.version + 1, now())
		TOGBankClassic_Output:Debug("BANK", "DONATIONS", "carried %d vendor-valued score(s) into %s's donation ledger", moved, me)
	end
	return moved > 0
end

--- Totals of one ledger: opening plus every entry. A fresh table.
function D:LedgerTotals(L)
	local totals = {}
	if not L then return totals end
	for donor, p in pairs(L.opening or {}) do totals[donor] = round2(p) end
	for _, e in ipairs(L.entries or {}) do
		if type(e.donor) == "string" then
			totals[e.donor] = round2((totals[e.donor] or 0) + (tonumber(e.points) or 0))
		end
	end
	return totals
end

--- DONATION-VALUE-001 (the operator, 2026-09-14: "flesh out the donation points = to gold value"):
--- the GOLD VALUE behind a ledger's points -- `{ [donor] = copper }` summed from every credit that
--- carries copper. An adjustment has no copper (it is points, by an officer), and an opening
--- balance is points carried from the old vendor-valued scores, so neither counts here: the value
--- is what the price library said the gifts were worth, exactly. A fresh table.
function D:LedgerValues(L)
	local values = {}
	if not L then return values end
	for donor, c in pairs(L.openingValue or {}) do values[donor] = math.floor(tonumber(c) or 0) end
	for _, e in ipairs(L.entries or {}) do
		local c = tonumber(e.copper)
		if type(e.donor) == "string" and c and c > 0 then
			values[e.donor] = (values[e.donor] or 0) + math.floor(c)
		end
	end
	return values
end

--- DONOR-KEY-001 (Peer Review f5e52bcf F7): THE ONE SPELLING OF A DONOR. The mail header gives a
--- bare name for a same-realm sender and `Name-Realm` for a cross-realm one; an officer types
--- whatever they type (`alice`, `Alice-Testrealm`). Three spellings of one person split the
--- board three ways and hide an adjustment under a name nobody searches for. So a donor is keyed
--- by the BARE name, and a name that differs from a donor already on the board only in case is
--- that donor -- matched against the keys held rather than folded, because Lua's `lower` is
--- byte-wise and a name with a non-ASCII first letter would fold wrong. A new name is written
--- as WoW spells names: first letter up, the rest down (ASCII; other letters kept as typed).
function D:DonorKey(name)
	if type(name) ~= "string" then return nil end
	local bare = name:match("^%s*([^%-]+)") or ""
	bare = bare:gsub("%s+$", "")
	if bare == "" then return nil end
	local want = bare:lower()
	for donor in pairs(self:Balances()) do
		if type(donor) == "string" and donor:lower() == want then return donor end
	end
	return bare:sub(1, 1):upper() .. bare:sub(2):lower()
end

--- Append an entry to `writer`'s ledger, roll the overflow into the opening balance, bump the
--- version and schedule a broadcast. Returns the entry.
function D:Append(writer, entry)
	local L = self:Ledger(writer, true)
	if not L then return nil end
	entry.at = entry.at or now()
	entry.points = round2(entry.points)
	local entries = L.entries
	entries[#entries + 1] = entry
	while #entries > self.ENTRIES_MAX do
		local old = table.remove(entries, 1)
		if type(old.donor) == "string" then
			L.opening[old.donor] = round2((L.opening[old.donor] or 0) + (tonumber(old.points) or 0))
			-- DONATION-VALUE-001: the value rolls with the points, so neither total moves.
			local c = math.floor(tonumber(old.copper) or 0)
			if c > 0 then L.openingValue[old.donor] = (L.openingValue[old.donor] or 0) + c end
		end
	end
	L.version = math.max(L.version + 1, entry.at)
	self:ScheduleBroadcast()
	return entry
end

--- A banker's credit for one received stack or one sum of money. The ONE writer Mail:Open uses.
--- `what` = { donor=, kind = "item"|"money", itemID=, name=, count=, copper=, source=, statistic=, age= }.
--- Returns the entry, or nil when it cannot be written (no guild, no donor).
function D:Credit(what)
	local me = self:Me()
	if not me or type(what) ~= "table" then return nil end
	local donor = self:DonorKey(what.donor)
	if not donor then return nil end
	self:MigrateOwnLedger()
	local copper = math.floor(tonumber(what.copper) or 0)
	if copper < 0 then copper = 0 end
	local entry = {
		donor = string.sub(donor, 1, self.NAME_MAX_LEN),
		kind = what.kind == "money" and "money" or "item",
		itemID = tonumber(what.itemID),
		name = what.name,
		count = tonumber(what.count),
		copper = copper,
		points = self:PointsFor(copper),
		source = what.source,
		statistic = what.statistic,
		age = tonumber(what.age),
		by = me,
	}
	return self:Append(self:Writer(), entry)
end

--- Can the character this client is on write an ADJUSTMENT? Officers, by the same test the shop
--- list uses (CanViewOfficerNote), so the two officer gestures cannot disagree about who is one.
function D:CanAdjust()
	return CanViewOfficerNote and CanViewOfficerNote() or false
end

--- An officer's correction: `points` may be negative. The ONE writer for adjustments. Returns the
--- entry, or nil and a reason.
function D:Adjust(donor, points, reason)
	if not self:CanAdjust() then return nil, "Only an officer can adjust donation points." end
	local me = self:Me()
	if not me then return nil, "Not in a guild." end
	donor = self:DonorKey(donor)
	if not donor then return nil, "Say whose points to adjust." end
	points = tonumber(points)
	if not points or points ~= points or points == 0 then return nil, "Say how many points to add (or remove, with a minus)." end
	if type(reason) ~= "string" or reason:match("^%s*$") then return nil, "Give a reason -- it is written into the ledger." end
	self:MigrateOwnLedger()
	local entry = {
		donor = string.sub(donor, 1, self.NAME_MAX_LEN),
		kind = "adjust",
		points = round2(points),
		reason = string.sub(reason:trim(), 1, self.REASON_MAX_LEN),
		by = me,
	}
	return self:Append(self:Writer(), entry)
end

-- ---------------------------------------------------------------------------
-- Balances: this account's ledgers, other writers' published totals, the legacy scores
-- ---------------------------------------------------------------------------

--- Every writer's totals, keyed by writer, choosing for each: this account's own ledger (the
--- source, when it is ours), else the published bucket, else a legacy `alt.ledger` this client
--- still holds for a character that has not logged in since the build.
function D:Buckets()
	local G = TOGBankClassic_Guild
	local info = G and G.Info
	local out = {}
	if not info then return out end
	for writer, L in pairs(type(info.donationLedger) == "table" and info.donationLedger or {}) do
		out[writer] = self:LedgerTotals(L)
	end
	for writer, b in pairs(type(info.donationPoints) == "table" and info.donationPoints or {}) do
		if not out[writer] and type(b) == "table" and type(b.totals) == "table" then
			out[writer] = b.totals
		end
	end
	for name, alt in pairs(info.alts or {}) do
		if not out[name] and type(alt) == "table" and type(alt.ledger) == "table" then
			local t = {}
			for donor, p in pairs(alt.ledger) do
				if type(donor) == "string" and tonumber(p) then t[donor] = round2(p) end
			end
			out[name] = t
		end
	end
	return out
end

--- `{ [donor] = points }` summed across every writer. A fresh table.
function D:Balances()
	local sum = {}
	for _, totals in pairs(self:Buckets()) do
		for donor, p in pairs(totals) do
			sum[donor] = round2((sum[donor] or 0) + (tonumber(p) or 0))
		end
	end
	return sum
end

--- DONATION-VALUE-001: every writer's VALUE totals (`{ [donor] = copper }`), keyed by writer,
--- choosing as Buckets does: this account's own ledger, else the published bucket. The legacy
--- `alt.ledger` scores carried no value and contribute none.
function D:ValueBuckets()
	local G = TOGBankClassic_Guild
	local info = G and G.Info
	local out = {}
	if not info then return out end
	for writer, L in pairs(type(info.donationLedger) == "table" and info.donationLedger or {}) do
		out[writer] = self:LedgerValues(L)
	end
	for writer, b in pairs(type(info.donationPoints) == "table" and info.donationPoints or {}) do
		if not out[writer] and type(b) == "table" and type(b.values) == "table" then
			out[writer] = b.values
		end
	end
	return out
end

--- `{ [donor] = copper }` of value donated, summed across every writer. A fresh table.
function D:Values()
	local sum = {}
	for _, values in pairs(self:ValueBuckets()) do
		for donor, c in pairs(values) do
			sum[donor] = (sum[donor] or 0) + math.floor(tonumber(c) or 0)
		end
	end
	return sum
end

--- The balance of one donor, by any spelling DonorKey resolves (bare, realm-qualified, any case).
function D:PointsOf(name)
	local key = self:DonorKey(name)
	if not key then return 0 end
	return self:Balances()[key] or 0
end

--- The gold value (copper) one donor has given, by the same name rule as PointsOf.
function D:ValueOf(name)
	local key = self:DonorKey(name)
	if not key then return 0 end
	return self:Values()[key] or 0
end

--- The scoreboard, highest first: { { player=, points=, copper= }, ... }. `copper` is the value
--- behind the points where the writers reported one (DONATION-VALUE-001); 0 for a balance that is
--- only adjustments or carried-over scores.
function D:Scoreboard()
	local board = {}
	local values = self:Values()
	for donor, p in pairs(self:Balances()) do
		if p ~= 0 then board[#board + 1] = { player = donor, points = p, copper = values[donor] or 0 } end
	end
	table.sort(board, function(a, b)
		if a.points ~= b.points then return a.points > b.points end
		return a.player < b.player
	end)
	return board
end

--- This character's own entries, newest first, optionally only one donor's.
function D:Entries(donor)
	local L = self:Ledger(self:Writer(), false)
	local out = {}
	if not L then return out end
	for i = #L.entries, 1, -1 do
		local e = L.entries[i]
		if not donor or e.donor == donor then out[#out + 1] = e end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- The wire: one bucket per broadcast, the sender's own
-- ---------------------------------------------------------------------------

--- Sanitize an inbound totals table into `{ [donor] = points }`: string donors, finite numbers,
--- two decimals, at most DONORS_MAX. A fresh table.
local function sanitizeTotals(t)
	local clean, n = {}, 0
	if type(t) ~= "table" then return clean end
	for donor, p in pairs(t) do
		p = tonumber(p)
		if type(donor) == "string" and donor ~= "" and p and p == p and p ~= math.huge and p ~= -math.huge
			and n < D.DONORS_MAX then
			clean[string.sub(donor, 1, D.NAME_MAX_LEN)] = round2(p)
			n = n + 1
		end
	end
	return clean
end
D.SanitizeTotals = sanitizeTotals

--- DONATION-VALUE-001: an inbound values table into `{ [donor] = copper }`: string donors,
--- non-negative integers, at most DONORS_MAX. A fresh table.
local function sanitizeValues(t)
	local clean, n = {}, 0
	if type(t) ~= "table" then return clean end
	for donor, c in pairs(t) do
		c = tonumber(c)
		if type(donor) == "string" and donor ~= "" and c and c == c and c ~= math.huge and c >= 0
			and n < D.DONORS_MAX then
			clean[string.sub(donor, 1, D.NAME_MAX_LEN)] = math.floor(c)
			n = n + 1
		end
	end
	return clean
end
D.SanitizeValues = sanitizeValues

--- Collapse the credits of one mail into one broadcast.
function D:ScheduleBroadcast()
	if self.broadcastPending then return end
	local Core = TOGBankClassic_Core
	if not (Core and Core.ScheduleTimer) then return end
	self.broadcastPending = true
	Core:ScheduleTimer(function()
		D.broadcastPending = nil
		D:Broadcast("NORMAL")
	end, self.BROADCAST_DELAY)
end

--- Publish this character's own totals, if it has a ledger and may write one (a banker or an
--- officer). Rides togbank-hl beside the guild settings. Returns true when something was sent.
--- XGUILD-SYNC-001 (D6): with `target`, the same bucket goes by WHISPER to one federated asker.
function D:Broadcast(priority, target)
	local G = TOGBankClassic_Guild
	local me = self:Me()
	if not (G and me) then return false end
	if not (G:IsBank(me) or G:SenderIsOfficer(me) or G:SenderIsGM(me)) then return false end
	self:MigrateOwnLedger()
	local writer = self:Writer()
	local L = self:Ledger(writer, false)
	if not L then return false end
	local payload = {
		type = "donation-points",
		writer = writer,   -- LEDGER-PC-001: the character on THIS machine
		version = L.version,
		totals = self:LedgerTotals(L),
		values = self:LedgerValues(L),   -- DONATION-VALUE-001: the gold behind the points
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	if target then
		TOGBankClassic_Core:SendWhisper("togbank-hl", data, target, priority or "NORMAL")
	else
		TOGBankClassic_Core:SendCommMessage("togbank-hl", data, "GUILD", nil, priority or "NORMAL")
	end
	TOGBankClassic_Output:Debug("PROTOCOL", "DONATIONS", "published %s's donation totals (version %s) to %s", writer, tostring(L.version), target or "guild")
	return true
end

--- Receive another writer's published totals. Trusted only from a banker, officer or GM, only for
--- the SENDER's own bucket (a relay cannot speak for another writer -- the writer key's character
--- must be the sender), never for a ledger this machine holds (it is the source), and only when
--- newer than what is held. Returns true when the bucket was stored.
function D:Receive(sender, data)
	local G = TOGBankClassic_Guild
	local info = G and G.Info
	if not info or type(data) ~= "table" then return false end
	if not (G:SenderHasGbankNote(sender) or G:SenderIsOfficer(sender) or G:SenderIsGM(sender)) then
		TOGBankClassic_Output:Debug("PROTOCOL", "DONATIONS", "donation totals from %s ignored: not a banker or officer", tostring(sender))
		return false
	end
	-- LEDGER-PC-001: the key is `Name-Realm@machine`; the character half is what must match the
	-- sender, and the machine half is kept as sent (it is what tells one PC's bucket from another's).
	local character = G:NormalizeName(self:WriterCharacter(data.writer))
	if not character or character ~= G:NormalizeName(sender) or type(data.writer) ~= "string" then
		TOGBankClassic_Output:Debug("PROTOCOL", "DONATIONS", "donation totals from %s ignored: they name %s as the writer", tostring(sender), tostring(data.writer))
		return false
	end
	local machine = data.writer:match("^.-@(.+)$")
	local writer = machine and (character .. "@" .. string.sub(machine, 1, 32)) or character
	if type(info.donationLedger) == "table" and info.donationLedger[writer] then
		return false   -- ours; the ledger is the source
	end
	local version = tonumber(data.version) or 0
	if type(info.donationPoints) ~= "table" then info.donationPoints = {} end
	local held = info.donationPoints[writer]
	if held and (tonumber(held.version) or 0) >= version then return false end
	-- DONATION-VALUE-001: the values ride beside the totals; a pre-VALUE sender carries none and
	-- the bucket reads as valueless, never as zero-valued.
	info.donationPoints[writer] = { totals = sanitizeTotals(data.totals), values = sanitizeValues(data.values), version = version }
	TOGBankClassic_Output:Debug("PROTOCOL", "DONATIONS", "stored %s's donation totals (version %s)", writer, tostring(version))
	local W = TOGBankClassic_UI_Donations
	if W and W.isOpen and W.DrawContent then W:DrawContent() end
	return true
end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

--- Copper as "12g 34s" / "34s 5c" / "5c" -- plain text, because the board's AceGUI labels and the
--- chat line both want a figure with no coin icons. Gold to the copper, never rounded up.
function D:FormatGold(copper)
	copper = math.floor(tonumber(copper) or 0)
	if copper <= 0 then return "0c" end
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	if g > 0 then return s > 0 and string.format("%dg %ds", g, s) or string.format("%dg", g) end
	if s > 0 then return c > 0 and string.format("%ds %dc", s, c) or string.format("%ds", s) end
	return c .. "c"
end

--- "12.5 points" / "1 point".
function D:FormatPoints(p)
	p = round2(p)
	local s = (p == math.floor(p)) and string.format("%d", p) or string.format("%.2f", p)
	return s .. (math.abs(p) == 1 and " point" or " points")
end
