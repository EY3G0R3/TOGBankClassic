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

local MAX_ACTIVE_SESSIONS = 3  -- max concurrent inbound data streams (requester side)
local MAX_ACTIVE_SENDS    = 3  -- max concurrent outbound sends (sender side)
local COLLECT_WINDOW      = 60 -- seconds to accumulate hash-offer responses (large guild congestion)
local DISPATCH_TIMEOUT    = 15 -- seconds to wait for sync-accept before next candidate (whisper congestion)
local DELIVERY_TIMEOUT    = 180 -- seconds before declaring a data delivery failed (must
                               --   exceed worst-case AceCommQueue drain time under load)
local SEND_TIMEOUT        = 210 -- seconds before auto-releasing an outbound send slot
                                --   (must be > DELIVERY_TIMEOUT so the safety release
                                --   never races with the delivery watchdog)
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

--- Called when a hash-offer whisper arrives from a peer.
-- @param peerName  string: normalized sender name
-- @param alts      table:  altName → {hash, updatedAt, mailHash}
function P2P:OnOffer(peerName, alts)
	if not alts then return end
	if not self.isCollecting then
		Dbg("OFFER", "OnOffer from %s ignored (not collecting)", tostring(peerName))
		return
	end

	for altName, summary in pairs(alts) do
		local norm = Norm(altName)
		-- Skip alts for which we already have a dispatched/active session.
		-- Skip alts not in our current guild's banker roster (prevents cross-guild bleed-in
		-- when a player's account SV contains data from another guild's bankers).
		if not self.sessionsByAlt[norm]
				and TOGBankClassic_Guild and TOGBankClassic_Guild:IsBank(norm) then
			self.offers[norm] = self.offers[norm] or {}
			local entry = {
				peer      = peerName,
				updatedAt = summary.updatedAt or 0,
				hash      = summary.hash      or 0,
				mailHash  = summary.mailHash  or 0,
			}
			-- Insert sorted by updatedAt descending so candidates[1] is always freshest.
			local inserted = false
			for i, existing in ipairs(self.offers[norm]) do
				if entry.updatedAt > existing.updatedAt then
					table.insert(self.offers[norm], i, entry)
					inserted = true
					break
				end
			end
			if not inserted then
				table.insert(self.offers[norm], entry)
			end
			Dbg("OFFER", "  offer: %s from %s (updatedAt=%s)", norm, peerName, tostring(summary.updatedAt))
			-- HASH-REFORM: Update latestBankerHashes with newest-wins so IsAltSyncPending
			-- drives tab colors correctly while the collect window is open.
			if TOGBankClassic_Guild then
				if not TOGBankClassic_Guild.latestBankerHashes then
					TOGBankClassic_Guild.latestBankerHashes = {}
				end
				local lbh = TOGBankClassic_Guild.latestBankerHashes[norm]
				if not lbh or entry.updatedAt > (lbh.updatedAt or 0) then
					TOGBankClassic_Guild.latestBankerHashes[norm] = {
						hash      = entry.hash,
						mailHash  = entry.mailHash,
						updatedAt = entry.updatedAt,
					}
					Dbg("OFFER", "  latestBankerHashes[%s] = hash=%08x updatedAt=%s", norm, entry.hash, tostring(entry.updatedAt))
				end
			end
		end
	end
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

	local altList = {}
	for altName, offerList in pairs(self.offers) do
		if #offerList > 0 and not self.sessionsByAlt[altName] then
			table.insert(altList, { altName = altName, candidates = offerList })
		end
	end

	if #altList == 0 then
		Dbg("DISPATCH", "Dispatch: no offers to dispatch")
		self:ScheduleCatchUp("no_offers")
		return
	end

	Dbg("DISPATCH", "Dispatch: %d alts with offers", #altList)
	self:DispatchList(altList)
	-- Refresh tab colors now that latestBankerHashes reflects the newest peer hashes
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
		TOGBankClassic_UI_Inventory:DrawContent()
	end
end

--- Schedule sessions from a list, respecting the active-session cap.
function P2P:DispatchList(altList)
	local slots = MAX_ACTIVE_SESSIONS - self.activeSessions
	if slots <= 0 then
		Dbg("DISPATCH", "DispatchList: at cap (%d active), queuing %d alts", self.activeSessions, #altList)
		for _, item in ipairs(altList) do
			table.insert(self.pendingDispatch, item)
		end
		return
	end

	local peerLoad   = {}
	local dispatched = 0

	for _, item in ipairs(altList) do
		-- Skip an alt that already gained a session while we were working through the list.
		-- Written as a negated guard rather than an empty `if ... then -- comment` branch, which
		-- reads as an unfinished thought and is what luacheck reports.
		if not self.sessionsByAlt[item.altName] then
			if dispatched >= slots then
				table.insert(self.pendingDispatch, item)
			else
				local peer = PickPeer(item.candidates, {}, peerLoad)
				if peer then
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
					dispatched = dispatched + 1
					Dbg("DISPATCH", "  → %s to %s (sid=%s)", item.altName, peer, sid)
				end
			end
		end
	end
end

function P2P:SendSyncRequest(sessionId)
	local s = self.sessions[sessionId]
	if not s then return end

	local payload = {
		type      = "sync-request",
		sessionId = sessionId,
		altName   = s.altName,
		requester = Me(),
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	TOGBankClassic_Core:SendWhisper("togbank-rr", data, s.peer, "NORMAL")

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
	end
end

--- Handle an incoming sync-request (we are the data provider).
-- Sends sync-accept if we have capacity and content; sync-busy otherwise.
-- Returns true if accepted.
function P2P:HandleSyncRequest(sessionId, requester, altName)
	if not sessionId or not requester or not altName then return false end

	local norm = Norm(altName)

	-- Verify we still have content for this alt (race guard).
	local myAlt = TOGBankClassic_Guild.Info
		and TOGBankClassic_Guild.Info.alts
		and TOGBankClassic_Guild.Info.alts[norm]
	if not myAlt or not TOGBankClassic_Guild:HasAltContent(myAlt, norm) then
		Dbg("HANDSHAKE", "HandleSyncRequest: no content for %s - busy to %s", norm, requester)
		local d = TOGBankClassic_Core:SerializeWithChecksum({ type = "sync-busy", sessionId = sessionId })
		TOGBankClassic_Core:SendWhisper("togbank-rr", d, requester, "NORMAL")
		return false
	end

	-- Acquire unified send slot (shared cap with old pull-based path via TryAcquireSendSlot).
	if not self:TryAcquireSendSlot(requester) then
		Dbg("HANDSHAKE", "HandleSyncRequest: at send cap (%d) - busy to %s for %s",
			self:GetActiveSendTotal(), requester, norm)
		local d = TOGBankClassic_Core:SerializeWithChecksum({ type = "sync-busy", sessionId = sessionId })
		TOGBankClassic_Core:SendWhisper("togbank-rr", d, requester, "NORMAL")
		return false
	end

	-- Accept.
	local d = TOGBankClassic_Core:SerializeWithChecksum({ type = "sync-accept", sessionId = sessionId })
	TOGBankClassic_Core:SendWhisper("togbank-rr", d, requester, "NORMAL")
	Dbg("HANDSHAKE", "HandleSyncRequest: accepted %s for %s", norm, requester)

	-- The requester will now send a togbank-state message to us, which the
	-- existing RespondToStateSummary pipeline handles automatically.
	return true
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
TOGBankClassic_P2PSession = P2P
