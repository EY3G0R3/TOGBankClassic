-- Item.lua — what is left of the item-identity layer after LINK-AUDIT-001: the request's display
-- name, the sort comparators and the scanning tooltip.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

-- writ-cannot: the "Item:GetItemString" (3), "Item:GetItemKey" (4), "Item:Aggregate" (8) and
-- "Item:GetItems" (11) blocks were DELETED with their functions (LINK-AUDIT-001 step 6,
-- docs/LINK_AUDIT.md 3.2, 3.5, 3.6). GetItemString and GetItemKey were link parsers whose only
-- caller was the mail scanner, which now parses at the edge with Scan.parseLink; Aggregate was a
-- link-keyed merge whose only caller was Search, which now walks Store's view rows (already one per
-- Record.key); GetItems was the 280-line async loader for a cold item cache, whose last producer of
-- rows without `Info` (the Mail window) now builds view rows through Resolve. The identity those
-- blocks pinned -- suffix siblings distinct, enchant distinct, instance id ignored, one row per
-- item -- is pinned on Record.key / Record.aggregate in record_spec and scan_spec, and mail's merge
-- of linked and linkless rows (MAIL-015) in logwho_spec's inbox-scan examples on the records the
-- scanner now returns. Keeping specs for deleted functions invites their return.
--
-- writ-cannot: the "Item:GetSuffixID" block (five examples) was DELETED with the function
-- (LINK-AUDIT-001 step 4, docs/LINK_AUDIT.md 3.2). It was the SECOND parser of the item string's
-- seventh field, with its own pattern; every live-link caller now reads `Scan.parseLink`, whose
-- field-7 behaviour -- signed, empty and 0 equivalent, nil link -> 0 -- is pinned in scan_spec.

describe("LINK-AUDIT-001 step 6: the link-era identity functions stay gone", function()
	it("Item.lua defines no parser, aggregator, loader or second Info builder", function()
		env.reset(); env.stubOutput(); env.loadFile("Modules/Item.lua")
		for _, name in ipairs({ "GetItemString", "GetItemKey", "GetSuffixID", "Aggregate", "GetItems", "GetInfo" }) do
			assert.is_nil(TOGBankClassic_Item[name], "Item:" .. name .. " is back")
		end
		-- And nothing in the shipped modules calls them.
		for _, path in ipairs({ "Modules/Bank.lua", "Modules/Mail.lua", "Modules/MailInventory.lua", "Modules/Log.lua",
			"Modules/UI.lua", "Modules/UI/Search.lua", "Modules/UI/Inventory.lua", "Modules/UI/Mail.lua", "Modules/UI/Requests.lua" }) do
			for lineNo, line in env.codeLines(env.readFile(path)) do
				assert.is_nil(line:match("TOGBankClassic_Item:Get(Item%a+)%(") or line:match("TOGBankClassic_Item:Aggregate%(") or line:match("TOGBankClassic_Item:GetInfo%("),
					("%s:%d calls a deleted Item function: %s"):format(path, lineNo, line))
			end
		end
	end)
end)

-- writ-cannot: Item:NeedsLink was DELETED on purpose (INV2 step 10, the standing operator directive
-- "V2 sends tuples only -- DELETE the link-stripping machinery, do not branch around it"). These
-- seven examples pinned the default-deny rule for a decision the addon no longer makes: whether a
-- link was safe to strip before sending. Nothing strips links now -- V2 sends {id,count,suffix,
-- enchant} and the receiver rebuilds the link from LibItemDB -- so the function has no caller and no
-- meaning. Keeping specs for a deleted function either breaks the run or invites someone to
-- reinstate the function to satisfy them, which is the corruption this directive removes.
--
-- The behaviour is NOT now unguarded, which is why this is a deletion and not a coverage loss:
-- syncwire_spec asserts a serialised V2 payload contains NO link markup and NO item-string at all,
-- which fails if stripping (or any link on the wire) ever returns.
--
-- writ-cannot: `Item:ItemClassNeedsLink` and `Item:GetClass` were DELETED on purpose too
-- (LINK-AUDIT-001 step 1, docs/LINK_AUDIT.md 3.1): their last caller,
-- `Database:PurgeLinklessGearGhosts`, went in INV2-RETIRE-003, and GetClass was the only reader of
-- the 3.7 MB static item database every client parsed at login. Four examples pinned a
-- classification nothing asks for; the example below pins that the dead weight stays gone.

