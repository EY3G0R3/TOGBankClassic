TOGBankClassic_UI_Requests = {}

local COLUMN_SPACING_H = 5
local COLUMN_SPACING_V = 2
local CONTENT_WIDTH_PADDING = 60
local FILTER_LAYOUT_TOP = "top"
local FILTER_LAYOUT_TWO_HEADERS = "two-headers"
local FILTER_LAYOUT = FILTER_LAYOUT_TOP -- switch to FILTER_LAYOUT_TWO_HEADERS for the two-row header layout

local COLUMNS = {
	{ key = "date", label = "Date", width = 140, align = "center" },
	{ key = "requester", label = "Requester", width = 150, align = "center", flex = true, weight = 1 },
	{ key = "bank", label = "Bank", width = 150, align = "center", flex = true, weight = 1 },
	{ key = "quantity", label = "#", width = 50, align = "end" },
	{ key = "item", label = "Item", width = 170, align = "start", flex = true, weight = 2 },
	{ key = "fulfilled", label = "Sent", width = 60, align = "start" },
	{ key = "actions", label = "Actions", width = 90, align = "center" },
}

local function minContentWidth()
	local total = 0
	for _, col in ipairs(COLUMNS) do
		total = total + (col.width or 0)
	end
	total = total + COLUMN_SPACING_H * (#COLUMNS - 1)
	return total
end

local MIN_WIDTH = minContentWidth() + CONTENT_WIDTH_PADDING

local CANCEL_ICON = "|TInterface\\Buttons\\CancelButton-Up:18:18:0:0|t"
local COMPLETE_ICON = "|TInterface\\Buttons\\UI-CheckBox-Check:18:18:0:0|t"
local FILTER_ANY = "__tog_any__"
local FILTER_SEPARATOR_ME_ANY = "__tog_sep_me_any__"
local FILTER_SEPARATOR_ANY_REST = "__tog_sep_any_rest__"
local FILTER_SEPARATOR_LABEL = "----------"

local function useTwoHeaderLayout()
	return FILTER_LAYOUT == FILTER_LAYOUT_TWO_HEADERS
end

local function isFilterSeparator(value)
	return value == FILTER_SEPARATOR_ME_ANY or value == FILTER_SEPARATOR_ANY_REST
end

local function currentFilterValue(self, key)
	if key == "requester" then
		return self.requesterFilter
	end
	return self.bankFilter
end

local function setFilterValue(self, key, value)
	if key == "requester" then
		self.requesterFilter = value
	else
		self.bankFilter = value
	end
end

local function handleFilterChange(self, key, widget, value)
	if isFilterSeparator(value) then
		local currentValue = currentFilterValue(self, key) or FILTER_ANY
		if widget and widget.SetValue then
			widget:SetValue(currentValue)
		end
		return
	end
	if value == FILTER_ANY then
		setFilterValue(self, key, nil)
	else
		setFilterValue(self, key, value)
	end
	self:DrawContent()
end

local function ColumnLayout(contentWidth)
	local cols = {}
	local widths = {}
	local baseTotal = 0
	local flexTotal = 0
	local spaceH = COLUMN_SPACING_H

	for _, col in ipairs(COLUMNS) do
		baseTotal = baseTotal + (col.width or 0)
		if col.flex then
			flexTotal = flexTotal + (col.weight or 1)
		end
	end

	local available = (tonumber(contentWidth) or 0) - spaceH * (#COLUMNS - 1)
	if available < baseTotal then
		available = baseTotal
	end

	local extra = available - baseTotal
	local used = 0
	local lastFlex = nil

	for i, col in ipairs(COLUMNS) do
		local width = col.width or 0
		if col.flex and flexTotal > 0 then
			width = width + extra * ((col.weight or 1) / flexTotal)
			lastFlex = i
		end
		width = math.floor(width + 0.5)
		widths[i] = width
		used = used + width
	end

	local remainder = available - used
	if remainder ~= 0 then
		local adjustIndex = lastFlex or #COLUMNS
		widths[adjustIndex] = widths[adjustIndex] + remainder
	end

	for i, col in ipairs(COLUMNS) do
		cols[i] = { width = widths[i], align = col.align or "start" }
	end

	return cols, widths
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

local function tagColumnWidget(widget, colIndex, keepWidth)
	if not widget or not widget.SetUserData then
		return
	end
	widget:SetUserData("togRequestsColIndex", colIndex)
	widget:SetUserData("togRequestsKeepWidth", keepWidth and true or false)
end

local function centerButtonText(button)
	if button.text and button.text.SetJustifyH then
		button.text:ClearAllPoints()
		button.text:SetPoint("CENTER")
		button.text:SetJustifyH("CENTER")
	end
end

local function setWidgetShown(widget, shown)
	if not widget or not widget.frame then
		return
	end
	local frame = widget.frame
	if not frame.togRequestsOrigShow then
		frame.togRequestsOrigShow = frame.Show
	end
	if shown then
		if frame.togRequestsHidden then
			frame.Show = frame.togRequestsOrigShow
			frame.togRequestsHidden = false
		end
		frame:Show()
	else
		if not frame.togRequestsHidden then
			-- AceGUI Flow layout calls frame:Show() during layout; override to keep hidden.
			frame.togRequestsHidden = true
			frame.Show = function() end
		end
		frame:Hide()
	end
end

local function attachActionTooltip(button, title, detail)
	if not button or not button.SetCallback then
		return
	end
	button:SetCallback("OnEnter", function()
		if not button.frame then
			return
		end
		GameTooltip:SetOwner(button.frame, "ANCHOR_RIGHT")
		GameTooltip:ClearLines()
		GameTooltip:AddLine(title or "")
		if detail and detail ~= "" then
			GameTooltip:AddLine(detail, 0.9, 0.9, 0.9, true)
		end
		GameTooltip:Show()
	end)
	button:SetCallback("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
	end)
end

local function currentContentWidth(self)
	if self.Content and self.Content.content and self.Content.content.GetWidth then
		local width = self.Content.content:GetWidth()
		if width and width > 0 then
			return width
		end
	end
	if self.Window and self.Window.frame and self.Window.frame.GetWidth then
		local width = self.Window.frame:GetWidth()
		if width and width > 0 then
			return width - CONTENT_WIDTH_PADDING
		end
	end
	return MIN_WIDTH - CONTENT_WIDTH_PADDING
end

function TOGBankClassic_UI_Requests:Init()
	self.sortColumn = "date"
	self.sortDirection = "desc"
	self.requesterFilter = nil
	self.bankFilter = nil
	self.defaultFiltersApplied = false
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
	if self.isOpen then
		return
	end
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
	if not self.isOpen then
		return
	end
	if not self.Window then
		return
	end

	OnClose(self.Window)

	if TOGBankClassic_UI_Inventory.isOpen == false then
		_G["TOGBankClassic"]:Hide()
	end
end

function TOGBankClassic_UI_Requests:ApplyColumnWidths()
	if not self.Content or not self.ColumnWidths then
		return
	end

	local widths = self.ColumnWidths
	local function applyTo(children)
		if not children then
			return
		end
		for _, child in ipairs(children) do
			if child and child.SetWidth then
				local colIndex = child:GetUserData("togRequestsColIndex")
				if colIndex and widths[colIndex] and not child:GetUserData("togRequestsKeepWidth") then
					child:SetWidth(widths[colIndex])
				end
			end
		end
	end

	applyTo(self.Content.children)
	if self.HeaderGroup then
		applyTo(self.HeaderGroup.children)
	end
end

function TOGBankClassic_UI_Requests:UpdateColumnLayout()
	if not self.Content then
		return
	end

	local width = currentContentWidth(self)
	local columns, widths = ColumnLayout(width)
	local function applyTable(group)
		if not group then
			return
		end
		local tableData = group:GetUserData("table") or {}
		tableData.columns = columns
		tableData.spaceH = COLUMN_SPACING_H
		tableData.spaceV = COLUMN_SPACING_V
		group:SetUserData("table", tableData)
	end

	applyTable(self.Content)
	applyTable(self.HeaderGroup)
	self.ColumnWidths = widths
	self.lastLayoutWidth = math.floor((width or 0) + 0.5)
end

function TOGBankClassic_UI_Requests:HandleResize()
	if not self.isOpen or not self.Content then
		return
	end

	local width = currentContentWidth(self)
	if not width or width <= 0 then
		return
	end

	local rounded = math.floor(width + 0.5)
	if self.lastLayoutWidth == rounded then
		return
	end

	self:UpdateColumnLayout()
	self:ApplyColumnWidths()
	if self.HeaderGroup then
		self.HeaderGroup:DoLayout()
	end
	if self.FilterGroup then
		self.FilterGroup:DoLayout()
	end
	self:AdjustTableHeight()
	if self.Window then
		self.Window:DoLayout()
	end
	self.Content:DoLayout()
end

function TOGBankClassic_UI_Requests:AdjustTableHeight()
	if not self.Window or not self.Window.content or not self.Content then
		return
	end

	local contentHeight = self.Window.content:GetHeight() or 0
	local headerHeight = 0
	local headerRows = 0
	if self.FilterGroup and self.FilterGroup.frame then
		headerHeight = headerHeight + (self.FilterGroup.frame:GetHeight() or 0)
		headerRows = headerRows + 1
	end
	if self.HeaderGroup and self.HeaderGroup.frame then
		headerHeight = headerHeight + (self.HeaderGroup.frame:GetHeight() or 0)
		headerRows = headerRows + 1
	end
	local gap = 3 -- AceGUI Flow row spacing
	local height = contentHeight - headerHeight - gap * headerRows
	if height < 50 then
		height = 50
	end
	self.Content:SetHeight(height)
end

function TOGBankClassic_UI_Requests:DrawWindow()
	local window = TOGBankClassic_UI:Create("Frame")
	window:Hide()
	window:SetCallback("OnClose", OnClose)
	window:SetTitle("Requests")
	window:SetLayout("Flow")
	window:SetWidth(MIN_WIDTH)
	window:EnableResize(true)
	if window.frame.SetResizeBounds then
		window.frame:SetResizeBounds(MIN_WIDTH, 200)
	else
		window.frame:SetMinResize(MIN_WIDTH, 200)
	end
	if not window.frame.togRequestsResizeHooked then
		window.frame.togRequestsResizeHooked = true
		window.frame:HookScript("OnSizeChanged", function()
			TOGBankClassic_UI_Requests:HandleResize()
		end)
	end
	self.Window = window

	self.HeaderGroup = nil
	self.FilterGroup = nil
	self.HeaderWidgets = nil
	self.FilterWidgets = nil
	self.FilterRequester = nil
	self.FilterBank = nil

	if not useTwoHeaderLayout() then
		local filterGroup = TOGBankClassic_UI:Create("SimpleGroup")
		filterGroup:SetLayout("Table")
		filterGroup:SetUserData("table", {
			columns = {
				{ width = 0.5, align = "start" },
				{ width = 0.5, align = "start" },
			},
			spaceH = 10,
		})
		filterGroup:SetFullWidth(true)
		window:AddChild(filterGroup)
		self.FilterGroup = filterGroup

		local requesterFilter = TOGBankClassic_UI:Create("Dropdown")
		requesterFilter:SetLabel("Requester")
		requesterFilter:SetFullWidth(true)
		requesterFilter:SetCallback("OnValueChanged", function(widget, _, value)
			handleFilterChange(self, "requester", widget, value)
		end)
		filterGroup:AddChild(requesterFilter)
		self.FilterRequester = requesterFilter

		local bankFilter = TOGBankClassic_UI:Create("Dropdown")
		bankFilter:SetLabel("Bank")
		bankFilter:SetFullWidth(true)
		bankFilter:SetCallback("OnValueChanged", function(widget, _, value)
			handleFilterChange(self, "bank", widget, value)
		end)
		filterGroup:AddChild(bankFilter)
		self.FilterBank = bankFilter
	end

	local headerGroup = TOGBankClassic_UI:Create("SimpleGroup")
	headerGroup:SetLayout("Table")
	headerGroup:SetUserData("table", {
		columns = ColumnLayout(MIN_WIDTH - CONTENT_WIDTH_PADDING),
		spaceH = COLUMN_SPACING_H,
		spaceV = COLUMN_SPACING_V,
	})
	headerGroup:SetFullWidth(true)
	if headerGroup.content and headerGroup.content.SetPoint then
		headerGroup.content:ClearAllPoints()
		headerGroup.content:SetPoint("TOPLEFT", 8, 0)
		headerGroup.content:SetPoint("BOTTOMRIGHT", 0, 0)
	end
	window:AddChild(headerGroup)
	self.HeaderGroup = headerGroup

	local tableFrame = TOGBankClassic_UI:Create("ScrollFrame")
	tableFrame:SetLayout("Table")
	tableFrame:SetUserData("table", {
		columns = ColumnLayout(MIN_WIDTH - CONTENT_WIDTH_PADDING),
		spaceH = COLUMN_SPACING_H,
		spaceV = COLUMN_SPACING_V,
	})
	tableFrame:SetFullWidth(true)

	tableFrame.scrollframe:ClearAllPoints()
	tableFrame.scrollframe:SetPoint("TOPLEFT", 8, -8)
	tableFrame.scrollbar:ClearAllPoints()
	tableFrame.scrollbar:SetPoint("TOPLEFT", tableFrame.scrollframe, "TOPRIGHT", -6, -12)
	tableFrame.scrollbar:SetPoint("BOTTOMLEFT", tableFrame.scrollframe, "BOTTOMRIGHT", -6, 22)

	window:AddChild(tableFrame)
	self.Content = tableFrame
	self.RowPool = nil
	self.EmptyRow = nil
	self:UpdateColumnLayout()
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
	if request.status == "cancelled" or request.status == "complete" or request.status == "fulfilled" then
		return true
	end
	return fulfilled >= qty and qty > 0
end

local function isPending(request)
	if not request then
		return false
	end
	local qty = tonumber(request.quantity or 0) or 0
	if qty <= 0 then
		return false
	end
	local fulfilled = tonumber(request.fulfilled or 0) or 0
	if (request.status or "open") ~= "open" then
		return false
	end
	return fulfilled < qty
end

local function pendingCounts(requests)
	local requesterCounts = {}
	local bankCounts = {}
	for _, req in ipairs(requests or {}) do
		if isPending(req) then
			local requester = req.requester
			if requester and requester ~= "" then
				requesterCounts[requester] = (requesterCounts[requester] or 0) + 1
			end
			local bank = req.bank
			if bank and bank ~= "" then
				bankCounts[bank] = (bankCounts[bank] or 0) + 1
			end
		end
	end
	return requesterCounts, bankCounts
end

local function buildRequesterOptions(currentPlayer, requesterCounts)
	local list = {}
	local order = {}
	if currentPlayer and currentPlayer ~= "" then
		list[currentPlayer] = string.format("(%d) Me - %s", requesterCounts[currentPlayer] or 0, currentPlayer)
		table.insert(order, currentPlayer)
		list[FILTER_SEPARATOR_ME_ANY] = FILTER_SEPARATOR_LABEL
		table.insert(order, FILTER_SEPARATOR_ME_ANY)
	end
	list[FILTER_ANY] = "Any Requester"
	table.insert(order, FILTER_ANY)

	local names = {}
	for name in pairs(requesterCounts or {}) do
		if name ~= currentPlayer then
			table.insert(names, name)
		end
	end
	table.sort(names)
	if #names > 0 then
		list[FILTER_SEPARATOR_ANY_REST] = FILTER_SEPARATOR_LABEL
		table.insert(order, FILTER_SEPARATOR_ANY_REST)
	end
	for _, name in ipairs(names) do
		list[name] = string.format("(%d) %s", requesterCounts[name], name)
		table.insert(order, name)
	end

	return list, order
end

local function buildBankOptions(currentPlayer, bankCounts)
	local list = {}
	local order = {}
	if currentPlayer and currentPlayer ~= "" then
		list[currentPlayer] = string.format("(%d) Me - %s", bankCounts[currentPlayer] or 0, currentPlayer)
		table.insert(order, currentPlayer)
		list[FILTER_SEPARATOR_ME_ANY] = FILTER_SEPARATOR_LABEL
		table.insert(order, FILTER_SEPARATOR_ME_ANY)
	end
	list[FILTER_ANY] = "Any Bank"
	table.insert(order, FILTER_ANY)

	local names = {}
	for name in pairs(bankCounts or {}) do
		if name ~= currentPlayer then
			table.insert(names, name)
		end
	end
	table.sort(names, function(a, b)
		local countA = bankCounts[a] or 0
		local countB = bankCounts[b] or 0
		if countA == countB then
			return tostring(a) < tostring(b)
		end
		return countA > countB
	end)
	if #names > 0 then
		list[FILTER_SEPARATOR_ANY_REST] = FILTER_SEPARATOR_LABEL
		table.insert(order, FILTER_SEPARATOR_ANY_REST)
	end
	for _, name in ipairs(names) do
		list[name] = string.format("(%d) %s", bankCounts[name], name)
		table.insert(order, name)
	end

	return list, order
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

function TOGBankClassic_UI_Requests:EnsureRow(index)
	if not self.Content then
		return nil
	end

	self.RowPool = self.RowPool or {}
	local row = self.RowPool[index]
	if row then
		return row
	end

	row = { cells = {} }
	for i, col in ipairs(COLUMNS) do
		if col.key == "actions" then
			local actionGroup = TOGBankClassic_UI:Create("SimpleGroup")
			actionGroup:SetLayout("Flow")
			tagColumnWidget(actionGroup, i, false)
			self.Content:AddChild(actionGroup)

			local completeButton = TOGBankClassic_UI:Create("Button")
			completeButton:SetText(COMPLETE_ICON)
			completeButton:SetWidth(24)
			completeButton:SetHeight(20)
			centerButtonText(completeButton)
			attachActionTooltip(completeButton, "Complete request", "Marks the request as completed by the bank.")
			actionGroup:AddChild(completeButton)

			local spacer = TOGBankClassic_UI:Create("Label")
			spacer:SetText("")
			spacer:SetWidth(4)
			actionGroup:AddChild(spacer)

			local cancelButton = TOGBankClassic_UI:Create("Button")
			cancelButton:SetText(CANCEL_ICON)
			cancelButton:SetWidth(24)
			cancelButton:SetHeight(20)
			centerButtonText(cancelButton)
			attachActionTooltip(cancelButton, "Cancel request", "Cancels the request without fulfilling it.")
			actionGroup:AddChild(cancelButton)

			row.actionGroup = actionGroup
			row.completeButton = completeButton
			row.cancelButton = cancelButton
			row.actionSpacer = spacer
			row.cells[i] = actionGroup
		else
			local label = TOGBankClassic_UI:Create("Label")
			label.label:SetHeight(18)
			label.label:SetJustifyH(justifyForAlign(col.align))
			tagColumnWidget(label, i, false)
			self.Content:AddChild(label)
			row.cells[i] = label
		end
	end

	self.RowPool[index] = row
	return row
end

function TOGBankClassic_UI_Requests:SetRowVisible(row, visible)
	if not row or not row.cells then
		return
	end
	for _, cell in ipairs(row.cells) do
		setWidgetShown(cell, visible)
	end
end

function TOGBankClassic_UI_Requests:EnsureEmptyLabel()
	if not self.Content then
		return nil
	end
	if self.EmptyRow then
		return self.EmptyRow
	end

	local empty = TOGBankClassic_UI:Create("Label")
	empty:SetText("No requests yet.")
	empty:SetFullWidth(true)
	tagColumnWidget(empty, 1, false)
	self.Content:AddChild(empty)
	self.EmptyRow = empty
	return empty
end

local function colorize(text, completed)
	local color = completed and "ff7f7f7f" or "ffffffff"
	return string.format("|c%s%s|r", color, text)
end

function TOGBankClassic_UI_Requests:EnsureHeaderRows()
	if not self.HeaderGroup then
		return
	end

	self.HeaderWidgets = self.HeaderWidgets or {}
	self.FilterWidgets = self.FilterWidgets or {}

	for i, col in ipairs(COLUMNS) do
		local button = self.HeaderWidgets[i]
		if not button then
			button = TOGBankClassic_UI:Create("Button")
			self.HeaderWidgets[i] = button
			tagColumnWidget(button, i, false)
			if button.text and button.text.SetJustifyH then
				button.text:SetJustifyH(justifyForAlign(col.align))
			end
			local colKey = col.key
			button:SetCallback("OnClick", function()
				if self.sortColumn == colKey then
					self.sortDirection = (self.sortDirection == "asc") and "desc" or "asc"
				else
					self.sortColumn = colKey
					self.sortDirection = "desc"
				end
				self:DrawContent()
			end)
			self.HeaderGroup:AddChild(button)
		end
	end

	if not useTwoHeaderLayout() then
		return
	end

	for i, col in ipairs(COLUMNS) do
		local widget = self.FilterWidgets[i]
		if not widget then
			if col.key == "requester" then
				local requesterFilter = TOGBankClassic_UI:Create("Dropdown")
				requesterFilter:SetCallback("OnValueChanged", function(widget, _, value)
					handleFilterChange(self, "requester", widget, value)
				end)
				widget = requesterFilter
				self.FilterRequester = requesterFilter
			elseif col.key == "bank" then
				local bankFilter = TOGBankClassic_UI:Create("Dropdown")
				bankFilter:SetCallback("OnValueChanged", function(widget, _, value)
					handleFilterChange(self, "bank", widget, value)
				end)
				widget = bankFilter
				self.FilterBank = bankFilter
			else
				local spacer = TOGBankClassic_UI:Create("Label")
				spacer:SetText("")
				widget = spacer
			end

			tagColumnWidget(widget, i, false)
			self.FilterWidgets[i] = widget
			self.HeaderGroup:AddChild(widget)
		end
	end
end

function TOGBankClassic_UI_Requests:DrawHeader()
	local ArrowUpIcon = " |TInterface\\Buttons\\Arrow-Up-Up:0|t"
	local ArrowDownIcon = " |TInterface\\Buttons\\Arrow-Down-Up:0|t"
	if not self.HeaderGroup then
		return
	end

	self:EnsureHeaderRows()

	for i, col in ipairs(COLUMNS) do
		local label = col.label
		if self.sortColumn == col.key then
			label = label .. (self.sortDirection == "asc" and ArrowUpIcon or ArrowDownIcon)
		end
		local button = self.HeaderWidgets[i]

		button:SetText(label)
		local columnWidth = (self.ColumnWidths and self.ColumnWidths[i]) or col.width
		button:SetWidth(columnWidth)
		setWidgetShown(button, true)
	end

	for i, _ in ipairs(COLUMNS) do
		local widget = self.FilterWidgets[i]
		if widget and widget.SetWidth then
			local columnWidth = (self.ColumnWidths and self.ColumnWidths[i]) or COLUMNS[i].width
			widget:SetWidth(columnWidth)
			setWidgetShown(widget, true)
		end
	end
end

function TOGBankClassic_UI_Requests:UpdateFilters()
	if not self.FilterRequester or not self.FilterBank then
		return
	end

	local info = TOGBankClassic_Guild.Info
	local requests = info and info.requests or {}
	local requesterCounts, bankCounts = pendingCounts(requests)
	local currentPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()
	if not self.defaultFiltersApplied then
		if self.requesterFilter ~= nil or self.bankFilter ~= nil then
			self.defaultFiltersApplied = true
		elseif currentPlayer and currentPlayer ~= "" then
			if TOGBankClassic_Guild:IsBank(currentPlayer) then
				self.bankFilter = currentPlayer
			else
				self.requesterFilter = currentPlayer
			end
			self.defaultFiltersApplied = true
		end
	end

	local requesterList, requesterOrder = buildRequesterOptions(currentPlayer, requesterCounts)
	self.FilterRequester:SetList(requesterList, requesterOrder)

	local bankList, bankOrder = buildBankOptions(currentPlayer, bankCounts)
	self.FilterBank:SetList(bankList, bankOrder)

	local requesterValue = self.requesterFilter or FILTER_ANY
	if requesterValue ~= FILTER_ANY and not requesterList[requesterValue] then
		self.requesterFilter = nil
		requesterValue = FILTER_ANY
	end
	self.FilterRequester:SetValue(requesterValue)

	local bankValue = self.bankFilter or FILTER_ANY
	if bankValue ~= FILTER_ANY and not bankList[bankValue] then
		self.bankFilter = nil
		bankValue = FILTER_ANY
	end
	self.FilterBank:SetValue(bankValue)
end

function TOGBankClassic_UI_Requests:ApplyFilters(requests)
	if not self.requesterFilter and not self.bankFilter then
		return requests
	end

	local filtered = {}
	for _, req in ipairs(requests or {}) do
		if (not self.requesterFilter or req.requester == self.requesterFilter)
			and (not self.bankFilter or req.bank == self.bankFilter) then
			table.insert(filtered, req)
		end
	end

	return filtered
end

function TOGBankClassic_UI_Requests:DrawContent()
	if not self.Content or not self.Window then
		return
	end

	local content = self.Content
	content:PauseLayout()

	self.Window:SetStatusText("")

	self:UpdateColumnLayout()
	self:DrawHeader()
	self:UpdateFilters()
	if self.HeaderGroup then
		self.HeaderGroup:DoLayout()
	end
	if self.FilterGroup then
		self.FilterGroup:DoLayout()
	end
	self:AdjustTableHeight()
	if self.Window then
		self.Window:DoLayout()
	end

	local sorted = self:SortedRequests()
	sorted = self:ApplyFilters(sorted)
	local count = #sorted
	if count == 0 then
		local empty = self:EnsureEmptyLabel()
		local columnWidth = (self.ColumnWidths and self.ColumnWidths[1]) or COLUMNS[1].width
		empty:SetWidth(columnWidth)
		setWidgetShown(empty, true)
		if self.RowPool then
			for _, row in ipairs(self.RowPool) do
				self:SetRowVisible(row, false)
			end
		end
	else
		if self.EmptyRow then
			setWidgetShown(self.EmptyRow, false)
		end

		local CheckMarkIcon = "|TInterface\\Buttons\\UI-CheckBox-Check:0|t "
		local actor = TOGBankClassic_Guild:GetNormalizedPlayer()

		for index, req in ipairs(sorted) do
			local row = self:EnsureRow(index)
			self:SetRowVisible(row, true)

			local completed = isComplete(req)
			local requestId = req.id
			local canCancel = not completed
				and requestId
				and TOGBankClassic_Guild:CanCancelRequest(req, actor)
			local canComplete = not completed
				and requestId
				and TOGBankClassic_Guild:CanCompleteRequest(req, actor)
			local ts = tonumber(req.date or 0) or 0
			local dateText = ts > 0 and date("%Y-%m-%d %H:%M", ts) or "Unknown"
			if completed then
				dateText = CheckMarkIcon .. dateText
			end

			local function cellText(colKey)
				if colKey == "date" then
					return dateText
				elseif colKey == "requester" then
					return req.requester or ""
				elseif colKey == "bank" then
					return req.bank or ""
				elseif colKey == "quantity" then
					local qty = req.quantity
					if qty == nil or qty == "" then
						return ""
					end
					return tostring(qty) .. "x"
				elseif colKey == "item" then
					return req.item or ""
				elseif colKey == "fulfilled" then
					return tostring(req.fulfilled or "")
				elseif colKey == "notes" then
					return req.notes or ""
				end
				return tostring(req[colKey] or "")
			end

			for i, col in ipairs(COLUMNS) do
				local columnWidth = (self.ColumnWidths and self.ColumnWidths[i]) or col.width
				if col.key == "actions" then
					local showComplete = canComplete and true or false
					local showCancel = canCancel and true or false
					row.actionGroup:SetWidth(columnWidth)
					setWidgetShown(row.completeButton, showComplete)
					setWidgetShown(row.cancelButton, showCancel)
					setWidgetShown(row.actionSpacer, showComplete and showCancel)

					row.completeButton:SetCallback("OnClick", function()
						if not requestId then
							return
						end
						if not TOGBankClassic_Guild:CompleteRequest(requestId, actor) then
							self.Window:SetStatusText("Unable to complete request.")
						end
					end)

					row.cancelButton:SetCallback("OnClick", function()
						if not requestId then
							return
						end
						if not TOGBankClassic_Guild:CancelRequest(requestId, actor) then
							self.Window:SetStatusText("Unable to cancel request.")
						end
					end)

					row.actionGroup:DoLayout()
				else
					local label = row.cells[i]
					label:SetText(colorize(cellText(col.key), completed))
					label:SetWidth(columnWidth)
					setWidgetShown(label, true)
				end
			end
		end

		if self.RowPool then
			for i = count + 1, #self.RowPool do
				self:SetRowVisible(self.RowPool[i], false)
			end
		end
	end

	local status = string.format("%d Request%s", count, count == 1 and "" or "s")
	self.Window:SetStatusText(status)

	content:ResumeLayout()
	content:DoLayout()
end
