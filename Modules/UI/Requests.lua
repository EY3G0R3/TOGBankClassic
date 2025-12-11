TOGBankClassic_UI_Requests = {}

local COLUMNS = {
    {key = "date", label = "Date", width = 150, align = "center"},
    {key = "requester", label = "Requester", width = 140, align = "center"},
    {key = "bank", label = "Bank", width = 140, align = "center"},
    {key = "quantity", label = "#", width = 60, align = "end"},
    {key = "item", label = "Item", width = 240, align = "start"},
    {key = "fulfilled", label = "Fulfilled", width = 110, align = "end"},
    {key = "notes", label = "Notes", width = 200, align = "start"},
}

local function ColumnLayout()
    local cols = {}
    for _, col in ipairs(COLUMNS) do
        table.insert(cols, {width = col.width, align = col.align or "start"})
    end
    return cols
end

local function justifyForAlign(align)
    align = tostring(align or "start"):lower()
    if align == "end" or align == "right" then
        return "RIGHT"
    end
    if align == "center" or align == "middle" then
        return "CENTER"
    end
    return "LEFT"
end

local function OnClose(_)
    TOGBankClassic_UI_Requests.isOpen = false
    if TOGBankClassic_UI_Requests.Window then
        TOGBankClassic_UI_Requests.Window:Hide()
    end
end

function TOGBankClassic_UI_Requests:Init()
    self.sortColumn = "date"
    self.sortDirection = "desc"
    self:DrawWindow()
end

function TOGBankClassic_UI_Requests:Toggle()
    if self.isOpen then
        self:Close()
    else
        self:Open()
    end
end

function TOGBankClassic_UI_Requests:Open()
    if self.isOpen then return end
    self.isOpen = true

    if not self.Window then
        self:DrawWindow()
    end

    self.Window:Show()

    if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen and TOGBankClassic_UI_Inventory.Window then
        self.Window:ClearAllPoints()
        self.Window:SetPoint("TOPLEFT", TOGBankClassic_UI_Inventory.Window.frame, "TOPRIGHT", 0, 0)
    end

    self:DrawContent()

    if _G["TOGBankClassic"] then
        _G["TOGBankClassic"]:Show()
    else
        TOGBankClassic_UI:Controller()
    end
end

function TOGBankClassic_UI_Requests:Close()
    if not self.isOpen then return end
    if not self.Window then return end

    OnClose(self.Window)

    if TOGBankClassic_UI_Inventory.isOpen == false then
        _G["TOGBankClassic"]:Hide()
    end
end

function TOGBankClassic_UI_Requests:DrawWindow()
    local window = TOGBankClassic_UI:Create("Frame")
    window:Hide()
    window:SetCallback("OnClose", OnClose)
    window:SetTitle("Requests")
    window:SetLayout("Fill")
    window:SetWidth(1200)
    window:EnableResize(false)
    self.Window = window

    local tableFrame = TOGBankClassic_UI:Create("ScrollFrame")
    tableFrame:SetLayout("Table")
    tableFrame:SetUserData("table", {
        columns = ColumnLayout(),
        spaceH = 5,
        spaceV = 2,
    })
    tableFrame:SetFullWidth(true)
    tableFrame:SetFullHeight(true)

    tableFrame.scrollframe:ClearAllPoints()
    tableFrame.scrollframe:SetPoint("TOPLEFT", 8, -8)
    tableFrame.scrollbar:ClearAllPoints()
    tableFrame.scrollbar:SetPoint("TOPLEFT", tableFrame.scrollframe, "TOPRIGHT", -6, -12)
    tableFrame.scrollbar:SetPoint("BOTTOMLEFT", tableFrame.scrollframe, "BOTTOMRIGHT", -6, 22)

    window:AddChild(tableFrame)
    self.Content = tableFrame
end

local function valueForSort(request, key)
    if key == "date" or key == "quantity" or key == "fulfilled" then
        return tonumber(request[key] or 0) or 0
    end
    return tostring(request[key] or ""):lower()
end

local function isComplete(request)
    local qty = tonumber(request.quantity or 0) or 0
    local fulfilled = tonumber(request.fulfilled or 0) or 0
    return fulfilled >= qty and qty > 0
end

function TOGBankClassic_UI_Requests:SortedRequests()
    local info = TOGBankClassic_Guild.Info
    if not info or not info.requests then
        return {}
    end

    local list = {}
    for _, req in ipairs(info.requests) do
        table.insert(list, req)
    end

    local column = self.sortColumn or "date"
    local direction = self.sortDirection or "desc"

    table.sort(list, function(a, b)
        local va = valueForSort(a, column)
        local vb = valueForSort(b, column)
        if va == vb then
            return valueForSort(a, "date") > valueForSort(b, "date")
        end
        if direction == "asc" then
            return va < vb
        end
        return va > vb
    end)

    return list
end

local function colorize(text, completed)
    local color = completed and "ff7f7f7f" or "ffffffff"
    return string.format("|c%s%s|r", color, text)
end

function TOGBankClassic_UI_Requests:DrawHeader()
    if not self.Content then return end

    for _, col in ipairs(COLUMNS) do
        local label = col.label
        if self.sortColumn == col.key then
            label = label .. (self.sortDirection == "asc" and " ^" or " v")
        end

        local button = TOGBankClassic_UI:Create("Button")
        button:SetText(label)
        button:SetWidth(col.width - 5)
        if button.text and button.text.SetJustifyH then
            button.text:SetJustifyH(justifyForAlign(col.align))
        end
        button:SetCallback("OnClick", function()
            if self.sortColumn == col.key then
                self.sortDirection = (self.sortDirection == "asc") and "desc" or "asc"
            else
                self.sortColumn = col.key
                self.sortDirection = "desc"
            end
            self:DrawContent()
        end)
        self.Content:AddChild(button)
    end
end

function TOGBankClassic_UI_Requests:DrawContent()
    if not self.Content or not self.Window then return end

    self.Content:ReleaseChildren()
    self.Window:SetStatusText("")

    self:DrawHeader()

    local sorted = self:SortedRequests()
    if #sorted == 0 then
        local empty = TOGBankClassic_UI:Create("Label")
        empty:SetText("No requests yet.")
        empty:SetFullWidth(true)
        self.Content:AddChild(empty)
        self.Window:SetStatusText("0 Requests")
        return
    end

    local count = 0
    for _, req in ipairs(sorted) do
        local completed = isComplete(req)
        local ts = tonumber(req.date or 0) or 0
        local dateText = ts > 0 and date("%Y-%m-%d %H:%M", ts) or "Unknown"
        if completed then
            dateText = "✔ " .. dateText
        end

        local cells = {
            dateText,
            req.requester or "",
            req.bank or "",
            tostring(req.quantity or ""),
            req.item or "",
            tostring(req.fulfilled or ""),
            req.notes or "",
        }

        for idx, cell in ipairs(cells) do
            local col = COLUMNS[idx]
            local label = TOGBankClassic_UI:Create("Label")
            label:SetText(colorize(cell, completed))
            label.label:SetHeight(18)
            label.label:SetJustifyH(justifyForAlign(col and col.align))
            self.Content:AddChild(label)
        end

        count = count + 1
    end

    local status = string.format("%d Request%s", count, count == 1 and "" or "s")
    self.Window:SetStatusText(status)
end
