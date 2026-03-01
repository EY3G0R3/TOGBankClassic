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
end

function TOGBankClassic_Database:Reset(name)
	if not name then
		return
	end

	-- PERF-012: Clear in-memory snapshot cache for this guild on reset
	deltaSnapshotsCache[name] = nil

	---START CHANGES
	--self.db.factionrealm[name] = {
	self.db.faction[name] = {
		---END CHANGES
		name = name,
		roster = {},
		alts = {},
		requests = {},
		requestsVersion = 0,
		requestsTombstones = {},
		settings = {
			maxRequestPercent = 100,  -- Default to no limit
		},
		-- Delta sync fields
		-- PERF-012: deltaSnapshots moved to in-memory deltaSnapshotsCache (not persisted)
		-- PERF-012: deltaHistory removed — delta chain replay dead code since v0.8.0
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

	---START CHANGES
	--if not self.db.factionrealm[name].alts[player] then return end
	if not self.db.faction[name].alts[player] then
		return
	end

	--self.db.factionrealm[name].alts[player] = {}
	self.db.faction[name].alts[player] = {}
	---END CHANGES

	TOGBankClassic_Output:Response("Reset Player Database")
end

function TOGBankClassic_Database:Load(name)
	if not name then
		return
	end

	---START CHANGES
	--local db = self.db.factionrealm[name]
	local db = self.db.faction[name]
	---END CHANGES

	-- Only reset if there's truly no data (nil). Otherwise initialize missing fields.
	-- This prevents data loss when some fields are missing but others (like requests) exist.
	if db == nil then
		TOGBankClassic_Database:Reset(name)
		---START CHANGES
		--db = self.db.factionrealm[name]
		db = self.db.faction[name]
		---END CHANGES
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

	-- PERF-010: Defer data migrations to prevent login freeze
	-- Looping through 70+ alts with RecalculateAggregatedItems blocks UI for 3-5 seconds
	-- Migrations don't need to be immediate - data already loaded from SavedVariables
	C_Timer.After(0.5, function()
		-- v0.8.0: Migrate old alt data to ensure slots fields exist
		-- Characters scanned before v0.6.0 may have bank/bags without slots
		if db.alts then
			for name, alt in pairs(db.alts) do
				if type(alt) == "table" then
					if alt.bank and not alt.bank.slots then
						alt.bank.slots = { count = 0, total = 0 }
					TOGBankClassic_Output:Debug("DATABASE", "Migrated alt data: initialized bank.slots for %s", name)
					end
					if alt.bags and not alt.bags.slots then
						alt.bags.slots = { count = 0, total = 0 }
					TOGBankClassic_Output:Debug("DATABASE", "Migrated alt data: initialized bags.slots for %s", name)
					end
					-- v0.8.0: Compute inventory hash for alts that don't have one
					-- This enables pull-based protocol for existing alt data
					if not alt.inventoryHash and alt.bank and alt.bags then
						local money = alt.money or 0
						alt.inventoryHash = TOGBankClassic_Core:ComputeInventoryHash(alt.bank, alt.bags, money)
					TOGBankClassic_Output:Debug("DATABASE", "Migrated alt data: computed inventory hash for %s (hash=%d)", name, alt.inventoryHash)
					end
					-- v0.8.7: Backfill inventoryUpdatedAt for alts that have hashes but no timestamp
					if alt.inventoryHash and not alt.inventoryUpdatedAt then
						alt.inventoryUpdatedAt = alt.version or GetServerTime()
						TOGBankClassic_Output:Debug("DATABASE", "Migrated alt data: backfilled inventoryUpdatedAt for %s (ts=%s)", name, tostring(alt.inventoryUpdatedAt))
					end
					-- Recalculate aggregated items from bank/bags/mail with corrected Aggregate function
					-- This fixes item count duplication without requiring a full scan
					-- AGGRESSIVE FIX: Clear and rebuild alt.items on every load to prevent accumulation
					if (alt.bank and alt.bank.items) or (alt.bags and alt.bags.items) or (alt.mail and alt.mail.items) then
						-- Banker alt with bank/bags - FORCE reconstruct from sources
						-- DEBUG: Log sample counts BEFORE clearing
						if alt.items and #alt.items > 0 then
							local beforeSample = {}
							for i = 1, math.min(5, #alt.items) do
								local item = alt.items[i]
								if item then
									table.insert(beforeSample, string.format("%s:%d", item.ID or "?", item.Count or 0))
								end
							end
							TOGBankClassic_Output:Debug("DATABASE", "BEFORE clear - Banker %s alt.items: %s", name, table.concat(beforeSample, ", "))
						end

						alt.items = nil  -- Clear corrupted data
						TOGBankClassic_Bank:RecalculateAggregatedItems(alt)

						-- DEBUG: Log sample counts AFTER recalculation
						if alt.items and #alt.items > 0 then
							local afterSample = {}
							for i = 1, math.min(5, #alt.items) do
								local item = alt.items[i]
								if item then
									table.insert(afterSample, string.format("%s:%d", item.ID or "?", item.Count or 0))
								end
							end
							TOGBankClassic_Output:Debug("DATABASE", "AFTER recalc - Banker %s alt.items: %s", name, table.concat(afterSample, ", "))
						end

						-- Recompute inventory hash using SYNC-006 path (same as Bank:Scan) so
						-- the stored hash matches what Bank:Scan() produces.  The old migration
						-- path used pre-SYNC-006 (ComputeInventoryHash(bank, bags, money)) which
						-- hashes bank.items+bags.items separately; Bank:Scan uses SYNC-006
						-- (ComputeInventoryHash(items, nil, nil, money)) which hashes the
						-- aggregated array.  Different inputs → different hash → false "inventory
						-- changed" on every startup until the first real scan fixed it.
						if alt.items then
							local money = alt.money or 0
							local syncHash = TOGBankClassic_Core:ComputeInventoryHash(alt.items, nil, nil, money)
							if syncHash ~= alt.inventoryHash then
								alt.inventoryHash = syncHash
								TOGBankClassic_Output:Debug("DATABASE", "Migrated alt data: corrected inventory hash for %s to SYNC-006 format (hash=%d)", name, syncHash)
							end
						end

						TOGBankClassic_Output:Debug("DATABASE", "FORCED recalculation for banker %s from bank/bags/mail", name)
					elseif alt.items then
						-- Synced alt - FORCE deduplicate
						-- NOTE: Do NOT merge mail here - alt.items from sync already includes mail from sender's scan
						local aggregated = TOGBankClassic_Item:Aggregate(alt.items, nil)
						alt.items = {}
						for _, item in pairs(aggregated) do
							table.insert(alt.items, item)
						end
						TOGBankClassic_Output:Debug("DATABASE", "FORCED deduplication for synced alt %s: %d items", name, #alt.items)
					end
				end
			end
		end
		TOGBankClassic_Output:Debug("DATABASE", "Completed deferred data migrations")
	end)
	if not db.requestsTombstones then
		db.requestsTombstones = {}
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

-- Get the age of a snapshot in seconds
-- PERF-012: Uses in-memory cache only
function TOGBankClassic_Database:GetSnapshotAge(name, altName)
	if not name or not altName then
		return nil
	end

	local cache = deltaSnapshotsCache[name]
	if not cache then
		return nil
	end

	local snapshot = cache[altName]
	if not snapshot or not snapshot.timestamp then
		return nil
	end

	return GetServerTime() - snapshot.timestamp
end

-- Clean up old snapshots (older than DELTA_SNAPSHOT_MAX_AGE)
-- PERF-012: Uses in-memory cache only
function TOGBankClassic_Database:CleanupOldSnapshots(name)
	if not name then
		return 0
	end

	local cache = deltaSnapshotsCache[name]
	if not cache then
		return 0
	end

	local currentTime = GetServerTime()
	local removed = 0

	for altName, snapshot in pairs(cache) do
		if snapshot and snapshot.timestamp then
			local age = currentTime - snapshot.timestamp
			if age > PROTOCOL.DELTA_SNAPSHOT_MAX_AGE then
				cache[altName] = nil
				removed = removed + 1
			end
		else
			-- Malformed snapshot, remove it
			cache[altName] = nil
			removed = removed + 1
		end
	end

	return removed
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

-- Delta History Management (DELTA-006: Delta Chain Replay)

-- PERF-012: SaveDeltaHistory is a no-op. Delta chain replay was only triggered by
-- deltaData.baseVersion which v0.8.0 stopped sending. GetDeltaHistory/togbank-dr/togbank-dc
-- callers are all dead code. Keeping the function stub so Chat.lua compile-time refs are safe.
function TOGBankClassic_Database:SaveDeltaHistory(name, altName, baseVersion, version, delta)
	-- No-op: delta chain replay is dead code since v0.8.0
	return false
end

-- Get delta history for an alt within a version range
function TOGBankClassic_Database:GetDeltaHistory(name, altName, fromVersion, toVersion)
	if not name or not altName then
		return nil
	end

	local db = self.db.faction[name]
	if not db or not db.deltaHistory or not db.deltaHistory[altName] then
		return nil
	end

	-- Build chain of deltas from fromVersion to toVersion
	local chain = {}
	local currentVersion = fromVersion

	for _, deltaEntry in ipairs(db.deltaHistory[altName]) do
		if deltaEntry.baseVersion == currentVersion and deltaEntry.version <= toVersion then
			table.insert(chain, {
				baseVersion = deltaEntry.baseVersion,
				version = deltaEntry.version,
				delta = deltaEntry.delta
			})
			currentVersion = deltaEntry.version

			-- Stop if we've reached the target
			if currentVersion == toVersion then
				break
			end
		end
	end

	-- Return nil if we couldn't build a complete chain
	if currentVersion ~= toVersion then
		return nil
	end

	return chain
end

-- Clean up old delta history (older than DELTA_HISTORY_MAX_AGE)
function TOGBankClassic_Database:CleanupDeltaHistory(name)
	if not name then
		return 0
	end

	local db = self.db.faction[name]
	if not db or not db.deltaHistory then
		return 0
	end

	local currentTime = GetServerTime()
	local maxAge = PROTOCOL.DELTA_HISTORY_MAX_AGE or 3600
	local totalRemoved = 0

	for altName, history in pairs(db.deltaHistory) do
		if type(history) == "table" then
			-- Remove old entries
			local i = 1
			while i <= #history do
				if history[i] and history[i].timestamp then
					local age = currentTime - history[i].timestamp
					if age > maxAge then
						table.remove(history, i)
						totalRemoved = totalRemoved + 1
					else
						i = i + 1
					end
				else
					-- Malformed entry
					table.remove(history, i)
					totalRemoved = totalRemoved + 1
				end
			end

			-- Remove empty histories
			if #history == 0 then
				db.deltaHistory[altName] = nil
			end
		end
	end

	return totalRemoved
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
