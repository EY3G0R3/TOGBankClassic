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

-- Helper function to create test data
local function createTestItem(id, count, link)
    return {
        itemID = id,
        count = count or 1,
        link = link or ("item:" .. id),
        quality = 1,
        texture = "Interface\\Icons\\INV_Misc_QuestionMark"
    }
end

local function createTestAltData(name)
    return {
        name = name,
        bank = {
            money = 100000,
            items = {
                [1] = createTestItem(2589, 20, "item:2589"), -- Linen Cloth
                [5] = createTestItem(2592, 10, "item:2592"), -- Wool Cloth
            }
        },
        bags = {
            money = 50000,
            items = {
                [1] = createTestItem(2589, 5, "item:2589"), -- Linen Cloth
                [10] = createTestItem(765, 3, "item:765"), -- Silverleaf
            }
        }
    }
end

--============================================================================
-- Phase 5.1: Delta Computation Tests
--============================================================================

local function testDeltaComputationNoChanges()
    local oldData = createTestAltData("TestAlt1")
    local newData = TableCopy(oldData)
    
    local delta = Guild:ComputeDelta(oldData, newData, 1)
    
    assertNotNil(delta, "Delta should not be nil for identical data")
    assertEquals(2, delta.version, "Delta version should be 2")
    assertEquals(1, delta.baseVersion, "Base version should be 1")
    assert(not Guild:DeltaHasChanges(delta), "Delta should have no changes")
end

local function testDeltaComputationMoneyChange()
    local oldData = createTestAltData("TestAlt2")
    local newData = TableCopy(oldData)
    newData.bank.money = 200000
    
    local delta = Guild:ComputeDelta(oldData, newData, 1)
    
    assertNotNil(delta, "Delta should not be nil")
    assert(Guild:DeltaHasChanges(delta), "Delta should have changes")
    assertEquals(200000, delta.changes.bank.money, "Bank money should be updated")
    assertNil(delta.changes.bags, "Bags should not be in changes")
end

local function testDeltaComputationItemAdded()
    local oldData = createTestAltData("TestAlt3")
    local newData = TableCopy(oldData)
    newData.bank.items[10] = createTestItem(2996, 1, "item:2996") -- Bolt of Linen Cloth
    
    local delta = Guild:ComputeDelta(oldData, newData, 1)
    
    assertNotNil(delta, "Delta should not be nil")
    assert(Guild:DeltaHasChanges(delta), "Delta should have changes")
    assertNotNil(delta.changes.bank.items[10], "New item should be in delta")
    assertEquals(2996, delta.changes.bank.items[10].itemID, "Item ID should match")
end

local function testDeltaComputationItemRemoved()
    local oldData = createTestAltData("TestAlt4")
    local newData = TableCopy(oldData)
    newData.bank.items[1] = nil
    
    local delta = Guild:ComputeDelta(oldData, newData, 1)
    
    assertNotNil(delta, "Delta should not be nil")
    assert(Guild:DeltaHasChanges(delta), "Delta should have changes")
    assert(delta.changes.bank.items[1] == false, "Removed item should be marked false")
end

local function testDeltaComputationItemCountChanged()
    local oldData = createTestAltData("TestAlt5")
    local newData = TableCopy(oldData)
    newData.bank.items[1].count = 25 -- Change from 20 to 25
    
    local delta = Guild:ComputeDelta(oldData, newData, 1)
    
    assertNotNil(delta, "Delta should not be nil")
    assert(Guild:DeltaHasChanges(delta), "Delta should have changes")
    assertNotNil(delta.changes.bank.items[1], "Changed item should be in delta")
    assertEquals(25, delta.changes.bank.items[1].count, "Count should be updated")
end

