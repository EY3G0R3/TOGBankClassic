TOGBankClassic_UI_Requests = {}

local COLUMN_SPACING_H = 5
local COLUMN_SPACING_V = 2
local CONTENT_WIDTH_PADDING = 60
local FILTER_LAYOUT_TOP = "top"
local FILTER_LAYOUT_TWO_HEADERS = "two-headers"
local FILTER_LAYOUT = FILTER_LAYOUT_TOP -- switch to FILTER_LAYOUT_TWO_HEADERS for the two-row header layout

local COLUMNS = {
	{ key = "date",      label = "Date",      width = 140, align = "center",                       tooltipTitle = "Date Submitted",  tooltipDetail = "When the request was submitted. Click to sort." },
	{ key = "requester", label = "Requester", width = 150, align = "center", flex = true, weight = 1, tooltipTitle = "Requester",        tooltipDetail = "The guild member who submitted the request. Click to sort." },
	{ key = "bank",      label = "Bank",      width = 150, align = "center", flex = true, weight = 1, tooltipTitle = "Bank",            tooltipDetail = "The banker character this request is assigned to. Click to sort." },
	{ key = "quantity",  label = "#",         width = 50,  align = "end",                              tooltipTitle = "Quantity",         tooltipDetail = "The number of items requested. Click to sort." },
	{ key = "item",      label = "Item",      width = 170, align = "start",  flex = true, weight = 2, tooltipTitle = "Item",            tooltipDetail = "The item being requested. Click to sort." },
	{ key = "fulfilled", label = "Sent",      width = 70,  align = "center",                           tooltipTitle = "Amount Sent",     tooltipDetail = "How many items have been sent to the requester so far. Click to sort." },
	{ key = "actions",   label = "Actions",   width = 140, align = "center",                           tooltipTitle = "Actions",         tooltipDetail = "Fulfill, complete, cancel or delete the request." },
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

local CANCEL_ICON = "|TInterface\\RAIDFRAME\\ReadyCheck-NotReady:18:18:0:0|t"
local COMPLETE_ICON = "|TInterface\\Buttons\\UI-CheckBox-Check:18:18:0:0|t"
local DELETE_ICON = "|TInterface\\Buttons\\UI-GroupLoot-Pass-Up:18:18:0:0|t"
local FULFILL_ICON = "|TInterface\\Icons\\INV_Letter_15:18:18:0:0|t"
-- Contextual fulfill button icons based on state
local FULFILL_ICON_READY = "|TInterface\\Icons\\INV_Letter_15:18:18:0:0|t"        -- Envelope: ready to send
local FULFILL_ICON_NO_MAILBOX = "|TInterface\\Icons\\INV_Letter_02:18:18:0:0|t"   -- Sealed letter: need mailbox
local FULFILL_ICON_NOT_IN_BAGS = "|TInterface\\Icons\\INV_Misc_Bag_07:18:18:0:0|t" -- Bag: pick up from bank
local FULFILL_ICON_NEED_SPLIT = "|TInterface\\Icons\\INV_Misc_Shovel_01:18:18:0:0|t" -- Shovel: manual work needed
local FULFILL_ICON_NO_ITEMS = "|TInterface\\Icons\\INV_Misc_QuestionMark:18:18:0:0|t" -- Question mark: no items
local DELETE_REQUEST_DIALOG = "TOGBankClassic_DeleteRequest"
local CANCEL_STALE_DIALOG   = "TOGBankClassic_CancelStale"
local FILTER_ANY = "__tog_any__"
local ARCHIVE_DAYS = 30
local FILTER_SEPARATOR_ME_ANY = "__tog_sep_me_any__"
local FILTER_SEPARATOR_ANY_REST = "__tog_sep_any_rest__"
local FILTER_SEPARATOR_HIST = "__tog_sep_hist__"
local FILTER_SEPARATOR_LABEL = "----------"

local function useTwoHeaderLayout()
	return FILTER_LAYOUT == FILTER_LAYOUT_TWO_HEADERS
end

local function isFilterSeparator(value)
	return value == FILTER_SEPARATOR_ME_ANY
		or value == FILTER_SEPARATOR_ANY_REST
		or value == FILTER_SEPARATOR_HIST
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
		cols[i] = { width = widths[i], alignH = col.align or "start" }
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

-- Special tooltip handler for fulfill button that works even when disabled
-- Hooks frame directly and stores tooltip data for dynamic updates
local function setupFulfillButtonTooltip(button)
	if not button or not button.frame then
		return
	end
	local frame = button.frame
	if frame.togFulfillTooltipHooked then
		return
	end
	frame.togFulfillTooltipHooked = true
	frame.togTooltipTitle = "Fulfill request"
	frame.togTooltipDetail = ""

	-- Hook scripts directly on the frame (works even when button is disabled)
	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:ClearLines()
		GameTooltip:AddLine(self.togTooltipTitle or "")
		if self.togTooltipDetail and self.togTooltipDetail ~= "" then
			GameTooltip:AddLine(self.togTooltipDetail, 0.9, 0.9, 0.9, true)
		end
		GameTooltip:Show()
	end)
	frame:HookScript("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
	end)
end

local function updateFulfillButtonTooltip(button, title, detail)
	if not button or not button.frame then
		return
	end
	button.frame.togTooltipTitle = title or "Fulfill request"
	button.frame.togTooltipDetail = detail or ""
end

