TOGBankClassic_Tests = {}
local Tests = TOGBankClassic_Tests

-- Proxy to access addon after it loads (Core loads after Tests in TOC)
local addon = setmetatable({}, {
    __index = function(_, key)
        return TOGBankClassic_Core and TOGBankClassic_Core[key]
    end
})

-- Direct module references (these exist before Core)
local Guild = TOGBankClassic_Guild
local Database = TOGBankClassic_Database

-- Helper function for deep table copy
local function TableCopy(src, dest)
    if type(src) ~= "table" then
        return src
    end
    
    dest = dest or {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            dest[k] = TableCopy(v)
        else
            dest[k] = v
        end
    end
    return dest
end

-- Test framework
local testResults = {}
local currentTest = nil

local function assert(condition, message)
    if not condition then
        error("Assertion failed: " .. (message or "unknown"), 2)
    end
end

local function assertEquals(expected, actual, message)
    if expected ~= actual then
        error(string.format("Assertion failed: %s\nExpected: %s\nActual: %s", 
            message or "values not equal", tostring(expected), tostring(actual)), 2)
    end
end

local function assertNotNil(value, message)
    if value == nil then
        error("Assertion failed: " .. (message or "value is nil"), 2)
    end
end

local function assertNil(value, message)
    if value ~= nil then
        error("Assertion failed: " .. (message or "value is not nil"), 2)
    end
end

local function runTest(testName, testFunc)
    currentTest = testName
    local success, err = pcall(testFunc)
    
    if success then
        table.insert(testResults, {name = testName, passed = true})
        addon:Print("|cff00ff00✓|r " .. testName)
    else
        table.insert(testResults, {name = testName, passed = false, error = err})
        addon:Print("|cffff0000✗|r " .. testName .. ": " .. tostring(err))
    end
    
    currentTest = nil
end

-- Helper function to create test data (matches actual Bank.lua structure)
local function createTestItem(id, count, link)
    return {
        ID = id,
        Count = count or 1,
        Link = link or ("[Item " .. id .. "]")
    }
end

local function createTestAltData(name)
    return {
        name = name,
        version = GetServerTime(),
        money = 150000, -- Total money
        bank = {
            items = {
                createTestItem(2589, 20, "[Linen Cloth]"),
                createTestItem(2592, 10, "[Wool Cloth]"),
            }
        },
        bags = {
            items = {
                createTestItem(2589, 5, "[Linen Cloth]"),
                createTestItem(765, 3, "[Silverleaf]"),
            }
        }
    }
end

--============================================================================
-- Phase 5.1: Delta Computation Tests
--============================================================================

-- Test setup: Initialize guild context for delta tests
local function setupDeltaTest(guildName)
    guildName = guildName or "TestGuild"
    
    -- Ensure Guild.Info is initialized with the guild name
    if not Guild.Info or Guild.Info.name ~= guildName then
        Guild.Info = { name = guildName }
    end
    
    -- Mock Events:TriggerCallback if it doesn't exist (for ApplyDelta)
    if TOGBankClassic_Events and not TOGBankClassic_Events.TriggerCallback then
        TOGBankClassic_Events.TriggerCallback = function() end
    end
    
    -- Database should already be initialized by addon, but ensure structure exists
    if not Database.db then
        addon:Print("|cffff0000ERROR: Database not initialized! Tests require addon to be loaded.|r")
        return nil
    end
    
    -- Ensure faction storage exists
    if not Database.db.faction then
        Database.db.faction = {}
    end
    
    -- Ensure guild entry exists (use Database:Reset to create proper structure)
    if not Database.db.faction[guildName] then
        Database:Reset(guildName)
    end
    
    -- Clear any existing test snapshots
    Database.db.faction[guildName].deltaSnapshots = {}
    
    return guildName
end

local function testDeltaComputationNoChanges()
    local guildName = setupDeltaTest()
    if not guildName then
        error("Test setup failed - database not initialized")
    end
    
    local oldData = createTestAltData("TestAlt1")
    
    -- Save snapshot as baseline
    local saved = Database:SaveSnapshot(guildName, "TestAlt1", oldData)
    assert(saved, "Failed to save snapshot")
    
    -- Verify snapshot was saved
    local retrieved = Database:GetSnapshot(guildName, "TestAlt1")
    assertNotNil(retrieved, "Snapshot should be retrievable after save")
    
    -- Create identical "new" data
    local newData = TableCopy(oldData)
    
    -- Compute delta
    local delta = Guild:ComputeDelta("TestAlt1", newData)
    
    assertNotNil(delta, "Delta should not be nil for identical data")
    assertEquals("alt-delta", delta.type, "Delta type should be alt-delta")
    assertEquals("TestAlt1", delta.name, "Delta name should match")
    assertNotNil(delta.version, "Delta should have version")
    -- baseVersion is optional in v0.8.0 (removed for bandwidth savings)
    assert(not Guild:DeltaHasChanges(delta), "Delta should have no changes")
end

local function testDeltaComputationMoneyChange()
    local guildName = setupDeltaTest()
    if not guildName then
        error("Test setup failed - database not initialized")
    end
    
    local oldData = createTestAltData("TestAlt2")
    
    -- Save snapshot as baseline
    local saved = Database:SaveSnapshot(guildName, "TestAlt2", oldData)
    assert(saved, "Failed to save snapshot")
    
    -- Create new data with money change
    local newData = TableCopy(oldData)
    newData.money = 200000
    
    -- Compute delta
    local delta = Guild:ComputeDelta("TestAlt2", newData)
    
    assertNotNil(delta, "Delta should not be nil")
    assert(Guild:DeltaHasChanges(delta), "Delta should have changes")
    assertEquals(200000, delta.changes.money, "Money should be updated")
end

local function testDeltaComputationItemAdded()
    local guildName = setupDeltaTest()
    if not guildName then
        error("Test setup failed - database not initialized")
    end
    
    local oldData = createTestAltData("TestAlt3")
    
    -- Save snapshot as baseline
    local saved = Database:SaveSnapshot(guildName, "TestAlt3", oldData)
    assert(saved, "Failed to save snapshot")
    
    -- Create new data with added item
    local newData = TableCopy(oldData)
    table.insert(newData.bank.items, createTestItem(2996, 5, "[Bolt of Linen Cloth]"))
    
    -- Compute delta
    local delta = Guild:ComputeDelta("TestAlt3", newData)
    
    assertNotNil(delta, "Delta should not be nil")
    assert(Guild:DeltaHasChanges(delta), "Delta should have changes")
    assertNotNil(delta.changes.bank, "Bank changes should exist")
    assert(#delta.changes.bank.added > 0, "Should have added items")
    assertEquals(2996, delta.changes.bank.added[1].ID, "Added item ID should match")
end

local function testDeltaComputationItemRemoved()
    local guildName = setupDeltaTest()
    if not guildName then
        error("Test setup failed - database not initialized")
    end
    
    local oldData = createTestAltData("TestAlt4")
    
    -- Save snapshot as baseline
    local saved = Database:SaveSnapshot(guildName, "TestAlt4", oldData)
    assert(saved, "Failed to save snapshot")
    
    -- Create new data with removed item
    local newData = TableCopy(oldData)
    table.remove(newData.bank.items, 1) -- Remove first item
    
    -- Compute delta
    local delta = Guild:ComputeDelta("TestAlt4", newData)
    
    assertNotNil(delta, "Delta should not be nil")
    assert(Guild:DeltaHasChanges(delta), "Delta should have changes")
    assertNotNil(delta.changes.bank, "Bank changes should exist")
    assert(#delta.changes.bank.removed > 0, "Should have removed items")
    assertEquals(2589, delta.changes.bank.removed[1].ID, "Removed item ID should match")
end

local function testDeltaComputationItemCountChanged()
    local guildName = setupDeltaTest()
    if not guildName then
        error("Test setup failed - database not initialized")
    end
    
    local oldData = createTestAltData("TestAlt5")
    
    -- Save snapshot as baseline
    local saved = Database:SaveSnapshot(guildName, "TestAlt5", oldData)
    assert(saved, "Failed to save snapshot")
    
    -- Create new data with changed item count
    local newData = TableCopy(oldData)
    newData.bank.items[1].Count = 25 -- Change from 20 to 25
    
    -- Compute delta
    local delta = Guild:ComputeDelta("TestAlt5", newData)
    
    assertNotNil(delta, "Delta should not be nil")
    assert(Guild:DeltaHasChanges(delta), "Delta should have changes")
    assertNotNil(delta.changes.bank, "Bank changes should exist")
    assert(#delta.changes.bank.modified > 0, "Should have modified items")
    assertEquals(2589, delta.changes.bank.modified[1].ID, "Modified item ID should match")
    assertEquals(25, delta.changes.bank.modified[1].Count, "Modified count should be 25")
end

local function testDeltaComputationMultipleChanges()
    local guildName = setupDeltaTest()
    if not guildName then
        error("Test setup failed - database not initialized")
    end
    
    local oldData = createTestAltData("TestAlt6")
    
    -- Save snapshot as baseline
    local saved = Database:SaveSnapshot(guildName, "TestAlt6", oldData)
    assert(saved, "Failed to save snapshot")
    
    -- Create new data with multiple changes
    local newData = TableCopy(oldData)
    newData.money = 300000  -- Money change
    newData.bank.items[1].Count = 30  -- Count change
    table.insert(newData.bank.items, createTestItem(2996, 5, "[Bolt of Linen Cloth]"))  -- Add item
    table.remove(newData.bags.items, 1)  -- Remove item
    
    -- Compute delta
    local delta = Guild:ComputeDelta("TestAlt6", newData)
    
    assertNotNil(delta, "Delta should not be nil")
    assert(Guild:DeltaHasChanges(delta), "Delta should have changes")
    assertEquals(300000, delta.changes.money, "Money should be updated")
    assert(#delta.changes.bank.modified > 0, "Should have modified bank items")
    assert(#delta.changes.bank.added > 0, "Should have added bank items")
    assert(#delta.changes.bags.removed > 0, "Should have removed bag items")
end

local function testItemsEqual()
    local item1 = createTestItem(2589, 20, "[Linen Cloth]")
    local item2 = createTestItem(2589, 20, "[Linen Cloth]")
    local item3 = createTestItem(2589, 25, "[Linen Cloth]")
    local item4 = createTestItem(2590, 20, "[Wool Cloth]")
    
    assert(Guild:ItemsEqual(item1, item2), "Identical items should be equal")
    assert(not Guild:ItemsEqual(item1, item3), "Different counts should not be equal")
    assert(not Guild:ItemsEqual(item1, item4), "Different IDs should not be equal")
    assert(not Guild:ItemsEqual(item1, nil), "Item and nil should not be equal")
    assert(Guild:ItemsEqual(nil, nil), "nil and nil should be equal")
end

local function testGetChangedFields()
    local oldItem = createTestItem(2589, 20, "[Linen Cloth]")
    local newItem = TableCopy(oldItem)
    newItem.Count = 25
    
    local changes = Guild:GetChangedFields(oldItem, newItem)
    
    assertNotNil(changes, "Changes should not be nil")
    assertEquals(2589, changes.ID, "ID should always be included for identification")
    assertEquals("[Linen Cloth]", changes.Link, "Link should always be included for identification")
    assertEquals(25, changes.Count, "Count change should be captured")
end

--============================================================================
-- Phase 5.2: Size Estimation Tests
--============================================================================

local function testSizeEstimationEmpty()
    local data = {}
    local size = Guild:EstimateSize(data)
    assert(size > 0, "Empty table should have non-zero size")
end

local function testSizeEstimationSmallDelta()
    local delta = {
        version = 2,
        baseVersion = 1,
        changes = {
            bank = {
                money = 100000
            }
        }
    }
    
    local size = Guild:EstimateSize(delta)
    assert(size > 0, "Delta should have non-zero size")
    assert(size < 1000, "Small delta should be less than 1KB")
end

local function testSizeEstimationLargeDelta()
    local delta = {
        version = 2,
        baseVersion = 1,
        changes = {
            bank = {
                items = {}
            }
        }
    }
    
    -- Add many items
    for i = 1, 100 do
        delta.changes.bank.items[i] = createTestItem(2589 + i, 20)
    end
    
    local size = Guild:EstimateSize(delta)
    assert(size > 1000, "Large delta should be over 1KB")
end

local function testSizeEstimationComparison()
    local fullData = createTestAltData("TestAlt")
    local delta = {
        version = 2,
        baseVersion = 1,
        changes = {
            bank = { money = 200000 }
        }
    }
    
    local fullSize = Guild:EstimateSize(fullData)
    local deltaSize = Guild:EstimateSize(delta)
    
    assert(deltaSize < fullSize, "Delta should be smaller than full data")
end

--============================================================================
-- Phase 5.3: Protocol Negotiation Tests
--============================================================================

local function testProtocolVersionDetection()
    local guildName = setupDeltaTest()
    if not guildName then
        error("Test setup failed - database not initialized")
    end
    
    -- Save peer protocol versions
    Database.db.faction[guildName].guildProtocolVersions = {
        ["V2User-TestRealm"] = 2,
        ["V1User-TestRealm"] = 1,
    }
    
    -- GetPeerCapabilities returns the protocol version number (or nil)
    local v2Protocol = Guild:GetPeerCapabilities("V2User-TestRealm")
    local v1Protocol = Guild:GetPeerCapabilities("V1User-TestRealm")
    local unknownProtocol = Guild:GetPeerCapabilities("Unknown-TestRealm")
    
    assertEquals(2, v2Protocol, "V2 user should have protocol version 2")
    assertEquals(1, v1Protocol, "V1 user should have protocol version 1")
    assertNil(unknownProtocol, "Unknown user should have nil protocol")
end

local function testShouldUseDeltaLogic()
    local guildName = setupDeltaTest()
    if not guildName then
        error("Test setup failed - database not initialized")
    end
    
    -- Setup Guild.Info
    Guild.Info = Guild.Info or {}
    Guild.Info.name = guildName
    
    -- Mock guild support at 60% (above 10% threshold)
    local oldGetGuildDeltaSupport = Database.GetGuildDeltaSupport
    Database.GetGuildDeltaSupport = function(name)
        return 0.6  -- 60% support
    end
    
    -- Test with delta enabled
    local oldEnabled = FEATURES.DELTA_ENABLED
    local oldForce = FEATURES.FORCE_FULL_SYNC
    FEATURES.DELTA_ENABLED = true
    FEATURES.FORCE_FULL_SYNC = false
    
    -- ShouldUseDelta takes no parameters
    local shouldUse = Guild:ShouldUseDelta()
    assert(shouldUse, "Should use delta when conditions are met")
    
    -- Test with delta disabled
    FEATURES.DELTA_ENABLED = false
    shouldUse = Guild:ShouldUseDelta()
    assert(not shouldUse, "Should not use delta when disabled")
    
    -- Test with force full sync
    FEATURES.DELTA_ENABLED = true
    FEATURES.FORCE_FULL_SYNC = true
    shouldUse = Guild:ShouldUseDelta()
    assert(not shouldUse, "Should not use delta when forced full sync")
    
    -- Restore
    FEATURES.DELTA_ENABLED = oldEnabled
    FEATURES.FORCE_FULL_SYNC = oldForce
    Database.GetGuildDeltaSupport = oldGetGuildDeltaSupport
end

local function testDeltaSupportThreshold()
    -- Test threshold comparison logic
    -- PROTOCOL.DELTA_SUPPORT_THRESHOLD is 0.05 (5%)
    
    -- Test below threshold (3%)
    local support = 0.03
    assert(support < PROTOCOL.DELTA_SUPPORT_THRESHOLD, "3% should be below 5% threshold")
    
    -- Test above threshold (10%)
    support = 0.10
    assert(support >= PROTOCOL.DELTA_SUPPORT_THRESHOLD, "10% should be above 5% threshold")
    
    -- Test exact threshold (5%)
    support = 0.05
    assert(support >= PROTOCOL.DELTA_SUPPORT_THRESHOLD, "5% should meet 5% threshold")
end

--============================================================================
-- Phase 5.4: Error Handling Tests
--============================================================================

local function testApplyDeltaNoExistingData()
    local guildName = setupDeltaTest()
    if not guildName then
        error("Test setup failed - database not initialized")
    end
    
    -- Ensure Guild.Info.alts exists but is empty
    if not Guild.Info.alts then
        Guild.Info.alts = {}
    end
    
    local delta = {
        type = "alt-delta",
        name = "NonExistent",
        version = 2,
        baseVersion = 1,
        changes = {}
    }
    
    -- Should fail because no existing data in Info.alts
    local result = Guild:ApplyDelta("NonExistent-TestRealm", delta, "Sender-TestRealm")
    assert(result ~= "APPLIED", "Should not apply when no existing data")
end

local function testApplyDeltaVersionMismatch()
    local guildName = setupDeltaTest()
    if not guildName then
        error("Test setup failed - database not initialized")
    end
    
    -- Create existing data with specific version
    local existingData = createTestAltData("TestAlt")
    existingData.version = 5
    
    -- Set up Guild.Info.alts with the existing data
    if not Guild.Info.alts then
        Guild.Info.alts = {}
    end
    Guild.Info.alts["TestAlt-TestRealm"] = existingData
    
    -- Create delta with mismatched base version
    local delta = {
        type = "alt-delta",
        name = "TestAlt",
        version = 6,
        baseVersion = 1, -- Mismatched (current is 5)
        changes = {money = 100000}
    }
    
    local result = Guild:ApplyDelta("TestAlt-TestRealm", delta, "Sender-TestRealm")
    assert(result ~= "APPLIED", "Should not apply on version mismatch")
end

local function testDeltaErrorTracking()
    local errorCount = Guild:GetDeltaFailureCount("TestRealm-ErrorAlt")
    assertEquals(0, errorCount, "Initial error count should be 0")
    
    -- Record errors
    Guild:RecordDeltaError("TestRealm-ErrorAlt", "TEST_ERROR", "Test error 1")
    errorCount = Guild:GetDeltaFailureCount("TestRealm-ErrorAlt")
    assertEquals(1, errorCount, "Error count should be 1")
    
    Guild:RecordDeltaError("TestRealm-ErrorAlt", "TEST_ERROR", "Test error 2")
    errorCount = Guild:GetDeltaFailureCount("TestRealm-ErrorAlt")
    assertEquals(2, errorCount, "Error count should be 2")
    
    -- Reset errors
    Guild:ResetDeltaErrorCount("TestRealm-ErrorAlt")
    errorCount = Guild:GetDeltaFailureCount("TestRealm-ErrorAlt")
    assertEquals(0, errorCount, "Error count should be reset to 0")
end

local function testSnapshotValidation()
    -- Valid snapshot (the data itself, not wrapped)
    local validSnapshot = createTestAltData("TestAlt")
    assert(Database:ValidateSnapshot(validSnapshot), "Valid snapshot should pass")
    
    -- Invalid: missing version
    local invalidSnapshot1 = TableCopy(validSnapshot)
    invalidSnapshot1.version = nil
    assert(not Database:ValidateSnapshot(invalidSnapshot1), "Missing version should fail")
    
    -- Invalid: version not a number
    local invalidSnapshot2 = TableCopy(validSnapshot)
    invalidSnapshot2.version = "not a number"
    assert(not Database:ValidateSnapshot(invalidSnapshot2), "Non-numeric version should fail")
    
    -- Invalid: corrupted bank structure
    local invalidSnapshot3 = {
        version = 1,
        bank = "not a table"
    }
    assert(not Database:ValidateSnapshot(invalidSnapshot3), "Corrupted bank should fail")
end

local function testDeltaStructureValidation()
    -- Valid delta
    local validDelta = {
        type = "alt-delta",
        name = "TestAlt",
        version = 2,
        baseVersion = 1,
        changes = {
            money = 100000
        }
    }
    local valid, err = addon:ValidateDeltaStructure(validDelta)
    assert(valid, "Valid delta should pass: " .. tostring(err))
    
    -- Invalid: missing type
    local invalidDelta1 = {
        name = "TestAlt",
        version = 2,
        baseVersion = 1,
        changes = {}
    }
    valid, err = addon:ValidateDeltaStructure(invalidDelta1)
    assert(not valid, "Missing type should fail")
    
    -- Invalid: wrong type
    local invalidDelta2 = {
        type = "wrong-type",
        name = "TestAlt",
        version = 2,
        baseVersion = 1,
        changes = {}
    }
    valid, err = addon:ValidateDeltaStructure(invalidDelta2)
    assert(not valid, "Wrong type should fail")
    
    -- Invalid: missing name
    local invalidDelta3 = {
        type = "alt-delta",
        version = 2,
        baseVersion = 1,
        changes = {}
    }
    valid, err = addon:ValidateDeltaStructure(invalidDelta3)
    assert(not valid, "Missing name should fail")
    
    -- Invalid: non-numeric version
    local invalidDelta4 = {
        type = "alt-delta",
        name = "TestAlt",
        version = "not a number",
        baseVersion = 1,
        changes = {}
    }
    valid, err = addon:ValidateDeltaStructure(invalidDelta4)
    assert(not valid, "Non-numeric version should fail")
end

--============================================================================
-- Phase 5.5: Integration Tests
--============================================================================

local function testFullDeltaRoundtrip()
    setupDeltaTest("TestGuild")
    
    local name = "IntegrationTest"
    local norm = Guild:NormalizeName(name)  -- Use Guild's NormalizeName which adds realm suffix
    
    -- Create initial data with proper structure
    local oldData = createTestAltData(name)
    oldData.version = 1
    oldData.money = 100000  -- Money is at root level, not in bank
    oldData.bank.items = oldData.bank.items or {}
    -- Keep only first bank item
    oldData.bank.items[2] = nil
    oldData.bags.items = oldData.bags.items or {}
    -- Keep both bag items (from createTestAltData)
    Database:SaveSnapshot("TestGuild", name, oldData)
    
    -- Setup Guild.Info for ApplyDelta with a deep copy
    Guild.Info.name = "TestGuild"
    Guild.Info.alts = Guild.Info.alts or {}
    Guild.Info.alts[norm] = TableCopy(oldData)
    
    -- Make changes  
    local newData = TableCopy(oldData)
    newData.version = 2
    newData.money = 200000  -- Money is at root level
    -- Add new item to bank (append to array)
    table.insert(newData.bank.items, createTestItem(2996, 5))
    -- Remove first bag item
    table.remove(newData.bags.items, 1)
    
    -- Compute delta
    local delta = Guild:ComputeDelta(name, newData)
    assertNotNil(delta, "Delta should be computed")
    assertEquals("alt-delta", delta.type, "Delta should have type")
    assertEquals(name, delta.name, "Delta should have name")
    
    -- Verify delta contains money change
    assertNotNil(delta.changes, "Delta should have changes")
    assertEquals(200000, delta.changes.money, "Delta should contain money change")
    
    -- Apply delta (modifies Guild.Info.alts[norm] in place)
    local status = Guild:ApplyDelta(name, delta, "sender")
    -- ApplyDelta returns ADOPTION_STATUS values, not boolean
    -- Just check it didn't return INVALID
    
    -- Verify changes through Guild.Info.alts
    local appliedData = Guild.Info.alts[norm]
    assertNotNil(appliedData, "Data should be in Guild.Info.alts")
    assertEquals(200000, appliedData.money, "Money should be updated")
    -- Bank should now have 2 items (originally had 1, added 1)
    assertEquals(2, #appliedData.bank.items, "Bank should have 2 items")
    -- Bag items should have 1 item (originally had 2, removed 1)
    assertEquals(1, #appliedData.bags.items, "Bags should have 1 item (TESTS ITEM REMOVAL)")
    assertEquals(2, appliedData.version, "Version should be updated")
end

local function testDeltaSizeThreshold()
    setupDeltaTest("TestGuild")
    
    local name = "SizeTest"
    local oldData = createTestAltData(name)
    oldData.version = 1
    oldData.money = 100000
    -- Add many items to increase full size
    for i = 3, 20 do
        oldData.bank.items[i] = createTestItem(2589 + i, 1)
    end
    Database:SaveSnapshot("TestGuild", name, oldData)
    
    local newData = TableCopy(oldData)
    newData.version = 2
    newData.money = 200000  -- Just change money
    
    local delta = Guild:ComputeDelta(name, newData)
    assertNotNil(delta, "Delta should be computed")
    assertNotNil(delta.changes, "Delta should have changes")
    assertEquals(200000, delta.changes.money, "Delta should have money change")
    
    local fullSize = Guild:EstimateSize(newData)
    local deltaSize = Guild:EstimateSize(delta)
    local ratio = deltaSize / fullSize
    
    -- With many items, a money-only delta should be small relative to full data
    assert(ratio < PROTOCOL.MIN_DELTA_SIZE_RATIO, 
        string.format(
            "Money-only change should be below %.0f%% threshold (actual: %.1f%%, deltaSize=%d, fullSize=%d)",
            PROTOCOL.MIN_DELTA_SIZE_RATIO * 100,
            ratio * 100,
            deltaSize,
            fullSize
        ))
end

--============================================================================
-- Phase 5.6: Backwards Compatibility Tests
--============================================================================

local function testV1ClientIgnoresDeltaPrefix()
    setupDeltaTest("TestGuild")
    
    -- Setup Guild.Info
    Guild.Info = Guild.Info or {}
    Guild.Info.name = "TestGuild"
    
    -- Directly set protocol version in database for V1Client
    local db = Database.db.faction["TestGuild"]
    db.guildProtocolVersions = db.guildProtocolVersions or {}
    db.guildProtocolVersions["V1Client"] = {
        version = 1,  -- Using 'version' not 'protocolVersion'
        lastSeen = GetServerTime(),
        supportsDelta = false
    }
    
    -- V1 clients should have protocol version 1
    local peerInfo = Guild:GetPeerCapabilities("V1Client")
    assertNotNil(peerInfo, "Should have peer info")
    assertEquals(1, peerInfo.version, "V1 client should have protocol version 1")
    assert(peerInfo.version < 2, "V1 client should not support delta (version < 2)")
end

local function testV2ClientHandlesBothProtocols()
    -- V2 clients should have protocol version 2
    assert(PROTOCOL.VERSION == 2, "Current protocol should be v2")
    assert(PROTOCOL.SUPPORTS_DELTA, "Current protocol should support delta")
end

local function testFallbackToFullSync()
    setupDeltaTest("TestGuild")
    
    -- Setup Guild.Info
    Guild.Info = Guild.Info or {}
    Guild.Info.name = "TestGuild"
    
    -- v0.8.0: Guild support threshold removed - delta always enabled if feature flag is on
    -- This test now validates that delta is enabled regardless of guild support percentage
    local oldGetGuildDeltaSupport = Database.GetGuildDeltaSupport
    Database.GetGuildDeltaSupport = function(name)
        return 0  -- 0% support
    end
    
    -- Should still use delta in v0.8.0 (threshold check removed)
    local shouldUse = Guild:ShouldUseDelta()
    assert(shouldUse, "v0.8.0: Should use delta even with 0% guild support (threshold removed)")
    
    -- Restore
    Database.GetGuildDeltaSupport = oldGetGuildDeltaSupport
end

--============================================================================
-- Test Runner
--============================================================================

function Tests:RunAllTests()
    testResults = {}
    addon:Print("=== Running TOGBank Delta Sync Tests ===")
    
    -- Phase 5.1: Delta Computation
    addon:Print("\n|cff00ffffPhase 5.1: Delta Computation Tests|r")
    runTest("Delta Computation - No Changes", testDeltaComputationNoChanges)
    runTest("Delta Computation - Money Change", testDeltaComputationMoneyChange)
    runTest("Delta Computation - Item Added", testDeltaComputationItemAdded)
    runTest("Delta Computation - Item Removed", testDeltaComputationItemRemoved)
    runTest("Delta Computation - Item Count Changed", testDeltaComputationItemCountChanged)
    runTest("Delta Computation - Multiple Changes", testDeltaComputationMultipleChanges)
    runTest("Items Equal - Comparison", testItemsEqual)
    runTest("Get Changed Fields", testGetChangedFields)
    
    -- Phase 5.2: Size Estimation
    addon:Print("\n|cff00ffffPhase 5.2: Size Estimation Tests|r")
    runTest("Size Estimation - Empty", testSizeEstimationEmpty)
    runTest("Size Estimation - Small Delta", testSizeEstimationSmallDelta)
    runTest("Size Estimation - Large Delta", testSizeEstimationLargeDelta)
    runTest("Size Estimation - Comparison", testSizeEstimationComparison)
    
    -- Phase 5.3: Protocol Negotiation
    addon:Print("\n|cff00ffffPhase 5.3: Protocol Negotiation Tests|r")
    runTest("Protocol Version Detection", testProtocolVersionDetection)
    runTest("Should Use Delta Logic", testShouldUseDeltaLogic)
    runTest("Delta Support Threshold", testDeltaSupportThreshold)
    
    -- Phase 5.4: Error Handling
    addon:Print("\n|cff00ffffPhase 5.4: Error Handling Tests|r")
    runTest("Apply Delta - No Existing Data", testApplyDeltaNoExistingData)
    runTest("Apply Delta - Version Mismatch", testApplyDeltaVersionMismatch)
    runTest("Delta Error Tracking", testDeltaErrorTracking)
    runTest("Snapshot Validation", testSnapshotValidation)
    runTest("Delta Structure Validation", testDeltaStructureValidation)
    
    -- Phase 5.5: Integration Tests
    addon:Print("\n|cff00ffffPhase 5.5: Integration Tests|r")
    runTest("Full Delta Roundtrip", testFullDeltaRoundtrip)
    runTest("Delta Size Threshold", testDeltaSizeThreshold)
    
    -- Phase 5.6: Backwards Compatibility
    addon:Print("\n|cff00ffffPhase 5.6: Backwards Compatibility Tests|r")
    runTest("V1 Client Ignores Delta Prefix", testV1ClientIgnoresDeltaPrefix)
    runTest("V2 Client Handles Both Protocols", testV2ClientHandlesBothProtocols)
    runTest("Fallback to Full Sync", testFallbackToFullSync)
    
    -- Summary
    local passed = 0
    local failed = 0
    for _, result in ipairs(testResults) do
        if result.passed then
            passed = passed + 1
        else
            failed = failed + 1
        end
    end
    
    addon:Print(string.format("\n|cff00ffff=== Test Summary ===|r\nTotal: %d | |cff00ff00Passed: %d|r | |cffff0000Failed: %d|r", 
        passed + failed, passed, failed))
    
    if failed > 0 then
        addon:Print("|cffff0000Some tests failed. See output above for details.|r")
    else
        addon:Print("|cff00ff00All tests passed!|r")
    end
    
    return failed == 0
end

function Tests:RunTest(testName)
    testResults = {}
    
    local tests = {
        ["no-changes"] = testDeltaComputationNoChanges,
        ["money-change"] = testDeltaComputationMoneyChange,
        ["item-added"] = testDeltaComputationItemAdded,
        ["item-removed"] = testDeltaComputationItemRemoved,
        ["item-count"] = testDeltaComputationItemCountChanged,
        ["multiple-changes"] = testDeltaComputationMultipleChanges,
        ["items-equal"] = testItemsEqual,
        ["changed-fields"] = testGetChangedFields,
        ["size-empty"] = testSizeEstimationEmpty,
        ["size-small"] = testSizeEstimationSmallDelta,
        ["size-large"] = testSizeEstimationLargeDelta,
        ["size-compare"] = testSizeEstimationComparison,
        ["protocol-detect"] = testProtocolVersionDetection,
        ["should-delta"] = testShouldUseDeltaLogic,
        ["support-threshold"] = testDeltaSupportThreshold,
        ["error-no-data"] = testApplyDeltaNoExistingData,
        ["error-version"] = testApplyDeltaVersionMismatch,
        ["error-tracking"] = testDeltaErrorTracking,
        ["snapshot-validate"] = testSnapshotValidation,
        ["delta-validate"] = testDeltaStructureValidation,
        ["roundtrip"] = testFullDeltaRoundtrip,
        ["size-threshold"] = testDeltaSizeThreshold,
        ["v1-ignore"] = testV1ClientIgnoresDeltaPrefix,
        ["v2-both"] = testV2ClientHandlesBothProtocols,
        ["fallback"] = testFallbackToFullSync,
    }
    
    local testFunc = tests[testName]
    if testFunc then
        runTest(testName, testFunc)
    else
        addon:Print("|cffff0000Unknown test: " .. testName .. "|r")
        addon:Print("Available tests:")
        for name in pairs(tests) do
            addon:Print("  - " .. name)
        end
    end
end

-- Note: Test command is now /togbank test (handled in Chat.lua)

