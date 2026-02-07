# Bug Report: 78% Delta Sync Failure Rate

**Severity:** 🔴 CRITICAL
**Category:** Delta Sync / Validation
**Reporter:** Investigation / Metrics Analysis
**Date Reported:** 2026-01-30
**Status:** ✅ FIXED
**Fixed In:** (pending commit)
**Branch:** main

---

## Summary

Delta sync showing 78% failure rate caused by overly strict validation rejecting valid link-less deltas (v0.8.0 bandwidth optimization feature) and logging of UNAUTHORIZED banker protection events.

---

## Observed Behavior

### Metrics
```
/togbank deltastats showed:
- 78% delta failure rate
- Repeated VALIDATION_FAILED errors
- Frequent UNAUTHORIZED rejection messages
```

### Error Log Output
```lua
TOGBankClassic_Guild:GetRecentDeltaErrors()
[1-10] errors showing:
  - 60% UNAUTHORIZED: "Rejected delta from [banker] about ourselves (banker is source of truth)"
  - 40% VALIDATION_FAILED: "invalid bank delta: added item missing or invalid Link"
```

---

## Root Cause Analysis

### Issue 1: Link Validation Too Strict (40% of errors)

**Location:** `Modules/DeltaComms.lua` lines 86-87, 101-102

**Problem:**
```lua
-- BEFORE (incorrect):
if not item.Link or type(item.Link) ~= "string" then
    return false, "added item missing or invalid Link"
end
```

The validation required `Link` to be present in `added` and `modified` items, but v0.8.0 introduced link-less deltas as a bandwidth optimization where receivers reconstruct links from item IDs.

**Evidence:**
- Comment at line 117 says "Link is optional in removed items (bandwidth optimization)"
- v0.8.0 features include link-less delta support (togbank-d3, togbank-d4)
- Validation was rejecting valid deltas that intentionally omitted links

### Issue 2: UNAUTHORIZED Logging (60% of errors)

**Location:** `Modules/DeltaComms.lua` lines 701, 716

**Problem:**
These are **working correctly** - banker protection is functioning as designed by rejecting deltas from other bankers about the local banker's own data. However, seeing these in the error log created confusion about the failure rate.

**Note:** These were **NOT** being counted in `deltasFailed` metrics (only logged), so they didn't actually inflate the failure percentage, but their presence in the error log suggested problems.

---

## Impact

### For Users
- **High perceived failure rate** causing concern about delta sync reliability
- **Legitimate link-less deltas rejected**, forcing unnecessary full syncs
- **Bandwidth optimization defeated** - link-less deltas couldn't be used

### For System
- Increased bandwidth usage (full syncs instead of deltas)
- Unnecessary full sync fallbacks
- Delta chain replay failures when link-less deltas in history

---

## Fix Implementation

### Change 1: Make Link Optional in Validation

**File:** `Modules/DeltaComms.lua`

**Lines 86-88 (added items):**
```lua
// BEFORE:
if not item.Link or type(item.Link) ~= "string" then
    return false, "added item missing or invalid Link"
end

// AFTER:
-- v0.8.0: Link is optional (bandwidth optimization - receiver reconstructs)
if item.Link and type(item.Link) ~= "string" then
    return false, "added item has invalid Link"
end
```

**Lines 101-103 (modified items):**
```lua
// BEFORE:
if not item.Link or type(item.Link) ~= "string" then
    return false, "modified item missing or invalid Link"
end

// AFTER:
-- v0.8.0: Link is optional (bandwidth optimization - receiver reconstructs)
if item.Link and type(item.Link) ~= "string" then
    return false, "modified item has invalid Link"
end
```

**Logic:**
- If `Link` is present, it must be a string (type validation)
- If `Link` is absent, that's acceptable (receiver will reconstruct)

### Change 2: Added Clarifying Comment

**File:** `Modules/Chat.lua` line ~912

Added comment explaining validation failure counting remains (now rare with optional Link).

