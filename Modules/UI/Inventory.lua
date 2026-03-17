TOGBankClassic_UI_Inventory = {}

-- Formats a copper amount as colored text (gold/silver/copper).
-- Replaces GetCoinTextureString() which renders broken square icons in AceGUI status bars.
local function FormatMoneyText(copper)
	copper = copper or 0
	if copper <= 0 then
		return "|cff7f7f7f0c|r"
	end
	local gold   = math.floor(copper / 10000)
	local silver = math.floor((copper % 10000) / 100)
	local cp     = copper % 100
	local parts  = {}
	if gold > 0 then
		table.insert(parts, string.format("|cffFFD700%dg|r", gold))
	end
	if silver > 0 or gold > 0 then
		table.insert(parts, string.format("|cffc0c0c0%ds|r", silver))
	end
	if cp > 0 or (gold == 0 and silver == 0) then
		table.insert(parts, string.format("|cffb46a2f%dc|r", cp))
	end
	return table.concat(parts, " ")
end

function TOGBankClassic_UI_Inventory:Init()
	-- Frame creation deferred to first Open() call (PERF-015)
end

local function QueryEmpty()
	local now = GetServerTime()
	local last = TOGBankClassic_UI_Inventory.last_empty_sync or 0
	if now - last > 30 then
		TOGBankClassic_UI_Inventory.last_empty_sync = now
		TOGBankClassic_Guild:Share()
	end
end

local function OnClose(_)
	if TOGBankClassic_UI_Inventory.networkTicker then
		TOGBankClassic_UI_Inventory.networkTicker:Cancel()
		TOGBankClassic_UI_Inventory.networkTicker = nil
	end
	TOGBankClassic_UI_Inventory.isOpen = false
	TOGBankClassic_UI_Inventory.Window:Hide()

	TOGBankClassic_UI_Donations:Close()
	TOGBankClassic_UI_Requests:Close()
	TOGBankClassic_UI_Search:Close()
end

function TOGBankClassic_UI_Inventory:Toggle()
	if self.isOpen then
		self:Close()
	else
		self:Open()
	end
end

function TOGBankClassic_UI_Inventory:Open()
	if self.isOpen then
		return
	end
	self.isOpen = true

	if not self.Window then
		self:DrawWindow()
	end

	self.Window:Show()

	self:DrawContent()

	-- Perform full sync (same as /togbank sync command)
	if TOGBankClassic_Chat and TOGBankClassic_Chat.PerformSync then
		TOGBankClassic_Chat:PerformSync()
	end

	if _G["TOGBankClassic"] then
		_G["TOGBankClassic"]:Show()
	else
		TOGBankClassic_UI:Controller()
	end
end

function TOGBankClassic_UI_Inventory:Close()
	if not self.isOpen then
		return
	end
	if not self.Window then
		return
	end

	OnClose(self.Window)
end

