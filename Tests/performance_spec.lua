-- Performance counters (PERF-013).
--
-- Modules/Performance.lua had NO spec at all until this file, and it is where a peer review found
-- 17 of 21 declared counters unreachable -- four of them killed by INV2 step 10, which deleted the
-- functions and left the counters behind. The two defects were opposite halves of one design:
--
--   * a DECLARED key with no caller is a measurement that can never happen, persisted into the
--     TOGBankClassic_PerfMetrics SavedVariable and handed to GetCurrentStats callers as a zero that
--     is indistinguishable from "it ran and cost nothing";
--   * an UNDECLARED name was SILENTLY DROPPED, because the declared key doubled as an allow-list --
--     so instrumentation could not follow the code, and the V2 tuple path that replaced the deleted
--     operations structurally could not be measured at all.
--
-- Both failed silently, which is why neither was found by running the addon. The scan at the bottom
-- is the half that generalises: it fails when a counter is declared with no site that records it.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Perf

--- Stand up a session the way the addon does at load.
local function newSession()
	TOGBankClassic_PerfEnabled = true
	TOGBankClassic_PerfMetrics = {}
	Perf:Initialize()
	return Perf.currentSession
end

describe("Performance counters", function()
	before_each(function()
		env.reset()
		env.stubOutput()
		env.loadFile("Modules/Performance.lua")
		Perf = TOGBankClassic_Performance
	end)

	after_each(function()
		TOGBankClassic_PerfEnabled = nil
		TOGBankClassic_PerfMetrics = nil
	end)

	describe("recording", function()
		it("counts a declared event", function()
			local session = newSession()
			Perf:RecordEvent("GUILD_ROSTER_UPDATE")
			Perf:RecordEvent("GUILD_ROSTER_UPDATE")
			assert.equal(2, session.events.GUILD_ROSTER_UPDATE)
		end)

		-- PERF-013, and the reason this file exists. The old gate was
		-- `if self.currentSession.events[name] then` with NO else, so a name that was not already a
		-- key vanished: no count, no warning, no error, and nothing in the report to say why.
		it("creates a key for an event nobody pre-declared, rather than dropping it", function()
			local session = newSession()
			Perf:RecordEvent("BANKFRAME_CLOSED")
			assert.equal(1, session.events.BANKFRAME_CLOSED,
				"an undeclared event name was silently dropped -- instrumentation cannot follow " ..
				"the code when the declared key doubles as an allow-list (PERF-013)")
		end)

		it("creates a key for an operation nobody pre-declared, rather than dropping it", function()
			local session = newSession()
			Perf:RecordOperation("BuildTuplePayload", 12)
			assert.equal(1, session.operations.BuildTuplePayload,
				"an undeclared operation name was silently dropped (PERF-013)")
			assert.equal(12, session.timing.BuildTuplePayload,
				"the timing table has the same allow-list defect as the counter table")
		end)

		it("accumulates timing and records the longest operation", function()
			local session = newSession()
			Perf:RecordOperation("RefreshOnlineCache", 5)
			Perf:RecordOperation("RefreshOnlineCache", 20)
			assert.equal(25, session.timing.RefreshOnlineCache)
			assert.equal("RefreshOnlineCache", session.peaks.longestOperation.name)
			assert.equal(20, session.peaks.longestOperation.duration)
		end)

		it("counts an operation called without a duration", function()
			local session = newSession()
			Perf:RecordOperation("RefreshOnlineCache")
			assert.equal(1, session.operations.RefreshOnlineCache)
			assert.equal(0, session.timing.RefreshOnlineCache,
				"a duration-less call must not invent timing")
		end)

		it("records nothing at all while profiling is off", function()
			local session = newSession()
			TOGBankClassic_PerfEnabled = false
			Perf:RecordEvent("GUILD_ROSTER_UPDATE")
			Perf:RecordOperation("RefreshOnlineCache", 5)
			assert.equal(0, session.events.GUILD_ROSTER_UPDATE)
			assert.equal(0, session.operations.RefreshOnlineCache)
		end)
	end)

	describe("Track", function()
		it("returns the wrapped function's values and records the call", function()
			local session = newSession()
			local a, b = Perf:Track("BuildTuplePayload", function() return "one", 2 end)
			assert.equal("one", a)
			assert.equal(2, b)
			assert.equal(1, session.operations.BuildTuplePayload,
				"Track is the one-line way to instrument a path; before PERF-013 it measured " ..
				"nothing at all unless the name was already declared")
		end)

		it("still returns the values when profiling is off", function()
			newSession()
			TOGBankClassic_PerfEnabled = false
			local a, b = Perf:Track("BuildTuplePayload", function() return "one", 2 end)
			assert.equal("one", a)
			assert.equal(2, b)
		end)
	end)

	describe("GetCurrentStats", function()
		it("returns nil rather than erroring with no session", function()
			Perf.currentSession = nil
			assert.is_nil(Perf:GetCurrentStats())
		end)

		it("reports a rate and an average for a recorded operation", function()
			newSession()
			Perf:RecordOperation("RefreshOnlineCache", 10)
			Perf:RecordOperation("RefreshOnlineCache", 30)
			local stats = Perf:GetCurrentStats()
			assert.equal(2, stats.operations.RefreshOnlineCache.count)
			assert.equal(20, stats.operations.RefreshOnlineCache.avgMs)
			assert.equal(40, stats.operations.RefreshOnlineCache.totalMs)
		end)
	end)

	-- ------------------------------------------------------------------
	-- The class guard
	-- ------------------------------------------------------------------
	--
	-- A declared counter with no recording site is what produced the 17 dead keys, and it is
	-- invisible in every other way: nothing errors, nothing is logged, and the report simply prints
	-- a plausible zero. Deleting today's dead keys fixes the instance; this fixes the class.
	--
	-- Scope note, deliberately narrow: this checks that every DECLARED name is RECORDED somewhere.
	-- The converse -- that everything worth measuring is measured -- is not checkable and is not
	-- claimed.
	describe("every declared counter has a site that records it", function()
		--- Names passed as a literal first argument to a recording call, across shipped source.
		local function recordedNames()
			local names = {}
			for _, path in ipairs(env.shippedModules()) do
				local src = env.readFile(path)
				for name in src:gmatch('Record[EO][%a]-%(%s*"([%w_]+)"') do names[name] = path end
				for name in src:gmatch('Track%(%s*"([%w_]+)"') do names[name] = path end
			end
			return names
		end

		--- The three declared tables, read out of a live session rather than re-parsed from source.
		local function declared()
			local session = newSession()
			return {
				events     = session.events,
				operations = session.operations,
				timing     = session.timing,
			}
		end

		-- ANTI-VACUOUS. The scan above is a pattern over source text, and a pattern that matches
		-- nothing passes every assertion built on it while reading no code at all -- which is how a
		-- guard in this suite was found green while covering 2 of 7 sites. If this fails, the scan
		-- is broken and every result below it is worthless, whatever they say.
		it("finds the recording sites at all", function()
			local names = recordedNames()
			assert.is_not_nil(names.RefreshOnlineCache,
				"the source scan found no RecordOperation(\"RefreshOnlineCache\") -- it is called " ..
				"from Guild.lua twice, so the scan is broken, not the code")
			assert.is_not_nil(names.GUILD_ROSTER_UPDATE,
				"the source scan found no RecordEvent(\"GUILD_ROSTER_UPDATE\") -- called from " ..
				"Events.lua, so the scan is broken")
		end)

		it("declares no counter that nothing records", function()
			local names, dead = recordedNames(), {}
			for tableName, counters in pairs(declared()) do
				for counter in pairs(counters) do
					if not names[counter] then
						dead[#dead + 1] = tableName .. "." .. counter
					end
				end
			end
			table.sort(dead)
			assert.same({}, dead,
				"these counters are declared but never recorded, so they are persisted to " ..
				"SavedVariables and reported as a zero that reads as 'it ran and cost nothing' " ..
				"(PERF-013). Delete the key, or instrument the path it was meant to measure.")
		end)
	end)
end)
