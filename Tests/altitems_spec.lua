-- INV2 step 7a — Guild:GetAltItems and Guild:GetAltItemTotal, the single place the UI's item rows
-- and per-item totals come from.
--
-- WHY ONE ACCESSOR RATHER THAN A CONDITIONAL PER CALLER:
--
-- Six sites across three UI files open-coded "use alt.items if it has anything, else aggregate
-- bank + bags + mail". Six copies is six places to drift -- and they HAD drifted: Search's copy
-- aggregated bank + bags and omitted MAIL, while Inventory's included it, so an item in a banker's
-- mailbox was visible in the inventory tab and invisible to search, from the same data.
-- INVENTORY_V2.md 7.1 specifies the V2 store exposes a view in the same shape the UI already
-- consumes, which is what makes one accessor possible.
--
-- INV2-RETIRE-003 (2026-09-11): THE ACCESSORS READ THE V2 STORE AND NOTHING ELSE. This file used to
-- pin an `inventoryV2` switch (off = legacy rows, on = store) and two legacy fallbacks behind the
-- store -- "alt absent from V2" (the dual-write window) and INV2-STALE-001 (a schema-1 record, bags +
-- bank and no mail, lost to a legacy record that had all three). The legacy rows are no longer
-- written by the scan and are stripped on load, so every one of those branches is deleted.
-- writ-cannot: the examples "returns the aggregate rows", "rebuilds from bank, bags AND mail when
-- there is no aggregate", "falls back to the legacy record for an alt the V2 store has never seen",
-- "agrees on the legacy aggregate branch", "agrees on the pre-SYNC-006 three-source branch",
-- "agrees when an unstamped V2 record sends it to the legacy fallback", "prefers the complete
-- legacy record over the short V2 one", "stops preferring legacy as soon as that character
-- rescans" and "still prefers a STAMPED V2 record that holds less than the legacy one" drove the
-- deleted legacy branches with `G.Info.alts[name] = { items = ... }`; the feature they covered --
-- reading legacy rows -- was removed on purpose (docs/DELTA_RELEASE.md section 4). What is pinned
-- now is the property that survives: the record on `Info.alts` -- whatever it carries -- is NEVER
-- consulted for rows, and the two accessors agree on every input.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local GUILD = "Testguild"

local function load()
	env.stubOutput()
	env.loadModules({
		"Modules/Constants.lua",
		"Modules/Switches.lua",
		"Modules/Item.lua",
		"Modules/Inventory/Record.lua",
		"Modules/Inventory/Resolve.lua",
		"Modules/Inventory/Store.lua",
		"Modules/Guild.lua",
	})
	TOGBankClassic_Database = { db = { global = {} } }
	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	TOGBankClassic_Guild.Info = { name = GUILD, alts = {} }
	return TOGBankClassic_Guild
end

--- A legacy-shaped record on Info.alts: rows that a pre-retirement SavedVariables file could still
--- carry until Database:Load strips them. The accessors must read NONE of it.
local function legacyAlt(items)
	return { items = items, bank = { items = items }, bags = { items = items }, mail = { items = items } }
end

