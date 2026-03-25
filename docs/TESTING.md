# TOGBankClassic Testing Guide

**Current Version:** v0.7.0 (Snapshot-Based Delta Sync)
**Next Version:** v0.8.0 (Pull-Based Delta Protocol)
**Last Updated:** January 21, 2026

---

## ⏳ Pending Tests — Requires Live Guild Data

The following features require another player to log on with "old" data (requests or requests sync older than the configured threshold) to verify fully.

### Archive Tab

**Feature:** Requests window shows a "Requests" tab (recent) and an "Archive" tab (older than `archiveDays`, default 30). The threshold is configured per-user in **Options > TOGBankClassic > Requests > Archive Threshold (days)**.

| # | Test | How to verify | Expected |
|---|------|--------------|----------|
| A-1 | Tab strip renders | Open Requests window | Two tabs ("Requests" / "Archive") appear at the top |
| A-2 | Recent requests go to Requests tab | Open Requests window | Requests submitted within the last N days appear only on the Requests tab |
| A-3 | Old requests go to Archive tab | Need a player with requests timestamped >30 days ago; or temporarily set `archiveDays = 0` to force all into Archive | Archive tab shows those requests; Requests tab empty |
| A-4 | Threshold persists through /reload | Set threshold to e.g. 14, `/reload` | Options field still shows 14; tab filter unchanged |
| A-5 | Threshold updates filter live | Change threshold while window open, switch tabs | Requests redistribute between tabs accordingly |
| A-6 | Empty-state label | Navigate to Archive tab with no old requests | Label reads "No archived requests." instead of generic empty text |

**Shortcut for local testing (no old data needed):**
Temporarily set `archiveDays = 0` in Options. All requests will appear in Archive tab, none in Requests tab.

---

### Auto-Tombstone: Stale Open Requests

**Feature:** Any open request older than `autoTombstoneDays` (guild-synced, default 30) is automatically rejected and tombstoned the moment it arrives via any sync path (`mergeRequest()`, REQUEST-RETIRE-003). Officers/bankers can also bulk-cancel via the "Cancel Stale" button.

**Prerequisite for full testing:** A player must log in who has an open request in their local SavedVariables that was submitted more than `autoTombstoneDays` days ago. That request will re-appear in the sync stream when their client broadcasts.

| # | Test | How to verify | Expected |
|---|------|--------------|----------|
| B-1 | Cancel Stale button visible (officer/banker) | Log in as banker or officer; open Requests window | "Cancel Stale" button appears in tab strip |
| B-2 | Cancel Stale button hidden (regular member) | Log in as non-officer, non-banker; open Requests window | Button does not appear |
| B-3 | Cancel Stale confirm dialog | Click "Cancel Stale" button | Dialog appears: "Cancel all open requests older than X days? This cannot be undone and will propagate to the whole guild." |
| B-4 | Cancel Stale no-op when none qualify | Click Cancel Stale when all requests are recent | Status bar shows "No stale requests found." |
| B-5 | Cancel Stale tombstones qualifying requests | With at least one old open request present; click Cancel Stale + confirm | Status bar shows "Cancelled N stale request(s)."; request disappears from table; tombstone entry added |
| B-6 | Cancellation propagates guild-wide | After B-5; another logged-in client checks their Requests window | Tombstoned request removed from their list too (on next sync) |
| B-7 | Stale open request auto-rejected on receive | Another player with an old open request logs in / forces a share | Request never appears in the Requests window; tombstone entry created; debug log shows REQUEST-RETIRE-003 |
| B-8 | `autoTombstoneDays` persists to guild settings | Officer sets threshold in Options; another client syncs | Second client applies same threshold without relogging |
| B-9 | Tooltip reflects current threshold | Hover "Cancel Stale" button | Tooltip body mentions the current `autoTombstoneDays` value |
| B-10 | REQUEST-RETIRE-003 not fired for recent open requests | Receive a request submitted today | Request added normally; no tombstone created |

**Debug check for B-7:**
Enable debug output with `/togbank debug` and watch for:
```
[RequestLog] REQUEST-RETIRE-003: tombstoning stale open request <id> (age=Xd, threshold=30d)
```

---

### Overview
v0.8.0 replaces snapshot-based delta sync with a pull-based handshake protocol. Testing must validate the 7-step flow, message optimizations, and backwards compatibility.

### Test Categories

#### 1. Protocol Flow Testing (7 Steps)
**Scenario:** Full handshake flow from request to data application

**Setup:**
- Character A: Banker (has all data)
- Character B: Non-banker (needs data for alt X)

**Test Steps:**
1. **Step 1: Banker announces**
   - Verify togbank-dv sent on GUILD channel
   - Verify Character B receives and updates banker list

2. **Step 2: Non-banker requests**
   - Verify Character B sends togbank-r (WHISPER if banker known)
   - Verify togbank-r includes alt name

3. **Step 3: Banker acknowledges**
   - Verify Character A sends togbank-rr on WHISPER
   - Verify togbank-rr includes `isBanker = true`

4. **Step 4: Non-banker sends state**
   - Verify Character B sends togbank-state on WHISPER
   - Verify state format: `{[itemID] = quantity}`
   - Verify state excludes Links, bags, slots

