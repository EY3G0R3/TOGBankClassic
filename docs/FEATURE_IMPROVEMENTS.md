# TOGBankClassic - Feature Improvements

**Development Note:** Use GitKraken for pushing updates to repository.

## Features
- [ ] Move filled/completed orders to an archive tab
- [ ] Add mouseover tooltip for truncated item names to show full text
- [ ] Single-click button to fulfill request and send mail with all/some items (bulk mail addon?), possibly a popup to select quantity then fill?
- [x] ~~Optimize bank data sync communications for efficiency/speed~~ **v0.7.0: Snapshot-based delta sync implemented**
- [x] ~~**v0.8.0: Pull-based delta protocol** - Further optimization with handshake-based sync~~ **CLOSED**
- [ ] Display items in mail with indicator/tag showing they're in mail (not bags/bank)
- [x] ~~Implement BigWigs package manager support~~ **CLOSED**
- [x] ~~Implement version check (notify users of outdated addon)~~ **CLOSED**
- [ ] **Order fulfillment notification** - Make it more apparent to the user when their order has been filled (e.g., sound alert, chat message, visual indicator on UI)
- [ ] **Communications buffer/queue on banker side** - Investigate if whispers are being dropped during high traffic; implement queue system to ensure all requests are processed
- [ ] **Real-time inventory scanning** - Monitor BAG_UPDATE and PLAYERBANKSLOTS_CHANGED events instead of only scanning on window close; add debouncing (500ms) to prevent spam during rapid changes; current behavior requires closing bank/mail/trade windows to update cached data
- [ ] **Banker ownership display** - Show which player/account owns each banker character to help identify who controls guild bank alts; useful for multi-person guild bank management and tracking
- [ ] **Debug category filtering** - Add category-based debug logging to filter spam; enable/disable specific categories (ROSTER, COMMS, DELTA, SYNC, CACHE, WHISPER, REQUESTS, UI, PROTOCOL) via slash commands; reduces debug noise when troubleshooting specific issues
- [x] ~~**Persistent debug logging**~~ **v0.7.11: Implemented with 50k entry buffer, 7-day retention, filtering**
- [x] ~~**SplitContainerItem popup for order fulfillment**~~ **IMPLEMENTED: Shows confirmation popup with shovel icon when split needed; smart bin-packing algorithm for optimal stack selection; supports complex partial fulfillment scenarios**
- [x] ~~**Mute warning messages**~~ **IMPLEMENTED: Checkbox in options to hide [WARN] messages like DATA-004/DATA-005 rejections; reduces day-to-day chat spam for non-debugging users**
- [x] ~~**Guild-wide request percentage limits**~~ **IMPLEMENTED: Officers can configure max request amount as percentage of available inventory (1-100%); setting syncs guild-wide; protects single items (gear) by always allowing at least 1 if available**
- [ ] **Bagnon-style item highlighting** - Implement visual highlighting system that greys out all items except those needed to fulfill active orders; works across player bags and bank; helps bankers quickly locate and gather items for order fulfillment
- [ ] **Deprecate legacy protocols** - Phase out togbank-v (non-delta), togbank-dv (pre-SYNC-006), and separate bank/bags structures in favor of unified togbank-dv2 (SYNC-006+) with `alt.items` aggregate; includes removing 5-second dv/dv2 prioritization delay once all clients upgraded; currently maintained for backward compatibility with pre-SYNC-006 clients; plan 3-phase deprecation after 3-6 months of adoption
- [x] ~~**Window position reset command**~~ **IMPLEMENTED: /togbank wipeframes to clear saved positions**
- [x] ~~**/togbank deltastats redesign**~~ **IMPLEMENTED: Meaningful P2P telemetry with outbound/inbound/P2P/health/savings sections (STATS-001/002/003)**

---

## 🪟 Window Position Reset Command - IMPLEMENTED

**Added:** February 20, 2026
**Purpose:** Provide easy recovery when addon windows become positioned off-screen or incorrectly placed

### Problem
- Window positions are persisted in SavedVariables per-character
- Windows can become stuck off-screen after resolution changes, monitor disconnection, or UI bugs
- No easy way to reset positions without manually editing SavedVariables files
- Users have to delete SavedVariables or manually edit TOGBankClassicOptionDB to recover

### Solution
New `/togbank wipeframes` command:
- Clears all saved window positions from `TOGBankClassicOptionDB`
- Preserves all other addon data (inventory, requests, settings)
- Reports how many positions were cleared
- Requires `/reload` for changes to take effect
- Windows return to default positions after reload

### Implementation Details
- **Storage:** Window positions stored in `TOGBankClassic_Options.db.char.framePositions`
- **Scope:** Per-character data (each character maintains own window positions)
- **Not affected by:** `/togbank wipe` or `/togbank wipeall` (those only reset guild bank data)
- **Command location:** Expert commands section (alphabetically between wipeall and debug commands)

### Usage
```lua
/togbank wipeframes
-- Output: "Cleared 3 saved window position(s). Type /reload to reset window positions."
/reload
-- Windows now appear at default positions
```

### Technical Notes
- Counts existing positions before clearing for user feedback
- Handles missing or uninitialized framePositions table gracefully
- Uses AceGUI-3.0 `SetStatusTable()` system for position persistence
- Affects Inventory, Search, and Requests windows

---

## ✂️ Automatic Stack Splitting for Order Fulfillment - IMPLEMENTED

**Added:** January 24, 2026
**Purpose:** Eliminate manual stack splitting when fulfilling guild bank orders with oversized stacks

### Problem
- Bankers must manually split stacks when order quantity doesn't match stack sizes
- Example: Request for 2 Felcloth, but only have 5-stack requires manual right-click split
- Complex scenarios (175 Runecloth from mixed stacks) require multiple manual splits
- Time-consuming and error-prone process

### Solution
Automatic stack splitting with confirmation popup:
- **Split Detection:** Detects when stacks are too large for requested quantity
- **Confirmation Dialog:** Shows popup with exact split amount (e.g., "Split 2 from stack of 5 Felcloth?")
- **Icon Indication:** Fulfill button shows shovel icon (🛠️) when split needed, envelope (✉️) when ready to mail
- **Smart Bin-Packing:** Optimizes which stacks to use/skip for best fit (e.g., skip 7-stack to use 2+13+160=175)
- **Two-Step Workflow:** (1) Click shovel → split to inventory, (2) Click envelope → attach all items

### Implementation Details

**Visual Indicators:**
- 🛠️ Shovel icon = Split needed before mailing
- ✉️ Envelope icon = Ready to attach items
- Button stays enabled during split workflow

**Algorithm:**
1. **First Pass (Greedy):** Try smallest-first stack selection
2. **Optimization Pass:** If not exact match, try skipping individual stacks to find optimal fit
3. **Split Decision:** Show popup if no exact combination found
4. **Attachment:** Use optimized stack selection, skip identified stacks for best fit

**Example Scenarios:**

*Simple Split:*
- Request: 2 Felcloth
- Inventory: 1×5 stack
- Action: Split 2 from 5-stack → Attach 2

*Complex Partial Fulfillment:*
- Request: 175 Runecloth
- Inventory: 1×2, 1×7, 1×13, 8×20 (total 262)
- Greedy would give: 2+7+13+7×20 = 162 (needs another split)
- Optimized: Skip 7-stack → 2+13+8×20 = 175 exactly!

### User Experience
1. Click fulfill button (shovel icon appears if split needed)
2. Popup asks: "Split 13 from stack of 20 Runecloth?"
3. Click "Split" → items split to empty bag slot
4. Icon changes to envelope automatically
5. Click envelope → all 175 items attach to mail
6. Click Send → order complete

### Technical Notes
- Uses `C_Container.SplitContainerItem()` with empty bag slot commitment
- Bin-packing tries up to 5 skip combinations for optimal fit
- Sorts stacks smallest-first for greedy baseline
- BAG_UPDATE event triggers UI refresh after split

---

## 🐛 Persistent Debug Logging (v0.7.11) - IMPLEMENTED

**Added:** January 23, 2026
**Purpose:** Capture complete debug history across sessions for troubleshooting intermittent issues

### Problem
- Chat frame debug logs are limited and lost on `/reload`
- Can only see current session snapshot (~1000 messages)
- Intermittent issues (like UI-003) require tracking 10,000s of messages over time
- No way to review complete debug history when issues manifest

### Solution
All DEBUG-level messages are captured to memory with timestamps and persisted to SavedVariables on logout.

### Configuration
- **Max Entries:** 50,000 (circular buffer)
- **Max Age:** 7 days (auto-cleanup)
- **Storage:** `TOGBankClassicDB_DebugLog` SavedVariable
- **Memory Impact:** ~5-10 MB in-game (negligible)
- **Disk Size:** ~5-15 MB SavedVariables file
- **Coverage:** Several hours to days of detailed debug logging

### Slash Commands

#### `/togbank debuglog [N] [filter]`
Export last N entries (default 500), optionally filtered by keyword.

**Examples:**
```
/togbank debuglog 50000                   # ALL entries (up to max)
/togbank debuglog 10000 anumbnutz         # Last 10k mentioning player
/togbank debuglog 5000 cancel             # Last 5k with "cancel"
/togbank debuglog 20000 request           # Last 20k about requests
```

Output format (compact for large logs):
```
14:20:15 TOGBankClassic: [DEBUG] < togbank-d Share: delta from Anumbnutz
14:21:42 TOGBankClassic: [DEBUG] > Anumbnutz shares delta (567 bytes)
14:22:18 TOGBankClassic: [DEBUG] Delta applied: v1234 -> v1235
```

#### `/togbank debuglogstats`
Show log statistics: entry count, oldest/newest timestamps, time span, configuration.

```
Debug log: 23,847 entries
Oldest: 2026-01-23 08:15:32
Newest: 2026-01-23 14:22:18
Span: 0.3 days
Max entries: 50,000
Max age: 7 days
```

#### `/togbank debuglogsave`
Manually save to SavedVariables (normally automatic on logout).

#### `/togbank debuglogclear`
Clear all persistent log entries.

### Workflow

---

