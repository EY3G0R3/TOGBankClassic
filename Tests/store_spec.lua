-- Inventory/Store — the V2 tuple store and its UI-compatibility view.
--
-- Two properties carry the design and both are asserted here rather than assumed:
--
--   1. Aggregation happens on WRITE, so what lands in the DB is already one row per distinct
--      item. A caller cannot reintroduce the miscount by forgetting to deduplicate.
--   2. The view cache is dropped on every write. A stale view showing pre-change counts would
--      be indistinguishable from the sync bug this rework exists to remove.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Record, Store

local function stubItemDB(items)
	LibStub.libs["LibItemDB-1.0"] = {
		HasItem = function(_, id) return items[id] ~= nil end,
		GetInfo = function(_, id)
			local d = items[id]
			if not d then return nil end
			return d.name, d.quality, d.class, d.subClass, d.equipLoc, d.itemLevel
		end,
		GetSuffixLink = function(_, id) return "|cffffffff|Hitem:" .. id .. "|h[" .. items[id].name .. "]|h|r" end,
		GetRequiredLevel = function(_, id) return items[id] and items[id].reqLevel or 0 end,
	}
	LibStub.minors["LibItemDB-1.0"] = 15
end

local function loadStore()
	env.stubOutput()
	env.loadFile("Modules/Inventory/Record.lua")
	env.loadFile("Modules/Inventory/Resolve.lua")
	env.loadFile("Modules/Inventory/Store.lua")
	Record = TOGBankClassic_Inventory_Record
	Store  = TOGBankClassic_Inventory_Store
	TOGBankClassicInvDB = nil          -- fresh SavedVariable per test
	Store.db = nil
	Store:Init()
	Store:InvalidateView()
	return Store
end