5. **Step 5: Banker computes response**
   - Test A: Empty state → full sync chosen
   - Test B: Matching state → no-change chosen
   - Test C: Partial state → delta computed

6. **Step 6: Banker sends data**
   - Verify togbank-d/togbank-d2 sent on GUILD (data)
   - Verify togbank-nochange sent on WHISPER (no-change)
   - Verify messages exclude Link fields
   - Verify messages exclude baseVersion

7. **Step 7: Receiver applies data**
   - Verify Character B applies changes
   - Verify Character B reconstructs Links for all items
   - Verify Links stored in database

**Expected Results:**
- ✅ All 7 steps complete successfully
- ✅ Data synchronized correctly
- ✅ Links reconstructed and stored
- ✅ No errors in chat log

#### 2. Message Optimization Testing

**Test 2.1: Links Removed from Transmission**
```lua
-- Setup: Banker has 100 items
-- Expected: togbank-d message size ~1-2KB (vs v0.7.0's 8-10KB)

/togbank test link_removal

-- Verify:
-- 1. Sent message contains only { ID, Count }
-- 2. Received message reconstructs Links
-- 3. Database stores reconstructed Links
-- 4. UI displays items correctly with Links
```

**Test 2.2: baseVersion Removed**
```lua
-- Setup: Send delta update
-- Expected: togbank-d2 message excludes baseVersion field

/togbank test no_baseversion

-- Verify:
-- 1. Delta structure has no baseVersion field
-- 2. Delta applies correctly without baseVersion
-- 3. No version mismatch errors
```

**Test 2.3: Minimal Remove Format**
```lua
-- Setup: Remove 10 items from banker
-- Expected: Remove array only contains IDs

/togbank test minimal_removes

-- Verify:
-- 1. remove = { { ID = 12345 }, ... }
-- 2. No Count field
-- 3. No Link field
-- 4. Items removed correctly from receiver database
```

**Test 2.4: State Summary Format**
```lua
-- Setup: Non-banker has 100 items
-- Expected: State summary ~800 bytes

/togbank test state_summary

-- Verify:
-- 1. Format: {[itemID] = quantity}
-- 2. No Link fields (60-80 bytes each saved)
-- 3. No bag/slot fields
-- 4. Correctly represents current state
```

#### 3. Channel Assignment Testing

**Test 3.1: GUILD Channel Usage**
```lua
-- Verify these messages use GUILD:
-- togbank-v, togbank-dv, togbank-d, togbank-d2

/togbank test guild_channel

-- Expected:
-- 1. Version broadcasts → GUILD
-- 2. Banker announcements → GUILD
-- 3. Full sync data → GUILD
-- 4. Delta data → GUILD
-- 5. Query fallback (banker unknown) → GUILD
```

**Test 3.2: WHISPER Channel Usage**
```lua
-- Verify these messages use WHISPER:
-- togbank-r (if banker known), togbank-rr, togbank-state, togbank-nochange

/togbank test whisper_channel

-- Expected:
-- 1. Query to banker → WHISPER
-- 2. Query reply → WHISPER
-- 3. State summary → WHISPER
-- 4. No-change reply → WHISPER
-- 5. NO DATA SYNC IN WHISPER
```

**Test 3.3: Smart Routing**
```lua
-- Test A: Banker known online
-- Expected: togbank-r sent via WHISPER

-- Test B: Banker unknown/offline
-- Expected: togbank-r sent via GUILD

/togbank test smart_routing
```

#### 4. Version Management Testing

**Test 4.1: Version Only Updated on Actual Inventory Changes**
```lua
-- v0.8.0: Uses ComputeInventoryHash() to detect real changes
-- Version only updates when hash changes (items/money added/removed/modified)

-- Test A: Open/close bank without changes
-- 1. Note current version timestamp
-- 2. Open bank, close bank (no items moved)
-- 3. Check version - SHOULD BE UNCHANGED

-- Test B: Open/close mailbox without changes
-- 1. Note current version timestamp
-- 2. Open mailbox, close mailbox (no items)
-- 3. Check version - SHOULD BE UNCHANGED

-- Test C: Multiple scans without changes
-- 1. Note current version timestamp
-- 2. Open/close bank 5 times
-- 3. Check version - SHOULD BE UNCHANGED

-- Expected debug log: "No inventory changes for PlayerName-Realm, version unchanged"
```

**Test 4.2: Version Updated on Inventory Changes**
```lua
-- Setup:
-- 1. Banker has items (note version = X)
-- 2. Add item to bank
-- 3. Check version - should be NEW timestamp

-- Test A: Add item
-- Expected: Version updates, hash changes

-- Test B: Remove item
-- Expected: Version updates, hash changes

-- Test C: Move item (same total, different arrangement)
-- Expected: Version UNCHANGED (same items/quantities)

-- Test D: Money change
-- Expected: Version updates, hash changes

-- Expected debug log: "Inventory changed for PlayerName-Realm, version updated to NNNNNN"
```

