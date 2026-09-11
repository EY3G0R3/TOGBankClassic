-- Modules/P2PSession.lua
-- P2P inventory sync session manager (P2P-006 redesign).
--
-- Replaces the banker-gated pull model with a broadcast/collect/dispatch loop:
--
-- DOC-003: the phase timings below name COLLECT_WINDOW rather than restating its value. They
-- said "10s" while the constant was 60 -- six times the documented window, in the comment a
-- reader consults before touching the dispatch logic. Three sites said it (here twice and
-- BeginCollectWindow's docstring), which is why none of them is a number any more.
--
--   Phase 1 (T+0):      Every player sends hash-list-broadcast to GUILD via SyncDeltaVersion.
--   Phase 2 (T+0..W):   Peers with NEWER data for any listed alt respond with a
--                        hash-offer whisper containing those alts' hashes + timestamps.
--                        W is COLLECT_WINDOW, below.
--   Phase 3 (T+W):      Dispatch: for each stale alt, pick the peer with the highest
--                        updatedAt, send a sync-request whisper. Note the window is
--                        EXTENDED by a later broadcast, so T+W is measured from the last
--                        one, not the first.
--   Phase 4 (handshake): Peer replies sync-accept (has capacity → sends data via
--                        existing togbank-state/togbank-d4 pipeline) or sync-busy
--                        (at cap → try next candidate).
--
-- The existing togbank-state / togbank-d4 / togbank-nochange data pipeline is
-- unchanged.  Only the trigger/negotiation layer is new.
--
-- Backward compat: old clients who whisper banker with hash-list-request still work
-- via the togbank-hlr path (BroadcastP2PRequest).  New clients skip that and use
-- this module instead.

local P2P = {}

-- ─── Constants ────────────────────────────────────────────────────────────────
local STATE = {
	DISPATCHED = "DISPATCHED", -- sync-request sent, awaiting ACK
	ACTIVE     = "ACTIVE",     -- sync-accept received, state-summary sent
	COMPLETE   = "COMPLETE",
	FAILED     = "FAILED",
}

-- P2P-033: `MAX_ACTIVE_SESSIONS = 3` stood here -- a GLOBAL cap on our own fetches, the same
-- arbitrary number as the sender's cap on the other side. Fetches now run in parallel across
-- peers; the only cap is per peer, because a second request to one peer only sits in that peer's
-- queue while others stand idle. `activeSessions` is still counted, for the status bar.
local MAX_SESSIONS_PER_PEER = 1
local MAX_ACTIVE_SENDS    = 3  -- max concurrent outbound sends (sender side)
local COLLECT_WINDOW      = 60 -- seconds to accumulate hash-offer responses (large guild congestion)
local DISPATCH_TIMEOUT    = 15 -- seconds to wait for sync-accept before next candidate (whisper congestion)
local DELIVERY_TIMEOUT    = 180 -- seconds before declaring a data delivery failed (must
                               --   exceed worst-case AceCommQueue drain time under load)
local SEND_TIMEOUT        = 210 -- seconds before auto-releasing an outbound send slot
                                --   (must be > DELIVERY_TIMEOUT so the safety release
                                --   never races with the delivery watchdog)
-- P2P-035: a number-only offer names WHO, not WHAT. Before asking anyone for data, ask up to this
-- many of the peers that offered a banker what version they hold, wait this long for answers (the
-- author answering ends the wait early), then ask the holder(s) of the newest.
local VERSION_QUERY_MAX    = 5
local VERSION_QUERY_WINDOW = 5
local MAX_RETRY_CYCLES    = 5  -- how many times to restart the candidate list when all peers are busy
local RETRY_CYCLE_DELAY   = 20 -- seconds to wait between retry cycles (allows busy peers to free up)
local CATCH_UP_DELAY      = 45 -- seconds before retrying a full broadcast when all offers are exhausted
local MAX_CATCH_UP_CYCLES = 5  -- max catch-up broadcast rounds before giving up

-- ─── State ────────────────────────────────────────────────────────────────────
P2P.sessions       = {} -- sessionId → session table
P2P.sessionsByAlt  = {} -- normalized altName → sessionId
P2P.offers         = {} -- normalized altName → sorted candidate list [{peer,updatedAt,hash,mailHash}]
P2P.activeSessions = 0  -- count of ACTIVE inbound sessions
P2P.activeSends    = {} -- requesterName → number of concurrent outbound sends
P2P.collectTimer   = nil
P2P.isCollecting   = false
P2P.pendingDispatch = {}
-- TIMER-001, adjacent: this is a LATCH, not a timer handle, despite the name. It is only ever
-- tested for truthiness (ScheduleCatchUp returns early if set) and cleared by the callback --
-- nothing calls :Cancel() on it, which is why C_Timer.After is correct at its one arm site where
-- it was wrong in BeginCollectWindow. DO NOT "fix" that After into a NewTimer expecting a handle
-- here, and do not add a :Cancel() call: the value is the boolean `true`, deliberately, and the
-- assignment happens BEFORE the After so a re-entry during scheduling cannot double-arm it.
P2P.catchUpTimer   = nil -- boolean latch: is a catch-up broadcast already scheduled?
P2P.catchUpCycles  = 0   -- how many catch-up rounds have fired since last full sync
P2P.versionQueries = {}  -- P2P-035: normalized altName -> dispatch item awaiting version replies
P2P.versionQueryTimer = nil

-- ─── Helpers ──────────────────────────────────────────────────────────────────
local function Norm(name)
	return TOGBankClassic_Guild and TOGBankClassic_Guild:NormalizeName(name) or name
end

local function Me()
	return TOGBankClassic_Guild and TOGBankClassic_Guild:GetNormalizedPlayer() or ""
end

local function MakeSessionId(altName)
	-- Include millisecond precision so rapid back-to-back cycles don't collide.
	return Me() .. ":" .. altName .. ":" .. tostring(math.floor(GetTime() * 1000))
end

local function Dbg(...)
	TOGBankClassic_Output:Debug("P2P", ...)
end

-- ─── Catch-up Logic ──────────────────────────────────────────────────────────

--- Schedule a full broadcast/collect/dispatch cycle after CATCH_UP_DELAY seconds.
-- Called when Dispatch finds no offers, or a session fails, and we still have
-- alts with missing content.  Guards against double-scheduling and runaway loops.
function P2P:ScheduleCatchUp(reason)
	if self.catchUpTimer then return end  -- already scheduled

	self.catchUpCycles = (self.catchUpCycles or 0) + 1
	if self.catchUpCycles > MAX_CATCH_UP_CYCLES then
		Dbg("CATCHUP", "Max catch-up cycles (%d) reached (%s) - giving up", MAX_CATCH_UP_CYCLES, reason)
		self.catchUpCycles = 0
		return
	end

	if not (TOGBankClassic_Guild and TOGBankClassic_Guild:HasMissingContent()) then
		Dbg("CATCHUP", "No missing content (%s) - catch-up not needed", reason)
		self.catchUpCycles = 0
		return
	end

	Dbg("CATCHUP", "Scheduling catch-up broadcast in %ds (%s, cycle %d/%d)",
		CATCH_UP_DELAY, reason, self.catchUpCycles, MAX_CATCH_UP_CYCLES)
	self.catchUpTimer = true  -- set before C_Timer.After in case it returns nil
	C_Timer.After(CATCH_UP_DELAY, function()
		P2P.catchUpTimer = nil
		if TOGBankClassic_Guild and TOGBankClassic_Guild:HasMissingContent() then
			Dbg("CATCHUP", "Catch-up cycle %d: firing SyncDeltaVersion", P2P.catchUpCycles)
			if TOGBankClassic_Events then
				TOGBankClassic_Events:SyncDeltaVersion("NORMAL")
			end
		else
			Dbg("CATCHUP", "Catch-up cycle %d: all content received, done", P2P.catchUpCycles)
			P2P.catchUpCycles = 0
		end
	end)
end

-- ─── Collect Window ───────────────────────────────────────────────────────────

--- Start (or extend) the COLLECT_WINDOW-second collect window after broadcasting our hashes.
-- @param myHashes table: altName → {hash, updatedAt, ...}  (from BuildBankerHashList)
function P2P:BeginCollectWindow(myHashes) -- luacheck: ignore myHashes
	-- TIMER-001: NewTimer, not After. C_Timer.After returns NOTHING, so `self.collectTimer` was
	-- always nil, the `if self.collectTimer` guard was always false, and the cancel below never
	-- ran -- while looking exactly like a cancel that did. Extending the window therefore STACKED
	-- a second timer instead of replacing the first: Dispatch fired at the ORIGINAL deadline,
	-- discarding every offer that arrived during the extension, and then fired again later with
	-- the window already closed. On a busy login, where hash-list broadcasts arrive in bursts and
	-- re-open the window repeatedly, that cost real offers every time.
	if self.isCollecting then
		-- Already open: just reset the deadline so late offers still count.
		if self.collectTimer then
			self.collectTimer:Cancel()
		end
		self.collectTimer = C_Timer.NewTimer(COLLECT_WINDOW, function()
			P2P:Dispatch()
		end)
		Dbg("OFFER", "Collect window extended (%ds)", COLLECT_WINDOW)
		return
	end

	self.isCollecting = true
	self.offers = {}
	-- TIMER-SAFE: assigns without cancelling first, and that is correct HERE rather than an
	-- oversight -- this branch is only reached when `isCollecting` is false, and the only thing
	-- that clears that flag is `Dispatch` (:239-240), which is called from NOWHERE BUT THE TIMER
	-- CALLBACKS above and below. So when control arrives here the previous timer has already
	-- FIRED, and `collectTimer` holds a spent handle rather than a live one.
	--
	-- WHAT WOULD BREAK IT, stated because it is one edit away: any new path that sets
	-- `isCollecting = false` while the timer is still armed -- a reset, an abort, a manual
	-- Dispatch. That path must cancel the timer, or this line silently overwrites a live one and
	-- it fires later into a window it does not belong to. That is exactly P2P-026/027.
	self.collectTimer = C_Timer.NewTimer(COLLECT_WINDOW, function()
		P2P:Dispatch()
	end)
	Dbg("OFFER", "Collect window started (%ds)", COLLECT_WINDOW)
end

--- P2P-032: IS THIS OFFER WORTH A SESSION? Read off the viewer's `/togbank dev sendqueue`: three
--- fetch slots busy with Togherbs, Toglowgear and Togweapons from old-build relays -- Togweapons
--- being a bank the viewer ALREADY HELD current (the peer answered no-change) -- and 23 banks
--- queued behind them, the one that mattered included. Old-build peers offer everything whose
--- revision-1 hash differs from ours and this accepted every offer unread. An offer is useful when
--- we hold nothing for the alt, or when it carries a canon newer than the one we hold; a canon-less
--- offer for a bank we hold is revision-1 data ("v1 is always red") and cannot improve anything.
---
--- P2P-034: the rule itself now lives in Guild:AdvertisedImproves, because the hash-list reply and
--- the catch-up check ask the same question and had drifted to a different answer (equality). The
--- publish-time compare -- "newer is the DATE, not the whole string", learned from a session opened
--- for a bank we held current because a float-mangled tail compared greater -- is there.
---@return boolean
function P2P:OfferIsUseful(norm, summary)
	local G = TOGBankClassic_Guild
	if not (G and G.AdvertisedImproves) then return false end
	return (G:AdvertisedImproves(norm, summary))
end

--- Turn the offers recorded for `norms` into a dispatch list, canon-first, exactly as Dispatch does.
local function offersToAltList(self, norms)
	local altList = {}
	for _, altName in ipairs(norms) do
		local offerList = self.offers[altName]
		if offerList and #offerList > 0 and not self.sessionsByAlt[altName] then
			table.sort(offerList, function(a, b)
				if (a.canon ~= nil) ~= (b.canon ~= nil) then return a.canon ~= nil end
				return (a.updatedAt or 0) > (b.updatedAt or 0)
			end)
			table.insert(altList, { altName = altName, candidates = offerList })
		end
	end
	table.sort(altList, function(a, b)
		local ac, bc = a.candidates[1].canon ~= nil, b.candidates[1].canon ~= nil
		if ac ~= bc then return ac end
		return a.altName < b.altName
	end)
	return altList
end

--- Called when a hash-offer whisper arrives from a peer.
---
--- P2P-034: AN OFFER THAT ARRIVES AFTER THE WINDOW IS ACTED ON, NOT DROPPED. This used to return at
--- once when `isCollecting` was false. Read off a viewer on 2026-09-10: `OnOffer from Leatherrcp
--- ignored (not collecting)` -- the banker's offer for the one bank the viewer lacked, whispered at
--- NORMAL behind three payloads it was serving, landed after the 60-second window had closed, and the
--- viewer learned nothing from it. An offer IS the peer saying "I hold newer than you"; it is judged
--- by the same rule whenever it arrives, and one that passes outside a window opens its session
--- now -- through DispatchList, so the one-per-peer rule still holds and a busy peer parks it in
--- pendingDispatch. Inside a window it accumulates for Dispatch, as before.
-- @param peerName  string: normalized sender name
-- @param alts      table:  altName → {hash, updatedAt, mailHash}
function P2P:OnOffer(peerName, alts)
	if not alts then return end
	local late = not self.isCollecting
	local touched = {}

	for altName, summary in pairs(alts) do
		local norm = Norm(altName)
		-- P2P-035: a BARE offer -- a banker number and nothing else -- says "I hold newer" and names
		-- no version. It cannot be judged here; it is recorded as an unverified candidate and judged
		-- after the version query, by the same rule. An offer that carries a canon (a broadcast read
		-- as an offer, or a version reply folded in) is judged now.
		local bare = summary.hashV2 == nil and summary.hash == nil
		-- Skip alts for which we already have a dispatched/active session.
		-- Skip alts not in our current guild's banker roster (prevents cross-guild bleed-in
		-- when a player's account SV contains data from another guild's bankers).
		if not self.sessionsByAlt[norm]
				and TOGBankClassic_Guild and TOGBankClassic_Guild:IsBank(norm)
				and norm ~= Me()
				and (bare or self:OfferIsUseful(norm, summary)) then
			touched[#touched + 1] = norm
			self.offers[norm] = self.offers[norm] or {}
			local entry = {
				peer      = peerName,
				updatedAt = summary.updatedAt or 0,
				hash      = summary.hash      or 0,
				mailHash  = summary.mailHash  or 0,
				canon     = summary.hashV2,   -- canonicalised in OfferIsUseful; nil = no version yet
			}
			-- One entry per peer per alt: a second mention from the same peer refreshes what it said
			-- (a bare offer followed by that peer's broadcast gains a canon; never loses one).
			local existing
			for _, e in ipairs(self.offers[norm]) do
				if e.peer == peerName then existing = e break end
			end
			if existing then
				if entry.canon then existing.canon = entry.canon end
				if entry.updatedAt > existing.updatedAt then existing.updatedAt = entry.updatedAt end
				-- A fresh bare offer from a peer that was queried before (and may have answered
				-- "nothing" -- its scan was not done yet) is a new claim: let it be asked again.
				if bare and not existing.canon then existing.queried, existing.answered = nil, nil end
			else
				-- Insert sorted by updatedAt descending so candidates[1] is always freshest.
				local inserted = false
				for i, e in ipairs(self.offers[norm]) do
					if entry.updatedAt > e.updatedAt then
						table.insert(self.offers[norm], i, entry)
						inserted = true
						break
					end
				end
				if not inserted then
					table.insert(self.offers[norm], entry)
				end
			end
			Dbg("OFFER", "  offer: %s from %s (%s)", norm, peerName, entry.canon or "version unknown")
			-- HASH-CACHE-001: through the one writer, with the SUMMARY AS ADVERTISED. This used to
			-- copy three fields into a fresh table and so dropped hashV2 on the way -- an offer for
			-- the very version we hold replaced a full cache entry with one that had forgotten its
			-- revision-2 hash, and every later comparison silently fell back to revision 1.
			-- A bare offer advertises nothing the cache can hold, and a broadcast read as an offer
			-- was already written to the cache by the broadcast loop that fed it here (Peer Review
			-- F2: the second write was idempotent and read as if it did something).
			if not bare and not summary.cachedByBroadcast then
				if TOGBankClassic_Guild.NoteAdvertisedHashes
					and TOGBankClassic_Guild:NoteAdvertisedHashes(norm, summary) then
					Dbg("OFFER", "  latestBankerHashes[%s] = hash=%08x updatedAt=%s", norm, entry.hash, tostring(entry.updatedAt))
				end
				if TOGBankClassic_Guild.NoteAdvertisedPublishTime then
					TOGBankClassic_Guild:NoteAdvertisedPublishTime(norm, summary)   -- TABCOLOUR-002
				end
			end
		end
	end

	if late and #touched > 0 then
		local altList = offersToAltList(self, touched)
		Dbg("DISPATCH", "Late offer from %s outside the collect window: acting on %d alt(s) now", tostring(peerName), #altList)
		self:DispatchOrQuery(altList)
	end
end

-- ─── Version query (P2P-035) ──────────────────────────────────────────────────

--- The candidates for an alt with the banker itself first: the author's answer is the newest by
--- definition and ends the wait for that alt.
local function authorFirst(candidates, norm)
	local out = {}
	for _, c in ipairs(candidates) do if c.peer == norm then out[#out + 1] = c end end
	for _, c in ipairs(candidates) do if c.peer ~= norm then out[#out + 1] = c end end
	return out
end

--- Every item whose candidates all carry a canon is dispatched; every other item has its
--- version-less candidates asked what they hold, and is dispatched when the answers are in.
--- One shortcut, the operator's: "if the banker responds, they win on the version" -- when the
--- AUTHOR is already among the candidates with its canon, nothing anyone else says can beat it, so
--- the alt is dispatched now with the version-less candidates dropped rather than asked.
function P2P:DispatchOrQuery(altList)
	local ready, query = {}, {}
	for _, item in ipairs(altList) do
		local norm = item.altName
		local needs, authorKnown = false, false
		for _, c in ipairs(item.candidates) do
			if c.canon == nil then needs = true end
			if c.canon ~= nil and c.peer == norm then authorKnown = true end
		end
		if needs and authorKnown then
			local kept = {}
			for _, c in ipairs(item.candidates) do
				if c.canon ~= nil then kept[#kept + 1] = c end
			end
			item.candidates = kept
			needs = false
		end
		if needs then query[#query + 1] = item else ready[#ready + 1] = item end
	end
	if #ready > 0 then self:DispatchList(ready) end
	if #query > 0 then self:BeginVersionQuery(query) end
end

--- Ask up to VERSION_QUERY_MAX version-less candidates per alt what they hold, one whisper per
--- peer carrying every number we want from it. The banker itself is always among those asked.
function P2P:BeginVersionQuery(items)
	local BN = TOGBankClassic_BankerNumbers
	if not BN then return end
	local perPeer = {}
	for _, item in ipairs(items) do
		local norm = item.altName
		if not self.sessionsByAlt[norm] and not self.versionQueries[norm] then
			local num = BN:NumberOf(norm)
			if not num then
				Dbg("VERSION", "%s has no banker number yet; cannot ask who holds which version", norm)
			else
				local asked = 0
				for _, c in ipairs(authorFirst(item.candidates, norm)) do
					if asked >= VERSION_QUERY_MAX then break end
					if c.canon == nil and not c.queried then
						c.queried = true
						asked = asked + 1
						perPeer[c.peer] = perPeer[c.peer] or {}
						table.insert(perPeer[c.peer], num)
					end
				end
				if asked > 0 then
					self.versionQueries[norm] = item
					Dbg("VERSION", "%s: asking %d peer(s) which version they hold", norm, asked)
				else
					-- Every version-less candidate was already asked in an earlier round and never
					-- answered; nothing new to ask. Judge what we have.
					self.versionQueries[norm] = item
					self:FinishVersionQuery(norm)
				end
			end
		end
	end
	for peer, numbers in pairs(perPeer) do
		table.sort(numbers)
		local d = TOGBankClassic_Core:SerializeWithChecksum({ type = "ver-query", n = BN:EncodeNumbers(numbers) })
		TOGBankClassic_Core:SendWhisper("togbank-rr", d, peer, "ALERT")
	end
	-- A latch: one window timer serves every open query, and it clears itself when it fires.
	if not self.versionQueryTimer and next(self.versionQueries) then
		self.versionQueryTimer = C_Timer.NewTimer(VERSION_QUERY_WINDOW, function()
			P2P.versionQueryTimer = nil
			P2P:FinishVersionQueries()
		end)
	end
end

--- A peer asked what we hold. Answer with an entry for every number we can SERVE (HASH-CANON-009);
--- always answer, even with nothing, so the asker stops waiting on us.
function P2P:HandleVersionQuery(sender, encoded)
	local BN = TOGBankClassic_BankerNumbers
	if not BN or not sender then return end
	local entries = {}
	for _, num in ipairs(BN:DecodeNumbers(encoded)) do
		local name = BN:NameOf(num)
		local canon = name and TOGBankClassic_Guild:ServableCanon(name)
		if canon then entries[#entries + 1] = { number = num, canon = canon } end
	end
	local d = TOGBankClassic_Core:SerializeWithChecksum({ type = "ver-reply", e = BN:EncodeEntries(entries) })
	TOGBankClassic_Core:SendWhisper("togbank-rr", d, sender, "ALERT")
	Dbg("VERSION", "ver-query from %s: answered %d of %d", sender, #entries, #BN:DecodeNumbers(encoded))
end

--- A queried peer answered. Fill in what it holds; an alt whose author answered, or whose every
--- asked peer has answered, is judged at once rather than at the end of the window.
function P2P:OnVersionReply(sender, encoded)
	local BN = TOGBankClassic_BankerNumbers
	if not BN or not sender then return end
	local held = {}
	for _, e in ipairs(BN:DecodeEntries(encoded)) do
		local name = BN:NameOf(e.number)
		if name then held[name] = e.canon end
	end
	local done = {}
	for norm, item in pairs(self.versionQueries) do
		local touched, allAnswered = false, true
		for _, c in ipairs(item.candidates) do
			if c.peer == sender and c.queried and not c.answered then
				c.answered = true
				c.canon = held[norm]   -- nil: they no longer hold anything servable for it
				touched = true
			end
			if c.queried and not c.answered then allAnswered = false end
		end
		if touched then
			Dbg("VERSION", "%s: %s holds %s", norm, sender, held[norm] or "nothing servable")
			if sender == norm or allAnswered then done[#done + 1] = norm end
		end
	end
	for _, norm in ipairs(done) do self:FinishVersionQuery(norm) end
end

--- Judge an alt's candidates by the one rule (AdvertisedImproves), keep the holders of the NEWEST
--- version (the author wins a tie), and ask them. A candidate that never answered has no version
--- and is not asked for data.
function P2P:FinishVersionQuery(norm)
	local item = self.versionQueries[norm]
	if not item then return end
	self.versionQueries[norm] = nil
	local G, DC = TOGBankClassic_Guild, TOGBankClassic_DeltaComms
	local live = {}
	for _, c in ipairs(item.candidates) do
		if c.canon and G:AdvertisedImproves(norm, { hashV2 = c.canon }) then live[#live + 1] = c end
	end
	if #live == 0 then
		Dbg("VERSION", "%s: nobody who offered holds a version newer than ours", norm)
		return
	end
	table.sort(live, function(a, b)
		local ta, tb = DC:CanonPublishTime(a.canon) or 0, DC:CanonPublishTime(b.canon) or 0
		if ta ~= tb then return ta > tb end
		return (a.peer == norm) and (b.peer ~= norm)
	end)
	local want = live[1].canon
	local chosen = {}
	for _, c in ipairs(live) do if c.canon == want then chosen[#chosen + 1] = c end end
	item.candidates = chosen
	item.canon = want
	Dbg("VERSION", "%s: newest is %s, held by %d peer(s); asking", norm, want, #chosen)
	self:DispatchList({ item })
end

function P2P:FinishVersionQueries()
	local norms = {}
	for norm in pairs(self.versionQueries) do norms[#norms + 1] = norm end
	table.sort(norms)
	for _, norm in ipairs(norms) do self:FinishVersionQuery(norm) end
end

-- ─── Dispatch ─────────────────────────────────────────────────────────────────

-- Pick the peer with the fewest current assignments (load-balance), avoiding
-- peers we have already tried for this alt.
local function PickPeer(candidates, triedPeers, peerLoad)
	local best, bestIdx = nil, nil
	local bestLoad = math.huge
	for i, c in ipairs(candidates) do
		if not triedPeers[c.peer] then
			local load = peerLoad[c.peer] or 0
			if load < bestLoad then
				bestLoad = load
				best     = c.peer
				bestIdx  = i
			end
		end
	end
	return best, bestIdx
end

--- Fire at end of collect window: create sessions for each stale alt.
function P2P:Dispatch()
	self.collectTimer = nil
	self.isCollecting = false

	-- P2P-032: within an alt, a candidate carrying a canon (the author, or a relay holding the
	-- author's version) goes ahead of one without, whatever their sidecar times say; across alts,
	-- the ones somebody holds a CANON for go first -- those are the ones that can turn a tab
	-- yellow. Stable on name so the order is reproducible. Shared with the late-offer path.
	local norms = {}
	for altName in pairs(self.offers) do norms[#norms + 1] = altName end
	local altList = offersToAltList(self, norms)

	if #altList == 0 then
		Dbg("DISPATCH", "Dispatch: no offers to dispatch")
		self:ScheduleCatchUp("no_offers")
		return
	end

	Dbg("DISPATCH", "Dispatch: %d alts with offers", #altList)
	self:DispatchOrQuery(altList)
	-- Refresh tab colors now that latestBankerHashes reflects the newest peer hashes
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
		TOGBankClassic_UI_Inventory:DrawContent()
	end
end

--- How many of our fetch sessions are currently pointed at `peer`.
local function sessionsWith(self, peer)
	local n = 0
	for _, s in pairs(self.sessions) do
		if s.peer == peer and (s.state == STATE.DISPATCHED or s.state == STATE.ACTIVE) then n = n + 1 end
	end
	return n
end

--- Schedule sessions from a list -- IN PARALLEL ACROSS PEERS.
---
--- P2P-033. The operator: "why don't we introduce parallel processing." This used to hold every
--- fetch behind a GLOBAL cap of three (`MAX_ACTIVE_SESSIONS`) -- the same arbitrary number as the
--- sender's, on the other side. Read off the viewer's `/togbank dev sendqueue`: three sessions on
--- old-build relays, 23 banks queued behind them, the one that mattered included. A fetch costs
--- the REQUESTER ~300 bytes (request + summary); the payload is the sender's bandwidth, and every
--- sender already serialises its own sends through its slots and queue. So the only cap that
--- means anything here is PER PEER: one session in flight with each peer, because a second one
--- would only sit in that peer's queue while other peers stand idle. Every alt with a useful offer
--- from an idle peer dispatches now; an alt whose peers are all busy with us waits in
--- `pendingDispatch` and is retried as sessions complete.
function P2P:DispatchList(altList)
	local peerLoad = {}
	for _, s in pairs(self.sessions) do
		if s.state == STATE.DISPATCHED or s.state == STATE.ACTIVE then
			peerLoad[s.peer] = (peerLoad[s.peer] or 0) + 1
		end
	end

	for _, item in ipairs(altList) do
		-- Skip an alt that already gained a session while we were working through the list.
		-- Written as a negated guard rather than an empty `if ... then -- comment` branch, which
		-- reads as an unfinished thought and is what luacheck reports.
		if not self.sessionsByAlt[item.altName] then
			-- Candidates already busy with us count as tried for THIS pass; they become available
			-- again when their session completes and FlushPendingDispatch re-runs this.
			local busy = {}
			for _, c in ipairs(item.candidates or {}) do
				if (peerLoad[c.peer] or 0) >= MAX_SESSIONS_PER_PEER then busy[c.peer] = true end
			end
			local peer = PickPeer(item.candidates, busy, peerLoad)
			if not peer then
				table.insert(self.pendingDispatch, item)
			else
				peerLoad[peer] = (peerLoad[peer] or 0) + 1
				local sid = MakeSessionId(item.altName)
				self.sessions[sid] = {
					sessionId  = sid,
					altName    = item.altName,
					state      = STATE.DISPATCHED,
					peer       = peer,
					candidates = item.candidates,
					triedPeers = { [peer] = true },
					timers     = {},
				}
				self.sessionsByAlt[item.altName] = sid
				-- Reserve the slot immediately so concurrent flushes see the correct count.
				self.activeSessions = self.activeSessions + 1
				self:SendSyncRequest(sid)
				Dbg("DISPATCH", "  → %s to %s (sid=%s, with that peer: %d)", item.altName, peer, sid, sessionsWith(self, peer))
			end
		end
	end
end

function P2P:SendSyncRequest(sessionId)
	local s = self.sessions[sessionId]
	if not s then return end

	-- P2P-035: the request names the VERSION it wants -- the one this candidate said it holds --
	-- so a peer that has since moved on answers "not that one" rather than sending whatever it has.
	local canon
	for _, c in ipairs(s.candidates or {}) do
		if c.peer == s.peer then canon = c.canon break end
	end
	local payload = {
		type      = "sync-request",
		sessionId = sessionId,
		altName   = s.altName,
		requester = Me(),
		canon     = canon,
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	-- P2P-031: EVERY togbank-rr handshake message goes out at ALERT. The operator: "why don't we
	-- just make ack's a priority? it's a whisper, super fast." Read off the live guild: a banker
	-- serving 13-chunk payloads and spraying kilobyte offers at NORMAL could not get a 100-byte ACK
	-- out inside the requester's 5-second wait, and every request timed out "no banker online" with
	-- the banker online. ChatThrottleLib splits its byte budget EQUALLY among lanes with something
	-- to send, so the ALERT lane -- otherwise near-empty -- carries a handshake in the next tick
	-- regardless of how much NORMAL and BULK is backed up. The eight sites are: sync-request,
	-- sync-accept, sync-busy (x2), sync-queued, sync-cancel, and the two alt-request-reply ACKs.
	TOGBankClassic_Core:SendWhisper("togbank-rr", data, s.peer, "ALERT")

	-- Timeout: if no ACK, advance to next candidate.
	-- TIMER-001: NewTimer, so the :Cancel() calls on this handle actually cancel.
	-- P2P-027: armed through ArmSessionTimer, because this function has TWO callers and only one of
	-- them cancels first. AdvanceCandidate cancels `dispatch` before calling us; the retry callback
	-- does not, and by then AdvanceCandidate may have armed a fresh dispatch timer for a new peer
	-- (its `triedPeers` reset makes a candidate available again). The retry's call would then
	-- overwrite that handle, and the orphan -- whose guard still sees STATE.DISPATCHED -- would fire
	-- AdvanceCandidate against the peer currently being waited on.
	self:ArmSessionTimer(s, "dispatch", DISPATCH_TIMEOUT, function()
		local live = P2P.sessions[sessionId]
		if live and live.state == STATE.DISPATCHED then
			Dbg("HANDSHAKE", "Dispatch timeout for %s/%s - next candidate", live.altName, live.peer)
			P2P:AdvanceCandidate(sessionId, "timeout")
		end
	end)
end

-- ─── ACK Handling ─────────────────────────────────────────────────────────────

--- Peer accepted our sync-request.
function P2P:OnSyncAccept(sessionId, sender)
	local s = self.sessions[sessionId]
	if not s then
		Dbg("HANDSHAKE", "OnSyncAccept: unknown session %s from %s", tostring(sessionId), sender)
		return
	end
	if s.state ~= STATE.DISPATCHED then
		Dbg("HANDSHAKE", "OnSyncAccept: session %s wrong state %s", sessionId, s.state)
		return
	end

	if s.timers.dispatch then
		s.timers.dispatch:Cancel()
		s.timers.dispatch = nil
	end

	s.state = STATE.ACTIVE
	-- activeSessions was already counted at dispatch time; no increment here.
	Dbg("HANDSHAKE", "ACTIVE: %s <- %s (activeSessions=%d)", s.altName, sender, self.activeSessions)

	-- Delivery watchdog in case peer accepts but never delivers.
	-- 180s budget covers worst-case AceCommQueue drain (observed 68-70s under load
	-- with 3 concurrent sends; 180s gives comfortable headroom for large payloads).
	-- P2P-027: through the helper for the invariant, though the state machine already protects this
	-- one -- OnSyncAccept returns early unless the session is DISPATCHED and sets ACTIVE below, so a
	-- second accept cannot reach here. Armed the same way as the others so the rule is the file's,
	-- not this call site's.
	self:ArmSessionTimer(s, "delivery", DELIVERY_TIMEOUT, function()
		local live = P2P.sessions[sessionId]
		if live and live.state == STATE.ACTIVE then
			Dbg("COMPLETE", "Delivery timeout for %s", live.altName)
			P2P:OnFailed(sessionId, "delivery_timeout")
		end
	end)

	-- Kick the existing data-delivery pipeline: send our current state to the
	-- peer so it can compute and send back only the delta (or a full sync).
	local norm = Norm(s.altName)
	TOGBankClassic_Guild:SendStateSummary(norm, sender)
end

--- Peer is at its concurrent-send cap; try the next candidate.
function P2P:OnSyncBusy(sessionId, sender)
	local s = self.sessions[sessionId]
	if not s then return end
	Dbg("HANDSHAKE", "BUSY: %s from %s - advancing", s.altName, sender)
	self:AdvanceCandidate(sessionId, "busy")
end

--- Move to the next untried candidate for a session.
function P2P:AdvanceCandidate(sessionId, reason)
	local s = self.sessions[sessionId]
	if not s then return end

	if s.timers.dispatch then
		s.timers.dispatch:Cancel()
		s.timers.dispatch = nil
	end
	-- P2P-027: the retry timer was NOT cancelled here, and that is the live half. Advancing means
	-- this session is taking a different path now, so a retry cycle scheduled by an earlier advance
	-- must not still fire -- it calls SendSyncRequest for the same session, whispering a second
	-- sync-request and re-arming the dispatch timeout underneath whichever peer we just chose.
	if s.timers.retry then
		s.timers.retry:Cancel()
		s.timers.retry = nil
	end

	local nextPeer = nil
	for _, candidate in ipairs(s.candidates) do
		if not s.triedPeers[candidate.peer] then
			nextPeer = candidate.peer
			break
		end
	end

	if not nextPeer then
		s.retryCount = (s.retryCount or 0) + 1
		if s.retryCount <= MAX_RETRY_CYCLES then
			-- All candidates are currently busy or timed out. Reset and retry after a
			-- delay so peers have time to finish their current sends and free up slots.
			Dbg("HANDSHAKE", "All candidates busy for %s (%s), retry %d/%d in %ds",
				s.altName, reason, s.retryCount, MAX_RETRY_CYCLES, RETRY_CYCLE_DELAY)
			s.triedPeers = {}  -- reset: allow all candidates to be tried again
			s.state = STATE.DISPATCHED
			self:ArmSessionTimer(s, "retry", RETRY_CYCLE_DELAY, function()
				local live = P2P.sessions[sessionId]
				if not live or live.state ~= STATE.DISPATCHED then return end
				local peer = PickPeer(live.candidates, live.triedPeers, {})
				if peer then
					live.peer = peer
					live.triedPeers[peer] = true
					P2P:SendSyncRequest(sessionId)
				else
					P2P:OnFailed(sessionId, "no_candidates_on_retry")
				end
			end)
		else
			Dbg("HANDSHAKE", "All candidates exhausted for %s (%s) after %d retry cycles",
				s.altName, reason, s.retryCount)
			self:OnFailed(sessionId, "no_candidates")
		end
		return
	end

	s.peer               = nextPeer
	s.triedPeers[nextPeer] = true
	s.state              = STATE.DISPATCHED
	self:SendSyncRequest(sessionId)
end

-- ─── Completion / Failure ─────────────────────────────────────────────────────

--- Called when data (or no-change) has been successfully received for an alt.
-- @param altName  string: the alt whose sync completed
-- @param sender   string: who delivered the data (for logging)
function P2P:OnAltCompleted(altName, sender)
	local norm      = Norm(altName)
	local sessionId = self.sessionsByAlt[norm]
	if not sessionId then return end -- not session-backed (legacy path)

	local s = self.sessions[sessionId]
	if not s then
		self.sessionsByAlt[norm] = nil
		return
	end

	self:CancelTimers(s)

	-- Decrement regardless of state: slot was reserved at dispatch time.
	self.activeSessions = math.max(0, self.activeSessions - 1)

	s.state                  = STATE.COMPLETE
	self.sessions[sessionId] = nil
	self.sessionsByAlt[norm] = nil
	Dbg("COMPLETE", "COMPLETE: %s from %s (activeSessions=%d)", norm, tostring(sender), self.activeSessions)

	self:FlushPendingDispatch()
end

--- All candidates failed; fall back to banker.
function P2P:OnFailed(sessionId, reason)
	local s = self.sessions[sessionId]
	if not s then return end

	self:CancelTimers(s)

	-- Decrement regardless of state: slot was reserved at dispatch time.
	self.activeSessions = math.max(0, self.activeSessions - 1)

	local altName            = s.altName
	s.state                  = STATE.FAILED
	self.sessions[sessionId] = nil
	self.sessionsByAlt[altName] = nil
	Dbg("COMPLETE", "FAILED (%s): %s (activeSessions=%d)", reason, altName, self.activeSessions)

	-- Schedule a catch-up broadcast if we still have alts with missing content.
	-- Using a delay lets peers that were busy free up their send slots first.
	self:ScheduleCatchUp("session_failed")
	self:FlushPendingDispatch()
end

--- Arm one of a session's named timers, cancelling whatever was in that slot.
---
--- P2P-027, the same class as P2P-026 one module over: not `After` versus `NewTimer` (this file was
--- corrected on that axis by audit finding 24) but a live handle being ASSIGNED OVER. `BeginCollectWindow`
--- already got this right and its comment says why; the session timers did not.
---@param s table the session
---@param name string slot in `s.timers`
---@param delay number seconds
---@param callback function
function P2P:ArmSessionTimer(s, name, delay, callback)
	s.timers = s.timers or {}
	local existing = s.timers[name]
	if existing and type(existing) == "table" and existing.Cancel then
		existing:Cancel()
		Dbg("HANDSHAKE", "[P2P-027] Replaced in-flight %s timer for %s", name, tostring(s.altName))
	end
	s.timers[name] = C_Timer.NewTimer(delay, callback)
	return s.timers[name]
end

function P2P:CancelTimers(s)
	for _, timer in pairs(s.timers or {}) do
		if timer and type(timer) == "table" and timer.Cancel then
			timer:Cancel()
		end
	end
	s.timers = {}
end

function P2P:FlushPendingDispatch()
	local pending = self.pendingDispatch
	if not pending or #pending == 0 then return end
	self.pendingDispatch = {}
	self:DispatchList(pending)
end

-- ─── Sender Side ──────────────────────────────────────────────────────────────

--- Total outbound sends in flight, across every requester.
-- P2P-025: this sum was hand-written at four call sites and the status bar read a fifth,
-- unrelated counter that nothing incremented -- so the one number the cap is enforced on had
-- five spellings and one of them was always zero. Everything that needs the total calls this.
function P2P:GetActiveSendTotal()
	local total = 0
	for _, count in pairs(self.activeSends) do
		total = total + count
	end
	return total
end

--- Try to acquire an outbound send slot for a given requester.
-- Returns true (slot incremented + safety timer set) if under cap; false if at cap.
-- Call ReleaseSendSlot on send completion; the safety timer is a no-op fallback.
function P2P:TryAcquireSendSlot(requester)
	if self:GetActiveSendTotal() >= MAX_ACTIVE_SENDS then
		return false
	end
	self.activeSends[requester] = (self.activeSends[requester] or 0) + 1

	-- P2P-024: the safety release is tied to THIS acquisition by a generation token.
	--
	-- It used to release unconditionally on a 210s timer. A send that finished normally released
	-- at completion AND again when its stale safety timer fired -- and by then the slot it
	-- decremented belonged to a DIFFERENT, later send from the same requester. The `> 0` guard
	-- prevents underflow but says nothing about over-release, so MAX_ACTIVE_SENDS was quietly
	-- exceeded under sustained load: send #1's timer frees send #2's slot and a fourth
	-- concurrent send is admitted.
	--
	-- Each acquisition gets a token; the real release consumes it, and the safety timer only
	-- acts if its own token is still outstanding.
	self.sendGeneration = (self.sendGeneration or 0) + 1
	local token = self.sendGeneration
	self.pendingSendTokens = self.pendingSendTokens or {}
	self.pendingSendTokens[token] = requester

	Dbg("HANDSHAKE", "TryAcquireSendSlot: acquired for %s (total=%d, token=%d)",
		requester, self:GetActiveSendTotal(), token)
	C_Timer.After(SEND_TIMEOUT, function()
		-- Absent means the real release already consumed it: this timer has nothing to free.
		if P2P.pendingSendTokens and P2P.pendingSendTokens[token] then
			P2P:ReleaseSendSlot(requester, "timeout", token)
		end
	end)
	return true
end

--- Release an outbound send slot for a given requester.
--
-- WITH a token (the safety timer) this is exactly once: the token is consumed, and a second call
-- carrying the same token returns immediately.
--
-- WITHOUT one (a completion) it retires the OLDEST outstanding token for this requester, and that
-- is a GUESS. FINDING 28: it is correct while one send is outstanding for that requester and wrong
-- when two are -- the second token-less call retires the other send's token and decrements its
-- slot, which is over-release, the same fault P2P-024 fixed for the timer path. The `> 0` guard
-- prevents underflow and says nothing about over-release.
--
-- So "safe to call redundantly" is NOT a property of this function, and the previous docstring
-- claimed it was. It is a property the single production caller provides: `Guild.lua` guards the
-- release with `sendStats.slotReleased`, so one send releases once. A NEW caller does not inherit
-- that -- either carry the token, or guard your own completion the same way.
function P2P:ReleaseSendSlot(requester, reason, token)
	self.pendingSendTokens = self.pendingSendTokens or {}
	if token then
		if not self.pendingSendTokens[token] then return end
		self.pendingSendTokens[token] = nil
	else
		-- A completion release with no token retires the OLDEST outstanding token for this
		-- requester, so the safety timer that was scheduled alongside it becomes inert.
		local oldest
		for t, who in pairs(self.pendingSendTokens) do
			if who == requester and (not oldest or t < oldest) then oldest = t end
		end
		if oldest then self.pendingSendTokens[oldest] = nil end
	end

	if (self.activeSends[requester] or 0) > 0 then
		self.activeSends[requester] = self.activeSends[requester] - 1
		Dbg("HANDSHAKE", "ReleaseSendSlot: %s (%s, remaining=%d)",
			requester, reason or "complete", self.activeSends[requester])
		-- P2P-029: a freed slot goes to whoever has been waiting longest.
		self:ServeQueue()
	end
end

--- Handle an incoming sync-request (we are the data provider).
-- Sends sync-accept if we have capacity and content; sync-busy otherwise.
-- Returns true if accepted.
function P2P:HandleSyncRequest(sessionId, requester, altName, canon)
	if not sessionId or not requester or not altName then return false end

	local norm = Norm(altName)

	-- Verify we can still DELIVER this alt (race guard). Peer Review F1: this asked HasAltContent,
	-- which is true for legacy-only content SendAltData cannot ship; CanServe is SendAltData's own
	-- condition, so an accept here is a promise the send can keep.
	if not TOGBankClassic_Guild:CanServe(norm) then
		Dbg("HANDSHAKE", "HandleSyncRequest: nothing servable for %s - busy to %s", norm, requester)
		local d = TOGBankClassic_Core:SerializeWithChecksum({ type = "sync-busy", sessionId = sessionId })
		TOGBankClassic_Core:SendWhisper("togbank-rr", d, requester, "ALERT")
		return false
	end
	-- P2P-035: the requester named the version it wants. If that is not what we can serve now (we
	-- rescanned, or a wipe took it), say so rather than sending a different version under that name.
	if canon ~= nil then
		local mine = TOGBankClassic_Guild.ServableCanon and TOGBankClassic_Guild:ServableCanon(norm)
		if mine ~= canon then
			Dbg("HANDSHAKE", "HandleSyncRequest: %s wants %s at %s, we hold %s - busy (version)", requester, norm, tostring(canon), tostring(mine))
			local d = TOGBankClassic_Core:SerializeWithChecksum({ type = "sync-busy", sessionId = sessionId, reason = "version" })
			TOGBankClassic_Core:SendWhisper("togbank-rr", d, requester, "ALERT")
			return false
		end
	end

	-- P2P-029: AT CAPACITY, QUEUE -- NEVER REFUSE. The operator, on the cap this replaced: "that 3
	-- was an arbitrary number ... make it so it 'buffers' all requests and then has only 3 open
	-- responses, so nothing gets dropped." And on why the cap existed: "to force the P2P in a busy
	-- guild, so one player wasn't getting hammered." Both hold: the reply carries the requester's
	-- queue position, and a requester with ANOTHER untried peer moves on (and cancels here), so
	-- load still spreads; a requester with nobody else to ask waits here and is served in turn.
	-- Refusing was the storm -- every refused requester retried every peer.
	if self:GetActiveSendTotal() >= MAX_ACTIVE_SENDS then
		local position = self:EnqueueSend(sessionId, requester, norm)
		Dbg("HANDSHAKE", "HandleSyncRequest: at capacity (%d) - queued %s for %s at position %d",
			self:GetActiveSendTotal(), requester, norm, position)
		local d = TOGBankClassic_Core:SerializeWithChecksum({ type = "sync-queued", sessionId = sessionId, position = position })
		TOGBankClassic_Core:SendWhisper("togbank-rr", d, requester, "ALERT")
		return false
	end

	return self:AcceptSend(sessionId, requester, norm)
end

--- Take a slot and send the accept. The requester then sends its state summary, which
--- RespondToStateSummary answers; every outcome there, or the state-wait, frees the slot.
function P2P:AcceptSend(sessionId, requester, norm)
	if not self:TryAcquireSendSlot(requester) then return false end
	local d = TOGBankClassic_Core:SerializeWithChecksum({ type = "sync-accept", sessionId = sessionId })
	TOGBankClassic_Core:SendWhisper("togbank-rr", d, requester, "ALERT")
	Dbg("HANDSHAKE", "HandleSyncRequest: accepted %s for %s", norm, requester)
	self:ArmStateWait(requester, norm)
	return true
end

-- P2P-029: the send queue. FIFO; a repeat request from the same requester for the same alt
-- refreshes its entry in place (keeps its position) rather than adding a second; an entry older
-- than QUEUE_TTL is dropped when it comes up, because the requester's own wait has expired.
local QUEUE_TTL = 180

---@return number position 1-based
function P2P:EnqueueSend(sessionId, requester, norm)
	self.sendQueue = self.sendQueue or {}
	for i, e in ipairs(self.sendQueue) do
		if e.requester == requester and e.altName == norm then
			e.sessionId, e.at = sessionId, GetTime()
			return i
		end
	end
	table.insert(self.sendQueue, { sessionId = sessionId, requester = requester, altName = norm, at = GetTime() })
	return #self.sendQueue
end

--- The requester found another peer, or gave up: forget its entry.
function P2P:DequeueSend(sessionId, requester)
	if not self.sendQueue then return end
	for i = #self.sendQueue, 1, -1 do
		local e = self.sendQueue[i]
		if e.requester == requester and (sessionId == nil or e.sessionId == sessionId) then
			table.remove(self.sendQueue, i)
		end
	end
end

--- Called whenever a slot frees: accept the next live entries while there is capacity.
function P2P:ServeQueue()
	while self.sendQueue and #self.sendQueue > 0 and self:GetActiveSendTotal() < MAX_ACTIVE_SENDS do
		local e = table.remove(self.sendQueue, 1)
		if GetTime() - e.at <= QUEUE_TTL then
			if TOGBankClassic_Guild:CanServe(e.altName) then
				self:AcceptSend(e.sessionId, e.requester, e.altName)
			else
				-- Content went away while they waited (a wipe): the honest answer is the same one
				-- HandleSyncRequest gives, so their session advances rather than hangs.
				local d = TOGBankClassic_Core:SerializeWithChecksum({ type = "sync-busy", sessionId = e.sessionId })
				TOGBankClassic_Core:SendWhisper("togbank-rr", d, e.requester, "NORMAL")
			end
		else
			Dbg("HANDSHAKE", "ServeQueue: dropping stale queue entry for %s/%s", e.requester, e.altName)
		end
	end
end

--- The peer queued our request. If we have another untried peer for this alt, move on to it and
--- let the queuing peer forget us; otherwise wait for our turn, well past the normal ACK timeout.
function P2P:OnSyncQueued(sessionId, sender)
	local s = self.sessions[sessionId]
	if not s or s.state ~= STATE.DISPATCHED then return end
	local untried = 0
	for _, c in ipairs(s.candidates or {}) do
		if not s.triedPeers[c.peer] then untried = untried + 1 end
	end
	if untried > 0 then
		local d = TOGBankClassic_Core:SerializeWithChecksum({ type = "sync-cancel", sessionId = sessionId })
		TOGBankClassic_Core:SendWhisper("togbank-rr", d, sender, "NORMAL")
		Dbg("HANDSHAKE", "QUEUED at %s for %s - %d other peer(s) untried, advancing", sender, s.altName, untried)
		self:AdvanceCandidate(sessionId, "queued")
		return
	end
	Dbg("HANDSHAKE", "QUEUED at %s for %s - nobody else holds it, waiting", sender, s.altName)
	self:ArmSessionTimer(s, "dispatch", QUEUE_TTL + 10, function()
		local live = P2P.sessions[sessionId]
		if live and live.state == STATE.DISPATCHED then
			Dbg("HANDSHAKE", "Queue wait expired for %s/%s - next candidate", live.altName, live.peer)
			P2P:AdvanceCandidate(sessionId, "queue_timeout")
		end
	end)
end

-- P2P-028: an accept that is never followed by the requester's state summary -- their session
-- timed out first, they logged off, the whisper was lost -- used to hold the slot for the full
-- 210-second safety timer, which is sized for a large payload in flight, not for a handshake that
-- went nowhere. Read off two live clients: with a guild's worth of requesters and three slots,
-- that alone kept the banker permanently "busy". The summary follows an accept within seconds
-- when it is coming at all, so the wait is short; RespondToStateSummary cancels it on arrival.
local STATE_WAIT = 30

--- Arm the short wait for a requester's state summary after we accepted its sync-request.
--- Keyed by requester AND alt (self-audit F2): two accepts to one requester inside the window are
--- two waits, and one summary cancels only its own -- keyed by requester alone, the second accept
--- cancelled the first's wait and one summary cancelled whichever wait was left.
function P2P:ArmStateWait(requester, norm)
	self.stateWaits = self.stateWaits or {}
	local key = requester .. "|" .. tostring(norm)
	local prior = self.stateWaits[key]
	if prior then prior:Cancel() end
	self.stateWaits[key] = C_Timer.NewTimer(STATE_WAIT, function()
		if P2P.stateWaits then P2P.stateWaits[key] = nil end
		Dbg("HANDSHAKE", "No state summary from %s for %s within %ds of accept - releasing slot", requester, tostring(norm), STATE_WAIT)
		P2P:ReleaseSendSlot(requester, "no_state_summary")
	end)
end

--- The requester's state summary arrived: the send is now in RespondToStateSummary's hands, and
--- every outcome there releases the slot itself.
function P2P:StateSummaryArrived(requester, norm)
	local key = requester .. "|" .. tostring(norm)
	local t = self.stateWaits and self.stateWaits[key]
	if t then
		t:Cancel()
		self.stateWaits[key] = nil
	end
end

--- True while we are still waiting on this requester's summary for any alt (for sendqueue).
function P2P:IsAwaitingSummary(requester)
	for key in pairs(self.stateWaits or {}) do
		if key:sub(1, #requester + 1) == requester .. "|" then return true end
	end
	return false
end

-- ─── Query Helpers ────────────────────────────────────────────────────────────

--- True if altName has an in-flight (DISPATCHED or ACTIVE) session.
function P2P:HasActiveSession(altName)
	local norm      = Norm(altName)
	local sessionId = self.sessionsByAlt[norm]
	if not sessionId then return false end
	local s = self.sessions[sessionId]
	return s ~= nil and (s.state == STATE.DISPATCHED or s.state == STATE.ACTIVE)
end

-- ─── Export ───────────────────────────────────────────────────────────────────
P2P.MAX_ACTIVE_SENDS = MAX_ACTIVE_SENDS   -- read by /togbank dev sendqueue
TOGBankClassic_P2PSession = P2P
