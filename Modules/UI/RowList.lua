-- Modules/UI/RowList.lua -- the data-row list the Browse window is built on.
--
-- BROWSE-001. The operator: "i'd like to follow the look and feel of FGI, with the zebra stripped
-- rows, it'll make it easier to see. the same font size/style. I did a really good job with the
-- FGI UX." So this is FastGuildInvite's GUI/RowList.lua, ported and trimmed -- the same visual
-- contract, taken from that file rather than reinvented:
--
--   * 16 px rows; every second row banded SetColorTexture(1, 1, 1, 0.04).
--   * a 20 px header bar at 8 % white with a 1 px gold rule under it; GameFontNormalSmall headers,
--     GameFontHighlightSmall cells; a click on a header sorts, the Calendar MoreArrow shows the
--     direction (V-flipped for ascending), exactly as FGI does it.
--   * one auto-width column (the one with no `width`), fixed columns chained left and right of it
--     with 4 px gaps and 6 px edge padding, a 22 px scrollbar gutter reserved so rows never shift.
--   * virtual scrolling: a pool of row frames sized to the parent's height, grown on demand; a
--     plain Slider with Blizzard's scrollbar art (UIPanelScrollBarTemplate calls
--     SetVerticalScroll on its parent and crashes on a plain frame -- FGI found that), mouse wheel
--     drives it; the bar hides when everything fits.
--
-- Trimmed: FGI's class colouring, locale re-fonting, expander / checkbox / button cells and its
-- Brand helper have no use here. Added: an `icon` cell kind (a texture, for the item icon), a
-- mouse button on `onRowClick` (the banker's right-click hide, HIDE-001) and `onRowEnter` /
-- `onRowLeave` for the item tooltip. Candidate for LibAceGUIWidgets once a second addon wants it;
-- raised as such, not moved from here (the library is authored from its own session).
--
-- Column spec: { key, header, width|nil, justify = "LEFT"|"RIGHT"|"CENTER", icon = true,
--   sortable = false, font = "<font object name>", format = function(value) -> text,
--   build = function(rowFrame) -> frame }.
-- Entry rows are plain tables keyed by column key; a column's sort value may be overridden with
-- `entry["_sort_" .. key]` (numbers sort numerically, everything else case-insensitively).
--
-- REQUESTS-ROWLIST-001: two additions for the Requests tab, which FGI's expander/button cells
-- covered and the first port trimmed. A column with `build` owns its cell: the function is called
-- once per pooled row with the row frame and returns the frame this list anchors into the column
-- (a glowing date, a copyable item, a strip of action icons); the list never writes to it -- the
-- owner paints it from `onRowRender(entry, rowFrame)`, called after the plain cells of a row are
-- set, with `rowFrame.cells[key]` holding the built frame. `onSortChanged(key, desc)` fires after a
-- header click has changed the sort, so an owner that rebuilds its body can put the sort back.

TOGBankClassic_UI_RowList = {}
local RowList = TOGBankClassic_UI_RowList
RowList.__index = RowList

RowList.ROW_HEIGHT       = 16
RowList.HEADER_HEIGHT    = 20
RowList.LEFT_PAD         = 6
RowList.COL_GAP          = 4
RowList.SCROLLBAR_WIDTH  = 16
RowList.SCROLLBAR_GUTTER = 16 + 6
RowList.SCROLLBAR_BTN    = 32
RowList.BAND_ALPHA       = 0.04
RowList.HEADER_ALPHA     = 0.08
RowList.HEADER_COLOR     = "ffffd100"   -- the addon's gold, where FGI uses its orange brand

--- Build a list anchored to `parent`; rows stretch to the parent's width. Dot-called, like FGI's:
--- the receiver is the class table and is not read.
---@param parent table a frame whose height decides how many rows show
---@param opts table { columns, rowHeight, onRowClick(entry, idx, button), onRowEnter(entry, rowFrame), onRowLeave(entry), onRowRender(entry, rowFrame), onSortChanged(key, desc) }
function RowList.New(_, parent, opts)
	opts = opts or {}
	local self = setmetatable({}, RowList)
	self.parent     = parent
	self.rowHeight  = opts.rowHeight or RowList.ROW_HEIGHT
	self.columns    = opts.columns or {}
	self.onRowClick = opts.onRowClick
	self.onRowEnter = opts.onRowEnter
	self.onRowLeave = opts.onRowLeave
	self.onRowRender    = opts.onRowRender
	self.onSortChanged  = opts.onSortChanged
	self.data, self.listOffset, self.rows, self.visibleRowCount = {}, 0, {}, 0

	self.hasHeader = false
	for _, col in ipairs(self.columns) do
		if col.header then self.hasHeader = true break end
	end
	self.headerHeight = self.hasHeader and RowList.HEADER_HEIGHT or 0
	if self.hasHeader then self:_buildHeader() end

	self:_buildScrollbar()

	parent:HookScript("OnSizeChanged", function() self:Refresh() end)
	parent:EnableMouseWheel(true)
	parent:HookScript("OnMouseWheel", function(_, delta)
		if #self.data == 0 then return end
		local _, maxOffset = self.scrollbar:GetMinMaxValues()
		if maxOffset <= 0 then return end
		self.scrollbar:SetValue(math.max(0, math.min(maxOffset, self.scrollbar:GetValue() - delta)))
	end)
	return self
end

--- The index of the one auto-width column, or nil.
function RowList:_autoIndex()
	for ci, col in ipairs(self.columns) do
		if not col.width then return ci end
	end
	return nil
end

--- Walk the columns in placement order, calling `place(col, anchor)` where anchor is
--- { leftOffset = n } (left chain), { rightOffset = n } (right chain, rightmost first) or both
--- (the auto column). The header and every row share this so their columns cannot drift apart.
function RowList:_placeColumns(place)
	local autoIdx = self:_autoIndex()
	local leftOffset = RowList.LEFT_PAD
	if autoIdx then
		for ci = 1, autoIdx - 1 do
			local col = self.columns[ci]
			place(col, { leftOffset = leftOffset })
			leftOffset = leftOffset + col.width + RowList.COL_GAP
		end
	end
	local rightOffset = RowList.COL_GAP
	for ci = #self.columns, (autoIdx and autoIdx + 1 or 1), -1 do
		local col = self.columns[ci]
		if col.width then
			place(col, { rightOffset = rightOffset })
			rightOffset = rightOffset + col.width + RowList.COL_GAP
		end
	end
	if autoIdx then
		place(self.columns[autoIdx], { leftOffset = leftOffset, rightOffset = rightOffset })
	end
end

local function anchorCell(widget, parent, col, anchor)
	if anchor.leftOffset and anchor.rightOffset then
		widget:SetPoint("LEFT",  parent, "LEFT",  anchor.leftOffset, 0)
		widget:SetPoint("RIGHT", parent, "RIGHT", -anchor.rightOffset, 0)
	elseif anchor.leftOffset then
		widget:SetWidth(col.width)
		widget:SetPoint("LEFT", parent, "LEFT", anchor.leftOffset, 0)
	else
		widget:SetWidth(col.width)
		widget:SetPoint("RIGHT", parent, "RIGHT", -anchor.rightOffset, 0)
	end
end

function RowList:_buildHeader()
	local h = CreateFrame("Frame", nil, self.parent)
	h:SetHeight(RowList.HEADER_HEIGHT)
	h:SetPoint("TOPLEFT",  self.parent, "TOPLEFT",  0, 0)
	h:SetPoint("TOPRIGHT", self.parent, "TOPRIGHT", -RowList.SCROLLBAR_GUTTER, 0)
	local bg = h:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(h)
	bg:SetColorTexture(1, 1, 1, RowList.HEADER_ALPHA)
	local rule = h:CreateTexture(nil, "OVERLAY")
	rule:SetHeight(1)
	rule:SetPoint("BOTTOMLEFT",  h, "BOTTOMLEFT",  0, 0)
	rule:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", 0, 0)
	rule:SetColorTexture(1, 0.82, 0, 0.4)

	self.headerCells = {}
	self:_placeColumns(function(col, anchor)
		local btn = CreateFrame("Button", nil, h)
		btn:EnableMouse(true)
		btn:SetHeight(RowList.HEADER_HEIGHT)
		anchorCell(btn, h, col, anchor)
		local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetAllPoints(btn)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		fs:SetMaxLines(1)
		local arrow = btn:CreateTexture(nil, "OVERLAY")
		arrow:SetTexture("Interface\\Calendar\\MoreArrow")
		arrow:SetSize(15, 11)
		arrow:Hide()
		self.headerCells[col.key] = { btn = btn, fs = fs, arrow = arrow, col = col }
		if col.header and col.sortable ~= false then
			btn:SetScript("OnClick", function()
				if self.sortKey == col.key then
					self.sortDesc = not self.sortDesc
				else
					self.sortKey, self.sortDesc = col.key, false
				end
				self._sorted = nil
				self:_updateHeaders()
				self:Refresh()
				if self.onSortChanged then self.onSortChanged(self.sortKey, self.sortDesc) end
			end)
		end
		if col.headerTip and TOGBankClassic_UI and TOGBankClassic_UI.AttachTooltip then
			TOGBankClassic_UI:AttachTooltip(btn, "ANCHOR_TOP", col.header, { col.headerTip })
		end
	end)
	self:_updateHeaders()
	self.header = h
end

function RowList:_updateHeaders()
	if not self.headerCells then return end
	for _, cell in pairs(self.headerCells) do
		cell.fs:SetText("|c" .. RowList.HEADER_COLOR .. (cell.col.header or "") .. "|r")
		if self.sortKey == cell.col.key then
			if self.sortDesc then
				cell.arrow:SetTexCoord(0.0, 0.9375, 0.0, 0.6875)
			else
				cell.arrow:SetTexCoord(0.0, 0.9375, 0.6875, 0.0)
			end
			cell.arrow:ClearAllPoints()
			cell.arrow:SetPoint("LEFT", cell.btn, "LEFT", (cell.fs:GetStringWidth() or 0) + 3, 0)
			cell.arrow:Show()
		else
			cell.arrow:Hide()
		end
	end
end

function RowList:_buildScrollbar()
	local parent = self.parent
	local sb = CreateFrame("Slider", nil, parent)
	sb:SetOrientation("VERTICAL")
	sb:SetPoint("TOPRIGHT",    parent, "TOPRIGHT",    -1, -(self.headerHeight + RowList.SCROLLBAR_BTN))
	sb:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -1, RowList.SCROLLBAR_BTN)
	sb:SetWidth(RowList.SCROLLBAR_WIDTH)
	sb:SetMinMaxValues(0, 0)
	sb:SetValueStep(1)
	sb:SetValue(0)
	local bg = sb:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(sb)
	bg:SetColorTexture(0, 0, 0, 0.4)

	local up = CreateFrame("Button", nil, sb)
	up:SetPoint("BOTTOM", sb, "TOP", 0, 0)
	up:SetSize(RowList.SCROLLBAR_BTN, RowList.SCROLLBAR_BTN)
	up:SetNormalTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up")
	up:SetPushedTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down")
	up:SetDisabledTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Disabled")
	up:SetHighlightTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Highlight", "ADD")
	up:SetScript("OnClick", function() sb:SetValue(sb:GetValue() - 1) end)

	local down = CreateFrame("Button", nil, sb)
	down:SetPoint("TOP", sb, "BOTTOM", 0, 0)
	down:SetSize(RowList.SCROLLBAR_BTN, RowList.SCROLLBAR_BTN)
	down:SetNormalTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
	down:SetPushedTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down")
	down:SetDisabledTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Disabled")
	down:SetHighlightTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Highlight", "ADD")
	down:SetScript("OnClick", function() sb:SetValue(sb:GetValue() + 1) end)

	local thumb = sb:CreateTexture(nil, "ARTWORK")
	thumb:SetSize(RowList.SCROLLBAR_WIDTH, 24)
	thumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
	sb:SetThumbTexture(thumb)

	sb:SetScript("OnValueChanged", function(_, val)
		local offset = math.floor(val + 0.5)
		if offset == self.listOffset then return end
		self.listOffset = offset
		self:_renderRows()
	end)
	sb:Hide()
	self.scrollbar = sb
