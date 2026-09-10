-- Inventory/Resolve — deriving display data from a V2 tuple.
--
-- The contract that matters most is the fallback chain: this must ALWAYS return something
-- displayable and must never error, because V2 stores integers and there is no stored link to
-- fall back on. A blank row or a Lua error in place of an item is worse than a labelled unknown.
--
-- Specs run against a STUBBED LibItemDB that behaves as docs/LIBRARY_CONTRACTS.md §1 specifies,
-- so they pass without the real library installed and pin the contract rather than one version's
-- behaviour. `resolve_integration_spec.lua` exercises the real thing separately.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Record, Resolve

--- Install a fake LibItemDB honouring the contract. `items` maps id -> field table.
local function stubItemDB(items, opts)
	opts = opts or {}
	local lib = {
		HasItem = function(_, id) return items[id] ~= nil end,
		GetInfo = function(_, id)
			local d = items[id]
			if not d then return nil end
			-- Contract order: name, quality, classID, subClassID, equipLoc, itemLevel
			return d.name, d.quality, d.class, d.subClass, d.equipLoc, d.itemLevel
		end,
		GetSuffixLink = function(_, id, suffix, enchant)
			local s = "item:" .. id
			if enchant then s = ("item:%d:%d:::::%d"):format(id, enchant, suffix or 0)
			elseif suffix then s = ("item:%d::::::%d"):format(id, suffix) end
			return "|cffffffff|H" .. s .. "|h[" .. (items[id].name or "?") .. "]|h|r"
		end,
	}
	-- LIBREQ-IDB-002 arrived later than the rest of the API, so Resolve feature-detects it.
	if not opts.withoutRequiredLevel then
		lib.GetRequiredLevel = function(_, id) return items[id] and items[id].reqLevel or 0 end
	end
	LibStub.libs["LibItemDB-1.0"] = lib
	LibStub.minors["LibItemDB-1.0"] = 15
	return lib
end

local function loadResolve()
	env.stubOutput()
	env.loadFile("Modules/Inventory/Record.lua")
	env.loadFile("Modules/Inventory/Resolve.lua")
	Record  = TOGBankClassic_Inventory_Record
	Resolve = TOGBankClassic_Inventory_Resolve
end