**Test 4.3: No Version Drift from Communication**
```lua
-- Setup:
-- 1. Banker has stable inventory (version 100)
-- 2. Non-banker queries 10 times
-- 3. Check banker version

-- Expected: Version still 100 (no drift from queries)

/togbank test no_version_drift

-- Verify:
-- 1. Version before queries: 100
-- 2. Multiple queries received and responded
-- 3. Version after queries: 100 (UNCHANGED)
-- 4. No new snapshots created (only on version change)
```

**Test 4.4: Version Never Updated On**
```lua
-- These events should NEVER update version:
-- ❌ Logout/login without inventory changes
-- ❌ Query/response messages
-- ❌ Opening bank/mail/AH/vendor without changes
-- ❌ No-change replies
-- ❌ SendAltData() calls

-- Only updated by:
-- ✅ Bank:Scan() when ComputeInventoryHash() detects change
-- ✅ ApplyDelta() when receiving data from another player
```

**Test 4.5: Hash Consistency**
```lua
-- Setup:
-- 1. Character A has: 10x [Item A], 5x [Item B], 100g
-- 2. Character B has: 5x [Item B], 10x [Item A], 100g (different order)

-- Expected: Same hash, same version behavior
-- (Hash is order-independent due to sorting)
```

#### 5. Response Prioritization Testing

**Test 5.1: Banker Response Priority**
```lua
-- Setup:
-- 1. Banker (version 100)
-- 2. Non-banker (version 110 - somehow newer)
-- 3. Both respond to query

-- Expected: Banker's data used (isBanker = true wins)

/togbank test banker_priority

-- Verify:
-- 1. Both send togbank-rr
-- 2. Banker's has isBanker = true
-- 3. Banker's data applied (even with lower version)
```

**Test 5.2: Highest Version Among Non-Bankers**
```lua
-- Setup:
-- 1. No banker online
-- 2. Character A (version 100)
-- 3. Character B (version 110)
-- 4. Both respond to query

-- Expected: Character B's data used (highest version)

/togbank test highest_version_non_banker
```

#### 6. Link Reconstruction Testing

**Test 6.1: GetItemInfo Reconstruction**
```lua
-- Setup: Receive delta with items (ID only)
-- Expected: Links reconstructed correctly

/togbank test link_reconstruction

-- Test items:
local testItems = {
  { ID = 2589 },  -- Linen Cloth
  { ID = 2592 },  -- Wool Cloth
  { ID = 4306 },  -- Silk Cloth
}

-- Verify:
-- 1. GetItemInfo(2589) returns correct link
-- 2. Link stored in database: item.Link = "|cff..."
-- 3. UI displays clickable, color-coded item
```

**Test 6.2: Async Loading Handling**
```lua
-- Setup: Receive item not in cache
-- Expected: Item:CreateFromItemID with callback

/togbank test async_link_loading

-- Verify:
-- 1. GetItemInfo returns nil (not cached)
-- 2. Item:CreateFromItemID called
-- 3. ContinueOnItemLoad callback fires
-- 4. Link retrieved and stored after load
```

#### 7. Startup Optimization Testing

**Test 7.1: Banker Discovery on Init**
```lua
-- Setup:
-- 1. Start addon with banker already online
-- 2. Wait for discovery broadcast

-- Expected: Banker detected and added to list

/togbank test banker_discovery_init

-- Verify:
-- 1. Discovery broadcast sent on load
-- 2. Banker responds with togbank-dv
-- 3. Banker added to onlineBankers table
```

**Test 7.2: Banker List Updates**
```lua
-- Setup:
-- 1. Banker online (in list)
-- 2. Banker logs out
-- 3. Check list

-- Expected: Banker removed from list

/togbank test banker_list_updates

-- Also test:
-- - Banker logs in → added to list
-- - Multiple bankers online → all in list
```

#### 8. Backwards Compatibility Testing

**Test 8.1: v0.8.0 Client with v0.7.0 Client**
```lua
-- Setup:
-- 1. Character A: v0.8.0 (new protocol)
-- 2. Character B: v0.7.0 (old protocol)

-- Expected: Fallback to full sync with Links

/togbank test v07_compatibility

-- Verify:
-- 1. v0.8.0 detects v0.7.0 from version broadcast
-- 2. v0.8.0 sends togbank-d with Links (full format)
-- 3. v0.7.0 receives and applies correctly
-- 4. No errors on either side
```

**Test 8.2: Mixed Guild**
```lua
-- Setup:
-- 1. Guild has 3 v0.8.0 clients
-- 2. Guild has 2 v0.7.0 clients

-- Expected: v0.8.0 clients use new protocol with each other

/togbank test mixed_guild
```

#### 9. Error Handling Testing

**Test 9.1: Malformed State Summary**
```lua
-- Setup: Send invalid state format
-- Expected: Request full sync fallback

/togbank test malformed_state

-- Test cases:
-- 1. State is nil
-- 2. State is string (not table)
-- 3. State has wrong structure
-- 4. State has negative quantities

-- Expected: Graceful fallback to full sync
```

