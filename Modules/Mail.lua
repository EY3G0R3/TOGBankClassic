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
	TOGBankClassic_Output:Debug("MAIL", "OnSendMail: HOOK FIRED for recipient=%s", tostring(recipient))
	
	-- If pendingSend was set recently by PrepareFulfillMail (within 10 seconds), keep it
	-- Otherwise, read items from mail attachments (fallback for non-fulfill mails)
	local now = GetTime()
	if self.pendingSend and self.pendingSendAt and (now - self.pendingSendAt) < 10 then
		TOGBankClassic_Output:Debug("MAIL", "OnSendMail: Using pendingSend from PrepareFulfillMail")
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
		"UI",
		"OnSendMail: sender=%s, recipient=%s, items=%d",
		tostring(sender),
		tostring(recipient),
		#items
	)

	if #items == 0 then
		return
	end

	local info = TOGBankClassic_Guild.Info
	if not info or not info.requests or #info.requests == 0 then
		return
	end

	if not sender or not TOGBankClassic_Guild:IsBank(sender) then
		TOGBankClassic_Output:Debug("MAIL", "OnSendMail: Sender %s is not a banker, skipping", tostring(sender))
		return
	end

	TOGBankClassic_Output:Debug("MAIL", "OnSendMail: Sender %s IS a banker, setting pendingSend", tostring(sender))
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
			"  pendingSend: sender=%s recipient=%s items=%d",
			tostring(self.pendingSend.sender),
			tostring(self.pendingSend.recipient),
			self.pendingSend.items and #self.pendingSend.items or 0
		)
	end
end

