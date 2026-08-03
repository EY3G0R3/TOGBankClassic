-- Luacheck configuration for TOGBankClassic (WoW Classic Era + TBC addon).
--
-- Tames the false positives luacheck produces on WoW addon code: the game client injects a
-- large global API at runtime (so "accessing undefined variable 'C_Container'" and friends are
-- not real problems), addon methods frequently don't use their implicit `self`, and the debug
-- format strings run long.
--
-- This mirrors the globals list in .luarc.json — when you add a WoW API call, add it to BOTH.

std = "lua51"
codes = true
self = false                 -- methods needn't use their implicit `self`
max_line_length = false      -- debug format strings and comments run long by nature

-- Globals the addon owns and assigns. Every module publishes itself as one of these
-- (see the module-namespace rule in CLAUDE.md), plus the SavedVariables from the .toc.
globals = {
	-- Module namespaces
	"TOGBankClassic_Core", "TOGBankClassic_Compat", "TOGBankClassic_Output",
	"TOGBankClassic_Performance", "TOGBankClassic_DeltaComms", "TOGBankClassic_Bank",
	"TOGBankClassic_Chat", "TOGBankClassic_Database", "TOGBankClassic_Events",
	"TOGBankClassic_Guild", "TOGBankClassic_P2PSession", "TOGBankClassic_RequestLog",
	"TOGBankClassic_Item", "TOGBankClassic_ItemHighlight", "TOGBankClassic_TooltipBankerInfo",
	"TOGBankClassic_Mail", "TOGBankClassic_MailInventory", "TOGBankClassic_Options",
	"TOGBankClassic_UI", "TOGBankClassic_Tests",
	"TOGBankClassic_UI_Donations", "TOGBankClassic_UI_StatusBar", "TOGBankClassic_UI_Inventory",
	"TOGBankClassic_UI_Mail", "TOGBankClassic_UI_Minimap", "TOGBankClassic_UI_Requests",
	"TOGBankClassic_UI_Search",
	-- Static data tables
	"TOGBankClassic_ItemDB", "TOGBankClassic_SuffixDB",
	-- SavedVariables (see .toc)
	"TOGBankClassicDB", "TOGBankClassicIconDB", "TOGBankClassicOptionDB",
	"TOGBankClassicDB_DebugLog", "TOGBankClassic_PerfMetrics", "TOGBankClassic_PerfEnabled",
	"TOGBankClassic_DebugLogEnabled",
	-- Bare globals declared by Modules/Constants.lua.
	-- NOTE: audit NS-001 — these should move under a TOGBankClassic_ prefix. Listed here so
	-- luacheck is quiet until that refactor lands, not as an endorsement of the current shape.
	"ADOPTION_STATUS", "TIMER_INTERVALS", "LOG_LEVEL", "DEBUG_CATEGORY", "DEBUG_TAGS",
	"REQUEST_LOG", "REQUESTS_SYNC", "COMM_PREFIX_DESCRIPTIONS", "PROTOCOL", "PEER_TO_PEER",
	"FEATURES",
	-- Bare global function declared by Modules/Guild.lua (audit NS-001).
	"GetPlayerWithNormalizedRealm",
}

-- WoW client APIs, UI globals and localized string constants the addon reads.
read_globals = {
	-- Core Lua-ish WoW helpers
	"strsplit", "strjoin", "strtrim", "wipe", "tContains", "unpack", "hooksecurefunc",
	"debugprofilestop", "GetTime", "GetServerTime", "time", "date", "format",
	-- Addon / metadata
	"LibStub", "GetAddOnMetadata", "C_AddOns", "UpdateAddOnMemoryUsage", "GetAddOnMemoryUsage",
	-- Frames / UI
	"CreateFrame", "UIParent", "GameTooltip", "GameFontNormal", "BackdropTemplateMixin",
	"StaticPopupDialogs", "StaticPopup_Show", "SlashCmdList", "BankFrame", "MailFrame",
	"MailFrameTab2", "DEFAULT_CHAT_FRAME", "NUM_CHAT_WINDOWS", "GetChatWindowInfo",
	"ChatFrame1", "ChatFrame_AddMessageEventFilter", "ChatFrame_RemoveAllMessageGroups",
	"ChatFrame_RemoveAllChannels", "ChatEdit_InsertLink", "FCF_SetWindowName",
	"FCF_SetWindowColor", "FCF_SetLocked", "FCF_DockFrame", "FCF_SelectDockFrame",
	"FCF_ResetChatWindows",
	-- Player / realm / guild
	"UnitName", "GetRealmName", "GetNormalizedRealmName", "IsInGuild", "IsInRaid",
	"GetGuildInfo", "GetNumGuildMembers", "GetGuildRosterInfo", "GuildRoster", "C_GuildInfo",
	"CanViewOfficerNote", "GetMoney",
	-- Items / containers
	"C_Container", "C_Item", "C_CurrencyInfo", "Item", "GetItemInfo", "GetItemInfoInstant",
	"GetItemQualityColor", "GetCoinTextureString", "PickupItem",
	"BANK_CONTAINER", "NUM_BANKGENERIC_SLOTS", "ITEM_UNIQUE",
	-- Mail
	"GetInboxNumItems", "GetInboxHeaderInfo", "GetInboxItem", "GetInboxItemLink",
	"ATTACHMENTS_MAX_RECEIVE", "SendMail", "TakeInboxItem",
	-- Timers
	"C_Timer",
	-- Third-party bag UIs (audit: ELVUI-001 / BAGANATOR-001 integrations)
	"Bagnon", "BagBrother", "ElvUI", "Baganator",
}

-- Unit-test specs run under the bundled runner (or busted), not the WoW client. The runner
-- replaces the global `assert` with a matcher table (assert.same / assert.equal / …), which
-- luacheck reads as field access on the stdlib assert function.
files["Tests"] = {
	std = "lua51+busted",
	ignore = { "143/assert" },
}

-- The harness is a separate public repo (WoWAPITesting) vendored as a submodule; it carries
-- its own lint config and must not be judged by this addon's rules.
exclude_files = {
	"Tests/wowapi",
	"Libs",
	"Modules/Static",   -- multi-megabyte generated data tables
}
