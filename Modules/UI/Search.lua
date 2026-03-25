TOGBankClassic_UI_Search = {}

function TOGBankClassic_UI_Search:Init()
	-- Frame creation deferred to first Open() call (PERF-015)
end

local function OnClose(_)
	TOGBankClassic_UI_Search.isOpen = false
	TOGBankClassic_UI_Search.Window:Hide()
	if TOGBankClassic_UI_Search.RequestDialog then
		TOGBankClassic_UI_Search.RequestDialog:Hide()
	end
end

-- Build (once) and show the request dialog for clicking search results
function TOGBankClassic_UI_Search:EnsureRequestDialog()
	if self.RequestDialog then
		return
	end

	local dialog = TOGBankClassic_UI:Create("Frame")
	dialog:Hide()
	dialog:SetTitle("Item Request")
	dialog:SetLayout("List")
	dialog:SetWidth(340)
	dialog:SetHeight(200)
	dialog:EnableResize(false)
	dialog:SetCallback("OnClose", function(widget)
		widget:Hide()
	end)
	dialog.frame:SetAlpha(1)
	TOGBankClassic_UI:ApplyThinBorder(dialog)
	if dialog.frame and dialog.frame.GetChildren then
		for _, child in ipairs({ dialog.frame:GetChildren() }) do
			-- Hide the built-in close button so we only show Send/Cancel actions
			if child.GetText and (child:GetText() == CLOSE or child:GetText() == "Close") then
				child:Hide()
				child:EnableMouse(false)
				break
			end
		end
	end

	local prompt = TOGBankClassic_UI:Create("Label")
	prompt:SetFullWidth(true)
	prompt:SetText("")
	prompt:SetJustifyH("LEFT")
	if prompt.label and prompt.label.SetWordWrap then
		prompt.label:SetWordWrap(true)
	end
	dialog:AddChild(prompt)
	dialog.Prompt = prompt

	local quantityInput = TOGBankClassic_UI:Create("Slider")
	quantityInput:SetLabel("Quantity")
	quantityInput:SetSliderValues(1, 1, 1)
	quantityInput:SetValue(1)
	quantityInput:SetFullWidth(true)
	if quantityInput.editbox and quantityInput.editbox.HookScript then
		quantityInput.editbox:HookScript("OnEnterPressed", function()
			self:SubmitRequest()
		end)
	end
	dialog:AddChild(quantityInput)
	dialog.QuantityInput = quantityInput

	local availableLabel = TOGBankClassic_UI:Create("Label")
	availableLabel:SetFullWidth(true)
	availableLabel:SetJustifyH("LEFT")
	availableLabel:SetText("")
	dialog:AddChild(availableLabel)
	dialog.AvailableLabel = availableLabel

	local buttons = TOGBankClassic_UI:Create("SimpleGroup")
	buttons:SetLayout("Table")
	buttons:SetUserData("table", {
		columns = {
			{ width = 0.5, align = "start" },
			{ width = 0.5, align = "end" },
		},
	})
	buttons:SetFullWidth(true)
	dialog:AddChild(buttons)

	local send = TOGBankClassic_UI:Create("Button")
	send:SetText("Send Request")
	send:SetWidth(140)
	send:SetCallback("OnClick", function()
		self:SubmitRequest()
	end)
	buttons:AddChild(send)

	local cancel = TOGBankClassic_UI:Create("Button")
	cancel:SetText("Cancel")
	cancel:SetWidth(120)
	cancel:SetCallback("OnClick", function()
		dialog:Hide()
	end)
	buttons:AddChild(cancel)

	self.RequestDialog = dialog
end

