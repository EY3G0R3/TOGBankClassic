# TOGBankClassic Testing Scenarios

## P2P-023: Hash-List Broadcast Collision Guard

**Test Objective:** Verify `hashBroadcastInProgress` flag prevents concurrent hash-list broadcasts from same sender, eliminating INTEGRITY-MISMATCH errors.

### TC-001: Periodic Timer Does Not Stack Sends (BULK Priority)
**Setup:** Banker with 36 bank alts, periodic `OnShareTimer` active (3-minute cycle).
**Steps:**
1. Wait for `OnShareTimer` to fire → observe "Broadcasting hash-list" in debug log
2. Note current time in debug log (broadcast started)
3. Within 15 seconds, manually trigger `/togbank share` (or wait for next timer tick if debugging with accelerated timer)
4. Check debug output for "COLLISION-GUARD" message

**Expected:**
- First broadcast sets `hashBroadcastInProgress = true`
- Second broadcast (BULK priority) logs `"Skipped BULK hash-list broadcast (previous broadcast in progress)"` and returns early
- No INTEGRITY-MISMATCH errors on any guild members
- 15 seconds after first broadcast, flag clears
- Next periodic timer proceeds normally

**Validation:**
- `/togbank deltastats` shows `hashBroadcastBlocked > 0` if collision occurred
- Debug log contains "Skipped BULK" message
- No CRC failures in guild members' debug logs

---

### TC-002: Manual HashUpdate Defers If Timer In Progress (NORMAL Priority)
**Setup:** Banker logged in with active guild, periodic timer recently fired (broadcast in progress).
**Steps:**
1. Trigger periodic broadcast via `/togbank share` or wait for `OnShareTimer`
2. Immediately (within 5 seconds) run `/togbank hashupdate`
3. Observe Info message in chat
4. Wait 16 seconds
5. Check debug log for retry execution

**Expected:**
- Manual `HashUpdate` detects `hashBroadcastInProgress = true`
- User sees Info message: `"Hash broadcast already in progress - deferring command for 16 seconds..."`
- After 16-second defer, command retries automatically
- If flag still set after retry, defers again (up to 3 total retries)
- After 3 retries (48s total), forces through

