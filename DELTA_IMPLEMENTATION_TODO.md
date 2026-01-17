# Delta Updates Implementation TODO

**Project:** TOGBankClassic Delta Sync Protocol  
**Target Version:** v0.7.0  
**Status:** Planning Phase  
**Last Updated:** January 17, 2026

---

## Phase 1: Foundation & Core Implementation

### 1.1 Constants & Configuration
- [ ] Add protocol version constants to `Modules/Constants.lua`
  - [ ] `PROTOCOL_VERSION = 2`
  - [ ] `SUPPORTS_DELTA = true`
  - [ ] `MIN_DELTA_SIZE_RATIO = 0.3`
  - [ ] `DELTA_SNAPSHOT_MAX_AGE = 3600` (1 hour)
- [ ] Add feature flags for easy enable/disable
  - [ ] `FEATURE_DELTA_ENABLED = true`
  - [ ] `FEATURE_FORCE_FULL_SYNC = false` (testing override)

### 1.2 Database Schema Updates
- [ ] Extend saved variables in `Modules/Database.lua`
  - [ ] Add `deltaSnapshots = {}` table to store previous alt states
  - [ ] Add `guildProtocolVersions = {}` to track peer capabilities
  - [ ] Add `deltaMetrics = {}` to track bandwidth savings
- [ ] Implement snapshot management functions
  - [ ] `SaveSnapshot(name, alt)` - Store alt state with timestamp
  - [ ] `GetSnapshot(name)` - Retrieve previous state
  - [ ] `CleanupOldSnapshots()` - Remove snapshots older than 1 hour
  - [ ] `GetSnapshotAge(name)` - Check if snapshot is still valid

### 1.3 Protocol Version Detection
- [ ] Update version broadcast structure in `Modules/Chat.lua`
  - [ ] Modify `togbank-v` message to include `protocol_version` field
  - [ ] Add `supports_delta` capability flag
  - [ ] Maintain backwards compatibility (old clients ignore new fields)
- [ ] Implement peer capability tracking
  - [ ] `UpdatePeerCapabilities(sender, data)` - Store protocol info
  - [ ] `GetPeerCapabilities(sender)` - Query peer protocol version
  - [ ] `GetGuildDeltaSupport()` - Calculate % of guild supporting delta
  - [ ] `ShouldUseDelta()` - Decision logic (>50% support threshold)

---

## Phase 2: Delta Computation & Serialization

### 2.1 Delta Computation Core
- [ ] Create delta computation functions in `Modules/Guild.lua`
  - [ ] `ComputeDelta(name, currentAlt)` - Main delta calculation
  - [ ] `ComputeItemDelta(oldItems, newItems)` - Item-level diff
  - [ ] `BuildSlotIndex(items)` - Helper to index items by slot
  - [ ] `ItemsEqual(item1, item2)` - Deep equality check
  - [ ] `GetChangedFields(oldItem, newItem)` - Extract only changed fields
  - [ ] `EstimateDeltaSize(delta)` - Estimate serialized size
  - [ ] `EstimateFullSize(alt)` - Estimate full sync size

### 2.2 Item Comparison Logic
- [ ] Implement robust item comparison
  - [ ] Compare `ID`, `Count`, `Link` fields
  - [ ] Compare `Info` table if present (future-proofing)
  - [ ] Handle nil/missing fields gracefully
  - [ ] Consider floating point precision for money

### 2.3 Delta Structure Validation
- [ ] Add validation functions in `Core.lua`
  - [ ] `ValidateDeltaStructure(delta)` - Ensure well-formed
  - [ ] `ValidateItemDelta(itemDelta)` - Check added/modified/removed
  - [ ] `SanitizeDelta(delta)` - Clean malformed data

---

## Phase 3: Communication Layer

### 3.1 New Comm Prefix Registration
- [ ] Register `togbank-d2` prefix in `Modules/Chat.lua`
  - [ ] `RegisterComm("togbank-d2", OnCommReceived)`
  - [ ] Add handler case in `OnCommReceived()` function
  - [ ] Maintain existing `togbank-d` handler (backwards compatibility)

