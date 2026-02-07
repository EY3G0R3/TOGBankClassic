TOGBankClassic_Item = {}

-- FILE LOAD MARKER - Logged when this file is loaded
if TOGBankClassic_Output then
	TOGBankClassic_Output:Debug("ITEM", "Item.lua LOADED - Version with TRACE debugging - Timestamp: %s", date("%Y-%m-%d %H:%M:%S"))
end

-- Item classes that require Link to be preserved (for suffix differentiation)
-- Class 2 = Weapons, Class 4 = Armor (includes all equippable gear)
local ITEM_CLASSES_NEEDING_LINK = {
	[2] = true,  -- Weapon
	[4] = true,  -- Armor (chest, legs, trinkets, rings, necks, etc)
}

-- Helper to count items in aggregated table
function TOGBankClassic_Item:CountItems(items)
	local count = 0
	for _ in pairs(items) do
		count = count + 1
	end
	return count
end

-- Check if an item needs its Link preserved based on item class
-- Gear (weapons/armor) can have random suffixes, so Link is required
-- Consumables and trade goods don't vary, so Link can be stripped
function TOGBankClassic_Item:NeedsLink(itemLink)
	if not itemLink then return false end
	
	local _, _, _, _, _, _, _, _, itemEquipLoc, _, _, classID = GetItemInfo(itemLink)
	if classID == nil then
		-- If item isn't cached, preserve the link to avoid losing suffix data
		return true
	end
	if ITEM_CLASSES_NEEDING_LINK[classID] == true then
		return true
	end
	-- Fallback: any equippable item should keep its link
	if itemEquipLoc and itemEquipLoc ~= "" then
		return true
	end
	return false
end

-- Extract ItemString from item link (full, unmodified)
-- Example: "[Revenant Helmet of the Bear]" -> "item:10132:0:0:0:0:0:0:0:863"
-- If link is nil/empty, returns empty string
function TOGBankClassic_Item:GetItemString(link)
	if not link or link == "" then
		return ""
	end
	
	-- Extract ItemString from link format: |cFFFFFFFF|Hitem:...|h[Name]|h|r
	local itemString = link:match("|Hitem:([^|]+)|h")
	if itemString then
		return "item:" .. itemString
	end
	
	-- Fallback: try to extract just the numeric part
	local numericPart = link:match("item:([%d:]+)")
	if numericPart then
		return "item:" .. numericPart
	end
	
	-- Last resort: return the whole link
	return link
end

-- Get normalized item key for deduplication (strips unique instance ID)
-- Items with same ID+suffix but different instance IDs will have same key
-- Format: itemID:enchant:gem1:gem2:gem3:gem4:suffixID (7 parts)
function TOGBankClassic_Item:GetItemKey(link)
	if not link or link == "" then
		return ""
	end
	
	local itemString = link:match("|Hitem:([^|]+)|h")
	if not itemString then
		itemString = link:match("item:([%d:]+)")
	end
	
	if itemString then
		-- Split into parts
		local parts = {}
		for part in string.gmatch(itemString, "([^:]+)") do
			table.insert(parts, part)
		end
		
		-- Keep first 7 parts only (strip uniqueID and specializationID)
		if #parts >= 7 then
			return "item:" .. table.concat({parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7]}, ":")
		else
			return "item:" .. itemString
		end
	end
	
	return link
end

