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
	VERSION_BROADCAST = 600,        -- 10 minutes: lightweight version ping (reduced for large guild congestion)
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
	BANK = "BANK",               -- Bank inventory aggregation and recalculation
	MAIL = "MAIL",               -- Mail inventory scanning and tracking
	ITEM = "ITEM",               -- Item loading, validation, and processing
	QUERIES = "QUERIES",         -- P2P query/response decisions and hash matching
	P2P = "P2P",                 -- P2P session manager: collect window, dispatch, handshake
}

-- Debug sub-tags: optional second argument to Output:Debug() for per-feature filtering.
-- Signature: Output:Debug("CATEGORY", "TAG", fmt, ...)  or  Output:Debug("CATEGORY", fmt, ...)
-- If a tag is supplied and matches a key in this table, only that tag's toggle gates it.
-- If no tag is supplied (or the string is not a known tag), the category master switch gates it.
-- nil entry in debugTags DB = tag is ALLOWED by default (opt-out model; new tags auto-show).
DEBUG_TAGS = {
	P2P = {
		OFFER     = "hash-offer send / receive",
		DISPATCH  = "session creation, peer selection, collect-window fallbacks (no response after timeout)",
		HANDSHAKE = "sync-accept/busy, state-summary exchange, RespondToStateSummary decisions, no-change replies",
		COMPLETE  = "data delivered, session COMPLETE/FAILED/delivery-timeout, queue slot release",
		["BROADCAST"] = "P2P hash-broadcast sent to guild channel (waiting for peers)",
		["RESPOND"]   = "peer sending data in response to a P2P request (queue progress)",
	},
	PROTOCOL = {
		["HLR"]               = "hash-list-reply processing",
		["HLR-COMPARE"]       = "per-alt hash comparison decisions (skip / mismatch / pending) - high volume",
		["VERSION-BROADCAST"] = "version broadcast processing",
		["ALT-REQUEST"]       = "alt-request send / receive decisions",
		["HASH-SKIP"]         = "hash comparison skip paths",
		["MAIL-012"]          = "MAIL-012 diagnostic traces",
		["DELTA-014"]         = "DELTA-014 diagnostic traces",
	},
	SYNC = {
		["HASH-MATCH"]      = "hash comparison decisions",
		["HASH-CORRECTION"] = "hash field auto-correction",
		["RECEIVE"]         = "full alt data receive / sanitize",
		["MERGE"]           = "request log merge decisions",
		["PROGRESS"]        = "banker data sync progress counters",
	},
	DELTA = {
		APPLY        = "applying deltas to local state",
		BUILD        = "constructing deltas",
		VALIDATE     = "delta validation / error recovery",
		["FAST-FILL"] = "fast-fill request count and missing-alt trigger",
	},
	ROSTER = {
		ONLINE  = "member online / offline events",
		REFRESH = "GuildRoster() refresh cycles",
	},
	REQUESTS = {
		RECEIVE = "incoming request data",
		SEND    = "outgoing request data",
		INDEX   = "index sync operations",
		PROTO2  = "togbank-ri / togbank-rd2 compact protocol (send + receive)",
	},
}

-- Request storage settings
REQUEST_LOG = {
	EXPIRY_SECONDS = 30 * 24 * 60 * 60,      -- 30 days: completed/cancelled requests and tombstones removed after this
	PRUNE_INTERVAL = 300,                     -- 5 minutes: minimum interval between automatic prunes
}

-- Request sync throttling settings
REQUESTS_SYNC = {
	-- NOTE: Short values for quick testing; production values should be higher.
	INDEX_QUERY_COOLDOWN = 60,         -- seconds between index queries (global and per-sender)
	INDEX_INFLIGHT_TIMEOUT = 180,      -- seconds before in-flight index sync is considered stale (must exceed max batch sequence: ceil(requests/BATCH_SIZE) * BATCH_DELAY)
	REQUESTS_BY_ID_BATCH_SIZE = 50,    -- max IDs per by-id query (prevents throttle on large syncs)
	REQUESTS_BY_ID_BATCH_DELAY = 5,    -- seconds between batches (lets peer respond before next batch arrives)
	-- Responding to incoming requests-by-id queries (queriedRequestsMap drain)
	RESPOND_BY_ID_BATCH_SIZE     = 50,   -- max IDs to resolve and send per drain tick
	RESPOND_BY_ID_DRAIN_INTERVAL = 1,    -- seconds between drain ticks
	RESPOND_BY_ID_DRAIN_BACKOFF  = 2,    -- seconds to wait when CTL is backlogged
	RESPOND_BY_ID_CTL_THRESHOLD  = 500,  -- pause sending when CTL queue depth exceeds this
	-- Responding to incoming requests-index queries (coalesced send + chunked drain)
	RESPOND_INDEX_COALESCE_DELAY  = 20,  -- seconds to wait for more queries before sending (single whisper -> guild broadcast)
	RESPOND_INDEX_CHUNK_SIZE      = 20,  -- IDs per chunk message (receiver can start querying after first chunk arrives)
	RESPOND_INDEX_CHUNK_INTERVAL  = 1,   -- seconds between chunk sends
}

-- Communication prefix descriptions for debug logging
COMM_PREFIX_DESCRIPTIONS = {
	["togbank-v"] = "(Version)",
	["togbank-dv"] = "(Delta Version)",
	["togbank-d"] = "(Data)",
	["togbank-d2"] = "(Delta Data)",
	["togbank-d3"] = "(Data v2 - No Links)",
	["togbank-d4"] = "(Delta Data v2 - No Links)",
	["togbank-r"] = "(Query)",
	["togbank-rr"] = "(Query Reply)",
	["togbank-rq"] = "(Request Query)",
	["togbank-ri"]  = "(Request Index v1)",
	["togbank-rd2"] = "(Request Data v2: single record/tombstone)",
	["togbank-rd"]  = "(Request Data: idx/by-id)",
	["togbank-rm"] = "(Request Mutations)",
	["togbank-state"] = "(State Summary)",
	["togbank-nochange"] = "(No Change)",
	["togbank-h"] = "(Hello)",
	["togbank-hr"] = "(Hello Reply)",
	["togbank-hl"] = "(Hash List Request)",
	["togbank-hlr"] = "(Hash List Reply)",
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

-- Peer-to-Peer distribution settings (PERF-005)
PEER_TO_PEER = {
	ENABLED = true,                  -- Enable P2P distribution (allows any peer with matching hash to respond)
	MIN_GUILD_SIZE = 3,              -- Only enable for guilds with >3 members
	HASH_QUERY_TIMEOUT = 5,          -- Seconds to wait for hash from banker
	PEER_RESPONSE_TIMEOUT = 5,       -- Seconds to wait for peer data
	FALLBACK_TO_BANKER = true,       -- Always fall back to banker on hash mismatch or timeout
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
