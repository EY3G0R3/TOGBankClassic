-- env_fleet -- SEVERAL WHOLE CLIENTS IN ONE LUA STATE, talking to each other over a message bus.
--
-- WHY THIS EXISTS. Every other spec in this suite drives ONE client and hands it the bytes a second
-- client would have sent -- captured from a first stand-up, or built by hand. That proves each leg;
-- it cannot prove the SYNC, because a sync is a conversation: a broadcast that draws offers, offers
-- that open a version query, a query that picks holders, a handshake, a data leg, a completion that
-- frees a slot another requester was queued behind, a catch-up cycle when the first round learnt
-- nothing. The operator, 2026-09-11: "you need COMPREHENSIVE end to end testing in the test harness.
-- FULL SYNC, not just pieces." This fixture is what makes that a thing a spec can say.
--
-- HOW A CLIENT IS ISOLATED. Every addon file publishes plain globals (`TOGBankClassic_Guild = {}`),
-- and the libraries register through a global `LibStub`, so two clients cannot share a global
-- table. Each client therefore gets ITS OWN GLOBAL ENVIRONMENT: a table whose `__index` falls
-- through to the real `_G` for the WoW API stubs, and every library and module file is loaded with
-- `setfenv` pointing at it, so their globals land in the client and their reads of the WoW API fall
-- through. Its `_G` is itself, so a library's `_G.X = ...` stays inside the client too. LibStub,
-- Ace3, AceCommQueue, LibGuildRoster, DeltaSync and the addon are loaded PER CLIENT from the same
-- installed files every other spec uses -- the REAL code, one instance each.
--
-- WHAT IS SHARED, deliberately, because it is the same world: the clock (`env.now` and the timer
-- queue), the guild roster (`env.roster`), the item cache. What is switched when a client runs is
-- what the client sees of itself: `UnitName`, its bags and money. Every entry into a client --
-- a delivered message, a timer it armed, a call a spec makes -- goes through `F.with(client, fn)`,
-- and a client's `C_Timer` is wrapped so its callbacks re-enter it. Get that wrong and a timer
-- fires as somebody else, so the wrapping is the one piece of this file that is not optional.
--
-- THE SEAM, DECLARED: the bus captures `Core:SendCommMessage` -- the wrapper every send in the addon
-- and every host send goes through -- and delivers the WHOLE message to each recipient's receive
-- handler (`Chat:OnCommReceived` for TOGBank's prefixes, the DeltaSync host's `OnAddonMessage` for
-- its own). AceComm's 255-byte chunking, ChatThrottleLib's pacing and AceCommQueue's serialisation
-- are NOT modelled; the envelope and the chunk reassembly are `syncwire_spec` / `deltahost_spec`'s
-- ground. The sender name is delivered as AceComm spells it for a same-realm peer -- the BARE name
-- -- because that is what found the slot leak in step 3b. A GUILD send is delivered to every client
-- including the sender (the client echoes its own guild addon messages), and the terminal delivery
-- verdict is reported to the sender's callback the way AceCommQueue reports it: once, `true`.
--
-- The bus is a QUEUE, drained by `F.deliver()`; `F.tick(seconds)` advances the clock in one-second
-- steps, firing timers and draining the queue after each, so a spec says "sixty seconds pass" and
-- the collect window closes, the dispatch goes out, the accept comes back, the data lands.
--
-- This is TOGBank-specific glue over the harness (`Tests/wowapi`); a generalised form would be a
-- harness contribution (Tests/HARNESS_CONTRACT.md), not something to grow here.
---@diagnostic disable: undefined-global, lowercase-global
-- luacheck: std lua51

package.path = "./Tests/?.lua;" .. package.path
local env  = require("env_togbank")
local ace  = require("env.ace")
local libs = require("env.libs")

local F = {}
F.env     = env
F.clients = {}     -- array, in creation order
F.byName  = {}     -- bare name -> client
F.queue   = {}     -- messages not yet delivered
F.log     = {}     -- every message ever sent: { from=, prefix=, dist=, target=, bytes=, type= }
F.active  = nil    -- the client currently running

local GUILD = "Testguild"
F.GUILD = GUILD

