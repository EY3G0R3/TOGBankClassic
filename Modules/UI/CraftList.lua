-- Modules/UI/CraftList.lua -- GSL-MERGE-001 build step 3 (v1.7.0): the shopping list's two tabs in the
-- Guild Bank window. The operator, 2026-09-25: "make a tab for the shopping list itself, and then an
-- officer only tab to set it up with the same/improved functionality in gsl. but i want to use the
-- look and feel of the new bank for the tabs."
--
--   Shopping List  (everyone): what the guild wants, or -- one dropdown away -- the reagents that
--                  takes, each netted against the home bank and your bags (CraftList:Demand, D4).
--   List Setup     (the list's writers: the GM, officers, the `[GSL]`-tagged member): find a recipe
--                  (LibProfessionDB) or an item (LibItemDB) by name and add it at a count, change or
--                  remove what is on the list, and set the gather window (LibAceGUIWidgets' date
--                  picker). GuildShoppingList's own editing, on the libraries.
--
-- Nothing here is new machinery (the operator's rule, docs/GSL_MERGE.md section 2): the tabs are
-- Browse's -- its tab group, its one-row strip (Browse:BuildSimpleStrip), UI/RowList rows, the shared
-- chrome and status line -- and every item is named and iconned through Inventory/Resolve
-- (CraftList.Describe). The data half (WantedRows / ReagentRows / SetupRows) is plain functions, so
-- it is specced without a frame; the window half renders what they return.
TOGBankClassic_UI_CraftList = {}
local UICL = TOGBankClassic_UI_CraftList

UICL.TAB       = { value = "shopping",      text = "Shopping List" }
UICL.SETUP_TAB = { value = "shoppingsetup", text = "List Setup" }
UICL.ANY = "any"
-- A search's result cap per library: enough to find a thing, small enough to draw on every keystroke.
UICL.SEARCH_MAX = 100

--- Is `value` one of this file's tabs?
function UICL.IsOurTab(value)
	return value == UICL.TAB.value or value == UICL.SETUP_TAB.value
end

--- A profession's name, in the client's language, from its skill line id. The client's own
--- C_TradeSkillUI.GetTradeSkillDisplayName (Classic Era, TBC and MoP Classic all carry it; Blizzard's
--- guild roster names its profession headers with it).
---@param profId number
---@return string
function UICL.ProfessionName(profId)
	local T = C_TradeSkillUI
	local name = T and T.GetTradeSkillDisplayName and T.GetTradeSkillDisplayName(profId)
	if type(name) == "string" and name ~= "" then return name end
	return "Profession " .. tostring(profId)
end

--- A profession's icon, from the same client namespace (nil when the client has none).
function UICL.ProfessionIcon(profId)
	local T = C_TradeSkillUI
	return T and T.GetTradeSkillTexture and T.GetTradeSkillTexture(profId) or nil
end

--- `name` in the colour of item quality `quality`, through the one helper the Browse rows use.
local function qualityText(name, quality)
	return TOGBankClassic_UI:QualityText(name, quality)
end

-- ─── Column specs ──────────────────────────────────────────────────────────────

local ICON_COL = { key = "icon", header = "", width = 16, icon = true, sortable = false }

-- WANTED-BREATH-001 (the operator 2026-09-26: "can you have the wanted stuff 'breath' using the
-- function from the widgets library?"): Still needed breathes while the guild still needs some --
-- LibAceGUIWidgets W:Breathe, the call the help icon, the cancelled date and the stay-online line
-- make. The breath animates a frame's alpha and a FontString cannot host it (BREATH-001), so the
-- column builds its own cell: a frame holding the number, painted by paintShort from onRowRender.
local function buildShortCell(row)
	local host = CreateFrame("Frame", nil, row)
	local fs = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	if TOGBankClassic_UI.UIScaledFont then TOGBankClassic_UI:UIScaledFont(fs, "GameFontHighlightSmall") end
	fs:SetAllPoints(host)
	fs:SetJustifyH("CENTER")
	fs:SetWordWrap(false)
	host.text = fs
	return host
end

local function paintShort(entry, row)
	local host = row.cells and row.cells.short
	if not (host and host.text) then return end
	host.text:SetText(tostring(entry.short or ""))
	local W = TOGBankClassic_UI.Widgets
	if type(entry.short) == "number" and entry.short > 0 then
		if W and W.Breathe then W:Breathe(host) end
	elseif W and W.StopBreathing then
		W:StopBreathing(host)   -- Stop + alpha 1: a pooled row reused for a met entry must not stay dim
	end
end

local function controlButton(host, text)
	local b = CreateFrame("Button", nil, host)
	b:SetSize(14, 16)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetAllPoints(b)
	fs:SetJustifyH("CENTER")
	fs:SetText(text)
	b.label = fs
	return b
end

-- SHOPLIST-SPLIT-001: on the Shopping List tab a click on the ROW orders the item (D6), so the
-- expander is a button of its own in the first column, not a row click as it is on List Setup. A
-- row with nothing to open takes no mouse, so a click there falls through to the row.
local function buildArrowCell(row)
	local b = controlButton(row, "")
	b:SetScript("OnClick", function() TOGBankClassic_UI_CraftList:ToggleWanted(b.entry) end)
	return b
end

local function paintWanted(entry, row)
	paintShort(entry, row)
	local b = row.cells and row.cells.arrow
	if not b then return end
	b.entry = entry
	b.label:SetText(entry.arrow or "")
	b:EnableMouse(entry.expandable and true or false)
end

-- SHOPLIST-SPLIT-001 (the operator 2026-09-26: "the + and the shopping list totals need to be on the
-- shopping list tab as well ... the shopping list tab needs to be like the list setup tab, the items
-- on the top, but instead of a search bit on the bottom, the bottom rows should be all the reagents
-- we need to make the items in the list"): the wanted items are the box on top, unsorted so a
-- reagent stays under its item, as List Setup's box is.
UICL.WANTED_COLUMNS = {
	{ key = "arrow", header = "", width = 14, sortable = false, build = buildArrowCell },
	ICON_COL,
	{ key = "name",  header = "Item",       sortable = false, headerTip = "What the guild wants: a crafted item, or an item to gather. Click + to see what a crafted item takes; click the row to request it from the bank." },
	{ key = "kind",  header = "Profession", width = 110, sortable = false, headerTip = "The profession that makes it, or Item for something gathered or handed in." },
	{ key = "count", header = "Wanted",     width = 56, justify = "CENTER", sortable = false, headerTip = "How many the guild wants. Under an opened item: how many of that reagent the rest of it takes." },
	{ key = "bank",  header = "In bank",    width = 56, justify = "CENTER", sortable = false, headerTip = "How many your guild's bank characters already hold." },
	{ key = "short", header = "Still needed", width = 80, justify = "CENTER", sortable = false, build = buildShortCell,
	  headerTip = "Wanted, less what the bank already holds. It breathes while the guild still needs some." },
}

-- Missing reads red while anything is, green at 0 -- the one number a gatherer is here for.
local function missingText(v)
	if type(v) ~= "number" then return "" end
	if v > 0 then return "|cffff4040" .. v .. "|r" end
	return "|cff40ff400|r"
end

UICL.REAGENT_COLUMNS = {
	ICON_COL,
	{ key = "name",    header = "Reagent", headerTip = "A reagent the list's recipes take, or a wanted item. Mouse over for its tooltip." },
	{ key = "needed",  header = "Needed",  width = 56, justify = "CENTER", headerTip = "How many the whole list takes, for what the bank does not already hold of each crafted item." },
	{ key = "bank",    header = "Bank",    width = 56, justify = "CENTER", headerTip = "How many your guild's bank characters hold." },
	-- GSL-BANK-001: the shopping-list character's own stock (bags, bank, mail), as any banker's.
	{ key = "gsl",     header = "GSL",     width = 48, justify = "CENTER", headerTip = "How many the shopping-list character (the one with [GSL] in their public note) already has, in their bags, bank and mail." },
	{ key = "you",     header = "You",     width = 48, justify = "CENTER", headerTip = "How many are in your bags." },
	{ key = "missing", header = "Missing", width = 60, justify = "CENTER", format = missingText, headerTip = "What the shopping-list character still needs: the whole list's need, less what they already have. Send these to them." },
}

UICL.SETUP_COLUMNS = {
	ICON_COL,
	{ key = "name",   header = "Recipe or item", headerTip = "Left-click to put it on the list at the How many count, or to change its count. Right-click to take it off." },
	{ key = "kind",   header = "Type",    width = 110 },
	{ key = "onlist", header = "On list", width = 60, justify = "CENTER", headerTip = "How many the list wants now; empty when it is not on the list." },
}

-- SETUP-SPLIT-001 (the operator 2026-09-26: "split the list setup into whats on the list on top and
-- the selection bit on the bottom. lets make it look like TOGPM's 'shopping list' bit at the top of
-- the professions page when items are selected, it will be familiar"): the top box is TOGPM's
-- shopping-list strip (GUI/BrowserTab.lua FillShoppingListSection) -- icon, quality-coloured name,
-- then - count + and a red x at the right edge, in a bordered box capped at SETUP_BOX_SHARE of the
-- tab's height and scrolling past it -- built on this addon's own RowList rather than TOGPM's raw
-- frames. TOGPM's "!" (a per-character craft alert) and its reagent expander have no meaning for a
-- guild list, so they are not carried.
UICL.SETUP_BOX_SHARE, UICL.SETUP_BOX_MIN_ROWS, UICL.SETUP_BOX_FALLBACK_ROWS = 0.4, 4, 10
UICL.SETUP_BOX_PAD, UICL.SETUP_BOX_GAP = 4, 6
-- SETUP-SPLIT-002 (the operator 2026-09-26: "i don't mind the scrollbar, but we need to expand more
-- than 3 items before we introduce it. how does TOGPM do it?"): TOGPM shows every row until its 40%
-- cap and pads the section past the rows (container:SetHeight(visibleH + 40)). Sized to EXACTLY its
-- rows, this box lost the last one to RowList's floor() whenever the client snapped an edge to a
-- physical pixel, and the scrollbar came in at 3. Slack for one snapped pixel on each edge.
UICL.SETUP_BOX_SLACK = 2

--- The on-list box's right-hand cell: - count + x, TOGPM's order and colours. Each button reads the
--- entry its row is showing now (host.entry, set by paintControls), never one captured at build.
local function buildControlsCell(row)
	local host = CreateFrame("Frame", nil, row)
	local remove = controlButton(host, "|cFFFF4444x|r")
	remove:SetPoint("RIGHT", host, "RIGHT", -2, 0)
	local plus = controlButton(host, "|cFFFFD100+|r")
	plus:SetPoint("RIGHT", remove, "LEFT", -6, 0)
	local count = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	count:SetPoint("RIGHT", plus, "LEFT", -2, 0)
	count:SetWidth(30)
	count:SetJustifyH("CENTER")
	local minus = controlButton(host, "|cFFFFD100-|r")
	minus:SetPoint("RIGHT", count, "LEFT", -2, 0)
	minus:SetScript("OnClick", function() TOGBankClassic_UI_CraftList:StepEntry(host.entry, -1) end)
	plus:SetScript("OnClick", function() TOGBankClassic_UI_CraftList:StepEntry(host.entry, 1) end)
	remove:SetScript("OnClick", function() TOGBankClassic_UI_CraftList:RemoveEntry(host.entry) end)
	host.minus, host.count, host.plus, host.remove = minus, count, plus, remove
	return host
end

local function paintControls(entry, row)
	local host = row.cells and row.cells.ctl
	if not host then return end
	host.entry = entry
	-- SETUP-REAGENTS-001: a reagent row under a made item shows how many, and nothing to press.
	local controls = not entry.child
	for _, b in ipairs({ host.minus, host.plus, host.remove }) do
		if controls then b:Show() else b:Hide() end
	end
	host.count:SetText(entry.child and ("x" .. tostring(entry.count or 0)) or tostring(entry.count or ""))
end

-- SETUP-REAGENTS-001 (the operator 2026-09-26: "i would like to do a TOGPM like thing, where each
-- 'made' item shows the mats to make it. so we can say we need 5 flask OR x reagent y reagent etc.
-- then it can generate a complete reagent list based on the end items required"): TOGPM's expander
-- (BrowserTab.lua FillShoppingListSection: a + / - before the icon, a click on the row toggles, the
-- reagents indented under it at per-craft count times the quantity). The complete roll-up across
-- every end item is the Shopping List tab's Reagents view (CraftList:Demand), unchanged. The box is
-- not sortable, as TOGPM's is not: sorting would pull a reagent away from the item it belongs to.
UICL.ONLIST_COLUMNS = {
	{ key = "arrow", header = "", width = 12, justify = "CENTER", sortable = false },
	ICON_COL,
	{ key = "name", header = "On the list", sortable = false, headerTip = "What the guild wants now. Click a made item to see what it takes. Use - and + to change a count, x to take it off." },
	{ key = "kind", header = "Type", width = 110, sortable = false },
	{ key = "ctl",  header = "Wanted", width = 90, justify = "RIGHT", sortable = false, build = buildControlsCell },
}

-- ─── Data ──────────────────────────────────────────────────────────────────────

local function CL() return TOGBankClassic_CraftList end

--- One row per list entry, for the Shopping List tab's Wanted view.
---@return table rows
function UICL:WantedRows()
	local rows = {}
	local list = CL()
	if not list then return rows end
	for _, e in ipairs(list:Entries()) do
		local item = e.item or {}
		local name = e.name or "?"
		local kind = e.kind == "recipe" and UICL.ProfessionName(e.profId) or "Item"
		local bank = e.itemID and list:BankHolds(e.itemID) or nil
		local text = e.known and qualityText(name, item.quality) or ("|cff808080" .. name .. " (not in your ProfessionDB)|r")
		rows[#rows + 1] = {
			_id = e.key, key = e.key, entry = e, link = item.link,
			icon = item.icon or (e.profId and UICL.ProfessionIcon(e.profId)) or nil,
			name = text, kind = kind, count = e.count,
			-- An enchant makes no item, so nothing is held of it and nothing is subtracted.
			bank = bank or "", short = bank and math.max(0, e.count - bank) or e.count,
			_sort_name = name:lower(), _sort_bank = bank or -1,
			plainName = name,
		}
	end
	return rows
end

--- One row per reagent the list still needs, for the Reagents view.
---@return table rows, table unknownKeys
function UICL:ReagentRows()
	local rows = {}
	local list = CL()
	if not list then return rows, {} end
	local demand, unknown = list:Demand()
	for _, d in ipairs(demand) do
		local item = TOGBankClassic_CraftList.Describe(d.itemID)
		local name = item.name or ("Item " .. d.itemID)
		rows[#rows + 1] = {
			_id = d.itemID, itemID = d.itemID, link = item.link, icon = item.icon,
			name = qualityText(name, item.quality), needed = d.needed, bank = d.bank, gsl = d.gsl, you = d.you, missing = d.missing,
			_sort_name = name:lower(), plainName = name,
		}
	end
	return rows, unknown
end

--- The Setup tab's search results: the recipes LibProfessionDB finds (in `profId`'s profession, or
--- every one) and, when no profession narrows it, the items LibItemDB finds -- each marked with its
--- count when it is already on the list. An empty query finds nothing: what is on the list is the
--- box above (SETUP-SPLIT-001, OnListRows).
---@param query string|nil
---@param profId number|string|nil a profession id, or UICL.ANY / nil for all
---@return table rows, boolean capped
function UICL:SetupRows(query, profId)
	local rows, capped = {}, false
	local list = CL()
	if not list then return rows, capped end
	local held = list:GetList()
	query = (query or ""):match("^%s*(.-)%s*$")
	local onlyP = tonumber(profId)
	if query == "" then return rows, capped end
	local db = list.DB()
	if db and db.Search then
		local found = db:Search({ query = query, profId = onlyP, max = UICL.SEARCH_MAX })
		capped = found.capped and true or false
		for _, r in ipairs(found) do
			local key = TOGBankClassic_CraftList.RecipeKey(r.profId, r.recipeId)
			local item = r.craftedItemId and TOGBankClassic_CraftList.Describe(r.craftedItemId) or {}
			local name = r.name or ("Recipe " .. r.recipeId)
			rows[#rows + 1] = {
				_id = key, key = key, recipe = { profId = r.profId, recipeId = r.recipeId }, link = item.link,
				icon = item.icon or UICL.ProfessionIcon(r.profId),
				name = qualityText(name, item.quality), kind = UICL.ProfessionName(r.profId),
				onlist = held[key] and held[key].n or "", _sort_name = name:lower(), plainName = name,
			}
		end
	end
	-- ITEM-SEARCH-001 (the operator 2026-09-26: "we need to ensure the eko's that make juju's are on
	-- the list, why don't we just have the itemdb searchable on the GSL add list?"): LibItemDB is
	-- searched whatever the profession dropdown says -- a profession narrows the recipes only. It
	-- used to skip the item search whenever a profession was picked, so an E'ko (a Quest item, no
	-- profession makes it) could not be found from a profession view at all.
	local items = LibStub and LibStub("LibItemDB-1.0", true)
	if items and items.Search then
		local found = items:Search({ query = query, max = UICL.SEARCH_MAX })
		capped = capped or (found.capped and true or false)
		for _, it in ipairs(found) do
			local key = TOGBankClassic_CraftList.ItemKey(it.id)
			local item = TOGBankClassic_CraftList.Describe(it.id)
			local name = it.name or item.name or ("Item " .. it.id)
			rows[#rows + 1] = {
				_id = key, key = key, itemID = it.id, link = item.link or it.link, icon = item.icon,
				name = qualityText(name, it.quality or item.quality), kind = "Item",
				onlist = held[key] and held[key].n or "", _sort_name = name:lower(), plainName = name,
			}
		end
	end
	return rows, capped
end

--- SETUP-REAGENTS-001 / SHOPLIST-SPLIT-001: the one expander both boxes use. `rows` in, the same rows
--- out with, under each opened made item, one row per reagent (`child = true`, indented, `count` =
--- per-craft count x `times(row)`), sorted by name. `open` is that box's own per-session table of
--- opened keys. A made item carries `expandable` and its + / - in `arrow`; anything else an empty
--- arrow. `fill(kid)` adds a box's own columns to a reagent row.
---@param rows table WantedRows-shaped rows
---@param open table key -> true
---@param times function(row) -> number
---@param fill function|nil
---@return table
function UICL.WithReagents(rows, open, times, fill)
	local out = {}
	local db = CL() and CL().DB()
	for _, r in ipairs(rows) do
		local e = r.entry
		local reagents = e and e.kind == "recipe" and db and db.GetReagents and db:GetReagents(e.profId, e.recipeId) or nil
		local expandable = type(reagents) == "table" and next(reagents) ~= nil
		local isOpen = expandable and open[r.key] or false
		r.expandable = expandable or nil
		r.arrow = expandable and (isOpen and "|cFFFFD100-|r" or "|cFFFFD100+|r") or ""
		out[#out + 1] = r
		if isOpen then
			local kids, n = {}, tonumber(times(r)) or 0
			for itemID, per in pairs(reagents) do
				itemID, per = tonumber(itemID), tonumber(per) or 0
				if itemID and per > 0 then
					local item = TOGBankClassic_CraftList.Describe(itemID)
					local name = item.name or ("Item " .. itemID)
					local kid = { _id = r.key .. "/" .. itemID, child = true, parent = r.key, itemID = itemID,
						link = item.link, icon = item.icon, name = "   " .. qualityText(name, item.quality),
						kind = "", arrow = "", count = per * n, plainName = name }
					if fill then fill(kid) end
					kids[#kids + 1] = kid
				end
			end
			table.sort(kids, function(a, b) return a.plainName < b.plainName end)
			for _, k in ipairs(kids) do out[#out + 1] = k end
		end
	end
	return out
end

--- The on-list box's rows (SETUP-SPLIT-001): one per list entry, with its count for the controls,
--- and each opened made item's reagents at the per-craft count times the count wanted.
---@return table rows
function UICL:OnListRows()
	self.expanded = self.expanded or {}
	local rows = {}
	for _, r in ipairs(self:WantedRows()) do
		rows[#rows + 1] = { _id = r._id, key = r.key, entry = r.entry, link = r.link, icon = r.icon, name = r.name,
			kind = r.kind, count = r.count, _sort_name = r._sort_name, plainName = r.plainName }
	end
	return UICL.WithReagents(rows, self.expanded, function(r) return r.count end)
end

--- SHOPLIST-SPLIT-001: the Shopping List tab's box -- the wanted rows `rows` (already filtered by
--- the tab's search), each opened made item's reagents at the per-craft count times what is STILL
--- NEEDED of it (what the bank holds of the crafted item is already made), so an opened item and the
--- reagent roll-up below agree (CraftList:Demand nets the same way).
---@param rows table WantedRows rows
---@return table
function UICL:WantedTree(rows)
	self.wantedExpanded = self.wantedExpanded or {}
	return UICL.WithReagents(rows, self.wantedExpanded, function(r) return r.short end,
		function(kid) kid.bank = ""; kid.short = "" end)
end

--- The + / - on a Shopping List row (SHOPLIST-SPLIT-001).
function UICL:ToggleWanted(entry)
	if not (entry and entry.expandable) then return end
	self.wantedExpanded = self.wantedExpanded or {}
	self.wantedExpanded[entry.key] = not self.wantedExpanded[entry.key] or nil
	self:Draw(UICL.TAB.value)
end

--- A left click on a made item in the box opens or closes its reagents (SETUP-REAGENTS-001).
function UICL:OnOnListRowClick(entry, button)
	if not entry or button == "RightButton" then return end
	if TOGBankClassic_UI:HandleLinkClick(entry.link) then return end
	if not entry.expandable then return end
	self.expanded = self.expanded or {}
	self.expanded[entry.key] = not self.expanded[entry.key] or nil
	self:Draw(UICL.SETUP_TAB.value)
end

--- Rows whose plain name or kind carries every word of `query`.
local function filterRows(rows, query)
	if not query or query == "" then return rows end
	local out = {}
	for _, r in ipairs(rows) do
		if TOGBankClassic_UI:SearchMatch(query, r.plainName, r.kind) then out[#out + 1] = r end
	end
	return out
end
UICL.FilterRows = filterRows

-- ─── Window ────────────────────────────────────────────────────────────────────

local function Browse() return TOGBankClassic_UI_Browse end

--- The tab's filters, per session like the Browse tab's.
function UICL:Filters()
	self.filter = self.filter or { text = "" }
	self.setupFilter = self.setupFilter or { text = "", prof = UICL.ANY, count = 1 }
	return self.filter, self.setupFilter
end

--- Build the three row lists on the Guild Bank window's tab body (hidden), as Browse builds its own.
---@param body table the tab group's content frame
function UICL:Build(body)
	local function hover(entry)
		if entry and entry.link then TOGBankClassic_UI:ShowItemTooltip(entry.link) end
	end
	local function leave() TOGBankClassic_UI:HideTooltip() end
	local function list(columns, sortKey, onClick, onRender)
		local host = CreateFrame("Frame", nil, body)
		local l = TOGBankClassic_UI_RowList:New(host, {
			columns = columns, onRowClick = onClick, onRowEnter = hover, onRowLeave = leave,
			onRowRender = onRender,
		})
		l:SetSort(sortKey, false)
		host:Hide()
		return l
	end
	local function order(entry, _, button) self:OnListRowClick(entry, button) end
	self.ReagentList = list(UICL.REAGENT_COLUMNS, "name", order)
	self.SetupList   = list(UICL.SETUP_COLUMNS, "name", function(entry, _, button) self:OnSetupRowClick(entry, button) end)
	-- A bordered box (TOGPM's strip) holding an UNSORTED RowList -- the list's own row order keeps
	-- each reagent under its made item. SETUP-SPLIT-001's box and SHOPLIST-SPLIT-001's are this one.
	local function box(columns, onClick, onRender)
		local frame = CreateFrame("Frame", nil, body, "BackdropTemplate")
		TOGBankClassic_UI:ApplyThinBorder(frame)
		if frame.SetBackdropColor then frame:SetBackdropColor(0, 0, 0, 0.35) end
		local inner = CreateFrame("Frame", nil, frame)
		local pad = TOGBankClassic_UI:UIScaled(UICL.SETUP_BOX_PAD)
		inner:SetPoint("TOPLEFT", frame, "TOPLEFT", pad, -pad)
		inner:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad)
		local l = TOGBankClassic_UI_RowList:New(inner, {
			columns = columns, onRowClick = onClick, onRowEnter = hover, onRowLeave = leave, onRowRender = onRender,
		})
		frame:Hide()
		return frame, l
	end
	-- SHOPLIST-SPLIT-001: the Shopping List tab -- the wanted items on top, the reagent roll-up below.
	self.WantedBox, self.WantedList = box(UICL.WANTED_COLUMNS, order, paintWanted)
	-- SETUP-SPLIT-001: List Setup -- what is on the list on top, the search results below.
	self.SetupBox, self.OnListList = box(UICL.ONLIST_COLUMNS,
		function(entry, _, button) self:OnOnListRowClick(entry, button) end, paintControls)
end

--- The lists Browse:AnchorLists hangs under the one-row strip, and ShowTab's hide pass hides. The
--- two boxes' lists are not among them (their frames live inside the boxes): AnchorSetup places the
--- boxes and hangs the reagent roll-up and the search results under them.
function UICL:Lists()
	return { self.ReagentList, self.SetupList }
end

function UICL:HideLists()
	for _, l in ipairs(self:Lists()) do if l then l:Hide() end end
	if self.SetupBox then self.SetupBox:Hide() end
	if self.WantedBox then self.WantedBox:Hide() end
	self:SetGatherBreath(false)   -- every tab switch passes here; Draw puts it back on our tab
end

--- GATHER-BREATH-001 (the operator 2026-09-26: "the date isn't breathing", of the Shopping List
--- tab's "3 wanted -- gathering 2026-09-26 to 2026-10-03"): the status line breathes, through the
--- bar's SetLeftBreathing, while the tab shows a gather window.
function UICL:SetGatherBreath(on)
	local B = Browse()
	local bar = B and B.StatusBar
	if bar and bar.SetLeftBreathing then bar:SetLeftBreathing(on and true or false) end
end

--- SETUP-SPLIT-001: the box at the top of the tab body under the strip, the search results under the
--- box. Called by Browse:AnchorLists after its own pass (which put the results at the top).
---@param body table the tab body
---@param top number the strip's scaled height plus its gap
function UICL:AnchorSetup(body, top)
	if not body then return end
	local gap = TOGBankClassic_UI:UIScaled(UICL.SETUP_BOX_GAP)
	for _, pair in ipairs({ { self.SetupBox, self.SetupList }, { self.WantedBox, self.ReagentList } }) do
		local box, below = pair[1], pair[2] and pair[2].parent
		if box and below then
			box:ClearAllPoints()
			box:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -top)
			box:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -top)
			below:ClearAllPoints()
			below:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -gap)
			below:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
		end
	end
	self.setupTop = top
end

--- List Setup's box height for `n` rows (BoxHeight on its list).
---@param n number
---@return number
function UICL:SetupBoxHeight(n)
	return self:BoxHeight(self.OnListList, self.SetupBox, n)
end

--- A box's height for `n` rows: the header and every row, capped at SETUP_BOX_SHARE of the tab
--- body (never under SETUP_BOX_MIN_ROWS rows' worth) and scrolling past it, as TOGPM caps its strip.
--- Before the first layout has given the body a height, a fixed row count stands in (TOGPM's
--- fallback too). At least one row's height, so an empty list still shows its box.
---@param l table the box's RowList
---@param frame table the box
---@param n number
---@return number
function UICL:BoxHeight(l, frame, n)
	local rowH, headH = l.rowHeight, l.headerHeight
	local pad = TOGBankClassic_UI:UIScaled(UICL.SETUP_BOX_PAD) * 2
	local body = frame and frame:GetParent()
	local bodyH = body and body.GetHeight and body:GetHeight() or 0
	local maxRows
	if bodyH and bodyH > 0 then
		local avail = bodyH * UICL.SETUP_BOX_SHARE - headH - pad
		maxRows = math.max(UICL.SETUP_BOX_MIN_ROWS, math.floor(avail / rowH))
	else
		maxRows = UICL.SETUP_BOX_FALLBACK_ROWS
	end
	return headH + math.max(1, math.min(n, maxRows)) * rowH + pad + UICL.SETUP_BOX_SLACK
end

--- The - and + controls: a count one up or one down; one down from 1 takes the entry off, as
--- TOGPM's minus does. Through the list's own writers and the same gate as a setup-row click.
---@param row table an OnListRows row
---@param delta number
function UICL:StepEntry(row, delta)
	local e = row and row.entry
	if not e then return end
	self:WriteEntry(e, math.max(0, (tonumber(e.count) or 0) + delta))
end

--- The x control: take the entry off.
function UICL:RemoveEntry(row)
	if row and row.entry then self:WriteEntry(row.entry, 0) end
end

--- Write `count` for a list entry (0 removes it), refusing a player who may not edit.
function UICL:WriteEntry(e, count)
	local list, B = CL(), Browse()
	if not list then return end
	if not list:CanEditHere() then
		if B then B:SetStatus(UICL.NOT_ALLOWED_TEXT) end
		return
	end
	if count == 0 then return list:Remove(e.key) end
	if e.kind == "recipe" then return list:SetRecipe(e.profId, e.recipeId, count) end
	return list:SetItem(e.itemID, count)
end

--- ShowTab's branch for our tabs: the strip, then the list, then the draw.
function UICL:Show(value)
	if value == UICL.SETUP_TAB.value then
		self:BuildSetupStrip()
		self.SetupBox:Show()
		self.SetupList:Show()
	else
		self:BuildListStrip()
		self.WantedBox:Show()
		self.WantedList:Show()
		self.ReagentList:Show()
	end
	self:Draw(value)
end

--- The Shopping List tab's strip: the search box, the Tracker, and who to send items to. The Show
--- dropdown that switched between the wanted items and the reagents is gone (SHOPLIST-SPLIT-001):
--- the tab shows both.
function UICL:BuildListStrip()
	local B = Browse()
	local f = self:Filters()
	local strip = B:BuildSimpleStrip({ 260, 110, 440 })
	local search = TOGBankClassic_UI:Create("TOGBankSearchBox")
	search:SetPlaceholder("Search the shopping list")
	search:SetMaxLetters(50)
	search:SetWidth(TOGBankClassic_UI:UIScaled(260))
	if f.text ~= "" then search:SetText(f.text) end
	search:SetCallback("OnTextChanged", function(_, _, text)
		f.text = text or ""
		self:Draw(UICL.TAB.value)
	end)
	strip:AddChild(search)
	-- D5: the detached Reagent Tracker, for keeping the roll-up on screen while gathering.
	local tracker = TOGBankClassic_UI:Create("Button")
	tracker:SetText("Tracker")
	tracker:SetWidth(110)
	tracker:SetCallback("OnClick", function()
		if TOGBankClassic_UI_CraftTracker then TOGBankClassic_UI_CraftTracker:Toggle() end
	end)
	TOGBankClassic_UI:AttachTooltip(tracker, "ANCHOR_TOP", "Reagent Tracker",
		{ "Open or close a small window with the reagents to gather, which stays up while you play. /togbank tracker does the same." })
	TOGBankClassic_UI:ScaleStockWidget(tracker)
	strip:AddChild(tracker)
	-- GSL-SENDTO-001: who to mail gathered items to. Painted by Draw, which a roster change reaches.
	local sendTo = TOGBankClassic_UI:Create("Label")
	sendTo:SetWidth(TOGBankClassic_UI:UIScaled(440))
	if sendTo.SetFontObject then sendTo:SetFontObject(GameFontNormal) end
	strip:AddChild(sendTo)
	self.ListSearch, self.TrackerButton, self.SendToLabel = search, tracker, sendTo
end

--- GSL-SENDTO-001: "Send items to: <the [GSL] characters>", online ones first and green, offline
--- ones grey and marked; a guild with none is told how to name one.
---@param players table CraftList:GSLPlayers()
---@return string
function UICL.SendToText(players)
	if #players == 0 then
		return "|cff808080Send items to: no one has [GSL] in their public note yet|r"
	end
	local online, offline = {}, {}
	for _, p in ipairs(players) do
		if p.online then online[#online + 1] = "|cff40ff40" .. p.name .. "|r"
		else offline[#offline + 1] = "|cff808080" .. p.name .. " (offline)|r" end
	end
	for _, s in ipairs(offline) do online[#online + 1] = s end
	return "Send items to: " .. table.concat(online, ", ")
end

--- A gather-window date as the picker holds it (a local-midnight timestamp) or nil.
local function toStamp(d)
	if not d or d == "" then return nil end
	return Browse():ParseDate(d)
end

--- The Setup tab's strip: search, profession, how many, and the gather window.
function UICL:BuildSetupStrip()
	local B = Browse()
	local _, f = self:Filters()
	local strip = B:BuildSimpleStrip({ 240, 140, 80, 110, 110 })
	local search = TOGBankClassic_UI:Create("TOGBankSearchBox")
	search:SetPlaceholder("Find a recipe or item to add")
	search:SetMaxLetters(50)
	search:SetWidth(TOGBankClassic_UI:UIScaled(240))
	if f.text ~= "" then search:SetText(f.text) end
	search:SetCallback("OnTextChanged", function(_, _, text)
		f.text = text or ""
		self:Draw(UICL.SETUP_TAB.value)
	end)
	strip:AddChild(search)

	local profs, order = { [UICL.ANY] = "Any profession" }, { UICL.ANY }
	local db = CL() and CL().DB()
	for _, p in ipairs(db and db:GetProfessions() or {}) do
		profs[tostring(p)] = UICL.ProfessionName(p)
		order[#order + 1] = tostring(p)
	end
	if not profs[f.prof] then f.prof = UICL.ANY end
	local prof = TOGBankClassic_UI:Create("Dropdown")
	prof:SetLabel("Profession")
	prof:SetWidth(140)
	prof:SetList(profs, order)
	prof:SetValue(f.prof)
	prof:SetCallback("OnValueChanged", function(_, _, value)
		f.prof = value
		self:Draw(UICL.SETUP_TAB.value)
	end)
	TOGBankClassic_UI:ScaleStockWidget(prof)
	strip:AddChild(prof)

	local count = TOGBankClassic_UI:Create("EditBox")
	count:SetLabel("How many")
	count:SetWidth(80)
	count:SetMaxLetters(4)
	count:DisableButton(true)
	count:SetText(tostring(f.count))
	count:SetCallback("OnTextChanged", function(_, _, text)
		local n = tonumber(text)
		f.count = (n and n >= 1) and math.floor(n) or 1
	end)
	TOGBankClassic_UI:AttachTooltip(count, "ANCHOR_TOP", "How many", { "The count a left-click puts on the list." })
	TOGBankClassic_UI:ScaleStockWidget(count)
	strip:AddChild(count)

	-- D7: the gather window on the library's date picker. A library too old to carry the widget
	-- leaves the window unset here (it still shows on the Shopping List tab when an officer on a
	-- newer library sets it).
	local hasPicker = TOGBankClassic_UI.GetWidgetVersion and TOGBankClassic_UI:GetWidgetVersion("LAGW-DatePicker") ~= nil
	if hasPicker then
		local start, finish = CL():GetGatherWindow()
		local function picker(label, value, isStart, tip)
			local box = TOGBankClassic_UI:Create("LAGW-DatePicker")
			box:SetLabel(label)
			box:SetWidth(110)
			box:SetValue(toStamp(value))
			box:SetCallback("OnValueChanged", function(_, _, ts)
				local d = ts and date("%Y-%m-%d", ts) or ""
				local s, e = CL():GetGatherWindow()
				if isStart then s = d else e = d end
				if not CL():CanEditHere() then
					B:SetStatus(UICL.NOT_ALLOWED_TEXT)
				elseif not CL():SetGatherWindow(s, e) and s ~= "" and e ~= "" and e < s then
					B:SetStatus("The gather window was not changed: the end cannot be before the start.")
				end
			end)
			TOGBankClassic_UI:AttachTooltip(box, "ANCHOR_TOP", label, { tip, "Clear it for no date." })
			strip:AddChild(box)
			return box
		end
		self.GatherFrom = picker("Gather from", start, true, "The first day the guild is gathering for this list.")
		self.GatherUntil = picker("Gather until", finish, false, "The last day.")
	end
	self.SetupSearch, self.ProfDropdown, self.CountBox = search, prof, count
end

--- Paint `value`'s list from the model. The status line says what is showing.
function UICL:Draw(value)
	local B = Browse()
	if not (B and B.isOpen) then return end
	value = value or B.currentTab
	local f, sf = self:Filters()
	if value == UICL.SETUP_TAB.value then
		-- SETUP-SPLIT-001: what is on the list in the box, sized to it; the search results below.
		local onList = self:OnListRows()
		self.onListRowsShown = onList
		self.SetupBox:SetHeight(self:SetupBoxHeight(#onList))
		self.OnListList:SetData(onList, true)
		local rows, capped = self:SetupRows(sf.text, sf.prof)
		self.setupRowsShown = rows
		self.SetupList:SetData(rows, true)
		if sf.text == "" then
			B:SetStatus(string.format("%d on the list -- search above to add a recipe or item", #onList))
		else
			B:SetStatus(string.format("%d on the list, %d found%s -- left-click to put it on the list at %d, right-click to take it off",
				#onList, #rows, capped and " (showing the first matches; type more to narrow)" or "", sf.count))
		end
		return
	end
	local start, finish = CL():GetGatherWindow()
	local window = ""
	if start ~= "" or finish ~= "" then
		window = string.format(" -- gathering %s to %s", start ~= "" and start or "now", finish ~= "" and finish or "open-ended")
	end
	self:SetGatherBreath(window ~= "")
	if self.SendToLabel then
		self.sendToText = UICL.SendToText(CL():GSLPlayers())
		self.SendToLabel:SetText(self.sendToText)
	end
	-- SHOPLIST-SPLIT-001: the wanted items (with each opened item's reagents) in the box on top, the
	-- complete reagent roll-up under it; the search narrows both.
	local all = self:WantedRows()
	local tree = self:WantedTree(filterRows(all, f.text))
	local shownWanted = 0
	for _, r in ipairs(tree) do if not r.child then shownWanted = shownWanted + 1 end end
	self.wantedRowsShown = tree
	self.WantedBox:SetHeight(self:BoxHeight(self.WantedList, self.WantedBox, #tree))
	self.WantedList:SetData(tree, true)
	local reagents, unknown = self:ReagentRows()
	local rows = filterRows(reagents, f.text)
	self.reagentRowsShown = rows
	self.ReagentList:SetData(rows, true)
	if #all == 0 then
		B:SetStatus("The shopping list is empty" .. window)
		return
	end
	local missing = 0
	for _, r in ipairs(reagents) do if r.missing > 0 then missing = missing + 1 end end
	local extra = #unknown > 0 and string.format(" (%d recipe%s not in your ProfessionDB)", #unknown, #unknown == 1 and "" or "s") or ""
	local wanted = shownWanted < #all and string.format("%d of %d wanted match", shownWanted, #all) or string.format("%d wanted", #all)
	B:SetStatus(string.format("%s, %d reagent%s, %d still missing%s%s", wanted, #reagents,
		#reagents == 1 and "" or "s", missing, extra, window))
end

--- The model changed (a write here, or a merge heard): repaint whichever of our tabs is showing.
function UICL:OnListChanged()
	local B = Browse()
	if B and B.isOpen and UICL.IsOurTab(B.currentTab) then self:Draw(B.currentTab) end
	local T = TOGBankClassic_UI_CraftTracker
	if T and T.isOpen then T:Refresh() end   -- step 4: the detached tracker shows the same roll-up
end

--- Setup rows: a left click puts the entry on the list at the How many count (or changes its
--- count); a right click takes it off.
UICL.NOT_ALLOWED_TEXT = "Only the guild master, officers and the member with [GSL] in their public note can change the shopping list."

function UICL:OnSetupRowClick(entry, button)
	local list = CL()
	if not (entry and list) then return end
	-- Self-audit 3197046a F3: the role is checked first, so a refusal names its real reason.
	if not list:CanEditHere() then
		local B = Browse()
		if B then B:SetStatus(UICL.NOT_ALLOWED_TEXT) end
		return
	end
	local _, f = self:Filters()
	local count = button == "RightButton" and 0 or f.count
	local changed
	if entry.recipe then
		changed = list:SetRecipe(entry.recipe.profId, entry.recipe.recipeId, count)
	elseif entry.itemID then
		changed = list:SetItem(entry.itemID, count)
	end
	if not changed then
		local B = Browse()
		if B then B:SetStatus(count == 0 and "That is not on the list." or "No change: the list already wants that many.") end
	end
end

--- GSL-MERGE-001 step 7 (D6): the Browse row a Shopping List row orders from -- the bank character
--- holding the most of `itemID` that can be asked for it. Browse:BuildRows is the one source, so a
--- sister guild's bank character counts exactly as it does on the Browse tab. A view-only bank and a
--- hidden row (only ever the player's own) are skipped here; every other refusal (ordering closed,
--- not for sale, the request limit) stays with Browse:OnBrowseRowClick and the dialog.
---@param itemID number
---@return table|nil row
function UICL:OrderSource(itemID)
	local B = Browse()
	if not (B and itemID) then return nil end
	local best
	for _, r in ipairs(B:BuildRows()) do
		local n = tonumber(r.Count) or 0
		if r.ID == itemID and not r.viewOnly and not r.Hidden and n > 0 and (not best or n > (tonumber(best.Count) or 0)) then
			best = r
		end
	end
	return best
end

--- A left click on a Shopping List row (either view) opens the request dialog for its item, through
--- the Browse tab's own click, on OrderSource's bank character. Shift/Ctrl-click links or previews.
function UICL:OnListRowClick(entry, button)
	if not entry or button == "RightButton" then return end
	if TOGBankClassic_UI:HandleLinkClick(entry.link) then return end
	local B = Browse()
	local itemID = entry.itemID or (entry.entry and entry.entry.itemID)
	local name = entry.plainName or "that"
	if not itemID then
		-- An enchant makes no item, so there is nothing a bank character could hold of it.
		if B then B:SetStatus(string.format("%s makes no item, so there is nothing to order.", name)) end
		return
	end
	local row = self:OrderSource(itemID)
	if not row then
		if B then B:SetStatus(string.format("No bank character has %s to order.", name)) end
		return
	end
	B:OnBrowseRowClick(row, "LeftButton")
end

--- The "?" text for our two tabs.
function UICL:AddHelpLines(value)
	GameTooltip:AddLine("Shopping List — How It Works")
	GameTooltip:AddLine(" ")
	if value == UICL.SETUP_TAB.value then
		GameTooltip:AddLine("Set up what the guild wants. Type in the search box to find a recipe (from ProfessionDB) or an item (from ItemDB); pick a profession to narrow the recipes (items are always searched). |cffffd100Left-click|r a row to put it on the list at the |cffffd100How many|r count, or to change the count of something already on it; |cffffd100right-click|r takes it off.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("The box at the top is what is on the list now: |cffffd100-|r and |cffffd100+|r change a count, the red |cffffd100x|r takes it off, and a click on a crafted item shows the reagents it takes.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Gather from|r and |cffffd100Gather until|r set the dates the guild is gathering for; everyone sees them on the Shopping List tab.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("This tab shows for the guild master, officers, and a member with [GSL] in their public note. Changes go to the whole guild.", 0.7, 0.7, 0.7, true)
	else
		GameTooltip:AddLine("What the guild wants crafted or gathered. |cffffd100In bank|r is how many your guild's bank characters already hold, and |cffffd100Still needed|r is the rest.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Click the |cffffd100+|r in front of a crafted item to see the reagents the rest of it takes. The list underneath is every reagent the whole list takes: how many are |cffffd100Needed|r, how many the |cffffd100Bank|r holds, how many are in your bags (|cffffd100You|r) and what is still |cffffd100Missing|r -- what the guild still has to send.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Send items to|r names the guild's shopping-list character (the one with [GSL] in their public note): mail what you gather or craft for the list to them.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Click|r a row to request that item from the bank character holding the most of it, as a click on the Browse tab does.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("The status line shows the gather dates when an officer has set them. Mouse over a row for the item's tooltip; click a column header to sort.", 0.9, 0.9, 0.9, true)
	end
end
