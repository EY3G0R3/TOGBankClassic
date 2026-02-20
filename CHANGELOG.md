# TOGBankClassic Changelog

## Unreleased - Hash Sync Fixes

**Status:** In Development
**Priority:** CRITICAL

### 🐛 Bug Fixes

#### [HASH-001] Fixed Hash Broadcast Not Triggering P2P Requests (CRITICAL)
- **FIXED**: hash-list-broadcast handler now triggers P2P requests for changed data
- **PROBLEM**: `/togbank share` only updated latestBankerHashes cache without triggering any data requests
- **IMPACT**: Complete sync failure - receivers saw "Updated banker hashes" but never requested changed data
- **BEHAVIOR**: Users had to manually run `/togbank sync` or wait 3 minutes for auto-sync timer
- **ROOT CAUSE**: hash-list-broadcast (togbank-hl) only cached hashes, while hash-list-reply (togbank-hlr) also compared and broadcast P2P
- **INCONSISTENCY**: Same data (hash updates) handled differently depending on source (broadcast vs reply)
- **SOLUTION**:
  - hash-list-broadcast handler updates latestBankerHashes cache (immediate)
  - Converts message to hash-list-reply format
  - Recursively calls OnCommReceived with "togbank-hlr" prefix to reuse existing logic
  - hash-list-reply handler now updates cache incrementally (not replacement) to support partial broadcasts
  - Avoids code duplication - single code path for all hash processing
- **RESULT**: `/togbank share` now triggers immediate P2P broadcasts, data syncs automatically
- **LOCATION**: `Modules/Chat.lua` (~1773-1800, ~1816-1828): Forward broadcast to reply handler, incremental cache update
- **NOW**: Hash broadcasts work identically whether from `/togbank share` (broadcast) or `/togbank sync` (reply)

#### [COMM-003] Fixed Offline Player Detection from Whisper Errors
- **FIXED**: CHAT_MSG_SYSTEM now detects "No player named X is currently playing" errors
- **PROBLEM**: Addon repeatedly attempted whispers to offline players causing error spam
- **ROOT CAUSE**: CHAT_MSG_SYSTEM handler only detected "has gone offline" but not whisper failure errors
- **IMPACT**: Hundreds of error messages when trying to communicate with offline players
- **SOLUTION**:
  - Added pattern matching for "No player named X is currently playing" in CHAT_MSG_SYSTEM
  - When detected, immediately marks player as offline in both onlineMembers and recentlySeen caches
  - Updated UpdateOnlineMember() to clear recentlySeen cache when marking offline
  - Added debug logging for all online/offline state changes
- **RESULT**: Player marked offline immediately when whisper fails, preventing repeat attempts
- **LOCATION**: 
  - Events.lua CHAT_MSG_SYSTEM (~334-375): Added error pattern detection
  - Guild.lua UpdateOnlineMember (~1425-1443): Clear recentlySeen on offline

#### [COMM-003b] Fixed Whisper Error Pattern Not Matching Single-Quoted Names
- **FIXED**: CHAT_MSG_SYSTEM now detects both single-quoted and unquoted variants of whisper failure messages
- **PROBLEM**: Pattern only matched `No player named Axkva is currently playing.` but Classic Era can also send `No player named 'Axkva' is currently playing.` (with single quotes around name)
- **ROOT CAUSE**: COMM-003 documentation incorrectly stated "Classic Era does NOT use quotes" but testing showed single quotes are sometimes used around player names
- **IMPACT**: Whisper failures with single-quoted names not detected, causing repeated whisper attempts and error spam
- **SOLUTION**:
  - Added dual pattern matching: tries single-quoted pattern `'(.+)'` first, falls back to unquoted `(.+)` if no match
  - Updated documentation to reflect both formats are possible
- **RESULT**: All whisper failure formats now detected, player marked offline immediately
- **LOCATION**: 
  - Events.lua CHAT_MSG_SYSTEM (~353-361): Dual pattern matching
  - DELTA_BUGS.md (~2521-2527): Updated pattern documentation