local function ensureDeleteDialog()
	if not StaticPopupDialogs then
		return
	end
	if StaticPopupDialogs[DELETE_REQUEST_DIALOG] then
		return
	end
	StaticPopupDialogs[DELETE_REQUEST_DIALOG] = {
		text = "%s",
		button1 = YES,
		button2 = CANCEL,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		OnAccept = function(_, data)
			if not data or not data.requestId then
				return
			end
			if not TOGBankClassic_Guild:DeleteRequest(data.requestId, data.actor) then
				if data.ui and data.ui.Window then
					data.ui.Window:SetStatusText("Unable to delete request.")
				end
			end
		end,
	}
end

local function ensureCancelStaleDialog()
	if not StaticPopupDialogs then
		return
	end
	if StaticPopupDialogs[CANCEL_STALE_DIALOG] then
		return
	end
	StaticPopupDialogs[CANCEL_STALE_DIALOG] = {
		text = "%s",
		button1 = YES,
		button2 = CANCEL,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		OnAccept = function(_, data)
			if not data then return end
			local expired = TOGBankClassic_Guild:ExpireStaleRequests(data.actor)
			if data.ui and data.ui.Window then
				if expired > 0 then
					data.ui.Window:SetStatusText(string.format("Cancelled %d stale request%s.", expired, expired == 1 and "" or "s"))
					data.ui:DrawContent()
				else
					data.ui.Window:SetStatusText("No stale requests found.")
				end
			end
		end,
	}
end

local function confirmDeleteRequest(request, actor)
	if not request or not StaticPopup_Show then
		return
	end

	ensureDeleteDialog()

	local qty = tonumber(request.quantity or 0) or 0
	local item = request.item or "Unknown"
	local requester = request.requester or "Unknown"
	local bank = request.bank or "Unknown"
	local message = string.format(
		"Are you sure you want to permanently delete the request for %dx %s from %s to %s?",
		qty,
		item,
		requester,
		bank
	)

	StaticPopup_Show(DELETE_REQUEST_DIALOG, message, nil, {
		requestId = request.id,
		actor = actor,
		ui = TOGBankClassic_UI_Requests,
	})
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

-- Throttled bag update handling - only active when window is open
local BAG_UPDATE_THROTTLE = 0.5 -- seconds
local bagUpdateFrame = nil
local lastBagUpdate = 0
local pendingBagUpdate = false

local function OnBagUpdate()
	if not TOGBankClassic_UI_Requests.isOpen then
		return
	end

	local now = GetTime()
	if now - lastBagUpdate < BAG_UPDATE_THROTTLE then
		-- Throttled - schedule a delayed refresh if not already pending
		if not pendingBagUpdate then
			pendingBagUpdate = true
			C_Timer.After(BAG_UPDATE_THROTTLE, function()
				pendingBagUpdate = false
				if TOGBankClassic_UI_Requests.isOpen then
					lastBagUpdate = GetTime()
					TOGBankClassic_UI_Requests:DrawContent()
				end
			end)
		end
		return
	end

	lastBagUpdate = now
	TOGBankClassic_UI_Requests:DrawContent()
end

local function RegisterBagEvents()
	if not bagUpdateFrame then
		bagUpdateFrame = CreateFrame("Frame")
		bagUpdateFrame:SetScript("OnEvent", OnBagUpdate)
	end
	-- BAG_UPDATE_DELAYED fires once after all bag changes from a single action
	bagUpdateFrame:RegisterEvent("BAG_UPDATE_DELAYED")
end

local function UnregisterBagEvents()
	if bagUpdateFrame then
		bagUpdateFrame:UnregisterAllEvents()
	end
end

