GBankClassic_UI_Search = {}

function GBankClassic_UI_Search:Init()
    self:DrawWindow()
end

local function OnClose(_)
    GBankClassic_UI_Search.isOpen = false
    GBankClassic_UI_Search.Window:Hide()
end

function GBankClassic_UI_Search:Toggle()
    if self.isOpen then
        self:Close()
    else
        self:Open()
    end
end

function GBankClassic_UI_Search:Open()
    if self.isOpen then return end
    self.isOpen = true

    if not self.Window then
        self:DrawWindow()
    end

    self.Window:Show()
    if GBankClassic_UI_Inventory.isOpen and GBankClassic_UI_Inventory.Window then
        self.Window:ClearAllPoints()
        self.Window:SetPoint("TOPRIGHT", GBankClassic_UI_Inventory.Window.frame, "TOPLEFT", 0, 0)
    end

    self:DrawContent()

    self.searchField:SetFocus()

    if _G["GBankClassic"] then
        _G["GBankClassic"]:Show()
    else
        GBankClassic_UI:Controller()
    end
end

function GBankClassic_UI_Search:Close()
    if not self.isOpen then return end
    if not self.Window then return end

    OnClose(self.Window)

    if GBankClassic_UI_Inventory.isOpen == false then
        _G["GBankClassic"]:Hide()
    end
end

function GBankClassic_UI_Search:DrawWindow()
    local searchWindow = GBankClassic_UI:Create("Frame")
    searchWindow:Hide()
    searchWindow:SetCallback("OnClose", OnClose)
    searchWindow:SetTitle("Search")
    searchWindow:SetLayout("Flow")
    searchWindow:SetWidth(250)
    searchWindow:EnableResize(false)

    self.Window = searchWindow

    local searchInput = GBankClassic_UI:Create("EditBox")
    searchInput:SetMaxLetters(50)
    searchInput:SetLabel("Item Name")
    searchInput:SetCallback("OnTextChanged", function (input)
        self.SearchText = input:GetText()
        self:DrawContent()
    end)
    searchInput:SetCallback("OnEnterPressed", function (input)
        self.SearchText = input:GetText()
        self:DrawContent()
        self.searchField:ClearFocus()
    end)
    searchInput:SetFullWidth(true)
    searchInput.editbox:SetScript("OnReceiveDrag", function (input)
        local type, _, info = GetCursorInfo()
        if type == "item" then
            self.SearchText = info
            self:DrawContent()
            ClearCursor()
            self.searchField:ClearFocus()
        end
    end)

    self.searchField = searchInput

    searchWindow:AddChild(searchInput)

    local scrollGroup = GBankClassic_UI:Create("SimpleGroup")
    scrollGroup:SetLayout("Fill")
    scrollGroup:SetFullWidth(true)
    scrollGroup:SetFullHeight(true)
    searchWindow:AddChild(scrollGroup)

    local resultGroup = GBankClassic_UI:Create("ScrollFrame")
    resultGroup:SetLayout("Table")
    resultGroup:SetUserData("table", {
        columns = {
            {
                width = 35,
                align = "middle",
            },
            {
                align = "start",
            },
        },
        spaceH = 30,
    })

    resultGroup.scrollframe:ClearAllPoints()
    resultGroup.scrollframe:SetPoint("TOPLEFT",  10, -10)

    resultGroup.scrollbar:ClearAllPoints()
    resultGroup.scrollbar:SetPoint("TOPLEFT", resultGroup.scrollframe, "TOPRIGHT", -6, -12)
    resultGroup.scrollbar:SetPoint("BOTTOMLEFT", resultGroup.scrollframe, "BOTTOMRIGHT", -6, 22)
    scrollGroup:AddChild(resultGroup)

    self.Results = resultGroup
end

