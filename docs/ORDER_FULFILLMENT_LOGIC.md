# Order Fulfillment Logic - End to End

**Last Updated:** January 27, 2026
**Status:** In Development - Greedy algorithm needs refinement

---

## Overview

When a banker clicks the "Fulfill" button on a pending request, the addon determines:
1. Whether the request can be fulfilled
2. Whether manual stack splitting is needed
3. Which specific stacks to attach to mail

This document details the complete flow from button click to mail preparation.

---

## Entry Points

### 1. Fulfill Button Click
**File:** `Modules/UI/Requests.lua:1180-1195`

When banker clicks fulfill button:
```lua
fulfillButton:SetCallback("OnClick", function()
    local success, message, attachedCount = TOGBankClassic_Mail:PrepareFulfillMail(req)
    if success then
        -- Mail prepared successfully
        self.Window:SetStatusText(string.format("Attached %d items. Send mail to complete.", attachedCount))
    else
        -- Need to split or error occurred
        self.Window:SetStatusText(message)
    end
end)
```

### 2. Tooltip Calculation
**File:** `Modules/Mail.lua:395-510`

Before button is even shown, `CanFulfillRequest()` determines button state:
- Returns `(true, nil, ...)` → Show envelope icon (can fulfill without split)
- Returns `(true, "Split X...", ...)` → Show scissors icon (needs split)
- Returns `(false, "Need X more", ...)` → Gray out button (insufficient items)

---

## The Problem: Using Stack of 1 in Greedy Algorithm

### Current Behavior (WRONG)
Given: **5 stacks: [1, 20, 20, 20, 20]** needing **90 items**

**Current greedy algorithm:**
1. Sort largest first: `[20, 20, 20, 20, 1]`
2. Accumulate: `20 + 20 + 20 + 20 = 80`
3. Remaining: `90 - 80 = 10`
4. Check stack of 1: Can't provide 10, ignore it
5. Result: **Use 4×20 stacks + split 10 from a 5th stack of 20**

**What actually happens in WoW:**
- Banker has to manually pick up stack of 1
- Banker has to manually attach it to mail
- Then split dialog appears asking to split 9 (not 10!)
- **Wrong:** Uses `[20, 20, 20, 20, 1] + split 9`

### Desired Behavior (CORRECT)
**Should be:**
1. Ignore stack of 1 entirely from greedy calculation
2. Accumulate only useful stacks: `20 + 20 + 20 + 20 = 80`
3. Remaining: `90 - 80 = 10`
4. Result: **Use 4×20 stacks + split 10 from a 5th stack of 20**

**What should happen in WoW:**
- Split dialog appears asking to split 10
- After split, banker has exactly 90 items ready to attach
- **Correct:** Uses `[20, 20, 20, 20] + split 10`

---

## Current Implementation Flow

### Phase 1: Tooltip Calculation (`CanFulfillRequest`)
**Purpose:** Determine button icon/state without side effects

```
┌─────────────────────────────────────────┐
│ 1. Count total items in bags           │
│    - Returns 0 if none found           │
└─────────────────────────────────────────┘
                ↓
┌─────────────────────────────────────────┐
│ 2. Sort items by stack size            │
│    - Largest first (20, 20, 20, 20, 1) │
└─────────────────────────────────────────┘
                ↓
┌─────────────────────────────────────────┐
│ 3. Find usable items (greedy smallest) │
│    - Only count stacks that fit exactly │
│    - usableItems = stacks that won't    │
│      exceed qtyNeeded                   │
└─────────────────────────────────────────┘
                ↓
┌─────────────────────────────────────────┐
│ 4. Try skipping individual small stacks │
│    - Look for exact match combinations  │
│    - Skip up to 5 stacks to find fit   │
└─────────────────────────────────────────┘
                ↓
┌─────────────────────────────────────────┐
│ 5. Check if split needed                │
│    - If usableItems < needed AND        │
│      totalInBags >= needed              │
│    - Return split message               │
└─────────────────────────────────────────┘
                ↓
┌─────────────────────────────────────────┐
│ 6. Return result                        │
│    - (true, nil) = can fulfill          │
│    - (true, "Split X") = need split     │
│    - (false, msg) = insufficient        │
└─────────────────────────────────────────┘
```

