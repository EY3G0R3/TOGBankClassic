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
-- Third-party bag UI integration latches. Declared up here rather than beside their
-- implementations below because SetEnabled (further up the file) reads them -- a local
-- declared later is not in scope there and would silently resolve to a nil global.
local elvuiHooked = false        -- ELVUI-001: hooksecurefunc installed on ElvUI's Bags module
local baganatorRegistered = false -- BAGANATOR-001: corner widget registered with Baganator

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
	-- The handler refreshes everything regardless of which event fired, so neither the event name
	-- nor its payload is read. Named `_` so that is explicit rather than looking like an oversight.
	eventFrame:SetScript("OnEvent", function()
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
		-- ELVUI-001: self.enabled is already false, so this rebuild makes our UpdateSlot
		-- hook a no-op and ElvUI reasserts its own searchOverlay state, clearing our dimming.
		self:RefreshElvUI()
		-- BAGANATOR-001: same idea -- onUpdate now returns false for every icon, hiding
		-- our marker. Only refreshes if the widget was actually registered.
		if baganatorRegistered then
			self:RefreshBaganator()
		end
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

--- Resolve a button's icon texture without assuming the button has a NAME.
---
--- AUDIT FINDING 10 (HIGHLIGHT-002), first half. The old spelling was
--- `button.icon or button.Icon or _G[button:GetName().."IconTexture"]`, which raises when
--- `GetName()` returns nil -- and several bag addons create anonymous buttons.
---
--- The finding said Lua "evaluates the concatenation even as the third `or` operand". IT DOES NOT:
--- `or` short-circuits, so the concatenation is reached ONLY when a button carries neither `.icon`
--- nor `.Icon`. That is why the crash is the RARER branch -- an anonymous button with `.icon`, the
--- near-universal convention, never evaluates it. The branch that actually fires is in
--- ClearAllOverlays below.
local function iconOf(button, name)
	return button.icon or button.Icon or (name and _G[name .. "IconTexture"])
end

-- Apply grey desaturation to a button
function ItemHighlight:ApplyOverlay(button)
	if not button or not button:IsVisible() then
		return
	end
	local name = button:GetName()
	-- Get the icon texture (works for both default and Bagnon buttons)
	local icon = iconOf(button, name)
	if icon then
		-- Grey out by reducing color saturation (use very dark grey)
		icon:SetVertexColor(0.2, 0.2, 0.2)
	end
	-- Store the BUTTON ITSELF, not `true`. See ClearAllOverlays for why the key alone is not enough.
	self.overlays[name or tostring(button)] = button
end

-- Remove grey desaturation from a button
function ItemHighlight:RemoveOverlay(button)
	if not button then return end
	local buttonName = button:GetName()
	-- Reset texture color to normal (FULL COLOR)
	local icon = iconOf(button, buttonName)
	if icon then
		icon:SetVertexColor(1, 1, 1)
	end
	self.overlays[buttonName or tostring(button)] = nil
end

--- Clear all overlays.
---
--- AUDIT FINDING 10 (HIGHLIGHT-002), second half -- and this is the branch that ACTUALLY FIRES,
--- where the crash above is the rare one.
---
--- This used to recover the button from its key: `_G[buttonKey] or buttonKey`, then skip the result
--- if it was still a string. For a NAMED button that works. For an anonymous one the key is
--- `tostring(button)` -- "table: 0x...", which is not a global -- so the lookup returned nil, the
--- fallback handed back the key string, the type test skipped it, and **the item stayed dimmed for
--- the rest of the session with no way to undo it.** Every entry point that clears highlighting
--- (RefreshHighlighting, disabling the feature, a request being filled) silently did nothing for
--- those buttons.
---
--- The fix is to stop round-tripping an object through a string. `ApplyOverlay` stores the button,
--- so this hands the real object straight to RemoveOverlay and the name is never needed. Note the
--- author had ALREADY anticipated a nil name one line further down -- `[button:GetName() or
--- tostring(button)]` -- so the guard existed; it was just placed downstream of the thing it was
--- written for.
---
--- Assigning nil to the current key inside `pairs` is explicitly permitted in Lua 5.1, which is what
--- RemoveOverlay does as it goes.
function ItemHighlight:ClearAllOverlays()
	for _, button in pairs(self.overlays) do
		self:RemoveOverlay(button)
	end
	self.overlays = {}
end

-- ELVUI-001: ElvUI replaces the bag UI entirely, so Blizzard's ContainerFrameNItemN
-- buttons are never shown and the default path's ApplyOverlay bails on its IsVisible()
-- guard -- the checkbox ticks and nothing happens. ElvUI already owns exactly the visual
-- we want: each slot carries a `searchOverlay` texture (SetColorTexture(0, 0, 0, 0.6))
-- that it shows to dim items filtered out by its search box. We reuse it rather than
-- poking icon vertex colours, so we never fight ElvUI's own rendering.
--
-- Verified against ElvUI/Game/Shared/Modules/Bags/Bags.lua (tukui-org/ElvUI):
--   B:UpdateSlot(frame, bagID, slotID)  -- per-slot rebuild; sets searchOverlay itself
--   B:InventorySearchUpdate(slot)       -- re-applies searchOverlay on search events
--   frame.Bags[bagID][slotID]           -- slot button lookup
--   B.BagFrame / B.BankFrame            -- ElvUI_ContainerFrame / ElvUI_BankContainerFrame
--   B:UpdateAllBagSlots()               -- bulk refresh entry point
-- Both writers are hooked with hooksecurefunc so our pass runs *after* ElvUI sets its own
-- value. We only ever turn the overlay ON for unneeded items and never turn it off, so a
-- slot ElvUI is already hiding for its own search stays hidden.
-- (elvuiHooked latch is declared at the top of the file -- see the note there.)

local function GetElvUIBags()
	if not ElvUI then
		return nil
	end
	local E = unpack(ElvUI)
	if not E or not E.GetModule then
		return nil
	end
	-- silent=true: ElvUI builds without the Bags module shouldn't error
	local B = E:GetModule("Bags", true)
	if not B or not B.UpdateSlot then
		return nil
	end
	-- ELVUI-001: the module object exists even when the user has switched ElvUI's bag
	-- replacement off (running Bagnon underneath it, say). B.BagFrame is only assigned in
	-- B:Initialize(), so its absence means ElvUI is not drawing the bags -- fall through to
	-- the Bagnon / Blizzard paths instead of claiming a UI we aren't actually driving.
	if not B.BagFrame then
		return nil
	end
	return B
end

function ItemHighlight:ApplyElvUISlot(frame, bagID, slotID)
	if not self.enabled then
		return
	end
	local bag = frame and frame.Bags and frame.Bags[bagID]
	local slot = bag and bag[slotID]
	if not slot or not slot.searchOverlay then
		return
	end
	-- Empty slot: leave ElvUI's own state alone.
	if not slot.itemID then
		return
	end
	local itemName = C_Item.GetItemNameByID(slot.itemID)
	if not self:IsItemNeeded(itemName, slot.itemID) then
		slot.searchOverlay:SetShown(true)
	end
end

function ItemHighlight:SetupElvUIHooks()
	if elvuiHooked then
		return true
	end
	local B = GetElvUIBags()
	if not B then
		return false
	end

	hooksecurefunc(B, "UpdateSlot", function(_, frame, bagID, slotID)
		ItemHighlight:ApplyElvUISlot(frame, bagID, slotID)
	end)

	-- INVENTORY_SEARCH_UPDATE path re-asserts searchOverlay from the slot itself.
	if B.InventorySearchUpdate then
		hooksecurefunc(B, "InventorySearchUpdate", function(_, slot)
			if not ItemHighlight.enabled or not slot or not slot.searchOverlay then
				return
			end
			if not slot.itemID then
				return
			end
			local itemName = C_Item.GetItemNameByID(slot.itemID)
			if not ItemHighlight:IsItemNeeded(itemName, slot.itemID) then
				slot.searchOverlay:SetShown(true)
			end
		end)
	end

	elvuiHooked = true
	TOGBankClassic_Output:Debug("REQUESTS", "ItemHighlight: ElvUI bag hooks installed")
	return true
end

-- Ask ElvUI to rebuild every slot, which re-runs our UpdateSlot hook.
-- Also the disable path: with self.enabled false the hook is a no-op, so ElvUI's
-- rebuild restores its own overlay state and our dimming disappears.
function ItemHighlight:RefreshElvUI()
	local B = GetElvUIBags()
	if not B or not B.UpdateAllBagSlots then
		return false
	end
	B:UpdateAllBagSlots()
	return true
end

function ItemHighlight:UpdateElvUIHighlighting()
	if not self:SetupElvUIHooks() then
		TOGBankClassic_Output:Debug("REQUESTS", "ElvUI bags not found")
		return false
	end
	TOGBankClassic_Output:Debug("REQUESTS", "Using ElvUI highlighting")
	return self:RefreshElvUI()
end

-- BAGANATOR-001: Baganator also replaces the bag UI, so the Blizzard-frame fallback finds
-- only hidden buttons and dims nothing -- the same dead-checkbox symptom as ElvUI. Unlike
-- ElvUI there is no public way to drive its search or its per-slot dimming: the only
-- sanctioned integration is the corner-widget API, which marks matching items rather than
-- dimming the rest. So the visual differs by design here -- needed items get a marker
-- instead of everything else going grey. Pattern copied from Baganator's own CanIMogIt and
-- equipment_set_icon widgets in API/ItemButton.lua (lines 316-355).
--
-- Verified against the installed Baganator (API/Main.lua):
--   Baganator.API.RegisterCornerWidget(label, id, onUpdate, onInit, defaultPosition, isFast)
--     onUpdate(cornerFrame, details) -> true show / false hide / nil "data not ready yet"
--     onInit(itemButton) -> Frame, called once per icon
--     details carries .itemID, .itemLink, .itemLocation{.bagID,.slotIndex}
--   Baganator.API.RequestItemButtonsRefresh({Baganator.Constants.RefreshReason.ItemWidgets})
--   Baganator.API.IsCornerWidgetActive(id)
-- RegisterCornerWidget asserts on a duplicate id, hence the registration latch
-- (baganatorRegistered, declared at the top of the file -- see the note there).

local function GetBaganatorAPI()
	if Baganator and Baganator.API and Baganator.API.RegisterCornerWidget then
		return Baganator.API
	end
	return nil
end

function ItemHighlight:SetupBaganatorWidget()
	if baganatorRegistered then
		return true
	end
	local API = GetBaganatorAPI()
	if not API then
		return false
	end

	local onUpdate = function(_, details)
		if not ItemHighlight.enabled then
			return false
		end
		if not details or not details.itemID then
			return false
		end
		-- Fast path: ID-keyed requests need no item cache at all.
		if ItemHighlight.neededItemIDs[details.itemID] then
			return true
		end
		-- Legacy name-keyed requests need the item name. A cold cache returns nil, which
		-- is Baganator's "not ready" signal -- returning false there would wrongly latch
		-- the marker off until the next full refresh.
		if next(ItemHighlight.neededItems) ~= nil then
			local itemName = C_Item.GetItemNameByID(details.itemID)
			if not itemName then
				return nil
			end
			return ItemHighlight.neededItems[itemName] ~= nil
		end
		return false
	end

	local onInit = function(itemButton)
		local marker = itemButton:CreateTexture(nil, "OVERLAY")
		marker:SetSize(12, 12)
		-- Solid colour rather than a texture path: the Era client is missing a lot of
		-- icon assets, and a missing file renders as a blank square with no error.
		-- SetColorTexture needs no asset and is identical on every client.
		marker:SetColorTexture(1, 0.82, 0, 0.9)
		return marker
	end

	-- pcall: RegisterCornerWidget asserts, and a Baganator API change must not break
	-- highlighting for everyone else.
	local ok, err = pcall(API.RegisterCornerWidget,
		"TOGBank: needed for an order",
		"togbank_needed",
		onUpdate,
		onInit,
		{ corner = "top_left", priority = 1 },
		true)
	if not ok then
		TOGBankClassic_Output:Debug("REQUESTS", "ItemHighlight: Baganator widget registration failed: %s", tostring(err))
		return false
	end

	baganatorRegistered = true
	TOGBankClassic_Output:Debug("REQUESTS", "ItemHighlight: Baganator corner widget registered")
	return true
end

-- Ask Baganator to re-run every corner widget, which re-evaluates our onUpdate.
-- Also the disable path: with self.enabled false, onUpdate returns false everywhere.
function ItemHighlight:RefreshBaganator()
	local API = GetBaganatorAPI()
	if not API or not API.RequestItemButtonsRefresh then
		return false
	end
	local reason = Baganator.Constants
		and Baganator.Constants.RefreshReason
		and Baganator.Constants.RefreshReason.ItemWidgets
	pcall(API.RequestItemButtonsRefresh, reason and { reason } or nil)
	return true
end

function ItemHighlight:UpdateBaganatorHighlighting()
	if not self:SetupBaganatorWidget() then
		TOGBankClassic_Output:Debug("REQUESTS", "Baganator not found")
		return false
	end
	TOGBankClassic_Output:Debug("REQUESTS", "Using Baganator highlighting")
	return self:RefreshBaganator()
end

-- Update highlighting for bag slots
function ItemHighlight:UpdateBagHighlighting()
	TOGBankClassic_Output:Debug("REQUESTS", "UpdateBagHighlighting called")
	-- ELVUI-001: ElvUI owns the bag UI when present, so it must be checked before both
	-- Bagnon and the Blizzard-frame fallback.
	if self:UpdateElvUIHighlighting() then
		return
	end
	-- BAGANATOR-001: likewise Baganator, checked before Bagnon and the Blizzard fallback.
	if self:UpdateBaganatorHighlighting() then
		return
	end
	-- Try Bagnon next
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

	local function stripRecipePrefix(name)
		local cleaned = name:gsub("^Formula: ", "")
		cleaned = cleaned:gsub("^Pattern: ", "")
		cleaned = cleaned:gsub("^Recipe: ", "")
		cleaned = cleaned:gsub("^Plans: ", "")
		cleaned = cleaned:gsub("^Schematic: ", "")
		cleaned = cleaned:gsub("^Design: ", "")
		cleaned = cleaned:gsub("^Manual: ", "")
		return cleaned
	end

	for itemName, _ in pairs(self.neededItems) do
		seenNames[itemName] = true
		local cleanName = stripRecipePrefix(itemName)
		table.insert(searchTerms, cleanName)
	end
	-- Include names for ID-keyed entries (from new requests with itemID)
	for itemID, _ in pairs(self.neededItemIDs) do
		local name = C_Item.GetItemNameByID(itemID)
		if name and not seenNames[name] then
			seenNames[name] = true
			local cleanName = stripRecipePrefix(name)
			table.insert(searchTerms, cleanName)
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

--- Find the ContainerFrame currently RENDERING a bag, the way Blizzard does.
---
--- AUDIT FINDING 29 (HIGH). Both call sites used to derive the name arithmetically --
--- `containerID = (bag == 0) and 1 or (bag + 1)` -- which assumes a fixed bag-to-frame mapping.
--- CLASSIC ERA HAS NO SUCH MAPPING. A bag is rendered into the first frame that is not currently
--- shown, verified in Blizzard's own source for this flavour:
---
---     -- Blizzard_UIPanels_Game/Classic/ContainerFrame_Shared.lua:476-481
---     function ContainerFrame_GetOpenFrame()
---         for i=1, NUM_CONTAINER_FRAMES, 1 do
---             local frame = _G["ContainerFrame"..i];
---             if ( not frame:IsShown() ) then return frame; end
---
--- and Blizzard NEVER derives the name anywhere: `ToggleBag` (:126-138), `OpenBag` (:331-341),
--- `CloseBag` (:351-358) and `IsBagOpen` (:361-369) all SEARCH, comparing
--- `frame:IsShown() and frame:GetID() == id`. The arithmetic only holds when bags happen to have
--- been opened in ascending order starting from the backpack.
---
--- FAILURE THIS PRODUCED: open bag 1 with the backpack closed and bag 1 renders into
--- ContainerFrame1, while the addon looks up ContainerFrame2 -- not shown, so ApplyOverlay bails on
--- its IsVisible guard and NOTHING IS HIGHLIGHTED, with no error. Open bag 2 then bag 1 and it is
--- worse: the lookups cross, so one bag is highlighted using another bag's slot count.
---
--- AND THE SYMPTOM WAS ALREADY ON RECORD, ATTRIBUTED ELSEWHERE. The ELVUI-001 note above describes
--- "the checkbox ticks and nothing happens" -- the identical silent signature, because both failures
--- end at the same IsVisible guard. ElvUI is a real cause of that; it was not the only one, and
--- reports from stock-UI users would have stayed unexplained.
---
--- `frame.size` is set by ContainerFrame_GenerateFrame (:713-714), so the frame carries the slot
--- count it was actually built with -- which is the count the button numbering below is relative to.
--- @return table|nil frame, number numSlots
local function findContainerFrame(bag)
	local n = NUM_CONTAINER_FRAMES or 13
	for i = 1, n do
		local frame = _G["ContainerFrame" .. i]
		if frame and frame:IsShown() and frame:GetID() == bag then
			return frame, frame.size or C_Container.GetContainerNumSlots(bag) or 0
		end
	end
	return nil, 0
end

-- Update highlighting for default WoW bags
function ItemHighlight:UpdateDefaultBagHighlighting()
	-- Iterate through all bags
	for bag = 0, 4 do
		-- Slot count comes from the FRAME, not the bag: the button numbering below is relative to
		-- the frame that is actually rendering this bag, and taking the two from different places
		-- is how a reversal lands on the wrong button.
		local frame, numSlots = findContainerFrame(bag)
		local frameName = frame and frame:GetName()

		-- Iterate through API slot numbers (1 to numSlots)
		for apiSlot = 1, numSlots do
			-- WoW bag buttons are ordered OPPOSITE of API slots
			-- API slot 1 = button slot numSlots, API slot 2 = button slot numSlots-1, etc.
			local buttonSlot = numSlots - apiSlot + 1
			local button = frameName and _G[frameName .. "Item" .. buttonSlot]
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

	-- BANKSLOT-001: ASK THE CLIENT. Both loops in this function hardcoded numbers, and MEASUREMENT
	-- ON A LIVE CLASSIC ERA CLIENT (2026-09-09) proved both wrong:
	--
	--   NUM_BANKGENERIC_SLOTS = 24   (this loop said 28 -- four slots too many)
	--   NUM_BAG_SLOTS         = 4
	--   NUM_BANKBAGSLOTS      = 6    (the bag loop below said 5..11, i.e. seven -- one too many)
	--
	-- Neither overran harmfully: GetContainerItemInfo returns nil for a slot that does not exist and
	-- GetBankSlotButton finds no BankFrameItem25. So this was wasted work and a false statement in a
	-- comment rather than a visible defect -- but "the numbers are wrong and nothing notices" is the
	-- state a real defect hides in, and the SHAPE was wrong regardless of the values because this
	-- addon ships Era and TBC from one source and the two need not agree.
	--
	-- Blizzard's own BankFrame.lua does exactly this: `for i = 1, NUM_BANKGENERIC_SLOTS`, and
	-- `self.size = NUM_BANKGENERIC_SLOTS`. Taking a count from anywhere but the thing being iterated
	-- is the same mistake findContainerFrame above exists to prevent.
	--
	-- THE CONSTANTS ARE ENGINE-SIDE and cannot be read from Blizzard's source at all: Constants.lua
	-- has `NUM_BANKGENERIC_SLOTS = Constants.InventoryConstants.NumGenericBankSlots`, and the
	-- generated documentation defines THAT as `Value = BANK_NUM_GENERIC_SLOTS` -- a symbol the client
	-- supplies. The docs point at the constant and the constant points at the docs, which is why this
	-- needed a live client and why the harness refused to guess it (contract section 9).
	--
	-- The fallbacks are the MEASURED Era values, used only if this somehow runs before
	-- Blizzard_FrameXMLBase sets the globals. TBC may differ and that costs nothing: each client
	-- reads its own constant, so the fallback is never the cross-flavour answer.
	for slot = 1, (NUM_BANKGENERIC_SLOTS or 24) do
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
	-- BANKSLOT-001: bank bags are the containers AFTER the carried bags, and both ends come from the
	-- client. Blizzard's BankFrame.lua:245 is the same expression:
	--   for i = NUM_BAG_SLOTS+1, (NUM_BAG_SLOTS + NUM_BANKBAGSLOTS)
	-- On Classic Era that is 5..10. This said `5, 11` -- a hardcoded start that happened to be right
	-- and a hardcoded end that was one too many, with a comment stating the wrong range as fact.
	local firstBankBag = (NUM_BAG_SLOTS or 4) + 1
	local lastBankBag  = (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 6)
	for bag = firstBankBag, lastBankBag do
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
--
-- AUDIT FINDING 29: this derived the frame name from the bag id, which Classic Era does not
-- guarantee -- see findContainerFrame above for the Blizzard source. Now resolved by search.
--
-- AUDIT FINDING 9 (HIGHLIGHT-001) is subsumed here rather than fixed separately. That finding was
-- that bank bags dim the wrong slots because this path applied NO button-order reversal while
-- UpdateDefaultBagHighlighting applied one, and the two could not both be right. They are now one
-- resolution and one reversal, so the divergence has nowhere left to live: `slot` arrives as an API
-- slot and is converted here exactly as the bag path converts it.
function ItemHighlight:GetBagSlotButton(bag, slot)
	local frame, numSlots = findContainerFrame(bag)
	if not frame or numSlots <= 0 then return nil end
	-- Button numbering runs opposite to API slot numbering, and is relative to THIS frame's size.
	local buttonSlot = numSlots - slot + 1
	return _G[frame:GetName() .. "Item" .. buttonSlot]
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
