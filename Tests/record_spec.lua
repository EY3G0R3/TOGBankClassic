-- Inventory/Record — the V2 item tuple.
--
-- This replaces link strings as the addon's item identity. The whole point is that two
-- references to the same physical item can have exactly one spelling, so the miscount class
-- (same item keyed two ways, aggregated as two rows with split counts) becomes impossible
-- rather than defended against. These specs pin that property, not just the arithmetic.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Record

describe("Record.new", function()
	before_each(function()
		env.reset()
		env.loadFile("Modules/Inventory/Record.lua")
		Record = TOGBankClassic_Inventory_Record
	end)

	it("builds a two-element tuple for a plain item", function()
		assert.same({ 858, 20 }, Record.new(858, 20))
	end)

	it("omits a zero suffix rather than storing it", function()
		assert.same({ 858, 20 }, Record.new(858, 20, 0))
	end)

	it("carries a suffix when present", function()
		assert.same({ 10132, 1, 863 }, Record.new(10132, 1, 863))
	end)

	it("carries an enchant, keeping suffix in slot 3", function()
		assert.same({ 10132, 1, 863, 2504 }, Record.new(10132, 1, 863, 2504))
	end)

	-- Positional storage means an enchant with no suffix still needs a 0 placeholder, or the
	-- enchant lands in the suffix slot and becomes a different item entirely.
	it("keeps a zero suffix placeholder when an enchant is present", function()
		assert.same({ 858, 1, 0, 2504 }, Record.new(858, 1, nil, 2504))
	end)

	-- Negative suffixes index the random-property table rather than the random-suffix table.
	-- Dropping the sign would merge two genuinely different items.
	it("preserves a negative suffix", function()
		assert.same({ 10132, 1, -25 }, Record.new(10132, 1, -25))
	end)

	it("accepts numeric strings", function()
		assert.same({ 858, 20 }, Record.new("858", "20"))
	end)

	it("rejects a nil, zero or negative id", function()
		assert.is_nil(Record.new(nil, 1))
		assert.is_nil(Record.new(0, 1))
		assert.is_nil(Record.new(-5, 1))
	end)

	it("rejects a zero or negative count", function()
		assert.is_nil(Record.new(858, 0))
		assert.is_nil(Record.new(858, -3))
	end)

	it("rejects a non-numeric id", function()
		assert.is_nil(Record.new("not-a-number", 1))
	end)
end)

describe("Record accessors", function()
	before_each(function()
		env.reset()
		env.loadFile("Modules/Inventory/Record.lua")
		Record = TOGBankClassic_Inventory_Record
	end)

	it("reads each field", function()
		local r = Record.new(10132, 3, 863, 2504)
		assert.equal(10132, Record.id(r))
		assert.equal(3,     Record.count(r))
		assert.equal(863,   Record.suffix(r))
		assert.equal(2504,  Record.enchant(r))
	end)

	-- Absent fields read as 0, never nil, so no caller needs a guard before arithmetic.
	it("reports absent suffix and enchant as zero, not nil", function()
		local r = Record.new(858, 1)
		assert.equal(0, Record.suffix(r))
		assert.equal(0, Record.enchant(r))
	end)

	it("survives a nil record", function()
		assert.is_nil(Record.id(nil))
		assert.equal(0, Record.count(nil))
		assert.equal(0, Record.suffix(nil))
		assert.equal(0, Record.enchant(nil))
	end)
end)

describe("Record.key", function()
	before_each(function()
		env.reset()
		env.loadFile("Modules/Inventory/Record.lua")
		Record = TOGBankClassic_Inventory_Record
	end)

	-- The property the whole rework rests on: same item, same key, regardless of how it arrived.
	it("is equal for the same item regardless of count", function()
		assert.equal(Record.key(Record.new(858, 1)), Record.key(Record.new(858, 999)))
	end)

	it("differs for different items", function()
		assert.truthy(Record.key(Record.new(858, 1)) ~= Record.key(Record.new(859, 1)))
	end)

	-- REQ-003: random-suffix siblings share a base id and must not collapse together.
	it("separates suffix variants of one base item", function()
		local tiger  = Record.key(Record.new(10132, 1, 863))
		local monkey = Record.key(Record.new(10132, 1, 865))
		assert.truthy(tiger ~= monkey, "two random-suffix variants produced the same key")
	end)

	it("separates an enchanted item from an unenchanted one", function()
		assert.truthy(Record.key(Record.new(858, 1)) ~= Record.key(Record.new(858, 1, 0, 2504)))
	end)

	it("handles a negative suffix without collision", function()
		assert.truthy(Record.key(Record.new(10132, 1, -25)) ~= Record.key(Record.new(10132, 1, 25)))
	end)

	it("returns nil for a nil record", function()
		assert.is_nil(Record.key(nil))
	end)

	-- keyFor must be byte-identical to key, or a lookup by loose values silently misses a record
	-- that is present.
	it("keyFor matches key for the same values", function()
		assert.equal(Record.key(Record.new(10132, 5, 863, 2504)), Record.keyFor(10132, 863, 2504))
		assert.equal(Record.key(Record.new(858, 5)),              Record.keyFor(858))
	end)

	it("keyFor returns nil without an id", function()
		assert.is_nil(Record.keyFor(nil))
	end)
end)

