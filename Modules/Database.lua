-- PERF-012: deltaSnapshots stored in-memory only — no persistence needed.
-- Snapshots are delta computation baselines that are rebuilt from live data each session.
-- Persisting them to SavedVariables added ~18k lines / 0.5 MB and caused the load freeze.
local deltaSnapshotsCache = {}

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
			},
			debugTags = {},  -- per-category tag overrides: debugTags["P2P"]["OFFER"] = false
			showUncategorizedDebug = true,  -- Show legacy debug messages by default
		},
	})

	-- Schedule the linkless-gear-ghost purge after a short delay so the WoW item cache
	-- has time to warm up. The purge identifies gear-class items (class 2/4) that lack
	-- a Link field; these can only have been created by ApplyItemDelta accepting a
	-- stripped delta (real bag scans always produce Links via C_Container). See
	-- docs/DELTA_BUGS.md ITEM-004 and the ITEM-003 update-path analysis.
	-- pcall-wrapped: a single malformed alt entry must not silently abort the migration
	-- or break addon initialization.
	if C_Timer and C_Timer.After then
		C_Timer.After(30, function()
			local ok, err = pcall(function()
				TOGBankClassic_Database:PurgeLinklessGearGhosts()
			end)
			if not ok then
				TOGBankClassic_Output:Error("Ghost purge migration failed: %s", tostring(err))
			end
		end)
	end
end

-- Walk every alt's items / bank.items / bags.items and drop entries where the item is
-- gear (class 2/4) AND has no Link. These cannot come from a local scan; they're
-- artifacts of pre-fix stripped deltas that landed in SavedVariables. Removing them
-- here recovers existing corruption without requiring users to /togbank wipe.
--
-- Safety: an entry whose class cannot be determined (Item:ItemClassNeedsLink returns
-- nil) is LEFT ALONE. We don't delete data we can't classify. Subsequent runs (after
-- TOGBankClassic_ItemDB is populated, or after the WoW cache warms further) will
-- catch them.
function TOGBankClassic_Database:PurgeLinklessGearGhosts()
	if not self.db or not self.db.faction then return end
	if not TOGBankClassic_Item or not TOGBankClassic_Item.ItemClassNeedsLink then return end

	local totalPurged = 0
	local totalScanned = 0

	local function purgeArray(arr, label, altName)
		if not arr then return 0 end
		local removed = 0
		for i = #arr, 1, -1 do
			local item = arr[i]
			totalScanned = totalScanned + 1
			if item and item.ID and not item.Link
			   and TOGBankClassic_Item:ItemClassNeedsLink(item.ID) == true then
				table.remove(arr, i)
				removed = removed + 1
				TOGBankClassic_Output:Debug("DATABASE", "MIGRATION",
					"[GHOST-PURGE] Removed linkless gear ID=%d from %s.%s",
					item.ID, altName, label)
			end
		end
		return removed
	end

	for guildName, guildData in pairs(self.db.faction) do
		if guildData and guildData.alts then
			for altName, alt in pairs(guildData.alts) do
				if type(alt) == "table" then
					totalPurged = totalPurged + purgeArray(alt.items, "items", altName)
					if alt.bank then
						totalPurged = totalPurged + purgeArray(alt.bank.items, "bank.items", altName)
					end
					if alt.bags then
						totalPurged = totalPurged + purgeArray(alt.bags.items, "bags.items", altName)
					end
					if alt.mail then
						totalPurged = totalPurged + purgeArray(alt.mail.items, "mail.items", altName)
					end
				end
			end
		end
		-- guildName intentionally not used in log (kept available for future per-guild reporting)
		_ = guildName
	end

	-- Count linkless-gear-suspect entries that we could NOT confidently classify
	-- (Item:ItemClassNeedsLink returned nil — either uncached or no static DB yet).
	-- These survive this pass and may be purged on a future run once the cache warms
	-- or the static DB is populated.
	local skippedSuspects = 0
	local function countSkipped(arr)
		if not arr then return end
		for _, item in ipairs(arr) do
			if item and item.ID and not item.Link
			   and TOGBankClassic_Item:ItemClassNeedsLink(item.ID) == nil then
				skippedSuspects = skippedSuspects + 1
			end
		end
	end
	for _, guildData in pairs(self.db.faction) do
		if guildData and guildData.alts then
			for _, alt in pairs(guildData.alts) do
				if type(alt) == "table" then
					countSkipped(alt.items)
					if alt.bank then countSkipped(alt.bank.items) end
					if alt.bags then countSkipped(alt.bags.items) end
					if alt.mail then countSkipped(alt.mail.items) end
				end
			end
		end
	end

	-- Always print a result so the user knows the migration actually ran.
	-- Three states: purged some, found suspects but couldn't confirm, fully clean.
	if totalPurged > 0 then
		TOGBankClassic_Output:Info(
			"Ghost purge: removed %d linkless gear ghost(s) from saved data (scanned %d entries). " ..
			"This recovers corruption caused by pre-fix stripped deltas. Fresh syncs " ..
			"from bankers will refill any missing data.",
			totalPurged, totalScanned)
		if skippedSuspects > 0 then
			TOGBankClassic_Output:Info(
				"Ghost purge: %d additional linkless entries skipped (item class unknown — " ..
				"item not in shipped Modules/Static/ItemDB.lua AND not yet in WoW client cache). " ..
				"Re-run /togbank dev purgeghosts after WoW has loaded the item to catch the rest.",
				skippedSuspects)
		end
	elseif skippedSuspects > 0 then
		TOGBankClassic_Output:Info(
			"Ghost purge: scanned %d entries, found %d linkless entries that COULD be gear " ..
			"ghosts but item class is unknown (not in shipped Modules/Static/ItemDB.lua and not " ..
			"yet in WoW client cache). Open the inventory window so WoW loads the items, then " ..
			"re-run /togbank dev purgeghosts.",
			totalScanned, skippedSuspects)
	else
		TOGBankClassic_Output:Info("Ghost purge: scanned %d entries, no linkless gear ghosts found. Clean.",
			totalScanned)
	end