## 🎯 Guild-Wide Request Percentage Limits - IMPLEMENTED

**Added:** February 2, 2026
**Purpose:** Allow officers to centrally configure request limits that automatically sync to all guild members

### Problem
- Requests exceeding available inventory create unfillable orders
- No way to distribute limited resources fairly among multiple requesters
- Bankers forced to manually adjust requests or explain limitations via whisper
- Officers need centralized control over request behavior guild-wide

### Solution
Officers can configure maximum request amount as percentage of available inventory (1-100%):
- **Guild-Wide Sync:** Setting stored in guild data structure, automatically propagates to all clients
- **Officer-Only Configuration:** "Requests" tab in options visible only to officers (CanViewOfficerNote)
- **Percentage-Based Clamping:** `maxAllowed = floor(available × percentage ÷ 100)`
- **Single Item Protection:** Always allows requesting at least 1 item if available (protects gear/weapons)
- **Clear User Feedback:** Shows "Available: 100 (Max: 50% = 50)" when percentage < 100%

### Implementation Details

**Storage & Sync:**
- Settings stored in `Guild.Info.settings.maxRequestPercent` (default: 100%)
- Syncs via existing request protocol (`togbank-d` / `SendRequestsData()`)
- Falls back to local setting if guild data not yet loaded
- Persists across `/reload`, logout, and client sessions

**User Experience:**
- **For Officers:**
  - Open Options → Requests tab
  - Slider: 1% to 100% (default: 100%)
  - Change broadcasts immediately to all online guild members
  - Info message: "Maximum request amount set to 50% (syncing to guild...)"

- **For Members:**
  - Request slider max automatically capped at configured percentage
  - Status text shows: "Available: 200 (Max: 50% = 100)"
  - Validation message if exceeding: "Reduced to max allowed: 50 items (50% of 100 available)"
  - No access to Requests tab or configuration

**Example Scenarios:**

*Fair Resource Distribution:*
- Guild has 100 Mooncloth, 3 members want some
- Officer sets 50% limit
- Each member can request max 50 (or less if stock depletes)
- Prevents one person claiming entire stock

*Single Item Protection:*
- Guild has 1 Thunderfury (yes, really)
- Officer has 25% limit configured
- Calculation: floor(1 × 25 ÷ 100) = 0
- Protection: `math.max(1, 0)` → 1 item requestable
- Member can still request the legendary weapon

*Dynamic Updates:*
- Officer changes 100% → 50% during raid prep
- All online members' request dialogs update immediately
- Existing requests unaffected, new requests use new limit
- Setting persists for offline members when they log in

### Technical Notes
- Reads from `Guild.Info.settings.maxRequestPercent` first, local DB as fallback
- Slider set function writes to both guild structure and local DB (backup)
- Calls `SendRequestsData()` to broadcast via existing request sync protocol
- Applied in Search.lua slider setup (line 119-139) and validation (line 182-207)
- Access control via `hidden = function() return not CanViewOfficerNote() end`

### Configuration
**Options → Requests (Officers Only)**
- Maximum Request Amount: 1% - 100% slider
- Example Calculations group shows gear vs stackable examples
- Real-time preview of how percentage affects different item quantities

1. Enable debug logging: `/togbank debug`
2. Reproduce the issue during gameplay (logs 50k entries automatically)
3. Logout or: `/togbank debuglogsave`
4. Filter and view: `/togbank debuglog 10000 anumbnutz`
5. Check stats: `/togbank debuglogstats`
6. Access raw file: `WTF/Account/<Account>/SavedVariables/TOGBankClassic.lua`

### Key Features

- **Automatic capture:** All DEBUG messages logged with timestamps
- **Circular buffer:** Maintains most recent 50,000 entries
- **Age-based cleanup:** Removes entries older than 7 days
- **Keyword filtering:** Quickly find relevant entries in large logs
- **Compact format:** Reduces chat spam when viewing thousands of entries
- **Zero gameplay impact:** Memory operations only, SavedVariables write on logout
- **Persistent across /reload:** Complete history maintained

### Use Cases

- **Intermittent bugs:** Capture complete timeline leading to issue (UI-003, message delivery)
- **Player-specific issues:** Filter by player name to track their interactions
- **Message flow debugging:** Track request/cancel/fulfill message sequences
- **Version mismatch tracking:** Review communication between different addon versions
- **Performance analysis:** Review delta sync timing and bandwidth usage

---

## � Centralized WHISPER Management (v0.7.11) - IMPLEMENTED

**Added:** January 23, 2026
**Purpose:** Consolidate all WHISPER communication with automatic online checking

### Problem
- WHISPER sends scattered across 7+ locations in codebase
- Manual online checks required before each send (easy to forget)
- Inconsistent error handling and logging
- "No player named X is currently playing" errors when sending to offline players
- High maintenance burden - every WHISPER location needs identical logic

### Solution
Created centralized `SendWhisper()` wrapper in Core.lua with built-in online checking.

### Implementation

**Core.lua - New Function:**
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

### Migration

Replaced all direct WHISPER sends (7 locations):

**Before:**
```lua
-- Manual check required (easy to forget)
if not TOGBankClassic_Guild:IsPlayerOnline(sender) then
    TOGBankClassic_Output:Debug("Cannot send to %s - offline", sender)
    return
end
TOGBankClassic_Core:SendCommMessage("togbank-rr", data, "WHISPER", sender, "NORMAL")
```

**After:**
```lua
-- Automatic online checking
if not TOGBankClassic_Core:SendWhisper("togbank-rr", data, sender, "NORMAL") then
    return
end
```

**Locations Updated:**
1. Chat.lua: togbank-rr ACK replies
2. Chat.lua: togbank-dc delta chain responses
3. Guild.lua: togbank-state state summaries
4. Guild.lua: togbank-nochange no-change replies (2 locations)
5. Guild.lua: togbank-r pull-based queries
6. Guild.lua: togbank-dr delta range requests

### Benefits

- ✅ **Single maintenance point:** All WHISPER logic in one place
- ✅ **Automatic safety:** Impossible to forget online checks
- ✅ **Consistent behavior:** Uniform error handling across codebase
- ✅ **Return value:** `true`/`false` indicates send success
- ✅ **Cleaner code:** Reduced from 10+ lines to 3 lines per call
- ✅ **Zero errors:** Eliminates all "player not online" error messages
- ✅ **Future-proof:** New WHISPER sends automatically get protection

### Impact

- Code reduction: 36 lines removed, 30 lines added (net -6 lines)
- Maintainability: All future WHISPER sends automatically safe
- Reliability: Eliminates entire class of communication errors
- Developer experience: Simple, consistent API for WHISPER sends

---

## 🔄 Request Data Sync (v0.7.11) - IMPLEMENTED
**Fixed:** [SYNC-002] - Pass player name to queries, remove player check for guild-wide data

## 🎨 Persistent Tab Selection (v0.7.11) - IMPLEMENTED
**Fixed:** [UI-004] - Preserve selected tab across syncs and redraws

---

## �🔄 Pull-Based Delta Protocol (v0.8.0) - PLANNED

### Overview
Replace v0.7.0's snapshot-based delta sync with a pull-based handshake protocol for greater simplicity and efficiency.

**Key Improvements over v0.7.0:**
- No snapshots to maintain (eliminates deltaSnapshots table)
- No version mismatch errors (receiver explicitly states what they have)
- No chain replay complexity (sender computes custom delta)
- Massive bandwidth savings (remove Links, baseVersion, unnecessary data)
- Simpler logic (7-step flow, clear rules)

### Core Philosophy
- Receiver states what they have, sender computes the diff
- If receiver has NO data → send everything
- If receiver has SOME data → ALWAYS send delta
- No thresholds, no size checks, no fallbacks, no stupid rules

### Protocol Flow (7 Steps)

1. **Banker announces presence**
   - Channel: GUILD
   - Message: `togbank-dv`
   - Content: "I'm the banker, I'm online"

2. **Non-banker requests data**
   - Channel: WHISPER (if banker known) or GUILD (if banker unknown)
   - Message: `togbank-r`
   - Content: "I need data for alt X"

3. **Responder acknowledges**
   - Channel: WHISPER
   - Message: `togbank-rr` (NEW)
   - Content: `{ isBanker = true/false }` - identifies authority
   - Purpose: "I can help, send me your state"

4. **Non-banker sends state summary**
   - Channel: WHISPER
   - Message: `togbank-state` (NEW)
   - Content: `{[itemID] = quantity}` - minimal state, no Links/bags/slots
   - Size: ~800 bytes for 100 items

5. **Responder computes response**
   - Logic:
     - If state is empty → full sync
     - If state matches current → no-change
     - Otherwise → compute delta from stated version to current

6. **Responder sends data**
   - Channel: GUILD
   - Messages: `togbank-d` (full), `togbank-d2` (delta), or `togbank-nochange` (WHISPER)
   - Optimization: No Links (60-80 bytes/item saved), no baseVersion (8 bytes saved)

7. **Receiver applies data**
   - Applies changes to local database
   - **Reconstructs Links locally:** Calls `GetItemInfo(itemID)` for each item
   - **Stores Links in database:** For UI display and functionality

### Message Optimizations

#### 1. Remove Links from Transmission (5-7KB savings)
**Problem:** v0.7.0 sends full Link strings with every item
```lua
-- v0.7.0 (HEAVY):
{ ID = 12345, Count = 5, Link = "|cff9d9d9d|Hitem:2589:0:0:0:0:0:0:0:20:0:0|h[Linen Cloth]|h|r" }
```

**Solution:** Send only ID/Count, receiver reconstructs
```lua
-- v0.8.0 (LIGHT):
{ ID = 12345, Count = 5 }  -- Receiver calls GetItemInfo(12345)
```

**Reconstruction:**
```lua
function ReconstructItemLinks(items)
  for _, item in ipairs(items) do
    local itemLink = select(2, GetItemInfo(item.ID))
    item.Link = itemLink  -- Store for UI display
  end
end
```

**Trade-off:** One API call per item vs. 60-80 bytes per item transmission
**Result:** 5-7KB bandwidth savings per sync (typical 100-item alt)

