TOGBankClassic_Guild = {}

TOGBankClassic_Guild.Info = nil

-- Temporary in-memory error storage for when Guild.Info is not initialized
TOGBankClassic_Guild.tempDeltaErrors = {
	lastErrors = {},
	failureCounts = {},
	notifiedAlts = {},
}

-- Migrate temporary errors to database once Guild.Info is initialized
function TOGBankClassic_Guild:MigrateTempErrors()
	if not self.Info or not self.Info.name then
		return
	end
	
	local db = TOGBankClassic_Database.db.faction[self.Info.name]
	if not db or not db.deltaErrors then
		return
	end
	
	-- Migrate errors
	if #self.tempDeltaErrors.lastErrors > 0 then
		for i = #self.tempDeltaErrors.lastErrors, 1, -1 do
			table.insert(db.deltaErrors.lastErrors, 1, self.tempDeltaErrors.lastErrors[i])
		end
		-- Keep only recent errors (max 10)
		while #db.deltaErrors.lastErrors > 10 do
			table.remove(db.deltaErrors.lastErrors)
		end
	end
	
	-- Migrate failure counts
	for altName, count in pairs(self.tempDeltaErrors.failureCounts) do
		if not db.deltaErrors.failureCounts[altName] then
			db.deltaErrors.failureCounts[altName] = 0
		end
		db.deltaErrors.failureCounts[altName] = db.deltaErrors.failureCounts[altName] + count
	end
	
	-- Migrate notification flags
	for altName, flag in pairs(self.tempDeltaErrors.notifiedAlts) do
		if flag then
			db.deltaErrors.notifiedAlts[altName] = true
		end
	end
	
	-- Clear temp storage
	self.tempDeltaErrors.lastErrors = {}
	self.tempDeltaErrors.failureCounts = {}
	self.tempDeltaErrors.notifiedAlts = {}
	
	TOGBankClassic_Output:Debug("Migrated temporary delta errors to database")
end

-- Record a delta error with details (persisted to database or temp storage)
function TOGBankClassic_Guild:RecordDeltaError(altName, errorType, errorMessage)
	local error = {
		altName = altName,
		errorType = errorType,
		message = errorMessage,
		timestamp = GetServerTime(),
	}
	
	-- Try to use database storage first
	if self.Info and self.Info.name then
		local db = TOGBankClassic_Database.db.faction[self.Info.name]
		if db and db.deltaErrors then
			-- Use database storage
			table.insert(db.deltaErrors.lastErrors, 1, error)
			
			-- Keep only recent errors (max 10)
			while #db.deltaErrors.lastErrors > 10 do
				table.remove(db.deltaErrors.lastErrors)
			end
			
			-- Track failure count per alt
			if not db.deltaErrors.failureCounts[altName] then
				db.deltaErrors.failureCounts[altName] = 0
			end
			db.deltaErrors.failureCounts[altName] = db.deltaErrors.failureCounts[altName] + 1
			
			-- Notify user if repeated failures (3+ failures for same alt)
			if db.deltaErrors.failureCounts[altName] >= 3 and not db.deltaErrors.notifiedAlts[altName] then
				TOGBankClassic_Output:Warn(
					"Repeated delta sync failures for %s. Falling back to full sync.",
					altName
				)
				db.deltaErrors.notifiedAlts[altName] = true
			end
			return
		end
	end
	
	-- Fallback: Use temporary in-memory storage
	TOGBankClassic_Output:Debug(
		"Using temporary error storage for %s (%s): Guild.Info not initialized",
		altName or "unknown",
		errorType or "unknown"
	)
	
	table.insert(self.tempDeltaErrors.lastErrors, 1, error)
	
	-- Keep only recent errors (max 10)
	while #self.tempDeltaErrors.lastErrors > 10 do
		table.remove(self.tempDeltaErrors.lastErrors)
	end
	
	-- Track failure count per alt
	if not self.tempDeltaErrors.failureCounts[altName] then
		self.tempDeltaErrors.failureCounts[altName] = 0
	end
	self.tempDeltaErrors.failureCounts[altName] = self.tempDeltaErrors.failureCounts[altName] + 1
	
	-- Notify user if repeated failures (3+ failures for same alt)
	if self.tempDeltaErrors.failureCounts[altName] >= 3 and not self.tempDeltaErrors.notifiedAlts[altName] then
		TOGBankClassic_Output:Warn(
			"Repeated delta sync failures for %s. Falling back to full sync.",
			altName
		)
		self.tempDeltaErrors.notifiedAlts[altName] = true
	end
end

-- Reset failure count for an alt (called on successful sync)
function TOGBankClassic_Guild:ResetDeltaErrorCount(altName)
	-- Reset in database if available
	if self.Info and self.Info.name then
		local db = TOGBankClassic_Database.db.faction[self.Info.name]
		if db and db.deltaErrors then
			if db.deltaErrors.failureCounts[altName] then
				db.deltaErrors.failureCounts[altName] = 0
			end
			if db.deltaErrors.notifiedAlts[altName] then
				db.deltaErrors.notifiedAlts[altName] = nil
			end
		end
	end
	
	-- Also reset in temporary storage
	if self.tempDeltaErrors.failureCounts[altName] then
		self.tempDeltaErrors.failureCounts[altName] = 0
	end
	if self.tempDeltaErrors.notifiedAlts[altName] then
		self.tempDeltaErrors.notifiedAlts[altName] = nil
	end
end

-- Get recent delta errors
function TOGBankClassic_Guild:GetRecentDeltaErrors()
	-- Return from database if available
	if self.Info and self.Info.name then
		local db = TOGBankClassic_Database.db.faction[self.Info.name]
		if db and db.deltaErrors then
			return db.deltaErrors.lastErrors
		end
	end
	
	-- Fallback to temporary storage
	return self.tempDeltaErrors.lastErrors
end

-- Get failure count for an alt
function TOGBankClassic_Guild:GetDeltaFailureCount(altName)
	-- Check database first if available
	if self.Info and self.Info.name then
		local db = TOGBankClassic_Database.db.faction[self.Info.name]
		if db and db.deltaErrors then
			return db.deltaErrors.failureCounts[altName] or 0
		end
	end
	
	-- Fallback to temporary storage
	return self.tempDeltaErrors.failureCounts[altName] or 0
end

---START CHANGES
function GetPlayerWithNormalizedRealm(name)
	if string.match(name, "(.*)%-(.*)") then
		return name
	end
	return name .. "-" .. GetNormalizedRealmName("player")
end

