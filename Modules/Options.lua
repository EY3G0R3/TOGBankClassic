-- NS-001: aliased as file-scope locals so a foreign global of the same name cannot be read
-- instead. See the header of Modules/Constants.lua. This file reads no DEBUG_CATEGORY of its own --
-- the Debug tab is built from CATEGORY_META below, and Tests/constants_spec.lua is what holds the
-- two in step.
local DEBUG_TAGS = TOGBankClassic_Constants.DEBUG_TAGS
local LOG_LEVEL  = TOGBankClassic_Constants.LOG_LEVEL

-- ─── Debug category metadata ────────────────────────────────────────────────
-- Controls display order and description text in the Options UI.
-- Must stay in sync with DEBUG_CATEGORY in Constants.lua.
local CATEGORY_META = {
	BANK     = { order = 9,  desc = "Bank/bag inventory scanning, including why a scan was skipped" },
	CACHE    = { order = 10, desc = "Cache operations (guild roster cache, etc.)" },
	COMMS    = { order = 11, desc = "All addon communication traffic (high volume)" },
	DATABASE = { order = 12, desc = "Database operations, SavedVariables" },
	DELTA    = { order = 13, desc = "Delta sync operations and computations" },
	EVENTS   = { order = 14, desc = "WoW event handling (GUILD_ROSTER_UPDATE, etc.)" },
	ITEM     = { order = 15, desc = "Item loading, validation, and processing" },
	MAIL     = { order = 16, desc = "Mail inventory scanning and tracking" },
	P2P      = { order = 17, desc = "Session manager: collect window, dispatch, handshake" },
	PROTOCOL = { order = 18, desc = "Protocol version negotiation, hash-list and alt-request decisions (envelope CRC and serialize tracing moved to DELTASYNC)" },
	QUERIES  = { order = 19, desc = "P2P query/response decisions and hash matching" },
	REQUESTS = { order = 20, desc = "Request system activity and updates" },
	ROSTER   = { order = 21, desc = "Guild roster updates, online/offline tracking" },
	SYNC     = { order = 22, desc = "Data synchronization operations" },
	UI       = { order = 23, desc = "UI operations, window opens/closes (includes SEARCH keystroke and DrawContent timing)" },
	WHISPER  = { order = 24, desc = "Whisper sends, skips, and online checks" },
	-- DEBUG-001: the third of the three registries that must agree (DEBUG_CATEGORY in
	-- Constants.lua and debugCategories in Database:Init are the others). Without a row here the
	-- category exists and works but has no toggle in the options panel, so a user cannot turn it
	-- off -- which is the same category of silent gap the finding is about, one layer up.
	FULFILL  = { order = 25, desc = "Request fulfillment: mail matching and completion detection" },
	SYSTEM   = { order = 26, desc = "The addon's own logging internals: persistent log rotation and garbage collection" },
	DELTASYNC = { order = 27, desc = "The DeltaSync-1.0 library host: its initialisation, comms, envelope and delta lines" },
	LOG      = { order = 28, desc = "The bank log: entries recorded from scans, deliveries and requests; batches delivered to the Log tab and TOGTools" },
}

-- Build one inline AceConfig group for a single debug category.
-- Contains the master enable toggle plus a sub-toggle per pre-registered tag.
local function BuildCategoryGroup(catKey, meta)
	local tags   = DEBUG_TAGS and DEBUG_TAGS[catKey]
	local hasTags = tags ~= nil and next(tags) ~= nil

	local groupArgs = {}

	-- Master category toggle
	groupArgs["enabled"] = {
		order = 1,
		type  = "toggle",
		width = "full",
		name  = "|cffffffff" .. catKey .. "|r",
		desc  = meta.desc,
		set   = function(_, v) TOGBankClassic_Output:SetCategoryEnabled(catKey, v) end,
		get   = function()    return TOGBankClassic_Output:IsCategoryEnabled(catKey) end,
	}

	if hasTags then
		groupArgs["tagLabel"] = {
			order = 2,
			type  = "description",
			name  = "|cffaaaaaa  Tags — uncheck to suppress specific messages:|r",
		}
		local tagOrder = 10
		for tagKey, tagDesc in pairs(tags) do
			local tk, td = tagKey, tagDesc  -- upvalue capture for closures
			groupArgs["tag_" .. tk] = {
				order    = tagOrder,
				type     = "toggle",
				name     = tk,
				desc     = td,
				disabled = function() return not TOGBankClassic_Output:IsCategoryEnabled(catKey) end,
				set      = function(_, v) TOGBankClassic_Output:SetTagEnabled(catKey, tk, v) end,
				get      = function()    return TOGBankClassic_Output:IsTagEnabled(catKey, tk)  end,
			}
			tagOrder = tagOrder + 1
		end
	end

	return {
		order  = meta.order,
		type   = "group",
		inline = true,
		name   = catKey .. " — " .. meta.desc,
		args   = groupArgs,
	}
end

