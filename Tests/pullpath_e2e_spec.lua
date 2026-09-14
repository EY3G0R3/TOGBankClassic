-- CHAIN-004 / P2P-038: THE PULL PATH, JOINED END TO END -- the example that should have existed.
--
-- The operator, 2026-09-12, on the banker's copies never landing on their other client: "your tests
-- should have caught it". They should have. Every spec of the data leg (statesummary, chainwire,
-- syncwire) hand-primed the provider with `TryAcquireSendSlot(PEER)` before sending the QUERY -- it
-- ASSUMED the accept, so the one path that never produced one (the banker's pull-path ACK in
-- Chat.lua) was never driven into Sync:OnDataRequest, and the gate that dropped its QUERY ("no
-- unclaimed accept -- ignored") was pinned as CORRECT by the CHAIN-003 example. This file drives the
-- real handlers on both sides of that ACK and asserts the join: the banker's ACK reserves, the
-- requester's ACK handling asks, and the ask is answered.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local PEER   = "Otherguy-Testrealm"
local THIRD  = "Thirdguy-Testrealm"
local GUILD  = "Testguild"
local C      = env.canon
local T      = 1757000000

local function client(who)
	env.standUpClient(who, { { name = BANKER, note = "gbank" }, { name = PEER }, { name = THIRD } }, GUILD)
end

local function hold(alt, canon, at)
	TOGBankClassic_Guild.Info.alts[alt] = {
		name = alt, money = 0, version = at,
		inventoryHash = 0x10, inventoryHashV2 = canon, inventoryUpdatedAt = at, mailHash = 0,
	}
	TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, alt, { TOGBankClassic_Inventory_Record.new(858, 5) }, 0)
end

