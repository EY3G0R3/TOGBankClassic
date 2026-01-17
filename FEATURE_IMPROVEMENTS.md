# TOGBankClassic - Feature Improvements

**Development Note:** Use GitKraken for pushing updates to repository.

## Features
- [ ] Right-click minimap button to open config/options
- [ ] Move filled/completed orders to an archive tab
- [ ] Add mouseover tooltip for truncated item names to show full text
- [ ] Single-click button to fulfill request and send mail with all/some items (bulk mail addon?), possibly a popup to select quantity then fill?
- [ ] Optimize bank data sync communications for efficiency/speed (encode data if possible)
- [ ] Display items in mail with indicator/tag showing they're in mail (not bags/bank)
- [ ] Implement BigWigs package manager support
- [ ] Implement version check (notify users of outdated addon)

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
-- New togbank-d2 message format
{
    type = "alt-delta",
    name = "BankAlt-Realm",
    version = 1234567900,           -- New version timestamp
    baseVersion = 1234567890,       -- Version this delta applies to
    changes = {
        money = 50000,              -- New total (if changed)
        bank = {
            added = {               -- New items
                {slot=5, ID=123, Count=10, Link="..."},
                {slot=12, ID=456, Count=5, Link="..."}
            },
            modified = {            -- Changed items (count, link, etc.)
                {slot=3, Count=15},
                {slot=7, Count=2, Link="..."}
            },
            removed = {2, 8, 15}   -- Removed slot numbers
        },
        bags = {
            added = {...},
            modified = {...},
            removed = {...}
        }
    }
}
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