### 3.2 Smart Send Logic
- [ ] Update `SendAltData()` in `Modules/Guild.lua`
  - [ ] Check if delta is appropriate (has snapshot, guild supports it)
  - [ ] Compute delta and estimate size
  - [ ] Compare delta size to full size (use if <30%)
  - [ ] Send via `togbank-d2` if delta chosen
  - [ ] Fallback to `togbank-d` (full sync) otherwise
  - [ ] Always save snapshot after successful send

### 3.3 Receive & Apply Delta
- [ ] Implement delta receiver in `Modules/Chat.lua`
  - [ ] Handle `togbank-d2` prefix in `OnCommReceived()`
  - [ ] Validate sender authorization (reuse existing logic)
  - [ ] Deserialize and validate delta structure
  - [ ] Call `ApplyDelta()` function
  - [ ] Log adoption status (ADOPTED, INVALID, etc.)

### 3.4 Delta Application Logic
- [ ] Create `ApplyDelta()` in `Modules/Guild.lua`
  - [ ] Validate base version matches current state
  - [ ] Request full sync if base version mismatch
  - [ ] Apply money changes
  - [ ] Apply bank item delta (`ApplyItemDelta()`)
  - [ ] Apply bag item delta (`ApplyItemDelta()`)
  - [ ] Update alt version timestamp
  - [ ] Save new snapshot
  - [ ] Trigger UI refresh event

### 3.5 Item Delta Application
- [ ] Implement `ApplyItemDelta(items, delta)`
  - [ ] Process `removed` slots (delete from items table)
  - [ ] Process `added` items (insert with slot as key)
  - [ ] Process `modified` items (update changed fields only)
  - [ ] Validate slot numbers are within valid range
  - [ ] Handle edge cases (duplicate slots, nil slots, etc.)

---

## Phase 4: Error Handling & Fallback

### 4.1 Delta Failure Detection
- [ ] Implement failure detection in `ApplyDelta()`
  - [ ] Check for base version mismatch
  - [ ] Validate delta structure before applying
  - [ ] Detect corrupted serialization
  - [ ] Log failure reasons

### 4.2 Automatic Full Sync Fallback
- [ ] Trigger full sync on delta failure
  - [ ] Call `QueryAlt(sender, name)` to request full data
  - [ ] Clear invalid snapshot
  - [ ] Log fallback event for metrics
  - [ ] Notify user if repeated failures occur

### 4.3 Snapshot Corruption Recovery
- [ ] Add snapshot validation
  - [ ] Verify snapshot structure on load
  - [ ] Check version timestamp is valid
  - [ ] Validate item arrays are well-formed
  - [ ] Purge corrupted snapshots automatically

---

## Phase 5: Testing & Validation

### 5.1 Unit Tests (Manual)
- [ ] Test delta computation accuracy
  - [ ] No changes → empty delta
  - [ ] Add items → correct `added` array
  - [ ] Remove items → correct `removed` array
  - [ ] Modify items → correct `modified` array
  - [ ] Mixed operations → all changes captured
  - [ ] Money change only → minimal delta

### 5.2 Size Estimation Tests
- [ ] Verify size estimation logic
  - [ ] Small delta (<10% full) → uses delta
  - [ ] Large delta (>50% full) → falls back to full
  - [ ] Edge case: empty bank → uses full sync
  - [ ] Edge case: no snapshot → uses full sync

### 5.3 Protocol Negotiation Tests
- [ ] Test version detection
  - [ ] Old client (v0.6.8) → receives full sync via `togbank-d`
  - [ ] New client (v0.7.0) → receives delta via `togbank-d2`
  - [ ] Mixed guild → uses appropriate protocol per recipient
  - [ ] Guild with <50% delta support → falls back to full

### 5.4 Error Handling Tests
- [ ] Test failure scenarios
  - [ ] Base version mismatch → requests full sync
  - [ ] Corrupted delta → requests full sync
  - [ ] Missing snapshot → uses full sync
  - [ ] Malformed serialization → logs error, ignores

