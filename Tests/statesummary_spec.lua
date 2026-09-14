-- The data leg's DECISION, on the canon alone (THE DELTA RELEASE step 3b, Inventory/Sync.lua).
--
-- HISTORY THIS FILE CARRIES. It was written for HASH-CANON-010, read off Galdof's live log on
-- 2026-09-10 ~18:20: Galdof requested Alchemyrcp, Alchemy ACKed, Galdof whispered its state summary
-- -- revision-1 `808855588`, no canon -- and Alchemy answered `togbank-nochange`, because the
-- responder compared revision 1 and the contents had not changed since Sep 5. Only the canon had.
-- The requester was "answered" and still held no canon. That was the FIFTH spelling of the same-hash
-- test, on the RESPONDER, and the one the requester-side fix could not reach.
--
-- Step 3b deleted that responder (`RespondToStateSummary`) and the state summary it read. The
-- decision it made is now Sync:OnDataRequest's, made on ONE field -- the canon the requester names
-- in its QUERY baseline -- with three answers: no-change, the chain, or the snapshot. The examples
-- below are the same cases re-pinned to the new seam, plus the one the old design could not
-- express ("they hold NEWER than we do"). The revision-1 fallback for two canon-less copies is gone
-- on purpose ("v1 is always red"): a copy with no canon gets the snapshot, which is how it acquires
-- one. The chain answer itself is specified in chainwire_spec, against the real chain.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local OTHER  = "Otherbanker-Testrealm"
local PEER   = "Otherguy-Testrealm"
local GUILD  = "Testguild"
local C      = env.canon
local T      = 1757000000

local function client(who)
	env.standUpClient(who, {
		{ name = BANKER, note = "gbank" }, { name = OTHER, note = "gbank" }, { name = PEER },
	}, GUILD)
end

--- The provider's record: contents in the store, canon (or nil) on the record.
local function hold(alt, canon, at)
	TOGBankClassic_Guild.Info.alts[alt] = {
		name = alt, money = 0, version = at,
		inventoryHash = 0x10, inventoryHashV2 = canon, inventoryUpdatedAt = at, mailHash = 0x77,
		bank = { slots = { count = 1, total = 28 } },
	}
	env.holdV2(GUILD, alt, { { 858, 5 } })
end

