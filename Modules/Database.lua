-- INV2-RETIRE-002: the delta-snapshot cache (`SaveSnapshot` / `GetSnapshot` / `ValidateSnapshot` /
-- `DeepCopy`) was deleted here. It was the baseline for the legacy alt-delta (`ComputeDelta`), which
-- INV2 step 10 removed in v1.4.0 -- and since then Bank:Scan deep-copied every item row of the
-- banker's record into it on every scan, for a reader that no longer existed. PERF-012's lesson
-- stays on record because it is the operator's SV rule in numbers: persisting these snapshots once
-- added ~18k lines / 0.5 MB to the SavedVariables and caused a load freeze.

TOGBankClassic_Database = {}

function TOGBankClassic_Database:Init()
	self.db = LibStub("AceDB-3.0"):New("TOGBankClassicDB", {
		global = {
			debugCategories = {
				ROSTER = false,
				COMMS = false,
				DELTA = false,
				SYNC = false,
				CACHE = false,
				WHISPER = false,
				REQUESTS = false,
				UI = false,
				PROTOCOL = false,
				DATABASE = false,
				EVENTS = false,
				MAIL = false,
				QUERIES = false,
				P2P = false,
				BANK = false,
				ITEM = false,
				-- DEBUG-001: must match DEBUG_CATEGORY in Constants.lua and CATEGORY_META in
				-- Options.lua. All three are maintained by hand and nothing else asserts they
				-- agree, so a category added to one and not the others is invisible.
				SYSTEM = false,
				FULFILL = false,
				DELTASYNC = false,
				LOG = false,
			},
			debugTags = {},  -- per-category tag overrides: debugTags["P2P"]["OFFER"] = false
			showUncategorizedDebug = true,  -- Show legacy debug messages by default
		},
	})

	-- INV2-RETIRE-003: the 30-second `PurgeLinklessGearGhosts` timer that ran here is gone with the
	-- migration itself (ITEM-004: drop link-less gear rows that only a stripped legacy delta could
	-- have produced). It walked the legacy item arrays, and those are now stripped: here for every
	-- guild record this faction holds, and again in Load for the guild being loaded.
	self:StripAllLegacyItemRows()
end

--- INV2-RETIRE-003: strip the legacy item rows from EVERY guild record in this faction's scope, not
--- only the one Load is about to attach. `Load` runs per guild name, so a record for a guild the
--- player has since left would otherwise keep its rows in the SavedVariables forever -- and the SV's
--- size is the whole point of the strip. AceDB's faction scope is keyed by guild name, so this is
--- one pass over what the file holds for this faction; the other faction's records are reached when
--- a character of that faction logs in.
--- @return number rows stripped across every guild
function TOGBankClassic_Database:StripAllLegacyItemRows()
	local faction = self.db and self.db.faction
	if type(faction) ~= "table" then return 0 end
	local stripped = 0
	for _, guild in pairs(faction) do
		stripped = stripped + self:StripLegacyItemRows(guild)
	end
	if stripped > 0 then
		TOGBankClassic_Output:Debug("DATABASE", "MIGRATE",
			"[INV2-RETIRE-003] stripped %d legacy item row(s) across every guild record; the V2 store holds the inventory",
			stripped)
	end
	return stripped
end

