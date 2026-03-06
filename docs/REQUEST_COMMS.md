# Request Communication & Synchronization Architecture

## Overview

TOGBankClassic uses an **event-sourced, distributed synchronization system** for guild member requests. Instead of simply broadcasting snapshots, the system maintains an **append-only event log** that records every request creation, modification, and deletion. This enables:

1. **Conflict-free merging** - Multiple guild members can create/modify requests independently
2. **Offline resilience** - Players who were offline can catch up by replaying missed events
3. **Auditability** - Full history of who created/modified each request and when
4. **Data recovery** - Requests can be reconstructed from event log if snapshot gets corrupted

---

## Core Data Structures

### 1. Request Snapshot (`self.Info.requests`)
**Type:** Array of request objects
**Persistence:** SavedVariables via AceDB
**Purpose:** Current materialized state of all active requests

```lua
self.Info.requests = {
    {
        id = "Shamanoodles-OldBlanchy-1769171234",
        item = "Gromsblood",
        quantity = 20,
        fulfilled = 0,
        priority = "normal",
        createdAt = 1769171234,
        updatedAt = 1769171234,
        actor = "Shamanoodles-OldBlanchy"
    },
    -- ... more requests ...
}

-- Alt data with mail support
self.Info.alts["BankerName-Realm"] = {
    version = 1769171234,
    money = 123456,
    inventoryHash = 98765,       -- Hash of bank + bags + mail
    mailHash = 12345,            -- Separate hash for mail-only changes
    inventoryUpdatedAt = 1769171234,
    items = { ... },             -- Aggregated bank + bags + mail
    bank = { items = {...} },
    bags = { items = {...} },
    mail = { items = {...}, version = 1769171200, lastScan = 1769171200 }
}
```

### 2. Event Log (`self.Info.requestLog`)
**Type:** Array of log entries
**Persistence:** SavedVariables via AceDB
**Purpose:** Append-only history of all request mutations

```lua
self.Info.requestLog = {
    {
        id = "Shamanoodles-OldBlanchy-3",  -- Unique log entry ID
        actor = "Shamanoodles-OldBlanchy",  -- Who made this change
        seq = 3,                            -- Sequence number (per-actor)
        ts = 1769171234,                    -- Timestamp
        type = "add",                       -- Event type: add, fulfill, delete
        requestId = "Shamanoodles-OldBlanchy-1769171234",
        request = { ... }                   -- Full request snapshot (for 'add')
    },
    {
        id = "Banker-OldBlanchy-15",
        actor = "Banker-OldBlanchy",
        seq = 15,
        ts = 1769171300,
        type = "fulfill",
        requestId = "Shamanoodles-OldBlanchy-1769171234",
        delta = { fulfilled = 10 }          -- Changes only (for 'fulfill')
    },
    -- ... more log entries ...
}
```

### 3. Applied Sequence Tracker (`self.Info.requestLogApplied`)
**Type:** Map of actor → last applied sequence number
**Persistence:** SavedVariables via AceDB
**Purpose:** Track which log entries have been applied to the snapshot

```lua
self.Info.requestLogApplied = {
    ["Shamanoodles-OldBlanchy"] = 42,  -- Applied through seq 42
    ["Banker-OldBlanchy"] = 15,        -- Applied through seq 15
    -- ... more actors ...
}
```

This map prevents replay duplicates. When replaying entries:
```lua
if entry.seq <= requestLogApplied[entry.actor] then
    skip  -- Already applied
else
    apply  -- New entry
end
```

### 4. Sequence Generator (`self.Info.requestLogSeq`)
**Type:** Map of actor → next sequence to emit
**Persistence:** SavedVariables via AceDB
**Purpose:** Generate monotonically increasing sequence numbers per actor

```lua
self.Info.requestLogSeq = {
    ["Shamanoodles-OldBlanchy"] = 43,  -- Next seq to emit is 43
    ["Banker-OldBlanchy"] = 16,        -- Next seq to emit is 16
}
```

