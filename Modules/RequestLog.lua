TOGBankClassic_Guild = TOGBankClassic_Guild or {}
local Guild = TOGBankClassic_Guild

-- Throttle warnings to prevent spam (only warn once per session per type)
local warnedAbout = {
	invalidRequestVersion = false,
	corruptedTimestamps = {},  -- Track by request ID
}

--[[
Request sync and storage
========================
This module owns the request lifecycle and synchronization rules. It attaches
methods to TOGBankClassic_Guild, but keeps the logic isolated from Guild.lua.

Data model (Guild.Info):
- requests: map of request ID -> request record (canonical state for UI/logic).
- requestsVersion: max updatedAt timestamp for quick freshness checks.
- requestsTombstones: map requestId -> delete timestamp.
- requestIdSeq: counter for generating unique request IDs.

Request record schema:
{
  id, date, updatedAt, statusUpdatedAt,
  requester, bank, item, quantity, fulfilled,
  status = "open" | "fulfilled" | "cancelled" | "complete",
  notes
}

Conflict resolution (merge-based sync):
- Each request is merged using last-writer-wins based on updatedAt.
- Tombstones win over requests with updatedAt <= tombstone timestamp.
- Fulfillment uses max() to ensure idempotency.

Sync flow:
- Version broadcast includes requestsVersion.
- Full snapshots are exchanged and merged per-request.
- Mutations are broadcast as entries and applied directly.
]]

-- Helper function to count keys in a table
local function countKeys(t)
	if not t or type(t) ~= "table" then
		return 0
	end
	local count = 0
	for _ in pairs(t) do
		count = count + 1
	end
	return count
end

-- Request status constants.
local VALID_REQUEST_STATUS = {
	open = true,
	fulfilled = true,
	cancelled = true,
	complete = true,
}

-- Compaction settings are defined in Constants.lua (REQUEST_LOG table)

-- Legacy requests without IDs are deterministically derived from older fields.
local function legacyRequestId(req)
	if not req or type(req) ~= "table" then
		return nil
	end
	local ts = tonumber(req.date or req.updatedAt or 0) or 0
	local requester = tostring(req.requester or "")
	local bank = tostring(req.bank or "")
	local item = tostring(req.item or "")
	-- TODO: why _and_ here?
	if requester == "" and bank == "" and item == "" and ts == 0 then
		return nil
	end
	return string.format("%s-%s-%s-%d", bank, requester, item, ts)
end

local function generateRequestId()
	-- Fallback ID generator for requests not created through AddRequest.
	-- Uses timestamp:random format (shorter than before, still unique).
	local now = GetServerTime()
	local rand = math.random(1000, 9999)
	return string.format("%d:%d", now, rand)
end

