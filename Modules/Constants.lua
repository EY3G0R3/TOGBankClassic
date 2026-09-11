-- NS-001: every table below is a FILE-SCOPE LOCAL, published once at the bottom of this file as
-- TOGBankClassic_Constants. None of them is a bare global any more, and that is not tidiness.
--
-- Bare globals in a WoW addon share ONE namespace with every other addon the player has installed,
-- and last writer wins. Grouper/GrouperOutput.lua:16 declares `DEBUG_CATEGORY` and :7 declares
-- `LOG_LEVEL` at file scope, and Grouper's DEBUG_CATEGORY was the one that won on the author's
-- client: `/togbank debug BANK` answered "Unknown debug category" and offered Grouper's eleven
-- (AUTOJOIN, BROWSE, CREATE, ...) instead of ours, so the BANK category could not be enabled to
-- diagnose a live sync divergence. LOG_LEVEL collided too and was harmless ONLY by coincidence --
-- both tables happened to be byte-identical (DEBUG=1..RESPONSE=5), with nothing enforcing it, so
-- either side renumbering would have silently changed the other addon's log filtering with no error.
--
-- Consumers take a file-scope local alias (`local DEBUG_CATEGORY = TOGBankClassic_Constants.DEBUG_CATEGORY`),
-- which shadows any foreign global of the same name. Publishing nothing bare also stops US clobbering
-- THEM -- the harm ran both ways. `.luacheckrc` no longer lists these as globals, so a stray bare use
-- is now an undefined-variable error rather than something that silently reads another addon's table.
local ADOPTION_STATUS = {
	ADOPTED = "adopted",
	STALE = "stale",
	INVALID = "invalid",
	UNAUTHORIZED = "unauthorized",
	IGNORED = "ignored",
}

-- Timer intervals (in seconds)
local TIMER_INTERVALS = {
	VERSION_BROADCAST = 600,        -- 10 minutes: lightweight version ping (reduced for large guild congestion)
	ALT_DATA_QUEUE_RETRY = 5,       -- 5 seconds: queue reprocessing delay
}

-- Log levels (lower = more verbose)
local LOG_LEVEL = {
	DEBUG = 1,       -- development/troubleshooting details
	INFO = 2,        -- sync status, normal operations
	WARN = 3,        -- something unexpected but recoverable
	ERROR = 4,       -- something failed
	RESPONSE = 5,    -- response to user commands (always shown)
}

-- Debug categories for filtering
local DEBUG_CATEGORY = {
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
	-- DEBUG-001: both were already being PASSED as categories by real call sites while not
	-- existing here, so Output:Debug treated the category as the format string and shifted every
	-- argument along -- printing a raw %d and the real format string as data, in the chat frame.
	-- Adding them (rather than retagging the call sites) keeps the messages where their authors
	-- put them. All three registries must agree: here, Database:Init's debugCategories defaults,
	-- and Options.CATEGORY_META.
	SYSTEM = "SYSTEM",           -- Output's own internals: persistent log rotation and GC
	FULFILL = "FULFILL",         -- request fulfillment: mail matching and completion detection
}

