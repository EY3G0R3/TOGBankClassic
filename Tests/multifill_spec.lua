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
-- it back with the client's five returns, and `SendMail` records `items` and empties the slots.
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

--- The mails SendMail recorded, in order.
local function sends()
	local out = {}
	for _, a in ipairs(wow.mailActions) do if a.action == "send" then out[#out + 1] = a end end
	return out
end

local function load()
	env.reset(); env.stubOutput()
	env.loadModules({ "Modules/Constants.lua", "Modules/Item.lua", "Modules/Guild.lua", "Modules/Bank.lua", "Modules/Mail.lua" })
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
		assert.equal(0, attachedCount(), "the send did not empty the slots")
		Mail:ApplyPendingSend()
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
		Mail:ApplyPendingSend()
		assert.same({ "r1", "r2", "r3" }, ids(credited))
		-- r4 (6 Silk, 5 in the bags) was never planned, attached or credited; the stack is whole.
		assert.equal(0, Guild.Info.requests.r4.fulfilled)
		local silkLeft = 0
		for s = 1, 16 do local it = wow.bags[0][s]; if it and it.itemID == SILK then silkLeft = silkLeft + it.count end end
		assert.equal(5, silkLeft, "the Silk stack was touched")
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
			Mail:ApplyPendingSend()
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
			Mail:ApplyPendingSend()
			assert.same({ "m1", "m2", "m3" }, ids(credited))
		end)

		it("refuses the split click up front when the bags have fewer free slots than splits, touching nothing", function()
			elementals()
			-- A 16-slot bag with 14 stacks: two free slots, three splits wanted.
			local contents = { { id = AIR, count = 5 }, { id = WATER, count = 5 }, { id = FIRE, count = 5 } }
			for _ = 1, 11 do contents[#contents + 1] = { id = LINEN, count = 20 } end
			env.harnessBag(0, 16, contents)
			order("e1", ALICE, AIR, 1, 1000); order("e2", ALICE, WATER, 1, 1001); order("e3", ALICE, FIRE, 1, 1002)
			assert.is_true((click()))
			assert.equal(3, #Mail.batchState.splits)
			local ok, msg = click()
			assert.is_false(ok)
			assert.truthy(msg:find("Need 3 free bag slots", 1, true), msg)
			assert.equal("split", Mail.batchState.phase, "the batch moved on despite refusing")
			assert.is_nil(wow.cursor); assert.equal(0, env.pendingTimerCount(), "a split was scheduled despite refusing")
			for _, id in ipairs({ AIR, WATER, FIRE }) do assert.same({ 5 }, stacksOf(id), "a stack was split despite refusing") end
			-- Make room and the same click goes through.
			wow.bags[0][14] = nil
			ok, msg = click()
			assert.is_true(ok, msg)
			env.advance(1)
			assert.is_true((click()))
			assert.equal(3, attachedCount())
			assert.is_true((click()))   -- send
			Mail.batchInFlight = false
			-- A single split with NO free slot keeps the one-slot wording.
			Guild.Info.requests = {}
			contents = {}
			for _ = 1, 16 do contents[#contents + 1] = { id = LINEN, count = 20 } end
			contents[1] = { id = AIR, count = 5 }
			env.harnessBag(0, 16, contents)
			order("one", ALICE, AIR, 1, 1000)
			assert.is_true((click()))
			ok, msg = click()
			assert.is_false(ok)
			assert.truthy(msg:find("Need one free bag slot", 1, true), msg)
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
			Mail:ApplyPendingSend()
			assert.same({ "a1" }, ids(credited))
			Mail.batchInFlight = false
			-- The next mail: a2 splits 2 from the 4 left.
			assert.is_true((click()))
			assert.equal("a2", Mail.batchState.req.id)
			assert.is_true((click())); env.advance(0.1); assert.is_true((click())); assert.is_true((click()))
			assert.equal(2, #sends()); assert.equal(2, sends()[2].items[1].count)
			assert.same({ 2 }, stacksOf(AIR))
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
