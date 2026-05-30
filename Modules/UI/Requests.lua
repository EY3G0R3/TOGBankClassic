TOGBankClassic_UI_Requests = {}

local COLUMN_SPACING_H = 5
local COLUMN_SPACING_V = 2
local CONTENT_WIDTH_PADDING = 60
local REQUESTS_PER_PAGE = 50  -- Pagination: limit visible requests per page to prevent freezing
local COLUMNS = {
	{ key = "date",      label = "Date",      width = 140, align = "center",                       tooltipTitle = "Date Submitted",  tooltipDetail = "When the request was submitted. Click to sort." },
	{ key = "requester", label = "Requester", width = 150, align = "center", flex = true, weight = 1, tooltipTitle = "Requester",        tooltipDetail = "The guild member who submitted the request. Click to sort." },
	{ key = "bank",      label = "Bank",      width = 150, align = "center", flex = true, weight = 1, tooltipTitle = "Bank",            tooltipDetail = "The banker character this request is assigned to. Click to sort." },
	{ key = "quantity",  label = "#",         width = 50,  align = "end",                              tooltipTitle = "Quantity",         tooltipDetail = "The number of items requested. Click to sort." },
	{ key = "item",      label = "Item",      width = 170, align = "start",  flex = true, weight = 2, tooltipTitle = "Item",            tooltipDetail = "The item being requested. Click to sort." },
	{ key = "fulfilled", label = "Sent",      width = 70,  align = "center",                           tooltipTitle = "Amount Sent",     tooltipDetail = "How many items have been sent to the requester so far. Click to sort." },
	{ key = "actions",   label = "Actions",   width = 140, align = "center",                           tooltipTitle = "Actions",         tooltipDetail = "Fulfill, complete, or cancel the request. Click to sort." },
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
local FULFILL_ICON_IN_MAIL         = "|TInterface\\Icons\\INV_Letter_06:18:18:0:0|t"                                                  -- Wax-sealed letter: item is in your mail inbox
local FULFILL_ICON_IN_MAIL_AND_BANK = "|TInterface\\Icons\\INV_Misc_Bag_07:14:14:0:0|t|TInterface\\Icons\\INV_Letter_06:14:14:0:0|t" -- Bag + wax letter: item is in both bank and mail
local FULFILL_ICON_NEED_SPLIT      = "|TInterface\\Icons\\INV_Misc_Shovel_01:18:18:0:0|t"      -- Shovel: manual work needed
local FULFILL_ICON_NO_ITEMS = "|TInterface\\Icons\\INV_Misc_QuestionMark:18:18:0:0|t" -- Question mark: no items
-- Row status prefix icons (date column decorators)
local CHECK_MARK_ICON = "|TInterface\\Buttons\\UI-CheckBox-Check:0|t "
local CANCELLED_ICON  = "|TInterface\\RAIDFRAME\\ReadyCheck-NotReady:0|t "
local PADDING_ICON    = "|TInterface\\AddOns\\TOGBankClassic\\Media\\blank:0|t "
local DELETE_REQUEST_DIALOG = "TOGBankClassic_DeleteRequest"
local CANCEL_STALE_DIALOG   = "TOGBankClassic_CancelStale"

-- Cancel reason dialog state (persistent reusable frame)
local cancelReasonFrame    = nil
local cancelReasonDropdown = nil
local cancelReasonMap      = {}
local cancelSelectedKey    = "unavailable"
local pendingCancelReq     = nil
local pendingCancelActor   = nil
local pendingCancelUI      = nil
local FILTER_ANY = "__tog_any__"
local ARCHIVE_DAYS = 30
local FILTER_SEPARATOR_ME_ANY = "__tog_sep_me_any__"
local FILTER_SEPARATOR_ANY_REST = "__tog_sep_any_rest__"
local FILTER_SEPARATOR_HIST = "__tog_sep_hist__"
local FILTER_SEPARATOR_LABEL = "|cFFFFCC55-----------------------------------------|r"
local FILTER_SECTION_OPEN    = "|cFFFFCC55----------- Open requests -----------|r"
local FILTER_SECTION_HIST    = "|cFFFFCC55--------------- History ---------------|r"

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
	self.currentPage = 1  -- Reset to first page on filter change
	self:DrawRows()
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

local function closeCancelReasonDialog()
	pendingCancelReq   = nil
	pendingCancelActor = nil
	pendingCancelUI    = nil
	if cancelReasonFrame then
		cancelReasonFrame.frame:Hide()
	end
end

local function showCancelReasonDialog(req, actor, ui)
	if cancelReasonFrame and cancelReasonFrame.frame:IsShown() then
		return
	end

	pendingCancelReq   = req
	pendingCancelActor = actor
	pendingCancelUI    = ui
	local isBanker = TOGBankClassic_Guild:IsBank(actor)
	local defaultKey, reasons
	if isBanker then
		local pct = (TOGBankClassic_Options and TOGBankClassic_Options:GetMaxRequestPercent()) or 100
		defaultKey = "unavailable"
		reasons = {
			{ key = "unavailable",  label = "Checked the vault, checked twice, even asked a goblin — it's gone. You no take candle." },
			{ key = "policy",       label = string.format("Easy there, Hogger. Guild law says you can't hoard more than %d%% of the stock.", pct) },
			{ key = "wrong_bank",   label = "That item lives in another banker's keep. Safe travels — it's a big Azeroth." },
			{ key = "first_come",   label = "A faster adventurer already claimed it. The early bird gets the [item], as they say." },
			{ key = "duplicate",    label = "You've already got this in the queue — one at a time, this isn't the Stormwind Auction House." },
			{ key = "not_in_guild", label = "Checked the guild roster... we can't find you. Did you /gquit, or did Sylvanas raise you?" },
		}
	else
		defaultKey = "changed_mind"
		reasons = {
			{ key = "changed_mind",   label = "Changed your mind? Understandable — even Arthas had second thoughts. Eventually." },
			{ key = "found_ah",       label = "Found it on the AH? Bold move. We respect the hustle." },
			{ key = "already_got",   label = "Already looted it elsewhere? Look at you, being all self-sufficient. We're proud." },
			{ key = "mistake",        label = "Wrong item? Happens to the best of us. Even Khadgar misread a scroll once." },
			{ key = "plans_changed", label = "Plans changed? Tell that to the Lich King... wait, he's dead. Never mind." },
		}
	end
	cancelSelectedKey = defaultKey
	wipe(cancelReasonMap)
	local reasonOrder = {}
	for _, r in ipairs(reasons) do
		cancelReasonMap[r.key] = r.label
		table.insert(reasonOrder, r.key)
	end

	if not cancelReasonFrame then
		local frame = TOGBankClassic_UI:Create("Frame")
		frame:SetTitle("Cancel Request")
		frame:SetWidth(440)
		frame:SetHeight(200)
		frame:SetLayout("Flow")
		frame:EnableResize(false)

		local infoLabel = TOGBankClassic_UI:Create("Label")
		infoLabel:SetText("Select a reason for cancelling this request:")
		infoLabel:SetFullWidth(true)
		infoLabel:SetHeight(28)
		frame:AddChild(infoLabel)

		local dd = TOGBankClassic_UI:Create("Dropdown")
		dd:SetFullWidth(true)
		dd:SetCallback("OnValueChanged", function(_, _, value)
			cancelSelectedKey = value
		end)
		frame:AddChild(dd)
		cancelReasonDropdown = dd

		local spacer = TOGBankClassic_UI:Create("Label")
		spacer:SetText("")
		spacer:SetFullWidth(true)
		spacer:SetHeight(8)
		frame:AddChild(spacer)

		local confirmBtn = TOGBankClassic_UI:Create("Button")
		confirmBtn:SetText("Cancel Request")
		confirmBtn:SetWidth(160)
		confirmBtn:SetCallback("OnClick", function()
			if not pendingCancelReq then return end
			local reasonText = cancelReasonMap[cancelSelectedKey] or ""
			local cReq   = pendingCancelReq
			local cActor = pendingCancelActor
			local cUI    = pendingCancelUI
			closeCancelReasonDialog()
			local success = TOGBankClassic_Guild:CancelRequest(cReq.id, cActor, reasonText)
			if not success and cUI and cUI.Window then
				cUI.Window:SetStatusText("Unable to cancel request.")
			end
		end)
		frame:AddChild(confirmBtn)

		local gapLabel = TOGBankClassic_UI:Create("Label")
		gapLabel:SetText("")
		gapLabel:SetWidth(10)
		frame:AddChild(gapLabel)

		local dismissBtn = TOGBankClassic_UI:Create("Button")
		dismissBtn:SetText("Keep Request")
		dismissBtn:SetWidth(140)
		dismissBtn:SetCallback("OnClick", function()
			closeCancelReasonDialog()
		end)
		frame:AddChild(dismissBtn)

		frame:SetCallback("OnClose", function()
			closeCancelReasonDialog()
		end)

		cancelReasonFrame = frame
	end

	---@diagnostic disable-next-line: undefined-field
	cancelReasonDropdown:SetList(cancelReasonMap, reasonOrder)
	---@diagnostic disable-next-line: undefined-field
	cancelReasonDropdown:SetValue(defaultKey)
	---@diagnostic disable-next-line: undefined-field
	cancelReasonFrame.frame:ClearAllPoints()
	---@diagnostic disable-next-line: undefined-field
	cancelReasonFrame.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	---@diagnostic disable-next-line: undefined-field
	cancelReasonFrame.frame:Show()
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
					local actor = TOGBankClassic_Guild:GetNormalizedPlayer()
					local isActorBank = actor and TOGBankClassic_Guild:IsBank(actor) or false
					local mailboxOpen = TOGBankClassic_Mail.isOpen or (MailFrame and MailFrame:IsShown()) or false
					TOGBankClassic_UI_Requests:_RefreshFulfillButtons(actor, isActorBank, mailboxOpen)
				end
			end)
		end
		return
	end

	lastBagUpdate = now
	local actor = TOGBankClassic_Guild:GetNormalizedPlayer()
	local isActorBank = actor and TOGBankClassic_Guild:IsBank(actor) or false
	local mailboxOpen = TOGBankClassic_Mail.isOpen or (MailFrame and MailFrame:IsShown()) or false
	TOGBankClassic_UI_Requests:_RefreshFulfillButtons(actor, isActorBank, mailboxOpen)
