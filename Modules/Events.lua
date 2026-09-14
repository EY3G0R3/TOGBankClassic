TOGBankClassic_Events = {}

-- NS-001: aliased as file-scope locals so a foreign global of the same name cannot be read
-- instead. See the header of Modules/Constants.lua.
local TIMER_INTERVALS = TOGBankClassic_Constants.TIMER_INTERVALS

function TOGBankClassic_Events:RegisterMessage(message, callback)
	if not callback then
		callback = message
	end
	TOGBankClassic_Core:RegisterMessage(message, callback)
end

function TOGBankClassic_Events:SendMessage(message, ...)
	TOGBankClassic_Core:SendMessage(message, ...)
end
function TOGBankClassic_Events:UnregisterMessage(message)
	TOGBankClassic_Core:UnregisterMessage(message)
end

function TOGBankClassic_Events:RegisterEvent(event, callback)
	if not callback then
		callback = event
	end
	TOGBankClassic_Core:RegisterEvent(event, function(...)
		self[callback](self, ...)
	end)
end

function TOGBankClassic_Events:UnregisterEvent(...)
	TOGBankClassic_Core:UnregisterEvent(...)
end

function TOGBankClassic_Events:RegisterEvents()
	if TOGBankClassic_Bank.eventsRegistered then
		return
	end

	self:RegisterEvent("PLAYER_LOGIN")
	self:RegisterEvent("PLAYER_LOGOUT")
	self:RegisterEvent("PLAYER_CAMPING")
	self:RegisterEvent("GUILD_RANKS_UPDATE")
	self:RegisterEvent("BANKFRAME_OPENED")
	self:RegisterEvent("BANKFRAME_CLOSED")
	self:RegisterEvent("MAIL_SHOW")
	self:RegisterEvent("MAIL_INBOX_UPDATE")
	self:RegisterEvent("MAIL_CLOSED")
	self:RegisterEvent("MAIL_SEND_SUCCESS")
	self:RegisterEvent("UI_ERROR_MESSAGE")
	self:RegisterEvent("GUILD_ROSTER_UPDATE")
	self:RegisterEvent("CHAT_MSG_SYSTEM")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("TRADE_SHOW")
	self:RegisterEvent("TRADE_CLOSED")
	self:RegisterEvent("AUCTION_HOUSE_SHOW")
	self:RegisterEvent("AUCTION_HOUSE_CLOSED")
	self:RegisterEvent("MERCHANT_SHOW")
	self:RegisterEvent("MERCHANT_CLOSED")
	self:RegisterEvent("PLAYER_REGEN_DISABLED")
	hooksecurefunc("ChatEdit_InsertLink", function(link)
		TOGBankClassic_UI:OnInsertLink(link)
	end)

	-- Filter out "No player named X is currently playing" and "Player not found" errors from chat
	-- These are detected and handled by CHAT_MSG_SYSTEM event handler
	-- Use fast plain-text check before pattern matching for performance
	ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, message)
		if message then
			-- Check for Classic Era pattern
			if message:find("No player named ", 1, true) then
				-- Only do pattern match if we found the error prefix
				if message:match("^No player named .+ is currently playing%.$") then
					return true  -- Suppress this message
				end
			end
			-- Check for alternate "Player not found" pattern
			if message:find("Player not found", 1, true) then
				return true  -- Suppress this message too
			end
		end
		return false
	end)

	-- Hook MailFrame visibility changes directly for more reliable detection
	-- THREE MARKER SPELLINGS EXIST AND EACH BELONGS TO A DIFFERENT HOOK. `togBankHooked` here
	-- and on MailFrameTab2; `TOGBankHooked` on MailFrame further down for a separate hook;
	-- `togbankHooked` in Modules/Output.lua for the debug frame. Every set/check pair is
	-- internally consistent, so nothing is broken today -- but MailFrame carries TWO of them,
	-- and reusing the wrong one for a third hook would either skip the hook or install it twice,
	-- silently. Match the spelling to the hook you are guarding, do not pick the nearest one.
	if MailFrame and not MailFrame.togBankHooked then
		MailFrame.togBankHooked = true
		MailFrame:HookScript("OnShow", function()
			TOGBankClassic_Mail.isOpen = true
			C_Timer.After(0.1, function()
				if TOGBankClassic_UI_Requests.isOpen then
					local actor = TOGBankClassic_Guild:GetNormalizedPlayer()
					local isActorBank = actor and TOGBankClassic_Guild:IsBank(actor) or false
					TOGBankClassic_UI_Requests:_RefreshFulfillButtons(actor, isActorBank, true)
				end
			end)
		end)
		MailFrame:HookScript("OnHide", function()
			TOGBankClassic_Mail.isOpen = false
			C_Timer.After(0.1, function()
				if TOGBankClassic_UI_Requests.isOpen then
					local actor = TOGBankClassic_Guild:GetNormalizedPlayer()
					local isActorBank = actor and TOGBankClassic_Guild:IsBank(actor) or false
					TOGBankClassic_UI_Requests:_RefreshFulfillButtons(actor, isActorBank, false)
				end
			end)
		end)
	end

	-- Hook Send Mail tab to auto-open the requests for bank alts (like BulkMail).
	-- BROWSE-005 (the operator, 2026-09-12: "when filling orders, it should just pop up the full new
	-- UI and go to the requests tab"): this is the Guild Bank window on its Requests tab, not the
	-- standalone Requests window. Browse:Open re-selects the tab without rebuilding a body that is
	-- already showing (Peer Review F4), so a body that was up is redrawn here for the fulfil icons
	-- the open mailbox changes -- exactly what the old `isOpen -> DrawContent` branch did.
	if MailFrameTab2 and not MailFrameTab2.togBankHooked then
		MailFrameTab2.togBankHooked = true
		MailFrameTab2:HookScript("OnClick", function()
			local player = TOGBankClassic_Guild:GetNormalizedPlayer()
			if player and TOGBankClassic_Guild:IsBank(player) then
				C_Timer.After(0.1, function()
					local Requests, Browse = TOGBankClassic_UI_Requests, TOGBankClassic_UI_Browse
					local wasEmbedded = Requests.isOpen and Requests.embedded
					if Browse and Browse.Open then
						Browse:Open("requests")
						if wasEmbedded then Requests:DrawContent() end
					elseif Requests.isOpen then
						Requests:DrawContent()
					else
						Requests:Open()
					end
				end)
			end
		end)
	end

	self:SetShareTimer()
	TOGBankClassic_Bank.eventsRegistered = true
end

function TOGBankClassic_Events:UnregisterEvents()
	if not TOGBankClassic_Bank.eventsRegistered then
		return
	end
	TOGBankClassic_Bank.eventsRegistered = false

	-- EVENT-002: these three were registered and never unregistered, so after OnDisable the
	-- addon kept handling them -- still paying the roster-update cost and still running its
	-- logout handler for a user who had switched it off. The register and unregister sets must
	-- stay symmetric; a spec now asserts that rather than leaving it to review.
	self:UnregisterEvent("PLAYER_LOGIN")
	self:UnregisterEvent("PLAYER_LOGOUT")
	self:UnregisterEvent("PLAYER_CAMPING")
	self:UnregisterEvent("GUILD_ROSTER_UPDATE")
	self:UnregisterEvent("PLAYER_ENTERING_WORLD")
	self:UnregisterEvent("GUILD_RANKS_UPDATE")
	self:UnregisterEvent("BANKFRAME_OPENED")
	self:UnregisterEvent("BANKFRAME_CLOSED")
	self:UnregisterEvent("MAIL_SHOW")
	self:UnregisterEvent("MAIL_INBOX_UPDATE")
	self:UnregisterEvent("MAIL_CLOSED")
	self:UnregisterEvent("MAIL_SEND_SUCCESS")
	self:UnregisterEvent("UI_ERROR_MESSAGE")
	self:UnregisterEvent("CHAT_MSG_SYSTEM")
	self:UnregisterEvent("TRADE_SHOW")
	self:UnregisterEvent("TRADE_CLOSED")
	self:UnregisterEvent("AUCTION_HOUSE_SHOW")
	self:UnregisterEvent("AUCTION_HOUSE_CLOSED")
	self:UnregisterEvent("MERCHANT_SHOW")
	self:UnregisterEvent("MERCHANT_CLOSED")
	self:UnregisterEvent("PLAYER_REGEN_DISABLED")
end

function TOGBankClassic_Events:SetShareTimer()
	if self.shareTimer then
		TOGBankClassic_Core:CancelTimer(self.shareTimer)
		self.shareTimer = nil
	end
	self.shareTimer = TOGBankClassic_Core:ScheduleTimer(function()
		TOGBankClassic_Events:OnShareTimer()
	end, TIMER_INTERVALS.VERSION_BROADCAST)
end

function TOGBankClassic_Events:OnShareTimer()
	-- PERF-021: Defer periodic broadcasts during zone-in cooldown to give ChatThrottleLib
	-- breathing room when processing backlogged message queues
	if self.zoningCooldown then
		TOGBankClassic_Output:Debug("EVENTS", "TIMER", "OnShareTimer deferred (zone-in cooldown active)")
		self:SetShareTimer()
		return
	end

	local now = GetTime()
	if self.lastShareTimerAt then
		local delta = now - self.lastShareTimerAt
		if delta < (TIMER_INTERVALS.VERSION_BROADCAST - 10) then
			TOGBankClassic_Output:Debug("EVENTS", "TIMER", "OnShareTimer fired early (%.1fs since last)", delta)
		end
	end
	self.lastShareTimerAt = now
	local startTime = debugprofilestop()
	TOGBankClassic_Guild:Share("reply", "version")
	local duration = debugprofilestop() - startTime
	TOGBankClassic_Output:Debug("EVENTS", "TIMER", "OnShareTimer took %.2fms", duration)

-- P2P-006: New clients broadcast their hashes via SyncDeltaVersion (called above
	-- inside Guild:Share).  Only fall back to the banker whisper for wipe-recovery:
	-- if we have NO hash data at all we can't participate in P2P comparison, so we
	-- need the banker to seed our stub table first.
	local hasAnyHashes = false
	local myAlts = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts or {}
	for _, alt in pairs(myAlts) do
		if (alt.inventoryHash or 0) ~= 0 or (alt.mailHash or 0) ~= 0 then
			hasAnyHashes = true
			break
		end
	end
	if not hasAnyHashes then
		-- Wipe-recovery: no local hashes at all → seed from banker so future P2P cycles work.
		TOGBankClassic_Guild:RequestHashListFromBanker()
	end

	-- REQUEST-001: Automatic index-based request sync on periodic timer
	TOGBankClassic_Guild:QueryRequestsIndex(nil, "NORMAL")

	-- REQUEST-RETIRE-001: Prune expired done requests on the periodic timer so fulfilled/
	-- cancelled requests don't accumulate indefinitely.  PruneIfNeeded is throttled
	-- internally (REQUEST_LOG.PRUNE_INTERVAL) so calling it on every share timer is safe --
	-- DOC-004: this said "every ~3 min", but the share timer is TIMER_INTERVALS.VERSION_BROADCAST,
	-- which is 600s. The conclusion held; the reasoning did not, since at that interval the
	-- internal guard is never the limiter.
	TOGBankClassic_Guild:PruneIfNeeded()

	self:SetShareTimer()
end

-- Delta-specific version broadcast (SYNC-001 fix)
-- P2P-006: Broadcast our hash list to the guild so peers can offer newer data.
-- Called on the periodic share timer (TIMER_INTERVALS.VERSION_BROADCAST, via Guild:Share), at
-- login, from /togbank share and /togbank sync (which the Inventory window's Open runs), and by
-- the P2P catch-up cycle. NOT after a bank scan -- deliberately, per the operator 2026-09-11: a
-- broadcast fired from the scan "risk[s] doing a broadcast with 1/2 the data, and then creating
-- another hash 5 seconds later ... that was 'too close' and wasn't updating". A fresh version
-- reaches peers on the next of those, or the moment anyone's broadcast is answered with an offer.
function TOGBankClassic_Events:SyncDeltaVersion(priority, retryCount)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then return end

	-- MULTIPC-001: from here on, a partial scan of our own bank waits for the guild's answer
	-- (P2PSession.consultBegun) -- set before the collision-guard defer below, so the wait covers
	-- the deferred send too.
	if TOGBankClassic_P2PSession and TOGBankClassic_P2PSession.BeginConsult then
		TOGBankClassic_P2PSession:BeginConsult()
	end

	-- RAID-CONSULT-001 (LOG-HYGIENE-002 F6, Peer Review db06c629): inside a raid the guard in
	-- Core:SendCommMessage drops this broadcast and Chat drops every receive, so nobody hears us
	-- and nobody can answer -- yet the collect window below still opened, closed 60 s later on
	-- "no offers", and MARKED THE GUILD CONSULTED. A partial read then published on the strength
	-- of a broadcast nobody heard, which is the MULTIPC-001 case the consult exists to prevent.
	-- The consult has begun (above), so a partial read is held; it settles on the fallback or on
	-- the first cycle that actually leaves this client. Nothing else here would reach the wire.
	if TOGBankClassic_Constants.SyncPausedByRaid() then
		TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST",
			"SyncDeltaVersion: skipped (sync paused by raid) -- no collect window, own-bank check stays open")
		return
	end

	-- P2P-023: Prevent concurrent broadcasts from colliding in AceComm multipart_spool
	-- Spool key is "prefix\tdistribution\tsender" - when same sender broadcasts twice
	-- before first completes, second FIRST chunk overwrites partial spool data, causing
	-- message corruption (FIRST from msg2 + NEXT/LAST from msg1 = CRC fail).
	retryCount = retryCount or 0
	if self.hashBroadcastInProgress then
		self.hashBroadcastBlocked = (self.hashBroadcastBlocked or 0) + 1
		if priority == "BULK" then
			-- Periodic timer broadcasts: skip if collision, next timer will catch it
			TOGBankClassic_Output:Debug("PROTOCOL", "COLLISION-GUARD",
				"Skipped BULK hash-list broadcast (previous broadcast in progress)")
			return
		else
			-- NORMAL/ALERT (login, manual commands): defer with retry
			if retryCount < 3 then
				TOGBankClassic_Output:Debug("PROTOCOL", "COLLISION-GUARD",
					"Deferring %s hash-list broadcast (retry %d/3) - will retry in 16s",
					priority or "NORMAL", retryCount + 1)
				C_Timer.After(16, function()
					self:SyncDeltaVersion(priority, retryCount + 1)
				end)
				return
			else
				-- After 3 retries (48s), force through to prevent indefinite blocking
				TOGBankClassic_Output:Debug("PROTOCOL", "COLLISION-GUARD",
					"Forcing %s hash-list broadcast after %d retries", priority or "NORMAL", retryCount)
				-- Fall through to send
			end
		end
	end

	local list = TOGBankClassic_Guild:BuildBankerHashList()
	if not list then return end

	local altCount = 0
	for _ in pairs(list) do altCount = altCount + 1 end
	if altCount == 0 then return end

	-- P2P-023: Set broadcast-in-progress flag before sending to prevent concurrent collisions
	self.hashBroadcastInProgress = true
	self.hashBroadcastCount = (self.hashBroadcastCount or 0) + 1

	local myPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()
	-- P2P-035: the broadcast is a run of `<number><canon>` entries, 24 characters each, for every
	-- banker we hold a SERVABLE canon for and a number for. That is ~900 bytes for 38 bankers where
	-- the keyed table was ~5 KB / 20 chunks on the guild channel from every member, every login and
	-- every ten minutes. A banker with no number yet, or no canon to serve, is simply absent -- a
	-- responder offers everything we did not mention, so absence is the wipe-recovery signal too.
	-- Sorted by number so two clients holding the same versions emit the same bytes.
	local BN = TOGBankClassic_BankerNumbers
	local entries, numbered = {}, 0
	for norm, summary in pairs(list) do
		local num = BN and BN:NumberOf(norm)
		if num and summary.hashV2 then
			entries[#entries + 1] = { number = num, canon = summary.hashV2 }
			numbered = numbered + 1
		end
	end
	table.sort(entries, function(a, b) return a.number < b.number end)
	local payload = {
		type     = "hlb2",
		v        = BN and BN:Version() or 0,
		e        = BN and BN:EncodeEntries(entries) or "",
		banker   = myPlayer,
		isBanker = TOGBankClassic_Guild:IsBank(myPlayer),
		addon    = GetAddOnMetadata("TOGBankClassic", "Version") or "dev",
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	local selfRef = self
	-- ACQ-004 / DOC-001: this callback took no arguments, so it cleared the collision guard on
	-- the FIRST chunk rather than on completion -- the comment claimed "once the final chunk is
	-- confirmed sent by CTL" and the code could not tell. Supplying an argument-ignoring
	-- callback is also how a caller tells AceCommQueue "I will handle the verdict myself", so
	-- the library deliberately does not report refusals here on our behalf.
	--
	-- Now: release only when the whole message is accounted for, and treat a refusal as a
	-- release too -- holding the guard after a failed send would block every later broadcast.
	TOGBankClassic_Core:SendCommMessage("togbank-hl", data, "GUILD", nil, priority or "BULK",
		function(_, bytesSent, totalBytes, sendResult)
			if sendResult == false then
				selfRef.hashBroadcastInProgress = false
				TOGBankClassic_Output:Debug("PROTOCOL", "COLLISION-GUARD",
					"Hash-list broadcast refused by the client - guard released so later broadcasts are not blocked")
			elseif bytesSent and totalBytes and bytesSent >= totalBytes then
				selfRef.hashBroadcastInProgress = false
			end
		end)
	TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "SyncDeltaVersion: broadcast %d numbered canon(s) of %d roster alts (isBanker=%s, numbers v%d, %d bytes)",
		numbered, altCount, tostring(payload.isBanker), payload.v, data and #data or 0)

	-- SETTINGS-001: Piggyback settings broadcast for authorized senders so new joiners
	-- and members who missed the immediate broadcast still receive guild-configured values.
	local settingsSender = TOGBankClassic_Guild:GetNormalizedPlayer()
	if settingsSender and (TOGBankClassic_Guild:IsBank(settingsSender) or TOGBankClassic_Guild:SenderIsOfficer(settingsSender) or TOGBankClassic_Guild:SenderIsGM(settingsSender)) then
		TOGBankClassic_Guild:BroadcastSettings()
	end

	-- Begin P2P collect window so incoming hash-offer responses are gathered.
	if TOGBankClassic_P2PSession then
		TOGBankClassic_P2PSession:BeginCollectWindow(list)
	end
end

function TOGBankClassic_Events:PLAYER_LOGIN(_)
	TOGBankClassic_Guild:GetPlayer()
end

function TOGBankClassic_Events:PLAYER_LOGOUT(_)
	-- Save persistent debug log to SavedVariables
	TOGBankClassic_Output:SavePersistentLog()
end

--- SYNCED-001: the logout countdown started. If the version of our bank minted this session has
--- reached nobody, say so now -- the countdown is the one moment the banker can still change their
--- mind. Advisory only; nothing cancels the logout.
function TOGBankClassic_Events:PLAYER_CAMPING(_)
	if TOGBankClassic_Propagation then TOGBankClassic_Propagation:OnCamping() end
end

-- Request initial guild roster update on world enter
function TOGBankClassic_Events:PLAYER_ENTERING_WORLD(_, isInitialLogin, isReloadingUi)
	TOGBankClassic_Performance:RecordEvent("PLAYER_ENTERING_WORLD")

	-- PERF-021: Set zone-in cooldown for ALL world entries (login, reload, zone change)
	-- When entering world with ChatThrottleLib backlog (e.g., 180+ queued messages from ongoing
	-- delta sends), CTL's Despool() can exceed execution limits. Defer expensive operations
	-- for 2.5s to give CTL time to drain queue without competing with our work.
	self.zoningCooldown = true
	C_Timer.After(2.5, function()
		self.zoningCooldown = false
		TOGBankClassic_Output:Debug("EVENTS", "TIMER", "Zone-in cooldown expired, resuming normal operations")
	end)

	-- PERF-013: Only do full roster refresh + broadcasts on login/reload, not zone changes
	-- Every zone change was broadcasting 2 GUILD messages (togbank-r + togbank-hl), causing
	-- ChatThrottleLib timeouts when 40+ players entered raids simultaneously
	if isInitialLogin or isReloadingUi then
		TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] PLAYER_ENTERING_WORLD (login=%s, reload=%s) - Requesting guild roster",
			tostring(isInitialLogin), tostring(isReloadingUi))
		GuildRoster()
		-- Don't try to cache before GUILD_ROSTER_UPDATE fires - GuildRoster() is async
		-- The cache will be populated when GUILD_ROSTER_UPDATE event fires
		-- Allow full refresh cycles on init to populate roster/banker cache
		self.needsFullRosterRefresh = true
		self.fullRosterInitAttempts = 0
	else
		TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] PLAYER_ENTERING_WORLD (zone change) - Skipping roster refresh")
	end
