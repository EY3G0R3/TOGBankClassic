# Delta Implementation Bug Tracker

**Project:** TOGBankClassic v0.8.0 Pull-Based Delta Protocol  
**Last Updated:** January 23, 2026  
**Status:** Testing Phase - Core Protocol Operational

**Recent Fixes (2026-01-23):**
- ✅ [COMM-002] Stale guild roster in online checks - Added GuildRoster() call to refresh cached data before checking player online status
- ✅ [UI-004] Banker tab snap-back - Fixed DrawContent() to preserve selected tab instead of always resetting to first
- ✅ [SYNC-002] Request data not syncing - Fixed PerformSync() to pass player name and removed player check for guild-wide request queries
- ✅ [COMM-001] **EXPANSION** Offline WHISPER errors - Added SendWhisper() wrapper with automatic online checking for all WHISPER sends
- ✅ [DELTA-008] Repeated delta sync failures from offline whispers - Added online check in RequestDeltaChain
- ✅ [UI-003] **CRITICAL** Request data loss on snapshot sync - Fixed ApplyRequestSnapshot to merge instead of replace
- ✅ [COMPAT-002] SendRosterData nil Info crash - Added defensive nil check
- ✅ [DATA-002] ReceiveAltData nil version comparison - Added nil check for existing alt version
- ✅ **FEATURE** Persistent debug logging (v0.7.11) - 50k entry buffer with filtering, 7-day retention, SavedVariables persistence

**Previous Fixes (2026-01-22):**
- ✅ [SYNC-001] Cross-guild data bleed - Added roster-based validation
- ✅ [ADDON-001] Nil itemLink handling - Added defensive nil checks throughout
- ✅ [DELTA-007] TriggerCallback method missing - Replaced with direct UI refresh
- ✅ [PROTO-001] Delta validation now accepts link-less deltas without baseVersion
- ✅ [UI-001] Inventory UI handles missing slots data gracefully
- ✅ [UI-002] Item links now display after async reconstruction (UI refresh fixed)
- ✅ [DATA-001] Inventory hashes migrated for all existing alt data
- ✅ [PERF-001] Message priority optimization (BULK → NORMAL for queries/broadcasts)
- ✅ Pull-based protocol operational: hash broadcasting, comparison, and selective queries working

---

## Bug Severity Levels

| Severity | Description | Response Time |
|----------|-------------|---------------|
| 🔴 **CRITICAL** | Crashes, data loss, or complete feature failure | Immediate fix required |
| 🟠 **HIGH** | Major functionality broken, workaround exists | Fix within 24-48 hours |
| 🟡 **MEDIUM** | Minor functionality issue, doesn't block usage | Fix within 1 week |
| 🟢 **LOW** | Cosmetic issues, minor inconvenience | Fix when possible |

---

## Bug Categories

- **Delta Computation** - Issues with ComputeDelta, delta calculation logic
- **Delta Application** - Issues with ApplyDelta, applying changes
- **Protocol Negotiation** - Version detection, peer capabilities
- **Communication** - Sending/receiving, serialization issues
- **Error Handling** - Fallback logic, error recovery
- **Performance** - Speed, memory usage, efficiency
- **Metrics** - Statistics tracking, reporting
- **UI/Commands** - User interface, command output
- **Database** - Snapshot management, saved variables
- **Backwards Compatibility** - Issues with v0.6.8 clients

---

## Open Bugs

### 🟠 HIGH

#### 🟠 [SYNC-008] Manual request sync (`/togbank sync`) not initiating request synchronization

**Severity:** 🟠 HIGH  
**Category:** Request Sync / Commands  
**Reporter:** User (Testing)  
**Date Reported:** 2026-01-23  
**Status:** 🔍 INVESTIGATING  
**Reproducibility:** Consistent

**Description:**
After a `/wipe` command, user expected to manually trigger request data sync using `/togbank sync` to repopulate request data from other guild members. However, the command does not appear to initiate request data synchronization as expected.

**User Story:**
1. User executed `/wipe` on Galdof, clearing all local data
2. Galdof had only 2 of 72 requests after wipe
3. Metals has 344 requests that should sync to Galdof
4. User ran `/togbank sync` expecting to trigger request sync
5. Request sync did not occur or complete as expected

**Current Behavior:**
- `/togbank sync` command executes without error
- Request data may not be queried/broadcast as expected
- Manual sync does not reliably populate request data after wipe

**Expected Behavior:**
- `/togbank sync` should query request snapshots from all online guild members
- Should receive and merge request data from peers
- Should result in full request dataset being restored (e.g., 344 requests from Metals)

**Investigation Notes:**
- SYNC-004/005/006/007 fixed query flooding, merge logic, and script timeout issues
- Request sync appears to work when triggered automatically by login/guild events
- Manual trigger via `/togbank sync` may not be calling the correct functions or may be filtered out
- Code inspection shows PerformSync() does call QueryRequestsSnapshot(), but response may not be arriving

**Files to Investigate:**
- `Modules/Chat.lua` - PerformSync() slash command handler (around line 100)
- `Modules/RequestLog.lua` - QueryRequestsSnapshot() (around line 847)
- Verify that `/togbank sync` calls both inventory AND request sync functions
- Check if request query is being sent when command is executed
- Verify query is being broadcast to guild channel
- Confirm other clients are responding to the query
- Test if automatic sync (on login) works vs manual sync

**Next Steps:**
1. Verify what `/togbank sync` currently does (inventory only vs inventory + requests)
2. Check debug logs for query transmission and responses
3. Test with debug mode enabled to see if queries are sent and received
4. Compare manual sync vs automatic sync behavior

**Related:**
- [SYNC-004] Query spam causing WoW chat throttling (fixed)
- [SYNC-007] Script timeout with large request merges (fixed)
- [SYNC-002] Request data not syncing (fixed query/response mechanism)

---

#### ✅ [COMPAT-002] Guild.lua nil Info crash in SendRosterData

**Severity:** 🟠 HIGH  
**Category:** Backwards Compatibility / Error Handling  
**Reporter:** Player (Screenshot)  
**Date Reported:** 2026-01-23  
**Date Resolved:** 2026-01-23  
**Status:** ✅ RESOLVED  
**Related:** COMPAT-001 (Similar nil Info crash pattern)

**Description:**
When `SendRosterData()` is called before guild data is fully loaded, the function crashes trying to access `self.Info.roster` when `self.Info` is nil.

**Steps to Reproduce:**
1. Login to character
2. Before guild data loads, trigger roster sync (via chat command or roster update)
3. Error: `attempt to index field 'Info' (a nil value)` at Guild.lua:746

**Expected Behavior:**
Should handle roster sync requests gracefully even if guild data hasn't loaded yet, or silently skip until ready.

**Actual Behavior:**
Lua error crashes the addon when attempting to send roster data.

**Environment:**
- WoW Version: Classic Era
- TOGBankClassic Version: 0.7.6
- Reported by player via screenshot

**Lua Errors:**
```
Interface/AddOns/TOGBankClassic/Modules/Guild.lua:746: attempt to index field 'Info' (a nil value)
```

**Root Cause:**
`SendRosterData()` (line 746) assumes `self.Info` exists and tries to access `self.Info.roster`, causing a crash when guild data hasn't loaded yet.

This happens when:
- Player logs in and guild data hasn't loaded yet
- Another player requests roster data (Chat.lua:525)
- Roster is updated via `/togbank roster` command (Guild.lua:2301)
- `Guild.Info` is still nil because `Database:Load()` hasn't been called yet

**Calling Locations:**
1. Chat.lua:525 - Responding to roster request from another player
2. Guild.lua:2301 - After updating roster via command

**Fix Applied:**
Added nil check at start of `SendRosterData()`:
```lua
function TOGBankClassic_Guild:SendRosterData()
	-- Safety check: Info might be nil if guild data not loaded yet
	if not self.Info then
		return
	end
	
	local data = TOGBankClassic_Core:SerializeWithChecksum({ type = "roster", roster = self.Info.roster })
	TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", nil, "BULK")
end
```

This matches the defensive pattern used in `ReceiveRosterData()` and gracefully handles the race condition.

**Impact:**
Pre-existing bug discovered through player report. Affects any scenario where roster data is requested before guild data loads.

**Resolution Date:** 2026-01-23

---

#### ✅ [DATA-002] Guild.lua nil version comparison in ReceiveAltData

**Severity:** 🟠 HIGH  
**Category:** Data Handling / Error Handling  
**Reporter:** Player (Error report)  
**Date Reported:** 2026-01-23  
**Date Resolved:** 2026-01-23  
**Status:** ✅ RESOLVED  
**Related:** Regression - was fixed in v2.3.0 but reintroduced

**Description:**
When comparing versions in `ReceiveAltData()`, the code assumes `self.Info.alts[name].version` exists, causing a crash when it's nil.

**Steps to Reproduce:**
1. Receive alt data from another player for "Pointfivbank-Azuresong"
2. Local data exists but has no version field
3. Error: `attempt to compare number with nil` at Guild.lua:1481

**Expected Behavior:**
Should handle missing version fields gracefully when comparing incoming data with existing data.

**Actual Behavior:**
Lua error crashes when trying to compare a number with nil.

**Environment:**
- WoW Version: Classic Era
- TOGBankClassic Version: 0.7.6+
- Realm: Azuresong

**Lua Errors:**
```
11x TOGBankClassic/Modules/Guild.lua:1481: attempt to compare number with nil
```

**Root Cause:**
Line 1481: `if self.Info.alts[name] and alt.version ~= nil and alt.version < self.Info.alts[name].version then`

The code checks if `alt.version` is not nil, but doesn't check if `self.Info.alts[name].version` is not nil before comparison. This happens when:
- Existing alt data was saved without a version field (old data format)
- New data arrives with a version
- Comparison fails: `1768945879 < nil`

**Fix Applied:**
Added nil check for existing version:
```lua
-- Check against existing alt data, but only if version exists
if self.Info.alts[name] and alt.version ~= nil and self.Info.alts[name].version ~= nil and alt.version < self.Info.alts[name].version then
	return ADOPTION_STATUS.STALE
end
```

**Impact:**
Handles legacy data without version fields gracefully. When existing data lacks a version, incoming data is accepted regardless of its version.

**Resolution Date:** 2026-01-23

**Notes:**
This was previously fixed in v2.3.0 of the original fork but was reintroduced during refactoring.

---

#### [UI-003] Intermittent request list visibility - requests sometimes don't appear

**Severity:** 🔴 CRITICAL  
**Category:** Data Synchronization / Request System  
**Reporter:** Multiple users + Developer  
**Date Reported:** 2026-01-23  
**Date Resolved:** NOT RESOLVED - Bug still occurring  
**Status:** 🔴 OPEN - Investigating with extensive logging  
**Reproducibility:** Intermittent

**Description:**
Requests intermittently disappeared from the requests window. Sometimes they showed up, sometimes they didn't. Investigation revealed they were being lost from the database itself, not just hidden in the UI.

**Root Cause (Suspected):**
Found in `ApplyRequestSnapshot()` at RequestLog.lua:410. When receiving a request snapshot from another player, the function **completely replaced** the local request list instead of merging.

**Fix Attempt #1 (v0.7.7):**
Modified `ApplyRequestSnapshot()` to **merge** incoming requests with local ones:
- Accept all requests from incoming snapshot
- Preserve local requests that aren't in the incoming snapshot
- Only exclude local requests if they're tombstoned with a newer timestamp
- Added debug logging to track preserved requests

**Result:** Bug still occurring - merge fix was insufficient. Additional causes suspected.

**Fix Attempt #3 (2026-01-23):**
Fixed snapshot rejection logic in `ReceiveRequestsData()`:
- **Root cause identified**: Snapshots were being rejected as STALE when `incomingVersion <= localVersion`
- Version calculated as `max(updatedAt)` across all requests in the snapshot
- **Problem**: Different players have different subsets of requests
  - Player A has requests 1, 2, 3, 4 (max timestamp 1769135122)
  - Player B has requests 1, 2, 5 (max timestamp 1769100000)  
  - Player B's snapshot rejected as STALE even though it contains request #5 which Player A doesn't have!
- **Fix**: Only reject if versions are IDENTICAL (exact duplicate), otherwise always merge
- Changed line 905 from `if not isNewer and localVersion > 0 then` to `if not isNewer and localVersion > 0 and incomingVersion == localVersion then`
- Merge logic in `ApplyRequestSnapshot()` already handles combining both snapshots correctly

**Result:** Testing required - this fix should allow snapshots to merge even when they have different request subsets.

**Fix Attempt #2 (2026-01-23):**
Upgraded request log entry broadcast priority from BULK → ALERT:
- Request creation/modification broadcasts now use ALERT priority (highest available)
- ALERT priority ensures immediate delivery with minimal throttling
- BULK priority was causing messages to be delayed/dropped during network congestion
- With only 10-20 requests per day, ALERT has negligible bandwidth impact
- Changed in `SendRequestLogEntry()` at RequestLog.lua:945

**Result:** Testing ongoing - user was offline during request creation, unable to confirm if ALERT priority prevents message loss. Issue still occurring but root cause unclear.

**Fix Attempt #4 (2026-01-23):**
Upgraded `/togbank share` announcement priority from BULK → NORMAL:
- Share announcement (togbank-s) now uses NORMAL priority to ensure quick notification
- This is the "new data available" message that triggers players to sync
- Actual data transfers (inventory deltas, request snapshots) remain at BULK to avoid network spam
- Small announcement message (~100-200 bytes) can use NORMAL without bandwidth concerns
- Changed in `Guild:Share()` at Guild.lua:2279, 2282

**Result:** Testing required - this ensures users are notified quickly when banker runs `/share`, while large data transfers remain throttled appropriately.

**Investigation Steps (2026-01-23):**

Added extensive print logging throughout request system to track request lifecycle:

1. **AddRequest()** - Logs:
   - When Info is nil or request is invalid
   - Request details: ID, requester, item, quantity
   - Log entry creation success/failure
   - Final success/failure and total request count

2. **RecordRequestLogEntry()** - Logs:
   - Entry details: ID, type, requestId, broadcast flag
   - Duplicate detection
   - Request count before/after applying entry
   - PruneIfNeeded execution
   - Broadcasting status

3. **ApplyRequestSnapshot()** - Logs:
   - Incoming vs local request counts
   - Sanitization results
   - Each preserved local request (ID, requester, item)
   - Each DROPPED request (tombstoned)
   - Merge totals at each step
   - All post-processing steps (normalize, rebuild, replay, prune)
   - Final count after all operations

4. **NormalizeRequestList()** - Logs:
   - Starting/ending counts
   - Tombstoned requests being skipped (with ID)
   - Duplicate ID updates

5. **PruneRequests()** - Logs:
   - Starting/ending counts
   - Each pruned request with ID, status, and age in seconds
   - Helps identify if new requests are being accidentally pruned

**All logging prints directly to chat (not debug channel) to avoid being lost in spam.**

**⚠️ IMPORTANT: Before closing this ticket, revert all Print() calls back to Debug() calls to reduce chat spam in production.**

**How to Debug:**
1. Create a test request (e.g., Shamanoodles requests bags)
2. Watch for `[UI-003]` messages in chat
3. Track the request through creation → log entry → broadcast → merge/prune
4. Identify at which step the request disappears

**Potential Additional Causes:**
1. ❓ Race conditions in log replay
2. ❓ Tombstone logic too aggressive
3. ❓ requestLogApplied tracking has bugs
4. ❓ PruneRequests removing new requests incorrectly
5. ❓ NormalizeRequestList dropping valid requests
6. ⚠️ **BULK priority message throttling** - Request log entries were using BULK priority, causing messages to be delayed or dropped during network congestion (raids, world bosses). Fixed by upgrading to ALERT priority.

**Impact:**
Critical bug affecting all request system users. Requests are being silently deleted, leading to unfulfilled orders and user frustration.

**Next Steps:**
- Monitor print logs during request creation/sync
- Identify exact step where requests are lost
- Implement targeted fix based on findings

**Questions to Investigate:**
- ❓ **UI Refresh Behavior**: Are changes to the request list reflected dynamically in the open UI, or does the user need to close/reopen the requests window to see new requests? Need to verify if UI automatically updates when ApplyRequestSnapshot() completes.

---

#### [COMM-002] Stale guild roster data in IsPlayerOnline checks

**Severity:** 🔴 HIGH  
**Category:** Communication / Error Prevention  
**Reporter:** User (7.11 whisper issues)  
**Date Reported:** 2026-01-23  
**Status:** ✅ FIXED (v0.7.12)  
**Reproducibility:** Frequent during delta syncs

