
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

-- SYNC-001 fix: Check if a player is in the current guild roster
-- Returns true if the player is a member of the current guild
function TOGBankClassic_Guild:IsInCurrentGuildRoster(playerName)
	if not playerName then
		return false
	end
	
	if not IsInGuild() then
		return false
	end
	
	local normPlayer = self:NormalizeName(playerName)
	
	for i = 1, GetNumGuildMembers() do
		local rosterName = GetGuildRosterInfo(i)
		if rosterName then
			local normRoster = self:NormalizeName(rosterName)
			if normRoster == normPlayer then
				return true
			end
		end
	end
	
	return false
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

-- v0.8.0: Fast-fill - Request missing banker alts on UI open
-- Compares roster bankers against local alt data and queries for missing alts
-- SYNC-001 fix: Use current guild roster instead of cached roster to prevent
-- requesting data for bankers from other guilds
function TOGBankClassic_Guild:FastFillMissingAlts()
	if not self.Info then
		return
	end
	
	-- SYNC-001 fix: Get live banker roster from current guild instead of using
	-- cached roster.alts which may contain stale cross-guild data
	local rosterAlts = self:GetBanks()
	if not rosterAlts or #rosterAlts == 0 then
		return
	end
	
	local missing = {}
	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		-- Check if we have this alt locally
		if not self.Info.alts or not self.Info.alts[norm] then
			table.insert(missing, norm)
		end
	end
	
	if #missing == 0 then
		TOGBankClassic_Output:Debug("Fast-fill: All %d roster alts present locally", #rosterAlts)
		return
	end
	
	TOGBankClassic_Output:Info("Fast-fill: Requesting %d missing alts (have %d/%d)", #missing, #rosterAlts - #missing, #rosterAlts)
	
	-- Query each missing alt using pull-based protocol
	for _, norm in ipairs(missing) do
		self:QueryAltPullBased(norm)
	end
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
		-- v0.8.0: Include inventory hash for pull-based protocol
		if type(v) == "table" and v.version then
			-- Send hash only in delta-enabled mode (backwards compatibility)
			if PROTOCOL.SUPPORTS_DELTA and v.inventoryHash then
				data.alts[k] = {
					version = v.version,
					hash = v.inventoryHash,
				}
				TOGBankClassic_Output:Debug("Broadcasting %s: version=%d, hash=%d", k, v.version, v.inventoryHash)
			else
				-- Legacy format for old clients
				data.alts[k] = v.version
				TOGBankClassic_Output:Debug("Broadcasting %s: version=%d (no hash)", k, v.version)
			end
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
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, "NORMAL")
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
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, "NORMAL")
end

-- v0.8.0: Pull-based query - WHISPER to banker if known, GUILD if unknown
function TOGBankClassic_Guild:QueryAltPullBased(name)
	if not name then
		return
	end
	
	local norm = self:NormalizeName(name)
	self.hasRequested = true
	if self.requestCount == nil then
		self.requestCount = 1
	else
		self.requestCount = self.requestCount + 1
	end
	
	-- Check if we have an online banker
	local onlineBankers = TOGBankClassic_Chat.online_bankers or {}
	local banker = nil
	local mostRecent = 0
	
	for sender, info in pairs(onlineBankers) do
		if info.seen > mostRecent then
			mostRecent = info.seen
			banker = sender
		end
	end
	
	-- Build request message
	local request = {
		type = "alt-request",  -- v0.8.0 pull-based request
		name = norm,
		requester = self:GetNormalizedPlayer(),
	}
	
	local data = TOGBankClassic_Core:SerializeWithChecksum(request)
	
	if banker and (GetServerTime() - mostRecent) < 600 and self:IsPlayerOnline(banker) then
		-- Banker known, seen recently (within 10 min), AND currently online - WHISPER directly
		TOGBankClassic_Output:DebugComm("SENDING WHISPER: togbank-r to %s for alt %s", banker, norm)
		TOGBankClassic_Output:Debug("Pull-based query for %s (WHISPER to banker %s)", norm, banker)
		TOGBankClassic_Core:SendCommMessage("togbank-r", data, "WHISPER", banker, "NORMAL")
		self:MarkPendingSync("alt", banker, norm)
	else
		-- No known banker, stale, or offline - broadcast on GUILD
		TOGBankClassic_Output:DebugComm("SENDING GUILD BROADCAST: togbank-r for alt %s (no online banker)", norm)
		TOGBankClassic_Output:Debug("Pull-based query for %s (GUILD broadcast, no online banker)", norm)
		TOGBankClassic_Core:SendCommMessage("togbank-r", data, "GUILD", nil, "NORMAL")
		self:MarkPendingSync("alt", nil, norm)
	end
