TOGBankClassic_Core = LibStub("AceAddon-3.0"):NewAddon("TOGBankClassic", "AceComm-3.0", "AceConsole-3.0", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
local AceComm_SendCommMessage = TOGBankClassic_Core.SendCommMessage

function TOGBankClassic_Core:SendCommMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
    if IsInRaid() then
        return
    end
    if not AceComm_SendCommMessage then
        return
    end
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

-- Debug print helper (no-op unless enabled by a module flag)
function TOGBankClassic_Core:DebugPrint(...)
    -- Modules can check their own debug flag and call this when desired.
    -- Keep this simple: always print (modules gate the calls).
    TOGBankClassic_Core:Print("[DEBUG]", ...)
end
