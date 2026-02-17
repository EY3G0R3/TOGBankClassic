
TOGBankClassic_Guild = {}

TOGBankClassic_Guild.Info = nil

-- Cache of online guild members (updated via GUILD_ROSTER_UPDATE)
-- Avoids stale data from GuildRoster() which only requests an update
TOGBankClassic_Guild.onlineMembers = {}

-- Cache of guild bankers (updated via GUILD_ROSTER_UPDATE)
-- Prevents iterating through entire guild roster on every IsBank() call
TOGBankClassic_Guild.banksCache = nil

-- Pending request tracking tables
TOGBankClassic_Guild.pendingAltRequests = {}
TOGBankClassic_Guild.pendingP2PRequests = {}
TOGBankClassic_Guild.lastAltQueryTime = {}
TOGBankClassic_Guild.bankerProgressKnown = {}

-- P2P send queue tracking (limit concurrent sends to prevent overwhelming chat throttle)
TOGBankClassic_Guild.pendingSendCount = 0
TOGBankClassic_Guild.MAX_PENDING_SENDS = 3

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

	-- Rebuild banker roster from guild notes after wipe
	self:RebuildBankerRoster()
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

	-- Update roster.alts list (roster sync is local-only, no version tracking needed)
	local oldRoster = table.concat(self.Info.roster.alts or {}, ",")
	local newRoster = table.concat(banks, ",")

	if oldRoster ~= newRoster then
		self.Info.roster.alts = banks
		TOGBankClassic_Output:Debug("ROSTER", "Rebuilt banker roster from guild notes: %d bankers", #banks)
	end

	-- Ensure local alt data exists for all roster bankers (authoritative roster cache)
	if not self.Info.alts then
		self.Info.alts = {}
	end
	for _, name in ipairs(banks) do
		local norm = self:NormalizeName(name)
		if norm and not self.Info.alts[norm] then
			self.Info.alts[norm] = {
				name = norm,
				version = 0,
				money = 0,
				inventoryHash = 0,
				items = {},
				mail = { items = {}, slots = { count = 0, total = 0 }, lastScan = 0, version = 0 },
				mailHash = 0,
			}
			self:EnsureLegacyFields(self.Info.alts[norm])
			TOGBankClassic_Output:Debug("ROSTER", "Added missing banker stub data for %s", norm)
		end
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

function TOGBankClassic_Guild:HasAltData(alt)
	if not alt or type(alt) ~= "table" then
		return false
	end
	if alt.version and alt.version > 0 then
		return true
	end
	if alt.inventoryHash and alt.inventoryHash > 0 then
		return true
	end
	if alt.items and #alt.items > 0 then
		return true
	end
	return false
end

function TOGBankClassic_Guild:HasAltContent(alt, altName)
	if not alt or type(alt) ~= "table" then
		TOGBankClassic_Output:Debug("DELTA", "[CONTENT-CHECK] %s: not a table", altName or (alt and alt.name) or "unknown")
		return false
	end
	
	local hasItems = alt.items and next(alt.items)
	local hasBankItems = alt.bank and alt.bank.items and next(alt.bank.items)
	local hasBagsItems = alt.bags and alt.bags.items and next(alt.bags.items)
	local hasMailItems = alt.mail and alt.mail.items and next(alt.mail.items)
	
	local result = hasItems or hasBankItems or hasBagsItems or hasMailItems
	
	TOGBankClassic_Output:Debug("DELTA", 
		"[CONTENT-CHECK] %s: items=%s, bank=%s, bags=%s, mail=%s => %s",
		altName or alt.name or "unknown",
		tostring(hasItems and "Y" or "N"),
		tostring(hasBankItems and "Y" or "N"),
		tostring(hasBagsItems and "Y" or "N"),
		tostring(hasMailItems and "Y" or "N"),
		tostring(result))
	
	return result
end

function TOGBankClassic_Guild:GetBankerDataProgress()
	if not self.Info then
		return 0, 0
	end

	local rosterAlts = self:GetRosterAlts()
	if not rosterAlts or #rosterAlts == 0 then
		rosterAlts = self:GetBanks()
	end
	if not rosterAlts or #rosterAlts == 0 then
		return 0, 0
	end

	local have = 0
	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		if norm and self:HasAltContent(self.Info.alts and self.Info.alts[norm], norm) then
			have = have + 1
		end
	end

	return have, #rosterAlts
end

function TOGBankClassic_Guild:ReportBankerDataProgress(context, force)
	if TOGBankClassic_Options and TOGBankClassic_Options.IsSyncProgressMuted and TOGBankClassic_Options:IsSyncProgressMuted() then
		return
	end

	local rosterAlts = self:GetRosterAlts()
	if not rosterAlts or #rosterAlts == 0 then
		rosterAlts = self:GetBanks()
	end
	if not rosterAlts or #rosterAlts == 0 then
		return
	end

	local have = 0
	local total = #rosterAlts
	local addedNames = {}
	self.bankerProgressKnown = self.bankerProgressKnown or {}
	local lastHave = self.lastBankerProgress or -1

	-- Reset completion tracking if roster size changes
	if self.lastBankerProgressTotal ~= total then
		self.lastBankerProgressTotal = total
		self.bankerProgressComplete = false
		self.bankerProgressKnown = {}
		lastHave = -1
		self.lastBankerProgress = lastHave
	end

	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		local hasContent = norm and self:HasAltContent(self.Info.alts and self.Info.alts[norm], norm)
		if hasContent then
			have = have + 1
			if lastHave >= 0 and not self.bankerProgressKnown[norm] then
				table.insert(addedNames, norm)
			end
			self.bankerProgressKnown[norm] = true
		else
			self.bankerProgressKnown[norm] = nil
		end
	end

	-- If already complete and previously at full, suppress further progress spam
	if have >= total then
		if self.lastBankerProgress == total then
			self.bankerProgressBuffer = {}
			return
		end
		self.bankerProgressComplete = true
	else
		self.bankerProgressComplete = false
	end

	-- Aggregate banker names added in the same tick
	self.bankerProgressBuffer = self.bankerProgressBuffer or {}
	if context and context:find("received ") then
		local name = context:gsub("^received ", "")
		table.insert(self.bankerProgressBuffer, name)
		context = nil
	end

	local lastHave = self.lastBankerProgress or -1
	if force or have ~= lastHave then
		self.lastBankerProgress = have
		local delta = (lastHave >= 0) and (have - lastHave) or 0
		local deltaStr = (delta and delta ~= 0) and string.format(" (+%d)", delta) or ""
		local names = ""
		if addedNames and #addedNames > 0 then
			names = " (received " .. table.concat(addedNames, ", ") .. ")"
			self.bankerProgressBuffer = {}
		elseif self.bankerProgressBuffer and #self.bankerProgressBuffer > 0 then
			names = " (received " .. table.concat(self.bankerProgressBuffer, ", ") .. ")"
			self.bankerProgressBuffer = {}
		elseif context then
			names = " (" .. context .. ")"
		end
		TOGBankClassic_Output:Info("Banker sync progress: %d/%d%s%s", have, total, deltaStr, names)
	end
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

function TOGBankClassic_Guild:BuildBankerHashList()
	local list = {}
	local rosterAlts = self:GetRosterAlts() or self:GetBanks() or {}
	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		if norm then
			local alt = self.Info and self.Info.alts and self.Info.alts[norm]
			local hash = (alt and alt.inventoryHash) or 0
			local updatedAt = (alt and (alt.inventoryUpdatedAt or alt.version)) or 0
			local version = (alt and alt.version) or 0
			local mailHash = (alt and alt.mailHash) or 0
			local mailUpdatedAt = (alt and alt.mail and alt.mail.version) or 0
			list[norm] = {
				hash = hash,
				updatedAt = updatedAt,
				version = version,
				mailHash = mailHash,
				mailUpdatedAt = mailUpdatedAt,
			}
		end
	end
	return list
end

function TOGBankClassic_Guild:ReportHashListCoverage()
	local rosterAlts = self:GetRosterAlts() or self:GetBanks() or {}
	local bankerList = self:BuildBankerHashList()
	local localAlts = self.Info and self.Info.alts or {}

	local matched = 0
	local pending = {}
	local matchedNoContent = {}
	for altName, summary in pairs(bankerList) do
		local localAlt = localAlts and localAlts[altName]
		local localHash = localAlt and localAlt.inventoryHash or 0
		if localAlt and localHash ~= 0 and summary and summary.hash == localHash then
			-- Hash matches, but check if we have actual content
			if not self:HasAltContent(localAlt, altName) then
				-- Hash matches but no content - treat as pending (need to request)
				table.insert(matchedNoContent, altName)
				table.insert(pending, altName)
			else
				-- Hash matches and we have content - truly matched
				matched = matched + 1
			end
		else
			-- Hash mismatch or no local data - pending
			table.insert(pending, altName)
		end
	end

	local rosterMissing = {}
	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		if norm and not bankerList[norm] then
			table.insert(rosterMissing, norm)
		end
	end

	table.sort(pending)
	table.sort(rosterMissing)

	local bankerCount = 0
	for _ in pairs(bankerList) do
		bankerCount = bankerCount + 1
	end

	local haveContent = 0
	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		local localAlt = localAlts and norm and localAlts[norm]
		if norm and self:HasAltContent(localAlt, norm) then
			haveContent = haveContent + 1
		end
	end

	TOGBankClassic_Output:Response(
		"Hash list coverage: banker=%d, matched=%d, pending=%d, rosterMissing=%d, haveContent=%d",
		bankerCount,
		matched,
		#pending,
		#rosterMissing,
		haveContent
	)

	local function printList(title, list)
		if #list == 0 then
			TOGBankClassic_Output:Response("%s: none", title)
			return
		end
		local cap = 20
		local count = math.min(#list, cap)
		local slice = {}
		for i = 1, count do
			slice[#slice + 1] = list[i]
		end
		local suffix = ""
		if #list > cap then
			suffix = string.format(" (showing %d of %d)", cap, #list)
		end
		TOGBankClassic_Output:Response("%s: %s%s", title, table.concat(slice, ", "), suffix)
	end

	printList("HLR pending", pending)
	printList("Hash matched but no content", matchedNoContent)
	printList("Missing from banker list", rosterMissing)
end

function TOGBankClassic_Guild:SendHashList(target)
	if not target then
		return
	end
	local normalizedTarget = self:NormalizeName(target)
	local list = self:BuildBankerHashList()
	local payload = {
		type = "hash-list-reply",
		alts = list,
		banker = self:GetNormalizedPlayer(),
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	local altCount = 0
	for _ in pairs(list) do
		altCount = altCount + 1
	end
	TOGBankClassic_Output:Debug(
		"PROTOCOL",
		"HLR send: target=%s (normalized=%s), alts=%d, bytes=%d",
		tostring(target),
		tostring(normalizedTarget),
		altCount,
		data and #data or 0
	)
	local sent = TOGBankClassic_Core:SendWhisper("togbank-hlr", data, normalizedTarget, "ALERT")
	TOGBankClassic_Output:Debug("PROTOCOL", "HLR send result: %s", tostring(sent))
end

function TOGBankClassic_Guild:RequestHashListFromBanker()
	-- Find an online banker from guild roster
	local banker = nil
	for member, _ in pairs(self.onlineMembers or {}) do
		if self:IsBank(member) and self:IsPlayerOnline(member) then
			banker = member
			break
		end
	end
	if not banker then
		-- No banker online: broadcast requests using local hashes when possible
		local rosterAlts = self:GetBanks()
		local pendingCount = 0
		if rosterAlts and #rosterAlts > 0 then
			for _, altName in ipairs(rosterAlts) do
				local norm = self:NormalizeName(altName)
				local localAlt = self.Info and self.Info.alts and norm and self.Info.alts[norm]
				local hasContent = localAlt and self:HasAltContent(localAlt, norm)
				if not hasContent then
					local localHash = localAlt and localAlt.inventoryHash or nil
					local updatedAt = localAlt and (localAlt.inventoryUpdatedAt or localAlt.version) or nil
					pendingCount = pendingCount + 1
					if localHash and localHash ~= 0 then
						-- We have hash but no content - broadcast P2P request WITH hash
						-- Peers with matching hash will respond (PERF-005 P2P protocol)
						TOGBankClassic_Output:Debug(
							"PROTOCOL",
							"HLR fallback: no banker online, broadcasting P2P for %s (expectedHash=%s, updatedAt=%s)",
							tostring(norm),
							tostring(localHash),
							tostring(updatedAt)
						)
						self:BroadcastP2PRequest(norm, localHash, updatedAt, nil)
					else
						-- No hash at all - regular query
						TOGBankClassic_Output:Debug(
							"PROTOCOL",
							"HLR fallback: no banker online, broadcasting query for %s (no local hash)",
							tostring(norm)
						)
						self:QueryAltPullBased(norm, false)
					end
				end
			end
		end
		if pendingCount > 0 then
			TOGBankClassic_Output:Info("Fast-fill: No banker online, broadcasting %d requests", pendingCount)
		end
		return false
	end

	local request = {
		type = "hash-list-request",
		requester = self:GetNormalizedPlayer(),
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(request)
	TOGBankClassic_Core:SendWhisper("togbank-hl", data, banker, "NORMAL")
	return true
end

function TOGBankClassic_Guild:BroadcastP2PRequest(altName, expectedHash, expectedUpdatedAt, bankerSender)
	if not altName or not expectedHash then
		return
	end
	
	-- Check if we already have this data with content - don't broadcast if we do
	local norm = self:NormalizeName(altName)
	local existing = self.Info and self.Info.alts and self.Info.alts[norm]
	if existing and self:HasAltContent(existing, norm) then
		TOGBankClassic_Output:Debug("SYNC", "PERF-005: Skipping P2P broadcast for %s (already have content)", altName)
		return
	end
	
	TOGBankClassic_Output:Debug(
		"PROTOCOL",
		"HLR broadcast: requesting %s (expectedHash=%s, updatedAt=%s) from banker=%s",
		tostring(altName),
		tostring(expectedHash),
		tostring(expectedUpdatedAt),
		tostring(bankerSender)
	)
	TOGBankClassic_Output:Info("P2P: Broadcasting request for %s with hash=%d (waiting for peers)", altName, expectedHash)
	
	self.expectedHashes = self.expectedHashes or {}
	self.expectedHashes[altName] = expectedHash
	if expectedUpdatedAt then
		self.expectedHashUpdatedAt = self.expectedHashUpdatedAt or {}
		self.expectedHashUpdatedAt[altName] = expectedUpdatedAt
	end
	self.pendingP2PRequests = self.pendingP2PRequests or {}
	self.pendingP2PRequests[altName] = { banker = bankerSender, requestedAt = GetTime() }

	-- MAIL-SYNC: Get requester's current mailHash to detect mail changes
	local ourAlt = self.Info and self.Info.alts and self.Info.alts[altName]
	local ourMailHash = (ourAlt and ourAlt.mailHash) or 0

	local p2pRequest = {
		type = "alt-request",
		name = altName,
		requester = self:GetNormalizedPlayer(),
		hashOnly = false,
		expectedHash = expectedHash,
		updatedAt = expectedUpdatedAt,
		requesterMailHash = ourMailHash,  -- MAIL-SYNC: Include mail hash
	}
	local p2pData = TOGBankClassic_Core:SerializeWithChecksum(p2pRequest)
	-- PERF-006: Use togbank-hl for P2P broadcasts so old code without hash support doesn't see them
	TOGBankClassic_Core:SendCommMessage("togbank-hl", p2pData, "GUILD", nil, "NORMAL")

	local timeout = (PEER_TO_PEER and PEER_TO_PEER.PEER_RESPONSE_TIMEOUT) or 5
	C_Timer.After(timeout, function()
		local pending = self.pendingP2PRequests and self.pendingP2PRequests[altName]
		if pending then
			self.pendingP2PRequests[altName] = nil
			-- PERF-006: Clear pendingAltRequests to allow banker fallback
			if self.pendingAltRequests then
				self.pendingAltRequests[altName] = nil
			end
			
			-- Check if we have any way to get this data
			local banker = pending.banker
			local bankerOnline = banker and self:IsPlayerOnline(banker)
			if bankerOnline then
				TOGBankClassic_Output:Debug("SYNC", "PERF-005: No P2P response for %s after %ds timeout, falling back to banker %s", altName, timeout, banker)
			else
				TOGBankClassic_Output:Debug("SYNC", "PERF-005: No P2P response for %s after %ds timeout, broadcasting to GUILD (no banker online)", altName, timeout)
			end
			self:QueryAltPullBased(altName, false)
		end
	end)
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

	-- Include request sync summary (version + hash) in version broadcasts.
	data.requests = {
		version = self:GetRequestsVersion(),
		hash = self:GetRequestsHash(),
	}

	for k, v in pairs(self.Info.alts) do
		---START CHANGES
		-- Only broadcast bankers from the CURRENT guild (cross-guild data leak fix)
		if self:IsBank(k) then
			-- P2P-007: Don't broadcast stub entries (hash but no content) - causes others to send empty deltas
			local hasContent = self:HasAltContent(v, k)
			if not hasContent then
				TOGBankClassic_Output:Debug("PROTOCOL", "GetVersion: excluding %s from version broadcast (stub entry - no content)", k)
			else
				-- Only store bank alt data if the sender is a bank alt
				--data.alts[k] = v.version
				-- v0.8.0: Include inventory hash for pull-based protocol
				if type(v) == "table" and v.version then
					-- Send hash only in delta-enabled mode (backwards compatibility)
					if PROTOCOL.SUPPORTS_DELTA and v.inventoryHash then
						data.alts[k] = {
							version = v.version,
							hash = v.inventoryHash,
							updatedAt = v.inventoryUpdatedAt or v.version,
						}
						TOGBankClassic_Output:Debug("PROTOCOL", "GetVersion: including %s in local version data (ver=%d, hash=%d)", k, v.version, v.inventoryHash)
					else
						-- Legacy format for old clients
						data.alts[k] = v.version
						TOGBankClassic_Output:Debug("PROTOCOL", "GetVersion: including %s in local version data (ver=%d, no hash)", k, v.version)
					end
				end
			end
		else
			TOGBankClassic_Output:Debug("PROTOCOL", "GetVersion: excluding %s from local version data (not a banker in current guild)", k)
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
function TOGBankClassic_Guild:QueryAltPullBased(name, hashOnly, forceFull, targetPlayer)
	if not name then
		return
	end

	local normName = self:NormalizeName(name)

	-- Log that we're sending a query
	TOGBankClassic_Output:Debug("PROTOCOL", "[QUERY] QueryAltPullBased called for %s (hashOnly=%s, target=%s)", normName, tostring(hashOnly or false), targetPlayer or "banker")

	-- Rate-limit repeated queries for the same alt to reduce stutter
	self.lastAltQueryTime = self.lastAltQueryTime or {}
	self.pendingAltRequests = self.pendingAltRequests or {}
	local now = GetTime()
	local pendingAt = self.pendingAltRequests[normName]
	if pendingAt and (now - pendingAt) < 10 then
		TOGBankClassic_Output:Debug("SYNC", "Skipping query for %s (pending request)", normName)
		return
	elseif pendingAt then
		self.pendingAltRequests[normName] = nil
	end
	local lastQuery = self.lastAltQueryTime[normName]
	if lastQuery and (now - lastQuery) < 3 then
		TOGBankClassic_Output:Debug("SYNC", "Skipping query for %s (rate-limited)", normName)
		return
	end
	self.lastAltQueryTime[normName] = now

	local norm = normName
	self.hasRequested = true
	if self.requestCount == nil then
		self.requestCount = 1
	else
		self.requestCount = self.requestCount + 1
	end

	-- Check if we have an online banker (from guild roster, not broadcasts)
	local banker = targetPlayer or nil
	local bankerCount = 0

	-- If no target specified, find a banker
	if not banker then
		-- MAIL-012 DEBUG: Log all online bankers from guild roster
		for member, _ in pairs(self.onlineMembers or {}) do
			if self:IsBank(member) then
				bankerCount = bankerCount + 1
				TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] Online banker from roster: %s, isOnline=%s",
					member, tostring(self:IsPlayerOnline(member)))
				-- Use first found banker (could randomize or prefer by name)
				if not banker then
					banker = member
				end
			end
		end
		-- Fallback: scan live guild roster if cache is stale
		if not banker then
			GuildRoster()
			for i = 1, GetNumGuildMembers() do
				local rosterName, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
				if rosterName and online then
					local normRoster = self:NormalizeName(rosterName)
					if self:IsBank(normRoster) then
						bankerCount = bankerCount + 1
						banker = banker or normRoster
						TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] Online banker from live roster: %s, isOnline=true", normRoster)
					end
				end
			end
		end
		TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] QueryAltPullBased for %s: %d online bankers found from guild roster", norm, bankerCount)
	else
		TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] QueryAltPullBased for %s: using target %s (P2P from version broadcast)", norm, banker)
	end

	-- Build request message
	local request = {
		type = "alt-request",  -- v0.8.0 pull-based request
		name = norm,
		requester = self:GetNormalizedPlayer(),
		hashOnly = hashOnly or false,  -- PERF-005: Request only hash for P2P distribution
	}

	-- DELTA-014: Include requester's current hashes (even for stubs!)
	-- P2P peers will respond ONLY if they have matching hash AND content
	local requesterAlt = self.Info and self.Info.alts and self.Info.alts[norm]
	if requesterAlt then
		-- Send the hash we have (from version broadcast or actual data)
		request.requesterInventoryHash = requesterAlt.inventoryHash or 0
		request.requesterMailHash = requesterAlt.mailHash or 0
		local hasContent = self:HasAltContent(requesterAlt, norm)
		-- P2P-006: Tell sender if we have content - if not, they should send full data
		request.requesterHasContent = hasContent
		TOGBankClassic_Output:Debug("DELTA", "[DELTA-014] QueryAltPullBased for %s: requester invHash=%d, mailHash=%d, hasContent=%s",
			norm, request.requesterInventoryHash, request.requesterMailHash, tostring(hasContent))
	else
		-- No local data at all - send hash=0
		request.requesterInventoryHash = 0
		request.requesterMailHash = 0
		request.requesterHasContent = false
		TOGBankClassic_Output:Debug("DELTA", "[DELTA-014] QueryAltPullBased for %s: requester invHash=0 (no local entry)", norm)
	end

	local data = TOGBankClassic_Core:SerializeWithChecksum(request)
	
	-- QueryAltPullBased is "last resort" - WHISPER banker directly if online, GUILD broadcast if not
	-- (P2P guild broadcast should be done via BroadcastP2PRequest first)
	if not banker then
		-- No banker found in roster - broadcast to GUILD hoping someone has data
		TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] QueryAltPullBased for %s: no banker found, broadcasting to GUILD", norm)
		TOGBankClassic_Output:DebugComm("SENDING GUILD BROADCAST (no banker): togbank-r for alt %s", norm)
		TOGBankClassic_Core:SendCommMessage("togbank-r", data, "GUILD", nil, "NORMAL")
		self:MarkPendingSync("alt", "guild", norm)
		self.pendingAltRequests[norm] = now
		return
	end
	
	if not self:IsPlayerOnline(banker) then
		-- Banker exists but offline - broadcast to GUILD hoping someone else has data
		TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] QueryAltPullBased for %s: banker %s offline, broadcasting to GUILD", norm, banker)
		TOGBankClassic_Output:DebugComm("SENDING GUILD BROADCAST (banker offline): togbank-r for alt %s", norm)
		TOGBankClassic_Core:SendCommMessage("togbank-r", data, "GUILD", nil, "NORMAL")
		self:MarkPendingSync("alt", "guild", norm)
		self.pendingAltRequests[norm] = now
		return
	end
	
	-- WHISPER banker as last resort (banker confirmed online)
	TOGBankClassic_Output:DebugComm("SENDING WHISPER (last resort): togbank-r to %s for alt %s", banker, norm)
	TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] WHISPER query for %s to banker %s (last resort after P2P timeout)", norm, banker)
	
	if not TOGBankClassic_Core:SendWhisper("togbank-r", data, banker, "NORMAL") then
		TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] WHISPER query failed for %s to %s", norm, banker)
		return
	end
	
	self:MarkPendingSync("alt", banker, norm)
	self.pendingAltRequests[norm] = now