**Validation:**
- No INTEGRITY-MISMATCH errors
- `/togbank deltastats` shows `hashBroadcastBlocked >= 1`
- Manual broadcast eventually completes (visible in guild members' debug logs)

---

### TC-003: Login Broadcast Works During Zone-In Cooldown (NORMAL Priority)
**Setup:** Logout, wait 30 seconds, log back in as banker.
**Steps:**
1. Log in and immediately check debug output
2. Observe GUILD_ROSTER_UPDATE handler execution
3. Look for `SyncDeltaVersion("NORMAL")` call after roster init
4. Verify broadcast completes despite PERF-021 zone-in cooldown

**Expected:**
- GUILD_ROSTER_UPDATE triggers `SyncDeltaVersion("NORMAL")` after roster refresh completes
- NORMAL priority bypasses zone-in cooldown (only BULK blocked during cooldown)
- Hash-list broadcast succeeds within 2-3 seconds of login
- Guild members receive hash-list and offer P2P data if they have fresher inventory

**Validation:**
- Guild members see "HLR pending" for this banker within 5 seconds of login
- No 10-minute delay before first P2P sync
- Debug log shows "Broadcasting hash-list" shortly after roster init

---

### TC-004: Flag Timeout Clears After 15 Seconds
**Setup:** Banker with hash broadcast capability.
**Steps:**
1. Trigger hash broadcast via `/togbank hashupdate`
2. Observe `hashBroadcastInProgress = true` set in debug log (requires manual debug print or breakpoint)
3. Wait exactly 15 seconds
4. Trigger another broadcast via `/togbank hashupdate`
5. Verify second broadcast proceeds immediately without defer

**Expected:**
- First broadcast sets flag to true
- 15-second timer fires and clears flag to false
- Second broadcast finds flag = false and proceeds without collision guard blocking
- Both broadcasts complete successfully

**Validation:**
- No "deferring command" Info message on second broadcast
- No "Skipped BULK" or collision guard debug logs for second send
- `/togbank deltastats` shows `hashBroadcastCount = 2, hashBroadcastBlocked = 0`

---

### TC-005: Forced Send After Max Retries (NORMAL Priority)
**Setup:** Simulate stuck flag scenario (manually set `TOGBankClassic_Events.hashBroadcastInProgress = true` in console, or use very long message + rapid commands).
**Steps:**
1. Set `hashBroadcastInProgress = true` manually via `/run TOGBankClassic_Events.hashBroadcastInProgress = true`
2. Run `/togbank hashupdate` (NORMAL priority)
3. Wait 16 seconds (retry 1) → 16 seconds (retry 2) → 16 seconds (retry 3)
4. After 48 seconds total, observe force-through behavior

**Expected:**
- First attempt: defers with "retry 1/3"
- Second attempt (T+16s): defers with "retry 2/3"
- Third attempt (T+32s): defers with "retry 3/3"
- Fourth attempt (T+48s): logs "Forcing NORMAL hash-list broadcast after 3 retries" and sends despite flag

**Validation:**
- Debug log shows progression: retry 1 → retry 2 → retry 3 → forcing
- Message eventually transmits after 48s
- No infinite defer loop

---

### TC-006: Telemetry Displays Collision Statistics
**Setup:** Banker with collision guard active, trigger at least one collision.
**Steps:**
1. Trigger hash broadcast collision (TC-001 or TC-002 scenario)
2. Run `/togbank deltastats`
3. Locate "Protocol Health" section in output

**Expected:**
- New line appears: `"Hash broadcasts: X sent, Y blocked (Z% collision rate)"`
- X = total successful broadcasts (`hashBroadcastCount`)
- Y = total blocked attempts (`hashBroadcastBlocked`)
- Z = Y / (X + Y) × 100
- Formatted with existing TOGBankClassic color scheme

**Validation:**
- Line displays correct counters
- Collision rate calculation accurate (if 1 blocked out of 10 total attempts → 10.0%)
- Counters persist across `/reload` (stored in Events.lua module state, not SavedVariables)

---

### TC-007: Multiple Bankers Can Broadcast Simultaneously
**Setup:** 2+ bankers online in same guild.
**Steps:**
1. Banker A triggers `/togbank hashupdate`
2. Banker B triggers `/togbank hashupdate` within 5 seconds
3. All guild members observe their debug logs

**Expected:**
- Banker A's broadcast completes successfully
- Banker B's broadcast completes successfully
- NO collision guard activation (different sender = different spool key)
- Guild members receive both hash-lists correctly (may batch via PERF-020 0.15s window)

**Validation:**
- No INTEGRITY-MISMATCH errors on any receiver
- Both bankers' hash-lists appear in receivers' debug logs
- Each banker's `hashBroadcastBlocked` remains 0 (no self-collision)

---

### TC-008: Backwards Compatibility With Unfixed Clients
**Setup:** Fixed banker broadcasts to guild with mix of fixed/unfixed clients.
**Steps:**
1. Fixed banker triggers hash broadcast (no concurrent sends)
2. Old unpatched client receives message
3. Fixed banker triggers concurrent broadcasts (via collision scenario)
4. Old unpatched client observes

**Expected:**
- Old clients receive normal broadcasts correctly (no protocol changes)
- Fixed sender's collision guard prevents corruption from reaching ANY receiver
- Old clients do NOT benefit when they send concurrent broadcasts (sender-side fix only)
- Mixed environment degrades gracefully: fixed senders = zero corruption, unfixed senders = still corrupt on collision

**Validation:**
- Old clients see no new error types (no breaking changes)
- Fixed banker's broadcasts never produce INTEGRITY-MISMATCH on any receiver
- Unfixed banker concurrent sends still produce CRC errors (expected, not regressed)

---

## Test Execution Log

| TC-ID | Date | Tester | Result | Notes |
|-------|------|--------|--------|-------|
| TC-001 | - | - | Not Tested | Periodic timer collision (BULK skip) |
| TC-002 | - | - | Not Tested | Manual command defer+retry (NORMAL) |
| TC-003 | - | - | Not Tested | Login broadcast during zone cooldown |
| TC-004 | - | - | Not Tested | 15s timeout clears flag |
| TC-005 | - | - | Not Tested | Force-through after 3 retries |
| TC-006 | - | - | Not Tested | Telemetry display in deltastats |
| TC-007 | - | - | Not Tested | Multi-banker simultaneous send (no collision) |
| TC-008 | - | - | Not Tested | Backwards compatibility validation |

---

