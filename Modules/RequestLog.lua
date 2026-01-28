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

-- Merge a single request using last-writer-wins.
-- Returns: "added", "updated", "kept", "tombstoned", or nil on error
local function mergeRequest(requests, tombstones, id, incoming)
	if not incoming or not id then
		return nil
	end

	local clean = sanitizeRequest(incoming)
	if not clean then
		return nil
	end

	local incomingTs = tonumber(clean.updatedAt or clean.date or 0) or 0
	local tombstoneTs = tonumber((tombstones or {})[id] or 0) or 0

	-- Check tombstone
	if tombstoneTs > 0 and incomingTs <= tombstoneTs then
		return "tombstoned"
	end

	local existing = requests[id]
	if existing then
		local existingTs = tonumber(existing.updatedAt or existing.date or 0) or 0
		if incomingTs > existingTs then
			requests[id] = clean
			return "updated"
		else
			return "kept"
		end
	else
		requests[id] = clean
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
	local iterFunc = incomingList[1] ~= nil and ipairs or pairs
	for _, req in iterFunc(incomingList) do
		if req and req.id then
			local result = mergeRequest(self.Info.requests, tombstones, req.id, req)
			if result then
				stats[result] = (stats[result] or 0) + 1
			end
		end
	end

	-- Update version and clean up
	self.Info.requestsVersion = calculateRequestsVersion(self.Info.requests)
	self:NormalizeRequestList()
	self:PruneRequests()
	self:PruneRequestTombstones()
	self:RefreshRequestsUI()

	TOGBankClassic_Output:Debug(string.format("ApplyRequestSnapshot: added=%d, updated=%d, kept=%d, tombstoned=%d",
		stats.added, stats.updated, stats.kept, stats.tombstoned))
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
function Guild:ApplyRequestMutation(entry)
	if not entry or type(entry) ~= "table" or not self.Info then
		return false
	end
	self:EnsureRequestsInitialized()

	local entryType = entry.type
	local entryTs = tonumber(entry.ts or 0) or 0
	local requestId = entry.requestId or (entry.request and entry.request.id)
	if not entryType or not requestId then
		return false
	end

	local tombstones = self.Info.requestsTombstones or {}

	-- Handle delete: remove request and record tombstone
	if entryType == "delete" then
		self.Info.requests[requestId] = nil
		local tombstoneTs = tonumber(tombstones[requestId] or 0) or 0
		if entryTs > tombstoneTs then
			tombstones[requestId] = entryTs
			self.Info.requestsTombstones = tombstones
		end
		return true
	end

	-- Handle fulfill: idempotent delta application
	if entryType == "fulfill" then
		local req = self.Info.requests[requestId]
		if not req or req.status == "cancelled" or req.status == "complete" then
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
				req.statusUpdatedAt = entryTs
			end
		end
		if entryTs > 0 then
			req.updatedAt = math.max(tonumber(req.updatedAt or 0) or 0, entryTs)
		end
		return true
	end

	-- Handle add/cancel/complete: merge request snapshot using LWW
	if entry.request then
		local result = mergeRequest(self.Info.requests, tombstones, requestId, entry.request)
		return result == "added" or result == "updated"
	end

	return false
end

-- Broadcast a request mutation to guild members.
-- mutation: { type, requestId, request (for add), delta/targetFulfilled (for fulfill) }
function Guild:BroadcastRequestMutation(mutation)
	if not mutation or type(mutation) ~= "table" then
		return
	end
	local now = GetServerTime()
	local actor = self:GetNormalizedPlayer() or "unknown"
	local payload = {
		type = "requests-log",  -- Keep wire format for backwards compat
		logEntries = {{
			type = mutation.type,
			actor = actor,
			ts = now,
			id = string.format("%s:%d", actor, now),
			requestId = mutation.requestId,
			request = mutation.request,
			delta = mutation.delta,
			targetFulfilled = mutation.targetFulfilled,
		}}
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", nil, "ALERT")
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

-- Receive mutation entries from another player and apply them.
function Guild:ReceiveRequestMutations(payload, sender)
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

	local applied = 0
	for _, entry in ipairs(entries) do
		if entry and type(entry) == "table" then
			if self:ApplyRequestMutation(entry) then
				applied = applied + 1
			end
		end
	end

	if applied > 0 then
		self:FinalizeMutation()
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

	-- Generate request ID in actor:seq format
	if not request.id then
		local actor = self:GetNormalizedPlayer() or "unknown"
		request.id = nextRequestId(self.Info, actor)
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
	if not self.Info or not self.Info.requests or not requestId then
		return false
	end

	local req = self.Info.requests[requestId]
	if not req then
		TOGBankClassic_Output:Debug("SYNC", "CancelRequest FAILED: Request not found")
		return false
	end

	-- Can't cancel if already in terminal state
	local quantity = tonumber(req.quantity or 0) or 0
	local fulfilled = tonumber(req.fulfilled or 0) or 0
	if req.status == "cancelled" or req.status == "complete" then
		return false
	end
	if req.status == "fulfilled" or (quantity > 0 and fulfilled >= quantity) then
		return false
	end

	if not self:CanCancelRequest(req, actor or self:GetPlayer()) then
		return false
	end

	-- Apply mutation directly
	local now = GetServerTime()
	req.status = "cancelled"
	req.statusUpdatedAt = now
	req.updatedAt = now

	-- Broadcast and finalize
	self:BroadcastRequestMutation({ type = "cancel", requestId = requestId, request = req })
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
	req.statusUpdatedAt = now
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
function Guild:FulfillRequest(bank, requester, itemName, count)
	if not self.Info or not self.Info.requests or not bank or not requester or not itemName or not count or count <= 0 then
		return 0
	end

	local normBank = self:NormalizeName(bank) or bank
	local normRequester = self:NormalizeName(requester) or requester
	local targetItem = string.lower(itemName)
	local now = GetServerTime()

	local applied = 0
	local mutations = {}

	for _, req in pairs(self.Info.requests) do
		if count <= 0 then break end

		local reqItem = req.item and string.lower(req.item) or ""
		local qty = tonumber(req.quantity or 0) or 0
		local fulfilled = tonumber(req.fulfilled or 0) or 0

		if req.bank == normBank and req.requester == normRequester and reqItem == targetItem and fulfilled < qty then
			local remaining = qty - fulfilled
			local delta = math.min(remaining, count)
			count = count - delta
			applied = applied + delta

			-- Apply mutation directly
			local targetFulfilled = fulfilled + delta
			req.fulfilled = targetFulfilled
			req.updatedAt = now
			if qty > 0 and targetFulfilled >= qty and req.status ~= "cancelled" and req.status ~= "complete" then
				req.status = "fulfilled"
				req.statusUpdatedAt = now
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
		self:FinalizeMutation(now)
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
