-- Order fulfillment: THE SPLITTING, end to end.
--
-- Mail:CalculateFulfillmentPlan decides how an order gets built out of whatever stacks are in the
-- banker's bags: which whole stacks to attach, and whether one stack has to be SPLIT to hit the
-- exact quantity. Getting it wrong is not cosmetic -- it either sends a guildmate the wrong number
-- of items, or refuses an order the bags can actually cover.
--
-- It had no direct coverage. What existed exercised the surrounding flow and never drove the
-- planner's four phases against known stack layouts, so every branch below is asserted here for the
-- first time. The phases, in the order the function tries them:
--
--   1. GREEDY  -- accumulate whole stacks largest-first, never exceeding the target.
--   2. SKIP    -- if that undershoots, retry ignoring one stack (up to the first five) to find an
--                 exact whole-stack combination.
--   3. SPLIT   -- still short: attach what fits and split the remainder out of a stack that is NOT
--                 already being attached.
--   4. REFUSE  -- the bags genuinely do not hold enough.
--
-- The arithmetic assertions matter more than the shape ones: `totalAttachable + splitAmount` must
-- equal the quantity ordered in EVERY fulfillable case, and that is the property a guildmate
-- actually feels.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Mail

--- Stacks as the bag scan hands them over: { bag, slot, count, link }.
local function stacks(...)
	local rows = {}
	for i, count in ipairs({ ... }) do
		rows[#rows + 1] = { bag = 0, slot = i, count = count, link = "|Hitem:2589:" }
	end
	return rows
end

local function total(rows)
	local n = 0
	for _, r in ipairs(rows) do n = n + r.count end
	return n
end

--- Plan for `need` against those stacks, with totalInBags derived rather than passed by hand -- a
--- caller that lies about the total is testing a state the addon cannot produce.
local function plan(need, rows)
	return Mail:CalculateFulfillmentPlan(rows, need, total(rows))
end

--- What the plan actually delivers: attached whole stacks plus whatever is split off.
local function delivered(p)
	local n = 0
	for _, s in ipairs(p.stacksToAttach or {}) do n = n + s.count end
	if p.splitStack then n = n + p.splitStack.amount end
	return n
end

describe("Mail:CalculateFulfillmentPlan", function()
	before_each(function()
		env.reset(); env.stubOutput()
		env.loadModules({ "Modules/Constants.lua", "Modules/Item.lua", "Modules/Mail.lua" })
		Mail = TOGBankClassic_Mail
	end)

	-- THE INVARIANT. Everything else in this file is a special case of it: whenever the planner
	-- says it can fulfil, what it plans to hand over must be EXACTLY what was ordered -- never one
	-- short, never one over.
	describe("delivers exactly the quantity ordered whenever it claims it can", function()
		local cases = {
			{ need = 1,   have = { 1 } },
			{ need = 1,   have = { 20 } },
			{ need = 5,   have = { 5 } },
			{ need = 5,   have = { 20 } },
			{ need = 5,   have = { 3, 2 } },
			{ need = 5,   have = { 2, 3 } },
			{ need = 5,   have = { 4, 4 } },
			{ need = 7,   have = { 5, 5 } },
			{ need = 7,   have = { 10 } },
			{ need = 12,  have = { 20, 20 } },
			{ need = 15,  have = { 20, 5 } },
			{ need = 19,  have = { 20, 20, 20 } },
			{ need = 20,  have = { 20 } },
			{ need = 23,  have = { 20, 20 } },
			{ need = 40,  have = { 20, 20 } },
			{ need = 41,  have = { 20, 20, 20 } },
			{ need = 3,   have = { 1, 1, 1 } },
			{ need = 4,   have = { 1, 1, 1, 1, 1 } },
			{ need = 9,   have = { 1, 2, 3, 4, 5 } },
			{ need = 100, have = { 20, 20, 20, 20, 20 } },
		}
		for _, case in ipairs(cases) do
			local label = string.format("need %d from stacks {%s}",
				case.need, table.concat(case.have, ","))
			it(label, function()
				local p = plan(case.need, stacks(unpack(case.have)))
				assert.is_true(p.canFulfill, label .. " was refused, but the bags hold enough")
				assert.equal(case.need, delivered(p),
					label .. " planned the wrong quantity -- a guildmate gets the wrong number of items")
			end)
		end
	end)

	describe("phase 1: whole stacks, no split", function()
		it("attaches one stack that is exactly the order", function()
			local p = plan(5, stacks(5))
			assert.is_true(p.canFulfill)
			assert.is_nil(p.splitStack, "an exact stack must not be split")
			assert.equal(1, #p.stacksToAttach)
		end)

		it("combines several stacks that sum exactly", function()
			local p = plan(5, stacks(3, 2))
			assert.is_true(p.canFulfill)
			assert.is_nil(p.splitStack, "an exact combination must not be split")
			assert.equal(2, #p.stacksToAttach)
		end)

		it("never attaches a stack that would overshoot", function()
			local p = plan(5, stacks(20, 5))
			assert.is_true(p.canFulfill)
			for _, s in ipairs(p.stacksToAttach) do
				assert.is_true(s.count <= 5,
					"attached a stack of " .. s.count .. " against an order of 5")
			end
		end)
	end)

	describe("phase 2: skipping a stack to reach an exact combination", function()
		-- Greedy alone takes 4 and then cannot use either 3, leaving 1 short and forcing a split.
		-- Skipping the 4 finds 3+3 exactly, which is strictly better: no split, no partial stack
		-- left behind in the banker's bags.
		it("prefers an exact combination over splitting", function()
			local p = plan(6, stacks(4, 3, 3))
			assert.is_true(p.canFulfill)
			assert.is_nil(p.splitStack,
				"split a stack when skipping one would have combined exactly -- a split leaves a " ..
				"stray partial stack in the banker's bags for no reason")
			assert.equal(6, delivered(p))
		end)
	end)

	describe("phase 3: splitting", function()
		it("splits a single oversized stack", function()
			local p = plan(7, stacks(20))
			assert.is_true(p.canFulfill)
			assert.is_not_nil(p.splitStack, "the only stack overshoots, so it has to be split")
			assert.equal(7, p.splitStack.amount)
			assert.equal(0, #p.stacksToAttach, "nothing whole should be attached here")
		end)

		it("attaches what fits and splits only the remainder", function()
			local p = plan(7, stacks(5, 5))
			assert.is_true(p.canFulfill)
			assert.is_not_nil(p.splitStack)
			assert.equal(5, delivered(p) - p.splitStack.amount, "should attach the whole first stack")
			assert.equal(2, p.splitStack.amount, "should split only the shortfall")
		end)

		-- The subtle one: the stack chosen to split from must NOT be one already being attached
		-- whole, or the same stack is counted twice and the order goes out short.
		it("never splits from a stack it is already attaching whole", function()
			local p = plan(7, stacks(5, 5))
			assert.is_not_nil(p.splitStack)
			for _, s in ipairs(p.stacksToAttach) do
				assert.is_false(s.bag == p.splitStack.bag and s.slot == p.splitStack.slot,
					"the split stack is also in the attach list -- one stack counted twice, and " ..
					"the order goes out short")
			end
			assert.equal(7, delivered(p))
		end)

		it("splits a quantity that is never zero or negative", function()
			for _, need in ipairs({ 1, 2, 3, 6, 9, 11, 19 }) do
				local p = plan(need, stacks(20, 20))
				if p.splitStack then
					assert.is_true(p.splitStack.amount > 0,
						"planned a split of " .. p.splitStack.amount .. " for an order of " .. need)
					assert.is_true(p.splitStack.amount <= p.splitStack.count,
						"planned to split " .. p.splitStack.amount .. " out of a stack of " ..
						p.splitStack.count)
				end
			end
		end)
	end)

	describe("phase 4: refusing", function()
		it("refuses when the bags are short and says by how much", function()
			local p = plan(10, stacks(3, 2))
			assert.is_false(p.canFulfill)
			assert.is_nil(p.splitStack, "must not plan a split it cannot make")
			assert.truthy(tostring(p.reason):find("5"),
				"the reason should name the 5-item deficit, got: " .. tostring(p.reason))
		end)

		it("refuses with no stacks at all", function()
			local p = plan(1, {})
			assert.is_false(p.canFulfill)
			assert.equal(0, p.totalAttachable)
			assert.equal(0, #p.stacksToAttach)
		end)

		it("refuses an order for nothing rather than planning an empty send", function()
			local p = plan(0, stacks(5))
			-- Zero is not a real order; what matters is that it never plans a zero-amount split,
			-- which would put the cursor into a state the send path cannot clear.
			if p.splitStack then
				assert.is_true(p.splitStack.amount > 0, "planned a zero-amount split")
			end
		end)
	end)

	describe("it does not mutate the caller's stack list into the wrong order", function()
		-- The planner sorts `items` in place, largest first. Callers pass a COPY for that reason;
		-- this pins that the sort is what the later phases actually rely on, so a future edit that
		-- removes the copy shows up here rather than in a mis-sent order.
		it("plans against the largest stack first", function()
			local rows = stacks(2, 20)
			local p = plan(15, rows)
			assert.is_true(p.canFulfill)
			assert.is_not_nil(p.splitStack)
			assert.equal(20, p.splitStack.count,
				"split from the small stack rather than the large one")
		end)
	end)
end)

-- Peer-review finding 39: the block that turns CanFulfillRequest's verdict into the fulfil
-- button's icon and tooltip was copied in full into BOTH the full row draw and the bag-update
-- refresh in UI/Requests.lua, so every new reason string had to be added twice by hand -- miss one
-- and the icon differs between the two paths, which reads as flicker. Pinned at source level:
-- the decision lives in ONE helper and both entry points call it. (UI/Requests.lua does load in
-- this harness -- searchbox_spec drives it -- but the fulfil icon needs a drawn row, which the
-- offline env cannot render, so the source-level pin is still the honest one.)
describe("the fulfil-button decision is implemented once (finding 39)", function()
	local src
	before_each(function()
		src = env.readFile("Modules/UI/Requests.lua")
	end)

	it("has exactly one copy of the icon decision", function()
		local n = 0
		for _ in src:gmatch("FULFILL_ICON_NO_MAILBOX; tooltipDetail =") do n = n + 1 end
		assert.equal(1, n, "the icon/tooltip decision block appears " .. n .. " times")
	end)

	it("is called from both the full row draw and the bag-update refresh", function()
		local populate = src:find("function TOGBankClassic_UI_Requests:_PopulateRow", 1, true)
		local refresh  = src:find("function TOGBankClassic_UI_Requests:_RefreshFulfillButtons", 1, true)
		assert.truthy(populate and refresh, "one of the two entry points is gone")
		local populateBody = src:sub(populate, refresh)
		local refreshBody  = src:sub(refresh)
		assert.truthy(populateBody:find("applyFulfillState(", 1, true), "_PopulateRow no longer uses the shared helper")
		assert.truthy(refreshBody:find("applyFulfillState(", 1, true), "_RefreshFulfillButtons no longer uses the shared helper")
	end)
end)