---

## Testing Plan

### Pre-Fix Baseline
```
/togbank deltastats
Expected: ~78% failure rate
Expected: VALIDATION_FAILED errors in logs
```

### Apply Fix
1. Update `DeltaComms.lua` validation logic
2. Reload addon (`/reload`)
3. Reset metrics: `/togbank resetmetrics`

### Post-Fix Verification
1. **Monitor failure rate:**
   ```
   /togbank deltastats
   Expected: <5% failure rate (legitimate failures only)
   ```

2. **Check error logs:**
   ```lua
   /dump TOGBankClassic_Guild:GetRecentDeltaErrors()
   Expected: No VALIDATION_FAILED for missing Link
   Expected: UNAUTHORIZED still present (working correctly)
   ```

3. **Verify link-less deltas accepted:**
   - Trigger delta sync between clients
   - Confirm link-less deltas (togbank-d3) process successfully
   - Verify items display correctly with reconstructed links

4. **Bandwidth verification:**
   ```
   /togbank deltastats
   Check: Delta bytes should be smaller (links not transmitted)
   ```

---

## Expected Results

### Metrics Improvement
- **Before:** 78% delta failure rate
- **After:** <5% delta failure rate (only legitimate failures)

### Error Log
- **VALIDATION_FAILED for missing Link:** Should disappear completely
- **UNAUTHORIZED:** Will still appear (banker protection working correctly)
- Other error types (VERSION_MISMATCH, NO_DATA): May still occur legitimately

### System Behavior
- Link-less deltas accepted and processed
- Items display correctly with reconstructed links
- Bandwidth optimization functional
- Delta chain replay works with link-less deltas

---

## Related Issues

- **v0.8.0 Link-less Delta Feature:** This fix enables the bandwidth optimization
- **Delta Chain Replay:** Now works with link-less deltas in history
- **Bandwidth Metrics:** Will show accurate savings from link-less transmission

---

## Lessons Learned

1. **Validation must match features:** When adding bandwidth optimizations, update validation logic simultaneously
2. **Error logging context:** Distinguish between "errors" (problems) and "rejections" (working correctly)
3. **Test with metrics:** Monitor `/togbank deltastats` when implementing protocol changes
4. **Feature flags:** Consider feature flags for new protocol features during rollout

---

## Verification Checklist

- [x] Root cause identified (strict Link validation)
- [x] Fix implemented (Link now optional in validation)
- [x] Code review completed
- [ ] Tested with `/togbank resetmetrics` and monitoring
- [ ] Verified <5% failure rate post-fix
- [ ] Confirmed link-less deltas accepted
- [ ] Bandwidth savings verified in metrics
- [ ] Documentation updated

---

## Files Modified

- `Modules/DeltaComms.lua` - Made Link optional in item delta validation (lines ~86-88, ~101-103)
- `Modules/Chat.lua` - Added clarifying comment for validation failure counting (line ~912)

---

## Additional Notes

### Why This Wasn't Caught Earlier

The v0.8.0 link-less delta feature was implemented with send-side link stripping, but the receive-side validation wasn't updated to accept optional links. This created a mismatch where:
- Sender: Strips links to save bandwidth
- Receiver: Rejects deltas without links as "invalid"

### UNAUTHORIZED "Errors" Clarification

The UNAUTHORIZED rejections appearing in error logs are actually **banker protection working correctly**:
- Other bankers broadcast their data
- Local banker receives delta about themselves
- Protection correctly rejects it (banker is source of truth for own data)
- This is logged for debugging but **not counted as a failure**

Future improvement: Consider separate logging for "rejections" vs "failures" to reduce confusion.

---

## Commands for Testing

```bash
# Before fix - capture baseline
/togbank deltastats

# After fix - reset and monitor
/reload
/togbank resetmetrics
# ... wait for activity ...
/togbank deltastats
/dump TOGBankClassic_Guild:GetRecentDeltaErrors()
```
