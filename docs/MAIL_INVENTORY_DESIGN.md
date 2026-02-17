# Mail Inventory Design Document

**Feature Branch:** `feature/mail-inventory-status`
**Created:** 2026-01-27
**Status:** ✅ IMPLEMENTED (February 16, 2026)
**Implementation Version:** v0.8.0+

## Overview

Mail inventory tracking is now fully integrated into TOGBankClassic, allowing users to see items in the mailbox as part of viewable inventory with full sync support.

## Implementation Status

✅ **Completed Features:**
1. **Mail Inventory Scanning**: Scans mailbox on MAIL_CLOSED event
2. **Inventory Aggregation**: Mail items merged into `alt.items` during Bank:Scan()
3. **Hash-Based Change Detection**: Separate `mailHash` tracks mail-specific changes
4. **Sync Protocol Integration**: Mail changes trigger delta syncs like bank/bags
5. **Bandwidth Optimization**: Mail links stripped for non-gear items
6. **Search Integration**: Mail items searchable (no double-counting)
7. **P2P Distribution**: Mail data distributed via peer-to-peer protocol

## Recent Fixes (February 17, 2026)

### Issue #7: Mail-Only Change Sync Abort ✅ FIXED
**Problem:** When mail changed but inventory didn't, and no snapshot was available, `ComputeDelta()` returned `nil`, causing complete sync failure. Requesters with matching inventory but outdated mail would never receive updates.  
**Root Cause:** Line 567 in DeltaComms.lua returned `nil` instead of falling back to empty baseline like the general hash mismatch case.  
**Solution:** Changed to use same fallback as inventory mismatch: `previous = { items = {}, money = 0, mailHash = 0 }`. Delta still contains all items as additions (against empty baseline), but sync succeeds.  
**Result:** Mail-only changes always sync successfully, even after snapshot expiration. No more permanent out-of-sync states.  
**Files:** [DeltaComms.lua](../Modules/DeltaComms.lua#L557-L567)

## Recent Fixes (February 16, 2026)

The following critical issues were resolved to make mail a true first-class inventory component:

### Issue #1: Mail Hash Not Checked During Sync ✅ FIXED
**Problem:** Version broadcasts only compared `inventoryHash`, ignoring `mailHash`  
**Solution:** Modified `ProcessVersionBroadcast()` in [Chat.lua](../Modules/Chat.lua#L506-L518) to compare both hashes  
**Result:** Mail changes now trigger delta syncs immediately

### Issue #2: Mail Links Not Stripped ✅ FIXED
**Problem:** Full item links sent for all mail items (bandwidth waste)  
**Solution:** Enhanced `StripAltLinks()` in [Guild.lua](../Modules/Guild.lua#L1842-L1862) to strip mail links  
**Result:** Only gear/weapon links sent, 70%+ bandwidth reduction for mail data

### Issue #3: mailHash Computed But Not Used ✅ FIXED
**Problem:** `mailHash` calculated but not passed through sync pipeline  
**Solution:** Added `requesterMailHash` to P2P requests, state summaries, delta computation  
**Files:** [Guild.lua](../Modules/Guild.lua#L873-L884), [Chat.lua](../Modules/Chat.lua#L1026-L1036), [DeltaComms.lua](../Modules/DeltaComms.lua#L547-L567)  
**Result:** Full mail hash tracking through entire sync protocol

### Issue #4: Search Double-Counted Mail ✅ FIXED
**Problem:** Mail aggregated twice in search (once in alt.items, once manually)  
**Solution:** Removed duplicate mail merging in [Search.lua](../Modules/UI/Search.lua#L444-L445)  
**Result:** Mail items counted correctly in search corpus

### Issue #6: No Mail-Specific Change Detection ✅ FIXED
**Problem:** Could not distinguish mail-only changes from inventory changes  
**Solution:** Three-way hash detection in `ComputeDelta()` ([DeltaComms.lua](../Modules/DeltaComms.lua#L547-L567))  
**Result:** Can send mail-only deltas, better debugging visibility

## Goals (✅ Achieved)

1. ✅ **Mail Inventory Visibility**: Display all items currently in the mailbox as part of viewable inventory
2. ✅ **Request Fulfillment Indicator**: Show visual indicator when requested items are waiting in mail
3. ✅ **Sync Support**: Mail changes propagate to all guild members
4. ✅ **First-Class Treatment**: Mail treated identically to bank/bags inventory

## Use Cases

### Use Case 1: Banker Viewing Mail Inventory
**Actor:** Guild Banker
**Goal:** See what items are currently in their mailbox without opening mail UI

**Flow:**
1. Banker opens TOGBankClassic UI
2. Inventory view shows both bank/bags AND mail items
3. Mail items are visually distinguished (icon, color, or separate section)
4. Banker can see total count including mail inventory

**Example:**
```
Inventory Status for Metals-Azuresong:
  Bank: 45/112 slots
  Bags: 60/80 slots
  Mail: 15/50 items  ← NEW

  Iron Ore: 200 (Bank: 120, Bags: 60, Mail: 20)  ← NEW: Shows mail breakdown
```

### Use Case 2: Requester Sees Items in Mail
**Actor:** Guild Member requesting items
**Goal:** Know that requested items are ready and waiting in banker's mail

**Flow:**
1. Member requests 50 Iron Ore from Metals
2. Another player mails 50 Iron Ore to Metals
3. Request UI updates to show mail icon next to request
4. Member sees: "50 Iron Ore - ✉ In Mail (Metals)"
5. Member can contact Metals to retrieve and send

### Use Case 3: Banker Priority Queue
**Actor:** Guild Banker
**Goal:** Prioritize fulfilling requests where items are already in mail

**Flow:**
1. Banker opens Requests UI
2. Requests with items in mail show special indicator (✉ icon, highlight)
3. Banker can filter/sort by "items in mail" status
4. Banker prioritizes these requests for quick fulfillment

## Technical Design

### Data Model

#### Mail Inventory Structure (Actual Implementation)
```lua
-- Alt data structure with mail
alt.mail = {
    slots = 50,           -- Total mail slots (always 50 in Classic)
    items = {              -- Array (same as bank/bags)
        {
            ID = 12345,
            Count = 20,
            Link = "|cffffffff|Hitem:2770::::::::60:::::|h[Copper Ore]|h|r",
            ItemString = "item:2770:0:0:0:0:0:0:0"
        }
    },
    version = 1234567890,  -- Timestamp of last scan
    lastScan = 1234567890  -- When mailbox was last opened
}

-- Inventory aggregation (in alt.items)
alt.items = {
    -- Merged items from bank + bags + mail
    -- Mail items are included in aggregate count
}

-- Hash tracking
alt.inventoryHash = 98765  -- Hash of bank + bags + mail
alt.mailHash = 12345       -- Separate hash for mail-only changes
```

**Implementation Notes:**
- Mail items stored as arrays like bank/bags
- Links preserved only for `NeedsLink()` items (gear/weapons/uncached)
- Mail items **aggregated into `alt.items`** during `Bank:Scan()`
- Dual-hash system: `inventoryHash` (all inventory) + `mailHash` (mail-specific)
- Link stripping applied to mail during P2P sync (bandwidth optimization)
- Mail treated as **first-class inventory** - changes trigger delta syncs

#### Request Enhancement
```lua
-- Add to request data structure
request.fulfillment = {
    inBags = 50,      -- Existing: items in bags/bank
    inMail = 20,      -- NEW: items in mail
    total = 70,       -- Total available
    canFulfill = true -- Total >= requested
}
```

### API Changes

#### New Functions

**Mail.lua - ScanMailInventory()**

This should be called from `Bank:Scan()` when mail was accessed (same flow as bank scanning):

```lua
function TOGBankClassic_Mail:ScanMailInventory()
    -- Only scan if mail was accessed this session
    if not self.hasUpdated then
        return nil
    end

    local mailItems = {}
    local numItems, totalItems = GetInboxNumItems()

    for i = 1, numItems do
        local packageIcon, stationeryIcon, sender, subject, money, CODAmount,
              daysLeft, hasItem, wasRead, wasReturned, textCreated, canReply,
              isGM = GetInboxHeaderInfo(i)

        -- Skip COD mail (can't take without payment)
        if hasItem and CODAmount == 0 then
            for j = 1, ATTACHMENTS_MAX_RECEIVE do
                local name, itemID, itemTexture, count, quality, canUse =
                    GetInboxItem(i, j)

                if itemID then
                    local link = GetInboxItemLink(i, j)

                    if not mailItems[itemID] then
                        mailItems[itemID] = {
                            id = itemID,
                            name = name,
                            link = link,
                            count = 0,
                            sources = {}
                        }
                    end

                    mailItems[itemID].count = mailItems[itemID].count + count
                    table.insert(mailItems[itemID].sources, {
                        index = i,
                        count = count,
                        sender = sender,
                        daysLeft = daysLeft,
                        subject = subject
                    })
                end
            end
        end
    end

    return {
        slots = 50,
        items = mailItems,
        version = time(),
        lastScan = time()
    }
end
```

**Bank.lua - Update Scan() to include mail**

Add mail scanning to the existing `Bank:Scan()` function (around line 160):

```lua
function TOGBankClassic_Bank:Scan()
    -- ... existing bank and bags scanning code ...

    -- NEW: Scan mail inventory (follows same pattern as bank)
    if TOGBankClassic_Mail.hasUpdated then
        local mailData = TOGBankClassic_Mail:ScanMailInventory()
        if mailData then
            alt.mail = mailData
        end
        TOGBankClassic_Mail.hasUpdated = false
    end

    -- v0.8.0: Only update version if inventory actually changed
    -- Update hash computation to include mail
    local currentHash = TOGBankClassic_Core:ComputeInventoryHash(
        alt.bank, alt.bags, alt.mail, money
    )
    -- ... rest of existing version logic ...
end
```

**Item.lua - GetItemsWithMail()**
```lua
function TOGBankClassic_Item:GetItemsWithMail(itemID)
    -- Returns list of alts that have this item in mail
    local alts = {}

    for name, alt in pairs(TOGBankClassic_Guild.Info.alts) do
        if alt.mail and alt.mail.items and alt.mail.items[itemID] then
            table.insert(alts, {
                name = name,
                count = alt.mail.items[itemID].count,
                lastScan = alt.mail.lastScan
            })
        end
    end

    return alts
end
```

**RequestLog.lua - CheckMailFulfillment()**
```lua
function TOGBankClassic_RequestLog:CheckMailFulfillment(request)
    -- Check if requested items are available in mail
    local itemID = request.itemID
    local needed = request.quantity

    local inMail = 0
    for name, alt in pairs(TOGBankClassic_Guild.Info.alts) do
        if alt.mail and alt.mail.items and alt.mail.items[itemID] then
            inMail = inMail + alt.mail.items[itemID].count
        end
    end

    return {
        inMail = inMail,
        canFulfillFromMail = inMail >= needed
    }
end
```

### Event Handling

#### Mail Events - Following Bank Pattern

Mail scanning follows the same pattern as bank scanning:

**Pattern:**
1. `MAIL_SHOW` → Set flag that mail was accessed
2. `MAIL_CLOSED` → Scan mail and cache inventory
3. Cached data persists until next mailbox visit

**Why scan on close instead of open?**
- Mail UI takes time to populate (async loading)
- Players may take/delete items while mailbox is open
- Scanning on close captures final state, just like bank does

```lua
-- Events.lua
function TOGBankClassic_Events:MAIL_SHOW()
    TOGBankClassic_Bank:OnUpdateStart()  -- Existing call for bags
    TOGBankClassic_Mail.hasUpdated = true  -- NEW: Flag mail access
end

function TOGBankClassic_Events:MAIL_CLOSED()
    if TOGBankClassic_Mail.hasUpdated then
        TOGBankClassic_Mail:ScanMailInventory()  -- Scan and cache
    end
    TOGBankClassic_Mail.hasUpdated = false
end
```

**No MAIL_INBOX_UPDATE needed** - scanning on close captures all changes automatically, whether items were added, removed, or mail expired.

### UI Changes

#### Inventory Display Enhancement

**UI/Inventory.lua - Show Mail Items**
```lua
-- Add mail section to inventory tooltip
if alt.mail and alt.mail.items then
    local mailCount = 0
    for _, item in pairs(alt.mail.items) do
        mailCount = mailCount + 1
    end

    if mailCount > 0 then
        tooltip:AddLine(" ")
        tooltip:AddLine("|cff00ff00Mail Inventory:|r", 1, 1, 1)

        for itemID, mailItem in pairs(alt.mail.items) do
            tooltip:AddDoubleLine(
                mailItem.link,
                string.format("x%d ✉", mailItem.count),
                1, 1, 1,
                0.7, 0.7, 1
            )
        end

        -- Show age of mail scan
        local age = time() - (alt.mail.lastScan or 0)
        if age > 3600 then
            tooltip:AddLine(
                string.format("|cffff9900Last scanned: %s ago|r",
                    SecondsToTime(age)),
                0.7, 0.7, 0.7
            )
        end
    end
end
```

#### Search Results Enhancement

**UI/Search.lua - Include Mail in Results**
```lua
-- When searching for items, include mail inventory
local function SearchAllInventory(searchText)
    local results = {}

    for name, alt in pairs(TOGBankClassic_Guild.Info.alts) do
        -- Existing: Search bags and bank
        SearchBagsAndBank(alt, results)

        -- NEW: Search mail
        if alt.mail and alt.mail.items then
            for itemID, mailItem in pairs(alt.mail.items) do
                if ItemMatchesSearch(mailItem, searchText) then
                    table.insert(results, {
                        alt = name,
                        item = mailItem,
                        location = "Mail",  -- NEW field
                        icon = "✉"          -- NEW field
                    })
                end
            end
        end
    end

    return results
end
```

#### Request UI Enhancement

**UI/Requests.lua - Show Mail Indicator**
```lua
-- Add mail icon to requests where items are in mail
local function UpdateRequestRow(row, request)
    -- Existing row setup...

    -- NEW: Check if items are in mail
    local mailFulfillment = TOGBankClassic_RequestLog:CheckMailFulfillment(request)

    if mailFulfillment.inMail > 0 then
        -- Show mail icon
        if not row.mailIcon then
            row.mailIcon = row:CreateTexture(nil, "OVERLAY")
            row.mailIcon:SetSize(16, 16)
            row.mailIcon:SetPoint("RIGHT", row.quantityText, "LEFT", -5, 0)
            row.mailIcon:SetTexture("Interface\\Icons\\INV_Letter_15")
        end

        row.mailIcon:Show()

        -- Tooltip
        row.mailIcon:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Items in Mail")
            GameTooltip:AddLine(
                string.format("%d available in mailbox", mailFulfillment.inMail),
                1, 1, 1
            )
            if mailFulfillment.canFulfillFromMail then
                GameTooltip:AddLine(
                    "Can fulfill this request from mail!",
                    0, 1, 0
                )
            end
            GameTooltip:Show()
        end)
        row.mailIcon:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    else
        if row.mailIcon then
            row.mailIcon:Hide()
        end
    end
end
```

### Delta Sync Integration

Mail inventory is **fully integrated** as first-class inventory in the delta sync system. Key implementation details:

#### Hash-Based Change Detection
```lua
-- Guild.lua: ComputeStateSummary()
local summary = {
    inventoryHash = alt.inventoryHash,
    mailHash = alt.mailHash,  -- CRITICAL: Both hashes included
    -- ...
}
```

#### Version Broadcast Comparison
```lua
-- Chat.lua: ProcessVersionBroadcast()
-- Compare BOTH hashes to determine if sync needed
local inventoryChanged = (ourHash ~= theirHash)
local mailChanged = (ourMailHash ~= theirMailHash)

if inventoryChanged or mailChanged then
    -- Trigger sync if EITHER changed
end
```

#### P2P Request Propagation
```lua
-- Guild.lua: BroadcastP2PRequest()
-- Include both hashes in P2P requests
Chat:SendAddonMessage("togbank-r", string.format(
    "%s|%s|%d|%d",  -- mailHash added to protocol
    requestingAlt, targetAlt, requesterHash, requesterMailHash
))
```

#### Three-Way Delta Detection
```lua
-- DeltaComms.lua: ComputeDelta()
-- Can detect three scenarios:
-- 1. Inventory + mail changed (both hashes differ)
-- 2. Inventory only changed (inventoryHash differs, mailHash same)
-- 3. Mail only changed (mailHash differs, inventoryHash same)
```

#### Link Stripping for Bandwidth
```lua
-- Guild.lua: StripAltLinks()
-- Mail links stripped for non-gear items (same as bank/bags)
if alt.mail and alt.mail.items then
    for _, item in ipairs(alt.mail.items) do
        if not Item:NeedsLink(item.ID) then
            item.Link = nil  -- Strip link to reduce bandwidth
        end
    end
end
```

**Benefits:**
- Mail changes trigger syncs immediately (not delayed)
- Can send mail-only deltas when inventory unchanged
- Full P2P distribution of mail data
- Bandwidth optimized via link stripping
- First-class treatment matches bank/bags behavior

## UI/UX Considerations

### Visual Indicators

1. **Mail Icon Options:**
   - ✉ (Unicode envelope)
   - Interface\Icons\INV_Letter_15 (WoW mail icon)
   - Interface\Icons\INV_Letter_04 (Sealed letter)

2. **Color Coding:**
   - Mail items: Light blue tint `|cff87ceeb` (sky blue)
   - Mail count: `|cff00bfff` (deep sky blue)
   - Priority indicator: `|cff00ff00` (green) when can fulfill from mail

3. **Sorting Priority:**
   - Requests with items in mail should sort higher
   - Option to filter "Items in Mail"

### Performance Considerations

1. **Mail Scanning:**
   - Only scan when mailbox is open (no polling)
   - Cache results until next mailbox open
   - Use delta sync to broadcast changes efficiently

2. **Mail Data Age:**
   - Show age of last mail scan (e.g., "Last scanned: 2 hours ago")
   - Mail data persists indefinitely like bank/bags data
   - Age is informational only, does not affect functionality

3. **Memory Impact:**
   - Mail has max 50 slots, typically 1-12 items
   - Minimal memory overhead (< 5KB per alt with full mail)

## Edge Cases

### Edge Case 1: Mail Expires
**Problem:** Items in mail for 30 days, expire before retrieval
**Solution:** Show days remaining in tooltip, highlight urgent (<3 days) in red

### Edge Case 2: Stale Mail Data
**Problem:** Mail data from yesterday, items already taken
**Solution:** Show age of scan. Mail data persists indefinitely like bank/bags data. User must rescan mailbox to update if items are taken.

### Edge Case 3: Multiple Bankers
**Problem:** Two bankers both have requested items in mail
**Solution:** Show all sources with mail counts, let requester choose

### Edge Case 4: Mail Inbox Changes
**Problem:** Taking/deleting items while mailbox is open
**Solution:** Scan on MAIL_CLOSED captures final state (same as bank)

### Edge Case 5: Offline Mail Scan
**Problem:** Banker logs out, guild can't see their mail
**Solution:** Broadcast last mail scan via delta sync, show age in UI

## Implementation Plan

### Phase 1: Data Collection (Week 1)
- [ ] Add `mail` field to alt data structure
- [ ] Add `hasUpdated` flag to Mail module
- [ ] Implement `ScanMailInventory()` in Mail.lua
- [ ] Update `Bank:Scan()` to call mail scanning
- [ ] Add MAIL_SHOW event handler (set hasUpdated flag)
- [ ] Add MAIL_CLOSED event handler (triggers scan via Bank:OnUpdateStop)
- [ ] Update `ComputeInventoryHash()` to include mail data
- [ ] Test mail scanning with various mail contents

### Phase 2: Core API (Week 2)
- [ ] Implement `GetItemsWithMail()` in Item.lua
- [ ] Implement `CheckMailFulfillment()` in RequestLog.lua
- [ ] Add mail inventory to `GetInventorySummary()`
- [ ] Test API functions with mock data

### Phase 3: UI - Inventory Display (Week 3)
- [ ] Update Inventory.lua tooltip to show mail items
- [ ] Add mail section to inventory status bar
- [ ] Update Search.lua to include mail results
- [ ] Add "Mail" column/indicator to search results
- [ ] Test inventory display with mail data

### Phase 4: UI - Request Indicators (Week 4)
- [ ] Add mail icon to request rows
- [ ] Implement mail icon tooltip
- [ ] Add "Items in Mail" filter option
- [ ] Sort requests with mail items higher
- [ ] Test request UI with various scenarios

### Phase 5: Testing & Polish (Week 5)
- [ ] Test full workflow: mail → scan → display → fulfill
- [ ] Test edge cases (expired mail, stale data, etc.)
- [ ] Performance testing with 50 mail items
- [ ] UI polish (colors, icons, tooltips)
- [ ] Verify delta sync includes mail data automatically
- [ ] Documentation updates

## Testing Scenarios

### Test 1: Basic Mail Scan
1. Send 10 different items to banker (50 total stacks)
2. Open mailbox
3. Verify all items appear in mail inventory
4. Close mailbox, verify data persists
5. Reopen, verify update triggers

### Test 2: Request Fulfillment
1. Create request for 50 Iron Ore
2. Mail 50 Iron Ore to banker
3. Open banker's mailbox
4. Verify request shows mail icon
5. Verify tooltip shows "50 available in mail"

### Test 3: Delta Sync
1. Banker opens mailbox (triggers scan)
2. Verify `alt.mail` data updated locally
3. Verify standard delta sync broadcasts to guild
4. Guild members receive delta and see updated inventory
5. Take items from mail, verify delta sync updates

### Test 4: Search Integration
1. Search for "Iron Ore"
2. Verify results show bank, bags, AND mail locations
3. Verify mail results have ✉ icon
4. Click mail result, verify tooltip shows mail details

### Test 5: Mail Data Persistence
1. Scan mail at time T
2. Wait 25 hours
3. Verify UI shows age ("25 hours ago")
4. Verify mail data still displays (persists indefinitely)

## Open Questions

1. **Should we auto-take items from mail for fulfillment?**
   - Pro: Fully automated workflow
   - Con: Dangerous (could take wrong items, lose mail)
   - **Decision:** No auto-take, just show indicator. Manual retrieval safer.

2. **Should mail count toward "available" in search?**
   - Pro: More accurate inventory counts
   - Con: Items not immediately accessible
   - **Decision:** Yes, but mark as "In Mail" with icon

3. **How to handle COD mail?**
   - COD items can't be taken without payment
   - **Decision:** Exclude COD items from inventory (check CODAmount > 0)

4. **Should we track mail sender?**
   - Useful for donations/tracking
   - Adds data complexity
   - **Decision:** Yes, store sender in sources array

5. **Filter expired mail?**
   - Mail <1 day left is risky to count
   - **Decision:** Show warning for <3 days, highlight urgent

## Future Enhancements

1. **Mail History:**
   - Track items received via mail over time
   - Show donation statistics by sender

2. **Auto-Fulfill from Mail:**
   - Advanced feature: macro to take items and fulfill in one click
   - Requires careful testing and safeguards

3. **Mail Notifications:**
   - Alert bankers when requested items arrive in mail
   - Push notification system

4. **Mail Forwarding:**
   - Forward mail from one banker to another
   - Route items to correct banker automatically

## Success Metrics

1. **Functionality:**
   - ✅ Mail inventory visible in UI
   - ✅ Request indicators show when items in mail
   - ✅ Search includes mail results
   - ✅ Mail data syncs via existing delta system

2. **Performance:**
   - Mail scan completes in <100ms for full mailbox
   - No frame rate impact when mailbox opens
   - Mail data uses existing delta sync (no additional bandwidth)

3. **User Experience:**
   - Bankers can see mail inventory at a glance
   - Requesters know when items are ready
   - Clear visual indicators (icons, colors)
   - Tooltips provide detailed information

## References

- WoW API: [GetInboxHeaderInfo](https://wowpedia.fandom.com/wiki/API_GetInboxHeaderInfo)
- WoW API: [GetInboxItem](https://wowpedia.fandom.com/wiki/API_GetInboxItem)
- WoW API: [MAIL_SHOW Event](https://wowpedia.fandom.com/wiki/MAIL_SHOW)
- WoW API: [MAIL_INBOX_UPDATE Event](https://wowpedia.fandom.com/wiki/MAIL_INBOX_UPDATE)
- Classic Era: Mail slots = 50, max 30 days retention
