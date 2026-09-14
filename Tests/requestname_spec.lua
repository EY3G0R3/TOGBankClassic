-- NAME-001: a request row reading `Item 7969`, reported from a live guild ("item id did not resolve
-- into a descriptive name"). The requester's client could not name the item when the request was
-- created, the placeholder went into `request.item`, and the record -- correct as written, and
-- append-only -- carried it to every client for the life of the request. The request also carries
-- `itemID`, so the name is re-resolved from the id at display time and at creation time.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Item

--- A LibItemDB knowing exactly `items` (id -> name), the contract shape resolve_spec pins.
local function stubItemDB(items)
	LibStub.libs["LibItemDB-1.0"] = {
		HasItem = function(_, id) return items[id] ~= nil end,
		GetInfo = function(_, id) return items[id], 1, 0, 0, "", 1 end,
		GetSuffixLink = function(_, id) return "|cffffffff|Hitem:" .. id .. "|h[" .. items[id] .. "]|h|r" end,
		GetRequiredLevel = function() return 0 end,
		-- LibItemDB-1.0.lua:1255: base .. " " .. family; the base alone for an unknown property.
		ResolveSuffix = function(_, id, prop)
			if not items[id] then return nil end
			local family = ({ [1180] = "of the Bear", [28] = "of Spirit" })[prop]
			return { id = id, name = family and (items[id] .. " " .. family) or items[id] }
		end,
	}
	LibStub.minors["LibItemDB-1.0"] = 15
end

describe("NAME-001: naming a request", function()
	before_each(function()
		env.reset(); env.stubOutput()
		stubItemDB({ [7969] = "Nightshade" })
		env.loadModules({ "Modules/Constants.lua", "Modules/Item.lua",
			"Modules/Inventory/Record.lua", "Modules/Inventory/Resolve.lua" })
		Item = TOGBankClassic_Item
	end)

	it("knows the three placeholder spellings, and nothing else", function()
		assert.is_true(Item:IsPlaceholderName("Item 7969"))
		assert.is_true(Item:IsPlaceholderName("Unknown item"))
		assert.is_true(Item:IsPlaceholderName("Unknown"))
		assert.is_true(Item:IsPlaceholderName(""))
		assert.is_true(Item:IsPlaceholderName(nil))
		assert.is_false(Item:IsPlaceholderName("Nightshade"))
		assert.is_false(Item:IsPlaceholderName("Item of the Tiger"), "a real name starting with 'Item' is not a placeholder")
	end)

	it("shows a stored real name as-is, without touching the resolver", function()
		assert.equal("Felcloth", Item:RequestDisplayName({ item = "Felcloth", itemID = 14256 }))
	end)

	it("re-resolves a stored placeholder from the id -- the live report", function()
		local req = { item = "Item 7969", itemID = 7969, quantity = 1 }
		assert.equal("Nightshade", Item:RequestDisplayName(req), "the request window still reads `Item 7969`")
		assert.equal("Item 7969", req.item, "the stored record was mutated; it is the wire's, not the UI's")
	end)

	it("re-resolves through the client cache when ItemDB does not know the id", function()
		env.defineItem(4306, { name = "Silk Cloth" })
		assert.equal("Silk Cloth", Item:RequestDisplayName({ item = "Item 4306", itemID = 4306 }))
	end)

	it("keeps the placeholder when nothing can name the id, and 'Unknown' when there is no id", function()
		assert.equal("Item 1234567", Item:RequestDisplayName({ item = "Item 1234567", itemID = 1234567 }))
		assert.equal("Unknown item", Item:RequestDisplayName({ item = "Unknown item" }), "a legacy request with no itemID")
		assert.equal("Unknown", Item:RequestDisplayName({}))
	end)

	-- SUFFIX-NAME-001 (the operator, 2026-09-13, with the Requests tab showing "Warmonger's Greaves"
	-- for a suffixed order: "the item in the requests HAS to show the link or i'm not able to fill
	-- the order properly ... aka, the suffixes"). The field report behind it: request 90fe527732a434
	-- carried 4564:1180 ("of the Bear"), stored as "Spiked Club" -- and the banker read "Spiked
	-- Club", which they had... of Spirit. A request carrying a suffix names the VARIANT, whatever
	-- base name was stored with it; the stored record is untouched.
	it("names a suffixed request by its variant, even when a real base name was stored", function()
		stubItemDB({ [4564] = "Spiked Club" })
		local req = { item = "Spiked Club", itemID = 4564, suffixID = 1180, quantity = 1 }
		assert.equal("Spiked Club of the Bear", Item:RequestDisplayName(req))
		assert.equal("Spiked Club of Spirit", Item:RequestDisplayName({ item = "Spiked Club", itemID = 4564, suffixID = 28 }))
		assert.equal("Spiked Club", req.item, "the stored record was mutated")
		-- No suffix, or suffix 0: the stored name, untouched, as before.
		assert.equal("Spiked Club", Item:RequestDisplayName({ item = "Spiked Club", itemID = 4564 }))
		assert.equal("Spiked Club", Item:RequestDisplayName({ item = "Spiked Club", itemID = 4564, suffixID = 0 }))
		-- The library does not know the id: the stored name stands rather than a placeholder.
		assert.equal("Spiked Club", Item:RequestDisplayName({ item = "Spiked Club", itemID = 999999, suffixID = 1180 }))
	end)
end)
