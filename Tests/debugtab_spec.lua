-- The debug chat tab: the client-compat crash (CHATWIN-001) and the confident-but-false
-- confirmation (DEV-UX-002).
--
-- Both defects shipped in a command whose whole job is DIAGNOSIS, which is the worst place for
-- them: the tool you reach for when something is wrong was itself either erroring or lying, and
-- in both cases the symptom read as "the debug tab is broken" rather than as its actual cause.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

-- ---------------------------------------------------------------------------
-- CHATWIN-001 -- NUM_CHAT_WINDOWS is not a guaranteed global on Classic Era
-- ---------------------------------------------------------------------------

describe("CHATWIN-001: the chat-window count survives a missing NUM_CHAT_WINDOWS", function()
	local Output

	before_each(function()
		env.reset()
		Output = env.loadOutput()
	end)

	-- THE FAILURE THIS PINS, and it is a hard error rather than a wrong answer:
	--
	-- `NUM_CHAT_WINDOWS` is assigned in exactly ONE place in Blizzard's Classic Era tree --
	-- Blizzard_DeprecatedChatInfo/Deprecated_ChatFrame.lua:18 -- and that file returns early at
	-- its line 4 unless GetCVarBool("loadDeprecationFallbacks") is true. For a player with that
	-- CVar off the global is nil, and `for i = 1, nil` raises. Every path in Output.lua that
	-- looks for the tab walked that loop, so the debug tab did not degrade, it threw.
	--
	-- Driven by NILLING THE GLOBAL rather than by reading the helper, because the helper is a
	-- local: this asserts the property a player experiences, which is also the only thing that
	-- stays true if the lookup is ever rewritten.
	it("does not error when the deprecated global is absent", function()
		local saved = NUM_CHAT_WINDOWS
		NUM_CHAT_WINDOWS = nil
		finally(function() NUM_CHAT_WINDOWS = saved end)

		assert.has_no_error(function() Output:GetDebugFrame() end)
	end)

	it("does not error when the global is absent and the engine table is too", function()
		-- The belt-and-braces case: a client exposing neither spelling must still degrade to
		-- "no tab found" rather than taking the caller down with it.
		local savedGlobal, savedConstants = NUM_CHAT_WINDOWS, Constants
		NUM_CHAT_WINDOWS, Constants = nil, nil
		finally(function() NUM_CHAT_WINDOWS, Constants = savedGlobal, savedConstants end)

		assert.has_no_error(function() Output:GetDebugFrame() end)
	end)

	-- Absence must read as "the tab is not there", never as an error and never as a frame.
	it("reports no debug frame rather than inventing one", function()
		local saved = NUM_CHAT_WINDOWS
		NUM_CHAT_WINDOWS = nil
		finally(function() NUM_CHAT_WINDOWS = saved end)

		Output.debugFrame = nil
		assert.is_nil(Output:GetDebugFrame())
	end)

	it("removing a tab that cannot be enumerated is a no-op, not an error", function()
		local saved = NUM_CHAT_WINDOWS
		NUM_CHAT_WINDOWS = nil
		finally(function() NUM_CHAT_WINDOWS = saved end)

		assert.has_no_error(function() Output:RemoveDebugTab() end)
	end)
end)

-- ---------------------------------------------------------------------------
-- DEV-UX-002 -- /togbank debugtab must not claim output it cannot produce
-- ---------------------------------------------------------------------------

local function loadChat()
	env.stubOutput()
	env.loadModules({ "Modules/Constants.lua", "Modules/Switches.lua", "Modules/Chat.lua" })
	env.stubCore()
	TOGBankClassic_Database = { db = { global = {} } }
	TOGBankClassic_Guild = TOGBankClassic_Guild or { Info = { name = "Testguild", alts = {} } }
	return TOGBankClassic_Chat
end

--- Stand the Output stub up in a named gate state. The stub is a catch-all metatable, so
--- assigning real fields here overrides it for exactly the methods the handler consults.
local function gates(levelIsDebug, enabledCategories)
	local Out = TOGBankClassic_Output
	Out.CreateDebugTab   = function() return true end
	Out.GetLevel         = function() return levelIsDebug and LOG_LEVEL.DEBUG or LOG_LEVEL.INFO end
	Out.IsCategoryEnabled = function(_, name) return (enabledCategories or {})[name] == true end
	return Out