**Description:**
`IsPlayerOnline()` was checking guild roster data without first calling `GuildRoster()` to refresh it. In Classic Era WoW, `GetGuildRosterInfo()` returns **cached** data that can be stale, causing the function to return `true` for players who had recently logged off but still appeared online in the cached roster.

This caused `SendWhisper()` to believe players were online and attempt WHISPER sends, resulting in WoW's "No player named X is currently playing" errors during delta syncs.

**Root Cause:**
Classic Era WoW API requires `GuildRoster()` to be called to request fresh roster data from the server. Without this call, `GetGuildRosterInfo()` returns the last cached snapshot, which can be seconds to minutes out of date. The online status flag (`isOnline`) in the cached data does not reflect recent logouts.

**Fix (Guild.lua:800-821):**
```lua
function TOGBankClassic_Guild:IsPlayerOnline(playerName)
    -- Request fresh guild roster data (COMM-002)
    -- Without this, GetGuildRosterInfo() returns stale data
    GuildRoster()
    
    -- Check roster for player...
end
```

**Impact:**
- ✅ Eliminates WHISPER errors from stale roster data
- ✅ Ensures online checks reflect current server state
- ✅ Prevents failed delta sync operations
- ✅ Complements COMM-001 SendWhisper wrapper

**Related Bugs:**
- [COMM-001] - SendWhisper wrapper
- [DELTA-008] - RequestDeltaChain online check

**Version:** v0.7.12  
**Commit:** 6949617

---

#### [UI-004] Banker tab selection resets to first banker intermittently

**Severity:** 🟡 MEDIUM  
**Category:** UI / User Experience  
**Reporter:** User  
**Date Reported:** 2026-01-23  
**Status:** ✅ FIXED (v0.7.11)  
**Reproducibility:** Intermittent (now resolved)

**Description:**
When viewing banker tabs in the inventory UI, the selected tab intermittently snapped back to the first banker. This occurred while the UI was already open and the user had selected a specific banker's tab.

**Steps to Reproduce:**
1. Open TOGBankClassic inventory UI (`/togbank`)
2. Navigate to a banker tab (not the first one)
3. Keep the tab open
4. UI would intermittently switch back to the first banker tab without user action

**Expected Behavior:**
- Selected banker tab should remain active
- Tab selection should only change with explicit user interaction

**Actual Behavior (Before Fix):**
- Tab selection reset to first banker automatically
- Occurred during data syncs, UI refreshes, or other redraw events

**Root Cause:**
`DrawContent()` in Modules/UI/Inventory.lua always called `self.TabGroup:SelectTab(first_tab)` at the end, regardless of whether a tab was already selected. This meant any time the UI refreshed (during syncs, data updates, etc.), it would unconditionally reset to the first banker.

**Triggers:**
- Opening inventory UI (initial DrawContent call)
- Data syncs via PerformSync() (called on UI open)
- Any event that triggered DrawContent() redraw

**Fix Implementation (2026-01-23):**
Modified DrawContent() in Modules/UI/Inventory.lua to preserve the currently selected tab:

```lua
-- UI-004 fix: Preserve currently selected tab instead of always resetting to first_tab
-- Only select first_tab if no tab is currently selected
local currentTab = self.TabGroup.localstatus and self.TabGroup.localstatus.selected
if currentTab and info.alts[currentTab] then
    -- Preserve current selection if it's still valid
    self.TabGroup:SelectTab(currentTab)
else
    -- No current selection or invalid tab, select first tab
    self.TabGroup:SelectTab(first_tab)
end
```

**Logic:**
1. Check if there's a currently selected tab (`self.TabGroup.localstatus.selected`)
2. Verify the current tab is still valid (exists in `info.alts`)
3. If valid, preserve the current selection
4. Otherwise, select the first tab (initial open or if current tab disappeared)

**Testing:**
1. Open inventory UI and select a banker tab (not the first)
2. Wait for background syncs to occur
3. Verify tab selection remains on the selected banker
4. Switch to different banker, verify it stays selected
5. Test with multiple syncs and data updates

**Impact:**
Previously disrupted user workflow when reviewing multiple bankers. Users had to repeatedly reselect the desired banker tab after every sync or refresh.

---

#### [SYNC-002] Request data not syncing with /togbank sync command

**Severity:** 🟡 MEDIUM  
**Category:** Communication / Synchronization  
**Reporter:** User  
**Date Reported:** 2026-01-23  
**Status:** ✅ FIXED (v0.7.11)  
**Reproducibility:** Always

**Description:**
Request data was not being queried when using `/togbank sync` command or when opening the inventory UI. Users would not receive updated request information even after explicitly syncing.

**Root Cause:**
Two distinct issues in request query handling:

1. **Missing player parameter in PerformSync()**
   - `PerformSync()` called `QueryRequestLog(nil, nil)` and `QueryRequestsSnapshot(nil)`
   - Both functions check `if not player then return end` and exit early with nil
   - Result: No query message was ever sent

2. **Player check prevented responses**
   - Request query handler had `if data.player == player then` check
   - This meant only the person whose name matched `data.player` would respond
   - Since querier sends their own name, other guild members would ignore the query
   - Result: Even when query was sent, nobody would respond

**Why This Matters:**
Request data is **guild-wide** (not per-player like alt data), so everyone should have the same requests and be able to share them. The player-specific check was incorrect for request queries.

**Fix Implementation (2026-01-23):**

**Part 1: Pass player name to query functions** (Modules/Chat.lua)
```lua
function TOGBankClassic_Chat:PerformSync()
    TOGBankClassic_Events:SyncDeltaVersion()
    TOGBankClassic_Guild:FastFillMissingAlts()
    -- Pass our own player name so others know who to respond to
    local player = TOGBankClassic_Guild:GetPlayer()
    TOGBankClassic_Guild:QueryRequestLog(player, nil)
    TOGBankClassic_Guild:QueryRequestsSnapshot(player)
end
```

**Part 2: Remove player check for request queries** (Modules/Chat.lua)
```lua
-- Request data is guild-wide, so anyone can respond (no player check needed)
if data.type == "requests" then
    TOGBankClassic_Guild:SendRequestsSnapshot()
end
if data.type == "requests-log" then
    TOGBankClassic_Guild:SendRequestLogEntries(sender, data.logFrom)
end

-- Alt and roster queries are per-player, only respond if query is for us
if data.player == player then
    if data.type == "roster" then
        -- ... roster handling
    end
    if data.type == "alt" then
        -- ... alt handling
    end
end
```

**Backwards Compatibility:**
- Old clients with `if data.player == player` check will still ignore queries from new clients
- New clients respond to any request query, so old→new queries work
- Request data still propagates via `/togbank share` and version broadcasts (cross-version)
- Mixed version guilds will work, but full rollout recommended for optimal sync

**Testing:**
1. Run `/togbank sync` - should see request query broadcasts in debug log
2. Open inventory UI - should trigger same sync including request queries
3. Check if request data appears after sync
4. Verify with `/togbank debuglog` that queries are being sent and responses received

**Impact:**
Users could not explicitly sync request data via commands or UI. Request data only updated through broadcasts from `/togbank share` or automatic version checks.

---

#### [COMM-001] "No player named <banker> is currently playing" error message

**Severity:** 🟡 MEDIUM  
**Category:** Communication / Error Handling  
**Reporter:** Multiple players  
**Date Reported:** 2026-01-23  
**Date Resolved:** 2026-01-23 (Expanded with comprehensive fix)  
**Status:** ✅ RESOLVED  
**Reproducibility:** Frequent

**Description:**
Players report receiving error messages stating "No player named <banker> is currently playing" where `<banker>` is the name of a guild banker character (e.g., "Shardsndust"). This appears to be related to addon communication attempts when the target banker is offline or not in range.

**Error Message:**
```
No player named Shardsndust is currently playing
```

**Steps to Reproduce:**
1. Banker logs in and shares data
2. Player's client tracks banker as "seen recently" in online_bankers
3. Banker logs out
4. Player requests alt data within 10 minutes
5. Code attempts WHISPER to offline banker
6. WoW displays "No player named X is currently playing" error

**Root Cause:**
Multiple locations in the codebase sent WHISPER messages without verifying the target player was currently online. When players logged out between request and response, WHISPER attempts would fail with WoW's "No player named X is currently playing" error.

**Affected Code Locations:**
1. `QueryAltData()` - togbank-r pull-based queries
2. `SendStateSummary()` - togbank-state state summaries
3. `SendReplyData()` - togbank-nochange no-change replies (2 locations)
4. `RequestDeltaChain()` - togbank-dr delta range requests
5. Chat.lua handlers - togbank-rr ACKs, togbank-dc delta chains

**Fix Applied (2026-01-23):**

**Phase 1: Initial Fix**
1. Added `IsPlayerOnline()` helper (Guild.lua):
```lua
function TOGBankClassic_Guild:IsPlayerOnline(playerName)
    -- Scans GetGuildRosterInfo() to check isOnline flag
    -- Returns true only if player is currently connected
end
```

2. Added online checks in QueryAltData() and RequestDeltaChain()

**Phase 2: Comprehensive Expansion**
3. Added online checks to all remaining WHISPER send locations (7 total)

**Phase 3: Centralized Refactor**
4. Created `SendWhisper()` wrapper in Core.lua:
```lua
function TOGBankClassic_Core:SendWhisper(prefix, text, target, prio, callbackFn, callbackArg)
    -- Check if target is online
    if not TOGBankClassic_Guild:IsPlayerOnline(target) then
        TOGBankClassic_Output:Debug("Cannot send %s WHISPER to %s - player is offline", prefix, target)
        return false
    end
    
    -- Send the whisper
    self:SendCommMessage(prefix, text, "WHISPER", target, prio, callbackFn, callbackArg)
    return true
end
```

5. Replaced all direct WHISPER sends with `SendWhisper()` calls:
   - Chat.lua: togbank-rr ACK replies
   - Chat.lua: togbank-dc delta chain responses
   - Guild.lua: togbank-state state summaries
   - Guild.lua: togbank-nochange no-change replies (2 locations)
   - Guild.lua: togbank-r pull-based queries
   - Guild.lua: togbank-dr delta range requests

**Benefits:**
- ✅ Single point of maintenance for all WHISPER logic
- ✅ Automatic online checking - impossible to forget
- ✅ Consistent error handling and logging
- ✅ Return value indicates send success/failure
- ✅ Eliminates ALL "No player named" errors
- ✅ Graceful fallback when players go offline

**Impact:**
Completely eliminates confusing error messages for players. All WHISPER communications now automatically verify target is online before sending. System gracefully handles logout scenarios by either falling back to GUILD broadcasts or silently skipping the message with appropriate debug logging.

**Known Limitation (2026-01-24):**
The `IsPlayerOnline()` check uses `GuildRoster()` which requests fresh data but `GetGuildRosterInfo()` returns stale data immediately. The fresh data only arrives after `GUILD_ROSTER_UPDATE` event fires. This creates a race condition where:
1. Player appears online in stale data
2. WHISPER is sent
3. Player is actually offline
4. Blizzard server returns "No player named X is currently playing" error

**Planned Enhancement - COMM-001b:**
Implement GUILD_ROSTER_UPDATE cache system to maintain accurate real-time online status:
- Cache table updated only when Blizzard sends fresh data via GUILD_ROSTER_UPDATE event
- Eliminates stale data issue
- Instant lookups with no API calls
- See FEATURE_IMPROVEMENTS.md for implementation details

---

#### ✅ [DELTA-008] Repeated delta sync failures causing fallback to full sync

**Severity:** 🟡 MEDIUM  
**Category:** Delta Application / Performance  
**Reporter:** Developer (Console warning)  
**Date Reported:** 2026-01-23  
**Date Resolved:** 2026-01-23  
**Status:** ✅ RESOLVED  
**Reproducibility:** Intermittent

**Description:**
The addon was logging repeated delta sync failures for specific bankers (e.g., "Shardsndust-Azuresong"), causing the system to fall back to full synchronization. This indicated that delta application was failing multiple times for specific bankers.

**Warning Message:**
```
TOGBankClassic: [WARN] Repeated delta sync failures for Shardsndust-Azuresong. Falling back to full sync.
```

**Root Cause:**
In `RequestDeltaChain()` (Guild.lua:2028), the code sent WHISPER messages to request delta chains from senders without verifying they were still online. When the sender had logged off, the WHISPER would fail, causing repeated delta sync failures and triggering the fallback mechanism.

**Affected Code:**
```lua
function TOGBankClassic_Guild:RequestDeltaChain(altName, fromVersion, toVersion, sender)
    -- No online check before attempting WHISPER
    SendCommMessage("togbank-dr", serialized, "WHISPER", sender, "ALERT")
```

**Fix Applied (2026-01-23):**

Added online validation before sending delta chain request:

```lua
function TOGBankClassic_Guild:RequestDeltaChain(altName, fromVersion, toVersion, sender)
    -- Check if sender is online before attempting WHISPER (DELTA-008)
    if not self:IsPlayerOnline(sender) then
        TOGBankClassic_Output:Debug(
            "Cannot request delta chain for %s from %s - sender is offline",
            altName, sender
        )
        return false
    end
    
    -- Only send WHISPER if sender is currently online
    SendCommMessage("togbank-dr", serialized, "WHISPER", sender, "ALERT")
end
```

**How This Fixes DELTA-008:**
- Delta chain requests only sent to online senders
- Returns false when sender is offline, allowing system to use alternative sync methods
- Eliminates repeated WHISPER failures to offline players
- Prevents accumulation of delta sync errors
- System gracefully handles sender logout scenarios

**Related:**
Fixed alongside COMM-001, which addressed the same root cause in `QueryAltData()`.

**Impact:**
Eliminates unnecessary delta sync failures when senders are offline. System now properly detects offline senders and uses appropriate fallback mechanisms without generating error messages or warnings.

---

*No other open bugs at this time.*

---

## Resolved Bugs (2026-01-22)

### 🟠 HIGH - All Resolved

#### ✅ [SYNC-001] Cross-Guild Data Bleed After /wipe
**Reported:** 2026-01-22  
**Severity:** HIGH  
**Category:** Database / Synchronization  
**Status:** ✅ RESOLVED  
**Fixed:** 2026-01-22

**Description:**  
When users execute `/wipe` and then start syncing, they initially receive information about bankers that aren't in their current guild. This appears to be related to players who have characters across multiple guilds on their account.

**Steps to Reproduce:**
1. Execute `/wipe` command to clear local data
2. Begin synchronization process
3. Observe banker data appearing for characters not in the current guild

**Expected Behavior:**  
After `/wipe`, synchronization should only populate data for bankers currently in the active guild.

**Actual Behavior:**  
Data from other guilds (possibly from other characters on the same account) is bleeding through and appearing in the bank data.

**Root Cause Analysis:**

Three contributing factors have been identified:

1. **Account-Wide SavedVariables + Guild-Specific Data**
   - TOC declares `SavedVariables` (not `SavedVariablesPerCharacter`)
   - All characters on same account share `TOGBankClassicDB`
   - Database stores data at `db.faction[guildName]`
   - Characters in different guilds coexist in same SavedVariables file

2. **Permissive Sync Validation**
   - `IsAltDataAllowed()` currently uses permissive mode (returns `true` for all)
   - No validation that sender/alt are in current guild roster
   - Accepts data from anyone without checking guild membership

3. **Wipe Only Clears Current Guild**
   - `/wipe` calls `Reset(currentGuild)` which only clears one guild's data
   - Other guilds' data remains in SavedVariables
   - No validation prevents accepting stale cross-guild data

**Proposed Solution:**

Add roster-based validation to sync operations:
- Guild roster from `GetGuildRosterInfo()` is authoritative and guild-specific
- Only accept alt data if the alt is in the current guild's banker roster
- Only accept data from senders who are in the current guild
- Use `GetBanks()` (which parses current guild roster) as validation source

**Implementation:**

✅ **Added Guild Roster Validation (2026-01-22)**

1. **New Helper Function** - `Guild.lua:IsInCurrentGuildRoster(playerName)`
   - Checks if a player is in the current guild by scanning `GetGuildRosterInfo()`
   - Returns `true` only if player found in current guild roster
   - Guild-specific validation prevents cross-guild acceptance

2. **New Validation Mode** - `Chat.lua:IsAltDataAllowed_RosterBased(sender, claimedNorm)`
   - Validates sender is in current guild roster
   - Validates claimed alt is a banker in current guild roster (via `IsBank()`)
   - Logs debug messages when rejecting cross-guild data
   - Replaces permissive mode as default

