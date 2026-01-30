TOGBankClassic_Options = {}

function TOGBankClassic_Options:Init()
	local defaults = {
		char = {
			minimap = { enabled = true },
			combat = { hide = true },
			bank = { donations = true },
			framePositions = {},  -- Stores window positions/sizes
		},
		global = {
			bank = { report = true, logLevel = LOG_LEVEL.INFO, protocolMode = "AUTO", commDebug = false },
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
				args = {
					["debugHeader"] = {
						order = 0,
						type = "header",
						name = "Debug Categories",
					},
					["debugDesc"] = {
						order = 1,
						type = "description",
						name = "Enable specific debug categories to filter output. Categories are only active when Log Level is set to 'Debug'.",
					},
					["showUncategorized"] = {
						order = 2,
						type = "toggle",
						width = "full",
						name = "Show Uncategorized Debug Messages (legacy)",
						desc = "Show old debug messages that don't have a category assigned. Disable this to only see categorized messages.",
						set = function(_, v)
							TOGBankClassic_Database.db.global.showUncategorizedDebug = v
						end,
						get = function()
							return TOGBankClassic_Database.db.global.showUncategorizedDebug
						end,
					},
					["spacer1"] = {
						order = 9,
						type = "description",
						name = " ",
					},
					["roster"] = {
						order = 10,
						type = "toggle",
						width = "full",
						name = "ROSTER - Guild roster updates, online/offline tracking",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("ROSTER", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("ROSTER")
						end,
					},
					["comms"] = {
						order = 11,
						type = "toggle",
						width = "full",
						name = "COMMS - All addon communication traffic (high volume)",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("COMMS", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("COMMS")
						end,
					},
					["delta"] = {
						order = 12,
						type = "toggle",
						width = "full",
						name = "DELTA - Delta sync operations and computations",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("DELTA", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("DELTA")
						end,
					},
					["sync"] = {
						order = 13,
						type = "toggle",
						width = "full",
						name = "SYNC - Data synchronization operations",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("SYNC", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("SYNC")
						end,
					},
					["cache"] = {
						order = 14,
						type = "toggle",
						width = "full",
						name = "CACHE - Cache operations (guild roster cache, etc.)",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("CACHE", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("CACHE")
						end,
					},
					["whisper"] = {
						order = 15,
						type = "toggle",
						width = "full",
						name = "WHISPER - Whisper sends, skips, and online checks",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("WHISPER", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("WHISPER")
						end,
					},
					["requests"] = {
						order = 16,
						type = "toggle",
						width = "full",
						name = "REQUESTS - Request system activity and updates",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("REQUESTS", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("REQUESTS")
						end,
					},
					["ui"] = {
						order = 17,
						type = "toggle",
						width = "full",
						name = "UI - UI operations, window opens/closes",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("UI", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("UI")
						end,
					},
					["protocol"] = {
						order = 18,
						type = "toggle",
						width = "full",
						name = "PROTOCOL - Protocol version negotiation",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("PROTOCOL", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("PROTOCOL")
						end,
					},
					["database"] = {
						order = 19,
						type = "toggle",
						width = "full",
						name = "DATABASE - Database operations, SavedVariables",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("DATABASE", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("DATABASE")
						end,
					},
					["events"] = {
						order = 20,
						type = "toggle",
						width = "full",
						name = "EVENTS - WoW event handling (GUILD_ROSTER_UPDATE, etc.)",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("EVENTS", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("EVENTS")
						end,
					},
					["mail"] = {
						order = 21,
						type = "toggle",
						width = "full",
						name = "MAIL - Mail inventory scanning and tracking",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("MAIL", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("MAIL")
						end,
					},
					["item"] = {
						order = 22,
						type = "toggle",
						width = "full",
						name = "ITEM - Item loading, validation, and processing",
						set = function(_, v)
							TOGBankClassic_Output:SetCategoryEnabled("ITEM", v)
						end,
						get = function()
							return TOGBankClassic_Output:IsCategoryEnabled("ITEM")
						end,
					},
					["spacer"] = {
						order = 30,
						type = "description",
						name = " ",
					},
					["enableAll"] = {
						order = 31,
						type = "execute",
						name = "Enable All Categories",
						func = function()
							TOGBankClassic_Output:EnableAllCategories()
							TOGBankClassic_Output:Info("All debug categories enabled")
						end,
					},
					["disableAll"] = {
						order = 32,
						type = "execute",
						name = "Disable All Categories",
						func = function()
							TOGBankClassic_Output:DisableAllCategories()
							TOGBankClassic_Output:Info("All debug categories disabled")
						end,
					},
					["spacer2"] = {
						order = 40,
						type = "description",
						name = " ",
					},
					["perfHeader"] = {
						order = 41,
						type = "header",
						name = "Performance Monitoring",
					},
					["perfEnabled"] = {
						order = 42,
						type = "toggle",
						width = "full",
						name = "Enable Performance Monitoring",
						desc = "Track event frequency, operation timing, and memory usage. Disable to reduce overhead if experiencing performance issues.",
						get = function() return TOGBankClassic_PerfEnabled end,
						set = function(info, value)
							TOGBankClassic_PerfEnabled = value
							if value then
								TOGBankClassic_Output:Info("Performance monitoring enabled")
							else
								TOGBankClassic_Output:Info("Performance monitoring disabled")
							end
						end,
					},
					["perfStatsButton"] = {
						order = 43,
						type = "execute",
						width = "full",
						name = "Show Performance Statistics",
						desc = "Display event frequency, operation timing, and memory usage for current session",
						func = function()
							TOGBankClassic_Performance:PrintReport()
						end,
					},
					["spacer3"] = {
						order = 44,
						type = "description",
						name = " ",
					},
					["debugLogHeader"] = {
						order = 45,
						type = "header",
						name = "Debug Logging",
					},
					["debugLogEnabled"] = {
						order = 46,
						type = "toggle",
						width = "full",
						name = "Enable Debug Log to SavedVariables",
						desc = "Save debug messages to SavedVariables (TOGBankClassicDB_DebugLog). Auto-cleans old entries (max 50,000 entries or 7 days). Disable to reduce SavedVariables file size.",
						get = function() return TOGBankClassic_DebugLogEnabled end,
						set = function(info, value)
							TOGBankClassic_DebugLogEnabled = value
							if value then
								TOGBankClassic_Output:Info("Debug logging to SavedVariables enabled")
							else
								TOGBankClassic_Output:Info("Debug logging to SavedVariables disabled")
							end
						end,
					},
				},
			},
		},
	}

	---START CHANGES
	--LibStub("AceConfig-3.0"):RegisterOptionsTable("TOGBankClassic", options)
	--LibStub("AceConfigDialog-3.0"):AddToBlizOptions("TOGBankClassic", "TOGBankClassic")
	LibStub("AceConfig-3.0"):RegisterOptionsTable("TOGBankClassic", options)
	LibStub("AceConfigDialog-3.0"):AddToBlizOptions("TOGBankClassic", "TOGBankClassic")
	---END CHANGES
end

function TOGBankClassic_Options:InitGuild()
	---START CHANGES
	-- Guild banks shouldn't be required to read the officer note, perhaps we want to use public note
	--if not CanViewOfficerNote() then return end
	---END CHANGES

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

	---START CHANGES
	--LibStub("AceConfig-3.0"):RegisterOptionsTable("TOGBankClassic/Bank", bankOptions)
	--LibStub("AceConfigDialog-3.0"):AddToBlizOptions("TOGBankClassic/Bank", "Bank", "TOGBankClassic")
	LibStub("AceConfig-3.0"):RegisterOptionsTable("TOGBankClassic/Bank", bankOptions)
	LibStub("AceConfigDialog-3.0"):AddToBlizOptions("TOGBankClassic/Bank", "Bank", "TOGBankClassic")
	---END CHANGES
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

function TOGBankClassic_Options:Open()
	-- NOTE: WoW API bug, requires call twice to open to specific category
	---START CHANGES
	Settings.OpenToCategory("TOGBankClassic")
	---END CHANGES
end