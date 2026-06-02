TOGBankClassic_Mail = {
	-- State for split operation
	splitState = nil  -- {bag, slot, amount, attachmentSlot, request}
}

-- Initialize split stack popup dialog
if not StaticPopupDialogs["TOGBANK_SPLIT_STACK"] then
	StaticPopupDialogs["TOGBANK_SPLIT_STACK"] = {
		text = "%s",
		button1 = "Split",
		button2 = "Cancel",
		OnAccept = function(self, data)
			if not data then return end
			ClearCursor()
			-- Find an empty bag slot to place the split items
			local emptyBag, emptySlot
			for bag = 0, 4 do
				local numSlots = C_Container.GetContainerNumSlots(bag)
				for slot = 1, numSlots do
					if not C_Container.GetContainerItemInfo(bag, slot) then
						emptyBag, emptySlot = bag, slot
						break
					end
				end
				if emptyBag then break end
			end
			if not emptyBag then
				return
			end
			-- Step 1: Split - puts amount on cursor
			C_Container.SplitContainerItem(data.bag, data.slot, data.amount)
			C_Timer.After(0.1, function()
				-- Step 2: Place split items into empty slot to "commit" the split
				C_Container.PickupContainerItem(emptyBag, emptySlot)
				C_Timer.After(0.05, function()
					-- Done! The split stack is now in inventory
					if TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.Window then
						local message = string.format("Split %d %s complete. Click Fulfill again to attach items.",
							data.amount, data.itemName)
						TOGBankClassic_UI_Requests.Window:SetStatusText(message)
						-- Refresh the request list to update the fulfill button icon
						TOGBankClassic_UI_Requests:DrawContent()
					end
				end)
			end)
		end,
		OnCancel = function()
			-- Nothing to clean up
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}
end

-- Check if mailbox is actually open (uses frame state as ground truth)
function TOGBankClassic_Mail:IsMailboxOpen()
	local frameOpen = MailFrame and MailFrame:IsShown() or false
	-- Sync our flag with actual frame state
	if self.isOpen ~= frameOpen then
		self.isOpen = frameOpen
	end
	return frameOpen
end

function TOGBankClassic_Mail:Check()
	CheckInbox()
end

-- Check if received item matches an active request from current player
function TOGBankClassic_Mail:CheckForFulfilledRequest(itemName, quantity, sender)
	local info = TOGBankClassic_Guild.Info
	if not info or not info.requests then
		return false
	end

	local currentPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()
	local normSender = TOGBankClassic_Guild:NormalizeName(sender)
	local normItemName = string.lower(itemName)

	-- Check if sender is a bank alt
	local banks = TOGBankClassic_Guild:GetBanks()
	local isBankAlt = false
	if banks then
		for _, bank in pairs(banks) do
			if TOGBankClassic_Guild:NormalizeName(bank) == normSender then
				isBankAlt = true
				break
			end
		end
	end

	if not isBankAlt then
		return false
	end

	-- Look for matching active request from current player
	for _, req in pairs(info.requests) do
		if req.requester == currentPlayer and
		   string.lower(req.item or "") == normItemName and
		   req.status ~= "complete" and
		   req.status ~= "cancelled" then
			local fulfilled = tonumber(req.fulfilled or 0)
			local requested = tonumber(req.quantity or 0)
			if fulfilled < requested then
				return true, req
			end
		end
	end

	return false
end

function TOGBankClassic_Mail:Scan()
	if not TOGBankClassic_Options:GetDonationEnabled() then
		return
	end

	if not TOGBankClassic_Mail.isOpen then
		return
	end
	if self.isScanning then
		return
	end
	-- FILLALL-001: while the Fulfill button is pulling a specific item for an order,
	-- don't let the donation auto-collect grab the other copies out of the mail.
	if self.collectInFlight then
		return
	end

	local info = TOGBankClassic_Guild.Info
	if not info then
		return
	end

	local player = TOGBankClassic_Guild:GetNormalizedPlayer()

	local isBank = false
	local banks = TOGBankClassic_Guild:GetBanks()
	if banks == nil then
		return
	end
	self.Roster = self.Roster or {}
	for _, v in pairs(banks) do
		local norm = TOGBankClassic_Guild:NormalizeName(v)
		if self.Roster and norm then
			self.Roster[norm] = true
		end
		if norm == player then
			isBank = true
		end
	end
	if not isBank then
		return
	end
	if not TOGBankClassic_Options:GetBankEnabled() then
		return
	end

	self.isScanning = true

	local numItems, totalItems = GetInboxNumItems()

	if numItems > 0 then
		for mailId = 1, numItems do
			local _, _, sender, _, money, CODAmount, _, itemCount, _, wasReturned, _, canReply, isGM =
				GetInboxHeaderInfo(mailId)
			if not sender then
				TOGBankClassic_Mail:ResetScan()
				return
			end

			if
				CODAmount == 0
				and not wasReturned
				and not isGM
				and canReply
				and not self.Roster[sender]
				and (money > 0 or (itemCount and itemCount > 0))
			then
				local hasNonUnique = nil
				if itemCount and itemCount > 0 then
					for attachmentIndex = 1, ATTACHMENTS_MAX_RECEIVE do
						local link = GetInboxItemLink(mailId, attachmentIndex)
						if link then
							local isUnique = TOGBankClassic_Item:IsUnique(link)
							if not isUnique then
								hasNonUnique = true
								break
							elseif hasNonUnique == nil then
								hasNonUnique = false
							end
						end
					end
				end

				if hasNonUnique == nil or hasNonUnique then
					TOGBankClassic_UI_Mail:SetMailId(mailId)
					TOGBankClassic_UI_Mail:Open()
					return
				end
			end
		end
	end
