TOGBankClassic_UI_Search = {}

local FILTER_ANY = "any"
local RESULTS_PER_PAGE = 50
local SUBFILTER_LIST  = {
	any     = "Any",
	type    = "Type",
	quality = "Quality",
}
local SUBFILTER_ORDER = { "any", "type", "quality" }

-- Parse item rarity from the colour prefix embedded in every item link.
-- e.g. |cFF0070DD|Hitem:...|h[Sword]|h|r -> Rare (3)
-- No API call needed -- the colour is part of the link string stored in SV.
local LINK_COLOR_RARITY = {
	["9D9D9D"] = 0,  -- Poor
	["FFFFFF"] = 1,  -- Common
	["1EFF00"] = 2,  -- Uncommon
	["0070DD"] = 3,  -- Rare
	["A335EE"] = 4,  -- Epic
	["FF8000"] = 5,  -- Legendary
}
local function RarityFromLink(link)
	if not link then return nil end
	-- WoW item links use lowercase |cff + 6 hex colour digits (e.g. |cff0070dd)
	-- |c%x%x matches the opaque alpha byte (always ff) in either case
	local hex = link:match("|c%x%x(%x%x%x%x%x%x)")
	return hex and LINK_COLOR_RARITY[hex:upper()] or nil
end

-- Second cascade dropdown lists; keys are tostring(classId) / tostring(rarityId)
local TYPE_LIST = {
	any   = "Any Type",
	["0"]  = "Consumable",
	["1"]  = "Container",
	["2"]  = "Weapon",
	["4"]  = "Armor",
	["5"]  = "Reagent",
	["6"]  = "Projectile",
	["7"]  = "Trade Goods",
	["9"]  = "Recipe",
	["11"] = "Quiver",
	["12"] = "Quest",
	["13"] = "Key",
	["15"] = "Miscellaneous",
}
local TYPE_ORDER  = { "any", "0", "1", "2", "4", "5", "6", "7", "9", "11", "12", "13", "15" }
local QUALITY_LIST = {
	any   = "Any Quality",
	["0"] = "Poor",
	["1"] = "Common",
	["2"] = "Uncommon",
	["3"] = "Rare",
	["4"] = "Epic",
	["5"] = "Legendary",
}
local QUALITY_ORDER = { "any", "0", "1", "2", "3", "4", "5" }

-- Third cascade: subclass lists keyed by string class ID.
-- IDs match GetItemInfo() return values for Classic Era (Vanilla).
local SUBCLASS_LISTS = {
	["0"] = {  -- Consumable
		list  = { any="Any", ["0"]="Consumable", ["1"]="Potion", ["2"]="Elixir", ["3"]="Flask", ["4"]="Scroll", ["5"]="Food & Drink", ["6"]="Item Enhancement", ["7"]="Bandage", ["8"]="Other" },
		order = { "any","0","1","2","3","4","5","6","7","8" },
	},
	["1"] = {  -- Container
		list  = { any="Any", ["0"]="Bag", ["1"]="Soul Bag", ["2"]="Herb Bag", ["3"]="Enchanting Bag", ["4"]="Engineering Bag", ["5"]="Gem Bag", ["6"]="Mining Bag", ["7"]="Leatherworking Bag" },
		order = { "any","0","1","2","3","4","5","6","7" },
	},
	["2"] = {  -- Weapon
		list  = { any="Any", ["0"]="Axe (1H)", ["1"]="Axe (2H)", ["2"]="Bow", ["3"]="Gun", ["4"]="Mace (1H)", ["5"]="Mace (2H)", ["6"]="Polearm", ["7"]="Sword (1H)", ["8"]="Sword (2H)", ["10"]="Staff", ["13"]="Fist Weapon", ["14"]="Misc", ["15"]="Dagger", ["16"]="Thrown", ["18"]="Crossbow", ["19"]="Wand", ["20"]="Fishing Pole" },
		order = { "any","0","1","2","3","4","5","6","7","8","10","13","14","15","16","18","19","20" },
	},
	["4"] = {  -- Armor
		list  = { any="Any", ["0"]="Miscellaneous", ["1"]="Cloth", ["2"]="Leather", ["3"]="Mail", ["4"]="Plate", ["6"]="Shield", ["7"]="Libram", ["8"]="Idol", ["9"]="Totem" },
		order = { "any","0","1","2","3","4","6","7","8","9" },
	},
	["5"] = {  -- Reagent
		list  = { any="Any", ["0"]="Reagent" },
		order = { "any","0" },
	},
	["6"] = {  -- Projectile
		list  = { any="Any", ["2"]="Arrow", ["3"]="Bullet" },
		order = { "any","2","3" },
	},
	["7"] = {  -- Trade Goods
		list  = { any="Any", ["0"]="Trade Goods", ["1"]="Parts", ["2"]="Explosives", ["3"]="Devices" },
		order = { "any","0","1","2","3" },
	},
	["9"] = {  -- Recipe
		list  = { any="Any", ["0"]="Book", ["1"]="Leatherworking", ["2"]="Tailoring", ["3"]="Engineering", ["4"]="Blacksmithing", ["5"]="Cooking", ["6"]="Alchemy", ["7"]="First Aid", ["8"]="Enchanting", ["9"]="Fishing" },
		order = { "any","0","1","2","3","4","5","6","7","8","9" },
	},
	["11"] = {  -- Quiver
		list  = { any="Any", ["2"]="Quiver", ["3"]="Ammo Pouch" },
		order = { "any","2","3" },
	},
	["12"] = {  -- Quest
		list  = { any="Any", ["0"]="Quest" },
		order = { "any","0" },
	},
	["13"] = {  -- Key
		list  = { any="Any", ["0"]="Key", ["1"]="Lockpick" },
		order = { "any","0","1" },
	},
	["15"] = {  -- Miscellaneous
		list  = { any="Any", ["0"]="Junk", ["1"]="Reagent", ["2"]="Companion Pet", ["3"]="Holiday", ["4"]="Other", ["5"]="Mount" },
		order = { "any","0","1","2","3","4","5" },
	},
}

