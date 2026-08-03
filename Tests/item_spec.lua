-- Item.lua — item-string parsing, deduplication keys, aggregation, and async loading.
--
-- These are the addon's identity functions for items. GetItemKey decides whether two stacks are
-- "the same item" for every count in the UI and on the wire, and GetItems is the gate every
-- inventory render passes through. A defect in either shows up as wrong counts or a window that
-- never finishes loading, not as an error.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function link(itemString, name)
	return "|cffffffff|Hitem:" .. itemString .. "|h[" .. (name or "Thing") .. "]|h|r"
end

describe("Item:GetItemString", function()
	local Item
	before_each(function()
		env.reset(); env.stubOutput(); env.loadFile("Modules/Item.lua"); Item = TOGBankClassic_Item
	end)

	it("extracts the item string from a full link", function()
		assert.equal("item:10132:0:0:0:0:0:863", Item:GetItemString(link("10132:0:0:0:0:0:863")))
	end)

	it("returns empty string for nil", function()
		assert.equal("", Item:GetItemString(nil))
	end)

	it("returns empty string for an empty link", function()
		assert.equal("", Item:GetItemString(""))
	end)
end)

describe("Item:GetItemKey", function()
	local Item
	before_each(function()
		env.reset(); env.stubOutput(); env.loadFile("Modules/Item.lua"); Item = TOGBankClassic_Item
	end)

	-- Parts 8+ (uniqueID, level) differ per instance of the same item; keeping them would make
	-- one stack look like several distinct items.
	it("strips the unique instance ID so identical items share a key", function()
		local a = Item:GetItemKey(link("10132:0:0:0:0:0:863:1111:60"))
		local b = Item:GetItemKey(link("10132:0:0:0:0:0:863:2222:60"))
		assert.equal(a, b)
	end)

	it("keeps the random suffix, so suffix siblings stay distinct", function()
		local tiger  = Item:GetItemKey(link("10132:0:0:0:0:0:863:1:60"))
		local monkey = Item:GetItemKey(link("10132:0:0:0:0:0:865:1:60"))
		assert.truthy(tiger ~= monkey, "two different random suffixes collapsed to one key")
	end)

	it("keeps the enchant, so an enchanted item is distinct", function()
		local plain     = Item:GetItemKey(link("10132:0:0:0:0:0:0:1:60"))
		local enchanted = Item:GetItemKey(link("10132:1234:0:0:0:0:0:1:60"))
		assert.truthy(plain ~= enchanted)
	end)

	it("returns empty string for nil", function()
		assert.equal("", Item:GetItemKey(nil))
	end)
end)

describe("Item:GetSuffixID", function()
	local Item
	before_each(function()
		env.reset(); env.stubOutput(); env.loadFile("Modules/Item.lua"); Item = TOGBankClassic_Item
	end)

	it("reads the suffix from field 7", function()
		assert.equal(863, Item:GetSuffixID(link("10132:0:0:0:0:0:863:1:60")))
	end)

	it("returns nil when the suffix is zero", function()
		assert.is_nil(Item:GetSuffixID(link("10132:0:0:0:0:0:0:1:60")))
	end)

	it("returns nil for a link with no suffix field", function()
		assert.is_nil(Item:GetSuffixID(link("10132")))
	end)

	-- Negative suffix IDs are real: they index the random-property table rather than the
	-- random-suffix table. Dropping the sign would merge two genuinely different items.
	it("preserves a negative suffix", function()
		assert.equal(-25, Item:GetSuffixID(link("10132:0:0:0:0:0:-25:1:60")))
	end)

	it("returns nil for nil", function()
		assert.is_nil(Item:GetSuffixID(nil))
	end)
end)