-- wrapper to ensure consistent normalization across the addon
local function NormalizePlayerName(name)
	if not name then
		return nil
	end
	if type(name) ~= "string" then
		name = tostring(name)
	end
	local trimmed = string.gsub(name, "^%s+", "")
	trimmed = string.gsub(trimmed, "%s+$", "")
	if trimmed == "" then
		return nil
	end
	-- Canonicalize hyphen spacing: convert "Name - Realm" or "Name- Realm" to "Name-Realm"
	local normalized = string.gsub(trimmed, "%s*%-%s*", "-")
	local left, right = string.match(normalized, "^(.-)%-(.-)$")
	if left and right then
		if left == "" then
			return nil
		end
		if string.lower(left) == "unknown" then
			return "Unknown"
		end
		if right ~= "" then
			return normalized
		end
		normalized = left
	end
	if string.lower(normalized) == "unknown" then
		return "Unknown"
	end
	-- If helper exists, use it
	if GetPlayerWithNormalizedRealm then
		return GetPlayerWithNormalizedRealm(normalized)
	end
	-- Fallback: append current realm
	return normalized .. "-" .. GetNormalizedRealmName("player")
end
-- expose for other modules
TOGBankClassic_Guild.NormalizePlayerName = NormalizePlayerName

function TOGBankClassic_Guild:NormalizeName(name)
	if not name then
		return nil
	end
	local normalize = self.NormalizePlayerName
	if normalize then
		return normalize(name)
	end
	return name
end

function TOGBankClassic_Guild:GetNormalizedPlayer(name)
	return self:NormalizeName(name or self:GetPlayer())
end

---END CHANGES
function TOGBankClassic_Guild:GetPlayer()
	---START CHANGES
	--return UnitName("player")
	if TOGBankClassic_Bank.player then
		return TOGBankClassic_Bank.player
	end

	-- The below code should never be called, but is here for safety
	local function try()
		local name, realm = UnitName("player"), GetNormalizedRealmName()
		if name and realm then
			TOGBankClassic_Bank.player = name .. "-" .. realm
			return true
		end
	end
	if try() then
		return TOGBankClassic_Bank.player
	end
	local count, max, delay, timer = 0, 10, 15
	timer = C_Timer.NewTicker(delay, function()
		count = count + 1
		if try() or count >= max then
			if timer then
				timer:Cancel()
			end
		end
	end)

	return nil
	---END CHANGES
end

function TOGBankClassic_Guild:GetGuild()
	return IsInGuild("player") and GetGuildInfo("player") or nil
end

function TOGBankClassic_Guild:GetPlayerInfo(name)
	for i = 1, GetNumGuildMembers() do
		local playerRealm, _, _, _, _, _, _, _, _, _, class = GetGuildRosterInfo(i)
		player, _ = string.match(playerRealm, "(.*)%-(.*)")
		---START CHANGES
		--if player == name then
		if playerRealm == name then
			---END CHANGES
			return class
		end
	end
	return nil
end

function TOGBankClassic_Guild:Reset(name)
	if not name then
		return
	end

	TOGBankClassic_UI_Inventory:Close()
	TOGBankClassic_Database:Reset(name)
	self.Info = TOGBankClassic_Database:Load(name)
	self:EnsureRequestsInitialized()
	
	-- Migrate any temporary errors to database
	self:MigrateTempErrors()
end

function TOGBankClassic_Guild:Init(name)
	if not name then
		return false
	end
	if self.Info and self.Info.name == name then
		return false
	end

	self.hasRequested = false
	self.requestCount = 0

	self.Info = TOGBankClassic_Database:Load(name)
	if self.Info then
		self:EnsureRequestsInitialized()
		-- Migrate any temporary errors to database
		self:MigrateTempErrors()
		return true
	end

	self:Reset(name)
	return true
end

-- Cleanup malformed entries in the saved guild data
-- This attempts to be conservative:
-- - remove alts that are not tables
-- - remove per-alt entries that have badly shaped bank/bags item lists
-- - ensure roster.alts is a proper array
-- Returns number of alts cleaned
function TOGBankClassic_Guild:CleanupMalformedAlts()
	if not self.Info or not self.Info.alts then
		return 0
	end

	local cleaned = 0
	for name, alt in pairs(self.Info.alts) do
		local remove = false
		if type(alt) ~= "table" then
			remove = true
		else
			-- Ensure version is present, but malformed nested fields are problematic
			if alt.bank and type(alt.bank) == "table" and alt.bank.items then
				-- alt.bank.items should be an array or a map of items with ID fields; remove any empty entries
				for k, v in pairs(alt.bank.items) do
					if not v or type(v) ~= "table" or not v.ID then
						alt.bank.items[k] = nil
					end
				end
			end
			if alt.bags and type(alt.bags) == "table" and alt.bags.items then
				for k, v in pairs(alt.bags.items) do
					if not v or type(v) ~= "table" or not v.ID then
						alt.bags.items[k] = nil
					end
				end
			end
			-- If after cleaning the alt has no meaningful fields (no version, no money, no items), remove it
			local hasData = false
			if alt.version then
				hasData = true
			end
			if alt.money then
				hasData = true
			end
			if alt.bank and next(alt.bank.items or {}) then
				hasData = true
			end
			if alt.bags and next(alt.bags.items or {}) then
				hasData = true
			end
			if not hasData then
				remove = true
			end
		end

		if remove then
			TOGBankClassic_Output:Debug("Removing malformed bank entry for", name)
			self.Info.alts[name] = nil
			cleaned = cleaned + 1
		end
	end

	-- Ensure roster.alts is a proper array (remove nils and non-strings)
	if self.Info.roster and self.Info.roster.alts then
		local new_alts = {}
		for _, v in pairs(self.Info.roster.alts) do
			if type(v) == "string" and v ~= "" then
				table.insert(new_alts, v)
			end
		end
		self.Info.roster.alts = new_alts
	end

	return cleaned
end

function TOGBankClassic_Guild:GetBanks()
	local banks = {}

	for i = 1, GetNumGuildMembers() do
		---START CHANGES
		-- Allow use of either public or officer note, and allow the note to contain "gbank" instead of requiring it to be equal to "gbank" only (and no other characters)
		--local name, _, _, _, _, _, _, officer_note, _, _, _ = GetGuildRosterInfo(i)
		local name, _, _, _, _, _, publicNote, officer_note, _, _, _ = GetGuildRosterInfo(i)
		--if officer_note == "gbank" then
		if publicNote ~= nil or officer_note ~= nil then
			if string.match(publicNote, "(.*)gbank(.*)") or string.match(officer_note, "(.*)gbank(.*)") then
				--local player, _ = string.match(name, "(.*)%-(.*)")
				table.insert(banks, name)
				---END CHANGES
			end
		end
	end
	if #banks == 0 then
		return nil
	end
	return banks
end

