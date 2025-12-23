TOGBankClassic_UI_Requests = {}

local COLUMNS = {
	{ key = "date", label = "Date", width = 140, align = "center" },
	{ key = "requester", label = "Requester", width = 150, align = "center" },
	{ key = "bank", label = "Bank", width = 150, align = "center" },
	{ key = "quantity", label = "#", width = 50, align = "end" },
	{ key = "item", label = "Item", width = 170, align = "start" },
	{ key = "fulfilled", label = "Sent", width = 60, align = "start" },
	{ key = "actions", label = "Action", width = 70, align = "center" },
}

local function ColumnLayout()
	local cols = {}
	for _, col in ipairs(COLUMNS) do
		table.insert(cols, { width = col.width, align = col.align or "start" })
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

function TOGBankClassic_UI_Requests:DrawWindow()
	local window = TOGBankClassic_UI:Create("Frame")
	window:Hide()
	window:SetCallback("OnClose", OnClose)
	window:SetTitle("Requests")
	window:SetLayout("Fill")
	window:SetWidth(850)
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
	if request.status == "cancelled" then
		return true
	end
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
	if not self.Content then
		return
	end

	local ArrowUpIcon = " |TInterface\\Buttons\\Arrow-Up-Up:0|t"
	local ArrowDownIcon = " |TInterface\\Buttons\\Arrow-Down-Up:0|t"

	for _, col in ipairs(COLUMNS) do
		local label = col.label
		if self.sortColumn == col.key then
			label = label .. (self.sortDirection == "asc" and ArrowUpIcon or ArrowDownIcon)
		end

		local button = TOGBankClassic_UI:Create("Button")
		button:SetText(label)
		button:SetWidth(col.width)
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
	if not self.Content or not self.Window then
		return
	end

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

	local CheckMarkIcon = "|TInterface\\Buttons\\UI-CheckBox-Check:0|t "
	local actor = TOGBankClassic_Guild:GetNormalizedPlayer()
	local canManage = TOGBankClassic_Guild:CanManageRequests(actor)

	local count = 0
	for _, req in ipairs(sorted) do
		local completed = isComplete(req)
		local requester = TOGBankClassic_Guild:NormalizeName(req.requester)
		local canCancel = not completed and (canManage or (actor and requester and actor == requester))
		local ts = tonumber(req.date or 0) or 0
		local dateText = ts > 0 and date("%Y-%m-%d %H:%M", ts) or "Unknown"
		if completed then
			dateText = CheckMarkIcon .. dateText
		end
		local requestId = req.id

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

		for _, col in ipairs(COLUMNS) do
			if col.key == "actions" then
				if canCancel and requestId then
					local button = TOGBankClassic_UI:Create("Button")
					button:SetText("Cancel")
					button:SetWidth(col.width)
					button:SetHeight(18)
					button:SetCallback("OnClick", function()
						if not TOGBankClassic_Guild:CancelRequest(requestId, actor) then
							self.Window:SetStatusText("Unable to cancel request.")
						end
					end)
					self.Content:AddChild(button)
				else
					local empty = TOGBankClassic_UI:Create("Label")
					empty:SetText("")
					empty:SetWidth(col.width)
					self.Content:AddChild(empty)
				end
			else
				local label = TOGBankClassic_UI:Create("Label")
				label:SetText(colorize(cellText(col.key), completed))
				label:SetWidth(col.width)
				label.label:SetHeight(18)
				label.label:SetJustifyH(justifyForAlign(col and col.align))
				self.Content:AddChild(label)
			end
		end

		count = count + 1
	end

	local status = string.format("%d Request%s", count, count == 1 and "" or "s")
	self.Window:SetStatusText(status)
end
