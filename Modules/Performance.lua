-- Performance Metrics Tracking
-- Tracks event frequency, operation timing, and resource usage for diagnostic purposes

TOGBankClassic_Performance = {}
local Performance = TOGBankClassic_Performance

-- Configuration
local perfMetricsMaxSessions = 10  -- Maximum number of sessions to keep
local perfMetricsMaxAge = 86400 * 30  -- 30 days in seconds

-- Garbage collect old performance metrics sessions
function Performance:GarbageCollectSessions()
	if not TOGBankClassic_PerfMetrics then return end

	local currentTime = time()
	local cutoffTime = currentTime - perfMetricsMaxAge

	local removed = 0
	for i = #TOGBankClassic_PerfMetrics, 1, -1 do
		local session = TOGBankClassic_PerfMetrics[i]
		if session.sessionStart and session.sessionStart < cutoffTime then
			table.remove(TOGBankClassic_PerfMetrics, i)
			removed = removed + 1
		end
	end

	if removed > 0 and TOGBankClassic_Output then
		TOGBankClassic_Output:Debug(string.format("[PERF] Garbage collected %d old session(s)", removed))
	end
end

-- Initialize performance metrics on addon load
function Performance:Initialize()
	-- Initialize enabled state (default to false - users can enable in options)
	if TOGBankClassic_PerfEnabled == nil then
		TOGBankClassic_PerfEnabled = false
	end

	-- Skip initialization if performance tracking is disabled
	if not TOGBankClassic_PerfEnabled then
		-- Clear any existing metrics from previous sessions when disabled
		TOGBankClassic_PerfMetrics = nil
		return
	end

	if not TOGBankClassic_PerfMetrics then
		TOGBankClassic_PerfMetrics = {}
	end

	-- Run garbage collection on initialization
	self:GarbageCollectSessions()

	-- Create new session
	local sessionStart = time()
	local session = {
		sessionStart = sessionStart,
		sessionId = string.format("%s_%d", date("%Y%m%d_%H%M%S"), sessionStart),

		-- PERF-013: these three tables list only what is ACTUALLY INSTRUMENTED, and every entry
		-- was verified by reading its call site rather than by trusting the declaration.
		--
		-- 17 of the 21 keys that used to be here were unreachable -- 13 already dead, and four
		-- (ComputeDelta, ApplyDelta in both tables, ReceiveAltData) killed by INV2 step 10, which
		-- deleted the functions and left the counters.
		--
		-- WHERE THEY LEAKED, checked rather than assumed: PrintReport does NOT print them --
		-- `if data.count > 0` at :238 and :245 skips a zero row. What did carry them is the session
		-- table pushed into the TOGBankClassic_PerfMetrics SavedVariable at :98, and GetCurrentStats,
		-- which returns every declared key with count/perMinute/avgMs of zero to any other caller.
		-- So the cost was a saved variable and an API asserting measurements that could not happen,
		-- not a chat line -- smaller than it first looks, and worth stating accurately.
		--
		-- Live sites, enumerated: RecordEvent from Events.lua:335 and :366; RecordOperation from
		-- Guild.lua:2139 and :2218. Nothing else records anything.
		events = {
			GUILD_ROSTER_UPDATE = 0,
			PLAYER_ENTERING_WORLD = 0,
		},

		operations = {
			RefreshOnlineCache = 0,
		},

		-- Timing data (cumulative ms)
		timing = {
			RefreshOnlineCache = 0,
		},

		-- Memory snapshots (in KB)
		memory = {},

		-- Peak values
		peaks = {
			eventsPerSecond = 0,
			operationsPerSecond = 0,
			longestOperation = { name = nil, duration = 0 },
		},
	}

	-- Store in global saved variables
	table.insert(TOGBankClassic_PerfMetrics, session)

	-- Keep only last N sessions (circular buffer)
	while #TOGBankClassic_PerfMetrics > perfMetricsMaxSessions do
		table.remove(TOGBankClassic_PerfMetrics, 1)
	end

	-- Store reference to current session
	self.currentSession = session
	self.sessionStartTime = GetTime()
end

-- PERF-013: the declared key is no longer an ALLOW-LIST. These three functions used to be gated on
-- `if self.currentSession.events[name] then` -- with no else -- so a name that was not already in
-- the table above was SILENTLY DROPPED: no count, no warning, no error, and no row in the report to
-- say why. That made the instrumentation unable to follow the code. Anyone wrapping the V2 tuple
-- path in Performance:Track("BuildTuplePayload", fn) got silence and a report with nothing in it.
--
-- An unknown name now CREATES its key. The trade, stated rather than hidden: a typo'd name produces
-- a spurious row instead of nothing at all. That is the better failure -- a visible wrong row gets
-- noticed, and a measurement that silently never happens does not.

-- Track an event firing
function Performance:RecordEvent(eventName)
	if not TOGBankClassic_PerfEnabled then return end
	if not self.currentSession then return end
	local events = self.currentSession.events
	events[eventName] = (events[eventName] or 0) + 1
