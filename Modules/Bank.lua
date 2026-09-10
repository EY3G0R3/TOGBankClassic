---@class TOGBankClassic_Bank
-- BANK-002: `{ ... }` at file scope captures the addon varargs the client passes in, so the
-- module table was born holding [1]="TOGBankClassic" and [2]=<addon namespace table>, with
-- #TOGBankClassic_Bank == 2. Harmless while nothing iterated it, and a trap for the first
-- ipairs or `#` over the module table -- which would have failed far from this line.
TOGBankClassic_Bank = {}

local function HasUpdated()
	return TOGBankClassic_Bank.hasUpdated
end

local function IsBankAvailable()
	local _, bagType = C_Container.GetContainerNumFreeSlots(BANK_CONTAINER)
	return bagType ~= nil
end

-- INV2-WIRE-001 WAS TRIED HERE AND REVERTED, 2026-09-09. Read this before attempting it again.
--
-- The plan was: delete this second container walk and build the legacy shape from Scan:ScanAll's
-- output, so `/togbank dev compare` diffs ONE walk instead of two taken microseconds apart. It was
-- implemented, and `wiring_spec`'s "still completes the legacy scan when the V2 mirror throws"
-- turned red -- correctly.
--
-- WHAT THE COLLAPSE COSTS: one walk means one point of failure. With the legacy shape derived from
-- Scan:ScanAll, any fault in the V2 scanner stops the legacy scan too -- and the legacy store is
-- what every character without a V2 record still reads. A bug in new code would freeze the whole
-- guild's inventory rather than just the new path. Two independent walks is what makes that
-- impossible, and that spec was written deliberately to hold the property.
--
-- WHAT IT BUYS, measured against that: the todo's own words are that a divergence caused by a stack
-- moving between the two walks is "close to theoretical" -- they are microseconds apart inside one
-- Bank:Scan call with no yield. So the trade is a real robustness guarantee for a theoretical
-- consistency gain. Not worth it.
--
-- If it is ever revisited, the thing to solve first is: what should happen to the legacy store when
-- the shared scan throws? "Leave it as it was" silently freezes inventory; "clear it" loses data.
-- Until there is a good answer, two walks is the right shape.

local function ScanBag(bag, slots)
	local count = 0
	local items = {}
	for slot = 1, slots do
		local itemInfo = C_Container.GetContainerItemInfo(bag, slot)
		if itemInfo then
			local itemCount = itemInfo.stackCount
			local itemLink = itemInfo.hyperlink
			local itemID = itemInfo.itemID
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
		local slots = C_Container.GetContainerNumSlots(bag)
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
		local slots = C_Container.GetContainerNumSlots(bag)
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