describe("Record.isValid", function()
	before_each(function()
		env.reset()
		env.loadFile("Modules/Inventory/Record.lua")
		Record = TOGBankClassic_Inventory_Record
	end)

	it("accepts well-formed records", function()
		assert.is_true(Record.isValid({ 858, 20 }))
		assert.is_true(Record.isValid({ 10132, 1, 863 }))
		assert.is_true(Record.isValid({ 10132, 1, 863, 2504 }))
	end)

	it("rejects non-tables", function()
		assert.is_false(Record.isValid(nil))
		assert.is_false(Record.isValid("858:20"))
		assert.is_false(Record.isValid(858))
	end)

	it("rejects a missing or non-numeric id", function()
		assert.is_false(Record.isValid({}))
		assert.is_false(Record.isValid({ "858", 20 }))
	end)

	it("rejects a non-positive count", function()
		assert.is_false(Record.isValid({ 858, 0 }))
		assert.is_false(Record.isValid({ 858, -1 }))
	end)

	-- Fractional ids or counts mean something upstream produced garbage; storing them would put
	-- a row in the DB that can never match a real bag slot.
	it("rejects fractional ids and counts", function()
		assert.is_false(Record.isValid({ 858.5, 20 }))
		assert.is_false(Record.isValid({ 858, 20.5 }))
	end)

	it("rejects an enchant with no suffix placeholder", function()
		local malformed = { 858, 1 }
		malformed[4] = 2504         -- slot 3 left nil: the enchant would read as a suffix
		assert.is_false(Record.isValid(malformed))
	end)
end)

describe("Record.merge", function()
	before_each(function()
		env.reset()
		env.loadFile("Modules/Inventory/Record.lua")
		Record = TOGBankClassic_Inventory_Record
	end)

	it("sums counts for the same item", function()
		assert.same({ 858, 8 }, Record.merge(Record.new(858, 5), Record.new(858, 3)))
	end)

	it("preserves suffix and enchant", function()
		local a = Record.new(10132, 1, 863, 2504)
		local b = Record.new(10132, 2, 863, 2504)
		assert.same({ 10132, 3, 863, 2504 }, Record.merge(a, b))
	end)

	-- Refusing rather than silently combining is the point: merging a Tiger with a Monkey is
	-- exactly the miscount that link-keying produced.
	it("refuses to merge different suffix variants", function()
		assert.is_nil(Record.merge(Record.new(10132, 1, 863), Record.new(10132, 1, 865)))
	end)

	it("refuses to merge different items", function()
		assert.is_nil(Record.merge(Record.new(858, 1), Record.new(859, 1)))
	end)

	it("refuses invalid input", function()
		assert.is_nil(Record.merge(Record.new(858, 1), { 858 }))
		assert.is_nil(Record.merge(nil, Record.new(858, 1)))
	end)
end)

describe("Record.aggregate", function()
	before_each(function()
		env.reset()
		env.loadFile("Modules/Inventory/Record.lua")
		Record = TOGBankClassic_Inventory_Record
	end)

	local function count(map)
		local n = 0
		for _ in pairs(map) do n = n + 1 end
		return n
	end

	it("sums duplicates into one entry", function()
		local map = Record.aggregate({ Record.new(858, 5), Record.new(858, 3), Record.new(858, 2) })
		assert.equal(1, count(map))
		assert.equal(10, Record.count(map[Record.keyFor(858)]))
	end)

	it("keeps distinct items separate", function()
		local map = Record.aggregate({ Record.new(858, 5), Record.new(859, 3) })
		assert.equal(2, count(map))
	end)

	it("keeps suffix variants separate", function()
		local map = Record.aggregate({ Record.new(10132, 1, 863), Record.new(10132, 1, 865) })
		assert.equal(2, count(map), "suffix variants were merged")
	end)

	-- ITEM-005's lesson: one bad row must not discard the batch.
	it("skips invalid entries without dropping valid ones", function()
		local map, skipped = Record.aggregate({
			Record.new(858, 5),
			{ 0, 5 },            -- invalid id
			{ 859 },             -- no count
			Record.new(859, 2),
		})
		assert.equal(2, skipped)
		assert.equal(2, count(map))
		assert.equal(5, Record.count(map[Record.keyFor(858)]))
	end)

	it("handles nil and empty input", function()
		assert.equal(0, count((Record.aggregate(nil))))
		assert.equal(0, count((Record.aggregate({}))))
	end)
end)

describe("Record.totalForItem", function()
	before_each(function()
		env.reset()
		env.loadFile("Modules/Inventory/Record.lua")
		Record = TOGBankClassic_Inventory_Record
	end)

	-- "How many Felcloth are there" ignores variants; "which exact Felcloth" uses the key.
	it("sums every variant of one item id", function()
		local map = Record.aggregate({
			Record.new(10132, 2, 863),
			Record.new(10132, 3, 865),
			Record.new(858, 99),
		})
		assert.equal(5, Record.totalForItem(map, 10132))
	end)

	it("returns zero for an absent item", function()
		assert.equal(0, Record.totalForItem(Record.aggregate({ Record.new(858, 1) }), 99999))
	end)

	it("returns zero for a nil id or map", function()
		assert.equal(0, Record.totalForItem(nil, 858))
		assert.equal(0, Record.totalForItem({}, nil))
	end)
end)