describe("Item:Aggregate", function()
	local Item
	before_each(function()
		env.reset(); env.stubOutput(); env.loadFile("Modules/Item.lua"); Item = TOGBankClassic_Item
	end)

	local function totalFor(result, id)
		local n = 0
		for _, v in pairs(result) do if v.ID == id then n = n + v.Count end end
		return n
	end

	local function countEntries(result)
		local n = 0
		for _ in pairs(result) do n = n + 1 end
		return n
	end

	it("sums two stacks of the same item", function()
		local a = { { ID = 858, Count = 5, Link = link("858") } }
		local b = { { ID = 858, Count = 3, Link = link("858") } }
		local r = Item:Aggregate(a, b)
		assert.equal(1, countEntries(r))
		assert.equal(8, totalFor(r, 858))
	end)

	it("keeps different items separate", function()
		local r = Item:Aggregate(
			{ { ID = 858, Count = 5, Link = link("858") } },
			{ { ID = 859, Count = 3, Link = link("859") } })
		assert.equal(2, countEntries(r))
	end)

	it("keeps suffix variants of one base item separate", function()
		local r = Item:Aggregate(
			{ { ID = 10132, Count = 1, Link = link("10132:0:0:0:0:0:863") } },
			{ { ID = 10132, Count = 1, Link = link("10132:0:0:0:0:0:865") } })
		assert.equal(2, countEntries(r), "two random-suffix variants were merged into one row")
	end)

	it("folds a linkless entry into an existing linked entry with the same ID", function()
		-- This is the mail path: mail items may arrive with no link and must not create a
		-- second, ghost row alongside the bank's linked entry.
		local r = Item:Aggregate(
			{ { ID = 858, Count = 5, Link = link("858") } },
			{ { ID = 858, Count = 2 } })
		assert.equal(1, countEntries(r), "a linkless entry created a duplicate row")
		assert.equal(7, totalFor(r, 858))
	end)

	it("preserves the link when folding a linkless entry in", function()
		local r = Item:Aggregate(
			{ { ID = 858, Count = 5, Link = link("858") } },
			{ { ID = 858, Count = 2 } })
		for _, v in pairs(r) do assert.is_not_nil(v.Link) end
	end)

	it("skips entries with no ID", function()
		local r = Item:Aggregate({ { Count = 5 }, { ID = 858, Count = 1, Link = link("858") } }, nil)
		assert.equal(1, countEntries(r))
	end)

	it("defaults a missing Count to 1 rather than erroring", function()
		local r = Item:Aggregate({ { ID = 858, Link = link("858") } }, nil)
		assert.equal(1, totalFor(r, 858))
	end)

	it("handles both sides being nil", function()
		assert.equal(0, countEntries(Item:Aggregate(nil, nil)))
	end)
end)

describe("Item:NeedsLink", function()
	local Item
	before_each(function()
		env.reset(); env.stubOutput(); env.loadFile("Modules/Item.lua"); Item = TOGBankClassic_Item
		TOGBankClassic_ItemDB = nil
	end)

	-- Default-deny stripping: the addon may only strip a link when it can POSITIVELY prove the
	-- item is not gear. Every uncertain case must preserve. This is what stops cold-cache
	-- windows from producing linkless gear ghosts in peers' saved data.
	it("preserves the link for a weapon (class 2)", function()
		env.defineItem(10132, { class = 2 })
		assert.is_true(Item:NeedsLink(link("10132")))
	end)

	it("preserves the link for armor (class 4)", function()
		env.defineItem(10132, { class = 4 })
		assert.is_true(Item:NeedsLink(link("10132")))
	end)

	it("allows stripping a confirmed non-gear item", function()
		env.defineItem(858, { class = 0 })
		assert.is_false(Item:NeedsLink(link("858")))
	end)

	it("preserves the link when the item class is unknown", function()
		assert.is_true(Item:NeedsLink(link("99999")),
			"an unclassifiable item was marked strippable — this is the cold-cache ghost bug")
	end)

	it("preserves when there is no link at all", function()
		assert.is_true(Item:NeedsLink(nil))
	end)

	it("preserves when no ID can be parsed from the link", function()
		assert.is_true(Item:NeedsLink("not a link"))
	end)

	it("prefers the shipped static DB over the client cache", function()
		TOGBankClassic_ItemDB = { [858] = { class = 2 } }
		env.defineItem(858, { class = 0 })   -- cache disagrees
		assert.is_true(Item:NeedsLink(link("858")))
	end)
end)

describe("Item:ItemClassNeedsLink", function()
	local Item
	before_each(function()
		env.reset(); env.stubOutput(); env.loadFile("Modules/Item.lua"); Item = TOGBankClassic_Item
		TOGBankClassic_ItemDB = nil
	end)

	it("returns true for gear", function()
		env.defineItem(10132, { class = 4 })
		assert.is_true(Item:ItemClassNeedsLink(10132))
	end)

	it("returns false for non-gear", function()
		env.defineItem(858, { class = 0 })
		assert.is_false(Item:ItemClassNeedsLink(858))
	end)

	-- nil is a distinct third answer meaning "cannot classify", and callers branch on it.
	-- Collapsing it to false would let the ghost purge delete data it cannot identify.
	it("returns nil — not false — for an unknown item", function()
		assert.is_nil(Item:ItemClassNeedsLink(99999))
	end)

	it("returns nil for a nil ID", function()
		assert.is_nil(Item:ItemClassNeedsLink(nil))
	end)
end)