-- Normalize incoming request data and ensure required fields exist.
local function sanitizeRequest(req)
	if not req or type(req) ~= "table" then
		return nil
	end

	local now = GetServerTime()

	local quantity = math.max(tonumber(req.quantity or 0) or 0, 0)
	local fulfilled = math.max(tonumber(req.fulfilled or 0) or 0, 0)
	if quantity > 0 then
		fulfilled = math.min(fulfilled, quantity)
	end

	local bank = Guild:NormalizeName(req.bank)
	local requester = Guild:NormalizeName(req.requester)

	local updatedAt = tonumber(req.updatedAt or req.date or now) or now
	local dateVal = tonumber(req.date or updatedAt) or updatedAt
	local statusUpdatedAt = tonumber(req.statusUpdatedAt or updatedAt) or updatedAt
	local status = req.status
	if not VALID_REQUEST_STATUS[status] then
		status = "open"
	end
	if quantity > 0 and fulfilled >= quantity and status ~= "cancelled" and status ~= "complete" then
		status = "fulfilled"
	end

	local id = req.id or legacyRequestId(req) or generateRequestId()

	return {
		id = id,
		date = dateVal,
		updatedAt = updatedAt,
		statusUpdatedAt = statusUpdatedAt,
		requester = requester or "Unknown",
		bank = bank or "",
		item = tostring(req.item or ""),
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

local function copyMap(src)
	local dest = {}
	for k, v in pairs(src or {}) do
		dest[k] = v
	end
	return dest
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

-- Generate next request ID using simple counter
local function nextRequestId(info, actor)
	if not info then
		return string.format("%s:%d", actor or "unknown", GetServerTime())
	end
	info.requestIdSeq = (info.requestIdSeq or 0) + 1
	return string.format("%s:%d", actor or "unknown", info.requestIdSeq)
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

	-- Initialize request ID counter if not set (migrate from old max ID)
	if not self.Info.requestIdSeq then
		local maxSeq = 0
		for id, _ in pairs(self.Info.requests) do
			-- Parse actor:seq format
			local seq = tonumber(string.match(id or "", ":(%d+)$") or "0") or 0
			if seq > maxSeq then
				maxSeq = seq
			end
		end
		self.Info.requestIdSeq = maxSeq
		TOGBankClassic_Output:Debug("[MIGRATE] Initialized requestIdSeq to %d", maxSeq)
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
	TOGBankClassic_Output:Debug(string.format("[UI-003] NormalizeRequestList: Starting with %d requests", before))

	local normalized = {}
	local tombstones = self.Info.requestsTombstones or {}
	local latest = tonumber(self.Info.requestsVersion or 0) or 0

	for id, req in pairs(self.Info.requests) do
		local clean = sanitizeRequest(req)
		if clean and clean.id then
			local tombstoneTs = tonumber(tombstones[clean.id] or 0) or 0
			if tombstoneTs > 0 and (tonumber(clean.updatedAt or 0) or 0) <= tombstoneTs then
				-- Skip entries that were deleted after their last update.
				TOGBankClassic_Output:Debug(string.format("[UI-003] NormalizeRequestList: Skipping tombstoned request id=%s", clean.id))
			else
				local existing = normalized[clean.id]
				if existing then
					local existingUpdated = tonumber(existing.updatedAt or existing.date or 0) or 0
					local incomingUpdated = tonumber(clean.updatedAt or clean.date or 0) or 0
					if incomingUpdated > existingUpdated then
						normalized[clean.id] = clean
						TOGBankClassic_Output:Debug(string.format("[UI-003] NormalizeRequestList: Updated duplicate id=%s", clean.id))
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
	TOGBankClassic_Output:Debug(string.format("[UI-003] NormalizeRequestList: Finished with %d requests (calling PruneRequests)", after))

	self:PruneRequests()
end

-- Log retention and pruning. Returns (pruned, before, after).
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
		TOGBankClassic_Output:Debug("[UI-003] ApplyRequestSnapshot FAILED: invalid payload")
		return false
	end
	if not self.Info then
		TOGBankClassic_Output:Debug("[UI-003] ApplyRequestSnapshot FAILED: self.Info is nil")
		return false
	end
	self:EnsureRequestsInitialized()

	local incomingList = payload.requests
	if not incomingList or type(incomingList) ~= "table" then
		TOGBankClassic_Output:Debug("[UI-003] ApplyRequestSnapshot FAILED: no requests in payload")
		return false
	end

	-- Incoming payload may be array (wire format) or map (if from newer client)
	local incomingCount = incomingList[1] ~= nil and #incomingList or countRequests(incomingList)
	local localCountBefore = countRequests(self.Info.requests)
	TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: Received snapshot with %d requests, local has %d requests",
		incomingCount, localCountBefore))

	-- Convert incoming to map format, sanitizing each request
	local incomingMap = {}
	local iterFunc = incomingList[1] ~= nil and ipairs or pairs
	for _, req in iterFunc(incomingList) do
		local clean = sanitizeRequest(req)
		if clean and clean.id then
			incomingMap[clean.id] = clean
		end
	end

	-- Merge incoming tombstones with local tombstones (keep most recent)
	local incomingTombstones = payload.tombstones or {}
	local localTombstones = self.Info.requestsTombstones or {}
	for id, ts in pairs(incomingTombstones) do
		local incomingTs = tonumber(ts or 0) or 0
		local localTs = tonumber(localTombstones[id] or 0) or 0
		if incomingTs > localTs then
			localTombstones[id] = incomingTs
		end
	end
	self.Info.requestsTombstones = localTombstones

	-- Merge requests using last-writer-wins per request
	local merged = {}
	local latest = 0
	local stats = { kept = 0, updated = 0, added = 0, tombstoned = 0 }

	-- Start with local requests
	for id, localReq in pairs(self.Info.requests) do
		local tombstoneTs = tonumber(localTombstones[id] or 0) or 0
		local localUpdated = tonumber(localReq.updatedAt or localReq.date or 0) or 0

		if tombstoneTs > 0 and localUpdated <= tombstoneTs then
			-- Request was deleted
			stats.tombstoned = stats.tombstoned + 1
		else
			local incomingReq = incomingMap[id]
			if incomingReq then
				-- Both have it - last writer wins
				local incomingUpdated = tonumber(incomingReq.updatedAt or incomingReq.date or 0) or 0
				if incomingUpdated > localUpdated then
					merged[id] = incomingReq
					stats.updated = stats.updated + 1
					if incomingUpdated > latest then latest = incomingUpdated end
				else
					merged[id] = localReq
					stats.kept = stats.kept + 1
					if localUpdated > latest then latest = localUpdated end
				end
			else
				-- Only local has it - keep it
				merged[id] = localReq
				stats.kept = stats.kept + 1
				if localUpdated > latest then latest = localUpdated end
			end
		end
	end

	-- Add requests only in incoming (not in local)
	for id, incomingReq in pairs(incomingMap) do
		if not self.Info.requests[id] then
			local tombstoneTs = tonumber(localTombstones[id] or 0) or 0
			local incomingUpdated = tonumber(incomingReq.updatedAt or incomingReq.date or 0) or 0
			if tombstoneTs > 0 and incomingUpdated <= tombstoneTs then
				-- Request was deleted
				stats.tombstoned = stats.tombstoned + 1
			else
				merged[id] = incomingReq
				stats.added = stats.added + 1
				if incomingUpdated > latest then latest = incomingUpdated end
			end
		end
	end

	self.Info.requests = merged
	if latest > 0 then
		self.Info.requestsVersion = latest
	end

	TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: Merged - kept=%d, updated=%d, added=%d, tombstoned=%d",
		stats.kept, stats.updated, stats.added, stats.tombstoned))

	self:NormalizeRequestList()
	self:PruneRequests()
	self:PruneRequestTombstones()

	local finalCount = countRequests(self.Info.requests)
	TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: FINAL count = %d requests", finalCount))

	self:RefreshRequestsUI()
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

	TOGBankClassic_Output:Debug(string.format("[UI-003] PruneRequests: Starting with %d requests", before))

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
			TOGBankClassic_Output:Debug(string.format("[UI-003] PruneRequests: Pruning request id=%s, status=%s, age=%d seconds",
				req.id or "nil", req.status or "nil", now - updated))
		else
			if updated > latest then
				latest = updated
			end
		end
	end

	if prunedCount > 0 then
		TOGBankClassic_Output:Debug(string.format("[UI-003] PruneRequests: Pruned %d old completed requests", prunedCount))
	end

	self.Info.requestsVersion = latest
	local after = countRequests(self.Info.requests)

	TOGBankClassic_Output:Debug(string.format("[UI-003] PruneRequests: Finished with %d requests (%d pruned)", after, prunedCount))

	return prunedCount, before, after
