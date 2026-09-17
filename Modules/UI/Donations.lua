TOGBankClassic_UI_Donations = {}

function TOGBankClassic_UI_Donations:Init()
	-- Frame creation deferred to first Open() call (PERF-015)
end

local function OnClose(_)
	TOGBankClassic_UI_Donations.isOpen = false
	TOGBankClassic_UI_Donations.Window:Hide()
end

function TOGBankClassic_UI_Donations:Toggle()
	if self.isOpen then
		self:Close()
	else
		self:Open()
	end
end

function TOGBankClassic_UI_Donations:Open()
	if self.isOpen then
		return
	end
	self.isOpen = true

	if not self.Window then
		self:DrawWindow()
	end

	self.Window:Show()
	if TOGBankClassic_UI_Inventory.isOpen and TOGBankClassic_UI_Inventory.Window then
		self.Window:ClearAllPoints()
		self.Window:SetPoint("TOPLEFT", TOGBankClassic_UI_Inventory.Window.frame, "TOPRIGHT", 0, 0)
	end

	-- Ensure window stays within screen bounds
	TOGBankClassic_UI:ClampFrameToScreen(self.Window)

	self:DrawContent()

	if _G["TOGBankClassic"] then
		_G["TOGBankClassic"]:Show()
	else
		TOGBankClassic_UI:Controller()
	end
end

function TOGBankClassic_UI_Donations:Close()
	if not self.isOpen then
		return
	end
	if not self.Window then
		return
	end

	OnClose(self.Window)

	if TOGBankClassic_UI_Inventory.isOpen == false then
		_G["TOGBankClassic"]:Hide()
	end
end

function TOGBankClassic_UI_Donations:DrawWindow()
	local donations = TOGBankClassic_UI:Create("Frame")
	donations:Hide()
	donations:SetCallback("OnClose", OnClose)
	donations:SetTitle(TOGBankClassic_UI:WindowTitle("Donations"))
	donations:SetLayout("Flow")
	donations:SetWidth(420)   -- DONATION-VALUE-001: room for the Value column
	donations:EnableResize(false)
	--handle keyboard events
	donations.frame:EnableKeyboard(true)
	donations.frame:SetPropagateKeyboardInput(true)
	donations.frame:SetScript("OnKeyDown", function(self, event)
		TOGBankClassic_UI:EventHandler(self, event)
	end)

	self.Window = donations
	TOGBankClassic_UI:ApplyWindowAlpha("donations", donations)
	self.StatusBar = TOGBankClassic_UI_StatusBar:AttachSides(donations)   -- SYNCED-001

	local content = TOGBankClassic_UI:Create("SimpleGroup")
	content:SetLayout("Table")
	content:SetUserData("table", {
		columns = {
			{
				width = 15,
				align = "CENTERRIGHT",
			},
			{
				width = 0.45,
				alignH = "start",
				alignV = "middle",
			},
			{
				width = 0.2,
				alignH = "end",
				alignV = "middle",
			},
			-- DONATION-VALUE-001: the gold value behind the points.
			{
				width = 0.3,
				alignH = "end",
				alignV = "middle",
			},
		},
		spaceH = 5,
		spaceV = 1,
	})
	content:SetFullWidth(true)
	content:SetFullHeight(true)
	content.content:ClearAllPoints()
	content.content:SetPoint("TOPLEFT", content.frame, "TOPLEFT", 5, -10)
	donations:AddChild(content)

	self.Content = content
end

function TOGBankClassic_UI_Donations:DrawContent()
	self.Window:SetStatusText("")
	self.Content:ReleaseChildren()

	local info = TOGBankClassic_Guild.Info
	if not info then
		return
	end

	-- STORE-007: the board is the sum of every writer's published totals (each banker's credits,
	-- each officer's adjustments), not this client's own `alt.ledger` tables -- so a member sees
	-- the same numbers the bankers do. Points, at the officer-set rate; the old vendor-valued
	-- scores are each banker's opening balance.
	local D = TOGBankClassic_Donations
	D:MigrateOwnLedger()
	local scoreboard = D:Scoreboard()

	local header = TOGBankClassic_UI:Create("Label")
	header:SetText("")
	self.Content:AddChild(header)

	header = TOGBankClassic_UI:Create("Label")
	header:SetText("Name")
	self.Content:AddChild(header)

	header = TOGBankClassic_UI:Create("Label")
	header:SetText("Points")
	self.Content:AddChild(header)

	-- DONATION-VALUE-001 (the operator: "flesh out the donation points = to gold value"): what
	-- the points stand for, in gold -- the value the bank characters' price sources put on each
	-- member's gifts when they arrived, summed. Blank where a balance has no value behind it (an
	-- officer's adjustment, a score carried from before the points existed).
	header = TOGBankClassic_UI:Create("Label")
	header:SetText("Value")
	self.Content:AddChild(header)

	local count = 0
	-- ipairs: the board is SORTED (highest first) and `pairs` on an array is order-undefined in
	-- principle -- the rank numbers beside the names are what the sort was for (Peer Review f5e52bcf F8).
	for _, v in ipairs(scoreboard) do
		count = count + 1

		if count <= 25 then
			local rank = TOGBankClassic_UI:Create("Label")
			local formatString = " %d)"
			if count < 10 then
				formatString = "  " .. formatString
			end
			rank:SetText(string.format(formatString, count))
			self.Content:AddChild(rank)

			local color = "ff888888"
			local class = TOGBankClassic_Guild:GetPlayerInfo(v.player)
			if class then
				_, _, _, color = GetClassColor(class)
			end
			local contributor = TOGBankClassic_UI:Create("Label")
			contributor:SetText(string.format("|c%s%s|r", color, v.player))
			self.Content:AddChild(contributor)

			-- The points as they are, to two decimals. This used to be math.ceil, which showed a
			-- member with 0.05 points as 1 -- and a board is exactly where a rounded-up number is
			-- read as a fact.
			local score = TOGBankClassic_UI:Create("Label")
			local p = v.points
			score:SetText(string.format("|c%s%s|r", color, p == math.floor(p) and string.format("%d", p) or string.format("%.2f", p)))
			self.Content:AddChild(score)

			local value = TOGBankClassic_UI:Create("Label")
			value:SetText((v.copper or 0) > 0 and string.format("|c%s%s|r", color, D:FormatGold(v.copper)) or "")
			self.Content:AddChild(value)
		end
	end

	-- Your own balance beside the count, so a donor has a receipt without finding their row.
	local me = TOGBankClassic_Guild:GetPlayer() or ""
	local mine, mineValue = D:PointsOf(me), D:ValueOf(me)
	self.Window:SetStatusText(string.format("%d Total -- you have %s%s (%s per gold donated)",
		count, D:FormatPoints(mine), mineValue > 0 and (" for " .. D:FormatGold(mineValue) .. " given") or "",
		D:FormatPoints(D:Rate())))
end