end

function RowList:_buildRow(i)
	local row = CreateFrame("Button", nil, self.parent)
	row:SetHeight(self.rowHeight)
	local y = -(self.headerHeight + (i - 1) * self.rowHeight)
	row:SetPoint("TOPLEFT",  self.parent, "TOPLEFT",  0, y)
	row:SetPoint("TOPRIGHT", self.parent, "TOPRIGHT", -RowList.SCROLLBAR_GUTTER, y)
	if i % 2 == 0 then
		local band = row:CreateTexture(nil, "BACKGROUND")
		band:SetAllPoints(row)
		band:SetColorTexture(1, 1, 1, RowList.BAND_ALPHA)
	end
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	local cells = {}
	self:_placeColumns(function(col, anchor)
		if col.build then
			local f = col.build(row)
			f:SetHeight(self.rowHeight)
			anchorCell(f, row, col, anchor)
			cells[col.key] = f
		elseif col.icon then
			local tex = row:CreateTexture(nil, "ARTWORK")
			tex:SetSize(self.rowHeight - 2, self.rowHeight - 2)
			anchorCell(tex, row, col, anchor)
			cells[col.key] = tex
		else
			local fs = row:CreateFontString(nil, "OVERLAY", col.font or "GameFontHighlightSmall")
			fs:SetHeight(self.rowHeight)
			fs:SetJustifyH(col.justify or "LEFT")
			fs:SetWordWrap(false)
			fs:SetMaxLines(1)
			anchorCell(fs, row, col, anchor)
			cells[col.key] = fs
		end
	end)
	row.cells = cells

	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetScript("OnClick", function(_, button)
		local entry = self:_sortedData()[self.listOffset + i]
		if entry and self.onRowClick then self.onRowClick(entry, self.listOffset + i, button) end
	end)
	row:SetScript("OnEnter", function(frame)
		local entry = self:_sortedData()[self.listOffset + i]
		if entry and self.onRowEnter then self.onRowEnter(entry, frame) end
	end)
	row:SetScript("OnLeave", function()
		local entry = self:_sortedData()[self.listOffset + i]
		if self.onRowLeave then self.onRowLeave(entry) end
	end)
	row:Hide()
	return row
