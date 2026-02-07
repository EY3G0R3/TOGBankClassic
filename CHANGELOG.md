# TOGBankClassic Changelog

## [v0.8.9] (2026-02-07) - P2P Hash Backfill Complete

**Status:** Production Ready  
**Priority:** HIGH

### 🎯 P2P Hash Backfill Implementation

#### Core Features Implemented
- **NEW**: Banker HLR (hash list reply) stores authoritative hashes for all roster alts
- **NEW**: Version broadcasts store peer hashes when local hash is missing
- **NEW**: 3-minute rebroadcast timer requests hash list and rebroadcasts P2P for missing alts
- **FIXED**: /wipe now rebuilds banker roster immediately (progress shows 0/35 instead of 0/2)
- **FIXED**: Data payloads always use GUILD channel (removed WHISPER routing for togbank-d3/d4)
- **ENHANCED**: P2P broadcasts happen for both "pending" (hash mismatch) and "missingContent" (hash match, no data)

### 📝 Technical Details

**Hash Storage Priority System:**

1. **Primary: Banker HLR (togbank-hlr)** - Most authoritative
   - Banker has scanned all alts, provides definitive hash list
   - Stores hash+updatedAt for all roster alts immediately
   - Triggered on /sync, UI open, and every 3 minutes via timer
   - Implementation: Chat.lua lines 1476-1510

2. **Secondary: Peer Version Broadcasts (togbank-dv2)** - Supplemental
   - Fills gaps if HLR not received yet
   - Only stores hash if we don't have one (hash=0 or nil)
   - Implementation: Chat.lua lines 394-434

**Result:** After HLR, all 35 alts have authoritative hashes (pending=0)

**Files Changed:**
- `Modules/Chat.lua`:
  - Added hash storage in HLR handler (two-pass: store hashes, then compare)
  - Added hash storage in version broadcast handler (only if missing)
  - Added debug logging for pending/missingContent broadcasts
- `Modules/Guild.lua`:
  - Added `RebuildBankerRoster()` call to `Reset()` for immediate banker list after /wipe
  - Removed forceFull bypass logic (preserves P2P design)
  - Changed `SendAltData()` to always use GUILD channel for togbank-d3/d4
- `Modules/Events.lua`:
  - Added `RequestHashListFromBanker()` call to `OnShareTimer()` (3-minute rebroadcast)
- `Modules/DeltaComms.lua`:
  - Updated `FastFillMissingAlts()` to use P2P broadcasts when banker offline

**How It Works:**
1. **On /sync or UI open**: Request hash list from banker (togbank-hl)
2. **Banker replies**: Send all alt hashes via togbank-hlr
3. **Store hashes**: Create/update local alt stubs with banker's authoritative hash+updatedAt
4. **Compare**: Categorize as "pending" (hash mismatch) or "missingContent" (hash match, no data)
5. **Broadcast**: Send P2P requests to GUILD for missing alts with expectedHash
6. **Peers respond**: Players with matching hash send data via GUILD
7. **Fallback**: After 5s timeout, query banker directly via whisper
8. **Rebroadcast**: Every 3 minutes, repeat steps 1-7 for still-missing alts

**Design Principles:**
- Banker is authoritative source for hash list
- P2P broadcasts reduce banker load
- GUILD channel for data, WHISPER for handshakes
- Newest-wins conflict resolution using inventoryUpdatedAt timestamps

---

## [v0.8.4] (2026-02-02) - Mail Hash Synchronization Fix

**Status:** Critical Bug Fix  
**Priority:** HIGH

### 🐛 Critical Bug Fix

#### [MAIL-012] Mail Hash Never Set - Fixed Mail Synchronization
- **FIXED**: `mailHash` field was referenced but never assigned, breaking mail synchronization
- **ROOT CAUSE**: Mail scan created mail data but never computed hash for change detection
- **IMPACT**: Mail items never synchronized between clients via `/togbank share` or `/togbank sync`
- **FIX**: 
  - `Bank.lua` now computes `mailHash` after mail scan using `ComputeInventoryHash()`
  - `DeltaComms.lua` tracks `mailHash` changes in delta computation
  - `DeltaComms.lua` applies `mailHash` changes when receiving deltas
  - `DeltaComms.lua` recognizes `mailHash` as a valid change type