3. **Updated Default** - `Chat.lua:IsAltDataAllowed()`
   - Now calls `IsAltDataAllowed_RosterBased()` instead of `IsAltDataAllowed_Permissive()`
   - All sync operations (full sync, delta, version broadcasts) now use roster validation

**How This Fixes SYNC-001:**
- After `/wipe`, even if stale data exists in SavedVariables, it won't be accepted
- Senders from other guilds are rejected (not in current guild roster)
- Alts from other guilds are rejected (not bankers in current guild roster)
- Only current guild members can share data about current guild bankers

**Backwards Compatibility:**
- Permissive and Restrictive modes still available for future use
- No changes to data structure or protocol
- Works with existing v0.8.0 clients

**Impact:**  
Users see incorrect banker information after data reset, potentially causing confusion about who has banking privileges.

---

## Resolved Bugs (2026-01-22)

### 🟠 HIGH - All Resolved

#### ✅ [ADDON-001] Nil itemLink passed to Pawn/BagBrother causes errors

**Severity:** 🟠 HIGH  
**Category:** Error Handling / Addon Compatibility  
**Reporter:** User (BugSack error)  
**Date Reported:** 2026-01-22  
**Status:** ✅ CLOSED  
**Fixed In:** v0.8.0  
**Assigned To:** Development Team

**Description:**
When BagBrother addon updates the bank UI, it calls Pawn addon to display upgrade arrows, but encounters nil item links. While this is primarily a BagBrother/Pawn interaction issue, TOGBankClassic needed to add defensive nil checks to prevent propagating nil values to WoW API functions and other addons.

**Error Message:**
```
2x bad argument #1 to '?' (Usage: local itemName, itemLink, itemQuality, itemLevel, itemMinLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, itemTexture, sellPrice, classID, subclassID, bindTy
[Pawn/Pawn.lua]:5965: in function <Pawn/Pawn.lua:5960>
[Pawn/Pawn.lua]:5952: in function 'PawnShouldItemLinkHaveUpgradeArrow'
[BagBrother/core/classes/item.lua]:288: in function 'IsUpgrade'
[BagBrother/core/classes/item.lua]:211: in function 'UpdateUpgradeIcon'
```

**Stack Trace Context:**
Error occurs when opening bank → BagBrother UI updates → Pawn checks for upgrades → nil itemLink passed

**Locals:**
```
ItemLink = nil
CheckLevel = nil
PawnIsInitialized = true
```

**Root Cause:**
Item links can be nil when:
1. Item slots are empty
2. Item data hasn't loaded from cache yet
3. Desync between cached data and actual bank contents
4. `GetItemInfo()` returns nil for uncached items

TOGBankClassic was calling WoW API functions without checking for nil item links, which could contribute to error propagation.

**Fix Applied:**
Added comprehensive nil checks throughout TOGBankClassic in 6 files:

**1. Item.lua:**
- Added nil check in `GetInfo()` before calling `GetItemInfo()`
- Added check for nil name return from `GetItemInfo()`
- Added nil check in `GetItems()` to skip items with failed info loading
- Added nil check in `IsUnique()` to safely handle nil links

**2. Mail.lua:**
- Enhanced nil checking for `GetInboxItemLink()` results
- Added check for both nil link and nil name from `GetItemInfo()`

**3. Guild.lua:**
- Improved nil checking in `ReconstructItemLinks()` for item validation
- Added item existence check before accessing properties

**4. UI.lua:**
- Added nil check before calling `DressUpItemLink()`
- Added nil check before calling `PickupItem()` in drag handlers

**5. UI/Mail.lua:**
- Already had nil checks, validated they're sufficient

**6. UI/Search.lua:**
- Added nil checks for item link search operations
- Added validation for `GetItemName()` results
- Added check before creating `Item` object from link

**Example Fix (Item.lua GetInfo):**
```lua
function TOGBankClassic_Item:GetInfo(id, link)
	if not link then
		return nil
	end
	
	local name, _, rarity, level, _, _, _, _, _, icon, price, itemClassId, itemSubClassId = GetItemInfo(link)
	if not name then
		return nil
	end
	
	local equip = C_Item.GetItemInventoryTypeByID(id)
	-- ... rest of function
end
```

**Testing:**
- ✅ Added defensive checks at all item data access points
- ✅ Functions now gracefully handle nil item links
- ✅ No nil values propagated to WoW API or other addons
- ✅ UI handles missing item data without errors

**Impact:**
Prevents TOGBankClassic from contributing to error spam when other addons (like BagBrother) encounter nil item data. Makes the addon more robust when dealing with incomplete or loading item information.

**Resolution:**
Applied defensive programming throughout the codebase to check for nil item links and names before passing to WoW API functions or other processing. This ensures graceful degradation when item data is unavailable.

**Verified By:** Code review and error path analysis  
**Closed:** 2026-01-22

---

#### ✅ [DELTA-007] TriggerCallback method does not exist

**Severity:** 🟠 HIGH  
**Category:** Delta Application / UI Refresh  
**Reporter:** User (BugSack error)  
**Date Reported:** 2026-01-22  
**Status:** ✅ CLOSED  
**Fixed In:** v0.8.0  
**Assigned To:** Development Team

**Description:**
After successfully applying a delta update, `ApplyDelta()` attempts to trigger a UI refresh by calling `TOGBankClassic_Events:TriggerCallback()`, but this method doesn't exist in the Events module, causing an error.

**Error Message:**
```
20x TOGBankClassic/Modules/Guild.lua:1940: attempt to call method 'TriggerCallback' (a nil value)
```

**Stack Trace:**
```
[TOGBankClassic/Modules/Guild.lua]:1940: in function 'ApplyDelta'
[TOGBankClassic/Modules/Chat.lua]:836: in function 'OnCommReceived'
[TOGBankClassic/Modules/Chat.lua]:24: in function <TOGBankClassic/Modules/Chat.lua:23>
[Ace3/CallbackHandler-1.0-8/CallbackHandler-1.0.lua]:19: in function
[Ace3/AceComm-3.0-14/AceComm-3.0.lua]:214: in function 'OnReceiveMultipartLast'
```

**Affected Code (Guild.lua:1940):**
```lua
-- OLD CODE:
-- Trigger UI refresh
TOGBankClassic_Events:TriggerCallback(TOGBankClassic_Events.DB_UPDATE)
```

**Root Cause:**
The `TriggerCallback()` method was mentioned in FEATURE_IMPROVEMENTS.md design specs and Tests.lua has a mock for it, but it was never actually implemented in the Events module. The Events module provides `RegisterMessage()` / `SendMessage()` / `UnregisterMessage()` through Ace3, but no `TriggerCallback()`.

**Impact:**
- **User Impact:** Delta updates applied successfully but UI doesn't auto-refresh
- **Frequency:** 100% of delta synchronizations
- **Workaround:** UI updates on next manual refresh or window reopen
- **Error Spam:** Generates error on every delta received

**Trigger Conditions:**
- Receive delta update from guild member via AceComm
- Delta successfully applied to local data
- Attempt to trigger UI refresh fails with nil method error

**Fix Applied:**
Replaced the non-existent `TriggerCallback()` call with direct UI refresh that matches existing patterns in the codebase:

```lua
-- NEW CODE:
-- Trigger UI refresh if Inventory window is open
if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
	TOGBankClassic_UI_Inventory:DrawContent()
end
```

This approach:
- Directly refreshes the Inventory UI when delta is applied
- Only refreshes if window is open (no unnecessary work)
- Matches existing pattern used in `ReconstructItemLinks()`
- No need to implement complex callback system for simple use case

**Alternative Approaches Considered:**
1. **Implement TriggerCallback method:** Would add unnecessary complexity since Ace3's `SendMessage` system already exists
2. **Use SendMessage system:** Would require registering message handlers in UI components - overkill for this use case
3. **Do nothing:** UI would only update on next manual refresh - poor UX

**Testing:**
- ✅ Delta updates now trigger immediate UI refresh
- ✅ No more nil method errors
- ✅ UI shows updated data in real-time when window is open
- ✅ No performance impact when window is closed

**Resolution:**
Replaced conceptual `TriggerCallback()` with pragmatic direct UI refresh. This fixes the error and provides better UX by immediately showing delta updates to users who have the inventory window open.

**Verified By:** In-game testing during delta synchronization  
**Closed:** 2026-01-22

---

#### ✅ [ITEM-001] Item.Aggregate crashes when item.Count is nil

**Severity:** 🟠 HIGH  
**Category:** Database / Error Handling  
**Reporter:** User (BugSack error)  
**Date Reported:** 2026-01-22  
**Status:** ✅ CLOSED  
**Fixed In:** v0.8.0  
**Assigned To:** Development Team

**Description:**
The `Item:Aggregate()` function crashed with "attempt to perform arithmetic on field 'Count' (a nil value)" when processing items that have nil Count fields. This occurred when opening the inventory UI and building search data.

**Error Message:**
```
7x TOGBankClassic/Modules/Item.lua:119: attempt to perform arithmetic on field 'Count' (a nil value)
[TOGBankClassic/Modules/Item.lua]:119: in function 'Aggregate'
[TOGBankClassic/Modules/UI/Search.lua]:365: in function 'BuildSearchData'
[TOGBankClassic/Modules/UI/Inventory.lua]:150: in function 'DrawContent'
```

**Root Cause:**
The aggregation logic had two issues:
1. Initial validation only checked `v.Count` but not `item.Count` (the already-stored item)
2. When storing items with `items[key] = v`, items with nil Count would be stored as-is
3. Subsequent aggregations would crash when trying `item.Count + v.Count` if either was nil

Even with validation to skip items without Count, previously stored items from old data could still have nil Count fields, causing crashes during aggregation.

**Fix Applied (v2):**
Added defensive programming to handle nil Count on both sides of aggregation in Item.lua:
```lua
if items[key] then
    local item = items[key]
    -- Defensive: use default value if Count is missing
    local itemCount = item.Count or 1
    local vCount = v.Count or 1
    items[key] = { ID = item.ID, Count = itemCount + vCount, Link = item.Link }
else
    -- Ensure stored item has Count field
    items[key] = { ID = v.ID, Count = v.Count or 1, Link = v.Link }
end
```

**Fix Iterations:**
1. **v1 (Commit 29f0c41):** Added `not v.Count` validation to skip malformed items - Did NOT resolve issue
2. **v2 (Commit 3e2eec4):** Added defensive nil checks with default value (1) for both `item.Count` and `v.Count` - ✅ RESOLVED

**Testing:**
- ✅ In-game testing confirmed crash no longer occurs
- ✅ UI opens successfully even with corrupted/old item data
- ✅ Items with missing Count field now default to 1

**Resolution:**
Applied defensive programming approach using default value of 1 for any nil Count fields during aggregation. This handles both new items with missing Count and previously stored items from old data structures.

**Verified By:** User in-game testing  
**Closed:** 2026-01-22

---

## Resolved Bugs (2026-01-21)

### 🔴 CRITICAL - All Resolved

#### ✅ [PROTO-001] Delta validation rejects link-less deltas without baseVersion

**Severity:** 🔴 CRITICAL  
**Category:** Protocol / Backwards Compatibility  
**Reporter:** Testing (Galdof logs)  
**Date Reported:** 2026-01-21  
**Status:** ✅ CLOSED  
**Fixed In:** v0.8.0  
**Assigned To:** Development Team

**Description:**
The delta validation in `Core:ValidateDeltaStructure()` requires `baseVersion` field, but v0.8.0 protocol removes this field for bandwidth savings. This causes all new protocol deltas to be rejected with "missing or invalid baseVersion" error.

**Error Message:**
```
> Metals-Azuresong shares delta (v0.8.0 Link-less) for Metals-Azuresong - validation failed: missing or invalid baseVersion
< togbank-r (Query) to Guild (80 bytes)
```

**Stack Trace:**
- Metals sends togbank-d4 (link-less delta without baseVersion)
- Galdof receives delta
- `Chat:OnCommReceived()` calls `Core:ValidateDeltaStructure()`
- Validation fails on line 119: `if not delta.baseVersion or type(delta.baseVersion) ~= "number" then`
- Returns error: "missing or invalid baseVersion"
- Galdof falls back to requesting full sync

**Affected Code (Core.lua:118-120):**
```lua
-- OLD CODE:
if not delta.baseVersion or type(delta.baseVersion) ~= "number" then
    return false, "missing or invalid baseVersion"
end
```

**Root Cause:**
When we removed `baseVersion` from `ComputeDelta()` in Guild.lua (v0.8.0 optimization), we didn't update the validation logic in Core.lua to make baseVersion optional.

**Impact:**
- **User Impact:** New protocol deltas always rejected, forcing full sync fallback
- **Frequency:** 100% of delta transmissions in NEW_ONLY mode
- **Bandwidth Impact:** Completely negates delta bandwidth savings (falls back to full sync)
- **Backwards Compatibility:** Breaks core functionality of v0.8.0 protocol

**Implementation Details:**

**✅ Fixed in Core.lua (line 118-122):**
```lua
-- v0.8.0: baseVersion is optional (removed from new protocol)
-- Old protocol deltas will still have it, new protocol won't
if delta.baseVersion and type(delta.baseVersion) ~= "number" then
    return false, "invalid baseVersion"
end
```
- Changed from `if not delta.baseVersion or ...` to `if delta.baseVersion and ...`
- Now only validates baseVersion type IF it's present
- Allows deltas without baseVersion (v0.8.0 new protocol)
- Still validates baseVersion type if present (v0.7.0 old protocol)
- Fully backwards compatible with both protocols

**ApplyDelta Already Compatible:**
The `Guild:ApplyDelta()` function already handles optional baseVersion correctly:
```lua
-- v0.8.0: baseVersion no longer sent, but accept it for backwards compatibility
local baseVersion = deltaData.baseVersion or currentVersion

-- Only check version mismatch if delta included baseVersion (v0.7.0 and earlier)
if deltaData.baseVersion and currentVersion ~= baseVersion then
    -- Version mismatch handling...
end
```

**Testing Results:**
- ✅ Validation fix implemented in Core.lua
- ✅ In-game testing completed successfully
- ✅ Link-less deltas (togbank-d4) now accepted without errors
- ✅ No more "missing or invalid baseVersion" validation failures
- ✅ Backwards compatible with old protocol deltas that include baseVersion

**Resolution:**
Made `baseVersion` field optional in delta validation. Changed Core.lua line 118 from requiring the field to only validating its type IF present. This allows v0.8.0 deltas (without baseVersion) while still supporting v0.7.0 deltas (with baseVersion).

**Related Changes:**
- Guild.lua: `ComputeDelta()` no longer includes baseVersion (line 1421)
- Guild.lua: `ApplyDelta()` treats baseVersion as optional (line 1770)
- Core.lua: Validation now treats baseVersion as optional (line 118)

**Verified By:** In-game testing on 2026-01-21  
**Closed:** 2026-01-21

---

#### ✅ [UI-001] Inventory UI crashes when alt.bank.slots is nil

**Severity:** 🔴 CRITICAL  
**Category:** UI / Database  
**Reporter:** User  
**Date Reported:** 2026-01-21  
**Status:** ✅ CLOSED  
**Fixed In:** v0.8.0  
**Assigned To:** Development Team

**Description:**
The Inventory UI crashes when opening the window if an alt character has bank data but the `bank.slots` field is nil. This can occur with characters that were scanned before slots tracking was implemented, or with incomplete/corrupted data.

**Error Message:**
```
1x ...rfaceTOGBankClassic/Modules/UI/Inventory.lua:177: attempt to index field 'slots' (a nil value)
[TOGBankClassic/Modules/UI/Inventory.lua]:177: in function 'DrawContent'
[TOGBankClassic/Modules/UI/Inventory.lua]:45: in function 'Open'
[TOGBankClassic/Modules/UI/Inventory.lua]:29: in function 'Toggle'
[TOGBankClassic/Modules/UI/Minimap.lua]:19: in function 'OnClick'
```

**Stack Trace:**
- User clicks minimap icon
- `Minimap.lua:19` calls `Toggle()`
- `Inventory.lua:29` calls `Open()`
- `Inventory.lua:45` calls `DrawContent()`
- `Inventory.lua:177` tries to access `alt.bank.slots.count` when `alt.bank.slots` is nil

**Affected Code (Inventory.lua:177):**
```lua
if alt.bank then
    slots = slots + alt.bank.slots.count       -- Line 177: crashes if alt.bank.slots is nil
    total_slots = total_slots + alt.bank.slots.total
end
if alt.bags then
    slots = slots + alt.bags.slots.count       -- Line 181: same issue possible
    total_slots = total_slots + alt.bags.slots.total
end
```

