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
		return nil
	end
	
	local mailItems = {}
	local numItems, totalItems = GetInboxNumItems()
	
	TOGBankClassic_Output:Debug("MAIL", "Scanning mailbox: %d items", numItems)
	
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
					
					-- Initialize item entry if first occurrence
					if not mailItems[itemID] then
						mailItems[itemID] = {
							id = itemID,
							name = name,
							link = link,
							count = 0,
							sources = {}
						}
					end
					
					-- Add to total count
					mailItems[itemID].count = mailItems[itemID].count + count
					
					-- Track source details
					table.insert(mailItems[itemID].sources, {
						index = i,
						count = count,
						sender = sender or "Unknown",
						daysLeft = daysLeft or 0,
						subject = subject or ""
					})
					
					TOGBankClassic_Output:Debug("MAIL", "Found %dx %s from %s (%d days left)", 
						count, name, sender or "Unknown", daysLeft or 0)
				end
			end
		elseif hasItem and CODAmount > 0 then
			TOGBankClassic_Output:Debug("MAIL", "Skipping COD mail from %s (COD: %d copper)", 
				sender or "Unknown", CODAmount)
		end
	end
	
	-- Build result structure
	local result = {
		slots = 50,  -- Mail slots are always 50 in Classic
		items = mailItems,
		version = time(),
		lastScan = time()
	}
	
	-- Count unique items
	local itemCount = 0
	for _ in pairs(mailItems) do
		itemCount = itemCount + 1
	end
	
	TOGBankClassic_Output:Debug("MAIL", "Mail scan complete: %d unique items across %d mail", 
		itemCount, numItems)
	
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
	IsMailDataStale(alt)
	Checks if mail scan data is too old to be reliable
	
	Parameters:
		alt - alt data structure
	
	Returns:
		boolean - true if data is stale (>1 hour old)
]]
function TOGBankClassic_MailInventory:IsMailDataStale(alt)
	if not alt or not alt.mail or not alt.mail.lastScan then
		return true
	end
	
	local age = time() - alt.mail.lastScan
	local STALE_THRESHOLD = 3600  -- 1 hour
	
	return age > STALE_THRESHOLD
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