--- Every message the client hands the transport, decoded, whichever door it left by.
local function captureAll()
	local host = TOGBankClassic_Core:DeltaHost()
	local byChannel = {}
	for channel, prefix in pairs(host.prefixes) do byChannel[prefix] = channel end
	local sent = {}
	local function record(prefix, body, dist, target)
		local _, decoded = TOGBankClassic_Core:DeserializeWithChecksum(body, {})
		sent[#sent + 1] = { channel = byChannel[prefix] or prefix, prefix = prefix, raw = body, body = decoded, dist = dist, target = target }
	end
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, body, dist, target, _, cb, arg)
		record(prefix, body, dist, target)
		if cb then cb(arg, #body, #body, true) end
	end
	TOGBankClassic_Core.SendWhisper = function(_, prefix, body, target)
		record(prefix, body, "WHISPER", target)
		return true
	end
	return sent
end

local function find(sent, pred)
	for _, m in ipairs(sent) do if pred(m) then return m end end
end

describe("CHAIN-004: the banker's pull-path ACK is an accept -- it reserves, and the QUERY it invites is answered", function()
	local sent, P2P, Sync

	before_each(function()
		env.reset(); client("Bankchar")
		hold(BANKER, C(T, 0x20), T)
		sent = captureAll()
		P2P, Sync = TOGBankClassic_P2PSession, TOGBankClassic_Inventory_Sync
	end)

	local function altRequest(from, expectedHash)
		local body = TOGBankClassic_Core:SerializeWithChecksum({
			type = "alt-request", name = BANKER, requester = from, hashOnly = false,
			expectedHash = expectedHash, requesterMailHash = 0,
		})
		TOGBankClassic_Chat:OnCommReceived("togbank-r", body, "GUILD", from)
	end

	it("ACKs as the banker AND holds a send slot for the requester, with the state-wait armed", function()
		altRequest(PEER, 0x10)
		local ack = find(sent, function(m) return m.prefix == "togbank-rr" and m.body and m.body.type == "alt-request-reply" end)
		assert.is_table(ack, "the banker did not ACK its own bank")
		assert.is_true(ack.body.isBanker)
		assert.equal(1, P2P:GetActiveSendTotal(),
			"the banker's ACK reserved nothing -- the requester's QUERY then has no accept to claim (CHAIN-004)")
		assert.is_true(P2P:IsAwaitingSummary(PEER), "no state-wait: a requester that never asks would hold the slot 210s")
	end)

	it("answers the QUERY that ACK invites -- the join that was never driven", function()
		altRequest(PEER, 0x10)
		-- What the requester's ACK handling sends (asserted as the same shape in the describe below).
		assert.is_true(Sync:OnDataRequest(PEER, { type = "inv", hash = 0, version = 0, keys = { alt = BANKER } }))
		local reply = find(sent, function(m) return m.channel == "RESPONSE" end)
		assert.is_table(reply, "the banker ACKed and then ignored the query it invited")
		assert.equal("inv-snapshot", reply.body.type)
		assert.equal(BANKER, reply.body.alt)
		assert.equal(0, P2P:GetActiveSendTotal(), "the slot the ACK took was not released with the reply")
		assert.is_false(P2P:IsAwaitingSummary(PEER))
	end)

	it("does not ACK at capacity -- the relay rule -- rather than promise a send it cannot make", function()
		P2P:TryAcquireSendSlot("A-Testrealm"); P2P:TryAcquireSendSlot("B-Testrealm"); P2P:TryAcquireSendSlot("C-Testrealm")
		altRequest(PEER, 0x10)
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "alt-request-reply" end),
			"a banker at capacity ACKed; the QUERY would be refused and the requester left to a timeout")
		assert.equal(3, P2P:GetActiveSendTotal())
	end)

	-- The in-flight mark that keeps "one reply per requester per alt" must not outlive the slot's own
	-- safety release: a transport that never reports would otherwise refuse that pair for the whole
	-- session.
	it("forgets an in-flight mark the transport never completed, after the slot's own safety window", function()
		local host = TOGBankClassic_Core:DeltaHost()
		local replies = 0
		TOGBankClassic_Core.SendCommMessage = function(_, prefix)
			if prefix == host.prefixes.RESPONSE then replies = replies + 1 end
			-- no callback: the transport never reports
		end
		P2P:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = 0, keys = { alt = BANKER } })
		assert.equal(1, replies)
		P2P:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = 0, keys = { alt = BANKER } })
		assert.equal(1, replies, "precondition: the second query inside the window was answered")
		env.advance(211)   -- the slot's safety release has fired; the mark is stale
		P2P:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = 0, keys = { alt = BANKER } })
		assert.equal(2, replies, "a stale in-flight mark refused this requester's alt for good")
	end)

	it("still answers a hash-only query without taking a slot -- no data follows it", function()
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "alt-request", name = BANKER, requester = PEER, hashOnly = true })
		TOGBankClassic_Chat:OnCommReceived("togbank-r", body, "GUILD", PEER)
		local ack = find(sent, function(m) return m.body and m.body.type == "alt-request-reply" end)
		assert.is_table(ack)
		assert.is_true(ack.body.hashOnly)
		assert.equal(0, P2P:GetActiveSendTotal(), "a hash-only ACK took a data slot")
	end)
end)