function TOGBankClassic_UI_Requests:Init()
	self.sortColumn = "date"
	self.sortDirection = "desc"
	self.requesterFilter = nil
	self.bankFilter = nil
	self.defaultFiltersApplied = false
	self.currentTab = "active"
	-- Frame creation deferred to first Open() call (PERF-015)
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

	-- Check if banker status has changed since window was created
	local currentPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()
	local isCurrentlyBanker = currentPlayer and TOGBankClassic_Guild:IsBank(currentPlayer) or false
	local bankerStatusChanged = (self.wasBank ~= nil) and (self.wasBank ~= isCurrentlyBanker)

	-- Recreate window if banker status changed (to add/remove highlight checkbox)
	if bankerStatusChanged and self.Window then
		self.Window:Release()
		self.Window = nil
	end

	if not self.Window then
		self:DrawWindow()
		self.wasBank = isCurrentlyBanker
	end

	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen and TOGBankClassic_UI_Inventory.Window then
		self.Window:ClearAllPoints()
		self.Window:SetPoint("TOPLEFT", TOGBankClassic_UI_Inventory.Window.frame, "TOPRIGHT", 0, 0)
	end

	-- Ensure window stays within screen bounds
	TOGBankClassic_UI:ClampFrameToScreen(self.Window)

	self:DrawContent()

	-- Force layout update before showing to ensure proper sizing
	self.Window:DoLayout()

	-- Show window AFTER content is drawn and laid out to prevent initial sizing issue
	self.Window:Show()

	-- Start listening for bag changes to update fulfill button states (bank alts only)
	local player = TOGBankClassic_Guild:GetNormalizedPlayer()
	if player and TOGBankClassic_Guild:IsBank(player) then
		RegisterBagEvents()
	end

	-- REQUEST-001: Pull latest request state when the window opens so a banker
	-- sees current data without needing to wait for the periodic timer.
	-- CanQueryRequestsIndex cooldown prevents spam if the window is toggled rapidly.
	TOGBankClassic_Guild:QueryRequestsIndex(nil, "NORMAL")

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

	-- Stop listening for bag changes
	UnregisterBagEvents()

	-- Clear item highlighting
	if TOGBankClassic_ItemHighlight then
		TOGBankClassic_ItemHighlight:ClearAllOverlays()
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
	if self.TabGroup and self.TabGroup.frame then
		headerHeight = headerHeight + (self.TabGroup.frame:GetHeight() or 0)
		headerRows = headerRows + 1
	end
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
	window:EnableResize(true)
	TOGBankClassic_UI:ApplyThinBorder(window)
	-- Persist window position/size across reloads
	if TOGBankClassic_Options and TOGBankClassic_Options.db then
		window:SetStatusTable(TOGBankClassic_Options.db.char.framePositions)
	end
	-- Set width AFTER SetStatusTable to ensure minimum size is enforced
	window:SetWidth(MIN_WIDTH)
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

	-- Register frame for ESC key handling
	-- AceGUI frames handle ESC automatically, no manual registration needed

	self.Window = window

	-- Shrink status bar right edge to make room for the help icon
	local statusbg = window.statustext:GetParent()
	statusbg:ClearAllPoints()
	statusbg:SetPoint("BOTTOMLEFT",  window.frame, "BOTTOMLEFT",  15, 15)
	statusbg:SetPoint("BOTTOMRIGHT", window.frame, "BOTTOMRIGHT", -163, 15)

	-- Help "?" icon — sits in the gap between the status bar and the close button
	local helpIcon = CreateFrame("Frame", nil, window.frame)
	helpIcon:SetSize(24, 24)
	helpIcon:SetPoint("BOTTOMRIGHT", window.frame, "BOTTOMRIGHT", -133, 15)
	helpIcon:EnableMouse(true)
	local helpTex = helpIcon:CreateTexture(nil, "OVERLAY")
	helpTex:SetAllPoints(helpIcon)
	helpTex:SetTexture("Interface\\Common\\help-i")
	helpIcon:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Guild Requests — Action Buttons")
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Each request row has up to four action buttons on the right.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Fulfill:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Sends the item by in-game mail. The icon changes to show what is needed: envelope = ready to send; sealed letter = no mailbox nearby; bag = item is in the bank, go get it first; shovel = quantity must be split manually; question mark = item not found in your inventory.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Complete:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Marks the request as done without mailing. Use this when the item was handed over directly.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Cancel:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Cancels the request. It moves to the Archive tab.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Delete:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Permanently removes the request from the database. This cannot be undone.", 0.9, 0.9, 0.9, true)
		GameTooltip:Show()
	end)
	helpIcon:SetScript("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
	end)

	self.HeaderWidgets = nil
	self.FilterWidgets = nil
	self.FilterRequester = nil
	self.FilterBank = nil
	self.TabGroup = nil
	self.ActiveTabBtn = nil
	self.ArchiveTabBtn = nil

	-- Tab strip
	local tabGroup = TOGBankClassic_UI:Create("SimpleGroup")
	tabGroup:SetLayout("Flow")
	tabGroup:SetFullWidth(true)
	tabGroup.content:SetPoint("TOPLEFT", 0, 8)
	tabGroup.content:SetPoint("BOTTOMRIGHT", 0, -5)
	window:AddChild(tabGroup)
	self.TabGroup = tabGroup

	local activeTabBtn = TOGBankClassic_UI:Create("Button")
	activeTabBtn:SetText("Requests")
	activeTabBtn:SetWidth(100)
	activeTabBtn:SetHeight(24)
	activeTabBtn:SetCallback("OnClick", function()
		self.currentTab = "active"
		self:DrawContent()
	end)
	attachActionTooltip(activeTabBtn, "Active Requests", "Shows open requests waiting to be fulfilled.")
	tabGroup:AddChild(activeTabBtn)
	self.ActiveTabBtn = activeTabBtn

	local archiveTabBtn = TOGBankClassic_UI:Create("Button")
	archiveTabBtn:SetText("Archive")
	archiveTabBtn:SetWidth(100)
	archiveTabBtn:SetHeight(24)
	archiveTabBtn:SetCallback("OnClick", function()
		self.currentTab = "archive"
		self:DrawContent()
	end)
	attachActionTooltip(archiveTabBtn, "Archive", "Shows completed and cancelled requests.")
	tabGroup:AddChild(archiveTabBtn)
	self.ArchiveTabBtn = archiveTabBtn

	-- "Cancel Stale" button — only for bankers/officers
	local actor = TOGBankClassic_Guild:GetNormalizedPlayer()
	local isOfficerOrBanker = (CanViewOfficerNote and CanViewOfficerNote())
		or (actor and TOGBankClassic_Guild:IsBank(actor))
	if isOfficerOrBanker then
		local cancelStaleBtn = TOGBankClassic_UI:Create("Button")
		cancelStaleBtn:SetText("Cancel Stale")
		cancelStaleBtn:SetWidth(110)
		cancelStaleBtn:SetHeight(24)
		cancelStaleBtn:SetCallback("OnClick", function()
			if not StaticPopup_Show then return end
			ensureCancelStaleDialog()
			local days = TOGBankClassic_Options and TOGBankClassic_Options:GetAutoTombstoneDays() or 30
			local msg = string.format(
				"Cancel all open requests older than %d days?\n\nThis cannot be undone and will propagate to the whole guild.",
				days)
			StaticPopup_Show(CANCEL_STALE_DIALOG, msg, nil, {
				actor = actor,
				ui = TOGBankClassic_UI_Requests,
			})
		end)
		if cancelStaleBtn.frame then
			cancelStaleBtn.frame:HookScript("OnEnter", function(btn)
				local days = TOGBankClassic_Options and TOGBankClassic_Options:GetAutoTombstoneDays() or 30
				GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
				GameTooltip:ClearLines()
				GameTooltip:AddLine("Cancel Stale Requests")
				GameTooltip:AddLine(string.format(
					"Permanently cancels all open requests older than %d days and broadcasts the cancellation guild-wide.\n\nThe threshold is configured in Options > TOGBankClassic > Requests.",
					days), 0.9, 0.9, 0.9, true)
				GameTooltip:Show()
			end)
			cancelStaleBtn.frame:HookScript("OnLeave", function()
				TOGBankClassic_UI:HideTooltip()
			end)
		end
		tabGroup:AddChild(cancelStaleBtn)
		self.CancelStaleBtn = cancelStaleBtn
	end

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
		requesterFilter.label:ClearAllPoints()
		requesterFilter.label:SetPoint("TOPLEFT", requesterFilter.frame, "TOPLEFT", 3, 0)
		requesterFilter.label:SetPoint("TOPRIGHT", requesterFilter.frame, "TOPRIGHT", 0, 0)
		local requesterLabelHit = CreateFrame("Frame", nil, requesterFilter.frame)
		requesterLabelHit:SetPoint("TOPLEFT", requesterFilter.frame, "TOPLEFT", 3, 0)
		requesterLabelHit:SetPoint("TOPRIGHT", requesterFilter.frame, "TOPRIGHT", 0, 0)
		requesterLabelHit:SetHeight(18)
		requesterLabelHit:EnableMouse(true)
		requesterLabelHit:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:ClearLines()
			GameTooltip:AddLine("Filter by Requester")
			GameTooltip:AddLine("Filter the request list to the guild member you select here, or all requesters (Any Requester).", 0.9, 0.9, 0.9, true)
			GameTooltip:Show()
		end)
		requesterLabelHit:SetScript("OnLeave", function()
			TOGBankClassic_UI:HideTooltip()
		end)
		requesterFilter:SetFullWidth(true)
		requesterFilter:SetCallback("OnValueChanged", function(widget, _, value)
			handleFilterChange(self, "requester", widget, value)
		end)
		filterGroup:AddChild(requesterFilter)
		self.FilterRequester = requesterFilter

		local bankFilter = TOGBankClassic_UI:Create("Dropdown")
		bankFilter:SetLabel("Bank")
		bankFilter.label:ClearAllPoints()
		bankFilter.label:SetPoint("TOPLEFT", bankFilter.frame, "TOPLEFT", 3, 0)
		bankFilter.label:SetPoint("TOPRIGHT", bankFilter.frame, "TOPRIGHT", 0, 0)
		local bankLabelHit = CreateFrame("Frame", nil, bankFilter.frame)
		bankLabelHit:SetPoint("TOPLEFT", bankFilter.frame, "TOPLEFT", 3, 0)
		bankLabelHit:SetPoint("TOPRIGHT", bankFilter.frame, "TOPRIGHT", 0, 0)
		bankLabelHit:SetHeight(18)
		bankLabelHit:EnableMouse(true)
		bankLabelHit:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:ClearLines()
			GameTooltip:AddLine("Filter by Banker")
			GameTooltip:AddLine("Filter the request list to the banker you select here, or all bankers (Any Banker).", 0.9, 0.9, 0.9, true)
			GameTooltip:Show()
		end)
		bankLabelHit:SetScript("OnLeave", function()
			TOGBankClassic_UI:HideTooltip()
		end)
		bankFilter:SetFullWidth(true)
		bankFilter:SetCallback("OnValueChanged", function(widget, _, value)
			handleFilterChange(self, "bank", widget, value)
		end)
		filterGroup:AddChild(bankFilter)
		self.FilterBank = bankFilter

		-- Add highlighting checkbox (only for bankers)
		-- Check if guild roster is loaded before checking banker status
		if GetNumGuildMembers() > 0 then
			local currentPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()
			local isBank = TOGBankClassic_Guild:IsBank(currentPlayer)
			TOGBankClassic_Output:Debug("UI", "FILTER", "UpdateFilters: currentPlayer=%s, isBank=%s", tostring(currentPlayer), tostring(isBank))

			if isBank then
				TOGBankClassic_Output:Debug("UI", "FILTER", "UpdateFilters: Creating highlight checkbox")
				local highlightCheckbox = TOGBankClassic_UI:Create("CheckBox")
				highlightCheckbox:SetLabel("Highlight needed items")
				highlightCheckbox:SetFullWidth(true)
				highlightCheckbox:SetValue(TOGBankClassic_ItemHighlight and TOGBankClassic_ItemHighlight.enabled or false)
				highlightCheckbox:SetCallback("OnValueChanged", function(widget, _, value)
					if TOGBankClassic_ItemHighlight then
						TOGBankClassic_ItemHighlight:SetEnabled(value)
					end
				end)
				highlightCheckbox:SetCallback("OnEnter", function()
					GameTooltip:SetOwner(highlightCheckbox.frame, "ANCHOR_RIGHT")
					GameTooltip:ClearLines()
					GameTooltip:AddLine("Highlight Needed Items")
					GameTooltip:AddLine("Highlights items in your bank bags that match pending requests, making it easier to see what needs to be sent.", 0.9, 0.9, 0.9, true)
					GameTooltip:Show()
				end)
				highlightCheckbox:SetCallback("OnLeave", function()
					TOGBankClassic_UI:HideTooltip()
				end)
				filterGroup:AddChild(highlightCheckbox)
				self.HighlightCheckbox = highlightCheckbox
				TOGBankClassic_Output:Debug("UI", "FILTER", "UpdateFilters: Highlight checkbox created and added to filterGroup")
			else
				TOGBankClassic_Output:Debug("UI", "FILTER", "UpdateFilters: Not a banker, skipping checkbox")
			end
		else
			TOGBankClassic_Output:Debug("UI", "FILTER", "UpdateFilters: Guild roster not loaded yet, skipping banker check")
		end
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