### 5.5 Integration Tests
- [ ] Test end-to-end flow
  - [ ] Bank alt makes item changes
  - [ ] Delta computed correctly
  - [ ] Delta sent via `togbank-d2`
  - [ ] Receiving clients apply delta
  - [ ] UI updates with new data
  - [ ] Snapshot saved for next delta

### 5.6 Backwards Compatibility Tests
- [ ] Test with v0.6.8 clients
  - [ ] Old clients ignore `togbank-d2` messages
  - [ ] Old clients still receive `togbank-d` full syncs
  - [ ] New clients can receive from old clients
  - [ ] No errors or crashes in either version

---

## Phase 6: Metrics & Monitoring

### 6.1 Bandwidth Tracking
- [ ] Add metrics collection in `Modules/Guild.lua`
  - [ ] Track bytes sent via delta protocol
  - [ ] Track bytes sent via full protocol
  - [ ] Track delta success rate (applied vs. failed)
  - [ ] Track full sync fallback count
  - [ ] Calculate bandwidth savings percentage

### 6.2 Performance Metrics
- [ ] Track delta computation time
  - [ ] Measure `ComputeDelta()` execution time
  - [ ] Measure `ApplyDelta()` execution time
  - [ ] Log slow operations (>50ms) for optimization

### 6.3 Adoption Tracking
- [ ] Track guild protocol versions
  - [ ] Count online members by protocol version
  - [ ] Calculate % supporting delta
  - [ ] Display in debug output or options panel

### 6.4 Debug Output
- [ ] Add detailed logging for delta operations
  - [ ] Log when delta is used vs. full sync
  - [ ] Log delta size vs. full size comparison
  - [ ] Log snapshot age and validity
  - [ ] Log fallback reasons
  - [ ] Use `TOGBankClassic_Output:Debug()` for consistency

---

## Phase 7: UI & User Experience

### 7.1 Options Panel Updates
- [ ] Add delta configuration to `Modules/Options.lua`
  - [ ] Toggle to enable/disable delta sync
  - [ ] Display current protocol version
  - [ ] Show guild delta support percentage
  - [ ] Display bandwidth savings metrics

### 7.2 Status Indicators
- [ ] Add visual feedback for sync type
  - [ ] Indicator when sending delta vs. full sync
  - [ ] Show delta success/failure in chat output
  - [ ] Display snapshot age in debug output

### 7.3 User Commands
- [ ] Add debug commands
  - [ ] `/togbank delta-stats` - Show metrics
  - [ ] `/togbank clear-snapshots` - Clear all snapshots
  - [ ] `/togbank force-full` - Force next sync to be full
  - [ ] `/togbank protocol-info` - Show guild protocol versions

---

## Phase 8: Documentation & Release

### 8.1 Code Documentation
- [ ] Add function header comments
  - [ ] Document delta computation algorithm
  - [ ] Document protocol version negotiation
  - [ ] Document snapshot lifecycle
  - [ ] Add usage examples for key functions

### 8.2 User Documentation
- [ ] Update README.md
  - [ ] Explain delta sync feature
  - [ ] Document backwards compatibility
  - [ ] Add troubleshooting section
- [ ] Update CHANGELOG.md
  - [ ] Add v0.7.0 release notes
  - [ ] List new features and improvements
  - [ ] Note breaking changes (none expected)

### 8.3 Testing Documentation
- [ ] Document test procedures
  - [ ] Manual testing checklist
  - [ ] Expected behavior for each test case
  - [ ] Known issues or limitations

### 8.4 Version Bump
- [ ] Update `TOGBankClassic.toc`
  - [ ] Change `## Version: 0.7.0`
  - [ ] Update interface version if needed
- [ ] Git commit and tag
  - [ ] Commit all changes with descriptive message
  - [ ] Create git tag `v0.7.0`
  - [ ] Push to repository

---

## Phase 9: Deployment & Monitoring

### 9.1 Beta Testing
- [ ] Deploy to test environment
  - [ ] Install on test characters
  - [ ] Test in small guild (5-10 members)
  - [ ] Monitor for errors or crashes
  - [ ] Gather feedback on performance

### 9.2 Metrics Collection Period
- [ ] Monitor delta usage
  - [ ] Track bandwidth savings over 1-2 weeks
  - [ ] Identify any failure patterns
  - [ ] Optimize based on real-world data

