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
-- The container is the HARNESS's (WoWAPITesting): `wow.bags`, `wow.cursor`, and its
-- `C_Container.UseContainerItem` / `SplitContainerItem` / `PickupContainerItem` and `ClearCursor`.
-- The client behaviour the code must survive either way -- moving a stack out of the bank MAY merge
-- it into a partial stack already in bags -- is the harness's `wow.bankAutoStack`, and the surplus
-- arithmetic is asserted with it on AND off, because the addon cannot know which happened.
--
-- BANKFILL-SWAP-001: this file carried a PRIVATE copy of those three moves until 2026-09-17, for
-- one reason -- the harness put a swapped-out stack ON THE CURSOR, while COLLECT-002 (Mail.lua,
-- "the client exchanges the two") has it return to the slot the addon picked up from. The operator
-- answered "i believe the bank" (the origin slot -- a belief, not a measurement); the harness
-- adopted that rule at f463acd, and the private moves are gone. What stays here is a RECORDING
-- wrapper: the call order and the swaps are what several examples assert, and the one thing the
-- addon must never do -- drop a stack onto the SAME item, which merges -- is still refused loudly.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")
local wow = env.wow

local Mail, Bank, Guild, Events

local ME      = "Bankchar-Testrealm"
local ALICE   = "Alice-Testrealm"
local LINEN   = 2589
local WOOL    = 2592
local STACK   = 20     -- the items' stack size: the harness's auto-stack reads `stackCount`
local VAULT   = -1     -- BANK_CONTAINER
local BANKBAG = 5      -- first bank bag: NUM_BAG_SLOTS + 1

--- Every container-moving API call, in order, as { name, ... }.
local calls
--- COLLECT-002: every swap the addon made, as { bag, slot, put, took }.
local swaps

