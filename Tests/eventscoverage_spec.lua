-- COVERAGE-EVENTS-001 (Peer Review 074cdad6): the branches of Modules/Events.lua the rest of the suite
-- never reached -- the share timer, the login roster-refresh state machine, the broadcast collision
-- guard's skip / force / refusal, the guild-ranks cleanup, the mailbox and Send Mail tab hooks, the
-- system-message chat filter, and every one-line event handler. Each example states what the code
-- SHOULD do, driven through the captured AceEvent handler exactly as CallbackHandler fires it (the
-- event name first, then the payload) and against the harness's clock and C_Timer.
--
-- Events.lua is a dispatcher: everything it calls is another module. Those collaborators are small
-- recording stand-ins, put back after every example so no later spec file inherits them.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Events

local ME = "Bankchar-Testrealm"

--- Every global this file replaces, so after_each can hand them back exactly.
local GLOBALS = { "TOGBankClassic_Core", "TOGBankClassic_Guild", "TOGBankClassic_Bank", "TOGBankClassic_Mail",
	"TOGBankClassic_MailInventory", "TOGBankClassic_UI", "TOGBankClassic_UI_Requests", "TOGBankClassic_UI_Browse",
	"TOGBankClassic_UI_Mailbox", "TOGBankClassic_UI_Mail", "TOGBankClassic_UI_Inventory", "TOGBankClassic_Options",
	"TOGBankClassic_Propagation", "TOGBankClassic_Performance", "TOGBankClassic_P2P", "TOGBankClassic_BankerNumbers",
	"TOGBankClassic_DeltaComms", "TOGBankClassic_ItemHighlight", "TOGBankClassic_Donations", "TOGBankClassic_PriceList",
	"MailFrame", "MailFrameTab2", "ChatFrameUtil", "ChatFrame_AddMessageEventFilter", "GuildRoster",
	"GetGameMessageInfo" }

local saved, calls, handlers, shareTimers, cancelled, state, filters, frameHooks, tabHooks

