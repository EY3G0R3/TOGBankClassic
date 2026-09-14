-- Modules/UI/Mailbox.lua
-- MAILUI-001: the inbox as INVENTORY. The operator, 2026-09-11: "the ability to open the mailbox,
-- see all the attachments on the mail and handle them like inventory. TSM does a good job of that,
-- providing rows for all the attachments to an email, and a search filter allowing you to narrow
-- it down. i was hoping we could reskin the inbox like how TSM does it."
--
-- MAILUI-002, the operator 2026-09-12: "i want this to look more like our browse ui in look and
-- feel, same zebra stripes, font, and one mail per row with however many items attached. i'd like
-- to be able to click into the mail to see everything attached to the one mail ... the filter needs
-- to update the rows and filter out the items so we only see the items on the rows that match the
-- filter. last, the item needs to show the icon, name, hover over full game tooltip and the
-- quantity." And: "we need some way to open this window. it pops open once the first time i open a
-- mailbox, but then i can't get to it again."
--
-- So: the window is a RowList (Modules/UI/RowList.lua -- the Browse window's zebra rows and font).
-- ONE ROW PER MAIL (sender, subject, how many attachments); a left-click on a mail expands it into
-- one indented row per attachment, each with the icon, the item's link, the count and the REAL
-- game tooltip (GameTooltip:SetInboxItem, the call MailFrame.xml:235 makes) on hover. The filter
-- narrows both: a mail shows if its sender or subject matches, or if one of its attachments does --
-- and an expanded mail shows only the matching attachments. The clicks are Blizzard's inbox's
-- (MAILCLICK-001/002, OnRowClick): left-click takes an attachment row, shift+left-click (or a
-- right-click on the mail) takes everything on the mail; Take Shown takes everything the filter
-- left, and Take Needed (MAILCOLLECT-001) takes what the open orders are short of -- the mailbox's
-- Fulfill-at-the-bank. It is reachable at any time the mailbox is open: the auto-open (bankers),
-- /togbank mailbox, and a "TOG Bank" button on the mail frame's title bar (beside TSM4's) for
-- everyone.
--
-- Blizzard's mail frame STAYS. This window opens beside it and closes with it. It never hides
-- MailFrame, never replaces the Send tab, and never takes a COD mail -- those stay Blizzard's.
--
-- The data half (BuildRows / BuildMails / FilterMails / ViewRows / the take sequencer) is plain
-- functions over the inbox API so it is specced without a frame; the window half only renders what
-- they return.

TOGBankClassic_UI_Mailbox = {}
local Mailbox = TOGBankClassic_UI_Mailbox

-- Blizzard's Open All waits this long between takes and then only proceeds once the client says no
-- command is pending (MailFrame.lua OPEN_ALL_MAIL_MIN_DELAY). Same here.
Mailbox.TAKE_DELAY = 0.15

-- The height of the search box + Take Shown strip the list hangs under (the AceGUI Flow row).
Mailbox.STRIP_H = 30

-- The coin icon a money-only mail shows in the icon column.
Mailbox.MONEY_ICON = 133784

-- ─── Data ─────────────────────────────────────────────────────────────────────

--- Every attachment in the inbox, one row each, plus one row per mail that carries money. Rows
--- are in mail order, attachment order. A COD mail's rows carry `cod` (copper) and are not
--- takeable from here; a GM mail is skipped entirely, as Blizzard's Open All skips it.
---@return table rows  array of { mailIndex, attachmentIndex|nil, itemID, name, link, icon, count,
---   quality, sender, subject, daysLeft, cod, money, needed }
function Mailbox:BuildRows()
	local rows = {}
	local numItems = GetInboxNumItems() or 0
	local wanted = self:WantedByOpenOrders()
	for i = 1, numItems do
		local _, _, sender, subject, money, cod, daysLeft, itemCount, _, _, _, _, isGM = GetInboxHeaderInfo(i)
		if sender and not isGM then
			cod = cod or 0
			if itemCount and itemCount > 0 then
				for j = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
					local name, itemID, icon, count, quality = GetInboxItem(i, j)
					if itemID then
						local link = GetInboxItemLink(i, j)
						rows[#rows + 1] = {
							mailIndex = i, attachmentIndex = j,
							itemID = itemID, name = name or ("Item " .. itemID), link = link, icon = icon,
							count = count or 1, quality = quality or 1,
							sender = sender, subject = subject or "", daysLeft = daysLeft or 0,
							cod = cod, needed = wanted[itemID] or false,
						}
					end
				end
			end
			if (money or 0) > 0 then
				rows[#rows + 1] = {
					mailIndex = i, attachmentIndex = nil,
					itemID = nil, name = "Money", link = nil, icon = Mailbox.MONEY_ICON, count = 1, quality = 1,
					sender = sender, subject = subject or "", daysLeft = daysLeft or 0,
					cod = cod, money = money, needed = false,
				}
			end
		end
	end
	return rows
