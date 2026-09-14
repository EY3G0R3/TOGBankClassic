-- RAID-VISIBILITY-001: a raid group pauses sync, and the player is TOLD.
--
-- While IsInRaid() the addon suppresses every send (Core:SendCommMessage) and ignores every
-- receive (Chat:OnCommReceived) -- the chat channel is throttled and raid addons need it. The
-- guard is right and was invisible: the collect and dispatch timers kept printing "no offers" as
-- if the guild were quiet, and the operator spent an afternoon on 2026-09-12 believing sync was
-- broken ("i was in a raid, do you stop syncs while in a raid?" -- "i wasn't aware"). Two
-- visibilities, pinned here: ONE plain-chat line per raid stint from the first suppressed send,
-- and a grey status-bar line in the centre slot for as long as the raid lasts. Not a setting.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local PEER   = "Otherguy-Testrealm"
local GUILD  = "Testguild"
local C      = env.canon
local T      = env.EPOCH

local Core, P, SB
-- What reached the transport. AceComm hands every send to `ChatThrottleLib:SendAddonMessage`,
-- looked up at call time, so this is the first layer PAST the raid guard that can be observed
-- without the real throttle: env_togbank's clock is rewound to EPOCH on every reset, which drives
-- ChatThrottleLib's bandwidth gauge negative and queues everything for good (harness README,
-- "wow.reset() no longer rewinds GetTime()" -- this env still does; its migration is its own item).
local wire, ctlSend

