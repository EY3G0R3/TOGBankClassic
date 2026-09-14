-- CMD-001 — arguments must survive the slash-command entry point.
--
-- WHY THIS FILE EXISTS, and why the existing dev-command specs did not catch it:
--
-- `/togbank dev switches inventoryV2 on` printed the switch list and the usage line instead of
-- setting anything -- indistinguishable from a command that ran and had nothing to do. The cause
-- was in ChatCommand, not in either handler: `Core:GetArgs(input, 2)` TOKENIZES. Its contract is
-- `arg1, ..., argN, nextposition` (AceConsole-3.0.lua:138-139), so it returned "dev" and
-- "switches" and the remainder was simply discarded. NO `/togbank dev <sub> <args>` COMMAND HAD
-- EVER RECEIVED ITS ARGUMENTS IN GAME.
--
-- Every existing spec for these commands calls the handler directly with a ready-made argument
-- string, which is precisely the step where the bug lives. So these drive
-- `TOGBankClassic_Chat:ChatCommand(...)` with the raw text a player types, and assert on the
-- effect. A spec that calls the handler cannot fail here however carefully it is written.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function loadChat()
	env.stubOutput()
	env.loadModules({ "Modules/Constants.lua", "Modules/Switches.lua", "Modules/Chat.lua" })
	-- The faithful AceConsole GetArgs. Using env.stubCore rather than a local fake is the whole
	-- point of this file: a looser stub is what hid CMD-001.
	env.stubCore()
	TOGBankClassic_Database = { db = { global = {} } }
	TOGBankClassic_Guild = TOGBankClassic_Guild or { Info = { name = "Testguild", alts = {} } }
	return TOGBankClassic_Chat
end