function TOGBankClassic_Guild:GetRosterAlts()
	if not self.Info then
		return nil
	end

	local roster = self.Info.roster
	local list = {}

	if roster and roster.alts then
		for _, v in pairs(roster.alts) do
			if type(v) == "string" and v ~= "" then
				table.insert(list, v)
			end
		end
	end

	if #list > 0 then
		return list
	end

	for name, alt in pairs(self.Info.alts or {}) do
		if type(alt) == "table" then
			table.insert(list, name)
		end
	end

	if #list == 0 then
		return nil
	end

	return list
end

function TOGBankClassic_Guild:IsBank(player)
	if not player then
		return false
	end
	local banks = TOGBankClassic_Guild:GetBanks()
	if banks == nil then
		return false
	end

	local normPlayer = self:NormalizeName(player) or player
	local isBank = false
	for _, v in pairs(banks) do
		local norm = self:NormalizeName(v) or v
		if norm == normPlayer then
			isBank = true
		end
	end

	return isBank
end

function TOGBankClassic_Guild:CheckVersion(version)
	if self.Info then
		return false
	end

	if version > self.Info.roster.version then
		return false
	end

	return true
end

function TOGBankClassic_Guild:GetVersion()
	if not self.Info then
		return nil
	end

	local versionInfo = GetAddOnMetadata("TOGBankClassic", "Version"):gsub("%.", "")
	local versionNumber = tonumber(versionInfo)
	local data = {
		addon = versionNumber,
		protocol_version = PROTOCOL.VERSION,
		supports_delta = PROTOCOL.SUPPORTS_DELTA,
		roster = nil,
		alts = {},
		requests = self:GetRequestsVersion(),
		requestLog = self:GetRequestLogSummary(),
	}

	if self.Info.name then
		data.name = self.Info.name
	end

	if self.Info.roster.version then
		data.roster = self.Info.roster.version
	end

	for k, v in pairs(self.Info.alts) do
		---START CHANGES
		-- Only store bank alt data if the sender is a bank alt
		--data.alts[k] = v.version
		if type(v) == "table" and v.version then
			data.alts[k] = v.version
		end
		---END CHANGES
	end

	return data
end

local PENDING_SYNC_TTL_SECONDS = 180

function TOGBankClassic_Guild:MarkPendingSync(syncType, sender, name)
	if not syncType or not sender then
		return
	end
	local now = GetServerTime()
	local normSender = self:NormalizeName(sender)
	if not self.pending_sync then
		self.pending_sync = { roster = {}, alts = {} }
	end
	if syncType == "roster" then
		self.pending_sync.roster[normSender] = now
	elseif syncType == "alt" and name then
		local normName = self:NormalizeName(name)
		if not self.pending_sync.alts[normName] then
			self.pending_sync.alts[normName] = {}
		end
		self.pending_sync.alts[normName][normSender] = now
	end
end

function TOGBankClassic_Guild:ConsumePendingSync(syncType, sender, name)
	if not syncType or not sender then
		return false
	end
	if not self.pending_sync then
		return false
	end
	local now = GetServerTime()
	local normSender = self:NormalizeName(sender)
	if syncType == "roster" then
		local roster = self.pending_sync.roster
		local ts = roster and roster[normSender]
		if ts and now - ts <= PENDING_SYNC_TTL_SECONDS then
			roster[normSender] = nil
			return true
		end
		if ts then
			roster[normSender] = nil
		end
		return false
	end
	if syncType == "alt" and name then
		local normName = self:NormalizeName(name)
		local alts = self.pending_sync.alts and self.pending_sync.alts[normName]
		local ts = alts and alts[normSender]
		if ts and now - ts <= PENDING_SYNC_TTL_SECONDS then
			alts[normSender] = nil
			if next(alts) == nil then
				self.pending_sync.alts[normName] = nil
			end
			return true
		end
		if ts then
			alts[normSender] = nil
			if next(alts) == nil then
				self.pending_sync.alts[normName] = nil
			end
		end
	end
	return false
end

function TOGBankClassic_Guild:QueryRoster(player, version)
	self.hasRequested = true
	if self.requestCount == nil then
		self.requestCount = 1
	else
		self.requestCount = self.requestCount + 1
	end
	self:MarkPendingSync("roster", player)
	local data = TOGBankClassic_Core:SerializeWithChecksum({ player = player, type = "roster", version = version })
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, "BULK")
end

function TOGBankClassic_Guild:QueryAlt(player, name, version)
	self.hasRequested = true
	if self.requestCount == nil then
		self.requestCount = 1
	else
		self.requestCount = self.requestCount + 1
	end
	self:MarkPendingSync("alt", player, name)
	local data = TOGBankClassic_Core:SerializeWithChecksum({ player = player, type = "alt", name = name, version = version })
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, "BULK")
end

function TOGBankClassic_Guild:SendRosterData()
	local data = TOGBankClassic_Core:SerializeWithChecksum({ type = "roster", roster = self.Info.roster })
	TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", nil, "BULK")
end

function TOGBankClassic_Guild:ReceiveRosterData(roster)
	if not self.Info then
		return
	end
	if self.Info.roster.version and roster.version and roster.version < self.Info.roster.version then
		return
	end
	if self.hasRequested then
		if self.requestCount == nil then
			self.requestCount = 0
		else
			self.requestCount = self.requestCount - 1
		end
		if self.requestCount == 0 then
			self.hasRequested = false
			TOGBankClassic_Output:Info("Sync completed.")
		end
	end

	self.Info.roster = roster
end

-- returns true if the given normalized sender has a public or officer note containing 'gbank'
function TOGBankClassic_Guild:SenderHasGbankNote(sender)
	if not sender then
		return false
	end
	for i = 1, GetNumGuildMembers() do
		local playerRealm, _, _, _, _, _, publicNote, officer_note = GetGuildRosterInfo(i)
		if playerRealm then
			local norm = self:NormalizeName(playerRealm)
			if norm == sender then
				if
					(publicNote and string.match(publicNote, "(.*)gbank(.*)"))
					or (officer_note and string.match(officer_note, "(.*)gbank(.*)"))
				then
					return true
				end
			end
		end
	end
	return false
end