-- Returns open counts and total counts per requester/banker across all requests.
-- Open counts drive the top section of the dropdown; total counts drive the history section.
local function allCounts(requests)
	local requesterOpen  = {}
	local requesterTotal = {}
	local bankOpen  = {}
	local bankTotal = {}
	for _, req in pairs(requests or {}) do
		local requester = req.requester
		if requester and requester ~= "" then
			requesterTotal[requester] = (requesterTotal[requester] or 0) + 1
			if isPending(req) then
				requesterOpen[requester] = (requesterOpen[requester] or 0) + 1
			end
		end
		local bank = req.bank
		if bank and bank ~= "" then
			bankTotal[bank] = (bankTotal[bank] or 0) + 1
			if isPending(req) then
				bankOpen[bank] = (bankOpen[bank] or 0) + 1
			end
		end
	end
	return requesterOpen, requesterTotal, bankOpen, bankTotal
end

local function buildNameOptions(anyLabel, currentPlayer, openCounts, totalCounts)
	local list = {}
	local order = {}

	-- "Me" entry at top (show open count if any, else total)
	if currentPlayer and currentPlayer ~= "" then
		local myOpen  = openCounts[currentPlayer] or 0
		local myTotal = totalCounts[currentPlayer] or 0
		local myCount = myOpen > 0 and myOpen or myTotal
		list[currentPlayer] = string.format("(%d) Me - %s", myCount, currentPlayer)
		table.insert(order, currentPlayer)
		list[FILTER_SEPARATOR_ME_ANY] = FILTER_SEPARATOR_LABEL
		table.insert(order, FILTER_SEPARATOR_ME_ANY)
	end

	list[FILTER_ANY] = anyLabel
	table.insert(order, FILTER_ANY)

	-- Split others into open-having and history-only
	local openNames = {}
	local histNames = {}
	for name in pairs(totalCounts or {}) do
		if name ~= currentPlayer then
			if (openCounts[name] or 0) > 0 then
				table.insert(openNames, name)
			else
				table.insert(histNames, name)
			end
		end
	end

	table.sort(openNames, function(a, b)
		local cA = openCounts[a] or 0
		local cB = openCounts[b] or 0
		if cA == cB then return tostring(a) < tostring(b) end
		return cA > cB
	end)
	table.sort(histNames, function(a, b)
		local cA = totalCounts[a] or 0
		local cB = totalCounts[b] or 0
		if cA == cB then return tostring(a) < tostring(b) end
		return cA > cB
	end)

	if #openNames > 0 then
		list[FILTER_SEPARATOR_ANY_REST] = "-- Open requests --"
		table.insert(order, FILTER_SEPARATOR_ANY_REST)
		for _, name in ipairs(openNames) do
			list[name] = string.format("(%d) %s", openCounts[name], name)
			table.insert(order, name)
		end
	end

	if #histNames > 0 then
		list[FILTER_SEPARATOR_HIST] = "-- History --"
		table.insert(order, FILTER_SEPARATOR_HIST)
		for _, name in ipairs(histNames) do
			list[name] = string.format("(%d) %s", totalCounts[name], name)
			table.insert(order, name)
		end
	end

	return list, order
