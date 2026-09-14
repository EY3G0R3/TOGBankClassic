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
--   Phase 4 (handshake): Peer replies sync-accept (has capacity) or sync-busy (does not hold
--                        it → try next candidate) or sync-queued (at cap → wait, or move on).
--   Phase 5 (data):      THE DELTA RELEASE step 3b -- on accept the requester asks on the
--                        DeltaSync host's QUERY channel, naming the canon it holds
--                        (Inventory/Sync.lua, RequestFrom); the peer answers on the RESPONSE
--                        channel with the delta chain, a snapshot, or a no-change. The
--                        togbank-state summary this replaced is gone.
--
-- LIBREQ-DS-008: the whole of this module (the numbered handshake, phases 1-4) moves INTO
-- DeltaSync as the library's P2P and this file is deleted when that ships. Phase 5 stays where it
-- is -- the library's data leg calls Inventory/Sync exactly as this file does.
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
-- The outbound send cap is Constants' (one spelling, Peer Review F2 2026-09-12); read at file scope
-- because Constants loads first, in the TOC and in every spec that loads this file.
local MAX_ACTIVE_SENDS    = TOGBankClassic_Constants.PEER_TO_PEER.MAX_ACTIVE_SENDS
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
-- MULTIPC-001: has this session's first broadcast/collect/query cycle SETTLED what the guild holds
-- for our own character? Until it has, Bank:Scan will not mint a version from a partial read (bags
-- alone, at a vendor), because a PC that shares the account may be weeks behind and cannot know it
-- until the peers answer. Set once, by Dispatch (no offer named us) or by the version query for our
-- own number finishing (a peer named a version -- newestAdvertisedAt now says whether it is newer),
-- or by Bank's own fallback timer if the cycle never runs. Never cleared within a session.
-- `consultBegun` is set the moment SyncDeltaVersion is CALLED (BeginConsult) -- before its
-- collision-guard defer, before the send -- and again when the collect window opens. Before that,
-- "unconsulted" would mean "not asked yet" rather than "asked and unanswered", and the gate does
-- not apply. The login call is made from the roster-ready callback, which is also the first moment
-- a scan can run at all (GetBanks needs the roster), so the gap is the frame between the two
-- (Peer Review, self-audit F2: it used to be roster-ready to window-open, unmeasured).
P2P.selfConsulted = false
P2P.consultBegun  = false

--- MULTIPC-001: the guild is about to be asked. Called at the top of Events:SyncDeltaVersion.
function P2P:BeginConsult()
	self.consultBegun = true
