TOGBankClassic_UI_Requests = {}

-- REQUESTS-ROWLIST-001. The operator, 2026-09-13, with a screenshot of this tab beside the Browse
-- tab: "we need to make the request tab look and feel like the browse and bankers tab looks. right
-- now it's different. we need the same zebra striping/spaceing etc." So the body is a
-- TOGBankClassic_UI_RowList (Modules/UI/RowList.lua) -- the same 16px banded rows, fonts, header
-- rule and scrollbar as the Browse, Bankers and Log tabs -- and the AceGUI label grid it replaced,
-- with its 50-a-page pagination and its own column-width arithmetic, is gone: the list scrolls the
-- whole set virtually, so there is nothing to page. Three columns own their cells (RowList `build`):
-- the date (the status glyph, the cancelled glow and the timeline tooltip), the item (the copyable
-- overlay and the item tooltip) and the actions (the icon strip). This resolves REQUESTS-LAYOUT-001
-- by its candidate (a): the fixed-offset grid that set the Guild Bank window's 972px floor is what
-- went.
--
-- SEARCH-006: `search = true` marks a column the ONE search box (above the dropdowns) matches
-- against -- the operator's Discord ask of 2026-08-19 ("add search on requestors to find someone
-- easily"), then on 2026-09-11 "one bar that filters on all columns". The four text columns are
-- searched; `#`, `Sent` and `Actions` are not -- a number or a button row is not something to
-- search. (SEARCH-005 briefly put a box under each of the four; that row is gone.)
-- `width` is the RowList's: fixed columns chained either side of the one auto column (the item).
local COLUMNS = {
	{ key = "date",      header = "Date",      width = 118, justify = "LEFT", search = true, headerTip = "When the request was submitted. Click to sort." },
	{ key = "requester", header = "Requester", width = 128, justify = "LEFT", search = true, headerTip = "The guild member who submitted the request. Click to sort." },
	{ key = "bank",      header = "Bank",      width = 128, justify = "LEFT", search = true, headerTip = "The banker character this request is assigned to. Click to sort." },
	{ key = "quantity",  header = "#",         width = 36,  justify = "RIGHT",               headerTip = "The number of items requested. Click to sort." },
	{ key = "item",      header = "Item",                   justify = "LEFT", search = true, headerTip = "The item being requested. Click to sort." },
	{ key = "fulfilled", header = "Sent",      width = 36,  justify = "RIGHT",               headerTip = "How many items have been sent to the requester so far. Click to sort." },
	{ key = "actions",   header = "Actions",   width = 96,  justify = "LEFT", sortable = false, headerTip = "Fulfill, mark handed over, cancel, delete or re-open the request." },
}

-- The item column's narrowest useful width: an item name in the small font.
local ITEM_MIN_WIDTH = 150

-- REQUESTS-STRIP-001: the filter strip's inset from the tab border -- UI.FILTER_INSET, the ONE
-- number Browse's strips read too, so the tabs' left edges line up -- and the gap between the
-- strip and the list.
local FILTER_INSET = TOGBankClassic_UI.FILTER_INSET
local LIST_GAP = 10
-- REQUESTS-STRIP-002: the Requests/Archive/Settings sub-tab row's height -- the 24px tab buttons
-- at y=-7 (AceGUI TabGroup) end at 31; the filter strip hangs under this, so the difference is the
-- clearance between the tab bottoms and the strip. One number.
local SUBTAB_H = 39

--- BROWSE-007: the narrowest window this body fits in -- every fixed column, the list's own
--- padding and gutter, and the item column at its narrowest useful width. The standalone window
--- uses it as its resize floor and the Guild Bank window reads it for ITS floor (Browse.ResizeFloor),
--- because it hosts this body on a tab. The operator: "the window can shrink smaller than the
--- columns, and the column headers float outside the window." REQUESTS-LAYOUT-001: the old grid's
--- 972 came down with the grid -- the RowList's auto column absorbs the width, and the fixed columns
--- are narrower in the small font.
---@return number
local function minWidth()
	local RowList = TOGBankClassic_UI_RowList
	local total = ITEM_MIN_WIDTH
	for _, col in ipairs(COLUMNS) do
		if col.width then total = total + col.width + (RowList and RowList.COL_GAP or 4) end
	end
	total = total + (RowList and (RowList.LEFT_PAD + RowList.SCROLLBAR_GUTTER) or 28)
	-- The AceGUI Frame's own insets either side of its content.
	return total + 40
end
function TOGBankClassic_UI_Requests:MinWidth()
	return minWidth()
end

-- The action icons, sized for the RowList's 16px row.
local CANCEL_ICON = "|TInterface\\RAIDFRAME\\ReadyCheck-NotReady:14:14:0:0|t"
local COMPLETE_ICON = "|TInterface\\Buttons\\UI-CheckBox-Check:14:14:0:0|t"
local DELETE_ICON = "|TInterface\\Buttons\\UI-GroupLoot-Pass-Up:14:14:0:0|t"
local FULFILL_ICON = "|TInterface\\Icons\\INV_Letter_15:14:14:0:0|t"
-- REOPEN-001: re-open icon. NOTE: Classic Era is missing many textures (see the broom saga,
-- BROOM-001); if this renders blank in-game, swap the texture or bundle a TGA like Textures/broom.
local REOPEN_ICON = "|TInterface\\Buttons\\UI-RefreshButton:14:14:0:0|t"
-- Contextual fulfill button icons based on state
local FULFILL_ICON_READY = "|TInterface\\Icons\\INV_Letter_15:14:14:0:0|t"        -- Envelope: ready to send
local FULFILL_ICON_NO_MAILBOX = "|TInterface\\Icons\\INV_Letter_02:14:14:0:0|t"   -- Sealed letter: need mailbox
local FULFILL_ICON_NOT_IN_BAGS = "|TInterface\\Icons\\INV_Misc_Bag_07:14:14:0:0|t" -- Bag: pick up from bank
local FULFILL_ICON_IN_MAIL         = "|TInterface\\Icons\\INV_Letter_06:14:14:0:0|t"                                                  -- Wax-sealed letter: item is in your mail inbox
local FULFILL_ICON_IN_MAIL_AND_BANK = "|TInterface\\Icons\\INV_Misc_Bag_07:10:10:0:0|t|TInterface\\Icons\\INV_Letter_06:10:10:0:0|t" -- Bag + wax letter: item is in both bank and mail
local FULFILL_ICON_NEED_SPLIT      = "|TInterface\\Icons\\INV_Misc_Shovel_01:14:14:0:0|t"      -- Shovel: manual work needed
local FULFILL_ICON_NO_ITEMS = "|TInterface\\Icons\\INV_Misc_QuestionMark:14:14:0:0|t" -- Question mark: no items
-- Row status prefix icons (date column decorators)
local CHECK_MARK_ICON = "|TInterface\\Buttons\\UI-CheckBox-Check:0|t "
local CANCELLED_ICON  = "|TInterface\\RAIDFRAME\\ReadyCheck-NotReady:0|t "
local PADDING_ICON    = "|TInterface\\AddOns\\TOGBankClassic\\Media\\blank:0|t "
local DELETE_REQUEST_DIALOG = "TOGBankClassic_DeleteRequest"
local CANCEL_STALE_DIALOG   = "TOGBankClassic_CancelStale"
local COMPLETE_QTY_DIALOG   = "TOGBankClassic_CompleteQty"
local REOPEN_REQUEST_DIALOG = "TOGBankClassic_ReopenRequest"

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
	self:DrawRows(false)   -- a new filter starts at the top of the list
end

local function OnClose(_)
	TOGBankClassic_UI_Requests.isOpen = false
	if TOGBankClassic_UI_Requests.Window then
		TOGBankClassic_UI_Requests.Window:Hide()
	end
end

