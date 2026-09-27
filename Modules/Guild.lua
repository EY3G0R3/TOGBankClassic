
TOGBankClassic_Guild = {}

-- NS-001: aliased as file-scope locals so a foreign global of the same name cannot be read
-- instead. See the header of Modules/Constants.lua.
local PROTOCOL = TOGBankClassic_Constants.PROTOCOL

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

TOGBankClassic_Guild.bankerProgressKnown = {}
-- LIBREQ-DS-008: `pendingAltRequests`, `lastAltQueryTime`, `pendingP2PRequests`, `pendingP2PTimeouts`,
-- `pendingP2PFallbackTimeouts` (the pull path's per-alt state) and `MAX_PENDING_SENDS` (the cap's
-- second name, read by the pull path's ACK branches) were here. The send cap is Constants' PEER_TO_PEER.MAX_ACTIVE_SENDS, enforced by
-- the library's numbered P2P on the DeltaSync host (Modules/P2P.lua); the status bar reads the
-- library's count. Do not reintroduce a counter or a cap here (P2P-025; statusbar_spec pins it).

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

-- XGUILD-SYNC-001 / XGUILD-LABEL-001 (docs/XGUILD_SYNC.md D2, D8): the FEDERATION. LibGuildRoster
-- holds the home roster and, once an officer lists sister guilds, each sister's roster; a name in
-- any of them is one of us. These are the ONE spelling of that question; every "is this a
-- guildmate" gate reads them, so the bank opens to a sister guild in one place. Without the
-- library, or before it has a sister roster, they answer for the home guild alone -- exactly
-- what every gate answered before.

--- The memberRoster entry for an already-normalised name, or nil -- and A STUB DOES NOT COUNT.
--- A stub is the unauthenticated sighting UpdateOnlineMember makes for EVERY inbound message,
--- before any authorisation runs; an entry's mere existence therefore proves nothing, and each
--- predicate that once read `memberRoster[norm]` directly (IsInCurrentGuildRoster, GuildOf,
--- IsHomeMember, SenderIsOfficer) was one more place to forget that. This is the ONE spelling.
function TOGBankClassic_Guild:RosterEntry(norm)
	local m = norm and self.memberRoster and self.memberRoster[norm]
	if m and not m.isStub then return m end
	return nil
end

-- XGUILD-SWITCH-001 (the operator, 2026-09-15: "shouldn't there be some officer configuration to
-- turn it on or make it work? we have the sister guilds in the guildroster library"): the
-- sister-guild bank is an OFFICER SWITCH, off by default, guild-synced like the shop switch. Guild
-- Roster's sister list says WHICH guilds are sisters; this says whether THIS guild's bank crosses
-- to them at all. Off, every gate below answers for the home guild alone -- no sister bankers on
-- the tabs, no pull from a sister peer on the cycle, a sister member's whisper refused as a
-- stranger's -- and nothing about where the record lives changes. Each guild opens its own side:
-- a sister guild whose officers leave it off neither serves nor asks.
function TOGBankClassic_Guild:IsSisterBankEnabled()
	local s = self.Info and self.Info.settings
	return s ~= nil and s.sisterBank == true
end

--- Open or close the sister-guild bank, guild-wide. The ONE writer. Returns true when it changed.
--- The rosters are rebuilt at once so the Bankers tab and the banker column follow the switch.
function TOGBankClassic_Guild:SetSisterBankEnabled(enabled)
	if not self.Info then return false end
	if not self.Info.settings then self.Info.settings = {} end
	enabled = enabled and true or false
	if self:IsSisterBankEnabled() == enabled then return false end
	self.Info.settings.sisterBank = enabled
	self:BroadcastSettings("ALERT")  -- SETTINGS-001
	TOGBankClassic_Output:Info(enabled and "The sister-guild bank is ON -- bank characters in the guilds listed in Guild Roster join this bank (syncing to guild...)."
		or "The sister-guild bank is OFF -- this bank is your guild's alone again (syncing to guild...).")
	self:OnSisterBankChanged()
	return true
end

--- Rebuild what the switch decides: the member and banker rosters, and the open window.
function TOGBankClassic_Guild:OnSisterBankChanged()
	self.banksCache = nil
	if self.RefreshOnlineCache then self:RefreshOnlineCache() end
	if self.RebuildBankerRoster then self:RebuildBankerRoster() end
	if self.RefreshRequestsUI then self:RefreshRequestsUI() end
	local B = TOGBankClassic_UI_Browse
	if B and B.Refresh then B:Refresh() end
end

--- The sister guilds this bank spans: the library's listed keys while the switch is on, none
--- otherwise. Every sister-facing walk reads this rather than the library, so the switch is one
--- gate and not four. `lib` may be passed by a caller that already resolved it.
function TOGBankClassic_Guild:SisterGuildKeys(lib)
	if not self:IsSisterBankEnabled() then return {} end
	lib = lib or RosterLib()
	if not (lib and lib.GetSisterGuildKeys) then return {} end
	return lib:GetSisterGuildKeys() or {}
end

--- Which roster holds `name`: the library's guild key ("Faction-Guild Name"), the home key for
--- a guildmate, nil for a stranger. Feature-detected on the library's cross-guild methods
--- (MINOR 6+); an older library answers only for the home guild, through memberRoster. With the
--- sister-guild bank OFF the library's cross-guild answer is not consulted: a sister member is
--- then a stranger, which is what every gate wants.
function TOGBankClassic_Guild:GuildOf(name)
	local norm = self:NormalizeName(name)
	if not norm then return nil end
	local lib = RosterLib()
	if lib and lib.IsInAnyRoster and self:IsSisterBankEnabled() then
		local key = lib:IsInAnyRoster(norm)
		if key then return key end
	end
	local m = self:RosterEntry(norm)
	if m then
		return m.guildKey or (lib and lib.GetHomeGuildKey and lib:GetHomeGuildKey()) or "home"
	end
	return nil
end

--- Is `name` in the HOME guild? (The roster the client itself scans.)
function TOGBankClassic_Guild:IsHomeMember(name)
	local norm = self:NormalizeName(name)
	if not norm then return false end
	local lib = RosterLib()
	if lib and lib.GetMember and lib:GetMember(norm) then return true end
	local m = self:RosterEntry(norm)
	return m ~= nil and m.guildKey == nil
end

--- Is `name` one of us -- a member of the home guild or of any listed sister guild?
function TOGBankClassic_Guild:IsFederated(name)
	return self:GuildOf(name) ~= nil
end

--- The display name of the guild that holds `name`: "" for a home-guild member or a stranger,
--- the sister guild's name otherwise. The library's key is "Faction-Guild Name"; the guild name
--- is everything after the first hyphen, spaces kept.
function TOGBankClassic_Guild:GuildNameOf(name)
	if self:IsHomeMember(name) then return "" end
	local key = self:GuildOf(name)
	if not key then return "" end
	return key:match("^[^%-]*%-(.+)$") or key
end

--- XGUILD-LABEL-001: the tag every banker listing appends to a banker from another guild --
--- " (Guild Name)" in grey -- and "" for one of the home guild, so the common case reads as it
--- always did. One function so the Bankers tab, the Banker column, the tooltips, the request
--- dialog and the Requests tab cannot spell the label three ways.
function TOGBankClassic_Guild:GuildTag(name)
	local guildName = self:GuildNameOf(name)
	if guildName == "" then return "" end
	return string.format(" |cff808080(%s)|r", guildName)
end

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
--
-- XGUILD-SYNC-001 (docs/XGUILD_SYNC.md D2): "the current guild" now means THE FEDERATION --
-- memberRoster carries every listed sister guild's members too (_AddSisterMembers, `guildKey`
-- set), so a sister member passes this gate exactly as a guildmate does, and a name in no
-- roster is still a stranger. The name is kept for its ~40 call sites; IsFederated / GuildOf
-- are the same question asked of the library directly.
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
	-- A STUB ENTRY DOES NOT COUNT (RosterEntry says why -- this is where the rule was found:
	-- treating a stub as membership let any sender satisfy this check simply by sending, which is
	-- the whole roster half of IsAltDataAllowed). A stub falls through to the authoritative client
	-- roster scan below rather than answering true.
	if self.memberRoster and next(self.memberRoster) then
		if self:RosterEntry(normPlayer) then
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
		self:SnapshotSettings()   -- SETTINGS-STALE-001: the first write diffs against what is held
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

--- GSL-BANK-001 (the operator 2026-09-26: "we also need what is on the GSL player (bank/bags/mail)
--- just like a banker. they are the 'special' banker for the shopping list"): THE ONE RULE for what
--- a guild note makes a character. `gbank` in either note makes a banker, as always. GuildShoppingList's
--- `[GSL]` in the PUBLIC note (the note CraftList:IsGSLPlayer reads) makes one too, flagged `gsl`, so
--- its bags, bank and mail are scanned, published and synced by the banker pipeline with no second
--- copy of it. A [GSL] character is VIEW-ONLY unless its note also says `gbank`: the guild sends
--- items TO it, and does not order the shopping list's stock back out of it. Every site that used to
--- test for `gbank` itself asks this instead, so the roster, the scan gate and the sister roster
--- cannot disagree about who is a banker.
---@return boolean isBank, boolean viewOnly, boolean gsl
local function noteBankRole(publicNote, officerNote)
	local pub = type(publicNote) == "string" and publicNote or ""
	local off = type(officerNote) == "string" and officerNote or ""
	local gbank = pub:find("gbank", 1, true) ~= nil or off:find("gbank", 1, true) ~= nil
	local gsl = pub:find("[GSL]", 1, true) ~= nil
	local isBank = gbank or gsl
	local viewOnly = isBank and (noteIsViewOnly(pub, off) or not gbank) or false
	return isBank, viewOnly, gsl
end
TOGBankClassic_Guild.NoteBankRole = noteBankRole

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
			if name and noteBankRole(publicNote, officer_note) then   -- GSL-BANK-001
				table.insert(banks, name)
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

--- XGUILD-SYNC-001: the bank characters of every listed sister guild, by the `gbank` marker in
--- the public note the library carries on a sister member (LIBREQ-GR-002; absent, none), as
--- normalised names sorted for a stable roster. A home-guild name is never listed here (home
--- wins in IsInAnyRoster, and the home scan already has it).
function TOGBankClassic_Guild:_SisterBankers()
	local lib = RosterLib()
	local out = {}
	if not (lib and lib.GetSisterGuildKeys and lib.GetRoster) then return out end
	local homeKey = lib.GetHomeGuildKey and lib:GetHomeGuildKey() or nil
	for _, key in ipairs(self:SisterGuildKeys(lib)) do   -- XGUILD-SWITCH-001: none while off
		local roster = key ~= homeKey and lib:GetRoster(key) or nil
		if roster then
			for name, m in pairs(roster) do
				local note = type(m) == "table" and m.note
				if type(note) == "string" and noteBankRole(note, "") then   -- GSL-BANK-001
					local norm = self:NormalizeName(name)
					if norm and not (lib.GetMember and lib:GetMember(norm)) then out[#out + 1] = norm end
				end
			end
		end
	end
	table.sort(out)
	return out
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
			local isBank, viewOnly, gsl = noteBankRole(publicNote, officer_note)   -- GSL-BANK-001
			if isBank then
				table.insert(banks, name)
			end
			-- Keep memberRoster.isBank / .viewOnly / .gsl in sync if the entry already exists
			local norm = self:NormalizeName(name)
			if norm and self.memberRoster and self.memberRoster[norm] then
				self.memberRoster[norm].isBank = isBank
				self.memberRoster[norm].viewOnly = viewOnly
				self.memberRoster[norm].gsl = gsl
			end
		end
	end

	-- XGUILD-SYNC-001 (docs/XGUILD_SYNC.md D3): the bankers of every listed sister guild join the
	-- roster -- a sister member whose public note carries the marker. The note reaches the sister
	-- roster as `member.note` from LibGuildRoster MINOR 19 (LIBREQ-GR-002, shipped 2026-09-15) and
	-- is feature-detected: a roster served by an older provider carries none and contributes no
	-- bankers, which is what it did before. Sorted so two clients holding the same rosters build
	-- the same list.
	for _, name in ipairs(self:_SisterBankers()) do
		local dup = false
		for _, b in ipairs(banks) do if self:NormalizeName(b) == name then dup = true break end end
		if not dup then table.insert(banks, name) end
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

-- LIBREQ-DS-008: `FastFillMissingAlts` (one `alt-request` GUILD broadcast per missing banker, from
-- /togbank sync and the window's Open) WAS HERE and in DeltaComms. A missing banker is filled by
-- the cycle: every peer offers the bankers our broadcast did not name (DeltaSync's OnBroadcast), and
-- the library asks one holder per bank.

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
			-- The view-only marker alone answers here, as it always has (a "GBANK VIEWONLY" note is
			-- view-only though the case-sensitive gbank test does not call it a banker); GSL-BANK-001
			-- adds a [GSL]-only note on top.
			local _, viewOnly = noteBankRole(publicNote, officer_note)
			return noteIsViewOnly(publicNote, officer_note) or viewOnly
		end
	end
	return false
end

--- GSL-BANK-001: is `player` the shopping list's banker -- a `[GSL]` public note (noteBankRole)?
--- O(1) through memberRoster, like IsBank and IsViewOnlyBank.
function TOGBankClassic_Guild:IsGSLBank(player)
	if not player then return false end
	local norm = self:NormalizeName(player) or player
	local m = self.memberRoster and self.memberRoster[norm]
	return m ~= nil and m.gsl == true
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
	for _, marker in ipairs({ "gbankro", "gbank", "[gsl]", "view-only", "viewonly", "read-only", "readonly" }) do
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
	local BN = TOGBankClassic_BankerNumbers
	local payload = {
		type = "hash-list-reply",
		alts = list,
		banker = self:GetNormalizedPlayer(),
		-- XGUILD-SYNC-001 (D5) / LIBREQ-DS-008: the numbers table rides the reply. A sister guild's
		-- client never hears this guild's hlb2 (GUILD), so this whisper is the one place it can learn
		-- the numbers these canons will be named by -- the receiver adopts it under the library's
		-- rules (newer wholesale; equal-and-different from the lower-sorting sender; the two guilds'
		-- tables converge as two minters do, H6). A guildmate already holds it: a no-op there.
		numbers = BN and BN:Snapshot() or nil,
		-- SETTINGS-CANON-001: the pulled sync names the guild settings too, as the hlb2 does.
		sv = self:SettingsVersion(),
		sh = self:SettingsCanon(),
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
	-- LIBREQ-DS-008: a `togbank-hl` type now (the `togbank-hlr` prefix went with the pull path);
	-- Chat:ReceiveHashListReply hands it to the library as the sender's broadcast.
	local sent = TOGBankClassic_Core:SendWhisper("togbank-hl", data, normalizedTarget, "ALERT")
	TOGBankClassic_Output:Debug("PROTOCOL", "HLR", "HLR send result: %s", tostring(sent))
end

-- XGUILD-SYNC-001 (docs/XGUILD_SYNC.md D5/D6): THE FEDERATION PULL. A broadcast reaches one guild;
-- the copy that crosses into a sister guild is a whispered `hash-list-request` to one member of
-- it -- the peer answers with its hash-list-reply exactly as it answers a guildmate, and the P2P
-- session, the version query and the data leg follow as whispers already. This is the shape
-- LibGuildRoster uses for its own sister rosters; GreenWall's bridge cannot carry it (1.1 of the
-- design: CHANNEL sends are hardware-gated, and every leg here fires from a timer).

--- How long a federation peer that never answered is left alone before it is asked again.
TOGBankClassic_Guild.FEDERATION_SILENT_FOR = 3600

--- Seconds after the hash-list ask before the requests-index ask follows it (and between the
--- asks to a second and third sister guild's peer): past INDEX_QUERY_COOLDOWN.
TOGBankClassic_Guild.FEDERATION_INDEX_DELAY = 70

--- The member of sister guild `key` to ask: the one this client most recently heard a TOGBank
--- message from (a proven TOGBank speaker), else one VersionCheck (or our memory of it) has seen on
--- a TOGBank that completes the data leg, else the first the library has seen online at all; never
--- ourselves, never one that ignored the last ask inside FEDERATION_SILENT_FOR, and never one KNOWN
--- to run a release this build cannot sync with. nil when nobody qualifies.
---
--- XGUILD-PEER-001 (XGUILD-INVENTORY-001, the operator 2026-09-16: "now we need to get the inventory
--- sync working"): the library's presence is every sister member it has seen -- most of a guild runs
--- Guild Roster without TOGBank, or a TOGBank from CurseForge that predates this sync -- and the old
--- pick took the first of them. Such a peer never answers the ask (or answers a data leg we refuse),
--- so the guild's bank stayed empty for a cycle per wrong pick and an hour per silent one. The
--- versions are already on this client for free (PeerSpeaksDataLeg: VersionCheck first, the hlb2
--- field second); an unknown is still asked, last, because VersionCheck's answer can be lost.
function TOGBankClassic_Guild:FederationPeer(key)
	local lib = RosterLib()
	if not (key and lib and lib.GetOnlineMembersScoped) then return nil end
	local me = self:GetNormalizedPlayer()
	local now = GetServerTime() or 0
	self.federationSilent = self.federationSilent or {}
	local best, bestAt, known, fallback = nil, nil, nil, nil
	-- Sorted, so two clients with the same sightings ask the same member (the library's list is a
	-- pairs walk).
	local names = {}
	for _, name in ipairs(lib:GetOnlineMembersScoped(key) or {}) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local norm = self:NormalizeName(name)
		local silentAt = norm and self.federationSilent[norm]
		-- XGUILD-BOUNCE-001: a sighting the server has since contradicted is not a candidate.
		if norm and norm ~= me and not (silentAt and now - silentAt < self.FEDERATION_SILENT_FOR)
			and self:SisterSightingHolds(lib, key, norm) then
			local capable, why = true, "unknown"
			if self.PeerSpeaksDataLeg then capable, why = self:PeerSpeaksDataLeg(norm) end
			if capable then
				local m = self.memberRoster and self.memberRoster[norm]
				local spoke = m and m.spokeAt or nil
				if spoke and (not bestAt or spoke > bestAt) then best, bestAt = norm, spoke end
				if why ~= "unknown" then known = known or norm end
				fallback = fallback or norm
			else
				TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "not asking %s (%s): it runs TOGBank %s", norm, key, tostring(why))
			end
		end
	end
	return best or known or fallback
end

--- Ask one member of every listed sister guild for its hash list, by whisper. Called on the
--- ten-minute cycle after the GUILD broadcast (Events:SyncDeltaVersion) and by /togbank share.
--- A peer asked on the previous cycle that never replied is marked silent and another is asked.
--- Returns the names asked.
function TOGBankClassic_Guild:PullFromFederation()
	local lib = RosterLib()
	local asked = {}
	if not (lib and lib.GetSisterGuildKeys) then return asked end
	self.federationAsked = self.federationAsked or {}
	self.federationSilent = self.federationSilent or {}
	local now = GetServerTime() or 0
	-- XGUILD-PEER-001: an ask younger than FEDERATION_ANSWER_GRACE is still PENDING, not silence --
	-- OnFederationPeerProven asks between cycles, and judging that ask at the next cycle a few
	-- seconds later marked a peer that was answering silent for an hour. Its guild is not asked twice.
	local pendingKeys = {}
	for peer, at in pairs(self.federationAsked) do
		local answered = self.federationAnswered and self.federationAnswered[peer] and self.federationAnswered[peer] >= at
		if not answered and now - at < self.FEDERATION_ANSWER_GRACE then
			local key = self.GuildOf and self:GuildOf(peer)
			if key then pendingKeys[key] = true end
		else
			if not answered then
				self.federationSilent[peer] = now
				TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "%s did not answer the last hash-list ask; left alone for an hour", peer)
			end
			self.federationAsked[peer] = nil
		end
	end
	local keys = self:SisterGuildKeys(lib)   -- XGUILD-SWITCH-001: none while off, so nothing is asked
	if #keys == 0 then return asked end
	for _, key in ipairs(keys) do
		local peer = not pendingKeys[key] and self:FederationPeer(key) or nil
		if pendingKeys[key] then
			TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "an ask to %s is still out; not asking it again yet", key)
		elseif peer then
			self:AskFederationPeer(key, peer, asked)
		else
			TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "nobody online to ask in %s", key)
		end
	end
	return asked
end

--- Whisper `peer` (a member of sister guild `key`) the hash-list ask, note it, and queue the
--- requests-index ask behind it. `asked` (optional) collects the name and staggers the index asks
--- of one cycle. Returns true when the ask left.
function TOGBankClassic_Guild:AskFederationPeer(key, peer, asked)
	asked = asked or {}
	local data = TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-list-request", requester = self:GetNormalizedPlayer() })
	if not TOGBankClassic_Core:SendWhisper("togbank-hl", data, peer, "NORMAL") then return false end
	self.federationAsked = self.federationAsked or {}
	self.federationAsked[peer] = GetServerTime() or 0
	asked[#asked + 1] = peer
	TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "asked %s (%s) for its hash list", peer, key)
	-- D7: the far guild's REQUESTS too -- the ones the relay never carried here because both
	-- names were on that side. The same index query the cycle broadcasts on GUILD, whispered
	-- to the peer, staggered past the GUILD query's cooldown (INDEX_QUERY_COOLDOWN, 60 s) so
	-- the one-at-a-time index state machine is not asked to hold two at once; a home sync
	-- still in flight then (a large by-id batch) skips this cycle's ask rather than forcing.
	local delay = self.FEDERATION_INDEX_DELAY * #asked
	C_Timer.After(delay, function()
		if self:IsPlayerOnline(peer) and self:QueryRequestsIndex(peer, "NORMAL") then
			TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "asked %s for its requests index", peer)
		end
	end)
	return true
end

--- XGUILD-PEER-001: a member of a listed sister guild has just PROVEN it runs a TOGBank we can sync
--- with -- it spoke TOGBank to us, or VersionCheck named its version. When that guild has had no ask
--- out and no answer this cycle, it is asked NOW instead of on the next ten-minute cycle: presence is
--- an event, and the first one after login is the moment a sister guild's bank can start arriving
--- (HANDSHAKE-OVER-TIMERS-001). The cycle's own pull is unchanged and still covers a lost ask.
---@param norm string the member, normalized
---@return boolean asked
function TOGBankClassic_Guild:OnFederationPeerProven(norm)
	if not norm or norm == self:GetNormalizedPlayer() or not self.IsHomeMember or self:IsHomeMember(norm) then return false end
	local key = self.GuildOf and self:GuildOf(norm)
	if not key then return false end
	local lib = RosterLib()
	local listed = false
	for _, k in ipairs(self:SisterGuildKeys(lib)) do if k == key then listed = true end end
	if not listed then return false end
	if self.PeerSpeaksDataLeg and not (self:PeerSpeaksDataLeg(norm)) then return false end
	local now = GetServerTime() or 0
	local silentAt = self.federationSilent and self.federationSilent[norm]
	if silentAt and now - silentAt < self.FEDERATION_SILENT_FOR then return false end
	-- Something already out to, or heard from, that guild inside a cycle: nothing to hurry.
	local window = self.FEDERATION_HURRY_WINDOW
	for peer, at in pairs(self.federationAsked or {}) do
		if now - at < window and self:GuildOf(peer) == key then return false end
	end
	for peer, at in pairs(self.federationAnswered or {}) do
		if now - at < window and self:GuildOf(peer) == key then return false end
	end
	TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "%s (%s) runs TOGBank; asking it now rather than on the next cycle", norm, key)
	return self:AskFederationPeer(key, norm)
end

--- SSYNC-001 (the operator, 2026-09-25: "do we have a /togbank command to start a cross guild sync?
--- i need that, especially for testing, and if i could do /togbank ssync <name> that would be
--- helpful. it could do a roster lookup so i can be lazy with the realm"). The sister-guild members
--- `input` names: an exact `Name-Realm`, or a bare name matched case-insensitively against every
--- sister guild's roster -- so the realm can be left off. Several when a bare name is on more than one
--- realm; empty when nobody matches.
---@param input string
---@return table matches array of { name = "Name-Realm", key = guild key }
function TOGBankClassic_Guild:FindSisterMembers(input)
	local out = {}
	if type(input) ~= "string" or input == "" then return out end
	local want = input:lower()
	local wantFull = want:find("-", 1, true) ~= nil
	for norm, m in pairs(self.memberRoster or {}) do
		if type(m) == "table" and m.guildKey and not m.isStub then
			local base = (norm:match("^(.-)%-") or norm):lower()
			if (wantFull and norm:lower() == want) or (not wantFull and base == want) then
				out[#out + 1] = { name = norm, key = m.guildKey }
			end
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

--- SSYNC-001: start a sister-guild sync NOW, for testing and troubleshooting. With no name, every
--- listed sister guild's usual peer is asked, past the pending and silent-for-an-hour waits the cycle
--- honours. With a name, THAT member is asked -- the hash-list ask and the requests index behind it,
--- the same ask the cycle sends (AskFederationPeer) -- and any "left alone" mark on it is cleared.
--- Returns the lines to print; nothing is sent when the answer is a refusal.
---@param input string|nil
---@return table lines
function TOGBankClassic_Guild:SisterSyncCommand(input)
	local lines = {}
	if not self:IsSisterBankEnabled() then
		lines[1] = "The Sister-guild bank is OFF for your guild, so there is nobody to sync with. An officer turns it on in Settings > Sister guilds."
		return lines
	end
	local lib = RosterLib()
	local keys = self:SisterGuildKeys(lib)
	if #keys == 0 then
		lines[1] = "No sister guilds are listed in Guild Roster's settings, so there is nobody to sync with."
		return lines
	end
	self.federationSilent = self.federationSilent or {}
	self.federationAsked = self.federationAsked or {}
	if input == nil or input == "" then
		local asked = {}
		for _, key in ipairs(keys) do
			local peer = self:FederationPeer(key)
			if not peer then
				-- The cycle's waits are for its own pacing; asked by hand, a silent member is tried again.
				for name in pairs(self.federationSilent) do if self:GuildOf(name) == key then self.federationSilent[name] = nil end end
				peer = self:FederationPeer(key)
			end
			if peer and self:AskFederationPeer(key, peer, asked) then
				lines[#lines + 1] = string.format("Asked %s (%s) for its bank and requests.", peer, key)
			else
				lines[#lines + 1] = string.format("Nobody in %s is online to ask.", key)
			end
		end
		return lines
	end
	local found = self:FindSisterMembers(input)
	if #found == 0 then
		lines[1] = string.format("%s is not a member of a sister guild (checked every sister guild's roster).", input)
		return lines
	end
	if #found > 1 then
		local names = {}
		for _, f in ipairs(found) do names[#names + 1] = f.name end
		lines[1] = string.format("%s matches more than one character: %s. Add the realm.", input, table.concat(names, ", "))
		return lines
	end
	local target = found[1]
	if not self:IsPlayerOnline(target.name) then
		lines[1] = string.format("%s (%s) is not online.", target.name, target.key)
		return lines
	end
	self.federationSilent[target.name] = nil
	if self:AskFederationPeer(target.key, target.name) then
		lines[1] = string.format("Asked %s (%s) for its bank and requests.", target.name, target.key)
	else
		lines[1] = string.format("Could not whisper %s.", target.name)
	end
	return lines
end

--- The window inside which an ask to, or an answer from, a sister guild means it is not hurried:
--- one sync cycle -- read from the cycle's own constant, so the two cannot drift apart.
TOGBankClassic_Guild.FEDERATION_HURRY_WINDOW = TOGBankClassic_Constants.TIMER_INTERVALS.VERSION_BROADCAST

--- How long a hash-list ask stays pending before the cycle may judge it unanswered. The reply is one
--- whispered message sent at ALERT; two minutes covers a congested sender's queue with room to spare.
TOGBankClassic_Guild.FEDERATION_ANSWER_GRACE = 120

-- XGUILD-BOUNCE-001: A SISTER MEMBER WHO LOGGED OFF. Guild Roster never hears "X has gone offline."
-- for another guild's member; its presence for one is a sighting stamp that only AGES OUT
-- (PRESENCE_TTL, 900 s) -- and its roster relay carries every name still inside that window and the
-- receiver re-stamps them at receive time (LibGuildRoster-1.0.lua:3976, :4194, :3297), on a
-- 270 s relay interval, so a member who logged off reads online for as long as two guildmates keep
-- relaying. The one authoritative "not online" this client ever gets for them is the server's own
-- bounce of a whisper: ERR_CHAT_PLAYER_NOT_FOUND_S ("No player named 'X' is currently playing."),
-- which Events:CHAT_MSG_SYSTEM turns into UpdateOnlineMember(X, false) -- and until this, that set a
-- flag on memberRoster that IsPlayerOnline, FederationPeer and the Bankers tab never read for a
-- sister member. Found by Tests/xguildlive_spec.lua step 8: the sister viewer whispered its ask to the
-- home banker who had just logged off, and waited a whole cycle (then judged them silent for an hour)
-- while the other home member sat online holding the bank.

--- How long a bounce outranks the library's sighting when the library does not say how long its own
--- window is: Guild Roster's PRESENCE_TTL, the time an un-refreshed stamp takes to age out anyway.
TOGBankClassic_Guild.SISTER_BOUNCE_HOLD = 900

--- Does the library's sighting of sister member `norm` (roster `key`) still stand against this
--- client's last bounce for them? True with no bounce on record, and again once the bounce is older
--- than the library's presence window (`lib.PRESENCE_TTL`, else SISTER_BOUNCE_HOLD): the library's
--- answer stands alone from then on, and if the member is still offline the next ask bounces again.
--- A TOGBank message FROM the member clears the bounce at once (UpdateOnlineMember) -- that is this
--- client's own sighting. The library's stamps are deliberately NOT compared against the bounce:
--- its guild relay re-stamps a relayed name at receive time, so a stamp newer than the bounce was
--- measured arriving within the minute (Tests/xguildlive_spec.lua step 8) and proves nothing.
function TOGBankClassic_Guild:SisterSightingHolds(lib, key, norm)   -- luacheck: no unused args
	local bounced = self.sisterBounced and self.sisterBounced[norm]
	if not bounced then return true end
	local hold = (lib and tonumber(lib.PRESENCE_TTL)) or self.SISTER_BOUNCE_HOLD
	if (GetTime() or 0) - bounced > hold then
		self.sisterBounced[norm] = nil
		return true
	end
	return false
end

--- The server has just said sister member `norm` (roster `key`) is not playing. Remembered so the
--- sighting is outranked (SisterSightingHolds); if our hash-list ask was out to them, it is
--- withdrawn, they are left alone for FEDERATION_SILENT_FOR, and their guild is asked through its
--- next member NOW -- the cycle's own pull still covers a lost ask. Returns whether a new ask left.
function TOGBankClassic_Guild:OnSisterMemberBounced(norm, key)
	self.sisterBounced = self.sisterBounced or {}
	self.sisterBounced[norm] = GetTime()
	if not (self.federationAsked and self.federationAsked[norm]) then return false end
	self.federationAsked[norm] = nil
	self.federationSilent = self.federationSilent or {}
	self.federationSilent[norm] = GetServerTime() or 0
	local peer = self:FederationPeer(key)
	if not peer then
		TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "%s is not playing (the ask bounced); nobody else online to ask in %s", norm, key)
		return false
	end
	TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "%s is not playing (the ask bounced); asking %s instead", norm, peer)
	return self:AskFederationPeer(key, peer)
end

--- A federated peer's hash-list-reply arrived: it answered. Called from the HLR receive.
function TOGBankClassic_Guild:NoteFederationAnswer(sender)
	local norm = self:NormalizeName(sender)
	if not norm then return end
	self.federationAnswered = self.federationAnswered or {}
	self.federationAnswered[norm] = GetServerTime() or 0
	if self.federationSilent then self.federationSilent[norm] = nil end
end

--- D6: what a federated NON-guildmate is told when it asks for the hash list -- everything the
--- GUILD cycle would have piggybacked for it: the guild settings (when this client may
--- broadcast them), this character's donation totals, and the price-list version held, each
--- by whisper. Rate-limited per asker so a client asking every cycle costs one round of answers.
TOGBankClassic_Guild.FEDERATION_ANSWER_COOLDOWN = 300
function TOGBankClassic_Guild:AnswerFederatedAsker(asker)
	local norm = self:NormalizeName(asker)
	if not norm or self:IsHomeMember(norm) or not self:IsFederated(norm) then return false end
	self.federationAnswers = self.federationAnswers or {}
	local now = GetServerTime() or 0
	local last = self.federationAnswers[norm]
	if last and now - last < self.FEDERATION_ANSWER_COOLDOWN then return false end
	self.federationAnswers[norm] = now
	-- XGUILD-SETTINGS-001: the owners alone, from any client -- officer settings never cross between
	-- guilds (ApplyRemoteSettings), and a plain member holds the owners as well as an officer does.
	-- Before, only a bank character or officer answered, with the whole settings payload.
	self:SendBankerOwnersTo(norm)
	if TOGBankClassic_Donations then TOGBankClassic_Donations:Broadcast("NORMAL", norm) end
	local PL = TOGBankClassic_PriceList
	if PL then
		-- The authority's GUILD publish never reaches a sister guild, and only the authority
		-- answers an ask -- so the authority hands a federated asker the whole list; anyone else
		-- names the version and publisher they hold, and the asker asks the authority from there.
		if PL:IsAuthority() and PL:Held() then PL:SendList(PL:Held(), norm) else PL:AnnounceTo(norm) end
	end
	TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "answered %s's ask with the settings, donation totals and price-list version", norm)
	return true
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
		-- LIBREQ-DS-008: this used to broadcast one `alt-request` per banker held without content.
		-- With no banker to ask, the cycle is the answer -- every peer offers the bankers our
		-- broadcast did not name -- and the library's catch-up re-broadcasts while anything is
		-- missing.
		local p2p = TOGBankClassic_P2P and TOGBankClassic_P2P:Lib()
		if p2p and self:HasMissingContent() then
			TOGBankClassic_Output:Debug("PROTOCOL", "HLR", "HLR: no capable banker online -- the P2P catch-up will re-broadcast for what is missing")
			p2p:ScheduleCatchUp("no_banker")
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

-- LIBREQ-DS-008: `ArmAltTimeout`, `ClearPendingP2PRequest` and `BroadcastP2PRequest` WERE HERE --
-- the pull path's per-alt request with its 5-second "no response" timer (P2P-026 / AUDIT finding
-- 24 / Peer Review 2026-09-12 F1). The library's numbered P2P asks one holder per bank through a
-- session with its own timers (DeltaSyncP2PNumbered.lua ArmSessionTimer); nothing here arms a
-- per-alt timer any more.

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
		if norm then
			self:RememberPeerAddonVersion(norm, version)
			-- XGUILD-PEER-001: VersionCheck just named a sister member's TOGBank -- ask that guild now.
			if self.OnFederationPeerProven then self:OnFederationPeerProven(norm) end
		end
	end)
	return true
end

-- WIRE-SKEW-007 (`peerOldWire` / `NotePeerOldWire`: peers OBSERVED on the old wire -- a
-- `togbank-state` summary after our accept, or silence for the whole state-wait) WAS HERE. Both
-- observers went with LIBREQ-DS-008: the tripwire prefix is unregistered and the state-wait is the
-- library's. A v1.4.1 peer is refused by its version, which VersionCheck names at login.

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
---@return boolean capable, string why "unknown" | "dev" | the observed version
function TOGBankClassic_Guild:PeerSpeaksDataLeg(name)
	local norm = self:NormalizeName(name)
	local raw = self:ObservedAddonVersion(name, norm)
	if not raw then return true, "unknown" end
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
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "GUILD", nil, "NORMAL")
end

