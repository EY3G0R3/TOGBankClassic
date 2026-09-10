-- INV2 step 7a — Guild:GetAltItems, the single place the inventoryV2 switch decides where the
-- UI's item rows come from.
--
-- WHY ONE ACCESSOR RATHER THAN A CONDITIONAL PER CALLER:
--
-- Six sites across three UI files open-coded "use alt.items if it has anything, else aggregate
-- bank + bags + mail". Six copies is six places to repeat the switch and six places to drift --
-- and they HAD drifted: Search's copy aggregated bank + bags and omitted MAIL, while Inventory's
-- included it, so an item in a banker's mailbox was visible in the inventory tab and invisible to
-- search, from the same data. INVENTORY_V2.md 7.1 specifies the V2 store exposes a view in the
-- same shape the UI already consumes, which is what makes one accessor possible.
--
-- The fallback in the middle is the part worth reading: with inventoryV2 on but an alt absent
-- from the V2 store, this returns the LEGACY rows rather than nothing. During dualWrite only the
-- local character is written to V2 -- everyone else's data still arrives over the legacy wire --
-- so returning empty would blank most of the guild's inventory the moment the switch flipped.
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

--- A legacy alt record in the post-SYNC-006 aggregate shape.
local function legacyAlt(items)
	return { items = items }
end

describe("Guild:GetAltItems with inventoryV2 OFF", function()
	local G
	before_each(function() env.reset(); G = load() end)

	it("returns the aggregate rows", function()
		G.Info.alts["Bob"] = legacyAlt({ { ID = 1, Count = 2 }, { ID = 5, Count = 1 } })
		local items = G:GetAltItems("Bob")
		assert.equal(2, #items)
	end)

	-- Always an array, never nil: every caller iterates the result directly.
	it("returns an empty table for an unknown alt", function()
		assert.same({}, G:GetAltItems("Nobody"))
	end)

	it("returns an empty table when there is no guild info at all", function()
		G.Info = nil
		assert.same({}, G:GetAltItems("Bob"))
	end)

	-- Pre-SYNC-006 records have no aggregate. This is the branch that used to be copied per file.
	it("rebuilds from bank, bags AND mail when there is no aggregate", function()
		G.Info.alts["Old"] = {
			bank = { items = { { ID = 1, Count = 1 } } },
			bags = { items = { { ID = 2, Count = 1 } } },
			mail = { items = { { ID = 3, Count = 1 } } },
		}
		local seen = {}
		for _, row in ipairs(G:GetAltItems("Old")) do seen[row.ID] = true end
		assert.is_true(seen[1], "bank items missing")
		assert.is_true(seen[2], "bag items missing")
		assert.is_true(seen[3],
			"mail items missing -- Search's old copy of this branch omitted mail, so an item in " ..
			"a banker's mailbox was searchable in one view and not the other")
	end)
end)

describe("Guild:GetAltItems with inventoryV2 ON", function()
	local G
	before_each(function()
		env.reset()
		G = load()
		TOGBankClassic_Switches:Set("inventoryV2", true)
	end)

	it("reads the V2 store rather than the legacy record", function()
		env.defineItem(101, { name = "Tuple Item" })
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 7 } })
		G.Info.alts["Bob"] = legacyAlt({ { ID = 999, Count = 1 } })

		local items = G:GetAltItems("Bob")
		assert.equal(1, #items)
		assert.equal(101, items[1].ID,
			"the legacy record was returned while inventoryV2 was on, so the switch does nothing")
		assert.equal(7, items[1].Count)
	end)

	-- The dualWrite-window guarantee. Without it, flipping the switch blanks the guild.
	it("falls back to the legacy record for an alt the V2 store has never seen", function()
		G.Info.alts["Carol"] = legacyAlt({ { ID = 42, Count = 3 } })
		local items = G:GetAltItems("Carol")
		assert.equal(1, #items)
		assert.equal(42, items[1].ID,
			"an alt absent from V2 returned nothing. During dualWrite only this character is in " ..
			"the V2 store, so every OTHER guild member's inventory would vanish on switch-on")
	end)

	it("returns an empty table when neither store has the alt", function()
		assert.same({}, G:GetAltItems("Nobody"))
	end)
end)