--- Capture what the host hands the transport, decoded, keyed by channel.
local function captureHost()
	local host = TOGBankClassic_Core:DeltaHost()
	local byChannel = {}
	for channel, prefix in pairs(host.prefixes) do byChannel[prefix] = channel end
	local sent = {}
	-- An instant transport: records the message and reports it delivered in the same call, the
	-- way AceCommQueue's one terminal callback would for a message that went in one tick.
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, body, dist, target, _, cb, arg)
		local _, decoded = TOGBankClassic_Core:DeserializeWithChecksum(body, {})
		sent[#sent + 1] = { channel = byChannel[prefix] or prefix, prefix = prefix, body = decoded, dist = dist, target = target }
		if cb then cb(arg, #body, #body, true) end
	end
	return sent
end

local function answers(sent)
	local out = {}
	for _, m in ipairs(sent) do
		if m.channel == "RESPONSE" and type(m.body) == "table" then out[m.body.type] = m.body end
	end
	return out
end

describe("HASH-CANON-010 / step 3b: the provider decides 'do they hold my version?' on the canon", function()
	local sent, Sync

	before_each(function()
		env.reset(); client("Bankchar")
		sent = captureHost()
		Sync = TOGBankClassic_Inventory_Sync
	end)

	local function ask(canon)
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)   -- the accept: CHAIN-003 answers nobody else
		Sync:OnDataRequest(PEER, { type = "inv", hash = canon or 0, keys = { alt = BANKER } })
		return answers(sent)
	end

	-- The Alchemyrcp case, exactly: same contents, no canon on the requester -> the data.
	it("SENDS the snapshot when the requester holds the same contents and NO canon", function()
		hold(BANKER, C(T, 0x20), T)
		local a = ask(nil)
		assert.is_nil(a["inv-nochange"],
			"answered 'no change' to a requester holding the same contents and NO canon -- it can " ..
			"never acquire one that way (HASH-CANON-010)")
		assert.is_table(a["inv-snapshot"], "the tuple payload was not sent")
		assert.equal(BANKER, a["inv-snapshot"].alt)
		assert.equal(C(T, 0x20), a["inv-snapshot"].payload[6], "the snapshot did not carry the author's canon")
	end)

	it("answers no-change when the requester holds the same canon", function()
		hold(BANKER, C(T, 0x20), T)
		local a = ask(C(T, 0x20))
		assert.is_table(a["inv-nochange"], "the same version was re-sent in full")
		assert.is_nil(a["inv-snapshot"])
		assert.is_nil(a["inv-chain"])
		assert.equal(BANKER, a["inv-nochange"].alt)
	end)

	it("SENDS when the requester holds an OLDER canon and no chain connects from it", function()
		hold(BANKER, C(T + 60, 0x21), T + 60)
		local a = ask(C(T, 0x20))
		assert.is_table(a["inv-snapshot"])
		assert.is_nil(a["inv-nochange"])
	end)

	it("SENDS on a forced-full request (hash 0)", function()
		hold(BANKER, C(T, 0x20), T)
		assert.is_table(ask(0)["inv-snapshot"])
	end)

	-- The case the state summary could not express: the requester is AHEAD of us. Nothing we send
	-- could improve their copy, and a snapshot would only be discarded as stale on arrival; a
	-- no-change completes their session.
	it("answers no-change when the requester holds a NEWER canon than ours", function()
		hold(BANKER, C(T, 0x20), T)
		local a = ask(C(T + 600, 0x99))
		assert.is_table(a["inv-nochange"], "sent an older copy to a requester that already holds newer")
		assert.is_nil(a["inv-snapshot"])
	end)

	-- "v1 is always red": there is no revision-1 language on this leg. Two canon-less copies used
	-- to be called the same version when their revision-1 numbers matched; now the requester gets
	-- the snapshot, and with it whatever version the provider can name (here: none).
	it("SENDS the snapshot when NEITHER side holds a canon -- no revision-1 fallback", function()
		hold(BANKER, nil, T)
		local a = ask(nil)
		assert.is_nil(a["inv-nochange"],
			"two canon-less copies were called the same version on revision 1; v1 is always red")
		assert.is_table(a["inv-snapshot"])
	end)

	it("does not answer a baseline that is not ours, so another consumer of the host can", function()
		hold(BANKER, C(T, 0x20), T)
		assert.is_false(Sync:OnDataRequest(PEER, { type = "roster", hash = 0, keys = {} }))
		assert.equal(0, #sent)
	end)

	-- THE HOST HANDS US THE SENDER AS AceComm SPELLS IT: a same-realm peer arrives as a BARE name
	-- (DeltaSync's NormalizeSender only strips realm spaces), while the slot and the state-wait were
	-- keyed by the requester's `Name-Realm` from the handshake. Found while writing this file: every
	-- fixture above used the full name and so could not see that a bare one leaked the slot (P2P-028)
	-- and let the state-wait release it a second time (P2P-024).
	it("keys the slot and the state-wait by the requester's FULL name when the host gives a bare one", function()
		hold(BANKER, C(T, 0x20), T)
		local P2P = TOGBankClassic_P2PSession
		P2P:TryAcquireSendSlot(PEER)
		P2P:ArmStateWait(PEER, BANKER)
		Sync:OnDataRequest("Otherguy", { type = "inv", hash = C(T, 0x20), keys = { alt = BANKER } })
		assert.equal(0, P2P:GetActiveSendTotal(), "a bare-named requester's no-change did not release ITS slot")
		assert.is_false(P2P:IsAwaitingSummary(PEER), "the state-wait armed for the full name was not cancelled by the bare-named query")
	end)

	-- P2P-028: the slot taken at accept (inside ask) is given back on the outcomes that send nothing.
	it("frees the send slot on a no-change", function()
		hold(BANKER, C(T, 0x20), T)
		local a = ask(C(T, 0x20))
		assert.is_table(a["inv-nochange"], "precondition: not a no-change")
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal(),
			"a no-change kept the slot it was accepted with; three of these and the banker is " ..
			"'busy' to everyone for 210 seconds (P2P-028)")
	end)

	it("frees the send slot when there is nothing to send for the alt", function()
		TOGBankClassic_Guild.Info.alts[BANKER] = {
			name = BANKER, money = 0, version = T,
			inventoryHash = 0x10, inventoryHashV2 = C(T, 0x20), inventoryUpdatedAt = T, mailHash = 0x77,
		}   -- a record, NO tuple rows: nothing to ship
		local a = ask(nil)
		assert.is_nil(a["inv-snapshot"], "precondition: something was sent after all")
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal(), "nothing-to-send kept the slot")
	end)

	it("frees the send slot when the request names no alt at all", function()
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = 0, keys = {} })
		assert.equal(0, #sent)
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal())
	end)

	-- The snapshot is a BULK send that drains over time; the slot must outlive the call and be
	-- released by the transport's completion, not by the return of SendData (P2P-024: three queued
	-- snapshots counting as no load is how the cap admitted a fourth).
	it("holds the slot for a snapshot until the transport reports the send complete", function()
		hold(BANKER, C(T, 0x20), T)
		local host = TOGBankClassic_Core:DeltaHost()
		local completion
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, _, _, _, _, cb, arg)
			if prefix == host.prefixes.RESPONSE then completion = { cb = cb, arg = arg } end
		end
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = 0, keys = { alt = BANKER } })
		assert.is_table(completion, "the snapshot never reached the transport")
		assert.equal(1, TOGBankClassic_P2PSession:GetActiveSendTotal(),
			"the slot was released before the payload had left -- the cap now counts a queued send as no load")
		-- AceCommQueue's one terminal verdict: the whole message went.
		completion.cb(completion.arg, 300, 300, true)
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal(), "delivery did not release the slot")
	end)

	it("releases the slot when the transport REFUSES the snapshot, and only once", function()
		hold(BANKER, C(T, 0x20), T)
		local host = TOGBankClassic_Core:DeltaHost()
		local completion
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, _, _, _, _, cb, arg)
			if prefix == host.prefixes.RESPONSE then completion = { cb = cb, arg = arg } end
		end
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = 0, keys = { alt = BANKER } })
		completion.cb(completion.arg, 0, 300, false, "rejected")
		completion.cb(completion.arg, 0, 300, false, "rejected")
		assert.equal(1, TOGBankClassic_P2PSession:GetActiveSendTotal(),
			"a refused send released the wrong number of slots (expected exactly one)")
	end)

	-- The host can refuse BEFORE the transport (its roster guard: the requester went offline). No
	-- callback will ever come, so the release must happen on the false return -- and the watcher
	-- armed for the send must be withdrawn, or the NEXT send to that peer would release a slot it
	-- never took.
	it("releases the slot at once when the host refuses the send, and withdraws the watcher", function()
		hold(BANKER, C(T, 0x20), T)
		local host = TOGBankClassic_Core:DeltaHost()
		host.SendMessage = function() return false end
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = 0, keys = { alt = BANKER } })
		host.SendMessage = nil
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal(), "a send the host refused kept its slot")

		-- A later, unrelated no-change to the same peer must not trip a stale watcher.
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		host:SendData(PEER, { type = "x" }, false)
		assert.equal(2, TOGBankClassic_P2PSession:GetActiveSendTotal(),
			"a watcher left behind by a refused send released a slot on the next send to that peer")
	end)
