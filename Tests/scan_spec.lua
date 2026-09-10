-- Inventory/Scan — containers to V2 tuples.
--
-- Three properties are load-bearing and each has a spec that would fail loudly if it regressed:
--
--   1. Link parsing treats `::::::` and `:0:0:0:0:0:` as the same thing. That equivalence is
--      what makes the miscount class stop existing rather than being normalised around.
--   2. Under dualWrite both shapes come from ONE container walk. Two walks would make
--      /togbank dev compare meaningless, because divergence could be a moved stack.
--   3. An unreachable bank returns nil, not empty. Treating it as empty would wipe a
--      character's whole vault from the guild's view.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Record, Scan

local function loadScan()
	env.stubOutput()
	env.loadFile("Modules/Switches.lua")
	env.loadFile("Modules/Inventory/Record.lua")
	env.loadFile("Modules/Inventory/Scan.lua")
	Record = TOGBankClassic_Inventory_Record
	Scan   = TOGBankClassic_Inventory_Scan
	TOGBankClassic_Database = { db = { global = {} } }
	return Scan
end

--- Put an item in a bag slot with an explicit link, so link parsing can be driven directly.
local function place(bag, slot, id, count, link)
	env.bags[bag] = env.bags[bag] or { size = 16, bagType = 0 }
	env.bags[bag][slot] = { itemID = id, stackCount = count, hyperlink = link }
end

describe("Scan.parseLink", function()
	before_each(function() env.reset(); loadScan() end)

	it("returns zeros for a plain link", function()
		local enchant, suffix = Scan.parseLink("|cffffffff|Hitem:858|h[Potion]|h|r")
		assert.equal(0, enchant)
		assert.equal(0, suffix)
	end)

	it("reads the suffix from field 7", function()
		local _, suffix = Scan.parseLink("|cff1eff00|Hitem:10132:0:0:0:0:0:863:1:60|h[X]|h|r")
		assert.equal(863, suffix)
	end)

	it("reads the enchant from field 2", function()
		local enchant = Scan.parseLink("|cff1eff00|Hitem:10132:2504:0:0:0:0:863:1:60|h[X]|h|r")
		assert.equal(2504, enchant)
	end)

	-- THE property. A client link writes explicit zeros; a rebuilt link writes empty fields.
	-- Both mean the same item, and parsing to integers is what makes that true by construction.
	it("treats empty fields and explicit zeros identically", function()
		local e1, s1 = Scan.parseLink("|cff1eff00|Hitem:10132:0:0:0:0:0:863:1:60|h[X]|h|r")
		local e2, s2 = Scan.parseLink("|cff1eff00|Hitem:10132::::::863|h[X]|h|r")
		assert.equal(e1, e2)
		assert.equal(s1, s2)
		assert.equal(863, s2)
	end)

	it("preserves a negative suffix", function()
		local _, suffix = Scan.parseLink("|cff1eff00|Hitem:10132:0:0:0:0:0:-25:1:60|h[X]|h|r")
		assert.equal(-25, suffix)
	end)

	it("accepts a bare item string", function()
		local _, suffix = Scan.parseLink("item:10132::::::863")
		assert.equal(863, suffix)
	end)

	it("returns zeros for nil or unparseable input", function()
		assert.equal(0, (Scan.parseLink(nil)))
		assert.equal(0, (Scan.parseLink("not a link")))
		assert.equal(0, (Scan.parseLink(12345)))
	end)
end)