**Test 9.2: Link Reconstruction Failure**
```lua
-- Setup: Receive item with invalid ID
-- Expected: Log error, continue processing

/togbank test link_reconstruction_failure

-- Verify:
-- 1. GetItemInfo returns nil for bad ID
-- 2. Error logged to debug
-- 3. Item stored without Link (ID/Count only)
-- 4. Other items process correctly
```

**Test 9.3: Channel Failure**
```lua
-- Setup: WHISPER channel throttled/unavailable
-- Expected: Fallback to GUILD for query

/togbank test channel_failure

-- Verify:
-- 1. WHISPER send fails
-- 2. Addon retries on GUILD
-- 3. Data still synchronized
```

#### 10. Performance Testing

**Test 10.1: Bandwidth Savings**
```lua
-- Setup:
-- 1. Banker with 100 items
-- 2. Measure v0.7.0 sync size (with Links)
-- 3. Measure v0.8.0 sync size (without Links)

/togbank test bandwidth_savings

-- Expected:
-- v0.7.0: ~8-10KB (with 60-80 byte Links)
-- v0.8.0: ~1-2KB (ID/Count only)
-- Savings: ~6-8KB (75-80% reduction)
```

**Test 10.2: CPU Cost of Link Reconstruction**
```lua
-- Setup: Receive 100 items
-- Measure: Time to reconstruct all Links

/togbank test link_reconstruction_time

-- Expected: <100ms for 100 items (negligible)
```

---

## v0.7.0 Automated Test Suite (IMPLEMENTED)

## Quick Start

### Running Automated Tests
```
/togbank test              -- Run all 25 tests (~2 seconds)
/togbank test <name>       -- Run specific test
/togbank test phase5.1     -- Run Phase 5.1 tests only
```

### Running Manual Tests
See manual testing procedures below for scenario-based testing.

---

## Automated Test Suite (25 Tests)

### Overview
The automated test suite validates all core delta sync functionality:
- **Phase 5.1:** Delta Computation (8 tests) - Core algorithm
- **Phase 5.2:** Size Estimation (4 tests) - Efficiency calculations
- **Phase 5.3:** Protocol Negotiation (3 tests) - Version detection
- **Phase 5.4:** Error Handling (5 tests) - Graceful fallbacks
- **Phase 5.5:** Integration (2 tests) - End-to-end workflows
- **Phase 5.6:** Backwards Compatibility (3 tests) - v1 client support

### What Each Phase Tests

#### Phase 5.1: Delta Computation (Core Logic)
Tests the algorithm that compares two snapshots and generates a delta:
- ✅ No changes detection (empty delta)
- ✅ Money changes (gold/silver/copper)
- ✅ Item additions (new items appearing)
- ✅ Item removals (items disappearing) ← **Caught critical bug!**
- ✅ Item count changes (stack size modifications)
- ✅ Multiple simultaneous changes
- ✅ Item equality comparison
- ✅ Changed field detection

**Functions Tested:** `ComputeDelta()`, `ItemsEqual()`, `GetChangedFields()`, `ComputeItemDelta()`

#### Phase 5.2: Size Estimation (Efficiency)
Tests whether delta is smaller than full sync:
- ✅ Empty data size calculation
- ✅ Small delta size estimation
- ✅ Large delta size estimation
- ✅ Delta vs full sync size comparison

**Functions Tested:** `EstimateSize()`
**Purpose:** Decides when delta is more efficient than full sync (< 30% threshold)

#### Phase 5.3: Protocol Negotiation (Version Detection)
Tests how clients detect each other's protocol versions:
- ✅ Protocol version detection (v1 vs v2)
- ✅ Delta usage decision logic
- ✅ Guild support threshold (10% must support v2)

**Functions Tested:** `GetPeerCapabilities()`, `ShouldUseDelta()`, `GetGuildDeltaSupport()`
**Purpose:** Ensures v2 clients only use delta when talking to other v2 clients

#### Phase 5.4: Error Handling (Graceful Fallbacks)
Tests what happens when things go wrong:
- ✅ Applying delta with no existing data → Request full sync
- ✅ Version mismatch → Request delta chain or full sync
- ✅ Error tracking in metrics
- ✅ Snapshot validation (rejects malformed data)
- ✅ Delta validation (rejects invalid deltas)

**Functions Tested:** `ApplyDelta()`, `ValidateSnapshot()`, `ValidateDeltaStructure()`
**Purpose:** Prevents data corruption and ensures system recovers from errors

#### Phase 5.5: Integration (End-to-End)
Tests complete workflows from start to finish:
- ✅ **Full delta roundtrip:** Compute → Apply → Verify (tests additions, removals, money changes)
- ✅ Delta size threshold decision making

**Critical Test:** Roundtrip test caught the `ApplyItemDelta` bug where item removals left holes in arrays instead of actually removing items.

#### Phase 5.6: Backwards Compatibility (v1 Support)
Tests that v2 clients work with v1 clients:
- ✅ V1 client detection (protocol version 1)
- ✅ V2 client capabilities (supports both protocols)
- ✅ Fallback to full sync when talking to v1 clients

**Purpose:** Ensures smooth migration from v0.6.8 (v1) to v0.7.0 (v2)

### Bug Discovered by Tests

