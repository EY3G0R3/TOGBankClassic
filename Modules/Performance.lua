-- Performance Metrics Tracking
-- Tracks event frequency, operation timing, and resource usage for diagnostic purposes

TOGBankClassic_Performance = {}
local Performance = TOGBankClassic_Performance

-- Initialize performance metrics on addon load
function Performance:Initialize()
	if not TOGBankClassic_PerfMetrics then
		TOGBankClassic_PerfMetrics = {}
	end
	
	-- Create new session
	local sessionStart = time()
	local session = {
		sessionStart = sessionStart,
		sessionId = string.format("%s_%d", date("%Y%m%d_%H%M%S"), sessionStart),
		
		-- Event counters
		events = {
			GUILD_ROSTER_UPDATE = 0,
			PLAYER_ENTERING_WORLD = 0,
			CHAT_MSG_ADDON = 0,
			MAIL_INBOX_UPDATE = 0,
			BANKFRAME_OPENED = 0,
			BANKFRAME_CLOSED = 0,
		},
		
		-- Operation counters
		operations = {
			RefreshOnlineCache = 0,
			InvalidateBanksCache = 0,
			GetBanks = 0,
			ComputeDelta = 0,
			ApplyDelta = 0,
			ReceiveAltData = 0,
			ReceiveRequestsData = 0,
			NormalizeRequestList = 0,
			ItemHighlightUpdate = 0,
		},
		
		-- Timing data (cumulative ms)
		timing = {
			RefreshOnlineCache = 0,
			GetBanks = 0,
			ComputeDelta = 0,
			ApplyDelta = 0,
			NormalizeRequestList = 0,
			ItemHighlightUpdate = 0,
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
	
	-- Keep only last 10 sessions
	while #TOGBankClassic_PerfMetrics > 10 do
		table.remove(TOGBankClassic_PerfMetrics, 1)
	end
	
	-- Store reference to current session
	self.currentSession = session
	self.sessionStartTime = GetTime()
end

-- Track an event firing
function Performance:RecordEvent(eventName)
	if not self.currentSession then return end
	if self.currentSession.events[eventName] then
		self.currentSession.events[eventName] = self.currentSession.events[eventName] + 1
	end
end

-- Track an operation execution with timing
function Performance:RecordOperation(operationName, durationMs)
	if not self.currentSession then return end
	
	if self.currentSession.operations[operationName] then
		self.currentSession.operations[operationName] = self.currentSession.operations[operationName] + 1
	end
	
	if durationMs and self.currentSession.timing[operationName] then
		self.currentSession.timing[operationName] = self.currentSession.timing[operationName] + durationMs
		
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

-- Helper to wrap a function with timing
function Performance:WrapFunction(operationName, func)
	return function(...)
		local startTime = debugprofilestop()
		local results = {func(...)}
		local duration = debugprofilestop() - startTime
		self:RecordOperation(operationName, duration)
		return unpack(results)
	end
end

-- Get current session stats
function Performance:GetCurrentStats()
	if not self.currentSession then return nil end
	
	local sessionDuration = GetTime() - self.sessionStartTime
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
			perMinute = (count / sessionDuration) * 60,
		}
	end
	
	-- Calculate rates and averages for operations
	for operation, count in pairs(self.currentSession.operations) do
		local totalTime = self.currentSession.timing[operation] or 0
		stats.operations[operation] = {
			count = count,
			perMinute = (count / sessionDuration) * 60,
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
		TOGBankClassic_Output:Response("|cffffff00Memory:|r %.1f KB → %.1f KB (%.1f KB growth)", 
			firstMem, lastMem, lastMem - firstMem)
	end
end
