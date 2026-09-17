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
-- THE TABLE, THE MINT, THE ADOPT AND THE CODEC ARE DELTASYNC'S (LIBREQ-DS-008 part 1, adopted
-- 2026-09-15 from the library's working tree under LIB-RELEASE-ORDER): `DeltaSyncNumbers.lua`
-- generalised this file's first cut to any string key and lives on TOGBank's host as
-- `host.numbers`. What remains here is exactly what the library cannot know:
--   * THE CONFIGURATION -- where the table lives (`Guild.Info.roster`, beside the banker list, so
--     the SavedVariables shape is unchanged), which keys get numbers (the current banker roster),
--     who may MINT (an account that OWNS a banker: a record carrying `inventoryContentHash`, which
--     only a local Bank:Scan writes and which never travels), the name spelling, the canon clock
--     (DeltaComms:CanonPublishTime), and what to do when the table changes (repaint the tabs).
--   * THE `togbank-hl` TRANSPORT, for the v1.5.1 OVERLAP ONLY. Part 2 (the numbered P2P itself,
--     Modules/P2P.lua) put the whole wire on the DeltaSync host: this build asks for and answers
--     the table on the library's HANDSHAKE prefix, through the library. A v1.5.1 client asks and
--     answers on `togbank-hl`, and numbers must be the same on EVERY client, upgraded or not --
--     so its hlb2's table version still drives `OnAdvertisedVersion` below and its request is still
--     answered here. Delete this section when v1.5.1 is gone from the guild.
--   * The forwarders below, read by the sites that name a banker by number: the Bankers tab and
--     /togbank roster, Chat's hash-list reply, the dev trace.
--
-- The library's rules, unchanged from the first cut and now specced on its side as well as here:
-- a number is issued once and never reused; minting is alphabetical from `numbersNext`, so two
-- minters produce the identical table; `numbersVersion` rides every numbered message and a client
-- behind it asks for the table; equal version + different table adopts only from the lower-sorting
-- sender, and the loser re-mints its stragglers under a higher version. WIRE: an entry is
-- `<4-digit number><20-digit canon>`, 24 characters, digits only.

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

-- ─── The library instance ─────────────────────────────────────────────────────

--- Does this ACCOUNT own a banker? True when any current banker's record carries
--- `inventoryContentHash` -- written only by a local scan, never received. The library's
--- `canMint` reads this.
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

--- The roster table the numbers live on, created on demand. nil when there is no guild record
--- yet. The library writes exactly three fields on it: numbers, numbersNext, numbersVersion.
local function rosterTable()
	local G = TOGBankClassic_Guild
	local info = G and G.Info
	if not info then return nil end
	info.roster = info.roster or {}
	return info.roster
end

--- The library's numbers instance on TOGBank's DeltaSync host, initialised with this addon's
--- configuration on first use. nil while the host is not up, or against a DeltaSync that predates
--- `DeltaSyncNumbers.lua` (no `InitNumbers` on the host) -- every forwarder below then answers
--- "nothing numbered", which is what every call site already tolerates.
function BN:Lib()
	local Core = TOGBankClassic_Core
	if not (Core and type(Core.DeltaHost) == "function") then return nil end
	local host = Core:DeltaHost()
	if not host then return nil end
	local inst = rawget(host, "numbers")
	if inst then return inst end
	if type(host.InitNumbers) ~= "function" then return nil end
	return host:InitNumbers({
		table   = rosterTable,
		keys    = function()
			local G = TOGBankClassic_Guild
			return (G and type(G.GetBanks) == "function" and G:GetBanks()) or {}
		end,
		canMint = function() return BN:CanMint() end,
		normalize = function(key)
			local G = TOGBankClassic_Guild
			return (G and G.NormalizeName and G:NormalizeName(key)) or key
		end,
		me = function()
			local G = TOGBankClassic_Guild
			return G and G.GetNormalizedPlayer and G:GetNormalizedPlayer() or nil
		end,
		-- nil (a revision-1 numeric, or garbage) reads as 0 in the library: "no version".
		canonTime = function(canon)
			local DC = TOGBankClassic_DeltaComms
			return DC and DC.CanonPublishTime and DC:CanonPublishTime(canon) or nil
		end,
		-- A mint or an adopt renumbered the roster: the Bankers tab and /togbank roster show numbers.
		-- (A bare offer parked for want of this table is replayed by the library itself, which calls
		-- its P2P's OnNumbersChanged after this -- LIBREQ-DS-008 ask 2.)
		onChanged = function(reason)
			Dbg("Banker numbers changed (%s): version %d", tostring(reason), BN:Version())
			if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.RefreshSoon then
				TOGBankClassic_UI_Inventory:RefreshSoon()
			end
		end,
		onExhausted = function(key)
			TOGBankClassic_Output:Warn("Banker numbers exhausted (%d): %s and later bankers cannot be numbered.", BN.MAX, tostring(key))
		end,
	})
end

-- ─── Forwarders (the library's answers, TOGBank's spelling) ───────────────────

function BN:Table()
	local n = self:Lib()
	return n and n:Table() or nil
end

function BN:Version()
	local n = self:Lib()
	return n and n:Version() or 0
end

--- Four zero-padded digits, the only spelling a number has on the wire or in the UI.
function BN:Format(num)
	return string.format("%04d", num)
end

--- The number for a banker, as a 4-digit string, or nil when it has none.
function BN:NumberOf(name)
	local n = self:Lib()
	return n and n:NumberOf(name) or nil
end

--- The banker a 4-digit number names, or nil.
function BN:NameOf(numStr)
	local n = self:Lib()
	return n and n:KeyOf(numStr) or nil
end

--- Assign numbers to every current banker that has none, alphabetically from `numbersNext`.
--- Returns how many were minted (0 when this account may not mint, or nothing was unnumbered).
function BN:Mint()
	local n = self:Lib()
	return n and n:Mint() or 0
end

--- The whole table, for the wire.
function BN:Snapshot()
	local n = self:Lib()
	return n and n:Snapshot() or nil
end

--- Take a peer's table when it is authoritative (the library's rules). True when ours changed.
function BN:Adopt(snap, sender)
	local n = self:Lib()
	return n and n:Adopt(snap, sender) or false
end

function BN:EncodeEntries(entries)
	local n = self:Lib()
	return n and n:EncodeEntries(entries) or ""
end

function BN:DecodeEntries(s)
	local n = self:Lib()
	return n and n:DecodeEntries(s) or {}
end

function BN:EncodeNumbers(numbers)
	local n = self:Lib()
	return n and n:EncodeNumbers(numbers) or ""
end

function BN:DecodeNumbers(s)
	local n = self:Lib()
	return n and n:DecodeNumbers(s) or {}
end

--- Decode a run of entries into the advertised-summary table every receive path already reads:
--- `{ [name] = { hashV2 = canon, updatedAt = <publish time> } }`, counting the numbers this client
--- cannot name so the caller can ask for the table. (A fresh SUMMARY table, not Guild.Info.alts.)
---@return table alts
---@return number unknown
function BN:EntriesToAlts(entries)
	local n = self:Lib()
	if not n then return {}, #(entries or {}) end
	return n:EntriesToItems(entries)
end

-- ─── Sync with a v1.5.1 peer, on togbank-hl (see the header) ─────────────────

--- A v1.5.1 peer's hlb2 carries its table version. Behind it, ask them for the table -- once per
--- version per cooldown, so a burst of broadcasts does not fan out into a burst of requests. (A
--- peer on this build advertises on the host's OFFER prefix and the library asks it itself.)
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
