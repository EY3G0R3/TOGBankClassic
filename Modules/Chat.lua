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

	---START CHANGES
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
	---END CHANGES
end

function TOGBankClassic_Chat:OnCommReceived(prefix, message, _, sender)
	if IsInRaid() then
		if self.debug then
			TOGBankClassic_Core:Print("OnCommReceived: ignoring prefix", prefix, "from", sender, "(in raid)")
		end
		return
	end
	local player = TOGBankClassic_Guild:GetPlayer()
	---START CHANGES
	-- Normalize the sender so spacing/hyphen formats match
	sender = TOGBankClassic_Guild:NormalizeName(sender)
	---END CHANGES

	if player == sender and self.debug then
		TOGBankClassic_Core:Print("OnCommReceived: (own, ignoring)", prefix, "from", sender)
		return
	elseif self.debug then
		TOGBankClassic_Core:Print("OnCommReceived:", prefix, "from", sender)
	end

	if prefix == "togbank-v" then
		local success, data = TOGBankClassic_Core:Deserialize(message)
		if not success then
			if self.debug then
				TOGBankClassic_Core:Print("OnCommReceived: failed to deserialize togbank-v from", sender)
			end
		else
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
						TOGBankClassic_Guild:RequestRosterSync(sender, data.roster)
					end
				end
				if data.requests then
					local currentRequests = current_data.requests
					if currentRequests == nil or data.requests > currentRequests then
						TOGBankClassic_Guild:RequestRequestsSync(sender, data.requests)
					end
				end
				if data.alts then
					for k, v in pairs(data.alts) do
						local kNorm = TOGBankClassic_Guild:NormalizeName(k)
						if not current_data.alts[kNorm] or v > current_data.alts[kNorm] then
							TOGBankClassic_Guild:RequestAltSync(sender, kNorm, v)
						end
					end
				end
			end
		end
	end

	if prefix == "togbank-r" then
		local success, data = TOGBankClassic_Core:Deserialize(message)
		if not success then
			if self.debug then
				TOGBankClassic_Core:Print("OnCommReceived: failed to deserialize togbank-r from", sender)
			end
		else
			if self.debug then
				TOGBankClassic_Core:Print("OnCommReceived: togbank-r: player:", data.player, "type:", data.type)
			end
			if data.player == player then
				if data.type == "roster" then
					local time = GetServerTime()
					if self.last_roster_sync == nil or time - self.last_roster_sync > 300 then
						self.last_roster_sync = time
						TOGBankClassic_Guild:SendRosterData()
					end
				end

				if data.type == "requests" then
					TOGBankClassic_Guild:SendRequestsData()
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
	end

	if prefix == "togbank-d" then
		local success, data = TOGBankClassic_Core:Deserialize(message)
		if not success then
			if self.debug then
				TOGBankClassic_Core:Print("OnCommReceived: failed to deserialize togbank-d from", sender)
			end
		else
			if self.debug then
				TOGBankClassic_Core:Print("OnCommReceived: togbank-d: type:", data.type)
			end
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
				if self.debug then
					TOGBankClassic_Core:Print(
						"OnCommReceived: togbank-d roster from",
						sender,
						"allowed=",
						tostring(allowed)
					)
				end
				if allowed then
					TOGBankClassic_Guild:ReceiveRosterData(data.roster)
				end
			end

			if data.type == "requests" then
				TOGBankClassic_Guild:ReceiveRequestsData(data)
			end

			if data.type == "alt" then
				-- only accept alt data if the sender matches the claimed alt name
				local claimed = data.name
				local claimedNorm = TOGBankClassic_Guild:NormalizeName(claimed)
				local hasExistingAlt = false
				if TOGBankClassic_Guild and TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts then
					local existingAlt = TOGBankClassic_Guild.Info.alts[claimedNorm]
					hasExistingAlt = existingAlt ~= nil and type(existingAlt) == "table"
				end
				if self.debug then
					TOGBankClassic_Core:Print(
						"OnCommReceived: togbank-d alt from",
						sender,
						"claims",
						claimed,
						"normClaim=",
						claimedNorm
					)
				end
				-- 'sender' was normalized near the top of this function
				local allowed = false
				local claimedIsBank = false
				-- If the sender is the claimed owner, always accept
				if sender == claimedNorm then
					allowed = true
				else
					-- If the claimed owner is a registered bank toon, only accept from bank-marked senders
					claimedIsBank = TOGBankClassic_Guild:IsBank(claimedNorm)
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
				if TOGBankClassic_Guild:ConsumePendingSync("alt", sender, claimedNorm) then
					allowed = true
				end
				if self.debug then
					TOGBankClassic_Core:Print(
						"OnCommReceived: alt allowed=",
						tostring(allowed),
						"from",
						sender,
						"claimedNorm=",
						claimedNorm,
						"claimedIsBank=",
						tostring(claimedIsBank)
					)
				end
				if allowed then
					TOGBankClassic_Guild:ReceiveAltData(claimedNorm, data.alt)
				else
					-- ignore spoofed alt data
					return
				end
			end
		end
	end

	---START CHANGES
	if prefix == "togbank-h" then
		local success, data = TOGBankClassic_Core:Deserialize(message)
		if success then
			TOGBankClassic_Guild:Hello("reply")
		end
	end
	if prefix == "togbank-hr" then
		local success, data = TOGBankClassic_Core:Deserialize(message)
		if success then
			if self.debug then
				TOGBankClassic_Core:Print(data)
			end
		end
	end
	if prefix == "togbank-s" then
		local success, data = TOGBankClassic_Core:Deserialize(message)
		if success then
			TOGBankClassic_Guild:Share("reply")
			local now = GetServerTime()
			if not self.last_share_sync or now - self.last_share_sync > 30 then
				self.last_share_sync = now
				TOGBankClassic_Events:Sync()
			end
		end
	end
	if prefix == "togbank-w" then
		local success, data = TOGBankClassic_Core:Deserialize(message)
		if success then
			TOGBankClassic_Guild:Wipe("reply")
		end
	end
	---END CHANGES