### 5. Tombstones (`self.Info.requestsTombstones`)
**Type:** Map of requestId → deletion timestamp
**Persistence:** SavedVariables via AceDB
**Purpose:** Track deleted requests to prevent resurrection

```lua
self.Info.requestsTombstones = {
    ["OldRequest-123"] = 1769170000,  -- Deleted at this timestamp
}
```

### 6. Runtime Indices (NOT Persisted)
**Type:** Maps built on load
**Persistence:** Rebuilt from `requestLog` on every load
**Purpose:** Fast lookups during runtime

```lua
-- Built by RebuildRequestLogIndex()
self.requestLogIndex = {
    ["Shamanoodles-OldBlanchy-3"] = true,  -- Quick existence check
}

self.requestLogByActor = {
    ["Shamanoodles-OldBlanchy"] = {
        { id = "...", seq = 1, ... },
        { id = "...", seq = 2, ... },
        { id = "...", seq = 3, ... },
    },
    ["Banker-OldBlanchy"] = { ... },
}
```

---

## Data Persistence Flow

### On Addon Load (Login/Reload)

1. **AceDB Loads SavedVariables** → `TOGBankClassic_Database:Init()`
   - Loads: `requests`, `requestLog`, `requestLogApplied`, `requestLogSeq`, `requestsTombstones`

2. **Guild Module Gets Reference** → `self.Info = TOGBankClassic_Database:Load(guildName)`
   - `self.Info` is a **direct reference** to the AceDB table
   - Changes to `self.Info.*` automatically persist to SavedVariables

3. **Rebuild Runtime Indices** → `EnsureRequestsInitialized()`
   - Calls `RebuildRequestLogIndex()` to build `self.requestLogIndex` and `self.requestLogByActor`
   - These are **NOT saved** - they're rebuilt every time from `requestLog`