**Critical Bug:** `ApplyItemDelta` item removal broken
**File:** `Modules/Guild.lua:1221-1236`
**Discovered By:** Phase 5.5 Integration Test

```lua
-- BROKEN (before fix):
items[i] = nil  -- Leaves hole in array, length unchanged

-- FIXED (after):
table.remove(items, i)  -- Properly removes and shifts elements
```

**Impact:** Item removals in delta sync were completely broken. Tests prevented this from reaching production!

### Test Data Structures

All tests use standardized data structures:

**Item:**
```lua
{ID = 2589, Count = 20, Link = "[Linen Cloth]"}
```

**Alt Data:**
```lua
{
  name = "CharName",
  version = 1234567890,
  money = 150000,  -- At root level (not bank.money!)
  bank = {items = {...}},
  bags = {items = {...}}
}
```

**Delta:**
```lua
{
  type = "alt-delta",
  name = "CharName",
  version = 2,
  baseVersion = 1,
  changes = {
    money = 200000,
    bank = {added=[...], modified=[...], removed=[...]},
    bags = {added=[...], modified=[...], removed=[...]}
  }
}
```

### Adding New Tests

1. Write test function in `Modules/Tests.lua`
2. Use `setupDeltaTest()` to initialize
3. Register in `runAllTests()` function
4. Test with `/togbank test <name>`

See inline comments in Tests.lua for examples.

---

## Manual Testing Procedures

### Pre-Testing Setup

1. **Test Environment Requirements:**
   - WoW Classic Era client (Interface 11508)
   - At least 2 characters in same guild
   - At least 1 character designated as guild bank (with "gbank" in note)
   - Ability to test with multiple accounts (for multi-user scenarios)

2. **Initial Setup:**
   - Install TOGBankClassic v0.7.0 on all test characters
   - Configure bank character with reporting enabled
   - Verify base functionality with `/togbank version` (should show 0.7.0)

---

## Test Suite 1: Basic Delta Sync Functionality

### Test 1.1: Initial Snapshot Creation
**Objective:** Verify snapshots are created on first sync

**Steps:**
1. Log in with bank character
2. Open bank and make initial inventory scan
3. Type `/togbank share` to broadcast data
4. Check snapshots with `/togbank deltastats`

**Expected Result:**
- Snapshot saved in database
- Full sync sent (no delta available yet)
- Metrics show bytesSentFull > 0

---

### Test 1.2: Small Change Delta ✅ PASSED
**Objective:** Verify delta sync for minor inventory changes

**Steps:**
1. With bank character, add/remove 1-2 items from bank
2. Open bank to trigger scan
3. Type `/togbank share` to broadcast
4. Log into receiving character
5. Check `/togbank deltastats`

**Expected Result:**
- Delta sync used (check debug output with `/togbank debug`)
- Metrics show bytesSentDelta > 0
- Delta size < 30% of full sync size
- Receiving character sees updated inventory

**Test Results (2026-01-20):**
- ✅ **Delta transmitted**: 311 bytes vs 1748 bytes full (17.8% size, 82% savings)
- ✅ **Validation passed**: No errors on receiver (Galdof-OldBlanchy)
- ✅ **Application successful**: "✓ Applied delta for Metals-Azuresong (v1768947985→v1768948029) in 0.06ms"
- ✅ **Quantity changes detected**: 70→90 Mithril Bars correctly reflected
- ✅ **Compute time**: 0.42ms (efficient)
- ✅ **Bandwidth metrics**: bytesSentDelta=1008B (0.8%), bytesSentFull=128.7KB (99.2%)
- **Bug Fixed**: DELTA-005 (item merging broke slot-based comparison) - converted to itemKey-based comparison
- **Test Environment**: Metals-Azuresong (sender) → Galdof-OldBlanchy (receiver), "The Old Gods" guild, 12.5% v2 adoption

---

### Test 1.3: Large Change Fallback
**Objective:** Verify fallback to full sync on large changes

**Steps:**
1. With bank character, change >30% of inventory (add/remove many items)
2. Open bank to trigger scan
3. Type `/togbank share`
4. Check debug output

**Expected Result:**
- Debug shows "✗ Delta too large" message
- Full sync used instead of delta
- Metrics show fullSyncFallbacks incremented
- Receiving character still gets updated data correctly

---

### Test 1.4: Delta Chain Replay (Offline Player Recovery)
**Objective:** Verify delta chain replay allows offline players to catch up efficiently

**Steps:**
1. **Setup**: Galdof (receiver) has Metals data at v100
2. **Simulate offline**: Log out Galdof or go AFK
3. **Banker makes updates**: On Metals, make 3-5 small changes over 10 minutes:
   - Update 1: Add 2 items → v105 (delta saved to history)
   - Update 2: Remove 1 item → v110 (delta saved to history)
   - Update 3: Change quantity → v115 (delta saved to history)
   - Each update: `/togbank share` to broadcast
4. **Player returns**: Log back in with Galdof
5. **Trigger sync**: Metals sends latest delta (expects v115, Galdof has v100)
6. **Observe recovery**: Watch debug output with `/togbank debug`

