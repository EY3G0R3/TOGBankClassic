TOGBankClassic_UI_Mail = {}

function TOGBankClassic_UI_Mail:Init()
	self:DrawWindow()
end

local function OnClose(_)
	TOGBankClassic_UI_Mail.isOpen = false
	TOGBankClassic_UI_Mail.Window:Hide()
end

function TOGBankClassic_UI_Mail:Open()
	if self.isOpen then
		return
	end
	self.isOpen = true

	if not self.Window then
		self:DrawWindow()
	end

	self.Content:ReleaseChildren()
	self.Window:Show()

	-- NOTE: Call the delayed version to give time for inbox data to be fetched
	self:RedrawContent()
end

function TOGBankClassic_UI_Mail:Close()
	if not self.isOpen then
		return
	end
	if not self.Window then
		return
	end

	OnClose(self.Window)
end

function TOGBankClassic_UI_Mail:SetMailId(id)
	self.MailId = id
end

function TOGBankClassic_UI_Mail:DrawWindow()
	local window = TOGBankClassic_UI:Create("Frame")
	window:Hide()
	window:SetCallback("OnClose", OnClose)
	window:SetTitle("Donation")
	window:SetLayout("Flow")
	window:SetWidth(440)
	window:SetHeight(550)
	window:EnableResize(false)
	window.statustext:GetParent():Hide()

	self.Window = window

	local openButton = TOGBankClassic_UI:Create("Button")
	openButton:SetText("Open")
	openButton:SetWidth(100)
	openButton:SetHeight(21)
	openButton:SetCallback("OnClick", function(_)
		openButton:SetDisabled(true)
		TOGBankClassic_Mail:Open(self.MailId)
	end)
	window:AddChild(openButton)

	self.OpenButton = openButton

	local content = TOGBankClassic_UI:Create("SimpleGroup")
	content:SetLayout("List")
	content:SetFullWidth(true)
	content:SetFullHeight(true)
	content.content:ClearAllPoints()
	content.content:SetPoint("TOPLEFT", 10, -10)
	content.content:SetPoint("BOTTOMRIGHT", -10, 10)
	window:AddChild(content)

	self.Content = content
end

function TOGBankClassic_UI_Mail:DrawContent()
	self.Content:ReleaseChildren()
	self.Content:ResumeLayout()

	local _, _, sender, subject, money, CODAmount, _, itemCount, _, wasReturned, _, _, _, _ =
		GetInboxHeaderInfo(self.MailId)
	if not sender then
		TOGBankClassic_UI_Mail:RedrawContent()
		return
	end

	local color = "ff888888"
	local class = TOGBankClassic_Guild:GetPlayerInfo(sender)
	if class then
		_, _, _, color = GetClassColor(class)
	end

	local senderGroup = TOGBankClassic_UI:Create("InlineGroup")
	senderGroup:SetTitle("Sender")
	senderGroup:SetLayout("Flow")
	senderGroup:SetFullWidth(true)
	self.Content:AddChild(senderGroup)

	local senderField = TOGBankClassic_UI:Create("Label")
	senderField:SetText(string.format("|c%s%s|r", color, sender))
	senderGroup:AddChild(senderField)

	local subjectGroup = TOGBankClassic_UI:Create("InlineGroup")
	subjectGroup:SetTitle("Subject")
	subjectGroup:SetLayout("Flow")
	subjectGroup:SetFullWidth(true)
	self.Content:AddChild(subjectGroup)

	local subjectField = TOGBankClassic_UI:Create("Label")
	subjectField:SetText(subject)
	subjectGroup:AddChild(subjectField)

	local bodyText, _, _, _ = GetInboxText(self.MailId)
	if bodyText then
		local bodyGroup = TOGBankClassic_UI:Create("InlineGroup")
		bodyGroup:SetTitle("Body")
		bodyGroup:SetLayout("Fill")
		bodyGroup:SetFullWidth(true)
		bodyGroup:SetHeight(150)
		self.Content:AddChild(bodyGroup)

		local scrollBody = TOGBankClassic_UI:Create("ScrollFrame")
		scrollBody:SetLayout("Flow")
		scrollBody:SetFullHeight(true)
		scrollBody:SetFullWidth(true)
		bodyGroup:AddChild(scrollBody)

		local body = TOGBankClassic_UI:Create("Label")
		body:SetFullWidth(true)
		body:SetFullHeight(true)
		body:SetText(bodyText)
		scrollBody:AddChild(body)
	end

	if money and money > 0 then
		local moneyGroup = TOGBankClassic_UI:Create("InlineGroup")
		moneyGroup:SetTitle("Money")
		moneyGroup:SetLayout("Flow")
		moneyGroup:SetFullWidth(true)
		self.Content:AddChild(moneyGroup)

		local moneyField = TOGBankClassic_UI:Create("Label")
		moneyField:SetText(GetCoinTextureString(money))
		moneyGroup:AddChild(moneyField)
	end

	local itemGroup = TOGBankClassic_UI:Create("InlineGroup")
	itemGroup:SetTitle("Items")
	itemGroup:SetLayout("Flow")
	itemGroup:SetFullWidth(true)

	local showItems = false
	local items = {}
	for attachmentIndex = 1, ATTACHMENTS_MAX_RECEIVE do
		local mail = GetInboxItem(self.MailId, attachmentIndex)
		if mail ~= nil then
			local link = GetInboxItemLink(self.MailId, attachmentIndex)
			if link then
				if not showItems then
					showItems = true
				end

				if not TOGBankClassic_Item:IsUnique(link) then
					local id = GetItemInfoInstant(link)
					local _, _, _, quantity, _ = GetInboxItem(self.MailId, attachmentIndex)
					table.insert(items, { ID = id, Link = link, Count = quantity })
				end
			else
				---START CHANGES
				self:RedrawContent()
				---END CHANGES
				return
			end
		end
	end

	if showItems then
		self.Content:AddChild(itemGroup)
		TOGBankClassic_Item:GetItems(items, function(list)
			for _, item in pairs(list) do
				TOGBankClassic_UI:DrawItem(item, itemGroup, 30, 35, 30, 30, 0, 5)
			end
		end)
	end

	self.ScoreMail = true
	local checkbox = TOGBankClassic_UI:Create("CheckBox")
	checkbox:SetValue(self.ScoreMail)
	checkbox:SetLabel("Add to score")
	checkbox:SetWidth(100)
	checkbox:SetCallback("OnValueChanged", function(target)
		self.ScoreMail = target:GetValue()
	end)
	self.Content:AddChild(checkbox)

	self.Content:PauseLayout()

	checkbox:ClearAllPoints()
	checkbox:SetPoint("CENTER")
	checkbox:SetPoint("BOTTOM")

	self.OpenButton:ClearAllPoints()
	self.OpenButton:SetPoint("BOTTOMLEFT", 10, -23.5)
	self.OpenButton:SetDisabled(false)
end

function TOGBankClassic_UI_Mail:RedrawContent()
	TOGBankClassic_Core:ScheduleTimer(function(...)
		TOGBankClassic_UI_Mail:OnTimer()
	end, 0.25)
end

function TOGBankClassic_UI_Mail:OnTimer()
	TOGBankClassic_UI_Mail:DrawContent()
end