end

--- MAILUI-002: the inbox as MAILS -- one entry per mail that carries something takeable, in inbox
--- order, each holding its attachment rows (BuildRows' shape, so the take sequencer and Take Shown
--- work on either view). A mail with neither an attachment nor money is not inventory and has no
--- entry; a mail's money rides as its last "attachment" (attachmentIndex nil), as BuildRows lists it.
---@return table mails  array of { mailIndex, sender, subject, daysLeft, cod, money|nil, attachments = { row, ... } }
function Mailbox:BuildMails()
	local mails, byIndex = {}, {}
	for _, row in ipairs(self:BuildRows()) do
		local m = byIndex[row.mailIndex]
		if not m then
			m = {
				mailIndex = row.mailIndex, sender = row.sender, subject = row.subject,
				daysLeft = row.daysLeft, cod = row.cod, attachments = {},
			}
			byIndex[row.mailIndex] = m
			mails[#mails + 1] = m
		end
		if row.money then m.money = row.money end
		m.attachments[#m.attachments + 1] = row
	end
	return mails
end

--- itemID -> true for every item an OPEN order addressed to this character still wants. What the
--- Requests window and ItemHighlight call "needed"; spelled here on the request record directly
--- because the mailbox is the one place a banker sees the item before it is in their bags.
function Mailbox:WantedByOpenOrders()
	local out = {}
	local G = TOGBankClassic_Guild
	local info = G and G.Info
	if not info or not info.requests then return out end
	local me = G:GetNormalizedPlayer()
	for _, req in pairs(info.requests) do
		if type(req) == "table" and req.itemID and req.status ~= "cancelled" and req.status ~= "complete"
				and (G:NormalizeName(req.bank) == me) then
			local qty, done = tonumber(req.quantity) or 0, tonumber(req.fulfilled) or 0
			if qty == 0 or done < qty then out[tonumber(req.itemID)] = true end
		end
	end
	return out
end

--- MAILCOLLECT-001 (operator 2026-09-13: "can you do the grabbing from the mail like we do with
--- the bank to fill orders? so we can grab items out of the 'mail bank' that we need?"): itemID ->
--- units the open orders to this character still need BEYOND what the bags hold. Same orders as
--- WantedByOpenOrders (open, mine, itemID known), summed; the bags are what BankCollectStep
--- measures its pulls against too. Bags are read through Bank:CountItemInBags when the module is
--- up; without it (a bare spec) the whole owed amount stands.
---@return table owed itemID -> units short
function Mailbox:OwedByOpenOrders()
	local owed = {}
	local G = TOGBankClassic_Guild
	local info = G and G.Info
	if not info or not info.requests then return owed end
	local me = G:GetNormalizedPlayer()
	local names = {}
	for _, req in pairs(info.requests) do
		if type(req) == "table" and req.itemID and req.status ~= "cancelled" and req.status ~= "complete"
				and (G:NormalizeName(req.bank) == me) then
			local qty, done = tonumber(req.quantity) or 0, tonumber(req.fulfilled) or 0
			if qty > done then
				local id = tonumber(req.itemID)
				owed[id] = (owed[id] or 0) + (qty - done)
				names[id] = names[id] or req.item
			end
		end
	end
	local Bank = TOGBankClassic_Bank
	if Bank and Bank.CountItemInBags then
		for id, units in pairs(owed) do
			local inBags = Bank:CountItemInBags(names[id], id) or 0
			owed[id] = math.max(0, units - inBags)
		end
	end
	return owed
end

--- MAILCOLLECT-001: the attachments to take so the bags cover the open orders -- oldest mail first
--- (the inbox lists newest first, so the walk runs from the end), COD mails skipped, and per item
--- only until the shortfall is covered: a mail stack cannot be split, so the LAST stack taken may
--- overshoot, but no stack is taken once the item is covered. Empty when nothing is short.
---@param mails table BuildMails' shape
---@return table rows the attachment rows to take, in the order chosen
function Mailbox:NeededAttachments(mails)
	local owed = self:OwedByOpenOrders()
	local out = {}
	for i = #mails, 1, -1 do
		local m = mails[i]
		if (m.cod or 0) == 0 then
			for _, a in ipairs(m.attachments) do
				local need = a.itemID and owed[a.itemID]
				if need and need > 0 then
					out[#out + 1] = a
					owed[a.itemID] = need - (a.count or 1)
				end
			end
		end
	end
	return out
end

--- The filter text as it is matched: lowercased, trimmed. "" means no filter.
local function normalise(text)
	return (tostring(text or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""))
end

local function contains(s, text)
	return (s or ""):lower():find(text, 1, true) ~= nil
end

--- The rows whose name or sender contains `text` (case-insensitive substring). Empty text keeps
--- every row. Never mutates `rows`.
function Mailbox:FilterRows(rows, text)
	text = normalise(text)
	if text == "" then return rows end
	local out = {}
	for _, r in ipairs(rows) do
		if contains(r.name, text) or contains(r.sender, text) then
			out[#out + 1] = r
		end
	end
	return out
end

--- MAILUI-002: the filter over MAILS. A mail whose sender or subject matches keeps every
--- attachment; otherwise it keeps only the attachments whose name matches, and drops out when none
--- do. Empty text keeps everything. Never mutates `mails` -- a kept mail is a copy with its own
--- attachment list, so a later redraw sees the full inbox again.
function Mailbox:FilterMails(mails, text)
	text = normalise(text)
	if text == "" then return mails end
	local out = {}
	for _, m in ipairs(mails) do
		local kept = {}
		if contains(m.sender, text) or contains(m.subject, text) then
			for i, a in ipairs(m.attachments) do kept[i] = a end
		else
			for _, a in ipairs(m.attachments) do
				if contains(a.name, text) then kept[#kept + 1] = a end
			end
		end
		if #kept > 0 then
			local copy = {}
			for k, v in pairs(m) do copy[k] = v end
			copy.attachments = kept
			out[#out + 1] = copy
		end
	end
	return out
end

--- The attachment rows of `mails`, flat, in order -- what Take Shown takes.
function Mailbox:AttachmentsOf(mails)
	local out = {}
	for _, m in ipairs(mails) do
		for _, a in ipairs(m.attachments) do out[#out + 1] = a end
	end
	return out
end

-- ─── Taking ───────────────────────────────────────────────────────────────────

--- Take one row now. Returns false, reason when it cannot (COD, full bags).
function Mailbox:TakeRow(row)
	if not row then return false, "nothing to take" end
	if (row.cod or 0) > 0 then return false, "cash-on-delivery mail is taken from the mail frame" end
	if row.attachmentIndex then
		if TOGBankClassic_Bank and TOGBankClassic_Bank.HasInventorySpace and not TOGBankClassic_Bank:HasInventorySpace() then
			return false, "bags are full"
		end
		TakeInboxItem(row.mailIndex, row.attachmentIndex)
	else
		TakeInboxMoney(row.mailIndex)
	end
	return true
end

--- The client is still processing the last take. Feature-detected: C_Mail.IsCommandPending is in
--- Era's generated docs, but a client (or the offline harness) without it must not error here.
local function commandPending()
	return C_Mail and C_Mail.IsCommandPending and C_Mail.IsCommandPending() or false
end

--- Take every row in `rows`, highest mail index first (a taken mail vanishes and renumbers those
--- above it; walking down keeps the untaken indices valid), pausing between takes until the
--- client has finished the last one. Stops on the first row that cannot be taken. `onDone(taken,
--- reason)` is called once at the end.
function Mailbox:TakeAll(rows, onDone)
	if self.taking then return false, "already taking" end
	local queue = {}
	for _, r in ipairs(rows) do queue[#queue + 1] = r end
	table.sort(queue, function(a, b)
		if a.mailIndex ~= b.mailIndex then return a.mailIndex > b.mailIndex end
		return (a.attachmentIndex or 0) > (b.attachmentIndex or 0)
	end)
	self.taking = { queue = queue, taken = 0, onDone = onDone }
	self:TakeNext()
	return true
end

function Mailbox:TakeNext()
	local t = self.taking
	if not t then return end
	local row = table.remove(t.queue, 1)
	if not row then
		self.taking = nil
		if t.onDone then t.onDone(t.taken) end
		return
	end
	local empties = self:TakeEmptiesMail(row)
	local ok, reason = self:TakeRow(row)
	if not ok then
		self.taking = nil
		if t.onDone then t.onDone(t.taken, reason) end
		return
	end
	t.taken = t.taken + 1
	if empties then self:ShiftExpanded(row.mailIndex) end
	local function proceed()
		if Mailbox.taking ~= t then return end
		if commandPending() then
			C_Timer.After(Mailbox.TAKE_DELAY, proceed)
		else
			Mailbox:TakeNext()
		end
	end
	C_Timer.After(self.TAKE_DELAY, proceed)
end

--- Abandon a take-all in progress (the mailbox closed).
function Mailbox:StopTaking()
	self.taking = nil
end

--- MAILUI-003 (Peer Review ccd04f5e): will taking `row` leave its mail with nothing takeable --
--- the last attachment of a mail with no money, or the money of a mail with no attachments? The
--- client deletes an emptied mail (MailFrame.lua's auto-delete on the last take) and renumbers
--- every mail above it, which is what the expansion set has to follow. Read from the inbox as it
--- stands BEFORE the take.
function Mailbox:TakeEmptiesMail(row)
	if not row then return false end
	local _, _, _, _, money, _, _, itemCount = GetInboxHeaderInfo(row.mailIndex)
	local takeables = (tonumber(itemCount) or 0) + (((tonumber(money) or 0) > 0) and 1 or 0)
	return takeables <= 1
end

--- The inbox renumbers by exactly one rule when mail `taken` vanishes: every mail above it moves
--- down one. The expansion set follows that rule, so an expanded mail stays expanded through a
--- take below it instead of the expansion landing on whichever mail inherited the index.
function Mailbox:ShiftExpanded(taken)
	local e = self.expanded
	if not e then return end
	e[taken] = nil
	local top = 0
	for i in pairs(e) do if i > top then top = i end end
	for i = taken + 1, top do
		e[i - 1] = e[i] or nil
		e[i] = nil
	end
end

-- ─── View rows ────────────────────────────────────────────────────────────────

-- MAILUI-002: the columns. NONE sortable -- a header sort would separate a mail's attachment rows
-- from the mail they hang under, and the inbox is already newest first.
-- MAILRETURN-001 (the operator, 2026-09-13: "can we add a return to sender option on this with a
-- mail icon to the right of the Left column?"): the `ret` column is a built cell -- a mail-icon
-- button on every MAIL row that returns the mail to its sender. Painted by OnRowRender, which
-- reads the entry off the row on every render (the RowList pools rows by position).
Mailbox.RETURN_ICON = "Interface\\Icons\\INV_Letter_15"   -- the envelope Fulfill Oldest uses
local function buildReturnCell(row)
	local cell = CreateFrame("Frame", nil, row)
	local btn = CreateFrame("Button", nil, cell)
	btn:SetSize(14, 14)
	btn:SetPoint("LEFT", cell, "LEFT", 2, 0)
	btn:SetNormalTexture(Mailbox.RETURN_ICON)
	btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	btn:SetScript("OnClick", function()
		local mail = cell.mail
		if mail then Mailbox:ReturnMail(mail) end
	end)
	btn:SetScript("OnEnter", function(f)
		local mail = cell.mail
		if not mail then return end
		GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
		GameTooltip:SetText("Return to " .. tostring(mail.sender or "sender"), 1, 1, 1)
		GameTooltip:AddLine("Sends this mail back with everything still on it.", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	cell.button = btn
	return cell
end

Mailbox.COLUMNS = {
	{ key = "icon",   header = "",            width = 16, icon = true, sortable = false },
	{ key = "name",   header = "Mail / Item", sortable = false },
	{ key = "count",  header = "Qty",         width = 44, justify = "RIGHT", sortable = false },
	{ key = "sender", header = "From",        width = 120, sortable = false },
	{ key = "left",   header = "Left",        width = 50, sortable = false },
	{ key = "ret",    header = "",            width = 20, sortable = false, build = buildReturnCell },
	{ key = "flags",  header = "",            width = 70, sortable = false },
}

--- MAILRETURN-001: send a mail back to its sender, everything still on it. `ReturnInboxItem` is the
--- call Blizzard's own inbox makes from its Return button (Era MailFrame.lua:786-800,
--- OpenMail_Delete), offered when `InboxItemCanDelete` is FALSE -- a player's mail is returnable,
--- a system or auction mail is deletable instead and has no sender to return to. A COD mail
--- returns like any other (Blizzard hides the COD prompt and returns). The inbox renumbers after
--- the return exactly as after a take, and MAIL_INBOX_UPDATE redraws the list.
---@param mail table a BuildMails entry
---@return boolean returned
function Mailbox:ReturnMail(mail)
	if not (mail and mail.mailIndex) then return false end
	if InboxItemCanDelete and InboxItemCanDelete(mail.mailIndex) then
		if self.Window then self.Window:SetStatusText("That mail has no sender to return it to.") end
		return false
	end
	if not ReturnInboxItem then return false end
	if self.taking then
		if self.Window then self.Window:SetStatusText("Already taking -- give it a moment.") end
		return false
	end
	self:ShiftExpanded(mail.mailIndex)
	ReturnInboxItem(mail.mailIndex)
	if self.Window then self.Window:SetStatusText(string.format("Returned to %s.", tostring(mail.sender or "sender"))) end
	return true
end

--- The cells a row owns, painted for the entry the RowList just put on it: the return icon shows
--- on a mail row that CAN be returned (a player's mail) and never on an attachment row.
function Mailbox:OnRowRender(entry, rowFrame)
	local cell = rowFrame.cells and rowFrame.cells.ret
	if not cell then return end
	local mail = entry and entry.kind == "mail" and entry.mail or nil
	local returnable = mail and not (InboxItemCanDelete and InboxItemCanDelete(mail.mailIndex))
	cell.mail = returnable and mail or nil
	cell.button:SetShown(returnable and true or false)
end

--- Money as coloured coin text. C_CurrencyInfo is the real API; the bare GetCoinTextureString
--- global is only a deprecation fallback in Era (Blizzard_DeprecatedCurrencyScript) and may be absent.
local function coinText(copper)
	local fmt = C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString
	return fmt and fmt(copper) or (tostring(copper) .. "c")
end

local function flagText(needed, cod)
	local flags = {}
	if needed then flags[#flags + 1] = "|cff00ff00needed|r" end
	if (cod or 0) > 0 then flags[#flags + 1] = "|cffff4444COD|r" end
	return table.concat(flags, " ")
end

--- Is this mail expanded (its attachment rows showing)? Keyed by mail index for the life of the
--- window's open; cleared when it closes.
function Mailbox:IsExpanded(mailIndex)
	return self.expanded ~= nil and self.expanded[mailIndex] == true
end

function Mailbox:ToggleExpanded(mailIndex)
	self.expanded = self.expanded or {}
	self.expanded[mailIndex] = not self.expanded[mailIndex] or nil
	self:DrawContent()
end

--- The RowList rows for `mails`: one `kind = "mail"` row per mail and, under an expanded mail, one
--- indented `kind = "item"` row per attachment. Pure over `mails` and the expansion state.
function Mailbox:ViewRows(mails)
	local rows = {}
	for _, m in ipairs(mails) do
		local open = self:IsExpanded(m.mailIndex)
		local first = m.attachments[1]
		local needed = false
		for _, a in ipairs(m.attachments) do if a.needed then needed = true end end
		rows[#rows + 1] = {
			kind = "mail", mail = m, _id = "m" .. m.mailIndex,
			icon   = first and first.icon or Mailbox.MONEY_ICON,
			name   = (open and "|cffffd100v|r " or "|cffffd100>|r ") .. ((m.subject and m.subject ~= "") and m.subject or "(no subject)"),
			count  = #m.attachments,
			sender = m.sender or "?",
			left   = string.format("%dd", math.floor(m.daysLeft or 0)),
			flags  = flagText(needed, m.cod),
		}
		if open then
			for _, a in ipairs(m.attachments) do
				rows[#rows + 1] = {
					kind = "item", mail = m, row = a, _id = "a" .. m.mailIndex .. ":" .. tostring(a.attachmentIndex or 0),
					icon   = a.icon,
					name   = "      " .. (a.money and coinText(a.money) or (a.link or a.name or "?")),
					count  = a.money and "" or a.count,
					sender = "", left = "",
					flags  = flagText(a.needed, a.cod),
				}
			end
		end
	end
	return rows
end

-- ─── Window ───────────────────────────────────────────────────────────────────

local function OnClose(_)
	Mailbox.isOpen = false
	Mailbox.expanded = nil
	Mailbox:StopTaking()
	if Mailbox.Window then Mailbox.Window:Hide() end
end

--- Should the window open by itself when this character opens a mailbox? Bankers only: the
--- window is about handling what the bank received.
function Mailbox:AutoOpens()
	local G = TOGBankClassic_Guild
	return G and G.IsBank and G:IsBank(G:GetNormalizedPlayer()) or false
end

--- MAILUI-002: the "TOG Bank" button on Blizzard's mail frame, for everyone -- the operator: "it
--- pops open once the first time i open a mailbox, but then i can't get to it again". Created once,
--- on the first MAIL_SHOW.
--- MAILBTN-001 (operator 2026-09-13, screenshot: the button floating in the band under the title):
--- "it needs to be on line in the top with TSM but on the left side of that box." TSM's own size
--- and height, read from TradeSkillMaster/Core/UI/MailingUI/Core.lua:163-173 (60x16, y -3 on
--- Classic, level +3; the small font is what fits 16px). Second round, with it beside TSM4: "it is
--- the right height, perfectly centered ... BUT, i want it in the left corner of that 'bar area'"
--- -- it sat over the "Inbox" title. So: the LEFT end of the title bar, just right of the portrait
--- ring, TSM's height. Third round (screenshot, x=74): "it still needs to go left a bit" -- 60.
--- Fourth (screenshot, x=60): "it's close, just a little more left" -- 52. Fifth (screenshot,
--- x=52, the button's left edge touching the ring): "a little too far left, i think 2-3 to the
--- right" -- 55. MAILBTN_X is the one number if a UI scale puts it on the ring.
local MAILBTN_W, MAILBTN_H, MAILBTN_X, MAILBTN_Y = 60, 16, 55, -3
function Mailbox:EnsureMailFrameButton()
	if self.MailFrameButton then return self.MailFrameButton end
	local host = _G.MailFrame
	if not host then return nil end
	local button = CreateFrame("Button", "TOGBankClassicMailboxButton", host, "UIPanelButtonTemplate")
	button:SetSize(MAILBTN_W, MAILBTN_H)
	button:SetPoint("TOPLEFT", host, "TOPLEFT", MAILBTN_X, MAILBTN_Y)
	button:SetFrameLevel(host:GetFrameLevel() + 3)
	button:SetNormalFontObject(GameFontNormalSmall)
	button:SetHighlightFontObject(GameFontHighlightSmall)
	button:SetText("TOG Bank")
	button:SetScript("OnClick", function() Mailbox:Toggle() end)
	self.MailFrameButton = button
	return button
end

function Mailbox:OnMailShow()
	self:EnsureMailFrameButton()
	if self:AutoOpens() then self:Open() end
end

function Mailbox:OnMailClosed()
	if self.isOpen then self:Close() end
end

function Mailbox:OnInboxUpdate()
	if self.isOpen then self:DrawContent() end
end

function Mailbox:Open()
	if not self.Window then self:DrawWindow() end
	self.isOpen = true
	self.Window:Show()
	self:DrawContent()
end

function Mailbox:Close()
	if not self.isOpen then return end
	OnClose(self.Window)
end

function Mailbox:Toggle()
	if self.isOpen then self:Close() else self:Open() end
end

--- Report a take's outcome on the status bar.
function Mailbox:ReportTake(ok, taken, reason)
	if not self.Window then return end
	if not ok then
		self.Window:SetStatusText(reason or "Could not take that.")
	elseif reason then
		self.Window:SetStatusText(string.format("Took %d, then stopped: %s", taken, reason))
	else
		self.Window:SetStatusText(string.format("Took %d attachment(s).", taken))
	end
end

--- Take every attachment of `rows`, reporting when done. Shared by Take Shown and a mail row's
--- right-click.
function Mailbox:TakeRows(rows)
	local started = self:TakeAll(rows, function(taken, reason) self:ReportTake(true, taken, reason) end)
	if not started and self.Window then self.Window:SetStatusText("Already taking -- give it a moment.") end
	return started
end

--- MAILCOLLECT-001: take what the open orders are short of. Returns what TakeRows returns, or
--- false with the reason nothing was started (not a banker; nothing short; already taking).
function Mailbox:TakeNeeded()
	local G = TOGBankClassic_Guild
	if not (G and G.IsBank and G:IsBank(G:GetNormalizedPlayer())) then
		if self.Window then self.Window:SetStatusText("Only a bank character has orders to collect for.") end
		return false, "not a banker"
	end
	local rows = self:NeededAttachments(self:BuildMails())
	if #rows == 0 then
		if self.Window then self.Window:SetStatusText("Nothing in the mail is needed for an open order -- your bags already cover them, or nothing was sent.") end
		return false, "nothing needed"
	end
	return self:TakeRows(rows)
end

--- One attachment row into the bags, saying which.
function Mailbox:TakeOne(row)
	local ok, reason = self:TakeRow(row)
	if ok then
		if self.Window then self.Window:SetStatusText(string.format("Taking %s...", row.name)) end
	else
		self:ReportTake(false, 0, reason)
	end
	return ok
end

--- MAILCLICK-001 (the operator, 2026-09-13, with the window open: "when i left click on an item it
--- needs to move into my bag. when i shift+left click it needs to move all attachments from the
--- mail to the bags. Just like the 'real' mailbox"). Blizzard's inbox: a click on an attachment
--- takes it, shift-click on the mail auto-loots everything in it. MAILCLICK-002, on the first cut
--- (which took a one-attachment mail's item on a click of the MAIL row): "the left click to loot
--- needs to only work when i click on the item, not the mail, i need the expand to work". So:
---   shift + left-click, any row      -> every attachment of that mail (money included)
---   left-click, an attachment row    -> that attachment
---   left-click, a mail row           -> opens / closes it, always -- the item rows are under it
---   right-click, a mail row          -> every attachment of that mail (as it was before)
---   right-click, an attachment row   -> that attachment (unchanged)
function Mailbox:OnRowClick(entry, button)
	if not entry then return end
	local mail = entry.mail
	local shift = IsShiftKeyDown and IsShiftKeyDown()
	if entry.kind == "item" then
		if shift then self:TakeRows(mail.attachments) else self:TakeOne(entry.row) end
	elseif button == "RightButton" or shift then
		self:TakeRows(mail.attachments)
	else
		self:ToggleExpanded(mail.mailIndex)
	end
end

--- MAILUI-002: the tooltips. An attachment row shows the REAL game tooltip for that attachment
--- (GameTooltip:SetInboxItem(mailIndex, attachmentIndex), the call Blizzard's own inbox makes at
--- MailFrame.xml:235), the money row its coin text, and a mail row every attachment it carries --
--- the "see everything attached" preview without expanding it.
function Mailbox:OnRowEnter(entry, rowFrame)
	if not entry then return end
	GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
	if entry.kind == "item" then
		local a = entry.row
		if a.attachmentIndex then
			GameTooltip:SetInboxItem(a.mailIndex, a.attachmentIndex)
		else
			GameTooltip:SetText(coinText(a.money or 0), 1, 1, 1)
		end
		GameTooltip:AddLine((a.cod or 0) > 0 and "Cash on delivery -- take it from the mail frame"
			or "Click to take it, shift-click to take everything on the mail", 0.6, 0.6, 0.6)
	else
		local m = entry.mail
		GameTooltip:SetText((m.subject and m.subject ~= "") and m.subject or "(no subject)", 1, 1, 1)
		GameTooltip:AddLine(string.format("from %s, %dd left", m.sender or "?", math.floor(m.daysLeft or 0)), 0.7, 0.7, 0.7)
		for _, a in ipairs(m.attachments) do
			if a.money then
				GameTooltip:AddLine(coinText(a.money), 1, 1, 1)
			else
				GameTooltip:AddLine(string.format("%s x%d%s", a.link or a.name or "?", a.count or 1,
					a.needed and "  |cff00ff00needed|r" or ""), 1, 1, 1)
			end
		end
		GameTooltip:AddLine((m.cod or 0) > 0 and "Cash on delivery -- take it from the mail frame"
			or "Click to open, shift-click (or right-click) to take everything on it", 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end

function Mailbox:DrawWindow()
	local window = TOGBankClassic_UI:Create("Frame")
	window:Hide()
	window:SetTitle(TOGBankClassic_UI:WindowTitle("Mailbox"))
	window:SetLayout("Flow")
	window:SetCallback("OnClose", OnClose)
	-- MAILBOX-PERSIST-001: position and size per character, like the Guild Bank window (the
	-- defaults and floor this window always had).
	TOGBankClassic_UI:PersistWindow(window, "mailbox", 560, 480, 420, 300)
	self.Window = window
	TOGBankClassic_UI:ApplyThinBorder(window, "mailbox")
	-- SYNCED-001: the banker at the mailbox is exactly who the "has my update reached anyone" line
	-- is for; this is the window they have open when it matters.
	self.StatusBar = TOGBankClassic_UI_StatusBar:AttachSides(window)

	-- SEARCH-005: the addon's one search box (TOGBankSearchBox, Modules/UI.lua).
	local search = TOGBankClassic_UI:Create("TOGBankSearchBox")
	search:SetPlaceholder("Filter by item, sender or subject")
	search:SetMaxLetters(50)
	search:SetRelativeWidth(0.5)
	search:SetCallback("OnTextChanged", function(_, _, text)
		self.filterText = text
		self:DrawContent()
	end)
	window:AddChild(search)
	self.SearchBox = search

	-- MAILCOLLECT-001: the mailbox's Fulfill-at-the-bank -- one click takes what the open orders
	-- are short of, oldest mail first, and nothing else. Bankers only; the button says so otherwise.
	local takeNeeded = TOGBankClassic_UI:Create("Button")
	takeNeeded:SetText("Take Needed")
	takeNeeded:SetRelativeWidth(0.24)
	takeNeeded:SetCallback("OnClick", function() self:TakeNeeded() end)
	TOGBankClassic_UI:AttachTooltip(takeNeeded, "ANCHOR_TOP", "Take Needed", {
		"Takes the attachments your open orders still need -- what the orders ask for beyond what is already in your bags -- oldest mail first. Nothing an order does not need is touched.",
	})
	window:AddChild(takeNeeded)
	self.TakeNeededButton = takeNeeded

	local takeShown = TOGBankClassic_UI:Create("Button")
	takeShown:SetText("Take Shown")
	takeShown:SetRelativeWidth(0.24)
	takeShown:SetCallback("OnClick", function()
		self:TakeRows(self:AttachmentsOf(self:FilterMails(self:BuildMails(), self.filterText)))
	end)
	window:AddChild(takeShown)
	self.TakeShownButton = takeShown

	-- MAILUI-002: the row list on a plain frame under the strip, exactly as the Guild Bank window
	-- hangs its Browse list under its filter strip (Browse.lua DrawWindow).
	local host = CreateFrame("Frame", nil, window.content)
	host:SetPoint("TOPLEFT",     window.content, "TOPLEFT",     0, -Mailbox.STRIP_H)
	host:SetPoint("BOTTOMRIGHT", window.content, "BOTTOMRIGHT", 0, 0)
	self.List = TOGBankClassic_UI_RowList:New(host, {
		columns    = self.COLUMNS,
		onRowClick = function(entry, _, button) self:OnRowClick(entry, button) end,
		onRowEnter = function(entry, rowFrame) self:OnRowEnter(entry, rowFrame) end,
		onRowLeave = function() GameTooltip:Hide() end,
		onRowRender = function(entry, rowFrame) self:OnRowRender(entry, rowFrame) end,
	})
	self.ListHost = host
end

--- Repopulate the rows from the live inbox through the filter. The inbox is at most 50 mails, so
--- rebuilding the data on every change is cheap and cannot show a row for a mail that is gone.
function Mailbox:DrawContent()
	if not self.List then return end
	local all = self:BuildMails()
	local mails = self:FilterMails(all, self.filterText)
	self.mailsShown = mails
	self.rowsShown = self:AttachmentsOf(mails)
	self.List:SetData(self:ViewRows(mails), true)

	if self.Window then
		if #all == 0 then
			self.Window:SetStatusText("The inbox is empty.")
		elseif #mails == 0 then
			self.Window:SetStatusText("Nothing matches the filter.")
		else
			self.Window:SetStatusText(string.format("%d attachment(s) in %d mail(s) shown -- click a mail to open it, click an item to take it, shift-click to take everything on a mail",
				#self.rowsShown, #mails))
		end
	end
end

function Mailbox:Init()
	-- Frame creation deferred to first Open() (PERF-015, as every other window).
end
