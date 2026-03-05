TOGBankClassic_Events = {}

function TOGBankClassic_Events:RegisterMessage(message, callback)
	if not callback then
		callback = message
	end
	TOGBankClassic_Core:RegisterMessage(message, callback)
end

function TOGBankClassic_Events:SendMessage(message, ...)
	TOGBankClassic_Core:SendMessage(message, ...)
end
function TOGBankClassic_Events:UnregisterMessage(message)
	TOGBankClassic_Core:UnregisterMessage(message)
end

function TOGBankClassic_Events:RegisterEvent(event, callback)
	if not callback then
		callback = event
	end
	TOGBankClassic_Core:RegisterEvent(event, function(...)
		self[callback](self, ...)
	end)
end

function TOGBankClassic_Events:UnregisterEvent(...)
	TOGBankClassic_Core:UnregisterEvent(...)
end

function TOGBankClassic_Events:RegisterEvents()
	if TOGBankClassic_Bank.eventsRegistered then
		return
	end

	self:RegisterEvent("PLAYER_LOGIN")
	self:RegisterEvent("PLAYER_LOGOUT")
	self:RegisterEvent("GUILD_RANKS_UPDATE")
	self:RegisterEvent("BANKFRAME_OPENED")
	self:RegisterEvent("BANKFRAME_CLOSED")
	self:RegisterEvent("MAIL_SHOW")
	self:RegisterEvent("MAIL_INBOX_UPDATE")
	self:RegisterEvent("MAIL_CLOSED")
	self:RegisterEvent("MAIL_SEND_SUCCESS")
	self:RegisterEvent("UI_ERROR_MESSAGE")
	self:RegisterEvent("GUILD_ROSTER_UPDATE")
	self:RegisterEvent("CHAT_MSG_SYSTEM")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("TRADE_SHOW")
	self:RegisterEvent("TRADE_CLOSED")
	self:RegisterEvent("AUCTION_HOUSE_SHOW")
	self:RegisterEvent("AUCTION_HOUSE_CLOSED")
	self:RegisterEvent("MERCHANT_SHOW")
	self:RegisterEvent("MERCHANT_CLOSED")
	self:RegisterEvent("PLAYER_REGEN_DISABLED") --player entered combat
	hooksecurefunc("ChatEdit_InsertLink", function(link)
		TOGBankClassic_UI:OnInsertLink(link)
	end)

	-- Filter out "No player named X is currently playing" and "Player not found" errors from chat
	-- These are detected and handled by CHAT_MSG_SYSTEM event handler
	-- Use fast plain-text check before pattern matching for performance
	ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(self, event, message, ...)
		if message then
			-- Check for Classic Era pattern
			if message:find("No player named ", 1, true) then
				-- Only do pattern match if we found the error prefix
				if message:match("^No player named .+ is currently playing%.$") then
					return true  -- Suppress this message
				end
			end
			-- Check for alternate "Player not found" pattern
			if message:find("Player not found", 1, true) then
				return true  -- Suppress this message too
			end
		end
		return false
	end)

	-- Hook MailFrame visibility changes directly for more reliable detection
	if MailFrame and not MailFrame.togBankHooked then
		MailFrame.togBankHooked = true
		MailFrame:HookScript("OnShow", function()
			TOGBankClassic_Mail.isOpen = true
			C_Timer.After(0.1, function()
				if TOGBankClassic_UI_Requests.isOpen then
					TOGBankClassic_UI_Requests:DrawContent()
				end
			end)
		end)
		MailFrame:HookScript("OnHide", function()
			TOGBankClassic_Mail.isOpen = false
			C_Timer.After(0.1, function()
				if TOGBankClassic_UI_Requests.isOpen then
					TOGBankClassic_UI_Requests:DrawContent()
				end
			end)
		end)
	end

	-- Hook Send Mail tab to auto-open Requests window for bank alts (like BulkMail)
	if MailFrameTab2 and not MailFrameTab2.togBankHooked then
		MailFrameTab2.togBankHooked = true
		MailFrameTab2:HookScript("OnClick", function()
			local player = TOGBankClassic_Guild:GetNormalizedPlayer()
			if player and TOGBankClassic_Guild:IsBank(player) then
				C_Timer.After(0.1, function()
					if TOGBankClassic_UI_Requests.isOpen then
						TOGBankClassic_UI_Requests:DrawContent()
					else
						TOGBankClassic_UI_Requests:Open()
					end
				end)
			end
		end)
	end

	self:SetTimer()
	---START CHANGES
	self:SetShareTimer()
	---END CHANGES
	TOGBankClassic_Bank.eventsRegistered = true
