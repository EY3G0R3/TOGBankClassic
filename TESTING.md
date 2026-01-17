# TOGBankClassic v0.7.0 Testing Guide

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

### Test 1.2: Small Change Delta
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

## Test Suite 2: Error Handling & Recovery

### Test 2.1: Version Mismatch Recovery
**Objective:** Verify automatic recovery from version mismatch

**Steps:**
1. Use `/togbank clearsnapshots` to clear all snapshots
2. Manually corrupt version data (development only)
3. Attempt delta sync
4. Observe error handling

**Expected Result:**
- "Version mismatch" error logged
- Automatic QueryAlt triggered
- Full sync requested and received
- Error recorded in deltaMetrics
- Normal operation resumes

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

### Test 5.1: All New Commands Work
**Objective:** Verify each new command functions correctly

**Tests:**
```
/togbank deltastats     → Shows statistics with no errors
/togbank protocol       → Shows protocol distribution
/togbank clearsnapshots → Clears snapshots with confirmation
/togbank forcefull      → Toggles full sync mode
/togbank resetmetrics   → Resets metrics to zero
```

**Expected Result:**
- Each command executes without errors
- Output is formatted correctly with colors
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

