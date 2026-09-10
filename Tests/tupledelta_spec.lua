-- INV2 — the tuple delta (ComputeTupleDelta / ApplyTupleDelta).
--
-- These replace ComputeItemDelta's link-derived identity machinery. The point is not that the new
-- code is shorter; it is that a whole CLASS of failure stops existing. ComputeItemDelta keys an
-- item by `Item:GetItemKey(item.Link or item.ItemString)`, so the same logical item keys
-- differently depending on whether the row arrived with a full link, an ItemString, or neither —
-- and BuildItemIndex, an ID-only index, a per-ID deep-fallback scan and `deepFallbackUsed` all
-- exist to paper over that. A tuple has one spelling, so identity is a hash lookup.
--
-- The suffix-variant case below is the one that matters most: two rows sharing a base ID and
-- differing only by suffix are DIFFERENT ITEMS. Link-keying got this wrong (the deep fallback
-- exists because of it), and it is the same defect REQ-001 fixed on the request side.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local D, Record

local function load()
	env.stubOutput()
	env.loadModules({
		"Modules/Constants.lua",
		"Modules/Item.lua",
		"Modules/Inventory/Record.lua",
		"Modules/DeltaComms.lua",
	})
	D = TOGBankClassic_DeltaComms
	Record = TOGBankClassic_Inventory_Record
	return D
end

--- Keys present in a tuple list, as a set, so assertions do not depend on ordering.
local function keysOf(list)
	local set = {}
	for _, rec in ipairs(list) do set[Record.key(rec)] = Record.count(rec) end
	return set
end

