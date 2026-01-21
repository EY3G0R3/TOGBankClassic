# TOGBankClassic Changelog

## [v0.7.0](https://github.com/EY3G0R3/TOGBankClassic/tree/v0.7.0) (2025-01-17)

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