end

-- Track an operation execution with timing
function Performance:RecordOperation(operationName, durationMs)
	if not TOGBankClassic_PerfEnabled then return end
	if not self.currentSession then return end

	local operations = self.currentSession.operations
	operations[operationName] = (operations[operationName] or 0) + 1

	if durationMs then
		self.currentSession.timing[operationName] = (self.currentSession.timing[operationName] or 0) + durationMs

		-- Track peak
		if durationMs > self.currentSession.peaks.longestOperation.duration then
			self.currentSession.peaks.longestOperation = {
				name = operationName,
				duration = durationMs,
			}
		end
	end
end

-- Take a memory snapshot
function Performance:RecordMemory(label)
	if not TOGBankClassic_PerfEnabled then return end
	if not self.currentSession then return end

	UpdateAddOnMemoryUsage()
	local memory = GetAddOnMemoryUsage("TOGBankClassic")

	table.insert(self.currentSession.memory, {
		timestamp = GetTime() - self.sessionStartTime,
		label = label,
		memoryKB = memory,
	})

	-- Keep only last 50 snapshots
	while #self.currentSession.memory > 50 do
		table.remove(self.currentSession.memory, 1)
	end
end

-- Track a function execution with timing (returns the function's return values).
--
-- PERF-013: this has NO PRODUCTION CALLER today -- both live recording sites call RecordOperation
-- directly. Kept rather than deleted because it is the one-line way to instrument a code path, and
-- until the allow-list gate above was removed it did not actually work: a name not pre-declared in
-- the session table was dropped, so wrapping anything new in it measured nothing. It works now.
-- If a later pass finds it still unused and the gate change forgotten, delete it then.
function Performance:Track(operationName, func)
	if not TOGBankClassic_PerfEnabled then
		return func()
	end

	local startTime = debugprofilestop()
	local results = {func()}
	local duration = debugprofilestop() - startTime
	self:RecordOperation(operationName, duration)
	return unpack(results)
end

-- Get current session stats
function Performance:GetCurrentStats()
	if not self.currentSession then return nil end

	local sessionDuration = GetTime() - self.sessionStartTime
	-- PERF-023 (audit finding 20): in the frame the session started, duration is 0 and every rate
	-- below divided by it -- `inf` per minute in the report. Rates over no elapsed time are 0.
	local minutes = sessionDuration > 0 and (sessionDuration / 60) or nil
	local function perMinute(count)
		return minutes and (count / minutes) or 0
	end
	local stats = {
		sessionId = self.currentSession.sessionId,
		duration = sessionDuration,
		events = {},
		operations = {},
		timing = {},
		memory = self.currentSession.memory,
		peaks = self.currentSession.peaks,
	}

	-- Calculate rates for events
	for event, count in pairs(self.currentSession.events) do
		stats.events[event] = {
			count = count,
			perMinute = perMinute(count),
		}
	end

	-- Calculate rates and averages for operations
	for operation, count in pairs(self.currentSession.operations) do
		local totalTime = self.currentSession.timing[operation] or 0
		stats.operations[operation] = {
			count = count,
			perMinute = perMinute(count),
			avgMs = count > 0 and (totalTime / count) or 0,
			totalMs = totalTime,
		}
	end

	return stats
end

-- Print performance report
function Performance:PrintReport()
	local stats = self:GetCurrentStats()
	if not stats then
		TOGBankClassic_Output:Response("No performance data available")
		return
	end

	TOGBankClassic_Output:Response("|cffffff00=== Performance Report ===|r")
	TOGBankClassic_Output:Response("Session: %s (%.1f minutes)", stats.sessionId, stats.duration / 60)

	TOGBankClassic_Output:Response("|cffffff00Events:|r")
	for event, data in pairs(stats.events) do
		if data.count > 0 then
			TOGBankClassic_Output:Response("  %s: %d (%.1f/min)", event, data.count, data.perMinute)
		end
	end

	TOGBankClassic_Output:Response("|cffffff00Operations:|r")
	for operation, data in pairs(stats.operations) do
		if data.count > 0 then
			TOGBankClassic_Output:Response("  %s: %d calls, %.2f ms avg (%.1f/min)",
				operation, data.count, data.avgMs, data.perMinute)
		end
	end

	if stats.peaks.longestOperation.name then
		TOGBankClassic_Output:Response("|cffffff00Peak:|r Longest operation: %s (%.2f ms)",
			stats.peaks.longestOperation.name, stats.peaks.longestOperation.duration)
	end

	if #stats.memory > 0 then
		local firstMem = stats.memory[1].memoryKB
		local lastMem = stats.memory[#stats.memory].memoryKB
		TOGBankClassic_Output:Response("|cffffff00Memory:|r %.1f KB -> %.1f KB (%.1f KB growth)",
			firstMem, lastMem, lastMem - firstMem)
	end
end