-- WIRE-SKEW-003: the version a fleet client runs unless a spec says otherwise. Read from the
-- addon's OWN constant rather than written here, so the fleet cannot drift from the release the
-- data-leg gate is defined against (PROTOCOL.DATA_LEG_MIN_ADDON_VERSION).
local CURRENT_VERSION = "1.5.0"
F.CURRENT_VERSION = CURRENT_VERSION
F.OLD_VERSION     = "TOGBankClassic-v1.4.1"   -- a RELEASED peer from before the data leg changed

-- ---------------------------------------------------------------------------
-- Running as a client
-- ---------------------------------------------------------------------------

--- Run `fn` as `c`: its name, bags and money are what the WoW API answers meanwhile. Returns
--- whatever `fn` returns, so a spec can READ a client (`F.with(c, function() return ... end)`).
function F.with(c, fn, ...)
	local prev = F.active
	local prevName, prevBags, prevMoney = env.playerName, env.bags, env.money
	F.active, env.playerName, env.bags, env.money = c, c.name, c.bags, c.money
	local results = { pcall(fn, ...) }
	F.active, env.playerName, env.bags, env.money = prev, prevName, prevBags, prevMoney
	if not results[1] then error(results[2], 0) end
	return unpack(results, 2, table.maxn(results))
end

--- A client-bound C_Timer: every callback re-enters the client that armed it.
local function timersFor(c)
	local function wrap(fn) return function(...) local a = { ... } F.with(c, function() fn(unpack(a)) end) end end
	return {
		After     = function(delay, fn) return _G.C_Timer.After(delay, wrap(fn)) end,
		NewTimer  = function(delay, fn) return _G.C_Timer.NewTimer(delay, wrap(fn)) end,
		NewTicker = function(delay, fn, n) return _G.C_Timer.NewTicker(delay, wrap(fn), n) end,
	}
end

-- ---------------------------------------------------------------------------
-- Loading a client
-- ---------------------------------------------------------------------------

local function loadInto(G, path, ...)
	local chunk, err = loadfile(path)
	if not chunk then
		local fh = io.open(path, "rb")
		if fh then
			local src = fh:read("*a"); fh:close()
			if src:sub(1, 3) == "\239\187\191" then chunk, err = loadstring(src:sub(4), "@" .. path) end
		end
	end
	if not chunk then error("env_fleet: could not load " .. path .. ": " .. tostring(err), 2) end
	setfenv(chunk, G)
	return chunk(...)
end