end

local function buildRequesterOptions(currentPlayer, requesterOpen, requesterTotal)
	return buildNameOptions("Any Requester", currentPlayer, requesterOpen, requesterTotal)
end

local function buildBankOptions(currentPlayer, bankOpen, bankTotal)
	return buildNameOptions("Any Bank", currentPlayer, bankOpen, bankTotal)
end

function TOGBankClassic_UI_Requests:SortedRequests()
	local info = TOGBankClassic_Guild.Info
	if not info or not info.requests then
		TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", "[UI-003] SortedRequests: No guild info or requests")
		return {}
	end

	local list = {}
	-- Use pairs() since requests is now a map keyed by ID, not an array
	for _, req in pairs(info.requests) do
		table.insert(list, req)
	end

	TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", string.format("[UI-003] SortedRequests: Found %d requests in Guild.Info", #list))

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

			-- Fulfill button (first)
			local fulfillButton = TOGBankClassic_UI:Create("Button")
			fulfillButton:SetText(FULFILL_ICON)
			fulfillButton:SetWidth(24)
			fulfillButton:SetHeight(20)
			centerButtonText(fulfillButton)
			setupFulfillButtonTooltip(fulfillButton)
			actionGroup:AddChild(fulfillButton)

			-- Spacer between fulfill and complete/cancel
			local fulfillSpacer = TOGBankClassic_UI:Create("Label")
			fulfillSpacer:SetText("")
			fulfillSpacer:SetWidth(8)
			actionGroup:AddChild(fulfillSpacer)

			-- Complete button
			local completeButton = TOGBankClassic_UI:Create("Button")
			completeButton:SetText(COMPLETE_ICON)
			completeButton:SetWidth(24)
			completeButton:SetHeight(20)
			centerButtonText(completeButton)
			attachActionTooltip(completeButton, "Complete request", "Marks the request as completed by the bank.")
			actionGroup:AddChild(completeButton)

			-- Small spacer between complete and cancel
			local actionSpacer = TOGBankClassic_UI:Create("Label")
			actionSpacer:SetText("")
			actionSpacer:SetWidth(4)
			actionGroup:AddChild(actionSpacer)

			-- Cancel button
			local cancelButton = TOGBankClassic_UI:Create("Button")
			cancelButton:SetText(CANCEL_ICON)
			cancelButton:SetWidth(24)
			cancelButton:SetHeight(20)
			centerButtonText(cancelButton)
			attachActionTooltip(cancelButton, "Cancel request", "Cancels the request without fulfilling it.")
			actionGroup:AddChild(cancelButton)

			-- Spacer between cancel and delete
			local deleteSpacer = TOGBankClassic_UI:Create("Label")
			deleteSpacer:SetText("")
			deleteSpacer:SetWidth(8)
			actionGroup:AddChild(deleteSpacer)

			-- Delete button (last)
			local deleteButton = TOGBankClassic_UI:Create("Button")
			deleteButton:SetText(DELETE_ICON)
			deleteButton:SetWidth(24)
			deleteButton:SetHeight(20)
			centerButtonText(deleteButton)
			attachActionTooltip(deleteButton, "Delete permanently", "Permanently removes the request.")
			actionGroup:AddChild(deleteButton)

			row.actionGroup = actionGroup
			row.fulfillButton = fulfillButton
			row.fulfillSpacer = fulfillSpacer
			row.completeButton = completeButton
			row.actionSpacer = actionSpacer
			row.cancelButton = cancelButton
			row.deleteSpacer = deleteSpacer
			row.deleteButton = deleteButton
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

