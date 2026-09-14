
TOGBankClassic_Guild = {}

-- NS-001: aliased as file-scope locals so a foreign global of the same name cannot be read
-- instead. See the header of Modules/Constants.lua.
local PEER_TO_PEER = TOGBankClassic_Constants.PEER_TO_PEER
local PROTOCOL     = TOGBankClassic_Constants.PROTOCOL

TOGBankClassic_Guild.Info = nil

-- Full guild roster cache with online status (updated via GUILD_ROSTER_UPDATE)
-- Stores ALL guild members with explicit online/offline state
-- Format: {["Name-Realm"] = {name="Name-Realm", class="CLASS", level=60, isOnline=true}, ...}
TOGBankClassic_Guild.memberRoster = {}

-- Legacy compatibility: onlineMembers still exists but now derived from memberRoster
-- Will be phased out once all code migrates to memberRoster
TOGBankClassic_Guild.onlineMembers = {}

-- Cache of recently-seen players (cross-realm/cross-guild)
-- Tracks players who have sent messages recently (5 minute expiry)
-- Format: {[normalizedName] = lastSeenTimestamp}
TOGBankClassic_Guild.recentlySeen = {}

-- Cache of guild bankers (updated via GUILD_ROSTER_UPDATE)
-- Prevents iterating through entire guild roster on every IsBank() call
TOGBankClassic_Guild.banksCache = nil

-- Pending request tracking tables
TOGBankClassic_Guild.pendingAltRequests = {}
--- Per normalized alt: a table describing the pull-path request in flight ({ banker, requestedAt }
--- or the noBanker / bankerOffline forms below). Typed here so a spec that stubs the table cannot
--- retype every writer in this file through the language server's inference.
---@type table<string, table>
TOGBankClassic_Guild.pendingP2PRequests = {}
TOGBankClassic_Guild.pendingP2PTimeouts = {}   -- Track P2P broadcast timeouts for cancellation
TOGBankClassic_Guild.lastAltQueryTime = {}
TOGBankClassic_Guild.bankerProgressKnown = {}

-- P2P send queue cap. The COUNT this is enforced against lives on P2PSession (activeSends, summed
-- by GetActiveSendTotal); only the limit itself is here, because Chat.lua and the status bar both
-- read it.
--
-- P2P-025: `pendingSendCount` and `pendingSendTimeouts` were removed on 2026-09-08. They were the
-- remains of a P2P backoff path that no longer exists: four sites decremented the counter, nothing
-- incremented it, and NOTHING EVER WROTE THE REGISTRY -- so `isP2PSend` in SendAltData was
-- permanently false and `releaseP2PSlot`'s entire body was unreachable at its guard. The status bar
-- read the counter and so could never render Tx:n/3. Do not reintroduce a second counter here;
-- Tests/statusbar_spec.lua asserts this file does not carry one.
-- The cap is Constants' (PEER_TO_PEER.MAX_ACTIVE_SENDS); this name is the one Chat.lua's relay
-- and banker ACK branches read. Not a second number.
TOGBankClassic_Guild.MAX_PENDING_SENDS = PEER_TO_PEER.MAX_ACTIVE_SENDS
TOGBankClassic_Guild.pendingP2PFallbackTimeouts = {}  -- Track 15s peer fallback timeouts

-- Temporary in-memory error storage for when Guild.Info is not initialized
TOGBankClassic_Guild.tempDeltaErrors = {
	lastErrors = {},
	failureCounts = {},
	notifiedAlts = {},
}

-- Migrate temporary errors to database once Guild.Info is initialized
function TOGBankClassic_Guild:MigrateTempErrors()
	if not self.Info or not self.Info.name then
		return
	end

	local db = TOGBankClassic_Database.db.faction[self.Info.name]
	if not db or not db.deltaErrors then
		return
	end

	-- Migrate errors
	if #self.tempDeltaErrors.lastErrors > 0 then
		for i = #self.tempDeltaErrors.lastErrors, 1, -1 do
			table.insert(db.deltaErrors.lastErrors, 1, self.tempDeltaErrors.lastErrors[i])
		end
		-- Keep only recent errors (max 10)
		while #db.deltaErrors.lastErrors > 10 do
			table.remove(db.deltaErrors.lastErrors)
		end
	end

	-- Migrate failure counts
	for altName, count in pairs(self.tempDeltaErrors.failureCounts) do
		if not db.deltaErrors.failureCounts[altName] then
			db.deltaErrors.failureCounts[altName] = 0
		end
		db.deltaErrors.failureCounts[altName] = db.deltaErrors.failureCounts[altName] + count
	end

	-- Migrate notification flags
	for altName, flag in pairs(self.tempDeltaErrors.notifiedAlts) do
		if flag then
			db.deltaErrors.notifiedAlts[altName] = true
		end
	end

	-- Clear temp storage
	self.tempDeltaErrors.lastErrors = {}
	self.tempDeltaErrors.failureCounts = {}
	self.tempDeltaErrors.notifiedAlts = {}

	TOGBankClassic_Output:Debug("DATABASE", "MIGRATE", "Migrated temporary delta errors to database")
end

-- Record a delta error with details (persisted to database or temp storage)
-- Delta error tracking delegated to DeltaComms module
function TOGBankClassic_Guild:RecordDeltaError(altName, errorType, errorMessage)
	return TOGBankClassic_DeltaComms:RecordDeltaError(self.Info and self.Info.name, altName, errorType, errorMessage)
end

-- Reset failure count for an alt (called on successful sync)
function TOGBankClassic_Guild:ResetDeltaErrorCount(altName)
	return TOGBankClassic_DeltaComms:ResetDeltaErrorCount(self.Info and self.Info.name, altName)
end

-- Get recent delta errors
function TOGBankClassic_Guild:GetRecentDeltaErrors()
	return TOGBankClassic_DeltaComms:GetRecentDeltaErrors(self.Info and self.Info.name)
end

-- Get failure count for an alt
function TOGBankClassic_Guild:GetDeltaFailureCount(altName)
	return TOGBankClassic_DeltaComms:GetDeltaFailureCount(self.Info and self.Info.name, altName)
end