describe("LINK-AUDIT-001 step 1: the static item databases are gone", function()
	it("neither TOC loads Modules/Static, and loading Item.lua defines no classifier", function()
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_TBC.toc", "TOGBankClassic_Mists.toc", "TOGBankClassic_Camelot.toc" }) do
			local text = env.readFile(toc)
			assert.truthy(text:find("## Interface:", 1, true), toc .. " could not be read (readFile answers \"\" for a missing file)")
			assert.is_nil(text:find("Modules/Static/", 1, true), toc .. " still loads a static item database")
		end
		env.reset(); env.stubOutput(); env.loadFile("Modules/Item.lua")
		-- Enumerated rather than named: ItemClassNeedsLink / GetClass under any spelling is a classifier.
		local classifiers = {}
		for k in pairs(TOGBankClassic_Item) do
			if type(k) == "string" and k:find("Class", 1, true) then classifiers[#classifiers + 1] = k end
		end
		assert.same({}, classifiers, "Item.lua defines an item classifier again")
		assert.is_nil(env.readFile("Modules/Item.lua"):find("TOGBankClassic_ItemDB", 1, true), "Item.lua reads the static database again")
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

	-- writ-cannot: "builds a minimal Info for an item that has none" and "does not default rarity to
	-- a number when Info exists without one" were DELETED with Sort's pre-pass (LINK-AUDIT-001 step
	-- 6, docs/LINK_AUDIT.md 3.5): every row sorted is a Store.viewRow whose Info Resolve filled, so
	-- there is no Info to fabricate from a link's brackets and no reqLevel to re-ask the client for.
end)

describe("Item:IsUnique", function()
	local Item
	-- The harness's scanning GameTooltip (pin 830dab2, env.frames): SetHyperlink fills
	-- `<name>TextLeft<n>` from the item's `tooltipLines`, which is the direction IsUnique reads.
	-- Until then this addon's env stubbed the fill and no example ever saw a "Unique" line.
	before_each(function()
		env.reset(); env.stubOutput()
		require("env.frames").reset()
		env.loadFile("Modules/Item.lua"); Item = TOGBankClassic_Item
		env.defineItem(858, { name = "Lesser Healing Potion" })
		env.defineItem(6948, { name = "Hearthstone", tooltipLines = { "Hearthstone", ITEM_UNIQUE, "Binds when picked up" } })
		-- UNIQUE-EQUIPPED-001: the two other lines the client prints. The harness's global-string
		-- set carries ITEM_UNIQUE alone; the sibling strings are enUS.lua:12179-12180. Set here and
		-- cleared after each example (the harness's reset does not own them), so the non-English
		-- values one example installs cannot reach the next.
		_G.ITEM_UNIQUE_EQUIPPABLE = "Unique-Equipped"
		_G.ITEM_UNIQUE_MULTIPLE   = "Unique (%d)"
		env.defineItem(19019, { name = "Thunderfury", tooltipLines = { "Thunderfury", _G.ITEM_UNIQUE_EQUIPPABLE, "Binds when picked up" } })
		env.defineItem(4306,  { name = "Silk Cloth",  tooltipLines = { "Silk Cloth", _G.ITEM_UNIQUE_MULTIPLE:format(20) } })
	end)
	after_each(function() _G.ITEM_UNIQUE_EQUIPPABLE, _G.ITEM_UNIQUE_MULTIPLE = nil, nil end)

	-- UNIQUE-EQUIPPED-001 (the operator, 2026-09-15: "the unique items need to be counted in the mail,
	-- but only those"): a Unique-EQUIPPED item limits what you wear, not what a bank can hold, so it
	-- is an ordinary item here -- taken, collected, credited. Only "Unique" and "Unique (n)" count.
	it("counts a Unique and a Unique (n) line, and NOT Unique-Equipped, which a bank can hold several of", function()
		assert.is_true(Item:IsUnique("|cffffffff|Hitem:6948|h[Hearthstone]|h|r"))
		assert.is_true(Item:IsUnique("|cffffffff|Hitem:4306|h[Silk Cloth]|h|r"), "'Unique (20)' was not read as unique")
		assert.is_false(Item:IsUnique("|cffffffff|Hitem:19019|h[Thunderfury]|h|r"), "a Unique-Equipped item was read as unique -- it can be held in numbers")
		-- A non-English client whose Unique-Equipped wording CONTAINS its Unique word (enUS does;
		-- the match is the whole line, so it still does not count).
		env.wow.setGlobalStrings({ ITEM_UNIQUE = "Unico", ITEM_UNIQUE_MULTIPLE = "Unico (%d)" })
		env.defineItem(19020, { name = "A", tooltipLines = { "A", "Unico-Equipaggiato" } })
		env.defineItem(19021, { name = "B", tooltipLines = { "B", "Unico (3)" } })
		env.defineItem(19022, { name = "C", tooltipLines = { "C", "Unico" } })
		assert.is_false(Item:IsUnique("|cffffffff|Hitem:19020|h[A]|h|r"))
		assert.is_true(Item:IsUnique("|cffffffff|Hitem:19021|h[B]|h|r"))
		assert.is_true(Item:IsUnique("|cffffffff|Hitem:19022|h[C]|h|r"))
	end)

	it("returns false for a nil link", function()
		assert.is_false(Item:IsUnique(nil))
	end)

	it("reads the client's tooltip: a Unique line is unique, an item without one is not, an unknown link is not", function()
		assert.is_true(Item:IsUnique("|cffffffff|Hitem:6948|h[Hearthstone]|h|r"))
		assert.is_false(Item:IsUnique("|cffffffff|Hitem:858|h[Lesser Healing Potion]|h|r"))
		assert.is_false(Item:IsUnique("|cffffffff|Hitem:999999|h[Nothing]|h|r"), "an uncached link read as unique")
		-- A non-English client: the scan matches whatever ITEM_UNIQUE says, not the English word.
		env.wow.setGlobalStrings({ ITEM_UNIQUE = "Unique*" })
		assert.is_false(Item:IsUnique("|cffffffff|Hitem:6948|h[Hearthstone]|h|r"), "matched the English word, not ITEM_UNIQUE")
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
