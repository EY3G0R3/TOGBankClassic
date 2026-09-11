-- Modules/BankerNumbers.lua
-- P2P-035: every banker has a NUMBER, and the P2P wire names bankers by it.
--
-- THE OPERATOR'S DESIGN, in their words (2026-09-10):
--   "instead of sending everything, say i have newer for 1, 2, 15, 19 and 23? that's a MUCH smaller
--    offer. and we give each banker a number"
--   "i'd rather it's assigned by the addon, having the notes change is too easy for a person to fuck
--    up and have the same number more than once."
--   "100% synced. they have to be the same on EVERY client. and i like the numbers are for life, that
--    way no errors, and if a banker comes back, no problem. lets set aside 4 digits"
--   "we already have a banker list, it's togbank roster, just add the number next to each one"
--   "first one would be 0001 and last one 9999"
--   "i'd be ok with a banker account that is the only one online minting ALL the bankers, that way
--    we don't stop data transmissions"
--
-- WHAT THAT IS, as code:
--   * The table lives on `Guild.Info.roster` beside the banker list: `numbers[name] = n`,
--     `numbersNext`, `numbersVersion`. Integers in SavedVariables; four zero-padded digits on the wire.
--   * A number is issued once and never reused. A banker that leaves keeps its entry; one that comes
--     back has the same number. `numbersNext` only ever rises.
--   * MINTING is done by any account that OWNS a banker -- a record carrying `inventoryContentHash`,
--     which only a local Bank:Scan writes and which never travels (Wire.encode has no slot for it) --
--     for EVERY unnumbered banker on the roster, in alphabetical order from `numbersNext`. Two banker
--     accounts minting at once from the same roster therefore produce the identical table, which is
--     why it does not depend on "only one online" (unknowable at mint time). Accounts that own no
--     banker never mint; they only adopt.
--   * SYNC: `numbersVersion` rides in every numbered message. A client that sees a higher version
--     whispers the sender for the table (`numbers-request`) and adopts the reply wholesale; a client
--     that sees an equal version with a different table adopts it only from a sender whose name sorts
--     lower, so two independent mints converge on one of them and the other re-mints its stragglers
--     under a higher version. KNOWN COST, stated: during that bootstrap window a number can map to
--     two names on two clients for as long as it takes one broadcast to cross; it self-heals and
--     cannot recur once one table has been adopted guild-wide.
--   * WIRE: an entry is `<4-digit number><20-digit canon>`, 24 characters, fixed width, no separator.
--     A broadcast is a run of entries; an offer is a run of bare numbers; a version reply is a run of
--     entries. Digits only, so AceSerializer escapes nothing.

TOGBankClassic_BankerNumbers = {}
local BN = TOGBankClassic_BankerNumbers

BN.MAX          = 9999
BN.WIDTH        = 4
BN.CANON_WIDTH  = 20
BN.ENTRY_WIDTH  = BN.WIDTH + BN.CANON_WIDTH
-- A second request for the same version is not sent inside this many seconds: every broadcast
-- from a client on a newer table would otherwise trigger one.
BN.REQUEST_COOLDOWN = 30

local function Dbg(...)
	TOGBankClassic_Output:Debug("ROSTER", "NUMBERS", ...)
end

--- The roster table the numbers live on, created on demand. nil when there is no guild record yet.
function BN:Table()
	local G = TOGBankClassic_Guild
	local info = G and G.Info
	if not info then return nil end
	info.roster = info.roster or {}
	local r = info.roster
	r.numbers        = r.numbers        or {}
	r.numbersNext    = r.numbersNext    or 1
	r.numbersVersion = r.numbersVersion or 0
	return r
end

function BN:Version()
	local r = self:Table()
	return r and r.numbersVersion or 0
end

--- Four zero-padded digits, the only spelling a number has on the wire or in the UI.
function BN:Format(n)
	return string.format("%04d", n)
end

--- The number for a banker, as a 4-digit string, or nil when it has none.
function BN:NumberOf(name)
	local r = self:Table()
	if not r or not name then return nil end
	local G = TOGBankClassic_Guild
	local norm = G and G:NormalizeName(name) or name
	local n = r.numbers[norm]
	return n and self:Format(n) or nil
end

--- The banker a 4-digit number names, or nil. Reverse map rebuilt when the table changes.
function BN:NameOf(numStr)
	local r = self:Table()
	if not r then return nil end
	local n = tonumber(numStr)
	if not n then return nil end
	if not self.byNumber or self.byNumberVersion ~= r.numbersVersion or self.byNumberTable ~= r.numbers then
		self.byNumber = {}
		for name, num in pairs(r.numbers) do self.byNumber[num] = name end
		self.byNumberVersion = r.numbersVersion
		self.byNumberTable   = r.numbers
	end
	return self.byNumber[n]
