-- The Search window's corpus and lookup -- LINK-AUDIT-001 step 6 (docs/LINK_AUDIT.md 3.6).
--
-- BuildSearchData walks the view rows Guild:GetAltItems hands back (Store.viewRow: one row per
-- identity per alt, `Info` filled by Resolve, mail included) and keys the corpus by each row's OWN
-- name. It used to key by id, so the first random-suffix variant seen named every variant --
-- "Dreadblade of the Tiger" was filed under "Dreadblade of the Bear" and could not be found by its
-- own name -- and it went through Item:Aggregate (a link-keyed merge) and Item:GetItems (the async
-- loader), both deleted with this.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Search

local ALICE, BOB = "Alice-Testrealm", "Bob-Testrealm"

local function row(id, count, suffix, enchant, name)
	return {
		ID = id, Count = count, Suffix = suffix or 0, Enchant = enchant or 0,
		Link = ("|cff1eff00|Hitem:%d:%d:::::%d|h[%s]|h|r"):format(id, enchant or 0, suffix or 0, name),
		Info = { name = name, icon = 1, rarity = 2, class = 2, subClass = 4, reqLevel = 20, equipId = 13 },
	}
end

local function load(rowsByAlt)
	env.reset()
	require("env.frames").reset()
	env.stubOutput()
	env.loadFile("Modules/Constants.lua")
	env.loadFile("Modules/Item.lua")
	env.loadUI()
	env.loadFile("Modules/UI/Search.lua")
	Search = TOGBankClassic_UI_Search
	TOGBankClassic_Guild = {
		Info = { name = "Testguild", alts = { [ALICE] = {}, [BOB] = {} } },
		GetRosterAlts = function() return { ALICE, BOB } end,
		NormalizeName = function(_, n) return n end,
		GetAltItems = function(_, alt) return rowsByAlt[alt] or {} end,
	}
end

describe("SEARCH: the corpus is keyed by each row's own name, and the lookup by name and variant", function()
	after_each(function() TOGBankClassic_UI_Search = nil end)

	it("lists two suffix variants of one base item as two names, each finding its own rows", function()
		load({
			[ALICE] = { row(17240, 1, 1196, 0, "Dreadblade of the Bear"), row(17240, 1, 1195, 0, "Dreadblade of the Tiger"), row(2589, 20, 0, 0, "Linen Cloth") },
			[BOB]   = { row(17240, 2, 1195, 0, "Dreadblade of the Tiger") },
		})
		Search:BuildSearchData()
		local corpus = {}
		for _, n in ipairs(Search.SearchData.Corpus) do corpus[n] = true end
		assert.same({ ["Dreadblade of the Bear"] = true, ["Dreadblade of the Tiger"] = true, ["Linen Cloth"] = true }, corpus,
			"a variant was filed under another variant's name")
		local tiger = Search.SearchData.Lookup["Dreadblade of the Tiger"]
		assert.equal(2, #tiger, "the Tiger's rows are not one per alt")
		local byAlt = {}
		for _, e in ipairs(tiger) do byAlt[e.alt] = e.item end
		assert.equal(1195, byAlt[ALICE].Suffix); assert.equal(1, byAlt[ALICE].Count)
		assert.equal(1195, byAlt[BOB].Suffix); assert.equal(2, byAlt[BOB].Count)
		assert.equal("Dreadblade of the Tiger", byAlt[BOB].Info.name, "the lookup row lost the view row's Info")
		assert.equal(1, #Search.SearchData.Lookup["Dreadblade of the Bear"])
		assert.equal(1196, Search.SearchData.Lookup["Dreadblade of the Bear"][1].item.Suffix)
	end)

	it("sums an enchant sibling into the same alt's variant row, and skips a row with no name", function()
		load({
			[ALICE] = { row(17240, 1, 1196, 0, "Dreadblade of the Bear"), row(17240, 1, 1196, 2504, "Dreadblade of the Bear"),
				{ ID = 999, Count = 1, Suffix = 0, Enchant = 0, Info = {} } },
		})
		Search:BuildSearchData()
		assert.equal(1, #Search.SearchData.Corpus)
		local bear = Search.SearchData.Lookup["Dreadblade of the Bear"]
		assert.equal(1, #bear, "an enchant sibling made a second row for the same variant")
		assert.equal(2, bear[1].item.Count)
	end)

	it("builds nothing without a roster, and the deleted loader is never asked", function()
		load({})
		TOGBankClassic_Item.GetItems = function() error("Search handed its rows to the async loader again") end
		TOGBankClassic_Item.Aggregate = function() error("Search re-aggregated rows the store already aggregated") end
		Search:BuildSearchData()
		assert.same({}, Search.SearchData.Corpus)
		TOGBankClassic_Guild.GetRosterAlts = function() return nil end
		Search:BuildSearchData()
		assert.same({}, Search.SearchData.Corpus)
		TOGBankClassic_Item.GetItems, TOGBankClassic_Item.Aggregate = nil, nil
	end)
end)