end

function TOGBankClassic_Chat:ChatCommand(input)
	if input == nil or input == "" then
		TOGBankClassic_UI_Inventory:Toggle()
	else
		local commands = {
			["sync"] = function()
				TOGBankClassic_Events:Sync()
			end,
			---START CHANGES
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
			---END CHANGES
		}

		local prefix, _ = TOGBankClassic_Core:GetArgs(input, 1)
		local cmd = commands[prefix]
		if cmd ~= nil then
			cmd()
		else
			TOGBankClassic_UI_Inventory:Toggle()
		end
	end

	return false
end

function TOGBankClassic_Chat:ShowHelp()
	TOGBankClassic_Core:Print(
		"\n|cff33ff99Commands:|r\n|cffe6cc80/togbank|r (to display the GBankClassic interface) \n|cffe6cc80/togbank help|r (this message) \n|cffe6cc80/togbank sync|r (to manually receive the latest data from other online users with guild bank data; this is done every 10 minutes automatically) \n|cffe6cc80/togbank share|r (to manually share the contents of your guild bank with other online users of GBankClassic; this is done every 3 minutes automatically), \n|cffe6cc80/togbank reset|r (to reset your own GBankClassic database)\n"
	)
	TOGBankClassic_Core:Print(
		"\n|cff33ff99Expert commands:|r\n|cffe6cc80/togbank roster|r (guild banks and members that can read the officer note can use this command to share updated roster data with online guild members)\n|cffe6cc80/togbank hello|r (understand which online guild members use which addon version and know what guild bank data; needs corresponding weakaura to print deserliazed addon communication)\n|cffe6cc80/togbank wipe|r (reset your own GBankClassic database)\n|cffe6cc80/togbank wipeall|r (officer only: reset your own GBankClassic database and that of all online guild members)"
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
