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
	self:RegisterEvent("GUILD_RANKS_UPDATE")
	self:RegisterEvent("BANKFRAME_OPENED")
	self:RegisterEvent("BANKFRAME_CLOSED")
	self:RegisterEvent("MAIL_SHOW")
	self:RegisterEvent("MAIL_INBOX_UPDATE")
	self:RegisterEvent("MAIL_CLOSED")
	self:RegisterEvent("MAIL_SEND_SUCCESS")
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
	end, 600)
end

function TOGBankClassic_Events:OnTimer()
	TOGBankClassic_Events:Sync()

	self:SetTimer()
end

---START CHANGES
function TOGBankClassic_Events:SetShareTimer()
	TOGBankClassic_Core:ScheduleTimer(function(...)
		TOGBankClassic_Events:OnShareTimer()
	end, 180)
end

function TOGBankClassic_Events:OnShareTimer()
	TOGBankClassic_Guild:Share("reply")

	self:SetShareTimer()
end
---END CHANGES

function TOGBankClassic_Events:Sync()
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

	local data = TOGBankClassic_Core:Serialize(version)
	TOGBankClassic_Core:SendCommMessage("togbank-v", data, "Guild", nil, "BULK")
end

function TOGBankClassic_Events:PLAYER_LOGIN(_)
	TOGBankClassic_Guild:GetPlayer()
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
			if self.debug then
				TOGBankClassic_Core:Print("GUILD_RANKS_UPDATE: ignoring cleanup", prefix, "from", sender, "(in raid)")
			end
			return
		end
		local cleaned = TOGBankClassic_Guild:CleanupMalformedAlts()
		if cleaned and cleaned > 0 then
			TOGBankClassic_Core:Printf("Cleaned %d malformed alt entries from saved database", cleaned)
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
	TOGBankClassic_Bank:OnUpdateStart()
	TOGBankClassic_Mail.isOpen = true
	TOGBankClassic_Mail:InitSendHook()
	TOGBankClassic_Mail:Check()
end

function TOGBankClassic_Events:MAIL_INBOX_UPDATE(_)
	TOGBankClassic_Mail:Scan()
end

function TOGBankClassic_Events:MAIL_CLOSED(_)
	TOGBankClassic_Mail.isOpen = false
	TOGBankClassic_Mail.isScanning = false
	TOGBankClassic_Bank:OnUpdateStop()
	TOGBankClassic_UI_Mail:Close()
end

function TOGBankClassic_Events:MAIL_SEND_SUCCESS(_)
	-- safety: ensure hook is registered when mail UI is opened
	TOGBankClassic_Mail:InitSendHook()
	TOGBankClassic_Mail:ApplyPendingSend()
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
