TOGBankClassic_UI_Search = {}

function TOGBankClassic_UI_Search:Init()
    self:DrawWindow()
end

local function OnClose(_)
    TOGBankClassic_UI_Search.isOpen = false
    TOGBankClassic_UI_Search.Window:Hide()
    if TOGBankClassic_UI_Search.RequestDialog then
        TOGBankClassic_UI_Search.RequestDialog:Hide()
    end
end

-- Build (once) and show the request dialog for clicking search results
function TOGBankClassic_UI_Search:EnsureRequestDialog()
    if self.RequestDialog then return end

    local dialog = TOGBankClassic_UI:Create("Frame")
    dialog:Hide()
    dialog:SetTitle("Item Request")
    dialog:SetLayout("List")
    dialog:SetWidth(340)
    dialog:SetHeight(200)
    dialog:EnableResize(false)
    dialog:SetCallback("OnClose", function(widget) widget:Hide() end)
    dialog.frame:SetBackdropColor(0, 0, 0, 1)
    dialog.frame:SetAlpha(1)

    local prompt = TOGBankClassic_UI:Create("Label")
    prompt:SetFullWidth(true)
    prompt:SetText("")
    prompt:SetJustifyH("LEFT")
    if prompt.label and prompt.label.SetWordWrap then
        prompt.label:SetWordWrap(true)
    end
    dialog:AddChild(prompt)
    dialog.Prompt = prompt

    local quantityInput = TOGBankClassic_UI:Create("Slider")
    quantityInput:SetLabel("Quantity")
    quantityInput:SetSliderValues(1, 1, 1)
    quantityInput:SetValue(1)
    quantityInput:SetFullWidth(true)
    if quantityInput.editbox and quantityInput.editbox.HookScript then
        quantityInput.editbox:HookScript("OnEnterPressed", function()
            self:SubmitRequest()
        end)
    end
    dialog:AddChild(quantityInput)
    dialog.QuantityInput = quantityInput

    local availableLabel = TOGBankClassic_UI:Create("Label")
    availableLabel:SetFullWidth(true)
    availableLabel:SetJustifyH("LEFT")
    availableLabel:SetText("")
    dialog:AddChild(availableLabel)
    dialog.AvailableLabel = availableLabel

    local buttons = TOGBankClassic_UI:Create("SimpleGroup")
    buttons:SetLayout("Table")
    buttons:SetUserData("table", {
        columns = {
            {width = 0.5, align = "start"},
            {width = 0.5, align = "end"},
        },
    })
    buttons:SetFullWidth(true)
    dialog:AddChild(buttons)

    local save = TOGBankClassic_UI:Create("Button")
    save:SetText("Save Request")
    save:SetWidth(140)
    save:SetCallback("OnClick", function() self:SubmitRequest() end)
    buttons:AddChild(save)

    local cancel = TOGBankClassic_UI:Create("Button")
    cancel:SetText("Cancel")
    cancel:SetWidth(120)
    cancel:SetCallback("OnClick", function() dialog:Hide() end)
    buttons:AddChild(cancel)

    self.RequestDialog = dialog
end

function TOGBankClassic_UI_Search:ShowRequestDialog(itemEntry, bankAlt)
    if not itemEntry or not itemEntry.Info or not bankAlt then return end

    self:EnsureRequestDialog()

    local itemName = itemEntry.Info.name or (itemEntry.Link and itemEntry.Link:match("%[(.-)%]")) or "Unknown item"
    self.requestContext = {
        item = itemEntry,
        bank = bankAlt,
        itemName = itemName,
        available = tonumber(itemEntry.Count) or 0,
    }

    local itemLabel = itemEntry.Link or itemName
    local prompt = string.format("Request how many %s from %s?", itemLabel, bankAlt)
    self.RequestDialog.Prompt:SetText(prompt)
    local available = self.requestContext.available
    local minQuantity = available > 0 and 1 or 0
    local maxQuantity = available > 0 and available or 0
    if maxQuantity < minQuantity then
        maxQuantity = minQuantity
    end
    self.RequestDialog.QuantityInput:SetSliderValues(minQuantity, maxQuantity, 1)
    self.RequestDialog.QuantityInput:SetValue(minQuantity > 0 and 1 or 0)
    self.RequestDialog.QuantityInput:SetDisabled(maxQuantity == 0)
    if self.RequestDialog.AvailableLabel then
        if available > 0 then
            self.RequestDialog.AvailableLabel:SetText(string.format("Available: %d", available))
        else
            self.RequestDialog.AvailableLabel:SetText("Available: none right now")
        end
    end
    self.RequestDialog:SetStatusText("")
    self.RequestDialog:Show()
    self.RequestDialog:DoLayout()
    if self.RequestDialog.QuantityInput.editbox and self.RequestDialog.QuantityInput.editbox.SetFocus then
        self.RequestDialog.QuantityInput.editbox:SetFocus()
        self.RequestDialog.QuantityInput.editbox:HighlightText()
    end
end

