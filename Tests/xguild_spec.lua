-- XGUILD-SYNC-001 / XGUILD-LABEL-001, build steps 2 and 3 of docs/XGUILD_SYNC.md: the FEDERATION.
--
-- A listed sister guild's members join memberRoster with `guildKey`; a name in any roster passes
-- the membership gate; a sister member whose public note carries `gbank` is a banker (the note
-- rides the sister roster only once LIBREQ-GR-002 lands, so it is feature-detected -- these
-- examples set the field on the stored member exactly where the library will); every banker
-- listing tags a sister guild's banker with its guild's name and leaves a home banker untagged.
--
-- The REAL LibGuildRoster is loaded from the sibling install; the sister roster is fed through
-- its own SetSisterRoster and the guild listed in its own SavedVariables record.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local HOME_BANKER = "Banker-Testrealm"
local SIS_BANKER  = "Sisbank-Testrealm"
local SIS_MEMBER  = "Sismember-Testrealm"
local SIS_VIEW    = "Sisview-Testrealm"
local STRANGER    = "Nobody-Testrealm"
local SISTER      = "Sister Guild"

local Guild, lib, sisterKey

local function loadGuild()
	env.stubOutput()
	env.loadFile("Modules/Constants.lua")
	env.loadFile("Modules/Guild.lua")
	TOGBankClassic_Performance = { RecordOperation = function() end }
	Guild = TOGBankClassic_Guild
	Guild.memberRoster, Guild.onlineMembers, Guild.banksCache = {}, {}, nil
	-- XGUILD-SWITCH-001: the switch ON, as an officer would have it; the switch's own example turns it off.
	Guild.Info = { name = "Testguild", alts = {}, roster = { alts = {} }, settings = { sisterBank = true } }
	-- The two "who am I" accessors, as loadWire below stubs them: Bank.lua is not loaded here, and
	-- the roster refresh reaches GetPlayer (SETTINGS-003's floor publish) -- run alone this file
	-- errored on it and passed in the full suite only on a TOGBankClassic_Bank an earlier file left.
	Guild.GetNormalizedPlayer = function() return "Regular-Testrealm" end
	Guild.GetPlayer = function() return "Regular-Testrealm" end
	return Guild
end

--- The faction half of the library's guild keys, taken from the key it built for the home guild
--- so the sister key is spelled exactly as GetSisterGuildKeys will spell it.
local function faction()
	local homeKey = lib:GetHomeGuildKey()
	assert.is_string(homeKey, "the home guild key did not resolve")
	return homeKey:match("^([^%-]+)")
end

--- List the sister guild and feed its roster with the note on the members `notes` names, through
--- the library's own feed entry -- LIBREQ-GR-002 (LibGuildRoster MINOR 19, adopted from its working
--- tree 2026-09-15): the provider serves the public note as `pn`, `takeServedRoster` feeds it as
--- `note`, and `SetSisterRoster` keeps it as `member.note`. A feed entry with no note is a member
--- with none, which is also what an older provider's roster reads as.
local function feedSister(notes, online)
	notes = notes or {}
	sisterKey = faction() .. "-" .. SISTER
	lib:GetSisterDb().sisterGuilds = { SISTER }
	lib:SetSisterRoster(sisterKey, {
		{ name = SIS_BANKER, class = "WARRIOR", level = 60, rank = "Bank", note = notes[SIS_BANKER] },
		{ name = SIS_MEMBER, class = "MAGE", level = 40, rank = "Member", note = notes[SIS_MEMBER] },
		{ name = SIS_VIEW, class = "PRIEST", level = 60, rank = "Bank", note = notes[SIS_VIEW] },
	}, { provider = SIS_MEMBER })
	for name, note in pairs(notes) do
		assert.equal(note, lib:GetRoster(sisterKey)[name].note, "the library dropped a fed note (LibGuildRoster before MINOR 19)")
	end
	if online then lib:MarkOnline(sisterKey, online) end
end

