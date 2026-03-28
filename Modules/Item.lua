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
-- Weapons (class 2) and Armor (class 4) ALWAYS keep their Link regardless of suffix,
-- because plain and suffixed variants of the same item share the same base ID and must
-- be distinguished by their full link string to avoid deduplication collisions.
function TOGBankClassic_Item:NeedsLink(itemLink)
	if not itemLink then return false end

	-- Primary check: item class via GetItemInfo (synchronous cache lookup at send time).
	-- ITEM_CLASSES_NEEDING_LINK = { [2]=Weapon, [4]=Armor } — these ALWAYS preserve Link.
	local itemID = tonumber(itemLink:match("|Hitem:(%d+)"))
	if itemID then
		local _, _, _, _, _, _, _, _, _, _, _, itemClassId = GetItemInfo(itemID)
		if itemClassId and ITEM_CLASSES_NEEDING_LINK[itemClassId] then
			return true
		end
	end

	-- Fallback (uncached items or raw itemString input): preserve link if link has a
	-- non-zero suffix field (part 7 of the itemString: enchant:gem1:gem2:gem3:gem4:suffixID).
	local hasSuffix = itemLink:match("item:%d+:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:%-?%d+")
	if hasSuffix then
		return true
	end

	return false
end

-- Check by item ID whether this item's class requires a Link to be preserved.
-- Returns true  = weapon/armor (class 2/4) — link required
-- Returns false = other class — link optional
-- Returns nil   = item not in client cache yet — caller must decide
-- Used by ApplyItemDelta to guard against accepting link-stripped items on the receive side.
function TOGBankClassic_Item:ItemClassNeedsLink(itemID)
	if not itemID then return nil end
	local _, _, _, _, _, _, _, _, _, _, _, itemClassId = GetItemInfo(itemID)
	if itemClassId then
		return ITEM_CLASSES_NEEDING_LINK[itemClassId] == true
	end
	return nil  -- not cached
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
	-- DUPLICATION-FIX: Handle raw itemStrings without "item:" prefix (e.g., "929::::::::1::::::::::")
	if not itemString and link:match("^%d+:") then
		itemString = link
	end

	if itemString then
		-- Split into parts, PRESERVING empty parts between colons
		-- Item format: itemID:enchant:gem1:gem2:gem3:gem4:suffixID:uniqueID:level:...
		-- We want to keep parts 1-7 (itemID through suffixID), stripping uniqueID (part 8), level (part 9), etc.
		
		-- Use simpler approach: manually split by colons
		local parts = {}
		local current = ""
		for i = 1, #itemString do
			local char = itemString:sub(i, i)
			if char == ":" then
				table.insert(parts, current)
				current = ""
			else
				current = current .. char
			end
		end
		-- Add final part after last colon
		table.insert(parts, current)

		-- Keep first 7 parts only (itemID through suffixID, strip uniqueID/level/etc)
		-- Parts 8+ (uniqueID, level) cause the same item to appear as different keys
		if #parts >= 7 then
			local normalized = {}
			for i = 1, 7 do
				normalized[i] = parts[i]
			end
			local result = "item:" .. table.concat(normalized, ":")
			-- DEBUG: Log key normalization for items that might have level variations
			if parts[9] and parts[9] ~= "" and parts[9] ~= "0" then
				TOGBankClassic_Output:Debug("ITEM", "LOAD", "[DEDUP] GetItemKey: ID=%s level=%s -> key=%s", parts[1], parts[9], result)
			end
			return result
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
			TOGBankClassic_Output:Debug("ITEM", "VALIDATE", "[ITEM-FILTER] Skipping nil item at index %s", tostring(idx))
		elseif type(item) ~= "table" then
			TOGBankClassic_Output:Debug("ITEM", "VALIDATE", "[ITEM-FILTER] Skipping non-table item at index %s (type=%s)", tostring(idx), type(item))
		elseif not item.ID then
			TOGBankClassic_Output:Debug("ITEM", "VALIDATE", "[ITEM-FILTER] Skipping item with nil ID at index %s", tostring(idx))
		elseif type(item.ID) ~= "number" then
			TOGBankClassic_Output:Debug("ITEM", "VALIDATE", "[ITEM-FILTER] Skipping item with non-number ID at index %s (ID=%s, type=%s)",
				tostring(idx), tostring(item.ID), type(item.ID))
		elseif item.ID <= 0 or item.ID < 100 then
			TOGBankClassic_Output:Debug("ITEM", "VALIDATE", "[ITEM-FILTER] Skipping corrupted item with invalid ID at index %s (ID=%d)", tostring(idx), item.ID)
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
	local pendingAsync = 0  -- Track items waiting for async load

	-- If there are no valid items to load, return an empty list immediately
	if total == 0 then
		callback(list)
		return
	end

	local function checkComplete()
		if not callbackFired and processed >= total and pendingAsync == 0 then
			callbackFired = true
			callback(list)
		end
	end

	for _, wrapper in ipairs(validItems) do
		local itemID = wrapper.id
		local itemLink = wrapper.link
		local item = wrapper.original

		-- Debug: Log what we're about to process
		TOGBankClassic_Output:Debug("ITEM", "LOAD", "[ITEM-DEBUG] Processing wrapper: id=%s, link=%s, original.ID=%s",
			tostring(itemID), tostring(itemLink), tostring(item and item.ID or "nil item"))

		-- Final safety check before calling Blizzard API
		if not itemID or type(itemID) ~= "number" or itemID <= 0 then
			TOGBankClassic_Output:Debug("ITEM", "VALIDATE", "[ITEM-DEBUG] SKIPPING INVALID: itemID=%s (type=%s)",
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
				TOGBankClassic_Output:Debug("ITEM", "VALIDATE", "[ITEM-DEBUG] CRITICAL: itemID validation failed after capture!")
				processed = processed + 1
				checkComplete()
			else
				-- BRANCH 1: Item has link - just use it directly, no GetItemInfo calls
				if capturedItemLink then
					TOGBankClassic_Output:Debug("ITEM", "LOAD", "[ITEM-DEBUG] Item %d has link, using directly", capturedItemID)
					-- Only extract icon if Info doesn't already exist
					if not capturedItem.Info then
						-- Use GetItemInfo (not GetItemInfoInstant) so we get rarity and all fields.
						-- Since the item link came from the client's own bank scan, data is already
						-- in the WoW client cache — this is not a server query.
						local name, _, rarity, level, _, _, _, _, _, icon, price, itemClassId, itemSubClassId = GetItemInfo(capturedItemLink)
						if name then
							local equip = C_Item.GetItemInventoryTypeByID(capturedItemID)
							capturedItem.Info = {
								icon = icon,
								name = name,
								rarity = rarity,
								level = level,
								price = price,
								class = itemClassId,
								subClass = itemSubClassId,
								equipId = equip,
							}
						else
							-- Fallback: item somehow not in cache, extract what we can
							-- GetItemInfoInstant works without cache and returns class/subclass too
							local _, _, _, _, iconID, itemClassId, itemSubClassId = GetItemInfoInstant(capturedItemLink)
							if iconID then
								capturedItem.Info = {
									icon = iconID,
									name = capturedItemLink:match("%[(.-)%]") or ("Item " .. tostring(capturedItemID)),
									class = itemClassId,
									subClass = itemSubClassId,
								}
							end
						end
					end
					table.insert(list, capturedItem)
					count = count + 1
					processed = processed + 1
					-- Don't call checkComplete here - will batch check after loop
				-- BRANCH 2: No link - need to load item data
				else
					-- Check if item data is already cached (fast path)
					local name, _, rarity, level, _, _, _, _, _, icon, price, itemClassId, itemSubClassId = GetItemInfo(capturedItemID)
					if name then
						-- Item data is cached, build Info directly without calling GetInfo (avoids redundant GetItemInfo call)
						TOGBankClassic_Output:Debug("ITEM", "LOAD", "[ITEM-DEBUG] Item %d already cached", capturedItemID)
						local equip = C_Item.GetItemInventoryTypeByID(capturedItemID)
						capturedItem.Info = {
						class = itemClassId,
						subClass = itemSubClassId,
						equipId = equip,
						rarity = rarity,
						name = name,
						level = level,
						price = price,
						icon = icon,
					}
					table.insert(list, capturedItem)
					count = count + 1
					processed = processed + 1
					-- Don't call checkComplete here - will batch check after loop
				else
					-- Item not cached, need async load
					TOGBankClassic_Output:Debug("ITEM", "LOAD", "[TRACE-1] Item %d not cached, calling CreateFromItemID", capturedItemID)
					
					pendingAsync = pendingAsync + 1  -- Track this async operation

					local success, itemData = pcall(Item.CreateFromItemID, Item, capturedItemID)

					TOGBankClassic_Output:Debug("ITEM", "LOAD", "[TRACE-2] CreateFromItemID result: success=%s, itemData=%s, type=%s",
						tostring(success), tostring(itemData), type(itemData))

					if not success then
						TOGBankClassic_Output:Debug("ITEM", "LOAD", "[TRACE-3] CreateFromItemID pcall failed: %s", tostring(itemData))
						processed = processed + 1
						checkComplete()
					elseif not itemData then
						TOGBankClassic_Output:Debug("ITEM", "LOAD", "[TRACE-4] CreateFromItemID returned nil")
						processed = processed + 1
						checkComplete()
					elseif type(itemData) ~= "table" then
						TOGBankClassic_Output:Debug("ITEM", "LOAD", "[TRACE-5] CreateFromItemID returned non-table: %s", type(itemData))
						processed = processed + 1
						checkComplete()
					else
						-- Got an Item object, now inspect its internal state
						TOGBankClassic_Output:Debug("ITEM", "LOAD", "[TRACE-6] Inspecting Item object for ID %d", capturedItemID)

						-- Try to access internal fields safely
						local objectItemID = nil
						local accessSuccess = pcall(function()
							objectItemID = itemData.itemID
						end)

						TOGBankClassic_Output:Debug("ITEM", "LOAD", "[TRACE-7] Internal field access: accessSuccess=%s, itemData.itemID=%s, type=%s",
							tostring(accessSuccess), tostring(objectItemID), type(objectItemID))

						-- Check if itemID matches what we expect
						if not accessSuccess then
							TOGBankClassic_Output:Debug("ITEM", "VALIDATE", "[TRACE-8] Cannot access itemData.itemID (protected?)")
							processed = processed + 1
							checkComplete()
						elseif objectItemID == nil then
							TOGBankClassic_Output:Debug("ITEM", "VALIDATE", "[TRACE-9] FOUND CORRUPTION: itemData.itemID is nil for requested ID %d - THIS IS THE BUG!", capturedItemID)
							processed = processed + 1
							checkComplete()
						elseif type(objectItemID) ~= "number" then
							TOGBankClassic_Output:Debug("ITEM", "VALIDATE", "[TRACE-10] itemData.itemID is not a number: %s", type(objectItemID))
							processed = processed + 1
							checkComplete()
						elseif objectItemID ~= capturedItemID then
							TOGBankClassic_Output:Debug("ITEM", "VALIDATE", "[TRACE-11] itemData.itemID mismatch: expected %d, got %d", capturedItemID, objectItemID)
							processed = processed + 1
							checkComplete()
						else
							-- Everything looks good, try ContinueOnItemLoad
							TOGBankClassic_Output:Debug("ITEM", "LOAD", "[TRACE-12] Item object valid (itemID=%d), calling ContinueOnItemLoad", objectItemID)

							local callbackSuccess, callbackError = pcall(function()
								itemData:ContinueOnItemLoad(function()
										TOGBankClassic_Output:Debug("ITEM", "LOAD", "[TRACE-13] ContinueOnItemLoad callback fired for ID %d", capturedItemID)
									capturedItem.Info = self:GetInfo(capturedItemID, capturedItemLink)
									table.insert(list, capturedItem)
									count = count + 1
									pendingAsync = pendingAsync - 1  -- Async operation completed
									checkComplete()
								end)
							end)

							TOGBankClassic_Output:Debug("ITEM", "LOAD", "[TRACE-14] ContinueOnItemLoad pcall result: success=%s, error=%s",
								tostring(callbackSuccess), tostring(callbackError))

							processed = processed + 1

							if not callbackSuccess then
								TOGBankClassic_Output:Debug("ITEM", "LOAD", "[TRACE-15] ContinueOnItemLoad pcall FAILED for ID %d: %s",
									capturedItemID, tostring(callbackError))
								pendingAsync = pendingAsync - 1  -- Async operation failed
								checkComplete()
							end
						end
					end
				end
			end
		end
		end  -- close else from line 168
	end  -- close for loop from line 153
	
	-- After processing all items, check if we can fire callback
	-- (handles case where all items had links and were processed synchronously)
	checkComplete()
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
-- mode: "alpha" (default) = A-Z by name; "type" = grouped by item class/slot/subclass then name
function TOGBankClassic_Item:Sort(items, mode)
	-- Ensure all items have Info with required fields for sorting
	for _, item in ipairs(items) do
		if not item.Info then
			-- No Info at all - create minimal
			item.Info = {
				class = 0,
				subClass = 0,
				equipId = 0,
				rarity = 1,
				name = item.Link and item.Link:match("%[(.-)%]") or ("Item " .. tostring(item.ID or "?")),
				level = 1,
				price = 0,
				icon = 134400,
			}
		elseif not item.Info.class then
			-- Info exists but missing sort fields (linked items) - add defaults
			item.Info.class = item.Info.class or 0
			item.Info.subClass = item.Info.subClass or 0
			item.Info.equipId = item.Info.equipId or 0
			-- Do NOT default rarity here — nil rarity means "not yet known from GetItemInfo".
			-- DrawItem uses nil rarity to trigger its sync/async fallback lookups.
			-- The sort comparator at line ~477 already handles nil via (a.Info.rarity or 0).
			item.Info.level = item.Info.level or 1
			item.Info.price = item.Info.price or 0
			item.Info.name = item.Info.name or (item.Link and item.Link:match("%[(.-)%]")) or ("Item " .. tostring(item.ID or "?"))
		end
	end

	if mode == "type" then
		-- By Type: group by item class (armor/weapon/consumable/etc.), then by equip slot
		-- (all helms together, all cloaks together, all wands together), then by subclass,
		-- then by rarity, then alphabetically within each group.
		table.sort(items, function(a, b)
			if a.Info.class ~= b.Info.class then
				return (a.Info.class or 99) < (b.Info.class or 99)
			end
			local aEquip = a.Info.equipId or 0
			local bEquip = b.Info.equipId or 0
			if aEquip ~= bEquip then
				return aEquip < bEquip
			end
			if a.Info.subClass ~= b.Info.subClass then
				return (a.Info.subClass or 99) < (b.Info.subClass or 99)
			end
			if a.Info.rarity ~= b.Info.rarity then
				return (a.Info.rarity or 0) < (b.Info.rarity or 0)
			end
			return (a.Info.name or "") < (b.Info.name or "")
		end)
	elseif mode == "rarity" then
		-- By Rarity: highest rarity first (epic before rare before uncommon etc.), then A-Z
		table.sort(items, function(a, b)
			local aRarity = a.Info.rarity or 0
			local bRarity = b.Info.rarity or 0
			if aRarity ~= bRarity then
				return aRarity > bRarity
			end
			return (a.Info.name or "") < (b.Info.name or "")
		end)
	elseif mode == "rarity_asc" then
		-- By Rarity (ascending): lowest rarity first (poor before common before uncommon etc.), then A-Z
		table.sort(items, function(a, b)
			local aRarity = a.Info.rarity or 0
			local bRarity = b.Info.rarity or 0
			if aRarity ~= bRarity then
				return aRarity < bRarity
			end
			return (a.Info.name or "") < (b.Info.name or "")
		end)
	elseif mode == "level" then
		-- By Level: highest required level first, then A-Z
		table.sort(items, function(a, b)
			local aLevel = a.Info.level or 0
			local bLevel = b.Info.level or 0
			if aLevel ~= bLevel then
				return aLevel > bLevel
			end
			return (a.Info.name or "") < (b.Info.name or "")
		end)
	elseif mode == "level_asc" then
		-- By Level (ascending): lowest required level first, then A-Z
		table.sort(items, function(a, b)
			local aLevel = a.Info.level or 0
			local bLevel = b.Info.level or 0
			if aLevel ~= bLevel then
				return aLevel < bLevel
			end
			return (a.Info.name or "") < (b.Info.name or "")
		end)
	elseif mode == "alpha_desc" then
		-- Alphabetical descending: pure Z-A by name
		table.sort(items, function(a, b)
			return (a.Info.name or "") > (b.Info.name or "")
		end)
	else
		-- Alphabetical (default): pure A-Z by name
		table.sort(items, function(a, b)
			return (a.Info.name or "") < (b.Info.name or "")
		end)
	end
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
