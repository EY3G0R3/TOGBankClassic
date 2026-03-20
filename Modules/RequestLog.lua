TOGBankClassic_Guild = TOGBankClassic_Guild or {}
local Guild = TOGBankClassic_Guild

-- Throttle warnings to prevent spam (only warn once per session per type)
local warnedAbout = {
	invalidRequestVersion = false,
	corruptedTimestamps = {},  -- Track by request ID
}

-- Queue for staggered by-id batch sends (requester side).
-- byIdQueueGen is bumped when sender changes; stale C_Timer callbacks check it and
-- exit silently (C_Timer has no cancel API in Classic Era).
-- byIdDraining is true while a timer is pending; EnqueueByIdBatches skips re-firing
-- the drain when the same sender sends multiple index chunks.
-- byIdCurrentSender tracks who we are querying so we can accumulate across chunks.
local byIdQueue = {}
local byIdQueueGen = 0
local byIdDraining = false
local byIdCurrentSender = nil

-- Pending by-id response map (responder side).
-- Maps requestId -> querier (player name, or "*" for guild broadcast).
-- Deduplication rules when a new query arrives for an ID already in the map:
--   same querier  -> silent duplicate, skip
--   new querier   -> upgrade to "*" (multiple people need it, broadcast to guild)
--   already "*"   -> no change
-- A CTL-aware drain sends batches of RESPOND_BY_ID_BATCH_SIZE IDs per tick (one send per tick).
-- Sending is gated on ChatThrottleLib queue depth <= RESPOND_BY_ID_CTL_THRESHOLD.
local queriedRequestsMap  = {}   -- [requestId] -> querier
local queriedRequestsDraining = false


local function ctlDepthForDrain()
	local ctl = _G.ChatThrottleLib
	if not ctl or not ctl.Prio then return 0 end
	local n = 0
	local function walkRing(ring)
		if not ring or not ring.pos then return end
		local pipe = ring.pos
		repeat n = n + #pipe; pipe = pipe.next until pipe == ring.pos
	end
	for _, prio in pairs(ctl.Prio) do
		walkRing(prio.Ring)
		walkRing(prio.Blocked)
	end
	return n
end

-- togbank-ri: positional index wire format (version 1)
-- {RI_VERSION, liveCount, id1, updatedAt1, ...[liveCount pairs]..., tombId1, tombTs1, ...}
-- First liveCount stride-2 pairs are live entries; remaining stride-2 pairs are tombstones.
local RI_VERSION  = 1
local RD2_VERSION = 1

-- togbank-rd2: positional single-record wire format (version 1)
-- Full record:  {RD2_VERSION, id, date, updatedAt, requester, bank, item, quantity, fulfilled, status, notes}
-- Tombstone:    {RD2_VERSION, id, false, tombstoneTs}
-- Receiver distinguishes by type(arr[3]): number = record, false = tombstone.

local function serializeRequestV1(req)
	return {
		RD2_VERSION,
		req.id,
		req.date,
		req.updatedAt,
		req.requester,
		req.bank,
		req.item,
		req.quantity,
		req.fulfilled,
		req.status,
		req.notes or "",
	}
end

local function serializeTombstoneV1(id, ts)
	return { RD2_VERSION, id, false, ts }
end

local function drainQueriedRequests()
	queriedRequestsDraining = false
	if not next(queriedRequestsMap) then return end

	local info = Guild.Info
	if not info then
		queriedRequestsMap = {}
		return
	end

	if ctlDepthForDrain() > REQUESTS_SYNC.RESPOND_BY_ID_CTL_THRESHOLD then
		queriedRequestsDraining = true
		C_Timer.After(REQUESTS_SYNC.RESPOND_BY_ID_DRAIN_BACKOFF, drainQueriedRequests)
		return
	end

	-- Pick the first target encountered and collect up to RESPOND_BY_ID_BATCH_SIZE IDs for it.
	-- One tick = one send: CTL check maps 1:1 to one enqueue.
	local target, ids = nil, {}
	for id, t in pairs(queriedRequestsMap) do
		if target == nil then target = t end
		if t == target then
			table.insert(ids, id)
			if #ids >= REQUESTS_SYNC.RESPOND_BY_ID_BATCH_SIZE then break end
		end
	end

	-- Send one togbank-rd2 message per record/tombstone.
	local sent = 0
	local dest = target == "*" and "GUILD" or target
	for _, id in ipairs(ids) do
		local req = info.requests and info.requests[id]
		local payload, data
		if req then
			payload = serializeRequestV1(req)
			data    = TOGBankClassic_Core:SerializeWithChecksum(payload)
			if target == "*" then
				TOGBankClassic_Core:SendCommMessage("togbank-rd2", data, "Guild", nil, "NORMAL")
			else
				TOGBankClassic_Core:SendWhisper("togbank-rd2", data, target, "NORMAL")
			end
			sent = sent + 1
		else
			local ts = tonumber((info.requestsTombstones or {})[id] or 0) or 0
			if ts > 0 then
				payload = serializeTombstoneV1(id, ts)
				data    = TOGBankClassic_Core:SerializeWithChecksum(payload)
				if target == "*" then
					TOGBankClassic_Core:SendCommMessage("togbank-rd2", data, "Guild", nil, "NORMAL")
				else
					TOGBankClassic_Core:SendWhisper("togbank-rd2", data, target, "NORMAL")
				end
				sent = sent + 1
			end
		end
		queriedRequestsMap[id] = nil
	end
	if sent > 0 then
		TOGBankClassic_Output:Debug("REQUESTS", "PROTO2",
			"Drain: sent %d togbank-rd2 message(s) to %s", sent, dest)
	end

	if next(queriedRequestsMap) then
		queriedRequestsDraining = true
		C_Timer.After(REQUESTS_SYNC.RESPOND_BY_ID_DRAIN_INTERVAL, drainQueriedRequests)
	else
		TOGBankClassic_Output:Debug("REQUESTS", "PROTO2", "Queried requests map fully drained")
	end
end

local function startDrainQueriedRequests()
	if not queriedRequestsDraining then
		queriedRequestsDraining = true
		C_Timer.After(0, drainQueriedRequests)
	end
end