-- AUDIT FINDING 33. `Record.aggregate`'s docstring promises that one bad row will not discard the
-- rest -- the ITEM-005 lesson. It walked with `ipairs`, and `ipairs` STOPS AT THE FIRST NIL, so a
-- hole truncated silently and `skipped` did not count it: the return value reported nothing wrong.
--
-- The asymmetry is the whole reason this is worth a fix rather than a comment. A hole in the OLD
-- side under-reports it, so rows re-appear as `added` -- wasteful, self-correcting. A hole in the
-- NEW side makes every row after it absent from the new map, so they are all emitted as `removed`:
-- a delta instructing the receiver to DELETE ITEMS THE SENDER STILL HOLDS, in a message that looks
-- entirely legitimate.
--
-- The reviewer was explicit that they found no production path creating a hole. That is why these
-- construct one deliberately -- the finding is that nothing asserted density, nothing documented it,
-- and the docstring asserted the opposite, so the guarantee was one refactor away from being
-- load-bearing and wrong.
describe("Record.aggregate tolerates a hole (finding 33)", function()
	before_each(function() env.reset(); load() end)

	it("keeps rows positioned after a nil hole", function()
		local withHole = { { 858, 5 }, nil, { 10132, 1 }, { 4306, 2 } }
		local map = Record.aggregate(withHole)
		local seen = {}
		for key in pairs(map) do seen[key] = true end
		assert.is_true(seen["858:0:0"], "the row before the hole was lost")
		assert.is_true(seen["10132:0:0"],
			"the row after a nil hole was discarded -- ipairs stopped at the hole, so this row " ..
			"is absent from the new map and ComputeTupleDelta would emit it as REMOVED")
		assert.is_true(seen["4306:0:0"], "every row after the hole was discarded")
	end)

	it("does not report a hole as a skipped invalid row", function()
		local _, skipped = Record.aggregate({ { 858, 5 }, nil, { 10132, 1 } })
		assert.equal(0, skipped,
			"a nil hole is absent, not invalid; counting it would make a legitimate sparse array " ..
			"look like corrupt input")
	end)

	-- The consequence the finding actually names, driven end to end rather than argued.
	it("does not emit rows after a hole in the NEW side as removals", function()
		local old = { { 858, 5 }, { 10132, 1 }, { 4306, 2 } }
		local new = { { 858, 5 }, nil, { 10132, 1 }, { 4306, 2 } }
		local d = D:ComputeTupleDelta(old, new)
		assert.equal(0, #(d.removed or {}), string.format(
			"%d row(s) were emitted as REMOVED because a hole truncated the new side -- the " ..
			"receiver would delete items the sender still holds", #(d.removed or {})))
	end)

	it("still counts a genuinely invalid row as skipped", function()
		local _, skipped = Record.aggregate({ { 858, 5 }, { -1, 5 }, { 4306, 0 }, "not a record" })
		assert.is_true(skipped >= 3,
			"invalid rows must still be counted, or the tolerance above becomes silence")
	end)
end)

describe("ComputeTupleDelta", function()
	before_each(function() env.reset(); load() end)

	it("reports an item present only in the new set as added", function()
		local d = D:ComputeTupleDelta({}, { { 858, 5 } })
		assert.equal(1, #d.added)
		assert.equal(858, Record.id(d.added[1]))
		assert.equal(0, #d.modified)
		assert.equal(0, #d.removed)
	end)

	it("reports an item present only in the old set as removed, by key alone", function()
		local d = D:ComputeTupleDelta({ { 858, 5 } }, {})
		assert.same({ "858:0:0" }, d.removed,
			"removed must carry the KEY, not the tuple -- a removal needs no counts")
		assert.equal(0, #d.added)
	end)

	it("reports a changed stack as modified, carrying the whole new row", function()
		local d = D:ComputeTupleDelta({ { 858, 5 } }, { { 858, 9 } })
		assert.equal(1, #d.modified)
		assert.equal(9, Record.count(d.modified[1]),
			"modified must carry the absolute count. A count DIFFERENCE would make a duplicated " ..
			"delta double the stack")
		assert.equal(0, #d.added)
		assert.equal(0, #d.removed)
	end)

	it("reports nothing at all when the two sides agree", function()
		local d = D:ComputeTupleDelta({ { 858, 5 }, { 10132, 1, 863 } },
			{ { 10132, 1, 863 }, { 858, 5 } })
		assert.equal(0, #d.added)
		assert.equal(0, #d.modified)
		assert.equal(0, #d.removed)
	end)

	-- THE ONE THAT MATTERS. Same base ID, different suffix: two different items. Link-derived
	-- keying collapsed these onto one another, which is why ComputeItemDelta needs a deep-fallback
	-- candidate list and a `deepFallbackUsed` set to stop it.
	it("keeps suffix variants of one base ID apart", function()
		local d = D:ComputeTupleDelta({ { 15260, 1, 863 } }, { { 15260, 1, 863 }, { 15260, 1, 2504 } })
		assert.equal(1, #d.added, "the second suffix variant was matched against the first")
		assert.equal(2504, Record.suffix(d.added[1]))
		assert.equal(0, #d.modified)
		assert.equal(0, #d.removed)
	end)

	it("treats a suffix change as an add plus a remove, never as a modify", function()
		local d = D:ComputeTupleDelta({ { 15260, 1, 863 } }, { { 15260, 1, 2504 } })
		assert.equal(1, #d.added)
		assert.same({ "15260:863:0" }, d.removed)
		assert.equal(0, #d.modified,
			"suffix is part of identity -- a different suffix is a different item, not a change")
	end)

	it("aggregates duplicate rows on each side before comparing", function()
		-- Two stacks of the same item in one input must not read as a change.
		local d = D:ComputeTupleDelta({ { 858, 2 }, { 858, 3 } }, { { 858, 5 } })
		assert.equal(0, #d.modified, "5 == 2+3, so there is no change to report")
		assert.equal(0, #d.added)
		assert.equal(0, #d.removed)
	end)

	it("orders its output stably, so an unchanged inventory serialises identically twice", function()
		local a = D:ComputeTupleDelta({}, { { 10132, 1 }, { 858, 1 }, { 4306, 1 } })
		local b = D:ComputeTupleDelta({}, { { 4306, 1 }, { 10132, 1 }, { 858, 1 } })
		assert.same(keysOf(a.added), keysOf(b.added))
		for i = 1, #a.added do
			assert.equal(Record.key(a.added[i]), Record.key(b.added[i]),
				"the same inventory produced two orderings, so a checksum over it means nothing")
		end
	end)

	it("survives nil inputs rather than erroring", function()
		local d = D:ComputeTupleDelta(nil, nil)
		assert.equal(0, #d.added)
		assert.equal(0, #d.modified)
		assert.equal(0, #d.removed)
	end)
end)

describe("ApplyTupleDelta", function()
	before_each(function() env.reset(); load() end)

	--- Compute a delta and apply it, returning the result as a key->count set.
	local function roundTrip(oldRecs, newRecs)
		return keysOf(D:ApplyTupleDelta(oldRecs, D:ComputeTupleDelta(oldRecs, newRecs)))
	end

	-- The property that actually matters: compute-then-apply must reproduce the new set exactly.
	-- Asserting the three lists individually would pass against a delta that is internally
	-- consistent and still wrong.
	it("round-trips an add, a modify and a remove together", function()
		local old = { { 858, 5 }, { 4306, 10 }, { 10132, 1, 863 } }
		local new = { { 858, 5 }, { 4306, 2 }, { 15260, 1 } }
		assert.same(keysOf({ { 858, 5 }, { 4306, 2 }, { 15260, 1 } }), roundTrip(old, new))
	end)

	it("round-trips suffix variants without merging them", function()
		local new = { { 15260, 1, 863 }, { 15260, 2, 2504 } }
		assert.same(keysOf(new), roundTrip({ { 15260, 1, 863 } }, new))
	end)

	it("round-trips to empty when everything is removed", function()
		assert.same({}, roundTrip({ { 858, 5 }, { 4306, 1 } }, {}))
	end)

	-- A duplicated or replayed message must not double a stack. This is why `modified` carries the
	-- absolute count rather than a difference.
	it("is idempotent when the same delta is applied twice", function()
		local old = { { 858, 5 } }
		local delta = D:ComputeTupleDelta(old, { { 858, 9 } })
		local once  = D:ApplyTupleDelta(old, delta)
		local twice = D:ApplyTupleDelta(once, delta)
		assert.same(keysOf(once), keysOf(twice))
		assert.equal(9, keysOf(twice)["858:0:0"])
	end)

	it("ignores a malformed row on the wire rather than storing it", function()
		local out = D:ApplyTupleDelta({}, { added = { { 858, 5 }, { -1, 5 }, { 4306, 0 } }, modified = {}, removed = {} })
		assert.same({ ["858:0:0"] = 5 }, keysOf(out),
			"a hostile or buggy peer's malformed tuple reached the store")
	end)

	it("returns the records untouched when handed a non-table delta", function()
		assert.same({ { 858, 5 } }, D:ApplyTupleDelta({ { 858, 5 } }, nil))
	end)
end)