function TOGBankClassic_Guild:SendAltData(name, force)
	if not name then
		return
	end
	local norm = self:NormalizeName(name)
	if not self.Info or not self.Info.alts or not self.Info.alts[norm] then
		return
	end

	-- Bump the version so this transfer wins conflict resolution
	if force then
		self.Info.alts[norm].version = GetServerTime()
	end

	local currentAlt = self.Info.alts[norm]
	local useDelta = false
	local deltaData = nil
	local computeStart = debugprofilestop()

	-- Check if delta sync should be used
	if self:ShouldUseDelta() and not force then
		deltaData = self:ComputeDelta(norm, currentAlt)
		if deltaData and self:DeltaHasChanges(deltaData) then
			local deltaSize = self:EstimateSize(deltaData)
			local fullSize = self:EstimateSize({ type = "alt", name = norm, alt = currentAlt })
			
			-- Use delta if significantly smaller
			if deltaSize < fullSize * PROTOCOL.MIN_DELTA_SIZE_RATIO then
				useDelta = true
				TOGBankClassic_Output:Debug(
					"✓ Delta selected for %s: %d bytes vs %d bytes full (%.1f%% size, %.0f bytes saved)",
					norm,
					deltaSize,
					fullSize,
					(deltaSize / fullSize) * 100,
					fullSize - deltaSize
				)
			else
				TOGBankClassic_Output:Debug(
					"✗ Delta too large for %s: %d bytes vs %d bytes full (%.1f%% > %.0f%% threshold)",
					norm,
					deltaSize,
					fullSize,
					(deltaSize / fullSize) * 100,
					PROTOCOL.MIN_DELTA_SIZE_RATIO * 100
				)
			end
		else
			if deltaData then
				TOGBankClassic_Output:Debug("No changes detected for %s (delta would be empty)", norm)
			else
				TOGBankClassic_Output:Debug("No previous snapshot for %s (first sync)", norm)
			end
		end
	end
	
	-- Record compute time if delta was computed
	if deltaData and self.Info and self.Info.name then
		local computeTime = debugprofilestop() - computeStart
		TOGBankClassic_Database:RecordDeltaComputeTime(self.Info.name, computeTime)
		TOGBankClassic_Output:Debug("Delta computation took %.2fms", computeTime)
	end

	if useDelta then
		-- Send delta via togbank-d2
		local serialized = TOGBankClassic_Core:SerializeWithChecksum(deltaData)
		TOGBankClassic_Core:SendCommMessage("togbank-d2", serialized, "Guild", nil, "BULK", OnChunkSent)
		
		TOGBankClassic_Output:Debug("Sent delta update for %s via togbank-d2", norm)
		
		-- Track metrics
		if self.Info and self.Info.name then
			TOGBankClassic_Database:RecordDeltaSent(self.Info.name, string.len(serialized or ""))
		end
		
		-- Save delta to history for potential chain replay (DELTA-006)
		if self.Info and self.Info.name and deltaData.baseVersion and deltaData.version and deltaData.changes then
			TOGBankClassic_Database:SaveDeltaHistory(
				self.Info.name,
				norm,
				deltaData.baseVersion,
				deltaData.version,
				deltaData.changes
			)
		end
		
		-- Save snapshot for next delta
		if self.Info and self.Info.name then
			TOGBankClassic_Database:SaveSnapshot(self.Info.name, norm, currentAlt)
		end
	else
		-- Fallback to full sync via togbank-d
		if deltaData and self:DeltaHasChanges(deltaData) then
			if self.Info and self.Info.name then
				TOGBankClassic_Database:RecordFullSyncFallback(self.Info.name)
			end
		end
		
		local data = TOGBankClassic_Core:SerializeWithChecksum({ type = "alt", name = norm, alt = currentAlt })
		TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", nil, "BULK", OnChunkSent)
		
		TOGBankClassic_Output:Debug("Sent full sync for %s via togbank-d (%d bytes)", norm, string.len(data or ""))
		
		-- Track metrics
		if self.Info and self.Info.name then
			TOGBankClassic_Database:RecordFullSyncSent(self.Info.name, string.len(data or ""))
		end
		
		-- Save snapshot for next delta
		if self.Info and self.Info.name then
			TOGBankClassic_Database:SaveSnapshot(self.Info.name, norm, currentAlt)
		end
	end
end

---START CHANGES
-- Tracking stats for current send operation
local SendStats = {
	startTime = nil,
	lastBytes = 0,
	chunksSent = 0,
	failures = 0,
	throttled = 0,
}

-- SendAddonMessageResult enum values from ChatThrottleLib
local SEND_RESULT = {
	Success = 0,
	AddonMessageThrottle = 3,
	NotInGroup = 5,
	ChannelThrottle = 8,
	GeneralError = 9,
}

local function GetSendResultName(result)
	if result == SEND_RESULT.Success or result == true then return "Success"
	elseif result == SEND_RESULT.AddonMessageThrottle then return "AddonMessageThrottle"
	elseif result == SEND_RESULT.NotInGroup then return "NotInGroup"
	elseif result == SEND_RESULT.ChannelThrottle then return "ChannelThrottle"
	elseif result == SEND_RESULT.GeneralError then return "GeneralError"
	elseif result == false then return "Failed"
	else return tostring(result)
	end
end

function OnChunkSent(arg, bytesSent, totalBytes, sendResult)
	-- Track chunk count (each callback = one chunk sent, ~254 bytes each)
	local bytesThisChunk = bytesSent - SendStats.lastBytes
	if bytesThisChunk > 0 then
		SendStats.chunksSent = SendStats.chunksSent + 1
	end
	SendStats.lastBytes = bytesSent

	-- Track failures
	local isSuccess = (sendResult == SEND_RESULT.Success or sendResult == true or sendResult == nil)
	local isThrottled = (sendResult == SEND_RESULT.AddonMessageThrottle or sendResult == SEND_RESULT.ChannelThrottle)
	if isThrottled then
		SendStats.throttled = SendStats.throttled + 1
	elseif not isSuccess then
		SendStats.failures = SendStats.failures + 1
	end

	-- Initialize start time on first chunk
	if SendStats.startTime == nil then
		SendStats.startTime = GetTime()
	end

	local totalChunks = math.ceil(totalBytes / 254)

	-- Print error on failed send
	if not isSuccess then
		local resultStr = GetSendResultName(sendResult)
		TOGBankClassic_Output:Error("chunk %d/%d failed: %s", SendStats.chunksSent, totalChunks, resultStr)
	end

	-- Show progress at start
	if SendStats.chunksSent == 1 then
		TOGBankClassic_Output:Info("Sharing guild bank data: %d bytes in ~%d chunks...", totalBytes, totalChunks)
	end

	-- Completion summary
	if bytesSent >= totalBytes then
		local elapsed = GetTime() - (SendStats.startTime or GetTime())
		local summary = string.format(
			"Send complete: %d chunks, %d bytes in %.1fs",
			SendStats.chunksSent, totalBytes, elapsed
		)
		if SendStats.failures > 0 or SendStats.throttled > 0 then
			summary = summary .. string.format(" | failures: %d, throttled: %d", SendStats.failures, SendStats.throttled)
		end

		TOGBankClassic_Output:Debug(summary)

		-- Warn on failures
		if SendStats.failures > 0 then
			TOGBankClassic_Output:Warn("%d send failures occurred!", SendStats.failures)
		end

		-- Reset stats for next operation
		SendStats.startTime = nil
		SendStats.lastBytes = 0
		SendStats.chunksSent = 0
		SendStats.failures = 0
		SendStats.throttled = 0
	end
