---@class TOGBankClassic_Bank
TOGBankClassic_Bank = { ... }

local function IsBankAvailable()
	---START CHANGES
	local _, bagType = C_Container.GetContainerNumFreeSlots(BANK_CONTAINER)
	---END CHANGES
	return bagType ~= nil
end

local function HasUpdated()
	return TOGBankClassic_Bank.hasUpdated
end

local function ScanBag(bag, slots)
	local count = 0
	local items = {}
	for slot = 1, slots do
		---START CHANGES
		local itemInfo = C_Container.GetContainerItemInfo(bag, slot)
		if itemInfo then
			local itemCount = itemInfo.stackCount
			local itemLink = itemInfo.hyperlink
			local itemID = itemInfo.itemID
			---END CHANGES
			if itemLink then
				local key = itemID .. itemLink
				if items[key] then
					local item = items[key]
					items[key] = { ID = item.ID, Count = item.Count + itemCount, Link = item.Link }
				else
					items[key] = { ID = itemID, Count = itemCount, Link = itemLink }
				end
				count = count + 1
			end
		end
	end
	return count, items
end

local function ScanBags(bag_info)
	local total = 0
	local numslots = 0
	local bagItems = nil
	for bag = 0, 4 do
		---START CHANGES
		local slots = C_Container.GetContainerNumSlots(bag)
		---END CHANGES
		local count, items = ScanBag(bag, slots)
		if bagItems == nil then
			bagItems = items
		else
			for k, v in pairs(items) do
				if bagItems[k] then
					local item = bagItems[k]
					bagItems[k] = { ID = item.ID, Count = item.Count + v.Count, Link = item.Link }
				else
					bagItems[k] = v
				end
			end
		end
		total = total + count
		numslots = numslots + slots
	end

	for _, v in pairs(bagItems) do
		table.insert(bag_info, v)
	end

	return total, numslots
end

local function ScanBank(bank_info)
	local numslots = NUM_BANKGENERIC_SLOTS
	local total, bankItems = ScanBag(BANK_CONTAINER, NUM_BANKGENERIC_SLOTS)
	for bag = 5, 11 do
		---START CHANGES
		local slots = C_Container.GetContainerNumSlots(bag)
		---END CHANGES
		local count, items = ScanBag(bag, slots)
		for k, v in pairs(items) do
			if bankItems[k] then
				local item = bankItems[k]
				bankItems[k] = { ID = item.ID, Count = item.Count + v.Count, Link = item.Link }
			else
				bankItems[k] = v
			end
		end
		total = total + count
		numslots = numslots + slots
	end

	for _, v in pairs(bankItems) do
		table.insert(bank_info, v)
	end

	return total, numslots
end

