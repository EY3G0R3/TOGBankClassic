-- MULTIPC-001: a banker played from SEVERAL PCs on one shared account.
--
-- THE OPERATOR, verbatim: "one thing we have to accomodate, the banker CAN be red in its tab and
-- out of date. For my guild we have a SHARED account many PC's in different states log into. so
-- their data COULD be out of date until they open their bags/mail/bank."
--
-- Each PC keeps its own SavedVariables, so the copy a PC holds of ITS OWN character can be older
-- than the version another PC published. Two things follow, and this file pins both:
--
--   * the own tab goes RED when a peer names a later version of this character, and a bare offer
--     for our own number is let through to the version query so the PC learns that promptly;
--   * a scan on a PC that is behind is STORED but NOT PUBLISHED until every source (vault, bags,
--     mail) has been re-read on that PC since the newer publish -- a bags-only scan merged over a
--     weeks-old vault, stamped as today's version, would be adopted by every peer over the correct
--     copy. And before the login cycle has answered at all, a partial read waits for it.
--
-- Every example runs on a WHOLE client (env.standUpClient) and drives the real Bank:Scan, the real
-- receive paths and the real timers, because the defect this guards against lives between them.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local OTHER  = "Otherbanker-Testrealm"
local PEER   = "Otherguy-Testrealm"
local GUILD  = "Testguild"
local C      = env.canon
local T      = env.EPOCH

-- Whispers go nowhere but are recorded, so a version query or a sync-request is visible.
local whispers = {}

local function client()
	env.standUpClient("Bankchar", {
		{ name = BANKER, note = "gbank" }, { name = OTHER, note = "gbank" }, { name = PEER },
	}, GUILD)
	assert.is_true(TOGBankClassic_Guild:IsBank(BANKER), "precondition: the roster did not come up")
	env.defineItem(858,   { name = "Minor Healing Potion", class = 0 })
	env.defineItem(15260, { name = "Stone Hammer", class = 2 })
	whispers = {}
	TOGBankClassic_Core.SendWhisper = function(_, prefix, text, target)
		local ok, data = TOGBankClassic_Core:DeserializeWithChecksum(text)
		whispers[#whispers + 1] = { prefix = prefix, data = ok and data or nil, target = target }
		return true   -- the real one returns true for an online target, and callers branch on it
	end
end

local function whispered(kind)
	for _, w in ipairs(whispers) do
		if w.data and w.data.type == kind then return w end
	end
	return nil
end

--- Scan as this client: bags always; the vault when `vault` is given; mail when `mail` is true.
local function scan(opts)
	opts = opts or {}
	env.setBag(0, 4, opts.bags or { { id = 858, count = 5 } })
	if opts.vault then env.setBag(-1, 24, opts.vault) else env.bags[-1] = nil end
	TOGBankClassic_MailInventory.hasUpdated = opts.mail == true
	TOGBankClassic_Bank.hasUpdated = true
	TOGBankClassic_Bank:Scan()
	return TOGBankClassic_Guild.Info.alts[BANKER]
end

local function held() return TOGBankClassic_Guild.Info.alts[BANKER] end

--- The count of item 858 in this PC's stored BAGS bucket. INV2-RETIRE-003: the record's sub-tables
--- are metadata only; what a scan stored is read back from the V2 store, per source.
local function storedBagCount()
	local Record = TOGBankClassic_Inventory_Record
	for _, rec in ipairs(TOGBankClassic_Inventory_Store:GetAltSourceRecords(GUILD, BANKER, "bags")) do
		if Record.id(rec) == 858 then return Record.count(rec) end
	end
	return nil
end
local function canonAt(alt) return alt and TOGBankClassic_DeltaComms:CanonPublishTime(alt.inventoryHashV2) end

--- A peer names a version of OUR bank through the real hash-list reply path.
local function peerNames(publishedAt)
	local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-list-reply", alts = {
		[BANKER] = { hash = 0x10, hashV2 = C(publishedAt, 0x21), updatedAt = publishedAt, mailHash = 0 },
	} })
	TOGBankClassic_Chat:OnCommReceived("togbank-hlr", body, "WHISPER", PEER)
end

--- The login broadcast's collect window, as SyncDeltaVersion opens it.
local function askTheGuild()
	TOGBankClassic_P2PSession:BeginCollectWindow({})
end

--- MULTIPC-002 (docs/DELTA_RELEASE.md section 3.5): the newer version of OUR OWN bank, delivered by
--- the peer that named it, as the snapshot the fetch asks for. Never stored -- Bank keeps it as the
--- base to diff from. `rows` are { id, count }; `canon` is the version it is.
local function peerDelivers(rows, money, canon, from)
	local Record, Wire = TOGBankClassic_Inventory_Record, TOGBankClassic_Inventory_Wire
	local records = {}
	for _, r in ipairs(rows) do records[#records + 1] = Record.new(r[1], r[2]) end
	local payload = Wire.encode(BANKER, records, money, 0x10, canon, TOGBankClassic_DeltaComms:CanonPublishTime(canon), 0)
	TOGBankClassic_Chat:OnCommReceived("togbank-d4", TOGBankClassic_Core:SerializeWithChecksum(payload), "WHISPER", from or PEER)
end

describe("MULTIPC-001: a single PC is untouched", function()
	before_each(function() env.reset(); client() end)

	it("publishes a bags-only scan at once when the guild has not been asked yet", function()
		local alt = scan()
		assert.is_string(alt.inventoryHashV2, "a single-PC banker's first scan minted no canon")
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))
	end)

	it("publishes a bags-only scan at once after the login cycle answered with nothing newer", function()
		askTheGuild()
		env.advance(61)   -- the collect window closes: nobody offered anything
		assert.is_true(TOGBankClassic_P2PSession:IsSelfConsulted(), "precondition: the cycle did not settle")
		local alt = scan()
		assert.is_string(alt.inventoryHashV2)
	end)

	it("stamps when THIS PC last read each source, beside the contents", function()
		env.advance(100)
		local alt = scan({ vault = { { id = 15260, count = 1 } }, mail = true })
		assert.equal(T + 100, alt.bags.lastScan)
		assert.equal(T + 100, alt.bank.lastScan)
		assert.equal(T + 100, alt.mail.lastScan)
	end)
end)

