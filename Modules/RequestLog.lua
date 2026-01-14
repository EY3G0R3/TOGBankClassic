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
			else
				local existingIdx = byId[clean.id]
				if existingIdx then
					local existing = normalized[existingIdx]
					local existingUpdated = tonumber(existing.updatedAt or existing.date or 0) or 0
					local incomingUpdated = tonumber(clean.updatedAt or clean.date or 0) or 0
					if incomingUpdated > existingUpdated then
						normalized[existingIdx] = clean
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
		return false
	end
	if not self.Info then
		return false
	end
	self:EnsureRequestsInitialized()

	local incomingList = payload.requests
	if not incomingList or type(incomingList) ~= "table" then
		return false
	end

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

	self.Info.requests = sanitized
	self.Info.requestsVersion = latest

	local logApplied = payload.requestLogApplied
	if type(logApplied) == "table" then
		self.Info.requestLogApplied = copyMap(logApplied)
	end

	local localActor = self:GetNormalizedPlayer()
	if localActor and localActor ~= "" then
		local appliedSeq = tonumber(self.Info.requestLogApplied[localActor] or 0) or 0
		local localSeq = tonumber(self.Info.requestLogSeq[localActor] or 0) or 0
		if appliedSeq > localSeq then
			self.Info.requestLogSeq[localActor] = appliedSeq
		end
	end

	local tombstones = payload.tombstones
	if type(tombstones) == "table" then
		self.Info.requestsTombstones = copyMap(tombstones)
	end

	self:NormalizeRequestList()
	self:RebuildRequestLogIndex()
	self:ReplayRequestLogEntries()
	self:PruneRequests()
	self:PruneRequestLog()
	self:PruneRequestTombstones()
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
	local latest = tonumber(self.Info.requestsVersion or 0) or 0

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
		end
	end

	self.Info.requests = keep
	self.Info.requestsVersion = latest
	local after = #keep
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
		return false
	end
	if not self.Info then
		return false
	end
	self:EnsureRequestsInitialized()
	if self.requestLogIndex and self.requestLogIndex[entry.id] then
		self.Info.requestLogApplied = self.Info.requestLogApplied or {}
		local actor = entry.actor or "unknown"
		local seq = tonumber(entry.seq or 0) or 0
		if seq > 0 then
			self.Info.requestLogApplied[actor] = math.max(tonumber(self.Info.requestLogApplied[actor] or 0) or 0, seq)
		end
		return true
	end
	if not self:ApplyRequestLogEntry(entry) then
		return false
	end

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
	self:PruneIfNeeded()
	if broadcast then
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
	if not self.Info or not self.Info.requests then
		return
	end
	self:NormalizeRequestList()
	local payload = {
		type = "requests",
		version = self:GetRequestsVersion(),
		requests = self.Info.requests,
		requestLogApplied = self.Info.requestLogApplied,
		tombstones = self.Info.requestsTombstones,
	}
	local data = TOGBankClassic_Core:Serialize(payload)
	TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", target, "BULK")
end

function Guild:SendRequestsData(target)
	self:SendRequestsSnapshot(target)
end

function Guild:QueryRequestsSnapshot(player)
	if not player then
		return
	end
	local data = TOGBankClassic_Core:Serialize({ player = player, type = "requests" })
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, "BULK")
end

function Guild:QueryRequestLog(player, logFrom)
	if not player then
		return
	end
	local data = TOGBankClassic_Core:Serialize({ player = player, type = "requests-log", logFrom = logFrom })
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, "BULK")
end

function Guild:ReceiveRequestsData(payload)
	if not payload or type(payload) ~= "table" then
		return ADOPTION_STATUS.INVALID
	end
	if not self.Info then
		return ADOPTION_STATUS.IGNORED
	end
	self:EnsureRequestsInitialized()

	local function maxUpdatedAt(list)
		local latest = 0
		for _, req in ipairs(list or {}) do
			local updated = tonumber(req.updatedAt or req.date or 0) or 0
			if updated > latest then
				latest = updated
			end
		end
		return latest
	end

	local localVersion = tonumber(self.Info.requestsVersion or 0) or 0
	if localVersion == 0 and self.Info.requests and #self.Info.requests > 0 then
		localVersion = maxUpdatedAt(self.Info.requests)
	end

	local incomingVersion = tonumber(payload.version or 0) or 0
	if incomingVersion == 0 then
		incomingVersion = maxUpdatedAt(payload.requests)
	end

	local isNewer = incomingVersion > localVersion
	if not isNewer then
		local incomingLog = payload.requestLogApplied
		if type(incomingLog) == "table" then
			local localLog = self.Info.requestLogApplied or {}
			for actor, seq in pairs(incomingLog) do
				local incomingSeq = tonumber(seq or 0) or 0
				local localSeq = tonumber(localLog[actor] or 0) or 0
				if incomingSeq > localSeq then
					isNewer = true
					break
				end
			end
		end
	end

	if not isNewer and localVersion > 0 then
		return ADOPTION_STATUS.STALE
	end

	if self:ApplyRequestSnapshot(payload) then
		return ADOPTION_STATUS.ADOPTED
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
	local data = TOGBankClassic_Core:Serialize(payload)
	TOGBankClassic_Core:SendCommMessage("togbank-v", data, "Guild", nil, "BULK")
end

function Guild:SendRequestLogEntry(entry, target)
	if not entry or type(entry) ~= "table" then
		return
	end
	local payload = { type = "requests-log", logEntries = { entry } }
	local data = TOGBankClassic_Core:Serialize(payload)
	TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", target, "BULK")
end

function Guild:SendRequestLogEntries(target, logFrom)
	if not logFrom or type(logFrom) ~= "table" then
		return
	end
	if not self.Info or not self.Info.requestLog then
		return
	end
	self:EnsureRequestsInitialized()

	local entriesToSend = {}

	for actor, fromSeq in pairs(logFrom) do
		local list = self.requestLogByActor and self.requestLogByActor[actor] or nil
		if not list or #list == 0 then
			self:SendRequestsSnapshot(target)
			return
		end
		local minSeq = tonumber(list[1].seq or 0) or 0
		local startSeq = tonumber(fromSeq or 0) or 0
		if startSeq <= 0 or startSeq < minSeq then
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

	if #entriesToSend == 0 then
		return
	end

	local chunk = {}
	local count = 0
	local maxPerChunk = 30
	for _, entry in ipairs(entriesToSend) do
		table.insert(chunk, entry)
		count = count + 1
		if count >= maxPerChunk then
			local payload = { type = "requests-log", logEntries = chunk }
			local data = TOGBankClassic_Core:Serialize(payload)
			TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", target, "BULK")
			chunk = {}
			count = 0
		end
	end

	if #chunk > 0 then
		local payload = { type = "requests-log", logEntries = chunk }
		local data = TOGBankClassic_Core:Serialize(payload)
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

	local clean = sanitizeRequest(request)
	if not clean then
		return false
	end

	local entry = self:BuildRequestLogEntry("add", clean)
	if not entry then
		return false
	end
	return self:RecordRequestLogEntry(entry, true)
end

-- Access control for requests.
function Guild:CanManageRequests(actor, actorIsGM)
	if CanViewOfficerNote and CanViewOfficerNote() then
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