function TOGBankClassic_UI_Search:ShowRequestDialog(itemEntry, bankAlt)
	if not itemEntry or not itemEntry.Info or not bankAlt then
		return
	end

	self:EnsureRequestDialog()

	local itemName = itemEntry.Info.name or (itemEntry.Link and itemEntry.Link:match("%[(.-)%]")) or "Unknown item"
	self.requestContext = {
		item = itemEntry,
		bank = bankAlt,
		itemName = itemName,
		available = tonumber(itemEntry.Count) or 0,
	}

	local itemLabel = itemEntry.Link or itemName
	local prompt = string.format("Request how many %s from %s?", itemLabel, bankAlt)
	self.RequestDialog.Prompt:SetText(prompt)
	local available = self.requestContext.available

	-- Apply configured percentage limit to available quantity
	local maxRequestPercent = 100
	if TOGBankClassic_Options and TOGBankClassic_Options.GetMaxRequestPercent then
		maxRequestPercent = TOGBankClassic_Options:GetMaxRequestPercent()
	end
	local maxAllowed = math.floor(available * maxRequestPercent / 100)
	-- Always allow at least 1 item if any are available (handles single items like gear)
	if maxAllowed == 0 and available > 0 then
		maxAllowed = 1
	end

	local minQuantity = maxAllowed > 0 and 1 or 0
	local maxQuantity = maxAllowed > 0 and maxAllowed or 0
	if maxQuantity < minQuantity then
		maxQuantity = minQuantity
	end
	self.RequestDialog.QuantityInput:SetSliderValues(minQuantity, maxQuantity, 1)
	self.RequestDialog.QuantityInput:SetValue(minQuantity > 0 and 1 or 0)
	self.RequestDialog.QuantityInput:SetDisabled(maxQuantity == 0)
	if self.RequestDialog.AvailableLabel then
		if maxRequestPercent < 100 then
			self.RequestDialog.AvailableLabel:SetText(string.format("Available: %d (max %d%% = %d)", available, maxRequestPercent, maxAllowed))
		elseif available > 0 then
			self.RequestDialog.AvailableLabel:SetText(string.format("Available: %d", available))
		else
			self.RequestDialog.AvailableLabel:SetText("Available: none right now")
		end
	end
	self.RequestDialog:SetStatusText("")
	if self.Window and self.Window.frame and self.RequestDialog.frame then
		self.RequestDialog.frame:ClearAllPoints()
		self.RequestDialog.frame:SetPoint("TOPRIGHT", self.Window.frame, "TOPLEFT", -10, 0)
	end
	self.RequestDialog:Show()
	-- Ensure dialog stays within screen bounds
	TOGBankClassic_UI:ClampFrameToScreen(self.RequestDialog)
	self.RequestDialog:DoLayout()
	if self.RequestDialog.QuantityInput.editbox and self.RequestDialog.QuantityInput.editbox.SetFocus then
		self.RequestDialog.QuantityInput.editbox:SetFocus()
		self.RequestDialog.QuantityInput.editbox:HighlightText()
	end
end

function TOGBankClassic_UI_Search:SubmitRequest()
	if not self.requestContext or not self.RequestDialog then
		return
	end

	local quantityInput = self.RequestDialog.QuantityInput
	if quantityInput and quantityInput.editbox and quantityInput.editbox.GetText then
		local text = quantityInput.editbox:GetText()
		if text and text ~= "" then
			local typed = tonumber(text) or tonumber(text:match("%d+"))
			if typed then
				local minValue = tonumber(quantityInput.min)
				local maxValue = tonumber(quantityInput.max)
				if minValue and typed < minValue then
					typed = minValue
				end
				if maxValue and typed > maxValue then
					typed = maxValue
				end
				local step = tonumber(quantityInput.step)
				if step and step > 0 and minValue then
					typed = math.floor((typed - minValue) / step + 0.5) * step + minValue
				end
				quantityInput:SetValue(typed)
			end
		end
	end

	local quantity = tonumber(quantityInput and quantityInput:GetValue())
	local available = tonumber(self.requestContext.available) or 0

	-- Apply configured percentage limit to available quantity
	local maxRequestPercent = 100
	if TOGBankClassic_Options and TOGBankClassic_Options.GetMaxRequestPercent then
		maxRequestPercent = TOGBankClassic_Options:GetMaxRequestPercent()
	end
	local maxAllowed = math.floor(available * maxRequestPercent / 100)
	-- Always allow at least 1 item if any are available (handles single items like gear)
	if maxAllowed == 0 and available > 0 then
		maxAllowed = 1
	end

	if not quantity or quantity <= 0 then
		self.RequestDialog:SetStatusText("Enter a quantity greater than 0.")
		return
	end
	if quantity > maxAllowed then
		if maxAllowed <= 0 then
			if maxRequestPercent < 100 then
				self.RequestDialog:SetStatusText(string.format("Cannot request - max allowed is %d%% of %d = 0 items.", maxRequestPercent, available))
			else
				self.RequestDialog:SetStatusText("Cannot request - none available right now.")
			end
			return
		else
			if maxRequestPercent < 100 then
				self.RequestDialog:SetStatusText(string.format("Reduced to max allowed: %d items (%d%% of %d available)", maxAllowed, maxRequestPercent, available))
			else
				self.RequestDialog:SetStatusText(string.format("Reduced to available: %d", maxAllowed))
			end
			quantity = maxAllowed
			-- Don't return - allow the clamped request to proceed
		end
	end

	local requester = TOGBankClassic_Guild:GetNormalizedPlayer()
	if not requester then
		local name, realm = UnitName("player"), GetNormalizedRealmName()
		if name then
			requester = realm and (name .. "-" .. realm) or name
			requester = TOGBankClassic_Guild:NormalizeName(requester)
		end
	end

	local bank = TOGBankClassic_Guild:NormalizeName(self.requestContext.bank)

	local request = {
		date = GetServerTime(),
		requester = requester or "Unknown",
		bank = bank or self.requestContext.bank,
		item = self.requestContext.itemName,
		quantity = quantity,
		fulfilled = 0,
		notes = "",
	}

	if not TOGBankClassic_Guild:AddRequest(request) then
		self.RequestDialog:SetStatusText("Unable to send request.")
		return
	end

	self.RequestDialog:Hide()
	self.requestContext = nil

	TOGBankClassic_Output:Response("Requested %d x %s from %s", quantity, request.item, request.bank)
