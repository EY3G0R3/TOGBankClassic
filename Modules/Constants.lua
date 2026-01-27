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

-- Debug categories for filtering
DEBUG_CATEGORY = {
	ROSTER = "ROSTER",           -- Guild roster updates, online/offline tracking
	COMMS = "COMMS",             -- All addon communication traffic
	DELTA = "DELTA",             -- Delta sync operations and computations
	SYNC = "SYNC",               -- Data synchronization operations
	CACHE = "CACHE",             -- Cache operations (guild roster cache, etc.)
	WHISPER = "WHISPER",         -- Whisper sends, skips, and online checks
	REQUESTS = "REQUESTS",       -- Request system activity and updates
	UI = "UI",                   -- UI operations, window opens/closes
	PROTOCOL = "PROTOCOL",       -- Protocol version negotiation
	DATABASE = "DATABASE",       -- Database operations, SavedVariables
	EVENTS = "EVENTS",           -- WoW event handling
	MAIL = "MAIL",               -- Mail inventory scanning and tracking
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
	["togbank-dv"] = "(Delta Version)",
	["togbank-d"] = "(Data)",
	["togbank-d2"] = "(Delta Data)",
	["togbank-d3"] = "(Data v2 - No Links)",
	["togbank-d4"] = "(Delta Data v2 - No Links)",
	["togbank-dr"] = "(Delta Range Request)",
	["togbank-dc"] = "(Delta Chain)",
	["togbank-r"] = "(Query)",
	["togbank-rr"] = "(Query Reply)",
	["togbank-state"] = "(State Summary)",
	["togbank-nochange"] = "(No Change)",
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
	DELTA_SUPPORT_THRESHOLD = 0.05, -- Use delta if >5% of online guild supports it (lowered for testing: 1 of 14 = 7.1%)

	-- Delta Chain Replay (DELTA-006)
	DELTA_HISTORY_MAX_COUNT = 10,   -- Keep last N deltas per alt (memory limit)
	DELTA_HISTORY_MAX_AGE = 3600,   -- 1 hour: purge deltas older than this
	DELTA_CHAIN_MAX_HOPS = 30,      -- Max deltas in one chain request (increased for testing)
	DELTA_CHAIN_MAX_SIZE = 5000,    -- If chain >5KB, fall back to full sync
}

-- Feature flags (for easy enable/disable during development/testing)
FEATURES = {
	DELTA_ENABLED = true,           -- Enable delta sync protocol
	FORCE_DELTA_SYNC = false,       -- Force delta sync (bypass thresholds) for testing
	FORCE_FULL_SYNC = false,        -- Force full sync (disable delta) for testing

	-- Protocol selection for v0.8.0+ (user-configurable)
	PROTOCOL_MODE = "AUTO",         -- "AUTO", "LEGACY_ONLY", "NEW_ONLY"
}

-- Protocol mode descriptions
PROTOCOL_MODES = {
	AUTO = {
		name = "Auto (Recommended)",
		desc = "Sends both legacy (with Links) and new (without Links) formats. Compatible with all versions. Temporary bandwidth cost during migration.",
		sendLegacy = true,
		sendNew = true,
	},
	LEGACY_ONLY = {
		name = "Legacy Only",
		desc = "Only sends legacy format with Links. Maximum compatibility with v0.6.x/v0.7.0. Higher bandwidth always.",
		sendLegacy = true,
		sendNew = false,
	},
	NEW_ONLY = {
		name = "New Protocol Only",
		desc = "Only sends new format without Links. Requires all guild members on v0.8.0+. Maximum bandwidth savings (5-7KB per sync).",
		sendLegacy = false,
		sendNew = true,
	},
}