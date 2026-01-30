TOGBankClassic_Guild = TOGBankClassic_Guild or {}
local Guild = TOGBankClassic_Guild

-- Throttle warnings to prevent spam (only warn once per session per type)
local warnedAbout = {
	invalidRequestVersion = false,
	corruptedTimestamps = {},  -- Track by request ID
}

--[[
Request log sync and storage
============================
This module owns the request lifecycle and synchronization rules. It attaches
methods to TOGBankClassic_Guild, but keeps the logic isolated from Guild.lua.

Data model (Guild.Info):
- requests: array of request records (canonical state for UI/logic).
- requestsVersion: max updatedAt timestamp for quick freshness checks.
- requestLog: array of log entries, ordered by (actor, seq).
- requestLogSeq: map actor -> next sequence number to emit.
- requestLogApplied: map actor -> last applied sequence number.
- requestsTombstones: map requestId -> delete timestamp.

Log entry schema:
{
  id, actor, seq, ts,
  type = "add" | "fulfill" | "cancel" | "complete" | "delete",
  requestId,
  request (full snapshot for add),
  delta (for fulfill)
}

Conflict resolution:
- Priority order (highest to lowest):
  1. delete: Removes request completely (tombstone)
  2. cancel: Requester withdraws their request
  3. complete: Banker marks as finished
  4. fulfill: Updates fulfillment progress (additive, partial fills allowed)
  5. add: Creates/updates request data
- Higher priority operations override lower priority operations
- Same priority operations use last-writer-wins by timestamp
- Special case: Cancel from requester always wins over banker operations

Sync flow:
- Version broadcast includes requestsVersion + requestLog summary.
- Missing log entries are fetched via requests-log query.
- Too-old gaps fall back to full snapshot ("requests").
- Snapshot includes requestLogApplied + tombstones to reconcile state.
]]

-- Operation priority table (higher number = higher priority)
local OPERATION_PRIORITY = {
	add = 1,
	fulfill = 2,
	complete = 3,
	cancel = 4,
	delete = 5,
}

-- Helper to get operation priority
local function getOperationPriority(opType)
	return OPERATION_PRIORITY[opType] or 0
end

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
	local now = GetServerTime()
	local rand = math.random(100000, 999999)
	return string.format("%d-%d", now, rand)
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
	local statusUpdatedAt = validateTimestamp(req.statusUpdatedAt or updatedAt, updatedAt)
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

local function requestLogId(actor, seq)
	local safeActor = tostring(actor or "unknown")
	local safeSeq = tonumber(seq or 0) or 0
	return string.format("%s:%d", safeActor, safeSeq)
end

local function buildRequestIndex(list)
	local map = {}
	for idx, req in ipairs(list) do
		if req and req.id then
			map[req.id] = idx
		end
	end
	return map
end

