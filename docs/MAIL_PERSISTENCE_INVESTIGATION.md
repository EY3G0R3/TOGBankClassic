# Mail Persistence Investigation

**Status:** 🟡 OPEN - Under Investigation
**Date Created:** 2026-01-29
**Priority:** High
**Affects:** Mail inventory feature visibility in UI

## Issue Summary

Items scanned from mail appear to be "disappearing" from the UI after logout/reload. Investigation revealed the data IS persisting correctly in SavedVariables, but there may be an issue with how mail items are displayed or aggregated in the UI.

## Background

The mail inventory feature was implemented to track items in a banker's mailbox and display them in the addon UI. Initial reports suggested mail data was not persisting through logout, but deeper investigation revealed:

1. ✅ Mail data IS being scanned correctly (44 items detected)
2. ✅ Mail data IS persisting to SavedVariables (`info.alts[player].mail`)
3. ❓ Mail items may not be showing up consistently in the UI
4. ❓ Original problem statement unclear - need to verify actual symptoms

## Investigation Timeline

### Initial Problem Statement
- User reported: "disappearing items in the UI that were loaded through the mail"
- Later clarified: Items were "always showing up in the UI"
- **UNCLEAR:** What exactly was the reproducible problem?

### Technical Findings

#### 1. SavedVariables Location (RESOLVED)
**Problem:** Was checking wrong account folder
**Root Cause:** WoW uses account-specific folders: `Account\981197530#1\` vs `Account\IANPLAMONDON\`
**Resolution:** Identified correct file location
**File:** `C:\Program Files (x86)\World of Warcraft\_classic_era_\WTF\Account\981197530#1\SavedVariables\TOGBankClassic.lua`

#### 2. Data Structure Fixes (COMPLETED)

**Fixed Issues:**
- ✅ `time()` → `GetServerTime()` - API compatibility for WoW Classic
- ✅ `mail.slots` structure changed from `number` to `{count, total}` table
- ✅ Mail scanning triggers correctly via MAIL_SHOW/MAIL_CLOSED events
- ✅ MailFrame OnHide hook added for event reliability

**Code Changes Made:**
```lua
-- BEFORE: mail.slots = 50
-- AFTER:  mail.slots = { count = 44, total = 50 }
```

#### 3. Persistence Verification (CONFIRMED WORKING)

**Confirmed:**
- Mail data writes to `info.alts[player].mail` structure
- Data persists through logout (file timestamp updates correctly)
- Structure includes:
  - `mail.items[]` - Array of mail items with ID, Count, Link
  - `mail.slots` - Table with count and total
  - `mail.version` - Timestamp
  - `mail.lastScan` - Timestamp

**Debug Output Confirms:**
```
>>> Calling Scan() <<<
>>> MailInventory: Created array with 44 items <<<
>>> MailInventory: result.slots.count=44 <<<
✓ Saved mail to info.alts[Booknlibram-Azuresong] (44 items)
>>> Scan() completed <<<
```

#### 4. Aggregate Merging (NEEDS VERIFICATION)

**Location:** `Modules/Guild.lua` lines 1246-1258
**Purpose:** Merge mail items into `bank.items` aggregate for backwards compatibility

**Current Code:**
```lua
-- Add or aggregate mail items into bank.items
for itemID, mailItem in pairs(alt.mail.items) do
    if existingBank[itemID] then
        -- Item exists in bank, add mail count to it
        existingBank[itemID].Count = (existingBank[itemID].Count or 0) + (mailItem.count or 0)
    else
        -- Item not in bank, add it as a new entry
        table.insert(alt.bank.items, { ID = itemID, Count = mailItem.count, Link = mailItem.link })
    end
end
```

**Potential Issue:**
- `alt.mail.items` is stored as an **array**: `[1] = {ID=123, Count=5}`
- Code iterates with `pairs()` which treats it as a dictionary
- When iterating array with pairs(), `itemID` gets array index (1,2,3...) not actual item ID
- This would cause items to be stored with wrong IDs in aggregate

**Status:** Reverted speculative fix - need to confirm if this is actually the problem

## Current State

### What's Working
✅ Mail scanning and detection (44 items found)
✅ Data persistence to SavedVariables
✅ Correct data structure in memory
✅ Event handling (MAIL_SHOW/MAIL_CLOSED)
✅ Debug logging throughout the flow

### What's Unclear
❓ Are mail items actually disappearing from UI?
❓ If so, under what conditions?
❓ Is the aggregate merge working correctly?
❓ Are there display/rendering issues in UI components?

### What Needs Testing
1. Open mailbox with items → close → check UI immediately
2. Open mailbox → close → /reload → check UI
3. Open mailbox → close → logout → login → check UI
4. Verify mail items show in inventory counts
5. Verify mail items show in search results
6. Check if aggregate merge is adding items correctly

## Files Modified