#### [DELTA-020] Fixed Delta Computation Using Wrong Baseline (CRITICAL)
- **FIXED**: ComputeDelta now uses requester's actual item structures from state summary instead of responder's snapshot
- **PROBLEM**: When responder broadcast multiple times (hash 461905621 → 317352773), GetSnapshot returned responder's NEW snapshot (317352773) instead of requester's OLD baseline (461905621)
- **IMPACT**: Item count duplication/corruption - delta computed as (317352773 - 317352773) = empty/minimal instead of (317352773 - 461905621) = proper changes
- **BEHAVIOR**: Requester with hash 461905621 applied incorrect delta to their old data, causing items to double instead of updating
- **ROOT CAUSE**: 
  - Snapshot system stores ONE snapshot per alt (keyed only by altName, not hash)
  - When responder broadcasts twice, old snapshot overwritten (461905621 deleted, only 317352773 remains)
  - State summary previously sent aggregated items `{[itemID] = count}` (useless for delta computation)
  - ComputeDelta used GetSnapshot(altName) which returned responder's OWN latest state, not requester's actual baseline
- **DESIGN ISSUE**: Delta needs requester's actual item structure (bank/bags/mail) to compute `delta = current - requester's baseline`
- **SOLUTION**:
  1. Modified ComputeStateSummary to send minimal item structures `{ID, Count}` (no Links) for separate bank/bags/mail arrays
  2. Modified ComputeDelta to accept optional `requesterBaseline` parameter with minimal structures
  3. ComputeDelta now uses requester's sent baseline as `previous` instead of GetSnapshot when available
  4. RespondToStateSummary extracts bank/bags/mail from state summary and passes through SendAltData → ComputeDelta chain
  5. SendAltData signature updated to accept and forward requesterBaseline parameter
  6. All SendAltData call sites updated to pass baseline (or nil for legacy paths)
- **BANDWIDTH SAVINGS**: Minimal structures ~1-2KB vs full with Links ~20-50KB (~85% reduction)
- **RESULT**: Delta computation uses correct baseline - requester's actual data (what they have) vs responder's current (what to send)
- **LOCATIONS**:
  - Guild.lua ComputeStateSummary (~1485-1542): Send bank/bags/mail arrays with {ID, Count} only
  - Guild.lua SendStateSummary (~1593-1606): Updated logging to count bank+bags+mail items
  - Guild.lua RespondToStateSummary (~1640-1644): Extract requesterBaseline from state summary
  - Guild.lua SendAltData (~2231, ~2301): Added requesterBaseline parameter
  - Guild.lua ComputeDelta wrapper (~2862): Pass through requesterBaseline
  - DeltaComms.lua ComputeDelta (~565-620): Accept requesterBaseline, use expandMinimalItems() helper, compute from requester's actual data
- **NOW**: Proper delta application - item counts update correctly without duplication, works regardless of how many broadcasts requester missed
- **RELATED**: Completes DELTA-019 fix - hash stays at local value until correct delta (computed from actual baseline) received and applied

#### [DELTA-019] Fixed Premature Hash Update Before Data Received (CRITICAL)
- **FIXED**: Removed HLR first pass branch that updated hash when `localHash == 0`
- **PROBLEM**: Hash updated from banker's broadcast before delta data arrived and was applied
- **IMPACT**: Data/hash desynchronization - old data stored with new hash value
- **BEHAVIOR**: User has hash 529743613 with data, banker broadcasts 461905621, hash immediately updates to 461905621 but old data remains
- **CONSEQUENCE**: Future sync attempts see matching hashes and skip update, leaving permanent stale data until `/wipe` command
- **ROOT CAUSE**: HLR first pass had three branches:
  1. `if not localAlt` - Create new stub with banker's hash (CORRECT - for brand new alts)
  2. `elseif localHash == 0` - Update existing alt's hash (BUG - fires during pending sync)
  3. `elseif mismatch` - Log mismatch without updating (CORRECT)
- **TRIGGER SCENARIO**: Between HLR broadcasts, localHash becomes 0 (ApplyDelta creates stub, or other process clears it), next HLR hits branch 2 and updates hash prematurely
- **USER SCENARIO**: "i have hash 5xxxx with data, banker sends hash 4xxxx, I should use hash 4xxxx to trigger delta sync comparing hash 5xx with 4xx to determine the delta, and then get new data"
- **ACTUAL BUG BEHAVIOR**: Hash 5xxxx → 4xxxx update happens immediately in HLR first pass, before delta data request sent/received
- **SOLUTION**: Removed branch 2 entirely from HLR first pass (Chat.lua lines 1861-1873)
  - Only create NEW stubs for brand new alts (branch 1)
  - Only update hash in ApplyDelta after successful data application (DeltaComms.lua:971)
  - Hash mismatch detection (branch 3) triggers requests without updating hash
- **RESULT**: Hash stays at local value until delta received and applied, maintaining data/hash consistency
- **LOCATION**: Chat.lua HLR handler first pass (~1847-1878): Removed `elseif localHash == 0` branch
- **RELATED**: Works with DELTA-018 fix - latestBankerHashes cache tracks "what banker says", local inventoryHash tracks "what data we have", only ApplyDelta updates local hash

#### [DELTA-018] Fixed Hash Broadcast Circular Comparison (CRITICAL)
- **FIXED**: Hash sync protocol now maintains separate in-memory cache from local storage
- **PROBLEM**: hash-list-broadcast immediately updated local alt.inventoryHash, then comparison read from same local storage
- **IMPACT**: Complete sync failure - /togbank share broadcasts updated hash without triggering sync requests
- **BEHAVIOR**: Receivers had stale data but /togbank hashdebug showed "matched" (compared local hash against itself)
- **ROOT CAUSE**: Circular comparison - BuildBankerHashList() read from alt.inventoryHash, ReportHashListCoverage compared alt.inventoryHash vs BuildBankerHashList() output (both same source)
- **DESIGN FLAW**: No separation between "banker's authoritative hash" (what they broadcast) vs "hash of data we actually have" (what's in SavedVariables)
- **SOLUTION**:
  - Initialize `latestBankerHashes` in-memory cache on addon load from all local alt.inventoryHash values
  - hash-list-broadcast handler: Only update cache, never modify local storage
  - hash-list-reply handler: Only update cache on mismatch, never modify local storage
  - ReportHashListCoverage: Use latestBankerHashes exclusively (no BuildBankerHashList, no merge)
  - Local alt.inventoryHash: Only updated when actual delta data received and applied
- **CACHE STRUCTURE**: `{hash, updatedAt, version, mailHash, mailUpdatedAt}` per alt
- **COMPARISON LOGIC**: cache.hash ("what banker says") vs localAlt.inventoryHash ("what we have")
- **RESULT**: Proper mismatch detection - cache updated by broadcasts, local unchanged until delta received, comparison detects staleness
- **LOCATION**: 
  - Guild.lua Init (~276-290): Initialize latestBankerHashes from SavedVariables
  - Guild.lua ReportHashListCoverage (~693-710): Use cache directly for comparison
  - Chat.lua hash-list-broadcast (~1773-1795): Update cache only
  - Chat.lua hash-list-reply (~1843-1847): Update cache only on mismatch
- **VERIFICATION**: Tested with manual hash revert - broadcast updated cache, local stayed stale, hashdebug showed pending, sync requested delta

#### [DELTA-016] Fixed Delta Protocol Sending Aggregated Items (CRITICAL)
- **FIXED**: ComputeDelta now sends separate bank/bags/mail inventories instead of aggregated items
- **PROBLEM**: Used `alt.items` (UI display field) which was often empty on sender side despite non-zero hash
- **IMPACT**: Complete data sync failure - deltas contained only money updates, no item data
- **BEHAVIOR**: Debug showed "hasChanges.items=false, itemCount=0" with non-zero inventoryHash (contradiction)
- **ROOT CAUSE**: `alt.items` computed during Bank:Scan() for UI aggregation, not guaranteed during delta computation
- **PROTOCOL DESIGN**: Should send bank/bags/mail separately so receiver populates individual inventories
- **SOLUTION**: 
  - ComputeDelta: Source from `currentAlt.bank.items`, `bags.items`, `mail.items` separately
  - ApplyDelta: Apply to `current.bank.items`, `bags.items`, `mail.items` individually
  - Recalculate aggregated `current.items` after delta application (UI display only)
  - DeltaHasChanges: Check bank/bags/mail separately
  - ValidateDeltaStructure: Validate mail delta
  - SanitizeDelta: Sanitize mail delta
  - StripDeltaLinks: Strip mail links
- **RESULT**: Deltas now contain actual item data (ID + Count) in separate bank/bags/mail structures
- **LOCATION**: `DeltaComms.lua` ComputeDelta (~627-648), ApplyDelta (~912-969), DeltaHasChanges, validation/sanitization
- **NOW**: Full inventory synchronization working - items populate correctly on receiver side

#### [DELTA-017] Fixed Empty Baseline Missing Bank/Bags/Mail Structures (CRITICAL)
- **FIXED**: ComputeDelta empty baseline now includes bank/bags/mail structures
- **PROBLEM**: Empty baseline fallback only had `{ items = {}, money = 0, mailHash = 0 }` without bank/bags/mail
- **IMPACT**: First-time sync sent empty deltas despite sender having inventory data
- **BEHAVIOR**: ComputeDelta compared empty baseline to sender's current but both appeared empty
- **ROOT CAUSE**: When accessing `previous.bank.items`, defaulted to `{}` but didn't distinguish between incomplete baseline vs empty inventory
- **SOLUTION**: 
  - Changed empty baseline to include complete structures:
    `{ items = {}, money = 0, mailHash = 0, bank = { items = {} }, bags = { items = {} }, mail = { items = {} } }`
  - Fixed in 3 locations: mail-only change without snapshot, hash mismatch without snapshot, requester has no data
- **RESULT**: First-time sync and hash mismatch scenarios now send actual items (not empty deltas)
- **LOCATION**: `DeltaComms.lua` ComputeDelta empty baseline initialization (~594, ~606, ~613)
- **NOW**: All sync scenarios populate receiver correctly with sender's inventory data

#### [MAIL-010] Fixed Mail-Only Change Sync Abort (CRITICAL)
- **FIXED**: ComputeDelta now uses empty baseline fallback instead of returning nil
- **PROBLEM**: When mail changed but inventory matched, and no snapshot existed, returned nil (line 567)
- **IMPACT**: Complete sync failure - requesters with matching inventory but outdated mail never received updates
- **BEHAVIOR**: Guild.lua aborted sync at line 2054-2055 with "Failed to compute delta" error
- **ROOT CAUSE**: Inconsistent error handling - inventory mismatch used empty baseline, mail-only change returned nil
- **SOLUTION**: Changed to `previous = { items = {}, money = 0, mailHash = 0 }` (same as inventory mismatch case)
- **RESULT**: Mail-only changes always sync successfully via delta (contains all items as additions against empty baseline)
- **LOCATION**: `DeltaComms.lua` (~557-567): Mail-only change handler now matches inventory mismatch fallback behavior
- **NOTE**: Still pure delta protocol - empty baseline causes delta to include all items, but transmitted as delta message

#### [P2P-010] Fixed P2P Broadcast Never Sent (CRITICAL)
- **FIXED**: togbank-rr handler now actually sends P2P broadcast to guild
- **PROBLEM**: Handler built P2P request but never serialized or sent it
- **IMPACT**: P2P only worked when no banker online initially; failed when banker responded with hash (common case)
- **BEHAVIOR**: Request was built, log said "Broadcasting", but SendCommMessage was missing
- **RESULT**: 5-second timeout always triggered, forcing 100% fallback to banker despite peers having data
- **LOCATION**: `Chat.lua` (~1053-1054): Added missing SerializeWithChecksum and SendCommMessage calls
- **NOW**: Full P2P flow works - peers receive broadcasts and respond with matching hashes

#### [P2P-011] Fixed pendingSendCount Leak
- **FIXED**: Added 30-second timeout to auto-decrement counter when requester never sends state summary
- **PROBLEM**: Peer ACKs request and increments counter, but if requester goes offline before sending state summary, counter never decrements
- **IMPACT**: After 3 stuck sends, peer permanently blocks all P2P responses with "send queue full" until `/reload`
- **BEHAVIOR**: Now auto-decrements counter after 30 seconds if SendAltData never called
- **RESULT**: Peers self-recover from stuck sends, preventing permanent P2P queue blocking
- **LOCATIONS**: 
  - `Guild.lua` (~22): Added pendingSendTimeouts tracking table
  - `Chat.lua` (~829-838): Added 30-second safety timeout after incrementing counter
  - `Guild.lua` (~1997-2000): Cancel timeout when SendAltData actually called
- **NOW**: Robust P2P send queue management with automatic recovery from edge cases

#### [P2P-012] Added Peer-Side Fallback Timeout
- **FIXED**: Added 15-second timeout on requester side after peer ACK
- **PROBLEM**: If peer ACKs but never sends data (disconnect/crash), requester waits indefinitely
- **IMPACT**: User must manually retry with `/togbank sync`
- **BEHAVIOR**: Now falls back to banker after 15 seconds if peer never delivers
- **RESULT**: Automatic recovery from peer failures without manual intervention
- **LOCATION**: `Chat.lua` (~1091-1101): Secondary timeout after clearing pending P2P request
- **NOW**: Full fallback chain works - peer timeout → banker fallback → data arrives

#### [P2P-013] Fixed expectedHashUpdatedAt Memory Leak
- **FIXED**: Added cleanup for expectedHashUpdatedAt after successful hash validation
- **PROBLEM**: Timestamps stored but never cleared, accumulating indefinitely
- **IMPACT**: Minor memory leak (just timestamps), no functional impact
- **RESULT**: Clean memory management for hash tracking
- **LOCATION**: `Guild.lua` (~2250-2252): Clear expectedHashUpdatedAt after validation

#### [PERF-007] Fixed GUILD_ROSTER_UPDATE Stuttering
- **FIXED**: Changed OR to AND logic in initialization condition to stop repeated full roster refreshes
- **PROBLEM**: Used `fullRosterInitAttempts < 2 OR (roster incomplete)` which kept triggering after initialization
- **IMPACT**: Every online/offline event triggered full guild roster scan (1000+ members), causing 5-10ms+ stuttering
- **BEHAVIOR**: After 2 initialization attempts, `fullRosterInitAttempts >= 2` BUT condition stayed true due to OR
- **ROOT CAUSE**: Second condition `totalMembers <= onlineMembers` often true (WoW API reports equal values)
- **SOLUTION**: Changed to AND logic - only refresh if BOTH conditions true: (not initialized yet) AND (roster incomplete)
- **RESULT**: Full refresh only during addon load, online/offline uses lightweight CHAT_MSG_SYSTEM handler (<1ms)
- **LOCATION**: `Events.lua` (~305-313): Fixed needsFullRosterRefresh flag logic
- **OPERATIONS AVOIDED**: RefreshOnlineCache, RebuildBankerRoster, GetGuildRosterInfo loops, RefreshRequestsUI
- **NOW**: Smooth gameplay without stuttering, full scan only on joins/leaves (not online/offline)
- **DOCUMENTATION**: See `docs/DELTA_BUGS.md` for comprehensive analysis (PERF-005, PERF-007)

#### [DELTA-015] Fixed Delta Duplication Bug (Complete)
- **FIXED**: Added snapshot validation for inventory changes to prevent item duplication
- **PROBLEM**: When inventory changed but no snapshot existed, delta computed against empty baseline
- **IMPACT**: Requester would receive delta additions on top of existing stale data, causing duplicates
- **BEHAVIOR**: Now checks for snapshot before computing delta for both mail-only AND inventory changes
- **RESULT**: Forces full data (hash=0) when no snapshot available, preventing duplication
- **LOCATIONS**: 
  - `Guild.lua` (~1568-1594): Mail-only change validation (previously fixed)
  - `Guild.lua` (~1596-1624): Inventory change validation (newly fixed)

#### [SYNC-009] Fixed Non-Banker Hash Sync
- **FIXED**: HLR handler now checks hash equality BEFORE skipping alts
- **PROBLEM**: Previously skipped any alt with hasContent=true without comparing hashes
- **IMPACT**: Non-banker updates never propagated to peers with stale data
- **BEHAVIOR**: Now only skips if BOTH hasContent AND hashes match
- **RESULT**: Non-banker-to-non-banker sync working correctly

#### [MAIL-009] Fixed mailHash Storage When Hashes Differ
- **FIXED**: HLR and HL-broadcast handlers now update mailHash when it differs from banker
- **PROBLEM**: Only stored mailHash when localHash=0, not when hashes differed
- **IMPACT**: Mail-only changes never cached banker's new mailHash
- **LOCATIONS**: Fixed in both HLR handler (togbank-hlr) and hash broadcast handler (togbank-hl)
- **RESULT**: Banker's authoritative mailHash properly cached in all scenarios

**Technical Details:**
```lua
// OLD: Only update when localHash == 0
elseif localHash == 0 then
    localAlt.inventoryHash = summary.hash
    if summary.mailHash then
        localAlt.mailHash = summary.mailHash  // Only here!
    end
