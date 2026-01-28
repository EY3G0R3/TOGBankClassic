# [FULFILL-002] Fulfill button callback not updating after split completion

**Severity:** 🟠 HIGH
**Category:** Order Fulfillment / UI
**Reporter:** User (Testing)
**Date Reported:** 2026-01-27
**Date Resolved:** 2026-01-27
**Status:** ✅ RESOLVED
**Reproducibility:** Was Consistent

## Description

When fulfilling a request that requires splitting:
1. User has single partial stack of 9 items in inventory
2. Requester wants 1 item
3. User opens mail, then opens Requests window
4. Split button (scissors icon) appears correctly
5. User clicks split button, gets 1 item split into inventory
6. Button icon changes to envelope (correct visual update)
7. **BUG:** Clicking the envelope button triggers split popup again instead of attaching items to mail

## Expected Behavior

After split completes and button changes to envelope icon, clicking should call `PrepareFulfillMail()` to attach items.

## Actual Behavior

Button visual updates but onClick handler still points to split popup logic.

## Root Cause

The issue was in the greedy stack allocation algorithm in `PrepareFulfillMail()`:

1. **First-pass accumulation logic**: When calculating which stacks to use, the algorithm accumulated only stacks >= 50% of the largest stack size to determine if a split was needed
2. **Minimum stack size filter**: After determining a split amount, it set `minStackSize = wouldNeedToSplit > 0 and wouldNeedToSplit or 5`
3. **The bug**: When needing only 1 item from a stack of 9:
   - Split 1 item, creating stacks [8, 1]
   - Algorithm filtered useful stacks with `minStackSize = 5` (default when no split needed)
   - Stack of 1 was filtered OUT as "too small"
   - Algorithm only saw stack of 8, marked it for splitting again
   - Button icon changed to envelope, but clicking still triggered split popup

4. **Second issue**: The greedy algorithm processed stacks in a single pass, marking splits before checking if smaller exact-fit stacks existed later in the list

## Solution

Two-part fix implemented in `Modules/Mail.lua`:

### Fix 1: Minimum Stack Size Calculation (Line 591)
Changed from:
```lua
local minStackSize = wouldNeedToSplit > 0 and wouldNeedToSplit or 5
```

To:
```lua
local minStackSize = wouldNeedToSplit > 0 and wouldNeedToSplit or math.min(5, qtyNeeded)
```

This ensures that when needing only 1 item, a stack of 1 is not filtered out as "too small".

### Fix 2: Two-Stage Greedy Algorithm (Lines 608-633)
Changed from single-pass greedy to two-stage:

**Stage 1**: Accumulate all stacks that fit exactly without exceeding qtyNeeded
```lua
for i, item in ipairs(usefulStacks) do
    if simulatedAttached >= qtyNeeded then break end
    local remaining = qtyNeeded - simulatedAttached
    if item.count <= remaining then
        simulatedAttached = simulatedAttached + item.count
    end
end
```

**Stage 2**: Only if still need more, look for a stack to split
```lua
if simulatedAttached < qtyNeeded then
    local remaining = qtyNeeded - simulatedAttached
    for i, item in ipairs(usefulStacks) do
        if item.count >= remaining then
            skippedLargeStack = item
            splitStackIndex = i
            break
        end
    end
end
```

This ensures exact-fit stacks are always preferred over splitting.

### Bonus: Debug System Migration
Moved all `print("[SPLIT DEBUG] ...")` statements to proper debug system:
```lua
TOGBankClassic_Output:Debug("FULFILL", message, ...)
```

This integrates fulfillment debugging with the existing persistent debug log system.

## Testing Results

**Before Fix:**
```
[SPLIT DEBUG] Need 1, accumulated 8 from large stacks, would split 0
[SPLIT DEBUG] Filtered 1 useful stacks from 2 total (min size: 5)  ← Stack of 1 filtered out!
[SPLIT DEBUG] Stack 1: count=8, can split (need 1), mark as candidate
[SPLIT DEBUG] Greedy result: attached=0, splitStackIndex=1
```

**After Fix:**
```
Need 1, accumulated 8 from large stacks, would split 0
Filtered 2 useful stacks from 2 total (min size: 1)  ← Stack of 1 included!
Stack 2: count=1, accumulate, total=1
Accumulated enough - no split needed
Greedy result: attached=1, splitStackIndex=nil
```

## Verification Steps

1. ✅ Create request for 1 item
2. ✅ Bank alt has single stack of 9 items
3. ✅ Open mailbox, open Requests window - scissors button appears
4. ✅ Click scissors button - split dialog appears
5. ✅ Split 1 item - creates stacks [8, 1]
6. ✅ Button changes to envelope icon
7. ✅ Click envelope button - items attach to mail (no split popup!)
8. ✅ Click Send - request fulfilled

## Files Modified

- `Modules/Mail.lua` (lines 591, 608-633) - Fixed greedy algorithm and minimum stack size
- `Modules/Mail.lua` (lines 603-604, 621, 629, 632-633) - Migrated debug to proper system
- `docs/FULFILL-002.md` - This ticket
