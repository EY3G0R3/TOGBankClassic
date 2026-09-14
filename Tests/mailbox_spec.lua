-- MAILUI-001: the inbox as inventory -- one row per attachment, a filter, and taking.
--
-- The operator, 2026-09-11: "see all the attachments on the mail and handle them like inventory
-- ... providing rows for all the attachments to an email, and a search filter allowing you to
-- narrow it down."
--
-- The DATA half is driven here against the harness's inbox model (wow.mail / wow.mailActions),
-- which is backed by Blizzard's own return shapes for GetInboxHeaderInfo / GetInboxItem. The
-- WINDOW half (DrawWindow / DrawContent) needs AceGUI's widget set, which the offline env does not
-- load -- it is not specced, and that is stated rather than hidden behind a stubbed Create.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")
local wow = require("env.wow")

local ME, OTHER = "Bankchar-Testrealm", "Otherbanker-Testrealm"
local M

local function load(isBank)
	-- env.reset() wipes wow.mail and wow.mailActions; each example fills the inbox it wants.
	env.stubOutput()
	env.loadModules({ "Modules/Constants.lua", "Modules/UI/Mailbox.lua" })
	M = TOGBankClassic_UI_Mailbox
	M.taking, M.isOpen, M.Window, M.Content = nil, nil, nil, nil
	TOGBankClassic_Guild = {
		Info = { name = "Testguild", requests = {} },
		GetNormalizedPlayer = function() return ME end,
		NormalizeName = function(_, n) return n end,
		IsBank = function(_, n) return isBank and n == ME end,
	}
	TOGBankClassic_Bank = { HasInventorySpace = function() return true end }
	_G.ATTACHMENTS_MAX_RECEIVE = 16
	return M
end

--- Two mails: one with two attachments from a guildmate, one money-only from another.
local function inbox()
	wow.mail[1] = { sender = "Alice", subject = "donation", money = 0, cod = 0, daysLeft = 29, items = {
		{ name = "Linen Cloth", id = 2589, count = 20, texture = 132889, quality = 1, link = "|cffffffff|Hitem:2589|h[Linen Cloth]|h|r" },
		{ name = "Minor Healing Potion", id = 858, count = 5, texture = 134780, quality = 1 },
	} }
	wow.mail[2] = { sender = "Bob", subject = "gold", money = 12345, cod = 0, daysLeft = 3 }
end