### Core Mail Implementation
- `Modules/MailInventory.lua` - Mail scanning logic (structure fixes)
- `Modules/Bank.lua` - Persistence to info.alts
- `Modules/Events.lua` - MAIL_SHOW/MAIL_CLOSED event handling
- `Modules/Database.lua` - Structure initialization

### Display/Aggregation (Potential Issues)
- `Modules/Guild.lua` - Merges mail items into bank.items aggregate
- `Modules/UI/Inventory.lua` - Displays inventory in UI
- `Modules/UI/Search.lua` - Search functionality

## Next Steps

### 1. Clarify Problem Statement
- [ ] Get reproducible test case from user
- [ ] Define "disappearing" - when exactly does it happen?
- [ ] Confirm: Does UI show mail items initially after scan?
- [ ] Confirm: Do items disappear after specific action?

### 2. Verify Aggregate Merge
- [ ] Add debug logging to Guild.lua line 1246 loop
- [ ] Check if loop iterates mail items correctly
- [ ] Verify items are added to bank.items with correct IDs
- [ ] Test with array vs dict iteration

### 3. Verify UI Display
- [ ] Check if UI components read from aggregate or raw mail data
- [ ] Verify inventory counts include mail items
- [ ] Check search functionality includes mail items
- [ ] Look for any filters that might hide mail items

### 4. Test Scenarios
Create systematic test:
```lua
1. Start fresh (no existing mail data)
2. Add items to mail
3. Open/close mailbox → Note UI state
4. /reload → Note UI state
5. Logout → Note UI state
6. Login → Note UI state
7. Document any point where items "disappear"
```

## Theories to Investigate

### Theory 1: Array/Dict Iteration Mismatch
**Hypothesis:** Guild.lua line 1246 treats array as dict, causing wrong IDs in aggregate
**Test:** Add debug logging to show itemID values during iteration
**Status:** Speculative - need to confirm aggregate is actually used for display

### Theory 2: UI Filter/Display Issue
**Hypothesis:** Mail items exist in data but UI component filters/hides them
**Test:** Check UI code for mail-specific filtering logic
**Status:** Not yet investigated

### Theory 3: Timing/Race Condition
**Hypothesis:** UI renders before mail data loads or aggregates
**Test:** Check initialization order and event sequencing
**Status:** Unlikely - data persists, so timing shouldn't matter on reload

### Theory 4: No Actual Bug
**Hypothesis:** User confusion about what "disappearing" means
**Test:** Get clear reproduction steps
**Status:** Possible - need clarification

## Documentation

### Data Flow
```
1. User opens mailbox
   ↓
2. MAIL_SHOW event → MailInventory.hasUpdated = true
   ↓
3. User closes mailbox
   ↓
4. MAIL_CLOSED event → Bank:OnUpdateStop()
   ↓
5. Bank:Scan() → MailInventory:Scan()
   ↓
6. Scan creates mail.items[] array with {ID, Count, Link}
   ↓
7. Bank:Scan() writes to info.alts[player].mail
   ↓
8. Guild.lua merges mail into bank.items aggregate (?)
   ↓
9. UI displays inventory (from aggregate? from raw?)
```

### Key Data Structures

**Raw Mail Structure** (`info.alts[player].mail`):
```lua
{
    items = {
        [1] = { ID = 21281, Count = 13, Link = "..." },
        [2] = { ID = 11737, Count = 2, Link = "..." },
        -- ... 44 total items
    },
    slots = { count = 44, total = 50 },
    version = 1769750000,
    lastScan = 1769750000
}
```

**Aggregate Structure** (`info.alts[player].bank.items`):
```lua
{
    [1] = { ID = 12345, Count = 100, Link = "..." },  -- Bank items
    [2] = { ID = 21281, Count = 13, Link = "..." },   -- Mail items merged?
    -- Combined bank + mail
}
```

## References

- Original Design: [MAIL_INVENTORY_DESIGN.md](MAIL_INVENTORY_DESIGN.md)
- Related: [DELTA_BUGS.md](DELTA_BUGS.md)
- Implementation Files:
  - [Modules/MailInventory.lua](../Modules/MailInventory.lua)
  - [Modules/Bank.lua](../Modules/Bank.lua)
  - [Modules/Guild.lua](../Modules/Guild.lua) (line 1246 - aggregate merge)

## Conclusion

**Current Status:** Investigation paused pending clarification of actual problem

**Confidence Level:**
- ✅ High confidence data persistence is working correctly
- ❓ Low confidence on actual UI visibility issue
- ❓ Need reproduction steps to proceed

**Recommendation:**
1. Get clear bug reproduction from user
2. Add debug logging to aggregate merge
3. Verify UI components show mail items
4. Only make changes after confirming actual problem

---

**Last Updated:** 2026-01-29
**Next Review:** After reproduction steps obtained
