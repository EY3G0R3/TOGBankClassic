ADOPTION_STATUS = {
	ADOPTED = "adopted",
	STALE = "stale",
	INVALID = "invalid",
	UNAUTHORIZED = "unauthorized",
	IGNORED = "ignored",
}

-- Timer intervals (in seconds)
TIMER_INTERVALS = {
	ROSTER_AND_ALT_SYNC = 600,      -- 10 minutes: full roster/alt data sync
	VERSION_BROADCAST = 180,        -- 3 minutes: lightweight version ping
	ALT_DATA_QUEUE_RETRY = 5,       -- 5 seconds: queue reprocessing delay
}

-- Log levels (lower = more verbose)
LOG_LEVEL = {
	DEBUG = 1,       -- development/troubleshooting details
	INFO = 2,        -- sync status, normal operations
	WARN = 3,        -- something unexpected but recoverable
	ERROR = 4,       -- something failed
	RESPONSE = 5,    -- response to user commands (always shown)
}

-- Request log compaction settings
REQUEST_LOG = {
	EXPIRY_SECONDS = 30 * 24 * 60 * 60,      -- 30 days: completed/cancelled requests removed after this
	RETENTION_SECONDS = 30 * 24 * 60 * 60,   -- 30 days: log entries older than this may be pruned
	MAX_ENTRIES = 2000,                       -- max log entries to keep after time-based pruning
	PRUNE_INTERVAL = 300,                     -- 5 minutes: minimum interval between automatic prunes
}

-- Communication prefix descriptions for debug logging
COMM_PREFIX_DESCRIPTIONS = {
	["togbank-v"] = "(Version)",
	["togbank-d"] = "(Data)",
	["togbank-d2"] = "(Delta Data)",
	["togbank-dr"] = "(Delta Range Request)",
	["togbank-dc"] = "(Delta Chain)",
	["togbank-r"] = "(Query)",
	["togbank-h"] = "(Hello)",
	["togbank-hr"] = "(Hello Reply)",
	["togbank-s"] = "(Share)",
	["togbank-sr"] = "(Share Reply)",
	["togbank-w"] = "(Wipe)",
	["togbank-wr"] = "(Wipe Reply)",
}

-- Protocol version and capabilities
PROTOCOL = {
	VERSION = 2,                    -- Current protocol version (bump for breaking changes)
	SUPPORTS_DELTA = true,          -- This client supports delta updates
	MIN_DELTA_SIZE_RATIO = 0.3,     -- Only use delta if <30% of full sync size
	DELTA_SNAPSHOT_MAX_AGE = 3600,  -- 1 hour: snapshots older than this are invalid
	DELTA_SUPPORT_THRESHOLD = 0.1,  -- Use delta if >10% of online guild supports it (lowered for testing)
	
	-- Delta Chain Replay (DELTA-006)
	DELTA_HISTORY_MAX_COUNT = 10,   -- Keep last N deltas per alt (memory limit)
	DELTA_HISTORY_MAX_AGE = 3600,   -- 1 hour: purge deltas older than this
	DELTA_CHAIN_MAX_HOPS = 10,      -- Max deltas in one chain request
	DELTA_CHAIN_MAX_SIZE = 5000,    -- If chain >5KB, fall back to full sync
}

-- Feature flags (for easy enable/disable during development/testing)
FEATURES = {
	DELTA_ENABLED = true,           -- Enable delta sync protocol
	FORCE_FULL_SYNC = false,        -- Force full sync (disable delta) for testing
}
