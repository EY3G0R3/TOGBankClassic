-- Bank.lua — bag/bank scanning and item lookup.
--
-- Scanning is the source of every number the addon shows and syncs, and FindItemsByName is what
-- mail fulfillment uses to decide which slot to pull from. Getting either subtly wrong produces
-- plausible-looking but incorrect counts rather than an error.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function loadBank()
	env.stubOutput()
	-- SPEC-ALONE-001: Bank.lua reads TOGBankClassic_Constants at file scope (it precedes Bank in both
	-- TOCs); run alone this file had none, because an earlier spec file used to leave it behind.
	env.loadFile("Modules/Constants.lua")
	env.loadFile("Modules/Item.lua")
	-- LINK-AUDIT-001 step 4: MatchContainers reads a slot's suffix through Scan.parseLink, the one
	-- link parser (Record precedes Scan in both TOCs). Forward-order alone found this missing.
	env.loadFile("Modules/Inventory/Record.lua")
	env.loadFile("Modules/Inventory/Scan.lua")
	env.loadFile("Modules/Bank.lua")
	return TOGBankClassic_Bank
end

describe("Bank module table", function()
	before_each(function() env.reset() end)

	-- `TOGBankClassic_Bank = { ... }` at file scope captures the chunk's varargs — the addon
	-- name and namespace the client passes in — so the module table is born with array entries.
	it("is an empty table, not one seeded from the chunk varargs", function()
		local Bank = loadBank()
		assert.equal(0, #Bank,
			"the module table has " .. #Bank .. " array entries: `TOGBankClassic_Bank = { ... }` " ..
			"captured the addon varargs instead of creating an empty table (audit BANK-002)")
	end)
end)

