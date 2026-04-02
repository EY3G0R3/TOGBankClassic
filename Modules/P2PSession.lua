-- Modules/P2PSession.lua
-- P2P inventory sync session manager (P2P-006 redesign).
--
-- Replaces the banker-gated pull model with a broadcast/collect/dispatch loop:
--
--   Phase 1 (T+0):      Every player sends hash-list-broadcast to GUILD via SyncDeltaVersion.
--   Phase 2 (T+0..10s): Peers with NEWER data for any listed alt respond with a
--                        hash-offer whisper containing those alts' hashes + timestamps.
--   Phase 3 (T+10s):    Dispatch: for each stale alt, pick the peer with the highest
--                        updatedAt, send a sync-request whisper.
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
local SEND_TIMEOUT        = 90 -- seconds before auto-releasing an outbound send slot
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
P2P.catchUpTimer   = nil -- scheduled catch-up broadcast timer
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

--- Start (or extend) the 10-second collect window after broadcasting our hashes.
-- @param myHashes table: altName → {hash, updatedAt, ...}  (from BuildBankerHashList)
function P2P:BeginCollectWindow(myHashes) -- luacheck: ignore myHashes
	if self.isCollecting then
		-- Already open: just reset the deadline so late offers still count.
		if self.collectTimer then
			self.collectTimer:Cancel()
		end
		self.collectTimer = C_Timer.After(COLLECT_WINDOW, function()
			P2P:Dispatch()
		end)
		Dbg("OFFER", "Collect window extended (%ds)", COLLECT_WINDOW)
		return
	end

	self.isCollecting = true
	self.offers = {}
	self.collectTimer = C_Timer.After(COLLECT_WINDOW, function()
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
		if self.sessionsByAlt[item.altName] then
			-- A session was created for this alt by the time we process the list.
		elseif dispatched >= slots then
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
	s.timers.dispatch = C_Timer.After(DISPATCH_TIMEOUT, function()
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
	s.timers.delivery = C_Timer.After(60, function()
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
			s.timers.retry = C_Timer.After(RETRY_CYCLE_DELAY, function()
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

--- Try to acquire an outbound send slot for a given requester.
-- Returns true (slot incremented + safety timer set) if under cap; false if at cap.
-- Call ReleaseSendSlot on send completion; the safety timer is a no-op fallback.
function P2P:TryAcquireSendSlot(requester)
	local total = 0
	for _, count in pairs(self.activeSends) do
		total = total + count
	end
	if total >= MAX_ACTIVE_SENDS then
		return false
	end
	self.activeSends[requester] = (self.activeSends[requester] or 0) + 1
	Dbg("HANDSHAKE", "TryAcquireSendSlot: acquired for %s (total=%d)", requester, total + 1)
	C_Timer.After(SEND_TIMEOUT, function()
		P2P:ReleaseSendSlot(requester, "timeout")
	end)
	return true
end

--- Release an outbound send slot for a given requester.
-- Safe to call redundantly — the > 0 guard prevents underflow.
function P2P:ReleaseSendSlot(requester, reason)
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
		local total = 0
		for _, c in pairs(self.activeSends) do total = total + c end
		Dbg("HANDSHAKE", "HandleSyncRequest: at send cap (%d) - busy to %s for %s", total, requester, norm)
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
