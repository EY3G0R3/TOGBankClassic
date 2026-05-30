TOGBankClassic_UI_Requests = {}

local COLUMN_SPACING_H = 5
local COLUMN_SPACING_V = 2
local CONTENT_WIDTH_PADDING = 60
local REQUESTS_PER_PAGE = 50  -- Pagination: limit visible requests per page to prevent freezing
local COLUMNS = {
	{ key = "date",      label = "Date",      width = 140, align = "center",                       tooltipTitle = "Date Submitted",  tooltipDetail = "When the request was submitted. Click to sort." },
	{ key = "requester", label = "Requester", width = 150, align = "center", flex = true, weight = 1, tooltipTitle = "Requester",        tooltipDetail = "The guild member who submitted the request. Click to sort." },
	{ key = "bank",      label = "Bank",      width = 150, align = "center", flex = true, weight = 1, tooltipTitle = "Bank",            tooltipDetail = "The banker character this request is assigned to. Click to sort." },
	{ key = "quantity",  label = "#",         width = 50,  align = "end",   headerSuffix = " ",         tooltipTitle = "Quantity",         tooltipDetail = "The number of items requested. Click to sort." },
	{ key = "item",      label = "Item",      width = 170, align = "start", headerAlign = "center", flex = true, weight = 2, tooltipTitle = "Item",            tooltipDetail = "The item being requested. Click to sort." },
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
local COMPLETE_QTY_DIALOG   = "TOGBankClassic_CompleteQty"

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

-- Enable/disable a raw Button frame (pagination icons), swapping to its disabled
-- texture and suppressing clicks. Mirrors AceGUI Button:SetDisabled for our needs.
local function setBtnEnabled(btn, enabled)
	if not btn then
		return
	end
	if enabled then
		btn:Enable()
	else
		btn:Disable()
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

-- CANCELREASON-001: built-in flavor presets, keyed so officers can disable them
-- individually. Banker presets are offered when a banker cancels someone's
-- request; member presets when a member cancels their own. The Settings-tab
-- editor lists these greyed-out (read-only text) with a tickbox per preset.
-- The "policy" label embeds the live max-request percent, so this is a builder
-- rather than a static table.
local function buildPresetReasons(role)
	if role == "banker" then
		local pct = (TOGBankClassic_Options and TOGBankClassic_Options:GetMaxRequestPercent()) or 100
		return {
			{ key = "unavailable",  label = "Checked the vault, checked twice, even asked a goblin — it's gone. You no take candle." },
			{ key = "policy",       label = string.format("Easy there, Hogger. Guild law says you can't hoard more than %d%% of the stock.", pct) },
			{ key = "wrong_bank",   label = "That item lives in another banker's keep. Safe travels — it's a big Azeroth." },
			{ key = "first_come",   label = "A faster adventurer already claimed it. The early bird gets the [item], as they say." },
			{ key = "duplicate",    label = "You've already got this in the queue — one at a time, this isn't the Stormwind Auction House." },
			{ key = "not_in_guild", label = "Checked the guild roster... we can't find you. Did you /gquit, or did Sylvanas raise you?" },
		}
	end
	return {
		{ key = "changed_mind",  label = "Changed your mind? Understandable — even Arthas had second thoughts. Eventually." },
		{ key = "found_ah",      label = "Found it on the AH? Bold move. We respect the hustle." },
		{ key = "already_got",   label = "Already looted it elsewhere? Look at you, being all self-sufficient. We're proud." },
		{ key = "mistake",       label = "Wrong item? Happens to the best of us. Even Khadgar misread a scroll once." },
		{ key = "plans_changed", label = "Plans changed? Tell that to the Lich King... wait, he's dead. Never mind." },
	}
end

-- The synced cancel-reason config (officer-authored, guild-wide). Read-only
-- accessors that tolerate a missing/old table so member clients still work.
local function cancelReasonConfig()
	local g = TOGBankClassic_Guild
	local cr = g and g.Info and g.Info.settings and g.Info.settings.cancelReasons
	return (type(cr) == "table") and cr or nil
end

local function presetDisabledSet(role)
	local cr = cancelReasonConfig()
	local pd = cr and cr.presetDisabled and cr.presetDisabled[role]
	return (type(pd) == "table") and pd or {}
end

local function customReasonList()
	local cr = cancelReasonConfig()
	local c  = cr and cr.custom
	return (type(c) == "table") and c or {}
end

local function showCancelReasonDialog(req, actor, ui)
	if cancelReasonFrame and cancelReasonFrame.frame:IsShown() then
		return
	end

	pendingCancelReq   = req
	pendingCancelActor = actor
	pendingCancelUI    = ui
	local isBanker = TOGBankClassic_Guild:IsBank(actor)
	local role = isBanker and "banker" or "member"
	local defaultKey = isBanker and "unavailable" or "changed_mind"

	-- Built-in presets for this role, minus any the officers have disabled.
	local reasons = {}
	local disabled = presetDisabledSet(role)
	for _, p in ipairs(buildPresetReasons(role)) do
		if not disabled[p.key] then
			reasons[#reasons + 1] = p
		end
	end
	-- Append officer-authored custom reasons enabled for this role (CANCELREASON-001).
	local customIdx = 0
	for _, c in ipairs(customReasonList()) do
		if type(c) == "table" and c[role] and type(c.text) == "string" and c.text ~= "" then
			customIdx = customIdx + 1
			reasons[#reasons + 1] = { key = "custom" .. customIdx, label = c.text }
		end
	end
	-- Always offer at least one option, even if every preset was disabled and no
	-- custom reasons target this role.
	if #reasons == 0 then
		reasons[1] = { key = "none", label = "Request cancelled." }
	end
	-- If the default was disabled/removed, fall back to the first available reason.
	local haveDefault = false
	for _, r in ipairs(reasons) do
		if r.key == defaultKey then haveDefault = true break end
	end
	if not haveDefault then
		defaultKey = reasons[1].key
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

-- COMPLETEQTY-001: the "Complete" (manual hand-off) button asks how many were
-- given, and records that quantity into the Sent column via Guild:FulfillRequest
-- (which marks the order fulfilled only when it reaches the requested amount).
local function ensureCompleteQtyDialog()
	if not StaticPopupDialogs then return end
	if StaticPopupDialogs[COMPLETE_QTY_DIALOG] then return end
	StaticPopupDialogs[COMPLETE_QTY_DIALOG] = {
		text = "%s",
		button1 = "Mark Sent",
		button2 = CANCEL,
		hasEditBox = true,
		maxLetters = 6,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		OnShow = function(self)
			local eb = self.editBox
			if eb then
				eb:SetNumeric(true)
				eb:SetText(tostring((self.data and self.data.defaultQty) or ""))
				eb:HighlightText()
				eb:SetFocus()
			end
		end,
		EditBoxOnEnterPressed = function(editBox)
			local parent = editBox:GetParent()
			if parent and parent.button1 then parent.button1:Click() end
		end,
		EditBoxOnEscapePressed = function(editBox)
			local parent = editBox:GetParent()
			if parent then parent:Hide() end
		end,
		OnAccept = function(self)
			local data = self.data
			if not data then return end
			local n = tonumber(self.editBox and self.editBox:GetText())
			local ui = TOGBankClassic_UI_Requests
			if not n or n < 1 then
				if ui.Window then ui.Window:SetStatusText("Enter a quantity of 1 or more.") end
				return
			end
			n = math.floor(n)
			if data.maxQty and n > data.maxQty then n = data.maxQty end
			-- Apply against the request's own bank so it works regardless of who
			-- clicked (the button is already gated by CanCompleteRequest).
			local applied = TOGBankClassic_Guild:FulfillRequest(data.bank, data.requester, data.item, n, data.requestId)
			if (applied or 0) <= 0 and ui.Window then
				ui.Window:SetStatusText("Unable to record that quantity.")
			end
		end,
	}
end

local function showCompleteQtyPrompt(request, actor)
	if not request or not StaticPopup_Show then return end
	ensureCompleteQtyDialog()
	local qty = tonumber(request.quantity or 0) or 0
	local fulfilled = tonumber(request.fulfilled or 0) or 0
	local remaining = math.max(qty - fulfilled, 0)
	local message = string.format(
		"How many %s did you hand directly to %s?\n\nThis amount is recorded in the Sent column (up to %d remaining).",
		request.item or "items", request.requester or "the requester", remaining)
	StaticPopup_Show(COMPLETE_QTY_DIALOG, message, nil, {
		requestId  = request.id,
		bank       = request.bank,
		requester  = request.requester,
		item       = request.item,
		defaultQty = remaining,
		maxQty     = remaining,
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

	-- Help "?" icon — rightmost of the bottom-row cluster, in the gap between the
	-- status bar and the AceGUI Close button (which spans x -127..-27). Must stay
	-- left of -127 so it doesn't overlap Close. The status bar extends to meet the
	-- cluster on its left.
	local helpIcon = CreateFrame("Frame", nil, window.frame)
	helpIcon:SetSize(22, 22)
	helpIcon:SetPoint("BOTTOMRIGHT", window.frame, "BOTTOMRIGHT", -133, 15)
	helpIcon:EnableMouse(true)
	-- HITBOX-001: AceGUI's Frame lays a mouse-enabled resize strip (sizer_s, full
	-- bottom width, 25px tall) + corner sizer across this row at the parent's default
	-- child level (101). Any button we add here defaults to the same level, so the
	-- sizer Z-fights and swallows clicks AND mouseover except a center sliver. Lift
	-- every bottom-row frame above the sizers so the whole 22x22 is live.
	helpIcon:SetFrameLevel(window.frame:GetFrameLevel() + 10)
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
		GameTooltip:AddLine("|cffffd100Mark hand-off (check):|r", 1, 1, 1, false)
		GameTooltip:AddLine("For items handed over directly (not mailed). Asks how many you gave; that amount goes into the Sent column, and the order completes once Sent reaches the amount requested.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Cancel:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Opens a dialog to select a cancellation reason before cancelling. The reason is stored with the request and shown in the date tooltip. Cancelled requests move to the Archive tab.", 0.9, 0.9, 0.9, true)
		TOGBankClassic_UI:AppendGuildHelpNote("requests")  -- HELPNOTE-001
		GameTooltip:Show()
	end)
	helpIcon:SetScript("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
	end)

	-- Bottom-row icon buttons on the window frame near the status bar, to the left
	-- of the help "?" icon: pagination (prev/next) and Cancel Stale (broom).
	-- These replace the buttons that used to crowd the top tab strip.
	local actor = TOGBankClassic_Guild:GetNormalizedPlayer()
	local canOfficer = (CanViewOfficerNote and CanViewOfficerNote()) or false
	local isOfficerOrBanker = canOfficer or (actor and TOGBankClassic_Guild:IsBank(actor)) or false

	local function bottomIconTooltip(frame, titleText, detailText)
		frame:SetScript("OnEnter", function(f)
			GameTooltip:SetOwner(f, "ANCHOR_TOP")
			GameTooltip:ClearLines()
			GameTooltip:AddLine(titleText)
			if detailText and detailText ~= "" then
				GameTooltip:AddLine(detailText, 0.9, 0.9, 0.9, true)
			end
			GameTooltip:Show()
		end)
		frame:SetScript("OnLeave", function()
			TOGBankClassic_UI:HideTooltip()
		end)
	end

	-- Next page (rightmost; sits just left of the help icon)
	local nextPageBtn = CreateFrame("Button", nil, window.frame)
	nextPageBtn:SetSize(22, 22)
	nextPageBtn:SetFrameLevel(window.frame:GetFrameLevel() + 10)  -- HITBOX-001
	nextPageBtn:SetPoint("RIGHT", helpIcon, "LEFT", -8, 0)
	nextPageBtn:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
	nextPageBtn:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
	nextPageBtn:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Disabled")
	nextPageBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	nextPageBtn:SetScript("OnClick", function()
		local info = TOGBankClassic_Guild.Info
		if not info or not info.requests then return end
		local allSorted = self:GetSortedTabFiltered()
		local allVisible = self:ApplyFilters(allSorted)
		local totalPages = math.max(1, math.ceil(#allVisible / REQUESTS_PER_PAGE))
		if self.currentPage < totalPages then
			self.currentPage = self.currentPage + 1
			self:DrawRows()
		end
	end)
	bottomIconTooltip(nextPageBtn, "Next Page", "Show the next page of requests.")
	self.NextPageBtn = nextPageBtn

	-- Previous page
	local prevPageBtn = CreateFrame("Button", nil, window.frame)
	prevPageBtn:SetSize(22, 22)
	prevPageBtn:SetFrameLevel(window.frame:GetFrameLevel() + 10)  -- HITBOX-001
	prevPageBtn:SetPoint("RIGHT", nextPageBtn, "LEFT", -8, 0)
	prevPageBtn:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
	prevPageBtn:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down")
	prevPageBtn:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Disabled")
	prevPageBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	prevPageBtn:SetScript("OnClick", function()
		if self.currentPage > 1 then
			self.currentPage = self.currentPage - 1
			self:DrawRows()
		end
	end)
	bottomIconTooltip(prevPageBtn, "Previous Page", "Show the previous page of requests.")
	self.PrevPageBtn = prevPageBtn

	-- Cancel Stale (broom) — officers/bankers only. INV_Broom_01 is the Hallow's End
	-- Magic Broom icon, a stock Classic Era texture.
	-- Clear any stale reference first: if banker status was lost since the previous
	-- window, this block won't run and the status-bar inset below must see nil.
	self.CancelStaleBtn = nil
	if isOfficerOrBanker then
		local cancelStaleBtn = CreateFrame("Button", nil, window.frame)
		cancelStaleBtn:SetSize(22, 22)
		cancelStaleBtn:SetFrameLevel(window.frame:GetFrameLevel() + 10)  -- HITBOX-001
		cancelStaleBtn:SetPoint("RIGHT", prevPageBtn, "LEFT", -8, 0)
		cancelStaleBtn:SetNormalTexture("Interface\\Icons\\INV_Broom_01")
		cancelStaleBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
		cancelStaleBtn:SetScript("OnClick", function()
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
		cancelStaleBtn:SetScript("OnEnter", function(f)
			local days = TOGBankClassic_Options and TOGBankClassic_Options:GetAutoTombstoneDays() or 30
			GameTooltip:SetOwner(f, "ANCHOR_TOP")
			GameTooltip:ClearLines()
			GameTooltip:AddLine("Cancel Stale Requests")
			GameTooltip:AddLine(string.format(
				"Permanently cancels all open requests older than %d days and broadcasts the cancellation guild-wide.\n\nThe threshold is configured in the Settings tab.",
				days), 0.9, 0.9, 0.9, true)
			GameTooltip:Show()
		end)
		cancelStaleBtn:SetScript("OnLeave", function()
			TOGBankClassic_UI:HideTooltip()
		end)
		self.CancelStaleBtn = cancelStaleBtn
	end

	-- Fulfill Oldest Order (envelope) — bankers only. One click sends the oldest
	-- order you can fully fill from bags to its requester (auto split + attach +
	-- send); spam it to drain the queue oldest-first. FILLALL-001. Sits left of the
	-- broom (a banker always also has the broom, since banker implies the cluster).
	self.FulfillOldestBtn = nil
	local isBanker = (actor and TOGBankClassic_Guild:IsBank(actor)) or false
	if isBanker then
		local fulfillBtn = CreateFrame("Button", nil, window.frame)
		fulfillBtn:SetSize(22, 22)
		fulfillBtn:SetFrameLevel(window.frame:GetFrameLevel() + 10)  -- HITBOX-001
		fulfillBtn:SetPoint("RIGHT", self.CancelStaleBtn or prevPageBtn, "LEFT", -8, 0)
		fulfillBtn:SetNormalTexture("Interface\\Icons\\INV_Letter_15")
		fulfillBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
		fulfillBtn:SetScript("OnClick", function()
			local _, message = TOGBankClassic_Mail:FulfillStep(actor)
			if self.Window then self.Window:SetStatusText(message or "") end
		end)
		fulfillBtn:SetScript("OnEnter", function(f)
			GameTooltip:SetOwner(f, "ANCHOR_TOP")
			GameTooltip:ClearLines()
			GameTooltip:AddLine("Fulfill Oldest Order")
			GameTooltip:AddLine("Click to advance the oldest order you can fully fill, one step per click: select \226\134\146 split \226\134\146 attach \226\134\146 send, then the next-oldest. If the needed items are sitting in your mail, it pulls them into your bags first (one per click). Watch the status bar for the next step. Requires an open mailbox; orders you can't fully cover (from bags + mail) are skipped.", 0.9, 0.9, 0.9, true)
			GameTooltip:Show()
		end)
		fulfillBtn:SetScript("OnLeave", function()
			TOGBankClassic_UI:HideTooltip()
		end)
		self.FulfillOldestBtn = fulfillBtn
	end

	-- Extend the status bar's right edge to just left of whichever icon is leftmost
	-- (fulfill → broom → prev), anchored to the icon itself so the gap stays correct
	-- no matter which icons are present. All icons are 22px at bottom y=15.
	local leftmostBottomIcon = self.FulfillOldestBtn or self.CancelStaleBtn or prevPageBtn
	statusbg:SetPoint("BOTTOMRIGHT", leftmostBottomIcon, "BOTTOMLEFT", -6, 0)

	self.HeaderWidgets = nil
	self.FilterWidgets = nil
	self.FilterRequester = nil
	self.FilterBank = nil
	self.TabGroup = nil
	-- Settings overlay is parented to this window; drop the stale reference so
	-- BuildSettingsPanel rebuilds it against the freshly created window frame.
	self.SettingsOverlay = nil
	self.SettingsArchiveEB = nil
	self.SettingsTombstoneEB = nil
	self.SettingsMaxPctEB = nil
	-- Cancel-reason editor widgets are children of the rebuilt overlay; drop the
	-- stale refs (and the row pool) so RefreshReasonsList builds against the new one.
	self.ReasonInput = nil
	self.ReasonNewMember = nil
	self.ReasonNewBanker = nil
	self.ReasonSaveBtn = nil
	self.ReasonScroll = nil
	self.ReasonContent = nil
	self.ReasonRows = nil
	self.ReasonEditIndex = nil

	-- Tab strip — AceGUI TabGroup for the proper WoW tab look (matches FGI). Used
	-- purely as a tab bar: its content box is hidden and the request list /
	-- settings panel render below it as separate window children. The "Settings"
	-- tab is GM/officer-only (CanViewOfficerNote is true for GM and officers).
	local TAB_TOOLTIPS = {
		active   = { title = "Requests", body = "Open requests waiting to be fulfilled." },
		archive  = { title = "Archive",  body = "Completed and cancelled requests." },
		settings = { title = "Settings", body = "Configure request thresholds and custom cancel reasons. Officers only." },
	}
	local tabGroup = TOGBankClassic_UI:Create("TabGroup")
	tabGroup:SetFullWidth(true)
	-- Just tall enough to contain the tab row (anchored at y=-7, 24px tall);
	-- keeps the gap to the filter dropdowns below tight.
	tabGroup:SetHeight(30)
	local tabList = {
		{ text = "Requests", value = "active" },
		{ text = "Archive",  value = "archive" },
	}
	if canOfficer then
		tabList[#tabList + 1] = { text = "Settings", value = "settings" }
	end
	tabGroup:SetTabs(tabList)
	-- Hide the empty content-area box; we only want the tabs themselves. The tab
	-- buttons are anchored to the widget frame, so they stay visible.
	if tabGroup.border then
		tabGroup.border:SetBackdrop(nil)
	end
	tabGroup:SetCallback("OnGroupSelected", function(_, _, value)
		if self.currentTab == value then return end
		self.currentTab = value
		self:DrawContent()
	end)
	tabGroup:SetCallback("OnTabEnter", function(_, _, value, tabFrame)
		local tip = TAB_TOOLTIPS[value]
		if not tip or not tabFrame then return end
		GameTooltip:SetOwner(tabFrame, "ANCHOR_BOTTOM")
		GameTooltip:ClearLines()
		GameTooltip:AddLine(tip.title)
		GameTooltip:AddLine(tip.body, 0.9, 0.9, 0.9, true)
		GameTooltip:Show()
	end)
	tabGroup:SetCallback("OnTabLeave", function() TOGBankClassic_UI:HideTooltip() end)
	window:AddChild(tabGroup)
	self.TabGroup = tabGroup

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
		-- -3 y adds a little breathing room between the filter dropdowns and the
		-- column headers.
		headerGroup.content:SetPoint("TOPLEFT", 8, -3)
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

	-- Officer-only Settings tab needs its overlay panel built once per window.
	if canOfficer then
		self:BuildSettingsPanel()
	end

	-- A persisted "settings" tab is meaningless for a non-officer; fall back.
	if self.currentTab == "settings" and not canOfficer then
		self.currentTab = "active"
	end
	-- Reflect the current tab in the TabGroup's visual selection. DrawContent
	-- (the actual draw) runs from Open() after this; the OnGroupSelected guard
	-- suppresses a redundant draw here.
	self.TabGroup:SelectTab(self.currentTab or "active")
end

-- Attach a hover tooltip to a FontString (labels/headers don't take mouse
-- events themselves) via an invisible hit frame matching its bounds, padded a
-- little so small labels are easy to hover.
local function attachLabelTooltip(parent, fs, title, body)
	local hit = CreateFrame("Frame", nil, parent)
	hit:SetPoint("TOPLEFT", fs, "TOPLEFT", -2, 2)
	hit:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 2, -2)
	hit:EnableMouse(true)
	hit:SetScript("OnEnter", function(f)
		GameTooltip:SetOwner(f, "ANCHOR_BOTTOM")
		GameTooltip:ClearLines()
		GameTooltip:AddLine(title)
		if body and body ~= "" then
			GameTooltip:AddLine(body, 0.9, 0.9, 0.9, true)
		end
		GameTooltip:Show()
	end)
	hit:SetScript("OnLeave", function() TOGBankClassic_UI:HideTooltip() end)
	return hit
end

-- Build the officer-only Settings panel: an opaque overlay covering the request
-- list, with editable fields for the three request settings. The setters mirror
-- the Blizzard options panel (Modules/Options.lua) so guild-wide sync still fires.
function TOGBankClassic_UI_Requests:BuildSettingsPanel()
	if self.SettingsOverlay or not self.Window or not self.TabGroup then
		return
	end
	local window = self.Window

	local overlay = CreateFrame("Frame", nil, window.frame, "BackdropTemplate")
	overlay:SetFrameLevel(window.frame:GetFrameLevel() + 50)
	overlay:SetPoint("TOPLEFT", self.TabGroup.frame, "BOTTOMLEFT", 4, -4)
	overlay:SetPoint("BOTTOMRIGHT", window.frame, "BOTTOMRIGHT", -16, 40)
	overlay:SetBackdrop({
		bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	overlay:EnableMouse(true)  -- swallow clicks so they don't reach the list behind
	overlay:Hide()
	self.SettingsOverlay = overlay

	-- All three numeric settings sit on a single compact row; the full
	-- descriptions live on each label's hover tooltip (not the edit box, so the
	-- tooltip doesn't get in the way while typing). No "Request Settings" title —
	-- the tab already says Settings.
	local FIELD_Y = -20
	local function compactField(prevEB, gap, labelText, tipTitle, tipBody, commit)
		local lbl = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		if prevEB then
			lbl:SetPoint("LEFT", prevEB, "RIGHT", gap, 0)
		else
			lbl:SetPoint("TOPLEFT", overlay, "TOPLEFT", 20, FIELD_Y)
		end
		lbl:SetText(labelText)
		attachLabelTooltip(overlay, lbl, tipTitle, tipBody .. "\n\nPress Enter to apply.")

		local eb = CreateFrame("EditBox", nil, overlay, "InputBoxTemplate")
		eb:SetAutoFocus(false)
		eb:SetNumeric(true)
		eb:SetMaxLetters(4)
		eb:SetSize(42, 20)
		eb:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
		eb:SetJustifyH("CENTER")
		eb:SetScript("OnEnterPressed", function(box) commit(box) box:ClearFocus() end)
		eb:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
		eb:SetScript("OnEditFocusLost", function(box) commit(box) end)
		return eb
	end

	self.SettingsArchiveEB = compactField(nil, 0,
		"Archive (days):",
		"Archive threshold (days)",
		"Requests older than this many days move to the Archive tab.",
		function(box)
			local n = tonumber(box:GetText())
			local opt = TOGBankClassic_Options
			local current = (opt and opt.db and opt.db.global and opt.db.global.requests
				and opt.db.global.requests.archiveDays) or 30
			if n and n >= 1 then
				n = math.floor(n)
				if n ~= current and opt and opt.db then
					opt.db.global.requests.archiveDays = n
					TOGBankClassic_Output:Info("Archive threshold set to %d days.", n)
				end
			end
			self:PopulateSettings()
		end)

	self.SettingsTombstoneEB = compactField(self.SettingsArchiveEB, 18,
		"Auto-cancel (days):",
		"Auto-cancel stale (days)",
		"Open requests older than this are auto-cancelled on sync. Syncs guild-wide.",
		function(box)
			local n = tonumber(box:GetText())
			local current = (TOGBankClassic_Options and TOGBankClassic_Options:GetAutoTombstoneDays()) or 30
			if n and n >= 1 then
				n = math.floor(n)
				if n ~= current then
					-- Write to guild-synced settings so every client applies the same threshold.
					if TOGBankClassic_Guild and TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.settings then
						TOGBankClassic_Guild.Info.settings.autoTombstoneDays = n
					end
					if TOGBankClassic_Options and TOGBankClassic_Options.db then
						TOGBankClassic_Options.db.global.requests.autoTombstoneDays = n
					end
					TOGBankClassic_Guild:BroadcastSettings("ALERT")  -- SETTINGS-001
					TOGBankClassic_Output:Info("Auto-cancel stale threshold set to %d days (syncing to guild...).", n)
				end
			end
			self:PopulateSettings()
		end)

	self.SettingsMaxPctEB = compactField(self.SettingsTombstoneEB, 18,
		"Max request (%):",
		"Maximum request amount (%)",
		"Caps how much of available inventory anyone can request at once (1-100). Syncs guild-wide.",
		function(box)
			local n = tonumber(box:GetText())
			local current = (TOGBankClassic_Options and TOGBankClassic_Options:GetMaxRequestPercent()) or 100
			if n then
				n = math.floor(n)
				if n < 1 then n = 1 elseif n > 100 then n = 100 end
				if n ~= current then
					if TOGBankClassic_Guild and TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.settings then
						TOGBankClassic_Guild.Info.settings.maxRequestPercent = n
					end
					if TOGBankClassic_Options and TOGBankClassic_Options.db then
						TOGBankClassic_Options.db.global.requests.maxRequestPercent = n
					end
					TOGBankClassic_Guild:BroadcastSettings("ALERT")  -- SETTINGS-001
					TOGBankClassic_Output:Info("Maximum request amount set to %d%% (syncing to guild...).", n)
				end
			end
			self:PopulateSettings()
		end)

	-- CANCELREASON-001: custom cancel-reason editor below the numeric settings.
	self:BuildReasonsEditor(overlay)
end

-- ---------------------------------------------------------------------------
-- CANCELREASON-001 — officer-only custom cancel-reason editor.
-- Styled after the FGI Filters tab: a [Member][Banker][reason][Save] strip over
-- a banded, scrolling list. Built-in presets appear greyed/read-only with a
-- single native-role tick officers can clear; custom rows have both ticks + a
-- delete X and are click-to-edit. All edits write to the guild-synced
-- Info.settings.cancelReasons and re-broadcast.
-- ---------------------------------------------------------------------------
local REASON_ROW_H    = 18
local REASON_MEMBER_X = 8    -- row-local x of the Member checkbox
local REASON_BANKER_X = 42   -- row-local x of the Banker checkbox
local REASON_TEXT_X   = 80   -- row-local x where the reason text starts
local REASON_MAX_LEN  = 160  -- mirrors Guild.SanitizeCancelReasons clamp
local REASON_MAX      = 20   -- mirrors Guild CANCEL_REASON_MAX_CUSTOM

function TOGBankClassic_UI_Requests:_EnsureReasonConfig()
	local g = TOGBankClassic_Guild
	if not (g and g.Info and g.Info.settings) then return nil end
	local s = g.Info.settings
	if type(s.cancelReasons) ~= "table" then s.cancelReasons = {} end
	local cr = s.cancelReasons
	if type(cr.custom) ~= "table" then cr.custom = {} end
	if type(cr.presetDisabled) ~= "table" then cr.presetDisabled = {} end
	if type(cr.presetDisabled.banker) ~= "table" then cr.presetDisabled.banker = {} end
	if type(cr.presetDisabled.member) ~= "table" then cr.presetDisabled.member = {} end
	return cr
end

function TOGBankClassic_UI_Requests:BuildReasonsEditor(overlay)
	local header = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	header:SetPoint("TOPLEFT", overlay, "TOPLEFT", 20, -52)
	header:SetText("Custom Cancel Reasons")
	-- The how-to text lives on the header's hover tooltip rather than a visible line.
	attachLabelTooltip(overlay, header, "Custom Cancel Reasons",
		"Reasons offered when cancelling a request, on top of the built-in ones. Tick Member and/or Banker to choose where each reason appears. Type a reason and press Save (or Enter) to add it; click a custom row to edit it, or the X to delete it. Built-in reasons are locked (greyed) but can be un-ticked to stop offering them. Everything here syncs to the whole guild.")

	-- Column headers
	local colY = -78
	local mHdr = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	mHdr:SetPoint("TOPLEFT", overlay, "TOPLEFT", 20 + REASON_MEMBER_X - 2, colY)
	mHdr:SetText("Mbr")
	attachLabelTooltip(overlay, mHdr, "Member",
		"Tick to offer this reason in the dropdown a member sees when cancelling their own request.")
	local bHdr = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bHdr:SetPoint("TOPLEFT", overlay, "TOPLEFT", 20 + REASON_BANKER_X - 2, colY)
	bHdr:SetText("Bnk")
	attachLabelTooltip(overlay, bHdr, "Banker",
		"Tick to offer this reason in the dropdown a banker sees when cancelling someone else's request.")
	local rHdr = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	rHdr:SetPoint("TOPLEFT", overlay, "TOPLEFT", 20 + REASON_TEXT_X, colY)
	rHdr:SetText("Reason")
	attachLabelTooltip(overlay, rHdr, "Reason",
		"The cancellation message shown to the requester. Built-in reasons are greyed and can't be edited; your custom reasons can be clicked to edit or deleted with the X.")

	-- Input strip
	local inputY = -100
	local newMember = CreateFrame("CheckButton", nil, overlay, "UICheckButtonTemplate")
	newMember:SetSize(REASON_ROW_H, REASON_ROW_H)
	newMember:SetPoint("TOPLEFT", overlay, "TOPLEFT", 20 + REASON_MEMBER_X - 4, inputY)
	newMember:SetChecked(true)
	self.ReasonNewMember = newMember

	local newBanker = CreateFrame("CheckButton", nil, overlay, "UICheckButtonTemplate")
	newBanker:SetSize(REASON_ROW_H, REASON_ROW_H)
	newBanker:SetPoint("TOPLEFT", overlay, "TOPLEFT", 20 + REASON_BANKER_X - 4, inputY)
	newBanker:SetChecked(true)
	self.ReasonNewBanker = newBanker

	local saveBtn = CreateFrame("Button", nil, overlay, "UIPanelButtonTemplate")
	saveBtn:SetSize(54, 22)
	saveBtn:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", -16, inputY + 1)
	saveBtn:SetText("Save")
	self.ReasonSaveBtn = saveBtn

	local input = CreateFrame("EditBox", nil, overlay, "InputBoxTemplate")
	input:SetAutoFocus(false)
	input:SetMaxLetters(REASON_MAX_LEN)
	input:SetHeight(20)
	input:SetPoint("TOPLEFT", overlay, "TOPLEFT", 20 + REASON_TEXT_X + 6, inputY)
	input:SetPoint("RIGHT", saveBtn, "LEFT", -10, 0)
	self.ReasonInput = input

	local function doSaveReason()
		local text = strtrim(input:GetText() or "")
		if text == "" then return end
		local cfg = self:_EnsureReasonConfig()
		if not cfg then return end
		local member = newMember:GetChecked() and true or false
		local banker = newBanker:GetChecked() and true or false
		if self.ReasonEditIndex and cfg.custom[self.ReasonEditIndex] then
			local c = cfg.custom[self.ReasonEditIndex]
			c.text, c.member, c.banker = text, member, banker
		else
			if #cfg.custom >= REASON_MAX then
				self.Window:SetStatusText(string.format("Custom reason limit reached (%d).", REASON_MAX))
				return
			end
			cfg.custom[#cfg.custom + 1] = { text = text, member = member, banker = banker }
		end
		self.ReasonEditIndex = nil
		input:SetText("")
		newMember:SetChecked(true)
		newBanker:SetChecked(true)
		input:ClearFocus()
		TOGBankClassic_Guild:BroadcastSettings("ALERT")
		self:RefreshReasonsList()
	end
	saveBtn:SetScript("OnClick", doSaveReason)
	input:SetScript("OnEnterPressed", doSaveReason)
	input:SetScript("OnEscapePressed", function(box)
		self.ReasonEditIndex = nil
		box:SetText("")
		box:ClearFocus()
	end)

	-- Scrolling list
	local scroll = CreateFrame("ScrollFrame", "TOGBankClassicReasonsScroll", overlay, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", overlay, "TOPLEFT", 20, -126)
	scroll:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", -28, 14)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(f, delta)
		local newv = f:GetVerticalScroll() - delta * (REASON_ROW_H * 3)
		local maxv = f:GetVerticalScrollRange()
		if newv < 0 then newv = 0 elseif newv > maxv then newv = maxv end
		f:SetVerticalScroll(newv)
	end)
	self.ReasonScroll = scroll

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(10, 10)
	scroll:SetScrollChild(content)
	self.ReasonContent = content
	self.ReasonRows = {}
	self.ReasonEditIndex = nil
end

-- Create one reusable reason row (checkboxes + text + delete). Handlers read
-- row._entry so the same frame can be rebound across refreshes.
function TOGBankClassic_UI_Requests:_BuildReasonRow()
	local row = CreateFrame("Button", nil, self.ReasonContent)
	row:SetHeight(REASON_ROW_H)

	local bg = row:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(row)
	bg:SetColorTexture(1, 1, 1, 0.04)
	row.bg = bg

	local mcb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	mcb:SetSize(REASON_ROW_H, REASON_ROW_H)
	mcb:SetPoint("LEFT", row, "LEFT", REASON_MEMBER_X, 0)
	row.memberCB = mcb

	local bcb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	bcb:SetSize(REASON_ROW_H, REASON_ROW_H)
	bcb:SetPoint("LEFT", row, "LEFT", REASON_BANKER_X, 0)
	row.bankerCB = bcb

	local del = CreateFrame("Button", nil, row)
	del:SetSize(14, 14)
	del:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	del:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
	del:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	row.deleteBtn = del

	local txt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	txt:SetPoint("LEFT", row, "LEFT", REASON_TEXT_X, 0)
	txt:SetPoint("RIGHT", del, "LEFT", -6, 0)
	txt:SetJustifyH("LEFT")
	txt:SetWordWrap(false)
	row.text = txt

	mcb:SetScript("OnClick", function(cb)
		if row._entry then self:_OnReasonToggle(row._entry, "member", cb:GetChecked() and true or false) end
	end)
	bcb:SetScript("OnClick", function(cb)
		if row._entry then self:_OnReasonToggle(row._entry, "banker", cb:GetChecked() and true or false) end
	end)
	del:SetScript("OnClick", function()
		local e = row._entry
		if e and e.kind == "custom" then self:_OnReasonDelete(e.index) end
	end)
	del:SetScript("OnEnter", function(f)
		GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
		GameTooltip:SetText("Delete this reason", 1, 1, 1)
		GameTooltip:Show()
	end)
	del:SetScript("OnLeave", function() TOGBankClassic_UI:HideTooltip() end)
	row:SetScript("OnClick", function()
		local e = row._entry
		if e and e.kind == "custom" then self:_OnReasonEdit(e.index) end
	end)

	return row
end

function TOGBankClassic_UI_Requests:_ConfigureReasonRow(row, entry, idx)
	row._entry = entry
	row.bg:SetShown(idx % 2 == 0)
	row.text:SetText(entry.text or "")
	if entry.kind == "preset" then
		row.text:SetTextColor(0.5, 0.5, 0.5)  -- greyed: locked text
		row.deleteBtn:Hide()
		local disabled = presetDisabledSet(entry.role)
		local on = not disabled[entry.key]
		if entry.role == "member" then
			row.memberCB:Show(); row.memberCB:SetChecked(on)
			row.bankerCB:Hide()
		else
			row.bankerCB:Show(); row.bankerCB:SetChecked(on)
			row.memberCB:Hide()
		end
	else
		row.text:SetTextColor(1, 1, 1)
		row.deleteBtn:Show()
		row.memberCB:Show(); row.memberCB:SetChecked(entry.member and true or false)
		row.bankerCB:Show(); row.bankerCB:SetChecked(entry.banker and true or false)
	end
end

function TOGBankClassic_UI_Requests:_OnReasonToggle(entry, column, checked)
	local cfg = self:_EnsureReasonConfig()
	if not cfg then return end
	if entry.kind == "preset" then
		-- Only the native-role checkbox is shown for presets; checked = offered.
		local set = cfg.presetDisabled[entry.role]
		if checked then set[entry.key] = nil else set[entry.key] = true end
	else
		local c = cfg.custom[entry.index]
		if c then c[column] = checked end
		entry[column] = checked
	end
	TOGBankClassic_Guild:BroadcastSettings("ALERT")
end

function TOGBankClassic_UI_Requests:_OnReasonDelete(index)
	local cfg = self:_EnsureReasonConfig()
	if not cfg or not cfg.custom[index] then return end
	table.remove(cfg.custom, index)
	if self.ReasonEditIndex == index then
		self.ReasonEditIndex = nil
		if self.ReasonInput then self.ReasonInput:SetText("") end
	elseif self.ReasonEditIndex and self.ReasonEditIndex > index then
		self.ReasonEditIndex = self.ReasonEditIndex - 1
	end
	TOGBankClassic_Guild:BroadcastSettings("ALERT")
	self:RefreshReasonsList()
end

function TOGBankClassic_UI_Requests:_OnReasonEdit(index)
	local cfg = self:_EnsureReasonConfig()
	local c = cfg and cfg.custom[index]
	if not c then return end
	self.ReasonEditIndex = index
	self.ReasonInput:SetText(c.text or "")
	self.ReasonNewMember:SetChecked(c.member and true or false)
	self.ReasonNewBanker:SetChecked(c.banker and true or false)
	self.ReasonInput:SetFocus()
end

-- Rebuild the reason rows: banker presets, member presets, then custom reasons.
function TOGBankClassic_UI_Requests:RefreshReasonsList()
	if not self.ReasonContent or not self.ReasonScroll then return end
	self.ReasonRows = self.ReasonRows or {}

	local entries = {}
	for _, p in ipairs(buildPresetReasons("banker")) do
		entries[#entries + 1] = { kind = "preset", role = "banker", key = p.key, text = p.label }
	end
	for _, p in ipairs(buildPresetReasons("member")) do
		entries[#entries + 1] = { kind = "preset", role = "member", key = p.key, text = p.label }
	end
	for i, c in ipairs(customReasonList()) do
		if type(c) == "table" then
			entries[#entries + 1] = { kind = "custom", index = i, text = c.text or "", member = c.member, banker = c.banker }
		end
	end

	local width = self.ReasonScroll:GetWidth()
	if not width or width < 10 then width = 200 end
	self.ReasonContent:SetWidth(width)
	self.ReasonContent:SetHeight(math.max(1, #entries * REASON_ROW_H))

	for i, entry in ipairs(entries) do
		local row = self.ReasonRows[i]
		if not row then
			row = self:_BuildReasonRow()
			self.ReasonRows[i] = row
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", self.ReasonContent, "TOPLEFT", 0, -((i - 1) * REASON_ROW_H))
		row:SetPoint("RIGHT", self.ReasonContent, "RIGHT", 0, 0)
		self:_ConfigureReasonRow(row, entry, i)
		row:Show()
	end
	for i = #entries + 1, #self.ReasonRows do
		self.ReasonRows[i]:Hide()
	end
end

-- Fill the Settings editboxes from current values (called when the tab opens
-- and after each commit so clamped/normalised values are reflected).
function TOGBankClassic_UI_Requests:PopulateSettings()
	if not self.SettingsOverlay then
		return
	end
	local opt = TOGBankClassic_Options
	local archiveDays = 30
	if opt and opt.db and opt.db.global and opt.db.global.requests then
		archiveDays = opt.db.global.requests.archiveDays or 30
	end
	if self.SettingsArchiveEB then self.SettingsArchiveEB:SetText(tostring(archiveDays)) end
	if self.SettingsTombstoneEB then
		self.SettingsTombstoneEB:SetText(tostring(opt and opt:GetAutoTombstoneDays() or 30))
	end
	if self.SettingsMaxPctEB then
		self.SettingsMaxPctEB:SetText(tostring(opt and opt:GetMaxRequestPercent() or 100))
	end
end

-- Toggle between the Settings panel and the request list. The bottom-row
-- pagination/Cancel-Stale icons are meaningless on the Settings tab, so hide them.
function TOGBankClassic_UI_Requests:ShowSettings(show)
	if show then
		if not self.SettingsOverlay then return end
		self:PopulateSettings()
		self:RefreshReasonsList()
		self.SettingsOverlay:Show()
		if self.PrevPageBtn then self.PrevPageBtn:Hide() end
		if self.NextPageBtn then self.NextPageBtn:Hide() end
		if self.CancelStaleBtn then self.CancelStaleBtn:Hide() end
		self.Window:SetStatusText("Officer settings — changes to the last two sync guild-wide.")
	else
		if self.SettingsOverlay then self.SettingsOverlay:Hide() end
		if self.PrevPageBtn then self.PrevPageBtn:Show() end
		if self.NextPageBtn then self.NextPageBtn:Show() end
		if self.CancelStaleBtn then self.CancelStaleBtn:Show() end
	end
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
			attachActionTooltip(completeButton, "Mark hand-off", "Record how many you gave the requester directly (not by mail). Enter a quantity; it goes into the Sent column, and the order completes once Sent reaches the amount requested.")
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
		local headerLabel = self.HeaderWidgets[i]
		if not headerLabel then
			-- Plain clickable sort header (no button background), justified to match
			-- the column's data cells so headers and rows line up. Mirrors the FGI
			-- RowList column headers. Gold text + hover glow signal click-to-sort.
			headerLabel = TOGBankClassic_UI:Create("InteractiveLabel")
			self.HeaderWidgets[i] = headerLabel
			tagColumnWidget(headerLabel, i, false)
			if headerLabel.label then
				headerLabel.label:SetFontObject("GameFontNormal")
				-- headerAlign overrides the data alignment for the header text only
				-- (e.g. center the "#" / "Item" headers while their cells stay
				-- right/left). Falls back to the column's data alignment.
				headerLabel.label:SetJustifyH(justifyForAlign(col.headerAlign or col.align))
				headerLabel.label:SetWordWrap(false)
			end
			headerLabel:SetHighlight("Interface\\QuestFrame\\UI-QuestTitleHighlight")
			local colKey = col.key
			headerLabel:SetCallback("OnClick", function()
				if self.sortColumn == colKey then
					self.sortDirection = (self.sortDirection == "asc") and "desc" or "asc"
				else
					self.sortColumn = colKey
					self.sortDirection = "desc"
				end
				self:DrawContent()
			end)
			if col.tooltipTitle then
				attachActionTooltip(headerLabel, col.tooltipTitle, col.tooltipDetail)
			end
			self.HeaderGroup:AddChild(headerLabel)
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
		-- headerSuffix nudges a right-justified header in by ~1 char (e.g. "#" sits
		-- over the first digit of the right-aligned quantity rather than the "x").
		if col.headerSuffix then
			label = label .. col.headerSuffix
		end
		local headerLabel = self.HeaderWidgets[i]

		headerLabel:SetText(label)
		local columnWidth = (self.ColumnWidths and self.ColumnWidths[i]) or col.width
		headerLabel:SetWidth(columnWidth)
		setWidgetShown(headerLabel, true)
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
				-- COMPLETEQTY-001: instead of silently marking complete, ask how many
				-- were handed over directly; the amount goes into the Sent column.
				row.completeButton:SetCallback("OnClick", function()
					if not requestId then return end
					showCompleteQtyPrompt(req, actor)
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
	
	-- Apply pagination: only show rows for current page. Clamp the page to the
	-- valid range so a background refresh after the data shrank can't strand the
	-- view on an out-of-range (empty) page.
	self.currentPage = self.currentPage or 1
	local totalPages = math.max(1, math.ceil(totalVisible / REQUESTS_PER_PAGE))
	if self.currentPage > totalPages then self.currentPage = totalPages end
	if self.currentPage < 1 then self.currentPage = 1 end
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
		setBtnEnabled(self.PrevPageBtn, self.currentPage > 1)
		setBtnEnabled(self.NextPageBtn, self.currentPage < totalPages)

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
			setBtnEnabled(self.PrevPageBtn, self.currentPage > 1)
			setBtnEnabled(self.NextPageBtn, self.currentPage < totalPages)

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
	-- Reset to the first page only when the tab actually changed. Background
	-- request syncs call DrawContent too (via RefreshRequestsUI); resetting the
	-- page there would snap the user back to page 1 mid-browse (the "snap back"
	-- bug). DrawRows clamps currentPage if the data shrank.
	if self._lastDrawnTab ~= self.currentTab then
		self.currentPage = 1
		self._lastDrawnTab = self.currentTab
	end

	-- Settings tab shows the officer panel instead of the request list.
	if self.currentTab == "settings" then
		self:ShowSettings(true)
		return
	end
	self:ShowSettings(false)

	self:UpdateColumnLayout()
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