end

-- Hook SendMail to update request fulfillment when sending items from bank alts
function TOGBankClassic_Mail:InitSendHook()
	if self.sendHooked then
		return
	end
	self.sendHooked = true

	hooksecurefunc("SendMail", function(recipient, subject, body)
		TOGBankClassic_Mail:OnSendMail(recipient)
	end)
end

function TOGBankClassic_Mail:OnSendMail(recipient)
	TOGBankClassic_Output:Debug("MAIL", "STORE", "OnSendMail: HOOK FIRED for recipient=%s", tostring(recipient))

	-- If pendingSend was set recently by PrepareFulfillMail (within 10 seconds), keep it
	-- Otherwise, read items from mail attachments (fallback for non-fulfill mails)
	local now = GetTime()
	if self.pendingSend and self.pendingSendAt and (now - self.pendingSendAt) < 10 then
		-- MULTIORDER-001: addon-generated send. KEEP pending.items exactly as PrepareFulfillMail
		-- set it — it carries the request's own stored item name (the requester's locale, which
		-- always compares equal to req.item) and the precise attached quantity, so the targeted
		-- order is credited locale-safely. Additionally capture any items the banker added BY HAND
		-- to "save a mail" (actual attachments MINUS what the addon attached, matched by name) so
		-- ApplyPendingSend can spill them to that person's OTHER open orders. We do NOT overwrite
		-- pending.items with GetSendMailItem names, which are in the banker's locale and would
		-- break the targeted match in a mixed-locale guild.
		local addonByName = {}
		for _, it in ipairs(self.pendingSend.items or {}) do
			addonByName[it.name] = (addonByName[it.name] or 0) + (it.quantity or 0)
		end
		local extras = {}
		for attachmentIndex = 1, ATTACHMENTS_MAX_SEND do
			local itemName, _, _, quantity = GetSendMailItem(attachmentIndex)
			if itemName and quantity and quantity > 0 then
				local accountedFor = addonByName[itemName] or 0
				if accountedFor >= quantity then
					addonByName[itemName] = accountedFor - quantity
				else
					table.insert(extras, { name = itemName, quantity = quantity - accountedFor })
					addonByName[itemName] = 0
				end
			end
		end
		if #extras > 0 then
			self.pendingSend.extraItems = extras
			TOGBankClassic_Output:Debug("MAIL", "STORE", "OnSendMail: addon send + %d hand-added extra stack(s) to spill", #extras)
		end
		return
	end

	-- Clear old pendingSend and read from mail attachments
	self.pendingSend = nil
	self.pendingSendAt = nil

	local sender = TOGBankClassic_Guild:GetNormalizedPlayer()
	local items = {}

	for attachmentIndex = 1, ATTACHMENTS_MAX_SEND do
		local itemName, itemID, texture, quantity = GetSendMailItem(attachmentIndex)
		if itemName and quantity and quantity > 0 then
			table.insert(items, { name = itemName, quantity = quantity })
		end
	end

	TOGBankClassic_Output:Debug(
		"MAIL",
		"STORE",
		"OnSendMail: sender=%s, recipient=%s, items=%d",
		tostring(sender),
		tostring(recipient),
		#items
	)

	if #items == 0 then
		return
	end

	local info = TOGBankClassic_Guild.Info
	-- requests is a map (string keys), # always returns 0 -- use next() to check emptiness
	if not info or not info.requests or next(info.requests) == nil then
		return
	end

	if not sender or not TOGBankClassic_Guild:IsBank(sender) then
		TOGBankClassic_Output:Debug("MAIL", "STORE", "OnSendMail: Sender %s is not a banker, skipping", tostring(sender))
		return
	end

	TOGBankClassic_Output:Debug("MAIL", "STORE", "OnSendMail: Sender %s IS a banker, setting pendingSend", tostring(sender))
	local normRecipient = TOGBankClassic_Guild:NormalizeName(recipient)

	self.pendingSend = {
		sender = sender,
		recipient = normRecipient,
		items = items,
	}
	self.pendingSendAt = GetTime()

	-- Log at INFO level so user can see manual sends are tracked
	local itemList = {}
	for _, item in ipairs(items) do
		table.insert(itemList, string.format("%dx %s", item.quantity, item.name))
	end
	TOGBankClassic_Output:Info("Tracking manual mail to %s: %s", recipient, table.concat(itemList, ", "))
end

function TOGBankClassic_Mail:DebugSendMailState(contextMessage)
	local recipient = SendMailNameEditBox and SendMailNameEditBox:GetText() or nil
	local subject = SendMailSubjectEditBox and SendMailSubjectEditBox:GetText() or nil
	local items = {}
	local totalCount = 0
	for attachmentIndex = 1, (ATTACHMENTS_MAX_SEND or 12) do
		local itemName, itemID, texture, quantity = GetSendMailItem(attachmentIndex)
		if itemName and quantity and quantity > 0 then
			table.insert(items, { name = itemName, id = itemID, quantity = quantity })
			totalCount = totalCount + quantity
		end
	end

	TOGBankClassic_Output:Debug(
		"MAIL",
		"STORE",
		"SendMail error: %s | recipient=%s subject=%s items=%d total=%d",
		tostring(contextMessage),
		tostring(recipient),
		tostring(subject),
		#items,
		totalCount
	)

	for i, item in ipairs(items) do
		TOGBankClassic_Output:Debug(
			"MAIL",
			"STORE",
			"  Attachment %d: %s (id=%s) x%d",
			i,
			tostring(item.name),
			tostring(item.id),
			item.quantity
		)
	end

	if self.pendingSend then
		TOGBankClassic_Output:Debug(
			"MAIL",
			"STORE",
			"  pendingSend: sender=%s recipient=%s items=%d",
			tostring(self.pendingSend.sender),
			tostring(self.pendingSend.recipient),
			self.pendingSend.items and #self.pendingSend.items or 0
		)
	end
end

function TOGBankClassic_Mail:ApplyPendingSend()
	self.batchInFlight = false  -- FILLALL-001: a send completed; allow the next batch fulfill
	TOGBankClassic_Output:Debug("MAIL", "STORE", "ApplyPendingSend: Called, pendingSend=%s", tostring(self.pendingSend ~= nil))
	local pending = self.pendingSend
	if not pending then
		TOGBankClassic_Output:Debug("MAIL", "STORE", "ApplyPendingSend: No pendingSend, returning")
		return
	end
	self.pendingSend = nil
	self.pendingSendAt = nil

	TOGBankClassic_Output:Info("Applying fulfillment for mail sent to %s...", pending.recipient)

	local totalApplied = 0

	-- Targeted order from the fulfill button (addon mail) is credited via pending.items, which
	-- carries the request's own stored item name (locale-safe) and exact quantity, against the
	-- specific requestId. A fully manual mail has requestId = nil, so the same call spreads each
	-- attachment across every matching open order for that banker (the pre-existing behaviour).
	for _, item in ipairs(pending.items) do
		local applied = TOGBankClassic_Guild:FulfillRequest(
			pending.sender, pending.recipient, item.name, item.quantity, pending.requestId)
		if applied > 0 then
			TOGBankClassic_Output:Info("  Applied %dx %s toward %s's order(s)", applied, item.name, pending.recipient)
		end
		totalApplied = totalApplied + applied
	end

	-- MULTIORDER-001: spill items the banker hand-added to an addon-generated mail (to "save a
	-- mail") across the recipient's OTHER open orders for this banker. nil requestId = match any
	-- of that banker's matching orders by name. Empty/absent for fully manual mails.
	for _, item in ipairs(pending.extraItems or {}) do
		local applied = TOGBankClassic_Guild:FulfillRequest(
			pending.sender, pending.recipient, item.name, item.quantity, nil)
		if applied > 0 then
			TOGBankClassic_Output:Info("  Applied %dx %s toward %s's other order(s)", applied, item.name, pending.recipient)
		end
		totalApplied = totalApplied + applied
	end

	if totalApplied > 0 then
		TOGBankClassic_Output:Info("Total fulfilled: %d item(s) for %s", totalApplied, pending.recipient)
		TOGBankClassic_Guild:RefreshRequestsUI()
	else
		TOGBankClassic_Output:Info("No matching requests found for items sent to %s", pending.recipient)
	end
end

function TOGBankClassic_Mail:ResetScan()
	-- have to wait for server to remove item from inbox before we can take another
	-- so we wait a second before trying the next item
	TOGBankClassic_Core:ScheduleTimer(function(...)
		TOGBankClassic_Mail:OnTimer()
	end, 1)
end

function TOGBankClassic_Mail:OnTimer()
	self.isScanning = false
	TOGBankClassic_Mail:Scan()
end

function TOGBankClassic_Mail:Open(mailId)
	local _, _, sender, _, money, _, _, itemCount, _, _, _, _, _, _ = GetInboxHeaderInfo(mailId)
	if not sender then
		TOGBankClassic_Mail:RetryOpen(mailId)
		return
	end

	local info = TOGBankClassic_Guild.Info
	if not info then
		return
	end
	local player = TOGBankClassic_Guild:GetPlayer()
	local norm = TOGBankClassic_Guild:GetNormalizedPlayer(player)

	if not info.alts then
		info.alts = {}
	end

	if info.alts and not info.alts[norm] then
		info.alts[norm] = {}
	end

	local alt = info.alts[norm]

	if not alt.ledger then
		alt.ledger = {}
	end

	local ledger = alt.ledger

	local current_score = 0
	if ledger[sender] then
		current_score = ledger[sender]
	end

	local score = 0
	if money > 0 then
		-- convert from copper to gold
		score = money / 10000

		if TOGBankClassic_Options:GetBankReporting() then
			TOGBankClassic_Output:Info("Received %s gold from %s", score, sender)
		end

		if TOGBankClassic_UI_Mail.ScoreMail and not self.Roster[sender] then
			ledger[sender] = current_score + score
		end

		TakeInboxMoney(mailId)
		if itemCount and itemCount > 0 then
			TOGBankClassic_Mail:RetryOpen(mailId)
			return
		end
	end
	if itemCount then
		if not TOGBankClassic_Bank:HasInventorySpace() then
			TOGBankClassic_Output:Warn("Inventory is full.")
			return
		end

		for attachmentIndex = 1, ATTACHMENTS_MAX_RECEIVE do
			local link = GetInboxItemLink(mailId, attachmentIndex)
			if link then
				local _, _, _, quantity, _ = GetInboxItem(mailId, attachmentIndex)
				local name, _, quality, level, _, _, _, _, _, _, price = GetItemInfo(link)
				if not name or level == nil then
					TOGBankClassic_Mail:RetryOpen(mailId)
					return
				end

				if not TOGBankClassic_Item:IsUnique(link) then
					score = ((price + 1) / 10000) * quantity

					if TOGBankClassic_Options:GetBankReporting() then
						TOGBankClassic_Output:Info("Received %s (%d) from %s", name, quantity, sender)
					end

					-- Check if this fulfills an active request
					local isFulfillment, request = self:CheckForFulfilledRequest(name, quantity, sender)
					if isFulfillment and request then
						-- Play completion sound and show notification
						if TOGBankClassic_Options:IsOrderFulfillmentSoundEnabled() then
							---@diagnostic disable-next-line: undefined-global
							PlaySound(SOUNDKIT and SOUNDKIT.AUCTION_WINDOW_CLOSE or 11561) -- Classic Era compatible numeric SoundKitID
						end
						local fulfilled = tonumber(request.fulfilled or 0) + quantity
						local requested = tonumber(request.quantity or 0)
						if fulfilled >= requested then
							TOGBankClassic_Output:Response("|cff00ff00[Order Filled]|r Received %dx %s from %s - Request Complete!", quantity, name, sender)
						else
							TOGBankClassic_Output:Response("|cff00ff00[Order Filled]|r Received %dx %s from %s (%d/%d)", quantity, name, sender, fulfilled, requested)
						end
					end

					if TOGBankClassic_UI_Mail.ScoreMail and not self.Roster[sender] then
						ledger[sender] = current_score + score
					end

					TakeInboxItem(mailId, attachmentIndex)
					if itemCount > 1 then
						TOGBankClassic_Mail:RetryOpen(mailId)
						return
					end
				end
			end
		end
	end

	TOGBankClassic_UI_Mail:Close()
	TOGBankClassic_Mail:ResetScan()
end

function TOGBankClassic_Mail:RetryOpen(mailId)
	-- have to wait for server to remove item from inbox before we can take another
	-- so we wait a second before trying the next item
	TOGBankClassic_Core:ScheduleTimer(function(...)
		TOGBankClassic_Mail:OnRetryTimer(mailId)
	end, 1)
end

function TOGBankClassic_Mail:OnRetryTimer(mailId)
	TOGBankClassic_Mail:Open(mailId)
end

-- Unified fulfillment plan calculator
-- Returns plan: {
--   canFulfill = boolean,
--   reason = string or nil,
--   stacksToAttach = {{bag, slot, count, originalIndex}, ...},
--   splitStack = {bag, slot, count, amount} or nil,
--   totalAttachable = number,
--   requiresMailbox = boolean
-- }
function TOGBankClassic_Mail:CalculateFulfillmentPlan(items, qtyNeeded, totalInBags)
	if not items or #items == 0 then
		return {
			canFulfill = false,
			reason = "No items found in bags.",
			stacksToAttach = {},
			splitStack = nil,
			totalAttachable = 0,
			requiresMailbox = false
		}
	end

	-- Add original index for stable sorting
	for i, item in ipairs(items) do
		item.originalIndex = i
	end

	-- Sort: largest first, maintain scan order for equal counts
	table.sort(items, function(a, b)
		if a.count == b.count then
			return a.originalIndex < b.originalIndex
		end
		return a.count > b.count
	end)

	local largestStack = items[1].count
	local smallestStack = items[#items].count

	-- PHASE 1: Try greedy exact match (accumulate stacks that fit without exceeding)
	local accumulated = 0
	local attachList = {}

	for i, item in ipairs(items) do
		local remaining = qtyNeeded - accumulated
		if item.count <= remaining then
			accumulated = accumulated + item.count
			table.insert(attachList, {
				bag = item.bag,
				slot = item.slot,
				count = item.count,
				originalIndex = item.originalIndex
			})
		end
	end

	-- SUCCESS: Exact match without splitting
	if accumulated == qtyNeeded then
		return {
			canFulfill = true,
			reason = nil,
			stacksToAttach = attachList,
			splitStack = nil,
			totalAttachable = accumulated,
			requiresMailbox = true
		}
	end

	-- PHASE 2: Try skipping small stacks to find exact match
	if accumulated < qtyNeeded and totalInBags >= qtyNeeded then
		local bestAccumulated = accumulated
		local bestAttachList = attachList
		local bestSkipIndex = nil

		for skipIndex = 1, math.min(5, #items) do
			local testAccumulated = 0
			local testAttachList = {}

			for i, item in ipairs(items) do
				if i ~= skipIndex then
					local remaining = qtyNeeded - testAccumulated
					if item.count <= remaining then
						testAccumulated = testAccumulated + item.count
						table.insert(testAttachList, {
							bag = item.bag,
							slot = item.slot,
							count = item.count,
							originalIndex = item.originalIndex
						})
					end
				end
			end

			-- Found exact match by skipping
			if testAccumulated == qtyNeeded then
				return {
					canFulfill = true,
					reason = nil,
					stacksToAttach = testAttachList,
					splitStack = nil,
					totalAttachable = testAccumulated,
					requiresMailbox = true
				}
			end

			-- Better fit than before (closer to target)
			if testAccumulated > bestAccumulated and testAccumulated < qtyNeeded then
				bestAccumulated = testAccumulated
				bestAttachList = testAttachList
				bestSkipIndex = skipIndex
			end
		end

		-- Use best fit found
		accumulated = bestAccumulated
		attachList = bestAttachList
	end

	-- PHASE 3: Need to split to fulfill
	if accumulated < qtyNeeded and totalInBags >= qtyNeeded then
		local remaining = qtyNeeded - accumulated

		-- Find a stack large enough to split from
		-- Prefer splitting from largest available stack
		local splitCandidate = nil
		for i, item in ipairs(items) do
			if item.count >= remaining then
				-- Check if this stack is already in attach list
				local alreadyAttaching = false
				for _, attached in ipairs(attachList) do
					if attached.originalIndex == item.originalIndex then
						alreadyAttaching = true
						break
					end
				end

				if not alreadyAttaching then
					-- Prefer largest split candidate (first one found due to sorting)
					if not splitCandidate then
						splitCandidate = item
					end
				end
			end
		end

		if splitCandidate then
			return {
				canFulfill = true,
				reason = string.format("Split %d from stack of %d.", remaining, splitCandidate.count),
				stacksToAttach = attachList,
				splitStack = {
					bag = splitCandidate.bag,
					slot = splitCandidate.slot,
					count = splitCandidate.count,
					amount = remaining
				},
				totalAttachable = accumulated,
				requiresMailbox = true
			}
		end
	end

	-- PHASE 4: Can't fulfill even with splitting
	local deficit = qtyNeeded - totalInBags
	if deficit > 0 then
		return {
			canFulfill = false,
			reason = string.format("Need %d more items.", deficit),
			stacksToAttach = {},
			splitStack = nil,
			totalAttachable = totalInBags,
			requiresMailbox = false
		}
	end

	-- Edge case: single large stack, need to split
	if accumulated == 0 and smallestStack > qtyNeeded and totalInBags >= qtyNeeded then
		return {
			canFulfill = true,
			reason = string.format("Split from stack of %d.", smallestStack),
			stacksToAttach = {},
			splitStack = {
				bag = items[1].bag,
				slot = items[1].slot,
				count = items[1].count,
				amount = qtyNeeded
			},
			totalAttachable = 0,
			requiresMailbox = true
		}
	end

	-- Shouldn't reach here, but fallback
	return {
		canFulfill = false,
		reason = "Unable to determine fulfillment strategy.",
		stacksToAttach = {},
		splitStack = nil,
		totalAttachable = accumulated,
		requiresMailbox = false
	}
end

-- Check if a request can be fulfilled by the current player
-- Returns: canFulfill (boolean), reason (string), itemsInBags (number), smallestStack (number)
function TOGBankClassic_Mail:CanFulfillRequest(request, actor)
	local normActor = TOGBankClassic_Guild:NormalizeName(actor or TOGBankClassic_Guild:GetPlayer())

	-- Must be a bank alt
	if not TOGBankClassic_Guild:IsBank(normActor) then
		return false, "Only bank alts can fulfill requests.", 0, 0
	end

	-- Request must be valid and not completed
	if not request or not request.item then
		return false, "Invalid request.", 0, 0
	end

	local qtyRequested = tonumber(request.quantity or 0) or 0
	local qtyFulfilled = tonumber(request.fulfilled or 0) or 0
	local qtyNeeded = qtyRequested - qtyFulfilled

	if request.status == "complete" or request.status == "fulfilled" or request.status == "cancelled" then
		return false, "Request is already completed.", 0, 0
	end

	if qtyFulfilled >= qtyRequested and qtyRequested > 0 then
		return false, "Request is already fulfilled.", 0, 0
	end

	-- Check if items are in bags and find usable stacks
	local totalInBags, items = TOGBankClassic_Bank:CountItemInBags(request.item, request.itemID, request.suffixID)

	-- Helper: check synced alt inventory tables for a matching item
	local altData = (function()
		local info = TOGBankClassic_Guild.Info
		return info and info.alts and info.alts[normActor]
	end)()
	local targetID     = tonumber(request.itemID) or nil
	local targetName   = request.item and string.lower(request.item) or nil
	local targetSuffix = tonumber(request.suffixID) or nil
	local function itemMatchesRequest(item)
		local matched
		if targetID then
			matched = item.ID == targetID and (item.Count or 0) > 0
		elseif targetName then
			matched = item.Name and string.lower(item.Name) == targetName and (item.Count or 0) > 0
		else
			return false
		end
		-- REQ-003: when the request carries a suffix and the synced entry has a link, the suffix
		-- must match too. Entries without a link (older link-less data) keep the lenient match.
		if matched and targetSuffix and item.Link then
			matched = (TOGBankClassic_Item:GetSuffixID(item.Link) == targetSuffix)
		end
		return matched
	end
	local function hasMatchInTable(tbl)
		if not tbl then return false end
		for _, item in ipairs(tbl) do
			if itemMatchesRequest(item) then return true end
		end
		return false
	end

	if totalInBags == 0 then
		-- Nothing in bags — tell the player where to look
		local inMail = hasMatchInTable(altData and altData.mail and altData.mail.items)
		local inBank = hasMatchInTable(altData and altData.bank and altData.bank.items)
		if inMail and inBank then
			return false, "in mail and bank", 0, 0
		elseif inMail then
			return false, "in mail", 0, 0
		end
		return false, "Items not in bags. Pick up from bank first.", 0, 0
	end

	-- Use unified fulfillment calc (make copy of items array to avoid mutation)
	local itemsCopy = {}
	for i, item in ipairs(items) do
		itemsCopy[i] = {bag = item.bag, slot = item.slot, count = item.count}
	end

	local plan = self:CalculateFulfillmentPlan(itemsCopy, qtyNeeded, totalInBags)

	-- Find smallest stack for legacy return value
	local smallestStack = nil
	for _, item in ipairs(items) do
		if not smallestStack or item.count < smallestStack then
			smallestStack = item.count
		end
	end

	-- Bags have items but not enough — check bank/mail for the shortfall
	if not plan.canFulfill and totalInBags < qtyNeeded then
		local inMail = hasMatchInTable(altData and altData.mail and altData.mail.items)
		local inBank = hasMatchInTable(altData and altData.bank and altData.bank.items)
		if inMail and inBank then
			return false, "shortfall in bank and mail", totalInBags, smallestStack or 0
		elseif inMail then
			return false, "shortfall in mail", totalInBags, smallestStack or 0
		elseif inBank then
			return false, "shortfall in bank", totalInBags, smallestStack or 0
		end
	end

	return plan.canFulfill, plan.reason, totalInBags, smallestStack or 0
end

-- Prepare mail to fulfill a request: sets recipient and attaches items
-- Returns: success (boolean), message (string), attachedCount (number)
function TOGBankClassic_Mail:PrepareFulfillMail(request)
	if not self:IsMailboxOpen() then
		return false, "Mailbox is not open.", 0
	end

	if not request or not request.item or not request.requester then
		return false, "Invalid request.", 0
	end

	local itemName = request.item
	local requester = request.requester
	local qtyRequested = tonumber(request.quantity or 0) or 0
	local qtyFulfilled = tonumber(request.fulfilled or 0) or 0
	local qtyNeeded = qtyRequested - qtyFulfilled

	if qtyNeeded <= 0 then
		return false, "Request is already fulfilled.", 0
	end

	-- Find items in inventory (REQ-003: suffix-aware so we attach the requested variant only)
	local totalInBags, items = TOGBankClassic_Bank:CountItemInBags(itemName, request.itemID, request.suffixID)

	if totalInBags == 0 then
		return false, "No " .. itemName .. " found in bags.", 0
	end

	-- Check if mail already has items attached
	if GetSendMailItem(1) then
		return false, "Mail already has items attached. Send or clear first.", 0
	end

	-- Set recipient
	if SendMailNameEditBox then
		SendMailNameEditBox:SetText(requester)
	end

	-- Use unified fulfillment plan
	local plan = self:CalculateFulfillmentPlan(items, qtyNeeded, totalInBags)

	if not plan.canFulfill then
		return false, plan.reason, 0
	end

	-- If plan requires split, show popup FIRST without attaching anything
	if plan.splitStack then
		local splitInfo = plan.splitStack
		local popupText = string.format("Split %d from stack of %d %s?",
			splitInfo.amount, splitInfo.count, itemName)
		local dialog = StaticPopup_Show("TOGBANK_SPLIT_STACK", popupText)
		if dialog then
			dialog.data = {
				bag = splitInfo.bag,
				slot = splitInfo.slot,
				amount = splitInfo.amount,
				attachmentSlot = 1,  -- Will be set after attaching plan stacks
				itemName = itemName,
				requester = requester
			}
		end

		local message = string.format("Click Split to prepare %d %s for mailing.",
			splitInfo.amount, itemName)
		return false, message, 0
	end

	-- No split needed, attach items from plan
	local attached = 0
	local attachmentSlot = 1
	local maxSlots = ATTACHMENTS_MAX_SEND or 12

	for _, stack in ipairs(plan.stacksToAttach) do
		if attached >= qtyNeeded then
			break
		end
		if attachmentSlot > maxSlots then
			break
		end

		ClearCursor()
		C_Container.PickupContainerItem(stack.bag, stack.slot)
		ClickSendMailItemButton(attachmentSlot)

		attached = attached + stack.count
		attachmentSlot = attachmentSlot + 1
	end

	local message
	if attached >= qtyNeeded then
		message = string.format("Attached %d %s for %s. Click Send to complete.",
			attached, itemName, requester)
	elseif attached > 0 then
		message = string.format("Attached %d of %d %s (partial). Click Send, then fulfill again.",
			attached, qtyNeeded, itemName)
	else
		message = string.format("No %s found in bags.", itemName)
		return false, message, 0
	end

	-- Set pendingSend NOW (when items are attached), not in SendMail hook
	-- This ensures pendingSend is set BEFORE MAIL_SEND_SUCCESS fires
	if attached > 0 then
		local sender = TOGBankClassic_Guild:GetNormalizedPlayer()
		local normRecipient = TOGBankClassic_Guild:NormalizeName(requester)
		self.pendingSend = {
			sender = sender,
			recipient = normRecipient,
			requestId = request.id,  -- Track which specific request is being fulfilled
			items = {{ name = itemName, quantity = attached }}
		}
		self.pendingSendAt = GetTime()
		TOGBankClassic_Output:Debug("MAIL", "STORE", "PrepareFulfillMail: Set pendingSend for %s (%d %s) - requestId=%s",
			tostring(normRecipient), attached, itemName, tostring(request.id))
	end

	return true, message, attached
end

-- FILLALL-001: stepped batch fulfillment. One WoW action per click — split,
-- attach and send each happen on a separate click (separate frame) so the cursor
-- and bag state settle between actions; doing it all in one click raced the send
-- ahead of the split. The banker spams the envelope icon to walk the oldest
-- fully-fillable order through: select -> (split) -> attach -> send, then the next
-- click selects the next-oldest. Decisions: oldest-first (FIFO by date); skip
-- partials (only orders we can fully fill from bags). The split is attached
-- directly off the cursor, so no free bag slot or async timers are needed.
local function tog_copyItems(items)
	local out = {}
	for i, item in ipairs(items) do
		out[i] = { bag = item.bag, slot = item.slot, count = item.count }
	end
	return out
end

local function tog_findEmptyBagSlot()
	for bag = 0, 4 do
		local numSlots = C_Container.GetContainerNumSlots(bag)
		for slot = 1, numSlots do
			if not C_Container.GetContainerItemInfo(bag, slot) then
				return bag, slot
			end
		end
	end
	return nil
end

-- FILLALL-001 (mail collect): does an inbox item link match a request's item?
-- Mirrors CanFulfillRequest's match: by itemID (+ suffix) when known, else by name.
local function tog_linkMatchesReq(link, req)
	if not link then return false end
	local targetID = tonumber(req.itemID)
	if targetID then
		local lid = GetItemInfoInstant(link)
		if lid ~= targetID then return false end
		local targetSuffix = tonumber(req.suffixID)
		if targetSuffix then
			return TOGBankClassic_Item:GetSuffixID(link) == targetSuffix
		end
		return true
	end
	local name = GetItemInfo(link)
	if name and req.item and string.lower(name) == string.lower(req.item) then
		return true
	end
	return false
end

-- Total quantity of a request's item sitting in the player's mail inbox.
local function tog_inboxQtyFor(req)
	local total = 0
	local num = GetInboxNumItems()
	for mailId = 1, (num or 0) do
		for a = 1, (ATTACHMENTS_MAX_RECEIVE or 12) do
			local link = GetInboxItemLink(mailId, a)
			if link and tog_linkMatchesReq(link, req) then
				local _, _, _, qty = GetInboxItem(mailId, a)
				total = total + (tonumber(qty) or 0)
			end
		end
	end
	return total
end

-- Take the first inbox attachment matching the request into bags.
-- Returns (ok, name, quantityTaken) — quantity matters because one attachment can
-- be a stack, so the collector counts items pulled, not attachments.
function TOGBankClassic_Mail:TakeOneInboxItemFor(req)
	local num = GetInboxNumItems()
	for mailId = 1, (num or 0) do
		for a = 1, (ATTACHMENTS_MAX_RECEIVE or 12) do
			local link = GetInboxItemLink(mailId, a)
			if link and tog_linkMatchesReq(link, req) then
				local name = GetItemInfo(link) or req.item
				local _, _, _, qty = GetInboxItem(mailId, a)
				TakeInboxItem(mailId, a)
				return true, name, (tonumber(qty) or 1)
			end
		end
	end
	return false
end

-- Oldest open order for normActor serviceable from bags, or from bags + the mail
-- inbox. Returns (req, bagsReady, plan, qtyNeeded). bagsReady=true → can be fully
-- attached from bags now (plan computed); false → some of its items are in the
-- mail and need pulling into bags first.
function TOGBankClassic_Mail:FindOldestServiceableOrder(normActor)
	local info = TOGBankClassic_Guild.Info
	local requests = info and info.requests
	if not requests then return nil end
	local best, bestBagsReady, bestPlan, bestQty
	for _, req in pairs(requests) do
		if (req.status or "open") == "open"
			and req.bank and TOGBankClassic_Guild:NormalizeName(req.bank) == normActor then
			local qtyNeeded = (tonumber(req.quantity) or 0) - (tonumber(req.fulfilled) or 0)
			if qtyNeeded > 0 then
				local totalInBags, items = TOGBankClassic_Bank:CountItemInBags(req.item, req.itemID, req.suffixID)
				local bagsReady, plan, serviceable = false, nil, false
				if totalInBags >= qtyNeeded then
					plan = self:CalculateFulfillmentPlan(tog_copyItems(items), qtyNeeded, totalInBags)
					if plan.canFulfill then bagsReady, serviceable = true, true end
				end
				if not serviceable and totalInBags < qtyNeeded then
					local inboxQty = tog_inboxQtyFor(req)
					if inboxQty > 0 and (totalInBags + inboxQty) >= qtyNeeded then
						serviceable = true  -- bags + mail can cover it; pull the mail items first
					end
				end
				if serviceable then
					-- Oldest = smallest date, with a stable id tiebreak so same-second
					-- orders resolve deterministically (not jump around the list).
					local d  = tonumber(req.date) or 0
					local bd = best and (tonumber(best.date) or 0) or nil
					if not best or d < bd or (d == bd and tostring(req.id) < tostring(best.id)) then
						best, bestBagsReady, bestPlan, bestQty = req, bagsReady, plan, qtyNeeded
					end
				end
			end
		end
	end
	return best, bestBagsReady, bestPlan, bestQty
end

-- Clear any in-progress stepped fulfillment (e.g. when the mailbox closes).
function TOGBankClassic_Mail:ResetFulfillStep()
	self.batchState = nil
	self.collectState = nil
end

-- Advance the stepped batch fulfillment one action. Returns (ok, message).
-- States: nil(idle) -> "split"(if needed) -> "attach" -> "send" -> nil.
function TOGBankClassic_Mail:FulfillStep(actor)
	if not self:IsMailboxOpen() then
		self.batchState = nil
		return false, "Open a mailbox first."
	end
	local normActor = TOGBankClassic_Guild:NormalizeName(actor or TOGBankClassic_Guild:GetPlayer())
	if not TOGBankClassic_Guild:IsBank(normActor) then
		return false, "Only bank characters can fulfill orders."
	end

	local st = self.batchState

	-- IDLE: select the oldest fully-fillable order and set the recipient.
	if not st then
		if self.batchInFlight then
			return false, "Waiting for the last order to confirm — try again in a second."
		end
		if GetSendMailItem(1) then
			return false, "The open mail already has items attached — send or clear it first."
		end
		local req, bagsReady, plan, qtyNeeded = self:FindOldestServiceableOrder(normActor)
		if not req then
			return false, "No orders you can fully fill from your bags or mail right now."
		end

		-- COLLECT: the oldest serviceable order's items are (partly) in the mail.
		-- Pull one matching item from the inbox into bags per click; once enough is
		-- in bags, the next click selects + fulfills it. Stay in IDLE meanwhile.
		if not bagsReady then
			-- Pull only as many as the order is short, then stop — never empty the
			-- mail of an item just because there are several copies. Taking an inbox
			-- item is async (it lands in bags a moment later), so we count what we've
			-- already pulled (collectState.pulled) against the deficit rather than
			-- relying on the live bag count, which lags.
			local cs = self.collectState
			if not cs or cs.reqId ~= req.id then
				local inBagsNow = TOGBankClassic_Bank:CountItemInBags(req.item, req.itemID, req.suffixID)
				cs = { reqId = req.id, toPull = math.max(0, qtyNeeded - inBagsNow), pulled = 0 }
				self.collectState = cs
			end
			if cs.pulled >= cs.toPull then
				-- Already pulled what's needed; just wait for it to arrive in bags.
				return false, string.format("Pulled the %d %s needed — waiting for it to reach your bags, then click to send.", cs.toPull, tostring(req.item))
			end
			if self.collectInFlight then
				return false, "Pulling from your mail — give it a second, then click again."
			end
			if not TOGBankClassic_Bank:HasInventorySpace() then
				return false, "Bags are full — make room to pull items from the mail."
			end
			-- Set the guard BEFORE taking so the donation auto-collect (Mail:Scan),
			-- which fires on the resulting inbox update, is suppressed and can't grab
			-- the other copies.
			self.collectInFlight = true
			C_Timer.After(1.5, function() self.collectInFlight = false end)
			local took, name, qtyTaken = self:TakeOneInboxItemFor(req)
			if took then
				cs.pulled = cs.pulled + (qtyTaken or 1)  -- count items, not attachments (stacks)
				return true, string.format("Pulled %d of %d %s for %s from your mail.", math.min(cs.pulled, cs.toPull), cs.toPull, tostring(name or req.item), tostring(req.requester))
			end
			self.collectInFlight = false
			return false, "Couldn't pull from the mail just now — click again."
		end
		self.collectState = nil  -- bags can cover it now; collecting done

		-- Make sure we're on the Send Mail tab so attaching works.
		if MailFrameTab2 and MailFrameTab2.Click then MailFrameTab2:Click() end
		if SendMailNameEditBox then SendMailNameEditBox:SetText(req.requester) end
		self.batchState = {
			req = req, plan = plan, requester = req.requester, qty = qtyNeeded,
			phase = plan.splitStack and "split" or "attach",
		}
		if plan.splitStack then
			return true, string.format("Order: %dx %s for %s. Click to SPLIT.", qtyNeeded, req.item, req.requester)
		end
		return true, string.format("Order: %dx %s for %s. Click to ATTACH.", qtyNeeded, req.item, req.requester)
	end

	-- SPLIT: split the needed amount into a free bag slot as its own stack (like
	-- the manual split), so it sits in your bags rather than on the cursor. The
	-- place into the slot is deferred a frame (matches the manual split timing);
	-- ATTACH waits for it to land.
	if st.phase == "split" then
		local sp = st.plan.splitStack
		local emptyBag, emptySlot = tog_findEmptyBagSlot()
		if not emptyBag then
			return false, "Need one free bag slot to split into — make room, then click again."
		end
		st.splitBag, st.splitSlot = emptyBag, emptySlot
		ClearCursor()
		C_Container.SplitContainerItem(sp.bag, sp.slot, sp.amount)        -- onto cursor
		C_Timer.After(0.1, function()
			C_Container.PickupContainerItem(emptyBag, emptySlot)         -- drop into the free slot
		end)
		st.phase = "attach"
		return true, string.format("Split %d %s into your bags. Click to ATTACH.", sp.amount, st.req.item)
	end

	-- ATTACH: attach the freshly-split stack (now in the bag) then the whole stacks.
	if st.phase == "attach" then
		if st.splitBag and not C_Container.GetContainerItemInfo(st.splitBag, st.splitSlot) then
			-- The split hasn't committed to the bag yet (clicked too fast).
			return false, "Still placing the split — click ATTACH again."
		end
		local slot = 1
		local maxSlots = ATTACHMENTS_MAX_SEND or 12
		if st.splitBag then
			ClearCursor()
			C_Container.PickupContainerItem(st.splitBag, st.splitSlot)
			ClickSendMailItemButton(slot)
			slot = slot + 1
			st.splitBag, st.splitSlot = nil, nil
		end
		for _, stack in ipairs(st.plan.stacksToAttach) do
			if slot > maxSlots then break end
			ClearCursor()
			C_Container.PickupContainerItem(stack.bag, stack.slot)
			ClickSendMailItemButton(slot)
			slot = slot + 1
		end
		st.phase = "send"
		return true, string.format("Attached %dx %s for %s. Click to SEND.", st.qty, st.req.item, st.requester)
	end

	-- SEND: mail it. pendingSend mirrors PrepareFulfillMail so MAIL_SEND_SUCCESS →
	-- ApplyPendingSend → Guild:FulfillRequest marks THIS request (by id).
	if st.phase == "send" then
		local req = st.req
		if not GetSendMailItem(1) then
			-- Nothing actually attached (e.g. the cursor was disturbed mid-sequence).
			-- Don't send an empty mail or falsely mark the order filled.
			self.batchState = nil
			return false, "Nothing is attached — start the order again."
		end
		self.pendingSend = {
			sender    = normActor,
			recipient = TOGBankClassic_Guild:NormalizeName(st.requester),
			requestId = req.id,
			items     = {{ name = req.item, quantity = st.qty }},
		}
		self.pendingSendAt = GetTime()
		SendMail(st.requester, "Guild Bank Order", "")
		-- Block re-selecting this order until the send confirms (or 5s safety).
		self.batchInFlight = true
		C_Timer.After(5, function() self.batchInFlight = false end)
		self.batchState = nil
		return true, string.format("Sent %dx %s to %s. Click for the next order.", st.qty, req.item, st.requester)
	end

	self.batchState = nil
	return false, "Reset — click to start the next order."
end
