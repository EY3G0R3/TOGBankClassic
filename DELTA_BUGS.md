# Delta Implementation Bug Tracker

**Project:** TOGBankClassic v0.7.0 Delta Sync Protocol  
**Last Updated:** January 17, 2026  
**Status:** Testing Phase

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

## Active Bugs

### 🔴 CRITICAL

#### ✅ [DELTA-001] Tests.lua NewModule initialization failure

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

#### ⏳ [TEST-001] Unit tests need adjustment for actual implementation

**Severity:** 🟡 MEDIUM  
**Category:** Testing  
**Reporter:** Testing Team  
**Date Reported:** 2026-01-17  
**Status:** Open  
**Assigned To:** Development Team

**Description:**
The automated test suite (/togbank test) has 17/25 tests failing because the test code was written against a different function signature than what was actually implemented.

**Test Results:**
- Phase 5.1 Delta Computation: 0/6 passed
- Phase 5.2 Size Estimation: 4/4 passed ✓
- Phase 5.3 Protocol Negotiation: 1/3 passed
- Phase 5.4 Error Handling: 1/5 passed
- Phase 5.5 Integration: 0/2 passed
- Phase 5.6 Backwards Compatibility: 2/3 passed

**Total: 8/25 passed (32%)**

**Root Cause:**
Tests were written expecting:
- `ComputeDelta(oldData, newData, version)` 

But actual implementation is:
- `ComputeDelta(name, currentAlt)` - retrieves snapshot from database internally

Similar mismatches exist for other functions.

**Impact:**
Automated tests cannot validate delta sync functionality. Manual testing required.

**Workaround:**
Proceed with manual testing per TESTING.md until unit tests are rewritten.

**Notes:**
- Size estimation tests (4/4) work correctly
- Some integration tests work
- Core delta functionality is implemented and can be manually tested
- Tests need complete rewrite to match actual API

*No other medium priority bugs reported*

---

### 🟢 LOW

*No low priority bugs reported*

---

## Resolved Bugs

### ✅ FIXED

*No bugs fixed yet - initial release*

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

4. **30% Size Threshold** - Large changes (>30%) fall back to full sync
   - Severity: 🟢 LOW
   - Reason: Delta larger than full sync wastes bandwidth
   - Workaround: None needed, automatic fallback works

---

## Testing Status

Track which test suites have been executed and results:

| Test Suite | Status | Date Tested | Tester | Result | Notes |
|------------|--------|-------------|--------|--------|-------|
| 1. Basic Delta Sync | ⏳ Pending | - | - | - | - |
| 2. Error Handling | ⏳ Pending | - | - | - | - |
| 3. Protocol Negotiation | ⏳ Pending | - | - | - | - |
| 4. Performance & Metrics | ⏳ Pending | - | - | - | - |
| 5. User Commands | ⏳ Pending | - | - | - | - |
| 6. Edge Cases | ⏳ Pending | - | - | - | - |
| 7. Stress Testing | ⏳ Pending | - | - | - | - |
| 8. Integration | ⏳ Pending | - | - | - | - |

**Status Legend:**
- ⏳ Pending - Not yet tested
- 🔄 In Progress - Currently testing
- ✅ Passed - All tests passed
- ⚠️ Issues Found - Some tests failed, bugs reported
- ❌ Blocked - Cannot test due to dependency

---

## Bug Statistics

**Total Bugs:** 5  
**Critical:** 0 (3 fixed)  
**High:** 0 (1 fixed)  
**Medium:** 1 (open)  
**Low:** 0  
**Fixed:** 4  
**Open:** 1  

**By Category:**
- Delta Computation: 0
- Delta Application: 0
- Protocol Negotiation: 0
- Communication: 0
- Error Handling: 1 (fixed)
- Performance: 0
- Metrics: 0
- UI/Commands: 0
- Database: 0
- Backwards Compatibility: 1 (fixed)
- Module Initialization: 3 (fixed)

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