-- SCAN-001: every early return below logs under BANK.GATE. These five gates used to fail
-- silently, so a character that never scanned gave no signal at all -- the Inventory tab
-- just sat on "Loading items..." with no way to tell which precondition was unmet.
function TOGBankClassic_Bank:Scan()
	if TOGBankClassic_Bank.eventsRegistered then
		if not HasUpdated() then
			TOGBankClassic_Output:Debug("BANK", "GATE", "Scan skipped: nothing marked dirty (hasUpdated=false)")
			return
		end
	end

	local info = TOGBankClassic_Guild.Info
	if not info then
		TOGBankClassic_Output:Debug("BANK", "GATE", "Scan skipped: Guild.Info is nil (guild data not loaded yet)")
		return
	end

	-- Normalize player name to ensure consistent keying in saved DB
	local player = TOGBankClassic_Guild:GetNormalizedPlayer()

	local isBank = false
	local banks = TOGBankClassic_Guild:GetBanks()
	if banks == nil then
		TOGBankClassic_Output:Debug("BANK", "GATE",
			"Scan skipped: no bankers found in guild notes (roster may not be loaded yet)")
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
		TOGBankClassic_Output:Debug("BANK", "GATE",
			"Scan skipped: '%s' is not in the banker list (%d banker(s) known) - check for 'gbank' in the guild/officer note",
			tostring(player), #banks)
		return
	end
	if not TOGBankClassic_Options:GetBankEnabled() then
		TOGBankClassic_Output:Debug("BANK", "GATE",
			"Scan skipped: bank scanning is disabled for '%s' (Options -> Bank -> Enable)", tostring(player))
		return
	end

	local alt = {}
	-- Load from aggregate view (info.alts)
	if info.alts and info.alts[player] then
		alt = info.alts[player]
	end

	-- TWO WALKS, DELIBERATELY. See the INV2-WIRE-001 note at the top of this file: collapsing this
	-- into Scan:ScanAll was tried and reverted, because it makes a fault in the V2 scanner stop the
	-- legacy scan that every character without a V2 record still reads.
	local total = 0
	local numslots = 0

	local scannedVault = false
	if IsBankAvailable() then
		scannedVault = true
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

	-- INV2-MAIL-001: the V2 mirror used to run HERE, and it fed the store from Scan:ScanAll alone
	-- -- which walks bags and bank and contains no mail at all. So the V2 store was missing a
	-- source the legacy aggregate has had since MAIL-002, and with inventoryV2 on a banker's mail
	-- silently stopped being counted. It surfaced as ONE tooltip line showing two different
	-- numbers for the same item: 68 on the banker, where V2 was populated, and 71 on a non-banker,
	-- where V2 has no record for that alt so the legacy fallback ran. The mirror now runs after
	-- the mail scan, below, so it can include it.

	-- SCAN-001: counterpart to the BANK.GATE lines above -- confirms a scan actually ran
	-- and shows whether the vault half was included (it is skipped away from a bank NPC).
	TOGBankClassic_Output:Debug("BANK", "SCAN",
		"Scanned '%s': %d item(s) across %d slot(s) (bank vault %s)",
		tostring(player), total, numslots,
		scannedVault and "included" or "skipped - not at a bank")

	-- Scan mail inventory if mail was accessed
	TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Bank:Scan() for player '%s', hasUpdated=%s",
		player, tostring(TOGBankClassic_MailInventory.hasUpdated))

	if TOGBankClassic_MailInventory.hasUpdated then
		TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Starting mail scan for player '%s'", player)

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

			TOGBankClassic_Output:Debug("MAIL", "STORE", "[MAIL-002] Replacing mail data for '%s': old=%d items, new=%d items",
				player, previousItemCount, itemCount)

			alt.mail = mailData
			TOGBankClassic_Output:Debug("MAIL", "STORE", "[MAIL-002] ASSIGNED alt.mail with %d items, version=%s, lastScan=%s",
				#mailData.items, tostring(mailData.version), tostring(mailData.lastScan))

			-- Verify assignment worked
			if alt.mail then
				TOGBankClassic_Output:Debug("MAIL", "STORE", "Confirmed: alt.mail exists with %d items", #alt.mail.items)
			else
				TOGBankClassic_Output:Debug("MAIL", "STORE", "ERROR: alt.mail is nil after assignment!")
			end
		end

		TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Clearing hasUpdated flag after scan")
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
		TOGBankClassic_Output:Debug("DATABASE", "STORE", "SOURCES - bank.items (first 3): %s", table.concat(bankSample, ", "))
	end
	if #bagItems > 0 then
		local bagSample = {}
		for i = 1, math.min(3, #bagItems) do
			local item = bagItems[i]
			if item then
				table.insert(bagSample, string.format("%s:%d", item.ID or "?", item.Count or 0))
			end
		end
		TOGBankClassic_Output:Debug("DATABASE", "STORE", "SOURCES - bags.items (first 3): %s", table.concat(bagSample, ", "))
	end
	if #mailItems > 0 then
		local mailSample = {}
		for i = 1, math.min(3, #mailItems) do
			local item = mailItems[i]
			if item then
				table.insert(mailSample, string.format("%s:%d", item.ID or "?", item.Count or 0))
			end
		end
		TOGBankClassic_Output:Debug("DATABASE", "STORE", "SOURCES - mail.items (first 3): %s", table.concat(mailSample, ", "))
	end

	-- Aggregate all three sources (returns table with composite keys, deduplicates by ID)
	local aggregated = TOGBankClassic_Item:Aggregate(bankItems, bagItems)
	aggregated = TOGBankClassic_Item:Aggregate(aggregated, mailItems)

	-- Convert back to array format for storage/sync/display
	alt.items = {}
	for _, item in pairs(aggregated) do
		table.insert(alt.items, item)
	end

	-- INV2: mirror this scan into the V2 tuple store.
	--
	-- Additive on purpose. The legacy path above is untouched and still authoritative; this writes
	-- into a SEPARATE SavedVariable so the two can be compared on live data
	-- (/togbank dev compare) before anything reads from V2. Nothing here feeds back into `alt`, so
	-- a fault cannot corrupt the legacy record.
	--
	-- It runs HERE, after the aggregate, rather than beside the container walk -- INV2-MAIL-001.
	-- Mail can only be read while the mailbox is open, so it arrives through MailInventory rather
	-- than a container scan, and a mirror placed next to the bag walk cannot see it. Running after
	-- the aggregate means the V2 store gets the same three sources the legacy record has.
	--
	-- NOTE this is deliberately NOT the "one walk, two writes" arrangement from INVENTORY_V2.md
	-- §6.1 -- that applies once V2 is the writer and dualWrite maintains the legacy DB. Here the
	-- legacy path is still the writer, so V2 re-walks the containers (INV2-WIRE-001). The cost is
	-- one extra container pass while inventoryV2 is off-by-default and opt-in.
	if TOGBankClassic_Switches and TOGBankClassic_Switches:IsEnabled("inventoryV2") then
		local ok, err = pcall(function()
			local Store  = TOGBankClassic_Inventory_Store
			local Scan   = TOGBankClassic_Inventory_Scan
			local Record = TOGBankClassic_Inventory_Record
			if not (Store and Scan and Record) then return end

			-- Per source, not one flat set -- INV2-VAULT-001. Bags and mail are readable
			-- anywhere; the vault is readable only at a banker. Writing them as separate
			-- sources lets the store keep the stored vault while still taking today's bags
			-- and mail. The previous arrangement skipped the ENTIRE write to protect the
			-- vault, so a mailbox opened away from a bank NPC updated the legacy record and
			-- never reached V2: 71 on a character reading the legacy fallback, 68 on the
			-- banker reading its own frozen V2 record, for the same item.
			-- ONE call, so `dualWrite` keeps a reader and the legacy shape still comes from the
			-- same walk. Splitting this into ScanBags + ScanBank orphaned ScanAll and left the
			-- switch read only by dead code -- caught by switches_spec's wiring guard.
			local result = Scan:ScanAll()

			-- Mail, as tuples. MailInventory stores linkless {ID, Count} rows, which is exactly
			-- what a tuple wants -- no link to parse, and suffix/enchant are unknowable for a mail
			-- attachment because GetInboxItem does not report them.
			local mailRecords, mailSkipped = {}, 0
			for _, item in ipairs(mailItems) do
				local rec = Record.new(item.ID, item.Count or 1)
				if rec then
					mailRecords[#mailRecords + 1] = rec
				else
					mailSkipped = mailSkipped + 1
				end
			end

			-- `mail` is always supplied, even when empty: an emptied mailbox must clear the
			-- source rather than leave yesterday's attachments counted. Same for bags. Only
			-- `bank` is conditional -- ScanAll omits it when the vault was unreadable, and an
			-- omitted source is KEPT by the store rather than cleared.
			local sources = { bags = result.sources.bags, mail = mailRecords }
			if result.sources.bank then sources.bank = result.sources.bank end

			local stored, skipped = Store:SetAltSources(info.name, player, sources, result.money)
			TOGBankClassic_Output:Debug("BANK", "SCAN",
				"[INV2] stored %d record(s) for %s (%d skipped, vault %s, mail %d/%d bad)",
				stored, player, skipped,
				result.bankScanned and "rescanned" or "kept - out of reach",
				#mailRecords, mailSkipped)
		end)
		if not ok then
			-- Loud, but non-fatal: V2 is not authoritative yet, so a fault here must not stop the
			-- legacy scan from completing and syncing.
			TOGBankClassic_Output:Error("[INV2] scan mirror failed (legacy scan unaffected): %s",
				tostring(err))
		end
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
		TOGBankClassic_Output:Debug("DATABASE", "STORE", "After Bank:Scan aggregation - First 5 items: %s", table.concat(scanSample, ", "))
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

	-- Compute a hash of the current inventory state (SYNC-006: use aggregated alt.items)
	--
	-- HASH-REV-001: change detection runs on REVISION 2, the accurate identity. Revision 1 cannot
	-- see suffix or enchant, so gating on it would reproduce audit finding 31 exactly -- a banker
	-- swapping one suffix variant for another at the same count would not bump the version and no
	-- delta would ever be computed. Revision 1 is still STAMPED, because it is what unmigrated peers
	-- compare against, but it must never be the gate.
	-- HASH-CANON-003: THE CHANGE DETECTOR IS THE CONTENT HASH, WHICH CARRIES NO DATESTAMP, and the
	-- distinction is what makes a DTS-bearing canon possible at all. A canon differs on every call by
	-- construction, so comparing against it would make every scan look like a change and republish to
	-- the whole guild -- the broadcast storm this work exists to end. Compare content against content;
	-- advance the datestamp only when content moved; then mint the canon over both.
	--
	-- `alt.inventoryContentHash` is absent on records written before this, so the first scan after
	-- upgrading bumps the version once for every character. That is a single self-correcting blip,
	-- not a loop: the second scan has a content hash to compare against and goes quiet.
	local currentHash = TOGBankClassic_Core:ComputeInventoryHash(alt.items, nil, nil, money)
	local previousHash = alt.inventoryContentHash

	if currentHash ~= previousHash then
		-- Inventory changed, update version timestamp
		local updatedAt = GetServerTime()
		alt.version = updatedAt
		alt.inventoryUpdatedAt = updatedAt
		-- THE ONE AND ONLY PLACE A CANON IS BORN. Every other site that used to stamp a hash has been
		-- deleted (HASH-CANON-002): the query-path recompute and the no-change adoption. A hash is
		-- written once, here, by the client that actually read the bank, and carried unchanged by
		-- everyone else.
		TOGBankClassic_Core:StampInventoryHashes(alt, alt.items, nil, nil, money, updatedAt)
		TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "Inventory changed for %s, version updated to %d (content: %s, canon: %s)", player, alt.version, tostring(currentHash), tostring(alt.inventoryHashV2))
	else
		-- No changes detected, preserve existing version
		TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "No inventory changes for %s, version unchanged (hash: %s)", player, tostring(currentHash))
		-- Backfill inventoryUpdatedAt if missing
		if not alt.inventoryUpdatedAt and alt.version then
			alt.inventoryUpdatedAt = alt.version
		end
	end

	-- MAIL-012: Compute mailHash for mail-specific change detection
	-- This allows receivers to detect when mail data exists and has changed
	-- mailHash is computed whenever mail is scanned (even if empty) to track all mail state changes
	-- nil mailHash = "never scanned mail" vs hash value = "mail scanned" (could be empty or full)
	if alt.mail and alt.mail.items then
		-- Compute hash even for empty mail - this allows detecting empty→full and full→empty transitions
		local currentMailHash = TOGBankClassic_Core:ComputeInventoryHash(alt.mail.items, nil, nil, nil)
		local previousMailHash = alt.mailHash

		if currentMailHash ~= previousMailHash then
			alt.mailHash = currentMailHash
			TOGBankClassic_Output:Debug("MAIL", "STORE", "[MAIL-012] Mail hash changed for %s: %s (was: %s, %d items)",
				player, tostring(currentMailHash), tostring(previousMailHash), #alt.mail.items)
		else
			-- Ensure mailHash is set even if unchanged (in case it was missing before)
			alt.mailHash = currentMailHash
			TOGBankClassic_Output:Debug("MAIL", "STORE", "[MAIL-012] Mail hash unchanged for %s: %s (%d items)",
				player, tostring(currentMailHash), #alt.mail.items)
		end
	else
		-- No mail data structure (mail was never scanned this session)
		-- Keep previous mailHash if it exists to preserve data across sessions
		TOGBankClassic_Output:Debug("MAIL", "STORE", "[MAIL-012] Mail not scanned this session for %s, preserving existing mailHash", player)
	end

	-- Initialize tables if needed
	if not info.alts then
		info.alts = {}
	end

	-- Log what we're about to save
	if alt.mail then
		TOGBankClassic_Output:Debug("MAIL", "STORE", "alt.mail exists with %d items, type=%s", #alt.mail.items, type(alt.mail))
		-- Handle both old format (number) and new format (table)
		if type(alt.mail.slots) == "table" then
			TOGBankClassic_Output:Debug("MAIL", "STORE", "alt.mail.slots = table with count=%d", alt.mail.slots.count)
		elseif type(alt.mail.slots) == "number" then
			TOGBankClassic_Output:Debug("MAIL", "STORE", "alt.mail.slots = %d (old format, migrating)", alt.mail.slots)
			-- Migrate old format to new format
			local oldSlots = alt.mail.slots
			alt.mail.slots = { count = #alt.mail.items, total = oldSlots }
		else
			TOGBankClassic_Output:Debug("MAIL", "STORE", "alt.mail.slots = nil")
		end
	end

	-- Write to aggregate view (info.alts) for normal use
	info.alts[player] = alt

	if alt.mail then
		TOGBankClassic_Output:Debug("MAIL", "STORE", "Saved mail to info.alts[%s] (%d items)", player, #alt.mail.items)
	else
		TOGBankClassic_Output:Debug("MAIL", "STORE", "No mail data to save for %s", player)
	end

	-- DELTA-021: Save snapshot after scan so next broadcast can compute proper delta
	-- Without this, first broadcast after scan always sends full data (no baseline)
	if info.name then
		TOGBankClassic_Database:SaveSnapshot(info.name, player, alt)
		TOGBankClassic_Output:Debug("DELTA", "APPLY", "Saved snapshot for %s after scan (hash=%s)", player, tostring(alt.inventoryHash))
	end
end

function TOGBankClassic_Bank:HasInventorySpace()
	local total = 0
	for bag = 0, 4 do
		local slots, _ = C_Container.GetContainerNumFreeSlots(bag)
		total = total + slots
	end
	return total > 0
end

-- Find all slots containing an item by name (case-insensitive), optionally filtered by item ID
-- and random-suffix ID.
-- When itemID is provided it takes precedence and the name is only used as a display fallback;
-- this correctly distinguishes same-named variants (e.g. Punctured Voodoo Doll by class).
-- REQ-003: when suffixID is also provided, the slot's own suffix must match too, so random-suffix
-- siblings that share a base itemID ("of the Tiger" vs "of the Monkey") are kept apart. suffixID
-- is nil for plain items and legacy requests, in which case suffix is not considered.
-- Returns: table of {bag, slot, count, link}
function TOGBankClassic_Bank:FindItemsByName(itemName, itemID, suffixID)
	local results = {}
	local targetID = tonumber(itemID) or nil
	local targetSuffix = tonumber(suffixID) or nil
	local hasName = itemName ~= nil and itemName ~= ""

	-- REQ-004: bail only when there is NOTHING to match on. This used to return empty whenever
	-- the name was nil or empty, even with a perfectly good itemID -- which contradicts the
	-- ID-primacy rule REQ-001 established, and silently broke the exact path REQ-001 was added
	-- for: an ID-only lookup for a same-name variant reported the item as not banked at all.
	if not hasName and not targetID then
		return results
	end

	local targetName = hasName and string.lower(itemName) or nil

	for bag = 0, 4 do
		local slots = C_Container.GetContainerNumSlots(bag)
		for slot = 1, slots do
			local itemInfo = C_Container.GetContainerItemInfo(bag, slot)
			if itemInfo and itemInfo.hyperlink then
				local matched
				if targetID then
					-- ID-based match: precise, handles same-name variants
					matched = (itemInfo.itemID == targetID)
				else
					-- Legacy name-based match
					local name = GetItemInfo(itemInfo.hyperlink)
					matched = name and string.lower(name) == targetName
				end
				-- REQ-003: enforce suffix equality when the request carries one.
				if matched and targetSuffix then
					matched = (TOGBankClassic_Item:GetSuffixID(itemInfo.hyperlink) == targetSuffix)
				end
				if matched then
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

-- Count total of named item in bags (0-4), optionally filtered by item ID and random-suffix ID.
-- Returns: totalCount, itemsTable
function TOGBankClassic_Bank:CountItemInBags(itemName, itemID, suffixID)
	local items = self:FindItemsByName(itemName, itemID, suffixID)
	local total = 0
	for _, item in ipairs(items) do
		total = total + item.count
	end
	return total, items
end

function TOGBankClassic_Bank:OnUpdateStart()
	self.hasUpdated = true
end

-- DEBUG-002: these four lines were logged under MAIL/EVENTS. This is the ONLY caller of
-- Bank:Scan on the bag/bank path, so "was a scan attempted at all?" was invisible to the BANK
-- category -- whose own description is "Bank/bag inventory scanning, including why a scan was
-- skipped". Someone enabling exactly the category the question belongs to got silence, which
-- reads as "no event fired" when it may equally be "the trigger fired and hasUpdated was false".
-- Found 2026-09-08 while diagnosing an empty V2 store: the operator had BANK on, correctly, and
-- saw nothing. The mail scan this function also triggers keeps its own MAIL logging inside Scan.
function TOGBankClassic_Bank:OnUpdateStop()
	TOGBankClassic_Output:Debug("BANK", "GATE", "OnUpdateStop called, hasUpdated=%s", tostring(self.hasUpdated))
	if self.hasUpdated then
		TOGBankClassic_Output:Debug("BANK", "GATE", "Calling Scan()")
		self:Scan()
		TOGBankClassic_Output:Debug("BANK", "GATE", "Scan() completed")
	else
		TOGBankClassic_Output:Debug("BANK", "GATE", "Skipping Scan() because hasUpdated is false")
	end
	self.hasUpdated = false
end