end

function TOGBankClassic_Events:UnregisterEvents()
	if not TOGBankClassic_Bank.eventsRegistered then
		return
	end
	TOGBankClassic_Bank.eventsRegistered = false

	self:UnregisterEvent("PLAYER_LOGIN")
	self:UnregisterEvent("GUILD_RANKS_UPDATE")
	self:UnregisterEvent("BANKFRAME_OPENED")
	self:UnregisterEvent("BANKFRAME_CLOSED")
	self:UnregisterEvent("MAIL_SHOW")
	self:UnregisterEvent("MAIL_INBOX_UPDATE")
	self:UnregisterEvent("MAIL_CLOSED")
	self:UnregisterEvent("MAIL_SEND_SUCCESS")
	self:UnregisterEvent("UI_ERROR_MESSAGE")
	self:UnregisterEvent("CHAT_MSG_SYSTEM")
	self:UnregisterEvent("TRADE_SHOW")
	self:UnregisterEvent("TRADE_CLOSED")
	self:UnregisterEvent("AUCTION_HOUSE_SHOW")
	self:UnregisterEvent("AUCTION_HOUSE_CLOSED")
	self:UnregisterEvent("MERCHANT_SHOW")
	self:UnregisterEvent("MERCHANT_CLOSED")
	self:UnregisterEvent("PLAYER_REGEN_DISABLED") --player entered combat
end

function TOGBankClassic_Events:SetTimer()
	TOGBankClassic_Core:ScheduleTimer(function(...)
		TOGBankClassic_Events:OnTimer()
	end, TIMER_INTERVALS.ROSTER_AND_ALT_SYNC)
end

function TOGBankClassic_Events:OnTimer()
	--TOGBankClassic_Events:Sync()  -- COMMENTED OUT: togbank-v ignored by delta clients

	self:SetTimer()
end

---START CHANGES
function TOGBankClassic_Events:SetShareTimer()
	if self.shareTimer then
		TOGBankClassic_Core:CancelTimer(self.shareTimer)
		self.shareTimer = nil
	end
	self.shareTimer = TOGBankClassic_Core:ScheduleTimer(function(...)
		TOGBankClassic_Events:OnShareTimer()
	end, TIMER_INTERVALS.VERSION_BROADCAST)
end

function TOGBankClassic_Events:OnShareTimer()
	local now = GetTime()
	if self.lastShareTimerAt then
		local delta = now - self.lastShareTimerAt
		if delta < (TIMER_INTERVALS.VERSION_BROADCAST - 10) then
			TOGBankClassic_Output:Debug("EVENTS", "OnShareTimer fired early (%.1fs since last)", delta)
		end
	end
	self.lastShareTimerAt = now
	local startTime = debugprofilestop()
	TOGBankClassic_Guild:Share("reply", "version")
	local duration = debugprofilestop() - startTime
	TOGBankClassic_Output:Debug("EVENTS", "OnShareTimer took %.2fms", duration)

-- P2P-006: New clients broadcast their hashes via SyncDeltaVersion (called above
	-- inside Guild:Share).  Only fall back to the banker whisper for wipe-recovery:
	-- if we have NO hash data at all we can't participate in P2P comparison, so we
	-- need the banker to seed our stub table first.
	local hasAnyHashes = false
	local myAlts = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts or {}
	for _, alt in pairs(myAlts) do
		if (alt.inventoryHash or 0) ~= 0 or (alt.mailHash or 0) ~= 0 then
			hasAnyHashes = true
			break
		end
	end
	if not hasAnyHashes then
		-- Wipe-recovery: no local hashes at all → seed from banker so future P2P cycles work.
		TOGBankClassic_Guild:RequestHashListFromBanker()
	end
	
	-- REQUEST-001: Automatic index-based request sync on periodic timer
	TOGBankClassic_Guild:QueryRequestsIndex(nil, "NORMAL")

	-- PERF-011: Periodically prune stale delta history so SavedVariables stays small.
	-- Runs every VERSION_BROADCAST interval (3 min); cheap when already clean.
	local guild = TOGBankClassic_Guild:GetGuild()
	if guild then
		local removed = TOGBankClassic_Database:CleanupDeltaHistory(guild)
		if removed and removed > 0 then
			TOGBankClassic_Output:Debug("DATABASE", "Periodic deltaHistory prune: removed %d stale entries", removed)
		end
	end

	self:SetShareTimer()
