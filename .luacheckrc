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

-- `_` is the deliberate "I am not using this" marker, and CLAUDE.md requires it for genuinely
-- unused params. WoW APIs return long positional tuples (GetItemInfo returns 14), so skipping to
-- the fields you want means a row of them -- and luacheck reported one unused-variable warning
-- per placeholder, which is noise about the exact convention the project asks for. Ignoring the
-- NAME rather than the warning class keeps every other unused variable a real signal.
-- 431/432 (shadowing an upvalue) is the same class .luarc.json disables as `redefined-local`, and
-- for the same reason: every AceGUI and WoW frame script is written `function(self, event)`, so an
-- inner `self` shadowing an outer one is the universal idiom here rather than a mistake. Leaving it
-- on in one linter and off in the other meant the two tools disagreed about the same file.
ignore = { "_", "431", "432" }

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
	"TOGBankClassic_Switches",
	"TOGBankClassic_Inventory_Record", "TOGBankClassic_Inventory_Resolve",
	"TOGBankClassic_Inventory_Store", "TOGBankClassic_Inventory_Scan",
	"TOGBankClassic_Inventory_Wire",
	"TOGBankClassic_UI_Donations", "TOGBankClassic_UI_StatusBar", "TOGBankClassic_UI_Inventory",
	"TOGBankClassic_UI_Mail", "TOGBankClassic_UI_Minimap", "TOGBankClassic_UI_Requests",
	"TOGBankClassic_UI_Search",
	-- Static data tables
	"TOGBankClassic_ItemDB", "TOGBankClassic_SuffixDB",
	-- SavedVariables (see .toc)
	"TOGBankClassicDB", "TOGBankClassicInvDB", "TOGBankClassicIconDB", "TOGBankClassicOptionDB",
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
	-- Client frames the addon TAGS with a "already hooked" marker field. They are the client's
	-- frames, not ours, but we do write a field on them -- so they belong here rather than in
	-- read_globals, which forbids field assignment and reported every tag as an error.
	-- Modules/Events.lua and Modules/Output.lua both do this; see the marker-spelling note in
	-- Events.lua before adding a third hook to MailFrame.
	"MailFrame", "MailFrameTab2",
	-- The client's popup-dialog registry. Adding a dialog is done by writing a NAMED FIELD into
	-- this table -- that is the documented way to register one -- so it belongs here rather than
	-- in read_globals, which forbids field assignment and reported every dialog as an error.
	-- Modules/UI/Requests.lua registers four.
	"StaticPopupDialogs",
	-- Bagnon's search API is DRIVEN BY ASSIGNMENT: setting `Bagnon.search` is how a consumer runs
	-- a search, and `Bagnon.canSearch` gates it. Declared per FIELD rather than promoting the whole
	-- `Bagnon` table out of read_globals, so writing any OTHER field of a third-party addon's
	-- namespace is still reported -- which is the part worth keeping.
	"Bagnon.search", "Bagnon.canSearch",
}