function TOGBankClassic_Item:GetItems(items, callback)
	if not items or type(items) ~= "table" then
		callback({})
		return
	end

	-- Only consider items that have a valid ID
	local total = 0
	local validItems = {}
	for idx, item in pairs(items) do
		-- Log every item we encounter to identify corrupted data
		if not item then
			TOGBankClassic_Output:Debug("ITEM", "[ITEM-FILTER] Skipping nil item at index %s", tostring(idx))
		elseif type(item) ~= "table" then
			TOGBankClassic_Output:Debug("ITEM", "[ITEM-FILTER] Skipping non-table item at index %s (type=%s)", tostring(idx), type(item))
		elseif not item.ID then
			TOGBankClassic_Output:Debug("ITEM", "[ITEM-FILTER] Skipping item with nil ID at index %s", tostring(idx))
		elseif type(item.ID) ~= "number" then
			TOGBankClassic_Output:Debug("ITEM", "[ITEM-FILTER] Skipping item with non-number ID at index %s (ID=%s, type=%s)",
				tostring(idx), tostring(item.ID), type(item.ID))
		elseif item.ID <= 0 or item.ID < 100 then
			TOGBankClassic_Output:Debug("ITEM", "[ITEM-FILTER] Skipping corrupted item with invalid ID at index %s (ID=%d)", tostring(idx), item.ID)
		else
			-- Valid item - add to processing list
			total = total + 1
			table.insert(validItems, {
				original = item,
				id = item.ID,
				link = item.Link
			})
		end
	end

	local list = {}
	local count = 0
	local processed = 0  -- Track total items processed (success + failures)
	local callbackFired = false  -- Ensure callback only fires once

	-- If there are no valid items to load, return an empty list immediately
	if total == 0 then
		callback(list)
		return
	end
	
	local function checkComplete()
		if not callbackFired and processed >= total then
			callbackFired = true
			callback(list)
		end
	end

	for _, wrapper in ipairs(validItems) do
		local itemID = wrapper.id
		local itemLink = wrapper.link
		local item = wrapper.original
		
		-- Debug: Log what we're about to process
		TOGBankClassic_Output:Debug("ITEM", "[ITEM-DEBUG] Processing wrapper: id=%s, link=%s, original.ID=%s",
			tostring(itemID), tostring(itemLink), tostring(item and item.ID or "nil item"))
		
		-- Final safety check before calling Blizzard API
		if not itemID or type(itemID) ~= "number" or itemID <= 0 then
			TOGBankClassic_Output:Debug("ITEM", "[ITEM-DEBUG] SKIPPING INVALID: itemID=%s (type=%s)",
				tostring(itemID), type(itemID))
			processed = processed + 1
			checkComplete()
		else
			-- Capture itemID in local scope to prevent closure corruption
			local capturedItemID = itemID
			local capturedItemLink = itemLink
			local capturedItem = item
			
			-- Double-check captured values
			if not capturedItemID or type(capturedItemID) ~= "number" or capturedItemID <= 0 then
				TOGBankClassic_Output:Debug("ITEM", "[ITEM-DEBUG] CRITICAL: itemID validation failed after capture!")
				processed = processed + 1
				checkComplete()
			else
				-- Check if item data is already cached (fast path)
				local itemInfo = GetItemInfo(capturedItemID)
				if itemInfo then
					-- Item data is cached, use it directly
					TOGBankClassic_Output:Debug("ITEM", "[ITEM-DEBUG] Item %d already cached", capturedItemID)
					capturedItem.Info = self:GetInfo(capturedItemID, capturedItemLink)
					table.insert(list, capturedItem)
					count = count + 1
					processed = processed + 1
					checkComplete()
				else
					-- Item not cached, need async load
					TOGBankClassic_Output:Debug("ITEM", "[TRACE-1] Item %d not cached, calling CreateFromItemID", capturedItemID)
					
					local success, itemData = pcall(Item.CreateFromItemID, Item, capturedItemID)
					
					TOGBankClassic_Output:Debug("ITEM", "[TRACE-2] CreateFromItemID result: success=%s, itemData=%s, type=%s",
						tostring(success), tostring(itemData), type(itemData))
					
					if not success then
						TOGBankClassic_Output:Debug("ITEM", "[TRACE-3] CreateFromItemID pcall failed: %s", tostring(itemData))
						processed = processed + 1
						checkComplete()
					elseif not itemData then
						TOGBankClassic_Output:Debug("ITEM", "[TRACE-4] CreateFromItemID returned nil")
						processed = processed + 1
						checkComplete()
					elseif type(itemData) ~= "table" then
						TOGBankClassic_Output:Debug("ITEM", "[TRACE-5] CreateFromItemID returned non-table: %s", type(itemData))
						processed = processed + 1
						checkComplete()
					else
						-- Got an Item object, now inspect its internal state
						TOGBankClassic_Output:Debug("ITEM", "[TRACE-6] Inspecting Item object for ID %d", capturedItemID)
						
						-- Try to access internal fields safely
						local objectItemID = nil
						local accessSuccess = pcall(function()
							objectItemID = itemData.itemID
						end)
						
						TOGBankClassic_Output:Debug("ITEM", "[TRACE-7] Internal field access: accessSuccess=%s, itemData.itemID=%s, type=%s",
							tostring(accessSuccess), tostring(objectItemID), type(objectItemID))
						
						-- Check if itemID matches what we expect
						if not accessSuccess then
							TOGBankClassic_Output:Debug("ITEM", "[TRACE-8] Cannot access itemData.itemID (protected?)")
							processed = processed + 1
							checkComplete()
						elseif objectItemID == nil then
							TOGBankClassic_Output:Debug("ITEM", "[TRACE-9] FOUND CORRUPTION: itemData.itemID is nil for requested ID %d - THIS IS THE BUG!", capturedItemID)
							processed = processed + 1
							checkComplete()
						elseif type(objectItemID) ~= "number" then
							TOGBankClassic_Output:Debug("ITEM", "[TRACE-10] itemData.itemID is not a number: %s", type(objectItemID))
							processed = processed + 1
							checkComplete()
						elseif objectItemID ~= capturedItemID then
							TOGBankClassic_Output:Debug("ITEM", "[TRACE-11] itemData.itemID mismatch: expected %d, got %d", capturedItemID, objectItemID)
							processed = processed + 1
							checkComplete()
						else
							-- Everything looks good, try ContinueOnItemLoad
							TOGBankClassic_Output:Debug("ITEM", "[TRACE-12] Item object valid (itemID=%d), calling ContinueOnItemLoad", objectItemID)
							
							local callbackSuccess, callbackError = pcall(function()
								itemData:ContinueOnItemLoad(function()
									TOGBankClassic_Output:Debug("ITEM", "[TRACE-13] ContinueOnItemLoad callback fired for ID %d", capturedItemID)
									capturedItem.Info = self:GetInfo(capturedItemID, capturedItemLink)
									table.insert(list, capturedItem)
									count = count + 1
									checkComplete()
								end)
							end)
							
							TOGBankClassic_Output:Debug("ITEM", "[TRACE-14] ContinueOnItemLoad pcall result: success=%s, error=%s",
								tostring(callbackSuccess), tostring(callbackError))
							
							processed = processed + 1
							
							if not callbackSuccess then
								TOGBankClassic_Output:Debug("ITEM", "[TRACE-15] ContinueOnItemLoad pcall FAILED for ID %d: %s",
									capturedItemID, tostring(callbackError))
								checkComplete()
							end
						end
					end
				end
			end
		end
	end