end

function TOGBankClassic_UI_Search:Toggle()
	if self.isOpen then
		self:Close()
	else
		self:Open()
	end
end

function TOGBankClassic_UI_Search:Open()
	if self.isOpen then
		return
	end
	self.isOpen = true

	if not self.Window then
		self:DrawWindow()
	end

	-- SEARCH-006 FIX: Rebuild search data when guild roster version changes
	-- Track roster version to detect when new data arrives (after /wipe, sync, etc.)
	local currentVersion = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.roster and TOGBankClassic_Guild.Info.roster.version or 0
	local needsRebuild = not self.searchDataBuilt or (self.lastRosterVersion ~= currentVersion)

	if needsRebuild then
		TOGBankClassic_Output:Debug("SEARCH", "Rebuilding search data (version changed: %s -> %s)",
			tostring(self.lastRosterVersion or "nil"), tostring(currentVersion))
		self:BuildSearchData()
		self.searchDataBuilt = true
		self.lastRosterVersion = currentVersion
	end

	self.Window:Show()
	if TOGBankClassic_UI_Inventory.isOpen and TOGBankClassic_UI_Inventory.Window then
		self.Window:ClearAllPoints()
		self.Window:SetPoint("TOPRIGHT", TOGBankClassic_UI_Inventory.Window.frame, "TOPLEFT", 0, 0)
	end

	-- Ensure window stays within screen bounds
	TOGBankClassic_UI:ClampFrameToScreen(self.Window)

	self:DrawContent()

	self.searchField:SetFocus()

	if _G["TOGBankClassic"] then
		_G["TOGBankClassic"]:Show()
	else
		TOGBankClassic_UI:Controller()
	end
end

function TOGBankClassic_UI_Search:Close()
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

