--[[
	Mail Inventory Module
	Scans and caches mailbox inventory when mail is accessed
	Follows the same pattern as Bank.lua (scan on close, not on open)
]]

TOGBankClassic_MailInventory = {}

-- Flag to track if mail was accessed this session
TOGBankClassic_MailInventory.hasUpdated = false

--[[
	ScanMailInventory()
	Scans the current mailbox and returns structured mail inventory data
	Called from Bank:Scan() when mail was accessed (hasUpdated = true)
	
	Returns:
		table with structure:
			{
				slots = 50,
				items = {
					[itemID] = {
						id = itemID,
						name = "Item Name",
						link = "|cffffffff|Hitem:...",
						count = total count across all mail,
						sources = {
							{ index, count, sender, daysLeft, subject }
						}
					}
				},
				version = timestamp,
				lastScan = timestamp
			}
		nil if mail was not accessed
]]
function TOGBankClassic_MailInventory:ScanMailInventory()
	-- Only scan if mail was accessed this session
	if not self.hasUpdated then
		TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] ScanMailInventory called but hasUpdated=false, returning nil")
		return nil
	end
	
	-- Use same structure as bank/bags: aggregate by composite key, store as array
	local mailItemsTable = {}
	local numItems, totalItems = GetInboxNumItems()
	
	TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Starting mailbox scan: %d mail messages", numItems)
	
	for i = 1, numItems do
		local packageIcon, stationeryIcon, sender, subject, money, CODAmount, 
		      daysLeft, hasItem, wasRead, wasReturned, textCreated, canReply, 
		      isGM = GetInboxHeaderInfo(i)
		
		-- Skip COD mail (can't take items without payment)
		if hasItem and CODAmount == 0 then
			for j = 1, ATTACHMENTS_MAX_RECEIVE do
				local name, itemID, itemTexture, count, quality, canUse = GetInboxItem(i, j)
				
				if itemID and name then
					local link = GetInboxItemLink(i, j)
					
					-- Conditionally include Link based on item class
					-- Gear (weapons/armor) needs FULL Link for suffix differentiation
					-- Consumables/trade goods don't need Link (saves bandwidth in d3 sync)
					local storageLink = nil
					if link and TOGBankClassic_Item:NeedsLink(link) then
						storageLink = link  -- Store FULL link for gear
					end
					
					-- Use NORMALIZED key for deduplication (strips unique instance ID)
					-- This allows identical items to merge even if they have different instance IDs
					local itemKey = TOGBankClassic_Item:GetItemKey(link)
					local key = tostring(itemID) .. itemKey
					
					if mailItemsTable[key] then
						-- Item already exists, add to count
						local item = mailItemsTable[key]
						mailItemsTable[key] = { ID = item.ID, Count = item.Count + count, Link = item.Link or storageLink }
						TOGBankClassic_Output:Debug("MAIL", "[MAIL-003] Item %s: MERGED (key=%s) added %d, total now %d", 
							name, key, count, mailItemsTable[key].Count)
					else
						-- New item
						mailItemsTable[key] = { ID = itemID, Count = count, Link = storageLink }
						TOGBankClassic_Output:Debug("MAIL", "[MAIL-003] New item in mailbox: %s (ID: %d, Count: %d, Link: %s, Key: %s)", 
							name, itemID, count, storageLink and "preserved" or "stripped", key)
					end
				end
			end
		elseif hasItem and CODAmount > 0 then
			TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Skipping COD mail from %s (COD: %d copper)", 
				sender or "Unknown", CODAmount)
		end
	end
	
	-- Convert to array format (same as bank/bags)
	local mailItems = {}
	for _, item in pairs(mailItemsTable) do
		table.insert(mailItems, item)
	end
	
	-- DEBUG: Verify mailItems is a proper sequential array
	print(string.format(">>> MailInventory: Created array with %d items <<<", #mailItems))
	for i = 1, math.min(3, #mailItems) do
		if mailItems[i] then
			print(string.format("    [%d] ID=%s, Count=%s", i, tostring(mailItems[i].ID), tostring(mailItems[i].Count)))
		end
	end
	
	-- Build result structure (match bank/bags format for consistency)
	local result = {
		slots = { count = #mailItems, total = 50 },  -- Match bank/bags structure
		items = mailItems,  -- Now an array like bank/bags
		version = GetServerTime(),
		lastScan = GetServerTime()
	}
	
	-- DEBUG: Verify result structure
	print(string.format(">>> MailInventory: result.items type=%s, length=%d <<<", type(result.items), #result.items))
	print(string.format(">>> MailInventory: result.slots.count=%d <<<", result.slots.count))
	
	TOGBankClassic_Output:Debug("MAIL", "[MAIL-002] Mail scan complete: %d unique items across %d mail messages", 
		#mailItems, numItems)
	
	return result
end

--[[
	GetItemsInMail(itemID)
	Returns list of alts that have the specified item in their mail
	
	Parameters:
		itemID - numeric item ID to search for
	
	Returns:
		array of { name, count, lastScan }
]]
function TOGBankClassic_MailInventory:GetItemsInMail(itemID)
	local alts = {}
	
	if not TOGBankClassic_Guild.Info or not TOGBankClassic_Guild.Info.alts then
		return alts
	end
	
	for name, alt in pairs(TOGBankClassic_Guild.Info.alts) do
		if alt.mail and alt.mail.items and alt.mail.items[itemID] then
			table.insert(alts, {
				name = name,
				count = alt.mail.items[itemID].count,
				lastScan = alt.mail.lastScan or 0
			})
		end
	end
	
	return alts
end

--[[
	GetTotalInMail(itemID)
	Returns total count of item across all alts' mail
	
	Parameters:
		itemID - numeric item ID to search for
	
	Returns:
		number - total count
]]
function TOGBankClassic_MailInventory:GetTotalInMail(itemID)
	local total = 0
	local alts = self:GetItemsInMail(itemID)
	
	for _, alt in ipairs(alts) do
		total = total + alt.count
	end
	
	return total
end

--[[
	GetMailDataAge(alt)
	Returns age of mail scan data in seconds
	
	Parameters:
		alt - alt data structure
	
	Returns:
		number - age in seconds, or nil if no data
]]
function TOGBankClassic_MailInventory:GetMailDataAge(alt)
	if not alt or not alt.mail or not alt.mail.lastScan then
		return nil
	end
	
	return time() - alt.mail.lastScan
end

--[[
	HasMailInventory(alt)
	Checks if alt has mail inventory data
	
	Parameters:
		alt - alt data structure
	
	Returns:
		boolean - true if has mail data with items
]]
function TOGBankClassic_MailInventory:HasMailInventory(alt)
	if not alt or not alt.mail or not alt.mail.items then
		return false
	end
	
	-- Check if there are any items
	for _ in pairs(alt.mail.items) do
		return true
	end
	
	return false
end
