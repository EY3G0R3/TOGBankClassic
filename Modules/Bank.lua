GBankClassic_Bank = {...}

local function IsBankAvailable()
    ---START CHANGES
    local _, bagType = C_Container.GetContainerNumFreeSlots(BANK_CONTAINER)
    ---END CHANGES
    return bagType ~= nil
end

local function HasUpdated()
    return GBankClassic_Bank.hasUpdated
end

local function ScanBag(bag, slots)
    local count = 0
    local items = {}
    for slot = 1, slots do
        ---START CHANGES
        local itemInfo = C_Container.GetContainerItemInfo(bag, slot)
        if itemInfo then 
            local itemCount = itemInfo.stackCount
            local itemLink = itemInfo.hyperlink
            local itemID = itemInfo.itemID
            ---END CHANGES
            if itemLink then
                local key = itemID .. itemLink
                if items[key] then
                    local item = items[key]
                    items[key] = {ID = item.ID, Count = item.Count + itemCount, Link = item.Link}
                else
                    items[key] = {ID = itemID, Count = itemCount, Link = itemLink}
                end
                count = count + 1
            end
        end
    end
    return count, items
end

local function ScanBags(bag_info)
    local total = 0
    local numslots = 0
    local bagItems = nil
    for bag = 0, 4 do
        ---START CHANGES
        local slots = C_Container.GetContainerNumSlots(bag)
        ---END CHANGES
        local count, items = ScanBag(bag, slots)
        if bagItems == nil then
            bagItems = items
        else
            for k, v in pairs(items) do
                if bagItems[k] then
                    local item = bagItems[k]
                    bagItems[k] = {ID = item.ID, Count = item.Count + v.Count, Link = item.Link}
                else
                    bagItems[k] = v
                end
            end
        end
        total = total + count
        numslots = numslots + slots
    end

    for _, v in pairs(bagItems) do
        table.insert(bag_info, v)
    end

    return total, numslots
end

local function ScanBank(bank_info)
    local numslots = NUM_BANKGENERIC_SLOTS
    local total, bankItems = ScanBag(BANK_CONTAINER, NUM_BANKGENERIC_SLOTS)
    for bag = 5, 11 do
        ---START CHANGES
        local slots = C_Container.GetContainerNumSlots(bag)
        ---END CHANGES
        local count, items = ScanBag(bag, slots)
        for k, v in pairs(items) do
            if bankItems[k] then
                local item = bankItems[k]
                bankItems[k] = {ID = item.ID, Count = item.Count + v.Count, Link = item.Link}
            else
                bankItems[k] = v
            end
        end
        total = total + count
        numslots = numslots + slots
    end

    for _, v in pairs(bankItems) do
        table.insert(bank_info, v)
    end

    return total, numslots
end

function GBankClassic_Bank:Scan()
    if GBankClassic_Bank.eventsRegistered then
        if not HasUpdated() then
            return
        end
    end

    local info = GBankClassic_Guild.Info
    if not info then return end

    local player = GBankClassic_Guild:GetPlayer()
    -- normalize player name to ensure consistent keying in saved DB
    if player then player = (GBankClassic_Guild and GBankClassic_Guild.NormalizePlayerName) and GBankClassic_Guild.NormalizePlayerName(player) or player end

    local isBank = false
    local banks = GBankClassic_Guild:GetBanks()
    if banks == nil then return end
    for _, v in pairs(banks) do
        local normV = (GBankClassic_Guild and GBankClassic_Guild.NormalizePlayerName) and GBankClassic_Guild.NormalizePlayerName(v) or v
        if normV == player then
            isBank = true
            break
        end
    end
    if not isBank then return end
    if not GBankClassic_Options:GetBankEnabled() then return end

    local updateRoster = false
    if info.roster["version"] ~= nil then
        if table.concat(banks) ~= table.concat(info.roster.alts) then
            updateRoster = true
        end
    else
        updateRoster = true
    end

    if updateRoster then
        info.roster.alts = banks
        info.roster.version = GetServerTime()
    end

    local alt = {}
    if info.alts[player] then
        alt = info.alts[player]
    end

    local total = 0
    local numslots = 0

    if IsBankAvailable() then
        alt.bank = {
            items = {},
            slots = {}
        }
        local count, slots = ScanBank(alt.bank.items)
        alt.bank.slots = {count = count, total = slots}
        total = total + count
        numslots = numslots + slots
    end

    alt.bags = {
        items = {},
        slots = {}
    }
    local count, slots = ScanBags(alt.bags.items)
    alt.bags.slots = {count = count, total = slots}
    total = total + count
    numslots = numslots + slots

    local money = GetMoney()
    alt.money = money

    alt.version = GetServerTime()

    info.alts[player] = alt
end

function GBankClassic_Bank:HasInventorySpace()
    local total = 0
    for bag = 0, 4 do
        ---START CHANGES
        local slots, _ = C_Container.GetContainerNumFreeSlots(bag)
        ---END CHANGES
        total = total + slots
    end
    return total > 0
end

function GBankClassic_Bank:OnUpdateStart()
    self.hasUpdated = true
end

function GBankClassic_Bank:OnUpdateStop()
    if self.hasUpdated then
        self:Scan()
    end
    self.hasUpdated = false
end