-- BROWSE-001 fold-in. The operator: "requests isn't a separate window, it's just another tab".
-- The same body -- tab strip, the one search box, the Requester/Bank dropdowns, the RowList
-- (header and banded rows), the bottom icon cluster -- renders in one of two places:
--   STANDALONE: its own AceGUI Frame (the Inventory window's Requests button, /togbank requests).
--   EMBEDDED:   the Guild Bank window's Requests tab (Browse:ShowTab -> Requests:Embed).
-- `self.Host` is the AceGUI container the body's widgets are children of (the window, or that
-- window's tab group); `self.Chrome` is the AceGUI Frame whose bottom row carries the icon
-- cluster and whose status bar takes the messages (the window, or the Guild Bank window).
-- Standalone, both are `self.Window`. Only one rendering exists at a time: embedding releases
-- the standalone window, and Open() while the Guild Bank window is up goes to its tab.

--- The status line, wherever the body is showing.
function TOGBankClassic_UI_Requests:SetStatusText(text)
	if self.embedded then
		local Browse = TOGBankClassic_UI_Browse
		if Browse and Browse.SetStatus then Browse:SetStatus(text) end
	elseif self.Window then
		self.Window:SetStatusText(text)
	end
end

--- Re-lay the container the body lives in.
function TOGBankClassic_UI_Requests:DoLayout()
	if self.Host and self.Host.DoLayout then self.Host:DoLayout() end
end

-- POOL HYGIENE. AceGUI's widget pool is shared with every addon in the client, and this file
-- leaves marks on a widget's FRAME that outlive the widget's release: a neutered `Show` (below)
-- and the cancel glow (SetCancelGlow). Handed back with any of those in place, the same frame
-- comes out of the pool for the next Create -- the Guild Bank window's filter strip took a Button
-- whose Show did nothing, and the strip's Clear button was simply not there; a SimpleGroup with the
-- same mark took the WHOLE strip with it ("issue with the stuff at the top disappearing
-- sometimes"). ONE OnRelease handler undoes every mark, registered by each site that makes one;
-- one handler rather than one per mark because SetCallback holds a single OnRelease and the
-- last registration would silently drop the others'. Registered on every marking, not once:
-- AceGUI wipes a widget's callbacks when it is released.
-- REQUESTS-ROWLIST-001: the row cells are plain frames on the RowList's pooled rows now, never
-- released to AceGUI, so the fulfil dim and the glow only reach this path through an AceGUI Label
-- someone hands SetCancelGlow (the spec does); the hidden-Show mark is still the Settings tab's.
local function restoreWidgetOnRelease(widget)
	local frame = widget and widget.frame
	if not frame then return end
	if frame.togRequestsHidden then
		frame.Show = frame.togRequestsOrigShow
		frame.togRequestsHidden = false
	end
	if frame.togDisabled ~= nil then
		frame.togDisabled = nil
		frame:SetAlpha(1)
	end
	if widget.label and widget.label.togCancelGlow then
		TOGBankClassic_UI_Requests:SetCancelGlow(widget, false)
	end
end

local function markForRestore(widget)
	if widget and widget.SetCallback then widget:SetCallback("OnRelease", restoreWidgetOnRelease) end
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
			markForRestore(widget)
		end
		frame:Hide()
	end
end

--- REQUESTS-ROWLIST-001: a row's action icon -- a plain Button on the row's actions cell carrying
--- the icon as text, a hover highlight, and a title/detail tooltip read off the button at hover
--- time (so the fulfil icon's tooltip can change with its state without re-hooking). Its click
--- reads the request off the cell it sits on (`cell.req`, set on every render) -- the RowList pools
--- rows by position, so nothing about a request may be captured at build time.
--- The icons show even when the action is greyed (the fulfil dim), which is why the tooltip is on
--- the frame's own scripts rather than gated on enabled state.
--- A cell that takes the mouse locks its row's highlight while the cursor is on it, so the row reads
--- as hovered across its whole width, as a Browse row does. Every mouse-taking cell -- the action
--- icons here, the date/item cells below -- goes through this one spelling.
local function lockRowHighlight(cell, on)
	local row = cell:GetParent()
	if not row then return end
	if on then
		if row.LockHighlight then row:LockHighlight() end
	elseif row.UnlockHighlight then
		row:UnlockHighlight()
	end
end

local ACTION_ICON_SIZE = 16
local function newActionIcon(cell, slot, iconText, title, detail, onClick)
	local btn = CreateFrame("Button", nil, cell)
	btn:SetSize(ACTION_ICON_SIZE, ACTION_ICON_SIZE)
	btn:SetPoint("LEFT", cell, "LEFT", (slot - 1) * (ACTION_ICON_SIZE + 2), 0)
	local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("CENTER", btn, "CENTER", 0, 0)
	fs:SetText(iconText)
	btn.icon = fs
	btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	btn.togTooltipTitle, btn.togTooltipDetail = title, detail
	btn:SetScript("OnEnter", function(self)
		lockRowHighlight(cell, true)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:ClearLines()
		GameTooltip:AddLine(self.togTooltipTitle or "")
		if self.togTooltipDetail and self.togTooltipDetail ~= "" then
			GameTooltip:AddLine(self.togTooltipDetail, 0.9, 0.9, 0.9, true)
		end
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function()
		lockRowHighlight(cell, false)
		TOGBankClassic_UI:HideTooltip()
	end)
	btn:SetScript("OnClick", function(self)
		if self.togDisabled then return end
		local req = cell.req
		if req and req.id then onClick(req) end
	end)
	return btn
end

local function updateFulfillButtonTooltip(button, title, detail)
	if not button then return end
	button.togTooltipTitle = title or "Fulfill request"
	button.togTooltipDetail = detail or ""
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
			if not success and cUI and cUI.SetStatusText then
				cUI:SetStatusText("Unable to cancel request.")
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
		-- Reachable for the spec (requestsactions_spec drives the dialog's own buttons); built once.
		TOGBankClassic_UI_Requests.CancelDialog, TOGBankClassic_UI_Requests.CancelDropdown = frame, dd
	end

	---@diagnostic disable-next-line: undefined-field
	cancelReasonDropdown:SetList(cancelReasonMap, reasonOrder)
	---@diagnostic disable-next-line: undefined-field
	cancelReasonDropdown:SetValue(defaultKey)
	-- ALPHA-001: inherits the Requests window's transparency rather than carrying its own slider —
	-- it is a transient child of that window. Applied on every show, not at creation, because
	-- `cancelReasonFrame` is built once and reused for the rest of the session; setting it only at
	-- creation would leave it on whatever the slider read the first time it opened.
	TOGBankClassic_UI:ApplyWindowAlpha("requests", cancelReasonFrame)
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
				if data.ui and data.ui.SetStatusText then
					data.ui:SetStatusText("Unable to delete request.")
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
			if data.ui and data.ui.SetStatusText then
				if expired > 0 then
					-- Redraw FIRST: DrawContent sets its own "Showing N requests" status, which used
					-- to land on top of this message the same instant (requestsactions_spec found it).
					data.ui:DrawContent()
					data.ui:SetStatusText(string.format("Cancelled %d stale request%s.", expired, expired == 1 and "" or "s"))
				else
					data.ui:SetStatusText("No stale requests found.")
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
	local item = TOGBankClassic_Item:RequestDisplayName(request)   -- NAME-001
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

local function ensureReopenDialog()
	if not StaticPopupDialogs then
		return
	end
	if StaticPopupDialogs[REOPEN_REQUEST_DIALOG] then
		return
	end
	StaticPopupDialogs[REOPEN_REQUEST_DIALOG] = {
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
			if not TOGBankClassic_Guild:ReopenRequest(data.requestId, data.actor) then
				if data.ui and data.ui.SetStatusText then
					data.ui:SetStatusText("Unable to re-open request.")
				end
			end
		end,
	}
end

-- REOPEN-001: confirm re-opening a finished order (banker/officer/GM). Resets it to an open
-- order and clears the Sent count, in case it was marked done by mistake.
local function confirmReopenRequest(request, actor)
	if not request or not StaticPopup_Show then
		return
	end

	ensureReopenDialog()

	local qty = tonumber(request.quantity or 0) or 0
	local item = TOGBankClassic_Item:RequestDisplayName(request)   -- NAME-001
	local requester = request.requester or "Unknown"
	local message = string.format(
		"Re-open the request for %dx %s from %s?\n\nThis clears its Sent count and makes it an open order again.",
		qty, item, requester)

	StaticPopup_Show(REOPEN_REQUEST_DIALOG, message, nil, {
		requestId = request.id,
		actor = actor,
		ui = TOGBankClassic_UI_Requests,
	})
end

-- STATICPOPUP-001: The Era StaticPopup refactor (Blizzard_StaticPopup mixins) replaced the
-- dialog's `.editBox` / `.button1` fields with `:GetEditBox()` / `:GetButton1()` accessor
-- methods. Reading the old fields returns nil, so the quantity typed into the Complete
-- prompt was never captured and the order was silently never marked filled. Read through the
-- methods (with a fallback to the legacy fields for safety) so the value is actually read.
local function popupEditBox(dialog)
	if dialog and dialog.GetEditBox then return dialog:GetEditBox() end
	return dialog and dialog.editBox
end
local function popupButton1(dialog)
	if dialog and dialog.GetButton1 then return dialog:GetButton1() end
	return dialog and dialog.button1
end

-- COMPLETEQTY-001: the "Complete" (manual hand-off) button asks how many were
-- given, and records that quantity into the Sent column via Guild:FulfillRequest
-- (which marks the order fulfilled only when it reaches the requested amount).
local function ensureCompleteQtyDialog()
	if not StaticPopupDialogs then return end
	if StaticPopupDialogs[COMPLETE_QTY_DIALOG] then return end
	StaticPopupDialogs[COMPLETE_QTY_DIALOG] = {
		text = "%s",
		button1 = "Mark Filled",
		button2 = CANCEL,
		hasEditBox = true,
		maxLetters = 6,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		OnShow = function(self)
			local eb = popupEditBox(self)
			if eb then
				eb:SetNumeric(true)
				eb:SetText(tostring((self.data and self.data.defaultQty) or ""))
				eb:HighlightText()
				eb:SetFocus()
			end
		end,
		EditBoxOnEnterPressed = function(editBox)
			local dialog = editBox:GetParent()
			local button1 = popupButton1(dialog)
			if button1 then button1:Click() end
		end,
		EditBoxOnEscapePressed = function(editBox)
			local parent = editBox:GetParent()
			if parent then parent:Hide() end
		end,
		OnAccept = function(self)
			local data = self.data
			if not data then return end
			local eb = popupEditBox(self)
			local n = tonumber(eb and eb:GetText())
			local ui = TOGBankClassic_UI_Requests
			if not n or n < 1 then
				ui:SetStatusText("Enter a quantity of 1 or more.")
				return
			end
			n = math.floor(n)
			if data.maxQty and n > data.maxQty then n = data.maxQty end
			-- COMPLETEQTY-002: complete by request id directly (not by re-matching
			-- bank+requester+item, which could silently no-op). Records the amount in
			-- Sent and flips the order to fulfilled once Sent reaches the requested qty.
			local applied = TOGBankClassic_Guild:FulfillRequestById(data.requestId, n, data.actor)
			if (applied or 0) <= 0 then
				ui:SetStatusText("Unable to record that quantity.")
			end
		end,
	}
end

local function showCompleteQtyPrompt(request, actor)
	if not request or not StaticPopup_Show then return end
	ensureCompleteQtyDialog()
	local remaining = TOGBankClassic_Guild:RequestQuantityNeeded(request)
	local message = string.format(
		"How many %s did you fill for %s?\n\nUse this for items handed over in person or mailed yourself. Recorded in the Sent column (up to %d remaining).",
		TOGBankClassic_Item:RequestDisplayName(request), request.requester or "the requester", remaining)
	StaticPopup_Show(COMPLETE_QTY_DIALOG, message, nil, {
		requestId  = request.id,
		bank       = request.bank,
		requester  = request.requester,
		item       = request.item,
		actor      = actor,
		defaultQty = remaining,
		maxQty     = remaining,
	})
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
	self.searchText = nil    -- SEARCH-006: the one search, session-scoped like the dropdowns
	self.defaultFiltersApplied = false
	self.currentTab = "active"
	-- Tab-filter cache (invalidated by DrawContent, persists across DrawRows calls)
	self._cachedTabFiltered = nil
	self._cachedTotal       = nil
	self._cachedTabFilter   = nil
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

--- Release the standalone window whole (banker status changed, or the body is moving into the
--- Guild Bank window's tab). ALPHA-001: hand the frame back to AceGUI's shared pool with opaque
--- chrome -- the pool is library-wide, so a faded frame released here can turn up as another
--- addon's window.
function TOGBankClassic_UI_Requests:ReleaseWindow()
	if not self.Window then return end
	TOGBankClassic_UI:ClearWindowAlpha(self.Window)
	self.Window:Release()
	self.Window = nil
	self:ForgetBody()
end

--- What the body's lifecycle needs on every open, standalone or embedded: the first draw, the
--- bag listener for a banker's fulfil icons, the request-index pull (REQUEST-001: a banker sees
--- current data without waiting for the periodic timer; CanQueryRequestsIndex's cooldown stops
--- a rapid toggle from spamming).
local function afterOpen(self)
	self:DrawContent()
	local player = TOGBankClassic_Guild:GetNormalizedPlayer()
	if player and TOGBankClassic_Guild:IsBank(player) then
		RegisterBagEvents()
	end
	TOGBankClassic_Guild:QueryRequestsIndex(nil, "NORMAL")
end

function TOGBankClassic_UI_Requests:Open()
	-- BROWSE-001: while the Guild Bank window is up, the requests ARE its Requests tab; a second
	-- rendering beside it would be two bodies over one row pool.
	local Browse = TOGBankClassic_UI_Browse
	if Browse and Browse.isOpen and Browse.Open then
		Browse:Open("requests")
		return
	end
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
		self:ReleaseWindow()
	end

	if not self.Window then
		self:DrawWindow()
		self.wasBank = isCurrentlyBanker
	end

	-- Dock beside the Inventory window when it is open.
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen and TOGBankClassic_UI_Inventory.Window then
		self.Window:ClearAllPoints()
		self.Window:SetPoint("TOPLEFT", TOGBankClassic_UI_Inventory.Window.frame, "TOPRIGHT", 0, 0)
	end

	-- Ensure window stays within screen bounds
	TOGBankClassic_UI:ClampFrameToScreen(self.Window)

	afterOpen(self)

	-- Force layout update before showing to ensure proper sizing
	self.Window:DoLayout()

	-- Show window AFTER content is drawn and laid out to prevent initial sizing issue
	self.Window:Show()

	if _G["TOGBankClassic"] then
		_G["TOGBankClassic"]:Show()
	else
		TOGBankClassic_UI:Controller()
	end
end

--- BROWSE-001: render the body inside the Guild Bank window's Requests tab. `host` is that
--- window's tab group (the widgets become its children, released with the tab), `chrome` the
--- window itself (bottom icon cluster, status bar), `anchor` the window's help icon the cluster
--- hangs left of. A standalone window that is up is released first -- one rendering at a time.
function TOGBankClassic_UI_Requests:Embed(host, chrome, anchor)
	if self.isOpen and not self.embedded then
		UnregisterBagEvents()
		if TOGBankClassic_ItemHighlight then TOGBankClassic_ItemHighlight:ClearAllOverlays() end
		OnClose(self.Window)
	end
	self:ReleaseWindow()
	self.embedded = true
	self.isOpen = true
	self.Host, self.Chrome = host, chrome
	self.wasBank = nil   -- the standalone rebuild-on-role-change check starts over next time
	if host.SetLayout then host:SetLayout("Flow") end
	self:BuildBody(host, chrome, anchor)
	-- Lay the widgets out ONCE before the first draw, so the list -- hung off the filter strip's
	-- bottom edge -- resolves against the tab body's real width and height rather than a pooled
	-- widget's stale ones; DrawContent lays out again after.
	self:DoLayout()
	afterOpen(self)
end

--- BROWSE-001: the Requests tab is going away (another tab, or the Guild Bank window closing).
--- The AceGUI widgets are the tab group's children and are released by it; this forgets them,
--- hides what lives on the chrome (the icon cluster, the settings overlay) and stops the
--- listeners, exactly as Close does for the standalone window.
function TOGBankClassic_UI_Requests:Detach()
	if not self.embedded then return end
	UnregisterBagEvents()
	if TOGBankClassic_ItemHighlight then
		TOGBankClassic_ItemHighlight:ClearAllOverlays()
	end
	self:ShowCluster(false)
	if self.SettingsOverlay then self.SettingsOverlay:Hide() end
	self.isOpen = false
	self.embedded = false
	self:ForgetBody()
end

--- Drop every reference to the body's widgets. The AceGUI widgets are released by whoever owns
--- them (the standalone window's Release, the tab group's ReleaseChildren); the RowList's frames
--- are plain frames on the host's content and are hidden with it -- WoW frames cannot be
--- destroyed, so the list is also parked (`Hide`) here rather than left showing on a tab body
--- that is about to hold another tab's list.
function TOGBankClassic_UI_Requests:ForgetBody()
	if self.ListHost then self.ListHost:Hide() end
	self.Host, self.Chrome = nil, nil
	self.TabGroup, self.SearchBox, self.FilterGroup, self.FilterRequester, self.FilterBank = nil, nil, nil, nil, nil
	self.HighlightCheckbox, self.List, self.ListHost, self.EmptyText = nil, nil, nil, nil
	self.SettingsOverlay, self.SettingsArchiveEB, self.SettingsTombstoneEB, self.SettingsMaxPctEB = nil, nil, nil, nil
	self.ReasonInput, self.ReasonNewMember, self.ReasonNewBanker, self.ReasonSaveBtn = nil, nil, nil, nil
	self.ReasonScroll, self.ReasonContent, self.ReasonRows, self.ReasonEditIndex = nil, nil, nil, nil
	self.HelpIcon, self.CancelStaleBtn, self.FulfillOldestBtn = nil, nil, nil
	self._lastDrawnTab = nil
	-- UpdateFilters sends a dropdown its option list only when the list CHANGED against these; a
	-- rebuilt body has fresh (pooled, empty) dropdowns, so a cache that survived it left the
	-- Requester and Bank dropdowns with no list and an empty value ("bug with the requests": an
	-- empty pullout the height of the window). The next UpdateFilters must send both lists.
	self.cachedRequesterList, self.cachedRequesterOrder, self.cachedBankList, self.cachedBankOrder = nil, nil, nil, nil
end

function TOGBankClassic_UI_Requests:Close()
	if not self.isOpen then
		return
	end
	-- Embedded, the tab is the Guild Bank window's to show or hide (Browse:ShowTab / Close).
	if self.embedded or not self.Window then
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

-- REQUESTS-ROWLIST-001: ApplyColumnWidths / UpdateColumnLayout / HandleResize / AdjustTableHeight
-- were here -- the grid's own column-width arithmetic and the table-height budget that had to be
-- re-run on every resize (and once ran one row past the bottom under the status bar). The RowList
-- hangs off the filter strip and the host's bottom edge by anchor and lays its own columns out on
-- OnSizeChanged, so a resize needs nothing from this file.

-- Helper to set up click-outside-to-close behavior for dropdowns
local function SetupClickOutsideHandler(dropdown)
	if not dropdown or not dropdown.pullout then return end

	local pullout = dropdown.pullout
	-- A Dropdown keeps ONE pullout for its whole life and AceGUI pools the Dropdown, so this runs
	-- again on every rebuild of the body (a banker-status change; every visit to the Guild Bank
	-- window's Requests tab). Wrap Open/Close once, or each rebuild nests another wrapper and
	-- another full-screen click catcher.
	if pullout.togClickOutsideHooked then return end
	pullout.togClickOutsideHooked = true
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

--- The help text for the Requests body, wherever it is showing: the standalone window's own "?"
--- icon, and the Guild Bank window's icon while its Requests tab is up.
function TOGBankClassic_UI_Requests:AddHelpLines()
	GameTooltip:AddLine("Guild Requests — How to Use")
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("|cffffd100Date column:|r", 1, 1, 1, false)
	GameTooltip:AddLine("Mouseover any row's date to see a timeline tooltip showing when the request was submitted and, if applicable, when it was filled or cancelled. A cancelled request's date breathes with a soft glow; if a reason was given, mouse over it to read why.", 0.9, 0.9, 0.9, true)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("|cffffd100Action icons (right side of each row -- mouse over one for its name):|r", 1, 1, 1, false)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("|cffffd100Fulfill:|r", 1, 1, 1, false)
	GameTooltip:AddLine("Sends the item by in-game mail. Click Fulfill on several of one person's requests and each is added to the same mail (up to 12), then Send once. The icon changes to show what is needed: envelope = ready to send; sealed letter = no mailbox nearby; bag = item is in the bank, go get it first; wax-sealed letter = item is in your mail inbox, retrieve it first; chest = item is split between your mail and bank; shovel = quantity must be split manually; question mark = item not found in your inventory.", 0.9, 0.9, 0.9, true)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("|cffffd100Mark hand-off (check):|r", 1, 1, 1, false)
	GameTooltip:AddLine("For items handed over directly (not mailed). Asks how many you gave; that amount goes into the Sent column, and the order completes once Sent reaches the amount requested.", 0.9, 0.9, 0.9, true)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("|cffffd100Cancel:|r", 1, 1, 1, false)
	GameTooltip:AddLine("Opens a dialog to select a cancellation reason before cancelling. The reason is stored with the request and shown in the date tooltip. Cancelled requests move to the Archive tab.", 0.9, 0.9, 0.9, true)
	TOGBankClassic_UI:AppendGuildHelpNote("requests")  -- HELPNOTE-001
end

--- The frame-level script a chrome frame needs while the body is on it: Escape closing an open
--- dropdown before it closes the window. Installed ONCE per frame and written against the module,
--- not a closure, so a pooled AceGUI frame that comes back (the standalone window after a release;
--- the Guild Bank window on every tab visit) does not stack a second copy. A no-op while the body
--- is not on that frame (the key handler finds no dropdowns). REQUESTS-ROWLIST-001: the resize
--- follow-through that was hooked beside it went with the grid; the RowList resizes by anchor.
local function hookChromeFrame(frame)
	if not frame.togRequestsKeyHooked then
		frame.togRequestsKeyHooked = true
		frame:EnableKeyboard(true)
		frame:SetPropagateKeyboardInput(true)
		frame:SetScript("OnKeyDown", function(f, key)
			local R = TOGBankClassic_UI_Requests
			if key == "ESCAPE" then
				-- Check if any dropdown pullout is open
				local closedAny = false
				if R.FilterRequester and R.FilterRequester.pullout and R.FilterRequester.pullout.frame:IsShown() then
					R.FilterRequester.pullout:Close()
					closedAny = true
				end
				if R.FilterBank and R.FilterBank.pullout and R.FilterBank.pullout.frame:IsShown() then
					R.FilterBank.pullout:Close()
					closedAny = true
				end
				-- If we closed a dropdown, consume the Esc key
				f:SetPropagateKeyboardInput(not closedAny)
			else
				f:SetPropagateKeyboardInput(true)
			end
		end)
	end
end

--- The standalone window: the frame, its persistence and resize bounds, the shared status bar,
--- its own help icon -- then the body, exactly as the Guild Bank window's tab gets it.
function TOGBankClassic_UI_Requests:DrawWindow()
	local window = TOGBankClassic_UI:Create("Frame")
	window:Hide()
	window:SetCallback("OnClose", OnClose)
	window:SetTitle(TOGBankClassic_UI:WindowTitle("Requests"))
	window:SetLayout("Flow")
	window:EnableResize(true)
	TOGBankClassic_UI:ApplyThinBorder(window, "requests")
	-- WINDOW-PERSIST-002: position, size and the resize floor per character, the one spelling every
	-- window uses (UI:PersistWindow -> the library's, which also raises a saved width under the
	-- column floor, as BROWSE-007 does for the Guild Bank window). This used to open-code the
	-- status table and a SetResizeBounds/SetMinResize pair beside it.
	local floor = minWidth()
	TOGBankClassic_UI:PersistWindow(window, "requests", floor, 500, floor, 200)

	self.Window = window
	self.embedded = false
	-- SYNCED-001: the shared center/right status sections (network parts, the banker's "has my
	-- update reached anyone" line), the same bar the Inventory window carries.
	self.StatusBar = TOGBankClassic_UI_StatusBar:AttachSides(window)

	-- WINDOW-CHROME-001: the "?" (this window's only own bottom icon -- no gear), the status bar
	-- ending at it, the hitbox lift: the shared bottom row (UI:DressWindow). The cluster then hangs
	-- left of it (BuildBody -> BuildBottomCluster) and ShowCluster moves the bar's edge along.
	local chrome = TOGBankClassic_UI:DressWindow(window, {
		help = function() TOGBankClassic_UI_Requests:AddHelpLines() end,
	})

	self:BuildBody(window, window, chrome.anchor)
end

--- The bottom-row icon cluster on `chrome`'s frame, hung left of `anchor` (the help icon):
--- pagination (prev/next), Cancel Stale (officers/bankers; the broom) and Fulfill Oldest
--- (bankers; the envelope). The status bar's right edge meets the leftmost icon. Cached on the
--- frame and rebuilt only when the roles it depends on change: AceGUI pools frames, so without
--- the cache a frame that came back (banker status change; every visit to the Guild Bank
--- window's Requests tab) accumulated a second set of icons under the first.
--- The banker roster changed under an EMBEDDED body (Peer Review, self-audit 2 F1): the standalone
--- window re-checks its role on the next Open, but the Guild Bank window's Requests tab is never
--- re-opened while it sits there, so a 'gbank' note edit landing mid-session left the broom /
--- envelope cluster and the highlight checkbox on the old role until a tab switch. Called from
--- Guild:RebuildBankerRoster when the list actually changed; BuildBottomCluster caches on role and
--- rebuilds only when it moved, so this is idempotent and cheap. No timer, no poll.
function TOGBankClassic_UI_Requests:OnBankerRosterChanged()
	if not (self.embedded and self.isOpen and self.Chrome and self.Chrome.frame) then return end
	local cluster = self.Chrome.frame.togRequestsCluster
	if not cluster then return end
	local wasBanker = cluster.isBanker
	self:BuildBottomCluster(self.Chrome, cluster.anchor)
	local nowBanker = self.Chrome.frame.togRequestsCluster and self.Chrome.frame.togRequestsCluster.isBanker
	-- The highlight checkbox and the fulfil column are role-bound too: a role change redraws.
	if wasBanker ~= nowBanker then self:DrawContent() end
end

function TOGBankClassic_UI_Requests:BuildBottomCluster(chrome, anchor)
	local frame = chrome.frame
	local actor = TOGBankClassic_Guild:GetNormalizedPlayer()
	local canOfficer = (CanViewOfficerNote and CanViewOfficerNote()) or false
	local isOfficerOrBanker = canOfficer or (actor and TOGBankClassic_Guild:IsBank(actor)) or false
	local isBanker = (actor and TOGBankClassic_Guild:IsBank(actor)) or false

	local cached = frame.togRequestsCluster
	if cached and (cached.isOfficerOrBanker ~= isOfficerOrBanker or cached.isBanker ~= isBanker or cached.anchor ~= anchor) then
		for _, f in pairs(cached.frames) do f:Hide() end
		cached = nil
	end
	if cached then
		self.CancelStaleBtn, self.FulfillOldestBtn = cached.CancelStaleBtn, cached.FulfillOldestBtn
		self:ShowCluster(true)
		return
	end

	-- REQUESTS-ROWLIST-001: the Next / Previous page icons were here, rightmost of the cluster. The
	-- list scrolls the whole set now (a RowList renders only the rows in view), so there are no
	-- pages, and the broom hangs straight off the anchor. A member who is neither officer nor
	-- banker has an EMPTY cluster: the status bar then meets the anchor itself (ShowCluster).

	-- Cancel Stale — officers/bankers only. BROOM-001: Classic Era ships NO broom icon
	-- (INV_Broom_01 / INV_Misc_Broom_01 / INV_Pet_Broom all render as the blue
	-- missing-texture box), so we bundle our own broom in Textures/broom.tga (64x64
	-- 32-bit TGA) and reference it by addon path.
	-- Clear any stale reference first: if banker status was lost since the previous
	-- window, this block won't run and the status-bar inset below must see nil.
	self.CancelStaleBtn = nil
	if isOfficerOrBanker then
		local cancelStaleBtn = CreateFrame("Button", nil, frame)
		cancelStaleBtn:SetSize(22, 22)
		cancelStaleBtn:SetFrameLevel(frame:GetFrameLevel() + 10)  -- HITBOX-001
		cancelStaleBtn:SetPoint("RIGHT", anchor, "LEFT", -8, 0)
		cancelStaleBtn:SetNormalTexture("Interface\\AddOns\\TOGBankClassic\\Textures\\broom")
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
	if isBanker then
		local fulfillBtn = CreateFrame("Button", nil, frame)
		fulfillBtn:SetSize(22, 22)
		fulfillBtn:SetFrameLevel(frame:GetFrameLevel() + 10)  -- HITBOX-001
		fulfillBtn:SetPoint("RIGHT", self.CancelStaleBtn or anchor, "LEFT", -8, 0)
		fulfillBtn:SetNormalTexture("Interface\\Icons\\INV_Letter_15")
		fulfillBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
		fulfillBtn:SetScript("OnClick", function()
			-- BANKFILL-001: one button, two contexts, because the game will not give you both at
			-- once -- a mailbox is never within reach of a bank. At the BANK it collects what the
			-- orders need out of the vault; at the MAILBOX it fills them. The context decides, so
			-- the banker mashes the same button in both places rather than learning two.
			local _, message
			if TOGBankClassic_Mail:IsBankOpen() then
				_, message = TOGBankClassic_Mail:BankCollectStep(actor)
			else
				_, message = TOGBankClassic_Mail:FulfillStep(actor)
			end
			self:SetStatusText(message or "")
		end)
		fulfillBtn:SetScript("OnEnter", function(f)
			GameTooltip:SetOwner(f, "ANCHOR_TOP")
			GameTooltip:ClearLines()
			GameTooltip:AddLine("Fulfill Oldest Order")
			GameTooltip:AddLine("Click to advance the oldest order you can fully fill, one step per click: select, then split, then attach, then send; then the next-oldest. If the needed items are sitting in your mail, it pulls them into your bags first (one per click). Watch the status bar for the next step. Requires an open mailbox; orders you can't fully cover (from bags + mail) are skipped.", 0.9, 0.9, 0.9, true)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("At the BANK the same button collects instead: each click pulls what an order still needs out of your bank, and if the stack is bigger than the order it puts the spare back. If your bags are full, the click swaps something no order needs into the bank to make room. Mash it at the bank to gather everything, then go to a mailbox and mash it again to send.", 0.9, 0.9, 0.9, true)
			GameTooltip:Show()
		end)
		fulfillBtn:SetScript("OnLeave", function()
			TOGBankClassic_UI:HideTooltip()
		end)
		self.FulfillOldestBtn = fulfillBtn
	end

	-- Appended one by one, never `ipairs` over a constructor with holes (Peer Review, self-audit 2
	-- F2): today the roles nest, so no nil ever precedes a button, but a role that had the envelope
	-- without the broom would have silently truncated this list at the hole.
	local frames = {}
	if self.CancelStaleBtn then frames[#frames + 1] = self.CancelStaleBtn end
	if self.FulfillOldestBtn then frames[#frames + 1] = self.FulfillOldestBtn end
	frame.togRequestsCluster = {
		isOfficerOrBanker = isOfficerOrBanker, isBanker = isBanker, anchor = anchor, frames = frames,
		CancelStaleBtn = self.CancelStaleBtn, FulfillOldestBtn = self.FulfillOldestBtn,
	}
	self:ShowCluster(true)
end

--- Show or hide the cluster on the current chrome, and give the status bar its right edge:
--- with the cluster up it meets the leftmost icon (fulfill -> broom), anchored to the icon itself
--- so the gap stays right whichever icons are present; without it (the Guild Bank window on
--- another tab), or with an empty cluster (a member with neither role), it meets that window's
--- own help icon. All icons are 22px at bottom y=15. HITBOX-001: the lift above AceGUI's resize
--- sizers is re-asserted with the live set.
function TOGBankClassic_UI_Requests:ShowCluster(show)
	local chrome = self.Chrome
	local frame = chrome and chrome.frame
	local cluster = frame and frame.togRequestsCluster
	if not cluster then return end
	for _, f in ipairs(cluster.frames) do
		if show then f:Show() else f:Hide() end
	end
	-- WINDOW-CHROME-001: the one status-bar rule (UI:AnchorStatusBar), given the cluster's leftmost.
	local leftmost = show and (cluster.FulfillOldestBtn or cluster.CancelStaleBtn) or cluster.anchor
	TOGBankClassic_UI:AnchorStatusBar(chrome, leftmost)
	-- KeepAboveResizeSizers REPLACES the frame's lift set. The chrome's OWN bottom icons are the
	-- chrome's to name (`chrome.togBottomIcons`, UI:DressWindow's list -- the Guild Bank window's
	-- gear and "?"; this window's "?"), never re-derived here: with the cluster up the set is those
	-- plus the cluster, hidden it is those alone. Peer Review F3-b: when the anchor became the
	-- gear, a hand-written list here silently dropped the Guild Bank window's help icon from the
	-- shown branch, and the OnShow re-lift walks only the stored set.
	local lift = {}
	for _, f in ipairs(chrome.togBottomIcons or { cluster.anchor }) do lift[#lift + 1] = f end
	if show then
		for _, f in ipairs(cluster.frames) do lift[#lift + 1] = f end
	end
	TOGBankClassic_UI:KeepAboveResizeSizers(chrome, lift)
end

--- THE BODY: the Requests/Archive/Settings tab strip, the one search box, the Requester/Bank
--- dropdowns (and a banker's highlight checkbox), the column header, the scrolling row table --
--- as children of `host`; the icon cluster and the officer settings overlay on `chrome`, the
--- cluster hung left of `anchor`. Standalone, host and chrome are the window; embedded, the
--- Guild Bank window's tab group and the window.
function TOGBankClassic_UI_Requests:BuildBody(host, chrome, anchor)
	self.Host, self.Chrome = host, chrome
	hookChromeFrame(chrome.frame)
	self:BuildBottomCluster(chrome, anchor)
	local canOfficer = (CanViewOfficerNote and CanViewOfficerNote()) or false

	self.HeaderWidgets = nil
	self.SearchBox = nil
	self.FilterRequester = nil
	self.FilterBank = nil
	self.TabGroup = nil
	-- The settings overlay lives on the chrome frame and is found again there (BuildSettingsPanel);
	-- these are re-pointed when it is.
	self.SettingsOverlay = nil
	self.SettingsArchiveEB = nil
	self.SettingsTombstoneEB = nil
	self.SettingsMaxPctEB = nil
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
	-- Just tall enough to contain the tab row (anchored at y=-7, 24px tall) plus a small clearance
	-- before the filter strip below. REQUESTS-STRIP-002 (operator 2026-09-13, screenshot: "there is
	-- a lot of dead space between that strip and the subtabs"): the height set here never held --
	-- a full-width child is laid out by the host's Flow, and a TabGroup with no children then sets
	-- its OWN height to 3 + borderoffset (30) + 23 = 56 (AceGUIContainer-TabGroup LayoutFinished),
	-- leaving ~25px of nothing under the tabs. Auto-height off is what makes the number below real.
	tabGroup:SetAutoAdjustHeight(false)
	tabGroup:SetHeight(SUBTAB_H)
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
	host:AddChild(tabGroup)
	self.TabGroup = tabGroup

	do
		-- SEARCH-006: ONE search box, above the dropdowns. The operator, 2026-09-11: "i don't need
		-- a search bar for each area, one bar that filters on all columns would work" and "put them
		-- above the dropdown, not below". Every word typed must appear somewhere across what the
		-- Date, Requester, Bank and Item columns show (SearchMatches). Its text lives on
		-- `self.searchText` so it survives a window rebuild (banker status change).
		-- REQUESTS-STRIP-001 (operator 2026-09-13, screenshot of a non-banker's tab: "the request
		-- dropdowns overlap the column header row. we need to move the dropdowns up 5 or so px. we
		-- also need to do the left hand alignment we did on the browse tab here"): ONE strip, in the
		-- Browse tab's shape (Browse:BuildFilterStrip) -- a Table on a group whose content is inset
		-- FILTER_INSET from the border, cells bottom-aligned. The list hangs LIST_GAP under the
		-- strip, not 4px -- the dropdown's textures sit under its frame's bottom edge, which is what
		-- ran into the header row. Second round (screenshot: the dropdowns' box art starts ~12px
		-- right of the search box above them): the search box and the two dropdowns are ONE ROW --
		-- Browse's search-then-dropdowns row exactly -- so nothing sits under the search to misalign
		-- with it; the banker's checkbox is the second row.
		local strip = TOGBankClassic_UI:Create("SimpleGroup")
		strip:SetLayout("Table")
		strip:SetUserData("table", {
			columns = { 220, 200, 200 },
			spaceH = 10, spaceV = 6, alignV = "end", alignH = "start",
		})
		if strip.content and strip.content.SetPoint then
			strip.content:ClearAllPoints()
			strip.content:SetPoint("TOPLEFT", FILTER_INSET, 0)
			strip.content:SetPoint("BOTTOMRIGHT", -FILTER_INSET, 0)
		end
		strip:SetFullWidth(true)
		host:AddChild(strip)
		self.FilterGroup = strip
		local filterGroup = strip

		local searchBox = TOGBankClassic_UI:Create("TOGBankSearchBox")
		searchBox:SetPlaceholder("Search requests...")
		-- A query is a word or two; the operator on the full-width cut: "the search bar doesn't
		-- need to be this big, it's a waste of space".
		searchBox:SetWidth(220)
		searchBox:SetText(self.searchText or "")
		searchBox:SetCallback("OnTextChanged", function(_, _, text) self:SetSearch(text) end)
		TOGBankClassic_UI:AttachTooltip(searchBox, "ANCHOR_BOTTOM", "Search requests", {
			"Only requests with every word you type somewhere in their date, requester, bank or item are shown.",
			"Works together with the Requester / Bank filters below.",
		})
		strip:AddChild(searchBox)
		self.SearchBox = searchBox

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
		requesterFilter:SetWidth(200)   -- REQUESTS-STRIP-001: a column of Browse's row, not full width
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
		bankFilter:SetWidth(200)
		bankFilter:SetCallback("OnValueChanged", function(widget, _, value)
			handleFilterChange(self, "bank", widget, value)
		end)
		filterGroup:AddChild(bankFilter)
		self.FilterBank = bankFilter
		SetupClickOutsideHandler(bankFilter)

		-- The banker's highlight checkbox, when the roster already says who we are; UpdateFilters
		-- adds it later otherwise (the roster can load after the window). One builder for both.
		self:EnsureHighlightCheckbox()
	end

	-- REQUESTS-ROWLIST-001: the list. A plain frame on the host's content, hung off the filter
	-- strip's bottom edge and the content's bottom-right -- the Guild Bank window's Browse tab hangs
	-- its list under its strip the same way -- so AceGUI's Flow layout of the widgets above (and the
	-- banker's checkbox appearing under the dropdowns) moves it by anchor, and a resize needs no
	-- code. The RowList's own header, banding, fonts and scrollbar are the Browse tab's.
	-- ONE list per host frame, found again on the next visit: WoW frames cannot be destroyed, and
	-- the Guild Bank window's tab body hosts this body on every visit to its Requests tab.
	local content = host.content
	local listHost = content.togRequestsListHost
	if not listHost then
		listHost = CreateFrame("Frame", nil, content)
		content.togRequestsListHost = listHost
		listHost.togList = TOGBankClassic_UI_RowList:New(listHost, {
			columns = COLUMNS,
			onRowRender = function(entry, rowFrame) TOGBankClassic_UI_Requests:_PopulateRow(rowFrame, entry) end,
			-- The list sorts; the body only REMEMBERS the sort, so a rebuild (a tab revisit) hands
			-- it back through SetSort below. The tab-filter cache does not depend on it.
			onSortChanged = function(key, desc)
				local R = TOGBankClassic_UI_Requests
				R.sortColumn, R.sortDirection = key, desc and "desc" or "asc"
			end,
		})
		local empty = listHost:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		empty:SetPoint("TOP", listHost, "TOP", 0, -(TOGBankClassic_UI_RowList.HEADER_HEIGHT + 12))
		empty:Hide()
		listHost.togEmpty = empty
	end
	listHost:ClearAllPoints()
	listHost:SetPoint("TOPLEFT",     self.FilterGroup.frame, "BOTTOMLEFT",  0, -LIST_GAP)
	listHost:SetPoint("BOTTOMRIGHT", content,                "BOTTOMRIGHT", 0, 0)
	listHost:Show()
	self.ListHost, self.List, self.EmptyText = listHost, listHost.togList, listHost.togEmpty
	self.List:SetSort(self.sortColumn or "date", (self.sortDirection or "desc") == "desc")

	-- Officer-only Settings tab needs its overlay panel on the chrome frame.
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
-- The widget references the settings overlay hands back when it is found again on a chrome frame.
local SETTINGS_REFS = {
	"SettingsArchiveEB", "SettingsTombstoneEB", "SettingsMaxPctEB",
	"ReasonInput", "ReasonNewMember", "ReasonNewBanker", "ReasonSaveBtn", "ReasonScroll", "ReasonContent", "ReasonRows",
}

function TOGBankClassic_UI_Requests:BuildSettingsPanel()
	if self.SettingsOverlay or not self.Chrome or not self.TabGroup then
		return
	end
	local chrome = self.Chrome

	-- Built once per chrome frame and found again: the frame is AceGUI-pooled (the standalone
	-- window after a release) or long-lived (the Guild Bank window across tab visits), and a second
	-- overlay on it would stack under the first with a second named scroll frame.
	-- It fills the body BELOW the tab strip -- the host's content area, which is the window's
	-- content standalone and the tab body embedded. Anchored to the window frame it ran past the
	-- tab border ("settings is still popping up another window that overlaps the main window").
	local overlay = chrome.frame.togRequestsSettings
	if overlay then
		self.SettingsOverlay = overlay
		for _, key in ipairs(SETTINGS_REFS) do self[key] = overlay.togRefs[key] end
		self.ReasonEditIndex = nil
		overlay:SetFrameLevel(chrome.frame:GetFrameLevel() + 50)
		overlay:ClearAllPoints()
		overlay:SetPoint("TOPLEFT", self.TabGroup.frame, "BOTTOMLEFT", 4, -4)
		overlay:SetPoint("BOTTOMRIGHT", self.Host.content, "BOTTOMRIGHT", 0, 0)
		overlay:Hide()
		return
	end

	overlay = CreateFrame("Frame", nil, chrome.frame, "BackdropTemplate")
	overlay:SetFrameLevel(chrome.frame:GetFrameLevel() + 50)
	overlay:SetPoint("TOPLEFT", self.TabGroup.frame, "BOTTOMLEFT", 4, -4)
	overlay:SetPoint("BOTTOMRIGHT", self.Host.content, "BOTTOMRIGHT", 0, 0)
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

	overlay.togRefs = {}
	for _, key in ipairs(SETTINGS_REFS) do overlay.togRefs[key] = self[key] end
	chrome.frame.togRequestsSettings = overlay
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
				self:SetStatusText(string.format("Custom reason limit reached (%d).", REASON_MAX))
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

-- Toggle between the Settings panel and the request list. The list's own widgets -- the search
-- box, the dropdowns, the column header, the table -- are HIDDEN while the panel is up, so
-- Settings reads as a tab and not as a second window over the list (the operator, on the Guild
-- Bank window: "settings is still popping up another window that overlaps the main window, it
-- should just be a tab now"). The bottom-row pagination/Cancel-Stale icons are meaningless on the
-- Settings tab, so they hide too.
function TOGBankClassic_UI_Requests:ShowSettings(show)
	for _, w in ipairs({ self.SearchBox, self.FilterGroup }) do
		setWidgetShown(w, not show)
	end
	-- The list is a plain frame, not a pooled widget: a plain Hide is enough.
	if self.ListHost then self.ListHost:SetShown(not show) end
	if show then
		if not self.SettingsOverlay then return end
		self:PopulateSettings()
		self:RefreshReasonsList()
		self.SettingsOverlay:Show()
		if self.CancelStaleBtn then self.CancelStaleBtn:Hide() end
		self:SetStatusText("Officer settings — changes to the last two sync guild-wide.")
	else
		if self.SettingsOverlay then self.SettingsOverlay:Hide() end
		if self.CancelStaleBtn then self.CancelStaleBtn:Show() end
	end
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
	if (request.status or "open") ~= "open" then
		return false
	end
	return TOGBankClassic_Guild:RequestQuantityNeeded(request) > 0
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

--- Every request in the guild, in no particular order. The RowList sorts the entries (entryFor's
--- `_sort_` values and the `_id` tie-break carry everything it needs); this used to be
--- SortedRequests and sorted them too, for the list to sort again.
function TOGBankClassic_UI_Requests:AllRequests()
	local info = TOGBankClassic_Guild.Info
	if not info or not info.requests then
		TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", "[UI-003] AllRequests: No guild info or requests")
		return {}
	end

	local list = {}
	-- Use pairs() since requests is now a map keyed by ID, not an array
	for _, req in pairs(info.requests) do
		table.insert(list, req)
	end

	TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", string.format("[UI-003] AllRequests: Found %d requests in Guild.Info", #list))
	return list
end

-- ─── REQUESTS-ROWLIST-001: the cells the rows own ───────────────────────────────
--
-- The RowList pools its rows by POSITION and re-renders them on every scroll, so nothing about a
-- request may be captured when a cell is built: every script reads the request off the cell
-- (`cell.req`, `cell._tipData`, the item overlay's `_itemName`), and _PopulateRow writes those on
-- every render. A cell that takes the mouse (all three do) locks the row's highlight through
-- `lockRowHighlight` (defined beside the action icons, which share it).

local function cellFontString(cell, justify)
	local fs = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("LEFT",  cell, "LEFT",  0, 0)
	fs:SetPoint("RIGHT", cell, "RIGHT", 0, 0)
	fs:SetJustifyH(justify or "LEFT")
	fs:SetWordWrap(false)
	fs:SetMaxLines(1)
	return fs
end

--- The date cell: the status glyph and the date, the timeline tooltip (submitted / filled /
--- cancelled, with the cancel reason), and the home of the cancelled glow. `cell.glowTarget` is
--- the { frame, label } pair SetCancelGlow takes -- the same shape as an AceGUI Label, which is
--- what it was written against and what the spec still hands it.
local function buildDateCell(row)
	local cell = CreateFrame("Frame", nil, row)
	cell:EnableMouse(true)
	local fs = cellFontString(cell, "LEFT")
	cell.label = fs
	cell.glowTarget = { frame = cell, label = fs }
	cell:SetScript("OnEnter", function(f)
		lockRowHighlight(f, true)
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
	cell:SetScript("OnLeave", function(f)
		lockRowHighlight(f, false)
		GameTooltip:Hide()
	end)
	return cell
end

--- The item cell: the name in its status colour, under a fully transparent EditBox so the name can
--- be selected and copied (click, Ctrl+C), with the item tooltip on hover.
local function buildItemCell(row)
	local cell = CreateFrame("Frame", nil, row)
	local fs = cellFontString(cell, "LEFT")
	cell.label = fs

	local eb = CreateFrame("EditBox", nil, cell)
	eb:SetFontObject("GameFontHighlightSmall")
	eb:SetMaxLetters(0)
	eb:SetMultiLine(false)
	eb:EnableMouse(true)
	eb:SetPoint("TOPLEFT", cell, "TOPLEFT", 0, 0)
	eb:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", 0, 0)
	eb:SetAutoFocus(false)
	eb:SetJustifyH("LEFT")
	eb:SetTextInsets(0, 0, 0, 0)
	eb:SetAlpha(0)
	-- The selection highlight is invisible too: the overlay is alpha 0, but a highlight would still
	-- paint. Era's SimpleEditBoxAPIDocumentation; the harness carries it since 1037beb, so the
	-- feature-detect guard that hid this line offline is gone and the spec asserts the colour.
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
		lockRowHighlight(cell, true)
		local itemName = self._itemName
		if not itemName or itemName == "" then return end

		-- If the request carries an explicit itemID, use it directly so we
		-- show the correct same-name variant (e.g. Druid vs Warrior Voodoo Doll).
		-- REQ-003: when a suffixID is present, prefer the inventory entry whose suffix
		-- matches so random-suffix siblings ("of the Tiger" vs "of the Monkey") resolve
		-- to the requested one rather than the first item sharing the base ID.
		-- LINK-AUDIT-001 (docs/LINK_AUDIT.md 3.4): this lookup and the hand-built item string
		-- below are the link layer's and change with it, not here.
		local requestItemID = self._itemID
		local requestSuffix = self._suffixID
		local itemLink, itemID
		if requestItemID then
			-- Search inventory for an entry with this exact ID (and suffix, when set) to get its full link
			local info = TOGBankClassic_Guild.Info
			if info and info.alts then
				-- INV2 step 7a: keyed by name so the rows come from GetAltItems, which
				-- honours the inventoryV2 switch. Reading alt.items directly here
				-- would have kept this lookup on the legacy store after the switch.
				for altName in pairs(info.alts) do
					for _, item in ipairs(TOGBankClassic_Guild:GetAltItems(altName)) do
						if item.ID == requestItemID
						   -- INV2-SUFFIX-001: read the row's stored Suffix, not the rebuilt
						   -- Link -- the link only carries it when ItemDB resolved the id.
						   and (not requestSuffix or TOGBankClassic_Item:RowSuffixID(item) == requestSuffix) then
							itemLink = item.Link
							itemID   = item.ID
							break
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
				for altName in pairs(info.alts) do
					for _, item in ipairs(TOGBankClassic_Guild:GetAltItems(altName)) do
						local name = item.Info and item.Info.name
						      or (item.Link and item.Link:match("%[(.-)%]"))
						if name == itemName then
							itemLink = item.Link
							itemID   = item.ID
							break
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
		lockRowHighlight(cell, false)
		GameTooltip:Hide()
	end)

	cell.editbox = eb
	return cell
end

--- The actions cell: five icon slots in a fixed order -- fulfil, hand-off, cancel, delete, re-open
--- -- so an icon sits in the same column on every row whatever else that row shows. Which are
--- shown, and the fulfil icon's state, are _PopulateRow's; the clicks read `cell.req` and
--- `cell.actor` off the cell.
local function buildActionsCell(row)
	local cell = CreateFrame("Frame", nil, row)
	local R = TOGBankClassic_UI_Requests
	cell.fulfill = newActionIcon(cell, 1, FULFILL_ICON, "Fulfill request", "", function(req)
		local _, message = TOGBankClassic_Mail:PrepareFulfillMail(req)
		R:SetStatusText(message or "")
	end)
	-- COMPLETEQTY-001: instead of silently marking complete, ask how many were handed over
	-- directly; the amount goes into the Sent column.
	cell.complete = newActionIcon(cell, 2, COMPLETE_ICON, "Mark hand-off",
		"Record how many you gave the requester directly (not by mail). Enter a quantity; it goes into the Sent column, and the order completes once Sent reaches the amount requested.",
		function(req) showCompleteQtyPrompt(req, cell.actor) end)
	cell.cancel = newActionIcon(cell, 3, CANCEL_ICON, "Cancel request", "Cancels the request without fulfilling it.",
		function(req) showCancelReasonDialog(req, cell.actor, R) end)
	cell.delete = newActionIcon(cell, 4, DELETE_ICON, "Delete permanently", "Permanently removes the request.",
		function(req) confirmDeleteRequest(req, cell.actor) end)
	-- REOPEN-001: re-open a finished order (banker/officer/GM). Shown only on completed rows.
	cell.reopen = newActionIcon(cell, 5, REOPEN_ICON, "Re-open order",
		"Re-open this finished order back to open (clears its Sent count), in case it was marked filled by mistake. Banker/officer/GM only.",
		function(req) confirmReopenRequest(req, cell.actor) end)
	return cell
end

for _, col in ipairs(COLUMNS) do
	if col.key == "date" then col.build = buildDateCell
	elseif col.key == "item" then col.build = buildItemCell
	elseif col.key == "actions" then col.build = buildActionsCell end
end

--- CANCEL-REASON-001: a soft glow on the date's LETTERS. The operator, on the first cut (a tinted
--- block behind the cell): "what i meant was a soft glow of the letters/numbers themselves"; on the
--- second (a coloured 1px text shadow): "it's just a 1px 'outline' can we actually make it 'glow'?".
--- The client has no text blur, so the glow is BUILT: copies of the text drawn under the glyphs in
--- three rings (1, 2 and 3 px out, eight directions each) whose alpha falls with distance -- the
--- overlaps stack bright at the glyph edge and thin out to nothing, which is what a blur looks like.
--- The glyphs' own black drop-shadow is switched off while the glow is on (it would cut a dark
--- notch into the halo) and put back when the pooled row is reused for an open request.
---
--- The colour is WARM CREAM, not gold: cancelled text is red, and gold is red's neighbour on the
--- wheel, so it merged into the glyphs ("red on red doesn't work" was the same lesson one step
--- earlier). A luminous halo is desaturated -- near-white with a little warmth -- and that is what
--- separates from red.
local GLOW_R, GLOW_G, GLOW_B = 1, 0.9, 0.7
-- Alpha per ring (index = radius in px). Eight copies overlap at the glyph edge, so coverage there
-- is 1 - (1 - a)^8: 0.12 -> 0.64, 0.06 -> 0.39, 0.03 -> 0.22. The first cut used 0.4/0.2/0.1 and
-- stacked to a solid cream blob that filled the counters of the 0s and 8s -- "i can't read it".
local GLOW_RINGS = { 0.12, 0.06, 0.03 }
local GLOW_DIRS  = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

local function plainText(text)
	return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

--- The frame the glow copies live on: a child of the cell at the cell's OWN frame level, its copies
--- on the ARTWORK layer, with the cell's glyphs raised to OVERLAY while they glow. Within one frame
--- level the client draws by layer across frames, so the copies are always under the glyphs and
--- never under anything else. A BACKGROUND sublevel under the label's own FontString was not enough
--- (on screen the copies painted OVER the glyphs), and CANCEL-GLOW-003's one-level-BELOW frame was
--- too much: whatever else sat at that level -- and it differs between the standalone window and
--- the Guild Bank tab -- could paint over the halo, and on the tab the operator saw no glow at all.
--- Re-levelled on every use, since AceGUI re-parents and re-levels pooled widgets.
--- The glow BREATHES: the operator picked a pulse over an icon ("oh, i like 2, can we do that?")
--- because motion is what catches the eye across a table where a static halo does not. One Alpha
--- animation on the glow frame, full to a third over a second, BOUNCE looping so it climbs back the
--- same way -- a two-second breath, eased at both ends so it never snaps. The glyphs are not on
--- this frame and do not pulse; only the halo does. BREATH-001: the breath is the library's
--- (LibAceGUIWidgets W:Breathe / W:StopBreathing, its defaults ARE these numbers -- 0.35 over 1.0 s,
--- BOUNCE, eased), the same call the help icon and the status bar's urgent line make.

local function glowFrame(label)
	local f = label.frame.togGlowFrame
	if not f then
		f = CreateFrame("Frame", nil, label.frame)
		f:SetAllPoints(label.frame)
		label.frame.togGlowFrame = f
	end
	f:SetFrameLevel(label.frame:GetFrameLevel())
	return f
end

local function ensureGlowLayers(label, fs)
	if fs.togGlowLayers then return fs.togGlowLayers end
	local parent = glowFrame(label)
	local layers = {}
	for radius, alpha in ipairs(GLOW_RINGS) do
		for _, dir in ipairs(GLOW_DIRS) do
			local g = parent:CreateFontString(nil, "ARTWORK")
			g:SetFontObject(fs:GetFontObject() or GameFontHighlightSmall)
			g:SetJustifyH(fs:GetJustifyH())
			g:SetJustifyV(fs:GetJustifyV())
			g:SetPoint("TOPLEFT",  fs, "TOPLEFT",  dir[1] * radius, dir[2] * radius)
			g:SetPoint("TOPRIGHT", fs, "TOPRIGHT", dir[1] * radius, dir[2] * radius)
			g:SetTextColor(GLOW_R, GLOW_G, GLOW_B)
			g:SetAlpha(alpha)
			if g.SetShadowColor then g:SetShadowColor(0, 0, 0, 0) end
			layers[#layers + 1] = g
		end
	end
	fs.togGlowLayers = layers
	return layers
end

--- The Appearance-tab switch for the glow. ON unless the player turned it off ("some folks will
--- whine about it ... folks can turn it off if they want"); a missing options DB (the addon before
--- Options:Init, a bare spec) is the default, not off.
---@return boolean
function TOGBankClassic_UI_Requests:CancelGlowEnabled()
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	return not (db and db.global and db.global.cancelGlow == false)
end

---@param label table the date cell (an AceGUI Label with .label, its FontString)
---@param on boolean
function TOGBankClassic_UI_Requests:SetCancelGlow(label, on)
	local fs = label and label.label
	if not (fs and fs.SetShadowColor) then return end
	if on and not self:CancelGlowEnabled() then on = false end
	if on then
		if not fs.togShadowSaved then
			local r, g, b, a, x, y
			if fs.GetShadowColor then r, g, b, a = fs:GetShadowColor() end
			if fs.GetShadowOffset then x, y = fs:GetShadowOffset() end
			-- GameFontNormal's own shadow when the getters are absent (the offline env).
			fs.togShadowSaved = { r or 0, g or 0, b or 0, a or 1, x or 1, y or -1 }
		end
		fs:SetShadowColor(0, 0, 0, 0)
		-- The glyphs above the copies by LAYER (AceGUI's Label draws its text on BACKGROUND).
		if fs.SetDrawLayer and not fs.togLayerSaved then
			fs.togLayerSaved = fs.GetDrawLayer and fs:GetDrawLayer() or "BACKGROUND"
			fs:SetDrawLayer("OVERLAY")
		end
		-- The glow copies carry the plain glyphs: the cell's colour escapes would paint them red.
		local text = plainText(fs:GetText())
		local frame = glowFrame(label)   -- re-level under the cell every draw, not only at creation
		for _, g in ipairs(ensureGlowLayers(label, fs)) do
			g:SetText(text)
			g:Show()
		end
		local W = TOGBankClassic_UI.Widgets
		if W and W.Breathe then W:Breathe(frame) end
		-- Self-audit 2026-09-12: AceGUI's widget pool is shared with every other addon, and the
		-- Requests window is Released whole when banker status changes (Open, ALPHA-001). A Label
		-- handed back with the glow ON would surface in someone else's UI with cream copies of our
		-- date pulsing under their text. Switch it off on the way out, exactly as ALPHA-001 clears
		-- the alpha -- through the one shared OnRelease (pool hygiene, above), since a date cell
		-- hidden for pagination carries that mark too and one registration would drop the other.
		fs.togCancelGlow = true
		markForRestore(label)
	elseif fs.togCancelGlow then
		local s = fs.togShadowSaved
		fs:SetShadowColor(s[1], s[2], s[3], s[4])
		fs:SetShadowOffset(s[5], s[6])
		if fs.togLayerSaved then
			fs:SetDrawLayer(fs.togLayerSaved)
			fs.togLayerSaved = nil
		end
		for _, g in ipairs(fs.togGlowLayers or {}) do g:Hide() end
		-- Stop, and leave the frame at full alpha: a stopped BOUNCE holds wherever it was, and the
		-- next cancelled request this pooled row shows would start from a dim halo.
		local frame, W = label.frame.togGlowFrame, TOGBankClassic_UI.Widgets
		if frame and W and W.StopBreathing then W:StopBreathing(frame) end
		fs.togCancelGlow = nil
	end
end

-- REQUESTS-ROWLIST-001: the per-request row pool is gone (InvalidateRow / InvalidateAllRows /
-- SetRowVisible / EnsureEmptyLabel / EnsureHeaderRows / DrawHeader were here). Every DrawRows
-- rebuilds the entries from the requests and the RowList re-renders whatever is in view, so
-- there is no "dirty" state to mark: the two invalidators are kept as the no-ops their callers
-- (Options' glow toggle, the mailbox open/close) still expect to find, and the next DrawRows is
-- the refresh.
function TOGBankClassic_UI_Requests:InvalidateRow() end
function TOGBankClassic_UI_Requests:InvalidateAllRows() end

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

-- SEARCH-006: the second header row SEARCH-005 built (a box under each of four columns) is gone.
-- The operator, on seeing it: "i don't need a search bar for each area, one bar that filters on
-- all columns would work" -- and "put them above the dropdown, not below". The one box is built
-- in BuildBody, above the Requester / Bank dropdowns. The column header itself is the RowList's
-- (gold GameFontNormalSmall, a click sorts, the arrow shows the direction, `headerTip` per column).

--- SEARCH-006: the one search text changed. Empty text clears the search.
---@param text string|nil
function TOGBankClassic_UI_Requests:SetSearch(text)
	text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	self.searchText = text ~= "" and text or nil
	self:DrawRows(false)   -- a new search starts at the top of the list
end

--- SEARCH-005: the text a column SHOWS for a request -- what a search must match against, so a
--- player searching for what they can see finds it. Status icons are not part of the date's text.
---@param req table
---@param key string column key
---@return string
function TOGBankClassic_UI_Requests:ColumnText(req, key)
	if key == "date" then
		local ts = tonumber(req.date or 0) or 0
		return ts > 0 and date("%Y-%m-%d %H:%M", ts) or "Unknown"
	elseif key == "item" then
		return TOGBankClassic_Item:RequestDisplayName(req) or ""
	end
	return tostring(req[key] or "")
end

--- SEARCH-006: does a request match the one search? Every word of `query` must appear somewhere
--- across what the searchable columns SHOW -- date, requester, bank, item -- case-insensitive
--- (TOGBankClassic_UI:SearchMatch over the four column texts). Pure: reads only the request and
--- the query, so the rule is one function for the UI and the spec. Nil / empty matches everything.
---@param req table
---@param query string|nil
---@return boolean
function TOGBankClassic_UI_Requests:SearchMatches(req, query)
	if not query or query == "" then return true end
	local texts = {}
	for _, col in ipairs(COLUMNS) do
		if col.search then texts[#texts + 1] = self:ColumnText(req, col.key) end
	end
	return TOGBankClassic_UI:SearchMatch(query, unpack(texts))
end

--- The banker's "Highlight needed items" checkbox on the filter strip's own second row. Built
--- ONCE, the first time the roster says the player is a banker: at BuildBody when the roster is
--- already loaded, else from UpdateFilters on a later draw. This used to be spelled twice (BuildBody
--- and UpdateFilters), and only the first copy had REQUESTS-STRIP-001's colspan cell, so a checkbox
--- created late landed in the Table as a bare fourth cell.
---@return boolean created true when the checkbox was built by THIS call
function TOGBankClassic_UI_Requests:EnsureHighlightCheckbox()
	if self.HighlightCheckbox or not self.FilterGroup then return false end
	-- The roster decides who is a banker; before it loads there is nothing to decide on.
	if GetNumGuildMembers() <= 0 then
		TOGBankClassic_Output:Debug("UI", "FILTER", "EnsureHighlightCheckbox: guild roster not loaded yet, skipping banker check")
		return false
	end
	local currentPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()
	if not TOGBankClassic_Guild:IsBank(currentPlayer) then
		TOGBankClassic_Output:Debug("UI", "FILTER", "EnsureHighlightCheckbox: %s is not a banker, no checkbox", tostring(currentPlayer))
		return false
	end
	local highlightCheckbox = TOGBankClassic_UI:Create("CheckBox")
	highlightCheckbox:SetLabel("Highlight needed items")
	highlightCheckbox:SetFullWidth(true)
	highlightCheckbox:SetUserData("cell", { colspan = 3 })   -- REQUESTS-STRIP-001: its own row
	highlightCheckbox:SetValue(TOGBankClassic_ItemHighlight and TOGBankClassic_ItemHighlight.enabled or false)
	highlightCheckbox:SetCallback("OnValueChanged", function(_, _, value)
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
	TOGBankClassic_Output:Debug("UI", "FILTER", "EnsureHighlightCheckbox: highlight checkbox created for banker %s", tostring(currentPlayer))
	return true
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

	-- The banker status may only now be known (the roster loaded after the window was built).
	if self:EnsureHighlightCheckbox() and self.FilterGroup.DoLayout then
		self.FilterGroup:DoLayout()
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
	local search = self.searchText
	local hasSearch = search ~= nil and search ~= ""
	if not self.requesterFilter and not self.bankFilter and not hasSearch then
		TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", string.format("[UI-003] ApplyFilters: No filters, returning all %d requests", #(requests or {})))
		return requests
	end

	local filtered = {}
	-- Use pairs() since requests is now a map keyed by ID, not an array
	for _, req in pairs(requests or {}) do
		if (not self.requesterFilter or req.requester == self.requesterFilter)
			and (not self.bankFilter or req.bank == self.bankFilter)
			and (not hasSearch or self:SearchMatches(req, search)) then   -- SEARCH-006
			table.insert(filtered, req)
		end
	end

	TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", string.format("[UI-003] ApplyFilters: Filtered from %d to %d requests (requester=%s, bank=%s, search=%s)",
		#(requests or {}), #filtered, tostring(self.requesterFilter), tostring(self.bankFilter), hasSearch and "yes" or "no"))

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

-- Returns the tab-filtered request list, caching the result so that bag-update and
-- filter-selection redraws skip the tab filter. The ORDER is not this cache's business: the
-- RowList sorts the entries by its own key (self-audit 1ebe87b4 F2 -- the body used to sort them
-- first by sortColumn/sortDirection and the list sorted the same rows again, so the cache was
-- keyed on a sort it did not need to know about).
-- Cache is invalidated at the top of DrawContent (called on structural changes).
function TOGBankClassic_UI_Requests:GetTabFiltered()
	if self._cachedTabFiltered and self._cachedTabFilter == self.currentTab then
		return self._cachedTabFiltered, self._cachedTotal
	end
	local tabFiltered = self:ApplyTabFilter(self:AllRequests())
	self._cachedTabFiltered = tabFiltered
	self._cachedTotal       = #tabFiltered
	self._cachedTabFilter   = self.currentTab
	return tabFiltered, self._cachedTotal
end

-- Units still owed on a request: Guild's one spelling, for both fulfil paths below.
local function quantityNeeded(req)
	return TOGBankClassic_Guild:RequestQuantityNeeded(req)
end

--- STALE-REQ-001: the version an OPEN request's requester is known to run when that version cannot
--- receive current bank contents, else nil. Read off the banker's Requests tab on 2026-09-13: a
--- request from a v1.3.2 client for a "Spiked Club" the bank had not held since the night before --
--- a client that old is turned away from every bank delivery since v1.4.0, so it browses a
--- months-old copy of the bank and requests from it, and the request itself is well-formed. The
--- gate that knows this is the sync layer's (Guild:PeerSpeaksDataLeg, WIRE-SKEW-004); this reads
--- it at draw time rather than storing a flag, so a requester who updates clears the mark on the
--- next draw with nothing to migrate. "unknown" and "dev" are not stale: a peer nobody has heard
--- from is not accused, as with the sync gate itself.
---
--- STALE-REQ-002: the gate's sources are session memory, and the requester of an order is usually
--- OFFLINE when the banker looks at it -- so after a reload the gate said "unknown" for the very
--- requester the mark was built for. When it does, the guild's memory of the version that
--- guildmate was LAST SEEN on (Guild:LastSeenAddonVersion) answers instead. Memory is read only
--- here, never by the sync gate.
---@param req table
---@return string|nil version the `d.d.d` the requester runs, when it is known to be too old
local function staleRequesterVersion(req)
	local G = TOGBankClassic_Guild
	if not (G and G.PeerSpeaksDataLeg) or not req or not req.requester then return nil end
	-- "Finished" is isComplete's one spelling (it already reads the cancelled/complete/fulfilled
	-- statuses); entryFor and the fulfil-icon gate read the same predicate.
	if isComplete(req) then return nil end
	local capable, why = G:PeerSpeaksDataLeg(req.requester)
	if not capable and type(why) == "string" then
		return why:match("%d+%.%d+%.%d+") or why
	end
	if why == "unknown" and G.LastSeenAddonVersion then
		local raw, remembered = G:LastSeenAddonVersion(req.requester)
		if remembered and raw then
			local n = G.EncodeVersion(raw)
			local min = TOGBankClassic_Constants.PROTOCOL.DATA_LEG_MIN_ADDON_VERSION
			if n ~= 0 and n < G.EncodeVersion(min) then
				return raw:match("%d+%.%d+%.%d+") or raw
			end
		end
	end
	return nil
end
TOGBankClassic_UI_Requests.StaleRequesterVersion = staleRequesterVersion

-- THE fulfil-button decision: turns Mail:CanFulfillRequest's verdict into the button's enabled
-- state, icon and tooltip. Peer-review finding 39: this twelve-branch block was copied byte-for-
-- byte into _PopulateRow AND _RefreshFulfillButtons, and every new reason string from
-- CanFulfillRequest (the `in mail and bank` / `shortfall in ...` family) had to be added to both
-- by hand -- miss one and the icon differs between the full redraw and the next BAG_UPDATE
-- refresh, which reads as flicker. Two entry points are right (the refresh path deliberately
-- skips text, permissions and closures); two copies of the decision were not.
local function applyFulfillState(button, req, canFulfill, fulfillReason, itemsInBags, mailboxOpen)
	if not button then return end
	local qtyNeeded      = quantityNeeded(req)
	local fulfillEnabled = canFulfill and mailboxOpen
	local needsSplit     = fulfillReason and string.find(fulfillReason, "Split")
	local isPartial      = fulfillReason and string.find(fulfillReason, "Partial")
	local buttonEnabled  = fulfillEnabled or (canFulfill and mailboxOpen and (needsSplit or isPartial))
	button.togDisabled = not buttonEnabled
	button:SetAlpha(buttonEnabled and 1.0 or 0.4)

	local icon, tooltipDetail
	if isPartial then
		icon = FULFILL_ICON_READY; tooltipDetail = fulfillReason
	elseif needsSplit then
		icon = FULFILL_ICON_NEED_SPLIT; tooltipDetail = fulfillReason
	elseif fulfillEnabled then
		icon = FULFILL_ICON_READY
		tooltipDetail = string.format("Attach %d %s to mail for %s.", math.min(itemsInBags, qtyNeeded), TOGBankClassic_Item:RequestDisplayName(req), req.requester or "requester")
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
		-- STALE-REQ-001: not found anywhere, and the requester runs a version that cannot see the
		-- bank as it is now -- say so, and what fixes it, rather than leaving "not in your bags"
		-- to read as a scan problem.
		local stale = staleRequesterVersion(req)
		if stale then
			tooltipDetail = tooltipDetail .. string.format(
				" %s is on v%s, which cannot receive current bank contents -- they requested from an old copy of this bank, and the item may be long gone. Ask them to update TOG Bank.",
				req.requester or "The requester", stale)
		end
	else
		icon = FULFILL_ICON_NOT_IN_BAGS; tooltipDetail = "Pick up items from bank first."
	end
	button.icon:SetText(icon)
	updateFulfillButtonTooltip(button, "Fulfill request", tooltipDetail)
end

--- The RowList entry for a request: the plain cells' text in the row's status colour, the sort
--- values (`_sort_`), and the request itself for the owned cells. The tie-break `_id` is the date
--- DESCENDING, so equal keys under any sort keep newest-first, as the old sorter did.
--- REQUESTS-ROWLIST-002: the inverted date is ~8.2e9, past a 32-bit int, and the client's
--- `string.format("%d")` refuses it ("integer overflow attempting to store 8210744788" -- the
--- operator's first open of the tab). `%.0f` formats the double as digits with no int cast; the
--- offline Lua casts silently, so the suite could not see it.
local function entryFor(req)
	local completed = isComplete(req)
	local reqStatus = req.status or "open"
	if completed and reqStatus == "open" then reqStatus = "fulfilled" end
	local ts = tonumber(req.date or 0) or 0
	local dateText = ts > 0 and date("%Y-%m-%d %H:%M", ts) or "Unknown"
	local glyph
	if reqStatus == "cancelled" then
		glyph = CANCELLED_ICON
	elseif completed then
		glyph = CHECK_MARK_ICON
	else
		glyph = PADDING_ICON
	end
	local qty = req.quantity
	local qtyText = (qty == nil or qty == "") and "" or (tostring(qty) .. "x")
	local itemName = TOGBankClassic_Item:RequestDisplayName(req)   -- NAME-001
	local requester, bank = req.requester or "", req.bank or ""
	-- STALE-REQ-001: the requester's too-old version rides beside the name, in the fulfil icon's
	-- amber, so the banker can see why an order names something the bank does not hold.
	local stale = staleRequesterVersion(req)
	local requesterText = colorize(requester, reqStatus)
	if stale then requesterText = requesterText .. " |cffff9900v" .. stale .. "|r" end
	return {
		req = req, status = reqStatus, completed = completed, itemName = itemName, staleClient = stale,
		_id = string.format("%010.0f:%s", 9999999999 - ts, tostring(req.id)),
		date      = glyph .. colorize(dateText, reqStatus),         _sort_date      = ts,
		requester = requesterText,                                   _sort_requester = requester:lower(),
		bank      = colorize(bank, reqStatus),                       _sort_bank      = bank:lower(),
		quantity  = colorize(qtyText, reqStatus),                    _sort_quantity  = tonumber(qty) or 0,
		item      = colorize(itemName, reqStatus),                   _sort_item      = itemName:lower(),
		fulfilled = colorize(tostring(req.fulfilled or ""), reqStatus), _sort_fulfilled = tonumber(req.fulfilled) or 0,
	}
end

-- Paint the cells a row owns for the entry the RowList just put on it: the date (glyph, text,
-- timeline tooltip data, the cancelled glow), the item (text and the copy overlay's lookup keys)
-- and the actions (which icons show, the fulfil icon's state, the request the clicks act on).
-- Called from the RowList's onRowRender on every render -- a scroll included -- so it captures
-- nothing: the actor and the mailbox state are read off `self._renderCtx`, set by DrawRows.
function TOGBankClassic_UI_Requests:_PopulateRow(row, entry)
	local ctx = self._renderCtx or {}
	local actor, actorIsGM, isActorBank, mailboxOpen = ctx.actor, ctx.actorIsGM, ctx.isActorBank, ctx.mailboxOpen
	local req, reqStatus, completed = entry.req, entry.status, entry.completed
	local requestId = req.id
	row.togEntry = entry

	local dateCell = row.cells.date
	if dateCell then
		dateCell.label:SetText(entry.date)
		dateCell._tipData = { date = req.date, updatedAt = req.updatedAt, status = reqStatus, notes = req.notes }
		-- CANCEL-REASON-001: the reason has always been in this cell's tooltip and nobody knew to
		-- hover. The operator: "make some way to show why things were cancelled, folks can't see why
		-- easily ... maybe a background glow or something". A cancelled request gets a soft glow on
		-- its date's glyphs, so the cell reads as "there is more here" -- the reason itself stays in
		-- the tooltip.
		-- CANCEL-GLOW-002: EVERY cancelled request, not only those with a reason. The operator, the
		-- day after: "can we add the 'breath' effect to the cancelled items? i'd like to apply what
		-- we did yesterday to the old cancelled items to make them more noticible". Requests cancelled
		-- before reasons existed have none and were the ones left unmarked; the breath is what draws
		-- the eye, and a cancelled row is what it should draw it to, reason or not.
		local label = dateCell.glowTarget
		self:SetCancelGlow(label, reqStatus == "cancelled")
	end

	local itemCell = row.cells.item
	if itemCell then
		itemCell.label:SetText(entry.item)
		-- The copy overlay's keys for the tooltip lookup.
		itemCell.editbox._itemName = entry.itemName
		itemCell.editbox._itemID   = req.itemID or nil    -- nil for legacy requests
		itemCell.editbox._suffixID = req.suffixID or nil  -- REQ-003: nil unless a random-suffix variant
	end

	local actions = row.cells.actions
	if actions then
		actions.req, actions.actor = req, actor
		local canCancel   = not completed and requestId and TOGBankClassic_Guild:CanCancelRequest(req, actor)
		local canComplete = not completed and requestId and TOGBankClassic_Guild:CanCompleteRequest(req, actor, actorIsGM)
		local canDelete   = requestId and TOGBankClassic_Guild:CanDeleteRequest(req, actor, actorIsGM)
		-- REOPEN-001: only a finished order, and only for banker/officer/GM.
		local canReopen   = completed and requestId and TOGBankClassic_Guild:CanManageRequests(actor, actorIsGM)
		local showFulfill = isActorBank and not completed and requestId
		actions.fulfill:SetShown(showFulfill and true or false)
		actions.complete:SetShown(canComplete and true or false)
		actions.cancel:SetShown(canCancel and true or false)
		actions.delete:SetShown(canDelete and true or false)
		actions.reopen:SetShown(canReopen and true or false)
		if showFulfill then
			local canFulfill, fulfillReason, itemsInBags = TOGBankClassic_Mail:CanFulfillRequest(req, actor)
			applyFulfillState(actions.fulfill, req, canFulfill, fulfillReason, itemsInBags, mailboxOpen)
		end
	end
end

-- Only refresh the fulfill icon on the rows in view -- used by bag-update events so the icon and
-- its state follow the bags without a full redraw of the text, permissions or the list.
function TOGBankClassic_UI_Requests:_RefreshFulfillButtons(actor, isActorBank, mailboxOpen)
	if not self.List then return end
	local ctx = self._renderCtx or {}
	ctx.actor, ctx.isActorBank, ctx.mailboxOpen = actor, isActorBank, mailboxOpen
	self._renderCtx = ctx
	for _, row in ipairs(self.List.rows) do
		local entry = row:IsShown() and row.togEntry
		local actions = entry and row.cells.actions
		if actions then
			local req = entry.req
			-- Same gate as _PopulateRow's showFulfill (finding 39's unnumbered note): a row whose
			-- request completed between draws gets its icon hidden here too, not left showing a
			-- stale icon until the next full redraw.
			local showFulfill = isActorBank and not isComplete(req) and req.id
			actions.fulfill:SetShown(showFulfill and true or false)
			if showFulfill then
				local canFulfill, fulfillReason, itemsInBags = TOGBankClassic_Mail:CanFulfillRequest(req, actor)
				applyFulfillState(actions.fulfill, req, canFulfill, fulfillReason, itemsInBags, mailboxOpen)
			end
		end
	end
end

-- REQUESTS-ROWLIST-001: `_ApplySortOrder` and `_CreateNewRowsBatched` were here -- reordering the
-- grid's AceGUI children to match the sort, and creating new rows twenty per frame so a page of
-- fifty did not stutter the client. The RowList renders only the rows in view from a plain array,
-- so the whole set is one SetData and there is nothing to reorder or to batch.

--- The rows: every request on the current tab through the search and the two dropdowns, as
--- RowList entries, in one SetData. `preserveScroll` keeps the view where it was (a background
--- request sync, a bag update) -- the "snap back" the old page reset produced; a new search,
--- filter or tab starts at the top.
---@param preserveScroll boolean|nil defaults to true
function TOGBankClassic_UI_Requests:DrawRows(preserveScroll)
	if not self.List or not self.Host then return end
	if preserveScroll == nil then preserveScroll = true end

	local actor       = TOGBankClassic_Guild:GetNormalizedPlayer()
	local actorIsGM   = actor and TOGBankClassic_Guild:SenderIsGM(actor) or false
	local isActorBank = TOGBankClassic_Guild:IsBank(actor)
	local mailboxOpen = TOGBankClassic_Mail.isOpen or (MailFrame and MailFrame:IsShown()) or false
	self._renderCtx = { actor = actor, actorIsGM = actorIsGM, isActorBank = isActorBank, mailboxOpen = mailboxOpen }

	-- The tab-filtered list (cached; invalidated by DrawContent), then the search and dropdowns.
	-- Unordered: the RowList sorts the entries.
	local tabFiltered, total = self:GetTabFiltered()
	local visible = self:ApplyFilters(tabFiltered)
	local count = #visible

	TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", string.format("[UI-003] DrawRows: %d visible of %d total", count, total))

	local entries = {}
	for i, req in ipairs(visible) do entries[i] = entryFor(req) end
	self.List:SetData(entries, preserveScroll)
	self.rowsShown = entries

	if count == 0 then
		-- SEARCH-005: an empty list behind a search box or filter is "nothing matches", not
		-- "nothing exists" -- the difference between clearing the box and waiting for a request.
		local narrowed = (self.searchText ~= nil and self.searchText ~= "")
			or self.requesterFilter or self.bankFilter
		local text
		if narrowed and total > 0 then
			text = "No requests match the search or filters."
		else
			text = self.currentTab == "archive" and "No archived requests." or "No requests yet."
		end
		if self.EmptyText then
			self.EmptyText:SetText(text)
			self.EmptyText:Show()
		end
		self:SetStatusText(string.format("Showing 0 requests out of %d total", total))
		return
	end
	if self.EmptyText then self.EmptyText:Hide() end
	self:SetStatusText(string.format("Showing %d request%s out of %d total", count, count == 1 and "" or "s", total))
end

function TOGBankClassic_UI_Requests:DrawContent()
	if not self.List or not self.Host then
		TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", "[UI-003] DrawContent: No content or window")
		return
	end

	TOGBankClassic_Output:Debug("REQUESTS", "RECEIVE", "[UI-003] DrawContent: Starting structural refresh")

	self:SetStatusText("")
	-- Back to the top of the list only when the tab actually changed. Background request syncs
	-- call DrawContent too (via RefreshRequestsUI); resetting the scroll there would snap the user
	-- back to the top mid-browse (the "snap back" bug).
	local sameTab = self._lastDrawnTab == self.currentTab
	self._lastDrawnTab = self.currentTab

	-- Settings tab shows the officer panel instead of the request list.
	if self.currentTab == "settings" then
		self:ShowSettings(true)
		return
	end
	self:ShowSettings(false)

	self:UpdateFilters()
	if self.FilterGroup then self.FilterGroup:DoLayout() end
	self:DoLayout()

	-- Invalidate the tab-filter cache so the data is refreshed
	self._cachedTabFiltered = nil
	self:DrawRows(sameTab)
end