end

-- Refresh online members cache when roster updates
function TOGBankClassic_Events:GUILD_ROSTER_UPDATE(_)
	TOGBankClassic_Performance:RecordEvent("GUILD_ROSTER_UPDATE")
	-- PERF-019: Guard against overlapping roster refresh operations
	-- If GUILD_ROSTER_UPDATE fires while a deferred refresh is in progress (e.g., during
	-- zone changes while sending data), skip it to prevent cascading expensive operations
	if self.needsFullRosterRefresh and not self.refreshInProgress then
		self.fullRosterInitAttempts = (self.fullRosterInitAttempts or 0) + 1
TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] GUILD_ROSTER_UPDATE #%d - Full refresh starting", self.fullRosterInitAttempts)

		self.needsFullRosterRefresh = false
		self.refreshInProgress = true

		-- PERF-008: Defer ALL expensive roster operations AND cache invalidation
		-- Must invalidate cache INSIDE the deferred block, otherwise any IsBank() call
		-- between invalidation and rebuild will synchronously rebuild cache, causing freeze
		C_Timer.After(0.5, function()
			-- Invalidate banks cache AFTER deferring, not before
			TOGBankClassic_Guild:InvalidateBanksCache()

			local onlineCount, totalMembers = TOGBankClassic_Guild:RefreshOnlineCache()
			TOGBankClassic_Guild:RebuildBankerRoster()

			-- SCAN-001: this is the first moment IsBank() can answer correctly, so retry
			-- the banker-gated options init here. GUILD_RANKS_UPDATE alone is not a
			-- reliable retry hook -- it may not fire again after the roster loads.
			TOGBankClassic_Options:InitGuild()
			-- HIGHLIGHT-003: same moment, same reason -- a banker's saved highlight preference
			-- can only be honoured once IsBank can answer.
			if TOGBankClassic_ItemHighlight and TOGBankClassic_ItemHighlight.ApplySavedPreference then
				TOGBankClassic_ItemHighlight:ApplySavedPreference()
			end

			-- Clear delta error counters for offline players (depends on RefreshOnlineCache)
			TOGBankClassic_DeltaComms:ClearOfflineErrorCounters(TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name)
			-- Refresh Requests UI to update banker-only controls (like highlight checkbox)
			TOGBankClassic_Guild:RefreshRequestsUI()

			-- PROP-PERSIST-001: an unconfirmed "bank update" from the last session comes back BEFORE
			-- the login broadcast below, so a peer that names the canon in reply is counted as seen.
			-- Idempotent across the retries of this block.
			if TOGBankClassic_Propagation and TOGBankClassic_Propagation.Restore then
				TOGBankClassic_Propagation:Restore()
			end

			-- Keep refreshing until we get actual online member data OR we've tried 5 times
			-- If we have 0 online members after API returns data, roster API hasn't initialized yet
			local needsRetry = false
			local attempts = self.fullRosterInitAttempts or 0
			if attempts < 5 then
				if not totalMembers or totalMembers == 0 then
						TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] Retry needed: GetNumGuildMembers returned %d", totalMembers or 0)
					needsRetry = true
				elseif onlineCount == 0 then
						TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] Retry needed: 0 online members (guild not empty)")
					needsRetry = true
				end
			end

			if needsRetry then
				self.needsFullRosterRefresh = true
					TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] Will retry on next GUILD_ROSTER_UPDATE")
			else
					TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] Roster initialization complete after %d attempts", attempts)
				-- PERF-021: Only broadcast on login if zone-in cooldown has expired
				-- Roster init completes ~1s after login, well before 2.5s cooldown expires.
				-- Defer these broadcasts until cooldown clears to avoid competing with CTL backlog.
				if not self.zoningCooldown then
					-- REQUEST-001: Sync request state shortly after login, don't wait for the periodic timer
					TOGBankClassic_Guild:QueryRequestsIndex(nil, "NORMAL")				-- SYNC-014: Broadcast our hashes immediately on login so peers can offer data
					-- without waiting for the 10-minute periodic timer to fire first.
					TOGBankClassic_Events:SyncDeltaVersion("NORMAL")
				else
					TOGBankClassic_Output:Debug("EVENTS", "TIMER", "Login broadcasts deferred (zone-in cooldown active)")
					-- Reschedule after cooldown expires
					C_Timer.After(2.6, function()
						if not self.zoningCooldown then
							TOGBankClassic_Guild:QueryRequestsIndex(nil, "NORMAL")
							TOGBankClassic_Events:SyncDeltaVersion("NORMAL")
						end
					end)
				end
			end

			-- PERF-019: Clear in-progress flag to allow next refresh cycle
			self.refreshInProgress = false
		end)
	else
		if self.needsFullRosterRefresh and self.refreshInProgress then
			TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] GUILD_ROSTER_UPDATE skipped (refresh already in progress)")
		else
			TOGBankClassic_Output:Debug("EVENTS", "SKIP", "GUILD_ROSTER_UPDATE ignored (online/offline handled via system messages)")
		end
	end