end
---END CHANGES

--[[ COMMENTED OUT - togbank-v legacy protocol (ignored by delta clients)
function TOGBankClassic_Events:Sync(priority)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		return
	end

	local version = TOGBankClassic_Guild:GetVersion()
	if version == nil then
		return
	end
	if version.roster == nil then
		return
	end

	local data = TOGBankClassic_Core:SerializeWithChecksum(version)
	-- Use provided priority or default to BULK for automatic timer-based syncs
	TOGBankClassic_Core:SendCommMessage("togbank-v", data, "Guild", nil, priority or "BULK")
end
--]]

-- Delta-specific version broadcast (SYNC-001 fix)
-- v0.8.0 SYNC-006: Bankers send BOTH togbank-dv (old) and togbank-dv2 (new) during migration
-- P2P-006: Broadcast our hash list to the guild so peers can offer newer data.
-- Called on the 3-minute timer (via Guild:Share) and after every bank scan.
function TOGBankClassic_Events:SyncDeltaVersion(priority)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then return end

	local list = TOGBankClassic_Guild:BuildBankerHashList()
	if not list then return end

	local altCount = 0
	for _ in pairs(list) do altCount = altCount + 1 end
	if altCount == 0 then return end

	local myPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()
	local payload = {
		type     = "hash-list-broadcast",
		alts     = list,
		banker   = myPlayer,
		isBanker = TOGBankClassic_Guild:IsBank(myPlayer),
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	TOGBankClassic_Core:SendCommMessage("togbank-hl", data, "GUILD", nil, priority or "BULK")
	TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "SyncDeltaVersion: broadcast %d alts (isBanker=%s)",
		altCount, tostring(payload.isBanker))

	-- Begin P2P collect window so incoming hash-offer responses are gathered.
	if TOGBankClassic_P2PSession then
		TOGBankClassic_P2PSession:BeginCollectWindow(list)
	end
end

function TOGBankClassic_Events:PLAYER_LOGIN(_)
	TOGBankClassic_Guild:GetPlayer()
end

function TOGBankClassic_Events:PLAYER_LOGOUT(_)
	-- DEBUG: Check if mail field exists before logout
	local player = UnitName("player") .. "-" .. GetRealmName()

	-- Store debug info in a SavedVariable so we can check after logout
	if not TOGBankClassic_MailDebugLog then
		TOGBankClassic_MailDebugLog = {}
	end

	local debugInfo = {
		player = player,
		timestamp = GetServerTime(),
		mailExists = false,
		mailItemCount = 0,
	}

	TOGBankClassic_Output:Debug("MAIL", "========================================")
	TOGBankClassic_Output:Debug("MAIL", "Checking mail at logout for: %s", player)
	if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts and TOGBankClassic_Guild.Info.alts[player] then
		local alt = TOGBankClassic_Guild.Info.alts[player]
		if alt.mail then
			local mailCount = alt.mail.items and #alt.mail.items or 0
			debugInfo.mailExists = true
			debugInfo.mailItemCount = mailCount
			debugInfo.versionType = type(alt.mail.version)
			debugInfo.versionValue = tostring(alt.mail.version)
			debugInfo.lastScanType = type(alt.mail.lastScan)
			debugInfo.slotsType = type(alt.mail.slots)
			debugInfo.hasMetatable = getmetatable(alt.mail) ~= nil

			-- Check if items is a proper array
			debugInfo.itemsIsTable = type(alt.mail.items) == "table"
			if alt.mail.items then
				local hasSequentialKeys = true
				for i = 1, mailCount do
					if alt.mail.items[i] == nil then
						hasSequentialKeys = false
						break
					end
				end
				debugInfo.hasSequentialKeys = hasSequentialKeys
			end

			TOGBankClassic_Output:Debug("MAIL", "Mail field exists with %d items", mailCount)
			TOGBankClassic_Output:Debug("MAIL", "  version: %s (type: %s)", tostring(alt.mail.version), type(alt.mail.version))
			TOGBankClassic_Output:Debug("MAIL", "  lastScan: %s (type: %s)", tostring(alt.mail.lastScan), type(alt.mail.lastScan))
			TOGBankClassic_Output:Debug("MAIL", "  slots type: %s", type(alt.mail.slots))
			if alt.mail.slots then
				debugInfo.slotsCount = alt.mail.slots.count
				TOGBankClassic_Output:Debug("MAIL", "  slots.count: %s", tostring(alt.mail.slots.count))
			end
			-- Check for metatables or functions that would prevent serialization
			if getmetatable(alt.mail) then
				TOGBankClassic_Output:Debug("MAIL", "WARNING: alt.mail has a metatable!")
			end
		else
			TOGBankClassic_Output:Debug("MAIL", "Mail field missing!")
		end
	else
		debugInfo.noAltData = true
		TOGBankClassic_Output:Debug("MAIL", "Alt data not found")
	end

	TOGBankClassic_MailDebugLog[player] = debugInfo
	TOGBankClassic_Output:Debug("MAIL", "========================================")
	-- Save persistent debug log to SavedVariables
	TOGBankClassic_Output:SavePersistentLog()