function TOGBankClassic_UI_Inventory:DrawWindow()
	local window = TOGBankClassic_UI:Create("Frame")
	window:Hide()
	window:SetCallback("OnClose", OnClose)
	window:SetTitle("TOGBankClassic")
	window:SetLayout("Flow")
	window:SetWidth(550)
	-- Persist window position/size across reloads
	if TOGBankClassic_Options and TOGBankClassic_Options.db then
		window:SetStatusTable(TOGBankClassic_Options.db.char.framePositions)
	end
	--handle keyboard events
	---START CHANGES
	window.frame:SetResizeBounds(500, 500)
	---END CHANGES
	window.frame:EnableKeyboard(true)
	window.frame:SetPropagateKeyboardInput(true)
	window.frame:SetScript("OnKeyDown", function(self, event)
		TOGBankClassic_UI:EventHandler(self, event)
	end)

	self.Window = window

	-- Add center and right FontStrings to the status bar for tri-part alignment.
	-- AceGUI's statustext spans TOPLEFT->BOTTOMRIGHT with LEFT justification;
	-- we create two siblings over the same area with CENTER and RIGHT justification.
	local statusbg = window.statustext:GetParent()
	local statusCenter = statusbg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	statusCenter:SetPoint("TOPLEFT", statusbg, "TOPLEFT", 7, -2)
	statusCenter:SetPoint("BOTTOMRIGHT", statusbg, "BOTTOMRIGHT", -7, 2)
	statusCenter:SetHeight(20)
	statusCenter:SetJustifyH("CENTER")
	statusCenter:SetText("")
	window.statusCenter = statusCenter

	local statusRight = statusbg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	statusRight:SetPoint("TOPLEFT", statusbg, "TOPLEFT", 7, -2)
	statusRight:SetPoint("BOTTOMRIGHT", statusbg, "BOTTOMRIGHT", -7, 2)
	statusRight:SetHeight(20)
	statusRight:SetJustifyH("RIGHT")
	statusRight:SetText("")
	window.statusRight = statusRight

	local buttonContainer = TOGBankClassic_UI:Create("SimpleGroup")
	buttonContainer:SetLayout("Table")
	buttonContainer:SetUserData("table", {
		columns = {
			{
				width = 0.34,
				align = "start",
			},
			{
				width = 0.33,
				align = "center",
			},
			{
				width = 0.33,
				align = "end",
			},
		},
	})
	buttonContainer:SetFullWidth(true)
	---START CHANGES
	--buttonContainer.frame:SetBackdropColor(0, 0, 0, 0)
	--buttonContainer.frame:SetBackdropBorderColor(0, 0, 0, 0)
	---END CHANGES
	buttonContainer.frame:ClearAllPoints()
	buttonContainer.content:SetPoint("TOPLEFT", 0, 5)
	buttonContainer.content:SetPoint("BOTTOMRIGHT", 0, -5)
	window:AddChild(buttonContainer)

	local searchButton = TOGBankClassic_UI:Create("Button")
	searchButton:SetText("Search")
	searchButton:SetCallback("OnClick", function(_)
		TOGBankClassic_UI_Search:Toggle()
	end)
	searchButton:SetWidth(160)
	searchButton:SetHeight(24)
	buttonContainer:AddChild(searchButton)

	local function GetSortLabel(m)
		return m == "type" and "Sort: By Type" or "Sort: A-Z"
	end
	local sortButton = TOGBankClassic_UI:Create("Button")
	local initMode = (TOGBankClassic_Options and TOGBankClassic_Options.db and TOGBankClassic_Options.db.char.sortMode) or "alpha"
	sortButton:SetText(GetSortLabel(initMode))
	sortButton:SetWidth(160)
	sortButton:SetHeight(24)
	sortButton:SetCallback("OnClick", function(_)
		local db = TOGBankClassic_Options and TOGBankClassic_Options.db and TOGBankClassic_Options.db.char
		if not db then return end
		db.sortMode = (db.sortMode == "type") and "alpha" or "type"
		sortButton:SetText(GetSortLabel(db.sortMode))
		-- Reload current tab with new sort order
		local tab = self.TabGroup.localstatus and self.TabGroup.localstatus.selected
		if tab then
			self.currentTab = nil
			self.tabLoaded = false
			self.TabGroup:SelectTab(tab)
		end
	end)
	self.SortButton = sortButton
	buttonContainer:AddChild(sortButton)

	local requestsButton = TOGBankClassic_UI:Create("Button")
	requestsButton:SetText("Requests")
	requestsButton:SetCallback("OnClick", function(_)
		TOGBankClassic_UI_Requests:Toggle()
	end)
	requestsButton:SetWidth(160)
	requestsButton:SetHeight(24)
	buttonContainer:AddChild(requestsButton)

	local tabGroup = TOGBankClassic_UI:Create("TabGroup")
	tabGroup:SetLayout("Flow")
	tabGroup:SetFullWidth(true)
	tabGroup:SetFullHeight(true)
	window:AddChild(tabGroup)

	self.TabGroup = tabGroup
end