end

-- Whisper-failure offline detection.
--
-- EVENT-001: this handler's signature previously omitted the leading event-name parameter.
-- AceEvent dispatches as fn(eventName, ...) -- verified in Ace3/AceEvent-3.0.lua:120 and
-- CallbackHandler-1.0.lua:54 -- so `message` received the literal string "CHAT_MSG_SYSTEM",
-- every match failed, and the whole handler silently did nothing in every shipped release.
--
-- ROSTER-003: online / offline / joined / left are now handled by LibGuildRoster, which owns
-- its own CHAT_MSG_SYSTEM registration and builds its patterns from the localized ERR_* globals
-- rather than hardcoded English. Those branches are gone from here; see Guild:InitRosterCallbacks.
--
-- What remains is the one case the library does NOT cover: "No player named X is currently
-- playing", i.e. a whisper bounced because the target is offline. The library matches
-- ERR_FRIEND_ONLINE_SS / OFFLINE_S / GUILD_JOIN_S / GUILD_LEAVE_S / GUILD_REMOVE_SS only --
-- this message is ERR_CHAT_PLAYER_NOT_FOUND_S and is not in that set. It is the authoritative
-- signal that stops the addon whispering at someone who is not logged in, so it stays here.
function TOGBankClassic_Events:CHAT_MSG_SYSTEM(_, message)
	if not message or message == "" then
		return
	end

	-- Classic sends several shapes of this message:
	--   No player named 'Axkva' is currently playing.  (single-quoted name)
	--   No player named Axkva is currently playing.    (unquoted)
	--   Player not found: Axkva                        (simplified)
	local notFoundName = message:match("^No player named '(.+)' is currently playing%.$")
		or message:match("^No player named (.+) is currently playing%.$")
		or message:match("^Player not found %(retail pattern%): (.+)$")
		or message:match("^Player not found: (.+)$")
	if notFoundName then
		-- ROSTER-003: counted so /togbank dev rostercheck can show this path is live. It is the
		-- one presence signal LibGuildRoster does not cover, so it has no other verification.
		if TOGBankClassic_Guild.NoteRosterEvent then
			TOGBankClassic_Guild:NoteRosterEvent("notFound", notFoundName)
		end
		-- OUTPUT-002: this used to ALSO print an unconditional Output:Info line ("[WHISPER-SPAM-FIX]
		-- Player X is not online ...") -- one per bounced whisper, in every player's chat, with no
		-- way to turn it off. Reported from a live guild 2026-08-24: "ensure they are behind a debug
		-- flag". The Debug line below is that line, under ROSTER/ONLINE.
		TOGBankClassic_Output:Debug("ROSTER", "ONLINE",
			"[CHAT_MSG_SYSTEM] Player %s is not online (WoW error) - marked offline to stop whispering them",
			notFoundName)
		TOGBankClassic_Guild:UpdateOnlineMember(notFoundName, false, "wow-error-not-online")
	end
end

function TOGBankClassic_Events:GUILD_RANKS_UPDATE(_)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		return
	end

	-- SCAN-001: InitGuild must run OUTSIDE the Guild:Init() gate. Init() returns false
	-- once Info.name matches the guild, so nesting it here meant exactly one attempt per
	-- session -- and that attempt happens before the roster carries guild notes, so
	-- IsBank() is false and the per-character bank toggle never gets initialised.
	-- InitGuild latches internally, so calling it on every event is cheap.
	TOGBankClassic_Options:InitGuild()

	-- Load guild data and perform a one-time cleanup of malformed alt entries
	if TOGBankClassic_Guild:Init(guild) then
		if TOGBankClassic_Constants.SyncPausedByRaid() then
			TOGBankClassic_Output:Debug("EVENTS", "SKIP", "GUILD_RANKS_UPDATE: ignoring guild ranks cleanup (in raid)")
			return
		end
		local cleaned = TOGBankClassic_Guild:CleanupMalformedAlts()
		if cleaned and cleaned > 0 then
			TOGBankClassic_Output:Info("Cleaned %d malformed alt entries from saved database", cleaned)
		end
	end
end

function TOGBankClassic_Events:BANKFRAME_OPENED(_)
	TOGBankClassic_Bank:OnUpdateStart()
end

function TOGBankClassic_Events:BANKFRAME_CLOSED(_)
	TOGBankClassic_Bank:OnUpdateStop()
	-- BANKFILL-001 self-audit: the bank-collect state machine has a "return the surplus" phase that
	-- can only be left by finding the pulled stack in bags. Walking away from the bank with that
	-- phase armed -- and then using, mailing or banking the item -- left it armed forever: every
	-- later click at any bank answered "waiting for the stack to reach your bags" and never
	-- collected anything. MAIL_CLOSED already drops the mailbox-side state for the same reason.
	TOGBankClassic_Mail:ResetFulfillStep()
end

function TOGBankClassic_Events:MAIL_SHOW(_)
	TOGBankClassic_Output:Debug("MAIL", "EVENTS", "MAIL_SHOW event fired")
	TOGBankClassic_Bank:OnUpdateStart()
	TOGBankClassic_MailInventory.hasUpdated = true  -- Flag that mail was accessed
	TOGBankClassic_Output:Debug("MAIL", "EVENTS", "Set MailInventory.hasUpdated = %s", tostring(TOGBankClassic_MailInventory.hasUpdated))
	TOGBankClassic_Mail.isOpen = true
	TOGBankClassic_Mail:InitSendHook()
	TOGBankClassic_Mail:Check()
	-- MAILUI-001: the inbox window opens beside Blizzard's for bankers.
	if TOGBankClassic_UI_Mailbox and TOGBankClassic_UI_Mailbox.OnMailShow then
		TOGBankClassic_UI_Mailbox:OnMailShow()
	end

	-- Hook MailFrame OnHide to detect when mail closes (MAIL_CLOSED event may not fire reliably)
	if not MailFrame.TOGBankHooked then
		MailFrame:HookScript("OnHide", function()
			TOGBankClassic_Output:Debug("MAIL", "EVENTS", "MailFrame OnHide fired (mailbox closed)")
			TOGBankClassic_Events:MAIL_CLOSED()
		end)
		MailFrame.TOGBankHooked = true
		TOGBankClassic_Output:Debug("MAIL", "EVENTS", "Hooked MailFrame OnHide")
	end
end

function TOGBankClassic_Events:MAIL_INBOX_UPDATE(_)
	-- LOG-MAIL-001: every inbox read records what left it since the last, so the mint can name the
	-- sender of an attachment the banker TOOK (the bank log's deposit is the take, not the arrival).
	if TOGBankClassic_MailInventory and TOGBankClassic_MailInventory.NoteInbox then
		TOGBankClassic_MailInventory:NoteInbox()
	end
	TOGBankClassic_Mail:Scan()
	-- MAILUI-001: a take, a delete or a refresh renumbers the inbox; the rows are rebuilt from it.
	if TOGBankClassic_UI_Mailbox and TOGBankClassic_UI_Mailbox.OnInboxUpdate then
		TOGBankClassic_UI_Mailbox:OnInboxUpdate()
	end
end

function TOGBankClassic_Events:MAIL_CLOSED(_)
	TOGBankClassic_Output:Debug("MAIL", "EVENTS", "MAIL_CLOSED event fired")
	TOGBankClassic_Mail.isOpen = false
	TOGBankClassic_Mail.isScanning = false
	TOGBankClassic_Mail:ResetFulfillStep()  -- FILLALL-001: drop any in-progress stepped fulfillment
	-- LOG-MAIL-001: the inbox comparison ends with the mailbox. NOT a final read here: the inbox
	-- data may already be gone from the client at this point, and an empty read would count every
	-- attachment still sitting there as taken.
	if TOGBankClassic_MailInventory and TOGBankClassic_MailInventory.CloseInbox then
		TOGBankClassic_MailInventory:CloseInbox()
	end
	TOGBankClassic_Output:Debug("MAIL", "EVENTS", "Calling Bank:OnUpdateStop()")
	TOGBankClassic_Bank:OnUpdateStop()
	TOGBankClassic_Output:Debug("MAIL", "EVENTS", "Bank:OnUpdateStop() completed")
	TOGBankClassic_UI_Mail:Close()
	if TOGBankClassic_UI_Mailbox and TOGBankClassic_UI_Mailbox.OnMailClosed then
		TOGBankClassic_UI_Mailbox:OnMailClosed()
	end
	-- Refresh fulfill button states without a full structural rebuild
	C_Timer.After(0.1, function()
		if TOGBankClassic_UI_Requests.isOpen then
			local actor = TOGBankClassic_Guild:GetNormalizedPlayer()
			local isActorBank = actor and TOGBankClassic_Guild:IsBank(actor) or false
			TOGBankClassic_UI_Requests:_RefreshFulfillButtons(actor, isActorBank, false)
		end
	end)
end

function TOGBankClassic_Events:MAIL_SEND_SUCCESS(_)
	TOGBankClassic_Output:Debug("MAIL", "EVENTS", "MAIL_SEND_SUCCESS event fired")
	-- safety: ensure hook is registered when mail UI is opened
	TOGBankClassic_Mail:InitSendHook()
	TOGBankClassic_Mail:ApplyPendingSend()
end

function TOGBankClassic_Events:UI_ERROR_MESSAGE(_, message)
	if not message then
		return
	end

	-- Capture mail send failures (includes "Internal mail database error")
	if tostring(message):lower():find("mail") then
		TOGBankClassic_Mail.batchInFlight = false  -- FILLALL-001: send failed; allow retry
		TOGBankClassic_Output:Debug("MAIL", "EVENTS", "UI_ERROR_MESSAGE: %s", tostring(message))
		if TOGBankClassic_Mail and TOGBankClassic_Mail.DebugSendMailState then
			TOGBankClassic_Mail:DebugSendMailState(message)
		end
		if TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.isOpen then
			TOGBankClassic_UI_Requests:SetStatusText(string.format("Mail error: %s", tostring(message)))
		end
	end
end

function TOGBankClassic_Events:TRADE_SHOW(_)
	TOGBankClassic_Bank:OnUpdateStart()
end

function TOGBankClassic_Events:TRADE_CLOSED(_)
	TOGBankClassic_Bank:OnUpdateStop()
end

function TOGBankClassic_Events:AUCTION_HOUSE_SHOW(_)
	TOGBankClassic_Bank:OnUpdateStart()
end

function TOGBankClassic_Events:AUCTION_HOUSE_CLOSED(_)
	TOGBankClassic_Bank:OnUpdateStop()
end

function TOGBankClassic_Events:MERCHANT_SHOW(_)
	TOGBankClassic_Bank:OnUpdateStart()
end

function TOGBankClassic_Events:MERCHANT_CLOSED(_)
	TOGBankClassic_Bank:OnUpdateStop()
end

--close frame on combat
function TOGBankClassic_Events:PLAYER_REGEN_DISABLED(_)
	if TOGBankClassic_Options:GetCombatHide() then
		TOGBankClassic_UI_Inventory:Close()
	end
end
