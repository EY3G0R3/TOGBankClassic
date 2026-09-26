-- env_fleet -- SEVERAL WHOLE CLIENTS IN ONE LUA STATE, talking to each other over a wire.
--
-- WHY THIS EXISTS. Every other spec in this suite drives ONE client and hands it the bytes a second
-- client would have sent -- captured from a first stand-up, or built by hand. That proves each leg;
-- it cannot prove the SYNC, because a sync is a conversation: a broadcast that draws offers, offers
-- that open a version query, a query that picks holders, a handshake, a data leg, a completion that
-- frees a slot another requester was queued behind, a catch-up cycle when the first round learnt
-- nothing. The operator, 2026-09-11: "you need COMPREHENSIVE end to end testing in the test harness.
-- FULL SYNC, not just pieces." This fixture is what makes that a thing a spec can say.
--
-- THE CLIENTS ARE THE HARNESS'S (WHOLE-ADDON-CLIENT-PROOF, harness contract aa1853c95b31, parts 1
-- and 2 at 5df0015 / f8495a3). Until 2026-09-16 this file built each client by hand -- a global
-- environment per client under `setfenv`, its own LibStub and ChatThrottleLib, a C_Timer wrapper so
-- callbacks re-entered the right player, bags and guild rosters swapped in and out by contents, and a
-- bus of its own. The operator: "why are you doing this instead of building it into the harness with
-- a contract?" (CONGESTION-HARNESS-001). WoWAPITesting built it; `Tests/wholeaddon_spec.lua` proved
-- TOGBank's real module set runs in two of its clients; this file is now the TOGBank glue over
-- `wow.client()` and nothing else. What the harness gives each client:
--   * `client.env`, the addon's own globals (`client:loadFile`), falling through to the shared `_G`;
--   * its own LibStub registry, ChatThrottleLib and C_ChatInfo (swapped by `wow.runAs`);
--   * its own `money`, `bags` and `addonMetadata` (a mixed-version guild, WIRE-SKEW-003);
--   * its own guild MEMBERSHIP, with the roster shared per guild name (`env.guild.setMembersFor`);
--   * presence: `goOffline` / `goOnline` send the system line to the rest of its guild;
--   * a frame or timer records the client that made it, and every dispatch runs as that client.
-- WHAT IS SHARED, deliberately, because it is the same world: the clock and timer list, the frames
-- registry, the item cache.
--
-- THE SEAM, DECLARED -- and there are TWO WIRES, chosen per fleet (`F.new(members, { wire = ... })`):
--
--   "ordered" (the default, and every fleet spec before CONGESTION-001): TOGBank's own bus. It
--   captures `Core:SendCommMessage` -- the wrapper every send in the addon and every host send goes
--   through -- and delivers the WHOLE message to each recipient's receive handler (`Chat:OnCommReceived`
--   for TOGBank's prefixes, the DeltaSync host's `OnAddonMessage` for its own), in send order, after
--   each one-second step. AceComm's chunking, ChatThrottleLib's pacing and AceCommQueue's
--   serialisation are NOT modelled; `syncwire_spec` / `deltahost_spec` own the envelope. This half is
--   TOGBank's and stays here: the harness's wire is always the real stack.
--
--   "throttled" (CONGESTION-001): THE HARNESS'S WIRE. Sends go through each client's real
--   AceCommQueue-1.0, AceComm-3.0 and ChatThrottleLib into its own C_ChatInfo, every chunk is recorded
--   in `wow.wire` as it leaves (`wow.wireTrace`, `wow.formatWire`), and the recipient's real AceComm
--   reassembles it through CHAT_MSG_ADDON. So a message on one prefix can leave AFTER a message sent
--   later on another, a four-chunk table arrives after a one-chunk offer sent the same instant, a BULK
--   snapshot drains over seconds while the ALERT handshake beside it does not wait. Not modelled: server
--   latency (a chunk arrives as it leaves) and the client's own throttle refusals.
--
-- In both wires the sender name is delivered as AceComm spells it for a same-realm peer -- the BARE
-- name -- because that is what found the slot leak in step 3b. A GUILD send reaches every online
-- client of the sender's guild including the sender (the client echoes its own guild addon messages).
--
-- `F.tick(seconds)` advances the clock in one-second steps, firing timers (and, on the throttled wire,
-- every client's ChatThrottleLib OnUpdate) and draining the ordered bus after each, so a spec says
-- "sixty seconds pass" and the collect window closes, the dispatch goes out, the accept comes back,
-- the data lands.
---@diagnostic disable: undefined-global, lowercase-global
-- luacheck: std lua51

package.path = "./Tests/?.lua;" .. package.path
local env   = require("env_togbank")
local wow   = require("env.wow")
local ace   = require("env.ace")
local libs  = require("env.libs")
local guild = env.guild

local F = {}
F.env     = env
F.clients = {}     -- array, in creation order
F.byName  = {}     -- bare name -> the FIRST client playing it
F.queue   = {}     -- ordered wire: messages not yet delivered
F.log     = {}     -- every message ever sent: { from=, prefix=, dist=, target=, bytes=, type=, prio=, body= }
                   -- throttled wire only: sentAt= (when the addon handed it to AceCommQueue),
                   -- leftAt= (when its LAST chunk left ChatThrottleLib), verdict=
F.wire    = "ordered"
F.active  = nil    -- ordered wire: the client a delivery is running as (nil between deliveries)

local GUILD = "Testguild"
F.GUILD = GUILD

-- WIRE-SKEW-003: the version a fleet client runs unless a spec says otherwise. READ from the
-- addon's OWN constant rather than written here, so the fleet cannot drift from the release the
-- data-leg gate is defined against (PROTOCOL.DATA_LEG_MIN_ADDON_VERSION). It used to be the
-- literal "1.5.0" under a comment claiming exactly this -- and the day the floor moved to 1.6.0
-- (LIBREQ-DS-008) every fleet client became an old-release peer and refused every other.
if not _G.TOGBankClassic_Constants then env.loadFile("Modules/Constants.lua") end
local CURRENT_VERSION = _G.TOGBankClassic_Constants.PROTOCOL.DATA_LEG_MIN_ADDON_VERSION
F.CURRENT_VERSION = CURRENT_VERSION
F.OLD_VERSION     = "TOGBankClassic-v1.4.1"   -- a RELEASED peer from before the data leg changed

-- ---------------------------------------------------------------------------
-- Running as a client
-- ---------------------------------------------------------------------------

--- Run `fn` as `c` -- its name, bags, money, guild and libraries are what the WoW API answers
--- meanwhile (`wow.runAs`). Returns whatever `fn` returns, so a spec can READ a client
--- (`F.with(c, function() return ... end)`). Re-entrant.
function F.with(c, fn, ...)
	return c:run(fn, ...)
end

--- The roster of guild `name` as the harness holds it (the host's guild reads `guild.members`).
local function rosterOf(name)
	if name == guild.guildName then return guild.members end
	return guild.rosters[name] or {}
end

-- ---------------------------------------------------------------------------
-- Loading a client
-- ---------------------------------------------------------------------------

-- Ace3 in dependency order (env.ace's verified edges), then the sibling libraries the TOCs declare.
--
-- DO NOT REORDER: `ChatThrottleLib` MUST STAY BEFORE `AceComm-3.0`, and on the throttled wire that is
-- load-bearing rather than tidy. `AceComm-3.0.lua:21` is `local CTL = assert(ChatThrottleLib, ...)` --
-- a FILE-SCOPE local captured when that copy of the file runs. So a client's AceComm is WELDED to
-- whichever ChatThrottleLib was its global when it loaded. Reorder these two and that client's sends
-- despool through another client's gauge -- or through none -- while its spool, its queues and its
-- gauge all still read as correctly separate. Measured by WoWAPITesting (thread 12c111893504, reply 6).
local ACE_ORDER = { "CallbackHandler-1.0", "AceAddon-3.0", "AceEvent-3.0", "AceTimer-3.0",
	"AceSerializer-3.0", "AceConsole-3.0", "ChatThrottleLib", "AceComm-3.0" }
-- LibItemDB is a declared dependency (Resolve raises an Error line without it), and VersionCheck is
-- its own.
local LIB_ORDER = { "AceCommQueue-1.0", "LibGuildRoster-1.0", "DeltaSync-1.0", "VersionCheck-1.0", "LibItemDB-1.0" }

--- Stand up a whole client called `name` (bare character name). `opts.money` is its purse,
--- `opts.guild` its guild (default F.GUILD), `opts.addonVersion` the TOGBank release it runs (false:
--- whatever the host's metadata says), `opts.offline` a second PC that starts logged out. Every
--- member of the fleet must already be on its guild's roster (see F.new), because LibGuildRoster
--- builds from it once and presence is suppressed until the count is stable.
function F.newClient(name, opts)
	opts = opts or {}
	local c = wow.client(name, { sameCharacter = F.byName[name] ~= nil })
	c.norm      = c.fullName
	c.guildName = opts.guild or GUILD
	c.guild.name, c.guild.inGuild = c.guildName, true
	c.money     = opts.money or 0
	c.out       = {}     -- every Output call: { level=, n=, ... }
	-- WIRE-SKEW-003: THIS CLIENT'S ADDON VERSION, so a fleet can be MIXED like a real guild -- a guild
	-- mid-upgrade is the one situation the operator has actually been stuck in. DEFAULT IS THE
	-- PACKAGER'S TAG FORM (`TOGBankClassic-v1.6.0`), because a released client reports the
	-- substitution of `@project-version@`, which is the whole tag (WIRE-SKEW-002).
	if opts.addonVersion ~= false then
		c.addonMetadata.TOGBankClassic = { Version = opts.addonVersion or ("TOGBankClassic-v" .. CURRENT_VERSION) }
	end
	c.addonVersion = opts.addonVersion
	c.G = c.env
	-- NO TOGBANK GLOBAL OF THE HOST'S IS VISIBLE TO A CLIENT. `client.env` falls through to the shared
	-- `_G`, and earlier spec files leave TOGBank's modules there -- the UI windows included, which a
	-- client never loads -- so a client's `TOGBankClassic_UI_Browse` would be the HOST'S window module,
	-- driven on the rich frame model by a sync it has no part in. `false` is "absent" to every
	-- `if X then` guard and an own field to the environment (the harness README's own remedy).
	for k in pairs(_G) do
		if type(k) == "string" and k:find("^TOGBankClassic") then c.env[k] = false end
	end

	for _, mod in ipairs(ACE_ORDER) do c:loadFile(ace.pathOf(mod), mod) end
	-- `pathsOf` is every file of the library's TOC, in TOC order.
	for _, lib in ipairs(LIB_ORDER) do
		for _, path in ipairs(libs.pathsOf(lib)) do c:loadFile(path, lib) end
	end
	for _, path in ipairs(env.MODULE_ORDER) do c:loadFile(path, "TOGBankClassic") end
	-- The status bar's TEXT builders (no AceGUI needed): what every window shows the banker about the
	-- sync, SYNCED-001's line included. The window half stays unloaded.
	c:loadFile("Modules/UI/StatusBar.lua", "TOGBankClassic")
	c:loadFile("Core.lua", "TOGBankClassic")

	c:run(function()
		local G = c.env
		-- The stand-ins env.standUpClient installs, per client: a recording Output, the Database and
		-- Options surfaces the sync layer reads. Output records into the client so a spec can assert
		-- that a whole sync raised no Error and no Warn.
		G.TOGBankClassic_Output = setmetatable({}, { __index = function(_, key)
			return function(_, ...) c.out[#c.out + 1] = { level = key, n = select("#", ...), ... } return true end
		end })
		G.TOGBankClassic_Database = {
			db = { global = { switches = { sendV2Wire = true }, debugCategories = {}, debugTags = {} }, faction = {} },
			RecordDeltaSent = function() end, RecordDeltaSavings = function() end,
			RecordDeltaComputeTime = function() end, RecordNoChangeSent = function() end,
			RecordDeltaFailed = function() end, RecordDeltaReceived = function() end,
			RecordP2PRequestBroadcast = function() end, RecordP2POffered = function() end,
			RecordP2PBankerFallback = function() end,
		}
		G.TOGBankClassic_Options = {
			IsIntegrityCheckDiagnosticsEnabled = function() return false end,
			IsSyncProgressMuted = function() return true end,
			GetBankEnabled = function() return true end,
			GetAutoTombstoneDays = function() return 30 end,
		}
		G.TOGBankClassic_Inventory_Store:Init({ faction = {} })

		-- A REAL roster, brought to READY exactly as env.standUpClient does.
		local roster = G.LibStub("LibGuildRoster-1.0")
		local frame = roster.frame
		local handler = frame:GetScript("OnEvent")
		for _ = 1, (roster.STABLE_THRESHOLD or 2) + 1 do handler(frame, "GUILD_ROSTER_UPDATE") end
		-- The shape Database:Init gives the guild record (the fields the roster rebuild and the request
		-- log touch). XGUILD-SWITCH-001: the sister-guild bank is an officer switch, off by default; a
		-- fleet's clients start with it ON so a two-guild fleet federates (a one-guild fleet has no
		-- sister to reach, so the switch changes nothing there).
		G.TOGBankClassic_Guild.Info = { name = c.guildName, alts = {}, roster = {}, requests = {}, requestsTombstones = {}, settings = { sisterBank = true } }
		G.TOGBankClassic_Guild:RefreshOnlineCache()
		-- What Core's OnInitialize binds before events register: the library's presence, membership
		-- and sister-roster callbacks (XGUILD-BANKERS-001's rebuild on a sister roster lives there).
		G.TOGBankClassic_Guild:InitRosterCallbacks()
		G.TOGBankClassic_Chat:Init()
		-- XGUILD-BOUNCE-001 / XGUILD-LIVE-001 item 2, ADOPTED at pin `4ffccf4`: the server answers the
		-- SENDER of a whisper to a logged-out character with ERR_CHAT_PLAYER_NOT_FOUND_S, and the harness
		-- now fires that as CHAT_MSG_SYSTEM on the sender's frames alone. A fleet client does not run
		-- `Events:RegisterEvents` (events_spec owns that wiring), so nothing here would hear it: this
		-- frame is the one line of routing that puts the harness's event into the addon's handler, the
		-- way env_togbank drives the roster library's own frame. It replaces `F.bounceIfOffline`, which
		-- MANUFACTURED the bounce; the bounce is now real and only its delivery is wired here.
		-- `c.sysLines` is every CHAT_MSG_SYSTEM this client was handed, so a spec can assert the SERVER
		-- said something rather than only that the addon reacted -- the two failed separately while
		-- this was being adopted.
		-- HELD ON THE CLIENT, not in a local: the frames registry keeps its candidate lists WEAK, so a
		-- frame nothing else references is collected and silently stops hearing its event. As a local
		-- this frame received nothing at all, which reads exactly like the harness not firing.
		c.sysLines = {}
		c.sysFrame = G.CreateFrame("Frame")
		local sysFrame = c.sysFrame
		sysFrame:RegisterEvent("CHAT_MSG_SYSTEM")
		sysFrame:SetScript("OnEvent", function(_, event, line)
			if event ~= "CHAT_MSG_SYSTEM" then return end
			c.sysLines[#c.sysLines + 1] = line
			if G.TOGBankClassic_Events and G.TOGBankClassic_Events.CHAT_MSG_SYSTEM then
				G.TOGBankClassic_Events:CHAT_MSG_SYSTEM(event, line)
			end
		end)
		G.TOGBankClassic_Core:DeltaHost()
		G.TOGBankClassic_Bank.eventsRegistered = false
		G.TOGBankClassic_MailInventory.hasUpdated = false

		if F.wire == "throttled" then
			-- The harness's wire carries the chunks; Core's method stays the AceCommQueue-wrapped one,
			-- and this wrapper over it only writes the message-level log the ordered wire gets for free,
			-- stamping when the addon handed the message over and, through the terminal callback
			-- AceCommQueue reports once per message, when its last chunk left.
			local queued = G.TOGBankClassic_Core.SendCommMessage
			G.TOGBankClassic_Core.SendCommMessage = function(self, prefix, text, dist, target, prio, cb, cbArg)
				if c.isOnline == false then return false end   -- a logged-out client sends nothing; see F.offline
				local entry = F.logMessage(c, prefix, text, dist, target, prio)
				entry.sentAt = env.now
				local function terminal(arg, sent, total, verdict, reason)
					if sent and total and sent >= total then
						entry.leftAt, entry.verdict, entry.reason = env.now, verdict, reason
					end
					if cb then return cb(arg, sent, total, verdict, reason) end
				end
				return queued(self, prefix, text, dist, target, prio or "NORMAL", terminal, cbArg)
			end
		else
			G.TOGBankClassic_Core.SendCommMessage = function(_, prefix, text, dist, target, prio, cb, cbArg)
				-- The ORDERED bus is TOGBank's own and never reaches the harness's send seams, so the
				-- harness's offline gate (XGUILD-LIVE-001, pin 4ffccf4) cannot see it: this is that rule
				-- for this wire. On the throttled wire the harness gates the seams itself and the guard
				-- above only keeps the message-level log honest.
				if c.isOnline == false then return false end
				F.enqueue(c, prefix, text, dist, target, prio, cb, cbArg)
			end
		end
	end)

	F.clients[#F.clients + 1] = c
	F.byName[name] = F.byName[name] or c
	-- A second PC on a shared account starts logged out, WITHOUT the system line: the character is
	-- still online on the first PC. F.online brings it on when the first leaves.
	if opts.offline then c.isOnline = false end
	return c
end

--- Silence the fleet that is standing. `wow.reset()` drops the clients but NOT the frames registry,
--- so every client's ChatThrottleLib, AceComm and roster frames would live on as ghosts -- their
--- OnUpdate still despooling, their CHAT_MSG_ADDON still answering each other on the harness's wire --
--- into the next example and the next spec FILE. (The full suite hung past fifteen minutes the first
--- time it ran with this fixture on the harness, before this existed.) Runs from env_togbank's reset,
--- so the last fleet of a file is silenced by whatever resets next. Idempotent.
function F.teardown()
	if #F.clients == 0 then return end
	local mine = {}
	for _, c in ipairs(F.clients) do mine[c] = true; c.isOnline = false end
	local frames = package.loaded["env.frames"]
	if frames and frames.all then
		for _, o in ipairs(frames.all()) do
			if o._client and mine[o._client] then
				if o.UnregisterAllEvents then o:UnregisterAllEvents() end
				if o.SetScript then o:SetScript("OnUpdate", nil) end
				if o.Hide then o:Hide() end
			end
		end
	end
	for _, c in ipairs(F.clients) do
		if c.noise then c.noise:Cancel(); c.noise = nil end
	end
	F.clients, F.byName, F.queue = {}, {}, {}
end
env.resetHooks[#env.resetHooks + 1] = F.teardown

--- Reset the world and stand up a fleet. `members` is { { name=, note=, client=bool, guild=? }, ... }:
--- every entry goes on its guild's roster (online; `guild` defaults to F.GUILD); those with
--- `client = true` get a running client. Returns the clients keyed by bare name.
--- `opts.wire`: "ordered" (default) or "throttled" -- see the header.
function F.new(members, opts)
	opts = opts or {}
	-- The RICH frame model: the harness's client switching on dispatch (OnEvent, OnUpdate, the
	-- CHAT_MSG_ADDON a chunk arrives as) lives there. It drops every client of the last fleet.
	-- (SUITE-HEAP-001's hand-clearing of `frames.objects` is gone: since WoWAPITesting 4113206,
	-- FLEET-PORT-SPEED-001, dispatch walks only objects with an OnEvent or OnUpdate handler, so the
	-- ~37,000 leftovers earlier UI specs leave behind are never visited.)
	-- (The ghost-client sweep that stood here is gone too: since WoWAPITesting c426723, reset marks
	-- every dropped client and its frames never dispatch again -- the fix for the ghost `Bankchar` from
	-- wholeaddon_spec that answered CONGESTION-001's viewer in the reverse-order run.)
	env.reset({ frames = true })
	F.clients, F.byName, F.queue, F.log, F.active = {}, {}, {}, {}, nil
	F.bulkDrain = 0   -- a spec that set it does not set it for the next one
	F.wire = opts.wire or "ordered"
	if F.wire ~= "ordered" and F.wire ~= "throttled" then
		error("env_fleet: wire must be \"ordered\" or \"throttled\", got " .. tostring(F.wire), 2)
	end
	-- A chunk that leaves is delivered by `F.deliver` (the pump), never inside the send. The harness's
	-- default fires it BEFORE the send returns, and a reply can then arrive before the sender's own
	-- code after the send has run: DeltaSync opens its collect window AFTER the broadcast returns, so
	-- the offer landed before the window existed and took the late-offer path at once -- a viewer
	-- synced on its broadcast's own tick, which no client with a server between it and its guild can
	-- do (measured on congestion_spec's P2P-031 example the day this file moved onto the harness).
	-- The harness README names the same trade as DeltaSync's contract 5.
	wow.echoMode = "queued"
	-- The library's SavedVariables global outlives env.reset (xguild_spec says so).
	_G.LibGuildRosterDB = nil
	local order, seen = {}, {}
	for _, m in ipairs(members) do
		local g = m.guild or GUILD
		if not seen[g] then seen[g] = true; order[#order + 1] = g end
	end
	-- The host is in the first guild, so a client created with no `guild` copies that membership.
	env.guildName = order[1] or GUILD
	for _, g in ipairs(order) do
		if g == env.guildName then
			for _, m in ipairs(members) do
				if (m.guild or GUILD) == g then env.addGuildMember(m.name .. "-" .. env.realmName, { note = m.note }) end
			end
		else
			local list = {}
			for _, m in ipairs(members) do
				if (m.guild or GUILD) == g then
					list[#list + 1] = { name = m.name .. "-" .. env.realmName, publicNote = m.note or "", officerNote = "",
						isOnline = true, level = 60, classFileName = "WARRIOR", rankIndex = 4 }
				end
			end
			guild.setMembersFor(g, list)
		end
	end
	local out = {}
	for _, m in ipairs(members) do
		if m.client then out[m.name] = F.newClient(m.name, m) end
	end
	return out
end

--- XGUILD-SYNC-001: make guilds `a` and `b` SISTERS on every client of both -- each lists the
--- other in its LibGuildRoster record and holds the other's roster, with the `note` on each member
--- fed through the library's own `SetSisterRoster` entry (LIBREQ-GR-002, LibGuildRoster MINOR 19:
--- the served `pn` lands as `member.note`) -- then rebuilds the banker roster. The library's own
--- pull traffic is not on the wire, so the feed stands in for the served roster; what it feeds is
--- the served shape.
function F.federate(a, b)
	local function feed(c, other)
		local list = {}
		for _, m in ipairs(rosterOf(other)) do
			list[#list + 1] = { name = m.name, class = m.classFileName, level = m.level, rank = m.rankName,
				note = m.publicNote }
		end
		F.with(c, function()
			local lib = c.G.LibStub("LibGuildRoster-1.0")
			local faction = lib:GetHomeGuildKey():match("^([^%-]+)")
			local key = faction .. "-" .. other
			lib:GetSisterDb().sisterGuilds = { other }
			lib:SetSisterRoster(key, list, { provider = list[1] and list[1].name })
			assert(list[1] == nil or list[1].note == nil or lib:GetRoster(key)[list[1].name].note == list[1].note,
				"env_fleet: the library dropped the fed note -- LibGuildRoster predates LIBREQ-GR-002 (MINOR 19)")
			c.G.TOGBankClassic_Guild:RefreshOnlineCache()
			c.G.TOGBankClassic_Guild:RebuildBankerRoster()
			c.sisterKey = key
		end)
	end
	for _, c in ipairs(F.clients) do
		if c.guildName == a then feed(c, b) elseif c.guildName == b then feed(c, a) end
	end
end

--- XGUILD-E2E-001: make guilds `a` and `b` SISTERS the way an officer does -- each lists the other in
--- its LibGuildRoster record -- and FEED NOTHING. The rosters, their `gbank` notes and every presence
--- stamp have to cross on the library's own whispered pull, on the harness's wire, exactly as in game.
--- The officer's list is written to the record rather than through `SetSisterGuildNames`, whose
--- officer gate reads a rank the fleet's members do not carry; what the library reads is the record.
function F.sisters(a, b)
	for _, c in ipairs(F.clients) do
		local other = (c.guildName == a and b) or (c.guildName == b and a) or nil
		if other then
			F.with(c, function()
				local lib = c.G.LibStub("LibGuildRoster-1.0")
				lib:GetSisterDb().sisterGuilds = { other }
				c.sisterKey = lib:GetHomeGuildKey():match("^([^%-]+)") .. "-" .. other
			end)
		end
	end
end

--- XGUILD-E2E-001: the player at `c` CLICKS somewhere in the world, and the SERVER answers every /who
--- that click sent. LibGuildRoster sends a /who only from a hardware event (a full-screen overlay that
--- passes the click through, shown while a query is owed) and serves a sister guild its roster only
--- once the server has placed the asker in that guild -- so a fleet that never clicks never crosses.
--- The click reaches `c`'s own frames alone (`frames.clickAnywhere` would click every client's overlay
--- at once), under the harness's hardware-event depth. The answer is what the server knows: every
--- ONLINE fleet client whose guild name or character name is the query, in Classic's row shape, and it
--- reaches the asker alone, as a server reply does. Returns how many /who queries the click sent.
function F.click(c)
	local frames = package.loaded["env.frames"]
	local protected = require("env.protected")
	local before = #wow.whoSent
	for _, o in ipairs(frames.all()) do
		if o._client == c and o._scripts and o._scripts.OnMouseDown and o._propagateClicks and o:IsVisible() then
			c:run(protected.asHardwareEvent, o._scripts.OnMouseDown, o, "LeftButton")
		end
	end
	local sent = #wow.whoSent - before
	for i = before + 1, #wow.whoSent do
		local query = string.lower(tostring(wow.whoSent[i].filter))
		local rows = {}
		for _, r in ipairs(F.clients) do
			if r.isOnline ~= false and (string.lower(r.guildName) == query or string.lower(r.name) == query) then
				rows[#rows + 1] = { fullName = r.name, fullGuildName = r.guildName, level = 60, raceStr = "Orc",
					classStr = "Warrior", filename = "WARRIOR", area = "Orgrimmar", gender = 2 }
			end
		end
		for k in pairs(wow.whoResults) do wow.whoResults[k] = nil end
		for j, row in ipairs(rows) do wow.whoResults[j] = row end
		frames.fireEventFiltered(function(o) return o._client == c end, "WHO_LIST_UPDATE")
		F.deliver()
	end
	return sent
end

--- XGUILD-SYNC-001: `c`'s roster library has SEEN `peer` (a member of a sister guild) -- the
--- sighting its own pull traffic would have stamped. What makes `peer` a federation peer.
function F.sighted(c, peer)
	F.with(c, function()
		local lib = c.G.LibStub("LibGuildRoster-1.0")
		lib:MarkOnline(lib:IsInAnyRoster(peer.norm), { peer.norm })
		c.G.TOGBankClassic_Guild:RefreshOnlineCache()
	end)
end

-- ---------------------------------------------------------------------------
-- The ordered bus
-- ---------------------------------------------------------------------------

local function bare(name)
	return type(name) == "string" and name:match("^([^%-]+)") or name
end

--- The message-level log entry, on either wire.
function F.logMessage(from, prefix, text, dist, target, prio, cb, cbArg)
	local _, decoded = from.G.TOGBankClassic_Core:DeserializeWithChecksum(text, {})
	local entry = {
		from = from, prefix = prefix, text = text, dist = dist, target = target, prio = prio,
		cb = cb, cbArg = cbArg, bytes = #text,
		type = type(decoded) == "table" and decoded.type or nil,
		body = decoded,
	}
	F.log[#F.log + 1] = entry
	return entry
end

--- The ordered wire: the whole message, onto the queue.
function F.enqueue(from, prefix, text, dist, target, prio, cb, cbArg)
	F.queue[#F.queue + 1] = F.logMessage(from, prefix, text, dist, target, prio, cb, cbArg)
end

--- Hand one message to one client, as the client would receive it.
local function route(r, m)
	local Chat = r.G.TOGBankClassic_Chat
	local sender = m.from.name   -- bare: what AceComm gives for a same-realm peer
	for _, p in ipairs(Chat.COMM_PREFIXES) do
		if p == m.prefix then
			Chat:OnCommReceived(m.prefix, m.text, m.dist, sender)
			return true
		end
	end
	local host = r.G.TOGBankClassic_Core:DeltaHost()
	for _, p in pairs(host.prefixes) do
		if p == m.prefix then
			host:OnAddonMessage(m.prefix, m.text, m.dist, sender)
			return true
		end
	end
	return false
end

--- Seconds a BULK send takes to leave the sender on the ORDERED wire. 0 (the default) delivers it
--- with the rest; a spec modelling a provider at capacity sets it, because on a real client a snapshot
--- drains over tens of seconds and the send slot is held for exactly that long (P2P-024/028). The
--- message ARRIVES when the drain completes, and the sender's terminal verdict is reported then.
F.bulkDrain = 0

local function online(c) return c.isOnline ~= false end

--- The ONLINE client playing `name`. Two clients may play one character -- a shared account on two
--- PCs (MULTIPC) -- but only one of them is logged in at a time, and a whisper reaches that one.
function F.clientNamed(name)
	for _, c in ipairs(F.clients) do
		if c.name == name and online(c) then return c end
	end
	return nil
end

local function deliverOne(m)
	local recipients = {}
	if m.dist == "WHISPER" then
		local r = F.clientNamed(bare(m.target))
		if r then recipients[1] = r end
	else
		-- A GUILD send reaches the sender's guild and nobody else (XGUILD-SYNC-001: what the
		-- federation's whisper pull exists to cross).
		for _, r in ipairs(F.clients) do
			if online(r) and r.guildName == m.from.guildName then recipients[#recipients + 1] = r end
		end
	end
	for _, r in ipairs(recipients) do
		local prev = F.active
		F.active = r
		local ok, err = pcall(r.run, r, function() m.routed = route(r, m) or m.routed end)
		F.active = prev
		if not ok then error(err, 0) end
	end
	if m.cb then
		F.with(m.from, function() m.cb(m.cbArg, m.bytes, m.bytes, true) end)
	end
end

--- Deliver everything queued -- the ordered bus's messages and the chunks the harness's wire is
--- holding -- including what the deliveries themselves send, until quiet.
function F.deliver()
	wow.pumpAddonMessages()
	local guard = 0
	while #F.queue > 0 do
		guard = guard + 1
		if guard > 10000 then error("env_fleet: message storm -- 10000 deliveries in one drain") end
		local m = table.remove(F.queue, 1)
		if m.prio == "BULK" and F.bulkDrain > 0 then
			-- writ:schedule the ordered wire's model of a BULK payload draining for F.bulkDrain simulated seconds; the clock IS what is being modelled
			_G.C_Timer.After(F.bulkDrain, function() deliverOne(m) end)
		else
			deliverOne(m)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Presence and the clock
-- ---------------------------------------------------------------------------

--- Take a client off the network: the rest of its guild gets "Name has gone offline.", the wire drops
--- what is sent to it and it hears no broadcast. Its state is kept -- it is a player who logged out,
--- not a wipe. Its timers still fire (the harness's rule) -- AND NOTHING THEY SEND LEAVES IT.
---
--- XGUILD-LIVE-001, ADOPTED at harness pin `4ffccf4` (`58ff098`): the harness now gates all three of
--- its send seams -- `SendAddonMessage`, `SendAddonMessageLogged`, `C_BattleNet.SendGameData` -- on
--- the SENDER being online, so a logged-out client echoes nothing, routes nothing and puts nothing on
--- `wow.wire` (the call is kept on `wow.sent` marked `dropped = "offline"`, because the addon really
--- did make it). This file's stand-in -- shadowing each client's own `C_ChatInfo` table while it was
--- offline -- is deleted with the adoption.
---
--- Why it mattered enough to contract for: the harness always dropped what was sent TO an offline
--- client, but not what its still-firing timers SENT. LibGuildRoster's rounds kept whispering a sister
--- banker its pull and relaying its roster for the whole ten minutes after the home banker "logged
--- off" (measured: six library sends in 660 s), and **a broadcast is a sighting** -- each one
--- re-stamped the logged-out banker's presence on the clients that heard it, so the failover cycle
--- asked the banker who was gone. The env was not missing an edge, it was manufacturing evidence for
--- the wrong answer.
--- `c.isOnline` IS THE ONLY FLAG, and this used to set a second one. `c.offline` was written here,
--- cleared in F.online and set by hand in one spec, and read NOWHERE -- one concept with two
--- spellings, the write-only one being the plausible-looking one. A future guard written against it
--- would have been true for a client taken offline through here and FALSE for one created with
--- `opts.offline` (which sets only `isOnline`), and nothing would have caught that. Peer Review
--- 8e933d44 asked for the deletion; `wow.setOnline`, through F.presence, owns the flag.
function F.offline(c)
	F.presence(c, false)
end

--- Bring it back. The client is exactly as it was when it left.
function F.online(c)
	F.presence(c, true)
end

--- Flip a member's presence and let every client's roster see it THE WAY THE CLIENT TELLS IT: the
--- "[Name] has come online." / "Name has gone offline." system line. LibGuildRoster builds its roster
--- ONCE from GUILD_ROSTER_UPDATE and then ignores that event outright; after that, presence is the
--- chat line and nothing else (found by SYNCED-001's "alone" scenario, the first to READ presence).
--- A running client flips through the harness (`setOnline`, which marks the roster and sends the line
--- to the rest of its guild). A roster member with NO client -- `{ norm = "Name-Realm" }` -- has no
--- harness player to flip, so its line is handed to each client's roster library here.
function F.presence(c, isOnline)
	if c.run then
		wow.setOnline(c, isOnline)
	else
		local bareName = bare(c.norm)
		local line = isOnline and string.format(_G.ERR_FRIEND_ONLINE_SS, bareName, bareName)
			or string.format(_G.ERR_FRIEND_OFFLINE_S, bareName)
		for _, r in ipairs(F.clients) do
			F.with(r, function()
				for _, m in ipairs(env.roster) do
					if m.name == c.norm then m.isOnline = isOnline end
				end
				local lib = r.G.LibStub("LibGuildRoster-1.0")
				lib.frame:GetScript("OnEvent")(lib.frame, "CHAT_MSG_SYSTEM", line)
			end)
		end
	end
	for _, r in ipairs(F.clients) do
		F.with(r, function()
			-- A sister guild's client never gets that system line; its presence for a sister member is
			-- a sighting stamp. Coming back is a sighting (the player's first message would be one);
			-- going away is NOT un-stamped here -- the library has no "un-sight" and neither has the
			-- game: the stamp ages out (PRESENCE_TTL) or a whisper to them bounces (the harness's own
			-- ERR_CHAT_PLAYER_NOT_FOUND_S since pin `4ffccf4`), and a spec that logs a sister member off
			-- meets exactly what a live client meets.
			-- (XGUILD-LIVE-001: this used to clear `lib.presence` by hand, which let the failover leg
			-- pass without the bounce the addon actually has to act on.)
			local lib = r.G.LibStub("LibGuildRoster-1.0")
			if isOnline and c.guildName and c.guildName ~= r.guildName and lib.IsInAnyRoster and lib.MarkOnline then
				local key = lib:IsInAnyRoster(c.norm)
				if key then lib:MarkOnline(key, { c.norm }) end
			end
			r.G.TOGBankClassic_Guild:RefreshOnlineCache()
		end)
	end
end

--- Let `seconds` pass in one-second steps, firing timers and draining the ordered bus after each.
function F.tick(seconds)
	F.deliver()
	local target = env.now + (seconds or 0)
	while env.now < target do
		env.advance(math.min(1, target - env.now))
		F.deliver()
	end
end

-- ---------------------------------------------------------------------------
-- Congestion (the throttled wire only)
-- ---------------------------------------------------------------------------

--- The client has just entered the world: PLAYER_ENTERING_WORLD on its own frames
--- (`client:enterWorld`), so its ChatThrottleLib empties its gauge and re-arms the 5-second hard
--- clamp (about 80 bytes/s, 400 burst) -- the state every login cycle actually runs in. Call it, let
--- the roster settle (`F.tick`), then `F.login`. Nothing on the ordered wire reads it.
function F.enterWorld(c)
	if F.wire ~= "throttled" then return end
	c:enterWorld(false, false)
end

--- OTHER ADDONS' traffic on this client: `bytesPerSecond` straight through the client's
--- `C_ChatInfo.SendAddonMessage` every second, past ChatThrottleLib -- which sees it through its hook
--- and charges it against the same 800 bytes/s TOGBank has (`client:background`, prefix "OtherAddon",
--- which nobody registers). 0 stops it.
function F.background(c, bytesPerSecond)
	if c.noise then c.noise:Cancel(); c.noise = nil end
	if (bytesPerSecond or 0) > 0 then c.noise = c:background(bytesPerSecond, "OtherAddon") end
end

--- The bandwidth gauge of a client's ChatThrottleLib, for a spec that wants to say it was empty.
function F.avail(c)
	return c.ctl and c.ctl.avail or nil
end

-- ---------------------------------------------------------------------------
-- Driving and reading a client
-- ---------------------------------------------------------------------------

--- Stage the client's containers and scan. `contents` is bag 0 (an array of { id, count } or
--- ids); `opts.bank` is the vault (bag -1) -- pass a table to be "at the bank", omit to be away.
function F.scan(c, contents, opts)
	opts = opts or {}
	F.with(c, function()
		env.setBag(0, opts.size or math.max(16, #(contents or {})), contents or {})
		if opts.bank then
			env.setBag(-1, 24, opts.bank)
		else
			env.bags[-1] = nil
		end
		if opts.money then env.money = opts.money end
		c.G.TOGBankClassic_Bank.hasUpdated = true
		c.G.TOGBankClassic_Bank:Scan()
	end)
end

--- The login broadcast: what the roster-ready callback fires once per session.
function F.login(c)
	F.with(c, function() c.G.TOGBankClassic_Events:SyncDeltaVersion("NORMAL") end)
end

--- key -> count of what `c` holds for `alt` in its store.
function F.held(c, alt)
	local out = {}
	local norm = alt:find("-", 1, true) and alt or (alt .. "-" .. env.realmName)
	local Store, Record = c.G.TOGBankClassic_Inventory_Store, c.G.TOGBankClassic_Inventory_Record
	for _, rec in ipairs(Store:GetAltRecords(c.guildName, norm)) do out[Record.key(rec)] = Record.count(rec) end
	return out, Store:GetAltMoney(c.guildName, norm)
end

--- The alt record `c` holds for `alt` (canon, stamps), or nil.
function F.record(c, alt)
	local norm = alt:find("-", 1, true) and alt or (alt .. "-" .. env.realmName)
	return c.G.TOGBankClassic_Guild.Info.alts[norm]
end

--- Every Output call at `level` ("Error", "Warn", ...) the client made, formatted.
function F.output(c, level)
	local out = {}
	for _, o in ipairs(c.out) do
		if o.level == level then
			local ok, s = pcall(string.format, tostring(o[1]), unpack(o, 2, o.n))
			out[#out + 1] = ok and s or tostring(o[1])
		end
	end
	return out
end

--- Messages in the log matching a filter { from=, prefix=, type=, dist=, to= }.
function F.sent(filter)
	local out = {}
	for _, m in ipairs(F.log) do
		local ok = true
		if filter.from   and m.from.name ~= filter.from then ok = false end
		if filter.prefix and m.prefix ~= filter.prefix then ok = false end
		if filter.type   and m.type ~= filter.type then ok = false end
		if filter.dist   and m.dist ~= filter.dist then ok = false end
		if filter.to     and bare(m.target) ~= filter.to then ok = false end
		if ok then out[#out + 1] = m end
	end
	return out
end

--- Total bytes on the GUILD channel -- the resource the design protects (Chat.lua's channel note).
function F.guildBytes()
	local n = 0
	for _, m in ipairs(F.log) do if m.dist == "GUILD" then n = n + m.bytes end end
	return n
end

return F
