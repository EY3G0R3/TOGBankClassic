TOGBankClassic_UI_Requests = {}

local COLUMNS = {
    {key = "date", label = "Date", width = 140},
    {key = "requester", label = "Requester", width = 120},
    {key = "bank", label = "Bank", width = 120},
    {key = "item", label = "Item", width = 220},
    {key = "quantity", label = "Qty", width = 60},
    {key = "fulfilled", label = "Fulfilled", width = 80},
    {key = "notes", label = "Notes", width = 200},
}

function TOGBankClassic_UI_Requests:Init()
    self.sortColumn = "date"
    self.sortDirection = "desc"
    self:DrawWindow()
end

local function OnClose(_)
    TOGBankClassic_UI_Requests.isOpen = false
    TOGBankClassic_UI_Requests.Window:Hide()
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
    if TOGBankClassic_UI_Inventory.isOpen and TOGBankClassic_UI_Inventory.Window then
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

local function ColumnLayout()
    local cols = {}
    for _, col in ipairs(COLUMNS) do
        table.insert(cols, {width = col.width, align = "start"})
    end
    return cols
end

function TOGBankClassic_UI_Requests:DrawWindow()
    local window = TOGBankClassic_UI:Create("Frame")
    window:Hide()
    window:SetCallback("OnClose", OnClose)
    window:SetTitle("Requests")
    window:SetLayout("Flow")
    window:SetWidth(900)
    window:EnableResize(false)

    self.Window = window

    local headerGroup = TOGBankClassic_UI:Create("SimpleGroup")
    headerGroup:SetLayout("Table")
    headerGroup:SetUserData("table", {columns = ColumnLayout(), spaceH = 5})
    headerGroup:SetFullWidth(true)
    window:AddChild(headerGroup)
    self.Header = headerGroup

    local scroll = TOGBankClassic_UI:Create("ScrollFrame")
    scroll:SetLayout("Table")
    scroll:SetUserData("table", {columns = ColumnLayout(), spaceH = 5, spaceV = 2})
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    window:AddChild(scroll)
    self.Content = scroll
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
    return fulfilled >= qty
end

function TOGBankClassic_UI_Requests:SortedRequests()
    local info = TOGBankClassic_Guild.Info
    if not info then return {} end

    local requests = info.requests or {}
    local list = {}
    for _, req in ipairs(requests) do
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
    if not self.Header then return end

    self.Header:ReleaseChildren()

    for _, col in ipairs(COLUMNS) do
        local label = col.label
        if self.sortColumn == col.key then
            label = label .. (self.sortDirection == "asc" and " ▲" or " ▼")
        end

        local button = TOGBankClassic_UI:Create("Button")
        button:SetText(label)
        button:SetWidth(col.width - 5)
        button:SetCallback("OnClick", function()
            if self.sortColumn == col.key then
                self.sortDirection = (self.sortDirection == "asc") and "desc" or "asc"
            else
                self.sortColumn = col.key
                self.sortDirection = "desc"
            end
            self:DrawContent()
        end)
        self.Header:AddChild(button)
    end
end

function TOGBankClassic_UI_Requests:DrawContent()
    if not self.Content then return end

    self:DrawHeader()
    self.Content:ReleaseChildren()
    self.Window:SetStatusText("")

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
        local dateText = ts > 0 and date("%Y-%m-%d %H:%M:%S", ts) or "Unknown"
        if completed then
            dateText = "✔ " .. dateText
        end

        local cells = {
            dateText,
            req.requester or "",
            req.bank or "",
            req.item or "",
            tostring(req.quantity or ""),
            tostring(req.fulfilled or ""),
            req.notes or "",
        }

        for i, cell in ipairs(cells) do
            local label = TOGBankClassic_UI:Create("Label")
            label:SetText(colorize(cell, completed))
            label.label:SetHeight(18)
            self.Content:AddChild(label)
        end

        count = count + 1
    end

    local status = string.format("%d Request%s", count, count == 1 and "" or "s")
    self.Window:SetStatusText(status)
end