end

function TOGBankClassic_Database:Reset(name)
	if not name then
		return
	end

	-- PERF-012: Clear in-memory snapshot cache for this guild on reset
	deltaSnapshotsCache[name] = nil

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
		deltaMetrics = {
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
		},
		-- Delta error tracking (persisted across reloads)
		deltaErrors = {
			lastErrors = {},  -- Recent errors for debugging (max 10)
			failureCounts = {},  -- Track failures per alt
			notifiedAlts = {},  -- Track which alts we've notified about
		},
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

	if not self.db.faction[name].alts[player] then
		return
	end

	self.db.faction[name].alts[player] = {}

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

	if not db.requestsVersion then
		db.requestsVersion = 0
	end

	if not db.requestsTombstones then
		db.requestsTombstones = {}
	end

	-- Initialize delta sync fields if missing
	if not db.guildProtocolVersions then
		db.guildProtocolVersions = {}
	end
	if not db.deltaMetrics then
		db.deltaMetrics = {
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
		}
	end
	if not db.deltaErrors then
		db.deltaErrors = {
			lastErrors = {},
			failureCounts = {},
			notifiedAlts = {},
		}
	end

	-- Migrate old alt data structures from pre-v0.8 saves (no-ops for v0.9.6+ users)
	C_Timer.After(0.5, function()
					-- Characters scanned before v0.6.0 may have bank/bags without slots
		if db.alts then
			for name, alt in pairs(db.alts) do
				if type(alt) == "table" then
					if alt.bank and not alt.bank.slots then
						alt.bank.slots = { count = 0, total = 0 }
					TOGBankClassic_Output:Debug("DATABASE", "MIGRATE", "Migrated alt data: initialized bank.slots for %s", name)
					end
					if alt.bags and not alt.bags.slots then
						alt.bags.slots = { count = 0, total = 0 }
					TOGBankClassic_Output:Debug("DATABASE", "MIGRATE", "Migrated alt data: initialized bags.slots for %s", name)
					end

					-- This enables pull-based protocol for existing alt data
					if not alt.inventoryHash and alt.bank and alt.bags then
						local money = alt.money or 0
						alt.inventoryHash = TOGBankClassic_Core:ComputeInventoryHash(alt.bank, alt.bags, money)
					TOGBankClassic_Output:Debug("DATABASE", "MIGRATE", "Migrated alt data: computed inventory hash for %s (hash=%08x)", name, alt.inventoryHash)
					end

					if alt.inventoryHash and not alt.inventoryUpdatedAt then
						alt.inventoryUpdatedAt = alt.version or GetServerTime()
						TOGBankClassic_Output:Debug("DATABASE", "MIGRATE", "Migrated alt data: backfilled inventoryUpdatedAt for %s (ts=%s)", name, tostring(alt.inventoryUpdatedAt))
					end
				end
			end
		end
	end)
	if not db.requestsTombstones then
		db.requestsTombstones = {}
	end

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

	-- Initialize delta sync fields if not present
	if not db.guildProtocolVersions then
		db.guildProtocolVersions = {}
	end
	if not db.deltaMetrics then
		db.deltaMetrics = {
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
		}
	end
	if not db.deltaErrors then
		db.deltaErrors = {
			lastErrors = {},
			failureCounts = {},
			notifiedAlts = {},
		}
	end

	return db