-- Ace3 in dependency order (env.ace's verified edges), then the sibling libraries the TOCs declare.
local ACE_ORDER = { "CallbackHandler-1.0", "AceAddon-3.0", "AceEvent-3.0", "AceTimer-3.0",
	"AceSerializer-3.0", "AceConsole-3.0", "ChatThrottleLib", "AceComm-3.0" }
-- LibItemDB is a declared dependency (Resolve raises an Error line without it), and VersionCheck is
-- its own.
local LIB_ORDER = { "AceCommQueue-1.0", "LibGuildRoster-1.0", "DeltaSync-1.0", "VersionCheck-1.0", "LibItemDB-1.0" }

--- Stand up a whole client called `name` (bare character name). `opts.money` is its purse.
--- Every member of the fleet must already be on `env.roster` (see F.new), because LibGuildRoster
--- builds from it once and presence is suppressed until the count is stable.
function F.newClient(name, opts)
	opts = opts or {}
	local c = {
		name  = name,
		norm  = name .. "-" .. env.realmName,
		bags  = {},
		money = opts.money or 0,
		out   = {},     -- every Output call: { level=, n=, ... }
	}
	local G = setmetatable({}, { __index = _G })
	G._G = G
	G.C_Timer = timersFor(c)
	-- Two libraries decide whether to INSTALL by looking for themselves as a global, and through
	-- `__index` they would find the copy the rest of the suite installed in the real `_G` -- so
	-- every client would share one LibStub (and NewAddon("TOGBankClassic") would refuse the second
	-- client) and one ChatThrottleLib. `false` is "absent" to their guards and an own field to the
	-- environment, so each installs its own.
	G.LibStub = false
	G.ChatThrottleLib = false

	-- WIRE-SKEW-003: THIS CLIENT'S ADDON VERSION, so a fleet can be MIXED like a real guild.
	--
	-- Until this, every client in the fleet ran the same build, and that is the shape of the whole
	-- fixture's blind spot: a guild mid-upgrade is the ONE situation the operator has actually been
	-- stuck in, and the fleet could not express it. `opts.addonVersion` is an OWN field on the
	-- client's environment, so it wins over the `__index` fall-through to the suite-wide stub, and
	-- `Guild:GetVersion` -> the hlb2 broadcast -> every other client's `PeerSpeaksDataLeg` reads it
	-- through the real bus.
	--
	-- DEFAULT IS THE PACKAGER'S TAG FORM, not "1.5.0", and that is the point of WIRE-SKEW-002: a
	-- RELEASED client reports the substitution of `@project-version@`, which is the whole git tag
	-- (`TOGBankClassic-v1.5.0`). Driving the bare number is what let an anchored version parse read
	-- every released peer as a dev build and pass a gate that refused nobody.
	if opts.addonVersion ~= false then
		local version = opts.addonVersion or ("TOGBankClassic-v" .. CURRENT_VERSION)
		local function meta(addon, field)
			if addon == "TOGBankClassic" and field == "Version" then return version end
			return _G.GetAddOnMetadata(addon, field)
		end
		G.GetAddOnMetadata = meta
		G.C_AddOns = setmetatable({ GetAddOnMetadata = meta }, { __index = _G.C_AddOns })
	end
	c.addonVersion = opts.addonVersion
	c.G = G

	F.with(c, function()
		loadInto(G, "Tests/wowapi/env/LibStub.lua")
		for _, mod in ipairs(ACE_ORDER) do loadInto(G, ace.pathOf(mod), mod, {}) end
		for _, lib in ipairs(LIB_ORDER) do
			for _, path in ipairs(libs.pathsOf(lib)) do loadInto(G, path, lib, {}) end
		end
		for _, path in ipairs(env.MODULE_ORDER) do loadInto(G, path, "TOGBankClassic", {}) end
		-- The status bar's TEXT builders (no AceGUI needed): what every window shows the banker
		-- about the sync, SYNCED-001's line included. The window half stays unloaded.
		loadInto(G, "Modules/UI/StatusBar.lua", "TOGBankClassic", {})
		loadInto(G, "Core.lua", "TOGBankClassic", {})

		-- The same stand-ins env.standUpClient installs, per client: a recording Output, the
		-- Database and Options surfaces the sync layer reads. Output records into the client so a
		-- spec can assert that a whole sync raised no Error and no Warn.
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
		G.TOGBankClassic_Guild.Info = { name = GUILD, alts = {} }
		G.TOGBankClassic_Guild:RefreshOnlineCache()
		G.TOGBankClassic_Chat:Init()
		G.TOGBankClassic_Core:DeltaHost()
		G.TOGBankClassic_Bank.eventsRegistered = false
		G.TOGBankClassic_MailInventory.hasUpdated = false

		-- THE BUS. Every send the addon makes -- its own prefixes and the host's -- passes here.
		G.TOGBankClassic_Core.SendCommMessage = function(_, prefix, text, dist, target, prio, cb, cbArg)
			F.enqueue(c, prefix, text, dist, target, prio, cb, cbArg)
		end
	end)

	F.clients[#F.clients + 1] = c
	F.byName[name] = c
	-- A second PC on a shared account starts logged out; F.online brings it on when the first leaves.
	if opts.offline then c.offline = true end
	return c
end

--- Reset the world and stand up a fleet. `members` is { { name=, note=, client=bool }, ... }: every
--- entry goes on the shared roster (online); those with `client = true` get a running client.
--- Returns the clients keyed by bare name.
function F.new(members)
	env.reset()
	F.clients, F.byName, F.queue, F.log, F.active = {}, {}, {}, {}, nil
	F.bulkDrain = 0   -- a spec that set it does not set it for the next one
	for _, m in ipairs(members) do env.addGuildMember(m.name .. "-" .. env.realmName, { note = m.note }) end
	local out = {}
	for _, m in ipairs(members) do
		if m.client then out[m.name] = F.newClient(m.name, m) end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- The bus
-- ---------------------------------------------------------------------------

local function bare(name)
	return type(name) == "string" and name:match("^([^%-]+)") or name
end

function F.enqueue(from, prefix, text, dist, target, prio, cb, cbArg)
	local _, decoded = from.G.TOGBankClassic_Core:DeserializeWithChecksum(text, {})
	local entry = {
		from = from, prefix = prefix, text = text, dist = dist, target = target, prio = prio,
		cb = cb, cbArg = cbArg, bytes = #text,
		type = type(decoded) == "table" and decoded.type or nil,
		body = decoded,
	}
	F.queue[#F.queue + 1] = entry
	F.log[#F.log + 1] = entry
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

--- Seconds a BULK send takes to leave the sender. 0 (the default) delivers it with the rest; a spec
--- modelling a provider at capacity sets it, because on a real client a snapshot drains over tens of
--- seconds and the send slot is held for exactly that long (P2P-024/028). The message ARRIVES when
--- the drain completes, and the sender's terminal verdict is reported at the same moment.
F.bulkDrain = 0

--- The ONLINE client playing `name`. Two clients may play one character -- a shared account on two
--- PCs (MULTIPC) -- but only one of them is logged in at a time, and a whisper reaches that one.
function F.clientNamed(name)
	for _, c in ipairs(F.clients) do
		if c.name == name and not c.offline then return c end
	end
	return nil
end

local function deliverOne(m)
	local recipients = {}
	if m.dist == "WHISPER" then
		local r = F.clientNamed(bare(m.target))
		if r then recipients[1] = r end
	else
		for _, r in ipairs(F.clients) do
			if not r.offline then recipients[#recipients + 1] = r end
		end
	end
	for _, r in ipairs(recipients) do
		F.with(r, function() m.routed = route(r, m) or m.routed end)
	end
	if m.cb then
		F.with(m.from, function() m.cb(m.cbArg, m.bytes, m.bytes, true) end)
	end
end

--- Deliver everything queued, including what the deliveries themselves send, until quiet.
function F.deliver()
	local guard = 0
	while #F.queue > 0 do
		guard = guard + 1
		if guard > 10000 then error("env_fleet: message storm -- 10000 deliveries in one drain") end
		local m = table.remove(F.queue, 1)
		if m.prio == "BULK" and F.bulkDrain > 0 then
			_G.C_Timer.After(F.bulkDrain, function() deliverOne(m) end)
		else
			deliverOne(m)
		end
	end
end

--- Take a client off the network: the roster says offline, the bus drops what is sent to it and
--- it hears no broadcast. Its state is kept -- it is a player who logged out, not a wipe.
function F.offline(c)
	c.offline = true
	F.presence(c, false)
end

--- Bring it back. The client is exactly as it was when it left.
function F.online(c)
	c.offline = nil
	F.presence(c, true)
end

--- Flip a member's presence on the shared roster and let every client's roster library see it,
--- THE WAY THE CLIENT TELLS IT: the "[Name] has come online." / "Name has gone offline." system
--- line. LibGuildRoster builds its roster ONCE from GUILD_ROSTER_UPDATE and then ignores that
--- event outright (its header says so); after that, presence is the chat line and nothing else.
--- This used to fire GUILD_ROSTER_UPDATE and CLAIM to flip presence -- a no-op after the build --
--- and every offline scenario passed only because the bus drops what is sent to an offline
--- client. Found by SYNCED-001's "alone" scenario, the first to READ presence on a peer.
--- `c` needs only `.norm`; a roster member with no client is `{ norm = "Name-Realm" }`.
function F.presence(c, online)
	for _, m in ipairs(env.roster) do
		if m.name == c.norm then m.online = online end
	end
	-- The same global strings the library compiled its patterns from.
	local bareName = bare(c.norm)
	local line = online and string.format(_G.ERR_FRIEND_ONLINE_SS, bareName, bareName)
		or string.format(_G.ERR_FRIEND_OFFLINE_S, bareName)
	for _, r in ipairs(F.clients) do
		F.with(r, function()
			local lib = r.G.LibStub("LibGuildRoster-1.0")
			local frame = lib.frame
			frame:GetScript("OnEvent")(frame, "CHAT_MSG_SYSTEM", line)
			r.G.TOGBankClassic_Guild:RefreshOnlineCache()
		end)
	end
end

--- Let `seconds` pass in one-second steps, firing timers and draining the bus after each.
function F.tick(seconds)
	F.deliver()
	local target = env.now + (seconds or 0)
	while env.now < target do
		env.advance(math.min(1, target - env.now))
		F.deliver()
	end
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
		if opts.money then c.money = opts.money; env.money = opts.money end
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
	for _, rec in ipairs(Store:GetAltRecords(GUILD, norm)) do out[Record.key(rec)] = Record.count(rec) end
	return out, Store:GetAltMoney(GUILD, norm)
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

--- Messages in the log matching a filter { from=, prefix=, type=, dist= }.
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
