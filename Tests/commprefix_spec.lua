-- LIBREQ-ALL-005 — a comm prefix the client REFUSED to register must be loud, and every other
-- outcome must be silent.
--
-- WHY THIS FILE EXISTS. `C_ChatInfo.RegisterAddonMessagePrefix` returns a NUMBER from
-- `Enum.RegisterAddonMessagePrefixResult` — never a boolean, never nil. So the two obvious guards
-- are both DEAD CODE in game:
--
--     if not C_ChatInfo.RegisterAddonMessagePrefix(p) then   -- Success is 0, and 0 is TRUTHY
--     if result == false then                                -- no boolean is ever returned
--
-- Either would have passed a spec written against the harness stub as it was until 2026-09-09,
-- which returned `true` and whose own comment admitted the return had never been checked against
-- Blizzard's docs. Writing the guard then would have ratified a branch that cannot execute — worse
-- than no guard, because it looks like coverage. The harness now returns the real enum
-- (`c9f3199`), which is what makes these assertions worth anything.
--
-- THE ASSERTION THAT MATTERS MOST IS THE SILENT ONE. AceComm registers our prefixes on our behalf
-- FIRST, so TOGBank re-registering to read the verdict gets `DuplicatePrefix` for all eleven, every
-- login, forever. A guard that treats it as failure produces eleven warnings a session, gets
-- trained out, and then a genuine `MaxPrefixes` refusal goes unread. "Reports nothing" is the
-- behaviour under test there, so it is asserted rather than left implied.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")
local wow = require("env.wow")

--- Captured once, at load, before any example can tamper with it. The "no C_ChatInfo at all"
--- example below nils the global deliberately, and this suite runs in ONE Lua state -- so without
--- putting it back, every spec file loaded after this one would run against a client that has no
--- C_ChatInfo, and would pass or fail for a reason nothing in those files mentions.
local realChatInfo = _G.C_ChatInfo

local function loadChat()
	env.stubOutput()
	env.loadModules({ "Modules/Constants.lua", "Modules/Switches.lua", "Modules/Chat.lua" })
	env.stubCore()
	TOGBankClassic_Database = { db = { global = {} } }
	return TOGBankClassic_Chat
end

