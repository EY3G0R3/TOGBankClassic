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

-- Fourth cascade: armor equip-slot filter (only offered when Type = Armor).
-- Keys are normalized slot names; INVTYPE_TO_SLOT maps GetItemInfo()'s equipLoc
-- (#9) onto them so CHEST/ROBE collapse to one "chest" entry, etc.
local SLOT_LIST = {
	any      = "Any Slot",
	head     = "Head",
	neck     = "Neck",
	shoulder = "Shoulder",
	back     = "Back",
	chest    = "Chest",
	wrist    = "Wrist",
	hands    = "Hands",
	waist    = "Waist",
	legs     = "Legs",
	feet     = "Feet",
	finger   = "Finger",
	trinket  = "Trinket",
	shield   = "Shield",
	holdable = "Held In Off-hand",
	relic    = "Relic",
}
local SLOT_ORDER = { "any", "head", "neck", "shoulder", "back", "chest", "wrist", "hands", "waist", "legs", "feet", "finger", "trinket", "shield", "holdable", "relic" }
local INVTYPE_TO_SLOT = {
	INVTYPE_HEAD = "head", INVTYPE_NECK = "neck", INVTYPE_SHOULDER = "shoulder",
	INVTYPE_CLOAK = "back", INVTYPE_CHEST = "chest", INVTYPE_ROBE = "chest",
	INVTYPE_WRIST = "wrist", INVTYPE_HAND = "hands", INVTYPE_WAIST = "waist",
	INVTYPE_LEGS = "legs", INVTYPE_FEET = "feet", INVTYPE_FINGER = "finger",
	INVTYPE_TRINKET = "trinket", INVTYPE_SHIELD = "shield",
	INVTYPE_HOLDABLE = "holdable", INVTYPE_RELIC = "relic",
}

-- Resolve an item's normalized equip-slot key, caching info.equipSlot on first
-- lookup (GetItemInfo #9 is warm by the time items are on screen). Returns nil
-- when the slot is unknown/uncached.
local function resolveSlotKey(info, item)
	local loc = info.equipSlot
	if not loc or loc == "" then
		local src = item and (item.Link or (item.ID and ("item:" .. item.ID)))
		if src then
			loc = select(9, GetItemInfo(src))
			if loc and loc ~= "" then info.equipSlot = loc end
		end
	end
	return loc and INVTYPE_TO_SLOT[loc] or nil
end

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

	-- VIEWBANK-001: a view-only bank toon is visible but not requestable. Don't open
	-- the request dialog; tell the user why instead.
	if TOGBankClassic_Guild:IsViewOnlyBank(bankAlt) then
		TOGBankClassic_Output:Warn("%s is a view-only bank — its items can be viewed but not requested.", bankAlt)
		return
	end

	self:EnsureRequestDialog()

	local itemName = itemEntry.Info.name or (itemEntry.Link and itemEntry.Link:match("%[(.-)%]")) or "Unknown item"
	self.requestContext = {
		item = itemEntry,
		bank = bankAlt,
		itemName = itemName,
		itemID = itemEntry.ID,  -- numeric ID; enables same-name variant disambiguation on fulfillment
		-- REQ-003: random-suffix ID (e.g. "of the Tiger" vs "of the Monkey"), which shares itemID
		-- with its sibling variants. nil for plain items and items with no link available.
		suffixID = TOGBankClassic_Item:GetSuffixID(itemEntry.Link),
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
		suffixID = self.requestContext.suffixID,  -- REQ-003: nil unless a random-suffix variant
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

	-- Filter row — compact horizontal layout. Each widget has an explicit width sized
	-- to its content; AceGUI's Flow layout auto-wraps based on the search window's
	-- current width so a wide window keeps everything on one row and a narrow window
	-- stacks them onto multiple rows. Sum of all widths is ~720px; user resizes the
	-- search window to taste.
	--
	-- Order is: [Min lvl] [Max lvl] [Filter] [Subtype] [Sub-subtype] [Slot] [Sort] [Usable]
	-- ([Slot] is the armor equip-slot dropdown, enabled only when Type = Armor.)
	-- The small numeric inputs lead so they don't get orphaned on their own row when
	-- the window is narrow; gives a denser top-left filter cluster.
	--
	-- Forward declarations: callbacks below reference widgets/functions defined later.
	local subValueDropdown, subSubValueDropdown, subSlotDropdown
	local usableCheck, updateUsableCB

	local function resetSubclass()
		self.SubFilterSubValue = FILTER_ANY
		subSubValueDropdown:SetList({ [FILTER_ANY] = "---" }, { FILTER_ANY })
		subSubValueDropdown:SetValue(FILTER_ANY)
		subSubValueDropdown:SetDisabled(true)
	end

	-- The armor equip-slot dropdown is only meaningful for Type = Armor; reset +
	-- disable it whenever the Filter / Type selection changes away from Armor.
	local function resetSlot()
		self.SubFilterSlot = FILTER_ANY
		if subSlotDropdown then
			subSlotDropdown:SetList({ [FILTER_ANY] = "---" }, { FILTER_ANY })
			subSlotDropdown:SetValue(FILTER_ANY)
			subSlotDropdown:SetDisabled(true)
		end
	end

	-- Min level (numeric input, 3 digits max). No gating on other filters — cheap to compute.
	-- Empty / non-numeric input is treated as 0 (no constraint).
	local minLevelInput = TOGBankClassic_UI:Create("EditBox")
	minLevelInput:SetLabel("Min lvl")
	minLevelInput:SetMaxLetters(3)
	minLevelInput:SetWidth(60)
	-- Shift label +5px right and -2px down so it doesn't overhang the EditBox's left edge.
	minLevelInput.label:ClearAllPoints()
	minLevelInput.label:SetPoint("TOPLEFT",  minLevelInput.frame, "TOPLEFT",  5, -2)
	minLevelInput.label:SetPoint("TOPRIGHT", minLevelInput.frame, "TOPRIGHT", 0, -2)
	minLevelInput:SetCallback("OnTextChanged", function(_, _, text)
		self.MinLevel = tonumber(text) or 0
		self.currentPage = 1
		self:DrawContent()
	end)
	-- Tooltip hit frame over the label (FontStrings can't fire mouse events).
	local minLevelLabelHit = CreateFrame("Frame", nil, minLevelInput.frame)
	minLevelLabelHit:SetPoint("TOPLEFT",  minLevelInput.frame, "TOPLEFT",  5, -2)
	minLevelLabelHit:SetPoint("TOPRIGHT", minLevelInput.frame, "TOPRIGHT", 0, -2)
	minLevelLabelHit:SetHeight(16)
	minLevelLabelHit:EnableMouse(true)
	TOGBankClassic_UI:AttachTooltip(minLevelLabelHit, "ANCHOR_TOP", "Minimum Required Level", {
		"Hide items whose required level is below this number.",
		"Leave empty (or 0) for no minimum.",
		" ",
		{"Items with no required level (trade goods, recipes, etc.) are hidden when a min is set.", 1, 0.8, 0.4, true},
	})
	searchWindow:AddChild(minLevelInput)
	self.minLevelInput = minLevelInput

	-- Max level
	local maxLevelInput = TOGBankClassic_UI:Create("EditBox")
	maxLevelInput:SetLabel("Max lvl")
	maxLevelInput:SetMaxLetters(3)
	maxLevelInput:SetWidth(60)
	maxLevelInput.label:ClearAllPoints()
	maxLevelInput.label:SetPoint("TOPLEFT",  maxLevelInput.frame, "TOPLEFT",  5, -2)
	maxLevelInput.label:SetPoint("TOPRIGHT", maxLevelInput.frame, "TOPRIGHT", 0, -2)
	maxLevelInput:SetCallback("OnTextChanged", function(_, _, text)
		self.MaxLevel = tonumber(text) or 0
		self.currentPage = 1
		self:DrawContent()
	end)
	local maxLevelLabelHit = CreateFrame("Frame", nil, maxLevelInput.frame)
	maxLevelLabelHit:SetPoint("TOPLEFT",  maxLevelInput.frame, "TOPLEFT",  5, -2)
	maxLevelLabelHit:SetPoint("TOPRIGHT", maxLevelInput.frame, "TOPRIGHT", 0, -2)
	maxLevelLabelHit:SetHeight(16)
	maxLevelLabelHit:EnableMouse(true)
	TOGBankClassic_UI:AttachTooltip(maxLevelLabelHit, "ANCHOR_TOP", "Maximum Required Level", {
		"Hide items whose required level is above this number.",
		"Leave empty (or 0) for no maximum.",
	})
	searchWindow:AddChild(maxLevelInput)
	self.maxLevelInput = maxLevelInput

	-- Filter selector (Type / Quality)
	local subFilterDropdown = TOGBankClassic_UI:Create("Dropdown")
	subFilterDropdown:SetLabel("Filter")
	subFilterDropdown.label:ClearAllPoints()
	subFilterDropdown.label:SetPoint("TOPLEFT", subFilterDropdown.frame, "TOPLEFT", 3, 0)
	subFilterDropdown.label:SetPoint("TOPRIGHT", subFilterDropdown.frame, "TOPRIGHT", 0, 0)
	-- Hit frame over the "Filter" label for tooltip. Spans the full dropdown width
	-- now that the inline Usable checkbox has been split out into its own widget.
	local subFilterLabelHit = CreateFrame("Frame", nil, subFilterDropdown.frame)
	subFilterLabelHit:SetPoint("TOPLEFT", subFilterDropdown.frame, "TOPLEFT", 3, 0)
	subFilterLabelHit:SetPoint("TOPRIGHT", subFilterDropdown.frame, "TOPRIGHT", 0, 0)
	subFilterLabelHit:SetHeight(18)
	subFilterLabelHit:EnableMouse(true)
	TOGBankClassic_UI:AttachTooltip(subFilterLabelHit, "ANCHOR_RIGHT", "Filter", {
		"Narrow the results by item Type or Quality.",
		" ",
		"|cFFFFFFFFType|r: pick a type (Weapon, Armor, etc.), then a subtype (Sword, Cloth, etc.).",
		"|cFFFFFFFFQuality|r: pick a quality tier (Common, Uncommon, Rare, Epic).",
	})
	subFilterDropdown:SetList(SUBFILTER_LIST, SUBFILTER_ORDER)
	subFilterDropdown:SetValue(FILTER_ANY)
	subFilterDropdown:SetWidth(110)
	subFilterDropdown:SetCallback("OnValueChanged", function(_, _, value)
		self.SubFilterMode  = value
		self.SubFilterValue = FILTER_ANY
		resetSubclass()
		resetSlot()
		updateUsableCB(false)  -- reset to disabled until a specific value is chosen
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
		self.currentPage = 1
		self:DrawContent()
	end)
	searchWindow:AddChild(subFilterDropdown)
	self.subFilterDropdown = subFilterDropdown

	-- Subtype dropdown (cascaded from Filter)
	subValueDropdown = TOGBankClassic_UI:Create("Dropdown")
	subValueDropdown:SetLabel("")
	subValueDropdown.label:ClearAllPoints()
	subValueDropdown.label:SetPoint("TOPLEFT", subValueDropdown.frame, "TOPLEFT", 3, 0)
	subValueDropdown.label:SetPoint("TOPRIGHT", subValueDropdown.frame, "TOPRIGHT", 0, 0)
	subValueDropdown:SetList({ [FILTER_ANY] = "---" }, { FILTER_ANY })
	subValueDropdown:SetValue(FILTER_ANY)
	subValueDropdown:SetDisabled(true)
	subValueDropdown:SetWidth(130)
	subValueDropdown:SetCallback("OnValueChanged", function(_, _, value)
		self.SubFilterValue = value
		updateUsableCB(value ~= FILTER_ANY)  -- enable Usable once a specific value is picked
		resetSubclass()
		resetSlot()
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
		-- Armor (class 4) gains an extra equip-slot dropdown.
		if self.SubFilterMode == "type" and value == "4" then
			subSlotDropdown:SetList(SLOT_LIST, SLOT_ORDER)
			subSlotDropdown:SetValue(FILTER_ANY)
			subSlotDropdown:SetDisabled(false)
		end
		self.currentPage = 1
		self:DrawContent()
	end)
	searchWindow:AddChild(subValueDropdown)
	self.subValueDropdown = subValueDropdown

	-- Sub-subtype dropdown (third cascading level)
	subSubValueDropdown = TOGBankClassic_UI:Create("Dropdown")
	subSubValueDropdown:SetLabel("")
	subSubValueDropdown.label:ClearAllPoints()
	subSubValueDropdown.label:SetPoint("TOPLEFT", subSubValueDropdown.frame, "TOPLEFT", 3, 0)
	subSubValueDropdown.label:SetPoint("TOPRIGHT", subSubValueDropdown.frame, "TOPRIGHT", 0, 0)
	subSubValueDropdown:SetList({ [FILTER_ANY] = "---" }, { FILTER_ANY })
	subSubValueDropdown:SetValue(FILTER_ANY)
	subSubValueDropdown:SetDisabled(true)
	subSubValueDropdown:SetWidth(130)
	subSubValueDropdown:SetCallback("OnValueChanged", function(_, _, value)
		self.SubFilterSubValue = value
		self.currentPage = 1
		self:DrawContent()
	end)
	searchWindow:AddChild(subSubValueDropdown)
	self.subSubValueDropdown = subSubValueDropdown

	-- Armor equip-slot dropdown (fourth cascade; enabled only for Type = Armor)
	subSlotDropdown = TOGBankClassic_UI:Create("Dropdown")
	subSlotDropdown:SetLabel("")
	subSlotDropdown.label:ClearAllPoints()
	subSlotDropdown.label:SetPoint("TOPLEFT", subSlotDropdown.frame, "TOPLEFT", 3, 0)
	subSlotDropdown.label:SetPoint("TOPRIGHT", subSlotDropdown.frame, "TOPRIGHT", 0, 0)
	subSlotDropdown:SetList({ [FILTER_ANY] = "---" }, { FILTER_ANY })
	subSlotDropdown:SetValue(FILTER_ANY)
	subSlotDropdown:SetDisabled(true)
	subSlotDropdown:SetWidth(130)
	subSlotDropdown:SetCallback("OnValueChanged", function(_, _, value)
		self.SubFilterSlot = value
		self.currentPage = 1
		self:DrawContent()
	end)
	searchWindow:AddChild(subSlotDropdown)
	self.subSlotDropdown = subSlotDropdown

	-- Sort dropdown — tooltip is now on a label hit frame (was on the dropdown control
	-- itself, which made it pop up while clicking the dropdown — confusing).
	local sortDropdown = TOGBankClassic_UI:Create("Dropdown")
	sortDropdown:SetLabel("Sort")
	sortDropdown.label:ClearAllPoints()
	sortDropdown.label:SetPoint("TOPLEFT", sortDropdown.frame, "TOPLEFT", 3, 0)
	sortDropdown.label:SetPoint("TOPRIGHT", sortDropdown.frame, "TOPRIGHT", 0, 0)
	sortDropdown:SetList(SORT_LIST, SORT_ORDER)
	sortDropdown:SetValue("alpha")  -- Default to A-Z
	sortDropdown:SetWidth(150)
	sortDropdown:SetCallback("OnValueChanged", function(_, _, value)
		self.SortMode = value
		self:DrawContent()
	end)
	local sortLabelHit = CreateFrame("Frame", nil, sortDropdown.frame)
	sortLabelHit:SetPoint("TOPLEFT", sortDropdown.frame, "TOPLEFT", 3, 0)
	sortLabelHit:SetPoint("TOPRIGHT", sortDropdown.frame, "TOPRIGHT", 0, 0)
	sortLabelHit:SetHeight(18)
	sortLabelHit:EnableMouse(true)
	TOGBankClassic_UI:AttachTooltip(sortLabelHit, "ANCHOR_RIGHT", "Sort Order", {
		"Choose how to sort the search results.",
		"Options include alphabetical, by quality tier, and by required level.",
	})
	searchWindow:AddChild(sortDropdown)
	self.sortDropdown = sortDropdown
	self.SortMode = "alpha"  -- Initialize default sort mode

	-- Usable-by-my-level checkbox (standalone AceGUI widget; previously glued to the
	-- Filter dropdown's right edge). Disabled until a specific Type or Quality is
	-- selected — scanning every item against player level without a pre-filter is too
	-- slow on large guild banks.
	usableCheck = TOGBankClassic_UI:Create("CheckBox")
	usableCheck:SetLabel("Usable")
	usableCheck:SetWidth(80)
	usableCheck:SetCallback("OnValueChanged", function(_, _, value)
		self.FilterUsableLevel = value
		self.currentPage = 1
		self:DrawContent()
	end)
	TOGBankClassic_UI:AttachTooltip(usableCheck, "ANCHOR_TOP", "Usable by my level", {
		"Hide items whose required level is above your character's current level.",
		" ",
		{"Disabled until you pick a Type or Quality first —", 1, 0.5, 0.5, true},
		{"scanning every item against player level on a large guild bank is too slow.", 1, 0.5, 0.5, true},
	})
	searchWindow:AddChild(usableCheck)
	self.usableCheck = usableCheck

	-- Enable / disable the Usable checkbox; always clears state when disabling so the
	-- filter doesn't silently persist after the user changes the parent filter.
	updateUsableCB = function(enabled)
		if enabled then
			usableCheck:SetDisabled(false)
		else
			usableCheck:SetValue(false)
			usableCheck:SetDisabled(true)
			self.FilterUsableLevel = false
		end
	end
	updateUsableCB(false)  -- initial state: disabled until a Type/Quality is picked

	-- Pagination buttons (Prev / Next) live at the bottom-right of the window next
	-- to the close button — see the "Bottom-right control row" block at the end of
	-- DrawWindow. They're created AFTER scrollGroup so they layer on top of nothing.

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

	-- ─── Bottom-right control row ──────────────────────────────────────────────
	-- Mirrors the inventory window's bottom-right layout: status bar shrunk to
	-- leave room for icon-sized controls before the AceGUI close button.
	-- Order right-to-left from close: [Next ">"] [Prev "<"] [Help "i"] [...status bar...]
	-- All controls are raw frames parented to searchWindow.frame so they live
	-- outside AceGUI's child layout and don't get re-flowed on resize.

	-- Shrink the status bar to leave ~95px of room on the right for the three icons
	-- (help 24px + 8px gap + prev 20px + 4px gap + next 20px + ~10px gap to close ≈ 95px).
	local statusbg = searchWindow.statustext:GetParent()
	statusbg:ClearAllPoints()
	statusbg:SetPoint("BOTTOMLEFT",  searchWindow.frame, "BOTTOMLEFT",  15, 15)
	statusbg:SetPoint("BOTTOMRIGHT", searchWindow.frame, "BOTTOMRIGHT", -210, 15)

	-- Help "i" icon — opens a tooltip explaining the Search window.
	local helpIcon = CreateFrame("Frame", nil, searchWindow.frame)
	helpIcon:SetSize(24, 24)
	helpIcon:SetPoint("BOTTOMRIGHT", searchWindow.frame, "BOTTOMRIGHT", -133, 15)
	helpIcon:EnableMouse(true)
	-- HITBOX-001: lift above AceGUI's mouse-enabled bottom resize strip (sizer_s,
	-- level 101) so the whole icon takes clicks/hover instead of a center sliver.
	helpIcon:SetFrameLevel(searchWindow.frame:GetFrameLevel() + 10)
	local helpTex = helpIcon:CreateTexture(nil, "OVERLAY")
	helpTex:SetAllPoints(helpIcon)
	helpTex:SetTexture("Interface\\Common\\help-i")
	TOGBankClassic_UI:AttachTooltip(helpIcon, "ANCHOR_TOP", "Search Window — How It Works", {
		"Type at least 3 characters in |cFFFFFFFFItem Name|r to find items across all banker alts.",
		"You can also drag an item from your bags into the field to search by ID.",
		" ",
		"|cffffd100Filters|r (compact row, auto-wraps based on window width):",
		"  • Min lvl / Max lvl — required-level range",
		"  • Filter — pick a Type (then Subtype) or a Quality tier",
		"  • Sort — how to order results",
		"  • Usable — hide items above your level (needs a Type or Quality first)",
		" ",
		"Click any result to open the request popup. Use |cFFFFFFFF<|r and |cFFFFFFFF>|r at the bottom-right to page through results.",
	}, "search")  -- HELPNOTE-001: append the guild "search" note at the bottom

	-- Helper that creates one of the small bottom-right pagination buttons.
	-- Returns a raw frame Button with a SetDisabled(bool) method bolted on so the
	-- existing DrawContent path (self.prevButton:SetDisabled(...) / self.nextButton:...)
	-- keeps working without changes. Pattern mirrors the gear icon in Inventory.lua.
	local function createPaginationButton(label, anchorXOffset, tooltipTitle, tooltipLines, onClick)
		local btn = CreateFrame("Button", nil, searchWindow.frame)
		btn:SetSize(20, 20)
		btn:SetPoint("BOTTOMRIGHT", searchWindow.frame, "BOTTOMRIGHT", anchorXOffset, 17)
		btn:EnableMouse(true)
		btn:SetFrameLevel(searchWindow.frame:GetFrameLevel() + 10)  -- HITBOX-001

		local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		fs:SetPoint("CENTER", btn, "CENTER", 0, 0)
		fs:SetText(label)
		btn.text = fs

		btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		btn:SetScript("OnClick", onClick)

		-- Disabled visual: grey out the text. Raw frame buttons don't auto-do this.
		btn:SetScript("OnDisable", function(self_)
			if self_.text then self_.text:SetTextColor(0.5, 0.5, 0.5) end
		end)
		btn:SetScript("OnEnable", function(self_)
			if self_.text then self_.text:SetTextColor(1, 1, 1) end
		end)

		-- AceGUI-compatible alias so DrawContent's existing :SetDisabled() calls work.
		function btn:SetDisabled(disabled)
			if disabled then self:Disable() else self:Enable() end
		end

		TOGBankClassic_UI:AttachTooltip(btn, "ANCHOR_TOP", tooltipTitle, tooltipLines)
		return btn
	end

	-- Prev "<" button: at -163 (8px gap from help icon's -133 + 24px width).
	self.prevButton = createPaginationButton(
		"<", -163,
		"Previous page",
		{ "Show the previous page of results.", "Disabled when you're on the first page." },
		function()
			if self.currentPage > 1 then
				self.currentPage = self.currentPage - 1
				self:DrawContent()
			end
		end
	)
	self.prevButton:SetDisabled(true)

	-- Next ">" button: at -187 (4px gap from prev's -163 + 20px width — tight paired grouping).
	self.nextButton = createPaginationButton(
		">", -187,
		"Next page",
		{ "Show the next page of results.", "Disabled when you're on the last page." },
		function()
			local totalPages = math.ceil(self.totalMatches / RESULTS_PER_PAGE)
			if self.currentPage < totalPages then
				self.currentPage = self.currentPage + 1
				self:DrawContent()
			end
		end
	)
	self.nextButton:SetDisabled(true)
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
	local mode    = self.SubFilterMode
	local minLvl  = self.MinLevel or 0
	local maxLvl  = self.MaxLevel or 0  -- 0 means "no max"
	local hasLvlFilter = (minLvl > 0) or (maxLvl > 0)
	if not self.FilterUsableLevel and not hasLvlFilter
	   and (not mode or mode == FILTER_ANY) then
		return true
	end

	-- Info should already be populated in BuildSearchData
	local info = item.Info
	if not info then return false end

	-- Usable-level check (SORT-002: use required-to-use level, not item level)
	if self.FilterUsableLevel then
		---@diagnostic disable-next-line: undefined-global
		local playerLevel = UnitLevel("player") or 1
		if (info.reqLevel or 0) > playerLevel then return false end
	end

	-- Min/Max required-level range check.
	-- SORT-002: info.reqLevel is the item's required-to-use level (GetItemInfo #5); these filters
	-- are labelled "Required Level" and previously compared item level by mistake. Items with no
	-- requirement (trade goods, etc.) are treated as level 0: pass when no min is set, fail any positive min.
	if hasLvlFilter then
		local lvl = info.reqLevel or 0
		if minLvl > 0 and lvl < minLvl then return false end
		if maxLvl > 0 and lvl > maxLvl then return false end
	end

	-- Type/subtype filter
	if mode == "type" then
		local val = self.SubFilterValue
		if not val or val == FILTER_ANY then return true end
		if tostring(info.class) ~= val then return false end
		local sub = self.SubFilterSubValue
		if sub and sub ~= FILTER_ANY and tostring(info.subClass) ~= sub then
			return false
		end
		-- Armor equip-slot filter (only populated for Type = Armor).
		local slot = self.SubFilterSlot
		if slot and slot ~= FILTER_ANY then
			if resolveSlotKey(info, item) ~= slot then return false end
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
		or ((self.MinLevel or 0) > 0)
		or ((self.MaxLevel or 0) > 0)
		or (self.SubFilterMode and self.SubFilterMode ~= FILTER_ANY
			and (self.SubFilterValue and self.SubFilterValue ~= FILTER_ANY
				or (self.SubFilterSubValue and self.SubFilterSubValue ~= FILTER_ANY)
				or (self.SubFilterSlot and self.SubFilterSlot ~= FILTER_ANY)))
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

	-- SORT-002/003: resolve required level from the live cache before sorting/filtering, retrying
	-- while unresolved (nil OR 0) so a cold-cache 0 doesn't stick. Mirrors Item:Sort's prep so the
	-- Search tab orders and filters by required level as reliably as the inventory tab.
	for _, entry in ipairs(matchedItems) do
		local info = entry.item and entry.item.Info
		if info and (not info.reqLevel or info.reqLevel == 0) then
			local src = entry.item.Link or entry.item.ID
			if src then
				local _, _, _, _, mreq = GetItemInfo(src)
				if mreq and mreq > 0 then
					info.reqLevel = mreq
				end
			end
		end
	end

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
	elseif sortMode == "type" then
		-- SORT-001/SORT-003: mirror Item:Sort "type" — class, then subclass/material, then
		-- required-to-use level high→low within the material, then equip slot, rarity, name.
		-- (Previously Search had no "type" case, so selecting By Type left results in scan order.)
		table.sort(matchedItems, function(a, b)
			local ai, bi = a.item.Info, b.item.Info
			if ai.class ~= bi.class then
				return (ai.class or 99) < (bi.class or 99)
			end
			if ai.subClass ~= bi.subClass then
				return (ai.subClass or 99) < (bi.subClass or 99)
			end
			local aLevel = ai.reqLevel or 0
			local bLevel = bi.reqLevel or 0
			if aLevel ~= bLevel then
				return aLevel > bLevel
			end
			local aEquip = ai.equipId or 0
			local bEquip = bi.equipId or 0
			if aEquip ~= bEquip then
				return aEquip < bEquip
			end
			if ai.rarity ~= bi.rarity then
				return (ai.rarity or 0) < (bi.rarity or 0)
			end
			return (ai.name or "") < (bi.name or "")
		end)
	elseif sortMode == "level" then
		-- SORT-002: required-to-use level, high to low (reqLevel = GetItemInfo #5)
		table.sort(matchedItems, function(a, b)
			local aLevel = a.item.Info.reqLevel or 0
			local bLevel = b.item.Info.reqLevel or 0
			if aLevel ~= bLevel then
				return aLevel > bLevel
			end
			return (a.item.Info.name or "") < (b.item.Info.name or "")
		end)
	elseif sortMode == "level_asc" then
		-- SORT-002: required-to-use level, low to high
		table.sort(matchedItems, function(a, b)
			local aLevel = a.item.Info.reqLevel or 0
			local bLevel = b.item.Info.reqLevel or 0
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

			-- Add label showing which banker has this item. VIEWBANK-001: tag
			-- view-only banks so users see they can't request before clicking.
			local label = TOGBankClassic_UI:Create("Label")
			label:SetHeight(35)
			local bankerText = "|cFFAAAAAA" .. bankAlt .. "|r"
			if TOGBankClassic_Guild:IsViewOnlyBank(bankAlt) then
				bankerText = bankerText .. " |cFFFFCC00(view only)|r"
			end
			label:SetText(bankerText)
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