end

local function invalidate(self)
	self.byNumber = nil
end

--- Does this ACCOUNT own a banker? True when any current banker's record carries
--- `inventoryContentHash` -- written only by a local scan, never received.
function BN:CanMint()
	local G = TOGBankClassic_Guild
	local alts = G and G.Info and G.Info.alts
	if not alts or type(G.GetBanks) ~= "function" then return false end
	-- Walk the banker list, not every alt: same answer, and the one roster method Mint already
	-- needs (Bank:Scan calls this on every scan, and its Guild is not always the full module).
	for _, name in ipairs(G:GetBanks() or {}) do
		local norm = G.NormalizeName and G:NormalizeName(name) or name
		local alt = norm and alts[norm]
		if type(alt) == "table" and alt.inventoryContentHash ~= nil then
			return true
		end
	end
	return false
end

--- Assign numbers to every current banker that has none, alphabetically from `numbersNext`.
--- Returns how many were minted (0 when this account may not mint, or nothing was unnumbered).
function BN:Mint()
	local r = self:Table()
	if not r or not self:CanMint() then return 0 end
	local G = TOGBankClassic_Guild
	local banks = G:GetBanks() or {}
	local unnumbered = {}
	for _, name in ipairs(banks) do
		local norm = G.NormalizeName and G:NormalizeName(name) or name
		if norm and not r.numbers[norm] then unnumbered[#unnumbered + 1] = norm end
	end
	if #unnumbered == 0 then return 0 end
	table.sort(unnumbered)

	local minted = 0
	for _, norm in ipairs(unnumbered) do
		if r.numbersNext > self.MAX then
			if not self.warnedExhausted then
				self.warnedExhausted = true
				TOGBankClassic_Output:Warn("Banker numbers exhausted (%d): %s and later bankers cannot be numbered.", self.MAX, norm)
			end
			break
		end
		r.numbers[norm] = r.numbersNext
		r.numbersNext   = r.numbersNext + 1
		minted = minted + 1
		Dbg("Minted %s = %s", norm, self:Format(r.numbers[norm]))
	end
	if minted > 0 then
		-- Strictly monotonic even when two mints land in one second.
		r.numbersVersion = math.max(r.numbersVersion + 1, GetServerTime())
		invalidate(self)
		Dbg("Minted %d banker number(s); version %d, next %s", minted, r.numbersVersion, self:Format(r.numbersNext))
	end
	return minted
end

--- The whole table, for the wire.
function BN:Snapshot()
	local r = self:Table()
	if not r then return nil end
	local t = {}
	for name, n in pairs(r.numbers) do t[name] = n end
	return { v = r.numbersVersion, n = r.numbersNext, t = t }
end

--- Names sort as the tie-break, and the comparison must be the same on both sides.
local function senderWins(sender, me)
	return type(sender) == "string" and type(me) == "string" and sender < me
end

--- Take a peer's table when it is authoritative. Returns true when ours changed.
---   newer version            -> adopt wholesale
---   same version, same table -> nothing
---   same version, different  -> adopt only from a lower-sorting sender
---   older version            -> ignore
--- After adopting, an account that may mint numbers any roster banker the peer's table lacks,
--- which raises the version so the peer adopts back and the two converge.
function BN:Adopt(snap, sender)
	local r = self:Table()
	if not r or type(snap) ~= "table" or type(snap.t) ~= "table" then return false end
	local v = tonumber(snap.v) or 0
	if v < r.numbersVersion then return false end
	if v == r.numbersVersion then
		local same = true
		for name, n in pairs(snap.t) do if r.numbers[name] ~= n then same = false break end end
		if same then for name, n in pairs(r.numbers) do if snap.t[name] ~= n then same = false break end end end
		if same then return false end
		local G = TOGBankClassic_Guild
		if not senderWins(sender, G and G:GetNormalizedPlayer()) then return false end
	end

	local numbers, maxN = {}, 0
	for name, n in pairs(snap.t) do
		n = tonumber(n)
		if type(name) == "string" and n and n >= 1 and n <= self.MAX and n == math.floor(n) then
			numbers[name] = n
			if n > maxN then maxN = n end
		end
	end
	r.numbers        = numbers
	r.numbersNext    = math.max(tonumber(snap.n) or 1, maxN + 1)
	r.numbersVersion = v
	invalidate(self)
	Dbg("Adopted banker numbers v%d from %s (%d entries, next %s)", v, tostring(sender), maxN, self:Format(r.numbersNext))
	self:Mint()
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.RefreshSoon then
		TOGBankClassic_UI_Inventory:RefreshSoon()
	end
	return true
end

-- ─── Sync ─────────────────────────────────────────────────────────────────────

--- Every numbered message carries the sender's table version. Behind it, ask them for the table --
--- once per version per cooldown, so a burst of broadcasts does not fan out into a burst of requests.
function BN:OnAdvertisedVersion(sender, v)
	v = tonumber(v)
	if not v or not sender or v <= self:Version() then return false end
	local now = GetTime()
	if self.requested and self.requested.v >= v and now - self.requested.at < self.REQUEST_COOLDOWN then
		return false
	end
	self.requested = { v = v, at = now }
	local data = TOGBankClassic_Core:SerializeWithChecksum({ type = "numbers-request" })
	TOGBankClassic_Core:SendWhisper("togbank-hl", data, sender, "NORMAL")
	Dbg("Behind on banker numbers (mine %d, %s has %d) - requested", self:Version(), sender, v)
	return true
end

function BN:HandleRequest(sender)
	local snap = self:Snapshot()
	if not snap or not sender then return false end
	local data = TOGBankClassic_Core:SerializeWithChecksum({ type = "numbers-reply", numbers = snap })
	TOGBankClassic_Core:SendWhisper("togbank-hl", data, sender, "NORMAL")
	Dbg("Sent banker numbers v%d to %s", snap.v, sender)
	return true
end

function BN:HandleReply(sender, snap)
	return self:Adopt(snap, sender)
end

-- ─── Wire ─────────────────────────────────────────────────────────────────────

local function isDigits(s, n)
	return type(s) == "string" and #s == n and s:match("^%d+$") ~= nil
end

--- `{ {number="0007", canon="<20 digits>"}, ... }` -> one fixed-width string. Entries that are not
--- exactly a 4-digit number beside a 20-digit canon are dropped, because one malformed entry would
--- shift every one after it.
function BN:EncodeEntries(entries)
	local parts = {}
	for _, e in ipairs(entries or {}) do
		if isDigits(e.number, self.WIDTH) and isDigits(e.canon, self.CANON_WIDTH) then
			parts[#parts + 1] = e.number .. e.canon
		end
	end
	return table.concat(parts)
end

--- The inverse. A string whose length is not a multiple of 24, or that carries a non-digit, decodes
--- to nothing rather than to a prefix -- a truncated payload must not read as a shorter valid one.
function BN:DecodeEntries(s)
	local out = {}
	if type(s) ~= "string" or #s % self.ENTRY_WIDTH ~= 0 or (s ~= "" and not s:match("^%d+$")) then
		return out
	end
	for i = 1, #s, self.ENTRY_WIDTH do
		out[#out + 1] = { number = s:sub(i, i + self.WIDTH - 1), canon = s:sub(i + self.WIDTH, i + self.ENTRY_WIDTH - 1) }
	end
	return out
end

--- `{ "0001", "0004", ... }` -> "00010004..."
function BN:EncodeNumbers(numbers)
	local parts = {}
	for _, n in ipairs(numbers or {}) do
		if isDigits(n, self.WIDTH) then parts[#parts + 1] = n end
	end
	return table.concat(parts)
end

function BN:DecodeNumbers(s)
	local out = {}
	if type(s) ~= "string" or #s % self.WIDTH ~= 0 or (s ~= "" and not s:match("^%d+$")) then
		return out
	end
	for i = 1, #s, self.WIDTH do
		out[#out + 1] = s:sub(i, i + self.WIDTH - 1)
	end
	return out
end

--- Decode a run of entries into the advertised-summary table every receive path already reads:
--- `{ [name] = { hashV2 = canon, updatedAt = <publish time> } }`. Entries whose number this client
--- cannot name are skipped and counted, so the caller can ask for the table.
---@return table alts
---@return number unknown how many entries named a number we do not hold
function BN:EntriesToAlts(entries)
	local alts, unknown = {}, 0
	local DC = TOGBankClassic_DeltaComms
	for _, e in ipairs(entries or {}) do
		local name = self:NameOf(e.number)
		if name then
			alts[name] = { hashV2 = e.canon, updatedAt = DC and DC:CanonPublishTime(e.canon) or nil }
		else
			unknown = unknown + 1
		end
	end
	return alts, unknown
end
