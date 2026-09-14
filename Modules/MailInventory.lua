--[[
	Mail Inventory Module
	Scans and caches mailbox inventory when mail is accessed
	Follows the same pattern as Bank.lua (scan on close, not on open)
]]

TOGBankClassic_MailInventory = {}

-- Flag to track if mail was accessed this session
TOGBankClassic_MailInventory.hasUpdated = false

--- Who sent how many of each attachment now in the inbox, keyed the way the bank log keys a row
--- (`id:suffix`; a mail row is stored suffix-less, so `id:0`). COD mail is skipped: its items cannot
--- be taken without payment, and are not the guild's until they are.
---@return table senders { ["id:0"] = { [sender] = count } }
local function readInboxSenders()
	local senders = {}
	for i = 1, (GetInboxNumItems() or 0) do
		local _, _, sender, _, _, CODAmount, _, hasItem = GetInboxHeaderInfo(i)
		if hasItem and (CODAmount or 0) == 0 then
			for j = 1, ATTACHMENTS_MAX_RECEIVE do
				local name, itemID, _, count = GetInboxItem(i, j)
				if itemID and name then
					local key = tostring(itemID) .. ":0"
					local who = sender or "Unknown"
					senders[key] = senders[key] or {}
					senders[key][who] = (senders[key][who] or 0) + (count or 1)
				end
			end
		end
	end
	return senders
end

-- LOG-MAIL-001: WHAT LEFT THE INBOX SINCE THE LAST MINT, by sender. The operator: "the log should
-- only show the 'deposit' when it's taken from the mail, not when it's scanned in the inbox. it may
-- sit there and be sent back." The bank log diffs what the banker HOLDS (bags + bank), so a take is
-- the moment an item rises there -- and the sender of that item is known only from the inbox read
-- BEFORE the take. Every MAIL_INBOX_UPDATE reads the inbox (NoteInbox); an attachment counted in one
-- read and missing from the next left the inbox between them, and its sender and count are kept
-- here until Bank:MintVersion attributes the rise and clears it (TakenSenders / ClearTakenSenders).
-- Session-only: a take never mints across a reload without a scan in between.
TOGBankClassic_MailInventory.inboxSeen    = nil   -- the last read, or nil while the mailbox is closed
TOGBankClassic_MailInventory.takenSenders = {}    -- { ["id:0"] = { [sender] = count } } since the last mint

--- Read the inbox (on MAIL_INBOX_UPDATE) and record what left it since the previous read.
function TOGBankClassic_MailInventory:NoteInbox()
	local cur = readInboxSenders()
	local prev = self.inboxSeen
	if prev then
		local taken = self.takenSenders
		for key, bySender in pairs(prev) do
			for sender, n in pairs(bySender) do
				local now = cur[key] and cur[key][sender] or 0
				if now < n then
					taken[key] = taken[key] or {}
					taken[key][sender] = (taken[key][sender] or 0) + (n - now)
				end
			end
		end
	end
	self.inboxSeen = cur
end

--- The mailbox closed: the next open starts a fresh comparison (what happens to the inbox while
--- it is closed -- a return, an expiry -- is not a take and is not observed).
function TOGBankClassic_MailInventory:CloseInbox()
	self.inboxSeen = nil
end

--- What left the inbox since the last mint, for Log:AttributeChanges. nil when nothing did.
---@return table|nil
function TOGBankClassic_MailInventory:TakenSenders()
	return next(self.takenSenders) and self.takenSenders or nil
end

--- The mint attributed what it could; what was taken is spent.
function TOGBankClassic_MailInventory:ClearTakenSenders()
	self.takenSenders = {}