end

-- Apply a single log entry to the current request state.
function Guild:ApplyRequestLogEntry(entry)
	if not entry or type(entry) ~= "table" then
		TOGBankClassic_Output:Debug("[REPLAY-DEBUG] ApplyRequestLogEntry: FAIL - entry not a table")
		return false
	end
	if not self.Info then
		TOGBankClassic_Output:Debug("[REPLAY-DEBUG] ApplyRequestLogEntry: FAIL - self.Info is nil")
		return false
	end
	self:EnsureRequestsInitialized()

	local entryType = entry.type
	if not entryType then
		TOGBankClassic_Output:Debug("[REPLAY-DEBUG] ApplyRequestLogEntry: FAIL - no entry.type")
		return false
	end
	local entryTs = tonumber(entry.ts or 0) or 0
	local requestId = entry.requestId or (entry.request and entry.request.id)
	if not requestId then
		TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] ApplyRequestLogEntry: FAIL - no requestId (type=%s)", entryType))
		return false
	end

	local tombstones = self.Info.requestsTombstones or {}
	local tombstoneTs = tonumber(tombstones[requestId] or 0) or 0
	if tombstoneTs > 0 and entryTs > 0 and entryTs <= tombstoneTs then
		TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] ApplyRequestLogEntry: BLOCKED by tombstone (requestId=%s, entryTs=%d, tombstoneTs=%d)",
			requestId, entryTs, tombstoneTs))
		return false
	end

	local req = self.Info.requests[requestId]
	local snapshot = entry.request

	if not req and snapshot then
		local clean = sanitizeRequest(snapshot)
		if clean then
			self.Info.requests[requestId] = clean
			req = clean
			TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] ApplyRequestLogEntry: CREATED request from snapshot (requestId=%s, type=%s)",
				requestId, entryType))
		else
			TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] ApplyRequestLogEntry: sanitizeRequest returned nil for snapshot (requestId=%s)",
				requestId))
		end
	end

	if entryType == "delete" then
		self.Info.requests[requestId] = nil
		if entryTs > tombstoneTs then
			tombstones[requestId] = entryTs
			self.Info.requestsTombstones = tombstones
		end
		if entryTs > 0 then
			self:TouchRequestsVersion(entryTs)
		end
		return true
	end

	if not req then
		TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] ApplyRequestLogEntry: FAIL - req is nil, snapshot=%s (requestId=%s, type=%s)",
			tostring(snapshot ~= nil), requestId, entryType))
		return false
	end

	if entryType == "add" then
		local existingUpdated = tonumber(req.updatedAt or 0) or 0
		if entryTs >= existingUpdated then
			local clean = sanitizeRequest(snapshot or req)
			if clean then
				clean.updatedAt = math.max(clean.updatedAt or entryTs, entryTs)
				if clean.statusUpdatedAt == nil or clean.statusUpdatedAt < (clean.updatedAt or 0) then
					clean.statusUpdatedAt = clean.updatedAt
				end
				self.Info.requests[requestId] = clean
			end
		end
		return true
	end

	if entryType == "fulfill" then
		if req.status == "cancelled" or req.status == "complete" then
			return false
		end
		local delta = tonumber(entry.delta or 0) or 0
		if delta <= 0 then
			return false
		end
		local qty = tonumber(req.quantity or 0) or 0
		local fulfilled = tonumber(req.fulfilled or 0) or 0
		local newFulfilled
		-- [SYNC-FIX] Idempotent fulfill: if targetFulfilled is present (new format),
		-- use max() to prevent double-application. Old entries without targetFulfilled
		-- still use additive logic for backwards compatibility.
		local targetFulfilled = entry.targetFulfilled
		if targetFulfilled ~= nil then
			-- New format: use max of current and target to ensure idempotency
			local target = tonumber(targetFulfilled or 0) or 0
			newFulfilled = math.max(fulfilled, target)
		else
			-- Old format: additive delta (not idempotent, but backwards compatible)
			newFulfilled = fulfilled + delta
		end
		if qty > 0 and newFulfilled > qty then
			newFulfilled = qty
		end
		req.fulfilled = newFulfilled
		if qty > 0 and newFulfilled >= qty and req.status ~= "cancelled" and req.status ~= "complete" then
			req.status = "fulfilled"
			req.statusUpdatedAt = entryTs
		end
		if entryTs > 0 then
			req.updatedAt = math.max(tonumber(req.updatedAt or 0) or 0, entryTs)
		end
		return true
	end

	if entryType == "cancel" or entryType == "complete" then
		local newStatus = (entryType == "cancel") and "cancelled" or "complete"
		local statusUpdatedAt = tonumber(req.statusUpdatedAt or req.updatedAt or 0) or 0
		if entryTs >= statusUpdatedAt then
			req.status = newStatus
			req.statusUpdatedAt = entryTs
			req.updatedAt = math.max(tonumber(req.updatedAt or 0) or 0, entryTs)
		end
		return true
	end

	return false