describe("MULTIPC-001: before the guild has answered, a partial read waits", function()
	before_each(function() env.reset(); client() end)

	it("stores a bags-only scan but does not mint, then publishes when the collect window closes empty", function()
		askTheGuild()
		local alt = scan()
		assert.equal(5, storedBagCount(), "the scan itself must still be stored")
		assert.is_nil(alt.inventoryHashV2, "a partial read was PUBLISHED before the guild answered -- on a shared account this is the stale-vault merge every peer adopts")
		assert.is_table(TOGBankClassic_Bank.deferred, "nothing was left waiting to publish")
		-- DEFERRED-LINE-001: the hold names its reason and its start, for the status bar.
		assert.equal("unconsulted", TOGBankClassic_Bank.deferred.why)
		assert.equal(GetTime(), TOGBankClassic_Bank.deferred.since)

		env.advance(61)   -- Dispatch: no offers, nobody named our bank
		assert.is_string(held().inventoryHashV2, "the deferred publish did not release when the cycle settled")
		assert.is_nil(TOGBankClassic_Bank.deferred)
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))
	end)

	-- DEFER-PERSIST-001 (operator 2026-09-13: "still not living through reload, you need to save it to
	-- SV when you 'start' it ... clear it and remove it from sv when it's filled"): a hold is saved
	-- the moment it starts, comes back after a reload with its clock and the before-images of the
	-- last published version (so the log diff and the chain link are the same ones), publishes when
	-- the new session's consult settles, and the save is gone at the mint.
	it("saves a held publish when it starts, restores it after a reload, and clears it at the mint", function()
		TOGBankClassic_Options.db = { char = {} }
		local Bank = TOGBankClassic_Bank
		-- A published version first, so the hold has a real parent and real before-images.
		askTheGuild(); scan(); env.advance(61)
		local parent = held().inventoryHashV2
		assert.is_string(parent)
		assert.is_nil(TOGBankClassic_Options.db.char.deferredPublish, "a publish left a save behind")
		-- New session: the consult has not settled; a changed bag scan is held.
		TOGBankClassic_P2PSession.selfConsulted, TOGBankClassic_P2PSession.consultBegun = false, nil
		askTheGuild()
		env.advance(7)
		scan({ bags = { { id = 858, count = 9 } } })
		local d = Bank.deferred
		assert.is_table(d, "the changed scan was not held")
		local saved = TOGBankClassic_Options.db.char.deferredPublish
		assert.is_table(saved, "the hold was not saved when it started")
		assert.equal(BANKER, saved.player); assert.equal("unconsulted", saved.why)
		assert.equal(d.startedAt, saved.startedAt); assert.equal(parent, saved.logCanonBefore)
		assert.is_table(saved.logBefore); assert.is_true(#saved.logBefore > 0, "the before-images were not saved")
		assert.are_not.equal(d.logBefore, saved.logBefore, "the save shares the live table")

		-- /reload: every module's session state is gone; the SavedVariables and the store stay.
		Bank.deferred, Bank.deferredFallbackArmed = nil, nil
		TOGBankClassic_P2PSession.selfConsulted, TOGBankClassic_P2PSession.consultBegun = false, nil
		env.advance(30)
		assert.is_true(Bank:RestoreDeferred(), "the hold did not come back")
		assert.is_false(Bank:RestoreDeferred(), "restored twice")
		local r = Bank.deferred
		assert.equal("unconsulted", r.why); assert.equal(parent, r.logCanonBefore)
		assert.same(saved.logBefore, r.logBefore)
		assert.equal(30, math.floor(GetTime() - r.since + 0.5), "the clock did not carry across the reload")
		assert.is_true(Bank.deferredFallbackArmed, "the net under 'never publishes' was not re-armed")
		assert.equal(parent, held().inventoryHashV2, "restoring a hold minted something")

		-- The new session's consult settles and the login bag scan runs (the gate now open): the mint
		-- diffs from the RESTORED before-images, not that scan's own rows -- otherwise the hide the hold
		-- carried would never reach the log or the chain link.
		local mintedFrom
		local realMint = Bank.MintVersion
		Bank.MintVersion = function(self, a, p, recs, money, hash, logBefore, logMoneyBefore, logCanonBefore)
			mintedFrom = { logBefore = logBefore, logCanonBefore = logCanonBefore }
			return realMint(self, a, p, recs, money, hash, logBefore, logMoneyBefore, logCanonBefore)
		end
		askTheGuild()
		scan({ bags = { { id = 858, count = 9 } } })   -- the session's first bag scan, same contents: held, images kept
		assert.same(saved.logBefore, Bank.deferred.logBefore, "the login scan replaced the restored before-images")
		env.advance(61)
		Bank.MintVersion = realMint
		local minted = held().inventoryHashV2
		assert.is_string(minted); assert.are_not.equal(parent, minted, "the restored hold did not publish")
		assert.is_not_nil(mintedFrom, "nothing minted")
		assert.equal(parent, mintedFrom.logCanonBefore, "the mint did not diff from the saved parent")
		assert.same(saved.logBefore, mintedFrom.logBefore, "the mint used the login scan's rows as before-images, dropping the held change")
		assert.is_nil(Bank.deferred)
		assert.is_nil(TOGBankClassic_Options.db.char.deferredPublish, "the save was not cleared at the mint")
	end)

	-- DEFER-CLOCK-001 (operator 2026-09-13: "if i do a hide, and wait 10 secs, then do an UNHIDE it
	-- should be a new hash so ensure it is a new hash and start the timer over on the NEW HASH"): the
	-- unhide puts the contents back where the published version had them, so Scan sees "no changes"
	-- against it -- but the hold's clock restarts on it, the share the hide asked for is still owed,
	-- and the mint that ends the hold is a NEW canon over the current contents.
	it("restarts a hold's clock on a hide-then-unhide, keeps the share it owes, and mints a new canon", function()
		local Bank = TOGBankClassic_Bank
		askTheGuild(); scan(); env.advance(61)          -- published: 5 potions
		local parent = held().inventoryHashV2
		TOGBankClassic_P2PSession.selfConsulted, TOGBankClassic_P2PSession.consultBegun = false, nil
		askTheGuild()
		Bank.shareOnMint = true                         -- what SetHidden sets before its rescan
		scan({ bags = { { id = 858, count = 4 } } })    -- the hide: held
		local d = Bank.deferred
		assert.is_table(d)
		env.advance(10)
		scan({ bags = { { id = 858, count = 5 } } })    -- the unhide, ten seconds later: contents as published
		assert.equal(d, Bank.deferred, "the unhide dropped the hold")
		assert.equal(0, math.floor(GetTime() - d.since + 0.5), "the clock did not restart on the unhide")
		assert.is_true(Bank.shareOnMint, "the unhide's no-change scan dropped the share the hide asked for")
		local shared = 0
		TOGBankClassic_Events = TOGBankClassic_Events or {}
		local realSync = TOGBankClassic_Events.SyncDeltaVersion
		TOGBankClassic_Events.SyncDeltaVersion = function() shared = shared + 1 end
		env.advance(61)                                 -- the consult settles: the hold mints
		TOGBankClassic_Events.SyncDeltaVersion = realSync
		local minted = held().inventoryHashV2
		assert.is_string(minted); assert.are_not.equal(parent, minted, "no new canon for the same contents -- the guild would never hear the sequence")
		assert.equal(1, shared, "the mint did not share the version the hide asked for")
		assert.is_nil(Bank.deferred); assert.is_nil(Bank.shareOnMint)
	end)

	it("drops a saved hold whose parent is no longer the held canon, and leaves it alone before the record is loaded", function()
		local Bank = TOGBankClassic_Bank
		TOGBankClassic_Options.db = { char = {} }
		askTheGuild(); scan(); env.advance(61)   -- a held canon exists
		local stale = { player = BANKER, startedAt = T, why = "unconsulted", logCanonBefore = C(T - 100, 0x11) }
		TOGBankClassic_Options.db.char.deferredPublish = stale
		local info = TOGBankClassic_Guild.Info
		TOGBankClassic_Guild.Info = nil
		assert.is_false(Bank:RestoreDeferred())
		assert.equal(stale, TOGBankClassic_Options.db.char.deferredPublish, "dropped before the record was loaded")
		TOGBankClassic_Guild.Info = info
		assert.is_false(Bank:RestoreDeferred())
		assert.is_nil(TOGBankClassic_Options.db.char.deferredPublish, "a stale hold was kept")
		assert.is_nil(Bank.deferred)
	end)

	it("serves and advertises NOTHING for its own bank while a publish is deferred -- the stored rows no longer match the old canon", function()
		scan()                                   -- published at T
		assert.is_string(TOGBankClassic_Guild:ServableCanon(BANKER), "precondition: a published bank is servable")
		askTheGuild()
		scan({ bags = { { id = 858, count = 9 } } })   -- stored, deferred: rows say 9, canon still says 5
		assert.is_false(TOGBankClassic_Guild:CanServe(BANKER), "a peer asking for the old version would receive the new rows under the old canon")
		assert.is_nil(TOGBankClassic_Guild:ServableCanon(BANKER))
		env.advance(61)
		assert.is_true(TOGBankClassic_Guild:CanServe(BANKER), "released and stamped: servable again")
		assert.is_string(TOGBankClassic_Guild:ServableCanon(BANKER))
	end)

	it("trusts a read of ALL THREE sources on its own -- it is the whole truth whatever anyone holds", function()
		askTheGuild()
		local alt = scan({ vault = { { id = 15260, count = 1 } }, mail = true })
		assert.is_string(alt.inventoryHashV2, "a full read was held back for an answer it does not need")
	end)

	it("publishes anyway after the fallback if the cycle never settles", function()
		askTheGuild()
		-- Stop the collect timer so Dispatch never fires: the cycle is stuck.
		TOGBankClassic_P2PSession.collectTimer:Cancel()
		scan()
		assert.is_nil(held().inventoryHashV2, "precondition")
		env.advance(179)
		assert.is_nil(held().inventoryHashV2, "released early")
		env.advance(2)
		assert.is_string(held().inventoryHashV2, "the fallback never released the deferred publish -- a banker that never publishes is the worse failure")
	end)

	it("keeps the bank-log diff against the last PUBLISHED version, not the last scan", function()
		-- First publish, then two deferred scans, then the release: one log entry spanning both.
		scan({ bags = { { id = 858, count = 5 } } })
		local before = held().inventoryHashV2
		askTheGuild()
		scan({ bags = { { id = 858, count = 7 } } })
		scan({ bags = { { id = 858, count = 9 } } })
		local entries = TOGBankClassic_Log:GetEntries()
		local n = #entries
		env.advance(61)
		entries = TOGBankClassic_Log:GetEntries()
		assert.equal(n + 1, #entries, "expected exactly one bank-log entry from the released publish")
		local e = entries[#entries]
		assert.equal(before, e.fromCanon, "the diff was not taken from the version last published")
		assert.equal(held().inventoryHashV2, e.toCanon)
		assert.equal(4, e.count, "the diff should span both deferred scans: 5 -> 9")
	end)
end)

describe("MULTIPC-001: a PC that is BEHIND on its own character", function()
	before_each(function()
		env.reset(); client()
		-- This PC's own copy: published at T, every source read at T. Another PC then publishes at
		-- T+60, and a peer tells us so.
		scan({ vault = { { id = 15260, count = 1 } }, mail = true })
		assert.equal(T, canonAt(held()), "precondition: the first publish is at T")
		env.advance(200)
		peerNames(T + 60)
	end)

	it("shows its own tab red, with the two times", function()
		local state, heldAt, newestAt = TOGBankClassic_Guild:GetAltStaleness(BANKER)
		assert.equal("behind", state)
		assert.equal(T, heldAt)
		assert.equal(T + 60, newestAt)
	end)

	it("does not fetch its own bank -- the record here is the only one with the per-source split", function()
		assert.is_nil(whispered("alt-request"), "the client asked a peer for its own bank")
		assert.is_nil(whispered("sync-request"))
		assert.is_false(TOGBankClassic_Guild:IsAltSyncPending(BANKER))
	end)

	it("stores a bags-only scan but publishes nothing -- the stored vault is a stale copy", function()
		local alt = scan({ bags = { { id = 858, count = 9 } } })
		assert.equal(9, storedBagCount())
		assert.equal(T, canonAt(alt), "a bags-only scan on a PC that is behind was PUBLISHED as a new version over a vault it never re-read")
		assert.equal("behind", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))
	end)

	-- MULTIPC-002 (section 3.5): once everything is re-read, the PC does not publish against the
	-- version IT last held -- that link would not connect to what the guild holds, and its log would
	-- repeat the other PC's moves as its own. It fetches the newer version from the peer that named
	-- it, for the diff only, and publishes when it lands.
	it("publishes only once vault, bags AND mail have all been re-read on this PC -- and the newer version has been fetched", function()
		scan({ bags = { { id = 858, count = 9 } }, vault = { { id = 15260, count = 2 } } })
		assert.equal(T, canonAt(held()), "vault + bags re-read, mail not: still a stale mail copy")
		local ok, why = TOGBankClassic_Bank:CanPublish(held())
		assert.is_false(ok)
		assert.equal("stale:mail", why)
		assert.is_nil(whispered("sync-request"), "the fetch went out before the re-read was complete")

		scan({ bags = { { id = 858, count = 9 } }, mail = true })
		assert.equal(T, canonAt(held()), "published before the newer version was fetched as the diff base")
		local req = whispered("sync-request")
		assert.is_table(req, "the re-read did not ask the peer that named the newer version for it")
		assert.equal(BANKER, req.data.altName, "the fetch is for OUR OWN bank")
		assert.equal(C(T + 60, 0x21), req.data.canon, "the fetch does not name the version the peer said it holds")
		assert.equal(PEER, req.target)

		-- The peer accepts; the session asks on the host; the snapshot of the newer version lands.
		TOGBankClassic_P2PSession:OnSyncAccept(req.data.sessionId, PEER)
		peerDelivers({ { 858, 7 }, { 15260, 2 } }, 0, C(T + 60, 0x21))
		assert.equal(T + 200, canonAt(held()), "every source re-read and the base fetched: this PC is the author again")
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))
		-- NEVER STORED: the store still holds what THIS PC read (bags 9), not the peer's copy (7).
		assert.equal(9, storedBagCount(), "the fetched version was written into the store -- MULTIPC-001's double count")
		assert.same({}, TOGBankClassic_P2PSession.sessionsByAlt, "the fetch's session was not completed")
	end)

	it("publishes a full re-read even when the contents came out identical to its OLD copy", function()
		-- Otherwise a PC whose re-read equals its old contents would keep advertising the old canon
		-- and stay red against the newer one for ever.
		scan({ vault = { { id = 15260, count = 1 } }, mail = true })
		local req = whispered("sync-request")
		TOGBankClassic_P2PSession:OnSyncAccept(req.data.sessionId, PEER)
		peerDelivers({ { 858, 7 }, { 15260, 1 } }, 0, C(T + 60, 0x21))
		assert.equal(T + 200, canonAt(held()))
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))
	end)

	it("diffs the bank log and the chain link from the FETCHED version, not from the copy it last published", function()
		scan({ bags = { { id = 858, count = 9 } } })                       -- stored, not published
		local n = #TOGBankClassic_Log:GetEntries()
		scan({ bags = { { id = 858, count = 9 } }, vault = { { id = 15260, count = 1 } }, mail = true })
		local req = whispered("sync-request")
		TOGBankClassic_P2PSession:OnSyncAccept(req.data.sessionId, PEER)
		-- The other PC's version: 858 x7. This PC now holds 9, so ITS move is +2, not the +4 from 5.
		peerDelivers({ { 858, 7 }, { 15260, 1 } }, 0, C(T + 60, 0x21))
		local entries = TOGBankClassic_Log:GetEntries()               -- newest first
		assert.equal(n + 1, #entries, "expected exactly one entry from the publish")
		assert.equal(C(T + 60, 0x21), entries[1].fromCanon, "the diff was not taken from the fetched version")
		assert.equal(2, entries[1].count, "7 -> 9: this PC's own move, not the other PC's 5 -> 7 as well")
		local links = TOGBankClassic_Inventory_Chain:Links(GUILD, BANKER)
		assert.equal(C(T + 60, 0x21), links[#links].parent, "the link does not connect to the version the guild holds")
		assert.equal(held().inventoryHashV2, links[#links].canon)
	end)

	it("publishes WITHOUT a base after the fallback when the peer never delivers: no link, nothing logged, data exact", function()
		scan({ bags = { { id = 858, count = 9 } }, vault = { { id = 15260, count = 1 } }, mail = true })
		assert.is_table(whispered("sync-request"))
		local n = #TOGBankClassic_Log:GetEntries()
		env.advance(179)
		assert.equal(T, canonAt(held()), "published before the fallback")
		env.advance(2)
		assert.equal(T + 200 + 181, canonAt(held()), "the fallback did not publish -- a banker that never publishes is the worse failure")
		assert.equal(9, storedBagCount())
		assert.equal(n, #TOGBankClassic_Log:GetEntries(), "something was logged for a version whose parent was never held")
		assert.is_nil(TOGBankClassic_Inventory_Chain:Newest(GUILD, BANKER), "a link was written from a version this PC did not hold")
	end)

	it("takes the base from a broadcast's holder too, and only a version NEWER than the one awaited", function()
		-- A second peer's broadcast names an even newer version: it becomes the one to fetch.
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-list-broadcast", alts = {
			[BANKER] = { hash = 0x10, hashV2 = C(T + 90, 0x22), updatedAt = T + 90, mailHash = 0 },
		}, banker = OTHER, isBanker = true })
		TOGBankClassic_Switches:Set("legacyKeyedReceive", true)
		-- standUpClient does not run Chat:Init; the broadcast batcher's queue and delay come from it.
		TOGBankClassic_Chat.hashBroadcastQueue = TOGBankClassic_Chat.hashBroadcastQueue or {}
		TOGBankClassic_Chat.HASH_BROADCAST_BATCH_DELAY = 0.15
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "GUILD", OTHER)
		env.advance(1)
		assert.equal(C(T + 90, 0x22), TOGBankClassic_Bank.newerSelf.canon)
		scan({ bags = { { id = 858, count = 9 } }, vault = { { id = 15260, count = 1 } }, mail = true })
		local req = whispered("sync-request")
		assert.equal(C(T + 90, 0x22), req.data.canon)
		assert.equal(OTHER, req.target, "the fetch did not go to the holder of the newest version")
		TOGBankClassic_P2PSession:OnSyncAccept(req.data.sessionId, OTHER)
		-- An OLDER copy arriving from somebody is not taken as the base.
		peerDelivers({ { 858, 6 } }, 0, C(T + 60, 0x21), PEER)
		assert.equal(T, canonAt(held()), "an older version than the one awaited was taken as the diff base")
		peerDelivers({ { 858, 8 }, { 15260, 1 } }, 0, C(T + 90, 0x22), OTHER)
		assert.is_true(canonAt(held()) > T + 90)
		local e = TOGBankClassic_Log:GetEntries()[1]
		assert.equal(C(T + 90, 0x22), e.fromCanon)
		assert.equal(1, e.count, "8 -> 9")
	end)

	-- MULTIPC-004 (Peer Review, thread 7b7efb1f): TWO HOLDERS, TWO VERSIONS, and the wrong one
	-- answers first. The refusal of a too-old diff base has to RELEASE the fetch, or the holder of
	-- the version we actually want is never asked -- RequestDiffBase short-circuits on
	-- `awaitingDiffBase` before it looks at holders, so the publish waits out the 180s fallback and
	-- goes out with no link and nothing logged.
	it("releases the fetch when the version it wants MOVED while the old one was in flight", function()
		-- The real ordering: ask PEER for X, THEN learn OTHER holds a newer Y. `deferred` is already
		-- set so nothing asks for Y; awaitingDiffBase still names X.
		scan({ bags = { { id = 858, count = 9 } }, vault = { { id = 15260, count = 1 } }, mail = true })
		local first = whispered("sync-request")
		assert.is_table(first, "no fetch went out at all")
		assert.equal(C(T + 60, 0x21), first.data.canon)
		TOGBankClassic_P2PSession:OnSyncAccept(first.data.sessionId, PEER)

		TOGBankClassic_Bank:NoteNewerSelfVersion(C(T + 90, 0x22), { OTHER })
		assert.equal(C(T + 90, 0x22), TOGBankClassic_Bank.newerSelf.canon)
		assert.equal(C(T + 60, 0x21), TOGBankClassic_Bank.awaitingDiffBase,
			"precondition: the fetch in flight is still for the OLD version")

		-- X arrives and is correctly refused -- and the fetch must not stay pinned to it, or the
		-- holder of Y is never asked and the publish waits out the 180s fallback with no link.
		whispers = {}
		peerDelivers({ { 858, 6 } }, 0, C(T + 60, 0x21), PEER)
		assert.equal(T, canonAt(held()), "the older version was taken as the base")
		assert.are_not.equal(C(T + 60, 0x21), TOGBankClassic_Bank.awaitingDiffBase,
			"the refused fetch is still pinned to the version it no longer wants")
		-- THE OTHER HALF (Peer Review 7b7efb1f, follow-up): releasing the flag was not enough. The
		-- session with PEER for our own name was still live when X was refused, and RequestDiffBase
		-- refuses to ask while one is -- so OTHER was still never asked. The refused delivery ends
		-- that session (PEER delivered what it had) and the re-ask goes to OTHER for Y.
		local P2P = TOGBankClassic_P2PSession
		local second = whispered("sync-request")
		assert.is_table(second, "the holder of the newer version was never asked")
		assert.equal(OTHER, second.target)
		assert.equal(C(T + 90, 0x22), second.data.canon)
		assert.equal(C(T + 90, 0x22), TOGBankClassic_Bank.awaitingDiffBase)
		-- Y arrives from OTHER: taken as the base, the publish goes out against it, one link.
		P2P:OnSyncAccept(second.data.sessionId, OTHER)
		peerDelivers({ { 858, 8 }, { 15260, 1 } }, 0, C(T + 90, 0x22), OTHER)
		assert.is_true(canonAt(held()) > T + 90, "the publish did not go out against the fetched base")
		local e = TOGBankClassic_Log:GetEntries()[1]
		assert.equal(C(T + 90, 0x22), e.fromCanon)
		assert.equal(1, e.count, "8 -> 9: this PC's own move against the version it fetched")
		assert.is_false(P2P:HasActiveSession(BANKER))
		assert.equal(0, P2P:GetActiveSendTotal(), "a send slot was left reserved")
	end)

	it("keeps a deferred partial read held when the cycle settles before the re-read is complete", function()
		scan({ bags = { { id = 858, count = 9 } } })         -- stored, not published: vault and mail stale
		assert.is_table(TOGBankClassic_Bank.deferred, "precondition: nothing was deferred")
		-- What MarkSelfConsulted / the fallback do: ask the deferred publish to release. It cannot.
		assert.is_false(TOGBankClassic_Bank:PublishIfDeferred())
		assert.is_table(TOGBankClassic_Bank.deferred, "a held publish was dropped instead of kept")
		assert.equal(T, canonAt(held()), "published over a vault this PC never re-read")
	end)

	it("publishes against the version it last published when it is behind but NOBODY is recorded holding the newer one", function()
		-- The documented fallthrough (Bank:Scan: "with no known holder there is nothing to ask").
		-- SET BY HAND, and said so: after peer review A2 every receive path that raises the staleness
		-- time for our own name also records the sender as a holder, so no wire message produces
		-- this state -- it is the shape Bank keeps for the two records diverging some way nobody has
		-- thought of, and this pins what it does then rather than leaving the branch unexercised.
		TOGBankClassic_Bank.newerSelf = nil
		assert.is_not_nil(TOGBankClassic_Guild:NewerSelfVersionAt(), "precondition: still behind")
		local before = held().inventoryHashV2
		scan({ bags = { { id = 858, count = 9 } }, vault = { { id = 15260, count = 1 } }, mail = true })
		assert.is_nil(whispered("sync-request"), "asked for a diff base with no holder to ask")
		assert.equal(T + 200, canonAt(held()), "a complete re-read with nobody to fetch from was not published")
		local e = TOGBankClassic_Log:GetEntries()[1]
		assert.equal(before, e.fromCanon, "the diff was not taken from the version this PC last published")
		assert.equal(4, e.count, "5 -> 9 against its own last publish")
	end)

	it("names the stale source in CanPublish, vault first", function()
		local ok, why = TOGBankClassic_Bank:CanPublish(held())
		assert.is_false(ok)
		assert.equal("stale:bank", why)
	end)

	it("treats a record with no read stamps (written before this) as stale everywhere", function()
		held().bank.lastScan, held().bags.lastScan, held().mail.lastScan = nil, nil, nil
		local ok, why = TOGBankClassic_Bank:CanPublish(held())
		assert.is_false(ok)
		assert.equal("stale:bank", why)
	end)

	it("does not require a mailbox visit from a record that never had a mail block -- a vault-only banker", function()
		-- Peer Review, self-audit F3: no mail block is "no mail source", not "stale mail". The vault
		-- is never optional: a record with no vault block is a PC that never read it.
		held().mail = nil
		local ok, why = TOGBankClassic_Bank:CanPublish(held())
		assert.is_false(ok)
		assert.equal("stale:bank", why, "precondition: the vault block from T is stale against T+60")
		held().bank = nil
		ok, why = TOGBankClassic_Bank:CanPublish(held())
		assert.is_false(ok)
		assert.equal("stale:bank", why, "a record with no vault block is stale on the vault, never exempt")
		scan({ bags = { { id = 858, count = 9 } }, vault = { { id = 15260, count = 2 } } })
		local req = whispered("sync-request")
		assert.is_table(req, "vault + bags re-read on a record with no mail block must pass the gate and fetch the base")
		TOGBankClassic_P2PSession:OnSyncAccept(req.data.sessionId, PEER)
		peerDelivers({ { 858, 7 } }, 0, C(T + 60, 0x21))
		assert.equal(T + 200, canonAt(held()), "vault + bags re-read on a record with no mail block must publish")
	end)
end)

-- MULTIPC-003: the re-read happened BEFORE the news, which is the ordinary login order -- the first
-- bag event scans while the guild's broadcasts are still in flight. Until this, only Bank:Scan could
-- mint, and a scan that finds no content change and does not YET know it is behind sets nothing
-- deferred; the news then lands with nothing to act on it and the banker sits red for ever.
--
-- Read off the operator's own client 2026-09-12: Bagsbagsbags holding a canon published two days
-- earlier with bags, vault and mail all lastScan'ed minutes before -- "my bags hash should be the
-- latest, but it's saying it's behind".
describe("MULTIPC-003: a PC that re-read everything BEFORE it learned it was behind", function()
	before_each(function()
		env.reset(); client()
		-- Published at T. Another PC publishes at T+60; this PC does not know yet.
		scan({ vault = { { id = 15260, count = 1 } }, mail = true })
		assert.equal(T, canonAt(held()), "precondition: the first publish is at T")
		-- T+200: every source re-read here, with IDENTICAL contents -- so the scan takes the
		-- "version unchanged" branch and defers nothing.
		env.advance(200)
		scan({ vault = { { id = 15260, count = 1 } }, mail = true })
		assert.equal(T, canonAt(held()), "precondition: an unchanged re-read must not mint")
		assert.is_nil(TOGBankClassic_Bank.deferred, "precondition: an unchanged scan deferred a publish")
	end)

	it("republishes on the NEWS, with no second scan: fetches the base, mints, and goes current", function()
		peerNames(T + 60)
		local req = whispered("sync-request")
		assert.is_table(req, "learning it was behind did not release a publish -- the tab stays red until something rescans")
		assert.equal(BANKER, req.data.altName)
		assert.equal(C(T + 60, 0x21), req.data.canon)
		TOGBankClassic_P2PSession:OnSyncAccept(req.data.sessionId, PEER)
		peerDelivers({ { 858, 5 }, { 15260, 1 } }, 0, C(T + 60, 0x21))
		assert.equal(T + 200, canonAt(held()), "the fetched base landed but nothing was published")
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))
	end)

	it("publishes what THIS PC read, not the copy it fetched to diff from", function()
		peerNames(T + 60)
		local req = whispered("sync-request")
		TOGBankClassic_P2PSession:OnSyncAccept(req.data.sessionId, PEER)
		peerDelivers({ { 858, 7 }, { 15260, 1 } }, 0, C(T + 60, 0x21))
		assert.equal(5, storedBagCount(), "the fetched version was written into the store")
	end)

	it("still refuses when a source has NOT been re-read since the newer publish -- the gate is untouched", function()
		-- The vault was last read at T; the other PC published at T+300, after it.
		peerNames(T + 300)
		assert.is_nil(whispered("sync-request"), "a publish was released over a vault this PC never re-read")
		assert.equal(T, canonAt(held()))
		assert.equal("behind", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))
		local ok, why = TOGBankClassic_Bank:CanPublish(held())
		assert.is_false(ok); assert.equal("stale:bank", why)
		-- It is HELD, not dropped: the next complete re-read releases it.
		assert.is_table(TOGBankClassic_Bank.deferred, "the held publish was dropped instead of kept")
		env.advance(200)
		scan({ vault = { { id = 15260, count = 1 } }, mail = true })
		local req = whispered("sync-request")
		assert.is_table(req, "the re-read after the news did not release the publish")
		TOGBankClassic_P2PSession:OnSyncAccept(req.data.sessionId, PEER)
		peerDelivers({ { 858, 5 }, { 15260, 1 } }, 0, C(T + 300, 0x21))
		assert.equal(T + 400, canonAt(held()))
	end)

	it("does not disturb a publish already deferred, whose before-images are the ones that must survive", function()
		-- SET BY HAND, and said so: this client has read all three sources, so the "full read" rule
		-- lets every later scan publish and no wire message leaves it deferred. The shape still
		-- reaches production from a PC that scanned partially before its first complete read, and
		-- the property matters -- the bank-log diff is taken against the version the DEFERRED scan
		-- started from, so overwriting it with the state as of the news would log the wrong moves.
		local d = { logBefore = {}, logMoneyBefore = 0, logCanonBefore = "sentinel" }
		TOGBankClassic_Bank.deferred = d
		peerNames(T + 60)
		assert.equal(d, TOGBankClassic_Bank.deferred, "the deferred publish's before-images were replaced")
		assert.equal("sentinel", TOGBankClassic_Bank.deferred.logCanonBefore)
	end)