function GBankClassic_UI_Search:BuildSearchData()
    self.SearchData = {
        Corpus = {},
        Lookup = {},
    }

    local info = GBankClassic_Guild.Info
    if not info or not info.roster.version then
        return
    end

    local items = {}
    for _, player in pairs(info.roster.alts) do
        local norm = (GBankClassic_Guild and GBankClassic_Guild.NormalizePlayerName) and GBankClassic_Guild.NormalizePlayerName(player) or player
        local alt = info.alts[norm]
        ---START CHANGES
        --if alt then
        if alt and type(alt) == "table" then
            ---END CHANGES
            if alt.bank then
                items = GBankClassic_Item:Aggregate(items, alt.bank.items)
            end
            if alt.bags then
                items = GBankClassic_Item:Aggregate(items, alt.bags.items)
            end
        end
    end

    local itemNames = {}
    GBankClassic_Item:GetItems(items, function (list)
        for _, v in pairs(list) do
            -- Skip malformed list entries
            if v and v.ID and v.Info and v.Info.name and not itemNames[v.ID] then
                table.insert(self.SearchData.Corpus, v.Info.name)
                itemNames[v.ID] = v.Info.name
            end
        end

        for _, player in pairs(info.roster.alts) do
            local altItems = {}
            local norm = (GBankClassic_Guild and GBankClassic_Guild.NormalizePlayerName) and GBankClassic_Guild.NormalizePlayerName(player) or player
            local alt = info.alts[norm]
            ---START CHANGES
            --if alt then
            if alt and type(alt) == "table" then
                ---END CHANGES
                if alt.bank then
                    altItems = GBankClassic_Item:Aggregate(altItems, alt.bank.items)
                end
                if alt.bags then
                    altItems = GBankClassic_Item:Aggregate(altItems, alt.bags.items)
                end
            end

            for _, itemEntry in pairs(altItems) do
                local name = itemNames[itemEntry.ID]
                if name then
                    if not self.SearchData.Lookup[name] then
                        self.SearchData.Lookup[name] = {}
                    end
                    local found = false
                    for _, existingEntry in pairs(self.SearchData.Lookup[name]) do
                        if existingEntry.alt == player then
                            found = true
                            break
                        end
                    end
                    if not found then
                        local info = GBankClassic_Item:GetInfo(itemEntry.ID, itemEntry.Link)
                        table.insert(self.SearchData.Lookup[name], {alt = player, item = {ID = itemEntry.ID, Count = itemEntry.Count, Link = itemEntry.Link, Info = info}})
                    end
                end
            end
        end
    end)
end

function GBankClassic_UI_Search:DrawContent()
    if not self.Results then return end

    self.Results:ReleaseChildren()
    self.Window:SetStatusText("")
    self.Results:DoLayout()

    if not self.SearchText then return end

    --retain search input after close
    if self.SearchText then
        self.searchField:SetText(self.SearchText)
        local searchLength = string.len(self.SearchText)
        self.searchField.editbox:SetCursorPosition(searchLength)
    end

    local search = self.SearchText
    if string.sub(search, 0, 2) == "|c" then
        self.searchField:SetText("")
        local item = Item:CreateFromItemLink(search)
        item:ContinueOnItemLoad(function()
            local name = item:GetItemName()
            self.SearchText = name
            self.searchField:SetText(name)
            self:DrawContent()
            self.searchField:ClearFocus()
        end)
        return
    end

    local searchText = search:lower()

    if string.len(searchText) < 3 then return end

    local searchData = self.SearchData
    if not searchData then return end

    local count = 0
    for _, v in pairs(searchData.Corpus) do
        if not v then
            -- Skip malformed corpus entries
        else
            local result = string.find(v:lower(), searchText)
            if result ~= nil then
                local lookupList = searchData.Lookup[v]
                if not lookupList then
                    -- No lookup for this name; skip
                else
                    for _, vv in pairs(lookupList) do
                        --draw item larger to add pading - icon and label smaller by the same to get dimensions
                        GBankClassic_UI:DrawItem(vv.item, self.Results, 30, 35, 30, 30, 0, 5)

                        local label = GBankClassic_UI:Create("Label")
                        label:SetText(vv.alt)
                        label.label:SetSize(100, 30)
                        label.label:SetJustifyV("MIDDLE")
                        self.Results:AddChild(label)

                        count = count + 1
                    end
                end
            end
        end
    end

    local status = count .. " Result"
    if count > 1 then
        status = status .. "s"
    end
    self.Window:SetStatusText(status)

    --redo layout after all items are loaded to get scroll bar to load
    self.Results:DoLayout()
end