end

-- Construct a mutation entry for broadcasting changes.
-- Note: This is transitional - will be simplified further in Phase 2.
function Guild:BuildRequestLogEntry(entryType, request, extra)
	if not self.Info then
		return nil
	end
	local actor = self:GetNormalizedPlayer() or "unknown"
	local now = GetServerTime()
	local clean = request and sanitizeRequest(request) or nil
	local entry = {
		type = entryType,
		actor = actor,
		ts = now,
		id = string.format("%s:%d", actor, now),
		requestId = clean and clean.id or (extra and extra.requestId),
		request = clean,
	}
	if extra then
		for k, v in pairs(extra) do
			if entry[k] == nil then
				entry[k] = v
			end
		end
	end
	return entry
end

-- Apply a mutation entry locally and optionally broadcast it.
-- Note: This is transitional - will be simplified further in Phase 2.
function Guild:RecordRequestLogEntry(entry, broadcast)
	if not entry or not entry.id then
		TOGBankClassic_Output:Debug("[UI-003] RecordRequestLogEntry FAILED: entry missing or no id")
		return false
	end
	if not self.Info then
		TOGBankClassic_Output:Debug("[UI-003] RecordRequestLogEntry FAILED: self.Info is nil")
		return false
	end
	self:EnsureRequestsInitialized()

	TOGBankClassic_Output:Debug(string.format("[UI-003] RecordRequestLogEntry: entry.id=%s, type=%s, requestId=%s, broadcast=%s",
		entry.id or "nil", entry.type or "nil", entry.requestId or "nil", tostring(broadcast)))

	TOGBankClassic_Output:Debug(string.format("[UI-003] RecordRequestLogEntry: Applying entry (requests before = %d)", countRequests(self.Info.requests)))

	if not self:ApplyRequestLogEntry(entry) then
		TOGBankClassic_Output:Debug("[UI-003] RecordRequestLogEntry FAILED: ApplyRequestLogEntry returned false")
		return false
	end

	TOGBankClassic_Output:Debug(string.format("[UI-003] RecordRequestLogEntry: Applied successfully (requests after = %d)", countRequests(self.Info.requests)))

	if entry.ts and entry.ts > 0 then
		self:TouchRequestsVersion(entry.ts)
	end

	TOGBankClassic_Output:Debug("[UI-003] RecordRequestLogEntry: Calling PruneIfNeeded")
	self:PruneIfNeeded()
	TOGBankClassic_Output:Debug(string.format("[UI-003] RecordRequestLogEntry: After PruneIfNeeded (requests = %d)", countRequests(self.Info.requests)))

	if broadcast then
		TOGBankClassic_Output:Debug("[UI-003] RecordRequestLogEntry: Broadcasting entry to guild")
		self:SendRequestLogEntry(entry)
	end
	self:RefreshRequestsUI()
	return true
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
	TOGBankClassic_Output:Debug(string.format("[UI-003] RefreshRequestsUI called: isOpen=%s, requests=%d",
		tostring(TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.isOpen),
		self.Info and self.Info.requests and countRequests(self.Info.requests) or 0))

	if TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.isOpen then
		TOGBankClassic_UI_Requests:DrawContent()
	end
