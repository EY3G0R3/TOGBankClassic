-- INV2-SUFFIX-001 — the suffix travels as a FIELD, never as something parsed back out of a link.
--
-- The defect this pins: a Record holds {id, count, suffix, enchant} with suffix as a first-class
-- value, but the UI view materialised only {ID, Count, Link, Info}. Consumers that needed the
-- suffix then recovered it with Item:GetSuffixID(row.Link) — and the link only carries it when
-- Resolve.describe's FIRST step ran, i.e. when LibItemDB knew the id. Step 2 emits a bare
-- "item:<id>" and step 3 emits no link at all, so on any client whose ItemDB lacks that id the
-- suffix silently became nil and every random-suffix variant matched every other one.
--
-- That is the operator's standing directive in miniature: "in V2 the link is just constructed on
-- the other side from ItemDB" and "link stripping is causing a lot of problems". The data was on
-- the record the whole time; these examples pin that it stays there.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Record, Store, Item

-- Deliberately LOSSY, and that is the point: GetSuffixLink ignores the suffix it is handed and
-- returns a bare link, exactly like Resolve step 2 on a client whose ItemDB lacks the id. A stub
-- that faithfully encoded the suffix would let the old link-parsing code pass and prove nothing.
local function stubLossyItemDB(items)
	LibStub.libs["LibItemDB-1.0"] = {
		HasItem = function(_, id) return items[id] ~= nil end,
		GetInfo = function(_, id)
			local d = items[id]
			if not d then return nil end
			return d.name, d.quality, d.class, d.subClass, d.equipLoc, d.itemLevel
		end,
		GetSuffixLink = function(_, id)
			return "|cffffffff|Hitem:" .. id .. "|h[" .. items[id].name .. "]|h|r"
		end,
		GetRequiredLevel = function(_, id) return items[id] and items[id].reqLevel or 0 end,
	}
	LibStub.minors["LibItemDB-1.0"] = 15
end

local function load()
	env.stubOutput()
	env.loadFile("Modules/Item.lua")
	env.loadFile("Modules/Inventory/Record.lua")
	env.loadFile("Modules/Inventory/Resolve.lua")
	env.loadFile("Modules/Inventory/Store.lua")
	Item   = TOGBankClassic_Item
	Record = TOGBankClassic_Inventory_Record
	Store  = TOGBankClassic_Inventory_Store
	TOGBankClassicInvDB = nil
	Store.db = nil
	Store:Init()
	Store:InvalidateView()
end

local SPIKED_CLUB = 10132
local TIGER, MONKEY = 863, 865

describe("INV2-SUFFIX-001: Store:GetAltView carries the suffix", function()
	before_each(function()
		env.reset()
		stubLossyItemDB({ [SPIKED_CLUB] = { name = "Spiked Club", quality = 2, class = 2,
		                                    subClass = 4, equipLoc = "INVTYPE_WEAPON",
		                                    itemLevel = 22, reqLevel = 17 } })
		load()
	end)

	it("exposes Suffix and Enchant as fields on the row", function()
		Store:SetAltRecords("Testguild", "Bob", { Record.new(SPIKED_CLUB, 1, TIGER, 0) })
		local view = Store:GetAltView("Testguild", "Bob")
		assert.equal(1, #view)
		assert.equal(TIGER, view[1].Suffix)
		assert.equal(0, view[1].Enchant)
	end)

	-- The whole failure scenario in one example. If this goes red the lossy round trip is back.
	it("reports the suffix even though the rebuilt Link has lost it", function()
		Store:SetAltRecords("Testguild", "Bob", { Record.new(SPIKED_CLUB, 1, TIGER, 0) })
		local row = Store:GetAltView("Testguild", "Bob")[1]
		assert.is_nil(Item:GetSuffixID(row.Link),
			"fixture is not exercising the defect: the link still encodes the suffix")
		assert.equal(TIGER, Item:RowSuffixID(row))
	end)

	-- Two variants of one base id must stay two rows with their own suffixes. Under the old
	-- shape both rendered identical links, so nothing downstream could tell them apart.
	it("keeps suffix siblings distinguishable", function()
		Store:SetAltRecords("Testguild", "Bob", {
			Record.new(SPIKED_CLUB, 1, TIGER, 0),
			Record.new(SPIKED_CLUB, 1, MONKEY, 0),
		})
		local view = Store:GetAltView("Testguild", "Bob")
		assert.equal(2, #view)
		local seen = {}
		for _, r in ipairs(view) do seen[Item:RowSuffixID(r)] = true end
		assert.is_true(seen[TIGER] and seen[MONKEY],
			"the two suffix variants did not survive as distinct rows")
	end)

	it("reports no suffix for a plain item", function()
		Store:SetAltRecords("Testguild", "Bob", { Record.new(SPIKED_CLUB, 3) })
		local row = Store:GetAltView("Testguild", "Bob")[1]
		assert.equal(0, row.Suffix)
		assert.is_nil(Item:RowSuffixID(row))
	end)
end)

describe("Item:RowSuffixID", function()
	before_each(function()
		env.reset(); env.stubOutput(); env.loadFile("Modules/Item.lua"); Item = TOGBankClassic_Item
	end)

	local function link(itemString)
		return "|cffffffff|Hitem:" .. itemString .. "|h[Thing]|h|r"
	end

	it("prefers the stored field over the link", function()
		-- The two disagree on purpose: the field must win, because the link is the derived copy.
		assert.equal(TIGER, Item:RowSuffixID({ Suffix = TIGER, Link = link("10132:0:0:0:0:0:0:1:60") }))
	end)

	-- The distinction the whole helper exists for. A V2 row saying 0 means "definitely no
	-- suffix"; a LEGACY row with no field at all means "unknown, ask the link". Collapsing these
	-- into `tonumber(row.Suffix) or GetSuffixID(row.Link)` would make legacy suffixed gear
	-- unmatchable, because 0 is truthy in Lua and would short-circuit the fallback away.
	it("treats a stored 0 as definitely no suffix, without consulting the link", function()
		assert.is_nil(Item:RowSuffixID({ Suffix = 0, Link = link("10132:0:0:0:0:0:863:1:60") }))
	end)

	it("falls back to the link when the row has no Suffix field at all", function()
		assert.equal(TIGER, Item:RowSuffixID({ Link = link("10132:0:0:0:0:0:863:1:60") }))
	end)

	it("preserves a negative suffix, which indexes the random-property table", function()
		assert.equal(-25, Item:RowSuffixID({ Suffix = -25 }))
	end)

	it("returns nil for a legacy row with neither field nor link", function()
		assert.is_nil(Item:RowSuffixID({ ID = SPIKED_CLUB }))
	end)

	it("returns nil for nil", function()
		assert.is_nil(Item:RowSuffixID(nil))
	end)
end)
