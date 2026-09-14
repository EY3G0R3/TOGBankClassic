-- INV2-COMPAT-001 -- `TOGBankClassic_Guild.Info.alts[name].items` keeps answering for OTHER ADDONS.
--
-- The operator, 2026-09-11, after INV2-RETIRE-003 stripped the legacy rows: "we can't break the bank
-- integration, why did you break it?" TOGProfessionMaster reads the alt records directly, and this
-- file drives ITS read pattern -- the two functions below are copied verbatim from
-- TOGProfessionMaster/Compat.lua (`addon.Bank.GetStock`, `addon.Bank.GetBanksWithItem`) so the
-- contract is the consumer's own code, not a paraphrase of it. If TPM changes how it reads, this copy
-- must follow; if TOGBank changes what `.items` answers, this is what turns red.
--
-- The mechanism is a metatable per record whose `__index` answers `items` from the store, plus a
-- `__newindex` on the alts table so records created later are wrapped. Neither reaches the
-- SavedVariables: the client serializes raw contents only, which the last describe pins.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local GUILD = "Testguild"
local BANKER, OTHER = "Bankchar-Testrealm", "Otherbanker-Testrealm"

-- ---- copied from TOGProfessionMaster/Compat.lua (v1.0.7+), unchanged --------------------------
local TPM = {}
function TPM.GetStock(itemId)
	local TOG = _G["TOGBankClassic_Guild"]
	if not TOG or not TOG.Info or not TOG.Info.alts then return 0 end
	local total = 0
	for _, alt in pairs(TOG.Info.alts) do
		for _, entry in ipairs(alt.items or {}) do
			if entry.ID == itemId then
				total = total + (entry.Count or 0)
			end
		end
	end
	return total
end
function TPM.GetBanksWithItem(itemId)
	local TOG = _G["TOGBankClassic_Guild"]
	if not TOG then return {} end
	local banks = TOG:GetBanks()
	if not banks or #banks == 0 then return {} end
	local alts   = TOG.Info and TOG.Info.alts or {}
	local result = {}
	for _, bankName in ipairs(banks) do
		local alt = alts[bankName]
		if alt and alt.items then
			local total = 0
			for _, entry in ipairs(alt.items) do
				if entry.ID == itemId then
					total = total + (entry.Count or 0)
				end
			end
			if total > 0 then
				table.insert(result, { name = bankName, count = total })
			end
		end
	end
	table.sort(result, function(a, b) return a.name < b.name end)
	return result
end
-- ------------------------------------------------------------------------------------------------

local DB, Store

local function load()
	env.reset(); env.stubOutput()
	env.loadModules({
		"Modules/Constants.lua",
		"Modules/Switches.lua",
		"Modules/Item.lua",
		"Modules/Inventory/Record.lua",
		"Modules/Inventory/Resolve.lua",
		"Modules/Inventory/Store.lua",
		"Modules/Database.lua",
		"Modules/Guild.lua",
	})
	DB, Store = TOGBankClassic_Database, TOGBankClassic_Inventory_Store
	DB.db = { global = {}, faction = {} }
	TOGBankClassic_Core = env.coreHashStub(4242)
	Store:Init({ faction = {} })
	env.defineItem(858,  { name = "Minor Healing Potion" })
	env.defineItem(2589, { name = "Copper Bar" })
	TOGBankClassic_Guild.GetBanks = function() return { BANKER, OTHER } end
end

--- A SavedVariables file as a v1.4.x client left it: legacy rows on the record.
local function legacyFile()
	DB.db.faction[GUILD] = { name = GUILD, alts = {
		[BANKER] = { name = BANKER, version = 7, money = 0, items = { { ID = 858, Count = 999 } } },
		[OTHER]  = { name = OTHER,  version = 7, money = 0, items = { { ID = 858, Count = 999 } } },
	} }
end