**Expected Result:**
- ✅ Galdof receives delta expecting v115, detects version mismatch (have v100)
- ✅ Galdof sends `togbank-dr` (Delta Range Request) to Metals for range [v100, v115]
- ✅ Metals responds with `togbank-dc` (Delta Chain) containing 3 deltas
- ✅ Galdof applies chain sequentially: v100→v105→v110→v115
- ✅ Debug shows: "✓ Applied delta chain for Metals-Azuresong (3 hops, v100→v115) in XX.XXms"
- ✅ Bandwidth: Chain (~900B) < Full sync (~1800B)
- ✅ Final state matches if full sync was used

**Debug Output Example:**
```
> Metals-Azuresong > togbank-d2 (Delta Data)
Version mismatch for Metals-Azuresong (have 100, delta expects 115), requesting delta chain
< togbank-dr (Delta Range Request) to Metals-Azuresong (v100→v115)
> Metals-Azuresong > togbank-dc (Delta Chain) (3 hops)
✓ Applied delta chain for Metals-Azuresong (3 hops, v100→v115) in 0.15ms
Delta chain application (adopted)
```

**Fallback Scenarios:**
- **Gap too large**: If v100→v115 requires >10 hops → requests full sync
- **Chain too large**: If total chain >5KB → requests full sync
- **Missing delta**: If Metals doesn't have complete history → requests full sync
- **Chain broken**: If any delta's baseVersion doesn't match → requests full sync

**Test Variations:**
1. **Small gap** (2-3 updates): Should use delta chain
2. **Large gap** (10+ updates): Should fall back to full sync
3. **History expired** (>1 hour old): Should fall back to full sync
4. **Mixed changes** (items + money + bags): Chain should handle all

---

## Test Suite 2: Error Handling & Recovery

### Test 2.1: Version Mismatch Recovery
**Objective:** Verify automatic recovery from version mismatch

**Steps:**
1. Use `/togbank clearsnapshots` to clear all snapshots
2. Manually corrupt version data (development only)
3. Attempt delta sync
4. Observe error handling
5. Check `/togbank deltaerrors` for error details

**Expected Result:**
- "Version mismatch" error logged
- Error recorded in `/togbank deltaerrors` with VERSION_MISMATCH type
- Automatic QueryAlt triggered (or RequestDeltaChain if sender known)
- Full sync requested and received (or delta chain applied)
- Error recorded in deltaMetrics
- Normal operation resumes

**Diagnostic Commands:**
```
/togbank deltaerrors    → Shows recent errors with timestamps
/togbank deltahistory   → Verifies delta history storage
/togbank deltastats     → Confirms failure count incremented
```

---

### Test 2.2: Corrupted Snapshot Detection
**Objective:** Verify snapshot validation works

**Steps:**
1. Create snapshot with valid data
2. Wait for next inventory change
3. Trigger sync
4. Verify snapshot validation

**Expected Result:**
- ValidateSnapshot() checks structure
- Invalid snapshots automatically purged
- Falls back to full sync
- No crashes or data corruption

---

### Test 2.3: Repeated Failure Notification
**Objective:** Verify user notification after 3 failures

**Steps:**
1. Force delta failures (clear snapshots repeatedly)
2. Attempt 3+ delta syncs for same alt
3. Check chat output

**Expected Result:**
- First 2 failures: silent recovery
- 3rd failure: warning message displayed
- Message: "Delta sync failing repeatedly for [alt]"
- Automatic full sync still works

---

## Test Suite 3: Protocol Negotiation

### Test 3.1: v0.7.0 to v0.7.0 Communication
**Objective:** Verify delta sync between two v0.7.0 clients

**Steps:**
1. Ensure both characters have v0.7.0 installed
2. Make inventory changes on bank character
3. Sync and verify delta protocol used
4. Check `/togbank protocol` on both sides

**Expected Result:**
- Both clients show protocol v2
- Delta sync used via togbank-d2 prefix
- Bandwidth savings visible in `/togbank deltastats`

---

### Test 3.2: v0.7.0 to v0.6.8 Compatibility
**Objective:** Verify backward compatibility

**Steps:**
1. Install v0.7.0 on sender
2. Keep v0.6.8 on receiver (or simulate)
3. Sender broadcasts data
4. Verify receiver gets data correctly

**Expected Result:**
- v0.7.0 detects v0.6.8 peer (or lack of v2 support)
- Automatically uses togbank-d (full sync)
- No errors on either side
- Data received correctly

---

### Test 3.3: Mixed Guild Threshold
**Objective:** Verify 50% adoption threshold

**Steps:**
1. Set up guild with mixed versions (simulate)
2. Check `/togbank protocol` for adoption %
3. Verify delta enablement status

**Expected Result:**
- With <50% v0.7.0: Delta disabled, status shows "⚠ Delta sync disabled"
- With ≥50% v0.7.0: Delta enabled, status shows "✓ Delta sync enabled"
- Percentage calculated correctly from online members

---

## Test Suite 4: Performance & Metrics

### Test 4.1: Performance Metrics Accuracy
**Objective:** Verify timing measurements are reasonable

**Steps:**
1. Enable debug output: `/togbank debug`
2. Perform several delta syncs
3. Check `/togbank deltastats` performance section
4. Observe debug timing messages

