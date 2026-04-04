-- ItemHighlight.lua - Highlight items needed for pending orders
-- Greys out all items except those needed to fulfill active requests

TOGBankClassic_ItemHighlight = {}
local ItemHighlight = TOGBankClassic_ItemHighlight

-- State
ItemHighlight.enabled = false
ItemHighlight.neededItems = {}   -- {itemName: quantityNeeded} — legacy requests (no itemID) and Bagnon search
ItemHighlight.neededItemIDs = {} -- {itemID: quantityNeeded} — new requests with explicit itemID
ItemHighlight.overlays = {} -- Texture overlays for dimming items
ItemHighlight.lastBagnonSearch = nil -- Cache last Bagnon search string to avoid redundant signals

-- Settings
-- Throttling to prevent Bagnon execution timeout
local REFRESH_THROTTLE = 0.5 -- seconds
local lastRefresh = 0
local pendingRefresh = false
local eventFrame = nil -- Frame for event handling
local eventsRegistered = false -- Track if BAG_UPDATE events are registered

-- Register BAG_UPDATE events (called when highlighting is enabled)
local function registerBagEvents()
	if eventsRegistered then
		return
	end

	eventFrame = CreateFrame("Frame")
	---@diagnostic disable-next-line: undefined-field
	eventFrame:RegisterEvent("BAG_UPDATE")
	---@diagnostic disable-next-line: undefined-field
	eventFrame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
	---@diagnostic disable-next-line: undefined-field
	eventFrame:RegisterEvent("BANKFRAME_OPENED")
	---@diagnostic disable-next-line: undefined-field
	eventFrame:RegisterEvent("BANKFRAME_CLOSED")
	---@diagnostic disable-next-line: undefined-field
	eventFrame:SetScript("OnEvent", function(_, event, ...)
		-- Only process if highlighting is enabled
		if ItemHighlight.enabled then
			-- Throttle refresh to prevent Bagnon execution timeout during rapid BAG_UPDATE spam
			-- ALWAYS delay the refresh to ensure minimum time between Bagnon signal calls
			local now = GetTime()

			-- Schedule delayed refresh if not already pending
			if not pendingRefresh then
				local delay = math.max(0, REFRESH_THROTTLE - (now - lastRefresh))
				pendingRefresh = true
				C_Timer.After(delay, function()
					pendingRefresh = false
					if ItemHighlight.enabled then
						lastRefresh = GetTime()
						ItemHighlight:RefreshHighlighting()
					end
				end)
			end
		end
	end)

	eventsRegistered = true
	TOGBankClassic_Output:Debug("REQUESTS", "ItemHighlight: BAG_UPDATE events registered")
end

-- Unregister BAG_UPDATE events (called when highlighting is disabled)
local function unregisterBagEvents()
	if not eventsRegistered then
		return
	end

	if eventFrame then
		eventFrame:UnregisterAllEvents()
		eventFrame:SetScript("OnEvent", nil)
		eventFrame = nil
	end

	eventsRegistered = false
	TOGBankClassic_Output:Debug("REQUESTS", "ItemHighlight: BAG_UPDATE events unregistered")
end

-- Initialize the module
function ItemHighlight:Initialize()
	-- Don't auto-enable from saved settings - let the checkbox control it
	self.enabled = false

	-- No events registered at initialization - they'll be registered when highlighting is enabled
	TOGBankClassic_Output:Debug("REQUESTS", "INIT", "ItemHighlight: initialized (events will be registered when enabled)")
end