local function drainByIdQueue(gen)
	byIdDraining = false
	if gen ~= byIdQueueGen then return end  -- stale callback from a previous sync; abort
	if #byIdQueue == 0 then return end

	local item = table.remove(byIdQueue, 1)
	local remaining = #byIdQueue
	if Guild.requestsIndexSync then
		Guild.requestsIndexSync.batchSent = (Guild.requestsIndexSync.batchTotal or 0) - remaining
	end
	TOGBankClassic_Output:Debug("REQUESTS", "INDEX",
		"Sending by-id batch to %s (%d IDs, %d batch(es) remaining in queue)",
		tostring(item.sender), #item.ids, remaining)

	if not TOGBankClassic_Guild:QueryRequestsById(item.sender, item.ids) then
		TOGBankClassic_Output:Debug("REQUESTS", "INDEX",
			"QueryRequestsById send failed for %s -- aborting queue (%d batch(es) dropped)",
			tostring(item.sender), remaining)
		byIdQueue = {}
		byIdQueueGen = byIdQueueGen + 1
		byIdCurrentSender = nil
		TOGBankClassic_Guild:EndRequestsIndexSync()
		TOGBankClassic_Guild:RefreshRequestsUI()
		return
	end

	if remaining > 0 then
		byIdDraining = true
		C_Timer.After(REQUESTS_SYNC.REQUESTS_BY_ID_BATCH_DELAY, function()
			drainByIdQueue(gen)
		end)
	else
		byIdCurrentSender = nil
		TOGBankClassic_Output:Debug("REQUESTS", "INDEX",
			"By-id queue drained -- all batches sent to %s", tostring(item.sender))
	end
end

function Guild:EnqueueByIdBatches(sender, missingIds)
	-- If sender changed, cancel any in-progress drain and start fresh.
	-- Same sender: accumulate new batches (multiple index chunks arrive from one sender).
	if sender ~= byIdCurrentSender then
		byIdQueueGen = byIdQueueGen + 1
		byIdQueue = {}
		byIdCurrentSender = sender
		if Guild.requestsIndexSync then
			Guild.requestsIndexSync.batchTotal = 0
			Guild.requestsIndexSync.batchSent  = 0
		end
	end

	local batchSize = REQUESTS_SYNC.REQUESTS_BY_ID_BATCH_SIZE
	local newBatches = 0
	for batchStart = 1, #missingIds, batchSize do
		local batch = {}
		for i = batchStart, math.min(batchStart + batchSize - 1, #missingIds) do
			batch[#batch + 1] = missingIds[i]
		end
		byIdQueue[#byIdQueue + 1] = { sender = sender, ids = batch }
		newBatches = newBatches + 1
	end

	if Guild.requestsIndexSync then
		Guild.requestsIndexSync.batchTotal = (Guild.requestsIndexSync.batchTotal or 0) + newBatches
	end

	TOGBankClassic_Output:Debug("REQUESTS", "INDEX",
		"Queuing %d missing requests -> %d new batch(es) for %s (total queue: %d batch(es))",
		#missingIds, newBatches, tostring(sender), #byIdQueue)

	-- Start drain only if not already running (may be mid-drain from a previous chunk).
	if not byIdDraining then
		drainByIdQueue(byIdQueueGen)
	end
end

--[[
Request sync and storage
========================
This module owns the request lifecycle and synchronization rules. It attaches
methods to TOGBankClassic_Guild, but keeps the logic isolated from Guild.lua.

Data model (Guild.Info):
- requests: map of request ID -> request record (canonical state for UI/logic).
- requestsVersion: max updatedAt timestamp for quick freshness checks.
- requestsTombstones: map requestId -> delete timestamp.

Request record schema:
{
  id, date, updatedAt,
  requester, bank, item, quantity, fulfilled,
  status = "open" | "fulfilled" | "cancelled" | "complete",
  notes
}

Conflict resolution (merge-based sync):
- Each request is merged using last-writer-wins based on updatedAt.
- Tombstones win over requests with updatedAt <= tombstone timestamp.
- Fulfillment uses max() to ensure idempotency.

Sync flow:
- Version broadcast includes requestsVersion + requests hash.
- Full snapshots and by-id fetches are merged per-request.
- Mutations are broadcast as entries and applied directly.
]]

-- Request status constants.
local VALID_REQUEST_STATUS = {
	open = true,
	fulfilled = true,
	cancelled = true,
	complete = true,
}

-- Expiry/prune settings are defined in Constants.lua (REQUEST_LOG table)

local function deserializeRequestV1(arr)
	-- arr[3] is date (number) — caller must verify before calling this
	return {
		id        = arr[2],
		date      = tonumber(arr[3]),
		updatedAt = tonumber(arr[4]),
		requester = arr[5],
		bank      = arr[6],
		item      = arr[7],
		quantity  = tonumber(arr[8]),
		fulfilled = tonumber(arr[9]),
		status    = arr[10],
		notes     = tostring(arr[11] or ""),
	}
end

local function serializeIndexChunkV1(requestsSlice, tombstonesSlice)
	local arr = { RI_VERSION, #requestsSlice }
	for _, entry in ipairs(requestsSlice) do
		arr[#arr+1] = entry.id
		arr[#arr+1] = entry.updatedAt
	end
	for _, entry in ipairs(tombstonesSlice) do
		arr[#arr+1] = entry.id
		arr[#arr+1] = entry.deletedAt
	end
	return arr
end

local function deserializeIndexChunkV1(arr)
	local liveCount = tonumber(arr[2]) or 0
	local requests  = {}
	local tombstones = {}
	local pos = 3
	for _ = 1, liveCount do
		local id        = arr[pos]
		local updatedAt = arr[pos + 1]
		if id then
			requests[#requests+1] = { id = id, updatedAt = tonumber(updatedAt) or 0 }
		end
		pos = pos + 2
	end
	while arr[pos] do
		local id = arr[pos]
		local ts = arr[pos + 1]
		if id then
			tombstones[#tombstones+1] = { id = id, deletedAt = tonumber(ts) or 0 }
		end
		pos = pos + 2
	end
	return requests, tombstones
end

local function generateRequestId()
	local hi = math.random(0, 0xFFFFFF)
	local lo = math.random(0, 0xFFFFFF)
	local tail = math.random(0, 0xFF)
	return string.format("%06x%06x%02x", hi, lo, tail)
end

-- Normalize incoming request data and ensure required fields exist.
local function sanitizeRequest(req)
	if not req or type(req) ~= "table" then
		return nil
	end

	-- REJECT empty required fields (Phase 1 validation)
	local item = req.item and tostring(req.item) or ""
	if item == "" then
		TOGBankClassic_Output:Debug("REQUESTS", "Rejected request: empty item field")
		return nil
	end

	local requesterRaw = req.requester and tostring(req.requester) or ""
	if requesterRaw == "" or requesterRaw == "Unknown" then
		TOGBankClassic_Output:Debug("REQUESTS", "Rejected request: invalid requester '%s'", requesterRaw)
		return nil
	end

	local bankRaw = req.bank and tostring(req.bank) or ""
	if bankRaw == "" then
		TOGBankClassic_Output:Debug("REQUESTS", "Rejected request: empty bank field")
		return nil
	end

	local now = GetServerTime()

	local quantity = math.max(tonumber(req.quantity or 0) or 0, 0)
	if quantity == 0 then
		TOGBankClassic_Output:Debug("REQUESTS", "Rejected request: quantity is zero")
		return nil
	end

	-- REQSYNC-005: Removed ID-vs-item-name cross-check. The check parsed the ID by splitting on
	-- '-' and comparing the middle segment against req.item, but the current ID format is
	-- "Actor-Realm:xxxxxx" (colon-separated hex suffix), so the old dash-split parser never
	-- reaches its #idParts >= 5 gate on any current request and is permanently dead code.
	-- When the gate did trigger (legacy IDs), it false-positived on items with words <=3 chars
	-- (e.g. "Elixir of the Mongoose" → extracted "Elixir" only → silent drop). The other
	-- sanitizeRequest field validations (item, requester, bank, quantity) cover the actual
	-- corruption cases this was meant to catch.

	local fulfilled = math.max(tonumber(req.fulfilled or 0) or 0, 0)
	if quantity > 0 then
		fulfilled = math.min(fulfilled, quantity)
	end

	local bank = Guild:NormalizeName(bankRaw)
	local requester = Guild:NormalizeName(requesterRaw)

	-- Validate timestamps to prevent corruption (DATA-003)
	-- Max 32-bit signed integer (Jan 19, 2038) - any larger value is corrupted
	local MAX_TIMESTAMP = 2147483647
	local function validateTimestamp(ts, fallback)
		local num = tonumber(ts) or fallback
		-- If timestamp is too large (corrupted), use fallback instead
		if num > MAX_TIMESTAMP then
			return fallback
		end
		return num
	end

	local updatedAt = validateTimestamp(req.updatedAt or req.date or now, now)
	local dateVal = validateTimestamp(req.date or updatedAt, updatedAt)
	local status = req.status
	if not VALID_REQUEST_STATUS[status] then
		status = "open"
	end
	if quantity > 0 and fulfilled >= quantity and status ~= "cancelled" and status ~= "complete" then
		status = "fulfilled"
	end

	local id = req.id or generateRequestId()

	return {
		id = id,
		date = dateVal,
		updatedAt = updatedAt,
		requester = requester,
		bank = bank,
		item = item,
		quantity = quantity,
		fulfilled = fulfilled,
		status = status,
		notes = tostring(req.notes or ""),
	}
end

-- Expose normalization for other modules that need a safe view of request data.
function Guild:SanitizeRequest(req)
	return sanitizeRequest(req)
end

-- Request map helpers: internal storage is now a map keyed by request ID.
-- Wire format remains an array for backwards compatibility.
local function requestsToArray(map)
	local arr = {}
	for _, req in pairs(map or {}) do
		if req and req.id then
			table.insert(arr, req)
		end
	end
	return arr
end

local function requestsToMap(arr)
	local map = {}
	for _, req in ipairs(arr or {}) do
		if req and req.id then
			map[req.id] = req
		end
	end
	return map
end

local function countRequests(map)
	local n = 0
	for _ in pairs(map or {}) do
		n = n + 1
	end
	return n
end

-- Compute a stable hash of requests + tombstones for sync comparison.
local function computeRequestsHash(requests, tombstones)
	local parts = {}

	for id, req in pairs(requests or {}) do
		local updatedAt = tonumber(req.updatedAt or req.date or 0) or 0
		table.insert(parts, string.format("r:%s:%d", tostring(id), updatedAt))
	end

	for id, ts in pairs(tombstones or {}) do
		local deletedAt = tonumber(ts or 0) or 0
		if deletedAt > 0 then
			table.insert(parts, string.format("t:%s:%d", tostring(id), deletedAt))
		end
	end

	table.sort(parts)
	local combined = table.concat(parts, "|")
	local sum = 0
	local len = #combined
	for i = 1, len do
		local byte = string.byte(combined, i)
		sum = (sum * 31 + byte) % 2147483647
	end
	sum = (sum * 31 + len) % 2147483647
	return sum
end

-- Calculate requestsVersion as max updatedAt across all requests
local function calculateRequestsVersion(requests)
	local maxVersion = 0
	for _, req in pairs(requests or {}) do
		local updatedAt = tonumber(req.updatedAt or req.date or 0) or 0
		if updatedAt > maxVersion then
			maxVersion = updatedAt
		end
	end
	return maxVersion
end


-- Merge a single request using last-writer-wins.
-- Returns: "added", "updated", "kept", "tombstoned", or nil on error
local function mergeRequest(requests, tombstones, id, incoming)
	if not incoming or not id then
		TOGBankClassic_Output:Debug("SYNC", "mergeRequest: Invalid input (id=%s, incoming=%s)",
			tostring(id), tostring(incoming ~= nil))
		return nil
	end

	local clean = sanitizeRequest(incoming)
	if not clean then
		TOGBankClassic_Output:Debug("SYNC", "MERGE", "mergeRequest: sanitizeRequest failed for id=%s", tostring(id))
		return nil
	end

	local incomingTs = tonumber(clean.updatedAt or clean.date or 0) or 0
	local tombstoneTs = tonumber((tombstones or {})[id] or 0) or 0

	-- Check tombstone
	if tombstoneTs > 0 and incomingTs <= tombstoneTs then
		TOGBankClassic_Output:Debug("SYNC", "mergeRequest: TOMBSTONED - id=%s (tombstoneTs=%d, incomingTs=%d)",
			id, tombstoneTs, incomingTs)
		return "tombstoned"
	end

	-- REQUEST-RETIRE-002: Reject and tombstone expired done requests on receive.
	-- Peers with old clients never pruned their data and keep re-sending stale
	-- fulfilled/cancelled requests.  Creating a tombstone here means we propagate
	-- the deletion back to the sender on our next sync, self-healing the network.
	local incomingIsDone = clean.status == "fulfilled"
		or clean.status == "complete"
		or clean.status == "cancelled"
	if incomingIsDone and incomingTs > 0 then
		local now = GetServerTime()
		if (now - incomingTs) > REQUEST_LOG.EXPIRY_SECONDS then
			-- Backdate the tombstone to when the request actually expired so it
			-- doesn't linger for a full extra 30 days from now.
			tombstones[id] = incomingTs + REQUEST_LOG.EXPIRY_SECONDS
			TOGBankClassic_Output:Debug("SYNC",
				"mergeRequest: EXPIRED-TOMBSTONED - id=%s (status=%s, age=%dd)",
				id, clean.status, math.floor((now - incomingTs) / 86400))
			return "tombstoned"
		end
	end

	local existing = requests[id]
	if existing then
		local existingTs = tonumber(existing.updatedAt or existing.date or 0) or 0
		local existingIsTerminal = (existing.status == "cancelled" or existing.status == "complete")
		local incomingIsTerminal = (clean.status == "cancelled" or clean.status == "complete")

		if incomingTs > existingTs then
			if existingIsTerminal and not incomingIsTerminal then
				-- Ratchet: incoming has a higher updatedAt (e.g. a partial fulfillment that arrived
				-- after a cancel on a stale peer) but we must never revert a terminal status.
				-- Accept the incoming record's data fields but restore the terminal status and
				-- take the higher fulfilled count.
				local merged = {}
				for k, v in pairs(clean) do merged[k] = v end
				merged.status = existing.status
				merged.fulfilled = math.max(
					tonumber(clean.fulfilled or 0) or 0,
					tonumber(existing.fulfilled or 0) or 0
				)
				requests[id] = merged
				TOGBankClassic_Output:Debug("SYNC", "MERGE",
					"mergeRequest: RATCHET - kept terminal %s, advanced updatedAt %d->%d (id=%s)",
					existing.status, existingTs, incomingTs, id)
				return "updated"
			else
				requests[id] = clean
				TOGBankClassic_Output:Debug("SYNC", "MERGE",
					"mergeRequest: UPDATED - id=%s, status %s->%s, updatedAt %d->%d",
					id, existing.status, clean.status, existingTs, incomingTs)
				return "updated"
			end
		else
			TOGBankClassic_Output:Debug("SYNC", "MERGE",
				"mergeRequest: KEPT - id=%s (incoming older: %d <= %d)",
				id, incomingTs, existingTs)
			return "kept"
		end
	else
		requests[id] = clean
		TOGBankClassic_Output:Debug("SYNC", "MERGE",
			"mergeRequest: ADDED - id=%s, status=%s, updatedAt=%d",
			id, clean.status, incomingTs)
		return "added"
	end
end

-- Initialization and normalization.
function Guild:EnsureRequestsInitialized()
	if not self.Info then
		return
	end

	-- Initialize requests map
	if not self.Info.requests then
		self.Info.requests = {}
	end

	-- Migrate from array to map format if needed (detect by checking for numeric keys)
	if self.Info.requests[1] ~= nil then
		TOGBankClassic_Output:Debug("[MIGRATE] Converting requests from array to map format")
		self.Info.requests = requestsToMap(self.Info.requests)
	end

	-- Initialize tombstones
	if not self.Info.requestsTombstones then
		self.Info.requestsTombstones = {}
	end

	-- Migrate away from log-based storage (v0.9.0+)
	-- The log is no longer used - we now use simple delta-based sync
	if self.Info.requestLog or self.Info.requestLogSeq or self.Info.requestLogApplied then
		TOGBankClassic_Output:Debug("[MIGRATE] Removing deprecated request log data")
		self.Info.requestLog = nil
		self.Info.requestLogSeq = nil
		self.Info.requestLogApplied = nil
		-- Also clear legacy field names
		self.Info.requestsOps = nil
		self.Info.requestsOpSeq = nil
		self.Info.requestsOpApplied = nil
	end

	-- Clear runtime log indices (no longer used)
	self.requestLogIndex = nil
	self.requestLogByActor = nil

	-- Remove deprecated requestIdSeq (now using random IDs)
	if self.Info.requestIdSeq then
		self.Info.requestIdSeq = nil
	end

	-- Calculate version from requests if not set
	if not self.Info.requestsVersion or self.Info.requestsVersion == 0 then
		self.Info.requestsVersion = calculateRequestsVersion(self.Info.requests)
	end

	self:NormalizeRequestList()
end

-- Normalize stored requests and drop tombstoned entries.
function Guild:NormalizeRequestList()
	if not self.Info or not self.Info.requests then
		return
	end

	local before = countRequests(self.Info.requests)
	TOGBankClassic_Output:Debug(string.format("NormalizeRequestList: Starting with %d requests", before))

	local normalized = {}
	local tombstones = self.Info.requestsTombstones or {}
	local latest = tonumber(self.Info.requestsVersion or 0) or 0

	for id, req in pairs(self.Info.requests) do
		local clean = sanitizeRequest(req)
		if clean and clean.id then
			local tombstoneTs = tonumber(tombstones[clean.id] or 0) or 0
			if tombstoneTs > 0 and (tonumber(clean.updatedAt or 0) or 0) <= tombstoneTs then
				-- Skip entries that were deleted after their last update.
				TOGBankClassic_Output:Debug(string.format("NormalizeRequestList: Skipping tombstoned request id=%s", clean.id))
			else
				local existing = normalized[clean.id]
				if existing then
					local existingUpdated = tonumber(existing.updatedAt or existing.date or 0) or 0
					local incomingUpdated = tonumber(clean.updatedAt or clean.date or 0) or 0
					if incomingUpdated > existingUpdated then
						normalized[clean.id] = clean
						TOGBankClassic_Output:Debug(string.format("NormalizeRequestList: Updated duplicate id=%s", clean.id))
					end
				else
					normalized[clean.id] = clean
				end
				if clean.updatedAt and clean.updatedAt > latest then
					-- Validate timestamp to prevent corruption (DATA-003)
					local MAX_TIMESTAMP = 2147483647  -- Max 32-bit signed integer (Jan 19, 2038)
					if clean.updatedAt < MAX_TIMESTAMP then
						latest = clean.updatedAt
					else
						-- Only warn once per corrupted request ID to prevent spam
						if not warnedAbout.corruptedTimestamps[clean.id] then
							TOGBankClassic_Output:Warn("Skipping corrupted updatedAt timestamp %s for request id=%s", tostring(clean.updatedAt), tostring(clean.id))
							warnedAbout.corruptedTimestamps[clean.id] = true
						end
					end
				end
			end
		end
	end

	self.Info.requests = normalized
	self.Info.requestsVersion = latest

	local after = countRequests(normalized)
	TOGBankClassic_Output:Debug(string.format("NormalizeRequestList: Finished with %d requests (calling PruneRequests)", after))

	self:PruneRequests()
end

-- Tombstone pruning. Returns (pruned, before, after).
function Guild:PruneRequestTombstones()
	if not self.Info or not self.Info.requestsTombstones then
		return 0, 0, 0
	end
	local before = 0
	for _ in pairs(self.Info.requestsTombstones) do
		before = before + 1
	end
	local now = GetServerTime()
	local keep = {}
	for requestId, ts in pairs(self.Info.requestsTombstones) do
		local deletedAt = tonumber(ts or 0) or 0
		if deletedAt > 0 and (now - deletedAt) <= REQUEST_LOG.EXPIRY_SECONDS then
			keep[requestId] = deletedAt
		end
	end
	self.Info.requestsTombstones = keep
	local after = 0
	for _ in pairs(keep) do
		after = after + 1
	end
	return before - after, before, after
end

-- Throttled pruning: only runs if enough time has passed since last prune.
-- Returns true if pruning was performed, false if skipped.
function Guild:PruneIfNeeded()
	local now = GetServerTime()
	local lastPrune = self.lastPruneTime or 0
	if (now - lastPrune) < REQUEST_LOG.PRUNE_INTERVAL then
		return false
	end
	self.lastPruneTime = now
	self:PruneRequests()
	self:PruneRequestTombstones()
	return true
end

-- Snapshot application using merge-based sync (no log replay).
-- Each request is merged using last-writer-wins based on updatedAt.
function Guild:ApplyRequestSnapshot(payload)
	if not payload or type(payload) ~= "table" then
		TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: Invalid payload")
		return false
	end
	if not self.Info then
		TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: No Guild Info")
		return false
	end
	self:EnsureRequestsInitialized()

	local incomingList = payload.requests
	if not incomingList or type(incomingList) ~= "table" then
		TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: No requests in payload")
		return false
	end

	local requestCount = 0
	local iterFunc = incomingList[1] ~= nil and ipairs or pairs
	for _ in iterFunc(incomingList) do
		requestCount = requestCount + 1
	end

	TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: Merging %d incoming requests", requestCount)

	-- Merge incoming tombstones (keep most recent per ID)
	local tombstones = self.Info.requestsTombstones or {}
	for id, ts in pairs(payload.tombstones or {}) do
		local incomingTs = tonumber(ts or 0) or 0
		if incomingTs > (tonumber(tombstones[id] or 0) or 0) then
			tombstones[id] = incomingTs
		end
	end
	self.Info.requestsTombstones = tombstones

	-- Merge each incoming request using LWW
	local stats = { added = 0, updated = 0, kept = 0, tombstoned = 0 }
	for _, req in iterFunc(incomingList) do
		if req and req.id then
			local result = mergeRequest(self.Info.requests, tombstones, req.id, req)
			if result then
				stats[result] = (stats[result] or 0) + 1
			end
		end
	end

	-- Update version and clean up
	-- REQSYNC-004: NormalizeRequestList already calls PruneRequests internally;
	-- the explicit PruneRequests() call that was here was redundant and has been removed.
	self.Info.requestsVersion = calculateRequestsVersion(self.Info.requests)
	self:NormalizeRequestList()
	self:PruneRequestTombstones()
	self:RefreshRequestsUI()

	TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: Complete - added=%d, updated=%d, kept=%d, tombstoned=%d",
		stats.added, stats.updated, stats.kept, stats.tombstoned)
	return true
end

-- Request list pruning based on expiry. Returns (pruned, before, after).
function Guild:PruneRequests()
	if not self.Info or not self.Info.requests then
		return 0, 0, 0
	end

	local before = countRequests(self.Info.requests)
	local now = GetServerTime()
	local prunedCount = 0
	local latest = tonumber(self.Info.requestsVersion or 0) or 0

	TOGBankClassic_Output:Debug(string.format("PruneRequests: Starting with %d requests", before))

	for id, req in pairs(self.Info.requests) do
		local updated = tonumber(req.updatedAt or req.date or 0) or 0
		local quantity = tonumber(req.quantity or 0) or 0
		local fulfilled = tonumber(req.fulfilled or 0) or 0
		local isDone = req.status == "fulfilled"
			or req.status == "complete"
			or req.status == "cancelled"
			or (quantity > 0 and fulfilled >= quantity)
		local tooOld = isDone and (now - updated) > REQUEST_LOG.EXPIRY_SECONDS
		if tooOld then
			self.Info.requests[id] = nil
			prunedCount = prunedCount + 1
			TOGBankClassic_Output:Debug(string.format("PruneRequests: Pruning request id=%s, status=%s, age=%d seconds",
				req.id or "nil", req.status or "nil", now - updated))
		else
			if updated > latest then
				latest = updated
			end
		end
	end

	if prunedCount > 0 then
		TOGBankClassic_Output:Debug(string.format("PruneRequests: Pruned %d old completed requests", prunedCount))
	end

	self.Info.requestsVersion = latest
	local after = countRequests(self.Info.requests)

	TOGBankClassic_Output:Debug(string.format("PruneRequests: Finished with %d requests (%d pruned)", after, prunedCount))

	return prunedCount, before, after
end

-- Apply a mutation entry received from another player.
-- REQSYNC-001: sender is the WoW-verified character name from OnCommReceived.
-- Each mutation type is gated on the appropriate permission check.
function Guild:ApplyRequestMutation(entry, sender)
	if not entry or type(entry) ~= "table" or not self.Info then
		TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: Invalid entry or missing Guild Info")
		return false
	end
	self:EnsureRequestsInitialized()

	local entryType = entry.type
	local entryTs = tonumber(entry.ts or 0) or 0
	local requestId = entry.requestId or (entry.request and entry.request.id)
	if not entryType or not requestId then
		TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: Missing entryType or requestId (type=%s, id=%s)",
			tostring(entryType), tostring(requestId))
		return false
	end

	TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: type=%s, requestId=%s, ts=%d, sender=%s",
		entryType, requestId, entryTs, tostring(sender))

	-- REQSYNC-001: Normalize sender once for all checks below.
	-- sender is nil only for locally-applied mutations (no remote auth needed).
	local normSender = sender and self:NormalizeName(sender) or nil

	local tombstones = self.Info.requestsTombstones or {}

	-- Handle delete: remove request and record tombstone
	-- Permission: GM only (matches CanDeleteRequest)
	if entryType == "delete" then
		if normSender then
			local fakeReq = {}  -- CanDeleteRequest only needs actor+GM check, not req fields
			if not self:CanDeleteRequest(fakeReq, normSender) then
				TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: DELETE rejected - sender %s lacks permission", normSender)
				return false
			end
		end
		self.Info.requests[requestId] = nil
		local tombstoneTs = tonumber(tombstones[requestId] or 0) or 0
		if entryTs > tombstoneTs then
			tombstones[requestId] = entryTs
			self.Info.requestsTombstones = tombstones
		end
		TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: DELETE applied for id=%s", requestId)
		return true
	end

	-- Handle fulfill: idempotent delta application
	-- Permission: banker or GM only
	if entryType == "fulfill" then
		if normSender then
			if not (self:IsBank(normSender) or self:SenderIsGM(normSender)) then
				TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: FULFILL rejected - sender %s is not a banker or GM", normSender)
				return false
			end
		end
		local req = self.Info.requests[requestId]
		if not req or req.status == "cancelled" or req.status == "complete" then
			TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: FULFILL rejected (request not found or terminal state) id=%s", requestId)
			return false
		end
		local targetFulfilled = entry.targetFulfilled
		if targetFulfilled ~= nil then
			-- Idempotent: use max of current and target
			req.fulfilled = math.max(tonumber(req.fulfilled or 0) or 0, tonumber(targetFulfilled) or 0)
		else
			-- Legacy additive delta (backwards compat)
			local delta = tonumber(entry.delta or 0) or 0
			if delta > 0 then
				req.fulfilled = (tonumber(req.fulfilled or 0) or 0) + delta
			end
		end
		-- Clamp to quantity and update status if fully fulfilled
		local qty = tonumber(req.quantity or 0) or 0
		if qty > 0 then
			req.fulfilled = math.min(req.fulfilled, qty)
			if req.fulfilled >= qty and req.status ~= "cancelled" and req.status ~= "complete" then
				req.status = "fulfilled"
			end
		end
		if entryTs > 0 then
			req.updatedAt = math.max(tonumber(req.updatedAt or 0) or 0, entryTs)
		end
		TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: FULFILL applied for id=%s (fulfilled=%d)",
			requestId, req.fulfilled)
		return true
	end

	-- Handle add/cancel/complete: merge request snapshot using LWW
	if entry.request then
		-- REQSYNC-001: Auth checks per operation type before merging.
		if normSender then
			if entryType == "add" then
				-- Anyone can add, but the requester field must match the sender.
				local claimedRequester = entry.request.requester and self:NormalizeName(entry.request.requester)
				if claimedRequester and claimedRequester ~= normSender then
					TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: ADD rejected - sender %s claimed requester %s",
						normSender, claimedRequester)
					return false
				end
			elseif entryType == "cancel" then
				-- Requester (own request), officer, banker, or GM.
				-- Use existing req if we have it; fall back to the embedded snapshot.
				local reqForCheck = self.Info.requests[requestId] or entry.request
				if not self:CanCancelRequest(reqForCheck, normSender) then
					TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: CANCEL rejected - sender %s lacks permission for id=%s",
						normSender, requestId)
					return false
				end
			elseif entryType == "complete" then
				-- Banker or GM only.
				local reqForCheck = self.Info.requests[requestId] or entry.request
				if not self:CanCompleteRequest(reqForCheck, normSender) then
					TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: COMPLETE rejected - sender %s lacks permission for id=%s",
						normSender, requestId)
					return false
				end
			end
		end

		TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: Merging request snapshot type=%s, id=%s, status=%s, updatedAt=%s",
			entryType, requestId, tostring(entry.request.status), tostring(entry.request.updatedAt))

		local result = mergeRequest(self.Info.requests, tombstones, requestId, entry.request)

		TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: mergeRequest result=%s for type=%s, id=%s",
			tostring(result), entryType, requestId)

		return result == "added" or result == "updated"
	end

	TOGBankClassic_Output:Debug("SYNC", "ApplyRequestMutation: No action taken for type=%s, id=%s (no request data)",
		entryType, requestId)
	return false
end

-- Broadcast a request mutation to guild members.
-- mutation: { type, requestId, request (for add), delta/targetFulfilled (for fulfill) }
function Guild:BroadcastRequestMutation(mutation)
	if not mutation or type(mutation) ~= "table" then
		TOGBankClassic_Output:Debug("SYNC", "BroadcastRequestMutation: Invalid mutation (nil or not table)")
		return
	end
	local now = GetServerTime()
	local actor = self:GetNormalizedPlayer() or "unknown"
	-- Use timestamp as pseudo-seq for backwards compat with old clients that expect seq field
	local pseudoSeq = now
	local payload = {
		type = "requests-log",
		logEntries = {{
			type = mutation.type,
			actor = actor,
			seq = pseudoSeq,  -- Backwards compat: old clients expect seq field
			ts = now,
			id = string.format("%s:%d", actor, now),
			requestId = mutation.requestId,
			request = mutation.request,
			delta = mutation.delta,
			targetFulfilled = mutation.targetFulfilled,
		}}
	}

	TOGBankClassic_Output:Debug("SYNC", "BroadcastRequestMutation: Sending type=%s, requestId=%s, actor=%s, ts=%d, hasRequest=%s",
		tostring(mutation.type), tostring(mutation.requestId), actor, now, tostring(mutation.request ~= nil))

	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)

	TOGBankClassic_Output:Debug("SYNC", "BroadcastRequestMutation: Serialized payload, size=%d bytes, calling SendCommMessage", #data)

	-- SYNC-010: Use dedicated togbank-rm prefix for request mutations
	-- Separate throttle bucket from togbank-d prevents BULK snapshot syncs from blocking ALERT mutations
	local sendResult = TOGBankClassic_Core:SendCommMessage("togbank-rm", data, "Guild", nil, "ALERT")

	TOGBankClassic_Output:Debug("SYNC", "BroadcastRequestMutation: SendCommMessage returned %s for type=%s", tostring(sendResult), tostring(mutation.type))
end

-- After a local mutation, update version and refresh UI.
function Guild:FinalizeMutation(ts)
	self:TouchRequestsVersion(ts or GetServerTime())
	self:PruneIfNeeded()
	self:RefreshRequestsUI()
end

-- Version and UI helpers.
function Guild:TouchRequestsVersion(ts)
	if not self.Info then
		return
	end
	local current = tonumber(self.Info.requestsVersion or 0) or 0
	local incoming = tonumber(ts or GetServerTime()) or current
	if incoming > current then
		self.Info.requestsVersion = incoming
	end
end

function Guild:RefreshRequestsUI()
	TOGBankClassic_Output:Debug(string.format("RefreshRequestsUI called: isOpen=%s, requests=%d",
		tostring(TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.isOpen),
		self.Info and self.Info.requests and countRequests(self.Info.requests) or 0))

	if TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.isOpen then
		-- Recreate filters (including banker checkbox) when roster updates
		TOGBankClassic_UI_Requests:UpdateFilters()
		TOGBankClassic_UI_Requests:DrawContent()
	end
end

function Guild:EnsureRequestsIndexSyncState()
	if not self.requestsIndexSync then
		self.requestsIndexSync = {
			lastQueryAt = 0,
			perSender = {},
			inFlight = nil,
			inFlightSince = 0,
			awaitingById = false,
		}
	end
end

function Guild:CanQueryRequestsIndex(sender)
	self:EnsureRequestsIndexSyncState()
	local now = GetServerTime()
	local state = self.requestsIndexSync

	if state.inFlight then
		if (now - (state.inFlightSince or 0)) < REQUESTS_SYNC.INDEX_INFLIGHT_TIMEOUT then
			return false
		end
		state.inFlight = nil
		state.inFlightSince = 0
		state.awaitingById = false
	end

	if (now - (state.lastQueryAt or 0)) < REQUESTS_SYNC.INDEX_QUERY_COOLDOWN then
		return false
	end

	if sender and sender ~= "" then
		local last = state.perSender[sender]
		if last and (now - last) < REQUESTS_SYNC.INDEX_QUERY_COOLDOWN then
			return false
		end
	end

	return true
end

function Guild:BeginRequestsIndexSync(sender, force)
	if not force and not self:CanQueryRequestsIndex(sender) then
		return false
	end
	self:EnsureRequestsIndexSyncState()
	local now = GetServerTime()
	self.requestsIndexSync.lastQueryAt = now
	if sender and sender ~= "" then
		self.requestsIndexSync.perSender[sender] = now
	end
	self.requestsIndexSync.inFlight = sender or "*"
	self.requestsIndexSync.inFlightSince = now
	self.requestsIndexSync.awaitingById = false
	return true
end

function Guild:MarkRequestsIndexAwaitingById()
	self:EnsureRequestsIndexSyncState()
	self.requestsIndexSync.awaitingById = true
end

function Guild:EndRequestsIndexSync()
	self:EnsureRequestsIndexSyncState()
	self.requestsIndexSync.inFlight = nil
	self.requestsIndexSync.inFlightSince = 0
	self.requestsIndexSync.awaitingById = false
end

function Guild:GetRequestsHash()
	if not self.Info then
		return 0
	end
	self:EnsureRequestsInitialized()
	return computeRequestsHash(self.Info.requests, self.Info.requestsTombstones)
end

-- Snapshot sync messaging.
function Guild:GetRequestsVersion()
	if not self.Info then
		return 0
	end
	local version = tonumber(self.Info.requestsVersion or 0) or 0
	-- Validate version is within reasonable Unix timestamp range (2000-2038)
	-- Prevents integer overflow from corrupted data (DATA-003)
	local MIN_TIMESTAMP = 946684800  -- Jan 1, 2000
	local MAX_TIMESTAMP = 2147483647  -- Max 32-bit signed integer (Jan 19, 2038)
	if version ~= 0 and (version < MIN_TIMESTAMP or version > MAX_TIMESTAMP) then
		-- Only warn once per session to prevent spam
		if not warnedAbout.invalidRequestVersion then
			TOGBankClassic_Output:Warn("Invalid request version %s detected, resetting to 0", tostring(version))
			warnedAbout.invalidRequestVersion = true
		end
		self.Info.requestsVersion = 0  -- Actually fix the stored value
		return 0
	end
	return version
end

-- Request index query/response for hash-based sync.
function Guild:QueryRequestsIndex(target, priority, force)
	if not self:BeginRequestsIndexSync(target, force) then
		return false
	end
	local payload = {
		player = "*",
		type = "requests-index",
		version = self:GetRequestsVersion(),
		hash = self:GetRequestsHash(),
		addon = GetAddOnMetadata("TOGBankClassic", "Version") or "dev",
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	-- Send on old prefix for backwards compat; new clients listen on both
	if target and target ~= "" then
		if not TOGBankClassic_Core:SendWhisper("togbank-r", data, target, priority or "NORMAL") then
			self:EndRequestsIndexSync()
			return false
		end
	else
		TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, priority or "BULK")
		-- REQSYNC-003: Optimistic inFlight clear for wildcard broadcasts.
		-- SYNC-011 causes peers that already match our hash to stay silent, so
		-- EndRequestsIndexSync() is never called on a fully-synced guild, leaving
		-- inFlight set for the full INDEX_INFLIGHT_TIMEOUT (30s) and blocking any
		-- reactive re-query triggered by external events in that window.
		-- The timer fires after 10s; if a real response already cleared inFlight it
		-- is a no-op, so no explicit cancellation is needed.
		local syncStateAtBroadcast = self.requestsIndexSync
		C_Timer.After(10, function()
			if self.requestsIndexSync == syncStateAtBroadcast and self.requestsIndexSync.inFlight then
				TOGBankClassic_Output:Debug("SYNC", "QueryRequestsIndex: No index response in 10s (guild in sync) - clearing inFlight")
				self:EndRequestsIndexSync()
			end
		end)
	end
	return true
end

-- Coalescing index response: accumulate senders within a short window before sending.
-- Single sender -> whisper. Multiple different senders -> one guild broadcast.
local pendingIndexSenders   = nil   -- nil | player_name | "*"
local pendingIndexScheduled = false

-- Chunked index drain (sender side).
-- SendRequestsIndex enqueues N small chunk messages here instead of one large payload.
-- One chunk is sent per tick, gated on CTL depth so we don't stampede the queue.
local pendingIndexChunks = {}
local pendingIndexChunksDraining = false

local function drainIndexChunks()
	pendingIndexChunksDraining = false
	if not pendingIndexChunks[1] then return end
	if ctlDepthForDrain() > 20 then
		pendingIndexChunksDraining = true
		C_Timer.After(REQUESTS_SYNC.RESPOND_INDEX_CHUNK_INTERVAL, drainIndexChunks)
		return
	end
	local chunk = table.remove(pendingIndexChunks, 1)
	local data = TOGBankClassic_Core:SerializeWithChecksum(chunk.payload)
	local liveCount = chunk.payload[2] or 0
	TOGBankClassic_Output:Debug("REQUESTS", "PROTO2", "togbank-ri %d ids (+%d remaining chunks) to %s",
		liveCount, #pendingIndexChunks, chunk.target or "guild")
	if chunk.target then
		TOGBankClassic_Core:SendWhisper("togbank-ri", data, chunk.target, "NORMAL")
	else
		TOGBankClassic_Core:SendCommMessage("togbank-ri", data, "Guild", nil, "NORMAL")
	end
	if pendingIndexChunks[1] then
		pendingIndexChunksDraining = true
		C_Timer.After(REQUESTS_SYNC.RESPOND_INDEX_CHUNK_INTERVAL, drainIndexChunks)
	end
end

local function flushIndexQueue()
	pendingIndexScheduled = false
	local target = pendingIndexSenders
	if not target then return end

	-- Defer if CTL is busy or we're draining by-id responses.
	-- Reschedule and check again after the coalesce delay.
	local ctlDepth = ctlDepthForDrain()
	if ctlDepth > 20 or next(queriedRequestsMap) then
		TOGBankClassic_Output:Debug("REQUESTS", "INDEX",
			"flushIndexQueue: deferring index send (CTL=%d, by-id pending=%d)",
			ctlDepth, Guild:GetQueriedRequestsCount())
		pendingIndexScheduled = true
		C_Timer.After(REQUESTS_SYNC.RESPOND_INDEX_COALESCE_DELAY, flushIndexQueue)
		return
	end

	pendingIndexSenders = nil
	TOGBankClassic_Output:Debug("REQUESTS", "INDEX",
		"flushIndexQueue: sending index to %s", target == "*" and "GUILD" or target)
	Guild:SendRequestsIndex(target == "*" and nil or target)
end

function Guild:EnqueueIndexResponse(sender)
	if pendingIndexSenders == nil then
		pendingIndexSenders = sender
	elseif pendingIndexSenders ~= sender and pendingIndexSenders ~= "*" then
		TOGBankClassic_Output:Debug("REQUESTS", "INDEX",
			"EnqueueIndexResponse: upgrading to guild broadcast (%s + %s)", pendingIndexSenders, sender)
		pendingIndexSenders = "*"
	end
	-- duplicate sender or already "*": no change
	if not pendingIndexScheduled then
		pendingIndexScheduled = true
		C_Timer.After(REQUESTS_SYNC.RESPOND_INDEX_COALESCE_DELAY, flushIndexQueue)
	end
end

function Guild:SendRequestsIndex(target)
	if not self.Info then
		return
	end
	self:EnsureRequestsInitialized()
	self:NormalizeRequestList()

	local requestsIndex = {}
	for id, req in pairs(self.Info.requests or {}) do
		local updatedAt = tonumber(req.updatedAt or req.date or 0) or 0
		table.insert(requestsIndex, { id = id, updatedAt = updatedAt })
	end
	table.sort(requestsIndex, function(a, b)
		return tostring(a.id) < tostring(b.id)
	end)

	local tombstonesIndex = {}
	for id, ts in pairs(self.Info.requestsTombstones or {}) do
		local deletedAt = tonumber(ts or 0) or 0
		if deletedAt > 0 then
			table.insert(tombstonesIndex, { id = id, deletedAt = deletedAt })
		end
	end
	table.sort(tombstonesIndex, function(a, b)
		return tostring(a.id) < tostring(b.id)
	end)

	-- Send on togbank-ri (positional format v1). Chunked so the receiver can start
	-- querying before all chunks arrive. Tombstones go in the first chunk only.
	local chunkSize   = REQUESTS_SYNC.RESPOND_INDEX_CHUNK_SIZE
	local totalChunks = math.max(1, math.ceil(#requestsIndex / chunkSize))

	TOGBankClassic_Output:Debug("REQUESTS", "PROTO2",
		"Queuing requests-index to %s: %d requests + %d tombstones -> %d chunk(s) of %d",
		tostring(target or "guild"), #requestsIndex, #tombstonesIndex, totalChunks, chunkSize)

	for chunkNum = 1, totalChunks do
		local startIdx = (chunkNum - 1) * chunkSize + 1
		local endIdx   = math.min(chunkNum * chunkSize, #requestsIndex)
		local chunkRequests = {}
		for i = startIdx, endIdx do
			chunkRequests[#chunkRequests + 1] = requestsIndex[i]
		end
		local chunkTombstones = chunkNum == 1 and tombstonesIndex or {}
		local payload = serializeIndexChunkV1(chunkRequests, chunkTombstones)
		table.insert(pendingIndexChunks, { payload = payload, target = target })
	end

	if not pendingIndexChunksDraining then
		pendingIndexChunksDraining = true
		C_Timer.After(0, drainIndexChunks)
	end
end

function Guild:ReceiveRequestsIndex(payload, sender)
	if not payload or type(payload) ~= "table" then
		return
	end
	if not self.Info then
		return
	end
	self:EnsureRequestsInitialized()

	local incomingRequests = payload.requests
	local incomingTombstones = payload.tombstones
	if type(incomingRequests) ~= "table" then
		return
	end

	-- Apply tombstones from index and track for skip logic.
	local tombstonesMap = {}
	for _, entry in pairs(incomingTombstones or {}) do
		if entry and entry.id then
			local ts = tonumber(entry.deletedAt or entry.ts or 0) or 0
			if ts > 0 then
				tombstonesMap[entry.id] = ts
				local currentTs = tonumber((self.Info.requestsTombstones or {})[entry.id] or 0) or 0
				if ts > currentTs then
					self.Info.requestsTombstones = self.Info.requestsTombstones or {}
					self.Info.requestsTombstones[entry.id] = ts
				end
				local localReq = self.Info.requests[entry.id]
				if localReq then
					local localUpdated = tonumber(localReq.updatedAt or localReq.date or 0) or 0
					if localUpdated <= ts then
						self.Info.requests[entry.id] = nil
					end
				end
			end
		end
	end

	local missingIds = {}
	for _, entry in pairs(incomingRequests) do
		if entry and entry.id then
			local incomingUpdated = tonumber(entry.updatedAt or entry.date or 0) or 0
			local tombstoneTs = tombstonesMap[entry.id] or tonumber((self.Info.requestsTombstones or {})[entry.id] or 0) or 0
			if tombstoneTs > 0 and incomingUpdated <= tombstoneTs then
				-- Deleted entry, skip fetching
			else
				local localReq = self.Info.requests[entry.id]
				local localUpdated = localReq and (tonumber(localReq.updatedAt or localReq.date or 0) or 0) or 0
				if not localReq or localUpdated < incomingUpdated then
					table.insert(missingIds, entry.id)
				end
			end
		end
	end

	local localCount = 0
	for _ in pairs(self.Info.requests or {}) do localCount = localCount + 1 end
	TOGBankClassic_Output:Debug("REQUESTS", "INDEX",
		"ReceiveRequestsIndex from %s: peer has %d requests + %d tombstones, we have %d local, %d missing",
		tostring(sender),
		#incomingRequests,
		#(incomingTombstones or {}),
		localCount,
		#missingIds)

	if #missingIds > 0 then
		self:MarkRequestsIndexAwaitingById()
		self:EnqueueByIdBatches(sender, missingIds)
	else
		TOGBankClassic_Output:Debug("REQUESTS", "INDEX", "Already in sync with %s (0 missing)", tostring(sender))
		self:EndRequestsIndexSync()
		self:RefreshRequestsUI()
	end
end

-- Receive a togbank-ri positional index payload and dispatch to ReceiveRequestsIndex.
function Guild:ReceiveRequestsIndexV1(arr, sender)
	if not arr or type(arr) ~= "table" then return end
	local requests, tombstones = deserializeIndexChunkV1(arr)
	self:ReceiveRequestsIndex({ requests = requests, tombstones = tombstones }, sender)
end

-- Receive a single togbank-rd2 positional record or tombstone.
function Guild:ReceiveRequestsByIdV1(arr)
	if not arr or type(arr) ~= "table" then return end
	if not self.Info then return end
	self:EnsureRequestsInitialized()

	local id = arr[2]
	if not id then return end

	if arr[3] == false then
		-- Tombstone: {RD2_VERSION, id, false, tombstoneTs}
		local ts = tonumber(arr[4]) or 0
		if ts > 0 then
			self:ApplyRequestSnapshot({ requests = {}, tombstones = { [id] = ts } })
		end
	else
		-- Full record: {RD2_VERSION, id, date, updatedAt, requester, bank, item, quantity, fulfilled, status, notes}
		local req = deserializeRequestV1(arr)
		if req then
			self:ApplyRequestSnapshot({ requests = { req }, tombstones = {} })
		end
	end

	local shouldEndSync = self.requestsIndexSync and self.requestsIndexSync.awaitingById
	if shouldEndSync then self:EndRequestsIndexSync() end
end

function Guild:QueryRequestsById(target, ids, priority)
	if not ids or type(ids) ~= "table" or #ids == 0 then
		return false
	end
	TOGBankClassic_Output:Debug("REQUESTS", "INDEX",
		"Sending [REQ] requests-by-id to %s (%d IDs)", tostring(target), #ids)
	local payload = {
		player = "*",
		type = "requests-by-id",
		ids = ids,
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	-- Send on old prefix for backwards compat; new clients listen on both
	if target and target ~= "" then
		if not TOGBankClassic_Core:SendWhisper("togbank-r", data, target, priority or "NORMAL") then
			return false
		end
	else
		TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, priority or "BULK")
	end
	return true
end

function Guild:GetQueriedRequestsCount()
	local n = 0
	for _ in pairs(queriedRequestsMap) do n = n + 1 end
	return n
end

function Guild:EnqueueRequestsById(sender, ids)
	if not ids or type(ids) ~= "table" or #ids == 0 then return end
	if not self.Info then return end
	self:EnsureRequestsInitialized()

	local added, duped, upgraded = 0, 0, 0
	for _, id in ipairs(ids) do
		if id then
			local existing = queriedRequestsMap[id]
			if existing == nil then
				queriedRequestsMap[id] = sender
				added = added + 1
			elseif existing == sender then
				duped = duped + 1
			elseif existing ~= "*" then
				queriedRequestsMap[id] = "*"
				upgraded = upgraded + 1
			end
			-- existing == "*": already broadcasting, no change
		end
	end

	TOGBankClassic_Output:Debug("REQUESTS", "SEND",
		"EnqueueRequestsById from %s: +%d new, %d dupes ignored, %d upgraded to broadcast",
		tostring(sender), added, duped, upgraded)

	if added > 0 or upgraded > 0 then
		startDrainQueriedRequests()
	end
end

function Guild:ReceiveRequestsById(payload)
	-- Only clear inFlight if we're actually in the index-sync awaiting-by-id state.
	-- On-demand fetches (SYNC-013 fulfill race) must not stomp an unrelated index sync.
	local shouldEndSync = self.requestsIndexSync and self.requestsIndexSync.awaitingById

	if not payload or type(payload) ~= "table" then
		if shouldEndSync then self:EndRequestsIndexSync() end
		return ADOPTION_STATUS.INVALID
	end
	if not self.Info then
		return ADOPTION_STATUS.IGNORED
	end
	self:EnsureRequestsInitialized()

	local requests = payload.requests
	if not requests or type(requests) ~= "table" then
		if shouldEndSync then self:EndRequestsIndexSync() end
		return ADOPTION_STATUS.INVALID
	end

	TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE",
		"Received by-id response: %d requests", #requests)

	-- Always end sync regardless of whether snapshot merge succeeded.
	-- ApplyRequestSnapshot failing means empty/corrupt payload — either way we're done waiting.
	local adopted = self:ApplyRequestSnapshot({
		requests = requests,
		tombstones = payload.tombstones or {},
	})
	if shouldEndSync then self:EndRequestsIndexSync() end
	return adopted and ADOPTION_STATUS.ADOPTED or ADOPTION_STATUS.INVALID
end

--[[ COMMENTED OUT - togbank-v legacy protocol (request version already in togbank-dv2)
function Guild:SendRequestsVersionPing()
	if not self.Info then
		return
	end
	local payload = {
		requests = {
			version = self:GetRequestsVersion(),
			hash = self:GetRequestsHash(),
		},
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	TOGBankClassic_Core:SendCommMessage("togbank-v", data, "Guild", nil, "BULK")
end
--]]

-- Receive mutation entries from another player and apply them.
function Guild:ReceiveRequestMutations(payload, sender)
	if not payload or type(payload) ~= "table" then
		TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestMutations: Invalid payload from %s", tostring(sender))
		return
	end
	local entries = payload.logEntries
	if not entries or type(entries) ~= "table" then
		TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestMutations: No logEntries in payload from %s", tostring(sender))
		return
	end
	if not self.Info then
		TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestMutations: No Guild Info, ignoring mutations from %s", tostring(sender))
		return
	end
	self:EnsureRequestsInitialized()

	TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestMutations: Processing %d entries from %s", #entries, tostring(sender))

	local applied = 0
	local fetchIds = {}  -- IDs of unknown requests referenced by fulfill mutations
	for i, entry in ipairs(entries) do
		if entry and type(entry) == "table" then
			local entryType = entry.type or "unknown"
			local requestId = entry.requestId or (entry.request and entry.request.id) or "?"
			TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestMutations: Entry %d/%d: type=%s, requestId=%s",
				i, #entries, entryType, tostring(requestId))

			if self:ApplyRequestMutation(entry, sender) then
				applied = applied + 1
				TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestMutations: Entry %d APPLIED (type=%s, id=%s)",
					i, entryType, tostring(requestId))
			else
				TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestMutations: Entry %d REJECTED (type=%s, id=%s)",
					i, entryType, tostring(requestId))
				-- SYNC-013: If a fulfill mutation is rejected because we don't have the request
				-- locally, queue an immediate by-id fetch from the sender (the banker who just
				-- filled the order).  This closes the race where the by-id response was
				-- serialised before the fill happened, so it arrived with status="open".
				if entryType == "fulfill" and requestId and requestId ~= "?" then
					if not self.Info.requests[requestId] then
						TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestMutations: Queuing on-demand fetch for unknown request id=%s from %s", tostring(requestId), tostring(sender))
						table.insert(fetchIds, requestId)
					end
				end
			end
		end
	end

	-- Fire on-demand by-id fetch for any fulfill-referenced requests we don't have locally
	if #fetchIds > 0 and sender and sender ~= "" then
		TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestMutations: Fetching %d unknown request(s) from %s", #fetchIds, tostring(sender))
		self:QueryRequestsById(sender, fetchIds, "NORMAL")
	end

	if applied > 0 then
		TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestMutations: Applied %d/%d entries from %s",
			applied, #entries, tostring(sender))
		self:FinalizeMutation()
	else
		TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestMutations: No entries applied from %s", tostring(sender))
	end
end

-- Request mutation helpers.
function Guild:AddRequest(request)
	if not self.Info then
		return false
	end
	if not request or type(request) ~= "table" then
		return false
	end

	self:EnsureRequestsInitialized()

	local now = GetServerTime()
	request.date = request.date or now
	request.updatedAt = now
	request.status = request.status or "open"
	request.fulfilled = tonumber(request.fulfilled or 0) or 0

	if not request.id then
		request.id = generateRequestId()
	end

	local clean = sanitizeRequest(request)
	if not clean then
		return false
	end

	-- Store directly
	self.Info.requests[clean.id] = clean

	-- Broadcast and finalize
	self:BroadcastRequestMutation({ type = "add", requestId = clean.id, request = clean })
	self:FinalizeMutation(now)

	TOGBankClassic_Output:Debug(string.format("AddRequest: id=%s, item=%s, qty=%d",
		clean.id, clean.item or "", clean.quantity or 0))
	return true
end

-- Access control for requests.
-- REQSYNC-001: Replaced CanViewOfficerNote() (local-player check) with SenderIsOfficer(normActor)
-- so the check evaluates the *actor's* rank rather than the local player's rank.
function Guild:CanManageRequests(actor, actorIsGM)
	local normActor = self:NormalizeName(actor)

	if normActor and self.SenderIsOfficer and self:SenderIsOfficer(normActor) then
		return true
	end

	if normActor and self.IsBank and self:IsBank(normActor) then
		return true
	end

	if actorIsGM ~= nil then
		return actorIsGM
	end

	if normActor and self.SenderIsGM and self:SenderIsGM(normActor) then
		return true
	end

	return false
end

function Guild:CanCancelRequest(req, actor)
	if not req or type(req) ~= "table" then
		return false
	end

	local normActor = self:NormalizeName(actor or self:GetPlayer())
	local requester = self:NormalizeName(req.requester)

	if normActor and requester and normActor == requester then
		return true
	end

	return self:CanManageRequests(normActor)
end

function Guild:CanCompleteRequest(req, actor, actorIsGM)
	if not req or type(req) ~= "table" then
		return false
	end

	local normActor = self:NormalizeName(actor or self:GetPlayer())
	if not normActor then
		return false
	end

	local bank = self:NormalizeName(req.bank)
	if bank and bank ~= "" and normActor == bank then
		return true
	end

	if actorIsGM ~= nil then
		return actorIsGM
	end

	if self.SenderIsGM and self:SenderIsGM(normActor) then
		return true
	end

	return false
end

function Guild:CanDeleteRequest(req, actor, actorIsGM)
	if not req or type(req) ~= "table" then
		return false
	end

	local normActor = self:NormalizeName(actor or self:GetPlayer())
	if not normActor then
		return false
	end

	if actorIsGM ~= nil then
		return actorIsGM
	end

	if self.SenderIsGM and self:SenderIsGM(normActor) then
		return true
	end

	return false
end

function Guild:CancelRequest(requestId, actor)
	if not self.Info or not self.Info.requests or not requestId then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: Missing data (Info=%s, requests=%s, requestId=%s)",
			tostring(self.Info ~= nil), tostring(self.Info and self.Info.requests ~= nil), tostring(requestId))
		return false
	end

	local req = self.Info.requests[requestId]
	if not req then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: Request not found (id=%s)", tostring(requestId))
		return false
	end

	-- Can't cancel if already in terminal state
	local quantity = tonumber(req.quantity or 0) or 0
	local fulfilled = tonumber(req.fulfilled or 0) or 0
	if req.status == "cancelled" or req.status == "complete" then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: Already in terminal state (status=%s)", req.status)
		return false
	end
	if req.status == "fulfilled" or (quantity > 0 and fulfilled >= quantity) then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: Already fulfilled (status=%s, fulfilled=%d, quantity=%d)",
			req.status, fulfilled, quantity)
		return false
	end

	if not self:CanCancelRequest(req, actor or self:GetPlayer()) then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: Permission denied (actor=%s, requester=%s)",
			tostring(actor or self:GetPlayer()), tostring(req.requester))
		return false
	end

	-- Apply mutation directly
	local now = GetServerTime()
	local oldStatus = req.status
	req.status = "cancelled"
	req.updatedAt = now

	TOGBankClassic_Output:Debug("SYNC", "CancelRequest SUCCESS: id=%s, item=%s, requester=%s, oldStatus=%s, updatedAt=%d",
		requestId, req.item or "?", req.requester or "?", oldStatus, now)

	-- Broadcast and finalize
	self:BroadcastRequestMutation({ type = "cancel", requestId = requestId, request = req })
	TOGBankClassic_Output:Debug("SYNC", "CancelRequest: Broadcast sent for id=%s", requestId)

	self:FinalizeMutation(now)
	return true
end

function Guild:CompleteRequest(requestId, actor)
	if not self.Info or not self.Info.requests or not requestId then
		return false
	end

	local req = self.Info.requests[requestId]
	if not req then
		return false
	end

	-- Can't complete if already in terminal state
	local quantity = tonumber(req.quantity or 0) or 0
	local fulfilled = tonumber(req.fulfilled or 0) or 0
	if req.status == "cancelled" or req.status == "complete" then
		return false
	end
	if req.status == "fulfilled" or (quantity > 0 and fulfilled >= quantity) then
		return false
	end

	if not self:CanCompleteRequest(req, actor or self:GetPlayer()) then
		return false
	end

	-- Apply mutation directly
	local now = GetServerTime()
	req.status = "complete"
	req.updatedAt = now

	-- Broadcast and finalize
	self:BroadcastRequestMutation({ type = "complete", requestId = requestId, request = req })
	self:FinalizeMutation(now)
	return true
end

function Guild:DeleteRequest(requestId, actor)
	if not self.Info or not self.Info.requests or not requestId then
		return false
	end

	local req = self.Info.requests[requestId]
	if not req then
		return false
	end

	if not self:CanDeleteRequest(req, actor or self:GetPlayer()) then
		return false
	end

	-- Apply mutation directly
	local now = GetServerTime()
	self.Info.requests[requestId] = nil

	-- Record tombstone
	self.Info.requestsTombstones = self.Info.requestsTombstones or {}
	self.Info.requestsTombstones[requestId] = now

	-- Broadcast and finalize
	self:BroadcastRequestMutation({ type = "delete", requestId = requestId })
	self:FinalizeMutation(now)
	return true
end

-- Increment fulfillment for matching requests; returns amount applied.
function Guild:FulfillRequest(bank, requester, itemName, count, targetRequestId)
	if not self.Info or not self.Info.requests or not bank or not requester or not itemName or not count or count <= 0 then
		return 0
	end

	local normBank = self:NormalizeName(bank) or bank
	local normRequester = self:NormalizeName(requester) or requester
	local targetItem = string.lower(itemName)
	local now = GetServerTime()

	local applied = 0
	local mutations = {}
	-- REQSYNC-006: Use a per-mutation offset so successive requests fulfilled in the same
	-- call get strictly increasing timestamps (now, now+1, now+2, …).  GetServerTime() has
	-- 1-second precision; without the offset every request in the loop gets the same
	-- updatedAt, which causes snapshot-based mergeRequest to silently
	-- discard later updates as "not newer" when a peer already holds any version at ts=now.
	local mutationCount = 0

	for _, req in pairs(self.Info.requests) do
		if count <= 0 then break end

		local reqItem = req.item and string.lower(req.item) or ""
		local qty = tonumber(req.quantity or 0) or 0
		local fulfilled = tonumber(req.fulfilled or 0) or 0

		-- If targetRequestId specified, only fulfill that specific request
		local matchesTarget = (not targetRequestId) or (req.id == targetRequestId)

		if matchesTarget and req.bank == normBank and req.requester == normRequester and reqItem == targetItem and fulfilled < qty then
			local remaining = qty - fulfilled
			local delta = math.min(remaining, count)
			count = count - delta
			applied = applied + delta

			-- Each mutation in this call gets a unique timestamp to prevent same-second collisions.
			local mutationTs = now + mutationCount
			mutationCount = mutationCount + 1

			-- Apply mutation directly
			local targetFulfilled = fulfilled + delta
			req.fulfilled = targetFulfilled
			req.updatedAt = mutationTs

			TOGBankClassic_Output:Debug("FULFILL", "Request %s: fulfilled=%d->%d, qty=%d, status=%s",
				req.id or "unknown", fulfilled, targetFulfilled, qty, tostring(req.status))

			if qty > 0 and targetFulfilled >= qty and req.status ~= "cancelled" and req.status ~= "complete" then
				req.status = "fulfilled"
				TOGBankClassic_Output:Debug("FULFILL", "Set status to FULFILLED (fulfilled %d >= qty %d)", targetFulfilled, qty)
			else
				TOGBankClassic_Output:Debug("FULFILL", "Status NOT changed: qty=%d, fulfilled=%d, status=%s",
					qty, targetFulfilled, tostring(req.status))
			end

			-- Queue broadcast (targetFulfilled for idempotency on receiver)
			table.insert(mutations, {
				type = "fulfill",
				requestId = req.id,
				delta = delta,
				targetFulfilled = targetFulfilled,
			})
		end
	end

	-- Broadcast all mutations
	for _, mutation in ipairs(mutations) do
		self:BroadcastRequestMutation(mutation)
	end

	if applied > 0 then
		-- Pass the last timestamp used so requestsVersion advances past all mutations.
		self:FinalizeMutation(now + math.max(mutationCount - 1, 0))
	end

	return applied
end

-- Manual compaction with stats output.
function Guild:Compact()
	if not self.Info then
		TOGBankClassic_Output:Response("Compact: no guild info loaded.")
		return
	end
	self:EnsureRequestsInitialized()

	-- Run compaction and collect stats
	local requestsPruned, requestsBefore, requestsAfter = self:PruneRequests()
	local tombstonesPruned, tombstonesBefore, tombstonesAfter = self:PruneRequestTombstones()

	-- Report results
	local totalPruned = requestsPruned + tombstonesPruned

	if totalPruned == 0 then
		TOGBankClassic_Output:Response("Compact: nothing to prune.")
		TOGBankClassic_Output:Response("  Requests: %d, Tombstones: %d", requestsAfter, tombstonesAfter)
	else
		TOGBankClassic_Output:Response("Compact: pruned %d entries.", totalPruned)
		if requestsPruned > 0 then
			TOGBankClassic_Output:Response("  Requests: %d -> %d (-%d)", requestsBefore, requestsAfter, requestsPruned)
		else
			TOGBankClassic_Output:Response("  Requests: %d", requestsAfter)
		end
		if tombstonesPruned > 0 then
			TOGBankClassic_Output:Response("  Tombstones: %d -> %d (-%d)", tombstonesBefore, tombstonesAfter, tombstonesPruned)
		else
			TOGBankClassic_Output:Response("  Tombstones: %d", tombstonesAfter)
		end
	end
end

-- Diagnostic scan: report done requests that should be expired but aren't being pruned.
function Guild:ReqScan()
	if not self.Info or not self.Info.requests then
		TOGBankClassic_Output:Response("ReqScan: no requests loaded.")
		return
	end

	local now = GetServerTime()
	local expiry = REQUEST_LOG.EXPIRY_SECONDS
	local DAY = 86400
	local total, done, expired = 0, 0, 0
	local noUpdatedAt, noDate = 0, 0
	local updatedAtString, dateString = 0, 0
	local statusCounts = {}
	-- updatedAt age buckets: 0-7d, 7-14d, 14-21d, 21-30d, >30d, future
	local ageBuckets = { [1]=0, [2]=0, [3]=0, [4]=0, [5]=0, [6]=0 }
	local example  -- first done request, for raw field inspection

	for _, req in pairs(self.Info.requests) do
		total = total + 1
		local status = req.status or "nil"
		statusCounts[status] = (statusCounts[status] or 0) + 1

		local quantity  = tonumber(req.quantity or 0) or 0
		local fulfilled = tonumber(req.fulfilled or 0) or 0
		local isDone = status == "fulfilled" or status == "complete"
			or status == "cancelled"
			or (quantity > 0 and fulfilled >= quantity)

		if isDone then
			done = done + 1
			local updated = tonumber(req.updatedAt or 0) or 0
			local dateTs  = tonumber(req.date or 0) or 0
			if updated == 0 then noUpdatedAt = noUpdatedAt + 1 end
			if dateTs  == 0 then noDate = noDate + 1 end
			if type(req.updatedAt) == "string" and tonumber(req.updatedAt) == nil then updatedAtString = updatedAtString + 1 end
			if type(req.date) == "string" and tonumber(req.date) == nil then dateString = dateString + 1 end

			if (now - updated) > expiry then expired = expired + 1 end

			-- Age distribution by updatedAt
			local ageDays = updated > 0 and ((now - updated) / DAY) or nil
			if ageDays == nil then
				ageBuckets[5] = ageBuckets[5] + 1  -- no updatedAt
			elseif ageDays < 0 then
				ageBuckets[6] = ageBuckets[6] + 1  -- future timestamp
			elseif ageDays < 7 then
				ageBuckets[1] = ageBuckets[1] + 1
			elseif ageDays < 14 then
				ageBuckets[2] = ageBuckets[2] + 1
			elseif ageDays < 21 then
				ageBuckets[3] = ageBuckets[3] + 1
			elseif ageDays < 30 then
				ageBuckets[4] = ageBuckets[4] + 1
			else
				ageBuckets[5] = ageBuckets[5] + 1
			end

			if not example then example = req end
		end
	end

	TOGBankClassic_Output:Response("ReqScan: %d total, %d done, %d done+expired (by updatedAt)", total, done, expired)
	TOGBankClassic_Output:Response("  Status breakdown:")
	for s, n in pairs(statusCounts) do
		TOGBankClassic_Output:Response("    %s: %d", s, n)
	end
	TOGBankClassic_Output:Response("  Completed-at age (updatedAt):")
	TOGBankClassic_Output:Response("    0-7d: %d  7-14d: %d  14-21d: %d  21-30d: %d  >30d: %d  future: %d",
		ageBuckets[1], ageBuckets[2], ageBuckets[3], ageBuckets[4], ageBuckets[5], ageBuckets[6])
	TOGBankClassic_Output:Response("  Done requests missing fields: updatedAt=%d, date=%d", noUpdatedAt, noDate)
	TOGBankClassic_Output:Response("  Done requests with non-numeric timestamp strings: updatedAt=%d, date=%d",
		updatedAtString, dateString)

	if example then
		TOGBankClassic_Output:Response("  Example done request (raw fields):")
		TOGBankClassic_Output:Response("    id=%s status=%s", tostring(example.id), tostring(example.status))
		TOGBankClassic_Output:Response("    date=(%s)%s updatedAt=(%s)%s",
			type(example.date), tostring(example.date),
			type(example.updatedAt), tostring(example.updatedAt))
		TOGBankClassic_Output:Response("    requester=%s item=%s", tostring(example.requester), tostring(example.item))
	end
end

--[[
	CheckMailFulfillment(request)
	Checks if requested items are available in mail across all alts
]]
function Guild:CheckMailFulfillment(request)
	if not request or not request.item then
		return { inMail = 0, canFulfillFromMail = false, alts = {} }
	end

	-- Get item ID from item name
	local itemID = nil
	if not self.Info or not self.Info.alts then
		return { inMail = 0, canFulfillFromMail = false, alts = {} }
	end

	-- Find item ID by searching through all alts (mail.items is an array)
	for _, alt in pairs(self.Info.alts) do
		if alt.mail and alt.mail.items then
			for _, item in ipairs(alt.mail.items) do
				-- Use item name from item Link if available, otherwise can't match by name
				local itemName = item.Link and (GetItemInfo(item.Link))
				if itemName == request.item or item.ID == tonumber(request.item) then
					itemID = item.ID
					break
				end
			end
		end
		if itemID then break end
	end

	if not itemID then
		return { inMail = 0, canFulfillFromMail = false, alts = {} }
	end

	local inMail = 0
	local alts = {}

	for name, alt in pairs(self.Info.alts) do
		if alt.mail and alt.mail.items then
			-- mail.items is an array, search for matching ID
			for _, item in ipairs(alt.mail.items) do
				if item.ID == itemID then
					local count = item.Count
					inMail = inMail + count
					table.insert(alts, {
						name = name,
						count = count,
						lastScan = alt.mail.lastScan or 0
					})
					break  -- Found the item, no need to continue
				end
			end
		end
	end

	local needed = request.quantity - (request.fulfilled or 0)
	return {
		inMail = inMail,
		canFulfillFromMail = inMail >= needed,
		alts = alts
	}
end