-- SELF-AUDIT FINDING 3. `Guild:GetAltItemTotal` exists because `TooltipBankerInfo` runs on
-- GameTooltip's OnTooltipSetItem and only ever wants ONE item's total, while GetAltItems' legacy
-- branch builds a fresh array of EVERY item per call -- an allocation per banker per hover, in the
-- file whose own header says it keeps a reusable table to avoid exactly that. INV2-STALE-001 then
-- routes MORE reads through that branch by design.
--
-- THE PROPERTY THAT MATTERS IS EQUIVALENCE, on every branch. A faster accessor that disagrees with
-- the slow one is the two-sources-for-one-number divergence INV2 step 7a existed to remove, so
-- these assert the two agree rather than asserting the number directly -- a fixture that drifted
-- would otherwise be checked against itself.
describe("Guild:GetAltItemTotal agrees with GetAltItems on every branch", function()
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

	before_each(function() env.reset(); G = load() end)

	it("agrees on the legacy aggregate branch", function()
		G.Info.alts["Bob"] = legacyAlt({ { ID = 1, Count = 2 }, { ID = 5, Count = 1 },
			{ ID = 1, Count = 3 } })
		bothAgree("Bob", 1)
		assert.equal(5, G:GetAltItemTotal("Bob", 1), "duplicate rows for one item must sum")
		bothAgree("Bob", 5)
		bothAgree("Bob", 999)
	end)

	it("agrees on the pre-SYNC-006 three-source branch", function()
		G.Info.alts["Old"] = {
			bank = { items = { { ID = 1, Count = 1 } } },
			bags = { items = { { ID = 1, Count = 4 } } },
			mail = { items = { { ID = 3, Count = 2 } } },
		}
		bothAgree("Old", 1)
		assert.equal(5, G:GetAltItemTotal("Old", 1),
			"the three sources must be summed, exactly as the aggregate branch does")
		bothAgree("Old", 3)
	end)

	it("agrees on the V2 branch", function()
		TOGBankClassic_Switches:Set("inventoryV2", true)
		env.defineItem(101, { name = "Tuple Item" })
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 7 } })
		G.Info.alts["Bob"] = legacyAlt({ { ID = 999, Count = 1 } })
		bothAgree("Bob", 101)
		assert.equal(7, G:GetAltItemTotal("Bob", 101))
		bothAgree("Bob", 999)
		assert.equal(0, G:GetAltItemTotal("Bob", 999),
			"the legacy record was read while the V2 store was authoritative")
	end)

	it("agrees when an unstamped V2 record sends it to the legacy fallback", function()
		TOGBankClassic_Switches:Set("inventoryV2", true)
		env.defineItem(101, { name = "Tuple Item" })
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 68 } })
		TOGBankClassic_Inventory_Store.db.faction[GUILD].alts["Bob"].schema = nil
		TOGBankClassic_Inventory_Store:InvalidateView(GUILD, "Bob")
		G.Info.alts["Bob"] = legacyAlt({ { ID = 101, Count = 71 } })
		bothAgree("Bob", 101)
		assert.equal(71, G:GetAltItemTotal("Bob", 101),
			"the short unstamped V2 record was preferred, so the two accessors would disagree " ..
			"exactly where INV2-STALE-001 says the number is wrong")
	end)

	it("returns zero for an unknown alt or a nil item", function()
		assert.equal(0, G:GetAltItemTotal("Nobody", 1))
		assert.equal(0, G:GetAltItemTotal("Bob", nil))
	end)

	-- The whole point: it must not reach the list-materialising accessor. Stubbing GetAltItems to
	-- raise is the only way to assert that from outside -- counting allocations is not available,
	-- and asserting the number alone would pass just as happily if it delegated.
	it("does not route through GetAltItems", function()
		G.Info.alts["Bob"] = legacyAlt({ { ID = 1, Count = 2 } })
		local real = G.GetAltItems
		G.GetAltItems = function() error("GetAltItemTotal delegated to GetAltItems", 2) end
		local ok, err = pcall(function() return G:GetAltItemTotal("Bob", 1) end)
		G.GetAltItems = real
		assert.is_true(ok, "GetAltItemTotal still materialises the full item list: " .. tostring(err))
	end)
end)

-- INV2-STALE-001. The gate above used to be `#view > 0`, which cannot distinguish "V2 is complete"
-- from "V2 has some rows" -- so a record written before INV2-MAIL-001 (bags + bank, no mail) was
-- preferred over a legacy record that had all three, and the operator saw 68 where their own saved
-- data said 71. It could not self-heal: nothing rescans another character's bank on your behalf.
--
-- These drive the STORED SHAPE rather than a flag, because that is what is actually on disk in every
-- installation that ran the switch before the fix: a record with no `schema` key at all.
describe("Guild:GetAltItems with a pre-INV2-MAIL-001 V2 record", function()
	local G
	before_each(function()
		env.reset()
		G = load()
		TOGBankClassic_Switches:Set("inventoryV2", true)
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

	it("prefers the complete legacy record over the short V2 one", function()
		preFixRecord("Bob", { { 101, 68 } })
		G.Info.alts["Bob"] = legacyAlt({ { ID = 101, Count = 71 } })

		local items = G:GetAltItems("Bob")
		assert.equal(1, #items)
		assert.equal(71, items[1].Count,
			"the mail-less V2 record was preferred over a legacy record that had all three " ..
			"sources, so every banker scanned before INV2-MAIL-001 under-reports until it rescans")
	end)

	it("stops preferring legacy as soon as that character rescans", function()
		preFixRecord("Bob", { { 101, 68 } })
		G.Info.alts["Bob"] = legacyAlt({ { ID = 101, Count = 71 } })

		-- A rescan writes through SetAltRecords, which stamps the current schema. This is the whole
		-- self-clearing property: no migration pass, and nothing to remember to run.
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 71 } })

		assert.is_true(TOGBankClassic_Inventory_Store:IsAltComplete(GUILD, "Bob"))
		local items = G:GetAltItems("Bob")
		assert.equal(71, items[1].Count)
	end)

	-- The fallback must not become "legacy wins whenever it is bigger". A complete V2 record is
	-- authoritative even when it disagrees, or the switch stops meaning anything.
	it("still prefers a STAMPED V2 record that holds less than the legacy one", function()
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, "Bob", { { 101, 5 } })
		G.Info.alts["Bob"] = legacyAlt({ { ID = 101, Count = 900 } })

		local items = G:GetAltItems("Bob")
		assert.equal(5, items[1].Count,
			"a complete V2 record lost to a larger legacy one -- that is the total-comparison " ..
			"remedy this fix deliberately did not implement, and it would mask a lagging V2")
	end)
end)
