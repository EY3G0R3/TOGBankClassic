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

	-- INV2 step 9: BOTH now default ON, and this is a deliberate re-baseline rather than a spec bent
	-- to fit the code. The legacy link wire format is deleted in both directions (the 2026-09-09
	-- directive), so with these off the addon has no send path and no receive path -- "off" is no
	-- longer a rollback to the old behaviour, because the old behaviour no longer exists.
	it("defaults V2 and the wire format ON, because there is no longer anything else", function()
		assert.is_true(Switches:IsEnabled("inventoryV2"))
		assert.is_true(Switches:IsEnabled("sendV2Wire"))
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
		-- The assertion is "it reports the DEFAULT", not "it reports false". The default moved.
		assert.is_true(Switches:IsEnabled("inventoryV2"))
		assert.is_false(Switches:Set("inventoryV2", true))
	end)
end)

describe("Switches dependencies", function()
	before_each(function() env.reset(); loadSwitches() end)

	-- The one that matters: dualWrite keeps the legacy DB current so a rollback lands on live
	-- data. Reporting it as on while V2 is off would describe maintenance that is not happening.
	-- inventoryV2 is turned off EXPLICITLY rather than relied on being off by default. The rule under
	-- test is the dependency rule, which has nothing to do with what the parent happens to default
	-- to -- and this example broke when that default moved, which is the tell that it was testing
	-- the default by accident.
	it("reports dualWrite off while inventoryV2 is off, despite its own default", function()
		assert.is_true(Switches.registry.dualWrite.default, "precondition: dualWrite defaults on")
		Switches:Set("inventoryV2", false)
		assert.is_false(Switches:IsEnabled("inventoryV2"), "precondition: V2 is off for this example")
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
		-- dualWrite defaults on but is inert while V2 is off. V2 is turned off explicitly, for the
		-- same reason as the dependency example above: the rule is the subject, not the default.
		Switches:Set("inventoryV2", false)
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
		assert.is_true(e.default)   -- INV2 step 9: defaults on

	end)

	-- `pending` has no user today and that is the correct state: every registered switch is wired
	-- to something. It is carried through GetAll so the escape hatch the wiring guard below offers
	-- actually reaches the listing the moment a switch is staged ahead of its code.
	it("carries the pending marker through, so the listing can show it", function()
		local function find(list, name)
			for _, e in ipairs(list) do if e.name == name then return e end end
		end
		assert.is_nil(find(Switches:GetAll(), "dualWrite").pending)
		Switches.registry.dualWrite.pending = "staged"
		assert.equal("staged", find(Switches:GetAll(), "dualWrite").pending)
		Switches.registry.dualWrite.pending = nil
	end)
end)

-- A SWITCH NOTHING READS IS A SWITCH THAT LIES, and this file's own header says so: the failure
-- that matters is "a switch reporting a state it is not actually in". Every test above asks whether
-- the registry is self-consistent; none of them can tell whether the switch is WIRED TO ANYTHING.
--
-- It was not caught by review. `dualWrite`'s only reader was `Scan:ScanAll`, and INV2-VAULT-001
-- replaced the one `ScanAll` call with per-source `ScanBags`/`ScanBank` calls -- orphaning the
-- function and, with it, the last read of the switch. The listing went on reporting `ON dualWrite`
-- with a description promising it was keeping the legacy DB current.
--
-- Swept from the .toc rather than a hand-written file list, for the reason timers_spec gives: a
-- module missing from the .toc does not load in game, so the .toc is the one list that cannot
-- silently omit a file. A hand-kept list is the defect it is meant to catch.
describe("Switches are wired to something", function()
	before_each(function() env.reset(); loadSwitches() end)

	--- Every .lua the addon actually ships, read from TOGBankClassic.toc.
	local function shippedSources()
		local out = {}
		local toc = io.open("TOGBankClassic.toc", "r")
		assert.is_not_nil(toc, "TOGBankClassic.toc could not be opened")
		for line in toc:lines() do
			local path = line:match("^%s*([%w_/\\%-%.]+%.lua)%s*$")
			if path then out[#out + 1] = (path:gsub("\\", "/")) end
		end
		toc:close()
		-- If the parse silently returned nothing, every assertion below would pass without reading
		-- a line -- the exact shape of a guard that cannot fail.
		assert.is_true(#out > 10,
			"parsed " .. #out .. " Lua files from the .toc; the parse is broken, not the addon")
		return out
	end

	-- Matches the CALL, not the name. A bare substring search reports `dualWrite` as read because
	-- Bank.lua:292 mentions it in a comment explaining what it will do at step 10 -- prose about a
	-- switch is the opposite of a reader, and counting it would have hidden exactly the defect this
	-- guard exists to find. `IsEnabled("<name>")` is the only way a switch is consulted; `Set` is
	-- driven from the slash command through a variable, so it never appears as a literal.
	local function readsSwitch(src, name)
		return src:find('IsEnabled%s*%(%s*["\']' .. name .. '["\']') ~= nil
	end

	it("reads every non-pending switch somewhere in the shipped source", function()
		local sources = shippedSources()
		for name, entry in pairs(Switches.registry) do
			local found = nil
			for _, path in ipairs(sources) do
				-- Switches.lua declares them; a declaration is not a reader.
				if not path:find("Switches%.lua$") then
					local fh = io.open(path, "r")
					if fh then
						local src = fh:read("*a")
						fh:close()
						if readsSwitch(src, name) then found = path break end
					end
				end
			end
			if entry.pending then
				assert.is_nil(found, string.format(
					"%s is marked pending but IS read at %s -- drop the pending marker, it now " ..
					"understates what the switch does", name, tostring(found)))
			else
				assert.is_not_nil(found, string.format(
					"nothing in the shipped source reads '%s', yet it has no `pending` marker. " ..
					"The dev-switch listing therefore promises an effect no code delivers -- " ..
					"either wire it up, or declare `pending` so the listing says NOT YET ACTIVE",
					name))
			end
		end
	end)
end)