-- INV2-RETIRE-003: the live string that exposed CMD-001 was `dev switches inventoryV2 on`; that
-- switch is retired, so these drive `legacyKeyedReceive` -- OFF by default, which is what makes
-- "on" an observable change -- and the dependency example registers its own parent/child pair,
-- since no shipped switch carries `requires` any more.
describe("CMD-001: /togbank argument plumbing", function()
	before_each(function() env.reset(); loadChat() end)

	-- The same shape as the exact string that exposed this from a live client.
	it("delivers both arguments of a dev subcommand", function()
		assert.is_false(TOGBankClassic_Switches:IsEnabled("legacyKeyedReceive"), "precondition: defaults off")
		TOGBankClassic_Chat:ChatCommand("dev switches legacyKeyedReceive on")
		assert.is_true(TOGBankClassic_Switches:IsEnabled("legacyKeyedReceive"),
			"the switch did not change, so the arguments never reached the handler -- ChatCommand " ..
			"tokenized them away and the command fell through to its no-argument branch, which " ..
			"prints the list and looks exactly like success (CMD-001)")
	end)

	it("turns a switch back off through the same path", function()
		TOGBankClassic_Chat:ChatCommand("dev switches legacyKeyedReceive on")
		TOGBankClassic_Chat:ChatCommand("dev switches legacyKeyedReceive off")
		assert.is_false(TOGBankClassic_Switches:IsEnabled("legacyKeyedReceive"))
	end)

	-- Ordering matters to the operator: a dependent switch reports OFF while its parent is off, so
	-- a spec that only set the child would assert nothing.
	it("sets a dependent switch once its parent is on", function()
		TOGBankClassic_Switches.registry.specParent = { default = false, description = "spec", retire = "spec" }
		TOGBankClassic_Switches.registry.specChild  = { default = false, requires = "specParent", description = "spec", retire = "spec" }
		TOGBankClassic_Chat:ChatCommand("dev switches specChild on")
		assert.is_false(TOGBankClassic_Switches:IsEnabled("specChild"), "precondition: inert while the parent is off")
		TOGBankClassic_Chat:ChatCommand("dev switches specParent on")
		assert.is_true(TOGBankClassic_Switches:IsEnabled("specChild"))
		TOGBankClassic_Switches.registry.specParent, TOGBankClassic_Switches.registry.specChild = nil, nil
	end)

	-- DOUBLE-001 / CMD-002 class: a registry entry meant for `/togbank dev` is routed there ONLY by
	-- DEV_COMMAND_NAMES. `sources` was registered without that line and the operator's client answered
	-- "Unknown dev subcommand: sources" -- so this drives the typed string and asserts the handler ran.
	it("routes /togbank dev sources to its handler, with its arguments", function()
		-- ONE Lua state for the whole suite: the Store global is put back, or every later spec that
		-- loads the real store finds this stub instead.
		local realStore = TOGBankClassic_Inventory_Store
		TOGBankClassic_Inventory_Store = { GuildTable = function() return { alts = {} } end }
		TOGBankClassic_Guild = { Info = { name = "Testguild", alts = {} },
			NormalizeName = function(_, n) return n .. "-Testrealm" end }
		TOGBankClassic_Chat:ChatCommand("dev sources Bankchar archaic")
		TOGBankClassic_Inventory_Store = realStore
		-- stubOutput records the format string and its arguments separately.
		local lines = {}
		for _, c in ipairs(TOGBankClassic_Output.calls) do
			local ok, s = pcall(string.format, tostring(c[1]), select(2, unpack(c, 1, c.n)))
			lines[#lines + 1] = ok and s or tostring(c[1])
		end
		local text = table.concat(lines, "\n")
		assert.is_nil(text:find("Unknown dev subcommand", 1, true), "`dev sources` is not routed to the dev dispatcher")
		assert.truthy(text:find("Bankchar-Testrealm: no V2 record held", 1, true), "the handler did not run with its banker argument: " .. text)
	end)

	it("leaves a bare dev subcommand working, with no arguments", function()
		-- A KNOWN state is established first and the assertion is that it is UNCHANGED. An earlier
		-- form used `is_false` as a stand-in for "unchanged", which only worked while the switch
		-- defaulted off -- flipping a default turned a listing command into an apparent mutation.
		-- Asserting the actual property is what makes it independent of the default.
		TOGBankClassic_Switches:Set("sendV2Wire", false)
		assert.is_false(TOGBankClassic_Switches:IsEnabled("sendV2Wire"), "precondition")

		assert.has_no_error(function()
			TOGBankClassic_Chat:ChatCommand("dev switches")
		end)
		assert.is_false(TOGBankClassic_Switches:IsEnabled("sendV2Wire"),
			"a bare `dev switches` changed a switch; it must only list them")

		-- And in the other direction, so "unchanged" cannot be satisfied by always reporting off.
		TOGBankClassic_Switches:Set("sendV2Wire", true)
		TOGBankClassic_Chat:ChatCommand("dev switches")
		assert.is_true(TOGBankClassic_Switches:IsEnabled("sendV2Wire"),
			"a bare `dev switches` turned a switch off; it must only list them")
	end)

	-- The regression this fix could plausibly introduce: `rest` is passed as a SECOND parameter
	-- precisely so a single-token handler still receives exactly what it did before.
	it("does not fold trailing text into a single-token argument", function()
		local seen = {}
		local original = TOGBankClassic_Chat.ChatCommand
		assert.is_not_nil(original)
		TOGBankClassic_Chat:ChatCommand("dev switches legacyKeyedReceive on")
		-- legacyKeyedReceive must be the switch name, not "legacyKeyedReceive on".
		assert.is_not_nil(TOGBankClassic_Switches.registry["legacyKeyedReceive"])
		assert.is_nil(TOGBankClassic_Switches.registry["legacyKeyedReceive on"],
			"the name and its value were concatenated, so the remainder replaced the token " ..
			"instead of being passed alongside it")
		seen[#seen + 1] = true
		assert.equal(1, #seen)
	end)

	it("reports an unknown dev subcommand rather than silently listing", function()
		assert.has_no_error(function()
			TOGBankClassic_Chat:ChatCommand("dev nosuchthing arg")
		end)
	end)
end)

-- DEV-UX-001 — driving debug CATEGORIES from chat.
--
-- The operator's constraint is the design constraint: "this is an ACTIVE guild and we'll get 1000s
-- of messages per second. you need to be surgical about what you want to see." So the assertions
-- that matter are the isolating ones -- `only` and `none` -- not merely that a setter can be
-- reached. Enabling everything is what the category system exists to avoid.
describe("DEV-UX-001: /togbank debug category control", function()
	local Out

	before_each(function()
		env.reset()
		-- The REAL Output module, not env.stubOutput: IsCategoryEnabled / SetCategoryEnabled /
		-- SetTagEnabled are the functions under test here, so a stub would assert nothing. This is
		-- the same trap CMD-001 was hiding in, one layer along.
		Out = env.loadOutput()
		env.loadModules({ "Modules/Switches.lua", "Modules/Chat.lua" })
		env.stubCore()
		-- Chat's bare-debug branch persists the chosen level through Options.
		TOGBankClassic_Options = { db = { global = { bank = {} } } }
	end)

	it("turns a single category on without touching the others", function()
		TOGBankClassic_Chat:ChatCommand("debug BANK on")
		assert.is_true(Out:IsCategoryEnabled("BANK"))
		assert.is_false(Out:IsCategoryEnabled("SYNC") == true,
			"enabling one category enabled another -- on a live guild that is the difference " ..
			"between a readable log and thousands of lines a second")
	end)

	it("accepts a lowercase category name", function()
		TOGBankClassic_Chat:ChatCommand("debug bank on")
		assert.is_true(Out:IsCategoryEnabled("BANK"))
	end)

	it("turns one off again", function()
		TOGBankClassic_Chat:ChatCommand("debug BANK on")
		TOGBankClassic_Chat:ChatCommand("debug BANK off")
		assert.is_false(Out:IsCategoryEnabled("BANK"))
	end)

	-- The command the constraint above actually calls for.
	it("`only` isolates one category and silences every other", function()
		TOGBankClassic_Chat:ChatCommand("debug SYNC on")
		TOGBankClassic_Chat:ChatCommand("debug P2P on")
		TOGBankClassic_Chat:ChatCommand("debug only BANK")
		assert.is_true(Out:IsCategoryEnabled("BANK"))
		assert.is_false(Out:IsCategoryEnabled("SYNC"),
			"`only` left another category on, so it does not isolate and is useless on a busy guild")
		assert.is_false(Out:IsCategoryEnabled("P2P"))
	end)

	it("`none` silences everything", function()
		TOGBankClassic_Chat:ChatCommand("debug BANK on")
		TOGBankClassic_Chat:ChatCommand("debug none")
		assert.is_false(Out:IsCategoryEnabled("BANK"))
	end)

	it("suppresses a single tag within a category", function()
		TOGBankClassic_Chat:ChatCommand("debug BANK on")
		TOGBankClassic_Chat:ChatCommand("debug BANK SCAN off")
		assert.is_true(Out:IsCategoryEnabled("BANK"))
		assert.is_false(Out:IsTagEnabled("BANK", "SCAN"))
		assert.is_true(Out:IsTagEnabled("BANK", "GATE"),
			"suppressing one tag suppressed a sibling; tags are opt-out and independent")
	end)

	-- Each of these used to report success while doing something other than what was asked.
	--
	-- NOTE ON THIS PAIR, because the first version of them was wrong: `debug BANK on extra` is
	-- caught by the TAG check, not the trailing-junk check -- "on extra" parses as first="on",
	-- second="extra", extra="", so the junk guard never sees it. A spec named for the junk guard
	-- that is actually exercising the tag guard is a guard that cannot fail for its stated reason.
	-- Proven by disabling each check in turn: only the tag one went red. So this drives a genuine
	-- three-word tail, where `extra` is non-empty.
	it("rejects a bogus tag rather than storing it", function()
		TOGBankClassic_Chat:ChatCommand("debug BANK on extra")
		assert.is_true(Out:IsTagEnabled("BANK", "ON"),
			"`debug BANK on extra` stored a tag named ON. The pattern matched only the first two " ..
			"words, so a typo produced a confident confirmation and no category change")
	end)

	it("rejects trailing junk after a valid tag and state", function()
		TOGBankClassic_Chat:ChatCommand("debug BANK GATE off now")
		assert.is_true(Out:IsTagEnabled("BANK", "GATE"),
			"a fourth word was ignored and the tag was set anyway -- the command silently did " ..
			"something narrower than what was typed")
	end)

	it("rejects a tag the category does not declare", function()
		TOGBankClassic_Chat:ChatCommand("debug BANK NOSUCHTAG off")
		assert.is_true(Out:IsTagEnabled("BANK", "NOSUCHTAG"),
			"an unknown tag was stored. Tags are opt-out at read time, so storing one that no " ..
			"Debug call uses is a setting that can never affect any output")
	end)

	it("rejects a tag state that is not on or off", function()
		TOGBankClassic_Chat:ChatCommand("debug BANK GATE maybe")
		assert.is_true(Out:IsTagEnabled("BANK", "GATE"),
			"`maybe` was treated as off rather than refused")
	end)

	it("still accepts a real tag with a real state", function()
		TOGBankClassic_Chat:ChatCommand("debug BANK GATE off")
		assert.is_false(Out:IsTagEnabled("BANK", "GATE"))
	end)

	it("rejects an unknown category rather than silently doing nothing", function()
		assert.has_no_error(function()
			TOGBankClassic_Chat:ChatCommand("debug NOSUCHCATEGORY on")
		end)
		assert.is_false(Out:IsCategoryEnabled("NOSUCHCATEGORY"))
	end)

	-- The pre-existing behaviour must survive: bare `/togbank debug` is the log-level toggle and
	-- thousands of muscle-memory uses depend on it.
	it("leaves bare /togbank debug as the log-level toggle", function()
		local before = Out:GetLevel()
		TOGBankClassic_Chat:ChatCommand("debug")
		assert.is_not.equal(before, Out:GetLevel(),
			"bare `/togbank debug` stopped toggling the log level")
	end)
end)