end
---END CHANGES

function TOGBankClassic_Guild:ReceiveAltData(name, alt)
	if not self.Info then
		return ADOPTION_STATUS.IGNORED
	end

	-- Sanitize incoming alt data
	local function sanitizeAlt(a)
		if not a or type(a) ~= "table" then
			return nil
		end
		if a.bank and type(a.bank) == "table" and a.bank.items then
			for k, v in pairs(a.bank.items) do
				if not v or type(v) ~= "table" or not v.ID then
					a.bank.items[k] = nil
				end
			end
		end
		if a.bags and type(a.bags) == "table" and a.bags.items then
			for k, v in pairs(a.bags.items) do
				if not v or type(v) ~= "table" or not v.ID then
					a.bags.items[k] = nil
				end
			end
		end
		return a
	end

	alt = sanitizeAlt(alt)
	if not alt then
		return ADOPTION_STATUS.INVALID
	end

	local norm = self:NormalizeName(name)
	local existing = self.Info.alts[norm]
	if existing and alt.version ~= nil and existing.version ~= nil and alt.version < existing.version then
		return ADOPTION_STATUS.STALE
	end

	-- Accept incoming if newer version
	-- If same version, accept the alt with more items
	local function itemCount(a)
		local c = 0
		if a and a.bank and a.bank.items then
			for _, v in pairs(a.bank.items) do
				if v and v.ID then
					c = c + 1
				end
			end
		end
		if a and a.bags and a.bags.items then
			for _, v in pairs(a.bags.items) do
				if v and v.ID then
					c = c + 1
				end
			end
		end
		return c
	end

	if existing and existing.version and alt.version and alt.version < existing.version then
		-- Incoming is older; ignore
		return ADOPTION_STATUS.STALE
	elseif existing and existing.version and alt.version and alt.version == existing.version then
		-- Tie-breaker: choose the one with more items
		if itemCount(alt) <= itemCount(existing) then
			return ADOPTION_STATUS.STALE
		end
	end

	if self.Info.alts[name] and alt.version ~= nil and alt.version < self.Info.alts[name].version then
		return ADOPTION_STATUS.STALE
	end
	if self.hasRequested then
		if self.requestCount == nil then
			self.requestCount = 0
		else
			self.requestCount = self.requestCount - 1
		end
		if self.requestCount == 0 then
			self.hasRequested = false
			TOGBankClassic_Output:Info("Sync completed.")
		end
	end

	self.Info.alts[norm] = alt
	
	-- Reset error count on successful full sync
	self:ResetDeltaErrorCount(norm)
	
	return ADOPTION_STATUS.ADOPTED
end

---START CHANGES
function s(a)
	local b = 0
	for c, d in pairs(a) do
		b = b + 1
	end
	return b
end

-- Protocol version helper functions

-- Check if delta sync should be used based on guild support
function TOGBankClassic_Guild:ShouldUseDelta()
	-- Check feature flags first
	if not FEATURES or not FEATURES.DELTA_ENABLED then
		return false
	end
	if FEATURES.FORCE_FULL_SYNC then
		return false
	end

	-- Check guild support level
	if not self.Info or not self.Info.name then
		return false
	end

	local supportRatio = TOGBankClassic_Database:GetGuildDeltaSupport(self.Info.name)
	return supportRatio >= PROTOCOL.DELTA_SUPPORT_THRESHOLD
end

-- Get peer protocol capabilities
function TOGBankClassic_Guild:GetPeerCapabilities(sender)
	if not self.Info or not self.Info.name or not sender then
		return nil
	end

	return TOGBankClassic_Database:GetPeerProtocol(self.Info.name, sender)
end

-- Delta Computation Functions

-- Compare two items for equality
function TOGBankClassic_Guild:ItemsEqual(item1, item2)
	if not item1 and not item2 then
		return true
	end
	if not item1 or not item2 then
		return false
	end

	-- Compare key fields
	if item1.ID ~= item2.ID then
		return false
	end
	if item1.Count ~= item2.Count then
		return false
	end
	if item1.Link ~= item2.Link then
		return false
	end

	-- Compare Info table if present (deep comparison)
	if item1.Info or item2.Info then
		if not item1.Info or not item2.Info then
			return false
		end
		for k, v in pairs(item1.Info) do
			if item2.Info[k] ~= v then
				return false
			end
		end
		for k, v in pairs(item2.Info) do
			if item1.Info[k] ~= v then
				return false
			end
		end
	end

	return true
end

-- Extract only the fields that changed between two items
function TOGBankClassic_Guild:GetChangedFields(oldItem, newItem)
	-- Always include ID and Link for identification (merged items use these as keys)
	local changes = {
		ID = newItem.ID,
		Link = newItem.Link
	}

	-- Include changed fields
	if oldItem.Count ~= newItem.Count then
		changes.Count = newItem.Count
	end
	if oldItem.Info or newItem.Info then
		if not oldItem.Info or not newItem.Info or not self:ItemsEqual(oldItem, newItem) then
			changes.Info = newItem.Info
		end
	end

	return changes
end

-- Build a slot-indexed lookup table from items array
function TOGBankClassic_Guild:BuildItemIndex(items)
	local index = {}
	if not items then
		return index
	end

	for _, item in pairs(items) do
		if item and item.ID and item.Link then
			local key = tostring(item.ID) .. item.Link
			index[key] = item
		end
	end

	return index
end

-- Compute delta between old and new item sets
function TOGBankClassic_Guild:ComputeItemDelta(oldItems, newItems)
	local delta = { added = {}, modified = {}, removed = {} }

	oldItems = oldItems or {}
	newItems = newItems or {}

	-- Build item index for old items by itemID+Link key
	local oldByKey = self:BuildItemIndex(oldItems)

	-- Find added and modified items
	for _, newItem in pairs(newItems) do
		if newItem and newItem.ID and newItem.Link then
			local key = tostring(newItem.ID) .. newItem.Link
			local oldItem = oldByKey[key]

			if not oldItem then
				-- Item was added
				table.insert(delta.added, newItem)
			elseif not self:ItemsEqual(oldItem, newItem) then
				-- Item was modified (quantity or other field changed)
				table.insert(delta.modified, self:GetChangedFields(oldItem, newItem))
			end

			-- Mark as processed
			oldByKey[key] = nil
		end
	end

	-- Remaining old items were removed
	for _, item in pairs(oldByKey) do
		table.insert(delta.removed, { ID = item.ID, Link = item.Link })
	end

	return delta
end