end

// NEW: Also update when hashes differ
elseif localHash ~= summary.hash or (localAlt.mailHash or 0) ~= (summary.mailHash or 0) then
    localAlt.inventoryHash = summary.hash
    if summary.mailHash then
        localAlt.mailHash = summary.mailHash  // Now cached properly!
    end
end
```

**Files Changed:**
- `Modules/Chat.lua` (~1740-1753): HLR handler - added elseif block for hash diff
- `Modules/Chat.lua` (~1654-1679): HL broadcast handler - updated stub creation and hash updates
- `docs/DELTA_BUGS.md`: Documented SYNC-009 and MAIL-009 with full analysis

---

## Unreleased - Hash Broadcast Improvements

**Status:** In Development
**Priority:** MEDIUM

### 🔄 Hash Broadcasting Overhaul

#### Changes to `/togbank share`
- **CHANGED**: Now broadcasts hash for ONLY the current banker character (single alt)
- **CHANGED**: Uses togbank-hl channel for hash announcement (P2P discovery)
- **CHANGED**: No longer pushes full data - clients pull data via sync cycle
- **IMPACT**: Reduces spam when banker shares (1 hash vs 35+ data packets)

#### New Command: `/togbank hashupdate`
- **NEW**: Banker-only command to broadcast ALL bank alt hashes (the "nuke")
- **USE CASE**: Force guild-wide hash refresh after bulk inventory changes
- **BEHAVIOR**: Broadcasts hash-list for all bank alts on togbank-hl
- **OUTPUT**: "Broadcasted hash-list for N bank alts"

#### Hash Broadcast Enhancements
- **ENHANCED**: `BuildBankerHashList()` now includes `mailHash` and `mailUpdatedAt`
- **ENHANCED**: Hash-list-broadcast handler stores both inventory and mail hashes
- **ENHANCED**: Handler tracks what changed: "Updated AltName: inv: 123->456, mail: 789->999"
- **FIXED**: Non-bankers can now detect mail-only changes from hash broadcasts
- **BEHAVIOR**: No automatic requests triggered - users must run `/togbank sync` or wait for automatic sync cycle

#### Technical Details
- Hash broadcasts contain: `inventoryHash`, `inventoryUpdatedAt`, `version`, `mailHash`, `mailUpdatedAt`
- Clients update local hash stubs when received
- Actual data requests happen during next sync cycle (manual, UI open, or 3-minute timer)

**Files Changed:**
- `Modules/Guild.lua`:
  - Updated `BuildBankerHashList()` to include mail hashes
  - Modified `Share()` to broadcast single-alt hash on togbank-hl
  - Added `HashUpdate()` function for all-alts hash broadcast
- `Modules/Chat.lua`:
  - Updated hash-list-broadcast handler to store both inventory and mail hashes
  - Added `/togbank hashupdate` command registration
  - Enhanced hash change detection and logging

---

## [v0.8.9] (2026-02-07) - P2P Hash Backfill Complete

**Status:** Production Ready
**Priority:** HIGH

### 🎯 P2P Hash Backfill Implementation

#### Core Features Implemented
- **NEW**: Banker HLR (hash list reply) stores authoritative hashes for all roster alts
- **NEW**: Version broadcasts store peer hashes when local hash is missing
- **NEW**: 3-minute rebroadcast timer requests hash list and rebroadcasts P2P for missing alts
- **NEW**: Roster sync fallback for officer-note-only guilds (config option, default OFF)
- **FIXED**: /wipe now rebuilds banker roster immediately (progress shows 0/35 instead of 0/2)
- **FIXED**: Data payloads always use GUILD channel (removed WHISPER routing for togbank-d3/d4)
- **FIXED**: SendWhisper now correctly treats AceComm nil return as success
- **FIXED**: Nil table access errors in Guild.lua (table initialization before access)
- **FIXED**: Inventory disappearing during async item loads - added loading indicator [UI-005]
- **FIXED**: Severe tooltip performance issues causing PC stuttering
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
