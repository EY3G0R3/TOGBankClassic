-- LibGuildRoster-1.0 integration.
--
-- As of v1.4.0 LibGuildRoster is a REQUIRED dependency (both TOCs + .pkgmeta). It replaces
-- TOGBank's hand-rolled roster cache, and adopting it is what actually fixes two audit findings:
--
--   EVENT-001  TOGBank's CHAT_MSG_SYSTEM handler has never run, so real-time presence has
--              always been dead. The library owns its own event frame and handles it.
--   ROSTER-002 Stale ex-banker stubs. TOGBank wipes its OWN memberRoster and rebuilds it from
--              lib:GetAllMembers(), so it cannot accumulate stale entries on top of what the
--              library holds.
--
-- THIS HEADER USED TO SAY "the library wipes and rebuilds, so stale members are structurally
-- impossible", AND THAT IS FALSE. LibGuildRoster is BUILD-ONCE: `LibGuildRoster-1.0.lua:1587`
-- reads "BUILD ONCE. THE ROSTER IS NEVER REBUILT", and `:1613` returns early from
-- GUILD_ROSTER_UPDATE once initialized. Membership is maintained after login from CHAT_MSG_SYSTEM
-- alone (ERR_GUILD_JOIN_S / ERR_GUILD_LEAVE_S / ERR_GUILD_REMOVE_SS).
--
-- The wrong version is what sent the removal example at the wrong mechanism: it emptied the fake
-- roster and fired GUILD_ROSTER_UPDATE, which build-once ignores by design, so the ex-member
-- survived and the red read as a TOGBank defect when TOGBank was correct. The example now
-- announces the departure in chat and asserts removal through that path.
--
-- THE REAL GUARANTEE IS WEAKER THAN "IMPOSSIBLE" and must not be restated as such: chat parsing
-- plus a fresh build at the next login. A departure whose system message is never delivered
-- persists in the roster until relog.
--
-- These specs load the REAL library from the sibling GuildRoster install (not a stub), because
-- the whole value of the migration is that its behaviour is real. A stub would assert only that
-- the mock works.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

describe("LibGuildRoster availability", function()
	before_each(function() env.reset() end)

	it("loads from the sibling GuildRoster install", function()
		local lib = env.freshGuildRoster()
		assert.is_table(lib)
	end)

	it("exposes every method TOGBank's roster layer needs", function()
		local lib = env.freshGuildRoster()
		for _, method in ipairs({
			"NormalizeName", "GetNormalizedPlayer", "GetRealmName",
			"IsInGuild", "IsOnline", "IsReady",
			"GetMember", "GetAllMembers", "GetOnlineMembers",
			"RegisterCallback",
		}) do
			assert.is_function(lib[method], "LibGuildRoster is missing " .. method)
		end
	end)

	-- The library registers PLAYER_LOGIN / GUILD_ROSTER_UPDATE / CHAT_MSG_SYSTEM on its own
	-- frame. Consumers do NOT forward events — which is precisely why adopting it fixes
	-- EVENT-001, a bug caused by TOGBank forwarding one incorrectly.
	it("owns its own event registration rather than taking forwarded events", function()
		local lib = env.freshGuildRoster()
		assert.is_not_nil(lib.frame, "expected the library to create its own event frame")
		for _, event in ipairs({ "PLAYER_LOGIN", "GUILD_ROSTER_UPDATE", "CHAT_MSG_SYSTEM" }) do
			assert.is_true(lib.frame:IsEventRegistered(event),
				"library did not register " .. event .. " itself")
		end
	end)
end)

describe("LibGuildRoster name normalization", function()
	local lib
	before_each(function()
		env.reset()
		lib = env.freshGuildRoster()
	end)

	-- TOGBank keys every alt record, request and wire message by normalized name, so the
	-- library's normalization must agree with TOGBank's or every lookup misses after migration.
	it("appends the connected realm to a bare name", function()
		assert.equal("Bob-Testrealm", lib:NormalizeName("Bob"))
	end)

	it("leaves an already-qualified name alone", function()
		assert.equal("Bob-Otherrealm", lib:NormalizeName("Bob-Otherrealm"))
	end)

	it("returns nil for nil", function()
		assert.is_nil(lib:NormalizeName(nil))
	end)

	it("agrees with TOGBank's own normalizer on the shapes TOGBank stores", function()
		env.stubOutput()
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/Guild.lua")
		local Guild = TOGBankClassic_Guild
		for _, name in ipairs({ "Bob", "Bob-Testrealm", "Bob-Otherrealm", "  Bob  " }) do
			assert.equal(Guild:NormalizeName(name), lib:NormalizeName(name),
				"normalizers disagree on " .. string.format("%q", name) ..
				" — every alt key would miss after migration")
		end
	end)
end)