describe("Item:Sort", function()
	local Item
	before_each(function()
		env.reset(); env.stubOutput(); env.loadFile("Modules/Item.lua"); Item = TOGBankClassic_Item
	end)

	local function named(...)
		local out = {}
		for _, n in ipairs({ ... }) do
			out[#out + 1] = { ID = 100 + #out, Info = { name = n, class = 0, subClass = 0, rarity = 1 } }
		end
		return out
	end

	local function names(items)
		local out = {}
		for _, i in ipairs(items) do out[#out + 1] = i.Info.name end
		return out
	end

	it("sorts alphabetically by default", function()
		local items = named("Charlie", "alpha", "Bravo")
		Item:Sort(items)
		assert.same({ "Bravo", "Charlie", "alpha" }, names(items))
	end)

	it("sorts Z-A for alpha_desc", function()
		local items = named("Alpha", "Charlie", "Bravo")
		Item:Sort(items, "alpha_desc")
		assert.same({ "Charlie", "Bravo", "Alpha" }, names(items))
	end)

	it("sorts rarity high to low, then by name", function()
		local items = {
			{ ID = 1, Info = { name = "Common",  rarity = 1, class = 0, subClass = 0 } },
			{ ID = 2, Info = { name = "Epic",    rarity = 4, class = 0, subClass = 0 } },
			{ ID = 3, Info = { name = "Rare",    rarity = 3, class = 0, subClass = 0 } },
		}
		Item:Sort(items, "rarity")
		assert.same({ "Epic", "Rare", "Common" }, names(items))
	end)

	it("sorts rarity low to high for rarity_asc", function()
		local items = {
			{ ID = 1, Info = { name = "Epic",   rarity = 4, class = 0, subClass = 0 } },
			{ ID = 2, Info = { name = "Common", rarity = 1, class = 0, subClass = 0 } },
		}
		Item:Sort(items, "rarity_asc")
		assert.same({ "Common", "Epic" }, names(items))
	end)

	it("builds a minimal Info for an item that has none", function()
		local items = { { ID = 858, Link = link("858", "Fallback Name") } }
		Item:Sort(items)
		assert.equal("Fallback Name", items[1].Info.name)
	end)

	it("does not default rarity to a number when Info exists without one", function()
		-- nil rarity is the signal DrawItem uses to trigger its async lookup; defaulting it
		-- here would permanently freeze the item at the wrong border colour.
		local items = { { ID = 858, Info = { name = "Thing" } } }
		Item:Sort(items)
		assert.is_nil(items[1].Info.rarity)
	end)
end)

-- ---------------------------------------------------------------------------
-- Audit ITEM-005
-- ---------------------------------------------------------------------------
describe("Item:GetItems", function()
	local Item
	before_each(function()
		env.reset(); env.stubOutput(); env.loadFile("Modules/Item.lua"); Item = TOGBankClassic_Item
	end)

	it("fires the callback immediately for an empty list", function()
		local got
		Item:GetItems({}, function(list) got = list end)
		assert.same({}, got)
	end)

	it("fires the callback for nil input", function()
		local got
		Item:GetItems(nil, function(list) got = list end)
		assert.same({}, got)
	end)

	it("returns linked items synchronously", function()
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		local got
		Item:GetItems({ { ID = 858, Count = 1, Link = env.items[858].link } }, function(l) got = l end)
		assert.is_not_nil(got, "callback never fired for a linked item")
		assert.equal(1, #got)
	end)

	it("returns cached linkless items synchronously", function()
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		local got
		Item:GetItems({ { ID = 858, Count = 1 } }, function(l) got = l end)
		assert.is_not_nil(got)
		assert.equal(1, #got)
	end)

	it("fires the callback once an uncached item finishes loading", function()
		local got
		Item:GetItems({ { ID = 858, Count = 1 } }, function(l) got = l end)
		assert.is_nil(got, "callback fired before the async load resolved")
		env.defineItem(858, { name = "Late Arrival", class = 0 })
		env.flushTimers()
		assert.is_not_nil(got, "callback never fired after the item loaded")
		assert.equal(1, #got)
	end)

	it("fires the callback exactly once", function()
		env.defineItem(858, { name = "Thing", class = 0 })
		local calls = 0
		Item:GetItems({ { ID = 858, Count = 1, Link = env.items[858].link } }, function() calls = calls + 1 end)
		env.flushTimers()
		assert.equal(1, calls)
	end)

	it("skips malformed entries without stalling the batch", function()
		env.defineItem(858, { name = "Good", class = 0 })
		local got
		Item:GetItems({
			{ Count = 1 },                                   -- no ID
			{ ID = "858", Count = 1 },                       -- ID is a string
			{ ID = 858, Count = 1, Link = env.items[858].link },
		}, function(l) got = l end)
		env.flushTimers()
		assert.is_not_nil(got, "callback never fired when the batch contained malformed entries")
		assert.equal(1, #got)
	end)

	-- ITEM-005. Seven failure branches increment `processed` but never decrement `pendingAsync`,
	-- so `checkComplete` can never satisfy `pendingAsync == 0` and the callback is never
	-- delivered — for the WHOLE batch, not just the offending item.
	it("still delivers the batch when CreateFromItemID returns nil for one item", function()
		env.defineItem(858, { name = "Good", class = 0 })
		local realCreate = Item and _G.Item.CreateFromItemID
		_G.Item.CreateFromItemID = function(_, id)
			if id == 99999 then return nil end
			return { itemID = id, ContinueOnItemLoad = function(_, cb) C_Timer.After(0, cb) end }
		end

		local got
		TOGBankClassic_Item:GetItems({
			{ ID = 99999, Count = 1 },                        -- forces the nil-itemData branch
			{ ID = 858,   Count = 1, Link = env.items[858].link },
		}, function(l) got = l end)
		env.flushTimers()

		_G.Item.CreateFromItemID = realCreate
		assert.is_not_nil(got,
			"the callback never fired: one item failing CreateFromItemID leaked pendingAsync " ..
			"and wedged the whole batch, so the Inventory window sits on 'Loading items…' " ..
			"forever (audit ITEM-005)")
		assert.equal(1, #got, "the healthy item should still be delivered")
	end)

	it("still delivers the batch when CreateFromItemID errors", function()
		env.defineItem(858, { name = "Good", class = 0 })
		local realCreate = _G.Item.CreateFromItemID
		_G.Item.CreateFromItemID = function(_, id)
			if id == 99999 then error("boom") end
			return { itemID = id, ContinueOnItemLoad = function(_, cb) C_Timer.After(0, cb) end }
		end

		local got
		TOGBankClassic_Item:GetItems({
			{ ID = 99999, Count = 1 },
			{ ID = 858,   Count = 1, Link = env.items[858].link },
		}, function(l) got = l end)
		env.flushTimers()

		_G.Item.CreateFromItemID = realCreate
		assert.is_not_nil(got,
			"a pcall failure in CreateFromItemID leaked pendingAsync and wedged the batch " ..
			"(audit ITEM-005)")
	end)

	it("still delivers the batch when the Item object carries a mismatched itemID", function()
		env.defineItem(858, { name = "Good", class = 0 })
		local realCreate = _G.Item.CreateFromItemID
		_G.Item.CreateFromItemID = function(_, id)
			if id == 99999 then
				return { itemID = 12345, ContinueOnItemLoad = function(_, cb) C_Timer.After(0, cb) end }
			end
			return { itemID = id, ContinueOnItemLoad = function(_, cb) C_Timer.After(0, cb) end }
		end

		local got
		TOGBankClassic_Item:GetItems({
			{ ID = 99999, Count = 1 },
			{ ID = 858,   Count = 1, Link = env.items[858].link },
		}, function(l) got = l end)
		env.flushTimers()

		_G.Item.CreateFromItemID = realCreate
		assert.is_not_nil(got,
			"an itemID mismatch leaked pendingAsync and wedged the batch (audit ITEM-005)")
	end)
end)

describe("Item:IsUnique", function()
	local Item
	before_each(function()
		env.reset(); env.stubOutput(); env.loadFile("Modules/Item.lua"); Item = TOGBankClassic_Item
	end)

	it("returns false for a nil link", function()
		assert.is_false(Item:IsUnique(nil))
	end)

	-- ITEM-006. WoW frames cannot be destroyed, so creating one per call leaks permanently and
	-- clobbers the global name each time.
	it("does not create a new scanning tooltip on every call", function()
		local created = 0
		local realCreateFrame = _G.CreateFrame
		_G.CreateFrame = function(...) created = created + 1; return realCreateFrame(...) end
		Item:IsUnique("|cffffffff|Hitem:858|h[A]|h|r")
		Item:IsUnique("|cffffffff|Hitem:859|h[B]|h|r")
		Item:IsUnique("|cffffffff|Hitem:860|h[C]|h|r")
		_G.CreateFrame = realCreateFrame
		assert.truthy(created <= 1,
			"IsUnique created " .. created .. " tooltip frames for 3 calls; WoW frames are " ..
			"never garbage-collected, so this leaks one frame per call (audit ITEM-006)")
	end)
end)