end

-- Request initial guild roster update on world enter
function TOGBankClassic_Events:PLAYER_ENTERING_WORLD(_)
	TOGBankClassic_Performance:RecordEvent("PLAYER_ENTERING_WORLD")
	TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] PLAYER_ENTERING_WORLD - Requesting guild roster")
	GuildRoster()
	-- Don't try to cache before GUILD_ROSTER_UPDATE fires - GuildRoster() is async
	-- The cache will be populated when GUILD_ROSTER_UPDATE event fires
	-- Allow full refresh cycles on init to populate roster/banker cache
	self.needsFullRosterRefresh = true
	self.fullRosterInitAttempts = 0
end

-- Refresh online members cache when roster updates
function TOGBankClassic_Events:GUILD_ROSTER_UPDATE(_)
	TOGBankClassic_Performance:RecordEvent("GUILD_ROSTER_UPDATE")
	if self.needsFullRosterRefresh then
		self.fullRosterInitAttempts = (self.fullRosterInitAttempts or 0) + 1
TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] GUILD_ROSTER_UPDATE #%d - Full refresh starting", self.fullRosterInitAttempts)
		
		self.needsFullRosterRefresh = false
		
		-- PERF-008: Defer ALL expensive roster operations AND cache invalidation
		-- Must invalidate cache INSIDE the deferred block, otherwise any IsBank() call
		-- between invalidation and rebuild will synchronously rebuild cache, causing freeze
		C_Timer.After(0.5, function()
			-- Invalidate banks cache AFTER deferring, not before
			TOGBankClassic_Guild:InvalidateBanksCache()
			
			local onlineCount, totalMembers = TOGBankClassic_Guild:RefreshOnlineCache()
			TOGBankClassic_Guild:RebuildBankerRoster()
			
			-- Clear delta error counters for offline players (depends on RefreshOnlineCache)
			TOGBankClassic_DeltaComms:ClearOfflineErrorCounters(TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name)
			-- Refresh Requests UI to update banker-only controls (like highlight checkbox)
			TOGBankClassic_Guild:RefreshRequestsUI()
			
			-- Keep refreshing until we get actual online member data OR we've tried 5 times
			-- If we have 0 online members after API returns data, roster API hasn't initialized yet
			local needsRetry = false
			local attempts = self.fullRosterInitAttempts or 0
			if attempts < 5 then
				if not totalMembers or totalMembers == 0 then
						TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] Retry needed: GetNumGuildMembers returned %d", totalMembers or 0)
					needsRetry = true
				elseif onlineCount == 0 then
						TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] Retry needed: 0 online members (guild not empty)")
					needsRetry = true
				end
			end
			
			if needsRetry then
				self.needsFullRosterRefresh = true
					TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] Will retry on next GUILD_ROSTER_UPDATE")
			else
					TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] Roster initialization complete after %d attempts", attempts)
				-- REQUEST-001: Sync request state shortly after login, don't wait for the periodic timer
				TOGBankClassic_Guild:QueryRequestsIndex(nil, "NORMAL")
			end
		end)
	else
		TOGBankClassic_Output:Debug("EVENTS", "GUILD_ROSTER_UPDATE ignored (online/offline handled via system messages)")
	end
end