end

local function RegisterBagEvents()
	if not bagUpdateFrame then
		bagUpdateFrame = CreateFrame("Frame")
		---@diagnostic disable-next-line: undefined-field
		bagUpdateFrame:SetScript("OnEvent", OnBagUpdate)
	end
	-- BAG_UPDATE_DELAYED fires once after all bag changes from a single action
	---@diagnostic disable-next-line: undefined-field
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
	self.currentPage = 1  -- Pagination: current page number
	-- Sort/data cache (invalidated by DrawContent, persists across DrawRows calls)
	self._cachedSortedTabFiltered = nil
	self._cachedTotal             = nil
	self._cachedSortColumn        = nil
	self._cachedSortDirection     = nil
	self._cachedTabFilter         = nil
	self._drawGeneration          = 0
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

-- Helper to set up click-outside-to-close behavior for dropdowns
local function SetupClickOutsideHandler(dropdown)
	if not dropdown or not dropdown.pullout then return end

	local pullout = dropdown.pullout
	local originalOpen = pullout.Open
	local clickCatcher = nil

	pullout.Open = function(self, ...)
		originalOpen(self, ...)

		-- Create invisible frame to catch clicks outside the pullout
		if not clickCatcher then
			---@diagnostic disable-next-line: undefined-global
			clickCatcher = CreateFrame("Frame", nil, UIParent)
			---@diagnostic disable-next-line: undefined-field
			clickCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
			---@diagnostic disable-next-line: undefined-field
			clickCatcher:SetFrameLevel(self.frame:GetFrameLevel() - 1)
			---@diagnostic disable-next-line: undefined-field
			clickCatcher:EnableMouse(true)
			---@diagnostic disable-next-line: undefined-field
			clickCatcher:SetScript("OnMouseDown", function()
				if self.frame:IsShown() then
					self:Close()
				end
			end)
		end

		---@diagnostic disable-next-line: undefined-field
		clickCatcher:SetAllPoints()
		---@diagnostic disable-next-line: undefined-field
		clickCatcher:Show()
	end

	local originalClose = pullout.Close
	pullout.Close = function(self)
		if clickCatcher then
			clickCatcher:Hide()
		end
		originalClose(self)
	end
end