end

function TOGBankClassic_Guild:SendRosterData()
	-- Safety check: Info might be nil if guild data not loaded yet
	if not self.Info then
		return
	end
	
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

-- Check if a player is currently online in the guild
function TOGBankClassic_Guild:IsPlayerOnline(playerName)
	if not playerName then
		return false
	end
	
	local norm = self:NormalizeName(playerName)
	
	for i = 1, GetNumGuildMembers() do
		local playerRealm, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
		if playerRealm then
			local memberNorm = self:NormalizeName(playerRealm)
			if memberNorm == norm then
				return isOnline == 1 or isOnline == true
			end
		end
	end
	
	return false
end

-- v0.8.0: Compute minimal state summary for pull-based protocol
-- Returns {[itemID] = quantity} - no Links, bags, slots, or metadata
-- ~800 bytes for 100 items vs 5-7KB for full data
function TOGBankClassic_Guild:ComputeStateSummary(name)
	if not name then
		return nil
	end
	
	local norm = self:NormalizeName(name)
	
	-- If we don't have data for this alt, return a "no data" summary
	if not self.Info or not self.Info.alts or not self.Info.alts[norm] then
		return {
			version = 0,
			hash = nil,
			money = 0,
			items = {}
		}
	end
	
	local alt = self.Info.alts[norm]
	local summary = {
		version = alt.version or 0,
		hash = alt.inventoryHash or nil,  -- v0.8.0: Include inventory hash for delta comparison
		money = alt.money or 0,
		items = {}  -- {[itemID] = quantity}
	}
	
	-- Aggregate items by ID (combine bank + bags)
	local function addItems(items)
		if not items then return end
		for _, item in ipairs(items) do
			if item and item.ID then
				local id = tostring(item.ID)
				local count = item.Count or 1
				summary.items[id] = (summary.items[id] or 0) + count
			end
		end
	end
	
	if alt.bank and alt.bank.items then
		addItems(alt.bank.items)
	end
	if alt.bags and alt.bags.items then
		addItems(alt.bags.items)
	end
	
	return summary
end

