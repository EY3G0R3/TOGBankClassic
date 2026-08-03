-- Events.lua — the AceEvent dispatch contract and the handlers that depend on it.
--
-- Events:RegisterEvent wraps AceEvent, which dispatches as fn(eventName, ...). Every handler in
-- the module therefore has to absorb the event name in a leading parameter. That convention is
-- invisible at the call site and impossible to see from a handler in isolation — a handler that
-- forgets it does not error, it just silently receives the wrong values forever. So the
-- convention is asserted here rather than trusted.
--
-- Verified against the installed Ace3 (not assumed):
--   Ace3/AceEvent-3.0/AceEvent-3.0.lua:120       events:Fire(event, ...)
--   Ace3/CallbackHandler-1.0/...lua:54           Dispatch(events[eventname], eventname, ...)
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

-- Stand in for AceEvent: capture what Events:RegisterEvent hands to Core, then invoke it the way
-- CallbackHandler does — with the event name first.
local function captureHandlers()
	local handlers = {}
	TOGBankClassic_Core = TOGBankClassic_Core or {}
	TOGBankClassic_Core.RegisterEvent   = function(_, event, fn) handlers[event] = fn end
	TOGBankClassic_Core.UnregisterEvent = function(_, event) handlers[event] = nil end
	TOGBankClassic_Core.RegisterMessage = function() end
	TOGBankClassic_Core.SendMessage     = function() end
	TOGBankClassic_Core.ScheduleTimer   = function() return {} end
	TOGBankClassic_Core.CancelTimer     = function() end
	TOGBankClassic_Core.Print           = function() end
	return handlers
end

--- Fire an event exactly as CallbackHandler:Fire does: the handler receives (eventName, ...).
local function fire(handlers, event, ...)
	local fn = handlers[event]
	assert.is_not_nil(fn, "no handler registered for " .. event)
	return fn(event, ...)
end

describe("Events dispatch contract", function()
	local handlers

	before_each(function()
		env.reset()
		env.stubOutput()
		handlers = captureHandlers()
		env.loadFile("Modules/Events.lua")
	end)

	it("passes the event name to the handler as its first argument", function()
		local seen
		TOGBankClassic_Events.PROBE_EVENT = function(_, first) seen = first end
		TOGBankClassic_Events:RegisterEvent("PROBE_EVENT")
		fire(handlers, "PROBE_EVENT", "payload")
		assert.equal("PROBE_EVENT", seen,
			"AceEvent dispatches as fn(eventName, ...); the harness must mirror that or every " ..
			"handler-signature spec below is meaningless")
	end)

	it("passes the event's own arguments after the event name", function()
		local a, b
		TOGBankClassic_Events.PROBE_EVENT = function(_, _, x, y) a, b = x, y end
		TOGBankClassic_Events:RegisterEvent("PROBE_EVENT")
		fire(handlers, "PROBE_EVENT", "first", "second")
		assert.equal("first", a)
		assert.equal("second", b)
	end)
end)