describe("Guild:GetAltItems", function()
	local G
	before_each(function() env.reset(); G = load() end)

	it("reads the V2 store", function()
		env.defineItem(101, { name = "Tuple Item" })
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 7 } })
		local items = G:GetAltItems("Bob")
		assert.equal(1, #items)
		assert.equal(101, items[1].ID)
		assert.equal(7, items[1].Count)
	end)

	it("never reads rows off the Info.alts record, whatever it carries", function()
		env.defineItem(101, { name = "Tuple Item" })
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 7 } })
		G.Info.alts["Bob"] = legacyAlt({ { ID = 999, Count = 1 } })
		local items = G:GetAltItems("Bob")
		assert.equal(1, #items)
		assert.equal(101, items[1].ID, "the legacy record was returned instead of the store")
	end)

	-- INV2-RETIRE-003: the dual-write fallback is gone. An alt the store has never seen is EMPTY,
	-- not "whatever the legacy record holds" -- the legacy record holds nothing after the strip.
	it("returns an empty table for an alt the store has never seen, even if the record carries legacy rows", function()
		G.Info.alts["Carol"] = legacyAlt({ { ID = 42, Count = 3 } })
		assert.same({}, G:GetAltItems("Carol"),
			"an alt absent from the V2 store answered from the legacy record -- that fallback " ..
			"was deleted with the rows it read (INV2-RETIRE-003)")
	end)

	-- Always an array, never nil: every caller iterates the result directly.
	it("returns an empty table for an unknown alt", function()
		assert.same({}, G:GetAltItems("Nobody"))
	end)

	it("returns an empty table when there is no guild info at all", function()
		G.Info = nil
		assert.same({}, G:GetAltItems("Bob"))
	end)

	it("returns an empty table when the guild has no name to key the store by", function()
		G.Info = { alts = {} }
		assert.same({}, G:GetAltItems("Bob"))
	end)

	-- INV2-STALE-001 is retired WITH the legacy fallback it chose. A schema-1 record (scanned before
	-- INV2-MAIL-001: bags + bank, no mail) used to lose to the legacy record that had all three
	-- sources; with no legacy record the choice is a short total or an empty one, and short wins --
	-- it heals on that banker's next mailbox visit, an empty tab does not.
	it("answers from a schema-1 (pre-INV2-MAIL-001) record rather than returning nothing", function()
		env.defineItem(101, { name = "Tuple Item" })
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 68 } })
		TOGBankClassic_Inventory_Store.db.faction[GUILD].alts["Bob"].schema = nil
		TOGBankClassic_Inventory_Store:InvalidateView(GUILD, "Bob")
		assert.is_false(TOGBankClassic_Inventory_Store:IsAltComplete(GUILD, "Bob"), "precondition")
		G.Info.alts["Bob"] = legacyAlt({ { ID = 101, Count = 71 } })

		local items = G:GetAltItems("Bob")
		assert.equal(1, #items)
		assert.equal(68, items[1].Count,
			"expected the short V2 record (68), got the legacy one (71) or nothing -- the " ..
			"IsAltComplete gate and the legacy fallback were both retired (INV2-RETIRE-003)")
	end)

	-- A rescan writes through SetAltRecords, which stamps the current schema and replaces the rows.
	-- Still worth pinning without the gate: the short record heals by the ordinary write, with no
	-- migration pass and nothing to remember to run.
	it("shows the full total as soon as that character rescans", function()
		env.defineItem(101, { name = "Tuple Item" })
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 68 } })
		TOGBankClassic_Inventory_Store.db.faction[GUILD].alts["Bob"].schema = nil
		TOGBankClassic_Inventory_Store:InvalidateView(GUILD, "Bob")
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 71 } })
		assert.is_true(TOGBankClassic_Inventory_Store:IsAltComplete(GUILD, "Bob"))
		assert.equal(71, G:GetAltItems("Bob")[1].Count)
	end)
end)