-- Sort modes for search results
local SORT_LIST = {
	alpha       = "A -> Z",
	alpha_desc  = "Z -> A",
	level_asc   = "Level (Low to High)",
	level       = "Level (High to Low)",
	rarity      = "Rarity (High to Low)",
	rarity_asc  = "Rarity (Low to High)",
}
local SORT_ORDER = { "alpha", "alpha_desc", "level_asc", "level", "rarity", "rarity_asc" }

function TOGBankClassic_UI_Search:Init()
	-- Frame creation deferred to first Open() call (PERF-015)
end

local function OnClose(_)
	TOGBankClassic_UI_Search.isOpen = false
	TOGBankClassic_UI_Search.Window:Hide()
	if TOGBankClassic_UI_Search.RequestDialog then
		TOGBankClassic_UI_Search.RequestDialog:Hide()
	end
end

-- Build (once) and show the request dialog for clicking search results
function TOGBankClassic_UI_Search:EnsureRequestDialog()
	if self.RequestDialog then
		return
	end

	local dialog = TOGBankClassic_UI:Create("Frame")
	dialog:Hide()
	dialog:SetTitle("Item Request")
	dialog:SetLayout("List")
	dialog:SetWidth(340)
	dialog:SetHeight(200)
	dialog:EnableResize(false)
	dialog:SetCallback("OnClose", function(widget)
		widget:Hide()
	end)
	dialog.frame:SetAlpha(1)
	TOGBankClassic_UI:ApplyThinBorder(dialog)
	if dialog.frame and dialog.frame.GetChildren then
		for _, child in ipairs({ dialog.frame:GetChildren() }) do
			-- Hide the built-in close button so we only show Send/Cancel actions
			if child.GetText and (child:GetText() == CLOSE or child:GetText() == "Close") then
				child:Hide()
				child:EnableMouse(false)
				break
			end
		end
	end

	local prompt = TOGBankClassic_UI:Create("Label")
	prompt:SetFullWidth(true)
	prompt:SetText("")
	prompt:SetJustifyH("LEFT")
	if prompt.label and prompt.label.SetWordWrap then
		prompt.label:SetWordWrap(true)
	end
	dialog:AddChild(prompt)
	dialog.Prompt = prompt

	local quantityInput = TOGBankClassic_UI:Create("Slider")
	quantityInput:SetLabel("Quantity")
	quantityInput:SetSliderValues(1, 1, 1)
	quantityInput:SetValue(1)
	quantityInput:SetFullWidth(true)
	if quantityInput.editbox and quantityInput.editbox.HookScript then
		quantityInput.editbox:HookScript("OnEnterPressed", function()
			self:SubmitRequest()
		end)
	end
	dialog:AddChild(quantityInput)
	dialog.QuantityInput = quantityInput

	local availableLabel = TOGBankClassic_UI:Create("Label")
	availableLabel:SetFullWidth(true)
	availableLabel:SetJustifyH("LEFT")
	availableLabel:SetText("")
	dialog:AddChild(availableLabel)
	dialog.AvailableLabel = availableLabel

	local buttons = TOGBankClassic_UI:Create("SimpleGroup")
	buttons:SetLayout("Table")
	buttons:SetUserData("table", {
		columns = {
			{ width = 0.5, align = "start" },
			{ width = 0.5, align = "end" },
		},
	})
	buttons:SetFullWidth(true)
	dialog:AddChild(buttons)

	local send = TOGBankClassic_UI:Create("Button")
	send:SetText("Send Request")
	send:SetWidth(140)
	send:SetCallback("OnClick", function()
		self:SubmitRequest()
	end)
	buttons:AddChild(send)

	local cancel = TOGBankClassic_UI:Create("Button")
	cancel:SetText("Cancel")
	cancel:SetWidth(120)
	cancel:SetCallback("OnClick", function()
		dialog:Hide()
	end)
	buttons:AddChild(cancel)

	self.RequestDialog = dialog
end

