-- COVERAGE-MAIL-001 (Peer Review 074cdad6, thread 0a7c03ad): the branches of Modules/Mail.lua the
-- rest of the suite never reached -- the refusals, the donation scan's early exits, the split popup's
-- commit, the receive-side order notification, the manual-send tracker's refusals, the send-error
-- dump, and the stepped fulfil/collect guards. Each example states what the code SHOULD do on that
-- branch, against the real Mail, Guild, Bank, Item, Record and Scan modules and the harness's bags,
-- cursor, send slots and inbox (wow.bags / wow.sendMailItems / wow.mail / wow.mailActions).
--
-- Collaborators that are not the subject (Options, the Donation and Requests windows, Core's timer)
-- are small recording stand-ins, put back after every example so no later spec file inherits them.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")
local wow = env.wow

local Mail, Guild, Item

local ME    = "Bankchar-Testrealm"
local ALICE = "Alice-Testrealm"
local LINEN, WOOL, SILK = 2589, 2592, 4306

local saved
local timers, opened, statusText, drawn, closed
local options

--- Every globals this file replaces, so after_each can hand them back exactly.
local GLOBALS = { "MailFrame", "TOGBankClassic_Options", "TOGBankClassic_UI_Mail", "TOGBankClassic_UI_Requests",
	"TOGBankClassic_Core", "PlaySound" }

local function load()
	env.reset(); env.stubOutput()
	saved = {}
	for _, k in ipairs(GLOBALS) do saved[k] = { v = rawget(_G, k) } end
	-- The split popup is defined only when absent; drop any earlier load's so this load's is driven.
	StaticPopupDialogs["TOGBANK_SPLIT_STACK"] = nil
	env.loadModules({ "Modules/Constants.lua", "Modules/Item.lua", "Modules/Inventory/Record.lua",
		"Modules/Inventory/Scan.lua", "Modules/Guild.lua", "Modules/Bank.lua", "Modules/Mail.lua" })
	Mail, Guild, Item = TOGBankClassic_Mail, TOGBankClassic_Guild, TOGBankClassic_Item
	env.defineItem(LINEN, { name = "Linen Cloth", stackCount = 20 })
	env.defineItem(WOOL,  { name = "Wool Cloth", stackCount = 20 })
	env.defineItem(SILK,  { name = "Silk Cloth", stackCount = 20 })
	Guild.Info = { name = "Testguild", alts = {}, requests = {} }
	Guild.IsBank = function(_, n) return n == ME end
	Guild.GetPlayer = function() return ME end
	Guild.GetNormalizedPlayer = function() return ME end
	Guild.GetBanks = function() return { ME } end
	Guild.RefreshRequestsUI = function() end
	Item.IsUnique = function() return false end

	timers, opened, statusText, drawn, closed = {}, {}, nil, 0, 0
	options = { donation = true, bank = true, reporting = false, sound = false }
	TOGBankClassic_Options = {
		GetDonationEnabled = function() return options.donation end,
		GetBankEnabled = function() return options.bank end,
		GetBankReporting = function() return options.reporting end,
		IsOrderFulfillmentSoundEnabled = function() return options.sound end,
	}
	TOGBankClassic_UI_Mail = {
		ScoreMail = false,
		SetMailId = function(_, id) opened[#opened + 1] = id end,
		Open = function() end,
		Close = function() closed = closed + 1 end,
	}
	TOGBankClassic_UI_Requests = {
		isOpen = true,
		SetStatusText = function(_, t) statusText = t end,
		DrawContent = function() drawn = drawn + 1 end,
	}
	-- Mail's retries ride Core:ScheduleTimer; captured here and fired by the example (the server's part).
	TOGBankClassic_Core = { ScheduleTimer = function(_, fn) timers[#timers + 1] = fn end }
	_G.MailFrame = { IsShown = function() return true end }
	Mail.isOpen, Mail.isScanning, Mail.collectInFlight = true, false, false
	Mail.batchState, Mail.batchInFlight, Mail.pendingSend, Mail.pendingSendAt = nil, false, nil, nil
	env.setBag(0, 16, {})
end

local function restore()
	for k, s in pairs(saved) do _G[k] = s.v end
end

--- The recorded Output calls of one level whose format string is `fmt`.
local function outputs(level, fmt)
	local out = {}
	for _, c in ipairs(TOGBankClassic_Output.calls) do
		if c.level == level then
			for i = 1, c.n do
				if c[i] == fmt then out[#out + 1] = c; break end
			end
		end
	end
	return out
end

local function order(id, requester, itemID, qty, extra)
	local req = { id = id, requester = requester, bank = ME, status = "open", item = (GetItemInfo(itemID)),
		itemID = itemID, quantity = qty, fulfilled = 0, date = 1000 }
	for k, v in pairs(extra or {}) do req[k] = v end
	Guild.Info.requests[id] = req
	return req
end

local function attach(bag, slot, sendSlot)
	C_Container.PickupContainerItem(bag, slot)
	ClickSendMailItemButton(sendSlot)
	assert.is_nil(wow.cursor, "precondition: the stack did not land in the send slot")
end

describe("COVERAGE-MAIL-001: the split popup commits the split", function()
	before_each(load)
	after_each(restore)

	-- SPLIT-ROOM-001: it used to say nothing at all.
	it("splits nothing when there is no free bag slot, and tells the banker why", function()
		env.setBag(0, 2, { { id = LINEN, count = 20 }, { id = LINEN, count = 20 } })
		StaticPopupDialogs["TOGBANK_SPLIT_STACK"].OnAccept(nil, { bag = 0, slot = 1, amount = 5, itemName = "Linen Cloth" })
		env.flushTimers()
		assert.is_nil(wow.cursor, "a split was lifted with nowhere to put it")
		assert.equal(20, wow.bags[0][1].count)
		local message = "No free bag slot to split Linen Cloth into. Make room, then click Fulfill again."
		assert.equal(message, statusText)
		assert.equal(1, #outputs("Warn", "%s"), "nothing was printed to chat")
	end)

	it("splits into the first free slot and tells the open Requests window to fulfil again", function()
		env.setBag(0, 3, { { id = LINEN, count = 20 } })
		StaticPopupDialogs["TOGBANK_SPLIT_STACK"].OnAccept(nil, { bag = 0, slot = 1, amount = 5, itemName = "Linen Cloth" })
		env.flushTimers()
		assert.equal(15, wow.bags[0][1].count)
		assert.equal(5, wow.bags[0][2].count, "the split did not land in the free slot")
		assert.is_nil(wow.cursor)
		assert.equal("Split 5 Linen Cloth complete. Click Fulfill again to attach items.", statusText)
		assert.equal(1, drawn, "the request list was not redrawn")
	end)
end)

-- HANDOFF-SPLIT-001 (Discord, 2026-10-24): "could the individual action button split the stacks
-- please" -- away from a mailbox, the row's Fulfill button splits the order off for a trade.
describe("HANDOFF-SPLIT-001: Mail:PrepareHandoffSplit", function()
	before_each(load)
	after_each(restore)

	it("offers the split for a trade, and the accepted split says to trade it and mark the hand-off", function()
		env.setBag(0, 3, { { id = LINEN, count = 20 } })
		local ok, msg = Mail:PrepareHandoffSplit(order("h1", ALICE, LINEN, 5))
		assert.is_false(ok)
		assert.equal("Click Split to make 5 Linen Cloth ready to trade to " .. ALICE .. ".", msg)
		assert.equal(1, #wow.popups)
		local popup = wow.popups[1]
		assert.equal("TOGBANK_SPLIT_STACK", popup.which)
		assert.equal("Split 5 from stack of 20 Linen Cloth to hand to " .. ALICE .. "?", popup.text1)
		assert.equal(20, wow.bags[0][1].count, "the stack was split before the banker clicked Split")
		StaticPopupDialogs["TOGBANK_SPLIT_STACK"].OnAccept(nil, popup.data)
		env.flushTimers()
		assert.equal(15, wow.bags[0][1].count)
		assert.equal(5, wow.bags[0][2].count, "the order's amount was not split into its own stack")
		assert.equal("Split 5 Linen Cloth complete. Trade the order to " .. ALICE .. ", then use Mark hand-off.", statusText)
		assert.equal("open", Guild.Info.requests.h1.status, "a split alone credited the order")
	end)

	it("names the stack it merges onto when the order already has a partial stack", function()
		env.setBag(0, 3, { { id = LINEN, count = 20 }, { id = LINEN, count = 3 } })
		assert.is_false((Mail:PrepareHandoffSplit(order("h1", ALICE, LINEN, 8))))
		assert.equal("Split 5 from stack of 20 Linen Cloth onto your stack of 3, to hand to " .. ALICE .. "?", wow.popups[1].text1)
	end)

	it("needs no split when whole stacks already make the order", function()
		env.setBag(0, 3, { { id = LINEN, count = 20 } })
		local ok, msg = Mail:PrepareHandoffSplit(order("h1", ALICE, LINEN, 20))
		assert.is_false(ok)
		assert.equal("Your bags already hold 20 Linen Cloth in whole stacks. Trade them to " .. ALICE .. ", then use Mark hand-off.", msg)
		assert.equal(0, #wow.popups)
	end)

	it("refuses with the reason when it cannot help", function()
		assert.same({ false, "Invalid request." }, { Mail:PrepareHandoffSplit(nil) })
		assert.same({ false, "Request is already fulfilled." },
			{ Mail:PrepareHandoffSplit(order("done", ALICE, LINEN, 5, { fulfilled = 5 })) })
		assert.same({ false, "No Linen Cloth found in bags." }, { Mail:PrepareHandoffSplit(order("none", ALICE, LINEN, 5)) })
		env.setBag(0, 3, { { id = LINEN, count = 20 } })
		assert.same({ false, "Need 10 more items." }, { Mail:PrepareHandoffSplit(order("short", ALICE, LINEN, 30)) })
		assert.equal(0, #wow.popups)
	end)
end)

describe("COVERAGE-MAIL-001: Mail:CheckForFulfilledRequest", function()
	before_each(function() load(); Guild.GetNormalizedPlayer = function() return ALICE end end)
	after_each(restore)

	it("matches the receiver's own open order for the item, by name in any case, only from a bank character", function()
		local req = order("r1", ALICE, LINEN, 5)
		local ok, found = Mail:CheckForFulfilledRequest("LINEN CLOTH", 5, "Bankchar")   -- bare same-realm sender
		assert.is_true(ok)
		assert.equal(req, found)
		assert.is_false((Mail:CheckForFulfilledRequest("Linen Cloth", 5, "Stranger")), "a non-banker's mail matched an order")
		Guild.GetBanks = function() return nil end
		assert.is_false((Mail:CheckForFulfilledRequest("Linen Cloth", 5, "Bankchar")), "no banker list still matched")
	end)

	it("does not match a finished, cancelled or already-filled order, or someone else's", function()
		order("r1", ALICE, LINEN, 5, { status = "complete" })
		order("r2", ALICE, LINEN, 5, { status = "cancelled" })
		order("r3", ALICE, LINEN, 5, { fulfilled = 5 })
		order("r4", "Bob-Testrealm", LINEN, 5)
		assert.is_false((Mail:CheckForFulfilledRequest("Linen Cloth", 5, "Bankchar")))
	end)
end)

describe("COVERAGE-MAIL-001: the donation scan's exits", function()
	before_each(load)
	after_each(restore)

	it("stands aside closed, mid-scan, mid-collect, with no guild, no bankers, off a bank character, or with the bank off", function()
		wow.mail[1] = { sender = "Carol", subject = "gift", money = 100, cod = 0 }
		local function scan() Mail.isScanning = Mail.isScanning or false; Mail:Scan(); return #opened end
		Mail.isOpen = false
		assert.equal(0, scan(), "scanned with the mailbox closed")
		Mail.isOpen, Mail.isScanning = true, true
		assert.equal(0, scan(), "scanned twice at once")
		Mail.isScanning, Mail.collectInFlight = false, true
		assert.equal(0, scan(), "scanned while Fulfill Oldest was pulling from the mail")
		Mail.collectInFlight = false
		local info = Guild.Info
		Guild.Info = nil
		assert.equal(0, scan(), "scanned with no guild loaded")
		Guild.Info = info
		Guild.GetBanks = function() return nil end
		assert.equal(0, scan(), "scanned with no banker list")
		Guild.GetBanks = function() return { "Other-Testrealm" } end
		assert.equal(0, scan(), "scanned on a character that is not a bank character")
		Guild.GetBanks = function() return { ME } end
		options.bank = false
		assert.equal(0, scan(), "scanned with the bank turned off")
		assert.is_false(Mail.isScanning, "an exit before the scan left it marked running")
		options.bank = true
		assert.equal(1, scan(), "with every gate open, the gift did not open the Donation window")
		assert.same({ 1 }, opened)
	end)

	it("a header with no sender yet ends the scan and retries it a second later", function()
		wow.mail[1] = { subject = "loading" }
		Mail:Scan()
		assert.equal(1, #timers, "no retry was scheduled")
		assert.is_true(Mail.isScanning)
		-- The retry: the server has filled the header in now.
		wow.mail[1] = { sender = "Carol", subject = "gift", money = 100, cod = 0 }
		timers[1]()
		assert.is_false(Mail.isScanning == nil)
		assert.same({ 1 }, opened, "the retried scan did not reach the gift")
	end)

	it("skips a mail whose every attachment is unique, and opens one with a stackable attachment", function()
		local uniq = "|cffffffff|Hitem:6948:0:0:0:0:0:0:0:60|h[Hearthstone]|h|r"
		local linen = GetItemInfo(LINEN) and select(2, GetItemInfo(LINEN))
		Item.IsUnique = function(_, link) return link == uniq end
		wow.mail[1] = { sender = "Carol", subject = "u", cod = 0, items = {
			{ name = "Hearthstone", id = 6948, count = 1, link = uniq }, { name = "Hearthstone", id = 6948, count = 1, link = uniq } } }
		wow.mail[2] = { sender = "Carol", subject = "mixed", cod = 0, items = {
			{ name = "Hearthstone", id = 6948, count = 1, link = uniq }, { name = "Linen Cloth", id = LINEN, count = 5, link = linen } } }
		Mail:Scan()
		assert.same({ 2 }, opened, "an all-unique mail opened the Donation window, or the mixed one did not")
	end)
end)

describe("COVERAGE-MAIL-001: the send hook and the send-error dump", function()
	before_each(load)
	after_each(restore)

	it("hooks SendMail once, however often it is asked", function()
		local seen = 0
		local real = Mail.OnSendMail
		Mail.OnSendMail = function(self, r) seen = seen + 1; return real(self, r) end
		Mail:InitSendHook()
		Mail:InitSendHook()
		SendMail("Alice", "hi", "")
		assert.equal(1, seen, "the hook fired more than once per send -- it was installed twice")
	end)

	it("tracks nothing for a manual mail with no attachments, no open orders, or from a non-banker", function()
		-- A pending send older than the hook's 10 s window is stale: each manual send drops it.
		local function stale()
			Mail.pendingSend, Mail.pendingSendAt = { sender = ME, recipient = ALICE, items = {} }, GetTime() - 60
			assert.is_table(Mail.pendingSend)
		end
		stale()
		Mail:OnSendMail("Alice")
		assert.is_nil(Mail.pendingSend, "an empty mail was tracked, or a stale send kept")
		env.setBag(0, 16, { { id = LINEN, count = 5 } })
		attach(0, 1, 1)
		stale()
		Mail:OnSendMail("Alice")
		assert.is_nil(Mail.pendingSend, "a mail was tracked with no open orders to credit")
		order("r1", ALICE, LINEN, 5)
		Guild.GetNormalizedPlayer = function() return "Stranger-Testrealm" end
		stale()
		Mail:OnSendMail("Alice")
		assert.is_nil(Mail.pendingSend, "a non-banker's mail was tracked")
		assert.equal(1, #outputs("Debug", "OnSendMail: Sender %s is not a banker, skipping"))
	end)

	it("dumps the recipient, subject, every attachment and the pending send on a send error", function()
		env.setBag(0, 16, { { id = LINEN, count = 5 }, { id = WOOL, count = 3 } })
		attach(0, 1, 1); attach(0, 2, 2)
		SendMailNameEditBox:SetText("Alice")
		SendMailSubjectEditBox:SetText("Order")
		Mail.pendingSend = { sender = ME, recipient = ALICE, items = { { name = "Linen Cloth", quantity = 5 } } }
		Mail:DebugSendMailState("ERR_MAIL_TARGET_NOT_FOUND")
		local head = outputs("Debug", "SendMail error: %s | recipient=%s subject=%s items=%d total=%d")
		assert.equal(1, #head)
		assert.same({ "ERR_MAIL_TARGET_NOT_FOUND", "Alice", "Order", 2, 8 }, { head[1][4], head[1][5], head[1][6], head[1][7], head[1][8] })
		local rows = outputs("Debug", "  Attachment %d: %s (id=%s) x%d")
		assert.equal(2, #rows)
		assert.same({ 1, "Linen Cloth", tostring(LINEN), 5 }, { rows[1][4], rows[1][5], rows[1][6], rows[1][7] })
		local pend = outputs("Debug", "  pendingSend: sender=%s recipient=%s items=%d")
		assert.equal(1, #pend)
		assert.same({ ME, ALICE, 1 }, { pend[1][4], pend[1][5], pend[1][6] })
		-- A pending send carrying no item list reports zero items rather than erroring.
		Mail.pendingSend = { sender = ME, recipient = ALICE }
		Mail:DebugSendMailState("again")
		pend = outputs("Debug", "  pendingSend: sender=%s recipient=%s items=%d")
		assert.equal(2, #pend)
		assert.equal(0, pend[2][6])
	end)

	it("ApplyPendingSend with nothing pending credits nothing and frees the next batch", function()
		local credited = 0
		Guild.FulfillRequest = function() credited = credited + 1; return 1 end
		Mail.batchInFlight = true
		Mail:ApplyPendingSend()
		assert.equal(0, credited)
		assert.is_false(Mail.batchInFlight)
		assert.equal(1, #outputs("Debug", "ApplyPendingSend: No pendingSend, returning"))
	end)
end)

describe("COVERAGE-MAIL-001: Mail:Open, the Donation window's taker", function()
	before_each(load)
	after_each(restore)

	it("retries a mail whose header has not loaded, and does nothing with no guild loaded", function()
		Mail:Open(1)
		assert.equal(1, #timers, "no retry for an unloaded header")
		assert.same({}, wow.mailActions)
		timers[1]()                       -- OnRetryTimer -> Open again, still unloaded
		assert.equal(2, #timers)
		wow.mail[1] = { sender = "Alice", subject = "gift", money = 100, cod = 0 }
		Guild.Info = nil
		Mail:Open(1)
		assert.same({}, wow.mailActions, "took from the mail with no guild loaded")
	end)

	it("reports gold received when bank reporting is on, takes it, then closes and rescans", function()
		options.reporting = true
		wow.mail[1] = { sender = "Alice", subject = "gift", money = 25000, cod = 0 }
		Mail:Open(1)
		local info = outputs("Info", "Received %s gold from %s")
		assert.equal(1, #info)
		assert.equal(2.5, info[1][2]); assert.equal("Alice", info[1][3])
		assert.equal("takeMoney", wow.mailActions[1].action)
		assert.equal(1, closed, "the Donation window was not closed after the take")
		assert.equal(1, #timers, "the scan was not resumed")
	end)

	it("warns and takes nothing when the bags are full", function()
		env.setBag(0, 1, { { id = WOOL, count = 1 } })
		for b = 1, 4 do env.setBag(b, 0, {}) end
		wow.mail[1] = { sender = "Alice", subject = "gift", cod = 0, items = {
			{ name = "Linen Cloth", id = LINEN, count = 5, link = select(2, GetItemInfo(LINEN)) } } }
		Mail:Open(1)
		assert.equal(1, #outputs("Warn", "Inventory is full."))
		assert.same({}, wow.mailActions)
	end)

	it("retries an attachment whose item the client has not loaded yet, rather than taking it blind", function()
		wow.mail[1] = { sender = "Alice", subject = "gift", cod = 0, items = {
			{ name = "Mystery", id = 99999, count = 1, link = "|cffffffff|Hitem:99999:0:0:0:0:0:0:0:60|h[Mystery]|h|r" } } }
		Mail:Open(1)
		assert.same({}, wow.mailActions, "an unloaded item was taken")
		assert.equal(1, #timers)
	end)

	it("announces an order filled by a bank character's mail, with the sound, complete or part", function()
		Guild.GetNormalizedPlayer = function() return ALICE end
		options.reporting, options.sound = true, true
		local sounds = 0
		_G.PlaySound = function() sounds = sounds + 1 end
		order("r1", ALICE, LINEN, 20)
		local link = select(2, GetItemInfo(LINEN))
		wow.mail[1] = { sender = "Bankchar", subject = "order", cod = 0, items = { { name = "Linen Cloth", id = LINEN, count = 20, link = link } } }
		Mail:Open(1)
		assert.equal(1, #outputs("Info", "Received %s (%d) from %s"))
		assert.equal(1, #outputs("Response", "|cff00ff00[Order Filled]|r Received %dx %s from %s - Request Complete!"))
		assert.equal(1, sounds)
		assert.equal("take", wow.mailActions[1].action)
		-- A second order for more than one mail carries: announced with the running count.
		Guild.Info.requests = {}
		order("r2", ALICE, LINEN, 30)
		options.sound = false
		Mail:Open(1)
		local part = outputs("Response", "|cff00ff00[Order Filled]|r Received %dx %s from %s (%d/%d)")
		assert.equal(1, #part)
		assert.same({ 20, 30 }, { part[1][5], part[1][6] })
		assert.equal(1, sounds, "the sound played with the option off")
	end)

	it("the scan timer resumes the scan where it left off", function()
		wow.mail[1] = { sender = "Carol", subject = "gift", money = 100, cod = 0 }
		Mail.isScanning = true
		Mail:ResetScan()
		assert.equal(1, #timers)
		timers[1]()
		assert.same({ 1 }, opened, "the resumed scan did not reach the gift")
	end)
end)

describe("COVERAGE-MAIL-001: the fulfilment planner", function()
	before_each(load)
	after_each(restore)

	it("phase 2 keeps the closest under-fill it finds by skipping a stack, then splits the rest", function()
		local items = { { bag = 0, slot = 1, count = 8 }, { bag = 0, slot = 2, count = 5 }, { bag = 0, slot = 3, count = 4 } }
		local plan = Mail:CalculateFulfillmentPlan(items, 10, 17)
		assert.is_true(plan.canFulfill)
		local counts = {}
		for _, s in ipairs(plan.stacksToAttach) do counts[#counts + 1] = s.count end
		assert.same({ 5, 4 }, counts, "the closer fit (5+4=9) was not kept over the greedy 8")
		assert.equal(1, plan.splitStack.amount); assert.equal(8, plan.splitStack.count)
		assert.equal("Split 1 from stack of 8.", plan.reason)
	end)

	it("fails closed when the stacks cannot make up a total the caller claimed", function()
		local plan = Mail:CalculateFulfillmentPlan({ { bag = 0, slot = 1, count = 3 } }, 5, 10)
		assert.is_false(plan.canFulfill)
		assert.equal("Unable to determine fulfillment strategy.", plan.reason)
		assert.same({}, plan.stacksToAttach); assert.is_nil(plan.splitStack)
	end)

	it("CanFulfillRequest refuses a non-banker, a malformed, a finished and a filled order", function()
		Guild.IsBank = function() return false end
		assert.equal("Only bank alts can fulfill requests.", select(2, Mail:CanFulfillRequest(order("r1", ALICE, LINEN, 5))))
		Guild.IsBank = function(_, n) return n == ME end
		assert.equal("Invalid request.", select(2, Mail:CanFulfillRequest(nil)))
		assert.equal("Invalid request.", select(2, Mail:CanFulfillRequest({ quantity = 1 })))
		for _, st in ipairs({ "complete", "fulfilled", "cancelled" }) do
			assert.equal("Request is already completed.", select(2, Mail:CanFulfillRequest(order("r" .. st, ALICE, LINEN, 5, { status = st }))))
		end
		assert.equal("Request is already fulfilled.", select(2, Mail:CanFulfillRequest(order("r2", ALICE, LINEN, 5, { fulfilled = 5 }))))
	end)

	it("CanFulfillRequest answers yes, with the bag count and smallest stack, when the bags cover it", function()
		env.setBag(0, 16, { { id = LINEN, count = 3 }, { id = LINEN, count = 2 } })
		local ok, reason, inBags, smallest = Mail:CanFulfillRequest(order("r1", ALICE, LINEN, 5))
		assert.is_true(ok); assert.is_nil(reason); assert.equal(5, inBags); assert.equal(2, smallest)
		-- Short, with nothing anywhere else: the planner's own reason.
		local ok2, reason2 = Mail:CanFulfillRequest(order("r2", ALICE, LINEN, 8))
		assert.is_false(ok2); assert.equal("Need 3 more items.", reason2)
	end)
end)

describe("COVERAGE-MAIL-001: CanFulfillRequest's shortfall hint", function()
	local Store, Record
	before_each(function()
		load()
		Store = env.freshV2()
		Record = TOGBankClassic_Inventory_Record
		Guild.Info = { name = "Testguild", alts = { [ME] = { name = ME } }, requests = {} }
		env.setBag(0, 16, { { id = LINEN, count = 2 } })
	end)
	after_each(restore)

	local function scanned(sources)
		local recs = {}
		for source, rows in pairs(sources) do
			recs[source] = {}
			for _, r in ipairs(rows) do recs[source][#recs[source] + 1] = Record.new(r[1], r[2]) end
		end
		Store:SetAltSources("Testguild", ME, recs, 0)
	end

	it("names the mail and the bank, or the mail alone, when the bags hold some but not enough", function()
		scanned({ bags = { { LINEN, 2 } }, mail = { { LINEN, 10 } }, bank = { { LINEN, 10 } } })
		local ok, reason, inBags = Mail:CanFulfillRequest(order("r1", ALICE, LINEN, 5))
		assert.is_false(ok); assert.equal("shortfall in bank and mail", reason); assert.equal(2, inBags)
		scanned({ bags = { { LINEN, 2 } }, mail = { { LINEN, 10 } }, bank = {} })
		assert.equal("shortfall in mail", select(2, Mail:CanFulfillRequest(order("r2", ALICE, LINEN, 5))))
	end)
end)

describe("COVERAGE-MAIL-001: PrepareFulfillMail's refusals and slot handling", function()
	before_each(load)
	after_each(restore)

	it("refuses with the mailbox shut, a malformed order, a filled one, none in bags, or not enough", function()
		_G.MailFrame = { IsShown = function() return false end }
		assert.equal("Mailbox is not open.", select(2, Mail:PrepareFulfillMail(order("r1", ALICE, LINEN, 5))))
		_G.MailFrame = { IsShown = function() return true end }
		assert.equal("Invalid request.", select(2, Mail:PrepareFulfillMail({ item = "Linen Cloth" })))
		assert.equal("Request is already fulfilled.", select(2, Mail:PrepareFulfillMail(order("r2", ALICE, LINEN, 5, { fulfilled = 5 }))))
		assert.equal("No Linen Cloth found in bags.", select(2, Mail:PrepareFulfillMail(order("r3", ALICE, LINEN, 5))))
		env.setBag(0, 16, { { id = LINEN, count = 20 } })
		local ok, msg, n = Mail:PrepareFulfillMail(order("r4", ALICE, LINEN, 30))
		assert.is_false(ok); assert.equal("Need 10 more items.", msg); assert.equal(0, n)
		assert.is_nil(Mail.pendingSend)
		assert.is_nil(wow.sendMailItems[1], "something was attached for a refused order")
		-- And the same order, once the bags cover it, is attached and pending.
		assert.is_true((Mail:PrepareFulfillMail(order("r5", ALICE, LINEN, 20))))
		assert.is_table(Mail.pendingSend)
	end)

	it("steps over a slot still holding an earlier order when the stacks fill the gap", function()
		env.setBag(0, 16, { { id = LINEN, count = 20 }, { id = WOOL, count = 10 }, { id = SILK, count = 5 }, { id = SILK, count = 5 } })
		assert.is_true((Mail:PrepareFulfillMail(order("r1", ALICE, LINEN, 20))))
		assert.is_true((Mail:PrepareFulfillMail(order("r2", ALICE, WOOL, 10))))
		ClickSendMailItemButton(1, true)     -- the banker detaches the Linen by hand
		local ok, msg = Mail:PrepareFulfillMail(order("r3", ALICE, SILK, 10))
		assert.is_true(ok, msg)
		assert.equal(SILK, wow.sendMailItems[1].itemID, "the gap at slot 1 was not used")
		assert.equal(WOOL, wow.sendMailItems[2].itemID, "the Wool still attached was displaced")
		assert.equal(SILK, wow.sendMailItems[3].itemID, "the second Silk stack did not skip the occupied slot 2")
	end)

	it("on a fresh mail, attaches the twelve stacks a mail holds and says the order is partial", function()
		local contents = {}
		for i = 1, 13 do contents[i] = { id = LINEN, count = 1 } end
		env.setBag(0, 16, contents)
		local ok, msg, n = Mail:PrepareFulfillMail(order("r1", ALICE, LINEN, 13))
		assert.is_true(ok)
		assert.equal("Attached 12 of 13 Linen Cloth (partial). Click Send, then fulfill again.", msg)
		assert.equal(12, n)
		assert.equal(12, Mail.pendingSend.items[1].quantity, "the order was credited for the stack left behind")
	end)

	it("attaches what fits when the mail runs out of slots, says it is partial, and credits only that", function()
		local contents = {}
		for i = 1, 11 do contents[i] = { id = WOOL, count = 1 } end
		contents[12] = { id = LINEN, count = 10 }; contents[13] = { id = LINEN, count = 10 }
		env.setBag(0, 16, contents)
		for i = 1, 11 do attach(0, i, i) end
		Mail.pendingSend = { sender = ME, recipient = ALICE, items = { { name = "Wool Cloth", quantity = 11, requestId = "w" } } }
		local ok, msg, n = Mail:PrepareFulfillMail(order("r1", ALICE, LINEN, 20))
		assert.is_true(ok)
		-- COVERAGE-MAIL-001: this read "Attached 10 Linen Cloth ... Click Send to complete." -- the
		-- added-order wording replaced the partial notice.
		assert.equal("Attached 10 of 20 Linen Cloth (partial) -- 2 orders on this mail. Click Send, then fulfill again.", msg)
		assert.equal(10, n)
		local entry = Mail.pendingSend.items[2]
		assert.equal("r1", entry.requestId); assert.equal(10, entry.quantity, "the order was credited for stacks left behind")
	end)

	it("refuses, and records no pending send, when a plan attaches nothing", function()
		-- A guard against a planner that says yes with nothing to attach: the planner cannot do that
		-- for a positive quantity today, so it is driven with a stand-in plan.
		env.setBag(0, 16, { { id = LINEN, count = 5 } })
		local real = Mail.CalculateFulfillmentPlan
		Mail.CalculateFulfillmentPlan = function() return { canFulfill = true, stacksToAttach = {} } end
		local ok, msg, n = Mail:PrepareFulfillMail(order("r1", ALICE, LINEN, 5))
		assert.is_false(ok); assert.equal("No Linen Cloth found in bags.", msg); assert.equal(0, n)
		assert.is_nil(Mail.pendingSend)
		assert.is_nil(wow.sendMailItems[1])
		-- With the real planner the same order attaches and is pending.
		Mail.CalculateFulfillmentPlan = real
		assert.is_true((Mail:PrepareFulfillMail(order("r1", ALICE, LINEN, 5))))
		assert.is_table(Mail.pendingSend)
	end)
end)

describe("COVERAGE-MAIL-001: taking an order's item out of the inbox", function()
	before_each(load)
	after_each(restore)

	local function suffixed(id, suffix, name)
		return string.format("|cffffffff|Hitem:%d:0:0:0:0:0:%d:0:60|h[%s]|h|r", id, suffix, name)
	end

	it("takes only the asked-for random-suffix variant", function()
		env.defineItem(10132, { name = "Thing" })
		wow.mail[1] = { sender = "S", subject = "x", items = {
			{ name = "Thing", id = 10132, count = 1, link = suffixed(10132, 2504, "Thing") },
			{ name = "Thing", id = 10132, count = 1, link = suffixed(10132, 863, "Thing") } } }
		local ok = Mail:TakeOneInboxItemFor({ item = "Thing", itemID = 10132, suffixID = 863 })
		assert.is_true(ok)
		assert.equal(2, wow.mailActions[1].attachment, "the wrong variant was taken")
	end)

	it("matches an order with no item id by name, in any case, and takes nothing when nothing matches", function()
		local wool, linen = select(2, GetItemInfo(WOOL)), select(2, GetItemInfo(LINEN))
		wow.mail[1] = { sender = "S", subject = "x", items = {
			{ name = "Mystery", id = 99999, count = 1, link = "|cffffffff|Hitem:99999:0:0:0:0:0:0:0:60|h[Mystery]|h|r" },
			{ name = "Wool Cloth", id = WOOL, count = 1, link = wool },
			{ name = "Linen Cloth", id = LINEN, count = 4, link = linen } } }
		local ok, name, qty = Mail:TakeOneInboxItemFor({ item = "linen cloth" })
		assert.is_true(ok); assert.equal("Linen Cloth", name); assert.equal(4, qty)
		assert.equal(3, wow.mailActions[1].attachment)
		assert.is_false((Mail:TakeOneInboxItemFor({ item = "Silk Cloth" })))
		assert.equal(1, #wow.mailActions, "something was taken for an item the inbox does not hold")
	end)
end)

describe("COVERAGE-MAIL-001: the stepped fulfil and collect guards", function()
	before_each(load)
	after_each(restore)

	it("FulfillStep refuses with the mailbox shut, off a bank character, mid-send, over a loaded mail, or with nothing to send", function()
		Mail.batchState = { phase = "attach" }
		assert.is_table(Mail.batchState)
		_G.MailFrame = { IsShown = function() return false end }
		assert.equal("Open a mailbox first.", select(2, Mail:FulfillStep(ME)))
		assert.is_nil(Mail.batchState, "a closed mailbox kept the half-done batch")
		_G.MailFrame = { IsShown = function() return true end }
		assert.equal("Only bank characters can fulfill orders.", select(2, Mail:FulfillStep("Alice")))
		Mail.batchInFlight = true
		assert.equal("Waiting for the last order to confirm — try again in a second.", select(2, Mail:FulfillStep(ME)))
		Mail.batchInFlight = false
		assert.equal("No orders you can fully fill from your bags or mail right now.", select(2, Mail:FulfillStep(ME)))
		env.setBag(0, 16, { { id = LINEN, count = 5 } })
		attach(0, 1, 1)
		assert.equal("The open mail already has items attached — send or clear it first.", select(2, Mail:FulfillStep(ME)))
	end)

	it("the mail-collect step waits for an in-flight pull, refuses full bags, and lets go when the take fails", function()
		order("r1", ALICE, LINEN, 5)
		wow.mail[1] = { sender = "S", subject = "x", items = { { name = "Linen Cloth", id = LINEN, count = 5, link = select(2, GetItemInfo(LINEN)) } } }
		Mail.collectInFlight = true
		assert.equal("Pulling from your mail — give it a second, then click again.", select(2, Mail:FulfillStep(ME)))
		Mail.collectInFlight = false
		env.setBag(0, 1, { { id = WOOL, count = 1 } })
		for b = 1, 4 do env.setBag(b, 0, {}) end
		assert.equal("Bags are full — make room to pull items from the mail.", select(2, Mail:FulfillStep(ME)))
		assert.same({}, wow.mailActions)
		env.setBag(0, 16, {})
		-- The inbox changed between the search and the take (the item was taken by hand): the guard
		-- is released at once so the next click is not blocked for the guard's full timer.
		Mail.TakeOneInboxItemFor = function() return false end
		assert.equal("Couldn't pull from the mail just now — click again.", select(2, Mail:FulfillStep(ME)))
		assert.is_false(Mail.collectInFlight)
	end)

	it("the SEND step sends no empty mail, and an unknown phase resets", function()
		Mail.batchState = { phase = "send", req = order("r1", ALICE, LINEN, 5), requester = ALICE, qty = 5 }
		assert.is_table(Mail.batchState)
		local ok, msg = Mail:FulfillStep(ME)
		assert.is_false(ok); assert.equal("Nothing is attached — start the order again.", msg)
		assert.is_nil(Mail.batchState)
		for _, a in ipairs(wow.mailActions) do assert.is_not_equal("send", a.action) end
		Mail.batchState = { phase = "bogus" }
		assert.is_table(Mail.batchState)
		assert.equal("Reset — click to start the next order.", select(2, Mail:FulfillStep(ME)))
		assert.is_nil(Mail.batchState)
	end)

	it("BankCollectStep says so, rather than erroring, when the bank shows none of the order's item", function()
		_G.BankFrame = { IsShown = function() return true end }
		local req = order("r1", ALICE, LINEN, 5)
		-- The search and the bank read are one synchronous pass today, so this is a guard against them
		-- disagreeing; driven with a stand-in search.
		Mail.FindOldestBankFillableOrder = function() return req, 5 end
		local ok, msg = Mail:BankCollectStep(ME)
		_G.BankFrame = nil
		assert.is_false(ok)
		assert.equal("Could not see Linen Cloth in the bank just now — click again.", msg)
	end)
end)
