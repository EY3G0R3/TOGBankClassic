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
		assert.equal(env.EPOCH + 500, TOGBankClassicInvDB.faction["Testguild"].alts["Bob-Testrealm"].updated)
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

	-- DOUBLE-001. The operator, 2026-09-12: "i only have 3x archaic defenders. the ui is showing 6.
	-- most of the things on toglowweap are doubled in the UI" -- and `/togbank dev sources` showed
	-- why: an `all` bucket (a delivery stored wholesale -- the store is account-wide, so a viewer alt
	-- on the same account stores its banker's record as `all`) carried forward BESIDE the bags/bank/
	-- mail buckets the banker's own scans then wrote. The view sums every bucket. The v1.1.0
	-- ITEM-004 class -- a source summed instead of replaced -- in the V2 store.
	describe("DOUBLE-001: a wholesale bucket and per-source buckets never coexist", function()
		it("a scan's named source REPLACES a stored wholesale bucket instead of being summed with it", function()
			-- The delivery: the whole record, as a same-account viewer alt stores it.
			Store:SetAltRecords("Testguild", "Bob", { Record.new(9385, 3), Record.new(4088, 1, 1191), Record.new(858, 20) }, 100)
			assert.equal(3, Store:GetAltItemTotal("Testguild", "Bob", 9385))
			-- The banker's own scan, away from the vault: bags only (the swords are in the bags).
			Store:SetAltSources("Testguild", "Bob", { bags = { Record.new(9385, 3), Record.new(4088, 1, 1191) } }, 100)
			assert.equal(3, Store:GetAltItemTotal("Testguild", "Bob", 9385), "Archaic Defender counted from `all` AND from `bags`")
			local recs = Store:GetAltRecords("Testguild", "Bob")
			assert.equal(2, #recs, "the wholesale bucket survived beside the scan's bucket")
			local g = Store:GuildTable("Testguild", false)
			assert.is_nil(g.alts.Bob.sources.all, "`all` is still stored beside a named source")
			assert.is_table(g.alts.Bob.sources.bags)
			-- A later vault read adds its bucket beside bags, as it should; nothing doubles.
			Store:SetAltSources("Testguild", "Bob", { bank = { Record.new(858, 20) } }, 100)
			assert.equal(3, #Store:GetAltRecords("Testguild", "Bob"))
			assert.equal(20, Store:GetAltItemTotal("Testguild", "Bob", 858))
			-- And the reverse still holds: a delivery replaces every bucket wholesale.
			Store:SetAltRecords("Testguild", "Bob", { Record.new(858, 5) }, 100)
			assert.equal(1, #Store:GetAltRecords("Testguild", "Bob"))
			assert.is_nil(g.alts.Bob.sources.bags)
		end)

		it("drops the hidden half of the wholesale bucket with the visible half", function()
			Store:SetAltRecords("Testguild", "Bob", { Record.new(9385, 3), Record.new(858, 20) }, 100)
			-- The hide split ran over `all` too (the operator's dump: `hidden all: 1 row`).
			Store:SetAltSources("Testguild", "Bob", {}, 100, { [Record.key(Record.new(858, 20))] = true })
			assert.is_table(Store:GuildTable("Testguild", false).alts.Bob.hidden.all)
			Store:SetAltSources("Testguild", "Bob", { bags = { Record.new(9385, 3) } }, 100, { [Record.key(Record.new(858, 20))] = true })
			local alt = Store:GuildTable("Testguild", false).alts.Bob
			assert.is_nil(alt.sources.all); assert.is_nil(alt.hidden and alt.hidden.all)
			assert.equal(3, Store:GetAltItemTotal("Testguild", "Bob", 9385))
		end)

		it("repairs a record already on disk in that state at Init, and reports how many", function()
			-- Written straight into the SavedVariable shape the operator's client holds.
			local g = Store:GuildTable("Testguild", true)
			g.alts.Bob = {
				sources = { all = { { 9385, 3 }, { 858, 20 } }, bags = { { 9385, 3 } }, bank = { { 858, 20 } }, mail = {} },
				hidden  = { all = { { 4088, 1, 1191 } }, bags = { { 4088, 1, 1191 } } },
				money = 100, updated = 1, schema = 2,
			}
			g.alts.Clean = { sources = { bags = { { 858, 1 } } }, money = 0, updated = 1, schema = 2 }
			g.alts.Received = { sources = { all = { { 858, 7 } } }, money = 0, updated = 1, schema = 2 }
			Store:InvalidateView()
			assert.equal(6, Store:GetAltItemTotal("Testguild", "Bob", 9385), "precondition: the on-disk state double-counts")
			Store:Init()
			assert.equal(1, Store.repaired, "exactly the one alt holding `all` beside named sources is repaired")
			assert.equal(3, Store:GetAltItemTotal("Testguild", "Bob", 9385))
			assert.is_nil(g.alts.Bob.sources.all); assert.is_nil(g.alts.Bob.hidden.all)
			assert.is_table(g.alts.Bob.hidden.bags, "the banker's own hidden rows were dropped with the repair")
			assert.is_table(g.alts.Received.sources.all, "a purely received record (all only) was touched")
			assert.equal(7, Store:GetAltItemTotal("Testguild", "Received", 858))
			assert.equal(0, Store:RepairWholesaleBuckets(), "a second pass found something to repair on a clean store")
		end)
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

	-- RESOLVE-002: the legacy loader stores equipId as the NUMERIC Enum.InventoryType; the view
	-- used to copy ItemDB's INVTYPE_* STRING into the same field. The By-Type sort compares it
	-- with `<`, so a V2 row sorted by token spelling, and a Search result mixing a V2 alt with a
	-- legacy-only alt compared a string against a number -- a Lua error in the comparator.
	describe("equipId is the numeric inventory type, as the legacy rows carry it", function()
		it("maps the INVTYPE token to Enum.InventoryType", function()
			stubItemDB({
				[10132] = { name = "Revenant Helmet", quality = 2, class = 4, subClass = 4, equipLoc = "INVTYPE_HEAD", itemLevel = 50, reqLevel = 45 },
				[2589]  = { name = "Linen Cloth", quality = 1, class = 7, subClass = 5, equipLoc = "", itemLevel = 5, reqLevel = 0 },
			})
			Store:SetAltRecords("Testguild", "Ann", { Record.new(10132, 1), Record.new(2589, 20) })
			local byId = {}
			for _, row in ipairs(Store:GetAltView("Testguild", "Ann")) do byId[row.ID] = row end
			assert.equal(1, byId[10132].Info.equipId, "INVTYPE_HEAD is Enum.InventoryType.IndexHeadType = 1")
			assert.equal(0, byId[2589].Info.equipId, "a non-equippable item is IndexNonEquipType = 0, as the legacy path stores it")
			assert.equal("number", type(byId[10132].Info.equipId))
		end)

		it("covers every equip slot Era's Enum.InventoryType names, 1..28", function()
			local seen = {}
			for _, v in pairs(Store.INVTYPE_TO_ID) do seen[v] = true end
			for v = 1, 28 do assert.is_true(seen[v], "no INVTYPE token maps to inventory type " .. v) end
		end)

		it("survives the By-Type comparator against a legacy row with a numeric equipId", function()
			stubItemDB({ [10132] = { name = "Revenant Helmet", quality = 2, class = 4, subClass = 4, equipLoc = "INVTYPE_HEAD", itemLevel = 50, reqLevel = 45 } })
			Store:SetAltRecords("Testguild", "Ann", { Record.new(10132, 1) })
			local v2 = Store:GetAltView("Testguild", "Ann")[1]
			local legacy = { ID = 7969, Count = 1, Info = { name = "Nightshade", class = 4, subClass = 4, reqLevel = 45, equipId = 5, rarity = 2 } }
			assert.has_no_error(function()
				table.sort({ v2, legacy }, function(a, b) return (a.Info.equipId or 0) < (b.Info.equipId or 0) end)
			end)
		end)
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

	-- LOG-MAIL-001: what the banker HOLDS is every source but the inbox, aggregated; a received
	-- (wholesale) record answers everything, having no source split; the mail rows stay in the
	-- full set the version and the viewers carry.
	it("answers the held set -- bags and bank, never mail -- as one aggregated array", function()
		Store:SetAltSources("Testguild", "Bob", {
			bags = { Record.new(858, 4) }, bank = { Record.new(858, 6), Record.new(10132, 1, 863) },
			mail = { Record.new(858, 12), Record.new(2589, 20) },
		}, 0)
		local held = {}
		for _, rec in ipairs(Store:GetAltHeldRecords("Testguild", "Bob")) do held[Record.key(rec)] = Record.count(rec) end
		assert.same({ ["858:0:0"] = 10, ["10132:863:0"] = 1 }, held, "the held set is not bags + bank aggregated")
		local full = {}
		for _, rec in ipairs(Store:GetAltRecords("Testguild", "Bob")) do full[Record.key(rec)] = Record.count(rec) end
		assert.equal(22, full["858:0:0"], "the full set lost the mail rows"); assert.equal(20, full["2589:0:0"])
		-- A delivery's wholesale bucket: everything, and the same shape.
		local all = Store:GetAltHeldRecords("Testguild", "Ann")
		assert.equal(1, #all); assert.equal(25, Record.count(all[1]))
		assert.same({}, Store:GetAltHeldRecords("Testguild", "Nobody"))
		-- Fresh per call: appending to it must not reach the store.
		local h = Store:GetAltHeldRecords("Testguild", "Bob"); h[#h + 1] = Record.new(1, 1)
		assert.equal(2, #Store:GetAltHeldRecords("Testguild", "Bob"))
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

-- PERF-022 (audit finding 13): the tooltip hover asked every banker "how many of X" by walking
-- its whole record set, O(bankers x items) on the client's hottest path. The store now answers
-- from a per-alt itemID index. The property that matters is INVALIDATION -- an index that misses
-- a writer is worse than the scan -- so every write path is driven here and the index is proven
-- rebuilt by counting record walks, not by trusting the comment.
describe("Store per-alt item index (PERF-022)", function()
	local walks

	before_each(function()
		env.reset()
		stubItemDB({ [858] = { name = "Potion", quality = 1, class = 0, subClass = 0, equipLoc = "", itemLevel = 1, reqLevel = 0 } })
		loadStore()
		Store:SetAltRecords("Testguild", "Bob", { Record.new(858, 10), Record.new(10132, 1, 863), Record.new(10132, 2, 865) })
		-- Count record walks: GetAltRecords is what the index is built FROM, so an ask that walks it
		-- is an ask the index did not answer.
		walks = 0
		local real = Store.GetAltRecords
		Store.GetAltRecords = function(...) walks = walks + 1; return real(...) end
	end)

	it("answers a total across every variant, and zero for an item or alt it does not hold", function()
		assert.equal(10, Store:GetAltItemTotal("Testguild", "Bob", 858))
		assert.equal(3, Store:GetAltItemTotal("Testguild", "Bob", 10132), "suffix variants are one item for a stock question")
		assert.equal(0, Store:GetAltItemTotal("Testguild", "Bob", 99999))
		assert.equal(0, Store:GetAltItemTotal("Testguild", "Nobody", 858))
		assert.equal(0, Store:GetAltItemTotal("Testguild", "Bob", nil))
	end)

	it("walks the records ONCE per alt, then answers every later ask from the index", function()
		Store:GetAltItemTotal("Testguild", "Bob", 858)
		assert.equal(1, walks, "the first ask must build the index from the records")
		Store:GetAltItemTotal("Testguild", "Bob", 10132)
		Store:GetAltItemTotal("Testguild", "Bob", 858)
		Store:GetAltItemTotal("Testguild", "Bob", 99999)
		assert.equal(1, walks, "a later ask walked the records: the hover is back to O(items) per banker")
	end)

	it("is rebuilt after SetAltRecords, after SetAltSources, and after RemoveAlt -- every writer", function()
		-- The writes call GetAltRecords themselves (the stored-row count), so the walk counter is
		-- read per ASK: exactly one walk after a write, none without one.
		local function askCosts(expectedWalks, expectedTotal, why)
			walks = 0
			assert.equal(expectedTotal, Store:GetAltItemTotal("Testguild", "Bob", 858), why)
			assert.equal(expectedWalks, walks, why)
		end
		askCosts(1, 10, "first ask builds")
		askCosts(0, 10, "second ask is served")
		Store:SetAltRecords("Testguild", "Bob", { Record.new(858, 4) })
		askCosts(1, 4, "a wholesale write left the index stale")
		-- DOUBLE-001: this used to expect 11 -- the delivery's 4 SUMMED with the scan's 7 -- which is
		-- the double-count itself, ratified. A named source replaces the wholesale bucket: 7.
		Store:SetAltSources("Testguild", "Bob", { bags = { Record.new(858, 7) } })
		askCosts(1, 7, "a per-source write left the index stale")
		askCosts(0, 7, "served again")
		Store:RemoveAlt("Testguild", "Bob")
		askCosts(0, 0, "a removed alt still answered from its index, or built one from nothing")
	end)

	it("caches nothing for an alt the store has not seen", function()
		assert.equal(0, Store:GetAltItemTotal("Testguild", "Nobody", 858))
		assert.equal(0, walks, "an unknown alt must not walk anything")
		Store:SetAltRecords("Testguild", "Nobody", { Record.new(858, 2) })
		assert.equal(2, Store:GetAltItemTotal("Testguild", "Nobody", 858), "an empty index cached for the unknown name answered for the real one")
	end)

	it("is dropped by the global InvalidateView along with the caches it derives from", function()
		Store:GetAltItemTotal("Testguild", "Bob", 858)
		Store:InvalidateView()
		Store:GetAltItemTotal("Testguild", "Bob", 858)
		assert.equal(2, walks)
	end)

	it("is what GetGuildTotal and FindItem read", function()
		Store:SetAltRecords("Testguild", "Ann", { Record.new(858, 25) })
		assert.equal(35, Store:GetGuildTotal("Testguild", 858))
		assert.equal("Ann", Store:FindItem("Testguild", 858)[1].name)
		walks = 0
		Store:GetGuildTotal("Testguild", 858)
		Store:FindItem("Testguild", 858)
		assert.equal(0, walks, "the guild-wide queries walked records the index already covered")
	end)
end)
