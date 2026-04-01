-- ─── Debug category metadata ────────────────────────────────────────────────
-- Controls display order and description text in the Options UI.
-- Must stay in sync with DEBUG_CATEGORY in Constants.lua.
local CATEGORY_META = {
	CACHE    = { order = 10, desc = "Cache operations (guild roster cache, etc.)" },
	COMMS    = { order = 11, desc = "All addon communication traffic (high volume)" },
	DATABASE = { order = 12, desc = "Database operations, SavedVariables" },
	DELTA    = { order = 13, desc = "Delta sync operations and computations" },
	EVENTS   = { order = 14, desc = "WoW event handling (GUILD_ROSTER_UPDATE, etc.)" },
	ITEM     = { order = 15, desc = "Item loading, validation, and processing" },
	MAIL     = { order = 16, desc = "Mail inventory scanning and tracking" },
	P2P      = { order = 17, desc = "Session manager: collect window, dispatch, handshake" },
	PROTOCOL = { order = 18, desc = "Protocol version negotiation (includes INTEGRITY-MISMATCH CRC errors and SERIAL outgoing checksum tracing)" },
	QUERIES  = { order = 19, desc = "P2P query/response decisions and hash matching" },
	REQUESTS = { order = 20, desc = "Request system activity and updates" },
	ROSTER   = { order = 21, desc = "Guild roster updates, online/offline tracking" },
	SYNC     = { order = 22, desc = "Data synchronization operations" },
	UI       = { order = 23, desc = "UI operations, window opens/closes (includes SEARCH keystroke and DrawContent timing)" },
	WHISPER  = { order = 24, desc = "Whisper sends, skips, and online checks" },
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

-- ─────────────────────────────────────────────────────────────────────────────
TOGBankClassic_Options = {}

function TOGBankClassic_Options:Init()
	local defaults = {
		char = {
			minimap = { enabled = true },
			combat = { hide = true },
			bank = { donations = true },
			framePositions = {},  -- Stores window positions/sizes
			sortMode = "alpha",   -- Inventory sort mode: "alpha" (A->Z) or "type" (by item type)
			statusBarNetworkInfo = false,  -- Show sync activity in inventory status bar
		},
		global = {
			bank = { report = true, logLevel = LOG_LEVEL.INFO, protocolMode = "AUTO", commDebug = false, integrityCheckDiagnostics = false },
			requests = {
				maxRequestPercent = 100,  -- Maximum % of available items that can be requested (100 = no limit)
				archiveDays = 30,  -- Requests older than this many days are moved to the Archive tab
				autoTombstoneDays = 30,  -- Stale open requests older than this are auto-cancelled on receive
			},
		},
	}
	self.db = LibStub("AceDB-3.0"):New("TOGBankClassicOptionDB", defaults)
	-- Migrate from old shutup toggle to new logLevel
	if self.db.global.bank["shutup"] ~= nil then
		if self.db.global.bank["shutup"] == true then
			self.db.global.bank["logLevel"] = LOG_LEVEL.RESPONSE
		end
		self.db.global.bank["shutup"] = nil
	end
	if self.db.global.bank["logLevel"] == nil then
		self.db.global.bank["logLevel"] = LOG_LEVEL.INFO
	end
	if self.db.global.bank["protocolMode"] == nil then
		self.db.global.bank["protocolMode"] = "AUTO"
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
	if self.db.global.requests.archiveDays == nil then
		self.db.global.requests.archiveDays = 30
	end
	if self.db.global.requests.autoTombstoneDays == nil then
		self.db.global.requests.autoTombstoneDays = 30
	end
	-- Initialize logger with saved level
	TOGBankClassic_Output:SetLevel(self.db.global.bank["logLevel"])
	-- Initialize comm debug with saved setting
	TOGBankClassic_Output:SetCommDebug(self.db.global.bank["commDebug"])
	-- Initialize protocol mode with saved setting
	FEATURES.PROTOCOL_MODE = self.db.global.bank["protocolMode"]

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
					["protocolMode"] = {
						order = 3,
						type = "select",
						style = "dropdown",
						width = "full",
						name = "Communication Protocol",
						desc = "Choose which message format to use for syncing bank data",
						values = {
							AUTO = PROTOCOL_MODES.AUTO.name,
							LEGACY_ONLY = PROTOCOL_MODES.LEGACY_ONLY.name,
							NEW_ONLY = PROTOCOL_MODES.NEW_ONLY.name,
						},
						sorting = { "AUTO", "LEGACY_ONLY", "NEW_ONLY" },
						set = function(_, v)
							self.db.global.bank["protocolMode"] = v
							FEATURES.PROTOCOL_MODE = v
							TOGBankClassic_Output:Info("Protocol mode changed to: %s", PROTOCOL_MODES[v].name)
						end,
						get = function()
							return self.db.global.bank["protocolMode"]
						end,
					},
					["protocolModeDesc"] = {
						order = 4,
						type = "description",
						width = "full",
						name = function()
							local mode = PROTOCOL_MODES[FEATURES.PROTOCOL_MODE] or PROTOCOL_MODES.AUTO
							return "|cffFFFFFF" .. mode.desc .. "|r"
						end,
					},
					["reset"] = {
						order = -1,
						name = "Reset Database",
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
			debug = {
				order = 2,
				type = "group",
				name = "Debug",
				args = BuildDebugArgs(),
			},
			requests = {
				order = 3,
				type = "group",
				name = "Requests",
				hidden = function()
					-- Show to officers or bankers
					if CanViewOfficerNote() then return false end
					local player = TOGBankClassic_Guild:GetNormalizedPlayer()
					return not (player and TOGBankClassic_Guild:IsBank(player))
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
						desc = "Limit how much of available inventory can be requested at once. Set to 100% to allow requesting everything. Lower values help share inventory among multiple guild members.\n\nExample: At 50%, if bank has 100 Copper Ore, members can request up to 50.\n\nNote: Single items (like gear) can always be requested even at low percentages.",
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
					["exampleGroup"] = {
						order = 4,
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
	LibStub("AceConfigDialog-3.0"):AddToBlizOptions("TOGBankClassic", "TOGBankClassic")
end

function TOGBankClassic_Options:InitGuild()
	local player = TOGBankClassic_Guild:GetPlayer()
	if not TOGBankClassic_Guild:IsBank(player) then
		return
	end

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
			["donations"] = {
				order = 2,
				type = "toggle",
				width = "full",
				name = "Enable donations",
				desc = "Displays donation window at mailbox",
				set = function(_, v)
					self.db.char.bank["donations"] = v
				end,
				get = function()
					return self.db.char.bank["donations"]
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

function TOGBankClassic_Options:GetDonationEnabled()
	return self.db.char.bank["donations"]
end

function TOGBankClassic_Options:GetBankReporting()
	return self.db.global.bank["report"]
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

function TOGBankClassic_Options:IsIntegrityCheckDiagnosticsEnabled()
	if not self.db or not self.db.global or not self.db.global.bank then return false end
	return self.db.global.bank["integrityCheckDiagnostics"] or false
end

function TOGBankClassic_Options:IsStatusBarNetworkInfoEnabled()
	if not self.db or not self.db.char then return true end
	local v = self.db.char.statusBarNetworkInfo
	return v == true
end

function TOGBankClassic_Options:GetMaxRequestPercent()
	-- Read from guild-synced settings first (officer-configured, syncs to all clients)
	if TOGBankClassic_Guild and TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.settings then
		return TOGBankClassic_Guild.Info.settings.maxRequestPercent or 100
	end
	-- Fall back to local setting if guild data not loaded yet
	if not self.db or not self.db.global or not self.db.global.requests then
		return 100
	end
	return self.db.global.requests.maxRequestPercent or 100
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

function TOGBankClassic_Options:Open()
	-- NOTE: WoW API bug, requires call twice to open to specific category
	Settings.OpenToCategory("TOGBankClassic")
end
