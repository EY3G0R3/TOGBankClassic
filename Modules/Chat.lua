TOGBankClassic_Chat = {}

function TOGBankClassic_Chat:Init()
	TOGBankClassic_Core:RegisterChatCommand("togbank", function(input)
		return TOGBankClassic_Chat:ChatCommand(input)
	end)

	self.addon_outdated = false

	self.debug = false

	self.last_roster_sync = nil
	self.last_alt_sync = {}
	self.sync_queue = {}
	self.is_syncing = false
	self.last_share_sync = nil

	TOGBankClassic_Core:RegisterComm("togbank-d", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-v", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-r", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-h", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-hr", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-s", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)
	TOGBankClassic_Core:RegisterComm("togbank-sr", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-w", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)
	TOGBankClassic_Core:RegisterComm("togbank-wr", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)
end

-- TODO: extend this pattern to all other classes
function TOGBankClassic_Chat:Debug(...)
	if self.debug then
		TOGBankClassic_Core:Print(...)
		return true
	end
	return false
end

local function ColorPlayerName(name)
	if not name or name == "" then
		return ""
	end
	local normalized = name
	if TOGBankClassic_Guild and TOGBankClassic_Guild.NormalizeName then
		normalized = TOGBankClassic_Guild:NormalizeName(name) or name
	end
	if TOGBankClassic_Guild and TOGBankClassic_Guild.GetPlayerInfo then
		local class = TOGBankClassic_Guild:GetPlayerInfo(normalized)
		if class then
			local _, _, _, color = GetClassColor(class)
			if color then
				return string.format("|c%s%s|r", color, name)
			end
		end
	end
	return string.format("|cff80bfff%s|r", name)
end

function TOGBankClassic_Chat:IsAltDataAllowed_Restrictive(sender, claimedNorm)
	-- 'sender' was normalized near the top of OnCommReceived
	local hasExistingAlt = false
	if TOGBankClassic_Guild and TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts then
		local existingAlt = TOGBankClassic_Guild.Info.alts[claimedNorm]
		hasExistingAlt = existingAlt ~= nil and type(existingAlt) == "table"
	end
	local allowed = false
	-- If the sender is the claimed owner, always accept
	if sender == claimedNorm then
		allowed = true
	else
		-- If the claimed owner is a registered bank toon, only accept from bank-marked senders
		local claimedIsBank = TOGBankClassic_Guild:IsBank(claimedNorm)
		if claimedIsBank then
			if
				TOGBankClassic_Guild
				and TOGBankClassic_Guild.SenderHasGbankNote
				and TOGBankClassic_Guild:SenderHasGbankNote(sender)
			then
				allowed = true
			else
				allowed = false
				-- Allow relayed data only when we have no entry yet
				if not hasExistingAlt then
					allowed = true
				end
			end
		else
			-- claimed owner is not a bank toon: accept delegated shares from anyone
			allowed = true
		end
	end
	return allowed
end

function TOGBankClassic_Chat:IsAltDataAllowed_Permissive(_, _)
	return true
end

function TOGBankClassic_Chat:IsAltDataAllowed(sender, claimedNorm)
	return self:IsAltDataAllowed_Permissive(sender, claimedNorm)
end

function TOGBankClassic_Chat:OnCommReceived(prefix, message, _, sender)
	local prefixDescriptions = {
		["togbank-v"] = "(Version)",
		["togbank-d"] = "(Data)",
		["togbank-r"] = "(Query)",
		["togbank-h"] = "(Hello)",
		["togbank-hr"] = "(Hello Reply)",
		["togbank-s"] = "(Share)",
		["togbank-sr"] = "(Share Reply)",
		["togbank-w"] = "(Wipe)",
		["togbank-wr"] = "(Wipe Reply)",
	}
	local prefixDesc = prefixDescriptions[prefix] or "(Unknown)"
	if IsInRaid() then
		self:Debug("> /ignoring/", prefix, prefixDesc, "from", ColorPlayerName(sender), "(in raid)")
		return
	end
	local player = TOGBankClassic_Guild:GetPlayer()
	-- Normalize the sender so spacing/hyphen formats match
	sender = TOGBankClassic_Guild:NormalizeName(sender)

	if player == sender then
		self:Debug("> /ignoring/", prefix, prefixDesc, "(our own)")
		return
	end

	local success, data = TOGBankClassic_Core:Deserialize(message)
	if not success then
		self:Debug("> failed to deserialize", prefix, prefixDesc, "from", ColorPlayerName(sender))
		return
	end

	if prefix ~= "togbank-r" and prefix ~= "togbank-d" then
		-- togbank-r and togbank-d do their own output
		self:Debug(">", ColorPlayerName(sender), ">", prefix, prefixDesc)
	end

	if prefix == "togbank-v" then
		local current_data = TOGBankClassic_Guild:GetVersion()
		if current_data then
			if data.name then
				if current_data.name ~= data.name then
					TOGBankClassic_Core:Print("A non-guild version!")
					return
				end
			end
			if data.addon and current_data.addon then
				if data.addon > current_data.addon then
					if not self.addon_outdated then
						-- only make the callout once
						self.addon_outdated = true
						TOGBankClassic_Core:Print(
							"A newer version is available! Download it from https://www.curseforge.com/wow/addons/togbankclassic/"
						)
					end
				end
			end
			if data.roster then
				if current_data.roster == nil or data.roster > current_data.roster then
					self:Debug(">", ColorPlayerName(sender), "has fresher roster data, querying.")
					TOGBankClassic_Guild:QueryRoster(sender, data.roster)
				end
			end
			if data.requests then
				local logSummary = data.requestLog
				if type(logSummary) == "table" then
					local missing = {}
					local currentLog = current_data.requestLog or {}
					for actor, seq in pairs(logSummary) do
						local have = tonumber(currentLog[actor] or 0) or 0
						local remoteSeq = tonumber(seq or 0) or 0
						if remoteSeq > have then
							missing[actor] = have + 1
						end
					end
					if next(missing) then
						self:Debug(">", ColorPlayerName(sender), "has fresher requests data, querying.")
						TOGBankClassic_Guild:QueryRequestLog(sender, missing)
					elseif data.requests and current_data.requests and data.requests > current_data.requests then
						self:Debug(">", ColorPlayerName(sender), "has fresher requests snapshot, querying.")
						TOGBankClassic_Guild:QueryRequestsSnapshot(sender)
					end
				else
					local currentRequests = current_data.requests
					if currentRequests == nil or data.requests > currentRequests then
						self:Debug(">", ColorPlayerName(sender), "has fresher requests data, querying.")
						TOGBankClassic_Guild:QueryRequestsSnapshot(sender)
					end
				end
			end
			if data.alts then
				for k, v in pairs(data.alts) do
					local kNorm = TOGBankClassic_Guild:NormalizeName(k)
					if not current_data.alts[kNorm] or v > current_data.alts[kNorm] then
						self:Debug(
							">",
							ColorPlayerName(sender),
							"has fresher bank data about",
							ColorPlayerName(kNorm) .. ", querying."
						)
						TOGBankClassic_Guild:QueryAlt(sender, kNorm, v)
					end
				end
			end
		end
	end

	if prefix == "togbank-r" then
		self:Debug(
			">",
			ColorPlayerName(sender),
			"queries",
			ColorPlayerName(data.player),
			"about",
			data.type,
			data.name and ColorPlayerName(TOGBankClassic_Guild:NormalizeName(data.name)) or ""
		)

		if data.player == player then
			if data.type == "roster" then
				local time = GetServerTime()
				if self.last_roster_sync == nil or time - self.last_roster_sync > 300 then
					self.last_roster_sync = time
					TOGBankClassic_Guild:SendRosterData()
				end
			end

			if data.type == "requests" then
				TOGBankClassic_Guild:SendRequestsSnapshot()
			end
			if data.type == "requests-log" then
				TOGBankClassic_Guild:SendRequestLogEntries(sender, data.logFrom)
			end

			if data.type == "alt" then
				local nameNorm = TOGBankClassic_Guild:NormalizeName(data.name)
				table.insert(self.sync_queue, nameNorm)
				if not self.is_syncing then
					TOGBankClassic_Chat:ProcessQueue()
				end
			end
		end
	end

	if prefix == "togbank-d" then
		if data.type == "roster" then
			-- only accept roster updates from a sender that is marked as a bank in guild notes, or from the guild master
			local allowed = (
				TOGBankClassic_Guild
				and TOGBankClassic_Guild.SenderHasGbankNote
				and TOGBankClassic_Guild:SenderHasGbankNote(sender)
			) or TOGBankClassic_Guild:SenderIsGM(sender)
			if TOGBankClassic_Guild:ConsumePendingSync("roster", sender) then
				allowed = true
			end
			self:Debug(
				">",
				ColorPlayerName(sender),
				"shares roster data. We",
				allowed and "accept it." or "do not accept it."
			)
			if allowed then
				TOGBankClassic_Guild:ReceiveRosterData(data.roster)
			end
		end

		if data.type == "requests" then
			self:Debug(">", ColorPlayerName(sender), "shares requests snapshot. We accept it by default.")
			TOGBankClassic_Guild:ReceiveRequestsData(data)
		end
		if data.type == "requests-log" then
			TOGBankClassic_Guild:ReceiveRequestLogEntries(data, sender)
		end

		if data.type == "alt" then
			-- only accept alt data if the sender matches the claimed alt name
			local claimed = data.name
			local claimedNorm = TOGBankClassic_Guild:NormalizeName(claimed)
			local allowed = self:IsAltDataAllowed(sender, claimedNorm)
			if TOGBankClassic_Guild:ConsumePendingSync("alt", sender, claimedNorm) then
				allowed = true
			end
			self:Debug(
				">",
				ColorPlayerName(sender),
				"shares bank data about",
				ColorPlayerName(claimedNorm) .. ". We",
				allowed and "accept it." or "do not accept it."
			)
			if allowed then
				-- this can still result in nothing because ReceiveAltData() compares the timestamps
				TOGBankClassic_Guild:ReceiveAltData(claimedNorm, data.alt)
			else
				-- ignore spoofed alt data
				return
			end
		end
	end

	if prefix == "togbank-h" then
		TOGBankClassic_Guild:Hello("reply")
	end
	if prefix == "togbank-hr" then
		self:Debug(data)
	end
	if prefix == "togbank-s" then
		TOGBankClassic_Guild:Share("reply")
		local now = GetServerTime()
		if not self.last_share_sync or now - self.last_share_sync > 30 then
			self.last_share_sync = now
			TOGBankClassic_Events:Sync()
		end
	end
	if prefix == "togbank-w" then
		TOGBankClassic_Guild:Wipe("reply")
	end
end

function TOGBankClassic_Chat:ChatCommand(input)
	if input == nil or input == "" then
		TOGBankClassic_UI_Inventory:Toggle()
	else
		local commands = {
			["sync"] = function()
				TOGBankClassic_Events:Sync()
			end,
			["reset"] = function()
				local guild = TOGBankClassic_Guild:GetGuild()
				if not guild then
					return
				end
				TOGBankClassic_Guild:Reset(guild)
			end,
			["share"] = function()
				TOGBankClassic_Bank:OnUpdateStart()
				TOGBankClassic_Bank:OnUpdateStop()
				TOGBankClassic_Guild:Share()
			end,
			["help"] = function()
				TOGBankClassic_Chat:ShowHelp()
			end,
			["version"] = function()
				local version = GetAddOnMetadata("TOGBankClassic", "Version") or "unknown"
				TOGBankClassic_Core:Print("TOGBankClassic version:", version)
			end,
			["debug"] = function()
				self.debug = not self.debug
				TOGBankClassic_Core:Print("Debug:", tostring(self.debug))
			end,
			["debugdump"] = function()
				local G = TOGBankClassic_Guild
				if not G or not G.Info or not G.Info.alts then
					TOGBankClassic_Core:Print("no alts table available")
					return
				end
				TOGBankClassic_Core:Print("Listing Info.alts keys:")
				local i = 0
				for k, v in pairs(G.Info.alts) do
					i = i + 1
					TOGBankClassic_Core:Print(i, tostring(k), type(v))
					if i >= 200 then
						TOGBankClassic_Core:Print("truncated at 200 entries")
						break
					end
				end
				if i == 0 then
					TOGBankClassic_Core:Print("no entries")
				end
			end,

			["hello"] = function()
				TOGBankClassic_Guild:Hello()
			end,
			["wipeall"] = function()
				TOGBankClassic_Guild:Wipe()
			end,
			["wipe"] = function()
				TOGBankClassic_Guild:WipeMine()
			end,
			["roster"] = function()
				TOGBankClassic_Guild:AuthorRosterData()
			end,
			["requestlog"] = function(arg1)
				TOGBankClassic_Guild:PrintRequestLog(arg1)
			end,
		}

		local prefix, arg1 = TOGBankClassic_Core:GetArgs(input, 2)
		local cmd = commands[prefix]
		if cmd ~= nil then
			cmd(arg1)
		else
			TOGBankClassic_Core:Print("Unknown command: ", prefix)
			TOGBankClassic_Chat:ShowHelp()
		end
	end

	return false
end

function TOGBankClassic_Chat:ShowHelp()
	TOGBankClassic_Core:Print(
		"\n|cff33ff99Commands:|r\n|cffe6cc80/togbank|r (to display the TOGBankClassic interface) \n|cffe6cc80/togbank help|r (this message) \n|cffe6cc80/togbank version|r (to display the TOGBankClassic version) \n|cffe6cc80/togbank sync|r (to manually receive the latest data from other online users with guild bank data; this is done every 10 minutes automatically) \n|cffe6cc80/togbank share|r (to manually share the contents of your guild bank with other online users of TOGBankClassic; this is done every 3 minutes automatically), \n|cffe6cc80/togbank reset|r (to reset your own TOGBankClassic database)\n"
	)
	TOGBankClassic_Core:Print(
		"\n|cff33ff99Expert commands:|r\n|cffe6cc80/togbank roster|r (guild banks and members that can read the officer note can use this command to share updated roster data with online guild members)\n|cffe6cc80/togbank hello|r (understand which online guild members use which addon version and know what guild bank data; needs corresponding weakaura to print deserliazed addon communication)\n|cffe6cc80/togbank requestlog [N|all]|r (print the request log, optionally limited to N entries)\n|cffe6cc80/togbank wipe|r (reset your own TOGBankClassic database)\n|cffe6cc80/togbank wipeall|r (officer only: reset your own TOGBankClassic database and that of all online guild members)"
	)
	TOGBankClassic_Core:Print(
		"\n|cff33ff99Instructions for setting up a new guild bank:|r\n1. Log in with the guild bank character, ensuring they are in the guild.\n2. Add |cffe6cc80gbank|r to their guild or officer note, then type |cffe6cc80/reload|r.\n3. In addon options (Escape -> Options -> Addons -> TOGBankClassic), click on the |cffe6cc80-|r icon (expand/collapse) to the left of the entry, enable reporting and scanning for the bank character in the |cffe6cc80Bank|r section.\n4. Open and close your bags and bank.\n5. Type |cffe6cc80/togbank roster|r and confirm your bank character is included in the sent roster.\n6. Type |cffe6cc80/reload|r.  Wait up to 3 minutes (or type |cffe6cc80/togbank share|r for immediate sharing) until |cffe6cc80Sharing guild bank data...|r completes.\n7. Verify with a guild member (they type |cffe6cc80/togbank|r).\n"
	)
	TOGBankClassic_Core:Print(
		"\n|cff33ff99Instructions for removing a guild bank:|r\n1. Log in with an officer or another bank character in the same guild (or a character from a different guild).\n2. If the bank character is still in the guild, remove |cffe6cc80gbank|r from their notes.\n3. Type |cffe6cc80/togbank roster|r and confirm the bank character is no longer listed or the roster is empty.\n4. Verify with a guild member (they type |cffe6cc80/togbank|r).\n"
	)
end

function TOGBankClassic_Chat:ProcessQueue()
	if IsInRaid() then
		return
	end
	if #self.sync_queue == 0 then
		self.is_syncing = false
		return
	end

	self.is_syncing = true

	local time = GetServerTime()

	local name = table.remove(self.sync_queue)
	if not self.last_alt_sync[name] or time - self.last_alt_sync[name] > 180 then
		self.last_alt_sync[name] = time
		TOGBankClassic_Guild:SendAltData(name)
	end

	TOGBankClassic_Chat:ReprocessQueue()
end

function TOGBankClassic_Chat:ReprocessQueue()
	TOGBankClassic_Core:ScheduleTimer(function(...)
		TOGBankClassic_Chat:OnTimer()
	end, 5)
end

function TOGBankClassic_Chat:OnTimer()
	TOGBankClassic_Chat:ProcessQueue()
end
