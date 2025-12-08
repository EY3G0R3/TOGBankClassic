GBankClassic_Mail = {}

function GBankClassic_Mail:Check()
    CheckInbox()
end

function GBankClassic_Mail:Scan()
    if not GBankClassic_Options:GetDonationEnabled() then return end

    if not GBankClassic_Mail.isOpen then return end
    if self.isScanning then return end

    local info = GBankClassic_Guild.Info
    if not info then return end

    local player = GBankClassic_Guild:GetPlayer()

    local isBank = false
    local banks = GBankClassic_Guild:GetBanks()
    if banks == nil then return end
    self.Roster = {}
    for _, v in pairs(banks) do
        local norm = (GBankClassic_Guild and GBankClassic_Guild.NormalizePlayerName) and GBankClassic_Guild.NormalizePlayerName(v) or v
        self.Roster[norm] = true
        if norm == player then
            isBank = true
        end
    end
    if not isBank then return end
    if not GBankClassic_Options:GetBankEnabled() then return end

    self.isScanning = true

    local numItems, totalItems = GetInboxNumItems()

    if numItems > 0 then
        for mailId = 1, numItems do
            local _, _, sender, _, money, CODAmount, _, itemCount, _, wasReturned, _, canReply, isGM = GetInboxHeaderInfo(mailId)
            if not sender then
                GBankClassic_Mail:ResetScan()
                return
            end

            if CODAmount == 0
                    and not wasReturned
                    and not isGM
                    and canReply
                    and not self.Roster[sender]
                    and (money > 0 or (itemCount and itemCount > 0)) then

                local hasNonUnique = nil
                if itemCount and itemCount > 0 then
                    for attachmentIndex = 1, ATTACHMENTS_MAX_RECEIVE do
                        local link = GetInboxItemLink(mailId, attachmentIndex)
                        if link then
                            local isUnique = GBankClassic_Item:IsUnique(link)
                            if not isUnique then
                                hasNonUnique = true
                                break
                            elseif hasNonUnique == nil then
                                hasNonUnique = false
                            end
                        end
                    end
                end

                if hasNonUnique == nil or hasNonUnique then
                    GBankClassic_UI_Mail:SetMailId(mailId)
                    GBankClassic_UI_Mail:Open()
                    return
                end
            end
        end
    end
end

function GBankClassic_Mail:ResetScan()
    -- have to wait for server to remove item from inbox before we can take another
    -- so we wait a second before trying the next item
    GBankClassic_Core:ScheduleTimer(function (...) GBankClassic_Mail:OnTimer() end, 1)
end

function GBankClassic_Mail:OnTimer()
    self.isScanning = false
    GBankClassic_Mail:Scan()
end

function GBankClassic_Mail:Open(mailId)
    local _, _, sender, _, money, _, _, itemCount, _, _, _, _, _, _ = GetInboxHeaderInfo(mailId)
    if not sender then
        GBankClassic_Mail:RetryOpen(mailId)
        return
    end

    local info = GBankClassic_Guild.Info
    ---START CHANGES
    if not info then return end
    ---END CHANGES
    local player = GBankClassic_Guild:GetPlayer()
    local norm = (GBankClassic_Guild and GBankClassic_Guild.NormalizePlayerName) and GBankClassic_Guild.NormalizePlayerName(player) or player

    if not info.alts[norm] then
        info.alts[norm] = {}
    end

    local alt = info.alts[norm]

    if not alt.ledger then
        alt.ledger = {}
    end

    local ledger = alt.ledger

    local current_score = 0
    if ledger[sender] then
        current_score = ledger[sender]
    end

    local score = 0
    if money > 0 then
        -- convert from copper to gold
        score = money / 10000

        if GBankClassic_Options:GetBankReporting() then
            GBankClassic_Core:Printf("Received %s gold from %s", score, sender)
        end

        if GBankClassic_UI_Mail.ScoreMail and not self.Roster[sender] then
            ledger[sender] = current_score + score
        end

        TakeInboxMoney(mailId)
        if itemCount and itemCount > 0 then
            GBankClassic_Mail:RetryOpen(mailId)
            return
        end
    end
    if itemCount then
        if not GBankClassic_Bank:HasInventorySpace() then
            GBankClassic_Core:Print("Inventory is full.")
            return
        end

        for attachmentIndex = 1, ATTACHMENTS_MAX_RECEIVE do
            local link = GetInboxItemLink(mailId, attachmentIndex)
            if link then
                local _, _, _, quantity, _ = GetInboxItem(mailId, attachmentIndex)
                local name, _, quality, level, _, _, _, _, _, _, price = GetItemInfo(link)
                if level == nil then
                    GBankClassic_Mail:RetryOpen(mailId)
                    return
                end

                if not GBankClassic_Item:IsUnique(link) then
                    score = ((price + 1) / 10000) * quantity

                    if GBankClassic_Options:GetBankReporting() then
                        GBankClassic_Core:Printf("Received %s (%d) from %s", name, quantity, sender)
                    end

                    if GBankClassic_UI_Mail.ScoreMail and not self.Roster[sender] then
                        ledger[sender] = current_score + score
                    end

                    TakeInboxItem(mailId, attachmentIndex)
                    if itemCount > 1 then
                        GBankClassic_Mail:RetryOpen(mailId)
                        return
                    end
                end
            end
        end
    end

    GBankClassic_UI_Mail:Close()
    GBankClassic_Mail:ResetScan()
end

function GBankClassic_Mail:RetryOpen(mailId)
    -- have to wait for server to remove item from inbox before we can take another
    -- so we wait a second before trying the next item
    GBankClassic_Core:ScheduleTimer(function (...) GBankClassic_Mail:OnRetryTimer(mailId) end, 1)
end

function GBankClassic_Mail:OnRetryTimer(mailId)
    GBankClassic_Mail:Open(mailId)
end