### Phase 2: Mail Preparation (`PrepareFulfillMail`)
**Purpose:** Actually attach items or show split dialog

```
┌─────────────────────────────────────────┐
│ 1. Validate preconditions              │
│    - Mailbox open?                      │
│    - Request valid?                     │
│    - Mail already has items?            │
└─────────────────────────────────────────┘
                ↓
┌─────────────────────────────────────────┐
│ 2. Set mail recipient                   │
│    - SendMailNameEditBox:SetText()      │
└─────────────────────────────────────────┘
                ↓
┌─────────────────────────────────────────┐
│ 3. Sort items with stable sort          │
│    - Add originalIndex to each item     │
│    - Sort by count (largest first)      │
│    - Maintain physical bag order        │
└─────────────────────────────────────────┘
                ↓
┌─────────────────────────────────────────┐
│ 4. FIRST PASS: Filter useful stacks    │
│    - Remove stacks too small to split   │
│    - Keep only stacks that can:         │
│      a) Be fully attached, OR           │
│      b) Provide remaining amount        │
└─────────────────────────────────────────┘
                ↓
┌─────────────────────────────────────────┐
│ 5. SECOND PASS: Greedy algorithm       │
│    - Accumulate stacks that fit         │
│    - Mark split candidate if needed     │
│    - Clear split if accumulated enough  │
└─────────────────────────────────────────┘
                ↓
┌─────────────────────────────────────────┐
│ 6. Check if split needed                │
│    - If skippedLargeStack exists:       │
│      Show split popup dialog            │
│      Return (false, message, 0)         │
└─────────────────────────────────────────┘
                ↓
┌─────────────────────────────────────────┐
│ 7. Attach items to mail                 │
│    - Loop through useful stacks         │
│    - PickupContainerItem() + ClickSend  │
│    - Stop when qtyNeeded reached        │
└─────────────────────────────────────────┘
                ↓
┌─────────────────────────────────────────┐
│ 8. Return success                       │
│    - Return (true, nil, attachedCount)  │
└─────────────────────────────────────────┘
```

---

## The Issue: Useful Stacks Filter

### Current Filter Logic (Lines 568-593)
```lua
-- FIRST PASS: Determine what we need and filter out stacks that are too small to be useful
local usefulStacks = {}
local accumulatedForFilter = 0
for i, item in ipairs(items) do
    if accumulatedForFilter >= qtyNeeded then
        -- We have enough - check if this stack could be used for splitting
        local remaining = qtyNeeded - accumulatedForFilter
        if remaining > 0 and item.count >= remaining then
            table.insert(usefulStacks, item)
        end
        -- Otherwise ignore this stack (too small to split)
    elseif item.count <= qtyNeeded - accumulatedForFilter then
        -- This stack can be fully attached
        table.insert(usefulStacks, item)
        accumulatedForFilter = accumulatedForFilter + item.count
    else
        -- This stack is larger than what we need - check if it can provide the full remaining amount
        local remaining = qtyNeeded - accumulatedForFilter
        if item.count >= remaining then
            table.insert(usefulStacks, item)
        end
        -- Otherwise ignore (too small to split the remaining amount)
    end
end
```

**Problem:** This filter is complex and still includes small stacks that shouldn't be in greedy calculation.

### Example Walkthrough: [20, 20, 20, 20, 1] need 90

**Filter Pass:**
1. `accumulatedForFilter = 0`, stack 20: `20 <= (90-0)` → Add to useful, accumulated = 20
2. `accumulatedForFilter = 20`, stack 20: `20 <= (90-20)` → Add to useful, accumulated = 40
3. `accumulatedForFilter = 40`, stack 20: `20 <= (90-40)` → Add to useful, accumulated = 60
4. `accumulatedForFilter = 60`, stack 20: `20 <= (90-60)` → Add to useful, accumulated = 80
5. `accumulatedForFilter = 80`, stack 1: `1 <= (90-80)` → **Add to useful**, accumulated = 81