-- Initialization and normalization.
function Guild:EnsureRequestsInitialized()
	if not self.Info then
		return
	end
	if not self.Info.requests then
		self.Info.requests = {}
	end
	if not self.Info.requestsVersion then
		self.Info.requestsVersion = 0
	end

	-- Migrate legacy request log fields.
	if self.Info.requestLog == nil and self.Info.requestsOps ~= nil then
		self.Info.requestLog = self.Info.requestsOps
		self.Info.requestsOps = nil
	end
	if self.Info.requestLogSeq == nil and self.Info.requestsOpSeq ~= nil then
		self.Info.requestLogSeq = self.Info.requestsOpSeq
		self.Info.requestsOpSeq = nil
	end
	if self.Info.requestLogApplied == nil and self.Info.requestsOpApplied ~= nil then
		self.Info.requestLogApplied = self.Info.requestsOpApplied
		self.Info.requestsOpApplied = nil
	end

	if not self.Info.requestLog then
		self.Info.requestLog = {}
	end
	if not self.Info.requestLogSeq then
		self.Info.requestLogSeq = {}
	end
	
	if not self.Info.requestLogApplied then
		self.Info.requestLogApplied = {}
	end
	if not self.Info.requestsTombstones then
		self.Info.requestsTombstones = {}
	end

	-- [PERSISTENCE-DEBUG] Log initial state on load
	TOGBankClassic_Output:Debug("SYNC", "[PERSIST] EnsureRequestsInitialized: requestLog has %d entries", #(self.Info.requestLog or {}))
	TOGBankClassic_Output:Debug("SYNC", "[PERSIST] EnsureRequestsInitialized: requestLogApplied has %d actors: %s",
		countKeys(self.Info.requestLogApplied or {}),
		table.concat((function() local t = {}; for k,v in pairs(self.Info.requestLogApplied or {}) do table.insert(t, k.."="..v) end; return t end)(), ", "))

	if not self.requestLogIndex or not self.requestLogByActor then
		self:RebuildRequestLogIndex()
	end
	
	-- [BUG-FIX REPLAY-001] Validate that requestLogApplied is consistent with event log
	-- Check if there are entries marked as applied but don't exist in requests snapshot
	-- Skip validation if we've already validated (prevents recursive calls)
	if not self._validationComplete then
		local needsRebuild = false
		local appliedButMissingCount = 0
		if self.requestLogByActor then
			for actor, entries in pairs(self.requestLogByActor) do
				local appliedSeq = self.Info.requestLogApplied[actor] or 0
				for _, entry in ipairs(entries) do
					-- Check entries that are marked as applied (seq <= appliedSeq)
					if entry.seq <= appliedSeq and entry.type == "add" then
						-- This "add" entry is marked as applied, so the request should exist
						local requestExists = false
						for _, req in ipairs(self.Info.requests or {}) do
							if req.id == entry.requestId then
								requestExists = true
								break
							end
						end
						if not requestExists then
							-- Check if it was deleted (tombstone)
							local tombstoneTs = self.Info.requestsTombstones and self.Info.requestsTombstones[entry.requestId]
							if not tombstoneTs or tombstoneTs < entry.ts then
								-- Not deleted or deletion is older than the add - request should exist!
								TOGBankClassic_Output:Debug("[REPLAY-001] Stale data: %s seq %d marked applied but request %s missing",
									actor, entry.seq, entry.requestId)
								appliedButMissingCount = appliedButMissingCount + 1
								needsRebuild = true
								if appliedButMissingCount >= 3 then
									break  -- Found enough evidence
								end
							end
						end
					end
				end
				if appliedButMissingCount >= 3 then break end
			end
		end
		
		if needsRebuild then
			TOGBankClassic_Output:Debug("SYNC", "[PERSIST] REPLAY-001 validation triggered rebuild - detected %d stale entries", appliedButMissingCount)
			TOGBankClassic_Output:Debug("SYNC", "[PERSIST] Before clear: requestLogApplied has %d actors, requests has %d items",
				countKeys(self.Info.requestLogApplied or {}), #(self.Info.requests or {}))
			-- Clear requestLogApplied so replay processes ALL entries from event log
			self.Info.requestLogApplied = {}
			-- Clear requests so we rebuild from scratch
			self.Info.requests = {}
			-- Mark validation as complete to prevent recursion
			self._validationComplete = true
			-- Replay all events from the log
			self:ReplayRequestLogEntries()
			TOGBankClassic_Output:Debug("SYNC", "[PERSIST] After rebuild: requestLogApplied has %d actors, requests has %d items",
				countKeys(self.Info.requestLogApplied or {}), #(self.Info.requests or {}))
			return
		end
		
		-- Mark validation as complete
		self._validationComplete = true
	end
	
	-- Fallback: Always rebuild requestLogApplied when it's empty and we have log data
	local isEmpty = next(self.Info.requestLogApplied) == nil
	local hasIndex = self.requestLogByActor ~= nil
	if isEmpty and hasIndex then
		TOGBankClassic_Output:Debug("SYNC", "requestLogApplied is empty, rebuilding from event log")
		-- Initialize to 0 so ReplayRequestLogEntries will process all events
		for actor, list in pairs(self.requestLogByActor) do
			if #list > 0 then
				self.Info.requestLogApplied[actor] = 0
			end
		end
		TOGBankClassic_Output:Debug("SYNC", "Initialized requestLogApplied for %d actors, calling ReplayRequestLogEntries", countKeys(self.Info.requestLogApplied))
		-- Replay all entries to rebuild the requests snapshot
		self:ReplayRequestLogEntries()
		TOGBankClassic_Output:Debug("SYNC", "After replay, requests count = %d", #(self.Info.requests or {}))
	end

	local localActor = self:GetNormalizedPlayer()
	if localActor and localActor ~= "" then
		local appliedSeq = tonumber(self.Info.requestLogApplied[localActor] or 0) or 0
		local localSeq = tonumber(self.Info.requestLogSeq[localActor] or 0) or 0
		if appliedSeq > localSeq then
			self.Info.requestLogSeq[localActor] = appliedSeq
		end
	end

	self:NormalizeRequestList()
end

-- Build fast lookups for log entries by id/actor.
-- NOTE: This function should ONLY rebuild the indices, not modify requestLogApplied.
-- The requestLogApplied map is managed by:
--   - RecordRequestLogEntry (when applying local entries)
--   - ApplyRequestSnapshot (when receiving snapshots)
--   - ReplayRequestLogEntries (when replaying after snapshot)
-- Modifying it here would break replay logic by marking entries as "already applied"
-- when they actually need to be replayed.
function Guild:RebuildRequestLogIndex()
	if not self.Info or not self.Info.requestLog then
		return
	end
	self.requestLogIndex = {}
	self.requestLogByActor = {}
	for _, entry in ipairs(self.Info.requestLog) do
		if entry and entry.id then
			self.requestLogIndex[entry.id] = true
			local actor = entry.actor or "unknown"
			if not self.requestLogByActor[actor] then
				self.requestLogByActor[actor] = {}
			end
			table.insert(self.requestLogByActor[actor], entry)
		end
	end
	for _, list in pairs(self.requestLogByActor) do
		table.sort(list, function(a, b)
			return (tonumber(a.seq or 0) or 0) < (tonumber(b.seq or 0) or 0)
		end)
	end
	-- [REPLAY-FIX] REMOVED: The old code here would rebuild requestLogApplied from max seq
	-- when it was empty. This broke replay because it would mark local entries as
	-- "already applied" before ReplayRequestLogEntries had a chance to run.
	-- requestLogApplied should only be modified by the functions listed above.
	TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] RebuildRequestLogIndex: %d entries, %d actors indexed",
		#self.Info.requestLog, countKeys(self.requestLogByActor)))
end

-- Normalize stored requests and drop tombstoned entries.
function Guild:NormalizeRequestList()
	if not self.Info or not self.Info.requests then
		return
	end

	TOGBankClassic_Output:Debug(string.format("[UI-003] NormalizeRequestList: Starting with %d requests", #self.Info.requests))

	local normalized = {}
	local byId = {}
	local tombstones = self.Info.requestsTombstones or {}
	local latest = tonumber(self.Info.requestsVersion or 0) or 0

	for _, req in ipairs(self.Info.requests) do
		local clean = sanitizeRequest(req)
		if clean and clean.id then
			local tombstoneTs = tonumber(tombstones[clean.id] or 0) or 0
			if tombstoneTs > 0 and (tonumber(clean.updatedAt or 0) or 0) <= tombstoneTs then
				-- Skip entries that were deleted after their last update.
				TOGBankClassic_Output:Debug(string.format("[UI-003] NormalizeRequestList: Skipping tombstoned request id=%s", clean.id))
			else
				local existingIdx = byId[clean.id]
				if existingIdx then
					local existing = normalized[existingIdx]
					local existingUpdated = tonumber(existing.updatedAt or existing.date or 0) or 0
					local incomingUpdated = tonumber(clean.updatedAt or clean.date or 0) or 0
					if incomingUpdated > existingUpdated then
						normalized[existingIdx] = clean
						TOGBankClassic_Output:Debug(string.format("[UI-003] NormalizeRequestList: Updated duplicate id=%s", clean.id))
					end
				else
					table.insert(normalized, clean)
					byId[clean.id] = #normalized
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

	TOGBankClassic_Output:Debug(string.format("[UI-003] NormalizeRequestList: Finished with %d requests (calling PruneRequests)", #normalized))

	self:PruneRequests()
end

-- Log retention and pruning. Returns (pruned, before, after).
function Guild:PruneRequestLog()
	if not self.Info or not self.Info.requestLog then
		return 0, 0, 0
	end
	local before = #self.Info.requestLog
	local now = GetServerTime()
	local keep = {}
	for _, entry in ipairs(self.Info.requestLog) do
		local ts = tonumber(entry.ts or 0) or 0
		if ts > 0 and (now - ts) <= REQUEST_LOG.RETENTION_SECONDS then
			table.insert(keep, entry)
		end
	end

	if #keep > REQUEST_LOG.MAX_ENTRIES then
		table.sort(keep, function(a, b)
			return (tonumber(a.ts or 0) or 0) < (tonumber(b.ts or 0) or 0)
		end)
		local startIndex = #keep - REQUEST_LOG.MAX_ENTRIES + 1
		local trimmed = {}
		for i = startIndex, #keep do
			table.insert(trimmed, keep[i])
		end
		keep = trimmed
	end

	self.Info.requestLog = keep
	self:RebuildRequestLogIndex()
	local after = #keep
	return before - after, before, after
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
	self:PruneRequestLog()
	self:PruneRequestTombstones()
	return true
end

-- Sequence allocation for local actors.
function Guild:NextRequestLogSeq(actor)
	if not self.Info then
		return 0
	end
	local normActor = self:NormalizeName(actor or self:GetPlayer()) or actor or "unknown"
	local current = tonumber(self.Info.requestLogSeq[normActor] or 0) or 0
	local nextSeq = current + 1
	self.Info.requestLogSeq[normActor] = nextSeq
	return nextSeq, normActor
end

function Guild:AppendRequestLogEntry(entry)
	if not self.Info or not entry or not entry.id then
		return
	end
	-- [REPLAY-DEBUG] Verify log entries are stored with full data
	if entry.type == "add" then
		if not entry.request then
			TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] WARNING: Storing 'add' entry WITHOUT request snapshot! id=%s, requestId=%s",
				entry.id or "nil", entry.requestId or "nil"))
		else
			TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] Storing 'add' entry WITH request snapshot: id=%s, requestId=%s, item=%s",
				entry.id or "nil", entry.requestId or "nil", entry.request.item or "nil"))
		end
	end
	self.Info.requestLog = self.Info.requestLog or {}
	table.insert(self.Info.requestLog, entry)
	self.requestLogIndex = self.requestLogIndex or {}
	self.requestLogIndex[entry.id] = true
	self.requestLogByActor = self.requestLogByActor or {}
	local actor = entry.actor or "unknown"
	if not self.requestLogByActor[actor] then
		self.requestLogByActor[actor] = {}
	end
	table.insert(self.requestLogByActor[actor], entry)
end

-- Snapshot application and replay.
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

	TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: Received snapshot with %d requests, local has %d requests",
		#incomingList, #(self.Info.requests or {})))

	local sanitized = {}
	local latest = 0
	for _, req in ipairs(incomingList) do
		local clean = sanitizeRequest(req)
		if clean and clean.id then
			table.insert(sanitized, clean)
			if clean.updatedAt and clean.updatedAt > latest then
				latest = clean.updatedAt
			end
		end
	end

	TOGBankClassic_Output:Debug("SYNC", string.format("ApplyRequestSnapshot: Sanitized to %d requests", #sanitized))

	-- [SYNC-FIX] MERGE snapshots instead of replacing. Event-sourcing principle: never accept
	-- data loss without proof (tombstones). If incoming snapshot is missing requests we have,
	-- we should keep ours unless there's a tombstone proving deletion.
	local localRequests = self.Info.requests or {}
	local incomingMap = {}
	local mergedRequests = {}
	
	-- Index incoming requests by ID
	for _, req in ipairs(sanitized) do
		if req.id then
			incomingMap[req.id] = req
		end
	end
	
	-- Index local requests by ID
	local localMap = {}
	for _, req in ipairs(localRequests) do
		if req.id then
			localMap[req.id] = req
		end
	end
	
	-- Get tombstones (both incoming and local)
	local tombstones = payload.tombstones or {}
	local localTombstones = self.Info.requestsTombstones or {}
	
	-- Merge: Take all incoming requests
	for id, incomingReq in pairs(incomingMap) do
		local localReq = localMap[id]
		if localReq then
			-- Both have it - take newer timestamp
			local incomingTime = tonumber(incomingReq.updatedAt or 0) or 0
			local localTime = tonumber(localReq.updatedAt or 0) or 0
			if incomingTime >= localTime then
				table.insert(mergedRequests, incomingReq)
				TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: Accepting incoming %s (time %d >= %d)", id, incomingTime, localTime)
			else
				table.insert(mergedRequests, localReq)
				TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: Keeping local %s (time %d > %d)", id, localTime, incomingTime)
			end
		else
			-- Only incoming has it - accept it
			table.insert(mergedRequests, incomingReq)
		end
	end
	
	-- Keep local requests that incoming doesn't have (unless tombstoned)
	local kept, tombstoned = 0, 0
	for id, localReq in pairs(localMap) do
		if not incomingMap[id] then
			-- Check if tombstoned
			local tombstoneTs = tombstones[id] or localTombstones[id]
			if tombstoneTs then
				-- Request was legitimately deleted, don't keep it
				TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: Removing tombstoned %s", id)
				tombstoned = tombstoned + 1
			else
				-- No tombstone - keep our local request (don't accept data loss)
				table.insert(mergedRequests, localReq)
				TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: Protecting local %s (not in incoming, no tombstone)", id)
				kept = kept + 1
			end
		end
	end
	
	local localCountBefore = #localRequests
	self.Info.requests = mergedRequests
	self.Info.requestsVersion = latest
	TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: Merged requests (was %d, incoming %d, merged %d) - kept %d protected, removed %d tombstoned",
		localCountBefore, #sanitized, #mergedRequests, kept, tombstoned)

	local logApplied = payload.requestLogApplied
	if type(logApplied) == "table" then
		-- [BUG-FIX] If incoming snapshot has empty requestLogApplied but we have event log
		-- data, reject it to prevent wiping our tracking. An empty requestLogApplied means
		-- the sender hasn't properly initialized, so their snapshot is incomplete.
		if next(logApplied) == nil and self.Info.requestLog and #self.Info.requestLog > 0 then
			TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: Rejecting snapshot with empty requestLogApplied (we have event log data)")
			logApplied = self.Info.requestLogApplied or {}
		end
		
		-- [SYNC-FIX] Smart-merge requestLogApplied: only accept incoming sequence numbers if they
		-- won't cause us to skip our own local event log entries. This fixes the critical bug where
		-- an incoming snapshot could upgrade requestLogApplied[actor] to a higher value, causing
		-- ReplayRequestLogEntries() to skip local events that should still be applied.
		--
		-- Example bug scenario:
		-- - Local has event log entry: Galdof seq 41 (gromsblood request)
		-- - Local requestLogApplied[Galdof] = 40 (would normally replay seq 41)
		-- - Incoming snapshot has requestLogApplied[Galdof] = 42 but no gromsblood in snapshot
		-- - Old code: upgrade to 42 → replay skips seq 41 → gromsblood disappears!
		-- - New code: detect we have seq 41 locally, reject the upgrade to 42
		local localApplied = self.Info.requestLogApplied or {}
		local upgraded, kept, rejected = 0, 0, 0
		
		-- Build map of max local sequence per actor from our event log
		local maxLocalSeq = {}
		if self.requestLogByActor then
			for actor, entries in pairs(self.requestLogByActor) do
				local maxSeq = 0
				for _, entry in ipairs(entries) do
					local seq = tonumber(entry.seq or 0) or 0
					if seq > maxSeq then
						maxSeq = seq
					end
				end
				maxLocalSeq[actor] = maxSeq
			end
		end
		
		for actor, seq in pairs(logApplied) do
			local incomingSeq = tonumber(seq or 0) or 0
			local localSeq = tonumber(localApplied[actor] or 0) or 0
			local maxLocal = maxLocalSeq[actor] or 0
			
			-- Only accept incoming seq if it's higher than local AND won't skip our event log
			if incomingSeq > localSeq then
				-- Check if accepting this would skip local events
				if incomingSeq > maxLocal then
					-- Incoming seq is beyond our event log, safe to accept
					localApplied[actor] = incomingSeq
					upgraded = upgraded + 1
				else
					-- Incoming seq would mark local events as "already applied"
					-- Keep our local seq so replay will process our events
					TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: Rejecting %s seq %d (would skip local events up to %d)",
						actor, incomingSeq, maxLocal)
					rejected = rejected + 1
				end
			else
				-- Local seq is same or higher, keep it
				kept = kept + 1
			end
		end
		
		self.Info.requestLogApplied = localApplied
		TOGBankClassic_Output:Debug("SYNC", "ApplyRequestSnapshot: Smart-merged requestLogApplied - %d upgraded, %d kept local, %d rejected",
			upgraded, kept, rejected)
		TOGBankClassic_Output:Debug("SYNC", "[PERSIST] After smart-merge: requestLogApplied has %d actors: %s",
			countKeys(self.Info.requestLogApplied or {}),
			table.concat((function() local t = {}; for k,v in pairs(self.Info.requestLogApplied or {}) do table.insert(t, k.."="..v) end; return t end)(), ", "))
	end

	local localActor = self:GetNormalizedPlayer()
	if localActor and localActor ~= "" then
		local appliedSeq = tonumber(self.Info.requestLogApplied[localActor] or 0) or 0
		local localSeq = tonumber(self.Info.requestLogSeq[localActor] or 0) or 0
		if appliedSeq > localSeq then
			TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: Updating local seq from %d to %d", localSeq, appliedSeq))
			self.Info.requestLogSeq[localActor] = appliedSeq
		end
	end

	local tombstones = payload.tombstones
	if type(tombstones) == "table" then
		self.Info.requestsTombstones = copyMap(tombstones)
		TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: Updated tombstones with %d entries",
			countKeys(tombstones)))
	end

	TOGBankClassic_Output:Debug("[UI-003] ApplyRequestSnapshot: Calling NormalizeRequestList")
	self:NormalizeRequestList()
	TOGBankClassic_Output:Debug("[UI-003] ApplyRequestSnapshot: Calling RebuildRequestLogIndex")
	self:RebuildRequestLogIndex()
	TOGBankClassic_Output:Debug("[UI-003] ApplyRequestSnapshot: Calling ReplayRequestLogEntries")
	self:ReplayRequestLogEntries()
	TOGBankClassic_Output:Debug("[UI-003] ApplyRequestSnapshot: Calling PruneRequests")
	self:PruneRequests()
	TOGBankClassic_Output:Debug("[UI-003] ApplyRequestSnapshot: Calling PruneRequestLog")
	self:PruneRequestLog()
	TOGBankClassic_Output:Debug("[UI-003] ApplyRequestSnapshot: Calling PruneRequestTombstones")
	self:PruneRequestTombstones()

	TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: FINAL count = %d requests", #(self.Info.requests or {})))

	self:RefreshRequestsUI()
	return true
end

function Guild:ReplayRequestLogEntries()
	if not self.Info or not self.Info.requestLog or not self.requestLogByActor then
		TOGBankClassic_Output:Debug("[REPLAY-DEBUG] ReplayRequestLogEntries: Early return (missing data)")
		return
	end

	local actorCount = 0
	for _ in pairs(self.requestLogByActor) do actorCount = actorCount + 1 end
	TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] ReplayRequestLogEntries: Starting with %d actors, %d log entries",
		actorCount, #self.Info.requestLog))

	local applied = self.Info.requestLogApplied or {}
	for actor, entries in pairs(self.requestLogByActor) do
		table.sort(entries, function(a, b)
			return (tonumber(a.seq or 0) or 0) < (tonumber(b.seq or 0) or 0)
		end)
		local lastSeq = tonumber(applied[actor] or 0) or 0
		local replayedCount = 0
		local skippedCount = 0
		for _, entry in ipairs(entries) do
			local seq = tonumber(entry.seq or 0) or 0
			if seq > lastSeq then
				local hasRequest = entry.request ~= nil
				local success = self:ApplyRequestLogEntry(entry)
				if success then
					lastSeq = seq
					replayedCount = replayedCount + 1
				else
					TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] REPLAY FAILED: actor=%s, seq=%d, type=%s, hasRequest=%s, requestId=%s",
						actor, seq, entry.type or "nil", tostring(hasRequest), entry.requestId or "nil"))
				end
			else
				skippedCount = skippedCount + 1
			end
		end
		if replayedCount > 0 or skippedCount > 0 then
			TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] Actor %s: replayed=%d, skipped=%d (already applied)",
				actor, replayedCount, skippedCount))
		end
		applied[actor] = lastSeq
	end
	self.Info.requestLogApplied = applied