local function client()
	env.standUpClient("Bankchar", { { name = BANKER, note = "gbank" }, { name = PEER } }, GUILD)
	env.loadFile("Modules/UI/StatusBar.lua")
	Core, P, SB = TOGBankClassic_Core, TOGBankClassic_Propagation, TOGBankClassic_UI_StatusBar
	P:Reset()
	-- standUpClient stubs Output; record what the player is TOLD in plain chat.
	TOGBankClassic_Output.Info = function(_, fmt, ...) env.printed[#env.printed + 1] = string.format(fmt, ...) end
	wire = {}
	ctlSend = _G.ChatThrottleLib.SendAddonMessage
	_G.ChatThrottleLib.SendAddonMessage = function(_, _, prefix, text, dist, _, _, cb, cbArg)
		wire[#wire + 1] = { prefix = prefix, text = text, dist = dist }
		-- CTL's contract to AceComm: the callback fires with the byte count once the chunk is out.
		if cb then cb(cbArg, true) end
	end
end

local function raidNotices()
	local n = 0
	for _, m in ipairs(env.printed) do
		if m:find("paused while you are in a raid group", 1, true) then n = n + 1 end
	end
	return n
end

--- One send through the real chain (AceCommQueue wrapper -> Core's raid guard -> AceComm -> CTL).
--- Returns what the queue's completion callback was handed, or nil if it never fired.
--- A prefix of its own: AceCommQueue keys its in-flight state by prefix+distribution and that
--- state outlives a spec file, so a send on `togbank-hl` here queues behind whatever an earlier
--- file left in flight (green alone, red in the whole suite, measured 2026-09-12).
local PREFIX = "togbank-rp"
local function send()
	local got
	Core:SendCommMessage(PREFIX, "payload", "GUILD", nil, "NORMAL",
		function(arg, sent, total) got = { arg = arg, sent = sent, total = total } end, "tag")
	return got
end

describe("RAID-VISIBILITY-001: the raid guard says so", function()
	before_each(function() env.reset(); client() end)
	after_each(function() _G.ChatThrottleLib.SendAddonMessage = ctlSend end)

	it("suppresses the send, unblocks the queue's callback, and says it ONCE per raid stint", function()
		env.setInRaid(true)
		local got = send()
		assert.equal(0, #wire, "a send reached the transport from inside a raid")
		-- The queue is waiting on this callback; 0 of 0 is its last-chunk signal. Without it the
		-- NEXT send on this prefix would sit behind a phantom in-flight message forever.
		assert.same({ arg = "tag", sent = 0, total = 0 }, got)
		assert.equal(1, raidNotices())
		assert.is_truthy(env.printed[1]:find("resumes when you leave", 1, true), env.printed[1])
		send(); send()
		assert.equal(0, #wire)
		assert.equal(1, raidNotices(), "the notice repeated inside one raid stint")
	end)

	it("says it again for the NEXT raid: the first send after leaving resets the notice", function()
		env.setInRaid(true)
		send()
		assert.equal(1, raidNotices())
		env.setInRaid(false)
		local got = send()
		assert.equal(1, #wire, "the first send after leaving the raid did not reach the transport")
		assert.equal(PREFIX, wire[1].prefix)
		assert.is_truthy(got and got.sent and got.sent > 0, "the real send's completion callback did not fire")
		assert.equal(1, raidNotices(), "leaving the raid printed something")
		env.setInRaid(true)
		send()
		assert.equal(1, #wire)
		assert.equal(2, raidNotices(), "a second raid stint was not announced")
	end)

	it("never prints outside a raid, however many sends", function()
		send(); send()
		assert.equal(2, #wire)
		assert.equal(0, raidNotices())
	end)

	-- RAID-SYNC-001: "make a setting so sync will work during a raid? have it unchecked by default".
	describe("the 'Keep syncing in a raid group' setting", function()
		it("is off by default, off before the database exists, and a General-tab toggle that reads back", function()
			-- standUpClient's Options stub has no accessor at all: the guard still holds.
			env.setInRaid(true)
			assert.is_true(TOGBankClassic_Constants.SyncPausedByRaid())
			env.setInRaid(false)
			assert.is_false(TOGBankClassic_Constants.SyncPausedByRaid(), "paused outside a raid")
			-- The REAL Options: executed, not grepped.
			TOGBankClassic_Options = nil
			require("env.frames").reset()   -- real frames: AceConfigDialog builds its popup at load
			require("env.ace").load("AceDB-3.0", "AceConfig-3.0", "AceConfigDialog-3.0")
			env.loadUI()
			env.loadFile("Modules/Options.lua")
			assert.is_false(TOGBankClassic_Options:IsSyncInRaidEnabled(), "true before Init -- the guard must be the default")
			TOGBankClassic_Options:Init()
			assert.is_false(TOGBankClassic_Options.db.global.bank.syncInRaid, "the default is not OFF")
			assert.is_false(TOGBankClassic_Options:IsSyncInRaidEnabled())
			local toggle = LibStub("AceConfigRegistry-3.0"):GetOptionsTable("TOGBankClassic", "dialog", "Spec-1.0").args.general.args.syncInRaid
			assert.equal("toggle", toggle.type)
			assert.is_false(toggle.get())
			env.setInRaid(true)
			assert.is_true(TOGBankClassic_Constants.SyncPausedByRaid())
			toggle.set(nil, true)
			assert.is_true(TOGBankClassic_Options:IsSyncInRaidEnabled())
			assert.is_false(TOGBankClassic_Constants.SyncPausedByRaid(), "the setting did not open the guard")
			toggle.set(nil, false)
			assert.is_true(TOGBankClassic_Constants.SyncPausedByRaid())
		end)

		-- Options:Init registers with the Blizzard options window, which is LIBRARY state that
		-- outlives this file; a second Init in a later spec file (searchbox_spec) raises "already
		-- been added". Hand the registration back -- in an after_each, so a RED example above still
		-- hands it back rather than turning one failure into two (the harness pin 292f625 did that).
		after_each(function()
			local ACD = LibStub("AceConfigDialog-3.0")
			ACD.BlizOptions["TOGBankClassic"] = nil
			ACD.BlizOptions["TOGBankClassic/Bank"] = nil
			ACD.BlizOptionsIDMap["TOGBankClassic"] = nil
		end)

		it("when on: sends go out, nothing is printed, and the status bar shows no pause", function()
			TOGBankClassic_Options.IsSyncInRaidEnabled = function() return true end
			TOGBankClassic_Options.IsStatusBarNetworkInfoEnabled = function() return true end
			env.setInRaid(true)
			assert.is_false(TOGBankClassic_Constants.SyncPausedByRaid())
			local got = send()
			assert.equal(1, #wire, "the send was suppressed with the setting on")
			assert.is_truthy(got and got.sent and got.sent > 0)
			assert.equal(0, raidNotices())
			P:OnPublished(BANKER, C(T, 0x20))
			local center = SB.BuildSides()
			assert.is_nil(center:find("Sync paused", 1, true), center)
		end)

		it("when on: incoming messages are handled rather than ignored", function()
			TOGBankClassic_Options.IsSyncInRaidEnabled = function() return true end
			env.setInRaid(true)
			-- Chat:Init's state for the broadcast path an hlb2 falls through to.
			TOGBankClassic_Chat.hashBroadcastQueue = TOGBankClassic_Chat.hashBroadcastQueue or {}
			TOGBankClassic_Chat.HASH_BROADCAST_BATCH_DELAY = TOGBankClassic_Chat.HASH_BROADCAST_BATCH_DELAY or 0.15
			local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hlb2", v = 0, e = "", banker = PEER, isBanker = false, addon = "TOGBankClassic-v1.5.0" })
			TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "GUILD", PEER)
			assert.equal("TOGBankClassic-v1.5.0", TOGBankClassic_Guild.peerAddonVersions[PEER],
				"the broadcast was ignored: the receive gate did not read the setting")
		end)

		it("when off: the same incoming message is ignored", function()
			env.setInRaid(true)
			local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hlb2", v = 0, e = "", banker = PEER, isBanker = false, addon = "TOGBankClassic-v1.5.0" })
			TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "GUILD", PEER)
			assert.is_nil(TOGBankClassic_Guild.peerAddonVersions[PEER], "a raid-time message was handled with the setting off")
		end)
	end)

	it("status bar: the grey paused line takes the centre over the transport text AND the propagation line", function()
		TOGBankClassic_Options.IsStatusBarNetworkInfoEnabled = function() return true end
		P:OnPublished(BANKER, C(T, 0x20))
		local center = SB.BuildSides()
		assert.is_truthy(center:find("stay online", 1, true), center)
		env.setInRaid(true)
		local raidCenter, right = SB.BuildSides()
		assert.equal("|cff888888Sync paused: in a raid group|r", raidCenter)
		assert.equal(select(2, SB.BuildSides()), right, "the right (network) section was disturbed by the raid line")
		-- The moment the raid is left the banker's own line is back: the pause is not sticky.
		env.setInRaid(false)
		center = SB.BuildSides()
		assert.is_truthy(center:find("stay online", 1, true), center)
	end)
end)