end)

describe("MULTIPC-001: the consult begins when the login broadcast is CALLED", function()
	before_each(function() env.reset(); client() end)

	it("holds a partial read from the moment SyncDeltaVersion is called, even while the collision guard defers the send", function()
		-- Peer Review, self-audit F2: the gap used to run until the collect window OPENED.
		TOGBankClassic_Events.hashBroadcastInProgress = true   -- the guard will defer the send by 16s
		TOGBankClassic_Events:SyncDeltaVersion("NORMAL")
		assert.is_false(TOGBankClassic_P2PSession.isCollecting, "precondition: the send was deferred, no window yet")
		assert.is_false(TOGBankClassic_P2PSession:IsSelfConsulted(), "the gate opened before the guild was asked")
		local alt = scan()
		assert.is_nil(alt.inventoryHashV2, "a partial read published in the gap between the call and the send")
	end)

	-- LOG-HYGIENE-002 F6 (Peer Review db06c629): the HIDE-SYNC-001 hypothesis nobody had separated
	-- offline -- the login broadcast SKIPPED by the raid guard. Core drops the send (RAID-VISIBILITY-001)
	-- and every receive, so nobody heard us and nobody can answer; a collect window that closes on
	-- "no offers" then is not the guild saying "nothing newer", it is silence. The consult begins (a
	-- partial read is held) and does NOT settle; the fallback bounds the hold as it always has.
	it("does not settle the own-bank check on a login broadcast the raid guard suppressed -- the hold runs to the fallback", function()
		env.setInRaid(true)
		TOGBankClassic_Events:SyncDeltaVersion("NORMAL")
		assert.is_true(TOGBankClassic_P2PSession.consultBegun, "the consult did not begin")
		assert.is_false(TOGBankClassic_P2PSession:IsSelfConsulted())
		env.advance(61)   -- where a collect window would close on "no offers"
		assert.is_false(TOGBankClassic_P2PSession.selfConsulted, "a window nobody could answer settled the own-bank check")
		local alt = scan()
		assert.is_nil(alt.inventoryHashV2, "a partial read published on the strength of a broadcast nobody heard")
		env.advance(181)  -- DEFERRED_PUBLISH_FALLBACK
		assert.is_true(canonAt(held()) > T, "the fallback did not release the deferred publish")
		assert.is_true(TOGBankClassic_P2PSession:IsSelfConsulted())
	end)

	-- LOG-HYGIENE-002 F6, the other half: EVERY writer of the hold, enumerated. HIDE-SYNC-001 was
	-- diagnosed by asking "who else could have cleared or replaced Bank.deferred?", and the answer
	-- was reconstructed by reading; this pins it so the next reader does not have to. Four sites:
	-- DeferPublish (the hold starts), RestoreDeferred (a reload brings it back), PublishIfDeferred
	-- (the mint clears it) and the no-record bail in the same function. A fifth writer anywhere in
	-- production is a new way for a hold to vanish, and this example names it.
	it("has exactly four production writers of Bank.deferred, all in Bank.lua", function()
		local function writersIn(path)
			local fh = assert(io.open(path, "rb"))
			local src = fh:read("*a"); fh:close()
			local n, lineNo = 0, 0
			for line in (src .. "\n"):gmatch("([^\n]*)\n") do
				lineNo = lineNo + 1
				if line:find("%.deferred%s*=[^=]") then n = n + 1 end
			end
			return n
		end
		assert.equal(4, writersIn("Modules/Bank.lua"), "the writer set of Bank.deferred changed -- name the new site here or remove the old one")
		for _, path in ipairs({ "Core.lua", "Modules/Guild.lua", "Modules/P2PSession.lua", "Modules/Chat.lua",
			"Modules/Events.lua", "Modules/DeltaComms.lua", "Modules/Inventory/Sync.lua", "Modules/Inventory/Store.lua" }) do
			assert.equal(0, writersIn(path), path .. " writes Bank.deferred -- the hold has a writer outside Bank.lua")
		end
	end)
end)

