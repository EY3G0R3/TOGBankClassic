TOGBankClassic_Core = LibStub("AceAddon-3.0"):NewAddon("TOGBankClassic", "AceComm-3.0", "AceConsole-3.0", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
local AceComm_SendCommMessage = TOGBankClassic_Core.SendCommMessage

function TOGBankClassic_Core:SendCommMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
    local prefixDesc = COMM_PREFIX_DESCRIPTIONS[prefix] or "(Unknown)"
    if IsInRaid() then
        TOGBankClassic_Output:Debug("COMMS", "SUPPRESS", "< (suppressing) %s %s (in raid)", prefix, prefixDesc)
        return
    end
    if not AceComm_SendCommMessage then
        return
    end

    local bytes = text and #text or 0
    local dest = (target and target ~= "") and (distribution .. "/" .. target) or distribution
    TOGBankClassic_Output:Debug("COMMS", "SEND", "< %s %s to %s (%d bytes)", prefix, prefixDesc, dest, bytes)

    return AceComm_SendCommMessage(self, prefix, text, distribution, target, prio, callbackFn, callbackArg)
end

-- Centralized WHISPER send with automatic online check
-- Returns true if sent, false if target offline or send failed
function TOGBankClassic_Core:SendWhisper(prefix, text, target, prio, callbackFn, callbackArg)
    -- Check if target is online
    local isOnline = TOGBankClassic_Guild:IsPlayerOnline(target)
    TOGBankClassic_Output:Debug("PROTOCOL", "WHISPER", "[WHISPER-DEBUG] SendWhisper called: prefix=%s, target=%s, isOnline=%s",
        prefix, target, tostring(isOnline))

    if not isOnline then
        TOGBankClassic_Output:Debug("WHISPER", "SKIP", "[WHISPER-DEBUG] Cannot send %s WHISPER to %s - player is offline", prefix, target)
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

    TOGBankClassic_Output:Debug("PROTOCOL", "WHISPER", "[WHISPER-DEBUG] Attempting SendCommMessage: prefix=%s, target=%s, nameOnly=%s", prefix, target, nameOnly)

    -- Send the whisper (AceComm returns nil on success, which is truthy behavior we want)
    self:SendCommMessage(prefix, text, "WHISPER", nameOnly, prio, callbackFn, callbackArg)

    TOGBankClassic_Output:Debug("PROTOCOL", "WHISPER", "[WHISPER-DEBUG] SendCommMessage completed for %s to %s", prefix, nameOnly)

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
            TOGBankClassic_Output:Debug("PROTOCOL", "INIT", "VersionCheck-1.0 integration enabled (v%s)", hostAddon.Version)
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
-- Stop-marker appended after checksum; its presence (O(4) check) confirms message was not
-- truncated mid-flight.  Used in parallel with the O(N) CRC to distinguish truncation from
-- genuine bit-corruption.  \031 (Unit Separator) is not emitted by AceSerializer.
local STOP_MARKER = "\031END"

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

-- Serialize data with appended checksum and stop-marker for integrity verification.
-- Wire format:  <AceSerialized> \030 <checksum> \031END
function TOGBankClassic_Core:SerializeWithChecksum(data)
    local serialized = self:Serialize(data)
    if not serialized then
        return nil
    end
    local checksum = ComputeChecksum(serialized)
    return serialized .. CHECKSUM_SEPARATOR .. tostring(checksum) .. STOP_MARKER
end

-- Deserialize data and verify integrity; returns success, data (or nil, error).
--
-- Two independent checks are run in parallel:
--   1. Stop-marker check (O(k)): was the message fully delivered?
--   2. CRC check (O(N)):         was the message content uncorrupted?
--
-- When both are available and they disagree (stop present but CRC fails) an error is
-- printed to chat — this contradicts the truncation-only hypothesis and means the O(N)
-- CRC cannot safely be replaced by the stop-marker alone.
--
-- Optional ctx table for richer diagnostics: { sender, prefix, distribution }
---@param message string
---@param ctx? table
function TOGBankClassic_Core:DeserializeWithChecksum(message, ctx)
    if not message or type(message) ~= "string" then
        return false, "invalid message"
    end

    -- === Stop-marker check (O(k)) ===
    -- A new-format message ends with STOP_MARKER; old-format messages do not.
    local stopMarkerLen = #STOP_MARKER
    local stopPresent = (string.sub(message, -stopMarkerLen) == STOP_MARKER)

    -- Strip stop-marker before CRC parsing so it doesn't interfere
    local body = stopPresent and string.sub(message, 1, #message - stopMarkerLen) or message

    -- === CRC check (O(N)) ===
    -- Find the checksum separator from the end of body (payload itself may contain the byte)
    local sepPos = nil
    local sepByte = string.byte(CHECKSUM_SEPARATOR)
    for i = #body, 1, -1 do
        if string.byte(body, i) == sepByte then
            sepPos = i
            break
        end
    end
    if not sepPos then
        -- No checksum found — old client or pre-checksum message; fall back gracefully
        return self:Deserialize(message)
    end

    local serialized    = string.sub(body, 1, sepPos - 1)
    local checksumStr   = string.sub(body, sepPos + 1)
    local expectedChecksum = tonumber(checksumStr)

    if not expectedChecksum then
        return false, "invalid checksum format"
    end

    local actualChecksum = ComputeChecksum(serialized)
    local crcValid       = (actualChecksum == expectedChecksum)

    -- === Parallel comparison (new-format messages only) ===
    -- Disagreement: stop-marker present (message arrived complete) but CRC fails
    -- (content was corrupted).  This is genuine bit-corruption, not truncation — the
    -- O(N) CRC cannot be replaced by the stop-marker.  Always logged to the debug
    -- output; the chat alert is shown only when the tester opt-in is enabled in Options.
    if stopPresent and not crcValid then
        local sender       = ctx and ctx.sender       or "?"
        local prefix       = ctx and ctx.prefix       or "?"
        local distribution = ctx and ctx.distribution or "?"
        local byteCount    = #message
        TOGBankClassic_Output:Debug("PROTOCOL", "INTEGRITY-MISMATCH",
            "stop=PASS crc=FAIL | from=%s prefix=%s dist=%s bytes=%d | expected=%d got=%d",
            sender, prefix, distribution, byteCount, expectedChecksum, actualChecksum)
        if TOGBankClassic_Options and TOGBankClassic_Options:IsIntegrityCheckDiagnosticsEnabled() then
            local msg = "|cFFFF0000[TOGBankClassic ERROR]|r Integrity mismatch: " ..
                "message complete (stop-marker present) but CRC failed. " ..
                "from=" .. sender .. " prefix=" .. prefix .. " dist=" .. distribution ..
                " bytes=" .. byteCount ..
                " expected=" .. expectedChecksum .. " got=" .. actualChecksum ..
                " — please report to developers!"
            DEFAULT_CHAT_FRAME:AddMessage(msg)
        end
    end

    if not crcValid then
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