function TOGBankClassic_UI_Search:SubmitRequest()
    if not self.requestContext or not self.RequestDialog then return end

    local quantity = tonumber(self.RequestDialog.QuantityInput:GetValue())
    local available = tonumber(self.requestContext.available) or 0
    if not quantity or quantity <= 0 then
        self.RequestDialog:SetStatusText("Enter a quantity greater than 0.")
        return
    end
    if available > 0 and quantity > available then
        quantity = available
    end

    local requester = TOGBankClassic_Guild:GetPlayer()
    if not requester then
        local name, realm = UnitName("player"), GetNormalizedRealmName()
        if name then
            requester = realm and (name .. "-" .. realm) or name
        end
    end

    local normalize = TOGBankClassic_Guild.NormalizePlayerName
    if normalize then
        if requester then requester = normalize(requester) end
    end

    local bank = self.requestContext.bank
    if normalize then
        bank = normalize(bank)
    end

    local request = {
        date = GetServerTime(),
        requester = requester or "Unknown",
        bank = bank or self.requestContext.bank,
        item = self.requestContext.itemName,
        quantity = quantity,
        fulfilled = 0,
        notes = "",
    }

    if not TOGBankClassic_Guild:AddRequest(request) then
        self.RequestDialog:SetStatusText("Unable to save request.")
        return
    end

    self.RequestDialog:Hide()
    self.requestContext = nil

    TOGBankClassic_Core:Printf("Requested %d x %s from %s", quantity, request.item, request.bank)
end

function TOGBankClassic_UI_Search:Toggle()
    if self.isOpen then
        self:Close()
    else
        self:Open()
    end
end

function TOGBankClassic_UI_Search:Open()
    if self.isOpen then return end
    self.isOpen = true

    if not self.Window then
        self:DrawWindow()
    end

    self.Window:Show()
    if TOGBankClassic_UI_Inventory.isOpen and TOGBankClassic_UI_Inventory.Window then
        self.Window:ClearAllPoints()
        self.Window:SetPoint("TOPRIGHT", TOGBankClassic_UI_Inventory.Window.frame, "TOPLEFT", 0, 0)
    end

    self:DrawContent()

    self.searchField:SetFocus()

    if _G["TOGBankClassic"] then
        _G["TOGBankClassic"]:Show()
    else
        TOGBankClassic_UI:Controller()
    end
end

function TOGBankClassic_UI_Search:Close()
    if not self.isOpen then return end
    if not self.Window then return end

    OnClose(self.Window)

    if TOGBankClassic_UI_Inventory.isOpen == false then
        _G["TOGBankClassic"]:Hide()
    end
end

function TOGBankClassic_UI_Search:DrawWindow()
    local searchWindow = TOGBankClassic_UI:Create("Frame")
    searchWindow:Hide()
    searchWindow:SetCallback("OnClose", OnClose)
    searchWindow:SetTitle("Search")
    searchWindow:SetLayout("Flow")
    searchWindow:SetWidth(250)
    searchWindow:EnableResize(false)

    self.Window = searchWindow

    local searchInput = TOGBankClassic_UI:Create("EditBox")
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

    local scrollGroup = TOGBankClassic_UI:Create("SimpleGroup")
    scrollGroup:SetLayout("Fill")
    scrollGroup:SetFullWidth(true)
    scrollGroup:SetFullHeight(true)
    searchWindow:AddChild(scrollGroup)

    local resultGroup = TOGBankClassic_UI:Create("ScrollFrame")
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

function TOGBankClassic_UI_Search:BuildSearchData()
    self.SearchData = {
        Corpus = {},
        Lookup = {},
    }

    local info = TOGBankClassic_Guild.Info
    if not info or not info.roster.version then
        return
    end

    local items = {}
    for _, player in pairs(info.roster.alts) do
        local norm = (TOGBankClassic_Guild and TOGBankClassic_Guild.NormalizePlayerName) and TOGBankClassic_Guild.NormalizePlayerName(player) or player
        local alt = info.alts[norm]
        ---START CHANGES
        --if alt then
        if alt and type(alt) == "table" then
            ---END CHANGES
            if alt.bank then
                items = TOGBankClassic_Item:Aggregate(items, alt.bank.items)
            end
            if alt.bags then
                items = TOGBankClassic_Item:Aggregate(items, alt.bags.items)
            end
        end
    end

    local itemNames = {}
    TOGBankClassic_Item:GetItems(items, function (list)
        for _, v in pairs(list) do
            -- Skip malformed list entries
            if v and v.ID and v.Info and v.Info.name and not itemNames[v.ID] then
                table.insert(self.SearchData.Corpus, v.Info.name)
                itemNames[v.ID] = v.Info.name
            end
        end

        for _, player in pairs(info.roster.alts) do
            local altItems = {}
            local norm = (TOGBankClassic_Guild and TOGBankClassic_Guild.NormalizePlayerName) and TOGBankClassic_Guild.NormalizePlayerName(player) or player
            local alt = info.alts[norm]
            ---START CHANGES
            --if alt then
            if alt and type(alt) == "table" then
                ---END CHANGES
                if alt.bank then
                    altItems = TOGBankClassic_Item:Aggregate(altItems, alt.bank.items)
                end
                if alt.bags then
                    altItems = TOGBankClassic_Item:Aggregate(altItems, alt.bags.items)
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
                        local info = TOGBankClassic_Item:GetInfo(itemEntry.ID, itemEntry.Link)
                        table.insert(self.SearchData.Lookup[name], {alt = player, item = {ID = itemEntry.ID, Count = itemEntry.Count, Link = itemEntry.Link, Info = info}})
                    end
                end
            end
        end
    end)
end

function TOGBankClassic_UI_Search:DrawContent()
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
                        local resultItem = vv.item
                        local bankAlt = vv.alt
                        local itemWidget = TOGBankClassic_UI:DrawItem(resultItem, self.Results, 30, 35, 30, 30, 0, 5)
                        if itemWidget then
                            itemWidget:SetCallback("OnClick", function(widget, event)
                                if IsShiftKeyDown() or IsControlKeyDown() then
                                    TOGBankClassic_UI:EventHandler(widget, event)
                                    return
                                end
                                TOGBankClassic_UI_Search:ShowRequestDialog(resultItem, bankAlt)
                            end)
                        end

                        local label = TOGBankClassic_UI:Create("Label")
                        label:SetText(bankAlt)
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