-- Compute full delta for an alt
function TOGBankClassic_Guild:ComputeDelta(name, currentAlt)
	if not name or not currentAlt then
		return nil
	end

	-- Get previous snapshot
	local previous = TOGBankClassic_Database:GetSnapshot(self.Info.name, name)
	if not previous then
		return nil
	end

	-- Build delta structure
	local delta = {
		type = "alt-delta",
		name = name,
		version = currentAlt.version or GetServerTime(),
		baseVersion = previous.version or 0,
		changes = {},
	}

	-- Money change
	if currentAlt.money ~= previous.money then
		delta.changes.money = currentAlt.money
	end

	-- Bank items delta
	local previousBankItems = previous.bank and previous.bank.items or {}
	local currentBankItems = currentAlt.bank and currentAlt.bank.items or {}
	
	-- Bag items delta
	local previousBagItems = previous.bags and previous.bags.items or {}
	local currentBagItems = currentAlt.bags and currentAlt.bags.items or {}
	
	-- Debug: Log item counts for both bank and bags
	TOGBankClassic_Output:Debug(
		"Comparing %s: previous bank has %d items, bags have %d items; current bank has %d items, bags have %d items",
		name,
		#previousBankItems,
		#previousBagItems,
		#currentBankItems,
		#currentBagItems
	)
	delta.changes.bank = self:ComputeItemDelta(previousBankItems, currentBankItems)
	delta.changes.bags = self:ComputeItemDelta(previousBagItems, currentBagItems)

	return delta
end

-- Estimate serialized size of a data structure
function TOGBankClassic_Guild:EstimateSize(data)
	if not data then
		return 0
	end

	-- Rough estimate: serialize and measure length
	local serialized = TOGBankClassic_Core:SerializeWithChecksum(data)
	return string.len(serialized or "")
end

-- Check if delta has any actual changes
function TOGBankClassic_Guild:DeltaHasChanges(delta)
	if not delta or not delta.changes then
		return false
	end

	local changes = delta.changes

	-- Check money change
	if changes.money then
		return true
	end

	-- Check bank changes
	if changes.bank then
		if next(changes.bank.added) or next(changes.bank.modified) or next(changes.bank.removed) then
			return true
		end
	end

	-- Check bag changes
	if changes.bags then
		if next(changes.bags.added) or next(changes.bags.modified) or next(changes.bags.removed) then
			return true
		end
	end

	return false
end

-- Apply item delta to an items table
function TOGBankClassic_Guild:ApplyItemDelta(items, delta)
	if not items or not delta then
		return false
	end

	-- Build current items index by itemKey
	local itemsByKey = self:BuildItemIndex(items)

	-- Remove items
	if delta.removed then
		for _, removedItem in ipairs(delta.removed) do
			if removedItem and removedItem.ID and removedItem.Link then
				local key = tostring(removedItem.ID) .. removedItem.Link
				-- Find and remove item with matching key
				for i = #items, 1, -1 do  -- Iterate backwards to safely remove
					local item = items[i]
					if item and item.ID and item.Link then
						local itemKey = tostring(item.ID) .. item.Link
						if itemKey == key then
							table.remove(items, i)
							break
						end
					end
				end
			end
		end
	end

	-- Add new items
	if delta.added then
		for _, item in ipairs(delta.added) do
			if item and item.ID and item.Link then
				table.insert(items, item)
			end
		end
	end

	-- Modify existing items
	if delta.modified then
		for _, changes in ipairs(delta.modified) do
			if changes and changes.ID and changes.Link then
				local key = tostring(changes.ID) .. changes.Link
				local existingItem = itemsByKey[key]
				
				if existingItem then
					-- Apply changed fields to existing item
					for field, value in pairs(changes) do
						existingItem[field] = value
					end
				else
					-- Item doesn't exist (shouldn't happen), add as new
					table.insert(items, changes)
				end
			end
		end
	end

	return true
end

-- Apply a delta to alt data
function TOGBankClassic_Guild:ApplyDelta(name, deltaData, sender)
	if not self.Info then
		return ADOPTION_STATUS.IGNORED
	end
	
	local applyStart = debugprofilestop()
	local norm = self:NormalizeName(name)
	local current = self.Info.alts[norm]

	-- Validate base version matches
	if not current then
		-- No existing data, request full sync
		local errorMsg = string.format("No existing data for %s", norm)
		TOGBankClassic_Output:Debug(errorMsg .. ", requesting full sync")
		self:RecordDeltaError(norm, "NO_DATA", errorMsg)
		TOGBankClassic_Guild:QueryAlt(nil, norm, nil)
		if self.Info and self.Info.name then
			TOGBankClassic_Database:RecordDeltaFailed(self.Info.name)
		end
		return ADOPTION_STATUS.INVALID
	end

	local currentVersion = current.version or 0
	local baseVersion = deltaData.baseVersion or 0

	if currentVersion ~= baseVersion then
		-- Version mismatch - try delta chain replay (DELTA-006)
		local errorMsg = string.format(
			"Version mismatch: have %d, delta expects %d",
			currentVersion,
			baseVersion
		)
		
		-- Try delta chain if sender is known and we're behind
		if sender and currentVersion < baseVersion then
			TOGBankClassic_Output:Debug(
				"Version mismatch for %s (have %d, delta expects %d), requesting delta chain",
				norm,
				currentVersion,
				baseVersion
			)
			
			-- Request delta chain to catch up
			self:RequestDeltaChain(norm, currentVersion, baseVersion, sender)
		else
			-- Can't use delta chain, request full sync
			TOGBankClassic_Output:Debug(
				"Version mismatch for %s (have %d, delta expects %d), requesting full sync",
				norm,
				currentVersion,
				baseVersion
			)
			TOGBankClassic_Guild:QueryAlt(nil, norm, nil)
		end
		
		self:RecordDeltaError(norm, "VERSION_MISMATCH", errorMsg)
		if self.Info and self.Info.name then
			TOGBankClassic_Database:RecordDeltaFailed(self.Info.name)
		end
		return ADOPTION_STATUS.INVALID
	end

	-- Apply changes (wrapped in pcall for safety)
	local success, err = pcall(function()
		local changes = deltaData.changes

		if changes.money then
			current.money = changes.money
		end

		-- Apply bank item changes
		if changes.bank then
			if not current.bank then
				current.bank = { items = {} }
			end
			if not current.bank.items then
				current.bank.items = {}
			end
			self:ApplyItemDelta(current.bank.items, changes.bank)
		end

		-- Apply bag item changes
		if changes.bags then
			if not current.bags then
				current.bags = { items = {} }
			end
			if not current.bags.items then
				current.bags.items = {}
			end
			self:ApplyItemDelta(current.bags.items, changes.bags)
		end

		-- Update version
		current.version = deltaData.version
	end)

	if not success then
		-- Delta application failed, request full sync
		local errorMsg = string.format("Delta application error: %s", tostring(err))
		TOGBankClassic_Output:Error("Failed to apply delta for %s: %s", norm, tostring(err))
		self:RecordDeltaError(norm, "APPLICATION_ERROR", errorMsg)
		TOGBankClassic_Guild:QueryAlt(nil, norm, nil)
		if self.Info and self.Info.name then
			TOGBankClassic_Database:RecordDeltaFailed(self.Info.name)
		end
		return ADOPTION_STATUS.INVALID
	end

	-- Save new snapshot for future deltas
	if self.Info and self.Info.name then
		TOGBankClassic_Database:SaveSnapshot(self.Info.name, norm, current)
		TOGBankClassic_Database:RecordDeltaApplied(self.Info.name)
		
		-- Record apply time
		local applyTime = debugprofilestop() - applyStart
		TOGBankClassic_Database:RecordDeltaApplyTime(self.Info.name, applyTime)
		TOGBankClassic_Output:Debug(
			"✓ Applied delta for %s (v%d→v%d) in %.2fms",
			norm,
			baseVersion,
			deltaData.version,
			applyTime
		)
	end

	-- Reset error count on successful application
	self:ResetDeltaErrorCount(norm)

	-- Trigger UI refresh
	TOGBankClassic_Events:TriggerCallback(TOGBankClassic_Events.DB_UPDATE)

	return ADOPTION_STATUS.ADOPTED