end

function TOGBankClassic_Item:GetInfo(id, link)
	local name, _, rarity, level, _, _, _, _, _, icon, price, itemClassId, itemSubClassId
	
	-- Try link first if available
	if link and link ~= "" then
		name, _, rarity, level, _, _, _, _, _, icon, price, itemClassId, itemSubClassId = GetItemInfo(link)
	end
	
	-- Fallback to ID if link didn't work
	if not name and id and id > 0 then
		name, _, rarity, level, _, _, _, _, _, icon, price, itemClassId, itemSubClassId = GetItemInfo(id)
	end
	
	-- If still no data, return basic info with ID only
	if not name then
		return {
			class = 0,
			subClass = 0,
			equipId = 0,
			rarity = 1,
			name = "Item " .. tostring(id or "?"),
			level = 1,
			price = 0,
			icon = 134400, -- Default grey question mark icon
		}
	end

	local equip = C_Item.GetItemInventoryTypeByID(id)

	return {
		class = itemClassId,
		subClass = itemSubClassId,
		equipId = equip,
		rarity = rarity,
		name = name,
		level = level,
		price = price,
		icon = icon,
	}
end

-- NOTE: Sort was adapted from ElvUI
local function BasicSort(a, b)
	if a.Info.level ~= b.Info.level and a.Info.level and b.Info.level then
		return a.Info.level < b.Info.level
	end
	if a.Info.price ~= b.Info.price and a.Info.price and b.Info.price then
		return a.Info.price < b.Info.price
	end
	if a.Info.name and b.Info.name then
		return a.Info.name < b.Info.name
	end
end

-- NOTE: Sort was adapted from ElvUI
function TOGBankClassic_Item:Sort(items)
	table.sort(items, function(a, b)
		if a.Info.rarity ~= b.Info.rarity and a.Info.rarity and b.Info.rarity then
			return a.Info.rarity < b.Info.rarity
		end
		if a.Info.class ~= b.Info.class then
			return (a.Info.class or 99) < (b.Info.class or 99)
		end
		if a.Info.equipId > 0 then
			if a.Info.equipId == b.Info.equipId then
				return BasicSort(a, b)
			end

			if a.Info.equip and b.Info.equip then
				return a.Info.equip < b.Info.equip
			end
		end
		if a.Info.class == b.Info.class and a.Info.subClass == b.Info.subClass then
			return BasicSort(a, b)
		end
		return (a.Info.subClass or 99) < (b.Info.subClass or 99)
	end)
end

