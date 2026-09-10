-- P2P-026 / AUDIT finding 24, SECOND HALF — a per-alt timeout timer must not outlive the request
-- that armed it.
--
-- Finding 24's remedy was `C_Timer.NewTimer` at three sites, so the stored handle stops being nil
-- and `:Cancel()` finally does something. That closed the path where a peer ACKs. It did NOT close
-- the path where nobody answers at all: `BroadcastP2PRequest` has no in-flight guard, so a second
-- request for the same alt inside the window armed a second timer and OVERWROTE the stored handle.
-- The first handle was dropped on the floor with nothing left that could reach it, and the first
-- timer then fired against the SECOND request's state — clearing its pending entry and expected
-- hash, recording a banker fallback, and abandoning a sync that had done nothing wrong.
--
-- That is why these examples drive TWO requests and advance past only the FIRST deadline. A single
-- request cannot show the defect: every callback re-checks state, so an orphaned timer is harmless
-- for the request that armed it. The harm is only ever across requests.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local ALT = "Banker-Testrealm"

local function loadGuild()
	env.stubOutput()
	env.loadFile("Modules/Constants.lua")
	env.loadFile("Modules/Guild.lua")
	return TOGBankClassic_Guild
end

--- Everything BroadcastP2PRequest reaches outside Guild.lua. P2PSession is deliberately left nil:
--- the timeout callback guards on it, and leaving it out keeps these examples about the timer
--- rather than about session advancement.
local function stubCollaborators()
	local fallbacks = { n = 0 }
	TOGBankClassic_Core = {
		SerializeWithChecksum = function(_, t) return "ser:" .. tostring(t and t.type) end,
		SendCommMessage = function(_, prefix, data, dist)
			env.sent[#env.sent + 1] = { prefix = prefix, data = data, dist = dist }
		end,
	}
	TOGBankClassic_Database = {
		RecordP2PRequestBroadcast = function() end,
		RecordP2PBankerFallback   = function() fallbacks.n = fallbacks.n + 1 end,
	}
	TOGBankClassic_P2PSession = nil
	return fallbacks
end

describe("P2P-026: a second request for the same alt cancels the first request's timer", function()
	local Guild, fallbacks

	before_each(function()
		env.reset()
		Guild = loadGuild()
		fallbacks = stubCollaborators()
		Guild.Info = { name = "Testguild", alts = {} }
		Guild.pendingP2PRequests, Guild.pendingP2PTimeouts = {}, {}
		Guild.pendingP2PFallbackTimeouts, Guild.pendingAltRequests = {}, {}
		Guild.expectedHashes, Guild.expectedHashUpdatedAt = {}, {}
	end)

	--- Two requests, then advance past the FIRST one's deadline only. Pre-fix this is where the
	--- second request died.
	local function twoRequestsThenFirstDeadline()
		Guild:BroadcastP2PRequest(ALT, 111, 100, nil)
		env.advance(2)                       -- still inside the 5s window
		Guild:BroadcastP2PRequest(ALT, 222, 200, nil)
		env.advance(3.5)                     -- t=5.5: request 1's timer was due at t=5
	end

	it("leaves the second request pending when the first request's deadline passes", function()
		twoRequestsThenFirstDeadline()
		assert.is_not_nil(Guild.pendingP2PRequests[ALT])
	end)

	it("keeps the second request's expected hash rather than the first's teardown clearing it", function()
		twoRequestsThenFirstDeadline()
		assert.equal(222, Guild.expectedHashes[ALT])
		assert.equal(200, Guild.expectedHashUpdatedAt[ALT])
	end)

	it("records no banker fallback for a request that has not timed out", function()
		twoRequestsThenFirstDeadline()
		assert.equal(0, fallbacks.n)
	end)

	it("leaves exactly one timer live for the alt", function()
		Guild:BroadcastP2PRequest(ALT, 111, 100, nil)
		env.advance(2)
		Guild:BroadcastP2PRequest(ALT, 222, 200, nil)
		-- pendingTimerCount excludes cancelled and already-fired timers, so this is direct evidence
		-- the first Cancel() did something rather than silently no-op'ing.
		assert.equal(1, env.pendingTimerCount())
	end)

	--- The other half, and the one that stops the fix from being "cancel everything". Cancelling
	--- the orphan must not cancel the live request's own timeout — a request that genuinely gets no
	--- answer still has to fall back.
	it("still times out the second request at its OWN deadline", function()
		twoRequestsThenFirstDeadline()
		env.advance(2)                       -- t=7.5: request 2 was armed at t=2, due at t=7
		assert.is_nil(Guild.pendingP2PRequests[ALT])
		assert.equal(1, fallbacks.n)
		assert.is_nil(Guild.expectedHashes[ALT])
	end)

	it("does not disturb a different alt's timer", function()
		Guild:BroadcastP2PRequest(ALT, 111, 100, nil)
		Guild:BroadcastP2PRequest("Other-Testrealm", 333, 300, nil)
		env.advance(2)
		Guild:BroadcastP2PRequest(ALT, 222, 200, nil)
		env.advance(3.5)                     -- t=5.5: BOTH original deadlines have passed
		-- The other alt was never re-requested, so its timer was never replaced and must have fired
		-- normally. Only the re-requested alt is protected.
		assert.is_not_nil(Guild.pendingP2PRequests[ALT])
		assert.is_nil(Guild.pendingP2PRequests["Other-Testrealm"])
		assert.equal(1, fallbacks.n)
	end)
end)

describe("Guild:ArmAltTimeout", function()
	local Guild

	before_each(function()
		env.reset()
		Guild = loadGuild()
		Guild.pendingP2PTimeouts, Guild.pendingP2PFallbackTimeouts = nil, nil
	end)

	it("creates the registry when it does not exist yet", function()
		Guild:ArmAltTimeout("pendingP2PFallbackTimeouts", ALT, 15, function() end)
		assert.is_table(Guild.pendingP2PFallbackTimeouts)
		assert.is_not_nil(Guild.pendingP2PFallbackTimeouts[ALT])
	end)

	it("stores the NEW handle, not the one it replaced", function()
		local first = Guild:ArmAltTimeout("pendingP2PTimeouts", ALT, 5, function() end)
		local second = Guild:ArmAltTimeout("pendingP2PTimeouts", ALT, 5, function() end)
		assert.are_not.equal(first, second)
		assert.equal(second, Guild.pendingP2PTimeouts[ALT])
	end)

	it("fires only the surviving callback", function()
		local fired = {}
		Guild:ArmAltTimeout("pendingP2PTimeouts", ALT, 5, function() fired[#fired + 1] = "first" end)
		Guild:ArmAltTimeout("pendingP2PTimeouts", ALT, 5, function() fired[#fired + 1] = "second" end)
		env.flushTimers()
		assert.same({ "second" }, fired)
	end)

	it("keeps the two registries independent", function()
		Guild:ArmAltTimeout("pendingP2PTimeouts", ALT, 5, function() end)
		Guild:ArmAltTimeout("pendingP2PFallbackTimeouts", ALT, 15, function() end)
		assert.equal(2, env.pendingTimerCount())
	end)
end)

--- Source guard. The examples above pin the BEHAVIOUR; this pins the SHAPE, because the way
--- finding 24 survived the first time was that no spec reached Chat.lua or Guild.lua at all and a
--- hand-written assignment reads exactly like a correct one. Any future arm site that assigns a
--- handle into these registries directly bypasses the cancel and is a reintroduction.
describe("the timeout registries are only ever written through ArmAltTimeout", function()
	local REGISTRIES = { "pendingP2PTimeouts", "pendingP2PFallbackTimeouts" }
	local FILES = { "Modules/Chat.lua", "Modules/Guild.lua" }

	--- Lines, numbered correctly. `gmatch("[^\n]*")` yields an EMPTY match between every pair of
	--- lines, so a counter driven by it reports roughly double the real line number -- and a guard
	--- whose entire output is a `file:line` only reveals that once it fires.
	local function lines(path)
		local fh = assert(io.open(path, "r"), "could not open " .. path)
		local src = fh:read("*a")
		fh:close()
		local out = {}
		for line in (src .. "\n"):gmatch("(.-)\r?\n") do
			out[#out + 1] = line
		end
		return out
	end

	it("assigns nothing but nil into them outside the helper", function()
		local offenders = {}
		for _, path in ipairs(FILES) do
			for lineNo, line in ipairs(lines(path)) do
				-- Code only. A comment describing the old assignment is not an assignment, and both
				-- files now carry exactly such a comment explaining P2P-026.
				local isComment = line:match("^%s*%-%-") ~= nil
				for _, registry in ipairs(isComment and {} or REGISTRIES) do
					-- Only INDEXED assignments. `ArmAltTimeout` writes through a local `registry`
					-- upvalue and the module-level declarations have no index, so neither matches.
					local rhs = line:match(registry .. "%[[^%]]*%]%s*=%s*([%w_]+)")
					if rhs and rhs ~= "nil" then
						offenders[#offenders + 1] = path .. ":" .. lineNo .. " -> " .. rhs
					end
				end
			end
		end
		assert.same({}, offenders)
	end)
end)