-- Lightweight online/offline updates from system messages
-- PRIMARY method for tracking online/offline state changes in real-time
function TOGBankClassic_Events:CHAT_MSG_SYSTEM(message)
	if not message or message == "" then
		return
	end

	-- Pattern 1: Player comes online
	local onlineName = message:match("^%[?(.-)%]? has come online%.$")
	if onlineName then
		TOGBankClassic_Output:Debug("ROSTER", "ONLINE", "[CHAT_MSG_SYSTEM] Player came online: %s", onlineName)
		TOGBankClassic_Guild:UpdateOnlineMember(onlineName, true, "system-msg-online")
		return
	end

	-- Pattern 2: Player goes offline
	local offlineName = message:match("^%[?(.-)%]? has gone offline%.$")
	if offlineName then
		TOGBankClassic_Output:Debug("ROSTER", "ONLINE", "[CHAT_MSG_SYSTEM] Player went offline: %s", offlineName)
		TOGBankClassic_Guild:UpdateOnlineMember(offlineName, false, "system-msg-offline")
		return
	end

	-- Pattern 3: CRITICAL - Failed whisper detection
	-- "No player named X is currently playing" means player is OFFLINE
	-- This is the AUTHORITATIVE offline signal - if WoW says they're not online, they're not
	-- Classic can send multiple formats:
	--   No player named 'Axkva' is currently playing.  (with single quotes around name)
	--   No player named Axkva is currently playing.    (without quotes)
	--   Player not found (retail pattern): Axkva       (alternate format - seen in some Classic versions)
	--   Player not found: Axkva                        (simplified format)
	local notFoundName = message:match("^No player named '(.+)' is currently playing%.$")
		or message:match("^No player named (.+) is currently playing%.$")
		or message:match("^Player not found %(retail pattern%): (.+)$")
		or message:match("^Player not found: (.+)$")
	if notFoundName then
		-- CRITICAL: This marks player offline to prevent spam whispers
		TOGBankClassic_Output:Debug("ROSTER", "ONLINE", "[CHAT_MSG_SYSTEM] Player not found: %s - marking offline", notFoundName)
		TOGBankClassic_Output:Info("[WHISPER-SPAM-FIX] Player %s is not online (WoW error - marked offline to prevent spam)", notFoundName)
		TOGBankClassic_Guild:UpdateOnlineMember(notFoundName, false, "wow-error-not-online")
		return
	end

	local joinedName = message:match("^%[?(.-)%]? has joined the guild%.$")
	if joinedName then
		self.needsFullRosterRefresh = true
		GuildRoster()
		return
	end

	local leftName = message:match("^%[?(.-)%]? has left the guild%.$")
	if leftName then
		self.needsFullRosterRefresh = true
		GuildRoster()
		return
	end
end

function TOGBankClassic_Events:GUILD_RANKS_UPDATE(_)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		return
	end

	-- Load guild data and perform a one-time cleanup of malformed alt entries
	if TOGBankClassic_Guild:Init(guild) then
		TOGBankClassic_Options:InitGuild()
		if IsInRaid() then
			TOGBankClassic_Output:Debug("EVENTS", "GUILD_RANKS_UPDATE: ignoring guild ranks cleanup (in raid)")
			return
		end
		local cleaned = TOGBankClassic_Guild:CleanupMalformedAlts()
		if cleaned and cleaned > 0 then
			TOGBankClassic_Output:Info("Cleaned %d malformed alt entries from saved database", cleaned)
		end
		-- PERF-011: Prune stale delta history entries (>1 hour old) on startup.
		-- CleanupDeltaHistory exists but was never called, allowing deltaHistory to grow
		-- to 30,000+ lines in SavedVariables, causing a 3-5 second freeze on load.
		-- Defer slightly so init work completes first; the cleanup itself is fast (table
		-- iteration), and the trimmed data is written to disk on the next logout/reload.
		C_Timer.After(2, function()
			local removed = TOGBankClassic_Database:CleanupDeltaHistory(guild)
			if removed and removed > 0 then
				TOGBankClassic_Output:Debug("DATABASE", "Pruned %d stale deltaHistory entries on startup", removed)
			end
		end)
	end
end

function TOGBankClassic_Events:BANKFRAME_OPENED(_)
	TOGBankClassic_Bank:OnUpdateStart()
end

function TOGBankClassic_Events:BANKFRAME_CLOSED(_)
	TOGBankClassic_Bank:OnUpdateStop()