end

-- Snapshot Management Functions

-- Save a snapshot of alt data for future delta computation
-- PERF-012: Uses in-memory cache only — not persisted to SavedVariables
function TOGBankClassic_Database:SaveSnapshot(name, altName, altData)
	if not name or not altName or not altData then
		return false
	end

	if not deltaSnapshotsCache[name] then
		deltaSnapshotsCache[name] = {}
	end

	-- Create a deep copy with timestamp
	deltaSnapshotsCache[name][altName] = {
		data = TOGBankClassic_Database:DeepCopy(altData),
		timestamp = GetServerTime(),
	}

	return true
end

-- Retrieve a snapshot of alt data for delta computation
-- PERF-012: Uses in-memory cache only — not persisted to SavedVariables
function TOGBankClassic_Database:GetSnapshot(name, altName)
	if not name or not altName then
		return nil
	end

	local cache = deltaSnapshotsCache[name]
	if not cache then
		return nil
	end

	local snapshot = cache[altName]
	if not snapshot then
		return nil
	end

	-- Check if snapshot is still valid (not too old)
	local age = GetServerTime() - (snapshot.timestamp or 0)
	if age > PROTOCOL.DELTA_SNAPSHOT_MAX_AGE then
		-- Snapshot expired, remove it
		cache[altName] = nil
		return nil
	end

	-- Validate snapshot structure
	if not self:ValidateSnapshot(snapshot.data) then
		-- Corrupted snapshot, remove it
		cache[altName] = nil
		return nil
	end

	return snapshot.data
end

-- Validate snapshot structure
function TOGBankClassic_Database:ValidateSnapshot(snapshot)
	if not snapshot or type(snapshot) ~= "table" then
		return false
	end

	-- Check required fields
	if not snapshot.version or type(snapshot.version) ~= "number" then
		return false
	end

	-- Validate bank structure if present
	if snapshot.bank then
		if type(snapshot.bank) ~= "table" then
			return false
		end
		if snapshot.bank.items and type(snapshot.bank.items) ~= "table" then
			return false
		end
	end

	-- Validate bags structure if present
	if snapshot.bags then
		if type(snapshot.bags) ~= "table" then
			return false
		end
		if snapshot.bags.items and type(snapshot.bags.items) ~= "table" then
			return false
		end
	end

	return true
end

-- Deep copy function for snapshot creation
function TOGBankClassic_Database:DeepCopy(obj)
	if type(obj) ~= "table" then
		return obj
	end

	local copy = {}
	for k, v in pairs(obj) do
		copy[k] = self:DeepCopy(v)
	end

	return copy
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
	for sender, info in pairs(db.guildProtocolVersions) do
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

	db.deltaMetrics = {
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
