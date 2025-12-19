TOGBankClassic_UI_Inventory = {}

function TOGBankClassic_UI_Inventory:Init()
	self:DrawWindow()
end

local function OnClose(_)
	TOGBankClassic_UI_Inventory.isOpen = false
	TOGBankClassic_UI_Inventory.Window:Hide()

	TOGBankClassic_UI_Donations:Close()
	TOGBankClassic_UI_Requests:Close()
	TOGBankClassic_UI_Search:Close()
end

function TOGBankClassic_UI_Inventory:Toggle()
	if self.isOpen then
		self:Close()
	else
		self:Open()
	end
end

function TOGBankClassic_UI_Inventory:Open()
	if self.isOpen then
		return
	end
	self.isOpen = true

	if not self.Window then
		self:DrawWindow()
	end

	self.Window:Show()

	self:DrawContent()

	if _G["TOGBankClassic"] then
		_G["TOGBankClassic"]:Show()
	else
		TOGBankClassic_UI:Controller()
	end
end

function TOGBankClassic_UI_Inventory:Close()
	if not self.isOpen then
		return
	end
	if not self.Window then
		return
	end

	OnClose(self.Window)
end

function TOGBankClassic_UI_Inventory:DrawWindow()
	local window = TOGBankClassic_UI:Create("Frame")
	window:Hide()
	window:SetCallback("OnClose", OnClose)
	window:SetTitle("TOGBankClassic")
	window:SetLayout("Flow")
	window:SetWidth(550)
	--handle keyboard events
	---START CHANGES
	window.frame:SetResizeBounds(500, 500)
	---END CHANGES
	window.frame:EnableKeyboard(true)
	window.frame:SetPropagateKeyboardInput(true)
	window.frame:SetScript("OnKeyDown", function(self, event)
		TOGBankClassic_UI:EventHandler(self, event)
	end)

	self.Window = window

	local buttonContainer = TOGBankClassic_UI:Create("SimpleGroup")
	buttonContainer:SetLayout("Table")
	buttonContainer:SetUserData("table", {
		columns = {
			{
				width = 0.33,
				align = "start",
			},
			{
				width = 0.34,
				align = "end",
			},
			{
				width = 0.33,
				align = "end",
			},
		},
	})
	buttonContainer:SetFullWidth(true)
	---START CHANGES
	--buttonContainer.frame:SetBackdropColor(0, 0, 0, 0)
	--buttonContainer.frame:SetBackdropBorderColor(0, 0, 0, 0)
	---END CHANGES
	buttonContainer.frame:ClearAllPoints()
	buttonContainer.content:SetPoint("TOPLEFT", 0, 5)
	buttonContainer.content:SetPoint("BOTTOMRIGHT", 0, -5)
	window:AddChild(buttonContainer)

	local searchButton = TOGBankClassic_UI:Create("Button")
	searchButton:SetText("Search")
	searchButton:SetCallback("OnClick", function(_)
		TOGBankClassic_UI_Search:Toggle()
	end)
	searchButton:SetWidth(175)
	searchButton:SetHeight(24)
	buttonContainer:AddChild(searchButton)

	local scoreboardButton = TOGBankClassic_UI:Create("Button")
	scoreboardButton:SetText("Donations")
	scoreboardButton:SetCallback("OnClick", function(_)
		TOGBankClassic_UI_Donations:Toggle()
	end)
	scoreboardButton:SetWidth(175)
	scoreboardButton:SetHeight(24)
	buttonContainer:AddChild(scoreboardButton)

	local requestsButton = TOGBankClassic_UI:Create("Button")
	requestsButton:SetText("Requests")
	requestsButton:SetCallback("OnClick", function(_)
		TOGBankClassic_UI_Requests:Toggle()
	end)
	requestsButton:SetWidth(175)
	requestsButton:SetHeight(24)
	buttonContainer:AddChild(requestsButton)

	local tabGroup = TOGBankClassic_UI:Create("TabGroup")
	tabGroup:SetLayout("Flow")
	tabGroup:SetFullWidth(true)
	tabGroup:SetFullHeight(true)
	window:AddChild(tabGroup)

	self.TabGroup = tabGroup
end