--- INV2-COMPAT-001: `Info.alts[name].items` STAYS READABLE FOR OTHER ADDONS, answered from the store.
---
--- The operator, 2026-09-11, on being told the strip left TOGProfessionMaster's [Bank] button empty:
--- "we can't break the bank integration, why did you break it?" TOGProfessionMaster (Compat.lua
--- `addon.Bank.GetStock` / `GetBanksWithItem`) reads `TOGBankClassic_Guild.Info.alts[name].items`
--- directly -- `pairs` over the alts, `ipairs` over `.items`, `entry.ID` / `entry.Count` -- and it
--- is a shipped consumer of that shape. Deleting the rows without a replacement broke it; and on
--- v1.4.x it was already reading STALE rows for every received banker, because the tuple receive
--- never refreshed `alt.items`. So this is a fix as well as a shim.
---
--- HOW: every alt record carries a metatable whose `__index` answers `items` from
--- `Guild:GetAltItems(name)` -- the store's resolved view, the same array every TOGBank window reads,
--- so an external reader now sees LIVE data for every banker. The alts table carries a `__newindex`
--- that wraps any record created later at a NEW key (`alts[name] = {}` in Bank:Scan, the roster
--- stub, the hash-list stub, the tuple receive); a record replaced at an EXISTING key does not
--- trigger it, and the one site that does that (`ResetPlayer`) wraps explicitly.
---
--- WHY IT DOES NOT UNDO THE STRIP: the client writes SavedVariables by walking a table's RAW
--- contents, so a metatable-provided field is never serialized -- AceDB's own defaults rely on the
--- same property. Nothing is added to the file. Internal readers use the accessors, not this; the
--- strip reads through `rawget` so a wrapped record does not look like it still has rows.
---@param name string the alt's normalized name
---@return function __index handler
local function compatIndex(name)
	return function(_, key)
		if key ~= "items" then return nil end
		local G = TOGBankClassic_Guild
		if not (G and G.GetAltItems) then return nil end
		return G:GetAltItems(name)
	end
end

local COMPAT_MARK = "__togbankAltCompat"

--- Is this record wrapped? Exposed so a spec can assert PRESENCE, not only that `items` answers.
---@param alt table
---@return boolean
function TOGBankClassic_Database:HasAltCompat(alt)
	local mt = type(alt) == "table" and getmetatable(alt)
	return (mt and mt[COMPAT_MARK]) == true
end

--- HAZARD, stated because it is silent (Peer Review, 2026-09-11): a record that ALREADY carries a
--- metatable is left alone -- and no record does today, because Init registers AceDB defaults for
--- `global` only. The day a `faction` default is added, AceDB attaches its own metatable to every
--- record, this wraps nothing, and TPM's [Bank] button goes empty with the suite still green --
--- unless a spec asserts the wrapper is PRESENT on a loaded record. `altcompat_spec` does, through
--- `HasAltCompat`. If that day comes, the answer is to chain: keep AceDB's `__index` as the fallback
--- inside ours.
---@param name string
---@param alt table
function TOGBankClassic_Database:AttachAltCompat(name, alt)
	if type(alt) ~= "table" or getmetatable(alt) ~= nil then return end
	setmetatable(alt, { [COMPAT_MARK] = true, __index = compatIndex(name) })
end

--- Wrap every record in `alts` and arm the table so records added later are wrapped too.
--- Idempotent: an alts table already armed is left alone, and a record with a metatable of its own
--- is never re-wrapped.
---@param alts table
function TOGBankClassic_Database:AttachAltsCompat(alts)
	if type(alts) ~= "table" then return end
	local mt = getmetatable(alts)
	if not (mt and mt[COMPAT_MARK]) then
		setmetatable(alts, {
			[COMPAT_MARK] = true,
			__newindex = function(t, key, value)
				TOGBankClassic_Database:AttachAltCompat(key, value)
				rawset(t, key, value)
			end,
		})
	end
	for name, alt in pairs(alts) do
		self:AttachAltCompat(name, alt)
	end
end