local function testDeltaComputationMultipleChanges()
    local oldData = createTestAltData("TestAlt6")
    local newData = TableCopy(oldData)
    
    -- Multiple changes
    newData.bank.money = 300000
    newData.bags.money = 75000
    newData.bank.items[1].count = 30
    newData.bank.items[10] = createTestItem(2996, 5)
    newData.bags.items[1] = nil
    
    local delta = Guild:ComputeDelta(oldData, newData, 1)
    
    assertNotNil(delta, "Delta should not be nil")
    assert(Guild:DeltaHasChanges(delta), "Delta should have changes")
    assertEquals(300000, delta.changes.bank.money, "Bank money should be updated")
    assertEquals(75000, delta.changes.bags.money, "Bags money should be updated")
    assertEquals(30, delta.changes.bank.items[1].count, "Item count should be updated")
    assertNotNil(delta.changes.bank.items[10], "New item should be added")
    assert(delta.changes.bags.items[1] == false, "Removed item should be marked false")
end

local function testItemsEqual()
    local item1 = createTestItem(2589, 20, "item:2589")
    local item2 = createTestItem(2589, 20, "item:2589")
    local item3 = createTestItem(2589, 25, "item:2589")
    local item4 = createTestItem(2590, 20, "item:2590")
    
    assert(Guild:ItemsEqual(item1, item2), "Identical items should be equal")
    assert(not Guild:ItemsEqual(item1, item3), "Different counts should not be equal")
    assert(not Guild:ItemsEqual(item1, item4), "Different IDs should not be equal")
    assert(not Guild:ItemsEqual(item1, nil), "Item and nil should not be equal")
    assert(Guild:ItemsEqual(nil, nil), "nil and nil should be equal")
end

local function testGetChangedFields()
    local oldItem = createTestItem(2589, 20, "item:2589")
    local newItem = TableCopy(oldItem)
    newItem.count = 25
    newItem.quality = 2
    
    local changes = Guild:GetChangedFields(oldItem, newItem)
    
    assertNotNil(changes, "Changes should not be nil")
    assertEquals(25, changes.count, "Count change should be captured")
    assertEquals(2, changes.quality, "Quality change should be captured")
    assertNil(changes.itemID, "Unchanged fields should not be in changes")
    assertNil(changes.link, "Unchanged fields should not be in changes")
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
    -- Mock database
    local oldGetPeerProtocol = TOGBankClassic_Database.GetPeerProtocol
    TOGBankClassic_Database.GetPeerProtocol = function(_, norm)
        if norm == "TestRealm-V2User" then
            return 2
        elseif norm == "TestRealm-V1User" then
            return 1
        else
            return nil
        end
    end
    
    local v2Caps = TOGBankClassic_Guild:GetPeerCapabilities("TestRealm-V2User")
    local v1Caps = TOGBankClassic_Guild:GetPeerCapabilities("TestRealm-V1User")
    local unknownCaps = TOGBankClassic_Guild:GetPeerCapabilities("TestRealm-Unknown")
    
    assert(v2Caps.supportsDelta, "V2 user should support delta")
    assert(not v1Caps.supportsDelta, "V1 user should not support delta")
    assert(not unknownCaps.supportsDelta, "Unknown user should not support delta")
    
    -- Restore
    TOGBankClassic_Database.GetPeerProtocol = oldGetPeerProtocol
end

local function testShouldUseDeltaLogic()
    -- Mock functions
    local oldGetSnapshot = TOGBankClassic_Database.GetSnapshot
    local oldGetPeerCapabilities = TOGBankClassic_Guild.GetPeerCapabilities
    local oldFeaturesEnabled = FEATURES.DELTA_ENABLED
    local oldFeaturesForce = FEATURES.FORCE_FULL_SYNC
    
    TOGBankClassic_Database.GetSnapshot = function() return {version = 1, data = {}} end
    TOGBankClassic_Guild.GetPeerCapabilities = function() return {supportsDelta = true} end
    FEATURES.DELTA_ENABLED = true
    FEATURES.FORCE_FULL_SYNC = false
    
    local shouldUse = TOGBankClassic_Guild:ShouldUseDelta("TestRealm-User", {})
    assert(shouldUse, "Should use delta when conditions are met")
    
    -- Test with delta disabled
    FEATURES.DELTA_ENABLED = false
    shouldUse = TOGBankClassic_Guild:ShouldUseDelta("TestRealm-User", {})
    assert(not shouldUse, "Should not use delta when disabled")
    
    -- Test with force full sync
    FEATURES.DELTA_ENABLED = true
    FEATURES.FORCE_FULL_SYNC = true
    shouldUse = TOGBankClassic_Guild:ShouldUseDelta("TestRealm-User", {})
    assert(not shouldUse, "Should not use delta when forced full sync")
    
    -- Restore
    TOGBankClassic_Database.GetSnapshot = oldGetSnapshot
    TOGBankClassic_Guild.GetPeerCapabilities = oldGetPeerCapabilities
    FEATURES.DELTA_ENABLED = oldFeaturesEnabled
    FEATURES.FORCE_FULL_SYNC = oldFeaturesForce