-- ---------------------------------------------------------------------------
-- Audit EVENT-001
-- ---------------------------------------------------------------------------
describe("Events:CHAT_MSG_SYSTEM", function()
	local handlers
	local online, offline, rosterRefreshes

	before_each(function()
		env.reset()
		env.stubOutput()
		handlers = captureHandlers()
		env.loadFile("Modules/Events.lua")

		online, offline, rosterRefreshes = {}, {}, 0
		TOGBankClassic_Guild = {
			UpdateOnlineMember = function(_, name, isOnline)
				if isOnline then online[#online + 1] = name else offline[#offline + 1] = name end
			end,
			GetNormalizedPlayer = function() return "Bankchar-Testrealm" end,
			IsBank = function() return false end,
		}
		_G.GuildRoster = function() rosterRefreshes = rosterRefreshes + 1 end

		TOGBankClassic_Events:RegisterEvent("CHAT_MSG_SYSTEM")
	end)

	-- The handler is declared `function TOGBankClassic_Events:CHAT_MSG_SYSTEM(message)` — with no
	-- leading `_` to absorb the event name. So `message` receives the string "CHAT_MSG_SYSTEM"
	-- and the real text is discarded. Every match below fails and the body does nothing.
	it("marks a player online when the come-online message arrives", function()
		fire(handlers, "CHAT_MSG_SYSTEM", "Bob has come online.")
		assert.same({ "Bob" }, online,
			"the come-online message was ignored. CHAT_MSG_SYSTEM's handler signature is " ..
			"missing the leading event-name parameter, so it reads the event NAME as the " ..
			"message and never matches anything (audit EVENT-001)")
	end)

	it("marks a player offline when the gone-offline message arrives", function()
		fire(handlers, "CHAT_MSG_SYSTEM", "Bob has gone offline.")
		assert.same({ "Bob" }, offline, "the gone-offline message was ignored (audit EVENT-001)")
	end)

	-- The addon calls this "the AUTHORITATIVE offline signal" and relies on it to stop whisper
	-- spam at a player who is not logged in.
	it("marks a player offline on the 'no player named' whisper failure", function()
		fire(handlers, "CHAT_MSG_SYSTEM", "No player named Bob is currently playing.")
		assert.same({ "Bob" }, offline,
			"the whisper-failure offline signal was ignored, so the addon keeps whispering an " ..
			"offline player (audit EVENT-001)")
	end)

	it("handles the quoted variant of the 'no player named' message", function()
		fire(handlers, "CHAT_MSG_SYSTEM", "No player named 'Bob' is currently playing.")
		assert.same({ "Bob" }, offline, "the quoted variant was ignored (audit EVENT-001)")
	end)

	it("requests a roster refresh when someone joins the guild", function()
		fire(handlers, "CHAT_MSG_SYSTEM", "Bob has joined the guild.")
		assert.equal(1, rosterRefreshes, "a guild join did not trigger a roster refresh (audit EVENT-001)")
	end)

	it("requests a roster refresh when someone leaves the guild", function()
		fire(handlers, "CHAT_MSG_SYSTEM", "Bob has left the guild.")
		assert.equal(1, rosterRefreshes, "a guild leave did not trigger a roster refresh (audit EVENT-001)")
	end)

	it("ignores an unrelated system message", function()
		fire(handlers, "CHAT_MSG_SYSTEM", "Your loot: something shiny.")
		assert.same({}, online)
		assert.same({}, offline)
	end)

	-- The harness's assert table has has_error but no has_no_error, so this is spelled out.
	-- See Tests/HARNESS_CONTRACT.md — has_no_error is a proposed harness addition.
	it("does not error on an empty message", function()
		local ok, err = pcall(fire, handlers, "CHAT_MSG_SYSTEM", "")
		assert.is_true(ok, "handler raised on an empty message: " .. tostring(err))
	end)
end)

describe("Events registration symmetry", function()
	local handlers

	before_each(function()
		env.reset()
		env.stubOutput()
		handlers = captureHandlers()
		env.loadFile("Modules/Constants.lua")   -- SetShareTimer reads TIMER_INTERVALS
		env.loadFile("Modules/Events.lua")
		-- RegisterEvents touches a lot of collaborators at load; stub the ones it reaches for.
		TOGBankClassic_Bank  = { eventsRegistered = false }
		TOGBankClassic_Guild = { GetNormalizedPlayer = function() return "Bankchar-Testrealm" end,
		                         IsBank = function() return false end }
		TOGBankClassic_UI    = { OnInsertLink = function() end }
		TOGBankClassic_UI_Requests = { isOpen = false }
		_G.ChatFrame_AddMessageEventFilter = function() end
		_G.MailFrame, _G.MailFrameTab2 = nil, nil
	end)

	-- Anything registered but never unregistered keeps firing after OnDisable, against a module
	-- that believes it is shut down.
	it("unregisters every event it registers", function()
		TOGBankClassic_Events:RegisterEvents()
		local registered = {}
		for event in pairs(handlers) do registered[#registered + 1] = event end

		TOGBankClassic_Events:UnregisterEvents()
		local leftOver = {}
		for event in pairs(handlers) do leftOver[#leftOver + 1] = event end
		table.sort(leftOver)

		assert.truthy(#registered > 0, "no events were registered; the stub setup is wrong")
		assert.same({}, leftOver,
			"these events are registered but never unregistered, so they keep firing after " ..
			"OnDisable (audit EVENT-002)")
	end)
end)
