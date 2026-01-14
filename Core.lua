TOGBankClassic_Core = LibStub("AceAddon-3.0"):NewAddon("TOGBankClassic", "AceComm-3.0", "AceConsole-3.0", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
local AceComm_SendCommMessage = TOGBankClassic_Core.SendCommMessage

function TOGBankClassic_Core:SendCommMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
    local prefixDesc = COMM_PREFIX_DESCRIPTIONS[prefix] or "(Unknown)"
    if IsInRaid() then
        TOGBankClassic_Output:Debug("< (suppressing) %s %s (in raid)", prefix, prefixDesc)
        return
    end
    if not AceComm_SendCommMessage then
        return
    end

    local bytes = text and #text or 0
    TOGBankClassic_Output:Debug("< %s %s to %s (%d bytes)", prefix, prefixDesc, distribution, bytes)

    return AceComm_SendCommMessage(self, prefix, text, distribution, target, prio, callbackFn, callbackArg)
end

function TOGBankClassic_Core:OnInitialize()
    -- Called when the addon is loaded
    TOGBankClassic_Database:Init()
    TOGBankClassic_Chat:Init()
    TOGBankClassic_Options:Init()
    TOGBankClassic_UI:Init()
end

function TOGBankClassic_Core:OnEnable()
    -- Called when the addon is enabled
    TOGBankClassic_Events:RegisterEvents()
end

function TOGBankClassic_Core:OnDisable()
    -- Called when the addon is disabled
    TOGBankClassic_Events:UnregisterEvents()
end