describe("LibGuildRoster roster read", function()
	local lib
	before_each(function()
		env.reset()
		env.addGuildMember("Banker-Testrealm", { note = "gbank", online = true })
		env.addGuildMember("Regular-Testrealm", { note = "", online = true })
		env.addGuildMember("Offline-Testrealm", { note = "", online = false })
		lib = env.freshGuildRoster()
		env.readyGuildRoster(lib)
	end)

	it("reports members after a roster update", function()
		local all = lib:GetAllMembers()
		assert.truthy(#all >= 3, "expected 3 members, got " .. #all)
	end)

	it("reports online state per member", function()
		assert.is_true(lib:IsOnline("Banker-Testrealm"))
		assert.is_false(lib:IsOnline("Offline-Testrealm"))
	end)

	-- Banker detection stays in TOGBank (domain logic); the library's job is to hand over the
	-- raw note fields unmodified. See LIBREQ-GR-001.
	it("exposes the public note, which is what banker detection reads", function()
		local m = lib:GetMember("Banker-Testrealm")
		assert.is_table(m, "GetMember returned nothing for a known member")
		assert.equal("gbank", m.publicNote)
	end)

	it("exposes the officer note as a separate field", function()
		local m = lib:GetMember("Banker-Testrealm")
		assert.is_not_nil(m.officerNote, "officerNote must exist separately from publicNote")
	end)

	it("returns nil for a member who is not in the guild", function()
		assert.is_nil(lib:GetMember("Nobody-Testrealm"))
	end)
end)

-- ---------------------------------------------------------------------------
-- Audit EVENT-001 — the reason this migration is worth doing
-- ---------------------------------------------------------------------------
describe("LibGuildRoster presence tracking", function()
	local lib, online, offline

	before_each(function()
		env.reset()
		env.addGuildMember("Bob-Testrealm", { note = "", online = false })
		lib = env.freshGuildRoster()
		env.readyGuildRoster(lib)

		online, offline = {}, {}
		lib.RegisterCallback(TOGBankClassic_Guild or {}, "OnMemberOnline",
			function(_, name) online[#online + 1] = name end)
		lib.RegisterCallback(TOGBankClassic_Guild or {}, "OnMemberOffline",
			function(_, name) offline[#offline + 1] = name end)
	end)

	-- TOGBank's own handler for this has never fired. The library's does — and unlike
	-- TOGBank's, it is covered by the library's own 146-spec suite at 100% line coverage.
	it("fires OnMemberOnline from the come-online system message", function()
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Bob has come online.")
		assert.same({ "Bob-Testrealm" }, online,
			"the library did not report the come-online transition (audit EVENT-001 is only " ..
			"fixed if this works)")
	end)

	it("fires OnMemberOffline from the gone-offline system message", function()
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Bob has come online.")
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Bob has gone offline.")
		assert.same({ "Bob-Testrealm" }, offline)
	end)

	it("reflects the transition in IsOnline, not just the callback", function()
		assert.is_false(lib:IsOnline("Bob-Testrealm"))
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Bob has come online.")
		assert.is_true(lib:IsOnline("Bob-Testrealm"),
			"presence callback fired but the queryable state did not change")
	end)

	it("ignores an unrelated system message", function()
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Your loot: something shiny.")
		assert.same({}, online)
		assert.same({}, offline)
	end)
end)

-- ---------------------------------------------------------------------------
-- ROSTER-003 — Guild:RefreshOnlineCache builds from the library
-- ---------------------------------------------------------------------------
describe("Guild roster build via LibGuildRoster", function()
	local Guild, lib

	local function loadGuild()
		env.stubOutput()
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/Guild.lua")
		TOGBankClassic_Performance = { RecordOperation = function() end }
		Guild = TOGBankClassic_Guild
		Guild.memberRoster, Guild.onlineMembers, Guild.banksCache = {}, {}, nil
		return Guild
	end

	before_each(function()
		env.reset()
		env.addGuildMember("Banker-Testrealm",  { note = "gbank", online = true,  rankIndex = 1 })
		env.addGuildMember("Raidbank-Testrealm",{ note = "gbank viewonly", online = false, rankIndex = 2 })
		env.addGuildMember("Regular-Testrealm", { note = "", online = false, rankIndex = 4 })
		loadGuild()
		lib = env.freshGuildRoster()
		env.readyGuildRoster(lib)
	end)

	it("populates memberRoster from the library", function()
		local online, total = Guild:RefreshOnlineCache()
		assert.equal(3, total)
		assert.equal(1, online)
		assert.is_not_nil(Guild.memberRoster["Banker-Testrealm"])
	end)

	it("derives isBank from the guild note", function()
		Guild:RefreshOnlineCache()
		assert.is_true(Guild.memberRoster["Banker-Testrealm"].isBank)
		assert.is_false(Guild.memberRoster["Regular-Testrealm"].isBank)
	end)

	-- VIEWBANK-001 must survive the migration: banker detection stayed in TOGBank on purpose.
	it("derives viewOnly from the view-only marker", function()
		Guild:RefreshOnlineCache()
		assert.is_true(Guild.memberRoster["Raidbank-Testrealm"].viewOnly)
		assert.is_false(Guild.memberRoster["Banker-Testrealm"].viewOnly)
	end)

	it("carries online state through to the cache", function()
		Guild:RefreshOnlineCache()
		assert.is_true(Guild.memberRoster["Banker-Testrealm"].isOnline)
		assert.is_false(Guild.memberRoster["Raidbank-Testrealm"].isOnline)
		assert.is_true(Guild.onlineMembers["Banker-Testrealm"])
		assert.is_nil(Guild.onlineMembers["Raidbank-Testrealm"])
	end)

	it("keeps IsBank and IsViewOnlyBank working off the rebuilt cache", function()
		Guild:RefreshOnlineCache()
		assert.is_true(Guild:IsBank("Banker-Testrealm"))
		assert.is_true(Guild:IsViewOnlyBank("Raidbank-Testrealm"))
		assert.is_false(Guild:IsViewOnlyBank("Banker-Testrealm"))
	end)

	-- ROSTER-002: an ex-member must not survive in TOGBank's cache.
	--
	-- THIS DRIVES CHAT, NOT A ROSTER RE-SCAN, AND THAT IS THE WHOLE POINT.
	--
	-- This spec used to set `env.roster = {}`, re-add one member and fire GUILD_ROSTER_UPDATE,
	-- on the belief that "the library wipes and rebuilds on every update". It does not.
	-- LibGuildRoster-1.0.lua:1587 states BUILD ONCE, THE ROSTER IS NEVER REBUILT, and :1613
	-- returns early the moment it is `initialized`. So the old spec drove a mechanism the
	-- library does not have: the event was ignored, the library kept all three members, and the
	-- ex-member survived.
	--
	-- That failure looked like a TOGBank bug and was not one. Guild.lua:1757 wipes memberRoster
	-- before rebuilding from lib:GetAllMembers(), so TOGBank faithfully mirrors whatever the
	-- library holds; the stale entry was in the library, put there by this spec.
	--
	-- After login, membership is maintained ONLY from CHAT_MSG_SYSTEM (ERR_GUILD_JOIN_S /
	-- ERR_GUILD_LEAVE_S / ERR_GUILD_REMOVE_SS), so a departure has to arrive on that path.
	-- Note the consequence, which is weaker than "structurally impossible": a departure whose
	-- system message is never delivered persists until the next login build.
	it("drops a member whose departure was announced in chat", function()
		Guild:RefreshOnlineCache()
		assert.is_not_nil(Guild.memberRoster["Regular-Testrealm"])

		-- ERR_GUILD_LEAVE_S is "%s has left the guild." and the library normalizes the bare
		-- name onto the realm, so this is the same key TOGBank stores.
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Regular has left the guild.")
		Guild:RefreshOnlineCache()

		assert.is_nil(Guild.memberRoster["Regular-Testrealm"],
			"an ex-member survived after the departure was announced (audit ROSTER-002)")
	end)

	it("falls back to the legacy scan when the library is not ready", function()
		-- A fresh library has not stabilized, so _RefreshFromRosterLib must decline and the
		-- legacy GetGuildRosterInfo path must still produce a usable roster.
		local fresh = env.freshGuildRoster()
		assert.is_false(fresh:IsReady())
		local online, total = Guild:RefreshOnlineCache()
		assert.equal(3, total, "the legacy fallback did not build a roster")
		assert.equal(1, online)
	end)

	it("returns nil from _RefreshFromRosterLib when the library is absent", function()
		LibStub.libs["LibGuildRoster-1.0"] = nil
		assert.is_nil(Guild:_RefreshFromRosterLib())
	end)
end)

-- ROSTER-003: the counters behind /togbank dev rostercheck's transition report.
--
-- These exist because a snapshot comparison cannot show the presence callbacks are LIVE — our
-- cache agreeing with the library only proves the copy is faithful, since the cache is copied
-- from the library in the first place. A transition count is direct evidence the wiring fires.
describe("Guild presence transition counters", function()
	local Guild, lib

	before_each(function()
		env.reset()
		env.stubOutput()
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/Guild.lua")
		Guild = TOGBankClassic_Guild
		Guild.memberRoster, Guild.onlineMembers, Guild.recentlySeen = {}, {}, {}
		Guild._rosterCallbacksBound = nil

		env.addGuildMember("Bob-Testrealm", { note = "", online = false })
		lib = env.freshGuildRoster()
		env.readyGuildRoster(lib)
		assert.is_true(Guild:InitRosterCallbacks(), "callbacks failed to bind")
	end)

	it("starts at zero", function()
		assert.equal(0, Guild.rosterStats.online)
		assert.equal(0, Guild.rosterStats.offline)
		assert.equal(0, Guild.rosterStats.notFound)
	end)

	it("counts an online transition driven by the library", function()
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Bob has come online.")
		assert.equal(1, Guild.rosterStats.online,
			"the library fired OnMemberOnline but the counter did not move — the callback " ..
			"wiring is not live")
	end)

	it("counts an offline transition", function()
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Bob has come online.")
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Bob has gone offline.")
		assert.equal(1, Guild.rosterStats.offline)
	end)

	it("records recent transitions, capped at five", function()
		for _ = 1, 4 do
			env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Bob has come online.")
			env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Bob has gone offline.")
		end
		assert.truthy(#Guild.rosterStats.recent <= 5,
			"the recent-transition list is unbounded: " .. #Guild.rosterStats.recent)
	end)

	it("updates the roster cache as well as the counter", function()
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Bob has come online.")
		assert.is_true(Guild.onlineMembers["Bob-Testrealm"],
			"counter moved but UpdateOnlineMember was not driven")
	end)

	-- Binding twice would double-fire every callback and double-count every transition.
	it("binds only once", function()
		assert.is_true(Guild:InitRosterCallbacks())
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Bob has come online.")
		assert.equal(1, Guild.rosterStats.online, "callbacks were bound twice and double-fired")
	end)
end)

-- ---------------------------------------------------------------------------
-- Packaging — both TOCs and .pkgmeta must declare it, spelled correctly
-- ---------------------------------------------------------------------------
describe("LibGuildRoster packaging", function()
	local function read(path)
		local fh = io.open(path, "rb")
		if not fh then return "" end
		local s = fh:read("*a"); fh:close()
		if s:sub(1, 3) == "\239\187\191" then s = s:sub(4) end
		return s
	end

	-- The TOC takes the addon FOLDER name; .pkgmeta takes the CurseForge SLUG. They differ for
	-- this library, and each is silently wrong in its own way: a bad slug skips auto-install,
	-- a bad folder name breaks load order.
	it("declares the folder name GuildRoster in both TOCs", function()
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_BCC.toc" }) do
			local deps = read(toc):match("## Dependencies:([^\n]*)")
			assert.is_not_nil(deps, toc .. " has no Dependencies line")
			assert.truthy(deps:find("GuildRoster", 1, true),
				toc .. " does not declare GuildRoster as a dependency")
		end
	end)

	it("declares the CurseForge slug libguildroster in .pkgmeta", function()
		local pkg = read(".pkgmeta")
		assert.truthy(pkg:find("libguildroster", 1, true),
			".pkgmeta must list the slug 'libguildroster' (not the folder name) under " ..
			"required-dependencies, or CurseForge will not auto-install it")
	end)

	it("keeps the two TOC dependency lines identical", function()
		local a = read("TOGBankClassic.toc"):match("## Dependencies:([^\n]*)")
		local b = read("TOGBankClassic_BCC.toc"):match("## Dependencies:([^\n]*)")
		assert.equal(a, b, "the TOC lockstep rule requires both flavours declare the same deps")
	end)
end)

-- ROSTER-004: "no bankers" and "bankers I am not allowed to see" look identical.
--
-- GetGuildRosterInfo returns officerNote as "" both when the note is empty and when the player's
-- rank cannot read officer notes. So a guild that tags its bankers ONLY in the officer note shows
-- a member without that permission an empty window and no reason for it.
--
-- These load the REAL library, because the whole point is that lib:IsOfficer() answers from
-- C_GuildInfo.CanViewOfficerNote (LibGuildRoster-1.0.lua:2361-2363). Against a stub they would be
-- asserting about the stub -- and LIBREQ-GR-001 was filed BECAUSE nobody noticed IsOfficer already
-- answers this question under a name that sounds like it is about rank.
describe("ROSTER-004: explaining an empty banker list", function()
	local Guild

	local function loadGuildWithRoster()
		env.reset()
		env.stubOutput()
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/Guild.lua")
		env.freshGuildRoster()
		Guild = TOGBankClassic_Guild
		Guild.memberRoster, Guild.banksCache = {}, nil
		Guild.Info = { name = "Testguild", roster = { alts = {} }, alts = {} }
		return Guild
	end

	--- Did a user-visible warning naming officer notes go out?
	local function warnedAboutOfficerNotes()
		for _, call in ipairs(TOGBankClassic_Output.calls) do
			if call.level == "Warn" and type(call[1]) == "string"
				and call[1]:find("officer notes", 1, true) then
				return true
			end
		end
		return false
	end

	before_each(function()
		loadGuildWithRoster()
		-- A member with no banker tag at all, so the list is legitimately empty in every example
		-- below and the ONLY thing that varies is whether we can read officer notes.
		env.addGuildMember("Someone-Testrealm", {})
	end)

	it("says why the list is empty when the player cannot read officer notes", function()
		C_GuildInfo.CanViewOfficerNote = function() return false end

		Guild:RebuildBankerRoster()

		assert.is_true(warnedAboutOfficerNotes(),
			"a player whose rank cannot read officer notes was shown an empty banker list with " ..
			"no explanation -- indistinguishable from a guild that has no bankers")
	end)

	it("stays quiet when the player CAN read officer notes, because then empty means empty", function()
		C_GuildInfo.CanViewOfficerNote = function() return true end

		Guild:RebuildBankerRoster()

		assert.is_false(warnedAboutOfficerNotes(),
			"the addon blamed officer-note permissions for an empty list it could see the whole of")
	end)

	it("warns once, not on every GUILD_ROSTER_UPDATE", function()
		C_GuildInfo.CanViewOfficerNote = function() return false end

		Guild:RebuildBankerRoster()
		Guild:RebuildBankerRoster()
		Guild:RebuildBankerRoster()

		local warnings = 0
		for _, call in ipairs(TOGBankClassic_Output.calls) do
			if call.level == "Warn" and type(call[1]) == "string"
				and call[1]:find("officer notes", 1, true) then
				warnings = warnings + 1
			end
		end
		assert.equal(1, warnings,
			"RebuildBankerRoster runs on every roster update, so an unguarded warning becomes a " ..
			"chat spam loop for the whole session")
	end)

	it("stays quiet once a banker IS visible, whatever the permission says", function()
		C_GuildInfo.CanViewOfficerNote = function() return false end
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })

		Guild:RebuildBankerRoster()

		assert.same({ "Banker-Testrealm" }, Guild.Info.roster.alts,
			"precondition: the banker was not picked up, so the assertion below proves nothing")
		assert.is_false(warnedAboutOfficerNotes(),
			"the addon warned about invisible bankers while displaying one")
	end)

	-- The library's own header requires feature detection: IsOfficer arrived in MINOR 12 and an
	-- older installed copy will not have it. Guessing in its absence would fire this warning for
	-- every guild that genuinely has no bankers.
	it("stays quiet when the installed library is too old to answer", function()
		C_GuildInfo.CanViewOfficerNote = function() return false end
		local lib = LibStub("LibGuildRoster-1.0", true)
		assert.is_not_nil(lib, "precondition: the library did not load, so this proves nothing")
		lib.IsOfficer = nil

		Guild:RebuildBankerRoster()

		assert.is_false(warnedAboutOfficerNotes(),
			"the addon asserted a permission problem against a library that cannot report one")
	end)
end)