end

-- Request a chain of deltas to catch up from an old version (DELTA-006)
function TOGBankClassic_Guild:RequestDeltaChain(altName, fromVersion, toVersion, sender)
	if not altName or not fromVersion or not toVersion or not sender then
		return false
	end

	-- Validate request parameters
	if fromVersion >= toVersion then
		TOGBankClassic_Output:Debug("Invalid delta chain request: fromVersion >= toVersion")
		return false
	end

	-- Calculate expected hop count
	local versionGap = toVersion - fromVersion
	if versionGap > (PROTOCOL.DELTA_CHAIN_MAX_HOPS or 10) * 60 then
		-- Gap too large (assuming ~60 seconds between updates), use full sync
		TOGBankClassic_Output:Debug(
			"Delta chain gap too large for %s (%d seconds), requesting full sync",
			altName,
			versionGap
		)
		TOGBankClassic_Guild:QueryAlt(nil, altName, sender)
		return false
	end

	-- Send delta range request
	local requestData = {
		altName = altName,
		fromVersion = fromVersion,
		toVersion = toVersion
	}
	
	local serialized = TOGBankClassic_Core:SerializeWithChecksum(requestData)
	TOGBankClassic_Core:SendCommMessage("togbank-dr", serialized, "WHISPER", sender, "ALERT")
	
	TOGBankClassic_Output:Debug(
		"Requesting delta chain for %s from v%d to v%d from %s",
		altName,
		fromVersion,
		toVersion,
		sender
	)
	
	return true
end

