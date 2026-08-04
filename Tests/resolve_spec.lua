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
