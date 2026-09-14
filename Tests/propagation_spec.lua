-- SYNCED-001: has the version of MY bank I just published reached anyone?
--
-- The operator, 2026-09-11: "figure out how to ensure the bankers data is being propagated after
-- filling orders, some kind of visual to tell the banker not to log off yet, until data is synced."
-- Modules/Propagation.lua is the tracker; Modules/UI/StatusBar.lua's BuildPropagationText is the
-- visual, on every window's status bar. The whole-fleet drive is in fullsync_spec; this file pins
-- the tracker's rules and the text one client at a time.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local OTHER  = "Otherbanker-Testrealm"
local PEER   = "Otherguy-Testrealm"
local GUILD  = "Testguild"
local C      = env.canon
local T      = env.EPOCH

local P, SB

local function client()
	env.standUpClient("Bankchar", {
		{ name = BANKER, note = "gbank" }, { name = OTHER, note = "gbank" }, { name = PEER },
	}, GUILD)
	-- The status bar's text builders need only Constants; the window half stays unloaded.
	env.loadFile("Modules/UI/StatusBar.lua")
	P, SB = TOGBankClassic_Propagation, TOGBankClassic_UI_StatusBar
	P:Reset()
	-- standUpClient stubs Output; record what the banker is TOLD.
	TOGBankClassic_Output.Info = function(_, fmt, ...) env.printed[#env.printed + 1] = string.format(fmt, ...) end
	TOGBankClassic_Output.Warn = TOGBankClassic_Output.Info
end

local function infos()
	local out = {}
	for _, m in ipairs(env.printed) do out[#out + 1] = m end
	return out
end

describe("Propagation: the tracker", function()
	before_each(function() env.reset(); client() end)

	it("starts idle, and only OUR OWN mint starts it", function()
		assert.equal("idle", (P:Status()))
		assert.is_false(P:OnPublished(OTHER, C(T, 0x20)), "a mint for another name was tracked")
		assert.is_false(P:OnPublished(BANKER, nil), "a mint with no canon was tracked")
		assert.equal("idle", (P:Status()))
		assert.is_true(P:OnPublished(BANKER, C(T, 0x20)))
		local state, cur = P:Status()
		assert.equal("pending", state)
		assert.equal(C(T, 0x20), cur.canon)
		assert.equal(0, cur.seen); assert.equal(0, cur.sent)
	end)

	it("counts a holder once, only for the tracked version, never ourselves", function()
		P:OnPublished(BANKER, C(T, 0x20))
		assert.is_false(P:NoteHolder(BANKER, C(T + 1, 0x21), PEER), "a different version was counted")
		assert.is_false(P:NoteHolder(OTHER, C(T, 0x20), PEER), "another banker's version was counted")
		assert.is_false(P:NoteHolder(BANKER, C(T, 0x20), BANKER), "we counted ourselves")
		assert.is_false(P:NoteHolder(BANKER, C(T, 0x20), nil))
		assert.equal("pending", (P:Status()))
		assert.is_true(P:NoteHolder(BANKER, C(T, 0x20), "Otherguy"), "a bare same-realm name was not normalised")
		assert.is_false(P:NoteHolder(BANKER, C(T, 0x20), PEER), "the same peer was counted twice")
		local state, cur = P:Status()
		assert.equal("synced", state)
		assert.equal(1, cur.seen)
		assert.equal("seen", cur.holders[PEER])
		assert.is_true(P:NoteHolder(BANKER, C(T, 0x20), OTHER))
		assert.equal(2, select(2, P:Status()).seen)
	end)

	-- Peer review B1: SENT (a reply left this client whole) and SEEN (the peer's own message named
	-- the version) are different facts. Only SEEN answers "has it reached anyone".
	it("keeps SENT apart from SEEN: a drained reply is progress, not a receipt", function()
		P:OnPublished(BANKER, C(T, 0x20))
		assert.is_true(P:NoteHolder(BANKER, C(T, 0x20), PEER, "sent"))
		local state, cur = P:Status()
		assert.equal("pending", state, "a drained reply alone turned the tracker green")
		assert.equal(1, cur.sent); assert.equal(0, cur.seen)
		assert.is_false(P:NoteHolder(BANKER, C(T, 0x20), PEER, "sent"), "the same drain counted twice")
		assert.is_true(P:NoteHolder(BANKER, C(T, 0x20), PEER, "seen"), "the peer's own message must upgrade sent to seen")
		state, cur = P:Status()
		assert.equal("synced", state)
		assert.equal(0, cur.sent, "a peer upgraded to seen is no longer counted as merely sent")
		assert.equal(1, cur.seen)
		assert.is_false(P:NoteHolder(BANKER, C(T, 0x20), PEER, "sent"), "a seen peer must not be demoted to sent")
		assert.equal(1, cur.seen)
	end)

	it("tells the banker ONCE, on the first receipt, that it is safe to log off", function()
		P:OnPublished(BANKER, C(T, 0x20))
		local before = #infos()
		P:NoteHolder(BANKER, C(T, 0x20), PEER)
		P:NoteHolder(BANKER, C(T, 0x20), OTHER)
		local after = infos()
		assert.equal(before + 1, #after)
		assert.is_truthy(after[#after]:find("Otherguy", 1, true), "the line does not name who received it: " .. after[#after])
		assert.is_truthy(after[#after]:find("safe to log off", 1, true))
	end)

	it("a new mint replaces the tracker whole: the old version's holders do not carry over", function()
		P:OnPublished(BANKER, C(T, 0x20))
		P:NoteHolder(BANKER, C(T, 0x20), PEER)
		assert.equal("synced", (P:Status()))
		P:OnPublished(BANKER, C(T + 60, 0x21))
		local state, cur = P:Status()
		assert.equal("pending", state)
		assert.equal(0, cur.seen)
		assert.is_false(P:NoteHolder(BANKER, C(T, 0x20), OTHER), "a receipt of the OLD version counted for the new one")
	end)

	it("is ALONE, not pending, when no guildmate is online to receive it", function()
		for _, m in pairs(TOGBankClassic_Guild.memberRoster) do m.isOnline = false end
		P:OnPublished(BANKER, C(T, 0x20))
		local state, _, online = P:Status()
		assert.equal("alone", state)
		assert.equal(0, online)
		TOGBankClassic_Guild.memberRoster[PEER].isOnline = true
		assert.equal("pending", (P:Status()))
		assert.equal(1, P:OnlinePeerCount(), "the banker counted itself as a guildmate who could receive")
	end)

	it("fires its callbacks on every change and survives one that raises", function()
		local seen = 0
		P:RegisterCallback("spec", function() seen = seen + 1 end)
		P:RegisterCallback("bad", function() error("boom") end)
		assert.is_false(P:RegisterCallback(nil, function() end))
		assert.is_false(P:RegisterCallback("x", "not a function"))
		P:OnPublished(BANKER, C(T, 0x20))
		P:NoteHolder(BANKER, C(T, 0x20), PEER)
		P:NoteHolder(BANKER, C(T, 0x20), PEER)   -- no change: no fire
		assert.equal(2, seen)
		assert.is_true(P:UnregisterCallback("bad"))
		assert.is_false(P:UnregisterCallback("bad"))
		assert.is_false(P:UnregisterCallback(nil))
		P:Reset()
		assert.equal(3, seen)
	end)

	it("measures the wait from the mint", function()
		assert.equal(0, P:Elapsed())
		P:OnPublished(BANKER, C(T, 0x20))
		env.advance(42)
		assert.equal(42, P:Elapsed())
	end)

	it("warns on the logout countdown while pending or alone, and says nothing once synced", function()
		assert.is_false(P:OnCamping(), "warned with nothing published")
		P:OnPublished(BANKER, C(T, 0x20))
		assert.is_true(P:OnCamping())
		local warned = env.printed[#env.printed]
		assert.is_truthy(warned:find("Stay logged in", 1, true), warned)
		assert.is_truthy(warned:find("2 online", 1, true), warned)   -- OTHER and PEER; never ourselves
		for _, m in pairs(TOGBankClassic_Guild.memberRoster) do m.isOnline = false end
		assert.is_true(P:OnCamping())
		assert.is_truthy(env.printed[#env.printed]:find("next login", 1, true))
		TOGBankClassic_Guild.memberRoster[PEER].isOnline = true
		P:NoteHolder(BANKER, C(T, 0x20), PEER)
		local n = #env.printed
		assert.is_false(P:OnCamping())
		assert.equal(n, #env.printed)
	end)
end)

-- PROP-PERSIST-001: the operator logged out and in to test HIDE-SHARE-001 and the line was gone:
-- "we should have this live through so they know no one synced the data if they are disconnected
-- or any other reason." The tracker is saved per character on every change and restored at login
-- while it still describes the held canon and nobody has confirmed it.
describe("Propagation: surviving a relog", function()
	before_each(function()
		env.reset(); client()
		-- standUpClient's Options stub carries no db; the tracker's slot is db.char.
		TOGBankClassic_Options.db = TOGBankClassic_Options.db or {}
		TOGBankClassic_Options.db.char = TOGBankClassic_Options.db.char or {}
		TOGBankClassic_Guild.Info.alts[BANKER] = TOGBankClassic_Guild.Info.alts[BANKER] or {}
		TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2 = C(T, 0x20)
	end)

	local function relog()
		-- A new session: the tracker's in-memory state is gone, the SavedVariables are not.
		P.current = nil
	end

	it("saves the pending tracker on every change and restores it at login, still pending, with the elapsed time kept", function()
		env.now = T + 100
		P:OnPublished(BANKER, C(T, 0x20))
		local saved = TOGBankClassic_Options.db.char.propagation
		assert.is_table(saved, "the mint was not saved")
		assert.equal(C(T, 0x20), saved.canon); assert.equal(BANKER, saved.player); assert.equal(0, saved.seen)
		P:NoteHolder(BANKER, C(T, 0x20), PEER, "sent")
		assert.equal(1, TOGBankClassic_Options.db.char.propagation.sent, "a sent holder was not saved")
		relog()
		assert.equal("idle", (P:Status()), "precondition: a fresh session knows nothing")
		env.now = T + 700   -- ten minutes later
		assert.is_true(P:Restore())
		local state, cur = P:Status()
		assert.equal("pending", state, "the unconfirmed update did not come back red")
		assert.equal(C(T, 0x20), cur.canon)
		assert.equal(1, cur.sent, "the sent-to count was lost"); assert.equal(0, cur.seen)
		assert.is_true(P:Elapsed() >= 600, "the wait restarted from zero instead of from the publish: " .. tostring(P:Elapsed()))
		assert.is_false(P:Restore(), "a second Restore replaced a live tracker")
		-- The receipt after the relog turns it green as before, and the save follows.
		P:NoteHolder(BANKER, C(T, 0x20), PEER)
		assert.equal("synced", (P:Status()))
		assert.equal(1, TOGBankClassic_Options.db.char.propagation.seen)
	end)

	it("drops a saved tracker that no longer describes the held canon, or that was already confirmed", function()
		P:OnPublished(BANKER, C(T, 0x20))
		relog()
		TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2 = C(T + 5, 0x21)   -- the record moved on
		assert.is_false(P:Restore())
		assert.is_nil(TOGBankClassic_Options.db.char.propagation, "a stale tracker was left in the SavedVariables")
		assert.equal("idle", (P:Status()))
		-- Confirmed before the relog: nothing to warn about, nothing restored.
		TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2 = C(T, 0x20)
		P:OnPublished(BANKER, C(T, 0x20))
		P:NoteHolder(BANKER, C(T, 0x20), PEER)
		relog()
		assert.is_false(P:Restore())
		assert.is_nil(TOGBankClassic_Options.db.char.propagation)
		-- Another character's tracker in this slot (a shared account's copy): not ours.
		TOGBankClassic_Options.db.char.propagation = { player = OTHER, canon = C(T, 0x20), publishedAt = T, holders = {}, sent = 0, seen = 0 }
		assert.is_false(P:Restore())
	end)

	-- The operator's first relog lost the line: the roster-init Restore ran before Guild:Init had
	-- loaded the record, judged the save against a nil canon, and DROPPED it.
	it("leaves the save alone while the guild record is not loaded, and restores on the call after the load", function()
		P:OnPublished(BANKER, C(T, 0x20))
		relog()
		local info = TOGBankClassic_Guild.Info
		TOGBankClassic_Guild.Info = nil
		assert.is_false(P:Restore())
		assert.is_table(TOGBankClassic_Options.db.char.propagation, "the save was dropped before the record was loaded")
		TOGBankClassic_Guild.Info = info
		assert.is_true(P:Restore(), "not restored once the record was loaded")
		assert.equal("pending", (P:Status()))
		-- And Guild:Init is the call that follows the load.
		local src = env.readFile("Modules/Guild.lua")
		assert.truthy(src:find("TOGBankClassic_Propagation:Restore()", 1, true), "Guild:Init does not call Restore after Database:Load")
	end)

	it("restores nothing before Options is up, and saves nothing then either -- without erroring", function()
		local O = TOGBankClassic_Options
		TOGBankClassic_Options = nil
		assert.is_false(P:Restore())
		assert.is_true(P:OnPublished(BANKER, C(T, 0x20)))
		assert.is_false(P:Save())
		TOGBankClassic_Options = O
	end)
end)

describe("Propagation: the status-bar line (every window)", function()
	before_each(function() env.reset(); client() end)

	it("is empty when idle, whatever the network-info option says", function()
		assert.equal("", SB.BuildPropagationText())
	end)

	it("tells the banker to stay online while pending, with who is online and how long it has been", function()
		P:OnPublished(BANKER, C(T, 0x20))
		env.advance(75)
		local s = SB.BuildPropagationText()
		assert.is_truthy(s:find("stay online", 1, true), s)
		assert.is_truthy(s:find("2 online", 1, true), s)
		assert.is_truthy(s:find("1:15", 1, true), s)
		assert.is_truthy(s:find("|cffff4444", 1, true), "not red: " .. s)
	end)

	it("says nobody is online to receive it, in grey, when alone", function()
		for _, m in pairs(TOGBankClassic_Guild.memberRoster) do m.isOnline = false end
		P:OnPublished(BANKER, C(T, 0x20))
		local s = SB.BuildPropagationText()
		assert.is_truthy(s:find("no guildmate online", 1, true), s)
		assert.is_truthy(s:find("|cff888888", 1, true), s)
	end)

	it("says SENT in amber while a reply has left but nobody has confirmed -- never green on a drain alone", function()
		P:OnPublished(BANKER, C(T, 0x20))
		P:NoteHolder(BANKER, C(T, 0x20), PEER, "sent")
		local s = SB.BuildPropagationText()
		assert.is_truthy(s:find("sent to 1, not confirmed", 1, true), s)
		assert.is_truthy(s:find("stay online", 1, true), s)
		assert.is_truthy(s:find("|cffff9900", 1, true), "not amber: " .. s)
		assert.is_nil(s:find("|cff00ff00", 1, true), "green on the transport's verdict alone: " .. s)
		assert.is_true(SB.PropagationIsUrgent())
	end)

	it("turns green with the confirmed count, names the merely-sent, and ages out after the last change", function()
		P:OnPublished(BANKER, C(T, 0x20))
		P:NoteHolder(BANKER, C(T, 0x20), PEER)
		local s = SB.BuildPropagationText()
		assert.is_truthy(s:find("confirmed by 1 guildmate|r", 1, true), s)
		assert.is_truthy(s:find("|cff00ff00", 1, true), s)
		assert.is_false(SB.PropagationIsUrgent())
		env.advance(60)
		P:NoteHolder(BANKER, C(T, 0x20), OTHER, "sent")
		s = SB.BuildPropagationText()
		assert.is_truthy(s:find("confirmed by 1 guildmate, sent to 1 more", 1, true), s)
		env.advance(91)
		assert.equal("", SB.BuildPropagationText(), "the synced line should age out; the status bar is not a trophy case")
	end)

	-- STATUSBAR-003: the narrow-bar spelling of each state. Same colour, same clock, same state --
	-- shorter words and no online count, so a 560-wide bar can hold it.
	it("has a SHORT form of every state, in the same colour, shorter than the full line", function()
		P:OnPublished(BANKER, C(T, 0x20))
		env.advance(75)
		local long, short = SB.BuildPropagationText(), SB.BuildPropagationText(true)
		assert.is_truthy(short:find("^|cffff4444Update not received yet %-%- stay online %(1:15%)|r$"), short)
		assert.is_true(#short < #long)

		P:NoteHolder(BANKER, C(T, 0x20), PEER, "sent")
		long, short = SB.BuildPropagationText(), SB.BuildPropagationText(true)
		assert.is_truthy(short:find("^|cffff9900Update sent to 1, unconfirmed %-%- stay online %(1:15%)|r$"), short)
		assert.is_true(#short < #long)

		P:NoteHolder(BANKER, C(T, 0x20), PEER)
		P:NoteHolder(BANKER, C(T, 0x20), OTHER, "sent")
		long, short = SB.BuildPropagationText(), SB.BuildPropagationText(true)
		assert.equal("|cff00ff00Update confirmed by 1, sent to 1 more|r", short)
		assert.is_true(#short < #long)
		env.advance(91)
		assert.equal("", SB.BuildPropagationText(true), "the short form outlived the full one")

		P:Reset()
		for _, m in pairs(TOGBankClassic_Guild.memberRoster) do m.isOnline = false end
		P:OnPublished(BANKER, C(T, 0x20))
		long, short = SB.BuildPropagationText(), SB.BuildPropagationText(true)
		assert.equal("|cff888888Update: nobody online to receive it (0:00)|r", short)
		assert.is_true(#short < #long)
	end)

	-- DEFERRED-LINE-001 (operator 2026-09-13: "hiding/unhiding and now it doesn't show up immediately
	-- like it did before"): a scan the publish gate holds mints nothing, so the tracker is silent for
	-- the whole wait. The bar must show the wait itself, from the first deferred scan, in amber, and
	-- say what ends it -- and drop it the moment the mint clears the hold.
	it("shows a deferred (stored, not published) scan in amber from the moment it is held, ahead of the tracker", function()
		local Bank = TOGBankClassic_Bank
		assert.is_not_nil(Bank, "the client has no Bank module")
		assert.is_nil(Bank.deferred)
		assert.equal("", SB.BuildPropagationText())

		-- The login window: the consult has not settled.
		local d = Bank:DeferPublish({}, 0, C(T, 0x20), "unconsulted")
		assert.equal(d, Bank.deferred)
		env.advance(12)
		local long, short = SB.BuildPropagationText(), SB.BuildPropagationText(true)
		assert.is_truthy(long:find("|cffff9900", 1, true), "not amber: " .. long)
		assert.is_truthy(long:find("not published yet", 1, true), long)
		assert.is_truthy(long:find("waiting for the guild", 1, true), long)
		assert.is_truthy(long:find("stay online", 1, true), long)
		assert.is_truthy(long:find("(0:12)", 1, true), "no clock from the first deferred scan: " .. long)
		assert.is_truthy(short:find("^|cffff9900Update stored, not published %-%- waiting for the guild %(0:12%)|r$"), short)
		assert.is_true(#short < #long)
		assert.is_true(SB.PropagationIsUrgent(), "a held publish is not urgent")

		-- A second change on the hold keeps the before-images (the diff is against the last publish)
		-- and takes the new reason -- and RESTARTS the clock (DEFER-CLOCK-001: "start the timer over
		-- on the NEW HASH").
		local d2 = Bank:DeferPublish({ "later" }, 5, C(T + 5, 0x21), "stale:bank")
		assert.equal(d, d2, "a second deferred scan replaced the first's before-images")
		assert.equal(C(T, 0x20), d2.logCanonBefore)
		assert.equal("stale:bank", d2.why)
		long, short = SB.BuildPropagationText(), SB.BuildPropagationText(true)
		assert.is_truthy(long:find("open your bank and a mailbox", 1, true), "a stale-source hold does not say what re-read ends it: " .. long)
		assert.is_truthy(long:find("(0:00)", 1, true), "the clock did not restart on the second change: " .. long)
		assert.is_truthy(short:find("open bank %+ mailbox %(0:00%)"), short)
		env.advance(3)
		assert.is_truthy(SB.BuildPropagationText():find("(0:03)", 1, true))

		-- The hold outranks the tracker: the version being tracked is about to be superseded.
		P:OnPublished(BANKER, C(T, 0x20))
		assert.is_truthy(SB.BuildPropagationText():find("not published yet", 1, true))
		TOGBankClassic_Options.IsStatusBarNetworkInfoEnabled = function() return false end
		local center = SB.BuildSides()
		assert.is_truthy(center:find("not published yet", 1, true), "the composed centre did not carry the hold: " .. center)

		-- The mint clears the hold; the tracker's own line is back.
		Bank.deferred = nil
		assert.is_truthy(SB.BuildPropagationText():find("not received by anyone yet", 1, true))
	end)

	it("takes the CENTER of the composed sides, over the transport text, and ignores the network-info option", function()
		TOGBankClassic_Options.IsStatusBarNetworkInfoEnabled = function() return false end
		P:OnPublished(BANKER, C(T, 0x20))
		local center, right = SB.BuildSides()
		assert.is_truthy(center:find("stay online", 1, true), center)
		assert.equal("", right, "network parts leaked through with the option off")
		P:Reset()
		center = SB.BuildSides()
		assert.equal("", center)
	end)
end)