local function colorize(text, reqStatus)
	local color
	if reqStatus == "cancelled" then
		color = "ffff6666"
	-- "complete" = officer manually marked done; "fulfilled" = quantity fully sent
	elseif reqStatus == "fulfilled" or reqStatus == "complete" then
		color = "ff66ff66"
	else
		color = "ffffffff"
	end
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
			if col.tooltipTitle then
				attachActionTooltip(button, col.tooltipTitle, col.tooltipDetail)
			end
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
	local requesterOpen, requesterTotal, bankOpen, bankTotal = allCounts(requests)
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

	-- Create highlight checkbox if it doesn't exist but should (banker status now available)
	if not self.HighlightCheckbox and self.FilterGroup and GetNumGuildMembers() > 0 then
		local isBank = TOGBankClassic_Guild:IsBank(currentPlayer)
		if isBank then
			TOGBankClassic_Output:Debug("UI", "FILTER", "UpdateFilters: Creating highlight checkbox (delayed)")
			local highlightCheckbox = TOGBankClassic_UI:Create("CheckBox")
			highlightCheckbox:SetLabel("Highlight needed items")
			highlightCheckbox:SetFullWidth(true)
			highlightCheckbox:SetValue(TOGBankClassic_ItemHighlight and TOGBankClassic_ItemHighlight.enabled or false)
			highlightCheckbox:SetCallback("OnValueChanged", function(widget, _, value)
				if TOGBankClassic_ItemHighlight then
					TOGBankClassic_ItemHighlight:SetEnabled(value)
				end
			end)
			highlightCheckbox:SetCallback("OnEnter", function()
				GameTooltip:SetOwner(highlightCheckbox.frame, "ANCHOR_RIGHT")
				GameTooltip:ClearLines()
				GameTooltip:AddLine("Highlight Needed Items")
				GameTooltip:AddLine("Highlights items in your bank bags that match pending requests, making it easier to see what needs to be sent.", 0.9, 0.9, 0.9, true)
				GameTooltip:Show()
			end)
			highlightCheckbox:SetCallback("OnLeave", function()
				TOGBankClassic_UI:HideTooltip()
			end)
			self.FilterGroup:AddChild(highlightCheckbox)
			self.HighlightCheckbox = highlightCheckbox
			-- Re-layout filter group to show new checkbox
			if self.FilterGroup.DoLayout then
				self.FilterGroup:DoLayout()
			end
			TOGBankClassic_Output:Debug("UI", "FILTER", "UpdateFilters: Highlight checkbox created and added")
		end
	end

	local requesterList, requesterOrder = buildRequesterOptions(currentPlayer, requesterOpen, requesterTotal)

	-- Only update the requester dropdown if the list has changed
	local requesterListChanged = false
	if not self.cachedRequesterList or #requesterOrder ~= #(self.cachedRequesterOrder or {}) then
		requesterListChanged = true
	else
		for i, key in ipairs(requesterOrder) do
			if key ~= self.cachedRequesterOrder[i] or requesterList[key] ~= self.cachedRequesterList[key] then
				requesterListChanged = true
				break
			end
		end
	end

	if requesterListChanged then
		self.FilterRequester:SetList(requesterList, requesterOrder)
		self.cachedRequesterList = requesterList
		self.cachedRequesterOrder = requesterOrder
		TOGBankClassic_Output:Debug("UI", "FILTER", "UpdateFilters: Requester dropdown list updated")
	end

	local bankList, bankOrder = buildBankOptions(currentPlayer, bankOpen, bankTotal)

	-- Only update the bank dropdown if the list has changed
	local bankListChanged = false
	if not self.cachedBankList or #bankOrder ~= #(self.cachedBankOrder or {}) then
		bankListChanged = true
	else
		for i, key in ipairs(bankOrder) do
			if key ~= self.cachedBankOrder[i] or bankList[key] ~= self.cachedBankList[key] then
				bankListChanged = true
				break
			end
		end
	end

	if bankListChanged then
		self.FilterBank:SetList(bankList, bankOrder)
		self.cachedBankList = bankList
		self.cachedBankOrder = bankOrder
		TOGBankClassic_Output:Debug("UI", "FILTER", "UpdateFilters: Bank dropdown list updated")
	end

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
		TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", string.format("[UI-003] ApplyFilters: No filters, returning all %d requests", #(requests or {})))
		return requests
	end

	local filtered = {}
	-- Use pairs() since requests is now a map keyed by ID, not an array
	for _, req in pairs(requests or {}) do
		if (not self.requesterFilter or req.requester == self.requesterFilter)
			and (not self.bankFilter or req.bank == self.bankFilter) then
			table.insert(filtered, req)
		end
	end

	TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", string.format("[UI-003] ApplyFilters: Filtered from %d to %d requests (requester=%s, bank=%s)",
		#(requests or {}), #filtered, tostring(self.requesterFilter), tostring(self.bankFilter)))

	return filtered