describe("CHAIN-004: the requester's half -- a banker ACK becomes a QUERY on the host, for everything", function()
	local sent

	before_each(function()
		env.reset(); client("Otherguy")
		sent = captureAll()
	end)

	local function bankerAck()
		local ack = TOGBankClassic_Core:SerializeWithChecksum({
			type = "alt-request-reply", name = BANKER, isBanker = true, hasData = true, hashOnly = false,
			expectedHash = 0x10, expectedUpdatedAt = T,
		})
		TOGBankClassic_Chat:OnCommReceived("togbank-rr", ack, "WHISPER", BANKER)
	end

	it("asks the banker for the whole bank on the QUERY channel after its ACK", function()
		bankerAck()
		local q = find(sent, function(m) return m.channel == "QUERY" end)
		assert.is_table(q, "the banker's ACK produced no query")
		assert.equal("inv", q.body.type)
		assert.equal(BANKER, q.body.keys.alt)
		assert.equal(0, q.body.hash, "a requester holding nothing named a baseline")
		assert.equal(TOGBankClassic_Core:WhisperAddress(BANKER), q.target)
	end)

	-- Peer Review F1: the banker's ACK had none of the relay ACK's bookkeeping -- the 5-second "no
	-- response" timer fired anyway (Galdof's log: "banker Alchemyrcp-Azuresong online, did not
	-- answer", under an ACK that had arrived) and nothing watched for the reply.
	it("answers our broadcast's 5-second timer with the banker's ACK, and arms the delivery watch", function()
		local G = TOGBankClassic_Guild
		local catchUps = {}
		TOGBankClassic_P2PSession.ScheduleCatchUp = function(_, why) catchUps[#catchUps + 1] = why end
		G:BroadcastP2PRequest(BANKER, 0x10, T, nil, nil)
		assert.is_table(G.pendingP2PRequests[BANKER], "precondition: the broadcast left nothing pending")
		bankerAck()
		assert.is_nil(G.pendingP2PRequests[BANKER], "the ACK did not answer the pending request")
		env.advance(6)
		assert.same({}, catchUps, "the 5-second 'no response' timer fired under the banker's ACK (F1)")
		assert.is_not_nil(G.pendingP2PFallbackTimeouts[BANKER], "no 'ACKed but never delivered' watch was armed")
		env.advance(15)
		assert.same({ "ack_no_data" }, catchUps, "an ACK that was never followed by data did not reach the catch-up")
	end)

	it("hears an at-capacity refusal with no session and schedules the catch-up (F1)", function()
		local G = TOGBankClassic_Guild
		local catchUps = {}
		TOGBankClassic_P2PSession.ScheduleCatchUp = function(_, why) catchUps[#catchUps + 1] = why end
		G:BroadcastP2PRequest(BANKER, 0x10, T, nil, nil)
		local busy = TOGBankClassic_Core:SerializeWithChecksum({ type = "sync-busy", alt = BANKER, reason = "no_slot" })
		TOGBankClassic_Chat:OnCommReceived("togbank-rr", busy, "WHISPER", BANKER)
		assert.same({ "query_refused" }, catchUps, "the refusal was heard and dropped on the pull path (F1)")
		assert.is_nil(G.pendingP2PRequests[BANKER])
		assert.is_nil(G.pendingP2PTimeouts[BANKER], "the 5-second timer outlived the refusal")
		env.advance(6)
		assert.equal(1, #catchUps, "the cleared request's timer fired anyway")
	end)

	it("Guild:ClearPendingP2PRequest is the one clearing: entry, hashes, marker, both timers", function()
		local G = TOGBankClassic_Guild
		G:BroadcastP2PRequest(BANKER, 0x10, T, nil, nil)
		G.pendingAltRequests = { [BANKER] = true }
		G:ArmAltTimeout("pendingP2PFallbackTimeouts", BANKER, 15, function() end)
		local before = env.pendingTimerCount()
		assert.is_table(G:ClearPendingP2PRequest(BANKER))
		assert.is_nil(G.pendingP2PRequests[BANKER]); assert.is_nil(G.pendingAltRequests[BANKER])
		assert.is_nil(G.expectedHashes[BANKER]); assert.is_nil(G.expectedHashUpdatedAt[BANKER])
		assert.is_nil(G.pendingP2PTimeouts[BANKER]); assert.is_nil(G.pendingP2PFallbackTimeouts[BANKER])
		assert.equal(before - 2, env.pendingTimerCount(), "the two timers were dropped, not cancelled")
		assert.is_nil(G:ClearPendingP2PRequest(BANKER), "a second clearing reported something pending")
	end)
end)

describe("P2P-038: an accept the requester cannot use is withdrawn, and the provider frees its slot", function()
	local sent, P2P

	before_each(function()
		env.reset(); client("Bankchar")
		hold(BANKER, C(T, 0x20), T)
		sent = captureAll()
		P2P = TOGBankClassic_P2PSession
	end)

	it("requester: a late accept for a session already ACTIVE elsewhere sends sync-cancel to that peer", function()
		P2P.sessions, P2P.sessionsByAlt, P2P.activeSessions = {}, {}, 1
		P2P.sessions["sid1"] = { altName = BANKER, peer = THIRD, state = "ACTIVE", timers = {}, candidates = {}, triedPeers = {} }
		P2P.sessionsByAlt[BANKER] = "sid1"
		P2P:OnSyncAccept("sid1", PEER)   -- PEER accepted after we moved on to THIRD
		local cancel = find(sent, function(m) return m.body and m.body.type == "sync-cancel" end)
		assert.is_table(cancel, "the late accept was logged and left; the peer holds a slot for us for 30s (P2P-038)")
		assert.equal("sid1", cancel.body.sessionId)
		assert.equal(PEER, cancel.target)
		assert.equal("ACTIVE", P2P.sessions["sid1"].state, "the live session was disturbed")
	end)

	it("requester: an accept for a session that no longer exists is withdrawn too", function()
		P2P.sessions, P2P.sessionsByAlt = {}, {}
		P2P:OnSyncAccept("gone", PEER)
		local cancel = find(sent, function(m) return m.body and m.body.type == "sync-cancel" end)
		assert.is_table(cancel)
		assert.equal("gone", cancel.body.sessionId)
	end)

	it("provider: sync-cancel naming an accept still waiting on its query releases the slot at once", function()
		assert.is_true(P2P:HandleSyncRequest("sidX", PEER, BANKER, C(T, 0x20)))
		assert.equal(1, P2P:GetActiveSendTotal(), "precondition: the accept took a slot")
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "sync-cancel", sessionId = "sidX" })
		TOGBankClassic_Chat:OnCommReceived("togbank-rr", body, "WHISPER", PEER)
		assert.equal(0, P2P:GetActiveSendTotal(), "the withdrawn accept kept its slot until the 30s state-wait")
		assert.is_false(P2P:IsAwaitingSummary(PEER))
		env.advance(31)
		assert.equal(0, P2P:GetActiveSendTotal(), "the state-wait fired anyway and released a second time")
	end)

	it("provider: sync-cancel after the query arrived changes nothing -- the send is in flight", function()
		local host = TOGBankClassic_Core:DeltaHost()
		local pendingCb, pendingArg
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, _, _, _, _, cb, arg)
			if prefix == host.prefixes.RESPONSE then pendingCb, pendingArg = cb, arg end
		end
		assert.is_true(P2P:HandleSyncRequest("sidY", PEER, BANKER, C(T, 0x20)))
		TOGBankClassic_Inventory_Sync:OnDataRequest(PEER, { type = "inv", hash = 0, keys = { alt = BANKER } })
		assert.is_function(pendingCb, "precondition: no reply left")
		P2P:CancelAccept("sidY", PEER)
		assert.equal(1, P2P:GetActiveSendTotal(), "a cancel after the query released the slot under a send in flight")
		pendingCb(pendingArg, 1, 1, true)
		assert.equal(0, P2P:GetActiveSendTotal())
	end)
end)

describe("P2P-038: the dispatch park holds one item per alt", function()
	before_each(function()
		env.reset(); client("Otherguy")
		captureAll()
	end)

	it("replaces a parked alt's item rather than parking it again on every late offer", function()
		local P2P = TOGBankClassic_P2PSession
		P2P.sessions, P2P.sessionsByAlt, P2P.pendingDispatch = {}, {}, {}
		-- THIRD is busy with us already (one session per peer), so every item naming only THIRD parks.
		P2P.sessions["busy"] = { altName = "X-Testrealm", peer = THIRD, state = "ACTIVE", timers = {}, candidates = {}, triedPeers = {} }
		P2P.sessionsByAlt["X-Testrealm"] = "busy"
		local function item(tag) return { altName = BANKER, candidates = { { peer = THIRD, canon = C(T, 0x20), updatedAt = T } }, tag = tag } end
		P2P:DispatchList({ item(1) })
		P2P:DispatchList({ item(2) })
		P2P:DispatchList({ item(3) })
		assert.equal(1, #P2P.pendingDispatch, "the same alt was parked once per late offer; the park grew without bound")
		assert.equal(3, P2P.pendingDispatch[1].tag, "the OLD candidates were kept over the newest")
	end)
end)