--- Record the calls around the harness's own moves (installed by env.reset, captured per load).
local function recordMoves()
	local use, split, pickup, clear = C_Container.UseContainerItem, C_Container.SplitContainerItem,
		C_Container.PickupContainerItem, _G.ClearCursor
	C_Container.UseContainerItem = function(bag, slot)
		calls[#calls + 1] = { "UseContainerItem", bag, slot }
		return use(bag, slot)
	end
	C_Container.SplitContainerItem = function(bag, slot, amount)
		calls[#calls + 1] = { "SplitContainerItem", bag, slot, amount }
		return split(bag, slot, amount)
	end
	C_Container.PickupContainerItem = function(bag, slot)
		calls[#calls + 1] = { "PickupContainerItem", bag, slot }
		local tbl, held = wow.bags[bag], wow.cursor
		assert(tbl and slot >= 1 and slot <= tbl.slots,
			string.format("pickup targeted a slot that does not exist: %d/%s", bag, tostring(slot)))
		local there = tbl[slot]
		if held and there then
			assert(there.itemID ~= held.itemID, string.format(
				"dropped a stack onto the SAME item at %d/%d -- that merges, and the addon must not rely on it", bag, slot))
			swaps[#swaps + 1] = { bag = bag, slot = slot, put = held.itemID, took = there.itemID }
		end
		return pickup(bag, slot)
	end
	_G.ClearCursor = function()
		calls[#calls + 1] = { "ClearCursor" }
		return clear()
	end
end

local function load()
	env.reset(); env.stubOutput()
	-- LINK-AUDIT-001 step 4: Bank's matchers read a slot's suffix through Scan.parseLink (Record
	-- precedes Scan in both TOCs). Run alone, or first in a forward-order run (NTFS lists this file
	-- before bank_spec), this file had neither and REQ-003 raised on a nil global -- it passed in the
	-- declared halves only on a Scan an earlier file left behind (SPEC-ALONE-001's class).
	env.loadModules({
		"Modules/Constants.lua", "Modules/Item.lua",
		"Modules/Inventory/Record.lua", "Modules/Inventory/Scan.lua",
		"Modules/Guild.lua", "Modules/Bank.lua", "Modules/Mail.lua", "Modules/Events.lua",
	})
	Mail, Bank, Guild, Events = TOGBankClassic_Mail, TOGBankClassic_Bank, TOGBankClassic_Guild,
		TOGBankClassic_Events

	env.defineItem(LINEN, { name = "Linen Cloth", stackCount = STACK })
	env.defineItem(WOOL,  { name = "Wool Cloth", stackCount = STACK })
	Guild.Info = { name = "Testguild", alts = {}, requests = {} }
	Guild.IsBank = function(_, n) return n == ME end

	calls, swaps = {}, {}
	wow.bankAutoStack = true
	recordMoves()
	-- The harness reads the bank as open while a `BankFrame` global reports shown.
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

	-- BANKCOLLECT-SHARE-001 (Discord, crimsonmane 2026-10-08): the bags are one pool for every order
	-- of the same item. Measuring each order against the whole bag count let the stack pulled for the
	-- older order "cover" the newer one too, so the newer one was never collected for.
	it("hands the bags to the older order first, so a newer order of the same item is still collected for", function()
		vault(20, 20)
		bags(5)
		order("old", 5, { date = 100 })
		order("new", 5, { date = 200 })
		local req, short = Mail:FindOldestBankFillableOrder(ME)
		assert.equal("new", req.id, "the 5 in the bags belong to the older order, so the newer one is short")
		assert.equal(5, short)
		-- Bags covering both: nothing left to collect.
		bags(5, 5)
		assert.is_nil(Mail:FindOldestBankFillableOrder(ME))
	end)

	it("collects for the older order, then the newer one, clicking through at the bank", function()
		vault(20)
		order("old", 5, { date = 100 })
		order("new", 5, { date = 200 })
		click()   -- pulls the 20 for the older order
		click()   -- puts the spare 15 back
		assert.equal(5, inBags())
		local req, short = Mail:FindOldestBankFillableOrder(ME)
		assert.equal("new", req.id, "the newer order was treated as covered by the older order's stack")
		assert.equal(5, short)
		click(); click()
		assert.equal(10, inBags(), "the bags did not end holding both orders")
		assert.equal(10, inBank())
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

-- FCFS-001 (the operator, 2026-10-09, on crimsonmane's Discord report: "you are supposed to fill the
-- oldest order first. first come first server"). The mailbox search used to SKIP an order it could
-- not fill yet and mail the next one that fit -- so a newer, smaller order for the same item went
-- out first and spent the stock the older order was waiting on.
describe("the mailbox fills orders first come, first served", function()
	local BOB = "Bob-Testrealm"
	before_each(load)

	local function carry(linen, wool)
		local contents = {}
		if linen then contents[#contents + 1] = { id = LINEN, count = linen } end
		if wool then contents[#contents + 1] = { id = WOOL, count = wool } end
		env.setBag(0, 16, contents)
	end

	it("never sends a newer order for the same item ahead of an older one it cannot fill yet", function()
		carry(5)
		order("old", 10, { date = 100 })
		order("new", 5,  { date = 200 }).requester = BOB
		assert.is_nil(Mail:FindOldestServiceableOrder(ME),
			"the newer 5x order jumped the older 10x order for the same item")
	end)

	it("sends the older order once the bags cover it", function()
		carry(10)
		order("old", 10, { date = 100 })
		order("new", 5,  { date = 200 }).requester = BOB
		assert.equal("old", (Mail:FindOldestServiceableOrder(ME)).id)
	end)

	it("still sends an order for a DIFFERENT item while an older one waits", function()
		carry(5, 5)
		order("old",  10, { date = 100 })
		order("wool", 5,  { date = 200, name = "Wool Cloth", itemID = WOOL }).requester = BOB
		assert.equal("wool", (Mail:FindOldestServiceableOrder(ME)).id,
			"orders for other items do not compete for the same stacks and must not be held up")
	end)

	it("does not let a requester's newer order ride along ahead of someone else's older one", function()
		carry(5, 5)
		order("first", 5, { date = 100, name = "Wool Cloth", itemID = WOOL })   -- Alice, oldest
		order("bobs",  5, { date = 200 }).requester = BOB                         -- Bob's linen
		order("extra", 5, { date = 300 })                                        -- Alice's linen
		local req = Mail:FindOldestServiceableOrder(ME)
		assert.equal("first", req.id)
		local extras = Mail:FindMoreOrdersFor(ME, ALICE, "first", {}, 11)
		assert.equal(0, #extras, "Alice's newer linen order took the 5 linen Bob's older order needs")

		-- With enough for both, Alice's extra rides along.
		carry(10, 5)
		extras = Mail:FindMoreOrdersFor(ME, ALICE, "first", {}, 11)
		assert.equal(1, #extras)
		assert.equal("extra", extras[1].req.id)
	end)

	-- FCFS-SELF-001 (Peer Review bf89d59d): the reservation covered only OTHER people's orders, so a
	-- requester's own newer order rode along on the stock their own older order was waiting for.
	it("does not let a requester's newer order ride along ahead of their OWN older one", function()
		carry(5, 5)
		order("first", 5,  { date = 100, name = "Wool Cloth", itemID = WOOL })   -- Alice's wool, sent now
		order("older", 10, { date = 200 })                                        -- Alice's linen: 5 short
		order("newer", 5,  { date = 300 })                                        -- Alice's linen: fits
		local extras = Mail:FindMoreOrdersFor(ME, ALICE, "first", {}, 11)
		assert.equal(0, #extras, "Alice's newer 5x linen spent the stock her older 10x order is waiting on")
	end)

	-- Peer Review bf89d59d B2's worked case: older wants 20, bags 5, bank 0; newer wants 5. The review
	-- read the bank step as pulling for the newer order. It cannot: both orders match the same (empty)
	-- bank stock. With stock, the OLDER order is the one collected for.
	it("at the bank, never collects for a newer order ahead of an older one of the same item", function()
		carry(5)
		order("old", 20, { date = 100 })
		order("new", 5,  { date = 200 }).requester = BOB
		assert.is_nil(Mail:FindOldestBankFillableOrder(ME), "pulled for the newer order with an empty bank")
		vault(20)
		local req, short = Mail:FindOldestBankFillableOrder(ME)
		assert.equal("old", req.id)
		assert.equal(15, short)
	end)

	it("names the order holding the queue when nothing can be sent", function()
		carry(5)
		order("old", 10, { date = 100 })
		order("new", 5,  { date = 200 }).requester = BOB
		local savedMailFrame = _G.MailFrame
		_G.MailFrame = { IsShown = function() return true end }
		local ok, msg = Mail:FulfillStep(ME)
		_G.MailFrame = savedMailFrame
		assert.is_false(ok)
		assert.truthy(msg:find(ALICE, 1, true), msg)
		assert.truthy(msg:find("10x Linen Cloth", 1, true), msg)
	end)

	-- SUFFIX-KEY-001 (Peer Review bf89d59d): an order with no suffix is counted against EVERY variant of
	-- its item, so it competes with an "of the Bear" order of the same item although their keys differ.
	-- Such orders still arrive (stored before INV2-SUFFIX-001, from an old client, from another addon).
	describe("an order with no suffix competes with every variant of its item", function()
		local BEAR, TIGER = 863, 864

		local function carryVariants(bear, tiger)
			local contents = {}
			if bear then contents[#contents + 1] = { id = LINEN, count = bear, suffix = BEAR } end
			if tiger then contents[#contents + 1] = { id = LINEN, count = tiger, suffix = TIGER } end
			env.setBag(0, 16, contents)
		end

		it("holds a newer Bear order behind an older no-suffix order", function()
			carryVariants(5)
			order("old", 10, { date = 100 })
			order("new", 5,  { date = 200, suffixID = BEAR }).requester = BOB
			assert.is_nil(Mail:FindOldestServiceableOrder(ME),
				"the newer Bear order spent the stock the older any-variant order is waiting on")
		end)

		it("holds a newer no-suffix order behind an older Bear order", function()
			carryVariants(5)
			order("old", 10, { date = 100, suffixID = BEAR })
			order("new", 5,  { date = 200 }).requester = BOB
			assert.is_nil(Mail:FindOldestServiceableOrder(ME),
				"the newer any-variant order took the Bear stack the older Bear order is waiting on")
		end)

		it("does not hold a Tiger order behind a Bear order: they never share a stack", function()
			carryVariants(5, 5)
			order("old", 10, { date = 100, suffixID = BEAR })
			order("new", 5,  { date = 200, suffixID = TIGER }).requester = BOB
			assert.equal("new", (Mail:FindOldestServiceableOrder(ME)).id)
		end)

		it("keeps an older no-suffix order's claim when a newer Bear order would ride along", function()
			env.setBag(0, 16, {
				{ id = WOOL, count = 5 },
				{ id = LINEN, count = 5, suffix = BEAR },
			})
			order("first", 5, { date = 100, name = "Wool Cloth", itemID = WOOL })   -- Alice, sent now
			order("bobs",  5, { date = 200 }).requester = BOB                         -- Bob: any linen
			order("extra", 5, { date = 300, suffixID = BEAR })                       -- Alice: Bear linen
			local extras = Mail:FindMoreOrdersFor(ME, ALICE, "first", {}, 11)
			assert.equal(0, #extras, "Alice's newer Bear order rode on the 5 linen Bob's older order needs")
		end)

		it("at the bank, collects for a newer Bear order once an older no-suffix order has the bag stack", function()
			carryVariants(5)
			order("old", 5, { date = 100 })
			order("new", 5, { date = 200, suffixID = BEAR }).requester = BOB
			env.setBag(VAULT, 24, { { id = LINEN, count = 20, suffix = BEAR } })
			local req, short = Mail:FindOldestBankFillableOrder(ME)
			assert.equal("new", req and req.id,
				"the Bear order was measured against the bag stack the older order already has")
			assert.equal(5, short)
		end)
	end)

	-- NAME-POOL-001 (Peer Review 1aa094de F1): an order with no item id (stored before REQ-001, or from
	-- an old client) is counted in the bags by name, so it takes every item of that name and competes
	-- with the orders that carry an id.
	describe("an order with no item id competes with the orders of its name", function()
		local function noId(req) req.itemID = nil; return req end

		it("holds a newer id order behind an older no-id order", function()
			carry(5)
			noId(order("old", 10, { date = 100 }))
			order("new", 5, { date = 200 }).requester = BOB
			assert.is_nil(Mail:FindOldestServiceableOrder(ME),
				"the newer id order spent the stock the older no-id order is waiting on")
		end)

		it("holds a newer no-id order behind an older id order", function()
			carry(5)
			order("old", 10, { date = 100 })
			noId(order("new", 5, { date = 200 })).requester = BOB
			assert.is_nil(Mail:FindOldestServiceableOrder(ME),
				"the newer no-id order took the linen the older order is waiting on")
		end)

		it("does not hold an order for a differently named item", function()
			carry(5, 5)
			noId(order("old", 10, { date = 100 }))
			order("wool", 5, { date = 200, name = "Wool Cloth", itemID = WOOL }).requester = BOB
			assert.equal("wool", (Mail:FindOldestServiceableOrder(ME)).id)
		end)

		it("matches the name whatever its case", function()
			carry(5)
			noId(order("old", 10, { date = 100, name = "linen cloth" }))
			order("new", 5, { date = 200 }).requester = BOB
			assert.is_nil(Mail:FindOldestServiceableOrder(ME))
		end)

		-- Peer Review 104ff6f7 N1: the name key was tostring(item), so every order with no name shared
		-- the key "nil" and an older nameless no-id order held every nameless order behind it.
		it("does not let an order with no id and no name hold an id order that has no name either", function()
			carry(5)
			noId(order("old", 10, { date = 100 })).item = nil
			order("new", 5, { date = 200 }).item = nil
			local req = Mail:FindOldestServiceableOrder(ME)
			assert.equal("new", req and req.id, "a nameless no-id order held a nameless id order under the key 'nil'")
		end)
	end)
end)

-- COLLECT-LAG-001 (Peer Review bf89d59d): TakeInboxItem is async. The inbox drops the attachment
-- before the bags show it, so for a moment the pulled stack is in neither. An order reads blocked in
-- that moment and Fulfill Oldest serves another order; the pull count for the first order used to be
-- thrown away then, and recomputed from the lagging bag count when that order came back -- pulling
-- again what was already on its way. The harness's TakeInboxItem only records the take, so each
-- example stages the lag by hand: the attachment leaves the inbox and does not reach the bags.
describe("pulling from the mail while a take is still landing", function()
	local savedMailFrame
	before_each(function()
		load()
		savedMailFrame = _G.MailFrame
		_G.MailFrame = { IsShown = function() return true end }
	end)
	after_each(function() _G.MailFrame = savedMailFrame end)

	local function linenMail(count)
		local _, link = GetItemInfo(LINEN)
		wow.mail[#wow.mail + 1] = { sender = "Somebody", items = { { name = "Linen Cloth", id = LINEN, count = count, link = link } } }
	end

	local function takes()
		local out = {}
		for _, a in ipairs(wow.mailActions) do if a.action == "take" then out[#out + 1] = a end end
		return out
	end

	--- The last take left the inbox; the bags have not shown it yet.
	local function inFlight()
		local t = takes()[#takes()]
		wow.mail[t.index].items[t.attachment] = nil
	end

	--- 1.5s later: the in-flight guard's own C_Timer.After has run (COLLECT-GUARD-TIMER-001, Peer
	--- Review 074cdad6 A4: this used to clear the flag by hand, so a change to how the guard clears
	--- could not show here).
	local function guardElapsed()
		assert.is_true(Mail.collectInFlight, "precondition: the take raised the in-flight guard")
		env.advance(1.5)
		assert.is_false(Mail.collectInFlight, "the guard's timer did not clear it after 1.5s")
	end

	it("keeps an order's pull count while another order is served in the gap", function()
		order("old", 10, { date = 100 })
		order("wool", 5, { date = 200, name = "Wool Cloth", itemID = WOOL })
		env.setBag(0, 16, { { id = WOOL, count = 5 } })
		linenMail(5); linenMail(5)

		assert.is_true((Mail:FulfillStep(ME)))   -- pulls the first 5 linen for "old"
		assert.equal(1, #takes(), "precondition: the first click pulled from the mail")
		inFlight(); guardElapsed()

		-- "old" reads 0 in bags + 5 in mail, short of 10: the wool order is served instead.
		assert.is_true((Mail:FulfillStep(ME)))
		assert.equal("wool", Mail.batchState and Mail.batchState.req.id, "precondition: the gap served the wool order")
		Mail.batchState = nil                    -- that mail went
		Guild.Info.requests.wool.fulfilled = 5
		env.setBag(0, 16, {})

		linenMail(5)                             -- more linen arrives; the first 5 still have not landed
		assert.is_true((Mail:FulfillStep(ME)))   -- the second 5
		guardElapsed()
		Mail:FulfillStep(ME)                     -- 10 are on their way: nothing more to pull
		assert.equal(2, #takes(), "pulled a third stack for an order that needed two; the first was still landing")
	end)

	it("forgets the pull count when the mailbox closes", function()
		order("old", 10, { date = 100 })
		linenMail(5); linenMail(5)
		assert.is_true((Mail:FulfillStep(ME)))
		assert.is_table(Mail.collectStates, "precondition: the pull was counted")
		Mail:ResetFulfillStep()
		assert.is_nil(Mail.collectStates, "a pull count outlived the mailbox")
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

		-- (7) -- was "refuses with full bags". COLLECT-002 (NanaTheBanana: "if the bag is full, it
		-- will swap items in the inventory for the missing items"; the operator: "put things into the
		-- bank when the bags are full that aren't needed to fill an order"): the click now SWAPS an
		-- unneeded carried stack for the wanted bank stack. Same button, same step, no new UI.
		it("with full bags, swaps an unneeded carried stack into the bank for the wanted one", function()
			local full = {}
			for i = 1, 16 do full[i] = { id = WOOL, count = 1 } end
			env.setBag(0, 16, full)
			vault(5)
			order("r1", 5)
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.truthy(msg:find("swapped"), msg)
			assert.equal(0, callsNamed("UseContainerItem"), "a plain move-out with full bags is a no-op in the client")
			assert.equal(2, callsNamed("PickupContainerItem"), "a swap is one pick-up and one drop")
			assert.equal(1, #swaps)
			assert.equal(WOOL, swaps[1].put)
			assert.equal(LINEN, swaps[1].took)
			assert.equal(VAULT, swaps[1].bag)
			assert.equal(5, inBags(), "the wanted stack did not land in the bags")
			assert.equal(0, inBank())
			assert.equal(1, Bank:CountItemInBank(nil, WOOL), "the spare wool did not go into the bank")
			assert.equal(15, Bank:CountItemInBags(nil, WOOL))
			assert.is_nil(wow.cursor, "something was left on the cursor")
			assert.is_nil(Mail.bankCollectState, "an exact swap has nothing to return")
		end)

		it("swaps and then returns the surplus, exactly like a plain pull that overshot", function()
			local full = {}
			for i = 1, 16 do full[i] = { id = WOOL, count = 1 } end
			env.setBag(0, 16, full)
			vault(20)
			order("r1", 5)
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.equal("return", Mail.bankCollectState.phase)
			assert.equal(15, Mail.bankCollectState.surplus)
			assert.truthy(msg:find("spare 15"), msg)
			-- The swap freed a vault slot (the wool took one, the linen left one), so the spare goes back.
			ok, msg = click()
			assert.is_true(ok, msg)
			assert.equal(5, inBags())
			assert.equal(15, inBank())
			assert.is_nil(Mail.bankCollectState)
		end)

		it("never swaps out a stack an open order needs, and says so when every stack is needed", function()
			-- Bags: 15 wool + 1 linen, all 16 slots. Two orders: linen (short) and wool (covered).
			local full = {}
			for i = 1, 15 do full[i] = { id = WOOL, count = 1 } end
			full[16] = { id = LINEN, count = 1 }
			env.setBag(0, 16, full)
			vault(5)
			order("r1", 6)                                     -- linen: 1 in bags, needs 5 more
			order("r2", 15, { name = "Wool Cloth", itemID = WOOL, date = 2000 })   -- wool: covered, must stay
			local ok, msg = click()
			assert.is_false(ok)
			assert.truthy(msg:find("everything in them is needed"), msg)
			assert.equal(0, #swaps)
			assert.equal(15, Bank:CountItemInBags(nil, WOOL), "a stack an order needs was swapped out")
			assert.equal(1, inBags())
		end)

		it("protects a legacy request's item by name when it carries no itemID", function()
			local full = {}
			for i = 1, 15 do full[i] = { id = WOOL, count = 1 } end
			full[16] = { id = 6948, count = 1 }                -- a hearthstone: never swapped out
			env.defineItem(6948, { name = "Hearthstone" })
			env.setBag(0, 16, full)
			vault(5)
			order("r1", 5)
			order("r2", 1, { name = "Wool Cloth", itemID = nil, date = 2000 })
			Guild.Info.requests.r2.itemID = nil
			local ok, msg = click()
			assert.is_false(ok)
			assert.truthy(msg:find("everything in them is needed"), msg)
			assert.equal(1, Bank:CountItemInBags(nil, 6948), "the hearthstone was swapped into the bank")
		end)

		it("swaps the first unneeded stack in bag order, leaving needed ones alone", function()
			env.defineItem(6948, { name = "Hearthstone" })
			local full = {}
			full[1] = { id = 6948, count = 1 }
			full[2] = { id = LINEN, count = 1 }
			for i = 3, 16 do full[i] = { id = WOOL, count = 1 } end
			env.setBag(0, 16, full)
			vault(4)
			order("r1", 5)
			local ok, msg = click()
			assert.is_true(ok, msg)
			assert.equal(VAULT, swaps[1].bag)
			assert.equal(WOOL, swaps[1].put)
			assert.equal(3, calls[2][3], "the swap did not take the first UNNEEDED slot (slot 3; 1 is the hearthstone, 2 is linen)")
			assert.equal(1, Bank:CountItemInBags(nil, 6948))
			assert.equal(5, inBags())
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
			assert.is_nil(wow.cursor, "the split stack must not be left on the cursor")
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
			assert.equal(13, env.bags[VAULT][24].count)
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
					wow.bankAutoStack = merge
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
					assert.is_nil(wow.cursor, label .. ": something was left on the cursor")
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
			assert.equal(20, env.bags[VAULT][1].count, "the look-alike stays banked")
		end)

		it("pulls only the suffix variant the order names (REQ-003)", function()
			env.setBag(VAULT, 24, {
				{ id = LINEN, count = 5, suffix = 863 },
				{ id = LINEN, count = 5, suffix = 864 },
			})
			order("r1", 5, { suffixID = 864 })
			assert.is_true((click()))
			assert.is_nil(env.bags[VAULT][2], "the 864 stack is the one that moved")
			assert.equal(5, env.bags[VAULT][1].count)
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
		Mail.collectStates = { r1 = { pulled = 1 } }
		Mail.bankCollectState = { phase = "return", surplus = 1 }
		assert.is_not_nil(Mail.batchState); assert.is_not_nil(Mail.collectStates); assert.is_not_nil(Mail.bankCollectState)
		Mail:ResetFulfillStep()
		assert.is_nil(Mail.batchState)
		assert.is_nil(Mail.collectStates)
		assert.is_nil(Mail.bankCollectState)
	end)
end)