-- v0.8.0: Send state summary to responder (Step 4 of pull-based flow)
function TOGBankClassic_Guild:SendStateSummary(name, target)
	TOGBankClassic_Output:DebugComm("SendStateSummary CALLED: name=%s, target=%s", tostring(name), tostring(target))
	if not name or not target then
		TOGBankClassic_Output:DebugComm("SendStateSummary EARLY RETURN: missing params")
		return
	end
	
	local summary = self:ComputeStateSummary(name)
	if not summary then
		TOGBankClassic_Output:DebugComm("SendStateSummary: No summary for %s", tostring(name))
		TOGBankClassic_Output:Debug("Cannot send state summary for %s (no data)", name)
		return
	end
	
	local message = {
		type = "state-summary",
		name = name,
		summary = summary,
	}
	
	-- Check if target is online before sending WHISPER
	if not self:IsPlayerOnline(target) then
		TOGBankClassic_Output:Debug("Cannot send state summary to %s - player is offline", target)
		return
	end
	
	local data = TOGBankClassic_Core:SerializeWithChecksum(message)
	TOGBankClassic_Output:DebugComm("SENDING STATE SUMMARY via WHISPER to %s for %s (%d bytes, hash=%s)", target, name, #data, tostring(summary.hash))
	TOGBankClassic_Core:SendCommMessage("togbank-state", data, "WHISPER", target, "NORMAL")
	
	local itemCount = 0
	for _ in pairs(summary.items) do itemCount = itemCount + 1 end
	TOGBankClassic_Output:Debug(
		"Sent state summary for %s to %s (%d unique items, %d bytes)",
		name,
		target,
		itemCount,
		string.len(data)
	)
end

-- v0.8.0: Respond to state summary (Step 5 & 6 of pull-based flow)
-- Compare requester's state with our data and send appropriate response
function TOGBankClassic_Guild:RespondToStateSummary(name, summary, requester)
	TOGBankClassic_Output:DebugComm("RespondToStateSummary CALLED: name=%s, requester=%s", tostring(name), tostring(requester))
	if not name or not summary or not requester then
		TOGBankClassic_Output:DebugComm("RespondToStateSummary EARLY RETURN: missing params")
		return
	end
	
	local norm = self:NormalizeName(name)
	if not self.Info or not self.Info.alts or not self.Info.alts[norm] then
		TOGBankClassic_Output:DebugComm("RespondToStateSummary: No data for %s", norm)
		TOGBankClassic_Output:Debug("Cannot respond to state summary for %s (no data)", norm)
		return
	end
	
	local currentAlt = self.Info.alts[norm]
	local requesterVersion = summary.version or 0
	local currentVersion = currentAlt.version or 0
	
	-- v0.8.0: In delta mode, compare HASHES not versions
	local requesterHash = summary.hash or nil
	local currentHash = currentAlt.inventoryHash or nil
	
	TOGBankClassic_Output:DebugComm("RespondToStateSummary: %s requesterV=%d currentV=%d requesterHash=%s currentHash=%s", norm, requesterVersion, currentVersion, tostring(requesterHash), tostring(currentHash))
	
	-- v0.8.0: Delta mode - ONLY use hashes, no version fallback
	if self:ShouldUseDelta() then
		-- If current alt doesn't have a hash, send full data (might be from pre-hash version)
		if not currentHash then
			TOGBankClassic_Output:DebugComm("DELTA MODE: Current alt missing hash - sending full data for %s", norm)
			TOGBankClassic_Output:Debug("Sending full data to %s for %s (responder has no hash)", requester, norm)
			self:SendAltData(norm)
			return
		end
		
		-- If requester has no hash (nil), they have no data - send everything
		if not requesterHash then
			TOGBankClassic_Output:DebugComm("DELTA MODE: REQUESTER HAS NO DATA (hash=nil) - sending full data for %s", norm)
			TOGBankClassic_Output:Debug("Sending full data to %s for %s (requester has no data)", requester, norm)
			self:SendAltData(norm)
			return
		end
		
		if requesterHash == currentHash then
			-- Check if requester is online before sending WHISPER
			if not self:IsPlayerOnline(requester) then
				TOGBankClassic_Output:Debug("Cannot send no-change to %s - player is offline", requester)
				return
			end
			
			-- Hashes match - no changes needed
			local noChangeMsg = {
				type = "no-change",
				name = norm,
				version = currentVersion,
				hash = currentHash,
			}
			local data = TOGBankClassic_Core:SerializeWithChecksum(noChangeMsg)
			TOGBankClassic_Output:DebugComm("DELTA MODE: SENDING NO-CHANGE to %s for %s (hash match: %d)", requester, norm, currentHash)
			TOGBankClassic_Core:SendCommMessage("togbank-nochange", data, "WHISPER", requester, "NORMAL")
			TOGBankClassic_Output:Debug("Sent no-change reply to %s for %s (hash=%d)", requester, norm, currentHash)
			return
		else
			-- Hashes differ - send data
			TOGBankClassic_Output:DebugComm("DELTA MODE: HASH MISMATCH - calling SendAltData for %s (requester=%d, current=%d)", norm, requesterHash, currentHash)
			TOGBankClassic_Output:Debug(
				"Sending data to %s for %s (hash mismatch: requester=%d, current=%d)",
				requester,
				norm,
				requesterHash,
				currentHash
			)
			self:SendAltData(norm)
			return
		end
	end
	
	-- Legacy mode: Compare versions only
	TOGBankClassic_Output:DebugComm("LEGACY MODE: Comparing versions")
	if requesterVersion == currentVersion then
		-- Check if requester is online before sending WHISPER
		if not self:IsPlayerOnline(requester) then
			TOGBankClassic_Output:Debug("Cannot send no-change to %s - player is offline", requester)
			return
		end
		
		-- No changes - send no-change message
		local noChangeMsg = {
			type = "no-change",
			name = norm,
			version = currentVersion,
		}
		local data = TOGBankClassic_Core:SerializeWithChecksum(noChangeMsg)
		TOGBankClassic_Output:DebugComm("SENDING NO-CHANGE to %s for %s (version match)", requester, norm)
		TOGBankClassic_Core:SendCommMessage("togbank-nochange", data, "WHISPER", requester, "NORMAL")
		TOGBankClassic_Output:Debug("Sent no-change reply to %s for %s (v%d)", requester, norm, currentVersion)
		return
	end
	
	-- Requester has different version - send data via GUILD channel
	-- Use existing SendAltData which handles protocol mode and dual-send
	TOGBankClassic_Output:DebugComm("VERSION MISMATCH: calling SendAltData for %s", norm)
	TOGBankClassic_Output:Debug(
		"Sending data to %s for %s (requester v%d, current v%d)",
		requester,
		norm,
		requesterVersion,
		currentVersion
	)
	self:SendAltData(norm)
end

-- Strip Link fields from items for transmission (v0.8.0 bandwidth optimization)
-- Saves 60-80 bytes per item, receiver reconstructs with GetItemInfo()
function TOGBankClassic_Guild:StripItemLinks(items)
	if not items then
		return nil
	end
	
	local stripped = {}
	for _, item in ipairs(items) do
		table.insert(stripped, {
			ID = item.ID,
			Count = item.Count
			-- Link removed - receiver will reconstruct
		})
	end
	return stripped
end

-- Reconstruct Link fields after receiving data (v0.8.0)
-- Calls GetItemInfo() to recreate links from ItemID
function TOGBankClassic_Guild:ReconstructItemLinks(items)
	if not items then
		return
	end
	
	local needsAsyncLoad = false
	
	for _, item in ipairs(items) do
		if item and item.ID and not item.Link then
			-- Try to get link from item cache
			local itemLink = select(2, GetItemInfo(item.ID))
			if itemLink then
				item.Link = itemLink
			else
				-- Item not in cache, use async loading
				needsAsyncLoad = true
				local itemObj = Item:CreateFromItemID(item.ID)
				if itemObj then
					itemObj:ContinueOnItemLoad(function()
						local link = itemObj:GetItemLink()
						if link then
							item.Link = link
							-- Refresh UI when link becomes available
							if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
								TOGBankClassic_UI_Inventory:DrawContent()
							end
						end
					end)
				end
			end
		end
	end
	
	-- If some links loaded immediately from cache, refresh UI now
	if not needsAsyncLoad and TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
		TOGBankClassic_UI_Inventory:DrawContent()
	end
end

-- Strip Links from entire alt structure before transmission
function TOGBankClassic_Guild:StripAltLinks(alt)
	if not alt then
		return nil
	end
	
	local stripped = {
		version = alt.version,
		money = alt.money,
		bank = {
			items = self:StripItemLinks(alt.bank and alt.bank.items),
			numSlots = alt.bank and alt.bank.numSlots,
			slotsFilled = alt.bank and alt.bank.slotsFilled
		},
		bags = {
			items = self:StripItemLinks(alt.bags and alt.bags.items),
			numSlots = alt.bags and alt.bags.numSlots,
			slotsFilled = alt.bags and alt.bags.slotsFilled
		}
	}
	return stripped
end

-- Strip Links from delta changes structure (v0.8.0 bandwidth optimization)
-- Processes add/modify/remove arrays in delta.changes.bank and delta.changes.bags
function TOGBankClassic_Guild:StripDeltaLinks(delta)
	if not delta or not delta.changes then
		return nil
	end
	
	local function stripItemArray(items)
		if not items then return nil end
		local stripped = {}
		for _, item in ipairs(items) do
			local strippedItem = {
				ID = item.ID,
				Count = item.Count
				-- Link removed - receiver will reconstruct
			}
			-- Preserve Info if present (for modified items)
			if item.Info then
				strippedItem.Info = item.Info
			end
			table.insert(stripped, strippedItem)
		end
		return stripped
	end
	
	local strippedDelta = {
		type = delta.type,
		name = delta.name,
		version = delta.version,
		-- v0.8.0: baseVersion no longer included (8 bytes saved)
		changes = {}
	}
	
	-- Copy money change (no Link to strip)
	if delta.changes.money then
		strippedDelta.changes.money = delta.changes.money
	end
	
	-- Strip Links from bank changes
	if delta.changes.bank then
		strippedDelta.changes.bank = {
			added = stripItemArray(delta.changes.bank.added),
			modified = stripItemArray(delta.changes.bank.modified),
			removed = stripItemArray(delta.changes.bank.removed)
		}
	end
	
	-- Strip Links from bags changes
	if delta.changes.bags then
		strippedDelta.changes.bags = {
			added = stripItemArray(delta.changes.bags.added),
			modified = stripItemArray(delta.changes.bags.modified),
			removed = stripItemArray(delta.changes.bags.removed)
		}
	end
	
	return strippedDelta
end

function TOGBankClassic_Guild:SendAltData(name)
	if not name then
		return
	end
	local norm = self:NormalizeName(name)
	if not self.Info or not self.Info.alts or not self.Info.alts[norm] then
		return
	end

	-- v0.8.0: Version is ONLY set by Bank:Scan() when inventory actually changes
	-- No longer bump version here - that caused version drift from communication

	local currentAlt = self.Info.alts[norm]
	local useDelta = false
	local deltaData = nil
	local computeStart = debugprofilestop()

	-- Check if delta sync should be used
	-- v0.8.0: No longer skip delta based on force flag (removed)
	if self:ShouldUseDelta() then
		deltaData = self:ComputeDelta(norm, currentAlt)
		if deltaData and self:DeltaHasChanges(deltaData) then
			local deltaSize = self:EstimateSize(deltaData)
			local fullSize = self:EstimateSize({ type = "alt", name = norm, alt = currentAlt })
			
			-- Use delta if significantly smaller OR if forced
			local forceDelta = FEATURES and FEATURES.FORCE_DELTA_SYNC
			if forceDelta or deltaSize < fullSize * PROTOCOL.MIN_DELTA_SIZE_RATIO then
				useDelta = true
				TOGBankClassic_Output:Debug(
					"✓ Delta selected for %s: %d bytes vs %d bytes full (%.1f%% size, %.0f bytes saved)%s",
					norm,
					deltaSize,
					fullSize,
					(deltaSize / fullSize) * 100,
					fullSize - deltaSize,
					forceDelta and " [FORCED]" or ""
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
		-- Send delta with dual-send for backwards compatibility (v0.8.0)
		local mode = PROTOCOL_MODES[FEATURES.PROTOCOL_MODE] or PROTOCOL_MODES.AUTO
		local deltaWithLinks, deltaNoLinks
		
		-- Prepare legacy format (with Links) if needed
		if mode.sendLegacy then
			deltaWithLinks = TOGBankClassic_Core:SerializeWithChecksum(deltaData)
			TOGBankClassic_Core:SendCommMessage("togbank-d2", deltaWithLinks, "Guild", nil, "BULK", OnChunkSent)
			TOGBankClassic_Output:Debug("Sent delta update for %s via togbank-d2 (with Links)", norm)
		end
		
		-- Prepare new format (without Links) if needed - saves 60-80 bytes per item
		if mode.sendNew then
			local strippedDelta = self:StripDeltaLinks(deltaData)
			deltaNoLinks = TOGBankClassic_Core:SerializeWithChecksum(strippedDelta)
			TOGBankClassic_Core:SendCommMessage("togbank-d4", deltaNoLinks, "Guild", nil, "BULK", OnChunkSent)
			TOGBankClassic_Output:Debug("Sent delta update for %s via togbank-d4 (no Links)", norm)
			
			-- Log bandwidth savings if dual-sending
			if mode.sendLegacy and deltaWithLinks then
				local savings = string.len(deltaWithLinks) - string.len(deltaNoLinks)
				TOGBankClassic_Output:Debug("Bandwidth saved: %d bytes (%.1f%%)", savings, (savings / string.len(deltaWithLinks)) * 100)
			end
		end
		
		-- Track metrics using the size of the format we're using (prefer new format)
		local serialized = deltaNoLinks or deltaWithLinks
		TOGBankClassic_Output:Debug("Final delta size: %d bytes", string.len(serialized or ""))
		
		-- Track metrics
		if self.Info and self.Info.name then
			TOGBankClassic_Database:RecordDeltaSent(self.Info.name, string.len(serialized or ""))
		end
		
		-- Save delta to history for potential chain replay (DELTA-006)
		-- v0.8.0: Use previous.version for baseVersion in history (delta no longer includes it)
		if self.Info and self.Info.name and deltaData.version and deltaData.changes then
			local previous = TOGBankClassic_Database:GetSnapshot(self.Info.name, norm)
			local baseVer = previous and previous.version or 0
			TOGBankClassic_Database:SaveDeltaHistory(
				self.Info.name,
				norm,
				baseVer,
				deltaData.version,
				deltaData  -- Save full delta, not just changes
			)
		end
		
		-- Save snapshot for next delta
		if self.Info and self.Info.name then
			TOGBankClassic_Database:SaveSnapshot(self.Info.name, norm, currentAlt)
		end
	else
		-- Fallback to full sync via togbank-d/togbank-d3
		-- Record fallback reason if we computed delta but chose full sync
		if deltaData and self:DeltaHasChanges(deltaData) then
			if self.Info and self.Info.name then
				TOGBankClassic_Database:RecordFullSyncFallback(self.Info.name)
			end
			
			-- Save delta to history even when falling back to full sync (DELTA-006)
			-- This allows chain replay to work for offline players even when deltas were too large
			-- v0.8.0: Use previous.version for baseVersion in history (delta no longer includes it)
			if self.Info and self.Info.name and deltaData.version and deltaData.changes then
				local previous = TOGBankClassic_Database:GetSnapshot(self.Info.name, norm)
				local baseVer = previous and previous.version or 0
				TOGBankClassic_Database:SaveDeltaHistory(
					self.Info.name,
					norm,
					baseVer,
					deltaData.version,
					deltaData  -- Save full delta, not just changes
				)
			end
		end
		
		-- Send full sync based on protocol mode (user-configurable)
		local mode = PROTOCOL_MODES[FEATURES.PROTOCOL_MODE] or PROTOCOL_MODES.AUTO
		local dataWithLinks, dataNoLinks
		
		-- Prepare legacy format (with Links) if needed
		if mode.sendLegacy then
			dataWithLinks = TOGBankClassic_Core:SerializeWithChecksum({ type = "alt", name = norm, alt = currentAlt })
			TOGBankClassic_Output:DebugComm("SENDING RESPONSE: togbank-d (legacy) for %s (%d bytes)", norm, #dataWithLinks)
			TOGBankClassic_Core:SendCommMessage("togbank-d", dataWithLinks, "Guild", nil, "BULK", OnChunkSent)
		end
		
		-- Prepare new format (without Links) if needed
		if mode.sendNew then
			local strippedAlt = self:StripAltLinks(currentAlt)
			dataNoLinks = TOGBankClassic_Core:SerializeWithChecksum({ type = "alt", name = norm, alt = strippedAlt })
			TOGBankClassic_Output:DebugComm("SENDING RESPONSE: togbank-d3 (new) for %s (%d bytes)", norm, #dataNoLinks)
			TOGBankClassic_Core:SendCommMessage("togbank-d3", dataNoLinks, "Guild", nil, "BULK", OnChunkSent)
		end
		
		-- Log what was sent
		if mode.sendLegacy and mode.sendNew then
			TOGBankClassic_Output:Debug(
				"Sent full sync for %s [%s]: togbank-d (%d bytes) + togbank-d3 (%d bytes, %.1f%% savings)",
				norm,
				FEATURES.PROTOCOL_MODE,
				string.len(dataWithLinks or ""),
				string.len(dataNoLinks or ""),
				100 - (string.len(dataNoLinks or "") / string.len(dataWithLinks or "") * 100)
			)
		elseif mode.sendLegacy then
			TOGBankClassic_Output:Debug(
				"Sent full sync for %s [LEGACY_ONLY]: togbank-d (%d bytes with Links)",
				norm,
				string.len(dataWithLinks or "")
			)
		elseif mode.sendNew then
			TOGBankClassic_Output:Debug(
				"Sent full sync for %s [NEW_ONLY]: togbank-d3 (%d bytes without Links)",
				norm,
				string.len(dataNoLinks or "")
			)
		end
		
		-- Track metrics
		if self.Info and self.Info.name then
			local totalSize = (dataWithLinks and string.len(dataWithLinks) or 0) + (dataNoLinks and string.len(dataNoLinks) or 0)
			TOGBankClassic_Database:RecordFullSyncSent(self.Info.name, totalSize)
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
		TOGBankClassic_Output:Debug("Sharing guild bank data: %d bytes in ~%d chunks...", totalBytes, totalChunks)
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

	-- Check against existing alt data, but only if version exists
	if self.Info.alts[name] and alt.version ~= nil and self.Info.alts[name].version ~= nil and alt.version < self.Info.alts[name].version then
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
	
	-- Reconstruct Links for items (v0.8.0 bandwidth optimization)
	if alt.bank and alt.bank.items then
		self:ReconstructItemLinks(alt.bank.items)
	end
	if alt.bags and alt.bags.items then
		self:ReconstructItemLinks(alt.bags.items)
	end
	
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

-- Check if delta sync should be used
function TOGBankClassic_Guild:ShouldUseDelta()
	-- Check force flags first (for testing)
	if FEATURES and FEATURES.FORCE_DELTA_SYNC then
		return true
	end
	
	-- Check feature flags
	if not FEATURES or not FEATURES.DELTA_ENABLED then
		return false
	end
	if FEATURES.FORCE_FULL_SYNC then
		return false
	end

	-- v0.8.0: Delta protocol always enabled if feature flag is on
	-- No guild support threshold - clients will use delta if both sides support it
	return PROTOCOL.SUPPORTS_DELTA
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
		-- v0.8.0: Minimal removes format (just ID, no Link or Count)
		-- Saves 4 bytes per removed item
		table.insert(delta.removed, { ID = item.ID })
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
	-- v0.8.0: baseVersion removed (8 bytes saved)
	-- In pull-based protocol, receiver states what they have, making baseVersion redundant
	local delta = {
		type = "alt-delta",
		name = name,
		version = currentAlt.version or GetServerTime(),
		-- baseVersion removed for v0.8.0 (still accepted when receiving for backwards compatibility)
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
	-- v0.8.0: Removed items now only have ID (Link removed for bandwidth savings)
	if delta.removed then
		for _, removedItem in ipairs(delta.removed) do
			if removedItem and removedItem.ID then
				-- v0.8.0: Match by ID only (Link field removed)
				-- Still support old format with Link for backwards compatibility
				if removedItem.Link then
					-- Old format (v0.7.0): Has Link, use ID+Link key
					local key = tostring(removedItem.ID) .. removedItem.Link
					for i = #items, 1, -1 do
						local item = items[i]
						if item and item.ID and item.Link then
							local itemKey = tostring(item.ID) .. item.Link
							if itemKey == key then
								table.remove(items, i)
								break
							end
						end
					end
				else
					-- New format (v0.8.0): Only has ID, match by ID only
					for i = #items, 1, -1 do
						local item = items[i]
						if item and item.ID == removedItem.ID then
							table.remove(items, i)
							break  -- Remove first match only
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
	-- v0.8.0: baseVersion no longer sent, but accept it for backwards compatibility
	local baseVersion = deltaData.baseVersion or currentVersion

	-- Only check version mismatch if delta included baseVersion (v0.7.0 and earlier)
	if deltaData.baseVersion and currentVersion ~= baseVersion then
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

	-- Trigger UI refresh if Inventory window is open
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
		TOGBankClassic_UI_Inventory:DrawContent()
	end

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
	
	-- Check if sender is online before attempting WHISPER (DELTA-008)
	if not self:IsPlayerOnline(sender) then
		TOGBankClassic_Output:Debug(
			"Cannot request delta chain for %s from %s - sender is offline",
			altName,
			sender
		)
		return false
	end

	-- Note: We don't check version gap age here - if we have the deltas, we use them.
	-- The delta history cleanup (DELTA_HISTORY_MAX_AGE) handles storage limits.
	-- If we can't build the chain, BuildDeltaChain will return nil and we'll fall back.

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

	-- v0.8.0: Broadcast delta version with hashes for pull-based protocol
	-- Send BOTH legacy and delta version broadcasts (SYNC-001 fix)
	if TOGBankClassic_Events and TOGBankClassic_Events.Sync then
		TOGBankClassic_Events:Sync()
	end
	if TOGBankClassic_Events and TOGBankClassic_Events.SyncDeltaVersion then
		TOGBankClassic_Events:SyncDeltaVersion()
	end

	local data = TOGBankClassic_Core:SerializeWithChecksum(share)
	if type ~= "reply" then
		-- Use NORMAL priority for share announcement so users are notified quickly
		-- Actual data transfers (deltas/snapshots) use BULK to avoid network spam
		TOGBankClassic_Core:SendCommMessage("togbank-s", data, "Guild", nil, "NORMAL")
	else
		-- TODO: togbank-sr is only used for debug output; consider removing or repurposing.
		TOGBankClassic_Core:SendCommMessage("togbank-sr", data, "Guild", nil, "NORMAL")
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