function TOGBankClassic_UI_Search:DrawWindow()
	local searchWindow = TOGBankClassic_UI:Create("Frame")
	searchWindow:Hide()
	searchWindow:SetCallback("OnClose", OnClose)
	searchWindow:SetTitle("Search")
	searchWindow:SetLayout("Flow")
	searchWindow:EnableResize(false)
	TOGBankClassic_UI:ApplyThinBorder(searchWindow)
	-- Persist window position/size across reloads
	if TOGBankClassic_Options and TOGBankClassic_Options.db then
		searchWindow:SetStatusTable(TOGBankClassic_Options.db.char.framePositions)
	end
	-- Set width AFTER SetStatusTable to override any saved width
	searchWindow:SetWidth(250)

	self.Window = searchWindow

	local searchInput = TOGBankClassic_UI:Create("EditBox")
	searchInput:SetMaxLetters(50)
	searchInput:SetLabel("Item Name")
	searchInput.label:ClearAllPoints()
	searchInput.label:SetPoint("TOPLEFT", searchInput.frame, "TOPLEFT", 3, -2)
	searchInput.label:SetPoint("TOPRIGHT", searchInput.frame, "TOPRIGHT", 0, -2)
	-- Invisible hit frame over the "Item Name" label (FontString has no mouse events)
	local itemNameLabelHit = CreateFrame("Frame", nil, searchInput.frame)
	itemNameLabelHit:SetPoint("TOPLEFT", searchInput.frame, "TOPLEFT", 3, -2)
	itemNameLabelHit:SetPoint("TOPRIGHT", searchInput.frame, "TOPRIGHT", 0, -2)
	itemNameLabelHit:SetHeight(18)
	itemNameLabelHit:EnableMouse(true)
	itemNameLabelHit:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Search Guild Bank")
		GameTooltip:AddLine("Type at least 3 characters to find items across all banker alts.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("You can also drag an item from your bags into this box to search by item.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Click a result to open the request popup.", 0.9, 0.9, 0.9, true)
		GameTooltip:Show()
	end)
	itemNameLabelHit:SetScript("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
	end)
	searchInput:SetCallback("OnTextChanged", function(input)
		self.SearchText = input:GetText()
		self:DrawContent()
	end)
	searchInput:SetCallback("OnEnterPressed", function(input)
		self.SearchText = input:GetText()
		self:DrawContent()
		self.searchField:ClearFocus()
	end)
	searchInput:SetFullWidth(true)
	searchInput.editbox:SetScript("OnReceiveDrag", function(input)
		local type, _, info = GetCursorInfo()
		if type == "item" then
			self.SearchText = info
			self:DrawContent()
			ClearCursor()
			self.searchField:ClearFocus()
		end
	end)

	self.searchField = searchInput

	searchWindow:AddChild(searchInput)

	local scrollGroup = TOGBankClassic_UI:Create("SimpleGroup")
	scrollGroup:SetLayout("Fill")
	scrollGroup:SetFullWidth(true)
	scrollGroup:SetFullHeight(true)
	searchWindow:AddChild(scrollGroup)

	local resultGroup = TOGBankClassic_UI:Create("ScrollFrame")
	resultGroup:SetLayout("Table")
	resultGroup:SetUserData("table", {
		columns = {
			{
				width = 35,
				align = "middle",
			},
			{
				align = "start",
			},
		},
		spaceH = 30,
	})

	resultGroup.scrollframe:ClearAllPoints()
	resultGroup.scrollframe:SetPoint("TOPLEFT", 10, -10)

	resultGroup.scrollbar:ClearAllPoints()
	resultGroup.scrollbar:SetPoint("TOPLEFT", resultGroup.scrollframe, "TOPRIGHT", -6, -12)
	resultGroup.scrollbar:SetPoint("BOTTOMLEFT", resultGroup.scrollframe, "BOTTOMRIGHT", -6, 22)
	scrollGroup:AddChild(resultGroup)

	self.Results = resultGroup
end