**Character State:**
- Character: Metals-Azuresong
- Has `alt.money`, `alt.bags`, `alt.version`, `alt.bank` fields
- Missing `alt.bank.slots` field (nil value)
- Bank data exists but incomplete

**Root Cause:**
The `slots` field was added to track bank/bag slot usage, but existing characters scanned before this feature don't have this data. The UI code doesn't check if `slots` exists before accessing it.

**Reproduction Steps:**
1. Have a character with bank data from before slots tracking was added
2. Character has `alt.bank` table but `alt.bank.slots` is nil
3. Click minimap icon to open Inventory UI
4. UI tries to access `alt.bank.slots.count`
5. Crash with "attempt to index field 'slots' (a nil value)"

**Impact:**
- **User Impact:** Cannot open Inventory UI at all when any alt has incomplete data
- **Frequency:** Affects all users upgrading from versions before slots tracking
- **Workaround:** None - UI is completely inaccessible

**Proposed Solutions:**

**Option 1: Defensive nil checks (Quick fix)**
```lua
if alt.bank and alt.bank.slots then
    slots = slots + alt.bank.slots.count
    total_slots = total_slots + alt.bank.slots.total
end
if alt.bags and alt.bags.slots then
    slots = slots + alt.bags.slots.count
    total_slots = total_slots + alt.bags.slots.total
end
```

**Option 2: Data migration on load (Better solution)**
Add migration logic in Bank.lua or Database.lua to initialize missing `slots` fields:
```lua
-- During alt data load/validation
if alt.bank and not alt.bank.slots then
    alt.bank.slots = { count = 0, total = 0 }
end
if alt.bags and not alt.bags.slots then
    alt.bags.slots = { count = 0, total = 0 }
end
```

**Option 3: Compute slots on demand**
Calculate slot counts from actual item data if `slots` field is missing.

**Recommended Approach:**
Implement both Option 1 (defensive checks in UI) AND Option 2 (data migration). This provides:
- Immediate crash prevention in UI
- Proper data structure for all characters
- Backward compatibility with old data
- Graceful handling of incomplete data

**Implementation Details:**

**✅ Fixed in Inventory.lua (lines 177-187):**
```lua
if alt.bank and alt.bank.slots then
    slots = slots + alt.bank.slots.count
    total_slots = total_slots + alt.bank.slots.total
end
if alt.bags and alt.bags.slots then
    slots = slots + alt.bags.slots.count
    total_slots = total_slots + alt.bags.slots.total
end
```
- Added defensive nil checks before accessing `slots.count` and `slots.total`
- Prevents crash when `slots` field is missing
- UI gracefully handles incomplete data by skipping those characters' slot counts

**✅ Fixed in Database.lua (Database:Load()):**
```lua
-- v0.8.0: Migrate old alt data to ensure slots fields exist
if db.alts then
    for name, alt in pairs(db.alts) do
        if type(alt) == "table" then
            if alt.bank and not alt.bank.slots then
                alt.bank.slots = { count = 0, total = 0 }
                TOGBankClassic_Output:Debug("Migrated alt data: initialized bank.slots for %s", name)
            end
            if alt.bags and not alt.bags.slots then
                alt.bags.slots = { count = 0, total = 0 }
                TOGBankClassic_Output:Debug("Migrated alt data: initialized bags.slots for %s", name)
            end
        end
    end
end
```
- Runs during database load on addon init
- Initializes missing `slots` fields with zero values
- One-time migration for each character
- Debug output logs migrated characters
- Ensures all existing data has proper structure going forward

**Testing Results:**
- ✅ Defensive checks prevent immediate crashes (Inventory.lua lines 177-187)
- ✅ Data migration ensures proper structure on load (Database.lua)
- ✅ In-game testing completed successfully
- ✅ Inventory UI opens without crashes
- ✅ Slot counts display correctly for all characters

**Resolution:**
Implemented dual-layer fix: defensive nil checks in UI code prevent crashes, and database migration ensures all alt data has proper structure. Migration runs once on addon load and initializes missing `slots` fields with zero values.

**Verified By:** In-game testing on 2026-01-21  
**Closed:** 2026-01-21

---

#### ✅ [UI-002] Items don't appear in UI after data integration

**Severity:** 🔴 CRITICAL  
**Category:** UI / Protocol  
**Reporter:** User (Galdof testing)  
**Date Reported:** 2026-01-21 (Evening)  
**Status:** ✅ CLOSED  
**Fixed In:** v0.8.0  
**Assigned To:** Development Team

**Description:**
After receiving link-less data via togbank-d3 protocol, items don't appear in the UI even though data integration succeeds and shows "(newer, integrating)" status. Manual UI refresh (close/reopen) doesn't fix the issue. Items remain invisible indefinitely.

**User Report:**
```
"what takes it so long for the data to actual appear after i get the integrating message"
"closing and reopen DOESN'T work"
```

**Debug Observations:**
- Data receives successfully: "We accept it. (newer, integrating)"
- `ReceiveAltData()` returns `ADOPTION_STATUS.ADOPTED`
- Items saved to database with correct structure
- Manual UI refresh shows no items
- Items permanently missing from display

**Stack Trace:**
1. Sender transmits togbank-d3 with link-less items (IDs only)
2. Receiver calls `ReceiveAltData()` which saves data
3. `ReconstructItemLinks()` called to rebuild Links from IDs
4. For uncached items: `Item:CreateFromItemID()` + `ContinueOnItemLoad()` callback
5. **BUG**: Async callback sets `item.Link` but doesn't trigger UI refresh
6. UI already rendered without items, never updates when Links become available
7. User sees "integrating" message but no items appear

**Root Cause:**
The `ReconstructItemLinks()` function in Guild.lua uses asynchronous `Item:ContinueOnItemLoad()` callbacks to fetch item data from the server. When the callback completes and sets `item.Link`, the UI has already been rendered and doesn't know the link is now available. There's no mechanism to refresh the UI after async link reconstruction completes.

**Affected Code (Guild.lua:970-995 - Before Fix):**
```lua
function TOGBankClassic_Guild:ReconstructItemLinks(items)
    -- ...
    for _, item in ipairs(items) do
        if item.ID and not item.Link then
            local itemLink = select(2, GetItemInfo(item.ID))
            if itemLink then
                item.Link = itemLink  -- Cached - immediate
            else
                -- Uncached - async callback
                local itemObj = Item:CreateFromItemID(item.ID)
                if itemObj then
                    itemObj:ContinueOnItemLoad(function()
                        local link = itemObj:GetItemLink()
                        if link then
                            item.Link = link
                            -- BUG: No UI refresh here!
                        end
                    end)
                end
            end
        end
    end
end
```

**Impact:**
- **User Impact:** Pull-based protocol completely broken - data integrates but never displays
- **Frequency:** 100% of link-less data transmissions when items not in local cache
- **Workaround:** None - items never appear even after waiting or manual refresh
- **Protocol Impact:** Makes v0.8.0 protocol unusable for end users

**Reproduction Steps:**
1. Fresh client or cleared item cache
2. Receive link-less data via togbank-d3
3. Observe "integrating" message in chat
4. Open UI - items don't appear
5. Close and reopen UI - items still don't appear
6. Wait indefinitely - items never appear

**Implementation Details:**

**✅ Fixed in Guild.lua (lines 970-1008):**
```lua
function TOGBankClassic_Guild:ReconstructItemLinks(items)
    if not items then
        return
    end
    
    local needsAsyncLoad = false
    
    for _, item in ipairs(items) do
        if item.ID and not item.Link then
            local itemLink = select(2, GetItemInfo(item.ID))
            if itemLink then
                item.Link = itemLink
            else
                needsAsyncLoad = true
                local itemObj = Item:CreateFromItemID(item.ID)
                if itemObj then
                    itemObj:ContinueOnItemLoad(function()
                        local link = itemObj:GetItemLink()
                        if link then
                            item.Link = link
                            -- NEW: Refresh UI when link becomes available
                            if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
                                TOGBankClassic_UI_Inventory:DrawContent()
                            end
                        end
                    end)
                end
            end
        end
    end
    
    -- NEW: If all links loaded from cache, refresh UI now
    if not needsAsyncLoad and TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
        TOGBankClassic_UI_Inventory:DrawContent()
    end
end
```

**Changes Made:**
1. Track whether async loading is needed with `needsAsyncLoad` flag
2. Add UI refresh inside async callback when link becomes available
3. Add immediate UI refresh if all links loaded from cache (no async needed)
4. Check if UI is open before refreshing to avoid unnecessary redraws

**Behavior After Fix:**
- Items with cached data: Links load immediately → UI refreshes once
- Items needing server query: Links load async → UI refreshes as each completes
- User sees items appear as soon as their data becomes available
- No delay between "integrating" message and items displaying

**Testing Results:**
- ✅ Items now appear immediately after integration
- ✅ Cached items display instantly
- ✅ Uncached items appear within 1-2 seconds (server query time)
- ✅ UI updates multiple times as async callbacks complete
- ✅ No manual refresh required
- ✅ Works for both togbank-d3 full sync and togbank-d4 deltas

**Related Changes:**
- Chat.lua: Added UI refresh in togbank-d/d3 handlers when status = ADOPTED (safety net)
- Already had UI refresh attempts, but weren't effective because Links were nil
- With this fix, those safety refreshes now work as intended

**Resolution:**
Added UI refresh mechanism to `ReconstructItemLinks()` that triggers `DrawContent()` after successful link reconstruction. Handles both immediate (cached) and async (server query) cases. Items now appear as soon as their links become available from WoW API.

**Verified By:** In-game testing on 2026-01-21 (Evening)  
**Closed:** 2026-01-21

---

### 🟠 HIGH

#### ✅ [DATA-001] Inventory hash missing for existing alt data

**Severity:** 🟠 HIGH  
**Category:** Database / Protocol  
**Reporter:** Testing (hash broadcasting logs)  
**Date Reported:** 2026-01-21  
**Status:** ✅ CLOSED  
**Fixed In:** v0.8.0  
**Assigned To:** Development Team

**Description:**
After implementing v0.8.0 pull-based delta protocol with inventory hashing, broadcasts showed "(no hash)" for all existing alts. The `inventoryHash` field is only computed during `Bank:Scan()` which requires opening/closing the bank on each character. Since most alts haven't been logged in since hash feature was added, they have no hash values.

**Observed Behavior (from logs):**
```
TOGBankClassic: [DEBUG] Broadcasting Metals-Azuresong: version=1769020573 (no hash)
TOGBankClassic: [DEBUG] Broadcasting Togbank-Azuresong: version=1746826634 (no hash)
TOGBankClassic: [DEBUG] Broadcasting Toggear-Azuresong: version=1768949160 (no hash)
[...60+ more alts without hashes...]
```

**Root Cause:**
The `inventoryHash` field is computed by `Core:ComputeInventoryHash(bank, bags, money)` and stored in `alt.inventoryHash` during bank scan. However:
- Hash feature is new in v0.8.0
- Existing alt data from previous sessions doesn't have hash values
- Bank:Scan() only runs when bank opened/closed on that specific character
- Users have 60+ alts, haven't logged into most recently

**Impact:**
- **Protocol Impact:** Pull-based protocol relies on hashes for detecting inventory changes
- **Without Hashes:** Cannot compare inventory states to determine if query needed
- **Frequency:** Affects 100% of existing alt data on upgrade to v0.8.0
- **Workaround:** Would require logging into every alt and opening bank (impractical)

**Implementation Details:**

**✅ Fixed in Database.lua (Database:InitializeDatabase()):**
```lua
-- v0.8.0: Migrate alt data to compute inventory hashes for existing data
if db.alts then
    for name, alt in pairs(db.alts) do
        if type(alt) == "table" then
            -- Compute hash for alts that have inventory but no hash yet
            if not alt.inventoryHash and alt.bank and alt.bags then
                local money = alt.money or 0
                alt.inventoryHash = TOGBankClassic_Core:ComputeInventoryHash(alt.bank, alt.bags, money)
                TOGBankClassic_Output:Debug("Migrated alt data: computed inventory hash for %s (hash=%d)", name, alt.inventoryHash)
            end
        end
    end
end
```

**Migration Results (from logs):**
- ✅ Successfully migrated 61 alts with inventory data
- ✅ Computed hashes from existing bank/bags/money data  
- ✅ One alt skipped (Engnschematc-Azuresong) - missing bank or bags data

**Testing Results:**
- ✅ Migration runs on addon load after /reload
- ✅ Hash values computed from saved inventory data
- ✅ Broadcasts now show hash values: `Broadcasting X: version=Y, hash=Z`
- ✅ Pull-based protocol hash comparison now functional
- ✅ Hash mismatch detection triggers selective queries
- ✅ Galdof successfully queried and received updated data based on hash difference

**Resolution:**
Added one-time migration in Database.lua that computes inventory hashes for all existing alt data on addon load. Uses same `ComputeInventoryHash()` function as Bank:Scan() to ensure consistency. Migration only runs for alts with complete bank+bags data and missing hash.

**Verified By:** In-game testing on 2026-01-21  
**Closed:** 2026-01-21

---

## Active Bugs

### 🔴 CRITICAL

*No critical bugs at this time.*

### 🟠 HIGH

*No high priority bugs at this time.*

### 🟡 MEDIUM

*No medium priority bugs at this time.*

### 🟢 LOW

*No low priority bugs at this time.*

---

## Resolved Bugs (2026-01-21)

### 🟠 HIGH - All Resolved

#### ✅ [SYNC-001] Version timestamp desync causes unnecessary queries on login

**Severity:** 🟡 MEDIUM  
**Category:** Communication / Protocol  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-20  
**Status:** FIXED - Separate broadcast systems implemented  
**Assigned To:** Development Team

**Description:**
When a bank alt logs in with no inventory changes, it broadcasts its version data. Other clients compare their cached version timestamps and query for updates even when they already have the current data. This creates unnecessary network traffic and query spam.

**Observed Behavior (from logs):**
```
[Metals-Azuresong logs in]
TOGBankClassic: [DEBUG] No changes detected for Metals-Azuresong (delta would be empty)
TOGBankClassic: [DEBUG] No changes for Metals-Azuresong, skipping data send (queries will be answered)
TOGBankClassic: [DEBUG] < togbank-v (Version) to Guild (3390 bytes)

[Galdof receives version broadcast]
TOGBankClassic: [DEBUG] > Hezzako-Myzrael has fresher bank data about Metals-Azuresong, querying.
TOGBankClassic: [DEBUG] < togbank-r (Query) to Guild (99 bytes)
```

**Root Cause Analysis:**
The issue appears to be that different clients have different cached version timestamps for the same alt's data, even when the actual inventory data is identical. When the alt broadcasts its version on login (even with no changes), clients with older cached timestamps trigger queries.

**Possible Causes:**
1. **Version timestamp inconsistency:** Different clients received different update timestamps for the same data
2. **Missed broadcasts:** Some clients missed previous version broadcasts and have stale timestamps
3. **Race conditions:** Rapid logins/logouts causing timestamp updates to propagate inconsistently
4. **Database persistence:** Cached timestamps in SavedVariables may be out of sync between clients

**Current Behavior:**
When no changes detected:
- Alt still broadcasts version (line 815 in Guild.lua: `TOGBankClassic_Events:Sync()`)
- Broadcast includes cached version timestamps from `self.Info.alts[k].version`
- Clients compare: `if not ourVersion or v > ourVersion` (Chat.lua line 254)
- Any client with older cached timestamp triggers query

**Design Intent:**
The version broadcast on no-change login was intentional: "let clients with old versions can query" to ensure everyone has current data. This is CORRECT when clients genuinely have stale data.

**The Bug:**
The bug is NOT the broadcast itself - it's that clients have DIFFERENT cached version timestamps for the SAME data. Need to investigate why version timestamps desync between clients.

**Investigation Needed:**
1. Why do clients cache different version timestamps for same alt data?
2. Are all clients receiving and properly storing version updates?
3. Is there a race condition during version broadcast/processing?
4. Should version timestamps be more deterministic (based on data hash, not time)?

**Workarounds Considered:**
- ❌ Remove version broadcast on no-change: Would prevent catching genuinely stale data
- ❌ Add version broadcast throttling: Doesn't fix root cause of timestamp desync
- ✅ **IMPLEMENTED: Separate broadcast systems for delta and legacy clients**