--- INV2-RETIRE-003: STRIP THE LEGACY ITEM ROWS FROM EVERY ALT RECORD, on load, unconditionally.
---
--- `alt.items`, `alt.bank.items`, `alt.bags.items`, `alt.mail.items` -- the link-bearing rows the
--- legacy scan and the legacy wire wrote -- are no longer written by anything (Bank:Scan writes the
--- V2 store; the tuple receive writes the V2 store) and no longer read by anything (every reader is
--- on `Guild:GetAltItems` / `GetAltItemTotal` / the store). Measured on the operator's own account
--- on 2026-09-11 they were 56% of a 1.52 MB SavedVariables file -- ~35,900 of 64,123 lines -- and
--- the SV's size is what the operator's rule is about: "the larger it is, the more impact it has on
--- init performance. to the point that it can crash the game". Nothing in them is unique: every
--- banker's rows are re-derivable from the V2 store or the next delivery/scan.
---
--- UNCONDITIONAL, not gated on `Store:IsAltComplete`. docs/DELTA_RELEASE.md section 4 first said to
--- gate the strip so a schema-1 V2 record (scanned before INV2-MAIL-001, no mail bucket) could keep
--- its legacy rows for the accessors' fallback. The fallback is deleted -- there is nothing for the
--- rows to be kept FOR -- so the gate would only keep 56% of the file for a record that heals on
--- the banker's next mailbox visit anyway.
---
--- The sub-tables themselves stay: `slots` feeds the status bar and `lastScan` the MULTIPC-001
--- publish gate. Synchronous, in Load, before anything reads the record. Idempotent.
--- @return number rows stripped (the legacy row count, for the one-time load message)
function TOGBankClassic_Database:StripLegacyItemRows(db)
	local alts = db and db.alts
	if type(alts) ~= "table" then return 0 end
	local stripped = 0
	-- rawget, not `t.items`: a record that AttachAltCompat has already wrapped answers `items` from
	-- the store through its metatable, and that answer is not a row to strip (nor to count).
	local function take(t)
		if type(t) ~= "table" then return end
		local rows = rawget(t, "items")
		if rows ~= nil then
			if type(rows) == "table" then
				for _ in pairs(rows) do stripped = stripped + 1 end
			end
			rawset(t, "items", nil)
		end
	end
	for _, alt in pairs(alts) do
		if type(alt) == "table" then
			take(alt)
			take(alt.bank)
			take(alt.bags)
			take(alt.mail)
		end
	end
	return stripped
end

-- DB-003 (audit finding 18, round 20): THE ONE deltaMetrics constructor. The literal lived in FOUR
-- places -- Reset, twice in Load, ResetDeltaMetrics -- and had diverged: three carried 16 keys and
-- the fourth 20, so a guild record created by Reset lacked the four timing counters a /togbank
-- reset one had, and every reader had to carry an `or 0` to survive it. One spelling; a spec
-- asserts Reset and ResetDeltaMetrics produce equal key sets.
local function newDeltaMetrics()
	return {
		bytesSentDelta = 0,
		bytesSentFull = 0,
		bytesSavedByDelta = 0,
		deltasSentCount = 0,
		p2pSentCount = 0,
		noChangeSentCount = 0,
		bytesReceived = 0,
		deltasReceivedFromBanker = 0,
		deltasReceivedFromPeer = 0,
		p2pOffered = 0,
		p2pRequestsBroadcast = 0,
		p2pFulfilledByPeer = 0,
		p2pBankerFallback = 0,
		deltasApplied = 0,
		deltasFailed = 0,
		fullSyncFallbacks = 0,
		totalComputeTime = 0,
		computeCount = 0,
		totalApplyTime = 0,
		applyCount = 0,
	}
end
TOGBankClassic_Database.NewDeltaMetrics = newDeltaMetrics

local function newDeltaErrors()
	return {
		lastErrors = {},     -- Recent errors for debugging (max 10)
		failureCounts = {},  -- Track failures per alt
		notifiedAlts = {},   -- Track which alts we've notified about
	}
end