describe("Resolve via LibItemDB", function()
	before_each(function()
		env.reset()
		stubItemDB({
			[858]   = { name = "Minor Healing Potion", quality = 1, class = 0, subClass = 1,
			            equipLoc = "", itemLevel = 5, reqLevel = 0 },
			[10132] = { name = "Revenant Helmet", quality = 2, class = 4, subClass = 3,
			            equipLoc = "INVTYPE_HEAD", itemLevel = 51, reqLevel = 46 },
		})
		loadResolve()
	end)

	-- RESOLVE-001. The itemdb branch hardcoded the placeholder icon, so every item that resolved
	-- SUCCESSFULLY drew as a question mark while its name, link, quality and stack count were all
	-- correct beside it -- which is why it read as an icon-cache problem rather than a missing
	-- field. The pre-existing guard asserted only `d.icon ~= nil`, which the placeholder satisfies:
	-- a check that cannot distinguish the right answer from the fallback cannot catch this.
	it("uses the item's real icon, not the unknown-item placeholder", function()
		env.defineItem(858, { name = "Minor Healing Potion", icon = 132948 })
		local d = Resolve.describe(Record.new(858, 1))
		assert.equal("itemdb", d.resolved)
		assert.equal(132948, d.icon,
			"a successfully resolved item drew the unknown-item placeholder. LibItemDB ships no " ..
			"icon (there is no GetIcon), so the icon must come from GetItemInfoInstant, which is " ..
			"cache-independent and answers on a cold client (RESOLVE-001)")
	end)

	-- The icon is a pure function of item id, so it is looked up once per DISTINCT id rather than
	-- once per row. Asserted by counting calls, because "it is cached" is otherwise a claim about
	-- code that no test exercises.
	it("looks the icon up once per distinct item id, not once per row", function()
		Resolve.ClearIconCache()
		env.defineItem(858, { name = "Minor Healing Potion", icon = 132948 })
		local calls = 0
		local real = GetItemInfoInstant
		GetItemInfoInstant = function(...) calls = calls + 1; return real(...) end

		for _ = 1, 25 do Resolve.describe(Record.new(858, 1)) end
		assert.equal(1, calls,
			"the icon was looked up per row. A bank holding hundreds of stacks of the same item " ..
			"would pay for every one of them (RESOLVE-001)")

		GetItemInfoInstant = real
	end)

	it("remembers a MISS too, so a failing id is not retried on every rebuild", function()
		Resolve.ClearIconCache()
		local calls = 0
		local real = GetItemInfoInstant
		GetItemInfoInstant = function(...) calls = calls + 1; return real(...) end

		-- 10132 is in the stubbed LibItemDB but has no defined client item, so it has no icon.
		for _ = 1, 10 do Resolve.describe(Record.new(10132, 1)) end
		assert.equal(1, calls,
			"an id with no icon was looked up repeatedly -- caching only hits means exactly the " ..
			"ids that fail are the ones retried forever, which is backwards")

		GetItemInfoInstant = real
	end)

	-- The placeholder must still be there when the client genuinely has nothing.
	it("falls back to the placeholder icon when the client has no icon for the id", function()
		local d = Resolve.describe(Record.new(10132, 1))
		assert.equal("itemdb", d.resolved)
		assert.is_not_nil(d.icon, "an unknown icon must never come back nil -- the UI draws it directly")
	end)

	it("resolves a plain item", function()
		local d = Resolve.describe(Record.new(858, 20))
		assert.equal("Minor Healing Potion", d.name)
		assert.equal("itemdb", d.resolved)
		assert.equal(1, d.quality)
	end)

	it("carries item level, required level, class and equip slot", function()
		local d = Resolve.describe(Record.new(10132, 1))
		assert.equal(51, d.itemLevel)
		assert.equal(46, d.reqLevel)
		assert.equal(4, d.class)
		assert.equal("INVTYPE_HEAD", d.equipLoc)
	end)

	it("builds a link with the suffix for random-suffix gear", function()
		local d = Resolve.describe(Record.new(10132, 1, 863))
		assert.truthy(d.link:find("::::::863", 1, true), "suffix missing from link: " .. tostring(d.link))
	end)

	it("builds a link carrying the enchant", function()
		local d = Resolve.describe(Record.new(10132, 1, 863, 2504))
		assert.truthy(d.link:find(":2504:", 1, true), "enchant missing from link: " .. tostring(d.link))
	end)

	-- A plain item must not get a suffix field, or its key and its link disagree about what it is.
	it("omits the suffix field entirely for a plain item", function()
		local d = Resolve.describe(Record.new(858, 1))
		assert.falsy(d.link:find("::::::", 1, true))
	end)

	-- LIBREQ-IDB-002 is feature-detected, not version-tested: LibStub can resolve an older copy
	-- that has the item data but not this method, and the handle looks healthy either way.
	it("degrades to reqLevel 0 when the library lacks GetRequiredLevel", function()
		env.reset()
		stubItemDB({ [10132] = { name = "Revenant Helmet", quality = 2, class = 4, subClass = 3,
		                          equipLoc = "INVTYPE_HEAD", itemLevel = 51, reqLevel = 46 } },
		           { withoutRequiredLevel = true })
		loadResolve()
		local d = Resolve.describe(Record.new(10132, 1))
		assert.equal(0, d.reqLevel)
		assert.equal("itemdb", d.resolved, "should still resolve, just without the level")
	end)
end)

describe("Resolve fallback chain", function()
	before_each(function()
		env.reset()
		stubItemDB({ [858] = { name = "Known", quality = 1, class = 0, subClass = 0,
		                       equipLoc = "", itemLevel = 1, reqLevel = 0 } })
		loadResolve()
	end)

	-- Step 2. GetItemInfoInstant needs no warm cache, which is why it can answer where the
	-- legacy loader had to go asynchronous.
	it("falls back to the client for an id LibItemDB does not know", function()
		env.defineItem(99999, { name = "Patch Item", class = 2, subClass = 7 })
		local d = Resolve.describe(Record.new(99999, 1))
		assert.equal("client", d.resolved)
		assert.equal(2, d.class)
	end)

	it("falls back to a placeholder when nothing knows the item", function()
		local d = Resolve.describe(Record.new(1234567, 1))
		assert.equal("placeholder", d.resolved)
		assert.equal("Item 1234567", d.name)
	end)

	-- The non-negotiable property: something displayable, always.
	it("never returns nil and never errors, whatever the id", function()
		for _, id in ipairs({ 858, 99999, 1234567 }) do
			local ok, d = pcall(Resolve.describe, Record.new(id, 1))
			assert.is_true(ok, "describe errored for id " .. id)
			assert.is_not_nil(d.name)
			assert.is_not_nil(d.icon)
		end
	end)

	it("handles an invalid record without erroring", function()
		local ok, d = pcall(Resolve.describe, { 0, 0 })
		assert.is_true(ok)
		assert.equal("invalid", d.resolved)
	end)

	it("works with no LibItemDB at all", function()
		env.reset()
		LibStub.libs["LibItemDB-1.0"] = nil
		loadResolve()
		env.defineItem(858, { name = "Client Only", class = 0 })
		local d = Resolve.describe(Record.new(858, 1))
		assert.equal("client", d.resolved)
	end)
end)