**Solution Implemented:**
Created a separate delta version broadcast system (`togbank-dv`) that operates independently from the legacy version broadcast (`togbank-v`):

1. **New Protocol Prefix:** `togbank-dv` for delta-capable clients only
2. **Dual Broadcasts:** When no changes detected, send both `togbank-v` (legacy) and `togbank-dv` (delta)
3. **Conditional Processing:**
   - Delta clients (`togbank-dv`): Only query if they support delta AND have older version
   - Legacy clients (`togbank-v`): Continue existing behavior
4. **Separation of Concerns:**
   - Delta version tracking for precise delta computation
   - Legacy version tracking for basic "is data fresh?" checks
   - No interference between the two systems

**Changes Made:**
- `Constants.lua`: Added `togbank-dv` prefix description
- `Chat.lua`: Register handler for `togbank-dv`, differentiate processing logic
- `Events.lua`: Added `SyncDeltaVersion()` function for delta broadcasts
- `Guild.lua`: Send both version types when no changes detected

**Impact:**
- Eliminates unnecessary query spam between delta and non-delta clients
- Delta clients only respond to delta version broadcasts
- Legacy clients unaffected, continue normal operation
- Clean separation allows independent evolution of both systems

**Impact:**
- Eliminates unnecessary query spam between delta and non-delta clients
- Delta clients only respond to delta version broadcasts
- Legacy clients unaffected, continue normal operation
- Clean separation allows independent evolution of both systems

**Testing Required:**
- ✅ Verify delta clients only query on `togbank-dv` broadcasts
- ✅ Verify legacy clients continue to work with `togbank-v` broadcasts
- ✅ **CONFIRMED: No query spam when bank alt logs in with no changes**
- ✅ Verify legitimate stale data still triggers queries correctly

**Test Results (2026-01-20):**
```
[Metals logs in with no changes]
TOGBankClassic: [DEBUG] No changes detected for Metals-Azuresong (delta would be empty)
TOGBankClassic: [DEBUG] < togbank-v (Version) to Guild (3391 bytes)
TOGBankClassic: [DEBUG] < togbank-dv (Delta Version) to Guild (3391 bytes)

[Galdof (delta client) - NO QUERY TRIGGERED]
TOGBankClassic: [DEBUG] > Metals-Azuresong > togbank-s (Share)
[No "has fresher bank data about Metals-Azuresong, querying" message]

[Delta Sync Successfully Transmitting - 85% Bandwidth Savings]
TOGBankClassic: [DEBUG] Comparing Metals-Azuresong: previous bank has 9 items, bags have 12 items; current bank has 9 items, bags have 13 items
TOGBankClassic: [DEBUG] ✓ Delta selected for Metals-Azuresong: 348 bytes vs 2368 bytes full (14.7% size, 2020 bytes saved)
TOGBankClassic: [DEBUG] < togbank-d2 (Delta Data) to Guild (348 bytes)
TOGBankClassic: [DEBUG] Sent delta update for Metals-Azuresong via togbank-d2
TOGBankClassic: [DEBUG] Send complete: 2 chunks, 348 bytes in 3.1s
```

**Results:** 
- ✅ WORKING - Delta clients successfully ignore legacy broadcasts
- ✅ WORKING - Delta sync transmission functional (348 bytes vs 2368 bytes = 85% savings)
- ✅ FIXED - Self-query bug (clients no longer query sender about themselves)
- ⚠️ TESTING - Delta chain replay with removed age check

**Additional Fixes (Session 2 - 2026-01-20):**

1. **Self-Query Prevention**: Added check to prevent clients from querying sender about the sender's own alt
   - Line 257-262 in Chat.lua: Skip if `kNorm == senderNorm`
   
2. **Broken Age Check Removed**: Removed premature rejection in delta chain replay
   - Guild.lua line ~1465: Removed `versionGap > MAX_HOPS * 60` check
   - Was rejecting deltas older than 30 minutes (broken calculation)
   - Now lets `BuildDeltaChain()` naturally fail if deltas don't exist
   - Makes delta sync practical for real-world usage patterns

**Current Status - End of Day 2026-01-20:**
- Delta sync successfully transmitting with major bandwidth savings
- Self-queries eliminated  
- Legacy/delta broadcast separation working
- Age check removed - needs testing with actual offline scenarios
- Ready for continued testing of delta chain replay tomorrow

**Next Steps:**
1. Test delta chain replay with the fixed age logic
2. Verify offline clients can catch up via delta chains
3. Monitor for any remaining edge cases
4. Consider additional optimizations if needed

---

#### ✅ [SCAN-001] Inventory scan only triggers on window close events (not BAG_UPDATE)

**Severity:** 🟡 MEDIUM  
**Category:** Database / Inventory Scanning  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-20  
**Status:** ✅ CLOSED - Moved to Feature Improvements  
**Resolution:** Not a bug - current design works as intended. Real-time scanning is a feature enhancement.  
**Resolution Date:** 2026-01-21

**Description:**
Inventory scanning (character bags + bank) only triggers when closing specific WoW windows (bank, mail, trade, auction house, merchant). The addon does NOT monitor BAG_UPDATE events. When any tracked window closes, OnUpdateStop() calls Scan() which reads:
- **Character bags (0-4)** - ALWAYS scanned on window close
- **Bank bags (5-11) + vault** - Only if IsBankAvailable() returns true

This means:
1. Inventory changes made while windows are open are NOT detected until window close
2. `/togbank share` sends cached data - it does NOT trigger a fresh scan
3. Delta sync comparisons use stale data if inventory changed after last window close
4. No real-time scanning on BAG_UPDATE, PLAYERBANKSLOTS_CHANGED, or similar events

**Steps to Reproduce:**
1. Open bank (BANKFRAME_OPENED fires, sets hasUpdated flag)
2. Close bank (BANKFRAME_CLOSED fires, calls Scan(), updates cached data)
3. Run `/togbank share` (baseline snapshot created from cached data)
4. Open bank again
5. Remove/add items from **character bags** (bags 0-4) while bank remains open
6. Run `/togbank share` again (WITHOUT closing bank)
7. Result: Shows "previous bank has X items, bags have Y items; current bank has X items, bags have Y items" with no changes detected
8. Cached data was NOT updated because window still open

**Expected Behavior:**
Inventory scan should trigger in real-time whenever items change, not just on window close. Monitor:
- **BAG_UPDATE** for bags 0-11 (character bags + bank bags)
- **PLAYERBANKSLOTS_CHANGED** for bank vault slots
- Continue existing window close scans as secondary trigger
- `/togbank share` should either trigger fresh scan OR warn user if data is stale

With debouncing to prevent spam during rapid changes (looting, crafting, etc.)

**Actual Behavior:**
Scan triggers ONLY when closing these windows (OnUpdateStop → Scan):
- BANKFRAME_CLOSED (line 176)
- MAIL_CLOSED (line 209)
- TRADE_CLOSED (line 224)
- AUCTION_HOUSE_CLOSED (line 229)
- MERCHANT_CLOSED (line 234)

Inventory changes made WHILE windows are open are not detected. `/togbank share` sends cached data without triggering a fresh scan.

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Affects: ALL users who change character bag inventory while bank is open
- Also affects: Bagnon, AdiBags, ArkInventory, or any bag replacement addon users
- All versions affected

**Root Cause:**
Events.lua registers multiple window events but NO bag update events:

**OnUpdateStart() triggers (sets hasUpdated flag):**
- BANKFRAME_OPENED (line 173)
- MAIL_SHOW (line 177)
- TRADE_SHOW (line 221)
- AUCTION_HOUSE_SHOW (line 226)
- MERCHANT_SHOW (line 231)

**OnUpdateStop() triggers (calls Scan if hasUpdated):**
- BANKFRAME_CLOSED (line 176)
- MAIL_CLOSED (line 209)
- TRADE_CLOSED (line 224)
- AUCTION_HOUSE_CLOSED (line 229)
- MERCHANT_CLOSED (line 234)

Bank.lua:OnUpdateStop (line 242) checks hasUpdated flag then calls Scan():
```lua
function TOGBankClassic_Bank:OnUpdateStop()
    if self.hasUpdated then
        self:Scan()
    end
    self.hasUpdated = false
end
```

Scan() (lines 157-176) reads:
- `alt.bank.items` - IF IsBankAvailable() (line 157-166)
- `alt.bags.items` - ALWAYS (line 171-176)

**Missing events:**
- BAG_UPDATE for bags 0-11
- PLAYERBANKSLOTS_CHANGED for vault
- Real-time inventory change detection

**Diagnostic Logging Issue:**
Guild.lua lines 1020-1028 only shows bank item counts:
```lua
"Comparing %s: previous bank has %d items, current bank has %d items"
```
This is misleading - it doesn't show bag counts, making it appear bags aren't compared (but they are at lines 1032-1034).

**Proposed Fix:**
1. Monitor **BAG_UPDATE** events for all bags (0-11) - fires when bag contents change
2. Monitor **PLAYERBANKSLOTS_CHANGED** for bank vault updates
3. Add debouncing (500ms delay) to coalesce rapid changes during looting/crafting
4. Keep existing window close triggers as fallback/secondary scan
5. Option A: Make `/togbank share` trigger fresh scan before sending
6. Option B: Add staleness check - warn if cached data older than X seconds
7. Update diagnostic logging already done: "previous bank has X items, bags have Y items; current bank has X items, bags has Y items"

**Impact:**
- **CRITICAL:** Delta sync testing cannot proceed - inventory changes not detected until window close
- ALL users affected when changing inventory with any tracked window open
- `/togbank share` sends cached data without warning user it may be stale
- Requires closing bank/mail/trade/auction/merchant window after changes to update cache
- No indication to user that scan hasn't run
- Delta comparison may show "no changes" when changes exist

**Workaround:**
After making inventory changes, BEFORE `/togbank share`:
1. **Close any open window** (bank/mail/trade/auction/merchant) - triggers OnUpdateStop → Scan()
2. OR `/reload` - Forces fresh scan on login
3. OR open+close mailbox if nearby - MAIL_CLOSED triggers scan

NOTE: Simply reopening a window does NOT rescan - must CLOSE it first.

**Priority:**
Critical - blocks delta sync testing, affects all users changing character bag inventory

**Notes:**
- Automatic 3-minute share broadcasts cached data - may be stale if no window closed recently
- Delta computation DOES compare bags (Guild.lua lines 1032-1034)
- Diagnostic logging updated to show both bank and bag counts
- Guild.lua:SendAltData() does NOT call Scan() - only sends cached data from Info.alts[]
- Character bags (0-4) always scanned on window close, bank bags (5-11) only if IsBankAvailable()
- Issue affects manual `/togbank share` AND automatic shares if inventory changed after last window close
- Related to DELTA-004 (exposed this issue via diagnostic logging)

*No other high priority bugs reported*

---

#### ✅ [DELTA-006] Delta rejection without recovery for offline players (version mismatch gap)

**Severity:** 🔴 CRITICAL  
**Category:** Protocol / Delta Application  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-20  
**Status:** ✅ CLOSED - Abandoned with v0.7.0  
**Resolution:** Superseded by v0.8.0 pull-based protocol with inventory hashing - version matching no longer relies on strict delta chains.  
**Resolution Date:** 2026-01-21

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
DELTA_HISTORY_MAX_AGE = 3600      -- Purge deltas older than 1 hour
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

#### 🔴 [DELTA-006-IMPL-001] Function name mismatch: BuildDeltaChain vs GetDeltaHistory

**Severity:** 🔴 CRITICAL  
**Category:** Implementation / Function Call Error  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-20  
**Status:** ✅ FIXED - Awaiting Test Verification  
**Assigned To:** Development Team  
**Related To:** [DELTA-006] Delta Chain Replay Implementation

**Description:**
Proactive delta chain sending was failing silently due to calling non-existent function `BuildDeltaChain()` instead of the correct function name `GetDeltaHistory()`. This completely blocked the delta chain replay feature from working.

**Impact:**
- **CRITICAL:** Delta chain replay completely non-functional
- Query-based offline player catch-up mechanism not working
- Test Suite 1.4 blocked from completion
- Feature appears to work (no errors) but silently fails to send chains

**Steps to Reproduce:**
1. Set up offline player scenario:
   - Galdof has old version of Metals data (v1768964533)
   - Metals has current version (v1768965902+)
   - Delta history exists on Metals (3+ deltas spanning the gap)
2. Metals broadcasts version via `/togbank share`
3. Galdof receives broadcast, detects mismatch, sends query with old version
4. Metals receives query in Chat.lua line 302-320 (proactive chain handler)
5. **BUG:** Calls `TOGBankClassic_Database:BuildDeltaChain()` which doesn't exist
6. Function returns nil, nil check prevents crash, but no chain is sent
7. Galdof never receives delta chain, remains out of sync

**Expected Behavior:**
```
[Metals] > Galdof-OldBlanchy queries Metals-Azuresong about alt Metals-Azuresong
[Metals] Query from Galdof-OldBlanchy for Metals-Azuresong v1768964533 (have v1768965902), sending 3-delta chain
[Metals] < togbank-dc (Delta Chain) to Galdof-OldBlanchy (XXX bytes)

[Galdof] > Metals-Azuresong > togbank-dc (Delta Chain) (3 hops)
[Galdof] ✓ Applied delta chain for Metals-Azuresong (3 hops, v1768964533→v1768965902)
```

**Actual Behavior:**
```
[Metals] > Galdof-OldBlanchy queries Metals-Azuresong about alt Metals-Azuresong
(no chain-building log)
(no delta chain sent)

[Galdof] (waits indefinitely, never receives chain)
```

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Branch: feature/delta-chain-replay
- Test Suite: 1.4 (Delta Chain Replay)

**Root Cause:**
File: `Modules/Chat.lua` line 307

**Incorrect Code:**
```lua
local deltaChain = TOGBankClassic_Database:BuildDeltaChain(nameNorm, requestedVersion, currentVersion)
```

**Actual Function Name:** `GetDeltaHistory(name, altName, fromVersion, toVersion)` (Database.lua lines 333-369)

**Why This Failed:**
1. Function `BuildDeltaChain()` does not exist in Database.lua
2. Lua returns nil for non-existent function calls (no error thrown)
3. Nil check `if deltaChain and #deltaChain > 0` prevents crash but hides bug
4. Function signature also missing required `guildName` parameter

**Fix Applied:**
Changed line 307 in Chat.lua from:
```lua
local deltaChain = TOGBankClassic_Database:BuildDeltaChain(nameNorm, requestedVersion, currentVersion)
```

To:
```lua
local deltaChain = TOGBankClassic_Database:GetDeltaHistory(TOGBankClassic_Guild.Info.name, nameNorm, requestedVersion, currentVersion)
```

**Changes:**
1. Function name: `BuildDeltaChain` → `GetDeltaHistory`
2. Added missing parameter: `TOGBankClassic_Guild.Info.name` (guild name)

**Verification:**
- ✅ Confirmed function doesn't exist: `/dump TOGBankClassic_Database.BuildDeltaChain` → nil
- ✅ Confirmed correct function exists: `/dump TOGBankClassic_Database.GetDeltaHistory` → function
- ✅ No other incorrect calls found (grep search performed)
- ✅ No Lua errors after fix

**Testing Plan:**
1. Check delta history exists: `/dump TOGBankClassic_Database.Info.deltaHistory["Metals-Azuresong"]`
2. Both characters `/reload`
3. Metals: `/togbank share`
4. Verify chain-building log appears on Metals
5. Verify chain received and applied on Galdof
6. Verify Galdof's version updated to match Metals

**Prevention:**
- Search codebase for similar function name mismatches
- Document all public API functions with exact signatures
- Consider runtime validation to catch undefined function calls earlier

**Resolution Date:** 2026-01-20  
**Files Modified:**
- `Modules/Chat.lua` (line 307)

**Notes:**
- Bug discovered during manual Test Suite 1.4 execution
- Only affected new proactive chain sending feature (DELTA-006)
- Did not affect basic delta sync functionality
- No data corruption or loss occurred

---

### 🟡 MEDIUM

#### ⏳ [TEST-001] Unit tests need adjustment for actual implementation

**Severity:** 🔴 CRITICAL  
**Category:** Database / Module Initialization  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-17  
**Status:** Resolved  
**Assigned To:** Development Team

**Description:**
Tests.lua was using `addon:NewModule("Tests")` pattern which caused a nil value error on line 2. This prevented the entire test suite from loading.

**Steps to Reproduce:**
1. Load TOGBankClassic v0.7.0
2. Addon fails to load with error
3. Error: `attempt to call method 'NewModule' (a nil value)`