4. **Validate & Replay** → `EnsureRequestsInitialized()` (continued)
   - **[REPLAY-001 Fix]** Validates that `requestLogApplied` is consistent with event log
   - If inconsistency detected (e.g., requests marked as applied but don't exist in snapshot):
     - Clears `requestLogApplied` (sets all actors to 0)
     - Calls `ReplayRequestLogEntries()` to rebuild snapshot from event log
   - If `requestLogApplied` is empty but event log has entries:
     - Initializes actors to seq 0
     - Replays all entries

### During Session (Receiving Syncs)

When receiving data from other players:

1. **Snapshot Arrives** → `ReceiveRequestsData()` → `ApplyRequestSnapshot()`
   - **Merges** incoming snapshot with local snapshot (preserves both)
   - **Smart-merges** `requestLogApplied` using SYNC-001 fix:
     - Only accepts incoming seq if it won't skip local event log entries
     - Protects local events from being marked as "already applied" prematurely
   - Updates `self.Info.requestLogApplied` ✅ **PERSISTS**
   - Updates `self.Info.requests` ✅ **PERSISTS**
   - Updates `self.Info.requestsTombstones` ✅ **PERSISTS**

2. **Log Entries Arrive** → `ReceiveRequestLogEntries()`
   - Appends to `self.Info.requestLog` ✅ **PERSISTS**
   - Immediately applies via `RecordRequestLogEntry()`:
     - Applies to `self.Info.requests` ✅ **PERSISTS**
     - Updates `self.Info.requestLogApplied[actor]` ✅ **PERSISTS**
   - Updates runtime indices (`self.requestLogIndex`, `self.requestLogByActor`)

3. **Local Request Created** → `AddRequest()` or `ModifyRequest()`
   - Creates log entry via `NextRequestLogSeq()` and `AppendRequestLogEntry()`
   - Appends to `self.Info.requestLog` ✅ **PERSISTS**
   - Applies to `self.Info.requests` ✅ **PERSISTS**
   - Updates `self.Info.requestLogSeq[actor]` ✅ **PERSISTS**
   - Updates `self.Info.requestLogApplied[actor]` ✅ **PERSISTS**
   - Broadcasts log entry to guild

### On Logout/Exit

1. **AceDB Auto-Saves** (WoW's SavedVariables mechanism)
   - All changes to `self.Info.*` tables are automatically written to:
     - `WTF\Account\<account>\SavedVariables\TOGBankClassic.lua`
   - This happens automatically when WoW closes or `/reload` is issued

**IMPORTANT:** AceDB uses table references. Since `self.Info` points directly to the AceDB-backed table, ANY modification to `self.Info.requests`, `self.Info.requestLog`, etc. is automatically marked as dirty and will be saved.

---

## Communication Protocols

### Priority-Based Conflict Resolution

**Added:** 2026-01-28 (SYNC-004 fix)

When multiple players modify the same request concurrently (e.g., user cancels while banker fulfills), the system uses a **priority-based conflict resolution** mechanism to determine which operation wins.

#### Operation Priority Table

Operations are assigned priority levels (higher number = higher priority):

```lua
OPERATION_PRIORITY = {
    add = 1,      -- Creates/updates request data
    fulfill = 2,  -- Updates fulfillment progress (additive, supports partial fills)
    complete = 3, -- Banker marks as finished
    cancel = 4,   -- Requester or banker withdraws request
    delete = 5,   -- Removes request completely (tombstone)
}
```

#### Conflict Resolution Rules

1. **Higher priority always wins** - Regardless of timestamp
   - Example: Cancel (4) overrides Fulfill (2), even if fulfill happened later

2. **Same priority uses timestamp** - Last-writer-wins
   - Example: Two cancels from different actors → newer timestamp wins

3. **Fulfill is additive** - Multiple fulfills accumulate (supports partial fills)
   - Example: Fulfill 10 items, then fulfill 5 more → total 15 fulfilled

4. **Status operations track their type** - Requests store `lastStatusOp` field
   - Tracks which operation type (fulfill, cancel, complete) last changed the status
   - Used to determine current operation priority for future conflict checks

#### Example Scenarios

**Scenario 1: User Cancel vs Banker Fulfill (Race Condition)**
```
Time=100: User cancels request (priority=4)
Time=105: Banker fulfills 10 items (priority=2)
Result: Cancel wins (4 > 2), fulfill is blocked
```

**Scenario 2: Banker Fulfill then User Cancel**
```
Time=100: Banker fulfills 5 items (priority=2, partial fill)
Time=105: User cancels request (priority=4)
Result: Cancel wins (4 > 2), status changes to "cancelled"
Note: fulfilled=5 remains, but status prevents further fulfills
```

**Scenario 3: Multiple Partial Fulfills**
```
Time=100: Banker fulfills 10 items (fulfilled=10)
Time=110: Banker fulfills 8 more items (fulfilled=18, additive)
Time=120: Request quantity=20, fulfilled=18
Result: All fulfills accumulate, status="open" until fulfilled>=quantity
```

**Scenario 4: Competing Cancels (Same Priority)**
```
Time=100: User cancels (statusUpdatedAt=100)
Time=105: Banker also cancels (statusUpdatedAt=105)
Result: Banker cancel wins (same priority, newer timestamp)
```

**Scenario 5: Delete Overrides Everything**
```
Time=100: Request cancelled (priority=4)
Time=105: Banker deletes request (priority=5)
Result: Delete wins (5 > 4), request removed with tombstone
```

#### Implementation Details

The priority system is implemented in `ApplyRequestLogEntry()` (Modules/RequestLog.lua):

**For cancel/complete operations:**
```lua
local incomingPriority = getOperationPriority(entryType)
local currentPriority = getOperationPriority(req.lastStatusOp)

if incomingPriority > currentPriority then
    -- Higher priority operation wins
    req.status = newStatus
    req.lastStatusOp = entryType
elseif incomingPriority == currentPriority then
    -- Same priority: check timestamp
    if entryTs >= statusUpdatedAt then
        req.status = newStatus
        req.lastStatusOp = entryType
    end
end
```

**For fulfill operations:**
```lua
local currentPriority = getOperationPriority(req.lastStatusOp)
local fulfillPriority = getOperationPriority("fulfill")

if currentPriority > fulfillPriority then
    -- Higher priority status (cancel/complete/delete) blocks fulfill
    return false
end

-- Otherwise apply fulfill (additive)
req.fulfilled = req.fulfilled + delta
```

#### Why This Matters

Without priority-based resolution, the original timestamp-only approach caused issues:

**Problem (Old Behavior):**
- User cancels at time=100
- Banker fulfills at time=105
- **Fulfill wins** (newer timestamp) → Cancel ignored! ❌

**Solution (New Behavior):**
- User cancels at time=100 (priority=4)
- Banker fulfills at time=105 (priority=2)
- **Cancel wins** (higher priority) → Fulfill blocked! ✅

This ensures that user intent (cancellations) is respected even when there's network lag or concurrent modifications.

#### Failed Entry Handling (SYNC-005)

When processing log entries, some entries may fail to apply (e.g., blocked by tombstone, invalid data, priority conflicts). The system distinguishes between:

**Permanent Failures** (mark as processed):
- Tombstone blocking: Entry timestamp ≤ deletion tombstone
- Priority blocking: Fulfill blocked by higher-priority cancel/complete
- Invalid data: Missing fields, invalid delta, bad structure
- Unknown operation: Future version incompatibility

**Transient Failures** (retry later):
- Request not found: fulfill/cancel/complete entry arrives before corresponding add

```lua
-- In ReceiveRequestLogEntries()
if not self:RecordRequestLogEntry(entry, false) then
    local isPermanent = self:IsEntryPermanentlyBlocked(entry)
    if isPermanent then
        -- Mark as processed to prevent infinite retries
        requestLogApplied[actor] = seq
    else
        -- Don't update - will retry on next sync
    end
end
```

This prevents infinite retry loops for entries that will never succeed while still allowing transient failures to resolve naturally.

---

### Version Broadcast (togbank-v)

**Frequency:** Every 3 minutes (automatic)
**Priority:** BULK
**Purpose:** Let other players know your current request state version

```lua
-- Sent via SendRequestsVersionPing()
{
    requests = 1769171234,              -- requestsVersion (timestamp)
    requestLog = {                      -- Summary of applied sequences
        ["Shamanoodles-OldBlanchy"] = 42,
        ["Banker-OldBlanchy"] = 15,
    }
}
```

**Receiving Logic:** (`Chat.lua` togbank-v handler)
- Compare incoming `requestLog` summary with local `requestLogApplied`
- If any actor has higher sequence remotely:
  - Query missing entries via `QueryRequestLog()` or `QueryRequestsSnapshot()`

### Snapshot Sync (togbank-d type="requests")

**When:** Initial sync, catch-up, or gap detection
**Priority:** BULK
**Direction:** Response to query

```lua
-- Sent via SendRequestsSnapshot()
{
    type = "requests",
    player = "*",                       -- Wildcard (any player can receive)
    version = 1769171234,               -- requestsVersion
    requests = [ ... ],                 -- Full request array
    requestLogApplied = { ... },        -- Applied sequence tracking
    tombstones = { ... }                -- Deletion tracking
}
```

**Receiving Logic:** (`Chat.lua` togbank-d handler → `ReceiveRequestsData()`)
1. Check if incoming is newer (compare `requestLogApplied` sequences)
2. Call `ApplyRequestSnapshot()`:
   - **Merge** snapshots (don't replace)
   - **Smart-merge** `requestLogApplied` (SYNC-001 fix)
   - Call `ReplayRequestLogEntries()` to apply any local events that weren't in snapshot

### Log Entry Sync (togbank-d type="requests-log")

**When:** Real-time updates, gap filling
**Priority:** ALERT (for creates), BULK (for queries)
**Direction:** Broadcast or targeted

```lua
-- Sent via SendRequestLogEntry() or SendRequestLogEntries()
{
    type = "requests-log",
    player = "*",
    logEntries = [
        {
            id = "Shamanoodles-OldBlanchy-43",
            actor = "Shamanoodles-OldBlanchy",
            seq = 43,
            ts = 1769171300,
            type = "add",
            requestId = "Shamanoodles-OldBlanchy-1769171300",
            request = { ... }           -- Full snapshot for 'add'
        }
    ]
}
```

**Receiving Logic:** (`Chat.lua` togbank-d handler → `ReceiveRequestLogEntries()`)
1. Group entries by actor
2. Sort by sequence
3. For each actor's entries:
   - Check `if seq <= requestLogApplied[actor]` → skip (duplicate)
   - Check `if seq == requestLogApplied[actor] + 1` → apply immediately
   - Check `if seq > requestLogApplied[actor] + 1` → gap detected! Query missing entries

### Query Protocols (togbank-r)

#### Query Snapshot
```lua
-- Sent via QueryRequestsSnapshot()
{
    player = "*",
    type = "requests"
}
```
Response: Snapshot (togbank-d type="requests")

#### Query Log Entries
```lua
-- Sent via QueryRequestLog()
{
    player = "*",
    type = "requests-log",
    logFrom = {
        ["Shamanoodles-OldBlanchy"] = 40,  -- Need seq 40+
        ["Banker-OldBlanchy"] = 13,        -- Need seq 13+
    }
}
```
Response: Log entries (togbank-d type="requests-log")

---

## Key Algorithms

### Smart-Merge requestLogApplied (SYNC-001 Fix)

**Problem:** Incoming snapshots could upgrade `requestLogApplied[actor]` to a value that skips local event log entries, causing requests to disappear.

**Solution:** Only accept incoming sequence numbers if they won't skip our local events.

```lua
-- Build map of max local sequence per actor from our event log
local maxLocalSeq = {}
for actor, entries in pairs(self.requestLogByActor) do
    local maxSeq = 0
    for _, entry in ipairs(entries) do
        if entry.seq > maxSeq then
            maxSeq = entry.seq
        end
    end
    maxLocalSeq[actor] = maxSeq
end

-- For each incoming sequence:
for actor, incomingSeq in pairs(incomingSnapshot.requestLogApplied) do
    local localSeq = self.Info.requestLogApplied[actor] or 0
    local maxLocal = maxLocalSeq[actor] or 0

    if incomingSeq > localSeq then
        if incomingSeq > maxLocal then
            -- Safe: incoming seq is beyond our event log
            self.Info.requestLogApplied[actor] = incomingSeq
        else
            -- REJECT: Would mark our local events as "already applied"
            -- Keep local value so replay will process our events
        end
    end
end
```

**Example:**
- Local: event log has Galdof seq 41, 42 (maxLocal = 42)
- Local: `requestLogApplied[Galdof] = 40`
- Incoming: `requestLogApplied[Galdof] = 42`
- Decision: **Reject** (42 <= 42, would skip our local seq 41 and 42)
- Result: Keep local value 40, replay processes 41 & 42, requests stay visible ✅

### Replay Log Entries

**When:** After applying snapshot, or on load if validation detects inconsistency

```lua
function Guild:ReplayRequestLogEntries()
    for actor, entries in pairs(self.requestLogByActor) do
        local appliedSeq = self.Info.requestLogApplied[actor] or 0

        for _, entry in ipairs(entries) do
            if entry.seq <= appliedSeq then
                -- Skip: already applied
            else
                -- Apply entry to snapshot
                self:ApplyRequestLogEntry(entry)
                -- Update tracking
                self.Info.requestLogApplied[actor] = entry.seq
            end
        end
    end
end
```

### Snapshot Merging (NOT Replacement)

When receiving a snapshot, we **merge** instead of replacing:

```lua
-- Index incoming and local by request ID
local incomingMap = {}
for _, req in ipairs(incomingSnapshot.requests) do
    incomingMap[req.id] = req
end

local localMap = {}
for _, req in ipairs(self.Info.requests) do
    localMap[req.id] = req
end

-- Merge: take all incoming
for id, incomingReq in pairs(incomingMap) do
    if localMap[id] then
        -- Both have it - take newer timestamp
        if incomingReq.updatedAt >= localMap[id].updatedAt then
            mergedRequests[id] = incomingReq
        else
            mergedRequests[id] = localMap[id]
        end
    else
        -- Only incoming has it - accept
        mergedRequests[id] = incomingReq
    end
end

-- Keep local requests that incoming doesn't have (unless tombstoned)
for id, localReq in pairs(localMap) do
    if not incomingMap[id] then
        if not tombstones[id] then
            -- No tombstone - keep our local request (protect from data loss)
            mergedRequests[id] = localReq
        end
    end
end
```

---

## Debugging the Persistence Issue

You mentioned that data builds up during syncing but disappears after `/reload` or logout/login. Let's trace through what should happen:

### What SHOULD Happen

1. **During Session:**
   - Sync arrives → `ApplyRequestSnapshot()` modifies `self.Info.requestLogApplied`
   - `self.Info` points to `TOGBankClassic_Database.db.faction[guildName]`
   - This is the AceDB-backed table that auto-saves

2. **On Logout:**
   - WoW calls `PLAYER_LOGOUT` event
   - AceDB automatically writes all dirty tables to SavedVariables file
   - File location: `WTF\Account\<account>\SavedVariables\TOGBankClassic.lua`

3. **On Next Login:**
   - AceDB loads SavedVariables
   - `Database:Load()` returns reference to loaded data
   - `self.Info = Database:Load()` points to the persisted data
   - Data should still be there!

### Potential Issues

#### Issue 1: Data Not Being Modified Correctly

Check if `self.Info` is actually pointing to the right table:

```lua
-- In RequestLog.lua, add debug:
TOGBankClassic_Output:Debug("SYNC", "self.Info reference: %s", tostring(self.Info))
TOGBankClassic_Output:Debug("SYNC", "Database table: %s", tostring(TOGBankClassic_Database.db.faction[guildName]))
TOGBankClassic_Output:Debug("SYNC", "Are they the same? %s", tostring(self.Info == TOGBankClassic_Database.db.faction[guildName]))
```

#### Issue 2: AceDB Not Detecting Changes

AceDB should auto-detect table modifications, but if there's a bug, we can force a save:

```lua
-- After modifying requestLogApplied:
TOGBankClassic_Database.db:MarkChanged()  -- Force dirty flag
```

#### Issue 3: Validation Clearing Data on Load

Check if the REPLAY-001 validation is wiping `requestLogApplied` on every load:

```lua
-- In EnsureRequestsInitialized(), check debug output:
TOGBankClassic_Output:Debug("SYNC", "Before validation: requestLogApplied has %d actors",
    countKeys(self.Info.requestLogApplied))
-- ... validation code ...
TOGBankClassic_Output:Debug("SYNC", "After validation: requestLogApplied has %d actors",
    countKeys(self.Info.requestLogApplied))
```

#### Issue 4: Empty Event Log After Replay

If the event log (`self.Info.requestLog`) is being cleared after replay, then on next load there's nothing to replay:

```lua
-- Check if requestLog persists:
TOGBankClassic_Output:Debug("SYNC", "requestLog has %d entries", #(self.Info.requestLog or {}))
```

### Diagnostic Commands

Add to chat commands or run via `/script`:

```lua
-- Check current state:
/script local G = TOGBankClassic_Guild; print("requests:", #(G.Info.requests or {}), "log:", #(G.Info.requestLog or {}), "applied:", G.Info.requestLogApplied and next(G.Info.requestLogApplied) and "yes" or "no")

-- Force save:
/script TOGBankClassic_Database.db:MarkChanged(); print("Forced database save")

-- Dump requestLogApplied:
/script for k,v in pairs(TOGBankClassic_Guild.Info.requestLogApplied or {}) do print(k, v) end
```

---

## Summary

The request system uses event sourcing with these key principles:

1. **Event log is source of truth** - `requestLog` contains complete history
2. **Snapshot is derived** - `requests` array is built from event log via replay
3. **Applied tracking prevents duplicates** - `requestLogApplied` marks which events have been applied
4. **Smart-merge protects local events** - SYNC-001 fix prevents incoming snapshots from skipping local events
5. **Automatic persistence** - All `self.Info.*` changes auto-save via AceDB

The data **should** persist across reloads because `self.Info` directly references the AceDB-backed SavedVariables table. If it's not persisting, the issue is likely:
- Validation clearing `requestLogApplied` on every load (check REPLAY-001 logic)
- Event log not persisting (check if `requestLog` is empty after reload)
- AceDB not detecting table modifications (add explicit `MarkChanged()` call)

Next step: Add debug logging to trace what happens to `requestLogApplied` between logout and next login.

---

> **NOTE:** The sections above describe the old event-log/sequence architecture (pre-v0.9.0).
> The current implementation uses a simpler LWW (last-writer-wins) delta model with tombstones.
> See `RequestLog.lua` and the findings below for the current design.

---

## Known Issues & Findings (March 2026 Audit)

The following issues were identified during a code review of the current request sync system
(`RequestLog.lua`, `Chat.lua`, `Constants.lua`). They are listed in priority order.
Address one at a time; mark each as Fixed when resolved.

---

### REQSYNC-001 — No authorization check on received mutations ✅ Fixed

**Severity:** High
**Location:** `RequestLog.lua` → `ApplyRequestMutation`

`ReceiveRequestMutations` → `ApplyRequestMutation` applies incoming `cancel`, `complete`,
`delete`, and `fulfill` operations without verifying the sender had permission to perform them.

The local mutation functions (`CancelRequest`, `CompleteRequest`, `DeleteRequest`) all gate on
`CanCancelRequest`, `CanCompleteRequest`, and `CanDeleteRequest` respectively, but those checks
are bypassed entirely when the mutation arrives over the wire.

Since WoW's addon API guarantees the `sender` field in `OnCommReceived` reflects the true sending
character, proper role checks are enforceable:
- `cancel` should require `CanCancelRequest(req, sender)`.
- `complete` should require `CanCompleteRequest(req, sender)`.
- `delete` should require `CanDeleteRequest(req, sender)`.
- `fulfill` should require the sender to be the assigned bank (`req.bank == normSender`) or a GM.

**Impact:** Any guild member can broadcast a crafted `requests-log` message to delete, cancel, or
complete any open request on every peer's client simultaneously.

---

### REQSYNC-002 — Tombstones accepted from any sender in snapshot/index merges ❌ Open

**Severity:** High
**Location:** `RequestLog.lua` → `ApplyRequestSnapshot`, `ReceiveRequestsIndex`

Both functions unconditionally merge tombstones from the incoming payload with no check on whether
the sender was authorized to delete those requests. A guild member can send a crafted snapshot or
index response with a high-timestamp tombstone for any request ID, causing every peer to silently
delete it and block resurrection for 30 days.

**Fix:** Gate tombstone acceptance on `IsBank(sender)` or `SenderIsGM(sender)`. Tombstones from
unprivileged senders should be ignored (or at most accepted only for requests where
`req.requester == sender`).

---

### REQSYNC-003 — `inFlight` stalls next sync cycle when all peers match hash ❌ Open

**Severity:** Low / UX
**Location:** `RequestLog.lua` → `CanQueryRequestsIndex` / `BeginRequestsIndexSync`

When `QueryRequestsIndex(nil)` broadcasts and every peer already has a matching hash (SYNC-011
causes them all to stay silent), `EndRequestsIndexSync` is never called. `inFlight` remains set
for the full `INDEX_INFLIGHT_TIMEOUT` (30 s) before expiring, and `INDEX_QUERY_COOLDOWN` (60 s)
starts from broadcast time, so the next query is effectively blocked for up to 90 seconds even
though nothing was wrong.

**Fix:** After broadcasting, schedule a short timer (e.g., 5 s) to optimistically clear `inFlight`
if no `requests-index` response has arrived, since silence means everyone agreed.

---

### REQSYNC-004 — Double `PruneRequests` call in `ApplyRequestSnapshot` ❌ Open

**Severity:** Low / Performance
**Location:** `RequestLog.lua` → `ApplyRequestSnapshot`

`ApplyRequestSnapshot` calls `NormalizeRequestList()` (which itself calls `PruneRequests` at the
end), then immediately calls `PruneRequests()` again explicitly. Requests are pruned twice on every
incoming snapshot merge — harmless but wasteful on large request maps.

**Fix:** Remove the redundant explicit `PruneRequests()` call from `ApplyRequestSnapshot` since
`NormalizeRequestList` already invokes it.

---

### REQSYNC-005 — Fragile ID-vs-item-name validation in `sanitizeRequest` ❌ Open

**Severity:** Medium
**Location:** `RequestLog.lua` → `sanitizeRequest` (lines ~100–125)

The heuristic that extracts an item name from the request ID (split on `-`, skip parts that look
like timestamps, compare against `req.item`) will produce false mismatches for:
- Item names containing dashes (e.g., "Two-Handed Sword", "Long-Barreled Musket").
- Item names where a segment is short (<=3 chars) and triggers the early-stop rule.

When a mismatch fires, the incoming request is silently dropped with only a debug log. This causes
remote requests to disappear on receive without any visible error.

**Fix options (discuss before changing):**
1. Harden: use a stricter ID format (store item name in the ID as a hash rather than verbatim text).
2. Soften: remove the cross-check entirely since it only guards against hand-edited IDs and harms
   legitimate data more than it helps.
3. Narrow: only apply the check to locally originated IDs (skip for received-over-wire data).

---

### REQSYNC-006 — Same-second fulfill timestamp collision ❌ Open

**Severity:** Low
**Location:** `RequestLog.lua` → `FulfillRequest`

`FulfillRequest` stamps all mutations with `now = GetServerTime()` (1-second precision). If two
fill events fire within the same second (e.g., banker quickly fills two items from different bag
slots), both mutations get the same `ts`. The `req.statusUpdatedAt` could collide if the first fill
triggers a status change to `"fulfilled"`, causing the second mutation to be considered a no-op by
the terminal-state guards in `mergeRequest`.

**Fix:** Bump `now` by 1 for each successive mutation in the same `FulfillRequest` call loop so
rapid same-second fills each get a unique timestamp.

---

### REQSYNC-007 — Index sync constants left at "quick testing" values ❌ Open

**Severity:** Low / Configuration
**Location:** `Constants.lua` → `REQUESTS_SYNC` table

Both constants carry the comment `-- NOTE: Short values for quick testing; production values
should be higher`:

```lua
INDEX_QUERY_COOLDOWN  = 60   -- seconds between index queries
INDEX_INFLIGHT_TIMEOUT = 30  -- seconds before in-flight sync is considered stale
```

These are currently the live production values. Decide the appropriate production numbers and
remove or update the comment.
