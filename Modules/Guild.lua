
TOGBankClassic_Guild = {}

TOGBankClassic_Guild.Info = nil

-- Cache of online guild members (updated via GUILD_ROSTER_UPDATE)
-- Avoids stale data from GuildRoster() which only requests an update
TOGBankClassic_Guild.onlineMembers = {}

-- Cache of guild bankers (updated via GUILD_ROSTER_UPDATE)
-- Prevents iterating through entire guild roster on every IsBank() call
TOGBankClassic_Guild.banksCache = nil

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

	TOGBankClassic_Output:Debug("DATABASE", "Migrated temporary delta errors to database")
end

-- Record a delta error with details (persisted to database or temp storage)
-- Delta error tracking delegated to DeltaComms module (v0.7.0+)
function TOGBankClassic_Guild:RecordDeltaError(altName, errorType, errorMessage)
	return TOGBankClassic_DeltaComms:RecordDeltaError(self.Info and self.Info.name, altName, errorType, errorMessage)
end

-- Reset failure count for an alt (called on successful sync)
function TOGBankClassic_Guild:ResetDeltaErrorCount(altName)
	return TOGBankClassic_DeltaComms:ResetDeltaErrorCount(self.Info and self.Info.name, altName)
end

-- Get recent delta errors
function TOGBankClassic_Guild:GetRecentDeltaErrors()
	return TOGBankClassic_DeltaComms:GetRecentDeltaErrors(self.Info and self.Info.name)
end

-- Get failure count for an alt
function TOGBankClassic_Guild:GetDeltaFailureCount(altName)
	return TOGBankClassic_DeltaComms:GetDeltaFailureCount(self.Info and self.Info.name, altName)
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
	local count, max, delay = 0, 10, 15
	local timer
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
		-- Rebuild banker roster from guild notes on init
		self:RebuildBankerRoster()
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
			if alt.items then
				-- alt.items should be an array or a map of items with ID fields; remove any empty entries
				for k, v in pairs(alt.items) do
					if not v or type(v) ~= "table" or not v.ID then
						alt.items[k] = nil
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
			if alt.items and next(alt.items) then
				hasData = true
			end
			if not hasData then
				remove = true
			end
		end

		if remove then
			TOGBankClassic_Output:Debug("DATABASE", "Removing malformed bank entry for", name)
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
	-- Return cached banks list if available
	if self.banksCache ~= nil then
		return self.banksCache
	end
	-- Build banks list
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
	-- Cache the result (nil if no banks found)
	if #banks == 0 then
		self.banksCache = nil
		return nil
	end
	self.banksCache = banks
	return banks
end

-- Invalidate the banks cache (call when guild roster changes)
function TOGBankClassic_Guild:InvalidateBanksCache()
	self.banksCache = nil
end