function TOGBankClassic_UI_Inventory:DrawContent()
	local info = TOGBankClassic_Guild.Info
	if not info or not info.roster.version then
		OnClose()
		TOGBankClassic_Core:Print("Database is empty; wait for sync.")
		return
	end

	TOGBankClassic_UI_Search:BuildSearchData()

	local players = {}
	local n = 0
	for _, v in pairs(info.roster.alts) do
		n = n + 1
		players[n] = v
	end

	table.sort(players)

	local tabs = {}
	local first_tab = nil
	local total_gold = 0
	local slots = 0
	local total_slots = 0
	local i = 1
	for _, player in pairs(players) do
		local norm = (TOGBankClassic_Guild and TOGBankClassic_Guild.NormalizePlayerName)
				and TOGBankClassic_Guild.NormalizePlayerName(player)
			or player
		local alt = info.alts[norm]
		---START CHANGES
		--if alt then
		if alt and type(alt) == "table" then
			---END CHANGES
			if not first_tab then
				first_tab = player
			end
			tabs[i] = { value = player, text = player }
			if alt.money then
				total_gold = total_gold + alt.money
			end
			if alt.bank then
				slots = slots + alt.bank.slots.count
				total_slots = total_slots + alt.bank.slots.total
			end
			if alt.bags then
				slots = slots + alt.bags.slots.count
				total_slots = total_slots + alt.bags.slots.total
			end
			i = i + 1
		end
	end

	self.TabGroup:SetTabs(tabs)

	local color = TOGBankClassic_UI_Inventory:GetPercentColor(slots / total_slots)
	local defaultStatus =
		string.format("%s    |c%s%d/%d|r", GetCoinTextureString(total_gold), color, slots, total_slots)
	self.Window:SetStatusText(defaultStatus)
	self.Window:SetCallback("OnEnterStatusBar", function(_)
		local tab = self.TabGroup.localstatus.selected
		local normTab = (TOGBankClassic_Guild and TOGBankClassic_Guild.NormalizePlayerName)
				and TOGBankClassic_Guild.NormalizePlayerName(tab)
			or tab
		local alt = info.alts[normTab]

		local datetime = date("%Y-%m-%d %H:%M:%S", alt.version)
		local slot_count = 0
		local slot_total = 0
		if alt.bank then
			slot_count = slot_count + alt.bank.slots.count
			slot_total = slot_total + alt.bank.slots.total
		end
		if alt.bags then
			slot_count = slot_count + alt.bags.slots.count
			slot_total = slot_total + alt.bags.slots.total
		end

		local money = 0
		if alt.money then
			money = alt.money
		end

		local color = TOGBankClassic_UI_Inventory:GetPercentColor(slot_count / slot_total)
		local status = string.format(
			"As of %s    %s    |c%s%d/%d|r",
			datetime,
			GetCoinTextureString(money),
			color,
			slot_count,
			slot_total
		)
		self.Window:SetStatusText(status)
	end)
	self.Window:SetCallback("OnLeaveStatusBar", function(_)
		self.Window:SetStatusText(defaultStatus)
	end)

	self.TabGroup:SetCallback("OnGroupSelected", function(group)
		local tab = group.localstatus.selected

		self.TabGroup:ReleaseChildren()

		local g = TOGBankClassic_UI:Create("SimpleGroup")
		g:SetFullWidth(true)
		g:SetFullHeight(true)
		g:SetLayout("Flow")
		self.TabGroup:AddChild(g)

		local scroll = TOGBankClassic_UI:Create("ScrollFrame")
		scroll:SetLayout("Flow")
		scroll:SetFullHeight(true)
		scroll:SetFullWidth(true)
		g:AddChild(scroll)

		local alt = info.alts[tab]
		local bank = nil
		if alt.bank then
			bank = alt.bank.items
		end
		if alt.bags then
			local items = TOGBankClassic_Item:Aggregate(bank, alt.bags.items)
			TOGBankClassic_Item:GetItems(items, function(list)
				TOGBankClassic_Item:Sort(list)

				for _, item in pairs(list) do
					local itemWidget = TOGBankClassic_UI:DrawItem(item, scroll)
					if itemWidget then
						itemWidget:SetCallback("OnClick", function(widget, event)
							if IsShiftKeyDown() or IsControlKeyDown() then
								TOGBankClassic_UI:EventHandler(widget, event)
								return
							end
							TOGBankClassic_UI_Search:ShowRequestDialog(item, tab)
						end)
					end
				end
			end)
		end
	end)

	self.TabGroup:SelectTab(first_tab)
end

function TOGBankClassic_UI_Inventory:GetPercentColor(percent)
	local color = nil
	if percent <= 0.25 then
		color = "ffffffff"
	elseif percent <= 0.5 then
		color = "ff00ff00"
	elseif percent <= 0.75 then
		color = "ffffff00"
	elseif percent <= 0.9 then
		color = "ffff9900"
	elseif percent > 0.9 then
		color = "ffff0000"
	end
	return color
end
