-- Modules/P2P.lua -- TOGBank's hooks into DeltaSync's numbered P2P.
--
-- writ-cannot: the 63 examples that stood in this file ("P2PSession collect window", "P2PSession
-- handshake", the queue, the state-wait, the version query, catch-up, the send slots, MULTIPC's
-- consult ...) must not exist any more -- the module they drove, Modules/P2PSession.lua (1,545
-- lines), was deleted on purpose with LIBREQ-DS-008 part 2 (directive #12702, "use deltasync ...
-- strip the chaff out of TOGBank"). The protocol they pinned is DeltaSync's now
-- (DeltaSyncP2PNumbered.lua, under the library's own Tests/numbered_p2p_spec.lua), and its run on
-- a whole guild of TOGBank clients is Tests/fullsync_spec.lua. What THIS file pins is what stayed
-- in TOGBank: the configuration (every hook resolving to the production predicate it names), the
-- instance (stood up with the host, once), the broadcast fields, and the one thing the library has no
-- seam for -- SendOwn. OfferUnmentioned, NoteVersionFirst and the offer parking were deleted with
-- their describes on 2026-09-16, when DeltaSync built all three (LIBREQ-DS-008 asks 1-3); the
-- library's own specs pin them now, and congestion_spec / fullsync_spec pin them on whole clients.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local OTHER  = "Otherbanker-Testrealm"
local PEER   = "Otherguy-Testrealm"
local OLD    = "Oldguy-Testrealm"
local THIRD  = "Thirdguy-Testrealm"   -- a guildmate who is NOT this client (client() plays Otherguy = PEER)
local GUILD  = "Testguild"
local C      = env.canon
local T      = 1757000000

local function client(who)
	env.standUpClient(who or "Otherguy", {
		{ name = BANKER, note = "gbank" }, { name = OTHER, note = "gbank" }, { name = PEER }, { name = OLD }, { name = THIRD },
	}, GUILD)
	TOGBankClassic_BankerNumbers:Adopt({ v = 5, n = 3, t = { [BANKER] = 1, [OTHER] = 2 } }, PEER)
	assert.equal("0002", TOGBankClassic_BankerNumbers:NumberOf(OTHER), "precondition: the numbers table was not adopted")
end

local function host() return TOGBankClassic_Core:DeltaHost() end

--- Everything that leaves, decoded, the target in `Name-Realm` spelling, in send order.
local function capture()
	local sent = {}
	local function record(prefix, text, dist, target, prio)
		local ok, data = TOGBankClassic_Core:DeserializeWithChecksum(text)
		sent[#sent + 1] = { prefix = prefix, data = ok and data or nil, dist = dist, prio = prio,
			target = target and (TOGBankClassic_Guild:NormalizeName(target) or target) or nil }
	end
	TOGBankClassic_Core.SendWhisper = function(_, prefix, text, target, prio)
		record(prefix, text, "WHISPER", target, prio)
		return true
	end
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, text, dist, target, prio, cb, arg)
		record(prefix, text, dist, target, prio)
		if cb then cb(arg, #text, #text, true) end
	end
	return sent
end

local function ofType(sent, kind)
	local out = {}
	for _, m in ipairs(sent) do if m.data and m.data.type == kind then out[#out + 1] = m end end
	return out
end

--- Hold a servable copy: a record with a canon and tuple rows in the store.
local function hold(alt, canon, at)
	TOGBankClassic_Guild.Info.alts[alt] = {
		name = alt, money = 0, version = at,
		inventoryHash = 0x10, inventoryHashV2 = canon, inventoryUpdatedAt = at, mailHash = 0,
	}
	env.holdV2(GUILD, alt)
end

-- ---------------------------------------------------------------------------------------------
describe("P2P:Lib -- the library's instance on TOGBank's host", function()
	before_each(function() env.reset(); client() end)

	it("is the numbered class on the host, stood up with it, and the same instance every time", function()
		local p2p = TOGBankClassic_P2P:Lib()
		assert.is_table(p2p)
		assert.equal(rawget(host(), "p2p"), p2p, "Lib() hands back something other than the host's own instance")
		assert.equal(LibStub("DeltaSync-1.0")._P2PNumberedClass, getmetatable(p2p).__index)
		assert.equal(p2p, TOGBankClassic_P2P:Lib(), "a second call re-initialised the instance")
	end)

	it("is nil without the numbers table or the numbered class -- every caller reads that as 'no P2P'", function()
		local BN = TOGBankClassic_BankerNumbers
		local realLib = BN.Lib
		BN.Lib = function() return nil end
		assert.is_nil(TOGBankClassic_P2P:Lib(), "no numbers table, yet an instance")
		BN.Lib = realLib
		local DS = LibStub("DeltaSync-1.0")
		local class = DS._P2PNumberedClass
		rawset(host(), "p2p", nil)
		DS._P2PNumberedClass = nil
		assert.is_nil(TOGBankClassic_P2P:Lib(), "no numbered class, yet an instance")
		DS._P2PNumberedClass = class
		assert.is_table(TOGBankClassic_P2P:Lib(), "the class is back and the instance did not come back with it")
	end)

	-- DS-MINOR-CHECK-001: the stand-ins for LIBREQ-DS-008 asks 1-3 are deleted, so a DeltaSync without
	-- the park-and-replay (v4.1.0) is told to the player -- once -- rather than silently syncing worse.
	it("warns the player once when the installed DeltaSync predates the offer parking it relies on, and never when it is current", function()
		local function warnings()
			local out = {}
			for _, call in ipairs(TOGBankClassic_Output.calls) do
				if call.level == "Warn" then
					for i = 1, 3 do
						if type(call[i]) == "string" and call[i]:find("DeltaSync library is out of date", 1, true) then out[#out + 1] = call end
					end
				end
			end
			return out
		end
		assert.is_function(TOGBankClassic_P2P:Lib().OnNumbersChanged, "precondition: the installed DeltaSync has no OnNumbersChanged")
		assert.same({}, warnings(), "a current DeltaSync was reported out of date")

		local DS = LibStub("DeltaSync-1.0")
		local class = DS._P2PNumberedClass
		local method = class.OnNumbersChanged
		rawset(host(), "p2p", nil)
		TOGBankClassic_P2P.libraryBehindWarned = nil
		class.OnNumbersChanged = nil
		local ok, err = pcall(function()
			assert.is_table(TOGBankClassic_P2P:Lib(), "an older DeltaSync gave no P2P at all")
			rawset(host(), "p2p", nil)
			assert.is_table(TOGBankClassic_P2P:Lib())
		end)
		class.OnNumbersChanged = method
		TOGBankClassic_P2P.libraryBehindWarned = nil
		assert(ok, err)
		assert.equal(1, #warnings(), "an out-of-date DeltaSync was not reported exactly once")
	end)

	it("leaves the library's OnBroadcast alone -- no TOGBank wrapper on the instance", function()
		local p2p = TOGBankClassic_P2P:Lib()
		assert.is_nil(rawget(p2p, "OnBroadcast"), "a pre-hook is still installed over the library's OnBroadcast")
	end)
end)

-- ---------------------------------------------------------------------------------------------
describe("P2P:Config -- every hook is the production predicate it names", function()
	local cfg, G
	before_each(function()
		env.reset(); client()
		cfg, G = TOGBankClassic_P2P:Config(), TOGBankClassic_Guild
		assert.equal("numbered", cfg.mode)
	end)

	it("servableCanon / canServe / heldCanon read the record and the store the way Guild does", function()
		assert.is_nil(cfg.servableCanon(OTHER)); assert.is_false(cfg.canServe(OTHER)); assert.is_nil(cfg.heldCanon(OTHER))
		-- A canon with no rows: held, not servable (HASH-CANON-009).
		G.Info.alts[OTHER] = { name = OTHER, inventoryHashV2 = C(T, 0x20), inventoryUpdatedAt = T }
		assert.is_nil(cfg.servableCanon(OTHER)); assert.is_false(cfg.canServe(OTHER))
		assert.equal(C(T, 0x20), cfg.heldCanon(OTHER))
		hold(OTHER, C(T, 0x20), T)
		assert.equal(C(T, 0x20), cfg.servableCanon(OTHER)); assert.is_true(cfg.canServe(OTHER))
		-- heldCanon re-encodes a v1.4.0 numeric canon beside its time (CanonFrom), and is nil for none.
		G.Info.alts[OTHER].inventoryHashV2 = 0x20
		assert.equal(C(T, 0x20), cfg.heldCanon(OTHER))
		G.Info.alts[OTHER].inventoryHashV2 = nil
		assert.is_nil(cfg.heldCanon(OTHER))
	end)

	it("canonImproves is Guild:AdvertisedImproves gated on a CURRENT banker", function()
		hold(OTHER, C(T, 0x20), T)
		assert.is_true(cfg.canonImproves(OTHER, C(T + 1, 0x21)))
		assert.is_false(cfg.canonImproves(OTHER, C(T, 0x20)))
		assert.is_false(cfg.canonImproves(OTHER, C(T - 1, 0x19)))
		assert.is_false(cfg.canonImproves(PEER, C(T + 999, 0x21)), "a non-banker (an ex-banker still in a peer's table) improves nothing")
		assert.is_false(cfg.canonImproves(G:GetNormalizedPlayer(), C(T + 999, 0x21)), "our own character is never fetched")
	end)

	it("isOwnKey / isValidPeer / peerCapable / hasMissingItems are Guild's", function()
		assert.is_true(cfg.isOwnKey(G:GetNormalizedPlayer())); assert.is_false(cfg.isOwnKey(BANKER))
		assert.is_true(cfg.isValidPeer(PEER)); assert.is_false(cfg.isValidPeer("Stranger-Elsewhere"))
		assert.is_true((cfg.peerCapable(PEER)))
		G:NotePeerAddonVersion(OLD, "1.5.1")
		local ok, why = cfg.peerCapable(OLD)
		assert.is_false(ok); assert.equal("1.5.1", why)
		assert.equal(G:HasMissingContent(), cfg.hasMissingItems())
	end)

	it("onDeliver starts the data leg through Inventory/Sync for the provider that accepted", function()
		local asked
		TOGBankClassic_Inventory_Sync.RequestFrom = function(_, provider, key) asked = { provider, key } end
		cfg.onDeliver(OTHER, C(T, 0x20), BANKER)
		assert.same({ BANKER, OTHER }, asked)
	end)

	it("onAdvertised feeds the two caches and the self-holder; onNewerOffered / onNewerCleared move the tab; onSelfConsulted releases a held publish", function()
		hold(OTHER, C(T, 0x20), T)
		cfg.onAdvertised(OTHER, C(T + 60, 0x21), BANKER)
		assert.equal(C(T + 60, 0x21), G.latestBankerHashes[OTHER].hashV2)
		assert.equal(T + 60, G.newestAdvertisedAt[OTHER])
		assert.equal("behind", (G:GetAltStaleness(OTHER)))
		-- Our own name: the self-holder record for Bank (MULTIPC-002), the cache refuses it.
		local me = G:GetNormalizedPlayer()
		hold(me, C(T, 0x30), T)
		cfg.onAdvertised(me, C(T + 60, 0x31), BANKER)
		assert.is_nil(G.latestBankerHashes[me])
		assert.equal(C(T + 60, 0x31), TOGBankClassic_Bank.newerSelf.canon)
		assert.same({ BANKER }, TOGBankClassic_Bank.newerSelf.holders)
		-- The bare offer's red, and its clearing.
		hold(BANKER, C(T, 0x40), T)
		cfg.onNewerOffered(BANKER, PEER)
		assert.equal("offered", (G:GetAltStaleness(BANKER)))
		cfg.onNewerCleared(BANKER)
		assert.equal("current", (G:GetAltStaleness(BANKER)))
		-- The consult settled: Bank is asked to publish what it held back.
		local released = 0
		TOGBankClassic_Bank.PublishIfDeferred = function() released = released + 1 end
		cfg.onSelfConsulted("collect window closed, no offers")
		assert.equal(1, released)
	end)
end)

-- ---------------------------------------------------------------------------------------------
describe("P2P:OnOfferReceived -- what TOGBank reads off every OFFER the host receives", function()
	local G
	before_each(function() env.reset(); client(); G = TOGBankClassic_Guild end)

	it("reads an hlb2's sender online, its addon version and its price-list version; ignores every other type", function()
		local announced
		TOGBankClassic_PriceList = { OnAnnounced = function(_, sender, v) announced = { sender, v } end }
		-- The sighting lands on TOGBank's own memberRoster (the library stays authoritative for a
		-- home member's presence, ROSTER-003): the entry's isOnline and the "runs TOGBank" stamp.
		G.memberRoster[PEER].isOnline, G.memberRoster[PEER].spokeAt = false, nil
		TOGBankClassic_P2P:OnOfferReceived(PEER, { type = "hash-offer2", v = 5, n = "0001", addon = "TOGBankClassic-v9.9.9", pl = 7 })
		assert.is_nil(G.peerAddonVersions[PEER], "a non-hlb2 was read for its version")
		assert.is_nil(announced)
		assert.is_false(G.memberRoster[PEER].isOnline)
		TOGBankClassic_P2P:OnOfferReceived(PEER, { type = "hlb2", v = 5, e = "", addon = "TOGBankClassic-v9.9.9", pl = 7 })
		assert.is_true(G.memberRoster[PEER].isOnline, "a peer that just broadcast is not online")
		assert.is_number(G.memberRoster[PEER].spokeAt, "a peer that just broadcast was not stamped as running TOGBank")
		assert.equal("TOGBankClassic-v9.9.9", G.peerAddonVersions[PEER])
		assert.same({ PEER, 7 }, announced)
		TOGBankClassic_P2P:OnOfferReceived(PEER, "junk")   -- no error
	end)
end)

-- ---------------------------------------------------------------------------------------------
-- writ-cannot: the P2P:OfferUnmentioned and P2P:NoteVersionFirst describes must not exist -- both functions were deleted on purpose on 2026-09-16 when DeltaSync built them into the library (LIBREQ-DS-008 asks 1 and 3); their behaviour is pinned below through the real host instead.
-- LIBREQ-DS-008 asks 1-3, delivered by DeltaSync 2026-09-16: what TOGBank used to stand in for, now
-- driven through the REAL host's OFFER receive, so the order the library calls TOGBank in is what
-- is pinned -- not a TOGBank function called by hand.
describe("the library's own offer handling, as TOGBank relies on it", function()
	local G, sent
	before_each(function()
		env.reset(); client()
		G = TOGBankClassic_Guild
		hold(BANKER, C(T, 0x20), T)
		hold(OTHER, C(T, 0x30), T)
		sent = capture()
	end)

	--- An hlb2 from `from`, as the host's OFFER prefix receives it.
	local function receive(from, fields)
		local BN = TOGBankClassic_BankerNumbers
		local msg = { type = "hlb2", v = BN:Version(), e = BN:EncodeEntries({}) }
		for k, v in pairs(fields or {}) do msg[k] = v end
		local h = host()
		h:OnAddonMessage(h.prefixes.OFFER, h:SerializeWithChecksum(msg), "GUILD", (from:match("^([^%-]+)")))
	end

	it("TOGBank reads the broadcaster's addon version BEFORE the data-leg gate is asked about it (was NoteVersionFirst)", function()
		local p2p = TOGBankClassic_P2P:Lib()
		local versionWhenAsked
		local realCapable = p2p.cb.peerCapable
		p2p.cb.peerCapable = function(name)
			if G:NormalizeName(name) == OLD then versionWhenAsked = G.peerAddonVersions[OLD] end
			return realCapable(name)
		end
		receive(OLD, { addon = "TOGBankClassic-v1.5.1" })
		assert.equal("TOGBankClassic-v1.5.1", versionWhenAsked, "the gate was asked before the message's own version was read")
		assert.equal(0, #ofType(sent, "hash-offer2"), "offered bankers to a release that cannot fetch them")
	end)

	it("a current peer's broadcast naming nothing draws ONE offer of every servable banker it left out, table first when it is behind (was OfferUnmentioned)", function()
		receive(THIRD, { v = 0, addon = "TOGBankClassic-v1.6.0" })
		local offers = ofType(sent, "hash-offer2")
		assert.equal(1, #offers, "expected exactly one offer -- two means a second offerer is still running")
		assert.equal("00010002", offers[1].data.n)
		local replyAt, offerAt
		for i, m in ipairs(sent) do
			if m.data and m.data.type == "numbers-reply" then replyAt = replyAt or i end
			if m.data and m.data.type == "hash-offer2" then offerAt = offerAt or i end
		end
		assert.is_number(replyAt, "a broadcaster behind on the table was not sent it")
		assert.is_true(replyAt < offerAt, "the offer left before the table it needs")
	end)

	it("the catch-up broadcast carries TOGBank's fields, asked for at send time", function()
		local extra = TOGBankClassic_P2P:Config().broadcastExtra()
		assert.same(TOGBankClassic_P2P:BroadcastExtra(), extra)
		assert.equal(G:GetNormalizedPlayer(), extra.banker)
		assert.equal(G:SettingsVersion(), extra.sv)
		assert.equal(G:SettingsCanon(), extra.sh)
		assert.is_string(extra.addon)
	end)
end)

-- ---------------------------------------------------------------------------------------------
describe("P2P:SendOwn -- TOGBank's two handshake messages on togbank-hl", function()
	before_each(function() env.reset(); client() end)

	it("whispers the message at ALERT with the checksum framing, and reports the send", function()
		local sent = capture()
		assert.is_true(TOGBankClassic_P2P:SendOwn(PEER, { type = "sync-done", alt = BANKER, canon = C(T, 0x20) }))
		assert.equal(1, #sent)
		assert.equal("togbank-hl", sent[1].prefix); assert.equal("WHISPER", sent[1].dist)
		assert.equal(PEER, sent[1].target); assert.equal("ALERT", sent[1].prio)
		assert.same({ type = "sync-done", alt = BANKER, canon = C(T, 0x20) }, sent[1].data)
	end)

	it("is false when the whisper is refused (an offline target) or Core cannot whisper at all", function()
		TOGBankClassic_Guild:UpdateOnlineMember(PEER, false, "spec")
		local lib = LibStub("LibGuildRoster-1.0", true)
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Otherguy has gone offline.")
		assert.is_false(TOGBankClassic_Guild:IsPlayerOnline(PEER), "precondition")
		assert.is_false(TOGBankClassic_P2P:SendOwn(PEER, { type = "query-refused", alt = BANKER, reason = "no_slot" }))
		local Core = TOGBankClassic_Core
		TOGBankClassic_Core = { SerializeWithChecksum = function() return "x" end }
		assert.is_false(TOGBankClassic_P2P:SendOwn(PEER, { type = "sync-done" }))
		TOGBankClassic_Core = Core
	end)

	-- The two types reach the library on the far side through Chat's togbank-hl branches, so the
	-- round trip is pinned once here: query-refused advances the session waiting on that peer.
	it("query-refused, received, advances the requester's ACTIVE session on that provider", function()
		local p2p = TOGBankClassic_P2P:Lib()
		p2p.sessions["s"] = { sessionId = "s", key = OTHER, peer = BANKER, state = "ACTIVE", timers = {},
			triedPeers = { [BANKER] = true }, candidates = { { peer = BANKER, canon = C(T, 0x30) }, { peer = PEER, canon = C(T, 0x30) } } }
		p2p.sessionsByKey[OTHER] = "s"
		local sent = capture()
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "query-refused", alt = OTHER, reason = "no_slot" })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "WHISPER", BANKER)
		assert.equal(PEER, p2p.sessions["s"].peer, "the session did not advance to the next holder")
		assert.equal(1, #ofType(sent, "sync-request"))
	end)
end)

-- writ-cannot: the P2P:NoteVersionFirst describe must not exist -- the function was deleted on purpose on 2026-09-16 when DeltaSync began firing onOfferReceived before it judges a message (LIBREQ-DS-008 ask 3); "TOGBank reads the broadcaster's addon version BEFORE the data-leg gate" above pins the same order through the real host.
