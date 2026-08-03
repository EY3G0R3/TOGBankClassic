-- Bank.lua — bag/bank scanning and item lookup.
--
-- Scanning is the source of every number the addon shows and syncs, and FindItemsByName is what
-- mail fulfillment uses to decide which slot to pull from. Getting either subtly wrong produces
-- plausible-looking but incorrect counts rather than an error.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function loadBank()
	env.stubOutput()
	env.loadFile("Modules/Item.lua")
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
		env.bags[1] = { size = 3, [2] = { itemID = 858, stackCount = 2, hyperlink = env.items[858].link } }
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
			size = 3,
			[1] = { itemID = 10132, stackCount = 1, hyperlink = base:format(863) },
			[2] = { itemID = 10132, stackCount = 1, hyperlink = base:format(865) },
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
		TOGBankClassic_Guild = {
			Info = { name = "Testguild", alts = {} },
			GetNormalizedPlayer = function() return "Bankchar-Testrealm" end,
			NormalizeName = function(_, n) return n and (n:find("-") and n or n .. "-Testrealm") or nil end,
			GetBanks = function() return { "Bankchar-Testrealm" } end,
		}
		TOGBankClassic_Options  = { GetBankEnabled = function() return true end }
		TOGBankClassic_Database = { SaveSnapshot = function() return true end }
		TOGBankClassic_MailInventory = { hasUpdated = false }
		TOGBankClassic_Core = {
			ComputeInventoryHash = function() return 12345 end,
		}
		Bank.hasUpdated = true
		Bank.eventsRegistered = false
	end)

	it("does not scan when guild data has not loaded", function()
		TOGBankClassic_Guild.Info = nil
		Bank:Scan()
		assert.is_nil(TOGBankClassic_Guild.Info)
	end)

	it("does not scan when the player is not a banker", function()
		TOGBankClassic_Guild.GetBanks = function() return { "SomeoneElse-Testrealm" } end
		Bank:Scan()
		assert.is_nil(TOGBankClassic_Guild.Info.alts["Bankchar-Testrealm"])
	end)

	it("does not scan when bank scanning is disabled for this character", function()
		TOGBankClassic_Options.GetBankEnabled = function() return false end
		Bank:Scan()
		assert.is_nil(TOGBankClassic_Guild.Info.alts["Bankchar-Testrealm"])
	end)

	it("records the character's bags when every gate passes", function()
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 858, count = 5 } })
		Bank:Scan()
		local alt = TOGBankClassic_Guild.Info.alts["Bankchar-Testrealm"]
		assert.is_not_nil(alt, "the scan produced no alt record")
		assert.is_not_nil(alt.bags)
		assert.equal(1, #alt.bags.items)
		assert.equal(5, alt.bags.items[1].Count)
	end)

	it("aggregates bags into alt.items", function()
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 858, count = 5 } })
		env.setBag(1, 4, { { id = 858, count = 2 } })
		Bank:Scan()
		local alt = TOGBankClassic_Guild.Info.alts["Bankchar-Testrealm"]
		assert.equal(1, #alt.items, "the same item in two bags should aggregate to one row")
		assert.equal(7, alt.items[1].Count)
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
