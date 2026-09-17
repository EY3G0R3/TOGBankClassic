-- Modules/P2P.lua
-- THE NUMBERED P2P IS DeltaSync's (LIBREQ-DS-008 part 2, adopted 2026-09-15 from the library's
-- working tree under LIB-RELEASE-ORDER). `DeltaSyncP2PNumbered.lua` is TOGBank's P2P-035 protocol
-- generalised -- the broadcast/collect/dispatch loop, the version query, the send slots and queue,
-- the state-wait, catch-up, MULTIPC's self-consult -- and it lives on TOGBank's DeltaSync host as
-- `host.p2p`, selected with `host:InitP2P({ mode = "numbered" })`. Modules/P2PSession.lua (1,545
-- lines) is deleted; the directive (#12702, "use deltasync ... strip the chaff out of TOGBank") is
-- what this file is.
--
-- WHAT STAYS HERE is exactly what the library cannot know -- THE CONFIGURATION, every hook resolved
-- at call time against TOGBank's own modules (Guild's canon rules, the data-leg gate, the tab-colour
-- caches, Inventory/Sync's data leg, Bank's publish gate) -- and ONE THING THE LIBRARY HAS NO SEAM
-- FOR:
--   * `SendOwn`: TOGBank's two handshake messages the library has no type for -- the `sync-done`
--     receipt (SYNCED-001) and the `query-refused` answer to a data QUERY no accept covers
--     (CHAIN-004) -- travel on TOGBank's `togbank-hl` whisper at ALERT, because the library's
--     HANDSHAKE router ignores a type it does not know and has no host hook for one.
--
-- THREE STAND-INS ARE GONE (LIBREQ-DS-008 asks 1-3, built by DeltaSync 2026-09-16 on thread
-- c20eb5b527e1 and adopted from its working tree under LIB-RELEASE-ORDER, the same day): the library
-- now OFFERS the keys a broadcast did not list (and sends its numbers table first to a broadcaster
-- behind on it) -- was `OfferUnmentioned`; PARKS an offer naming a number its table cannot resolve
-- and replays it when a table is minted or adopted -- was `ParkUnresolved` / `ReplayParkedOffers`
-- (CONGESTION-001: on a throttled wire the one-chunk offer lands before the five-chunk table); and
-- fires `onOfferReceived` BEFORE it judges the message, so the sender's addon version is noted before
-- the data-leg gate reads it -- was `NoteVersionFirst` (WIRE-SKEW-004). Found the day they landed:
-- with both copies running, a banker offered every unlisted key TWICE (congestion_spec, reverse
-- order). The catch-up broadcast also carries TOGBank's fields now (`broadcastExtra`).
--
-- THE WIRE IS THE LIBRARY'S NOW: hlb2 (the numbered broadcast) and hash-offer2 (the bare offer) on
-- the host's OFFER prefix, ver-query / ver-reply / sync-request / -accept / -busy / -queued /
-- -cancel and numbers-request / -reply on its HANDSHAKE prefix, the data leg on QUERY / RESPONSE as
-- since v1.5.0. KNOWN COST, stated in the CHANGELOG and the player notes: a v1.5.1 client and this
-- build never P2P with each other -- their hlb2 on `togbank-hl` is read for its addon version and
-- its numbers-table version and nothing else, and DATA_LEG_MIN_ADDON_VERSION names this version.
--
-- EVERY CALL SITE READS THE LIBRARY DIRECTLY through `Lib()` -- `local p2p = TOGBankClassic_P2P:Lib()
-- ; if p2p then p2p:OnItemCompleted(...) end` -- rather than through a forwarder per method; a
-- forwarding adapter is the class the BankerNumbers header owned as debt for one release, and this
-- file does not add another. nil from `Lib()` means no host, or a DeltaSync that predates the
-- numbered class; every site tolerates that as "no P2P", which is what it is.

TOGBankClassic_P2P = {}
local P2P = TOGBankClassic_P2P

--- The library's numbered P2P instance on TOGBank's DeltaSync host, initialised with this addon's
--- hooks on first use. nil while the host is not up, while the numbers table is not (the numbered
--- protocol requires `host:InitNumbers` first -- BankerNumbers owns that configuration), or against
--- a DeltaSync without `DeltaSyncP2PNumbered.lua`.
---@return table|nil p2p
function P2P:Lib()
	local BN = TOGBankClassic_BankerNumbers
	local numbers = BN and BN:Lib()
	if not numbers then return nil end
	local host = TOGBankClassic_Core:DeltaHost()
	local inst = rawget(host, "p2p")
	if inst and inst.OnBroadcast then return inst end
	local DS = LibStub("DeltaSync-1.0", true)
	if not (DS and DS._P2PNumberedClass and type(host.InitP2P) == "function") then return nil end
	inst = host:InitP2P(self:Config())
	self:WarnIfLibraryBehind(inst)
	return inst
