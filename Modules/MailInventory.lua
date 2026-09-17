--[[
	Mail Inventory Module
	Scans and caches mailbox inventory when mail is accessed
	Follows the same pattern as Bank.lua (scan on close, not on open)
]]

TOGBankClassic_MailInventory = {}

-- Flag to track if mail was accessed this session
TOGBankClassic_MailInventory.hasUpdated = false

--- LINK-AUDIT-001 step 5 (docs/LINK_AUDIT.md 3.3): the inbox is one of the two EDGES where the
--- client hands over a link. Each attachment is parsed once (Scan.parseLink) into a record --
--- `{ id, count, suffix, enchant }` -- and everything downstream keys on `Record.key`, the store's
--- own identity. A mail row used to be stored `{ ID, Count }` with the suffix thrown away, so a
--- "Dreadblade of the Bear" in the inbox was a different item from the same weapon in the bags,
--- and the log's `from` (keyed `id:0`) could never match the deposit the bags-row produced.
---@param i number mail index
---@param j number attachment index
---@return table|nil record nil when the slot is empty or the client has no link for it yet
local function attachmentRecord(i, j)
	local name, itemID, _, count = GetInboxItem(i, j)
	if not (itemID and name) then return nil end
	local Record, Scan = TOGBankClassic_Inventory_Record, TOGBankClassic_Inventory_Scan
	local enchant, suffix = Scan.parseLink(GetInboxItemLink(i, j))
	return Record.new(itemID, count or 1, suffix, enchant)
end

--- Who sent how many of each attachment now in the inbox, keyed by `Record.key` -- the key the
--- bank log's diff uses, so a taken attachment can be matched to the rise it causes in the bags.
--- COD mail is skipped: its items cannot be taken without payment, and are not the guild's until
--- they are.
---@return table senders { [Record.key] = { [sender] = count } }
local function readInboxSenders()
	local senders = {}
	local Record = TOGBankClassic_Inventory_Record
	for i = 1, (GetInboxNumItems() or 0) do
		local _, _, sender, _, _, CODAmount, _, hasItem = GetInboxHeaderInfo(i)
		if hasItem and (CODAmount or 0) == 0 then
			for j = 1, ATTACHMENTS_MAX_RECEIVE do
				local rec = attachmentRecord(i, j)
				if rec then
					local key = Record.key(rec)
					local who = sender or "Unknown"
					senders[key] = senders[key] or {}
					senders[key][who] = (senders[key][who] or 0) + Record.count(rec)
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
TOGBankClassic_MailInventory.takenSenders = {}    -- { [Record.key] = { [sender] = count } } since the last mint

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

--- Scan the current mailbox. Called from Bank:Scan() when mail was accessed (hasUpdated = true).
---
--- LINK-AUDIT-001 step 5: returns RECORDS, aggregated by `Record.key` (Record.aggregate), so the
--- mail source is the same shape as the bag and bank sources and a suffixed attachment keeps its
--- suffix and enchant all the way into the store, the hashes and the log. The legacy
--- `{ ID, Count, Link, ItemString }` rows, and the two link parsers that keyed them, are gone.
---@return table|nil { slots = { count, total }, items = { record, ... }, senders, version, lastScan }
---   nil if mail was not accessed
function TOGBankClassic_MailInventory:ScanMailInventory()
	-- Only scan if mail was accessed this session
	if not self.hasUpdated then
		TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] ScanMailInventory called but hasUpdated=false, returning nil")
		return nil
	end

	local Record = TOGBankClassic_Inventory_Record
	-- Who sent what, as of this read (readInboxSenders, the one spelling). LOG-MAIL-001: NOT the
	-- log's `from` any more -- that is TakenSenders, what LEFT the inbox -- but kept in the result
	-- for a reader of the scan.
	local senders = readInboxSenders()
	local numItems = GetInboxNumItems()

	TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Starting mailbox scan: %d mail messages", numItems)

	local records = {}
	for i = 1, numItems do
		-- GetInboxHeaderInfo: packageIcon, stationeryIcon, sender, subject, money, CODAmount,
		-- daysLeft, hasItem, wasRead, wasReturned, textCreated, canReply, isGM. Three are read.
		local _, _, sender, _, _, CODAmount, _, hasItem = GetInboxHeaderInfo(i)

		-- Skip COD mail (can't take items without payment)
		if hasItem and CODAmount == 0 then
			for j = 1, ATTACHMENTS_MAX_RECEIVE do
				local rec = attachmentRecord(i, j)
				if rec then
					records[#records + 1] = rec
					TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-003] Attachment %d/%d: %s x%d",
						i, j, Record.key(rec), Record.count(rec))
				end
			end
		elseif hasItem and CODAmount > 0 then
			TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Skipping COD mail from %s (COD: %d copper)",
				sender or "Unknown", CODAmount)
		end
	end

	-- One record per identity, as the bag and bank sources are (Record.aggregate merges by key).
	local byKey = Record.aggregate(records)
	local mailItems = {}
	for _, rec in pairs(byKey) do mailItems[#mailItems + 1] = rec end
	table.sort(mailItems, function(a, b) return Record.key(a) < Record.key(b) end)

	local result = {
		slots = { count = #mailItems, total = 50 },  -- Match bank/bags structure
		items = mailItems,
		senders = senders,  -- { [Record.key] = { [sender] = count } }, for a reader of the scan
		version = GetServerTime(),
		lastScan = GetServerTime()
	}

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