function TOGBankClassic_UI_Requests:DrawWindow()
	local window = TOGBankClassic_UI:Create("Frame")
	window:Hide()
	window:SetCallback("OnClose", OnClose)
	window:SetTitle("Requests")
	window:SetLayout("Flow")
	window:EnableResize(true)
	TOGBankClassic_UI:ApplyThinBorder(window)
	-- Persist window position/size across reloads (each window gets its own sub-table)
	if TOGBankClassic_Options and TOGBankClassic_Options.db then
		local positions = TOGBankClassic_Options.db.char.framePositions
		positions.requests = positions.requests or { width = MIN_WIDTH, height = 500 }
		window:SetStatusTable(positions.requests)
	end
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

	-- Handle Esc key to close dropdowns before closing window
	window.frame:EnableKeyboard(true)
	window.frame:SetPropagateKeyboardInput(true)
	window.frame:SetScript("OnKeyDown", function(frame, key)
		if key == "ESCAPE" then
			-- Check if any dropdown pullout is open
			local closedAny = false
			if self.FilterRequester and self.FilterRequester.pullout and self.FilterRequester.pullout.frame:IsShown() then
				self.FilterRequester.pullout:Close()
				closedAny = true
			end
			if self.FilterBank and self.FilterBank.pullout and self.FilterBank.pullout.frame:IsShown() then
				self.FilterBank.pullout:Close()
				closedAny = true
			end
			-- If we closed a dropdown, consume the Esc key
			if closedAny then
				frame:SetPropagateKeyboardInput(false)
			else
				frame:SetPropagateKeyboardInput(true)
			end
		else
			frame:SetPropagateKeyboardInput(true)
		end
	end)

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
		GameTooltip:AddLine("Guild Requests — How to Use")
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Date column:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Mouseover any row's date to see a timeline tooltip showing when the request was submitted and, if applicable, when it was filled or cancelled (including the cancellation reason).", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Action buttons (right side of each row):|r", 1, 1, 1, false)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Fulfill:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Sends the item by in-game mail. The icon changes to show what is needed: envelope = ready to send; sealed letter = no mailbox nearby; bag = item is in the bank, go get it first; wax-sealed letter = item is in your mail inbox, retrieve it first; chest = item is split between your mail and bank; shovel = quantity must be split manually; question mark = item not found in your inventory.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Complete:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Marks the request as done without mailing. Use this when the item was handed over directly.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Cancel:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Opens a dialog to select a cancellation reason before cancelling. The reason is stored with the request and shown in the date tooltip. Cancelled requests move to the Archive tab.", 0.9, 0.9, 0.9, true)
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
	activeTabBtn:SetWidth(120)
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
	archiveTabBtn:SetWidth(120)
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
		cancelStaleBtn:SetWidth(130)
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

	-- Pagination buttons
	local prevButton = TOGBankClassic_UI:Create("Button")
	prevButton:SetText("< Prev")
	prevButton:SetWidth(90)
	prevButton:SetHeight(24)
	prevButton:SetCallback("OnClick", function()
		if self.currentPage > 1 then
			self.currentPage = self.currentPage - 1
			self:DrawRows()
		end
	end)
	attachActionTooltip(prevButton, "Previous Page", "Show the previous page of requests.")
	tabGroup:AddChild(prevButton)
	self.prevButton = prevButton

	local nextButton = TOGBankClassic_UI:Create("Button")
	nextButton:SetText("Next >")
	nextButton:SetWidth(90)
	nextButton:SetHeight(24)
	nextButton:SetCallback("OnClick", function()
		local info = TOGBankClassic_Guild.Info
		if not info or not info.requests then return end
		local allSorted, total = self:GetSortedTabFiltered()
		local allVisible = self:ApplyFilters(allSorted)
		local totalPages = math.max(1, math.ceil(#allVisible / REQUESTS_PER_PAGE))
		if self.currentPage < totalPages then
			self.currentPage = self.currentPage + 1
			self:DrawRows()
		end
	end)
	attachActionTooltip(nextButton, "Next Page", "Show the next page of requests.")
	tabGroup:AddChild(nextButton)
	self.nextButton = nextButton

	do
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
		SetupClickOutsideHandler(requesterFilter)

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
		SetupClickOutsideHandler(bankFilter)

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

	-- Apply thin scrollbar style to match dropdown scrollbars
	if tableFrame.scrollbar then
		tableFrame.scrollbar:ClearAllPoints()
		tableFrame.scrollbar:SetPoint("TOPRIGHT", tableFrame.scrollframe, "TOPRIGHT", 0, -20)
		tableFrame.scrollbar:SetPoint("BOTTOMRIGHT", tableFrame.scrollframe, "BOTTOMRIGHT", 0, 20)
		tableFrame.scrollbar:SetWidth(8)
		tableFrame.scrollbar:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Vertical")
	end

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
		list[FILTER_SEPARATOR_ANY_REST] = FILTER_SECTION_OPEN
		table.insert(order, FILTER_SEPARATOR_ANY_REST)
		for _, name in ipairs(openNames) do
			list[name] = string.format("(%d) %s", openCounts[name], name)
			table.insert(order, name)
		end
	end

	if #histNames > 0 then
		list[FILTER_SEPARATOR_HIST] = FILTER_SECTION_HIST
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

-- Create one row of widgets permanently bound to a request ID.
-- Rows are never reassigned to a different request; filter/sort changes
-- show/hide and reorder existing rows rather than re-populating them.
function TOGBankClassic_UI_Requests:EnsureRowForRequest(reqId)
	if not self.Content then return nil end

	self.RowPool = self.RowPool or {}
	local row = self.RowPool[reqId]
	if row then return row end

	row = { cells = {}, reqId = reqId, dirty = true }
	for i, col in ipairs(COLUMNS) do
		if col.key == "actions" then
			local actionGroup = TOGBankClassic_UI:Create("SimpleGroup")
			actionGroup:SetLayout("Flow")
			tagColumnWidget(actionGroup, i, false)
			self.Content:AddChild(actionGroup)

			local fulfillButton = TOGBankClassic_UI:Create("Button")
			fulfillButton:SetText(FULFILL_ICON)
			fulfillButton:SetWidth(24)
			fulfillButton:SetHeight(20)
			centerButtonText(fulfillButton)
			setupFulfillButtonTooltip(fulfillButton)
			actionGroup:AddChild(fulfillButton)

			local fulfillSpacer = TOGBankClassic_UI:Create("Label")
			fulfillSpacer:SetText("")
			fulfillSpacer:SetWidth(8)
			actionGroup:AddChild(fulfillSpacer)

			local completeButton = TOGBankClassic_UI:Create("Button")
			completeButton:SetText(COMPLETE_ICON)
			completeButton:SetWidth(24)
			completeButton:SetHeight(20)
			centerButtonText(completeButton)
			attachActionTooltip(completeButton, "Complete request", "Marks the request as completed by the bank.")
			actionGroup:AddChild(completeButton)

			local actionSpacer = TOGBankClassic_UI:Create("Label")
			actionSpacer:SetText("")
			actionSpacer:SetWidth(4)
			actionGroup:AddChild(actionSpacer)

			local cancelButton = TOGBankClassic_UI:Create("Button")
			cancelButton:SetText(CANCEL_ICON)
			cancelButton:SetWidth(24)
			cancelButton:SetHeight(20)
			centerButtonText(cancelButton)
			attachActionTooltip(cancelButton, "Cancel request", "Cancels the request without fulfilling it.")
			actionGroup:AddChild(cancelButton)

			local deleteSpacer = TOGBankClassic_UI:Create("Label")
			deleteSpacer:SetText("")
			deleteSpacer:SetWidth(8)
			actionGroup:AddChild(deleteSpacer)

			local deleteButton = TOGBankClassic_UI:Create("Button")
			deleteButton:SetText(DELETE_ICON)
			deleteButton:SetWidth(24)
			deleteButton:SetHeight(20)
			centerButtonText(deleteButton)
			attachActionTooltip(deleteButton, "Delete permanently", "Permanently removes the request.")
			actionGroup:AddChild(deleteButton)

			row.actionGroup   = actionGroup
			row.fulfillButton = fulfillButton
			row.fulfillSpacer = fulfillSpacer
			row.completeButton = completeButton
			row.actionSpacer  = actionSpacer
			row.cancelButton  = cancelButton
			row.deleteSpacer  = deleteSpacer
			row.deleteButton  = deleteButton
			row.cells[i]      = actionGroup
		else
			local label = TOGBankClassic_UI:Create("Label")
			label.label:SetHeight(18)
			label.label:SetWordWrap(false)
			label.label:SetJustifyH(justifyForAlign(col.align))
			tagColumnWidget(label, i, false)
			self.Content:AddChild(label)
			
			-- Item column: Add copyable EditBox overlay
			if col.key == "item" then
				local eb = CreateFrame("EditBox", nil, label.frame)
				eb:SetFontObject("GameFontHighlight")
				eb:SetMaxLetters(0)
				eb:SetMultiLine(false)
				eb:EnableMouse(true)
				eb:SetHeight(18)
				eb:SetPoint("TOPLEFT", label.frame, "TOPLEFT", 0, 0)
				eb:SetPoint("BOTTOMRIGHT", label.frame, "BOTTOMRIGHT", 0, 0)
				eb:SetAutoFocus(false)
				eb:SetJustifyH(justifyForAlign(col.align))
				eb:SetTextInsets(0, 0, 0, 0)
				eb:SetAlpha(0)
				eb:SetHighlightColor(0, 0, 0, 0)
				eb:Show()
				
				-- Copyable text behavior: EditBox is a fully transparent (alpha 0) overlay.
				-- Invisible but still receives mouse/keyboard events. On click, text is set
				-- and highlighted so Ctrl+C copies it. Focus auto-clears after 5 seconds.
				eb:SetScript("OnEditFocusGained", function(self)
					self:SetText(self._itemName or "")
					self:HighlightText()
					C_Timer.After(5, function()
						if self:HasFocus() then self:ClearFocus() end
					end)
				end)
				eb:SetScript("OnEditFocusLost", function(self)
					self:SetText("")
				end)
				eb:SetScript("OnChar", function(self)
					self:SetText(self._itemName or "")
					self:HighlightText()
				end)
				eb:SetScript("OnKeyDown", function(self, key)
					if key == "ESCAPE" then self:ClearFocus() end
				end)
				
				-- Item tooltip on hover
				eb:SetScript("OnEnter", function(self)
					local itemName = self._itemName
					if not itemName or itemName == "" then return end
					
					-- If the request carries an explicit itemID, use it directly so we
					-- show the correct same-name variant (e.g. Druid vs Warrior Voodoo Doll).
					-- REQ-003: when a suffixID is present, prefer the inventory entry whose suffix
					-- matches so random-suffix siblings ("of the Tiger" vs "of the Monkey") resolve
					-- to the requested one rather than the first item sharing the base ID.
					local requestItemID = self._itemID
					local requestSuffix = self._suffixID
					local itemLink, itemID
					if requestItemID then
						-- Search inventory for an entry with this exact ID (and suffix, when set) to get its full link
						local info = TOGBankClassic_Guild.Info
						if info and info.alts then
							for _, alt in pairs(info.alts) do
								if alt.items then
									for _, item in ipairs(alt.items) do
										if item.ID == requestItemID
										   and (not requestSuffix or TOGBankClassic_Item:GetSuffixID(item.Link) == requestSuffix) then
											itemLink = item.Link
											itemID   = item.ID
											break
										end
									end
								end
								if itemLink or itemID then break end
							end
						end
						-- Fall back to a bare/suffixed item string if no inventory entry found
						if not itemLink and not itemID then
							itemID = requestItemID
						end
					else
						-- Legacy request (no itemID): search by name, take first match
						local info = TOGBankClassic_Guild.Info
						if info and info.alts then
							for _, alt in pairs(info.alts) do
								if alt.items then
									for _, item in ipairs(alt.items) do
										local name = item.Info and item.Info.name
										      or (item.Link and item.Link:match("%[(.-)%]"))
										if name == itemName then
											itemLink = item.Link
											itemID   = item.ID
											break
										end
									end
								end
								if itemLink or itemID then break end
							end
						end
					end
					
					-- Build hyperlink from link string, or fall back to an item:ID string.
					-- REQ-003: when only the ID is known but a suffix was requested, encode the suffix
					-- (item:ID:0:0:0:0:0:suffixID) so the tooltip shows the requested random-suffix variant.
					local hyperlink = itemLink
					if not hyperlink and itemID then
						if requestSuffix then
							hyperlink = string.format("item:%d:0:0:0:0:0:%d", itemID, requestSuffix)
						else
							hyperlink = "item:" .. itemID
						end
					end
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
					if hyperlink then
						GameTooltip:SetHyperlink(hyperlink)
					else
						GameTooltip:ClearLines()
						GameTooltip:AddLine(itemName, 1, 1, 1)
					end
					GameTooltip:Show()
				end)
				eb:SetScript("OnLeave", function()
					GameTooltip:Hide()
				end)
				
				label.editbox = eb
			end
			
			if col.key == "date" then
				label.frame:SetScript("OnEnter", function(f)
					local d = f._tipData
					if not d then return end
					GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
					GameTooltip:ClearLines()
					GameTooltip:AddLine("Request Timeline", 1, 1, 1)
					local subTs = tonumber(d.date or 0) or 0
					if subTs > 0 then
						GameTooltip:AddLine("Submitted:  " .. date("%Y-%m-%d %H:%M", subTs), 0.9, 0.9, 0.9)
					else
						GameTooltip:AddLine("Submitted:  Unknown", 0.9, 0.9, 0.9)
					end
					local updTs = tonumber(d.updatedAt or 0) or 0
					if d.status == "fulfilled" or d.status == "complete" then
						if updTs > 0 then
							GameTooltip:AddLine("Filled:  " .. date("%Y-%m-%d %H:%M", updTs), 0.4, 1, 0.4)
							GameTooltip:AddLine("Item arrives approx. 1 hour after sending.", 0.6, 0.8, 0.6)
						end
					elseif d.status == "cancelled" then
						if updTs > 0 then
							GameTooltip:AddLine("Cancelled:  " .. date("%Y-%m-%d %H:%M", updTs), 1, 0.4, 0.4)
						end
						if d.notes and d.notes ~= "" then
							GameTooltip:AddLine("Reason:  " .. d.notes, 1, 0.65, 0.65, true)
						end
					end
					GameTooltip:Show()
				end)
				label.frame:SetScript("OnLeave", function()
					GameTooltip:Hide()
				end)
			end
			row.cells[i] = label
		end
	end

	-- Tag first cell with its reqId for O(1) lookup in _ApplySortOrder
	if row.cells[1] then
		row.cells[1]:SetUserData("togRequestsReqId", reqId)
	end
	self.RowPool[reqId] = row
	return row
end

-- Mark a specific request's row as needing data refresh next DrawRows call.
function TOGBankClassic_UI_Requests:InvalidateRow(reqId)
	if self.RowPool and reqId then
		local row = self.RowPool[reqId]
		if row then row.dirty = true end
	end
end

-- Mark all existing pool rows dirty (used after actor change, mailbox open/close).
function TOGBankClassic_UI_Requests:InvalidateAllRows()
	if not self.RowPool then return end
	for _, row in pairs(self.RowPool) do
		row.dirty = true
	end
end

function TOGBankClassic_UI_Requests:SetRowVisible(row, visible)
	if not row or not row.cells then return end
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

-- Returns the tab-filtered sorted request list, caching the result so that
-- bag-update and filter-selection redraws skip the expensive sort+tabfilter.
-- Cache is invalidated at the top of DrawContent (called on structural changes).
function TOGBankClassic_UI_Requests:GetSortedTabFiltered()
	if self._cachedSortedTabFiltered
		and self._cachedSortColumn    == self.sortColumn
		and self._cachedSortDirection == self.sortDirection
		and self._cachedTabFilter     == self.currentTab
	then
		return self._cachedSortedTabFiltered, self._cachedTotal
	end
	local sorted      = self:SortedRequests()
	local tabFiltered = self:ApplyTabFilter(sorted)
	self._cachedSortedTabFiltered = tabFiltered
	self._cachedTotal             = #tabFiltered
	self._cachedSortColumn        = self.sortColumn
	self._cachedSortDirection     = self.sortDirection
	self._cachedTabFilter         = self.currentTab
	return tabFiltered, self._cachedTotal
end

-- Populate a row with data from req. Only called when row.dirty == true.
-- SetCallback closures capture reqId from req.id, not the req table, so they
-- stay correct if req data is updated in-place by guild comms.
function TOGBankClassic_UI_Requests:_PopulateRow(row, req, actor, actorIsGM, isActorBank, mailboxOpen)
	row.dirty = false

	local completed = isComplete(req)
	local reqStatus = req.status or "open"
	if completed and reqStatus == "open" then reqStatus = "fulfilled" end
	local requestId = req.id

	local canCancel   = not completed and requestId and TOGBankClassic_Guild:CanCancelRequest(req, actor)
	local canComplete = not completed and requestId and TOGBankClassic_Guild:CanCompleteRequest(req, actor, actorIsGM)
	local canDelete   = requestId and TOGBankClassic_Guild:CanDeleteRequest(req, actor, actorIsGM)

	local ts = tonumber(req.date or 0) or 0
	local dateText = ts > 0 and date("%Y-%m-%d %H:%M", ts) or "Unknown"
	if reqStatus == "cancelled" then
		dateText = CANCELLED_ICON .. dateText
	elseif completed then
		dateText = CHECK_MARK_ICON .. dateText
	else
		dateText = PADDING_ICON .. dateText
	end

	local canFulfill, fulfillReason, itemsInBags = false, nil, 0
	if not completed and requestId and isActorBank then
		canFulfill, fulfillReason, itemsInBags = TOGBankClassic_Mail:CanFulfillRequest(req, actor)
	end
	local showFulfill    = isActorBank and not completed and requestId
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
			local showCancel   = canCancel   and true or false
			local showDelete   = canDelete   and true or false
			if row.actionGroup   then row.actionGroup:SetWidth(columnWidth) end
			if row.fulfillButton then setWidgetShown(row.fulfillButton, showFulfill) end
			if row.fulfillSpacer then setWidgetShown(row.fulfillSpacer, showFulfill and (showComplete or showCancel)) end
			if row.completeButton then setWidgetShown(row.completeButton, showComplete) end
			if row.actionSpacer  then setWidgetShown(row.actionSpacer, showComplete and showCancel) end
			if row.cancelButton  then setWidgetShown(row.cancelButton, showCancel) end
			if row.deleteSpacer  then setWidgetShown(row.deleteSpacer, showDelete and (showComplete or showCancel or showFulfill)) end
			if row.deleteButton  then setWidgetShown(row.deleteButton, showDelete) end

			-- Fulfill button visual/icon/tooltip state
			if row.fulfillButton and row.fulfillButton.frame then
				local needsSplit    = fulfillReason and string.find(fulfillReason, "Split")
				local isPartial     = fulfillReason and string.find(fulfillReason, "Partial")
				local buttonEnabled = fulfillEnabled or (canFulfill and mailboxOpen and (needsSplit or isPartial))
				row.fulfillButton.frame.togDisabled = not buttonEnabled
				row.fulfillButton.frame:SetAlpha(buttonEnabled and 1.0 or 0.4)

				local icon, tooltipDetail
				if fulfillReason and string.find(fulfillReason, "Partial") then
					icon = FULFILL_ICON_READY; tooltipDetail = fulfillReason
				elseif fulfillReason and string.find(fulfillReason, "Split") then
					icon = FULFILL_ICON_NEED_SPLIT; tooltipDetail = fulfillReason
				elseif fulfillEnabled then
					icon = FULFILL_ICON_READY
					tooltipDetail = string.format("Attach %d %s to mail for %s.", math.min(itemsInBags, qtyNeeded), req.item or "items", req.requester or "requester")
				elseif canFulfill and not mailboxOpen then
					icon = FULFILL_ICON_NO_MAILBOX; tooltipDetail = "Open a mailbox to fulfill this request."
				elseif fulfillReason == "in mail and bank" then
					icon = FULFILL_ICON_IN_MAIL_AND_BANK; tooltipDetail = "Item is split between your mail inbox and bank. Retrieve mail items first, then pick up the rest from the bank."
				elseif fulfillReason == "in mail" then
					icon = FULFILL_ICON_IN_MAIL; tooltipDetail = "Item is in your mail inbox. Open mailbox and retrieve it first."
				elseif fulfillReason == "shortfall in bank and mail" then
					icon = FULFILL_ICON_IN_MAIL_AND_BANK; tooltipDetail = string.format("Have %d in bags. More available in your bank and mail inbox — pick up or retrieve the rest to reach %d.", itemsInBags, qtyNeeded)
				elseif fulfillReason == "shortfall in mail" then
					icon = FULFILL_ICON_IN_MAIL; tooltipDetail = string.format("Have %d in bags. More available in your mail inbox — retrieve items to reach %d.", itemsInBags, qtyNeeded)
				elseif fulfillReason == "shortfall in bank" then
					icon = FULFILL_ICON_NOT_IN_BAGS; tooltipDetail = string.format("Have %d in bags. More available in your bank — pick up the rest to reach %d.", itemsInBags, qtyNeeded)
				elseif fulfillReason and string.find(fulfillReason, "not in bags") then
					icon = FULFILL_ICON_NOT_IN_BAGS; tooltipDetail = fulfillReason
				elseif fulfillReason then
					icon = FULFILL_ICON_NO_ITEMS; tooltipDetail = fulfillReason
				else
					icon = FULFILL_ICON_NOT_IN_BAGS; tooltipDetail = "Pick up items from bank first."
				end
				row.fulfillButton:SetText(icon)
				updateFulfillButtonTooltip(row.fulfillButton, "Fulfill request", tooltipDetail)
			end

			-- Wire action button callbacks — closures capture requestId (value type, safe)
			if row.completeButton then
				row.completeButton:SetCallback("OnClick", function()
					if not requestId then return end
					if not TOGBankClassic_Guild:CompleteRequest(requestId, actor) then
						self.Window:SetStatusText("Unable to complete request.")
					end
				end)
			end
			if row.cancelButton then
				row.cancelButton:SetCallback("OnClick", function()
					if not requestId then return end
					showCancelReasonDialog(req, actor, self)
				end)
			end
			if row.deleteButton then
				row.deleteButton:SetCallback("OnClick", function()
					if not requestId then return end
					confirmDeleteRequest(req, actor)
				end)
			end
			if row.fulfillButton then
				row.fulfillButton:SetCallback("OnClick", function()
					if not requestId then return end
					if row.fulfillButton.frame and row.fulfillButton.frame.togDisabled then return end
					local _, message = TOGBankClassic_Mail:PrepareFulfillMail(req)
					self.Window:SetStatusText(message or "")
				end)
			end
		else
			if row.cells then
				local label = row.cells[i]
				local cellVal
				if col.key == "date" then
					cellVal = dateText
				elseif col.key == "requester" then
					cellVal = req.requester or ""
				elseif col.key == "bank" then
					cellVal = req.bank or ""
				elseif col.key == "quantity" then
					local qty = req.quantity
					cellVal = (qty == nil or qty == "") and "" or (tostring(qty) .. "x")
				elseif col.key == "item" then
					cellVal = req.item or ""
				elseif col.key == "fulfilled" then
					cellVal = tostring(req.fulfilled or "")
				else
					cellVal = tostring(req[col.key] or "")
				end
				
				-- Item column has EditBox overlay for copyable text
				if col.key == "item" and label.editbox then
					-- Label renders the visible (colorized) text
					label:SetText(colorize(cellVal, reqStatus))
					-- Store item name, itemID and suffixID on EditBox for tooltip lookup
					label.editbox._itemName = cellVal
					label.editbox._itemID   = req.itemID or nil    -- nil for legacy requests
					label.editbox._suffixID = req.suffixID or nil  -- REQ-003: nil unless a random-suffix variant
				else
					label:SetText(colorize(cellVal, reqStatus))
				end
				
				label:SetWidth(columnWidth)

				if col.key == "date" then
					label.frame._tipData = {
						date      = req.date,
						updatedAt = req.updatedAt,
						status    = reqStatus,
						notes     = req.notes,
					}
				end
			end
		end
	end
end

-- Only refresh the fulfill button on visible rows — used by bag-update events
-- so the icon/state updates without touching text, permissions, or closures.
function TOGBankClassic_UI_Requests:_RefreshFulfillButtons(actor, isActorBank, mailboxOpen)
	if not self.RowPool or not self.Content then return end
	local info = TOGBankClassic_Guild.Info
	if not info or not info.requests then return end

	for reqId, row in pairs(self.RowPool) do
		if row._visible then
			local req = info.requests[reqId]
			if req then
				local completed = isComplete(req)
				if not completed and isActorBank then
					local canFulfill, fulfillReason, itemsInBags = TOGBankClassic_Mail:CanFulfillRequest(req, actor)
					local fulfillEnabled = canFulfill and mailboxOpen
					local qtyNeeded = (tonumber(req.quantity) or 0) - (tonumber(req.fulfilled) or 0)
					if row.fulfillButton and row.fulfillButton.frame then
						local needsSplit    = fulfillReason and string.find(fulfillReason, "Split")
						local isPartial     = fulfillReason and string.find(fulfillReason, "Partial")
						local buttonEnabled = fulfillEnabled or (canFulfill and mailboxOpen and (needsSplit or isPartial))
						row.fulfillButton.frame.togDisabled = not buttonEnabled
						row.fulfillButton.frame:SetAlpha(buttonEnabled and 1.0 or 0.4)

						local icon, tooltipDetail
						if fulfillReason and string.find(fulfillReason, "Partial") then
							icon = FULFILL_ICON_READY; tooltipDetail = fulfillReason
						elseif fulfillReason and string.find(fulfillReason, "Split") then
							icon = FULFILL_ICON_NEED_SPLIT; tooltipDetail = fulfillReason
						elseif fulfillEnabled then
							icon = FULFILL_ICON_READY
							tooltipDetail = string.format("Attach %d %s to mail for %s.", math.min(itemsInBags, qtyNeeded), req.item or "items", req.requester or "requester")
						elseif canFulfill and not mailboxOpen then
							icon = FULFILL_ICON_NO_MAILBOX; tooltipDetail = "Open a mailbox to fulfill this request."
						elseif fulfillReason == "in mail and bank" then
							icon = FULFILL_ICON_IN_MAIL_AND_BANK; tooltipDetail = "Item is split between your mail inbox and bank. Retrieve mail items first, then pick up the rest from the bank."
						elseif fulfillReason == "in mail" then
							icon = FULFILL_ICON_IN_MAIL; tooltipDetail = "Item is in your mail inbox. Open mailbox and retrieve it first."
						elseif fulfillReason == "shortfall in bank and mail" then
							icon = FULFILL_ICON_IN_MAIL_AND_BANK; tooltipDetail = string.format("Have %d in bags. More available in your bank and mail inbox — pick up or retrieve the rest to reach %d.", itemsInBags, qtyNeeded)
						elseif fulfillReason == "shortfall in mail" then
							icon = FULFILL_ICON_IN_MAIL; tooltipDetail = string.format("Have %d in bags. More available in your mail inbox — retrieve items to reach %d.", itemsInBags, qtyNeeded)
						elseif fulfillReason == "shortfall in bank" then
							icon = FULFILL_ICON_NOT_IN_BAGS; tooltipDetail = string.format("Have %d in bags. More available in your bank — pick up the rest to reach %d.", itemsInBags, qtyNeeded)
						elseif fulfillReason and string.find(fulfillReason, "not in bags") then
							icon = FULFILL_ICON_NOT_IN_BAGS; tooltipDetail = fulfillReason
						elseif fulfillReason then
							icon = FULFILL_ICON_NO_ITEMS; tooltipDetail = fulfillReason
						else
							icon = FULFILL_ICON_NOT_IN_BAGS; tooltipDetail = "Pick up items from bank first."
						end
						row.fulfillButton:SetText(icon)
						updateFulfillButtonTooltip(row.fulfillButton, "Fulfill request", tooltipDetail)
					end
				end
			end
		end
	end
end

-- Reorder self.Content.children to match the desired sort order.
-- Each request occupies exactly #COLUMNS consecutive child slots.
-- We sort those slot groups without touching the widgets themselves.
function TOGBankClassic_UI_Requests:_ApplySortOrder(sortedReqs)
	if not self.Content or not self.Content.children then return end

	local children = self.Content.children
	-- Build a map: reqId -> starting child index (1-based, step = #COLUMNS)
	local step = #COLUMNS

	-- O(N) linear scan: each row's first-cell widget carries its reqId via
	-- SetUserData("togRequestsReqId"). EmptyRow and other non-row widgets
	-- have no reqId and are safely skipped.
	local idToStart = {}
	for i, widget in ipairs(children) do
		local reqId = widget:GetUserData("togRequestsReqId")
		if reqId then
			idToStart[reqId] = i
		end
	end

	-- Build sorted children: all rows in allSorted order, then unsorted pool rows.
	local newChildren = {}
	local inSorted = {}
	for _, req in ipairs(sortedReqs) do
		inSorted[req.id] = true
		local start = idToStart[req.id]
		if start then
			for j = 0, step - 1 do
				newChildren[#newChildren + 1] = children[start + j]
			end
		end
	end

	-- Append pool rows not in sortedReqs (e.g. from a different archive tab).
	for reqId, row in pairs(self.RowPool or {}) do
		if not inSorted[reqId] and row.cells then
			local start = idToStart[reqId]
			if start then
				for j = 0, step - 1 do
					newChildren[#newChildren + 1] = children[start + j]
				end
			end
		end
	end

	-- Preserve non-row widgets (e.g. EmptyRow) that were in children but not
	-- placed by either loop above. Keep them at the end in their original order.
	local inNew = {}
	for _, w in ipairs(newChildren) do inNew[w] = true end
	for _, w in ipairs(children) do
		if not inNew[w] then
			newChildren[#newChildren + 1] = w
		end
	end

	-- Rebuild children in-place.
	for i = 1, #newChildren do children[i] = newChildren[i] end
	for i = #newChildren + 1, #children do children[i] = nil end
end

-- Main row-only redraw.
-- Filter changes   → show/hide rows, reorder, one DoLayout.
-- Data changes     → additionally re-populate dirty rows before layout.
-- New requests     → create rows (batched across frames if many are new at once).
function TOGBankClassic_UI_Requests:DrawRows()
	if not self.Content or not self.Window then return end

	local info    = TOGBankClassic_Guild.Info
	local allReqs = info and info.requests or {}

	local actor       = TOGBankClassic_Guild:GetNormalizedPlayer()
	local actorIsGM   = actor and TOGBankClassic_Guild:SenderIsGM(actor) or false
	local isActorBank = TOGBankClassic_Guild:IsBank(actor)
	local mailboxOpen = TOGBankClassic_Mail.isOpen or (MailFrame and MailFrame:IsShown()) or false

	-- Get the full sorted+tab-filtered list (cached; invalidated by DrawContent)
	local allSorted, total = self:GetSortedTabFiltered()

	-- Apply requester/bank filter to get the visible subset
	local allVisible = self:ApplyFilters(allSorted)
	local totalVisible = #allVisible
	
	-- Apply pagination: only show rows for current page
	self.currentPage = self.currentPage or 1
	local startIdx = (self.currentPage - 1) * REQUESTS_PER_PAGE
	local endIdx = startIdx + REQUESTS_PER_PAGE
	local visible = {}
	for i = startIdx + 1, math.min(endIdx, totalVisible) do
		visible[#visible + 1] = allVisible[i]
	end
	local count = #visible

	TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", string.format("[UI-003] DrawRows: %d visible of %d total (page %d)", count, total, self.currentPage))

	-- Cancel any in-progress batch from a prior call
	self._drawGeneration = (self._drawGeneration or 0) + 1
	local gen = self._drawGeneration

	local content = self.Content
	content:PauseLayout()

	-- Empty state
	if count == 0 then
		local empty       = self:EnsureEmptyLabel()
		local columnWidth = (self.ColumnWidths and self.ColumnWidths[1]) or COLUMNS[1].width
		if empty then
			empty:SetWidth(columnWidth)
			empty:SetText(self.currentTab == "archive" and "No archived requests." or "No requests yet.")
		end
		setWidgetShown(empty, true)
		-- Hide all pooled rows
		if self.RowPool then
			for _, row in pairs(self.RowPool) do
				if row._visible then
					self:SetRowVisible(row, false)
					row._visible = false
				end
			end
		end
		self.Window:SetStatusText(string.format("Showing 0 requests out of %d total", total))
		content:ResumeLayout()
		content:DoLayout()
		return
	end

	if self.EmptyRow then setWidgetShown(self.EmptyRow, false) end

	-- Build set of visible req IDs for fast lookup
	local visibleIds = {}
	for _, req in ipairs(visible) do visibleIds[req.id] = true end

	-- Show/hide rows and populate dirty ones synchronously (pool hits only).
	-- Collect requests that need NEW row creation (not yet in pool).
	local needsNewRow = {}
	for _, req in ipairs(visible) do
		local reqId = req.id
		local row   = self.RowPool and self.RowPool[reqId]
		if row then
			if not row._visible then
				self:SetRowVisible(row, true)
				row._visible = true
			end
			if row.dirty then
				self:_PopulateRow(row, req, actor, actorIsGM, isActorBank, mailboxOpen)
			end
		else
			needsNewRow[#needsNewRow + 1] = req
		end
	end

	-- Hide rows that are no longer in the visible set
	if self.RowPool then
		for reqId, row in pairs(self.RowPool) do
			if row._visible and not visibleIds[reqId] then
				self:SetRowVisible(row, false)
				row._visible = false
			end
		end
	end

	-- Reorder Content.children to match current sort
	self:_ApplySortOrder(allSorted)

	if #needsNewRow == 0 then
		-- All rows already existed (pool hits) and were populated above — one layout pass.
		self._batchLayoutGen = nil
		content:ResumeLayout()
		content:DoLayout()
		local totalPages = math.max(1, math.ceil(totalVisible / REQUESTS_PER_PAGE))
		if self.prevButton then self.prevButton:SetDisabled(self.currentPage <= 1) end
		if self.nextButton then self.nextButton:SetDisabled(self.currentPage >= totalPages) end
		
		-- Always calculate the range being shown on current page
		local showStart = startIdx + 1
		local showEnd = math.min(endIdx, totalVisible)
		local pageCount = showEnd - showStart + 1
		
		if totalVisible <= REQUESTS_PER_PAGE then
			self.Window:SetStatusText(string.format("Showing %d request%s out of %d total", pageCount, pageCount == 1 and "" or "s", total))
		else
			self.Window:SetStatusText(string.format("Showing %d-%d of %d (Page %d/%d)", showStart, showEnd, totalVisible, self.currentPage, totalPages))
		end
	else
		-- Some rows are brand new. Batch their creation across frames.
		-- Pool hits were already populated synchronously above, so one DoLayout
		-- displays correct data immediately before any new-row batching starts.
		self._batchLayoutGen = nil
		content:ResumeLayout()
		content:DoLayout()
		self.Window:SetStatusText("Loading...")
		C_Timer.After(0, function()
			if self._drawGeneration == gen and self.isOpen then
				self:_CreateNewRowsBatched(gen, needsNewRow, 1, count, total, allSorted, actor, actorIsGM, isActorBank, mailboxOpen)
			end
		end)
	end
end

-- Create brand-new rows in batches of 20, yielding between batches so the
-- game loop gets control. Layout stays paused across all batches; one
-- ResumeLayout+DoLayout fires only on the final batch.
function TOGBankClassic_UI_Requests:_CreateNewRowsBatched(gen, newReqs, startIndex, count, total, allSorted, actor, actorIsGM, isActorBank, mailboxOpen)
	if not self.isOpen or self._drawGeneration ~= gen then
		-- Superseded. Only resume layout if we are still the active pauser;
		-- a newer DrawRows may have already taken ownership of the pause.
		if self._batchLayoutGen == gen and self.Content then
			self.Content:ResumeLayout()
			self._batchLayoutGen = nil
		end
		return
	end
	if not self.Content then return end

	local batchSize = 20
	local endIndex  = math.min(startIndex + batchSize - 1, #newReqs)
	local content   = self.Content

	-- Pause layout and take ownership so superseded-batch cleanup knows not to interfere.
	content:PauseLayout()
	self._batchLayoutGen = gen
	for i = startIndex, endIndex do
		local req = newReqs[i]
		local row = self:EnsureRowForRequest(req.id)
		if row then
			row._visible = true
			self:SetRowVisible(row, true)
			self:_PopulateRow(row, req, actor, actorIsGM, isActorBank, mailboxOpen)
		end
	end

	local isLast = (endIndex >= #newReqs)
	if isLast then
		-- Final batch: sort order is now authoritative (all rows exist in children).
		self._batchLayoutGen = nil
		self:_ApplySortOrder(allSorted)
		content:ResumeLayout()
		content:DoLayout()
		
		-- Update pagination button states and status text
		local info = TOGBankClassic_Guild.Info
		if info and info.requests then
			local allSorted2, total2 = self:GetSortedTabFiltered()
			local allVisible2 = self:ApplyFilters(allSorted2)
			local totalVisible2 = #allVisible2
			local totalPages = math.max(1, math.ceil(totalVisible2 / REQUESTS_PER_PAGE))
			if self.prevButton then self.prevButton:SetDisabled(self.currentPage <= 1) end
			if self.nextButton then self.nextButton:SetDisabled(self.currentPage >= totalPages) end
			
			-- Calculate the range being shown on current page
			local startIdx = (self.currentPage - 1) * REQUESTS_PER_PAGE
			local endIdx = startIdx + REQUESTS_PER_PAGE
			local showStart = startIdx + 1
			local showEnd = math.min(endIdx, totalVisible2)
			local pageCount = showEnd - showStart + 1
			
			if totalVisible2 <= REQUESTS_PER_PAGE then
				self.Window:SetStatusText(string.format("Showing %d request%s out of %d total", pageCount, pageCount == 1 and "" or "s", total2))
			else
				self.Window:SetStatusText(string.format("Showing %d-%d of %d (Page %d/%d)", showStart, showEnd, totalVisible2, self.currentPage, totalPages))
			end
		else
			self.Window:SetStatusText(string.format("Showing %d request%s out of %d total", count, count == 1 and "" or "s", total))
		end
	else
		-- Layout stays paused across batches — no intermediate DoLayout.
		self.Window:SetStatusText(string.format("Loading %d / %d...", endIndex, #newReqs))
		C_Timer.After(0, function()
			self:_CreateNewRowsBatched(gen, newReqs, endIndex + 1, count, total, allSorted, actor, actorIsGM, isActorBank, mailboxOpen)
		end)
	end
end

function TOGBankClassic_UI_Requests:DrawContent()
	if not self.Content or not self.Window then
		TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", "[UI-003] DrawContent: No content or window")
		return
	end

	TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", "[UI-003] DrawContent: Starting structural refresh")

	self.Window:SetStatusText("")
	self.currentPage = 1  -- Reset to first page on tab change or full refresh

	self:UpdateColumnLayout()
	self:UpdateTabButtons()
	self:DrawHeader()
	self:UpdateFilters()
	if self.HeaderGroup then self.HeaderGroup:DoLayout() end
	if self.FilterGroup  then self.FilterGroup:DoLayout()  end
	self:AdjustTableHeight()
	if self.Window then self.Window:DoLayout() end

	-- Invalidate sort/tab cache and mark all rows dirty so data is refreshed
	self._cachedSortedTabFiltered = nil
	self:InvalidateAllRows()
	self:DrawRows()
end