describe("MULTIPC-001: a WIPED PC on the shared account", function()
	before_each(function() env.reset(); client() end)

	it("seeds no stub for our own character from a hash-list reply, reads as behind, and holds a partial read", function()
		-- Nothing held for ourselves; a banker's reply names our bank at T+60.
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-list-reply", alts = {
			[BANKER] = { hash = 0x10, hashV2 = C(T + 60, 0x21), updatedAt = T + 60, mailHash = 0 },
		} })
		TOGBankClassic_Chat:OnCommReceived("togbank-hlr", body, "WHISPER", OTHER)
		assert.is_nil(held(), "a stub carrying the peer's canon was seeded for OUR OWN character -- this PC would read as current and publish a bags-only scan over the real copy")
		assert.equal("behind", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))

		env.advance(200)
		local alt = scan()
		assert.is_nil(alt.inventoryHashV2, "a wiped PC published a bags-only version over one it never read")
		scan({ vault = { { id = 15260, count = 1 } }, mail = true })
		-- MULTIPC-002: everything read; the banker that named the version holds it, so it is fetched
		-- as the base before this PC publishes.
		local req = whispered("sync-request")
		assert.is_table(req, "the wiped PC did not fetch the version it was told about")
		assert.equal(OTHER, req.target)
		TOGBankClassic_P2PSession:OnSyncAccept(req.data.sessionId, OTHER)
		peerDelivers({ { 858, 5 }, { 15260, 1 } }, 0, C(T + 60, 0x21), OTHER)
		assert.equal(T + 200, canonAt(held()))
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))
	end)