- **RESULT**: Mail data now properly syncs between guild members
- **LOGGING**: Added `[MAIL-012]` debug markers for mail hash operations

### 📝 Technical Details

**Files Changed:**
- `Modules/Bank.lua` - Added mailHash computation after mail scan (lines 289-310)
- `Modules/DeltaComms.lua` - Track mailHash in ComputeDelta() (lines 533-545)
- `Modules/DeltaComms.lua` - Apply mailHash in ApplyDelta() (lines 806-810)
- `Modules/DeltaComms.lua` - Recognize mailHash in DeltaHasChanges() (lines 590-593)
- `docs/DELTA_BUGS.md` - Comprehensive bug documentation with root cause analysis

**How It Works:**
1. When mail is scanned, `mailHash` is computed from `alt.mail.items`
2. `mailHash` changes trigger version updates in deltas
3. Receivers see `mailHash` and know mail data is "new format" (not legacy)
4. Clients can detect mail changes and request updates
5. Backward compatible: clients without `mailHash` still treated as "old format"

---

## [v0.8.0] (2026-01-21) - Pull-Based Delta Protocol

**Branch:** feature/pull-based-delta  
**Status:** Testing Phase  
**Latest Update:** 2026-01-21 (Evening)

### 🚀 Major Features

#### Pull-Based Protocol with Inventory Hashing
- **NEW**: Hash-based inventory comparison replaces version timestamps
- **NEW**: Automatic pull sync when inventory hashes differ
- **NEW**: Dual broadcast system (`togbank-v` + `togbank-dv`) for compatibility
- **NEW**: `/togbank share` command broadcasts version data with hashes
- **NEW**: Selective querying - only request data when hashes mismatch
- **NEW**: Data migration system computes hashes for existing alts on load
- **NEW**: Fast-fill feature - automatically requests missing banker alts when UI opens or `/togbank sync` is used
- **NEW**: Smart message prioritization - NORMAL priority for reliable delivery
- **NEW**: Communication debug filtering - Optional "(comm)" prefixed debug messages with separate toggle

#### Inventory Hashing System
- `ComputeInventoryHash()` generates numeric hash from bank + bags + money
- Hash computed automatically on bank scan (BANKFRAME_CLOSED event)
- Stored alongside version timestamp in `alt.inventoryHash` field
- More reliable than version timestamps for detecting real changes
- Minimal overhead (single number vs full data comparison)

#### Protocol Simplification
- **REMOVED**: Guild support threshold requirement (was 5% minimum)
- **NEW**: Delta protocol always enabled if `PROTOCOL.SUPPORTS_DELTA = true`
- **NEW**: Works immediately without waiting for guild adoption
- **SIMPLIFIED**: `ShouldUseDelta()` now only checks feature flags

#### Broadcast Enhancements
- **Version Broadcast (`togbank-v`)**: Legacy format with version timestamps only
- **Delta Version Broadcast (`togbank-dv`)**: New format with version + hash
- **Format**: `data.alts[name] = {version = X, hash = Y}`
- **Share Command**: Now sends BOTH broadcasts for maximum compatibility

#### Hash Comparison Logic
- Compares inventory hashes to detect changes
- **We have no data**: Query for everything
- **Hashes differ**: Query for update
- **Hashes match**: Skip query (no changes)
- **No hash available**: Fall back to version comparison
- Handles nil checks gracefully after database wipes

### 🐛 Bug Fixes

#### [SEARCH-003] Search Returning 0 Results
- **Fixed**: Search now correctly processes all aggregated items
- **Root Cause**: BuildSearchData was using `ipairs()` on hash table returned by `Aggregate()`
- **Solution**: Changed to `pairs()` for proper hash table iteration, fixed item counting
- **Impact**: Search functionality now works correctly for all item queries
- Location: Search.lua lines 405-410

#### Mail Data Persistence
- **Removed**: Unused `IsMailDataStale()` function and 1-hour staleness threshold
- **Change**: Mail data now persists indefinitely like bank/bags data
- **Impact**: Mail inventory remains visible regardless of age, with timestamp displayed for information
- Location: MailInventory.lua

