TOGBankClassic_UI_Inventory = {}

local SORT_LIST = {
	alpha       = "A-Z",
	alpha_desc  = "Z-A",
	type        = "By Type",
	level_asc   = "Level (Low to High)",
	level       = "Level (High to Low)",
	rarity      = "Rarity (High to Low)",
	rarity_asc  = "Rarity (Low to High)",
}
local SORT_ORDER = { "alpha", "alpha_desc", "type", "level_asc", "level", "rarity", "rarity_asc" }

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
	local version = GetAddOnMetadata("TOGBankClassic", "Version") or "?"
	window:SetTitle("TOGBankClassic v" .. version)
	window:SetLayout("Flow")
	TOGBankClassic_UI:ApplyThinBorder(window, "inventory")
	-- Persist window position/size across reloads (each window gets its own sub-table)
	if TOGBankClassic_Options and TOGBankClassic_Options.db then
		local positions = TOGBankClassic_Options.db.char.framePositions
		positions.inventory = positions.inventory or { width = 550, height = 500 }
		window:SetStatusTable(positions.inventory)
	end
	--handle keyboard events
	window.frame:SetResizeBounds(500, 500)
	window.frame:EnableKeyboard(true)
	window.frame:SetPropagateKeyboardInput(true)
	window.frame:SetScript("OnKeyDown", function(self, event)
		TOGBankClassic_UI:EventHandler(self, event)
	end)

	self.Window = window
	self.StatusBar = TOGBankClassic_UI_StatusBar:Attach(window)

	-- Shrink status bar right edge to make room for the help and settings icons.
	-- Layout (right to left): [Close button] [Help "?" icon @ -133] [Gear icon @ -165] [Status bar ending at -195]
	local statusbg = window.statustext:GetParent()
	statusbg:ClearAllPoints()
	statusbg:SetPoint("BOTTOMLEFT",  window.frame, "BOTTOMLEFT",  15, 15)
	statusbg:SetPoint("BOTTOMRIGHT", window.frame, "BOTTOMRIGHT", -195, 15)

	-- Help "?" icon — sits in the gap between the status bar and the close button
	local helpIcon = CreateFrame("Frame", nil, window.frame)
	helpIcon:SetSize(24, 24)
	helpIcon:SetPoint("BOTTOMRIGHT", window.frame, "BOTTOMRIGHT", -133, 15)
	helpIcon:EnableMouse(true)
	-- HITBOX-001: lift above AceGUI's mouse-enabled bottom resize strip (sizer_s,
	-- level 101) so the whole icon takes clicks/hover instead of a center sliver.
	helpIcon:SetFrameLevel(window.frame:GetFrameLevel() + 10)
	local helpTex = helpIcon:CreateTexture(nil, "OVERLAY")
	helpTex:SetAllPoints(helpIcon)
	helpTex:SetTexture("Interface\\Common\\help-i")
	helpIcon:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Guild Bank — How It Works")
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("This window shows the combined inventory of all guild banker alts and their mail inventory. Each tab represents one banker character, which is a real in-game character.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100To donate items:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Mail the item using in-game mail directly to the banker character shown in the tab you want to contribute to.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100To request items:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Open the Search window to search for an item, click on it to open the submit request popup and submit the request. Alternatively, you can click on the item directly in the banker tabs to open the request popup. A banker will fulfil it when they are next online and see your request.", 0.9, 0.9, 0.9, true)
		TOGBankClassic_UI:AppendGuildHelpNote("inventory")  -- HELPNOTE-001
		GameTooltip:Show()
	end)
	helpIcon:SetScript("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
	end)

	-- Gear icon — opens TOGBankClassic settings (Escape → Options → AddOns → TOGBankClassic).
	-- 20x20 to match FastGuildInvite's settings gear (same project author, same visual feel).
	-- Bottom-anchor offset +17 (vs help icon's +15) so the gear's vertical centre lines up with
	-- the help icon's (help is 24x24 → centre y=27; gear is 20x20 → bottom 17 + 10 = centre 27).
	-- Texture pattern matches FGI: the Trade_Engineering icon looks like a gear, but Blizzard's
	-- icon files ship with ~8% transparent padding on each edge; cropping the TexCoord to
	-- (0.08-0.92) makes the visible gear fill the button instead of looking floaty in the middle.
	local settingsIcon = CreateFrame("Button", nil, window.frame)
	settingsIcon:SetSize(20, 20)
	settingsIcon:SetPoint("BOTTOMRIGHT", window.frame, "BOTTOMRIGHT", -165, 17)
	settingsIcon:EnableMouse(true)
	settingsIcon:SetFrameLevel(window.frame:GetFrameLevel() + 10)  -- HITBOX-001
	settingsIcon:SetNormalTexture("Interface\\Icons\\Trade_Engineering")
	settingsIcon:SetPushedTexture("Interface\\Icons\\Trade_Engineering")
	local gearNormal = settingsIcon:GetNormalTexture()
	if gearNormal then gearNormal:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
	local gearPushed = settingsIcon:GetPushedTexture()
	if gearPushed then
		gearPushed:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		gearPushed:SetVertexColor(0.7, 0.7, 0.7)
	end
	-- Expand the click hit-rect 2px beyond the visible button so the click target
	-- matches the larger feel a player expects from a 24px-wide icon.
	settingsIcon:SetHitRectInsets(-2, -2, -2, -2)
	settingsIcon:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	settingsIcon:SetScript("OnClick", function()
		if not (TOGBankClassic_Options and TOGBankClassic_Options.Open) then return end
		-- Blizzard's Settings panel takes focus when it opens and (depending on WoW
		-- version) can hide other top-level frames. Our inventory is registered in
		-- UISpecialFrames, so a focus-grab can propagate through the controller's
		-- OnHide and close it. We don't want that — the user wants to return to the
		-- inventory after closing Settings. So: remember whether the inventory was
		-- open BEFORE opening Settings, and if it got closed by the focus change,
		-- restore it on the next frame. If Settings doesn't close it, this is a no-op.
		local wasOpen = TOGBankClassic_UI_Inventory.isOpen
		TOGBankClassic_Options:Open()
		if wasOpen then
			C_Timer.After(0, function()
				if not TOGBankClassic_UI_Inventory.isOpen then
					TOGBankClassic_UI_Inventory:Open()
				end
			end)
		end
	end)
	settingsIcon:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("TOGBankClassic Settings")
		GameTooltip:AddLine("Open the addon options panel (banker/scan configuration, debug logging, minimap button, etc.).", 0.9, 0.9, 0.9, true)
		GameTooltip:Show()
	end)
	settingsIcon:SetScript("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
	end)

	-- HITBOX-001: re-assert the bottom-row lift on every show so the whole icon (and the
	-- AceGUI Close button) stays clickable, not just its top half. See KeepAboveResizeSizers.
	TOGBankClassic_UI:KeepAboveResizeSizers(window, { helpIcon, settingsIcon })

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
	buttonContainer.frame:ClearAllPoints()
	buttonContainer.content:SetPoint("TOPLEFT", 0, 5)
	buttonContainer.content:SetPoint("BOTTOMRIGHT", 0, -5)
	window:AddChild(buttonContainer)

	local searchButton = TOGBankClassic_UI:Create("Button")
	searchButton:SetText("Search")
	searchButton:SetCallback("OnClick", function(_)
		TOGBankClassic_UI_Search:Toggle()
	end)
	searchButton:SetCallback("OnEnter", function()
		GameTooltip:SetOwner(searchButton.frame, "ANCHOR_BOTTOM")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Search Guild Bank")
		GameTooltip:AddLine("Find items across all banker alts by name. Click an item in the results to submit a request.", 0.9, 0.9, 0.9, true)
		GameTooltip:Show()
	end)
	searchButton:SetCallback("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
	end)
	searchButton:SetWidth(160)
	searchButton:SetHeight(24)
	buttonContainer:AddChild(searchButton)

	local sortDropdown = TOGBankClassic_UI:Create("Dropdown")
	sortDropdown:SetLabel("")
	sortDropdown.label:Hide()  -- Hide the label completely
	local initMode = (TOGBankClassic_Options and TOGBankClassic_Options.db and TOGBankClassic_Options.db.char.sortMode) or "alpha"
	sortDropdown:SetList(SORT_LIST, SORT_ORDER)
	sortDropdown:SetValue(initMode)
	sortDropdown:SetWidth(200)
	-- Adjust internal dropdown structure to align with buttons
	if sortDropdown.dropdown then
		sortDropdown.dropdown:ClearAllPoints()
		sortDropdown.dropdown:SetPoint("TOPLEFT", sortDropdown.frame, "TOPLEFT", 0, 0)
		sortDropdown.dropdown:SetPoint("BOTTOMRIGHT", sortDropdown.frame, "BOTTOMRIGHT", 0, 0)
	end
	sortDropdown:SetCallback("OnValueChanged", function(_, _, value)
		local db = TOGBankClassic_Options and TOGBankClassic_Options.db and TOGBankClassic_Options.db.char
		if not db then return end
		db.sortMode = value
		-- Reload current tab with new sort order
		local tab = self.TabGroup.localstatus and self.TabGroup.localstatus.selected
		if tab then
			self.currentTab = nil
			self.tabLoaded = false
			self.TabGroup:SelectTab(tab)
		end
	end)
	sortDropdown:SetCallback("OnEnter", function()
		GameTooltip:SetOwner(sortDropdown.frame, "ANCHOR_BOTTOM")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Sort Order")
		GameTooltip:AddLine("Choose how to sort items in this character's inventory.", 0.9, 0.9, 0.9, true)
		GameTooltip:Show()
	end)
	sortDropdown:SetCallback("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
	end)
	self.SortDropdown = sortDropdown
	buttonContainer:AddChild(sortDropdown)

	local requestsButton = TOGBankClassic_UI:Create("Button")
	requestsButton:SetText("Requests")
	requestsButton:SetCallback("OnClick", function(_)
		TOGBankClassic_UI_Requests:Toggle()
	end)
	requestsButton:SetCallback("OnEnter", function()
		GameTooltip:SetOwner(requestsButton.frame, "ANCHOR_BOTTOM")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Guild Requests")
		GameTooltip:AddLine("View and manage guild bank item requests. Bankers can fulfil or cancel requests from here.", 0.9, 0.9, 0.9, true)
		GameTooltip:Show()
	end)
	requestsButton:SetCallback("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
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

--- Repaint the tab colours shortly, coalescing a burst of deliveries into one redraw.
---
--- TABCOLOUR-001: the tabs were redrawn at the two places NEW HASHES arrive (a hash-list batch,
--- a P2P dispatch) -- the moments a tab is about to turn red -- and nowhere that DATA arrives, so
--- a tab stayed red after its bank contents had landed until some later broadcast happened to
--- repaint it. Reported from a live guild: two bankers received in full, still red. Debounced
--- because several peers relay the same alts within the same second and each delivery would
--- otherwise rebuild the tab strip and status bar.
function TOGBankClassic_UI_Inventory:RefreshSoon()
	if not self.isOpen or self.refreshPending then return end
	self.refreshPending = true
	C_Timer.After(0.5, function()
		self.refreshPending = nil
		if self.isOpen then self:DrawContent() end
	end)
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

	-- Sync sort dropdown value with persisted mode (db available by the time DrawContent runs)
	if self.SortDropdown and TOGBankClassic_Options and TOGBankClassic_Options.db then
		local m = TOGBankClassic_Options.db.char.sortMode or "alpha"
		self.SortDropdown:SetValue(m)
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

	-- TABCOLOUR-002: red is decided by Guild:GetAltStaleness -- "v1 is always red, v2 does it by
	-- is someone newer" -- not by the sync layer's hash-equality question, which is what made the
	-- tabs take minutes to settle and paint current bankers red.
	local function IsStale(norm)
		local state = TOGBankClassic_Guild:GetAltStaleness(norm)
		return state ~= "current"
	end

	local tabs = {}
	local first_tab = nil
	local i = 1
	for _, player in pairs(players) do
		local norm = TOGBankClassic_Guild:NormalizeName(player)
		local alt = info.alts[norm]
		if alt and type(alt) == "table" then
			if not first_tab then
				first_tab = player
			end
			local tabText = IsStale(norm) and ("|cffff0000" .. player .. "|r") or player
			tabs[i] = { value = player, text = tabText }
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

	-- TABCOLOUR-002: the tooltip says WHICH kind of red this is, with the two publish times when it
	-- has them, so a banker can tell "I need to open my bank" from "a newer copy is on its way".
	local function ago(at)
		local diff = (GetServerTime() or 0) - (tonumber(at) or 0)
		if diff < 0 then diff = 0 end
		return SecondsToTime(diff)
	end
	self.TabGroup:SetCallback("OnTabEnter", function(_, _, value, tabBtn)
		local norm = TOGBankClassic_Guild:NormalizeName(value)
		local state, heldAt, newestAt = TOGBankClassic_Guild:GetAltStaleness(norm)
		if state == "current" then return end
		GameTooltip:SetOwner(tabBtn, "ANCHOR_TOP")
		GameTooltip:AddLine("|cffff0000Outdated Data|r")
		if state == "behind" then
			GameTooltip:AddLine(string.format("A newer copy of this bank was published %s ago; yours is from %s ago.",
				ago(newestAt), ago(heldAt)), 1, 1, 1, true)
			GameTooltip:AddLine("It is being fetched -- the tab turns yellow when it arrives.", 0.8, 0.8, 0.8, true)
		elseif state == "v1" then
			if norm == TOGBankClassic_Guild:GetNormalizedPlayer() then
				GameTooltip:AddLine("Your own bank has not been published in the current format yet. Open your bank once to publish it.", 1, 1, 1, true)
			else
				GameTooltip:AddLine("This copy predates the current format. It stays red until the banker opens their bank on the new version.", 1, 1, 1, true)
			end
		else -- "none"
			GameTooltip:AddLine("No contents held for this banker yet.", 1, 1, 1, true)
		end
		GameTooltip:AddLine("What you're seeing may not reflect current availability.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	self.TabGroup:SetCallback("OnTabLeave", function()
		GameTooltip:Hide()
	end)

	self.StatusBar:Draw(info, roster_alts, self.TabGroup)

	self.TabGroup:SetCallback("OnGroupSelected", function(group)
		local tab = group.localstatus.selected

		-- Prevent processing the same tab multiple times
		if self.currentTab == tab and self.tabLoaded then
			TOGBankClassic_Output:Debug("MAIL", "SCAN", "[RACE-CONDITION] BLOCKED duplicate OnGroupSelected for tab %s - something is triggering tab reload!", tab)
			-- Print stack trace to see what's calling this
			local stack = debugstack(2)
			TOGBankClassic_Output:Debug("MAIL", "SCAN", "[RACE-CONDITION] Stack trace:\n%s", stack)
			return
		end
		self.currentTab = tab
		self.tabLoaded = false  -- Will be set to true after GetItems completes

		TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Loading tab %s", tab)

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

		-- Apply thin scrollbar style to match dropdown scrollbars
		if scroll.scrollbar then
			scroll.scrollbar:ClearAllPoints()
			scroll.scrollbar:SetPoint("TOPRIGHT", scroll.scrollframe, "TOPRIGHT", 0, -20)
			scroll.scrollbar:SetPoint("BOTTOMRIGHT", scroll.scrollframe, "BOTTOMRIGHT", 0, 20)
			scroll.scrollbar:SetWidth(8)
			scroll.scrollbar:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Vertical")
		end
		g:AddChild(scroll)

		-- The guard against a double-processed callback is this flag on the container itself.
		-- A `local scrollId = tostring(scroll)` sat here describing that job and was never read
		-- by anything; the flag below is, and always was, the whole mechanism.
		scroll.callbackProcessed = false

		local normTab = TOGBankClassic_Guild:NormalizeName(tab)

		-- INV2 step 7a: the aggregate-or-rebuild decision, and the inventoryV2 switch with it,
		-- live in Guild:GetAltItems. This used to open-code both here.
		local items = TOGBankClassic_Guild:GetAltItems(normTab)
		TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Inventory tab %s: aggregated to %d unique items",
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
					TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] DUPLICATE ITEM ID %d found with %d different entries:", itemID, #entries)
					for i, entry in ipairs(entries) do
						TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002]   Entry %d: Count=%d, Link=%s", i, entry.Count, entry.Link or "nil")
					end
				end
			end

			-- Validate and filter items before passing to GetItems
			local validItems = {}
			for i, item in ipairs(items) do
				if item and item.ID and item.ID > 0 then
					table.insert(validItems, item)
				else
					TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] WARNING: Tab %s skipping invalid item at index %d (ID: %s, Link: %s)",
						tab, i, tostring(item and item.ID or "nil item"), tostring(item and item.Link or "nil"))
				end
			end

			TOGBankClassic_Item:GetItems(validItems, function(list)
				-- Prevent callback from running twice on same scroll container
				if scroll.callbackProcessed then
					TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Ignoring duplicate callback for tab %s", tab)
					return
				end
				scroll.callbackProcessed = true
				self.tabLoaded = true  -- Mark tab as fully loaded

				TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Inventory tab %s: GetItems callback received %d items",
					tab, list and #list or 0)

				-- Clear previous items before adding new ones
				scroll:ReleaseChildren()

					local sortMode = TOGBankClassic_Options and TOGBankClassic_Options.db and TOGBankClassic_Options.db.char.sortMode or "alpha"
				TOGBankClassic_Item:Sort(list, sortMode)

				for _, item in pairs(list) do
					if item and item.Info and item.Info.name then
					TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Inventory tab %s: displaying %s with count %d (ID: %d)",
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
		else
			-- SCAN-001: with no items there is no GetItems callback to release the loading
			-- label, so it used to sit on "Loading items..." forever and read as a hang
			-- rather than an empty record. Say what is actually true and how to fix it.
			scroll:ReleaseChildren()
			self.tabLoaded = true

			local emptyLabel = TOGBankClassic_UI:Create("Label")
			emptyLabel:SetFullWidth(true)
			if TOGBankClassic_Guild:NormalizeName(tab) == TOGBankClassic_Guild:GetNormalizedPlayer() then
				-- Own character: nothing has been scanned into the DB yet.
				emptyLabel:SetText("|cff808080No items recorded yet. Open and close your bank, "
					.. "or type |r|cffe6cc80/togbank share|r|cff808080 to scan your bags now.|r")
			else
				emptyLabel:SetText("|cff808080No items recorded for this character yet "
					.. "- waiting for them to share their inventory.|r")
			end
			scroll:AddChild(emptyLabel)
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