end

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
	self:BeginConsult()   -- MULTIPC-001: the guild has been asked; Bank's gate now waits on the answer
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
	-- WIRE-SKEW-006: AN OFFER FROM A PEER THAT CANNOT SERVE US IS REFUSED AT THE DOOR. Read off the
	-- operator's two v1.5.0 clients on 2026-09-12, holding the IDENTICAL canon for Cardsngames and
	-- "not syncing": every tab red. A bare offer turns the tab red (TABCOLOUR-003) and the version
	-- query is what clears it when nobody really holds newer; WIRE-SKEW-004 drops incapable holders
	-- BEFORE that query, so an alt every old-release peer offered went to DispatchList with no
	-- candidates, was skipped there, and nothing ever cleared the red -- credited to a v1.4.1 peer,
	-- for a bank we already held current. Forty old clients offer every bank on every cycle ("v1
	-- is always red": their compare is the revision-1 hash, which always differs), so this was every
	-- tab, permanently. Such a peer's "I hold newer" carries no information and names nothing we
	-- could fetch, so it is not an offer: not recorded, not folded into a session, no red.
	local G = TOGBankClassic_Guild
	if G and G.PeerSpeaksDataLeg then
		local ok, why = G:PeerSpeaksDataLeg(peerName)
		if not ok then
			Dbg("OFFER", "offer from %s ignored: release %s is before the data leg changed", tostring(peerName), tostring(why))
			return
		end
	end
	local late = not self.isCollecting
	local touched = {}

	for altName, summary in pairs(alts) do
		local norm = Norm(altName)
		-- P2P-035: a BARE offer -- a banker number and nothing else -- says "I hold newer" and names
		-- no version. It cannot be judged here; it is recorded as an unverified candidate and judged
		-- after the version query, by the same rule. An offer that carries a canon (a broadcast read
		-- as an offer, or a version reply folded in) is judged now.
		local bare = summary.hashV2 == nil and summary.hash == nil
		-- P2P-037: an offer for an alt with a LIVE session is not thrown away -- it teaches the
		-- session. Read off the banker account on 2026-09-10: Togstone was rescanned while Galdof's
		-- session for it was in flight; the post-scan broadcast (a canon-bearing offer) was skipped
		-- here, so the session kept naming the old version and could learn neither the new one nor
		-- that this peer held it. A canon-bearing offer that improves what we hold now adds or
		-- refreshes that peer among the session's candidates, so AdvanceCandidate / the retry can
		-- reach it. (A bare offer names nothing a session can use; it is still dropped here.)
		local liveSid = self.sessionsByAlt[norm]
		if liveSid and not bare and self.sessions[liveSid] and norm ~= Me()
				and TOGBankClassic_Guild and TOGBankClassic_Guild:IsBank(norm)
				and self:OfferIsUseful(norm, summary) then
			local s = self.sessions[liveSid]
			s.candidates = s.candidates or {}
			local found
			for _, c in ipairs(s.candidates) do if c.peer == peerName then found = c break end end
			if found then
				found.canon = summary.hashV2
				if (summary.updatedAt or 0) > (found.updatedAt or 0) then found.updatedAt = summary.updatedAt end
			else
				table.insert(s.candidates, { peer = peerName, canon = summary.hashV2,
					updatedAt = summary.updatedAt or 0, hash = summary.hash or 0, mailHash = summary.mailHash or 0 })
			end
			Dbg("OFFER", "  offer: %s from %s (%s) -- folded into live session %s", norm, peerName, tostring(summary.hashV2), liveSid)
			if not summary.cachedByBroadcast then
				if TOGBankClassic_Guild.NoteAdvertisedHashes then TOGBankClassic_Guild:NoteAdvertisedHashes(norm, summary, peerName) end
				if TOGBankClassic_Guild.NoteAdvertisedPublishTime then TOGBankClassic_Guild:NoteAdvertisedPublishTime(norm, summary, peerName) end
			end
		end
		-- Skip alts for which we already have a dispatched/active session.
		-- Skip alts not in our current guild's banker roster (prevents cross-guild bleed-in
		-- when a player's account SV contains data from another guild's bankers).
		-- MULTIPC-001: a BARE offer for OUR OWN number is let through to the version query. It is
		-- the reply to our own broadcast from a peer holding a version of our bank we did not
		-- advertise -- on a shared account played from several PCs, that is the only prompt signal
		-- this PC gets that it is behind on itself. The query names the version, which raises
		-- newestAdvertisedAt for our name (tab red, publish gate); FinishVersionQuery then stops,
		-- because AdvertisedImproves is "self" and nothing is ever FETCHED for our own name. A
		-- canon-bearing offer for self needs no query and is judged useless above, as before.
		if not self.sessionsByAlt[norm]
				and TOGBankClassic_Guild and TOGBankClassic_Guild:IsBank(norm)
				and (norm ~= Me() or bare)
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
			if bare then
				-- TABCOLOUR-003: the tab goes red on the offer itself, not on the data.
				if TOGBankClassic_Guild.NoteNewerOffered
					and TOGBankClassic_Guild:NoteNewerOffered(norm, peerName) then
					Dbg("OFFER", "  %s: %s offers newer -- tab red until it lands", norm, peerName)
				end
			elseif not summary.cachedByBroadcast then
				if TOGBankClassic_Guild.NoteAdvertisedHashes
					and TOGBankClassic_Guild:NoteAdvertisedHashes(norm, summary, peerName) then
					Dbg("OFFER", "  latestBankerHashes[%s] = hash=%08x updatedAt=%s", norm, entry.hash, tostring(entry.updatedAt))
				end
				if TOGBankClassic_Guild.NoteAdvertisedPublishTime then
					TOGBankClassic_Guild:NoteAdvertisedPublishTime(norm, summary, peerName)   -- TABCOLOUR-002
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
		-- WIRE-SKEW-004: DROP THE INCAPABLE HOLDERS HERE, not at dispatch. This filter used to run
		-- only in DispatchList, so a peer on the old release was still asked WHICH VERSION IT HOLDS
		-- (a whisper out and a reply back, five per alt per round), counted as a holder, and -- while
		-- its own version was still unknown to us -- picked as the peer to fetch from, costing a full
		-- dispatch timeout and then a five-round retry with 20s of backoff. With 40 of 42 clients on
		-- the old release that is the entire cycle doing nothing but timing out. Filtered here, an
		-- alt nobody capable holds simply has no candidates and resolves at once.
		item.candidates = self:CapableCandidates(item.candidates, norm)
		-- WIRE-SKEW-006: the filter emptied the list, so every offer for this alt came from a peer
		-- we will not ask -- one whose version was learned AFTER its offer got through OnOffer's
		-- door (VersionCheck and its broadcast both land during the same login burst). The red that
		-- offer raised would otherwise stand for the session, because the version query that clears
		-- it never opens for an empty list. Nobody we can hear from has claimed newer: yellow.
		if #item.candidates == 0 and TOGBankClassic_Guild and TOGBankClassic_Guild.ClearNewerOffered
				and TOGBankClassic_Guild:ClearNewerOffered(norm) then
			Dbg("DISPATCH", "%s: every offer came from a release before the data leg changed -- tab back to yellow", norm)
		end
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
		self:SendHandshake(peer, { type = "ver-query", n = BN:EncodeNumbers(numbers) })
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
	self:SendHandshake(sender, { type = "ver-reply", e = BN:EncodeEntries(entries) })
	Dbg("VERSION", "ver-query from %s: answered %d of %d", sender, #entries, #BN:DecodeNumbers(encoded))
end

--- A queried peer answered. Fill in what it holds; an alt whose author answered, or whose every
--- asked peer has answered, is judged at once rather than at the end of the window.
function P2P:OnVersionReply(sender, encoded)
	local BN = TOGBankClassic_BankerNumbers
	if not BN or not sender then return end
	local held = {}
	local G = TOGBankClassic_Guild
	for _, e in ipairs(BN:DecodeEntries(encoded)) do
		local name = BN:NameOf(e.number)
		if name then
			held[name] = e.canon
			-- TABCOLOUR-003: the reply is the first message on this path that NAMES the version, so
			-- it feeds the same two caches every other canon-bearing message does -- the tab's
			-- newest time (red by publish time, from here on) and the advertised-hash cache
			-- (`hashdump`'s `known`). Nothing else on the offer -> query -> fetch path did.
			local summary = { hashV2 = e.canon, updatedAt = TOGBankClassic_DeltaComms:CanonPublishTime(e.canon) }
			if G.NoteAdvertisedHashes then G:NoteAdvertisedHashes(name, summary, sender) end
			if G.NoteAdvertisedPublishTime then G:NoteAdvertisedPublishTime(name, summary, sender) end
			-- MULTIPC-002: the replier HOLDS every version it names, our own character's included --
			-- recorded HERE, where the version is learned, not in FinishVersionQuery (peer review A2).
			-- A LATE reply -- after the self query settled -- or a reply to a query about some other
			-- banker that also names ours raised the tab's newest time above without ever reaching
			-- FinishVersionQuery, so Bank knew it was behind and knew nobody to fetch from.
			if name == Me() and G.NoteSelfHolder then G:NoteSelfHolder(e.canon, sender) end
		end
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
	-- MULTIPC-001: the query for OUR OWN number ends here. Every reply already raised
	-- newestAdvertisedAt through OnVersionReply, so the tab and Bank:Scan's publish gate now know
	-- whether another PC published a later version of this character. Nothing is fetched for our
	-- own name; the remedy is a rescan on this PC. The cycle has answered, whatever it said.
	-- HIDE-SYNC-001: a queried peer that CANNOT answer is not "unanswered". A v1.4.1 client offers
	-- banker numbers but does not speak the version query, so it stays queried-and-silent for ever;
	-- with one such peer in the guild the own-bank check below never settled, every partial scan --
	-- a right-click hide, a vendor visit -- was held for the whole 180 s fallback, and CanServe
	-- refused our own record for the duration. Read off the operator's banker 2026-09-12: `consult:
	-- begun=true settled=false` fifteen minutes into a session, a hide "never syncing". The rule
	-- that a silent CAPABLE peer may still hold the newer version stands; a peer the addon already
	-- knows runs the old wire (Guild:ClaimantCanServe -> PeerSpeaksDataLeg) has given its answer by
	-- being what it is.
	local function stillWaiting(c)
		return c.queried and not c.answered and G:ClaimantCanServe(c.peer)
	end
	if norm == Me() then
		-- The same rule the other-alt branch below applies to the red tab (Peer Review, self-audit
		-- F1): a capable peer that went SILENT may still hold the newer version, so silence is not
		-- an answer. The gate stays closed until someone answers -- a late reply still raises
		-- newestAdvertisedAt through OnVersionReply -- or Bank's fallback releases it, which bounds
		-- the wait at DEFERRED_PUBLISH_FALLBACK seconds from the first deferred scan.
		local unanswered = false
		for _, c in ipairs(item.candidates) do
			if stillWaiting(c) then unanswered = true break end
		end
		if unanswered then
			Dbg("VERSION", "%s is us: a peer that offered newer never answered -- not settled", norm)
			return
		end
		-- MULTIPC-002: WHO holds the later version was recorded as each reply arrived (OnVersionReply
		-- -> Guild:NoteSelfHolder), so Bank can fetch it as its diff base when this PC has re-read
		-- everything (docs/DELTA_RELEASE.md section 3.5). Nothing to add here.
		-- WIRE-SKEW-008: this line used to read "a peer holds a LATER version" directly under a reply
		-- naming the SAME canon we hold, because the verdict is read off newestAdvertisedAt, not off
		-- the reply. Say who raised it and to what, so the next reader does not blame the replier.
		local newer = G.NewerSelfVersionAt and G:NewerSelfVersionAt()
		local by = newer and G.newestAdvertisedBy and G.newestAdvertisedBy[norm]
		Dbg("VERSION", "%s is us: %s", norm,
			newer and string.format("%s claims a version of this character published at %d, later than this PC's -- rescan to republish",
				(by and by.peer) or "a peer", newer)
			or "nobody holds anything newer than this PC")
		self:MarkSelfConsulted("version query answered")
		return
	end
	local live = {}
	for _, c in ipairs(item.candidates) do
		if c.canon and G:AdvertisedImproves(norm, { hashV2 = c.canon }) then live[#live + 1] = c end
	end
	if #live == 0 then
		Dbg("VERSION", "%s: nobody who offered holds a version newer than ours", norm)
		-- TABCOLOUR-003: the offer that turned the tab red has been checked and found empty (a peer
		-- whose scan had not finished, or a version no newer than ours). Back to yellow -- but ONLY
		-- when every peer we asked actually answered. A peer that went silent may still hold it,
		-- and the operator's rule is red "until we can get it", so an unanswered offer stays red
		-- for the next cycle to settle.
		local unanswered = false
		for _, c in ipairs(item.candidates) do
			if stillWaiting(c) then unanswered = true break end
		end
		if not unanswered and G.ClearNewerOffered then G:ClearNewerOffered(norm) end
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
		-- MULTIPC-001: the window closed and nobody offered anything, our own bank included.
		self:MarkSelfConsulted("collect window closed, no offers")
		self:ScheduleCatchUp("no_offers")
		return
	end

	Dbg("DISPATCH", "Dispatch: %d alts with offers", #altList)
	self:DispatchOrQuery(altList)
	-- MULTIPC-001: if an offer named OUR OWN number, DispatchOrQuery opened a version query for it
	-- and FinishVersionQuery will settle the latch; otherwise nobody claims to hold newer than us.
	if not self.versionQueries[Me()] then
		self:MarkSelfConsulted("collect window closed, nobody offered our own bank")
	end
	-- Refresh tab colors now that latestBankerHashes reflects the newest peer hashes. BROWSE-008:
	-- through RefreshSoon, the one fan-out that reaches the Guild Bank window as well (see Chat's
	-- broadcast batch, the other site that bypassed it).
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.RefreshSoon then
		TOGBankClassic_UI_Inventory:RefreshSoon()
	end
end

--- MULTIPC-001: the session's first cycle has said what the guild holds for our own character.
--- Idempotent; the first call releases a publish Bank:Scan deferred while waiting on it.
---@param reason string for the debug line
function P2P:MarkSelfConsulted(reason)
	if self.selfConsulted then return end
	self.selfConsulted = true
	Dbg("VERSION", "own-bank check settled (%s)", tostring(reason))
	if TOGBankClassic_Bank and TOGBankClassic_Bank.PublishIfDeferred then
		TOGBankClassic_Bank:PublishIfDeferred()
	end
end

--- MULTIPC-001: may a partial scan trust that nobody holds a newer version of our own bank? True
--- once the cycle has answered -- and also before it has been ASKED, because a window that has not
--- opened cannot be waited on (see `consultBegun`).
---@return boolean
function P2P:IsSelfConsulted()
	return self.selfConsulted == true or not self.consultBegun
end

--- How many of our fetch sessions are currently pointed at `peer`.
local function sessionsWith(self, peer)
	local n = 0
	for _, s in pairs(self.sessions) do
		if s.peer == peer and (s.state == STATE.DISPATCHED or s.state == STATE.ACTIVE) then n = n + 1 end
	end
	return n
end

--- WIRE-SKEW-001: the candidates that can complete the data leg with us (Guild:PeerSpeaksDataLeg).
--- Logged once per alt when something was dropped, so a bank nobody capable holds says so.
function P2P:CapableCandidates(candidates, altName)
	local G = TOGBankClassic_Guild
	if not (G and G.PeerSpeaksDataLeg) then return candidates or {} end
	local kept, dropped, sample = {}, 0, {}
	for _, c in ipairs(candidates or {}) do
		local ok, why = G:PeerSpeaksDataLeg(c.peer)
		if ok then
			kept[#kept + 1] = c
		else
			dropped = dropped + 1
			-- WIRE-SKEW-004: a COUNT and three names, never the whole list. This printed every
			-- dropped peer, and in a guild 40 clients deep on the old release that is a 40-name line
			-- per alt per cycle -- the operator's chat was unreadable and the real handshake lines
			-- were buried in it. Three is enough to recognise who, and the count is the fact.
			if #sample < 3 then sample[#sample + 1] = c.peer .. "(" .. tostring(why) .. ")" end
		end
	end
	if dropped > 0 then
		Dbg("DISPATCH", "%s: not asking %d holder(s) on a release before the data leg changed: %s%s",
			tostring(altName), dropped, table.concat(sample, ", "),
			dropped > #sample and (" +" .. (dropped - #sample) .. " more") or "")
	end
	return kept
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
		-- WIRE-SKEW-001: a holder on a release before the data leg changed accepts and then never
		-- answers our query (180 seconds each, per alt, per such peer). Not a candidate.
		item.candidates = self:CapableCandidates(item.candidates, item.altName)
		-- Skip an alt that already gained a session while we were working through the list.
		-- Written as a negated guard rather than an empty `if ... then -- comment` branch, which
		-- reads as an unfinished thought and is what luacheck reports.
		if not self.sessionsByAlt[item.altName] and #item.candidates > 0 then
			-- Candidates already busy with us count as tried for THIS pass; they become available
			-- again when their session completes and FlushPendingDispatch re-runs this.
			local busy = {}
			for _, c in ipairs(item.candidates or {}) do
				if (peerLoad[c.peer] or 0) >= MAX_SESSIONS_PER_PEER then busy[c.peer] = true end
			end
			local peer = PickPeer(item.candidates, busy, peerLoad)
			if not peer then
				-- One parked item per alt: the newest candidates replace the old. Every late offer
				-- (each peer's broadcast is one, per bank) re-ran this list while the holders were
				-- busy and parked the same alt again -- read off the operator's log as the same
				-- fourteen banks "asking" after every broadcast -- so the park grew without bound
				-- and FlushPendingDispatch walked hundreds of duplicates to open one session.
				local replaced = false
				for i, parked in ipairs(self.pendingDispatch) do
					if parked.altName == item.altName then self.pendingDispatch[i] = item; replaced = true; break end
				end
				if not replaced then table.insert(self.pendingDispatch, item) end
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
				Dbg("DISPATCH", "  -> %s to %s (sid=%s, with that peer: %d)", item.altName, peer, sid, sessionsWith(self, peer))
			end
		end
	end
end

--- EVERY handshake message this module sends goes out through here, on `togbank-rr` at ALERT.
--- P2P-031: the operator, "why don't we just make ack's a priority? it's a whisper, super fast."
--- Read off the live guild: a banker serving 13-chunk payloads and spraying kilobyte offers at
--- NORMAL could not get a 100-byte ACK out inside the requester's wait, and every request timed
--- out "no banker online" with the banker online. ChatThrottleLib splits its byte budget EQUALLY
--- among lanes with something to send, so the ALERT lane -- otherwise near-empty -- carries a
--- handshake in the next tick regardless of how much NORMAL and BULK is backed up.
--- Peer Review c6819531 F2: the prefix and the priority were twelve literals across this file and
--- two of them had drifted to NORMAL (the queue-drain busy, the queued-elsewhere cancel) -- one of
--- six paths at a different priority is the kind of thing a sync investigation cannot see. One
--- function, no literal at a call site, and the count in a comment is no longer a thing to go stale.
---@param to string the peer
---@param message table the payload, serialised with the checksum framing here
function P2P:SendHandshake(to, message)
	local data = TOGBankClassic_Core:SerializeWithChecksum(message)
	return TOGBankClassic_Core:SendWhisper("togbank-rr", data, to, "ALERT")
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
	self:SendHandshake(s.peer, {
		type      = "sync-request",
		sessionId = sessionId,
		altName   = s.altName,
		requester = Me(),
		canon     = canon,
	})

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
	-- P2P-038: an accept we cannot use -- the session is gone, or already ACTIVE with another peer
	-- (we advanced on a timeout or a queued reply and the first peer accepted after all) -- used to
	-- be logged and left. The peer had taken a slot for us and held it the full 30-second state-wait
	-- for a query that was never coming; read off the operator's clients on 2026-09-12 as a run of
	-- "wrong state ACTIVE" on one side and "No query from X within 30s of accept" on the other.
	-- Tell it, the same way a queued request is withdrawn: sync-cancel names the session, and the
	-- provider gives the slot back at once (DequeueSend / CancelAccept).
	if not s or s.state ~= STATE.DISPATCHED then
		Dbg("HANDSHAKE", "OnSyncAccept: %s from %s cannot be used (%s) - cancelling it", tostring(sessionId), sender,
			s and ("wrong state " .. tostring(s.state)) or "unknown session")
		self:SendHandshake(sender, { type = "sync-cancel", sessionId = sessionId })
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

	-- THE DELTA RELEASE step 3b: ask on the host's QUERY channel, naming the canon we hold, so the
	-- peer can answer with the links after it rather than the whole bank (Inventory/Sync.lua). A
	-- refused send (the peer went offline between accept and now) is left to the delivery watchdog
	-- above, which advances the session the way a silent peer always has.
	local norm = Norm(s.altName)
	TOGBankClassic_Inventory_Sync:RequestFrom(sender, norm)
end

--- Peer is at its concurrent-send cap; try the next candidate.
function P2P:OnSyncBusy(sessionId, sender)
	local s = self.sessions[sessionId]
	if not s then return end
	Dbg("HANDSHAKE", "BUSY: %s from %s - advancing", s.altName, sender)
	self:AdvanceCandidate(sessionId, "busy")
end

--- CHAIN-004: the provider refused our data QUERY for `altName` -- its accept had lapsed (the
--- 30-second state-wait) and it had no room to treat the query as a fresh one. Only the session
--- waiting on THAT peer advances; a refusal from a peer we have already moved on from is stale.
function P2P:OnQueryRefused(altName, sender)
	local norm = Norm(altName)
	local sid = self.sessionsByAlt[norm]
	local s = sid and self.sessions[sid]
	if s then
		if s.peer ~= sender or s.state ~= STATE.ACTIVE then return end
		Dbg("HANDSHAKE", "REFUSED: %s from %s (no room for our query) - advancing", norm, sender)
		self:AdvanceCandidate(sid, "query_refused")
		return
	end
	-- No session: the query came from the PULL path (a banker or relay ACK, Chat.lua). Peer Review
	-- F1: this refusal used to be heard and dropped. Forget the pull request the way its own
	-- timeouts do and let the catch-up ask again -- the 15-second "ACKed but never delivered" watch
	-- would reach the same place later; this is the same answer, now.
	local G = TOGBankClassic_Guild
	if G and G.ClearPendingP2PRequest then G:ClearPendingP2PRequest(norm) end
	Dbg("HANDSHAKE", "REFUSED: %s from %s (no room for our query, no session) - catch-up", norm, sender)
	local DB = TOGBankClassic_Database
	if G and G.Info and G.Info.name and DB and DB.RecordP2PBankerFallback then
		DB:RecordP2PBankerFallback(G.Info.name)
	end
	self:ScheduleCatchUp("query_refused")
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
	-- CHAIN-004: an ACTIVE session can advance now (a refused query), so the delivery watchdog armed
	-- for the peer being left goes too. Its ACTIVE guard already made a late fire harmless once the
	-- next peer's accept re-armed the slot; cancelling is simply the honest state.
	if s.timers.delivery then
		s.timers.delivery:Cancel()
		s.timers.delivery = nil
	end

	-- WIRE-SKEW-001: a candidate learned mid-session (OnOffer folds broadcasts into a live session)
	-- may be on the old release; it is dropped here the same way DispatchList drops it.
	s.candidates = self:CapableCandidates(s.candidates, s.altName)
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

--- Consume one ACCEPT for `requester`: true when it holds a send slot that no reply is serving
--- yet, and that slot is now marked serving. The data QUERY on the host is answered only when this
--- succeeds (CHAIN-003): the cap is enforced at accept time, so a QUERY that never went through the
--- handshake would be a BULK send outside it -- and a second QUERY inside one accept's window
--- (peer review A1) would be a second BULK send for one accept. A slot is ACCEPTED (granted by the
--- accept) then SERVING (claimed here); the count and the cap are untouched, and the release on
--- drain gives both back. Two accepts for one requester (two alts) are two passes.
function P2P:ClaimSendSlot(requester)
	self.servingSends = self.servingSends or {}
	local held, serving = self.activeSends[requester] or 0, self.servingSends[requester] or 0
	if held <= serving then return false end
	self.servingSends[requester] = serving + 1
	return true
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
		-- The serving mark goes back with the slot (ClaimSendSlot); a slot released before any QUERY
		-- claimed it (the state-wait, the safety timer) has nothing to give back here. Counts, not
		-- identities: with TWO accepts for one requester, one serving, a state-wait release of the
		-- unclaimed one also clears the mark -- the residual is one extra reply for that requester,
		-- which is what every accept used to allow.
		if self.servingSends and (self.servingSends[requester] or 0) > 0 then
			self.servingSends[requester] = self.servingSends[requester] - 1
		end
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
		self:SendHandshake(requester, { type = "sync-busy", sessionId = sessionId })
		return false
	end
	-- WIRE-SKEW-001: a requester on a release before the data leg changed would answer our accept
	-- with a state summary we no longer read, hold the slot for the whole state-wait and requeue --
	-- and with a guild of them, nobody who CAN complete ever reaches a slot. Busy, at once, and no
	-- queue position; its own build cannot get anything from us until it updates.
	local G = TOGBankClassic_Guild
	local capable, why = true, nil
	if G.PeerSpeaksDataLeg then capable, why = G:PeerSpeaksDataLeg(requester) end
	if not capable then
		Dbg("HANDSHAKE", "HandleSyncRequest: %s runs %s, before the data leg changed - busy (version skew)", requester, tostring(why))
		self:SendHandshake(requester, { type = "sync-busy", sessionId = sessionId, reason = "addon_version" })
		return false
	end
	-- P2P-035: the requester named the version it wants. P2P-037: we serve when we hold THAT version
	-- OR A LATER ONE -- what they want is the newest, and ours is newer still. Read off the banker
	-- account on 2026-09-10: Togstone was rescanned six seconds after Galdof learned its version, so
	-- Galdof asked for `...1707...`, the holder had `...1713...`, and an EXACT-match check answered
	-- `busy (version)` five times in a row to an idle holder with the better copy -- the requester's
	-- live session could not learn the new version either, because an offer for an alt with a live
	-- session is skipped. Refuse only when ours is OLDER than asked (a relay behind the author) or
	-- unreadable; the requester then moves to the next holder, as designed.
	if canon ~= nil then
		local mine = G.ServableCanon and G:ServableCanon(norm)
		local older = mine ~= canon and not (G.CanonIsNewer and G:CanonIsNewer(mine, canon))
		if older then
			Dbg("HANDSHAKE", "HandleSyncRequest: %s wants %s at %s, we hold %s - busy (version)", requester, norm, tostring(canon), tostring(mine))
			self:SendHandshake(requester, { type = "sync-busy", sessionId = sessionId, reason = "version" })
			return false
		elseif mine ~= canon then
			Dbg("HANDSHAKE", "HandleSyncRequest: %s wants %s at %s, we hold NEWER %s - serving ours", requester, norm, tostring(canon), tostring(mine))
		end
	end

	-- P2P-029: AT CAPACITY, QUEUE -- NEVER REFUSE. The operator, on the cap this replaced: "that 3
	-- was an arbitrary number ... make it so it 'buffers' all requests and then has only 3 open
	-- responses, so nothing gets dropped." And on why the cap existed: "to force the P2P in a busy
	-- guild, so one player wasn't getting hammered." Both hold: the reply carries the requester's
	-- queue position, and a requester with ANOTHER untried peer moves on (and cancels here), so
	-- load still spreads; a requester with nobody else to ask waits here and is served in turn.
	-- Refusing was the storm -- every refused requester retried every peer.
	-- ONE DELIBERATE EXCEPTION, written where the rule is so the two cannot be read apart: a data
	-- QUERY whose accept LAPSED (Sync:OnDataRequest, CHAIN-004) is refused at capacity rather than
	-- queued -- that requester was already accepted once and waited the state-wait out, and the
	-- QUERY carries no session id to queue under. The reasoning is at that site.
	if self:GetActiveSendTotal() >= MAX_ACTIVE_SENDS then
		local position = self:EnqueueSend(sessionId, requester, norm)
		Dbg("HANDSHAKE", "HandleSyncRequest: at capacity (%d) - queued %s for %s at position %d",
			self:GetActiveSendTotal(), requester, norm, position)
		self:SendHandshake(requester, { type = "sync-queued", sessionId = sessionId, position = position })
		return false
	end

	return self:AcceptSend(sessionId, requester, norm)
end

--- Take a slot and send the accept. The requester then asks on the host's QUERY channel, naming the
--- canon it holds, and Inventory/Sync's OnDataRequest answers; every outcome there (no-change, a
--- reply that has drained, a refused send), or the state-wait below, frees the slot.
function P2P:AcceptSend(sessionId, requester, norm)
	if not self:TryAcquireSendSlot(requester) then return false end
	self:SendHandshake(requester, { type = "sync-accept", sessionId = sessionId })
	Dbg("HANDSHAKE", "HandleSyncRequest: accepted %s for %s", norm, requester)
	self:ArmStateWait(requester, norm, sessionId)
	return true
end

--- P2P-038: the requester withdrew a session we ACCEPTED (its sync-cancel names the session id). If
--- the accept is still waiting on its query, the wait ends and the slot goes back now rather than
--- when the 30-second wait expires; an accept whose query already arrived is in Sync's hands and
--- releases on drain as before. Called beside DequeueSend from the sync-cancel handler.
function P2P:CancelAccept(sessionId, requester)
	local key = self.stateWaitSids and sessionId and self.stateWaitSids[sessionId]
	if not key then return false end
	self.stateWaitSids[sessionId] = nil
	local t = self.stateWaits and self.stateWaits[key]
	if not t then return false end
	t:Cancel()
	self.stateWaits[key] = nil
	Dbg("HANDSHAKE", "Accept for %s withdrawn by %s before its query - releasing slot", key, tostring(requester))
	self:ReleaseSendSlot(requester, "accept_cancelled")
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
			-- WIRE-SKEW-005: THE SECOND DOOR INTO AcceptSend, and it had no version gate on it.
			-- HandleSyncRequest refuses an old-release requester before it can take a slot, but a
			-- requester QUEUED while we were at capacity comes back through here instead, and this
			-- path only ever re-checked whether the content still exists. So an old peer sat in the
			-- queue, a slot freed, it was accepted, and it burned the whole 30-second state-wait
			-- before releasing -- `no_state_summary`. Read off the operator's live log 2026-09-12:
			-- Cinia, Zurayli, Groucho and Bilgoth each appear REFUSED on one line and ACCEPTED on
			-- another, and every accept follows a ReleaseSendSlot -- that is this drain. The queue
			-- can hold entries from before we learned the peer's version, so re-checking at drain
			-- time is the only place that catches them.
			local capable, why = true, nil
			local G = TOGBankClassic_Guild
			if G.PeerSpeaksDataLeg then capable, why = G:PeerSpeaksDataLeg(e.requester) end
			if not capable then
				Dbg("HANDSHAKE", "ServeQueue: %s runs %s, before the data leg changed - busy (version skew)",
					e.requester, tostring(why))
				self:SendHandshake(e.requester, { type = "sync-busy", sessionId = e.sessionId, reason = "addon_version" })
			elseif TOGBankClassic_Guild:CanServe(e.altName) then
				self:AcceptSend(e.sessionId, e.requester, e.altName)
			else
				-- Content went away while they waited (a wipe): the honest answer is the same one
				-- HandleSyncRequest gives, so their session advances rather than hangs.
				self:SendHandshake(e.requester, { type = "sync-busy", sessionId = e.sessionId })
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
		self:SendHandshake(sender, { type = "sync-cancel", sessionId = sessionId })
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

-- P2P-028: an accept that is never followed by the requester's QUERY (its "state": the canon it
-- holds) -- their session timed out first, they logged off, the whisper was lost -- used to hold
-- the slot for the full 210-second safety timer, which is sized for a large payload in flight, not
-- for a handshake that went nowhere. Read off two live clients: with a guild's worth of requesters
-- and three slots, that alone kept the banker permanently "busy". The query follows an accept
-- within seconds when it is coming at all, so the wait is short; Sync:OnDataRequest cancels it on
-- arrival through StateSummaryArrived.
local STATE_WAIT = 30

--- Arm the short wait for a requester's query after we accepted its sync-request.
--- Keyed by requester AND alt (self-audit F2): two accepts to one requester inside the window are
--- two waits, and one summary cancels only its own -- keyed by requester alone, the second accept
--- cancelled the first's wait and one summary cancelled whichever wait was left.
---@param sessionId string|nil the accepted session, so a sync-cancel naming it can find this wait
function P2P:ArmStateWait(requester, norm, sessionId)
	self.stateWaits = self.stateWaits or {}
	self.stateWaitSids = self.stateWaitSids or {}
	local key = requester .. "|" .. tostring(norm)
	local prior = self.stateWaits[key]
	if prior then prior:Cancel() end
	if sessionId then self.stateWaitSids[sessionId] = key end
	self.stateWaits[key] = C_Timer.NewTimer(STATE_WAIT, function()
		if P2P.stateWaits then P2P.stateWaits[key] = nil end
		P2P:ForgetStateWaitSids(key)
		Dbg("HANDSHAKE", "No query from %s for %s within %ds of accept - releasing slot", requester, tostring(norm), STATE_WAIT)
		-- WIRE-SKEW-007: the silence IS the evidence. A capable requester's query follows the accept
		-- within seconds; thirty of nothing is the old wire (its summary lost, or a build that never
		-- sent one). Remembered, so its next request is refused at the door rather than given a slot
		-- to sit in for another thirty. KNOWN COST: a capable peer whose query was genuinely lost is
		-- refused until VersionCheck or its own broadcast names its version, which both happen
		-- within the login burst -- and a known claim outranks this mark.
		if TOGBankClassic_Guild and TOGBankClassic_Guild.NotePeerOldWire
				and TOGBankClassic_Guild:NotePeerOldWire(requester, "silent") then
			Dbg("HANDSHAKE", "%s answered an accept with silence - treated as the old wire until its version says otherwise", requester)
		end
		P2P:ReleaseSendSlot(requester, "no_state_summary")
	end)
end

--- WIRE-SKEW-007: a `togbank-state` summary arrived -- the message a v1.4.1 requester whispers after
--- our accept, which a v1.5.0 requester never sends (it asks on the host's QUERY channel). The
--- prefix is registered for exactly this and nothing in it is read: the SENDER is the fact. Every
--- accept still waiting on that requester's query is released now, not at the end of the 30-second
--- wait, and the peer is remembered so its next request costs nothing.
---@param requester string normalized sender
function P2P:OnOldWireSummary(requester)
	if not requester then return end
	local G = TOGBankClassic_Guild
	if G and G.NotePeerOldWire and G:NotePeerOldWire(requester, "state-summary") then
		Dbg("HANDSHAKE", "%s sent a togbank-state summary: it runs the old wire - refused from here on", requester)
	end
	local prefix = requester .. "|"
	-- WIRE-SKEW-009: collect first, release after. ReleaseSendSlot can dispatch the next queued
	-- send, which ADDS a wait to this table -- inserting during pairs() is undefined in Lua and
	-- raised "invalid key to 'next'" 15 times on the operator's banker (Bellow's summary, 2026-09-12).
	local matched = {}
	for key, t in pairs(self.stateWaits or {}) do
		if key:sub(1, #prefix) == prefix then matched[#matched + 1] = { key = key, timer = t } end
	end
	local released = 0
	for _, m in ipairs(matched) do
		m.timer:Cancel()
		self.stateWaits[m.key] = nil
		self:ForgetStateWaitSids(m.key)
		self:ReleaseSendSlot(requester, "old_wire")
		released = released + 1
	end
	if released > 0 then
		Dbg("HANDSHAKE", "Released %d accept(s) held for %s at once rather than after the %ds wait", released, requester, STATE_WAIT)
	end
end

--- Drop every session id that pointed at a wait that has ended.
function P2P:ForgetStateWaitSids(key)
	for sid, k in pairs(self.stateWaitSids or {}) do
		if k == key then self.stateWaitSids[sid] = nil end
	end
end

--- The requester's query arrived: the send is now in Sync:OnDataRequest's hands, and every outcome
--- there releases the slot itself.
function P2P:StateSummaryArrived(requester, norm)
	local key = requester .. "|" .. tostring(norm)
	local t = self.stateWaits and self.stateWaits[key]
	if t then
		t:Cancel()
		self.stateWaits[key] = nil
	end
	self:ForgetStateWaitSids(key)
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