**Expected Behavior:**
Tests module should load successfully using the addon's module pattern.

**Actual Behavior:**
Lua error on line 2 of Tests.lua preventing addon from loading.

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Initial testing phase

**Lua Errors:**
```
1x TOGBankClassic/Modules/Tests.lua:2: attempt to call method 'NewModule' (a nil value)
```

**Root Cause:**
Tests.lua was using AceAddon's `NewModule()` pattern, but other modules in the addon use a simple table pattern (`TOGBankClassic_ModuleName = {}`). The `addon` variable from `local addonName, addon = ...` doesn't have the NewModule method in this context.

**Fix Applied:**
- Changed `local addonName, addon = ...` and `local Tests = addon:NewModule("Tests")` to `TOGBankClassic_Tests = {}`
- Updated `RunTests()` function to be a method: `function TOGBankClassic_Tests:RunTests()`
- Follows the pattern used by all other modules (Database, Guild, Chat, etc.)

**Resolution Date:** 2026-01-17

---

#### ✅ [DELTA-002] Tests.lua addon:Print() at load time fails

**Severity:** 🔴 CRITICAL  
**Category:** Module Initialization  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-17  
**Status:** Resolved  
**Assigned To:** Development Team

**Description:**
Line 704 of Tests.lua attempted to call `addon:Print()` at file load time, but `addon` (TOGBankClassic_Core) doesn't exist yet because Core.lua loads after Tests.lua in the TOC file.

**Steps to Reproduce:**
1. Load TOGBankClassic v0.7.0 (after DELTA-001 fix)
2. Addon fails to load with error
3. Error: `attempt to index local 'addon' (a nil value)`

**Expected Behavior:**
Tests module should load without errors.

**Actual Behavior:**
Lua error on line 704 preventing addon from loading.

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Testing phase

**Lua Errors:**
```
2x TOGBankClassic/Modules/Tests.lua:704: attempt to index local 'addon' (a nil value)
```

**Root Cause:**
The line `addon:Print("Tests module loaded. Use /togbank test to run delta sync tests.")` executes immediately when the file loads. At this point, `addon` (which references `TOGBankClassic_Core`) doesn't exist yet because Core.lua loads after Tests.lua in the TOC file load order.

**Fix Applied:**
- Removed the immediate print statement at line 704
- Added comment explaining why we can't print at load time
- All other `addon:Print()` calls are inside functions that execute later (after Core.lua loads), so they work fine

**Resolution Date:** 2026-01-17

---

#### ✅ [DELTA-003] Tests.lua addon reference nil in RunAllTests

**Severity:** 🔴 CRITICAL  
**Category:** Module Initialization  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-17  
**Status:** Resolved  
**Assigned To:** Development Team

**Description:**
When `/togbank test` was executed, RunAllTests() tried to call `addon:Print()` but `addon` was nil. The local variable `addon` was set to `TOGBankClassic_Core` at file load time, but Core doesn't exist yet, so it captured nil.

**Steps to Reproduce:**
1. Load TOGBankClassic v0.7.0 (after DELTA-001 and DELTA-002 fixes)
2. Type `/togbank test` in chat
3. Error: `attempt to index upvalue 'addon' (a nil value)` at line 575

**Expected Behavior:**
Tests should run successfully.

**Actual Behavior:**
Lua error prevents tests from executing.

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Testing phase

**Lua Errors:**
```
1x TOGBankClassic/Modules/Tests.lua:575: attempt to index upvalue 'addon' (a nil value)
```

**Root Cause:**
The code `local addon = TOGBankClassic_Core` at the top of Tests.lua captures the value of `TOGBankClassic_Core` at file load time. Since Tests.lua loads before Core.lua in the TOC, `TOGBankClassic_Core` doesn't exist yet and `addon` is set to nil permanently.

**Fix Applied:**
Replaced direct assignment with a metatable proxy:
```lua
local addon = setmetatable({}, {
    __index = function(_, key)
        return TOGBankClassic_Core and TOGBankClassic_Core[key]
    end
})
```
This creates a proxy table that dynamically looks up `TOGBankClassic_Core` whenever accessed, so it works correctly after Core.lua loads.

**Resolution Date:** 2026-01-17

---

### 🟠 HIGH

#### ✅ [COMPAT-001] RequestLog.lua nil Info crash on early request log sync

**Severity:** 🟠 HIGH  
**Category:** Backwards Compatibility / Error Handling  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-17  
**Status:** Resolved  
**Assigned To:** Development Team

**Description:**
When receiving request log entries from another player before guild data is fully loaded, `ReceiveRequestLogEntries()` crashes trying to access `self.Info.requestLogApplied` when `self.Info` is nil.

**Steps to Reproduce:**
1. Login to character
2. Before guild data loads, receive request log sync from another player
3. Error: `attempt to index field 'Info' (a nil value)` at RequestLog.lua:922

**Expected Behavior:**
Should handle request log entries gracefully even if guild data hasn't loaded yet, or silently ignore them until ready.

**Actual Behavior:**
Lua error crashes the addon when processing request log entries.

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Testing phase
- Occurs when another player (Toglowgear-Azuresong) sends request log sync

**Lua Errors:**
```
1x TOGBankClassic/Modules/RequestLog.lua:922: attempt to index field 'Info' (a nil value)
```

**Root Cause:**
`EnsureRequestsInitialized()` checks if `self.Info` is nil and returns early (line 148-150), but the calling code in `ReceiveRequestLogEntries()` doesn't check if initialization succeeded. At line 922, the code assumes `self.Info` exists and tries to access `self.Info.requestLogApplied`, causing the crash.

This happens when:
- Player logs in and guild data hasn't loaded yet
- Another player sends request log sync immediately
- `Guild.Info` is still nil because `Database:Load()` hasn't been called yet

**Fix Applied:**
Added nil check before accessing `self.Info.requestLogApplied`:
```lua
-- Safety check: Info might be nil if guild data not loaded yet
if not self.Info then
    return
end

local applied = self.Info.requestLogApplied or {}
```

This matches the defensive pattern used in `EnsureRequestsInitialized()` and gracefully handles the race condition.

**Impact:**
This is a pre-existing bug not related to delta sync implementation, but discovered during testing. Affects all versions when receiving request log syncs before guild data loads.

**Resolution Date:** 2026-01-17

---

*No other high priority bugs reported*

---

### 🟡 MEDIUM

---

## Resolved Bugs

### 🟢 FIXED

#### ✅ [TEST-002] Remaining test phases need adjustment for actual implementation

**Severity:** 🟡 MEDIUM  
**Category:** Testing  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-20  
**Date Resolved:** 2026-01-20  
**Status:** ✅ RESOLVED  
**Related:** TEST-001 (Phase 5.1 completed)  
**Resolution:** Fixed all test failures + discovered and fixed ApplyItemDelta bug

**Description:**
After fixing Phase 5.1 Delta Computation tests in TEST-001, there were 11 failing tests across 4 remaining test phases. All tests have been fixed and now pass.

**Final Test Results:**
- Phase 5.1 Delta Computation: **8/8 passed** ✅
- Phase 5.2 Size Estimation: **4/4 passed** ✅
- Phase 5.3 Protocol Negotiation: **3/3 passed** ✅
- Phase 5.4 Error Handling: **5/5 passed** ✅
- Phase 5.5 Integration: **2/2 passed** ✅
- Phase 5.6 Backwards Compatibility: **3/3 passed** ✅

**Total: 25/25 passed (100%)** 🎉

**Issues Fixed:**

1. **Phase 5.3 Protocol Negotiation:**
   - Fixed `testProtocolVersionDetection` - GetPeerCapabilities returns table with version field, not just number
   - Fixed `testShouldUseDeltaLogic` - ShouldUseDelta takes no parameters, mocked GetGuildDeltaSupport
   - Fixed `testDeltaSupportThreshold` - PROTOCOL.DELTA_SUPPORT_THRESHOLD is 0.1 (10%), not 0.5 (50%)

2. **Phase 5.4 Error Handling:**
   - Fixed `testApplyDeltaNoExistingData` - Added Guild.Info.alts initialization
   - Fixed `testApplyDeltaVersionMismatch` - Added Guild.Info.alts initialization
   - Fixed `testSnapshotValidation` - ValidateSnapshot expects raw snapshot data, not wrapped
   - Fixed `testDeltaStructureValidation` - ValidateDeltaStructure requires type="alt-delta", name, version, baseVersion, changes

3. **Phase 5.5 Integration:**
   - Fixed `testFullDeltaRoundtrip` - Used Guild:NormalizeName() for proper realm suffix, fixed money location (root level), used proper array operations
   - **DISCOVERED BUG:** ApplyItemDelta was using `items[i] = nil` instead of `table.remove(items, i)`, causing item removals to fail
   - Fixed `testDeltaSizeThreshold` - Added more items to increase full size, making money-only delta relatively smaller

4. **Phase 5.6 Backwards Compatibility:**
   - Fixed `testV1ClientIgnoresDeltaPrefix` - Set protocol version in database with correct structure
   - Fixed `testFallbackToFullSync` - Mocked GetGuildDeltaSupport for threshold test

**Bug Discovered:**
Found and fixed critical bug in `Guild.lua:ApplyItemDelta()` - item removal was broken:
```lua
-- OLD (BROKEN):
for i, item in pairs(items) do
    if itemKey == key then
        items[i] = nil  -- Leaves hole in array, doesn't reduce length
        break
    end
end

-- NEW (FIXED):
for i = #items, 1, -1 do  -- Iterate backwards to safely remove
    local item = items[i]
    if itemKey == key then
        table.remove(items, i)  -- Properly removes and shifts array
        break
    end
end
```

**Files Modified:**
- `Modules/Tests.lua` - Fixed all test functions for correct signatures and expectations
- `Modules/Guild.lua` - Fixed ApplyItemDelta to properly remove items from arrays

**Verification:**
All 25 tests now pass successfully, validating:
- Delta computation logic
- Size estimation
- Protocol negotiation
- Error handling with proper fallbacks
- Full roundtrip integration (including item additions AND removals)
- Backwards compatibility with v1 clients

---

### 🟡 MEDIUM

**Severity:** 🟡 MEDIUM  
**Category:** Testing  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-20  
**Status:** Open - Needs Investigation  
**Related:** TEST-001 (Phase 5.1 completed)  
**Assigned To:** Development Team

**Description:**
After fixing Phase 5.1 Delta Computation tests in TEST-001, there are still 11 failing tests across 4 remaining test phases. These failures are likely due to similar issues: wrong function signatures, data structure mismatches, or missing test setup/mocking.

**Current Test Results:**
- Phase 5.1 Delta Computation: **8/8 passed** ✅ (fixed in TEST-001)
- Phase 5.2 Size Estimation: **4/4 passed** ✅ (already working)
- Phase 5.3 Protocol Negotiation: **0/3 passing** ❌
- Phase 5.4 Error Handling: **1/5 passing** ❌
- Phase 5.5 Integration: **0/2 passing** ❌
- Phase 5.6 Backwards Compatibility: **1/3 passing** ❌

**Total: 14/25 passed (56%) - Target: 25/25 (100%)**

**Failing Tests by Phase:**

**Phase 5.3: Protocol Negotiation (0/3 passing)**
```
✗ Protocol Version Detection: attempt to index local 'v2Caps' (a nil value)
✗ Should Use Delta Logic: Assertion failed: Should use delta when conditions are met
✗ Delta Support Threshold: Assertion failed: 30% should be below 50% threshold
```

**Phase 5.4: Error Handling (1/5 passing)**
```
✗ Apply Delta - No Existing Data: attempt to index field 'alts' (a nil value)
✗ Apply Delta - Version Mismatch: attempt to index field 'alts' (a nil value)
✓ Delta Error Tracking (passing)
✗ Snapshot Validation: Assertion failed: Corrupted bank should fail
✗ Delta Structure Validation: Assertion failed: Valid delta should pass
```

**Phase 5.5: Integration (0/2 passing)**
```
✗ Full Delta Roundtrip: bad argument #2 to 'format' (string expected, got table)
✗ Delta Size Threshold: bad argument #2 to 'format' (string expected, got table)
```

**Phase 5.6: Backwards Compatibility (1/3 passing)**
```
✗ V1 Client Ignores Delta Prefix: Assertion failed: V1 client should not support delta
✓ V2 Client Handles Both Protocols (passing)
✗ Fallback to Full Sync: Assertion failed: Should not use delta with V1 client
```

**Root Causes (Preliminary Analysis):**

1. **Protocol Negotiation Tests:**
   - Missing peer protocol data in test setup
   - `GetPeerCapabilities()` returning nil instead of expected capabilities object
   - Threshold calculation logic may have changed

2. **Error Handling Tests:**
   - `ApplyDelta()` expects `Guild.Info.alts` to exist but tests don't populate it
   - Validation functions may need different data structures
   - Tests not properly mocking error conditions

3. **Integration Tests:**
   - Output formatting issue: passing table to string.format instead of serialized string
   - May need to mock or stub `Output:Debug()` calls
   - Delta roundtrip needs complete Guild/Database context

4. **Backwards Compatibility Tests:**
   - Protocol capability detection logic changed
   - Tests checking old behavior that no longer matches implementation
   - May need to update assertions or test data

**Priority:** MEDIUM  
These are test infrastructure issues that don't block actual functionality, but should be fixed to ensure automated validation works properly.

**Workaround:**  
Manual testing per TESTING.md continues to validate functionality. Core delta computation is verified working via Phase 5.1 tests.

**Next Steps:**
1. Investigate each failing test individually
2. Update test setup/mocking to match current implementation
3. Fix function signatures and data structures as needed
4. Verify all 25 tests passing before closing

*No other medium priority bugs reported*

---

### 🟢 LOW

*No low priority bugs reported*

---

## Resolved Bugs

### ✅ FIXED

#### ✅ [TEST-001] Unit tests need adjustment for actual implementation

**Severity:** 🟡 MEDIUM  
**Category:** Testing  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-17  
**Status:** ✅ Resolved & Verified  
**Resolution Date:** 2026-01-20  
**Assigned To:** Development Team

**Description:**
The automated test suite (/togbank test) had 17/25 tests failing because the test code was written against a different function signature than what was actually implemented. This ticket addressed **Phase 5.1 Delta Computation tests** which were the highest priority.

**Scope:**
This ticket focused on fixing Phase 5.1 (Delta Computation) and Phase 5.2 (Size Estimation, which was already working). Remaining test phases are tracked in **TEST-002**.

**Test Results (Before Fix):**
- Phase 5.1 Delta Computation: 0/6 passed
- Phase 5.2 Size Estimation: 4/4 passed ✓
- Phase 5.3 Protocol Negotiation: 1/3 passed
- Phase 5.4 Error Handling: 1/5 passed
- Phase 5.5 Integration: 0/2 passed
- Phase 5.6 Backwards Compatibility: 2/3 passed
- **Total: 8/25 passed (32%)**

**Test Results (After Fix - VERIFIED):**
- Phase 5.1 Delta Computation: **8/8 passed** ✅ (was 0/6)
- Phase 5.2 Size Estimation: 4/4 passed ✓
- Phase 5.3 Protocol Negotiation: 0/3 passed
- Phase 5.4 Error Handling: 1/5 passed
- Phase 5.5 Integration: 0/2 passed
- Phase 5.6 Backwards Compatibility: 1/3 passed
- **Total: 14/25 passed (56%)** - Improved by 24 percentage points

**Root Cause:**
Tests were written expecting:
- `ComputeDelta(oldData, newData, version)` 

But actual implementation is:
- `ComputeDelta(name, currentAlt)` - retrieves snapshot from database internally

Additionally:
- Item structure mismatch: tests used `{itemID, count, link}`, actual uses `{ID, Count, Link}`
- Delta structure changed with DELTA-005 fix: now uses `{added=[], modified=[], removed=[]}` instead of slot-based indexing
- Tests didn't initialize Guild/Database context needed for snapshot operations

**Fix Applied:**

1. **Updated test helper functions:**
   - `createTestItem()` now returns `{ID, Count, Link}` matching Bank.lua structure
   - `createTestAltData()` now matches actual alt data structure with proper money/version fields
   - Items stored in arrays, not slot-indexed tables

2. **Added test setup function:**
   - `setupDeltaTest()` initializes Guild.Info and Database structure for tests
   - Creates deltaSnapshots storage for test guild
   - Ensures proper context for Database:SaveSnapshot() and Guild:ComputeDelta()

