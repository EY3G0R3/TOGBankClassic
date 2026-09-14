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
	"TOGBankClassic_Guild", "TOGBankClassic_BankerNumbers", "TOGBankClassic_P2PSession", "TOGBankClassic_RequestLog",
	"TOGBankClassic_Log", "TOGBankClassic_Propagation",
	"TOGBankClassic_Item", "TOGBankClassic_ItemHighlight", "TOGBankClassic_TooltipBankerInfo",
	"TOGBankClassic_Mail", "TOGBankClassic_MailInventory", "TOGBankClassic_Options",
	"TOGBankClassic_UI", "TOGBankClassic_Tests",
	"TOGBankClassic_Switches",
	"TOGBankClassic_Inventory_Record", "TOGBankClassic_Inventory_Resolve",
	"TOGBankClassic_Inventory_Store", "TOGBankClassic_Inventory_Scan", "TOGBankClassic_Inventory_Chain",
	"TOGBankClassic_Inventory_Wire", "TOGBankClassic_Inventory_Sync",
	"TOGBankClassic_UI_Donations", "TOGBankClassic_UI_StatusBar", "TOGBankClassic_UI_Inventory",
	"TOGBankClassic_UI_Mail", "TOGBankClassic_UI_Minimap", "TOGBankClassic_UI_Requests",
	"TOGBankClassic_UI_Search", "TOGBankClassic_UI_Mailbox",
	"TOGBankClassic_UI_RowList", "TOGBankClassic_UI_Browse", "TOGBankClassic_Usable",
	-- Static data tables
	"TOGBankClassic_ItemDB", "TOGBankClassic_SuffixDB",
	-- SavedVariables (see .toc)
	"TOGBankClassicDB", "TOGBankClassicInvDB", "TOGBankClassicIconDB", "TOGBankClassicOptionDB",
	"TOGBankClassicDB_DebugLog", "TOGBankClassic_PerfMetrics", "TOGBankClassic_PerfEnabled",
	"TOGBankClassic_DebugLogEnabled",
	-- NS-001 (fixed): the shared constant tables, published as ONE global by Modules/Constants.lua.
	-- The eleven bare globals that used to be listed here -- ADOPTION_STATUS, TIMER_INTERVALS,
	-- LOG_LEVEL, DEBUG_CATEGORY, DEBUG_TAGS, REQUEST_LOG, REQUESTS_SYNC, COMM_PREFIX_DESCRIPTIONS,
	-- PROTOCOL, PEER_TO_PEER, FEATURES -- plus the bare `GetPlayerWithNormalizedRealm` function from
	-- Guild.lua are GONE, and their absence from this list is now load-bearing rather than cosmetic:
	-- a stray bare `DEBUG_CATEGORY` is an undefined-variable warning here instead of a silent read of
	-- whatever another installed addon happens to have published under that name. Do not re-add them.
	"TOGBankClassic_Constants",
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
	-- The client's error handler, for routing a CONSUMER's callback error (Modules/Log.lua) to
	-- BugSack/the default frame rather than swallowing it. Feature-detected: absent offline.
	"geterrorhandler",
	-- Addon / metadata
	"LibStub", "GetAddOnMetadata", "C_AddOns", "UpdateAddOnMemoryUsage", "GetAddOnMemoryUsage",
	-- The Settings panel API. Feature-detected at every call site (Options:Open), because it is
	-- absent on older clients -- so it is legitimately read without being guaranteed to exist.
	"Settings",
	-- Modifier keys and the client's stack dumper (Modules/UI/Inventory.lua)
	"IsShiftKeyDown", "IsControlKeyDown", "debugstack",
	-- Cursor drag-and-drop, unit level, and the localized "Close" string (Modules/UI/Search.lua)
	"GetCursorInfo", "ClearCursor", "UnitLevel", "CLOSE",
	-- BROWSE-004 (Modules/Usable.lua): the character's class and race, the tooltip-data API
	-- Classic Era's own TooltipComparisonManager reads (feature-detected), its arg surfacer, and the
	-- localized "Classes: %s" / "Races: %s" formats the tags are recognised by.
	"UnitClass", "UnitRace", "C_TooltipInfo", "TooltipUtil", "ITEM_CLASSES_ALLOWED", "ITEM_RACES_ALLOWED",
	-- Localized button captions used by the StaticPopupDialogs entries (Modules/UI/Requests.lua)
	"YES", "CANCEL",
	-- Frames / UI
	"CreateFrame", "UIParent", "GameTooltip", "GameFontNormal", "GameFontNormalSmall", "GameFontHighlightSmall", "BackdropTemplateMixin",
	-- Modules/UI.lua reads these four; all verified in the Era tree (WorldFrame is the engine's
	-- root frame; UISpecialFrames in UIParentPanelManager.lua; GameTooltip_SetDefaultAnchor in
	-- Blizzard_GameTooltip/Classic/GameTooltip.lua; DressUpItemLink in Classic/DressUpFrames.lua).
	-- UISpecialFrames is APPENDED to (table.insert), which is a read of the global itself.
	"WorldFrame", "UISpecialFrames", "GameTooltip_SetDefaultAnchor", "DressUpItemLink",
	-- NOTE: StaticPopupDialogs is deliberately NOT here -- it is in `globals` above, because
	-- registering a dialog means WRITING a named field into it. Listing it in both made the
	-- read-only entry win, and every one of Requests.lua's four registrations reported W122
	-- "setting read-only field" -- the exact warning the `globals` entry exists to prevent.
	"StaticPopup_Show", "SlashCmdList", "BankFrame",
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
	-- CHATWIN-001: the engine-side constants table. Read for ChatFrameConstants.MaxChatWindows,
	-- because the bare `NUM_CHAT_WINDOWS` global is only assigned inside
	-- Blizzard_DeprecatedChatInfo, behind GetCVarBool("loadDeprecationFallbacks") -- so it is nil
	-- for any player who has that CVar off. `Constants` is what the deprecated global forwards to.
	"Constants",
	-- Mail. The Send-Mail half was missing from this list entirely, so every one of Mail.lua's
	-- attach/send call sites reported as an undefined variable -- 20-odd warnings that were real
	-- signal being drowned out rather than real problems. All verified present in Blizzard's
	-- Classic Era tree before being added here, not assumed from the name.
	"GetInboxNumItems", "GetInboxHeaderInfo", "GetInboxItem", "GetInboxItemLink",
	"ATTACHMENTS_MAX_RECEIVE", "SendMail", "TakeInboxItem",
	-- MAILRETURN-001: Era MailFrame.lua:787/:798 (OpenMail_Delete) -- the Return button's pair.
	"InboxItemCanDelete", "ReturnInboxItem",
	"ATTACHMENTS_MAX_SEND", "GetSendMailItem", "ClickSendMailItemButton", "TakeInboxMoney",
	"CheckInbox", "SendMailNameEditBox", "SendMailSubjectEditBox",
	-- MAILUI-001: C_Mail.IsCommandPending gates the next take (Era's MailFrame.lua:1216 calls it;
	-- MailInfoDocumentation.lua declares it). Feature-detected at the call.
	"C_Mail",
	-- SEARCH-005: the global string SearchBoxTemplate uses as its instruction text
	-- (Blizzard_SharedXML/Shared/InputBox/InputBoxTemplates.xml:31, `value="SEARCH" type="global"`).
	"SEARCH",
	-- Sound, for the donation-collected cue (Modules/Mail.lua)
	"PlaySound", "SOUNDKIT",
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
	-- NUM_CHAT_WINDOWS and Constants are read-only to the addon (above) and WRITABLE here for the
	-- same reason LibStub is: CHATWIN-001 is precisely the case where the client does NOT supply
	-- them, and the only way to drive that branch is to take them away. `debugtab_spec` nils each
	-- and restores it in a `finally`. A spec cannot arrange this by any other means -- the absence
	-- IS the condition under test -- and the branch it reaches used to be a hard error.
	-- The three container-MOVING calls are stood in front of by bankcollect_spec (BANKFILL-001):
	-- the env models container READS only, and the bank-collect state machine is about what the
	-- moves do to the stacks -- pull, split, drop -- so the spec has to implement them over the env's
	-- bag tables to assert the arithmetic. Exact fields, so every other C_Container write is still
	-- reported. BankFrame is the same spec's stand-in for the bank being open; IsBankOpen reads
	-- `BankFrame:IsShown()` and the frame is steered per example.
	globals = { "LibStub", "string.trim", "GetItemInfoInstant", "GameTooltip.HookScript",
		"C_GuildInfo.CanViewOfficerNote", "NUM_CHAT_WINDOWS", "Constants",
		"C_Container.UseContainerItem", "C_Container.SplitContainerItem",
		"C_Container.PickupContainerItem", "BankFrame" },
}

-- The harness is a separate public repo (WoWAPITesting) vendored as a submodule; it carries
-- its own lint config and must not be judged by this addon's rules.
exclude_files = {
	"Tests/wowapi",
	"Libs",
	"Modules/Static",   -- multi-megabyte generated data tables
}