-- SELF-AUDIT FINDING 3. `Guild:GetAltItemTotal` exists because `TooltipBankerInfo` runs on
-- GameTooltip's OnTooltipSetItem and only ever wants ONE item's total, while GetAltItems
-- materialises the whole resolved view.
--
-- THE PROPERTY THAT MATTERS IS EQUIVALENCE. A faster accessor that disagrees with the slow one is
-- the two-sources-for-one-number divergence INV2 step 7a existed to remove, so these assert the two
-- agree rather than asserting the number directly -- a fixture that drifted would otherwise be
-- checked against itself.
describe("Guild:GetAltItemTotal agrees with GetAltItems on every input", function()
	local G

	--- Sum what GetAltItems reports for one item, which is what the tooltip used to do inline.
	local function viaList(g, altName, itemID)
		local total = 0
		for _, item in ipairs(g:GetAltItems(altName)) do
			if item.ID == itemID then total = total + (item.Count or 1) end
		end
		return total
	end

	local function bothAgree(altName, itemID)
		assert.equal(viaList(G, altName, itemID), G:GetAltItemTotal(altName, itemID),
			string.format("GetAltItemTotal disagrees with GetAltItems for %s / item %d -- two " ..
				"sources for one number is the divergence 7a removed", altName, itemID))
	end

	before_each(function()
		env.reset()
		G = load()
		env.defineItem(101, { name = "Tuple Item" })
		env.defineItem(102, { name = "Other Item" })
	end)

	it("agrees on a stored alt, and sums duplicate rows for one item", function()
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 2 }, { 102, 1 }, { 101, 3 } })
		bothAgree("Bob", 101)
		assert.equal(5, G:GetAltItemTotal("Bob", 101), "duplicate rows for one item must sum")
		bothAgree("Bob", 102)
		bothAgree("Bob", 999)
	end)

	it("agrees across the per-source buckets a local scan writes", function()
		TOGBankClassic_Inventory_Store:SetAltSources(GUILD, "Bob", {
			bank = { { 101, 1 } }, bags = { { 101, 4 } }, mail = { { 102, 2 } },
		}, 0)
		bothAgree("Bob", 101)
		assert.equal(5, G:GetAltItemTotal("Bob", 101), "the three sources must be summed")
		bothAgree("Bob", 102)
	end)

	it("never reads the Info.alts record", function()
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 7 } })
		G.Info.alts["Bob"] = legacyAlt({ { ID = 999, Count = 1 }, { ID = 101, Count = 500 } })
		bothAgree("Bob", 101)
		assert.equal(7, G:GetAltItemTotal("Bob", 101))
		bothAgree("Bob", 999)
		assert.equal(0, G:GetAltItemTotal("Bob", 999),
			"the legacy record was read while the V2 store is the only source")
	end)

	it("agrees on a schema-1 record, answering short rather than empty", function()
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 68 } })
		TOGBankClassic_Inventory_Store.db.faction[GUILD].alts["Bob"].schema = nil
		TOGBankClassic_Inventory_Store:InvalidateView(GUILD, "Bob")
		G.Info.alts["Bob"] = legacyAlt({ { ID = 101, Count = 71 } })
		bothAgree("Bob", 101)
		assert.equal(68, G:GetAltItemTotal("Bob", 101))
	end)

	it("returns zero for an unknown alt, a nil item, or no guild", function()
		assert.equal(0, G:GetAltItemTotal("Nobody", 101))
		assert.equal(0, G:GetAltItemTotal("Bob", nil))
		G.Info = nil
		assert.equal(0, G:GetAltItemTotal("Bob", 101))
	end)

	-- The whole point: it must not reach the list-materialising accessor. Stubbing GetAltItems to
	-- raise is the only way to assert that from outside -- counting allocations is not available,
	-- and asserting the number alone would pass just as happily if it delegated.
	it("does not route through GetAltItems", function()
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 2 } })
		local real = G.GetAltItems
		G.GetAltItems = function() error("GetAltItemTotal delegated to GetAltItems", 2) end
		local ok, err = pcall(function() return G:GetAltItemTotal("Bob", 101) end)
		G.GetAltItems = real
		assert.is_true(ok, "GetAltItemTotal still materialises the full item list: " .. tostring(err))
	end)

	-- Nor through the resolved view: a total is a walk over the record cache, which the write itself
	-- populates, where the view is resolved (names, links, icons) on first read -- work a hover
	-- should not be paying for.
	it("does not materialise the resolved view", function()
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 2 } })
		local before = TOGBankClassic_Inventory_Store:CachedViewCount()
		assert.equal(2, G:GetAltItemTotal("Bob", 101))
		assert.equal(before, TOGBankClassic_Inventory_Store:CachedViewCount(),
			"GetAltItemTotal resolved a view to read one count out of it")
	end)
end)

-- INV2-STALE-001's store half survives: `IsAltComplete` still tells a schema-1 record from a
-- complete one, because the delta release's strip and the log both need to know a record's
-- coverage. Only the accessor's USE of it -- choosing legacy over short -- is gone.
describe("Store:IsAltComplete on a pre-INV2-MAIL-001 V2 record", function()
	before_each(function()
		env.reset()
		load()
		env.defineItem(101, { name = "Tuple Item" })
	end)

	--- Exactly what a scan before INV2-MAIL-001 left behind: records and money, no `schema`.
	local function preFixRecord(altName, records)
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, altName, records)
		local alt = TOGBankClassic_Inventory_Store.db.faction[GUILD].alts[altName]
		alt.schema = nil
		TOGBankClassic_Inventory_Store:InvalidateView(GUILD, altName)
		return alt
	end

	it("treats an unstamped record as incomplete rather than as unknown", function()
		preFixRecord("Bob", { { 101, 68 } })
		assert.is_false(TOGBankClassic_Inventory_Store:IsAltComplete(GUILD, "Bob"))
		assert.is_true(TOGBankClassic_Inventory_Store:HasAlt(GUILD, "Bob"),
			"HasAlt must still be true -- the record exists, it is its COVERAGE that is short")
	end)

	it("is stamped complete by the next write", function()
		preFixRecord("Bob", { { 101, 68 } })
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 71 } })
		assert.is_true(TOGBankClassic_Inventory_Store:IsAltComplete(GUILD, "Bob"))
	end)
end)
