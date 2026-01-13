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