#### [UI-002] Item Links Not Appearing After Integration
- **Fixed**: Items now display immediately after async item link reconstruction
- **Root Cause**: `ReconstructItemLinks()` was using async `Item:ContinueOnItemLoad()` callbacks without triggering UI refresh
- **Solution**: Added UI refresh calls after successful link reconstruction (both immediate and async)
- **Impact**: Items now appear in UI as soon as their links become available from WoW API
- Location: Guild.lua lines 970-995

#### [PROTO-001] Delta Validation
- **Fixed**: Delta validation now accepts link-less deltas without `baseVersion`
- Made `baseVersion` field optional in `ValidateDeltaStructure()`
- Maintains backwards compatibility with old protocol deltas
- Location: Core.lua line 118-122

#### [UI-001] Inventory UI Crash
- **Fixed**: UI handles missing `bank.slots` and `bags.slots` data
- Added defensive nil checks in Inventory.lua lines 177-187
- Data migration initializes missing slots fields with `{count = 0, total = 0}`
- Prevents crashes when opening UI with incomplete alt data

#### [DATA-001] Missing Inventory Hashes
- **Fixed**: Existing alt data migrated to include inventory hashes
- Migration runs once on addon load via `Database:InitializeDatabase()`
- Computes hashes from saved bank/bags/money data
- Successfully migrated 60+ existing alts in testing

#### Hash Comparison Edge Cases
- **Fixed**: Handles `nil` hash values after database wipe
- **Fixed**: Pull decision logic checks for missing data
- **Fixed**: Broadcasts send even when no alt data exists locally
- Debug output shows "has bank data for X (we have none), querying"

### 📝 Documentation Updates
- Updated DELTA_IMPLEMENTATION_TODO.md with current architecture
- Documented inventory hashing system and pull protocol flow
- Removed outdated guild support threshold documentation
- Added hash comparison algorithm documentation
- Updated bug tracker (DELTA_BUGS.md) with resolved issues

### 🔧 Technical Changes
- Guild.lua: Added dual broadcast to `Share()` function
- Guild.lua: `FastFillMissingAlts()` auto-requests missing banker alts (lines 458-498)
- Guild.lua: `ReconstructItemLinks()` now refreshes UI after async link loading (lines 970-1008)
- Events.lua: `SyncDeltaVersion()` uses NORMAL priority for reliable delivery (was BULK)
- Events.lua: Changed all query messages from BULK to NORMAL priority
- Chat.lua: Enhanced hash comparison logic with nil handling
- Chat.lua: Added UI auto-refresh when data adopted (togbank-d and togbank-d3 handlers)
- Chat.lua: `/togbank sync` command now also triggers fast-fill for missing alts
- Database.lua: Added hash migration for existing alts
- Database.lua: Added slots migration to prevent UI crashes
- Core.lua: Made baseVersion optional in delta validation
- UI/Inventory.lua: Calls `FastFillMissingAlts()` on Open() in delta mode (line 49)
- Output.lua: Added `DebugComm()` function for filterable communication debug logging
- Options.lua: Added `commDebug` toggle in config UI below log level

### 🎯 Performance Improvements
- Message priority optimization: Changed queries and delta broadcasts from BULK to NORMAL
- Improved responsiveness of pull-based protocol handshake
- Faster UI updates with async item link reconstruction
- Reduced query spam with fast-fill on-demand loading
- Communication debug filtering: Separate toggle for comm debug messages with "(comm)" prefix

### ⚠️ Breaking Changes
None - Full backwards compatibility maintained with v0.7.0 clients

---

## [v0.7.0](https://github.com/EY3G0R3/TOGBankClassic/tree/v0.7.0) (2025-01-17)

**Latest Update:** 2026-01-20 - Fixed error tracking issues

### 🐛 Bug Fixes (2026-01-20)

#### Error Tracking System
- **Fixed**: Error tracking now works even when Guild.Info is not initialized
  - Implemented temporary in-memory storage for errors occurring before guild initialization
  - Automatic migration to database when guild data loads
  - No error data loss during addon startup phase
  - Query functions check both temporary and database storage
  