describe("Scan:ScanBags", function()
	before_each(function() env.reset(); loadScan() end)

	it("returns a record per occupied slot", function()
		place(0, 1, 858, 20, "|cffffffff|Hitem:858|h[Potion]|h|r")
		place(0, 2, 859, 5,  "|cffffffff|Hitem:859|h[Other]|h|r")
		local records, _, used = Scan:ScanBags()
		assert.equal(2, #records)
		assert.equal(2, used)
	end)

	it("carries suffix and enchant through to the record", function()
		place(0, 1, 10132, 1, "|cff1eff00|Hitem:10132:2504:0:0:0:0:863:1:60|h[X]|h|r")
		local records = Scan:ScanBags()
		assert.equal(863, Record.suffix(records[1]))
		assert.equal(2504, Record.enchant(records[1]))
	end)

	it("reports slot totals across all carried bags", function()
		env.bags[0] = { size = 16, bagType = 0 }
		env.bags[1] = { size = 10, bagType = 0 }
		local _, _, used, total = Scan:ScanBags()
		assert.equal(0, used)
		assert.equal(26, total)
	end)

	it("returns nothing for empty bags", function()
		assert.same({}, (Scan:ScanBags()))
	end)

	it("omits the legacy shape unless asked", function()
		place(0, 1, 858, 20, "|cffffffff|Hitem:858|h[Potion]|h|r")
		local _, legacy = Scan:ScanBags()
		assert.is_nil(legacy)
	end)
end)

describe("Scan:ScanBank", function()
	before_each(function() env.reset(); loadScan() end)

	--- The vault reports a non-nil bagType only when the player is at a banker.
	local function openBank()
		env.bags[-1] = { size = 28, bagType = 0 }
	end

	it("returns nil when the player is not at a banker", function()
		local records = Scan:ScanBank()
		assert.is_nil(records)
	end)

	-- The distinction that matters: nil means "unknown", not "empty". Storing an empty scan
	-- would erase a character's entire vault from every other member's view.
	it("distinguishes an unreachable bank from an empty one", function()
		openBank()
		local records = Scan:ScanBank()
		assert.is_table(records, "an open but empty bank must return a table, not nil")
		assert.equal(0, #records)
	end)

	it("scans the vault and its bag slots together", function()
		openBank()
		place(-1, 1, 858, 10, "|cffffffff|Hitem:858|h[Potion]|h|r")
		env.bags[5] = { size = 16, bagType = 0 }
		place(5, 1, 859, 3, "|cffffffff|Hitem:859|h[Other]|h|r")
		local records, _, used = Scan:ScanBank()
		assert.equal(2, #records)
		assert.equal(2, used)
	end)
end)

describe("Scan:ScanAll", function()
	before_each(function() env.reset(); loadScan() end)

	it("combines bags and bank", function()
		env.bags[-1] = { size = 28, bagType = 0 }
		place(0, 1, 858, 20, "|cffffffff|Hitem:858|h[Potion]|h|r")
		place(-1, 1, 859, 5, "|cffffffff|Hitem:859|h[Other]|h|r")
		local result = Scan:ScanAll()
		assert.equal(2, #result.records)
		assert.is_true(result.bankScanned)
	end)

	it("flags bankScanned false when away from a banker", function()
		place(0, 1, 858, 20, "|cffffffff|Hitem:858|h[Potion]|h|r")
		local result = Scan:ScanAll()
		assert.equal(1, #result.records)
		assert.is_false(result.bankScanned,
			"a caller must be able to preserve stored vault contents rather than replacing them")
	end)

	it("records money", function()
		env.money = 987654
		assert.equal(987654, Scan:ScanAll().money)
	end)

	-- dualWrite is turned off explicitly. It is inert while inventoryV2 is off, and INV2 step 9 made
	-- inventoryV2 default ON -- so this example was previously passing because of the PARENT's
	-- default rather than because of anything it set.
	it("omits the legacy shape while dualWrite is off", function()
		TOGBankClassic_Switches:Set("dualWrite", false)
		place(0, 1, 858, 20, "|cffffffff|Hitem:858|h[Potion]|h|r")
		assert.is_nil(Scan:ScanAll().legacy)
	end)

	describe("with dualWrite on", function()
		before_each(function()
			TOGBankClassic_Switches:Set("inventoryV2", true)   -- dualWrite is inert without it
		end)

		it("emits both shapes", function()
			place(0, 1, 858, 20, "|cffffffff|Hitem:858|h[Potion]|h|r")
			local result = Scan:ScanAll()
			assert.equal(1, #result.records)
			assert.is_table(result.legacy)
			assert.equal(1, #result.legacy)
		end)

		-- One walk, two writes. If these disagreed, /togbank dev compare could not tell an
		-- encoding bug from a stack that moved between two separate passes.
		it("produces both shapes from the same items", function()
			env.bags[-1] = { size = 28, bagType = 0 }
			place(0, 1, 858, 20, "|cffffffff|Hitem:858|h[Potion]|h|r")
			place(0, 2, 10132, 1, "|cff1eff00|Hitem:10132:0:0:0:0:0:863:1:60|h[X]|h|r")
			place(-1, 1, 859, 5, "|cffffffff|Hitem:859|h[Other]|h|r")

			local result = Scan:ScanAll()
			assert.equal(#result.records, #result.legacy,
				"the two shapes disagree on how many items were seen")

			local tupleIDs, legacyIDs = {}, {}
			for _, rec in ipairs(result.records) do tupleIDs[Record.id(rec)] = true end
			for _, item in ipairs(result.legacy) do legacyIDs[item.ID] = true end
			assert.same(tupleIDs, legacyIDs, "the two shapes disagree on WHICH items were seen")
		end)

		it("keeps the original link in the legacy shape", function()
			local link = "|cff1eff00|Hitem:10132:0:0:0:0:0:863:1:60|h[X]|h|r"
			place(0, 1, 10132, 1, link)
			assert.equal(link, Scan:ScanAll().legacy[1].Link,
				"the legacy shape must carry the client's own link verbatim, not a rebuild")
		end)
	end)
end)