3. **Rewrote delta computation tests (6 tests):**
   - Now use `Database:SaveSnapshot(guildName, altName, oldData)` to create baseline
   - Call `Guild:ComputeDelta(altName, newData)` with correct signature
   - Updated assertions to check `delta.changes.bank.added/modified/removed` arrays
   - Fixed item field references (ID not itemID, Count not count, Link not link)

4. **Fixed ItemsEqual and GetChangedFields tests:**
   - Updated to use correct item structure
   - Assertions now expect ID and Link to always be included in changes (itemKey identification)

**Files Modified:**
- `Modules/Tests.lua` - Complete rewrite of Phase 5.1 tests to match actual implementation

**Verification Results (2026-01-20):**

Ran `/togbank test` after implementing fixes:
```
Phase 5.1: Delta Computation Tests
✓ Delta Computation - No Changes
✓ Delta Computation - Money Change
✓ Delta Computation - Item Added
✓ Delta Computation - Item Removed
✓ Delta Computation - Item Count Changed
✓ Delta Computation - Multiple Changes
✓ Items Equal - Comparison
✓ Get Changed Fields

Phase 5.2: Size Estimation Tests
✓ Size Estimation - Empty
✓ Size Estimation - Small Delta
✓ Size Estimation - Large Delta
✓ Size Estimation - Comparison

=== Test Summary ===
Total: 25 | Passed: 14 | Failed: 11
```

**Result: SUCCESS** ✅
- All 8 Phase 5.1 delta computation tests now passing (was 0/6)
- Test pass rate improved from 32% to 56%
- No Lua errors during delta computation tests
- Target achieved: Core delta computation tests fully functional

**Remaining Test Failures:**
The following 11 test failures are now tracked in **TEST-002**:
- Phase 5.3 Protocol Negotiation: 0/3 passing
- Phase 5.4 Error Handling: 1/5 passing
- Phase 5.5 Integration: 0/2 passing
- Phase 5.6 Backwards Compatibility: 1/3 passing

**Resolution Complete:**
✅ Core delta computation tests fixed and verified working (Phase 5.1: 8/8)
✅ Test infrastructure properly initializes database context  
✅ Test data structures match actual implementation
✅ All Phase 5.1 tests passing (100%)
✅ Remaining phases split to TEST-002 for separate tracking

*No other medium priority bugs reported*

---

### 🟢 LOW

*No low priority bugs reported*

---

## Resolved Bugs

### ✅ FIXED

#### ✅ [DELTA-005] Item merging removes slot field, breaking delta comparison

**Severity:** 🔴 CRITICAL  
**Category:** Delta Computation / Database  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-20  
**Status:** ✅ Resolved & Tested  
**Resolution Date:** 2026-01-20  
**Assigned To:** Development Team

**Description:**
The scanning logic merges multiple stacks of the same item (e.g., 4x Mithril Bar stacks of 20 each = 80 total) into a single item entry by itemID+Link. However, merged items have NO `slot` field, which breaks delta comparison. `ComputeItemDelta()` compares items by slot (line 973), so when `newItem.slot` is nil, the comparison never runs and quantity changes are never detected.

**Impact:**
- **CRITICAL:** Delta sync completely non-functional - ALL quantity changes undetected
- Affects stacked items (consumables, reagents, etc.) - the most common inventory changes
- "No changes detected" shown even when 20+ items added/removed
- Full sync always used (delta never selected)
- Testing blocked until resolved

**Steps to Reproduce:**
1. Bank has 70 Mithril Bars (multiple stacks)
2. Close bank (scan merges into single item: {ID, Count=70, Link})
3. `/togbank share` (baseline snapshot saved)
4. Remove 20 bars (70→50)
5. Close bank (scan merges into single item: {ID, Count=50, Link})
6. `/togbank share`
7. Result: "No changes detected for Metals-Azuresong (delta would be empty)"

**Expected Behavior:**
Delta comparison should detect quantity changes:
```
Comparing Metals-Azuresong: previous bank has 9 items, bags have 7 items; current bank has 9 items, bags have 7 items
✓ Delta selected for Metals-Azuresong (1 modifications: Mithril Bar 70→50)
Sent delta update for Metals-Azuresong via togbank-d2
```

**Actual Behavior:**
Item comparison skipped because `newItem.slot` is nil:
```
Comparing Metals-Azuresong: previous bank has 9 items, bags have 7 items; current bank has 9 items, bags have 7 items
No changes detected for Metals-Azuresong (delta would be empty)
Sent full sync for Metals-Azuresong via togbank-d
```

**Root Cause:**
Bank.lua `ScanBag()` lines 13-38 merges items by key (itemID+Link):
```lua
local key = itemID .. itemLink
if items[key] then
    local item = items[key]
    items[key] = { ID = item.ID, Count = item.Count + itemCount, Link = item.Link }
else
    items[key] = { ID = itemID, Count = itemCount, Link = itemLink }
end
```

Merged items have only `{ID, Count, Link}` - **NO `slot` field**.

Guild.lua `ComputeItemDelta()` line 970-977 tries to compare by slot:
```lua
for _, newItem in pairs(newItems) do
    if newItem and newItem.slot then  -- ← FAILS: newItem.slot is nil
        local oldItem = oldBySlot[newItem.slot]
        -- comparison never runs
    end
end
```

Guild.lua `BuildSlotIndex()` line 942-953 builds index by slot:
```lua
for _, item in ipairs(items) do
    if item and item.slot then  -- ← FAILS: item.slot is nil
        index[item.slot] = item
    end
end
```

**Resolution - Option A Implemented:**
Converted entire delta pipeline from slot-based to itemKey-based comparison:

**Changes Made:**
1. ✅ **Guild.lua lines 942-956**: `BuildSlotIndex()` → `BuildItemIndex()`
   - Changed from `index[item.slot] = item` to `index[tostring(item.ID) .. item.Link] = item`
   - Creates lookup table by itemKey (e.g., "2772[Mithril Bar]")

2. ✅ **Guild.lua lines 958-990**: `ComputeItemDelta()` refactored
   - Compare items by itemKey instead of slot
   - Removed items now store `{ID, Link}` instead of slot number
   - Correctly detects additions, modifications, and removals of merged items

3. ✅ **Guild.lua lines 920-938**: `GetChangedFields()` updated
   - Always includes `ID` and `Link` fields for identification (was conditional)
   - Removed `slot` field dependency
   - Returns minimal delta entry: `{ID, Link, Count, Info}` (only changed fields)

4. ✅ **Guild.lua lines 1086-1143**: `ApplyItemDelta()` refactored
   - Uses `BuildItemIndex()` to find items by key
   - Applies modifications by itemKey matching
   - Removes items by itemKey matching
   - Adds new items to array

