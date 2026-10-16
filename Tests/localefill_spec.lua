-- LOCALE-SENDTRIM-001, second half (Peer Review f6aa732c, F3/F4): a mail slot is named in the
-- BANKER's client language and an order in the REQUESTER's. The send trim was fixed to match by item
-- id; FulfillRequest, one call further on, still matched by name, so a hand-built mail or a stack
-- hand-added to an addon mail credited nothing in a mixed-locale guild. These run the real send hook,
-- ApplyPendingSend and FulfillRequest on a whole client, nothing stubbed between them.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")
local wow = env.wow

local T = 1757000000
local GUILD = "Testguild"
local BANKER, PEER = "Bankchar-Testrealm", "Otherguy-Testrealm"
local FELCLOTH, LINEN, BRACERS = 14256, 2589, 15372

local Guild, Mail

local function place(item, itemID, qty, at)
	assert.is_true(Guild:AddRequest({
		date = at, requester = PEER, bank = BANKER,
		item = item, itemID = itemID, quantity = qty, fulfilled = 0, notes = "",
	}), "precondition: AddRequest refused " .. tostring(item))
	for id, r in pairs(Guild.Info.requests) do
		if r.item == item and r.date == at then return r, id end
	end
	error("placed request not found")
end

--- Put a stack straight into send slot `i`, named as the BANKER's client names it.
local function attach(i, itemID, count, name)
	wow.sendMailItems[i] = { itemID = itemID, count = count, name = name }
end