**Expected Result:**
- Compute time: typically 1-5ms
- Apply time: typically 1-3ms
- Times logged in debug output match stats
- No unusual spikes or errors

---

### Test 4.2: Bandwidth Savings Calculation
**Objective:** Verify bandwidth metrics are accurate

**Steps:**
1. Perform mix of delta and full syncs
2. Record sizes from debug output
3. Check `/togbank deltastats` bandwidth section
4. Manually verify savings calculation

**Expected Result:**
- Delta bytes + full bytes = total bytes
- Savings estimation formula: (estimated full - actual delta) / estimated full
- Percentages add up to 100%
- Savings typically 70-99%

---

### Test 4.3: Success Rate Tracking
**Objective:** Verify success rate calculation

**Steps:**
1. Perform successful delta syncs (should succeed)
2. Force some failures (clear snapshots)
3. Check success rate in `/togbank deltastats`

**Expected Result:**
- Success rate = applied / (applied + failed)
- Color coding: Green ≥95%, Yellow ≥80%, Red <80%
- Accurate count of operations

---

## Test Suite 5: User Commands

### Test 5.1: All Delta Commands Work
**Objective:** Verify each delta-related command functions correctly

**Tests:**
```
/togbank deltastats     → Shows statistics (bandwidth, operations, performance)
/togbank deltaerrors    → Shows recent errors and failure counts
/togbank deltahistory   → Shows stored delta chain history
/togbank protocol       → Shows protocol version distribution
/togbank clearsnapshots → Clears snapshots with confirmation
/togbank forcefull      → Toggles full sync mode
/togbank resetmetrics   → Resets metrics to zero
```

**Expected Result:**
- Each command executes without errors
- Output is formatted correctly with colors
- deltaerrors persists across /reload
- deltahistory shows stored deltas with version transitions

### Test 5.2: Diagnostic Commands Detail
**Objective:** Verify diagnostic commands provide useful information

**deltaerrors command:**
- Shows last 10 errors with timestamps
- Displays error types (VERSION_MISMATCH, NO_DATA, APPLICATION_ERROR, VALIDATION_FAILED)
- Shows failure counts per alt
- Highlights alts with 3+ failures (notified status)
- Color-coded: VERSION_MISMATCH = orange, others = red
- **Persists across /reload** (database storage)

**deltahistory command:**
- Shows total deltas stored per alt
- Lists version transitions (baseVersion → version)
- Shows what changed (bank, bags, money counts)
- Displays age of each delta (seconds/minutes/hours)
- Verifies SaveDeltaHistory() is working

**Example Output:**
```
=== Delta Sync Errors ===
Recent Errors: (2)
  1. [VERSION_MISMATCH] 14:25:30
     Metals-Azuresong: Version mismatch: have 100, delta expects 115
  2. [NO_DATA] 14:20:15
     Galdof-OldBlanchy: No existing data

Failure Counts by Alt:
  Metals-Azuresong: 3 (notified)

=== Delta Chain History ===
Total: 5 delta(s) stored for 1 alt(s)

Metals-Azuresong: 5 delta(s)
  1. v100→v105 (2 change(s), 5m ago)
  2. v95→v100 (1 change(s), 15m ago)
```
- Data displayed matches internal state
- State changes persist (forcefull, resetmetrics)

---

### Test 5.2: Help Text Accuracy
**Objective:** Verify help text matches functionality

**Steps:**
1. Type `/togbank help`
2. Verify all new commands listed in "Expert commands" section
3. Check descriptions are accurate

**Expected Result:**
- All 5 new commands visible
- Descriptions match actual behavior
- Commands categorized correctly as "expert"

---

## Test Suite 6: Edge Cases

### Test 6.1: Empty Inventory Delta
**Objective:** Handle delta with no actual changes

**Steps:**
1. Create snapshot
2. Open/close bank without changes
3. Trigger share

**Expected Result:**
- Delta computed but no changes detected
- Debug: "No changes detected for [alt] (delta would be empty)"
- No delta sent (optimization)

---

### Test 6.2: First-Time Alt with No Snapshot
**Objective:** Verify graceful handling of missing snapshot

**Steps:**
1. Add new bank alt (never synced before)
2. Trigger sync
3. Observe behavior

**Expected Result:**
- No snapshot available (expected)
- Full sync used automatically
- Snapshot created for next sync
- No errors logged

---

### Test 6.3: Snapshot Expiration
**Objective:** Verify 1-hour snapshot expiration

**Steps:**
1. Create snapshot (note timestamp)
2. Wait >1 hour (or manipulate timestamp)
3. Trigger sync

**Expected Result:**
- Snapshot detected as expired
- Automatic cleanup/removal
- Full sync used
- New snapshot created

---

### Test 6.4: Concurrent Updates
**Objective:** Handle multiple rapid updates

**Steps:**
1. Make inventory change
2. Share immediately
3. Make another change quickly
4. Share again

**Expected Result:**
- Both syncs process correctly
- Version numbers increment properly
- No race conditions or corruption
- Snapshots update sequentially

---

