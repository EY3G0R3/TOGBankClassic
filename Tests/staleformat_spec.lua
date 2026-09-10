-- The mixed-version migration warning: a v1.4.0 client tells you WHICH banker is still on the
-- old wire format, and tells you ONCE.
--
-- WHY THIS MATTERS AT RELEASE. The 2026-09-09 directive removed backwards compatibility on the
-- wire, so a v1.4.0 client DROPS every legacy inventory payload. That is correct and deliberate,
-- but it means an early upgrader sees banker data quietly stop arriving -- indistinguishable from
-- the banker having no items, from the sync never being requested, and from a bug in the new
-- path. The warning is what turns that from a support ticket into a nudge, so it is load-bearing
-- rather than cosmetic.
--
-- AND IT MUST NOT FLOOD. The drop branch is reached on EVERY legacy payload, not once per client:
-- an unmigrated banker re-broadcasts on every scan and answers every P2P query. Unlatched, that is
-- a user-visible line each time, worst exactly when a guild is mid-migration and most bankers are
-- still old. Measured against a real guild during the v1.4.0 rollout: 9 of 11 online clients
-- unmigrated, several of them bankers.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER   = "Oldbanker-Testrealm"
local NOBODY   = "Randomguy-Testrealm"

-- DECLARED NARROWING: a pass-through envelope, not the real checksum framing. This file is about
-- WHICH SENDER earns a warning and HOW OFTEN, not about serialization; `syncwire_spec` drives the
-- real envelope end to end.
--
-- It boxes the table behind a STRING token rather than returning the table itself, because
-- `OnCommReceived` takes `#message` on some paths -- handing it a table would make this fixture
-- fail for a reason that has nothing to do with the behaviour under test.
--
-- Supplied explicitly because `env.stubCore` provides only `GetArgs`. Relying on a Core left
-- behind by an earlier spec file would make this file pass or fail depending on suite ORDER,
-- which is the class of false green the whole suite is written to avoid.
local boxes = {}
local function stubEnvelope()
	return {
		SerializeWithChecksum = function(_, t)
			local key = "BOXED-" .. tostring(#boxes + 1)
			boxes[#boxes + 1] = t
			boxes[key] = t
			return key
		end,
		DeserializeWithChecksum = function(_, m)
			local t = boxes[m]
			if not t then return false, "unknown token" end
			return true, t
		end,
	}
end

local function loadChat()
	env.stubOutput()
	env.loadModules({ "Modules/Constants.lua", "Modules/Switches.lua", "Modules/Chat.lua" })
	env.stubCore(stubEnvelope())

	TOGBankClassic_Database = { db = { global = {} } }

	-- The receive path consults the roster for authorisation and for "is this a banker". Only the
	-- banker answer steers the branch under test; the rest is the minimum to reach it.
	TOGBankClassic_Guild = {
		Info = { name = "Testguild", alts = {} },
		GetPlayer      = function() return "Me-Testrealm" end,
		NormalizeName  = function(_, n) return n end,
		IsBank         = function(_, n) return n == BANKER end,
		IsAltDataAllowed = function() return true end,
		ConsumePendingSync = function() return false end,
		-- Every inbound message marks its sender online before any prefix branch runs, so this
		-- is on the path to EVERY receive test, not just this one.
		UpdateOnlineMember = function() end,
	}

	-- Wire must classify the payload as NOT V2, which is the whole premise: this spec is about
	-- what happens to a payload the addon no longer speaks.
	TOGBankClassic_Inventory_Wire = { isV2 = function() return false end }

	return TOGBankClassic_Chat
end

--- Deliver one legacy inventory payload from `sender`.
local function deliverLegacy(sender, altName)
	local body = TOGBankClassic_Core:SerializeWithChecksum({
		type = "alt-delta",
		name = altName or "Someone-Testrealm",
	})
	TOGBankClassic_Chat:OnCommReceived("togbank-d4", body, "WHISPER", sender)
end

--- How many user-visible Warn calls were captured.
local function warnCount()
	local n = 0
	for _, c in ipairs(TOGBankClassic_Output.calls or {}) do
		if c.level == "Warn" then n = n + 1 end
	end
	return n
end

describe("the stale wire-format warning", function()
	before_each(function() env.reset(); loadChat() end)

	-- The diagnostic itself. Without it the drop is silent, which is the state this branch's own
	-- comment calls indistinguishable from four other causes.
	it("names the banker still speaking the old format", function()
		deliverLegacy(BANKER)
		assert.equal(1, warnCount(),
			"a legacy payload from a BANKER produced no user-visible warning, so the commonest " ..
			"mixed-version support question -- 'why can't I see their bank?' -- has no answer")
	end)

	-- THE REGRESSION THIS FILE EXISTS FOR. Latched per sender, so repeated payloads from one
	-- unmigrated banker cost exactly one line.
	it("warns ONCE however many payloads that banker sends", function()
		for _ = 1, 25 do deliverLegacy(BANKER) end
		assert.equal(1, warnCount(),
			"the warning is not latched -- 25 legacy payloads from one banker produced " ..
			warnCount() .. " user-visible lines, which is a chat flood mid-migration")
	end)

	-- The latch must be per person, not a single global "already warned" flag: a guild migrating
	-- has several unmigrated bankers and the player needs to know about each.
	it("warns separately for each unmigrated banker", function()
		local OTHER = "Otherbanker-Testrealm"
		TOGBankClassic_Guild.IsBank = function(_, n) return n == BANKER or n == OTHER end
		deliverLegacy(BANKER)
		deliverLegacy(OTHER)
		assert.equal(2, warnCount(),
			"a second unmigrated banker was silenced by the first one's latch, so the player " ..
			"is told to chase one person and not the other")
	end)

	it("stays latched per banker when several are interleaved", function()
		local OTHER = "Otherbanker-Testrealm"
		TOGBankClassic_Guild.IsBank = function(_, n) return n == BANKER or n == OTHER end
		for _ = 1, 10 do deliverLegacy(BANKER); deliverLegacy(OTHER) end
		assert.equal(2, warnCount(), "interleaving defeated the per-sender latch")
	end)

	-- A non-banker on an old version is not the player's problem: their payload is dropped, but
	-- there is nothing to chase and nothing they hold that anyone is waiting on.
	it("says nothing for a non-banker", function()
		deliverLegacy(NOBODY)
		assert.equal(0, warnCount(),
			"warned about a non-banker's old version, which the player can neither use nor act on")
	end)

	-- The debug line is unconditional and must NOT be latched -- a diagnostic log is exactly where
	-- you want to see every occurrence, and it is opt-in so it cannot spam anyone.
	it("still records every dropped payload in the debug log", function()
		for _ = 1, 5 do deliverLegacy(BANKER) end
		local debugLines = 0
		for _, c in ipairs(TOGBankClassic_Output.calls or {}) do
			if c.level == "Debug" then
				for i = 1, (c.n or 0) do
					if type(c[i]) == "string" and c[i]:find("discarded a legacy", 1, true) then
						debugLines = debugLines + 1
					end
				end
			end
		end
		assert.equal(5, debugLines,
			"the DEBUG record was latched along with the warning -- a diagnostic log must show " ..
			"every occurrence, and it is opt-in so it cannot flood anyone")
	end)
end)