describe("Store persistence", function()
	before_each(function()
		env.reset()
		stubItemDB({ [858] = { name = "Minor Healing Potion", quality = 1, class = 0,
		                       subClass = 0, equipLoc = "", itemLevel = 5, reqLevel = 0 } })
		loadStore()
	end)

	it("uses its own SavedVariable, separate from the legacy DB", function()
		Store:SetAltRecords("Testguild", "Bob-Testrealm", { Record.new(858, 5) })
		assert.is_table(TOGBankClassicInvDB.faction["Testguild"])
		-- The legacy table must be untouched: no data is ever translated between formats.
		assert.is_nil(TOGBankClassicDB)
	end)

	it("stores and returns an alt's records", function()
		Store:SetAltRecords("Testguild", "Bob-Testrealm", { Record.new(858, 5) })
		local recs = Store:GetAltRecords("Testguild", "Bob-Testrealm")
		assert.equal(1, #recs)
		assert.equal(5, Record.count(recs[1]))
	end)

	it("returns an empty table for an unknown guild or alt", function()
		assert.same({}, Store:GetAltRecords("Nope", "Nobody"))
		assert.same({}, Store:GetAltRecords(nil, nil))
	end)

	it("records money and the update time", function()
		env.advance(500)
		Store:SetAltRecords("Testguild", "Bob-Testrealm", {}, 12345)
		assert.equal(12345, Store:GetAltMoney("Testguild", "Bob-Testrealm"))
		assert.equal(500, TOGBankClassicInvDB.faction["Testguild"].alts["Bob-Testrealm"].updated)
	end)

	it("keeps existing money when a later write omits it", function()
		Store:SetAltRecords("Testguild", "Bob-Testrealm", {}, 999)
		Store:SetAltRecords("Testguild", "Bob-Testrealm", {})
		assert.equal(999, Store:GetAltMoney("Testguild", "Bob-Testrealm"))
	end)

	it("replaces rather than merges on a rescan", function()
		Store:SetAltRecords("Testguild", "Bob-Testrealm", { Record.new(858, 5) })
		Store:SetAltRecords("Testguild", "Bob-Testrealm", { Record.new(858, 2) })
		assert.equal(2, Record.count(Store:GetAltRecords("Testguild", "Bob-Testrealm")[1]))
	end)

	it("lists and removes alts", function()
		Store:SetAltRecords("Testguild", "Bob-Testrealm", {})
		Store:SetAltRecords("Testguild", "Ann-Testrealm", {})
		assert.same({ "Ann-Testrealm", "Bob-Testrealm" }, Store:GetAltNames("Testguild"))
		assert.is_true(Store:HasAlt("Testguild", "Bob-Testrealm"))
		assert.is_true(Store:RemoveAlt("Testguild", "Bob-Testrealm"))
		assert.is_false(Store:HasAlt("Testguild", "Bob-Testrealm"))
		assert.is_false(Store:RemoveAlt("Testguild", "Bob-Testrealm"))
	end)
end)

describe("Store aggregation on write", function()
	before_each(function()
		env.reset()
		stubItemDB({ [858] = { name = "Potion", quality = 1, class = 0, subClass = 0,
		                       equipLoc = "", itemLevel = 1, reqLevel = 0 },
		             [10132] = { name = "Helmet", quality = 2, class = 4, subClass = 3,
		                         equipLoc = "INVTYPE_HEAD", itemLevel = 51, reqLevel = 46 } })
		loadStore()
	end)

	-- Deduplicating on write rather than read means a caller cannot reintroduce the miscount.
	it("collapses duplicate stacks into one row", function()
		local stored = Store:SetAltRecords("Testguild", "Bob", {
			Record.new(858, 5), Record.new(858, 3), Record.new(858, 2),
		})
		assert.equal(1, stored)
		assert.equal(10, Record.count(Store:GetAltRecords("Testguild", "Bob")[1]))
	end)

	-- REQ-003: suffix siblings share a base id and must stay apart.
	it("keeps suffix variants as separate rows", function()
		local stored = Store:SetAltRecords("Testguild", "Bob", {
			Record.new(10132, 1, 863), Record.new(10132, 1, 865),
		})
		assert.equal(2, stored)
	end)

	it("reports skipped invalid records without dropping the good ones", function()
		local stored, skipped = Store:SetAltRecords("Testguild", "Bob", {
			Record.new(858, 5), { 0, 1 }, { 858 },
		})
		assert.equal(1, stored)
		assert.equal(2, skipped)
	end)

	-- Unstable ordering would rewrite the SavedVariables file on every save even when nothing
	-- changed, which is how SV files quietly grow and slow logins.
	it("stores rows in a stable order", function()
		Store:SetAltRecords("Testguild", "Bob", { Record.new(10132, 1), Record.new(858, 1) })
		local first = Store:GetAltRecords("Testguild", "Bob")
		Store:SetAltRecords("Testguild", "Bob", { Record.new(858, 1), Record.new(10132, 1) })
		local second = Store:GetAltRecords("Testguild", "Bob")
		assert.equal(Record.key(first[1]), Record.key(second[1]))
		assert.equal(Record.key(first[2]), Record.key(second[2]))
	end)
end)

describe("Store UI view", function()
	before_each(function()
		env.reset()
		stubItemDB({ [858] = { name = "Minor Healing Potion", quality = 1, class = 0,
		                       subClass = 0, equipLoc = "", itemLevel = 5, reqLevel = 0 } })
		loadStore()
		Store:SetAltRecords("Testguild", "Bob", { Record.new(858, 7) })
	end)

	-- The shape the existing UI already consumes, so the first cut of V2 needs no UI changes.
	it("presents records in the legacy item shape", function()
		local view = Store:GetAltView("Testguild", "Bob")
		assert.equal(1, #view)
		assert.equal(858, view[1].ID)
		assert.equal(7, view[1].Count)
		assert.equal("Minor Healing Potion", view[1].Info.name)
		assert.equal(1, view[1].Info.rarity)
		assert.is_not_nil(view[1].Link)
	end)

	it("caches the materialised view", function()
		local a = Store:GetAltView("Testguild", "Bob")
		local b = Store:GetAltView("Testguild", "Bob")
		assert.is_true(a == b, "view was rebuilt instead of served from cache")
	end)

	-- A stale view showing pre-change counts is indistinguishable from the sync bug this rework
	-- exists to remove, so the invalidation is asserted rather than trusted.
	it("drops the cached view when the alt is written", function()
		local before = Store:GetAltView("Testguild", "Bob")
		Store:SetAltRecords("Testguild", "Bob", { Record.new(858, 99) })
		local after = Store:GetAltView("Testguild", "Bob")
		assert.is_false(before == after, "cache survived a write")
		assert.equal(99, after[1].Count)
	end)

	it("drops the cached view when the alt is removed", function()
		Store:GetAltView("Testguild", "Bob")
		Store:RemoveAlt("Testguild", "Bob")
		assert.same({}, Store:GetAltView("Testguild", "Bob"))
	end)

	it("invalidates every view when called with no arguments", function()
		Store:SetAltRecords("Testguild", "Ann", { Record.new(858, 1) })
		Store:GetAltView("Testguild", "Bob")
		Store:GetAltView("Testguild", "Ann")
		assert.equal(2, Store:CachedViewCount())
		Store:InvalidateView()
		assert.equal(0, Store:CachedViewCount())
	end)

	it("returns an empty view for an unknown alt", function()
		assert.same({}, Store:GetAltView("Testguild", "Nobody"))
	end)
end)

describe("Store queries", function()
	before_each(function()
		env.reset()
		stubItemDB({ [858] = { name = "Potion", quality = 1, class = 0, subClass = 0,
		                       equipLoc = "", itemLevel = 1, reqLevel = 0 },
		             [10132] = { name = "Helmet", quality = 2, class = 4, subClass = 3,
		                         equipLoc = "", itemLevel = 51, reqLevel = 46 } })
		loadStore()
		Store:SetAltRecords("Testguild", "Bob", { Record.new(858, 10), Record.new(10132, 1, 863) })
		Store:SetAltRecords("Testguild", "Ann", { Record.new(858, 25) })
		Store:SetAltRecords("Testguild", "Cid", { Record.new(10132, 2, 865) })
	end)

	it("totals an item across every alt", function()
		assert.equal(35, Store:GetGuildTotal("Testguild", 858))
	end)

	-- Variants of one base item are different rows but the same item for a stock question.
	it("totals across suffix variants", function()
		assert.equal(3, Store:GetGuildTotal("Testguild", 10132))
	end)

	it("returns zero for an absent or nil item", function()
		assert.equal(0, Store:GetGuildTotal("Testguild", 99999))
		assert.equal(0, Store:GetGuildTotal("Testguild", nil))
	end)

	it("finds which alts hold an item, most stock first", function()
		local found = Store:FindItem("Testguild", 858)
		assert.equal(2, #found)
		assert.equal("Ann", found[1].name)
		assert.equal(25, found[1].count)
		assert.equal("Bob", found[2].name)
	end)

	it("returns an empty list when nobody holds the item", function()
		assert.same({}, Store:FindItem("Testguild", 99999))
		assert.same({}, Store:FindItem("Testguild", nil))
	end)

	-- Equal stock has to break ties by name, or the order is whatever pairs() happened to give
	-- and the same query renders differently between sessions.
	it("breaks equal counts alphabetically", function()
		Store:SetAltRecords("Testguild", "Zed", { Record.new(858, 10) })
		Store:SetAltRecords("Testguild", "Abe", { Record.new(858, 10) })
		Store:RemoveAlt("Testguild", "Ann")   -- leave only the three equal holders
		local found = Store:FindItem("Testguild", 858)
		assert.equal(3, #found)
		assert.equal("Abe", found[1].name)
		assert.equal("Bob", found[2].name)
		assert.equal("Zed", found[3].name)
	end)
end)