-- Enable/disable highlighting
function ItemHighlight:SetEnabled(enabled)
	-- Check if player is a banker
	local banks = TOGBankClassic_Guild:GetBanks()
	if not banks then
		TOGBankClassic_Output:Debug("REQUESTS", "Highlighting unavailable: guild data not loaded")
		return
	end

	local currentPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()
	local isBank = false
	for _, bankName in ipairs(banks) do
		local normBank = TOGBankClassic_Guild:NormalizeName(bankName)
		if normBank == currentPlayer then
			isBank = true
			break
		end
	end

	if not isBank then
		TOGBankClassic_Output:Debug("REQUESTS", "Highlighting disabled: not a banker")
		return
	end

	self.enabled = enabled

	-- Save to settings
	if not TOGBankClassicDB.settings then
		TOGBankClassicDB.settings = {}
	end
	TOGBankClassicDB.settings.highlightEnabled = enabled

	if enabled then
		-- Register BAG_UPDATE events when enabling highlighting
		registerBagEvents()
		self:RefreshHighlighting()
	else
		self:ClearAllOverlays()
		-- Clear Bagnon search when disabling (only if it was previously set)
		if Bagnon and self.lastBagnonSearch ~= nil then
			self.lastBagnonSearch = nil
			local addon = Bagnon
			addon.search = nil
			addon.canSearch = false
			addon:SendSignal('SEARCH_CHANGED')
		end
		-- Unregister BAG_UPDATE events when disabling highlighting
		unregisterBagEvents()
	end
end

-- Build table of needed items from all pending requests
function ItemHighlight:BuildNeededItemsList()
	local info = TOGBankClassic_Guild.Info
	if not info or not info.requests then
		return false
	end

	-- Clear and rebuild
	self.neededItems = {}
	self.neededItemIDs = {}

	-- Get current banker from Requests UI filter
	local currentBanker = TOGBankClassic_UI_Requests.bankFilter
	local currentPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()

	-- If no filter set, default to current player if they're a banker
	if not currentBanker or currentBanker == "__tog_any__" then
		if currentPlayer and TOGBankClassic_Guild:IsBank(currentPlayer) then
			currentBanker = currentPlayer
		else
			return false
		end
	end

	-- Aggregate quantities from all pending requests for this banker
	-- Use pairs() since requests is now a map keyed by ID, not an array
	for _, request in pairs(info.requests or {}) do
		if request.bank == currentBanker
			and request.status ~= "complete"
			and request.status ~= "fulfilled"
			and request.status ~= "cancelled" then

			local itemName = request.item
			local qtyNeeded = (request.quantity or 0) - (request.fulfilled or 0)

			if qtyNeeded > 0 then
				if request.itemID then
					-- New request: key by numeric ID for precise variant matching
					self.neededItemIDs[request.itemID] = (self.neededItemIDs[request.itemID] or 0) + qtyNeeded
				else
					-- Legacy request: key by name (existing behaviour)
					self.neededItems[itemName] = (self.neededItems[itemName] or 0) + qtyNeeded
				end
			end
		end
	end

	local uniqueCount = 0
	for _ in pairs(self.neededItems) do uniqueCount = uniqueCount + 1 end
	TOGBankClassic_Output:Debug("REQUESTS", "Built needed items list: %d unique items", uniqueCount)

	return true
end

-- Check if an item is needed.
-- When itemID is provided, ID-based matching is used (precise; handles same-name variants).
-- Falls back to name-based matching for legacy requests that lack an itemID.
function ItemHighlight:IsItemNeeded(itemName, itemID)
	if itemID then
		if self.neededItemIDs[itemID] then return true end
		-- ID not in the ID table; still check legacy name table in case an old
		-- request for the same item exists without an ID.
		return itemName and self.neededItems[itemName] ~= nil
	end
	if not itemName then return false end
	return self.neededItems[itemName] ~= nil
end

-- Apply grey desaturation to a button
function ItemHighlight:ApplyOverlay(button)
	if not button or not button:IsVisible() then
		return
	end
	-- Get the icon texture (works for both default and Bagnon buttons)
	local icon = button.icon or button.Icon or _G[button:GetName().."IconTexture"]
	if icon then
		-- Grey out by reducing color saturation (use very dark grey)
		icon:SetVertexColor(0.2, 0.2, 0.2)
	end
	self.overlays[button:GetName() or tostring(button)] = true
end

-- Remove grey desaturation from a button
function ItemHighlight:RemoveOverlay(button)
	if not button then return end
	local buttonName = button:GetName()
	-- Reset texture color to normal (FULL COLOR)
	local icon = button.icon or button.Icon or _G[buttonName.."IconTexture"]
	if icon then
		icon:SetVertexColor(1, 1, 1)
	end
	self.overlays[buttonName or tostring(button)] = nil
end