end)

describe("HASH-CANON-010 / step 3b: the requester names the canon it holds in its QUERY", function()
	local sent, Sync

	before_each(function()
		env.reset(); client("Otherguy")
		sent = captureHost()
		Sync = TOGBankClassic_Inventory_Sync
	end)

	local function query()
		for _, m in ipairs(sent) do
			if m.channel == "QUERY" then return m end
		end
	end

	it("carries the held canon, the alt, and goes to the peer on the QUERY channel at ALERT", function()
		hold(BANKER, C(T, 0x20), T)
		assert.is_true(Sync:RequestFrom(BANKER, BANKER))
		local q = query()
		assert.is_table(q, "no query went out on the host")
		assert.equal(TOGBankClassic_Core:WhisperAddress(BANKER), q.target, "addressed by a rule other than SendWhisper's")
		assert.equal("WHISPER", q.dist)
		assert.equal("inv", q.body.type)
		assert.equal(C(T, 0x20), q.body.hash, "the provider cannot see what version we hold")
		assert.equal(T, q.body.version)
		assert.equal(BANKER, q.body.keys.alt, "the provider cannot see which alt we want")
	end)

	-- Peer review F4: ONE address rule for every directed send. SendWhisper always stripped the realm
	-- for a same-realm target; the host's sends used to hand over the normalized Name-Realm, so a
	-- handshake and its reply were addressed by two rules and could disagree in game.
	it("addresses the host's sends by SendWhisper's rule: bare for same-realm, full for cross-realm", function()
		local Core = TOGBankClassic_Core
		assert.equal("Bankchar", Core:WhisperAddress("Bankchar-Testrealm"))
		assert.equal("Faraway-Otherrealm", Core:WhisperAddress("Faraway-Otherrealm"), "a cross-realm target must keep its realm")
		assert.equal("Bankchar", Core:WhisperAddress("Bankchar"), "a bare name is already an address")
		hold(BANKER, C(T, 0x20), T)
		Sync:RequestFrom("Faraway-Otherrealm", BANKER)
		assert.equal("Faraway-Otherrealm", query().target)
	end)

	it("claims no version when we hold a canon but no rows for it (a hash-list stub)", function()
		TOGBankClassic_Guild.Info.alts[BANKER] = {
			name = BANKER, money = 0, version = T, inventoryHashV2 = C(T, 0x20), inventoryUpdatedAt = T,
		}
		Sync:RequestFrom(BANKER, BANKER)
		assert.equal(0, query().body.hash,
			"a stub's canon was named as a baseline -- a chain applied over nothing produces nothing")
	end)

	it("claims no version when we hold none, and on a forced-full request", function()
		hold(BANKER, nil, T)
		Sync:RequestFrom(BANKER, BANKER)
		assert.equal(0, query().body.hash)

		sent[1] = nil
		hold(BANKER, C(T, 0x20), T)
		Sync:RequestFrom(BANKER, BANKER, true)
		assert.equal(0, query().body.hash,
			"a forced-full request still claimed a version, so a provider holding that version " ..
			"would answer no-change to a request that asked for everything")
	end)

	-- A refused chain marks the alt for a full request (Sync:ReceiveChain); the mark is consumed by
	-- the next request, whichever peer it goes to, and only once.
	it("honours and consumes a standing forced-full mark", function()
		hold(BANKER, C(T, 0x20), T)
		TOGBankClassic_Guild.forceFullRequests = { [BANKER] = true }
		Sync:RequestFrom(BANKER, BANKER)
		assert.equal(0, query().body.hash, "the standing mark was ignored")
		assert.is_nil(TOGBankClassic_Guild.forceFullRequests[BANKER], "the mark was not consumed")

		sent[1] = nil
		Sync:RequestFrom(BANKER, BANKER)
		assert.equal(C(T, 0x20), query().body.hash, "the mark outlived the request it was for")
	end)

	-- The host refuses a send before it reaches the transport when its roster guard says the peer
	-- is offline. That guard reads the LibGuildRoster instance DeltaSync captured at file load,
	-- which in this one-Lua-state suite is not the instance standUpClient just rebuilt -- so the
	-- refusal is produced at the host's own seam rather than by flipping a roster flag the library
	-- would not see. What is under test is RequestFrom's handling of the verdict, not the guard.
	it("reports a refused send", function()
		hold(BANKER, C(T, 0x20), T)
		local host = TOGBankClassic_Core:DeltaHost()
		host.SendMessage = function() return false end
		local ok = Sync:RequestFrom(BANKER, BANKER)
		host.SendMessage = nil
		assert.is_false(ok)
		assert.is_nil(query(), "a refused send still reached the transport")
	end)
end)