- **Fixed**: `RecordDeltaError()` logs debug messages when using temporary storage
  - Shows: "Using temporary error storage for <alt> (<type>): Guild.Info not initialized"
  - Helps identify initialization timing issues
  
- **Fixed**: Test function `testDeltaErrorTracking()` parameter mismatch
  - Was calling `RecordDeltaError()` with 2 parameters instead of required 3
  - Now correctly passes: `altName`, `errorType`, `errorMessage`
  - Ensures proper error categorization in test suite

**Impact**: Error tracking is now fully functional throughout addon lifecycle, including early delta failures before guild initialization completes.

---

### 🚀 Major Features

#### Delta Sync Protocol
- **NEW**: Intelligent delta synchronization protocol reduces bandwidth by 90-99%
- **NEW**: Automatic protocol version negotiation between v0.6.8 and v0.7.0+ clients
- **NEW**: Smart snapshot management with automatic corruption recovery
- **NEW**: Comprehensive error handling with automatic full sync fallback
- **NEW**: Backward compatible with v0.6.8 clients (seamless mixed-guild support)

#### Bandwidth Optimization
- Only transmits changed items instead of entire inventories
- Automatic size comparison (uses delta only if <30% of full sync size)
- Estimated bandwidth savings: 90-99% for typical inventory updates
- Guild-wide adoption threshold (50%) ensures efficient operation

#### Performance Metrics
- Real-time bandwidth tracking (delta vs full sync)
- Performance monitoring (computation and application times)
- Success rate tracking with automatic failure detection
- Estimated bandwidth savings calculations

### ✨ New Commands

- `/togbank deltastats` - Display comprehensive delta sync statistics including:
  - Bandwidth usage breakdown (delta vs full syncs)
  - Estimated total bandwidth saved
  - Operation counts and success rates
  - Average performance metrics (computation/application times)

- `/togbank deltaerrors` - Show recent delta sync errors for debugging:
  - Last 10 errors with timestamps and error types
  - Failure counts per alt
  - Highlights alts with repeated failures (3+)
  - Persists across /reload

- `/togbank deltahistory` - Show stored delta chain history:
  - Delta storage per alt with version transitions
  - Change types and ages for each delta
  - Verifies chain replay infrastructure is working

- `/togbank protocol` - Show protocol version distribution:
  - Online member protocol versions (v1 vs v2)
  - All-time protocol adoption statistics
  - Delta sync enablement status with threshold indicator
  - Recently seen members with their protocol versions

- `/togbank clearsnapshots` - Clear all delta snapshots (forces next sync to be full)

- `/togbank forcefull` - Toggle forcing full sync mode (temporarily disables delta sync)

- `/togbank resetmetrics` - Reset all delta sync statistics to zero

### 🔧 Technical Improvements

#### Database Layer
- Added `deltaSnapshots` table for efficient snapshot storage (1-hour expiration)
- Added `guildProtocolVersions` table for peer protocol tracking
- Added `deltaMetrics` table for bandwidth and performance tracking
- Implemented snapshot validation and automatic corruption recovery
- Added 23 new database functions for delta operations

#### Guild Module
- Rewrote `SendAltData()` with intelligent protocol selection
- Implemented `ComputeDelta()` for efficient change detection
- Implemented `ApplyDelta()` with robust error handling
- Added error tracking system with repeated failure detection
- Enhanced debug output with detailed size and timing information

#### Communication Layer
- Registered new `togbank-d2` prefix for delta protocol
- Enhanced version broadcast to include protocol capabilities
- Added delta structure validation before application
- Implemented automatic QueryAlt on all failure paths

#### Error Handling & Recovery
- 6 error detection points covering all failure scenarios
- Automatic full sync fallback on any delta failure
- Per-alt failure tracking with user notification (after 3 consecutive failures)
- Automatic failure count reset on successful sync
- Snapshot corruption detection and automatic purge

### 📊 Monitoring & Visibility

#### Enhanced Debug Output
- Delta selection logging with size comparisons and savings calculations
- Performance timing for all delta operations
- Color-coded status indicators (✓/✗) for quick visual parsing
- Detailed error messages with context for troubleshooting

#### Statistics Display
- Bandwidth metrics with color-coded percentages
- Success rate with threshold-based coloring (green ≥95%, yellow ≥80%, red <80%)
- Performance averages for computation and application
- Protocol adoption visualization