end

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
		TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] ScanMailInventory called but hasUpdated=false, returning nil")
		return nil
	end

	-- Use same structure as bank/bags: aggregate by composite key, store as array
	local mailItemsTable = {}
	-- Who sent what, as of this read (readInboxSenders, the one spelling). LOG-MAIL-001: NOT the
	-- log's `from` any more -- that is TakenSenders, what LEFT the inbox -- but kept in the result
	-- for a reader of the scan.
	local senders = readInboxSenders()
	local numItems = GetInboxNumItems()

	TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Starting mailbox scan: %d mail messages", numItems)

	for i = 1, numItems do
		-- GetInboxHeaderInfo: packageIcon, stationeryIcon, sender, subject, money, CODAmount,
		-- daysLeft, hasItem, wasRead, wasReturned, textCreated, canReply, isGM. Three are read.
		local _, _, sender, _, _, CODAmount, _, hasItem = GetInboxHeaderInfo(i)

		-- Skip COD mail (can't take items without payment)
		if hasItem and CODAmount == 0 then
			for j = 1, ATTACHMENTS_MAX_RECEIVE do
				-- GetInboxItem: name, itemID, itemTexture, count, quality, canUse.
				local name, itemID, _, count = GetInboxItem(i, j)

				if itemID and name then
					local link = GetInboxItemLink(i, j)
					-- DO NOT fall back to GetItemInfo(itemID) for the link.
					-- GetItemInfo by numeric ID returns the BASE item link (no suffix/enchant),
					-- which is wrong for suffixed weapons/armor (e.g. yields "Warlords' Axe"
					-- instead of "Warlords' Axe of the Wolf"). Storing the wrong link creates
					-- a distinct key that Aggregate cannot dedup against the correct suffixed
					-- bank entry, producing a ghost plain-weapon duplicate row.
					-- Leaving link=nil lets Aggregate's ID-based linkless merge fold the count
					-- into the correct existing bank/bags entry instead.
					local itemString = link and TOGBankClassic_Item:GetItemString(link) or nil

					-- Always store the full link, exactly like Bank.lua's ScanBag().
					-- Link-stripping (for bandwidth) happens at transmission time in
					-- StripItemLinks / StripDeltaLinks, where NeedsLink() is called with
					-- the item already guaranteed to be in the client cache.
					-- Pre-stripping here caused gear links to be permanently lost when
					-- the item wasn't cached yet at scan time.
					local storageLink = link
					-- Normalize: strip "item:" prefix so format matches StripItemLinks output.
					-- GetItemString returns "item:4306:...", but ReconstructItemLink embeds as
					-- |Hitem:%s, so storing with the prefix produces double "item:item:" which
					-- makes SetHyperlink silently fail and shows no tooltip.
					local storageItemString = itemString and (itemString:match("^item:(.+)$") or itemString) or nil

					-- Use NORMALIZED key for deduplication (strips unique instance ID)
					-- This allows identical items to merge even if they have different instance IDs
					local itemKey = TOGBankClassic_Item:GetItemKey(link)
					local key = tostring(itemID) .. itemKey

					if mailItemsTable[key] then
						-- Item already exists, add to count
						local item = mailItemsTable[key]
						mailItemsTable[key] = {
							ID = item.ID,
							Count = item.Count + count,
							Link = item.Link or storageLink,
							ItemString = item.ItemString or storageItemString,
						}
						TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-003] Item %s: MERGED (key=%s) added %d, total now %d",
							name, key, count, mailItemsTable[key].Count)
					else
						-- New item
						mailItemsTable[key] = {
							ID = itemID,
							Count = count,
							Link = storageLink,
							ItemString = storageItemString,
						}
						TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-003] New item in mailbox: %s (ID: %d, Count: %d, Link: %s, Key: %s)",
							name, itemID, count, storageLink and "yes" or "no", key)
					end
				end
			end
		elseif hasItem and CODAmount > 0 then
			TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Skipping COD mail from %s (COD: %d copper)",
				sender or "Unknown", CODAmount)
		end
	end

	-- Convert to array format (same as bank/bags)
	local mailItems = {}
	for _, item in pairs(mailItemsTable) do
		table.insert(mailItems, item)
	end

	-- Verify mailItems is a proper sequential array
	TOGBankClassic_Output:Debug("MAIL", "SCAN", "Created mail items array with %d items", #mailItems)
	for i = 1, math.min(3, #mailItems) do
		if mailItems[i] then
			TOGBankClassic_Output:Debug("MAIL", "SCAN", "  [%d] ID=%s, Count=%s", i, tostring(mailItems[i].ID), tostring(mailItems[i].Count))
		end
	end

	-- Build result structure (match bank/bags format for consistency)
	local result = {
		slots = { count = #mailItems, total = 50 },  -- Match bank/bags structure
		items = mailItems,  -- Now an array like bank/bags
		senders = senders,  -- step 4: { ["id:0"] = { [sender] = count } }, for the bank log's `from`
		version = GetServerTime(),
		lastScan = GetServerTime()
	}

	-- Verify result structure
	TOGBankClassic_Output:Debug("MAIL", "SCAN", "Mail result structure: items type=%s, length=%d", type(result.items), #result.items)
	TOGBankClassic_Output:Debug("MAIL", "SCAN", "Mail result slots.count=%d", result.slots.count)

	TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Mail scan complete: %d unique items across %d mail messages",
		#mailItems, numItems)

	return result
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
	if not alt or not alt.mail or not alt.mail.lastScan or alt.mail.lastScan == 0 then
		return nil
	end

	return time() - alt.mail.lastScan
end