#### 2. Remove baseVersion (8 bytes saved)
**v0.7.0:** Delta includes `baseVersion` to identify what it's built against
```lua
{ type = "alt-delta", version = 110, baseVersion = 100, changes = {...} }
```

**v0.8.0:** Receiver explicitly stated what they have in step 4, baseVersion is redundant
```lua
{ type = "alt-delta", version = 110, changes = {...} }  -- No baseVersion needed
```

#### 3. Minimal Remove Format (4 bytes/item saved)
**v0.7.0:** Remove items include Count and Link
```lua
remove = { { ID = 12345, Count = 5, Link = "|cff..." }, ... }
```

**v0.8.0:** Only send ID (count/link irrelevant for deletion)
```lua
remove = { { ID = 12345 }, { ID = 67890 }, ... }
```

#### 4. State Summary Format
**Purpose:** Receiver tells sender what they have for delta computation
**Format:** `{[itemID] = quantity}` - ID to quantity mapping only
**Size:** ~8 bytes per item = ~800 bytes for 100 items
**Excludes:** Links, bag numbers, slot numbers, metadata

### Channel Assignment

**GUILD Channel (High Volume):**
- togbank-v (version broadcasts)
- togbank-dv (banker announcements)
- togbank-d (full sync data)
- togbank-d2 (delta data)
- togbank-r (query fallback when banker unknown)

**WHISPER Channel (Handshakes Only):**
- togbank-r (query to specific banker)
- togbank-rr (query reply - NEW)
- togbank-state (state summary - NEW)
- togbank-nochange (no-change reply - NEW)

**Rule:** NO DATA SYNC IN WHISPER, ONLY HANDSHAKES

### Version Management (CRITICAL FIX)

**v0.7.0 Problem:** Versions created on logout regardless of changes
```lua
-- Guild.lua:679 (WRONG)
self.Info.alts[norm].version = GetServerTime()  -- Always updates!
```

**v0.8.0 Solution:** Versions ONLY created when inventory actually changes
```lua
-- Only update version if items/money changed
if inventoryChanged then
  self.Info.alts[norm].version = GetServerTime()
end
```

**Version Creation Rules:**
- ✅ Create new version when: Items added/removed/modified, money changed
- ❌ NEVER create version on: Queries, responses, no-change replies, failed requests

**Why:** Prevents version drift where identical data has different versions due to communication events

### Response Prioritization

When multiple guild members respond to a query:

1. **THE BANKER** (always authoritative)
   - `isBanker = true` flag in togbank-rr
   - If banker responds, use their data regardless of version

2. **Highest version** (among non-bankers)
   - If no banker responds, use data from member with newest version

### Startup Optimization

**Discovery Phase:**
- On addon init: Broadcast "is any banker online?"
- Listen for togbank-dv responses
- Build list of online bankers
- Update list as members log in/out

**Smart Routing:**
```lua
if bankerKnownOnline then
  SendCommMessage("togbank-r", data, "WHISPER", bankerName)
else
  SendCommMessage("togbank-r", data, "GUILD")
end
```

### Implementation Checklist

#### Config Flags (User-Selectable)
- [ ] Add protocol selection option to addon config menu
- [ ] `FORCE_LEGACY_PROTOCOL` - Force use of togbank-d/d2 with Links (v0.6.x compatible)
- [ ] `FORCE_NEW_PROTOCOL` - Force use of togbank-d3/d4 without Links (v0.8.0 only)
- [ ] `AUTO_PROTOCOL` (default) - Dual-send both formats for compatibility
- [ ] Display current protocol mode in config UI
- [ ] Show bandwidth savings in config UI when using new protocol

#### New Messages
- [ ] `togbank-rr` - Query reply with `{ isBanker = bool, version = timestamp }`
- [ ] `togbank-state` - State summary `{ items = {[itemID] = count} }`
- [ ] `togbank-nochange` - Explicit no-change response

#### Modified Messages
- [ ] `togbank-d` - Remove Link fields from all items
- [ ] `togbank-d2` - Remove Link fields, remove baseVersion, minimal removes

#### Link Reconstruction
- [ ] `ReconstructItemLinks(items)` - Call GetItemInfo for each item
- [ ] Store reconstructed Links in database after applying delta
- [ ] Handle async loading with `Item:CreateFromItemID()` if needed

#### Version Management
- [ ] Fix version creation to only happen on actual changes
- [ ] Remove version updates from logout event (Guild.lua:679)
- [ ] Track inventory state to detect changes

#### Banker Discovery
- [ ] Implement banker discovery on init
- [ ] Maintain `onlineBankers = {}` table
- [ ] Update from togbank-dv broadcasts
- [ ] Smart routing based on banker availability

#### Remove Old Code
- [ ] Delete deltaSnapshots table and snapshot functions
- [ ] Delete chain replay logic (RequestDeltaChain, ApplyDeltaChain)
- [ ] Delete SEND_FULL_THRESHOLD and size comparison
- [ ] Delete baseVersion from delta structure

---

## v0.7.0 Snapshot-Based Delta Sync (IMPLEMENTED)

### Current Bank Sync Implementation (Detailed Analysis)

**Overview:**
The addon uses WoW's guild chat communication system (AceComm-3.0) to synchronize bank inventory data between guild members. Data is serialized, checksummed, and transmitted in chunks through multiple communication prefixes.

**Communication Prefixes:**
- `togbank-v` - Version broadcasts (lightweight pings every 3 minutes)
- `togbank-d` - Data transfers (alt inventory, roster, requests)
- `togbank-r` - Query requests (asking for specific data)
- `togbank-h` / `togbank-hr` - Hello/Hello Reply (handshake)
- `togbank-s` / `togbank-sr` - Share/Share Reply (manual triggers)
- `togbank-w` / `togbank-wr` - Wipe/Wipe Reply (reset commands)

**Sync Timers:**
- Full roster/alt data sync: Every 10 minutes (600s)
- Lightweight version broadcast: Every 3 minutes (180s)
- Queue retry delay: 5 seconds

**Data Serialization Process:**
1. **Serialization** (Core.lua):
   - Uses AceSerializer-3.0 to convert Lua tables to strings
   - Computes simple additive checksum (31-bit hash) on serialized data
   - Appends checksum using ASCII Record Separator (\030)
   - Format: `<serialized_data>\030<checksum>`

