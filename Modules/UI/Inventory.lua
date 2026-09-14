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
	window:SetTitle(TOGBankClassic_UI:WindowTitle())
	window:SetLayout("Flow")
	TOGBankClassic_UI:ApplyThinBorder(window, "inventory")
	-- WINDOW-PERSIST-002: position, size and the resize floor per character, the one spelling every
	-- window uses (UI:PersistWindow -> the library's). This used to open-code the status table and a
	-- SetResizeBounds(500, 500) beside it.
	TOGBankClassic_UI:PersistWindow(window, "inventory", 550, 500, 500, 500)
	--handle keyboard events
	window.frame:EnableKeyboard(true)
	window.frame:SetPropagateKeyboardInput(true)
	window.frame:SetScript("OnKeyDown", function(self, event)
		TOGBankClassic_UI:EventHandler(self, event)
	end)

	self.Window = window
	self.StatusBar = TOGBankClassic_UI_StatusBar:Attach(window)

	-- WINDOW-CHROME-001: the "?" and the gear, the status bar ending at the gear, the hitbox lift --
	-- the shared bottom row (UI:DressWindow). Only the help text is this window's.
	TOGBankClassic_UI:DressWindow(window, {
		settings = TOGBankClassic_UI_Inventory,
		help = function()
			GameTooltip:AddLine("Guild Bank — How It Works")
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("This window shows the combined inventory of all guild banker alts and their mail inventory. Each tab represents one banker character, which is a real in-game character.", 0.9, 0.9, 0.9, true)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("|cffffd100To donate items:|r", 1, 1, 1, false)
			GameTooltip:AddLine("Mail the item using in-game mail directly to the banker character shown in the tab you want to contribute to.", 0.9, 0.9, 0.9, true)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("|cffffd100To request items:|r", 1, 1, 1, false)
			GameTooltip:AddLine("Open the Search window to search for an item, click on it to open the submit request popup and submit the request. Alternatively, you can click on the item directly in the banker tabs to open the request popup. A banker will fulfil it when they are next online and see your request.", 0.9, 0.9, 0.9, true)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("|cffffd100Bankers -- to hide an item from the guild:|r", 1, 1, 1, false)
			GameTooltip:AddLine("On your own tab, right-click an item to hide it. It stays on your tab greyed out with a red mark; to everyone else it is as if you do not have it. Right-click it again to show it.", 0.9, 0.9, 0.9, true)
			TOGBankClassic_UI:AppendGuildHelpNote("inventory")  -- HELPNOTE-001
		end,
	})

	local buttonContainer = TOGBankClassic_UI:Create("SimpleGroup")
	buttonContainer:SetLayout("Table")
	-- Four columns since BROWSE-001: Search | Browse | Sort | Requests.
	buttonContainer:SetUserData("table", {
		columns = {
			{
				width = 0.25,
				align = "start",
			},
			{
				width = 0.20,
				align = "center",
			},
			{
				width = 0.30,
				align = "center",
			},
			{
				width = 0.25,
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

	-- BROWSE-001: the whole bank as one list, in parallel with these tabs.
	local browseButton = TOGBankClassic_UI:Create("Button")
	browseButton:SetText("Browse")
	browseButton:SetCallback("OnClick", function(_)
		TOGBankClassic_UI_Browse:Toggle()
	end)
	browseButton:SetCallback("OnEnter", function()
		GameTooltip:SetOwner(browseButton.frame, "ANCHOR_BOTTOM")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Browse Guild Bank")
		GameTooltip:AddLine("Every banker's items as one sortable list, with filters for type, slot, quality and level across the top, and a Bankers tab showing each bank's status.", 0.9, 0.9, 0.9, true)
		GameTooltip:Show()
	end)
	browseButton:SetCallback("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
	end)
	browseButton:SetWidth(120)
	browseButton:SetHeight(24)
	buttonContainer:AddChild(browseButton)

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
	-- BROWSE-001: the Guild Bank window shows the same data; every "data landed" signal that
	-- repaints these tabs repaints it too, on the same debounce. Fanned out here rather than at
	-- each of the six callers so a seventh cannot forget it.
	local Browse = TOGBankClassic_UI_Browse
	if Browse and Browse.isOpen and not Browse.refreshPending then
		Browse.refreshPending = true
		C_Timer.After(0.5, function()
			Browse.refreshPending = nil
			Browse:Refresh()
		end)
	end
	if not self.isOpen or self.refreshPending then return end
	self.refreshPending = true
	C_Timer.After(0.5, function()
		self.refreshPending = nil
		if self.isOpen then self:DrawContent() end
	end)
end

--- HIDE-001: right click on the banker's own tab. Flips the item's hidden flag, which re-reads and
--- republishes (Bank:SetHidden), then reloads the tab so the row moves between greyed and normal.
--- The tab reload is explicit because DrawContent deliberately does not re-select the current tab
--- (UI-004) -- the contents would otherwise stay as they were until the next tab change.
---@param item table a view row: ID, Suffix, Enchant, Hidden
---@param tab string the tab value (the banker's display name)
function TOGBankClassic_UI_Inventory:ToggleHidden(item, tab)
	if not (item and item.ID) then return end
	local nowHidden = not item.Hidden
	-- HIDE-002: a row the checkbox hid has no manual key to remove; a right click would look like
	-- it did nothing. Say what governs it instead.
	local T = TOGBankClassic_UI.HIDDEN_TEXT   -- HIDDEN-TEXT-001: the same words the Browse tab says
	local name = item.Info and item.Info.name or ("item " .. tostring(item.ID))
	if item.Hidden and TOGBankClassic_Bank:HiddenReason(item.ID, item.Suffix, item.Enchant) == "soulbound" then
		TOGBankClassic_Output:Info(T.noticeSoulbound:format(name))
		return
	end
	if not TOGBankClassic_Bank:SetHidden(item.ID, item.Suffix, item.Enchant, nowHidden) then return end
	TOGBankClassic_Output:Info((nowHidden and T.noticeHidden or T.noticeShown):format(name))
	self:ReloadTab(tab)
end

--- Re-run the current tab's OnGroupSelected so its rows are rebuilt from the store.
function TOGBankClassic_UI_Inventory:ReloadTab(tab)
	if not (self.isOpen and self.TabGroup) then return end
	self.currentTab, self.tabLoaded = nil, false
	self.TabGroup:SelectTab(tab)
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
			-- TAB-STATE-003: grey for a newer copy nobody who can serve us holds; red for the rest.
			local state = TOGBankClassic_Guild:GetAltStaleness(norm)
			local tabText = state == "refused" and ("|cffa0a0a0" .. player .. "|r")
				or IsStale(norm) and ("|cffff0000" .. player .. "|r") or player
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
		local state, heldAt, newestAt, offeredBy, peerVersion = TOGBankClassic_Guild:GetAltStaleness(norm)
		if state == "current" then return end
		GameTooltip:SetOwner(tabBtn, "ANCHOR_TOP")
		if state == "refused" then   -- TAB-STATE-003: the one sentence, Browse's
			GameTooltip:AddLine("|cffa0a0a0Newer Copy Unreachable|r")
			GameTooltip:AddLine(TOGBankClassic_UI_Browse.RefusedText(offeredBy, peerVersion), 1, 1, 1, true)
			GameTooltip:Show()
			return
		end
		GameTooltip:AddLine("|cffff0000Outdated Data|r")
		if state == "behind" and norm == TOGBankClassic_Guild:GetNormalizedPlayer() then
			-- MULTIPC-001: our own bank, and another computer on this account published a later
			-- version than this one holds. Nothing is fetched for our own character; the only way
			-- forward is to re-read every source here, and the gate in Bank:Scan holds publishing
			-- until that has happened.
			GameTooltip:AddLine(string.format("Another computer published a newer copy of this bank %s ago; this computer's copy is from %s.",
				ago(newestAt), heldAt > 0 and (ago(heldAt) .. " ago") or "before that"), 1, 1, 1, true)
			GameTooltip:AddLine("Open your bank on this character (and your mailbox, if this character uses mail) to refresh and republish it. Until then nothing you scan here is sent to the guild.", 0.8, 0.8, 0.8, true)
		elseif state == "behind" then
			GameTooltip:AddLine(string.format("A newer copy of this bank was published %s ago; yours is from %s ago.",
				ago(newestAt), ago(heldAt)), 1, 1, 1, true)
			GameTooltip:AddLine("It is being fetched -- the tab turns yellow when it arrives.", 0.8, 0.8, 0.8, true)
		elseif state == "offered" then   -- TABCOLOUR-003
			GameTooltip:AddLine(string.format("%s says they hold a newer copy of this bank than yours (from %s ago).",
				tostring(offeredBy), ago(heldAt)), 1, 1, 1, true)
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

		TOGBankClassic_UI:ApplyThinScrollbar(scroll)   -- SCROLLBAR-002: in the gap, not over the icons
		g:AddChild(scroll)

		-- The guard against a double-processed callback is this flag on the container itself.
		-- A `local scrollId = tostring(scroll)` sat here describing that job and was never read
		-- by anything; the flag below is, and always was, the whole mechanism.
		scroll.callbackProcessed = false

		local normTab = TOGBankClassic_Guild:NormalizeName(tab)

		-- INV2 step 7a: the aggregate-or-rebuild decision, and the inventoryV2 switch with it,
		-- live in Guild:GetAltItems. This used to open-code both here.
		-- HIDE-001 / HIDDEN-MERGE-001: the banker's OWN tab also shows what they keep from the
		-- guild, greyed, so it can be shown again -- Guild:GetAltItemsWithOwnHidden is the one
		-- place that merge is spelled (the Browse tab reads the same); GetAltItems (Search,
		-- tooltips, TPM) never carries these rows.
		local items = TOGBankClassic_Guild:GetAltItemsWithOwnHidden(normTab)
		local ownTab = normTab == TOGBankClassic_Guild:GetNormalizedPlayer()
			and TOGBankClassic_Guild:IsBank(normTab)
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
						-- HIDE-001: on the banker's own tab the tooltip says what a right click does, and
						-- a hidden row says so first.
						if ownTab then
							-- HIDE-002 / HIDDEN-TEXT-001: the words are UI.HIDDEN_TEXT's, shared with Browse.
							local why = item.Hidden and TOGBankClassic_Bank:HiddenReason(item.ID, item.Suffix, item.Enchant) or nil
							itemWidget.tooltipLines = TOGBankClassic_UI:HiddenTooltipLines(item.Hidden and true or false, why)
						end
						itemWidget:SetCallback("OnClick", function(widget, event, button)
							if button == "RightButton" then
								if ownTab then self:ToggleHidden(item, tab) end
								return
							end
							if IsShiftKeyDown() or IsControlKeyDown() then
								TOGBankClassic_UI:EventHandler(widget, event, button)
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