end

--- True if any captured Response carried `text` in its FORMAT STRING.
local function said(text)
	for _, c in ipairs(TOGBankClassic_Output.calls or {}) do
		if type(c[1]) == "string" and c[1]:find(text, 1, true) then return true end
	end
	return false
end

describe("DEV-UX-002: /togbank debugtab reports the gates it cannot open", function()
	before_each(function() env.reset(); loadChat() end)

	-- THE DEFECT: this replied "Debug output will now appear in 'TOGBank Debug' tab"
	-- unconditionally. The tab is the FOURTH of four gates and the two before it are off by
	-- default, so the default state produced a confident confirmation followed by silence --
	-- which reads as a broken tab rather than an unset switch. Same class as DEV-UX-001.
	it("says nothing will appear when BOTH the level and every category are off", function()
		gates(false, {})
		TOGBankClassic_Chat:ChatCommand("debugtab")
		assert.is_true(said("Nothing will appear in it yet"),
			"the tab was created in the default state and the command did not warn that the " ..
			"level and every category are still off -- DEV-UX-002")
		assert.is_false(said("IS|r flowing"),
			"claimed output was flowing while both gates were shut")
	end)

	-- Naming the remedy is the point. A warning that does not say which command to run leaves
	-- the user exactly as stuck, which is what sent the operator hunting on 2026-09-10.
	it("names the command that turns the log level on", function()
		gates(false, {})
		TOGBankClassic_Chat:ChatCommand("debugtab")
		assert.is_true(said("/togbank debug|r"), "did not name the command that raises the level")
	end)

	it("names the command that turns a category on", function()
		gates(false, {})
		TOGBankClassic_Chat:ChatCommand("debugtab")
		assert.is_true(said("debug only <CATEGORY>"), "did not name the command that enables a category")
	end)

	-- The level alone is NOT sufficient, and this is the half most likely to be lost in a
	-- refactor: categories are opt-in and default false, so a raised level with no category
	-- still produces nothing at all.
	it("still warns when the level is on but no category is", function()
		gates(true, {})
		TOGBankClassic_Chat:ChatCommand("debugtab")
		assert.is_true(said("Nothing will appear in it yet"),
			"level on with zero categories produces no output, and the command claimed otherwise")
	end)

	-- And a category alone is not sufficient either, for the mirror-image reason: Log() drops
	-- anything below the current level before it ever reaches the frame.
	it("still warns when a category is on but the level is not", function()
		gates(false, { COMMS = true })
		TOGBankClassic_Chat:ChatCommand("debugtab")
		assert.is_true(said("Nothing will appear in it yet"),
			"a category with the level down produces no output, and the command claimed otherwise")
	end)

	it("confirms output IS flowing once both gates are open", function()
		gates(true, { COMMS = true })
		TOGBankClassic_Chat:ChatCommand("debugtab")
		assert.is_true(said("IS|r flowing"),
			"both gates were open and the command failed to confirm it")
		assert.is_false(said("Nothing will appear in it yet"),
			"warned about shut gates while both were open")
	end)

	-- The listing is what lets a user see they enabled the WRONG category -- the actual cause of
	-- the 2026-09-10 report, which turned out to be a mis-ticked box rather than a code defect.
	it("lists which categories are enabled, so a wrong one is visible", function()
		gates(true, { COMMS = true })
		TOGBankClassic_Chat:ChatCommand("debugtab")
		local listed = false
		for _, c in ipairs(TOGBankClassic_Output.calls or {}) do
			for i = 1, (c.n or 0) do
				if c[i] == "COMMS" then listed = true end
			end
		end
		assert.is_true(listed, "the enabled category was not named, so a mis-ticked one stays invisible")
	end)

	-- Nothing is claimed about a tab that was never created.
	it("says nothing at all when the tab could not be created", function()
		gates(false, {})
		TOGBankClassic_Output.CreateDebugTab = function() return false end
		TOGBankClassic_Chat:ChatCommand("debugtab")
		assert.is_false(said("tab is ready"), "reported a tab that was never created")
	end)
end)