**Result:** `usefulStacks = [20, 20, 20, 20, 1]` ← Stack of 1 is included!

**Greedy Pass:**
1. Stack 20: accumulate, total = 20
2. Stack 20: accumulate, total = 40
3. Stack 20: accumulate, total = 60
4. Stack 20: accumulate, total = 80
5. Stack 1: accumulate, total = 81
6. Need 90, have 81, remaining = 9
7. No stack can split 9 → Falls through to skip-stack logic

**Result:** Eventually uses `[20, 20, 20, 20, 1] + split 9` ❌

---

## Proposed Solution: Two-Stage Logic

### Stage 1: Pure Greedy (No Splits)
**Goal:** Find largest combination without splitting

```
1. Sort stacks largest first: [20, 20, 20, 20, 1]
2. Greedy accumulation (full stacks only):
   - Add 20: total = 20
   - Add 20: total = 40
   - Add 20: total = 60
   - Add 20: total = 80
   - Check 1: would exceed? No, but total < needed, continue
   - Add 1: total = 81
3. Check if exact match:
   - Need 90, have 81 → NOT exact, need split
```

### Stage 2: Smart Split Decision
**Goal:** Determine optimal split strategy

```
1. Calculate what's missing: 90 - 81 = 9
2. Find candidates for splitting:
   - Look for stacks >= 9 that we DIDN'T use yet
   - We used [20, 20, 20, 20, 1], have 1 stack of 20 left
3. Compare strategies:

   Strategy A: Use partials + small split
   - Use [20, 20, 20, 20, 1] + split 9 from remaining 20
   - Attachment slots: 5 stacks + 1 split = 6 operations

   Strategy B: Use fewer full stacks + larger split
   - Use [20, 20, 20, 20] + split 10 from remaining 20
   - Attachment slots: 4 stacks + 1 split = 5 operations

4. Choose Strategy B (fewer operations)
```

### Stage 3: Ignore Tiny Stacks Heuristic
**Goal:** Don't use stacks smaller than split amount

```
If we're going to split anyway:
- Ignore stacks smaller than (split amount - 5)
- Why? Using them creates MORE work:
  - Extra attachment slot used
  - Larger split amount needed later

Example: Need to split 10
- Stack of 1: IGNORE (creates split of 9)
- Stack of 8: IGNORE (creates split of 2)
- Stack of 9: MAYBE (creates split of 1)
- Stack of 10+: USE (exact or overflow to split)
```

---

## Revised Algorithm Pseudocode

```lua
function DetermineOptimalFulfillment(items, qtyNeeded)
    -- Sort largest first
    sort(items, descending by count)

    -- Stage 1: Pure greedy (try for exact match)
    local accumulated = 0
    local usedStacks = {}

    for stack in items do
        if accumulated >= qtyNeeded then
            break
        end

        if accumulated + stack.count <= qtyNeeded then
            -- This stack fits exactly or leaves room
            table.insert(usedStacks, stack)
            accumulated = accumulated + stack.count
        end
    end

    -- Check if exact match
    if accumulated == qtyNeeded then
        return { action = "ATTACH", stacks = usedStacks }
    end

    -- Stage 2: Determine if split is beneficial
    local remaining = qtyNeeded - accumulated
    local unusedStacks = items - usedStacks

    -- Find best split candidate from unused stacks
    local bestSplit = nil
    for stack in unusedStacks do
        if stack.count >= remaining then
            bestSplit = stack
            break  -- First one is best (largest first)
        end
    end

    if bestSplit then
        -- Stage 3: Check if we should ignore tiny stacks
        local tinyThreshold = remaining - 5
        local optimizedStacks = {}
        local optimizedTotal = 0

        for stack in usedStacks do
            if stack.count >= tinyThreshold or optimizedTotal + stack.count <= qtyNeeded then
                table.insert(optimizedStacks, stack)
                optimizedTotal = optimizedTotal + stack.count
            end
        end

        local optimizedRemaining = qtyNeeded - optimizedTotal

        -- Use optimized version if it's actually better
        if optimizedRemaining <= remaining + 5 then
            return {
                action = "SPLIT",
                stacks = optimizedStacks,
                splitFrom = bestSplit,
                splitAmount = optimizedRemaining
            }
        end
    end

    -- Fallback: use greedy result + split
    return {
        action = "SPLIT",
        stacks = usedStacks,
        splitFrom = bestSplit,
        splitAmount = remaining
    }
end
```

