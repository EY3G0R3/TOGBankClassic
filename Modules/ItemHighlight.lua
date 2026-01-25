-- ItemHighlight.lua - Highlight items needed for pending orders
-- Greys out all items except those needed to fulfill active requests

TOGBankClassic_ItemHighlight = {}
local ItemHighlight = TOGBankClassic_ItemHighlight

-- State
ItemHighlight.enabled = false
ItemHighlight.neededItems = {} -- {itemName: quantityNeeded}
ItemHighlight.overlays = {} -- Texture overlays for dimming items

-- Settings
local OVERLAY_ALPHA = 0.7 -- Alpha for grey overlay (0=transparent, 1=opaque)
local OVERLAY_COLOR = {0.2, 0.2, 0.2} -- RGB grey color

-- Initialize the module
function ItemHighlight:Initialize()
	-- Load saved settings
	if TOGBankClassicDB and TOGBankClassicDB.settings then
		self.enabled = TOGBankClassicDB.settings.highlightEnabled or false
	end
	
	-- Register events
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("BAG_UPDATE")
	frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
	frame:RegisterEvent("BANKFRAME_OPENED")
	frame:RegisterEvent("BANKFRAME_CLOSED")
	frame:SetScript("OnEvent", function(_, event, ...)
		if self.enabled then
			ItemHighlight:RefreshHighlighting()
		end
	end)
	
	TOGBankClassic_Output:Debug("REQUESTS", "ItemHighlight initialized")
end

-- Enable/disable highlighting
function ItemHighlight:SetEnabled(enabled)
	self.enabled = enabled
	
	-- Save to settings
	if not TOGBankClassicDB.settings then
		TOGBankClassicDB.settings = {}
	end
	TOGBankClassicDB.settings.highlightEnabled = enabled
	
	if enabled then
		self:RefreshHighlighting()
	else
		self:ClearAllOverlays()
	end
end

-- Build table of needed items from all pending requests
function ItemHighlight:BuildNeededItemsList()
	self.neededItems = {}
	
	if not TOGBankClassic_RequestLog or not TOGBankClassic_RequestLog.requests then
		return
	end
	
	-- Aggregate quantities from all pending requests
	for _, request in ipairs(TOGBankClassic_RequestLog.requests) do
		if request.status ~= "complete" and request.status ~= "fulfilled" and request.status ~= "cancelled" then
			local itemName = request.item
			local qtyNeeded = (request.quantity or 0) - (request.quantityFulfilled or 0)
			
			if qtyNeeded > 0 then
				self.neededItems[itemName] = (self.neededItems[itemName] or 0) + qtyNeeded
			end
		end
	end
	
	TOGBankClassic_Output:Debug("REQUESTS", "Built needed items list: %d unique items", 
		TOGBankClassic_Core:TableCount(self.neededItems))
end

-- Check if an item is needed
function ItemHighlight:IsItemNeeded(itemName)
	if not itemName then return false end
	return self.neededItems[itemName] ~= nil
end

-- Apply grey overlay to a button
function ItemHighlight:ApplyOverlay(button)
	if not button or not button:IsVisible() then return end
	
	-- Check if overlay already exists
	local overlayKey = button:GetName() or tostring(button)
	if self.overlays[overlayKey] then return end
	
	-- Create grey overlay texture
	local overlay = button:CreateTexture(nil, "OVERLAY")
	overlay:SetAllPoints(button)
	overlay:SetColorTexture(OVERLAY_COLOR[1], OVERLAY_COLOR[2], OVERLAY_COLOR[3], OVERLAY_ALPHA)
	
	self.overlays[overlayKey] = overlay
end

-- Remove overlay from a button
function ItemHighlight:RemoveOverlay(button)
	if not button then return end
	
	local overlayKey = button:GetName() or tostring(button)
	local overlay = self.overlays[overlayKey]
	
	if overlay then
		overlay:Hide()
		overlay:SetParent(nil)
		self.overlays[overlayKey] = nil
	end
end

-- Clear all overlays
function ItemHighlight:ClearAllOverlays()
	for _, overlay in pairs(self.overlays) do
		overlay:Hide()
		overlay:SetParent(nil)
	end
	self.overlays = {}
end

-- Update highlighting for bag slots
function ItemHighlight:UpdateBagHighlighting()
	-- Iterate through all bag slots (bags 0-4)
	for bag = 0, 4 do
		local numSlots = C_Container.GetContainerNumSlots(bag)
		for slot = 1, numSlots do
			local itemInfo = C_Container.GetContainerItemInfo(bag, slot)
			if itemInfo then
				local itemName = C_Item.GetItemNameByID(itemInfo.itemID)
				local button = self:GetBagSlotButton(bag, slot)
				
				if button then
					if self:IsItemNeeded(itemName) then
						-- Item is needed - remove overlay
						self:RemoveOverlay(button)
					else
						-- Item not needed - apply grey overlay
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
				if self:IsItemNeeded(itemName) then
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
					if self:IsItemNeeded(itemName) then
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
	-- Try modern container API first
	if C_Container and C_Container.GetContainerFrame then
		local containerFrame = C_Container.GetContainerFrame(bag)
		if containerFrame then
			return containerFrame:GetItemButton(slot)
		end
	end
	
	-- Fallback: Classic frame names
	local frameName = string.format("ContainerFrame%dItem%d", (bag == 0 and 1 or bag + 1), slot)
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
	if not self.enabled then return end
	
	-- Rebuild needed items list
	self:BuildNeededItemsList()
	
	-- Clear old overlays
	self:ClearAllOverlays()
	
	-- Apply new highlighting
	self:UpdateBagHighlighting()
	self:UpdateBankHighlighting()
	
	TOGBankClassic_Output:Debug("REQUESTS", "Refreshed item highlighting")
end

-- Initialize on load
if TOGBankClassic_Core and TOGBankClassic_Core.RegisterModule then
	TOGBankClassic_Core:RegisterModule("ItemHighlight", ItemHighlight)
end