end

--- DS-MINOR-CHECK-001 (Peer Review 2c807551 on the self-audit's F2): the three stand-ins above were
--- DELETED, so this build relies on the library doing that work -- and CurseForge's required dependency
--- guarantees DeltaSync is INSTALLED, not that it is CURRENT. A player whose client updated TOGBank
--- before DeltaSync (v4.1.0) would silently never be offered a bank character the broadcast did not
--- list (a wiped client never recovers) and would wait for the catch-up on an offer that beat its
--- numbers table. Feature-detected on the METHOD the park-and-replay introduced (`OnNumbersChanged`),
--- never a MINOR compare -- this file's house rule, and the method is exactly the missing behaviour.
--- Said once per session, in chat, in the player's terms.
---@param inst table|nil the numbered P2P instance
---@return boolean warned
function P2P:WarnIfLibraryBehind(inst)
	if self.libraryBehindWarned or type(inst) ~= "table" or inst.OnNumbersChanged then return false end
	self.libraryBehindWarned = true
	TOGBankClassic_Output:Warn("Your DeltaSync library is out of date. Update DeltaSync (CurseForge) so bank contents keep syncing reliably.")
	TOGBankClassic_Output:Debug("DELTASYNC", "P2P", "the numbered P2P has no OnNumbersChanged: DeltaSync predates LIBREQ-DS-008 asks 1-3 (unlisted offers, parked offers, onOfferReceived first)")
	return true
end

--- TOGBank's fields on every hlb2 -- the login/cycle broadcast (Events:SyncDeltaVersion) and the
--- library's catch-up (`broadcastExtra`) alike -- built at send time, so a version that moved since
--- the last broadcast is the one named.
---@return table extra
function P2P:BroadcastExtra()
	local g = TOGBankClassic_Guild
	local me = g:GetNormalizedPlayer()
	return {
		banker   = me,
		isBanker = g:IsBank(me),
		-- WIRE-SKEW-001: the data-leg gate's fallback source for peers VersionCheck has not seen.
		addon    = GetAddOnMetadata("TOGBankClassic", "Version") or "dev",
		-- STORE-002: the price authority names the guild price list version it holds (nil for
		-- everyone else), so a client behind it can ask by whisper.
		pl       = TOGBankClassic_PriceList and TOGBankClassic_PriceList:AnnouncedVersion() or nil,
		-- SETTINGS-CANON-001: EVERY client names the guild settings it holds -- their version and the
		-- canon of their values -- so a guildmate holding older ones asks for the new ones by whisper.
		sv       = g:SettingsVersion(),
		sh       = g:SettingsCanon(),
	}
end

--- THE CONFIGURATION. Every hook looks its module up at call time (Core loads last; a spec may
--- stand up a subset), and each is the production predicate itself, never a copy of one.
---@return table config for host:InitP2P
function P2P:Config()
	local function G() return TOGBankClassic_Guild end
	return {
		mode = "numbered",
		-- The canon this client can SERVE (HASH-CANON-009: tuples in the store, and a canon) and the
		-- one it HOLDS (the record's, whatever the store has -- what AdvertisedImproves compares).
		servableCanon = function(key) return G():ServableCanon(key) end,
		heldCanon = function(key)
			local g = G()
			local alt = g.Info and g.Info.alts and g.Info.alts[key]
			if type(alt) ~= "table" or alt.inventoryHashV2 == nil then return nil end
			return TOGBankClassic_DeltaComms:CanonFrom(alt.inventoryHashV2, alt.inventoryUpdatedAt or alt.version)
		end,
		canServe = function(key) return G():CanServe(key) end,
		-- P2P-034: the ONE "can this claim improve what I hold" rule (publish time off the canon;
		-- nothing improves our own character; a copy with no canon is improved by any). Only a
		-- current banker: a peer's adopted numbers table may still name an ex-banker.
		canonImproves = function(key, canon)
			local g = G()
			if not g:IsBank(key) then return false end
			return (g:AdvertisedImproves(key, { hashV2 = canon }))
		end,
		isOwnKey = function(key) return key == G():GetNormalizedPlayer() end,
		-- The catch-up broadcast names what the login one does (the library asks at send time).
		broadcastExtra = function() return P2P:BroadcastExtra() end,
		-- The same gate the delivery passes (Chat:IsAltDataAllowed -> IsInCurrentGuildRoster), so a
		-- peer the library will talk to is one whose payload is taken. XGUILD-SYNC-001: that roster
		-- is the federation while the sister-guild bank is on.
		isValidPeer = function(name) return G():IsInCurrentGuildRoster(name) end,
		-- WIRE-SKEW-001/004: the data-leg gate, a callback because the verdict is TOGBank's memory.
		peerCapable = function(name) return G():PeerSpeaksDataLeg(name) end,
		hasMissingItems = function() return G():HasMissingContent() end,
		-- THE DATA LEG (THE DELTA RELEASE step 3b): on accept, ask on the host's QUERY channel naming
		-- the canon we hold; Inventory/Sync answers on RESPONSE and completes the session on store.
		onDeliver = function(key, _, provider)
			TOGBankClassic_Inventory_Sync:RequestFrom(provider, key)
		end,
		-- EVERY message that names a canon for a banker feeds the caches (P2P:OnAdvertised below).
		onAdvertised = function(key, canon, peer) P2P:OnAdvertised(key, canon, peer) end,
		-- TABCOLOUR-003: a bare offer turns the tab red; the query clearing it, or the delivery,
		-- turns it back.
		onNewerOffered = function(key, peer) G():NoteNewerOffered(key, peer) end,
		onNewerCleared = function(key) G():ClearNewerOffered(key) end,
		-- MULTIPC-001: the login cycle has said what the guild holds for our own character; a scan
		-- deferred on that answer publishes now.
		onSelfConsulted = function()
			local Bank = TOGBankClassic_Bank
			if Bank and Bank.PublishIfDeferred then Bank:PublishIfDeferred() end
		end,
	}
end

--- A message named a canon for a banker (the library's `onAdvertised`; also called directly by
--- Chat:ReceiveHashListReply for an alt the numbers table cannot name yet, which the library never
--- sees as a broadcast). Feeds the two caches the tab colour and the re-request decision read from
--- (the newest-time and the advertised-hash cache, each with its own ClaimantCanServe / IsBank /
--- self guards), and a claim about OUR OWN character records who holds the version this PC lacks
--- (MULTIPC-002).
---@param key string normalized banker name
---@param canon string the advertised canon
---@param peer string who advertised it
function P2P:OnAdvertised(key, canon, peer)
	local g = TOGBankClassic_Guild
	local summary = { hashV2 = canon, updatedAt = TOGBankClassic_DeltaComms:CanonPublishTime(canon) }
	g:NoteAdvertisedHashes(key, summary, peer)
	g:NoteAdvertisedPublishTime(key, summary, peer)
	if key == g:GetNormalizedPlayer() then g:NoteSelfHolder(canon, peer) end
end

--- Every OFFER message the host receives, BEFORE the library judges it (Core's `onOfferReceived`;
--- DeltaSync fires it first, LIBREQ-DS-008 ask 3). An hlb2 names its sender's addon version (the
--- data-leg gate's fallback source -- noted here before the gate reads it), the guild price list
--- version it holds (STORE-002) and the guild settings version and canon it holds
--- (SETTINGS-CANON-001).
---@param sender string as the host normalised it
---@param data table the deserialized message
function P2P:OnOfferReceived(sender, data)
	if type(data) ~= "table" or data.type ~= "hlb2" then return end
	local g = TOGBankClassic_Guild
	local norm = g:NormalizeName(sender) or sender
	-- A peer that just spoke to us is online whatever the roster says yet, and -- the host's
	-- prefixes being TOGBank's own namespace -- it RUNS TOGBank: the same source Chat stamps for
	-- every TOGBank prefix, which is the stamp the federation peer picker prefers (XGUILD-SYNC-001).
	-- The host's own prefixes reach TOGBank only here and in Inventory/Sync.
	if g.UpdateOnlineMember then g:UpdateOnlineMember(norm, true, "addon-message-received") end
	if g.NotePeerAddonVersion then g:NotePeerAddonVersion(sender, data.addon) end
	if data.pl and TOGBankClassic_PriceList then TOGBankClassic_PriceList:OnAnnounced(sender, data.pl) end
	-- SETTINGS-CANON-001: the guild settings it holds; behind them, we ask it.
	if data.sv ~= nil and g.OnSettingsAdvertised then g:OnSettingsAdvertised(norm, data.sv, data.sh) end
end

--- TOGBank's OWN handshake messages -- `sync-done` and `query-refused`, the two the library has no
--- type for (see the header) -- on `togbank-hl` by whisper at ALERT (P2P-031: the lane a busy
--- provider's BULK payloads cannot block). Serialised with the checksum framing here, so no call
--- site spells the prefix or the priority (Peer Review c6819531 F2).
---@param to string the peer, TOGBank's `Name-Realm` spelling
---@param message table { type = "sync-done"|"query-refused", ... }
---@return boolean sent
function P2P:SendOwn(to, message)
	local Core = TOGBankClassic_Core
	if not (Core and Core.SendWhisper) then return false end
	local data = Core:SerializeWithChecksum(message)
	return Core:SendWhisper("togbank-hl", data, to, "ALERT") and true or false
end