function TOGBankClassic_UI_Search:ShowRequestDialog(itemEntry, bankAlt)
	if not itemEntry or not itemEntry.Info or not bankAlt then
		return
	end

	self:EnsureRequestDialog()

	local itemName = itemEntry.Info.name or (itemEntry.Link and itemEntry.Link:match("%[(.-)%]")) or "Unknown item"
	self.requestContext = {
		item = itemEntry,
		bank = bankAlt,
		itemName = itemName,
		itemID = itemEntry.ID,  -- numeric ID; enables same-name variant disambiguation on fulfillment
		available = tonumber(itemEntry.Count) or 0,
	}

	local itemLabel = itemEntry.Link or itemName
	local prompt = string.format("Request how many %s from %s?", itemLabel, bankAlt)
	self.RequestDialog.Prompt:SetText(prompt)
	local available = self.requestContext.available

	-- Apply configured percentage limit to available quantity
	local maxRequestPercent = 100
	if TOGBankClassic_Options and TOGBankClassic_Options.GetMaxRequestPercent then
		maxRequestPercent = TOGBankClassic_Options:GetMaxRequestPercent()
	end
	local maxAllowed = math.floor(available * maxRequestPercent / 100)
	-- Always allow at least 1 item if any are available (handles single items like gear)
	if maxAllowed == 0 and available > 0 then
		maxAllowed = 1
	end

	local minQuantity = maxAllowed > 0 and 1 or 0
	local maxQuantity = maxAllowed > 0 and maxAllowed or 0
	if maxQuantity < minQuantity then
		maxQuantity = minQuantity
	end
	self.RequestDialog.QuantityInput:SetSliderValues(minQuantity, maxQuantity, 1)
	self.RequestDialog.QuantityInput:SetValue(minQuantity > 0 and 1 or 0)
	self.RequestDialog.QuantityInput:SetDisabled(maxQuantity == 0)
	if self.RequestDialog.AvailableLabel then
		if maxRequestPercent < 100 then
			self.RequestDialog.AvailableLabel:SetText(string.format("Available: %d (max %d%% = %d)", available, maxRequestPercent, maxAllowed))
		elseif available > 0 then
			self.RequestDialog.AvailableLabel:SetText(string.format("Available: %d", available))
		else
			self.RequestDialog.AvailableLabel:SetText("Available: none right now")
		end
	end
	self.RequestDialog:SetStatusText("")
	if self.Window and self.Window.frame and self.RequestDialog.frame then
		self.RequestDialog.frame:ClearAllPoints()
		self.RequestDialog.frame:SetPoint("TOPRIGHT", self.Window.frame, "TOPLEFT", -10, 0)
	end
	self.RequestDialog:Show()
	-- Ensure dialog stays within screen bounds
	TOGBankClassic_UI:ClampFrameToScreen(self.RequestDialog)
	self.RequestDialog:DoLayout()
	if self.RequestDialog.QuantityInput.editbox and self.RequestDialog.QuantityInput.editbox.SetFocus then
		self.RequestDialog.QuantityInput.editbox:SetFocus()
		self.RequestDialog.QuantityInput.editbox:HighlightText()
	end
end

function TOGBankClassic_UI_Search:SubmitRequest()
	if not self.requestContext or not self.RequestDialog then
		return
	end

	local quantityInput = self.RequestDialog.QuantityInput
	if quantityInput and quantityInput.editbox and quantityInput.editbox.GetText then
		local text = quantityInput.editbox:GetText()
		if text and text ~= "" then
			local typed = tonumber(text) or tonumber(text:match("%d+"))
			if typed then
				local minValue = tonumber(quantityInput.min)
				local maxValue = tonumber(quantityInput.max)
				if minValue and typed < minValue then
					typed = minValue
				end
				if maxValue and typed > maxValue then
					typed = maxValue
				end
				local step = tonumber(quantityInput.step)
				if step and step > 0 and minValue then
					typed = math.floor((typed - minValue) / step + 0.5) * step + minValue
				end
				quantityInput:SetValue(typed)
			end
		end
	end

	local quantity = tonumber(quantityInput and quantityInput:GetValue())
	local available = tonumber(self.requestContext.available) or 0

	-- Apply configured percentage limit to available quantity
	local maxRequestPercent = 100
	if TOGBankClassic_Options and TOGBankClassic_Options.GetMaxRequestPercent then
		maxRequestPercent = TOGBankClassic_Options:GetMaxRequestPercent()
	end
	local maxAllowed = math.floor(available * maxRequestPercent / 100)
	-- Always allow at least 1 item if any are available (handles single items like gear)
	if maxAllowed == 0 and available > 0 then
		maxAllowed = 1
	end

	if not quantity or quantity <= 0 then
		self.RequestDialog:SetStatusText("Enter a quantity greater than 0.")
		return
	end
	if quantity > maxAllowed then
		if maxAllowed <= 0 then
			if maxRequestPercent < 100 then
				self.RequestDialog:SetStatusText(string.format("Cannot request - max allowed is %d%% of %d = 0 items.", maxRequestPercent, available))
			else
				self.RequestDialog:SetStatusText("Cannot request - none available right now.")
			end
			return
		else
			if maxRequestPercent < 100 then
				self.RequestDialog:SetStatusText(string.format("Reduced to max allowed: %d items (%d%% of %d available)", maxAllowed, maxRequestPercent, available))
			else
				self.RequestDialog:SetStatusText(string.format("Reduced to available: %d", maxAllowed))
			end
			quantity = maxAllowed
			-- Don't return - allow the clamped request to proceed
		end
	end

	local requester = TOGBankClassic_Guild:GetNormalizedPlayer()
	if not requester then
		local name, realm = UnitName("player"), GetNormalizedRealmName()
		if name then
			requester = realm and (name .. "-" .. realm) or name
			requester = TOGBankClassic_Guild:NormalizeName(requester)
		end
	end

	local bank = TOGBankClassic_Guild:NormalizeName(self.requestContext.bank)

	local request = {
		date = GetServerTime(),
		requester = requester or "Unknown",
		bank = bank or self.requestContext.bank,
		item = self.requestContext.itemName,
		itemID = self.requestContext.itemID,  -- nil for legacy; set for same-name variant disambiguation
		quantity = quantity,
		fulfilled = 0,
		notes = "",
	}

	if not TOGBankClassic_Guild:AddRequest(request) then
		self.RequestDialog:SetStatusText("Unable to send request.")
		return
	end

	self.RequestDialog:Hide()
	self.requestContext = nil

	TOGBankClassic_Output:Response("Requested %d x %s from %s", quantity, request.item, request.bank)
end

function TOGBankClassic_UI_Search:Toggle()
	if self.isOpen then
		self:Close()
	else
		self:Open()
	end
end

