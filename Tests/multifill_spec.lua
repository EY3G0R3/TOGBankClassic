-- MULTIFILL-001: one requester's several orders on ONE mail. The operator, 2026-09-13: "can we make
-- it so if 1 person has 4 requests for a banker, we can fill all the requests in one mail?"
--
-- Two paths reach the send. The row's Fulfill icon (PrepareFulfillMail) used to refuse when the
-- mail already carried anything; now it appends to a mail the addon opened for the SAME requester,
-- from the first free slot. Fulfill Oldest (FulfillStep) used to send one order per mail; now the
-- oldest order's requester gets their other whole-stack orders on the same mail. Both credit every
-- order by ITS id when the send confirms, through the one pendingSend the send hook reads.
--
-- The cursor, the send-mail slots and SendMail's record are the HARNESS's (WoWAPITesting 1211a3a,
-- requested for this file): `C_Container.PickupContainerItem` puts a `wow.bags` stack on
-- `wow.cursor`, `ClickSendMailItemButton` lands it in `wow.sendMailItems`, `GetSendMailItem` reads
-- it back with the client's five returns, and `SendMail` records `items`. Since WoWAPITesting
-- be92d12 the slots stay full until `wow.completeMailSend()` (the server's MAIL_SEND_SUCCESS), so a
-- send in this file is confirmed through `confirmSend` below, not by the send click.
-- This file carried a private model of all four until 2026-09-13; it is gone, so the bags here are
-- filled in the harness shape (`env.harnessBag`) rather than this env's `setBag`.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")
local wow = env.wow

local Mail, Guild

local ME    = "Bankchar-Testrealm"
local ALICE = "Alice-Testrealm"
local BOB   = "Bob-Testrealm"
local LINEN, WOOL, SILK = 2589, 2592, 4306

local credited
local savedMailFrame
local function restoreMailFrame() _G.MailFrame = savedMailFrame end

--- The mails SendMail recorded, in order.
local function sends()
	local out = {}
	for _, a in ipairs(wow.mailActions) do if a.action == "send" then out[#out + 1] = a end end
	return out
end

local function load()
	env.reset(); env.stubOutput()
	-- Record precedes Mail in every TOC: the oldest-first searches key orders on Record.requestKey.
	-- Without it this file passed only after an earlier spec file had left Record loaded.
	env.loadModules({ "Modules/Constants.lua", "Modules/Item.lua", "Modules/Inventory/Record.lua",
		"Modules/Guild.lua", "Modules/Bank.lua", "Modules/Mail.lua" })
	Mail, Guild = TOGBankClassic_Mail, TOGBankClassic_Guild
	env.defineItem(LINEN, { name = "Linen Cloth" })
	env.defineItem(WOOL,  { name = "Wool Cloth" })
	env.defineItem(SILK,  { name = "Silk Cloth" })
	Guild.Info = { name = "Testguild", alts = {}, requests = {} }
	Guild.IsBank = function(_, n) return n == ME end
	Guild.GetPlayer = function() return ME end
	Guild.GetNormalizedPlayer = function() return ME end
	credited = {}
	-- RequestLog's crediting is its own spec's; here it records the call and moves the counter so
	-- a credited order is not picked again.
	Guild.FulfillRequest = function(_, bank, requester, item, qty, requestId)
		credited[#credited + 1] = { bank = bank, requester = requester, item = item, qty = qty, id = requestId }
		local req = requestId and Guild.Info.requests[requestId]
		if req then req.fulfilled = (req.fulfilled or 0) + qty end
		return qty
	end
	Guild.RefreshRequestsUI = function() end

	env.useHarnessBags()
	-- SPEC-ORDER-001: the harness's MailFrame is a Frame (env/frames.lua) and Mailbox.lua reads its
	-- level; this open-mailbox stand-in is a bare table, so it is handed back after each example
	-- (`restoreMailFrame` below) rather than left for mailbox_spec to trip on.
	savedMailFrame = _G.MailFrame
	_G.MailFrame = { IsShown = function() return true end }
	Mail.batchState, Mail.batchInFlight, Mail.pendingSend, Mail.pendingSendAt = nil, false, nil, nil
	env.harnessBag(0, 16, {})
end

local function order(id, requester, itemID, qty, date)
	local name = GetItemInfo(itemID)
	local req = { id = id, requester = requester, bank = ME, status = "open", item = name, itemID = itemID,
		quantity = qty, fulfilled = 0, date = date or 1000 }
	Guild.Info.requests[id] = req
	return req
end

local function attachedCount()
	local n = 0
	for i = 1, ATTACHMENTS_MAX_SEND do if GetSendMailItem(i) then n = n + 1 end end
	return n
end

--- MAIL_SEND_SUCCESS for the send SendMail made: the harness empties the slots and fires the event.
--- Nothing in this file registers the addon's handler for it, so the credit is applied by hand.
local function confirmSend()
	wow.completeMailSend()
	Mail:ApplyPendingSend()
end

--- The stack in send-mail slot `i`, as the harness holds it (`itemID`, `count`, `link`, `name`).
local function slot(i) return wow.sendMailItems[i] end

local function ids(list)
	local out = {}
	for _, c in ipairs(list) do out[#out + 1] = c.id or c.requestId end
	table.sort(out)
	return out
end

describe("MULTIFILL-001: the row's Fulfill icon stacks one requester's orders on one mail", function()
	before_each(load)
	after_each(restoreMailFrame)

	it("appends a second, third and fourth order for the same requester from the first free slot, and credits each by id on send", function()
		env.harnessBag(0, 16, { { id = LINEN, count = 20 }, { id = WOOL, count = 10 }, { id = SILK, count = 5 }, { id = LINEN, count = 20 } })
		local r1, r2, r3, r4 = order("r1", ALICE, LINEN, 20), order("r2", ALICE, WOOL, 10), order("r3", ALICE, SILK, 5), order("r4", ALICE, LINEN, 20)
		local ok, msg = Mail:PrepareFulfillMail(r1)
		assert.is_true(ok, msg)
		assert.equal(1, attachedCount())
		ok, msg = Mail:PrepareFulfillMail(r2)
		assert.is_true(ok, "the second order for the same requester was refused: " .. tostring(msg))
		assert.equal(2, attachedCount())
		assert.equal(WOOL, slot(2).itemID, "the second order did not go to the first free slot")
		assert.truthy(msg:find("2 orders on this mail", 1, true), msg)
		assert.is_true((Mail:PrepareFulfillMail(r3)))
		assert.is_true((Mail:PrepareFulfillMail(r4)))
		assert.equal(4, attachedCount())
		assert.equal(ALICE, SendMailNameEditBox:GetText())
		-- One pending send, four entries, each with its own id; the envelope carries the first.
		local p = Mail.pendingSend
		assert.equal(ALICE, p.recipient); assert.equal("r1", p.requestId)
		assert.same({ "r1", "r2", "r3", "r4" }, ids(p.items))
		-- The send hook keeps the addon's entries (MULTIORDER-001) and finds no hand-added extras.
		Mail:OnSendMail(ALICE)
		assert.is_nil(p.extraItems)
		-- MAIL_SEND_SUCCESS: every order credited against ITS id, with its own quantity.
		assert.is_not_nil(Mail.pendingSend, "precondition: the send is pending")
		Mail:ApplyPendingSend()
		assert.same({ "r1", "r2", "r3", "r4" }, ids(credited))
		for _, c in ipairs(credited) do
			assert.equal(ALICE, c.requester); assert.equal(ME, c.bank)
			assert.equal(Guild.Info.requests[c.id].item, c.item)
			assert.equal(Guild.Info.requests[c.id].quantity, c.qty)
		end
		assert.is_nil(Mail.pendingSend)
	end)

	it("still refuses another person's order onto an open mail, naming whose it is, and a hand-built mail", function()
		env.harnessBag(0, 16, { { id = LINEN, count = 20 }, { id = WOOL, count = 10 } })
		local r1, r2 = order("r1", ALICE, LINEN, 20), order("r2", BOB, WOOL, 10)
		assert.is_true((Mail:PrepareFulfillMail(r1)))
		local ok, msg = Mail:PrepareFulfillMail(r2)
		assert.is_false(ok)
		assert.truthy(msg:find("for " .. ALICE, 1, true), "the refusal does not say whose mail is open: " .. msg)
		assert.equal(1, attachedCount())
		assert.same({ "r1" }, ids(Mail.pendingSend.items), "the refused order leaked into the pending send")
		-- A mail the banker built by hand (no pending send) is nobody's to append to -- not even for
		-- the requester whose name is in the box.
		Mail.pendingSend = nil
		SendMailNameEditBox:SetText(BOB)
		ok, msg = Mail:PrepareFulfillMail(r2)
		assert.is_false(ok)
		assert.truthy(msg:find("already has items attached", 1, true), msg)
		assert.equal(1, attachedCount())
	end)

	-- SEND-RECIPIENT-001 (Peer Review f4c6a142, R1): the send hook kept any pending send under 10 s
	-- old without looking at who the mail went to. The banker retypes the name box after a row
	-- Fulfill (or a failed batch send leaves its pending send behind), mails Bob the same Linen, and
	-- Alice's order was credited for a mail she never got.
	it("credits nothing to the prepared requester when the mail goes to someone else", function()
		env.harnessBag(0, 16, { { id = LINEN, count = 20 } })
		local r1 = order("r1", ALICE, LINEN, 20)
		assert.is_true((Mail:PrepareFulfillMail(r1)))
		SendMailNameEditBox:SetText(BOB)
		Mail:OnSendMail(BOB)
		assert.is_not_nil(Mail.pendingSend, "the mail to Bob was not tracked at all")
		assert.equal(BOB, Mail.pendingSend.recipient, "the pending send still names Alice for a mail sent to Bob")
		assert.is_nil(Mail.pendingSend.requestId, "Alice's order id rode along on Bob's mail")
		Mail:ApplyPendingSend()
		for _, c in ipairs(credited) do
			assert.are_not.equal(ALICE, c.requester, "Alice was credited for a mail sent to Bob")
		end
		assert.equal(0, r1.fulfilled, "Alice's order was filled by a mail sent to Bob")
	end)

	it("keeps the prepared order when the same name is typed in another case", function()
		env.harnessBag(0, 16, { { id = LINEN, count = 20 } })
		local r1 = order("r1", ALICE, LINEN, 20)
		assert.is_true((Mail:PrepareFulfillMail(r1)))
		Mail:OnSendMail(ALICE:lower())
		assert.equal("r1", Mail.pendingSend.requestId, "a name in another case dropped the prepared order")
		Mail:ApplyPendingSend()
		assert.same({ "r1" }, ids(credited))
	end)

	-- Self-audit: slot 1 alone was the "is the mail loaded" test. A banker who detaches slot 1 by hand
	-- leaves slots 2+ loaded; reading that as empty would start a fresh pending send over orders
	-- still attached, and the mail would go with those credited to nobody.
	it("treats a mail with only slot 1 detached as still loaded: fills the gap and keeps the earlier orders", function()
		env.harnessBag(0, 16, { { id = LINEN, count = 20 }, { id = WOOL, count = 10 }, { id = SILK, count = 5 } })
		local r1, r2, r3 = order("r1", ALICE, LINEN, 20), order("r2", ALICE, WOOL, 10), order("r3", ALICE, SILK, 5)
		assert.is_true((Mail:PrepareFulfillMail(r1)))
		assert.is_true((Mail:PrepareFulfillMail(r2)))
		-- The banker right-clicks slot 1 (Linen) back to the bags; r1 is still in the pending send.
		ClickSendMailItemButton(1, true)
		assert.is_nil(slot(1)); assert.equal(LINEN, wow.bags[0][1].itemID, "the detached Linen did not return to the bags")
		local ok, msg = Mail:PrepareFulfillMail(r3)
		assert.is_true(ok, msg)
		assert.equal(SILK, slot(1).itemID, "the gap at slot 1 was not used")
		assert.equal(WOOL, slot(2).itemID)
		assert.same({ "r1", "r2", "r3" }, ids(Mail.pendingSend.items), "the earlier orders were dropped from the pending send")
		-- At send time the hook cuts each entry to what is really attached: r1's Linen went back to
		-- the bags, so r1 is NOT credited; a stack the banker added by hand is spilled as before.
		wow.bags[0][5] = { itemID = WOOL, count = 3, name = "Wool Cloth" }
		C_Container.PickupContainerItem(0, 5)
		ClickSendMailItemButton(3)
		assert.is_nil(wow.cursor)
		Mail:OnSendMail(ALICE)
		assert.same({ "r2", "r3" }, ids(Mail.pendingSend.items), "a detached order stayed in the pending send")
		assert.equal(1, #Mail.pendingSend.extraItems)
		assert.equal("Wool Cloth", Mail.pendingSend.extraItems[1].name); assert.equal(3, Mail.pendingSend.extraItems[1].quantity)
		Mail:ApplyPendingSend()
		assert.same({ "r2", "r3" }, ids(credited))
		assert.equal(0, Guild.Info.requests.r1.fulfilled, "r1 was credited for Linen that never went")
	end)

	-- LOCALE-SENDTRIM-001 (Peer Review 4d7fc1c4): the send hook cut each entry to what is attached
	-- under ITS NAME, and the slot's name is the banker's locale while the entry's is the requester's.
	-- A German requester's order on an English banker's mail matched nothing and was never credited.
	it("credits an order whose stored name is in another locale, matching the attachment by item id", function()
		env.harnessBag(0, 16, { { id = LINEN, count = 20 }, { id = WOOL, count = 10 }, { id = WOOL, count = 3 } })
		local r1 = order("r1", ALICE, LINEN, 20)
		r1.item = "Leinenstoff"   -- the requester's client named it
		-- A pre-REQ-001 order carries no id; it was found in the bags by name, so it still matches by name.
		local r2 = order("r2", ALICE, WOOL, 10)
		r2.itemID = nil
		assert.is_true((Mail:PrepareFulfillMail(r1)))
		assert.is_true((Mail:PrepareFulfillMail(r2)))
		assert.equal("Linen Cloth", (GetSendMailItem(1)), "precondition: the slot reads in the banker's locale")
		-- And a stack the banker added by hand still spills.
		C_Container.PickupContainerItem(0, 3)
		ClickSendMailItemButton(3)
		Mail:OnSendMail(ALICE)
		assert.same({ "r1", "r2" }, ids(Mail.pendingSend.items), "an order was cut from the send by its name")
		assert.equal(20, Mail.pendingSend.items[1].quantity)
		assert.equal(10, Mail.pendingSend.items[2].quantity, "the by-name order took the hand-added stack too")
		assert.equal(1, #Mail.pendingSend.extraItems)
		assert.equal("Wool Cloth", Mail.pendingSend.extraItems[1].name); assert.equal(3, Mail.pendingSend.extraItems[1].quantity)
		Mail:ApplyPendingSend()
		assert.same({ "r1", "r2" }, ids(credited))
		assert.equal(20, Guild.Info.requests.r1.fulfilled)
	end)

	-- LOCALE-SENDTRIM-001 self-audit: random-suffix siblings share one base id. With the Bear variant
	-- detached by hand, an id-only match handed the Bear order the Monkey's slot and credited the wrong one.
	it("credits the variant still attached, not its detached sibling with the same base id", function()
		local BRACERS = 9999
		Mail.pendingSend = { sender = ME, recipient = ALICE, requestId = "bear", items = {
			{ name = "Bracers of the Bear", itemID = BRACERS, quantity = 1, requestId = "bear" },
			{ name = "Bracers of the Monkey", itemID = BRACERS, quantity = 1, requestId = "monkey" },
		} }
		Mail.pendingSendAt = GetTime()
		wow.sendMailItems[1] = { itemID = BRACERS, count = 1, name = "Bracers of the Monkey" }
		Mail:OnSendMail(ALICE)
		assert.same({ "monkey" }, ids(Mail.pendingSend.items), "the detached variant's order took its sibling's slot")
		assert.equal(1, Mail.pendingSend.items[1].quantity)
		assert.same({}, (function() local o = {} for k in pairs(Mail.pendingSend) do if k == "extraItems" then o[#o + 1] = k end end return o end)(),
			"the attached variant was left over as a hand-added extra")
	end)

	it("says the mail is full at twelve attachments rather than attaching over the top", function()
		local contents = {}
		for _ = 1, 13 do contents[#contents + 1] = { id = LINEN, count = 1 } end
		env.harnessBag(0, 16, contents)
		for i = 1, ATTACHMENTS_MAX_SEND do wow.sendMailItems[i] = { itemID = LINEN, count = 1, name = "Linen Cloth" } end
		Mail.pendingSend = { sender = ME, recipient = ALICE, requestId = "r0", items = {} }
		local ok, msg = Mail:PrepareFulfillMail(order("r1", ALICE, LINEN, 1))
		assert.is_false(ok)
		assert.truthy(msg:find("full", 1, true), msg)
		assert.equal(12, attachedCount())
	end)
end)

describe("MULTIFILL-001: Fulfill Oldest sends one mail per person", function()
	before_each(load)
	after_each(restoreMailFrame)

	local function click() return Mail:FulfillStep(ME) end

	it("attaches the oldest order and the same requester's other whole-stack orders, oldest first, then sends once and credits each", function()
		env.harnessBag(0, 16, { { id = LINEN, count = 20 }, { id = WOOL, count = 10 }, { id = SILK, count = 5 }, { id = LINEN, count = 20 }, { id = SILK, count = 5 } })
		order("r1", ALICE, LINEN, 20, 1000)
		order("r2", ALICE, WOOL, 10, 1001)
		order("r3", ALICE, LINEN, 20, 1002)   -- the same item as r1: must plan the OTHER stack
		order("r4", ALICE, SILK, 6, 1003)     -- 6 Silk: only 5 left after Bob's -- not fillable at all
		order("r5", BOB, SILK, 5, 999)        -- older, but Bob's -- a different mail
		local ok, msg = click()
		assert.is_true(ok, msg)
		-- Bob's is oldest overall, so Bob's mail goes first: one order, no extras.
		assert.equal("r5", Mail.batchState.req.id)
		assert.equal(0, #Mail.batchState.extras)
		assert.is_true((click()))   -- attach
		assert.is_true((click()))   -- send
		assert.equal(1, #sends()); assert.equal(BOB, sends()[1].target)
		assert.equal(1, #sends()[1].items, "Bob's mail did not carry exactly his one stack")
		confirmSend()
		assert.equal(0, attachedCount(), "the confirmed send did not empty the slots")
		assert.same({ "r5" }, ids(credited))
		credited = {}
		Mail.batchInFlight = false
		-- Alice's: r1 with r2 and r3 as extras; r4 needs a split and stays.
		ok, msg = click()
		assert.is_true(ok, msg)
		assert.equal("r1", Mail.batchState.req.id)
		assert.same({ "r2", "r3" }, (function() local o = {} for _, e in ipairs(Mail.batchState.extras) do o[#o + 1] = e.req.id end return o end)())
		assert.truthy(msg:find("+2 more of their orders", 1, true), msg)
		ok, msg = click()   -- attach
		assert.is_true(ok, msg)
		assert.equal(3, attachedCount(), "the extras were not attached")
		assert.equal(LINEN, slot(1).itemID); assert.equal(WOOL, slot(2).itemID); assert.equal(LINEN, slot(3).itemID)
		assert.equal(20, slot(3).count, "r3 did not get the second whole Linen stack")
		ok, msg = click()   -- send
		assert.is_true(ok, msg)
		assert.truthy(msg:find("Sent 3 orders", 1, true), msg)
		assert.equal(2, #sends(), "Alice's three orders went as more than one mail"); assert.equal(ALICE, sends()[2].target)
		assert.equal(3, #sends()[2].items, "Alice's mail did not go with all three stacks")
		assert.same({ "r1", "r2", "r3" }, ids(Mail.pendingSend.items))
		-- LOCALE-SENDTRIM-001: every entry carries its order's item id, which the send hook trims by.
		assert.equal(LINEN, Mail.pendingSend.items[1].itemID); assert.equal(WOOL, Mail.pendingSend.items[2].itemID)
		assert.equal(LINEN, Mail.pendingSend.items[3].itemID)
		confirmSend()
		assert.same({ "r1", "r2", "r3" }, ids(credited))
		-- r4 (6 Silk, 5 in the bags) was never planned, attached or credited; the stack is whole.
		assert.equal(0, Guild.Info.requests.r4.fulfilled)
		local silkLeft = 0
		for s = 1, 16 do local it = wow.bags[0][s]; if it and it.itemID == SILK then silkLeft = silkLeft + it.count end end
		assert.equal(5, silkLeft, "the Silk stack was touched")
	end)

	-- BATCH-TIMER-001 (Peer Review 030b8a0a, N1): each send's 5 s safety timer cleared the flag
	-- unconditionally, so send A's timer could free a third click while a later send B was unconfirmed.
	it("lets only the latest send's safety timer free the next click", function()
		env.harnessBag(0, 16, { { id = LINEN, count = 20 }, { id = WOOL, count = 10 } })
		order("a", BOB, LINEN, 20, 1000)
		order("b", ALICE, WOOL, 10, 1001)
		click(); click(); click()        -- plan, attach, send A at t=0
		assert.equal(1, #sends())
		env.advance(1)
		confirmSend()                    -- A confirms at t=1
		assert.is_false(Mail.batchInFlight)
		env.advance(1)
		click(); click(); click()        -- send B at t=2
		assert.equal(2, #sends())
		assert.is_true(Mail.batchInFlight)
		env.advance(3)                   -- t=5: A's timer is due, B is still unconfirmed
		assert.is_true(Mail.batchInFlight, "the earlier send's timer freed the click while a later send was pending")
		local ok, msg = click()
		assert.is_false(ok, "a click went through while send B was unconfirmed")
		assert.truthy(msg:find("Waiting for the last order", 1, true), "refused for another reason: " .. tostring(msg))
		env.advance(2)                   -- t=7: B's own timer frees it
		assert.is_false(Mail.batchInFlight, "the latest send's own safety timer did not free the click")
	end)

	-- MAIL-SLOTCAP-001 (Peer Review bf89d59d B1): an order whose stacks need more than one mail's
	-- twelve slots was attached up to slot 12 and credited in full, so one Linen never left the bags
	-- and the order read filled.
	it("mails an order that needs more than twelve stacks in parts, crediting each mail only what it carried", function()
		local contents = {}
		for _ = 1, 13 do contents[#contents + 1] = { id = LINEN, count = 1 } end
		env.harnessBag(0, 16, contents)
		order("big", ALICE, LINEN, 13, 1000)
		local ok, msg = click()
		assert.is_true(ok, msg)
		assert.equal(12, Mail.batchState.qty, "the first mail was planned for more than twelve stacks hold")
		assert.truthy(msg:find("12 of 13x", 1, true), msg)
		assert.truthy(msg:find("the rest goes next", 1, true), msg)
		assert.is_true((click()))   -- attach
		assert.equal(12, attachedCount())
		-- The in-game send hook cuts each entry to what is attached; a capped entry must survive it whole.
		-- Driven here with the slots full; the real hook through the send click, with the slots full or
		-- already emptied, is SEND-SNAPSHOT-001's describe below.
		local function pendingQty()
			local n = 0
			for _, it in ipairs(Mail.pendingSend.items) do n = n + it.quantity end
			return n
		end
		Mail:OnSendMail(ALICE)
		assert.equal(12, pendingQty(), "the send hook cut the capped mail's entries")
		ok, msg = click()           -- send
		assert.is_true(ok, msg)
		assert.equal(12, #sends()[1].items)
		confirmSend()
		assert.equal(1, #credited)
		assert.equal(12, credited[1].qty, "the order was credited for stacks that never went in the mail")
		assert.equal(12, Guild.Info.requests.big.fulfilled)
		-- The order is still the oldest; the next mail carries the last one.
		Mail.batchInFlight = false
		ok, msg = click()
		assert.is_true(ok, msg)
		assert.equal("big", Mail.batchState.req.id)
		assert.equal(1, Mail.batchState.qty)
		assert.truthy(msg:find("Order: 1x", 1, true), msg)
		assert.is_true((click()))   -- attach
		Mail:OnSendMail(ALICE)
		assert.equal(1, pendingQty())
		assert.is_true((click()))   -- send
		confirmSend()
		assert.equal(13, Guild.Info.requests.big.fulfilled)
		assert.equal(2, #sends())
	end)

	-- SEND-SNAPSHOT-001 (Peer Review 024ada6d): the send hook is a hooksecurefunc POST-hook on SendMail,
	-- and when the client empties the send slots is not shown by its UI source. Whichever it is, the
	-- capped mail must credit the 12 it carried. These go through the REAL hook and the real send click,
	-- and the record is kept through the REAL event registration (Events:RegisterEvents), so a broken
	-- line in that wiring fails here rather than only in a client (Peer Review 1aa094de F2).
	describe("the send hook credits what went, whenever the client empties the slots", function()
		local handlers

		-- env.reset does not touch TOGBankClassic_Core or the addon's UI globals, so whatever wireEvents
		-- writes outlives this file unless it is put back (Peer Review 104ff6f7 F3): a later file that
		-- merges into Core and calls RegisterEvents would register into this file's dead `handlers`.
		local CORE_FIELDS = { "RegisterEvent", "UnregisterEvent", "RegisterMessage", "SendMessage", "ScheduleTimer", "CancelTimer" }
		local GLOBALS = { "TOGBankClassic_Core", "TOGBankClassic_Events", "TOGBankClassic_UI", "TOGBankClassic_UI_Requests", "TOGBankClassic_UI_Mail" }
		local saved   -- nil until wireEvents runs; { globals = {name -> value}, core = {field -> value} }

		after_each(function()
			if not saved then return end
			for _, name in ipairs(GLOBALS) do _G[name] = saved.globals[name] end
			if saved.globals.TOGBankClassic_Core then
				for _, f in ipairs(CORE_FIELDS) do saved.globals.TOGBankClassic_Core[f] = saved.core[f] end
			end
			for _, name in ipairs(GLOBALS) do
				assert.equal(saved.globals[name], _G[name], name .. " was not put back")
			end
			for _, f in ipairs(CORE_FIELDS) do
				assert.equal(saved.core[f], TOGBankClassic_Core and TOGBankClassic_Core[f], "TOGBankClassic_Core." .. f .. " was not put back")
			end
			saved = nil
		end)

		--- Register the addon's events with the handlers captured, as CallbackHandler would hold them.
		local function wireEvents()
			saved = { globals = {}, core = {} }
			for _, name in ipairs(GLOBALS) do saved.globals[name] = _G[name] end
			for _, f in ipairs(CORE_FIELDS) do saved.core[f] = TOGBankClassic_Core and TOGBankClassic_Core[f] end
			handlers = {}
			TOGBankClassic_Core = TOGBankClassic_Core or {}
			TOGBankClassic_Core.RegisterEvent   = function(_, event, fn) handlers[event] = fn end
			TOGBankClassic_Core.UnregisterEvent = function(_, event) handlers[event] = nil end
			TOGBankClassic_Core.RegisterMessage = function() end
			TOGBankClassic_Core.SendMessage     = function() end
			TOGBankClassic_Core.ScheduleTimer   = function() return {} end
			TOGBankClassic_Core.CancelTimer     = function() end
			env.loadFile("Modules/Events.lua")
			-- Neither the open-mailbox stand-in nor this env's Send Mail tab has HookScript; those hooks
			-- are events_spec's.
			_G.MailFrame.togBankHooked = true
			if _G.MailFrameTab2 then _G.MailFrameTab2.togBankHooked = true end
			TOGBankClassic_UI = TOGBankClassic_UI or { OnInsertLink = function() end }
			TOGBankClassic_UI_Requests = TOGBankClassic_UI_Requests or { isOpen = false }
			TOGBankClassic_UI_Mail = TOGBankClassic_UI_Mail or { Close = function() end }
			TOGBankClassic_Events:RegisterEvents()
		end

		--- Fire an event exactly as CallbackHandler does: the handler receives (eventName, ...).
		local function fire(event, ...)
			local fn = handlers[event]
			assert.is_function(fn, "nothing is registered for " .. event)
			return fn(event, ...)
		end

		local function loadTwelve()
			wireEvents()
			local contents = {}
			for _ = 1, 13 do contents[#contents + 1] = { id = LINEN, count = 1 } end
			env.harnessBag(0, 16, contents)
			order("big", ALICE, LINEN, 13, 1000)
			assert.is_true((click()))   -- plan
			assert.is_true((click()))   -- attach
			assert.equal(12, attachedCount())
			-- The client repaints the send slots as the stacks land. The harness fires this event from
			-- ClickSendMailItemButton too (be92d12), but into its own event system; the handlers here are
			-- the ones wireEvents captured, so every fire in this describe is by hand.
			fire("MAIL_SEND_INFO_UPDATE")
		end

		-- The harness keeps the slots full through SendMail (WoWAPITesting be92d12), so the empty case
		-- is this file's own SendMail, which empties them inside the call as the harness used to.
		it("when the slots are already empty in the hook", function()
			_G.SendMail = function(target, subject, body)
				wow.mailActions[#wow.mailActions + 1] = { action = "send", target = target, subject = subject, body = body, items = {} }
				for i = 1, ATTACHMENTS_MAX_SEND do wow.sendMailItems[i] = nil end
			end
			loadTwelve()
			Mail:InitSendHook()
			assert.is_true((click()))   -- send: SendMail empties the slots, then the hook runs
			assert.equal(0, attachedCount(), "precondition: the slots were empty when the hook ran")
			Mail:ApplyPendingSend()
			assert.equal(1, #credited)
			assert.equal(12, credited[1].qty, "the send hook read the emptied slots and credited nothing")
		end)

		it("when the slots still hold the attachments in the hook (the harness's SendMail)", function()
			loadTwelve()
			Mail:InitSendHook()
			assert.is_true((click()))   -- send: the hook runs with the slots still full
			assert.equal(12, #sends()[1].items, "precondition: the harness's SendMail did not record the twelve")
			assert.equal(12, attachedCount(), "precondition: the slots were full when the hook ran")
			confirmSend()
			assert.equal(0, attachedCount())
			assert.equal(1, #credited)
			assert.equal(12, credited[1].qty)
		end)

		it("does not credit stacks the banker took off the mail before sending it", function()
			wireEvents()
			env.harnessBag(0, 16, { { id = LINEN, count = 20 } })
			assert.is_true((Mail:PrepareFulfillMail(order("r1", ALICE, LINEN, 20))))
			fire("MAIL_SEND_INFO_UPDATE")
			ClickSendMailItemButton(1, true)   -- the banker detaches it by hand
			fire("MAIL_SEND_INFO_UPDATE")
			wow.time = wow.time + 1            -- and sends in a later frame
			Mail:InitSendHook()
			SendMail(ALICE, "", "")
			Mail:ApplyPendingSend()
			assert.equal(0, #credited, "the record of an attachment the banker removed was credited")
		end)

		it("forgets the record when the mailbox closes between attaching and sending", function()
			wireEvents()
			env.harnessBag(0, 16, { { id = LINEN, count = 20 } })
			assert.is_true((Mail:PrepareFulfillMail(order("r1", ALICE, LINEN, 20))))
			fire("MAIL_SEND_INFO_UPDATE")
			assert.is_not_nil(Mail.sendSlots, "precondition: the attachment was recorded")
			ClickSendMailItemButton(1, true)
			fire("MAIL_SEND_INFO_UPDATE")
			assert.is_number(Mail.sendSlotsEmptiedAt, "precondition: the empty update was stamped")
			fire("MAIL_CLOSED")
			assert.is_nil(Mail.sendSlots, "the record outlived the mailbox")
			assert.is_nil(Mail.sendSlotsEmptiedAt)
		end)
	end)

	-- MULTIFILL-002 (the operator, 2026-09-13, a screenshot of four 1x Elemental orders for one
	-- person sent as FOUR mails): "it should do all the splitting first for ONE recipient, create the
	-- mail, attach everything to one mail, then send it". MULTIFILL-001 left a split order for its own
	-- mail, so four orders that each needed a split were four mails.
	describe("MULTIFILL-002: orders that need a split ride on the same mail", function()
		local AIR, WATER, FIRE, EARTH = 7082, 7080, 7078, 7076

		local function elementals()
			env.defineItem(AIR,   { name = "Essence of Air" })
			env.defineItem(WATER, { name = "Essence of Water" })
			env.defineItem(FIRE,  { name = "Essence of Fire" })
			env.defineItem(EARTH, { name = "Essence of Earth" })
		end

		local function stacksOf(itemID)
			local out = {}
			for s = 1, 16 do local it = wow.bags[0][s]; if it and it.itemID == itemID then out[#out + 1] = it.count end end
			table.sort(out)
			return out
		end

		it("splits every order's stack from ONE click, into distinct free slots, then attaches all four and sends one mail", function()
			elementals()
			env.harnessBag(0, 16, { { id = AIR, count = 5 }, { id = WATER, count = 5 }, { id = FIRE, count = 5 }, { id = EARTH, count = 5 } })
			order("e1", ALICE, AIR, 1, 1000)
			order("e2", ALICE, WATER, 1, 1001)
			order("e3", ALICE, FIRE, 1, 1002)
			order("e4", ALICE, EARTH, 1, 1003)
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.equal("e1", Mail.batchState.req.id)
			assert.equal(3, #Mail.batchState.extras, "the three split orders were not planned as extras")
			assert.equal(4, #Mail.batchState.splits, "four splits were not queued")
			assert.equal("split", Mail.batchState.phase)
			assert.truthy(msg:find("+3 more of their orders", 1, true), msg)
			-- ONE click splits all four. The first runs now; the rest are chained on the clock so each
			-- deferred pickup has cleared the cursor before the next split loads it.
			ok, msg = click()
			assert.is_true(ok, msg)
			assert.truthy(msg:find("Splitting 4 stacks (4 items)", 1, true), msg)
			assert.equal("attach", Mail.batchState.phase)
			assert.is_not_nil(wow.cursor, "the first split did not load the cursor")
			-- Too fast: not every split has landed, so ATTACH waits rather than attaching a gap.
			ok, msg = click()
			assert.is_false(ok); assert.truthy(msg:find("Still placing", 1, true), msg)
			env.advance(0.1)   -- first pickup
			ok = click()
			assert.is_false(ok, "attached with three splits still in flight")
			env.advance(1)     -- every chained split and pickup
			assert.is_nil(wow.cursor, "a split was left on the cursor")
			-- Four split stacks in four DISTINCT slots (5..8), each source down to 4.
			local landed = {}
			for _, s in ipairs(Mail.batchState.splits) do
				assert.is_nil(landed[s.bag .. ":" .. s.slot], "two splits were placed into the same slot")
				landed[s.bag .. ":" .. s.slot] = true
				assert.equal(1, wow.bags[s.bag][s.slot].count)
			end
			for _, id in ipairs({ AIR, WATER, FIRE, EARTH }) do assert.same({ 1, 4 }, stacksOf(id)) end
			-- ONE click attaches all four split stacks.
			ok, msg = click()
			assert.is_true(ok, msg)
			assert.equal(4, attachedCount(), "the four split stacks were not all attached")
			assert.equal(AIR, slot(1).itemID); assert.equal(WATER, slot(2).itemID); assert.equal(FIRE, slot(3).itemID); assert.equal(EARTH, slot(4).itemID)
			for i = 1, 4 do assert.equal(1, slot(i).count) end
			assert.truthy(msg:find("and 3 more of their orders", 1, true), msg)
			-- ONE mail, crediting each order by its id.
			ok, msg = click()
			assert.is_true(ok, msg)
			assert.truthy(msg:find("Sent 4 orders", 1, true), msg)
			assert.equal(1, #sends(), "four split orders went as more than one mail"); assert.equal(ALICE, sends()[1].target)
			assert.equal(4, #sends()[1].items)
			assert.same({ "e1", "e2", "e3", "e4" }, ids(Mail.pendingSend.items))
			confirmSend()
			assert.same({ "e1", "e2", "e3", "e4" }, ids(credited))
			for _, id in ipairs({ AIR, WATER, FIRE, EARTH }) do assert.same({ 4 }, stacksOf(id), "a source stack was not left at 4") end
		end)

		it("mixes whole stacks and splits on one mail: the first order whole, an extra split, an extra whole", function()
			elementals()
			env.harnessBag(0, 16, { { id = LINEN, count = 20 }, { id = AIR, count = 5 }, { id = WOOL, count = 10 } })
			order("m1", ALICE, LINEN, 20, 1000)   -- whole
			order("m2", ALICE, AIR, 2, 1001)      -- 2 of 5: a split
			order("m3", ALICE, WOOL, 10, 1002)    -- whole
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.is_nil(Mail.batchState.plan.splitStack, "precondition: the first order is whole")
			assert.equal(2, #Mail.batchState.extras)
			assert.equal(1, #Mail.batchState.splits)
			assert.equal("split", Mail.batchState.phase, "an extra's split did not route the batch through SPLIT")
			assert.truthy(msg:find("Click to SPLIT", 1, true), msg)
			ok, msg = click()
			assert.is_true(ok, msg)
			assert.truthy(msg:find("Split 2 Essence of Air", 1, true), msg)
			env.advance(0.1)
			assert.is_true((click()))   -- attach
			assert.equal(3, attachedCount())
			assert.equal(LINEN, slot(1).itemID); assert.equal(20, slot(1).count)
			assert.equal(AIR, slot(2).itemID);   assert.equal(2, slot(2).count, "the extra's split stack was not the one attached")
			assert.equal(WOOL, slot(3).itemID);  assert.equal(10, slot(3).count)
			assert.same({ 3 }, stacksOf(AIR), "the Air source was not left at 3")
			assert.is_true((click()))   -- send
			assert.equal(1, #sends()); assert.equal(3, #sends()[1].items)
			confirmSend()
			assert.same({ "m1", "m2", "m3" }, ids(credited))
		end)

		-- SPLIT-ROOM-001 (Discord, 2026-10-24: three orders each needing a split, two free bag slots,
		-- "none of the stacks will attempt to split"): this used to refuse the whole mail.
		it("splits what the free slots hold, holds the extra order that does not fit for the next mail, and says so", function()
			elementals()
			-- A 16-slot bag with 14 stacks: two free slots, three splits wanted.
			local contents = { { id = AIR, count = 5 }, { id = WATER, count = 5 }, { id = FIRE, count = 5 } }
			for _ = 1, 11 do contents[#contents + 1] = { id = LINEN, count = 20 } end
			env.harnessBag(0, 16, contents)
			order("e1", ALICE, AIR, 1, 1000); order("e2", ALICE, WATER, 1, 1001); order("e3", ALICE, FIRE, 1, 1002)
			assert.is_true((click()))
			assert.equal(3, #Mail.batchState.splits)
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.truthy(msg:find("Splitting 2 stacks (2 items)", 1, true), msg)
			assert.truthy(msg:find("1 of their orders held for the next mail", 1, true), msg)
			-- The in-game check's "chat warning shows": the same news goes to chat, not only the status bar.
			local warned
			for _, c in ipairs(TOGBankClassic_Output.calls) do
				if c.level == "Warn" and c[1] == "Not enough free bag slots to split all of %s's orders: %d held for the next mail." then
					warned = c
				end
			end
			assert.is_table(warned, "the held-back order was not reported in chat")
			assert.equal(ALICE, warned[2]); assert.equal(1, warned[3])
			assert.equal(2, #Mail.batchState.splits)
			assert.equal(1, #Mail.batchState.extras, "the order with no slot was not taken off this mail")
			assert.equal("e2", Mail.batchState.extras[1].req.id, "the newer order was not the one held back")
			env.advance(1)
			assert.same({ 5 }, stacksOf(FIRE), "the held-back order's stack was split anyway")
			ok, msg = click()   -- attach
			assert.is_true(ok, msg)
			assert.equal(2, attachedCount())
			assert.equal(AIR, slot(1).itemID); assert.equal(WATER, slot(2).itemID)
			assert.is_true((click()))   -- send
			assert.equal(1, #sends()); assert.equal(2, #sends()[1].items)
			confirmSend()
			assert.same({ "e1", "e2" }, ids(credited))
			assert.equal("open", Guild.Info.requests.e3.status, "the held-back order was closed")
			-- The held-back order goes on the next mail, into the slots the first mail freed.
			assert.is_true((click()))
			assert.equal("e3", Mail.batchState.req.id)
			assert.is_true((click()))   -- split
			env.advance(1)
			assert.is_true((click()))   -- attach
			assert.equal(FIRE, slot(1).itemID); assert.equal(1, slot(1).count)
			assert.is_true((click()))   -- send
			confirmSend()
			assert.same({ "e1", "e2", "e3" }, ids(credited))
		end)

		it("refuses, touching nothing, when the oldest order's own split has no free slot", function()
			elementals()
			local contents = {}
			for _ = 1, 16 do contents[#contents + 1] = { id = LINEN, count = 20 } end
			contents[1] = { id = AIR, count = 5 }
			env.harnessBag(0, 16, contents)
			order("one", ALICE, AIR, 1, 1000)
			assert.is_true((click()))
			local ok, msg = click()
			assert.is_false(ok)
			assert.truthy(msg:find("Need a free bag slot", 1, true), msg)
			assert.equal("split", Mail.batchState.phase, "the batch moved on despite refusing")
			assert.is_nil(wow.cursor); assert.equal(0, env.pendingTimerCount(), "a split was scheduled despite refusing")
			assert.same({ 5 }, stacksOf(AIR), "the stack was split despite refusing")
			-- Make room and the same click goes through.
			wow.bags[0][16] = nil
			ok, msg = click()
			assert.is_true(ok, msg)
			assert.truthy(msg:find("Split 1 Essence of Air into your bags. Click to ATTACH.", 1, true), msg)
		end)

		it("goes straight to ATTACH when the first order is whole and no extra's split has a slot", function()
			elementals()
			-- Full bags: a whole Linen order first, then an Air order that needs a split.
			local contents = {}
			for _ = 1, 16 do contents[#contents + 1] = { id = WOOL, count = 10 } end
			contents[1] = { id = LINEN, count = 20 }
			contents[2] = { id = AIR, count = 5 }
			env.harnessBag(0, 16, contents)
			order("w1", ALICE, LINEN, 20, 1000)
			order("w2", ALICE, AIR, 2, 1001)
			assert.is_true((click()))
			assert.equal(1, #Mail.batchState.splits, "precondition: the extra's split was planned")
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.truthy(msg:find("Nothing left to split. 1 of their orders held for the next mail", 1, true), msg)
			assert.equal("attach", Mail.batchState.phase)
			assert.equal(0, #Mail.batchState.extras)
			assert.equal(0, env.pendingTimerCount(), "a split was scheduled with no slot for it")
			assert.is_true((click()))   -- attach
			assert.equal(1, attachedCount())
			assert.equal(LINEN, slot(1).itemID)
		end)

		it("leaves the second of two orders splitting from ONE stack for the next mail, and still fills it there", function()
			elementals()
			env.harnessBag(0, 16, { { id = AIR, count = 5 } })
			order("a1", ALICE, AIR, 1, 1000)
			order("a2", ALICE, AIR, 2, 1001)   -- the same 5-stack is a1's split source: claimed
			assert.is_true((click()))
			assert.equal("a1", Mail.batchState.req.id)
			assert.equal(0, #Mail.batchState.extras, "a2 was planned to split the stack a1 is splitting")
			assert.equal(1, #Mail.batchState.splits)
			assert.is_true((click()))   -- split
			env.advance(0.1)
			assert.is_true((click()))   -- attach
			assert.is_true((click()))   -- send
			assert.equal(1, #sends()); assert.equal(1, #sends()[1].items)
			confirmSend()
			assert.same({ "a1" }, ids(credited))
			-- The next mail: a2 splits 2 from the 4 left.
			assert.is_true((click()))
			assert.equal("a2", Mail.batchState.req.id)
			assert.is_true((click())); env.advance(0.1); assert.is_true((click())); assert.is_true((click()))
			assert.equal(2, #sends()); assert.equal(2, sends()[2].items[1].count)
			assert.same({ 2 }, stacksOf(AIR))
		end)
	end)

	-- MAIL-SPLIT-MERGE-001 (the operator, 2026-09-16): "say i need 8 of an item and i have 5. the
	-- splitter will split off another 3 and then send the stacks of 3 and 5 as 2 attachments to the
	-- mail. this costs an extra 30c. it would be nice if the one click tool stacked the 3 and the 5 to
	-- make 8, so it went out as one attachment."
	describe("MAIL-SPLIT-MERGE-001: a split that fits drops onto the order's own stack", function()
		local function stacksOf(itemID)
			local out = {}
			for s = 1, 16 do local it = wow.bags[0][s]; if it and it.itemID == itemID then out[#out + 1] = it.count end end
			table.sort(out)
			return out
		end

		it("sends 8 from a 5 and a 10 as ONE attachment of 8", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
			env.harnessBag(0, 16, { { id = LINEN, count = 5 }, { id = LINEN, count = 10 } })
			order("r1", ALICE, LINEN, 8, 1000)
			local ok, msg = click()
			assert.is_true(ok, msg)
			local plan = Mail.batchState.plan
			assert.equal(1, #plan.stacksToAttach); assert.equal(5, plan.stacksToAttach[1].count)
			assert.equal(3, plan.splitStack.amount)
			assert.is_table(plan.splitStack.onto, "the split was not planned onto the 5")
			ok, msg = click()   -- split
			assert.is_true(ok, msg)
			assert.truthy(msg:find("onto your stack of 5", 1, true), msg)
			-- Too fast: the 5 still reads 5, so ATTACH waits rather than attaching it short.
			ok, msg = click()
			assert.is_false(ok); assert.truthy(msg:find("Still placing", 1, true), msg)
			env.advance(0.1)
			assert.is_nil(wow.cursor, "the split was left on the cursor")
			assert.same({ 7, 8 }, stacksOf(LINEN), "the 3 did not stack onto the 5")
			-- The count reads 8 but the server has not released the slot yet: picking it up would do
			-- nothing, so ATTACH still waits.
			wow.bags[0][1].isLocked = true
			ok, msg = click()
			assert.is_false(ok); assert.truthy(msg:find("Still placing", 1, true), msg)
			wow.bags[0][1].isLocked = nil
			ok, msg = click()   -- attach
			assert.is_true(ok, msg)
			assert.equal(1, attachedCount(), "the order went as more than one attachment")
			assert.equal(8, slot(1).count)
			assert.is_true((click()))   -- send
			assert.equal(1, #sends()); assert.equal(1, #sends()[1].items); assert.equal(8, sends()[1].items[1].count)
			confirmSend()
			assert.same({ "r1" }, ids(credited))
			assert.same({ 7 }, stacksOf(LINEN))
		end)

		it("splits into a free slot as before when the item's max stack has no room for the merge", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 6 })
			env.harnessBag(0, 16, { { id = LINEN, count = 5 }, { id = LINEN, count = 6 } })
			order("r1", ALICE, LINEN, 8, 1000)
			assert.is_true((click()))
			assert.is_nil(Mail.batchState.plan.splitStack.onto, "planned a merge past the max stack of 6")
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.truthy(msg:find("into your bags", 1, true), msg)
			env.advance(0.1)
			assert.is_true((click()))
			assert.equal(2, attachedCount())
		end)

		it("needs no free bag slot when the split merges", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
			local contents = { { id = LINEN, count = 5 }, { id = LINEN, count = 10 } }
			for _ = 3, 16 do contents[#contents + 1] = { id = WOOL, count = 1 } end
			env.harnessBag(0, 16, contents)
			order("r1", ALICE, LINEN, 8, 1000)
			assert.is_true((click()))
			assert.is_not_nil(Mail.batchState.plan.splitStack.onto, "a split with room to merge planned no merge")
			local ok, msg = click()
			assert.is_true(ok, "a merging split was refused for want of a free slot: " .. tostring(msg))
			env.advance(0.1)
			assert.is_true((click()))
			assert.equal(1, attachedCount()); assert.equal(8, slot(1).count)
		end)

		it("restarts rather than dropping the split onto a stack that changed since the order was picked", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
			env.harnessBag(0, 16, { { id = LINEN, count = 5 }, { id = LINEN, count = 10 } })
			order("r1", ALICE, LINEN, 8, 1000)
			assert.is_true((click()))
			assert.is_not_nil(Mail.batchState, "precondition: the batch is running")
			wow.bags[0][1].count = 4   -- the banker used one
			local ok, msg = click()
			assert.is_false(ok); assert.truthy(msg:find("bags changed", 1, true), msg)
			assert.is_nil(Mail.batchState)
			assert.is_nil(wow.cursor); assert.same({ 4, 10 }, stacksOf(LINEN), "a stack was split despite restarting")
		end)

		it("counts a merged extra as its whole stacks only, so it still fits the mail", function()
			env.defineItem(WOOL, { name = "Wool Cloth", stackCount = 20 })
			-- r1 takes eleven 1-stacks of Linen; r2 wants 8 Wool from a 5 and a 10 -- one slot merged,
			-- two unmerged, and one slot is left.
			local contents = {}
			for _ = 1, 11 do contents[#contents + 1] = { id = LINEN, count = 1 } end
			contents[#contents + 1] = { id = WOOL, count = 5 }
			contents[#contents + 1] = { id = WOOL, count = 10 }
			env.harnessBag(0, 16, contents)
			order("r1", ALICE, LINEN, 11, 1000)
			order("r2", ALICE, WOOL, 8, 1001)
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.equal(1, #Mail.batchState.extras, "the merged extra was counted as two attachments and dropped")
			assert.is_true((click()))   -- split
			env.advance(0.1)
			ok, msg = click()           -- attach
			assert.is_true(ok, msg)
			assert.equal(12, attachedCount())
			assert.equal(WOOL, slot(12).itemID); assert.equal(8, slot(12).count)
			assert.is_true((click()))   -- send
			confirmSend()
			assert.same({ "r1", "r2" }, ids(credited))
		end)

		it("the row's Fulfill icon splits onto the stack too, so the next click attaches one stack of 8", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
			env.harnessBag(0, 16, { { id = LINEN, count = 5 }, { id = LINEN, count = 10 } })
			local r1 = order("r1", ALICE, LINEN, 8, 1000)
			local ok, msg = Mail:PrepareFulfillMail(r1)
			assert.is_false(ok, msg)
			local popup = wow.popups[#wow.popups]
			assert.equal("TOGBANK_SPLIT_STACK", popup.which)
			assert.truthy(popup.text1:find("onto your stack of 5", 1, true), popup.text1)
			assert.is_table(popup.data and popup.data.onto, "the popup's data carries no merge target")
			popup.info.OnAccept(nil, popup.data)
			env.advance(0.2)
			assert.is_nil(wow.cursor)
			assert.same({ 7, 8 }, stacksOf(LINEN))
			ok, msg = Mail:PrepareFulfillMail(r1)
			assert.is_true(ok, msg)
			assert.equal(1, attachedCount()); assert.equal(8, slot(1).count)
		end)

		-- MAIL-ONE-STACK-001 (the operator, 2026-10-31: "why does it send a stack of 5 and a stack of 2
		-- instead of making it one stack of 7?"): stacks that add up exactly used to go as they were.
		it("sends 7 from a 20, a 5 and a 2 as ONE stack of 7, moving the 2 onto the 5", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
			env.harnessBag(0, 16, { { id = LINEN, count = 20 }, { id = LINEN, count = 5 }, { id = LINEN, count = 2 } })
			order("r1", ALICE, LINEN, 7, 1000)
			local ok, msg = click()
			assert.is_true(ok, msg)
			local plan = Mail.batchState.plan
			assert.equal(1, #plan.stacksToAttach); assert.equal(5, plan.stacksToAttach[1].count)
			assert.equal(2, plan.splitStack.count, "split from the 20 rather than moving the 2")
			assert.equal(2, plan.splitStack.amount)
			assert.is_table(plan.splitStack.onto, "the 2 was not planned onto the 5")
			assert.is_true((click()))   -- split
			env.advance(0.1)
			assert.is_nil(wow.cursor, "the moved stack was left on the cursor")
			assert.same({ 7, 20 }, stacksOf(LINEN), "the 2 did not stack onto the 5")
			ok, msg = click()           -- attach
			assert.is_true(ok, msg)
			assert.equal(1, attachedCount(), "the order went as more than one attachment")
			assert.equal(7, slot(1).count)
			assert.is_true((click()))   -- send
			confirmSend()
			assert.same({ "r1" }, ids(credited))
			assert.same({ 20 }, stacksOf(LINEN))
		end)

		it("splits from a bigger stack onto the order's stack when no small stack covers the rest", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
			env.harnessBag(0, 16, { { id = LINEN, count = 20 }, { id = LINEN, count = 3 }, { id = LINEN, count = 2 }, { id = LINEN, count = 2 } })
			order("r1", ALICE, LINEN, 7, 1000)
			assert.is_true((click()))
			local plan = Mail.batchState.plan
			assert.equal(1, #plan.stacksToAttach); assert.equal(3, plan.stacksToAttach[1].count)
			assert.equal(20, plan.splitStack.count); assert.equal(4, plan.splitStack.amount)
			assert.is_true((click()))   -- split
			env.advance(0.1)
			assert.is_true((click()))   -- attach
			assert.equal(1, attachedCount()); assert.equal(7, slot(1).count)
		end)

		it("the row's Fulfill icon moves the whole 2 onto the 5, so the next click attaches one stack of 7", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
			env.harnessBag(0, 16, { { id = LINEN, count = 5 }, { id = LINEN, count = 2 } })
			local r1 = order("r1", ALICE, LINEN, 7, 1000)
			local ok, msg = Mail:PrepareFulfillMail(r1)
			assert.is_false(ok, msg)
			local popup = wow.popups[#wow.popups]
			assert.equal("TOGBANK_SPLIT_STACK", popup.which)
			assert.truthy(popup.text1:find("Split 2 from stack of 2", 1, true), popup.text1)
			assert.truthy(popup.text1:find("onto your stack of 5", 1, true), popup.text1)
			assert.equal(2, popup.data.count, "the popup cannot tell a whole-stack move from a split")
			popup.info.OnAccept(nil, popup.data)
			env.advance(0.2)
			assert.is_nil(wow.cursor, "the moved stack was left on the cursor")
			assert.same({ 7 }, stacksOf(LINEN))
			ok, msg = Mail:PrepareFulfillMail(r1)
			assert.is_true(ok, msg)
			assert.equal(1, attachedCount()); assert.equal(7, slot(1).count)
		end)

		-- Peer Review 349c7141 B1: the whole-stack move is decided from the plan's count, so a source
		-- that changed between the order being picked and the SPLIT click must restart, not move it all.
		it("restarts when the stack to move grew between picking the order and SPLIT", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
			env.harnessBag(0, 16, { { id = LINEN, count = 5 }, { id = LINEN, count = 2 } })
			order("r1", ALICE, LINEN, 7, 1000)
			assert.is_true((click()))
			assert.equal(2, Mail.batchState.plan.splitStack.count, "precondition: the 2 is to be moved")
			wow.bags[0][2].count = 4   -- looted two more onto it
			local ok, msg = click()
			assert.is_false(ok); assert.truthy(msg:find("bags changed", 1, true), msg)
			assert.is_nil(Mail.batchState)
			assert.is_nil(wow.cursor); assert.same({ 4, 5 }, stacksOf(LINEN), "a stack was moved despite restarting")
		end)

		it("the popup refuses when the stack to move changed while it was open", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
			env.harnessBag(0, 16, { { id = LINEN, count = 5 }, { id = LINEN, count = 2 } })
			assert.is_false((Mail:PrepareFulfillMail(order("r1", ALICE, LINEN, 7, 1000))))
			local popup = wow.popups[#wow.popups]
			wow.bags[0][2].count = 4
			popup.info.OnAccept(nil, popup.data)
			env.advance(0.2)
			assert.is_nil(wow.cursor)
			assert.same({ 4, 5 }, stacksOf(LINEN), "the popup moved a stack that had changed")
		end)

		-- Peer Review 349c7141 B2: moving the whole 2 into an empty slot would change nothing.
		it("the popup refuses a whole-stack move when its target stack changed, rather than moving it to a free slot", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
			env.harnessBag(0, 16, { { id = LINEN, count = 5 }, { id = LINEN, count = 2 } })
			assert.is_false((Mail:PrepareFulfillMail(order("r1", ALICE, LINEN, 7, 1000))))
			local popup = wow.popups[#wow.popups]
			wow.bags[0][1].count = 4   -- the banker used one of the 5
			popup.info.OnAccept(nil, popup.data)
			env.advance(0.2)
			assert.is_nil(wow.cursor)
			assert.equal(2, wow.bags[0][2].count, "the 2 was moved")
			assert.is_nil(wow.bags[0][3], "the 2 was moved into a free slot")
		end)

		-- Self-audit F1: with no known max stack there is no merge, and the old plan stands.
		it("keeps the stacks as they are when the item's max stack is not known", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
			env.harnessBag(0, 16, { { id = LINEN, count = 5 }, { id = LINEN, count = 2 } })
			local realGetItemInfo = _G.GetItemInfo
			_G.GetItemInfo = function() return nil end
			local ok, plan = pcall(Mail.CalculateFulfillmentPlan, Mail,
				{ { bag = 0, slot = 1, count = 5 }, { bag = 0, slot = 2, count = 2 } }, 7, 7)
			_G.GetItemInfo = realGetItemInfo
			assert.is_true(ok, plan)
			assert.equal(2, #plan.stacksToAttach); assert.is_nil(plan.splitStack)
		end)

		it("keeps the stacks as they are when the order is bigger than one stack holds", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 5 })
			env.harnessBag(0, 16, { { id = LINEN, count = 5 }, { id = LINEN, count = 2 } })
			order("r1", ALICE, LINEN, 7, 1000)
			assert.is_true((click()))
			local plan = Mail.batchState.plan
			assert.equal(2, #plan.stacksToAttach); assert.is_nil(plan.splitStack)
		end)

		it("the popup splits into a free slot instead when the stack changed while it was open", function()
			env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
			env.harnessBag(0, 16, { { id = LINEN, count = 5 }, { id = LINEN, count = 10 } })
			assert.is_false((Mail:PrepareFulfillMail(order("r1", ALICE, LINEN, 8, 1000))))
			local popup = wow.popups[#wow.popups]
			wow.bags[0][1].count = 4   -- the banker used one before clicking Split
			popup.info.OnAccept(nil, popup.data)
			env.advance(0.2)
			assert.is_nil(wow.cursor)
			assert.equal(3, wow.bags[0][3].count, "the split did not land in the first free slot")
			assert.same({ 3, 4, 7 }, stacksOf(LINEN), "the split was dropped onto the changed stack")
		end)
	end)

	-- Self-audit: the first order's SPLIT source stack is taken from before ATTACH runs, so an extra
	-- planned on its full count would attach the remainder and be credited the plan.
	it("never plans an extra on the stack the first order is about to split", function()
		env.harnessBag(0, 16, { { id = SILK, count = 5 } })
		order("s1", ALICE, SILK, 3, 1000)   -- 3 of 5: a split
		order("s2", ALICE, SILK, 5, 1001)   -- the whole 5-stack -- which will be 2 after the split
		local ok, msg = click()
		assert.is_true(ok, msg)
		assert.equal("s1", Mail.batchState.req.id)
		assert.is_table(Mail.batchState.plan.splitStack, "precondition: s1 needs a split")
		assert.equal(0, #Mail.batchState.extras, "s2 was planned on the stack s1 is about to split")
	end)

	it("never plans the same stack for two orders of one item, and drops an extra whole when it would not fit", function()
		-- One Linen stack only: r1 takes it; r2 (same item) has nothing left to plan against.
		env.harnessBag(0, 16, { { id = LINEN, count = 20 } })
		order("r1", ALICE, LINEN, 20, 1000)
		order("r2", ALICE, LINEN, 20, 1001)
		assert.is_true((click()))
		assert.equal("r1", Mail.batchState.req.id)
		assert.equal(0, #Mail.batchState.extras, "r2 was planned against the stack r1 already took")
		Mail:ResetFulfillStep()
		-- Twelve slots: eleven stacks for r1, then r2 needs two stacks and only one slot is left.
		local contents = {}
		for _ = 1, 13 do contents[#contents + 1] = { id = WOOL, count = 1 } end
		env.harnessBag(0, 16, contents)
		Guild.Info.requests = {}
		order("w1", ALICE, WOOL, 11, 1000)
		order("w2", ALICE, WOOL, 2, 1001)
		assert.is_true((click()))
		assert.equal("w1", Mail.batchState.req.id)
		assert.equal(0, #Mail.batchState.extras, "an order needing two slots was planned into one")
	end)
end)
