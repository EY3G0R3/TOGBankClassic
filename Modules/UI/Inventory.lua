TOGBankClassic_UI_Inventory = {}

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
	self.StatusBar = TOGBankClassic_StatusBar:Attach(window)

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

	self.StatusBar:Draw(info, roster_alts, self.TabGroup)

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