describe("Bank:FindItemsByName", function()
	local Bank

	before_each(function()
		env.reset()
		Bank = loadBank()
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.defineItem(859, { name = "Lesser Healing Potion", class = 0 })
	end)

	it("finds every slot holding the named item", function()
		env.setBag(0, 4, { { id = 858, count = 5 }, { id = 859, count = 1 }, { id = 858, count = 3 } })
		local results = Bank:FindItemsByName("Minor Healing Potion")
		assert.equal(2, #results)
		assert.equal(5, results[1].count)
		assert.equal(3, results[2].count)
	end)

	it("matches the name case-insensitively", function()
		env.setBag(0, 2, { { id = 858, count = 5 } })
		assert.equal(1, #Bank:FindItemsByName("minor healing POTION"))
	end)

	it("returns an empty list when nothing matches", function()
		env.setBag(0, 2, { { id = 859, count = 1 } })
		assert.same({}, Bank:FindItemsByName("Minor Healing Potion"))
	end)

	it("returns an empty list for a nil name", function()
		assert.same({}, Bank:FindItemsByName(nil))
	end)

	it("reports the bag and slot of each match", function()
		env.setBag(0, 2, {})
		-- Placed directly rather than via setBag so the item lands in slot 2, not slot 1.
		env.bags[1] = { slots = 3, [2] = { itemID = 858, count = 2, link = env.items[858].link } }
		local results = Bank:FindItemsByName("Minor Healing Potion")
		assert.equal(1, #results)
		assert.equal(1, results[1].bag)
		assert.equal(2, results[1].slot)
	end)

	-- Same-name variants (REQ-001) are told apart by ID, so an ID match must win over the name.
	it("prefers the item ID over the name when both are supplied", function()
		env.defineItem(1000, { name = "Punctured Voodoo Doll", class = 0 })
		env.defineItem(1001, { name = "Punctured Voodoo Doll", class = 0 })
		env.setBag(0, 3, { { id = 1000, count = 1 }, { id = 1001, count = 1 } })
		local results = Bank:FindItemsByName("Punctured Voodoo Doll", 1001)
		assert.equal(1, #results, "the ID filter did not separate the two same-named variants")
		assert.truthy(results[1].link:find("item:1001", 1, true))
	end)

	-- REQ-003: random-suffix siblings share a base ID and differ only in field 7.
	it("distinguishes random-suffix siblings when a suffix is supplied", function()
		local base = "|cffffffff|Hitem:10132:0:0:0:0:0:%d:1:60|h[Spiked Club]|h|r"
		env.defineItem(10132, { name = "Spiked Club", class = 2 })
		env.bags[0] = {
			slots = 3,
			[1] = { itemID = 10132, count = 1, link = base:format(863) },
			[2] = { itemID = 10132, count = 1, link = base:format(865) },
		}
		local results = Bank:FindItemsByName("Spiked Club", 10132, 863)
		assert.equal(1, #results, "the suffix filter did not separate the two variants")
		assert.truthy(results[1].link:find(":863:", 1, true))
	end)

	-- REQ-004. An ID identifies an item on its own; requiring a name too means an ID-only
	-- lookup silently finds nothing, contradicting the ID-primacy rule REQ-001 established.
	it("finds by ID even when no name is supplied", function()
		env.setBag(0, 2, { { id = 858, count = 5 } })
		local results = Bank:FindItemsByName(nil, 858)
		assert.equal(1, #results,
			"an ID-only lookup returned nothing: FindItemsByName bails on an empty name before " ..
			"it ever considers the ID (audit REQ-004)")
	end)
end)

describe("Bank:CountItemInBags", function()
	local Bank

	before_each(function()
		env.reset()
		Bank = loadBank()
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
	end)

	it("sums the counts across every matching slot", function()
		env.setBag(0, 4, { { id = 858, count = 5 }, { id = 858, count = 3 } })
		local total = Bank:CountItemInBags("Minor Healing Potion")
		assert.equal(8, total)
	end)

	it("returns zero when the item is absent", function()
		env.setBag(0, 2, {})
		assert.equal(0, Bank:CountItemInBags("Minor Healing Potion"))
	end)

	it("also returns the matching slot list", function()
		env.setBag(0, 4, { { id = 858, count = 5 } })
		local _, items = Bank:CountItemInBags("Minor Healing Potion")
		assert.equal(1, #items)
	end)
end)

describe("Bank:HasInventorySpace", function()
	local Bank
	before_each(function() env.reset(); Bank = loadBank() end)

	it("is true when a bag has a free slot", function()
		env.setBag(0, 4, { { id = 858, count = 1 } })
		assert.is_true(Bank:HasInventorySpace())
	end)

	it("is false when every bag is full", function()
		env.defineItem(858, {})
		env.setBag(0, 2, { { id = 858, count = 1 }, { id = 858, count = 1 } })
		assert.is_false(Bank:HasInventorySpace())
	end)

	it("is false with no bags at all", function()
		assert.is_false(Bank:HasInventorySpace())
	end)
end)

describe("Bank:Scan gating", function()
	local Bank

	before_each(function()
		env.reset()
		Bank = loadBank()
		env.loadFile("Modules/Constants.lua")
		-- INV2-RETIRE-003: the V2 store is the scan's source of truth, so the scan REQUIRES the
		-- inventory modules -- exactly as the TOC guarantees in production. A spec that ran the scan
		-- without them was exercising a branch the client never takes.
		env.loadModules({
			"Modules/Inventory/Record.lua",
			"Modules/Inventory/Resolve.lua",
			"Modules/Inventory/Store.lua",
			"Modules/Inventory/Scan.lua",
		})
		TOGBankClassic_Inventory_Store:Init({ faction = {} })
		TOGBankClassic_Guild = {
			Info = { name = "Testguild", alts = {} },
			GetNormalizedPlayer = function() return "Bankchar-Testrealm" end,
			NormalizeName = function(_, n) return n and (n:find("-") and n or n .. "-Testrealm") or nil end,
			GetBanks = function() return { "Bankchar-Testrealm" } end,
		}
		TOGBankClassic_Options  = { GetBankEnabled = function() return true end }
		-- INV2-RETIRE-002: no SaveSnapshot here on purpose -- a scan that reaches for it must fail.
		TOGBankClassic_Database = {}
		TOGBankClassic_MailInventory = { hasUpdated = false }
		TOGBankClassic_Core = env.coreHashStub(12345)
		Bank.hasUpdated = true
		Bank.eventsRegistered = false
	end)

	it("does not scan when guild data has not loaded", function()
		TOGBankClassic_Guild.Info = nil
		-- Every field the guild table had, before and after: a scan that rebuilt Info (or wrote
		-- anything else onto the table) adds a key.
		local function fields()
			local t = {}
			for k in pairs(TOGBankClassic_Guild) do t[#t + 1] = tostring(k) end
			table.sort(t)
			return t
		end
		local before = fields()
		Bank:Scan()
		assert.same(before, fields(), "the scan wrote to the guild table without guild data loaded")
	end)

	-- The fixture's alts table starts empty, so "no record was written" is the whole table staying empty.
	it("does not scan when the player is not a banker", function()
		TOGBankClassic_Guild.GetBanks = function() return { "SomeoneElse-Testrealm" } end
		Bank:Scan()
		assert.same({}, TOGBankClassic_Guild.Info.alts, "a non-banker's scan wrote a record")
	end)

	it("does not scan when bank scanning is disabled for this character", function()
		TOGBankClassic_Options.GetBankEnabled = function() return false end
		Bank:Scan()
		assert.same({}, TOGBankClassic_Guild.Info.alts, "a scan with scanning disabled wrote a record")
	end)

	-- INV2-RETIRE-003: the scan writes the V2 store and leaves the record's sub-tables as
	-- METADATA ONLY -- `alt.bags` carries the slot counts and the read stamp, never rows. The rows
	-- are read back from the store's bags bucket.
	it("records the character's bags when every gate passes", function()
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 858, count = 5 } })
		Bank:Scan()
		local alt = TOGBankClassic_Guild.Info.alts["Bankchar-Testrealm"]
		assert.is_not_nil(alt, "the scan produced no alt record")
		assert.is_not_nil(alt.bags, "the bags metadata block was not written")
		assert.is_nil(alt.bags.items, "the scan wrote legacy bag rows onto the record")
		assert.is_nil(alt.items, "the scan wrote the legacy aggregate onto the record")
		local bags = TOGBankClassic_Inventory_Store:GetAltSourceRecords("Testguild", "Bankchar-Testrealm", "bags")
		assert.equal(1, #bags)
		assert.equal(858, TOGBankClassic_Inventory_Record.id(bags[1]))
		assert.equal(5, TOGBankClassic_Inventory_Record.count(bags[1]))
	end)

	it("aggregates the same item across bags into one store record", function()
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 858, count = 5 } })
		env.setBag(1, 4, { { id = 858, count = 2 } })
		Bank:Scan()
		local records = TOGBankClassic_Inventory_Store:GetAltRecords("Testguild", "Bankchar-Testrealm")
		assert.equal(1, #records, "the same item in two bags should aggregate to one row")
		assert.equal(7, TOGBankClassic_Inventory_Record.count(records[1]))
	end)

	it("records the character's money", function()
		env.money = 123456
		Bank:Scan()
		assert.equal(123456, TOGBankClassic_Guild.Info.alts["Bankchar-Testrealm"].money)
	end)

	it("skips the vault when the player is away from a bank", function()
		env.defineItem(858, { class = 0 })
		env.setBag(0, 4, { { id = 858, count = 1 } })
		Bank:Scan()
		local alt = TOGBankClassic_Guild.Info.alts["Bankchar-Testrealm"]
		assert.is_nil(alt.bank, "the vault was scanned despite the bank frame being closed")
	end)
end)