end

function TOGBankClassic_Events:MAIL_SHOW(_)
	TOGBankClassic_Output:Debug("MAIL", "MAIL_SHOW event fired")
	TOGBankClassic_Bank:OnUpdateStart()
	TOGBankClassic_MailInventory.hasUpdated = true  -- Flag that mail was accessed
	TOGBankClassic_Output:Debug("MAIL", "Set MailInventory.hasUpdated = %s", tostring(TOGBankClassic_MailInventory.hasUpdated))
	TOGBankClassic_Mail.isOpen = true
	TOGBankClassic_Mail:InitSendHook()
	TOGBankClassic_Mail:Check()

	-- Hook MailFrame OnHide to detect when mail closes (MAIL_CLOSED event may not fire reliably)
	if not MailFrame.TOGBankHooked then
		MailFrame:HookScript("OnHide", function()
			TOGBankClassic_Output:Debug("MAIL", "MailFrame OnHide fired (mailbox closed)")
			TOGBankClassic_Events:MAIL_CLOSED()
		end)
		MailFrame.TOGBankHooked = true
		TOGBankClassic_Output:Debug("MAIL", "Hooked MailFrame OnHide")
	end
end

function TOGBankClassic_Events:MAIL_INBOX_UPDATE(_)
	TOGBankClassic_Mail:Scan()
end

function TOGBankClassic_Events:MAIL_CLOSED(_)
	TOGBankClassic_Output:Debug("MAIL", "MAIL_CLOSED event fired")
	TOGBankClassic_Mail.isOpen = false
	TOGBankClassic_Mail.isScanning = false
	TOGBankClassic_Output:Debug("MAIL", "Calling Bank:OnUpdateStop()")
	TOGBankClassic_Bank:OnUpdateStop()
	TOGBankClassic_Output:Debug("MAIL", "Bank:OnUpdateStop() completed")
	TOGBankClassic_UI_Mail:Close()
	-- Refresh requests UI to update fulfill button states
	-- Delay slightly to ensure MailFrame state is updated
	C_Timer.After(0.1, function()
		if TOGBankClassic_UI_Requests.isOpen then
			TOGBankClassic_UI_Requests:DrawContent()
		end
	end)
end

function TOGBankClassic_Events:MAIL_SEND_SUCCESS(_)
	TOGBankClassic_Output:Debug("MAIL", "MAIL_SEND_SUCCESS event fired")
	-- safety: ensure hook is registered when mail UI is opened
	TOGBankClassic_Mail:InitSendHook()
	TOGBankClassic_Mail:ApplyPendingSend()
end

function TOGBankClassic_Events:UI_ERROR_MESSAGE(_, message)
	if not message then
		return
	end

	-- Capture mail send failures (includes "Internal mail database error")
	if tostring(message):lower():find("mail") then
		TOGBankClassic_Output:Debug("MAIL", "UI_ERROR_MESSAGE: %s", tostring(message))
		if TOGBankClassic_Mail and TOGBankClassic_Mail.DebugSendMailState then
			TOGBankClassic_Mail:DebugSendMailState(message)
		end
		if TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.Window then
			TOGBankClassic_UI_Requests.Window:SetStatusText(string.format("Mail error: %s", tostring(message)))
		end
	end
end

function TOGBankClassic_Events:TRADE_SHOW(_)
	TOGBankClassic_Bank:OnUpdateStart()
end

function TOGBankClassic_Events:TRADE_CLOSED(_)
	-- FIXME: Isn't rescanning?
	TOGBankClassic_Bank:OnUpdateStop()
end

function TOGBankClassic_Events:AUCTION_HOUSE_SHOW(_)
	TOGBankClassic_Bank:OnUpdateStart()
end

function TOGBankClassic_Events:AUCTION_HOUSE_CLOSED(_)
	TOGBankClassic_Bank:OnUpdateStop()
end

function TOGBankClassic_Events:MERCHANT_SHOW(_)
	TOGBankClassic_Bank:OnUpdateStart()
end

function TOGBankClassic_Events:MERCHANT_CLOSED(_)
	TOGBankClassic_Bank:OnUpdateStop()
end

--close frame on combat
function TOGBankClassic_Events:PLAYER_REGEN_DISABLED(_)
	if TOGBankClassic_Options:GetCombatHide() then
		TOGBankClassic_UI_Inventory:Close()
	end
end
