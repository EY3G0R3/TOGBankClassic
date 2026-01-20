# DELTA-006: Delta Chain Replay for Offline Players

**This content should be inserted into DELTA_BUGS.md between SCAN-001 and DELTA-004**

---

#### 🔴 [DELTA-006] Delta rejection without recovery for offline players (version mismatch gap)

**Severity:** 🔴 CRITICAL  
**Category:** Protocol / Delta Application  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-20  
**Status:** Open - Needs Implementation  
**Assigned To:** Development Team

**Description:**
Delta sync requires EXACT version matching. When a player is offline and misses updates, they have an old version and ALL subsequent deltas are rejected. The auto-recovery system (query for full sync) fails silently, leaving the player permanently out of sync until manual intervention.

This breaks the fundamental use case: **Players who go offline should be able to sync when they return.**

**Impact:**
- **CRITICAL:** Delta sync completely non-functional for offline players
- Every delta rejection triggers full sync fallback, negating bandwidth savings
- Auto-recovery (`togbank-r` query) appears broken - full sync never arrives
- Players stay permanently out of sync after missing ONE update
- Affects EVERY player who logs in after banker makes updates

**Steps to Reproduce:**
1. Galdof (receiver) has Metals data at version `v1768949336`
2. Galdof goes offline (logs out or AFK)
3. Metals (banker) makes updates over 15 minutes → version `v1768950207`
4. Galdof comes back online
5. Metals sends delta: `baseVersion=1768950207, version=1768950250`
6. Galdof rejects: "Version mismatch for Metals-Azuresong (have 1768949336, delta expects 1768950207)"
7. Galdof sends query: `< togbank-r (Query) to Guild (53 bytes)`
8. **Full sync never arrives** (recovery failed)
9. Galdof remains out of sync, bracer item not visible in UI

**Expected Behavior (Current - Broken):**
```
Delta rejected → Query for full sync → Metals responds → Full sync applied → Synced
```

**Actual Behavior:**
```
Delta rejected → Query sent → No response → Permanently out of sync
```

**Root Cause:**
1. **Strict version matching**: Delta requires `currentVersion == baseVersion` (zero tolerance)
2. **Recovery failure**: `togbank-r` query broadcast appears unreliable (sender auth? timing?)
3. **No delta chain**: Sender doesn't store intermediate deltas to replay missed updates

**Proposed Solution - Delta Chain Replay:**

Instead of falling back to full sync, implement delta chain replay to gracefully handle offline players.

**Architecture:**
1. **Sender stores delta history**: Keep last 10 deltas per alt (configurable)
2. **New protocol**: `togbank-dr` (Delta Range Request)
3. **Version gap detection**: Receiver detects version mismatch, calculates gap
4. **Chain request**: Request all deltas from oldVersion → newVersion
5. **Sequential application**: Apply deltas in order to catch up

**Example Flow:**
```lua
-- Sender (Metals) delta history:
deltaHistory["Metals-Azuresong"] = {
  {baseVersion=100, version=105, delta={bank:{modified:[...]}}},  -- Update 1
  {baseVersion=105, version=110, delta={bags:{added:[...]}}},     -- Update 2
  {baseVersion=110, version=115, delta={money:5000}}              -- Update 3
}

-- Receiver (Galdof) has v100, receives delta expecting v115:
1. Detect mismatch: have=100, need=115
2. Send: togbank-dr request for range [100, 115]
3. Metals sends 3 deltas (still smaller than full sync)
4. Galdof applies sequentially:
   v100 + delta1 → v105
   v105 + delta2 → v110
   v110 + delta3 → v115
5. ✓ Synced! Bandwidth: ~900 bytes vs ~1800 bytes full
```

**Benefits:**
- ✅ Works for offline players (most common scenario)
- ✅ Still bandwidth-efficient (chain < full sync)
- ✅ Automatic recovery without manual intervention
- ✅ Graceful degradation (falls back to full if gap too large)

**Implementation Requirements:**

**Database.lua:**
```lua
SaveDeltaHistory(guildName, altName, baseVersion, version, delta)
GetDeltaHistory(guildName, altName, fromVersion, toVersion) → delta[]
CleanupDeltaHistory(guildName) -- Remove deltas older than 1 hour
```

**Constants.lua:**
```lua
DELTA_HISTORY_MAX_COUNT = 10      -- Keep last N deltas per alt
DELTA_HISTORY_MAX_AGE = 3600      -- Purge deltas older than 1 hour (1 hour)
DELTA_CHAIN_MAX_HOPS = 10         -- Max deltas in one chain (prevent abuse)
DELTA_CHAIN_MAX_SIZE = 5000       -- If chain > 5KB, use full sync instead
```

**Guild.lua:**
```lua
-- Sender side
SendAltData(name)
  → ComputeDelta() → SaveDeltaHistory() → Send delta

-- Receiver side
ApplyDelta(name, deltaData)
  → if version mismatch:
       → RequestDeltaChain(fromVersion, toVersion)
       → Receive chain → ApplyDeltaChain()
```

**Chat.lua:**
```lua
RegisterComm("togbank-dr") -- Delta Range Request handler
  → GetDeltaHistory(fromVersion, toVersion) → Send chain via togbank-dc
```

**New Protocol Messages:**
- `togbank-dr` (Delta Range Request): `{altName, fromVersion, toVersion}`
- `togbank-dc` (Delta Chain): `{altName, deltas: [{baseVersion, version, delta}]}`

**Fallback Rules:**
1. If delta chain > 10 hops → full sync
2. If total chain size > 5KB → full sync
3. If any delta missing in history → full sync
4. If chain application fails → full sync
5. Cleanup old deltas (>1 hour) to prevent memory growth

**Files Affected:**
- `Modules/Database.lua` (delta history storage - 3 new functions)
- `Modules/Guild.lua` (chain request/application logic - RequestDeltaChain, ApplyDeltaChain)
- `Modules/Chat.lua` (togbank-dr and togbank-dc handlers)
- `Modules/Constants.lua` (4 new configuration constants)
- `Core.lua` (register togbank-dr and togbank-dc prefixes)

**Priority:**
Critical - Blocks delta sync for offline players (primary use case)

**Workaround:**
Manual `/togbank share` from banker after player returns online forces full sync.

**Notes:**
- Delta chain replay is industry-standard pattern (Git, databases, event sourcing)
- Bandwidth still better than full sync: 3 deltas (~900B) vs full (~1800B)
- History cleanup prevents unbounded memory growth
- Chain validation ensures data integrity (each delta checks baseVersion)
- Related to UI-001 debugging exposed version mismatch scenarios

---
