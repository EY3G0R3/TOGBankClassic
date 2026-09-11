-- BANKFILL-001: collecting an order's items out of the BANK -- pull, split the surplus, put it back.
--
-- The fulfil button has two contexts. At a mailbox it fills orders from bags (fulfillsplit_spec
-- covers that planner); at a bank it COLLECTS: each click pulls one stack the oldest order still
-- needs, and if that stack is bigger than the order it splits the spare back into the bank so the
-- banker walks away carrying exactly what was asked for. This file drives that whole state machine
-- against a bag/bank model that actually moves stacks, because the arithmetic is the feature: a
-- surplus computed wrongly either short-changes the requester or strips the bank.
--
-- This path shipped with NO spec and was twice claimed covered when it was not (self-audit
-- ed18e977db05). Every function below is driven here for the first time.
--
-- The container model is deliberately FAITHFUL about one thing the code must survive either way:
-- moving a stack out of the bank MAY merge it into a partial stack already in bags (the client
-- auto-stacks). The surplus arithmetic is asserted with merging on AND off, because the addon cannot
-- know which happened and must be right regardless.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Mail, Bank, Guild, Events

local ME      = "Bankchar-Testrealm"
local ALICE   = "Alice-Testrealm"
local LINEN   = 2589
local WOOL    = 2592
local STACK   = 20     -- stack ceiling the merge model uses for every item
local VAULT   = -1     -- BANK_CONTAINER
local BANKBAG = 5      -- first bank bag: NUM_BAG_SLOTS + 1

--- Every container-moving API call, in order, as { name, ... }.
local calls
--- Whatever SplitContainerItem left on the cursor, until PickupContainerItem drops it.
local cursor
--- Whether UseContainerItem merges into partial stacks of the same item first (client behaviour).
local mergeOnMove