-- Debug sub-tags: optional second argument to Output:Debug() for per-feature filtering.
-- Signature: Output:Debug("CATEGORY", "TAG", fmt, ...)  or  Output:Debug("CATEGORY", fmt, ...)
-- If a tag is supplied and matches a key in this table, only that tag's toggle gates it.
-- If no tag is supplied (or the string is not a known tag), the category master switch gates it.
-- nil entry in debugTags DB = tag is ALLOWED by default (opt-out model; new tags auto-show).
local DEBUG_TAGS = {
	P2P = {
		OFFER     = "hash-offer send / receive",
		DISPATCH  = "session creation, peer selection, collect-window fallbacks (no response after timeout)",
		HANDSHAKE = "sync-accept/busy, state-summary exchange, RespondToStateSummary decisions, no-change replies",
		COMPLETE  = "data delivered, session COMPLETE/FAILED/delivery-timeout, queue slot release",
		CATCHUP   = "catch-up broadcast scheduling (fires when data is still missing after dispatch)",
		["BROADCAST"] = "P2P hash-broadcast sent to guild channel (waiting for peers)",
		["RESPOND"]   = "peer sending data in response to a P2P request (queue progress)",
		["TIMEOUT"]   = "per-alt timeout timers armed, and an in-flight one being replaced (P2P-026)",
		["VERSION"]   = "P2P-035 version query: who was asked what they hold, what they answered, which version was chosen",
	},
	PROTOCOL = {
		["HLR"]               = "hash-list-reply processing",
		["HLR-COMPARE"]       = "per-alt hash comparison decisions (skip / mismatch / pending) - high volume",
		["VERSION-BROADCAST"] = "version broadcast processing",
		["ALT-REQUEST"]       = "alt-request send / receive decisions",
		["HASH-SKIP"]         = "hash comparison skip paths",
		["SETTINGS"]          = "guild settings broadcast / receive (maxRequestPercent, autoTombstoneDays, cancelReasons, helpNotes)",
		["MAIL-SYNC"]         = "mail hash sync query decisions (when/why to query for mail updates)",
		["PULL-HASH"]         = "requester hash data included in pull-based requests",
		["INTEGRITY-MISMATCH"] = "stop-marker present but CRC failed (genuine bit-corruption, not truncation)",
		["COLLISION-GUARD"]   = "hash-list broadcast collision prevention (skip/defer/retry decisions, P2P-023 fix)",
		["SERIAL"]           = "SerializeWithChecksum call tracing (outgoing checksum + payload size)",
		["PREFIX"]  = "comm prefix registration verdicts from the client (LIBREQ-ALL-005)",
		["RECV"]    = "general incoming message dispatch and receipt",
		["WHISPER"] = "whisper send routing and online-check decisions",
		["INIT"]    = "addon and library initialization events",
		["HELLO"]   = "hello / hello-reply protocol ping",
		["HL"]      = "hash-list (HL) request send and receive",
	},
	SYNC = {
		["HASH-MATCH"]      = "hash comparison decisions",
		["HASH-CORRECTION"] = "hash field auto-correction",
		["RECEIVE"]         = "full alt data receive / sanitize",
		["MERGE"]           = "request log merge decisions",
		["PROGRESS"]        = "banker data sync progress counters",
		["SLOT-CORRECTION"] = "bank/bags slot count corrections applied from peer no-change messages",
		["APPLY"]           = "applying request snapshots and mutations to local state",
		["BROADCAST"]       = "broadcasting request mutations to guild channel",
		["SEND"]            = "outgoing sync data and acknowledgments",
		["VALIDATE"]        = "request mutation validation and rejection decisions",
		["HASH-ADOPT"]      = "adopting a peer's hash for an alt we have no newer data for",
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
		NUMBERS = "P2P-035 banker numbers: minting, adopting a peer's table, table requests and replies",
	},
	BANK = {
		GATE = "why Bank:Scan() returned early (not a banker, scanning disabled, roster not ready, ...)",
		SCAN = "bank / bag slot enumeration and totals",
	},
	REQUESTS = {
		RECEIVE = "incoming request data",
		SEND    = "outgoing request data",
		INDEX   = "index sync operations",
		PROTO2    = "togbank-ri / togbank-rd2 compact protocol (send + receive)",
		VALIDATE  = "incoming request sanitization and rejection log",
		INIT      = "module initialization and event registration",
	},
	COMMS = {
		SEND    = "outbound addon messages (guild, whisper, broadcast)",
		RECEIVE = "inbound addon messages",
		SUPPRESS = "messages suppressed (in raid, offline target, etc.)",
	},
	CACHE = {
		REFRESH = "guild roster cache rebuild and online-count update",
	},
	MAIL = {
		SCAN   = "mail inbox scanning and slot enumeration",
		STORE  = "saving / assigning mail data to alt records",
		ADOPT  = "merge decisions when receiving remote mail data",
		EVENTS = "WoW mail frame events (MAIL_SHOW, MAIL_CLOSED, etc.)",
	},
	DATABASE = {
		MIGRATE   = "SavedVariables schema migrations",
		PRUNE     = "stale entry cleanup (deltaHistory, tombstones)",
		CLEAN     = "malformed or invalid entry removal",
		STORE     = "data write operations during bank scan aggregation",
		NORMALIZE = "request list normalization and deduplication",
	},
	EVENTS = {
		TIMER = "periodic share timer, zone-in cooldown, deferred broadcasts",
		SKIP  = "events ignored due to guard conditions (in raid, already in progress, etc.)",
	},
	ITEM = {
		LOAD     = "item object creation and ContinueOnItemLoad callbacks",
		VALIDATE = "item field validation before storage or display",
	},
	QUERIES = {
		RECEIVE  = "incoming pull-based requests from peers",
		RESPOND  = "outgoing responses to peer requests",
		SKIP     = "requests ignored (no content, hash match, queue full, etc.)",
		TIMEOUT  = "P2P response timeout fallback to banker",
	},
	WHISPER = {
		SEND = "whisper send attempts and results",
		SKIP = "whispers suppressed (player offline, in raid, etc.)",
	},
	UI = {
		FILTER = "filter bar updates (requester dropdown, banker checkbox, etc.)",
		SEARCH = "search field OnTextChanged events and DrawContent entry/exit timing",
		DRAW   = "item rendering (DrawItem), border color lookups, async fallback triggers",
	},
}

-- Request storage settings
local REQUEST_LOG = {
	EXPIRY_SECONDS = 30 * 24 * 60 * 60,      -- 30 days: completed/cancelled requests and tombstones removed after this
	PRUNE_INTERVAL = 300,                     -- 5 minutes: minimum interval between automatic prunes
}

