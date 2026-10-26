TOGBankClassic_Mail = {
	-- State for split operation
	splitState = nil  -- {bag, slot, amount, attachmentSlot, request}
}

-- STORE-007: how long after crediting a mail's money the same sender + amount is still that mail
-- (Mail:Open re-enters itself on a 1 s timer; the server usually clears the money well inside
-- this). Seconds.
local MONEY_CREDIT_WINDOW = 10

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

--- MAIL-SPLIT-MERGE-001 (the operator, 2026-09-16: "say i need 8 of an item and i have 5. the
--- splitter will split off another 3 and then send the stacks of 3 and 5 as 2 attachments to the
--- mail. this costs an extra 30c"): the stack in `attachList` a split of `amount` from `src` can be
--- dropped ONTO, so the order goes as one attachment. Nil when none has room under the item's max
--- stack (GetItemInfo's 8th return), when that size is unknown, or when the slots no longer hold
--- the same item -- a name-matched legacy order can mix same-name variants, which never stack.
--- Returns a copy carrying the target's `itemID`, so a later click can confirm the slot is unchanged.
local function tog_mergeTarget(attachList, src, amount)
	local srcInfo = C_Container.GetContainerItemInfo(src.bag, src.slot)
	local itemID = srcInfo and srcInfo.itemID
	local maxStack = itemID and tonumber((select(8, GetItemInfo(itemID))))
	if not maxStack then return nil end
	for _, stack in ipairs(attachList) do
		if stack.count + amount <= maxStack then
			local info = C_Container.GetContainerItemInfo(stack.bag, stack.slot)
			if info and info.itemID == itemID then
				return { bag = stack.bag, slot = stack.slot, count = stack.count, itemID = itemID }
			end
		end
	end
	return nil
end

--- Whether the merge target recorded by tog_mergeTarget still holds what the plan saw.
local function tog_mergeTargetIntact(onto)
	local info = C_Container.GetContainerItemInfo(onto.bag, onto.slot)
	return info ~= nil and info.itemID == onto.itemID and (info.stackCount or 1) == onto.count
end

--- How many attachments one outgoing mail holds. Peer Review 024ada6d F2: the one spelling of the cap
--- -- it was written out at nine sites, and the capped-mail message and the planner must agree. A
--- function rather than a file-scope local because ATTACHMENTS_MAX_SEND is the client's mail frame
--- constant, read at call time.
local function tog_mailCap()
	return ATTACHMENTS_MAX_SEND or 12
end

--- Attachment slots a plan takes: its whole stacks, plus one for a split that is not merged onto
--- one of them (MAIL-SPLIT-MERGE-001).
local function tog_planSlots(plan)
	return #(plan.stacksToAttach or {}) + ((plan.splitStack and not plan.splitStack.onto) and 1 or 0)
end

--- MAIL-SLOTCAP-001 (Peer Review bf89d59d B1): a plan needing more attachment slots than one mail
--- holds (an order for 13 Linen held as 13 single stacks) used to be attached only up to slot 12 and
--- then credited in full, so the order was marked filled for items that never left the bags. A plan
--- that does not fit is cut to the first maxSlots whole stacks (CalculateFulfillmentPlan lists them
--- largest first) with no split, and the quantity returned is what those stacks hold -- the order is
--- credited that much, stays open, and remains the oldest, so the next click mails the rest.
--- @return table plan, number qty the quantity this mail carries
local function tog_capPlanToMail(plan, qty)
	local maxSlots = tog_mailCap()
	if tog_planSlots(plan) <= maxSlots then return plan, qty end
	local stacks, carried = {}, 0
	for i = 1, maxSlots do
		local stack = plan.stacksToAttach[i]
		if not stack then break end
		stacks[i] = stack
		carried = carried + stack.count
	end
	return {
		canFulfill = true,
		stacksToAttach = stacks,
		splitStack = nil,
		totalAttachable = carried,
		requiresMailbox = true,
		cappedFrom = qty,  -- what the order needs in all; FulfillStep says this mail is only part of it
	}, carried
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
			-- MAIL-SPLIT-MERGE-001: drop the split onto the order's partial stack when the plan found
			-- one and it is unchanged since the popup opened; otherwise into an empty bag slot.
			local emptyBag, emptySlot
			if data.onto and tog_mergeTargetIntact(data.onto) then
				emptyBag, emptySlot = data.onto.bag, data.onto.slot
			else
				emptyBag, emptySlot = tog_findEmptyBagSlot()
			end
			if not emptyBag then
				-- SPLIT-ROOM-001 (Discord, 2026-10-24: "actions should not fail silently"): this
				-- returned with no word to the banker, so clicking Split with full bags did nothing.
				local message = string.format("No free bag slot to split %s into. Make room, then click Fulfill again.",
					tostring(data.itemName))
				TOGBankClassic_Output:Warn("%s", message)
				if TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.isOpen then
					TOGBankClassic_UI_Requests:SetStatusText(message)
				end
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
						-- HANDOFF-SPLIT-001: a split for an in-person hand-off is traded, not attached.
						local message = data.handoff
							and string.format("Split %d %s complete. Trade the order to %s, then use Mark hand-off.",
								data.amount, data.itemName, tostring(data.requester))
							or string.format("Split %d %s complete. Click Fulfill again to attach items.",
								data.amount, data.itemName)
						-- Refresh the request list to update the fulfill button icon -- FIRST. SPLIT-STATUS-001:
						-- DrawContent writes its own "Showing N requests" line, and it ran after this message,
						-- so the banker never saw "Trade the order ..." or "Click Fulfill again" (found by the
						-- end-to-end example in requestsactions_spec; Cancel Stale had the same order fixed).
						TOGBankClassic_UI_Requests:DrawContent()
						TOGBankClassic_UI_Requests:SetStatusText(message)
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
	-- DONATIONS-BOX-001 (the operator, 2026-10-07): the per-mail Donation popup opens only when
	-- this character's Bank setting "Enable donations" is ticked, default off. History: v1.5.2's
	-- UX-WATERFALL-001 removed that box and let the Mailbox window's setting govern the popup
	-- instead (it stood aside while the window auto-opened), so unticking the window brought the
	-- popup back with no way to stop it (GUNNEY, Discord, the same day). Both settings are now
	-- independent; a banker who ticks both gets both windows, which is what they asked for. Gifts
	-- taken through the Mailbox window are credited either way (Mail:IsDonation).
	local O = TOGBankClassic_Options
	if not (O and O.GetDonationEnabled and O:GetDonationEnabled()) then
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

			-- Peer Review f5e52bcf F3: the Roster is keyed `Name-Realm` and the header carries the BARE
			-- name for a same-realm sender, so the bare lookup never matched and the popup opened for
			-- a bank-to-bank transfer (IsDonation, normalising, is what kept the CREDIT out).
			local senderNorm = TOGBankClassic_Guild:NormalizeName(sender) or sender
			if
				CODAmount == 0
				and not wasReturned
				and not isGM
				and canReply
				and not self.Roster[senderNorm]
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

--- The send slots as { name, itemID, quantity } rows, slot order, empty slots skipped.
local function tog_readSendSlots()
	local slots = {}
	for i = 1, tog_mailCap() do
		local itemName, itemID, _, quantity = GetSendMailItem(i)
		if itemName and quantity and quantity > 0 then
			slots[#slots + 1] = { name = itemName, itemID = tonumber(itemID), quantity = quantity }
		end
	end
	return slots
end

--- SEND-SNAPSHOT-001 (Peer Review 024ada6d, thread 0872fe66): OnSendMail runs in a hooksecurefunc
--- POST-hook, after SendMail has returned, and reads what went from the send slots. When the client
--- empties those slots is not in its UI source -- MAIL_SEND_SUCCESS only clears the name, subject and
--- body boxes (Classic/MailFrame.lua SendMailFrame_Reset) -- so if it empties them inside SendMail,
--- every addon send would trim to nothing and credit nothing. The slots are therefore also recorded
--- on MAIL_SEND_INFO_UPDATE, the event Blizzard's frame repaints them on. An empty read keeps the last
--- record and notes WHEN it went empty: GetTime() is frozen for a frame, so slots that went empty in
--- the frame of the send were emptied by the send, while slots emptied in an earlier frame were
--- emptied by the banker and the mail really went without them.
function TOGBankClassic_Mail:OnSendInfoUpdate()
	local slots = tog_readSendSlots()
	if #slots > 0 then
		self.sendSlots, self.sendSlotsEmptiedAt = slots, nil
	elseif self.sendSlots and not self.sendSlotsEmptiedAt then
		self.sendSlotsEmptiedAt = GetTime()
	end
end

--- Drop the record (the mailbox closed).
function TOGBankClassic_Mail:ClearSendSnapshot()
	self.sendSlots, self.sendSlotsEmptiedAt = nil, nil
end

--- What this send carried: the live slots, or the record when the send itself emptied them. The
--- record is consumed either way, so it can never stand in for a later mail.
function TOGBankClassic_Mail:SendAttachments()
	local live = tog_readSendSlots()
	local snap, emptiedAt = self.sendSlots, self.sendSlotsEmptiedAt
	self:ClearSendSnapshot()
	local useSnap = #live == 0 and snap ~= nil and (emptiedAt == nil or emptiedAt == GetTime())
	TOGBankClassic_Output:Debug("MAIL", "STORE", "OnSendMail: %d slot(s) attached in the hook, %d recorded on the last update%s",
		#live, snap and #snap or 0, useSnap and " -- using the record" or "")
	if useSnap then return snap end
	return live
end

function TOGBankClassic_Mail:OnSendMail(recipient)
	TOGBankClassic_Output:Debug("MAIL", "STORE", "OnSendMail: HOOK FIRED for recipient=%s", tostring(recipient))
	local attached = self:SendAttachments()

	-- If pendingSend was set recently by PrepareFulfillMail (within 10 seconds), keep it
	-- Otherwise, read items from mail attachments (fallback for non-fulfill mails)
	-- SEND-RECIPIENT-001 (Peer Review f4c6a142, R1): only for a mail to the same person. A pendingSend
	-- outlives a failed send, and the banker can retype the name box after a row Fulfill, so a mail to
	-- Bob carrying the same item would credit Alice's orders. Compared without case, because the
	-- client sends to a name typed in any case.
	local now = GetTime()
	local normRecipient = TOGBankClassic_Guild:NormalizeName(recipient)
	local pendingTo = self.pendingSend and self.pendingSend.recipient
	local sameRecipient = normRecipient ~= nil and pendingTo ~= nil and normRecipient:lower() == pendingTo:lower()
	if sameRecipient and self.pendingSendAt and (now - self.pendingSendAt) < 10 then
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
		-- LOCALE-SENDTRIM-001 (Peer Review 4d7fc1c4): the cut compared the slot's name (the banker's
		-- locale) with it.name (the requester's), so in a mixed-locale guild every entry matched
		-- nothing and the send credited no order. An entry carrying an id is matched to slots by id;
		-- only an entry without one (or a slot the client gave no id) still falls back to the name.
		-- An entry has no id only when its request has none (pre-REQ-001), and such a request was
		-- found in the bags by name, so its name is the banker's own and the fallback still matches.
		-- Random-suffix siblings ("of the Bear" / "of the Monkey") share one base id, so an id match
		-- alone could hand one order its sibling's slot when the banker detached its own. So EVERY
		-- entry first takes slots matching id AND name (same locale: exact), and only after all of
		-- them have does any entry take what is left by id alone.
		local pool = {}
		for _, s in ipairs(attached) do
			pool[#pool + 1] = { name = s.name, itemID = s.itemID, left = s.quantity }
		end
		local function matches(it, p, exact)
			if it.itemID and p.itemID then
				return p.itemID == it.itemID and (not exact or p.name == it.name)
			end
			return p.name == it.name
		end
		local entries = self.pendingSend.items or {}
		local taken = {}
		for _, exact in ipairs({ true, false }) do
			for i, it in ipairs(entries) do
				local want = it.quantity or 0
				taken[i] = taken[i] or 0
				for _, p in ipairs(pool) do
					if taken[i] >= want then break end
					if p.left > 0 and matches(it, p, exact) then
						local n = math.min(p.left, want - taken[i])
						p.left, taken[i] = p.left - n, taken[i] + n
					end
				end
			end
		end
		local kept = {}
		for i, it in ipairs(entries) do
			local take = taken[i]
			if take > 0 then
				it.quantity = take
				kept[#kept + 1] = it
			else
				TOGBankClassic_Output:Debug("MAIL", "STORE", "OnSendMail: %s for request %s is no longer attached -- not credited", tostring(it.name), tostring(it.requestId or self.pendingSend.requestId))
			end
		end
		self.pendingSend.items = kept
		-- Peer Review f6aa732c F3: grouped by item id when the slot has one, and the id rides along so
		-- FulfillRequest can match a requester whose order is named in another locale.
		local leftByKey, extras = {}, {}
		for _, p in ipairs(pool) do
			if p.left > 0 then
				local key = p.itemID or p.name
				if not leftByKey[key] then
					leftByKey[key] = { name = p.name, itemID = p.itemID, quantity = 0 }
					extras[#extras + 1] = leftByKey[key]
				end
				leftByKey[key].quantity = leftByKey[key].quantity + p.left
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
	local items = attached

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
	-- Peer Review f6aa732c F5: the one reader of the send slots.
	local items = tog_readSendSlots()
	local totalCount = 0
	for _, item in ipairs(items) do totalCount = totalCount + item.quantity end

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
			tostring(item.itemID),
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
	-- Peer Review f6aa732c F4: every row hands FulfillRequest its item id too, so a manual mail's
	-- slot rows (named in the banker's locale) still match an order named in the requester's.
	for _, item in ipairs(pending.items) do
		local applied = TOGBankClassic_Guild:FulfillRequest(
			pending.sender, pending.recipient, item.name, item.quantity, item.requestId or pending.requestId, item.itemID)
		if applied > 0 then
			TOGBankClassic_Output:Info("  Applied %dx %s toward %s's order(s)", applied, item.name, pending.recipient)
		end
		totalApplied = totalApplied + applied
	end

	-- MULTIORDER-001: spill items the banker hand-added to an addon-generated mail (to "save a
	-- mail") across the recipient's OTHER open orders for this banker. nil requestId = match any
	-- of that banker's matching orders (by item id when known, else by name). Empty/absent for
	-- fully manual mails.
	for _, item in ipairs(pending.extraItems or {}) do
		local applied = TOGBankClassic_Guild:FulfillRequest(
			pending.sender, pending.recipient, item.name, item.quantity, nil, item.itemID)
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

--- STORE-007 / UX-WATERFALL-001: is a take from `sender`'s mail a DONATION to credit? The ONE
--- rule, read by both takers -- the Donation popup's Open below and the Mailbox window's TakeRow --
--- so they cannot drift: this character is a bank character, the sender is NOT one (a transfer
--- between bank characters is stock moving, not a gift), and the mail was not returned to us.
--- The sender is normalised first: the inbox header carries the BARE name for a same-realm
--- sender, and the banker set is keyed `Name-Realm`, so the old bare lookup never matched and a
--- banker's transfer was credited as a donation (found lifting this, 2026-09-14). `score` is the
--- popup's "Add to score" box, true when the caller has no such box.
---@param sender string as the inbox header spells it
---@param wasReturned boolean|nil the header's returned flag
---@param score boolean|nil
---@return boolean
function TOGBankClassic_Mail:IsDonation(sender, wasReturned, score)
	if score == false or wasReturned then return false end
	local G = TOGBankClassic_Guild
	if not (G and G.Info and sender) then return false end
	local me = G:GetNormalizedPlayer()
	if not (me and G:IsBank(me)) then return false end
	local from = G:NormalizeName(sender)
	if from and G:IsBank(from) then return false end
	return true
end

--- STORE-007: credit the money of one mail, ONCE. Open takes one thing and re-enters itself a
--- second later (RetryOpen) so the server can act in between; if the server has not cleared the
--- money by then the header still shows it and the branch runs again -- the take is harmless (the
--- server refuses), the credit is not. So the same sender and amount inside the window is the
--- same mail, not a second gift. The Mailbox window takes money once per row and shares the rule
--- at no cost.
function TOGBankClassic_Mail:CreditMoney(sender, money)
	local key = tostring(sender) .. "|" .. tostring(money)
	local last = self.lastMoneyCredit
	local nowTs = GetServerTime()
	if last and last.key == key and nowTs - last.at <= MONEY_CREDIT_WINDOW then return false end
	self.lastMoneyCredit = { key = key, at = nowTs }
	TOGBankClassic_Donations:Credit({ donor = sender, kind = "money", copper = money, source = "mail", statistic = "money" })
	return true
end

--- STORE-007: credit one attachment -- valued NOW and written once: the conservative statistic
--- of the price library, floored at what a vendor pays (`price`, GetItemInfo's sell price), never
--- re-priced later. A unique item is not credited: the client may refuse the take when one is
--- already held, and a credit for a stack still in the mail is a credit for nothing.
---
--- Peer Review f5e52bcf F4: the SAME retry that CreditMoney guards against runs for items -- Open
--- credits, takes, and re-enters a second later; a slow server still shows the attachment and the
--- branch credited it AGAIN. So the same mail slot, link and count from the same sender inside the
--- window is the same stack, not a second gift (`slot` = "mailId:attachmentIndex"; the Mailbox
--- window's rows pass none and take once). KNOWN COST, the money guard's: two identical gifts in
--- two mails taken inside ten seconds credit once.
function TOGBankClassic_Mail:CreditItem(sender, link, name, quantity, price, slot)
	if TOGBankClassic_Item:IsUnique(link) then return false end
	if slot then
		local key = tostring(sender) .. "|" .. tostring(slot) .. "|" .. tostring(link) .. "|" .. tostring(quantity)
		local last = self.lastItemCredit
		local nowTs = GetServerTime()
		if last and last.key == key and nowTs - last.at <= MONEY_CREDIT_WINDOW then return false end
		self.lastItemCredit = { key = key, at = nowTs }
	end
	local D = TOGBankClassic_Donations
	local itemID = GetItemInfoInstant and GetItemInfoInstant(link) or nil
	local copper, valued = D:Value(itemID, quantity, price)
	D:Credit({
		donor = sender, kind = "item", itemID = itemID, name = name, count = quantity,
		copper = copper, source = valued.source, statistic = valued.statistic, age = valued.age,
	})
	return true
end

function TOGBankClassic_Mail:Open(mailId)
	local _, _, sender, _, money, _, _, itemCount, _, wasReturned, _, _, _, _ = GetInboxHeaderInfo(mailId)
	if not sender then
		TOGBankClassic_Mail:RetryOpen(mailId)
		return
	end

	local info = TOGBankClassic_Guild.Info
	if not info then
		return
	end

	-- STORE-007: the credit is written by TOGBankClassic_Donations (this character's own ledger,
	-- valued and locked here at ingest), not into `alt.ledger` any more. The "Add to score" box on
	-- the Donation window is honoured through IsDonation.
	local credit = self:IsDonation(sender, wasReturned, TOGBankClassic_UI_Mail.ScoreMail)
	if money > 0 then
		if TOGBankClassic_Options:GetBankReporting() then
			TOGBankClassic_Output:Info("Received %s gold from %s", money / 10000, sender)
		end
		if credit then self:CreditMoney(sender, money) end

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

					if credit then self:CreditItem(sender, link, name, quantity, price, mailId .. ":" .. attachmentIndex) end

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
	-- say so at the point of use. (`smallestStack` went the same way with the dead branch below,
	-- COVERAGE-MAIL-001.)

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
			-- MAIL-SPLIT-MERGE-001: `onto` is the attached stack the split drops onto, when one has room.
			local onto = tog_mergeTarget(attachList, splitCandidate, remaining)
			return {
				canFulfill = true,
				reason = onto
					and string.format("Split %d from stack of %d onto the stack of %d.", remaining, splitCandidate.count, onto.count)
					or string.format("Split %d from stack of %d.", remaining, splitCandidate.count),
				stacksToAttach = attachList,
				splitStack = {
					bag = splitCandidate.bag,
					slot = splitCandidate.slot,
					count = splitCandidate.count,
					amount = remaining,
					onto = onto,
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

	-- COVERAGE-MAIL-001: a "single large stack" branch stood here (accumulated == 0 and every stack
	-- larger than the need). It could not run: for qtyNeeded > 0 that case is PHASE 3's -- items[1] is
	-- an unattached stack >= the need -- and qtyNeeded == 0 returns at PHASE 1. Only a negative need
	-- reached it, and then it answered canFulfill with a negative split. Deleted.
	--
	-- Reached by a negative need, or when the caller's totalInBags is more than `items` holds (every
	-- shipped caller passes the sum of `items`): fail closed rather than plan a split from stacks that
	-- are not there.
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
	local maxSlots = tog_mailCap()
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
	local maxSlots = tog_mailCap()
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
		local popupText = splitInfo.onto
			and string.format("Split %d from stack of %d %s onto your stack of %d?",
				splitInfo.amount, splitInfo.count, itemName, splitInfo.onto.count)
			or string.format("Split %d from stack of %d %s?", splitInfo.amount, splitInfo.count, itemName)
		-- StaticPopup_Show's 4th argument is the dialog's data (StaticPopup.lua:278/376, Era and TBC).
		StaticPopup_Show("TOGBANK_SPLIT_STACK", popupText, nil, {
			bag = splitInfo.bag,
			slot = splitInfo.slot,
			amount = splitInfo.amount,
			onto = splitInfo.onto,   -- MAIL-SPLIT-MERGE-001
			itemName = itemName,
			requester = requester
		})

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
		local entry = { name = itemName, itemID = tonumber(request.itemID), quantity = attached, requestId = request.id }
		if anyAttached and self.pendingSend and self.pendingSend.recipient == normRecipient then
			table.insert(self.pendingSend.items, entry)
			-- COVERAGE-MAIL-001: an order that ran out of slots on this mail must still SAY it is partial.
			-- This line used to replace the partial notice with "Click Send to complete" for any added
			-- order, so a banker appending a 20-order to a mail with one slot left was told the order was
			-- done when only half of it was attached.
			if attached >= qtyNeeded then
				message = string.format("Attached %d %s for %s -- %d orders on this mail. Click Send to complete.",
					attached, itemName, requester, #self.pendingSend.items)
			else
				message = string.format("Attached %d of %d %s (partial) -- %d orders on this mail. Click Send, then fulfill again.",
					attached, qtyNeeded, itemName, #self.pendingSend.items)
			end
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

--- HANDOFF-SPLIT-001 (Discord, 2026-10-24: "addon does not split the stacks unless i'm creating the
--- mail. could the individual action button split the stacks please"): away from a mailbox, the
--- row's Fulfill button splits the order's amount off into its own stack, ready to trade, through the
--- same Split popup the mail path uses. Nothing is credited here -- the banker records the trade
--- with Mark hand-off, as before.
---@return boolean ok, string message
function TOGBankClassic_Mail:PrepareHandoffSplit(request)
	if not request or not request.item or not request.requester then
		return false, "Invalid request."
	end
	local itemName, requester = request.item, request.requester
	local qtyNeeded = TOGBankClassic_Guild:RequestQuantityNeeded(request)
	if qtyNeeded <= 0 then
		return false, "Request is already fulfilled."
	end
	local totalInBags, items = TOGBankClassic_Bank:CountItemInBags(itemName, request.itemID, request.suffixID)
	if totalInBags == 0 then
		return false, "No " .. itemName .. " found in bags."
	end
	local plan = self:CalculateFulfillmentPlan(items, qtyNeeded, totalInBags)
	if not plan.canFulfill then
		return false, plan.reason
	end
	if not plan.splitStack then
		return false, string.format("Your bags already hold %d %s in whole stacks. Trade them to %s, then use Mark hand-off.",
			qtyNeeded, itemName, requester)
	end
	local s = plan.splitStack
	local popupText = s.onto
		and string.format("Split %d from stack of %d %s onto your stack of %d, to hand to %s?",
			s.amount, s.count, itemName, s.onto.count, requester)
		or string.format("Split %d from stack of %d %s to hand to %s?", s.amount, s.count, itemName, requester)
	StaticPopup_Show("TOGBANK_SPLIT_STACK", popupText, nil, {
		bag = s.bag, slot = s.slot, amount = s.amount, onto = s.onto,
		itemName = itemName, requester = requester, handoff = true,
	})
	return false, string.format("Click Split to make %d %s ready to trade to %s.", qtyNeeded, itemName, requester)
end

-- FILLALL-001: stepped batch fulfillment. One WoW action per click — split,
-- attach and send each happen on a separate click (separate frame) so the cursor
-- and bag state settle between actions; doing it all in one click raced the send
-- ahead of the split. The banker spams the envelope icon to walk the oldest
-- fully-fillable order through: select -> (split) -> attach -> send, then the next
-- click selects the next-oldest. Decisions: oldest-first (FIFO by date); no
-- partials (only orders we can fully fill from bags); an unfillable order still
-- holds its place for its item (FCFS-001, see FindOldestServiceableOrder). The split is attached
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
		-- LINK-AUDIT-001 step 4: id and suffix from the one link parser, no client call.
		local _, linkSuffix, lid = TOGBankClassic_Inventory_Scan.parseLink(link)
		if lid ~= targetID then return false end
		local targetSuffix = tonumber(req.suffixID)
		if targetSuffix then
			return linkSuffix == targetSuffix
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

-- nil for an order with no usable name (Peer Review 104ff6f7 N1): tostring(nil) made every nameless
-- order share the key "nil", so a nameless no-id order was held by every nameless id order.
local function tog_nameKey(req)
	if type(req.item) == "string" and req.item ~= "" then return string.lower(req.item) end
	return nil
end

-- The key a no-id order of this order's name has; the one spelling tog_orderKey and tog_poolFor share.
local function tog_noIdKey(req)
	local name = tog_nameKey(req)
	return name and ("n:" .. name) or nil
end

-- The pool an order draws from: item id + suffix, or the lowercased name for a legacy order with no
-- id. Every order with the same key competes for the same stacks. nil for an order with neither,
-- which then competes with nothing.
local function tog_orderKey(req)
	return TOGBankClassic_Inventory_Record.requestKey(req.itemID, req.suffixID) or tog_noIdKey(req)
end

-- SUFFIX-KEY-001 (Peer Review bf89d59d): an order with NO suffix is counted against every variant of
-- its item (CountItemInBags with no suffix matches them all), so it competes with an "of the Bear"
-- order of the same item, though their keys differ. Such orders still exist: one stored before
-- INV2-SUFFIX-001, one from an old client, one placed by another addon through Guild:AddRequest. Two
-- orders compete when they share a key, or share an item id and either has no suffix. A pool sums an
-- amount per order and answers "how much of it do THIS order's competitors hold" -- the one rule the
-- mailbox hold, the ride-along reservation and the bank shortfall all apply.
--
-- NAME-POOL-001 (Peer Review 1aa094de F1): the same holds one level up. A legacy order with no item id
-- is counted in the bags by NAME (Bank MatchContainers), so it takes every item of that name, id or
-- not; it competes with every order whose stored name equals its own, and every such order competes
-- with it. Over-holding where two items share a name is the safe direction, as for suffixes.
local function tog_newPool()
	return { key = {}, id = {}, name = {} }
end

local function tog_hasSuffix(req)
	local s = tonumber(req.suffixID)
	return s ~= nil and s ~= 0
end

local function tog_poolAdd(pool, req, n)
	local key = tog_orderKey(req)
	if key then pool.key[key] = (pool.key[key] or 0) + n end
	local id = tonumber(req.itemID)
	if id then pool.id[id] = (pool.id[id] or 0) + n end
	local name = tog_nameKey(req)
	if name then pool.name[name] = (pool.name[name] or 0) + n end
end

local function tog_poolFor(pool, req)
	local id = tonumber(req.itemID)
	local name = tog_nameKey(req)
	if not id then return name and pool.name[name] or 0 end
	local noIdKey = tog_noIdKey(req)
	local noId = noIdKey and pool.key[noIdKey] or 0   -- the no-id orders of this order's name
	if not tog_hasSuffix(req) then return (pool.id[id] or 0) + noId end
	return (pool.key[tog_orderKey(req)] or 0)
		+ (pool.key[TOGBankClassic_Inventory_Record.requestKey(id, 0)] or 0)
		+ noId
end

-- The one definition of "oldest" lives on Guild (RequestOlderFirst), shared with FulfillRequest.
local function tog_olderFirst(a, b)
	return TOGBankClassic_Guild.RequestOlderFirst(a, b)
end

-- This banker's open orders that still need something, oldest first.
local function tog_openOrdersOldestFirst(normActor)
	local open = {}
	local info = TOGBankClassic_Guild.Info
	local requests = info and info.requests
	if not requests then return open end
	for _, req in pairs(requests) do
		if (req.status or "open") == "open"
			and req.bank and TOGBankClassic_Guild:NormalizeName(req.bank) == normActor
			and TOGBankClassic_Guild:RequestQuantityNeeded(req) > 0 then
			open[#open + 1] = req
		end
	end
	table.sort(open, tog_olderFirst)
	return open
end

-- Oldest open order for normActor serviceable from bags, or from bags + the mail
-- inbox. Returns (req, bagsReady, plan, qtyNeeded). bagsReady=true → can be fully
-- attached from bags now (plan computed); false → some of its items are in the
-- mail and need pulling into bags first.
--
-- FCFS-001 (the operator, 2026-10-09, on crimsonmane's Discord report that Fulfill Oldest "does not
-- fulfill the oldest order first": "you are supposed to fill the oldest order first. first come first
-- server"): an order that cannot be filled yet still holds its place in the queue for ITS item. It
-- used to be skipped, and the next order that fit went out -- so a newer order for fewer of the same
-- item was mailed ahead of the older one, spending the stock the older order was waiting on. Now the
-- first unfillable order for an item blocks every newer order for that item; orders for OTHER items
-- are unaffected, because they do not compete for the same stacks.
function TOGBankClassic_Mail:FindOldestServiceableOrder(normActor)
	local blocked = tog_newPool()
	local firstHeld   -- the oldest order holding its item's queue, for the "nothing to send" message
	for _, req in ipairs(tog_openOrdersOldestFirst(normActor)) do
		if tog_poolFor(blocked, req) == 0 then
			local qtyNeeded = TOGBankClassic_Guild:RequestQuantityNeeded(req)
			local totalInBags, items = TOGBankClassic_Bank:CountItemInBags(req.item, req.itemID, req.suffixID)
			if totalInBags >= qtyNeeded then
				local plan = self:CalculateFulfillmentPlan(tog_copyItems(items), qtyNeeded, totalInBags)
				if plan.canFulfill then
					local mailPlan, mailQty = tog_capPlanToMail(plan, qtyNeeded)
					return req, true, mailPlan, mailQty
				end
			else
				local inboxQty = tog_inboxQtyFor(req)
				if inboxQty > 0 and (totalInBags + inboxQty) >= qtyNeeded then
					return req, false, nil, qtyNeeded  -- bags + mail can cover it; pull the mail items first
				end
			end
			tog_poolAdd(blocked, req, 1)
			firstHeld = firstHeld or req
		end
	end
	return nil, nil, nil, nil, firstHeld
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
--- slot (none when it merges onto one of its own stacks, MAIL-SPLIT-MERGE-001) and claims its SOURCE stack, the same way IDLE claims the first order's -- so a second order
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
	if slotsLeft <= 0 then return extras end
	-- FCFS-001: what OTHER people's older orders still need of each item. Their claim on the bags comes
	-- first, so an extra rides only on stock left over after them -- riding along must not let this
	-- requester's newer order jump someone else's older one.
	local reservedBefore = tog_newPool()
	for _, req in ipairs(tog_openOrdersOldestFirst(normActor)) do
		if req.requester ~= requester then
			tog_poolAdd(reservedBefore, req, TOGBankClassic_Guild:RequestQuantityNeeded(req))
		elseif req.id ~= excludeId and slotsLeft > 0 then
			local qtyNeeded = TOGBankClassic_Guild:RequestQuantityNeeded(req)
			local _, items = TOGBankClassic_Bank:CountItemInBags(req.item, req.itemID, req.suffixID)
			local free, total = {}, 0
			for _, it in ipairs(items or {}) do
				if not claimed[it.bag .. ":" .. it.slot] then
					free[#free + 1] = { bag = it.bag, slot = it.slot, count = it.count }
					total = total + it.count
				end
			end
			if total - tog_poolFor(reservedBefore, req) >= qtyNeeded then
				local plan = self:CalculateFulfillmentPlan(free, qtyNeeded, total)
				local needSlots = tog_planSlots(plan)
				if plan.canFulfill and needSlots <= slotsLeft then
					for _, st in ipairs(plan.stacksToAttach) do claimed[st.bag .. ":" .. st.slot] = true end
					if plan.splitStack then claimed[plan.splitStack.bag .. ":" .. plan.splitStack.slot] = true end
					slotsLeft = slotsLeft - needSlots
					extras[#extras + 1] = { req = req, plan = plan, qty = qtyNeeded }
				else
					-- FCFS-SELF-001 (Peer Review bf89d59d): an order of this requester's that does not ride
					-- keeps its claim too, so their own newer order of the item cannot spend its stock.
					tog_poolAdd(reservedBefore, req, qtyNeeded)
				end
			else
				tog_poolAdd(reservedBefore, req, qtyNeeded)
			end
		end
	end
	return extras
end

-- Clear any in-progress stepped fulfillment (e.g. when the mailbox closes).
function TOGBankClassic_Mail:ResetFulfillStep()
	self.batchState = nil
	self.collectStates = nil
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
	-- Oldest first, by the same ordering the mailbox search uses so the two agree about what "oldest"
	-- means.
	local open = tog_openOrdersOldestFirst(normActor)
	-- BANKCOLLECT-SHARE-001 (Discord, crimsonmane 2026-10-08: Fulfill Oldest "does not fulfill the
	-- oldest order first"): the bags are ONE pool shared by every order for the same item. Each order
	-- used to be measured against the whole bag count, so the stack pulled for an older order also
	-- "covered" a newer order of the same item, and the newer one was never collected for. The bags
	-- are now handed out oldest-first, and each order's shortfall is what is left after the older
	-- orders' share.
	-- SUFFIX-KEY-001: a no-suffix order shares the pool with every variant's orders. For a suffixed
	-- order the no-suffix orders' share is subtracted whole, though some of it may be another variant's
	-- stacks -- the error is toward collecting a stack too many, never toward leaving an order short.
	local given = tog_newPool()
	-- Peer Review bf89d59d B2 asked for the mailbox's per-item hold here. It is not needed: orders with
	-- one key match the same bank stock, so when the bank cannot help an older order it cannot help a
	-- newer one of that item either, and the newer one is never collected for ahead of it.
	for _, req in ipairs(open) do
		local qtyNeeded = TOGBankClassic_Guild:RequestQuantityNeeded(req)
		local inBags = TOGBankClassic_Bank:CountItemInBags(req.item, req.itemID, req.suffixID)
		local free = math.max(0, inBags - tog_poolFor(given, req))
		tog_poolAdd(given, req, math.min(free, qtyNeeded))
		local shortfall = qtyNeeded - free
		if shortfall > 0 and TOGBankClassic_Bank:CountItemInBank(req.item, req.itemID, req.suffixID) > 0 then
			-- The TRUE shortfall, not capped at what the bank holds: the pick below already takes the
			-- largest stack when nothing covers it, and the status message reports "of the N needed"
			-- from this number, so capping it under-reported N.
			return req, shortfall
		end
	end
	return nil, 0
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
			-- NAMEKEY-ONE-SPELLING-001 (Peer Review 074cdad6 A3): the one name-key rule, not a copy of it.
			if tog_nameKey(req) then needed.name[tog_nameKey(req)] = true end
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
	-- FOREVER-BANK-001: the one list of bank containers -- the vault then the bank bags on Classic,
	-- same order as before; the character bank tabs on Forever, where BANK_CONTAINER is nil.
	for _, container in ipairs(TOGBankClassic_Constants.BankContainers()) do
		local bag, slot = tog_firstEmptySlot(container, container)
		if bag then return { bag = bag, slot = slot } end
	end
	return nil
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
		local req, bagsReady, plan, qtyNeeded, held = self:FindOldestServiceableOrder(normActor)
		if not req then
			if held then
				-- BANKCOLLECT-FCFS-001: say which order is first in line, so a banker holding stock for
				-- a newer order knows why it is not going out.
				return false, string.format(
					"Nothing to send yet — %s's order for %dx %s is first in line and your bags and mail can't cover it.",
					tostring(held.requester), TOGBankClassic_Guild:RequestQuantityNeeded(held), tostring(held.item))
			end
			return false, "No orders you can fully fill from your bags or mail right now."
		end

		-- COLLECT: the oldest serviceable order's items are (partly) in the mail.
		-- Pull one matching item from the inbox into bags per click; once enough is
		-- in bags, the next click selects + fulfills it. Stay in IDLE meanwhile.
		if not bagsReady then
			-- Pull only as many as the order is short, then stop — never empty the
			-- mail of an item just because there are several copies. Taking an inbox
			-- item is async (it lands in bags a moment later), so we count what we've
			-- already pulled (cs.pulled) against the deficit rather than
			-- relying on the live bag count, which lags.
			--
			-- COLLECT-LAG-001 (Peer Review bf89d59d): kept PER ORDER. For a moment a pulled stack is in
			-- neither the inbox nor the bags, so this order can read blocked and another be served; one
			-- shared state was replaced then, and recomputed from the lagging bag count when this order
			-- came back -- pulling again what was already on its way. Cleared when the mailbox closes.
			self.collectStates = self.collectStates or {}
			local cs = self.collectStates[req.id]
			if not cs then
				local inBagsNow = TOGBankClassic_Bank:CountItemInBags(req.item, req.itemID, req.suffixID)
				cs = { toPull = math.max(0, qtyNeeded - inBagsNow), pulled = 0 }
				self.collectStates[req.id] = cs
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
		if self.collectStates then self.collectStates[req.id] = nil end  -- bags can cover it now; collecting done

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
		local used = tog_planSlots(plan)
		local extras = self:FindMoreOrdersFor(normActor, req.requester, req.id, claimed, tog_mailCap() - used)
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
		-- MAIL-SLOTCAP-001 self-audit F2 (Peer Review 4d7fc1c4): a capped mail is only part of the
		-- order, and "Order: 12x" alone reads as the whole of it.
		local amount = string.format("%dx", qtyNeeded)
		if plan.cappedFrom then
			amount = string.format("%d of %dx", qtyNeeded, plan.cappedFrom)
			more = more .. string.format(" (one mail holds %d stacks; the rest goes next)", tog_mailCap())
		end
		if #splits > 0 then
			return true, string.format("Order: %s %s for %s%s. Click to SPLIT.", amount, req.item, req.requester, more)
		end
		return true, string.format("Order: %s %s for %s%s. Click to ATTACH.", amount, req.item, req.requester, more)
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
	--
	-- MAIL-SPLIT-MERGE-001: a split whose plan found room on one of its order's own stacks (`src.onto`)
	-- drops onto that stack instead, needs no free slot, and ATTACH waits for the stack to read the
	-- merged count. If the target changed since the order was picked, the batch restarts rather than
	-- dropping the split onto something else.
	if st.phase == "split" then
		local needFree = 0
		for _, s in ipairs(st.splits) do
			if s.src.onto then
				if not tog_mergeTargetIntact(s.src.onto) then
					self.batchState = nil
					return false, "Your bags changed since the order was picked — click to start it again."
				end
			else
				needFree = needFree + 1
			end
		end
		local empties = tog_emptyBagSlots(needFree)
		-- SPLIT-ROOM-001 (Discord, 2026-10-24: three orders each needing a split, two free bag slots,
		-- and nothing split): fewer free slots than splits used to refuse the WHOLE mail, with only a
		-- status-bar line to say why. Now the splits that fit go ahead -- the first order's first, as
		-- it is the oldest -- and each extra order whose split has no slot is left off this mail, still
		-- open, for the next one. Only a first order with no slot for its own split stops the click.
		local heldBack = 0
		if #empties < needFree then
			local kept, dropped, room = {}, {}, #empties
			for _, s in ipairs(st.splits) do
				if s.src.onto or room > 0 then
					if not s.src.onto then room = room - 1 end
					kept[#kept + 1] = s
				elseif not s.extra then
					local message = "Need a free bag slot to split into — make room, then click again."
					TOGBankClassic_Output:Warn("%s", message)
					return false, message
				else
					dropped[s.extra] = true
					heldBack = heldBack + 1
				end
			end
			local extras = {}
			for _, extra in ipairs(st.extras or {}) do
				if not dropped[extra] then extras[#extras + 1] = extra end
			end
			st.extras, st.splits = extras, kept
			TOGBankClassic_Output:Warn("Not enough free bag slots to split all of %s's orders: %d held for the next mail.",
				tostring(st.requester), heldBack)
		end
		local held = heldBack > 0
			and string.format(" %d of their orders held for the next mail (not enough free bag slots).", heldBack)
			or ""
		if #st.splits == 0 then
			st.phase = "attach"
			return true, "Nothing left to split." .. held .. " Click to ATTACH."
		end
		local total, nextEmpty = 0, 1
		for i, s in ipairs(st.splits) do
			local dst
			if s.src.onto then
				dst = s.src.onto
				s.merged, s.expect = true, dst.count + s.src.amount
			else
				dst = empties[nextEmpty]
				nextEmpty = nextEmpty + 1
			end
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
			local item = (s.extra and s.extra.req or st.req).item
			if s.merged then
				return true, string.format("Split %d %s onto your stack of %d.%s Click to ATTACH.", total, item, s.src.onto.count, held)
			end
			return true, string.format("Split %d %s into your bags.%s Click to ATTACH.", total, item, held)
		end
		return true, string.format("Splitting %d stacks (%d items) into your bags.%s Click to ATTACH.", #st.splits, total, held)
	end

	-- ATTACH: attach each order's freshly-split stack (now in the bag) then its whole stacks --
	-- the first order, then each extra.
	if st.phase == "attach" then
		for _, s in ipairs(st.splits or {}) do
			local landed = s.bag and C_Container.GetContainerItemInfo(s.bag, s.slot)
			-- MAIL-SPLIT-MERGE-001: a merged split has landed only once its target reads the merged count,
			-- and any split only once the server has released the slot's lock -- picking up a locked
			-- stack does nothing, and the mail would go without it.
			if s.bag and not (landed and not landed.isLocked
				and (not s.merged or (landed.stackCount or 1) == s.expect)) then
				-- A split hasn't committed to the bag yet (clicked too fast).
				return false, "Still placing the split — click ATTACH again."
			end
		end
		local slot = 1
		local maxSlots = tog_mailCap()
		local function splitFor(extra)
			for _, s in ipairs(st.splits or {}) do
				if s.extra == extra and s.bag then return s end
			end
		end
		-- Returns how many items it attached, which is what the order is credited (MAIL-SLOTCAP-001):
		-- the plan is capped to one mail in IDLE, so this should equal the plan, but a mail that ran
		-- out of slots must never be credited for stacks left behind.
		local function attachOrder(plan, extra)
			local attached = 0
			local s = splitFor(extra)
			-- A merged split rides on its target, which the whole-stack loop below attaches.
			if s and not s.merged then
				ClearCursor()
				C_Container.PickupContainerItem(s.bag, s.slot)
				ClickSendMailItemButton(slot)
				slot = slot + 1
				attached = attached + s.src.amount
				s.bag, s.slot = nil, nil
			end
			for _, stack in ipairs(plan.stacksToAttach) do
				if slot > maxSlots then break end
				ClearCursor()
				C_Container.PickupContainerItem(stack.bag, stack.slot)
				ClickSendMailItemButton(slot)
				slot = slot + 1
				attached = attached + stack.count
			end
			if s and s.merged then attached = attached + s.src.amount end
			return attached
		end
		st.qty = math.min(st.qty, attachOrder(st.plan, nil))
		-- MULTIFILL-001: the same person's other orders, planned in IDLE against the slots left. An
		-- extra that no longer fits is dropped whole -- never half an order -- and stays open for
		-- the next mail (its split stack, if any, simply sits in the bags).
		local attachedExtras = {}
		for _, extra in ipairs(st.extras or {}) do
			local es = splitFor(extra)
			local need = #extra.plan.stacksToAttach + ((es and not es.merged) and 1 or 0)
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
		-- LOCALE-SENDTRIM-001: each entry carries its order's item id, which the send hook trims by.
		local items = { { name = req.item, itemID = tonumber(req.itemID), quantity = st.qty, requestId = req.id } }
		for _, extra in ipairs(st.extras or {}) do
			items[#items + 1] = { name = extra.req.item, itemID = tonumber(extra.req.itemID),
				quantity = extra.qty, requestId = extra.req.id }
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
		-- BATCH-TIMER-001 (Peer Review 030b8a0a, N1): each send's safety timer clears only its own
		-- send. Unguarded, send A's timer could fire while a later send B was still unconfirmed and
		-- free a third click before B confirmed.
		self.batchInFlight = true
		local gen = (self.sendGen or 0) + 1
		self.sendGen = gen
		C_Timer.After(5, function()
			if self.sendGen == gen then self.batchInFlight = false end
		end)
		self.batchState = nil
		if #items > 1 then
			return true, string.format("Sent %d orders (%dx %s and %d more) to %s. Click for the next order.", #items, st.qty, req.item, #items - 1, st.requester)
		end
		return true, string.format("Sent %dx %s to %s. Click for the next order.", st.qty, req.item, st.requester)
	end

	self.batchState = nil
	return false, "Reset — click to start the next order."
end