end

--- The data in the current sort order; cached until the data or the sort changes.
function RowList:_sortedData()
	if not self.sortKey then return self.data end
	if self._sorted then return self._sorted end
	local sorted = {}
	for i, e in ipairs(self.data) do sorted[i] = e end
	local key, desc = self.sortKey, self.sortDesc
	local sortKey = "_sort_" .. key
	table.sort(sorted, function(a, b)
		local av, bv = a[sortKey], b[sortKey]
		if av == nil then av = a[key] end
		if bv == nil then bv = b[key] end
		if av == nil and bv == nil then return false end
		if av == nil then return not desc end
		if bv == nil then return desc end
		if type(av) == "number" and type(bv) == "number" then
			if av ~= bv then if desc then return av > bv else return av < bv end end
		else
			local al, bl = tostring(av):lower(), tostring(bv):lower()
			if al ~= bl then if desc then return al > bl else return al < bl end end
		end
		-- A stable tiebreak so equal keys do not swap between renders.
		local ai, bi = tostring(a._id or ""), tostring(b._id or "")
		return ai < bi
	end)
	self._sorted = sorted
	return sorted
end

--- Replace the rows. The view goes back to the top unless `preserveScroll`.
function RowList:SetData(data, preserveScroll)
	self.data = data or {}
	if preserveScroll then
		self.listOffset = math.min(self.listOffset, math.max(0, #self.data - self.visibleRowCount))
	else
		self.listOffset = 0
	end
	self._sorted = nil
	self:Refresh()
end

--- Set the sort without a header click (the initial order).
function RowList:SetSort(key, desc)
	self.sortKey, self.sortDesc, self._sorted = key, desc and true or false, nil
	self:_updateHeaders()
end

function RowList:_recomputeVisibleRows()
	local h = (self.parent:GetHeight() or 0) - self.headerHeight
	local need = math.max(0, math.floor(h / self.rowHeight))
	for i = #self.rows + 1, need do self.rows[i] = self:_buildRow(i) end
	self.visibleRowCount = need
end

function RowList:_renderRows()
	local data = self:_sortedData()
	for i, row in ipairs(self.rows) do
		local entry = i <= self.visibleRowCount and data[self.listOffset + i] or nil
		if entry then
			for _, col in ipairs(self.columns) do
				local cell = row.cells[col.key]
				local val = entry[col.key]
				-- A built cell is the owner's: painted by onRowRender below, never by this list.
				if col.icon then
					if val then cell:SetTexture(val) cell:Show() else cell:Hide() end
					-- HIDE-003: a greyed icon for a row the banker keeps from the guild (`_iconDesaturated`).
					if cell.SetDesaturated then cell:SetDesaturated(entry._iconDesaturated and true or false) end
				elseif not col.build then
					if val == nil then val = "" end
					if col.format then val = col.format(val, entry) end
					cell:SetText(tostring(val))
				end
			end
			if self.onRowRender then self.onRowRender(entry, row) end
			row:Show()
		else
			row:Hide()
		end
	end
end

--- Re-render from the current data and offset, recomputing the pool and the scrollbar range.
function RowList:Refresh()
	self:_recomputeVisibleRows()
	local maxOffset = math.max(0, #self.data - self.visibleRowCount)
	if self.listOffset > maxOffset then self.listOffset = maxOffset end
	local sb = self.scrollbar
	sb:SetMinMaxValues(0, maxOffset)
	sb:SetValue(self.listOffset)
	if maxOffset > 0 then sb:Show() else sb:Hide() end
	self:_renderRows()
end

function RowList:Show() self.parent:Show() end
function RowList:Hide() self.parent:Hide() end