end

local function testDeltaSupportThreshold()
    local oldGetGuildDeltaSupport = TOGBankClassic_Database.GetGuildDeltaSupport
    
    -- Test below threshold
    TOGBankClassic_Database.GetGuildDeltaSupport = function() return 0.3 end -- 30%
    local support = TOGBankClassic_Database:GetGuildDeltaSupport()
    assert(support < PROTOCOL.DELTA_SUPPORT_THRESHOLD, "30% should be below 50% threshold")
    
    -- Test above threshold
    TOGBankClassic_Database.GetGuildDeltaSupport = function() return 0.7 end -- 70%
    support = TOGBankClassic_Database:GetGuildDeltaSupport()
    assert(support >= PROTOCOL.DELTA_SUPPORT_THRESHOLD, "70% should be above 50% threshold")
    
    -- Restore
    TOGBankClassic_Database.GetGuildDeltaSupport = oldGetGuildDeltaSupport
end

--============================================================================
-- Phase 5.4: Error Handling Tests
--============================================================================

local function testApplyDeltaNoExistingData()
    local delta = {
        version = 2,
        baseVersion = 1,
        changes = {
            bank = { money = 100000 }
        }
    }
    
    -- Should fail because no existing data
    local success = Guild:ApplyDelta("TestRealm", "NonExistent", delta)
    assert(not success, "Should fail when no existing data")
end

local function testApplyDeltaVersionMismatch()
    -- Mock database
    local oldGetAltData = Database.GetAltData
    Database.GetAltData = function()
        return {
            version = 5, -- Different from delta baseVersion
            data = createTestAltData("TestAlt")
        }
    end
    
    local delta = {
        version = 2,
        baseVersion = 1, -- Mismatched
        changes = {
            bank = { money = 100000 }
        }
    }
    
    local success = Guild:ApplyDelta("TestRealm", "TestAlt", delta)
    assert(not success, "Should fail on version mismatch")
    
    -- Restore
    Database.GetAltData = oldGetAltData
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
    -- Valid snapshot
    local validSnapshot = {
        version = 1,
        timestamp = time(),
        data = createTestAltData("TestAlt")
    }
    assert(Database:ValidateSnapshot(validSnapshot), "Valid snapshot should pass")
    
    -- Invalid: missing version
    local invalidSnapshot1 = {
        timestamp = time(),
        data = createTestAltData("TestAlt")
    }
    assert(not Database:ValidateSnapshot(invalidSnapshot1), "Missing version should fail")
    
    -- Invalid: version not a number
    local invalidSnapshot2 = {
        version = "not a number",
        timestamp = time(),
        data = createTestAltData("TestAlt")
    }
    assert(not Database:ValidateSnapshot(invalidSnapshot2), "Non-numeric version should fail")
    
    -- Invalid: corrupted bank structure
    local invalidSnapshot3 = {
        version = 1,
        timestamp = time(),
        data = {
            bank = "not a table"
        }
    }
    assert(not Database:ValidateSnapshot(invalidSnapshot3), "Corrupted bank should fail")
end