end

-- Request list pruning based on expiry. Returns (pruned, before, after).
function Guild:PruneRequests()
	if not self.Info or not self.Info.requests then
		return 0, 0, 0
	end

	local before = #self.Info.requests
	local now = GetServerTime()
	local keep = {}
	local pruned = {}
	local latest = tonumber(self.Info.requestsVersion or 0) or 0

	TOGBankClassic_Output:Debug(string.format("[UI-003] PruneRequests: Starting with %d requests", before))

	for _, req in ipairs(self.Info.requests) do
		local updated = tonumber(req.updatedAt or req.date or 0) or 0
		local quantity = tonumber(req.quantity or 0) or 0
		local fulfilled = tonumber(req.fulfilled or 0) or 0
		local isDone = req.status == "fulfilled"
			or req.status == "complete"
			or req.status == "cancelled"
			or (quantity > 0 and fulfilled >= quantity)
		local tooOld = isDone and (now - updated) > REQUEST_LOG.EXPIRY_SECONDS
		if not tooOld then
			table.insert(keep, req)
			if updated > latest then
				latest = updated
			end
		else
			table.insert(pruned, req)
			TOGBankClassic_Output:Debug(string.format("[UI-003] PruneRequests: Pruning request id=%s, status=%s, age=%d seconds",
				req.id or "nil", req.status or "nil", now - updated))
		end
	end

	if #pruned > 0 then
		TOGBankClassic_Output:Debug(string.format("[UI-003] PruneRequests: Pruned %d old completed requests", #pruned))
	end

	self.Info.requests = keep
	self.Info.requestsVersion = latest
	local after = #keep

	TOGBankClassic_Output:Debug(string.format("[UI-003] PruneRequests: Finished with %d requests (%d pruned)", after, before - after))

	return before - after, before, after
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

	local byId = buildRequestIndex(self.Info.requests)
	local idx = byId[requestId]
	local req = idx and self.Info.requests[idx] or nil
	local snapshot = entry.request

	if not req and snapshot then
		local clean = sanitizeRequest(snapshot)
		if clean then
			table.insert(self.Info.requests, clean)
			idx = #self.Info.requests
			req = self.Info.requests[idx]
			TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] ApplyRequestLogEntry: CREATED request from snapshot (requestId=%s, type=%s)",
				requestId, entryType))
		else
			TOGBankClassic_Output:Debug(string.format("[REPLAY-DEBUG] ApplyRequestLogEntry: sanitizeRequest returned nil for snapshot (requestId=%s)",
				requestId))
		end
	end

	if entryType == "delete" then
		if idx then
			table.remove(self.Info.requests, idx)
		end
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
				self.Info.requests[idx] = clean
			end
		end
		return true
	end

	if entryType == "fulfill" then
		TOGBankClassic_Output:Debug("SYNC", "ApplyRequestLogEntry: fulfill entry for requestId=%s, currentStatus=%s, lastStatusOp=%s, entryTs=%d",
			requestId, tostring(req.status), tostring(req.lastStatusOp), entryTs)
		
		-- Check if current status operation has higher priority than fulfill
		local currentStatusOp = req.lastStatusOp or "add"
		local currentPriority = getOperationPriority(currentStatusOp)
		local fulfillPriority = getOperationPriority("fulfill")
		
		if currentPriority > fulfillPriority then
			-- Higher priority status operation (cancel/complete) blocks fulfill
			TOGBankClassic_Output:Debug("SYNC", "ApplyRequestLogEntry: fulfill REJECTED (status=%s set by higher priority op=%s)",
				req.status, currentStatusOp)
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
		if qty > 0 and newFulfilled >= qty and currentPriority <= fulfillPriority then
			req.status = "fulfilled"
			req.statusUpdatedAt = entryTs
			req.lastStatusOp = "fulfill"  -- Track fulfill operation
		end
		if entryTs > 0 then
			req.updatedAt = math.max(tonumber(req.updatedAt or 0) or 0, entryTs)
		end
		return true
	end

	if entryType == "cancel" or entryType == "complete" then
		local newStatus = (entryType == "cancel") and "cancelled" or "complete"
		local statusUpdatedAt = tonumber(req.statusUpdatedAt or req.updatedAt or 0) or 0
		local currentStatusOp = req.lastStatusOp or "add"  -- Default to 'add' if not set
		
		TOGBankClassic_Output:Debug("SYNC", "ApplyRequestLogEntry: %s entry for requestId=%s, entryTs=%d, statusUpdatedAt=%d, currentStatus=%s, currentStatusOp=%s",
			entryType, requestId, entryTs, statusUpdatedAt, tostring(req.status), currentStatusOp)
		
		-- Priority-based conflict resolution
		local incomingPriority = getOperationPriority(entryType)
		local currentPriority = getOperationPriority(currentStatusOp)
		
		local shouldApply = false
		if incomingPriority > currentPriority then
			-- Higher priority operation always wins
			shouldApply = true
			TOGBankClassic_Output:Debug("SYNC", "ApplyRequestLogEntry: Applying due to higher priority (%d > %d)",
				incomingPriority, currentPriority)
		elseif incomingPriority == currentPriority then
			-- Same priority: use timestamp (last-writer-wins)
			if entryTs >= statusUpdatedAt then
				shouldApply = true
				TOGBankClassic_Output:Debug("SYNC", "ApplyRequestLogEntry: Applying due to newer timestamp (%d >= %d)",
					entryTs, statusUpdatedAt)
			else
				TOGBankClassic_Output:Debug("SYNC", "ApplyRequestLogEntry: Status change REJECTED (same priority, older timestamp: %d < %d)",
					entryTs, statusUpdatedAt)
			end
		else
			-- Lower priority operation rejected
			TOGBankClassic_Output:Debug("SYNC", "ApplyRequestLogEntry: Status change REJECTED (lower priority: %d < %d)",
				incomingPriority, currentPriority)
		end
		
		if shouldApply then
			req.status = newStatus
			req.statusUpdatedAt = entryTs
			req.updatedAt = math.max(tonumber(req.updatedAt or 0) or 0, entryTs)
			req.lastStatusOp = entryType  -- Track which operation set the status
			TOGBankClassic_Output:Debug("SYNC", "ApplyRequestLogEntry: Status changed to %s (op=%s)", newStatus, entryType)
		end
		return true
	end

	return false