### 🧪 Testing & Quality

- Created comprehensive test module with 30+ unit tests
- Test coverage for delta computation, size estimation, protocol negotiation
- Error handling tests for all failure scenarios
- Integration tests for full delta roundtrip
- Backwards compatibility tests for v0.6.8 mixed guilds

### 📝 Documentation

- Added comprehensive README.txt with all commands and features
- Updated installation instructions with CurseForge App (recommended) method
- Added troubleshooting section specific to delta sync issues
- Created detailed DELTA_IMPLEMENTATION_TODO.md documenting all phases
- Added FEATURE_IMPROVEMENTS.md with technical architecture

### 🔄 Protocol Specifications

#### Version 2 Features
- Protocol version: 2
- Supports delta updates: Yes
- Delta size threshold: 30% of full sync
- Snapshot max age: 1 hour
- Guild adoption threshold: 50%

#### Backwards Compatibility
- v0.7.0+ ↔ v0.7.0+: Delta sync via `togbank-d2` (when threshold met)
- v0.7.0+ ↔ v0.6.8: Full sync via `togbank-d` (automatic fallback)
- v0.6.8 ↔ v0.6.8: Full sync via `togbank-d` (unchanged)
- No breaking changes - seamless upgrade path

### 🐛 Bug Fixes

- Fixed potential race conditions in snapshot management
- Improved error messages for version mismatch scenarios
- Enhanced validation to prevent corrupted delta application
- Added nil checks throughout delta codepaths

### ⚙️ Configuration

New constants in `Modules/Constants.lua`:
```lua
PROTOCOL = {
    VERSION = 2,
    SUPPORTS_DELTA = true,
    MIN_DELTA_SIZE_RATIO = 0.3,     -- 30% threshold
    DELTA_SNAPSHOT_MAX_AGE = 3600,  -- 1 hour
    DELTA_SUPPORT_THRESHOLD = 0.5,  -- 50% adoption
}

FEATURES = {
    DELTA_ENABLED = true,           -- Master enable/disable
    FORCE_FULL_SYNC = false,        -- Force full sync for testing
}
```

### 📈 Performance Impact

- **Bandwidth Reduction**: 90-99% for typical inventory updates
- **Computation Overhead**: ~2-3ms average per delta computation
- **Application Overhead**: ~1-2ms average per delta application
- **Memory Impact**: Minimal (~50KB per snapshot, auto-expiring)

### 🔮 Known Limitations

- Delta sync requires 50%+ of online guild to use v0.7.0+ for enablement
- Snapshots expire after 1 hour (forces full sync on first update after expiration)
- Large inventory changes (>30% of items) automatically fall back to full sync
- Options panel GUI for delta configuration deferred to future update

---

## [v2.3.0](https://github.com/GrumpyPlayer/GBankClassic/tree/v2.3.0) (2025-10-27)
[Full Changelog](https://github.com/GrumpyPlayer/GBankClassic/compare/v2.2.0...v2.3.0) [Previous Releases](https://github.com/GrumpyPlayer/GBankClassic/releases)

- Merge pull request #3 from GrumpyPlayer/merge/fix-search-normalization-into-handle-malformed-data  
    Merge/fix search normalization into handle malformed data  
- fix issues related to clean-up and init, and also allow GM to author /bank roster updates  
- Merge PR #1 (fix-search-normalization) into integration branch  
- Perform cleanup of malformed data on addon initialization and handle malformed data better  
- Fix nil version comparison in ReceiveAltData  
    - Added nil check for existing alt data version before comparison  
    - Prevents 'attempt to compare number with nil' error  
    - Fixes crash when receiving data for alts without version field  
- Fix Search.lua crash and implement name normalization with security improvements  
    - Fixed nil table index crash in Search.lua duplicate detection  
    - Added NormalizePlayerName helper for consistent 'Name-Realm' format  
    - Implemented sender authentication to prevent communication spoofing  
    - Added debug tools: /bank debug toggle and /bank debugdump command  
    - Auto-enable bank reporting for detected bank characters  
    - Relaxed delegation policy for multi-bank account support  
    - Normalized player keys across all modules for data consistency  