end)

describe("MULTIPC-001: learning it from the offer path", function()
	before_each(function()
		env.reset(); client()
		TOGBankClassic_BankerNumbers:Adopt({ v = 5, n = 3, t = { [BANKER] = 1, [OTHER] = 2 } }, PEER)
		scan({ vault = { { id = 15260, count = 1 } }, mail = true })
		env.advance(200)
	end)

	local function bareOfferForUs()
		local BN = TOGBankClassic_BankerNumbers
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-offer2", v = 5, n = BN:EncodeNumbers({ "0001" }) })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "WHISPER", PEER)
	end

	local function peerAnswers(publishedAt)
		local BN = TOGBankClassic_BankerNumbers
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "ver-reply",
			e = BN:EncodeEntries({ { number = "0001", canon = C(publishedAt, 0x21) } }) })
		TOGBankClassic_Chat:OnCommReceived("togbank-rr", body, "WHISPER", PEER)
	end

	it("asks a peer that offers OUR OWN number what version it holds, and goes red on the answer", function()
		askTheGuild()
		bareOfferForUs()
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(BANKER)), "a bare offer names no version; nothing to be behind yet")
		env.advance(61)   -- Dispatch -> version query for our own number
		local q = whispered("ver-query")
		assert.is_table(q, "the offer for our own number was dropped instead of queried -- this PC never learns it is behind")
		assert.equal(PEER, q.target)
		assert.is_false(TOGBankClassic_P2PSession:IsSelfConsulted(), "the cycle settled before the query was answered")

		peerAnswers(T + 60)
		assert.equal("behind", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))
		assert.is_true(TOGBankClassic_P2PSession:IsSelfConsulted())
		assert.is_nil(whispered("sync-request"), "the query led to a FETCH of our own bank")
	end)

	it("does NOT settle the cycle when the peer that offered newer goes silent -- silence is not an answer", function()
		-- Peer Review, self-audit F1: the same rule the red tab applies for any other banker. The
		-- wait is bounded by Bank's fallback, not open-ended.
		-- This PC has NOT read its sources this session (the before_each's full read models the
		-- previous session's SavedVariables): a full read this session is the whole truth and would
		-- rightly publish whatever anyone claims.
		TOGBankClassic_Bank.readThisSession = {}
		askTheGuild()
		bareOfferForUs()
		env.advance(61)                        -- the query goes out
		env.advance(6)                         -- VERSION_QUERY_WINDOW closes with no reply
		assert.is_false(TOGBankClassic_P2PSession:IsSelfConsulted(), "an unanswered query for our own number opened the gate")
		local alt = scan({ bags = { { id = 858, count = 9 } } })
		assert.equal(T, canonAt(alt), "a partial read published on the strength of silence")
		env.advance(181)                       -- DEFERRED_PUBLISH_FALLBACK: the bound
		assert.is_true(canonAt(held()) > T, "the fallback did not release the deferred publish")
		assert.is_true(TOGBankClassic_P2PSession:IsSelfConsulted())
	end)

	-- HIDE-SYNC-001. Read off the operator's banker: `consult: begun=true settled=false` fifteen
	-- minutes into a session, a right-click hide held the whole fallback, CanServe refusing our own
	-- record meanwhile. A v1.4.1 peer offers numbers but cannot answer a version query, so it sat
	-- queried-and-silent for ever. A peer the addon KNOWS runs the old wire has answered by being one.
	it("settles the cycle when the silent offerer is a known old-wire peer -- it cannot answer, and that is its answer", function()
		TOGBankClassic_Bank.readThisSession = {}
		assert.is_true(TOGBankClassic_Guild:NotePeerOldWire(PEER, "state-summary"))
		askTheGuild()
		bareOfferForUs()
		env.advance(61)                        -- the query goes out
		env.advance(6)                         -- VERSION_QUERY_WINDOW closes with no reply
		assert.is_true(TOGBankClassic_P2PSession:IsSelfConsulted(), "an old-wire peer's silence held the own-bank check open")
		-- And the partial scan that follows publishes at once rather than after the 180 s fallback.
		local alt = scan({ bags = { { id = 858, count = 9 } } })
		assert.is_true(canonAt(alt) > T, "the hide-shaped partial scan was deferred behind a peer that can never answer")
	end)

	it("settles the cycle when the answer is no newer than what this PC holds", function()
		askTheGuild()
		bareOfferForUs()
		env.advance(61)
		peerAnswers(T)
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))
		assert.is_true(TOGBankClassic_P2PSession:IsSelfConsulted())
	end)

	it("never marks our own tab 'offered' -- a bare offer for us is settled by the query, not the flag", function()
		askTheGuild()
		bareOfferForUs()
		assert.is_nil(TOGBankClassic_Guild.newerOfferedBy[BANKER])
	end)

	-- MULTIPC-002 / peer review A2: a version reply names the HOLDER as well as the version. A reply
	-- that arrives LATE -- after the query for our own number settled -- or one answering a query
	-- about some OTHER banker that also lists ours, raised the tab's newest time and recorded nobody
	-- to fetch the diff base from: Bank knew it was behind and had no one to ask.
	it("records the replier as a holder of our newer version even when the reply is not to our own query", function()
		askTheGuild()
		-- A bare offer for OTHER's number only; the query that goes out is about OTHER.
		local BN = TOGBankClassic_BankerNumbers
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", TOGBankClassic_Core:SerializeWithChecksum(
			{ type = "hash-offer2", v = 5, n = BN:EncodeNumbers({ "0002" }) }), "WHISPER", PEER)
		env.advance(61)
		local q = whispered("ver-query")
		assert.is_table(q, "precondition: no version query went out")
		-- The reply says nothing servable for OTHER (no entry) but names OUR number, newer than this
		-- PC's copy -- a reply to a query that was never about us.
		TOGBankClassic_Chat:OnCommReceived("togbank-rr", TOGBankClassic_Core:SerializeWithChecksum({ type = "ver-reply",
			e = BN:EncodeEntries({ { number = "0001", canon = C(T + 60, 0x21) } }) }), "WHISPER", PEER)
		assert.is_nil(TOGBankClassic_P2PSession.sessionsByAlt[OTHER], "precondition: nothing to fetch for OTHER, so PEER is free")
		assert.equal("behind", (TOGBankClassic_Guild:GetAltStaleness(BANKER)), "precondition: the reply raised our newest time")
		local newer = TOGBankClassic_Bank.newerSelf
		assert.is_table(newer, "the replier was not recorded as holding our newer version")
		assert.equal(C(T + 60, 0x21), newer.canon)
		assert.same({ PEER }, newer.holders)
		-- And the full re-read fetches from exactly that peer.
		scan({ bags = { { id = 858, count = 9 } }, vault = { { id = 15260, count = 1 } }, mail = true })
		local req = whispered("sync-request")
		assert.is_table(req, "behind with a known holder, and nothing was asked for the diff base")
		assert.equal(BANKER, req.data.altName)
		assert.equal(PEER, req.target)
	end)
