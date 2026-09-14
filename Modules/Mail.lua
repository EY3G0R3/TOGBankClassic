TOGBankClassic_Mail = {
	-- State for split operation
	splitState = nil  -- {bag, slot, amount, attachmentSlot, request}
}

--- First empty slot in containers `first`..`last`, as (bag, slot), or nil.
---
--- THE ONE empty-slot walk. Three copies existed -- the split popup below, tog_findEmptyBagSlot and
--- FindEmptyBankSlot's inner scan -- and two of them still hardcoded the carried range as `0, 4`
--- after BANKSLOT-001 had fixed every other container walk; the guard in itemhighlight_spec found
--- them the first time it covered this file. Ranges come from Constants.lua (BANKSLOT-001).
local function tog_firstEmptySlot(first, last)
	for bag = first, last do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			if not C_Container.GetContainerItemInfo(bag, slot) then
				return bag, slot
			end
		end
	end
	return nil
end

local function tog_findEmptyBagSlot()
	return tog_firstEmptySlot(TOGBankClassic_Constants.CarriedBagRange())
end

--- The first `n` empty carried-bag slots, as an array of { bag=, slot= } -- fewer when the bags
--- have fewer. MULTIFILL-002: several splits in one click each need their OWN empty slot, and a
--- landed split is not visible to the container API until its deferred pickup fires, so calling
--- tog_findEmptyBagSlot once per split would hand every split the same slot. Enumerate up front.
local function tog_emptyBagSlots(n)
	local out = {}
	local first, last = TOGBankClassic_Constants.CarriedBagRange()
	for bag = first, last do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			if #out >= n then return out end
			if not C_Container.GetContainerItemInfo(bag, slot) then
				out[#out + 1] = { bag = bag, slot = slot }
			end
		end
	end
	return out
end

-- Initialize split stack popup dialog
if not StaticPopupDialogs["TOGBANK_SPLIT_STACK"] then
	StaticPopupDialogs["TOGBANK_SPLIT_STACK"] = {
		text = "%s",
		button1 = "Split",
		button2 = "Cancel",
		OnAccept = function(_, data)
			if not data then return end
			ClearCursor()
			-- Find an empty bag slot to place the split items
			local emptyBag, emptySlot = tog_findEmptyBagSlot()
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
					if TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.isOpen then
						local message = string.format("Split %d %s complete. Click Fulfill again to attach items.",
							data.amount, data.itemName)
						TOGBankClassic_UI_Requests:SetStatusText(message)
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
function TOGBankClassic_Mail:CheckForFulfilledRequest(itemName, _, sender)
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
			if TOGBankClassic_Guild:RequestQuantityNeeded(req) > 0 then
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

	local numItems = GetInboxNumItems()

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

	hooksecurefunc("SendMail", function(recipient)
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
		-- MULTIFILL-001 self-audit: the other direction too. An order the addon attached and the
		-- banker then DETACHED by hand is still in pending.items; crediting it would mark an order
		-- filled that never went. Each entry is cut to what is actually attached under its name,
		-- in order; an entry cut to nothing is dropped. What is attached beyond the entries is the
		-- hand-added extra to spill, as before.
		local attachedByName = {}
		for attachmentIndex = 1, ATTACHMENTS_MAX_SEND do
			local itemName, _, _, quantity = GetSendMailItem(attachmentIndex)
			if itemName and quantity and quantity > 0 then
				attachedByName[itemName] = (attachedByName[itemName] or 0) + quantity
			end
		end
		local kept = {}
		for _, it in ipairs(self.pendingSend.items or {}) do
			local have = attachedByName[it.name] or 0
			local take = math.min(it.quantity or 0, have)
			if take > 0 then
				it.quantity = take
				kept[#kept + 1] = it
				attachedByName[it.name] = have - take
			else
				TOGBankClassic_Output:Debug("MAIL", "STORE", "OnSendMail: %s for request %s is no longer attached -- not credited", tostring(it.name), tostring(it.requestId or self.pendingSend.requestId))
			end
		end
		self.pendingSend.items = kept
		local extras = {}
		for itemName, quantity in pairs(attachedByName) do
			if quantity > 0 then table.insert(extras, { name = itemName, quantity = quantity }) end
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
		local itemName, _, _, quantity = GetSendMailItem(attachmentIndex)
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
		local itemName, itemID, _, quantity = GetSendMailItem(attachmentIndex)
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
	-- MULTIFILL-001: a mail carrying several of one requester's orders has one entry per order,
	-- each with its own id; the envelope's requestId is the first order's and only a fallback.
	for _, item in ipairs(pending.items) do
		local applied = TOGBankClassic_Guild:FulfillRequest(
			pending.sender, pending.recipient, item.name, item.quantity, item.requestId or pending.requestId)
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
	TOGBankClassic_Core:ScheduleTimer(function()
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

	-- Was `local score = 0`, and luacheck was right that the 0 is never read. Both readers --
	-- the money ledger below and the item ledger in the attachment loop -- sit inside a branch that
	-- assigns `score` first, so the initialiser could not be observed. Dropping it changes no
	-- behaviour; checked by reading both call sites rather than by trusting the warning.
	local score
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
				local name, _, _, level, _, _, _, _, _, _, price = GetItemInfo(link)
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
	TOGBankClassic_Core:ScheduleTimer(function()
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

	-- BANKFILL-001 cleanup: `largestStack` was computed here and never read. Deleted rather than
	-- silenced -- the sort above already means items[1] IS the largest, so anything wanting it can
	-- say so at the point of use.
	local smallestStack = items[#items].count

	-- PHASE 1: Try greedy exact match (accumulate stacks that fit without exceeding)
	local accumulated = 0
	local attachList = {}

	for _, item in ipairs(items) do
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
		for _, item in ipairs(items) do
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
	local qtyNeeded = TOGBankClassic_Guild:RequestQuantityNeeded(request)

	if request.status == "complete" or request.status == "fulfilled" or request.status == "cancelled" then
		return false, "Request is already completed.", 0, 0
	end

	if qtyNeeded == 0 and qtyRequested > 0 then
		return false, "Request is already fulfilled.", 0, 0
	end

	-- Check if items are in bags and find usable stacks
	local totalInBags, items = TOGBankClassic_Bank:CountItemInBags(request.item, request.itemID, request.suffixID)

	-- INV2-RETIRE-003: the "where else is it" hint reads THIS banker's own scan, per source, from
	-- the V2 store (Store:GetAltSourceRecords) -- it used to read the legacy `alt.mail.items` /
	-- `alt.bank.items` sub-tables, which are on their way out. A tuple carries no name, so the
	-- name-only fallback (a request with no itemID, from an old client) cannot match here and reads
	-- as "not found elsewhere"; the itemID path, which every request written since REQ-001 has, is
	-- exact and suffix-aware without a link to parse.
	local Store, Record = TOGBankClassic_Inventory_Store, TOGBankClassic_Inventory_Record
	local guildName = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name
	local targetID     = tonumber(request.itemID) or nil
	local targetSuffix = tonumber(request.suffixID) or nil
	local function hasMatchInSource(source)
		if not (Store and Record and guildName and targetID) then return false end
		for _, rec in ipairs(Store:GetAltSourceRecords(guildName, normActor, source)) do
			if Record.id(rec) == targetID and Record.count(rec) > 0
				and (not targetSuffix or Record.suffix(rec) == targetSuffix) then
				return true
			end
		end
		return false
	end

	if totalInBags == 0 then
		-- Nothing in bags — tell the player where to look
		local inMail = hasMatchInSource("mail")
		local inBank = hasMatchInSource("bank")
		if inMail and inBank then
			return false, "in mail and bank", 0, 0
		elseif inMail then
			return false, "in mail", 0, 0
		elseif inBank then
			return false, "Items not in bags. Pick up from bank first.", 0, 0
		end
		-- FULFIL-003: `inBank` was computed and then ignored here -- every not-in-bags, not-in-mail
		-- request fell through to "pick up from bank first" and wore the bag icon, including an item
		-- the bank does not hold (read off the banker's own screen on 2026-09-12: a recipe mailed out
		-- two days earlier, the request for it still saying "it is in the bank"). The store can only
		-- answer for a request that names an itemID; an old name-only request cannot be looked up, so
		-- it keeps the "check the bank" wording rather than claiming an absence nobody verified.
		if targetID and Store and Record and guildName then
			return false, "Not in your bags, bank or mail (as of your last bank scan).", 0, 0
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
		local inMail = hasMatchInSource("mail")
		local inBank = hasMatchInSource("bank")
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

--- Whether ANY send slot holds something, and the first free slot. Slot 1 alone is not the test
--- (self-audit, MULTIFILL-001): a banker who detaches slot 1 by hand leaves slots 2+ loaded, and a
--- path that read slot 1 as "the mail is empty" would start a fresh pending send over orders still
--- attached -- crediting them to nobody when the mail went.
---@return boolean anyAttached, number|nil firstFree nil when every slot is taken
local function tog_sendSlots()
	local maxSlots = ATTACHMENTS_MAX_SEND or 12
	local any, firstFree = false, nil
	for i = 1, maxSlots do
		if GetSendMailItem(i) then any = true elseif not firstFree then firstFree = i end
	end
	return any, firstFree
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
	local qtyNeeded = TOGBankClassic_Guild:RequestQuantityNeeded(request)

	if qtyNeeded <= 0 then
		return false, "Request is already fulfilled.", 0
	end

	-- Find items in inventory (REQ-003: suffix-aware so we attach the requested variant only)
	local totalInBags, items = TOGBankClassic_Bank:CountItemInBags(itemName, request.itemID, request.suffixID)

	if totalInBags == 0 then
		return false, "No " .. itemName .. " found in bags.", 0
	end

	-- MULTIFILL-001 (operator 2026-09-13: "if 1 person has 4 requests for a banker, we can fill all
	-- the requests in one mail?"): a mail the addon has already loaded for THIS requester takes the
	-- next order too -- click Fulfill on each of their rows, then Send once. The open mail is
	-- theirs when pendingSend names the same recipient (set only by this function and FulfillStep,
	-- so a hand-built mail never qualifies); anyone else's mail is still refused, with their name.
	local normRecipient = TOGBankClassic_Guild:NormalizeName(requester)
	local maxSlots = ATTACHMENTS_MAX_SEND or 12
	local attachmentSlot = 1
	local anyAttached, firstFree = tog_sendSlots()
	if anyAttached then
		local pend = self.pendingSend
		if not (pend and pend.items and pend.recipient == normRecipient) then
			return false, string.format("The open mail already has items attached%s. Send or clear it first.",
				pend and pend.recipient and (" for " .. pend.recipient) or ""), 0
		end
		if not firstFree then
			return false, string.format("The mail for %s is full (%d attachments). Send it first.", requester, maxSlots), 0
		end
		attachmentSlot = firstFree
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

	-- No split needed, attach items from plan, from the first free slot on. A later free slot may
	-- be past an occupied one (a hand-detached slot), so each stack takes the next FREE slot.
	local attached = 0

	for _, stack in ipairs(plan.stacksToAttach) do
		if attached >= qtyNeeded then
			break
		end
		while attachmentSlot <= maxSlots and GetSendMailItem(attachmentSlot) do
			attachmentSlot = attachmentSlot + 1
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
	-- This ensures pendingSend is set BEFORE MAIL_SEND_SUCCESS fires.
	-- MULTIFILL-001: every order on the mail is one entry in `items`, each carrying ITS request id,
	-- so ApplyPendingSend credits each order by id; `requestId` on the envelope is the first order's
	-- (kept for the entries and readers that predate this). An added order appends to the pending
	-- send already open for this recipient.
	if attached > 0 then
		local sender = TOGBankClassic_Guild:GetNormalizedPlayer()
		local entry = { name = itemName, quantity = attached, requestId = request.id }
		if anyAttached and self.pendingSend and self.pendingSend.recipient == normRecipient then
			table.insert(self.pendingSend.items, entry)
			message = string.format("Attached %d %s for %s -- %d orders on this mail. Click Send to complete.",
				attached, itemName, requester, #self.pendingSend.items)
		else
			self.pendingSend = {
				sender = sender,
				recipient = normRecipient,
				requestId = request.id,
				items = { entry },
			}
		end
		self.pendingSendAt = GetTime()
		TOGBankClassic_Output:Debug("MAIL", "STORE", "PrepareFulfillMail: pendingSend for %s (%d %s) - requestId=%s, %d order(s) on the mail",
			tostring(normRecipient), attached, itemName, tostring(request.id), #self.pendingSend.items)
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
			local qtyNeeded = TOGBankClassic_Guild:RequestQuantityNeeded(req)
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

--- MULTIFILL-001: the SAME requester's other open orders for this banker that the bags can fill,
--- oldest first, that fit in the slots left -- so Fulfill Oldest sends one mail per person rather
--- than one per order (the operator: "if 1 person has 4 requests for a banker, we can fill all the
--- requests in one mail"). `claimed` is the set of "bag:slot" stacks already promised to the mail
--- (the first order's, then each extra's), so two orders for the same item never plan the same
--- stack.
---
--- MULTIFILL-002 (the operator, 2026-09-13, four 1x orders from four 5-stacks sent as FOUR mails:
--- "it should do all the splitting first for ONE recipient, create the mail, attach everything to
--- one mail, then send it"): an extra that needs a SPLIT rides too. Its split takes one attachment
--- slot and claims its SOURCE stack, the same way IDLE claims the first order's -- so a second order
--- wanting to split the same stack finds it claimed and waits for the next mail (its plan is built
--- on the unclaimed stacks only, and none is left). The SPLIT phase performs every split in one
--- click.
---@param normActor string
---@param requester string the first order's requester, as stored on the request
---@param excludeId any the first order's id
---@param claimed table "bag:slot" -> true, extended in place
---@param slotsLeft number attachment slots still free after the first order
---@return table extras array of { req=, plan=, qty= }, oldest first
function TOGBankClassic_Mail:FindMoreOrdersFor(normActor, requester, excludeId, claimed, slotsLeft)
	local extras = {}
	local info = TOGBankClassic_Guild.Info
	local requests = info and info.requests
	if not requests or slotsLeft <= 0 then return extras end
	local candidates = {}
	for _, req in pairs(requests) do
		if req.id ~= excludeId and (req.status or "open") == "open" and req.requester == requester
			and req.bank and TOGBankClassic_Guild:NormalizeName(req.bank) == normActor
			and TOGBankClassic_Guild:RequestQuantityNeeded(req) > 0 then
			candidates[#candidates + 1] = req
		end
	end
	table.sort(candidates, function(a, b)
		local da, db = tonumber(a.date) or 0, tonumber(b.date) or 0
		if da ~= db then return da < db end
		return tostring(a.id) < tostring(b.id)
	end)
	for _, req in ipairs(candidates) do
		if slotsLeft <= 0 then break end
		local qtyNeeded = TOGBankClassic_Guild:RequestQuantityNeeded(req)
		local _, items = TOGBankClassic_Bank:CountItemInBags(req.item, req.itemID, req.suffixID)
		local free, total = {}, 0
		for _, it in ipairs(items or {}) do
			if not claimed[it.bag .. ":" .. it.slot] then
				free[#free + 1] = { bag = it.bag, slot = it.slot, count = it.count }
				total = total + it.count
			end
		end
		if total >= qtyNeeded then
			local plan = self:CalculateFulfillmentPlan(free, qtyNeeded, total)
			local needSlots = #plan.stacksToAttach + (plan.splitStack and 1 or 0)
			if plan.canFulfill and needSlots <= slotsLeft then
				for _, st in ipairs(plan.stacksToAttach) do claimed[st.bag .. ":" .. st.slot] = true end
				if plan.splitStack then claimed[plan.splitStack.bag .. ":" .. plan.splitStack.slot] = true end
				slotsLeft = slotsLeft - needSlots
				extras[#extras + 1] = { req = req, plan = plan, qty = qtyNeeded }
			end
		end
	end
	return extras
end

-- Clear any in-progress stepped fulfillment (e.g. when the mailbox closes).
function TOGBankClassic_Mail:ResetFulfillStep()
	self.batchState = nil
	self.collectState = nil
	self.bankCollectState = nil
end

--- BANKFILL-001 -- true while the player can actually see and move bank contents.
---
--- Frame state is ground truth, exactly as IsMailboxOpen uses it: the container API answers for bank
--- slots only while the bank is open, so this is not a convenience check. Away from a banker,
--- FindItemsInBank returns EMPTY, which means "not visible from here" and must never be read as
--- "the bank does not have it" -- the same conflation INV2-VAULT-001 was.
function TOGBankClassic_Mail:IsBankOpen()
	return (BankFrame and BankFrame:IsShown()) or false
end

--- The oldest open order for this banker that the BANK could help fill, plus how much is still
--- missing from bags.
---
--- BANKFILL-001. Deliberately a SEPARATE search from FindOldestServiceableOrder rather than a flag
--- on it: that function decides what to work on AT THE MAILBOX, and bank stock is unreachable from
--- there. Teaching it about the bank would make it select orders it cannot fill and skip ones it
--- can, which is a regression in the existing button dressed up as a feature.
--- @return table|nil req, number shortfall how many more are needed than bags hold
function TOGBankClassic_Mail:FindOldestBankFillableOrder(normActor)
	local info = TOGBankClassic_Guild.Info
	local requests = info and info.requests
	if not requests then return nil, 0 end
	local best, bestShort
	for _, req in pairs(requests) do
		if (req.status or "open") == "open"
			and req.bank and TOGBankClassic_Guild:NormalizeName(req.bank) == normActor then
			local qtyNeeded = TOGBankClassic_Guild:RequestQuantityNeeded(req)
			if qtyNeeded > 0 then
				local inBags = TOGBankClassic_Bank:CountItemInBags(req.item, req.itemID, req.suffixID)
				local shortfall = qtyNeeded - inBags
				if shortfall > 0 then
					local inBank = TOGBankClassic_Bank:CountItemInBank(req.item, req.itemID, req.suffixID)
					if inBank > 0 then
						-- Oldest first, with the same stable id tiebreak the mailbox search uses so
						-- the two agree about what "oldest" means.
						local d  = tonumber(req.date) or 0
						local bd = best and (tonumber(best.date) or 0) or nil
						if not best or d < bd or (d == bd and tostring(req.id) < tostring(best.id)) then
							-- The TRUE shortfall, not capped at what the bank holds: the pick below already
							-- takes the largest stack when nothing covers it, and the status message
							-- reports "of the N needed" from this number, so capping it under-reported N.
							best, bestShort = req, shortfall
						end
					end
				end
			end
		end
	end
	return best, bestShort
end

--- COLLECT-002: everything this banker's OPEN orders ask for -- by id, and by lowercased name for
--- the legacy requests that carry no id -- so the swap step never puts an order's item into the
--- bank to make room for another order's. Every open order counts, not only the ones still short:
--- a stack that already covers an order is exactly what must stay in the bags.
--- @return table { id = { [itemID]=true }, name = { [lowername]=true } }
function TOGBankClassic_Mail:ItemsOpenOrdersNeed(normActor)
	local needed = { id = {}, name = {} }
	local info = TOGBankClassic_Guild.Info
	local requests = info and info.requests
	if not requests then return needed end
	for _, req in pairs(requests) do
		if (req.status or "open") == "open"
			and req.bank and TOGBankClassic_Guild:NormalizeName(req.bank) == normActor then
			if tonumber(req.itemID) then needed.id[tonumber(req.itemID)] = true end
			if type(req.item) == "string" and req.item ~= "" then needed.name[string.lower(req.item)] = true end
		end
	end
	return needed
end

--- Advance the stepped BANK collection one action. Returns (ok, message).
---
--- BANKFILL-001, and the operator's framing is the design: *"it pulls from your bags, splits it,
--- then attaches it. i need the same pull/split/put back into the bank. the mail isn't close enough
--- to a bank to fill it, but you need to be able to collect everything you need from the bank
--- quickly."*
---
--- So this is the COLLECTION half, and it runs at the bank with the mailbox shut. Per click:
---   pull one matching stack out of the bank, and if that stack overshoots what the order needs,
---   split the surplus back INTO the bank so you walk away carrying exactly the order.
---
--- States: nil(idle) -> "return"(only when the pulled stack overshot) -> nil.
function TOGBankClassic_Mail:BankCollectStep(actor)
	if not self:IsBankOpen() then
		self.bankCollectState = nil
		return false, "Open your bank first — bank contents can only be moved while the bank is open."
	end

	local normActor = TOGBankClassic_Guild:NormalizeName(actor)
	if not normActor then return false, "Could not work out which character you are." end
	-- Same gate FulfillStep applies. The button is only built for bankers, but that is a property
	-- of one caller and this is a public method (AUDIT-S3/S4: a guard at the call site is a guard
	-- with a half-life).
	if not TOGBankClassic_Guild:IsBank(normActor) then
		return false, "Only bank characters can collect for orders."
	end

	local st = self.bankCollectState

	-- RETURN: the previous click pulled a stack bigger than the order needed. Put the surplus back
	-- so the bank keeps it, rather than leaving the banker to sort their bags out by hand.
	if st and st.phase == "return" then
		local rows = TOGBankClassic_Bank:FindItemsByName(st.item, st.itemID, st.suffixID)
		local source
		for _, row in ipairs(rows) do
			if row.count >= st.surplus then source = row; break end
		end
		if not source then
			-- The stack has not landed in bags yet (UseContainerItem is async), or the player moved
			-- it. Give it a bounded number of clicks, then let go: a phase that can only be exited by
			-- finding a stack is a phase that can strand, and "click again" forever is worse than
			-- leaving the banker holding a few spares.
			st.waits = (st.waits or 0) + 1
			if st.waits >= 3 then
				self.bankCollectState = nil
				return false, string.format(
					"Could not find the %s stack to return the spare %d from — carrying on without it.",
					tostring(st.item), st.surplus)
			end
			return false, "Waiting for the stack to reach your bags — click again."
		end
		local emptyBank = self:FindEmptyBankSlot()
		if not emptyBank then
			self.bankCollectState = nil
			return false, string.format(
				"No free bank slot to put the spare %d back into — you are carrying %d extra %s.",
				st.surplus, st.surplus, tostring(st.item))
		end
		ClearCursor()
		C_Container.SplitContainerItem(source.bag, source.slot, st.surplus)
		local bag, slot = emptyBank.bag, emptyBank.slot
		C_Timer.After(0.1, function() C_Container.PickupContainerItem(bag, slot) end)
		self.bankCollectState = nil
		return true, string.format("Put %d spare %s back in the bank. Click for the next item.",
			st.surplus, tostring(st.item))
	end

	local req, shortfall = self:FindOldestBankFillableOrder(normActor)
	if not req then
		return false, "Nothing left to collect — your bags already cover every order the bank can fill."
	end

	local rows = TOGBankClassic_Bank:FindItemsInBank(req.item, req.itemID, req.suffixID)
	if #rows == 0 then
		return false, string.format("Could not see %s in the bank just now — click again.", tostring(req.item))
	end

	-- Prefer a stack that covers the shortfall exactly or with the least surplus, so the common case
	-- needs no split at all and the bank keeps its stacks tidy.
	local pick = rows[1]
	for _, row in ipairs(rows) do
		local overshoot = row.count - shortfall
		local bestOver  = pick.count - shortfall
		if (overshoot >= 0 and (bestOver < 0 or overshoot < bestOver))
			or (overshoot < 0 and bestOver < 0 and row.count > pick.count) then
			pick = row
		end
	end

	ClearCursor()
	if not TOGBankClassic_Bank:HasInventorySpace() then
		-- COLLECT-002 (Discord, NanaTheBanana: "if the bag is full, it will swap items in the
		-- inventory for the missing items"; the operator: "put things into the bank when the bags
		-- are full that aren't needed to fill an order"). Full bags used to stop the click dead.
		-- Now the click SWAPS: pick up a carried stack no open order of this banker needs and drop
		-- it onto the bank stack we want -- the client exchanges the two, so the wanted stack lands
		-- in that bag slot and the spare goes to the bank. No free slot is needed on either side,
		-- which is the point: a full bank could not take a plain move-out either. Same pick, same
		-- surplus handling below, so the return phase behaves exactly as for a plain pull.
		local spare = TOGBankClassic_Bank:FindUnneededBagStack(self:ItemsOpenOrdersNeed(normActor))
		if not spare then
			return false, "Bags are full and everything in them is needed for an order — make room, then click again."
		end
		C_Container.PickupContainerItem(spare.bag, spare.slot)
		local bag, slot = pick.bag, pick.slot
		C_Timer.After(0.1, function() C_Container.PickupContainerItem(bag, slot) end)
		local surplus = pick.count - shortfall
		if surplus > 0 then
			self.bankCollectState = {
				phase = "return", surplus = surplus,
				item = req.item, itemID = req.itemID, suffixID = req.suffixID,
			}
		else
			self.bankCollectState = nil
		end
		return true, string.format("Bags full: swapped %d %s into the bank for %d %s (%s needs %d).%s",
			spare.count, tostring(spare.name), pick.count, tostring(req.item), tostring(req.requester), shortfall,
			surplus > 0 and string.format(" Click to put the spare %d back.", surplus) or " Click for more.")
	end

	C_Container.UseContainerItem(pick.bag, pick.slot)   -- bank slot + bank open = move to bags

	local surplus = pick.count - shortfall
	if surplus > 0 then
		self.bankCollectState = {
			phase = "return", surplus = surplus,
			item = req.item, itemID = req.itemID, suffixID = req.suffixID,
		}
		return true, string.format(
			"Pulled %d %s for %s. Click to put the spare %d back in the bank.",
			pick.count, tostring(req.item), tostring(req.requester), surplus)
	end

	self.bankCollectState = nil
	return true, string.format("Pulled %d of the %d %s needed for %s. Click for more.",
		pick.count, shortfall, tostring(req.item), tostring(req.requester))
end

--- First empty slot in the bank vault or its bags, or nil. BANKFILL-001.
--- @return table|nil { bag = number, slot = number }
function TOGBankClassic_Mail:FindEmptyBankSlot()
	local bag, slot = tog_firstEmptySlot(BANK_CONTAINER, BANK_CONTAINER)
	if not bag then
		bag, slot = tog_firstEmptySlot(TOGBankClassic_Constants.BankBagRange())   -- BANKSLOT-001
	end
	return bag and { bag = bag, slot = slot } or nil
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
		if (tog_sendSlots()) then
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
		-- MULTIFILL-001: the same person's other orders ride on this mail. The first order's stacks
		-- (and the split's own slot) are claimed before the extras plan theirs.
		local claimed = {}
		for _, stack in ipairs(plan.stacksToAttach or {}) do claimed[stack.bag .. ":" .. stack.slot] = true end
		-- The split's SOURCE stack too (self-audit): the split takes from it before ATTACH runs, so
		-- an extra planned on its full count would attach the remainder and be credited the plan.
		if plan.splitStack then claimed[plan.splitStack.bag .. ":" .. plan.splitStack.slot] = true end
		local used = #(plan.stacksToAttach or {}) + (plan.splitStack and 1 or 0)
		local extras = self:FindMoreOrdersFor(normActor, req.requester, req.id, claimed, (ATTACHMENTS_MAX_SEND or 12) - used)
		-- MULTIFILL-002: every split the mail needs -- the first order's and each extra's -- is one
		-- list, performed together by the SPLIT phase. `extra = nil` marks the first order's.
		local splits = {}
		if plan.splitStack then splits[#splits + 1] = { src = plan.splitStack } end
		for _, extra in ipairs(extras) do
			if extra.plan.splitStack then splits[#splits + 1] = { src = extra.plan.splitStack, extra = extra } end
		end
		self.batchState = {
			req = req, plan = plan, requester = req.requester, qty = qtyNeeded, extras = extras,
			splits = splits,
			phase = #splits > 0 and "split" or "attach",
		}
		local more = #extras > 0 and string.format(" (+%d more of their orders)", #extras) or ""
		if #splits > 0 then
			return true, string.format("Order: %dx %s for %s%s. Click to SPLIT.", qtyNeeded, req.item, req.requester, more)
		end
		return true, string.format("Order: %dx %s for %s%s. Click to ATTACH.", qtyNeeded, req.item, req.requester, more)
	end

	-- SPLIT: split each needed amount into its own free bag slot as its own stack (like the manual
	-- split), so it sits in your bags rather than on the cursor. The place into the slot is deferred
	-- a frame (matches the manual split timing); ATTACH waits for every one to land.
	--
	-- MULTIFILL-002: ALL the mail's splits run from this one click, 0.25s apart, each split's pickup
	-- 0.1s after it -- so a pickup has cleared the cursor before the next split loads it (the client
	-- refuses a split onto a loaded cursor). Every timer is scheduled here, flat, rather than each
	-- pickup from inside its split's callback: the same sequence with no nesting to get wrong. The
	-- empty slots are enumerated up front: a split that has not been picked up yet is invisible to
	-- the container API, so a per-split search would hand every split the same slot.
	if st.phase == "split" then
		local empties = tog_emptyBagSlots(#st.splits)
		if #empties < #st.splits then
			if #st.splits == 1 then
				return false, "Need one free bag slot to split into — make room, then click again."
			end
			return false, string.format("Need %d free bag slots to split into — make room, then click again.", #st.splits)
		end
		local total = 0
		for i, s in ipairs(st.splits) do
			local dst = empties[i]
			s.bag, s.slot = dst.bag, dst.slot
			total = total + s.src.amount
			local at = (i - 1) * 0.25
			local function doSplit()
				ClearCursor()
				C_Container.SplitContainerItem(s.src.bag, s.src.slot, s.src.amount)   -- onto cursor
			end
			if i == 1 then doSplit() else C_Timer.After(at, doSplit) end
			C_Timer.After(at + 0.1, function()
				C_Container.PickupContainerItem(dst.bag, dst.slot)                     -- drop into the free slot
			end)
		end
		st.phase = "attach"
		if #st.splits == 1 then
			local s = st.splits[1]
			return true, string.format("Split %d %s into your bags. Click to ATTACH.", total, (s.extra and s.extra.req or st.req).item)
		end
		return true, string.format("Splitting %d stacks (%d items) into your bags. Click to ATTACH.", #st.splits, total)
	end

	-- ATTACH: attach each order's freshly-split stack (now in the bag) then its whole stacks --
	-- the first order, then each extra.
	if st.phase == "attach" then
		for _, s in ipairs(st.splits or {}) do
			if s.bag and not C_Container.GetContainerItemInfo(s.bag, s.slot) then
				-- A split hasn't committed to the bag yet (clicked too fast).
				return false, "Still placing the split — click ATTACH again."
			end
		end
		local slot = 1
		local maxSlots = ATTACHMENTS_MAX_SEND or 12
		local function splitFor(extra)
			for _, s in ipairs(st.splits or {}) do
				if s.extra == extra and s.bag then return s end
			end
		end
		local function attachOrder(plan, extra)
			local s = splitFor(extra)
			if s then
				ClearCursor()
				C_Container.PickupContainerItem(s.bag, s.slot)
				ClickSendMailItemButton(slot)
				slot = slot + 1
				s.bag, s.slot = nil, nil
			end
			for _, stack in ipairs(plan.stacksToAttach) do
				if slot > maxSlots then break end
				ClearCursor()
				C_Container.PickupContainerItem(stack.bag, stack.slot)
				ClickSendMailItemButton(slot)
				slot = slot + 1
			end
		end
		attachOrder(st.plan, nil)
		-- MULTIFILL-001: the same person's other orders, planned in IDLE against the slots left. An
		-- extra that no longer fits is dropped whole -- never half an order -- and stays open for
		-- the next mail (its split stack, if any, simply sits in the bags).
		local attachedExtras = {}
		for _, extra in ipairs(st.extras or {}) do
			local need = #extra.plan.stacksToAttach + (splitFor(extra) and 1 or 0)
			if slot + need - 1 <= maxSlots then
				attachOrder(extra.plan, extra)
				attachedExtras[#attachedExtras + 1] = extra
			end
		end
		st.extras = attachedExtras
		st.phase = "send"
		local more = #attachedExtras > 0 and string.format(" and %d more of their orders", #attachedExtras) or ""
		return true, string.format("Attached %dx %s for %s%s. Click to SEND.", st.qty, st.req.item, st.requester, more)
	end

	-- SEND: mail it. pendingSend mirrors PrepareFulfillMail so MAIL_SEND_SUCCESS →
	-- ApplyPendingSend → Guild:FulfillRequest marks THIS request (by id).
	if st.phase == "send" then
		local req = st.req
		if not (tog_sendSlots()) then
			-- Nothing actually attached (e.g. the cursor was disturbed mid-sequence).
			-- Don't send an empty mail or falsely mark the order filled.
			self.batchState = nil
			return false, "Nothing is attached — start the order again."
		end
		-- MULTIFILL-001: one entry per order on the mail, each with its own id (ApplyPendingSend
		-- credits by item.requestId); the envelope's requestId is the first order's.
		local items = { { name = req.item, quantity = st.qty, requestId = req.id } }
		for _, extra in ipairs(st.extras or {}) do
			items[#items + 1] = { name = extra.req.item, quantity = extra.qty, requestId = extra.req.id }
		end
		self.pendingSend = {
			sender    = normActor,
			recipient = TOGBankClassic_Guild:NormalizeName(st.requester),
			requestId = req.id,
			items     = items,
		}
		self.pendingSendAt = GetTime()
		SendMail(st.requester, "Guild Bank Order", "")
		-- Block re-selecting this order until the send confirms (or 5s safety).
		self.batchInFlight = true
		C_Timer.After(5, function() self.batchInFlight = false end)
		self.batchState = nil
		if #items > 1 then
			return true, string.format("Sent %d orders (%dx %s and %d more) to %s. Click for the next order.", #items, st.qty, req.item, #items - 1, st.requester)
		end
		return true, string.format("Sent %dx %s to %s. Click for the next order.", st.qty, req.item, st.requester)
	end

	self.batchState = nil
	return false, "Reset — click to start the next order."
end