function TOGBankClassic_UI_Search:BuildSearchData()
	TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] BuildSearchData called - clearing and rebuilding search data")
	self.SearchData = {
		Corpus = {},
		Lookup = {},
	}

	local info = TOGBankClassic_Guild.Info
	local roster_alts = TOGBankClassic_Guild:GetRosterAlts()
	if not info or not roster_alts then
		TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] BuildSearchData: no info or roster_alts, returning early")
		return
	end

	local rosterCount = 0
	for _ in pairs(roster_alts) do rosterCount = rosterCount + 1 end
	TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] BuildSearchData: processing %d roster alts", rosterCount)

	local items = {}
	for _, player in pairs(roster_alts) do
		local norm = TOGBankClassic_Guild:NormalizeName(player)
		local alt = info.alts[norm]
		TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Search corpus loop: processing player=%s, norm=%s, has alt=%s",
			player, norm, tostring(alt ~= nil))
		---START CHANGES
		--if alt then
		if alt and type(alt) == "table" then
			---END CHANGES
			-- Use alt.items if available (SYNC-006 aggregated format)
			if alt.items and next(alt.items) ~= nil then
				-- alt.items already includes bank+bags+mail, use it directly
				local beforeCount = #items
				items = TOGBankClassic_Item:Aggregate(items, alt.items)
				local afterCount = #items
				TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Search corpus: using alt.items for %s (%d items before, %d after aggregation)",
					player, beforeCount, afterCount)
			else
				-- Fallback: aggregate from sources for backward compatibility
				if alt.bank then
					items = TOGBankClassic_Item:Aggregate(items, alt.bank.items)
				end
				if alt.bags then
					items = TOGBankClassic_Item:Aggregate(items, alt.bags.items)
				end
				-- MAIL-SYNC: Don't aggregate mail separately - it's already in alt.items
				-- (Mail is aggregated during Bank:Scan into alt.items)
			end
		end
	end

	local itemNames = {}
	local corpusNamesSeen = {}

	-- Count items in hash table (can't use # operator on hash tables)
	local itemCount = 0
	for _ in pairs(items) do itemCount = itemCount + 1 end
	TOGBankClassic_Output:Debug("MAIL", "[SEARCH-DEBUG] About to validate %d items before GetItems", itemCount)

	-- Validate and filter items before passing to GetItems
	local validItems = {}
	local invalidCount = 0
	for key, item in pairs(items) do  -- Use pairs() not ipairs() - items is a hash table
		if item and item.ID and item.ID > 0 then
			table.insert(validItems, item)
		else
			invalidCount = invalidCount + 1
			TOGBankClassic_Output:Debug("MAIL", "[SEARCH-DEBUG] WARNING: Skipping invalid item at key %s (ID: %s, Link: %s)",
				tostring(key), tostring(item and item.ID or "nil item"), tostring(item and item.Link or "nil"))
		end
	end

	TOGBankClassic_Output:Debug("MAIL", "[SEARCH-DEBUG] Passing %d valid items to GetItems (%d invalid skipped)",
		#validItems, invalidCount)

	TOGBankClassic_Item:GetItems(validItems, function(list)
		local listCount = 0
		for _ in pairs(list) do listCount = listCount + 1 end
		TOGBankClassic_Output:Debug("MAIL", "[SEARCH-006] GetItems callback fired with %d items", listCount)
		for _, v in pairs(list) do
			-- Skip malformed list entries
			if v and v.ID and v.Info and v.Info.name then
				-- Map item ID to name (for lookup table building later)
				if not itemNames[v.ID] then
					itemNames[v.ID] = v.Info.name
				end
				-- Only add each unique name to Corpus once
				if not corpusNamesSeen[v.Info.name] then
					corpusNamesSeen[v.Info.name] = true
					table.insert(self.SearchData.Corpus, v.Info.name)
					TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Corpus: added unique name '%s' (ID: %d)", v.Info.name, v.ID)
				else
					TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Corpus: skipping duplicate name '%s' (ID: %d already in corpus)", v.Info.name, v.ID)
				end
			end
		end

		for _, player in pairs(roster_alts) do
			local altItems = {}
			local norm = TOGBankClassic_Guild:NormalizeName(player)
			local alt = info.alts[norm]
			TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Search results loop: processing player=%s, norm=%s, has alt=%s",
				player, norm, tostring(alt ~= nil))
			---START CHANGES
			--if alt then
			if alt and type(alt) == "table" then
				---END CHANGES
				-- Use alt.items if available (SYNC-006 aggregated format)
				if alt.items and next(alt.items) ~= nil then
					-- alt.items already includes bank+bags+mail, use it directly
					for _, item in pairs(alt.items) do
						table.insert(altItems, item)
					end
					TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Search results: using alt.items for %s", player)
				else
					-- Fallback: aggregate from sources for backward compatibility
					if alt.bank then
						altItems = TOGBankClassic_Item:Aggregate(altItems, alt.bank.items)
					end
					if alt.bags then
						altItems = TOGBankClassic_Item:Aggregate(altItems, alt.bags.items)
					end
				-- MAIL-SYNC: Don't aggregate mail separately - it's already in alt.items
				-- (Mail is aggregated during Bank:Scan into alt.items)
				end
			end

			for _, itemEntry in pairs(altItems) do
				local name = itemNames[itemEntry.ID]
				if name then
					TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Search results: adding %s with count %d for player %s to lookup",
						name, itemEntry.Count or 0, player)
					if not self.SearchData.Lookup[name] then
						self.SearchData.Lookup[name] = {}
					end
					local found = false
					for _, existingEntry in pairs(self.SearchData.Lookup[name]) do
						if existingEntry.alt == player and existingEntry.item.ID == itemEntry.ID then
							found = true
							TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Search results: DUPLICATE FOUND - skipping %s (ID: %d) for %s",
								name, itemEntry.ID, player)
							break
						end
					end
					if not found then
						local info = TOGBankClassic_Item:GetInfo(itemEntry.ID, itemEntry.Link)
						table.insert(
							self.SearchData.Lookup[name],
							{
								alt = player,
								item = {
									ID = itemEntry.ID,
									Count = itemEntry.Count,
									Link = itemEntry.Link,
									Info = info,
								},
							}
						)
					end
				end
			end
		end
	end)