function TOGBankClassic_Database:Reset(name)
	if not name then
		return
	end

	self.db.faction[name] = {
		name = name,
		roster = {},
		alts = {},
		requests = {},
		requestsVersion = 0,
		requestsTombstones = {},
		settings = {
			maxRequestPercent = 100,  -- Default to no limit
			autoTombstoneDays = 30,   -- Stale open requests older than this are auto-tombstoned on receive
			-- CANCELREASON-001: officer-authored, guild-synced cancel-reason config.
			--   custom        = array of { text = string, member = bool, banker = bool }
			--                   (a custom reason can be offered in the member self-cancel
			--                    dropdown, the banker-cancel dropdown, both, or neither).
			--   presetDisabled = { banker = { key=true }, member = { key=true } } — built-in
			--                   flavor presets the officers have un-ticked so they stop being
			--                   offered in that role's dropdown.
			cancelReasons = {
				custom = {},
				presetDisabled = { banker = {}, member = {} },
			},
			-- HELPNOTE-001: officer-authored note appended to the bottom of each
			-- window's help "?" tooltip (per window). Guild-synced.
			helpNotes = { inventory = "", search = "", requests = "" },
		},
		-- Delta sync fields
		guildProtocolVersions = {},
		-- STALE-REQ-002: the last ADDON version each guildmate was seen on ({ version, at } by
		-- normalized name), for the Requests tab's mark on an offline requester. Session sources
		-- (VersionCheck, the broadcast) empty on reload; this does not.
		peerAddonVersions = {},
		deltaMetrics = newDeltaMetrics(),
		-- Delta error tracking (persisted across reloads)
		deltaErrors = newDeltaErrors(),
	}

	TOGBankClassic_Output:Response("Reset Database (cleared deltaHistory and deltaSnapshots)")
end

function TOGBankClassic_Database:ResetPlayer(name, player)
	if not name then
		return
	end
	if not player then
		return
	end

	-- DB-002: guard the GUILD record, not just the alt. `faction[name]` is nil for any guild the
	-- addon has never stored, and indexing `.alts` on it raised
	-- "attempt to index field '?' (a nil value)" -- a Lua error where the correct answer is
	-- "nothing to reset".
	local guild = self.db.faction[name]
	if not guild or not guild.alts or not guild.alts[player] then
		return
	end

	-- Replaced at an EXISTING key, which `__newindex` does not see -- so wrapped by hand
	-- (INV2-COMPAT-001).
	local fresh = {}
	self:AttachAltCompat(player, fresh)
	guild.alts[player] = fresh

	TOGBankClassic_Output:Response("Reset Player Database")
end

