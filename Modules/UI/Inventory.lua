TOGBankClassic_UI_Inventory = {}

function TOGBankClassic_UI_Inventory:Init()
	self:DrawWindow()
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

	local buttonContainer = TOGBankClassic_UI:Create("SimpleGroup")
	buttonContainer:SetLayout("Table")
	buttonContainer:SetUserData("table", {
		columns = {
			{
				width = 0.5,
				align = "start",
			},
			{
				width = 0.5,
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
	searchButton:SetWidth(175)
	searchButton:SetHeight(24)
	buttonContainer:AddChild(searchButton)

	local requestsButton = TOGBankClassic_UI:Create("Button")
	requestsButton:SetText("Requests")
	requestsButton:SetCallback("OnClick", function(_)
		TOGBankClassic_UI_Requests:Toggle()
	end)
	requestsButton:SetWidth(175)
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

	-- Build search data only once per data update, not on every refresh (UI-008 fix)
	-- This prevents recursive async item loading that causes C stack overflow
	if not self.searchDataBuilt then
		TOGBankClassic_UI_Search:BuildSearchData()
		self.searchDataBuilt = true
	end

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
		string.format("%s    |c%s%d/%d|r", GetCoinTextureString(total_gold), color, slots, total_slots)
	self.Window:SetStatusText(defaultStatus)
	self.Window:SetCallback("OnEnterStatusBar", function(_)
		local tab = self.TabGroup.localstatus.selected
		local normTab = TOGBankClassic_Guild:NormalizeName(tab)
		local alt = info.alts[normTab]

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
			mailText = string.format("    |cff87ceeb✉ %d item%s%s|r", mailCount, mailCount > 1 and "s" or "", ageText)
		end
		local status = string.format(
			"As of %s    %s    |c%s%d/%d|r%s",
			datetime,
			GetCoinTextureString(money),
			color,
			slot_count,
			slot_total,
			mailText
		)
		self.Window:SetStatusText(status)
	end)
	self.Window:SetCallback("OnLeaveStatusBar", function(_)
		self.Window:SetStatusText(defaultStatus)
	end)

	self.TabGroup:SetCallback("OnGroupSelected", function(group)
		local tab = group.localstatus.selected

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
			local mailItems = {}
			if alt.mail and alt.mail.items then
				for itemID, mailItem in pairs(alt.mail.items) do
					table.insert(mailItems, { ID = itemID, Count = mailItem.count, Link = mailItem.link })
				end
			end
			
			TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Inventory tab %s: computing from sources bank=%d, bags=%d, mail=%d", 
				tab, #bankItems, #bagItems, #mailItems)
			
			local aggregated = TOGBankClassic_Item:Aggregate(bankItems, bagItems)
			aggregated = TOGBankClassic_Item:Aggregate(aggregated, mailItems)
			for _, item in pairs(aggregated) do
				table.insert(items, item)
			end
		end
		
		TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Inventory tab %s: aggregated to %d unique items", 
			tab, #items)
		
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
			
			TOGBankClassic_Item:GetItems(items, function(list)
				TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Inventory tab %s: GetItems callback received %d items", 
					tab, list and #list or 0)
				TOGBankClassic_Item:Sort(list)

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
		-- Preserve current selection if it's still valid
		self.TabGroup:SelectTab(currentTab)
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