end

-- Snapshot and log sync messaging.
function Guild:GetRequestsVersion()
	if not self.Info then
		return 0
	end
	local version = tonumber(self.Info.requestsVersion or 0) or 0
	-- Validate version is within reasonable Unix timestamp range (2000-2038)
	-- Prevents integer overflow from corrupted data (DATA-003)
	local MIN_TIMESTAMP = 946684800  -- Jan 1, 2000
	local MAX_TIMESTAMP = 2147483647  -- Max 32-bit signed integer (Jan 19, 2038)
	if version < MIN_TIMESTAMP or version > MAX_TIMESTAMP then
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

function Guild:SendRequestsSnapshot(target)
	-- Always send snapshot, even if empty (so querying player knows we have nothing)
	if not self.Info then
		TOGBankClassic_Output:DebugComm("SendRequestsSnapshot: Skipping (self.Info is nil)")
		return
	end
	self:EnsureRequestsInitialized()
	self:NormalizeRequestList()
	local payload = {
		type = "requests",
		player = "*",  -- Backwards compat: v0.7.11-v0.7.13 need this field to process responses
		version = self:GetRequestsVersion(),
		requests = requestsToArray(self.Info.requests),  -- Convert map to array for wire format
		tombstones = self.Info.requestsTombstones or {},
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", target, "BULK")
end

function Guild:SendRequestsData(target)
	self:SendRequestsSnapshot(target)
end

function Guild:QueryRequestsSnapshot(player, priority)
	-- Send wildcard query (v0.7.14+)
	-- Note: Old clients won't respond to wildcard, but targeted queries flood guild chat
	-- and trigger WoW throttling which blocks responses. Wildcard-only is the fix.
	local data = TOGBankClassic_Core:SerializeWithChecksum({ player = "*", type = "requests" })
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, priority or "BULK")
	TOGBankClassic_Output:DebugComm("[SYNC-004] QUERY REQUESTS: Sent wildcard query (removed targeted spam)")