---

## Implementation Plan

### Step 1: Simplify Useful Stacks Filter
Remove complex filter logic, use simple "can this stack contribute?" check:

```lua
local usefulStacks = {}
for _, stack in ipairs(items) do
    -- Include if stack is meaningful (>= 5 items or we need it)
    if stack.count >= 5 or #usefulStacks < (qtyNeeded / 20) then
        table.insert(usefulStacks, stack)
    end
end
```

### Step 2: Pure Greedy Pass
Accumulate only stacks that fit within qtyNeeded:

```lua
local accumulated = 0
local usedStacks = {}

for _, stack in ipairs(usefulStacks) do
    if accumulated >= qtyNeeded then
        break
    end

    if accumulated + stack.count <= qtyNeeded then
        table.insert(usedStacks, stack)
        accumulated = accumulated + stack.count
    end
end
```

### Step 3: Split Decision (Separate)
Only consider splitting if greedy didn't get exact match:

```lua
if accumulated < qtyNeeded then
    local remaining = qtyNeeded - accumulated

    -- Find unused stacks that can provide remaining
    for _, stack in ipairs(usefulStacks) do
        if not isUsed(stack, usedStacks) and stack.count >= remaining then
            -- Show split dialog
            return SPLIT_NEEDED
        end
    end
end
```

### Step 4: Ignore Tiny Stacks Optimization
Before final decision, check if removing tiny stacks improves result:

```lua
local tinyThreshold = math.max(5, remaining - 5)
local withoutTiny = filterStacks(usedStacks, function(s)
    return s.count >= tinyThreshold
end)

if canSplitBetter(withoutTiny, qtyNeeded) then
    usedStacks = withoutTiny
    accumulated = sum(withoutTiny)
end
```

---

## Testing Scenarios

### Scenario 1: Exact Match (No Split Needed)
**Given:** `[20, 20, 20, 20, 10]` need 90
**Expected:** Use `[20, 20, 20, 20, 10]`, no split
**Result:** ✅ Attach 5 stacks, send mail

### Scenario 2: Simple Split (Ignore Tiny Stack)
**Given:** `[20, 20, 20, 20, 1]` need 90
**Expected:** Use `[20, 20, 20, 20]`, split 10 from 5th stack of 20
**Result:** ✅ Attach 4 stacks, split popup appears for 10

### Scenario 3: Complex Split Decision
**Given:** `[20, 20, 15, 10, 5, 3, 1]` need 50
**Expected:** Use `[20, 20]`, split 10 from next 15
**Result:** ✅ Don't use 5+3+1 (too many small stacks)

### Scenario 4: Borderline Tiny Stack
**Given:** `[20, 20, 20, 8]` need 70
**Expected:** Use `[20, 20, 20]`, split 10 from next 20
**Alternative:** Use `[20, 20, 20, 8]`, split 2 from next 20
**Decision:** First option (fewer operations)

---

## Current Status

- ✅ Stable sort implemented (preserves physical bag order)
- ✅ Split popup dialog working
- ✅ Basic greedy algorithm functional
- ⚠️ **NEEDS FIX:** Still including tiny stacks in greedy calculation
- ⚠️ **NEEDS FIX:** Filter is too complex and error-prone
- ❌ **NOT IMPLEMENTED:** Two-stage split decision logic
- ❌ **NOT IMPLEMENTED:** Tiny stack threshold heuristic

---

## Next Steps

1. **Simplify filter:** Remove complex accumulation logic from filter pass
2. **Pure greedy:** Implement clean greedy that only accumulates fitting stacks
3. **Split decision:** Separate logic to determine if/where/how-much to split
4. **Add threshold:** Don't use stacks smaller than (remaining - 5) when splitting needed
5. **Test all scenarios:** Verify with debug output showing decision process
