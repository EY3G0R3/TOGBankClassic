-- Modules/UI/Browse.lua -- the guild bank as ONE list, with the bankers as a column.
--
-- BROWSE-001. crimsonmane (Discord, 2026-09-07): "Browsing the guild bank tab-by-tab is only
-- meaningful if the character names reflect the type of items being held ... when just browsing
-- it's a wall of icons which carry very little meaning ... Maybe have filters on the left side and
-- results on the much larger right side, display items in their full-name across the line." The
-- operator: "he clearly doesn't like the 'here is a list of bankers' as the view ... make it look
-- more like the FGI's scan tab in layout? we have 'filter stuff' across the top, and rows of things
-- across the bottom, then a banker tab maybe to show the bankers/staleness status" -- and
-- "requests isn't a separate window, it's just another tab, makes the window a LOT cleaner".
--
-- So: one window, tabs across the top -- Browse | Bankers | Requests.
--   Browse:  the filter strip (the one search box, Bank, Type -> Subtype -> Slot, Quality, level
--            range, Usable by me) over sortable ROWS of every banker's stock: icon, name in quality
--            colour, quantity, banker (with the staleness dot the tab colour used to carry), type,
--            required level. Click a row = the request dialog; right-click on your own bank's rows
--            = hide/show (HIDE-001). Filters apply as they change -- nothing to submit.
--   Bankers: one row per banker -- online, status in words, when they last published, items,
--            money. Click one = Browse filtered to that bank.
--   Requests: the Requests body itself -- its tab strip, search, filters, rows and the bottom
--            icon cluster -- rendered INSIDE this tab (Requests:Embed). The first cut docked the
--            old window beside this one; the operator, on seeing it: "the requests still pops up
--            the window, and it's not inside the new UI".
--
-- BUILT IN PARALLEL: Inventory and Search are untouched. ENTRY-001 (2026-09-13): the MINIMAP
-- CLICK opens this and /togbank legacy opens the old Inventory window (swapped from the first
-- cut, at the operator's ask); a Browse button on the Inventory window opens this too. Nothing
-- here is a second implementation
-- of the data: every row comes from Guild:GetAltItems (the same store view every window reads),
-- the filter lists are Search's own (TOGBankClassic_UI_Search.Filters), the request dialog is
-- Search's, and the rows are TOGBankClassic_UI_RowList -- FGI's row list, ported.
--
-- The data half (BuildRows / FilterRows / BankerRows / the column specs) is plain functions over
-- the store so it is specced without a frame; the window half only renders what they return.

TOGBankClassic_UI_Browse = {}
local Browse = TOGBankClassic_UI_Browse

local FILTER_ANY   = "any"
-- The filter strip is a two-row TABLE of AceGUI widgets (five columns, bottom-aligned so the
-- boxes sit on one line whatever their labels do), inset from the tab's border -- the operator on
-- the Flow-laid first cut: "the stuff at the top needs to align vertically, and the search bar is
-- too close to the border". Two 44px rows plus the insets make the strip 100px; the row list
-- starts a further 12px down -- the operator, on the first cut: "the bottom row is too close to
-- the column header row, need to move it up a little".
local STRIP_H      = 100
local STRIP_GAP    = 12
local FILTER_H     = STRIP_H + STRIP_GAP
local FILTER_INSET = TOGBankClassic_UI.FILTER_INSET   -- shared with the Requests strip
-- BANKERS-FILTER-001 / LOG-FILTER-001 (operator 2026-09-13: "add some filters to the top of the
-- bankers tab like the browse tab ... at a minimum we need the search filter" and "the filter
-- search bar add it to the top of the logs as well ... filter by start/stop date, filter by from,
-- by to"): those two tabs carry a ONE-row strip of the same shape, and their lists start under it.
local SIMPLE_STRIP_H = 48
local SIMPLE_FILTER_H = SIMPLE_STRIP_H + STRIP_GAP
Browse.STRIP_H, Browse.FILTER_H, Browse.SIMPLE_FILTER_H = STRIP_H, FILTER_H, SIMPLE_FILTER_H
local MIN_WIDTH    = 760
local MIN_HEIGHT   = 380
-- BROWSE-006: the default size, here rather than as a SetWidth/SetHeight pair in DrawWindow,
-- because they are now the DEFAULTS of the saved status table -- AceGUI sizes the frame from that
-- table, so a hard SetWidth after it would overwrite the size the player chose.
local DEFAULT_WIDTH, DEFAULT_HEIGHT = 900, 540

--- BROWSE-007: THE FLOOR IS THE WIDEST TAB'S FLOOR. This window hosts the Requests body, whose
--- columns cannot lay out below their own minimum (Requests:MinWidth, 972 today); this window's
--- own number was 760 and its default 900, so a player could drag it -- or simply open it -- narrower
--- than the tab it was showing, and the column table ran past the border. The operator: "the window
--- can shrink smaller than the columns, and the column headers float outside the window." Read at
--- draw time, not load time: Requests is a later file in the TOC.
---@return number minWidth, number minHeight
local function resizeFloor()
	local R = TOGBankClassic_UI_Requests
	local w = MIN_WIDTH
	if R and R.MinWidth then w = math.max(w, R:MinWidth()) end
	return w, MIN_HEIGHT
end
Browse.ResizeFloor = resizeFloor

-- BROWSE-006: the tabs, declared ONCE. SetTabs renders this and RememberedTab validates against it,
-- so a tab cannot exist in one place and not the other -- a saved value naming a tab that no longer
-- exists (an older build's, or a future one rolled back) would otherwise select nothing and open the
-- window blank, which is indistinguishable from the addon being broken.
local TABS = {
	{ value = "browse",   text = "Browse" },
	{ value = "bankers",  text = "Bankers" },
	{ value = "requests", text = "Requests" },
	-- LOG-TAB-001: the bank log. The operator: "lets add a bank log tab, perfect thing to add to
	-- our new window". Appended rather than slotted, so the three tabs already in muscle memory
	-- keep their places.
	{ value = "log",      text = "Log" },
}
local DEFAULT_TAB = TABS[1].value
Browse.TABS = TABS
-- The help icon BREATHES until the first mouseover, then never again (remembered per account):
-- the operator, "i want to draw their attention to it, ONCE". BREATH-001: the breath is the
-- library's (LibAceGUIWidgets W:Breathe -- full to a third over a second, BOUNCE, eased), the same
-- call as the cancelled request's date glow and the status bar's urgent line.

-- Staleness in words, and the dot colour the tab used to be. Guild:GetAltStaleness states.
local STATE_TEXT = {
	current = "Current",
	behind  = "Behind",
	offered = "Update offered",
	refused = "Newer copy unreachable",   -- TAB-STATE-003
	v1      = "Old format",
	none    = "No data",
}
local STATE_COLOR = {
	current = "ff00ff00",
	behind  = "ffff0000",
	offered = "ffffff00",
	refused = "ffa0a0a0",   -- TAB-STATE-003: grey -- nothing is on its way
	v1      = "ffff0000",
	none    = "ff808080",
}
Browse.STATE_TEXT, Browse.STATE_COLOR = STATE_TEXT, STATE_COLOR

--- TAB-STATE-003: the one sentence for the grey state, read by the Bankers row hover here and the
--- Inventory window's tab tooltip, so the two cannot describe it differently.
---@param peer string|nil
---@param version string|nil
---@return string
function Browse.RefusedText(peer, version)
	return string.format("A newer copy of this bank is held by %s on %s, which cannot send it to this release. Nothing is on its way until they update or a current client holds it.",
		tostring(peer or "a guildmate"), version and TOGBankClassic_Constants.VersionText(version) or "an older version")
end

-- Store's numeric equipId -> the INVTYPE token Search's slot map keys on. Store.INVTYPE_TO_ID is
-- the same table the other way round; inverted once here rather than kept twice.
local ID_TO_INVTYPE
--- The item's INVTYPE token, from the Info's own equipSlot or the store's numeric equipId.
local function equipLocFor(info)
	if not info then return nil end
	if info.equipSlot then return info.equipSlot end
	if not ID_TO_INVTYPE then
		ID_TO_INVTYPE = {}
		local Store = TOGBankClassic_Inventory_Store
		for token, id in pairs(Store and Store.INVTYPE_TO_ID or {}) do ID_TO_INVTYPE[id] = token end
	end
	return ID_TO_INVTYPE[info.equipId]
end

local function slotKeyFor(info)
	local Search = TOGBankClassic_UI_Search
	local F = Search and Search.Filters
	if not (F and info) then return nil end
	local loc = equipLocFor(info)
	return loc and F.INVTYPE_TO_SLOT[loc] or nil
end

--- "Weapon / Sword (1H)", "Trade Goods", "Armor / Cloth" -- the type column, from Search's lists.
function Browse:TypeText(info)
	local F = TOGBankClassic_UI_Search and TOGBankClassic_UI_Search.Filters
	if not (F and info) then return "" end
	local class = info.class ~= nil and tostring(info.class) or nil
	local typeName = class and F.TYPE_LIST[class] or nil
	if not typeName then return "" end
	local subs = F.SUBCLASS_LISTS[class]
	local subName = subs and info.subClass ~= nil and subs.list[tostring(info.subClass)] or nil
	-- "Consumable / Consumable" and "Reagent / Reagent" say nothing twice.
	if subName and subName ~= typeName and subName ~= "Any" then return typeName .. " / " .. subName end
	return typeName
end

-- ─── Data ──────────────────────────────────────────────────────────────────────

--- Every banker's stock as flat rows. One row per (banker, item variant); the same rows the
--- Inventory tabs and Search draw, read through the same accessor.
---@return table rows
function Browse:BuildRows()
	local G = TOGBankClassic_Guild
	local rows = {}
	if not (G and G.Info) then return rows end
	local roster = G:GetRosterAlts() or {}
	table.sort(roster)
	for _, player in ipairs(roster) do
		local norm = G:NormalizeName(player)
		local state = G:GetAltStaleness(norm)
		local viewOnly = G.IsViewOnlyBank and G:IsViewOnlyBank(norm) or false
		-- HIDE-003: the banker's OWN hidden rows ride along here exactly as on the Inventory window's
		-- own tab, greyed with the red badge, so a right-click hide has a row to right-click back.
		-- The first cut read the visible view only: the operator, on the Guild Bank window, "right
		-- click on an item it 'just went away'. i don't see it and i can't unselect it". Only the
		-- banker's own bank; HIDDEN-MERGE-001 put that rule in Guild:GetAltItemsWithOwnHidden, the
		-- one site both windows read. GetAltItems never carries these rows, and no viewer sees them.
		local items = G:GetAltItemsWithOwnHidden(norm) or {}
		for _, item in ipairs(items) do
			if type(item) == "table" and item.ID then
				local info = item.Info or {}
				local name = info.name or ("Item " .. tostring(item.ID))
				local quality = tonumber(info.rarity) or 1
				local r, g, b = 1, 1, 1
				if GetItemQualityColor then r, g, b = GetItemQualityColor(quality) end
				local typeText = self:TypeText(info)
				local nameText = string.format("|cff%02x%02x%02x%s|r", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), name)
				if item.Hidden then
					-- Grey, with the same badge the Inventory window's own tab uses (ReadyCheck-NotReady).
					nameText = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:12:12:0:0|t |cff808080" .. name .. "|r"
				end
				rows[#rows + 1] = {
					-- What the request dialog and HIDE-001 need, in the shape they already take.
					ID = item.ID, Count = item.Count or 0, Suffix = item.Suffix, Enchant = item.Enchant,
					Link = item.Link, Info = info, Hidden = item.Hidden,
					-- The row's columns.
					icon  = info.icon,
					_iconDesaturated = item.Hidden and true or nil,
					name  = nameText,
					count = item.Count or 0,
					bank  = string.format("|c%s\226\128\162|r %s", STATE_COLOR[state] or STATE_COLOR.none, player)
						.. (viewOnly and " |cff808080(view)|r" or ""),
					type  = typeText,
					level = tonumber(info.reqLevel) or 0,
					-- Sort on the plain values, not the colour-coded display text.
					_sort_name = name:lower(), _sort_bank = player:lower(), _sort_level = tonumber(info.reqLevel) or 0,
					_id = tostring(item.ID) .. ":" .. tostring(item.Suffix or 0) .. ":" .. tostring(item.Enchant or 0) .. "@" .. norm,
					-- Filter inputs.
					plainName = name, player = player, norm = norm, state = state, viewOnly = viewOnly,
					class = info.class, subClass = info.subClass, quality = quality,
					slot = slotKeyFor(info), equipLoc = equipLocFor(info), reqLevel = tonumber(info.reqLevel) or 0,
				}
			end
		end
	end
	return rows
end

---@class BrowseFilters
---@field text string|nil       the search box; every word must appear across name, banker and type
---@field bank string           a banker's Name-Realm, or "any"
---@field type string           Search's TYPE_LIST key, or "any"
---@field subtype string        Search's SUBCLASS_LISTS key, or "any"
---@field slot string           Search's SLOT_LIST key, or "any"
---@field quality string        Search's QUALITY_LIST key, or "any"
---@field minLevel number|nil   required level at least (0 / nil = no floor)
---@field maxLevel number|nil   required level at most (0 / nil = no ceiling)
---@field usable boolean|nil    only what this character can use (Modules/Usable.lua)

-- USABLE BY ME. The first cut compared the required level alone, which at level 60 filters nothing;
-- the second scanned the item tooltip for red lines and still let a hunter see maces -- the
-- operator: "you may want to use some of what dibs did for the filtering". So the answer is
-- DATA, Dibs' gate ported to Modules/Usable.lua: level, LibItemDB's class obtainability, the
-- armour / shield / weapon proficiency tables, the tooltip's Classes: / Races: tags.
---@return boolean
function Browse:IsUsable(row, player)
	local U = TOGBankClassic_Usable
	if not U then return true end
	return U.CanUse(row, player)
end

--- The rows that pass every filter in `f`. Never mutates `rows`.
---@param f BrowseFilters|nil
function Browse:FilterRows(rows, f)
	f = f or {}
	local trimmed = f.text and f.text:gsub("^%s+", ""):gsub("%s+$", "") or ""
	local q = trimmed ~= "" and trimmed or nil
	local minL, maxL = tonumber(f.minLevel) or 0, tonumber(f.maxLevel) or 0
	-- The character once per pass, not once per row.
	local player = f.usable and TOGBankClassic_Usable and TOGBankClassic_Usable.Player() or nil
	local out = {}
	for _, r in ipairs(rows) do
		local ok = true
		if f.bank and f.bank ~= FILTER_ANY and r.norm ~= f.bank then ok = false end
		if ok and f.type and f.type ~= FILTER_ANY and tostring(r.class) ~= f.type then ok = false end
		if ok and f.subtype and f.subtype ~= FILTER_ANY and tostring(r.subClass) ~= f.subtype then ok = false end
		if ok and f.slot and f.slot ~= FILTER_ANY and r.slot ~= f.slot then ok = false end
		if ok and f.quality and f.quality ~= FILTER_ANY and tostring(r.quality) ~= f.quality then ok = false end
		if ok and minL > 0 and r.reqLevel < minL then ok = false end
		if ok and maxL > 0 and r.reqLevel > maxL then ok = false end
		if ok and q and not TOGBankClassic_UI:SearchMatch(q, r.plainName, r.player, r.type) then ok = false end
		-- Last: the only filter that may touch a tooltip, so the cheap ones narrow the set first.
		if ok and f.usable and not self:IsUsable(r, player) then ok = false end
		if ok then out[#out + 1] = r end
	end
	return out
end

--- The filters as they start: everything, nothing narrowed.
function Browse:DefaultFilters()
	return { bank = FILTER_ANY, type = FILTER_ANY, subtype = FILTER_ANY, slot = FILTER_ANY, quality = FILTER_ANY }
end

--- Is any filter narrowing the list?
function Browse:FiltersActive(f)
	f = f or self.filters or {}
	for _, key in ipairs({ "bank", "type", "subtype", "slot", "quality" }) do
		if f[key] and f[key] ~= FILTER_ANY then return true end
	end
	if f.text and f.text:gsub("^%s+", ""):gsub("%s+$", "") ~= "" then return true end
	if (tonumber(f.minLevel) or 0) > 0 or (tonumber(f.maxLevel) or 0) > 0 then return true end
	return f.usable and true or false
end

--- The Clear button: every filter back to its start, the strip rebuilt to show it, the list redrawn.
function Browse:ClearFilters()
	self.filters = self:DefaultFilters()
	if self.isOpen and self.currentTab == "browse" and self.TabGroup then
		self:ShowTab("browse")
	end
end

--- One row per banker: what the tab strip's colours were saying, in words.
function Browse:BankerRows()
	local G, Store = TOGBankClassic_Guild, TOGBankClassic_Inventory_Store
	local rows = {}
	if not (G and G.Info) then return rows end
	local guild = G.Info.name
	local roster = G:GetRosterAlts() or {}
	table.sort(roster)
	for _, player in ipairs(roster) do
		local norm = G:NormalizeName(player)
		local state, heldAt, _, statePeer, stateVersion = G:GetAltStaleness(norm)
		local online = G.IsPlayerOnline and G:IsPlayerOnline(norm) or false
		local items = #(G:GetAltItems(norm) or {})
		local money = Store and guild and Store:GetAltMoney(guild, norm) or 0
		local viewOnly = G.IsViewOnlyBank and G:IsViewOnlyBank(norm) or false
		local publishedText = (heldAt and heldAt > 0) and self:Ago(heldAt) or "never"
		-- BANKERS-FILTER-001: what the banker stores, from the guild note beside its gbank marker.
		local stores = G.BankerStores and G:BankerStores(norm) or ""
		rows[#rows + 1] = {
			name = player .. (viewOnly and " |cff808080(view only)|r" or ""),
			stores = stores,
			online = online and "|cff00ff00yes|r" or "|cff808080no|r",
			status = "|c" .. (STATE_COLOR[state] or STATE_COLOR.none) .. (STATE_TEXT[state] or state) .. "|r",
			published = publishedText,
			items = items,
			money = self:Money(money),
			_sort_name = player:lower(), _sort_stores = stores:lower(), _sort_online = online and 1 or 0,
			_sort_status = STATE_TEXT[state] or state, _sort_published = heldAt or 0, _sort_money = money,
			_id = norm,
			norm = norm, player = player, state = state, heldAt = heldAt or 0, moneyCopper = money, viewOnly = viewOnly,
			plainStatus = STATE_TEXT[state] or state,
			refusedPeer = state == "refused" and statePeer or nil, refusedVersion = state == "refused" and stateVersion or nil,
		}
	end
	return rows
end

--- BANKERS-FILTER-001: the Bankers rows whose name, Stores text or status contain every word of
--- `text` (the addon's one search rule, SearchMatch). Empty text keeps every row.
function Browse:FilterBankerRows(rows, text)
	local q = text and text:match("^%s*(.-)%s*$") or ""
	if q == "" then return rows end
	local out = {}
	for _, r in ipairs(rows) do
		if TOGBankClassic_UI:SearchMatch(q, r.player, r.stores, r.plainStatus) then out[#out + 1] = r end
	end
	return out
end

--- LOG-FILTER-001 / LOG-FILTER-002: what a Since/Until filter holds, as a timestamp at the START of
--- its day, or nil for no limit. With the library's date picker (LOG-FILTER-002) the filter holds
--- the widget's own value -- a local-midnight timestamp -- and passes through. A typed date (the
--- picker's own field, or the plain edit box a library without the widget falls back to) is parsed
--- by the LIBRARY's rule, `DatePicker.parse` -- one spelling of "what is a date" for every addon on
--- it -- which reads YYYY-MM-DD with `-`, `/` or `.`, and accepts-and-drops a trailing HH:MM, since
--- the filter is by DAY. The rule below it is only for a library too old to carry the parser.
---@param value number|string|nil
---@return number|nil ts
function Browse:ParseDate(value)
	if type(value) == "number" then return value end
	if type(value) ~= "string" then return nil end
	local W = TOGBankClassic_UI.Widgets
	local DP = W and W.DatePicker
	if DP and DP.parse then return (DP.parse(value)) end
	local y, m, d = value:match("^%s*(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s*%d?%d?:?%d?%d?%s*$")
	if not y then return nil end
	return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0, min = 0, sec = 0 })
end

--- LOG-FILTER-001: the log rows that pass every set filter -- `text` (every word somewhere in the
--- from, action, item or to), `since` / `until` (the day's start / the day's end, inclusive). Unset
--- filters keep every row.
---
--- LOG-FILTER-004 (the operator, 2026-09-13, with the From list forty names long: "the from and
--- to filters on the log tab are going to be too unweildly. as long as the name is searchable and
--- filters through the search bar, we can probably get rid of these two dropdown filters"): the
--- From / To name dropdowns are gone, with their LogNames / FillLogNameDropdown machinery. The
--- search box already matched both names; typing one is the filter now.
---@param rows table LogRows' shape
---@param f table { text=, since=, ["until"]= }
function Browse:FilterLogRows(rows, f)
	f = f or {}
	local q = f.text and f.text:match("^%s*(.-)%s*$") or ""
	local since, untilDay = self:ParseDate(f.since), self:ParseDate(f["until"])
	local untilTs = untilDay and (untilDay + 86400 - 1) or nil
	local out = {}
	for _, r in ipairs(rows) do
		local e = r.entry or {}
		local ts = tonumber(r._sort_when) or 0
		local ok = true
		if since and ts < since then ok = false end
		if ok and untilTs and ts > untilTs then ok = false end
		if ok and q ~= "" and not TOGBankClassic_UI:SearchMatch(q, r.from, r.to, tostring(e.item or ""), r.plainAction) then ok = false end
		if ok then out[#out + 1] = r end
	end
	return out
end

-- LOG-TAB-001: how each log entry type reads as a row. `verb` is the Action column; `who` and
-- `with` name which entry field is the actor and which the other party (Log.lua's entry shapes:
-- bank movements carry name=banker and to/from=member; request events carry name=requester or
-- banker and to=the other). Colour follows the in-game guild bank log's reading: a deposit is
-- good news, a withdrawal is stock leaving, a cancellation is red like the Requests list's.
local LOG_VERBS = {
	["deposit"]        = { verb = "deposited",   colour = "ff40c040", with = "from" },
	["withdraw"]       = { verb = "withdrew",    colour = "ffff9900", with = "to" },
	["money-deposit"]  = { verb = "deposited",   colour = "ff40c040", with = "from", money = true },
	["money-withdraw"] = { verb = "withdrew",    colour = "ffff9900", with = "to",   money = true },
	["requested"]      = { verb = "requested",   colour = "ffffd100", with = "to" },
	["mailed"]         = { verb = "mailed",      colour = "ffffffff", with = "to" },
	["handed"]         = { verb = "handed over", colour = "ffffffff", with = "to" },
	["cancelled"]      = { verb = "cancelled",   colour = "ffff4444", with = "to" },
	["reopened"]       = { verb = "reopened",    colour = "ffffd100", with = "to" },
}

local function shortName(full)
	return (tostring(full or ""):match("^([^-]+)") or tostring(full or ""))
end

--- One row per log entry, newest first. The log is the RECENT buffer (Log.lua LOG-PERSIST-001: the
--- last MAX_ENTRIES per guild, saved; TOGTools keeps the history), so this tab is "recent", and its
--- status line says how many rather than letting an empty list read as "nothing ever happened".
function Browse:LogRows()
	local Log = TOGBankClassic_Log
	local rows = {}
	if not (Log and Log.GetEntries) then return rows end
	for _, e in ipairs(Log:GetEntries()) do
		local spec = LOG_VERBS[e.type] or { verb = tostring(e.type), colour = "ffffffff", with = "to" }
		local other = e[spec.with]
		local link = (not spec.money and e.itemID) and Log.ItemLinkFor and Log:ItemLinkFor(e.itemID, e.suffixID, e.item) or nil
		local itemText
		if spec.money then
			itemText = self:Money(e.money)
		else
			itemText = link or tostring(e.item or "")
		end
		-- LOG-TAB-002: From and To, as the columns say. A deposit came FROM the member (when known)
		-- TO the bank character; everything else goes FROM the actor (`name`) TO the other party.
		local fromName, toName
		if spec.with == "from" then fromName, toName = other, e.name else fromName, toName = e.name, other end
		rows[#rows + 1] = {
			when   = self:Ago(e.ts),
			from   = fromName and shortName(fromName) or "",
			action = "|c" .. spec.colour .. spec.verb .. "|r",
			item   = itemText,
			count  = (not spec.money and e.count and e.count > 0) and e.count or "",
			to     = toName and shortName(toName) or "",
			_sort_when = e.ts or 0, _sort_from = tostring(fromName or ""):lower(), _sort_action = spec.verb,
			_sort_item = tostring(e.item or ""):lower(), _sort_count = e.count or 0, _sort_to = tostring(toName or ""):lower(),
			_id = tostring(e.ts) .. "|" .. tostring(e.type) .. "|" .. tostring(e.requestId or e.itemID or e.name),
			entry = e, link = link,
			-- LOG-FILTER-001: the full names and the plain verb, for the filters.
			fromFull = fromName, toFull = toName, plainAction = spec.verb,
		}
	end
	return rows
end

--- "just now", "3m ago", "2h ago", "5d ago". Its own arithmetic rather than SecondsToTime: that
--- global is FrameXML, absent offline, and its "1 Hr 2 Min" is wider than a 110px column wants.
function Browse:Ago(at)
	local diff = (GetServerTime() or 0) - (tonumber(at) or 0)
	if diff < 60 then return "just now" end
	if diff < 3600 then return math.floor(diff / 60) .. "m ago" end
	if diff < 86400 then return math.floor(diff / 3600) .. "h ago" end
	return math.floor(diff / 86400) .. "d ago"
end

--- Copper as the game's coin string when the API is there, else "12g 34s".
function Browse:Money(copper)
	copper = tonumber(copper) or 0
	local fmt = C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString
	if fmt then return fmt(copper) end
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	if g > 0 then return string.format("%dg %ds", g, s) end
	if s > 0 then return string.format("%ds %dc", s, c) end
	return c .. "c"
end

-- ─── Column specs ──────────────────────────────────────────────────────────────

Browse.BROWSE_COLUMNS = {
	{ key = "icon",  header = "",       width = 16, icon = true, sortable = false },
	-- A hidden row is not in this list at all (the accessor excludes it), so "show it again" is the
	-- greyed row on your own tab of the main window, not here.
	{ key = "name",  header = "Item",   headerTip = "The item. Click a row to request it. On your own bank, right-click hides it from the guild (show it again from your tab on the main window)." },
	{ key = "count", header = "Qty",    width = 44,  justify = "RIGHT", headerTip = "How many that banker holds." },
	{ key = "bank",  header = "Banker", width = 130, headerTip = "Which bank character holds it. The dot is that bank's status: green current, red behind or old format, yellow an update on its way." },
	{ key = "type",  header = "Type",   width = 150, headerTip = "The item's type and subtype." },
	{ key = "level", header = "Lvl",    width = 34,  justify = "RIGHT", format = function(v) return v and v > 0 and tostring(v) or "" end, headerTip = "Required level to use." },
}

Browse.BANKER_COLUMNS = {
	{ key = "name",      header = "Banker",    width = 150, headerTip = "Click to browse just this bank." },
	-- BANKERS-FILTER-001: the auto column, so a long description gets the room the window has.
	{ key = "stores",    header = "Stores",    headerTip = "What this bank keeps, as written in its guild note beside the gbank marker (an officer edits the note to change it)." },
	{ key = "online",    header = "Online",    width = 48 },
	{ key = "status",    header = "Status",    width = 100, headerTip = "Current: your copy is the newest published. Behind: a newer copy exists and is being fetched. Old format: not published on this version yet. No data: nothing held." },
	{ key = "published", header = "Published", width = 110, headerTip = "When this bank's contents were last published." },
	{ key = "items",     header = "Items",     width = 44,  justify = "RIGHT" },
	{ key = "money",     header = "Money",     width = 110, justify = "RIGHT" },
}

-- LOG-TAB-001: the in-game guild bank log's shape -- who did what, to which item, how many, with
-- whom, when -- as sortable columns rather than one sentence, so a banker can sort by item or by
-- member. Newest first by default.
-- LOG-TAB-002, the operator's first look: "the who column is the from column, and it should say as
-- much"; "not sure why the column is labeled with. this is the recipient"; "the quantity isn't
-- centered under the column header ... it merges into the with column" (a RIGHT-justified number
-- against a LEFT-justified neighbour; the header is left-justified, so the cell is now too).
Browse.LOG_COLUMNS = {
	{ key = "when",   header = "When",   width = 80,  headerTip = "When it happened, as the bank character's client recorded it." },
	{ key = "from",   header = "From",   width = 110, headerTip = "Who it came from: the bank character for a withdrawal or a mailed order, the member who mailed it in for a deposit, the requester for a request." },
	{ key = "action", header = "Action", width = 90 },
	{ key = "item",   header = "Item",   headerTip = "The item, as its link. Mouse over for the item's tooltip." },
	{ key = "count",  header = "Qty",    width = 44 },
	{ key = "to",     header = "To",     width = 130, headerTip = "Who received it: the requester for a mailed or handed order, the bank character for a deposit or a request." },
}

-- ─── Window ────────────────────────────────────────────────────────────────────

function Browse:Init()
	-- Frame creation deferred to first Open() (PERF-015, as every other window).
	---@type BrowseFilters
	self.filters = self.filters or self:DefaultFilters()
end

local function OnClose(_)
	Browse.isOpen = false
	-- The Requests body, if it is on our tab, lets go of its widgets (they stay ours, hidden with
	-- the window); its bottom icons and settings overlay on our frame are hidden.
	if TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.Detach then TOGBankClassic_UI_Requests:Detach() end
	if Browse.Window then Browse.Window:Hide() end
end

--- Has this account hovered the help icon ON THIS TAB before? The breath is a one-time
--- attention-getter -- PER TAB (HELP-PULSE-002). The operator: "each i on each tab has different
--- info. the 'breath' effect has to be on, for each one, until it's moused over. right now mousing
--- over one, fills the stop breath effect for them all." One flag for the window was the first cut;
--- `helpSeen.browse` is now a table keyed by tab. A `true` left by that first cut (an account that
--- hovered it today) reads as the Browse tab seen and the other two not -- their text is different
--- and has not been read.
---@param tab string|nil defaults to the current tab
---@return boolean
function Browse:HelpSeen(tab)
	tab = tab or self.currentTab or DEFAULT_TAB
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	local seen = db and db.global and db.global.helpSeen and db.global.helpSeen.browse
	if seen == true then return tab == "browse" end
	return type(seen) == "table" and seen[tab] == true or false
end

---@param tab string|nil defaults to the current tab
function Browse:MarkHelpSeen(tab)
	tab = tab or self.currentTab or DEFAULT_TAB
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	if not (db and db.global) then return end
	db.global.helpSeen = db.global.helpSeen or {}
	local seen = db.global.helpSeen.browse
	if type(seen) ~= "table" then
		seen = { browse = seen == true or nil }   -- the first cut's boolean, migrated
		db.global.helpSeen.browse = seen
	end
	seen[tab] = true
end

--- Play or stop the breath for the tab now showing. Called on every tab change (RememberTab) and
--- when the icon is (re)built, so a tab whose help has not been read breathes the moment it is
--- shown, and one that has does not.
function Browse:SyncHelpPulse()
	local icon, W = self.HelpIcon, TOGBankClassic_UI.Widgets
	if not (icon and W and W.Breathe) then return end
	if self:HelpSeen() then
		self:StopHelpPulse()
	else
		W:Breathe(icon)
	end
end

--- The "?" icon's text, for whichever tab is showing.
function Browse:AddHelpLines()
	local tab = self.currentTab
	if tab == "requests" and TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.AddHelpLines then
		TOGBankClassic_UI_Requests:AddHelpLines()
		return
	end
	GameTooltip:AddLine("Guild Bank — How It Works")
	GameTooltip:AddLine(" ")
	if tab == "log" then
		GameTooltip:AddLine("What has moved in and out of the guild bank recently, newest first: deposits and withdrawals as each bank character publishes a rescan, and every request as it is placed, mailed, handed over, cancelled or reopened. |cffffd100From|r and |cffffd100To|r name the two parties when the bank character's client knew them. Mouse over an item for its tooltip; a cancelled request shows its reason. Click a column header to sort.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Filters across the top:|r the search box (every word must appear in the row -- a name finds that person's entries on either side, or type an item or an action), and |cffffd100Since|r / |cffffd100Until|r as YYYY-MM-DD or from the calendar. They apply as you change them.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(string.format("Only the most recent %d entries are kept here, not the full history. Bank characters using TOGTools keep the long history there.", TOGBankClassic_Log and TOGBankClassic_Log.MAX_ENTRIES or 0), 0.7, 0.7, 0.7, true)
	elseif tab == "bankers" then
		GameTooltip:AddLine("One row per bank character. |cffffd100Stores|r is what that bank keeps, as written in its guild note beside the gbank marker (an officer edits the note to change it -- \"gbank herbs, potions\"). |cffffd100Status|r is whether your copy of that bank is the newest published: green Current, red Behind (a newer copy exists and is on its way), Old format (that banker has not published on this version yet), grey No data. |cffffd100Published|r is when its contents were last published. The search box matches the name, what it stores and the status. Click a row to browse just that bank.", 0.9, 0.9, 0.9, true)
	else
		-- HELP-TEXT-001: the main window's "How It Works" lives on here -- the operator: "it's
		-- imparitive this tooltip lives on somewhere in the new main UI". What it is, how to donate,
		-- how to request, how a banker hides -- the same four things, said for this window.
		GameTooltip:AddLine("This window shows the combined inventory of every guild bank character -- real in-game characters run by guild members -- including what is waiting in their mail. Every banker's stock is one list; use the search box and the filters across the top to narrow it (they apply as you change them, and |cffffd100Clear|r puts them all back), and click a column header to sort by it.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100To donate items:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Mail them with in-game mail directly to the bank character you want to contribute to -- the Bankers tab lists them. They show up here once that banker next logs in and publishes.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100To request an item:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Click its row and submit the request. A banker fulfils it when they are next online and see your request; watch the Requests tab.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Banker column:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Which bank character holds the item. The dot is that bank's status: green current, red behind or old format, yellow an update on its way. (view) marks a bank you can look at but not request from.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Usable by me:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Hides anything your character cannot use -- too high a level, or the wrong class, race, armour or weapon type (what the item's tooltip shows in red).", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Bankers -- to hide an item from the guild:|r", 1, 1, 1, false)
		GameTooltip:AddLine("Right-click one of your own bank's rows to hide it. It stays in your list greyed out with a red mark; to everyone else it is as if you do not have it. Right-click it again to show it.", 0.9, 0.9, 0.9, true)
	end
	-- HELPNOTE-001: the officers' note for the main window applies here -- same bank, one note.
	TOGBankClassic_UI:AppendGuildHelpNote("inventory")
end

--- The bottom row: the help "?" left of Close and the gear left of that, the status bar ending at
--- the gear, the hitbox lift -- the shared chrome (WINDOW-CHROME-001, UI:DressWindow). What is
--- this window's: the per-tab help text (AddHelpLines) and the "?" BREATHING (the request glow's
--- pulse) until the tab's help is first moused over, then never again on this account.
function Browse:DressChrome()
	local chrome = TOGBankClassic_UI:DressWindow(self.Window, {
		settings = Browse,
		onHelpEnter = function()
			Browse:StopHelpPulse()
			Browse:MarkHelpSeen()
		end,
		help = function() Browse:AddHelpLines() end,
	})
	self.HelpIcon, self.SettingsIcon = chrome.help, chrome.settings
	self:SyncHelpPulse()
	return chrome
end

function Browse:StopHelpPulse()
	local icon, W = self.HelpIcon, TOGBankClassic_UI.Widgets
	if icon and W and W.StopBreathing then W:StopBreathing(icon) end   -- Stop + alpha 1: a stopped BOUNCE holds wherever it was
end

--- The leftmost of this window's own bottom-row icons -- what the status bar's right edge meets,
--- and what the Requests cluster hangs left of while it is on this window.
function Browse:BottomAnchor()
	return self.Window and self.Window.togChrome and self.Window.togChrome.anchor
end

--- The status bar's right edge meets the gear again (Requests extends it further left while its
--- cluster is on this window: Requests:ShowCluster, and hands it back on leaving the tab).
function Browse:AnchorStatusBar()
	TOGBankClassic_UI:AnchorStatusBar(self.Window)
end

--- BROWSE-006: the tab this character was last on, per character and validated.
---
--- Validated against TABS rather than trusted, because the saved value outlives the build that
--- wrote it: a tab removed in a later version, or a name from a build the player has rolled back
--- from, would otherwise be handed to SelectTab, match nothing, and open the window on a blank body
--- -- which reads as the addon being broken rather than as a stale preference.
---@return string
function Browse:RememberedTab()
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	local saved = db and db.char and db.char.browseTab
	for _, entry in ipairs(TABS) do
		if entry.value == saved then return saved end
	end
	return self.currentTab or DEFAULT_TAB
end

--- Record the tab for next time. Per character, beside the window position, for the same reason
--- that is per character: it is part of how this particular alt has the window arranged.
---@param value string
function Browse:RememberTab(value)
	self.currentTab = value
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	if db and db.char then db.char.browseTab = value end
	self:SyncHelpPulse()   -- HELP-PULSE-002: the breath is per tab
end

function Browse:Open(tab)
	if not self.Window then self:DrawWindow() end
	self.isOpen = true
	self.Window:Show()
	self.TabGroup:SelectTab(tab or self:RememberedTab())
	if _G["TOGBankClassic"] then _G["TOGBankClassic"]:Show() end
end

function Browse:Close()
	if not self.isOpen then return end
	OnClose(self.Window)
end

function Browse:Toggle()
	if self.isOpen then self:Close() else self:Open() end
end

--- Repaint whatever tab is showing from the store (called when data lands; debounced by callers).
function Browse:Refresh()
	if not self.isOpen then return end
	if self.currentTab == "browse" then self:DrawBrowse()
	elseif self.currentTab == "bankers" then self:DrawBankers()
	elseif self.currentTab == "log" then self:DrawLog() end
end

function Browse:DrawWindow()
	self:Init()
	local window = TOGBankClassic_UI:Create("Frame")
	window:Hide()
	window:SetTitle(TOGBankClassic_UI:WindowTitle("Guild Bank"))
	window:SetLayout("Fill")
	window:SetCallback("OnClose", OnClose)
	-- BROWSE-006: position AND size persist, per character, exactly as the Inventory, Search and
	-- Requests windows already do -- this window was the only one that did not, so it reopened at
	-- 900x540 in the middle of the screen every single time. AceGUI writes `top`/`left`/`width`/
	-- `height` into this table on every drag and resize and reads them back through ApplyStatus, so
	-- there is nothing to save by hand. SetStatusTable APPLIES the table, which is why the hard
	-- SetWidth/SetHeight pair that used to sit here is gone: it would have run after this and put
	-- the window back to the default size on every open.
	-- BROWSE-007: the floor governs the DEFAULT and the SAVED size as well as the drag. Resize
	-- bounds only stop the sizer; a status table saved narrower than the floor (from before the floor
	-- was raised, or from a smaller UI scale) is applied by AceGUI as-is, and the default of 900 was
	-- itself below the Requests floor -- so the window opened too narrow with nothing to drag.
	-- WINDOW-PERSIST-002: that rule is now UI:PersistWindow's (the library's), the one spelling every
	-- window uses -- it fills a missing size from the defaults, raises a saved size to the floor,
	-- applies the table and sets the bounds; without a db (a spec) it applies the defaults.
	local minW, minH = resizeFloor()
	TOGBankClassic_UI:PersistWindow(window, "browse", DEFAULT_WIDTH, DEFAULT_HEIGHT, minW, minH)
	self.Window = window
	TOGBankClassic_UI:ApplyThinBorder(window, "browse")
	self.StatusBar = TOGBankClassic_UI_StatusBar:AttachSides(window)
	self:DressChrome()

	local tabs = TOGBankClassic_UI:Create("TabGroup")
	tabs:SetLayout("Fill")
	-- The window's Fill layout sizes the tab group; it must NOT then shrink itself to its content
	-- when a Flow layout finishes (AceGUI's TabGroup does, by default). With the Requests body on
	-- the tab that auto-height grew the body past the window -- the operator: "the 'stuff' isn't
	-- fitting into the request tab page" -- and on the Browse tab it would leave the body the
	-- filter strip's height.
	tabs:SetAutoAdjustHeight(false)
	tabs:SetTabs(TABS)
	tabs:SetCallback("OnGroupSelected", function(_, _, value) self:ShowTab(value) end)
	window:AddChild(tabs)
	self.TabGroup = tabs

	-- The two row lists live on plain frames anchored inside the tab body, under the AceGUI
	-- filter strip; shown and hidden per tab rather than rebuilt.
	local body = tabs.content
	local browseList = CreateFrame("Frame", nil, body)
	browseList:SetPoint("TOPLEFT",     body, "TOPLEFT",     0, -FILTER_H)
	browseList:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
	self.BrowseList = TOGBankClassic_UI_RowList:New(browseList, {
		columns = self.BROWSE_COLUMNS,
		onRowClick = function(entry, _, button) self:OnBrowseRowClick(entry, button) end,
		onRowEnter = function(entry) self:OnBrowseRowEnter(entry) end,
		onRowLeave = function() TOGBankClassic_UI:HideTooltip() end,
	})
	self.BrowseList:SetSort("name", false)
	browseList:Hide()

	-- BANKERS-FILTER-001 / LOG-FILTER-001: both lists hang under their one-row strip.
	local bankerList = CreateFrame("Frame", nil, body)
	bankerList:SetPoint("TOPLEFT",     body, "TOPLEFT",     0, -SIMPLE_FILTER_H)
	bankerList:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
	self.BankerList = TOGBankClassic_UI_RowList:New(bankerList, {
		columns = self.BANKER_COLUMNS,
		onRowClick = function(entry) self:BrowseBank(entry.norm) end,
		-- TAB-STATE-003: the grey state needs its sentence; the others say what they are.
		onRowEnter = function(entry)
			if entry.state ~= "refused" then return end
			GameTooltip:SetOwner(WorldFrame, "ANCHOR_CURSOR")
			GameTooltip:SetText(Browse.RefusedText(entry.refusedPeer, entry.refusedVersion), 1, 1, 1, 1, true)
			GameTooltip:Show()
		end,
		onRowLeave = function() TOGBankClassic_UI:HideTooltip() end,
	})
	self.BankerList:SetSort("name", false)
	bankerList:Hide()

	-- LOG-TAB-001: the bank log, newest first, an item tooltip on hover.
	local logList = CreateFrame("Frame", nil, body)
	logList:SetPoint("TOPLEFT",     body, "TOPLEFT",     0, -SIMPLE_FILTER_H)
	logList:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
	self.LogList = TOGBankClassic_UI_RowList:New(logList, {
		columns = self.LOG_COLUMNS,
		onRowEnter = function(entry)
			if entry.link then
				TOGBankClassic_UI:ShowItemTooltip(entry.link)
			elseif entry.entry and entry.entry.note then
				GameTooltip:SetOwner(WorldFrame, "ANCHOR_CURSOR")
				GameTooltip:SetText("Reason: " .. tostring(entry.entry.note), 1, 1, 1, 1, true)
				GameTooltip:Show()
			end
		end,
		onRowLeave = function() TOGBankClassic_UI:HideTooltip() end,
	})
	self.LogList:SetSort("when", true)
	logList:Hide()
	-- New entries repaint the tab while it is showing. Registered once, on the module (the owner
	-- key), so a rebuilt window does not stack a second callback. The log coalesces and delivers
	-- on a timer, so nothing click-gated runs here -- a repaint is all.
	if TOGBankClassic_Log and TOGBankClassic_Log.RegisterCallback then
		TOGBankClassic_Log:RegisterCallback(Browse, function()
			if Browse.isOpen and Browse.currentTab == "log" then Browse:DrawLog() end
		end)
	end
end

function Browse:ShowTab(value)
	local Requests = TOGBankClassic_UI_Requests
	-- AceGUI's SelectTab fires OnGroupSelected whether or not the tab was already selected, and
	-- Open() selects the current tab, so re-selecting Requests while its body is still on this tab
	-- group (Peer Review F4) would tear the body down and rebuild it, snapping the list to page 1.
	-- "Still embedded" is the test, not the tab name: after Close the body is detached but the
	-- widgets are still the tab group's children, and that case must rebuild.
	-- BROWSE-006: BOTH assignments go through RememberTab, this early return included. It is the
	-- path taken when Requests is already on screen and the tab is re-selected -- which is exactly
	-- what Open() does -- so persisting only in the branch below would fail to remember the Requests
	-- tab in the one case the player is most likely to be in when they log out.
	if value == "requests" and Requests and Requests.embedded and Requests.Host == self.TabGroup then
		self:RememberTab(value)
		return
	end
	self:RememberTab(value)
	-- The Requests body forgets its widgets BEFORE the tab group releases them.
	if Requests and Requests.Detach then Requests:Detach() end
	self.TabGroup:ReleaseChildren()
	self.FilterWidgets = nil
	self.BrowseList:Hide()
	self.BankerList:Hide()
	if self.LogList then self.LogList:Hide() end
	self:AnchorStatusBar()
	if value == "browse" then
		self:BuildFilterStrip()
		self.BrowseList:Show()
		self:DrawBrowse()
	elseif value == "bankers" then
		self:BuildBankerStrip()
		self.BankerList:Show()
		self:DrawBankers()
	elseif value == "log" then
		self:BuildLogStrip()
		self.LogList:Show()
		self:DrawLog()
	elseif value == "requests" then
		-- The Requests body renders IN this tab: its widgets become the tab group's children, its
		-- icon cluster sits on our bottom row left of our gear, its messages take our status bar.
		if Requests and Requests.Embed then
			Requests:Embed(self.TabGroup, self.Window, self:BottomAnchor())
		end
	end
end

--- Browse, narrowed to one bank (the Bankers tab's row click).
function Browse:BrowseBank(norm)
	self.filters.bank = norm or FILTER_ANY
	self.TabGroup:SelectTab("browse")
end

--- The filter strip: a two-row, five-column TABLE of AceGUI widgets above the row list, on a group
--- inset from the tab's border. Cells are bottom-aligned, so the search box (no label), the
--- labelled dropdowns and edit boxes, the checkbox and the Clear button all sit on one line per
--- row whatever their heights -- Flow top-aligned them and the operator saw the stagger. Rebuilt
--- on every tab change (AceGUI releases the tab's children), so every control re-reads self.filters.
function Browse:BuildFilterStrip()
	local F = TOGBankClassic_UI_Search.Filters
	local f = self.filters ---@type BrowseFilters
	-- One column per first-row widget; the second row's narrower widgets start at the same left
	-- edges, which is the vertical alignment the operator asked for. The strip's shape is
	-- BuildSimpleStrip's (self-audit 9bce8d86 F3: this used to set the same group up by hand).
	local strip = self:BuildSimpleStrip({ 220, 150, 130, 140, 110 }, STRIP_H)
	self.FilterStrip = strip

	local search = TOGBankClassic_UI:Create("TOGBankSearchBox")
	search:SetPlaceholder("Search items, bankers, types")
	search:SetMaxLetters(50)
	search:SetWidth(220)
	if f.text and f.text ~= "" then search:SetText(f.text) end
	search:SetCallback("OnTextChanged", function(_, _, text)
		f.text = text
		self:DrawBrowse()
	end)
	strip:AddChild(search)

	local function dropdown(label, width, list, order, key, onChange)
		local dd = TOGBankClassic_UI:Create("Dropdown")
		dd:SetLabel(label)
		dd:SetWidth(width)
		dd:SetList(list, order)
		dd:SetValue(f[key] or FILTER_ANY)
		dd:SetCallback("OnValueChanged", function(_, _, value)
			f[key] = value
			if onChange then onChange(value) end
			self:DrawBrowse()
		end)
		strip:AddChild(dd)
		return dd
	end

	-- Bank: every banker on the roster, "Any" first.
	local bankList, bankOrder = { [FILTER_ANY] = "Any bank" }, { FILTER_ANY }
	local G = TOGBankClassic_Guild
	local roster = G and G:GetRosterAlts() or {}
	table.sort(roster)
	for _, player in ipairs(roster) do
		local norm = G:NormalizeName(player)
		bankList[norm] = player
		bankOrder[#bankOrder + 1] = norm
	end
	if not bankList[f.bank] then f.bank = FILTER_ANY end
	dropdown("Bank", 150, bankList, bankOrder, "bank")

	local subtypeDD, slotDD
	dropdown("Type", 130, F.TYPE_LIST, F.TYPE_ORDER, "type", function(value)
		f.subtype, f.slot = FILTER_ANY, FILTER_ANY
		local subs = F.SUBCLASS_LISTS[value]
		subtypeDD:SetList(subs and subs.list or { [FILTER_ANY] = "Any" }, subs and subs.order or { FILTER_ANY })
		subtypeDD:SetValue(FILTER_ANY)
		subtypeDD:SetDisabled(not subs)
		slotDD:SetValue(FILTER_ANY)
		slotDD:SetDisabled(value ~= "4")
	end)
	local subs = F.SUBCLASS_LISTS[f.type]
	subtypeDD = dropdown("Subtype", 140, subs and subs.list or { [FILTER_ANY] = "Any" }, subs and subs.order or { FILTER_ANY }, "subtype")
	subtypeDD:SetDisabled(not subs)
	slotDD = dropdown("Slot", 110, F.SLOT_LIST, F.SLOT_ORDER, "slot")
	slotDD:SetDisabled(f.type ~= "4")   -- armour only, as in Search

	dropdown("Quality", 110, F.QUALITY_LIST, F.QUALITY_ORDER, "quality")

	local function levelBox(label, key)
		local eb = TOGBankClassic_UI:Create("EditBox")
		eb:SetLabel(label)
		eb:SetWidth(60)
		eb:SetMaxLetters(2)
		eb:DisableButton(true)
		eb:SetText(f[key] and f[key] > 0 and tostring(f[key]) or "")
		eb:SetCallback("OnTextChanged", function(_, _, text)
			f[key] = tonumber(text) or 0
			self:DrawBrowse()
		end)
		strip:AddChild(eb)
	end
	levelBox("Min lvl", "minLevel")
	levelBox("Max lvl", "maxLevel")

	local usable = TOGBankClassic_UI:Create("CheckBox")
	usable:SetLabel("Usable by me")
	usable:SetWidth(120)
	usable:SetValue(f.usable and true or false)
	usable:SetCallback("OnValueChanged", function(_, _, value)
		f.usable = value and true or false
		self:DrawBrowse()
	end)
	TOGBankClassic_UI:AttachTooltip(usable, "ANCHOR_TOP", "Usable by me", {
		"Only what this character can use: level, class, race, armour and weapon type -- anything the item's tooltip would show in red is hidden.",
	})
	strip:AddChild(usable)

	-- The operator: "we also need a clear filters button on the browse page".
	local clear = TOGBankClassic_UI:Create("Button")
	clear:SetText("Clear")
	clear:SetWidth(90)
	clear:SetCallback("OnClick", function() self:ClearFilters() end)
	TOGBankClassic_UI:AttachTooltip(clear, "ANCHOR_TOP", "Clear filters", { "Empty the search box and put every filter back to Any." })
	strip:AddChild(clear)
	self.ClearButton = clear
end

--- The filter strip every Browse tab hangs its list under: a Table on a group inset FILTER_INSET,
--- bottom-aligned cells, at a FIXED height. The Browse tab's two-row strip (STRIP_H) and the
--- one-row strips of the Bankers and Log tabs (BANKERS-FILTER-001 / LOG-FILTER-001, SIMPLE_STRIP_H,
--- the default) are the same shape at different heights.
---@param columns table the column widths, one per control
---@param height number|nil the strip's height; SIMPLE_STRIP_H when nil
---@return table strip the AceGUI SimpleGroup
function Browse:BuildSimpleStrip(columns, height)
	local tabs = self.TabGroup
	tabs:SetLayout("Flow")
	local strip = TOGBankClassic_UI:Create("SimpleGroup")
	-- The row list is anchored a fixed distance below the body, so the strip keeps its height rather
	-- than taking whatever its layout measures -- and this is set BEFORE the height, because AceGUI
	-- lays a container out again whenever its content resizes, and a layout that finishes with no
	-- children yet would size the group to nothing.
	strip:SetAutoAdjustHeight(false)
	strip:SetFullWidth(true)
	strip:SetHeight(height or SIMPLE_STRIP_H)
	strip:SetLayout("Table")
	strip:SetUserData("table", { columns = columns, spaceH = 10, spaceV = 6, alignV = "end", alignH = "start" })
	if strip.content and strip.content.SetPoint then
		strip.content:ClearAllPoints()
		strip.content:SetPoint("TOPLEFT", FILTER_INSET, -4)
		strip.content:SetPoint("BOTTOMRIGHT", -FILTER_INSET, 0)
	end
	tabs:AddChild(strip)
	return strip
end

--- BANKERS-FILTER-001: the Bankers tab's strip -- the one search box, matching the banker's name,
--- what it stores (the guild note) and its status. Session-scoped, like the Browse filters.
function Browse:BuildBankerStrip()
	self.bankerFilter = self.bankerFilter or { text = "" }
	local f = self.bankerFilter
	local strip = self:BuildSimpleStrip({ 260 })
	self.BankerStrip = strip
	local search = TOGBankClassic_UI:Create("TOGBankSearchBox")
	search:SetPlaceholder("Search bankers, what they store")
	search:SetMaxLetters(50)
	search:SetWidth(260)
	if f.text and f.text ~= "" then search:SetText(f.text) end
	search:SetCallback("OnTextChanged", function(_, _, text)
		f.text = text
		self:DrawBankers()
	end)
	strip:AddChild(search)
	self.BankerSearch = search
end

--- LOG-FILTER-001: the Log tab's strip -- search, a Since and an Until date. (From / To dropdowns
--- until LOG-FILTER-004; the search box covers both names.)
function Browse:BuildLogStrip()
	self.logFilter = self.logFilter or { text = "" }
	local f = self.logFilter
	local strip = self:BuildSimpleStrip({ 260, 110, 110 })
	self.LogStrip = strip

	local search = TOGBankClassic_UI:Create("TOGBankSearchBox")
	search:SetPlaceholder("Search the log by name, item, action")
	search:SetMaxLetters(50)
	search:SetWidth(260)
	if f.text and f.text ~= "" then search:SetText(f.text) end
	search:SetCallback("OnTextChanged", function(_, _, text)
		f.text = text
		self:DrawLog()
	end)
	TOGBankClassic_UI:AttachTooltip(search, "ANCHOR_BOTTOM", "Search the log", {
		"Every word you type must appear somewhere in the row's From, Action, Item or To -- type a name to see one person's entries.",
	})
	strip:AddChild(search)
	self.LogSearch = search

	-- LOG-FILTER-002 (operator 2026-09-13, on the typed boxes: "we need the since and until to be
	-- date pickers"): the library's LAGW-DatePicker (LibAceGUIWidgets MINOR 28, built for this ask
	-- on inbox thread 3ecad6a6) -- a field that opens a month calendar, typing still accepted; its
	-- value is a local-midnight timestamp or nil, which is what the filter holds. A library too old
	-- to carry the widget gets the typed box it had, with text the filter parses (ParseDate).
	local hasPicker = TOGBankClassic_UI.GetWidgetVersion and TOGBankClassic_UI:GetWidgetVersion("LAGW-DatePicker") ~= nil
	local function dateBox(label, key, tip)
		local box
		if hasPicker then
			box = TOGBankClassic_UI:Create("LAGW-DatePicker")
			box:SetLabel(label)
			box:SetWidth(110)
			box:SetValue(type(f[key]) == "number" and f[key] or nil)
			box:SetCallback("OnValueChanged", function(_, _, ts)
				f[key] = ts
				self:DrawLog()
			end)
			-- LOG-FILTER-003 (operator 2026-09-13, screenshot: "they don't actually have a date picker
			-- dropdown"): the widget's calendar opened from its small arrow BUTTON only, and this
			-- tooltip said to click the field. The library now opens it from a click in the field as
			-- well (thread bb9c59be4d68, MINOR 28 unreleased); browse_spec drives that script.
			TOGBankClassic_UI:AttachTooltip(box, "ANCHOR_TOP", label, { tip, "Click the field or its arrow for a calendar, or type a date as YYYY-MM-DD. Clear it for no limit." })
		else
			box = TOGBankClassic_UI:Create("EditBox")
			box:SetLabel(label)
			box:SetWidth(110)
			box:SetMaxLetters(16)
			box:DisableButton(true)
			box:SetText(type(f[key]) == "string" and f[key] or "")
			box:SetCallback("OnTextChanged", function(_, _, text)
				f[key] = text or ""
				self:DrawLog()
			end)
			TOGBankClassic_UI:AttachTooltip(box, "ANCHOR_TOP", label, { tip, "Type a date as YYYY-MM-DD. Leave it empty for no limit." })
		end
		strip:AddChild(box)
		return box
	end
	self.LogSince = dateBox("Since", "since", "Only entries on or after this day.")
	self.LogUntil = dateBox("Until", "until", "Only entries on or before this day.")
end

--- The window's own status line (the left section of the shared bar). Remembered on the module
--- because AceGUI's Frame has no getter, and the specs read it.
function Browse:SetStatus(text)
	self.statusText = text
	if self.Window then self.Window:SetStatusText(text) end
end

function Browse:DrawBrowse()
	if not (self.isOpen and self.BrowseList) then return end
	local all = self:BuildRows()
	local rows = self:FilterRows(all, self.filters)
	self.rowsShown = rows
	self.BrowseList:SetData(rows, true)
	local banks = self:BankCount(all)
	self:SetStatus(#rows == #all
		and string.format("%d item%s across %d bank%s", #all, #all == 1 and "" or "s", banks, banks == 1 and "" or "s")
		or string.format("%d of %d items", #rows, #all))
end

function Browse:BankCount(rows)
	local seen, n = {}, 0
	for _, r in ipairs(rows) do
		if not seen[r.norm] then seen[r.norm] = true n = n + 1 end
	end
	return n
end

function Browse:DrawBankers()
	if not (self.isOpen and self.BankerList) then return end
	local all = self:BankerRows()
	local rows = self:FilterBankerRows(all, self.bankerFilter and self.bankerFilter.text)
	self.BankerList:SetData(rows, true)
	local current = 0
	for _, r in ipairs(rows) do if r.state == "current" then current = current + 1 end end
	if #rows < #all then
		self:SetStatus(string.format("%d of %d bankers match, %d current", #rows, #all, current))
	else
		self:SetStatus(string.format("%d banker%s, %d current", #rows, #rows == 1 and "" or "s", current))
	end
end

--- LOG-TAB-001 / LOG-PERSIST-001. The status line names the cap, because that is what the log
--- holds -- the most recent entries, not the history.
function Browse:DrawLog()
	if not (self.isOpen and self.LogList) then return end
	local all = self:LogRows()
	local rows = self:FilterLogRows(all, self.logFilter)
	self.LogList:SetData(rows, true)
	local cap = TOGBankClassic_Log and TOGBankClassic_Log.MAX_ENTRIES or 0
	if #all == 0 then
		self:SetStatus("No recent bank activity")
	elseif #rows < #all then
		self:SetStatus(string.format("%d of %d recent entries match", #rows, #all))
	else
		self:SetStatus(string.format("%d recent entr%s (the last %d are kept)", #rows, #rows == 1 and "y" or "ies", cap))
	end
end

--- A left click requests; a right click on your own bank's row hides or shows (HIDE-001).
function Browse:OnBrowseRowClick(entry, button)
	local G = TOGBankClassic_Guild
	if button == "RightButton" then
		if entry.norm == G:GetNormalizedPlayer() and G:IsBank(entry.norm) and TOGBankClassic_Bank.SetHidden then
			-- HIDE-002: a row the checkbox hid has no manual key to remove; say what governs it.
			local T = TOGBankClassic_UI.HIDDEN_TEXT   -- HIDDEN-TEXT-001: the same words the Inventory window says
			if entry.Hidden and TOGBankClassic_Bank:HiddenReason(entry.ID, entry.Suffix, entry.Enchant) == "soulbound" then
				TOGBankClassic_Output:Info(T.noticeSoulbound:format(entry.plainName))
				return
			end
			if TOGBankClassic_Bank:SetHidden(entry.ID, entry.Suffix, entry.Enchant, not entry.Hidden) then
				TOGBankClassic_Output:Info((not entry.Hidden and T.noticeHidden or T.noticeShown):format(entry.plainName))
				self:DrawBrowse()
			end
		end
		return
	end
	if IsShiftKeyDown and IsShiftKeyDown() and entry.Link then
		ChatEdit_InsertLink(entry.Link)
		return
	end
	if entry.viewOnly then
		self:SetStatus(entry.player .. " is a view-only bank -- its items cannot be requested.")
		return
	end
	-- LOG-HYGIENE-002 F3 (Peer Review db06c629): a HIDDEN row is on the list only for its owner
	-- to right-click back (HIDE-003); nobody else can see it, so a request for it is a request
	-- from yourself for a thing you hid. Say what the row is for instead of opening the dialog.
	if entry.Hidden then
		self:SetStatus(TOGBankClassic_UI.HIDDEN_TEXT.statusHidden:format(entry.plainName))
		return
	end
	TOGBankClassic_UI_Search:ShowRequestDialog(entry, entry.player)
end

function Browse:OnBrowseRowEnter(entry)
	if entry.Link then
		-- HIDE-003: on the banker's own rows the tooltip says what a right click does, as on the
		-- Inventory window's own tab; a hidden row says so first.
		local lines
		local G = TOGBankClassic_Guild
		if entry.norm == G:GetNormalizedPlayer() and G:IsBank(entry.norm) then
			-- HIDDEN-TEXT-001: the words are UI.HIDDEN_TEXT's, shared with the Inventory window.
			local why = entry.Hidden and TOGBankClassic_Bank and TOGBankClassic_Bank.HiddenReason
				and TOGBankClassic_Bank:HiddenReason(entry.ID, entry.Suffix, entry.Enchant) or nil
			lines = TOGBankClassic_UI:HiddenTooltipLines(entry.Hidden and true or false, why)
		end
		TOGBankClassic_UI:ShowItemTooltip(entry.Link, lines)
	elseif entry.plainName then
		GameTooltip:SetOwner(WorldFrame, "ANCHOR_CURSOR")
		GameTooltip:SetText(entry.plainName, 1, 1, 1)
		GameTooltip:Show()
	end
end