-- Clear all overlays
function ItemHighlight:ClearAllOverlays()
	for buttonKey, _ in pairs(self.overlays) do
		local button = _G[buttonKey] or buttonKey
		if type(button) ~= "string" then
			self:RemoveOverlay(button)
		end
	end
	self.overlays = {}
end

-- Update highlighting for bag slots
function ItemHighlight:UpdateBagHighlighting()
	TOGBankClassic_Output:Debug("REQUESTS", "UpdateBagHighlighting called")
	-- Try Bagnon first
	local bagnonWorked = self:UpdateBagnonHighlighting()
	if bagnonWorked then
		TOGBankClassic_Output:Debug("REQUESTS", "Using Bagnon highlighting")
		return
	end
	-- Fall back to default bags ONLY if Bagnon didn't work
	TOGBankClassic_Output:Debug("REQUESTS", "Falling back to default bag highlighting")
	self:UpdateDefaultBagHighlighting()
end

-- Update highlighting for Bagnon bags
function ItemHighlight:UpdateBagnonHighlighting()
	-- Check if Bagnon addon is loaded
	if not Bagnon and not BagBrother then
		TOGBankClassic_Output:Debug("REQUESTS", "Bagnon not found")
		return false
	end

	TOGBankClassic_Output:Debug("REQUESTS", "Bagnon found, building search string")

	-- Build search string from needed items
	-- Bagnon search is case-insensitive and matches partial names
	-- Use | as OR operator to match any of the item names
	local searchTerms = {}
	local seenNames = {}
	for itemName, _ in pairs(self.neededItems) do
		seenNames[itemName] = true
		local cleanName = itemName:gsub("^Formula: ", "")
		cleanName = cleanName:gsub("^Pattern: ", "")
		cleanName = cleanName:gsub("^Recipe: ", "")
		cleanName = cleanName:gsub("^Plans: ", "")
		cleanName = cleanName:gsub("^Schematic: ", "")
		cleanName = cleanName:gsub("^Design: ", "")
		cleanName = cleanName:gsub("^Manual: ", "")
		table.insert(searchTerms, cleanName)
	end
	-- Include names for ID-keyed entries (from new requests with itemID)
	for itemID, _ in pairs(self.neededItemIDs) do
		local name = C_Item.GetItemNameByID(itemID)
		if name and not seenNames[name] then
			seenNames[name] = true
			table.insert(searchTerms, name)
		end
	end

	if #searchTerms == 0 then
		TOGBankClassic_Output:Debug("REQUESTS", "No items to search for")
		return false
	end

	-- Limit to 20 items max to prevent Bagnon timeout with complex search strings
	local MAX_SEARCH_ITEMS = 20
	if #searchTerms > MAX_SEARCH_ITEMS then
		TOGBankClassic_Output:Debug("REQUESTS", "Too many items (%d), limiting to %d", #searchTerms, MAX_SEARCH_ITEMS)
		local limited = {}
		for i = 1, MAX_SEARCH_ITEMS do
			limited[i] = searchTerms[i]
		end
		searchTerms = limited
	end

	-- Join with | (OR operator) so Bagnon matches items containing ANY of these names
	local searchString = table.concat(searchTerms, "|")

	-- Only trigger SEARCH_CHANGED if the search string actually changed
	-- This prevents redundant Bagnon UI rebuilds that can cause execution timeout
	if self.lastBagnonSearch == searchString then
		TOGBankClassic_Output:Debug("REQUESTS", "Search string unchanged, skipping SEARCH_CHANGED signal")
		return true
	end

	self.lastBagnonSearch = searchString
	TOGBankClassic_Output:Debug("REQUESTS", "Setting Bagnon search (%d items): %s", #searchTerms, searchString)

	-- Set Bagnon's search string (use whichever global is available)
	local addon = Bagnon or BagBrother
	if addon.sets then
		addon.sets.search = searchString
	end
	addon.search = searchString
	addon.canSearch = true

	-- Trigger search update
	addon:SendSignal('SEARCH_CHANGED')
	TOGBankClassic_Output:Debug("REQUESTS", "Sent SEARCH_CHANGED signal")

	return true
end

-- Update highlighting for default WoW bags
function ItemHighlight:UpdateDefaultBagHighlighting()
	-- Iterate through all bags
	for bag = 0, 4 do
		local containerID = (bag == 0) and 1 or (bag + 1)
		local numSlots = C_Container.GetContainerNumSlots(bag)

		-- Iterate through API slot numbers (1 to numSlots)
		for apiSlot = 1, numSlots do
			-- WoW bag buttons are ordered OPPOSITE of API slots
			-- API slot 1 = button slot numSlots, API slot 2 = button slot numSlots-1, etc.
			local buttonSlot = numSlots - apiSlot + 1
			local buttonName = string.format("ContainerFrame%dItem%d", containerID, buttonSlot)
			local button = _G[buttonName]
			if button then
				local itemInfo = C_Container.GetContainerItemInfo(bag, apiSlot)
				if itemInfo then
					local itemName = C_Item.GetItemNameByID(itemInfo.itemID)
					if not self:IsItemNeeded(itemName, itemInfo.itemID) then
						-- Item not needed - grey it out
						self:ApplyOverlay(button)
					end
				end
			end
		end
	end
end

-- Update highlighting for bank slots
function ItemHighlight:UpdateBankHighlighting()
	if not BankFrame or not BankFrame:IsVisible() then return end

	-- Bank slots (1-28)
	for slot = 1, 28 do
		local itemInfo = C_Container.GetContainerItemInfo(-1, slot)
		if itemInfo then
			local itemName = C_Item.GetItemNameByID(itemInfo.itemID)
			local button = self:GetBankSlotButton(slot)
			if button then
				if self:IsItemNeeded(itemName, itemInfo.itemID) then
					self:RemoveOverlay(button)
				else
					self:ApplyOverlay(button)
				end
			end
		end
	end
	-- Bank bag slots (5-11)
	for bag = 5, 11 do
		local numSlots = C_Container.GetContainerNumSlots(bag)
		for slot = 1, numSlots do
			local itemInfo = C_Container.GetContainerItemInfo(bag, slot)
			if itemInfo then
				local itemName = C_Item.GetItemNameByID(itemInfo.itemID)
				local button = self:GetBagSlotButton(bag, slot)
				if button then
					if self:IsItemNeeded(itemName, itemInfo.itemID) then
						self:RemoveOverlay(button)
					else
						self:ApplyOverlay(button)
					end
				end
			end
		end
	end
end

-- Get button frame for a bag slot
function ItemHighlight:GetBagSlotButton(bag, slot)
	-- Classic Era uses direct frame names
	-- Bag 0 = ContainerFrame1, Bag 1-4 = ContainerFrame2-5
	local containerID = (bag == 0) and 1 or (bag + 1)
	local frameName = string.format("ContainerFrame%dItem%d", containerID, slot)
	return _G[frameName]
end

-- Get button frame for a bank slot
function ItemHighlight:GetBankSlotButton(slot)
	-- Bank slots use BankFrameItem1, BankFrameItem2, etc.
	local frameName = string.format("BankFrameItem%d", slot)
	return _G[frameName]
end

-- Refresh all highlighting
function ItemHighlight:RefreshHighlighting()
	if not self.enabled then
		-- If disabled, clear Bagnon search (only if it was previously set)
		if Bagnon and self.lastBagnonSearch ~= nil then
			self.lastBagnonSearch = nil
			local addon = Bagnon
			addon.search = nil
			addon.canSearch = false
			addon:SendSignal('SEARCH_CHANGED')
		end
		return
	end

	-- Rebuild needed items list
	local rebuilt = self:BuildNeededItemsList()
	if not rebuilt then
		TOGBankClassic_Output:Debug("REQUESTS", "BuildNeededItemsList returned false, exiting")
		return
	end

	TOGBankClassic_Output:Debug("REQUESTS", "About to clear overlays")
	-- Clear old overlays (for default bags)
	self:ClearAllOverlays()

	TOGBankClassic_Output:Debug("REQUESTS", "Cleared overlays, updating highlighting")

	-- Apply new highlighting
	self:UpdateBagHighlighting()
	self:UpdateBankHighlighting()

	TOGBankClassic_Output:Debug("REQUESTS", "Refreshed item highlighting")
end