end

function TOGBankClassic_UI_Requests:ApplyTabFilter(requests)
	local days = (TOGBankClassic_Options and TOGBankClassic_Options.db
		and TOGBankClassic_Options.db.global.requests.archiveDays)
		or ARCHIVE_DAYS
	local now = time()
	local cutoff = now - days * 86400
	local isArchive = (self.currentTab == "archive")
	local filtered = {}
	for _, req in ipairs(requests) do
		local ts = tonumber(req.date or 0) or 0
		if isArchive then
			if ts > 0 and ts < cutoff then
				table.insert(filtered, req)
			end
		else
			if ts <= 0 or ts >= cutoff then
				table.insert(filtered, req)
			end
		end
	end
	return filtered
end

function TOGBankClassic_UI_Requests:UpdateTabButtons()
	if not self.ActiveTabBtn or not self.ArchiveTabBtn then
		return
	end
	local isArchive = (self.currentTab == "archive")
	self.ActiveTabBtn:SetText(isArchive and "Requests" or "|cffffd100> Requests|r")
	self.ArchiveTabBtn:SetText(isArchive and "|cffffd100> Archive|r" or "Archive")
end

function TOGBankClassic_UI_Requests:DrawContent()
	if not self.Content or not self.Window then
		TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", "[UI-003] DrawContent: No content or window")
		return
	end

	TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", "[UI-003] DrawContent: Starting UI refresh")

	local content = self.Content
	content:PauseLayout()

	self.Window:SetStatusText("")

	self:UpdateColumnLayout()
	self:UpdateTabButtons()
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
	sorted = self:ApplyTabFilter(sorted)
	local total = #sorted
	sorted = self:ApplyFilters(sorted)
	local count = #sorted

	TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", string.format("[UI-003] DrawContent: Displaying %d requests", count))

	if count == 0 then
		local empty = self:EnsureEmptyLabel()
		local columnWidth = (self.ColumnWidths and self.ColumnWidths[1]) or COLUMNS[1].width
		if empty then
			empty:SetWidth(columnWidth)
			empty:SetText(self.currentTab == "archive" and "No archived requests." or "No requests yet.")
		end
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
		local CancelledIcon = "|TInterface\\RAIDFRAME\\ReadyCheck-NotReady:0|t "
		local PaddingIcon   = "|TInterface\\AddOns\\TOGBankClassic\\Media\\blank:0|t "
		local actor = TOGBankClassic_Guild:GetNormalizedPlayer()
		local actorIsGM = actor and TOGBankClassic_Guild:SenderIsGM(actor) or false

		for index, req in ipairs(sorted) do
			local row = self:EnsureRow(index)
			self:SetRowVisible(row, true)

			local completed = isComplete(req)
			local reqStatus = req.status or "open"
			if completed and reqStatus == "open" then
				reqStatus = "fulfilled"
			end
			local requestId = req.id
			local canCancel = not completed
				and requestId
				and TOGBankClassic_Guild:CanCancelRequest(req, actor)
			local canComplete = not completed
				and requestId
				and TOGBankClassic_Guild:CanCompleteRequest(req, actor, actorIsGM)
			local canDelete = requestId
				and TOGBankClassic_Guild:CanDeleteRequest(req, actor, actorIsGM)
			local ts = tonumber(req.date or 0) or 0
			local dateText = ts > 0 and date("%Y-%m-%d %H:%M", ts) or "Unknown"
			if reqStatus == "cancelled" then
				dateText = CancelledIcon .. dateText
			elseif completed then
				dateText = CheckMarkIcon .. dateText
			else
				dateText = PaddingIcon .. dateText
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

			-- Check fulfill eligibility
			local canFulfill, fulfillReason, itemsInBags = false, nil, 0
			local isActorBank = TOGBankClassic_Guild:IsBank(actor)
			if not completed and requestId and isActorBank then
				canFulfill, fulfillReason, itemsInBags = TOGBankClassic_Mail:CanFulfillRequest(req, actor)
			end
			local showFulfill = isActorBank and not completed and requestId
			-- Check mailbox state: flag is authoritative (set by events), frame is backup
			local mailboxOpen = TOGBankClassic_Mail.isOpen or (MailFrame and MailFrame:IsShown()) or false
			local fulfillEnabled = canFulfill and mailboxOpen

			local qtyNeeded = 0
			if req.quantity and req.fulfilled then
				qtyNeeded = (tonumber(req.quantity) or 0) - (tonumber(req.fulfilled) or 0)
			elseif req.quantity then
				qtyNeeded = tonumber(req.quantity) or 0
			end

			for i, col in ipairs(COLUMNS) do
				local columnWidth = (self.ColumnWidths and self.ColumnWidths[i]) or col.width
				if col.key == "actions" then
					local showComplete = canComplete and true or false
					local showCancel = canCancel and true or false
					local showDelete = canDelete and true or false
					if row and row.actionGroup then
						row.actionGroup:SetWidth(columnWidth)
					end
					-- Layout: [Fulfill] [spacer] [Complete] [spacer] [Cancel] [spacer] [Delete]
					if row and row.fulfillButton then
						setWidgetShown(row.fulfillButton, showFulfill)
					end
					if row and row.fulfillSpacer then
						setWidgetShown(row.fulfillSpacer, showFulfill and (showComplete or showCancel))
					end
					if row and row.completeButton then
						setWidgetShown(row.completeButton, showComplete)
					end
					if row and row.actionSpacer then
						setWidgetShown(row.actionSpacer, showComplete and showCancel)
					end
					if row and row.cancelButton then
						setWidgetShown(row.cancelButton, showCancel)
					end
					if row and row.deleteSpacer then
						setWidgetShown(row.deleteSpacer, showDelete and (showComplete or showCancel or showFulfill))
					end
					if row and row.deleteButton then
						setWidgetShown(row.deleteButton, showDelete)
					end

					-- Update fulfill button state, icon, and tooltip
					-- Don't use SetDisabled - it blocks mouse events including tooltips
					-- Instead, store disabled state and check in OnClick, use alpha for visual
					if row and row.fulfillButton and row.fulfillButton.frame then
						-- Special case: if split is needed, keep button enabled (PrepareFulfillMail will handle it)
						local needsSplit = fulfillReason and string.find(fulfillReason, "Split")
						local isPartial = fulfillReason and string.find(fulfillReason, "Partial")
						local buttonEnabled = fulfillEnabled or (canFulfill and mailboxOpen and (needsSplit or isPartial))
						row.fulfillButton.frame.togDisabled = not buttonEnabled
						row.fulfillButton.frame:SetAlpha(buttonEnabled and 1.0 or 0.4)

						-- Determine icon and tooltip based on state
						local icon, tooltipDetail
						if fulfillReason and string.find(fulfillReason, "Partial") then
							-- Partial fulfillment available - show envelope icon
							icon = FULFILL_ICON_READY
							tooltipDetail = fulfillReason
						elseif fulfillReason and string.find(fulfillReason, "Split") then
							-- Split needed - show special icon (shovel)
							icon = FULFILL_ICON_NEED_SPLIT
							tooltipDetail = fulfillReason
						elseif fulfillEnabled then
							icon = FULFILL_ICON_READY
							local attachCount = math.min(itemsInBags, qtyNeeded)
							tooltipDetail = string.format("Attach %d %s to mail for %s.", attachCount, req.item or "items", req.requester or "requester")
						elseif not mailboxOpen then
							icon = FULFILL_ICON_NO_MAILBOX
							tooltipDetail = "Open a mailbox to fulfill this request."
						elseif fulfillReason and string.find(fulfillReason, "Split") then
							-- Stack size issue
							icon = FULFILL_ICON_NEED_SPLIT
							tooltipDetail = fulfillReason
						elseif fulfillReason and string.find(fulfillReason, "not in bags") then
							-- Items in bank but not picked up
							icon = FULFILL_ICON_NOT_IN_BAGS
							tooltipDetail = fulfillReason
						elseif fulfillReason then
							-- Other reason (no items at all, etc.)
							icon = FULFILL_ICON_NO_ITEMS
							tooltipDetail = fulfillReason
						else
							icon = FULFILL_ICON_NOT_IN_BAGS
							tooltipDetail = "Pick up items from bank first."
						end

						row.fulfillButton:SetText(icon)
						updateFulfillButtonTooltip(row.fulfillButton, "Fulfill request", tooltipDetail)
					end

					if row and row.completeButton then
						row.completeButton:SetCallback("OnClick", function()
							if not requestId then
								return
							end
							if not TOGBankClassic_Guild:CompleteRequest(requestId, actor) then
								self.Window:SetStatusText("Unable to complete request.")
							end
						end)
					end

					if row and row.cancelButton then
						row.cancelButton:SetCallback("OnClick", function()
							if not requestId then
								return
							end
							if not TOGBankClassic_Guild:CancelRequest(requestId, actor) then
								self.Window:SetStatusText("Unable to cancel request.")
							end
						end)
					end

					if row and row.deleteButton then
						row.deleteButton:SetCallback("OnClick", function()
						if not requestId then
							return
						end
							confirmDeleteRequest(req, actor)
						end)
					end

					if row and row.fulfillButton then
						row.fulfillButton:SetCallback("OnClick", function()
							if not requestId then
								return
							end
							-- Check manual disabled state (we don't use SetDisabled to keep tooltips working)
							if row.fulfillButton and row.fulfillButton.frame and row.fulfillButton.frame.togDisabled then
								return
							end
							local success, message = TOGBankClassic_Mail:PrepareFulfillMail(req)
							self.Window:SetStatusText(message or "")
						end)
					end

					if row and row.actionGroup then
						row.actionGroup:DoLayout()
					end
				else
					if row and row.cells then
						local label = row.cells[i]
						label:SetText(colorize(cellText(col.key), reqStatus))
						label:SetWidth(columnWidth)
						setWidgetShown(label, true)
					end
				end
			end
		end

		if self.RowPool then
			for i = count + 1, #self.RowPool do
				self:SetRowVisible(self.RowPool[i], false)
			end
		end
	end

	local status = string.format("Showing %d request%s out of %d total", count, count == 1 and "" or "s", total)
	self.Window:SetStatusText(status)

	content:ResumeLayout()
	content:DoLayout()
end