function TOGBankClassic_UI_Search:Open()
	if self.isOpen then
		return
	end
	self.isOpen = true

	if not self.Window then
		self:DrawWindow()
	end

	-- SEARCH-006 FIX: Rebuild search data when guild roster version changes
	-- Track roster version to detect when new data arrives (after /wipe, sync, etc.)
	local currentVersion = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.roster and TOGBankClassic_Guild.Info.roster.version or 0
	local needsRebuild = not self.searchDataBuilt or (self.lastRosterVersion ~= currentVersion)

	if needsRebuild then
		TOGBankClassic_Output:Debug("UI", "FILTER", "Rebuilding search data (version changed: %s -> %s)",
			tostring(self.lastRosterVersion or "nil"), tostring(currentVersion))
		self:BuildSearchData()
		self.searchDataBuilt = true
		self.lastRosterVersion = currentVersion
		self.currentPage = 1  -- reset pagination on data rebuild
	end

	self.Window:Show()
	if TOGBankClassic_UI_Inventory.isOpen and TOGBankClassic_UI_Inventory.Window then
		self.Window:ClearAllPoints()
		self.Window:SetPoint("TOPRIGHT", TOGBankClassic_UI_Inventory.Window.frame, "TOPLEFT", 0, 0)
	end

	-- Ensure window stays within screen bounds
	TOGBankClassic_UI:ClampFrameToScreen(self.Window)

	self:DrawContent()

	self.searchField:SetFocus()

	if _G["TOGBankClassic"] then
		_G["TOGBankClassic"]:Show()
	else
		TOGBankClassic_UI:Controller()
	end
end

function TOGBankClassic_UI_Search:Close()
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

