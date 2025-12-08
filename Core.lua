GBankClassic_Core = LibStub("AceAddon-3.0"):NewAddon("GBankClassic", "AceComm-3.0", "AceConsole-3.0", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")

function GBankClassic_Core:OnInitialize()
    -- Called when the addon is loaded
    GBankClassic_Database:Init()
    GBankClassic_Chat:Init()
    GBankClassic_Options:Init()
    GBankClassic_UI:Init()
end

function GBankClassic_Core:OnEnable()
    -- Called when the addon is enabled
    GBankClassic_Events:RegisterEvents()
end

function GBankClassic_Core:OnDisable()
    -- Called when the addon is disabled
    GBankClassic_Events:UnregisterEvents()
end

-- Debug print helper (no-op unless enabled by a module flag)
function GBankClassic_Core:DebugPrint(...)
    -- Modules can check their own debug flag and call this when desired.
    -- Keep this simple: always print (modules gate the calls).
    GBankClassic_Core:Print("[DEBUG]", ...)
end