2. **Transmission** (Chat.lua, Guild.lua):
   - Sends via AceComm-3.0 which uses ChatThrottleLib
   - Priority: "BULK" (lowest priority, won't interfere with gameplay)
   - Channel: "Guild" (broadcast to all online guild members)
   - Chunks: ~254 bytes per chunk to stay within WoW API limits
   - Tracks: bytes sent, chunk count, throttle events, failures

3. **Deserialization** (Core.lua):
   - Receives message, finds checksum separator
   - Verifies checksum matches computed hash
   - Falls back to regular deserialize if no checksum (backwards compatibility)
   - Returns success/failure with error messages

**Sync Flow:**

*Bank Character Shares Data:*
1. Timer triggers or manual `/bank share` command
2. Checks if player is marked as bank alt (guild note contains specific marker)
3. Serializes full inventory data:
   - Character name (normalized: Name-Realm format)
   - Money amount
   - Bank items (ID, Count, Link, Info)
   - Bag items (ID, Count, Link, Info)
   - Slot counts (used/total)
   - Version timestamp
4. Calls `SendAltData()` → `SendCommMessage("togbank-d", ...)`
5. ChatThrottleLib chunks and sends data

*Receiving Client:*
1. `OnCommReceived()` intercepts message by prefix
2. Deserializes and validates checksum
3. Authenticates sender:
   - Must be guild member
   - Must have gbank marker in guild note OR be guild master
   - For alt data: restrictive policy checks ownership/authorization
4. Compares version timestamps:
   - `ADOPTED` - newer data, integrate it
   - `STALE` - older data, discard
   - `INVALID` - malformed data, ignore
   - `UNAUTHORIZED` - sender not allowed, ignore
5. If adopted: updates local database, triggers UI refresh

**Version Comparison System:**
- Each alt's data has a `version` field (server timestamp)
- Receiving client checks: `if remote_version > local_version then adopt`
- Conflicts resolved by newest timestamp wins
- Missing version treated as very old (0)

**Query/Response Pattern:**
- Clients send lightweight version broadcasts every 3 minutes
- Includes: player name, addon version, list of known alts with their versions
- Recipients compare versions, send queries for fresher data
- Queries: `SendCommMessage("togbank-r", {type="alt", name="BankAlt-Realm"})`
- Bank character responds by sending full data via `togbank-d`

**Current Inefficiencies:**

1. **Full Data Transmission:**
   - Entire inventory sent every time, even if only 1 item changed
   - No delta/diff system
   - Bank with 200 items = full 200 item array transmitted

2. **Redundant Item Info:**
   - Each item includes full metadata (icon, level, rarity, class, subclass, name)
   - This info rarely changes and could be cached locally
   - Game API can retrieve this from Item IDs

3. **No Compression:**
   - Serialized data is plain text representation of Lua tables
   - No gzip or similar compression before transmission
   - Typical payload: 10-50KB for full bank alt

4. **Broadcast to All:**
   - Every online guild member receives all data
   - No selective targeting based on who needs updates
   - Scales poorly with large guilds

5. **Chunking Overhead:**
   - ChatThrottleLib splits at ~254 bytes per chunk
   - Each chunk has protocol overhead
   - Large inventories = many sequential chunks

6. **Checksum Method:**
   - Simple additive hash (collision-prone)
   - Not cryptographic (spoofing possible if desired)
   - Computes over entire payload (no per-chunk verification)

7. **Queue Management:**
   - Sync queue processes one alt at a time sequentially
   - 5 second retry delay if queue has pending items
   - No parallel processing of independent alts

**Potential Optimizations:**
- Implement delta updates (only send changed items)
- Strip redundant item metadata (send only ID/Count/Link)
- Add LZ compression layer before serialization
- Use differential sync based on last-seen timestamps
- Implement request batching for multiple alts
- Add per-chunk checksums for early error detection
- Cache item metadata locally by ID
- Compress version broadcasts (bit flags instead of full arrays)

### Proposed Optimization Strategies

**High Impact, Medium Effort:**

1. **Delta Updates (Incremental Sync)**
   - Track hash per inventory slot to detect changes
   - Only transmit changed items instead of entire inventory
   - Bandwidth reduction: ~99% for typical updates (200 items, 2 changed)
   - Implementation: Add `lastHash` field per slot, compare before send
   - Requires: Sequence numbers for conflict resolution

2. **Strip Item Metadata**
   - Currently sends: `{ID, Count, Link, Info{icon, level, rarity, equipId, price, class, subClass, name}}`
   - Optimize to: `{ID, Count, Link}` only
   - Client retrieves Info from Item ID via `GetItemInfo()` API
   - Bandwidth reduction: ~60-70% per item
   - Cache API results locally to avoid repeated lookups

3. **Add Compression (LibDeflate)**
   - Integrate LibDeflate library (widely used, proven stable)
   - Compress serialized data before transmission
   - Text data typically compresses 60-80%
   - Apply after serialization, before chunking
   - Format: `<compressed_data>\030<checksum>`

**Medium Impact, Lower Effort:**

4. **Targeted Whispers for Query Responses**
   - Current: All data broadcast to entire guild
   - Optimize: Query responses whispered directly to requester
   - Only broadcast: Initial version pings, roster updates
   - Reduces network spam for all guild members
   - Implementation: Change distribution parameter from "GUILD" to "WHISPER"

5. **Batch Item Updates**
   - Current: Immediate sync on every item change
   - Optimize: Accumulate changes for 2-5 seconds, send batch
   - Reduces multiple small transmissions to one larger
   - Especially useful during bank/mail organization
   - Use timer to flush pending changes

6. **Shared Item Metadata Cache**
   - Build local cache: `ItemInfoCache[itemID] = {icon, level, rarity, ...}`
   - First encounter: Retrieve via API, cache permanently
   - Never transmit cached metadata
   - Cleared only on addon version updates
   - Reduces bandwidth for commonly banked items (cloth, ores, etc.)

**Lower Impact, Good Optimizations:**

7. **Better Checksum Algorithm**
   - Replace simple additive hash with CRC32
   - Available in LibCompress or LibDeflate
   - Smaller output, faster computation, better collision resistance
   - Per-chunk checksums for early error detection
   - Reduces retransmissions due to detected corruption

8. **Incremental Sync Protocol**
   - Add sequence number to each update: `{sequence: 12345, changes: [...]}`
   - Clients track last-seen sequence per alt
   - Query: "Send all changes since sequence X"
   - Eliminates full inventory retransmission on reconnect
   - Requires persistent sequence number storage

9. **Optimized Version Broadcasts**
   - Current: Full table of all alts with timestamps
   - Optimize: Only include alts modified since last broadcast
   - Use bit-packed format for flags (has_bags, has_bank, etc.)
   - Example: `{changed: ["BankAlt1-Realm"], versions: {12345}}`
   - Reduces 3-minute ping size by 80-90%

**Radical Redesign (High Effort, High Reward):**

10. **Event-Driven Updates Only**
    - Remove periodic 10-minute full sync timer
    - Trigger updates only on actual changes:
      - `BANKFRAME_OPENED` / `BANKFRAME_CLOSED`
      - `MAIL_INBOX_UPDATE` / `MAIL_SEND_SUCCESS`
      - `TRADE_CLOSED`
    - Fallback: Manual `/bank share` or login sync
    - Reduces network traffic by 90%+ during idle periods

11. **Subscription Model**
    - Clients specify which bank alts they care about
    - Bank alts only send to subscribers
    - Reduces broadcasts for large guilds with many banks
    - Protocol: `{type: "subscribe", alts: ["BankAlt1", "BankAlt2"]}`
    - Timeout: Auto-unsubscribe after 30 minutes offline

12. **Progressive Update Strategy**
    - Priority 1: Send item counts and IDs (fast, small)
    - Priority 2: Send full item links (slower, larger)
    - Priority 3: Send metadata for uncached items (slowest)
    - Allows UI to display results immediately, refine later
    - User sees "Loading..." indicators for incomplete data

**Implementation Priority Recommendation:**
1. Start with #2 (Strip Metadata) - Easy win, big impact
2. Add #6 (Item Cache) - Complements #2
3. Implement #3 (Compression) - Mature library, proven
4. Add #1 (Delta Updates) - Complex but massive savings
5. Consider #10 (Event-Driven) - Requires careful testing

---

## Delta Updates Implementation Plan

### Strategy: Dual Protocol with Version Detection

**Objective:** Implement delta updates without breaking compatibility with older addon versions. Use a phased rollout approach that allows coexistence of old and new sync protocols.

### Architecture Overview

**Phase 1: Add New Delta Protocol (v0.7.0)**
- Introduce new comm prefix `togbank-d2` for delta updates
- Maintain existing `togbank-d` for full data transfers (backwards compatibility)
- Add protocol version negotiation in version broadcasts
- Implement automatic protocol selection based on peer capabilities

**Phase 2: Coexistence Period (v0.7.x - v0.8.x)**
- Both protocols operate simultaneously
- New clients speak both protocols (send delta to v0.7+ clients, full to older)
- Old clients ignore `togbank-d2` messages, continue using `togbank-d`
- Monitor adoption rates via version broadcasts
- Gather metrics on bandwidth savings

**Phase 3: Deprecation (v0.9.0+, Optional)**
- After sufficient adoption (>80% of guild online users)
- Add deprecation warnings for old protocol in UI
- Remove `togbank-d` full sync in v1.0.0 (breaking change)

### Technical Implementation

#### 1. Protocol Version Constants
```lua
-- Modules/Constants.lua
PROTOCOL_VERSION = 2  -- Bump for breaking changes
SUPPORTS_DELTA = true
MIN_DELTA_SIZE_RATIO = 0.3  -- Only use delta if <30% of full size
```

#### 2. Enhanced Version Broadcast
```lua
-- togbank-v message structure
{
    player = "PlayerName-Realm",
    addon_version = "0.7.0",
    protocol_version = 2,        -- NEW: Protocol capability
    supports_delta = true,       -- NEW: Delta support flag
    alts = {["BankAlt-Realm"] = 1234567890, ...},
    requests = 42,
    requestLog = {...}
}
```

#### 3. Delta Data Structure
```lua
-- v0.8.0 togbank-d4 message format (link-less)
{
    type = "alt-delta",
    name = "BankAlt-Realm",
    version = 1234567900,           -- New version timestamp
    updatedAt = 1234567900,         -- Inventory update timestamp
    inventoryHash = 123456789,      -- Inventory hash for validation
    changes = {
        money = 50000,              -- New total (if changed)
        mailHash = 987654,          -- Mail hash (if changed)
        bank = {
            added = {               -- New items (ID + Count, link-less)
                {ID=123, Count=10},
                {ID=456, Count=5}
            },
            modified = {            -- Changed items (ID + Count)
                {ID=789, Count=15},
                {ID=234, Count=2}
            },
            removed = {             -- Removed items (ID only)
                {ID=567},
                {ID=890}
            }
        },
        bags = {
            added = {...},
            modified = {...},
            removed = {...}
        },
        mail = {
            added = {...},
            modified = {...},
            removed = {...}
        }
    }
}

-- Note: bank, bags, and mail are sent as SEPARATE inventories
-- Receiver populates current.bank.items, current.bags.items, current.mail.items individually
-- Aggregated current.items is recalculated after delta application for UI display
-- Link-less protocol: Links removed for bandwidth savings (except gear via NeedsLink())
-- baseVersion removed in v0.8.0 (pull-based protocol renders it redundant)
```

#### 4. Peer Capability Detection
```lua
-- Track guild member protocol versions
guild_protocol_versions = {
    ["Player1-Realm"] = {version = 2, supports_delta = true},
    ["Player2-Realm"] = {version = 1, supports_delta = false},
    ...
}

-- Decision logic: Use delta if >50% of online guild supports it
function ShouldUseDelta()
    local total, supports = 0, 0
    for _, info in pairs(guild_protocol_versions) do
        total = total + 1
        if info.supports_delta then
            supports = supports + 1
        end
    end
    return supports / total > 0.5
end
```

#### 5. Smart Send Logic with Fallback
```lua
function SendAltData(name, force)
    local norm = NormalizeName(name)
    local alt = Info.alts[norm]

    -- Determine which protocol to use
    local useDelta = ShouldUseDelta() and HasPreviousSnapshot(norm)

    if useDelta then
        local delta = ComputeDelta(norm, alt)
        local deltaSize = EstimateSize(delta)
        local fullSize = EstimateSize(alt)

        -- Only use delta if significantly smaller
        if deltaSize < fullSize * MIN_DELTA_SIZE_RATIO then
            SendCommMessage("togbank-d2", Serialize(delta), "Guild")
            SaveSnapshot(norm, alt)  -- Save for next delta
            return
        end
    end

    -- Fallback: Send full data via old protocol
    SendCommMessage("togbank-d", Serialize({type="alt", name=norm, alt=alt}), "Guild")
    SaveSnapshot(norm, alt)  -- Save as baseline for future deltas
end
```

#### 6. Delta Computation Algorithm
```lua
function ComputeDelta(name, currentAlt)
    local previous = GetSnapshot(name)
    if not previous then return nil end

    local delta = {
        type = "alt-delta",
        name = name,
        version = currentAlt.version,
        baseVersion = previous.version,
        changes = {}
    }

    -- Money comparison
    if currentAlt.money ~= previous.money then
        delta.changes.money = currentAlt.money
    end

    -- Bank items delta
    delta.changes.bank = ComputeItemDelta(
        previous.bank.items,
        currentAlt.bank.items
    )

    -- Bag items delta
    delta.changes.bags = ComputeItemDelta(
        previous.bags.items,
        currentAlt.bags.items
    )

    return delta
end

function ComputeItemDelta(oldItems, newItems)
    local added, modified, removed = {}, {}, {}
    local oldBySlot = BuildSlotIndex(oldItems)

    for _, newItem in pairs(newItems) do
        local oldItem = oldBySlot[newItem.slot]
        if not oldItem then
            table.insert(added, newItem)
        elseif not ItemsEqual(oldItem, newItem) then
            table.insert(modified, GetChangedFields(oldItem, newItem))
        end
        oldBySlot[newItem.slot] = nil  -- Mark processed
    end

    -- Remaining slots were removed
    for slot in pairs(oldBySlot) do
        table.insert(removed, slot)
    end

    return {added=added, modified=modified, removed=removed}
end
```

#### 7. Delta Application with Validation
```lua
function ApplyDelta(name, deltaData)
    local norm = NormalizeName(name)
    local current = Info.alts[norm]

    -- Validate base version matches
    if not current or current.version ~= deltaData.baseVersion then
        -- Delta doesn't apply to our state, request full sync
        QueryAlt(nil, norm, nil)
        return ADOPTION_STATUS.INVALID
    end

    -- Apply changes
    if deltaData.changes.money then
        current.money = deltaData.changes.money
    end

    if deltaData.changes.bank then
        ApplyItemDelta(current.bank.items, deltaData.changes.bank)
    end

    if deltaData.changes.bags then
        ApplyItemDelta(current.bags.items, deltaData.changes.bags)
    end

    -- Update version
    current.version = deltaData.version

    -- Save new snapshot for future deltas
    SaveSnapshot(norm, DeepCopy(current))

    -- Trigger UI refresh
    TriggerCallback(DB_UPDATE)

    return ADOPTION_STATUS.ADOPTED
end

function ApplyItemDelta(items, delta)
    -- Remove items
    for _, slot in ipairs(delta.removed) do
        items[slot] = nil
    end

    -- Add new items
    for _, item in ipairs(delta.added) do
        items[item.slot] = item
    end

    -- Modify existing items
    for _, changes in ipairs(delta.modified) do
        local slot = changes.slot
        if items[slot] then
            -- Apply only changed fields
            for key, value in pairs(changes) do
                if key ~= "slot" then
                    items[slot][key] = value
                end
            end
        end
    end
end
```

### Benefits Summary

1. **Zero Breaking Changes**: Old clients continue working with full sync
2. **Automatic Optimization**: Clients detect and use best protocol
3. **Bandwidth Reduction**: 95-99% for typical bank updates (1-5 items changed)
4. **Safety**: Automatic fallback to full sync on delta failure
5. **Gradual Migration**: Guild members update at their pace
6. **Reversible**: Can disable delta if issues arise
7. **Measurable**: Track adoption and bandwidth savings

### Rollout Timeline

- **v0.7.0**: Implement delta protocol, both active
- **v0.7.1**: Bug fixes, optimize delta computation
- **v0.7.2**: Add metrics/logging for bandwidth tracking
- **v0.8.0**: Optimize snapshot storage, add compression
- **v0.9.0**: (Optional) Deprecation warnings for old protocol
- **v1.0.0**: (Optional) Remove old protocol entirely

### Testing Strategy

1. **Unit Tests**: Delta computation accuracy
2. **Integration Tests**: Protocol version negotiation
3. **Live Testing**: Small guild deployment (5-10 members)
4. **Metrics Collection**: Bandwidth usage, delta success rate
5. **Fallback Testing**: Verify full sync on delta failure
6. **Version Mix Testing**: v0.6.8 + v0.7.0 coexistence

---

## 📋 Request Communication System Architecture

### Overview
The request system uses a **full snapshot + operation log** architecture for synchronizing guild bank requests across all players. Unlike the delta-based inventory system, requests use complete snapshots with operation replay for conflict resolution.

**Key Design Principles:**
- **Snapshot-based sync**: Full request list transmitted on sync
- **Operation log**: All changes recorded as discrete log entries
- **Last-writer-wins**: Conflicts resolved by timestamp
- **Tombstones**: Deleted requests tracked to prevent resurrection
- **Merge on receive**: Incoming snapshots merged with local data (not replaced)

### Communication Channels

#### Primary Channels
- **`togbank-r`** (Request): Query for request data (GUILD broadcast)
- **`togbank-rr`** (Request Reply): Acknowledgment of request (WHISPER response)
- **`togbank-d`** (Data): Full snapshots and log entries (GUILD broadcast)

#### Message Types
1. **`requests`** - Full snapshot of all requests
2. **`requests-log`** - Individual log entries for incremental updates

### Data Model (Guild.Info)

```lua
-- Core request storage
requests = {
    {
        id = "Shamanoodles-OldBlanchy-1769171234-123456",  -- Unique ID
        requester = "Shamanoodles-OldBlanchy",             -- Who requested
        bank = "Bagsbagsbags-OldBlanchy",                  -- Target banker
        item = "Silk Bag",                                 -- Item name
        quantity = 4,                                      -- Amount requested
        fulfilled = 0,                                     -- Amount fulfilled
        status = "open",                                   -- open|fulfilled|cancelled|complete
        date = 1769171234,                                 -- Creation timestamp
        updatedAt = 1769171234,                            -- Last modification
        statusUpdatedAt = 1769171234,                      -- Status change timestamp
        notes = ""                                         -- Optional notes
    }
}

-- Version tracking (max updatedAt for quick freshness check)
requestsVersion = 1769171234

-- Operation log (ordered by actor, seq)
requestLog = {
    {
        id = "log-entry-uuid",                             -- Log entry ID
        actor = "Shamanoodles-OldBlanchy",                 -- Who performed action
        seq = 1,                                           -- Sequence number per actor
        ts = 1769171234,                                   -- Timestamp
        type = "add",                                      -- add|fulfill|cancel|complete|delete
        requestId = "request-uuid",                        -- Target request ID
        request = { ... },                                 -- Full snapshot (for add)
        delta = { fulfilled = 2 }                          -- Changes (for fulfill)
    }
}

-- Sequence tracking per actor
requestLogSeq = {
    ["Shamanoodles-OldBlanchy"] = 3,                      -- Next seq to emit
}

-- Applied sequence tracking (what we've processed)
requestLogApplied = {
    ["Shamanoodles-OldBlanchy"] = 2,                      -- Last applied seq
}

-- Tombstones (deleted requests)
requestsTombstones = {
    ["request-uuid"] = 1769171234,                        -- Delete timestamp
}
```

### Request Lifecycle

#### 1. Creating a Request
**Flow:**
1. Player calls `Guild:AddRequest(request)`
2. Request sanitized and assigned unique ID
3. Log entry created with type "add"
4. Entry recorded in local requestLog
5. Entry broadcast to guild via `togbank-d`
6. Request added to local requests array
7. UI refreshed

**Code Path:**
```
UI/Requests.lua:OnAddButtonClick()
  → Guild:AddRequest()
    → sanitizeRequest()
    → BuildRequestLogEntry("add")
    → RecordRequestLogEntry(broadcast=true)
      → AppendLogEntry()
      → SendRequestLogEntry() → togbank-d
      → ApplyRequestLogEntry()
        → requests array updated
      → RefreshRequestsUI()
```

#### 2. Fulfilling a Request
**Flow:**
1. Banker calls `Guild:FulfillRequest(requestId, quantity)`
2. Validates request exists and is fulfillable
3. Log entry created with type "fulfill" and delta
4. Entry broadcast and applied locally
5. If quantity >= request.quantity, status → "fulfilled"

**Conflict Resolution:**
- Multiple fulfillments are **additive** (clamped to quantity)
- Example: Banker A fulfills 2, Banker B fulfills 3 → total 5 (clamped to quantity)

#### 3. Cancelling/Completing
**Flow:**
1. Player calls `Guild:CancelRequest()` or `Guild:CompleteRequest()`
2. Permission checked (requester can cancel, bankers can complete)
3. Log entry created with type "cancel" or "complete"
4. Entry broadcast and applied locally

**Conflict Resolution:**
- Last-writer-wins by statusUpdatedAt
- Cancel beats fulfill if cancel.statusUpdatedAt > fulfill.statusUpdatedAt

#### 4. Deleting (Pruning)
**Flow:**
1. Completed/cancelled requests older than 7 days automatically pruned
2. Tombstone created with delete timestamp
3. Tombstone prevents deleted requests from reappearing in snapshots

### Synchronization Protocol

#### Snapshot Sync (Full State)
**When:** Initial sync, catch-up after being offline, or gap detection

**Flow:**
1. Player A broadcasts: `togbank-r` with type "requests" query
2. Player B (has data) sends: `togbank-d` with type "requests"
3. Player A receives snapshot via `ReceiveRequestsData()`
4. Player A calls `ApplyRequestSnapshot()`
   - **Merges** incoming with local (does NOT replace)
   - Keeps local requests not in incoming (unless tombstoned)
   - Updates requestLogApplied tracking
   - Updates tombstones
5. Replays any log entries newer than applied sequence
6. UI refreshed

**Payload Structure:**
```lua
{
    type = "requests",
    version = 1769171234,                    -- requestsVersion
    requests = [ ... ],                      -- Full request array
    requestLogApplied = { ... },             -- Applied sequences
    tombstones = { ... }                     -- Deleted request IDs
}
```

#### Log Entry Sync (Incremental)
**When:** Real-time updates, gap filling

**Flow:**
1. Player creates/modifies request → log entry broadcast
2. Other players receive via `ReceiveRequestLogEntries()`
3. Entry validated against expected sequence (must be seq = last + 1)
4. If gap detected → query missing entries via `QueryRequestLog()`
5. Entry applied via `ApplyRequestLogEntry()`

**Payload Structure:**
```lua
{
    type = "requests-log",
    logEntries = [
        {
            id = "...",
            actor = "Shamanoodles-OldBlanchy",
            seq = 3,
            ts = 1769171234,
            type = "add",
            requestId = "...",
            request = { ... }           -- Full data for add
            -- OR
            delta = { fulfilled = 2 }   -- Changes for fulfill
        }
    ]
}
```

#### Gap Detection & Recovery
**Problem:** Player offline, misses log entries 3-10

**Solution:**
1. Player receives entry with seq=11
2. Detects gap (expected seq=3, got seq=11)
3. Calls `QueryRequestLog(sender, { [actor] = 3 })`
4. Sender responds with entries 3-11
5. Entries applied in order

**Fallback:** If too many gaps → request full snapshot

### Merge Logic (Critical!)

**Problem:** ApplyRequestSnapshot was **replacing** local requests with incoming snapshot, causing data loss.

**Solution (v0.7.7):** Merge incoming with local
```lua
-- Build index of incoming requests
local incomingById = {}
for _, req in ipairs(sanitized) do
    incomingById[req.id] = req
end

-- Start with all incoming requests
local merged = {}
for _, req in ipairs(sanitized) do
    table.insert(merged, req)
end

-- Add local requests NOT in incoming (unless tombstoned)
for _, localReq in ipairs(self.Info.requests or {}) do
    if localReq.id and not incomingById[localReq.id] then
        local tombstoneTs = tombstones[localReq.id] or 0
        local localUpdated = localReq.updatedAt or 0

        -- Keep if not tombstoned OR if local update is newer
        if tombstoneTs == 0 or localUpdated > tombstoneTs then
            table.insert(merged, localReq)
        end
    end
end

self.Info.requests = merged
```

**Why This Matters:**
- Player A creates request locally
- Player B (who hasn't seen it) sends their snapshot
- Without merge: Player A's request gets deleted
- With merge: Player A's request is preserved

### Conflict Resolution Rules

#### Add (Create)
- **Rule:** Last-writer-wins by updatedAt
- **Example:** If request with same ID arrives from two sources, keep the one with newer updatedAt

#### Fulfill
- **Rule:** Additive, clamped to quantity
- **Example:**
  - Request for 10 items
  - Banker A fulfills 4
  - Banker B fulfills 6
  - Result: fulfilled = 10 (4+6)

#### Cancel/Complete
- **Rule:** Last-writer-wins by statusUpdatedAt
- **Example:**
  - Player cancels at timestamp 100
  - Banker fulfills at timestamp 90
  - Result: Request is cancelled (100 > 90)

#### Delete
- **Rule:** Tombstone wins over older updates
- **Example:**
  - Request deleted at timestamp 200
  - Receive snapshot with request updatedAt=150
  - Result: Request stays deleted (tombstone > update)

### Retention & Pruning

#### Request Pruning
- **When:** Completed/cancelled requests older than 7 days
- **How:** `PruneRequests()` called after sync operations
- **Result:** Request removed, tombstone created

#### Log Pruning
- **When:** Log entries older than 30 days OR log exceeds 500 entries
- **How:** `PruneRequestLog()` sorts by timestamp, keeps newest
- **Result:** Old entries discarded (already applied to snapshots)

#### Tombstone Pruning
- **When:** Tombstones older than 30 days
- **How:** `PruneRequestTombstones()` removes aged tombstones
- **Result:** Very old deleted requests can theoretically resurrect (acceptable)

### Known Issues & Fixes

#### UI-003: Request Data Loss (CRITICAL)
**Status:** Partially Fixed (v0.7.7), but still occurring

**Root Cause:** Multiple potential causes identified:
1. ✅ **Fixed:** ApplyRequestSnapshot was replacing instead of merging
2. ❓ **Investigating:** Possible race conditions in log replay
3. ❓ **Investigating:** Tombstone logic may be too aggressive
4. ❓ **Investigating:** requestLogApplied tracking may have bugs

**Current Symptoms:**
- Requests created by users sometimes don't appear in UI
- Requests visible, then disappear after reload
- No entry in requestLog or requestLogSeq for missing requests

**Debug Logging Added:**
- All request sync operations tagged with `[UI-003]`
- RefreshRequestsUI logs request count
- ApplyRequestSnapshot logs preserved local requests
- PruneRequests logs pruned requests

**Next Steps:**
1. Monitor debug logs for pattern detection
2. Verify requestLog entries are created for all requests
3. Check if tombstones are being created incorrectly
4. Investigate requestLogApplied sequence tracking

### Comparison: Request Sync vs. Delta Protocol

| Aspect | Request System | Inventory Delta System |
|--------|---------------|------------------------|
| **Architecture** | Snapshot + Operation Log | Hash-based Delta |
| **Sync Method** | Full state + log replay | Compute diff on-demand |
| **Bandwidth** | High (full snapshots) | Low (only changes) |
| **Complexity** | Moderate (merge logic) | High (hash computation) |
| **Channels** | togbank-r, togbank-d | togbank-r, togbank-rr, togbank-d |
| **Conflict Resolution** | Timestamps + log sequence | Version-based |
| **Gap Handling** | Query missing log entries | Re-query full state |
| **Storage** | Operation log + tombstones | Snapshots per alt |

**Note:** Request system could be refactored to use delta-style protocol in future for bandwidth optimization.

---

## 🔧 GUILD_ROSTER_UPDATE Cache System (COMM-001b) - IMPLEMENTED

**Status:** ✅ Fully Implemented (v0.8.x), Enhanced in COMM-003d (v0.8.29)
**Purpose:** Fix stale roster data causing false "player online" detections
**Priority:** HIGH - Eliminates player-visible error spam

**Update (v0.8.29 / COMM-003d):** The recentlySeen secondary cache has been removed. The onlineMembers cache (populated by GUILD_ROSTER_UPDATE and CHAT_MSG_SYSTEM events) is now the single source of truth for online status. This eliminates dual-cache race conditions and the 5-minute stale data window that was causing whispers to recently-offline players.

### Problem

Current `IsPlayerOnline()` implementation has a fundamental flaw:

```lua
function Guild:IsPlayerOnline(playerName)
    GuildRoster()  -- ❌ Requests update, doesn't wait for it
    -- GetGuildRosterInfo() returns STALE data immediately
    for i = 1, GetNumGuildMembers() do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        -- isOnline flag is outdated!
    end
end
```

**The Race Condition:**
1. Player logs out
2. 5 minutes pass (roster data becomes very stale)
3. Addon calls `IsPlayerOnline()` → `GuildRoster()` → `GetGuildRosterInfo()`
4. `GetGuildRosterInfo()` returns data from 5 minutes ago (player still "online")
5. Addon sends WHISPER to offline player
6. Blizzard server returns: **"No player named X is currently playing"**
7. Player sees error spam

### Solution: Event-Driven Cache

Maintain real-time cache that updates ONLY when Blizzard sends fresh data via `GUILD_ROSTER_UPDATE` event.

### Implementation Plan

**Step 1: Add Cache Table (Guild.lua)**
```lua
-- At module initialization
TOGBankClassic_Guild.onlineMembers = {}  -- {normalizedName = true}
```

**Step 2: Cache Refresh Function (Guild.lua)**
```lua
function TOGBankClassic_Guild:RefreshOnlineCache()
    wipe(self.onlineMembers)

    for i = 1, GetNumGuildMembers() do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if name and isOnline then
            local normalized = self:NormalizeName(name)
            self.onlineMembers[normalized] = true
        end
    end

    TOGBankClassic_Output:Debug("Refreshed online cache: %d members online",
        self:CountKeys(self.onlineMembers))
end
```

**Step 3: Event Registration (Events.lua)**
```lua
Events:RegisterEvent("GUILD_ROSTER_UPDATE", function()
    TOGBankClassic_Guild:RefreshOnlineCache()
end)

-- Request initial roster on login
Events:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    GuildRoster()  -- Triggers GUILD_ROSTER_UPDATE when server responds
end)
```

**Step 4: Update IsPlayerOnline() (Guild.lua)**
```lua
function TOGBankClassic_Guild:IsPlayerOnline(playerName)
    if not playerName then
        return false
    end

    local norm = self:NormalizeName(playerName)
    return self.onlineMembers[norm] == true
end
```

### Benefits

| Metric | Current (GuildRoster) | With Cache |
|--------|----------------------|------------|
| **Data Freshness** | Stale (minutes old) | Fresh (event-driven) |
| **API Calls** | 1 per check + loop | 0 (table lookup) |
| **Lookup Speed** | O(n) scan | O(1) hash lookup |
| **False Positives** | High (stale data) | Minimal (ms race window) |
| **Memory Overhead** | 0 | ~1KB for 100 members |
| **CPU per check** | ~2ms (roster scan) | ~0.001ms (table lookup) |

### When Cache Updates

- ✅ Guild member logs in/out
- ✅ Player joins/leaves guild
- ✅ After `GuildRoster()` call when server responds
- ✅ Blizzard's automatic periodic updates (~every few minutes)
- ✅ On PLAYER_ENTERING_WORLD (initial login)

### Edge Cases

**Q: What if someone logs out between cache update and whisper send?**
A: Race window reduced from minutes to milliseconds. Still possible, but 99%+ accurate.

**Q: What if cache isn't initialized yet?**
A: Returns false (safe default - no whisper sent). `PLAYER_ENTERING_WORLD` ensures quick init.

**Q: What about non-guild members?**
A: Not in cache, returns false. `SendWhisper()` skips send (correct behavior for guild-only bank addon). Note: A previous recentlySeen cache (5-minute TTL) was removed in COMM-003d - it attempted to track cross-realm/cross-guild players but was unnecessary architectural bloat for a guild-only addon and caused stale online status bugs.

**Q: Memory/performance cost?**
A: Negligible - ~10 bytes per member, rebuild takes <1ms for typical guild sizes.

### Testing Checklist

- [x] Cache initializes on login
- [x] Cache updates on GUILD_ROSTER_UPDATE
- [x] IsPlayerOnline() returns accurate status
- [x] Online player: WHISPER sent
- [x] Offline player: WHISPER skipped, debug log
- [x] Rapid login/logout scenarios
- [x] Large guild (200+ members) performance
- [x] Memory usage (<2KB for 200 members)
- [x] Verify "No player named" errors eliminated (COMM-003c: chat filter added)

### Files Modified

1. **Modules/Guild.lua**
   - Added `onlineMembers = {}` table
   - Implemented `RefreshOnlineCache()`
   - Replaced `IsPlayerOnline()` logic with onlineMembers-only lookup (COMM-003d removed recentlySeen dual-cache)

2. **Modules/Events.lua**
   - Registered `GUILD_ROSTER_UPDATE` event
   - Registered `PLAYER_ENTERING_WORLD` event with `GuildRoster()` call
   - Added `ChatFrame_AddMessageEventFilter` for error suppression (COMM-003c)

3. **docs/DELTA_BUGS.md**
   - Update [COMM-001] status to fully resolved
   - Document stale data fix

### Related Issues

- [COMM-001] "No player named X is currently playing" errors (original issue)
- [COMM-003] Whisper error detection via CHAT_MSG_SYSTEM
- [COMM-003b] Single-quoted player name pattern matching
- [COMM-003c] ChatFrame_AddMessageEventFilter for error suppression
- [COMM-003d] Removed recentlySeen cache (eliminated dual-cache race conditions)
- Complements SendWhisper() wrapper (already implemented)

### Success Criteria

- ✅ Zero "No player named" errors in normal operation
- ✅ <1ms overhead per online check
- ✅ Cache updates automatically without manual intervention
- ✅ Works with guilds of 200+ members
- ✅ Graceful handling of edge cases (cache not ready, non-guild members)

---

## 🔧 Debug Category Filtering - PLANNED

**Added:** January 24, 2026
**Purpose:** Reduce debug log spam by filtering messages into categories

### Problem
- Enabling `/togbank debug` creates miles of spam
- Hard to focus on specific issues when all debug output is mixed together
- Need to troubleshoot one subsystem at a time (e.g., just roster updates, just comms)
- Wading through thousands of messages to find relevant ones is inefficient

### Solution
Add category-based filtering to the debug output system. Each debug message gets tagged with a category, and users can enable/disable specific categories via the options UI.

### Debug Categories

- **ROSTER** - Guild roster updates, online/offline tracking
- **COMMS** - All addon communication traffic (high volume)
- **DELTA** - Delta sync operations and computations
- **SYNC** - Data synchronization operations
- **CACHE** - Cache operations (guild roster cache, etc.)
- **WHISPER** - Whisper sends, skips, and online checks
- **REQUESTS** - Request system activity and updates
- **UI** - UI operations, window opens/closes, rendering
- **PROTOCOL** - Protocol version negotiation
- **DATABASE** - Database operations, SavedVariables
- **EVENTS** - WoW event handling (GUILD_ROSTER_UPDATE, etc.)

### User Interface

**Options Panel Redesign** - Split into two tabs:

**Tab 1: "General"**
- Existing options (log level, sync messages mute, etc.)
- Keeps main config clean and uncluttered

**Tab 2: "Debug"**
- Checkbox for each debug category (11 checkboxes total)
- "Enable All" / "Disable All" buttons
- Categories default to OFF (opt-in to reduce spam)
- Only shown when debug mode is enabled via `/togbank debug`
- Settings persist in SavedVariables across sessions

**No slash commands needed** - all controls in UI

### Code Examples

```lua
-- Old style (no category, always shows if debug enabled)
TOGBankClassic_Output:Debug("Some message")

-- New style (category as first parameter)
TOGBankClassic_Output:Debug("ROSTER", "Refreshed online cache: %d members", count)
TOGBankClassic_Output:Debug("COMMS", "Received message from %s", sender)

-- Category is checked:
-- 1. If not a valid category string -> always show (backward compatible)
-- 2. If valid category but disabled -> skip message
-- 3. If valid category and enabled -> show message
```

### Implementation Plan

1. **Constants.lua** - Add `DEBUG_CATEGORY` table with all categories ✅
2. **Output.lua** - Add `debugCategories = {}` storage, modify `Debug()` function
3. **Database.lua** - Add SavedVariables field for category state persistence
4. **Options.lua** - Add "Debug Categories" section with checkboxes for each category
5. **Various modules** - Update high-traffic Debug() calls with categories (gradual)

### Default Behavior

- All categories **disabled by default** (opt-in to avoid spam)
- User must explicitly enable categories they want to see
- Uncategorized Debug() calls always show (backward compatibility)
- Settings persist across `/reload` and sessions

### Files to Modify

1. **Modules/Constants.lua** - Define DEBUG_CATEGORY constants ✅
2. **Modules/Output.lua** - Category tracking, modified Debug() function
3. **Modules/Database.lua** - SavedVariables schema for category state
4. **Modules/Options.lua** - UI controls for category toggles
5. **Various modules** - Update Debug() calls (gradual rollout)

### Testing Checklist

- [ ] Category checkboxes appear in Options panel
- [ ] Categories default to disabled (unchecked)
- [ ] Toggling categories on/off filters debug output correctly
- [ ] Settings persist across `/reload`
- [ ] Settings persist across logout/login
- [ ] "Enable All" / "Disable All" buttons work
- [ ] Backward compatibility (old Debug() calls still work)
- [ ] High-traffic categories (COMMS) reduce spam when disabled

### Success Criteria

- ✅ Can enable only ROSTER category to debug guild cache without COMMS spam
- ✅ Category settings persist across sessions
- ✅ Existing Debug() calls work without modification
- ✅ Easy to toggle categories on/off in options UI
- ✅ All categories default to OFF (opt-in)

---

## 🔄 Protocol Prioritization (SYNC-006 Migration) - IMPLEMENTED

**Added:** January 28, 2026
**Purpose:** Ensure smooth migration from pre-SYNC-006 to SYNC-006+ protocol during dual-broadcast period

### Problem
- Bankers broadcast on both `togbank-dv` (pre-SYNC-006) and `togbank-dv2` (SYNC-006+) for backward compatibility
- SYNC-006+ clients received both messages, potentially causing:
  - Duplicate processing of same alt data
  - Hash format confusion (legacy "B:+G:" vs new "I:" format)
  - Wasted bandwidth processing obsolete protocol data

### Solution
Implemented message prioritization with delayed processing:

**Protocol Filtering:**
- SYNC-006+ clients: Only listen to `togbank-dv2`, delay `togbank-dv` by 5 seconds
- Pre-SYNC-006 clients: Only listen to `togbank-dv`, ignore `togbank-dv2`
- Bankers: Broadcast on BOTH channels during migration period

**Delay/Cancel Mechanism:**
1. When `togbank-dv` arrives on SYNC-006+ client:
   - Store message in pending queue with 5-second timer
   - Log: "Delaying dv message from {sender} for 5 seconds (waiting for dv2)"
2. When `togbank-dv2` arrives:
   - Process immediately
   - Cancel any pending `togbank-dv` timers for same alts
   - Log: "Canceling pending dv message for {alt} (dv2 arrived)"
3. After 5 seconds (if no dv2):
   - Process delayed `togbank-dv` message as fallback
   - Log: "Processing delayed dv message from {sender} (no dv2 received)"

### Implementation Details

**Chat.lua Changes:**
- `pending_dv_messages[sender][altName]` - Tracks delayed messages by sender and alt name
- `DV_DELAY = 5` - Configurable delay in seconds
- `CancelPendingDvMessages()` - Cancels timers when dv2 arrives
- `ProcessDelayedDvMessage()` - Handles fallback after timeout
- `ProcessVersionBroadcast()` - Extracted common processing logic

**Guild.lua Changes:**
- `UsesSYNC006()` - Returns `true` for current clients, enables protocol filtering

**Flow Diagram:**
```
Banker broadcasts:
  ├─ togbank-dv2 → SYNC-006+ clients (immediate)
  └─ togbank-dv → Pre-SYNC-006 clients (immediate)
                └─ SYNC-006+ clients (5s delay, canceled if dv2 arrives)
```

### Migration Strategy

**Phase 1: Dual Broadcasting (Current)**
- All bankers send both dv and dv2
- New clients prioritize dv2, fallback to dv after 5s
- Old clients ignore dv2, process dv normally

**Phase 2: Monitor Adoption (3-6 months)**
- Track client versions in guild
- Wait until 95%+ on SYNC-006+

**Phase 3: Remove Legacy (Future)**
- Stop broadcasting `togbank-dv`
- Remove 5-second delay logic
- Remove `togbank-v` legacy support
- Clean up `alt.bank.items` and `alt.bags.items` structures

### Technical Notes
- Uses `C_Timer.After()` for 5-second delay
- Timer references stored in pending queue for cancellation
- Pending messages keyed by `sender` → `altName` for granular control
- No performance impact: delay only applies when receiving obsolete protocol data
- Graceful fallback: if banker only sends dv (old version), still processes after 5s

### User Experience
- **New clients with new bankers:** Instant sync (dv2 only), no delay
- **New clients with old bankers:** 5s delay for dv fallback (rare case)
- **Old clients:** No change, immediate sync on dv
- **Migration period:** Both client types work simultaneously

### Success Criteria
- ✅ SYNC-006+ clients never process togbank-dv when dv2 available
- ✅ SYNC-006+ clients fall back to dv if banker only sends dv
- ✅ Pre-SYNC-006 clients continue working during migration
- ✅ No duplicate processing or hash confusion
- ✅ Clear debug logs show delay/cancel/fallback behavior

---

## 🛡️ Request Data Validation & Sanitization

**Current State:** January 31, 2026
**Purpose:** Document existing and planned validation to prevent corrupted request data from spreading

### Current Validation (in `sanitizeRequest()`)

**What We Validate:**
1. ✅ **Type Checking** - Rejects non-table data
2. ✅ **Numeric Fields** - Forces non-negative values, clamps fulfilled ≤ quantity
3. ✅ **Timestamp Validation** - Rejects timestamps > 2147483647 (32-bit limit, DATA-003 fix)
4. ✅ **Status Validation** - Resets invalid status to "open"
5. ✅ **Player Name Normalization** - Ensures consistent name-realm format
6. ✅ **String Safety** - Forces toString on item/notes fields
7. ✅ **Auto-Status Correction** - Sets status="fulfilled" when fulfilled ≥ quantity

**Where Applied:**
- `mergeRequest()` - On receiving snapshots
- `NormalizeRequestList()` - On load
- `AddRequest()` - On creation
- UI display - Before rendering

### Weaknesses Identified

❌ **Not Validated:**
- **ID length** - No max length check (could be exploited)
- **Empty strings** - `item = ""` or `requester = "Unknown"` are allowed
- **Future timestamps** - Only checks for overflow, not logical validity (e.g., year 2050)
- **Negative timestamps** - No minimum timestamp check
- **Request age** - No check for ancient requests (years old)
- **Duplicate IDs** - Not checked during sanitization
- **Malicious field injection** - Extra fields are silently kept

**Current Behavior:**
- Bad data is **corrected** rather than **rejected**
- No rejection tracking or logging
- No broadcast filtering (bad data could spread before being sanitized)
- Permissive defaults (empty/missing → "Unknown" or "")

### Planned Improvements

#### Phase 1: Strict Validation (Empty Strings & Duplicate IDs)

**Status:** ✅ IMPLEMENTED (2026-01-31)

**Goal:** Reject obviously invalid requests instead of accepting with defaults

**Implementation:**
```lua
local function sanitizeRequest(req)
    if not req or type(req) ~= "table" then
        return nil
    end

    -- REJECT empty required fields (Phase 1 validation)
    local item = req.item and tostring(req.item) or ""
    if item == "" then
        TOGBankClassic_Output:Debug("REQUESTS", "Rejected request: empty item field")
        return nil
    end

    local requesterRaw = req.requester and tostring(req.requester) or ""
    if requesterRaw == "" or requesterRaw == "Unknown" then
        TOGBankClassic_Output:Debug("REQUESTS", "Rejected request: invalid requester '%s'", requesterRaw)
        return nil
    end

    local bankRaw = req.bank and tostring(req.bank) or ""
    if bankRaw == "" then
        TOGBankClassic_Output:Debug("REQUESTS", "Rejected request: empty bank field")
        return nil
    end

    local quantity = math.max(tonumber(req.quantity or 0) or 0, 0)
    if quantity == 0 then
        TOGBankClassic_Output:Debug("REQUESTS", "Rejected request: quantity is zero")
        return nil
    end

    -- ... rest of sanitization ...
end
```

**Where Applied (Multi-Layer Defense):**

1. **Layer 1: Receiving Snapshots** - `RequestLog.lua:219`
   ```lua
   local function mergeRequest(requests, tombstones, id, incoming)
       local clean = sanitizeRequest(incoming)
       if not clean then
           return nil  -- Silently drops invalid requests from snapshots
       end
       -- ... merge logic
   end
   ```
   - **Effect:** Invalid requests from other players are rejected before merging into local database
   - **Protection:** Prevents corrupted data from spreading through guild

2. **Layer 2: Loading from SavedVariables** - `RequestLog.lua:313`
   ```lua
   function Guild:NormalizeRequestList()
       for id, req in pairs(self.Info.requests) do
           local clean = sanitizeRequest(req)
           if clean and clean.id then
               normalized[clean.id] = clean
           end
           -- Invalid requests are silently dropped
       end
   end
   ```
   - **Effect:** Corrupted requests in saved data are stripped out on addon load
   - **Protection:** Auto-healing of existing database corruption

3. **Layer 3: Creating New Requests** - `RequestLog.lua:1064`
   ```lua
   function Guild:AddRequest(request)
       local clean = sanitizeRequest(request)
       if not clean then
           return false  -- Request creation fails
       end
       -- ... store and broadcast
   end
   ```
   - **Effect:** Prevents creation of invalid requests via UI or commands
   - **Protection:** Stops bad data at the source

4. **Layer 4: UI Display** - `Guild.lua:2041`
   ```lua
   for _, req in pairs(current_data.requests or {}) do
       local clean = TOGBankClassic_Guild:SanitizeRequest(req)
       if clean and clean.item and clean.item ~= "" then
           -- Count for status display
       end
   end
   ```
   - **Effect:** Corrupted requests filtered out of UI
   - **Protection:** Prevents crashes or display issues from bad data

**What Happens to Rejected Requests:**
- **Snapshots:** Request not merged, silently dropped
- **Load:** Request removed from database during normalization
- **Creation:** `AddRequest()` returns `false`, user sees failure
- **Display:** Request skipped, doesn't appear in UI
- **Debug Log:** All rejections logged with reason

**Validation Rules Enforced:**
- ✅ `item` - Must not be empty or missing
- ✅ `requester` - Must not be empty, missing, or "Unknown"
- ✅ `bank` - Must not be empty or missing
- ✅ `quantity` - Must be > 0

**Files Modified:**
- `Modules/RequestLog.lua` (lines 55-85): Added Phase 1 validation

**See Also:**
- Bug ticket: [DATA-008] in DELTA_BUGS.md

**Duplicate ID Handling (Not Yet Implemented):**
```lua
-- In mergeRequest() or ApplyRequestSnapshot()
local seenIds = {}
for _, req in ipairs(incomingList) do
    if req.id and seenIds[req.id] then
        TOGBankClassic_Output:Warn("Duplicate request ID detected: %s", req.id)
        -- Skip duplicate, keep first occurrence only
    else
        seenIds[req.id] = true
        -- ... merge logic ...
    end
end
```

#### Phase 2: Timestamp Logic Validation

```lua
-- Add to sanitizeRequest()
local MIN_TIMESTAMP = 946684800  -- Jan 1, 2000
local MAX_TIMESTAMP = 2147483647  -- Jan 19, 2038
local now = GetServerTime()
local MAX_FUTURE = now + 86400  -- Allow 1 day tolerance for clock skew

local function validateTimestamp(ts, fallback)
    local num = tonumber(ts) or fallback

    -- Check range
    if num < MIN_TIMESTAMP then
        TOGBankClassic_Output:Debug("REQUESTS", "Rejected: timestamp too old (%d)", num)
        return nil  -- Reject instead of using fallback
    end

    if num > MAX_TIMESTAMP then
        TOGBankClassic_Output:Debug("REQUESTS", "Rejected: timestamp overflow (%d)", num)
        return nil
    end

    -- Check for future timestamps (possible corruption or malicious data)
    if num > MAX_FUTURE then
        TOGBankClassic_Output:Debug("REQUESTS", "Rejected: future timestamp (%d > %d)", num, MAX_FUTURE)
        return nil
    end

    return num
end

-- Then use stricter validation
local updatedAt = validateTimestamp(req.updatedAt or req.date, now)
if not updatedAt then
    return nil  -- Reject request with invalid timestamp
end
```

#### Phase 3: Broadcast Filtering

**Prevent spreading bad data:**
```lua
function Guild:BroadcastRequestMutation(mutation)
    if not mutation or type(mutation) ~= "table" then
        return
    end

    -- VALIDATE before broadcasting
    if mutation.request then
        local clean = sanitizeRequest(mutation.request)
        if not clean then
            TOGBankClassic_Output:Warn("Blocked broadcast of invalid request: %s",
                tostring(mutation.requestId))
            return  -- Don't spread bad data
        end
        mutation.request = clean  -- Use sanitized version
    end

    -- ... existing broadcast logic ...
end
```

#### Phase 4: Periodic Cleanup

**Auto-heal corrupted data on load:**
```lua
function Guild:ValidateAndCleanRequests()
    if not self.Info or not self.Info.requests then
        return 0
    end

    local removed = 0
    local now = GetServerTime()

    for id, req in pairs(self.Info.requests) do
        local shouldRemove = false
        local reason = ""

        -- Check for corrupted data
        if not req.id or req.id ~= id then
            shouldRemove = true
            reason = "ID mismatch"
        elseif not req.item or req.item == "" then
            shouldRemove = true
            reason = "Empty item"
        elseif req.quantity and req.quantity < 0 then
            shouldRemove = true
            reason = "Negative quantity"
        elseif req.updatedAt and req.updatedAt > now + 86400 then
            shouldRemove = true
            reason = "Future timestamp"
        end

        if shouldRemove then
            TOGBankClassic_Output:Debug("REQUESTS",
                "Cleaning corrupted request %s: %s", id, reason)
            self.Info.requests[id] = nil
            -- Create tombstone to prevent resurrection
            self.Info.requestsTombstones = self.Info.requestsTombstones or {}
            self.Info.requestsTombstones[id] = now
            removed = removed + 1
        end
    end

    if removed > 0 then
        TOGBankClassic_Output:Info("Cleaned %d corrupted requests", removed)
        self:RefreshRequestsUI()
    end

    return removed
end

-- Call during initialization
function Guild:EnsureRequestsInitialized()
    -- ... existing initialization ...

    -- Run cleanup on load
    self:ValidateAndCleanRequests()
end
```

#### Phase 5: User Command

```lua
-- Add slash command for manual cleanup
-- Usage: /togbank cleanrequests
function TOGBankClassic_Commands:CleanRequests()
    local guild = TOGBankClassic_Guild
    if not guild or not guild.Info then
        TOGBankClassic_Output:Response("No guild data loaded")
        return
    end

    local removed = guild:ValidateAndCleanRequests()
    if removed > 0 then
        TOGBankClassic_Output:Response("Cleaned %d corrupted requests", removed)
        -- Broadcast updated snapshot to overwrite bad data on other clients
        guild:SendRequestsSnapshot()
    else
        TOGBankClassic_Output:Response("No corrupted requests found")
    end
end
```

### Implementation Priority

1. **Phase 1** (Immediate) - Empty strings & duplicate IDs
   - Low risk, high value
   - Prevents most common data issues
   - Easy to implement and test

2. **Phase 2** (Short-term) - Timestamp logic validation
   - Catches corruption and malicious data
   - Prevents future-dated requests

3. **Phase 3** (Medium-term) - Broadcast filtering
   - Prevents spreading bad data
   - Most impactful for guild-wide data integrity

4. **Phase 4** (Long-term) - Periodic cleanup
   - Auto-healing for existing corruption
   - Reduces support burden

5. **Phase 5** (Nice-to-have) - User command
   - Manual recovery tool
   - Useful for debugging

### Testing Strategy

**Test Cases:**
- Empty item name
- Empty requester name
- Duplicate request IDs in snapshot
- Future timestamps (year 2050)
- Negative timestamps (1970)
- Oversized IDs (500+ characters)
- Malformed ID format (missing colon, invalid hex)
- Negative quantities
- Requests without required fields

**Success Metrics:**
- Zero corrupted requests after cleanup
- No rejected valid requests (false positives)
- Debug logs show rejection reasons
- No crashes or errors during validation

---
