-- env_fleet RESETS EVERYTHING IT OWNS (peer review F7 on THE DELTA RELEASE).
--
-- The fleet-wide rule for every test environment: the whole suite runs in ONE Lua state, so a
-- fixture field that survives a reset lets one spec leak into the next -- invisible in a single-file
-- run, only reproducible in a full-suite run. `F.new` carries a hand-written reset list
-- (`F.clients, F.byName, F.queue, F.log, F.active = ...` and `F.bulkDrain = 0`), and a list written
-- by hand drifts the day a field is added without it. F7 asked for the list to be ENUMERATED against
-- the fixture rather than trusted.
--
-- This does not hardcode the list either: it walks every non-function field on `F`, poisons each
-- mutable one with a sentinel, calls `F.new`, and requires the sentinel gone. A field added to the
-- fixture later is walked automatically; the only edit a new CONSTANT needs is a line in CONSTANTS,
-- and a constant that is really state fails here first.
package.path = "./Tests/?.lua;" .. package.path
local F = require("env_fleet")

-- Fields that are the same world for every spec and are NOT state: the harness env itself, the
-- guild name, and the two addon-version strings a mixed-version fleet is built from
-- (WIRE-SKEW-003). Anything else that is not a function must come back fresh from F.new.
local CONSTANTS = { env = true, GUILD = true, CURRENT_VERSION = true, OLD_VERSION = true }

local function stateFields()
	local out = {}
	for k, v in pairs(F) do
		if type(v) ~= "function" and not CONSTANTS[k] then out[#out + 1] = k end
	end
	table.sort(out)
	return out
end

describe("env_fleet: F.new resets every state field the fixture owns", function()
	it("walks at least the fields the reset list names, so the enumeration is not vacuous", function()
		local seen = {}
		for _, k in ipairs(stateFields()) do seen[k] = true end
		for _, k in ipairs({ "clients", "byName", "queue", "log", "bulkDrain" }) do
			assert.is_true(seen[k], "expected to enumerate F." .. k)
		end
	end)

	it("no state field survives F.new with the value a previous spec left in it", function()
		local SENTINEL = { leaked = "from the previous spec" }
		local fields = stateFields()
		-- `active` is nil at rest and pairs() cannot see a nil field: poison it by name so a reset
		-- that forgets it is still caught.
		local poisoned = {}
		for _, k in ipairs(fields) do F[k] = SENTINEL; poisoned[k] = true end
		if not poisoned.active then F.active = SENTINEL; fields[#fields + 1] = "active" end

		F.new({})

		local leaked = {}
		for _, k in ipairs(fields) do
			if F[k] == SENTINEL then leaked[#leaked + 1] = k end
		end
		assert.same({}, leaked, "F.new did not reset these fields: " .. table.concat(leaked, ", "))
	end)

	it("after the reset a fleet is empty and the bus is quiet", function()
		F.new({})
		assert.same({}, F.clients)
		assert.same({}, F.byName)
		assert.same({}, F.queue)
		assert.same({}, F.log)
		assert.is_nil(F.active)
		assert.equal(0, F.bulkDrain)
	end)
end)