local function bagSlots(first, last)
	local out = {}
	for b = first, last do
		local bag = env.bags[b]
		for s = 1, (bag and bag.size or 0) do out[#out + 1] = { bag = bag, b = b, s = s } end
	end
	return out
end

--- Model the client moving a bank stack into bags: merge into partial stacks first when the fixture
--- says the client does that, then the first empty carried slot. What does not fit stays banked.
local function useContainerItem(bag, slot)
	calls[#calls + 1] = { "UseContainerItem", bag, slot }
	local src = env.bags[bag] and env.bags[bag][slot]
	if not src then return end
	local remaining = src.stackCount
	if mergeOnMove then
		for _, c in ipairs(bagSlots(0, NUM_BAG_SLOTS)) do
			local it = c.bag[c.s]
			if it and it.itemID == src.itemID and it.stackCount < STACK and remaining > 0 then
				local moved = math.min(STACK - it.stackCount, remaining)
				it.stackCount = it.stackCount + moved
				remaining = remaining - moved
			end
		end
	end
	if remaining > 0 then
		for _, c in ipairs(bagSlots(0, NUM_BAG_SLOTS)) do
			if not c.bag[c.s] then
				c.bag[c.s] = { itemID = src.itemID, stackCount = remaining, hyperlink = src.hyperlink }
				remaining = 0
				break
			end
		end
	end
	if remaining == 0 then
		env.bags[bag][slot] = nil
	else
		src.stackCount = remaining
	end
end

local function splitContainerItem(bag, slot, amount)
	calls[#calls + 1] = { "SplitContainerItem", bag, slot, amount }
	local src = env.bags[bag] and env.bags[bag][slot]
	assert(src, string.format("split from an EMPTY slot %d/%d", bag, slot))
	assert(amount > 0 and amount < src.stackCount, string.format(
		"split %d out of a stack of %d -- the client refuses that", amount, src.stackCount))
	assert(cursor == nil, "split with something already on the cursor -- the client refuses that")
	src.stackCount = src.stackCount - amount
	cursor = { itemID = src.itemID, stackCount = amount, hyperlink = src.hyperlink }
end

local function pickupContainerItem(bag, slot)
	calls[#calls + 1] = { "PickupContainerItem", bag, slot }
	local tbl = env.bags[bag]
	assert(tbl and slot >= 1 and slot <= tbl.size,
		string.format("pickup targeted a slot that does not exist: %d/%d", bag, tostring(slot)))
	if cursor then
		-- The addon only ever drops onto a slot it found EMPTY. Dropping onto an occupied one is a
		-- swap in the client, which would leave the swapped item on the cursor -- a fixture failure
		-- rather than a modelled behaviour, because the code must never do it.
		assert(not tbl[slot], string.format("dropped the cursor onto an OCCUPIED slot %d/%d", bag, slot))
		tbl[slot] = cursor
		cursor = nil
	else
		cursor = tbl[slot]
		tbl[slot] = nil
	end
end

local function load()
	env.reset(); env.stubOutput()
	env.loadModules({
		"Modules/Constants.lua", "Modules/Item.lua", "Modules/Guild.lua",
		"Modules/Bank.lua", "Modules/Mail.lua", "Modules/Events.lua",
	})
	Mail, Bank, Guild, Events = TOGBankClassic_Mail, TOGBankClassic_Bank, TOGBankClassic_Guild,
		TOGBankClassic_Events

	env.defineItem(LINEN, { name = "Linen Cloth" })
	env.defineItem(WOOL,  { name = "Wool Cloth" })
	Guild.Info = { name = "Testguild", alts = {}, requests = {} }
	Guild.IsBank = function(_, n) return n == ME end

	calls, cursor, mergeOnMove = {}, nil, true
	C_Container.UseContainerItem    = useContainerItem
	C_Container.SplitContainerItem  = splitContainerItem
	C_Container.PickupContainerItem = pickupContainerItem
	_G.ClearCursor = function() calls[#calls + 1] = { "ClearCursor" }; cursor = nil end
	_G.BankFrame = { shown = true, IsShown = function(self) return self.shown end }

	-- Carried bags: one 16-slot backpack is plenty. Vault: 24 slots, empty until a case fills it.
	env.setBag(0, 16, {})
	env.setBag(VAULT, 24, {})
end

--- An open order for `qty` of the item, assigned to this banker.
local function order(id, qty, opts)
	opts = opts or {}
	local req = {
		id = id, requester = ALICE, bank = ME, status = "open",
		item = opts.name or "Linen Cloth", itemID = opts.itemID or LINEN, suffixID = opts.suffixID,
		quantity = qty, fulfilled = opts.fulfilled or 0, date = opts.date or 1000,
	}
	Guild.Info.requests[id] = req
	return req
end

--- Stacks of Linen in the vault, one per slot from slot 1.
local function vault(...)
	local contents = {}
	for _, n in ipairs({ ... }) do contents[#contents + 1] = { id = LINEN, count = n } end
	env.setBag(VAULT, 24, contents)
end

--- Stacks of Linen in the backpack.
local function bags(...)
	local contents = {}
	for _, n in ipairs({ ... }) do contents[#contents + 1] = { id = LINEN, count = n } end
	env.setBag(0, 16, contents)
end

local function inBags() return (Bank:CountItemInBags(nil, LINEN)) end
local function inBank() return (Bank:CountItemInBank(nil, LINEN)) end

local function callsNamed(name)
	local n = 0
	for _, c in ipairs(calls) do if c[1] == name then n = n + 1 end end
	return n
end

--- One click of the button at the bank, then let the deferred pickup land.
local function click()
	local ok, msg = Mail:BankCollectStep(ME)
	env.advance(0.1)
	return ok, msg
end

describe("Bank:FindItemsInBank / CountItemInBank", function()
	before_each(load)

	it("walks the vault and the bank bags, never the carried bags", function()
		bags(5)
		vault(20, 3)
		env.setBag(BANKBAG, 6, { { id = LINEN, count = 7 } })
		local total, rows = Bank:CountItemInBank("Linen Cloth", LINEN)
		assert.equal(30, total)
		assert.equal(3, #rows)
		for _, r in ipairs(rows) do
			assert.is_true(r.bag == VAULT or r.bag >= BANKBAG,
				"a carried-bag slot (" .. r.bag .. ") came back from the BANK search")
		end
	end)

	it("matches on itemID first, so a same-name variant is not collected by mistake", function()
		env.defineItem(9999, { name = "Linen Cloth" })   -- same display name, different item
		env.setBag(VAULT, 24, { { id = 9999, count = 20 }, { id = LINEN, count = 4 } })
		local total, rows = Bank:CountItemInBank("Linen Cloth", LINEN)
		assert.equal(4, total)
		assert.equal(LINEN, env.bags[VAULT][rows[1].slot].itemID)
	end)

	it("falls back to the name when the request carries no itemID", function()
		vault(6)
		assert.equal(6, (Bank:CountItemInBank("linen CLOTH", nil)))
	end)

	it("enforces suffix equality when the request carries a suffix (REQ-003)", function()
		env.setBag(VAULT, 24, {
			{ id = LINEN, count = 5, suffix = 863 },
			{ id = LINEN, count = 9, suffix = 864 },
		})
		assert.equal(9, (Bank:CountItemInBank("Linen Cloth", LINEN, 864)))
		assert.equal(14, (Bank:CountItemInBank("Linen Cloth", LINEN)),
			"with no suffix on the request both variants count")
	end)

	it("returns nothing when there is nothing to match on", function()
		vault(6)
		assert.same({}, Bank:FindItemsInBank(nil, nil))
		assert.same({}, Bank:FindItemsInBank("", nil))
	end)
end)

describe("Mail:IsBankOpen", function()
	before_each(load)

	it("is true only while the bank frame is shown", function()
		assert.is_true(Mail:IsBankOpen())
		BankFrame.shown = false
		assert.is_false(Mail:IsBankOpen())
	end)

	it("is false, not an error, when the frame does not exist", function()
		_G.BankFrame = nil
		assert.is_false(Mail:IsBankOpen())
	end)
end)

describe("Mail:FindEmptyBankSlot", function()
	before_each(load)

	it("prefers the vault, then the bank bags", function()
		vault(1, 2, 3)
		local slot = Mail:FindEmptyBankSlot()
		assert.same({ bag = VAULT, slot = 4 }, slot)
	end)

	it("moves on to the bank bags when the vault is full", function()
		env.setBag(VAULT, 2, { { id = WOOL }, { id = WOOL } })
		env.setBag(BANKBAG, 4, { { id = WOOL } })
		assert.same({ bag = BANKBAG, slot = 2 }, Mail:FindEmptyBankSlot())
	end)

	it("never offers a carried-bag slot", function()
		env.setBag(VAULT, 1, { { id = WOOL } })
		assert.is_nil(Mail:FindEmptyBankSlot(), "the backpack has 16 free slots and none of them count")
	end)
end)

describe("Mail:FindOldestBankFillableOrder", function()
	before_each(load)

	it("reports the TRUE shortfall against bags, even when the bank holds less than that", function()
		bags(2)
		vault(3)
		order("r1", 10)
		local req, short = Mail:FindOldestBankFillableOrder(ME)
		assert.equal("r1", req.id)
		assert.equal(8, short, "shortfall is needed minus bags; the bank's stock does not shrink it")
	end)

	it("skips an order the bags already cover", function()
		bags(10)
		vault(20)
		order("r1", 10)
		assert.is_nil(Mail:FindOldestBankFillableOrder(ME))
	end)

	it("skips an order the bank cannot help with", function()
		vault(20)
		order("r1", 5, { name = "Wool Cloth", itemID = WOOL })
		assert.is_nil(Mail:FindOldestBankFillableOrder(ME))
	end)

	it("counts what is already fulfilled", function()
		vault(20)
		order("r1", 10, { fulfilled = 4 })
		local _, short = Mail:FindOldestBankFillableOrder(ME)
		assert.equal(6, short)
	end)

	it("only considers this banker's open orders", function()
		vault(20)
		order("mine",   5)
		order("theirs", 5, {}).bank = "Otherbanker-Testrealm"
		order("done",   5, {}).status = "fulfilled"
		Guild.Info.requests["done"].date = 1     -- oldest of all, and must still lose
		Guild.Info.requests["theirs"].date = 2
		local req = Mail:FindOldestBankFillableOrder(ME)
		assert.equal("mine", req.id)
	end)

	-- (10) The mailbox search and the bank search must agree about what "oldest" means, or the
	-- banker collects for one order and is then told to fill a different one.
	it("picks the oldest by date, then by id -- the same tiebreak the mailbox search uses", function()
		vault(20, 20, 20)
		order("zz", 5, { date = 100 })
		order("b",  5, { date = 500 })
		order("a",  5, { date = 500 })
		assert.equal("zz", Mail:FindOldestBankFillableOrder(ME).id, "older date wins regardless of id")
		Guild.Info.requests["zz"] = nil
		assert.equal("a", Mail:FindOldestBankFillableOrder(ME).id, "same date: smaller id wins")

		-- And the mailbox search resolves the identical tie the identical way once bags cover them.
		bags(20)
		assert.equal("a", (Mail:FindOldestServiceableOrder(ME)).id)
	end)
end)

-- (11) A bank-only order is NOT serviceable at the mailbox. The two searches are separate on
-- purpose: teaching the mailbox one about bank stock would make it pick orders it cannot fill.
describe("the mailbox search does not count bank stock", function()
	before_each(load)

	it("finds nothing serviceable when the only stock is in the bank", function()
		vault(20)
		order("r1", 5)
		assert.is_nil(Mail:FindOldestServiceableOrder(ME),
			"the bank has 20 but the mailbox search must not see them")
		local req, short = Mail:FindOldestBankFillableOrder(ME)
		assert.equal("r1", req.id)
		assert.equal(5, short)
	end)
end)

describe("Mail:BankCollectStep", function()
	before_each(load)

	describe("refusals before anything moves", function()
		it("needs the bank open, and drops any armed state when it is not", function()
			Mail.bankCollectState = { phase = "return", surplus = 3 }
			BankFrame.shown = false
			local ok, msg = Mail:BankCollectStep(ME)
			assert.is_false(ok)
			assert.truthy(msg:find("bank"))
			assert.is_nil(Mail.bankCollectState)
			assert.equal(0, #calls)
		end)

		it("refuses a non-banker, exactly as the mailbox step does", function()
			vault(20)
			order("r1", 5)
			local ok, msg = Mail:BankCollectStep("Notabanker")
			assert.is_false(ok)
			assert.truthy(msg:find("bank characters"))
			assert.equal(0, #calls)
		end)

		it("refuses an actor whose name cannot be resolved", function()
			local ok = Mail:BankCollectStep(nil)
			assert.is_false(ok)
			assert.equal(0, #calls)
		end)

		-- (9)
		it("reports nothing to collect when the bags already cover every order", function()
			bags(10)
			vault(20)
			order("r1", 10)
			local ok, msg = click()
			assert.is_false(ok)
			assert.truthy(msg:find("Nothing left"))
			assert.equal(0, #calls, "must not touch the bank when there is nothing to do")
		end)

		-- (7)
		it("refuses with full bags before touching the bank", function()
			local full = {}
			for i = 1, 16 do full[i] = { id = WOOL, count = 1 } end
			env.setBag(0, 16, full)
			vault(20)
			order("r1", 5)
			local ok, msg = click()
			assert.is_false(ok)
			assert.truthy(msg:find("full"))
			assert.equal(0, callsNamed("UseContainerItem"))
			assert.equal(20, inBank())
		end)
	end)

	-- (2)
	describe("an exact stack", function()
		it("is pulled whole and arms no return phase", function()
			vault(20, 5)
			order("r1", 5)
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.equal(5, inBags())
			assert.equal(20, inBank())
			assert.is_nil(Mail.bankCollectState, "an exact pull has nothing to return")
			assert.equal(0, callsNamed("SplitContainerItem"))
			assert.truthy(msg:find("Pulled 5 of the 5"))
		end)
	end)

	-- (1)
	describe("choosing which stack to pull", function()
		it("takes the stack that overshoots least when several would cover the order", function()
			vault(20, 8, 5, 12)
			order("r1", 7)
			assert.is_true((click()))
			assert.equal(8, inBags(), "the 8-stack overshoots by 1; every other cover overshoots more")
			assert.equal(37, inBank())
		end)

		it("takes the largest stack when none covers the order, and arms no return", function()
			vault(3, 5, 2)
			order("r1", 7)
			local ok, msg = click()
			assert.is_true(ok)
			assert.equal(5, inBags())
			assert.is_nil(Mail.bankCollectState)
			assert.truthy(msg:find("Pulled 5 of the 7"), "the message names the TRUE shortfall: " .. msg)
		end)

		it("keeps pulling on later clicks until the order is covered, re-choosing each time", function()
			vault(3, 5, 2)
			order("r1", 7)
			click()                                   -- shortfall 7, nothing covers: the 5
			click()                                   -- shortfall 2: the 2 fits exactly, not the 3
			assert.equal(7, inBags(), "second click should take the exact 2, not overshoot with the 3")
			local ok, msg = click()
			assert.is_false(ok)
			assert.truthy(msg:find("Nothing left"), msg)
			assert.equal(3, inBank(), "the 3-stack stays banked -- the order was already covered")
		end)
	end)

	-- (3)
	describe("an oversized stack", function()
		it("is pulled, then the surplus is split back into a free bank slot on the next click", function()
			vault(20)
			order("r1", 7)
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.equal(20, inBags(), "the whole stack comes out first; the client cannot split from the bank")
			assert.equal("return", Mail.bankCollectState.phase)
			assert.equal(13, Mail.bankCollectState.surplus)
			assert.truthy(msg:find("spare 13"), msg)

			ok, msg = click()
			assert.is_true(ok, msg)
			assert.equal(7, inBags(), "bags hold exactly the order")
			assert.equal(13, inBank(), "the bank gets exactly the surplus back")
			assert.is_nil(Mail.bankCollectState)
			assert.is_nil(cursor, "the split stack must not be left on the cursor")
			assert.equal(1, callsNamed("SplitContainerItem"))
			assert.equal(1, callsNamed("PickupContainerItem"))
		end)

		it("returns the surplus to the vault slot it came from when that is the free one", function()
			-- A full vault except for the stack being pulled: the only free slot after the pull is
			-- the one it left, so the spare must land there rather than being reported unplaceable.
			local contents = {}
			for i = 1, 23 do contents[i] = { id = WOOL, count = 1 } end
			contents[24] = { id = LINEN, count = 20 }
			env.setBag(VAULT, 24, contents)
			order("r1", 7)
			click()
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.equal(13, env.bags[VAULT][24].stackCount)
			assert.equal(7, inBags())
		end)

		it("clears the cursor before every move so a stale pickup cannot swap the wrong item", function()
			vault(20)
			order("r1", 7)
			click(); click()
			assert.equal("ClearCursor", calls[1][1])
			local sawSplit = false
			for i, c in ipairs(calls) do
				if c[1] == "SplitContainerItem" then
					sawSplit = true
					assert.equal("ClearCursor", calls[i - 1][1], "ClearCursor must directly precede the split")
				end
			end
			assert.is_true(sawSplit)
		end)
	end)

	-- (4) THE INVARIANT under both client behaviours: after pull + return, bags hold exactly what
	-- they held plus the order, and the bank holds exactly what it held minus the order.
	describe("the surplus arithmetic holds whether or not the pulled stack merges into bags", function()
		local layouts = {
			{ bags = {},         vault = { 20 },     need = 7 },
			{ bags = { 5 },      vault = { 20 },     need = 12 },
			{ bags = { 18, 2 },  vault = { 5 },      need = 21 },
			{ bags = { 19, 19 }, vault = { 20 },     need = 41 },
			{ bags = { 15, 15 }, vault = { 20, 20 }, need = 33 },
			{ bags = { 1 },      vault = { 20 },     need = 2 },
			{ bags = { 3 },      vault = { 20, 4 },  need = 6 },
		}
		for _, merge in ipairs({ true, false }) do
			for _, L in ipairs(layouts) do
				local label = string.format("bags {%s} + vault {%s}, need %d, merge=%s",
					table.concat(L.bags, ","), table.concat(L.vault, ","), L.need, tostring(merge))
				it(label, function()
					mergeOnMove = merge
					bags(unpack(L.bags))
					vault(unpack(L.vault))
					order("r1", L.need)
					local bagsBefore, bankBefore = inBags(), inBank()
					-- Drive until the order is covered or the step refuses; return phases included.
					for _ = 1, 10 do
						local ok = click()
						if not ok and not Mail.bankCollectState then break end
					end
					assert.equal(L.need, inBags(), label .. ": bags do not hold exactly the order")
					assert.equal(bankBefore - (L.need - bagsBefore), inBank(),
						label .. ": the bank did not get exactly the surplus back")
					assert.is_nil(cursor, label .. ": something was left on the cursor")
					assert.is_nil(Mail.bankCollectState, label .. ": state left armed")
				end)
			end
		end
	end)

	describe("the return phase", function()
		local function armReturn()
			vault(20)
			order("r1", 7)
			assert.is_true((click()))
			assert.equal("return", Mail.bankCollectState.phase)
		end

		-- (6)
		it("waits for the stack to land, then gives up after three empty looks rather than stranding", function()
			armReturn()
			env.setBag(0, 16, {})            -- the player moved the pulled stack away
			local ok, msg = click()
			assert.is_false(ok); assert.truthy(msg:find("click again"), msg)
			assert.is_not_nil(Mail.bankCollectState)
			ok, msg = click()
			assert.is_false(ok); assert.truthy(msg:find("click again"), msg)
			ok, msg = click()
			assert.is_false(ok)
			assert.truthy(msg:find("carrying on"), msg)
			assert.is_nil(Mail.bankCollectState, "three misses must release the phase")
			assert.equal(0, callsNamed("SplitContainerItem"))
		end)

		-- (8)
		it("gives up cleanly when the bank has no free slot to take the spare", function()
			armReturn()
			local full = {}
			for i = 1, 24 do full[i] = { id = WOOL, count = 1 } end
			env.setBag(VAULT, 24, full)      -- something filled the slot the pull freed
			local ok, msg = click()
			assert.is_false(ok)
			assert.truthy(msg:find("No free bank slot"), msg)
			assert.truthy(msg:find("13"), "the message says how many extra the banker is carrying")
			assert.is_nil(Mail.bankCollectState)
			assert.equal(0, callsNamed("SplitContainerItem"), "must not split with nowhere to put it")
			assert.equal(20, inBags(), "the banker keeps the whole stack rather than losing the spare")
		end)

		-- (5) BANKFILL-002: the stuck state the self-audit found. Walking away from the bank with
		-- a return phase armed left every later click at any bank answering "waiting for the stack".
		it("is dropped when the bank closes, so the next visit starts clean", function()
			armReturn()
			env.setBag(0, 16, {})            -- and the banker used the stack in between
			Events:BANKFRAME_CLOSED()
			assert.is_nil(Mail.bankCollectState)

			-- Next visit: a fresh order collects rather than waiting on a stack that is long gone.
			vault(5)
			Guild.Info.requests["r1"] = nil
			order("r2", 5)
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.truthy(msg:find("Pulled 5"), msg)
		end)
	end)

	describe("same-name variants and suffixes", function()
		it("pulls the variant the order names, not the same-named other item (REQ-001)", function()
			env.defineItem(9999, { name = "Linen Cloth" })
			env.setBag(VAULT, 24, { { id = 9999, count = 20 }, { id = LINEN, count = 5 } })
			order("r1", 5)
			assert.is_true((click()))
			assert.equal(LINEN, env.bags[0][1].itemID)
			assert.equal(20, env.bags[VAULT][1].stackCount, "the look-alike stays banked")
		end)

		it("pulls only the suffix variant the order names (REQ-003)", function()
			env.setBag(VAULT, 24, {
				{ id = LINEN, count = 5, suffix = 863 },
				{ id = LINEN, count = 5, suffix = 864 },
			})
			order("r1", 5, { suffixID = 864 })
			assert.is_true((click()))
			assert.is_nil(env.bags[VAULT][2], "the 864 stack is the one that moved")
			assert.equal(5, env.bags[VAULT][1].stackCount)
		end)
	end)
end)

-- The button dispatches on context. It is built inside a large AceGUI window, so this pins the
-- contract it relies on rather than the widget: both steps exist on Mail and IsBankOpen is what
-- decides. The dispatch line itself is Modules/UI/Requests.lua's OnClick.
describe("ResetFulfillStep", function()
	before_each(load)

	it("drops the mailbox AND the bank state together", function()
		Mail.batchState = { phase = "attach" }
		Mail.collectState = { pulled = 1 }
		Mail.bankCollectState = { phase = "return", surplus = 1 }
		Mail:ResetFulfillStep()
		assert.is_nil(Mail.batchState)
		assert.is_nil(Mail.collectState)
		assert.is_nil(Mail.bankCollectState)
	end)
end)
