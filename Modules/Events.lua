GBankClassic_Events = {}

function GBankClassic_Events:RegisterMessage(message, callback)
    if not callback then callback = message end
    GBankClassic_Core:RegisterMessage(message, callback)
end

function GBankClassic_Events:SendMessage(message, ...) GBankClassic_Core:SendMessage(message, ...) end
function GBankClassic_Events:UnregisterMessage(message) GBankClassic_Core:UnregisterMessage(message) end

function GBankClassic_Events:RegisterEvent(event, callback)
    if not callback then callback = event end
    GBankClassic_Core:RegisterEvent(event, function(...) self[callback](self, ...) end)
end

function GBankClassic_Events:UnregisterEvent(...) GBankClassic_Core:UnregisterEvent(...) end

function GBankClassic_Events:RegisterEvents()
    if GBankClassic_Bank.eventsRegistered then return end

    self:RegisterEvent("PLAYER_LOGIN")
    self:RegisterEvent("GUILD_RANKS_UPDATE")
    self:RegisterEvent("BANKFRAME_OPENED")
    self:RegisterEvent("BANKFRAME_CLOSED")
    self:RegisterEvent("MAIL_SHOW")
    self:RegisterEvent("MAIL_INBOX_UPDATE")
    self:RegisterEvent("MAIL_CLOSED")
    self:RegisterEvent("TRADE_SHOW")
    self:RegisterEvent("TRADE_CLOSED")
    self:RegisterEvent("AUCTION_HOUSE_SHOW")
    self:RegisterEvent("AUCTION_HOUSE_CLOSED")
    self:RegisterEvent("MERCHANT_SHOW")
    self:RegisterEvent("MERCHANT_CLOSED")
    self:RegisterEvent("PLAYER_REGEN_DISABLED")--player entered combat
    hooksecurefunc("ChatEdit_InsertLink", function(link) GBankClassic_UI:OnInsertLink(link) end)

    self:SetTimer()
    ---START CHANGES
    self:SetShareTimer()
    ---END CHANGES
    GBankClassic_Bank.eventsRegistered = true
end

function GBankClassic_Events:UnregisterEvents()
    if not GBankClassic_Bank.eventsRegistered then return end
    GBankClassic_Bank.eventsRegistered = false

    self:UnregisterEvent("PLAYER_LOGIN")
    self:UnregisterEvent("GUILD_RANKS_UPDATE")
    self:UnregisterEvent("BANKFRAME_OPENED")
    self:UnregisterEvent("BANKFRAME_CLOSED")
    self:UnregisterEvent("MAIL_SHOW")
    self:UnregisterEvent("MAIL_INBOX_UPDATE")
    self:UnregisterEvent("MAIL_CLOSED")
    self:UnregisterEvent("TRADE_SHOW")
    self:UnregisterEvent("TRADE_CLOSED")
    self:UnregisterEvent("AUCTION_HOUSE_SHOW")
    self:UnregisterEvent("AUCTION_HOUSE_CLOSED")
    self:UnregisterEvent("MERCHANT_SHOW")
    self:UnregisterEvent("MERCHANT_CLOSED")
    self:UnregisterEvent("PLAYER_REGEN_DISABLED")--player entered combat

end

function GBankClassic_Events:SetTimer()
    GBankClassic_Core:ScheduleTimer(function (...) GBankClassic_Events:OnTimer() end, 600)
end

function GBankClassic_Events:OnTimer()
    GBankClassic_Events:Sync()

    self:SetTimer()
end

---START CHANGES
function GBankClassic_Events:SetShareTimer()
    GBankClassic_Core:ScheduleTimer(function (...) GBankClassic_Events:OnShareTimer() end, 180)
end

function GBankClassic_Events:OnShareTimer()
    GBankClassic_Guild:Share("reply")

    self:SetShareTimer()
end
---END CHANGES

function GBankClassic_Events:Sync()
    local guild = GBankClassic_Guild:GetGuild()
    if not guild then return end

    local version = GBankClassic_Guild:GetVersion()
    if version == nil then return end
    if version.roster == nil then return end

    local data = GBankClassic_Core:Serialize(version)
    GBankClassic_Core:SendCommMessage("gbank-v", data, "Guild", nil, "BULK")
end

function GBankClassic_Events:PLAYER_LOGIN(_)
    GBankClassic_Guild:GetPlayer()
end

function GBankClassic_Events:GUILD_RANKS_UPDATE(_)
    local guild = GBankClassic_Guild:GetGuild()
    if not guild then return end

    -- Load guild data and perform a one-time cleanup of malformed alt entries
    if GBankClassic_Guild:Init(guild) then
        GBankClassic_Options:InitGuild()
        if IsInRaid() then
            if self.debug then GBankClassic_Core:Print('GUILD_RANKS_UPDATE: ignoring cleanup', prefix, 'from', sender, '(in raid)') end
            return
        end
        local cleaned = GBankClassic_Guild:CleanupMalformedAlts()
        if cleaned and cleaned > 0 then
            GBankClassic_Core:Printf("Cleaned %d malformed alt entries from saved database", cleaned)
        end
    end
end

function GBankClassic_Events:BANKFRAME_OPENED(_)
    GBankClassic_Bank:OnUpdateStart()
end

function GBankClassic_Events:BANKFRAME_CLOSED(_)
    GBankClassic_Bank:OnUpdateStop()
end

function GBankClassic_Events:MAIL_SHOW(_)
    GBankClassic_Bank:OnUpdateStart()
    GBankClassic_Mail.isOpen = true
    GBankClassic_Mail:Check()
end

function GBankClassic_Events:MAIL_INBOX_UPDATE(_)
    GBankClassic_Mail:Scan()
end

function GBankClassic_Events:MAIL_CLOSED(_)
    GBankClassic_Mail.isOpen = false
    GBankClassic_Mail.isScanning = false
    GBankClassic_Bank:OnUpdateStop()
    GBankClassic_UI_Mail:Close()
end

function GBankClassic_Events:TRADE_SHOW(_)
    GBankClassic_Bank:OnUpdateStart()
end

function GBankClassic_Events:TRADE_CLOSED(_)
    -- FIXME: Isn't rescanning?
    GBankClassic_Bank:OnUpdateStop()
end

function GBankClassic_Events:AUCTION_HOUSE_SHOW(_)
    GBankClassic_Bank:OnUpdateStart()
end

function GBankClassic_Events:AUCTION_HOUSE_CLOSED(_)
    GBankClassic_Bank:OnUpdateStop()
end

function GBankClassic_Events:MERCHANT_SHOW(_)
    GBankClassic_Bank:OnUpdateStart()
end

function GBankClassic_Events:MERCHANT_CLOSED(_)
    GBankClassic_Bank:OnUpdateStop()
end

--close frame on combat
function GBankClassic_Events:PLAYER_REGEN_DISABLED(_)
    if GBankClassic_Options:GetCombatHide() then
        GBankClassic_UI_Inventory:Close()
    end
end