function TOGBankClassic_Database:Load(name)
	if not name then
		return
	end

	local db = self.db.faction[name]

	-- Only reset if there's truly no data (nil). Otherwise initialize missing fields.
	-- This prevents data loss when some fields are missing but others (like requests) exist.
	if db == nil then
		TOGBankClassic_Database:Reset(name)
		db = self.db.faction[name]
	else
		-- Initialize missing fields without wiping existing data
		if db.name == nil then
			db.name = name
		end
		if db.roster == nil then
			db.roster = {}
		end
		if db.alts == nil then
			db.alts = {}
		end
	end

	if not db.requests then
		db.requests = {}
	end

	-- PERF-012: Purge legacy persisted fields — no longer stored in SavedVariables.
	-- deltaSnapshots moved to in-memory cache; deltaHistory is dead code since v0.8.0.
	-- Niling these removes the old 18k+ lines of data from the SV file on next save.
	if db.deltaHistory ~= nil then
		db.deltaHistory = nil
	end
	if db.deltaSnapshots ~= nil then
		db.deltaSnapshots = nil
	end

	-- INV2-RETIRE-003: the legacy item rows go here, synchronously, before any reader runs.
	local strippedRows = self:StripLegacyItemRows(db)
	if strippedRows > 0 then
		TOGBankClassic_Output:Debug("DATABASE", "MIGRATE",
			"[INV2-RETIRE-003] stripped %d legacy item row(s) from %s; the V2 store holds the inventory",
			strippedRows, name)
	end
	-- INV2-COMPAT-001: and `alt.items` keeps answering, from the store, for the addons that read it.
	-- After the strip, so the wrapper never sits over rows that are about to go.
	self:AttachAltsCompat(db.alts)

	if not db.requestsVersion then
		db.requestsVersion = 0
	end

	if not db.requestsTombstones then
		db.requestsTombstones = {}
	end

	-- Initialize delta sync fields if missing. DB-003: this block used to appear TWICE in this
	-- function (the second copy sat after the settings block and could never take effect); one copy
	-- now, through the one constructor. A record whose metrics table predates the four timing
	-- counters gets them backfilled here rather than relying on every reader's `or 0`.
	if not db.guildProtocolVersions then
		db.guildProtocolVersions = {}
	end
	if not db.peerAddonVersions then   -- STALE-REQ-002
		db.peerAddonVersions = {}
	end
	if not db.deltaMetrics then
		db.deltaMetrics = newDeltaMetrics()
	else
		for key, zero in pairs(newDeltaMetrics()) do
			if db.deltaMetrics[key] == nil then db.deltaMetrics[key] = zero end
		end
	end
	if not db.deltaErrors then
		db.deltaErrors = newDeltaErrors()
	end

	-- Migrate old alt data structures from pre-v0.8 saves (no-ops for v0.9.6+ users)
	C_Timer.After(0.5, function()
					-- Characters scanned before v0.6.0 may have bank/bags without slots
		if db.alts then
			for altName, alt in pairs(db.alts) do
				if type(alt) == "table" then
					if alt.bank and not alt.bank.slots then
						alt.bank.slots = { count = 0, total = 0 }
						TOGBankClassic_Output:Debug("DATABASE", "MIGRATE", "Migrated alt data: initialized bank.slots for %s", altName)
					end
					if alt.bags and not alt.bags.slots then
						alt.bags.slots = { count = 0, total = 0 }
						TOGBankClassic_Output:Debug("DATABASE", "MIGRATE", "Migrated alt data: initialized bags.slots for %s", altName)
					end

					-- HASH-CANON-003: THE MIGRATION NO LONGER MINTS AN INVENTORY HASH, and the whole
					-- block that did -- the aggregation, the money read, the stamp -- is deleted
					-- rather than left unreached.
					--
					-- It existed so "a migrated record advertises the same pair a scanned one does",
					-- and the argument was sound while a hash was treated as a digest of content.
					-- It is wrong once a hash is the IDENTITY OF A VERSION: this migration runs over
					-- SavedVariables that mostly describe OTHER PEOPLE'S bank characters, received
					-- over the wire. Minting one for those is this client inventing an identity for
					-- data it never read -- the same class as the two mutation sites deleted in
					-- HASH-CANON-002, and it travels the same way, because we then advertise our
					-- invented number and peers adopt it.
					--
					-- WHAT HAPPENS INSTEAD: nothing, deliberately. A record with no canon advertises
					-- no canon and is re-requested from the client that can author one; for our own
					-- characters that is the next bank scan, now the only place a canon is born.
					-- Self-correcting, and it cannot go quiet while wrong -- an invented hash is
					-- indistinguishable from a real one and never heals.
					--
					-- MIGRATE-001 / AUDIT finding 3 and finding 25 were both about WHICH ARGUMENTS
					-- this call site passed. The call site is gone, so those are moot here rather
					-- than resolved -- do not read this deletion as agreeing with either.

					-- CANON-TIME-001: `alt.version`, NEVER our clock -- and this used to read
					-- `alt.version or GetServerTime()`, which is the very thing the comment above
					-- forbids, arrived at one field later. The deletion recorded above removed the
					-- invented HASH and left an invented TIME, and a time is enough on its own:
					-- `Guild:ReencodeHeldCanons` runs immediately after this load and builds a canon
					-- as `<inventoryUpdatedAt><hash>` from any still-numeric v1.4.0 canon. So a record
					-- for SOMEONE ELSE'S banker, carried from a pre-v1.4.0 file with no version of its
					-- own, was re-encoded as a canon stamped with THIS CLIENT'S LOGIN TIME -- newer
					-- than anything the real author ever published -- and then advertised, putting the
					-- author's own tab behind a version that never existed.
					--
					-- Leaving it nil is the designed outcome, not a gap: CanonFrom with no publish
					-- time returns nil, ReencodeHeldCanons CLEARS the canon ("a version nobody can
					-- place in time"), the record advertises nothing and is re-requested from the
					-- client that can author one.
					if alt.inventoryHash and not alt.inventoryUpdatedAt and alt.version then
						alt.inventoryUpdatedAt = alt.version
						TOGBankClassic_Output:Debug("DATABASE", "MIGRATE", "Migrated alt data: backfilled inventoryUpdatedAt for %s (ts=%s)", altName, tostring(alt.inventoryUpdatedAt))
					end
				end
			end
		end
	end)

	if not db.settings then
		db.settings = {}
	end
	if db.settings.maxRequestPercent == nil then
		db.settings.maxRequestPercent = 100
	end
	if db.settings.autoTombstoneDays == nil then
		db.settings.autoTombstoneDays = 30
	end
	-- CANCELREASON-001: custom guild cancel reasons + preset disable-set
	if type(db.settings.cancelReasons) ~= "table" then
		db.settings.cancelReasons = {}
	end
	if type(db.settings.cancelReasons.custom) ~= "table" then
		db.settings.cancelReasons.custom = {}
	end
	if type(db.settings.cancelReasons.presetDisabled) ~= "table" then
		db.settings.cancelReasons.presetDisabled = {}
	end
	if type(db.settings.cancelReasons.presetDisabled.banker) ~= "table" then
		db.settings.cancelReasons.presetDisabled.banker = {}
	end
	if type(db.settings.cancelReasons.presetDisabled.member) ~= "table" then
		db.settings.cancelReasons.presetDisabled.member = {}
	end
	-- HELPNOTE-001: per-window officer help notes appended to the help "?" tooltips
	if type(db.settings.helpNotes) ~= "table" then
		db.settings.helpNotes = {}
	end
	for _, key in ipairs({ "inventory", "search", "requests" }) do
		if type(db.settings.helpNotes[key]) ~= "string" then
			db.settings.helpNotes[key] = ""
		end
	end

	return db
end

-- Protocol Version Tracking

-- Update protocol version for a guild member
function TOGBankClassic_Database:UpdatePeerProtocol(name, sender, protocolVersion, supportsDelta)
	if not name or not sender then
		return false
	end

	local db = self.db.faction[name]
	if not db or not db.guildProtocolVersions then
		return false
	end

	db.guildProtocolVersions[sender] = {
		version = protocolVersion or 1,
		supportsDelta = supportsDelta or false,
		lastSeen = GetServerTime(),
	}

	return true
end

-- Get protocol version for a guild member
function TOGBankClassic_Database:GetPeerProtocol(name, sender)
	if not name or not sender then
		return nil
	end

	local db = self.db.faction[name]
	if not db or not db.guildProtocolVersions then
		return nil
	end

	return db.guildProtocolVersions[sender]
end

-- Calculate percentage of online guild members supporting delta
function TOGBankClassic_Database:GetGuildDeltaSupport(name)
	if not name then
		return 0
	end

	local db = self.db.faction[name]
	if not db or not db.guildProtocolVersions then
		return 0
	end

	local total = 0
	local supporting = 0
	local currentTime = GetServerTime()

	-- Only count members seen in last 10 minutes (considered online)
	for _, info in pairs(db.guildProtocolVersions) do
		if info and info.lastSeen and (currentTime - info.lastSeen) < 600 then
			total = total + 1
			if info.supportsDelta then
				supporting = supporting + 1
			end
		end
	end

	if total == 0 then
		return 0
	end

	return supporting / total
end

-- Delta Metrics

-- Record bytes sent via delta protocol
function TOGBankClassic_Database:RecordDeltaSent(name, bytes)
	if not name or not bytes then
		return
	end

	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.bytesSentDelta = (db.deltaMetrics.bytesSentDelta or 0) + bytes
		db.deltaMetrics.deltasSentCount = (db.deltaMetrics.deltasSentCount or 0) + 1
	end
end

-- Record bytes saved by sending a delta instead of a full sync
function TOGBankClassic_Database:RecordDeltaSavings(name, bytesSaved)
	if not name or not bytesSaved or bytesSaved <= 0 then return end
	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.bytesSavedByDelta = (db.deltaMetrics.bytesSavedByDelta or 0) + bytesSaved
	end
end

-- Record a P2P send (non-banker serving data to a peer)
function TOGBankClassic_Database:RecordP2PSent(name)
	if not name then return end
	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.p2pSentCount = (db.deltaMetrics.p2pSentCount or 0) + 1
	end
end

-- Record a no-change reply sent to a requester
function TOGBankClassic_Database:RecordNoChangeSent(name)
	if not name then return end
	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.noChangeSentCount = (db.deltaMetrics.noChangeSentCount or 0) + 1
	end
end

-- Record receiving delta data from another client
function TOGBankClassic_Database:RecordDeltaReceived(name, bytes, isFromBanker)
	if not name then return end
	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.bytesReceived = (db.deltaMetrics.bytesReceived or 0) + (bytes or 0)
		if isFromBanker then
			db.deltaMetrics.deltasReceivedFromBanker = (db.deltaMetrics.deltasReceivedFromBanker or 0) + 1
		else
			db.deltaMetrics.deltasReceivedFromPeer = (db.deltaMetrics.deltasReceivedFromPeer or 0) + 1
			db.deltaMetrics.p2pFulfilledByPeer = (db.deltaMetrics.p2pFulfilledByPeer or 0) + 1
		end
	end
end

-- Record sending a P2P ACK offer to a requester
function TOGBankClassic_Database:RecordP2POffered(name)
	if not name then return end
	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.p2pOffered = (db.deltaMetrics.p2pOffered or 0) + 1
	end
end

-- Record broadcasting a P2P request to the guild
function TOGBankClassic_Database:RecordP2PRequestBroadcast(name)
	if not name then return end
	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.p2pRequestsBroadcast = (db.deltaMetrics.p2pRequestsBroadcast or 0) + 1
	end
end

-- Record falling back to banker after no peer responded
function TOGBankClassic_Database:RecordP2PBankerFallback(name)
	if not name then return end
	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.p2pBankerFallback = (db.deltaMetrics.p2pBankerFallback or 0) + 1
	end
end

-- Record bytes sent via full sync protocol
function TOGBankClassic_Database:RecordFullSyncSent(name, bytes)
	if not name or not bytes then
		return
	end

	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.bytesSentFull = (db.deltaMetrics.bytesSentFull or 0) + bytes
	end
end

-- Record successful delta application
function TOGBankClassic_Database:RecordDeltaApplied(name)
	if not name then
		return
	end

	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.deltasApplied = (db.deltaMetrics.deltasApplied or 0) + 1
	end
end

-- Record failed delta application
function TOGBankClassic_Database:RecordDeltaFailed(name)
	if not name then
		return
	end

	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.deltasFailed = (db.deltaMetrics.deltasFailed or 0) + 1
	end
end

-- Record delta computation time
function TOGBankClassic_Database:RecordDeltaComputeTime(name, milliseconds)
	if not name or not milliseconds then
		return
	end

	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.totalComputeTime = (db.deltaMetrics.totalComputeTime or 0) + milliseconds
		db.deltaMetrics.computeCount = (db.deltaMetrics.computeCount or 0) + 1
	end
end

-- Record delta application time
function TOGBankClassic_Database:RecordDeltaApplyTime(name, milliseconds)
	if not name or not milliseconds then
		return
	end

	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.totalApplyTime = (db.deltaMetrics.totalApplyTime or 0) + milliseconds
		db.deltaMetrics.applyCount = (db.deltaMetrics.applyCount or 0) + 1
	end
end

-- Reset delta metrics (for testing or cleanup)
function TOGBankClassic_Database:ResetDeltaMetrics(name)
	if not name then
		return false
	end

	local db = self.db.faction[name]
	if not db then
		return false
	end

	db.deltaMetrics = newDeltaMetrics()

	return true
end

-- Record fallback to full sync
function TOGBankClassic_Database:RecordFullSyncFallback(name)
	if not name then
		return
	end

	local db = self.db.faction[name]
	if db and db.deltaMetrics then
		db.deltaMetrics.fullSyncFallbacks = (db.deltaMetrics.fullSyncFallbacks or 0) + 1
	end
end

-- Get delta metrics
function TOGBankClassic_Database:GetDeltaMetrics(name)
	if not name then
		return nil
	end

	local db = self.db.faction[name]
	if not db or not db.deltaMetrics then
		return nil
	end

	return db.deltaMetrics
end
