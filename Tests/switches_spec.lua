-- Switches — the V2 dev-switch registry.
--
-- These gate diagnostics on a storage-format migration, so the failure that matters is a switch
-- reporting a state it is not actually in: a dependent switch claiming to be on while its parent
-- is off would describe an effect that is not happening.
--
-- INV2-RETIRE-003 (2026-09-11): `inventoryV2` and `dualWrite` are RETIRED -- the V2 store is the
-- only storage format, the legacy rows are neither written nor kept, and the accessors have no
-- fallback. Every example below that named them is re-pinned on the switches that remain
-- (`sendV2Wire`, `legacyKeyedReceive`); the dependency rule, which no shipped switch uses any more
-- but which `IsEnabled` still implements, is pinned through a pair registered by the example.
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

local function find(list, name)
	for _, e in ipairs(list) do if e.name == name then return e end end
end

describe("Switches registry", function()
	before_each(function() env.reset(); loadSwitches() end)

	it("declares the wire switch and the N6 grace-period switch, and nothing retired", function()
		for _, name in ipairs({ "sendV2Wire", "legacyKeyedReceive" }) do
			assert.is_table(Switches.registry[name], name .. " is not registered")
		end
		for _, name in ipairs({ "inventoryV2", "dualWrite" }) do
			assert.is_nil(Switches.registry[name],
				name .. " is registered again -- it was retired by INV2-RETIRE-003 when the V2 " ..
				"store became the only storage format, and nothing reads it")
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

	-- INV2 step 9: defaults ON, and this is a deliberate re-baseline rather than a spec bent to fit
	-- the code. The legacy link wire format is deleted in both directions (the 2026-09-09
	-- directive), so with this off the addon has no send path -- "off" is no longer a rollback to
	-- the old behaviour, because the old behaviour no longer exists.
	it("defaults the wire format ON, because there is no longer anything else", function()
		assert.is_true(Switches:IsEnabled("sendV2Wire"))
	end)
end)

describe("Switches state", function()
	before_each(function() env.reset(); loadSwitches() end)

	it("turns a switch on and off", function()
		assert.is_true(Switches:Set("sendV2Wire", true))
		assert.is_true(Switches:IsEnabled("sendV2Wire"))
		Switches:Set("sendV2Wire", false)
		assert.is_false(Switches:IsEnabled("sendV2Wire"))
	end)

	it("persists through db.global so it survives a reload", function()
		Switches:Set("sendV2Wire", true)
		assert.is_true(TOGBankClassic_Database.db.global.switches.sendV2Wire)
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
		-- The assertion is "it reports the DEFAULT", not "it reports false".
		assert.is_true(Switches:IsEnabled("sendV2Wire"))
		assert.is_false(Switches:IsEnabled("legacyKeyedReceive"))
		assert.is_false(Switches:Set("sendV2Wire", true))
	end)
end)

-- The dependency rule: a switch with `requires` is inert while its parent is off, whatever its own
-- stored value says. No shipped switch carries `requires` since `dualWrite` retired, but the rule is
-- still what `IsEnabled` implements and the next staged migration will lean on it -- so it is pinned
-- through a pair the example registers, and unregisters, itself.
describe("Switches dependencies", function()
	before_each(function()
		env.reset(); loadSwitches()
		Switches.registry.specParent = { default = true, description = "spec", retire = "spec" }
		Switches.registry.specChild  = { default = true, requires = "specParent", description = "spec", retire = "spec" }
	end)
	after_each(function()
		Switches.registry.specParent, Switches.registry.specChild = nil, nil
	end)

	-- The parent is turned off EXPLICITLY rather than relied on being off by default. The rule under
	-- test is the dependency rule, which has nothing to do with what the parent happens to default
	-- to -- an earlier form of this example broke when a default moved, which is the tell that it
	-- was testing the default by accident.
	it("reports a dependent switch off while its parent is off, despite its own default", function()
		assert.is_true(Switches.registry.specChild.default, "precondition: the child defaults on")
		Switches:Set("specParent", false)
		assert.is_false(Switches:IsEnabled("specParent"), "precondition: the parent is off")
		assert.is_false(Switches:IsEnabled("specChild"), "the child claimed to be active while its parent is off")
	end)

	it("reports a dependent switch on once its parent is on", function()
		Switches:Set("specParent", true)
		assert.is_true(Switches:IsEnabled("specChild"))
	end)

	it("still honours an explicit off for a dependent switch", function()
		Switches:Set("specParent", true)
		Switches:Set("specChild", false)
		assert.is_false(Switches:IsEnabled("specChild"))
	end)

	it("reports live state through GetAll, not the stored value", function()
		Switches:Set("specParent", false)
		assert.is_false(find(Switches:GetAll(), "specChild").enabled)
		Switches:Set("specParent", true)
		assert.is_true(find(Switches:GetAll(), "specChild").enabled)
	end)
end)

describe("Switches:GetAll", function()
	before_each(function() env.reset(); loadSwitches() end)

	it("returns every switch, sorted by name", function()
		local all = Switches:GetAll()
		assert.equal(2, #all)
		assert.equal("legacyKeyedReceive", all[1].name)
		assert.equal("sendV2Wire", all[2].name)
	end)

	-- N6: the operator's "comment it out first, delete in a week or two if nothing happens". Off
	-- by default is the comment-out; the switch is what makes it undoable in game.
	it("ships legacyKeyedReceive OFF, with a retire note naming the deletion", function()
		assert.is_false(Switches:IsEnabled("legacyKeyedReceive"))
		assert.truthy(Switches.registry.legacyKeyedReceive.retire:find("delete", 1, true))
	end)

	-- Distinguishes "the user set this" from "this is inherited", which is the first question
	-- when diagnosing a report.
	it("flags whether a switch was explicitly overridden", function()
		assert.is_false(find(Switches:GetAll(), "sendV2Wire").overridden)
		Switches:Set("sendV2Wire", true)   -- same as the default, but explicitly set
		assert.is_true(find(Switches:GetAll(), "sendV2Wire").overridden)
	end)

	it("carries the description, default and retirement note through", function()
		local e = find(Switches:GetAll(), "sendV2Wire")
		assert.is_string(e.description)
		assert.is_string(e.retire)
		assert.is_true(e.default)   -- INV2 step 9: defaults on
	end)

	-- `pending` has no user today and that is the correct state: every registered switch is wired
	-- to something. It is carried through GetAll so the escape hatch the wiring guard below offers
	-- actually reaches the listing the moment a switch is staged ahead of its code.
	it("carries the pending marker through, so the listing can show it", function()
		assert.is_nil(find(Switches:GetAll(), "sendV2Wire").pending)
		Switches.registry.sendV2Wire.pending = "staged"
		assert.equal("staged", find(Switches:GetAll(), "sendV2Wire").pending)
		Switches.registry.sendV2Wire.pending = nil
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

	-- Matches the CALL, not the name. A bare substring search would report a switch as read because
	-- a comment mentions it -- prose about a switch is the opposite of a reader, and counting it
	-- would have hidden exactly the defect this guard exists to find. `IsEnabled("<name>")` is the
	-- only way a switch is consulted; `Set` is driven from the slash command through a variable, so
	-- it never appears as a literal.
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

	-- The other direction, added with INV2-RETIRE-003: a switch that was retired must not still be
	-- READ anywhere, or the reader silently branches on a name `IsEnabled` answers false for.
	it("has no shipped reader of a retired switch", function()
		for _, path in ipairs(shippedSources()) do
			local fh = io.open(path, "r")
			if fh then
				local src = fh:read("*a")
				fh:close()
				for _, name in ipairs({ "inventoryV2", "dualWrite" }) do
					assert.is_false(readsSwitch(src, name), string.format(
						"%s still reads the retired switch '%s' -- IsEnabled answers false for an " ..
						"unregistered name, so that branch is silently dead", path, name))
				end
			end
		end
	end)
end)