function TOGBankClassic_Item:Aggregate(a, b)
	local items = {}
	-- Build ID index to avoid O(n²) lookups for linkless deduplication
	local itemsByID = {}
	
	if a then
		for _, v in pairs(a) do
			-- Only require ID field (Link is optional for v0.8.0 link-less data)
			if not v or not v.ID then
				-- Skip malformed entries (missing required ID field)
			else
				-- Use NORMALIZED key (strips unique instance ID) for deduplication
				-- This allows identical items with different instance IDs to merge
				local itemKey = self:GetItemKey(v.Link or v.ItemString)
				local key = tostring(v.ID) .. itemKey
				
				-- If no Link, also check if there's an existing entry with same ID but with link
				-- This handles deduplication between linked (bank/bags) and linkless (mail) items
				if not v.Link and itemKey == "" then
					-- Use ID index for O(1) lookup instead of O(n) iteration
					local idStr = tostring(v.ID)
					local existingKeys = itemsByID[idStr]
					if existingKeys and #existingKeys > 0 then
						-- Found item(s) with same ID - merge into first entry
						local existingKey = existingKeys[1]
						local existingItem = items[existingKey]
						local itemCount = existingItem.Count or 1
						local vCount = v.Count or 1
								existingItem.Count = itemCount + vCount
								existingItem.Link = existingItem.Link or v.Link
								existingItem.ItemString = existingItem.ItemString or v.ItemString
								existingItem.ForceLink = existingItem.ForceLink or v.ForceLink
						key = nil  -- Signal that we already merged
					end
				end
				
				if key then
					if items[key] then
						local item = items[key]
						-- Defensive: use default value if Count is missing
						local itemCount = item.Count or 1
						local vCount = v.Count or 1
							items[key] = { ID = item.ID, Count = itemCount + vCount, Link = item.Link or v.Link, ItemString = item.ItemString or v.ItemString, ForceLink = item.ForceLink or v.ForceLink }
					else
						-- Ensure stored item has Count field
							items[key] = { ID = v.ID, Count = v.Count or 1, Link = v.Link, ItemString = v.ItemString, ForceLink = v.ForceLink }
						-- Add to ID index
						local idStr = tostring(v.ID)
						if not itemsByID[idStr] then
							itemsByID[idStr] = {}
						end
						table.insert(itemsByID[idStr], key)
					end
				end
			end
		end
	end

	if b then
		for _, v in pairs(b) do
			-- Only require ID field (Link is optional for v0.8.0 link-less data)
			if not v or not v.ID then
				-- Skip malformed entries (missing required ID field)
			else
				-- Use NORMALIZED key (strips unique instance ID) for deduplication
				-- This allows identical items with different instance IDs to merge
				local itemKey = self:GetItemKey(v.Link or v.ItemString)
				local key = tostring(v.ID) .. itemKey
				
				-- If no Link, also check if there's an existing entry with same ID but with link
				-- This handles deduplication between linked (bank/bags) and linkless (mail) items
				if not v.Link and itemKey == "" then
					-- Use ID index for O(1) lookup instead of O(n) iteration
					local idStr = tostring(v.ID)
					local existingKeys = itemsByID[idStr]
					if existingKeys and #existingKeys > 0 then
						-- Found item(s) with same ID - merge into first entry
						local existingKey = existingKeys[1]
						local existingItem = items[existingKey]
						local itemCount = existingItem.Count or 1
						local vCount = v.Count or 1
							existingItem.Count = itemCount + vCount
							existingItem.Link = existingItem.Link or v.Link
							existingItem.ItemString = existingItem.ItemString or v.ItemString
							existingItem.ForceLink = existingItem.ForceLink or v.ForceLink
						key = nil  -- Signal that we already merged
					end
				end
				
				if key then
					if items[key] then
						local item = items[key]
						-- Defensive: use default value if Count is missing
						local itemCount = item.Count or 1
						local vCount = v.Count or 1
							items[key] = { ID = item.ID, Count = itemCount + vCount, Link = item.Link or v.Link, ItemString = item.ItemString or v.ItemString, ForceLink = item.ForceLink or v.ForceLink }
					else
						-- Ensure stored item has Count field
							items[key] = { ID = v.ID, Count = v.Count or 1, Link = v.Link, ItemString = v.ItemString, ForceLink = v.ForceLink }
						-- Add to ID index
						local idStr = tostring(v.ID)
						if not itemsByID[idStr] then
							itemsByID[idStr] = {}
						end
						table.insert(itemsByID[idStr], key)
					end
				end
			end
		end
	end

	return items
end

function TOGBankClassic_Item:IsUnique(link)
	if not link then
		return false
	end

	local tip = CreateFrame("GameTooltip", "scanTip", UIParent, "GameTooltipTemplate")
	tip:ClearLines()
	tip:SetOwner(UIParent, "ANCHOR_NONE")
	tip:SetHyperlink(link)
	for i = 1, tip:NumLines() do
		local line = _G["scanTipTextLeft" .. i]
		if line and line:IsVisible() then
			local l = line:GetText()
			if l and l:find(ITEM_UNIQUE) then
				return true
			end
		end
	end

	return false
end