local function note(name, ...)
	calls[#calls + 1] = { name = name, n = select("#", ...), ... }
end

--- A method stand-in that records its call under `name`.
local function rec(name) return function(_, ...) note(name, ...) end end

--- The recorded calls named `name`, in order.
local function called(name)
	local out = {}
	for _, c in ipairs(calls) do if c.name == name then out[#out + 1] = c end end
	return out
end

--- The recorded Output calls of one level whose format string is `fmt` (any call of the level when nil).
local function outputs(level, fmt)
	local out = {}
	for _, c in ipairs(TOGBankClassic_Output.calls) do
		if c.level == level then
			if fmt == nil then
				out[#out + 1] = c
			else
				for i = 1, c.n do
					if c[i] == fmt then out[#out + 1] = c; break end
				end
			end
		end
	end
	return out
end

--- Fire an event the way AceEvent does: Events:RegisterEvent's wrapper receives (eventName, ...).
local function fire(event, ...)
	if not handlers[event] then Events:RegisterEvent(event) end
	return handlers[event](event, ...)
end

--- A frame stand-in whose HookScript records each hook under its script name.
local function hookable(into)
	return { HookScript = function(_, script, fn)
		into[script] = into[script] or {}
		into[script][#into[script] + 1] = fn
	end }
end

local function load()
	env.reset(); env.stubOutput()
	saved = {}
	for _, k in ipairs(GLOBALS) do saved[k] = { v = rawget(_G, k) } end
	env.loadModules({ "Modules/Constants.lua", "Modules/Events.lua" })
	Events = TOGBankClassic_Events

	calls, handlers, shareTimers, cancelled, filters, frameHooks, tabHooks = {}, {}, {}, {}, {}, {}, {}
	state = { isBank = true, guild = "Testguild", init = false, cleaned = 0, online = 3, total = 10,
		banks = { ME }, combatHide = true, broadcastOk = true }
	state.p2p = { BeginConsult = rec("BeginConsult"),
		Broadcast = function(_, prio, extra) note("Broadcast", prio, extra); return state.broadcastOk, 42 end }

	TOGBankClassic_Core = {
		RegisterEvent = function(_, e, fn) handlers[e] = fn end,
		UnregisterEvent = function(_, e) handlers[e] = nil end,
		RegisterMessage = rec("RegisterMessage"),
		UnregisterMessage = rec("UnregisterMessage"),
		SendMessage = rec("SendMessage"),
		ScheduleTimer = function(_, fn, delay)
			local h = { fn = fn, delay = delay }
			shareTimers[#shareTimers + 1] = h
			return h
		end,
		CancelTimer = function(_, h) cancelled[#cancelled + 1] = h end,
	}
	TOGBankClassic_Guild = {
		Info = { name = "Testguild", alts = {} },
		GetPlayer = rec("GetPlayer"),
		GetNormalizedPlayer = function() return ME end,
		IsBank = function(_, n) return state.isBank and n == ME end,
		GetGuild = function() return state.guild end,
		Init = function(_, g) note("Init", g); return state.init end,
		CleanupMalformedAlts = function() note("CleanupMalformedAlts"); return state.cleaned end,
		Share = rec("Share"),
		RequestHashListFromBanker = rec("RequestHashListFromBanker"),
		QueryRequestsIndex = rec("QueryRequestsIndex"),
		PruneIfNeeded = rec("PruneIfNeeded"),
		InvalidateBanksCache = rec("InvalidateBanksCache"),
		RefreshOnlineCache = function() note("RefreshOnlineCache"); return state.online, state.total end,
		RebuildBankerRoster = rec("RebuildBankerRoster"),
		RefreshRequestsUI = rec("RefreshRequestsUI"),
		GetBanks = function() return state.banks end,
		SenderIsOfficer = function() return false end,
		SenderIsGM = function() return false end,
		BroadcastSettings = rec("BroadcastSettings"),
	}
	TOGBankClassic_Bank = { eventsRegistered = false,
		OnUpdateStart = rec("Bank:OnUpdateStart"), OnUpdateStop = rec("Bank:OnUpdateStop") }
	TOGBankClassic_Mail = { isOpen = false, isScanning = true, batchInFlight = true,
		InitSendHook = rec("Mail:InitSendHook"), Check = rec("Mail:Check"), Scan = rec("Mail:Scan"),
		ResetFulfillStep = rec("Mail:ResetFulfillStep"), ClearSendSnapshot = rec("Mail:ClearSendSnapshot"),
		ApplyPendingSend = rec("Mail:ApplyPendingSend"), OnSendInfoUpdate = rec("Mail:OnSendInfoUpdate"),
		DebugSendMailState = rec("Mail:DebugSendMailState") }
	TOGBankClassic_MailInventory = { hasUpdated = false,
		NoteInbox = rec("MailInventory:NoteInbox"), CloseInbox = rec("MailInventory:CloseInbox") }
	TOGBankClassic_UI = { OnInsertLink = rec("UI:OnInsertLink") }
	TOGBankClassic_UI_Requests = { isOpen = false, embedded = false,
		_RefreshFulfillButtons = rec("Requests:_RefreshFulfillButtons"), SetStatusText = rec("Requests:SetStatusText"),
		DrawContent = rec("Requests:DrawContent"), Open = rec("Requests:Open") }
	TOGBankClassic_UI_Browse = nil
	TOGBankClassic_UI_Mailbox = { OnMailShow = rec("Mailbox:OnMailShow"), OnInboxUpdate = rec("Mailbox:OnInboxUpdate"),
		OnMailClosed = rec("Mailbox:OnMailClosed") }
	TOGBankClassic_UI_Mail = { Close = rec("UI_Mail:Close") }
	TOGBankClassic_UI_Inventory = { Close = rec("Inventory:Close") }
	TOGBankClassic_Options = { InitGuild = rec("Options:InitGuild"),
		GetCombatHide = function() return state.combatHide end, NoteAccountCharacter = rec("Options:NoteAccountCharacter") }
	TOGBankClassic_Propagation = { OnCamping = rec("Propagation:OnCamping"), Restore = rec("Propagation:Restore") }
	TOGBankClassic_Performance = { RecordEvent = rec("Performance:RecordEvent") }
	TOGBankClassic_P2P = { Lib = function() return state.p2p end, BroadcastExtra = function() return "extra" end }
	TOGBankClassic_BankerNumbers = { Version = function() return 7 end }
	TOGBankClassic_DeltaComms = { ClearOfflineErrorCounters = rec("DeltaComms:ClearOfflineErrorCounters") }
	TOGBankClassic_ItemHighlight = { ApplySavedPreference = rec("ItemHighlight:ApplySavedPreference") }
	TOGBankClassic_Donations, TOGBankClassic_PriceList = nil, nil
	_G.GuildRoster = function() note("GuildRoster") end
	_G.MailFrame = hookable(frameHooks)
	_G.MailFrameTab2 = hookable(tabHooks)
	_G.ChatFrame_AddMessageEventFilter = nil
	_G.ChatFrameUtil = {
		InsertLink = function() end,
		AddMessageEventFilter = function(event, fn) filters[event] = fn end,
	}
end

local function restore()
	for k, s in pairs(saved) do _G[k] = s.v end
	env.setInRaid(false)
end

describe("COVERAGE-EVENTS-001: the message wrappers", function()
	before_each(load)
	after_each(restore)

	it("RegisterMessage with no callback registers the message name as its own callback; Unregister forwards", function()
		Events:RegisterMessage("TOGBANK_PROBE")
		Events:RegisterMessage("TOGBANK_OTHER", "OnOther")
		Events:UnregisterMessage("TOGBANK_PROBE")
		local reg = called("RegisterMessage")
		assert.equal(2, #reg)
		assert.same({ "TOGBANK_PROBE", "TOGBANK_PROBE" }, { reg[1][1], reg[1][2] })
		assert.same({ "TOGBANK_OTHER", "OnOther" }, { reg[2][1], reg[2][2] })
		local unreg = called("UnregisterMessage")
		assert.equal(1, #unreg)
		assert.equal("TOGBANK_PROBE", unreg[1][1])
	end)
end)

describe("COVERAGE-EVENTS-001: RegisterEvents and UnregisterEvents", function()
	before_each(load)
	after_each(restore)

	it("registers nothing and schedules no timer when the events are already registered", function()
		TOGBankClassic_Bank.eventsRegistered = true
		Events:RegisterEvents()
		assert.is_nil(next(handlers), "an event was registered a second time")
		assert.equal(0, #shareTimers, "a second share timer was scheduled")
		assert.is_nil(frameHooks.OnShow, "the mailbox was hooked again")
	end)

	it("UnregisterEvents with nothing registered changes nothing", function()
		handlers.PROBE = function() end
		Events:UnregisterEvents()
		assert.is_function(handlers.PROBE, "an unregister ran for events that were never registered")
		assert.is_false(TOGBankClassic_Bank.eventsRegistered)
	end)

	it("the system-message filter hides only the two offline-whisper errors", function()
		Events:RegisterEvents()
		local filter = filters.CHAT_MSG_SYSTEM
		assert.is_function(filter, "no system-message filter was installed")
		assert.is_true(filter(nil, nil, "No player named Bob is currently playing."))
		assert.is_true(filter(nil, nil, "Player not found: Bob"))
		assert.is_false(filter(nil, nil, "No player named Bob was seen today."),
			"a message that only starts like the offline error was hidden")
		assert.is_false(filter(nil, nil, "Bob has come online."))
		assert.is_false(filter(nil, nil, nil))
	end)

	it("hooks the mailbox once: showing and hiding it mark the mail open/closed and refresh an open Requests body", function()
		Events:RegisterEvents()
		assert.equal(1, #frameHooks.OnShow); assert.equal(1, #frameHooks.OnHide)
		TOGBankClassic_UI_Requests.isOpen = true
		frameHooks.OnShow[1]()
		assert.is_true(TOGBankClassic_Mail.isOpen)
		assert.equal(0, #called("Requests:_RefreshFulfillButtons"), "refreshed before the deferral")
		env.advance(0.2)
		local r = called("Requests:_RefreshFulfillButtons")
		assert.equal(1, #r)
		assert.same({ ME, true, true }, { r[1][1], r[1][2], r[1][3] })
		frameHooks.OnHide[1]()
		assert.is_false(TOGBankClassic_Mail.isOpen)
		env.advance(0.2)
		r = called("Requests:_RefreshFulfillButtons")
		assert.equal(2, #r)
		assert.same({ ME, true, false }, { r[2][1], r[2][2], r[2][3] })
		-- A second registration after a disable does not hook the frames again.
		Events:UnregisterEvents()
		Events:RegisterEvents()
		assert.equal(1, #frameHooks.OnShow, "the mailbox OnShow was hooked twice")
		assert.equal(1, #frameHooks.OnHide, "the mailbox OnHide was hooked twice")
		assert.equal(1, #tabHooks.OnClick, "the Send Mail tab was hooked twice")
	end)

	it("the mailbox hooks refresh nothing while the Requests body is closed, and pass a non-banker as such", function()
		Events:RegisterEvents()
		frameHooks.OnShow[1]()
		frameHooks.OnHide[1]()
		env.advance(0.2)
		assert.equal(0, #called("Requests:_RefreshFulfillButtons"), "a closed Requests body was refreshed")
		state.isBank = false
		TOGBankClassic_UI_Requests.isOpen = true
		frameHooks.OnShow[1]()
		env.advance(0.2)
		local r = called("Requests:_RefreshFulfillButtons")
		assert.equal(1, #r)
		assert.is_false(r[1][2], "a non-banker was refreshed as a banker")
	end)

	it("without the Guild Bank window, the Send Mail tab redraws an open Requests window or opens it", function()
		Events:RegisterEvents()
		TOGBankClassic_UI_Requests.isOpen = true
		tabHooks.OnClick[1]()
		env.advance(0.2)
		assert.equal(1, #called("Requests:DrawContent"))
		assert.equal(0, #called("Requests:Open"))
		TOGBankClassic_UI_Requests.isOpen = false
		tabHooks.OnClick[1]()
		env.advance(0.2)
		assert.equal(1, #called("Requests:DrawContent"))
		assert.equal(1, #called("Requests:Open"), "a closed Requests window was not opened at the Send Mail tab")
	end)
end)

describe("COVERAGE-EVENTS-001: the periodic share timer", function()
	local INTERVAL
	before_each(function()
		load()
		INTERVAL = TOGBankClassic_Constants.TIMER_INTERVALS.VERSION_BROADCAST
	end)
	after_each(restore)

	it("schedules one timer at the broadcast interval, cancelling the one it replaces, and firing it runs the share", function()
		Events:SetShareTimer()
		Events:SetShareTimer()
		assert.equal(2, #shareTimers)
		assert.equal(INTERVAL, shareTimers[2].delay)
		assert.same({ shareTimers[1] }, cancelled, "the replaced timer was not cancelled")
		shareTimers[2].fn()
		assert.equal(1, #called("Share"), "the timer did not run the share")
	end)

	it("defers the whole share, and re-arms, while the zone-in cooldown is on", function()
		Events.zoningCooldown = true
		Events:OnShareTimer()
		assert.equal(0, #called("Share"))
		assert.equal(0, #called("QueryRequestsIndex"))
		assert.equal(1, #shareTimers, "the deferred share was not re-armed")
		assert.equal(1, #outputs("Debug", "OnShareTimer deferred (zone-in cooldown active)"))
	end)

	it("shares the version, asks a banker for hashes when it holds none, syncs and prunes requests, and re-arms", function()
		TOGBankClassic_Guild.Info.alts = { [ME] = { inventoryHash = 0 } }
		Events:OnShareTimer()
		local share = called("Share")
		assert.equal(1, #share)
		assert.same({ "reply", "version" }, { share[1][1], share[1][2] })
		assert.equal(1, #called("RequestHashListFromBanker"), "a client with no hashes did not ask a banker to seed it")
		local q = called("QueryRequestsIndex")
		assert.equal(1, #q)
		assert.is_nil(q[1][1]); assert.equal("NORMAL", q[1][2])
		assert.equal(1, #called("PruneIfNeeded"))
		assert.equal(1, #shareTimers, "the share timer was not re-armed")
		assert.equal(GetTime(), Events.lastShareTimerAt)
		assert.equal(1, #outputs("Debug", "OnShareTimer took %.2fms"))
		assert.equal(0, #outputs("Debug", "OnShareTimer fired early (%.1fs since last)"), "the first share was called early")
	end)

	it("asks no banker once any alt carries a hash, and notes a share that fires early", function()
		TOGBankClassic_Guild.Info.alts = { a = { inventoryHash = 0, mailHash = 0 }, b = { mailHash = 99 } }
		Events:OnShareTimer()
		assert.equal(0, #called("RequestHashListFromBanker"), "a client holding hashes still asked a banker")
		env.advance(5)
		Events:OnShareTimer()
		assert.equal(1, #outputs("Debug", "OnShareTimer fired early (%.1fs since last)"), "a share 5 s after the last was not noted as early")
		Events.lastShareTimerAt = GetTime() - INTERVAL
		Events:OnShareTimer()
		assert.equal(1, #outputs("Debug", "OnShareTimer fired early (%.1fs since last)"), "an on-time share was noted as early")
	end)

	it("with no guild loaded, treats the client as holding no hashes", function()
		TOGBankClassic_Guild.Info = nil
		Events:OnShareTimer()
		assert.equal(1, #called("RequestHashListFromBanker"))
	end)
end)

describe("COVERAGE-EVENTS-001: SyncDeltaVersion's guards", function()
	before_each(load)
	after_each(restore)

	it("broadcasts nothing when the host has no numbered P2P", function()
		state.p2p = nil
		Events:SyncDeltaVersion("NORMAL")
		assert.equal(0, #called("BeginConsult"))
		assert.equal(1, #outputs("Debug", "SyncDeltaVersion: no numbered P2P on the host -- nothing broadcast"))
	end)

	it("skips a periodic (BULK) broadcast while one is in flight, counting the block", function()
		Events.hashBroadcastInProgress = true
		Events:SyncDeltaVersion("BULK")
		assert.equal(0, #called("Broadcast"), "a BULK broadcast collided with the one in flight")
		assert.equal(1, Events.hashBroadcastBlocked)
		assert.equal(1, #outputs("Debug", "Skipped BULK hash-list broadcast (previous broadcast in progress)"))
	end)

	it("forces a login broadcast through after three deferrals rather than blocking it forever", function()
		Events.hashBroadcastInProgress = true
		Events:SyncDeltaVersion("NORMAL", 3)
		local b = called("Broadcast")
		assert.equal(1, #b, "the fourth attempt was not forced through")
		assert.equal("NORMAL", b[1][1])
		assert.equal(1, #outputs("Debug", "Forcing %s hash-list broadcast after %d retries"))
		assert.is_true(Events.hashBroadcastInProgress)
		assert.equal(1, #called("BroadcastSettings"), "a banker's broadcast did not carry the settings")
	end)

	it("releases the guard, and sends nothing after, when the library refuses the broadcast", function()
		state.broadcastOk = false
		Events:SyncDeltaVersion("NORMAL")
		assert.equal(1, #called("Broadcast"))
		assert.is_false(Events.hashBroadcastInProgress, "a refused broadcast held the guard")
		assert.equal(0, #called("BroadcastSettings"))
		assert.equal(1, #outputs("Debug", "SyncDeltaVersion: the host refused the broadcast"))
	end)
end)

describe("COVERAGE-EVENTS-001: entering the world and the login roster refresh", function()
	before_each(load)
	after_each(restore)

	it("a zone change sets the cooldown, which lifts after 2.5 s, and asks for no roster", function()
		fire("PLAYER_ENTERING_WORLD", false, false)
		assert.equal(1, #called("Performance:RecordEvent"))
		assert.is_true(Events.zoningCooldown)
		assert.equal(0, #called("GuildRoster"), "a zone change re-requested the roster")
		assert.is_nil(Events.needsFullRosterRefresh)
		assert.equal(1, #outputs("Debug", "[INIT] PLAYER_ENTERING_WORLD (zone change) - Skipping roster refresh"))
		env.advance(2.4)
		assert.is_true(Events.zoningCooldown)
		env.advance(0.2)
		assert.is_false(Events.zoningCooldown, "the zone-in cooldown never lifted")
	end)

	it("a login asks for the roster, rebuilds it on the update, and holds the login broadcasts until the cooldown lifts", function()
		local syncs = {}
		Events.SyncDeltaVersion = function(_, prio) syncs[#syncs + 1] = prio end
		fire("PLAYER_ENTERING_WORLD", true, false)
		assert.equal(1, #called("GuildRoster"))
		assert.is_true(Events.needsFullRosterRefresh)
		fire("GUILD_ROSTER_UPDATE")
		assert.is_true(Events.refreshInProgress)
		assert.equal(0, #called("RefreshOnlineCache"), "the rebuild was not deferred")
		env.advance(0.6)
		for _, name in ipairs({ "InvalidateBanksCache", "RefreshOnlineCache", "RebuildBankerRoster", "Options:InitGuild",
			"ItemHighlight:ApplySavedPreference", "RefreshRequestsUI", "Propagation:Restore" }) do
			assert.equal(1, #called(name), name .. " did not run once in the rebuild")
		end
		assert.equal("Testguild", called("DeltaComms:ClearOfflineErrorCounters")[1][1])
		assert.is_false(Events.refreshInProgress)
		assert.is_false(Events.needsFullRosterRefresh, "a complete roster asked for another refresh")
		assert.equal(1, #outputs("Debug", "Login broadcasts deferred (zone-in cooldown active)"))
		assert.equal(0, #syncs, "the login broadcast went out inside the cooldown")
		env.advance(2.0)
		assert.is_false(Events.zoningCooldown)
		assert.equal(0, #syncs)
		env.advance(1.0)
		assert.same({ "NORMAL" }, syncs, "the deferred login broadcast never went out")
		local q = called("QueryRequestsIndex")
		assert.equal(1, #q)
		assert.equal("NORMAL", q[1][2])
	end)

	it("drops the deferred login broadcast when another zone-in cooldown is on by then", function()
		local syncs = 0
		Events.SyncDeltaVersion = function() syncs = syncs + 1 end
		fire("PLAYER_ENTERING_WORLD", false, true)
		fire("GUILD_ROSTER_UPDATE")
		env.advance(0.6)
		assert.equal(1, #outputs("Debug", "Login broadcasts deferred (zone-in cooldown active)"))
		env.advance(2.4)
		fire("PLAYER_ENTERING_WORLD", false, false)   -- a zone change just before the deferral fires
		env.advance(0.4)
		assert.is_true(Events.zoningCooldown)
		assert.equal(0, syncs, "a login broadcast went out inside a second cooldown")
		assert.equal(0, #called("QueryRequestsIndex"))
	end)

	it("broadcasts at once when the roster completes outside the cooldown", function()
		local syncs = 0
		Events.SyncDeltaVersion = function() syncs = syncs + 1 end
		fire("PLAYER_ENTERING_WORLD", true, false)
		env.advance(3)
		fire("GUILD_ROSTER_UPDATE")
		env.advance(0.6)
		assert.equal(1, syncs)
		assert.equal(1, #called("QueryRequestsIndex"))
		assert.equal(1, #outputs("Debug", "[INIT] Roster initialization complete after %d attempts"))
	end)

	it("retries an empty or all-offline roster up to five times, then completes anyway", function()
		local syncs = 0
		Events.SyncDeltaVersion = function() syncs = syncs + 1 end
		fire("PLAYER_ENTERING_WORLD", true, false)
		env.advance(3)
		state.total = 0
		fire("GUILD_ROSTER_UPDATE"); env.advance(0.6)
		assert.is_true(Events.needsFullRosterRefresh, "an empty roster was not retried")
		assert.equal(1, #outputs("Debug", "[INIT] Retry needed: GetNumGuildMembers returned %d"))
		state.total, state.online = 10, 0
		for attempt = 2, 4 do
			fire("GUILD_ROSTER_UPDATE"); env.advance(0.6)
			assert.is_true(Events.needsFullRosterRefresh, "attempt " .. attempt .. " with nobody online was not retried")
		end
		assert.equal(3, #outputs("Debug", "[INIT] Retry needed: 0 online members (guild not empty)"))
		assert.equal(4, #outputs("Debug", "[INIT] Will retry on next GUILD_ROSTER_UPDATE"))
		assert.equal(0, syncs)
		fire("GUILD_ROSTER_UPDATE"); env.advance(0.6)
		assert.is_false(Events.needsFullRosterRefresh, "the fifth attempt still asked for another")
		assert.equal(5, Events.fullRosterInitAttempts)
		assert.equal(1, syncs, "the login broadcast never went out after the retries ran out")
	end)

	it("skips an update while a rebuild is pending, and ignores one when no refresh is wanted", function()
		fire("PLAYER_ENTERING_WORLD", true, false)
		fire("GUILD_ROSTER_UPDATE")
		Events.needsFullRosterRefresh = true          -- a retry was asked for while this one is pending
		fire("GUILD_ROSTER_UPDATE")
		assert.equal(1, #outputs("Debug", "[INIT] GUILD_ROSTER_UPDATE skipped (refresh already in progress)"))
		Events.SyncDeltaVersion = function() end
		env.advance(0.6)
		assert.equal(1, #called("RefreshOnlineCache"), "an overlapping update started a second rebuild")
		Events.needsFullRosterRefresh = false
		fire("GUILD_ROSTER_UPDATE")
		assert.equal(1, #outputs("Debug", "GUILD_ROSTER_UPDATE ignored (online/offline handled via system messages)"))
		env.advance(0.6)
		assert.equal(1, #called("RefreshOnlineCache"))
	end)

	it("completes the rebuild without the highlight or propagation modules", function()
		TOGBankClassic_ItemHighlight, TOGBankClassic_Propagation = nil, nil
		Events.SyncDeltaVersion = function() end
		fire("PLAYER_ENTERING_WORLD", true, false)
		fire("GUILD_ROSTER_UPDATE")
		env.advance(0.6)
		assert.equal(1, #called("RefreshRequestsUI"))
		assert.is_false(Events.refreshInProgress)
	end)
end)

describe("COVERAGE-EVENTS-001: GUILD_RANKS_UPDATE", function()
	before_each(load)
	after_each(restore)

	it("does nothing outside a guild", function()
		state.guild = nil
		fire("GUILD_RANKS_UPDATE")
		assert.equal(0, #called("Options:InitGuild"))
		assert.equal(0, #called("Init"))
	end)

	it("initialises the options every time, and cleans nothing when the guild was already loaded", function()
		fire("GUILD_RANKS_UPDATE")
		assert.equal(1, #called("Options:InitGuild"))
		assert.equal("Testguild", called("Init")[1][1])
		assert.equal(0, #called("CleanupMalformedAlts"))
	end)

	it("skips the cleanup inside a raid", function()
		state.init = true
		env.setInRaid(true)
		fire("GUILD_RANKS_UPDATE")
		assert.equal(0, #called("CleanupMalformedAlts"), "the cleanup ran inside a raid")
		assert.equal(1, #outputs("Debug", "GUILD_RANKS_UPDATE: ignoring guild ranks cleanup (in raid)"))
	end)

	it("reports how many malformed alts it cleaned, and says nothing when there were none", function()
		state.init, state.cleaned = true, 3
		fire("GUILD_RANKS_UPDATE")
		local info = outputs("Info", "Cleaned %d malformed alt entries from saved database")
		assert.equal(1, #info)
		assert.equal(3, info[1][2])
		state.cleaned = 0
		fire("GUILD_RANKS_UPDATE")
		assert.equal(2, #called("CleanupMalformedAlts"))
		assert.equal(1, #outputs("Info", "Cleaned %d malformed alt entries from saved database"))
	end)
end)

describe("COVERAGE-EVENTS-001: the mailbox events", function()
	before_each(load)
	after_each(restore)

	it("MAIL_SHOW opens the mail session, and hooks the mailbox's hide once to close it", function()
		fire("MAIL_SHOW")
		assert.equal(1, #called("Bank:OnUpdateStart"))
		assert.is_true(TOGBankClassic_MailInventory.hasUpdated)
		assert.is_true(TOGBankClassic_Mail.isOpen)
		for _, name in ipairs({ "Mail:InitSendHook", "Mail:Check", "Mailbox:OnMailShow" }) do
			assert.equal(1, #called(name), name)
		end
		fire("MAIL_SHOW")
		assert.equal(1, #frameHooks.OnHide, "the mailbox hide was hooked twice")
		frameHooks.OnHide[1]()
		assert.is_false(TOGBankClassic_Mail.isOpen, "hiding the mailbox did not close the mail session")
		assert.equal(1, #called("MailInventory:CloseInbox"))
		assert.equal(1, #called("UI_Mail:Close"))
	end)

	it("MAIL_SHOW works without the mailbox window module", function()
		TOGBankClassic_UI_Mailbox = nil
		fire("MAIL_SHOW")
		assert.equal(1, #called("Mail:Check"))
	end)

	it("MAIL_INBOX_UPDATE notes the inbox, scans it and rebuilds the mailbox rows", function()
		fire("MAIL_INBOX_UPDATE")
		assert.equal(1, #called("MailInventory:NoteInbox"))
		assert.equal(1, #called("Mail:Scan"))
		assert.equal(1, #called("Mailbox:OnInboxUpdate"))
		TOGBankClassic_MailInventory, TOGBankClassic_UI_Mailbox = nil, nil
		fire("MAIL_INBOX_UPDATE")
		assert.equal(2, #called("Mail:Scan"), "the scan needs neither optional module")
	end)

	it("MAIL_CLOSED ends the session and refreshes an open Requests body's fulfil buttons", function()
		TOGBankClassic_Mail.isOpen = true
		TOGBankClassic_UI_Requests.isOpen = true
		fire("MAIL_CLOSED")
		assert.is_false(TOGBankClassic_Mail.isOpen)
		assert.is_false(TOGBankClassic_Mail.isScanning)
		for _, name in ipairs({ "Mail:ResetFulfillStep", "Mail:ClearSendSnapshot", "MailInventory:CloseInbox",
			"Bank:OnUpdateStop", "UI_Mail:Close", "Mailbox:OnMailClosed" }) do
			assert.equal(1, #called(name), name)
		end
		env.advance(0.2)
		local r = called("Requests:_RefreshFulfillButtons")
		assert.equal(1, #r)
		assert.same({ ME, true, false }, { r[1][1], r[1][2], r[1][3] })
	end)

	it("MAIL_SEND_SUCCESS makes sure the send hook is in, then credits the pending send", function()
		fire("MAIL_SEND_SUCCESS")
		assert.equal(1, #called("Mail:InitSendHook"))
		assert.equal(1, #called("Mail:ApplyPendingSend"))
	end)

	-- UI_ERROR_MESSAGE's payload is (errorType, message) on every flavour this addon ships
	-- (Blizzard_APIDocumentationGenerated/SystemDocumentation.lua, UiErrorMessage). The handler took
	-- `(_, message)`, so `message` was the numeric errorType and no mail error was ever recognised.
	it("a mail send error frees the next batch, dumps the send state and tells an open Requests window", function()
		GetGameMessageInfo = nil  -- the English-text fallback; the error-id path is the last example
		TOGBankClassic_UI_Requests.isOpen = true
		fire("UI_ERROR_MESSAGE", 51, "Internal mail database error")
		assert.is_false(TOGBankClassic_Mail.batchInFlight, "a failed send left the next batch blocked")
		local dump = called("Mail:DebugSendMailState")
		assert.equal(1, #dump)
		assert.equal("Internal mail database error", dump[1][1])
		local st = called("Requests:SetStatusText")
		assert.equal(1, #st)
		assert.equal("Mail error: Internal mail database error", st[1][1])
	end)

	it("ignores an error that is not about mail, and one with no message", function()
		GetGameMessageInfo = nil
		fire("UI_ERROR_MESSAGE", 3, "You are too far away.")
		fire("UI_ERROR_MESSAGE", 3, nil)
		assert.is_true(TOGBankClassic_Mail.batchInFlight)
		assert.equal(0, #called("Mail:DebugSendMailState"))
		-- A mail error with the Requests window closed sets no status line.
		fire("UI_ERROR_MESSAGE", 51, "Mail target not found")
		assert.is_false(TOGBankClassic_Mail.batchInFlight)
		assert.equal(0, #called("Requests:SetStatusText"))
	end)

	-- EVENTS-UIERR-002 (Peer Review 511e37b8 L1, 6639c74e R1): the message is localized, so the error
	-- id from GetGameMessageInfo decides, not the text. The texts below are chosen so the English word
	-- would get both answers wrong.
	it("decides by the error id GetGameMessageInfo names, whatever the text says", function()
		local names = { [3] = "ERR_OUT_OF_RANGE", [51] = "ERR_MAIL_DATABASE_ERROR" }
		GetGameMessageInfo = function(index) return names[index] end
		fire("UI_ERROR_MESSAGE", 3, "Your mail is too far away.")
		assert.is_true(TOGBankClassic_Mail.batchInFlight, "a non-mail error id freed the batch because its text said mail")
		fire("UI_ERROR_MESSAGE", 51, "Interner Postdatenbankfehler")
		assert.is_false(TOGBankClassic_Mail.batchInFlight, "a German mail error left the next batch blocked")
		assert.equal(1, #called("Mail:DebugSendMailState"))
	end)

	-- EVENTS-UIERR-004 (Peer Review 030b8a0a): an inbox action's mail error is not a send failure, so it
	-- must not free the next Fulfill click while a send is still pending. It is still a mail error the
	-- player should see (Peer Review ca15a538 U1), so the dump and the status line still happen.
	it("an inbox-only mail error leaves a pending batch send blocked but is still reported", function()
		local names = { [60] = "ERR_MAIL_ATTACHMENT_EXPIRED", [61] = "ERR_MAIL_DELETE_ITEM_ERROR" }
		GetGameMessageInfo = function(index) return names[index] end
		TOGBankClassic_UI_Requests.isOpen = true
		fire("UI_ERROR_MESSAGE", 60, "That item has expired.")
		fire("UI_ERROR_MESSAGE", 61, "You can't delete that.")
		assert.is_true(TOGBankClassic_Mail.batchInFlight, "an inbox error freed the next batch while a send was pending")
		assert.equal(2, #called("Mail:DebugSendMailState"))
		local st = called("Requests:SetStatusText")
		assert.equal(2, #st)
		assert.equal("Mail error: That item has expired.", st[1][1])
		assert.equal("Mail error: You can't delete that.", st[2][1])
	end)

	it("falls back to the English text for an index GetGameMessageInfo does not know", function()
		GetGameMessageInfo = function() end
		fire("UI_ERROR_MESSAGE", 999, "Mail target not found")
		assert.is_false(TOGBankClassic_Mail.batchInFlight)
	end)
end)

describe("COVERAGE-EVENTS-001: the one-line handlers", function()
	before_each(load)
	after_each(restore)

	it("the bank, trade, auction house and merchant windows start and stop the bag watcher", function()
		fire("BANKFRAME_OPENED")
		assert.is_true(TOGBankClassic_Bank.atBank)
		fire("TRADE_SHOW"); fire("AUCTION_HOUSE_SHOW"); fire("MERCHANT_SHOW")
		assert.equal(4, #called("Bank:OnUpdateStart"))
		fire("TRADE_CLOSED"); fire("AUCTION_HOUSE_CLOSED"); fire("MERCHANT_CLOSED")
		assert.equal(3, #called("Bank:OnUpdateStop"))
	end)

	it("logging out saves the debug log; camping tells propagation, and survives without it", function()
		fire("PLAYER_LOGOUT")
		assert.equal(1, #outputs("SavePersistentLog"))
		fire("PLAYER_CAMPING")
		assert.equal(1, #called("Propagation:OnCamping"))
		TOGBankClassic_Propagation = nil
		local ok, err = pcall(fire, "PLAYER_CAMPING")
		assert.is_true(ok, tostring(err))
	end)

	it("entering combat closes the inventory window only when the option says to", function()
		fire("PLAYER_REGEN_DISABLED")
		assert.equal(1, #called("Inventory:Close"))
		state.combatHide = false
		fire("PLAYER_REGEN_DISABLED")
		assert.equal(1, #called("Inventory:Close"), "the window closed in combat with the option off")
	end)
end)