-- Build the full args table for the Debug options tab.
-- Called once at Init() time; includes headers, all category groups, bulk buttons,
-- and the Performance Monitoring + Debug Logging sub-sections.
local function BuildDebugArgs()
	local args = {
		["debugHeader"] = {
			order = 0,
			type  = "header",
			name  = "Debug Categories",
		},
		["debugDesc"] = {
			order = 1,
			type  = "description",
			name  = "Enable categories to filter debug output. Expand a category to toggle individual message tags. Log Level must be set to 'Debug' for any of these to appear.",
		},
		["showUncategorized"] = {
			order = 2,
			type  = "toggle",
			width = "full",
			name  = "Show Uncategorized Debug Messages (legacy)",
			desc  = "Show old debug messages that don't have a category assigned. Disable to only see categorized messages.",
			set   = function(_, v) TOGBankClassic_Database.db.global.showUncategorizedDebug = v end,
			get   = function()    return TOGBankClassic_Database.db.global.showUncategorizedDebug end,
		},
		["spacer1"] = { order = 9, type = "description", name = " " },
	}

	-- One inline group per category
	for catKey, meta in pairs(CATEGORY_META) do
		args["cat_" .. catKey] = BuildCategoryGroup(catKey, meta)
	end

	-- Bulk action buttons
	args["spacer_actions"] = { order = 100, type = "description", name = " " }
	args["enableAll"] = {
		order = 101,
		type  = "execute",
		name  = "Enable All Categories",
		func  = function()
			TOGBankClassic_Output:EnableAllCategories()
			TOGBankClassic_Output:Info("All debug categories enabled")
		end,
	}
	args["disableAll"] = {
		order = 102,
		type  = "execute",
		name  = "Disable All Categories",
		func  = function()
			TOGBankClassic_Output:DisableAllCategories()
			TOGBankClassic_Output:Info("All debug categories disabled")
		end,
	}

	-- Performance monitoring section
	args["spacer2"]     = { order = 200, type = "description", name = " " }
	args["perfHeader"]  = { order = 201, type = "header",      name = "Performance Monitoring" }
	args["perfEnabled"] = {
		order = 202,
		type  = "toggle",
		width = "full",
		name  = "Enable Performance Monitoring",
		desc  = "Track event frequency, operation timing, and memory usage. Disable to reduce overhead if experiencing performance issues.",
		get   = function() return TOGBankClassic_PerfEnabled end,
		set   = function(_, value)
			TOGBankClassic_PerfEnabled = value
			TOGBankClassic_Output:Info(value and "Performance monitoring enabled" or "Performance monitoring disabled")
		end,
	}
	args["perfStatsButton"] = {
		order = 203,
		type  = "execute",
		width = "full",
		name  = "Show Performance Statistics",
		desc  = "Display event frequency, operation timing, and memory usage for current session",
		func  = function() TOGBankClassic_Performance:PrintReport() end,
	}

	-- Debug log section
	args["spacer3"]        = { order = 300, type = "description", name = " " }
	args["debugLogHeader"] = { order = 301, type = "header",      name = "Debug Logging" }
	args["debugLogDescription"] = {
		order = 302,
		type = "description",
		name = "Debug categories (below) control what messages are shown. Persistent logging (optional) saves those messages to SavedVariables for later review.",
	}
	args["debugLogEnabled"] = {
		order = 303,
		type  = "toggle",
		width = "full",
		name  = "Enable Persistent Logging to SavedVariables",
		desc  = "When ENABLED: Debug messages are saved to TOGBankClassicDB_DebugLog SavedVariables file (max 50,000 entries or 7 days) for later review via /togbank debuglog. When DISABLED (default): Debug messages are still shown in chat/debug frame but NOT saved to disk. WARNING: Enabling this increases SavedVariables file size (1-5 MB) and reload time. Requires /reload to take effect.",
		get   = function() return TOGBankClassic_DebugLogEnabled end,
		set   = function(_, value)
			TOGBankClassic_DebugLogEnabled = value
			if value then
				TOGBankClassic_Output:Info("Persistent logging ENABLED. Debug messages will be saved to SavedVariables for later review. Requires /reload to load existing logs.")
			else
				TOGBankClassic_Output:Info("Persistent logging DISABLED. Debug messages will still show in chat but will NOT be saved to SavedVariables. Requires /reload to skip loading logs.")
			end
		end,
	}

	-- Integrity diagnostics section
	args["spacer4"]         = { order = 400, type = "description", name = " " }
	args["integrityHeader"] = { order = 401, type = "header", name = "Integrity Check Diagnostics" }
	args["integrityDesc"]   = {
		order = 402,
		type  = "description",
		name  = "When enabled, a chat alert is shown any time a message arrives complete (stop-marker present) but fails the CRC check. This indicates genuine bit-corruption rather than truncation, meaning the stop-marker check alone would not be sufficient. Off by default — enable only if you are a designated tester.",
	}
	args["integrityCheckDiagnostics"] = {
		order = 403,
		type  = "toggle",
		width = "full",
		name  = "Show Integrity Mismatch Alerts",
		desc  = "Print a chat error when stop-marker says the message arrived complete but CRC disagrees. Leave disabled unless you are actively testing for non-truncation corruption.",
		get   = function() return TOGBankClassic_Options.db.global.bank["integrityCheckDiagnostics"] end,
		set   = function(_, v) TOGBankClassic_Options.db.global.bank["integrityCheckDiagnostics"] = v end,
	}

	return args
end

-- ALPHA-001: one transparency slider per window, generated from TOGBankClassic_UI.ALPHA_WINDOWS
-- so adding a window means adding one row there rather than editing this file too.
--
-- Stored as 0..1, which is what SetBackdropColor wants, and displayed as a percentage by
-- AceConfig's `isPercent` -- it renders the value and both end labels as percentages, so no
-- conversion is needed in get/set and there is no rounding step to get wrong.
--
-- Shape (min/max/step/isPercent/width) deliberately mirrors the Window opacity slider in FGI, so
-- the control behaves identically across the TOG addons. The difference is that FGI has one
-- window and therefore one slider; here it is one per window, which is what was asked for.
local function BuildAppearanceArgs()
	local args = {
		["alphaHeader"] = {
			order = 0,
			type  = "header",
			name  = "Window Transparency",
		},
		["alphaDesc"] = {
			order = 1,
			type  = "description",
			name  = "Set how see-through each window's background is. Only the window frame fades — "
				.. "item icons, counts and text stay fully readable at every setting.\n\n"
				.. "Changes apply immediately to any window that is already open.",
		},
	}

	for i, entry in ipairs(TOGBankClassic_UI.ALPHA_WINDOWS) do
		args["alpha_" .. entry.key] = {
			order = 10 + i,
			type  = "range",
			-- Full row so the slider has a long track to drag against.
			width = "full",
			name  = entry.label,
			desc  = ("Background opacity of the %s window. 100%% is solid, 10%% is nearly "
				.. "invisible. The frame texture has its own translucency, so a solid backing "
				.. "layer sits behind it to make 100%% actually opaque."):format(entry.label),
			-- Matches the same slider in FGI. The floor is 10%, not 0: a fully invisible window
			-- is one a player cannot find again to fix, and 10% is already see-through enough
			-- for any real use.
			min = 0.1, max = 1.0, step = 0.05,
			isPercent = true,
			get = function() return TOGBankClassic_UI:GetWindowAlpha(entry.key) end,
			set = function(_, v) TOGBankClassic_UI:SetWindowAlpha(entry.key, v) end,
		}
	end

	args["alphaResetSpacer"] = { order = 100, type = "description", name = " " }
	args["alphaReset"] = {
		order = 101,
		type  = "execute",
		width = "full",
		name  = "Reset All Windows to Solid",
		desc  = "Sets every window back to 100% opacity.",
		func  = function()
			for _, entry in ipairs(TOGBankClassic_UI.ALPHA_WINDOWS) do
				TOGBankClassic_UI:SetWindowAlpha(entry.key, 1)
			end
			-- Single %, not %%: Output:Log only runs string.format when varargs are present, so
			-- with none this string is printed verbatim.
			TOGBankClassic_Output:Info("All window transparency reset to 100%.")
		end,
	}

	-- RECENTER-001: the escape hatch for a window that has ended up off-screen. It has to live in
	-- the OPTIONS panel specifically, because that is the one TOGBank surface a player can still
	-- reach when the window itself is somewhere they cannot click.
	args["recenterSpacer"] = { order = 110, type = "description", name = " " }
	args["recenterHeader"] = { order = 111, type = "header", name = "Window Position" }
	args["recenterDesc"] = {
		order = 112,
		type  = "description",
		name  = "If a TOG Bank window has ended up off the edge of your screen, this brings every "
			.. "window back to the middle where you can reach it again. Sizes are kept.",
	}
	args["recenter"] = {
		order = 113,
		type  = "execute",
		width = "full",
		name  = "Recenter All Windows",
		desc  = "Moves every TOG Bank window back to the centre of the screen. Takes effect "
			.. "immediately -- no reload needed.",
		func  = function()
			local moved = TOGBankClassic_UI:RecenterWindows()
			if moved > 0 then
				TOGBankClassic_Output:Info("Recentred %d window(s).", moved)
			else
				TOGBankClassic_Output:Info("Every window was already in its default position.")
			end
		end,
	}

	-- CANCEL-REASON-001: the pulsing glow that marks a cancelled request as having a reason to
	-- read. On by default; here so the people it annoys can switch it off.
	args["glowSpacer"] = { order = 200, type = "description", name = " " }
	args["glowHeader"] = { order = 201, type = "header", name = "Requests Window" }
	args["cancelGlow"] = {
		order = 202,
		type  = "toggle",
		width = "full",
		name  = "Pulsing glow on cancelled requests",
		desc  = "A cancelled request shows a soft, pulsing glow on its date so it stands out in the "
			.. "list; if a reason was given, mouse over the date to read why. Turn this off for plain "
			.. "red dates; the reason is still in the date's tooltip.",
		get   = function() return TOGBankClassic_UI_Requests:CancelGlowEnabled() end,
		set   = function(_, v)
			TOGBankClassic_Options.db.global.cancelGlow = v and true or false
			-- Every visible row repaints, so a glow already on screen goes out (or comes on) now.
			TOGBankClassic_UI_Requests:InvalidateAllRows()
			TOGBankClassic_UI_Requests:DrawRows()
		end,
	}

	return args