end

-- DEPRECATED: Roster sync no longer uses network communication
-- Each player rebuilds roster locally from guild notes on GUILD_ROSTER_UPDATE
function TOGBankClassic_Guild:SendRosterData()
	-- Only send roster if config option is enabled (for guilds with officer-note-only gbank identification)
	if not TOGBankClassic_Options or not TOGBankClassic_Options:IsRosterSyncEnabled() then
		TOGBankClassic_Output:Debug("ROSTER", "SendRosterData skipped - roster sync disabled in config")
		return
	end

	if not self.Info or not self.Info.roster or not self.Info.roster.alts then
		TOGBankClassic_Output:Debug("ROSTER", "SendRosterData skipped - no roster data available")
		return
	end

	local data = TOGBankClassic_Core:EncodeJSON({
		roster = {
			alts = self.Info.roster.alts,
			version = self.Info.roster.version or GetServerTime()
		}
	})

	TOGBankClassic_Output:Debug("ROSTER", "Broadcasting roster with %d bankers", #self.Info.roster.alts)
	TOGBankClassic_Core:SendCommMessage("togbank-roster", data, "GUILD", nil, "NORMAL")
end

-- Receive roster broadcast from banker/officer (only if roster sync enabled)
function TOGBankClassic_Guild:ReceiveRosterData(sender, roster)
	-- Only accept roster if config option is enabled
	if not TOGBankClassic_Options or not TOGBankClassic_Options:IsRosterSyncEnabled() then
		TOGBankClassic_Output:Debug("ROSTER", "ReceiveRosterData ignored - roster sync disabled in config")
		return
	end

	if not roster or not roster.alts then
		TOGBankClassic_Output:Debug("ROSTER", "ReceiveRosterData ignored - invalid roster data")
		return
	end

	-- Verify sender has gbank note or can view officer notes
	if not self:SenderHasGbankNote(sender) and not CanViewOfficerNote() then
		TOGBankClassic_Output:Debug("ROSTER", "ReceiveRosterData ignored - sender %s not authorized", sender or "unknown")
		return
	end

	-- Only accept if we don't have a roster or received roster is newer
	local currentVersion = (self.Info and self.Info.roster and self.Info.roster.version) or 0
	local receivedVersion = roster.version or 0

	if receivedVersion > currentVersion then
		if not self.Info.roster then
			self.Info.roster = {}
		end
		self.Info.roster.alts = roster.alts
		self.Info.roster.version = receivedVersion
		TOGBankClassic_Output:Debug("ROSTER", "Received roster update from %s with %d bankers", sender, #roster.alts)

		-- Ensure local alt data exists for all roster bankers
		if not self.Info.alts then
			self.Info.alts = {}
		end
		for _, name in ipairs(roster.alts) do
			local norm = self:NormalizeName(name)
			if norm and not self.Info.alts[norm] then
				self.Info.alts[norm] = {
					name = norm,
					version = 0,
					money = 0,
					inventoryHash = 0,
					items = {},
					mail = { items = {}, slots = { count = 0, total = 0 }, lastScan = 0, version = 0 },
					mailHash = 0,
				}
				self:EnsureLegacyFields(self.Info.alts[norm])
			end
		end
	else
		TOGBankClassic_Output:Debug("ROSTER", "Ignored roster from %s - not newer than current (received: %d, current: %d)",
			sender, receivedVersion, currentVersion)
	end
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

-- Update a single member's online state (from CHAT_MSG_SYSTEM)
function TOGBankClassic_Guild:UpdateOnlineMember(memberName, isOnline)
	if not memberName then
		return
	end
	self.onlineMembers = self.onlineMembers or {}
	local normalized = self:NormalizeName(memberName)
	if not normalized then
		return
	end
	if isOnline then
		self.onlineMembers[normalized] = true
	else
		self.onlineMembers[normalized] = nil
	end
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
		updatedAt = alt.inventoryUpdatedAt or alt.version or 0,
		mailHash = alt.mailHash or 0,  -- MAIL-SYNC: Include mail hash for mail change detection
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
function TOGBankClassic_Guild:SendStateSummary(name, target, forceFullParam)
	TOGBankClassic_Output:DebugComm("SendStateSummary CALLED: name=%s, target=%s, forceFull=%s", tostring(name), tostring(target), tostring(forceFullParam))
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

	local norm = self:NormalizeName(name)
	local forceFull = forceFullParam or (self.forceFullRequests and norm and self.forceFullRequests[norm])
	local localAlt = self.Info and self.Info.alts and norm and self.Info.alts[norm]
	local hasContent = localAlt and self:HasAltContent(localAlt, norm) or false
	if forceFull or not hasContent then
		-- PERF-006: Set hash=0 (not nil) to force full data from responder
		-- If we set hash=nil and responder also has hash=nil (old code), they'll match and send NO-CHANGE
		summary.hash = 0
		summary.version = 0
		TOGBankClassic_Output:DebugComm(
			"SendStateSummary: forcing full data for %s (forceFull=%s, hasContent=%s)",
			tostring(name),
			tostring(forceFull and true or false),
			tostring(hasContent)
		)
		if self.forceFullRequests and norm then
			self.forceFullRequests[norm] = nil
		end
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
	if currentAlt and not currentAlt.inventoryUpdatedAt and currentAlt.version then
		currentAlt.inventoryUpdatedAt = currentAlt.version
	end
	local requesterVersion = summary.version or 0
	local currentVersion = currentAlt.version or 0

	-- v0.8.0: In delta mode, compare HASHES not versions
	local requesterHash = summary.hash or nil
	local currentHash = currentAlt.inventoryHash or nil

	-- Extract mail hashes for comparison
	local requesterMailHash = summary.mailHash or 0
	local currentMailHash = currentAlt.mailHash or 0
	
	TOGBankClassic_Output:DebugComm("RespondToStateSummary: %s requesterV=%d currentV=%d requesterHash=%s currentHash=%s requesterMailHash=%s currentMailHash=%s", norm, requesterVersion, currentVersion, tostring(requesterHash), tostring(currentHash), tostring(requesterMailHash), tostring(currentMailHash))

	-- v0.8.0: Delta mode - ONLY use hashes, no version fallback
	if self:ShouldUseDelta() then
		-- If current alt doesn't have a hash, send full data (might be from pre-hash version)
		if not currentHash then
			TOGBankClassic_Output:DebugComm("DELTA MODE: Current alt missing hash - sending full data for %s", norm)
			TOGBankClassic_Output:Debug("SYNC", "Sending full data to %s for %s (responder has no hash)", requester, norm)
			-- DELTA-014: Pass zero hashes (requester baseline unknown, send everything)
			self:SendAltData(norm, 0, 0, requester)
			return
		end

		-- If requester has no hash (nil), they have no data - send everything
		if not requesterHash then
			TOGBankClassic_Output:DebugComm("DELTA MODE: REQUESTER HAS NO DATA (hash=nil) - sending full data for %s", norm)
			TOGBankClassic_Output:Debug("SYNC", "Sending full data to %s for %s (requester has no data)", requester, norm)
			-- DELTA-014: Pass zero hashes (requester has no data, everything is new)
			self:SendAltData(norm, 0, 0, requester)
			return
		end

		-- Check both inventory and mail hashes
		if requesterHash == currentHash and requesterMailHash == currentMailHash then
			-- Both hashes match - no changes needed
			local noChangeMsg = {
				type = "no-change",
				name = norm,
				version = currentVersion,
				hash = currentHash,
				mailHash = currentMailHash,
			}
			local data = TOGBankClassic_Core:SerializeWithChecksum(noChangeMsg)
			TOGBankClassic_Output:DebugComm("DELTA MODE: SENDING NO-CHANGE to %s for %s (hash match: inv=%d, mail=%d)", requester, norm, currentHash, currentMailHash)
			if not TOGBankClassic_Core:SendWhisper("togbank-nochange", data, requester, "NORMAL") then
				return
			end
			TOGBankClassic_Output:Debug("SYNC", "Sent no-change reply to %s for %s (hash=%d, mailHash=%d)", requester, norm, currentHash, currentMailHash)
			return
		elseif requesterHash == currentHash and requesterMailHash ~= currentMailHash then
			-- Only mail changed - send mail-only delta
			TOGBankClassic_Output:DebugComm("DELTA MODE: MAIL-ONLY CHANGE - calling SendAltData for %s (mail: requester=%d, current=%d)", norm, requesterMailHash, currentMailHash)
			TOGBankClassic_Output:Debug(
				"SYNC",
				"Sending data to %s for %s (mail-only change: requester=%d, current=%d)",
				requester,
				norm,
				requesterMailHash,
				currentMailHash
			)
			-- DELTA-014: Pass requester hashes to compute proper delta (inventory unchanged)
			self:SendAltData(norm, requesterHash, requesterMailHash, requester)
			return
		else
			-- Inventory changed (mail may or may not have changed) - send delta
			TOGBankClassic_Output:DebugComm("DELTA MODE: INVENTORY CHANGE - calling SendAltData for %s (inv: requester=%d, current=%d, mail: requester=%d, current=%d)", norm, requesterHash, currentHash, requesterMailHash, currentMailHash)
			TOGBankClassic_Output:Debug(
				"SYNC",
				"Sending data to %s for %s (hash mismatch: inv=%d->%d, mail=%d->%d)",
				requester,
				norm,
				requesterHash,
				currentHash,
				requesterMailHash,
				currentMailHash
			)
			-- DELTA-014: Pass requester hashes to compute proper delta
			self:SendAltData(norm, requesterHash, requesterMailHash, requester)
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
	-- DELTA-014: Legacy mode doesn't use hashes, pass zeros
	self:SendAltData(norm, 0, 0, requester)
end

-- Strip Link fields from items for transmission (v0.8.0 bandwidth optimization)
-- Saves 60-80 bytes per item, receiver reconstructs with GetItemInfo()
function TOGBankClassic_Guild:StripItemLinks(items)
	if not items then
		return nil
	end

	local stripped = {}
	for _, item in ipairs(items) do
		local strippedItem = {
			ID = item.ID,
			Count = item.Count
			-- Link removed - receiver will reconstruct
		}

		local forceLink = item.ForceLink == true

		-- Preserve itemString for items with unique stats (suffixes, enchants, etc.)
		-- Extract from Link if available: |Hitem:itemString|h[Name]|h
		if item.Link then
			if forceLink or (TOGBankClassic_Item and TOGBankClassic_Item.NeedsLink and TOGBankClassic_Item:NeedsLink(item.Link)) then
				-- Preserve full link for forced/gear/uncached items
				strippedItem.Link = item.Link
			else
				local itemString = string.match(item.Link, "item:([^|]+)")
				if itemString then
					strippedItem.ItemString = itemString
				end
			end
		elseif item.ItemString then
			strippedItem.ItemString = item.ItemString
		end

		table.insert(stripped, strippedItem)
	end
	return stripped
end

-- Reconstruct Link fields after receiving data (v0.8.0)
-- Calls GetItemInfo() to recreate links from ItemID or ItemString
-- Throttle UI refreshes to prevent stuttering when many items load async
local lastUIRefresh = 0
local function ThrottledUIRefresh()
	local now = GetTime()
	if now - lastUIRefresh < 0.5 then -- Throttle to max once per 0.5 seconds
		return
	end
	lastUIRefresh = now

	-- Only refresh if UI is actually open
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
		TOGBankClassic_UI_Inventory:DrawContent()
	end
	if TOGBankClassic_UI_Search and TOGBankClassic_UI_Search.isOpen then
		TOGBankClassic_UI_Search:DrawContent()
	end
end

-- Queue system for batched item reconstruction
local itemReconstructQueue = {}
local isProcessingQueue = false
local pendingAsyncLoads = 0  -- Track number of pending async loads
local MAX_CONCURRENT_ASYNC = 3  -- Limit concurrent async operations
local BATCH_SIZE = 10  -- Process 10 items at a time
local BATCH_DELAY = 0.2  -- 0.2 second delay between batches (slower = smoother)

local function ProcessItemQueue()
	if #itemReconstructQueue == 0 then
		isProcessingQueue = false
		return
	end

	-- Process a batch of items
	local processCount = math.min(BATCH_SIZE, #itemReconstructQueue)
	local loadedAnyInBatch = false

	for i = 1, processCount do
		local item = table.remove(itemReconstructQueue, 1)
		if item and item.ID and not item.Link then
			-- Skip obviously corrupted items (IDs < 100 are not valid WoW items)
			if item.ID >= 100 then
				-- If we have an ItemString, use it to reconstruct full link
				if item.ItemString then
				local itemName = GetItemInfo(item.ID)
				if itemName then
					item.Link = string.format("|cffffffff|Hitem:%s|h[%s]|h|r", item.ItemString, itemName)
					loadedAnyInBatch = true
				else
					-- Item not in cache - only start async if under limit
					if pendingAsyncLoads < MAX_CONCURRENT_ASYNC then
						pendingAsyncLoads = pendingAsyncLoads + 1
						local itemObj = Item:CreateFromItemID(item.ID)

						-- Debug: Check itemObj state
						TOGBankClassic_Output:Debug("ITEM", "[GUILD] ItemString Item %d: itemObj=%s, itemObj.itemID=%s",
							item.ID or -1,
							tostring(itemObj),
							itemObj and tostring(itemObj.itemID) or "nil")

						if itemObj and itemObj.itemID and itemObj.itemID == item.ID then
							-- Item object is valid, try ContinueOnItemLoad with error protection
							TOGBankClassic_Output:Debug("ITEM", "[GUILD] ItemString Item %d PASSED validation, calling ContinueOnItemLoad", item.ID)
							local success, err = pcall(function()
								itemObj:ContinueOnItemLoad(function()
									pendingAsyncLoads = pendingAsyncLoads - 1
									local name = itemObj:GetItemName()
									if name then
										item.Link = string.format("|cffffffff|Hitem:%s|h[%s]|h|r", item.ItemString, name)
										ThrottledUIRefresh()
									end
								end)
							end)
							if not success then
								TOGBankClassic_Output:Debug("ITEM", "[GUILD] ContinueOnItemLoad crashed for ItemString item %d: %s", item.ID, tostring(err))
								pendingAsyncLoads = pendingAsyncLoads - 1
							end
						else
							-- Item object is nil or corrupted, skip
							TOGBankClassic_Output:Debug("ITEM", "[GUILD] ItemString Item %d FAILED validation, skipping", item.ID or -1)
							pendingAsyncLoads = pendingAsyncLoads - 1
						end
					else
						-- Too many pending, requeue for later
						table.insert(itemReconstructQueue, item)
					end
				end
			else
				-- No ItemString, fall back to basic ID-only link
				local itemLink = select(2, GetItemInfo(item.ID))
				if itemLink then
					item.Link = itemLink
					loadedAnyInBatch = true
				else
					-- Item not in cache - only start async if under limit
					if pendingAsyncLoads < MAX_CONCURRENT_ASYNC then
						pendingAsyncLoads = pendingAsyncLoads + 1
						local itemObj = Item:CreateFromItemID(item.ID)

						-- Debug: Check itemObj state
						TOGBankClassic_Output:Debug("ITEM", "[GUILD] Item %d: itemObj=%s, itemObj.itemID=%s",
							item.ID or -1,
							tostring(itemObj),
							itemObj and tostring(itemObj.itemID) or "nil")

						if itemObj and itemObj.itemID and itemObj.itemID == item.ID then
							-- Item object is valid, try ContinueOnItemLoad with error protection
							TOGBankClassic_Output:Debug("ITEM", "[GUILD] Item %d PASSED validation, calling ContinueOnItemLoad", item.ID)
							local success, err = pcall(function()
								itemObj:ContinueOnItemLoad(function()
									pendingAsyncLoads = pendingAsyncLoads - 1
									local link = itemObj:GetItemLink()
									if link then
										item.Link = link
										ThrottledUIRefresh()
									end
								end)
							end)
							if not success then
								TOGBankClassic_Output:Debug("ITEM", "[GUILD] ContinueOnItemLoad crashed for item %d: %s", item.ID, tostring(err))
								pendingAsyncLoads = pendingAsyncLoads - 1
							end
						else
							-- Item object is nil or corrupted, skip
							TOGBankClassic_Output:Debug("ITEM", "[GUILD] Item %d FAILED validation, skipping", item.ID or -1)
							pendingAsyncLoads = pendingAsyncLoads - 1
						end
					else
						-- Too many pending, requeue for later
						table.insert(itemReconstructQueue, item)
					end
				end
			end
			end  -- End of if item.ID >= 100
		end
	end

	-- Refresh UI if any items loaded synchronously in this batch
	if loadedAnyInBatch then
		ThrottledUIRefresh()
	end

	-- Schedule next batch
	if #itemReconstructQueue > 0 then
		C_Timer.After(BATCH_DELAY, ProcessItemQueue)
	else
		isProcessingQueue = false
	end
end

-- Reconstruct single item link (immediate, synchronous only)
function TOGBankClassic_Guild:ReconstructItemLink(item)
	if not item or not item.ID or item.Link then
		return
	end

	-- Try synchronous reconstruction from cache only
	if item.ItemString then
		local itemName = GetItemInfo(item.ID)
		if itemName then
			item.Link = string.format("|cffffffff|Hitem:%s|h[%s]|h|r", item.ItemString, itemName)
		end
	else
		local itemLink = select(2, GetItemInfo(item.ID))
		if itemLink then
			item.Link = itemLink
		end
	end
	-- Note: If not in cache, link stays nil - will be reconstructed by queue
end

-- Reconstruct item links from ItemStrings - queued/batched to prevent stuttering
function TOGBankClassic_Guild:ReconstructItemLinks(items)
	if not items then
		return
	end

	-- Add all items without links to queue for async loading
	-- Items already in cache will load synchronously and won't need async
	for _, item in ipairs(items) do
		if item and item.ID and not item.Link then
			table.insert(itemReconstructQueue, item)
		end
	end

	-- Start processing queue if not already running
	if not isProcessingQueue and #itemReconstructQueue > 0 then
		isProcessingQueue = true
		ProcessItemQueue()
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

	-- MAIL-SYNC: Strip mail links for bandwidth optimization
	local strippedMail = nil
	if alt.mail then
		strippedMail = {
			slots = alt.mail.slots,
			items = self:StripItemLinks(alt.mail.items),
			version = alt.mail.version,
			lastScan = alt.mail.lastScan
		}
	end

	local stripped = {
		version = alt.version,
		money = alt.money,
		inventoryHash = alt.inventoryHash,
		inventoryUpdatedAt = alt.inventoryUpdatedAt or alt.version,
		items = strippedItems,
		bank = strippedBank,
		bags = strippedBags,
		mail = strippedMail,  -- MAIL-SYNC: Include stripped mail
		mailHash = alt.mailHash
	}
	return stripped
end

-- Strip Links from delta changes structure (v0.8.0 bandwidth optimization) - delegated to DeltaComms
function TOGBankClassic_Guild:StripDeltaLinks(delta)
	return TOGBankClassic_DeltaComms:StripDeltaLinks(delta)
end

-- Ensure legacy fields (bank.items, bags.items) exist for backward compatibility with old clients
-- New clients (v0.8.0+) use alt.items, but old clients need bank.items and bags.items
-- IMPORTANT: This also ensures mail items are included in legacy fields for old clients
function TOGBankClassic_Guild:EnsureLegacyFields(alt)
	if not alt or not alt.items then
		return alt
	end

	-- Check if we have mail items that need to be added to legacy fields
	local hasMailItems = alt.mail and alt.mail.items and next(alt.mail.items)

	-- If no legacy fields exist, reconstruct from alt.items
	if not alt.bank or not alt.bank.items then
		TOGBankClassic_Output:Debug("SYNC", "Reconstructing legacy fields from alt.items for %s", alt.name or "unknown")

		if not alt.bank then
			alt.bank = {}
		end
		alt.bank.items = {}
		-- Copy all items from alt.items to bank.items (includes mail)
		for _, item in ipairs(alt.items) do
			table.insert(alt.bank.items, item)
		end

		if not alt.bags then
			alt.bags = {}
		end
		if not alt.bags.items then
			alt.bags.items = {}
		end

		return alt
	end

	-- Legacy fields exist (from Bank.lua scan), but they don't include mail
	-- MAIL-008: DO NOT modify alt.bank.items directly - it corrupts the data!
	-- Old clients will see mail items via alt.mail field, or can aggregate themselves
	-- If needed, create temporary copies with mail included only for transmission

	-- Ensure bags.items exists (even if empty)
	if not alt.bags then
		alt.bags = {}
	end
	if not alt.bags.items then
		alt.bags.items = {}
	end

	return alt
end

function TOGBankClassic_Guild:SendAltData(name, requesterInventoryHash, requesterMailHash, target)
	if not name then
		return
	end
	local norm = self:NormalizeName(name)
	if not self.Info or not self.Info.alts or not self.Info.alts[norm] then
		return
	end

	-- Determine distribution channel: WHISPER to target if provided, otherwise GUILD broadcast
	local distribution = "GUILD"
	local distTarget = nil
	if target then
		distribution = "WHISPER"
		distTarget = target
		TOGBankClassic_Output:Debug("PROTOCOL", "[RESPONSE] Sending %s data via WHISPER to %s (pull-based response)", norm, target)
	else
		TOGBankClassic_Output:Debug("PROTOCOL", "[RESPONSE] Sending %s data via GUILD broadcast (manual share)", norm)
	end

	-- v0.8.0: Version is ONLY set by Bank:Scan() when inventory actually changes
	-- No longer bump version here - that caused version drift from communication

	local currentAlt = self.Info.alts[norm]

	-- Ensure legacy fields exist for backward compatibility with old clients
	-- This ensures old clients that only read bank.items/bags.items still get data
	self:EnsureLegacyFields(currentAlt)  -- Modifies in place, no need to reassign

	-- [MAIL-012] Log mailHash before sending to verify it's in the alt object
	TOGBankClassic_Output:Debug("SYNC", "[MAIL-012] SendAltData for %s: mailHash=%s", norm, tostring(currentAlt.mailHash))

	-- Log what we're about to send (all 3 arrays for backward compatibility)
	local itemsCount = currentAlt.items and #currentAlt.items or 0
	local bankCount = (currentAlt.bank and currentAlt.bank.items) and #currentAlt.bank.items or 0
	local bagsCount = (currentAlt.bags and currentAlt.bags.items) and #currentAlt.bags.items or 0
	TOGBankClassic_Output:Debug("SYNC", "Sending %s: alt.items=%d, alt.bank.items=%d (includes mail), alt.bags.items=%d",
		norm, itemsCount, bankCount, bagsCount)

	-- DEBUG: Log sample counts from what we're about to send
	if currentAlt.items and #currentAlt.items > 0 then
		local sampleItems = {}
		for i = 1, math.min(5, #currentAlt.items) do
			local item = currentAlt.items[i]
			if item then
				table.insert(sampleItems, string.format("%s:%d", item.ID or "?", item.Count or 0))
			end
		end
		TOGBankClassic_Output:Debug("SYNC", "First 5 items in alt.items being sent: %s", table.concat(sampleItems, ", "))
	end

	local useDelta = false
	local deltaData = nil
	local computeStart = debugprofilestop()

	-- DELTA-ONLY: All syncs use delta protocol, no full sync fallback
	-- DELTA-014: Pass requester's hashes for proper baseline comparison
	if not self:ShouldUseDelta() then
		TOGBankClassic_Output:Error("Delta protocol disabled - cannot send data for %s", norm)
		return
	end

	deltaData = self:ComputeDelta(norm, currentAlt, requesterInventoryHash, requesterMailHash)
	
	if not deltaData then
		TOGBankClassic_Output:Error("Failed to compute delta for %s", norm)
		return
	end

	if not self:DeltaHasChanges(deltaData) then
		-- No changes detected - skip send (requester already has current data)
		TOGBankClassic_Output:Debug("DELTA", "No changes detected for %s (requester has current data, skipping send)", norm)
		return
	end

	-- Delta has changes - send it
	local deltaSize = self:EstimateSize(deltaData)
	local fullSize = self:EstimateSize({ type = "alt", name = norm, alt = currentAlt })
	useDelta = true
	TOGBankClassic_Output:Debug(
		"DELTA",
		"✓ Delta for %s: %d bytes vs %d bytes full (%.1f%% size, %.0f bytes saved)",
		 norm,
		deltaSize,
		fullSize,
		(deltaSize / fullSize) * 100,
		fullSize - deltaSize
	)

	-- Record compute time if delta was computed
	if deltaData and self.Info and self.Info.name then
		local computeTime = debugprofilestop() - computeStart
		TOGBankClassic_Database:RecordDeltaComputeTime(self.Info.name, computeTime)
		TOGBankClassic_Output:Debug("DELTA", "Delta computation took %.2fms", computeTime)
	end

	-- DELTA-ONLY: Send via togbank-d4 (no legacy channels)
	local strippedDelta = self:StripDeltaLinks(deltaData)
	local deltaNoLinks = TOGBankClassic_Core:SerializeWithChecksum(strippedDelta)
	TOGBankClassic_Core:SendCommMessage("togbank-d4", deltaNoLinks, distribution, distTarget, "BULK", OnChunkSent)
	TOGBankClassic_Output:Debug("DELTA", "Sent delta update for %s via togbank-d4 to %s (%d bytes)", norm, distribution, string.len(deltaNoLinks))

	-- Track metrics
	local totalSize = string.len(deltaNoLinks)
	TOGBankClassic_Output:Debug("DELTA", "Final delta size: %d bytes", totalSize)

	if self.Info and self.Info.name then
		TOGBankClassic_Database:RecordDeltaSent(self.Info.name, totalSize)
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

		-- Decrement P2P send queue counter
		if TOGBankClassic_Guild.pendingSendCount > 0 then
			TOGBankClassic_Guild.pendingSendCount = TOGBankClassic_Guild.pendingSendCount - 1
			TOGBankClassic_Output:Debug("SYNC", "P2P send completed - queue now: %d/%d", 
				TOGBankClassic_Guild.pendingSendCount, TOGBankClassic_Guild.MAX_PENDING_SENDS)
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

function TOGBankClassic_Guild:ReceiveAltData(name, alt, sender)
	return TOGBankClassic_Performance:Track("ReceiveAltData", function()
		if not self.Info then
			return ADOPTION_STATUS.IGNORED
		end

		-- PERF-005: Validate hash if we have an expected hash for this alt
		-- PROTO-002: Defensive nil check for PEER_TO_PEER constant
		if PEER_TO_PEER and PEER_TO_PEER.ENABLED and self.expectedHashes and self.expectedHashes[name] then
			local expectedHash = self.expectedHashes[name]
			local receivedHash = alt.inventoryHash or 0

			if receivedHash ~= expectedHash then
				TOGBankClassic_Output:Debug("SYNC", "PERF-005: Hash mismatch for %s from %s! Expected=%d, Got=%d - rejecting",
					name, sender, expectedHash, receivedHash)
				-- Don't clear expected hash - let timeout handle fallback to banker
				return ADOPTION_STATUS.INVALID
			else
				TOGBankClassic_Output:Debug("SYNC", "PERF-005: Hash validated for %s from %s (hash=%d)",
					name, sender, receivedHash)
				-- Clear expected hash after successful validation
				self.expectedHashes[name] = nil
			end
		end

		-- Sanitize incoming alt data
		local function sanitizeAlt(a)
			if not a or type(a) ~= "table" then
				return nil
			end

			-- [MAIL-012] Log mailHash IMMEDIATELY upon receiving alt data
			TOGBankClassic_Output:Debug("SYNC", "[MAIL-012] ReceiveAltData for %s: received mailHash=%s", name, tostring(a.mailHash))
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
			-- alt.items exists, deduplicate and ensure array format
			-- Items may have duplicates from corrupted syncs, so aggregate to dedupe
			-- DEBUG: Log sample counts BEFORE deduplication
			if alt.items and #alt.items > 0 then
				local beforeSample = {}
				for i = 1, math.min(5, #alt.items) do
					local item = alt.items[i]
					if item then
						table.insert(beforeSample, string.format("%s:%d", item.ID or "?", item.Count or 0))
					end
				end
				TOGBankClassic_Output:Debug("SYNC", "BEFORE dedupe - First 5 items received: %s", table.concat(beforeSample, ", "))
			end

			-- MAIL-010: Check if we need to merge mail items into alt.items
			-- Only merge if this is OLD data (no mailHash = created before mail sync existed)
			-- If mailHash exists, alt.items already includes mail from sender's Bank:Scan()
			local hasMailHash = alt.mailHash ~= nil
			local mailItems = (alt.mail and alt.mail.items) or {}
			local hasMailItems = mailItems and #mailItems > 0
			local needsMailMerge = hasMailItems and not hasMailHash

			if needsMailMerge then
				TOGBankClassic_Output:Debug("SYNC", "OLD DATA: Merging %d mail items into alt.items for %s (no mailHash)", #mailItems, name)
				-- Aggregate alt.items with mail to ensure mail is included
				local aggregated = TOGBankClassic_Item:Aggregate(alt.items, mailItems)
				local arrayItems = {}
				for _, item in pairs(aggregated) do
					table.insert(arrayItems, item)
				end
				alt.items = arrayItems
				TOGBankClassic_Output:Debug("SYNC", "Merged alt.items for %s: %d items (including mail)",
					name, #alt.items)
			else
				if hasMailHash then
					TOGBankClassic_Output:Debug("SYNC", "NEW DATA: alt.items already includes mail (mailHash present) for %s", name)
				end
				-- No mail merge needed, just deduplicate
				local aggregated = TOGBankClassic_Item:Aggregate(alt.items, nil)
				local arrayItems = {}
				for _, item in pairs(aggregated) do
					table.insert(arrayItems, item)
				end
				alt.items = arrayItems
				TOGBankClassic_Output:Debug("SYNC", "alt.items exists for %s, deduplicated and converted to array: %d items",
					name, #alt.items)
			end

			-- DEBUG: Log sample counts AFTER deduplication
			if alt.items and #alt.items > 0 then
				local afterSample = {}
				for i = 1, math.min(5, #alt.items) do
					local item = alt.items[i]
					if item then
						table.insert(afterSample, string.format("%s:%d", item.ID or "?", item.Count or 0))
					end
				end
				TOGBankClassic_Output:Debug("SYNC", "AFTER dedupe - First 5 items stored: %s", table.concat(afterSample, ", "))
			end
		end

		local norm = self:NormalizeName(name)
		self.pendingP2PRequests[norm] = nil
		self.pendingAltRequests[norm] = nil
		local existing = self.Info.alts[norm]
		local hadBankerData = self:HasAltData(existing)
		local senderNorm = sender and self:NormalizeName(sender) or nil

		-- DATA-004/DATA-006: Banker protection logic
		-- Rule 1: Never accept data about yourself (you are source of truth)
		-- Rule 2: Bankers only accept data about OTHER bankers FROM that banker
		-- Rule 3: Non-bankers accept data from anyone
		local player = UnitName("player") .. "-" .. GetNormalizedRealmName()
		local playerNorm = self:NormalizeName(player)
		local isOwnData = playerNorm == norm
		local targetIsBanker = self:IsBank(norm)
		local senderIsBanker = senderNorm and self:IsBank(senderNorm) or false
		local receiverIsBanker = self:IsBank(playerNorm)

		-- Rule 1: Reject data about ourselves (we already have our own current data)
		if isOwnData then
			TOGBankClassic_Output:Warn(
				"[DATA-004] Rejected alt data about ourselves (we are the source of truth)"
			)
			return ADOPTION_STATUS.UNAUTHORIZED
		end

		-- Rule 2: Banker protection - only apply if WE are a banker protecting our data
		-- Regular users should accept banker data from anyone
		if receiverIsBanker and targetIsBanker then
			-- We are a banker, and data is about a banker - only accept if sender is that banker
			if senderNorm ~= norm then
			-- OPTION-B: Check timestamps before rejecting - allow if incoming is newer
			local incomingUpdatedAt = alt.inventoryUpdatedAt or alt.version
			local existingUpdatedAt = existing and (existing.inventoryUpdatedAt or existing.version) or nil
			
			-- Allow if: no existing data OR incoming is newer
			local shouldAccept = false
			if not existing then
				shouldAccept = true
				TOGBankClassic_Output:Info(
					"[OPTION-B] Accepting banker data from non-banker: no existing data for %s", norm)
			elseif incomingUpdatedAt and existingUpdatedAt and incomingUpdatedAt > existingUpdatedAt then
				shouldAccept = true
				TOGBankClassic_Output:Info(
					"[OPTION-B] Accepting newer banker data: %s about %s (timestamp %d > %d)",
					senderNorm or "unknown", norm, incomingUpdatedAt, existingUpdatedAt)
			end
			
			if not shouldAccept then
				-- Reject: incoming is not newer
				TOGBankClassic_Output:Debug("SYNC",
					"[DATA-006] Rejected data about banker %s from %s (not newer: incoming=%s, existing=%s)",
					norm, senderNorm or "unknown", 
					tostring(incomingUpdatedAt), tostring(existingUpdatedAt))
				return ADOPTION_STATUS.UNAUTHORIZED
			end
		else
			-- If we get here: senderNorm == norm (banker updating themselves) - ACCEPT
			TOGBankClassic_Output:Debug("SYNC",
				"[DATA-006] Accepting data about banker %s from themselves",
				norm)
		end
	end

	-- Rule 3: Non-bankers accept all data, non-banker data accepted from anyone

	-- Non-banker conflict resolution: newest wins (timestamped hash)
	local incomingUpdatedAt = alt.inventoryUpdatedAt or alt.version
	local existingUpdatedAt = existing and (existing.inventoryUpdatedAt or existing.version) or nil

	-- Backfill missing inventoryUpdatedAt on incoming data
		if incomingUpdatedAt and not alt.inventoryUpdatedAt then
			alt.inventoryUpdatedAt = incomingUpdatedAt
		end

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

		local existingHasContent = existing and self:HasAltContent(existing, norm) or false
		local incomingHasContent = self:HasAltContent(alt, norm)
		-- Allow incoming data if we have no existing data OR existing has no content
		local allowStaleBecauseMissingContent = (not existing) or (not existingHasContent and incomingHasContent)
		if allowStaleBecauseMissingContent then
			TOGBankClassic_Output:Debug("SYNC", "Accepting data for %s (no existing data or existing has no content)", norm)
		end
		if existingHasContent and not incomingHasContent then
			TOGBankClassic_Output:Debug("SYNC", "Rejecting empty data for %s because existing has content", norm)
			return ADOPTION_STATUS.STALE
		end

-- PERFORMANCE FIX: Reject old client syncs if we already have mail preserved
	-- Old clients (pre-v0.8.0) don't include mail in their syncs
	-- If we already have data with mail, don't accept incomplete data from old clients
	local incomingHasMail = alt.mail ~= nil
	local existingHasMail = existing and existing.mail ~= nil
	if existing and existingHasMail and not incomingHasMail then
		TOGBankClassic_Output:Debug("SYNC", "Rejecting old client sync for %s (we have mail, incoming doesn't) - STALE",
			norm)
		return ADOPTION_STATUS.STALE
	end

	-- Hash-based staleness check: If inventory hash matches, data is identical (PERFORMANCE FIX)
	-- Skip expensive mail preservation if nothing changed
	-- ONLY reject if we actually have content - if existing has no content, always accept incoming data
	if existing and existingHasContent and alt.inventoryHash and existing.inventoryHash and alt.inventoryHash == existing.inventoryHash then
		TOGBankClassic_Output:Debug("SYNC", "Hash match for %s (hash=%d) - data unchanged, rejecting as STALE",
			norm, alt.inventoryHash)
		return ADOPTION_STATUS.STALE
	end

	if not targetIsBanker and existing and incomingUpdatedAt and existingUpdatedAt and not allowStaleBecauseMissingContent then
		TOGBankClassic_Output:Debug("SYNC", "Timestamp staleness check for %s: incoming=%d, existing=%d, hasContent=%s", 
			norm, incomingUpdatedAt, existingUpdatedAt, tostring(existingHasContent))
		if incomingUpdatedAt < existingUpdatedAt then
			TOGBankClassic_Output:Debug("SYNC", "Rejecting %s: incoming timestamp %d < existing %d", 
				norm, incomingUpdatedAt, existingUpdatedAt)
			return ADOPTION_STATUS.STALE
		elseif incomingUpdatedAt == existingUpdatedAt then
			-- Tie-breaker: choose the one with more items
			local incomingCount = itemCount(alt)
			local existingCount = itemCount(existing)
			TOGBankClassic_Output:Debug("SYNC", "Timestamp tie for %s: incomingCount=%d, existingCount=%d", 
				norm, incomingCount, existingCount)
			if incomingCount <= existingCount then
				TOGBankClassic_Output:Debug("SYNC", "Rejecting %s: incoming itemCount %d <= existing %d", 
					norm, incomingCount, existingCount)
				return ADOPTION_STATUS.STALE
			end
		end
	end

		-- Legacy fallback: version-based staleness check
		if existing and alt.version ~= nil and existing.version ~= nil and alt.version < existing.version and not allowStaleBecauseMissingContent then
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

		-- DATA-006/MAIL-009: Preserve mail field from existing data when incoming sync lacks it
		-- Mail is now synced in v0.8.0+, but old clients don't include it in their syncs
		-- Preserve locally-scanned mail data to maintain visibility for new clients
		local existingMail = existing and existing.mail or nil
		local incomingHasMail = alt.mail ~= nil

		TOGBankClassic_Output:Debug("MAIL", "AdoptAltData for %s: existingMail=%s, incomingHasMail=%s",
			norm, existingMail and "YES" or "NO", tostring(incomingHasMail))
		if existingMail then
			TOGBankClassic_Output:Debug("MAIL", "  existingMail has %d items", existingMail.items and #existingMail.items or 0)
		end

		---@diagnostic disable-next-line: need-check-nil
		self.Info.alts[norm] = alt
		TOGBankClassic_Output:Debug("MAIL", "Overwrote self.Info.alts[%s], mail field now: %s",
			norm, alt.mail and "EXISTS" or "GONE")

		-- [MAIL-012] Log mailHash after storing to verify it persisted
		TOGBankClassic_Output:Debug("SYNC", "[MAIL-012] Stored alt data for %s: mailHash=%s", norm, tostring(self.Info.alts[norm].mailHash))

		-- Restore preserved mail if we had it locally and incoming sync doesn't have it
		-- This handles backward compatibility: new clients preserve mail when receiving from old clients
		if existingMail and not incomingHasMail then
			self.Info.alts[norm].mail = existingMail
			local mailItemCount = existingMail.items and #existingMail.items or 0
			TOGBankClassic_Output:Debug("MAIL", "Restored mail for %s (%d items) - incoming sync lacked mail",
				norm, mailItemCount)
			TOGBankClassic_Output:Debug("MAIL",
				"[MAIL-009] Preserved mail data for %s (%d items, lastScan=%s) - backward compat",
				norm, mailItemCount, tostring(existingMail.lastScan))

			-- MAIL-010: Re-aggregate alt.items to include the restored mail
			-- The incoming alt.items doesn't have mail, so we need to merge it back in
			if existingMail.items and #existingMail.items > 0 then
				TOGBankClassic_Output:Debug("MAIL", "[MAIL-010] Merging %d restored mail items into alt.items for %s",
					#existingMail.items, norm)
				local aggregated = TOGBankClassic_Item:Aggregate(self.Info.alts[norm].items, existingMail.items)
				self.Info.alts[norm].items = {}
				for _, item in pairs(aggregated) do
					table.insert(self.Info.alts[norm].items, item)
				end
				TOGBankClassic_Output:Debug("MAIL", "[MAIL-010] Re-aggregated alt.items for %s: %d items (including restored mail)",
					norm, #self.Info.alts[norm].items)
			end
		elseif incomingHasMail then
			TOGBankClassic_Output:Debug("MAIL", "Using incoming mail data for %s (new client sync)", norm)
		end

		-- Reset search data flag so inventory UI rebuilds search index (UI-008 fix)
		if TOGBankClassic_UI_Inventory then
			TOGBankClassic_UI_Inventory.searchDataBuilt = false
		end

		-- Reconstruct Links for items (v0.8.0 bandwidth optimization)
		if alt.items then
			self:ReconstructItemLinks(alt.items)
			-- Ensure UI refresh even when no links need reconstruction
			ThrottledUIRefresh()
		end

		-- Reset error count on successful full sync
		self:ResetDeltaErrorCount(norm)

		-- Progress reporting for banker sync coverage
		local rosterAlts = self:GetRosterAlts() or self:GetBanks() or {}
		local isRosterBanker = false
		for _, altName in ipairs(rosterAlts) do
			if self:NormalizeName(altName) == norm then
				isRosterBanker = true
				break
			end
		end
		if isRosterBanker and not hadBankerData then
			self:ReportBankerDataProgress("received " .. tostring(norm), true)
		end

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

-- Check if this client uses SYNC-006 aggregated items format
function TOGBankClassic_Guild:UsesSYNC006()
	-- SYNC-006 introduced aggregated items structure (alt.items)
	-- All current clients use SYNC-006
	return true
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
function TOGBankClassic_Guild:ComputeDelta(name, currentAlt, requesterInventoryHash, requesterMailHash)
	return TOGBankClassic_DeltaComms:ComputeDelta(self.Info and self.Info.name, name, currentAlt, requesterInventoryHash, requesterMailHash)
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

function TOGBankClassic_Guild:HashUpdate()
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		return
	end
	self.Info = TOGBankClassic_Database:Load(guild)
	local player = TOGBankClassic_Guild:GetPlayer()
	local normPlayer = TOGBankClassic_Guild:GetNormalizedPlayer(player)
	
	-- Only bankers can use this command
	if not (self.Info.alts[normPlayer] and TOGBankClassic_Guild:IsBank(normPlayer)) then
		TOGBankClassic_Output:Response("Only bankers can use /togbank hashupdate")
		return
	end
	
	-- Broadcast hash-list for ALL bank alts
	TOGBankClassic_Output:Info("Broadcasting hash-list for ALL bank alts...")
	local hashList = self:BuildBankerHashList()
	local payload = {
		type = "hash-list-broadcast",
		alts = hashList,
		banker = normPlayer,
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	TOGBankClassic_Core:SendCommMessage("togbank-hl", data, "GUILD", nil, "NORMAL")
	
	local count = 0
	for _ in pairs(hashList) do
		count = count + 1
	end
	TOGBankClassic_Output:Info("Broadcasted hash-list for %d bank alts", count)
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
		-- Banker running /togbank share: broadcast hash for CURRENT banker only
		local alt = self.Info.alts[normPlayer]
		if alt then
			local singleAltHash = {
				[normPlayer] = {
					hash = alt.inventoryHash or 0,
					updatedAt = alt.inventoryUpdatedAt or alt.version or 0,
					version = alt.version or 0,
					mailHash = alt.mailHash or 0,
					mailUpdatedAt = (alt.mail and alt.mail.version) or 0,
				}
			}
			local payload = {
				type = "hash-list-broadcast",
				alts = singleAltHash,
				banker = normPlayer,
			}
			local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
			TOGBankClassic_Core:SendCommMessage("togbank-hl", data, "GUILD", nil, "NORMAL")
			TOGBankClassic_Output:Info("Broadcasted hash for %s (invHash=%d, mailHash=%d)", normPlayer, singleAltHash[normPlayer].hash, singleAltHash[normPlayer].mailHash)
		else
			TOGBankClassic_Output:Response("No data available for %s", normPlayer)
		end
	end

	if mode == "snapshot" then
		-- Share current requests state alongside bank data so everyone stays in sync
		self:SendRequestsData()
	elseif mode == "version" then
		-- Lightweight ping; snapshots are sent only when queried.
		--self:SendRequestsVersionPing()  -- COMMENTED OUT: togbank-v ignored by delta clients (BANDWIDTH-001)
	end

	-- v0.8.0: Broadcast delta version with hashes for pull-based protocol
	-- Send BOTH legacy and delta version broadcasts (SYNC-001 fix)
	--[[ COMMENTED OUT: togbank-v ignored by delta clients
	if TOGBankClassic_Events and TOGBankClassic_Events.Sync then
		TOGBankClassic_Events:Sync()
	end
	--]]
	TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] About to call SyncDeltaVersion (exists=%s)", tostring(TOGBankClassic_Events and TOGBankClassic_Events.SyncDeltaVersion ~= nil))
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
		if info and not info.roster then
			info.roster = {}
		end
		if info and info.roster then
			info.roster.alts = banks
			info.roster.version = GetServerTime()
			if not banks then
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

