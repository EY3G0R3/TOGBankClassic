TOGBankClassic_Chat = {}

-- Store pre-debug log level for restoration
local preDebugLogLevel = nil

--[[
Comms system breakdown as of 2026-03-18:

  Active Protocol Messages

  ┌──────────────────┬────────────────┬─────────────┬───────────────────────────────────────────────────────────────────────────────────┐
  │      Prefix      │    Channel     │  Priority   │                                      Purpose                                      │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-dv2      │ GUILD          │ BULK        │ Periodic version/hash broadcast so peers know if their data is stale              │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-d4       │ GUILD or       │ BULK        │ Delta inventory data (no item links, bandwidth-optimized) — current standard      │
  │                  │ WHISPER        │             │                                                                                   │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-hl       │ GUILD          │ NORMAL/BULK │ Multi-purpose hash protocol: hash-list-broadcast (banker→all), share-request,     │
  │                  │                │             │ wipe-command                                                                      │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-hlr      │ WHISPER        │ ALERT       │ Hash list reply — peer responds to banker's broadcast with their matching alts    │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-r        │ GUILD or       │ NORMAL/BULK │ Universal query — requests alt data, requests-index, or requests-by-id            │
  │                  │ WHISPER        │             │                                                                                   │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-rr       │ WHISPER        │ NORMAL      │ P2P handshake control: sync-request / sync-accept / sync-busy                     │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-state    │ WHISPER        │ NORMAL      │ Requester sends minimal state summary to responder; responder decides delta vs.   │
  │                  │                │             │ full                                                                              │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-nochange │ WHISPER        │ NORMAL      │ Responder tells requester "your data is already current, nothing to send"         │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-rd       │ GUILD or       │ NORMAL      │ Request log data: chunked requests-index, requests-by-id responses, mutations     │
  │                  │ WHISPER        │             │                                                                                   │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-rm       │ GUILD          │ ALERT       │ Request log mutations (add/cancel/complete) — ALERT priority so it isn't blocked  │
  │                  │                │             │ by BULK sends                                                                     │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-h        │ GUILD          │ BULK        │ Hello broadcast (administrative, informational text)                              │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-hr       │ GUILD          │ BULK        │ Hello reply                                                                       │
  └──────────────────┴────────────────┴─────────────┴───────────────────────────────────────────────────────────────────────────────────┘

  Legacy — Still Sent in AUTO Mode (for Backward Compatibility)

  ┌────────────┬───────────────────────────────────────────────────────────────────────────────────────────┐
  │   Prefix   │                                           Notes                                           │
  ├────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-d  │ Full sync with item links — pre-v0.8 format; still sent alongside togbank-d4 in AUTO mode │
  ├────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-dv │ Old delta version broadcast — superseded by togbank-dv2                                   │
  ├────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-v  │ Very old version broadcast — ignored by delta clients                                     │
  └────────────┴───────────────────────────────────────────────────────────────────────────────────────────┘

  Dead Code / Never Sent

  ┌────────────┬───────────────────────────────────────────────────────────────────────────────────────────────┐
  │   Prefix   │                                             Notes                                             │
  ├────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-d2 │ Old delta format — never sent in current code                                                 │
  ├────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-d3 │ Full sync without links — registered but never sent                                           │
  ├────────────┼───────────────────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-rq │ Defined in constants, no send code anywhere                                                   │
  └────────────┴───────────────────────────────────────────────────────────────────────────────────────────────┘


 A typical sync looks like this:

  1. Banker scans bank → broadcasts togbank-dv2 (hash) to guild
  2. Peer receives hash, compares to local — if stale, initiates P2P session via togbank-rr handshake
  3. Peer sends togbank-state (minimal summary) to banker
  4. Banker compares hashes:
    - Same → togbank-nochange
    - Different → togbank-d4 (delta) or togbank-d (full, legacy)
  5. Separately, togbank-r (requests-index query) → togbank-rd (chunked index response) → togbank-r (requests-by-id) → togbank-rd (request
  data)
  6. New/changed requests propagate immediately via togbank-rm (ALERT priority)

]]

