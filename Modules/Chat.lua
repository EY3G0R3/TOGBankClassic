TOGBankClassic_Chat = {}

function TOGBankClassic_Chat:Init()
	TOGBankClassic_Core:RegisterChatCommand("togbank", function(input)
		return TOGBankClassic_Chat:ChatCommand(input)
	end)

	self.addon_outdated = false
	self.guild_versions = {}  -- tracks addon versions of guild members

	self.last_roster_sync = nil
	self.last_alt_sync = {}
	self.sync_queue = {}
	self.is_syncing = false
	self.last_share_sync = nil

	TOGBankClassic_Core:RegisterComm("togbank-d", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-d2", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	-- DELTA-006: Delta chain replay handlers
	TOGBankClassic_Core:RegisterComm("togbank-dr", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-dc", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-v", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	-- Delta-specific version broadcast (SYNC-001 fix)
	TOGBankClassic_Core:RegisterComm("togbank-dv", function(prefix, message, distribution, sender)
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

-- Wrapper for debug logging (delegates to centralized logger)
function TOGBankClassic_Chat:Debug(...)
	return TOGBankClassic_Output:Debug(...)
end

local SHARES_COLOR = "|cff80bfffshares|r"
local QUERIES_COLOR = "|cffffff00queries|r"

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

local function FormatSyncStatus(status)
	if status == ADOPTION_STATUS.ADOPTED then
		return "(newer, integrating)"
	end
	if status == ADOPTION_STATUS.STALE then
		return "(older, discarding)"
	end
	if status == ADOPTION_STATUS.INVALID then
		return "(invalid, ignoring)"
	end
	if status == ADOPTION_STATUS.UNAUTHORIZED then
		return "(unauthorized, ignoring)"
	end
	if status == ADOPTION_STATUS.IGNORED then
		return "(ignored)"
	end
	return ""
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
	local prefixDesc = COMM_PREFIX_DESCRIPTIONS[prefix] or "(Unknown)"
	if IsInRaid() then
		self:Debug("> (ignoring)", prefix, prefixDesc, "from", ColorPlayerName(sender), "(in raid)")
		return
	end
	local player = TOGBankClassic_Guild:GetPlayer()
	-- Normalize the sender so spacing/hyphen formats match
	sender = TOGBankClassic_Guild:NormalizeName(sender)

	if player == sender then
		self:Debug("> (ignoring)", prefix, prefixDesc, "(our own)")
		return
	end

	local success, data = TOGBankClassic_Core:DeserializeWithChecksum(message)
	if not success then
		self:Debug("> failed to deserialize", prefix, prefixDesc, "from", ColorPlayerName(sender), "error:", tostring(data))
		return
	end

	if prefix ~= "togbank-r" and prefix ~= "togbank-d" then
		-- togbank-r and togbank-d do their own output
		self:Debug(">", ColorPlayerName(sender), ">", prefix, prefixDesc)
	end

	if prefix == "togbank-v" or prefix == "togbank-dv" then
		local isDeltaVersion = (prefix == "togbank-dv")
		
		-- Delta clients ignore legacy version broadcasts (SYNC-001 fix)
		local weUseDelta = TOGBankClassic_Guild:ShouldUseDelta()
		if weUseDelta and prefix == "togbank-v" then
			-- Silently ignore - delta clients only listen to togbank-dv
			return
		end
		
		local current_data = TOGBankClassic_Guild:GetVersion()
		if current_data then
			if data.name then
				if current_data.name ~= data.name then
					TOGBankClassic_Output:Warn("A non-guild version!")
					return
				end
			end
			if data.addon then
				-- Track this user's addon version
				self.guild_versions[sender] = {
					version = data.addon,
					seen = time(),
				}

				-- Track protocol capabilities
				local protocolVersion = data.protocol_version or 1
				local supportsDelta = data.supports_delta or false
				TOGBankClassic_Database:UpdatePeerProtocol(
					current_data.name,
					sender,
					protocolVersion,
					supportsDelta
				)

				if current_data.addon and data.addon > current_data.addon then
					if not self.addon_outdated then
						-- only make the callout once
						self.addon_outdated = true
						TOGBankClassic_Output:Info(
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
					local ourVersion = current_data.alts[kNorm]
					
					-- Don't query sender about themselves (SYNC-001 fix)
					local senderNorm = TOGBankClassic_Guild:NormalizeName(sender)
					if kNorm ~= senderNorm then
						-- For delta version broadcasts, only query if we support delta
						-- For legacy version broadcasts, query as normal
						local shouldQuery = false
						if isDeltaVersion then
							-- Delta version: only query if we support delta and version is newer
							if TOGBankClassic_Guild:ShouldUseDelta() and (not ourVersion or v > ourVersion) then
								shouldQuery = true
								self:Debug(
									">",
									ColorPlayerName(sender),
									"has fresher bank data about",
									ColorPlayerName(kNorm) .. ", querying (delta)."
								)
							end
						else
							-- Legacy version: query as usual
							if not ourVersion or v > ourVersion then
								shouldQuery = true
								self:Debug(
									">",
									ColorPlayerName(sender),
									"has fresher bank data about",
									ColorPlayerName(kNorm) .. ", querying."
								)
							end
						end
						
						if shouldQuery then
							-- Pass OUR version so sender can build delta chain from our version to theirs
							TOGBankClassic_Guild:QueryAlt(sender, kNorm, ourVersion)
						end
					end
				end
			end
		end
	end

	if prefix == "togbank-r" then
		self:Debug(
			">",
			ColorPlayerName(sender),
			QUERIES_COLOR,
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
				
				-- Check if query includes version and we can send delta chain
				if data.version and TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts[nameNorm] then
					local currentVersion = TOGBankClassic_Guild.Info.alts[nameNorm].version
					local requestedVersion = data.version
					
					-- If requester has old version, try to send delta chain immediately
					if requestedVersion < currentVersion then
						local deltaChain = TOGBankClassic_Database:GetDeltaHistory(TOGBankClassic_Guild.Info.name, nameNorm, requestedVersion, currentVersion)
						if deltaChain and #deltaChain > 0 then
							TOGBankClassic_Output:Debug(
								"Query from %s for %s v%d (have v%d), sending %d-delta chain",
								sender,
								nameNorm,
								requestedVersion,
								currentVersion,
								#deltaChain
							)
							TOGBankClassic_Guild:SendDeltaChain(nameNorm, deltaChain, sender)
							return
						end
					end
				end
				
				-- Fall back to normal query response
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
				SHARES_COLOR,
				"roster data. We",
				allowed and "accept it." or "do not accept it."
			)
			if allowed then
				TOGBankClassic_Guild:ReceiveRosterData(data.roster)
			end
		end

		if data.type == "requests" then
			local status = TOGBankClassic_Guild:ReceiveRequestsData(data)
			self:Debug(
				">",
				ColorPlayerName(sender),
				SHARES_COLOR,
				"requests snapshot. We accept it by default.",
				FormatSyncStatus(status)
			)
		end
		if data.type == "requests-log" then
			self:Debug(">", ColorPlayerName(sender), SHARES_COLOR, "requests log. We accept it by default.")
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
			local status = allowed and TOGBankClassic_Guild:ReceiveAltData(claimedNorm, data.alt)
				or ADOPTION_STATUS.UNAUTHORIZED
			self:Debug(
				">",
				ColorPlayerName(sender),
				SHARES_COLOR,
				"bank data about",
				ColorPlayerName(claimedNorm) .. ". We",
				allowed and "accept it." or "do not accept it.",
				FormatSyncStatus(status)
			)
			if allowed then
				-- ReceiveAltData already applied/rejected; nothing else to do.
			else
				-- ignore spoofed alt data
				return
			end
		end
	end

	if prefix == "togbank-d2" then
		if data.type == "alt-delta" then
			-- only accept delta data if the sender matches the claimed alt name
			local claimed = data.name
			local claimedNorm = TOGBankClassic_Guild:NormalizeName(claimed)
			local allowed = self:IsAltDataAllowed(sender, claimedNorm)
			if TOGBankClassic_Guild:ConsumePendingSync("alt", sender, claimedNorm) then
				allowed = true
			end

			if allowed then
				-- Validate and sanitize delta structure
				local valid, err = TOGBankClassic_Core:ValidateDeltaStructure(data)
				if not valid then
					local errorMsg = "Validation failed: " .. (err or "unknown error")
					self:Debug(
						">",
						ColorPlayerName(sender),
						SHARES_COLOR,
						"delta for",
						ColorPlayerName(claimedNorm),
						"- validation failed:",
						err
					)
					-- Record error and request full sync
					TOGBankClassic_Guild:RecordDeltaError(claimedNorm, "VALIDATION_FAILED", errorMsg)
					TOGBankClassic_Guild:QueryAlt(sender, claimedNorm, nil)
					if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name then
						TOGBankClassic_Database:RecordDeltaFailed(TOGBankClassic_Guild.Info.name)
					end
					return
				end

				local status = TOGBankClassic_Guild:ApplyDelta(claimedNorm, data, sender)
				self:Debug(
					">",
					ColorPlayerName(sender),
					SHARES_COLOR,
					"delta for",
					ColorPlayerName(claimedNorm) .. ".",
					FormatSyncStatus(status)
				)
			else
				self:Debug(
					">",
					ColorPlayerName(sender),
					SHARES_COLOR,
					"delta for",
					ColorPlayerName(claimedNorm) .. ". We do not accept it.",
					FormatSyncStatus(ADOPTION_STATUS.UNAUTHORIZED)
				)
			end
		end
	end

	-- DELTA-006: Delta Range Request handler
	if prefix == "togbank-dr" then
		if data.altName and data.fromVersion and data.toVersion then
			local altName = data.altName
			local fromVersion = data.fromVersion
			local toVersion = data.toVersion
			
			self:Debug(
				">",
				ColorPlayerName(sender),
				QUERIES_COLOR,
				"requests delta chain for",
				ColorPlayerName(altName),
				string.format("(v%d→v%d)", fromVersion, toVersion)
			)
			
			-- Get delta history
			if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name then
				local deltaChain = TOGBankClassic_Database:GetDeltaHistory(
					TOGBankClassic_Guild.Info.name,
					altName,
					fromVersion,
					toVersion
				)
				
				if deltaChain then
					-- Send delta chain back via whisper
					local chainData = {
						altName = altName,
						deltas = deltaChain
					}
					local serialized = TOGBankClassic_Core:SerializeWithChecksum(chainData)
					TOGBankClassic_Core:SendCommMessage("togbank-dc", serialized, "WHISPER", sender, "ALERT")
					
					self:Debug(
						"<",
						"togbank-dc (Delta Chain) to",
						ColorPlayerName(sender),
						string.format("(%d hops, %d bytes)", #deltaChain, string.len(serialized or ""))
					)
				else
					-- Can't build chain, let them request full sync
					self:Debug(
						"< Cannot build delta chain for",
						ColorPlayerName(altName),
						string.format("(v%d→v%d), no history", fromVersion, toVersion)
					)
				end
			end
		end
	end

	-- DELTA-006: Delta Chain response handler
	if prefix == "togbank-dc" then
		if data.altName and data.deltas then
			local altName = data.altName
			local deltaChain = data.deltas
			
			self:Debug(
				">",
				ColorPlayerName(sender),
				SHARES_COLOR,
				"delta chain for",
				ColorPlayerName(altName),
				string.format("(%d hops)", #deltaChain)
			)
			
			-- Apply delta chain
			local status = TOGBankClassic_Guild:ApplyDeltaChain(altName, deltaChain)
			self:Debug(
				"Delta chain application",
				FormatSyncStatus(status)
			)
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

-- Help text color codes
local HELP_COLOR = {
	HEADER = "|cff33ff99",
	COMMAND = "|cffe6cc80",
	RESET = "|r",
}

-- Command registry: name, usage, help, expert, handler
-- Commands are displayed in help in the order they appear here.
-- Set help = nil to hide from help output.
local COMMAND_REGISTRY = {
	-- Basic commands
	{
		name = "help",
		help = "this message",
		handler = function()
			TOGBankClassic_Chat:ShowHelp()
		end,
	},
	{
		name = "version",
		help = "display the TOGBankClassic version",
		handler = function()
			local version = GetAddOnMetadata("TOGBankClassic", "Version") or "unknown"
			TOGBankClassic_Output:Response("TOGBankClassic version:", version)
		end,
	},
	{
		name = "sync",
		help = "manually receive the latest data from other online users with guild bank data; this is done every 10 minutes automatically",
		handler = function()
			TOGBankClassic_Events:Sync()
		end,
	},
	{
		name = "share",
		help = "manually share the contents of your guild bank with other online users of TOGBankClassic; this is done every 3 minutes automatically",
		handler = function()
			TOGBankClassic_Bank:OnUpdateStart()
			TOGBankClassic_Bank:OnUpdateStop()
			TOGBankClassic_Guild:Share()
		end,
	},
	{
		name = "reset",
		help = "reset your own TOGBankClassic database",
		handler = function()
			local guild = TOGBankClassic_Guild:GetGuild()
			if not guild then
				return
			end
			TOGBankClassic_Guild:Reset(guild)
		end,
	},
	-- Expert commands
	{
		name = "roster",
		help = "guild banks and members that can read the officer note can use this command to share updated roster data with online guild members",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:AuthorRosterData()
		end,
	},
	{
		name = "hello",
		help = "understand which online guild members use which addon version and know what guild bank data; needs corresponding weakaura to print deserialized addon communication",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:Hello()
		end,
	},
	{
		name = "versions",
		help = "show addon versions of online guild members",
		expert = true,
		handler = function()
			TOGBankClassic_Chat:PrintVersions()
		end,
	},
	{
		name = "deltastats",
		help = "show delta sync statistics and bandwidth savings",
		expert = true,
		handler = function()
			TOGBankClassic_Chat:PrintDeltaStats()
		end,
	},
	{
		name = "deltaerrors",
		help = "show recent delta sync errors and failure counts",
		expert = true,
		handler = function()
			TOGBankClassic_Chat:PrintDeltaErrors()
		end,
	},
	{
		name = "deltahistory",
		help = "show stored delta chain history for offline recovery",
		expert = true,
		handler = function()
			TOGBankClassic_Chat:PrintDeltaHistory()
		end,
	},
	{
		name = "protocol",
		help = "show protocol version distribution across guild members",
		expert = true,
		handler = function()
			TOGBankClassic_Chat:PrintProtocolInfo()
		end,
	},
	{
		name = "clearsnapshots",
		help = "clear all delta snapshots (forces full syncs next time)",
		expert = true,
		handler = function()
			local guild = TOGBankClassic_Guild:GetGuild()
			if not guild then
				TOGBankClassic_Output:Response("Not in a guild")
				return
			end
			local db = TOGBankClassic_Database.db.faction[guild]
			if db and db.deltaSnapshots then
				local count = 0
				for _ in pairs(db.deltaSnapshots) do
					count = count + 1
				end
				db.deltaSnapshots = {}
				TOGBankClassic_Output:Response("Cleared %d delta snapshot(s)", count)
			else
				TOGBankClassic_Output:Response("No snapshots to clear")
			end
		end,
	},
	{
		name = "clearhistory",
		help = "clear delta chain history (removes saved deltas)",
		expert = true,
		handler = function()
			local guild = TOGBankClassic_Guild:GetGuild()
			if not guild then
				TOGBankClassic_Output:Response("Not in a guild")
				return
			end
			local db = TOGBankClassic_Database.db.faction[guild]
			if db and db.deltaHistory then
				local count = 0
				for _, deltas in pairs(db.deltaHistory) do
					if type(deltas) == "table" then
						count = count + #deltas
					end
				end
				db.deltaHistory = {}
				TOGBankClassic_Output:Response("Cleared %d delta(s) from history", count)
			else
				TOGBankClassic_Output:Response("No delta history to clear")
			end
		end,
	},
	{
		name = "forcedelta",
		help = "force delta sync mode (on|off) - bypass thresholds for testing",
		expert = true,
		handler = function(arg)
			if arg == "on" then
				FEATURES.FORCE_DELTA_SYNC = true
				FEATURES.FORCE_FULL_SYNC = false
				TOGBankClassic_Output:Response("Force delta sync: ENABLED (will always use delta)")
			elseif arg == "off" then
				FEATURES.FORCE_DELTA_SYNC = false
				TOGBankClassic_Output:Response("Force delta sync: DISABLED (normal behavior)")
			else
				local status = FEATURES.FORCE_DELTA_SYNC and "ON" or "OFF"
				TOGBankClassic_Output:Response("Force delta sync: %s", status)
				TOGBankClassic_Output:Response("Usage: /togbank forcedelta [on|off]")
			end
		end,
	},
	{
		name = "forcefull",
		help = "force full sync mode (on|off) - disable delta for testing",
		expert = true,
		handler = function(arg)
			if arg == "on" then
				FEATURES.FORCE_FULL_SYNC = true
				FEATURES.FORCE_DELTA_SYNC = false
				TOGBankClassic_Output:Response("Force full sync: ENABLED (will never use delta)")
			elseif arg == "off" then
				FEATURES.FORCE_FULL_SYNC = false
				TOGBankClassic_Output:Response("Force full sync: DISABLED (normal behavior)")
			else
				local status = FEATURES.FORCE_FULL_SYNC and "ON" or "OFF"
				TOGBankClassic_Output:Response("Force full sync: %s", status)
				TOGBankClassic_Output:Response("Usage: /togbank forcefull [on|off]")
			end
		end,
	},
	{
		name = "forcefull",
		help = "toggle forcing full sync (disables delta temporarily)",
		expert = true,
		handler = function()
			FEATURES.FORCE_FULL_SYNC = not FEATURES.FORCE_FULL_SYNC
			if FEATURES.FORCE_FULL_SYNC then
				TOGBankClassic_Output:Response("|cffff0000Full sync forced|r - delta sync temporarily disabled")
			else
				TOGBankClassic_Output:Response("|cff00ff00Full sync force removed|r - delta sync re-enabled")
			end
		end,
	},
	{
		name = "resetmetrics",
		help = "reset delta sync statistics and metrics",
		expert = true,
		handler = function()
			local guild = TOGBankClassic_Guild:GetGuild()
			if not guild then
				TOGBankClassic_Output:Response("Not in a guild")
				return
			end
			if TOGBankClassic_Database:ResetDeltaMetrics(guild) then
				TOGBankClassic_Output:Response("Delta metrics reset")
			else
				TOGBankClassic_Output:Response("Failed to reset metrics")
			end
		end,
	},
	{
		name = "requestlog",
		usage = "[N|all]",
		help = "print the request log, optionally limited to N entries",
		expert = true,
		handler = function(arg1)
			TOGBankClassic_Guild:PrintRequestLog(arg1)
		end,
	},
	{
		name = "compact",
		help = "manually run compaction to prune old requests and log entries",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:Compact()
		end,
	},
	{
		name = "wipe",
		help = "reset your own TOGBankClassic database",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:WipeMine()
		end,
	},
	{
		name = "wipeall",
		help = "officer only: reset your own TOGBankClassic database and that of all online guild members",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:Wipe()
		end,
	},
	-- Hidden commands (no help text)
	{
		name = "debug",
		handler = function()
			local currentLevel = TOGBankClassic_Output:GetLevel()
			if currentLevel == LOG_LEVEL.DEBUG then
				TOGBankClassic_Output:SetLevel(LOG_LEVEL.INFO)
				TOGBankClassic_Options.db.global.bank["logLevel"] = LOG_LEVEL.INFO
				TOGBankClassic_Output:Response("Debug: off (log level: Info)")
			else
				TOGBankClassic_Output:SetLevel(LOG_LEVEL.DEBUG)
				TOGBankClassic_Options.db.global.bank["logLevel"] = LOG_LEVEL.DEBUG
				TOGBankClassic_Output:Response("Debug: on (log level: Debug)")
			end
		end,
	},
	{
		name = "debugtab",
		help = "create a dedicated chat tab for debug output",
		expert = true,
		handler = function()
			if TOGBankClassic_Output:CreateDebugTab() then
				TOGBankClassic_Output:Response("Debug output will now appear in 'TOGBank Debug' tab")
				TOGBankClassic_Output:Response("Use /togbank debug to enable debug logging")
			end
		end,
	},
	{
		name = "debugtabremove",
		help = "remove the TOGBank Debug chat tab",
		expert = true,
		handler = function()
			TOGBankClassic_Output:RemoveDebugTab()
		end,
	},
	{
		name = "test",
		help = "run automated delta sync tests (use 'test help' for options)",
		expert = true,
		handler = function(arg)
			if not TOGBankClassic_Tests then
				TOGBankClassic_Output:Response("Test module not loaded")
				return
			end
			
			arg = arg and arg:trim():lower() or ""
			
			if arg == "" or arg == "all" then
				TOGBankClassic_Tests:RunAllTests()
			elseif arg == "help" then
				TOGBankClassic_Output:Response("TOGBank Test Commands:")
				TOGBankClassic_Output:Response("  /togbank test - Run all tests")
				TOGBankClassic_Output:Response("  /togbank test all - Run all tests")
				TOGBankClassic_Output:Response("  /togbank test <test-name> - Run specific test")
				TOGBankClassic_Output:Response("  /togbank test help - Show this help")
			else
				TOGBankClassic_Tests:RunTest(arg)
			end
		end,
	},
	{
		name = "debugdump",
		handler = function()
			local G = TOGBankClassic_Guild
			if not G or not G.Info or not G.Info.alts then
				TOGBankClassic_Output:Response("no alts table available")
				return
			end
			TOGBankClassic_Output:Response("Listing Info.alts keys:")
			local i = 0
			for k, v in pairs(G.Info.alts) do
				i = i + 1
				TOGBankClassic_Output:Response(i, tostring(k), type(v))
				if i >= 200 then
					TOGBankClassic_Output:Response("truncated at 200 entries")
					break
				end
			end
			if i == 0 then
				TOGBankClassic_Output:Response("no entries")
			end
		end,
	},
}

-- Build lookup table for fast command dispatch
local COMMAND_HANDLERS = {}
for _, cmd in ipairs(COMMAND_REGISTRY) do
	COMMAND_HANDLERS[cmd.name] = cmd.handler
end

-- Instructions as multiline strings for readability
local HELP_INSTRUCTIONS = {
	{
		title = "Instructions for setting up a new guild bank:",
		text = [[
1. Log in with the guild bank character, ensuring they are in the guild.
2. Add |cffe6cc80gbank|r to their guild or officer note, then type |cffe6cc80/reload|r.
3. In addon options (Escape -> Options -> Addons -> TOGBankClassic), click on the |cffe6cc80-|r icon (expand/collapse) to the left of the entry, enable reporting and scanning for the bank character in the |cffe6cc80Bank|r section.
4. Open and close your bags and bank.
5. Type |cffe6cc80/togbank roster|r and confirm your bank character is included in the sent roster.
6. Type |cffe6cc80/reload|r. Wait up to 3 minutes (or type |cffe6cc80/togbank share|r for immediate sharing) until |cffe6cc80Sharing guild bank data...|r completes.
7. Verify with a guild member (they type |cffe6cc80/togbank|r).]],
	},
	{
		title = "Instructions for removing a guild bank:",
		text = [[
1. Log in with an officer or another bank character in the same guild (or a character from a different guild).
2. If the bank character is still in the guild, remove |cffe6cc80gbank|r from their notes.
3. Type |cffe6cc80/togbank roster|r and confirm the bank character is no longer listed or the roster is empty.
4. Verify with a guild member (they type |cffe6cc80/togbank|r).]],
	},
}

function TOGBankClassic_Chat:ChatCommand(input)
	if input == nil or input == "" then
		TOGBankClassic_UI_Inventory:Toggle()
	else
		local prefix, arg1 = TOGBankClassic_Core:GetArgs(input, 2)
		local handler = COMMAND_HANDLERS[prefix]
		if handler then
			handler(arg1)
		else
			TOGBankClassic_Output:Response("Unknown command: ", prefix)
			TOGBankClassic_Chat:ShowHelp()
		end
	end

	return false
end

function TOGBankClassic_Chat:ShowHelp()
	local H = HELP_COLOR.HEADER
	local C = HELP_COLOR.COMMAND
	local R = HELP_COLOR.RESET

	-- Basic commands header
	TOGBankClassic_Output:Response("\n%sCommands:%s", H, R)
	TOGBankClassic_Output:Response("%s/togbank%s - display the TOGBankClassic interface", C, R)

	-- Print basic commands
	for _, cmd in ipairs(COMMAND_REGISTRY) do
		if cmd.help and not cmd.expert then
			local usage = cmd.usage and (" " .. cmd.usage) or ""
			TOGBankClassic_Output:Response("%s/togbank %s%s%s - %s", C, cmd.name, usage, R, cmd.help)
		end
	end

	-- Expert commands header
	TOGBankClassic_Output:Response("\n%sExpert commands:%s", H, R)

	-- Print expert commands
	for _, cmd in ipairs(COMMAND_REGISTRY) do
		if cmd.help and cmd.expert then
			local usage = cmd.usage and (" " .. cmd.usage) or ""
			TOGBankClassic_Output:Response("%s/togbank %s%s%s - %s", C, cmd.name, usage, R, cmd.help)
		end
	end

	-- Print instructions
	for _, instruction in ipairs(HELP_INSTRUCTIONS) do
		TOGBankClassic_Output:Response("\n%s%s%s", H, instruction.title, R)
		TOGBankClassic_Output:Response(instruction.text)
	end
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
	end, TIMER_INTERVALS.ALT_DATA_QUEUE_RETRY)
end

function TOGBankClassic_Chat:OnTimer()
	TOGBankClassic_Chat:ProcessQueue()
end

function TOGBankClassic_Chat:PrintVersions()
	-- Get our own version
	local myVersion = GetAddOnMetadata("TOGBankClassic", "Version") or "unknown"
	local myPlayer = TOGBankClassic_Guild:GetPlayer()

	-- Collect versions into a sortable list
	local versions = {}

	-- Add ourselves
	table.insert(versions, {
		name = myPlayer,
		version = myVersion,
		seen = time(),
		isSelf = true,
	})

	-- Add tracked guild members
	for name, info in pairs(self.guild_versions) do
		table.insert(versions, {
			name = name,
			version = tostring(info.version),
			seen = info.seen,
			isSelf = false,
		})
	end

	-- Sort by version (descending), then by name
	table.sort(versions, function(a, b)
		if a.version ~= b.version then
			return a.version > b.version
		end
		return a.name < b.name
	end)

	-- Print header
	local count = #versions
	TOGBankClassic_Output:Response("Addon versions (%d members):", count)

	-- Print each version
	local now = time()
	for _, entry in ipairs(versions) do
		local age = ""
		if not entry.isSelf then
			local seconds = now - entry.seen
			if seconds < 60 then
				age = " (just now)"
			elseif seconds < 3600 then
				age = (" (%dm ago)"):format(math.floor(seconds / 60))
			else
				age = (" (%dh ago)"):format(math.floor(seconds / 3600))
			end
		end
		local marker = entry.isSelf and " (you)" or ""
		TOGBankClassic_Output:Response("  %s: %s%s%s", entry.name, entry.version, marker, age)
	end
end

function TOGBankClassic_Chat:PrintDeltaStats()
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		TOGBankClassic_Output:Response("Not in a guild")
		return
	end

	local metrics = TOGBankClassic_Database:GetDeltaMetrics(guild)
	if not metrics then
		TOGBankClassic_Output:Response("No delta sync metrics available")
		return
	end

	-- Helper to format bytes
	local function formatBytes(bytes)
		if bytes < 1024 then
			return string.format("%d B", bytes)
		elseif bytes < 1024 * 1024 then
			return string.format("%.1f KB", bytes / 1024)
		else
			return string.format("%.1f MB", bytes / (1024 * 1024))
		end
	end

	TOGBankClassic_Output:Response("|cff00ffffDelta Sync Statistics|r")
	TOGBankClassic_Output:Response("")

	-- Bandwidth stats
	local deltaBytes = metrics.bytesSentDelta or 0
	local fullBytes = metrics.bytesSentFull or 0
	local totalBytes = deltaBytes + fullBytes

	if totalBytes > 0 then
		TOGBankClassic_Output:Response("|cffffff00Bandwidth:|r")
		TOGBankClassic_Output:Response("  Delta syncs: %s (%.1f%%)", 
			formatBytes(deltaBytes), 
			(deltaBytes / totalBytes) * 100)
		TOGBankClassic_Output:Response("  Full syncs:  %s (%.1f%%)", 
			formatBytes(fullBytes), 
			(fullBytes / totalBytes) * 100)
		TOGBankClassic_Output:Response("  Total sent:  %s", formatBytes(totalBytes))

		-- Estimate bandwidth saved (assume delta would have been full sync)
		local deltasApplied = metrics.deltasApplied or 0
		if deltasApplied > 0 and deltaBytes > 0 then
			-- Estimate: if we sent full syncs instead of deltas, how much more data?
			local avgFullSize = fullBytes > 0 and (fullBytes / math.max(1, (metrics.fullSyncFallbacks or 0) + 1)) or 5000
			local estimatedFullBytes = deltasApplied * avgFullSize
			local saved = estimatedFullBytes - deltaBytes
			if saved > 0 then
				local reduction = (saved / estimatedFullBytes) * 100
				TOGBankClassic_Output:Response("  |cff00ff00Saved: ~%s (%.1f%% reduction)|r", 
					formatBytes(saved), reduction)
			end
		end
		TOGBankClassic_Output:Response("")
	end

	-- Operation stats
	local deltasApplied = metrics.deltasApplied or 0
	local deltasFailed = metrics.deltasFailed or 0
	local fullSyncFallbacks = metrics.fullSyncFallbacks or 0
	local totalOps = deltasApplied + deltasFailed

	if totalOps > 0 then
		TOGBankClassic_Output:Response("|cffffff00Operations:|r")
		TOGBankClassic_Output:Response("  Deltas applied:      %d", deltasApplied)
		TOGBankClassic_Output:Response("  Deltas failed:       %d", deltasFailed)
		TOGBankClassic_Output:Response("  Full sync fallbacks: %d", fullSyncFallbacks)

		local successRate = (deltasApplied / totalOps) * 100
		local rateColor = "|cff00ff00" -- green
		if successRate < 95 then
			rateColor = "|cffffff00" -- yellow
		end
		if successRate < 80 then
			rateColor = "|cffff0000" -- red
		end
		TOGBankClassic_Output:Response("  Success rate:        %s%.1f%%|r", rateColor, successRate)
		TOGBankClassic_Output:Response("")
	end

	-- Performance stats
	local computeCount = metrics.computeCount or 0
	local applyCount = metrics.applyCount or 0

	if computeCount > 0 or applyCount > 0 then
		TOGBankClassic_Output:Response("|cffffff00Performance:|r")
		if computeCount > 0 then
			local avgCompute = (metrics.totalComputeTime or 0) / computeCount
			TOGBankClassic_Output:Response("  Avg compute time: %.2fms (%d computed)", avgCompute, computeCount)
		end
		if applyCount > 0 then
			local avgApply = (metrics.totalApplyTime or 0) / applyCount
			TOGBankClassic_Output:Response("  Avg apply time:   %.2fms (%d applied)", avgApply, applyCount)
		end
	end

	if totalOps == 0 and totalBytes == 0 then
		TOGBankClassic_Output:Response("No delta sync activity yet")
	end
end

-- Print recent delta errors and failure counts
function TOGBankClassic_Chat:PrintDeltaErrors()
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		TOGBankClassic_Output:Response("Not in a guild")
		return
	end

	-- Try to get errors from database first, fall back to temp storage
	local errors = nil
	local db = TOGBankClassic_Database.db.faction[guild]
	if db and db.deltaErrors then
		errors = db.deltaErrors
	elseif TOGBankClassic_Guild.tempDeltaErrors then
		-- Use temp storage if database not available
		errors = TOGBankClassic_Guild.tempDeltaErrors
		TOGBankClassic_Output:Response("|cffffaa00Using temporary error storage (Guild.Info not initialized)|r")
	end
	
	if not errors then
		TOGBankClassic_Output:Response("No error tracking data available")
		return
	end
	
	-- Print header
	TOGBankClassic_Output:Response("|cff00ff00=== Delta Sync Errors ===|r")
	
	-- Print recent errors
	if errors.lastErrors and #errors.lastErrors > 0 then
		TOGBankClassic_Output:Response("|cffffff00Recent Errors:|r (%d)", #errors.lastErrors)
		for i, err in ipairs(errors.lastErrors) do
			local timeStr = date("%H:%M:%S", err.timestamp or 0)
			local typeColor = err.errorType == "VERSION_MISMATCH" and "|cffff8800" or "|cffff0000"
			TOGBankClassic_Output:Response("  %d. %s[%s]|r |cffaaaaaa%s|r", i, typeColor, err.errorType, timeStr)
			TOGBankClassic_Output:Response("     |cff88ccff%s|r: %s", err.altName or "Unknown", err.message or "No details")
		end
	else
		TOGBankClassic_Output:Response("|cffffff00Recent Errors:|r None")
	end
	
	-- Print failure counts per alt
	if errors.failureCounts and next(errors.failureCounts) then
		TOGBankClassic_Output:Response("|cffffff00Failure Counts by Alt:|r")
		local sortedAlts = {}
		for altName, count in pairs(errors.failureCounts) do
			table.insert(sortedAlts, {name = altName, count = count})
		end
		table.sort(sortedAlts, function(a, b) return a.count > b.count end)
		for _, entry in ipairs(sortedAlts) do
			local notified = errors.notifiedAlts and errors.notifiedAlts[entry.name] and " |cffff0000(notified)|r" or ""
			TOGBankClassic_Output:Response("  |cff88ccff%s|r: %d%s", entry.name, entry.count, notified)
		end
	else
		TOGBankClassic_Output:Response("|cffffff00Failure Counts:|r None")
	end
	
	-- Print summary
	local totalErrors = #(errors.lastErrors or {})
	local totalAlts = 0
	if errors.failureCounts then
		for _ in pairs(errors.failureCounts) do
			totalAlts = totalAlts + 1
		end
	end
	TOGBankClassic_Output:Response("|cffffff00Summary:|r %d error(s) tracked, %d alt(s) affected", totalErrors, totalAlts)
end

-- Print stored delta chain history
function TOGBankClassic_Chat:PrintDeltaHistory()
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		TOGBankClassic_Output:Response("Not in a guild")
		return
	end

	local db = TOGBankClassic_Database.db.faction[guild]
	if not db or not db.deltaHistory then
		TOGBankClassic_Output:Response("No delta history available")
		return
	end

	TOGBankClassic_Output:Response("|cff00ff00=== Delta Chain History ===|r")
	
	local totalDeltas = 0
	local altCount = 0
	
	-- Count total deltas and alts
	for altName, deltas in pairs(db.deltaHistory) do
		altCount = altCount + 1
		if type(deltas) == "table" then
			totalDeltas = totalDeltas + #deltas
		end
	end
	
	if totalDeltas == 0 then
		TOGBankClassic_Output:Response("No delta history stored yet")
		return
	end
	
	TOGBankClassic_Output:Response("|cffffff00Total:|r %d delta(s) stored for %d alt(s)", totalDeltas, altCount)
	TOGBankClassic_Output:Response("")
	
	-- Show per-alt breakdown
	for altName, deltas in pairs(db.deltaHistory) do
		if type(deltas) == "table" and #deltas > 0 then
			TOGBankClassic_Output:Response("|cff88ccff%s|r: %d delta(s)", altName, #deltas)
			
			-- Show details for each delta (newest first)
			for i, delta in ipairs(deltas) do
				local age = GetServerTime() - (delta.timestamp or 0)
				local ageStr = age < 60 and string.format("%ds ago", age) 
					or age < 3600 and string.format("%dm ago", math.floor(age / 60))
					or string.format("%dh ago", math.floor(age / 3600))
				
				local changeCount = 0
				-- Delta is nested: historyEntry.delta.changes
				local changes = delta.delta and delta.delta.changes or nil
				if changes then
					if changes.bank then changeCount = changeCount + 1 end
					if changes.bags then changeCount = changeCount + 1 end
					if changes.money then changeCount = changeCount + 1 end
				end
				
				TOGBankClassic_Output:Response(
					"  %d. v%d→v%d (%d change(s), %s)",
					i,
					delta.baseVersion or 0,
					delta.version or 0,
					changeCount,
					ageStr
				)
			end
		end
	end
end

function TOGBankClassic_Chat:PrintProtocolInfo()
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		TOGBankClassic_Output:Response("Not in a guild")
		return
	end

	TOGBankClassic_Output:Response("|cff00ffffProtocol Version Distribution|r")
	TOGBankClassic_Output:Response("")

	-- Get guild delta support
	local support = TOGBankClassic_Database:GetGuildDeltaSupport(guild)
	local threshold = PROTOCOL.DELTA_SUPPORT_THRESHOLD

	-- Count versions
	local db = TOGBankClassic_Database.db.faction[guild]
	if not db or not db.guildProtocolVersions then
		TOGBankClassic_Output:Response("No protocol data available")
		return
	end

	local now = GetServerTime()
	local onlineV1 = 0
	local onlineV2 = 0
	local allTimeV1 = 0
	local allTimeV2 = 0
	local recentMembers = {}

	for sender, info in pairs(db.guildProtocolVersions) do
		if info then
			local version = info.version or 1
			local isOnline = info.lastSeen and (now - info.lastSeen) < 600

			-- All time counts
			if version >= 2 then
				allTimeV2 = allTimeV2 + 1
			else
				allTimeV1 = allTimeV1 + 1
			end

			-- Online counts (last 10 minutes)
			if isOnline then
				if version >= 2 then
					onlineV2 = onlineV2 + 1
				else
					onlineV1 = onlineV1 + 1
				end
			end

			-- Track recent members for display
			if isOnline then
				table.insert(recentMembers, {
					name = sender,
					version = version,
					lastSeen = info.lastSeen,
				})
			end
		end
	end

	-- Sort recent members by last seen
	table.sort(recentMembers, function(a, b)
		return a.lastSeen > b.lastSeen
	end)

	-- Display online distribution
	local totalOnline = onlineV1 + onlineV2
	if totalOnline > 0 then
		TOGBankClassic_Output:Response("|cffffff00Online (last 10 minutes):|r")
		TOGBankClassic_Output:Response("  Protocol v2 (delta): %d (%.1f%%)", onlineV2, (onlineV2 / totalOnline) * 100)
		TOGBankClassic_Output:Response("  Protocol v1 (full):  %d (%.1f%%)", onlineV1, (onlineV1 / totalOnline) * 100)
		TOGBankClassic_Output:Response("  Total online: %d", totalOnline)
		TOGBankClassic_Output:Response("")
	end

	-- Display all-time distribution
	local totalAllTime = allTimeV1 + allTimeV2
	if totalAllTime > 0 then
		TOGBankClassic_Output:Response("|cffffff00All time:|r")
		TOGBankClassic_Output:Response("  Protocol v2: %d", allTimeV2)
		TOGBankClassic_Output:Response("  Protocol v1: %d", allTimeV1)
		TOGBankClassic_Output:Response("")
	end

	-- Display threshold status
	local statusIcon = support >= threshold and "|cff00ff00✓|r" or "|cffff0000⚠|r"
	local statusText = support >= threshold and "enabled" or "disabled"
	TOGBankClassic_Output:Response("%s Delta sync %s (%.1f%% %s %.0f%% threshold)",
		statusIcon, statusText, support * 100,
		support >= threshold and "≥" or "<",
		threshold * 100)

	-- Display recent members
	if #recentMembers > 0 then
		TOGBankClassic_Output:Response("")
		TOGBankClassic_Output:Response("|cffffff00Recently seen members:|r")
		local shown = 0
		for _, member in ipairs(recentMembers) do
			if shown >= 10 then
				TOGBankClassic_Output:Response("  ... and %d more", #recentMembers - shown)
				break
			end

			local age = ""
			local seconds = now - member.lastSeen
			if seconds < 60 then
				age = "now"
			elseif seconds < 3600 then
				age = string.format("%dm ago", math.floor(seconds / 60))
			else
				age = string.format("%dh ago", math.floor(seconds / 3600))
			end

			TOGBankClassic_Output:Response("  %s: v%d (%s)", member.name, member.version, age)
			shown = shown + 1
		end
	end

	if totalOnline == 0 and totalAllTime == 0 then
		TOGBankClassic_Output:Response("No protocol version data available")
	end
end
