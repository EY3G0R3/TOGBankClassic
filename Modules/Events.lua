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
	if duration > 20 then
		TOGBankClassic_Output:Debug("EVENTS", "OnShareTimer took %.2fms", duration)
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
function TOGBankClassic_Events:SyncDeltaVersion(priority)
	local startTime = debugprofilestop()
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] SyncDeltaVersion SKIP: no guild")
		return
	end

	-- Only broadcast delta version if we support delta
	if not TOGBankClassic_Guild:ShouldUseDelta() then
		TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] SyncDeltaVersion SKIP: ShouldUseDelta=false (DELTA_ENABLED=%s, SUPPORTS_DELTA=%s)", 
			tostring(FEATURES.DELTA_ENABLED), tostring(PROTOCOL.SUPPORTS_DELTA))
		return
	end

	local version = TOGBankClassic_Guild:GetVersion()
	if version == nil then
		TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] SyncDeltaVersion SKIP: version is nil")
		return
	end
	-- REMOVED: roster.version check - roster is now local-only, no need to gate broadcasts on it

	-- v0.8.0: Include banker status for pull-based protocol
	local player = TOGBankClassic_Guild:GetNormalizedPlayer()
	local isBanker = player and TOGBankClassic_Guild:IsBank(player) or false
	version.isBanker = isBanker

	-- SYNC-006 Migration: Send on BOTH channels
	-- togbank-dv2 for new clients (with aggregated items hash)
	local altCount = 0
	if version.alts then
		for _ in pairs(version.alts) do
			altCount = altCount + 1
		end
	end
	TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] SENDING togbank-dv2 from %s (isBanker=%s, altCount=%d)", 
		player, tostring(isBanker), altCount)
	local data = TOGBankClassic_Core:SerializeWithChecksum(version)
	TOGBankClassic_Output:Debug("PROTOCOL", "[MAIL-012] togbank-dv2 message size: %d bytes", #data)
	TOGBankClassic_Core:SendCommMessage("togbank-dv2", data, "Guild", nil, priority or "NORMAL")
	local duration = debugprofilestop() - startTime
	if duration > 20 then
		TOGBankClassic_Output:Debug("EVENTS", "SyncDeltaVersion took %.2fms (alts=%d, size=%d)", duration, altCount, #data)
	end
	
	-- Also send on togbank-dv for old pre-SYNC-006 clients
	-- Note: Old clients will compute hash from their legacy alt.bank/alt.bags structure
	-- New clients ignore togbank-dv, so no conflict
	--[[ COMMENTED OUT - Legacy togbank-dv protocol (pre-SYNC-006)
	TOGBankClassic_Core:SendCommMessage("togbank-dv", data, "Guild", nil, priority or "NORMAL")
	--]]
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
	GuildRoster()
	-- Initialize cache immediately in case GUILD_ROSTER_UPDATE is delayed
	TOGBankClassic_Guild:RefreshOnlineCache()
end

-- Refresh online members cache when roster updates
function TOGBankClassic_Events:GUILD_ROSTER_UPDATE(_)
	TOGBankClassic_Performance:RecordEvent("GUILD_ROSTER_UPDATE")
	TOGBankClassic_Guild:RefreshOnlineCache()
	-- Invalidate banks cache when roster updates
	TOGBankClassic_Guild:InvalidateBanksCache()
	-- Rebuild banker roster from guild notes (local only, no network communication)
	TOGBankClassic_Guild:RebuildBankerRoster()
	-- Clear delta error counters for offline players
	TOGBankClassic_DeltaComms:ClearOfflineErrorCounters(TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name)
	-- Refresh Requests UI to update banker-only controls (like highlight checkbox)
	TOGBankClassic_Guild:RefreshRequestsUI()
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