--- Every Output call the module made at the levels a player actually sees.
local function loudCalls()
	local loud = {}
	for _, call in ipairs(TOGBankClassic_Output.calls) do
		if call.level == "Error" or call.level == "Warn" then
			loud[#loud + 1] = call
		end
	end
	return loud
end

local function loudText()
	local parts = {}
	for _, call in ipairs(loudCalls()) do
		for i = 1, call.n do parts[#parts + 1] = tostring(call[i]) end
	end
	return table.concat(parts, " ")
end

describe("LIBREQ-ALL-005: comm prefix registration", function()
	local R

	before_each(function()
		env.reset()
		-- DO NOT call wow.reset() here. The whole suite runs in ONE Lua state, and resetting the
		-- harness env from inside a spec that only needs C_ChatInfo tore out globals another
		-- module had hooked -- it reddened syncwire_spec, a different file, which is the
		-- one-spec-corrupts-a-later-spec failure that only ever reproduces in a full-suite run.
		-- Requiring env.wow installed C_ChatInfo and the enum once at load; that is enough.
		_G.C_ChatInfo = realChatInfo
		R = Enum.RegisterAddonMessagePrefixResult
		assert.is_table(R, "the harness must supply Enum.RegisterAddonMessagePrefixResult -- " ..
			"without it every assertion below would compare nil against nil and pass vacuously")
		wow.registerPrefixResult = nil
		wow.maxPrefixes = nil
		loadChat()
	end)

	after_each(function()
		wow.registerPrefixResult = nil
		wow.maxPrefixes = nil
		_G.C_ChatInfo = realChatInfo
	end)

	-- ------------------------------------------------------------------
	-- The list itself
	-- ------------------------------------------------------------------

	-- COMM_PREFIXES is deliberately NOT derived from COMM_PREFIX_DESCRIPTIONS — that is a bare
	-- global, and NS-001 is a confirmed live case of another addon overwriting one of ours, which
	-- would leave us registering nothing and silently receiving nothing. The cost of a second list
	-- is that it can drift, so this is the thing that stops it drifting.
	it("registers exactly the prefixes Constants documents, and no others", function()
		local documented, registered = {}, {}
		for prefix in pairs(COMM_PREFIX_DESCRIPTIONS) do documented[prefix] = true end
		for _, prefix in ipairs(TOGBankClassic_Chat.COMM_PREFIXES) do registered[prefix] = true end

		for prefix in pairs(documented) do
			assert.is_true(registered[prefix] or false,
				prefix .. " is described in COMM_PREFIX_DESCRIPTIONS but is never registered, so " ..
				"nothing will ever receive it")
		end
		for prefix in pairs(registered) do
			assert.is_true(documented[prefix] or false,
				prefix .. " is registered but has no COMM_PREFIX_DESCRIPTIONS entry, so the SEND " ..
				"log will print it as (Unknown)")
		end
	end)

	it("has no duplicate entries in the list", function()
		local seen = {}
		for _, prefix in ipairs(TOGBankClassic_Chat.COMM_PREFIXES) do
			assert.is_nil(seen[prefix], prefix .. " appears twice in COMM_PREFIXES")
			seen[prefix] = true
		end
	end)

	it("subscribes to every one of them on Init", function()
		local subscribed = {}
		env.stubCore({ RegisterComm = function(_, prefix) subscribed[prefix] = true end,
		               RegisterChatCommand = function() end })
		TOGBankClassic_Chat:Init()
		for _, prefix in ipairs(TOGBankClassic_Chat.COMM_PREFIXES) do
			assert.is_true(subscribed[prefix] or false,
				prefix .. " was never passed to RegisterComm, so this client cannot receive it")
		end
	end)

	-- ------------------------------------------------------------------
	-- The verdicts
	-- ------------------------------------------------------------------

	-- THE ONE THAT MATTERS. See the header: this is the every-login case.
	it("says NOTHING when the client reports DuplicatePrefix", function()
		wow.registerPrefixResult = R.DuplicatePrefix
		TOGBankClassic_Chat:VerifyCommPrefixes()
		assert.equal(0, #loudCalls(),
			"DuplicatePrefix is what AceComm registering first produces for every prefix on every " ..
			"login. Warning on it fires eleven times a session and trains the player to ignore the " ..
			"channel a real MaxPrefixes refusal has to arrive on")
	end)

	it("says nothing when every prefix registers cleanly", function()
		wow.registerPrefixResult = R.Success
		TOGBankClassic_Chat:VerifyCommPrefixes()
		assert.equal(0, #loudCalls())
	end)

	it("reports loudly when the client is out of prefix slots", function()
		wow.registerPrefixResult = R.MaxPrefixes
		TOGBankClassic_Chat:VerifyCommPrefixes()
		assert.is_true(#loudCalls() > 0,
			"a client at its prefix cap cannot receive guild bank data at all, and nothing else " ..
			"in the addon would ever say so -- sync simply stops")
		local text = loudText()
		assert.is_truthy(text:find("togbank-d4", 1, true),
			"the message must name the prefixes that were refused, not merely that something was")
	end)

	it("reports loudly when the client rejects a prefix as malformed", function()
		wow.registerPrefixResult = R.InvalidPrefix
		TOGBankClassic_Chat:VerifyCommPrefixes()
		assert.is_true(#loudCalls() > 0)
		assert.is_truthy(loudText():find("togbank-d4", 1, true))
	end)

	-- Success is 0 and 0 is truthy, so a guard written as `if not register(p)` passes this file's
	-- clean case and this one identically. Asserting the SUCCESS path stays quiet while the
	-- MaxPrefixes path speaks is what separates a real guard from one that cannot fire.
	it("distinguishes the two by VALUE, not by truthiness", function()
		wow.registerPrefixResult = R.Success
		TOGBankClassic_Chat:VerifyCommPrefixes()
		local afterSuccess = #loudCalls()

		env.stubOutput()
		wow.registerPrefixResult = R.MaxPrefixes
		TOGBankClassic_Chat:VerifyCommPrefixes()
		local afterFailure = #loudCalls()

		assert.equal(0, afterSuccess)
		assert.is_true(afterFailure > 0,
			"both Success (0) and MaxPrefixes (3) are truthy, so a guard that tests truthiness " ..
			"treats them the same and this is the assertion that catches it")
	end)

	-- The moment debug output matters most is when something failed to load. A missing API must
	-- degrade to silence, not to an error inside Init.
	it("degrades quietly when the client has no C_ChatInfo at all", function()
		_G.C_ChatInfo = nil
		assert.has_no_error(function() TOGBankClassic_Chat:VerifyCommPrefixes() end)
		assert.equal(0, #loudCalls())
	end)
end)
