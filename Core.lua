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
    local dest = (target and target ~= "") and (distribution .. "/" .. target) or distribution
    TOGBankClassic_Output:Debug("COMMS", "< %s %s to %s (%d bytes)", prefix, prefixDesc, dest, bytes)

    return AceComm_SendCommMessage(self, prefix, text, distribution, target, prio, callbackFn, callbackArg)
end

-- Centralized WHISPER send with automatic online check
-- Returns true if sent, false if target offline or send failed
function TOGBankClassic_Core:SendWhisper(prefix, text, target, prio, callbackFn, callbackArg)
    -- Check if target is online
    local isOnline = TOGBankClassic_Guild:IsPlayerOnline(target)
    TOGBankClassic_Output:Debug("PROTOCOL", "[WHISPER-DEBUG] SendWhisper called: prefix=%s, target=%s, isOnline=%s",
        prefix, target, tostring(isOnline))

    if not isOnline then
        TOGBankClassic_Output:Debug("WHISPER", "[WHISPER-DEBUG] Cannot send %s WHISPER to %s - player is offline", prefix, target)
        return false
    end

    -- Strip realm suffix only for same-realm targets; cross-realm requires full name
    local nameOnly = target
    if target and string.find(target, "-") then
        local left, right = string.match(target, "^(.-)%-(.+)$")
        local currentRealm = GetNormalizedRealmName("player")
        if left and right and currentRealm and right == currentRealm then
            nameOnly = left
        end
    end

    TOGBankClassic_Output:Debug("PROTOCOL", "[WHISPER-DEBUG] Attempting SendCommMessage: prefix=%s, target=%s, nameOnly=%s", prefix, target, nameOnly)

    -- Send the whisper (AceComm returns nil on success, which is truthy behavior we want)
    self:SendCommMessage(prefix, text, "WHISPER", nameOnly, prio, callbackFn, callbackArg)

    TOGBankClassic_Output:Debug("PROTOCOL", "[WHISPER-DEBUG] SendCommMessage completed for %s to %s", prefix, nameOnly)

    -- If we got this far, player is online and whisper was sent
    return true
end

function TOGBankClassic_Core:OnInitialize()
    -- Called when the addon is loaded
    TOGBankClassic_Output:Init()
    TOGBankClassic_Performance:Initialize()
    TOGBankClassic_Database:Init()
    TOGBankClassic_Chat:Init()
    TOGBankClassic_Options:Init()
    TOGBankClassic_UI:Init()

    -- Initialize ItemHighlight module
    if TOGBankClassic_ItemHighlight and TOGBankClassic_ItemHighlight.Initialize then
        TOGBankClassic_ItemHighlight:Initialize()
    end

    -- Setup periodic memory snapshots (every 5 minutes)
    self:ScheduleRepeatingTimer(function()
        TOGBankClassic_Performance:RecordMemory("periodic")
    end, 300)

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

-- Expose Checksum as public method for DeltaComms
function TOGBankClassic_Core:Checksum(str)
    return ComputeChecksum(str)
end

-- Serialize data. Checksum intentionally omitted: WoW uses TCP (transport integrity
-- is guaranteed) and AceSerializer will fail to parse truncated/corrupted payloads
-- on its own. The byte-by-byte Lua checksum loop over 15-50KB payloads was a
-- measurable source of frame stutters on large guilds. DeserializeWithChecksum
-- retains its checksum-verification path for backward compat with old messages.
function TOGBankClassic_Core:SerializeWithChecksum(data)
    local serialized = self:Serialize(data)
    if not serialized then
        return nil
    end
    return serialized
end

-- Deserialize data and verify checksum; returns success, data (or nil, error)
function TOGBankClassic_Core:DeserializeWithChecksum(message)
    if not message or type(message) ~= "string" then
        return false, "invalid message"
    end

    -- Find the checksum separator from the end (payload may contain separator)
    local sepPos = nil
    local sepByte = string.byte(CHECKSUM_SEPARATOR)
    for i = #message, 1, -1 do
        if string.byte(message, i) == sepByte then
            sepPos = i
            break
        end
    end
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

function TOGBankClassic_Core:ComputeInventoryHash(bank, bags, mail, money)
	return TOGBankClassic_DeltaComms:ComputeInventoryHash(bank, bags, mail, money)
end