## Test Suite 7: Stress Testing

### Test 7.1: Large Inventory (100+ Items)
**Objective:** Verify performance with large inventories

**Steps:**
1. Fill bank with 100+ unique items
2. Change 5-10 items
3. Compute and send delta
4. Measure performance

**Expected Result:**
- Delta computation completes in <50ms
- Delta application completes in <50ms
- Size savings still achieved
- No performance degradation

---

### Test 7.2: Multiple Bank Alts
**Objective:** Test with 5+ bank characters

**Steps:**
1. Configure 5+ bank alts with "gbank" notes
2. Each makes inventory changes
3. All share simultaneously
4. Verify all data received correctly

**Expected Result:**
- All snapshots managed independently
- No cross-contamination of data
- Metrics track all alts separately
- Protocol detection works per-alt

---

### Test 7.3: Rapid Snapshot Creation/Deletion
**Objective:** Verify snapshot cleanup works

**Steps:**
1. Create many snapshots via repeated syncs
2. Use `/togbank clearsnapshots` multiple times
3. Create more snapshots
4. Check memory usage

**Expected Result:**
- Old snapshots cleaned up (1-hour expiration)
- Manual clear works correctly
- No memory leaks
- Database remains stable

---

## Test Suite 8: Integration Testing

### Test 8.1: End-to-End Workflow
**Objective:** Complete realistic user scenario

**Steps:**
1. Fresh install on bank character
2. Configure and scan bank
3. Share with guild
4. Regular member searches for item
5. Regular member requests item
6. Bank character receives request
7. Make inventory changes
8. Delta sync updates guild

**Expected Result:**
- All steps work seamlessly
- Delta sync activates after initial full sync
- Item requests still function normally
- No errors at any step

---

### Test 8.2: Guild Raid Scenario (Stress)
**Objective:** Many members online, frequent updates

**Steps:**
1. Simulate 20+ guild members online
2. Multiple bank characters updating
3. Version broadcasts from all clients
4. Check protocol adoption tracking

**Expected Result:**
- Protocol tracking handles many members
- Delta threshold calculated correctly
- No performance issues
- Bandwidth savings evident

---

## Known Issues & Limitations

### Current Limitations (v0.7.0)
1. **Options Panel**: Delta configuration via commands only (no GUI yet)
2. **Snapshot Expiration**: 1-hour limit means first sync after long offline uses full sync
3. **Adoption Threshold**: Requires 50% of online guild for delta enablement
4. **Large Changes**: >30% inventory changes fall back to full sync

### Not Yet Implemented
- Options panel GUI for delta settings
- Configurable snapshot expiration time
- Adjustable size threshold via UI
- Delta sync history visualization

---

## Regression Testing Checklist

After any code changes, verify these core functions still work:

- [ ] Basic inventory sync (full sync protocol)
- [ ] Item search across multiple banks
- [ ] Item request via mail
- [ ] Bank character scanning and reporting
- [ ] Roster updates (officer function)
- [ ] Version checking and compatibility
- [ ] Database compaction and cleanup
- [ ] Minimap button functionality
- [ ] All existing `/togbank` commands

---

## Test Result Reporting

### Bug Report Template
```
**Test Case:** [Test Suite X.Y: Test Name]
**Expected Result:** [What should happen]
**Actual Result:** [What actually happened]
**Steps to Reproduce:**
1. Step 1
2. Step 2
3. ...

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Number of bank alts: X
- Guild size: Y members

**Debug Output:** [Paste relevant `/togbank debug` output]
**Error Messages:** [Any Lua errors from /console scriptErrors 1]
```

---

## Performance Benchmarks

### Target Performance Metrics
- Delta computation: <10ms for typical inventories
- Delta application: <5ms for typical deltas
- Bandwidth savings: 70-95% for typical updates
- Success rate: >95% under normal conditions
- Memory overhead: <100KB per snapshot

### Acceptable Degradation
- Computation: <50ms acceptable for very large inventories (100+ items)
- Application: <20ms acceptable for complex deltas
- Bandwidth: >50% savings still valuable
- Success rate: >80% acceptable during mixed-version transition

---

## Automated Testing

### Unit Test Execution
```
1. Login to test character
2. Type: /togbank test
3. Review test results (should be all green ✓)
```

### Test Coverage
- Delta computation: 8 tests
- Size estimation: 5 tests
- Protocol negotiation: 3 tests
- Error handling: 5 tests
- Integration: 2 tests
- Backwards compatibility: 3 tests

**Total: 26 automated tests**

---

## Sign-Off Criteria

Before release, ensure:
- [ ] All automated tests pass (/togbank test shows 100% pass rate)
- [ ] Manual testing completed for all Test Suites 1-8
- [ ] No critical bugs or data corruption issues
- [ ] Backwards compatibility verified with v0.6.8
- [ ] Performance within acceptable ranges
- [ ] Documentation complete and accurate
- [ ] Version number updated in TOC
- [ ] CHANGELOG.md updated with all changes
- [ ] README.txt reflects new features

---

**Last Updated:** 2025-01-17
**Test Suite Version:** 1.0 (for TOGBankClassic v0.7.0)