end

-- ─────────────────────────────────────────────────────────────────────────────
TOGBankClassic_Options = {}

function TOGBankClassic_Options:Init()
	local defaults = {
		char = {
			minimap = { enabled = true },
			combat = { hide = true },
			-- SCAN-001: `enabled` MUST carry a default. It gates every Bank:Scan() and
			-- Mail:Scan(), and its only other writer is InitGuild() below, which is
			-- reachable just once per session behind an IsBank() check that loses a
			-- login race on a fresh profile. Without a default it stays nil (falsy)
			-- forever and the character never scans. Harmless for non-bankers, whose
			-- scans are already gated on IsBank() independently.
			bank = { enabled = true },   -- UX-WATERFALL-001: `donations` default retired with its box
			framePositions = {},  -- Stores window positions/sizes
			-- BROWSE-006: the Guild Bank window's last tab. Per character, beside the window
			-- positions and for the same reason -- it is part of how this alt has that window set up.
			browseTab = "browse",
			sortMode = "alpha",   -- Inventory sort mode: "alpha" (A->Z) or "type" (by item type)
			statusBarNetworkInfo = false,  -- Show sync activity in inventory status bar
			-- VISIBILITY-001: the accessibility scale. Per character, like the window positions and
			-- for the same reason -- it is how this player has these windows set up. The default is
			-- the LIBRARY's normal size, read from it (see GetUIScale) rather than written as 1.
			uiScale = TOGBankClassic_Options.SCALE_DEFAULT,
			-- HIDE-001: this banker's "not for the guild" items, `Record.key -> true`. Per character:
			-- it is a property of what THIS toon carries, and a hearthstone hidden on one banker
			-- says nothing about another.
			hiddenItems = {},
		},
		global = {
				-- RAID-SYNC-001: syncInRaid OFF by default -- the raid guard stays as it has always been
				-- unless the player opts out of it (the chat channel is throttled; raid addons need it).
				-- MAILBOX-TOGGLE-001: mailboxAutoOpen ON by default -- v1.5.0 shipped the auto-open.
				-- MAILBOX-TOGGLE-002: mailboxAutoOpenNonBankers OFF by default -- "on by default for
				-- bankers only" (the operator, 2026-09-14).
				bank = { report = true, logLevel = LOG_LEVEL.INFO, commDebug = false, integrityCheckDiagnostics = false, registerBankCommand = true, registerGbankCommand = true, syncInRaid = false, mailboxAutoOpen = true, mailboxAutoOpenNonBankers = false },
			-- ALPHA-001: per-window chrome transparency, 0..1, keyed by TOGBankClassic_UI.ALPHA_WINDOWS.
			-- Account-wide rather than per-character: it is a pure display preference with no
			-- per-character meaning, and setting it once per alt is exactly the chore the request
			-- was about avoiding. Window POSITIONS stay per-character (db.char.framePositions) --
			-- those people really do arrange differently per alt.
			windowAlpha = {},
			-- CANCEL-REASON-001: the pulsing glow on a cancelled request's date. ON by default --
			-- the operator: "some folks will whine about it ... folks can turn it off if they want".
			-- Account-wide for the same reason as windowAlpha: a display preference, set once.
			cancelGlow = true,
			-- BROWSE-001: which windows' help icons this account has hovered once. The Guild Bank
			-- window's icon breathes until then ("draw their attention to it, ONCE").
			helpSeen = {},
			requests = {
				maxRequestPercent = 100,  -- Maximum % of available items that can be requested (100 = no limit)
				archiveDays = 30,  -- Requests older than this many days are moved to the Archive tab
				autoTombstoneDays = 30,  -- Stale open requests older than this are auto-cancelled on receive
			},
		},
	}
	self.db = LibStub("AceDB-3.0"):New("TOGBankClassicOptionDB", defaults)
	if self.db.global.bank["shutup"] ~= nil then
		if self.db.global.bank["shutup"] == true then
			self.db.global.bank["logLevel"] = LOG_LEVEL.RESPONSE
		end
		self.db.global.bank["shutup"] = nil
	end
	if self.db.global.bank["logLevel"] == nil then
		self.db.global.bank["logLevel"] = LOG_LEVEL.INFO
	end
	if self.db.global.bank["commDebug"] == nil then
		self.db.global.bank["commDebug"] = false
	end
	if self.db.global.bank["muteSyncProgress"] == nil then
		self.db.global.bank["muteSyncProgress"] = false
	end
	if self.db.global.bank["muteWarnings"] == nil then
		self.db.global.bank["muteWarnings"] = false
	end
	if self.db.global.bank["integrityCheckDiagnostics"] == nil then
		self.db.global.bank["integrityCheckDiagnostics"] = false
	end
	if self.db.global.bank["registerBankCommand"] == nil then
		self.db.global.bank["registerBankCommand"] = true
	end
	if self.db.global.bank["registerGbankCommand"] == nil then
		self.db.global.bank["registerGbankCommand"] = true
	end
	if self.db.global.requests.archiveDays == nil then
		self.db.global.requests.archiveDays = 30
	end
	if self.db.global.requests.autoTombstoneDays == nil then
		self.db.global.requests.autoTombstoneDays = 30
	end
	-- VISIBILITY-001: hand the saved accessibility scale to LibAceGUIWidgets BEFORE any window is
	-- built, so a reload comes back at the size the player set rather than at 100% until they touch
	-- the slider. The library holds it in memory only; this is the one place it is restored.
	self:ApplyUIScale()
	-- Initialize logger with saved level
	TOGBankClassic_Output:SetLevel(self.db.global.bank["logLevel"])
	-- Initialize comm debug with saved setting
	TOGBankClassic_Output:SetCommDebug(self.db.global.bank["commDebug"])

	-- Main options container
	local options = {
		type = "group",
		name = "TOGBankClassic",
		childGroups = "tab",
		args = {
			general = {
				order = 1,
				type = "group",
				name = "General",
				args = {
					["minimap"] = {
						order = 0,
						type = "toggle",
						width = "full",
						name = "Show Minimap Button",
						desc = "Toggles visibility of the minimap button",
						set = function(_, v)
							self.db.char.minimap["enabled"] = v
							TOGBankClassic_UI_Minimap:Toggle()
						end,
						get = function()
							return self.db.char.minimap["enabled"]
						end,
					},
					["combat"] = {
						order = 1,
						type = "toggle",
						width = "full",
						name = "Hide During Combat",
						desc = "Toggles visibility of the window during combat",
						set = function(_, v)
							self.db.char.combat["hide"] = v
						end,
						get = function()
							return self.db.char.combat["hide"]
						end,
					},
					-- VISIBILITY-001, the operator: "can we add a visibility feature that makes the
					-- font/icons/rows larger on a slider for the visually impaired?" ONE factor for
					-- every window: LibAceGUIWidgets MINOR 29 scales every font, icon, row height,
					-- menu, dialog and resize floor it draws, and re-lays every live widget on the
					-- change; `Options:SetUIScale` is the one writer and `ApplyUIScale` the one
					-- caller of the library, from here and from load. PER-CHARACTER (`db.char`),
					-- not guild-synced: an accessibility preference of the person at the keyboard,
					-- the only setting here about their eyes rather than about the bank.
					["uiScale"] = {
						order = 1.4,
						type = "range",
						width = "full",
						name = "Window and Text Size",
						desc = "Enlarges the text, icons and row height of every TOGBank window together. 100% is the normal size; raise it if the bank list is hard to read.",
						min = TOGBankClassic_Options.SCALE_MIN,
						max = TOGBankClassic_Options.SCALE_MAX,
						step = 0.1,
						isPercent = true,
						set = function(_, v) TOGBankClassic_Options:SetUIScale(v) end,
						get = function() return TOGBankClassic_Options:GetUIScale() end,
					},
					["statusBarNetworkInfo"] = {
						order = 1.5,
						type = "toggle",
						width = "full",
						name = "Show Network Status in Status Bar",
						desc = "Shows sync activity (sending / backlog) in the inventory window status bar. Disable for a cleaner display.",
						set = function(_, v)
							self.db.char.statusBarNetworkInfo = v
						end,
						get = function()
							return self.db.char.statusBarNetworkInfo
						end,
					},
					["logLevel"] = {
						order = 2,
						type = "select",
						style = "radio",
						width = "full",
						name = "Log Level",
						desc = "Controls which messages are shown in chat",
						values = {
							[LOG_LEVEL.RESPONSE] = "Quiet (only respond to /togbank commands)",
							[LOG_LEVEL.ERROR] = "Errors and above",
							[LOG_LEVEL.WARN] = "Warnings and above",
							[LOG_LEVEL.INFO] = "Info and above (default)",
							[LOG_LEVEL.DEBUG] = "Debug (show everything)",
						},
						sorting = { LOG_LEVEL.RESPONSE, LOG_LEVEL.ERROR, LOG_LEVEL.WARN, LOG_LEVEL.INFO, LOG_LEVEL.DEBUG },
						set = function(_, v)
							self.db.global.bank["logLevel"] = v
							TOGBankClassic_Output:SetLevel(v)
						end,
						get = function()
							return self.db.global.bank["logLevel"]
						end,
					},
					["muteSyncProgress"] = {
						order = 2.6,
						type = "toggle",
						width = "full",
						name = "Mute Sync Progress Messages",
						desc = "Hides 'Sharing guild bank data...' and 'Send complete...' messages during data sync",
						set = function(_, v)
							self.db.global.bank["muteSyncProgress"] = v
						end,
						get = function()
							return self.db.global.bank["muteSyncProgress"]
						end,
					},
					["syncInRaid"] = {
						order = 2.65,
						type = "toggle",
						width = "full",
						name = "Keep syncing in a raid group",
						desc = "Guild bank data is normally not sent or received while you are in a raid group, so raid addons keep the addon chat channel to themselves. Tick this to keep syncing anyway.",
						set = function(_, v)
							self.db.global.bank["syncInRaid"] = v
						end,
						get = function()
							return self.db.global.bank["syncInRaid"] == true
						end,
					},
					-- MAILBOX-TOGGLE-001 (operator, v1.5.1: "we also need the ability to turn on/off the
					-- mail window, some folks might not want that" / "put a settings in the general
					-- settings for that"). ON by default: the auto-open is v1.5.0's shipped behaviour and
					-- an upgrade must not take it away. Off, the window still opens by hand
					-- (/togbank mailbox, the TOG Bank button on the mail frame).
					["mailboxAutoOpen"] = {
						order = 2.66,
						type = "toggle",
						width = "full",
						name = "Open the Mailbox window at a mailbox",
						desc = "On bank characters, the addon's Mailbox window opens beside the mail frame whenever you open a mailbox. Untick to stop that; /togbank mailbox and the TOG Bank button on the mail frame still open it when you want it.",
						set = function(_, v)
							self.db.global.bank["mailboxAutoOpen"] = v and true or false
						end,
						get = function()
							return self:IsMailboxAutoOpenEnabled()
						end,
					},
					-- MAILBOX-TOGGLE-002 (operator, 2026-09-14: "it used to open for normal characters
					-- ... it could be useful for non-bankers too" / "make a 2nd check box that
					-- enables/disables it, and have it on by default for bankers only"). OFF by
					-- default; greyed while the master switch above is off, since it only adds to it.
					["mailboxAutoOpenNonBankers"] = {
						order = 2.67,
						type = "toggle",
						width = "full",
						name = "Mailbox window on non-bank characters",
						desc = "The Mailbox window normally opens by itself only on bank characters. Tick this to have it open at a mailbox on every character. Needs 'Open the Mailbox window at a mailbox' above.",
						disabled = function()
							return not self:IsMailboxAutoOpenEnabled()
						end,
						set = function(_, v)
							self.db.global.bank["mailboxAutoOpenNonBankers"] = v and true or false
						end,
						get = function()
							return self:IsMailboxAutoOpenForNonBankersEnabled()
						end,
					},
					["muteWarnings"] = {
						order = 2.7,
						type = "toggle",
						width = "full",
						name = "Mute Warning Messages",
						desc = "Hides [WARN] messages like data protection rejections and protocol warnings",
						set = function(_, v)
							self.db.global.bank["muteWarnings"] = v
						end,
						get = function()
							return self.db.global.bank["muteWarnings"]
						end,
					},
					["orderFulfillmentSound"] = {
						order = 2.8,
						type = "toggle",
						width = "full",
						name = "Play Sound on Order Fulfilled",
						desc = "Plays a sound when mail arrives that fulfills one of your requests",
						set = function(_, v)
							self.db.global.bank["orderFulfillmentSound"] = v
						end,
						get = function()
							local v = self.db.global.bank["orderFulfillmentSound"]
							return v == nil and true or v
						end,
					},
					["registerBankCommand"] = {
						order = 2.92,
						type  = "toggle",
						width = "full",
						name  = "Register /bank command",
						desc  = "When enabled, typing /bank opens the TOGBankClassic window. Disable if another addon uses /bank. Requires /reload to take effect.",
						set   = function(_, v)
							self.db.global.bank["registerBankCommand"] = v
							TOGBankClassic_Output:Info("/bank command %s. Requires /reload to take effect.", v and "enabled" or "disabled")
						end,
						get   = function()
							return self.db.global.bank["registerBankCommand"]
						end,
					},
					["registerGbankCommand"] = {
						order = 2.93,
						type  = "toggle",
						width = "full",
						name  = "Register /gbank command",
						desc  = "When enabled, typing /gbank opens the TOGBankClassic window. Disable if another addon uses /gbank. Requires /reload to take effect.",
						set   = function(_, v)
							self.db.global.bank["registerGbankCommand"] = v
							TOGBankClassic_Output:Info("/gbank command %s. Requires /reload to take effect.", v and "enabled" or "disabled")
						end,
						get   = function()
							return self.db.global.bank["registerGbankCommand"]
						end,
					},
					["reset"] = {
						order = -1,
						name = "Reset Database",
						desc = "Wipes all saved guild bank data for this guild, including inventory, requests, and sync state. Equivalent to /togbank wipe. Cannot be undone — all bankers will need to re-sync after.",
						type = "execute",
						func = function()
							local guild = TOGBankClassic_Guild:GetGuild()
							if not guild then
								return
							end
							TOGBankClassic_Guild:Reset(guild)
						end,
					},
				},
			},
			appearance = {
				order = 1.5,
				type = "group",
				name = "Appearance",
				args = BuildAppearanceArgs(),
			},
			debug = {
				order = 2,
				type = "group",
				name = "Debug",
				args = BuildDebugArgs(),
			},
			requests = {
				order = 3,
				type = "group",
				name = "Officer",
				-- GM/officers only (CanViewOfficerNote is true for the GM and officers).
				-- Bankers and regular members no longer see or edit these settings.
				hidden = function()
					return not (CanViewOfficerNote and CanViewOfficerNote())
				end,
				args = {
					["requestsHeader"] = {
						order = 0,
						type = "header",
						name = "Request Settings",
					},
					["requestsDesc"] = {
						order = 1,
						type = "description",
						name = "Configure how item requests work to help manage bank inventory fairly.",
					},
				["archiveDays"] = {
					order = 2,
					type = "input",
					width = "full",
					name = "Archive Threshold (days)",
					desc = "Requests older than this many days are moved to the Archive tab in the Requests window. Default is 30. Enter a whole number greater than 0.",
					validate = function(_, v)
						local n = tonumber(v)
						if not n or n < 1 or math.floor(n) ~= n then
							return "Please enter a whole number greater than 0."
						end
						return true
					end,
					get = function()
						return tostring(self.db.global.requests.archiveDays or 30)
					end,
					set = function(_, v)
						local n = tonumber(v)
						if n and n >= 1 then
							self.db.global.requests.archiveDays = math.floor(n)
							TOGBankClassic_Output:Info("Archive threshold set to %d days.", math.floor(n))
						end
					end,
				},
				["autoTombstoneDays"] = {
					order = 2.5,
					type = "input",
					width = "full",
					name = "Auto-Cancel Stale Requests (days)",
					desc = "Open requests older than this many days are automatically tombstoned (cancelled and rejected) when received during sync. The 'Cancel Stale' button in the Requests window uses this same threshold. Default is 30. Setting syncs guild-wide. Enter a whole number greater than 0.",
					validate = function(_, v)
						local n = tonumber(v)
						if not n or n < 1 or math.floor(n) ~= n then
							return "Please enter a whole number greater than 0."
						end
						return true
					end,
					get = function()
						return tostring(TOGBankClassic_Options:GetAutoTombstoneDays())
					end,
					set = function(_, v)
						local n = tonumber(v)
						if n and n >= 1 then
							n = math.floor(n)
							-- Write to guild-synced settings so all clients apply the same threshold
							if TOGBankClassic_Guild and TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.settings then
								TOGBankClassic_Guild.Info.settings.autoTombstoneDays = n
							end
							self.db.global.requests.autoTombstoneDays = n
							-- SETTINGS-001: Broadcast to all guild members so everyone enforces the same value
							TOGBankClassic_Guild:BroadcastSettings("ALERT")
							TOGBankClassic_Output:Info("Auto-cancel stale threshold set to %d days (syncing to guild...).", n)
						end
					end,
				},
				["maxRequestPercent"] = {
					order = 3,
						type = "range",
						width = "full",
						name = "Maximum Request Amount",
						desc = "Limit how much of a bank character's stock of an item one member can have on order. Set to 100% to allow requesting everything. Lower values help share inventory among multiple guild members.\n\nExample: At 50%, if bank has 100 Copper Ore, members can request up to 50 -- and a member with 30 already on order can ask for 20 more.\n\nEnforced however the order is placed, and a member who was offline when you changed it gets the new value when they log in (a bank character or officer must be online to hand it over).\n\nNote: Single items (like gear) can always be requested even at low percentages.",
						min = 1,
						max = 100,
						step = 1,
						get = function()
							return TOGBankClassic_Options:GetMaxRequestPercent()
						end,
						set = function(_, v)
							-- Write to guild-synced settings (propagates to all clients)
							if TOGBankClassic_Guild and TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.settings then
								TOGBankClassic_Guild.Info.settings.maxRequestPercent = v
							end
							-- Also write to local settings as backup
							self.db.global.requests.maxRequestPercent = v
							-- SETTINGS-001: Broadcast to all guild members so everyone enforces the same value
							TOGBankClassic_Guild:BroadcastSettings("ALERT")
							TOGBankClassic_Output:Info("Maximum request amount set to %d%% (syncing to guild...)", v)
						end,
					},
					-- SHOP-SECTION-001 (the operator, 2026-09-15, on the Ordering open box sitting under
					-- Maximum Request Amount: "this is for shop orders correct, not for non-shop orders?
					-- if so, we need to clarify that, as it could be confusing. maybe we make a separate
					-- shop section in the officers tab"): the shop's settings are their OWN section, under
					-- their own heading, after the plain bank's request settings and their example box.
					-- The wording says "shop orders" everywhere, because that is all the sign governs:
					-- with the shop on every order IS a shop order (SHOP-NOFREE-001); with it off the box
					-- is greyed and the plain bank's requests never see it (Guild:IsStoreOpen).
					["shopHeader"] = {
						order = 3.2,
						type = "header",
						name = "Shop",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
					},
					["shopDesc"] = {
						order = 3.3,
						type = "description",
						name = "For a guild bank that SELLS its items. Everything here is about shop orders: with the Shop on, every order placed is a shop order at the estimate shown, and the settings below open and close that ordering and discount the estimates. With the Shop off, the bank is a plain bank -- these settings do nothing and the request settings above are all that apply.",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
					},
					-- SHOP-TAB-001 (the operator, 2026-09-14: "a setting to turn it on/off, so folks can
					-- shut it off if their bank doesn't 'sell' items. it should be off by default"): the
					-- shop switch. Officer-only, guild-synced, OFF by default; on, the Guild Bank window
					-- gains a Shop tab (estimates, the open/closed sign, the not-for-sale list).
					["shopEnabled"] = {
						order = 3.4,
						type = "toggle",
						width = "full",
						name = "Shop",
						desc = "Turn on if your guild bank SELLS items -- members order, the bank character fills the order and sets the price. The Guild Bank window gains a Shop tab with estimated values (from your price sources: type /itemdb), and officers can close ordering or take items off the shop list. Off, the bank is a plain bank. Syncs to the whole guild.",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
						get = function() return TOGBankClassic_Guild:IsShopEnabled() end,
						set = function(_, v) TOGBankClassic_Guild:SetShopEnabled(v) end,
					},
					-- STORE-006 (GUILD_STORE.md 4.6): the shop's open/closed sign. Officer-only like the
					-- help notes; writes through Guild:SetStoreOpen, the single writer shared with the
					-- Shop tab's box. Greyed while the shop is off: there is no sign to hang.
					["storeOpen"] = {
						order = 3.5,
						type = "toggle",
						width = "full",
						name = "Shop ordering open",
						desc = "The shop's open/closed sign. Untick to stop members placing SHOP orders -- a stocktake, an officer away, a pricing mistake; members clicking an item are told ordering is closed. Tick to reopen. Only shop orders are affected: with the Shop off this box is greyed and plain bank requests never see it. Syncs to the whole guild.",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
						disabled = function() return not TOGBankClassic_Guild:IsShopEnabled() end,
						get = function() return TOGBankClassic_Guild:IsStoreOpen() end,
						set = function(_, v) TOGBankClassic_Guild:SetStoreOpen(v) end,
					},
					-- STORE-003 (GUILD_STORE.md 4.3; the operator: "if you want to sell all the items at
					-- 50% off, we need to apply that to the pricing that is displayed on the shop tab"):
					-- the guild-wide discount off every estimate on the Shop tab. Officer-only, synced,
					-- greyed while the shop is off. Guild:SetStoreDiscount is the one writer.
					["storeDiscountPercent"] = {
						order = 3.55,
						type = "range",
						width = "full",
						name = "Shop discount",
						desc = "Percent off every estimate shown on the Shop tab -- 50 shows every item at half its market estimate. 0 is no discount. The bank character still sets the real price when an order is filled. Syncs to the whole guild.",
						min = 0,
						max = 100,
						step = 1,
						isPercent = false,
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
						disabled = function() return not TOGBankClassic_Guild:IsShopEnabled() end,
						get = function() return TOGBankClassic_Guild:GetStoreDiscount() end,
						set = function(_, v) TOGBankClassic_Guild:SetStoreDiscount(v) end,
					},
					-- SHOP-SECTION-001: the two below are NOT shop settings (neither is gated by the shop
					-- switch -- the donation board and the guild price list serve a plain bank too), so
					-- they get their own heading rather than reading as the shop's.
					["donationsHeader"] = {
						order = 3.58,
						type = "header",
						name = "Donations and pricing",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
					},
					["donationsDesc"] = {
						order = 3.59,
						type = "description",
						name = "Apply with or without the Shop: what a donation to a bank character earns, and whose price sources the whole guild values things by.",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
					},
					-- STORE-007 (GUILD_STORE.md 4.7): points per gold of donated value. Officer-only,
					-- guild-synced, applied at the moment a donation is received and written into that
					-- entry -- changing it changes future credits only. Not gated by the shop switch: the
					-- donation board existed for plain banks before the store did.
					["donationRate"] = {
						order = 3.6,
						type = "input",
						width = "normal",
						name = "Donation points per gold",
						desc = "What a donation earns: this many points for every gold of value received by a bank character (valued when it arrives, from your price sources, never below what a vendor pays). 1 is the default. Officers can correct a member's points with /togbank donations adjust. Syncs to the whole guild.",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
						validate = function(_, v)
							local D = TOGBankClassic_Donations
							local n = tonumber(v)
							if not n or n ~= n or n < D.RATE_MIN or n > D.RATE_MAX then
								return string.format("Please enter a number between %s and %s.", tostring(D.RATE_MIN), tostring(D.RATE_MAX))
							end
							return true
						end,
						get = function() return tostring(TOGBankClassic_Donations:Rate()) end,
						set = function(_, v) TOGBankClassic_Guild:SetDonationRate(tonumber(v)) end,
					},
					-- STORE-002 / DONATION-VALUE-001 (GUILD_STORE.md 4.2.1): the price authority --
					-- the one character whose price sources become the guild's price list, so every
					-- banker values a donation the same and every member sees the same estimate.
					-- Officer-only, guild-synced; blank means no list. Not gated by the shop switch.
					["priceAuthority"] = {
						order = 3.65,
						type = "input",
						width = "normal",
						name = "Price authority",
						desc = "The character whose price sources (TSM, Auctionator, ItemDB's own scan) become the guild's price list. Their client publishes the list to the guild; every other client -- bank characters especially -- values donations and shows shop estimates from it, so nobody's figure depends on which price addon they run. Leave blank for no guild list (each client prices on its own sources). Syncs to the whole guild.",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
						get = function() return TOGBankClassic_Guild:GetPriceAuthority() or "" end,
						set = function(_, v) TOGBankClassic_Guild:SetPriceAuthority(v) end,
					},
					-- XGUILD-SWITCH-001 (the operator, 2026-09-15: "shouldn't there be some officer
					-- configuration to turn it on or make it work? we have the sister guilds in the
					-- guildroster library"): the sister-guild bank's own section and switch. Off by
					-- default, guild-synced; Guild:SetSisterBankEnabled is the one writer.
					["sisterHeader"] = {
						order = 3.7,
						type = "header",
						name = "Sister guilds",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
					},
					["sisterDesc"] = {
						order = 3.71,
						type = "description",
						name = "One bank across the guilds listed as sister guilds in Guild Roster's settings. On, their bank characters join this bank (tagged with their guild) and their members can browse and order from yours; each guild's officers switch on their own side. Off, this bank is your guild's alone. Bank characters in a sister guild are recognised by the gbank mark in their public note.",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
					},
					["sisterBank"] = {
						order = 3.72,
						type = "toggle",
						width = "full",
						name = "Sister-guild bank",
						desc = "Tick to open this bank to the sister guilds listed in Guild Roster: their bank characters appear on the Bankers tab and in the Banker column, tagged with their guild, and their members can place orders with yours. Both guilds' officers must list each other in Guild Roster (a guild that lists yours without being listed back gets nothing), and the sister guild's officers must tick this on their side too. Untick and the bank is your guild's alone again. Syncs to the whole guild.",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
						get = function() return TOGBankClassic_Guild:IsSisterBankEnabled() end,
						set = function(_, v) TOGBankClassic_Guild:SetSisterBankEnabled(v) end,
					},
					-- HELPNOTE-001: officer-only per-window help-tooltip notes (GM/officers).
					["helpNotesHeader"] = {
						order = 5,
						type = "header",
						name = "Guild Help Notes (officers only)",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
					},
					["helpNotesDesc"] = {
						order = 5.1,
						type = "description",
						name = "Optional notes appended to the bottom of the help (?) tooltip on each window — e.g. how to submit a request and the expected turnaround time. Leave blank for none. These sync to the whole guild.",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
					},
					["helpNoteRequests"] = {
						order = 5.2,
						type = "input",
						multiline = 4,
						width = "full",
						name = "Requests window note",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
						get = function() return TOGBankClassic_Guild:GetHelpNote("requests") end,
						set = function(_, v) TOGBankClassic_Options:SetHelpNote("requests", v) end,
					},
					["helpNoteSearch"] = {
						order = 5.3,
						type = "input",
						multiline = 4,
						width = "full",
						name = "Search window note",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
						get = function() return TOGBankClassic_Guild:GetHelpNote("search") end,
						set = function(_, v) TOGBankClassic_Options:SetHelpNote("search", v) end,
					},
					["helpNoteInventory"] = {
						order = 5.4,
						type = "input",
						multiline = 4,
						width = "full",
						name = "Inventory (main) window note",
						hidden = function() return not (CanViewOfficerNote and CanViewOfficerNote()) end,
						get = function() return TOGBankClassic_Guild:GetHelpNote("inventory") end,
						set = function(_, v) TOGBankClassic_Options:SetHelpNote("inventory", v) end,
					},
					-- SHOP-SECTION-001: directly under the slider it explains, so the request section ends
					-- before the Shop heading rather than resuming after it.
					["exampleGroup"] = {
						order = 3.1,
						type = "group",
						inline = true,
						name = "Example Calculations",
						args = {
							["example1"] = {
								order = 1,
								type = "description",
								fontSize = "medium",
								name = function()
									local pct = self.db.global.requests.maxRequestPercent or 100
									local available = 100
									local maxRequest = math.max(1, math.floor(available * pct / 100))
									return string.format("|cff00ff00Current Setting: %d%%|r\n\nIf bank has %d items available:\n  Max: |cffffd700%d items|r", pct, available, maxRequest)
								end,
							},
							["example2"] = {
								order = 2,
								type = "description",
								fontSize = "medium",
								name = function()
									local pct = self.db.global.requests.maxRequestPercent or 100
									local available = 1
									local maxRequest = math.max(1, math.floor(available * pct / 100))
									return string.format("If bank has %d item available (gear/single):\n  Max: |cffffd700%d item|r", available, maxRequest)
								end,
							},
						},
					},
				},
			},
		},
	}

	LibStub("AceConfig-3.0"):RegisterOptionsTable("TOGBankClassic", options)
	-- SETTINGS-002: AddToBlizOptions' second return is the registered category ID.
	-- On builds that expose C_SettingsUtil.OpenSettingsPanel, Ace3 can no longer
	-- override that ID to the category *name*, so it is a number and the name-based
	-- Settings.OpenToCategory("TOGBankClassic") call errors. Keep the real ID for Open().
	local _, categoryID = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("TOGBankClassic", "TOGBankClassic")
	self.blizCategoryID = categoryID
end

-- SCAN-001: safe to call repeatedly. Callers fire this on every GUILD_RANKS_UPDATE and
-- again once RebuildBankerRoster() has run, because IsBank() is false on the first
-- GUILD_RANKS_UPDATE of a session (memberRoster is still empty and guild notes usually
-- aren't populated yet). Previously this ran at most once, behind Guild:Init()'s
-- once-per-guild return, so losing that race left the Bank options panel unregistered
-- for the whole session with no way for the user to reach the toggle.
function TOGBankClassic_Options:InitGuild()
	if self.guildInitialized then
		return
	end

	local player = TOGBankClassic_Guild:GetPlayer()
	if not TOGBankClassic_Guild:IsBank(player) then
		-- Banker status not established yet; a later call retries.
		return
	end

	-- Latch only on success, so AddToBlizOptions below runs exactly once and we don't
	-- stack duplicate "Bank" panels in the Blizzard options tree.
	self.guildInitialized = true

	-- If this character is recognized as a bank and the per-character option
	-- hasn't been set yet, enable bank reporting by default to avoid manual steps.
	if self.db and self.db.char and self.db.char.bank and self.db.char.bank["enabled"] == nil then
		self.db.char.bank["enabled"] = true
	end

	local bankOptions = {
		type = "group",
		name = "Bank",
		args = {
			["enabled"] = {
				order = 0,
				type = "toggle",
				width = "full",
				name = "Enable for " .. player,
				desc = "Enables reporting and scanning for this player",
				set = function(_, v)
					self.db.char.bank["enabled"] = v
				end,
				get = function()
					return self.db.char.bank["enabled"]
				end,
			},
			["report"] = {
				order = 1,
				type = "toggle",
				width = "full",
				name = "Report contributions",
				desc = "Enables contribution reports",
				set = function(_, v)
					self.db.global.bank["report"] = v
				end,
				get = function()
					return self.db.global.bank["report"]
				end,
			},
			-- UX-WATERFALL-001: the "Enable donations" box that lived here (order 2, "Displays donation
			-- window at mailbox") is GONE. It was a second setting for the one mailbox -- the Donation
			-- popup's -- beside the Mailbox window's own, and a banker with both on got both windows
			-- (crimsonmane, 2026-09-14). The Mailbox window's General setting governs the mailbox now;
			-- the popup stands aside while that window auto-opens, and returns when it is unticked.
			-- The saved `db.char.bank.donations` value is left in place and read by nothing.
			-- HIDE-002 (the operator: "a setting for bankers in settings in the banker only settings,
			-- a check box"). OFF by default: ticking it changes what this banker publishes, and an
			-- upgrade must not do that unasked.
			["hideSoulbound"] = {
				order = 2.5,
				type = "toggle",
				width = "full",
				name = "Hide soulbound items from the guild",
				desc = "Every soulbound item in this character's bags and bank is kept off the guild's view of "
					.. "this bank, as if you had right-clicked each one and hidden it. Your own tab still shows "
					.. "them greyed out. Untick to show them again.",
				set = function(_, v)
					self.db.char.bank["hideSoulbound"] = v and true or false
					-- Takes effect now, not at the next vault visit: the scan re-splits the stored
					-- sources on the new list and republishes.
					if TOGBankClassic_Bank and TOGBankClassic_Bank.OnUpdateStart then
						TOGBankClassic_Bank:OnUpdateStart()
						TOGBankClassic_Bank:Scan()
					end
				end,
				get = function()
					return self.db.char.bank["hideSoulbound"] == true
				end,
			},
			["reset"] = {
				order = 3,
				name = "Reset Player Database",
				type = "execute",
				func = function()
					local guild = TOGBankClassic_Guild:GetGuild()
					if not guild then
						return
					end
					TOGBankClassic_Database:ResetPlayer(guild, player)
				end,
			},
		},
	}

	LibStub("AceConfig-3.0"):RegisterOptionsTable("TOGBankClassic/Bank", bankOptions)
	LibStub("AceConfigDialog-3.0"):AddToBlizOptions("TOGBankClassic/Bank", "Bank", "TOGBankClassic")
end

function TOGBankClassic_Options:GetBankEnabled()
	return self.db.char.bank["enabled"]
end

-- ---------------------------------------------------------------------------------------------
-- VISIBILITY-001: ONE accessibility scale for every TOGBank window
-- ---------------------------------------------------------------------------------------------
-- The operator: *"can we add a visibility feature that makes the font/icons/rows larger on a slider
-- for the visually impared?"* The WORK is LibAceGUIWidgets MINOR 29's -- `W:SetScale(factor)` scales
-- every font, icon, row height, menu, dialog, header and resize floor the library draws, and re-lays
-- every live widget -- so TOGBank's half is the setting, the load-time apply, and (in the windows)
-- the regions TOGBank draws itself. This is the whole persistence and the ONE call site.
--
-- The bounds are the LIBRARY's, read from it rather than copied, so a library that widens the range
-- widens the slider with no edit here. Against a library too old to carry the scale (or absent --
-- it is a declared dependency, but `LibStub(..., true)` is how every other read of it is written)
-- the bounds fall back to the same numbers and `ApplyUIScale` is a no-op: the setting is saved and
-- does nothing, which is the right degradation for an accessibility preference.
local WIDGETS = LibStub("LibAceGUIWidgets-1.0", true)
TOGBankClassic_Options.SCALE_MIN     = (WIDGETS and WIDGETS.SCALE_MIN) or 0.8
TOGBankClassic_Options.SCALE_MAX     = (WIDGETS and WIDGETS.SCALE_MAX) or 2.0
TOGBankClassic_Options.SCALE_DEFAULT = (WIDGETS and WIDGETS.SCALE_DEFAULT) or 1.0

--- The saved factor, clamped to the library's range. `SCALE_DEFAULT` before the DB is up and for a
--- profile from before the setting existed -- nil reads as "normal size", never as 0.
---@return number scale
function TOGBankClassic_Options:GetUIScale()
	local char = self.db and self.db.char
	local v = tonumber(char and char.uiScale)
	if not v then return self.SCALE_DEFAULT end
	if v < self.SCALE_MIN then return self.SCALE_MIN end
	if v > self.SCALE_MAX then return self.SCALE_MAX end
	return v
end

--- Save the factor and apply it. THE ONE WRITER (the slider, and anything else that ever sets it).
---@param v number
function TOGBankClassic_Options:SetUIScale(v)
	if not (self.db and self.db.char) then return end
	self.db.char.uiScale = tonumber(v) or self.SCALE_DEFAULT
	self:ApplyUIScale()
end

--- Hand the saved factor to the library. THE ONE CALLER of `W:SetScale` in this addon: from
--- `SetUIScale` above and from `Core`'s startup, so a reload comes back at the size the player set.
--- Silent against a library without the scale (see the header); the library clamps for itself.
function TOGBankClassic_Options:ApplyUIScale()
	local W = LibStub("LibAceGUIWidgets-1.0", true)
	if not (W and W.SetScale) then return end
	W:SetScale(self:GetUIScale())
end

--- HIDE-002: is this banker hiding every soulbound item from the guild? False before the DB is up.
function TOGBankClassic_Options:GetHideSoulbound()
	local char = self.db and self.db.char
	return (char and char.bank and char.bank["hideSoulbound"]) == true
end

function TOGBankClassic_Options:GetBankReporting()
	return self.db.global.bank["report"]
end

--- MAILBOX-TOGGLE-001: does the Mailbox window open by itself at a mailbox (bank characters)?
--- True unless the player has unticked it; true before the DB is up, and for a saved profile
--- from before the setting existed (nil reads as the default, not as off).
function TOGBankClassic_Options:IsMailboxAutoOpenEnabled()
	local bank = self.db and self.db.global and self.db.global.bank
	local v = bank and bank["mailboxAutoOpen"]
	if v == nil then return true end
	return v == true
end

--- MAILBOX-TOGGLE-002: does the Mailbox window open by itself on characters that are NOT bank
--- characters? Off unless ticked -- "on by default for bankers only" -- so nil (a saved profile
--- from before the setting, or no DB yet) reads as off. Only meaningful while
--- IsMailboxAutoOpenEnabled; Mailbox:AutoOpens asks that first.
function TOGBankClassic_Options:IsMailboxAutoOpenForNonBankersEnabled()
	local bank = self.db and self.db.global and self.db.global.bank
	return (bank and bank["mailboxAutoOpenNonBankers"]) == true
end

function TOGBankClassic_Options:GetLogLevel()
	return self.db.global.bank["logLevel"] or LOG_LEVEL.INFO
end

function TOGBankClassic_Options:GetMinimapEnabled()
	return self.db.char.minimap["enabled"]
end

function TOGBankClassic_Options:GetCombatHide()
	return self.db.char.combat["hide"]
end

function TOGBankClassic_Options:IsSyncProgressMuted()
	return self.db.global.bank["muteSyncProgress"] or false
end

function TOGBankClassic_Options:IsWarningsMuted()
	return self.db.global.bank["muteWarnings"] or false
end

function TOGBankClassic_Options:IsOrderFulfillmentSoundEnabled()
	if not self.db or not self.db.global or not self.db.global.bank then return true end
	local v = self.db.global.bank["orderFulfillmentSound"]
	return v == nil and true or v
end

function TOGBankClassic_Options:IsIntegrityCheckDiagnosticsEnabled()
	if not self.db or not self.db.global or not self.db.global.bank then return false end
	return self.db.global.bank["integrityCheckDiagnostics"] or false
end

--- RAID-SYNC-001: has the player opted OUT of the raid guard? False until the box is ticked, and
--- false before the database exists -- the guard is the default, never the exception.
function TOGBankClassic_Options:IsSyncInRaidEnabled()
	if not self.db or not self.db.global or not self.db.global.bank then return false end
	return self.db.global.bank["syncInRaid"] == true
end

function TOGBankClassic_Options:IsStatusBarNetworkInfoEnabled()
	if not self.db or not self.db.char then return true end
	local v = self.db.char.statusBarNetworkInfo
	return v == true
end

function TOGBankClassic_Options:GetMaxRequestPercent()
	-- REQUEST-LIMIT-ONE-RULE-001 (self-audit 4777d14a F3): the guild-synced value is read through
	-- Guild:MaxRequestPercent, the same read Guild:AddRequest enforces -- this used to return the raw
	-- stored number, so a stored 33.7 or 0 showed 33.7 / 0 here while the gate enforced 33 / 1, and
	-- TOGProfessionMaster's fallback path reads THIS getter.
	local G = TOGBankClassic_Guild
	if G and G.Info and G.Info.settings and G.MaxRequestPercent then
		return G:MaxRequestPercent()
	end
	-- Fall back to the local setting if guild data is not loaded yet, clamped the same way.
	local v = self.db and self.db.global and self.db.global.requests and tonumber(self.db.global.requests.maxRequestPercent) or 100
	v = math.floor(v)
	if v < 1 then return 1 end
	if v > 100 then return 100 end
	return v
end

function TOGBankClassic_Options:GetAutoTombstoneDays()
	-- Read from guild-synced settings first (officer/banker-configured, syncs to all clients)
	if TOGBankClassic_Guild and TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.settings then
		local v = TOGBankClassic_Guild.Info.settings.autoTombstoneDays
		if v and v > 0 then return v end
	end
	if self.db and self.db.global and self.db.global.requests then
		return self.db.global.requests.autoTombstoneDays or 30
	end
	return 30
end

-- HELPNOTE-001: write an officer help note for a window into the guild-synced
-- settings and broadcast it. windowKey: "inventory" / "search" / "requests".
function TOGBankClassic_Options:SetHelpNote(windowKey, value)
	value = string.sub(tostring(value or ""), 1, 400)
	local g = TOGBankClassic_Guild
	if g and g.Info and g.Info.settings then
		if type(g.Info.settings.helpNotes) ~= "table" then
			g.Info.settings.helpNotes = { inventory = "", search = "", requests = "" }
		end
		g.Info.settings.helpNotes[windowKey] = value
		if g.BroadcastSettings then
			g:BroadcastSettings("ALERT")  -- SETTINGS-001: propagate to the guild
		end
		TOGBankClassic_Output:Info("Updated the %s window help note (syncing to guild...).", windowKey)
	end
end

function TOGBankClassic_Options:IsRegisterBankCommandEnabled()
	if not self.db or not self.db.global or not self.db.global.bank then return true end
	local v = self.db.global.bank["registerBankCommand"]
	return v ~= false
end

function TOGBankClassic_Options:IsRegisterGbankCommandEnabled()
	if not self.db or not self.db.global or not self.db.global.bank then return true end
	local v = self.db.global.bank["registerGbankCommand"]
	return v ~= false
end

-- SETTINGS-002: resolve the Blizzard Settings category ID for our panel. Prefer the
-- ID captured at registration, then Ace3's name->ID map (covers a re-registration we
-- didn't see), and finally the raw name for older builds where Ace3 forced the ID to
-- equal the category name.
function TOGBankClassic_Options:GetBlizCategoryID()
	if self.blizCategoryID then
		return self.blizCategoryID
	end
	local dialog = LibStub("AceConfigDialog-3.0", true)
	local mapped = dialog and dialog.BlizOptionsIDMap and dialog.BlizOptionsIDMap["TOGBankClassic"]
	if mapped then
		self.blizCategoryID = mapped
		return mapped
	end
	return "TOGBankClassic"
end

function TOGBankClassic_Options:Open()
	if not (Settings and Settings.OpenToCategory) then
		TOGBankClassic_Output:Error("Could not open the settings panel: the Settings API is unavailable.")
		return
	end
	Settings.OpenToCategory(self:GetBlizCategoryID())
end