describe("XGUILD-SYNC-001: the federation", function()
	before_each(function()
		env.reset()
		env.addGuildMember(HOME_BANKER, { note = "gbank", online = true, rankIndex = 1 })
		env.addGuildMember("Regular-Testrealm", { note = "", online = false, rankIndex = 4 })
		loadGuild()
		-- The library's SavedVariables global outlives env.reset: a sister guild listed by one
		-- example would still be listed (and its roster re-fed) in the next.
		_G.LibGuildRosterDB = nil
		lib = env.freshGuildRoster()
		env.readyGuildRoster(lib)
	end)

	it("a listed sister guild's members join memberRoster with their guild key, online by the library's sighting", function()
		feedSister({ [SIS_BANKER] = "gbank" }, { SIS_BANKER })
		local online, total = Guild:RefreshOnlineCache()
		assert.equal(2, total, "the count the library reports is the home roster's")
		assert.equal(2, online, "the home banker and the sighted sister banker")
		local m = Guild.memberRoster[SIS_BANKER]
		assert.is_table(m, "the sister banker is not in memberRoster")
		assert.equal(sisterKey, m.guildKey)
		assert.is_true(m.isOnline); assert.is_true(m.isBank); assert.is_false(m.isOfficer)
		assert.is_false(Guild.memberRoster[SIS_MEMBER].isOnline, "an unsighted sister member read as online")
		assert.is_false(Guild.memberRoster[SIS_MEMBER].isBank)
		assert.is_nil(Guild.memberRoster[HOME_BANKER].guildKey, "a home member was given a guild key")
		-- The membership gate every receive path reads: federated names pass, a stranger does not.
		assert.is_true(Guild:IsInCurrentGuildRoster(SIS_MEMBER))
		assert.is_true(Guild:IsInCurrentGuildRoster(HOME_BANKER))
		assert.is_false(Guild:IsInCurrentGuildRoster(STRANGER))
		assert.is_true(Guild:IsFederated(SIS_MEMBER)); assert.is_false(Guild:IsFederated(STRANGER))
		assert.is_true(Guild:IsPlayerOnline(SIS_BANKER))
	end)

	it("GuildOf / IsHomeMember / GuildNameOf / GuildTag: home untagged, a sister member tagged with its guild's name, a stranger nothing", function()
		feedSister()
		Guild:RefreshOnlineCache()
		assert.equal(lib:GetHomeGuildKey(), Guild:GuildOf(HOME_BANKER))
		assert.equal(sisterKey, Guild:GuildOf("Sisbank"))   -- a bare name normalises
		assert.is_nil(Guild:GuildOf(STRANGER))
		assert.is_true(Guild:IsHomeMember(HOME_BANKER)); assert.is_false(Guild:IsHomeMember(SIS_BANKER))
		assert.equal("", Guild:GuildNameOf(HOME_BANKER))
		assert.equal(SISTER, Guild:GuildNameOf(SIS_BANKER))
		assert.equal("", Guild:GuildNameOf(STRANGER))
		assert.equal("", Guild:GuildTag(HOME_BANKER))
		assert.equal(" |cff808080(" .. SISTER .. ")|r", Guild:GuildTag(SIS_BANKER))
		assert.equal("", Guild:GuildTag(STRANGER))
	end)

	it("the banker roster is the UNION: a sister member noted gbank is a banker, view-only by the same marker, and SenderHasGbankNote agrees", function()
		feedSister({ [SIS_BANKER] = "gbank herbs", [SIS_VIEW] = "gbank viewonly" })
		Guild:RefreshOnlineCache()
		Guild:RebuildBankerRoster()
		assert.same({ HOME_BANKER, SIS_BANKER, SIS_VIEW }, Guild.Info.roster.alts)
		assert.is_true(Guild:IsBank(SIS_BANKER)); assert.is_true(Guild:IsBank(HOME_BANKER))
		assert.is_false(Guild:IsBank(SIS_MEMBER))
		assert.is_true(Guild:IsViewOnlyBank(SIS_VIEW)); assert.is_false(Guild:IsViewOnlyBank(SIS_BANKER))
		assert.equal("herbs", Guild:BankerStores(SIS_BANKER))
		assert.is_true(Guild:SenderHasGbankNote(SIS_BANKER))
		assert.is_false(Guild:SenderHasGbankNote(SIS_MEMBER))
		assert.is_false(Guild:SenderHasGbankNote(STRANGER))
		assert.is_table(Guild.Info.alts[SIS_BANKER], "no stub was created for the sister banker")
		-- Rebuilding again is stable (no duplicate, same order).
		Guild:RebuildBankerRoster()
		assert.same({ HOME_BANKER, SIS_BANKER, SIS_VIEW }, Guild.Info.roster.alts)
	end)

	-- GSL-BANK-001: a sister guild's [GSL] character is a view-only bank (noteBankRole), but a
	-- [GSL] note is not `gbank`, so it carries no settings or donation authority -- the same as a
	-- home [GSL] character, whose note SenderHasGbankNote's home loop reads for `gbank` alone.
	it("a sister member noted [GSL] is a view-only bank and SenderHasGbankNote says no; [GSL] plus gbank says yes", function()
		feedSister({ [SIS_MEMBER] = "[GSL] shopping", [SIS_VIEW] = "[GSL] gbank" })
		Guild:RefreshOnlineCache()
		assert.is_true(Guild.memberRoster[SIS_MEMBER].isBank, "a sister [GSL] character is not a bank")
		assert.is_true(Guild:IsViewOnlyBank(SIS_MEMBER))
		assert.is_false(Guild:SenderHasGbankNote(SIS_MEMBER), "a [GSL] note granted settings authority")
		assert.is_true(Guild:SenderHasGbankNote(SIS_VIEW))
	end)

	-- XGUILD-BANKERS-001 (the operator, 2026-09-16: "should i not have the list of their bankers, and
	-- should they not be populating in the bankers tab?"): the sister roster arrives AFTER TOGBank built
	-- its member cache -- a login where the persisted copy or the first pull lands late -- and nothing
	-- but the library's own signal is allowed to fix it.
	it("a sister roster that arrives AFTER the member cache was built adds its bankers on the library's signal -- the baseline feed and a later note-only pull both", function()
		local function banks()
			local out = {}
			for _, n in ipairs(Guild:GetBanks() or {}) do out[#out + 1] = n end
			table.sort(out)
			return out
		end
		Guild:RefreshOnlineCache()
		Guild:RebuildBankerRoster()
		assert.same({ HOME_BANKER }, banks())
		assert.is_true(Guild:InitRosterCallbacks())
		-- The FIRST copy: the library files it as a baseline and fires no OnMemberJoined per member.
		feedSister({ [SIS_BANKER] = "gbank herbs" })
		assert.same({ HOME_BANKER, SIS_BANKER }, banks(), "the sister banker is not listed until something rebuilds by hand")
		assert.same({ HOME_BANKER, SIS_BANKER }, Guild.Info.roster.alts)
		-- A later pull with the SAME members and one more gbank note: no join, no leave.
		feedSister({ [SIS_BANKER] = "gbank herbs", [SIS_VIEW] = "gbank" })
		lib.callbacks:Fire("OnSisterRosterUpdated", sisterKey, "pull")
		assert.same({ HOME_BANKER, SIS_BANKER, SIS_VIEW }, banks(), "a note added on a later pull did not make a banker")
		-- The switch off: the signal adds nothing.
		Guild.Info.settings.sisterBank = false
		feedSister({ [SIS_BANKER] = "gbank herbs", [SIS_VIEW] = "gbank", [SIS_MEMBER] = "gbank" })
		lib.callbacks:Fire("OnSisterRosterUpdated", sisterKey, "pull")
		assert.is_nil(Guild.memberRoster[SIS_MEMBER] and Guild.memberRoster[SIS_MEMBER].isBank or nil)
	end)

	it("without the note (the library before LIBREQ-GR-002) a sister roster contributes members but no bankers", function()
		feedSister(nil, { SIS_BANKER })
		Guild:RefreshOnlineCache()
		Guild:RebuildBankerRoster()
		assert.same({ HOME_BANKER }, Guild.Info.roster.alts)
		assert.is_true(Guild:IsInCurrentGuildRoster(SIS_BANKER), "membership does not depend on the note")
		assert.is_false(Guild:IsBank(SIS_BANKER))
		assert.is_false(Guild:SenderHasGbankNote(SIS_BANKER))
	end)

	-- XGUILD-SWITCH-001 (the operator, 2026-09-15: "shouldn't there be some officer configuration
	-- to turn it on or make it work?"): the officer switch, off by default, one gate for every
	-- sister-facing walk, guild-synced through the settings broadcast like the shop switch.
	it("the sister-guild bank is an officer switch: OFF by default a listed sister guild adds nothing, ON it joins, and the setting travels", function()
		feedSister({ [SIS_BANKER] = "gbank" }, { SIS_BANKER })
		-- Off (the default: a settings table with no key).
		Guild.Info.settings = {}
		assert.is_false(Guild:IsSisterBankEnabled())
		Guild:RefreshOnlineCache(); Guild:RebuildBankerRoster()
		assert.is_nil(Guild.memberRoster[SIS_BANKER], "a sister member joined memberRoster with the switch off")
		assert.same({ HOME_BANKER }, Guild.Info.roster.alts)
		assert.is_false(Guild:IsFederated(SIS_MEMBER), "a sister member was federated with the switch off")
		assert.is_nil(Guild:GuildOf(SIS_BANKER))
		assert.equal(lib:GetHomeGuildKey(), Guild:GuildOf(HOME_BANKER), "the switch took the home guild's own answer with it")
		assert.same({}, Guild:SisterGuildKeys())
		assert.same({}, Guild:PullFromFederation(), "the cycle asked a sister peer with the switch off")
		-- On, through the ONE writer: the rosters follow at once and the change is broadcast.
		local broadcasts = 0
		Guild.BroadcastSettings = function() broadcasts = broadcasts + 1 end
		assert.is_true(Guild:SetSisterBankEnabled(true))
		assert.is_false(Guild:SetSisterBankEnabled(true), "a no-op write broadcast")
		assert.equal(1, broadcasts)
		assert.is_true(Guild:IsSisterBankEnabled())
		assert.is_table(Guild.memberRoster[SIS_BANKER], "the sister banker did not join on the switch")
		assert.same({ HOME_BANKER, SIS_BANKER }, Guild.Info.roster.alts)
		assert.equal(sisterKey, Guild:GuildOf(SIS_BANKER))
		assert.same({ sisterKey }, Guild:SisterGuildKeys())
		-- Off again: gone at once.
		assert.is_true(Guild:SetSisterBankEnabled(false))
		assert.is_nil(Guild.memberRoster[SIS_BANKER])
		assert.same({ HOME_BANKER }, Guild.Info.roster.alts)
		-- The receive side: a broadcast carrying the switch adopts it and rebuilds; one without the
		-- field (an older client) leaves it alone.
		local held = Guild:SettingsVersion()
		Guild:ApplyRemoteSettings(HOME_BANKER, { sisterBank = true, version = held + 1 })   -- a banker's word is authorized
		assert.is_true(Guild:IsSisterBankEnabled(), "the switch did not travel")
		assert.is_table(Guild.memberRoster[SIS_BANKER], "the rosters did not follow a received switch")
		Guild:ApplyRemoteSettings(HOME_BANKER, { shopEnabled = false, version = held + 2 })
		assert.is_true(Guild:IsSisterBankEnabled(), "a broadcast without the field switched it off")
	end)

	it("a sister guild that is fed but NOT listed, or a library without the cross-guild methods, adds nothing", function()
		lib:SetSisterRoster(faction() .. "-Unlisted", { { name = SIS_MEMBER } })
		Guild:RefreshOnlineCache()
		assert.is_nil(Guild.memberRoster[SIS_MEMBER])
		assert.is_false(Guild:IsInCurrentGuildRoster(SIS_MEMBER))
		-- An older library: the home path alone, every predicate answering for the home guild.
		lib.GetSisterGuildKeys, lib.IsInAnyRoster = nil, nil
		feedSister({ [SIS_BANKER] = "gbank" })
		Guild:RefreshOnlineCache()
		Guild:RebuildBankerRoster()
		assert.is_nil(Guild.memberRoster[SIS_BANKER])
		assert.same({ HOME_BANKER }, Guild.Info.roster.alts)
		assert.equal("", Guild:GuildTag(HOME_BANKER))
		assert.is_nil(Guild:GuildOf(SIS_BANKER))
	end)
end)

-- ─── Step 4: the federation pull and the whispered answers ───────────────────

local ME = "Homebank-Testrealm"   -- the home guild's banker, the character these examples run on
local sent

--- The real Guild + Chat dispatch + Core envelope with the send captured, the REAL library with
--- a listed sister roster, and only the two "who am I" accessors stubbed (Bank.lua is not loaded).
local function loadWire()
	env.stubOutput()
	require("env.ace").load("AceAddon-3.0", "AceComm-3.0", "AceConsole-3.0",
		"AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
	env.loadDeltaSync()
	env.loadModules({
		"Modules/Constants.lua", "Modules/Switches.lua", "Modules/Item.lua",
		"Modules/Inventory/Record.lua", "Modules/Inventory/Resolve.lua", "Modules/Inventory/Store.lua",
		"Modules/Inventory/Scan.lua", "Modules/Inventory/Wire.lua", "Modules/DeltaComms.lua",
		"Modules/Guild.lua", "Modules/RequestLog.lua", "Modules/Donations.lua", "Modules/PriceList.lua",
		"Modules/Chat.lua",
	})
	local AceAddon = LibStub("AceAddon-3.0")
	if AceAddon and AceAddon.addons then
		AceAddon.addons["TOGBankClassic"] = nil
		if AceAddon.addonstatus then AceAddon.addonstatus["TOGBankClassic"] = nil end
	end
	env.loadFile("Core.lua")
	env.now = 1757000000
	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	TOGBankClassic_Database = { db = { global = { switches = {} }, faction = {} }, RecordDeltaReceived = function() end, RecordNoChangeSent = function() end }
	TOGBankClassic_Options = {
		IsIntegrityCheckDiagnosticsEnabled = function() return false end, IsSyncProgressMuted = function() return true end,
		GetBankEnabled = function() return true end, GetAutoTombstoneDays = function() return 30 end,
		GetMaxRequestPercent = function() return 100 end, GetBankReporting = function() return false end,
		IsOrderFulfillmentSoundEnabled = function() return false end,
	}
	TOGBankClassic_Performance = { RecordOperation = function() end }
	Guild = TOGBankClassic_Guild
	Guild.Info = { name = "Testguild", alts = {}, roster = { alts = {} }, requests = {}, requestsTombstones = {}, settings = { sisterBank = true } }
	Guild.memberRoster, Guild.onlineMembers, Guild.banksCache = {}, {}, nil
	Guild.federationAsked, Guild.federationAnswered, Guild.federationSilent, Guild.federationAnswers = nil, nil, nil, nil
	Guild.GetNormalizedPlayer = function() return ME end
	Guild.GetPlayer = function() return ME end
	TOGBankClassic_Chat.hashBroadcastQueue = {}
	sent = {}
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, body, dist, target, prio, cb, cbArg)
		sent[#sent + 1] = { prefix = prefix, body = body, dist = dist, target = target, prio = prio }
		if cb then cb(cbArg, #tostring(body), #tostring(body), true) end
	end
	_G.LibGuildRosterDB = nil
	lib = env.freshGuildRoster()
	env.readyGuildRoster(lib)
end

--- Every captured message on `prefix`, decoded, oldest first.
local function captured(prefix)
	local out = {}
	for _, msg in ipairs(sent) do
		if msg.prefix == prefix then
			local ok, decoded = TOGBankClassic_Core:DeserializeWithChecksum(msg.body, { sender = ME, prefix = prefix })
			assert.is_true(ok)
			out[#out + 1] = { data = decoded, msg = msg }
		end
	end
	return out
end

local function clearSent()
	for i = #sent, 1, -1 do sent[i] = nil end
end

local function hear(from, payload, dist)
	TOGBankClassic_Chat:OnCommReceived("togbank-hl", TOGBankClassic_Core:SerializeWithChecksum(payload), dist or "WHISPER", from)
end

describe("XGUILD-SYNC-001 step 4: the federation pull on the cycle, and what a federated asker is told", function()
	before_each(function()
		env.reset()
		env.addGuildMember(ME, { note = "gbank", online = true, rankIndex = 1 })
		env.addGuildMember("Regular-Testrealm", { note = "", online = true, rankIndex = 4 })
		loadWire()
	end)

	it("asks one sighted member of each listed sister guild for its hash list by whisper, prefers a TOGBank speaker, and leaves a silent peer alone for an hour", function()
		feedSister(nil, { SIS_MEMBER, SIS_BANKER })
		Guild:RefreshOnlineCache()
		-- Two sighted by the library; SIS_BANKER also spoke TOGBank to us, so it is preferred -- and
		-- XGUILD-PEER-001: proven, it is asked AT ONCE, not on the next cycle.
		Guild:UpdateOnlineMember(SIS_BANKER, true, "addon-message-received")
		local asks = captured("togbank-hl")
		assert.equal(1, #asks, "the member that spoke TOGBank was not asked at once")
		assert.equal("WHISPER", asks[1].msg.dist); assert.matches("^Sisbank", asks[1].msg.target)
		assert.same({ type = "hash-list-request", requester = ME }, asks[1].data)
		-- The cycle straight after leaves that ask pending: no second ask, and no silence mark.
		local asked = Guild:PullFromFederation()
		assert.same({}, asked, "the guild was asked twice")
		assert.is_nil(Guild.federationSilent[SIS_BANKER], "an ask seconds old was judged unanswered")
		assert.equal(1, #captured("togbank-hl"))
		clearSent()
		-- No answer by the next cycle: that peer is silent, the other sighted member is asked.
		env.now = env.now + 600
		asked = Guild:PullFromFederation()
		assert.same({ SIS_MEMBER }, asked, "the silent peer was asked again")
		assert.is_number(Guild.federationSilent[SIS_BANKER])
		-- An answer (its hash-list-reply) lifts the mark; an hour later it may be asked again anyway.
		Guild:NoteFederationAnswer(SIS_MEMBER)
		env.now = env.now + 600
		asked = Guild:PullFromFederation()
		assert.same({ SIS_MEMBER }, asked, "a peer that answered was not asked again")
		Guild:NoteFederationAnswer(SIS_BANKER)
		assert.is_nil(Guild.federationSilent[SIS_BANKER])
		-- Nobody sighted: nothing sent, nothing marked.
		clearSent()
		lib.presence[sisterKey] = {}
		Guild:RefreshOnlineCache()
		env.now = env.now + 600
		assert.same({}, Guild:PullFromFederation())
		assert.equal(0, #captured("togbank-hl"))
	end)

	-- XGUILD-BOUNCE-001: Guild Roster never hears "gone offline" for another guild's member -- its
	-- presence is a sighting stamp that ages out, and its relay re-stamps it -- so the server bouncing
	-- our whisper ("No player named 'X' is currently playing.", Events:CHAT_MSG_SYSTEM ->
	-- UpdateOnlineMember(X, false, "wow-error-not-online"); events_spec covers that wiring) is the one
	-- "not online" this client gets. Found by xguildlive_spec step 8, where the flag it set was read
	-- by nothing for a sister member.
	it("a whisper the server bounced marks a sister member offline for the library's window, moves an ask out to them to the next member at once, and a message from them clears it", function()
		feedSister(nil, { SIS_MEMBER, SIS_BANKER })
		Guild:RefreshOnlineCache()
		-- Proven speaker, asked at once (XGUILD-PEER-001).
		Guild:UpdateOnlineMember(SIS_BANKER, true, "addon-message-received")
		local asks = captured("togbank-hl")
		assert.equal(1, #asks); assert.matches("^Sisbank", asks[1].msg.target)
		assert.is_number(Guild.federationAsked[SIS_BANKER])
		clearSent()
		-- The server bounces it, by the bare name the system line carries.
		Guild:UpdateOnlineMember("Sisbank", false, "wow-error-not-online")
		assert.is_false(Guild:IsPlayerOnline(SIS_BANKER), "the bounced member still reads online")
		assert.is_true(Guild:IsPlayerOnline(SIS_MEMBER), "the bounce reached a member it did not name")
		assert.is_nil(Guild.federationAsked[SIS_BANKER], "the ask to the bounced member is still out")
		assert.is_number(Guild.federationSilent[SIS_BANKER], "the bounced member was not left alone")
		asks = captured("togbank-hl")
		assert.equal(1, #asks, "the guild was not asked through its next member at once")
		assert.matches("^Sismember", asks[1].msg.target)
		assert.is_number(Guild.federationAsked[SIS_MEMBER])
		-- The rebuild agrees (the Bankers tab reads memberRoster), and FederationPeer skips them.
		Guild:RefreshOnlineCache()
		assert.is_false(Guild.memberRoster[SIS_BANKER].isOnline, "the rebuild put the bounced member back online")
		assert.equal(SIS_MEMBER, Guild:FederationPeer(sisterKey))
		-- The library re-stamps them inside the window (its relay does exactly this): still offline.
		lib:MarkOnline(sisterKey, { SIS_BANKER })
		assert.is_false(Guild:IsPlayerOnline(SIS_BANKER), "a re-stamp inside the window put the bounced member back online")
		-- They speak TOGBank to us: this client's own sighting, online at once.
		Guild:UpdateOnlineMember(SIS_BANKER, true, "addon-message-received")
		assert.is_true(Guild:IsPlayerOnline(SIS_BANKER), "a message from the member did not clear the bounce")
		-- Bounced again with no ask out: nothing sent, and after the library's window its answer
		-- stands alone -- the old stamp has aged out, a fresh sighting is online.
		clearSent()
		Guild:UpdateOnlineMember("Sisbank", false, "wow-error-not-online")
		assert.equal(0, #captured("togbank-hl"), "a bounce with no ask out sent something")
		assert.is_false(Guild:IsPlayerOnline(SIS_BANKER))
		env.advance((lib.PRESENCE_TTL or Guild.SISTER_BOUNCE_HOLD) + 1)
		assert.is_false(Guild:IsPlayerOnline(SIS_BANKER), "an aged-out sighting read online")
		lib:MarkOnline(sisterKey, { SIS_BANKER })
		assert.is_true(Guild:IsPlayerOnline(SIS_BANKER), "after the window a fresh sighting did not count")
		assert.is_nil(Guild.sisterBounced[SIS_BANKER], "an expired bounce was kept")
	end)

	-- XGUILD-PEER-001: most of a sister guild runs Guild Roster without TOGBank, or a CurseForge
	-- TOGBank that predates this sync; the old pick took the first sighted member whatever it ran.
	it("never asks a sister member known to run a TOGBank too old to sync, and prefers one known to run a current one over an unknown", function()
		feedSister(nil, { SIS_MEMBER, SIS_BANKER, SIS_VIEW })
		Guild:RefreshOnlineCache()
		local versions = { [SIS_BANKER] = "TOGBankClassic-v1.5.1", [SIS_VIEW] = "TOGBankClassic-v1.6.0" }
		Guild.ObservedAddonVersion = function(_, name, norm) return versions[norm or Guild:NormalizeName(name)] end
		assert.equal(SIS_VIEW, Guild:FederationPeer(sisterKey), "a member known to run a current TOGBank was not preferred")
		versions[SIS_VIEW] = nil
		assert.equal(SIS_MEMBER, Guild:FederationPeer(sisterKey), "with no current one known, an unknown is not asked")
		versions[SIS_MEMBER] = "TOGBankClassic-v1.4.1"
		assert.equal(SIS_VIEW, Guild:FederationPeer(sisterKey))
		versions[SIS_VIEW] = "TOGBankClassic-v1.5.0"
		assert.is_nil(Guild:FederationPeer(sisterKey), "a member on a release this build cannot sync with was asked")
	end)

	it("VersionCheck naming a sister member's current TOGBank asks that guild at once -- once per cycle, never a home guildmate, never an old release", function()
		feedSister(nil, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		local versions = {}
		Guild.ObservedAddonVersion = function(_, name, norm) return versions[norm or Guild:NormalizeName(name)] end
		versions[SIS_MEMBER] = "TOGBankClassic-v1.5.1"
		assert.is_false(Guild:OnFederationPeerProven(SIS_MEMBER), "an old release was asked")
		assert.is_false(Guild:OnFederationPeerProven("Regular-Testrealm"), "a home guildmate was asked as a federation peer")
		assert.is_false(Guild:OnFederationPeerProven(STRANGER))
		assert.equal(0, #captured("togbank-hl"))
		versions[SIS_MEMBER] = "TOGBankClassic-v1.6.0"
		assert.is_true(Guild:OnFederationPeerProven(SIS_MEMBER))
		assert.equal(1, #captured("togbank-hl"))
		assert.is_false(Guild:OnFederationPeerProven(SIS_MEMBER), "the same guild was asked twice inside a cycle")
		-- Its answer inside the cycle keeps it from being hurried again; a cycle on, it may be.
		Guild:NoteFederationAnswer(SIS_MEMBER)
		env.now = env.now + 300
		assert.is_false(Guild:OnFederationPeerProven(SIS_MEMBER))
		env.now = env.now + 400
		assert.is_true(Guild:OnFederationPeerProven(SIS_MEMBER))
	end)

	-- SSYNC-001 (the operator, 2026-09-25: "if i could do /togbank ssync <name> that would be helpful.
	-- it could do a roster lookup so i can be lazy with the realm").
	it("/togbank ssync <name> finds the sister member without its realm, in any case, and asks them now; refuses a stranger, an offline member, an ambiguous name and a closed switch without sending", function()
		feedSister(nil, { SIS_MEMBER, SIS_BANKER })
		Guild:RefreshOnlineCache()
		clearSent()
		local lines = Guild:SisterSyncCommand("sismember")
		local asks = captured("togbank-hl")
		assert.equal(1, #asks, "the named member was not asked")
		assert.equal("WHISPER", asks[1].msg.dist); assert.matches("^Sismember", asks[1].msg.target)
		assert.same({ type = "hash-list-request", requester = ME }, asks[1].data)
		assert.matches("Asked Sismember%-Testrealm", lines[1])
		-- Asked by hand again at once, and with the realm: a troubleshooting ask is not paced.
		Guild.federationSilent[SIS_MEMBER] = env.now
		clearSent()
		Guild:SisterSyncCommand("SISMEMBER-testrealm")
		assert.equal(1, #captured("togbank-hl"), "a hand ask to a member marked silent was withheld")
		assert.is_nil(Guild.federationSilent[SIS_MEMBER])
		-- Refusals send nothing and say why.
		clearSent()
		assert.matches("not a member of a sister guild", Guild:SisterSyncCommand("Nobody")[1])
		assert.matches("not a member of a sister guild", Guild:SisterSyncCommand("Regular")[1], "a home guildmate was treated as a sister member")
		assert.matches("is not online", Guild:SisterSyncCommand("sisview")[1])
		Guild.memberRoster["Sismember-Otherrealm"] = { name = "Sismember-Otherrealm", guildKey = sisterKey }
		assert.matches("more than one character", Guild:SisterSyncCommand("sismember")[1])
		Guild.memberRoster["Sismember-Otherrealm"] = nil
		assert.equal(0, #captured("togbank-hl"), "a refused ssync sent something")
		-- With no name: every listed sister guild is asked now, past the cycle's pending wait.
		Guild:SisterSyncCommand("sismember")
		clearSent()
		lines = Guild:SisterSyncCommand()
		assert.equal(1, #captured("togbank-hl"), "the no-name form did not ask the sister guild")
		assert.matches("^Asked ", lines[1])
		-- The switch off: nothing to sync with, said plainly.
		Guild.Info.settings.sisterBank = false
		clearSent()
		assert.matches("Sister%-guild bank is OFF", Guild:SisterSyncCommand("sismember")[1])
		assert.equal(0, #captured("togbank-hl"))
	end)

	it("a federated non-guildmate's hash-list-request is answered with the hash list AND, by whisper, who runs each bank character (never the officer settings), the donation totals and the price-list version -- once per five minutes; a guildmate gets the hash list alone", function()
		feedSister(nil, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		Guild:RebuildBankerRoster()
		Guild.Info.settings.version = 500
		Guild.Info.settings.maxRequestPercent = 40
		Guild.Info.settings.bankerOwners = { [ME] = "Alice" }
		Guild.Info.settings.bankerOwnerStamps = { [ME] = 450 }
		Guild.Info.settings.priceAuthority = ME
		Guild.Info.priceList = { version = 777, publisher = ME, at = env.now, items = { [2589] = { sell = 5 } } }
		TOGBankClassic_Donations:Credit({ donor = "Giver", kind = "money", copper = 10000 })
		clearSent()
		hear(SIS_MEMBER, { type = "hash-list-request", requester = SIS_MEMBER })
		local types = {}
		for _, m in ipairs(captured("togbank-hl")) do
			assert.equal("WHISPER", m.msg.dist, m.data.type .. " went to the guild, not to the asker")
			assert.matches("^Sismember", m.msg.target)
			types[m.data.type] = m.data
		end
		-- LIBREQ-DS-008: the hash list is a togbank-hl type now (the togbank-hlr prefix went with the
		-- pull path), by whisper like the rest.
		assert.is_table(types["hash-list-reply"], "the hash list was not whispered to the federated asker")
		-- XGUILD-SETTINGS-001 (the operator: "we should NOT be syncing the officer settings between
		-- sister guilds"): the owners alone.
		assert.is_table(types["guild-settings"], "who runs each bank character was not whispered to the federated asker")
		assert.same({ bankerOwners = { [ME] = "Alice" }, bankerOwnerStamps = { [ME] = 450 } }, types["guild-settings"].settings,
			"something other than the owners crossed to the sister guild")
		assert.equal(500, Guild.Info.settings.version)
		assert.is_table(types["donation-points"], "the donation totals were not whispered")
		assert.equal(ME, TOGBankClassic_Donations:WriterCharacter(types["donation-points"].writer))   -- LEDGER-PC-001: Name@machine
		-- This client IS the price authority: the asker gets the LIST itself (its GUILD publish
		-- never reached the sister guild), not a version line it could only ask the authority for.
		assert.is_nil(types["pl-version"], "the authority named its version instead of sending the list")
		local chunks = captured("togbank-pl")
		assert.equal(1, #chunks); assert.equal("WHISPER", chunks[1].msg.dist); assert.matches("^Sismember", chunks[1].msg.target)
		assert.equal(777, chunks[1].data[2]); assert.equal(ME, chunks[1].data[3])
		-- A holder that is NOT the authority names the version and publisher instead.
		clearSent()
		Guild.federationAnswers = nil
		Guild.Info.settings.priceAuthority = "Authority-Testrealm"
		Guild.Info.priceList.publisher = "Authority-Testrealm"
		hear(SIS_MEMBER, { type = "hash-list-request", requester = SIS_MEMBER })
		assert.equal(0, #captured("togbank-pl"))
		local line
		for _, m in ipairs(captured("togbank-hl")) do if m.data.type == "pl-version" then line = m.data end end
		assert.same({ type = "pl-version", version = 777, publisher = "Authority-Testrealm" }, line)
		Guild.Info.settings.priceAuthority = ME
		Guild.Info.priceList.publisher = ME
		--- The hash list alone went out on togbank-hl (one message, that type).
		local function onlyTheHashList(what)
			local hl = captured("togbank-hl")
			assert.equal(1, #hl, what .. ": expected the hash list alone on togbank-hl")
			assert.equal("hash-list-reply", hl[1].data.type, what)
		end
		-- Inside the cooldown: the hash list again, nothing else.
		clearSent()
		hear(SIS_MEMBER, { type = "hash-list-request", requester = SIS_MEMBER })
		onlyTheHashList("inside the cooldown")
		-- A guildmate's ask: the hash list alone, as ever.
		clearSent()
		hear("Regular-Testrealm", { type = "hash-list-request", requester = "Regular-Testrealm" })
		onlyTheHashList("a guildmate's ask")
		-- A stranger's ask: the hash list (as ever -- the reply is sender-agnostic), nothing else.
		clearSent()
		Guild:UpdateOnlineMember(STRANGER, true, "addon-message-received")
		hear(STRANGER, { type = "hash-list-request", requester = STRANGER })
		onlyTheHashList("a stranger's ask")
	end)

	it("a whispered pl-version naming the authority sends the ask to the AUTHORITY; one naming anyone else is nothing", function()
		feedSister(nil, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		Guild.Info.settings.priceAuthority = "Authority-Testrealm"
		Guild:UpdateOnlineMember("Authority-Testrealm", true, "addon-message-received")
		clearSent()
		hear(SIS_MEMBER, { type = "pl-version", version = 900, publisher = "Someone-Testrealm" })
		assert.equal(0, #captured("togbank-plq"))
		hear(SIS_MEMBER, { type = "pl-version", version = 900, publisher = "Authority-Testrealm" })
		local asks = captured("togbank-plq")
		assert.equal(1, #asks)
		assert.matches("^Authority", asks[1].msg.target, "the ask did not go to the authority")
		assert.same({ type = "pl-query", held = 0 }, asks[1].data)
	end)
end)

-- REQ-GATE-001 (Peer Review on self-audit 31294783, F5): a requests query is answered only for a
-- guildmate or, while the Sister-guild bank is on, a sister guild's member -- never a stranger.
describe("REQ-GATE-001: who a requests query is answered for", function()
	before_each(function()
		env.reset()
		env.addGuildMember(ME, { note = "gbank", online = true, rankIndex = 1 })
		env.addGuildMember("Regular-Testrealm", { note = "", online = true, rankIndex = 4 })
		loadWire()
	end)

	it("answers a guildmate and a sister-guild member (switch on); drops a stranger, and the sister member once the switch is off", function()
		feedSister(nil, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		local answered = {}
		Guild.EnqueueRequestsById = function(_, who) answered[#answered + 1] = who end
		local function ask(from)
			local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "requests-by-id", player = "*", ids = { "x" } })
			TOGBankClassic_Chat:OnCommReceived("togbank-r", body, "WHISPER", from)
		end
		ask(STRANGER)
		assert.equal(0, #answered, "a stranger was answered with the guild's requests")
		ask("Regular-Testrealm")
		assert.equal(1, #answered, "a guildmate was refused")
		ask(SIS_MEMBER)
		assert.equal(2, #answered, "a sister-guild member was refused with the switch on")
		Guild.Info.settings.sisterBank = false
		Guild:RefreshOnlineCache()
		ask(SIS_MEMBER)
		assert.equal(2, #answered, "a sister-guild member was answered with the Sister-guild bank off")
	end)
end)

-- ─── Step 5: the request relay ───────────────────────────────────────────────

--- A mutation as another client's `togbank-rm` send would carry it: one requests-log entry
--- authored by `actor`, optionally marked relayed.
local function mutationFrom(actor, entryType, request, relayed)
	return {
		type = "requests-log",
		logEntries = {{
			type = entryType, actor = actor, seq = env.now, ts = env.now,
			id = actor .. ":" .. env.now, requestId = request.id, request = request, relayed = relayed or nil,
		}},
	}
end

local function hearMutation(from, payload, dist)
	TOGBankClassic_Chat:OnCommReceived("togbank-rm", TOGBankClassic_Core:SerializeWithChecksum(payload), dist, from)
end

local function requestFrom(requester, bank, id)
	return { id = id, requester = requester, bank = bank, item = "Linen Cloth", itemID = 2589, quantity = 5,
		fulfilled = 0, status = "open", date = env.now, updatedAt = env.now }
end

describe("XGUILD-SYNC-001 step 5: a request mutation crosses into a sister guild by whisper, and is relayed there once", function()
	before_each(function()
		env.reset()
		env.addGuildMember(ME, { note = "gbank", online = true, rankIndex = 1 })
		env.addGuildMember("Regular-Testrealm", { note = "", online = true, rankIndex = 4 })
		loadWire()
	end)

	it("a request against a SISTER banker goes to the guild AND, the same bytes, by whisper to that banker; offline, to the federation peer of its guild; a home-only request is never whispered", function()
		feedSister({ [SIS_BANKER] = "gbank" }, { SIS_BANKER, SIS_MEMBER })
		Guild:RefreshOnlineCache()
		Guild:RebuildBankerRoster()
		clearSent()
		assert.is_true(Guild:AddRequest({ requester = ME, bank = SIS_BANKER, item = "Linen Cloth", itemID = 2589, quantity = 5 }))
		local sends = captured("togbank-rm")
		assert.equal(2, #sends)
		assert.equal("GUILD", sends[1].msg.dist)
		assert.equal("WHISPER", sends[2].msg.dist); assert.matches("^Sisbank", sends[2].msg.target)
		assert.equal(sends[1].msg.body, sends[2].msg.body, "the whisper is not the same bytes as the broadcast")
		assert.equal("add", sends[2].data.logEntries[1].type)
		assert.is_nil(sends[2].data.logEntries[1].relayed, "a first send was marked as a relay")
		-- The banker offline: the sighted member of its guild carries it.
		clearSent()
		lib.presence[sisterKey] = {}
		lib:MarkOnline(sisterKey, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		Guild:UpdateOnlineMember(SIS_BANKER, false, "test")
		assert.is_true(Guild:AddRequest({ requester = ME, bank = SIS_BANKER, item = "Linen Cloth", itemID = 2589, quantity = 2 }))
		sends = captured("togbank-rm")
		assert.equal(2, #sends)
		assert.equal("WHISPER", sends[2].msg.dist); assert.matches("^Sismember", sends[2].msg.target)
		-- Nobody of that guild sighted: the guild send alone (the far side catches up on its pull).
		clearSent()
		lib.presence[sisterKey] = {}
		Guild:RefreshOnlineCache()
		Guild:UpdateOnlineMember(SIS_MEMBER, false, "test")
		assert.is_true(Guild:AddRequest({ requester = ME, bank = SIS_BANKER, item = "Linen Cloth", itemID = 2589, quantity = 1 }))
		assert.equal(1, #captured("togbank-rm"))
		-- A request whose banker and requester are both guildmates: as it always was.
		clearSent()
		Guild:UpdateOnlineMember("Regular-Testrealm", true, "test")
		assert.is_true(Guild:AddRequest({ requester = ME, bank = "Regular-Testrealm", item = "Linen Cloth", itemID = 2589, quantity = 1 }))
		sends = captured("togbank-rm")
		assert.equal(1, #sends); assert.equal("GUILD", sends[1].msg.dist)
	end)

	it("a banker-side mutation (complete, delete) whispers back to a SISTER requester -- a delete through the record it just removed", function()
		feedSister(nil, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		Guild.Info.requests["r1"] = requestFrom(SIS_MEMBER, ME, "r1")
		Guild.Info.requests["r2"] = requestFrom(SIS_MEMBER, ME, "r2")
		Guild.SenderIsGM = function(_, who) return who == ME end
		clearSent()
		assert.is_true(Guild:CompleteRequest("r1", ME))
		local sends = captured("togbank-rm")
		assert.equal(2, #sends)
		assert.equal("complete", sends[2].data.logEntries[1].type)
		assert.equal("WHISPER", sends[2].msg.dist); assert.matches("^Sismember", sends[2].msg.target)
		clearSent()
		assert.is_true(Guild:DeleteRequest("r2", ME))
		sends = captured("togbank-rm")
		assert.equal(2, #sends, "the delete's whisper needed the record that DeleteRequest had already dropped")
		assert.equal("delete", sends[2].data.logEntries[1].type)
		assert.is_nil(sends[2].data.logEntries[1].relayFor, "the local-only hint reached the wire")
		assert.matches("^Sismember", sends[2].msg.target)
	end)

	it("a WHISPERED mutation from a federated non-guildmate is applied and re-broadcast ONCE on the guild, marked relayed with its author kept; a relayed entry is never whispered on", function()
		feedSister({ [SIS_BANKER] = "gbank" }, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		Guild:RebuildBankerRoster()
		clearSent()
		hearMutation(SIS_MEMBER, mutationFrom(SIS_MEMBER, "add", requestFrom(SIS_MEMBER, ME, "x1")), "WHISPER")
		assert.is_table(Guild.Info.requests["x1"], "the whispered add was not applied")
		local sends = captured("togbank-rm")
		assert.equal(1, #sends, "expected exactly one relay on the guild")
		assert.equal("GUILD", sends[1].msg.dist)
		local entry = sends[1].data.logEntries[1]
		assert.is_true(entry.relayed); assert.equal(SIS_MEMBER, entry.actor); assert.equal("add", entry.type)
		assert.equal("x1", entry.request.id)
		-- The same mutation whispered again (a second courier): already held, nothing applied, nothing relayed.
		clearSent()
		hearMutation(SIS_MEMBER, mutationFrom(SIS_MEMBER, "add", requestFrom(SIS_MEMBER, ME, "x1")), "WHISPER")
		assert.equal(0, #captured("togbank-rm"))
	end)

	it("a GUILD entry marked relayed is the AUTHOR's word: applied under the author's permissions, not the courier's, and never relayed again", function()
		feedSister({ [SIS_BANKER] = "gbank" }, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		Guild:RebuildBankerRoster()
		clearSent()
		-- A guildmate couriers a sister member's request against our banker.
		hearMutation("Regular-Testrealm", mutationFrom(SIS_MEMBER, "add", requestFrom(SIS_MEMBER, ME, "y1"), true), "GUILD")
		assert.is_table(Guild.Info.requests["y1"], "the relayed add was not applied")
		assert.equal(0, #captured("togbank-rm"), "a relayed entry was relayed again")
		-- The sister BANKER's complete, couriered: the author is the request's banker, so it passes.
		Guild.Info.requests["y2"] = requestFrom(ME, SIS_BANKER, "y2")
		local done = requestFrom(ME, SIS_BANKER, "y2"); done.status = "complete"; done.updatedAt = env.now + 5
		hearMutation("Regular-Testrealm", mutationFrom(SIS_BANKER, "complete", done, true), "GUILD")
		assert.equal("complete", Guild.Info.requests["y2"].status)
		-- The same complete couriered in the name of a sister MEMBER who is neither banker nor GM: refused.
		Guild.Info.requests["y3"] = requestFrom(ME, SIS_BANKER, "y3")
		local done3 = requestFrom(ME, SIS_BANKER, "y3"); done3.status = "complete"; done3.updatedAt = env.now + 5
		hearMutation("Regular-Testrealm", mutationFrom(SIS_MEMBER, "complete", done3, true), "GUILD")
		assert.equal("open", Guild.Info.requests["y3"].status, "the courier's relay let a non-banker complete a request")
	end)

	it("refused: a relayed entry naming a HOME author, a relayed entry by whisper, a whisper from a stranger; a guildmate's whisper is its own word, applied and not relayed", function()
		feedSister(nil, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		Guild:UpdateOnlineMember(STRANGER, true, "addon-message-received")
		clearSent()
		-- A guildmate can speak for itself on GUILD: an entry "relayed" in its name is a forgery.
		hearMutation("Regular-Testrealm", mutationFrom(ME, "add", requestFrom(ME, "Regular-Testrealm", "z1"), true), "GUILD")
		assert.is_nil(Guild.Info.requests["z1"])
		-- Relayed entries travel on GUILD only.
		hearMutation(SIS_MEMBER, mutationFrom(SIS_MEMBER, "add", requestFrom(SIS_MEMBER, ME, "z2"), true), "WHISPER")
		assert.is_nil(Guild.Info.requests["z2"])
		-- A guildmate's whisper is its own word (it could have said it on GUILD): applied, not relayed.
		hearMutation("Regular-Testrealm", mutationFrom("Regular-Testrealm", "add", requestFrom("Regular-Testrealm", ME, "z3")), "WHISPER")
		assert.is_table(Guild.Info.requests["z3"])
		assert.equal(0, #captured("togbank-rm"), "a guildmate's whisper was relayed")
		-- A stranger has no standing on any transport -- and the STUB its message created (an
		-- unauthenticated sighting) does not make it one of us, on either predicate.
		hearMutation(STRANGER, mutationFrom(STRANGER, "add", requestFrom(STRANGER, ME, "z4")), "WHISPER")
		assert.is_nil(Guild.Info.requests["z4"])
		assert.is_true(Guild.memberRoster[STRANGER].isStub)
		assert.is_false(Guild:IsFederated(STRANGER)); assert.is_false(Guild:IsHomeMember(STRANGER))
		assert.equal(0, #captured("togbank-rm"), "a refused entry was relayed")
		-- And the plain GUILD path is exactly as it was: a guildmate's own add applies, no relay.
		hearMutation("Regular-Testrealm", mutationFrom("Regular-Testrealm", "add", requestFrom("Regular-Testrealm", ME, "z5")), "GUILD")
		assert.is_table(Guild.Info.requests["z5"])
		assert.equal(0, #captured("togbank-rm"))
	end)

	it("the federation pull also asks the peer for its REQUESTS INDEX by whisper, 70 s after the hash-list ask so the guild's own index query keeps its turn", function()
		feedSister(nil, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		clearSent()
		assert.same({ SIS_MEMBER }, Guild:PullFromFederation())
		assert.equal(0, #captured("togbank-r"), "the index ask went out with the hash-list ask")
		env.advance(69)
		assert.equal(0, #captured("togbank-r"))
		env.advance(1)
		local asks = captured("togbank-r")
		assert.equal(1, #asks)
		assert.equal("WHISPER", asks[1].msg.dist); assert.matches("^Sismember", asks[1].msg.target)
		assert.equal("requests-index", asks[1].data.type)
		assert.equal(SIS_MEMBER, Guild.requestsIndexSync.inFlight)
		-- The peer's index answer names one request we lack: it is fetched by-id from the peer, by whisper.
		clearSent()
		TOGBankClassic_Chat:OnCommReceived("togbank-rd", TOGBankClassic_Core:SerializeWithChecksum({
			type = "requests-index", requests = { { id = "far1", updatedAt = env.now } }, tombstones = {},
		}), "WHISPER", SIS_MEMBER)
		env.advance(5)
		local fetches = captured("togbank-r")
		assert.equal(1, #fetches)
		assert.equal("requests-by-id", fetches[1].data.type); assert.same({ "far1" }, fetches[1].data.ids)
		assert.matches("^Sismember", fetches[1].msg.target)
	end)
end)

describe("XGUILD-OWNERS-001: who runs each bank character crosses between sister guilds, entry by entry", function()
	local broadcasts
	before_each(function()
		env.reset()
		env.addGuildMember(HOME_BANKER, { note = "gbank", online = true, rankIndex = 1 })
		env.addGuildMember("Homeother-Testrealm", { note = "gbank", online = true, rankIndex = 1 })
		loadGuild()
		_G.LibGuildRosterDB = nil
		lib = env.freshGuildRoster()
		env.readyGuildRoster(lib)
		feedSister({ [SIS_BANKER] = "gbank", [SIS_VIEW] = "gbank" }, { SIS_BANKER })
		Guild:RefreshOnlineCache()
		Guild:RebuildBankerRoster()
		broadcasts = 0
		Guild.BroadcastSettings = function() broadcasts = broadcasts + 1 end
	end)

	--- A guild-settings payload as a sender on the new build builds it: owners with their stamps.
	local function payload(owners, stamps)
		return { version = 5000, bankerOwners = owners, bankerOwnerStamps = stamps, stamps = { bankerOwners = 5000 } }
	end

	it("an officer names the owner of a HOME bank character with its own stamp, and cannot for a sister guild's", function()
		assert.is_true(Guild:SetBankerOwner(HOME_BANKER, "Alice"))
		assert.equal("Alice", Guild:GetBankerOwner(HOME_BANKER))
		assert.is_number(Guild.Info.settings.bankerOwnerStamps[HOME_BANKER], "the entry was not stamped")
		assert.equal(1, broadcasts)
		local first = Guild.Info.settings.bankerOwnerStamps[HOME_BANKER]
		assert.is_true(Guild:SetBankerOwner(HOME_BANKER, "Bob"))
		assert.is_true(Guild.Info.settings.bankerOwnerStamps[HOME_BANKER] > first, "a second write in the same second did not move the stamp")
		assert.is_false(Guild:BankerOwnerWritable(SIS_BANKER))
		assert.is_false(Guild:SetBankerOwner(SIS_BANKER, "Mallory"), "a home officer described a sister guild's bank character")
		assert.is_nil(Guild:GetBankerOwner(SIS_BANKER))
		assert.equal(2, broadcasts)
		-- The stamps ride the payload; the canon does not count them.
		local fields = Guild:SettingsFields()
		assert.equal(Guild.Info.settings.bankerOwnerStamps[HOME_BANKER], fields.bankerOwnerStamps[HOME_BANKER])
		local canon = Guild:SettingsCanon()
		Guild.Info.settings.bankerOwnerStamps[HOME_BANKER] = 1
		assert.equal(canon, Guild:SettingsCanon(), "the owner stamps changed the settings canon")
	end)

	it("a sister banker's settings ADD its guild's owners to ours, keep ours, and cannot rewrite a home bank character's", function()
		Guild.Info.settings.bankerOwners = { [HOME_BANKER] = "Alice" }
		Guild.Info.settings.bankerOwnerStamps = { [HOME_BANKER] = 100 }
		Guild:ApplyRemoteSettings(SIS_BANKER, payload(
			{ [SIS_BANKER] = "Sally", [HOME_BANKER] = "Forged" },
			{ [SIS_BANKER] = 200, [HOME_BANKER] = 999 }))
		assert.equal("Sally", Guild:GetBankerOwner(SIS_BANKER), "the sister guild's owner did not arrive")
		assert.equal("Alice", Guild:GetBankerOwner(HOME_BANKER), "a sister guild rewrote who runs a home bank character")
		assert.equal(100, Guild.Info.settings.bankerOwnerStamps[HOME_BANKER])
		assert.equal(200, Guild.Info.settings.bankerOwnerStamps[SIS_BANKER])
	end)

	it("the sister guild's newer clear removes its entry; an older copy never brings it back; a home guildmate relays it on", function()
		Guild.Info.settings.bankerOwners = { [SIS_BANKER] = "Sally", [HOME_BANKER] = "Alice" }
		Guild.Info.settings.bankerOwnerStamps = { [SIS_BANKER] = 200, [HOME_BANKER] = 100 }
		-- Cleared over there at 300: absent from the owners, stamped.
		Guild:ApplyRemoteSettings(SIS_BANKER, payload({}, { [SIS_BANKER] = 300 }))
		assert.is_nil(Guild:GetBankerOwner(SIS_BANKER), "the sister guild's clear did not land")
		assert.equal("Alice", Guild:GetBankerOwner(HOME_BANKER), "a payload without our entry cleared it")
		-- A copy from before the clear, relayed by anyone, does not resurrect it.
		Guild:ApplyRemoteSettings("Homeother-Testrealm", payload({ [SIS_BANKER] = "Sally" }, { [SIS_BANKER] = 200 }))
		assert.is_nil(Guild:GetBankerOwner(SIS_BANKER), "an older copy resurrected a cleared owner")
		-- A home guildmate's broadcast carrying a NEWER sister entry (it heard the sister guild first) is taken.
		Guild:ApplyRemoteSettings("Homeother-Testrealm", payload({ [SIS_BANKER] = "Sam" }, { [SIS_BANKER] = 400 }))
		assert.equal("Sam", Guild:GetBankerOwner(SIS_BANKER), "a home guildmate's relay of the sister guild's owner was refused")
	end)

	it("an entry from a sister member for a bank character in NO roster, or in another guild, is refused", function()
		Guild:ApplyRemoteSettings(SIS_BANKER, payload({ [STRANGER] = "X", ["Homeother-Testrealm"] = "Y" },
			{ [STRANGER] = 50, ["Homeother-Testrealm"] = 50 }))
		assert.is_nil(Guild:GetBankerOwner(STRANGER))
		assert.is_nil(Guild:GetBankerOwner("Homeother-Testrealm"))
	end)

	-- Self-audit 2026-09-16: the merge must move the FIELD's stamp too, or an older client's
	-- whole-table re-announcement stamped in between replaces the merged table.
	it("a merged payload moves the owners field's stamp, so an OLDER pre-stamp re-announcement cannot wipe the merged table", function()
		Guild.Info.settings.bankerOwners = { [HOME_BANKER] = "Alice" }
		Guild.Info.settings.bankerOwnerStamps = { [HOME_BANKER] = 100 }
		Guild.Info.settings.stamps = { bankerOwners = 100 }
		Guild:ApplyRemoteSettings(SIS_BANKER, { version = 5000, bankerOwners = { [SIS_BANKER] = "Sally" },
			bankerOwnerStamps = { [SIS_BANKER] = 5000 }, stamps = { bankerOwners = 5000 } })
		assert.equal("Sally", Guild:GetBankerOwner(SIS_BANKER))
		assert.equal(5000, Guild:SettingsStamp("bankerOwners"), "the merge left the field's stamp behind")
		-- A v1.5.1 officer's re-announcement, stamped after our old write but before the merge.
		Guild:ApplyRemoteSettings("Homeother-Testrealm", { version = 4000, bankerOwners = { [HOME_BANKER] = "Old" },
			stamps = { bankerOwners = 4000 } })
		assert.equal("Sally", Guild:GetBankerOwner(SIS_BANKER), "an older whole-table payload wiped the sister guild's owner")
		assert.equal("Alice", Guild:GetBankerOwner(HOME_BANKER))
	end)

	-- OWNERS-STAMP-001 (Peer Review, inbox 31294783): the home path and the sister branch moved the
	-- field's stamp by two separate computations -- the home one read the field stamp only. One
	-- method now; both routes take the newest ENTRY stamp too, and neither moves it backwards.
	it("the home and sister routes move the owners field's stamp the same way: to the newest entry stamp, never back", function()
		Guild.Info.settings.stamps = { bankerOwners = 100 }
		-- A home guildmate's payload whose entry is newer than its own field stamp.
		Guild:ApplyRemoteSettings("Homeother-Testrealm", { version = 150, bankerOwners = { [HOME_BANKER] = "Alice" },
			bankerOwnerStamps = { [HOME_BANKER] = 700 }, stamps = { bankerOwners = 150 } })
		assert.equal(700, Guild:SettingsStamp("bankerOwners"), "the home route ignored the entry stamp")
		-- The sister route, the same shape.
		Guild:ApplyRemoteSettings(SIS_BANKER, { version = 150, bankerOwners = { [SIS_BANKER] = "Sally" },
			bankerOwnerStamps = { [SIS_BANKER] = 900 }, stamps = { bankerOwners = 150 } })
		assert.equal(900, Guild:SettingsStamp("bankerOwners"), "the sister route ignored the entry stamp")
		-- Older stamps on either route leave it where it is.
		Guild:ApplyRemoteSettings("Homeother-Testrealm", { version = 150, bankerOwners = { [HOME_BANKER] = "Bob" },
			bankerOwnerStamps = { [HOME_BANKER] = 200 }, stamps = { bankerOwners = 200 } })
		Guild:ApplyRemoteSettings(SIS_BANKER, { version = 150, bankerOwners = { [SIS_BANKER] = "Sam" },
			bankerOwnerStamps = { [SIS_BANKER] = 300 }, stamps = { bankerOwners = 300 } })
		assert.equal(900, Guild:SettingsStamp("bankerOwners"), "an older payload moved the stamp backwards")
		assert.equal("Alice", Guild:GetBankerOwner(HOME_BANKER))
		assert.equal("Sally", Guild:GetBankerOwner(SIS_BANKER))
	end)

	-- XGUILD-SETTINGS-001 (the operator, 2026-09-25: "the banker metadata isn't syncing though").
	it("a sister guild's payload changes NOTHING of our officer settings -- even from its bank character, even newer-stamped -- only its own bank characters' owners", function()
		Guild.Info.settings.version = 100
		Guild.Info.settings.maxRequestPercent = 40
		Guild.Info.settings.storeOpen = true
		Guild.Info.settings.sisterBank = true
		Guild.Info.settings.officerRankFloor = 2
		Guild.Info.settings.stamps = { maxRequestPercent = 100, storeOpen = 100, sisterBank = 100, officerRankFloor = 100 }
		Guild:ApplyRemoteSettings(SIS_BANKER, { version = 9000, maxRequestPercent = 5, storeOpen = false, sisterBank = false, officerRankFloor = 0,
			bankerOwners = { [SIS_BANKER] = "Sally" }, bankerOwnerStamps = { [SIS_BANKER] = 9000 },
			stamps = { maxRequestPercent = 9000, storeOpen = 9000, sisterBank = 9000, officerRankFloor = 9000, bankerOwners = 9000 } })
		assert.equal(40, Guild.Info.settings.maxRequestPercent, "the sister guild's request limit became ours")
		assert.is_true(Guild.Info.settings.storeOpen, "the sister guild closed our shop")
		assert.is_true(Guild:IsSisterBankEnabled(), "the sister guild switched our sister-guild bank off")
		assert.equal(2, Guild.Info.settings.officerRankFloor, "the sister guild's rank floor became ours")
		assert.equal(100, Guild:SettingsVersion(), "the sister guild's version became ours")
		assert.equal("Sally", Guild:GetBankerOwner(SIS_BANKER), "its own bank character's owner did not arrive")
	end)

	it("the owners arrive from a PLAIN sister-guild member (the one usually asked), held to that guild's bank characters", function()
		Guild:ApplyRemoteSettings(SIS_MEMBER, { bankerOwners = { [SIS_BANKER] = "Sally", [HOME_BANKER] = "Forged" },
			bankerOwnerStamps = { [SIS_BANKER] = 200, [HOME_BANKER] = 999 } })
		assert.equal("Sally", Guild:GetBankerOwner(SIS_BANKER), "a plain sister member's owners were refused")
		assert.is_nil(Guild:GetBankerOwner(HOME_BANKER), "a sister member described a home bank character")
		-- And the sending side: any client answers with the owners alone.
		local sentTo, body
		TOGBankClassic_Core = TOGBankClassic_Core or {}
		local savedSW, savedSer = TOGBankClassic_Core.SendWhisper, TOGBankClassic_Core.SerializeWithChecksum
		TOGBankClassic_Core.SerializeWithChecksum = function(_, t) return t end
		TOGBankClassic_Core.SendWhisper = function(_, _, data, target) sentTo, body = target, data return true end
		-- A home bank character's owner goes; the receiver's OWN guild's entry does not (Peer Review F4).
		Guild.Info.settings.bankerOwners[HOME_BANKER] = "Alice"
		Guild.Info.settings.bankerOwnerStamps[HOME_BANKER] = 150
		assert.is_true(Guild:SendBankerOwnersTo(SIS_MEMBER))
		TOGBankClassic_Core.SendWhisper, TOGBankClassic_Core.SerializeWithChecksum = savedSW, savedSer
		assert.equal(SIS_MEMBER, sentTo)
		assert.same({ type = "guild-settings", settings = { bankerOwners = { [HOME_BANKER] = "Alice" }, bankerOwnerStamps = { [HOME_BANKER] = 150 } } }, body,
			"the sister guild was sent its own bank character's owner, or not ours")
	end)

	it("a sender from before the per-entry stamps is adopted whole on the field's stamp, as it always was", function()
		Guild.Info.settings.bankerOwners = { [HOME_BANKER] = "Alice" }
		Guild:ApplyRemoteSettings("Homeother-Testrealm", { version = 6000, bankerOwners = { ["Homeother-Testrealm"] = "Zed" } })
		assert.equal("Zed", Guild:GetBankerOwner("Homeother-Testrealm"))
		assert.is_nil(Guild:GetBankerOwner(HOME_BANKER), "the pre-stamp payload stopped replacing the table")
	end)
end)

describe("XGUILD-LABEL-001: every banker listing names a sister guild's banker's guild", function()
	before_each(function()
		env.reset()
		env.addGuildMember(HOME_BANKER, { note = "gbank", online = true, rankIndex = 1 })
		loadGuild()
		-- The library's SavedVariables global outlives env.reset: a sister guild listed by one
		-- example would still be listed (and its roster re-fed) in the next.
		_G.LibGuildRosterDB = nil
		lib = env.freshGuildRoster()
		env.readyGuildRoster(lib)
		feedSister({ [SIS_BANKER] = "gbank" }, { SIS_BANKER })
		Guild:RefreshOnlineCache()
		Guild:RebuildBankerRoster()
	end)

	it("the Requests tab's Bank column, the request dialog's prompt and the item tooltip's banker lines carry the tag; a home banker none", function()
		local tag = Guild:GuildTag(SIS_BANKER)
		assert.matches("Sister Guild", tag)
		-- The Requests tab's row builder, read through its own source: the Bank column appends
		-- Guild:GuildTag(bank) after the coloured name.
		local src = env.readFile("Modules/UI/Requests.lua")
		assert.is_truthy(src:find("bank      = colorize(bank, reqStatus) .. bankTag", 1, true), "the Requests Bank column does not carry the guild tag")
		assert.is_truthy(src:find("G:GuildTag(bank)", 1, true))
		-- The request dialog's prompt names the banker with its guild.
		local search = env.readFile("Modules/UI/Search.lua")
		assert.is_truthy(search:find('"Request how many %s from %s?", itemLabel, bankLabel', 1, true), "the dialog prompt does not use the tagged banker label")
		assert.is_truthy(search:find("G:GuildTag(bankAlt)", 1, true))
		-- The item tooltip's banker lines.
		local tip = env.readFile("Modules/TooltipBankerInfo.lua")
		assert.is_truthy(tip:find("name = shortName .. tag", 1, true), "the tooltip's banker line does not carry the guild tag")
		-- The Browse rows: both the Bankers tab's name and the Banker column, driven for real.
		local browse = env.readFile("Modules/UI/Browse.lua")
		assert.is_truthy(browse:find("bank  = player .. (G.GuildTag and G:GuildTag(norm) or \"\")", 1, true))
		assert.is_truthy(browse:find("name = player .. (G.GuildTag and G:GuildTag(norm) or \"\")", 1, true))
		assert.is_truthy(browse:find('"Bank character of " .. entry.guildName', 1, true), "the Bankers row hover does not name the guild")
	end)
end)

-- ─── Step 7: the GreenWall nudge (XGUILD_SYNC.md 4.6) ────────────────────────
--
-- One short line on GreenWall's bridge from the Guild Bank window's open (a click); a federated client
-- hearing it treats it as a TOGBank message from the sender and asks that guild at once. GreenWall
-- itself needs a joined custom channel and a configured confederation, neither of which the harness
-- models, so the SEAM is its API's three functions -- their signatures read from the installed
-- GreenWall (../GreenWall/API.lua) and pinned by the last example.
describe("XGUILD-SYNC-001 step 7: the GreenWall nudge -- one line from a click, and a sighting on hearing one", function()
	local api

	--- A stand-in for GreenWall's transport API: the calls TOGBank makes and the channel query it gates
	--- on, plus `hear`, which does what GreenWall's dispatcher does with a line heard on the channel
	--- (gw.APIDispatcher: every handler registered for that addon, or for '*').
	local function fakeGreenWall(channels)
		api = { sent = {}, handlers = {}, channels = channels or { 7 } }
		function api.SendMessage(addon, message) api.sent[#api.sent + 1] = { addon = addon, message = message } end
		function api.AddMessageHandler(fn, addon, priority)
			api.handlers[#api.handlers + 1] = { fn = fn, addon = addon, priority = priority }
			return "id" .. #api.handlers
		end
		function api.GetChannelNumbers() return api.channels end
		function api.hear(addon, sender, message, echo, isOwnGuild)
			local acted = false
			for _, h in ipairs(api.handlers) do
				if h.addon == addon or h.addon == "*" then acted = h.fn(addon, sender, message, echo, isOwnGuild) or acted end
			end
			return acted
		end
		_G.GreenWallAPI = api
		return api
	end

	before_each(function()
		env.reset()
		env.addGuildMember(ME, { note = "gbank", online = true, rankIndex = 1 })
		env.addGuildMember("Regular-Testrealm", { note = "", online = true, rankIndex = 4 })
		loadWire()
		env.loadFile("Modules/GreenWall.lua")
		TOGBankClassic_GreenWall.lastNudge, TOGBankClassic_GreenWall.handlerId = nil, nil
		fakeGreenWall()
	end)
	after_each(function() _G.GreenWallAPI = nil end)

	it("the window's open sends one short line carrying this client's version -- once per cycle, only with the sister bank on and GreenWall's channel joined", function()
		feedSister(nil, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		local GW = TOGBankClassic_GreenWall
		assert.is_true(GW:Nudge())
		assert.equal(1, #api.sent)
		assert.equal("TOGBankClassic", api.sent[1].addon, "GreenWall validates the sender against its TOC name")
		assert.equal("hlq:" .. (GetAddOnMetadata("TOGBankClassic", "Version") or ""), api.sent[1].message)
		assert.is_true(#api.sent[1].message < 100, "the line must fit GreenWall's 255-byte segment with its framing")
		-- Within the cycle: nothing more. A cycle on: one more.
		assert.same({ false, "cooldown" }, { GW:Nudge() })
		assert.equal(1, #api.sent)
		env.now = env.now + GW.NUDGE_COOLDOWN
		assert.is_true(GW:Nudge()); assert.equal(2, #api.sent)
		-- The channel not joined (number 0: GreenWall would PARK the segment for a later, non-hardware
		-- flush), no channel, GreenWall absent, the sister bank off: refused, nothing sent.
		GW.lastNudge = nil
		api.channels = { 0 }
		assert.same({ false, "no bridge" }, { GW:Nudge() })
		api.channels = {}
		assert.same({ false, "no bridge" }, { GW:Nudge() })
		_G.GreenWallAPI = nil
		assert.same({ false, "no bridge" }, { GW:Nudge() })
		_G.GreenWallAPI = api; api.channels = { 7 }
		Guild.Info.settings.sisterBank = false
		assert.same({ false, "no sister guilds" }, { GW:Nudge() })
		assert.equal(2, #api.sent)
	end)

	-- Peer Review 8e933d44: an officer-only confederation reaches SendMessage and ALWAYS fails there
	-- (GreenWall indexes a nil `gw.config.channel.guild`), so without a stamp on the refusal it would
	-- pay a failed call and a debug line on every single window open, forever. Stamping bounds it to
	-- once per cycle -- but ONLY on this path: a refusal BEFORE the send must not make a client whose
	-- GreenWall finished loading a moment later wait a whole cycle for its first nudge.
	it("a refusal FROM GreenWall starts the cooldown, and a refusal before the send does not", function()
		feedSister(nil, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		local GW = TOGBankClassic_GreenWall
		api.SendMessage = function() error("no guild channel") end
		assert.same({ false, "refused" }, { GW:Nudge() })
		assert.is_number(GW.lastNudge, "a refusal from GreenWall left the cooldown unstamped -- it will retry on every open")
		assert.same({ false, "cooldown" }, { GW:Nudge() }, "the second open called SendMessage again")
		-- A cycle on it tries once more, and succeeds when GreenWall has come good.
		env.now = env.now + GW.NUDGE_COOLDOWN
		api.SendMessage = function(addon, message) api.sent[#api.sent + 1] = { addon = addon, message = message } end
		assert.is_true(GW:Nudge())
		assert.equal(1, #api.sent)
		-- A refusal that never reached GreenWall leaves the cooldown alone.
		GW.lastNudge = nil
		_G.GreenWallAPI = nil
		assert.same({ false, "no bridge" }, { GW:Nudge() })
		assert.is_nil(GW.lastNudge, "a refusal before the send started the cooldown, delaying the first real nudge by a cycle")
		_G.GreenWallAPI = api
		Guild.Info.settings.sisterBank = false
		assert.same({ false, "no sister guilds" }, { GW:Nudge() })
		assert.is_nil(GW.lastNudge)
	end)

	it("a nudge heard from a listed sister member is a TOGBank sighting: their version is noted, they read online, their guild is asked at once; echo, a home guildmate, a stranger, another addon's line and a plain line are not", function()
		feedSister(nil, { SIS_MEMBER })
		Guild:RefreshOnlineCache()
		local GW = TOGBankClassic_GreenWall
		assert.is_true(GW:Init())
		assert.equal(1, #api.handlers); assert.equal("TOGBankClassic", api.handlers[1].addon)
		assert.is_true(GW:Init()); assert.equal(1, #api.handlers, "a second Init registered a second handler")
		local current = "TOGBankClassic-v" .. TOGBankClassic_Constants.PROTOCOL.DATA_LEG_MIN_ADDON_VERSION
		-- SIS_VIEW has never been sighted by the library: the nudge IS the sighting.
		assert.is_false(Guild:IsPlayerOnline(SIS_VIEW))
		assert.is_true(api.hear("TOGBankClassic", SIS_VIEW, "hlq:" .. current, false, false))
		assert.equal(current, Guild.peerAddonVersions[SIS_VIEW], "the version on the line was not noted")
		assert.is_true(Guild:IsPlayerOnline(SIS_VIEW), "the nudge did not count as a sighting")
		local asks = captured("togbank-hl")
		assert.equal(1, #asks, "the nudging member's guild was not asked at once")
		assert.equal("WHISPER", asks[1].msg.dist); assert.matches("^Sisview", asks[1].msg.target)
		assert.same({ type = "hash-list-request", requester = ME }, asks[1].data)
		clearSent()
		-- Ignored: our own echo; a home guildmate (its guild has its own cycle), whether GreenWall calls
		-- it our guild or not; a stranger GreenWall's confederation carries but Guild Roster does not
		-- list; another addon's line; a line that is not a nudge. Nothing sent, nothing stamped.
		assert.is_false(api.hear("TOGBankClassic", ME, "hlq:" .. current, true, true))
		assert.is_false(api.hear("TOGBankClassic", "Regular-Testrealm", "hlq:" .. current, false, true))
		assert.is_false(api.hear("TOGBankClassic", "Regular-Testrealm", "hlq:" .. current, false, false))
		assert.is_false(api.hear("TOGBankClassic", STRANGER, "hlq:" .. current, false, false))
		assert.is_false(GW:OnMessage("OtherAddon", SIS_MEMBER, "hlq:" .. current, false, false))
		assert.is_false(api.hear("TOGBankClassic", SIS_MEMBER, "hello", false, false))
		assert.equal(0, #captured("togbank-hl"))
		assert.is_false(Guild:IsPlayerOnline(STRANGER)); assert.is_nil(Guild.peerAddonVersions[STRANGER])
		assert.is_nil(Guild.peerAddonVersions[SIS_MEMBER])
	end)

	it("the send rides the window's Toggle alone (a click), never Open, and the installed GreenWall's API is the one this module calls", function()
		local browse = env.readFile("Modules/UI/Browse.lua")
		local toggle = browse:match("\nfunction Browse:Toggle%(%)(.-)\nend")
		assert.is_string(toggle)
		assert.is_truthy(toggle:find("TOGBankClassic_GreenWall:Nudge()", 1, true), "Toggle does not nudge")
		local open = browse:match("\nfunction Browse:Open%(tab%)(.-)\nend")
		assert.is_string(open)
		assert.is_falsy(open:find("Nudge", 1, true), "Open() nudges -- Events and Requests reach it from handlers that are not hardware events")
		assert.is_truthy(env.readFile("Core.lua"):find("TOGBankClassic_GreenWall:Init()", 1, true), "Core never registers the handler")
		local fh = io.open("../GreenWall/API.lua", "r")
		assert.is_truthy(fh, "the installed GreenWall is not beside this addon; its API cannot be checked")
		local gw = fh:read("*a"); fh:close()
		assert.is_truthy(gw:find("function GreenWallAPI.SendMessage(addon, message)", 1, true))
		assert.is_truthy(gw:find("function GreenWallAPI.AddMessageHandler(handler, addon, priority)", 1, true))
		assert.is_truthy(gw:find("function GreenWallAPI.GetChannelNumbers()", 1, true))
		assert.is_truthy(gw:find("e[4](addon, sender, message, echo, guild)", 1, true), "GreenWall's handler signature moved")
	end)
end)
