TOGBankClassic_Core = LibStub("AceAddon-3.0"):NewAddon("TOGBankClassic", "AceComm-3.0", "AceConsole-3.0", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
local AceComm_SendCommMessage = TOGBankClassic_Core.SendCommMessage

local prefixDescriptions = {
    ["togbank-v"] = "(Version)",
    ["togbank-d"] = "(Data)",
    ["togbank-r"] = "(Query)",
    ["togbank-h"] = "(Hello)",
    ["togbank-hr"] = "(Hello Reply)",
    ["togbank-s"] = "(Share)",
    ["togbank-sr"] = "(Share Reply)",
    ["togbank-w"] = "(Wipe)",
    ["togbank-wr"] = "(Wipe Reply)",
}

function TOGBankClassic_Core:SendCommMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
    if IsInRaid() then
        local prefixDesc = prefixDescriptions[prefix] or "(Unknown)"
        TOGBankClassic_Output:Debug("< (suppressing)", prefix, prefixDesc, "(in raid)")
        return
    end
    if not AceComm_SendCommMessage then
        return
    end

    local prefixDesc = prefixDescriptions[prefix] or "(Unknown)"
    local bytes = text and #text or 0
    TOGBankClassic_Output:Debug("<", prefix, prefixDesc, "to", distribution, "(%d bytes)", bytes)

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