-- ItemDB became a REQUIRED dependency when INV2 landed (declared in both TOCs, slug `libitemdb`
-- in .pkgmeta). A required dependency that did not load has to be LOUD, and this one is
-- especially easy to miss: V2 stores integer tuples and rebuilds the link at render time, so
-- with no library there is nothing to rebuild from and every row quietly becomes a placeholder.
-- Resolve asks for it through LibStub's optional form, which returns nil rather than raising, so
-- without this nothing anywhere would say a word.
describe("Resolve missing-library reporting", function()
	local function errors()
		local out = {}
		for _, c in ipairs(TOGBankClassic_Output.calls or {}) do
			if c.level == "Error" then out[#out + 1] = tostring(c[1]) end
		end
		return out
	end

	before_each(function()
		env.reset()
		LibStub.libs["LibItemDB-1.0"] = nil
		loadResolve()
		env.defineItem(858, { name = "Client Only", class = 0 })
	end)

	it("reports the missing library at a level the player sees", function()
		Resolve.describe(Record.new(858, 1))
		local e = errors()
		assert.equal(1, #e, "expected exactly one Error, got " .. #e)
		assert.is_not_nil(e[1]:find("LibItemDB", 1, true),
			"the error must name the library so the player knows what to reinstall: " .. e[1])
	end)

	-- Keyed on the LIBRARY, not per item id the way noteUnresolved is. Routing this through the
	-- per-id tracker would report once per distinct item -- thousands of identical lines, in a
	-- debug category that is off by default, which is indistinguishable from silence.
	it("reports it once, however many items are resolved", function()
		for _ = 1, 20 do Resolve.describe(Record.new(858, 1)) end
		assert.equal(1, #errors(), "the missing-library error is not deduped")
	end)

	it("says nothing when the library is present", function()
		env.reset()
		stubItemDB({ [858] = { name = "Known", quality = 1, class = 0, subClass = 0,
		                       equipLoc = "", itemLevel = 1, reqLevel = 0 } })
		loadResolve()
		Resolve.describe(Record.new(858, 1))
		assert.equal(0, #errors(), "a healthy install must not report a missing dependency")
	end)
end)

describe("Resolve unresolved tracking", function()
	before_each(function()
		env.reset()
		stubItemDB({ [858] = { name = "Known", quality = 1, class = 0, subClass = 0,
		                       equipLoc = "", itemLevel = 1, reqLevel = 0 } })
		loadResolve()
		Resolve.resetUnresolved()
	end)

	-- Silent degradation is the failure mode the rework exists to remove: an id that keeps
	-- falling past IDB is a gap in the shipped data, and it should be collectable.
	it("records ids that fall past LibItemDB", function()
		Resolve.describe(Record.new(1234567, 1))
		local list = Resolve.getUnresolved()
		assert.equal(1, #list)
		assert.equal(1234567, list[1].id)
	end)

	it("does not record ids it resolved", function()
		Resolve.describe(Record.new(858, 1))
		assert.equal(0, #Resolve.getUnresolved())
	end)

	-- Reported once, not once per draw — the inventory redraws constantly.
	it("records each id only once", function()
		for _ = 1, 5 do Resolve.describe(Record.new(1234567, 1)) end
		assert.equal(1, #Resolve.getUnresolved())
	end)

	it("returns the list sorted by id", function()
		Resolve.describe(Record.new(3000000, 1))
		Resolve.describe(Record.new(1234567, 1))
		local list = Resolve.getUnresolved()
		assert.equal(1234567, list[1].id)
		assert.equal(3000000, list[2].id)
	end)
end)

describe("Resolve convenience accessors", function()
	before_each(function()
		env.reset()
		stubItemDB({ [858] = { name = "Minor Healing Potion", quality = 1, class = 0,
		                       subClass = 0, equipLoc = "", itemLevel = 1, reqLevel = 0 } })
		loadResolve()
	end)

	it("name returns the display name", function()
		assert.equal("Minor Healing Potion", Resolve.name(Record.new(858, 1)))
	end)

	it("link returns the clickable link", function()
		assert.truthy(Resolve.link(Record.new(858, 1)):find("|Hitem:858", 1, true))
	end)

	-- Callers must handle nil rather than feeding it to SetHyperlink, which fails silently and
	-- shows no tooltip at all.
	it("link returns nil when no link can be built", function()
		assert.is_nil(Resolve.link(Record.new(1234567, 1)))
	end)
end)