end

function TOGBankClassic_UI_Search:DrawContent()
	if not self.Results then
		return
	end

	self.Results:ReleaseChildren()
	self.Window:SetStatusText("")
	self.Results:DoLayout()

	if not self.SearchText then
		return
	end

	--retain search input after close
	if self.SearchText then
		self.searchField:SetText(self.SearchText)
		local searchLength = string.len(self.SearchText)
		self.searchField.editbox:SetCursorPosition(searchLength)
	end

	local search = self.SearchText
	if search and string.sub(search, 0, 2) == "|c" then
		self.searchField:SetText("")
		local item = Item:CreateFromItemLink(search)
		if item and item.itemID then
			-- Item object is valid, safe to use ContinueOnItemLoad
			item:ContinueOnItemLoad(function()
				local name = item:GetItemName()
				if name then
					self.SearchText = name
					self.searchField:SetText(name)
					self:DrawContent()
					self.searchField:ClearFocus()
				end
			end)
		end
		return
	end

	local searchText = search:lower()

	if string.len(searchText) < 3 then
		return
	end

	local searchData = self.SearchData
	if not searchData then
		return
	end

	TOGBankClassic_Output:Debug("MAIL", "[SEARCH-004] Search for '%s': Corpus has %d entries", searchText, #searchData.Corpus)

	local count = 0
	local matchedNames = 0
	for _, v in pairs(searchData.Corpus) do
		if not v then
			-- Skip malformed corpus entries
		else
			local result = string.find(v:lower(), searchText)
			if result ~= nil then
				matchedNames = matchedNames + 1
				TOGBankClassic_Output:Debug("MAIL", "[SEARCH-004] Match #%d: '%s' contains '%s'", matchedNames, v, searchText)
				local lookupList = searchData.Lookup[v]
				if not lookupList then
					-- No lookup for this name; skip
					TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Search display: '%s' matched search but has NO lookup entries", v)
				else
					local lookupCount = 0
					for _ in pairs(lookupList) do lookupCount = lookupCount + 1 end
					TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Search display: '%s' matched search, has %d lookup entries", v, lookupCount)
					for _, vv in pairs(lookupList) do
						--draw item larger to add pading - icon and label smaller by the same to get dimensions
						local resultItem = vv.item
						local bankAlt = vv.alt
						TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Search display: showing %s with %d items for %s",
							resultItem.Info and resultItem.Info.name or "Unknown", resultItem.Count or 0, bankAlt)
					
					-- Draw item with tooltip support (tooltips automatically enabled by DrawItem)
					local itemWidget = TOGBankClassic_UI:DrawItem(resultItem, self.Results, 30, 35, 30, 30, 0, 5)
					if itemWidget then
						itemWidget:SetCallback("OnClick", function(widget, event)
							if IsShiftKeyDown() or IsControlKeyDown() then
								TOGBankClassic_UI:EventHandler(widget, event)
								return
							end
							TOGBankClassic_UI_Search:ShowRequestDialog(resultItem, bankAlt)
						end)
					end
					
					-- Add label showing which bank alt has this item
					local label = TOGBankClassic_UI:Create("Label")
					label:SetText(bankAlt)
					end
				end
			end
		end
	end

	TOGBankClassic_Output:Debug("MAIL", "[SEARCH-004] Search complete: matched %d names, displayed %d result widgets", matchedNames, count)

	local status = count .. " Result"
	if count > 1 then
		status = status .. "s"
	end
	self.Window:SetStatusText(status)

	--redo layout after all items are loaded to get scroll bar to load
	self.Results:DoLayout()
end