function TOGBankClassic_Mail:ApplyPendingSend()
	TOGBankClassic_Output:Debug("MAIL", "ApplyPendingSend: Called, pendingSend=%s", tostring(self.pendingSend ~= nil))
	local pending = self.pendingSend
	if not pending then
		TOGBankClassic_Output:Debug("MAIL", "ApplyPendingSend: No pendingSend, returning")
		return
	end
	self.pendingSend = nil
	self.pendingSendAt = nil

	TOGBankClassic_Output:Info("Applying fulfillment for mail sent to %s...", pending.recipient)
	
	local totalApplied = 0
	for _, item in ipairs(pending.items) do
		local applied = TOGBankClassic_Guild:FulfillRequest(
			pending.sender,
			pending.recipient,
			item.name,
			item.quantity
		)
		if applied > 0 then
			TOGBankClassic_Output:Info("  Applied %dx %s toward %s's request", applied, item.name, pending.recipient)
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
	---START CHANGES
	if not info then
		return
	end
	---END CHANGES
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
	local totalInBags, items = TOGBankClassic_Bank:CountItemInBags(request.item)

	if totalInBags == 0 then
		return false, "Items not in bags. Pick up from bank first.", 0, 0
	end

	-- Sort items by stack size (largest first) to match attachment behavior
	table.sort(items, function(a, b) return a.count > b.count end)

	-- Find smallest and largest stacks, and count usable items (stacks that fit without exceeding qtyNeeded)
	local smallestStack = nil
	local largestStack = nil
	local usableItems = 0
	for _, item in ipairs(items) do
		if not smallestStack or item.count < smallestStack then
			smallestStack = item.count
		end
		if not largestStack or item.count > largestStack then
			largestStack = item.count
		end
		-- Only count this stack if adding it doesn't exceed what we need
		if usableItems + item.count <= qtyNeeded then
			usableItems = usableItems + item.count
		end
	end

	-- If greedy smallest-first didn't get exact match, try skipping individual small stacks
	if usableItems < qtyNeeded and totalInBags >= qtyNeeded then
		for skipIndex = 1, math.min(5, #items) do
			local testUsable = 0
			for i = 1, #items do
				if i ~= skipIndex and testUsable + items[i].count <= qtyNeeded then
					testUsable = testUsable + items[i].count
				end
			end
			if testUsable == qtyNeeded then
				usableItems = testUsable
				break
			elseif testUsable > usableItems and testUsable <= qtyNeeded then
				-- Better fit, use it
				usableItems = testUsable
			end
		end
	end

	-- Check if we need to split
	if usableItems < qtyNeeded and totalInBags >= qtyNeeded then
		-- We have enough total, but need to split to fulfill
		-- Efficiency check: if we have any stack large enough to provide what we need,
		-- prefer splitting from it rather than using multiple small stacks
		if largestStack and largestStack >= qtyNeeded then
			-- Can split exactly what we need from a single stack - more efficient
			local reason = string.format("Split %d from available stacks.", qtyNeeded)
			return true, reason, totalInBags, smallestStack
		end
		
		local remaining = qtyNeeded - usableItems
		
		-- Additional efficiency check: if using small partials requires a split,
		-- check if using only the largest stacks would require similar or smaller effort
		-- Example: [1,20,20,20,20,20] need 90 -> better to use 4×20+split(10) than 1+4×20+split(9)
		-- The trade-off: splitting 10 from one stack vs using a 1-stack + splitting 9
		if largestStack and largestStack > 1 and remaining > 0 then
			-- Count how many complete largest stacks we can use
			local largeStacksUsable = 0
			for _, item in ipairs(items) do
				if item.count == largestStack and largeStacksUsable + item.count <= qtyNeeded then
					largeStacksUsable = largeStacksUsable + item.count
				end
			end
			
			-- If we have at least one more largest stack available to split from
			local hasExtraLargeStack = false
			for _, item in ipairs(items) do
				if item.count == largestStack then
					local testTotal = largeStacksUsable + item.count
					if testTotal > largeStacksUsable and testTotal >= qtyNeeded then
						hasExtraLargeStack = true
						break
					end
				end
			end
			
			if hasExtraLargeStack and largeStacksUsable < qtyNeeded then
				local largeSplitAmount = qtyNeeded - largeStacksUsable
				-- Prefer this if it means not attaching tiny partial stacks
				-- (using fewer mail attachment slots is more efficient)
				if largeSplitAmount <= largestStack then
					usableItems = largeStacksUsable
					remaining = largeSplitAmount
				end
			end
		end
		
		local reason = string.format("Splitting %d to fill the order.", remaining)
		return true, reason, totalInBags, smallestStack
	end

	-- If no stacks are small enough, we can split automatically
	if usableItems == 0 and smallestStack and smallestStack > qtyNeeded then
		local reason = string.format("Split from stack of %d.", smallestStack)
		return true, reason, totalInBags, smallestStack
	end

	-- Check if we have enough usable items to fulfill the request
	if usableItems >= qtyNeeded then
		return true, nil, usableItems, smallestStack
	end

	-- Not enough items even with splitting
	return false, string.format("Need %d more items.", qtyNeeded - usableItems), totalInBags, smallestStack
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

	-- Find items in inventory
	local totalInBags, items = TOGBankClassic_Bank:CountItemInBags(itemName)

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

	-- Attach items (up to ATTACHMENTS_MAX_SEND slots)
	-- NOTE: Classic Era doesn't support programmatic stack splitting,
	-- so we only attach stacks that won't exceed the needed quantity
	local attached = 0
	local attachmentSlot = 1
	local maxSlots = ATTACHMENTS_MAX_SEND or 12
	local skippedLargeStack = nil

	-- Sort items by stack size (largest first) - full stacks before partial stacks
	-- When counts are equal, maintain the original scan order (bottom-right to top-left in bags)
	-- by adding an index to each item before sorting
	for i, item in ipairs(items) do
		item.originalIndex = i
	end
	table.sort(items, function(a, b)
		if a.count == b.count then
			return a.originalIndex < b.originalIndex  -- Maintain physical order for equal counts
		end
		return a.count > b.count
	end)

	-- FIRST PASS: Calculate minimum useful stack size based on split requirement
	-- Strategy: Don't use stacks smaller than what we'll need to split
	-- Example: Need 95, have [20,20,20,20,14] → need to split 15, so exclude 14
	
	-- Accumulate largest stacks to see what we'd need to split
	local accumulated = 0
	local largestStack = items[1] and items[1].count or 0
	
	for _, item in ipairs(items) do
		if accumulated >= qtyNeeded then
			break
		end
		-- Only accumulate stacks that are at least half the largest stack size
		-- This gets us the "main" stacks and ignores tiny partials
		if item.count >= (largestStack * 0.5) then
			accumulated = accumulated + item.count
		end
	end
	
	-- Calculate what we'd need to split
	local wouldNeedToSplit = math.max(0, qtyNeeded - accumulated)
	
	-- Minimum stack size = the split amount (must be able to split that much from a stack)
	-- If no split needed, use min(5, qtyNeeded) to avoid filtering out perfectly sized stacks
	-- Example: Need 1 item → minStackSize should be 1, not 5
	-- CRITICAL: Never set minStackSize higher than largestStack (fixes non-stackable items like bags)
	local minStackSize = math.min(largestStack, wouldNeedToSplit > 0 and wouldNeedToSplit or math.min(5, qtyNeeded))
	
	-- Build useful stacks list
	local usefulStacks = {}
	for i, item in ipairs(items) do
		if item.count >= minStackSize then
			table.insert(usefulStacks, item)
		end
	end
	
	TOGBankClassic_Output:Debug("FULFILL", "Need %d, accumulated %d from large stacks, would split %d",
		qtyNeeded, accumulated, wouldNeedToSplit)
	TOGBankClassic_Output:Debug("FULFILL", "Filtered %d useful stacks from %d total (min size: %d)",
		#usefulStacks, #items, minStackSize)

	-- SECOND PASS: Run greedy algorithm on useful stacks only
	local simulatedAttached = 0
	local skipStackIndex = nil  -- Track which stack to skip during attachment for optimal fit
	local splitStackIndex = nil  -- Track which stack we'll split from

	-- Greedy pass: accumulate items until we need more than a stack can provide
	-- CRITICAL FIX: Process in TWO stages to prefer exact-fit stacks before splits
	-- Stage 1: Accumulate all stacks that fit exactly without exceeding qtyNeeded
	for i, item in ipairs(usefulStacks) do
		if simulatedAttached >= qtyNeeded then
			break
		end
		local remaining = qtyNeeded - simulatedAttached

		if item.count <= remaining then
			-- This stack fits completely - accumulate it
			simulatedAttached = simulatedAttached + item.count
			TOGBankClassic_Output:Debug("FULFILL", "Stack %d: count=%d, accumulate, total=%d", i, item.count, simulatedAttached)
		end
	end
	
	-- Stage 2: If we didn't get enough, look for a stack to split
	if simulatedAttached < qtyNeeded then
		local remaining = qtyNeeded - simulatedAttached
		for i, item in ipairs(usefulStacks) do
			if item.count > remaining and item.count >= remaining then
				-- This stack can provide the remaining amount
				skippedLargeStack = item
				splitStackIndex = i
				TOGBankClassic_Output:Debug("FULFILL", "Stack %d: count=%d, can split (need %d), mark as candidate", i, item.count, remaining)
				break  -- Found a split candidate, stop looking
			end
		end
	else
		-- We accumulated enough - no split needed
		TOGBankClassic_Output:Debug("FULFILL", "Accumulated enough - no split needed")
	end
	
	TOGBankClassic_Output:Debug("FULFILL", "Greedy result: attached=%d, splitStackIndex=%s", simulatedAttached, tostring(splitStackIndex))

	-- If greedy didn't get exact match AND didn't find a split candidate, try skipping individual stacks to find better fit
	if simulatedAttached < qtyNeeded and totalInBags >= qtyNeeded and not skippedLargeStack then
		for skipIndex = 1, math.min(5, #items) do
			local testAttached = 0
			local testSkippedLargeStack = nil
			local testSplitStackIndex = nil
			for i = 1, #items do
				if i ~= skipIndex then
					local remaining = qtyNeeded - testAttached
					if testAttached >= qtyNeeded then
						break
					elseif items[i].count <= remaining then
						testAttached = testAttached + items[i].count
					elseif items[i].count >= remaining then
						-- This stack can provide the remaining amount - keep track of it
						-- Continue iterating to find the LAST stack that can be split
						testSkippedLargeStack = items[i]
						testSplitStackIndex = i
					else
						-- This stack is too small to split - stop here
						break
					end
				end
			end
			if testAttached == qtyNeeded then
				simulatedAttached = testAttached
				skipStackIndex = skipIndex  -- Remember to skip this stack during attachment
				skippedLargeStack = nil  -- No split needed - found exact match!
				splitStackIndex = nil
				break
			elseif testAttached > simulatedAttached or
			       (testAttached == simulatedAttached and testSplitStackIndex and splitStackIndex and
			        testSplitStackIndex > splitStackIndex) then
				-- Better fit found, or same fit but with split from a later stack (preferred)
				simulatedAttached = testAttached
				skipStackIndex = skipIndex
				skippedLargeStack = testSkippedLargeStack
				splitStackIndex = testSplitStackIndex
			end
		end
	end

	-- If we need to split, show popup FIRST without attaching anything
	if skippedLargeStack then
		local remaining = qtyNeeded - simulatedAttached

		-- Show confirmation popup
		local popupText = string.format("Split %d from stack of %d %s?", remaining, skippedLargeStack.count, itemName)
		local dialog = StaticPopup_Show("TOGBANK_SPLIT_STACK", popupText)
		if dialog then
			dialog.data = {
				bag = skippedLargeStack.bag,
				slot = skippedLargeStack.slot,
				amount = remaining,
				attachmentSlot = attachmentSlot,
				itemName = itemName,
				requester = requester
			}
		end

		local message = string.format("Click Split to prepare %d %s for mailing.", remaining, itemName)
		return false, message, 0
	end

	-- No split needed, proceed with normal attachment
	for i, item in ipairs(usefulStacks) do
		if attached >= qtyNeeded then
			break
		end
		if attachmentSlot > maxSlots then
			break
		end

		-- Skip this stack if it was identified as needing to be skipped for optimal fit
		if not (skipStackIndex and i == skipStackIndex) then
			local remaining = qtyNeeded - attached

			-- Attach full stacks that don't exceed what we need
			if item.count <= remaining then
				ClearCursor()
				C_Container.PickupContainerItem(item.bag, item.slot)
				ClickSendMailItemButton(attachmentSlot)

				attached = attached + item.count
				attachmentSlot = attachmentSlot + 1
			end
		end
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
			items = {{ name = itemName, quantity = attached }}
		}
		self.pendingSendAt = GetTime()
		TOGBankClassic_Output:Debug("MAIL", "PrepareFulfillMail: Set pendingSend for %s (%d %s)", 
			tostring(normRecipient), attached, itemName)
	end
	
	return true, message, attached
end