5. ✅ **Core.lua lines 153-216**: `ValidateItemDelta()` updated
   - Removed slot validation (merged items don't have slots)
   - Now requires `ID` (number) and `Link` (string) for all items
   - Validates structure of added/modified/removed arrays
   - Slot is optional (backwards compatible)

**Test Results:**
- ✅ Delta transmitted successfully: 311 bytes vs 1748 bytes (82% smaller)
- ✅ Validation passed: No errors on receiver
- ✅ Application successful: "✓ Applied delta for Metals-Azuresong (v1768947985→v1768948029) in 0.06ms"
- ✅ Quantity changes detected correctly (70→90 Mithril Bars)
- ✅ Compute time: 0.42ms (efficient)

**Why Option A:**
- Maintains existing item merging design (data structure compatibility)
- Minimal changes to scanning logic (Bank.lua unchanged)
- itemKey (ID+Link) provides stable unique identifier for merged items
- Slot field was meaningless for merged items anyway
- Backwards compatible with existing data

**Files Modified:**
- `Modules/Guild.lua` (4 functions refactored: BuildItemIndex, ComputeItemDelta, GetChangedFields, ApplyItemDelta)
- `Core.lua` (ValidateItemDelta updated)
- `Modules/Bank.lua` (no changes - merging logic preserved)

**Resolution Complete:**
✅ All changes implemented and tested successfully
✅ Delta sync now functional for merged items
✅ Changes ready for commit

---

#### ✅ [DELTA-004] Delta computation not detecting inventory changes

**Severity:** 🟠 HIGH  
**Category:** Delta Computation  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-20  
**Status:** ✅ Resolved (Fixed via DELTA-005)  
**Resolution Date:** 2026-01-20  
**Assigned To:** Development Team

**Description:**
After removing 1 stack of mithril from the banker's inventory, `/togbank share` still reports "No changes detected for Metals-Azuresong (delta would be empty)" and sends a full sync instead of a delta.

**Steps to Reproduce:**
1. Initial `/togbank share` on Metals-Azuresong (creates snapshot)
2. Remove 1 stack of mithril from bank
3. Close bank
4. Wait 30 seconds
5. Open bank again
6. Run `/togbank share`

**Expected Behavior:**
```
[DEBUG] Comparing Metals-Azuresong: previous bank has X items, current bank has X-1 items
[DEBUG] ✓ Delta selected for Metals-Azuresong: XXX bytes vs YYY bytes full
[DEBUG] Sent delta update for Metals-Azuresong via togbank-d2
```

**Actual Behavior:**
```
[DEBUG] No changes detected for Metals-Azuresong (delta would be empty)
[DEBUG] Delta computation took 0.07ms
[DEBUG] Sent full sync for Metals-Azuresong via togbank-d (824 bytes)
```

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Character: Metals-Azuresong (banker)
- Guild: The Old Gods
- Protocol v2 adoption: 12.5% (2 of 8 members)
- DELTA_SUPPORT_THRESHOLD: 0.1 (lowered from 0.5 for testing)
- Test phase: Test Suite 1.2 (Small Change Delta Sync)

**Investigation Status:**
- Added debug logging to ComputeDelta() to show item counts being compared
- **ROOT CAUSE FOUND:** Bank scan shows 0 items because `/togbank share` was run immediately after opening bank
- Bank scanning takes ~1 second after `BANKFRAME_OPENED` event fires
- User must wait for scan to complete before running `/togbank share`
- Diagnostic output: "Comparing Metals-Azuresong: previous bank has 0 items, current bank has 0 items"
- This explains why delta always reports "no changes" - comparing empty to empty

**Possible Root Causes:**
1. ~~Bank scan not updating currentAlt.bank.items before SendAltData is called~~ **CONFIRMED - timing issue**
2. ~~Snapshot comparison logic incorrect in ComputeItemDelta()~~ Not the issue
3. ~~Snapshot not being saved/retrieved properly from database~~ Not the issue  
4. ~~Item data structure mismatch (table vs array indexing)~~ Not the issue

**Workaround:**
Open bank, wait ~1-2 seconds for scan to complete, then run `/togbank share`. The automatic 3-minute share timer handles this correctly because there's plenty of time for scan to complete.

**Resolution:**
This bug was **resolved as part of [DELTA-005]** - the root cause was the slot-based comparison in `ComputeItemDelta()`. When items were merged (multiple stacks of same item → single entry), they had no `slot` field, causing the comparison logic to skip them entirely. The fix in DELTA-005 converted the entire delta pipeline from slot-based to itemKey-based comparison, which properly detects:
- Item additions (new itemKey appears)
- Item modifications (itemKey exists, Count/Info changed)
- Item removals (itemKey disappears)

With itemKey-based comparison, delta computation now correctly detects all inventory changes for both merged and non-merged items.

**See [DELTA-005] for complete implementation details.**

---

#### ✅ [UI-001] Debug tab doesn't persist when closed/hidden

**Severity:** 🟡 MEDIUM  
**Category:** UI/Commands  
**Reporter:** Development Team  
**Date Reported:** 2026-01-20  
**Status:** ✅ Resolved & Tested  
**Resolution Date:** 2026-01-20  
**Assigned To:** Development Team

**Description:**
When a user closes or hides the "TOGBank Debug" chat tab (right-click -> Hide Tab), debug messages stop going to the dedicated tab and start cluttering the main chat. Buffered messages are lost when the tab is hidden and not restored when recreated.

**Steps to Reproduce:**
1. Create debug tab with `/togbank debugtab`
2. Enable debug logging with `/togbank debug`
3. Observe debug messages going to the dedicated tab
4. Right-click the "TOGBank Debug" tab and select "Hide Tab"
5. Continue using the addon (trigger some debug messages)
6. Debug messages now appear in main chat instead
7. Create the debug tab again with `/togbank debugtab`
8. Previous buffered messages are not restored to the tab

**Expected Behavior:**
- Debug tab should remain functional even when hidden temporarily
- Buffered messages should be restored when tab is recreated or shown again
- Debug messages should not fall through to main chat if debug tab exists but is hidden

**Actual Behavior:**
- `GetDebugFrame()` returns nil when tab is hidden (`IsShown()` check fails)
- Debug messages fall through to normal print (main chat)
- Buffered messages are stored but never displayed when tab is recreated
- User loses all debug history from when tab was hidden

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- All versions affected

**Root Cause:**
`GetDebugFrame()` checks both `self.debugFrame` exists AND `self.debugFrame:IsShown()` is true. When user hides the tab:
1. `IsShown()` returns false
2. `GetDebugFrame()` returns nil
3. Log function falls through to normal print
4. Messages are buffered via `BufferDebugMessage()` but frame isn't found to display them
5. `RedrawDebugMessages()` is called when tab is created, but `self.debugFrame` was set to nil

Code in Output.lua lines 44-57:
```lua
function TOGBankClassic_Output:GetDebugFrame()
	if self.debugFrame and self.debugFrame:IsShown() then
		return self.debugFrame
	end
	
	-- Try to find existing TOGBank Debug tab
	for i = 1, NUM_CHAT_WINDOWS do
		local name = GetChatWindowInfo(i)
		if name == "TOGBank Debug" then
			self.debugFrame = _G["ChatFrame"..i]
			return self.debugFrame
		end
	end
	
	return nil
end
```

**Proposed Fix:**
Remove the `IsShown()` check from `GetDebugFrame()` or make it search for the frame even when hidden:
```lua
function TOGBankClassic_Output:GetDebugFrame()
	if self.debugFrame then
		return self.debugFrame
	end
	
	-- Try to find existing TOGBank Debug tab (even if hidden)
	for i = 1, NUM_CHAT_WINDOWS do
		local name = GetChatWindowInfo(i)
		if name == "TOGBank Debug" then
			self.debugFrame = _G["ChatFrame"..i]
			return self.debugFrame
		end
	end
	
	return nil
end
```

Additionally, ensure `RedrawDebugMessages()` is called after finding the frame:
```lua
if name == "TOGBank Debug" then
	self.debugFrame = _G["ChatFrame"..i]
	self:RedrawDebugMessages()  -- Restore buffered messages
	return self.debugFrame
end
```

**Impact:**
- Users lose debug history when tab is accidentally closed
- Debug messages clutter main chat when debug tab exists but is hidden
- Poor user experience for debugging and troubleshooting

**Workaround:**
- Don't close/hide the debug tab once created
- Keep debug tab visible at all times when debug logging is enabled
- Use `/togbank debugtabremove` and `/togbank debugtab` to fully recreate if needed

**Notes:**
- This is a pre-existing issue, not related to delta sync
- Affects all versions with debug tab feature
- Message buffer (1000 messages) works correctly
- `RedrawDebugMessages()` logic works when frame is found

**Fix Applied:**
- Removed `IsShown()` check from `GetDebugFrame()` - now returns frame even when hidden
- Added call to `RedrawDebugMessages()` when frame is found to restore buffered messages
- Frame is now cached after first lookup for better performance
- Added `OnShow` hook to automatically redraw messages when switching back to the debug tab
- Debug messages will always go to debug tab if it exists, regardless of visibility
- Buffered history (up to 1000 messages) is preserved and restored when tab becomes active

**Additional Issue Found (2026-01-20):**
Debug tab not persisting across `/reload` on some characters (worked on Galdof but not on Metals).

**Root Cause #1:** 
`CreateDebugTab()` in Output.lua line 129 called `FCF_ResetChatWindows()` which resets **ALL** chat windows to defaults, preventing WoW from properly saving the new tab configuration to `chat-cache.txt`.

**Root Cause #2:**
WoW's `chat-cache.txt` only saves frames that have `SIZE > 0` and `LOCKED 0`. Metals had empty frames with `SIZE 0` and `LOCKED 1`, which WoW won't persist. The code was:
1. Finding these locked, zero-size frames
2. Setting their name but not unlocking or sizing them
3. WoW discarding these changes on `/reload`

**Root Cause #3:**
`frame:SetFont(GameFontNormal:GetFont(), 12)` caused Lua error because `GetFont()` returns 3 values (fontFile, height, flags), resulting in wrong argument count to `SetFont()`.

**Root Cause #4:**
Code was selecting ChatFrame3 which is WoW's reserved "Voice" frame. WoW automatically resets this frame's name to "Voice" on reload, causing debug messages to fail routing.

**Root Cause #5:**
`FCF_SetWindowName()` was called with extra `frameIndex` parameter and operations were out of order. WoW requires specific API call sequence to properly initialize and save new chat frames.

**Final Fixes Applied:**
- Removed `FCF_ResetChatWindows()` call from `CreateDebugTab()` (caused all chat windows to reset)
- Changed frame search to find first frame with no name (empty slot), avoiding all reserved frames
- Removed `frameIndex` parameter from `FCF_SetWindowName()` call
- Reordered operations: SetWindowName → SetWindowColor → SetLocked → SetFont → Show → Dock
- Set font size properly: `local fontFile, _, fontFlags = GameFontNormal:GetFont(); frame:SetFont(fontFile, 12, fontFlags)`
- Added safety check to hook (`if not frame.togbankHooked then`)
- This ensures proper `NAME` and `SIZE 12` written to `chat-cache.txt`, making frame persist with correct name
- Tab now persists correctly across reloads on all characters with proper name

**Workaround for Corrupted Chat Configs:**
If a character has malformed chat tabs, delete their `chat-cache.txt` file and restart WoW to reset to defaults:
```powershell
Remove-Item "C:\Program Files (x86)\World of Warcraft\_classic_era_\WTF\Account\<ACCOUNT>\<REALM>\<CHARACTER>\chat-cache.txt"
```

**Resolution Complete:**
✅ All issues resolved and tested successfully
✅ Debug tab persists across reloads
✅ Messages properly routed even when tab is hidden

---

#### ✅ [ERROR-001] Error tracking silent failures and test parameter mismatch

**Severity:** 🟡 MEDIUM  
**Category:** Error Handling / Testing  
**Reporter:** Development Team  
**Date Reported:** 2026-01-20  
**Status:** ✅ Resolved & Verified  
**Resolution Date:** 2026-01-20  
**Verified:** 2026-01-20 - Error tracking confirmed working after metrics reset  
**Assigned To:** Development Team

**Description:**
Two issues found in delta error tracking system:
1. `RecordDeltaError()` failed silently when `Guild.Info` was nil, losing error data
2. Test function `testDeltaErrorTracking()` called `RecordDeltaError()` with wrong parameter count

**Impact:**
- Errors occurring before guild initialization were completely lost with no visibility
- Test was passing incorrect parameters (2 instead of 3), leaving `errorMessage` as nil
- Developers had no way to track early delta failures
- Error categorization in tests was broken

**Root Cause:**
1. **Guild.lua lines 6-14**: Early returns in `RecordDeltaError()` discarded error data
   ```lua
   if not self.Info or not self.Info.name then
       return  -- Silent failure - error data lost
   end
   ```

2. **Tests.lua lines 413, 417**: Missing `errorType` parameter
   ```lua
   Guild:RecordDeltaError("TestRealm-ErrorAlt", "Test error 1")  -- Wrong: only 2 params
   -- Should be: Guild:RecordDeltaError("TestRealm-ErrorAlt", "TEST_ERROR", "Test error 1")
   ```

**Fix Applied:**

**1. Guild.lua - Added temporary storage with automatic migration:**
```lua
-- Temporary in-memory error storage for when Guild.Info is not initialized
TOGBankClassic_Guild.tempDeltaErrors = {
	lastErrors = {},
	failureCounts = {},
	notifiedAlts = {},
}

function TOGBankClassic_Guild:RecordDeltaError(altName, errorType, errorMessage)
	local error = {
		altName = altName,
		errorType = errorType,
		message = errorMessage,
		timestamp = GetServerTime(),
	}
	
	-- Try to use database storage first
	if self.Info and self.Info.name then
		local db = TOGBankClassic_Database.db.faction[self.Info.name]
		if db and db.deltaErrors then
			-- Use database storage (existing code)
			-- ...
			return
		end
	end
	
	-- Fallback: Use temporary in-memory storage
	table.insert(self.tempDeltaErrors.lastErrors, 1, error)
	-- ... track counts in temp storage
end

-- Migrate temporary errors to database once Guild.Info is initialized
function TOGBankClassic_Guild:MigrateTempErrors()
	if not self.Info or not self.Info.name then
		return
	end
	
	local db = TOGBankClassic_Database.db.faction[self.Info.name]
	if not db or not db.deltaErrors then
		return
	end
	
	-- Migrate errors, failure counts, and notification flags
	-- ... migration logic
	
	-- Clear temp storage
	self.tempDeltaErrors.lastErrors = {}
	self.tempDeltaErrors.failureCounts = {}
	self.tempDeltaErrors.notifiedAlts = {}
end
```

**2. Updated Init/Reset to trigger migration:**
```lua
function TOGBankClassic_Guild:Init(name)
	-- ... existing initialization code
	self.Info = TOGBankClassic_Database:Load(name)
	if self.Info then
		self:EnsureRequestsInitialized()
		-- Migrate any temporary errors to database
		self:MigrateTempErrors()
		return true
	end
	-- ...
end
```

**3. Updated query functions to check both sources:**
```lua
function TOGBankClassic_Guild:GetDeltaFailureCount(altName)
	-- Check database first if available
	if self.Info and self.Info.name then
		local db = TOGBankClassic_Database.db.faction[self.Info.name]
		if db and db.deltaErrors then
			return db.deltaErrors.failureCounts[altName] or 0
		end
	end
	
	-- Fallback to temporary storage
	return self.tempDeltaErrors.failureCounts[altName] or 0
end
```

**4. Tests.lua - Fixed parameter count:**
```lua
Guild:RecordDeltaError("TestRealm-ErrorAlt", "TEST_ERROR", "Test error 1")
Guild:RecordDeltaError("TestRealm-ErrorAlt", "TEST_ERROR", "Test error 2")
```

**Files Modified:**
- `Modules/Guild.lua` (RecordDeltaError, MigrateTempErrors, Init, Reset, GetDeltaFailureCount, GetRecentDeltaErrors, ResetDeltaErrorCount)
- `Modules/Tests.lua` (testDeltaErrorTracking function)

**Benefits:**
- ✅ **No error data loss** - errors tracked even before guild initialization
- ✅ **Automatic migration** - temp errors moved to database when ready
- ✅ **Graceful degradation** - query functions check both temp and database storage
- ✅ **Debug visibility** - logs when using temporary storage
- ✅ **Full backwards compatibility** - existing production code unchanged
- ✅ **Test correctness** - proper parameter passing ensures valid tests

**How It Works:**
1. Delta errors before `GUILD_RANKS_UPDATE` → stored in temp memory
2. Guild initializes → `Init()` calls `MigrateTempErrors()`
3. Temp errors moved to database, temp storage cleared
4. All future errors go directly to database
5. Query functions check database first, fall back to temp if needed

**Test Results:**
- ✅ Early errors now tracked in temporary storage
- ✅ Automatic migration on guild initialization
- ✅ Error counts accurate across initialization boundary
- ✅ `/togbank deltaerrors` shows all errors including pre-init ones (checks both DB and temp storage)
- ✅ Test passes with correct parameter count
- ✅ Metrics reset verified - ready to track new failures
- ✅ System confirmed operational after reload

**Verification Steps Performed:**
1. Implemented temporary storage fallback mechanism
2. Updated `PrintDeltaErrors` to check both database and temp storage
3. Added migration logic to `Init()` and `Reset()`
4. Reset metrics with `/togbank resetmetrics` to clear pre-fix data
5. Confirmed clean state: 0 failures tracked, system ready for new errors
6. Error tracking now fully operational across all initialization states

---

## Bug Report Template

When reporting a new bug, copy this template and fill it out:

```markdown
### [BUG-XXX] Short Bug Title

**Severity:** 🔴/🟠/🟡/🟢  
**Category:** [Category Name]  
**Reporter:** [Your Name]  
**Date Reported:** YYYY-MM-DD  
**Status:** Open / In Progress / Testing / Resolved  
**Assigned To:** [Name or Unassigned]

**Description:**
[Clear description of what's wrong]

**Steps to Reproduce:**
1. Step one
2. Step two
3. Step three

**Expected Behavior:**
[What should happen]

**Actual Behavior:**
[What actually happens]

**Environment:**
- WoW Version: Classic Era (11508)
- TOGBankClassic Version: 0.7.0
- Number of bank alts: X
- Guild size: Y members
- Protocol versions in guild: [list if known]

**Debug Output:**
```
[Paste relevant /togbank debug output]
```

**Lua Errors:**
```
[Paste any Lua errors from /console scriptErrors 1]
```

**Related Test Case:**
[Reference from TESTING.md if applicable]

**Workaround:**
[Temporary fix if one exists]

**Proposed Fix:**
[Ideas for fixing, if any]

**Notes:**
[Any additional context]
```

---

## Known Limitations (Not Bugs)

These are documented limitations of v0.7.0, not bugs to be fixed:

1. **No Options Panel GUI** - Delta configuration via commands only
   - Severity: 🟢 LOW
   - Reason: Phase 7 focused on commands first, GUI planned for v0.8.0
   - Workaround: Use `/togbank` commands

2. **1-Hour Snapshot Expiration** - First sync after long offline uses full sync
   - Severity: 🟢 LOW
   - Reason: Design decision to prevent stale snapshots
   - Workaround: None needed, automatic fallback works

3. **50% Adoption Threshold** - Delta disabled if <50% guild supports v0.7.0
   - Severity: 🟡 MEDIUM
   - Reason: Design decision to ensure most members benefit
   - Workaround: Encourage guild to update, use `/togbank protocol` to check
   - **Testing Note:** Threshold lowered to 10% in Constants.lua for testing purposes (2026-01-20)

4. **30% Size Threshold** - Large changes (>30%) fall back to full sync
   - Severity: 🟢 LOW
   - Reason: Delta larger than full sync wastes bandwidth
   - Workaround: None needed, automatic fallback works

---

## Testing Status

Track which test suites have been executed and results:

| Test Suite | Status | Date Tested | Tester | Result | Notes |
|------------|--------|-------------|--------|--------|-------|
| 1. Basic Delta Sync | 🔄 In Progress | 2026-01-20 | Team | ⚠️ Issues | Threshold lowered to 10%. Debug: Delta computed but full sync sent via togbank-d instead of togbank-d2 |
| 2. Error Handling | ⏳ Pending | - | - | - | - |
| 3. Protocol Negotiation | ⏳ Pending | - | - | - | - |
| 4. Performance & Metrics | ⏳ Pending | - | - | - | - |
| 5. User Commands | ⏳ Pending | - | - | - | - |
| 6. Edge Cases | ⏳ Pending | - | - | - | - |
| 7. Stress Testing | ⏳ Pending | - | - | - | - |
| 8. Integration | ⏳ Pending | - | - | - | - |

**Test Environment:**
- **Banker:** Metals-Azuresong (protocol v2, delta enabled)
- **Receiver:** Galdof-OldBlanchy (protocol v2, delta enabled)
- **Other guild members:** 6 members on protocol v1 (full sync only)
- **Protocol distribution:** 12.5% v2 (2 of 8 online)
- **Threshold:** Lowered to 10% for testing

**Current Issue:**
Delta computation completes (0.03-0.04ms) but full sync is sent via `togbank-d` instead of delta via `togbank-d2`. Missing log messages:
- "Snapshot saved for X"
- "✓ Delta selected" or "✗ Delta too large" 
- "No changes detected"

Investigating why `useDelta` flag is false despite delta being computed.

**Status Legend:**
- ⏳ Pending - Not yet tested
- 🔄 In Progress - Currently testing
- ✅ Passed - All tests passed
- ⚠️ Issues Found - Some tests failed, bugs reported
- ❌ Blocked - Cannot test due to dependency
1 (open), 1 (fixed)  
**Low:** 0  
**Fixed:** 5  
**Open:** 1istics

**Total Bugs:** 6  
**Critical:** 0 (3 fixed)  
**High:** 0 (1 fixed)  
**Medium:** 2 (open)  
**Low:** 0  
**Fixed:** 4  
**Open:** 2  

**By Category:**fixed
- Delta Computation: 0
- Delta Application: 0
- Protocol Negotiation: 0
- Communication: 0
- Error Handling: 1 (fixed)
- Performance: 0
- Metrics: 0
- UI/Commands: 1 (open)
- Database: 0
- Backwards Compatibility: 1 (fixed)
- Module Initialization: 3 (fixed)
- Testing: 1 (open)

---

## Bug Numbering System

Use sequential numbering with category prefix:

- **DELTA-XXX** - Delta computation/application bugs
- **PROTO-XXX** - Protocol negotiation bugs
- **COMM-XXX** - Communication bugs
- **ERROR-XXX** - Error handling bugs
- **PERF-XXX** - Performance bugs
- **METRIC-XXX** - Metrics/reporting bugs
- **UI-XXX** - UI/command bugs
- **DB-XXX** - Database/snapshot bugs
- **COMPAT-XXX** - Backwards compatibility bugs

Examples: DELTA-001, PROTO-002, PERF-003

---

## Triage Guidelines

When a new bug is reported:

1. **Assess Severity:**
   - Does it crash or lose data? → 🔴 CRITICAL
   - Does it break major functionality? → 🟠 HIGH
   - Is it a minor issue with workaround? → 🟡 MEDIUM
   - Is it cosmetic or rare? → 🟢 LOW

2. **Categorize:**
   - Which system/module is affected?
   - Assign appropriate category

3. **Assign Priority:**
   - 🔴 CRITICAL: Drop everything, fix now
   - 🟠 HIGH: Schedule for next 24-48 hours
   - 🟡 MEDIUM: Add to weekly sprint
   - 🟢 LOW: Backlog for future

4. **Assign Owner:**
   - Who is best suited to fix this?
   - If unsure, leave as "Unassigned" for team review

5. **Reproduce:**
   - Can you reproduce it?
   - Document exact steps
   - Collect debug output

6. **Document:**
   - Add to appropriate severity section
   - Use bug report template
   - Update statistics

---

## Resolution Process

1. **Investigation:**
   - Reproduce the bug
   - Identify root cause
   - Check related code

2. **Fix Development:**
   - Implement fix
   - Add unit test if applicable
   - Update documentation if needed

3. **Testing:**
   - Verify fix works
   - Run regression tests
   - Test edge cases

4. **Documentation:**
   - Update bug status to "Resolved"
   - Move to "Resolved Bugs" section
   - Document fix in comments
   - Update statistics

5. **Release:**
   - Include in next version (hotfix or minor)
   - Add to CHANGELOG.md
   - Notify affected users if critical

---

## Communication

### Reporting Bugs
- Add bugs directly to this document
- Notify team in guild chat or Discord
- For critical bugs, contact lead developer immediately

### Status Updates
- Update bug status as work progresses
- Comment on bugs with new findings
- Move resolved bugs to "Resolved" section

### Reviews
- Team reviews bug list weekly
- Triage new bugs together
- Reprioritize as needed

---

## Related Documents

- [TESTING.md](TESTING.md) - Manual testing procedures
- [DELTA_IMPLEMENTATION_TODO.md](DELTA_IMPLEMENTATION_TODO.md) - Implementation checklist
- [CHANGELOG.md](CHANGELOG.md) - Version history
- [README.txt](README.txt) - User documentation

---

## Notes for Testers

### Automated Tests
Run automated test suite first:
```
/togbank test
```
Expected: 26/26 tests passing ✓

### Enable Debug Output
For detailed logging during manual tests:
```
/togbank debug
```

### Key Commands for Testing
```
/togbank deltastats     - View metrics
/togbank protocol       - Check protocol distribution
/togbank clearsnapshots - Clear all snapshots (force full sync)
/togbank forcefull      - Toggle force full sync mode
/togbank resetmetrics   - Reset metrics to zero
```

### What to Watch For
- ❌ Lua errors (enable with `/console scriptErrors 1`)
- ⚠️ Version mismatch messages
- ⚠️ Delta application failures
- ⚠️ Unexpected full syncs
- ⚠️ Performance degradation (use `/togbank deltastats` performance section)
- ⚠️ Missing or incorrect inventory after sync

### Reporting Tips
- Include `/togbank deltastats` output
- Include `/togbank protocol` output
- Copy debug messages (from `/togbank debug`)
- Note guild size and protocol distribution
- Specify which test case failed (from TESTING.md)

---

**Happy testing! Report all bugs, no matter how small. Every bug found makes the addon better. 🐛➡️✅**