describe("INV2-COMPAT-001: TOGProfessionMaster's read of Info.alts[name].items", function()
	before_each(function()
		load()
		legacyFile()
		TOGBankClassic_Guild.Info = DB:Load(GUILD)
	end)

	-- PRESENCE, not only the answer. Peer Review (2026-09-11): AttachAltCompat leaves a record that
	-- already carries a metatable alone, so an AceDB `faction` default added later would attach
	-- AceDB's metatable first, the shim would wrap nothing, and every example that only reads
	-- `alt.items` would still pass on the store's empty view -- with TPM's [Bank] button empty. This
	-- is the example that goes red on that day.
	it("wraps EVERY loaded record -- the wrapper is present, not merely answering", function()
		for name, alt in pairs(TOGBankClassic_Guild.Info.alts) do
			assert.is_true(DB:HasAltCompat(alt), name .. " carries no compat wrapper after Load -- " ..
				"another metatable (AceDB defaults?) got there first and the shim silently declined")
		end
	end)

	it("answers from the V2 store after the legacy rows are stripped", function()
		Store:SetAltRecords(GUILD, BANKER, { { 858, 20 }, { 858, 5 }, { 2589, 3 } }, 0)
		Store:SetAltRecords(GUILD, OTHER,  { { 858, 7 } }, 0)
		assert.equal(32, TPM.GetStock(858), "TPM's [Bank] stock is not the store's total -- the integration is broken")
		assert.equal(3,  TPM.GetStock(2589))
		assert.same({ { name = BANKER, count = 25 }, { name = OTHER, count = 7 } }, TPM.GetBanksWithItem(858))
		assert.same({ { name = BANKER, count = 3 } }, TPM.GetBanksWithItem(2589))
	end)

	it("never answers the 999s the legacy rows held -- those were stripped, and were stale anyway", function()
		Store:SetAltRecords(GUILD, BANKER, { { 858, 20 } }, 0)
		assert.equal(20, TPM.GetStock(858))
	end)

	it("is LIVE: a later store write changes what TPM reads, with no reload", function()
		Store:SetAltRecords(GUILD, BANKER, { { 858, 20 } }, 0)
		assert.equal(20, TPM.GetStock(858))
		Store:SetAltRecords(GUILD, BANKER, { { 858, 50 } }, 0)
		assert.equal(50, TPM.GetStock(858),
			"TPM read a cached array after the store moved on -- on v1.4.x this is exactly how " ..
			"received bankers went stale")
	end)

	it("answers an empty array, never nil, for a banker the store has not seen", function()
		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		assert.is_table(alt.items)
		assert.equal(0, #alt.items)
		assert.equal(0, TPM.GetStock(858))
	end)

	it("wraps a record created AFTER load at a new key, as Bank:Scan and the receive stubs do", function()
		TOGBankClassic_Guild.Info.alts["Newbank-Testrealm"] = { name = "Newbank-Testrealm", money = 0 }
		Store:SetAltRecords(GUILD, "Newbank-Testrealm", { { 2589, 11 } }, 0)
		assert.is_true(DB:HasAltCompat(TOGBankClassic_Guild.Info.alts["Newbank-Testrealm"]))
		assert.equal(11, TOGBankClassic_Guild.Info.alts["Newbank-Testrealm"].items[1].Count)
	end)

	it("wraps the record ResetPlayer replaces at an existing key", function()
		Store:SetAltRecords(GUILD, BANKER, { { 858, 20 } }, 0)
		DB:ResetPlayer(GUILD, BANKER)
		assert.is_true(DB:HasAltCompat(TOGBankClassic_Guild.Info.alts[BANKER]))
		assert.equal(20, TOGBankClassic_Guild.Info.alts[BANKER].items[1].Count,
			"ResetPlayer replaced the record with a plain table; __newindex does not fire for an " ..
			"existing key, so it has to wrap by hand")
	end)

	it("answers only `items`; any other missing field is still nil", function()
		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		assert.is_nil(alt.nosuchfield)
		assert.is_nil(alt.bank)
	end)

	it("reads the same rows every TOGBank window reads (Guild:GetAltItems)", function()
		Store:SetAltRecords(GUILD, BANKER, { { 858, 20 }, { 2589, 3 } }, 0)
		assert.equal(TOGBankClassic_Guild:GetAltItems(BANKER), TOGBankClassic_Guild.Info.alts[BANKER].items,
			"two arrays for one banker: the compat shim built its own view instead of the accessor's")
	end)
end)

describe("INV2-COMPAT-001: the shim reaches neither the SavedVariables nor the strip", function()
	before_each(function()
		load()
		legacyFile()
		TOGBankClassic_Guild.Info = DB:Load(GUILD)
		Store:SetAltRecords(GUILD, BANKER, { { 858, 20 } }, 0)
	end)

	-- The client writes a SavedVariables table by walking its raw contents (`next`), which is the
	-- property AceDB's own defaults depend on. So `pairs` over the record is the serializer's view.
	it("a raw walk of the record -- what the client serializes -- never yields items", function()
		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		assert.equal(20, alt.items[1].Count, "precondition: the shim answers")
		for key in pairs(alt) do
			assert.is_not.equal("items", key, "items is a RAW field again -- it will be written to the SV")
		end
		assert.is_nil(rawget(alt, "items"))
	end)

	it("a raw walk of the alts table yields exactly the records, no shim state", function()
		local names = {}
		for name in pairs(TOGBankClassic_Guild.Info.alts) do names[#names + 1] = name end
		table.sort(names)
		assert.same({ BANKER, OTHER }, names)
	end)

	it("is not counted or 'stripped' by a second strip pass", function()
		assert.equal(0, DB:StripLegacyItemRows(DB.db.faction[GUILD]),
			"the strip saw the shim's answer as rows -- it must read through rawget")
		assert.equal(20, TOGBankClassic_Guild.Info.alts[BANKER].items[1].Count, "the strip removed the shim")
	end)

	it("is idempotent: attaching twice changes nothing", function()
		local alts = TOGBankClassic_Guild.Info.alts
		local mt = getmetatable(alts)
		DB:AttachAltsCompat(alts)
		assert.equal(mt, getmetatable(alts))
		assert.equal(20, alts[BANKER].items[1].Count)
	end)

	it("leaves a record that already carries a metatable of its own alone", function()
		local own = setmetatable({ name = "Odd-Testrealm" }, { __index = function() return "theirs" end })
		TOGBankClassic_Guild.Info.alts["Odd-Testrealm"] = own
		assert.equal("theirs", own.items)
		assert.is_false(DB:HasAltCompat(own), "HasAltCompat must report the OTHER metatable as not ours")
	end)
end)
