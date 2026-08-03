-- Smoke test: the offline environment stands up and every addon module loads.
--
-- This is the spec that fails first and loudest when the harness, the module load order, or a
-- module's top-level code breaks — before any behavioural spec gets a chance to report a
-- confusing downstream error.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

describe("harness", function()
	before_each(function() env.reset() end)

	it("provides a controllable clock", function()
		assert.equal(0, GetTime())
		env.advance(5)
		assert.equal(5, GetTime())
	end)

	it("runs a C_Timer.After callback only once its delay has elapsed", function()
		local fired = false
		C_Timer.After(10, function() fired = true end)
		env.advance(9)
		assert.is_false(fired)
		env.advance(1)
		assert.is_true(fired)
	end)

	-- This is the contract that audit TIMER-001 turns on. If a future harness change
	-- "helpfully" returns a handle here, eight real bugs in the addon become untestable.
	it("returns nothing from C_Timer.After, exactly like the real API", function()
		assert.is_nil(C_Timer.After(1, function() end))
	end)

	it("returns a cancellable handle from C_Timer.NewTimer", function()
		local fired = false
		local handle = C_Timer.NewTimer(10, function() fired = true end)
		assert.is_not_nil(handle)
		handle:Cancel()
		env.advance(20)
		assert.is_false(fired)
	end)

	it("resets state between tests", function()
		assert.equal(0, GetTime())
		assert.equal(0, env.pendingTimerCount())
	end)
end)

describe("module loading", function()
	before_each(function() env.reset() end)

	it("loads Constants and publishes its tables", function()
		env.loadFile("Modules/Constants.lua")
		assert.is_table(DEBUG_CATEGORY)
		assert.is_table(DEBUG_TAGS)
		assert.is_table(COMM_PREFIX_DESCRIPTIONS)
	end)

	it("loads every module in .toc order without error", function()
		env.stubOutput()
		env.loadModules(env.MODULE_ORDER)
		for _, name in ipairs({
			"TOGBankClassic_Bank", "TOGBankClassic_Guild", "TOGBankClassic_Item",
			"TOGBankClassic_Database", "TOGBankClassic_Events", "TOGBankClassic_P2PSession",
		}) do
			assert.is_table(_G[name], name .. " was not published as a global")
		end
	end)
end)