-- Apply a chain of deltas sequentially (DELTA-006)
function TOGBankClassic_Guild:ApplyDeltaChain(altName, deltaChain)
	if not altName or not deltaChain or type(deltaChain) ~= "table" or #deltaChain == 0 then
		return ADOPTION_STATUS.INVALID
	end

	local norm = self:NormalizeName(altName)
	local current = self.Info and self.Info.alts and self.Info.alts[norm]

	if not current then
		TOGBankClassic_Output:Debug("No existing data for %s, cannot apply delta chain", norm)
		return ADOPTION_STATUS.INVALID
	end

	-- Validate chain
	if #deltaChain > (PROTOCOL.DELTA_CHAIN_MAX_HOPS or 10) then
		TOGBankClassic_Output:Debug(
			"Delta chain too long for %s (%d hops > %d max)",
			norm,
			#deltaChain,
			PROTOCOL.DELTA_CHAIN_MAX_HOPS or 10
		)
		return ADOPTION_STATUS.INVALID
	end

	-- Estimate total chain size
	local totalSize = self:EstimateSize(deltaChain)
	if totalSize > (PROTOCOL.DELTA_CHAIN_MAX_SIZE or 5000) then
		TOGBankClassic_Output:Debug(
			"Delta chain too large for %s (%d bytes > %d max), requesting full sync",
			norm,
			totalSize,
			PROTOCOL.DELTA_CHAIN_MAX_SIZE or 5000
		)
		TOGBankClassic_Guild:QueryAlt(nil, norm, nil)
		return ADOPTION_STATUS.INVALID
	end

	-- Apply each delta in sequence
	local chainStart = debugprofilestop()
	local currentVersion = current.version or 0

	for i, deltaEntry in ipairs(deltaChain) do
		-- Validate this delta applies to our current version
		if deltaEntry.baseVersion ~= currentVersion then
			TOGBankClassic_Output:Debug(
				"Delta chain broken for %s at hop %d: have v%d, delta expects v%d",
				norm,
				i,
				currentVersion,
				deltaEntry.baseVersion
			)
			TOGBankClassic_Guild:QueryAlt(nil, norm, nil)
			return ADOPTION_STATUS.INVALID
		end

		-- Apply this delta
		local deltaData = {
			type = "alt-delta",
			name = altName,
			version = deltaEntry.version,
			baseVersion = deltaEntry.baseVersion,
			changes = deltaEntry.delta
		}

		local status = self:ApplyDelta(altName, deltaData)
		if status ~= ADOPTION_STATUS.ADOPTED then
			TOGBankClassic_Output:Debug(
				"Failed to apply delta chain for %s at hop %d (v%d→v%d)",
				norm,
				i,
				deltaEntry.baseVersion,
				deltaEntry.version
			)
			return status
		end

		currentVersion = deltaEntry.version
	end

	local chainTime = debugprofilestop() - chainStart
	TOGBankClassic_Output:Debug(
		"✓ Applied delta chain for %s (%d hops, v%d→v%d) in %.2fms",
		norm,
		#deltaChain,
		deltaChain[1].baseVersion,
		deltaChain[#deltaChain].version,
		chainTime
	)

	return ADOPTION_STATUS.ADOPTED
end

function TOGBankClassic_Guild:Hello(type)
	local addon_data = TOGBankClassic_Guild:GetVersion()
	local current_data = TOGBankClassic_Guild.Info
	if addon_data and current_data then
		local roster_alts = ""
		local guild_bank_alts = ""
		local hello = "Hi! " .. TOGBankClassic_Guild:GetPlayer() .. " is using version " .. addon_data.addon .. "."
		if s(current_data.roster) > 0 and s(current_data.alts) > 0 then
			for _, v in pairs(current_data.roster.alts) do
				if roster_alts ~= "" then
					roster_alts = roster_alts .. ", "
				end
				roster_alts = roster_alts .. v
			end
			if roster_alts ~= "" then
				roster_alts = " (" .. roster_alts .. ")"
			end
			for k, _ in pairs(current_data.alts) do
				if guild_bank_alts ~= "" then
					guild_bank_alts = guild_bank_alts .. ", "
				end
				guild_bank_alts = guild_bank_alts .. k
			end
			if guild_bank_alts ~= "" then
				guild_bank_alts = " (" .. guild_bank_alts .. ")"
			end
			if current_data.roster.alts then
				hello = hello .. "\n"
				hello = hello
					.. "I know about "
					.. #current_data.roster.alts
					.. " guild bank alts"
					.. roster_alts
					.. " on the roster."
				hello = hello .. "\n"
				hello = hello
					.. "I have guild bank data from "
					.. s(current_data.alts)
					.. " alts"
					.. guild_bank_alts
					.. "."
			end
		else
			hello = hello .. " I know about 0 guild bank alts on the roster, and have guild bank data from 0 alts."
		end

		local pending_count = 0
		local fulfilled_count = 0
		local pending_banks = {}
		for _, req in pairs(current_data.requests or {}) do
			local clean = TOGBankClassic_Guild:SanitizeRequest(req)
			if clean and clean.item and clean.item ~= "" then
				local qty = tonumber(clean.quantity or 0) or 0
				local fulfilled = tonumber(clean.fulfilled or 0) or 0
				if qty > 0 then
					local is_fulfilled = clean.status == "fulfilled" or clean.status == "complete" or fulfilled >= qty
					local is_pending = clean.status == "open" and fulfilled < qty
					if is_fulfilled then
						fulfilled_count = fulfilled_count + 1
					elseif is_pending then
						pending_count = pending_count + 1
						if clean.bank and clean.bank ~= "" then
							pending_banks[clean.bank] = true
						end
					end
				end
			end
		end

		local pending_bank_list = {}
		for name in pairs(pending_banks) do
			table.insert(pending_bank_list, name)
		end
		table.sort(pending_bank_list)

		hello = hello
			.. "\n"
			.. string.format(
				"I have %d pending item requests and %d fulfilled item requests.",
				pending_count,
				fulfilled_count
			)
		if #pending_bank_list > 0 then
			hello = hello .. "\n" .. "Pending requests for bank alts: " .. table.concat(pending_bank_list, ", ") .. "."
		else
			hello = hello .. "\n" .. "Pending requests for bank alts: none."
		end

		if type ~= "reply" then
			TOGBankClassic_Output:Info(hello)
		end
		local data = TOGBankClassic_Core:SerializeWithChecksum(hello)
		if type ~= "reply" then
			TOGBankClassic_Core:SendCommMessage("togbank-h", data, "Guild", nil, "BULK")
		else
			TOGBankClassic_Core:SendCommMessage("togbank-hr", data, "Guild", nil, "BULK")
		end
	end
end

function TOGBankClassic_Guild:Wipe(type)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild and not CanViewOfficerNote() then
		return
	end
	local wipe = "I wiped all addon data from " .. guild .. "."
	TOGBankClassic_Guild:Reset(guild)

	local data = TOGBankClassic_Core:SerializeWithChecksum(wipe)
	if type ~= "reply" then
		TOGBankClassic_Core:SendCommMessage("togbank-w", data, "Guild", nil, "BULK")
	else
		TOGBankClassic_Core:SendCommMessage("togbank-wr", data, "Guild", nil, "BULK")
	end
end

function TOGBankClassic_Guild:WipeMine(type)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		return
	end
	local wipe = "I wiped all my addon data from " .. guild .. "."
	TOGBankClassic_Guild:Reset(guild)
end

function TOGBankClassic_Guild:Share(type, requestsMode)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		return
	end
	self.Info = TOGBankClassic_Database:Load(guild)
	local player = TOGBankClassic_Guild:GetPlayer()
	local normPlayer = TOGBankClassic_Guild:GetNormalizedPlayer(player)
	local share = "I'm sharing my bank data. Share yours please."
	local mode = requestsMode or "snapshot"
	if not self.Info.alts[normPlayer] then
		if type ~= "reply" then
			share = "Share your bank data please."
		else
			share = "Nothing to share."
		end
	end
	if self.Info.alts[normPlayer] and TOGBankClassic_Guild:IsBank(normPlayer) then
		TOGBankClassic_Guild:SendAltData(normPlayer)
	end

	if mode == "snapshot" then
		-- Share current requests state alongside bank data so everyone stays in sync
		self:SendRequestsData()
	elseif mode == "version" then
		-- Lightweight ping; snapshots are sent only when queried.
		self:SendRequestsVersionPing()
	end

	local data = TOGBankClassic_Core:SerializeWithChecksum(share)
	if type ~= "reply" then
		TOGBankClassic_Core:SendCommMessage("togbank-s", data, "Guild", nil, "BULK")
	else
		-- TODO: togbank-sr is only used for debug output; consider removing or repurposing.
		TOGBankClassic_Core:SendCommMessage("togbank-sr", data, "Guild", nil, "BULK")
	end
end

function TOGBankClassic_Guild:AuthorRosterData()
	if not self.Info then
		return
	end
	local info = self.Info
	local isBank = false
	local banks = TOGBankClassic_Guild:GetBanks()
	local player = TOGBankClassic_Guild:GetPlayer()
	if banks then
		for _, v in pairs(banks) do
			if v == player then
				isBank = true
				break
			end
		end
	end
	if isBank or CanViewOfficerNote() then
		info.roster.alts = banks
		info.roster.version = GetServerTime()
		if not banks then
			info.roster.version = nil
		end
		TOGBankClassic_Guild:SendRosterData()
		if banks then
			local characterNames = {}
			for _, bankChar in pairs(banks) do
				table.insert(characterNames, bankChar)
			end
			if #characterNames > 0 then
				TOGBankClassic_Output:Info(
					"Sent updated roster containing the follow banks: " .. table.concat(characterNames, ", ")
				)
			else
				TOGBankClassic_Output:Info("Sent empty roster.")
			end
		else
			TOGBankClassic_Output:Info("Sent empty roster.")
		end
	else
		TOGBankClassic_Output:Warn("You lack permissions to share the roster.")
		return
	end
end

function TOGBankClassic_Guild:SenderIsGM(player)
	if not player then
		return false
	end
	if not IsInGuild() then
		return false
	end
	for i = 1, GetNumGuildMembers() do
		local playerRealm, _, rankIndex, _, _, _, publicNote, officer_note = GetGuildRosterInfo(i)
		if playerRealm then
			local norm = self:NormalizeName(playerRealm)
			if rankIndex == 0 and norm == player then
				return true
			end
		end
	end
	return false
end
---END CHANGES