function TOGBankClassic_Chat:Init()
	TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "[INIT] TOGBankClassic_Chat:Init() starting")
	TOGBankClassic_Core:RegisterChatCommand("togbank", function(input)
		return TOGBankClassic_Chat:ChatCommand(input)
	end)

	self.addon_outdated = false
	self.guild_versions = {}  -- tracks addon versions of guild members
	self.online_bankers = {}  -- v0.8.0: tracks online bankers for pull-based protocol

	self.last_roster_sync = nil
	self.last_alt_sync = {}
	self.sync_queue = {}
	self.is_syncing = false
	self.last_share_sync = nil

	-- Protocol prioritization: delay dv processing to allow dv2 to arrive first
	self.pending_dv_messages = {}  -- {sender = {altName = {timer, data, ...}}}
	self.DV_DELAY = 5  -- seconds to wait before processing dv messages

	-- PERF-020: Batch hash broadcast processing to prevent stuttering from sync storms
	self.hashBroadcastQueue = {}  -- {sender, data, distribution, isSenderBanker, altCount}
	self.hashBroadcastTimer = nil
	self.HASH_BROADCAST_BATCH_DELAY = 0.15  -- seconds to batch incoming broadcasts

	TOGBankClassic_Core:RegisterComm("togbank-d", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	-- togbank-d2, togbank-d3 removed: never sent in code (legacy docs only)
	TOGBankClassic_Core:RegisterComm("togbank-hl", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-hlr", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-d4", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	-- SYNC-010: Dedicated prefix for request mutations (add/cancel/complete)
	-- Uses separate throttle bucket from togbank-d to prevent BULK messages from blocking ALERT mutations
	TOGBankClassic_Core:RegisterComm("togbank-rm", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	-- togbank-dr / togbank-dc (DELTA-006 delta chain replay) REMOVED:
	-- togbank-dr was only triggered by deltaData.baseVersion which v0.8+ stopped sending.
	-- togbank-dc was the paired response; both are dead code paths. Slots freed for future use.

	-- togbank-v registration REMOVED: never sent (all sends commented out), ignored on receive by delta clients
	-- Slot freed for togbank-rd (request data) which was previously at slot #25, over WoW's 16-prefix limit
	TOGBankClassic_Core:RegisterComm("togbank-rd", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	-- togbank-dv removed: all clients now use togbank-dv2 (SYNC-006+); slot freed
	-- SYNC-006: New protocol for aggregated items structure
	TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "[INIT] Registering togbank-dv2 handler")
	TOGBankClassic_Core:RegisterComm("togbank-dv2", function(prefix, message, distribution, sender)
		TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "[HANDLER] togbank-dv2 called: %s from %s (%d bytes)", prefix, sender, #message)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-r", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-rr", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-state", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-nochange", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	-- togbank-h / togbank-hr: hello/hello-reply handshake (now slots 14/15 after legacy removals)
	TOGBankClassic_Core:RegisterComm("togbank-h", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)

	TOGBankClassic_Core:RegisterComm("togbank-hr", function(prefix, message, distribution, sender)
		TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	end)
	-- togbank-s/sr, togbank-w/wr, togbank-roster, togbank-rq removed:
	-- share/wipe/roster traffic migrated onto togbank-hl type dispatch (SYNC-013)
	-- sr and wr had no handler; rq was never sent
end

-- Wrapper for debug logging (delegates to centralized logger)
function TOGBankClassic_Chat:Debug(...)
	return TOGBankClassic_Output:Debug(...)
end

-- Centralized sync function for both /sync command and UI opening
function TOGBankClassic_Chat:PerformSync()
	-- v0.8.0: Use delta version broadcast instead of legacy sync
	-- SYNC-008 fix: Use ALERT priority for manual sync so it happens immediately
	TOGBankClassic_Events:SyncDeltaVersion("ALERT")
	-- SYNC-008 fix: Also send legacy version broadcast like the automatic timer does
	--TOGBankClassic_Events:Sync("ALERT")  -- COMMENTED OUT: togbank-v ignored by delta clients
	local hashListRequested = false
	if PEER_TO_PEER and PEER_TO_PEER.ENABLED then
		hashListRequested = TOGBankClassic_Guild:RequestHashListFromBanker()
	end
	TOGBankClassic_Guild:FastFillMissingAlts()
	TOGBankClassic_Guild:ReportBankerDataProgress("sync", true)
	-- REQUEST-001: Use index-based request sync (modern delta protocol)
	-- Pass force=true to bypass the 60s cooldown — this is an explicit user action, not a timer.
	local sent = TOGBankClassic_Guild:QueryRequestsIndex(nil, "ALERT", true)
	if sent then
		TOGBankClassic_Output:Response("Syncing requests with guild...")
	else
		TOGBankClassic_Output:Response("Request sync failed to send.")
	end
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

-- SYNC-001 fix: Roster-based validation to prevent cross-guild data bleed
-- Only accept alt data if both sender and claimed alt are in current guild
function TOGBankClassic_Chat:IsAltDataAllowed_RosterBased(sender, claimedNorm)
	-- Check if sender is in the current guild
	if not TOGBankClassic_Guild:IsInCurrentGuildRoster(sender) then
		TOGBankClassic_Output:Debug(
			"PROTOCOL", "ALT-REQUEST",
			"Rejecting alt data from %s: sender not in current guild roster",
			sender
		)
		return false
	end

	-- Check if claimed alt is in the current guild's banker roster
	if not TOGBankClassic_Guild:IsBank(claimedNorm) then
		TOGBankClassic_Output:Debug(
			"PROTOCOL", "ALT-REQUEST",
			"Rejecting alt data for %s: not a banker in current guild roster",
			claimedNorm
		)
		return false
	end

	return true
end

function TOGBankClassic_Chat:IsAltDataAllowed(sender, claimedNorm)
	-- SYNC-001 fix: Use roster-based validation by default
	return self:IsAltDataAllowed_RosterBased(sender, claimedNorm)
end

-- Cancel pending dv messages for specific alts (called when dv2 arrives)
function TOGBankClassic_Chat:CancelPendingDvMessages(sender, altNames)
	if not self.pending_dv_messages[sender] then
		return
	end

	for _, altName in ipairs(altNames) do
		local pending = self.pending_dv_messages[sender][altName]
		if pending and pending.timer then
			TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "Canceling pending dv message for %s (dv2 arrived)", altName)
			pending.timer:Cancel()
			self.pending_dv_messages[sender][altName] = nil
		end
	end
end

-- Process delayed dv message after timer expires
function TOGBankClassic_Chat:ProcessDelayedDvMessage(sender, data, prefix, message, distribution)
	TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "Processing delayed dv message from %s (no dv2 received)", sender)
	-- Remove from pending queue
	if self.pending_dv_messages[sender] then
		self.pending_dv_messages[sender] = nil
	end
	-- Process the message normally
	self:ProcessVersionBroadcast(prefix, data, sender, message, distribution)
end

-- Process version broadcast message (togbank-v, togbank-dv, togbank-dv2)
function TOGBankClassic_Chat:ProcessVersionBroadcast(prefix, data, sender, message, distribution)
	local isDeltaVersion = (prefix == "togbank-dv" or prefix == "togbank-dv2")
	local isSYNC006 = (prefix == "togbank-dv2")

	-- Debug: Show what data we received
	if isDeltaVersion then
		local altCount = 0
		if data.alts then
			for _ in pairs(data.alts) do
				altCount = altCount + 1
			end
		end
		TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "togbank-dv/dv2 from %s: has data.alts=%s, alts count=%d, isSYNC006=%s",
			sender,
			tostring(data.alts ~= nil),
			altCount,
			tostring(isSYNC006)
		)
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
			if not self.guild_versions then
				self.guild_versions = {}
			end
			self.guild_versions[sender] = {
				version = data.addon,
				seen = time(),
			}

			-- v0.8.0: Track online bankers for pull-based protocol
			if data.isBanker then
				if not self.online_bankers then
					self.online_bankers = {}
				end
				self.online_bankers[sender] = {
					seen = time(),
					version = data.addon,
				}
				TOGBankClassic_Output:Debug("ROSTER", "ONLINE", "Tracked online banker: %s", sender)
			end

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
				self:Debug("SYNC", "HASH-MATCH", ">", ColorPlayerName(sender), "has fresher roster data, querying.")
				TOGBankClassic_Guild:QueryRoster(sender, data.roster)
			end
		end
		-- PERF-002 fix: Request sync decoupled from inventory sync (togbank-dv)
		-- Request syncs now handled independently via SendRequestsVersionPing()
		
		-- P2P-005: Ignore unsolicited version broadcasts - use HL/HLR hash comparison instead
		-- Keep handler active for banker tracking, protocol capabilities, and roster sync above
		if data.alts then
			TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "[VERSION-BROADCAST] Ignoring unsolicited version broadcast from %s (alts=%d) - use HL/HLR for sync",
				sender, data.alts and (function() local c=0; for _ in pairs(data.alts) do c=c+1 end return c end)() or 0)
			return
		end
		--[[
		if data.alts then
			local altCount = 0
			for _ in pairs(data.alts) do
				altCount = altCount + 1
			end
			TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "[PROCESS] Processing %d alts from %s (isDeltaVersion=%s)",
				altCount, sender, tostring(isDeltaVersion))
			for k, v in pairs(data.alts) do
				local kNorm = TOGBankClassic_Guild:NormalizeName(k)
				local ourAlt = (TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts and TOGBankClassic_Guild.Info.alts[kNorm])
					or current_data.alts[kNorm]

				-- v0.8.0: Handle both old format (number) and new format (table with version+hash)
				local theirVersion = type(v) == "table" and v.version or v
				local theirHash = type(v) == "table" and v.hash or nil
				local theirUpdatedAt = type(v) == "table" and v.updatedAt or nil
				local ourVersion = type(ourAlt) == "table" and ourAlt.version or nil
				local ourHash = type(ourAlt) == "table" and ourAlt.inventoryHash or nil

				-- MAIL-012 DEBUG: Always log hash comparisons to PROTOCOL (not just SYNC)
				if theirHash then
					TOGBankClassic_Output:Debug(
						"PROTOCOL", "MAIL-012",
						"[MAIL-012] Received %s from %s: theirVer=%d, theirHash=%d, theirUpdatedAt=%s, ourVer=%s, ourHash=%s",
						kNorm,
						sender,
						theirVersion,
						theirHash,
						theirUpdatedAt and tostring(theirUpdatedAt) or "nil",
						ourVersion and tostring(ourVersion) or "nil",
						ourHash and tostring(ourHash) or "nil"
					)

					-- Store peer's hash locally ONLY if we don't have one
					if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts then
						if not ourAlt then
							-- Create stub entry for this alt
							TOGBankClassic_Guild.Info.alts[kNorm] = {
								name = kNorm,
								version = theirVersion,
								money = 0,
								inventoryHash = theirHash,
								inventoryUpdatedAt = theirUpdatedAt,
								items = {},
								mail = { items = {}, slots = { count = 0, total = 0 }, lastScan = 0, version = 0 },
								mailHash = 0,
							}
							TOGBankClassic_Guild:EnsureLegacyFields(TOGBankClassic_Guild.Info.alts[kNorm])
							TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "Stored hash for new alt %s: hash=%08x, updatedAt=%s", kNorm, theirHash, tostring(theirUpdatedAt))
						elseif not ourHash or ourHash == 0 then
							-- Store hash if we don't have one
							ourAlt.inventoryHash = theirHash
							if theirUpdatedAt then
								ourAlt.inventoryUpdatedAt = theirUpdatedAt
							end
							TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "Stored missing hash for %s: hash=%08x, updatedAt=%s", kNorm, theirHash, tostring(theirUpdatedAt))
						end
					end
				end

				-- MAIL-012 fix: Don't query if WE are the sender (prevents self-queries)
				-- Previous logic (kNorm ~= senderNorm) incorrectly prevented OTHER players
				-- from querying the sender's own data (e.g., Pickyminer couldn't query Togammo-Azuresong)
				local ourPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()
				local senderNorm = TOGBankClassic_Guild:NormalizeName(sender)
				local weAreSender = (ourPlayer == senderNorm)

				-- MAIL-012 DEBUG: Log the sender check
				TOGBankClassic_Output:Debug(
					"PROTOCOL", "MAIL-012",
					"[MAIL-012] Sender check for %s: ourPlayer=%s, senderNorm=%s, weAreSender=%s",
					kNorm,
					ourPlayer,
					senderNorm,
					tostring(weAreSender)
				)

				if not weAreSender then
					-- We're not the sender, so we can query about any alt including the sender
					-- For delta version broadcasts, only query if we support delta
					-- For legacy version broadcasts, query as normal
					local shouldQuery = false

					-- Check if we already have content for this alt - skip if we do
					local localAlt = current_data.alts and kNorm and current_data.alts[kNorm]
					local hasContent = localAlt and TOGBankClassic_Guild and TOGBankClassic_Guild.HasAltContent
						and TOGBankClassic_Guild:HasAltContent(localAlt)

					if hasContent then
					-- Skip querying for alts we already have content for
					TOGBankClassic_Output:Debug(
						"PROTOCOL", "MAIL-012",
						"[MAIL-012] Query decision for %s: SKIP (already have content)",
						kNorm
					)
				else
					-- MAIL-012 DEBUG: Log query decision path
					TOGBankClassic_Output:Debug(
						"PROTOCOL", "MAIL-012",
						"[MAIL-012] Query evaluation for %s: isDeltaVersion=%s, ShouldUseDelta=%s",
						kNorm,
						tostring(isDeltaVersion),
						tostring(TOGBankClassic_Guild:ShouldUseDelta())
					)

					if isDeltaVersion then
						-- Delta version: check hash first (most accurate), then version
						if TOGBankClassic_Guild:ShouldUseDelta() then
							-- Hash-based comparison (most accurate)
							if theirHash then
								if not ourHash then
									-- They have data, we don't - query
									shouldQuery = true
									self:Debug(
										"SYNC",
										">",
										ColorPlayerName(sender),
										"has bank data for",
										ColorPlayerName(kNorm) .. " (we have none), querying."
									)
									TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-012", "[MAIL-012] Query decision for %s: NO_OUR_HASH", kNorm)
								elseif theirHash ~= ourHash or theirMailHash ~= ourMailHash then
									-- Hashes differ (inventory or mail) - we need an update
									shouldQuery = true
									local reason = (theirHash ~= ourHash) and "inventory" or "mail"
									self:Debug(
										"SYNC",
										">",
										ColorPlayerName(sender),
										"has different " .. reason .. " for",
										ColorPlayerName(kNorm) .. " (hash mismatch), querying."
									)
									TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-012", "[MAIL-SYNC] Query decision for %s: HASH_MISMATCH %s (ourInv=%d, theirInv=%d, ourMail=%d, theirMail=%d)", 
										kNorm, reason, ourHash, theirHash, ourMailHash, theirMailHash)
								elseif not hasContent then
									-- Hash matches but we don't have content (stub entry) - need to fill it
									shouldQuery = true
									self:Debug(
										"SYNC",
										">",
										ColorPlayerName(sender),
										"has matching hash for",
										ColorPlayerName(kNorm) .. " but we need content (stub entry), querying."
									)
									TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-012", "[MAIL-012] Query decision for %s: HASH_MATCH_NO_CONTENT (filling stub)", kNorm)
								else
									TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-012", "[MAIL-012] Query decision for %s: HASH_MATCH_WITH_CONTENT (no query)", kNorm)
								end
							elseif not ourVersion or theirVersion > ourVersion then
								-- No hash available, fall back to version comparison
								shouldQuery = true
								self:Debug(
									"SYNC",
									">",
									ColorPlayerName(sender),
									"has fresher bank data about",
									ColorPlayerName(kNorm) .. ", querying (delta)."
								)
								TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-012", "[MAIL-012] Query decision for %s: VERSION_NEWER", kNorm)
							else
								TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-012", "[MAIL-012] Query decision for %s: VERSION_SAME_OR_OLDER (no query)", kNorm)
							end
						else
							TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-012", "[MAIL-012] Query decision for %s: DELTA_DISABLED (no query)", kNorm)
						end
					else
						-- Legacy version: query as usual
						if not ourVersion or theirVersion > ourVersion then
							shouldQuery = true
							self:Debug(
								"SYNC",
								">",
								ColorPlayerName(sender),
								"has fresher bank data about",
								ColorPlayerName(kNorm) .. ", querying."
							)
							TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-012", "[MAIL-012] Query decision for %s: LEGACY_VERSION_NEWER", kNorm)
						else
							TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-012", "[MAIL-012] Query decision for %s: LEGACY_VERSION_SAME_OR_OLDER (no query)", kNorm)
						end
					end
				end -- Close hasContent else block

				if shouldQuery then
					-- v0.8.0: Use P2P broadcast when hash available, fallback to banker query
					TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-012", "[MAIL-012] QUERYING %s from %s (reason: version broadcast mismatch)", kNorm, sender)
					if theirHash and theirHash ~= 0 then
						-- P2P: Broadcast to guild with hash, wait for peers, fallback to banker
						TOGBankClassic_Guild:BroadcastP2PRequest(kNorm, theirHash, theirVersion, sender)
					else
						-- No hash available, go straight to banker as last resort
						TOGBankClassic_Guild:QueryAltPullBased(kNorm, false, false, sender)
					end
				end
			else
					-- MAIL-012 DEBUG: Log when we skip because we are the sender
					TOGBankClassic_Output:Debug(
						"PROTOCOL", "MAIL-012",
						"[MAIL-012] Skipping %s: weAreSender=true (ourPlayer=%s, senderNorm=%s)",
						kNorm,
						ourPlayer,
						senderNorm
					)
				end
			end
		end
		--]]
	end
end

-- PERF-020: Process queued hash broadcasts in batch to prevent stuttering
function TOGBankClassic_Chat:ProcessQueuedHashBroadcasts()
	local startTime = debugprofilestop()
	local queueSize = #self.hashBroadcastQueue
	
	if queueSize == 0 then
		return
	end
	
	TOGBankClassic_Output:Debug("P2P", "OFFER", "Processing %d queued hash broadcasts", queueSize)
	
	-- Deduplicate by sender (if same sender broadcasted multiple times, process most recent)
	local uniqueBroadcasts = {}
	for _, entry in ipairs(self.hashBroadcastQueue) do
		uniqueBroadcasts[entry.sender] = entry  -- Later entries overwrite earlier ones
	end
	
	-- Process each unique broadcast
	for sender, entry in pairs(uniqueBroadcasts) do
		local data = entry.data
		local isSenderBanker = entry.isSenderBanker
		
		-- Build hash-offer: alts where WE have newer data than what the sender advertised
		local offerAlts  = {}
		local myAlts     = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts or {}
		local myPlayer   = TOGBankClassic_Guild:GetNormalizedPlayer()
		
		for altName, peerSummary in pairs(data.alts) do
			local norm = TOGBankClassic_Guild:NormalizeName(altName)
			if norm and norm ~= myPlayer then
				local myAlt = myAlts[norm]
				if myAlt and TOGBankClassic_Guild:HasAltContent(myAlt, norm) then
					local myUpdatedAt   = myAlt.inventoryUpdatedAt or myAlt.version or 0
					local peerUpdatedAt = peerSummary.updatedAt or 0
					if myUpdatedAt > peerUpdatedAt then
						offerAlts[norm] = {
							hash      = myAlt.inventoryHash or 0,
							updatedAt = myUpdatedAt,
							mailHash  = myAlt.mailHash or 0,
						}
					end
				end
			end
		end
		
		local offerCount = 0
		for _ in pairs(offerAlts) do offerCount = offerCount + 1 end
		if offerCount > 0 then
			local offerData = TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-offer", alts = offerAlts })
			TOGBankClassic_Core:SendWhisper("togbank-hl", offerData, sender, "NORMAL")
			TOGBankClassic_Output:Debug("P2P", "Sent hash-offer to %s for %d alts", sender, offerCount)
		end
		
		-- Banker-only legacy path: cache authoritative hashes and forward to togbank-hlr
		if isSenderBanker then
			if not TOGBankClassic_Guild.latestBankerHashes then
				TOGBankClassic_Guild.latestBankerHashes = {}
			end
			for altName, summary in pairs(data.alts) do
				local norm = TOGBankClassic_Guild:NormalizeName(altName)
				if norm and summary then
					TOGBankClassic_Guild.latestBankerHashes[norm] = summary
				end
			end
			local hlrPayload = {
				type     = "hash-list-reply",
				alts     = data.alts,
				banker   = data.banker or sender,
				isBanker = true,
			}
			local hlrData = TOGBankClassic_Core:SerializeWithChecksum(hlrPayload)
			self:OnCommReceived("togbank-hlr", hlrData, entry.distribution, sender)
		end
	end
	
	-- Clear queue and timer
	self.hashBroadcastQueue = {}
	self.hashBroadcastTimer = nil
	
	local duration = debugprofilestop() - startTime
	TOGBankClassic_Output:Debug("P2P", "OFFER", "Batch processed %d broadcasts in %.2fms", queueSize, duration)
end

function TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	local prefixDesc = COMM_PREFIX_DESCRIPTIONS[prefix] or "(Unknown)"

	if prefix == "togbank-hlr" then
		TOGBankClassic_Output:Debug("PROTOCOL", "HLR", "HLR incoming: from=%s via=%s (%d bytes)", tostring(sender), tostring(distribution), message and #message or 0)
	end

	-- Debug: Log ALL incoming messages before any filtering
	if prefix == "togbank-dv" or prefix == "togbank-dv2" then
		TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-012", "[MAIL-012] RAW RECEIVED: %s from %s (%d bytes)", prefix, sender, #message)
	end

	-- WHISPER DEBUG
	if distribution == "WHISPER" or prefix == "togbank-r" or prefix == "togbank-rr" then
		TOGBankClassic_Output:DebugComm("RECEIVED: %s via %s from %s", prefix, distribution, sender)
	end

	if IsInRaid() then
		self:Debug("PROTOCOL", "HASH-SKIP", "> (ignoring)", prefix, prefixDesc, "from", ColorPlayerName(sender), "(in raid)")
		return
	end
	local player = TOGBankClassic_Guild:GetPlayer()
	-- Normalize the sender so spacing/hyphen formats match
	sender = TOGBankClassic_Guild:NormalizeName(sender)

	-- Mark sender as online (they just sent us a message, so they're definitionally online)
	-- This is a FALLBACK for when CHAT_MSG_SYSTEM events haven't fired yet
	-- Source tracking helps debug where online status updates come from
	TOGBankClassic_Guild:UpdateOnlineMember(sender, true, "addon-message-received")

	-- MAIL-012 DEBUG: Log the player check for delta version messages
	if prefix == "togbank-dv2" or prefix == "togbank-dv" then
		TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-012", "[MAIL-012] Player check: player=%s, sender=%s, match=%s",
			player, sender, tostring(player == sender))
	end

	if player == sender then
		self:Debug("PROTOCOL", "HASH-SKIP", "> (ignoring)", prefix, prefixDesc, "(our own)")
		return
	end

	local success, data = TOGBankClassic_Core:DeserializeWithChecksum(message)
	if not success then
		self:Debug("PROTOCOL", "> failed to deserialize", prefix, prefixDesc, "from", ColorPlayerName(sender), "error:", tostring(data))
		if prefix == "togbank-hlr" then
			TOGBankClassic_Output:Debug("PROTOCOL", "HLR", "HLR deserialize failed: %s", tostring(data))
		end
		return
	end

	-- Debug: Log what we deserialized for togbank-dv
	if prefix == "togbank-dv" then
		local altCount = 0
		if data and data.alts then
			for _ in pairs(data.alts) do
				altCount = altCount + 1
			end
		end
		TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "[DESERIALIZE] togbank-dv from %s: success=%s, has data=%s, has data.alts=%s, altCount=%d",
			sender,
			tostring(success),
			tostring(data ~= nil),
			tostring(data and data.alts ~= nil),
			altCount
		)
	end

	if prefix ~= "togbank-r" and prefix ~= "togbank-d" then
		-- togbank-r and togbank-d do their own output
		self:Debug("PROTOCOL", ">", ColorPlayerName(sender), ">", prefix, prefixDesc)
	end

	-- togbank-v and togbank-dv unregistered; only togbank-dv2 (SYNC-006) is active
	if prefix == "togbank-dv2" then
		self:ProcessVersionBroadcast(prefix, data, sender, message, distribution)
		return
	end

	if prefix == "togbank-r" then
		TOGBankClassic_Output:DebugComm("togbank-r DATA.TYPE = %s from %s", tostring(data.type), sender)

		-- v0.8.0: Check if this is a pull-based request (has type == "alt-request")
		if data.type == "alt-request" then
			-- Pull-based request flow - respond with togbank-rr acknowledgment
			local altName = data.name
			local requester = data.requester or sender
			local hashOnly = data.hashOnly or false
			local normAltName = TOGBankClassic_Guild:NormalizeName(altName)

			TOGBankClassic_Output:DebugComm("RECEIVED PULL-BASED REQUEST from %s for alt %s (hashOnly=%s)", sender, altName, tostring(hashOnly))

			TOGBankClassic_Output:Debug("QUERIES", "> %s %s %s",
				ColorPlayerName(sender),
				hashOnly and "queries hash query for" or "queries pull-based request for",
				ColorPlayerName(altName)
			)

			-- Check if we have this alt
			local player = TOGBankClassic_Guild:GetNormalizedPlayer()
			local isBanker = player and TOGBankClassic_Guild:IsBank(player) or false
			local hasData = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts and normAltName and TOGBankClassic_Guild.Info.alts[normAltName] ~= nil

			-- PERF-005: Compute hash on-demand if missing (for alts that haven't rescanned since hash was added)
			if hasData and isBanker then
				local alt = TOGBankClassic_Guild.Info.alts[normAltName]
				if not alt.inventoryHash and alt.items then
					-- Compute hash from existing items data
					alt.inventoryHash = TOGBankClassic_Core:ComputeInventoryHash(alt.items, nil, nil, alt.money or 0)
					TOGBankClassic_Output:Debug("SYNC", "HASH-CORRECTION", "PERF-005: Computed missing inventoryHash for %s: %d", altName, alt.inventoryHash or 0)
				end
				-- Compute missing mailHash if we have mail data
				if not alt.mailHash and alt.mail and alt.mail.items and #alt.mail.items > 0 then
					alt.mailHash = TOGBankClassic_Core:ComputeInventoryHash(alt.mail.items, nil, nil, nil)
					TOGBankClassic_Output:Debug("SYNC", "HASH-CORRECTION", "PERF-005: Computed missing mailHash for %s: %d", altName, alt.mailHash or 0)
				end
			end

			-- PERF-005: For hashOnly queries, only bankers respond (authoritative hash source)
			-- For regular queries, anyone with matching hash can respond (if P2P enabled)
			local shouldRespond = false
			local expectedHash = nil
			local expectedUpdatedAt = nil

			if hashOnly then
				-- Hash query: only banker responds with authoritative hash
				shouldRespond = isBanker and hasData
				if shouldRespond then
					local alt = TOGBankClassic_Guild.Info.alts[normAltName]
					expectedHash = alt.inventoryHash or 0
					expectedUpdatedAt = alt.inventoryUpdatedAt or alt.version or 0
				end
			else
				-- Regular query: bankers respond if they have content, peers respond if hash matches (P2P)
				if isBanker and hasData then
					local alt = TOGBankClassic_Guild.Info.alts[normAltName]
					local hasContent = TOGBankClassic_Guild:HasAltContent(alt, altName)
					if hasContent then
						shouldRespond = true
						-- PERF-005: Banker includes hash for P2P validation
						expectedHash = alt.inventoryHash or 0
						expectedUpdatedAt = alt.inventoryUpdatedAt or alt.version or 0
					else
						TOGBankClassic_Output:Debug("QUERIES", "P2P-005: Banker skipping response for %s (no content - stub entry)", altName)
					end
				elseif PEER_TO_PEER and PEER_TO_PEER.ENABLED and hasData then
					local alt = TOGBankClassic_Guild.Info.alts[normAltName]
					local myHash = alt.inventoryHash or 0
					local hasContent = TOGBankClassic_Guild:HasAltContent(alt, altName)
					local sendQueueFull = TOGBankClassic_Guild.pendingSendCount >= TOGBankClassic_Guild.MAX_PENDING_SENDS
					local requesterHash = data.requesterInventoryHash or 0
					
					-- Allow response in two scenarios:
					-- 1. P2P with expectedHash: hash must match (normal P2P operation)
					-- 2. No expectedHash but requesterHash=0: post-wipe recovery, any peer can help
					local shouldRespondP2P = false
					if data.expectedHash and myHash == data.expectedHash and hasContent and not sendQueueFull then
						-- Normal P2P: hash match required
						shouldRespondP2P = true
						TOGBankClassic_Output:Debug("QUERIES", "PERF-005: Peer responding for %s (hash match: %d)", altName, myHash)
					elseif not data.expectedHash and requesterHash == 0 and hasContent and not sendQueueFull then
						-- Post-wipe recovery: requester has no data, any peer can help
						shouldRespondP2P = true
						TOGBankClassic_Output:Debug("QUERIES", "WIPE-RECOVERY: Peer responding for %s (requester wiped, providing fresh data)", altName)
					elseif sendQueueFull then
						TOGBankClassic_Output:Debug("QUERIES", "PERF-005: Skipping response (send queue full: %d/%d)",
							TOGBankClassic_Guild.pendingSendCount, TOGBankClassic_Guild.MAX_PENDING_SENDS)
					elseif data.expectedHash and myHash == data.expectedHash and not hasContent then
						TOGBankClassic_Output:Debug("QUERIES", "PERF-005: Skipping response for %s (hash matches but no content)", altName)
					elseif data.expectedHash and myHash ~= data.expectedHash then
						TOGBankClassic_Output:Debug("QUERIES", "PERF-005: Hash mismatch for %s (have %d, expected %d)", altName, myHash, data.expectedHash)
					end
					
					if shouldRespondP2P then
						-- FIX: Add random backoff to prevent multiple peers responding simultaneously
						local backoff = math.random() * 0.5  -- 0-500ms random delay
						C_Timer.After(backoff, function()
							-- Check if someone else already responded
							if TOGBankClassic_Guild.pendingSendCount >= TOGBankClassic_Guild.MAX_PENDING_SENDS then
								TOGBankClassic_Output:Debug("QUERIES", "PERF-005: Another peer beat us to it, not responding for %s", altName)
								return
							end
							
							shouldRespond = true
							expectedHash = myHash
							TOGBankClassic_Guild.pendingSendCount = TOGBankClassic_Guild.pendingSendCount + 1
							TOGBankClassic_Output:Debug("P2P", "RESPOND", "P2P: Responding to %s with data for %s (hash=%08x) - queue now: %d/%d",
								sender, altName, myHash, TOGBankClassic_Guild.pendingSendCount, TOGBankClassic_Guild.MAX_PENDING_SENDS)
							if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name then
								TOGBankClassic_Database:RecordP2POffered(TOGBankClassic_Guild.Info.name)
							end
							
							-- Safety timeout: if requester never sends state summary (disconnect/crash),
							-- auto-decrement counter after 30 seconds to prevent permanent queue blocking
							local timeoutAlt = normAltName
							if not TOGBankClassic_Guild.pendingSendTimeouts then
								TOGBankClassic_Guild.pendingSendTimeouts = {}
							end
							local timer = C_Timer.After(30, function()
								if TOGBankClassic_Guild.pendingSendCount > 0 then
									TOGBankClassic_Guild.pendingSendCount = TOGBankClassic_Guild.pendingSendCount - 1
									TOGBankClassic_Output:Debug("SYNC", "P2P-FALLBACK", "P2P: Send timeout for %s - decremented queue (now %d/%d)",
										timeoutAlt, TOGBankClassic_Guild.pendingSendCount, TOGBankClassic_Guild.MAX_PENDING_SENDS)
								end
								TOGBankClassic_Guild.pendingSendTimeouts[timeoutAlt] = nil
							end)
							TOGBankClassic_Guild.pendingSendTimeouts[normAltName] = timer
							
							-- Actually send the ACK now
							if shouldRespond then
								local ack = {
									type = "alt-request-reply",
									name = normAltName or altName,
									isBanker = isBanker,
									hasData = hasData,
									hashOnly = hashOnly,
									expectedHash = expectedHash,
									expectedUpdatedAt = expectedUpdatedAt,
								}
								local ackData = TOGBankClassic_Core:SerializeWithChecksum(ack)
								TOGBankClassic_Output:DebugComm("SENDING ACK: togbank-rr via WHISPER to %s (isBanker=%s, hasData=%s, hash=%s, updatedAt=%s)",
									sender, tostring(isBanker), tostring(hasData), tostring(expectedHash), tostring(expectedUpdatedAt))
								TOGBankClassic_Core:SendCommMessage("togbank-rr", ackData, "WHISPER", sender, "NORMAL")
								TOGBankClassic_Chat:Debug(
									"SYNC",
									"<",
									"Sent togbank-rr to",
									ColorPlayerName(sender),
									string.format("(isBanker=%s, hasData=%s, hash=%s)", tostring(isBanker), tostring(hasData), tostring(expectedHash))
								)
							end
						end)
						return  -- Exit early since we'll send ACK in timer
					end
				end
			end

			if shouldRespond then
				-- Send acknowledgment with banker flag and hash
				-- Note: P2P responses with backoff are handled above and return early
				local ack = {
					type = "alt-request-reply",
					name = normAltName or altName,
					isBanker = isBanker,
					hasData = hasData,
					hashOnly = hashOnly,
					expectedHash = expectedHash,  -- PERF-005: Include hash for P2P validation
					expectedUpdatedAt = expectedUpdatedAt,
				}
				local ackData = TOGBankClassic_Core:SerializeWithChecksum(ack)

				-- Send acknowledgment via WHISPER to reduce guild channel spam
				TOGBankClassic_Output:DebugComm("SENDING ACK: togbank-rr via WHISPER to %s (isBanker=%s, hasData=%s, hash=%s, updatedAt=%s)",
					sender, tostring(isBanker), tostring(hasData), tostring(expectedHash), tostring(expectedUpdatedAt))
				if TOGBankClassic_Core:SendWhisper("togbank-rr", ackData, sender, "NORMAL") then
					self:Debug(
						"SYNC",
						"<",
						"Sent togbank-rr to",
						ColorPlayerName(sender),
						string.format("(isBanker=%s, hasData=%s, hash=%s)", tostring(isBanker), tostring(hasData), tostring(expectedHash))
					)
				end

			else
				-- Don't respond if we don't have the data
				if not hasData then
					TOGBankClassic_Output:Debug(
						"QUERIES",
						"Ignoring pull-based request for %s (no data): isBanker=%s, hasInfo=%s",
						altName,
						tostring(isBanker),
						tostring(TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts and TOGBankClassic_Guild.Info.alts[normAltName] ~= nil)
					)
				else
					-- We have data but not responding - explain why
					local reason = "unknown"
					if hashOnly and not isBanker then
						reason = "hash query but not banker"
					elseif not hashOnly and not isBanker then
						if not PEER_TO_PEER or not PEER_TO_PEER.ENABLED then
							reason = "P2P disabled"
						else
							local alt = TOGBankClassic_Guild.Info.alts[normAltName]
							local myHash = alt and alt.inventoryHash or 0
							local hasContent = alt and TOGBankClassic_Guild:HasAltContent(alt, altName) or false
							local sendQueueFull = TOGBankClassic_Guild.pendingSendCount >= TOGBankClassic_Guild.MAX_PENDING_SENDS
							local requesterHash = data.requesterInventoryHash or 0
							
							if sendQueueFull then
								reason = string.format("send queue full (%d/%d)", TOGBankClassic_Guild.pendingSendCount, TOGBankClassic_Guild.MAX_PENDING_SENDS)
							elseif not hasContent then
								reason = "no content (stub entry)"
							elseif data.expectedHash and myHash ~= data.expectedHash then
								reason = string.format("hash mismatch (have %d, expected %d)", myHash, data.expectedHash)
							elseif not data.expectedHash and requesterHash ~= 0 then
								reason = string.format("no expectedHash but requester has data (requesterHash=%d)", requesterHash)
							else
								reason = "shouldRespond logic failed"
							end
						end
					end
					TOGBankClassic_Output:Debug("QUERIES", "Ignoring pull-based request for %s (%s)", altName, reason)
				end
			end

			return
		end

		-- Legacy request handling
		if data.player then
			-- Use REQUESTS category for request-related queries, SYNC for alt queries
			local isRequestQuery = data.type and string.find(data.type, "^requests") ~= nil
			local category = isRequestQuery and "REQUESTS" or "SYNC"
			local extraInfo = ""
			if data.type == "requests-index" and data.hash then
				local myHash = TOGBankClassic_Guild:GetRequestsHash()
				local querierHash = tonumber(data.hash) or 0
				extraInfo = string.format(" (their:%08x ours:%08x)", querierHash, myHash)
			end
			self:Debug(
				category,
				">",
				ColorPlayerName(sender),
				QUERIES_COLOR,
				isRequestQuery and "[REQ]" or "",
				data.type,
				(data.name and ColorPlayerName(TOGBankClassic_Guild:NormalizeName(data.name)) or "") .. extraInfo
			)

			if data.type == "requests-index" then
				-- Track addon version (all clients broadcast this on login and periodically)
				if data.addon then
					if not self.guild_versions then self.guild_versions = {} end
					self.guild_versions[sender] = {
						version = data.addon,
						seen    = time(),
					}
				end
				local matches = (data.player == "*" or data.player == player)
				if matches then
					-- SYNC-011: Only respond if our hash differs from the querier's.
					-- If hashes match, querier already has exactly what we have - stay silent.
					local myHash = TOGBankClassic_Guild:GetRequestsHash()
					local querierHash = tonumber(data.hash) or 0
					if querierHash == 0 or myHash ~= querierHash then
						TOGBankClassic_Output:DebugComm("REQUEST INDEX HANDLER: Responding to requests-index query (hash mismatch: mine=%08x theirs=%08x)", myHash, querierHash)
						TOGBankClassic_Guild:EnqueueIndexResponse(sender)
					else
						TOGBankClassic_Output:DebugComm("REQUEST INDEX HANDLER: Skipping (hash match %d, querier already in sync)", myHash)
					end
				end
			end
			if data.type == "requests-by-id" then
				local matches = (data.player == "*" or data.player == player)
				if matches then
					TOGBankClassic_Output:Debug("REQUESTS", "INDEX",
						"%s queries [REQ] requests-by-id (%d IDs)", tostring(sender), data.ids and #data.ids or 0)
					TOGBankClassic_Guild:EnqueueRequestsById(sender, data.ids)
				end
			end
		end

		-- Alt queries are per-player, only respond if query is for us
		if data.player and data.player == player then
			-- Roster query removed: Roster is now rebuilt locally from guild notes

			if data.type == "alt" then
				local nameNorm = TOGBankClassic_Guild:NormalizeName(data.name)

				-- Check if query includes version and we can send delta chain
				if data.version and TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts[nameNorm] then
					local currentVersion = TOGBankClassic_Guild.Info.alts[nameNorm].version
					local requestedVersion = data.version

					-- If requester has old version, try to send delta chain immediately
					if type(requestedVersion) == "number" and type(currentVersion) == "number" and requestedVersion < currentVersion then
						local deltaChain = TOGBankClassic_Database:GetDeltaHistory(TOGBankClassic_Guild.Info.name, nameNorm, requestedVersion, currentVersion)
						if deltaChain and #deltaChain > 0 then
							TOGBankClassic_Output:Debug(
								"DELTA",
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

	-- v0.8.0: Pull-based request reply handler (togbank-rr)
	if prefix == "togbank-rr" then
		-- P2P-006: Session handshake — sync-request (we are the data provider).
		-- Requester asks us to send data for one alt; we accept or reject based on capacity.
		if data.type == "sync-request" then
			local sessionId = data.sessionId
			local requester = data.requester or sender
			local altName   = data.altName
			TOGBankClassic_Output:Debug("P2P", "sync-request from %s for %s (sid=%s)",
				requester, tostring(altName), tostring(sessionId))
			if TOGBankClassic_P2PSession and altName and sessionId then
				TOGBankClassic_P2PSession:HandleSyncRequest(sessionId, requester, altName)
			end
			return
		end
		-- P2P-006: sync-accept / sync-busy (we are the requester; peer answered our sync-request).
		if data.type == "sync-accept" then
			local sessionId = data.sessionId
			TOGBankClassic_Output:Debug("P2P", "sync-accept from %s (sid=%s)", sender, tostring(sessionId))
			if TOGBankClassic_P2PSession and sessionId then
				TOGBankClassic_P2PSession:OnSyncAccept(sessionId, sender)
			end
			return
		end
		if data.type == "sync-busy" then
			local sessionId = data.sessionId
			TOGBankClassic_Output:Debug("P2P", "sync-busy from %s (sid=%s)", sender, tostring(sessionId))
			if TOGBankClassic_P2PSession and sessionId then
				TOGBankClassic_P2PSession:OnSyncBusy(sessionId, sender)
			end
			return
		end
		if data.type == "alt-request-reply" then
			local altName = data.name
			local isBanker = data.isBanker or false
			local hasData = data.hasData or false
			local hashOnly = data.hashOnly or false
			local expectedHash = data.expectedHash
			local expectedUpdatedAt = data.expectedUpdatedAt

			TOGBankClassic_Output:DebugComm("RECEIVED ACK: togbank-rr from %s for alt %s (isBanker=%s, hasData=%s, hashOnly=%s, hash=%s, updatedAt=%s)",
				sender, altName, tostring(isBanker), tostring(hasData), tostring(hashOnly), tostring(expectedHash), tostring(expectedUpdatedAt))

			self:Debug(
				"SYNC",
				">",
				ColorPlayerName(sender),
				QUERIES_COLOR,
				string.format("acknowledged request for %s (banker=%s, hasData=%s, hash=%s)",
					ColorPlayerName(altName),
					tostring(isBanker),
					tostring(hasData),
					tostring(expectedHash))
			)

			-- PERF-005: If we have a hash from banker, broadcast to GUILD to enable P2P
			-- Any peer with matching hash can respond instead of just the banker
			if isBanker and hashOnly and expectedHash and PEER_TO_PEER and PEER_TO_PEER.ENABLED then
				-- Store expected hash for validation when peers respond
				if not TOGBankClassic_Guild.expectedHashes then
					TOGBankClassic_Guild.expectedHashes = {}
				end
				local norm = TOGBankClassic_Guild:NormalizeName(altName)
				TOGBankClassic_Guild.expectedHashes[norm] = expectedHash
				if expectedUpdatedAt then
					TOGBankClassic_Guild.expectedHashUpdatedAt = TOGBankClassic_Guild.expectedHashUpdatedAt or {}
					TOGBankClassic_Guild.expectedHashUpdatedAt[norm] = expectedUpdatedAt
				end

				-- Track pending P2P request for fallback
				TOGBankClassic_Guild.pendingP2PRequests = TOGBankClassic_Guild.pendingP2PRequests or {}
				TOGBankClassic_Guild.pendingP2PRequests[norm] = { banker = sender, requestedAt = GetTime() }

				-- Now broadcast regular request to GUILD with expectedHash so peers can respond
			-- MAIL-SYNC: Include requester's mailHash for mail change detection
			local ourAlt = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts and TOGBankClassic_Guild.Info.alts[altName]
			local ourMailHash = (ourAlt and ourAlt.mailHash) or 0
			local p2pRequest = {
				type = "alt-request",
				name = altName,
				requester = TOGBankClassic_Guild:GetNormalizedPlayer(),
				hashOnly = false,
				expectedHash = expectedHash,  -- Peers will validate against this
				requesterMailHash = ourMailHash,  -- MAIL-SYNC: Mail change detection
			}
			local p2pData = TOGBankClassic_Core:SerializeWithChecksum(p2pRequest)
			TOGBankClassic_Core:SendCommMessage("togbank-hl", p2pData, "GUILD", nil, "NORMAL")
				if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name then
					TOGBankClassic_Database:RecordP2PRequestBroadcast(TOGBankClassic_Guild.Info.name)
				end

				-- Fallback: if no peer responds, request from banker directly
				local timeoutTimer = C_Timer.After(5, function()
					local norm = TOGBankClassic_Guild:NormalizeName(altName)
					local pending = TOGBankClassic_Guild.pendingP2PRequests and TOGBankClassic_Guild.pendingP2PRequests[norm]
					if pending then
						TOGBankClassic_Guild.pendingP2PRequests[norm] = nil
						-- PERF-006: Clear pendingAltRequests to allow banker fallback
						if TOGBankClassic_Guild.pendingAltRequests then
							TOGBankClassic_Guild.pendingAltRequests[norm] = nil
						end
						-- FIX: Clear expectedHashes on fallback
						if TOGBankClassic_Guild.expectedHashes then
							TOGBankClassic_Guild.expectedHashes[norm] = nil
						end
						if TOGBankClassic_Guild.expectedHashUpdatedAt then
							TOGBankClassic_Guild.expectedHashUpdatedAt[norm] = nil
						end
						-- Clear timeout timer tracking
						if TOGBankClassic_Guild.pendingP2PTimeouts then
							TOGBankClassic_Guild.pendingP2PTimeouts[norm] = nil
						end
						-- Also cancel 15s fallback if it exists (shouldn't exist yet, but be defensive)
						if TOGBankClassic_Guild.pendingP2PFallbackTimeouts and TOGBankClassic_Guild.pendingP2PFallbackTimeouts[norm] then
							TOGBankClassic_Guild.pendingP2PFallbackTimeouts[norm]:Cancel()
							TOGBankClassic_Guild.pendingP2PFallbackTimeouts[norm] = nil
						end
						TOGBankClassic_Output:Debug("SYNC", "PERF-005: No P2P response for %s, requesting banker directly", altName)
						if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name then
							TOGBankClassic_Database:RecordP2PBankerFallback(TOGBankClassic_Guild.Info.name)
						end
						TOGBankClassic_Guild:QueryAltPullBased(altName, false)
					end
				end)
				
				-- Store timeout timer for cancellation if peer responds
				if not TOGBankClassic_Guild.pendingP2PTimeouts then
					TOGBankClassic_Guild.pendingP2PTimeouts = {}
				end
				TOGBankClassic_Guild.pendingP2PTimeouts[norm] = timeoutTimer
			elseif not isBanker and hasData and TOGBankClassic_Guild.pendingP2PRequests then
				-- P2P: Non-banker (peer) acknowledged - continue with delta sync
				local norm = TOGBankClassic_Guild:NormalizeName(altName)
				local wasPending = TOGBankClassic_Guild.pendingP2PRequests[norm] ~= nil
				
				if wasPending then
					TOGBankClassic_Output:Info("P2P: Peer %s acknowledged %s - will send delta", sender, altName)
					
					-- Clear pending P2P request since peer is responding
					TOGBankClassic_Guild.pendingP2PRequests[norm] = nil
					
					-- FIX: Cancel the first timeout timer since peer responded
					if TOGBankClassic_Guild.pendingP2PTimeouts and TOGBankClassic_Guild.pendingP2PTimeouts[norm] then
						TOGBankClassic_Guild.pendingP2PTimeouts[norm]:Cancel()
						TOGBankClassic_Guild.pendingP2PTimeouts[norm] = nil
					end
					
					-- Also clear pendingAltRequests to prevent banker fallback
					if TOGBankClassic_Guild.pendingAltRequests then
						TOGBankClassic_Guild.pendingAltRequests[norm] = nil
					end

					-- Secondary timeout: if peer ACKs but never sends data (disconnect/crash),
					-- fallback to banker after 15 seconds
					local fallbackTimer = C_Timer.After(15, function()
						-- Check if we still don't have content (peer never delivered)
						local alt = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts and TOGBankClassic_Guild.Info.alts[norm]
						if not alt or not TOGBankClassic_Guild:HasAltContent(alt, norm) then
							TOGBankClassic_Output:Debug("SYNC", "P2P: Peer %s ACKed %s but never delivered data - falling back to banker", sender, altName)
							TOGBankClassic_Guild:QueryAltPullBased(altName, false)
						else
							TOGBankClassic_Output:Debug("SYNC", "P2P: Peer %s successfully delivered data for %s", sender, altName)
						end
						-- Clean up timer reference
						if TOGBankClassic_Guild.pendingP2PFallbackTimeouts then
							TOGBankClassic_Guild.pendingP2PFallbackTimeouts[norm] = nil
						end
					end)

					-- Store timer for cancellation
					if not TOGBankClassic_Guild.pendingP2PFallbackTimeouts then
						TOGBankClassic_Guild.pendingP2PFallbackTimeouts = {}
					end
					TOGBankClassic_Guild.pendingP2PFallbackTimeouts[norm] = fallbackTimer

					-- Send state summary for delta comparison
					if hasData and expectedHash then
						TOGBankClassic_Output:DebugComm("CALLING SendStateSummary for %s to %s", altName, sender)
						TOGBankClassic_Guild:SendStateSummary(altName, sender)
					end
				end
			elseif hasData then
				-- Banker (non-P2P path) or fallback - send state summary
				if expectedHash == nil then
					TOGBankClassic_Output:Debug("PROTOCOL", "PERF-006: Responder has no hash support (old code) - forcing full data request for %s", altName)
					TOGBankClassic_Guild:SendStateSummary(altName, sender, true) -- forceFull=true
				else
					TOGBankClassic_Output:DebugComm("CALLING SendStateSummary for %s to %s", altName, sender)
					TOGBankClassic_Guild:SendStateSummary(altName, sender)
				end
			else
				TOGBankClassic_Output:DebugComm("NOT sending state summary (hasData=false)")
			end
	end
end

-- v0.8.0: State summary handler (togbank-state) - Step 5 & 6 of pull-based flow
	if prefix == "togbank-state" then
		if data.type == "state-summary" then
			local altName = data.name
			local summary = data.summary

			TOGBankClassic_Output:DebugComm("RECEIVED STATE SUMMARY from %s for alt %s (hash=%s, version=%s)", sender, altName, tostring(summary and summary.hash), tostring(summary and summary.version))

			self:Debug(
				"SYNC",
				">",
				ColorPlayerName(sender),
				QUERIES_COLOR,
				string.format("received state summary for %s", ColorPlayerName(altName))
			)

			-- Compute and send response (full/delta/no-change)
			TOGBankClassic_Output:DebugComm("CALLING RespondToStateSummary for %s from %s", altName, sender)
			TOGBankClassic_Guild:RespondToStateSummary(altName, summary, sender)
		end
	end

	-- v0.8.0: No-change handler (togbank-nochange)
	if prefix == "togbank-nochange" then
		if data.type == "no-change" then
			local altName = data.name
			local version = data.version or 0
			if TOGBankClassic_Guild.pendingAltRequests then
				local norm = TOGBankClassic_Guild:NormalizeName(altName)
				TOGBankClassic_Guild.pendingAltRequests[norm] = nil
			end
			if TOGBankClassic_Guild.pendingP2PRequests then
				local norm = TOGBankClassic_Guild:NormalizeName(altName)
				TOGBankClassic_Guild.pendingP2PRequests[norm] = nil
				
				-- Cancel 15s fallback timeout since peer confirmed no changes
				if TOGBankClassic_Guild.pendingP2PFallbackTimeouts and TOGBankClassic_Guild.pendingP2PFallbackTimeouts[norm] then
					TOGBankClassic_Guild.pendingP2PFallbackTimeouts[norm]:Cancel()
					TOGBankClassic_Guild.pendingP2PFallbackTimeouts[norm] = nil
					TOGBankClassic_Output:Debug("SYNC", "P2P: Cancelled fallback timeout for %s (no-change received)", altName)
				end
			end

			-- P2P-006: Signal session completion (no-change = sync confirmed up-to-date).
			if TOGBankClassic_P2PSession then
				TOGBankClassic_P2PSession:OnAltCompleted(altName, sender)
			end

			TOGBankClassic_Output:DebugComm("RECEIVED NO-CHANGE from %s for alt %s (version=%d)", sender, altName, version)

			self:Debug(
				"SYNC",
				">",
				ColorPlayerName(sender),
				QUERIES_COLOR,
				string.format("no changes for %s (v%d)", ColorPlayerName(altName), version)
			)

			-- HASH-CORRECTION: If the responder sends corrected hash values, apply them.
			-- This fixes stale inventoryHash/mailHash left by the pre-DELTA-025 bug
			-- (hash was blindly stamped from the delta instead of recomputed from items).
			-- The sender only reaches this no-change path if our item baseline matched
			-- their current items exactly, so their hash IS correct for our data.
			local norm = TOGBankClassic_Guild:NormalizeName(altName)
			local correctedHash = data.hash
			local correctedMailHash = data.mailHash
			if correctedHash and correctedHash ~= 0 and TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts then
				local localAlt = TOGBankClassic_Guild.Info.alts[norm]
				if localAlt then
					local oldInvHash = localAlt.inventoryHash
					local oldMailHash = localAlt.mailHash
					if oldInvHash ~= correctedHash then
						localAlt.inventoryHash = correctedHash
						TOGBankClassic_Output:Debug("SYNC", "HASH-CORRECTION: %s inventoryHash %s→%d (from %s)",
							norm, tostring(oldInvHash), correctedHash, sender)
					end
					if correctedMailHash ~= nil and oldMailHash ~= correctedMailHash then
						localAlt.mailHash = correctedMailHash
						TOGBankClassic_Output:Debug("SYNC", "HASH-CORRECTION: %s mailHash %s→%d (from %s)",
							norm, tostring(oldMailHash), correctedMailHash, sender)
					end
				end
			end

			-- Mark sync as complete
			TOGBankClassic_Guild:ConsumePendingSync("alt", sender, altName)
			if TOGBankClassic_Guild.hasRequested then
				if TOGBankClassic_Guild.requestCount == nil then
					TOGBankClassic_Guild.requestCount = 0
				else
					TOGBankClassic_Guild.requestCount = TOGBankClassic_Guild.requestCount - 1
				end
				if TOGBankClassic_Guild.requestCount == 0 then
					TOGBankClassic_Guild.hasRequested = false
					TOGBankClassic_Output:Info("Sync completed.")
				end
			end
		end
	end

	if prefix == "togbank-d" or prefix == "togbank-rm" then
		-- SYNC-003p: Debug all togbank-d messages to see what's arriving
		TOGBankClassic_Output:DebugComm("[SYNC-003p] %s received from %s: type=%s", prefix, sender, tostring(data.type))

		-- SYNC-010: Critical debug for request mutations
		if data.type == "requests-log" then
			TOGBankClassic_Output:Debug("SYNC", "MERGE", "[SYNC-010] %s requests-log received from %s, about to call ReceiveRequestMutations", prefix, sender)
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
			self:Debug(
				"SYNC",
				">",
				ColorPlayerName(sender),
				SHARES_COLOR,
				"roster data. We",
				allowed and "accept it." or "do not accept it."
			)
			-- Roster sync removed: Roster is now rebuilt locally from guild notes
		end

		if data.type == "requests-index" then
			self:Debug("REQUESTS", "RECEIVE", ">", ColorPlayerName(sender), SHARES_COLOR, "requests index. We accept it by default.")
			TOGBankClassic_Guild:ReceiveRequestsIndex(data, sender)
		end
		if data.type == "requests-by-id" then
			local status = TOGBankClassic_Guild:ReceiveRequestsById(data)
			self:Debug(
				"REQUESTS",
				">",
				ColorPlayerName(sender),
				SHARES_COLOR,
				"requests by-id data. We accept it by default.",
				FormatSyncStatus(status)
			)
		end
		if data.type == "requests-log" then
			self:Debug("REQUESTS", "RECEIVE", ">", ColorPlayerName(sender), SHARES_COLOR, "request mutations. We accept by default.")
			TOGBankClassic_Guild:ReceiveRequestMutations(data, sender)
		end

		if data.type == "alt" then
			-- only accept alt data if the sender matches the claimed alt name
			local claimed = data.name
			local claimedNorm = TOGBankClassic_Guild:NormalizeName(claimed)
			local allowed = self:IsAltDataAllowed(sender, claimedNorm)
			if TOGBankClassic_Guild:ConsumePendingSync("alt", sender, claimedNorm) then
				allowed = true
			end
			local status = allowed and TOGBankClassic_Guild:ReceiveAltData(claimedNorm, data.alt, sender)
				or ADOPTION_STATUS.UNAUTHORIZED
			self:Debug(
				"SYNC",
				">",
				ColorPlayerName(sender),
				SHARES_COLOR,
				"bank data about",
				ColorPlayerName(claimedNorm) .. ". We",
				allowed and "accept it." or "do not accept it.",
				FormatSyncStatus(status)
			)
			if allowed then
				-- ReceiveAltData already applied/rejected; refresh UI if open
				if status == ADOPTION_STATUS.ADOPTED and TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
					TOGBankClassic_UI_Inventory:DrawContent()
				end
			else
				-- ignore spoofed alt data
				return
			end
		end
	end

	-- togbank-d3: v0.8.0 Link-less full sync (same as togbank-d but without Links)
	if prefix == "togbank-d3" then
		if data.type == "alt" then
			-- only accept alt data if the sender matches the claimed alt name
			local claimed = data.name
			local claimedNorm = TOGBankClassic_Guild:NormalizeName(claimed)

			TOGBankClassic_Output:DebugComm("RECEIVED DATA: togbank-d3 from %s for alt %s (%d bytes)", sender, claimedNorm, #message)

			local allowed = self:IsAltDataAllowed(sender, claimedNorm)
			local hadPendingRequest = TOGBankClassic_Guild:ConsumePendingSync("alt", sender, claimedNorm)
			if hadPendingRequest then
				allowed = true
				TOGBankClassic_Output:Debug("PROTOCOL", "ALT-REQUEST", "[RECEIVE] Receiving %s from %s (REQUESTED - had pending sync)", claimedNorm, sender)
			else
				TOGBankClassic_Output:Debug("PROTOCOL", "ALT-REQUEST", "[RECEIVE] Receiving %s from %s (UNSOLICITED - no pending sync)", claimedNorm, sender)
			end
			local status = allowed and TOGBankClassic_Guild:ReceiveAltData(claimedNorm, data.alt, sender)
				or ADOPTION_STATUS.UNAUTHORIZED
			self:Debug(
				"SYNC",
				">",
				ColorPlayerName(sender),
				SHARES_COLOR,
				"bank data (v0.8.0 Link-less) about",
				ColorPlayerName(claimedNorm) .. ". We",
				allowed and "accept it." or "do not accept it.",
				FormatSyncStatus(status)
			)

			-- Show receive message when data arrives
			local estimatedChunks = math.ceil(#message / 254)
			if not TOGBankClassic_Options:IsSyncProgressMuted() then
				TOGBankClassic_Output:Info("Receiving guild bank data for %s: %d bytes in ~%d chunks...", claimedNorm, #message, estimatedChunks)
			end

			if allowed then
				-- Show completion message based on status
				if status == ADOPTION_STATUS.ADOPTED then
					if not TOGBankClassic_Options:IsSyncProgressMuted() then
						TOGBankClassic_Output:Info("Received complete: %s (%d bytes) - data written", claimedNorm, #message)
					end

					-- Report progress update after successful data write
					if TOGBankClassic_Guild and TOGBankClassic_Guild.ReportBankerDataProgress then
						TOGBankClassic_Guild:ReportBankerDataProgress("received " .. claimedNorm, true)
					end
				elseif status == ADOPTION_STATUS.STALE then
					if not TOGBankClassic_Options:IsSyncProgressMuted() then
						TOGBankClassic_Output:Info("Received complete: %s (%d bytes) - STALE (older than current data, discarded)", claimedNorm, #message)
					end
				elseif status == ADOPTION_STATUS.INVALID then
					if not TOGBankClassic_Options:IsSyncProgressMuted() then
						TOGBankClassic_Output:Warn("Received complete: %s (%d bytes) - INVALID (malformed data, discarded)", claimedNorm, #message)
					end
				elseif status == ADOPTION_STATUS.IGNORED then
					if not TOGBankClassic_Options:IsSyncProgressMuted() then
						TOGBankClassic_Output:Info("Received complete: %s (%d bytes) - IGNORED", claimedNorm, #message)
					end
				end

				-- ReceiveAltData already applied/rejected; refresh UI if open
				if status == ADOPTION_STATUS.ADOPTED and TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
					TOGBankClassic_UI_Inventory:DrawContent()
				end

				-- Clear P2P pending request for any response (not just ADOPTED)
				-- This prevents duplicate responses from being processed
				if TOGBankClassic_Guild.pendingP2PRequests and TOGBankClassic_Guild.pendingP2PRequests[claimedNorm] then
					TOGBankClassic_Guild.pendingP2PRequests[claimedNorm] = nil
					if status == ADOPTION_STATUS.ADOPTED then
						TOGBankClassic_Output:Info("P2P: Successfully received data for %s from peer %s (bypassed banker)", claimedNorm, sender)
					else
						TOGBankClassic_Output:Debug("SYNC", "P2P: Cleared pending request for %s (status: %s)", claimedNorm, tostring(status))
					end
				end
			else
				-- ignore spoofed alt data
				return
			end
		end
	end

	-- togbank-d4: v0.8.0 Link-less delta (future - not yet implemented)
	-- v0.8.0 Link-less delta handler (togbank-d4) - saves 60-80 bytes per item
	if prefix == "togbank-d4" then
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
						"DELTA",
						">",
						ColorPlayerName(sender),
						SHARES_COLOR,
						"delta (v0.8.0 Link-less) for",
						ColorPlayerName(claimedNorm),
						"- validation failed:",
						err
					)
					-- Record error and request full sync
					TOGBankClassic_Guild:RecordDeltaError(claimedNorm, "VALIDATION_FAILED", errorMsg)
					TOGBankClassic_Guild:QueryAlt(sender, claimedNorm, nil)
					-- Only count as failure if validation actually failed (not just missing optional fields)
					if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name then
						TOGBankClassic_Database:RecordDeltaFailed(TOGBankClassic_Guild.Info.name)
					end
					return
				end

				-- Reconstruct item links in background using batched queue system
				-- Processes 5 items every 0.1s to prevent stuttering
				if data.changes then
					if data.changes.bank then
						TOGBankClassic_Guild:ReconstructItemLinks(data.changes.bank.added)
						TOGBankClassic_Guild:ReconstructItemLinks(data.changes.bank.modified)
						TOGBankClassic_Guild:ReconstructItemLinks(data.changes.bank.removed)
					end
					if data.changes.bags then
						TOGBankClassic_Guild:ReconstructItemLinks(data.changes.bags.added)
						TOGBankClassic_Guild:ReconstructItemLinks(data.changes.bags.modified)
						TOGBankClassic_Guild:ReconstructItemLinks(data.changes.bags.removed)
					end
				end

				-- Track inbound receive metrics
				if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name then
					local isFromBanker = TOGBankClassic_Guild:IsBank(sender) or false
					TOGBankClassic_Database:RecordDeltaReceived(TOGBankClassic_Guild.Info.name, #message, isFromBanker)
				end
				local status = TOGBankClassic_Guild:ApplyDelta(claimedNorm, data, sender)
				
				-- Cancel 15s fallback timeout since peer delivered data
				local norm = TOGBankClassic_Guild:NormalizeName(claimedNorm)
				if TOGBankClassic_Guild.pendingP2PFallbackTimeouts and TOGBankClassic_Guild.pendingP2PFallbackTimeouts[norm] then
					TOGBankClassic_Guild.pendingP2PFallbackTimeouts[norm]:Cancel()
					TOGBankClassic_Guild.pendingP2PFallbackTimeouts[norm] = nil
					TOGBankClassic_Output:Debug("SYNC", "P2P: Cancelled fallback timeout for %s (data received)", claimedNorm)
				end

				-- P2P-006: Signal session completion to release the active-session slot.
				if TOGBankClassic_P2PSession then
					TOGBankClassic_P2PSession:OnAltCompleted(claimedNorm, sender)
				end

				self:Debug(
					"DELTA",
					">",
					ColorPlayerName(sender),
					SHARES_COLOR,
					"delta (v0.8.0 Link-less) for",
					ColorPlayerName(claimedNorm) .. ".",
					FormatSyncStatus(status)
				)
			else
				self:Debug(
					"DELTA",
					">",
					ColorPlayerName(sender),
					SHARES_COLOR,
					"delta (v0.8.0 Link-less) for",
					ColorPlayerName(claimedNorm) .. ". We do not accept it.",
					FormatSyncStatus(ADOPTION_STATUS.UNAUTHORIZED)
				)
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
						"DELTA",
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
					"DELTA",
					">",
					ColorPlayerName(sender),
					SHARES_COLOR,
					"delta for",
					ColorPlayerName(claimedNorm) .. ".",
					FormatSyncStatus(status)
				)
			else
				self:Debug(
					"DELTA",
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

	-- v0.9.1+: Request-specific data handler (togbank-rd)
	-- This is the dedicated prefix for request data, replacing togbank-d with type="requests*"
	if prefix == "togbank-rd" then
		TOGBankClassic_Output:DebugComm("[SYNC-003p] togbank-rd received from %s: type=%s", sender, tostring(data.type))

		if data.type == "requests-index" then
			local reqCount = data.requests and #data.requests or 0
			local tombCount = data.tombstones and #data.tombstones or 0
			self:Debug("REQUESTS", "RECEIVE", ">", ColorPlayerName(sender), SHARES_COLOR,
				string.format("requests index (%d requests, %d tombstones).", reqCount, tombCount))
			TOGBankClassic_Guild:ReceiveRequestsIndex(data, sender)
		end
		if data.type == "requests-by-id" then
			local status = TOGBankClassic_Guild:ReceiveRequestsById(data)
			self:Debug(
				"REQUESTS",
				">",
				ColorPlayerName(sender),
				SHARES_COLOR,
				"requests by-id data.",
				FormatSyncStatus(status)
			)
		end
		if data.type == "requests-log" then
			self:Debug("REQUESTS", "RECEIVE", ">", ColorPlayerName(sender), SHARES_COLOR, "request mutations.")
			TOGBankClassic_Guild:ReceiveRequestMutations(data, sender)
		end
	end

	if prefix == "togbank-h" then
		TOGBankClassic_Guild:Hello("reply")
	end
	if prefix == "togbank-hr" then
		-- hello-reply: log the text response from the remote side
		TOGBankClassic_Output:Debug("PROTOCOL", "Hello reply from %s: %s", tostring(sender), tostring(data))
	end
	if prefix == "togbank-hl" then
		if data.type == "hash-list-request" then
			local replyTarget = data.requester or sender
			TOGBankClassic_Output:Debug("PROTOCOL", "HL request from %s (replyTarget=%s)", tostring(sender), tostring(replyTarget))
			TOGBankClassic_Guild:SendHashList(replyTarget)
		elseif data.type == "hash-list-broadcast" and data.alts then
			-- PERF-020: Queue hash broadcasts for batched processing to prevent stuttering
			-- When 4+ broadcasts arrive within seconds (144 hash comparisons), synchronous
			-- processing blocks main thread causing stuttering. Batch with 0.15s delay spreads
			-- work across multiple frames while adding negligible latency (0.25% of 60s collect window).
			local isSenderBanker = data.isBanker or false
			local altCount = 0
			for _ in pairs(data.alts) do altCount = altCount + 1 end
			TOGBankClassic_Output:Debug("P2P", "HL broadcast from %s (alts=%d, isBanker=%s)",
				tostring(sender), altCount, tostring(isSenderBanker))

			-- Track addon version from hash-list-broadcast (version tracking channel)
			if data.addon then
				if not self.guild_versions then self.guild_versions = {} end
				self.guild_versions[sender] = {
					version = data.addon,
					seen    = time(),
				}
			end
			
			-- Queue this broadcast for batched processing
			table.insert(self.hashBroadcastQueue, {
				sender = sender,
				data = data,
				distribution = distribution,
				isSenderBanker = isSenderBanker,
				altCount = altCount,
			})
			
			-- Start batch timer if not already running
			if not self.hashBroadcastTimer then
				self.hashBroadcastTimer = C_Timer.After(self.HASH_BROADCAST_BATCH_DELAY, function()
					TOGBankClassic_Chat:ProcessQueuedHashBroadcasts()
				end)
				TOGBankClassic_Output:Debug("P2P", "OFFER", "Started batch timer (%ds) for hash broadcasts", self.HASH_BROADCAST_BATCH_DELAY)
			end
			return
		elseif data.type == "hash-offer" and data.alts then
			-- P2P-006: A peer is signalling it has newer data for some of our alts.
			-- Feed into the session manager collect window so Dispatch() can pick it up.
			if TOGBankClassic_P2PSession then
				TOGBankClassic_P2PSession:OnOffer(sender, data.alts)
			end
			return
		elseif data.type == "alt-request" then
			-- PERF-006: P2P broadcast on togbank-hl channel (modern code only)
			-- Process exactly the same as togbank-r alt-request, but only modern peers see this
			TOGBankClassic_Output:Debug("PROTOCOL", "P2P alt-request from %s for %s (expectedHash=%s)",
				tostring(sender), tostring(data.name), tostring(data.expectedHash))
			-- Forward to togbank-r handler by recursively calling OnCommReceived
			self:OnCommReceived("togbank-r", message, distribution, sender)
			return
		-- SYNC-013: share/wipe/roster migrated from dead prefixes onto togbank-hl type dispatch
		elseif data.type == "share-request" then
			-- PERF-021: Defer share replies during zone-in cooldown
			if TOGBankClassic_Events.zoningCooldown then
				TOGBankClassic_Output:Debug("PERF", "Share reply deferred (zone-in cooldown active)")
				return
			end
			TOGBankClassic_Guild:Share("reply")
			local now = GetServerTime()
			if not self.last_share_sync or now - self.last_share_sync > 30 then
				self.last_share_sync = now
			end
		elseif data.type == "wipe-command" then
			TOGBankClassic_Guild:Wipe("reply")
		elseif data.type == "roster-broadcast" then
			if data.roster then
				TOGBankClassic_Guild:ReceiveRosterData(sender, data.roster)
			end
		end
	end
	if prefix == "togbank-hlr" then
		if data.type == "hash-list-reply" and data.alts then
			local altCount = 0
			for _ in pairs(data.alts) do
				altCount = altCount + 1
			end
			TOGBankClassic_Output:Debug("PROTOCOL", "HLR-COMPARE", "HLR received from %s (alts=%d)", tostring(sender), altCount)
			-- Update cache incrementally to support both full replies and partial broadcasts
			if not TOGBankClassic_Guild.latestBankerHashes then
				TOGBankClassic_Guild.latestBankerHashes = {}
			end
			for altName, summary in pairs(data.alts) do
				local norm = TOGBankClassic_Guild:NormalizeName(altName)
				if norm and summary then
					TOGBankClassic_Guild.latestBankerHashes[norm] = summary
				end
			end
			local localAlts = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts or {}
			local pending = {}
			local missingContent = {}
			local totalCount = 0

			-- First pass: Store banker's authoritative hashes locally if we don't have them
			if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts then
				for altName, summary in pairs(data.alts) do
					local norm = TOGBankClassic_Guild:NormalizeName(altName)
					local localAlt = localAlts[norm]
					local localHash = localAlt and localAlt.inventoryHash or 0

					if summary and summary.hash and summary.hash > 0 then
						if not localAlt and data.isBanker then
							-- Create stub entry with banker's authoritative hash (only trusted banker broadcasts)
							TOGBankClassic_Guild.Info.alts[norm] = {
								name = norm,
								version = summary.version or 0,
								money = 0,
								inventoryHash = summary.hash,
								inventoryUpdatedAt = summary.updatedAt,
								items = {},
								mail = { items = {}, slots = { count = 0, total = 0 }, lastScan = 0, version = 0 },
								mailHash = summary.mailHash or 0,
							}
							TOGBankClassic_Guild:EnsureLegacyFields(TOGBankClassic_Guild.Info.alts[norm])
							TOGBankClassic_Output:Debug("PROTOCOL", "HLR: Stored banker hash for new alt %s: hash=%08x, mailHash=%08x, updatedAt=%s", norm, summary.hash, summary.mailHash or 0, tostring(summary.updatedAt))
						elseif localHash ~= summary.hash or (localAlt.mailHash or 0) ~= (summary.mailHash or 0) then
							-- Hash mismatch detected - banker has different hash than our local data
							-- DO NOT update local hash here - it will be updated when we receive and apply the delta
							-- Second pass will detect this mismatch and trigger a delta sync request
							TOGBankClassic_Output:Debug("PROTOCOL", "HLR-COMPARE", "HLR: Hash mismatch detected for %s - local inv=%d/mail=%d vs banker inv=%d/mail=%d (delta sync needed)",
								norm, localHash, localAlt.mailHash or 0, summary.hash, summary.mailHash or 0)
						end
					end
				end
			-- Refresh localAlts reference after potentially creating new entries
			localAlts = TOGBankClassic_Guild.Info.alts
		end

		-- Second pass: Compare hashes and categorize alts
		local currentPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()
		for altName, summary in pairs(data.alts) do
				local norm = TOGBankClassic_Guild:NormalizeName(altName)
				
				-- Skip current player (can't request your own data)
				if norm ~= currentPlayer then
					local localAlt = localAlts and localAlts[norm]
					local localHash = localAlt and localAlt.inventoryHash or 0
					local localMailHash = localAlt and localAlt.mailHash or 0
					local hasContent = localAlt and TOGBankClassic_Guild and TOGBankClassic_Guild.HasAltContent
						and TOGBankClassic_Guild:HasAltContent(localAlt, norm)
					-- DEBUG: Log every alt to see what's happening
					TOGBankClassic_Output:Debug("PROTOCOL", "HLR check: %s hasContent=%s localHash=%s bankerHash=%s localMailHash=%s bankerMailHash=%s",
						tostring(norm), tostring(hasContent), tostring(localHash), tostring(summary and summary.hash), tostring(localMailHash), tostring(summary and summary.mailHash))
					totalCount = totalCount + 1

					-- SYNC-009: Check if hashes match BEFORE skipping (non-banker sync bug fix)
					-- Previously, we skipped any alt with hasContent=true without checking hashes.
					-- This broke non-banker sync: if we had OLD content for a non-banker alt,
					-- we'd skip it even when the banker had a different (newer) hash.
					-- Now we only skip if BOTH hasContent AND hashes match.
					-- BUGFIX: Hash=0 should NOT be treated as a wildcard match - it means "empty inventory"
					-- and should only match another hash=0, not any hash value.
					local inventoryHashMatches = (summary.hash ~= nil and summary.hash == localHash)
					local mailHashMatches = (summary.mailHash ~= nil and summary.mailHash == localMailHash)
					local hashesMatch = inventoryHashMatches and mailHashMatches
					
					-- Skip alts we already have content for AND hashes match - no need to request
					if hasContent and hashesMatch then
						TOGBankClassic_Output:Debug("PROTOCOL", "HLR-COMPARE",
							"HLR: Skipping %s (have content + hashes match: local inv=%d/mail=%d, banker inv=%d/mail=%d)",
							tostring(norm),
							tostring(localHash),
							tostring(localMailHash),
							tostring(summary and summary.hash),
							tostring(summary and summary.mailHash)
						)
					elseif not localAlt or localHash == 0 or (summary.hash and summary.hash ~= localHash) or (summary.mailHash and summary.mailHash ~= localMailHash) then
						pending[norm] = summary
						local reason = (not localAlt or localHash == 0) and "no data" or ((summary.hash and summary.hash ~= localHash) and "inventory mismatch" or "mail mismatch")
						TOGBankClassic_Output:Debug("PROTOCOL", "HLR-COMPARE",
							"HLR: Adding %s to pending (%s: local inv=%d/mail=%d, banker inv=%d/mail=%d)",
							tostring(norm),
							reason,
							tostring(localHash),
							tostring(localMailHash),
							tostring(summary and summary.hash),
							tostring(summary and summary.mailHash)
						)
					else
						-- Hash matches but no content - request it
						missingContent[norm] = summary
						TOGBankClassic_Output:Debug(
							"PROTOCOL",
							"HLR missing content: %s (localHash=%s matches bankerHash=%s)",
							tostring(norm),
							tostring(localHash),
							tostring(summary and summary.hash)
						)
					end
				else
					TOGBankClassic_Output:Debug("PROTOCOL", "HLR: Skipping %s (current player)", tostring(norm))
				end
			end

			local pendingCount = 0
			for _ in pairs(pending) do
				pendingCount = pendingCount + 1
			end
			TOGBankClassic_Output:Debug(
				"PROTOCOL",
				"HLR compare complete: total=%d pending=%d",
				totalCount,
				pendingCount
			)
			local missingCount = 0
			for _ in pairs(missingContent) do
				missingCount = missingCount + 1
			end
			if pendingCount > 0 then
				local haveCount, totalCount = TOGBankClassic_Guild:GetBankerDataProgress()
				TOGBankClassic_Output:Debug("DELTA", "FAST-FILL", "Fast-fill: Requesting %d missing alts (have %d/%d)", pendingCount, haveCount, totalCount)
				TOGBankClassic_Guild:ReportBankerDataProgress("fast-fill", true)
			end
			if missingCount > 0 then
				if not (TOGBankClassic_Options and TOGBankClassic_Options.IsSyncProgressMuted and TOGBankClassic_Options:IsSyncProgressMuted()) then
					TOGBankClassic_Output:Info("Fast-fill: Re-requesting %d alts with hash but no content", missingCount)
				end
			end

			for altName, summary in pairs(pending) do
				TOGBankClassic_Output:Debug(
					"PROTOCOL",
					"HLR broadcast pending: %s (hash=%s, updatedAt=%s)",
					tostring(altName),
					tostring(summary and summary.hash),
					tostring(summary and summary.updatedAt)
				)
				TOGBankClassic_Guild:BroadcastP2PRequest(altName, summary.hash, summary.updatedAt, sender)
			end
			for altName, summary in pairs(missingContent) do
				TOGBankClassic_Output:Debug(
					"PROTOCOL",
					"HLR broadcast missingContent: %s (hash=%s, updatedAt=%s)",
					tostring(altName),
					tostring(summary and summary.hash),
					tostring(summary and summary.updatedAt)
				)
				if summary and summary.hash then
					TOGBankClassic_Guild:BroadcastP2PRequest(altName, summary.hash, summary.updatedAt, sender)
				else
					TOGBankClassic_Output:Debug(
						"PROTOCOL",
						"HLR missingContent no hash: %s - querying banker directly",
						tostring(altName)
					)
					TOGBankClassic_Guild:QueryAltPullBased(altName, false)
				end
			end
		end
	end
	-- togbank-s and togbank-w handlers removed: migrated to togbank-hl type dispatch (SYNC-013)
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
			TOGBankClassic_Chat:PerformSync()
		end,
	},
	{
		name = "share",
		help = "manually share the contents of your guild bank with other online users of TOGBankClassic; this is done every 3 minutes automatically",
		handler = function()
			-- PERF-021: Warn user if zone-in cooldown is active
			if TOGBankClassic_Events.zoningCooldown then
				TOGBankClassic_Output:Response("Zone-in cooldown active, deferring share for 2.5s...")
				C_Timer.After(2.6, function()
					TOGBankClassic_Bank:OnUpdateStart()
					TOGBankClassic_Bank:OnUpdateStop()
					TOGBankClassic_Guild:Share()
				end)
				return
			end
			TOGBankClassic_Bank:OnUpdateStart()
			TOGBankClassic_Bank:OnUpdateStop()
			TOGBankClassic_Guild:Share()
		end,
	},
	{
		name = "hashupdate",
		help = "(banker only) broadcast hash-list for ALL bank alts to force guild-wide hash refresh",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:HashUpdate()
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
	-- Expert commands (alphabetically sorted)
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
		name = "compact",
		help = "manually run compaction to prune old requests and tombstones",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:Compact()
		end,
	},
	{
		name = "reqscan",
		help = "scan done requests and report why expired ones are not being pruned",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:ReqScan()
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
		name = "clear-delta-errors",
		help = "clear all recorded delta sync errors (DELTA-011 cleanup)",
		expert = true,
		handler = function()
			local guild = TOGBankClassic_Guild:GetGuild()
			if not guild then
				TOGBankClassic_Output:Response("Not in a guild")
				return
			end

			local db = TOGBankClassic_Database.db.faction[guild]
			if db and db.deltaErrors then
				db.deltaErrors.lastErrors = {}
				db.deltaErrors.failureCounts = {}
				db.deltaErrors.notifiedAlts = {}
				TOGBankClassic_Output:Response("Cleared all delta sync errors")
			else
				TOGBankClassic_Output:Response("No delta errors to clear")
			end
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
		name = "deltastats",
		help = "show delta sync statistics and bandwidth savings",
		expert = true,
		handler = function()
			TOGBankClassic_Chat:PrintDeltaStats()
		end,
	},
	{
		name = "debuglog",
		usage = "[N] [filter]",
		help = "export last N debug log entries (default 500), optionally filtered by keyword",
		expert = true,
		handler = function(arg1)
			local args = tostring(arg1 or ""):trim()
			local count, filter = 500, nil

			-- Parse arguments: first is count, rest is filter
			if args ~= "" then
				local firstSpace = args:find(" ")
				if firstSpace then
					count = tonumber(args:sub(1, firstSpace - 1)) or 500
					filter = args:sub(firstSpace + 1):trim()
					if filter == "" then filter = nil end
				else
					count = tonumber(args) or 500
				end
			end

			local log, matchCount = TOGBankClassic_Output:ExportPersistentLogCompact(count, filter)
			if log == "" then
				TOGBankClassic_Output:Response("No debug log entries found")
			else
				if filter then
					TOGBankClassic_Output:Response("Last %d debug log entries (filtered: '%s', %d matches):", count, filter, matchCount)
				else
					TOGBankClassic_Output:Response("Last %d debug log entries:", count)
				end
				TOGBankClassic_Output:Response(log)
			end
		end,
	},
	{
		name = "debuglogclear",
		help = "clear all persistent debug log entries",
		expert = true,
		handler = function()
			TOGBankClassic_Output:ClearPersistentLog()
			TOGBankClassic_Output:Response("Debug log cleared")
		end,
	},
	{
		name = "debuglogsave",
		help = "manually save debug log to SavedVariables (normally done on logout)",
		expert = true,
		handler = function()
			TOGBankClassic_Output:SavePersistentLog()
			TOGBankClassic_Output:Response("Persistent debug log saved")
		end,
	},
	{
		name = "debuglogstats",
		help = "show statistics about the persistent debug log",
		expert = true,
		handler = function()
			local count = #TOGBankClassic_Output.persistentLog
			if count == 0 then
				TOGBankClassic_Output:Response("No debug log entries")
				return
			end

			local oldest = TOGBankClassic_Output.persistentLog[1]
			local newest = TOGBankClassic_Output.persistentLog[count]
			local oldestTime = date("%Y-%m-%d %H:%M:%S", oldest.timestamp)
			local newestTime = date("%Y-%m-%d %H:%M:%S", newest.timestamp)
			local ageSeconds = newest.timestamp - oldest.timestamp
			local ageDays = ageSeconds / 86400

			TOGBankClassic_Output:Response("Debug log: %d entries", count)
			TOGBankClassic_Output:Response("Oldest: %s", oldestTime)
			TOGBankClassic_Output:Response("Newest: %s", newestTime)
			TOGBankClassic_Output:Response("Span: %.1f days", ageDays)
			TOGBankClassic_Output:Response("Max entries: %d", TOGBankClassic_Output.persistentLogMaxEntries)
			TOGBankClassic_Output:Response("Max age: %d days", TOGBankClassic_Output.persistentLogMaxAge / 86400)
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
		name = "hello",
		help = "understand which online guild members use which addon version and know what guild bank data; needs corresponding weakaura to print deserialized addon communication",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:Hello()
		end,
	},
	{
		name = "perfstats",
		help = "show performance metrics for current session",
		expert = true,
		handler = function()
			TOGBankClassic_Performance:PrintReport()
		end,
	},
	{
		name = "persistcheck",
		help = "check current request persistence state (for debugging SYNC-001)",
		expert = true,
		handler = function()
			local G = TOGBankClassic_Guild
			if not G or not G.Info then
				TOGBankClassic_Output:Response("Guild info not loaded")
				return
			end

			local logCount = #(G.Info.requestLog or {})
			local appliedCount = 0
			local appliedActors = {}
			if G.Info.requestLogApplied then
				for actor, seq in pairs(G.Info.requestLogApplied) do
					appliedCount = appliedCount + 1
					table.insert(appliedActors, string.format("%s=%d", actor, seq))
				end
			end
			local requestCount = (function()
				local n = 0
				for _ in pairs(G.Info.requests or {}) do n = n + 1 end
				return n
			end)()
			local seqCount = 0
			if G.Info.requestLogSeq then
				for _ in pairs(G.Info.requestLogSeq) do
					seqCount = seqCount + 1
				end
			end

			TOGBankClassic_Output:Response("=== Request Persistence State ===")
			TOGBankClassic_Output:Response("requests: %d items", requestCount)
			TOGBankClassic_Output:Response("requestLog: %d entries", logCount)
			TOGBankClassic_Output:Response("requestLogApplied: %d actors", appliedCount)
			if appliedCount > 0 then
				TOGBankClassic_Output:Response("  %s", table.concat(appliedActors, ", "))
			end
			TOGBankClassic_Output:Response("requestLogSeq: %d actors", seqCount)

			-- Check if data is referencing SavedVariables
			local db = TOGBankClassic_Database and TOGBankClassic_Database.db
			if db and db.faction then
				local guildName = G:GetGuild()
				if guildName and db.faction[guildName] then
					local isSameRef = (G.Info == db.faction[guildName])
					TOGBankClassic_Output:Response("Guild.Info %s SavedVariables reference",
						isSameRef and "IS" or "IS NOT")
				end
			end
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
		name = "roster",
		help = "guild banks and members that can read the officer note can use this command to share updated roster data with online guild members",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:AuthorRosterData()
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
		name = "versions",
		help = "show addon versions of online guild members",
		expert = true,
		handler = function()
			TOGBankClassic_Chat:PrintVersions()
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
	{
		name = "wipeframes",
		help = "reset all saved window positions to default",
		expert = true,
		handler = function()
			if TOGBankClassic_Options and TOGBankClassic_Options.db and TOGBankClassic_Options.db.char then
				local count = 0
				for _ in pairs(TOGBankClassic_Options.db.char.framePositions or {}) do
					count = count + 1
				end
				TOGBankClassic_Options.db.char.framePositions = {}
				TOGBankClassic_Output:Response("Cleared %d saved window position(s). Type /reload to reset window positions.", count)
			else
				TOGBankClassic_Output:Response("No frame positions to clear")
			end
		end,
	},
	{
		name = "netq",
		help = "show a breakdown of the ChatThrottleLib outbound queue by message type and recipient",
		expert = true,
		handler = function()
			local ctl = _G.ChatThrottleLib
			if not ctl or not ctl.Prio then
				TOGBankClassic_Output:Response("ChatThrottleLib not available.")
				return
			end

			-- Tally messages by "prefix/chattype/target" bucket
			local buckets = {}
			local grandTotal = 0

			local function walkRing(ring, prioName)
				if not ring or not ring.pos then return end
				local pipe = ring.pos
				repeat
					for i = 1, #pipe do
						local msg = pipe[i]
						local prefix   = tostring(msg[1] or "?")
						local chattype = tostring(msg[3] or "?")
						local target   = msg[4] and tostring(msg[4]) or nil
						local desc = COMM_PREFIX_DESCRIPTIONS[prefix]
						local prefixLabel = desc and (prefix .. " " .. desc) or prefix
						local key = target and (prefixLabel .. " -> " .. chattype .. "/" .. target)
						              or (prefixLabel .. " -> " .. chattype)
						buckets[key] = (buckets[key] or 0) + 1
						grandTotal = grandTotal + 1
					end
					pipe = pipe.next
				until pipe == ring.pos
			end

			for prioName, prio in pairs(ctl.Prio) do
				walkRing(prio.Ring,    prioName)
				walkRing(prio.Blocked, prioName)
			end

			if grandTotal == 0 then
				TOGBankClassic_Output:Response("ChatThrottleLib queue is empty.")
				return
			end

			-- Sort buckets by count descending
			local sorted = {}
			for key, count in pairs(buckets) do
				table.insert(sorted, { key = key, count = count })
			end
			table.sort(sorted, function(a, b) return a.count > b.count end)

			TOGBankClassic_Output:Response("ChatThrottleLib queue: %d msgs total", grandTotal)
			for _, entry in ipairs(sorted) do
				local pct = math.floor(entry.count / grandTotal * 100 + 0.5)
				TOGBankClassic_Output:Response("  %s: %d (%d%%)", entry.key, entry.count, pct)
			end
		end,
	},
	-- Hidden commands (no help text)
	{
		name = "debug",
		handler = function()
			local currentLevel = TOGBankClassic_Output:GetLevel()
			if currentLevel == LOG_LEVEL.DEBUG then
				-- Restore to pre-debug level
				local restoreLevel = preDebugLogLevel or LOG_LEVEL.INFO
				preDebugLogLevel = nil
				TOGBankClassic_Output:SetLevel(restoreLevel)
				TOGBankClassic_Options.db.global.bank["logLevel"] = restoreLevel

				-- Get level name for response message
				local levelName = "Info"
				if restoreLevel == LOG_LEVEL.RESPONSE then levelName = "Quiet"
				elseif restoreLevel == LOG_LEVEL.ERROR then levelName = "Error"
				elseif restoreLevel == LOG_LEVEL.WARN then levelName = "Warn"
				end
				TOGBankClassic_Output:Response("Debug: off (log level: " .. levelName .. ")")
			else
				-- Save current level before entering debug mode
				preDebugLogLevel = TOGBankClassic_Options.db.global.bank["logLevel"]
				TOGBankClassic_Output:SetLevel(LOG_LEVEL.DEBUG)
				TOGBankClassic_Options.db.global.bank["logLevel"] = LOG_LEVEL.DEBUG
				TOGBankClassic_Output:Response("Debug: on (log level: Debug)")
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
	{
		name = "hashdebug",
		help = "show hash-list coverage and missing alts",
		expert = true,
		handler = function()
			if TOGBankClassic_Guild and TOGBankClassic_Guild.ReportHashListCoverage then
				TOGBankClassic_Guild:ReportHashListCoverage()
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
	local startTime = debugprofilestop()

	local time = GetServerTime()

	local name = table.remove(self.sync_queue)
	if not self.last_alt_sync[name] or time - self.last_alt_sync[name] > 180 then
		self.last_alt_sync[name] = time
		-- DELTA-014: Broadcast mode - no specific requester, use empty baseline (0,0)
		-- This sends full delta to everyone
		TOGBankClassic_Guild:SendAltData(name, 0, 0)
	end
	local duration = debugprofilestop() - startTime
	TOGBankClassic_Output:Debug("EVENTS", "ProcessQueue took %.2fms (name=%s, queue=%d)", duration, tostring(name), #self.sync_queue)

	if #self.sync_queue > 0 then
		TOGBankClassic_Chat:ReprocessQueue()
	end
end

function TOGBankClassic_Chat:ReprocessQueue()
	if self.reprocessTimer then
		return
	end
	self.reprocessTimer = TOGBankClassic_Core:ScheduleTimer(function(...)
		TOGBankClassic_Chat.reprocessTimer = nil
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
				age = string.format(" (%dm ago)", math.floor(seconds / 60))
			else
				age = string.format(" (%dh ago)", math.floor(seconds / 3600))
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

	-- Outbound: what this client served to others
	local sentCount = metrics.deltasSentCount or 0
	local sentBytes = metrics.bytesSentDelta or 0
	local p2pSent = metrics.p2pSentCount or 0
	local p2pOffered = metrics.p2pOffered or 0
	local noChangeSent = metrics.noChangeSentCount or 0
	TOGBankClassic_Output:Response("|cffffff00Outbound (what I served):|r")
	if sentCount > 0 then
		local avgBytes = sentBytes / sentCount
		local bytesSaved = metrics.bytesSavedByDelta or 0
		TOGBankClassic_Output:Response("  Data sends:        %d sends, %s (avg %s/send)",
			sentCount, formatBytes(sentBytes), formatBytes(avgBytes))
		TOGBankClassic_Output:Response("  Bandwidth saved:   %s vs full sync (%.0f%% reduction)",
			formatBytes(bytesSaved), bytesSaved / (sentBytes + bytesSaved) * 100)
		if p2pSent > 0 then
			TOGBankClassic_Output:Response("  Of which P2P:      %d sends (%.0f%%)",
				p2pSent, (p2pSent / sentCount) * 100)
		else
			TOGBankClassic_Output:Response("  Of which P2P:      0 (all sent in banker role)")
		end
	else
		TOGBankClassic_Output:Response("  Data sends:        0 (no data served yet)")
	end
	if p2pOffered > 0 then
		local converted = p2pSent
		TOGBankClassic_Output:Response("  P2P offered/sent:  %d offered, %d sent (%.0f%% resulted in data)",
			p2pOffered, converted, (converted / p2pOffered) * 100)
	end
	TOGBankClassic_Output:Response("  No-change replies: %d", noChangeSent)
	TOGBankClassic_Output:Response("")

	-- Inbound: what this client received from others
	local bytesReceived = metrics.bytesReceived or 0
	local fromBanker = metrics.deltasReceivedFromBanker or 0
	local fromPeer = metrics.deltasReceivedFromPeer or 0
	local totalReceived = fromBanker + fromPeer
	TOGBankClassic_Output:Response("|cffffff00Inbound (what I received):|r")
	if totalReceived > 0 then
		TOGBankClassic_Output:Response("  Received:          %d deltas, %s", totalReceived, formatBytes(bytesReceived))
		TOGBankClassic_Output:Response("  From banker:       %d (%.0f%%)", fromBanker, (fromBanker / totalReceived) * 100)
		TOGBankClassic_Output:Response("  From peers:        %d (%.0f%%)", fromPeer, (fromPeer / totalReceived) * 100)
	else
		TOGBankClassic_Output:Response("  Received:          0 deltas")
	end
	TOGBankClassic_Output:Response("")

	-- P2P requests: what this client asked peers for
	local p2pBroadcast = metrics.p2pRequestsBroadcast or 0
	local p2pFulfilled = metrics.p2pFulfilledByPeer or 0
	local p2pFallback = metrics.p2pBankerFallback or 0
	TOGBankClassic_Output:Response("|cffffff00P2P Requests (what I asked peers for):|r")
	if p2pBroadcast > 0 then
		local p2pUnresolved = math.max(0, p2pBroadcast - p2pFulfilled - p2pFallback)
		TOGBankClassic_Output:Response("  Broadcast:           %d", p2pBroadcast)
		TOGBankClassic_Output:Response("  Peer responded:      %d (%.0f%%)",
			p2pFulfilled, (p2pFulfilled / p2pBroadcast) * 100)
		TOGBankClassic_Output:Response("  Fell back to banker: %d (%.0f%%)",
			p2pFallback, (p2pFallback / p2pBroadcast) * 100)
		if p2pUnresolved > 0 then
			TOGBankClassic_Output:Response("  Still pending:       %d", p2pUnresolved)
		end
	else
		TOGBankClassic_Output:Response("  No P2P requests broadcast yet")
	end
	TOGBankClassic_Output:Response("")

	-- Protocol health
	local deltasApplied = metrics.deltasApplied or 0
	local deltasFailed = metrics.deltasFailed or 0
	local fullSyncFallbacks = metrics.fullSyncFallbacks or 0
	local totalOps = deltasApplied + deltasFailed
	TOGBankClassic_Output:Response("|cffffff00Protocol Health:|r")
	TOGBankClassic_Output:Response("  Deltas applied:      %d", deltasApplied)
	TOGBankClassic_Output:Response("  Deltas failed:       %d", deltasFailed)
	TOGBankClassic_Output:Response("  Full sync fallbacks: %d", fullSyncFallbacks)
	if totalOps > 0 then
		local successRate = (deltasApplied / totalOps) * 100
		local rateColor = "|cff00ff00"
		if successRate < 95 then rateColor = "|cffffff00" end
		if successRate < 80 then rateColor = "|cffff0000" end
		TOGBankClassic_Output:Response("  Success rate:        %s%.1f%%|r", rateColor, successRate)
	end

	-- Performance (only show if populated)
	local computeCount = metrics.computeCount or 0
	local applyCount = metrics.applyCount or 0
	if computeCount > 0 or applyCount > 0 then
		TOGBankClassic_Output:Response("")
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

	if sentCount == 0 and totalReceived == 0 and p2pBroadcast == 0 then
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
