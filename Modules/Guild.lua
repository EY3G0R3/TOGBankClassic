
TOGBankClassic_Guild = {}

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
TOGBankClassic_Guild.MAX_PENDING_SENDS = 3
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

function GetPlayerWithNormalizedRealm(name)
	if string.match(name, "(.*)%-(.*)") then
		return name
	end
	return name .. "-" .. GetNormalizedRealmName()
end

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
	-- If helper exists, use it
	if GetPlayerWithNormalizedRealm then
		return GetPlayerWithNormalizedRealm(normalized)
	end
	-- Fallback: append current realm
	return normalized .. "-" .. GetNormalizedRealmName()
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
						self.latestBankerHashes[altName] = {
							hash = alt.inventoryHash or 0,
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
-- - remove per-alt entries that have badly shaped bank/bags item lists
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
		else
			-- Ensure version is present, but malformed nested fields are problematic
			if alt.items then
				-- alt.items should be an array or a map of items with ID fields; remove any empty entries
				for k, v in pairs(alt.items) do
					if not v or type(v) ~= "table" or not v.ID then
						alt.items[k] = nil
					end
				end
			end
			-- If after cleaning the alt has no meaningful fields (no version, no money, no items), remove it
			local hasData = false
			if alt.version then
				hasData = true
			end
			if alt.money then
				hasData = true
			end
			if alt.items and next(alt.items) then
				hasData = true
			end
			if not hasData then
				remove = true
			end
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

	if oldRoster ~= newRoster then
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
			self.Info.alts[norm] = {
				name = norm,
				version = 0,
				money = 0,
				inventoryHash = 0,
				items = {},
				mail = { items = {}, slots = { count = 0, total = 0 }, lastScan = 0, version = 0 },
				mailHash = 0,
			}
			self:EnsureLegacyFields(self.Info.alts[norm])
			TOGBankClassic_Output:Debug("ROSTER", "REFRESH", "Added missing banker stub data for %s", norm)
		end
	end

	-- ROSTER-002: Remove zero-data stubs for alts no longer in the banker roster.
	-- RebuildBankerRoster() creates stubs when someone joins the banker list but never
	-- removed them when they left, causing permanent "HLR pending" phantom entries.
	-- Only remove stubs that have never received real data (version==0, inventoryHash==0,
	-- no items) — non-zero alts are never touched regardless of roster status.
	local removedStubs = 0
	for altName, alt in pairs(self.Info.alts) do
		if not newBanksLookup[altName] then
			local isZeroStub = (
				type(alt) == "table"
				and (not alt.version or alt.version == 0)
				and (not alt.inventoryHash or alt.inventoryHash == 0)
				and (not alt.mailHash or alt.mailHash == 0)
				and (not alt.items or #alt.items == 0)
				and (not alt.bank or not alt.bank.items or #alt.bank.items == 0)
				and (not alt.mail or not alt.mail.items or #alt.mail.items == 0)
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
	if alt.items and #alt.items > 0 then
		return true
	end
	return false
end

--- Does this client hold any inventory for `altName`?
---
--- THE NEGOTIATION LAYER'S GATE, and it decides far more than its name suggests: ~10 call sites use
--- it to answer "may I offer this alt's data", "should I respond to this query", "did the peer
--- actually deliver", and "how many bankers do I have". A false answer does not merely hide items --
--- it makes the client tell the guild it has nothing, so it never offers data and keeps re-asking.
---
--- INV2: it must therefore consult the V2 STORE as well as the legacy record. A client that
--- received a tuple payload has its data in V2 and nothing in `alt.items`; before this it reported
--- itself empty, re-requested forever, and never passed the data on -- the "half implemented" state
--- where the data layer had moved and the negotiation layer had not.
function TOGBankClassic_Guild:HasAltContent(alt, altName)
	-- V2 content counts even when the legacy record is an empty stub, which is exactly what an alt
	-- populated purely over the tuple wire looks like. Checked first and independently of `alt`,
	-- because that stub may be a table with nothing in it OR absent entirely.
	if TOGBankClassic_Inventory_Store and self.Info and self.Info.name and altName then
		local norm = self:NormalizeName(altName) or altName
		if #TOGBankClassic_Inventory_Store:GetAltRecords(self.Info.name, norm) > 0 then
			TOGBankClassic_Output:Debug("DELTA", "VALIDATE",
				"[CONTENT-CHECK] %s: satisfied by the V2 store", norm)
			return true
		end
	end

	if not alt or type(alt) ~= "table" then
		TOGBankClassic_Output:Debug("DELTA", "VALIDATE", "[CONTENT-CHECK] %s: not a table", altName or (alt and alt.name) or "unknown")
		return false
	end

	local hasItems = alt.items and next(alt.items)
	local hasBankItems = alt.bank and alt.bank.items and next(alt.bank.items)
	local hasBagsItems = alt.bags and alt.bags.items and next(alt.bags.items)
	local hasMailItems = alt.mail and alt.mail.items and next(alt.mail.items)

	local result = hasItems or hasBankItems or hasBagsItems or hasMailItems

	TOGBankClassic_Output:Debug("DELTA", "VALIDATE",
		"[CONTENT-CHECK] %s: items=%s, bank=%s, bags=%s, mail=%s => %s",
		altName or alt.name or "unknown",
		tostring(hasItems and "Y" or "N"),
		tostring(hasBankItems and "Y" or "N"),
		tostring(hasBagsItems and "Y" or "N"),
		tostring(hasMailItems and "Y" or "N"),
		tostring(result))

	return result
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

--- INV2 step 7a: THE one place the inventoryV2 switch decides where item rows come from.
---
--- Every UI module used to open-code "use `alt.items` if it has anything, otherwise aggregate
--- bank + bags + mail" -- six sites across three files, each a place the switch would have to be
--- repeated and each free to drift. INVENTORY_V2.md 7.1 anticipated this: the V2 store exposes a
--- view in the SAME shape the UI already consumes, so the wiring is one accessor rather than six
--- conditionals.
---
--- Returns an ARRAY of item rows, always -- never nil, so callers need no guard. With
--- `inventoryV2` on the rows are materialised from tuples (cached per alt, dropped on write);
--- with it off this is exactly the legacy behaviour it replaced.
--- @param altName string  normalized alt name
--- @return table array of { ID = , Count = , Link = , Info = }
function TOGBankClassic_Guild:GetAltItems(altName)
	local info = self.Info
	if not info or not info.alts then return {} end
	local alt = info.alts[altName]

	if TOGBankClassic_Switches and TOGBankClassic_Switches:IsEnabled("inventoryV2")
		and TOGBankClassic_Inventory_Store and info.name then
		-- Two reasons to fall through to the legacy record, and they are different failures:
		--
		-- 1. The V2 store has never scanned this alt (empty view). During the dualWrite period a
		--    member's own character is in V2 but everyone ELSE's data still arrives over the legacy
		--    wire, so returning empty would blank most of the guild's inventory the moment the
		--    switch was flipped. Once sendV2Wire is the default this stops being reachable.
		--
		-- 2. INV2-STALE-001 -- the V2 record exists but was built from FEWER sources than today's
		--    scan reads. `#view > 0` cannot tell that from a complete record, so before this gate a
		--    banker scanned before INV2-MAIL-001 showed its bags+bank total (68) in place of the
		--    legacy record's bags+bank+mail (71), and kept showing it until that specific character
		--    rescanned with a mailbox visit. Unlike (1) this fallback does NOT stop being reachable
		--    when sendV2Wire lands, so the stamp has to be checked rather than assumed.
		if TOGBankClassic_Inventory_Store:IsAltComplete(info.name, altName) then
			local view = TOGBankClassic_Inventory_Store:GetAltView(info.name, altName)
			if #view > 0 then return view end
		end
	end

	if not alt then return {} end

	local items = {}
	if alt.items and next(alt.items) ~= nil then
		for _, item in pairs(alt.items) do items[#items + 1] = item end
		return items
	end

	-- Pre-SYNC-006 records have no aggregate; rebuild it from the three sources.
	local aggregated = TOGBankClassic_Item:Aggregate((alt.bank and alt.bank.items) or {},
		(alt.bags and alt.bags.items) or {})
	aggregated = TOGBankClassic_Item:Aggregate(aggregated, (alt.mail and alt.mail.items) or {})
	for _, item in pairs(aggregated) do items[#items + 1] = item end
	return items
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
--- This asks the question the caller actually has -- a total for ONE item -- so no branch needs to
--- materialise a list. The V2 branch reads the cached view without copying it; the legacy branch
--- walks `alt.items` in place. Same switch semantics as GetAltItems, deliberately: the two must not
--- disagree about which store answers, which is the whole point of 7a.
---
--- WHAT THIS DOES NOT FIX, stated so it is not mistaken for the remedy: audit finding 13
--- (`PERF-022`) is that the hover is O(bankers x items) because every banker is scanned linearly.
--- That needs an itemID -> {banker,count} index rebuilt when alt data changes, and the hard part is
--- INVALIDATION -- there are writers in Bank:Scan, the V2 receive, ApplyDelta and ReceiveAltData,
--- and an index that misses one goes silently stale, which is worse than the scan. Still open.
--- @param altName string  normalized alt name
--- @param itemID number
--- @return number
function TOGBankClassic_Guild:GetAltItemTotal(altName, itemID)
	itemID = tonumber(itemID)
	if not itemID then return 0 end

	local info = self.Info
	if not info or not info.alts then return 0 end

	local total = 0

	if TOGBankClassic_Switches and TOGBankClassic_Switches:IsEnabled("inventoryV2")
		and TOGBankClassic_Inventory_Store and info.name
		and TOGBankClassic_Inventory_Store:IsAltComplete(info.name, altName) then
		local view = TOGBankClassic_Inventory_Store:GetAltView(info.name, altName)
		if #view > 0 then
			for _, item in ipairs(view) do
				if item.ID == itemID then total = total + (item.Count or 1) end
			end
			return total
		end
	end

	local alt = info.alts[altName]
	if not alt then return 0 end

	if alt.items and next(alt.items) ~= nil then
		for _, item in pairs(alt.items) do
			if item.ID == itemID then total = total + (item.Count or 1) end
		end
		return total
	end

	-- Pre-SYNC-006 records have no aggregate. Summing the three sources directly is equivalent to
	-- aggregating and then filtering, because Item:Aggregate only ever merges rows of the same
	-- item -- and it avoids building the aggregate to read one number out of it.
	for _, source in ipairs({ alt.bank, alt.bags, alt.mail }) do
		for _, item in pairs((source and source.items) or {}) do
			if item.ID == itemID then total = total + (item.Count or 1) end
		end
	end
	return total
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
			list[norm] = {
				hash = hash,
				hashV2 = (alt and alt.inventoryHashV2) or nil,
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
	local theirV2 = summary.hashV2
	local ourV2   = localAlt and localAlt.inventoryHashV2
	local inventoryHashMatches
	if theirV2 ~= nil and ourV2 ~= nil then
		inventoryHashMatches = (theirV2 == ourV2)
	else
		inventoryHashMatches = (summary.hash ~= nil and summary.hash == localHash)
	end

	local mailHashMatches = (summary.mailHash ~= nil and summary.mailHash == localMailHash)
	return (inventoryHashMatches and mailHashMatches), localHash, localMailHash
end

-- Returns true if the given normalized alt name is sync-pending (matches the HLR pending
-- definition used by /togbank hashdebug): hash mismatch, no local data, or hash matches
-- but content is missing.  Returns false if fully in sync or not in the hash cache.
function TOGBankClassic_Guild:IsAltSyncPending(norm)
	local bankerList = self.latestBankerHashes
	if not bankerList then return false end
	local summary = bankerList[norm]
	if not summary then return false end

	local localAlts = self.Info and self.Info.alts or {}
	local localAlt  = localAlts[norm]
	local hashesMatch, localHash = self:HashesAgreeWith(localAlt, summary)

	if localAlt and localHash ~= 0 and hashesMatch then
		-- Hashes match but content may still be missing
		return not self:HasAltContent(localAlt, norm)
	end
	return true  -- hash mismatch or no local data
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
			-- HASH-REV-002: BOTH inventory and mail hashes must match. See HashesAgreeWith.
			local hashesMatch, localHash = self:HashesAgreeWith(localAlt, summary)

			if localAlt and localHash ~= 0 and hashesMatch then
				-- Hash matches, but check if we have actual content
				if not self:HasAltContent(localAlt, altName) then
					-- Hash matches but no content - treat as pending (need to request)
					table.insert(matchedNoContent, altName)
					table.insert(pending, altName)
				else
					-- Hash matches and we have content - truly matched
					matched = matched + 1
				end
			else
				-- Hash mismatch or no local data - pending
				table.insert(pending, altName)
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
		if self:IsBank(member) and self:IsPlayerOnline(member) and member ~= myPlayer then
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
						self:BroadcastP2PRequest(norm, localHash, updatedAt, nil)
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

function TOGBankClassic_Guild:BroadcastP2PRequest(altName, expectedHash, expectedUpdatedAt, bankerSender)
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

	-- Only skip broadcast if we have matching hash AND content
	local existing = self.Info and self.Info.alts and self.Info.alts[norm]
	local existingHash = existing and existing.inventoryHash or 0

	if existingHash == expectedHash and existing and self:HasAltContent(existing, norm) then
		TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "PERF-005: Skipping P2P broadcast for %s (hash matches and have content)", altName)
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
		local pending = self.pendingP2PRequests and self.pendingP2PRequests[norm]
		if pending then
			self.pendingP2PRequests[norm] = nil
			-- PERF-006: Clear pendingAltRequests to allow banker fallback
			if self.pendingAltRequests then
				self.pendingAltRequests[norm] = nil
			end

			-- FIX: Clear expectedHashes to prevent memory leak
			if self.expectedHashes then
				self.expectedHashes[norm] = nil
			end
			if self.expectedHashUpdatedAt then
				self.expectedHashUpdatedAt[norm] = nil
			end

			-- Check if we have any way to get this data
			local banker = pending.banker
			local bankerOnline = banker and self:IsPlayerOnline(banker)
			if bankerOnline then
				TOGBankClassic_Output:Debug("P2P", "DISPATCH", "PERF-005: No P2P response for %s after %ds timeout", altName, timeout)
			else
				TOGBankClassic_Output:Debug("P2P", "DISPATCH", "PERF-005: No P2P response for %s after %ds timeout (no banker online)", altName, timeout)
			end
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
function TOGBankClassic_Guild.EncodeVersion(raw)
	if type(raw) ~= "string" then return 0 end
	local major, minor, patch = raw:match("^(%d+)%.(%d+)%.(%d+)")
	if not major then
		-- Two-component ("1.4") and bare ("dev", "@project-version@") forms. A dev build is 0
		-- rather than a guess: an invented number would rank a working copy against real peers.
		major, minor = raw:match("^(%d+)%.(%d+)")
		if not major then return 0 end
		patch = 0
	end
	return (tonumber(major) * 1000000) + (tonumber(minor) * 1000) + tonumber(patch)
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
						-- HASH-REV-001 shape 3 of 5.
						data.alts[k] = {
							version = v.version,
							hash = v.inventoryHash,
							hashV2 = v.inventoryHashV2 or nil,
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
	-- Invalidate only; RebuildBankerRoster is expensive and GUILD_ROSTER_UPDATE will drive it.
	local function onMembershipChanged(_, name)
		TOGBankClassic_Output:Debug("ROSTER", "REFRESH",
			"Roster membership changed (%s) - invalidating banker cache", tostring(name))
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

function TOGBankClassic_Guild:RefreshOnlineCache()
	local startTime = debugprofilestop()
	self.memberRoster = self.memberRoster or {}
	self.onlineMembers = self.onlineMembers or {}

	-- ROSTER-003: prefer the library. Falls through to the legacy scan when it can't answer.
	local libOnline, libTotal = self:_RefreshFromRosterLib()
	if libOnline then
		local libDuration = debugprofilestop() - startTime
		TOGBankClassic_Performance:RecordOperation("RefreshOnlineCache", libDuration)
		TOGBankClassic_Output:Debug("CACHE", "REFRESH",
			"Refreshed roster from LibGuildRoster: %d total, %d online (%.1f ms)",
			libTotal, libOnline, libDuration)
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

-- Compute minimal state summary for pull-based protocol
-- Returns {[itemID] = quantity} - no Links, bags, slots, or metadata
-- ~800 bytes for 100 items vs 5-7KB for full data
function TOGBankClassic_Guild:ComputeStateSummary(name)
	if not name then
		return nil
	end

	local norm = self:NormalizeName(name)

	-- If we don't have data for this alt, return a "no data" summary
	if not self.Info or not self.Info.alts or not self.Info.alts[norm] then
		return {
			version = 0,
			hash = nil,
			money = 0,
			bank = {},
			bags = {},
			mail = {}
		}
	end

	local alt = self.Info.alts[norm]
	local summary = {
		version = alt.version or 0,
		hash = alt.inventoryHash or nil,
		updatedAt = alt.inventoryUpdatedAt or alt.version or 0,
		mailHash = alt.mailHash or 0,  -- MAIL-SYNC: Include mail hash for mail change detection
		money = alt.money or 0,
		-- DELTA-020: Send minimal item structures (ID+Count only, no Links) for accurate delta baseline
		bank = {},
		bags = {},
		mail = {}
	}

	-- Extract minimal item data (ID and Count only, no Links) for delta computation baseline
	local function extractMinimalItems(items)
		local minimal = {}
		if not items then return minimal end
		for _, item in ipairs(items) do
			if item and item.ID then
				table.insert(minimal, {
					ID = item.ID,
					Count = item.Count or 1
				})
			end
		end
		return minimal
	end

	-- Send bank/bags/mail structures separately so sender can compute accurate delta
	if alt.bank and alt.bank.items then
		summary.bank = extractMinimalItems(alt.bank.items)
	end
	if alt.bags and alt.bags.items then
		summary.bags = extractMinimalItems(alt.bags.items)
	end
	if alt.mail and alt.mail.items then
		summary.mail = extractMinimalItems(alt.mail.items)
	end

	return summary
end

-- Send state summary to responder (Step 4 of pull-based flow)
function TOGBankClassic_Guild:SendStateSummary(name, target, forceFullParam)
	TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "SendStateSummary called: name=%s, target=%s, forceFull=%s", tostring(name), tostring(target), tostring(forceFullParam))
	if not name or not target then
		TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "SendStateSummary early return: missing params")
		return
	end

	local summary = self:ComputeStateSummary(name)
	if not summary then
		TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "SendStateSummary: No data for %s", tostring(name))
		return
	end

	local norm = self:NormalizeName(name)
	local forceFull = forceFullParam or (self.forceFullRequests and norm and self.forceFullRequests[norm])
	local localAlt = self.Info and self.Info.alts and norm and self.Info.alts[norm]
	local hasContent = localAlt and self:HasAltContent(localAlt, norm) or false
	if forceFull or not hasContent then
		-- PERF-006: Set hash=0 (not nil) to force full data from responder
		-- If we set hash=nil and responder also has hash=nil (old code), they'll match and send NO-CHANGE
		summary.hash = 0
		summary.version = 0
		TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "SendStateSummary: forcing full data for %s (forceFull=%s, hasContent=%s)", tostring(name), tostring(forceFull and true or false), tostring(hasContent))
		if self.forceFullRequests and norm then
			self.forceFullRequests[norm] = nil
		end
	end

	local message = {
		type = "state-summary",
		name = name,
		summary = summary,
	}

	local data = TOGBankClassic_Core:SerializeWithChecksum(message)
	TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Sending state summary via WHISPER to %s for %s (%d bytes, hash=%s)", target, name, #data, tostring(summary.hash))
	if not TOGBankClassic_Core:SendWhisper("togbank-state", data, target, "NORMAL") then
		return
	end

	-- DELTA-020: Count total items from bank/bags/mail structures
	local itemCount = 0
	if summary.bank then itemCount = itemCount + #summary.bank end
	if summary.bags then itemCount = itemCount + #summary.bags end
	if summary.mail then itemCount = itemCount + #summary.mail end
	TOGBankClassic_Output:Debug(
		"P2P",
		"HANDSHAKE",
		"Sent state summary for %s to %s (%d total items: bank=%d, bags=%d, mail=%d, %d bytes)",
		name,
		target,
		itemCount,
		summary.bank and #summary.bank or 0,
		summary.bags and #summary.bags or 0,
		summary.mail and #summary.mail or 0,
		string.len(data)
	)
end

-- Respond to state summary (Step 5 & 6 of pull-based flow)
-- Compare requester's state with our data and send appropriate response
function TOGBankClassic_Guild:RespondToStateSummary(name, summary, requester)
	TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "RespondToStateSummary called: name=%s, requester=%s", tostring(name), tostring(requester))
	if not name or not summary or not requester then
		TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "RespondToStateSummary early return: missing params")
		return
	end

	local norm = self:NormalizeName(name)
	if not self.Info or not self.Info.alts or not self.Info.alts[norm] then
		TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Cannot respond to state summary for %s (no data)", norm)
		return
	end

	local currentAlt = self.Info.alts[norm]
	if currentAlt and not currentAlt.inventoryUpdatedAt and currentAlt.version then
		currentAlt.inventoryUpdatedAt = currentAlt.version
	end
	local requesterVersion = summary.version or 0
	local currentVersion = currentAlt.version or 0

	-- In delta mode, compare HASHES not versions
	local requesterHash = summary.hash or nil
	local currentHash = currentAlt.inventoryHash or nil

	-- Extract mail hashes for comparison
	local requesterMailHash = summary.mailHash or 0
	local currentMailHash = currentAlt.mailHash or 0

	-- DELTA-020: Extract requester's baseline from state summary for accurate delta computation
	local requesterBaseline = {
		bank = summary.bank or {},
		bags = summary.bags or {},
		mail = summary.mail or {},
		money = summary.money or 0
	}

	TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "RespondToStateSummary: %s requesterV=%d currentV=%d requesterHash=%s currentHash=%s requesterMailHash=%s currentMailHash=%s", norm, requesterVersion, currentVersion, tostring(requesterHash), tostring(currentHash), tostring(requesterMailHash), tostring(currentMailHash))

	-- Delta mode - ONLY use hashes, no version fallback
	if self:ShouldUseDelta() then
		-- If current alt doesn't have a hash, send full data (might be from pre-hash version)
		if not currentHash then
			TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Sending full data to %s for %s (responder has no hash)", requester, norm)
			-- DELTA-014: Pass zero hashes (requester baseline unknown, send everything)
			self:SendAltData(norm, 0, 0, requester, nil)
			return
		end

		-- If requester has no hash (nil), they have no data - send everything
		if not requesterHash then
			TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Sending full data to %s for %s (requester has no data)", requester, norm)
			-- DELTA-014: Pass zero hashes (requester has no data, everything is new)
			self:SendAltData(norm, 0, 0, requester, nil)
			return
		end

		-- Check both inventory and mail hashes
		if requesterHash == currentHash and requesterMailHash == currentMailHash then
			-- Both hashes match - no changes needed.
			-- P2P-025: a pendingSendTimeouts cleanup block stood here. Nothing ever wrote that
			-- registry, so it could not run. The live slot release is P2PSession:ReleaseSendSlot.
			-- HASH-CANON-002: NO HASHES ON A NO-CHANGE MESSAGE. This used to carry `hash`, `hashV2`
			-- and `mailHash` so the requester could ADOPT them, and the receive side has now deleted
			-- that adoption -- any peer holding a copy answers a state summary, so adopting from one
			-- let a number minted by a non-author travel the guild and overwrite good records.
			--
			-- Removing them from the SEND side too, rather than only refusing them on receive, is
			-- the point: an older client still adopts whatever arrives, so continuing to publish a
			-- hash we may not have authored would keep feeding the exact loop this closes.
			--
			-- A no-change now says only "your version is current", plus slot counts, which are
			-- display data and carry no version identity. The canon travels with the DATA, on
			-- togbank-d4, stamped by the client that scanned it.
			local noChangeMsg = {
				type = "no-change",
				name = norm,
				version = currentVersion,
				bankSlots = currentAlt.bank and currentAlt.bank.slots or nil,
				bagsSlots = currentAlt.bags and currentAlt.bags.slots or nil,
			}
			local data = TOGBankClassic_Core:SerializeWithChecksum(noChangeMsg)
			TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Sending no-change to %s for %s (hash match: inv=%d, mail=%d)", requester, norm, currentHash, currentMailHash)
			if not TOGBankClassic_Core:SendWhisper("togbank-nochange", data, requester, "NORMAL") then
				return
			end
			TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Sent no-change reply to %s for %s (hash=%08x, mailHash=%08x)", requester, norm, currentHash, currentMailHash)
			if self.Info and self.Info.name then TOGBankClassic_Database:RecordNoChangeSent(self.Info.name) end
			return
		elseif requesterHash == currentHash and requesterMailHash ~= currentMailHash then
			-- Only mail changed.
			-- DELTA-020: requesterBaseline from state summary is sufficient for delta computation.
			-- The old hasSnapshot gate was a pre-DELTA-020 safety measure (snapshot held the
			-- responder's data, not the requester's). ComputeDelta now uses requesterBaseline
			-- directly, so no snapshot is needed.
			TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Sending data to %s for %s (mail-only change: requester=%d, current=%d)", requester, norm, requesterMailHash, currentMailHash)
			-- DELTA-020: Pass requester baseline for accurate delta computation
			self:SendAltData(norm, requesterHash, requesterMailHash, requester, requesterBaseline)
			return
		else
			-- Inventory changed (mail may or may not have changed).
			-- DELTA-020: requesterBaseline from state summary is sufficient for delta computation.
			-- The old hasSnapshot gate was a pre-DELTA-020 safety measure (snapshot held the
			-- responder's data, not the requester's). ComputeDelta now uses requesterBaseline
			-- directly, so no snapshot is needed. requesterHash == 0 (new requester with no data)
			-- is handled inside ComputeDelta by sending all items as additions.
			TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Sending data to %s for %s (inv mismatch: %d->%d, mail: %d->%d)", requester, norm, requesterHash, currentHash, requesterMailHash, currentMailHash)
			-- DELTA-020: Pass requester baseline for accurate delta computation
			self:SendAltData(norm, requesterHash, requesterMailHash, requester, requesterBaseline)
			return
		end
	end

	-- Legacy mode: Compare versions only
	TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Legacy mode for %s - comparing versions", norm)
	if requesterVersion == currentVersion then
		-- No changes - send no-change message.
		-- P2P-025: the second copy of the dead pendingSendTimeouts cleanup stood here.
		local noChangeMsg = {
			type = "no-change",
			name = norm,
			version = currentVersion,
			bankSlots = currentAlt.bank and currentAlt.bank.slots or nil,
			bagsSlots = currentAlt.bags and currentAlt.bags.slots or nil,
		}
		local data = TOGBankClassic_Core:SerializeWithChecksum(noChangeMsg)
		TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Sending no-change to %s for %s (version match: v%d)", requester, norm, currentVersion)
		if not TOGBankClassic_Core:SendWhisper("togbank-nochange", data, requester, "NORMAL") then
			return
		end
		TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Sent no-change reply to %s for %s (v%d)", requester, norm, currentVersion)
		if self.Info and self.Info.name then TOGBankClassic_Database:RecordNoChangeSent(self.Info.name) end
		return
	end

	-- Version mismatch - send full data
	TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Sending data to %s for %s (version mismatch: requester=%d, current=%d)", requester, norm, requesterVersion, currentVersion)
	-- DELTA-014: Legacy mode doesn't use hashes, pass zeros (no baseline)
	self:SendAltData(norm, 0, 0, requester, nil)
end

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

-- Ensure legacy fields (bank.items, bags.items) exist for backward compatibility with old clients.
-- New clients (v0.8.0+) use alt.items as the canonical aggregate view; old clients need the
-- bank.items / bags.items split.
--
-- [ITEM-004 FIX] When alt.bank.items is missing (peer-relayed data only carried alt.items),
-- we previously COPIED all of alt.items into alt.bank.items as a "reconstruction". That was
-- catastrophic: alt.items is the bank+bags+MAIL aggregate, so the copy poisoned bank.items
-- with shared table references to mail items. Subsequent re-aggregation in ApplyDelta
-- (Aggregate(bank, bags) → Aggregate(result, mail)) then summed those mail items twice
-- on every delta apply, causing gear item Counts to inflate monotonically across peer
-- relay cycles. The corruption presented as base-name "Battlefell Sabre" Count=21 and
-- random-suffix variants like "of Power" Count=6237 in real SavedVariables.
-- See docs/DELTA_BUGS.md ITEM-004 for the full root-cause analysis.
--
-- The fix: leave bank.items empty when missing. The next direct delta from the actual
-- banker repopulates it correctly. Display code already prefers alt.items when present.
function TOGBankClassic_Guild:EnsureLegacyFields(alt)
	if not alt or not alt.items then
		return alt
	end

	-- Ensure bank.items exists as an empty array if absent. Do NOT copy alt.items into it.
	if not alt.bank or not alt.bank.items then
		if not alt.bank then
			alt.bank = {}
		end
		alt.bank.items = {}
	end

	-- Ensure bags.items exists (even if empty) so legacy iteration code doesn't nil-error.
	if not alt.bags then
		alt.bags = {}
	end
	if not alt.bags.items then
		alt.bags.items = {}
	end

	return alt
end

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

--- INV2 step 10: `requesterInventoryHash`, `requesterMailHash` and `requesterBaseline` are now
--- UNUSED and kept only to hold the positional signature, because callers across Chat.lua and
--- P2PSession pass them. They fed `ComputeDelta`, which computed a diff against the requester's
--- baseline; a V2 send is a full tuple snapshot and needs to know nothing about what the requester
--- already holds. They go when the state summary carries a tuple baseline and delta-over-tuples
--- lands -- at which point they become meaningful again rather than merely present.
---@diagnostic disable-next-line: unused-local
function TOGBankClassic_Guild:SendAltData(name, requesterInventoryHash, requesterMailHash, target, requesterBaseline) -- luacheck: ignore requesterInventoryHash requesterMailHash requesterBaseline
	if not name then
		return
	end
	local norm = self:NormalizeName(name)

	-- P2P-025: an `isP2PSend` flag and a `releaseP2PSlot(reason)` helper stood here, called on
	-- four early-return paths. The flag read `pendingSendTimeouts[norm]`, a registry NOTHING ever
	-- wrote, so it was permanently false and the helper's entire body sat behind it -- dead at the
	-- guard, not merely at the counter. The four calls were removed with it because they could not
	-- have any effect. Whatever replaces this must release through
	-- TOGBankClassic_P2PSession:ReleaseSendSlot, which is where the cap is genuinely accounted.
	if not self.Info or not self.Info.alts or not self.Info.alts[norm] then
		return
	end

	-- Determine distribution channel: WHISPER to target if provided, otherwise GUILD broadcast
	local distribution = "GUILD"
	local distTarget = nil
	if target then
		distribution = "WHISPER"
		distTarget = target
		TOGBankClassic_Output:Debug("PROTOCOL", "ALT-REQUEST", "[RESPONSE] Sending %s data via WHISPER to %s (pull-based response)", norm, target)
	else
		TOGBankClassic_Output:Debug("PROTOCOL", "ALT-REQUEST", "[RESPONSE] Sending %s data via GUILD broadcast (manual share)", norm)
	end

	-- No longer bump version here - that caused version drift from communication

	local currentAlt = self.Info.alts[norm]

	-- Ensure legacy fields exist for backward compatibility with old clients
	-- This ensures old clients that only read bank.items/bags.items still get data
	self:EnsureLegacyFields(currentAlt)  -- Modifies in place, no need to reassign

	-- [MAIL-012] Log mailHash before sending to verify it's in the alt object
	TOGBankClassic_Output:Debug("SYNC", "RECEIVE", "[MAIL-012] SendAltData for %s: mailHash=%s", norm, tostring(currentAlt.mailHash))

	-- Log what we're about to send (all 3 arrays for backward compatibility)
	local itemsCount = currentAlt.items and #currentAlt.items or 0
	local bankCount = (currentAlt.bank and currentAlt.bank.items) and #currentAlt.bank.items or 0
	local bagsCount = (currentAlt.bags and currentAlt.bags.items) and #currentAlt.bags.items or 0
	TOGBankClassic_Output:Debug("SYNC", "RECEIVE", "Sending %s: alt.items=%d, alt.bank.items=%d (includes mail), alt.bags.items=%d",
		norm, itemsCount, bankCount, bagsCount)

	-- DEBUG: Log sample counts from what we're about to send
	if currentAlt.items and #currentAlt.items > 0 then
		local sampleItems = {}
		for i = 1, math.min(5, #currentAlt.items) do
			local item = currentAlt.items[i]
			if item then
				table.insert(sampleItems, string.format("%s:%d", item.ID or "?", item.Count or 0))
			end
		end
		TOGBankClassic_Output:Debug("SYNC", "RECEIVE", "First 5 items in alt.items being sent: %s", table.concat(sampleItems, ", "))
	end

	-- INV2 step 10: `deltaData` and `computeStart` went with the legacy delta build below. There is
	-- one send path now and it does not compute a diff, so there is nothing to time and nothing to
	-- hold between branches.
	--
	-- INV2 step 7b. The V2 path sends TUPLES and returns here: it never reaches ComputeDelta,
	-- StripDeltaLinks, NeedsLink or ForceLink below. That is the point rather than a shortcut --
	-- there is no link on the wire to decide about, because the receiver rebuilds it from
	-- LibItemDB (Modules/Inventory/Resolve.lua). The per-item "is this link safe to drop" guess is
	-- what corrupts data, and a branch that skips it is the only way to stop making it.
	--
	-- A FULL SNAPSHOT, NOT A DELTA, and the reason is a real constraint rather than laziness:
	-- ComputeTupleDelta needs the REQUESTER's tuple baseline to diff against, and `togbank-state`
	-- carries only the legacy one (per-source ID+Count). Diffing today's tuples against that would
	-- compare two different things. A tuple row is a few integers against a link's 70-90 bytes, so
	-- a full V2 snapshot is already competitive with the link delta it replaces; delta-over-tuples
	-- lands once the state summary carries a tuple baseline.
	--
	-- GATED ON `sendV2Wire` VIA Wire.shouldSendV2(), not on `inventoryV2` alone. The two switches
	-- mean different things and INVENTORY_V2.md section 6 keeps them apart deliberately:
	-- `inventoryV2` chooses the local STORAGE and read source, `sendV2Wire` chooses what goes on
	-- the WIRE. Emission is the half that a peer can see, so it is the half that must be flippable
	-- on its own -- turning it off is the rollback when a guild turns out to have unmigrated
	-- clients, and it has to work without also reverting local storage.
	--
	-- Gating on `inventoryV2` alone left `sendV2Wire` read ONLY by Wire.shouldSendV2, which nothing
	-- called -- the identical shape as INV2-SWITCH-001 earlier the same day, reintroduced by me
	-- while wiring this. switches_spec's guard does not catch it: it asks whether the switch NAME
	-- is read somewhere in the shipped source, and it was -- inside a function with no caller.
	if TOGBankClassic_Switches and TOGBankClassic_Switches:IsEnabled("inventoryV2")
		and TOGBankClassic_Inventory_Wire and TOGBankClassic_Inventory_Wire.shouldSendV2()
		and TOGBankClassic_Inventory_Store
		and self.Info and self.Info.name then
		local Wire    = TOGBankClassic_Inventory_Wire
		local records = TOGBankClassic_Inventory_Store:GetAltRecords(self.Info.name, norm)
		-- Wire.encode returns nil when there is nothing sendable, so an empty envelope a receiver
		-- would apply as "this alt has no items" is never transmitted. Falling through to the
		-- legacy path in that case is deliberate: it is the same alt, and the legacy record may
		-- still hold data this client has not scanned into V2.
		-- HASH-CANON-001: PUBLISH OUR CANON WITH THE DATA IT DESCRIBES. These are the hashes this
		-- client stamped at SCAN time (Bank.lua's StampInventoryHashes), which is the only place a
		-- hash is ever produced. Sending them is what lets every receiver hold the same identity
		-- for this version instead of deriving its own -- see the receive path in Chat.lua.
		--
		-- Passed straight through, NOT recomputed here. Computing at send time is its own defect in
		-- DeltaSync's list ("the hash changes when nothing changed. Peers see churn on every
		-- broadcast and re-sync data they already have").
		--
		-- nil is legitimate and is forwarded as nil: a banker that has not scanned since upgrading
		-- has published no canon, and the receiver must be able to tell that from a real value.
		-- HASH-CANON-001 rule 7: the author's PUBLISH TIME rides with the data too. Bank.lua stamps
		-- it in the same block as the two hashes, from the same scan, so all three describe one
		-- version. Without it the receiver stamped its own arrival time and a relayed copy claimed
		-- to be fresher than the author's own record -- see the note on Wire.encode.
		-- HASH-CANON-004: `mailHash` goes too. `HashesAgreeWith` needs BOTH hashes to match before
		-- it will call an alt in sync, and only the author's own scan stamps the mail one -- so
		-- omitting it leaves every receiver comparing a real advertised value against nil, forever.
		local payload = Wire.encode(norm, records, currentAlt.money,
			currentAlt.inventoryHash, currentAlt.inventoryHashV2,
			currentAlt.inventoryUpdatedAt or currentAlt.version,
			currentAlt.mailHash)
		if payload and #records > 0 then
			local body = TOGBankClassic_Core:SerializeWithChecksum(payload)
			local onSent = CreateOnChunkSentCallback(norm, distTarget)
			if not TOGBankClassic_Options:IsSyncProgressMuted() then
				TOGBankClassic_Output:Info("Sharing guild bank data: %d bytes in ~%d chunks...",
					string.len(body), math.ceil(string.len(body) / 254))
			end
			TOGBankClassic_Core:SendCommMessage("togbank-d4", body, distribution, distTarget,
				"BULK", onSent)
			TOGBankClassic_Output:Debug("DELTA", "BUILD",
				"[INV2] sent %d tuple(s) for %s via togbank-d4 to %s (%d bytes)",
				#records, norm, distribution, string.len(body))
			return
		end
	end

	-- INV2 step 10 / the 2026-09-09 directive: THE LEGACY LINK SEND PATH ENDED HERE.
	--
	-- Everything below this point used to be: ComputeDelta -> DeltaHasChanges -> either a
	-- `togbank-nochange` hash correction or a link-bearing `alt-delta` on togbank-d4. All of it is
	-- gone. TOGBank sends tuples or it sends nothing.
	--
	-- REACHING HERE IS NOW A REAL CONDITION WORTH REPORTING rather than a fallback: it means this
	-- client holds a legacy record for the alt but no V2 records, so it has not rescanned since
	-- upgrading. The remedy is a scan, and saying so is more useful than silently sending a format
	-- nobody speaks any more.
	--
	-- KNOWN COST, stated rather than buried: every V2 send is a FULL SNAPSHOT, because
	-- ComputeTupleDelta needs the requester's tuple baseline and `togbank-state` still carries only
	-- the legacy one. So an unchanged inventory is re-sent in full where the old path would have
	-- answered "no change" in a few bytes. A tuple row is a handful of integers against a link's
	-- 70-90 bytes, so this is not the regression it sounds like -- but it is a regression, and it
	-- closes when the state summary carries a tuple baseline.
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

-- Check if this client uses SYNC-006 aggregated items format
function TOGBankClassic_Guild:UsesSYNC006()
	-- SYNC-006 introduced aggregated items structure (alt.items)
	-- All current clients use SYNC-006
	return true
end

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