function TOGBankClassic_UI_Search:DrawWindow()
	local searchWindow = TOGBankClassic_UI:Create("Frame")
	searchWindow:Hide()
	searchWindow:SetCallback("OnClose", OnClose)
	searchWindow:SetTitle("Search")
	searchWindow:SetLayout("Flow")
	searchWindow:EnableResize(true)
	TOGBankClassic_UI:ApplyThinBorder(searchWindow)
	-- Persist window size across reloads (position is always snapped to the main UI in Open())
	if TOGBankClassic_Options and TOGBankClassic_Options.db then
		local positions = TOGBankClassic_Options.db.char.framePositions
		positions.search = positions.search or { width = 250, height = 400 }
		searchWindow:SetStatusTable(positions.search)
	end
	if searchWindow.frame.SetResizeBounds then
		searchWindow.frame:SetResizeBounds(200, 200)
	end

	self.Window = searchWindow

	local searchInput = TOGBankClassic_UI:Create("EditBox")
	searchInput:SetMaxLetters(50)
	searchInput:SetLabel("Item Name")
	searchInput.label:ClearAllPoints()
	searchInput.label:SetPoint("TOPLEFT", searchInput.frame, "TOPLEFT", 3, -2)
	searchInput.label:SetPoint("TOPRIGHT", searchInput.frame, "TOPRIGHT", 0, -2)
	-- Invisible hit frame over the "Item Name" label (FontString has no mouse events)
	local itemNameLabelHit = CreateFrame("Frame", nil, searchInput.frame)
	itemNameLabelHit:SetPoint("TOPLEFT", searchInput.frame, "TOPLEFT", 3, -2)
	itemNameLabelHit:SetPoint("TOPRIGHT", searchInput.frame, "TOPRIGHT", 0, -2)
	itemNameLabelHit:SetHeight(18)
	itemNameLabelHit:EnableMouse(true)
	itemNameLabelHit:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Search Guild Bank")
		GameTooltip:AddLine("Type at least 3 characters to find items across all banker alts.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("You can also drag an item from your bags into this box to search by item.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Click a result to open the request popup.", 0.9, 0.9, 0.9, true)
		GameTooltip:Show()
	end)
	itemNameLabelHit:SetScript("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
	end)
	searchInput:SetCallback("OnTextChanged", function(input)
		self.SearchText = input:GetText()
		TOGBankClassic_Output:Debug("UI", "SEARCH", "OnTextChanged: text='%s' t=%.3f", self.SearchText or "", GetTime())
		self.currentPage = 1  -- reset to first page on search text change
		self:DrawContent()
	end)
	searchInput:SetCallback("OnEnterPressed", function(input)
		self.SearchText = input:GetText()
		self:DrawContent()
		self.searchField:ClearFocus()
	end)
	searchInput:SetFullWidth(true)
	searchInput.editbox:SetScript("OnReceiveDrag", function(input)
		local type, _, info = GetCursorInfo()
		if type == "item" then
			self.SearchText = info
			self:DrawContent()
			ClearCursor()
			self.searchField:ClearFocus()
		end
	end)

	self.searchField = searchInput

	searchWindow:AddChild(searchInput)

	-- Sub-filter: three cascading Requests-style dropdowns
	-- subValueDropdown and subSubValueDropdown forward-declared so callbacks can reference them
	local subValueDropdown, subSubValueDropdown

	local function resetSubclass()
		self.SubFilterSubValue = FILTER_ANY
		subSubValueDropdown:SetList({ [FILTER_ANY] = "---" }, { FILTER_ANY })
		subSubValueDropdown:SetValue(FILTER_ANY)
		subSubValueDropdown:SetDisabled(true)
	end

	local subFilterDropdown = TOGBankClassic_UI:Create("Dropdown")
	subFilterDropdown:SetLabel("Filter")
	subFilterDropdown.label:ClearAllPoints()
	subFilterDropdown.label:SetPoint("TOPLEFT", subFilterDropdown.frame, "TOPLEFT", 3, 0)
	subFilterDropdown.label:SetPoint("TOPRIGHT", subFilterDropdown.frame, "TOPRIGHT", 0, 0)
	-- Hit frame for tooltip: only spans left portion, stops before the checkbox
	local subFilterLabelHit = CreateFrame("Frame", nil, subFilterDropdown.frame)
	subFilterLabelHit:SetPoint("TOPLEFT", subFilterDropdown.frame, "TOPLEFT", 3, 0)
	subFilterLabelHit:SetPoint("TOPRIGHT", subFilterDropdown.frame, "TOPRIGHT", -165, 0)
	subFilterLabelHit:SetHeight(18)
	subFilterLabelHit:EnableMouse(true)
	subFilterLabelHit:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Secondary Filter")
		GameTooltip:AddLine("Narrows results alongside the name search.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cFFFFFFFFType|r: pick a type then a subtype (e.g. Weapon > Sword).", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine("|cFFFFFFFFQuality|r: pick a quality tier.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine("|cFFFFFFFFUsable by my level|r: tick the checkbox to hide items your character cannot yet equip.", 0.9, 0.9, 0.9, true)
		GameTooltip:Show()
	end)
	subFilterLabelHit:SetScript("OnLeave", function()
		TOGBankClassic_UI:HideTooltip()
	end)
	-- Native CheckButton: sits at far right of the Filter label row, text to its left
	local usableCBFrame = CreateFrame("CheckButton", nil, subFilterDropdown.frame)
	usableCBFrame:SetSize(16, 16)
	usableCBFrame:SetPoint("TOPRIGHT", subFilterDropdown.frame, "TOPRIGHT", 0, -1)
	usableCBFrame:SetNormalTexture(130755)   -- UI-CheckBox-Up
	usableCBFrame:SetCheckedTexture(130751)  -- UI-CheckBox-Check
	usableCBFrame:SetHighlightTexture(130753, "ADD")
	local usableCBText = usableCBFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	usableCBText:SetText("Usable by my level")
	usableCBText:SetJustifyH("RIGHT")
	usableCBText:SetPoint("RIGHT", usableCBFrame, "LEFT", -3, 0)
	usableCBFrame:SetScript("OnClick", function(btn)
		self.FilterUsableLevel = btn:GetChecked()
		self.currentPage = 1  -- reset to first page on filter change
		self:DrawContent()
	end)
	usableCBFrame:SetFrameLevel(subFilterDropdown.frame:GetFrameLevel() + 10)
	self.usableCBFrame = usableCBFrame
	-- Enable/disable the checkbox; always unchecks+clears state when disabling
	local function updateUsableCB(enabled)
		if enabled then
			usableCBFrame:Enable()
			usableCBText:SetTextColor(1, 1, 1)
		else
			usableCBFrame:SetChecked(false)
			usableCBFrame:Disable()
			usableCBText:SetTextColor(0.5, 0.5, 0.5)
			self.FilterUsableLevel = false
		end
	end
	updateUsableCB(false)  -- disabled until a specific filter value is chosen
	usableCBFrame:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Usable by my level")
		GameTooltip:AddLine("Hides items whose required level exceeds your current level.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine("Requires a specific Type or Quality to be selected first —", 1, 0.5, 0.5, true)
		GameTooltip:AddLine("scanning all items without a filter causes severe lag.", 1, 0.5, 0.5, true)
		GameTooltip:Show()
	end)
	usableCBFrame:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	subFilterDropdown:SetList(SUBFILTER_LIST, SUBFILTER_ORDER)
	subFilterDropdown:SetValue(FILTER_ANY)
	subFilterDropdown:SetFullWidth(true)
	subFilterDropdown:SetCallback("OnValueChanged", function(widget, _, value)
		self.SubFilterMode  = value
		self.SubFilterValue = FILTER_ANY
		resetSubclass()
		updateUsableCB(false)  -- second dropdown reset, so disable checkbox again
		if value == "type" then
			subValueDropdown:SetList(TYPE_LIST, TYPE_ORDER)
			subValueDropdown:SetValue(FILTER_ANY)
			subValueDropdown:SetDisabled(false)
		elseif value == "quality" then
			subValueDropdown:SetList(QUALITY_LIST, QUALITY_ORDER)
			subValueDropdown:SetValue(FILTER_ANY)
			subValueDropdown:SetDisabled(false)
		else
			subValueDropdown:SetList({ [FILTER_ANY] = "---" }, { FILTER_ANY })
			subValueDropdown:SetValue(FILTER_ANY)
			subValueDropdown:SetDisabled(true)
		end
		self.currentPage = 1  -- reset to first page on filter change
		self:DrawContent()
	end)
	searchWindow:AddChild(subFilterDropdown)
	self.subFilterDropdown = subFilterDropdown

	subValueDropdown = TOGBankClassic_UI:Create("Dropdown")
	subValueDropdown:SetLabel("")
	subValueDropdown.label:ClearAllPoints()
	subValueDropdown.label:SetPoint("TOPLEFT", subValueDropdown.frame, "TOPLEFT", 3, 0)
	subValueDropdown.label:SetPoint("TOPRIGHT", subValueDropdown.frame, "TOPRIGHT", 0, 0)
	subValueDropdown:SetList({ [FILTER_ANY] = "---" }, { FILTER_ANY })
	subValueDropdown:SetValue(FILTER_ANY)
	subValueDropdown:SetDisabled(true)
	subValueDropdown:SetFullWidth(true)
	subValueDropdown:SetCallback("OnValueChanged", function(widget, _, value)
		self.SubFilterValue = value
		updateUsableCB(value ~= FILTER_ANY)  -- enable checkbox once a specific value is picked
		resetSubclass()
		-- Populate 3rd dropdown if this type has subclasses
		if self.SubFilterMode == "type" and SUBCLASS_LISTS[value] then
			local sc = SUBCLASS_LISTS[value]
			subSubValueDropdown:SetList(sc.list, sc.order)
			subSubValueDropdown:SetValue(FILTER_ANY)
			subSubValueDropdown:SetDisabled(false)
		else
			subSubValueDropdown:SetList({ [FILTER_ANY] = "---" }, { FILTER_ANY })
			subSubValueDropdown:SetValue(FILTER_ANY)
			subSubValueDropdown:SetDisabled(true)
		end
		self.currentPage = 1  -- reset to first page on filter change
		self:DrawContent()
	end)
	searchWindow:AddChild(subValueDropdown)
	self.subValueDropdown = subValueDropdown

	subSubValueDropdown = TOGBankClassic_UI:Create("Dropdown")
	subSubValueDropdown:SetLabel("")
	subSubValueDropdown.label:ClearAllPoints()
	subSubValueDropdown.label:SetPoint("TOPLEFT", subSubValueDropdown.frame, "TOPLEFT", 3, 0)
	subSubValueDropdown.label:SetPoint("TOPRIGHT", subSubValueDropdown.frame, "TOPRIGHT", 0, 0)
	subSubValueDropdown:SetList({ [FILTER_ANY] = "---" }, { FILTER_ANY })
	subSubValueDropdown:SetValue(FILTER_ANY)
	subSubValueDropdown:SetDisabled(true)
	subSubValueDropdown:SetFullWidth(true)
	subSubValueDropdown:SetCallback("OnValueChanged", function(widget, _, value)
		self.SubFilterSubValue = value
		self.currentPage = 1  -- reset to first page on filter change
		self:DrawContent()
	end)
	searchWindow:AddChild(subSubValueDropdown)
	self.subSubValueDropdown = subSubValueDropdown

	-- Sort dropdown
	local sortDropdown = TOGBankClassic_UI:Create("Dropdown")
	sortDropdown:SetLabel("Sort")
	sortDropdown.label:ClearAllPoints()
	sortDropdown.label:SetPoint("TOPLEFT", sortDropdown.frame, "TOPLEFT", 3, 0)
	sortDropdown.label:SetPoint("TOPRIGHT", sortDropdown.frame, "TOPRIGHT", 0, 0)
	sortDropdown:SetList(SORT_LIST, SORT_ORDER)
	sortDropdown:SetValue("alpha")  -- Default to A-Z
	sortDropdown:SetFullWidth(true)
	sortDropdown:SetCallback("OnValueChanged", function(widget, _, value)
		self.SortMode = value
		self:DrawContent()
	end)
	sortDropdown:SetCallback("OnEnter", function()
		GameTooltip:SetOwner(sortDropdown.frame, "ANCHOR_BOTTOM")
		GameTooltip:ClearLines()
		GameTooltip:AddLine("Sort Order")
		GameTooltip:AddLine("Choose how to sort search results.", 0.9, 0.9, 0.9, true)
		GameTooltip:Show()
	end)
	sortDropdown:SetCallback("OnLeave", function()
		GameTooltip:Hide()
	end)
	searchWindow:AddChild(sortDropdown)
	self.sortDropdown = sortDropdown
	self.SortMode = "alpha"  -- Initialize default sort mode

	-- Pagination controls
	local paginationGroup = TOGBankClassic_UI:Create("SimpleGroup")
	paginationGroup:SetFullWidth(true)
	paginationGroup:SetLayout("Flow")
	paginationGroup:SetHeight(30)

	local prevButton = TOGBankClassic_UI:Create("Button")
	prevButton:SetText("< Previous")
	prevButton:SetWidth(100)
	prevButton:SetDisabled(true)
	prevButton:SetCallback("OnClick", function()
		if self.currentPage > 1 then
			self.currentPage = self.currentPage - 1
			self:DrawContent()
		end
	end)
	paginationGroup:AddChild(prevButton)
	self.prevButton = prevButton

	local nextButton = TOGBankClassic_UI:Create("Button")
	nextButton:SetText("Next >")
	nextButton:SetWidth(100)
	nextButton:SetDisabled(true)
	nextButton:SetCallback("OnClick", function()
		local totalPages = math.ceil(self.totalMatches / RESULTS_PER_PAGE)
		if self.currentPage < totalPages then
			self.currentPage = self.currentPage + 1
			self:DrawContent()
		end
	end)
	paginationGroup:AddChild(nextButton)
	self.nextButton = nextButton

	searchWindow:AddChild(paginationGroup)

	local scrollGroup = TOGBankClassic_UI:Create("SimpleGroup")
	scrollGroup:SetLayout("Fill")
	scrollGroup:SetFullWidth(true)
	scrollGroup:SetFullHeight(true)
	searchWindow:AddChild(scrollGroup)

	-- Extend scrollGroup right edge to window edge (Frame content has 17px right padding)
	scrollGroup.content:ClearAllPoints()
	scrollGroup.content:SetPoint("TOPLEFT", scrollGroup.frame, "TOPLEFT", 0, 0)
	scrollGroup.content:SetPoint("BOTTOMRIGHT", scrollGroup.frame, "BOTTOMRIGHT", 17, 0)

	local resultGroup = TOGBankClassic_UI:Create("ScrollFrame")
	resultGroup:SetLayout("Table")
	resultGroup:SetUserData("table", {
		columns = {
			{
				width = 35,
				align = "middle",
			},
			{
				align = "start",
			},
		},
		spaceH = 30,
	})

	resultGroup.scrollframe:SetPoint("TOPLEFT")
	resultGroup.scrollframe:SetPoint("BOTTOMRIGHT")

	-- Apply thin scrollbar style to match dropdown scrollbars
	if resultGroup.scrollbar then
		resultGroup.scrollbar:ClearAllPoints()
		resultGroup.scrollbar:SetPoint("TOPRIGHT", resultGroup.scrollframe, "TOPRIGHT", 0, -20)
		resultGroup.scrollbar:SetPoint("BOTTOMRIGHT", resultGroup.scrollframe, "BOTTOMRIGHT", 0, 20)
		resultGroup.scrollbar:SetWidth(8)
		resultGroup.scrollbar:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Vertical")
	end
	scrollGroup:AddChild(resultGroup)

	self.Results = resultGroup
end

function TOGBankClassic_UI_Search:BuildSearchData()
	self.SearchData = { Corpus = {}, Lookup = {} }

	local guildInfo = TOGBankClassic_Guild.Info
	local roster_alts = TOGBankClassic_Guild:GetRosterAlts()
	if not guildInfo or not roster_alts then return end

	-- First pass: aggregate all items from all alts
	local items = {}
	for _, player in pairs(roster_alts) do
		local norm = TOGBankClassic_Guild:NormalizeName(player)
		local alt = guildInfo.alts[norm]
		if alt and type(alt) == "table" then
			-- Use alt.items if available (aggregated format)
			if alt.items and next(alt.items) ~= nil then
				items = TOGBankClassic_Item:Aggregate(items, alt.items)
			else
				-- Fallback: aggregate from sources
				if alt.bank then items = TOGBankClassic_Item:Aggregate(items, alt.bank.items) end
				if alt.bags  then items = TOGBankClassic_Item:Aggregate(items, alt.bags.items)  end
			end
		end
	end

	-- Use GetItems to enrich all items with Info (handles caching properly)
	TOGBankClassic_Item:GetItems(items, function(enrichedList)
		-- Build Corpus: unique item names
		local itemNames = {}
		local corpusSeen = {}
		for _, v in pairs(enrichedList) do
			if v and v.ID and v.Info and v.Info.name then
				if not itemNames[v.ID] then
					itemNames[v.ID] = v.Info.name
				end
				if not corpusSeen[v.Info.name] then
					corpusSeen[v.Info.name] = true
					table.insert(self.SearchData.Corpus, v.Info.name)
				end
			end
		end

		-- Build Lookup: name -> [{alt, item}]
		for _, player in pairs(roster_alts) do
			local norm = TOGBankClassic_Guild:NormalizeName(player)
			local alt = guildInfo.alts[norm]
			if alt and type(alt) == "table" then
				local altItems = {}
				if alt.items and next(alt.items) ~= nil then
					for _, item in pairs(alt.items) do
						table.insert(altItems, item)
					end
				else
					if alt.bank then altItems = TOGBankClassic_Item:Aggregate(altItems, alt.bank.items) end
					if alt.bags  then altItems = TOGBankClassic_Item:Aggregate(altItems, alt.bags.items)  end
				end

				for _, itemEntry in pairs(altItems) do
					local name = itemNames[itemEntry.ID]
					if name then
						if not self.SearchData.Lookup[name] then
							self.SearchData.Lookup[name] = {}
						end
						local found = false
						local existingEntry = nil
						for _, existing in pairs(self.SearchData.Lookup[name]) do
							if existing.alt == player and existing.item.ID == itemEntry.ID then
								found = true
								existingEntry = existing
								break
							end
						end
						if found and existingEntry then
							-- Same alt has this item already - sum the counts
							existingEntry.item.Count = (existingEntry.item.Count or 1) + (itemEntry.Count or 1)
						else
							-- New entry for this alt/item combo
							local info = TOGBankClassic_Item:GetInfo(itemEntry.ID, itemEntry.Link)
							table.insert(self.SearchData.Lookup[name], {
								alt  = player,
								item = {
									ID    = itemEntry.ID,
									Count = itemEntry.Count,
									Link  = itemEntry.Link,
									Info  = info,
								},
							})
						end
					end
				end
			end
		end
	end)
end

function TOGBankClassic_UI_Search:SubFilterMatches(item)
	if not item then return true end

	-- No filters active? Always match
	local mode = self.SubFilterMode
	if not self.FilterUsableLevel and (not mode or mode == FILTER_ANY) then
		return true
	end

	-- Info should already be populated in BuildSearchData
	local info = item.Info
	if not info then return false end

	-- Usable-level check
	if self.FilterUsableLevel then
		---@diagnostic disable-next-line: undefined-global
		local playerLevel = UnitLevel("player") or 1
		if (info.level or 0) > playerLevel then return false end
	end

	-- Type/subtype filter
	if mode == "type" then
		local val = self.SubFilterValue
		if not val or val == FILTER_ANY then return true end
		if tostring(info.class) ~= val then return false end
		local sub = self.SubFilterSubValue
		if sub and sub ~= FILTER_ANY then
			return tostring(info.subClass) == sub
		end
		return true
	-- Quality filter
	elseif mode == "quality" then
		local val = self.SubFilterValue
		if not val or val == FILTER_ANY then return true end
		return tostring(info.rarity) == val
	end

	return true
end

function TOGBankClassic_UI_Search:DrawContent()
	if not self.Results then
		return
	end

	self.Results:ReleaseChildren()
	self.Window:SetStatusText("")
	self.Results:DoLayout()

	local hasSubFilter = self.FilterUsableLevel
		or (self.SubFilterMode and self.SubFilterMode ~= FILTER_ANY
			and (self.SubFilterValue and self.SubFilterValue ~= FILTER_ANY
				or (self.SubFilterSubValue and self.SubFilterSubValue ~= FILTER_ANY)))
	if not self.SearchText and not hasSubFilter then
		return
	end

	--retain search input after close
	if self.SearchText then
		self.searchField:SetText(self.SearchText)
		local searchLength = string.len(self.SearchText)
		self.searchField.editbox:SetCursorPosition(searchLength)
	end

	local search = self.SearchText or ""
	if search ~= "" and string.sub(search, 0, 2) == "|c" then
		self.searchField:SetText("")
		local item = Item:CreateFromItemLink(search)
		if item and item.itemID then
			-- Item object is valid, safe to use ContinueOnItemLoad
			item:ContinueOnItemLoad(function()
				local name = item:GetItemName()
				if name then
					self.SearchText = name
					self.searchField:SetText(name)
					self:DrawContent()
					self.searchField:ClearFocus()
				end
			end)
		end
		return
	end

	local searchText = search:lower()

	if string.len(searchText) < 3 and not hasSubFilter then
		return
	end

	local searchData = self.SearchData
	if not searchData then
		return
	end

	TOGBankClassic_Output:Debug("MAIL", "SCAN", "[SEARCH-004] Search for '%s': Corpus has %d entries", searchText, #searchData.Corpus)
	TOGBankClassic_Output:Debug("UI", "SEARCH", "DrawContent: start text='%s' corpus=%d t=%.3f", searchText, #searchData.Corpus, GetTime())

	-- Initialize pagination state
	self.currentPage = self.currentPage or 1

	-- PASS 1: Collect all matching items
	local matchedItems = {}
	for _, v in pairs(searchData.Corpus) do
		if v then
			local nameMatches = string.len(searchText) < 3 or string.find(v:lower(), searchText) ~= nil
			if nameMatches then
				local lookupList = searchData.Lookup[v]
				if lookupList then
					for _, vv in pairs(lookupList) do
						if self:SubFilterMatches(vv.item) then
							table.insert(matchedItems, { item = vv.item, alt = vv.alt })
						end
					end
				end
			end
		end
	end

	local totalMatches = #matchedItems
	self.totalMatches = totalMatches
	TOGBankClassic_Output:Debug("UI", "SEARCH", "Total matches: %d", totalMatches)

	-- Sort the matched items based on selected sort mode
	local sortMode = self.SortMode or "alpha"
	if sortMode == "alpha" then
		table.sort(matchedItems, function(a, b)
			return (a.item.Info.name or "") < (b.item.Info.name or "")
		end)
	elseif sortMode == "alpha_desc" then
		table.sort(matchedItems, function(a, b)
			return (a.item.Info.name or "") > (b.item.Info.name or "")
		end)
	elseif sortMode == "level" then
		table.sort(matchedItems, function(a, b)
			local aLevel = a.item.Info.level or 0
			local bLevel = b.item.Info.level or 0
			if aLevel ~= bLevel then
				return aLevel > bLevel
			end
			return (a.item.Info.name or "") < (b.item.Info.name or "")
		end)
	elseif sortMode == "level_asc" then
		table.sort(matchedItems, function(a, b)
			local aLevel = a.item.Info.level or 0
			local bLevel = b.item.Info.level or 0
			if aLevel ~= bLevel then
				return aLevel < bLevel
			end
			return (a.item.Info.name or "") < (b.item.Info.name or "")
		end)
	elseif sortMode == "rarity" then
		table.sort(matchedItems, function(a, b)
			local aRarity = a.item.Info.rarity or 0
			local bRarity = b.item.Info.rarity or 0
			if aRarity ~= bRarity then
				return aRarity > bRarity
			end
			return (a.item.Info.name or "") < (b.item.Info.name or "")
		end)
	elseif sortMode == "rarity_asc" then
		table.sort(matchedItems, function(a, b)
			local aRarity = a.item.Info.rarity or 0
			local bRarity = b.item.Info.rarity or 0
			if aRarity ~= bRarity then
				return aRarity < bRarity
			end
			return (a.item.Info.name or "") < (b.item.Info.name or "")
		end)
	end

	-- Calculate page range
	local startIdx = (self.currentPage - 1) * RESULTS_PER_PAGE
	local endIdx = startIdx + RESULTS_PER_PAGE

	-- PASS 2: Render only items in current page range
	local renderedCount = 0
	for i = startIdx + 1, math.min(endIdx, totalMatches) do
		local matched = matchedItems[i]
		local resultItem = matched.item
		local bankAlt = matched.alt

		local itemWidget = TOGBankClassic_UI:DrawItem(resultItem, self.Results, 30, 35, 30, 30, 0, 5)
		if itemWidget then
			itemWidget:SetCallback("OnClick", function(widget, event)
				if IsShiftKeyDown() or IsControlKeyDown() then
					TOGBankClassic_UI:EventHandler(widget, event)
					return
				end
				TOGBankClassic_UI_Search:ShowRequestDialog(resultItem, bankAlt)
			end)

			-- Add label showing which banker has this item
			local label = TOGBankClassic_UI:Create("Label")
			label:SetHeight(35)
			label:SetText("|cFFAAAAAA" .. bankAlt .. "|r")
			self.Results:AddChild(label)
			renderedCount = renderedCount + 1
		end
	end

	TOGBankClassic_Output:Debug("UI", "SEARCH", "DrawContent: rendered %d/%d items (page %d) t=%.3f", renderedCount, totalMatches, self.currentPage, GetTime())

	-- Update pagination button states
	local totalPages = math.max(1, math.ceil(totalMatches / RESULTS_PER_PAGE))
	if self.prevButton then
		self.prevButton:SetDisabled(self.currentPage <= 1)
	end
	if self.nextButton then
		self.nextButton:SetDisabled(self.currentPage >= totalPages)
	end

	-- Update status text with pagination info
	local status
	if totalMatches == 0 then
		status = "No Results"
	elseif totalMatches <= RESULTS_PER_PAGE then
		-- Only one page, show simple count
		status = totalMatches .. " Result"
		if totalMatches > 1 then
			status = status .. "s"
		end
	else
		-- Multiple pages, show range and page number
		local showStart = startIdx + 1
		local showEnd = math.min(endIdx, totalMatches)
		status = string.format("Showing %d-%d of %d (Page %d/%d)", showStart, showEnd, totalMatches, self.currentPage, totalPages)
	end
	self.Window:SetStatusText(status)

	--redo layout after all items are loaded to get scroll bar to load
	self.Results:DoLayout()
end