-- Rebuild banker roster from local guild notes (no network communication needed)
-- Called automatically on GUILD_ROSTER_UPDATE event
function TOGBankClassic_Guild:RebuildBankerRoster()
	if not self.Info then
		return
	end

	local banks = {}
	for i = 1, GetNumGuildMembers() do
		local name, _, _, _, _, _, publicNote, officer_note = GetGuildRosterInfo(i)
		if name and (publicNote or officer_note) then
			if (publicNote and string.match(publicNote, "(.*)gbank(.*)")) or
			   (officer_note and string.match(officer_note, "(.*)gbank(.*)")) then
				table.insert(banks, name)
			end
		end
	end

	-- Update roster.alts list (no version tracking needed - purely local)
	local oldRoster = table.concat(self.Info.roster.alts or {}, ",")
	local newRoster = table.concat(banks, ",")
	
	if oldRoster ~= newRoster then
		self.Info.roster.alts = banks
		TOGBankClassic_Output:Debug("ROSTER", "Rebuilt banker roster from guild notes: %d bankers", #banks)
	end
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
-- Fast-fill delegated to DeltaComms module (v0.8.0)
function TOGBankClassic_Guild:FastFillMissingAlts()
	return TOGBankClassic_DeltaComms:FastFillMissingAlts(self.Info)
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

function TOGBankClassic_Guild:GetAnyBanker()
	local banks = self:GetBanks()
	if not banks or #banks == 0 then
		return nil
	end
	-- Return the first banker (normalized)
	return self:NormalizeName(banks[1])
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
				TOGBankClassic_Output:Debug("SYNC", "Broadcasting %s: version=%d, hash=%d", k, v.version, v.inventoryHash)
			else
				-- Legacy format for old clients
				data.alts[k] = v.version
				TOGBankClassic_Output:Debug("SYNC", "Broadcasting %s: version=%d (no hash)", k, v.version)
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
	if not self.pending_sync.roster then
		self.pending_sync.roster = {}
	end
	if not self.pending_sync.alts then
		self.pending_sync.alts = {}
	end

	if syncType == "roster" then
		if self.pending_sync.roster then
			---@diagnostic disable-next-line: need-check-nil
			self.pending_sync.roster[normSender] = now
		end
	elseif syncType == "alt" and name then
		local normName = self:NormalizeName(name)
		if self.pending_sync.alts and not self.pending_sync.alts[normName] then
			---@diagnostic disable-next-line: need-check-nil
			self.pending_sync.alts[normName] = {}
		end
		if self.pending_sync.alts and self.pending_sync.alts[normName] then
			---@diagnostic disable-next-line: need-check-nil
			self.pending_sync.alts[normName][normSender] = now
		end
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
			---@diagnostic disable-next-line: need-check-nil
			roster[normSender] = nil
			return true
		end
		if ts then
			---@diagnostic disable-next-line: need-check-nil
			roster[normSender] = nil
		end
		return false
	end
	if syncType == "alt" and name then
		local normName = self:NormalizeName(name)
		local alts = self.pending_sync.alts and self.pending_sync.alts[normName]
		local ts = alts and alts[normSender]
		if ts and now - ts <= PENDING_SYNC_TTL_SECONDS then
			---@diagnostic disable-next-line: need-check-nil
			alts[normSender] = nil
			if next(alts) == nil then
				---@diagnostic disable-next-line: need-check-nil
				self.pending_sync.alts[normName] = nil
			end
			return true
		end
		if ts then
			---@diagnostic disable-next-line: need-check-nil
			alts[normSender] = nil
			if next(alts) == nil then
				---@diagnostic disable-next-line: need-check-nil
				self.pending_sync.alts[normName] = nil
			end
		end
	end
	return false
end

-- DEPRECATED: Roster sync no longer uses network communication
-- Each player rebuilds roster locally from guild notes on GUILD_ROSTER_UPDATE
function TOGBankClassic_Guild:QueryRoster(player, version)
	-- No-op: Roster is now local-only
	TOGBankClassic_Output:Debug("ROSTER", "QueryRoster called but roster sync is now local-only")
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
		TOGBankClassic_Output:Debug("SYNC", "Pull-based query for %s (WHISPER to banker %s)", norm, banker)
		TOGBankClassic_Core:SendWhisper("togbank-r", data, banker, "NORMAL")
		self:MarkPendingSync("alt", banker, norm)
	else
		-- No known banker, stale, or offline - broadcast on GUILD
		TOGBankClassic_Output:DebugComm("SENDING GUILD BROADCAST: togbank-r for alt %s (no online banker)", norm)
		TOGBankClassic_Output:Debug("SYNC", "Pull-based query for %s (GUILD broadcast, no online banker)", norm)
		TOGBankClassic_Core:SendCommMessage("togbank-r", data, "GUILD", nil, "NORMAL")
		self:MarkPendingSync("alt", nil, norm)
	end
end

-- DEPRECATED: Roster sync no longer uses network communication
-- Each player rebuilds roster locally from guild notes on GUILD_ROSTER_UPDATE
function TOGBankClassic_Guild:SendRosterData()
	-- No-op: Roster is now local-only
	TOGBankClassic_Output:Debug("ROSTER", "SendRosterData called but roster sync is now local-only")
end

-- DEPRECATED: Roster sync no longer uses network communication
-- Each player rebuilds roster locally from guild notes on GUILD_ROSTER_UPDATE
function TOGBankClassic_Guild:ReceiveRosterData(roster)
	-- No-op: Roster is now local-only
	TOGBankClassic_Output:Debug("ROSTER", "ReceiveRosterData called but roster sync is now local-only")
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

-- Refresh the online members cache from current guild roster
-- Called automatically when GUILD_ROSTER_UPDATE event fires
function TOGBankClassic_Guild:RefreshOnlineCache()
	local startTime = debugprofilestop()
	self.onlineMembers = self.onlineMembers or {}
	wipe(self.onlineMembers)
	for i = 1, GetNumGuildMembers() do
		local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
		if name and isOnline then
			local normalized = self:NormalizeName(name)
			if self.onlineMembers and normalized then
				self.onlineMembers[normalized] = true
			end
		end
	end
	local count = 0
	for _ in pairs(self.onlineMembers) do
		count = count + 1
	end
	local duration = debugprofilestop() - startTime
	TOGBankClassic_Performance:RecordOperation("RefreshOnlineCache", duration)
	TOGBankClassic_Output:Debug("CACHE", "Refreshed online cache: %d members online", count)
	TOGBankClassic_Output:Debug("ROSTER", "[GUILD ROSTER] Refreshed online cache: %d members online", count)
end

-- Check if a player is currently online in the guild
-- Uses cached roster data updated via GUILD_ROSTER_UPDATE event
function TOGBankClassic_Guild:IsPlayerOnline(playerName)
	if not playerName then
		return false
	end
	local norm = self:NormalizeName(playerName)
	return self.onlineMembers[norm] == true
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

	-- Aggregate items by ID
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

	if alt.items then
		addItems(alt.items)
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
		TOGBankClassic_Output:Debug("SYNC", "Cannot send state summary for %s (no data)", name)
		return
	end

	local message = {
		type = "state-summary",
		name = name,
		summary = summary,
	}

	local data = TOGBankClassic_Core:SerializeWithChecksum(message)
	TOGBankClassic_Output:DebugComm("SENDING STATE SUMMARY via WHISPER to %s for %s (%d bytes, hash=%s)", target, name, #data, tostring(summary.hash))
	if not TOGBankClassic_Core:SendWhisper("togbank-state", data, target, "NORMAL") then
		return
	end

	local itemCount = 0
	for _ in pairs(summary.items) do itemCount = itemCount + 1 end
	TOGBankClassic_Output:Debug(
		"SYNC",
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
		TOGBankClassic_Output:Debug("SYNC", "Cannot respond to state summary for %s (no data)", norm)
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
			TOGBankClassic_Output:Debug("SYNC", "Sending full data to %s for %s (responder has no hash)", requester, norm)
			self:SendAltData(norm)
			return
		end

		-- If requester has no hash (nil), they have no data - send everything
		if not requesterHash then
			TOGBankClassic_Output:DebugComm("DELTA MODE: REQUESTER HAS NO DATA (hash=nil) - sending full data for %s", norm)
			TOGBankClassic_Output:Debug("SYNC", "Sending full data to %s for %s (requester has no data)", requester, norm)
			self:SendAltData(norm)
			return
		end

		if requesterHash == currentHash then
			-- Hashes match - no changes needed
			local noChangeMsg = {
				type = "no-change",
				name = norm,
				version = currentVersion,
				hash = currentHash,
			}
			local data = TOGBankClassic_Core:SerializeWithChecksum(noChangeMsg)
			TOGBankClassic_Output:DebugComm("DELTA MODE: SENDING NO-CHANGE to %s for %s (hash match: %d)", requester, norm, currentHash)
			if not TOGBankClassic_Core:SendWhisper("togbank-nochange", data, requester, "NORMAL") then
				return
			end
			TOGBankClassic_Output:Debug("SYNC", "Sent no-change reply to %s for %s (hash=%d)", requester, norm, currentHash)
			return
		else
			-- Hashes differ - send data
			TOGBankClassic_Output:DebugComm("DELTA MODE: HASH MISMATCH - calling SendAltData for %s (requester=%d, current=%d)", norm, requesterHash, currentHash)
			TOGBankClassic_Output:Debug(
				"SYNC",
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
		-- No changes - send no-change message
		local noChangeMsg = {
			type = "no-change",
			name = norm,
			version = currentVersion,
		}
		local data = TOGBankClassic_Core:SerializeWithChecksum(noChangeMsg)
		TOGBankClassic_Output:DebugComm("SENDING NO-CHANGE to %s for %s (version match)", requester, norm)
		if not TOGBankClassic_Core:SendWhisper("togbank-nochange", data, requester, "NORMAL") then
			return
		end
		TOGBankClassic_Output:Debug("SYNC", "Sent no-change reply to %s for %s (v%d)", requester, norm, currentVersion)
		return
	end

	-- Version mismatch - send full data
	TOGBankClassic_Output:Debug("SYNC", "Sending data to %s for %s (version mismatch: requester=%d, current=%d)", requester, norm, requesterVersion, currentVersion)
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

	-- Strip links from aggregate items (v0.8.0 new format)
	local strippedItems = self:StripItemLinks(alt.items)
	
	-- Also strip links from legacy bank/bags fields for backward compatibility
	-- Old clients can reconstruct links, new clients use alt.items
	local strippedBank = nil
	if alt.bank then
		strippedBank = {
			slots = alt.bank.slots,
			items = self:StripItemLinks(alt.bank.items)
		}
	end
	
	local strippedBags = nil
	if alt.bags then
		strippedBags = {
			slots = alt.bags.slots,
			items = self:StripItemLinks(alt.bags.items)
		}
	end

	local stripped = {
		version = alt.version,
		money = alt.money,
		inventoryHash = alt.inventoryHash,
		items = strippedItems,
		bank = strippedBank,
		bags = strippedBags,
		mail = alt.mail
	}
	return stripped
end

-- Strip Links from delta changes structure (v0.8.0 bandwidth optimization) - delegated to DeltaComms
function TOGBankClassic_Guild:StripDeltaLinks(delta)
	return TOGBankClassic_DeltaComms:StripDeltaLinks(delta)
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
					"DELTA",
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
					"DELTA",
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
				TOGBankClassic_Output:Debug("DELTA", "No changes detected for %s (delta would be empty)", norm)
			else
				TOGBankClassic_Output:Debug("DELTA", "No previous snapshot for %s (first sync)", norm)
			end
		end
	end

	-- Record compute time if delta was computed
	if deltaData and self.Info and self.Info.name then
		local computeTime = debugprofilestop() - computeStart
		TOGBankClassic_Database:RecordDeltaComputeTime(self.Info.name, computeTime)
		TOGBankClassic_Output:Debug("DELTA", "Delta computation took %.2fms", computeTime)
	end

	if useDelta then
		-- Send delta with dual-send for backwards compatibility (v0.8.0)
		local mode = PROTOCOL_MODES[FEATURES.PROTOCOL_MODE] or PROTOCOL_MODES.AUTO
		local deltaWithLinks, deltaNoLinks

		-- Prepare legacy format (with Links) if needed
		if mode.sendLegacy then
			deltaWithLinks = TOGBankClassic_Core:SerializeWithChecksum(deltaData)
			TOGBankClassic_Core:SendCommMessage("togbank-d2", deltaWithLinks, "Guild", nil, "BULK", OnChunkSent)
			TOGBankClassic_Output:Debug("DELTA", "Sent delta update for %s via togbank-d2 (with Links)", norm)
		end

		-- Prepare new format (without Links) if needed - saves 60-80 bytes per item
		if mode.sendNew then
			local strippedDelta = self:StripDeltaLinks(deltaData)
			deltaNoLinks = TOGBankClassic_Core:SerializeWithChecksum(strippedDelta)
			TOGBankClassic_Core:SendCommMessage("togbank-d4", deltaNoLinks, "Guild", nil, "BULK", OnChunkSent)
			TOGBankClassic_Output:Debug("DELTA", "Sent delta update for %s via togbank-d4 (no Links)", norm)

			-- Log bandwidth savings if dual-sending
			if mode.sendLegacy and deltaWithLinks then
				local savings = string.len(deltaWithLinks) - string.len(deltaNoLinks)
				TOGBankClassic_Output:Debug("DELTA", "Bandwidth saved: %d bytes (%.1f%%)", savings, (savings / string.len(deltaWithLinks)) * 100)
			end
		end

		-- Track metrics using the size of the format we're using (prefer new format)
		local serialized = deltaNoLinks or deltaWithLinks
		TOGBankClassic_Output:Debug("DELTA", "Final delta size: %d bytes", string.len(serialized or ""))

		-- Track metrics
		if self.Info and self.Info.name then
			TOGBankClassic_Database:RecordDeltaSent(self.Info.name, string.len(serialized or ""))
		end

		-- Save delta to history for potential chain replay (DELTA-006)
		-- v0.8.0: Use previous.version for baseVersion in history (delta no longer includes it)
		---@diagnostic disable-next-line: need-check-nil
		if self.Info and self.Info.name and deltaData.version and deltaData.changes then
			---@diagnostic disable-next-line: need-check-nil
			local previous = TOGBankClassic_Database:GetSnapshot(self.Info.name, norm)
			local baseVer = previous and previous.version or 0
			TOGBankClassic_Database:SaveDeltaHistory(
				---@diagnostic disable-next-line: need-check-nil
				self.Info.name,
				norm,
				baseVer,
				---@diagnostic disable-next-line: need-check-nil
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
				"SYNC",
				"Sent full sync for %s [%s]: togbank-d (%d bytes) + togbank-d3 (%d bytes, %.1f%% savings)",
				norm,
				FEATURES.PROTOCOL_MODE,
				string.len(dataWithLinks or ""),
				string.len(dataNoLinks or ""),
				100 - (string.len(dataNoLinks or "") / string.len(dataWithLinks or "") * 100)
			)
		elseif mode.sendLegacy then
			TOGBankClassic_Output:Debug(
				"SYNC",
				"Sent full sync for %s [LEGACY_ONLY]: togbank-d (%d bytes with Links)",
				norm,
				string.len(dataWithLinks or "")
			)
		elseif mode.sendNew then
			TOGBankClassic_Output:Debug(
				"SYNC",
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
		if not TOGBankClassic_Options:IsSyncProgressMuted() then
			TOGBankClassic_Output:Info("Sharing guild bank data: %d bytes in ~%d chunks...", totalBytes, totalChunks)
		end
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

		if not TOGBankClassic_Options:IsSyncProgressMuted() then
			TOGBankClassic_Output:Info(summary)
		end

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
	return TOGBankClassic_Performance:Track("ReceiveAltData", function()
		if not self.Info then
			return ADOPTION_STATUS.IGNORED
		end

		-- Sanitize incoming alt data
		local function sanitizeAlt(a)
			if not a or type(a) ~= "table" then
				return nil
			end
			
			-- Sanitize alt.items (array)
			if a.items then
				local cleaned = {}
				for k, v in pairs(a.items) do
					if v and type(v) == "table" and v.ID then
						table.insert(cleaned, v)
					end
				end
				a.items = cleaned
			end
			
			-- Sanitize bank items (array) - compact after removing invalids
			if a.bank and type(a.bank) == "table" and a.bank.items then
				local cleaned = {}
				for k, v in pairs(a.bank.items) do
					if v and type(v) == "table" and v.ID then
						table.insert(cleaned, v)
					end
				end
				a.bank.items = cleaned
			end
			
			-- Sanitize bag items (array) - compact after removing invalids
			if a.bags and type(a.bags) == "table" and a.bags.items then
				local cleaned = {}
				local beforeCount = 0
				local validCount = 0
				local invalidCount = 0
				for k, v in pairs(a.bags.items) do
					beforeCount = beforeCount + 1
					if v and type(v) == "table" and v.ID then
						table.insert(cleaned, v)
						validCount = validCount + 1
					else
						invalidCount = invalidCount + 1
						TOGBankClassic_Output:Debug("SYNC", "  Sanitize: invalid bag item at [%s]: v=%s, type=%s, ID=%s", 
							tostring(k), tostring(v), type(v), v and tostring(v.ID) or "nil")
					end
				end
				TOGBankClassic_Output:Debug("SYNC", "Sanitized bags: before=%d, valid=%d, invalid=%d", 
					beforeCount, validCount, invalidCount)
				a.bags.items = cleaned
			end
			
			return a
		end

		alt = sanitizeAlt(alt)
		if not alt then
			return ADOPTION_STATUS.INVALID
		end

		-- Debug: Log what we received
		local function countItems(items)
			if not items or type(items) ~= "table" then return 0 end
			local count = 0
			for _ in pairs(items) do count = count + 1 end
			return count
		end
		
		TOGBankClassic_Output:Debug("SYNC", "ReceiveAltData for %s: alt.items=%d, alt.bank.items=%d, alt.bags.items=%d", 
			name,
			countItems(alt.items),
			(alt.bank and alt.bank.items) and countItems(alt.bank.items) or 0,
			(alt.bags and alt.bags.items) and countItems(alt.bags.items) or 0)

		-- Backward compatibility: Compute alt.items from sources if missing (SYNC-006)
		-- This handles data from players who haven't rescanned after the aggregation update
		-- OLD STRUCTURE: Only bank and bags were synced (mail was local-only)
		
		-- Check if alt.items has any content (handles both array and key-value formats)
		local function hasAnyItems(items)
			if not items or type(items) ~= "table" then return false end
			return next(items) ~= nil
		end
		
		local needsReconstruction = not hasAnyItems(alt.items)
		
		if needsReconstruction then
			local bankItems = (alt.bank and alt.bank.items) or {}
			local bagItems = (alt.bags and alt.bags.items) or {}
			
			TOGBankClassic_Output:Debug("SYNC", "Reconstructing alt.items for %s: bank=%d, bags=%d", 
				name, #bankItems, #bagItems)
			
			-- Aggregate bank + bags ONLY (mail was never synced in old system)
			if #bankItems > 0 or #bagItems > 0 then
				local aggregated = TOGBankClassic_Item:Aggregate(bankItems, bagItems)
				alt.items = {}
				for _, item in pairs(aggregated) do
					table.insert(alt.items, item)
				end
				TOGBankClassic_Output:Debug("SYNC", "Reconstructed alt.items for %s: %d items from bank+bags", 
					name, #alt.items)
			else
				TOGBankClassic_Output:Debug("SYNC", "No items to reconstruct for %s (bank and bags both empty)", name)
			end
		else
			-- alt.items exists, ensure it's in array format (not key-value)
			local arrayItems = {}
			for _, item in pairs(alt.items) do
				table.insert(arrayItems, item)
			end
			alt.items = arrayItems
			TOGBankClassic_Output:Debug("SYNC", "alt.items exists for %s, converted to array format: %d items", 
				name, #alt.items)
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
			if a and a.items then
				for _, v in pairs(a.items) do
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

		if not self.Info.alts then
			self.Info.alts = {}
		end
		---@diagnostic disable-next-line: need-check-nil
		self.Info.alts[norm] = alt

		-- Reset search data flag so inventory UI rebuilds search index (UI-008 fix)
		if TOGBankClassic_UI_Inventory then
			TOGBankClassic_UI_Inventory.searchDataBuilt = false
		end

		-- Reconstruct Links for items (v0.8.0 bandwidth optimization)
		if alt.items then
			self:ReconstructItemLinks(alt.items)
		end

		-- Reset error count on successful full sync
		self:ResetDeltaErrorCount(norm)

		return ADOPTION_STATUS.ADOPTED
	end)
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
-- Delta protocol delegated to DeltaComms module (v0.7.0+)
function TOGBankClassic_Guild:ShouldUseDelta()
	return TOGBankClassic_DeltaComms:ShouldUseDelta()
end

-- Get peer protocol capabilities
function TOGBankClassic_Guild:GetPeerCapabilities(sender)
	return TOGBankClassic_DeltaComms:GetPeerCapabilities(self.Info and self.Info.name, sender)
end

-- Delta Computation Functions delegated to DeltaComms module (v0.7.0+)

-- Compare two items for equality
function TOGBankClassic_Guild:ItemsEqual(item1, item2)
	return TOGBankClassic_DeltaComms:ItemsEqual(item1, item2)
end

-- Extract only the fields that changed between two items
function TOGBankClassic_Guild:GetChangedFields(oldItem, newItem)
	return TOGBankClassic_DeltaComms:GetChangedFields(oldItem, newItem)
end

-- Build a slot-indexed lookup table from items array
function TOGBankClassic_Guild:BuildItemIndex(items)
	return TOGBankClassic_DeltaComms:BuildItemIndex(items)
end

-- Compute delta between old and new item sets
function TOGBankClassic_Guild:ComputeItemDelta(oldItems, newItems)
	return TOGBankClassic_DeltaComms:ComputeItemDelta(oldItems, newItems)
end

-- Compute full delta for an alt
function TOGBankClassic_Guild:ComputeDelta(name, currentAlt)
	return TOGBankClassic_DeltaComms:ComputeDelta(self.Info and self.Info.name, name, currentAlt)
end

-- Estimate serialized size of a data structure
function TOGBankClassic_Guild:EstimateSize(data)
	return TOGBankClassic_DeltaComms:EstimateSize(data)
end

-- Check if delta has any actual changes
function TOGBankClassic_Guild:DeltaHasChanges(delta)
	return TOGBankClassic_DeltaComms:DeltaHasChanges(delta)
end

-- Apply item delta to an items table
function TOGBankClassic_Guild:ApplyItemDelta(items, delta)
	return TOGBankClassic_DeltaComms:ApplyItemDelta(items, delta)
end

-- Apply a delta to alt data
function TOGBankClassic_Guild:ApplyDelta(name, deltaData, sender)
	return TOGBankClassic_DeltaComms:ApplyDelta(self.Info, name, deltaData, sender)
end

-- Request a chain of deltas to catch up from an old version (DELTA-006)
function TOGBankClassic_Guild:RequestDeltaChain(altName, fromVersion, toVersion, sender)
	return TOGBankClassic_DeltaComms:RequestDeltaChain(self.Info and self.Info.name, altName, fromVersion, toVersion, sender)
end

-- Apply a chain of deltas sequentially (DELTA-006)
function TOGBankClassic_Guild:ApplyDeltaChain(altName, deltaChain)
	return TOGBankClassic_DeltaComms:ApplyDeltaChain(self.Info, altName, deltaChain)
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
		if not info.roster then
			---@diagnostic disable-next-line: need-check-nil
			info.roster = {}
		end
		if info.roster then
			---@diagnostic disable-next-line: need-check-nil
			info.roster.alts = banks
			---@diagnostic disable-next-line: need-check-nil
			info.roster.version = GetServerTime()
			if not banks then
				---@diagnostic disable-next-line: need-check-nil
				info.roster.version = nil
			end
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