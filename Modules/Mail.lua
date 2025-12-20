TOGBankClassic_Mail = {}

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

	local player = TOGBankClassic_Guild:GetPlayer()

	local isBank = false
	local banks = TOGBankClassic_Guild:GetBanks()
	if banks == nil then
		return
	end
	self.Roster = {}
	for _, v in pairs(banks) do
		local norm = (TOGBankClassic_Guild and TOGBankClassic_Guild.NormalizePlayerName)
				and TOGBankClassic_Guild.NormalizePlayerName(v)
			or v
		self.Roster[norm] = true
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
	self.pendingSend = nil
	self.pendingSendAt = nil

	local sender = TOGBankClassic_Guild:GetPlayer()
	local items = {}

	for attachmentIndex = 1, ATTACHMENTS_MAX_SEND do
		local itemName, itemID, texture, quantity = GetSendMailItem(attachmentIndex)
		if itemName and quantity and quantity > 0 then
			table.insert(items, { name = itemName, quantity = quantity })
		end
	end

	if TOGBankClassic_Chat and TOGBankClassic_Chat.debug then
		TOGBankClassic_Core:DebugPrint(
			"OnSendMail:",
			"sender",
			tostring(sender),
			"recipient",
			tostring(recipient),
			"items",
			#items
		)
	end

	if #items == 0 then
		return
	end

	local info = TOGBankClassic_Guild.Info
	if not info or not info.requests or #info.requests == 0 then
		return
	end

	if not sender or not TOGBankClassic_Guild:IsBank(sender) then
		return
	end

	local normalize = TOGBankClassic_Guild.NormalizePlayerName
	local normRecipient = normalize and normalize(recipient) or recipient

	self.pendingSend = {
		sender = sender,
		recipient = normRecipient,
		items = items,
	}
	self.pendingSendAt = GetTime()
end

function TOGBankClassic_Mail:ApplyPendingSend()
	local pending = self.pendingSend
	if not pending then
		return
	end
	self.pendingSend = nil
	self.pendingSendAt = nil

	local totalApplied = 0
	for _, item in ipairs(pending.items) do
		local applied = TOGBankClassic_Guild:FulfillRequest(
			pending.sender,
			pending.recipient,
			item.name,
			item.quantity
		)
		totalApplied = totalApplied + applied
	end

	if totalApplied > 0 then
		TOGBankClassic_Core:Printf("Applied %d item(s) toward requests for %s.", totalApplied, pending.recipient)
		if TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.isOpen then
			TOGBankClassic_UI_Requests:DrawContent()
		end
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
	local norm = (TOGBankClassic_Guild and TOGBankClassic_Guild.NormalizePlayerName)
			and TOGBankClassic_Guild.NormalizePlayerName(player)
		or player

	if not info.alts[norm] then
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
			TOGBankClassic_Core:Printf("Received %s gold from %s", score, sender)
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
			TOGBankClassic_Core:Print("Inventory is full.")
			return
		end

		for attachmentIndex = 1, ATTACHMENTS_MAX_RECEIVE do
			local link = GetInboxItemLink(mailId, attachmentIndex)
			if link then
				local _, _, _, quantity, _ = GetInboxItem(mailId, attachmentIndex)
				local name, _, quality, level, _, _, _, _, _, _, price = GetItemInfo(link)
				if level == nil then
					TOGBankClassic_Mail:RetryOpen(mailId)
					return
				end

				if not TOGBankClassic_Item:IsUnique(link) then
					score = ((price + 1) / 10000) * quantity

					if TOGBankClassic_Options:GetBankReporting() then
						TOGBankClassic_Core:Printf("Received %s (%d) from %s", name, quantity, sender)
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