local function testDeltaStructureValidation()
    -- Valid delta
    local validDelta = {
        version = 2,
        baseVersion = 1,
        changes = {
            bank = { money = 100000 }
        }
    }
    assert(addon:ValidateDeltaStructure(validDelta), "Valid delta should pass")
    
    -- Invalid: missing version
    local invalidDelta1 = {
        baseVersion = 1,
        changes = {}
    }
    assert(not addon:ValidateDeltaStructure(invalidDelta1), "Missing version should fail")
    
    -- Invalid: missing baseVersion
    local invalidDelta2 = {
        version = 2,
        changes = {}
    }
    assert(not addon:ValidateDeltaStructure(invalidDelta2), "Missing baseVersion should fail")
    
    -- Invalid: changes not a table
    local invalidDelta3 = {
        version = 2,
        baseVersion = 1,
        changes = "not a table"
    }
    assert(not addon:ValidateDeltaStructure(invalidDelta3), "Non-table changes should fail")
end

--============================================================================
-- Phase 5.5: Integration Tests
--============================================================================

local function testFullDeltaRoundtrip()
    -- Create initial data
    local oldData = createTestAltData("IntegrationTest")
    local snapshot = {
        version = 1,
        timestamp = time(),
        data = oldData
    }
    
    -- Make changes
    local newData = TableCopy(oldData)
    newData.bank.money = 200000
    newData.bank.items[10] = createTestItem(2996, 5)
    newData.bags.items[1] = nil
    
    -- Compute delta
    local delta = Guild:ComputeDelta(snapshot.data, newData, 1)
    assertNotNil(delta, "Delta should be computed")
    
    -- Mock GetAltData for ApplyDelta
    local oldGetAltData = Database.GetAltData
    Database.GetAltData = function()
        return {version = 1, data = oldData}
    end
    
    local oldSetAltData = Database.SetAltData
    local appliedData = nil
    Database.SetAltData = function(_, _, _, data)
        appliedData = data
    end
    
    -- Apply delta
    local success = Guild:ApplyDelta("TestRealm", "IntegrationTest", delta)
    assert(success, "Delta should apply successfully")
    assertNotNil(appliedData, "Data should be saved")
    
    -- Verify changes
    assertEquals(200000, appliedData.bank.money, "Bank money should be updated")
    assertNotNil(appliedData.bank.items[10], "New item should be added")
    assertNil(appliedData.bags.items[1], "Item should be removed")
    
    -- Restore
    Database.GetAltData = oldGetAltData
    Database.SetAltData = oldSetAltData
end

local function testDeltaSizeThreshold()
    local oldData = createTestAltData("SizeTest")
    local newData = TableCopy(oldData)
    
    -- Small change
    newData.bank.money = 200000
    local delta = Guild:ComputeDelta(oldData, newData, 1)
    
    local fullSize = Guild:EstimateSize(newData)
    local deltaSize = Guild:EstimateSize(delta)
    local ratio = deltaSize / fullSize
    
    assert(ratio < addon.PROTOCOL.MIN_DELTA_SIZE_RATIO, 
        "Small change should be below size threshold")
end

--============================================================================
-- Phase 5.6: Backwards Compatibility Tests
--============================================================================

local function testV1ClientIgnoresDeltaPrefix()
    -- V1 clients should not have togbank-d2 registered
    -- This is implicitly tested by protocol negotiation
    local caps = TOGBankClassic_Guild:GetPeerCapabilities("TestRealm-V1Client")
    assert(not caps.supportsDelta, "V1 client should not support delta")
end

local function testV2ClientHandlesBothProtocols()
    -- V2 clients should handle both togbank-d and togbank-d2
    local caps = TOGBankClassic_Guild:GetPeerCapabilities("TestRealm-V2Client")
    
    -- We can't directly test comm handlers, but we can verify protocol version
    assert(PROTOCOL.VERSION == 2, "Current protocol should be v2")
    assert(PROTOCOL.SUPPORTS_DELTA, "Current protocol should support delta")
end

local function testFallbackToFullSync()
    -- When peer doesn't support delta, should use full sync
    local oldGetPeerCapabilities = TOGBankClassic_Guild.GetPeerCapabilities
    TOGBankClassic_Guild.GetPeerCapabilities = function()
        return {supportsDelta = false}
    end
    
    local shouldUse = TOGBankClassic_Guild:ShouldUseDelta("TestRealm-V1Client", {})
    assert(not shouldUse, "Should not use delta with V1 client")
    
    -- Restore
    TOGBankClassic_Guild.GetPeerCapabilities = oldGetPeerCapabilities
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

