TOGBankClassic_Guild = TOGBankClassic_Guild or {}
local Guild = TOGBankClassic_Guild

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
- add: last-writer-wins by updatedAt.
- fulfill: additive delta, clamped by quantity.
- cancel/complete: last-writer-wins by statusUpdatedAt.
- delete: tombstone wins over older updates.

Sync flow:
- Version broadcast includes requestsVersion + requestLog summary.
- Missing log entries are fetched via requests-log query.
- Too-old gaps fall back to full snapshot ("requests").
- Snapshot includes requestLogApplied + tombstones to reconcile state.
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

	if not self.requestLogIndex or not self.requestLogByActor then
		self:RebuildRequestLogIndex()
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
	if not self.Info.requestLogApplied or next(self.Info.requestLogApplied) == nil then
		local applied = {}
		for actor, list in pairs(self.requestLogByActor) do
			local maxSeq = 0
			for _, entry in ipairs(list) do
				local seq = tonumber(entry.seq or 0) or 0
				if seq > maxSeq then
					maxSeq = seq
				end
			end
			if maxSeq > 0 then
				applied[actor] = maxSeq
			end
		end
		self.Info.requestLogApplied = applied
	end
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
					latest = clean.updatedAt
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

	TOGBankClassic_Core:Print("[MERGE] ApplyRequestSnapshot: Checking payload")
	
	local incomingList = payload.requests
	if not incomingList or type(incomingList) ~= "table" then
		TOGBankClassic_Core:Print("[MERGE] ApplyRequestSnapshot FAILED: no requests in payload")
		TOGBankClassic_Output:Debug("[UI-003] ApplyRequestSnapshot FAILED: no requests in payload")
		return false
	end

	TOGBankClassic_Core:Print(string.format("[MERGE] ApplyRequestSnapshot: Sanitizing %d incoming requests", #incomingList))
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

	TOGBankClassic_Core:Print(string.format("[MERGE] ApplyRequestSnapshot: Sanitized to %d requests", #sanitized))
	TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: Sanitized to %d requests", #sanitized))

	-- Merge with existing requests instead of replacing
	-- [SYNC-006] Build index of local requests by ID with timestamps
	TOGBankClassic_Core:Print("[MERGE] ApplyRequestSnapshot: Building local index")
	local localById = {}
	for _, localReq in ipairs(self.Info.requests or {}) do
		if localReq.id then
			localById[localReq.id] = localReq
		end
	end

	local tombstones = payload.tombstones or {}
	local merged = {}
	
	TOGBankClassic_Core:Print(string.format("[MERGE] ApplyRequestSnapshot: Merging %d incoming requests", #sanitized))
	
	-- [SYNC-006] Add incoming requests, but prefer newer local version if exists
	local incomingProcessed = {}
	for _, incomingReq in ipairs(sanitized) do
		incomingProcessed[incomingReq.id] = true
		local localReq = localById[incomingReq.id]
		
		if localReq then
			-- Both exist - compare timestamps
			local localUpdated = tonumber(localReq.updatedAt or localReq.date or 0) or 0
			local incomingUpdated = tonumber(incomingReq.updatedAt or incomingReq.date or 0) or 0
			
			if localUpdated > incomingUpdated then
				table.insert(merged, localReq)
				TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: Keeping newer local request id=%s (local=%d, incoming=%d)", 
					incomingReq.id, localUpdated, incomingUpdated))
			else
				table.insert(merged, incomingReq)
				if incomingUpdated > localUpdated then
					TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: Replacing with newer incoming request id=%s (local=%d, incoming=%d)", 
						incomingReq.id, localUpdated, incomingUpdated))
				end
			end
		else
			-- Only incoming has it
			table.insert(merged, incomingReq)
		end
	end
	
	TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: Processed %d incoming requests", #sanitized))
	
	-- [SYNC-006] Add local requests that weren't in incoming (and not tombstoned)
	local localPreservedCount = 0
	for _, localReq in ipairs(self.Info.requests or {}) do
		if localReq.id and not incomingProcessed[localReq.id] then
			local tombstoneTs = tonumber(tombstones[localReq.id] or 0) or 0
			local localUpdated = tonumber(localReq.updatedAt or localReq.date or 0) or 0
			-- Only keep if not tombstoned or if local update is newer than tombstone
			if tombstoneTs == 0 or localUpdated > tombstoneTs then
				table.insert(merged, localReq)
				localPreservedCount = localPreservedCount + 1
				TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: Preserving local-only request id=%s, requester=%s, item=%s", 
					localReq.id, localReq.requester or "nil", localReq.item or "nil"))
			else
				TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: DROPPING local request id=%s (tombstoned at %d, updated at %d)", 
					localReq.id, tombstoneTs, localUpdated))
			end
		end
	end
	
	TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: Preserved %d local-only requests, merged list has %d total", 
		localPreservedCount, #merged))
	
	-- [SYNC-005] FIX: Actually use the merged list!
	TOGBankClassic_Core:Print(string.format("[MERGE] ApplyRequestSnapshot: Assigning merged list (%d requests)", #merged))
	self.Info.requests = merged
	self.Info.requestsVersion = latest

	TOGBankClassic_Core:Print("[MERGE] ApplyRequestSnapshot: SUCCESS - returning true")

	local logApplied = payload.requestLogApplied
	if type(logApplied) == "table" then
		self.Info.requestLogApplied = copyMap(logApplied)
		TOGBankClassic_Output:Debug(string.format("[UI-003] ApplyRequestSnapshot: Updated requestLogApplied with %d actors", 
			countKeys(logApplied)))
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
		return
	end
	local applied = self.Info.requestLogApplied or {}
	for actor, entries in pairs(self.requestLogByActor) do
		table.sort(entries, function(a, b)
			return (tonumber(a.seq or 0) or 0) < (tonumber(b.seq or 0) or 0)
		end)
		local lastSeq = tonumber(applied[actor] or 0) or 0
		for _, entry in ipairs(entries) do
			local seq = tonumber(entry.seq or 0) or 0
			if seq > lastSeq then
				if self:ApplyRequestLogEntry(entry) then
					lastSeq = seq
				end
			end
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
		return false
	end
	if not self.Info then
		return false
	end
	self:EnsureRequestsInitialized()

	local entryType = entry.type
	if not entryType then
		return false
	end
	local entryTs = tonumber(entry.ts or 0) or 0
	local requestId = entry.requestId or (entry.request and entry.request.id)
	if not requestId then
		return false
	end

	local tombstones = self.Info.requestsTombstones or {}
	local tombstoneTs = tonumber(tombstones[requestId] or 0) or 0
	if tombstoneTs > 0 and entryTs > 0 and entryTs <= tombstoneTs then
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
		if req.status == "cancelled" or req.status == "complete" then
			return false
		end
		local delta = tonumber(entry.delta or 0) or 0
		if delta <= 0 then
			return false
		end
		local qty = tonumber(req.quantity or 0) or 0
		local fulfilled = tonumber(req.fulfilled or 0) or 0
		local newFulfilled = fulfilled + delta
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

-- Construct a new log entry for local changes.
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
	return tonumber(self.Info.requestsVersion or 0) or 0
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

function Guild:QueryRequestsSnapshot(player)
	-- Send wildcard query (v0.7.14+)
	-- Note: Old clients won't respond to wildcard, but targeted queries flood guild chat
	-- and trigger WoW throttling which blocks responses. Wildcard-only is the fix.
	local data = TOGBankClassic_Core:SerializeWithChecksum({ player = "*", type = "requests" })
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, "BULK")
	TOGBankClassic_Output:DebugComm("[SYNC-004] QUERY REQUESTS: Sent wildcard query (removed targeted spam)")
end

function Guild:QueryRequestLog(player, logFrom)
	-- Send wildcard query (v0.7.14+)
	-- Note: Old clients won't respond to wildcard, but targeted queries flood guild chat
	-- and trigger WoW throttling which blocks responses. Wildcard-only is the fix.
	local data = TOGBankClassic_Core:SerializeWithChecksum({ player = "*", type = "requests-log", logFrom = logFrom })
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, "BULK")
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
	TOGBankClassic_Core:Print(string.format("[MERGE] START - local=%d, incoming=%d", localCountBefore, incomingCount))
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
		TOGBankClassic_Core:Print("[MERGE] Legacy client detected - using version comparison")
		localVersion = tonumber(self.Info.requestsVersion or 0) or 0
		incomingVersion = tonumber(payload.version or 0) or 0
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
		TOGBankClassic_Core:Print(string.format("[MERGE] COMPLETE - before=%d, after=%d", localCountBefore, localCountAfter))
		TOGBankClassic_Output:Debug(string.format("[SYNC-003n] ReceiveRequestsData: ADOPTED - final count=%d (was %d, incoming had %d)", 
			localCountAfter, localCountBefore, incomingCount))
		return ADOPTION_STATUS.ADOPTED
	end
	TOGBankClassic_Output:Debug("[SYNC-003n] ReceiveRequestsData: INVALID - ApplyRequestSnapshot returned false")
	TOGBankClassic_Output:DebugComm("QUERY REQUEST LOG: Guild has %d members, checking for online...", numGuildMembers)
	
	local onlineCount = 0
	for i = 1, numGuildMembers do
		local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
		if online and name then
			local normalized = self:NormalizeName(name)
			if normalized then
				local targetedData = TOGBankClassic_Core:SerializeWithChecksum({ player = normalized, type = "requests-log", logFrom = logFrom })
				TOGBankClassic_Core:SendCommMessage("togbank-r", targetedData, "Guild", nil, "BULK")
				onlineCount = onlineCount + 1
				if onlineCount <= 5 then
					TOGBankClassic_Output:DebugComm("QUERY REQUEST LOG: Sent targeted query #%d to %s", onlineCount, normalized)
				end
			end
		end
	end
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
		return
	end
	local payload = { type = "requests-log", logEntries = { entry } }
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	-- Use ALERT priority for immediate request broadcasts (highest priority)
	-- Request creations are very rare (10-20/day) and need guaranteed immediate delivery
	TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", target, "ALERT")
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
		return
	end
	local entries = payload.logEntries
	if not entries or type(entries) ~= "table" then
		return
	end
	self:EnsureRequestsInitialized()

	local entriesByActor = {}
	for _, entry in ipairs(entries) do
		if entry and entry.actor and entry.seq then
			local actor = entry.actor
			if not entriesByActor[actor] then
				entriesByActor[actor] = {}
			end
			table.insert(entriesByActor[actor], entry)
		end
	end

	for actor, list in pairs(entriesByActor) do
		table.sort(list, function(a, b)
			return (tonumber(a.seq or 0) or 0) < (tonumber(b.seq or 0) or 0)
		end)
		
		-- Safety check: Info might be nil if guild data not loaded yet
		if not self.Info then
			return
		end
		
		local applied = self.Info.requestLogApplied or {}
		local lastSeq = tonumber(applied[actor] or 0) or 0
		for _, entry in ipairs(list) do
			local seq = tonumber(entry.seq or 0) or 0
			if seq <= lastSeq then
				-- skip duplicates
			elseif seq == lastSeq + 1 then
				if self:RecordRequestLogEntry(entry, false) then
					lastSeq = seq
				end
			else
				if sender then
					self:QueryRequestLog(sender, { [actor] = lastSeq + 1 })
				end
				break
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
	if req.status == "fulfilled" or req.status == "complete" or (quantity > 0 and fulfilled >= quantity) then
		return false
	end

	local actorName = actor or self:GetPlayer()
	if not self:CanCancelRequest(req, actorName) then
		return false
	end

	local entry = self:BuildRequestLogEntry("cancel", req)
	if not entry then
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
			local entry = self:BuildRequestLogEntry("fulfill", req, { delta = delta })
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