-- Single-pass CTL queue inspector: returns total, nextPrefix, nextDest, recipientCount.
-- Walks in ALERT->NORMAL->BULK order so "next" reflects true send priority.
local CTL_PRIO_ORDER = {"ALERT", "NORMAL", "BULK"}
local function CTLQueueInfo()
	local ctl = _G.ChatThrottleLib
	if not ctl or not ctl.Prio then return 0, nil, nil, 0 end
	local total = 0
	local nextPrefix, nextDest
	local recipients = {}
	local function walkRing(ring)
		if not ring or not ring.pos then return end
		local pipe = ring.pos
		repeat
			for i = 1, #pipe do
				local msg = pipe[i]
				total = total + 1
				local dest = msg[4] or msg[3]
				if dest then recipients[dest] = true end
				if not nextPrefix and msg[1] then
					nextPrefix = msg[1]
					nextDest = dest
				end
			end
			pipe = pipe.next
		until pipe == ring.pos
	end
	for _, prioName in ipairs(CTL_PRIO_ORDER) do
		local prio = ctl.Prio[prioName]
		if prio then
			walkRing(prio.Ring)
			walkRing(prio.Blocked)
		end
	end
	local recipientCount = 0
	for _ in pairs(recipients) do recipientCount = recipientCount + 1 end
	return total, nextPrefix, nextDest, recipientCount
end

-- Returns leftText, centerText, rightText for tri-part status bar alignment.
function TOGBankClassic_UI_Inventory:BuildNetworkStatus()
	local leftParts  = {}
	local centerText = ""
	local rightParts = {}

	-- P2P sends in flight (alt inventory data being sent to peers) -> LEFT
	local sends = TOGBankClassic_Guild.pendingSendCount or 0
	if sends > 0 then
		local max = TOGBankClassic_Guild.MAX_PENDING_SENDS or 3
		local c = (sends >= max) and "ffff4444" or "ffff9900"
		table.insert(leftParts, string.format("|c%ssend:%d/%d|r", c, sends, max))
	end

	-- Outgoing sync queue (alts queued to broadcast their data) -> LEFT
	local syncQ = TOGBankClassic_Chat and TOGBankClassic_Chat.sync_queue and #TOGBankClassic_Chat.sync_queue or 0
	if syncQ > 0 then
		table.insert(leftParts, string.format("|cffffff00q:%d|r", syncQ))
	end

	-- P2P data fetches in flight (waiting for alt data from peers) -> LEFT
	local fetches = 0
	if TOGBankClassic_Guild.pendingP2PRequests then
		for _ in pairs(TOGBankClassic_Guild.pendingP2PRequests) do fetches = fetches + 1 end
	end
	if fetches > 0 then
		table.insert(leftParts, string.format("|cff87ceebfetch:%d|r", fetches))
	end

	-- Request sync state (requests-index handshake) -> RIGHT
	local rSync = TOGBankClassic_Guild.requestsIndexSync
	if rSync then
		if rSync.awaitingById then
			local bTotal = rSync.batchTotal
			if bTotal and bTotal > 0 then
				table.insert(rightParts, string.format("|cff87ceebr:%d/%d|r", rSync.batchSent or 0, bTotal))
			else
				table.insert(rightParts, "|cff87ceebr:ids|r")
			end
		elseif rSync.inFlight then
			local target = rSync.inFlight
			if target == "*" then
				table.insert(rightParts, "|cff87ceebQuerying requests index...|r")
			else
				table.insert(rightParts, string.format("|cff87ceebQuerying requests index from %s|r", target))
			end
		end
	end

	-- ChatThrottleLib outbound queue: next message -> CENTER, backlog -> RIGHT
	local ctlDepth, nextPrefix, nextDest, recipientCount = CTLQueueInfo()
	local queriedCount = TOGBankClassic_Guild:GetQueriedRequestsCount()
	if ctlDepth > 0 then
		if nextPrefix then
			local desc = COMM_PREFIX_DESCRIPTIONS and COMM_PREFIX_DESCRIPTIONS[nextPrefix]
			local msgType = (desc and string.match(desc, "^%((.-)%)$")) or nextPrefix
			centerText = string.format("|cffffffffSending %s to %s|r", msgType, nextDest or "?")
		end
		local c = ctlDepth >= 1000 and "ffff4444" or "ffff9900"
		local backlog = string.format("%d packets", ctlDepth)
		if recipientCount > 1 then
			backlog = backlog .. string.format(", %d recipients", recipientCount)
		end
		if queriedCount > 0 then
			backlog = backlog .. string.format(", %d requests", queriedCount)
		end
		table.insert(rightParts, string.format("|c%sBacklog: %s|r", c, backlog))
	end

	local left = #leftParts > 0 and ("    " .. table.concat(leftParts, "  ")) or ""
	return left, centerText, table.concat(rightParts, "  ")