-- ROSTER-003: LibGuildRoster-1.0 is a required dependency (both TOCs + .pkgmeta) and owns the
-- roster from v1.4.0. It registers PLAYER_LOGIN / GUILD_ROSTER_UPDATE / CHAT_MSG_SYSTEM on its
-- own frame, so presence tracking no longer depends on this addon forwarding events correctly --
-- which is what EVENT-001 was: a handler that silently never ran.
--
-- Resolved lazily rather than at file scope: load order puts the library first, but a user who
-- disables it should degrade to the legacy roster scan rather than error on load. Every call
-- site below falls back, so the addon still works (with EVENT-001's blind spot) without it.
local function RosterLib()
	return LibStub and LibStub("LibGuildRoster-1.0", true) or nil
end
TOGBankClassic_Guild.RosterLib = RosterLib

-- NS-001: file-scope local, published on the module table rather than as a bare global. The old
-- spelling was `function GetPlayerWithNormalizedRealm(name)` -- a global with a name generic enough
-- that any other addon declaring one would have silently replaced ours, changing how every player
-- name in this addon is normalised with no error anywhere. Same class as the Grouper DEBUG_CATEGORY
-- collision documented in Modules/Constants.lua, which did happen.
local function GetPlayerWithNormalizedRealm(name)
	if string.match(name, "(.*)%-(.*)") then
		return name
	end
	return name .. "-" .. GetNormalizedRealmName()
end
TOGBankClassic_Guild.GetPlayerWithNormalizedRealm = GetPlayerWithNormalizedRealm

-- wrapper to ensure consistent normalization across the addon
local function NormalizePlayerName(name)
	if not name then
		return nil
	end
	if type(name) ~= "string" then
		name = tostring(name)
	end
	local trimmed = string.gsub(name, "^%s+", "")
	trimmed = string.gsub(trimmed, "%s+$", "")
	if trimmed == "" then
		return nil
	end
	-- Canonicalize hyphen spacing: convert "Name - Realm" or "Name- Realm" to "Name-Realm"
	local normalized = string.gsub(trimmed, "%s*%-%s*", "-")
	local left, right = string.match(normalized, "^(.-)%-(.-)$")
	if left and right then
		if left == "" then
			return nil
		end
		if string.lower(left) == "unknown" then
			return "Unknown"
		end
		if right ~= "" then
			return normalized
		end
		normalized = left
	end
	if string.lower(normalized) == "unknown" then
		return "Unknown"
	end
	-- NS-001: the `if GetPlayerWithNormalizedRealm then` guard that used to wrap this call is gone.
	-- It read as defensive but could only ever be false while the helper was a bare GLOBAL that
	-- another addon might not have left in place; as a local declared 30 lines above it is always
	-- present, so the guard was dead and the realm-appending fallback under it was unreachable.
	return GetPlayerWithNormalizedRealm(normalized)
end
-- expose for other modules
TOGBankClassic_Guild.NormalizePlayerName = NormalizePlayerName

function TOGBankClassic_Guild:NormalizeName(name)
	if not name then
		return nil
	end
	local normalize = self.NormalizePlayerName
	if normalize then
		return normalize(name)
	end
	return name
end

function TOGBankClassic_Guild:GetNormalizedPlayer(name)
	return self:NormalizeName(name or self:GetPlayer())
end

function TOGBankClassic_Guild:GetPlayer()
	if TOGBankClassic_Bank.player then
		return TOGBankClassic_Bank.player
	end

	-- The below code should never be called, but is here for safety
	local function try()
		local name, realm = UnitName("player"), GetNormalizedRealmName()
		if name and realm then
			TOGBankClassic_Bank.player = name .. "-" .. realm
			return true
		end
	end
	if try() then
		return TOGBankClassic_Bank.player
	end
	local count, max, delay = 0, 10, 15
	local timer
	timer = C_Timer.NewTicker(delay, function()
		count = count + 1
		if try() or count >= max then
			if timer then
				timer:Cancel()
			end
		end
	end)

	return nil
end

function TOGBankClassic_Guild:GetGuild()
	return IsInGuild("player") and GetGuildInfo("player") or nil
end

-- SYNC-001 fix: Check if a player is in the current guild roster
-- Returns true if the player is a member of the current guild
function TOGBankClassic_Guild:IsInCurrentGuildRoster(playerName)
	if not playerName then
		return false
	end

	if not IsInGuild() then
		return false
	end

	local normPlayer = self:NormalizeName(playerName)

	-- PERF: O(1) memberRoster lookup instead of scanning all 500 members.
	--
	-- A STUB ENTRY DOES NOT COUNT. Stubs are created by UpdateOnlineMember from an inbound addon
	-- message -- an unauthenticated claim about a name -- and Chat:OnCommReceived does that for
	-- every message BEFORE authorisation. Treating one as membership let any sender satisfy this
	-- check simply by sending, which is the whole roster half of IsAltDataAllowed. A stub therefore
	-- falls through to the authoritative client roster scan below rather than answering true.
	if self.memberRoster and next(self.memberRoster) then
		local entry = self.memberRoster[normPlayer]
		if entry and not entry.isStub then
			return true
		end
	end

	-- Fallback: memberRoster not yet populated (very early in login sequence)
	for i = 1, GetNumGuildMembers() do
		local rosterName = GetGuildRosterInfo(i)
		if rosterName then
			local normRoster = self:NormalizeName(rosterName)
			if normRoster == normPlayer then
				return true
			end
		end
	end

	return false
end

function TOGBankClassic_Guild:GetPlayerInfo(name)
	if not name then return nil end
	-- PERF: O(1) memberRoster lookup instead of scanning all members
	if self.memberRoster and next(self.memberRoster) then
		local norm = self:NormalizeName(name)
		local member = norm and self.memberRoster[norm]
		return member and member.class or nil
	end
	-- Fallback: memberRoster not yet populated
	for i = 1, GetNumGuildMembers() do
		local playerRealm, _, _, _, _, _, _, _, _, _, class = GetGuildRosterInfo(i)
		-- Only the match itself matters here; the captures are unused because the comparison
		-- below is against the full "Name-Realm" string.
		if playerRealm == name then
			return class
		end
	end
	return nil
end

function TOGBankClassic_Guild:Reset(name)
	if not name then
		return
	end

	TOGBankClassic_UI_Inventory:Close()
	TOGBankClassic_Database:Reset(name)
	self.Info = TOGBankClassic_Database:Load(name)
	self:EnsureRequestsInitialized()

	-- Migrate any temporary errors to database
	self:MigrateTempErrors()

	-- PERF-008: Defer expensive RebuildBankerRoster() to prevent freeze on first load/wipe
	-- Reset() is called during Init() if no data exists, which happens on GUILD_RANKS_UPDATE
	-- Loops through all guild members (500+) which blocks for 5+ seconds on large guilds
	C_Timer.After(1, function()
		self:RebuildBankerRoster()
	end)
end

--- HASH-CANON-005: re-encode every held v1.4.0 numeric canon as `<dts><hash>`, once, on load.
---
--- Deterministic and applied identically by every client -- the author of each record included --
--- so all copies of one old publish converge on one string with no rescan and no rehydration (see
--- DeltaComms:CanonFrom for why this is a re-encoding and not the mutation the canon rule forbids).
--- A numeric canon with no publish time beside it cannot be re-encoded and is CLEARED: it was a
--- version nobody can place in time, and leaving it would make HashesAgreeWith compare a number
--- against strings forever.
---@return number reencoded, number cleared
function TOGBankClassic_Guild:ReencodeHeldCanons()
	local alts = self.Info and self.Info.alts
	local DC = TOGBankClassic_DeltaComms
	if not alts or not (DC and DC.CanonFrom) then return 0, 0 end
	local reencoded, cleared = 0, 0
	for _, alt in pairs(alts) do
		if type(alt) == "table" and alt.inventoryHashV2 ~= nil and type(alt.inventoryHashV2) ~= "string" then
			local canon = DC:CanonFrom(alt.inventoryHashV2, alt.inventoryUpdatedAt or alt.version)
			alt.inventoryHashV2 = canon
			if canon then reencoded = reencoded + 1 else cleared = cleared + 1 end
		end
	end
	if reencoded + cleared > 0 then
		TOGBankClassic_Output:Debug("DATABASE", "MIGRATE",
			"HASH-CANON-005: re-encoded %d numeric canon(s) as <dts><hash>, cleared %d with no publish time",
			reencoded, cleared)
	end
	return reencoded, cleared
end

function TOGBankClassic_Guild:Init(name)
	if not name then
		return false
	end
	if self.Info and self.Info.name == name then
		return false
	end

	self.hasRequested = false
	self.requestCount = 0

	self.Info = TOGBankClassic_Database:Load(name)
	if self.Info then
		self:EnsureRequestsInitialized()
		self:ReencodeHeldCanons()
		-- PROP-PERSIST-001: the record is loaded now, so the saved "bank update not received" tracker
		-- can be judged against the held canon. The roster-init call can run before this point and
		-- must not be the only one.
		if TOGBankClassic_Propagation and TOGBankClassic_Propagation.Restore then
			TOGBankClassic_Propagation:Restore()
		end
		-- DEFER-PERSIST-001: a publish the gate was holding when the last session ended comes back
		-- the same way, judged against the held canon now that it is loaded.
		if TOGBankClassic_Bank and TOGBankClassic_Bank.RestoreDeferred then
			TOGBankClassic_Bank:RestoreDeferred()
		end
		-- STALE-REQ-002: from here the guild record exists, so VersionCheck's observations can be
		-- remembered in it as they land.
		self:HookVersionCheck()
		-- Migrate any temporary errors to database
		self:MigrateTempErrors()
		-- Prune expired done requests immediately on load so stale data doesn't linger
		-- until the first share timer fires (TIMER_INTERVALS.VERSION_BROADCAST). lastPruneTime is nil on login so
		-- PruneIfNeeded's throttle guard is never hit — this always runs once.
		self:PruneIfNeeded()

		-- PERF-008: Defer expensive RebuildBankerRoster() to prevent login freeze
		-- Loops through all guild members (500+) which blocks for 5+ seconds on large guilds
		-- Delay by 1 second to allow UI to become responsive first
		C_Timer.After(1, function()
			self:RebuildBankerRoster()
		end)

		-- PERF-010 / ROSTER-002: Defer hash cache initialization to prevent login freeze.
		-- Delayed to 1.5s (after RebuildBankerRoster at 1s) so banksCache is already clean.
		-- Filtered to current banksCache only — prevents stale ex-banker stubs (removed by
		-- RebuildBankerRoster) from being seeded into latestBankerHashes and showing as
		-- perpetual "HLR pending" entries.
		C_Timer.After(1.5, function()
			self.latestBankerHashes = {}
			-- TABCOLOUR-002: session-scoped and per guild. Nothing seeds it -- until a peer mentions
			-- a version, nobody has said anything newer exists, which is "current".
			self.newestAdvertisedAt = {}
			self.newestAdvertisedBy = {}   -- CLAIM-TRACE-001, same scope: who raised that time
			self.newerOfferedBy = {}   -- TABCOLOUR-003, same scope
			self.refusedNewerBy = {}   -- TAB-STATE-003, same scope
			local hashCount = 0
			-- Use banksCache (freshly built by RebuildBankerRoster) as the filter.
			-- Fall back to roster.alts from SV only if banksCache hasn't been built yet.
			local currentBankers = self.banksCache or (self.Info and self.Info.roster and self.Info.roster.alts) or {}
			local bankerLookup = {}
			for _, bankerName in ipairs(currentBankers) do
				local norm = self:NormalizeName(bankerName)
				if norm then bankerLookup[norm] = true end
			end
			if self.Info.alts then
				for altName, alt in pairs(self.Info.alts) do
					if alt and bankerLookup[altName] then
						-- The seed is our OWN stored state, written before anything arrives, so it goes
						-- in directly rather than through NoteAdvertisedHashes -- but it carries hashV2
						-- like every other entry (HASH-CACHE-001): a seed without it would be a
						-- revision-1-only entry that any V2 claim then displaces regardless of time.
						self.latestBankerHashes[altName] = {
							hash = alt.inventoryHash or 0,
							hashV2 = alt.inventoryHashV2,
							updatedAt = alt.inventoryUpdatedAt or alt.version or 0,
							version = alt.version or 0,
							mailHash = alt.mailHash or 0,
							mailUpdatedAt = (alt.mail and alt.mail.version) or 0,
						}
						hashCount = hashCount + 1
					end
				end
			end
			TOGBankClassic_Output:Debug("PROTOCOL", "HLR", "Initialized banker hash cache with %d alts (filtered to current roster)", hashCount)
		end)

		return true
	end

	self:Reset(name)
	return true
end

-- Cleanup malformed entries in the saved guild data
-- This attempts to be conservative:
-- - remove alts that are not tables
-- - remove alts with no version and no money (INV2-RETIRE-003: the item-row clauses are gone with
--   the rows; a record's contents live in the V2 store, and its metadata is what this judges)
-- - ensure roster.alts is a proper array
-- Returns number of alts cleaned
function TOGBankClassic_Guild:CleanupMalformedAlts()
	if not self.Info or not self.Info.alts then
		return 0
	end

	local cleaned = 0
	for name, alt in pairs(self.Info.alts) do
		local remove = false
		if type(alt) ~= "table" then
			remove = true
		elseif not alt.version and not alt.money then
			remove = true
		end

		if remove then
			TOGBankClassic_Output:Debug("DATABASE", "CLEAN", "Removing malformed bank entry for", name)
			self.Info.alts[name] = nil
			cleaned = cleaned + 1
		end
	end

	-- Ensure roster.alts is a proper array (remove nils and non-strings)
	if self.Info.roster and self.Info.roster.alts then
		local new_alts = {}
		for _, v in pairs(self.Info.roster.alts) do
			if type(v) == "string" and v ~= "" then
				table.insert(new_alts, v)
			end
		end
		self.Info.roster.alts = new_alts
	end

	return cleaned
end

-- VIEWBANK-001: a bank toon can be flagged "view only" — its stock stays visible
-- everywhere (inventory, search, tooltips), but guild members can't send requests
-- for it (e.g. a raid bank). Officers flag it by adding a view-only marker to the
-- toon's guild note alongside the usual "gbank" tag, e.g. "gbank viewonly" or the
-- compact "gbankro". Accepted markers (case-insensitive) below.
local VIEW_ONLY_MARKERS = { "viewonly", "view-only", "view only", "readonly", "read-only", "read only", "gbankro" }
local function noteHasViewMarker(note)
	if type(note) ~= "string" or note == "" then
		return false
	end
	local lower = note:lower()
	for _, marker in ipairs(VIEW_ONLY_MARKERS) do
		if lower:find(marker, 1, true) then
			return true
		end
	end
	return false
end
local function noteIsViewOnly(note1, note2)
	return noteHasViewMarker(note1) or noteHasViewMarker(note2)
end

function TOGBankClassic_Guild:GetBanks()
	-- Return cached banks list if available
	if self.banksCache ~= nil then
		return self.banksCache
	end
	-- PERF: Derive banker list from memberRoster (already built by RefreshOnlineCache)
	-- instead of calling GetGuildRosterInfo() for every member again.
	local banks = {}
	if self.memberRoster and next(self.memberRoster) then
		for norm, member in pairs(self.memberRoster) do
			if member.isBank then
				table.insert(banks, member.name or norm)
			end
		end
	else
		-- Fallback: memberRoster not yet populated (very early in login sequence)
		for i = 1, GetNumGuildMembers() do
			local name, _, _, _, _, _, publicNote, officer_note = GetGuildRosterInfo(i)
			if name then
				if (publicNote and publicNote:find("gbank", 1, true))
				or (officer_note and officer_note:find("gbank", 1, true)) then
					table.insert(banks, name)
				end
			end
		end
	end
	-- Cache the result (nil if no banks found)
	if #banks == 0 then
		self.banksCache = nil
		return nil
	end
	self.banksCache = banks
	return banks
end

-- Invalidate the banks cache (call when guild roster changes)
function TOGBankClassic_Guild:InvalidateBanksCache()
	self.banksCache = nil
end

-- Rebuild banker roster from local guild notes (no network communication needed)
-- Called automatically on GUILD_ROSTER_UPDATE event
function TOGBankClassic_Guild:RebuildBankerRoster()
	if not self.Info then
		return
	end

	local banks = {}
	for i = 1, GetNumGuildMembers() do
		local name, _, _, _, _, _, publicNote, officer_note = GetGuildRosterInfo(i)
		if name then
			-- PERF: plain-text find is orders of magnitude faster than (.*)gbank(.*) pattern
			local isBank = (publicNote and publicNote:find("gbank", 1, true) ~= nil)
				or (officer_note and officer_note:find("gbank", 1, true) ~= nil)
			if isBank then
				table.insert(banks, name)
			end
			-- Keep memberRoster.isBank / .viewOnly in sync if the entry already exists
			local norm = self:NormalizeName(name)
			if norm and self.memberRoster and self.memberRoster[norm] then
				self.memberRoster[norm].isBank = isBank or false
				self.memberRoster[norm].viewOnly = (isBank and noteIsViewOnly(publicNote, officer_note)) or false
			end
		end
	end

	-- Update roster.alts list (roster sync is local-only, no version tracking needed)
	local oldRoster = table.concat(self.Info.roster.alts or {}, ",")
	local newRoster = table.concat(banks, ",")

	local rosterChanged = oldRoster ~= newRoster
	if rosterChanged then
		self.Info.roster.alts = banks
		self.Info.roster.version = GetServerTime()
		TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "Rebuilt banker roster from guild notes: %d bankers", #banks)
	end

	-- PERF-008: Rebuild banksCache directly to prevent lazy synchronous rebuild
	-- If cache is nil and IsBank() is called, GetBanks() will synchronously rebuild
	-- By rebuilding here, we ensure future IsBank() calls use cached data
	if #banks == 0 then
		self.banksCache = nil

		-- ROSTER-004: say WHY there are no bankers, when we can tell.
		--
		-- GetGuildRosterInfo returns officerNote as "" in TWO different situations that are
		-- indistinguishable from the string alone: the note is genuinely empty, or the player's
		-- rank is not permitted to read officer notes. So a guild whose bankers are tagged ONLY
		-- in the officer note looks, to a member without that permission, exactly like a guild
		-- with no bankers at all -- an empty window and no explanation.
		--
		-- LIBREQ-GR-001 asked LibGuildRoster for a `CanViewOfficerNotes()` accessor to close
		-- this. NOT A GAP, established 2026-09-09 by reading the library: `lib:IsOfficer()` with
		-- NO argument already is that accessor -- LibGuildRoster-1.0.lua:2361-2363 returns
		-- `C_GuildInfo.CanViewOfficerNote()` for the player. It is named for the privilege rather
		-- than the visibility, which is why it was missed. The per-member half of that request is
		-- genuinely unbuildable (no client API answers another member's permissions, :2350-2359)
		-- and TOGBank never needed it -- "can *I* read officer notes" is the whole question.
		--
		-- Feature-detected because the library's own header requires it: IsOfficer arrived in
		-- MINOR 12 and an older installed copy will not have it. Absent, we simply stay quiet --
		-- guessing would produce this warning for every guild that really has no bankers.
		if not self.warnedOfficerNoteBlind then
			local lib = RosterLib()
			if lib and lib.IsOfficer and lib:IsOfficer() == false then
				self.warnedOfficerNoteBlind = true
				TOGBankClassic_Output:Warn(
					"No guild bankers found. Your rank cannot read officer notes, so any banker " ..
					"tagged there is invisible to you -- ask an officer to put 'gbank' in the " ..
					"PUBLIC note instead.")
			end
		end
	else
		self.banksCache = banks
		-- Re-arm, so a member promoted mid-session is told again if the list empties later.
		self.warnedOfficerNoteBlind = nil
	end

	-- Ensure local alt data exists for all roster bankers (authoritative roster cache)
	if not self.Info.alts then
		self.Info.alts = {}
	end
	-- ROSTER-002: Build lookup of current bankers for stub-cleanup pass below
	local newBanksLookup = {}
	for _, name in ipairs(banks) do
		local norm = self:NormalizeName(name)
		if norm then
			newBanksLookup[norm] = true
		end
	end
	for _, name in ipairs(banks) do
		local norm = self:NormalizeName(name)
		if norm and not self.Info.alts[norm] then
			-- INV2-RETIRE-003: a stub carries sync METADATA only -- no legacy item arrays. Content
			-- lives in the V2 store; `mail` keeps the shape the MULTIPC-001 gate and the status bar
			-- read (`lastScan`, `slots`), minus the rows.
			self.Info.alts[norm] = {
				name = norm,
				version = 0,
				money = 0,
				inventoryHash = 0,
				mail = { slots = { count = 0, total = 0 }, lastScan = 0, version = 0 },
				mailHash = 0,
			}
			TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "Added missing banker stub data for %s", norm)
		end
	end

	-- ROSTER-002: Remove zero-data stubs for alts no longer in the banker roster.
	-- RebuildBankerRoster() creates stubs when someone joins the banker list but never
	-- removed them when they left, causing permanent "HLR pending" phantom entries.
	-- Only remove stubs that have never received real data (version==0, inventoryHash==0,
	-- mailHash==0, nothing in the V2 store) — non-zero alts are never touched regardless of
	-- roster status. INV2-RETIRE-003: the item-array clauses became the store check.
	local Store = TOGBankClassic_Inventory_Store
	local removedStubs = 0
	for altName, alt in pairs(self.Info.alts) do
		if not newBanksLookup[altName] then
			local isZeroStub = (
				type(alt) == "table"
				and (not alt.version or alt.version == 0)
				and (not alt.inventoryHash or alt.inventoryHash == 0)
				and (not alt.mailHash or alt.mailHash == 0)
				and not (Store and self.Info.name and #Store:GetAltRecords(self.Info.name, altName) > 0)
			)
			if isZeroStub then
				self.Info.alts[altName] = nil
				removedStubs = removedStubs + 1
				TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "ROSTER-002: Removed stale zero-stub for ex-banker %s", altName)
			end
		end
	end
	if removedStubs > 0 then
		TOGBankClassic_Output:Info("Cleaned %d stale ex-banker stub(s) from database", removedStubs)
	end

	-- P2P-035: a banker account numbers whatever the roster now holds unnumbered. No-op for an
	-- account that owns no banker, and for a roster with nothing new.
	if TOGBankClassic_BankerNumbers then
		TOGBankClassic_BankerNumbers:Mint()
	end

	-- An embedded Requests tab re-checks its role here (BROWSE F1) -- after banksCache is rebuilt
	-- above, so IsBank answers from the new list.
	if rosterChanged and TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.OnBankerRosterChanged then
		TOGBankClassic_UI_Requests:OnBankerRosterChanged()
	end
end

function TOGBankClassic_Guild:GetRosterAlts()
	if not self.Info then
		return nil
	end

	local roster = self.Info.roster
	local list = {}

	if roster and roster.alts then
		for _, v in pairs(roster.alts) do
			if type(v) == "string" and v ~= "" then
				table.insert(list, v)
			end
		end
	end

	if #list > 0 then
		return list
	end

	for name, alt in pairs(self.Info.alts or {}) do
		if type(alt) == "table" then
			table.insert(list, name)
		end
	end

	if #list == 0 then
		return nil
	end

	return list
end

function TOGBankClassic_Guild:HasAltData(alt)
	if not alt or type(alt) ~= "table" then
		return false
	end
	if alt.version and alt.version > 0 then
		return true
	end
	if alt.inventoryHash and alt.inventoryHash > 0 then
		return true
	end
	-- INV2-RETIRE-003: the `alt.items` clause is gone with the rows. A record with data has a
	-- version or a hash; contents are the V2 store's (HasAltContent), not this record's.
	return false
end

--- Does this client hold any inventory for `altName`?
---
--- THE NEGOTIATION LAYER'S GATE, and it decides far more than its name suggests: ~10 call sites use
--- it to answer "may I offer this alt's data", "should I respond to this query", "did the peer
--- actually deliver", and "how many bankers do I have". A false answer does not merely hide items --
--- it makes the client tell the guild it has nothing, so it never offers data and keeps re-asking.
---
--- INV2-RETIRE-003: THE V2 STORE IS THE ONLY ANSWER. This used to fall through to the legacy
--- record's four item arrays when the store held nothing -- the "half implemented" period where a
--- client populated over the tuple wire had data in V2 and nothing in `alt.items`. Now the store
--- is what the scan writes, what SendAltData ships (CanServe is `#records > 0`, the same test), and
--- what the strip will leave; a legacy-only record is content this client cannot serve, so saying
--- "yes" for it is the Peer Review F1 defect (accept a request, ship nothing) reintroduced.
--- `alt` is accepted for the debug line and for callers that pass only the record, and is no longer
--- consulted for content.
function TOGBankClassic_Guild:HasAltContent(alt, altName)
	local Store = TOGBankClassic_Inventory_Store
	local name = altName or (type(alt) == "table" and alt.name) or nil
	if Store and self.Info and self.Info.name and name then
		local norm = self:NormalizeName(name) or name
		if #Store:GetAltRecords(self.Info.name, norm) > 0 then
			TOGBankClassic_Output:Debug("DELTA", "VALIDATE",
				"[CONTENT-CHECK] %s: satisfied by the V2 store", norm)
			return true
		end
	end
	TOGBankClassic_Output:Debug("DELTA", "VALIDATE", "[CONTENT-CHECK] %s: no V2 records", tostring(name or "unknown"))
	return false
end

--- The revision-2 canon we can actually SERVE for an alt, or nil.
---
--- HASH-CANON-009. A canon is a promise: "ask me and I will send you this version". Every path that
--- delivers data sends TUPLES from the V2 store and nothing else (SendAltData), so a record whose
--- canon sits beside legacy-only content -- or beside nothing, the hash-list stub -- is a promise
--- this client cannot keep. Read off the operator's own account on 2026-09-10: 36 records carried a
--- canon and 10 had tuple data; the other 26 were revision-1 data wearing a re-encoded canon. Every
--- advertiser (the hash-list reply, both offer emitters, the version broadcast) used to read
--- `alt.inventoryHashV2` directly, so a viewer was told "a newer version exists", requested it, and
--- the responder's SendAltData found no records and sent nothing -- a request wasted every cycle,
--- and the requester's tab stuck on red for a version nobody could deliver.
---
--- So: advertise a canon only while the V2 store holds records for that alt. A canon-less or
--- record-less copy advertises nil, which every comparison already reads as "no version to offer" --
--- "v1 is always red" applied on the SENDING side, the same rule the offer compare follows.
--- One spelling through CanonFrom so a v1.4.0 number is re-encoded here exactly as it is everywhere.
---@param norm string normalized alt name
---@return string|nil canon
function TOGBankClassic_Guild:ServableCanon(norm)
	local alt = self.Info and self.Info.alts and norm and self.Info.alts[norm]
	if type(alt) ~= "table" or alt.inventoryHashV2 == nil then return nil end
	if not self:CanServe(norm) then return nil end
	return TOGBankClassic_DeltaComms:CanonFrom(alt.inventoryHashV2, alt.inventoryUpdatedAt or alt.version)
end

--- Can this client actually DELIVER an alt's data? Exactly SendAltData's own condition -- tuple
--- records in the V2 store -- and nothing else.
---
--- Peer Review F1 (2026-09-10): "can I deliver this" had THREE spellings -- HasAltContent (legacy
--- items OR tuples), ServableCanon (tuples AND canon), and SendAltData's `#records > 0`. The
--- sync-request gate used the first, so a peer holding LEGACY-ONLY content accepted a request,
--- took a slot, and SendAltData then shipped nothing; the requester's 180-second delivery watchdog
--- ran out before it learned anything. HandleSyncRequest and ServeQueue gate on this now, and
--- ServableCanon is this plus a canon -- one predicate with a qualifier, not three peers.
---@param norm string normalized alt name
---@return boolean
function TOGBankClassic_Guild:CanServe(norm)
	local Store = TOGBankClassic_Inventory_Store
	if not (Store and self.Info and self.Info.name and norm) then return false end
	-- MULTIPC-001: NOT OUR OWN CHARACTER WHILE A PUBLISH IS DEFERRED. A deferred scan has already
	-- written what this PC read into the store, but the canon still names the version published
	-- before it -- so what we would ship no longer matches the version we would claim it is. A
	-- canon is the identity of one set of contents; serving mismatched contents under it is the
	-- HASH-CANON-001 defect from the other side. Nothing is served for our own name until the
	-- gate releases and MintVersion stamps the contents we hold.
	local Bank = TOGBankClassic_Bank
	if Bank and Bank.deferred and norm == self:GetNormalizedPlayer() then return false end
	return #Store:GetAltRecords(self.Info.name, norm) > 0
end

function TOGBankClassic_Guild:GetBankerDataProgress()
	if not self.Info then
		return 0, 0
	end

	local rosterAlts = self:GetRosterAlts()
	if not rosterAlts or #rosterAlts == 0 then
		rosterAlts = self:GetBanks()
	end
	if not rosterAlts or #rosterAlts == 0 then
		return 0, 0
	end

	local have = 0
	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		if norm and self:HasAltContent(self.Info.alts and self.Info.alts[norm], norm) then
			have = have + 1
		end
	end

	return have, #rosterAlts
end

function TOGBankClassic_Guild:ReportBankerDataProgress(context, force)
	if TOGBankClassic_Options and TOGBankClassic_Options.IsSyncProgressMuted and TOGBankClassic_Options:IsSyncProgressMuted() then
		return
	end

	-- Defensive: Check if Info exists before attempting to access alts
	if not self.Info then
		TOGBankClassic_Output:Debug("SYNC", "ReportBankerDataProgress: self.Info is nil, cannot report progress")
		return
	end

	local rosterAlts = self:GetRosterAlts()
	if not rosterAlts or #rosterAlts == 0 then
		rosterAlts = self:GetBanks()
	end
	if not rosterAlts or #rosterAlts == 0 then
		return
	end

	local have = 0
	local total = #rosterAlts
	local addedNames = {}
	self.bankerProgressKnown = self.bankerProgressKnown or {}
	local lastHave = self.lastBankerProgress or -1

	-- Reset completion tracking if roster size changes
	if self.lastBankerProgressTotal ~= total then
		self.lastBankerProgressTotal = total
		self.bankerProgressComplete = false
		self.bankerProgressKnown = {}
		lastHave = -1
		self.lastBankerProgress = lastHave
	end

	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		local hasContent = norm and self:HasAltContent(self.Info.alts and self.Info.alts[norm], norm)
		if hasContent then
			have = have + 1
			if lastHave >= 0 and not self.bankerProgressKnown[norm] then
				table.insert(addedNames, norm)
			end
			self.bankerProgressKnown[norm] = true
		else
			self.bankerProgressKnown[norm] = nil
		end
	end

	-- If already complete and previously at full, suppress further progress spam
	if have >= total then
		if self.lastBankerProgress == total then
			self.bankerProgressBuffer = {}
			return
		end
		self.bankerProgressComplete = true
	else
		self.bankerProgressComplete = false
	end

	-- Aggregate banker names added in the same tick
	self.bankerProgressBuffer = self.bankerProgressBuffer or {}
	if context and context:find("received ") then
		local name = context:gsub("^received ", "")
		table.insert(self.bankerProgressBuffer, name)
		context = nil
	end

	local lastReported = self.lastBankerProgress or -1
	if force or have ~= lastReported then
		self.lastBankerProgress = have
		local delta = (lastHave >= 0) and (have - lastHave) or 0
		local deltaStr = (delta and delta ~= 0) and string.format(" (+%d)", delta) or ""
		local names = ""
		if addedNames and #addedNames > 0 then
			names = " (received " .. table.concat(addedNames, ", ") .. ")"
			self.bankerProgressBuffer = {}
		elseif self.bankerProgressBuffer and #self.bankerProgressBuffer > 0 then
			names = " (received " .. table.concat(self.bankerProgressBuffer, ", ") .. ")"
			self.bankerProgressBuffer = {}
		elseif context then
			names = " (" .. context .. ")"
		end
		TOGBankClassic_Output:Debug("SYNC", "PROGRESS", "Banker sync progress: %d/%d%s%s", have, total, deltaStr, names)
	end
end

-- Fast-fill - Request missing banker alts on UI open
-- Compares roster bankers against local alt data and queries for missing alts
-- SYNC-001 fix: Use current guild roster instead of cached roster to prevent
-- requesting data for bankers from other guilds
function TOGBankClassic_Guild:FastFillMissingAlts()
	return TOGBankClassic_DeltaComms:FastFillMissingAlts(self.Info)
end

--- INV2 step 7a: THE one place item rows come from.
---
--- Every UI module used to open-code "use `alt.items` if it has anything, otherwise aggregate
--- bank + bags + mail" -- six sites across three files, each free to drift. INVENTORY_V2.md 7.1
--- anticipated this: the V2 store exposes a view in the SAME shape the UI already consumes, so
--- the wiring is one accessor rather than six conditionals.
---
--- Returns an ARRAY of item rows, always -- never nil, so callers need no guard. The rows are
--- materialised from the store's tuples (cached per alt, dropped on write).
---
--- INV2-RETIRE-003: the `inventoryV2` switch, the `IsAltComplete` gate and the legacy fallback
--- that followed them are gone. The legacy rows are no longer written (Bank:Scan) and are stripped
--- on load (Database:Load), so there is nothing to fall back TO. The gate (INV2-STALE-001) chose
--- the legacy record over a schema-1 V2 record -- one scanned before INV2-MAIL-001, bags+bank and
--- no mail -- because a short total looks like data. Without the legacy record the choice is a
--- short total or an EMPTY one, and short wins: it heals on that banker's next mailbox visit, an
--- empty tab does not.
--- @param altName string  normalized alt name
--- @return table array of { ID = , Count = , Link = , Info = }
function TOGBankClassic_Guild:GetAltItems(altName)
	local info = self.Info
	local Store = TOGBankClassic_Inventory_Store
	if not info or not info.name or not Store then return {} end
	return Store:GetAltView(info.name, altName)
end

--- HIDDEN-MERGE-001: the rows a window DRAWS for `altName` -- `GetAltItems`, plus, when the alt is
--- the player's OWN bank, the rows they keep hidden from the guild (`Store:GetAltHiddenView`,
--- `Hidden = true`), so a right-click hide has a row to right-click back. The Inventory window's
--- own tab and the Browse tab each open-coded this merge (HIDE-001, HIDE-003); this is the one
--- site, and `hideitems_spec` pins that nothing else reads the hidden view. Every other consumer
--- -- Search, tooltips, TOGProfessionMaster, the wire -- reads `GetAltItems` and never sees them.
--- Returns a fresh array when a merge happens, so the store's cached view is never appended to.
--- @param altName string  normalized alt name
--- @return table array of item rows; the hidden ones carry `Hidden = true`
function TOGBankClassic_Guild:GetAltItemsWithOwnHidden(altName)
	local items = self:GetAltItems(altName)
	local info = self.Info
	local Store = TOGBankClassic_Inventory_Store
	if not (info and info.name and Store and Store.GetAltHiddenView) then return items end
	if altName ~= self:GetNormalizedPlayer() or not self:IsBank(altName) then return items end
	local hidden = Store:GetAltHiddenView(info.name, altName)
	if #hidden == 0 then return items end
	local merged = {}
	for _, row in ipairs(items) do merged[#merged + 1] = row end
	for _, row in ipairs(hidden) do merged[#merged + 1] = row end
	return merged
end

--- How many of `itemID` does `altName` hold? Zero when the alt or the item is unknown.
---
--- SELF-AUDIT FINDING 3. `TooltipBankerInfo` runs on GameTooltip's OnTooltipSetItem -- one of the
--- hottest paths in the client -- and its own header says it keeps a reusable table "to avoid
--- per-hover allocations". INV2 step 7a then replaced its direct `ipairs(alt.items)` walk with
--- `GetAltItems(altName)`, whose LEGACY branch builds and returns a FRESH ARRAY OF EVERY ITEM on
--- every call. So the accessor that fixed a correctness divergence introduced an allocation per
--- banker per hover, in the one file that had explicitly avoided them. INV2-STALE-001 then made it
--- worse by design: the schema gate deliberately routes MORE reads through that legacy branch.
---
--- This asks the question the caller actually has -- a total for ONE item -- so nothing needs to
--- materialise a list. Same source as GetAltItems, deliberately: the two must not disagree, which
--- is the whole point of 7a. INV2-RETIRE-003: the legacy branches went with GetAltItems'.
---
--- PERF-022 (audit finding 13), CLOSED with the delta release: the hover was still O(bankers x
--- items) because each banker's record set was scanned linearly. The store now keeps a per-alt
--- `itemID -> count` index (`Store:GetAltItemTotal`) built from its record cache on first ask and
--- dropped in the same `InvalidateView` call that drops the record cache -- so the index cannot
--- miss a writer unless the record cache already did, and INV2-ISOLATE-001 pins the writer set.
--- @param altName string  normalized alt name
--- @param itemID number
--- @return number
function TOGBankClassic_Guild:GetAltItemTotal(altName, itemID)
	local info = self.Info
	local Store = TOGBankClassic_Inventory_Store
	if not info or not info.name or not Store then return 0 end
	-- PERF-022: the store's per-alt itemID index, dropped with its record cache on every write.
	return Store:GetAltItemTotal(info.name, altName, itemID)
end

--- Units still owed on a request: quantity minus what the Sent column records, never negative.
--- THE ONE SPELLING (peer review F2, delta release step 5): this was written out at seven sites
--- across Mail, ItemHighlight and the Requests window, and two more tested `fulfilled < quantity`
--- for the same question. Says nothing about status -- a cancelled request can still "need" units
--- by this arithmetic, and every caller that cares gates on status beside it, as before.
---@param req table a request record
---@return number
function TOGBankClassic_Guild:RequestQuantityNeeded(req)
	if type(req) ~= "table" then return 0 end
	local needed = (tonumber(req.quantity) or 0) - (tonumber(req.fulfilled) or 0)
	return needed > 0 and needed or 0
end

function TOGBankClassic_Guild:IsBank(player)
	if not player then
		return false
	end
	local norm = self:NormalizeName(player) or player
	-- PERF: O(1) memberRoster lookup instead of iterating banksCache
	if self.memberRoster and self.memberRoster[norm] then
		return self.memberRoster[norm].isBank == true
	end
	-- Fallback: memberRoster not yet populated — check banksCache or scan
	local banks = TOGBankClassic_Guild:GetBanks()
	if not banks then
		return false
	end
	for _, v in pairs(banks) do
		if (self:NormalizeName(v) or v) == norm then
			return true
		end
	end
	return false
end

-- VIEWBANK-001: true if the banker is flagged view-only (visible but not
-- requestable). Mirrors IsBank's O(1) memberRoster lookup with a roster-scan
-- fallback for the brief window before memberRoster is built.
function TOGBankClassic_Guild:IsViewOnlyBank(player)
	if not player then
		return false
	end
	local norm = self:NormalizeName(player) or player
	if self.memberRoster and self.memberRoster[norm] then
		return self.memberRoster[norm].viewOnly == true
	end
	for i = 1, GetNumGuildMembers() do
		local name, _, _, _, _, _, publicNote, officer_note = GetGuildRosterInfo(i)
		if name and (self:NormalizeName(name) or name) == norm then
			return noteIsViewOnly(publicNote, officer_note)
		end
	end
	return false
end

--- BANKERS-FILTER-001 (operator 2026-09-13: "it might be nice to be able to provide metadata for
--- each banker, on the types of stuff they store when you're in a large guild with a lot of
--- bankers"): what the banker's public note says BESIDE the markers. The note already carries the
--- identity (`gbank`) and the view-only flag; whatever else the officer wrote there -- "gbank herbs,
--- potions", "gbank: raid mats" -- is the description, with the markers and the punctuation around
--- them stripped. "" for a banker with nothing but the marker, or one the roster has not cached.
---@param player string
---@return string
function TOGBankClassic_Guild:BankerStores(player)
	local norm = player and (self:NormalizeName(player) or player)
	local m = norm and self.memberRoster and self.memberRoster[norm]
	local note = m and m.note
	if type(note) ~= "string" or note == "" then return "" end
	local s = note
	for _, marker in ipairs({ "gbankro", "gbank", "view-only", "viewonly", "read-only", "readonly" }) do
		local at = s:lower():find(marker, 1, true)
		while at do
			s = s:sub(1, at - 1) .. " " .. s:sub(at + #marker)
			at = s:lower():find(marker, 1, true)
		end
	end
	s = s:gsub("^[%s%p]+", ""):gsub("[%s%p]+$", ""):gsub("%s%s+", " ")
	return s
end

function TOGBankClassic_Guild:GetAnyBanker()
	local banks = self:GetBanks()
	if not banks or #banks == 0 then
		return nil
	end
	-- Return the first banker (normalized)
	return self:NormalizeName(banks[1])
end

function TOGBankClassic_Guild:BuildBankerHashList()
	local list = {}
	-- Prefer live GetBanks() (derived from current memberRoster) over persisted GetRosterAlts(),
	-- which reads Info.roster.alts from SavedVariables and may contain stale ex-bankers.
	local rosterAlts = self:GetBanks() or self:GetRosterAlts() or {}
	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		if norm then
			local alt = self.Info and self.Info.alts and self.Info.alts[norm]
			local hash = (alt and alt.inventoryHash) or 0
			local updatedAt = (alt and (alt.inventoryUpdatedAt or alt.version)) or 0
			local version = (alt and alt.version) or 0
			local mailHash = (alt and alt.mailHash) or 0
			local mailUpdatedAt = (alt and alt.mail and alt.mail.version) or 0
			-- Always include roster alts even with hash=0 — this is the correct wipe-recovery
			-- signal. Peers compare their stored hash vs our hash=0 and send offers for alts
			-- we're missing. Peers who also have hash=0 for an alt won't offer. Safe.
			-- HASH-REV-001 shape 1 of 5. `hashV2` rides ALONGSIDE `hash`, never replacing it: an old
			-- receiver indexes by name and is unaffected by a sixth field, and `mailHash` is the
			-- precedent -- two hashes in one entry is a shape this table already has.
			-- HASH-CANON-009: only a canon we can deliver is advertised (ServableCanon).
			list[norm] = {
				hash = hash,
				hashV2 = self:ServableCanon(norm),
				updatedAt = updatedAt,
				version = version,
				mailHash = mailHash,
				mailUpdatedAt = mailUpdatedAt,
			}
		end
	end
	return list
end

--- Does our stored state for an alt agree with what a peer advertised for it?
---
--- HASH-REV-002, and audit finding 36's class. This comparison existed THREE times, byte for byte:
--- `IsAltSyncPending` and `ReportHashListCoverage` here, and the HLR compare in `Chat.lua`. They
--- agreed today and nothing kept them agreeing -- and the very next change to this comparison is
--- HASH-REV-001's hash-revision negotiation (audit finding 37), which would otherwise be written
--- three times and diverge the first time one copy was fixed and the others were not. Collapsing
--- it BEFORE that change is the point; afterwards is too late.
---
--- A nil field in the summary is NOT a wildcard, and that is load-bearing rather than defensive.
--- `hash == 0` means "empty inventory" and must match only another 0; an ABSENT field means the
--- peer said nothing about it, which cannot be read as agreement. Treating either as a match makes
--- a client skip a sync it needs.
---@param localAlt table|nil our stored record for the alt, may be absent
---@param summary table|nil the peer's advertised entry: { hash, mailHash, ... }
---@return boolean matches true only when BOTH hashes are present and equal
---@return number localHash our inventory hash, 0 when we hold nothing
---@return number localMailHash our mail hash, 0 when we hold nothing
--- HASH-REV-001: the revision negotiation lives HERE, in the one comparison, which is the whole
--- reason HASH-REV-002 collapsed the four copies first. Revision 2 is used only when BOTH sides
--- advertise it; otherwise both fall back to the frozen revision 1, which every client computes.
--- A migrated and an unmigrated peer therefore still agree, on revision 1, and no release has to be
--- coordinated -- see audit finding 37 and `docs/LIBRARY_CONTRACTS.md`'s frozen-value rule.
function TOGBankClassic_Guild:HashesAgreeWith(localAlt, summary)
	local localHash     = localAlt and localAlt.inventoryHash or 0
	local localMailHash = localAlt and localAlt.mailHash or 0
	if not summary then
		return false, localHash, localMailHash
	end

	-- Negotiate DOWN to what both sides can compute, never up. `nil` on either side means that peer
	-- does not speak revision 2, so revision 1 is the only shared language.
	-- HASH-CANON-005: both sides through CanonFrom, so a v1.4.0 numeric canon on either side is
	-- compared in the same `<dts><hash>` encoding as the other -- a number and its own re-encoding
	-- are the same publish and must agree.
	local DC = TOGBankClassic_DeltaComms
	local theirV2 = DC:CanonFrom(summary.hashV2, summary.updatedAt)
	local ourV2   = localAlt and DC:CanonFrom(localAlt.inventoryHashV2, localAlt.inventoryUpdatedAt or localAlt.version)
	local inventoryHashMatches
	if theirV2 ~= nil and ourV2 ~= nil then
		inventoryHashMatches = (theirV2 == ourV2)
	elseif theirV2 ~= nil then
		-- HASH-CANON-006: THE PEER HOLDS A CANON AND WE HOLD NONE. This used to negotiate DOWN to
		-- revision 1, which was right while a guild ran mixed versions and is exactly wrong now
		-- that it does not (the no-backwards-compatibility directive): a copy received before the
		-- canon existed carries the same revision-1 number as the banker's current scan -- read
		-- off the live guild, Alchemyrcp: banker 808855588 with a canon, viewer 808855588 with
		-- none -- so revision 1 said "in sync", nothing was ever requested, the viewer could never
		-- ACQUIRE a canon, and the tab read "v1" forever. Fetching is the only way to get one.
		inventoryHashMatches = false
	else
		-- Neither side has a canon, or only we do: revision 1 is the only shared language, and a
		-- peer with no canon cannot give us anything better than what we hold.
		inventoryHashMatches = (summary.hash ~= nil and summary.hash == localHash)
	end

	-- READ THIS BEFORE COPYING THE BLOCK ABOVE: mail's nil-handling is DELIBERATELY THE OPPOSITE of
	-- inventory's, in adjacent lines of one function, and nothing else says so.
	--
	--   inventory (above) -- a nil is a NEGOTIATION SIGNAL. It degrades to the shared revision.
	--   mail      (here)  -- a nil is a PERMANENT NO. There is no fallback and no revision.
	--
	-- Fail-closed is RIGHT while mail has exactly one revision: a missing mailHash then means a
	-- broken or non-publishing sender, not an older dialect, and treating it as agreement would hide
	-- that. It is not right by accident, and it is not a template.
	--
	-- WHAT IT COSTS IF COPIED: HASH-CANON-004 was this line failing closed for every remote alt at
	-- once, because a regression stopped the wire carrying mailHash at all -- so nothing could ever
	-- agree, everything read as permanently pending, and it re-requested forever: a broadcast storm
	-- of exactly the shape the canon-hash work removes. 713 examples were green throughout.
	--
	-- So IF MAIL EVER GAINS A REVISION 2, this line must grow the negotiation the block above has,
	-- not keep this shape. Written in the shape below, a peer on the older build sends mailHash and
	-- not mailHashV2, every mixed-version pair disagrees permanently, and it passes every spec that
	-- stubs both sides as current.
	local mailHashMatches = (summary.mailHash ~= nil and summary.mailHash == localMailHash)
	return (inventoryHashMatches and mailHashMatches), localHash, localMailHash
end

--- Record what a peer ADVERTISES for an alt, in the one cache every "is this alt behind?" question
--- is answered from -- the tab colour, the re-request decision, /togbank hashdebug.
---
--- HASH-CACHE-001. THE OPERATOR'S RULE, VERBATIM: "I NEED CANON hashes written ONCE by the banker,
--- then passed around. NEVER mutated. The hash HAS to have the DTS in it and the NEWER V2 Hash
--- wins." And the failure it was written from: "the banker logged off and then I was getting the
--- mutated V1 hash that was 'newer' and it was over-writing my V2 data."
---
--- Three writers used to feed this cache with three different rules: the hash-list reply
--- overwrote unconditionally (last writer wins), the P2P offer path kept the newest by time but
--- DROPPED hashV2 as it copied, and the login seed wrote local data. So the cache held whatever
--- arrived last, and a stale relayer advertising a recomputed revision-1 number for an alt this
--- client already held the author's V2 canon for turned the tab red and triggered a re-request
--- from a peer whose payload it cannot read. Reported from a live guild, twice.
---
--- The rule, applied identically by every writer:
---   1. OUR OWN CHARACTER IS NEVER OVERWRITTEN BY A PEER. This cache drives FETCHING, and we never
---      fetch our own bank: the local record is the only copy with the per-source split a scan
---      needs (MULTIPC-001). This used to add "nothing anyone else says about us can be newer than
---      what we hold" -- false on a shared account played from several PCs, where a peer CAN hold
---      a version this PC never saw. That case is tracked by `newestAdvertisedAt`, which accepts
---      claims about our own name, and answered by re-reading, not by fetching.
---   2. A V2 claim (hashV2 present) and a revision-1-only claim are not in the same contest. V2
---      ALWAYS displaces V1-only, whatever the times say; V1-only NEVER displaces V2. A
---      revision-1-only number is one an unmigrated client minted for itself and stamped with its
---      own clock -- exactly the "newer" that did the damage -- so its time proves nothing.
---   3. Within the same revision the NEWER publish time wins, strictly. Equal time keeps what we
---      hold: a re-advertisement of the same version changes nothing, and a different number at
---      the same time is a mutation, which cannot prove itself newer.
--- The entry is stored WHOLE -- hashV2 included -- never copied field by field.
---@param norm string normalized alt name
---@param summary table { hash, hashV2, updatedAt, mailHash, ... } as advertised
---@param sender string|nil who advertised it; a claimant that cannot serve us is ignored (WIRE-SKEW-008)
---@return boolean accepted whether the cache now holds this summary
function TOGBankClassic_Guild:NoteAdvertisedHashes(norm, summary, sender)
	if not norm or type(summary) ~= "table" then return false end
	if not self:ClaimantCanServe(sender) then return false end
	-- Only current bankers: rejects stale ex-banker entries a sender may still carry in its SV.
	if not self:IsBank(norm) then return false end
	if norm == self:GetNormalizedPlayer() then return false end

	self.latestBankerHashes = self.latestBankerHashes or {}
	local held = self.latestBankerHashes[norm]
	if held then
		local heldV2, theirV2 = held.hashV2 ~= nil, summary.hashV2 ~= nil
		if heldV2 ~= theirV2 then
			if not theirV2 then return false end   -- rule 2: V1-only never displaces V2
		else
			local heldAt, theirAt = tonumber(held.updatedAt) or 0, tonumber(summary.updatedAt) or 0
			if theirAt <= heldAt then return false end   -- rule 3: strictly newer, same revision
		end
	end
	self.latestBankerHashes[norm] = summary
	return true
end

--- TABCOLOUR-002: the Inventory tab colour, and the rule it follows -- THE OPERATOR'S, verbatim:
--- "it has to ask which is newer, but v1 didn't do that well, with v2 we can. we need it to be
--- newer, so v1 is always red, v2 does it by is someone newer."
---
--- Every V2 canon is `<dts><hash>` (HASH-CANON-005): written once by the banker, the publish time
--- readable off its front, carried unchanged. So "am I behind?" is not a question about hash
--- EQUALITY against whatever a peer last said -- that is what the tabs did until today, and it took
--- minutes to settle and was wrong for bankers whose copy was already current, because a claim can
--- be a copy-of-a-copy or a number an old client minted, and "not equal" cannot tell newer from
--- older from garbage. It is one comparison of two times read off two canons:
---
---   the newest V2 canon ANYONE has mentioned for this banker
---   against the canon on the copy I hold.
---
--- `newestAdvertisedAt[norm]` is the publish time off the newest such canon. Every message that
--- carries a V2 canon for an alt raises it (never lowers it -- a stale relayer cannot regress it),
--- and it ignores claims with no readable canon (a revision-1 number says nothing about recency).
--- It converges on the first message that mentions the newest version and repaints, so the tab is
--- right in seconds rather than after the sync cycle, and it goes yellow the instant the newer copy
--- lands because delivery stores the author's canon on the record.
---
--- MULTIPC-001: CLAIMS ABOUT OUR OWN CHARACTER ARE RECORDED TOO. This used to refuse them -- "we
--- are the author, a peer cannot know a newer version of our bank than we do" -- and that is only
--- true when ONE computer ever plays the character. The operator's guild runs its bankers on a
--- shared account that several PCs log into, each with its own SavedVariables, so the PC logging in
--- today can hold a copy WEEKS older than the version another PC published yesterday. The peers
--- are right and this client is behind on itself. What the entry drives for our own name is the
--- tab (red, with a tooltip saying what to do) and Bank:Scan's publish gate; it never drives a
--- fetch, because the local record is the only copy with the per-source split a scan needs (see
--- NewerSelfVersionAt). The hash CACHE keeps its self-guard for that reason (HASH-CACHE-001).
TOGBankClassic_Guild.newestAdvertisedAt = {}

--- CLAIM-TRACE-001: WHO raised the time beside it -- `{ peer, canon, at }` per banker, for
--- `/togbank dev trace`. Declared HERE, next to the table it shadows, and wiped in the SAME block on
--- Init, because the first cut created it lazily inside NoteAdvertisedPublishTime and was therefore
--- missed by that wipe: switching guilds left it naming a peer from the previous one, and a
--- diagnostic built to identify a culprit would have named the wrong player with confidence.
TOGBankClassic_Guild.newestAdvertisedBy = {}

--- The canon an advertised entry carries, re-encoded if it is a v1.4.0 numeric one, or nil.
local function advertisedCanon(summary)
	local DC = TOGBankClassic_DeltaComms
	if not (DC and DC.CanonFrom) then return nil end
	return DC:CanonFrom(summary.hashV2, summary.updatedAt)
end

--- HASH-CANON-005: normalise an advertised entry's revision-2 slot IN PLACE at the point it enters
--- this client, so every reader downstream -- the cache, HashesAgreeWith, the stub seed, the tab
--- colour -- sees a `<dts><hash>` string or nil and never a number. Called once per entry at each
--- receive path (hash-list reply, hash-offer, hash-list broadcast). Idempotent.
---@param summary table as advertised
---@return table summary the same table
function TOGBankClassic_Guild:CanonicaliseSummary(summary)
	if type(summary) == "table" and summary.hashV2 ~= nil then
		summary.hashV2 = advertisedCanon(summary)
	end
	return summary
end

--- Record the publish time read off a canon a peer advertised for an alt. Returns true if it RAISED
--- the known newest time, which is the only event that can turn a tab red.
---
--- CLAIM-TRACE-001: WHO SAID SO IS RECORDED BESIDE IT. A red tab's whole content is "somebody has
--- a newer copy than yours", and until now nothing anywhere kept which somebody -- so when a banker
--- reads Behind against a version its own author never published (CANON-TIME-001 was one way that
--- happens, and it will not be the last), the one question that identifies the culprit could not be
--- answered from a live client at all. It cost a session of reading SavedVariables to get a
--- MECHANISM and it still could not name the peer. `newestAdvertisedBy[norm]` is session-only, one
--- small table, written on the same raise that moves the tab; `/togbank dev trace` prints it.
---@param norm string normalized alt name
---@param summary table as advertised: { hash, hashV2, updatedAt, ... }
---@param sender string|nil who advertised it, for the trace. Optional: a caller that does not know
---       (or a spec driving the raise alone) still raises the time, it is simply unattributed.
---@return boolean raised
function TOGBankClassic_Guild:NoteAdvertisedPublishTime(norm, summary, sender)
	if not norm or type(summary) ~= "table" then return false end
	local canon = advertisedCanon(summary)
	local at = canon and TOGBankClassic_DeltaComms:CanonPublishTime(canon) or 0
	if not self:ClaimantCanServe(sender) then
		-- TAB-STATE-003: the claim moves nothing (WIRE-SKEW-008), but it is remembered as what it
		-- is -- a newer copy held where this release cannot fetch it -- for the grey tab state.
		self:NoteRefusedNewer(norm, at, sender)
		return false
	end
	if at <= 0 then return false end                      -- no readable canon: nothing to compare
	if not self:IsBank(norm) then return false end
	self.newestAdvertisedAt = self.newestAdvertisedAt or {}
	if at <= (self.newestAdvertisedAt[norm] or 0) then return false end
	self.newestAdvertisedAt[norm] = at
	-- TAB-STATE-003: a CAPABLE claim of the same or a newer version than a refused peer's makes
	-- the refused one irrelevant -- the copy is fetchable after all; the tab goes red then yellow.
	if self.refusedNewerBy and self.refusedNewerBy[norm] and at >= self.refusedNewerBy[norm].at then
		self.refusedNewerBy[norm] = nil
	end
	-- The `or {}` matches its sibling two lines up and is a nil-guard for the specs that drive a
	-- raise without running Init (which is what creates the table). NOT the lazy creation that
	-- caused the guild-switch leak -- that was the ABSENCE of a declaration and of a wipe; both
	-- exist now (see the header and Guild:Init).
	self.newestAdvertisedBy = self.newestAdvertisedBy or {}
	self.newestAdvertisedBy[norm] = { peer = sender and self:NormalizeName(sender) or nil, canon = canon, at = at }
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.RefreshSoon then
		TOGBankClassic_UI_Inventory:RefreshSoon()
	end
	return true
end

--- TABCOLOUR-003: A BARE OFFER TURNS THE TAB RED. The operator: "if someone replies that they have a
--- newer data set than us, we need to make that bankers tab go red until we can get it. we've done a
--- great job in clearing the red, now we need to do just as good a job as setting the red."
---
--- Since P2P-035 an offer is banker NUMBERS ONLY -- it names no version, so it cannot raise
--- `newestAdvertisedAt` and, before this, moved no tab: the reply to our own broadcast, the one
--- message that exists to say "I hold newer than what you just advertised", left the tab yellow
--- until the data landed. But that reply IS the claim, judged by the sender against the canon we
--- broadcast (`mine > theirs`, Chat.lua). So it is recorded here as "a peer says newer", red, and it
--- clears on exactly two events: the fetch lands for that alt (any delivery stores the author's
--- canon, and `newestAdvertisedAt` keeps it red if that copy is still behind), or the version query
--- establishes that nobody who offered actually holds anything that improves ours (a peer whose scan
--- had not finished answers "nothing servable"). Session-scoped, like `newestAdvertisedAt`.
TOGBankClassic_Guild.newerOfferedBy = {}

--- A peer has offered a newer copy of an alt without naming the version. Returns true if this is
--- the first such offer for the alt (the only event that repaints).
---@param norm string normalized alt name
---@param peer string the offering peer
---@return boolean raised
function TOGBankClassic_Guild:NoteNewerOffered(norm, peer)
	if not norm or not peer then return false end
	if norm == self:GetNormalizedPlayer() then return false end
	if not self:IsBank(norm) then return false end
	self.newerOfferedBy = self.newerOfferedBy or {}
	if self.newerOfferedBy[norm] then return false end
	self.newerOfferedBy[norm] = peer
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.RefreshSoon then
		TOGBankClassic_UI_Inventory:RefreshSoon()
	end
	return true
end

--- TAB-STATE-003 (Peer Review 498a84f3 F3): A NEWER COPY EXISTS, BUT ONLY WHERE THIS RELEASE CANNOT
--- FETCH IT. WIRE-SKEW-008 drops every claim from a peer that cannot complete the data leg, so a
--- bank whose ONLY newer holder is a v1.4.1 client read "Current" here -- true of what could be
--- fetched, false of what exists. `refusedNewerBy[norm]` = { peer=, version=, at= } is the newest
--- such claim, kept only while it is newer than what we hold; GetAltStaleness answers "refused"
--- (grey) from it, and only while no CAPABLE peer has claimed the same or newer (that claim wins:
--- red, then yellow when it lands -- NoteAdvertisedPublishTime drops this record on it). Session
--- memory, wiped with newerOfferedBy on Init. No wire: nothing is asked of the refused peer.
TOGBankClassic_Guild.refusedNewerBy = {}

--- A claim naming a version published at `at` arrived from `sender`, who cannot serve it to us.
--- Recorded when it is newer than the copy held and than any refused claim before it.
---@param norm string normalized alt name
---@param at number the claimed canon's publish time (0 for none)
---@param sender string|nil
---@return boolean recorded
function TOGBankClassic_Guild:NoteRefusedNewer(norm, at, sender)
	if not (norm and sender) or (tonumber(at) or 0) <= 0 then return false end
	if norm == self:GetNormalizedPlayer() or not self:IsBank(norm) then return false end
	local alt = self.Info and self.Info.alts and self.Info.alts[norm]
	local heldAt = alt and TOGBankClassic_DeltaComms:CanonPublishTime(alt.inventoryHashV2) or 0
	if at <= heldAt then return false end
	self.refusedNewerBy = self.refusedNewerBy or {}
	local cur = self.refusedNewerBy[norm]
	if cur and cur.at >= at then return false end
	local peer = self:NormalizeName(sender) or sender
	self.refusedNewerBy[norm] = { peer = peer, version = self:ObservedAddonVersion(sender, peer), at = at }
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.RefreshSoon then
		TOGBankClassic_UI_Inventory:RefreshSoon()
	end
	return true
end

--- The offer has been answered: the data landed, or the query found nobody really holds newer.
---@param norm string normalized alt name
---@return boolean cleared
function TOGBankClassic_Guild:ClearNewerOffered(norm)
	if not (norm and self.newerOfferedBy and self.newerOfferedBy[norm]) then return false end
	self.newerOfferedBy[norm] = nil
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.RefreshSoon then
		TOGBankClassic_UI_Inventory:RefreshSoon()
	end
	return true
end

--- How current the copy we hold for an alt is, for the Inventory tabs.
---
--- States, and the rule each comes from:
---   "none"    -- we hold nothing for this banker. Red.
---   "v1"      -- we hold a copy with no V2 canon: it predates the current format, or its author
---                has not scanned since upgrading. Red, full stop -- "v1 is always red".
---   "behind"  -- someone has advertised a V2 canon published LATER than the one we hold. Red.
---   "offered" -- a peer has offered a newer copy without naming its version (TABCOLOUR-003). Red
---                until it lands or the version query clears it.
---   "refused" -- a newer copy exists, but the ONLY peer claiming it cannot send it to this release
---                (TAB-STATE-003). Grey: nothing is on its way. Gone the moment a capable peer claims
---                the same or newer (red), or the copy we hold catches up.
---   "current" -- nobody has mentioned anything newer. Yellow.
--- MULTIPC-001: our own character CAN be "behind" -- another PC on the same account published a
--- later version than the copy this PC holds -- and for our own name that state wins over "none"
--- and "v1", because its tooltip is the one that says what fixes it (open the bank and the
--- mailbox on this PC; see Bank:Scan's publish gate). It is never "offered": a bare offer names no
--- version, and for our own name the version query settles it into "behind" or nothing.
---@param norm string normalized alt name
---@return string state
---@return number heldAt 0 when unknown
---@return number newestAt 0 when nobody has said
---@return string|nil peer the peer whose offer holds the tab red ("offered"), or whose refused
---        claim holds it grey ("refused")
---@return string|nil version for "refused": the addon version that peer was seen on, or nil
function TOGBankClassic_Guild:GetAltStaleness(norm)
	local alt = self.Info and self.Info.alts and self.Info.alts[norm]
	local newestAt = (self.newestAdvertisedAt and self.newestAdvertisedAt[norm]) or 0
	local isSelf = norm == self:GetNormalizedPlayer()
	if isSelf then
		local newer = self:NewerSelfVersionAt()
		if newer then
			local heldAt = alt and TOGBankClassic_DeltaComms:CanonPublishTime(alt.inventoryHashV2) or 0
			return "behind", heldAt, newer
		end
	end
	if not alt or not self:HasAltContent(alt, norm) then
		return "none", 0, newestAt
	end
	-- The time is read off the CANON, not off a sidecar field: a record whose revision-2 slot
	-- holds no readable canon has no version we can place in time, whatever else it carries.
	local heldAt = TOGBankClassic_DeltaComms:CanonPublishTime(alt.inventoryHashV2)
	if not heldAt then
		return "v1", 0, newestAt
	end
	if not isSelf then
		if newestAt > heldAt then
			return "behind", heldAt, newestAt
		end
		local offeredBy = self.newerOfferedBy and self.newerOfferedBy[norm]
		if offeredBy then
			return "offered", heldAt, newestAt, offeredBy
		end
		-- TAB-STATE-003: last, so red and yellow win over it; only while the refused claim is still
		-- newer than the copy held (the record is not cleared on delivery, the compare retires it).
		local refused = self.refusedNewerBy and self.refusedNewerBy[norm]
		if refused and refused.at > heldAt then
			return "refused", heldAt, newestAt, refused.peer, refused.version
		end
	end
	return "current", heldAt, newestAt
end

--- MULTIPC-001: IS THIS PC BEHIND ON ITS OWN CHARACTER? The publish time of a version of our own
--- bank that a peer has named and this PC does not hold, or nil when nobody has named one.
---
--- The operator's guild: "we have a SHARED account many PC's in different states log into. so their
--- data COULD be out of date until they open their bags/mail/bank." Each PC keeps its own
--- SavedVariables, so the copy this PC holds of its own character can be older than what the guild
--- holds. Two things read this: the tab (red until this PC re-reads and republishes) and Bank:Scan,
--- which will not mint a new version over a source this PC has not read since that publish -- a
--- bags-only scan on a stale PC would otherwise stamp a weeks-old vault as today's and every peer
--- would adopt it over the correct copy.
---
--- Read off the same table as every other tab (newestAdvertisedAt) against the canon we hold, the
--- same compare as "behind" for any other banker. A copy with no readable canon is behind any named
--- version at all.
---@return number|nil publishedAt
function TOGBankClassic_Guild:NewerSelfVersionAt()
	local me = self:GetNormalizedPlayer()
	local newestAt = me and self.newestAdvertisedAt and self.newestAdvertisedAt[me] or 0
	if newestAt <= 0 then return nil end
	local alt = self.Info and self.Info.alts and self.Info.alts[me]
	local heldAt = alt and TOGBankClassic_DeltaComms:CanonPublishTime(alt.inventoryHashV2) or 0
	if newestAt > heldAt then return newestAt end
	return nil
end

--- MULTIPC-002 (docs/DELTA_RELEASE.md section 3.5): a peer has named a version of OUR OWN character
--- newer than the one this PC holds, and that peer HOLDS it -- a hash-list reply, a broadcast and a
--- version reply all list what their sender can serve. Recorded for Bank, which fetches it as the
--- diff base when this PC has re-read everything. One helper so the three message paths that learn
--- it cannot each spell the "newer than what I hold" test differently. Nothing for another name.
---@param canon string|nil the canon the peer named for our character
---@param peer string|nil normalized peer name
---@return boolean recorded
function TOGBankClassic_Guild:NoteSelfHolder(canon, peer)
	local Bank = TOGBankClassic_Bank
	if not (canon and peer and Bank and Bank.NoteNewerSelfVersion) then return false end
	if not self:ClaimantCanServe(peer) then return false end   -- WIRE-SKEW-008
	local me = self:GetNormalizedPlayer()
	local alt = self.Info and self.Info.alts and me and self.Info.alts[me]
	local held = alt and alt.inventoryHashV2 or nil
	-- SYNCED-001: a peer naming the version we HOLD has received it -- the propagation tracker's
	-- third source (the other two are Sync's delivered reply and its no-change).
	if held ~= nil and canon == held and TOGBankClassic_Propagation then
		TOGBankClassic_Propagation:NoteHolder(me, canon, peer)
		return false
	end
	if not self:CanonIsNewer(canon, held) then return false end
	return Bank:NoteNewerSelfVersion(canon, { peer })
end

--- CAN WHAT A PEER ADVERTISES IMPROVE THE COPY WE HOLD? The one question behind every decision to
--- ask for an alt's data: a hash-offer (P2PSession:OfferIsUseful), the hash-list reply compare in
--- Chat.lua, IsAltSyncPending (which drives catch-up), and BroadcastP2PRequest's skip guard.
---
--- P2P-034. It had TWO spellings. Offers used the publish-time rule below (P2P-032); the hash-list
--- reply, catch-up and the broadcast guard used HashesAgreeWith -- EQUALITY, "is this the same
--- version?" -- and requested on any difference. Read off a viewer on 2026-09-10: a hash-list reply
--- from a peer holding revision-1 copies of everything produced 26 guild broadcasts, Togweapons and
--- Toglowweap among them -- banks the viewer held CURRENT, with the author's canon -- and every one
--- timed out at 5s, because nobody had anything newer to send. "Not equal" cannot tell newer from
--- older from garbage; only a publish time can, and only a canon carries one.
---
--- The rule, the operator's ("v1 is always red, v2 does it by is someone newer"), same as the tab:
---   * we hold nothing            -> yes, if the claim carries anything at all (hash or canon)
---   * the claim has no canon     -> no: revision-1 data cannot improve a copy, whatever its hash
---   * we hold no canon           -> yes: fetching is the only way to acquire one (HASH-CANON-006)
---   * both canons                -> yes only if theirs was PUBLISHED later. Same time and a different
---                                   number is a mutation, which cannot prove itself newer.
--- Our own character is never improvable by a FETCH: the local record is the only copy with the
--- per-source split a scan needs, so a newer version of ourselves on another PC (MULTIPC-001) is
--- answered by re-reading the sources here, never by adopting a flat copy from a peer.
--- Mail rides on this deliberately: a mail scan changes alt.items, so the content hash and the canon
--- move with it (Bank:Scan) -- a newer mailbox IS a newer publish, and needs no clause of its own.
---@param norm string normalized alt name
---@param summary table|nil what the peer advertised: { hash, hashV2, updatedAt, mailHash, ... }
---@return boolean improves
---@return string reason one of "no data" | "canon" | "newer" | "self" | "no canon" | "not newer" | "nothing"
function TOGBankClassic_Guild:AdvertisedImproves(norm, summary)
	if type(summary) ~= "table" or not norm then return false, "nothing" end
	if norm == self:GetNormalizedPlayer() then return false, "self" end
	self:CanonicaliseSummary(summary)   -- HASH-CANON-005: never a number past this point
	local held = self.Info and self.Info.alts and self.Info.alts[norm]
	if not held or not self:HasAltContent(held, norm) then
		if summary.hashV2 == nil and (tonumber(summary.hash) or 0) == 0 then return false, "nothing" end
		return true, "no data"
	end
	local theirs = summary.hashV2
	if theirs == nil then return false, "no canon" end
	local DC = TOGBankClassic_DeltaComms
	local mine = DC:CanonFrom(held.inventoryHashV2, held.inventoryUpdatedAt or held.version)
	if mine == nil then return true, "canon" end
	if self:CanonIsNewer(theirs, mine) then return true, "newer" end
	return false, "not newer"
end

--- Is canon `a` a LATER PUBLISH than canon `b`? The one compare behind "is someone newer" -- the
--- publish time off the front of each canon, never the whole string (a float-mangled tail compares
--- greater and means nothing). Peer Review F6: this was spelled in AdvertisedImproves and again in
--- the offer emitter; a nil on either side is "not a version" and never newer.
---@param a string|nil
---@param b string|nil
---@return boolean
function TOGBankClassic_Guild:CanonIsNewer(a, b)
	local DC = TOGBankClassic_DeltaComms
	local ta, tb = DC:CanonPublishTime(a), DC:CanonPublishTime(b)
	return ta ~= nil and (tb == nil or ta > tb)
end

-- Returns true if the given normalized alt name is sync-pending: the newest thing anyone has
-- advertised for it (latestBankerHashes) can improve what we hold -- see AdvertisedImproves.
-- Returns false if in sync or not in the hash cache.
--
-- TABCOLOUR-002: this is the SYNC layer's question (catch-up scheduling, hashdebug) and no longer
-- the tab colour's -- that is GetAltStaleness above. They answer from the same publish-time rule;
-- this one reads the cache entry, that one reads the time the cache entry raised.
function TOGBankClassic_Guild:IsAltSyncPending(norm)
	-- HASH-CACHE-001 rule 1: our own character is never FETCHED (MULTIPC-001: it can be behind,
	-- and that is answered by a rescan, not a sync). AdvertisedImproves applies it too; it is kept
	-- here so an empty cache answers before anything is looked up.
	if norm == self:GetNormalizedPlayer() then return false end
	local bankerList = self.latestBankerHashes
	if not bankerList then return false end
	local summary = bankerList[norm]
	if not summary then return false end
	return (self:AdvertisedImproves(norm, summary))
end

-- Returns true if any alt still needs content: hash mismatch, missing data, or
-- roster alt with no content at all (covers the wipe-recovery case where
-- latestBankerHashes is empty because no hashes have been received yet).
function TOGBankClassic_Guild:HasMissingContent()
	local currentPlayer = self:GetNormalizedPlayer()

	-- Check 1: any alt in latestBankerHashes that is still pending (hash mismatch / no data)
	local bankerList = self.latestBankerHashes
	if bankerList then
		for altName in pairs(bankerList) do
			if altName ~= currentPlayer and self:IsAltSyncPending(altName) then
				return true
			end
		end
	end

	-- Check 2: any roster alt with no content at all (wipe / blank DB case where
	-- latestBankerHashes may be empty because no hash-offers have arrived yet)
	local rosterAlts = self:GetRosterAlts() or self:GetBanks() or {}
	local localAlts  = self.Info and self.Info.alts or {}
	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		if norm and norm ~= currentPlayer then
			local localAlt = localAlts[norm]
			if not self:HasAltContent(localAlt, norm) then
				return true
			end
		end
	end

	return false
end

function TOGBankClassic_Guild:ReportHashListCoverage()
	local rosterAlts = self:GetRosterAlts() or self:GetBanks() or {}

	-- Build roster lookup table for faster validation
	local rosterLookup = {}
	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		if norm then
			rosterLookup[norm] = true
		end
	end

	-- Use in-memory hash cache (populated on load and updated by hash broadcasts)
	local bankerList = self.latestBankerHashes or {}
	local localAlts = self.Info and self.Info.alts or {}
	local currentPlayer = self:GetNormalizedPlayer()

	local matched = 0
	local pending = {}
	local matchedNoContent = {}
	for altName, summary in pairs(bankerList) do
		-- Skip current player (can't request your own data) and non-roster alts (old/invalid data)
		if altName ~= currentPlayer and rosterLookup[altName] then
			local localAlt = localAlts and localAlts[altName]
			-- P2P-034: the same question the request paths ask, so this report predicts them.
			if self:AdvertisedImproves(altName, summary) then
				table.insert(pending, altName)
			elseif not self:HasAltContent(localAlt, altName) then
				-- Nothing held and the claim carries nothing either: neither side has this bank.
				table.insert(matchedNoContent, altName)
			else
				matched = matched + 1
			end
		end
	end

	local rosterMissing = {}
	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		if norm and not bankerList[norm] then
			table.insert(rosterMissing, norm)
		end
	end

	table.sort(pending)
	table.sort(rosterMissing)

	local bankerCount = 0
	for _ in pairs(bankerList) do
		bankerCount = bankerCount + 1
	end

	local haveContent = 0
	local missingContent = {}
	for _, altName in ipairs(rosterAlts) do
		local norm = self:NormalizeName(altName)
		local localAlt = localAlts and norm and localAlts[norm]
		if norm and self:HasAltContent(localAlt, norm) then
			haveContent = haveContent + 1
		elseif norm and norm ~= currentPlayer then
			table.insert(missingContent, norm)
		end
	end
	table.sort(missingContent)

	TOGBankClassic_Output:Response(
		"Hash list coverage: banker=%d, matched=%d, pending=%d, rosterMissing=%d, haveContent=%d, missingContent=%d",
		bankerCount,
		matched,
		#pending,
		#rosterMissing,
		haveContent,
		#missingContent
	)

	local function printList(title, list)
		if #list == 0 then
			TOGBankClassic_Output:Response("%s: none", title)
			return
		end
		local cap = 20
		local count = math.min(#list, cap)
		local slice = {}
		for i = 1, count do
			slice[#slice + 1] = list[i]
		end
		local suffix = ""
		if #list > cap then
			suffix = string.format(" (showing %d of %d)", cap, #list)
		end
		TOGBankClassic_Output:Response("%s: %s%s", title, table.concat(slice, ", "), suffix)
	end

	printList("HLR pending", pending)
	printList("Hash matched but no content", matchedNoContent)
	printList("Missing from banker list", rosterMissing)
	printList("Missing content (no data)", missingContent)
end

function TOGBankClassic_Guild:SendHashList(target)
	if not target then
		return
	end
	local normalizedTarget = self:NormalizeName(target)
	local list = self:BuildBankerHashList()
	local payload = {
		type = "hash-list-reply",
		alts = list,
		banker = self:GetNormalizedPlayer(),
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	local altCount = 0
	for _ in pairs(list) do
		altCount = altCount + 1
	end
	TOGBankClassic_Output:Debug(
		"PROTOCOL",
		"HLR",
		"HLR send: target=%s (normalized=%s), alts=%d, bytes=%d",
		tostring(target),
		tostring(normalizedTarget),
		altCount,
		data and #data or 0
	)
	local sent = TOGBankClassic_Core:SendWhisper("togbank-hlr", data, normalizedTarget, "ALERT")
	TOGBankClassic_Output:Debug("PROTOCOL", "HLR", "HLR send result: %s", tostring(sent))
end

function TOGBankClassic_Guild:RequestHashListFromBanker()
	-- Find an online banker from guild roster (excluding ourselves)
	local myPlayer = self:GetNormalizedPlayer()
	local banker = nil
	for member, _ in pairs(self.onlineMembers or {}) do
		-- WIRE-SKEW-008 (self-audit): a banker whose reply we would then ignore (ClaimantCanServe)
		-- is not worth the round trip; with no capable banker online the no-banker path below asks
		-- the guild instead, which the capable relays answer.
		if self:IsBank(member) and self:IsPlayerOnline(member) and member ~= myPlayer
				and self:ClaimantCanServe(member) then
			banker = member
			break
		end
	end
	if not banker then
		-- No banker online: broadcast requests using local hashes when possible
		local rosterAlts = self:GetBanks()
		local pendingCount = 0
		if rosterAlts and #rosterAlts > 0 then
			-- DEAD SCAFFOLDING REMOVED. A `isWipeRecovery` flag was computed here by walking
			-- every roster alt, under the comment "Bypass rate limiting for bulk requests when
			-- user has blank DB" -- and then never read. The bypass it advertised did not exist,
			-- so a user with a wiped database was rate-limited exactly like anyone else while the
			-- code read as though they were not. Same class as P2P-025: a whole loop whose only
			-- output was discarded.
			--
			-- If the bypass is wanted, it has to be written; do not restore the flag alone.
			for _, altName in ipairs(rosterAlts) do
				local norm = self:NormalizeName(altName)
				local localAlt = self.Info and self.Info.alts and norm and self.Info.alts[norm]
				local hasContent = localAlt and self:HasAltContent(localAlt, norm)
				if not hasContent then
					local localHash = localAlt and localAlt.inventoryHash or nil
					local updatedAt = localAlt and (localAlt.inventoryUpdatedAt or localAlt.version) or nil
					pendingCount = pendingCount + 1
					if localHash and localHash ~= 0 then
						-- We have hash but no content - broadcast P2P request WITH hash
						-- Peers with matching hash will respond (PERF-005 P2P protocol)
						TOGBankClassic_Output:Debug(
							"PROTOCOL",
							"HLR",
							"HLR fallback: no banker online, broadcasting P2P for %s (expectedHash=%s, updatedAt=%s)",
							tostring(norm),
							tostring(localHash),
							tostring(updatedAt)
							)
						self:BroadcastP2PRequest(norm, localHash, updatedAt, nil, localAlt and localAlt.inventoryHashV2)
					else
						-- No hash: let ScheduleCatchUp handle via next SyncDeltaVersion
						TOGBankClassic_Output:Debug(
							"PROTOCOL",
							"HLR fallback: no banker online, no hash for %s - scheduling catch-up",
							tostring(norm)
						)
						TOGBankClassic_P2PSession:ScheduleCatchUp("no_hash_no_banker")
					end
				end
			end
		end
		if pendingCount > 0 then
			TOGBankClassic_Output:Debug("PROTOCOL", "Fast-fill: No banker online, broadcasting %d requests", pendingCount)
		end
		return false
	end

	local request = {
		type = "hash-list-request",
		requester = self:GetNormalizedPlayer(),
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(request)
	TOGBankClassic_Core:SendWhisper("togbank-hl", data, banker, "NORMAL")
	return true
end

--- Arm a per-alt timeout timer, cancelling whatever was already armed for that alt.
---
--- P2P-026 / AUDIT finding 24, SECOND HALF. Switching these to `C_Timer.NewTimer` fixed the ACK
--- path -- a peer answers, the stored handle is finally real, and `:Cancel()` does something. It
--- did NOT fix the path where no peer ever answers. `BroadcastP2PRequest` has no in-flight guard,
--- so a second request for the same alt inside the window armed a second timer and OVERWROTE the
--- stored handle, dropping the first on the floor with nothing left that could reach it. The first
--- timer then fired, saw the SECOND request's `pendingP2PRequests[norm]` as its own, and tore that
--- request down: pending state cleared, a banker fallback recorded against the guild, and
--- `AdvanceCandidate` called on a session it was never armed for. That is the exact failure
--- finding 24 describes, reached without any peer responding -- so making the cancels work only
--- closed the half that needed an ACK.
---
--- One spelling for all three arm sites (Chat.lua's 5s and 15s, and BroadcastP2PRequest's
--- PEER_RESPONSE_TIMEOUT below), so "at most one timer per alt per registry" is an invariant of the
--- helper rather than something three separate assignments each have to remember. The registry is
--- named rather than passed so the lazy creation lives here too.
---
--- Cancelling an already-fired handle is safe, and that is checked rather than assumed: Blizzard's
--- own `AsyncRequestMixin` cancels its timeout timer from inside that timer's own callback
--- (Blizzard_AsyncRequest.lua:60-77 -- the callback calls `StopRequest`, which calls `:Cancel()` on
--- the timer currently running), unguarded.
---@param registryName string field on this module holding the per-alt handle table
---@param norm string normalized alt name
---@param delay number seconds until the callback fires
---@param callback function
---@return table timer the new handle, also stored in the registry
function TOGBankClassic_Guild:ArmAltTimeout(registryName, norm, delay, callback)
	local registry = self[registryName]
	if not registry then
		registry = {}
		self[registryName] = registry
	end

	local existing = registry[norm]
	if existing then
		existing:Cancel()
		TOGBankClassic_Output:Debug("P2P", "TIMEOUT",
			"[P2P-026] Replaced in-flight %s for %s -- the old timer would have torn down this request",
			registryName, norm)
	end

	local timer = C_Timer.NewTimer(delay, callback)
	registry[norm] = timer
	return timer
end

--- Forget a pull-path request for `norm`: the pending entry, the expected hashes, the alt-request
--- marker, and both its timers. Returns the pending entry it cleared, or nil when nothing was
--- pending (so a caller can decide whether the outcome is worth a fallback record at all).
---
--- THE ONE SPELLING (Peer Review 2026-09-12, F1): this block was written out by hand in the
--- BroadcastP2PRequest timeout below and in Chat.lua's hash-only ACK timeout, and a third caller
--- (a refusal heard with no session -- P2PSession:OnQueryRefused) would have been the third copy.
---@param norm string
---@return table|nil pending
function TOGBankClassic_Guild:ClearPendingP2PRequest(norm)
	local pending = self.pendingP2PRequests and self.pendingP2PRequests[norm]
	if self.pendingP2PRequests then self.pendingP2PRequests[norm] = nil end
	if self.pendingAltRequests then self.pendingAltRequests[norm] = nil end
	if self.expectedHashes then self.expectedHashes[norm] = nil end
	if self.expectedHashUpdatedAt then self.expectedHashUpdatedAt[norm] = nil end
	for _, registryName in ipairs({ "pendingP2PTimeouts", "pendingP2PFallbackTimeouts" }) do
		local registry = self[registryName]
		local t = registry and registry[norm]
		if t then
			if type(t) == "table" and t.Cancel then t:Cancel() end
			registry[norm] = nil
		end
	end
	return pending
end

--- @param expectedHashV2 string|nil the advertised canon, when the caller has one. HASH-CANON-006:
--- the "already have it" skip below must see the canon, or a pre-canon copy whose revision-1 hash
--- happens to equal the banker's current one is never requested and can never acquire a canon.
function TOGBankClassic_Guild:BroadcastP2PRequest(altName, expectedHash, expectedUpdatedAt, bankerSender, expectedHashV2)
	if not altName or not expectedHash then
		return
	end

	-- Skip if requesting data for ourselves (can't P2P request your own data)
	local norm = self:NormalizeName(altName)
	local currentPlayer = self:GetNormalizedPlayer()
	if norm == currentPlayer then
		TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "Skipping P2P broadcast for %s (requesting own data)", altName)
		return
	end

	-- Only broadcast for a version that can IMPROVE what we hold. P2P-034: this guard used to ask
	-- HashesAgreeWith -- "the same version?" -- and so let through a request for any DIFFERENT
	-- version, older ones and canon-less ones included; the guild-wide alt-request then timed out
	-- because nobody had anything newer. Same rule as every other request path (AdvertisedImproves),
	-- which also keeps HASH-CANON-006 (a held copy with no canon still asks for one) and PERF-005 (a
	-- copy we already hold is not re-requested).
	local improves, why = self:AdvertisedImproves(norm, {
		hash = expectedHash, hashV2 = expectedHashV2, updatedAt = expectedUpdatedAt,
	})
	if not improves then
		TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "PERF-005: Skipping P2P broadcast for %s (%s)", altName, why)
		return
	end

	TOGBankClassic_Output:Debug(
		"PROTOCOL",
		"HLR",
		"HLR broadcast: requesting %s (expectedHash=%s, updatedAt=%s) from banker=%s",
		tostring(altName),
		tostring(expectedHash),
		tostring(expectedUpdatedAt),
		tostring(bankerSender)
	)
	TOGBankClassic_Output:Debug("P2P", "BROADCAST", "P2P: Broadcasting request for %s with hash=%08x (waiting for peers)", altName, expectedHash)

	self.expectedHashes = self.expectedHashes or {}
	self.expectedHashes[norm] = expectedHash
	if expectedUpdatedAt then
		self.expectedHashUpdatedAt = self.expectedHashUpdatedAt or {}
		self.expectedHashUpdatedAt[norm] = expectedUpdatedAt
	end
	self.pendingP2PRequests = self.pendingP2PRequests or {}
	self.pendingP2PRequests[norm] = { banker = bankerSender, requestedAt = GetTime() }

	-- MAIL-SYNC: Get requester's current mailHash to detect mail changes
	local ourAlt = self.Info and self.Info.alts and self.Info.alts[norm]
	local ourMailHash = (ourAlt and ourAlt.mailHash) or 0

	local p2pRequest = {
		type = "alt-request",
		name = altName,
		requester = self:GetNormalizedPlayer(),
		hashOnly = false,
		expectedHash = expectedHash,
		updatedAt = expectedUpdatedAt,
		requesterMailHash = ourMailHash,  -- MAIL-SYNC: Include mail hash
	}
	local p2pData = TOGBankClassic_Core:SerializeWithChecksum(p2pRequest)
	-- PERF-006: Use togbank-hl for P2P broadcasts so old code without hash support doesn't see them
	if self.Info and self.Info.name then
		TOGBankClassic_Database:RecordP2PRequestBroadcast(self.Info.name)
	end
	TOGBankClassic_Core:SendCommMessage("togbank-hl", p2pData, "GUILD", nil, "NORMAL")

	local timeout = (PEER_TO_PEER and PEER_TO_PEER.PEER_RESPONSE_TIMEOUT) or 5
	-- TIMER-001 / AUDIT finding 24: NewTimer (via ArmAltTimeout), so pendingP2PTimeouts[norm] holds
	-- a real handle rather than nil. P2P-026: arming through the helper also cancels any timer this
	-- alt already had in flight -- without that, a second request inside the window orphaned the
	-- first timer, which then tore down this one.
	self:ArmAltTimeout("pendingP2PTimeouts", norm, timeout, function()
		-- One clearing (ClearPendingP2PRequest): the pending entry, the expected hashes, the
		-- alt-request marker, the timers -- it used to be spelled out here.
		local pending = self:ClearPendingP2PRequest(norm)
		if pending then
			-- Check if we have any way to get this data
			-- Peer Review F3: this printed "(no banker online)" whenever `pending.banker` was nil --
			-- which the fast-fill and no-banker callers always pass -- so the log claimed a fact the
			-- code had not established, with the banker online. Say only what is known.
			local banker = pending.banker
			local why = banker == nil and "no banker named on this request"
				or (self:IsPlayerOnline(banker) and ("banker " .. banker .. " online, did not answer")
					or ("banker " .. banker .. " offline"))
			TOGBankClassic_Output:Debug("P2P", "DISPATCH", "PERF-005: No P2P response for %s after %ds timeout (%s)", altName, timeout, why)
			if self.Info and self.Info.name then
				TOGBankClassic_Database:RecordP2PBankerFallback(self.Info.name)
			end
			-- Schedule a catch-up broadcast rather than whispering a banker.
			if TOGBankClassic_P2PSession then
				local sid = TOGBankClassic_P2PSession.sessionsByAlt[norm]
				if sid then
					TOGBankClassic_P2PSession:AdvanceCandidate(sid, "hlr_timeout")
				else
					TOGBankClassic_P2PSession:ScheduleCatchUp("hlr_timeout")
				end
			end
		end
	end)
end

--- Turn "1.10.0" into a number that ORDERS correctly. Returns 0 for an unpackaged/dev build.
---
--- PROTO-001: this used to be `tonumber(gsub(raw, "%.", ""))`, which produces an integer whose
--- magnitude depends on DIGIT COUNT rather than on precedence. "1.10.0" became 1100 and "2.0.0"
--- became 200, so a major-version bump ranked BELOW a two-digit minor and protocol negotiation
--- picked the older peer as authoritative. "1.3.2" (132) against "1.10.0" (1100) happens to come
--- out right, which is exactly what made it survive: the inversion only appears once the digit
--- counts differ across a boundary.
---
--- Fixed-width fields instead, 1000 per component, so each component is compared on its own.
---
--- ON THE WIRE, and why this is safe to change unilaterally: peers exchange this number and
--- compare it. An unmigrated peer still sends the old dot-stripped form, but the two encodings
--- stay ordered the same way ACROSS the boundary -- every old value is a 3-4 digit number and
--- every new one is 7 digits, so a migrated client always reads as newer than an unmigrated one,
--- which is true. The comparison is only ever "is the other side ahead of me".
---
--- WIRE-SKEW-002: NOT anchored at the start. A RELEASED client's Version is the packager's
--- substitution of `@project-version@`, which is the WHOLE git tag -- `TOGBankClassic-v1.4.1`
--- (VersionCheck-1.0 widened its version column for exactly that string). The `^(%d+)` anchor
--- matched nothing in it, so every released peer encoded as 0 -- "dev", "capable" -- and the
--- WIRE-SKEW-001 gate built on this number never refused a single v1.4.1 requester: read off
--- Galdof's log on 2026-09-12, the afternoon after that gate shipped, still queueing Holstein,
--- Swax, Barlth and Unclejenny for a bank they could never finish. The first `d.d.d` anywhere in
--- the string is the version; a string with none is a dev build.
function TOGBankClassic_Guild.EncodeVersion(raw)
	if type(raw) ~= "string" then return 0 end
	local major, minor, patch = raw:match("(%d+)%.(%d+)%.(%d+)")
	if not major then
		-- Two-component ("1.4") and bare ("dev", "@project-version@") forms. A dev build is 0
		-- rather than a guess: an invented number would rank a working copy against real peers.
		major, minor = raw:match("(%d+)%.(%d+)")
		if not major then return 0 end
		patch = 0
	end
	return (tonumber(major) * 1000000) + (tonumber(minor) * 1000) + tonumber(patch)
end

--- Peer Review c6819531 F3: is this version string a DEV BUILD -- the two spellings an unpackaged
--- working copy actually reports (`@project-version@`, the TOC placeholder the packager never
--- substituted; `dev`) -- as opposed to a string that merely fails to parse? EncodeVersion answers 0
--- for both, and the two callers used to read every 0 as "dev, capable": a garbage claim ("?",
--- "unknown", a truncated string) from either source would then OUTRANK a real v1.4.1 claim from
--- the other and pass the data-leg gate. Garbage is not evidence; only these two words are.
---@param raw any
---@return boolean
function TOGBankClassic_Guild.IsDevVersion(raw)
	return raw == "@project-version@" or raw == "dev"
end

-- WIRE-SKEW-001: what addon version each peer last announced (the `addon` field every hlb2
-- broadcast has carried since v1.4.1 and nothing read). Session-only; a peer we have not heard
-- from is unknown, and unknown is treated as capable.
TOGBankClassic_Guild.peerAddonVersions = {}

--- A peer's hlb2 broadcast announced its addon version.
function TOGBankClassic_Guild:NotePeerAddonVersion(sender, raw)
	local norm = self:NormalizeName(sender)
	if not norm or type(raw) ~= "string" or raw == "" then return end
	self.peerAddonVersions[norm] = raw
	self:RememberPeerAddonVersion(norm, raw)
end

--- STALE-REQ-002: the LAST version each guildmate was seen on, in the guild's SavedVariables.
---
--- Both live sources are session memory -- VersionCheck's table empties on every reload and
--- refills only as each guildmate's client answers, and `peerAddonVersions` only as their
--- broadcasts land -- so an OFFLINE guildmate has no version at all after a reload. Read off the
--- operator's banker on 2026-09-13: a v1.3.2 requester's request carried no mark because the
--- lookup answered "unknown", though VersionCheck had shown him on v1.3.2 an hour earlier. The
--- Requests tab is exactly where the requester is usually offline (a banker fills orders on their
--- own time), so the mark needs a memory that outlives the session.
---
--- FOR THE REQUESTS TAB ONLY. The sync gate (PeerSpeaksDataLeg) keeps reading the two live
--- sources: a remembered version is what a client RAN, not what it runs, and refusing a peer on
--- the strength of last week's sighting is the starvation WIRE-SKEW-004 was built against.
--- Newer wins, as everywhere: a remembered version only ever moves forward.
---@param norm string normalized name
---@param raw string the version string as observed
function TOGBankClassic_Guild:RememberPeerAddonVersion(norm, raw)
	if not (self.Info and norm and type(raw) == "string" and raw ~= "") then return end
	local mem = self.Info.peerAddonVersions
	if not mem then mem = {}; self.Info.peerAddonVersions = mem end
	local have = mem[norm]
	local n = self.EncodeVersion(raw)
	-- Peer Review c6819531 F3, the same rule as ObservedAddonVersion: a dev marker is the newest
	-- thing there is and replaces anything; an unparseable string is not a version and is not
	-- remembered (it used to overwrite a real one, because 0 skipped the newer-wins guard).
	if n == 0 and not self.IsDevVersion(raw) then return end
	if have and have.version and n ~= 0 and not self.IsDevVersion(have.version)
			and self.EncodeVersion(have.version) > n then return end
	mem[norm] = { version = raw, at = GetServerTime() }
end

--- STALE-REQ-002: the version a guildmate was LAST SEEN on -- the live sources first, then the
--- guild's memory. nil when nothing has ever been seen.
---@param name string as stored (a request's requester)
---@return string|nil raw, boolean remembered true when the answer came from memory, not this session
function TOGBankClassic_Guild:LastSeenAddonVersion(name)
	local norm = self:NormalizeName(name)
	local live = self:ObservedAddonVersion(name, norm)
	if live then return live, false end
	local mem = self.Info and self.Info.peerAddonVersions
	local have = mem and norm and mem[norm]
	if have and type(have.version) == "string" and have.version ~= "" then return have.version, true end
	return nil, false
end

--- STALE-REQ-002: VersionCheck's observations land here too, as they happen, so the memory does
--- not depend on the guildmate ever broadcasting to us. Registered once; VersionCheck keys its
--- registry by target, so a second call replaces rather than stacks.
function TOGBankClassic_Guild:HookVersionCheck()
	local VC = LibStub and LibStub("VersionCheck-1.0", true)
	if not (VC and VC.RegisterCallback) then return false end
	VC.RegisterCallback(self, "OnPeerVersion", function(_, sender, addonName, version)
		if addonName ~= "TOGBankClassic" then return end
		local norm = self:NormalizeName(sender)
		if norm then self:RememberPeerAddonVersion(norm, version) end
	end)
	return true
end

-- WIRE-SKEW-007: peers OBSERVED on the old wire, before anyone told us their version. Read off the
-- banker's log after a /reload on 2026-09-12: Garlii, Freezeplug and Venshea were ACCEPTED (nobody
-- had named their version yet, and unknown is capable), each held a slot for the whole 30-second
-- state-wait, released `no_state_summary`, and were refused as v1.4.1 only minutes later once
-- VersionCheck caught up -- three slots times thirty seconds, every login, before a capable peer
-- could be served. Two things say "old wire" without a version claim: the `togbank-state` summary a
-- v1.4.1 requester whispers after our accept (a v1.5.0 one asks on the host's QUERY channel and
-- never sends that), and silence for the whole wait. Session-only. A version claim from either real
-- source, when one arrives, outranks this: it names what the peer runs, this only names what it did.
TOGBankClassic_Guild.peerOldWire = {}

--- A peer showed old-wire behaviour. Returns true the first time for this peer.
---@param sender string as it arrived on the wire
---@param how string "state-summary" | "silent"
---@return boolean noted
function TOGBankClassic_Guild:NotePeerOldWire(sender, how)
	local norm = self:NormalizeName(sender)
	if not norm then return false end
	self.peerOldWire = self.peerOldWire or {}
	if self.peerOldWire[norm] then return false end
	self.peerOldWire[norm] = how or "observed"
	return true
end

--- WIRE-SKEW-004: the version a peer runs comes from VersionCheck-1.0 FIRST, and only then from
--- the hlb2 broadcast.
---
--- `peerAddonVersions` fills in when that peer's own broadcast reaches us, which is AFTER we have
--- already had to decide whether to ask it for data. Everything unheard-from read as "unknown" ->
--- capable -> dispatched -> a full dispatch timeout -> the next candidate -> `All candidates busy
--- ... retry 1/5 in 20s`. Read off the operator's log on 2026-09-12: `→ Togstone-Azuresong to
--- Kajind-Azuresong`, then `Dispatch timeout for Elementals-Azuresong/Kajind-Azuresong`, and
--- Kajind in the refusal lists a moment later once its broadcast landed. In a guild where 40 of 42
--- clients are on the old release, that is where the hours went.
---
--- VersionCheck already holds the whole guild's versions before any sync traffic happens -- it is a
--- declared dependency, and its table COSTS NO TRAFFIC (every client's version-check REQ is already
--- broadcast carrying its full addon list; the library just stops discarding the versions). So it
--- is the authority and the broadcast field is the fallback for a peer it has not observed.
---
--- Keyed through LibGuildRoster's `CanonName` -- the SAME function VersionCheck keys with -- rather
--- than our own NormalizeName, so the two cannot disagree about a realm suffix and miss silently,
--- which would look exactly like the bug this replaces. The raw name and our normalized form are
--- tried after it rather than instead of it.
---@return boolean capable, string why "unknown" | "dev" | "old wire (<how>)" | the observed version
function TOGBankClassic_Guild:PeerSpeaksDataLeg(name)
	local norm = self:NormalizeName(name)
	local raw = self:ObservedAddonVersion(name, norm)
	if not raw then
		-- WIRE-SKEW-007: no version claim, but the peer has already BEHAVED like the old wire with
		-- us. That is not "not seen" -- the operator's line that must never be crossed -- it is seen,
		-- doing the one thing a capable client cannot do. Refused until a real claim says otherwise.
		local how = norm and self.peerOldWire and self.peerOldWire[norm]
		if how then return false, "old wire (" .. tostring(how) .. ")" end
		return true, "unknown"
	end
	if self.IsDevVersion(raw) then return true, "dev" end
	local n = self.EncodeVersion(raw)
	-- ObservedAddonVersion never hands back a string that encodes to 0 unless it is a dev marker,
	-- so this is belt-and-braces: an unparseable claim is not a version, and not a refusal either.
	if n == 0 then return true, "unknown" end
	return n >= self.EncodeVersion(PROTOCOL.DATA_LEG_MIN_ADDON_VERSION), raw
end

--- WIRE-SKEW-008: MAY A CLAIM FROM THIS PEER MOVE ANYTHING? Read off both of the operator's v1.5.0
--- clients on 2026-09-12: Elementals -- ONLINE, its author's own client holding canon
--- `1789076374...`, Galdof holding the identical one -- read "Behind" on both, and the Elementals
--- client logged `a peer holds a LATER version of this character than this PC` against Galdof's
--- reply naming the very canon it held. Nothing newer existed. Five v1.4.1 relays had advertised
--- Elementals with a LATER publish time than the author's: the old release still stamps the clock
--- onto timestamp-less saved data on load (CANON-TIME-001, fixed here in v1.5.0 and nowhere else),
--- and every claim path took the maximum with no regard for who was claiming. That one lie set
--- Galdof's tab red, set the author's OWN tab red, and -- through MULTIPC-002 -- had the author
--- fetching a phantom diff base from peers it cannot fetch from before it would publish a rescan.
---
--- The rule: a peer that cannot complete the data leg with us cannot move the tab, the advertised
--- hash cache, or the self-holder record. Red means "on its way", and nothing is on its way from a
--- release we do not speak. KNOWN COST, stated rather than hidden: a bank genuinely rescanned on a
--- v1.4.1 client reads Current on v1.5.0 clients until that client upgrades, at which point its
--- broadcast turns the tab red and the fetch turns it yellow. A claimant with no name (a spec
--- driving a raise alone) is allowed, as it always was.
---@param sender string|nil
---@return boolean
function TOGBankClassic_Guild:ClaimantCanServe(sender)
	if not sender or not self.PeerSpeaksDataLeg then return true end
	return (self:PeerSpeaksDataLeg(sender))
end

--- The version this peer is running: the NEWER of what VersionCheck-1.0 observed and what their own
--- hlb2 broadcast announced. nil when neither knows, and nil is NOT a refusal (see the caller).
---
--- THE NEWER, not VersionCheck's, and the operator is the reason: "VC doesn't always get an answer
--- due to congestion, so we can't hard block anyone with a not seen status." The same congestion
--- that loses an answer also leaves a STALE one behind, and a fixed VersionCheck-wins rule would
--- then refuse a peer that has since updated -- inventing the very starvation this whole item is
--- about. A client's version only ever moves FORWARD, so taking the higher of two claims is
--- monotonic: it can only let MORE peers through than either source alone, never fewer, and there
--- is no arrangement of stale data that turns a capable peer into a refused one.
---@param name string as it arrived on the wire
---@param norm string|nil the same name through NormalizeName
---@return string|nil
function TOGBankClassic_Guild:ObservedAddonVersion(name, norm)
	norm = norm or self:NormalizeName(name)
	local best, bestN = nil, -1
	local function consider(v)
		if type(v) ~= "string" or v == "" then return end
		-- A dev build encodes as 0 and outranks nothing numerically, but it is CAPABLE, so it has to
		-- win outright rather than lose to a v1.4.1 claim from the other source. Peer Review
		-- c6819531 F3: ONLY a dev build -- a string that merely fails to parse is not evidence of
		-- anything and must not outrank (or become) a real claim; it is dropped here.
		local n
		if self.IsDevVersion(v) then n = math.huge
		else
			n = self.EncodeVersion(v)
			if n == 0 then return end
		end
		if n > bestN then best, bestN = v, n end
	end

	local VC = LibStub and LibStub("VersionCheck-1.0", true)
	local seen = VC and VC.GetPeerVersions and VC:GetPeerVersions("TOGBankClassic")
	if seen then
		local lib = RosterLib()
		local canon = lib and lib.CanonName and lib:CanonName(name or norm)
		-- EVERY SPELLING, because the two sides do not agree on one. VersionCheck keys by the sender
		-- string as AceComm delivered it, and a SAME-REALM sender arrives BARE ("Oldguy"); we key by
		-- NormalizeName, which always qualifies ("Oldguy-Testrealm"). On a connected-realm guild that
		-- is most of the roster, so a qualified-only lookup misses for nearly everyone, falls through
		-- to "unknown", and quietly restores the bug this whole item is about -- with a green suite
		-- and no error. Caught by the spec that drives both spellings; it failed before this line.
		--
		-- All O(1) rather than a scan of the table: this runs per candidate per alt, ~1100 times in a
		-- dispatch cycle on the operator's guild, and a linear search there would cost more than the
		-- refusal saves. RESIDUAL, stated rather than hidden: two guildmates whose names differ only
		-- by realm share a bare key, so one could answer for the other. It can only mis-refuse when
		-- that row is the ONLY evidence about our peer -- any claim of 1.5.0+ from any other spelling
		-- wins under the newer-claim rule above, and the peer's own broadcast settles it for good.
		local function bare(s) return s and s:match("^[^-]+") or nil end
		local keys = { canon, norm, name, bare(name), bare(norm) }
		for i = 1, 5 do
			local entry = keys[i] and seen[keys[i]]
			if entry then consider(entry.version) end
		end
	end
	if norm then consider(self.peerAddonVersions[norm]) end
	return best
end

function TOGBankClassic_Guild:GetVersion()
	if not self.Info then
		return nil
	end

	local versionRaw = GetAddOnMetadata("TOGBankClassic", "Version") or "dev"
	local versionNumber = TOGBankClassic_Guild.EncodeVersion(versionRaw)
	local data = {
		addon = versionNumber,
		addonDisplay = (versionNumber > 0) and versionRaw or "dev",
		protocol_version = PROTOCOL.VERSION,
		supports_delta = PROTOCOL.SUPPORTS_DELTA,
		-- The WIRE payload's alts, not Guild.Info.alts: INV2-COMPAT-001's wrapper does not apply.
		alts = {},
	}

	if self.Info.name then
		data.name = self.Info.name
	end

	-- PERF-002: Do not include request version/hash here — NormalizeRequestList() is expensive.
	-- Revisit once NormalizeRequestList has a dirty-flag guard (see Guild:NormalizeRequestList).

	for k, v in pairs(self.Info.alts) do
		-- Only broadcast bankers from the CURRENT guild (cross-guild data leak fix)
		if self:IsBank(k) then
			-- P2P-007: Don't broadcast stub entries (hash but no content) - causes others to send empty deltas
			local hasContent = self:HasAltContent(v, k)
			if not hasContent then
				TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "GetVersion: excluding %s from version broadcast (stub entry - no content)", k)
			else
				if type(v) == "table" and v.version then
					-- Send hash only in delta-enabled mode (backwards compatibility)
					if PROTOCOL.SUPPORTS_DELTA and v.inventoryHash then
						-- HASH-REV-001 shape 3 of 5. HASH-CANON-009: ServableCanon, not the raw field.
						data.alts[k] = {
							version = v.version,
							hash = v.inventoryHash,
							hashV2 = self:ServableCanon(k),
							updatedAt = v.inventoryUpdatedAt or v.version,
						}
						TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "GetVersion: including %s in local version data (ver=%d, hash=%08x)", k, v.version, v.inventoryHash)
					else
						-- Legacy format for old clients
						data.alts[k] = v.version
						TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "GetVersion: including %s in local version data (ver=%d, no hash)", k, v.version)
					end
				end
			end
		else
			TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "GetVersion: excluding %s from local version data (not a banker in current guild)", k)
		end
	end

	return data
end

local PENDING_SYNC_TTL_SECONDS = 180

function TOGBankClassic_Guild:MarkPendingSync(syncType, sender, name)
	if not syncType or not sender then
		return
	end
	local now = GetServerTime()
	local normSender = self:NormalizeName(sender)
	if not self.pending_sync then
		self.pending_sync = { alts = {} }
	end
	if not self.pending_sync.alts then
		self.pending_sync.alts = {}
	end

	if syncType == "alt" and name then
		local normName = self:NormalizeName(name)
		if self.pending_sync.alts and not self.pending_sync.alts[normName] then
			---@diagnostic disable-next-line: need-check-nil
			self.pending_sync.alts[normName] = {}
		end
		if self.pending_sync.alts and self.pending_sync.alts[normName] then
			---@diagnostic disable-next-line: need-check-nil
			self.pending_sync.alts[normName][normSender] = now
		end
	end
end

function TOGBankClassic_Guild:ConsumePendingSync(syncType, sender, name)
	if not syncType or not sender then
		return false
	end
	if not self.pending_sync then
		return false
	end
	local now = GetServerTime()
	local normSender = self:NormalizeName(sender)
	if syncType == "alt" and name then
		local normName = self:NormalizeName(name)
		local alts = self.pending_sync.alts and self.pending_sync.alts[normName]
		local ts = alts and alts[normSender]
		if ts and now - ts <= PENDING_SYNC_TTL_SECONDS then
			---@diagnostic disable-next-line: need-check-nil
			alts[normSender] = nil
			if next(alts) == nil then
				---@diagnostic disable-next-line: need-check-nil
				self.pending_sync.alts[normName] = nil
			end
			return true
		end
		if ts then
			---@diagnostic disable-next-line: need-check-nil
			alts[normSender] = nil
			if next(alts) == nil then
				---@diagnostic disable-next-line: need-check-nil
				self.pending_sync.alts[normName] = nil
			end
		end
	end
	return false
end

function TOGBankClassic_Guild:QueryAlt(player, name, version)
	self.hasRequested = true
	if self.requestCount == nil then
		self.requestCount = 1
	else
		self.requestCount = self.requestCount + 1
	end
	self:MarkPendingSync("alt", player, name)
	local data = TOGBankClassic_Core:SerializeWithChecksum({ player = player, type = "alt", name = name, version = version })
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, "NORMAL")
end

-- Query - WHISPER to banker if known, GUILD if unknown
-- `forceFull` is accepted and ignored: DELTA-ONLY means every send is a delta, so there is no
-- full-sync path left for it to select. Kept in the signature because call sites still pass it.
function TOGBankClassic_Guild:QueryAltPullBased(name, hashOnly, _, targetPlayer)
	if not name then
		return
	end

	local normName = self:NormalizeName(name)

	-- Log that we're sending a query
	TOGBankClassic_Output:Debug("PROTOCOL", "ALT-REQUEST", "[QUERY] QueryAltPullBased called for %s (hashOnly=%s, target=%s)", normName, tostring(hashOnly or false), targetPlayer or "banker")

	-- Rate-limit repeated queries for the same alt to reduce stutter
	self.lastAltQueryTime = self.lastAltQueryTime or {}
	self.pendingAltRequests = self.pendingAltRequests or {}
	local now = GetTime()
	local pendingAt = self.pendingAltRequests[normName]
	if pendingAt and (now - pendingAt) < 10 then
		TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "Skipping query for %s (pending request)", normName)
		return
	elseif pendingAt then
		self.pendingAltRequests[normName] = nil
	end
	local lastQuery = self.lastAltQueryTime[normName]
	if lastQuery and (now - lastQuery) < 3 then
		TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "Skipping query for %s (rate-limited)", normName)
		return
	end
	self.lastAltQueryTime[normName] = now

	local norm = normName
	self.hasRequested = true
	if self.requestCount == nil then
		self.requestCount = 1
	else
		self.requestCount = self.requestCount + 1
	end

	-- Check if we have an online banker (from guild roster, not broadcasts)
	local banker = targetPlayer or nil
	local bankerCount = 0

	-- If no target specified, find a banker
	local myPlayer = self:GetNormalizedPlayer()
	if not banker then
		-- MAIL-012 DEBUG: Log all online bankers from guild roster
		for member, _ in pairs(self.onlineMembers or {}) do
			if self:IsBank(member) and member ~= myPlayer then
				bankerCount = bankerCount + 1
				TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-SYNC", "Online banker from roster: %s, isOnline=%s",
					member, tostring(self:IsPlayerOnline(member)))
				-- Use first found banker (could randomize or prefer by name)
				if not banker then
					banker = member
				end
			end
		end
		-- Fallback: scan memberRoster for online bankers if onlineMembers cache was stale
		if not banker then
			GuildRoster()
			for normRoster, member in pairs(self.memberRoster or {}) do
				if member.isOnline and member.isBank and normRoster ~= myPlayer then
					bankerCount = bankerCount + 1
					banker = banker or normRoster
					TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-SYNC", "Online banker from memberRoster fallback: %s, isOnline=true", normRoster)
				end
			end
		end
		TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-SYNC", "QueryAltPullBased for %s: %d online bankers found from guild roster", norm, bankerCount)
	else
		TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-SYNC", "QueryAltPullBased for %s: using target %s (P2P from version broadcast)", norm, banker)
	end

	-- Build request message
	local request = {
		type = "alt-request",  -- v0.8.0 pull-based request
		name = norm,
		requester = self:GetNormalizedPlayer(),
		hashOnly = hashOnly or false,  -- PERF-005: Request only hash for P2P distribution
	}

	-- DELTA-014: Include requester's current hashes (even for stubs!)
	-- P2P peers will respond ONLY if they have matching hash AND content
	local requesterAlt = self.Info and self.Info.alts and self.Info.alts[norm]
	if requesterAlt then
		-- Send the hash we have (from version broadcast or actual data)
		request.requesterInventoryHash = requesterAlt.inventoryHash or 0
		request.requesterMailHash = requesterAlt.mailHash or 0
		local hasContent = self:HasAltContent(requesterAlt, norm)
		-- P2P-006: Tell sender if we have content - if not, they should send full data
		request.requesterHasContent = hasContent
		TOGBankClassic_Output:Debug("DELTA", "BUILD", "[DELTA-014] QueryAltPullBased for %s: requester invHash=%08x, mailHash=%08x, hasContent=%s",
			norm, request.requesterInventoryHash, request.requesterMailHash, tostring(hasContent))
	else
		-- No local data at all - send hash=0
		request.requesterInventoryHash = 0
		request.requesterMailHash = 0
		request.requesterHasContent = false
		TOGBankClassic_Output:Debug("DELTA", "BUILD", "[DELTA-014] QueryAltPullBased for %s: requester invHash=0 (no local entry)", norm)
	end

	local data = TOGBankClassic_Core:SerializeWithChecksum(request)

	-- QueryAltPullBased is "last resort" - WHISPER banker directly if online, GUILD broadcast if not
	-- (P2P guild broadcast should be done via BroadcastP2PRequest first)
	if not banker then
		-- No banker found in roster - broadcast to GUILD hoping someone has data
		TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-SYNC", "QueryAltPullBased for %s: no banker found, broadcasting to GUILD", norm)
		TOGBankClassic_Output:Debug("COMMS", "SEND", "Sending GUILD BROADCAST (no banker): togbank-r for alt %s", norm)
		TOGBankClassic_Core:SendCommMessage("togbank-r", data, "GUILD", nil, "NORMAL")
		self:MarkPendingSync("alt", "guild", norm)
		self.pendingAltRequests[norm] = now
		-- Track as pending P2P request so peer ACKs are processed
		self.pendingP2PRequests = self.pendingP2PRequests or {}
		self.pendingP2PRequests[norm] = { noBanker = true, requestedAt = now }
		return
	end

	if not self:IsPlayerOnline(banker) then
		-- Banker exists but offline - broadcast to GUILD hoping someone else has data
		TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-SYNC", "QueryAltPullBased for %s: banker %s offline, broadcasting to GUILD", norm, banker)
		TOGBankClassic_Output:Debug("COMMS", "SEND", "Sending GUILD BROADCAST (banker offline): togbank-r for alt %s", norm)
		TOGBankClassic_Core:SendCommMessage("togbank-r", data, "GUILD", nil, "NORMAL")
		self:MarkPendingSync("alt", "guild", norm)
		self.pendingAltRequests[norm] = now
		-- Track as pending P2P request so peer ACKs are processed
		self.pendingP2PRequests = self.pendingP2PRequests or {}
		self.pendingP2PRequests[norm] = { bankerOffline = true, requestedAt = now }
		return
	end

	-- Never whisper ourselves (WoW delivers whispers back to sender, causing self-loops)
	if banker == myPlayer then
		TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-SYNC", "Skipping self-query for alt %s - we are the banker (%s)", norm, banker)
		return
	end

	-- WHISPER banker as last resort (banker confirmed online)
	TOGBankClassic_Output:Debug("COMMS", "SEND", "Sending WHISPER (last resort): togbank-r to %s for alt %s", banker, norm)
	TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-SYNC", "WHISPER query for %s to banker %s (last resort after P2P timeout)", norm, banker)

	if not TOGBankClassic_Core:SendWhisper("togbank-r", data, banker, "NORMAL") then
		TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-SYNC", "WHISPER query failed for %s to %s", norm, banker)
		return
	end

	self:MarkPendingSync("alt", banker, norm)
	self.pendingAltRequests[norm] = now
end

-- SETTINGS-001: Broadcast guild-wide settings to all online members.
-- Only authorized senders (banker/officer/GM) may broadcast. Called after any settings change
-- and piggybacked onto the periodic SyncDeltaVersion cycle (TIMER_INTERVALS.VERSION_BROADCAST)
-- so new joiners also receive values.
function TOGBankClassic_Guild:BroadcastSettings(priority)
	if not self.Info or not self.Info.settings then return end
	local myPlayer = self:GetNormalizedPlayer()
	if not myPlayer then return end
	if not self:IsBank(myPlayer) and not self:SenderIsOfficer(myPlayer) and not self:SenderIsGM(myPlayer) then return end
	local payload = {
		type = "guild-settings",
		settings = {
			maxRequestPercent = self.Info.settings.maxRequestPercent,
			autoTombstoneDays = self.Info.settings.autoTombstoneDays,
			-- CANCELREASON-001: officer-authored custom cancel reasons + preset disable-set
			cancelReasons = self.Info.settings.cancelReasons,
			-- HELPNOTE-001: officer-authored per-window help-tooltip notes
			helpNotes = self.Info.settings.helpNotes,
		},
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	TOGBankClassic_Core:SendCommMessage("togbank-hl", data, "GUILD", nil, priority or "NORMAL")
	TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "BroadcastSettings: maxRequestPercent=%s autoTombstoneDays=%s",
		tostring(payload.settings.maxRequestPercent), tostring(payload.settings.autoTombstoneDays))
end

-- CANCELREASON-001: bounds for the synced cancel-reason config (keeps the
-- guild-settings broadcast small even with a misbehaving/old sender).
local CANCEL_REASON_MAX_CUSTOM = 20
local CANCEL_REASON_MAX_LEN    = 160

-- Sanitize an inbound cancelReasons table into the canonical shape, dropping
-- malformed entries and clamping count/length. Returns a fresh table.
local function sanitizeCancelReasons(cr)
	local clean = { custom = {}, presetDisabled = { banker = {}, member = {} } }
	if type(cr) ~= "table" then return clean end
	if type(cr.custom) == "table" then
		for _, r in ipairs(cr.custom) do
			if type(r) == "table" and type(r.text) == "string" and r.text ~= ""
				and #clean.custom < CANCEL_REASON_MAX_CUSTOM then
				clean.custom[#clean.custom + 1] = {
					text   = string.sub(r.text, 1, CANCEL_REASON_MAX_LEN),
					member = r.member and true or false,
					banker = r.banker and true or false,
				}
			end
		end
	end
	if type(cr.presetDisabled) == "table" then
		for _, role in ipairs({ "banker", "member" }) do
			local src = cr.presetDisabled[role]
			if type(src) == "table" then
				for key, val in pairs(src) do
					if type(key) == "string" and val then
						clean.presetDisabled[role][key] = true
					end
				end
			end
		end
	end
	return clean
end
TOGBankClassic_Guild.SanitizeCancelReasons = sanitizeCancelReasons

-- HELPNOTE-001: sanitize inbound per-window help notes (string, length-clamped,
-- only the three known window keys). Returns a fresh table.
local HELP_NOTE_MAX_LEN = 400
local function sanitizeHelpNotes(hn)
	local clean = { inventory = "", search = "", requests = "" }
	if type(hn) ~= "table" then return clean end
	for _, key in ipairs({ "inventory", "search", "requests" }) do
		local v = hn[key]
		if type(v) == "string" then
			clean[key] = string.sub(v, 1, HELP_NOTE_MAX_LEN)
		end
	end
	return clean
end
TOGBankClassic_Guild.SanitizeHelpNotes = sanitizeHelpNotes

-- HELPNOTE-001: the officer-authored note for a given window's help "?" tooltip
-- ("inventory" / "search" / "requests"). Returns "" when none set.
function TOGBankClassic_Guild:GetHelpNote(windowKey)
	local s = self.Info and self.Info.settings
	local notes = s and s.helpNotes
	if type(notes) ~= "table" then return "" end
	local n = notes[windowKey]
	return (type(n) == "string") and n or ""
end

-- SETTINGS-001: Apply settings received from a remote authorized sender.
-- Validates sender auth and bounds-checks values before writing to Guild.Info.settings.
function TOGBankClassic_Guild:ApplyRemoteSettings(sender, settings)
	if not settings or type(settings) ~= "table" then return end
	if not self:SenderHasGbankNote(sender) and not self:SenderIsGM(sender) and not self:SenderIsOfficer(sender) then
		TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "ApplyRemoteSettings: sender %s not authorized, ignoring", tostring(sender))
		return
	end
	if not self.Info then return end
	if not self.Info.settings then self.Info.settings = {} end
	if type(settings.maxRequestPercent) == "number" and settings.maxRequestPercent >= 1 and settings.maxRequestPercent <= 100 then
		self.Info.settings.maxRequestPercent = math.floor(settings.maxRequestPercent)
	end
	if type(settings.autoTombstoneDays) == "number" and settings.autoTombstoneDays >= 1 then
		self.Info.settings.autoTombstoneDays = math.floor(settings.autoTombstoneDays)
	end
	-- CANCELREASON-001: apply synced cancel-reason config only when the sender
	-- actually carried one (older clients omit the field — don't wipe local).
	if settings.cancelReasons ~= nil then
		self.Info.settings.cancelReasons = sanitizeCancelReasons(settings.cancelReasons)
	end
	-- HELPNOTE-001: apply synced help notes only when present (old clients omit it).
	if settings.helpNotes ~= nil then
		self.Info.settings.helpNotes = sanitizeHelpNotes(settings.helpNotes)
	end
	TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "ApplyRemoteSettings from %s: maxRequestPercent=%s autoTombstoneDays=%s cancelCustom=%d",
		tostring(sender), tostring(self.Info.settings.maxRequestPercent), tostring(self.Info.settings.autoTombstoneDays),
		(self.Info.settings.cancelReasons and self.Info.settings.cancelReasons.custom and #self.Info.settings.cancelReasons.custom) or 0)
end

-- returns true if the given normalized sender has a public or officer note containing 'gbank'
function TOGBankClassic_Guild:SenderHasGbankNote(sender)
	if not sender then
		return false
	end
	for i = 1, GetNumGuildMembers() do
		local playerRealm, _, _, _, _, _, publicNote, officer_note = GetGuildRosterInfo(i)
		if playerRealm then
			local norm = self:NormalizeName(playerRealm)
			if norm == sender then
				if
					(publicNote and string.match(publicNote, "(.*)gbank(.*)"))
					or (officer_note and string.match(officer_note, "(.*)gbank(.*)"))
				then
					return true
				end
			end
		end
	end
	return false
end

-- Refresh the full guild roster cache from current guild roster
-- Called automatically when GUILD_ROSTER_UPDATE event fires
-- Builds comprehensive roster with ALL members and online/offline state
-- ROSTER-003: subscribe to LibGuildRoster's presence and membership callbacks.
--
-- This REPLACES TOGBankClassic_Events:CHAT_MSG_SYSTEM, which never ran (EVENT-001): its handler
-- signature omitted the leading event-name parameter, so it read the string "CHAT_MSG_SYSTEM" as
-- the message and matched nothing, for every release the addon has ever shipped.
--
-- The library owns the event registration and its handling is covered by its own suite, so the
-- failure mode that produced EVENT-001 -- a consumer wiring an event up incorrectly and nothing
-- noticing -- is gone rather than fixed in place.
--
-- Idempotent: CallbackHandler would happily register the same handler twice and double-fire.
function TOGBankClassic_Guild:InitRosterCallbacks()
	if self._rosterCallbacksBound then
		return true
	end
	local lib = RosterLib()
	if not lib or not lib.RegisterCallback then
		TOGBankClassic_Output:Debug("ROSTER", "REFRESH",
			"LibGuildRoster-1.0 not available - falling back to the legacy roster scan")
		return false
	end

	-- ROSTER-003: transition counters. A snapshot comparison cannot show that the presence
	-- callbacks are actually LIVE -- both sides agreeing proves only that the copy is faithful.
	-- These count real transitions since login so /togbank dev rostercheck can report direct
	-- evidence the mechanism fires, which is the part of EVENT-001 a snapshot can't reach.
	self.rosterStats = { online = 0, offline = 0, notFound = 0, recent = {} }

	local function note(kind, name)
		local s = TOGBankClassic_Guild.rosterStats
		s[kind] = (s[kind] or 0) + 1
		table.insert(s.recent, string.format("%s %s", kind, tostring(name)))
		while #s.recent > 5 do table.remove(s.recent, 1) end
	end
	TOGBankClassic_Guild.NoteRosterEvent = function(_, kind, name) note(kind, name) end

	lib.RegisterCallback(self, "OnMemberOnline", function(_, name)
		note("online", name)
		TOGBankClassic_Guild:UpdateOnlineMember(name, true, "libguildroster-online")
	end)
	lib.RegisterCallback(self, "OnMemberOffline", function(_, name)
		note("offline", name)
		TOGBankClassic_Guild:UpdateOnlineMember(name, false, "libguildroster-offline")
	end)

	-- Membership changes can add or remove a banker, so the note-derived caches must be dropped.
	--
	-- ROSTER-005: this used to invalidate banksCache ONLY, on the belief that GUILD_ROSTER_UPDATE
	-- would drive RebuildBankerRoster. It does not: Events.lua ignores that event once login init
	-- completes, and GetBanks() re-derives from memberRoster -- which nobody had rebuilt, so the
	-- departed banker came straight back into the list and IsBank stayed true until relog, even
	-- with the system message delivered. The library has already applied the change before it
	-- fires (LibGuildRoster-1.0.lua:2228 nils the entry, :2243 fires), so re-pulling memberRoster
	-- from it here is the whole fix; it is one pass over GetAllMembers, the same work as login.
	--
	-- _RefreshFromRosterLib DIRECTLY, not RefreshOnlineCache: the latter falls back to the
	-- synchronous GetGuildRosterInfo walk when the library reports not-ready, and that walk is the
	-- multi-second freeze PERF-008 deferred off the login path. This callback comes FROM the library,
	-- so it is ready by construction -- but a chat event must never be able to reach that loop. If
	-- the library ever answers nil here, the cache is left as it was and the next login rebuilds it.
	local function onMembershipChanged(_, name)
		TOGBankClassic_Output:Debug("ROSTER", "REFRESH",
			"Roster membership changed (%s) - rebuilding member cache", tostring(name))
		TOGBankClassic_Guild:_RefreshFromRosterLib()
		TOGBankClassic_Guild:InvalidateBanksCache()
	end
	lib.RegisterCallback(self, "OnMemberJoined", onMembershipChanged)
	lib.RegisterCallback(self, "OnMemberLeft",   onMembershipChanged)

	self._rosterCallbacksBound = true
	TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "LibGuildRoster presence callbacks bound")
	return true
end

-- ROSTER-003: build memberRoster from LibGuildRoster instead of scanning GetGuildRosterInfo.
--
-- Returns onlineCount, totalMembers on success, or nil when the library can't answer (absent,
-- or not yet stabilized) so the caller falls back to the legacy scan below.
--
-- Why this matters beyond tidiness, stated correctly -- THIS COMMENT USED TO BE WRONG and the
-- error was load-bearing. It said "the library wipes and rebuilds its roster on every update, so a
-- member who has left the guild cannot survive in it", and called ROSTER-002's failure mode
-- structurally impossible. LibGuildRoster does nothing of the kind.
--
-- THE LIBRARY IS BUILD-ONCE. `LibGuildRoster-1.0.lua:1587` says so in as many words -- "BUILD ONCE.
-- THE ROSTER IS NEVER REBUILT" -- and `:1613` returns early from GUILD_ROSTER_UPDATE the moment it
-- is initialized. It constructs the roster during the login stream and then maintains membership
-- from CHAT_MSG_SYSTEM alone: ERR_GUILD_JOIN_S, ERR_GUILD_LEAVE_S, ERR_GUILD_REMOVE_SS.
--
-- WHAT THIS FUNCTION ACTUALLY GUARANTEES, which is narrower and worth knowing: TOGBank wipes its
-- OWN memberRoster and rebuilds it from lib:GetAllMembers(), so it holds exactly what the library
-- holds and cannot accumulate stale entries of its own on top. The library's own membership is
-- kept current by chat parsing plus a fresh build at the next login.
--
-- SO THERE IS A REAL WINDOW: a departure whose system message is never delivered -- missed, or
-- suppressed -- persists until relog. That is weaker than "impossible" and anyone reasoning about
-- ex-member staleness needs the true version. The wrong comment sent a spec at the wrong mechanism
-- (it emptied the fake roster, fired GUILD_ROSTER_UPDATE, and read the survivor as a TOGBank bug
-- when TOGBank was correct), which is how a misleading comment costs more than a missing one.
--
-- The derived fields (isBank, viewOnly, isOfficer) stay HERE. Banker identification is this
-- addon's domain logic; the library's job is to hand over the raw notes, and it does.
function TOGBankClassic_Guild:_RefreshFromRosterLib()
	local lib = RosterLib()
	if not lib or not lib.GetAllMembers or not lib:IsReady() then
		return nil
	end

	local names = lib:GetAllMembers()
	if not names or #names == 0 then
		return nil
	end

	-- REQSYNC-008: same officer-rank inference as the legacy path. Classic has no per-rank
	-- permission API, but ranks are strictly ordered (lower rankIndex = more permissions), so
	-- if the local player can read officer notes then so can everyone at or above their rank.
	local localOfficerThreshold = nil
	if CanViewOfficerNote and CanViewOfficerNote() then
		local me = lib:GetNormalizedPlayer()
		local meMember = me and lib:GetMember(me)
		localOfficerThreshold = meMember and meMember.rankIndex or nil
	end

	wipe(self.memberRoster)
	wipe(self.onlineMembers)

	local onlineCount = 0
	for _, name in ipairs(names) do
		local m = lib:GetMember(name)
		if m then
			-- tostring guards a library that ever hands back a non-string note; the plain-text
			-- find (not a pattern) is orders of magnitude faster than "(.*)gbank(.*)".
			local note        = tostring(m.publicNote or "")
			local officernote = tostring(m.officerNote or "")
			local isBank = (string.find(note, "gbank", 1, true) ~= nil)
				or (string.find(officernote, "gbank", 1, true) ~= nil)
			local isOfficer = (m.rankIndex == 0)
				or (localOfficerThreshold ~= nil and m.rankIndex ~= nil
					and m.rankIndex <= localOfficerThreshold)

			self.memberRoster[name] = {
				name        = name,
				class       = m.class,
				level       = m.level or 1,
				rankIndex   = m.rankIndex,
				rankName    = m.rankName,
				isOnline    = m.isOnline or false,
				isOfficer   = isOfficer,
				isBank      = isBank or false,
				-- VIEWBANK-001: the view-only marker is only meaningful on a banker.
				viewOnly    = (isBank and noteIsViewOnly(note, officernote)) or false,
				-- BANKERS-FILTER-001: the public note, kept for what it says BESIDE the gbank marker
				-- ("gbank herbs & potions") -- the Bankers tab's "Stores" text. Bankers only.
				note        = isBank and note or nil,
				lastUpdated = GetServerTime(),
			}

			if m.isOnline then
				self.onlineMembers[name] = true
				onlineCount = onlineCount + 1
			end
		end
	end

	return onlineCount, #names
end

--- BROWSE-008: which bankers are online right now, as `{ [name] = true }`, for the before/after
--- compare in RefreshOnlineCache. Bankers only: the Bankers tab and the Inventory tabs paint
--- nothing about anyone else, and a repaint per roster event (every ten seconds in a busy guild)
--- rebuilds the whole tab strip for nothing.
local function bankersOnline(self)
	local out = {}
	for name, m in pairs(self.memberRoster or {}) do
		if m.isBank and m.isOnline then out[name] = true end
	end
	return out
end

--- BROWSE-008: a banker logged in or out. The operator: "is there a refresh on the new banker tab
--- when something updates?" -- for data, yes (every claim and delivery goes through
--- UI_Inventory:RefreshSoon, which fans out to the Guild Bank window); for the ONLINE column, no:
--- nothing anywhere repainted on a roster change, so "Online: yes" stayed until the next data
--- signal happened along. One notify, on an actual change, through the same fan-out.
local function notifyIfBankersOnlineChanged(self, before)
	local after = bankersOnline(self)
	local changed = false
	for name in pairs(before) do if not after[name] then changed = true break end end
	if not changed then
		for name in pairs(after) do if not before[name] then changed = true break end end
	end
	if changed and TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.RefreshSoon then
		TOGBankClassic_UI_Inventory:RefreshSoon()
	end
	return changed
end

function TOGBankClassic_Guild:RefreshOnlineCache()
	local startTime = debugprofilestop()
	self.memberRoster = self.memberRoster or {}
	self.onlineMembers = self.onlineMembers or {}
	local before = bankersOnline(self)   -- BROWSE-008

	-- ROSTER-003: prefer the library. Falls through to the legacy scan when it can't answer.
	local libOnline, libTotal = self:_RefreshFromRosterLib()
	if libOnline then
		local libDuration = debugprofilestop() - startTime
		TOGBankClassic_Performance:RecordOperation("RefreshOnlineCache", libDuration)
		TOGBankClassic_Output:Debug("CACHE", "REFRESH",
			"Refreshed roster from LibGuildRoster: %d total, %d online (%.1f ms)",
			libTotal, libOnline, libDuration)
		notifyIfBankersOnlineChanged(self, before)
		return libOnline, libTotal
	end

	TOGBankClassic_Output:Debug("ROSTER", "REFRESH",
		"LibGuildRoster unavailable or not ready - using the legacy GetGuildRosterInfo scan")

	wipe(self.memberRoster)
	wipe(self.onlineMembers)

	local totalMembers = GetNumGuildMembers()
	TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[INIT] GetNumGuildMembers() returned %d", totalMembers or 0)

	local onlineCount = 0

	-- REQSYNC-008: Determine the officer rank threshold at cache-build time.
	-- Classic Era has no per-rank permission API (GuildControlGetRankFlags is Retail-only).
	-- CanViewOfficerNote() tells us whether the LOCAL player has officer-note access.
	-- In Classic, ranks are strictly ordered: lower rankIndex = more permissions.
	-- Therefore if the local player at rankIndex N can view officer notes, every member
	-- with rankIndex <= N also has officer-note access.
	-- If local player cannot view officer notes, only rankIndex 0 (GM) is definitive.
	local localOfficerThreshold = nil
	if CanViewOfficerNote and CanViewOfficerNote() then
		local localName = self:GetNormalizedPlayer()
		if localName then
			for i = 1, totalMembers do
				local n, _, ri = GetGuildRosterInfo(i)
				if n and self:NormalizeName(n) == localName then
					localOfficerThreshold = ri
					break
				end
			end
		end
		TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "Officer threshold rankIndex: %s", tostring(localOfficerThreshold))
	end

	-- Build full roster with explicit online/offline state for ALL members
	for i = 1, totalMembers do
		local name, rankName, rankIndex, level, _, _, note, officernote, isOnline, _, classFileName = GetGuildRosterInfo(i)
		if name then
			local normalized = self:NormalizeName(name)
			if normalized then
				-- isOfficer: GM always qualifies; otherwise true only if local player can see
				-- officer notes AND this member's rank is at or above the local player's rank.
				local isOfficer = (rankIndex == 0) or
					(localOfficerThreshold ~= nil and rankIndex <= localOfficerThreshold)
				-- PERF: plain-text find is orders of magnitude faster than (.*)gbank(.*) pattern
				local isBank = (note and note:find("gbank", 1, true) ~= nil)
					or (officernote and officernote:find("gbank", 1, true) ~= nil)
				-- VIEWBANK-001: view-only flag only meaningful for bankers
				local viewOnly = isBank and noteIsViewOnly(note, officernote)
				-- Store full member data
				self.memberRoster[normalized] = {
					name = normalized,
					class = classFileName,
					level = level or 1,
					rankIndex = rankIndex,
					rankName = rankName,
					isOnline = isOnline or false,
					isOfficer = isOfficer,
					isBank = isBank or false,
					viewOnly = viewOnly or false,
					note = isBank and note or nil,   -- BANKERS-FILTER-001, as the library path keeps it
					lastUpdated = GetServerTime()
				}

				-- Update legacy onlineMembers cache for backwards compatibility
				if isOnline then
					self.onlineMembers[normalized] = true
					onlineCount = onlineCount + 1
				end
			end
		end
	end

	local duration = debugprofilestop() - startTime
	TOGBankClassic_Performance:RecordOperation("RefreshOnlineCache", duration)
	TOGBankClassic_Output:Debug("CACHE", "REFRESH", "Refreshed guild roster cache: %d total, %d online (%.1f ms)",
		totalMembers or 0, onlineCount, duration)
	TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "[GUILD ROSTER] Refreshed online cache: %d/%d members online", onlineCount, totalMembers or 0)

	notifyIfBankersOnlineChanged(self, before)   -- BROWSE-008
	return onlineCount, totalMembers
end

-- Update a single member's online state (from CHAT_MSG_SYSTEM or addon messages)
-- Handles both full roster updates and incremental state changes
function TOGBankClassic_Guild:UpdateOnlineMember(memberName, isOnline, source)
	if not memberName then
		return
	end

	self.memberRoster = self.memberRoster or {}
	self.onlineMembers = self.onlineMembers or {}
	self.recentlySeen = self.recentlySeen or {}

	local normalized = self:NormalizeName(memberName)
	if not normalized then
		return
	end

	source = source or "unknown"
	-- BROWSE-008: this runs for EVERY inbound message (OnCommReceived marks the sender online), so
	-- the roster walk is taken only when the member is a banker -- the only case that can repaint.
	-- Peer Review bee7f23f F1: an OFFLINE update matches by BASE name across realm variants below
	-- (the system message carries no realm), so `normalized` can name a realm the banker is not on
	-- and IsBank(normalized) answer false for a banker who IS going offline -- and the Online column
	-- kept "yes". Offline updates are rare (one system message each), so the walk is always taken
	-- for them; the online path keeps the banker-only gate, being the per-message one.
	local before = (not isOnline or self:IsBank(normalized)) and bankersOnline(self) or nil

	if isOnline then
		-- Mark player as online
		-- Update full roster entry if it exists
		if self.memberRoster[normalized] then
			self.memberRoster[normalized].isOnline = true
			self.memberRoster[normalized].lastUpdated = GetServerTime()
		else
			-- Create stub entry if member not in roster yet (shouldn't happen, but safeguard)
			--
			-- `isStub` IS A SECURITY MARKER, not a diagnostic. This entry is created from an
			-- unauthenticated fact -- "a message arrived claiming to be from this name" -- and
			-- Chat:OnCommReceived calls this for EVERY inbound message before any authorisation
			-- runs. Without the marker, `IsInCurrentGuildRoster` is satisfied by the entry's mere
			-- existence, so sending a message is enough to be treated as a guild member: the
			-- roster check in IsAltDataAllowed was defeated by the act of receiving. Found by
			-- Tests/syncwire_spec.lua's two-client join, which is the first test that ever drove
			-- OnCommReceived from a sender who was not in the roster.
			self.memberRoster[normalized] = {
				name = normalized,
				class = "Unknown",
				level = 0,
				isOnline = true,
				isStub = true,
				lastUpdated = GetServerTime()
			}
			TOGBankClassic_Output:Debug("ROSTER", "ONLINE", "[ONLINE-UPDATE] Created stub entry for %s (source: %s)", normalized, source)
		end

		-- Update legacy cache
		self.onlineMembers[normalized] = true

		TOGBankClassic_Output:Debug("ROSTER", "ONLINE", "[ONLINE-UPDATE] %s marked ONLINE (source: %s)", normalized, source)
	else
		--Mark player as offline
		-- CRITICAL: Handle cross-realm and same-server name variants
		-- WoW error messages NEVER include realm: "No player named Eturnity is currently playing"
		-- But our cache stores "Eturnity-Myzrael"

		local baseName = memberName:match("^(.-)%-") or memberName
		local markedOffline = false

		-- Search memberRoster for ALL variants of this base name
		for cachedName, memberData in pairs(self.memberRoster) do
			local cachedBase = cachedName:match("^(.-)%-") or cachedName
			if cachedBase == baseName or cachedName == normalized then
				memberData.isOnline = false
				memberData.lastUpdated = GetServerTime()
				self.onlineMembers[cachedName] = nil
				self.recentlySeen[cachedName] = nil
				markedOffline = true
				TOGBankClassic_Output:Debug("ROSTER", "ONLINE", "[OFFLINE-UPDATE] %s marked OFFLINE (matched base: %s, source: %s)",
					cachedName, baseName, source)
			end
		end

		-- Also clear from legacy caches by base name search
		if not memberName:find("-") then
			-- Clear all realm variants when error message has no realm
			for cachedName, _ in pairs(self.onlineMembers) do
				local cachedBase = cachedName:match("^(.-)%-") or cachedName
				if cachedBase == baseName then
					self.onlineMembers[cachedName] = nil
				end
			end
			for cachedName, _ in pairs(self.recentlySeen) do
				local cachedBase = cachedName:match("^(.-)%-") or cachedName
				if cachedBase == baseName then
					self.recentlySeen[cachedName] = nil
				end
			end
		end

		if not markedOffline then
			TOGBankClassic_Output:Debug("ROSTER", "ONLINE", "[OFFLINE-UPDATE] WARNING: No member found matching %s / base %s (source: %s)",
				normalized, baseName, source)
		end
	end
	if before then notifyIfBankersOnlineChanged(self, before) end   -- BROWSE-008
end

function TOGBankClassic_Guild:IsPlayerOnline(playerName)
	if not playerName then
		return false
	end
	local norm = self:NormalizeName(playerName)

	-- ROSTER-003: the library is authoritative once it has stabilized. It tracks presence from
	-- CHAT_MSG_SYSTEM in real time, so its answer is fresher than memberRoster, which only moves
	-- on a full GUILD_ROSTER_UPDATE sweep. Gated on IsReady() because before that the library is
	-- still retrying the initial build and would report everyone offline.
	local lib = RosterLib()
	if lib and lib:IsReady() and lib:IsInGuild(norm) then
		return lib:IsOnline(norm) == true
	end

	-- Fallback: our own cache (library absent, or not ready yet).
	if self.memberRoster and self.memberRoster[norm] then
		return self.memberRoster[norm].isOnline == true
	end

	-- Legacy fallback for backwards compatibility during transition
	return self.onlineMembers and self.onlineMembers[norm] == true
end

-- THE DELTA RELEASE step 3b: `ComputeStateSummary`, `SendStateSummary` and `RespondToStateSummary`
-- WERE HERE (~250 lines) and are deleted with the `togbank-state` prefix they spoke. The requester
-- now asks on the DeltaSync host's QUERY channel naming the canon it holds, and the provider
-- answers on the RESPONSE channel with the delta chain, a snapshot, or a no-change -- all of it in
-- Modules/Inventory/Sync.lua (RequestFrom / OnDataRequest). What the responder decided here on
-- four hashes it now decides on the canon alone; the revision-1 fallback for two canon-less copies
-- is gone with it ("v1 is always red"): a copy with no canon is answered with the snapshot, which
-- is how it acquires one. P2P-028's rule survives the move -- every terminal outcome of a request
-- releases the send slot the accept took.
-- INV2: `StripItemLinks` and `StripAltLinks` were deleted here. Both were dead -- `StripAltLinks`
-- had no caller anywhere in the addon and was `StripItemLinks`'s only one -- and both implemented
-- the mechanism V2 exists to remove: deciding, per item, whether a link is safe to drop, keeping
-- the full link for gear/uncached/ForceLink rows and an `ItemString` otherwise. That decision is
-- what corrupts data, because it is a guess about the client's cache made at transmission time.
--
-- V2 does not make the decision. A row on the wire is {id, count, suffix, enchant} and the
-- receiver rebuilds the link from those integers via LibItemDB (Modules/Inventory/Resolve.lua),
-- so there is no link to strip and nothing to get wrong.

-- INV2 step 10: THE BATCHED LINK-RECONSTRUCTION QUEUE WAS HERE and is deleted with
-- `ReconstructItemLinks`, its only entry point, which went with `ReceiveAltData`.
--
-- WHAT IT WAS: `itemReconstructQueue` plus `ProcessItemQueue`, ~130 lines of asynchronous machinery
-- -- a concurrency cap, a batch size, a re-queue path, `ContinueOnItemLoad` callbacks wrapped in
-- pcall, and a throttled UI refresh -- whose entire job was to turn the ItemStrings in a received
-- LEGACY payload back into item links, slowly enough not to stutter the client.
--
-- WHY IT IS GONE RATHER THAN KEPT FOR LATER: it exists only because the legacy format shipped links
-- and item strings across the wire in the first place. V2 sends `{id, count, suffix, enchant}` and
-- the link is built from LibItemDB on arrival, so there is no backlog of link-less rows to work
-- through and nothing to schedule. This is the link machinery the operator's directive is about:
-- "we are redesigning to get RID of this complexity because it's causing data corruption".
--
-- `ThrottledUIRefresh` AND `lastUIRefresh` WENT WITH IT. Every caller was inside this queue or
-- inside `ReceiveAltData`: it existed to repaint the Inventory and Search windows as async link
-- loads trickled in, at most twice a second so the client did not stutter. Nothing trickles in any
-- more -- a V2 payload resolves its rows on arrival and the UI redraws once -- so there is no
-- stream of late completions to coalesce.
--
-- NOT TO BE CONFUSED WITH `ReconstructItemLink` (SINGULAR), which is alive and called by
-- Modules/UI.lua:320 and :339 while drawing, for records that still carry an ItemString. The names
-- differ by one character; check the call sites before assuming that one went too.

-- Reconstruct single item link (immediate, synchronous only)
function TOGBankClassic_Guild:ReconstructItemLink(item)
	if not item or not item.ID or item.Link then
		return
	end

	-- Try synchronous reconstruction from cache only
	if item.ItemString then
		local itemName = GetItemInfo(item.ID)
		if itemName then
			-- Strip "item:" prefix defensively (mail items may store ItemString with prefix)
			local rawStr = item.ItemString:match("^item:(.+)$") or item.ItemString
			item.Link = string.format("|cffffffff|Hitem:%s|h[%s]|h|r", rawStr, itemName)
		end
	else
		local itemLink = select(2, GetItemInfo(item.ID))
		if itemLink then
			item.Link = itemLink
		end
	end
	-- Note: If not in cache, link stays nil - will be reconstructed by queue
end

-- `ReconstructItemLinks` (PLURAL) was deleted here along with `ReceiveAltData`, its only caller.
-- It queued every link-less item from a received LEGACY payload for async link reconstruction --
-- work that exists only because that format shipped links in the first place. V2 sends integers and
-- the link is built from LibItemDB on arrival, so there is nothing to reconstruct in a batch.
--
-- `ReconstructItemLink` (SINGULAR) is NOT dead and must stay: Modules/UI.lua:320 and :339 call it
-- while drawing, for records that predate V2 and still carry an ItemString rather than a link. The
-- names differ by one character, so check the call sites before assuming this one went too.

-- INV2 step 10: `Guild:StripDeltaLinks` was deleted here along with the DeltaComms function it
-- delegated to. It was the wrapper for the per-item "is this link safe to drop" guess; V2 sends
-- integers and rebuilds the link from LibItemDB on the receiving side, so there is no such decision
-- left to make. See the note at its former call site in SendAltData.

-- INV2-RETIRE-003: `EnsureLegacyFields` WAS HERE and is deleted. It created empty `bank.items` /
-- `bags.items` arrays on a record "so legacy iteration code doesn't nil-error" -- and every legacy
-- iterator is gone or going (docs/DELTA_RELEASE.md section 4). Its history is worth one line: it
-- once COPIED the aggregate into `bank.items` as a "reconstruction", which double-counted mail on
-- every delta apply (ITEM-004, docs/DELTA_BUGS.md, "of Power" Count=6237 in real SavedVariables);
-- the fix left the arrays empty, and now nothing needs them at all.

-- ACQ-004: the send verdict is a BOOLEAN, never a SendAddonMessageResult enum member.
--
-- The enum is lost two layers below us and cannot be recovered here:
--   1. ChatThrottleLib:Despool retries only AddonMessageThrottle; GeneralError, NotInGroup and
--      ChannelThrottle are dequeued and destroyed with no retry.
--   2. AceComm-3.0's ctlCallback declares two parameters, so CTL's (arg, didSend, sendResult)
--      drops the enum and only the didSend boolean survives.
--
-- This module previously compared argument 4 against an enum table, so `isThrottled` could
-- never be true and the throttled counter was permanently 0. Those comparisons are deleted
-- rather than corrected: there is no value of argument 4 that could ever satisfy them.
--
-- The contract AceCommQueue-1.0 MINOR 5+ actually provides:
--   true  — delivered (every chunk accepted; the verdict covers the WHOLE message)
--   false — refused, after the library's own retry/backoff gave up
--   nil   — not attempted (e.g. suppressed by our in-raid guard, which reports 0/0/nil)
local function DescribeSendResult(result)
	if result == true then return "delivered"
	elseif result == false then return "refused"
	elseif result == nil then return "not attempted"
	else return tostring(result)
	end
end

-- Create a per-send callback with its own stats tracking
-- FIX: Prevents stats corruption when multiple P2P sends happen concurrently
-- NOTE: AceCommQueue delivers only the final callback (when bytesSent >= totalBytes),
-- so startTime is captured at closure creation and chunk count is estimated from byte count.
local function CreateOnChunkSentCallback(altName, requester)
	-- Per-send stats (closure captures these)
	-- startTime is recorded NOW so elapsed is measured from just before SendCommMessage.
	-- ACQ-004: no `throttled` counter any more. It could only be incremented by the enum
	-- comparison deleted above, so it was permanently 0 while still being printed in the
	-- summary — a statistic that reads as "no throttling occurred" when it in fact measured
	-- nothing. Throttling is now the library's business: it retries with backoff and only
	-- reports `false` once it has given up, so a refusal reaching us is already terminal.
	local sendStats = {
		startTime = GetTime(),
		failures = 0,
	}

	return function(_, bytesSent, totalBytes, sendResult)
		-- ACQ-004: only `false` means the send was refused. `nil` is "not attempted" — our
		-- in-raid guard reports (0, 0, nil) to unblock the queue — and must not be counted as
		-- a failure, or every suppressed send would look like a delivery error.
		local refused = (sendResult == false)
		if refused then
			sendStats.failures = sendStats.failures + 1
		end

		-- AceCommQueue only delivers the final callback (sent >= total), so
		-- chunk count is estimated rather than tracked per-invocation.
		local totalChunks = math.ceil(totalBytes / 254)

		if refused then
			-- Reaching here means the library already retried and gave up, so this is a real
			-- lost message rather than a transient throttle. Loud on purpose: silent loss on
			-- an inventory send is what leaves peers with stale data and no way to tell.
			TOGBankClassic_Output:Error(
				"send to %s for %s was refused by the client after retries (%s) - peers may hold stale data",
				tostring(requester or "guild"), tostring(altName), DescribeSendResult(sendResult))
		end

		-- Completion summary
		if bytesSent >= totalBytes then
			local elapsed = GetTime() - sendStats.startTime
			local summary = string.format(
				"Send complete: ~%d chunks, %d bytes in %.1fs",
				totalChunks, totalBytes, elapsed
			)
			if sendStats.failures > 0 then
				summary = summary .. string.format(" | REFUSED: %d", sendStats.failures)
			end

			if not TOGBankClassic_Options:IsSyncProgressMuted() then
				TOGBankClassic_Output:Info(summary)
			end

			-- Release the unified P2P send slot so the cap allows new sends.
			-- P2P-025: an `elseif pendingSendCount > 0` legacy branch followed this, for
			-- GUILD-broadcast sends with no requester. The counter it decremented was never
			-- incremented, so the branch could not be reached with a true condition.
			--
			-- FINDING 28: release AT MOST ONCE per send. `ReleaseSendSlot`'s token-less branch
			-- retires the OLDEST outstanding token for this requester -- which, with two sends in
			-- flight for them, belongs to the OTHER send. So a duplicated completion callback
			-- would retire send B's token and decrement B's slot, re-opening the over-release
			-- P2P-024 closed. The token protects the TIMER path from the completion path; nothing
			-- protected the completion path from itself. `sendStats` is already this send's own
			-- state, so the identity is carried here rather than threaded across the two acquire
			-- sites (Chat.lua, P2PSession.lua) and the send call chain between them.
			if requester and TOGBankClassic_P2PSession and not sendStats.slotReleased then
				sendStats.slotReleased = true
				TOGBankClassic_P2PSession:ReleaseSendSlot(requester, "send_complete")
			end

			-- Warn on failures
			if sendStats.failures > 0 then
				TOGBankClassic_Output:Warn("%d send failures occurred!", sendStats.failures)
			end
		end
	end
end

--- THE MANUAL SHARE: broadcast an alt's full tuple snapshot to GUILD (`/togbank share`).
---
--- THE DELTA RELEASE step 3b: this used to be every data send -- the WHISPER answer to a
--- requester's state summary as well as the broadcast -- and so carried a `target`, the
--- requester's hashes (unused since INV2 step 10) and the P2P slot release. The whispered reply
--- now goes over the DeltaSync host (Modules/Inventory/Sync.lua: the chain when it connects, the
--- snapshot otherwise, the slot released when the send has drained), so what is left here is the
--- one-to-many case, which genuinely serves every listener with a single message and is the only
--- inventory traffic that belongs on GUILD (see the channel note in Modules/Chat.lua).
---
--- The payload is the same Wire.encode array the host's `inv-snapshot` carries, built by the one
--- builder (Sync:SnapshotPayload) so the two cannot drift. HASH-CANON-001: it carries the author's
--- canon, revision-1 hash, publish time and mail hash VERBATIM -- stamped at scan, never recomputed
--- here.
---
--- GATED ON `sendV2Wire` VIA Wire.shouldSendV2(): emission is the half a peer can see, so it is
--- the half that must be flippable on its own as a diagnostic. Off means send nothing -- the legacy
--- link format is gone in both directions.
function TOGBankClassic_Guild:SendAltData(name)
	if not name then return end
	local norm = self:NormalizeName(name)
	if not self.Info or not self.Info.alts or not self.Info.alts[norm] then return end
	TOGBankClassic_Output:Debug("PROTOCOL", "ALT-REQUEST", "[RESPONSE] Sending %s data via GUILD broadcast (manual share)", norm)

	local Wire, Sync = TOGBankClassic_Inventory_Wire, TOGBankClassic_Inventory_Sync
	if Wire and Wire.shouldSendV2() and Sync then
		local payload, count = Sync:SnapshotPayload(norm)
		if payload then
			local body = TOGBankClassic_Core:SerializeWithChecksum(payload)
			local onSent = CreateOnChunkSentCallback(norm, nil)
			if not TOGBankClassic_Options:IsSyncProgressMuted() then
				TOGBankClassic_Output:Info("Sharing guild bank data: %d bytes in ~%d chunks...",
					string.len(body), math.ceil(string.len(body) / 254))
			end
			TOGBankClassic_Core:SendCommMessage("togbank-d4", body, "GUILD", nil, "BULK", onSent)
			TOGBankClassic_Output:Debug("DELTA", "BUILD",
				"[INV2] sent %d tuple(s) for %s via togbank-d4 to GUILD (%d bytes, canon=%s)",
				count, norm, string.len(body), tostring(self.Info.alts[norm].inventoryHashV2))
			return
		end
	end

	-- Reaching here is a real condition worth reporting: this client holds a record for the alt
	-- but no V2 rows, so it has not rescanned since upgrading. The remedy is a scan.
	TOGBankClassic_Output:Debug("DELTA", "BUILD",
		"[INV2] no tuple records for %s -- nothing sent. This client has not scanned since " ..
		"upgrading; open and close the bank to populate the V2 store.", norm)
	if not TOGBankClassic_Options:IsSyncProgressMuted() then
		TOGBankClassic_Output:Warn(
			"No V2 inventory for %s yet - open and close your bank to scan, then it will sync.", norm)
	end
end

-- INV2 step 10 / the 2026-09-09 directive: `ReceiveAltData` WAS HERE, ~430 lines, and it is
-- deleted rather than left unreached. Its only caller was the `data.type == "alt"` branch on the
-- `togbank-rm` prefix in Chat.lua, deleted with it.
--
-- WHAT IT DID: took a link-bearing LEGACY alt payload off the wire and wrote `alt.items`,
-- `alt.bank.items` and `alt.bags.items` from it, with sanitising, the DATA-004/DATA-006 banker
-- protection rules, and an OPTION-B timestamp comparison. None of it ever met the tuples-only
-- guard on `togbank-d4`, so the no-backwards-compatibility directive was being enforced on one
-- inventory path and not the other.
--
-- VALIDATED AS UNFED BEFORE DELETING, so nobody re-derives it: the released v1.3.2 (`4d8fe14`)
-- sends alt inventory on `togbank-d4` (`Guild.lua:2697` there) and its ONLY `togbank-rm` sender is
-- `RequestLog.lua:1070`, request mutations. No shipped version sends inventory on that prefix.
-- So this was dead code, NOT the source of the corruption reported from the live guild -- that was
-- INV2-ORDER-001 (no last-writer-wins guard on the tuple path) and HASH-CANON-002 (the hash being
-- re-minted by every client). It is removed because a bypass nothing currently drives is still a
-- bypass, and because the directive says delete rather than branch around.
--
-- WHAT WAS WORTH KEEPING FROM IT, and where it went: its OPTION-B ordering check was the only
-- last-writer-wins logic in the addon, and reading it is what revealed the tuple path had none.
-- That rule now lives in `Chat:ShouldApplyTuplePayload`, in one place, ordering on the author's
-- publish time carried on the wire.
--
-- NO SPEC REFERENCED IT (checked: zero matches in Tests/), so nothing was re-baselined to allow
-- this deletion.



-- Protocol version helper functions

-- Check if delta sync should be used
-- Delta protocol delegated to DeltaComms module
function TOGBankClassic_Guild:ShouldUseDelta()
	return TOGBankClassic_DeltaComms:ShouldUseDelta()
end

-- INV2-RETIRE-003: `UsesSYNC006` ("does this client use the aggregated alt.items format" --
-- always true, no caller) was deleted here with the aggregate it described.

-- INV2 step 10: seven thin wrappers were deleted here -- ItemsEqual, GetChangedFields,
-- BuildItemIndex, ComputeItemDelta, ComputeDelta, DeltaHasChanges, ApplyItemDelta and ApplyDelta --
-- each a one-line delegate to a DeltaComms function that no longer exists. `EstimateSize` survives
-- below because it is generic and still used.

-- Estimate serialized size of a data structure
function TOGBankClassic_Guild:EstimateSize(data)
	return TOGBankClassic_DeltaComms:EstimateSize(data)
end

function TOGBankClassic_Guild:Wipe(type)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild and not CanViewOfficerNote() then
		return
	end
	local wipe = "I wiped all addon data from " .. guild .. "."
	TOGBankClassic_Guild:Reset(guild)

	-- SYNC-013: Migrated from dead togbank-w/wr prefixes onto togbank-hl type dispatch
	if type ~= "reply" then
		local hlData = TOGBankClassic_Core:SerializeWithChecksum({ type = "wipe-command", message = wipe })
		TOGBankClassic_Core:SendCommMessage("togbank-hl", hlData, "Guild", nil, "BULK")
	end
end

function TOGBankClassic_Guild:HashUpdate()
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		return
	end
	self.Info = TOGBankClassic_Database:Load(guild)
	local player = TOGBankClassic_Guild:GetPlayer()
	local normPlayer = TOGBankClassic_Guild:GetNormalizedPlayer(player)

	-- Only bankers can use this command
	if not (self.Info.alts[normPlayer] and TOGBankClassic_Guild:IsBank(normPlayer)) then
		TOGBankClassic_Output:Response("Only bankers can use /togbank hashupdate")
		return
	end

	-- P2P-023: Check collision guard - defer manual command if broadcast already in progress
	if TOGBankClassic_Events and TOGBankClassic_Events.hashBroadcastInProgress then
		TOGBankClassic_Events.hashBroadcastBlocked = (TOGBankClassic_Events.hashBroadcastBlocked or 0) + 1
		TOGBankClassic_Output:Info("Hash broadcast already in progress - deferring command for 16 seconds...")
		C_Timer.After(16, function()
			self:HashUpdate()  -- Retry once
		end)
		return
	end

	-- Broadcast hash-list for ALL bank alts
	TOGBankClassic_Output:Info("Broadcasting hash-list for ALL bank alts...")
	local hashList = self:BuildBankerHashList()

	-- P2P-023: Set flag before sending (shared with Events:SyncDeltaVersion)
	if TOGBankClassic_Events then
		TOGBankClassic_Events.hashBroadcastInProgress = true
		TOGBankClassic_Events.hashBroadcastCount = (TOGBankClassic_Events.hashBroadcastCount or 0) + 1
	end

	local payload = {
		type = "hash-list-broadcast",
		alts = hashList,
		banker = normPlayer,
		isBanker = true,  -- command is banker-only (guarded above), so this is always true
	}
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	local count = 0
	for _ in pairs(hashList) do
		count = count + 1
	end
	-- ACQ-004 / DOC-001: same defect as Events:SyncDeltaVersion -- an argument-ignoring
	-- callback released the collision guard on the first chunk, not on completion. This one is
	-- user-invoked (/togbank dev hashdump), so the outcome is reported to the player rather
	-- than only to the debug log: telling someone "broadcasted" when the client refused it is
	-- the same lie the library just stopped telling us.
	TOGBankClassic_Core:SendCommMessage("togbank-hl", data, "GUILD", nil, "NORMAL",
		function(_, bytesSent, totalBytes, sendResult)
			if TOGBankClassic_Events then
				if sendResult == false or (bytesSent and totalBytes and bytesSent >= totalBytes) then
					TOGBankClassic_Events.hashBroadcastInProgress = false
				end
			end
			if sendResult == false then
				TOGBankClassic_Output:Error(
					"Hash-list broadcast was refused by the client - the %d bank alts were NOT sent", count)
			elseif bytesSent and totalBytes and bytesSent >= totalBytes then
				TOGBankClassic_Output:Info("Broadcasted hash-list for %d bank alts", count)
			end
		end)
end

-- The argument is accepted and unused; `wipe` below builds a fixed message either way. It also
-- shadowed the `type` builtin, which is why it is not simply renamed.
function TOGBankClassic_Guild:WipeMine(_)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		return
	end
	-- A guild announcement string ("I wiped all my addon data from <guild>.") was built here and
	-- never sent anywhere -- the wipe happens silently. Removed rather than left: as a local
	-- named `wipe` it also SHADOWED the WoW `wipe()` global for the rest of this scope, so any
	-- later code here calling wipe(t) would have tried to call a string.
	TOGBankClassic_Guild:Reset(guild)
end

-- `requestsMode` is accepted and unused. It was only ever defaulted into a local that nothing
-- read, so a snapshot-vs-delta choice passed by a caller has never reached the send path.
function TOGBankClassic_Guild:Share(type, _)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		return
	end
	self.Info = TOGBankClassic_Database:Load(guild)
	local player = TOGBankClassic_Guild:GetPlayer()
	local normPlayer = TOGBankClassic_Guild:GetNormalizedPlayer(player)
	-- `requestsMode` was defaulted into a local `mode` that nothing read. The parameter is still
	-- accepted; if a snapshot-vs-delta choice is meant to reach the send path, it has to be
	-- wired, not merely defaulted.
	local share = "I'm sharing my bank data. Share yours please."
	if not self.Info.alts[normPlayer] then
		if type ~= "reply" then
			share = "Share your bank data please."
		else
			share = "Nothing to share."
		end
	end
	-- Broadcast delta version with hashes for pull-based protocol
	TOGBankClassic_Output:Debug("PROTOCOL", "MAIL-SYNC", "About to call SyncDeltaVersion (exists=%s)", tostring(TOGBankClassic_Events and TOGBankClassic_Events.SyncDeltaVersion ~= nil))
	if TOGBankClassic_Events and TOGBankClassic_Events.SyncDeltaVersion then
		TOGBankClassic_Events:SyncDeltaVersion()
	end

	-- SYNC-013: Migrated from dead togbank-s/sr prefixes onto togbank-hl type dispatch
	if type ~= "reply" then
		local hlData = TOGBankClassic_Core:SerializeWithChecksum({ type = "share-request", message = share })
		-- Use NORMAL priority for share announcement so users are notified quickly
		TOGBankClassic_Core:SendCommMessage("togbank-hl", hlData, "Guild", nil, "NORMAL")
	end
end

function TOGBankClassic_Guild:SenderIsGM(player)
	if not player then
		return false
	end
	if not IsInGuild() then
		return false
	end
	-- PERF: O(1) memberRoster lookup instead of scanning all members
	if self.memberRoster and next(self.memberRoster) then
		local member = self.memberRoster[player]
		return member ~= nil and member.rankIndex == 0
	end
	-- Fallback: memberRoster not yet populated
	for i = 1, GetNumGuildMembers() do
		local playerRealm, _, rankIndex = GetGuildRosterInfo(i)
		if playerRealm then
			local norm = self:NormalizeName(playerRealm)
			if rankIndex == 0 and norm == player then
				return true
			end
		end
	end
	return false
end

-- REQSYNC-001: Check if a named player's guild rank has officer-note (officer) permission.
-- Uses the isOfficer field stored in memberRoster at cache-build time (RefreshOnlineCache).
-- No WoW API calls at lookup time. Returns false if cache not yet populated (deny when uncertain).
-- REQSYNC-008: GuildControlGetRankFlags does not exist in Classic Era (Retail-only API).
-- Officer status is now computed in RefreshOnlineCache via CanViewOfficerNote() threshold.
function TOGBankClassic_Guild:SenderIsOfficer(player)
	if not player then
		return false
	end
	if not self.memberRoster then
		return false
	end
	local member = self.memberRoster[player]
	if not member then
		return false
	end
	return member.isOfficer == true
end