end)

describe("MULTIPC-001: a delivery for OUR OWN character is never applied", function()
	before_each(function() env.reset() end)

	it("ignores a tuple payload naming this client's own character", function()
		-- Build the payload on the OTHER client, deliver it here, as tabstaleness_spec does.
		client()
		local Record = TOGBankClassic_Inventory_Record
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, BANKER, { Record.new(858, 5) }, 0)
		TOGBankClassic_Guild.Info.alts[BANKER] = { name = BANKER, items = {}, money = 0 }
		TOGBankClassic_Core:StampInventoryHashes(TOGBankClassic_Guild.Info.alts[BANKER],
			TOGBankClassic_Inventory_Store:GetAltView(GUILD, BANKER), nil, nil, 0, T + 60)
		local sent = {}
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, text) sent[#sent + 1] = { prefix = prefix, text = text } end
		TOGBankClassic_Guild:SendAltData(BANKER, 0, 0, PEER)
		local d4
		for _, m in ipairs(sent) do if m.prefix == "togbank-d4" then d4 = m end end
		assert.is_table(d4, "no payload was sent")

		env.reset(); client()
		local alt = scan({ vault = { { id = 15260, count = 1 } }, mail = true })
		local before = alt.inventoryHashV2
		local sources = TOGBankClassic_Inventory_Store.db.faction[GUILD].alts[BANKER].sources
		assert.is_table(sources.bank, "precondition: our own record is kept per source")

		TOGBankClassic_Chat:OnCommReceived("togbank-d4", d4.text, "GUILD", PEER)
		assert.equal(before, held().inventoryHashV2, "a peer's copy of OUR OWN bank replaced the canon this PC minted")
		sources = TOGBankClassic_Inventory_Store.db.faction[GUILD].alts[BANKER].sources
		assert.is_nil(sources.all, "the flat copy landed beside the per-source record -- the next bags scan counts every bag item twice")
		assert.is_table(sources.bank)
	end)
end)