end

-- Construct a new log entry for local changes.
-- Check if a failed entry is permanently blocked and should update requestLogApplied to prevent infinite retries.
-- Returns: true if entry will never succeed (should mark as processed), false if transient (should retry later)
function Guild:IsEntryPermanentlyBlocked(entry)
	if not entry or type(entry) ~= "table" then
		return true -- Invalid entry structure is permanent
	end
	
	if not self.Info then
		return true -- System error is permanent
	end
	
	if not entry.type or not entry.requestId then
		return true -- Missing required fields is permanent
	end
	
	-- Check tombstone blocking
	local tombstone = self.requestTombstones and self.requestTombstones[entry.requestId]
	if tombstone and entry.ts and entry.ts <= tombstone then
		return true -- Tombstone blocking is permanent
	end
	
	-- Check priority-based blocking for fulfill operations
	if entry.type == "fulfill" then
		local request = self:FindRequestByID(entry.requestId)
		if request then
			local currentStatusOp = request.lastStatusOp or "add"
			local currentPriority = getOperationPriority(currentStatusOp)
			local fulfillPriority = getOperationPriority("fulfill")
			
			if currentPriority > fulfillPriority then
				return true -- Priority blocking is permanent (fulfill can't override cancel/complete)
			end
			
			-- Check for invalid delta
			if not entry.delta or tonumber(entry.delta or 0) <= 0 then
				return true -- Invalid delta is permanent
			end
		end
		-- If request not found, it's transient (might arrive later)
		return false
	end
	
	-- For cancel/complete, if request doesn't exist, it's transient
	if entry.type == "cancel" or entry.type == "complete" then
		local request = self:FindRequestByID(entry.requestId)
		if not request then
			return false -- Request might arrive later
		end
	end
	
	-- Unknown operation type is permanent
	if entry.type ~= "add" and entry.type ~= "fulfill" and entry.type ~= "cancel" and entry.type ~= "complete" and entry.type ~= "delete" then
		return true
	end
	
	-- Default: not permanently blocked
	return false
end

-- Check if a failed entry is permanently blocked and should update requestLogApplied to prevent infinite retries.
-- Returns: true if entry will never succeed (should mark as processed), false if transient (should retry later)
function Guild:IsEntryPermanentlyBlocked(entry)
	if not entry or type(entry) ~= "table" then
		return true -- Invalid entry structure is permanent
	end
	
	if not self.Info then
		return true -- System error is permanent
	end
	
	if not entry.type or not entry.requestId then
		return true -- Missing required fields is permanent
	end
	
	-- Check tombstone blocking
	local tombstone = self.requestTombstones and self.requestTombstones[entry.requestId]
	if tombstone and entry.ts and entry.ts <= tombstone then
		return true -- Tombstone blocking is permanent
	end
	
	-- Check priority-based blocking for fulfill operations
	if entry.type == "fulfill" then
		local request = self:FindRequestByID(entry.requestId)
		if request then
			local currentStatusOp = request.lastStatusOp or "add"
			local currentPriority = getOperationPriority(currentStatusOp)
			local fulfillPriority = getOperationPriority("fulfill")
			
			if currentPriority > fulfillPriority then
				return true -- Priority blocking is permanent (fulfill can't override cancel/complete)
			end
			
			-- Check for invalid delta
			if not entry.delta or tonumber(entry.delta or 0) <= 0 then
				return true -- Invalid delta is permanent
			end
		end
		-- If request not found, it's transient (might arrive later)
		return false
	end
	
	-- For cancel/complete, if request doesn't exist, it's transient
	if entry.type == "cancel" or entry.type == "complete" then
		local request = self:FindRequestByID(entry.requestId)
		if not request then
			return false -- Request might arrive later
		end
	end
	
	-- Unknown operation type is permanent
	if entry.type ~= "add" and entry.type ~= "fulfill" and entry.type ~= "cancel" and entry.type ~= "complete" and entry.type ~= "delete" then
		return true
	end
	
	-- Default: not permanently blocked
	return false
end

function Guild:BuildRequestLogEntry(entryType, request, extra)
	if not self.Info then
		return nil
	end
	local seq, actor = self:NextRequestLogSeq(self:GetPlayer())
	local now = GetServerTime()
	local clean = request and sanitizeRequest(request) or nil
	local entry = {
		type = entryType,
		actor = actor,
		seq = seq,
		ts = now,
		id = requestLogId(actor, seq),
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

-- Record an entry locally, update indices, and optionally broadcast it.
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

	if self.requestLogIndex and self.requestLogIndex[entry.id] then
		TOGBankClassic_Output:Debug("[UI-003] RecordRequestLogEntry: Entry already in log index (duplicate)")
		self.Info.requestLogApplied = self.Info.requestLogApplied or {}
		local actor = entry.actor or "unknown"
		local seq = tonumber(entry.seq or 0) or 0
		if seq > 0 then
			self.Info.requestLogApplied[actor] = math.max(tonumber(self.Info.requestLogApplied[actor] or 0) or 0, seq)
		end
		return true
	end

	TOGBankClassic_Output:Debug(string.format("[UI-003] RecordRequestLogEntry: Applying log entry (requests before = %d)", #(self.Info.requests or {})))

	if not self:ApplyRequestLogEntry(entry) then
		TOGBankClassic_Output:Debug("[UI-003] RecordRequestLogEntry FAILED: ApplyRequestLogEntry returned false")
		return false
	end

	TOGBankClassic_Output:Debug(string.format("[UI-003] RecordRequestLogEntry: Applied successfully (requests after = %d)", #(self.Info.requests or {})))

	self:AppendRequestLogEntry(entry)
	self.Info.requestLogApplied = self.Info.requestLogApplied or {}
	local actor = entry.actor or "unknown"
	local seq = tonumber(entry.seq or 0) or 0
	if seq > 0 then
		self.Info.requestLogApplied[actor] = math.max(tonumber(self.Info.requestLogApplied[actor] or 0) or 0, seq)
	end

	if entry.ts and entry.ts > 0 then
		self:TouchRequestsVersion(entry.ts)
	end

	TOGBankClassic_Output:Debug("[UI-003] RecordRequestLogEntry: Calling PruneIfNeeded")
	self:PruneIfNeeded()
	TOGBankClassic_Output:Debug(string.format("[UI-003] RecordRequestLogEntry: After PruneIfNeeded (requests = %d)", #(self.Info.requests or {})))

	if broadcast then
		TOGBankClassic_Output:Debug("[UI-003] RecordRequestLogEntry: Broadcasting log entry to guild")
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
		self.Info and self.Info.requests and #self.Info.requests or 0))

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
		requests = self.Info.requests or {},
		requestLogApplied = self.Info.requestLogApplied or {},
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

function Guild:QueryRequestLog(player, logFrom, priority)
	-- Send wildcard query (v0.7.14+)
	-- Note: Old clients won't respond to wildcard, but targeted queries flood guild chat
	-- and trigger WoW throttling which blocks responses. Wildcard-only is the fix.
	local data = TOGBankClassic_Core:SerializeWithChecksum({ player = "*", type = "requests-log", logFrom = logFrom })
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, priority or "BULK")
	TOGBankClassic_Output:DebugComm("[SYNC-004] QUERY REQUEST LOG: Sent wildcard query (removed targeted spam)")
end

function Guild:ReceiveRequestsData(payload)
	-- TOGBankClassic_Core:Print("[MERGE] ReceiveRequestsData called - RETURNING IMMEDIATELY FOR TESTING")
	-- return ADOPTION_STATUS.IGNORED  -- Bypass everything for now

	if not payload or type(payload) ~= "table" then
		TOGBankClassic_Output:Debug("[SYNC-003n] ReceiveRequestsData: INVALID - payload not a table")
		return ADOPTION_STATUS.INVALID
	end
	if not self.Info then
		TOGBankClassic_Output:Debug("[SYNC-003n] ReceiveRequestsData: IGNORED - self.Info is nil")
		return ADOPTION_STATUS.IGNORED
	end
	self:EnsureRequestsInitialized()

	local incomingCount = (payload.requests and type(payload.requests) == "table") and #payload.requests or 0
	local localCountBefore = self.Info.requests and #self.Info.requests or 0
	TOGBankClassic_Output:Debug(string.format("[SYNC-003n] ReceiveRequestsData: START - local=%d requests, incoming=%d requests",
		localCountBefore, incomingCount))

	local function maxUpdatedAt(list)
		local latest = 0
		local nonTableCount = 0
		for i, req in ipairs(list or {}) do
			if type(req) == "table" then
				local updated = tonumber(req.updatedAt or req.date or 0) or 0
				if updated > latest then
					latest = updated
				end
			else
				nonTableCount = nonTableCount + 1
				TOGBankClassic_Core:Print(string.format("[MERGE] WARNING: Request array has non-table entry at index %d (type=%s)", i, type(req)))
			end
		end
		if nonTableCount > 0 then
			TOGBankClassic_Core:Print(string.format("[MERGE] Found %d non-table entries in requests array - possible SavedVariables corruption", nonTableCount))
		end
		return latest
	end

	-- Calculate versions
	-- Modern clients (v7.10+) have requestLogApplied - skip version calc and always merge (SYNC-003o)
	-- Legacy clients need version comparison
	local localVersion = 0
	local incomingVersion = 0
	local isNewer = true

	if not payload.requestLogApplied then
		-- Legacy client without requestLogApplied - use stored versions only
		TOGBankClassic_Output:Debug("REQUESTS", "[MERGE] Legacy client detected - using version comparison")
		localVersion = tonumber(self.Info.requestsVersion or 0) or 0
		incomingVersion = tonumber(payload.version or 0) or 0

		-- Validate incoming version to prevent integer overflow (DATA-003)
		local MAX_TIMESTAMP = 2147483647  -- Max 32-bit signed integer (Jan 19, 2038)
		if incomingVersion > MAX_TIMESTAMP then
			TOGBankClassic_Output:Warn("Rejecting corrupted request snapshot with invalid version: %s (max timestamp exceeded)", tostring(incomingVersion))
			return
		end

		isNewer = incomingVersion > localVersion
	else
		-- Modern client with requestLogApplied - check sequence numbers (SYNC-003o)
		-- Skip expensive maxUpdatedAt() iteration
		local incomingLog = payload.requestLogApplied
		if type(incomingLog) == "table" then
			local localLog = self.Info.requestLogApplied or {}
			for actor, seq in pairs(incomingLog) do
				local incomingSeq = tonumber(seq or 0) or 0
				local localSeq = tonumber(localLog[actor] or 0) or 0
				if incomingSeq > localSeq then
					TOGBankClassic_Output:Debug(string.format("[SYNC-003n] ReceiveRequestsData: isNewer=true (log check) - actor=%s, localSeq=%d, incomingSeq=%d",
						actor, localSeq, incomingSeq))
					isNewer = true
					break
				end
			end
		end
	end

	TOGBankClassic_Output:Debug(string.format("[SYNC-003n] ReceiveRequestsData: Versions - local=%d, incoming=%d",
		localVersion, incomingVersion))

	-- SYNC-003o: Always merge request snapshots, never reject as STALE
	-- Different players have different subsets of requests. Even if versions match,
	-- the incoming snapshot may contain requests we don't have. ApplyRequestSnapshot()
	-- handles merging correctly by preserving both incoming and local requests.
	TOGBankClassic_Output:Debug(string.format("[SYNC-003o] ReceiveRequestsData: Calling ApplyRequestSnapshot (isNewer=%s, localVer=%d, incomingVer=%d)",
		tostring(isNewer), localVersion, incomingVersion))

	if self:ApplyRequestSnapshot(payload) then
		local localCountAfter = self.Info.requests and #self.Info.requests or 0
		TOGBankClassic_Output:Debug(string.format("[SYNC-003n] ReceiveRequestsData: ADOPTED - final count=%d (was %d, incoming had %d)",
			localCountAfter, localCountBefore, incomingCount))
		return ADOPTION_STATUS.ADOPTED
	end
	TOGBankClassic_Output:Debug("[SYNC-003n] ReceiveRequestsData: INVALID - ApplyRequestSnapshot returned false")
	-- Dead code: uses undefined variables (numGuildMembers, logFrom) and is unreachable after ApplyRequestSnapshot failure
	-- TOGBankClassic_Output:DebugComm("QUERY REQUEST LOG: Guild has %d members, checking for online...", numGuildMembers)

	-- local onlineCount = 0
	-- for i = 1, numGuildMembers do
	-- 	local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
	-- 	if online and name then
	-- 		local normalized = self:NormalizeName(name)
	-- 		if normalized then
	-- 			local targetedData = TOGBankClassic_Core:SerializeWithChecksum({ player = normalized, type = "requests-log", logFrom = logFrom })
	-- 			TOGBankClassic_Core:SendCommMessage("togbank-r", targetedData, "Guild", nil, "BULK")
	-- 			onlineCount = onlineCount + 1
	-- 			if onlineCount <= 5 then
	-- 				TOGBankClassic_Output:DebugComm("QUERY REQUEST LOG: Sent targeted query #%d to %s", onlineCount, normalized)
	-- 			end
	-- 		end
	-- 	end
	-- end
	return ADOPTION_STATUS.INVALID
end

function Guild:GetRequestLogSummary()
	if not self.Info or not self.Info.requestLogApplied then
		return nil
	end
	local summary = {}
	for actor, seq in pairs(self.Info.requestLogApplied) do
		local num = tonumber(seq or 0) or 0
		if num > 0 then
			summary[actor] = num
		end
	end
	return summary
end

function Guild:SendRequestsVersionPing()
	if not self.Info then
		return
	end
	local payload = {
		requests = self:GetRequestsVersion(),
		requestLog = self:GetRequestLogSummary(),
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

function Guild:SendRequestLogEntries(target, logFrom)
	if not logFrom or type(logFrom) ~= "table" then
		TOGBankClassic_Output:DebugComm("SendRequestLogEntries: Skipping (invalid logFrom parameter)")
		return
	end
	if not self.Info then
		TOGBankClassic_Output:DebugComm("SendRequestLogEntries: Skipping (self.Info is nil)")
		return
	end
	self:EnsureRequestsInitialized()

	-- If we don't have a request log, send snapshot instead (player will get all data)
	if not self.Info.requestLog then
		self:SendRequestsSnapshot(target)
		return
	end

	local entriesToSend = {}

	for actor, fromSeq in pairs(logFrom) do
		local list = self.requestLogByActor and self.requestLogByActor[actor] or nil
		if not list or #list == 0 then
			-- No log entries for this actor, send snapshot so querier gets current state
			self:SendRequestsSnapshot(target)
			return
		end
		local minSeq = tonumber(list[1].seq or 0) or 0
		local startSeq = tonumber(fromSeq or 0) or 0
		if startSeq <= 0 or startSeq < minSeq then
			-- Requested sequence is too old or invalid, send full snapshot
			self:SendRequestsSnapshot(target)
			return
		end
		for _, entry in ipairs(list) do
			local seq = tonumber(entry.seq or 0) or 0
			if seq >= startSeq then
				table.insert(entriesToSend, entry)
			end
		end
	end

	-- If no entries to send, send empty log response (so querier knows we're caught up)
	if #entriesToSend == 0 then
		local payload = { type = "requests-log", player = "*", logEntries = {} }
		local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
		TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", target, "BULK")
		return
	end

	local chunk = {}
	local count = 0
	local maxPerChunk = 30
	for _, entry in ipairs(entriesToSend) do
		table.insert(chunk, entry)
		count = count + 1
		if count >= maxPerChunk then
			local payload = { type = "requests-log", player = "*", logEntries = chunk }
			local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
			TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", target, "BULK")
			chunk = {}
			count = 0
		end
	end

	if #chunk > 0 then
		local payload = { type = "requests-log", player = "*", logEntries = chunk }
		local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
		TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", target, "BULK")
	end
end

function Guild:ReceiveRequestLogEntry(entry, sender)
	if not entry or type(entry) ~= "table" then
		return false
	end
	return self:ReceiveRequestLogEntries({ logEntries = { entry } }, sender)
end

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
	
	TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestLogEntries: Processing %d entries from %s", #entries, tostring(sender))
	
	self:EnsureRequestsInitialized()

	local entriesByActor = {}
	for _, entry in ipairs(entries) do
		if entry and entry.actor and entry.seq then
			local actor = entry.actor
			if not entriesByActor[actor] then
				entriesByActor[actor] = {}
			end
			table.insert(entriesByActor[actor], entry)
			TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestLogEntries: Entry from actor=%s, seq=%d, type=%s, requestId=%s",
				tostring(actor), tonumber(entry.seq or 0), tostring(entry.type), tostring(entry.requestId))
		end
	end

	for actor, list in pairs(entriesByActor) do
		table.sort(list, function(a, b)
			return (tonumber(a.seq or 0) or 0) < (tonumber(b.seq or 0) or 0)
		end)

		-- Safety check: Info might be nil if guild data not loaded yet
		if not self.Info then
			TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestLogEntries: Info is nil, aborting")
			return
		end

		local applied = self.Info.requestLogApplied or {}
		local lastSeq = tonumber(applied[actor] or 0) or 0
		TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestLogEntries: Processing actor=%s, lastSeq=%d, entries=%d",
			tostring(actor), lastSeq, #list)
		
		local gapDetected = false
		for _, entry in ipairs(list) do
			local seq = tonumber(entry.seq or 0) or 0
			
			-- Detect gaps for querying missing data
			if not gapDetected and seq > lastSeq + 1 then
				TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestLogEntries: Gap detected - seq=%d, lastSeq=%d, querying missing entries", seq, lastSeq)
				if sender then
					self:QueryRequestLog(sender, { [actor] = lastSeq + 1 })
				end
				gapDetected = true
			end
			
			-- Always try to record entries - RecordRequestLogEntry will handle deduplication via entry.id
			if seq <= lastSeq then
				TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestLogEntries: Processing seq=%d (might be duplicate, checking entry.id)", seq)
			else
				TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestLogEntries: Processing seq=%d", seq)
			end
			
			-- Let RecordRequestLogEntry handle deduplication - it checks entry.id in requestLogIndex
			if self:RecordRequestLogEntry(entry, false) then
				-- Update lastSeq to highest successfully recorded
				if seq > lastSeq then
					lastSeq = seq
					TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestLogEntries: Recorded seq=%d successfully, updated lastSeq", seq)
				end
			else
				-- [SYNC-005] Check if failure is permanent - if so, mark as processed to prevent infinite retries
				local isPermanent = self:IsEntryPermanentlyBlocked(entry)
				if isPermanent then
					TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestLogEntries: Entry seq=%d permanently blocked, marking as processed", seq)
					if seq > lastSeq then
						lastSeq = seq
					end
				else
					TOGBankClassic_Output:Debug("SYNC", "ReceiveRequestLogEntries: Failed to record seq=%d (transient failure, will retry)", seq)
				end
			end
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
		TOGBankClassic_Output:Debug(string.format("[UI-003] AddRequest SUCCESS: Total requests now = %d", #(self.Info.requests or {})))
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

	local byId = buildRequestIndex(self.Info.requests)
	local idx = byId[requestId]
	if not idx then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: Request not found in index")
		return false
	end

	local req = self.Info.requests[idx]
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
	
	TOGBankClassic_Output:Debug("SYNC", "CancelRequest: Recording log entry with broadcast=true, entry.id=%s", tostring(entry.id))
	local result = self:RecordRequestLogEntry(entry, true)
	TOGBankClassic_Output:Debug("SYNC", "CancelRequest: RecordRequestLogEntry returned %s", tostring(result))
	return result
end

function Guild:CompleteRequest(requestId, actor)
	if not self.Info or not self.Info.requests then
		return false
	end
	if not requestId then
		return false
	end

	self:EnsureRequestsInitialized()

	local byId = buildRequestIndex(self.Info.requests)
	local idx = byId[requestId]
	if not idx then
		return false
	end

	local req = self.Info.requests[idx]
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

	local byId = buildRequestIndex(self.Info.requests)
	local idx = byId[requestId]
	if not idx then
		return false
	end

	local req = self.Info.requests[idx]
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
	for _, req in ipairs(self.Info.requests) do
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

-- Diagnostics: print request log entries to chat.
function Guild:PrintRequestLog(limitArg)
	if not self.Info then
		TOGBankClassic_Output:Response("Request log: no guild info loaded.")
		return
	end
	self:EnsureRequestsInitialized()

	local log = self.Info.requestLog or {}
	local total = #log
	if total == 0 then
		TOGBankClassic_Output:Response("Request log is empty.")
		return
	end

	local limit = tonumber(limitArg or "")
	if limitArg and tostring(limitArg):lower() == "all" then
		limit = nil
	elseif limit and limit <= 0 then
		limit = nil
	end

	local entries = {}
	for _, entry in ipairs(log) do
		table.insert(entries, entry)
	end
	table.sort(entries, function(a, b)
		local ta = tonumber(a.ts or 0) or 0
		local tb = tonumber(b.ts or 0) or 0
		if ta == tb then
			local aa = tostring(a.actor or "")
			local bb = tostring(b.actor or "")
			if aa == bb then
				return (tonumber(a.seq or 0) or 0) < (tonumber(b.seq or 0) or 0)
			end
			return aa < bb
		end
		return ta < tb
	end)

	local startIndex = 1
	if limit and total > limit then
		startIndex = total - limit + 1
	end

	local shown = total - startIndex + 1
	local header = string.format("Request log: %d entries (showing %d).", total, shown)
	if limit and total > limit then
		header = header .. " Use /togbank requestlog all for full log."
	end
	TOGBankClassic_Output:Response(header)

	for i = startIndex, total do
		local entry = entries[i]
		local ts = tonumber(entry.ts or 0) or 0
		local tsText = ts > 0 and date("%Y-%m-%d %H:%M:%S", ts) or "unknown"
		local actor = tostring(entry.actor or "unknown")
		local seq = tostring(entry.seq or "0")
		local entryType = tostring(entry.type or "unknown")
		local requestId = tostring(entry.requestId or (entry.request and entry.request.id) or "unknown")
		local req = entry.request or {}
		local item = tostring(req.item or "")
		local qty = tostring(req.quantity or "")
		local requester = tostring(req.requester or "")
		local bank = tostring(req.bank or "")
		local status = tostring(req.status or "")
		local delta = entry.delta and (" delta=" .. tostring(entry.delta)) or ""

		local line = string.format(
			'[%s] %s#%s %s id=%s item="%s" qty=%s requester=%s bank=%s status=%s%s',
			tsText,
			actor,
			seq,
			entryType,
			requestId,
			item,
			qty,
			requester,
			bank,
			status,
			delta
		)
		TOGBankClassic_Output:Response(line)
	end
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
	local logPruned, logBefore, logAfter = self:PruneRequestLog()
	local tombstonesPruned, tombstonesBefore, tombstonesAfter = self:PruneRequestTombstones()

	-- Report results
	local totalPruned = requestsPruned + logPruned + tombstonesPruned

	if totalPruned == 0 then
		TOGBankClassic_Output:Response("Compact: nothing to prune.")
		TOGBankClassic_Output:Response("  Requests: %d, Log entries: %d, Tombstones: %d", requestsAfter, logAfter, tombstonesAfter)
	else
		TOGBankClassic_Output:Response("Compact: pruned %d entries.", totalPruned)
		if requestsPruned > 0 then
			TOGBankClassic_Output:Response("  Requests: %d -> %d (-%d)", requestsBefore, requestsAfter, requestsPruned)
		else
			TOGBankClassic_Output:Response("  Requests: %d", requestsAfter)
		end
		if logPruned > 0 then
			TOGBankClassic_Output:Response("  Log entries: %d -> %d (-%d)", logBefore, logAfter, logPruned)
		else
			TOGBankClassic_Output:Response("  Log entries: %d", logAfter)
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