function TOGBankClassic_Bank:Scan()
	if TOGBankClassic_Bank.eventsRegistered then
		if not HasUpdated() then
			return
		end
	end

	local info = TOGBankClassic_Guild.Info
	if not info then
		return
	end

	-- Normalize player name to ensure consistent keying in saved DB
	local player = TOGBankClassic_Guild:GetNormalizedPlayer()

	local isBank = false
	local banks = TOGBankClassic_Guild:GetBanks()
	if banks == nil then
		return
	end
	for _, v in pairs(banks) do
		local normV = TOGBankClassic_Guild:NormalizeName(v)
		if normV == player then
			isBank = true
			break
		end
	end
	if not isBank then
		return
	end
	if not TOGBankClassic_Options:GetBankEnabled() then
		return
	end

	-- Roster sync removed: Roster is now rebuilt locally from guild notes on GUILD_ROSTER_UPDATE

	local alt = {}
	-- Load from aggregate view (info.alts)
	if info.alts and info.alts[player] then
		alt = info.alts[player]
	end

	local total = 0
	local numslots = 0

	if IsBankAvailable() then
		alt.bank = {
			items = {},
			slots = {},
		}
		local count, slots = ScanBank(alt.bank.items)
		alt.bank.slots = { count = count, total = slots }
		total = total + count
		numslots = numslots + slots
	end

	alt.bags = {
		items = {},
		slots = {},
	}
	local count, slots = ScanBags(alt.bags.items)
	alt.bags.slots = { count = count, total = slots }
	total = total + count
	numslots = numslots + slots

	local money = GetMoney()
	alt.money = money

	-- Scan mail inventory if mail was accessed
	TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Bank:Scan() for player '%s', hasUpdated=%s",
		player, tostring(TOGBankClassic_MailInventory.hasUpdated))
	
	if TOGBankClassic_MailInventory.hasUpdated then
		TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Starting mail scan for player '%s'", player)
		
		local mailData = TOGBankClassic_MailInventory:ScanMailInventory()
		if mailData then
			local itemCount = 0
			for _ in pairs(mailData.items or {}) do
				itemCount = itemCount + 1
			end
			
			-- Check if alt.mail already exists
			local hadPreviousMail = alt.mail ~= nil
			local previousItemCount = 0
			if hadPreviousMail and alt.mail.items then
				-- mail.items is array format, use # operator
				previousItemCount = #alt.mail.items
			end
			
			TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Replacing mail data for '%s': old=%d items, new=%d items",
				player, previousItemCount, itemCount)
			
			alt.mail = mailData
			TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] ASSIGNED alt.mail with %d items, version=%s, lastScan=%s",
				#mailData.items, tostring(mailData.version), tostring(mailData.lastScan))
			
			-- Verify assignment worked
			if alt.mail then
				TOGBankClassic_Output:Debug("MAIL", "Confirmed: alt.mail exists with %d items", #alt.mail.items)
			else
				TOGBankClassic_Output:Debug("MAIL", "ERROR: alt.mail is nil after assignment!")
			end
		end
		
		TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Clearing hasUpdated flag after scan")
		TOGBankClassic_MailInventory.hasUpdated = false
	end

	-- Aggregate bank + bags + mail into alt.items for sync and display
	local bankItems = (alt.bank and alt.bank.items) or {}
	local bagItems = (alt.bags and alt.bags.items) or {}
	local mailItems = (alt.mail and alt.mail.items) or {}  -- Now an array like bank/bags
	
	-- DEBUG: Log sample counts from SOURCE arrays before aggregation
	if #bankItems > 0 then
		local bankSample = {}
		for i = 1, math.min(3, #bankItems) do
			local item = bankItems[i]
			if item then
				table.insert(bankSample, string.format("%s:%d", item.ID or "?", item.Count or 0))
			end
		end
		TOGBankClassic_Output:Debug("DATABASE", "SOURCES - bank.items (first 3): %s", table.concat(bankSample, ", "))
	end
	if #bagItems > 0 then
		local bagSample = {}
		for i = 1, math.min(3, #bagItems) do
			local item = bagItems[i]
			if item then
				table.insert(bagSample, string.format("%s:%d", item.ID or "?", item.Count or 0))
			end
		end
		TOGBankClassic_Output:Debug("DATABASE", "SOURCES - bags.items (first 3): %s", table.concat(bagSample, ", "))
	end
	if #mailItems > 0 then
		local mailSample = {}
		for i = 1, math.min(3, #mailItems) do
			local item = mailItems[i]
			if item then
				table.insert(mailSample, string.format("%s:%d", item.ID or "?", item.Count or 0))
			end
		end
		TOGBankClassic_Output:Debug("DATABASE", "SOURCES - mail.items (first 3): %s", table.concat(mailSample, ", "))
	end
	
	-- Aggregate all three sources (returns table with composite keys, deduplicates by ID)
	local aggregated = TOGBankClassic_Item:Aggregate(bankItems, bagItems)
	aggregated = TOGBankClassic_Item:Aggregate(aggregated, mailItems)
	
	-- Convert back to array format for storage/sync/display
	alt.items = {}
	for _, item in pairs(aggregated) do
		table.insert(alt.items, item)
	end
	
	-- DEBUG: Log sample counts after aggregation
	if alt.items and #alt.items > 0 then
		local scanSample = {}
		for i = 1, math.min(5, #alt.items) do
			local item = alt.items[i]
			if item then
				table.insert(scanSample, string.format("%s:%d", item.ID or "?", item.Count or 0))
			end
		end
		TOGBankClassic_Output:Debug("DATABASE", "After Bank:Scan aggregation - First 5 items: %s", table.concat(scanSample, ", "))
	end
	
	-- Also clean up source arrays to remove any duplicates (in case of corrupted data)
	-- This ensures future scans start fresh
	if alt.bank and alt.bank.items then
		local cleanBank = {}
		local bankAgg = TOGBankClassic_Item:Aggregate(alt.bank.items, nil)
		for _, item in pairs(bankAgg) do
			table.insert(cleanBank, item)
		end
		alt.bank.items = cleanBank
	end
	if alt.bags and alt.bags.items then
		local cleanBags = {}
		local bagsAgg = TOGBankClassic_Item:Aggregate(alt.bags.items, nil)
		for _, item in pairs(bagsAgg) do
			table.insert(cleanBags, item)
		end
		alt.bags.items = cleanBags
	end

	-- v0.8.0: Only update version if inventory actually changed
	-- Compute a hash of the current inventory state (SYNC-006: use aggregated alt.items)
	local currentHash = TOGBankClassic_Core:ComputeInventoryHash(alt.items, nil, nil, money)
	local previousHash = alt.inventoryHash

	if currentHash ~= previousHash then
		-- Inventory changed, update version timestamp
		alt.version = GetServerTime()
		alt.inventoryHash = currentHash
		TOGBankClassic_Output:Debug("SYNC", "Inventory changed for %s, version updated to %d (hash: %s)", player, alt.version, tostring(currentHash))
	else
		-- No changes detected, preserve existing version
		TOGBankClassic_Output:Debug("SYNC", "No inventory changes for %s, version unchanged (hash: %s)", player, tostring(currentHash))
	end

	-- Initialize tables if needed
	if not info.alts then
		info.alts = {}
	end

	-- Log what we're about to save
	if alt.mail then
		TOGBankClassic_Output:Debug("MAIL", "alt.mail exists with %d items, type=%s", #alt.mail.items, type(alt.mail))
		TOGBankClassic_Output:Debug("MAIL", "alt.mail.slots = %s", alt.mail.slots and ("table with count="..tostring(alt.mail.slots.count)) or "nil")
	end
	
	-- Write to aggregate view (info.alts) for normal use
	info.alts[player] = alt
	
	if alt.mail then
		TOGBankClassic_Output:Debug("MAIL", "Saved mail to info.alts[%s] (%d items)", player, #alt.mail.items)
	else
		TOGBankClassic_Output:Debug("MAIL", "No mail data to save for %s", player)
	end
end

function TOGBankClassic_Bank:HasInventorySpace()
	local total = 0
	for bag = 0, 4 do
		---START CHANGES
		local slots, _ = C_Container.GetContainerNumFreeSlots(bag)
		---END CHANGES
		total = total + slots
	end
	return total > 0
end

-- Find all slots containing an item by name (case-insensitive)
-- Returns: table of {bag, slot, count, link}
function TOGBankClassic_Bank:FindItemsByName(itemName)
	local results = {}
	if not itemName or itemName == "" then
		return results
	end

	local targetName = string.lower(itemName)

	for bag = 0, 4 do
		local slots = C_Container.GetContainerNumSlots(bag)
		for slot = 1, slots do
			local itemInfo = C_Container.GetContainerItemInfo(bag, slot)
			if itemInfo and itemInfo.hyperlink then
				local name = GetItemInfo(itemInfo.hyperlink)
				if name and string.lower(name) == targetName then
					table.insert(results, {
						bag = bag,
						slot = slot,
						count = itemInfo.stackCount or 1,
						link = itemInfo.hyperlink,
					})
				end
			end
		end
	end

	return results
end

-- Count total of named item in bags (0-4)
-- Returns: totalCount, itemsTable
function TOGBankClassic_Bank:CountItemInBags(itemName)
	local items = self:FindItemsByName(itemName)
	local total = 0
	for _, item in ipairs(items) do
		total = total + item.count
	end
	return total, items
end

function TOGBankClassic_Bank:OnUpdateStart()
	self.hasUpdated = true
end

function TOGBankClassic_Bank:OnUpdateStop()
	TOGBankClassic_Output:Debug("MAIL", "OnUpdateStop called, hasUpdated=%s", tostring(self.hasUpdated))
	if self.hasUpdated then
		TOGBankClassic_Output:Debug("MAIL", "Calling Scan()")
		self:Scan()
		TOGBankClassic_Output:Debug("MAIL", "Scan() completed")
	else
		TOGBankClassic_Output:Debug("MAIL", "Skipping Scan() because hasUpdated is false")
	end
	self.hasUpdated = false
end

-- Recalculate alt.items from existing bank/bags/mail data
-- Used to fix aggregation without requiring a full scan
function TOGBankClassic_Bank:RecalculateAggregatedItems(alt)
	if not alt then
		return
	end

	-- First deduplicate source data (bank/bags) in case they have duplicates
	local bankItems = {}
	if alt.bank and alt.bank.items then
		local deduped = TOGBankClassic_Item:Aggregate(alt.bank.items, nil)
		for _, item in pairs(deduped) do
			table.insert(bankItems, item)
		end
		-- Write deduplicated bank items back to source to fix SV file
		alt.bank.items = bankItems
	end
	
	local bagItems = {}
	if alt.bags and alt.bags.items then
		local deduped = TOGBankClassic_Item:Aggregate(alt.bags.items, nil)
		for _, item in pairs(deduped) do
			table.insert(bagItems, item)
		end
		-- Write deduplicated bag items back to source to fix SV file
		alt.bags.items = bagItems
	end
	
	local mailItems = {}
	if alt.mail and alt.mail.items then
		TOGBankClassic_Output:Debug("MAIL", "[MAIL-003] BEFORE dedup: mail has %d entries", #alt.mail.items)
		-- Debug: Check for duplicates BEFORE deduplication
		local mailByID = {}
		for i, item in ipairs(alt.mail.items) do
			if item and item.ID then
				if not mailByID[item.ID] then
					mailByID[item.ID] = {}
				end
				table.insert(mailByID[item.ID], { index = i, Count = item.Count, Link = item.Link })
			end
		end
		for itemID, entries in pairs(mailByID) do
			if #entries > 1 then
				TOGBankClassic_Output:Debug("MAIL", "[MAIL-003] BEFORE dedup: mail item ID %d has %d entries", itemID, #entries)
				for _, entry in ipairs(entries) do
					TOGBankClassic_Output:Debug("MAIL", "[MAIL-003]   index=%d Count=%d Link=%s", entry.index, entry.Count, entry.Link or "nil")
				end
			end
		end
		
		-- Mail items are now stored as array (same as bank/bags)
		local deduped = TOGBankClassic_Item:Aggregate(alt.mail.items, nil)
		for _, item in pairs(deduped) do
			table.insert(mailItems, item)
		end
		TOGBankClassic_Output:Debug("MAIL", "[MAIL-003] AFTER dedup: mail has %d entries", #mailItems)
		-- Write deduplicated mail items back to source to fix SV file
		alt.mail.items = mailItems
	end
	
	-- Aggregate all three sources
	TOGBankClassic_Output:Debug("MAIL", "[MAIL-003] Aggregating: bank=%d, bags=%d, mail=%d", #bankItems, #bagItems, #mailItems)
	local aggregated = TOGBankClassic_Item:Aggregate(bankItems, bagItems)
	TOGBankClassic_Output:Debug("MAIL", "[MAIL-003] After bank+bags aggregate: %d unique items", TOGBankClassic_Item:CountItems(aggregated))
	aggregated = TOGBankClassic_Item:Aggregate(aggregated, mailItems)
	TOGBankClassic_Output:Debug("MAIL", "[MAIL-003] After adding mail: %d unique items", TOGBankClassic_Item:CountItems(aggregated))
	
	-- Convert back to array format and filter out corrupted low-ID items
	-- Valid Classic WoW item IDs start around 2000+, items with ID < 100 are from old bugs
	alt.items = {}
	local filteredCount = 0
	for _, item in pairs(aggregated) do
		if item.ID and item.ID >= 100 then
			table.insert(alt.items, item)
		else
			filteredCount = filteredCount + 1
			TOGBankClassic_Output:Debug("BANK", "Filtered out corrupted item with invalid ID: %s", tostring(item.ID))
		end
	end
	
	if filteredCount > 0 then
		TOGBankClassic_Output:Debug("BANK", "Removed %d corrupted items from aggregated data", filteredCount)
	end
	
	TOGBankClassic_Output:Debug("BANK", "Recalculated aggregated items: bank=%d, bags=%d, mail=%d, total=%d (filtered %d)",
		#bankItems, #bagItems, #mailItems, #alt.items, filteredCount)
end