-- LIBREQ-DS-008: `QueryAltPullBased` (the v0.8.0 `alt-request` whisper-or-broadcast, "last resort
-- after P2P timeout") WAS HERE. It had no caller left in the shipped modules and its ACK branch is
-- gone with the pull path; nothing sends `alt-request` any more.

-- SHOP-TAB-001 (the operator, 2026-09-14: "a new tab, with a setting to turn it on/off, so folks
-- can shut it off if their bank doesn't 'sell' items. it should be off by default"): is this guild's
-- bank a SHOP? Officer-set, guild-synced, OFF unless an officer turned it on -- a missing value is
-- off, the opposite of storeOpen's default, because most guilds run a plain bank. Off, the Guild
-- Bank window has no Shop tab and every shop rule below (the open/closed sign, the not-for-sale
-- list, the estimates) is inert.
function TOGBankClassic_Guild:IsShopEnabled()
	local s = self.Info and self.Info.settings
	return s ~= nil and s.shopEnabled == true
end

--- Turn the shop on or off, guild-wide. The ONE writer. Returns true when the value changed.
function TOGBankClassic_Guild:SetShopEnabled(enabled)
	if not self.Info then return false end
	if not self.Info.settings then self.Info.settings = {} end
	enabled = enabled and true or false
	if self:IsShopEnabled() == enabled then return false end
	self.Info.settings.shopEnabled = enabled
	self:BroadcastSettings("ALERT")  -- SETTINGS-001
	TOGBankClassic_Output:Info(enabled and "The Shop is ON -- the Guild Bank window gains a Shop tab (syncing to guild...)."
		or "The Shop is OFF -- the Guild Bank window is a plain bank again (syncing to guild...).")
	local B = TOGBankClassic_UI_Browse
	if B and B.OnShopSettingChanged then B:OnShopSettingChanged() end
	return true
end

-- STORE-006 (GUILD_STORE.md 4.6, build-order step 1): the shop's open/closed sign. One officer-set,
-- guild-synced boolean; off, no request can be created anywhere (Guild:AddRequest is the gate,
-- the request dialog says why). A missing value reads as OPEN -- every guild ran without the sign
-- before it existed, and a client that predates it never sends the field. SHOP-TAB-001: with the
-- shop off the sign does not exist, and ordering is open.
function TOGBankClassic_Guild:IsStoreOpen()
	if not self:IsShopEnabled() then return true end
	local s = self.Info and self.Info.settings
	if not s or s.storeOpen == nil then return true end
	return s.storeOpen == true
end

--- The sentence every "you cannot order" surface prints, so the request dialog, the Browse
--- status line and the chat warning all say the same thing.
-- SHOP-SECTION-001: says SHOP, because that is all the sign governs.
TOGBankClassic_Guild.STORE_CLOSED_TEXT = "The shop is not taking orders right now -- an officer has closed shop ordering."

-- SHOP-NOFREE-001 (the operator, 2026-09-14: "when the shop tab is shown and ordering is enabled,
-- there should be no 'free' item requests"): is the bank SELLING right now -- the shop on AND
-- ordering open? While it is, every request minted is a SHOP ORDER (`request.shopOrder`, with the
-- estimate the member was shown written on the record, GUILD_STORE.md 4.4) and Guild:AddRequest
-- refuses a request without the mark, so no surface can place a plain-bank request past the price.
-- Shop off, or ordering closed, and this is false: the plain bank's free requests are unchanged.
function TOGBankClassic_Guild:IsShopSelling()
	return self:IsShopEnabled() and self:IsStoreOpen()
end

--- Open or close ordering, guild-wide. The ONE writer: the Shop tab's strip box (SHOP-TAB-001)
--- and the Blizzard options toggle both come here, so the sync and the chat line cannot drift
--- between them. Returns true when the value changed.
function TOGBankClassic_Guild:SetStoreOpen(open)
	if not self.Info then return false end
	if not self.Info.settings then self.Info.settings = {} end
	open = open and true or false
	if self:IsStoreOpen() == open then return false end
	self.Info.settings.storeOpen = open
	self:BroadcastSettings("ALERT")  -- SETTINGS-001
	TOGBankClassic_Output:Info(open and "Shop ordering is OPEN (syncing to guild...)."
		or "Shop ordering is CLOSED -- members cannot place shop orders (syncing to guild...).")
	return true
end

-- STORE-006 (GUILD_STORE.md 4.6, build-order step 2): the not-for-sale list. A per-item block on
-- the synced settings, keyed by itemID and NOT by name -- same-name variants are a solved problem
-- here (REQ-001) and a name-keyed list would undo it. Officer-set; off the list, an item is
-- ordinary; on it, Guild:AddRequest refuses and every surface says why. Capped so a misbehaving
-- sender cannot grow the settings broadcast without bound.
local NOT_FOR_SALE_MAX = 500

--- Sanitize an inbound not-for-sale table into `{ [itemID] = true }`: integer keys 1 and up only,
--- anything else dropped, at most NOT_FOR_SALE_MAX entries. Returns a fresh table.
local function sanitizeNotForSale(nfs)
	local clean, n = {}, 0
	if type(nfs) ~= "table" then return clean end
	for k, v in pairs(nfs) do
		local id = tonumber(k)
		if v and id and id >= 1 and id == math.floor(id) and n < NOT_FOR_SALE_MAX then
			clean[id] = true
			n = n + 1
		end
	end
	return clean
end
TOGBankClassic_Guild.SanitizeNotForSale = sanitizeNotForSale

function TOGBankClassic_Guild:IsNotForSale(itemID)
	if not self:IsShopEnabled() then return false end   -- SHOP-TAB-001: no shop, no shop list
	local s = self.Info and self.Info.settings
	local nfs = s and s.notForSale
	itemID = tonumber(itemID)
	return type(nfs) == "table" and itemID ~= nil and nfs[itemID] == true
end

--- The sentence every "you cannot order this" surface prints for a blocked item.
TOGBankClassic_Guild.NOT_FOR_SALE_TEXT = "%s is not for sale -- an officer has taken it off the shop list."

--- Put an item on, or take it off, the not-for-sale list, guild-wide. The ONE writer (the Browse
--- tab's officer gesture comes here), so the sync and the chat line cannot drift. Returns true when
--- the list changed; false for a non-item, a full list, or no change.
function TOGBankClassic_Guild:SetNotForSale(itemID, blocked, itemName)
	if not self.Info then return false end
	itemID = tonumber(itemID)
	if not itemID or itemID < 1 or itemID ~= math.floor(itemID) then return false end
	if not self.Info.settings then self.Info.settings = {} end
	local s = self.Info.settings
	if type(s.notForSale) ~= "table" then s.notForSale = {} end
	blocked = blocked and true or false
	if (s.notForSale[itemID] == true) == blocked then return false end
	if blocked then
		local n = 0
		for _ in pairs(s.notForSale) do n = n + 1 end
		if n >= NOT_FOR_SALE_MAX then
			TOGBankClassic_Output:Warn("The not-for-sale list is full (%d items).", NOT_FOR_SALE_MAX)
			return false
		end
		s.notForSale[itemID] = true
	else
		s.notForSale[itemID] = nil
	end
	self:BroadcastSettings("ALERT")  -- SETTINGS-001
	local label = itemName or ("item " .. tostring(itemID))
	TOGBankClassic_Output:Info(blocked and "%s is now NOT FOR SALE -- members cannot request it (syncing to guild...)."
		or "%s is back on sale (syncing to guild...).", label)
	return true
end

-- STORE-003 (GUILD_STORE.md 4.3, build-order step 8; the operator, 2026-09-14, on seeing the Shop
-- tab: "we need to set a % discount for the items. like if you want to sell all the items at 50%
-- off, we need to apply that to the pricing that is displayed on the shop tab"): a guild-wide
-- percentage off the shop's estimate, officer-set, synced like the sign. Applied at DISPLAY on the
-- Shop tab (Browse:PriceRows), never stored into a price -- the banker's price at fill is the
-- price (3), so the discount is what the member is shown, not what anyone is charged. A bare
-- number for now; a per-rank table (4.3's extrapolation) would sit beside it, not replace it.
--- The discount, 0..100, as an integer. 0 with the shop off, unset, or malformed.
function TOGBankClassic_Guild:GetStoreDiscount()
	if not self:IsShopEnabled() then return 0 end
	local s = self.Info and self.Info.settings
	local d = s and tonumber(s.storeDiscountPercent)
	if not d or d ~= d or d < 0 then return 0 end
	if d > 100 then return 100 end
	return math.floor(d)
end

--- Set the discount, guild-wide. The ONE writer. Returns true when the value changed.
function TOGBankClassic_Guild:SetStoreDiscount(pct)
	if not self.Info then return false end
	pct = tonumber(pct)
	if not pct or pct ~= pct or pct < 0 or pct > 100 then return false end
	pct = math.floor(pct)
	if not self.Info.settings then self.Info.settings = {} end
	if self.Info.settings.storeDiscountPercent == pct then return false end
	self.Info.settings.storeDiscountPercent = pct
	self:BroadcastSettings("ALERT")  -- SETTINGS-001 / 002
	TOGBankClassic_Output:Info(pct > 0 and "Shop discount set to %d%% off every estimate (syncing to guild...)."
		or "Shop discount removed -- estimates are shown at full value (syncing to guild...).", pct)
	local B = TOGBankClassic_UI_Browse
	if B and B.OnShopSettingChanged then B:OnShopSettingChanged() end
	return true
end

-- STORE-007 (GUILD_STORE.md 4.7, build-order step 6): the donation rate, points per gold of value,
-- "an officer-configurable rate -- 1g of value = 1 point by default, with the rate synced through
-- Guild.Info.settings exactly like the discount". Read through TOGBankClassic_Donations:Rate(),
-- which is what the ingest applies; a missing or malformed value reads as the default there.
--- Set the donation rate, guild-wide. The ONE writer. Returns true when the value changed.
function TOGBankClassic_Guild:SetDonationRate(rate)
	local D = TOGBankClassic_Donations
	if not self.Info or not D then return false end
	rate = tonumber(rate)
	if not rate or rate ~= rate or rate < D.RATE_MIN or rate > D.RATE_MAX then return false end
	rate = math.floor(rate * 100 + 0.5) / 100
	if not self.Info.settings then self.Info.settings = {} end
	if D:Rate() == rate and self.Info.settings.donationRate ~= nil then return false end
	self.Info.settings.donationRate = rate
	self:BroadcastSettings("ALERT")  -- SETTINGS-001
	TOGBankClassic_Output:Info("Donation credit set to %s per gold of value (syncing to guild...).", D:FormatPoints(rate))
	return true
end

-- STORE-002 / DONATION-VALUE-001 (b) (GUILD_STORE.md 4.2.1): the guild's PRICE AUTHORITY -- the one
-- character whose client publishes the guild price list (Modules/PriceList.lua), so every banker
-- values a gift the same and every member is shown the same estimate. Officer-set, guild-synced
-- with the other settings; "" (the default, and a missing value) means no authority and no list,
-- so a guild that never picks one prices on its own sources as before. Not gated by the shop
-- switch: a plain bank's donations are valued too.
local PRICE_AUTHORITY_MAX_LEN = 64

--- The authority's Name-Realm, or nil when none is set.
function TOGBankClassic_Guild:GetPriceAuthority()
	local s = self.Info and self.Info.settings
	local a = s and s.priceAuthority
	if type(a) ~= "string" or a == "" then return nil end
	return a
end

--- Is the character this client is on the price authority?
function TOGBankClassic_Guild:IsPriceAuthority()
	local a = self:GetPriceAuthority()
	local me = a and self:GetNormalizedPlayer()
	return a ~= nil and me ~= nil and a == me
end

--- Name (or with "" / nil, clear) the price authority, guild-wide. The ONE writer. A bare name is
--- normalised to Name-Realm. Returns true when the value changed.
function TOGBankClassic_Guild:SetPriceAuthority(name)
	if not self.Info then return false end
	local norm = ""
	if type(name) == "string" and not name:match("^%s*$") then
		norm = self:NormalizeName((name:gsub("^%s+", ""):gsub("%s+$", ""))) or ""
		if norm == "" then return false end
		norm = norm:sub(1, PRICE_AUTHORITY_MAX_LEN)
	end
	if not self.Info.settings then self.Info.settings = {} end
	if (self:GetPriceAuthority() or "") == norm then return false end
	self.Info.settings.priceAuthority = norm
	self:BroadcastSettings("ALERT")  -- SETTINGS-001 / 002
	TOGBankClassic_Output:Info(norm ~= "" and "%s now publishes the guild price list -- every estimate and donation value comes from their price sources (syncing to guild...)."
		or "The guild price list is off -- each client prices on its own sources again (syncing to guild...).", norm)
	if TOGBankClassic_PriceList then TOGBankClassic_PriceList:OnAuthorityChanged() end
	return true
end

-- BANKER-OWNER-001 (the operator, 2026-09-14: "the ability for officers to right click on a banker
-- in the bankers tab to assign who 'owns' the banker, that info would show on the mouseover
-- tooltip ... autocomplete for the names on the roster in guild roster but it can be free text
-- entry as some guilds like ours have a 'shared' account for the banker"): who runs each bank
-- character. `Info.settings.bankerOwners[norm] = text`, officer-set, guild-synced with the other
-- settings, free text bounded so a misbehaving sender cannot grow the broadcast. "" clears.
local BANKER_OWNER_MAX_LEN = 40
local BANKER_OWNER_MAX     = 100

--- Sanitize an inbound owner table into `{ [Name-Realm] = text }`: string keys and non-empty
--- string values only, each clamped, at most BANKER_OWNER_MAX entries. Returns a fresh table.
local function sanitizeBankerOwners(owners)
	local clean, n = {}, 0
	if type(owners) ~= "table" then return clean end
	for norm, text in pairs(owners) do
		if type(norm) == "string" and norm ~= "" and type(text) == "string" and n < BANKER_OWNER_MAX then
			text = text:gsub("^%s+", ""):gsub("%s+$", ""):sub(1, BANKER_OWNER_MAX_LEN)
			if text ~= "" then
				clean[norm] = text
				n = n + 1
			end
		end
	end
	return clean
end
TOGBankClassic_Guild.SanitizeBankerOwners = sanitizeBankerOwners

-- XGUILD-OWNERS-001 (the operator, 2026-09-16: "we also need to sync the right click who owns banker
-- metadata between sister guilds"). The owners travelled as ONE settings field with ONE stamp, so
-- across a federation whichever guild wrote last replaced the other guild's table outright: the home
-- guild's owners for its bank characters were wiped by the sister guild's broadcast, or the sister's
-- never landed at all because the home stamp was newer. Each ENTRY now carries its own stamp
-- (`bankerOwnerStamps[norm]`, the server time of the write that set or cleared it), a receiver
-- MERGES entry by entry -- newer stamp wins, a stamped absence is a clear -- and an entry for a bank
-- character is taken from a sister guild's member only when that bank character is in the SENDER'S
-- guild: each guild's officers say who runs their own bank characters, and a home guildmate relaying
-- what it learned (its own settings broadcast) is trusted as the request relay's courier is (D7).
-- Twice the owner cap: a clear keeps its stamp so an older set cannot resurrect the entry.
local BANKER_OWNER_STAMPS_MAX = BANKER_OWNER_MAX * 2

--- Sanitize an inbound per-entry stamp table into `{ [Name-Realm] = number }`, capped. Entries that
--- name an owner in `owners` are kept first, so the cap only ever drops the stamp of a clear.
local function sanitizeOwnerStamps(stamps, owners)
	local clean, n = {}, 0
	if type(stamps) ~= "table" then return clean end
	local function take(norm, v)
		if n < BANKER_OWNER_STAMPS_MAX and clean[norm] == nil then
			clean[norm] = v
			n = n + 1
		end
	end
	for pass = 1, 2 do
		for norm, v in pairs(stamps) do
			v = tonumber(v)
			if type(norm) == "string" and norm ~= "" and v and v > 0 and v == v then
				local named = type(owners) == "table" and owners[norm] ~= nil
				if (pass == 1) == named then take(norm, math.floor(v)) end
			end
		end
	end
	return clean
end
TOGBankClassic_Guild.SanitizeOwnerStamps = sanitizeOwnerStamps

--- May THIS client's officers say who runs `norm`'s bank character? Only for a bank character of
--- their own guild (XGUILD-OWNERS-001); a sister guild's are set by that guild.
function TOGBankClassic_Guild:BankerOwnerWritable(norm)
	norm = norm and self:NormalizeName(norm) or nil
	if not norm then return false end
	if self.IsHomeMember and self.GuildOf and self:GuildOf(norm) then return self:IsHomeMember(norm) end
	return true
end

--- XGUILD-OWNERS-001: merge a received owner table entry by entry. `inOwners` / `inStamps` are the
--- payload's; an entry is taken when its stamp is newer than the one held, or when neither side has
--- ever stamped it and we hold nothing for it (seeding from a copy written before the stamps).
--- `sender` must be a home guildmate, or in the same guild as the bank character the entry names.
--- Returns true when anything changed.
--- OWNERS-STAMP-001 (Peer Review, inbox 31294783: "two computations of one field stamp, each passing
--- its own spec"): after an owners MERGE, move the `bankerOwners` field stamp to the newest of the
--- payload's field stamp and its entry stamps, never backwards. The one spelling for both the home
--- path and the sister-guild branch of ApplyRemoteSettings. Without it an older pre-stamp whole-table
--- payload, judged against the field stamp, would replace the merged table.
---@param settings table the received guild-settings payload (carries `bankerOwnerStamps`)
---@return boolean moved
function TOGBankClassic_Guild:AdvanceOwnersStamp(settings)
	if not (self.Info and type(settings) == "table") then return false end
	local newest = tonumber(type(settings.stamps) == "table" and settings.stamps.bankerOwners) or 0
	for _, v in pairs(type(settings.bankerOwnerStamps) == "table" and settings.bankerOwnerStamps or {}) do
		v = tonumber(v)
		if v and v > newest then newest = v end
	end
	if newest <= self:SettingsStamp("bankerOwners") then return false end
	self.Info.settings = self.Info.settings or {}
	if type(self.Info.settings.stamps) ~= "table" then self.Info.settings.stamps = {} end
	self.Info.settings.stamps.bankerOwners = newest
	return true
end

function TOGBankClassic_Guild:MergeBankerOwners(sender, inOwners, inStamps)
	local s = self.Info.settings
	local owners = sanitizeBankerOwners(s.bankerOwners)
	local stamps = sanitizeOwnerStamps(s.bankerOwnerStamps, owners)
	inOwners = sanitizeBankerOwners(inOwners)
	inStamps = sanitizeOwnerStamps(inStamps, inOwners)
	-- A sender is held to its own guild's bank characters only when it is KNOWN to be a sister guild's
	-- member. ApplyRemoteSettings has already authorized it; one the rosters cannot place is treated as
	-- the settings always treated it (BANKER-OWNER-001's whole-table adopt accepted it).
	local senderGuild = self.GuildOf and self:GuildOf(sender) or nil
	local fromHome = not self.IsHomeMember or self:IsHomeMember(sender) or senderGuild == nil
	local keys = {}
	for norm in pairs(inOwners) do keys[norm] = true end
	for norm in pairs(inStamps) do keys[norm] = true end
	local changed = false
	for norm in pairs(keys) do
		local allowed = fromHome or (senderGuild ~= nil and self:GuildOf(norm) == senderGuild)
		local theirs, ours = inStamps[norm] or 0, stamps[norm] or 0
		-- SETTINGS-TIE-001 (Peer Review on 3197046a, F2): on an equal stamp the greater name wins and a
		-- cleared owner counts as "", so two officers' same-second writes settle on one in either order.
		-- KNOWN COST: a clear in the same second as someone else's set loses; the owner stays listed.
		local take = theirs > ours
			or (theirs == ours and theirs > 0 and (inOwners[norm] or "") > (owners[norm] or ""))
			or (theirs == 0 and ours == 0 and owners[norm] == nil and inOwners[norm] ~= nil)
		if allowed and take then
			if owners[norm] ~= inOwners[norm] then changed = true end
			owners[norm] = inOwners[norm]
			if theirs > 0 then stamps[norm] = theirs end
		elseif not allowed and take then
			TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "owner of %s from %s refused: %s is not that bank character's guild",
				norm, tostring(sender), tostring(senderGuild))
		end
	end
	s.bankerOwners = sanitizeBankerOwners(owners)
	s.bankerOwnerStamps = sanitizeOwnerStamps(stamps, s.bankerOwners)
	return changed
end

--- XGUILD-SETTINGS-001: whisper `target` (a sister guild's member) who runs each bank character, and
--- nothing else of the settings. Sent by ANY client -- a plain member holds the owners its officers
--- wrote exactly as they do -- because the sister side takes only this from us. Returns true when sent.
---@param target string normalized
---@return boolean
function TOGBankClassic_Guild:SendBankerOwnersTo(target)
	local s = self.Info and self.Info.settings
	if not (target and s) then return false end
	local owners = sanitizeBankerOwners(s.bankerOwners)
	local stamps = sanitizeOwnerStamps(s.bankerOwnerStamps, owners)
	-- Peer Review on 31294783 (F4): never the receiver's OWN guild's entries -- its officers wrote
	-- them, MergeBankerOwners refuses them from us, and each one was a wasted entry plus a debug line.
	local theirs = self.GuildOf and self:GuildOf(target) or nil
	if theirs then
		for norm in pairs(stamps) do
			if self:GuildOf(norm) == theirs then owners[norm], stamps[norm] = nil, nil end
		end
		for norm in pairs(owners) do
			if self:GuildOf(norm) == theirs then owners[norm] = nil end
		end
	end
	if next(owners) == nil and next(stamps) == nil then return false end
	local payload = { type = "guild-settings", settings = { bankerOwners = owners, bankerOwnerStamps = stamps } }
	return TOGBankClassic_Core:SendWhisper("togbank-hl", TOGBankClassic_Core:SerializeWithChecksum(payload), target, "NORMAL") and true or false
end

--- Who owns `norm`'s bank character, as an officer wrote it, or nil.
function TOGBankClassic_Guild:GetBankerOwner(norm)
	local s = self.Info and self.Info.settings
	local owners = s and s.bankerOwners
	if type(owners) ~= "table" or not norm then return nil end
	local text = owners[self:NormalizeName(norm) or norm]
	return type(text) == "string" and text ~= "" and text or nil
end

--- Set (or with "" / nil, clear) who owns a bank character, guild-wide. The ONE writer. Returns
--- true when the value changed.
function TOGBankClassic_Guild:SetBankerOwner(norm, text)
	if not self.Info then return false end
	norm = norm and self:NormalizeName(norm) or nil
	if not norm then return false end
	-- XGUILD-OWNERS-001: a sister guild's bank character is that guild's to describe.
	if not self:BankerOwnerWritable(norm) then return false end
	text = type(text) == "string" and text:gsub("^%s+", ""):gsub("%s+$", ""):sub(1, BANKER_OWNER_MAX_LEN) or ""
	if not self.Info.settings then self.Info.settings = {} end
	local owners = sanitizeBankerOwners(self.Info.settings.bankerOwners)
	if (owners[norm] or "") == text then return false end
	if text == "" then
		owners[norm] = nil
	else
		local n = 0
		for _ in pairs(owners) do n = n + 1 end
		if not owners[norm] and n >= BANKER_OWNER_MAX then return false end
		owners[norm] = text
	end
	-- XGUILD-OWNERS-001: this entry's own stamp, newer than whatever this client held for it.
	local stamps = sanitizeOwnerStamps(self.Info.settings.bankerOwnerStamps, owners)
	stamps[norm] = math.max(GetServerTime() or 0, (stamps[norm] or 0) + 1)
	self.Info.settings.bankerOwners = owners
	self.Info.settings.bankerOwnerStamps = sanitizeOwnerStamps(stamps, owners)
	self:BroadcastSettings("ALERT")  -- SETTINGS-001 / 002
	TOGBankClassic_Output:Info(text ~= "" and "%s is run by %s (syncing to guild...)." or "%s has no owner listed now (syncing to guild...).",
		norm, text)
	local B = TOGBankClassic_UI_Browse
	if B and B.OnBankerOwnerChanged then B:OnBankerOwnerChanged() end
	return true
end

-- SETTINGS-002: the version of the guild settings this client holds (0 = never stamped).
function TOGBankClassic_Guild:SettingsVersion()
	local s = self.Info and self.Info.settings
	return s and tonumber(s.version) or 0
end

-- SETTINGS-004 (Peer Review f5e52bcf F5): PER-FIELD STAMPS. SETTINGS-002's one version stopped a
-- stale RE-ANNOUNCEMENT and not a stale WRITER: an officer who missed Monday's "ordering closed"
-- and set the discount on Tuesday stamped the whole payload fresh, and every client adopted the
-- stale `storeOpen = true` it carried with the new discount. So each field carries the server
-- time of the write that last changed IT (`settings.stamps[key]`), a receiver adopts field by
-- field, and a writer's stale copy of a field it did not touch keeps its old stamp and loses.
--
-- The stamps are minted HERE, not at the fifteen writer sites: an ALERT broadcast diffs the payload
-- it builds against the last one this client sent or applied (`lastSettingsPayload`, a deep copy --
-- Requests.lua mutates `cancelReasons` in place, and a reference would already carry the change),
-- and stamps only the keys that moved. The snapshot is taken when the record is bound and whenever
-- settings are applied (SETTINGS-STALE-001, below); a write that still finds none diffs against the
-- defaults, never "stamp every key" -- that was how a stale default reached the whole guild.
-- A pre-004 receiver ignores `stamps` and applies whole on `version`, as it did.

local function deepEqual(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

local function deepCopy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = deepCopy(x) end
	return out
end

--- The stamp this client holds for one settings field: its own stamp, else the whole-payload
--- version (a field written before SETTINGS-004 is as old as the version that carried it).
function TOGBankClassic_Guild:SettingsStamp(key)
	local s = self.Info and self.Info.settings
	local st = s and s.stamps
	local own = type(st) == "table" and tonumber(st[key]) or nil
	return own or self:SettingsVersion()
end

--- SETTINGS-STALE-001 (the operator, 2026-09-25, after the Sister-guild bank was found unticked
--- guild-wide: "we need to make sure someone logging on for the first time doesn't uncheck it, as
--- that's the default. how do we guard this?"). The snapshot a write diffs against was EMPTY at two
--- moments -- a session's first write before any settings were sent or heard, and any write after
--- settings were RECEIVED (ApplyRemoteSettings cleared it) -- and an empty snapshot stamped EVERY
--- field as freshly written. So an officer whose client still held the default "off" (a first login,
--- or one that missed the tick) changed the discount and pushed "off", newest, to the whole guild.
--- Now the snapshot is the HELD settings from the moment the record is bound or settings are
--- applied, tied to that settings table (a snapshot of another table is no snapshot); and should a
--- write still find none, it diffs against the DEFAULTS, so a default value can never be stamped by
--- a write that did not change it.

--- The synced fields as a client that has never held settings would send them.
---@return table
function TOGBankClassic_Guild:DefaultSettingsFields()
	local held = self.Info.settings
	self.Info.settings = {}
	local ok, fields = pcall(self.SettingsFields, self)
	self.Info.settings = held
	return ok and fields or {}
end

--- Remember the settings this client holds now as the baseline the next write diffs against.
function TOGBankClassic_Guild:SnapshotSettings()
	local s = self.Info and self.Info.settings
	if type(s) ~= "table" then
		self.lastSettingsPayload, self.lastSettingsFor = nil, nil
		return
	end
	self.lastSettingsPayload = deepCopy(self:SettingsFields())
	self.lastSettingsFor = s
end

--- Stamp every field of `fields` that differs from the last payload sent or applied with `v`,
--- and remember `fields` as the new snapshot. Returns the stamps table (the held one).
function TOGBankClassic_Guild:StampChangedFields(fields, v)
	local s = self.Info.settings
	if type(s.stamps) ~= "table" then s.stamps = {} end
	local last = self.lastSettingsFor == s and self.lastSettingsPayload or nil
	if not last then last = self:DefaultSettingsFields() end   -- SETTINGS-STALE-001
	for key, val in pairs(fields) do
		if key ~= "version" and key ~= "stamps" and (not last or not deepEqual(val, last[key])) then
			s.stamps[key] = v
		end
	end
	self.lastSettingsPayload = deepCopy(fields)
	self.lastSettingsFor = s
	return s.stamps
end

-- SETTINGS-CANON-001 (the operator, 2026-09-16: "we need to ensure the the request % is being synced
-- and enforced. people are still allowed to request more than what was set. the officer setting
-- needs to be part of EVERY sync. they should have a canon has as well and if someones is older, they
-- need to pull the new settings as part of their sync"). Until this the settings were a PUSH only --
-- the officer's ALERT write, and an authorized client's re-announcement on its ten-minute cycle -- so
-- a client that missed both (offline through the write, or logged in while no banker or officer was
-- on) held the old maximum request % with no way to learn it was behind, and its request dialog
-- enforced the old number. Now EVERY client's sync broadcast (the hlb2 cycle and the hash-list reply)
-- names the settings VERSION it holds and a CANON of their values; a client that hears an authorized
-- guildmate holding newer ones -- or the same version with different values -- ASKS that guildmate by
-- whisper and is answered with the settings (the existing payload, applied field by field under
-- SETTINGS-004's stamps). A handshake, not a timer (HANDSHAKE-OVER-TIMERS-001).

--- A deterministic string of a settings value: table keys sorted, so two clients holding the same
--- values produce the same bytes however their tables were built.
local function canonicalSettings(v)
	local t = type(v)
	if t == "table" then
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local parts = {}
		for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. canonicalSettings(v[k]) end
		return "{" .. table.concat(parts, ";") .. "}"
	elseif t == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

--- SETTINGS-TIE-001 (Peer Review on the GSL step-2 self-audit, F1): the ONE rule for taking a received
--- settings field. A newer stamp wins and an older one loses. On an EQUAL stamp -- two writes in the
--- same second -- it used to be whichever payload arrived last, so two clients holding different
--- values at one stamp each took the other's and never agreed. Now the greater canonical value wins:
--- every client picks the same winner whatever order the payloads arrive in. An unset field is
--- seeded. The caller judges fields BEFORE it moves the held version: a field with no stamp of its
--- own is as old as that version, and moved first it read as exactly the payload's stamp -- a tie on
--- every one (the first cut of this rule refused a GM's percent that way; settings_spec caught it).
--- KNOWN COST: a tie seen by a plain member while the writer holding the greater value is offline
--- makes that member ask the other writer once per SETTINGS_ASK_COOLDOWN until the two writers meet.
--- `value` is the field as it would be stored.
local function adoptSettingsField(self, key, stamp, value)
	local held = self:SettingsStamp(key)
	if stamp ~= held then return stamp > held end
	local current = self.Info.settings[key]
	if current == nil then return true end
	return canonicalSettings(value) > canonicalSettings(current)
end

--- The seconds between two asks of one peer for one advertised (version, canon), and between two
--- answers to one asker. A burst of broadcasts is one ask; they are not a wait for anything.
TOGBankClassic_Guild.SETTINGS_ASK_COOLDOWN = 60
TOGBankClassic_Guild.SETTINGS_ANSWER_COOLDOWN = 30

--- SETTINGS-CANON-001: the canon of the guild settings this client holds -- a checksum of the synced
--- VALUES (not the stamps or the version), so two clients that agree on every value agree on it.
--- nil before the guild record exists.
---@return string|nil
function TOGBankClassic_Guild:SettingsCanon()
	if not (self.Info and self.Info.settings) then return nil end
	return self:CanonOfSettingsFields(self:SettingsFields())
end

--- The canon of a SettingsFields-shaped table -- ours, or a guild-settings payload as its sender built
--- it (SETTINGS-FANOUT-001 records a sender's from the payload). `version` and `stamps` never count.
---@param source table
---@return string
function TOGBankClassic_Guild:CanonOfSettingsFields(source)
	local Core = TOGBankClassic_Core
	local fields = {}
	for k, v in pairs(source) do
		-- SETTINGS-CANON-002 (Peer Review on 4777d14a, finding 1): the officer rank floor is left OUT.
		-- ApplyRemoteSettings adopts it from the GM alone but takes the payload's version from any
		-- authorized sender, so a member answered by a banker held the banker's version with its own
		-- old floor -- equal version, different canon, forever -- and asked every banker it heard on
		-- every sync until a GM broadcast reached it. The floor still travels on every payload; the
		-- GM's own publish (ALERT) and its ten-minute re-announcement deliver it.
		-- XGUILD-OWNERS-001: the owner stamps are bookkeeping, like `stamps` -- two clients holding the
		-- same owners agree however they came by them.
		-- GSL-MERGE-001: the shopping list is left OUT as well. A v1.6.1 client's payload has no such
		-- fields, so hashing them here would make every v1.6.1 / v1.7.0 pair disagree forever -- equal
		-- version, different canon -- and ask each other on every sync. The list reaches a client that
		-- missed it by the version a write moves, the entry merge on every payload heard, and the
		-- ten-minute re-announcement. KNOWN COST: two writes of the same second on two clients are
		-- only reconciled by the next payload either hears, not by a canon ask.
		if k ~= "version" and k ~= "stamps" and k ~= "officerRankFloor" and k ~= "bankerOwnerStamps"
			and k ~= "craftList" and k ~= "craftListStamps" and k ~= "gatherStart" and k ~= "gatherEnd" then
			fields[k] = v
		end
	end
	-- Hash the values AS A RECEIVER STORES THEM. ApplyRemoteSettings sanitizes the cancel reasons and
	-- help notes (filling a missing window key with "", a missing presetDisabled role with {}) and
	-- floors the two numbers; the writer's own copy keeps whatever shape its editor left. Hashing the
	-- raw copy made an officer and every member who applied their settings disagree FOREVER -- equal
	-- version, different canon -- so the pair re-sent the settings on every sync (self-audit finding).
	-- The two numbers are also clamped where they are SENT (SettingsFields), because a value the
	-- receiver refuses cannot be matched by any hash.
	if fields.cancelReasons ~= nil and self.SanitizeCancelReasons then fields.cancelReasons = self.SanitizeCancelReasons(fields.cancelReasons) end
	if fields.helpNotes ~= nil and self.SanitizeHelpNotes then fields.helpNotes = self.SanitizeHelpNotes(fields.helpNotes) end
	if tonumber(fields.maxRequestPercent) then fields.maxRequestPercent = math.floor(fields.maxRequestPercent) end
	if tonumber(fields.autoTombstoneDays) then fields.autoTombstoneDays = math.floor(fields.autoTombstoneDays) end
	local text = canonicalSettings(fields)
	return tostring(Core and Core.Checksum and Core:Checksum(text) or #text)
end

--- May `sender`'s copy of the settings be adopted? The same standing ApplyRemoteSettings requires --
--- asking a guildmate whose answer would be dropped would be a wasted whisper.
---
--- XGUILD-SETTINGS-002 (Peer Review F4 on self-audit 13180dbf): never a member of ANOTHER guild. The
--- three sender helpers answer true for a sister guild's bank characters, officers and GM (each reads
--- that guild's own roster), which is right where they authorize a sister guild's bank data and wrong
--- here: a sister guild's officer is not ours. ApplyRemoteSettings' sister branch was the only wall
--- between another guild and every officer setting; this is the second, on the same test that branch
--- uses (placed in a guild, and not the home one). The helpers are left as they are.
function TOGBankClassic_Guild:SettingsSenderAuthorized(sender)
	if sender == nil then return false end
	if self.IsHomeMember and self.GuildOf and self:GuildOf(sender) and not self:IsHomeMember(sender) then return false end
	return (self:SenderHasGbankNote(sender) or self:SenderIsGM(sender) or self:SenderIsOfficer(sender)) and true or false
end

-- SETTINGS-FANOUT-001 (self-audit 4777d14a F2): a behind member's login hlb2 goes to the whole
-- guild, and every client with standing that heard it answered -- six bankers and two officers
-- online sent eight identical settings whispers where one does the job. ONE responder is picked,
-- without a timer (HANDSHAKE-OVER-TIMERS-001): THE LOWEST-SORTING ONLINE AUTHORIZED GUILDMATE KNOWN
-- TO HOLD SETTINGS THE ASKER LACKS ANSWERS. Every client records what each authorized guildmate
-- said it holds -- its hlb2 / hash-list reply (`sv`, `sh`) and its own guild-settings payload, never
-- an inference about who else heard one -- and defers when an online home guildmate sorting before it
-- is recorded ahead of the asker. A record only ever UNDER-states what a guildmate holds (versions
-- only grow), so a deferral is to a guildmate that really is ahead; the one at the bottom of that
-- chain defers to nobody and answers. KNOWN COST: records refresh on each guildmate's own sync, so in
-- the ten minutes after an officer's write the bankers' records of each other still show the old
-- version and several may answer, as before this fix. The one way to miss -- a recorded guildmate
-- that went offline before the roster said so, or wiped its settings -- is recovered without a timer:
-- the behind member hears the next hlb2 of any authorized guildmate and asks it (the BEHIND branch).

--- Lua 5.1 compares strings "according to the current locale" (manual §2.5.2), and every client
--- must agree on who sorts first -- so names are compared byte by byte.
local function byteLess(a, b)
	local la, lb = #a, #b
	for i = 1, math.min(la, lb) do
		local x, y = a:byte(i), b:byte(i)
		if x ~= y then return x < y end
	end
	return la < lb
end

--- Does a holder of (version, canon) hold settings an asker advertising (theirs, theirCanon) lacks?
--- OnSettingsRequest's own test. A nil canon on either side is unknown, and an unknown never counts
--- as different.
local function settingsAhead(version, canon, theirs, theirCanon)
	if version > theirs then return true end
	return version == theirs and version > 0 and canon ~= nil and theirCanon ~= nil and canon ~= theirCanon
end

--- SETTINGS-FANOUT-001: record that authorized guildmate `peer` holds (version, canon). A record never
--- moves backwards except on the peer's own advertisement, which is the truth (a wipe lowers it).
---@param own boolean true when the peer itself said so (hlb2, hash-list reply, its own payload)
function TOGBankClassic_Guild:NoteSettingsHeld(peer, version, canon, own)
	if not (peer and tonumber(version)) or peer == self:GetNormalizedPlayer() then return end
	if not self:SettingsSenderAuthorized(peer) then return end
	self.settingsHeard = self.settingsHeard or {}
	local rec = self.settingsHeard[peer]
	version = tonumber(version)
	if own or not rec or version > rec.version then
		self.settingsHeard[peer] = { version = version, canon = canon ~= nil and tostring(canon) or nil }
	end
end

--- SETTINGS-FANOUT-001: a guild-settings payload arrived from `sender`, which holds exactly what it
--- sent. NOT inferred: that the rest of the guild heard a GUILD payload and now holds it. A receiver
--- judges the sender's standing by its own roster view (an officer's write before the GM publishes
--- the rank floor is dropped by clients ranked below the writer, SETTINGS-003), so that inference
--- would defer to a guildmate that is not ahead -- a missed answer, which is worse than a spare one.
---@param sender string normalized
---@param settings table the payload
function TOGBankClassic_Guild:NoteSettingsBroadcast(sender, settings)
	if type(settings) ~= "table" then return end
	self:NoteSettingsHeld(sender, tonumber(settings.version) or 0, self:CanonOfSettingsFields(settings), true)
end

--- SETTINGS-FANOUT-001: the online authorized home guildmate, sorting before us, known to hold
--- settings `asker` lacks -- the one that answers it instead of us -- or nil when we answer. Records
--- of guildmates no longer online, home or authorized are ignored rather than trusted.
---@param asker string normalized; never a candidate (it is the one behind)
---@param theirs number the asker's advertised version
---@param theirCanon string|nil the asker's advertised canon
---@return string|nil deferTo
function TOGBankClassic_Guild:SettingsResponderBefore(asker, theirs, theirCanon)
	local heard = self.settingsHeard
	if type(heard) ~= "table" then return nil end
	local me = self:GetNormalizedPlayer() or ""
	local best = nil
	for peer, rec in pairs(heard) do
		if peer ~= me and peer ~= asker and byteLess(peer, best or me)
			and settingsAhead(rec.version, rec.canon, theirs, theirCanon)
			and self:IsPlayerOnline(peer) and (not self.IsHomeMember or self:IsHomeMember(peer))
			and self:SettingsSenderAuthorized(peer) then
			best = peer
		end
	end
	return best
end

--- SETTINGS-CANON-001: a HOME guildmate's sync broadcast named the settings it holds (a sister
--- guild's officers set their own guild's settings, so a sister member's are neither asked for nor
--- answered). Both sides of the handshake start here, so whichever client holds the newer copy, the
--- exchange happens on THIS sync rather than on somebody's next ten-minute cycle:
---   * BEHIND it -- a newer version, or the same version with different values -- ask it by whisper,
---     when it has the standing whose answer we would adopt;
---   * AHEAD of it -- a member logging in with yesterday's limit -- answer it by whisper at once, when
---     WE have that standing (OnSettingsRequest, with its own cooldown) and no online guildmate
---     outranks us to do it (SETTINGS-FANOUT-001). `private` is an advertisement only WE heard (a
---     hash-list reply whispered to us): nobody else can answer it, so nobody is deferred to.
--- One (peer, version, canon) is asked once per SETTINGS_ASK_COOLDOWN.
---@param sender string normalized
---@param version any the advertised version (`sv`)
---@param canon any the advertised canon (`sh`)
---@param private boolean|nil true when the advertisement reached this client alone
---@return boolean acted true when an ask or an answer went out
function TOGBankClassic_Guild:OnSettingsAdvertised(sender, version, canon, private)
	version = tonumber(version)
	if not (version and sender and self.Info and self.Info.settings) then return false end
	if sender == self:GetNormalizedPlayer() then return false end
	if self.IsHomeMember and not self:IsHomeMember(sender) then return false end
	local held, heldCanon = self:SettingsVersion(), self:SettingsCanon()
	canon = canon ~= nil and tostring(canon) or nil
	self:NoteSettingsHeld(sender, version, canon, true)
	-- SETTINGS-AHEAD-001: the one rule (settingsAhead) from the sender's side; it was open-coded here
	-- and in OnSettingsRequest with a different nil check each (Peer Review 2c807551, F3).
	local behind = settingsAhead(version, canon, held, heldCanon)
	if not behind then
		if not private and settingsAhead(held, heldCanon, version, canon) then
			local deferTo = self:SettingsResponderBefore(sender, version, canon)
			if deferTo then
				TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "%s advertised settings v%d it could update; %s (holding v%d) answers it, not us",
					sender, version, deferTo, self.settingsHeard[deferTo].version)
				return false
			end
		end
		return self:OnSettingsRequest(sender, { held = version, canon = canon })
	end
	if not self:SettingsSenderAuthorized(sender) then return false end
	local key = sender .. "|" .. version .. "|" .. tostring(canon)
	self.settingsAsked = self.settingsAsked or {}
	local now = GetServerTime() or 0
	local last = self.settingsAsked[key]
	if last and now - last < self.SETTINGS_ASK_COOLDOWN then return false end
	self.settingsAsked[key] = now
	local Core = TOGBankClassic_Core
	local payload = { type = "settings-request", held = held, canon = heldCanon }
	local sent = Core and Core:SendWhisper("togbank-hl", Core:SerializeWithChecksum(payload), sender, "NORMAL")
	TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "asked %s for guild settings v%d (holding v%d, canon %s vs %s): %s",
		sender, version, held, tostring(heldCanon), tostring(canon), sent and "sent" or "not sent")
	return sent and true or false
end

--- SETTINGS-CANON-001: a guildmate asked for our settings. Answered by whisper with the settings
--- payload (BroadcastSettings' own, unstamped) when we hold something the asker does not -- a newer
--- version, or the same version with different values -- at most once per asker per
--- SETTINGS_ANSWER_COOLDOWN. BroadcastSettings refuses for a client without standing.
---@param sender string normalized
---@param data table { type = "settings-request", held = number, canon = string }
---@return boolean answered
function TOGBankClassic_Guild:OnSettingsRequest(sender, data)
	if type(data) ~= "table" or not sender or not (self.Info and self.Info.settings) then return false end
	local me = self:GetNormalizedPlayer()
	if not me or sender == me or not self:SettingsSenderAuthorized(me) then return false end
	local held, heldCanon = self:SettingsVersion(), self:SettingsCanon()
	local theirs = tonumber(data.held) or 0
	-- Equal versions differing in value are answered only once something has been stamped: two
	-- never-stamped clients can hold different defaults (a field one of them has never had), and an
	-- unstamped payload cannot settle that -- it would be re-sent on every sync for nothing.
	local differs = settingsAhead(held, heldCanon, theirs, data.canon ~= nil and tostring(data.canon) or nil)
	if not differs then return false end
	self.settingsAnswered = self.settingsAnswered or {}
	local now = GetServerTime() or 0
	local last = self.settingsAnswered[sender]
	if last and now - last < self.SETTINGS_ANSWER_COOLDOWN then return false end
	self.settingsAnswered[sender] = now
	self:BroadcastSettings(nil, sender)
	TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "answered %s's settings ask with v%d (it held v%d)", sender, held, theirs)
	return true
end

-- SETTINGS-003 (Peer Review f5e52bcf F1): WHO IS AN OFFICER, as far as a RECEIVER can tell.
-- memberRoster.isOfficer was built from a threshold = the LOCAL player's own rank (nil when it
-- cannot view officer notes), so an officer's settings write, and its donation bucket, were
-- DROPPED by every receiver ranked below the writer -- the GM's client and every member included.
-- The shop's controls reached nobody they govern unless the writer was the GM or wore a gbank note.
--
-- The client's rank permissions are readable through C_GuildInfo.GuildControlGetRankFlags
-- (classic_era GuildInfoDocumentation.lua; index 11 = View Officer Note, the same predicate the
-- writer's CanViewOfficerNote answers). Blizzard's own Era code reads it from the Guild Control
-- UI -- the GM's -- and nothing documents what a non-GM's client gets back, so ONLY THE GM'S client
-- reads it: it derives the highest rank that may view officer notes and publishes that as
-- `officerRankFloor` on the synced settings, which a receiver adopts from a GM sender alone
-- (rankIndex 0 is the one rank every client can judge). Every client then judges a sender against
-- a number it holds. Until the GM has logged in on this build the old threshold rule stands (a
-- lower bound); KNOWN COST, stated in the CHANGELOG.
TOGBankClassic_Guild.VIEW_OFFICER_NOTE_FLAG = 11

--- The published floor: the highest rankIndex that counts as an officer, or nil when the GM has
--- not published one.
function TOGBankClassic_Guild:OfficerRankFloor()
	local s = self.Info and self.Info.settings
	local n = s and tonumber(s.officerRankFloor)
	if n and n >= 0 and n == math.floor(n) then return n end
	return nil
end

--- Read the floor from the client's rank permissions: the highest rankIndex whose flags say View
--- Officer Note. nil when the API is absent or answers nothing (a non-GM client, or no data yet).
function TOGBankClassic_Guild:ReadOfficerRankFloor()
	if not (C_GuildInfo and C_GuildInfo.GuildControlGetRankFlags and GuildControlGetNumRanks) then return nil end
	local n = tonumber(GuildControlGetNumRanks()) or 0
	local floor = nil
	for order = 1, n do
		local ok, flags = pcall(C_GuildInfo.GuildControlGetRankFlags, order)
		if ok and type(flags) == "table" and flags[self.VIEW_OFFICER_NOTE_FLAG] == true then
			floor = order - 1
		end
	end
	return floor
end

--- The GM's client publishes the floor when it differs from what the guild holds. Called after
--- every roster rebuild; a no-op on any other client. Returns true when it broadcast.
function TOGBankClassic_Guild:PublishOfficerRankFloor()
	local me = self:GetNormalizedPlayer()
	if not (me and self.Info and self:SenderIsGM(me)) then return false end
	local floor = self:ReadOfficerRankFloor()
	if floor == nil or floor == self:OfficerRankFloor() then return false end
	self.Info.settings = self.Info.settings or {}
	self.Info.settings.officerRankFloor = floor
	TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "officer rank floor read from the guild's rank permissions: rankIndex <= %d", floor)
	self:BroadcastSettings("ALERT")
	return true
end

--- SETTINGS-002: a local officer write happened -- stamp the settings newer than anything held,
--- so every client that hears this broadcast prefers it to what it holds. Server time, so every
--- client's stamps are on one clock; +1 over the held version guards two writes in one second.
function TOGBankClassic_Guild:StampSettings()
	if not self.Info then return 0 end
	if not self.Info.settings then self.Info.settings = {} end
	local v = math.max(GetServerTime() or 0, self:SettingsVersion() + 1)
	self.Info.settings.version = v
	return v
end

-- SETTINGS-001: Broadcast guild-wide settings to all online members.
-- Only authorized senders (banker/officer/GM) may broadcast. Called after any settings change
-- and piggybacked onto the periodic SyncDeltaVersion cycle (TIMER_INTERVALS.VERSION_BROADCAST)
-- so new joiners also receive values.
--
-- SETTINGS-002: THE SETTINGS CARRY A VERSION, and a receiver applies only a newer one. Without it
-- the periodic piggyback made every authorized client a writer: a banker logging in with
-- yesterday's settings re-broadcast them on its first cycle and reverted an officer's close /
-- shop-off / not-for-sale / rate on every client (last writer wins). The version is the server
-- time of the officer's write, stamped HERE when the call is the write's own ALERT broadcast --
-- every writer in the addon calls BroadcastSettings("ALERT") after mutating, and the periodic
-- piggyback calls it with no priority, so "ALERT" is the one signal that distinguishes "I changed
-- something" from "I am re-announcing what I hold". A re-announcement carries the version it
-- holds and cannot overwrite a newer one; the stale client is itself corrected by the next newer
-- broadcast it hears.
--
-- XGUILD-SYNC-001 (D6): with `target`, the same payload goes by WHISPER to one federated asker
-- instead of to the guild -- never stamped (it is a re-announcement), never a write.
function TOGBankClassic_Guild:BroadcastSettings(priority, target)
	if not self.Info or not self.Info.settings then return end
	local myPlayer = self:GetNormalizedPlayer()
	if not myPlayer then return end
	-- GSL-MERGE-001: the `[GSL]`-tagged member writes the shopping list and must be able to send it;
	-- a receiver takes only the list from them (ApplyRemoteSettings).
	if not self:IsBank(myPlayer) and not self:SenderIsOfficer(myPlayer) and not self:SenderIsGM(myPlayer)
		and not (TOGBankClassic_CraftList and TOGBankClassic_CraftList:IsGSLPlayer(myPlayer)) then return end
	local stamped = nil
	if priority == "ALERT" and not target then stamped = self:StampSettings() end
	local fields = self:SettingsFields()
	-- SETTINGS-002: always a number; 0 is "never stamped" (a client that has only ever held
	-- defaults, or one built before the field).
	fields.version = self:SettingsVersion()
	local payload = { type = "guild-settings", settings = fields }
	-- SETTINGS-004: a write stamps the fields it changed; a re-announcement (and the whisper to a
	-- federated asker) carries the stamps it holds. Either way the snapshot moves to this payload.
	if stamped then
		self:StampChangedFields(payload.settings, stamped)
	else
		self.lastSettingsPayload = deepCopy(payload.settings)
		self.lastSettingsFor = self.Info.settings
	end
	payload.settings.stamps = deepCopy(self.Info.settings.stamps)
	local data = TOGBankClassic_Core:SerializeWithChecksum(payload)
	if target then
		TOGBankClassic_Core:SendWhisper("togbank-hl", data, target, priority or "NORMAL")
	else
		TOGBankClassic_Core:SendCommMessage("togbank-hl", data, "GUILD", nil, priority or "NORMAL")
	end
	TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "BroadcastSettings to %s: maxRequestPercent=%s autoTombstoneDays=%s",
		target or "guild", tostring(payload.settings.maxRequestPercent), tostring(payload.settings.autoTombstoneDays))
end

--- The synced settings VALUES, as they go on the wire -- BroadcastSettings' payload without its
--- version and stamps, and what SettingsCanon hashes (SETTINGS-CANON-001), so the broadcast and the
--- canon cannot name different fields.
---@return table fields
function TOGBankClassic_Guild:SettingsFields()
	local s = self.Info.settings
	return {
		-- SETTINGS-003: the officer rank floor the GM published (nil until then).
		officerRankFloor = self:OfficerRankFloor(),
		-- SETTINGS-CANON-002 (Peer Review on 4777d14a): the two numbers go out in the form a receiver
		-- STORES -- whole, the percent within 1..100, the days at least 1 -- the range the receiving gate
		-- in ApplyRemoteSettings accepts and Guild:MaxRequestPercent enforces. A legacy stored 0 went out
		-- raw, every receiver refused it and kept its own, and the canons never matched. nil stays nil.
		maxRequestPercent = tonumber(s.maxRequestPercent) and math.min(100, math.max(1, math.floor(s.maxRequestPercent))) or nil,
		autoTombstoneDays = tonumber(s.autoTombstoneDays) and math.max(1, math.floor(s.autoTombstoneDays)) or nil,
		-- CANCELREASON-001: officer-authored custom cancel reasons + preset disable-set
		cancelReasons = s.cancelReasons,
		-- HELPNOTE-001: officer-authored per-window help-tooltip notes
		helpNotes = s.helpNotes,
		-- STORE-006: the open/closed sign. Sent as a real boolean, never nil, so a receiver that has
		-- it can tell "closed" from "this sender predates the field".
		storeOpen = s.storeOpen ~= false,   -- the stored sign, not the shop-gated read
		-- STORE-006: the not-for-sale list, always a table (empty means "nothing blocked"), so a
		-- receiver can tell "cleared" from "this sender predates the field".
		notForSale = sanitizeNotForSale(s.notForSale),
		-- SHOP-TAB-001: whether this guild's bank is a shop at all. A real boolean, never nil.
		shopEnabled = self:IsShopEnabled(),
		-- XGUILD-SWITCH-001: whether this bank spans the sister guilds. A real boolean, never nil.
		sisterBank = self:IsSisterBankEnabled(),
		-- STORE-003: the discount, the STORED number (0 when unset), not the shop-gated read.
		storeDiscountPercent = tonumber(s.storeDiscountPercent) or 0,
		-- STORE-007: points per gold of donated value. Always a number (the default when unset), so
		-- a receiver can tell "the default" from "this sender predates the field". Guarded like the
		-- UI modules above: a spec that loads Guild alone must not depend on a global another spec
		-- file left behind.
		donationRate = TOGBankClassic_Donations and TOGBankClassic_Donations:Rate() or nil,
		-- BANKER-OWNER-001: who runs each bank character, always a table (empty means "nobody
		-- listed"), so a receiver can tell "cleared" from "this sender predates the field".
		bankerOwners = sanitizeBankerOwners(s.bankerOwners),
		-- XGUILD-OWNERS-001: each owner entry's own stamp (a clear keeps one), always a table, so a
		-- receiver merges entry by entry instead of replacing the table.
		bankerOwnerStamps = sanitizeOwnerStamps(s.bankerOwnerStamps, s.bankerOwners),
		-- STORE-002: the price authority, always a string ("" = none), so a receiver can tell
		-- "cleared" from "this sender predates the field".
		priceAuthority = self:GetPriceAuthority() or "",
		-- GSL-MERGE-001 (v1.7.0): the shopping list, always a table (empty means "nothing wanted"), with
		-- each entry's own stamp so a receiver merges entry by entry, and the gather window as two
		-- strings ("" = unset). Guarded like the Donations read above.
		craftList = TOGBankClassic_CraftList and TOGBankClassic_CraftList.SanitizeList(s.craftList) or nil,
		craftListStamps = TOGBankClassic_CraftList and TOGBankClassic_CraftList.SanitizeStamps(s.craftListStamps, s.craftList) or nil,
		gatherStart = TOGBankClassic_CraftList and (TOGBankClassic_CraftList.SanitizeDate(s.gatherStart) or "") or nil,
		gatherEnd = TOGBankClassic_CraftList and (TOGBankClassic_CraftList.SanitizeDate(s.gatherEnd) or "") or nil,
	}
end

--- GSL-MERGE-001: take the shopping list from a received settings payload -- the entries merged
--- entry by entry on their own stamps, the gather window field by field through `adopt` (the
--- caller's per-field stamp test). The caller has authorized the sender for the list. Returns
--- nothing; changes land in Info.settings.
local function applyCraftListFields(self, settings, adopt)
	local CL = TOGBankClassic_CraftList
	if not CL then return end
	if settings.craftList ~= nil and type(settings.craftListStamps) == "table" then
		CL:Merge(settings.craftList, settings.craftListStamps)
	end
	local start, finish = CL.SanitizeDate(settings.gatherStart), CL.SanitizeDate(settings.gatherEnd)
	if start and adopt("gatherStart", start) then self.Info.settings.gatherStart = start end
	if finish and adopt("gatherEnd", finish) then self.Info.settings.gatherEnd = finish end
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
	-- XGUILD-SETTINGS-001. The operator, 2026-09-25: "we should NOT be syncing the officer settings
	-- between sister guilds, this would allow any guild to target another guild and force it into
	-- being a sister." Every gate below passed for a sister guild's bank characters (SenderHasGbankNote
	-- reads the sister roster's note), its officers (isOfficer from its roster) and its GM (rank 0), so
	-- its request limit, shop, discount, Sister-guild bank switch and rank floor were adopted as OURS
	-- whenever its stamp was newer. From another guild the ONE thing taken is who runs that guild's
	-- own bank characters ("the banker metadata isn't syncing though"), merged entry by entry and
	-- from ANY member -- the entry stamps are its officers' writes, a plain member (the one a
	-- federation pull usually asks) holds them as well as an officer does, and MergeBankerOwners holds
	-- the sender to its own guild's bank characters. This supersedes docs/XGUILD_SYNC.md D1/D4.
	if sender and self.IsHomeMember and not self:IsHomeMember(sender) and self.GuildOf and self:GuildOf(sender) then
		if self.Info and type(settings.bankerOwnerStamps) == "table" and settings.bankerOwners ~= nil then
			if not self.Info.settings then self.Info.settings = {} end
			if self:MergeBankerOwners(sender, settings.bankerOwners, settings.bankerOwnerStamps) then
				local B = TOGBankClassic_UI_Browse
				if B and B.OnBankerOwnerChanged then B:OnBankerOwnerChanged() end
			end
			self:AdvanceOwnersStamp(settings)   -- the version is ours and is not touched
			self:SnapshotSettings()   -- SETTINGS-STALE-001: the baseline follows what is held
		end
		TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "ApplyRemoteSettings from sister-guild member %s: bank character owners only", tostring(sender))
		return
	end
	if not self:SettingsSenderAuthorized(sender) then   -- XGUILD-SETTINGS-002: home members only
		-- GSL-MERGE-001: the `[GSL]`-tagged member may write the shopping list and nothing else. Their
		-- payload's other fields (and its version) are ignored; the list's own stamps decide it.
		local CL = TOGBankClassic_CraftList
		if self.Info and CL and CL:IsGSLPlayer(sender) then
			if not self.Info.settings then self.Info.settings = {} end
			local inStamps = type(settings.stamps) == "table" and settings.stamps or {}
			local taken = {}
			applyCraftListFields(self, settings, function(key, value)
				local stamp = tonumber(inStamps[key]) or 0
				if not adoptSettingsField(self, key, stamp, value) then return false end   -- SETTINGS-TIE-001
				taken[key] = stamp
				return true
			end)
			if next(taken) then
				if type(self.Info.settings.stamps) ~= "table" then self.Info.settings.stamps = {} end
				for key, stamp in pairs(taken) do self.Info.settings.stamps[key] = stamp end
			end
			self:SnapshotSettings()
			TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "ApplyRemoteSettings from [GSL] member %s: shopping list only", tostring(sender))
			return
		end
		TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "ApplyRemoteSettings: sender %s not authorized, ignoring", tostring(sender))
		return
	end
	if not self.Info then return end
	if not self.Info.settings then self.Info.settings = {} end
	-- SETTINGS-002: a pre-004 sender (no `stamps`) carries one version for the whole payload, and
	-- only a version at least as new as the held one is applied -- a stale client's re-announcement
	-- (older) is dropped whole. A pre-002 sender carries no version and reads as 0: it can still
	-- seed a client that has never held a stamped copy, and nothing else.
	-- SETTINGS-004: a sender with `stamps` is judged FIELD BY FIELD -- each field against the stamp
	-- this client holds for it. A field the payload carries no stamp for is of unknown age and reads
	-- as 0: it can seed an empty client and displaces nothing (a re-announcement from a client that
	-- has not written since the upgrade carries exactly that).
	local incoming = tonumber(settings.version) or 0
	local held = self:SettingsVersion()
	local inStamps = type(settings.stamps) == "table" and settings.stamps or nil
	if not inStamps and incoming < held then
		TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "ApplyRemoteSettings from %s ignored: version %s is older than the held %s",
			tostring(sender), tostring(incoming), tostring(held))
		return
	end
	local adopted = {}
	--- Does the payload's `value` for `key` win (SETTINGS-TIE-001)? Records the stamp to keep when so.
	local function adopt(key, value)
		local stamp = inStamps and (tonumber(inStamps[key]) or 0) or incoming
		if not adoptSettingsField(self, key, stamp, value) then return false end
		adopted[key] = stamp
		return true
	end
	if type(settings.maxRequestPercent) == "number" and settings.maxRequestPercent >= 1 and settings.maxRequestPercent <= 100
		and adopt("maxRequestPercent", math.floor(settings.maxRequestPercent)) then
		self.Info.settings.maxRequestPercent = math.floor(settings.maxRequestPercent)
	end
	if type(settings.autoTombstoneDays) == "number" and settings.autoTombstoneDays >= 1
		and adopt("autoTombstoneDays", math.floor(settings.autoTombstoneDays)) then
		self.Info.settings.autoTombstoneDays = math.floor(settings.autoTombstoneDays)
	end
	-- CANCELREASON-001: apply synced cancel-reason config only when the sender
	-- actually carried one (older clients omit the field — don't wipe local).
	if settings.cancelReasons ~= nil then
		local cr = sanitizeCancelReasons(settings.cancelReasons)
		if adopt("cancelReasons", cr) then self.Info.settings.cancelReasons = cr end
	end
	-- HELPNOTE-001: apply synced help notes only when present (old clients omit it).
	if settings.helpNotes ~= nil then
		local hn = sanitizeHelpNotes(settings.helpNotes)
		if adopt("helpNotes", hn) then self.Info.settings.helpNotes = hn end
	end
	-- STORE-006: the open/closed sign, only when the sender carried it -- a pre-STORE client's
	-- broadcast must not reopen a shop an officer closed. Anything but `true` is closed.
	if settings.storeOpen ~= nil and adopt("storeOpen", settings.storeOpen == true) then
		self.Info.settings.storeOpen = settings.storeOpen == true
	end
	-- STORE-006: the not-for-sale list, only when carried -- an older client's broadcast must not
	-- put every item back on sale. Sanitized: integer item ids, capped.
	if settings.notForSale ~= nil then
		local nfs = sanitizeNotForSale(settings.notForSale)
		if adopt("notForSale", nfs) then self.Info.settings.notForSale = nfs end
	end
	-- SHOP-TAB-001: the shop switch, only when carried; a change repaints the Guild Bank window's
	-- tab strip on this client (the Shop tab appears or goes).
	if settings.shopEnabled ~= nil and adopt("shopEnabled", settings.shopEnabled == true) then
		local was = self:IsShopEnabled()
		self.Info.settings.shopEnabled = settings.shopEnabled == true
		if was ~= self:IsShopEnabled() then
			local B = TOGBankClassic_UI_Browse
			if B and B.OnShopSettingChanged then B:OnShopSettingChanged() end
		end
	end
	-- XGUILD-SWITCH-001: the sister-guild bank switch, only when carried; a change rebuilds the
	-- rosters on this client so the sister bankers appear or go.
	if settings.sisterBank ~= nil and adopt("sisterBank", settings.sisterBank == true) then
		local was = self:IsSisterBankEnabled()
		self.Info.settings.sisterBank = settings.sisterBank == true
		if was ~= self:IsSisterBankEnabled() then self:OnSisterBankChanged() end
	end
	-- STORE-003: the discount, only when carried and a number in 0..100; a change repaints an open
	-- Shop tab on this client.
	local pct = tonumber(settings.storeDiscountPercent)
	if pct and pct == pct and pct >= 0 and pct <= 100 and adopt("storeDiscountPercent", math.floor(pct)) then
		pct = math.floor(pct)
		if self.Info.settings.storeDiscountPercent ~= pct then
			self.Info.settings.storeDiscountPercent = pct
			local B = TOGBankClassic_UI_Browse
			if B and B.OnShopSettingChanged then B:OnShopSettingChanged() end
		end
	end
	-- STORE-007: the donation rate, only when carried and within bounds -- an older client's
	-- broadcast must not reset a rate an officer chose, and a garbage value is not a rate.
	local D = TOGBankClassic_Donations
	local rate = tonumber(settings.donationRate)
	if D and rate and rate == rate and rate >= D.RATE_MIN and rate <= D.RATE_MAX
		and adopt("donationRate", math.floor(rate * 100 + 0.5) / 100) then
		self.Info.settings.donationRate = math.floor(rate * 100 + 0.5) / 100
	end
	-- BANKER-OWNER-001: the owners, only when carried -- an older client's broadcast must not
	-- clear them. Sanitized and capped; a change repaints an open Bankers tab.
	-- XGUILD-OWNERS-001: a sender that carries per-entry stamps is MERGED entry by entry (a sister
	-- guild's entries reach us without replacing ours); a sender from before them is adopted whole on
	-- the field's stamp, as it always was -- such a client predates the federation, so it is home.
	if type(settings.bankerOwnerStamps) == "table" and settings.bankerOwners ~= nil then
		-- The FIELD's stamp still moves forward (self-audit 2026-09-16): the whole-table branch below
		-- judges a pre-stamp sender against it, and a stamp left behind let a v1.5.1 officer's
		-- re-announcement, stamped after the held one but before this payload, replace the merged
		-- table and wipe every sister guild's entry. OWNERS-STAMP-001: the same method the sister
		-- branch above uses, so the two cannot drift.
		self:AdvanceOwnersStamp(settings)
		if self:MergeBankerOwners(sender, settings.bankerOwners, settings.bankerOwnerStamps) then
			local B = TOGBankClassic_UI_Browse
			if B and B.OnBankerOwnerChanged then B:OnBankerOwnerChanged() end
		end
	elseif settings.bankerOwners ~= nil then
		local owners = sanitizeBankerOwners(settings.bankerOwners)
		if adopt("bankerOwners", owners) then
			self.Info.settings.bankerOwners = owners
			local B = TOGBankClassic_UI_Browse
			if B and B.OnBankerOwnerChanged then B:OnBankerOwnerChanged() end
		end
	end
	-- STORE-002: the price authority, only when carried (a string; "" clears) -- an older client's
	-- broadcast must not unset it. Normalised and clamped; a change re-reads the held list against
	-- the new name, and a client that IS the new authority publishes.
	local authority = type(settings.priceAuthority) == "string" and settings.priceAuthority or nil
	if authority and authority ~= "" then authority = (self:NormalizeName(authority) or ""):sub(1, PRICE_AUTHORITY_MAX_LEN) end
	if authority and adopt("priceAuthority", authority) then
		if (self:GetPriceAuthority() or "") ~= authority then
			self.Info.settings.priceAuthority = authority
			if TOGBankClassic_PriceList then TOGBankClassic_PriceList:OnAuthorityChanged() end
		end
	end
	-- GSL-MERGE-001: the shopping list, entry by entry, and the gather window, field by field.
	applyCraftListFields(self, settings, adopt)
	-- SETTINGS-003: the officer rank floor, from the GM ALONE -- rankIndex 0 is the one rank every
	-- receiver can judge for itself, and this field is what lets it judge the rest.
	local floor = tonumber(settings.officerRankFloor)
	if floor and floor >= 0 and floor == math.floor(floor) and self:SenderIsGM(sender) and adopt("officerRankFloor", floor) then
		self.Info.settings.officerRankFloor = floor
	end
	-- The version moves even when no field above was adopted, DELIBERATELY: it names the newest write
	-- this client has heard, and the stamps decide each value. Every field is adoptable from any
	-- authorized sender except the officer rank floor (GM only) -- which is why SettingsCanon leaves
	-- the floor out (SETTINGS-CANON-002): otherwise this line makes "equal version, different values".
	-- SETTINGS-TIE-001: it moves AFTER the fields are judged, never before (see adoptSettingsField).
	if incoming > held then self.Info.settings.version = incoming end
	-- SETTINGS-004: keep the stamps of what was adopted, and let the next write diff against this.
	if next(adopted) then
		if type(self.Info.settings.stamps) ~= "table" then self.Info.settings.stamps = {} end
		for key, stamp in pairs(adopted) do self.Info.settings.stamps[key] = stamp end
	end
	-- SETTINGS-STALE-001: the baseline is what this client holds NOW, not nothing -- an empty one
	-- made the next write stamp every field, stale ones included.
	self:SnapshotSettings()
	TOGBankClassic_Output:Debug("PROTOCOL", "SETTINGS", "ApplyRemoteSettings from %s: maxRequestPercent=%s autoTombstoneDays=%s cancelCustom=%d",
		tostring(sender), tostring(self.Info.settings.maxRequestPercent), tostring(self.Info.settings.autoTombstoneDays),
		(self.Info.settings.cancelReasons and self.Info.settings.cancelReasons.custom and #self.Info.settings.cancelReasons.custom) or 0)
end

-- returns true if the given normalized sender has a public or officer note containing 'gbank'.
-- GSL-BANK-001: deliberately `gbank` ONLY, not noteBankRole. This gates settings and donation
-- authority, and a [GSL] character is a banker for the shopping list's stock, not a guild authority.
function TOGBankClassic_Guild:SenderHasGbankNote(sender)
	if not sender then
		return false
	end
	-- XGUILD-SYNC-001 (D3/D4): a sister guild's banker is one by the note its roster carries.
	-- Read from memberRoster, which _AddSisterMembers filled from that note; a stub entry (an
	-- unauthenticated sighting) has no guildKey and never answers here. isBank is also true for a
	-- [GSL]-only note, so the note itself is re-read for `gbank`.
	local m = self.memberRoster and self.memberRoster[sender]
	if m and m.guildKey and not m.isStub and m.isBank and tostring(m.note or ""):find("gbank", 1, true) then
		return true
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

	-- XGUILD-BANKERS-001 (the operator, 2026-09-16: "i have the sister guild set up, and i have the
	-- sister guild in guild roster with the info. should i not have the list of their bankers, and
	-- should they not be populating in the bankers tab?"). A sister guild's bank characters reach
	-- memberRoster (and so GetBanks, the Bankers tab and every banker list) only when memberRoster is
	-- REBUILT, and nothing rebuilt it when a sister roster arrived: the library files the FIRST copy of
	-- a sister roster as a baseline and fires no OnMemberJoined per member (SetSisterRoster,
	-- LibGuildRoster-1.0.lua:3132-3134), a pull that only changes notes fires no join either, and the
	-- persisted copy restored at login lands whenever it lands. So a roster that came after TOGBank's
	-- login rebuild -- the operator's, 290 members with their gbank notes saved -- contributed no
	-- bankers until relog happened to order things the other way. Every signal the library gives for a
	-- sister roster (its own window repaints on the same three, :7029) now rebuilds, when the sister
	-- bankers it names actually changed.
	local function onSisterRosterChanged(_, key)
		local G = TOGBankClassic_Guild
		if not G:IsSisterBankEnabled() then return end
		if type(key) == "string" and lib.GetHomeGuildKey and key == lib:GetHomeGuildKey() then return end
		local names = table.concat(G:_SisterBankers(), ",")
		if names == G._sisterBankersSeen then return end
		G._sisterBankersSeen = names
		TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "Sister roster changed (%s) - rebuilding the banker roster", tostring(key))
		G:_RefreshFromRosterLib()
		G:InvalidateBanksCache()
		G:RebuildBankerRoster()
		if G.RefreshRequestsUI then G:RefreshRequestsUI() end
		local B = TOGBankClassic_UI_Browse
		if B and B.Refresh then B:Refresh() end
	end
	lib.RegisterCallback(self, "OnSisterRosterUpdated", onSisterRosterChanged)
	lib.RegisterCallback(self, "OnRosterHashChanged", onSisterRosterChanged)
	lib.RegisterCallback(self, "OnSisterConfigChanged", function() onSisterRosterChanged(nil, nil) end)

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

	-- XGUILD-SYNC-001: the "spoke TOGBank to us" stamps survive the rebuild, or every refresh
	-- would forget which sister member FederationPeer should prefer.
	local spoke = {}
	for n, m in pairs(self.memberRoster) do spoke[n] = m.spokeAt end

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
			local isBank, viewOnly, gsl = noteBankRole(note, officernote)   -- GSL-BANK-001
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
				isBank      = isBank,
				-- VIEWBANK-001: the view-only marker is only meaningful on a banker.
				viewOnly    = viewOnly,
				gsl         = gsl,
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

	onlineCount = onlineCount + self:_AddSisterMembers(lib, spoke)
	return onlineCount, #names
end

--- XGUILD-SYNC-001 (docs/XGUILD_SYNC.md 4.1): the members of every listed sister guild join
--- memberRoster with `guildKey` set, so IsPlayerOnline / IsBank / IsViewOnlyBank / the labels
--- answer for them. A sister member is ONLINE when the library has a fresh sighting of them
--- (GetOnlineMembersScoped: a presence stamp inside its TTL); a banker when its public note --
--- `member.note`, carried from LibGuildRoster MINOR 19 (LIBREQ-GR-002) and feature-detected, so an
--- older provider's roster has none -- says so; an officer
--- only when the library marks one (it does not today, so never). A home member is never
--- overwritten: home wins, as the library's own IsInAnyRoster rules. Returns how many sister
--- members are online. Feature-detected on the cross-guild methods; an older library adds none.
function TOGBankClassic_Guild:_AddSisterMembers(lib, spoke)
	lib = lib or RosterLib()
	spoke = spoke or {}
	if not (lib and lib.GetSisterGuildKeys and lib.GetRoster and lib.GetOnlineMembersScoped) then return 0 end
	local homeKey = lib.GetHomeGuildKey and lib:GetHomeGuildKey() or nil
	local online = 0
	for _, key in ipairs(self:SisterGuildKeys(lib)) do   -- XGUILD-SWITCH-001: none while off
		local roster = key ~= homeKey and lib:GetRoster(key) or nil
		if roster then
			local seen = {}
			for _, n in ipairs(lib:GetOnlineMembersScoped(key) or {}) do seen[n] = true end
			for name, m in pairs(roster) do
				local norm = self:NormalizeName(name)
				if norm and not self.memberRoster[norm] then
					local note = tostring(m.note or "")
					local isBank, viewOnly, gsl = noteBankRole(note, "")   -- GSL-BANK-001
					-- XGUILD-BOUNCE-001: a sighting the server has since contradicted is not online.
					local isOnline = seen[norm] == true and self:SisterSightingHolds(lib, key, norm)
					self.memberRoster[norm] = {
						name        = norm,
						class       = m.class,
						level       = m.level or 1,
						rankIndex   = m.rankIndex,
						rankName    = m.rank,
						isOnline    = isOnline,
						isOfficer   = m.isOfficer == true,
						isBank      = isBank,
						viewOnly    = viewOnly,
						gsl         = gsl,
						note        = isBank and note or nil,
						guildKey    = key,
						spokeAt     = spoke[norm],
						lastUpdated = GetServerTime(),
					}
					if isOnline then
						self.onlineMembers[norm] = true
						online = online + 1
					end
				end
			end
		end
	end
	return online
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
		-- SETTINGS-003: the GM's client publishes the officer rank floor it can read; nobody else's
		-- does anything here.
		self:PublishOfficerRankFloor()
		-- GSL-MERGE-001 step 5: the role is readable now, so a writer can bring GuildShoppingList's list over.
		if TOGBankClassic_CraftList and TOGBankClassic_CraftList.ImportGSL then TOGBankClassic_CraftList:ImportGSL() end
		-- SHARE-BTN-LIVE-001: banker status may have just arrived with a window open.
		if TOGBankClassic_UI and TOGBankClassic_UI.SyncShareButtons then TOGBankClassic_UI:SyncShareButtons() end
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
	-- (This said Classic Era has no per-rank permission API; C_GuildInfo.GuildControlGetRankFlags
	-- exists there, but is read on the GM's client only -- SETTINGS-003 -- and reaches everyone
	-- else as the published floor SenderIsOfficer unions with this threshold.)
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
				-- GSL-BANK-001: the one rule (gbank, [GSL], view-only); VIEWBANK-001 inside it.
				local isBank, viewOnly, gsl = noteBankRole(note, officernote)
				-- Store full member data
				self.memberRoster[normalized] = {
					name = normalized,
					class = classFileName,
					level = level or 1,
					rankIndex = rankIndex,
					rankName = rankName,
					isOnline = isOnline or false,
					isOfficer = isOfficer,
					isBank = isBank,
					viewOnly = viewOnly,
					gsl = gsl,
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
	self:PublishOfficerRankFloor()               -- SETTINGS-003
	if TOGBankClassic_CraftList and TOGBankClassic_CraftList.ImportGSL then TOGBankClassic_CraftList:ImportGSL() end   -- GSL-MERGE-001 step 5
	-- SHARE-BTN-LIVE-001: banker status may have just arrived with a window open.
	if TOGBankClassic_UI and TOGBankClassic_UI.SyncShareButtons then TOGBankClassic_UI:SyncShareButtons() end
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
			-- XGUILD-SYNC-001: a TOGBank message is proof the member RUNS TOGBank -- the stamp
			-- FederationPeer prefers over the library's sighting of any addon message. And for a
			-- SISTER member the library is told too: its presence is stamped only by its own pull
			-- traffic, and FederationPeer draws its candidates from that presence, so a sister
			-- member who spoke to us would otherwise not be one until the library's next pull.
			-- XGUILD-SYNC-001 step 7: a nudge heard on GreenWall's bridge is a TOGBank message from
			-- them too (Modules/GreenWall.lua), and leaves the same sighting.
			if source == "addon-message-received" or source == "greenwall-nudge" then
				local m = self.memberRoster[normalized]
				m.spokeAt = GetServerTime()
				-- XGUILD-BOUNCE-001: they spoke to us -- whatever the server said earlier is stale.
				if self.sisterBounced then self.sisterBounced[normalized] = nil end
				local lib = m.guildKey and RosterLib()
				if lib and lib.MarkOnline then lib:MarkOnline(m.guildKey, { normalized }) end
				-- XGUILD-PEER-001: and a sister guild nobody has asked yet is asked now.
				if m.guildKey and not m.isStub then self:OnFederationPeerProven(normalized) end
			end
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
				-- XGUILD-BOUNCE-001: for a SISTER member this flag is not what IsPlayerOnline reads
				-- (the library's sighting is); the bounce has to outrank that sighting, and an ask
				-- out to them has to move to someone else.
				if memberData.guildKey and not memberData.isStub then self:OnSisterMemberBounced(cachedName, memberData.guildKey) end
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

	-- XGUILD-INVENTORY-001: a SISTER guild's member is online by the library's presence stamp, read
	-- NOW. memberRoster copies that stamp only when it is rebuilt, and the stamps that matter arrive
	-- between rebuilds (the library's pull answer, a /who, a relay's sightings): FederationPeer picked
	-- the member the library had just seen, and SendWhisper then refused it as offline off the stale
	-- copy -- so the sister guild's bank was never asked for. Found by Tests/xguilde2e_spec.lua.
	local entry = self.memberRoster and self.memberRoster[norm]
	if lib and entry and entry.guildKey and not entry.isStub and lib.GetOnlineMembersScoped and self:IsSisterBankEnabled() then
		for _, name in ipairs(lib:GetOnlineMembersScoped(entry.guildKey) or {}) do
			-- XGUILD-BOUNCE-001: unless the server has said otherwise since that sighting.
			if name == norm or self:NormalizeName(name) == norm then return self:SisterSightingHolds(lib, entry.guildKey, norm) end
		end
		return false
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
-- `ReconstructItemLink` (SINGULAR) went too, in LINK-AUDIT-001 step 1 (docs/LINK_AUDIT.md 3.4): it
-- built a WHITE link from a `row.ItemString` no writer produces any more, else GetItemInfo's base
-- link, suffix dropped. `UI:DrawItem` asks `Resolve.link` on the row's own id/suffix/enchant instead.

-- `ReconstructItemLinks` (PLURAL) was deleted here along with `ReceiveAltData`, its only caller.
-- It queued every link-less item from a received LEGACY payload for async link reconstruction --
-- work that exists only because that format shipped links in the first place. V2 sends integers and
-- the link is built from LibItemDB on arrival, so there is nothing to reconstruct in a batch.

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
local function CreateOnChunkSentCallback(altName)
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
				"send to guild for %s was refused by the client after retries (%s) - peers may hold stale data",
				tostring(altName), DescribeSendResult(sendResult))
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

			-- LIBREQ-DS-008: the P2P send-slot release that followed here (FINDING 28's once-per-send
			-- guard) went with its only requester-bearing caller; the manual GUILD share is the one
			-- send left through this callback and takes no slot. A whispered reply's slot is
			-- released by Inventory/Sync on the host's own completion.

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
			local onSent = CreateOnChunkSentCallback(norm)
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
		TOGBankClassic_Core:SendCommMessage("togbank-hl", hlData, "GUILD", nil, "BULK")
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
		TOGBankClassic_Core:SendCommMessage("togbank-hl", hlData, "GUILD", nil, "NORMAL")
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
-- REQSYNC-008 said GuildControlGetRankFlags does not exist in Classic Era; the BARE global does
-- not, C_GuildInfo.GuildControlGetRankFlags does (SETTINGS-003 above) -- but it is read on the
-- GM's client only, and what it found reaches here as the published `officerRankFloor`.
-- SETTINGS-003: with a floor published, any home-guild member at or above it is an officer, and
-- the cache-time threshold (a lower bound from the LOCAL player's rank) still counts -- a union,
-- since both are sound and the floor is absent until the GM has logged in on this build.
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
	if member.isOfficer == true then return true end
	local floor = self:OfficerRankFloor()
	local real = self:RosterEntry(player)   -- a stub has no rank to judge
	return floor ~= nil and real ~= nil and real.guildKey == nil
		and type(real.rankIndex) == "number" and real.rankIndex <= floor
end