end

function TOGBankClassic_UI_Inventory:RefreshStatusBar()
	if not self.Window then return end
	if self.statusHovered then return end
	local left, center, right = self:BuildNetworkStatus()
	self.Window:SetStatusText((self.baseStatusText or "") .. left)
	if self.Window.statusCenter then self.Window.statusCenter:SetText(center) end
	if self.Window.statusRight  then self.Window.statusRight:SetText(right)   end
end

function TOGBankClassic_UI_Inventory:DrawContent()
	local info = TOGBankClassic_Guild.Info
	local roster_alts = TOGBankClassic_Guild:GetRosterAlts()
	if not info or not roster_alts then
		QueryEmpty()
		OnClose()
		TOGBankClassic_Output:Response("Database is empty; wait for sync.")
		return
	end

	-- Sync sort button label with persisted mode (db available by the time DrawContent runs)
	if self.SortButton and TOGBankClassic_Options and TOGBankClassic_Options.db then
		local m = TOGBankClassic_Options.db.char.sortMode or "alpha"
		self.SortButton:SetText(m == "type" and "Sort: By Type" or "Sort: A-Z")
	end

	-- Clear search data built flag so search rebuilds on next open (PERF-004)
	TOGBankClassic_UI_Search.searchDataBuilt = false

	local players = {}
	local n = 0
	for _, v in pairs(roster_alts) do
		n = n + 1
		players[n] = v
	end

	table.sort(players)

	local tabs = {}
	local first_tab = nil
	local total_gold = 0
	local slots = 0
	local total_slots = 0
	local i = 1
	for _, player in pairs(players) do
		local norm = TOGBankClassic_Guild:NormalizeName(player)
		local alt = info.alts[norm]
		---START CHANGES
		--if alt then
		if alt and type(alt) == "table" then
			---END CHANGES
			if not first_tab then
				first_tab = player
			end
			tabs[i] = { value = player, text = player }
			if alt.money then
				total_gold = total_gold + alt.money
			end
			if alt.bank and alt.bank.slots then
				slots = slots + alt.bank.slots.count
				total_slots = total_slots + alt.bank.slots.total
			end
			if alt.bags and alt.bags.slots then
				slots = slots + alt.bags.slots.count
				total_slots = total_slots + alt.bags.slots.total
			end
			i = i + 1
		end
	end

	if #tabs == 0 then
		QueryEmpty()
		OnClose()
		TOGBankClassic_Output:Response("Database is empty; wait for sync.")
		return
	end

	self.TabGroup:SetTabs(tabs)

	local percent = total_slots > 0 and (slots / total_slots) or 0
	local color = TOGBankClassic_UI_Inventory:GetPercentColor(percent)
	local defaultStatus =
		string.format("%s    |c%s%d/%d|r", FormatMoneyText(total_gold), color, slots, total_slots)
	self.baseStatusText = defaultStatus
	self.statusHovered = false
	self:RefreshStatusBar()

	-- Start network status refresh ticker (cancelled in OnClose)
	if self.networkTicker then
		self.networkTicker:Cancel()
	end
	self.networkTicker = C_Timer.NewTicker(0.5, function()
		TOGBankClassic_UI_Inventory:RefreshStatusBar()
	end)

	self.Window:SetCallback("OnEnterStatusBar", function(_)
		self.statusHovered = true
		if self.Window.statusCenter then self.Window.statusCenter:SetText("") end
		if self.Window.statusRight  then self.Window.statusRight:SetText("")  end
		local tab = self.TabGroup.localstatus.selected
		local normTab = TOGBankClassic_Guild:NormalizeName(tab)
		local alt = info.alts[normTab]

		-- Defensive: Check if alt exists and has valid data
		if not alt or type(alt) ~= "table" then
			self.Window:SetStatusText("No data available")
			return
		end

		-- Check if alt has been synced (version > 0 means real data)
		if not alt.version or alt.version == 0 then
			self.Window:SetStatusText("Waiting for sync...")
			return
		end

		local datetime = date("%Y-%m-%d %H:%M:%S", alt.version)
		local slot_count = 0
		local slot_total = 0
		if alt.bank and alt.bank.slots then
			slot_count = slot_count + alt.bank.slots.count
			slot_total = slot_total + alt.bank.slots.total
		end
		if alt.bags and alt.bags.slots then
			slot_count = slot_count + alt.bags.slots.count
			slot_total = slot_total + alt.bags.slots.total
		end

		-- Add mail item count if available
		local mailCount = 0
		if alt.mail and alt.mail.items then
			for _ in pairs(alt.mail.items) do
				mailCount = mailCount + 1
			end
		end

		local money = 0
		if alt.money then
			money = alt.money
		end

		local percent = slot_total > 0 and (slot_count / slot_total) or 0
		local color = TOGBankClassic_UI_Inventory:GetPercentColor(percent)
		local mailText = ""
		if mailCount > 0 then
			local age = TOGBankClassic_MailInventory:GetMailDataAge(alt)
			local ageText = age and (" (" .. SecondsToTime(age) .. " ago)") or ""
			mailText = string.format("    |cff87ceebMail: %d item%s%s|r", mailCount, mailCount > 1 and "s" or "", ageText)
		end
		local status = string.format(
			"As of %s    %s    |c%s%d/%d|r%s",
			datetime,
			FormatMoneyText(money),
			color,
			slot_count,
			slot_total,
			mailText
		)
		self.Window:SetStatusText(status)
	end)
	self.Window:SetCallback("OnLeaveStatusBar", function(_)
		self.statusHovered = false
		self:RefreshStatusBar()
	end)

	self.TabGroup:SetCallback("OnGroupSelected", function(group)
		local tab = group.localstatus.selected
		
		-- Prevent processing the same tab multiple times
		if self.currentTab == tab and self.tabLoaded then
			TOGBankClassic_Output:Debug("MAIL", "[RACE-CONDITION] BLOCKED duplicate OnGroupSelected for tab %s - something is triggering tab reload!", tab)
			-- Print stack trace to see what's calling this
			local stack = debugstack(2)
			TOGBankClassic_Output:Debug("MAIL", "[RACE-CONDITION] Stack trace:\n%s", stack)
			return
		end
		self.currentTab = tab
		self.tabLoaded = false  -- Will be set to true after GetItems completes
		
		TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Loading tab %s", tab)

		self.TabGroup:ReleaseChildren()

		local g = TOGBankClassic_UI:Create("SimpleGroup")
		g:SetFullWidth(true)
		g:SetFullHeight(true)
		g:SetLayout("Flow")
		self.TabGroup:AddChild(g)

		local scroll = TOGBankClassic_UI:Create("ScrollFrame")
		scroll:SetLayout("Flow")
		scroll:SetFullHeight(true)
		scroll:SetFullWidth(true)
		g:AddChild(scroll)
		
		-- Track scroll container to prevent race conditions
		local scrollId = tostring(scroll)
		scroll.callbackProcessed = false

		local normTab = TOGBankClassic_Guild:NormalizeName(tab)
		local alt = info.alts[normTab]

		-- Use alt.items if available (post-SYNC-006 aggregate)
		-- Otherwise compute from sources for backward compatibility
		local items = {}

		if alt.items and next(alt.items) ~= nil then
			-- alt.items exists - use it directly (may be array or key-value)
			for _, item in pairs(alt.items) do
				table.insert(items, item)
			end
			TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Inventory tab %s: using alt.items (%d items)",
				tab, #items)
		else
			-- Fallback: compute from sources (backward compatibility for very old data)
			local bankItems = (alt.bank and alt.bank.items) or {}
			local bagItems = (alt.bags and alt.bags.items) or {}
			local mailItems = (alt.mail and alt.mail.items) or {}

			TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Inventory tab %s: computing from sources bank=%d, bags=%d, mail=%d",
				tab, #bankItems, #bagItems, #mailItems)

			-- Aggregate all sources (all are now in array format), then convert the key-value result to array
			local aggregated = TOGBankClassic_Item:Aggregate(bankItems, bagItems)
			aggregated = TOGBankClassic_Item:Aggregate(aggregated, mailItems)
			for _, item in pairs(aggregated) do
				table.insert(items, item)
			end
		end

		TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Inventory tab %s: aggregated to %d unique items",
			tab, #items)

		-- Show loading indicator immediately
		local loadingLabel = TOGBankClassic_UI:Create("Label")
		loadingLabel:SetText("|cff808080Loading items...|r")
		loadingLabel:SetFullWidth(true)
		scroll:AddChild(loadingLabel)

		if items and #items > 0 then
			-- Debug: Check for duplicate item IDs with different links
			local itemsByID = {}
			for _, item in pairs(items) do
				if item and item.ID then
					if not itemsByID[item.ID] then
						itemsByID[item.ID] = {}
					end
					table.insert(itemsByID[item.ID], { Count = item.Count, Link = item.Link })
				end
			end
			for itemID, entries in pairs(itemsByID) do
				if #entries > 1 then
					TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] DUPLICATE ITEM ID %d found with %d different entries:", itemID, #entries)
					for i, entry in ipairs(entries) do
						TOGBankClassic_Output:Debug("MAIL", "[MAIL-002]   Entry %d: Count=%d, Link=%s", i, entry.Count, entry.Link or "nil")
					end
				end
			end

			-- Validate and filter items before passing to GetItems
			local validItems = {}
			for i, item in ipairs(items) do
				if item and item.ID and item.ID > 0 then
					table.insert(validItems, item)
				else
					TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] WARNING: Tab %s skipping invalid item at index %d (ID: %s, Link: %s)",
						tab, i, tostring(item and item.ID or "nil item"), tostring(item and item.Link or "nil"))
				end
			end

			TOGBankClassic_Item:GetItems(validItems, function(list)
				-- Prevent callback from running twice on same scroll container
				if scroll.callbackProcessed then
					TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Ignoring duplicate callback for tab %s", tab)
					return
				end
				scroll.callbackProcessed = true
				self.tabLoaded = true  -- Mark tab as fully loaded
				
				TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Inventory tab %s: GetItems callback received %d items",
					tab, list and #list or 0)
				
				-- Clear previous items before adding new ones
				scroll:ReleaseChildren()
				
					local sortMode = TOGBankClassic_Options and TOGBankClassic_Options.db and TOGBankClassic_Options.db.char.sortMode or "alpha"
				TOGBankClassic_Item:Sort(list, sortMode)

				for _, item in pairs(list) do
					if item and item.Info and item.Info.name then
						TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Inventory tab %s: displaying %s with count %d (ID: %d)",
							tab, item.Info.name, item.Count or 0, item.ID)
					end
					local itemWidget = TOGBankClassic_UI:DrawItem(item, scroll)
					if itemWidget then
						itemWidget:SetCallback("OnClick", function(widget, event)
							if IsShiftKeyDown() or IsControlKeyDown() then
								TOGBankClassic_UI:EventHandler(widget, event)
								return
							end
							TOGBankClassic_UI_Search:ShowRequestDialog(item, tab)
						end)
					end
				end
			end)
		end
	end)

	-- UI-004 fix: Preserve currently selected tab instead of always resetting to first_tab
	-- Only select first_tab if no tab is currently selected
	local currentTab = self.TabGroup.localstatus and self.TabGroup.localstatus.selected
	if currentTab and info.alts[currentTab] then
		-- Don't call SelectTab if it's already the current tab (prevents reload on sync)
		-- The tab is already displayed, no need to trigger OnGroupSelected again
		if self.currentTab ~= currentTab then
			self.TabGroup:SelectTab(currentTab)
		end
	else
		-- No current selection or invalid tab, select first tab
		self.TabGroup:SelectTab(first_tab)
	end
end

function TOGBankClassic_UI_Inventory:GetPercentColor(percent)
	local color = nil
	if percent <= 0.25 then
		color = "ffffffff"
	elseif percent <= 0.5 then
		color = "ff00ff00"
	elseif percent <= 0.75 then
		color = "ffffff00"
	elseif percent <= 0.9 then
		color = "ffff9900"
	elseif percent > 0.9 then
		color = "ffff0000"
	end
	return color
end