-- Request sync throttling settings
local REQUESTS_SYNC = {
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
local COMM_PREFIX_DESCRIPTIONS = {

	["togbank-d4"] = "(Delta Data v2 - No Links)",
	["togbank-r"] = "(Query)",
	["togbank-rr"] = "(Query Reply)",
	["togbank-ri"]  = "(Request Index v1)",
	["togbank-rd2"] = "(Request Data v2: single record/tombstone)",
	["togbank-rd"]  = "(Request Data: idx/by-id)",
	["togbank-rm"] = "(Request Mutations)",
	["togbank-state"] = "(State Summary)",
	["togbank-nochange"] = "(No Change)",
	["togbank-hl"] = "(Hash List Request)",
	["togbank-hlr"] = "(Hash List Reply)",
}

-- Protocol version and capabilities
local PROTOCOL = {
	VERSION = 2,                    -- Current protocol version (bump for breaking changes)
	SUPPORTS_DELTA = true,          -- This client supports delta updates
	MIN_DELTA_SIZE_RATIO = 0.3,     -- Only use delta if <30% of full sync size
	DELTA_SNAPSHOT_MAX_AGE = 3600,  -- 1 hour: snapshots older than this are invalid
	DELTA_SUPPORT_THRESHOLD = 0.05, -- Use delta if >5% of online guild supports it (lowered for testing: 1 of 14 = 7.1%)
}

-- Peer-to-Peer distribution settings (PERF-005)
local PEER_TO_PEER = {
	ENABLED = true,                  -- Enable P2P distribution (allows any peer with matching hash to respond)
	MIN_GUILD_SIZE = 3,              -- Only enable for guilds with >3 members
	HASH_QUERY_TIMEOUT = 5,          -- Seconds to wait for hash from banker
	PEER_RESPONSE_TIMEOUT = 5,       -- Seconds to wait for peer data
	FALLBACK_TO_BANKER = true,       -- Always fall back to banker on hash mismatch or timeout
}

-- Feature flags (for easy enable/disable during development/testing)
local FEATURES = {
	DELTA_ENABLED = true,           -- Enable delta sync protocol
	FORCE_DELTA_SYNC = false,       -- Force delta sync (bypass thresholds) for testing
	FORCE_FULL_SYNC = false,        -- Force full sync (disable delta) for testing
}

-- Container geometry, BANKSLOT-001. THE ONE SPELLING of which bag ids are carried and which are the
-- bank's: Blizzard's own expression from BankFrame.lua:245,
--     for i = NUM_BAG_SLOTS+1, (NUM_BAG_SLOTS + NUM_BANKBAGSLOTS)
-- which is 0..4 and 5..10 on Classic Era (measured on a live client 2026-09-09: NUM_BAG_SLOTS = 4,
-- NUM_BANKBAGSLOTS = 6). Five files carried their own copy of this arithmetic; a fifth was added the
-- day the fourth was fixed. Five spellings of one range is a divergence nothing reports -- the two
-- scan paths walking different ranges would make `/togbank dev compare` lie -- so they all call here.
--
-- FUNCTIONS, READ AT CALL TIME, not values captured at file scope: these are engine-side globals the
-- client's own Constants.lua sets, and an addon file can load before that has happened. A file-scope
-- capture would latch the fallback for the whole session and behave exactly like the hardcode this
-- replaced, with nothing to show it had. The fallbacks are the measured Era values; TBC may differ
-- and that costs nothing, because each client reads its own constant.
local function CarriedBagRange()
	return 0, (NUM_BAG_SLOTS or 4)
end
local function BankBagRange()
	local carried = NUM_BAG_SLOTS or 4
	return carried + 1, carried + (NUM_BANKBAGSLOTS or 6)
end

-- NS-001: the single global this file publishes. Consumers alias what they need at file scope:
--     local DEBUG_CATEGORY = TOGBankClassic_Constants.DEBUG_CATEGORY
-- Aliasing rather than rewriting every reference keeps the ~240 call sites untouched, and the local
-- shadows any same-named global another addon declares -- which is the whole point (see the header).
TOGBankClassic_Constants = {
	ADOPTION_STATUS          = ADOPTION_STATUS,
	TIMER_INTERVALS          = TIMER_INTERVALS,
	LOG_LEVEL                = LOG_LEVEL,
	DEBUG_CATEGORY           = DEBUG_CATEGORY,
	DEBUG_TAGS               = DEBUG_TAGS,
	REQUEST_LOG              = REQUEST_LOG,
	REQUESTS_SYNC            = REQUESTS_SYNC,
	COMM_PREFIX_DESCRIPTIONS = COMM_PREFIX_DESCRIPTIONS,
	PROTOCOL                 = PROTOCOL,
	PEER_TO_PEER             = PEER_TO_PEER,
	FEATURES                 = FEATURES,
	CarriedBagRange          = CarriedBagRange,
	BankBagRange             = BankBagRange,
}