### 9.3 Full Release
- [ ] Release v0.7.0 to guild
  - [ ] Announce new delta sync feature
  - [ ] Provide update instructions
  - [ ] Monitor adoption rate
  - [ ] Be available for bug reports

### 9.4 Post-Release Support
- [ ] Monitor for issues
  - [ ] Check logs for errors
  - [ ] Respond to user reports
  - [ ] Prepare hotfix if needed (v0.7.1)

---

## Phase 10: Future Optimizations (Post v0.7.0)

### 10.1 Compression Integration (v0.7.1+)
- [ ] Integrate LibDeflate for delta compression
- [ ] Test compression ratio on deltas
- [ ] Measure CPU overhead vs. bandwidth savings

### 10.2 Metadata Stripping (v0.7.2+)
- [ ] Remove `Info` table from transmitted items
- [ ] Implement local item cache using `GetItemInfo()`
- [ ] Further reduce bandwidth by 60-70%

### 10.3 Old Protocol Deprecation (v0.9.0+)
- [ ] Add deprecation warnings for old protocol
- [ ] Track adoption rate (target >80% guild support)
- [ ] Plan removal for v1.0.0

### 10.4 Advanced Features (v0.8.0+)
- [ ] Event-driven updates (remove periodic timers)
- [ ] Targeted whispers for query responses
- [ ] Batch update accumulation (2-5 second buffer)
- [ ] Progressive update strategy (IDs first, details later)

---

## Success Criteria

### Functional Requirements
✓ Delta sync works correctly for typical bank operations  
✓ Backwards compatible with v0.6.8 clients  
✓ Automatic fallback to full sync on delta failure  
✓ No data loss or corruption  
✓ UI updates correctly after delta application  

### Performance Requirements
✓ Delta computation completes in <50ms for typical bank (200 items)  
✓ Delta application completes in <20ms  
✓ Bandwidth reduction of >90% for typical updates (1-5 items changed)  
✓ Delta size <30% of full sync size (or fallback to full)  

### Quality Requirements
✓ Zero crashes or Lua errors in production  
✓ Clean code with proper error handling  
✓ Adequate logging for debugging  
✓ User-friendly options and commands  

---

## Risk Mitigation

### High Risk Areas
1. **Base Version Mismatch** - If clients have different states, delta fails
   - Mitigation: Automatic full sync fallback, log mismatch events

2. **Snapshot Corruption** - Saved snapshots become invalid
   - Mitigation: Validation on load, purge corrupted snapshots, fallback to full

3. **Protocol Version Detection Failure** - Can't determine peer capabilities
   - Mitigation: Conservative default (assume old protocol), manual override option

4. **Network Serialization Issues** - Large deltas fail to transmit
   - Mitigation: Size threshold check, fallback to full sync if delta too large

5. **Backwards Compatibility Break** - Old clients stop working
   - Mitigation: Extensive testing, maintain `togbank-d` support indefinitely in v0.7.x

### Contingency Plan
If critical issues arise post-release:
1. Release hotfix v0.7.1 with `FEATURE_DELTA_ENABLED = false` by default
2. Investigate root cause with debug logging
3. Fix issue and re-enable in v0.7.2
4. In worst case, revert to v0.6.8 until fix is ready

---

## Notes & Decisions

- **Decision:** Use 50% guild support threshold for delta adoption
  - Rationale: Balance between optimization and compatibility
  - Can adjust based on real-world metrics

- **Decision:** Keep snapshots for 1 hour max
  - Rationale: Balance between delta opportunities and memory usage
  - Long-offline clients will get full sync anyway

- **Decision:** 30% size threshold for delta vs. full
  - Rationale: Diminishing returns if delta isn't much smaller
  - Avoids delta computation overhead for marginal gains

- **Decision:** Don't compress deltas in v0.7.0
  - Rationale: Keep initial implementation simple
  - Add compression in v0.7.1+ after delta is proven stable

---

**Status Legend:**
- [ ] Not Started
- [~] In Progress
- [x] Completed
- [!] Blocked
- [?] Needs Discussion