describe("LOCALE-SENDTRIM-001: a mail credits an order named in another language", function()
	before_each(function()
		env.reset()
		env.standUpClient("Bankchar", { { name = BANKER, note = "gbank" }, { name = PEER } }, GUILD)
		Guild, Mail = TOGBankClassic_Guild, TOGBankClassic_Mail
		env.now = T
		TOGBankClassic_Core.SendCommMessage = function() end
		TOGBankClassic_Core.SendWhisper = function() return true end
		env.defineItem(FELCLOTH, { name = "Felcloth" })
		env.defineItem(LINEN, { name = "Linen Cloth" })
		env.defineItem(BRACERS, { name = "Bracers of the Bear" })
		assert.is_true(Guild:IsBank(BANKER), "precondition: the roster did not come up")
		Mail.pendingSend, Mail.pendingSendAt = nil, nil
		for i = 1, ATTACHMENTS_MAX_SEND do wow.sendMailItems[i] = nil end
	end)

	it("credits an English order from a mail the banker built by hand in German", function()
		local req = place("Felcloth", FELCLOTH, 20, T)
		attach(1, FELCLOTH, 20, "Teufelsstoff")
		Mail:OnSendMail(PEER)
		assert.is_table(Mail.pendingSend, "precondition: the hand-built mail was tracked")
		Mail:ApplyPendingSend()
		assert.equal(20, req.fulfilled, "the order stayed open after its items went")
	end)

	it("credits a hand-added stack on an addon mail to the person's other order", function()
		local linen, linenId = place("Linen Cloth", LINEN, 5, T)
		local fel = place("Felcloth", FELCLOTH, 8, T + 1)
		Mail.pendingSend = { sender = BANKER, recipient = PEER, requestId = linenId,
			items = { { name = "Linen Cloth", itemID = LINEN, quantity = 5, requestId = linenId } } }
		Mail.pendingSendAt = GetTime()
		attach(1, LINEN, 5, "Leinenstoff")
		attach(2, FELCLOTH, 8, "Teufelsstoff")   -- added by hand to save a mail
		Mail:OnSendMail(PEER)
		Mail:ApplyPendingSend()
		assert.equal(5, linen.fulfilled)
		assert.equal(8, fel.fulfilled, "the hand-added stack credited nothing")
	end)

	it("fills the requester's OLDER order first when one mail covers part of two", function()
		-- Lua 5.1's string hash is fixed, so a real requests table can walk the older order first and
		-- pass this without a sort. Re-key both orders under ids that pairs() walks NEWER first, and
		-- assert that walk: if it ever changes, the example fails here instead of passing unsorted.
		local older = place("Felcloth", FELCLOTH, 10, T)
		local newer = place("Felcloth", FELCLOTH, 2, T + 100)
		older.id, newer.id = "older-order", "newer-order"
		Guild.Info.requests = { [older.id] = older, [newer.id] = newer }
		assert.equal(newer, (select(2, next(Guild.Info.requests))),
			"precondition: pairs() reaches the older order first, so this proves nothing about the sort")
		assert.equal(10, Guild:FulfillRequest(BANKER, PEER, "Felcloth", 10, nil, FELCLOTH))
		assert.equal(10, older.fulfilled, "the older order was left open")
		assert.equal(0, newer.fulfilled, "the newer order was filled first")
	end)

	it("passes over an older CANCELLED order and credits the open one", function()
		local cancelled = place("Felcloth", FELCLOTH, 10, T)
		local open = place("Felcloth", FELCLOTH, 10, T + 100)
		cancelled.status = "cancelled"
		assert.equal(10, Guild:FulfillRequest(BANKER, PEER, "Felcloth", 10, nil, FELCLOTH))
		assert.equal(10, open.fulfilled, "the open order was left short")
		assert.equal(0, cancelled.fulfilled, "a cancelled order took the credit")
	end)

	-- A peer's 'complete' mutation or an older release can leave an order closed SHORT; it is as
	-- finished as a cancelled one and must not take an untargeted spill either.
	it("passes over an older order closed short as COMPLETE and credits the open one", function()
		local closed = place("Felcloth", FELCLOTH, 10, T)
		local open = place("Felcloth", FELCLOTH, 10, T + 100)
		closed.status, closed.fulfilled = "complete", 4
		assert.equal(10, Guild:FulfillRequest(BANKER, PEER, "Felcloth", 10, nil, FELCLOTH))
		assert.equal(10, open.fulfilled, "the open order was left short")
		assert.equal(4, closed.fulfilled, "a completed order took the credit")
	end)

	it("credits the suffix variant that was sent, not an older sibling sharing its base id", function()
		local bear = place("Bracers of the Bear", BRACERS, 1, T)
		local monkey = place("Bracers of the Monkey", BRACERS, 1, T + 1)
		assert.equal(1, Guild:FulfillRequest(BANKER, PEER, "Bracers of the Monkey", 1, nil, BRACERS))
		assert.equal(1, monkey.fulfilled, "the Monkey order went unfilled")
		assert.equal(0, bear.fulfilled, "the Bear order was credited for a Monkey")
	end)

	-- FINISHED-001 (Peer Review f40a8e77 H2): the stale sweep asks Guild.IsRequestFinished, so only
	-- a live order goes stale; every kind of finished order is left for its own retention.
	it("expires only the stale LIVE orders, never a finished one", function()
		local stale = place("Felcloth", FELCLOTH, 10, T)
		local partial = place("Linen Cloth", LINEN, 10, T + 1)
		local filled = place("Felcloth", FELCLOTH, 3, T + 2)
		local short = place("Linen Cloth", LINEN, 9, T + 3)
		local cancelled = place("Felcloth", FELCLOTH, 7, T + 4)
		local fresh = place("Linen Cloth", LINEN, 6, T + 5)
		partial.fulfilled = 4
		filled.fulfilled, filled.status = 3, "fulfilled"
		short.fulfilled, short.status = 2, "complete"
		cancelled.status = "cancelled"
		for _, r in ipairs({ stale, partial, filled, short, cancelled }) do r.updatedAt = T end
		env.now = T + 40 * 86400
		fresh.updatedAt = env.now - 86400
		assert.is_true(Guild:CanManageRequests(BANKER), "precondition: the banker may manage orders")
		assert.equal(2, Guild:ExpireStaleRequests(BANKER))
		-- Read the sweep's tombstones, not what is left: its finalize also runs the retention prune,
		-- which drops old FINISHED orders without a tombstone, so the finished three are gone either way.
		local tomb = Guild.Info.requestsTombstones
		assert.is_number(tomb[stale.id], "a stale open order was not expired")
		assert.is_number(tomb[partial.id], "a stale part-filled order was not expired")
		assert.is_nil(tomb[filled.id], "a filled order was expired as stale")
		assert.is_nil(tomb[short.id], "an order closed short was expired as stale")
		assert.is_nil(tomb[cancelled.id], "a cancelled order was expired as stale")
		assert.is_nil(tomb[fresh.id], "a recent open order was expired")
		local kept = false
		for _, r in pairs(Guild.Info.requests) do kept = kept or r.id == fresh.id end
		assert.is_true(kept, "the recent open order is gone")
	end)

	-- Peer Review 7b5e912d: /reqscan counts "done" with the same helper the prune uses, so a
	-- closed-short order counts as done and a part-filled open one does not.
	it("counts as done in /reqscan exactly the orders the prune would drop", function()
		local open = place("Felcloth", FELCLOTH, 10, T)
		local short = place("Linen Cloth", LINEN, 9, T + 1)
		local filled = place("Felcloth", FELCLOTH, 3, T + 2)
		open.fulfilled = 4
		short.fulfilled, short.status = 2, "complete"
		filled.fulfilled = 3   -- at the quantity, status left as placed
		local lines = {}
		TOGBankClassic_Output.Response = function(_, fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
		Guild:ReqScan()
		assert.equal("ReqScan: 3 total, 2 done, 0 done+expired (by updatedAt, else date)", lines[1])
	end)

	-- Peer Review aa437aa8 B2: /reqscan ages a done order the way PruneRequests does, by updatedAt
	-- and then date, so a recent order with no updatedAt is not reported as expired while the
	-- prune keeps it.
	it("does not report a recent done order with no updatedAt as expired in /reqscan", function()
		local short = place("Linen Cloth", LINEN, 9, T)
		short.fulfilled, short.status = 2, "complete"
		short.updatedAt, short.date = nil, env.now
		local lines = {}
		TOGBankClassic_Output.Response = function(_, fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
		Guild:ReqScan()
		assert.equal("ReqScan: 1 total, 1 done, 0 done+expired (by updatedAt, else date)", lines[1])
		assert.equal("    0-7d: 1  7-14d: 0  14-21d: 0  21-30d: 0  >30d: 0  future: 0", lines[5])
		assert.equal("  Done requests missing fields: updatedAt=1, date=0", lines[6])
	end)

	-- Peer Review ca7dc86f (C1/C2): a non-numeric updatedAt falls back to date for the age, in the
	-- prune and in /reqscan alike, so a recent finished order is neither dropped nor reported expired.
	it("ages a finished order with a non-numeric updatedAt by its date, in the prune and in /reqscan", function()
		local short = place("Linen Cloth", LINEN, 9, T)
		short.fulfilled, short.status = 2, "complete"
		short.updatedAt, short.date = "garbage", env.now
		local lines = {}
		TOGBankClassic_Output.Response = function(_, fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
		Guild:ReqScan()
		assert.equal("ReqScan: 1 total, 1 done, 0 done+expired (by updatedAt, else date)", lines[1])
		Guild:PruneRequests()
		local kept = false
		for _, r in pairs(Guild.Info.requests) do kept = kept or r.id == short.id end
		assert.is_true(kept, "a recent finished order was pruned because its updatedAt was not a number")
	end)
end)