end

-- Receive and merge a requests snapshot from another player.
-- Uses merge-based sync - always merges, ApplyRequestSnapshot handles conflict resolution.
function Guild:ReceiveRequestsData(payload)
	if not payload or type(payload) ~= "table" then
		TOGBankClassic_Output:Debug("[SYNC] ReceiveRequestsData: INVALID - payload not a table")
		return ADOPTION_STATUS.INVALID
	end
	if not self.Info then
		TOGBankClassic_Output:Debug("[SYNC] ReceiveRequestsData: IGNORED - self.Info is nil")
		return ADOPTION_STATUS.IGNORED
	end
	self:EnsureRequestsInitialized()

	local incomingCount = (payload.requests and type(payload.requests) == "table") and #payload.requests or 0
	local localCountBefore = self.Info.requests and countRequests(self.Info.requests) or 0
	TOGBankClassic_Output:Debug(string.format("[SYNC] ReceiveRequestsData: START - local=%d, incoming=%d",
		localCountBefore, incomingCount))

	-- Always merge - ApplyRequestSnapshot handles last-writer-wins per request
	if self:ApplyRequestSnapshot(payload) then
		local localCountAfter = self.Info.requests and countRequests(self.Info.requests) or 0
		TOGBankClassic_Output:Debug(string.format("[SYNC] ReceiveRequestsData: ADOPTED - final=%d (was %d, incoming=%d)",
			localCountAfter, localCountBefore, incomingCount))
		return ADOPTION_STATUS.ADOPTED
	end

	TOGBankClassic_Output:Debug("[SYNC] ReceiveRequestsData: INVALID - ApplyRequestSnapshot returned false")
	return ADOPTION_STATUS.INVALID
end