-- WoW client APIs, UI globals and localized string constants the addon reads.
read_globals = {
	-- Core Lua-ish WoW helpers
	"strsplit", "strjoin", "strtrim", "wipe", "tContains", "unpack", "hooksecurefunc",
	"debugprofilestop", "GetTime", "GetServerTime", "time", "date", "format",
	-- Addon / metadata
	"LibStub", "GetAddOnMetadata", "C_AddOns", "UpdateAddOnMemoryUsage", "GetAddOnMemoryUsage",
	-- The Settings panel API. Feature-detected at every call site (Options:Open), because it is
	-- absent on older clients -- so it is legitimately read without being guaranteed to exist.
	"Settings",
	-- Modifier keys and the client's stack dumper (Modules/UI/Inventory.lua)
	"IsShiftKeyDown", "IsControlKeyDown", "debugstack",
	-- Cursor drag-and-drop, unit level, and the localized "Close" string (Modules/UI/Search.lua)
	"GetCursorInfo", "ClearCursor", "UnitLevel", "CLOSE",
	-- Localized button captions used by the StaticPopupDialogs entries (Modules/UI/Requests.lua)
	"YES", "CANCEL",
	-- Frames / UI
	"CreateFrame", "UIParent", "GameTooltip", "GameFontNormal", "BackdropTemplateMixin",
	"StaticPopupDialogs", "StaticPopup_Show", "SlashCmdList", "BankFrame",
	"DEFAULT_CHAT_FRAME", "NUM_CHAT_WINDOWS", "GetChatWindowInfo",
	"ChatFrame1", "ChatFrame_AddMessageEventFilter", "ChatFrame_RemoveAllMessageGroups",
	"ChatFrame_RemoveAllChannels", "ChatEdit_InsertLink", "FCF_SetWindowName",
	"FCF_SetWindowColor", "FCF_SetLocked", "FCF_DockFrame", "FCF_SelectDockFrame",
	"FCF_ResetChatWindows",
	-- Player / realm / guild
	"UnitName", "GetRealmName", "GetNormalizedRealmName", "IsInGuild", "IsInRaid", "GetClassColor",
	"GetGuildInfo", "GetNumGuildMembers", "GetGuildRosterInfo", "GuildRoster", "C_GuildInfo",
	"CanViewOfficerNote", "GetMoney",
	-- Items / containers
	"C_Container", "C_Item", "C_CurrencyInfo", "Item", "GetItemInfo", "GetItemInfoInstant",
	"GetItemQualityColor", "GetCoinTextureString", "PickupItem",
	-- BANKSLOT-001: the bank/bag geometry constants. All three are ENGINE-SIDE (Constants.lua
	-- assigns them from Constants.InventoryConstants, which the client supplies), so they cannot be
	-- read from Blizzard's source and had to be measured on a live client: on Classic Era they are
	-- 24, 4 and 6. ItemHighlight reads all three rather than hardcoding, because Era and TBC ship
	-- from one source and need not agree.
	"BANK_CONTAINER", "NUM_BANKGENERIC_SLOTS", "NUM_BAG_SLOTS", "NUM_BANKBAGSLOTS",
	"ITEM_UNIQUE", "NUM_CONTAINER_FRAMES",
	-- Mail
	"GetInboxNumItems", "GetInboxHeaderInfo", "GetInboxItem", "GetInboxItemLink",
	"ATTACHMENTS_MAX_RECEIVE", "SendMail", "TakeInboxItem",
	-- Timers
	"C_Timer",
	-- Addon message prefix registration + its result enum (LIBREQ-ALL-005, Modules/Chat.lua)
	"C_ChatInfo", "Enum",
	-- Duration formatting (Modules/UI/StatusBar.lua's "last sync" text)
	"SecondsToTime",
	-- Third-party bag UIs (audit: ELVUI-001 / BAGANATOR-001 integrations)
	"Bagnon", "BagBrother", "ElvUI", "Baganator",
}

-- Unit-test specs run under the bundled runner (or busted), not the WoW client. The runner
-- replaces the global `assert` with a matcher table (assert.same / assert.equal / …), which
-- luacheck reads as field access on the stdlib assert function.
files["Tests"] = {
	std = "lua51+busted",
	ignore = { "143/assert" },
	-- LibStub is read-only to the addon (above) and WRITABLE here, deliberately and only here.
	-- A spec that reloads a LibStub library has to evict `LibStub.libs[major]` and
	-- `.minors[major]` first, or NewLibrary returns nil, the file bails at `if not lib then
	-- return end`, and the spec silently reuses the PREVIOUS spec's library — a false pass that
	-- only appears in a full-suite run. Specs also null a library out to exercise the
	-- absent-dependency path (see guildroster_integration_spec.lua). Both are required test
	-- technique, so the write is legitimate in Tests and remains a real warning everywhere else.
	-- `string.trim` is a WoW client extension to the stdlib string table, not stock Lua 5.1. The
	-- env installs it because addon code calls `s:trim()` and a missing method is a hard error
	-- rather than a wrong answer. Declared as the exact field so setting anything ELSE on `string`
	-- is still reported -- `globals = { "string" }` would have opened the whole table.
	-- GetItemInfoInstant is read-only to the addon (above) and WRITABLE here for the same reason
	-- LibStub is: a spec that wants to prove a memo actually memoises has to COUNT the calls, and
	-- the only way to count calls into a client API is to stand in front of it. Each spec restores
	-- the original immediately; env.reset() reinstalls it regardless.
	-- GameTooltip.HookScript is swapped by tooltipbankerinfo_spec to capture the handler the module
	-- installs -- the only way to assert that our own hook renders through the same public
	-- AppendTo the other addon calls, rather than a second private layout.
	-- C_GuildInfo.CanViewOfficerNote is steered by guildroster_integration_spec (ROSTER-004): it is
	-- a PERMISSION, and the branch under test is the one where the player does NOT have it, which
	-- no fixture can reach by arranging roster data -- the env's default answers true. Declared as
	-- the exact field, like Bagnon.search above, so writing any other field of the client's guild
	-- namespace is still reported.
	globals = { "LibStub", "string.trim", "GetItemInfoInstant", "GameTooltip.HookScript",
		"C_GuildInfo.CanViewOfficerNote" },
}

-- The harness is a separate public repo (WoWAPITesting) vendored as a submodule; it carries
-- its own lint config and must not be judged by this addon's rules.
exclude_files = {
	"Tests/wowapi",
	"Libs",
	"Modules/Static",   -- multi-megabyte generated data tables
}
