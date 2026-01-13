TOGBankClassic_Options = {}

function TOGBankClassic_Options:Init()
	self.db = LibStub("AceDB-3.0"):New("TOGBankClassicOptionDB")
	if self.db.char.minimap == nil then
		self.db.char.minimap = { enabled = true }
	end
	if self.db.char.combat == nil then
		self.db.char.combat = { hide = true }
	end
	if self.db.char.bank == nil then
		self.db.char.bank = {}
	end
	if self.db.char.bank["donations"] == nil then
		self.db.char.bank["donations"] = true
	end
	if self.db.global.bank == nil then
		self.db.global.bank = { report = true, logLevel = LOG_LEVEL.INFO }
	end
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
	-- Initialize logger with saved level
	TOGBankClassic_Output:SetLevel(self.db.global.bank["logLevel"])

	local options = {
		type = "group",
		---START CHANGES
		--name = "TOGBankClassic",
		name = "TOGBankClassic",
		---END CHANGES
		args = {
			["minimap"] = {
				order = 0,
				type = "toggle",
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
				name = "Log Level",
				desc = "Controls which messages are shown in chat",
				values = {
					[LOG_LEVEL.DEBUG] = "Debug (show everything)",
					[LOG_LEVEL.INFO] = "Info (default)",
					[LOG_LEVEL.WARN] = "Warnings only",
					[LOG_LEVEL.ERROR] = "Errors only",
					[LOG_LEVEL.RESPONSE] = "Silent (commands only)",
				},
				sorting = { LOG_LEVEL.DEBUG, LOG_LEVEL.INFO, LOG_LEVEL.WARN, LOG_LEVEL.ERROR, LOG_LEVEL.RESPONSE },
				set = function(_, v)
					self.db.global.bank["logLevel"] = v
					TOGBankClassic_Output:SetLevel(v)
				end,
				get = function()
					return self.db.global.bank["logLevel"]
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
				order = 0,
				type = "toggle",
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
				order = 1,
				type = "toggle",
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
				order = 2,
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

function TOGBankClassic_Options:Open()
	-- NOTE: WoW API bug, requires call twice to open to specific category
	---START CHANGES
	Settings.OpenToCategory("TOGBankClassic")
	---END CHANGES
end