describe("MAILUI-001: rows", function()
	before_each(function() env.reset(); load(true); inbox() end)

	it("is one row per ATTACHMENT, in mail order, plus one per mail that carries money", function()
		local rows = M:BuildRows()
		assert.equal(3, #rows)
		assert.equal(1, rows[1].mailIndex); assert.equal(1, rows[1].attachmentIndex); assert.equal(2589, rows[1].itemID)
		assert.equal(20, rows[1].count); assert.equal("Alice", rows[1].sender); assert.equal(29, rows[1].daysLeft)
		assert.equal("|cffffffff|Hitem:2589|h[Linen Cloth]|h|r", rows[1].link)
		assert.equal(2, rows[2].attachmentIndex); assert.equal(858, rows[2].itemID); assert.is_nil(rows[2].link)
		assert.equal(2, rows[3].mailIndex); assert.is_nil(rows[3].attachmentIndex); assert.equal(12345, rows[3].money)
		assert.equal("Bob", rows[3].sender)
	end)

	it("marks an attachment an open order to THIS banker still wants, and nothing else", function()
		TOGBankClassic_Guild.Info.requests = {
			r1 = { id = "r1", bank = ME, itemID = 2589, quantity = 40, fulfilled = 10, status = "open" },
			r2 = { id = "r2", bank = OTHER, itemID = 858, quantity = 5, fulfilled = 0, status = "open" },   -- another banker's
		}
		local rows = M:BuildRows()
		assert.is_true(rows[1].needed, "an open order to this banker did not mark its item")
		assert.is_false(rows[2].needed, "an order to ANOTHER banker marked an item here")
		TOGBankClassic_Guild.Info.requests.r1.fulfilled = 40
		assert.is_false(M:BuildRows()[1].needed, "a fully sent order still marks the item")
		TOGBankClassic_Guild.Info.requests.r1.fulfilled = 0
		TOGBankClassic_Guild.Info.requests.r1.status = "cancelled"
		assert.is_false(M:BuildRows()[1].needed, "a cancelled order still marks the item")
	end)

	it("carries the COD amount on every row of a COD mail and skips a GM mail entirely", function()
		wow.mail[1].cod = 500
		wow.mail[3] = { sender = "GM", subject = "hi", money = 1, isGM = true, items = { { name = "X", id = 1 } } }
		local rows = M:BuildRows()
		assert.equal(3, #rows)
		assert.equal(500, rows[1].cod); assert.equal(500, rows[2].cod)
		for _, r in ipairs(rows) do assert.is_not_equal("GM", r.sender, "a GM mail produced a row") end
	end)

	it("filters by item name or sender, case-insensitively, and leaves the input alone", function()
		local rows = M:BuildRows()
		assert.equal(3, #M:FilterRows(rows, ""))
		assert.equal(3, #M:FilterRows(rows, "   "))
		local linen = M:FilterRows(rows, "LINEN")
		assert.equal(1, #linen); assert.equal(2589, linen[1].itemID)
		local alice = M:FilterRows(rows, "alice")
		assert.equal(2, #alice, "sender did not match")
		assert.equal(0, #M:FilterRows(rows, "zzz"))
		assert.equal(3, #rows, "FilterRows mutated the rows it was given")
	end)
end)

-- MAILCOLLECT-001: the operator, 2026-09-13: "can you do the grabbing from the mail like we do
-- with the bank to fill orders? so we can grab items out of the 'mail bank' that we need?" -- the
-- Mailbox window's Take Needed. Owed = what open orders to this banker ask for beyond the bags;
-- the pick walks oldest mail first, skips COD, and stops per item once the shortfall is covered.
describe("MAILCOLLECT-001: taking what the open orders need", function()
	local bags
	before_each(function()
		env.reset(); load(true)
		bags = {}
		TOGBankClassic_Bank.CountItemInBags = function(_, _, id) return bags[id] or 0 end
		-- Newest first, as the inbox lists them: mail 1 is the newest.
		wow.mail[1] = { sender = "Cara", subject = "more", money = 0, cod = 0, daysLeft = 29, items = {
			{ name = "Linen Cloth", id = 2589, count = 20 } } }
		wow.mail[2] = { sender = "Bob", subject = "cod", money = 0, cod = 500, daysLeft = 20, items = {
			{ name = "Linen Cloth", id = 2589, count = 20 } } }
		wow.mail[3] = { sender = "Alice", subject = "donation", money = 0, cod = 0, daysLeft = 10, items = {
			{ name = "Linen Cloth", id = 2589, count = 20 },
			{ name = "Minor Healing Potion", id = 858, count = 5 },
			{ name = "Wool Cloth", id = 2592, count = 10 } } }
		TOGBankClassic_Guild.Info.requests = {
			r1 = { id = "r1", bank = ME, item = "Linen Cloth", itemID = 2589, quantity = 40, fulfilled = 10, status = "open" },
			r2 = { id = "r2", bank = ME, item = "Linen Cloth", itemID = 2589, quantity = 5, fulfilled = 0, status = "open" },
			r3 = { id = "r3", bank = ME, item = "Minor Healing Potion", itemID = 858, quantity = 5, fulfilled = 0, status = "open" },
			r4 = { id = "r4", bank = OTHER, item = "Wool Cloth", itemID = 2592, quantity = 10, fulfilled = 0, status = "open" },
			r5 = { id = "r5", bank = ME, item = "Wool Cloth", itemID = 2592, quantity = 3, fulfilled = 0, status = "cancelled" },
		}
	end)

	it("sums what this banker's open orders still owe, per item, less what the bags hold", function()
		bags[2589] = 12
		local owed = M:OwedByOpenOrders()
		assert.equal(23, owed[2589], "30 + 5 owed, 12 in bags")
		assert.equal(5, owed[858])
		assert.is_nil(owed[2592], "another banker's order, or a cancelled one, counted as owed here")
		bags[2589] = 100
		assert.equal(0, M:OwedByOpenOrders()[2589], "bags beyond the orders went negative")
	end)

	it("picks oldest mail first, skips COD, and stops per item once the shortfall is covered -- overshooting only by the last stack", function()
		bags[2589] = 12   -- 23 short: Alice's 20 (oldest) then Cara's 20 covers it; Bob's is COD
		local rows = M:NeededAttachments(M:BuildMails())
		local picked = {}
		for _, r in ipairs(rows) do picked[#picked + 1] = r.mailIndex .. ":" .. r.itemID end
		assert.same({ "3:2589", "3:858", "1:2589" }, picked)
		-- Wool: needed by nobody here -- not picked even though it sits on the oldest mail.
		bags[2589] = 30   -- 5 short: Alice's one stack covers it; Cara's is left alone
		rows = M:NeededAttachments(M:BuildMails())
		picked = {}
		for _, r in ipairs(rows) do picked[#picked + 1] = r.mailIndex .. ":" .. r.itemID end
		assert.same({ "3:2589", "3:858" }, picked)
		bags[2589], bags[858] = 100, 100
		assert.equal(0, #M:NeededAttachments(M:BuildMails()), "nothing is short, yet something was picked")
	end)

	it("Take Needed runs the pick through the take sequencer, highest mail index first, and reports; a non-banker is told no", function()
		bags[2589] = 12
		assert.is_true(M:TakeNeeded())
		env.advance(M.TAKE_DELAY); env.advance(M.TAKE_DELAY); env.advance(M.TAKE_DELAY)
		assert.equal(3, #wow.mailActions, "not every needed attachment was taken")
		-- Sorted for taking: mail 3's two attachments (index 3 first, higher attachment first), then mail 1.
		assert.same({ action = "take", index = 3, attachment = 2 }, wow.mailActions[1])
		assert.same({ action = "take", index = 3, attachment = 1 }, wow.mailActions[2])
		assert.same({ action = "take", index = 1, attachment = 1 }, wow.mailActions[3])
		-- Nothing short: says so, takes nothing.
		bags[2589], bags[858] = 100, 100
		local ok, why = M:TakeNeeded()
		assert.is_false(ok); assert.equal("nothing needed", why)
		assert.equal(3, #wow.mailActions)
		-- Not a banker: refused before looking.
		load(false)
		ok, why = M:TakeNeeded()
		assert.is_false(ok); assert.equal("not a banker", why)
	end)
end)

describe("MAILUI-001: taking", function()
	before_each(function() env.reset(); load(true); inbox() end)

	it("takes an attachment, or the money, of the row it is given", function()
		local rows = M:BuildRows()
		assert.is_true(M:TakeRow(rows[2]))
		assert.same({ action = "take", index = 1, attachment = 2 }, wow.mailActions[1])
		assert.is_true(M:TakeRow(rows[3]))
		assert.same({ action = "takeMoney", index = 2 }, wow.mailActions[2])
	end)

	it("refuses a COD row and a take into full bags, saying why, and takes nothing", function()
		wow.mail[1].cod = 500
		local rows = M:BuildRows()
		local ok, why = M:TakeRow(rows[1])
		assert.is_false(ok); assert.truthy(why:find("cash-on-delivery", 1, true))
		wow.mail[1].cod = 0
		TOGBankClassic_Bank.HasInventorySpace = function() return false end
		ok, why = M:TakeRow(M:BuildRows()[1])
		assert.is_false(ok); assert.truthy(why:find("bags are full", 1, true))
		assert.equal(0, #wow.mailActions)
	end)

	-- Highest mail index first: a taken mail vanishes and renumbers those above it, so walking
	-- down keeps every untaken index valid. Blizzard's Open All waits between takes; so do we.
	it("takes every shown row from the highest mail index down, one per delay, and reports the count", function()
		local done, count
		assert.is_true(M:TakeAll(M:BuildRows(), function(n, reason) done, count = reason or "ok", n end))
		assert.equal(1, #wow.mailActions, "TakeAll took more than one before the client could finish the first")
		assert.same({ action = "takeMoney", index = 2 }, wow.mailActions[1], "did not start from the highest mail index")
		env.advance(M.TAKE_DELAY)
		assert.equal(2, #wow.mailActions)
		assert.same({ action = "take", index = 1, attachment = 2 }, wow.mailActions[2], "attachments are not taken highest first")
		env.advance(M.TAKE_DELAY)
		assert.equal(3, #wow.mailActions)
		env.advance(M.TAKE_DELAY)
		assert.equal("ok", done); assert.equal(3, count)
		assert.is_nil(M.taking)
	end)

	it("waits while the client reports a command pending, rather than firing the next take blind", function()
		local pending = true
		_G.C_Mail = { IsCommandPending = function() return pending end }
		M:TakeAll(M:BuildRows(), function() end)
		env.advance(M.TAKE_DELAY)
		assert.equal(1, #wow.mailActions, "took the next attachment while the client was still busy")
		env.advance(M.TAKE_DELAY)
		assert.equal(1, #wow.mailActions)
		pending = false
		env.advance(M.TAKE_DELAY)
		assert.equal(2, #wow.mailActions, "did not resume once the client was free")
		_G.C_Mail = nil
	end)

	it("stops at the first row it cannot take, reporting how many it took and why it stopped", function()
		wow.mail[1].cod = 500   -- rows 1 and 2 are COD; the money row (mail 2) is taken first
		local done, count
		M:TakeAll(M:BuildRows(), function(n, reason) count, done = n, reason end)
		env.advance(M.TAKE_DELAY)
		assert.equal(1, count); assert.truthy(done and done:find("cash-on-delivery", 1, true))
		assert.equal(1, #wow.mailActions)
	end)

	it("refuses to start a second take-all while one is running, and StopTaking abandons the queue", function()
		M:TakeAll(M:BuildRows(), function() end)
		local ok, why = M:TakeAll(M:BuildRows(), function() end)
		assert.is_false(ok); assert.equal("already taking", why)
		M:StopTaking()
		env.advance(M.TAKE_DELAY * 4)
		assert.equal(1, #wow.mailActions, "takes continued after StopTaking")
	end)
end)

describe("MAILUI-001: opening beside the mail frame", function()
	local opened

	local function spyOpen()
		opened = 0
		M.Open = function() opened = opened + 1; M.isOpen = true end
	end

	it("opens by itself at MAIL_SHOW for a banker", function()
		env.reset(); load(true); spyOpen()
		M:OnMailShow()
		assert.equal(1, opened)
	end)

	it("does NOT open by itself for a non-banker -- the window is about what the bank received", function()
		env.reset(); load(false); spyOpen()
		M:OnMailShow()
		assert.equal(0, opened)
		assert.is_false(M:AutoOpens())
	end)

	it("closes with the mailbox and abandons a take-all in progress", function()
		env.reset(); load(true); inbox(); spyOpen()
		M:OnMailShow()
		M:TakeAll(M:BuildRows(), function() end)
		M:OnMailClosed()
		assert.is_false(M.isOpen)
		assert.is_nil(M.taking, "the take-all outlived the mailbox")
	end)
end)

-- ─── MAILUI-002: one row per mail, expandable, the filter narrowing both ─────────────
--
-- The operator, 2026-09-12: "one mail per row with however many items attached. i'd like to be
-- able to click into the mail to see everything attached to the one mail ... the filter needs to
-- update the rows and filter out the items so we only see the items on the rows that match".

--- Three mails: two attachments from Alice, one attachment + money from Bob, money only from Carol.
local function inbox3()
	inbox()
	wow.mail[2].items = { { name = "Linen Cloth", id = 2589, count = 7, texture = 132889, quality = 1 } }
	wow.mail[3] = { sender = "Carol", subject = "tip", money = 50, cod = 0, daysLeft = 10 }
end

describe("MAILUI-002: mails", function()
	before_each(function() env.reset(); load(true); inbox3() end)

	it("is one entry per mail carrying something, in inbox order, with its attachments and money", function()
		local mails = M:BuildMails()
		assert.equal(3, #mails)
		assert.equal(1, mails[1].mailIndex); assert.equal("Alice", mails[1].sender); assert.equal("donation", mails[1].subject)
		assert.equal(2, #mails[1].attachments); assert.is_nil(mails[1].money)
		assert.equal(2589, mails[1].attachments[1].itemID); assert.equal(858, mails[1].attachments[2].itemID)
		-- Bob: the item first, then the money as the last "attachment" (attachmentIndex nil).
		assert.equal(12345, mails[2].money)
		assert.equal(2, #mails[2].attachments)
		assert.equal(7, mails[2].attachments[1].count); assert.is_nil(mails[2].attachments[2].attachmentIndex)
		assert.equal(12345, mails[2].attachments[2].money)
		-- Carol: money only.
		assert.equal(1, #mails[3].attachments); assert.equal(50, mails[3].money)
	end)

	it("skips a mail with nothing takeable, and a GM mail", function()
		wow.mail[4] = { sender = "Dave", subject = "just text", money = 0, cod = 0, daysLeft = 5 }
		wow.mail[5] = { sender = "GM", subject = "hi", money = 1, isGM = true, items = { { name = "X", id = 1 } } }
		local mails = M:BuildMails()
		assert.equal(3, #mails)
		for _, m in ipairs(mails) do assert.is_not_equal("Dave", m.sender); assert.is_not_equal("GM", m.sender) end
	end)

	it("keeps EVERY attachment of a mail whose sender or subject matches", function()
		local mails = M:BuildMails()
		local alice = M:FilterMails(mails, "ALICE")
		assert.equal(1, #alice); assert.equal(2, #alice[1].attachments, "a sender match dropped attachments")
		local tip = M:FilterMails(mails, "tip")
		assert.equal(1, #tip); assert.equal("Carol", tip[1].sender)
	end)

	it("keeps ONLY the matching attachments of a mail matched through an item, and drops mails with none", function()
		local mails = M:BuildMails()
		local linen = M:FilterMails(mails, "linen")
		assert.equal(2, #linen, "Alice's and Bob's linen")
		assert.equal(1, #linen[1].attachments, "the potion stayed on Alice's mail under an item filter")
		assert.equal(2589, linen[1].attachments[1].itemID)
		assert.equal(1, #linen[2].attachments, "Bob's money stayed under an item filter")
		assert.equal(2589, linen[2].attachments[1].itemID)
		assert.equal(0, #M:FilterMails(mails, "zzz"))
		assert.equal(mails, M:FilterMails(mails, "  "), "an empty filter should hand back the same list")
	end)

	it("never mutates the mails it filters -- the next redraw sees the whole inbox again", function()
		local mails = M:BuildMails()
		local linen = M:FilterMails(mails, "linen")
		assert.is_not_equal(mails[1], linen[1], "the kept mail is the original table, not a copy")
		assert.equal(2, #mails[1].attachments, "FilterMails removed attachments from the original")
		assert.equal(2, #mails[2].attachments)
		assert.equal(2, #M:AttachmentsOf(linen), "AttachmentsOf did not flatten the filtered view")
		assert.equal(5, #M:AttachmentsOf(mails))
	end)

	it("renders one row per mail collapsed, and one indented row per attachment once expanded", function()
		M.expanded = nil
		local mails = M:BuildMails()
		local rows = M:ViewRows(mails)
		assert.equal(3, #rows)
		assert.equal("mail", rows[1].kind); assert.equal(2, rows[1].count); assert.equal("Alice", rows[1].sender)
		assert.equal("29d", rows[1].left); assert.equal(132889, rows[1].icon, "a mail row shows its first attachment's icon")
		assert.truthy(rows[1].name:find("donation", 1, true))
		assert.equal(M.MONEY_ICON, rows[3].icon, "a money-only mail shows the coin")
		M:IsExpanded(1)
		M.expanded = { [1] = true }
		rows = M:ViewRows(mails)
		assert.equal(5, #rows, "expanding a two-attachment mail did not add two rows under it")
		assert.equal("item", rows[2].kind); assert.equal("item", rows[3].kind); assert.equal("mail", rows[4].kind)
		assert.truthy(rows[2].name:find("|Hitem:2589|", 1, true), "the attachment row does not carry the item link")
		assert.equal(20, rows[2].count)
		assert.truthy(rows[3].name:find("Minor Healing Potion", 1, true), "a linkless attachment falls back to its name")
		assert.equal(5, rows[3].count)
		assert.equal("", rows[2].sender, "attachment rows repeat the sender")
		M.expanded = { [2] = true }
		rows = M:ViewRows(mails)   -- Alice, Bob, Bob's linen, Bob's money, Carol
		assert.equal(7, rows[3].count)
		assert.equal("", rows[4].count, "the money row shows a count")
		assert.truthy(rows[4].name:find("12345", 1, true), "the money row does not show the amount")
	end)

	it("flags a mail whose attachment an open order wants, and a COD mail, on the mail row and the item row", function()
		TOGBankClassic_Guild.Info.requests = { r1 = { id = "r1", bank = ME, itemID = 858, quantity = 5, fulfilled = 0, status = "open" } }
		wow.mail[2].cod = 900
		M.expanded = { [1] = true }
		local rows = M:ViewRows(M:BuildMails())
		assert.truthy(rows[1].flags:find("needed", 1, true), "the mail row does not say an attachment is needed")
		assert.equal("", rows[2].flags, "the linen row is flagged needed")
		assert.truthy(rows[3].flags:find("needed", 1, true))
		assert.truthy(rows[4].flags:find("COD", 1, true), "the COD mail is not flagged")
	end)
end)

describe("MAILUI-002: the window", function()
	local calls

	before_each(function()
		env.reset()
		-- The rich frame model BEFORE the widget library loads (browse_spec's rule: Ace3's widget
		-- files capture CreateFrame at file scope, once per Lua state).
		require("env.frames").reset()
		env.stubOutput()
		require("env.libs").load("LibAceGUIWidgets-1.0")
		-- SPEC-HYGIENE-001: Constants is loaded ONCE, by load() below -- neither UI.lua, RowList.lua
		-- nor Mailbox.lua reads it at file scope, so nothing here needs it earlier.
		env.loadUI()
		env.loadFile("Modules/UI/RowList.lua")
		load(true)
		inbox3()
		TOGBankClassic_UI_StatusBar = { AttachSides = function() return {} end }
		calls = {}
		-- The harness's GameTooltip has no SetInboxItem (it is the client's inbox tooltip); record the
		-- call so the spec can prove the REAL tooltip is asked for, with the right indices.
		local tip = _G.GameTooltip
		tip.SetInboxItem = function(_, mailIndex, attachmentIndex) calls[#calls + 1] = { mailIndex, attachmentIndex } end
		-- MAILRETURN-001: InboxItemCanDelete (a SYSTEM mail, `wow.mail[i].system = true`, is deletable;
		-- a player's mail is returnable) and ReturnInboxItem are the harness's since pin 292f625.
	end)

	after_each(function()
		TOGBankClassic_UI_StatusBar = nil
		local tip = _G.GameTooltip
		tip.SetInboxItem = nil
	end)

	local function shownNames(rl)
		local out = {}
		for i, row in ipairs(rl.rows) do
			if row:IsShown() then out[i] = row.cells.name:GetText() end
		end
		return out
	end

	it("opens on a RowList of mails with the filter strip above it, titled like the other windows", function()
		M:Open()
		assert.is_true(M.isOpen)
		assert.truthy(M.Window.titletext:GetText():find("Mailbox", 1, true))
		assert.is_not_nil(M.List, "no RowList")
		assert.equal(3, #M.List.data, "one row per mail")
		assert.equal(5, #M.rowsShown, "rowsShown is not the flat attachment list")
		-- Hung under the strip, stretched to the content frame.
		local point, rel, relPoint, x, y = M.ListHost:GetPoint(1)
		assert.equal("TOPLEFT", point); assert.equal(M.Window.content, rel); assert.equal("TOPLEFT", relPoint)
		assert.equal(0, x); assert.equal(-M.STRIP_H, y)
		assert.equal("Mail / Item", M.COLUMNS[2].header)
		for _, col in ipairs(M.COLUMNS) do assert.is_false(col.sortable ~= false, col.key .. " is sortable; a sort would split a mail from its rows") end
		assert.truthy(M.Window.statustext:GetText():find("5 attachment(s) in 3 mail(s)", 1, true))
	end)

	-- SPEC-HYGIENE-001 (Peer Review ccd04f5e item 4): STRIP_H is a constant the list is hung under,
	-- and the strip is an AceGUI Flow row whose height the widgets decide. If a widget grows (a font
	-- scale, a taller search box), the list overlaps the strip -- on a screen, silently. So the spec
	-- measures the row the layout actually produced and holds the constant to it.
	it("hangs the list below the strip the Flow layout actually produced (STRIP_H covers every widget in the row)", function()
		M:Open()
		local content = M.Window.content
		local top = assert(content:GetTop(), "the content frame did not resolve")
		local lowest = 0
		for _, child in ipairs(M.Window.children) do
			local bottom = assert(child.frame:GetBottom(), "a strip widget did not resolve")
			lowest = math.max(lowest, top - bottom)
		end
		assert.is_true(lowest > 0, "no strip widget has a height")
		assert.is_true(M.STRIP_H >= lowest,
			("STRIP_H %d is under the strip's measured %d -- the list would overlap it"):format(M.STRIP_H, lowest))
	end)

	-- MAILBOX-PERSIST-001 (operator 2026-09-13: "ensure the mail inbox window saves size/position and
	-- persists through reload and open/close like the main window"): the window's status table IS
	-- the per-character save, so AceGUI's own drag/resize writes persist; a rebuilt window (a reload)
	-- reads the same table back, and a saved size under the floor is raised to it.
	it("remembers its position and size per character, through a rebuild, through UI:PersistWindow", function()
		TOGBankClassic_Options = { db = { char = { framePositions = {} } } }
		M:Open()
		local positions = TOGBankClassic_Options.db.char.framePositions
		local saved = positions.mailbox
		assert.is_table(saved, "no framePositions.mailbox after the first open")
		assert.equal(saved, M.Window.status, "the window's status table is not the saved one -- a drag would not persist")
		assert.equal(560, saved.width); assert.equal(480, saved.height)
		-- The floor reaches the FRAME, not only the status table: the library's ApplyResizeBounds
		-- (SetResizeBounds, else SetMinResize) is what stops a drag under it.
		assert.same({ 420, 300 }, { M.Window.frame:GetMinResize() }, "the resize floor did not reach the frame")
		-- A drag and a resize, as AceGUI records them; then a reload rebuilds the window.
		saved.top, saved.left, saved.width, saved.height = 700, 120, 640, 500
		M:Close()
		M.Window = nil
		M:Open()
		assert.equal(saved, M.Window.status, "the rebuilt window did not read the saved table")
		assert.equal(640, M.Window.frame:GetWidth()); assert.equal(500, M.Window.frame:GetHeight())
		-- Under the floor: raised, so there is something to drag.
		saved.width, saved.height = 100, 100
		M:Close(); M.Window = nil; M:Open()
		assert.equal(420, saved.width); assert.equal(300, saved.height)
		-- Without a db (a spec, or before Options is up) the defaults apply and nothing is saved.
		TOGBankClassic_Options = nil
		M:Close(); M.Window = nil; M:Open()
		assert.equal(560, M.Window.frame:GetWidth())
	end)

	-- WINDOW-PERSIST-002: every window persists through the ONE spelling. A source property, because
	-- the drift it stops is a sixth window growing its own SetStatusTable + SetResizeBounds pair (four
	-- of them did, identically, until 2026-09-13).
	it("every window persists through UI:PersistWindow and none spells the status table itself", function()
		local windows = { "Modules/UI/Inventory.lua", "Modules/UI/Search.lua", "Modules/UI/Requests.lua",
			"Modules/UI/Browse.lua", "Modules/UI/Mailbox.lua" }
		for _, path in ipairs(windows) do
			local src = env.readFile(path)
			assert.truthy(src:find("TOGBankClassic_UI:PersistWindow(", 1, true), path .. " does not persist through UI:PersistWindow")
			assert.is_nil(src:find(":SetStatusTable(", 1, true), path .. " spells its own status table")
			assert.is_nil(src:find(":SetResizeBounds(", 1, true), path .. " sets its own resize bounds beside the persisted floor")
		end
		local ui = env.readFile("Modules/UI.lua")
		assert.truthy(ui:find("function TOGBankClassic_UI:PersistWindow(", 1, true))
	end)

	-- WINDOW-PERSIST-002, the equivalence Peer Review asked to see pinned (6f421e806c84 F9): the
	-- Inventory window used to call `window.frame:SetResizeBounds(500, 500)` itself. Through the
	-- wrapper, with the numbers Inventory.lua passes, the same bounds land on the frame -- and they
	-- land whichever of the two setters the client has, because the library picks (ApplyResizeBounds:
	-- SetResizeBounds when present, else SetMinResize), which is the fallback Requests.lua dropped.
	it("hands the Inventory window's 500x500 floor to the frame through the library, on either setter", function()
		TOGBankClassic_Options = { db = { char = { framePositions = {} } } }
		local window = TOGBankClassic_UI:Create("Frame")
		TOGBankClassic_UI:PersistWindow(window, "inventory", 550, 500, 500, 500)
		assert.same({ 500, 500 }, { window.frame:GetMinResize() })
		assert.same({ 500, 500 }, { window.frame:GetResizeBounds() })
		window:Release()
		-- A client with only the Classic-era pair: the floor still reaches the frame. The harness
		-- frame is a plain table whose methods come from its class metatable, so an instance `false`
		-- is what makes `if raw.SetResizeBounds then` take the fallback; `nil` would not shadow.
		local old = TOGBankClassic_UI:Create("Frame")
		old.frame.SetResizeBounds = false
		TOGBankClassic_UI:PersistWindow(old, "inventory", 550, 500, 500, 500)
		old.frame.SetResizeBounds = nil
		assert.same({ 500, 500 }, { old.frame:GetMinResize() })
		old:Release()
		TOGBankClassic_Options = nil
	end)

	-- MAILUI-003 (Peer Review ccd04f5e): the inbox renumbers when an emptied mail vanishes, so the
	-- expansion set -- keyed by index -- follows the same rule instead of landing on the mail that
	-- inherited the number. A take that leaves its mail with something still on it shifts nothing.
	it("shifts the expansion set down when a take empties a mail, and leaves it alone otherwise", function()
		wow.mail[1].items = { wow.mail[1].items[1] }   -- Alice: ONE attachment, no money -> a take empties it
		M:Open()
		M:ToggleExpanded(2); M:ToggleExpanded(3)
		assert.is_false(M:IsExpanded(1)); assert.is_true(M:IsExpanded(2)); assert.is_true(M:IsExpanded(3))
		local rows = M:BuildRows()
		assert.is_true(M:TakeEmptiesMail(rows[1]), "one attachment, no money: the take empties the mail")
		assert.is_false(M:TakeEmptiesMail(rows[2]), "Bob's mail keeps its money after the item is taken")
		M:TakeRows({ rows[1] })                          -- the first take is synchronous
		assert.is_true(M:IsExpanded(1), "mail 2 moved down to 1 and lost its expansion")
		assert.is_true(M:IsExpanded(2), "mail 3 moved down to 2 and lost its expansion")
		assert.is_false(M:IsExpanded(3), "a stale expansion stayed on the vacated top index")
		M:StopTaking()
		-- A take that does not empty the mail: nothing moves.
		M.expanded = { [2] = true }
		M:TakeRows({ rows[2] })
		assert.is_true(M:IsExpanded(2)); assert.is_false(M:IsExpanded(1))
		M:StopTaking()
	end)

	it("expands a mail on a left click and collapses it on the next, keeping the other mails in place", function()
		M:Open()
		M.List.parent:SetHeight(20 + 16 * 10); M.List:Refresh()
		M.List.rows[1]:Fire("OnClick", "LeftButton")
		assert.equal(5, #M.List.data, "clicking Alice's mail did not add its two rows")
		local names = shownNames(M.List)
		assert.truthy(names[2]:find("Linen Cloth", 1, true)); assert.truthy(names[3]:find("Potion", 1, true))
		assert.truthy(names[4]:find("gold", 1, true), "Bob's mail did not follow Alice's rows")
		M.List.rows[1]:Fire("OnClick", "LeftButton")
		assert.equal(3, #M.List.data, "a second click did not collapse the mail")
	end)

	it("narrows both levels as the filter changes: only matching attachments under an expanded mail", function()
		M:Open()
		M.List.parent:SetHeight(20 + 16 * 10); M.List:Refresh()
		M.List.rows[1]:Fire("OnClick", "LeftButton")
		M.SearchBox:Fire("OnTextChanged", "linen")
		assert.equal(2, #M.mailsShown, "Carol's money-only mail survived an item filter")
		assert.equal(3, #M.List.data, "Alice expanded should show ONE attachment row under 'linen', plus Bob's mail")
		local names = shownNames(M.List)
		assert.truthy(names[2]:find("Linen Cloth", 1, true))
		assert.is_nil(names[2]:find("Potion", 1, true))
		M.SearchBox:Fire("OnTextChanged", "zzz")
		assert.equal(0, #M.List.data)
		assert.equal("Nothing matches the filter.", M.Window.statustext:GetText())
		M.SearchBox:Fire("OnTextChanged", "")
		assert.equal(5, #M.List.data, "clearing the filter did not bring the full expanded view back")
	end)

	-- MAILCLICK-001 (the operator, 2026-09-13: "when i left click on an item it needs to move into my
	-- bag. when i shift+left click it needs to move all attachments from the mail to the bags. Just
	-- like the 'real' mailbox"). Blizzard's inbox clicks, on our rows.
	it("takes ONE attachment on a left-click of its row (right-click too), and everything on a mail on a shift+left-click", function()
		M:Open()
		M.List.parent:SetHeight(20 + 16 * 10); M.List:Refresh()
		M.List.rows[1]:Fire("OnClick", "LeftButton")    -- Alice's mail: two attachments, so a click OPENS it
		M.List.rows[3]:Fire("OnClick", "LeftButton")    -- the potion
		assert.same({ action = "take", index = 1, attachment = 2 }, wow.mailActions[1])
		assert.truthy(M.Window.statustext:GetText():find("Taking Minor Healing Potion", 1, true))
		M.List.rows[2]:Fire("OnClick", "RightButton")   -- the linen: right-click still takes one
		assert.same({ action = "take", index = 1, attachment = 1 }, wow.mailActions[2])
		-- Shift+left on Bob's mail row: the item (attachment 1), then the money (0).
		_G.IsShiftKeyDown = function() return true end
		M.List.rows[4]:Fire("OnClick", "LeftButton")
		assert.equal(3, #wow.mailActions)
		assert.same({ action = "take", index = 2, attachment = 1 }, wow.mailActions[3], "a mail's take-all did not start with its attachments")
		-- env.frames installs env.wow's C_Timer, so the take sequencer's delay lives on that clock.
		require("env.wow").advanceTime(M.TAKE_DELAY)
		assert.same({ action = "takeMoney", index = 2 }, wow.mailActions[4], "the money was not taken after the item")
		_G.IsShiftKeyDown = function() return false end
	end)

	-- MAILCLICK-002 (the operator, on the first cut: "the left click to loot needs to only work when
	-- i click on the item, not the mail, i need the expand to work"): a mail row ALWAYS opens on a
	-- left-click, one attachment or ten; only attachment rows take on a click.
	it("a mail row opens on left-click even with one attachment; right-click on a mail takes everything; shift+left on an attachment row takes its whole mail", function()
		M:Open()
		M.List.parent:SetHeight(20 + 16 * 10); M.List:Refresh()
		-- Carol's mail (row 3) carries only money: the click OPENS it, takes nothing.
		M.List.rows[3]:Fire("OnClick", "LeftButton")
		assert.equal(0, #wow.mailActions, "a left-click on a one-attachment mail row took it")
		assert.is_true(M:IsExpanded(3), "the one-attachment mail did not open")
		M.List.rows[4]:Fire("OnClick", "LeftButton")   -- its money row: taken
		assert.same({ action = "takeMoney", index = 3 }, wow.mailActions[1])
		M:StopTaking()
		-- Right-click on Alice's mail takes everything on it, highest attachment first.
		M.List.rows[1]:Fire("OnClick", "RightButton")
		assert.same({ action = "take", index = 1, attachment = 2 }, wow.mailActions[2])
		require("env.wow").advanceTime(M.TAKE_DELAY)
		assert.same({ action = "take", index = 1, attachment = 1 }, wow.mailActions[3])
		M:StopTaking()
		-- Shift+left on one of Alice's attachment rows takes the whole mail too.
		M.List.rows[1]:Fire("OnClick", "LeftButton")   -- open Alice
		assert.is_true(M:IsExpanded(1))
		_G.IsShiftKeyDown = function() return true end
		M.List.rows[2]:Fire("OnClick", "LeftButton")
		_G.IsShiftKeyDown = function() return false end
		assert.same({ action = "take", index = 1, attachment = 2 }, wow.mailActions[4])
		require("env.wow").advanceTime(M.TAKE_DELAY)
		assert.same({ action = "take", index = 1, attachment = 1 }, wow.mailActions[5])
		M:StopTaking()
		M.List.rows[1]:Fire("OnClick", "LeftButton")
		assert.is_false(M:IsExpanded(1), "a second click did not close the mail")
	end)

	-- MAILRETURN-001 (the operator, 2026-09-13: "can we add a return to sender option on this with a
	-- mail icon to the right of the Left column?"). Blizzard's inbox returns a mail with
	-- ReturnInboxItem when InboxItemCanDelete is false (a player's mail); a system mail has nobody
	-- to return to and the icon stays off it.
	it("shows a return-to-sender envelope right of Left on every player mail row, and returns the mail on a click", function()
		M:Open()
		M.List.parent:SetHeight(20 + 16 * 10); M.List:Refresh()
		-- The column sits directly after Left.
		local keys = {}
		for i, c in ipairs(M.COLUMNS) do keys[i] = c.key end
		assert.same({ "icon", "name", "count", "sender", "left", "ret", "flags" }, keys)
		-- Every mail row carries the envelope; an attachment row does not.
		for i = 1, 3 do
			local cell = M.List.rows[i].cells.ret
			assert.is_true(cell.button:IsShown(), "mail row " .. i .. " has no return envelope")
			assert.equal(M.RETURN_ICON, cell.button:GetNormalTexture():GetTexture(), "the envelope is not the mail icon")
		end
		M.List.rows[1]:Fire("OnClick", "LeftButton")   -- open Alice: her two attachment rows appear
		assert.is_false(M.List.rows[2].cells.ret.button:IsShown(), "an attachment row grew a return envelope")
		assert.is_true(M.List.rows[4].cells.ret.button:IsShown(), "Bob's row lost its envelope after Alice opened")
		-- Hovering says who it goes back to.
		local btn = M.List.rows[4].cells.ret.button
		btn:Fire("OnEnter", btn)
		assert.truthy(GameTooltip:GetLines()[1].left:find("Return to Bob", 1, true))
		btn:Fire("OnLeave")
		-- The click returns THAT mail, and says so.
		M.expanded = { [1] = true, [3] = true }
		btn:Fire("OnClick")
		assert.same({ action = "return", index = 2 }, wow.mailActions[#wow.mailActions])
		assert.truthy(M.Window.statustext:GetText():find("Returned to Bob", 1, true))
		-- The inbox renumbers past the returned mail, like a take that empties one: Carol (3) -> 2.
		assert.same({ [1] = true, [2] = true }, M.expanded)
		-- A system mail (no sender to return to) shows no envelope, and a direct return is refused.
		wow.mail[3].system = true
		M:OnInboxUpdate()
		local carol
		for i, e in ipairs(M.List.data) do
			if e.kind == "mail" and e.mail.mailIndex == 3 then carol = M.List.rows[i - M.List.listOffset] end
		end
		assert.is_table(carol, "Carol's mail row is not drawn")
		assert.is_false(carol.cells.ret.button:IsShown(), "a system mail offers a return")
		local n = #wow.mailActions
		assert.is_false(M:ReturnMail({ mailIndex = 3, sender = "System" }))
		assert.equal(n, #wow.mailActions)
		assert.truthy(M.Window.statustext:GetText():find("no sender", 1, true))
		-- While a take-all is running the return waits its turn.
		M.taking = true
		assert.is_false(M:ReturnMail({ mailIndex = 1, sender = "Alice" }))
		assert.equal(n, #wow.mailActions)
		M.taking = nil
		-- Without the API at all (a client that lacks it): nothing happens, nothing errors.
		local real = _G.ReturnInboxItem
		_G.ReturnInboxItem = nil
		assert.is_false(M:ReturnMail({ mailIndex = 1, sender = "Alice" }))
		_G.ReturnInboxItem = real
	end)

	it("Take Shown takes exactly what the filter left", function()
		M:Open()
		M.SearchBox:Fire("OnTextChanged", "linen")
		M.TakeShownButton:Fire("OnClick")
		assert.equal(1, #wow.mailActions)
		assert.same({ action = "take", index = 2, attachment = 1 }, wow.mailActions[1], "did not start from the highest mail")
		require("env.wow").advanceTime(M.TAKE_DELAY)
		assert.same({ action = "take", index = 1, attachment = 1 }, wow.mailActions[2])
		require("env.wow").advanceTime(M.TAKE_DELAY * 2)
		assert.equal(2, #wow.mailActions, "Take Shown took something the filter had hidden")
	end)

	it("shows the REAL game tooltip for an attachment row (SetInboxItem), the coin text for money, and every attachment for a mail row", function()
		M:Open()
		M.List.parent:SetHeight(20 + 16 * 10); M.List:Refresh()
		M.List.rows[1]:Fire("OnClick", "LeftButton")
		M.List.rows[3]:Fire("OnEnter")
		assert.same({ { 1, 2 } }, calls, "the potion row did not ask the game for its inbox tooltip")
		assert.equal(M.List.rows[3], (GameTooltip:GetOwner()))
		M.List.rows[3]:Fire("OnLeave")
		assert.is_false(GameTooltip:IsShown())
		M.List.rows[1]:Fire("OnClick", "LeftButton")   -- collapse Alice
		M.List.rows[2]:Fire("OnClick", "LeftButton")   -- expand Bob
		M.List.rows[4]:Fire("OnEnter")                 -- Bob's money row
		assert.equal(1, #calls, "a money row asked for an inbox item tooltip")
		assert.truthy(GameTooltip.TextLeft1:GetText():find("12345", 1, true))
		M.List.rows[2]:Fire("OnEnter")                 -- Bob's mail row
		assert.equal("gold", GameTooltip.TextLeft1:GetText())
		assert.truthy(GameTooltip.TextLeft3:GetText():find("Linen Cloth x7", 1, true), "the mail tooltip does not list its attachments")
		assert.truthy(GameTooltip.TextLeft4:GetText():find("12345", 1, true))
	end)

	-- MAILBTN-001 (the operator, screenshot of the button floating under the title: "it needs to be
	-- on line in the top with TSM but on the left side of that box"): TSM's own placement
	-- (TradeSkillMaster/Core/UI/MailingUI/Core.lua:163-173 -- 60x16, MailFrame TOPRIGHT -26,-3,
	-- level +3), shifted left by a button-and-gap when TSM is loaded, in TSM's spot when it is not.
	it("puts a 'TOG Bank' button on Blizzard's mail frame title bar at MAIL_SHOW, once, for everyone, that toggles the window -- in TSM's spot, or left of TSM4", function()
		_G.MailFrame = CreateFrame("Frame", "MailFrame", UIParent)
		load(false)   -- not a banker: no auto-open, but the button still
		local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded
		_G.C_AddOns = { IsAddOnLoaded = function() return false end }
		M:OnMailShow()
		assert.is_falsy(M.isOpen, "a non-banker's mailbox auto-opened the window")
		local b = M.MailFrameButton
		assert.is_not_nil(b, "no button on the mail frame")
		assert.equal(_G.MailFrame, b:GetParent(), "the button is not on MailFrame (the title bar), where TSM's is")
		-- Second round: the LEFT end of the title bar (it sat over "Inbox" beside TSM4), TSM's height.
		local point, _, relPoint, x, y = b:GetPoint(1)
		-- Third round: 74 -> 60 ("it still needs to go left a bit"); fourth: 60 -> 52 ("just a little more left").
		assert.equal("TOPLEFT", point); assert.equal("TOPLEFT", relPoint); assert.equal(55, x); assert.equal(-3, y)
		assert.equal(60, b:GetWidth()); assert.equal(16, b:GetHeight())
		assert.equal(_G.MailFrame:GetFrameLevel() + 3, b:GetFrameLevel())
		assert.equal("TOG Bank", b:GetText())
		M:OnMailShow()
		assert.equal(b, M.MailFrameButton, "a second MAIL_SHOW made a second button")
		b:Fire("OnClick")
		assert.is_true(M.isOpen, "the button did not open the window")
		b:Fire("OnClick")
		assert.is_false(M.isOpen, "the button did not close it again")
		-- The left corner is TSM-independent: the same spot with TSM loaded.
		M.MailFrameButton = nil
		_G.C_AddOns = { IsAddOnLoaded = function(name) return name == "TradeSkillMaster" end }
		local b2 = M:EnsureMailFrameButton()
		local _, _, _, x2, y2 = b2:GetPoint(1)
		assert.equal(55, x2); assert.equal(-3, y2)
		_G.C_AddOns = isLoaded and { IsAddOnLoaded = isLoaded } or nil
		_G.MailFrame = nil
	end)

	it("says why a click could not take, and how far a mail's take-all got before it stopped", function()
		M:Open()
		M.List.parent:SetHeight(20 + 16 * 10); M.List:Refresh()
		wow.mail[1].cod = 500
		M:OnInboxUpdate()   -- MAIL_INBOX_UPDATE while open redraws from the live inbox
		M.List.rows[1]:Fire("OnClick", "LeftButton")
		M.List.rows[2]:Fire("OnClick", "LeftButton")
		assert.equal(0, #wow.mailActions, "a COD attachment was taken")
		assert.truthy(M.Window.statustext:GetText():find("cash-on-delivery", 1, true), "the refusal was not reported")
		-- Bob's mail: the item goes, then the bags fill up before the money -- reported as far as it got.
		TOGBankClassic_Bank.HasInventorySpace = function() return #wow.mailActions == 0 end
		wow.mail[2].items[2] = { name = "Wool Cloth", id = 2592, count = 3, texture = 132911, quality = 1 }
		M:OnInboxUpdate()
		_G.IsShiftKeyDown = function() return true end
		M.List.rows[4]:Fire("OnClick", "LeftButton")
		_G.IsShiftKeyDown = function() return false end
		require("env.wow").advanceTime(M.TAKE_DELAY)
		assert.equal(1, #wow.mailActions)
		assert.truthy(M.Window.statustext:GetText():find("Took 1, then stopped: bags are full", 1, true), M.Window.statustext:GetText())
	end)

	it("says the inbox is empty when it is", function()
		for k in pairs(wow.mail) do wow.mail[k] = nil end
		M:Open()
		assert.equal(0, #M.List.data)
		assert.equal("The inbox is empty.", M.Window.statustext:GetText())
	end)

	it("closes with the mailbox, forgetting which mails were expanded", function()
		M:Open()
		M.List.rows[1]:Fire("OnClick", "LeftButton")
		assert.is_true(M:IsExpanded(1))
		M:OnMailClosed()
		assert.is_false(M.isOpen)
		assert.is_false(M:IsExpanded(1), "an expanded mail stayed expanded across a close")
	end)
end)

describe("MAILUI-001: shipping", function()
	it("is listed in both TOCs after UI.lua and RowList.lua, and registered for a transparency slider", function()
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_BCC.toc" }) do
			local src = env.readFile(toc)
			local ui, mb = src:find("Modules/UI.lua", 1, true), src:find("Modules/UI/Mailbox.lua", 1, true)
			local rl = src:find("Modules/UI/RowList.lua", 1, true)
			assert.truthy(mb, toc .. " does not ship Modules/UI/Mailbox.lua")
			assert.is_true(ui < mb, toc .. ": Mailbox.lua must load after UI.lua")
			assert.is_true(rl ~= nil and rl < mb, toc .. ": Mailbox.lua is built on RowList.lua and must load after it")
		end
		env.reset()
		local UI = env.loadUI()
		local found = false
		for _, entry in ipairs(UI.ALPHA_WINDOWS) do
			if entry.key == "mailbox" and entry.module == "TOGBankClassic_UI_Mailbox" then found = true end
		end
		assert.is_true(found, "the Mailbox window has no transparency slider entry")
	end)
end)
