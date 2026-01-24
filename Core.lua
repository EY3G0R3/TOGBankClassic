TOGBankClassic_Core = LibStub("AceAddon-3.0"):NewAddon("TOGBankClassic", "AceComm-3.0", "AceConsole-3.0", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
local AceComm_SendCommMessage = TOGBankClassic_Core.SendCommMessage

function TOGBankClassic_Core:SendCommMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
    local prefixDesc = COMM_PREFIX_DESCRIPTIONS[prefix] or "(Unknown)"
    if IsInRaid() then
        TOGBankClassic_Output:Debug("COMMS", "< (suppressing) %s %s (in raid)", prefix, prefixDesc)
        return
    end
    if not AceComm_SendCommMessage then
        return
    end

    local bytes = text and #text or 0
    TOGBankClassic_Output:Debug("COMMS", "< %s %s to %s (%d bytes)", prefix, prefixDesc, distribution, bytes)

    return AceComm_SendCommMessage(self, prefix, text, distribution, target, prio, callbackFn, callbackArg)
end

-- Centralized WHISPER send with automatic online check
-- Returns true if sent, false if target offline or send failed
function TOGBankClassic_Core:SendWhisper(prefix, text, target, prio, callbackFn, callbackArg)
    -- Check if target is online
    if not TOGBankClassic_Guild:IsPlayerOnline(target) then
        TOGBankClassic_Output:Debug("WHISPER", "Cannot send %s WHISPER to %s - player is offline", prefix, target)
        return false
    end

    -- Send the whisper
    self:SendCommMessage(prefix, text, "WHISPER", target, prio, callbackFn, callbackArg)
    return true
end

function TOGBankClassic_Core:OnInitialize()
    -- Called when the addon is loaded
    TOGBankClassic_Output:Init()
    TOGBankClassic_Database:Init()
    TOGBankClassic_Chat:Init()
    TOGBankClassic_Options:Init()
    TOGBankClassic_UI:Init()

    -- Enable VersionCheck-1.0 addon integration
    do
        local VC = LibStub:GetLibrary("VersionCheck-1.0", true)
        if VC and VC.Enable then
            -- Create a host addon object for VersionCheck
            local hostAddon = {
                GetName = function() return "TOGBankClassic" end,
                Version = (C_AddOns and C_AddOns.GetAddOnMetadata("TOGBankClassic", "Version")) or GetAddOnMetadata("TOGBankClassic", "Version") or "@project-version@"
            }
            VC:Enable(hostAddon)
            TOGBankClassic_Output:Debug("PROTOCOL", "VersionCheck-1.0 integration enabled (v%s)", hostAddon.Version)
        end
    end
end

function TOGBankClassic_Core:OnEnable()
    -- Called when the addon is enabled
    TOGBankClassic_Events:RegisterEvents()
end

function TOGBankClassic_Core:OnDisable()
    -- Called when the addon is disabled
    TOGBankClassic_Events:UnregisterEvents()
end

-- Checksum implementation for message integrity
-- Uses a simple but effective hash that detects corruption
local CHECKSUM_SEPARATOR = "\030" -- ASCII Record Separator, not used by AceSerializer

local function ComputeChecksum(str)
    if not str or type(str) ~= "string" then
        return 0
    end
    -- Simple additive checksum with bit mixing for better distribution
    local sum = 0
    local len = #str
    for i = 1, len do
        local byte = string.byte(str, i)
        sum = (sum * 31 + byte) % 2147483647
    end
    -- Include length to catch truncation
    sum = (sum * 31 + len) % 2147483647
    return sum
end

-- Serialize data with appended checksum for integrity verification
function TOGBankClassic_Core:SerializeWithChecksum(data)
    local serialized = self:Serialize(data)
    if not serialized then
        return nil
    end
    local checksum = ComputeChecksum(serialized)
    return serialized .. CHECKSUM_SEPARATOR .. tostring(checksum)
end

-- Deserialize data and verify checksum; returns success, data (or nil, error)
function TOGBankClassic_Core:DeserializeWithChecksum(message)
    if not message or type(message) ~= "string" then
        return false, "invalid message"
    end

    -- Find the checksum separator from the end
    local sepPos = string.find(message, CHECKSUM_SEPARATOR, 1, true)
    if not sepPos then
        -- No checksum found - fall back to regular deserialize for backwards compatibility
        return self:Deserialize(message)
    end

    local serialized = string.sub(message, 1, sepPos - 1)
    local checksumStr = string.sub(message, sepPos + 1)
    local expectedChecksum = tonumber(checksumStr)

    if not expectedChecksum then
        return false, "invalid checksum format"
    end

    local actualChecksum = ComputeChecksum(serialized)
    if actualChecksum ~= expectedChecksum then
        return false, "checksum mismatch (expected " .. expectedChecksum .. ", got " .. actualChecksum .. ")"
    end

    return self:Deserialize(serialized)
end

-- Delta functions delegated to DeltaComms module (v0.7.0+)
function TOGBankClassic_Core:ValidateDeltaStructure(delta)
	return TOGBankClassic_DeltaComms:ValidateDeltaStructure(delta)
end

function TOGBankClassic_Core:ValidateItemDelta(itemDelta)
	return TOGBankClassic_DeltaComms:ValidateItemDelta(itemDelta)
end

function TOGBankClassic_Core:SanitizeDelta(delta)
	return TOGBankClassic_DeltaComms:SanitizeDelta(delta)
end

function TOGBankClassic_Core:SanitizeItemDelta(itemDelta)
	return TOGBankClassic_DeltaComms:SanitizeItemDelta(itemDelta)
end

function TOGBankClassic_Core:ComputeInventoryHash(bank, bags, money)
	return TOGBankClassic_DeltaComms:ComputeInventoryHash(bank, bags, money)
end