function Guild:SendRequestsVersionPing()
	if not self.Info then
		return
	end
	local payload = {
		requests = self:GetRequestsVersion(),
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	TOGBankClassic_Core:SendCommMessage("togbank-v", data, "Guild", nil, "BULK")
end

function Guild:SendRequestLogEntry(entry, target)
	if not entry or type(entry) ~= "table" then
		TOGBankClassic_Output:Debug("SYNC", "SendRequestLogEntry FAILED: Invalid entry")
		return
	end
	TOGBankClassic_Output:Debug("SYNC", "SendRequestLogEntry: Broadcasting entry.id=%s, type=%s, target=%s", 
		tostring(entry.id), tostring(entry.type), tostring(target or "GUILD"))
	local payload = { type = "requests-log", logEntries = { entry } }
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	-- Use ALERT priority for immediate request broadcasts (highest priority)
	-- Request creations are very rare (10-20/day) and need guaranteed immediate delivery
	TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", target, "ALERT")
	TOGBankClassic_Output:Debug("SYNC", "SendRequestLogEntry: Broadcast complete")
end

function Guild:ReceiveRequestLogEntry(entry, sender)
	if not entry or type(entry) ~= "table" then
		return false
	end
	return self:ReceiveRequestLogEntries({ logEntries = { entry } }, sender)
end

-- Receive mutation entries from another player and apply them.
-- Each entry is applied directly - ApplyRequestLogEntry handles idempotency.
function Guild:ReceiveRequestLogEntries(payload, sender)
	if not payload or type(payload) ~= "table" then
		TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestLogEntries: Invalid payload")
		return
	end
	local entries = payload.logEntries
	if not entries or type(entries) ~= "table" then
		TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestLogEntries: No logEntries in payload")
		return
	end
	if not self.Info then
		return
	end
	self:EnsureRequestsInitialized()

	-- Apply each entry directly - ApplyRequestLogEntry handles conflicts
	for _, entry in ipairs(entries) do
		if entry and type(entry) == "table" then
			self:RecordRequestLogEntry(entry, false)
		end
	end
end

-- Request mutation helpers.
function Guild:AddRequest(request)
	if not self.Info then
		TOGBankClassic_Output:Debug("[UI-003] AddRequest FAILED: self.Info is nil")
		return false
	end
	if not request or type(request) ~= "table" then
		TOGBankClassic_Output:Debug("[UI-003] AddRequest FAILED: invalid request parameter")
		return false
	end

	self:EnsureRequestsInitialized()

	local now = GetServerTime()
	request.date = request.date or now
	request.updatedAt = now
	request.status = request.status or "open"
	request.fulfilled = tonumber(request.fulfilled or 0) or 0

	-- Generate request ID in actor:seq format
	if not request.id then
		local actor = self:GetNormalizedPlayer() or "unknown"
		request.id = nextRequestId(self.Info, actor)
	end

	local clean = sanitizeRequest(request)
	if not clean then
		TOGBankClassic_Output:Debug("[UI-003] AddRequest FAILED: sanitizeRequest returned nil")
		return false
	end

	TOGBankClassic_Output:Debug(string.format("[UI-003] AddRequest: Creating request id=%s, requester=%s, item=%s, quantity=%d",
		clean.id or "nil", clean.requester or "nil", clean.item or "nil", clean.quantity or 0))

	local entry = self:BuildRequestLogEntry("add", clean)
	if not entry then
		TOGBankClassic_Output:Debug("[UI-003] AddRequest FAILED: BuildRequestLogEntry returned nil")
		return false
	end

	TOGBankClassic_Output:Debug(string.format("[UI-003] AddRequest: Built log entry id=%s, seq=%d, actor=%s",
		entry.id or "nil", entry.seq or 0, entry.actor or "nil"))

	local result = self:RecordRequestLogEntry(entry, true)
	TOGBankClassic_Output:Debug(string.format("[UI-003] AddRequest: RecordRequestLogEntry returned %s", tostring(result)))

	if result then
		TOGBankClassic_Output:Debug(string.format("[UI-003] AddRequest SUCCESS: Total requests now = %d", countRequests(self.Info.requests)))
	end

	return result
end

-- Access control for requests.
function Guild:CanManageRequests(actor, actorIsGM)
	if CanViewOfficerNote() then
		return true
	end

	local normActor = self:NormalizeName(actor)

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

	-- TODO: remove this testing code after functional validation
	if normActor == "Huntmehuntme-Myzrael" then
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

function Guild:CancelRequest(requestId, actor)
	TOGBankClassic_Output:Debug("SYNC", "CancelRequest called: requestId=%s, actor=%s", tostring(requestId), tostring(actor))
	
	if not self.Info or not self.Info.requests then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: No Info or requests")
		return false
	end
	if not requestId then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: No requestId")
		return false
	end

	self:EnsureRequestsInitialized()

	local req = self.Info.requests[requestId]
	if not req then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: Request not found")
		return false
	end

	local quantity = tonumber(req.quantity or 0) or 0
	local fulfilled = tonumber(req.fulfilled or 0) or 0
	if req.status == "cancelled" then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: Already cancelled")
		return false
	end
	if req.status == "fulfilled" or req.status == "complete" or (quantity > 0 and fulfilled >= quantity) then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: Request already complete or fulfilled")
		return false
	end

	local actorName = actor or self:GetPlayer()
	TOGBankClassic_Output:Debug("SYNC", "CancelRequest: actorName=%s, requester=%s", tostring(actorName), tostring(req.requester))
	
	if not self:CanCancelRequest(req, actorName) then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: CanCancelRequest returned false")
		return false
	end

	TOGBankClassic_Output:Debug("SYNC", "CancelRequest: Building log entry...")
	local entry = self:BuildRequestLogEntry("cancel", req)
	if not entry then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: BuildRequestLogEntry returned nil")
		return false
	end
	return self:RecordRequestLogEntry(entry, true)
end

function Guild:CompleteRequest(requestId, actor)
	if not self.Info or not self.Info.requests then
		return false
	end
	if not requestId then
		return false
	end

	self:EnsureRequestsInitialized()

	local req = self.Info.requests[requestId]
	if not req then
		return false
	end

	local quantity = tonumber(req.quantity or 0) or 0
	local fulfilled = tonumber(req.fulfilled or 0) or 0
	if req.status == "cancelled" then
		return false
	end
	if req.status == "complete" then
		return false
	end
	if req.status == "fulfilled" or (quantity > 0 and fulfilled >= quantity) then
		return false
	end

	local actorName = actor or self:GetPlayer()
	if not self:CanCompleteRequest(req, actorName) then
		return false
	end

	local entry = self:BuildRequestLogEntry("complete", req)
	if not entry then
		return false
	end
	return self:RecordRequestLogEntry(entry, true)
end

function Guild:DeleteRequest(requestId, actor)
	if not self.Info or not self.Info.requests then
		return false
	end
	if not requestId then
		return false
	end

	self:EnsureRequestsInitialized()

	local req = self.Info.requests[requestId]
	if not req then
		return false
	end

	local actorName = actor or self:GetPlayer()
	if not self:CanDeleteRequest(req, actorName) then
		return false
	end

	local entry = self:BuildRequestLogEntry("delete", req, { requestId = requestId })
	if not entry then
		return false
	end
	return self:RecordRequestLogEntry(entry, true)
end

-- Increment fulfillment for matching requests; returns amount applied.
function Guild:FulfillRequest(bank, requester, itemName, count)
	if
		not self.Info
		or not self.Info.requests
		or not bank
		or not requester
		or not itemName
		or not count
		or count <= 0
	then
		return 0
	end

	local normBank = self:NormalizeName(bank) or bank
	local normRequester = self:NormalizeName(requester) or requester
	local targetItem = string.lower(itemName)

	local applied = 0
	local entries = {}
	for _, req in pairs(self.Info.requests) do
		local reqBank = req.bank
		local reqRequester = req.requester
		local reqItem = req.item and string.lower(req.item) or ""
		local qty = tonumber(req.quantity or 0) or 0
		local fulfilled = tonumber(req.fulfilled or 0) or 0

		if reqBank == normBank and reqRequester == normRequester and reqItem == targetItem and fulfilled < qty then
			local remaining = qty - fulfilled
			local delta = math.min(remaining, count)
			count = count - delta
			applied = applied + delta
			-- [SYNC-FIX] Include targetFulfilled for idempotent replay - if this entry is
			-- re-applied, we use max() to ensure we don't double-apply the delta
			local targetFulfilled = fulfilled + delta
			local entry = self:BuildRequestLogEntry("fulfill", req, { delta = delta, targetFulfilled = targetFulfilled })
			if entry then
				table.insert(entries, entry)
			end
		end

		if count <= 0 then
			break
		end
	end

	if #entries > 0 then
		for _, entry in ipairs(entries) do
			self:RecordRequestLogEntry(entry, true)
		end
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

	-- Find item ID by searching through all alts
	for _, alt in pairs(self.Info.alts) do
		if alt.mail and alt.mail.items then
			for id, mailItem in pairs(alt.mail.items) do
				if mailItem.name == request.item then
					itemID = id
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
		if alt.mail and alt.mail.items and alt.mail.items[itemID] then
			local count = alt.mail.items[itemID].count
			inMail = inMail + count
			table.insert(alts, {
				name = name,
				count = count,
				lastScan = alt.mail.lastScan or 0
			})
		end
	end

	local needed = request.quantity - (request.fulfilled or 0)
	return {
		inMail = inMail,
		canFulfillFromMail = inMail >= needed,
		alts = alts
	}
end
