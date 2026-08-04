-- Switches — the V2 dev-switch registry.
--
-- These gate a storage-format migration, so the failure that matters is a switch reporting a
-- state it is not actually in: `dualWrite` claiming to be on while V2 is off would mean the
-- legacy DB is silently going stale behind a diagnostic that says it is being maintained.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Switches

--- Switches read and write db.global, so a minimal AceDB stand-in is enough. `withoutDB`
--- exercises the pre-Init window, when a switch can be queried before the DB exists.
local function loadSwitches(withoutDB)
	env.stubOutput()
	env.loadFile("Modules/Switches.lua")
	Switches = TOGBankClassic_Switches
	if withoutDB then
		TOGBankClassic_Database = nil
	else
		TOGBankClassic_Database = { db = { global = {} } }
	end
	return Switches
end

describe("Switches registry", function()
	before_each(function() env.reset(); loadSwitches() end)

	it("declares the three V2 switches", function()
		for _, name in ipairs({ "inventoryV2", "sendV2Wire", "dualWrite" }) do
			assert.is_table(Switches.registry[name], name .. " is not registered")
		end
	end)

	-- A switch that outlives its rework is a bug, not a feature. FEATURES.FORCE_DELTA_SYNC and
	-- friends are still in Constants.lua from a previous round of exactly this exercise, which
	-- is what `retire` exists to prevent repeating.
	it("gives every switch a description and a retirement condition", function()
		for name, entry in pairs(Switches.registry) do
			assert.is_string(entry.description, name .. " has no description")
			assert.is_string(entry.retire, name .. " has no retire note")
		end
	end)

	it("defaults V2 and the wire format off", function()
		assert.is_false(Switches:IsEnabled("inventoryV2"))
		assert.is_false(Switches:IsEnabled("sendV2Wire"))
	end)
end)

describe("Switches state", function()
	before_each(function() env.reset(); loadSwitches() end)

	it("turns a switch on and off", function()
		assert.is_true(Switches:Set("inventoryV2", true))
		assert.is_true(Switches:IsEnabled("inventoryV2"))
		Switches:Set("inventoryV2", false)
		assert.is_false(Switches:IsEnabled("inventoryV2"))
	end)

	it("persists through db.global so it survives a reload", function()
		Switches:Set("inventoryV2", true)
		assert.is_true(TOGBankClassic_Database.db.global.switches.inventoryV2)
	end)

	-- A typo at the slash command must be reported, not silently create a switch nothing reads.
	it("refuses an unknown switch name", function()
		assert.is_false(Switches:Set("noSuchSwitch", true))
	end)

	it("reports an unknown switch as off rather than erroring", function()
		assert.is_false(Switches:IsEnabled("noSuchSwitch"))
	end)

	-- A switch may be queried before Database:Init has run.
	it("falls back to defaults with no database", function()
		env.reset(); loadSwitches(true)
		assert.is_false(Switches:IsEnabled("inventoryV2"))
		assert.is_false(Switches:Set("inventoryV2", true))
	end)
end)

describe("Switches dependencies", function()
	before_each(function() env.reset(); loadSwitches() end)

	-- The one that matters: dualWrite keeps the legacy DB current so a rollback lands on live
	-- data. Reporting it as on while V2 is off would describe maintenance that is not happening.
	it("reports dualWrite off while inventoryV2 is off, despite its own default", function()
		assert.is_true(Switches.registry.dualWrite.default, "precondition: dualWrite defaults on")
		assert.is_false(Switches:IsEnabled("inventoryV2"))
		assert.is_false(Switches:IsEnabled("dualWrite"),
			"dualWrite claimed to be active while V2 is off")
	end)

	it("reports dualWrite on once inventoryV2 is on", function()
		Switches:Set("inventoryV2", true)
		assert.is_true(Switches:IsEnabled("dualWrite"))
	end)

	it("still honours an explicit off for a dependent switch", function()
		Switches:Set("inventoryV2", true)
		Switches:Set("dualWrite", false)
		assert.is_false(Switches:IsEnabled("dualWrite"))
	end)
end)

describe("Switches:GetAll", function()
	before_each(function() env.reset(); loadSwitches() end)

	it("returns every switch, sorted by name", function()
		local all = Switches:GetAll()
		assert.equal(3, #all)
		assert.equal("dualWrite", all[1].name)
		assert.equal("inventoryV2", all[2].name)
		assert.equal("sendV2Wire", all[3].name)
	end)

	it("reports live state, not the stored value", function()
		local function find(list, name)
			for _, e in ipairs(list) do if e.name == name then return e end end
		end
		-- dualWrite defaults on but is inert while V2 is off.
		assert.is_false(find(Switches:GetAll(), "dualWrite").enabled)
		Switches:Set("inventoryV2", true)
		assert.is_true(find(Switches:GetAll(), "dualWrite").enabled)
	end)

	-- Distinguishes "the user set this" from "this is inherited", which is the first question
	-- when diagnosing a report.
	it("flags whether a switch was explicitly overridden", function()
		local function find(list, name)
			for _, e in ipairs(list) do if e.name == name then return e end end
		end
		assert.is_false(find(Switches:GetAll(), "sendV2Wire").overridden)
		Switches:Set("sendV2Wire", false)   -- same as the default, but explicitly set
		assert.is_true(find(Switches:GetAll(), "sendV2Wire").overridden)
	end)

	it("carries the description, default and retirement note through", function()
		local e = Switches:GetAll()[2]   -- inventoryV2
		assert.is_string(e.description)
		assert.is_string(e.retire)
		assert.is_false(e.default)
	end)
end)
