-- THE CHAIN ON THE WIRE -- THE DELTA RELEASE step 3b (Inventory/Sync.lua over the DeltaSync host).
--
-- The operator, 2026-09-11: "we need to use the P2P deltasync with deltas, so we aren't transmitting
-- a bunch of 'old' stuff". Step 3a wrote the per-version delta at mint (Inventory/Chain.lua,
-- chain_spec); this is the join that puts it on the wire: the AUTHOR mints two versions, a REQUESTER
-- holding the first names its canon, the author answers with the one link after it, the requester
-- applies it, PROVES it against the author's canon, stamps the author's identity verbatim, and can
-- then serve the same link onward.
--
-- TWO WHOLE CLIENTS IN ONE LUA STATE, the way syncwire_spec does it: stand up the author, capture
-- the bytes the host hands the transport, tear down, stand up the requester, feed those bytes into
-- the host's own RESPONSE handler. SEAM DECLARED HONESTLY: Core.SendCommMessage is captured rather
-- than driven through AceComm, so chunking is not covered; what is covered is that the bytes one
-- client's host emits are the bytes the other client's host applies.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local PEER   = "Otherguy-Testrealm"
local THIRD  = "Thirdguy-Testrealm"
local GUILD  = "Testguild"

local Record, Store, Chain, Sync

local function client(who)
	env.standUpClient(who, { { name = BANKER, note = "gbank" }, { name = PEER }, { name = THIRD } }, GUILD)
	Record, Store = TOGBankClassic_Inventory_Record, TOGBankClassic_Inventory_Store
	Chain, Sync = TOGBankClassic_Inventory_Chain, TOGBankClassic_Inventory_Sync
	assert.is_true(TOGBankClassic_Guild:IsBank(BANKER), "precondition: the roster did not come up")
end

local function recs(...)
	local out = {}
	for _, r in ipairs({ ... }) do out[#out + 1] = Record.new(r[1], r[2], r[3], r[4]) end
	return out
end

--- A twenty-row bank, so a one-row change is visibly smaller than the whole.
local function bigBank(changedCount)
	local rows = {}
	for i = 1, 20 do rows[#rows + 1] = { 1000 + i, 5 } end
	rows[7][2] = changedCount or 5
	return recs(unpack(rows))
end

--- Capture what the host hands the transport, decoded, with an instant "delivered" verdict.
local function captureHost()
	local host = TOGBankClassic_Core:DeltaHost()
	local byChannel = {}
	for channel, prefix in pairs(host.prefixes) do byChannel[prefix] = channel end
	local sent = {}
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, body, dist, target, _, cb, arg)
		local _, decoded = TOGBankClassic_Core:DeserializeWithChecksum(body, {})
		sent[#sent + 1] = { channel = byChannel[prefix] or prefix, prefix = prefix, raw = body, body = decoded, dist = dist, target = target }
		if cb then cb(arg, #body, #body, true) end
	end
	return sent, host
end

local function lastResponse(sent)
	for i = #sent, 1, -1 do
		if sent[i].channel == "RESPONSE" then return sent[i] end
	end
end

--- Stand up THE AUTHOR with two published versions: v1 at T, v2 (one count changed, money changed)
--- at T+60, the link between them recorded by Bank:MintVersion exactly as a scan would.
--- Returns what a requester needs to know: both canons, the author's stamps, and the v2 rows.
local function authorWithTwoVersions()
	client("Bankchar")
	local v1, v2 = bigBank(5), bigBank(9)
	local alt = { name = BANKER, money = 100 }
	TOGBankClassic_Guild.Info.alts[BANKER] = alt
	Store:SetAltRecords(GUILD, BANKER, v1, 100)
	TOGBankClassic_Core:StampInventoryHashes(alt, Store:GetAltRecords(GUILD, BANKER), nil, nil, 100, GetServerTime())
	alt.version, alt.inventoryUpdatedAt, alt.mailHash = GetServerTime(), GetServerTime(), 0x77
	local canon1 = alt.inventoryHashV2
	assert.is_string(canon1, "precondition: v1 minted no canon")

	env.advance(60)
	local before = Store:GetAltRecords(GUILD, BANKER)
	Store:SetAltRecords(GUILD, BANKER, v2, 250)
	alt.money = 250
	local after = Store:GetAltRecords(GUILD, BANKER)
	TOGBankClassic_Bank:MintVersion(alt, BANKER, after, 250,
		TOGBankClassic_Core:ComputeInventoryHash(after, nil, nil, 250), before, 100, canon1)
	local canon2 = alt.inventoryHashV2
	assert.is_string(canon2)
	assert.are_not.equal(canon1, canon2, "precondition: v2 did not mint a new canon")
	assert.equal(canon2, Chain:Newest(GUILD, BANKER), "precondition: MintVersion recorded no link")
	return {
		canon1 = canon1, canon2 = canon2, v2 = v2,
		hash = alt.inventoryHash, updatedAt = alt.inventoryUpdatedAt, mailHash = alt.mailHash,
	}
end

--- Stand up a REQUESTER holding v1 under canon1, with a live P2P session for the banker.
local function requesterHoldingV1(a, who)
	client(who or "Otherguy")
	Store:SetAltRecords(GUILD, BANKER, bigBank(5), 100)
	TOGBankClassic_Guild.Info.alts[BANKER] = {
		name = BANKER, money = 100, version = a.updatedAt - 60, inventoryUpdatedAt = a.updatedAt - 60,
		inventoryHash = 0x1, inventoryHashV2 = a.canon1, mailHash = 0x11,
	}
	local P2P = TOGBankClassic_P2PSession
	P2P.sessions, P2P.sessionsByAlt, P2P.activeSessions = {}, {}, 1
	P2P.sessions["sid1"] = { altName = BANKER, peer = BANKER, state = "ACTIVE", timers = {}, candidates = {}, triedPeers = {} }
	P2P.sessionsByAlt[BANKER] = "sid1"
	return P2P
end

local function countOf(id)
	for _, rec in ipairs(Store:GetAltRecords(GUILD, BANKER)) do
		if Record.id(rec) == id then return Record.count(rec) end
	end
end

describe("step 3b: the author answers a held canon with the chain, and the requester proves it", function()
	before_each(env.reset)

	it("author -> requester: one link, applied, verified against the canon, stamped with the author's identity, kept for relay", function()
		-- ---- THE AUTHOR ----
		local a = authorWithTwoVersions()
		local sent = captureHost()
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = a.canon1, version = a.updatedAt - 60, keys = { alt = BANKER } })

		local reply = lastResponse(sent)
		assert.is_table(reply, "the author sent nothing on the RESPONSE channel")
		assert.equal("inv-chain", reply.body.type, "the author sent a snapshot to a requester one version behind")
		assert.equal(BANKER, reply.body.alt)
		assert.equal(1, #reply.body.links)
		assert.equal(a.canon1, reply.body.links[1][1], "the link does not start from the canon the requester named")
		assert.equal(a.canon2, reply.body.links[1][2], "the link does not end at the author's newest canon")
		assert.equal("WHISPER", reply.dist)
		-- Peer review F4: the reply is addressed by the ONE rule the handshake uses (same realm:
		-- bare name), never by the slot's Name-Realm key -- so the two cannot disagree.
		assert.equal("Otherguy", TOGBankClassic_Core:WhisperAddress(PEER), "fixture: PEER is same-realm")
		assert.equal(TOGBankClassic_Core:WhisperAddress(PEER), reply.target)
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal(), "the slot was not released on delivery")

		-- THE POINT OF THE RELEASE, measured: the chain reply for a one-row change against a
		-- twenty-row bank is under half the snapshot it replaces (measured 299 against 639 bytes
		-- when this was written; the reply's fixed cost is two 20-digit canons and the author's
		-- stamps, so the ratio only improves as the bank grows -- a real banker has hundreds of rows).
		local snapshot = TOGBankClassic_Core:SerializeWithChecksum({ type = "inv-snapshot", alt = BANKER, payload = Sync:SnapshotPayload(BANKER) })
		assert.is_true(#reply.raw * 2 < #snapshot,
			string.format("the chain reply (%d bytes) is not under half the snapshot (%d bytes)", #reply.raw, #snapshot))

		-- ---- THE REQUESTER, holding v1 ----
		local P2P = requesterHoldingV1(a)
		local host = TOGBankClassic_Core:DeltaHost()
		assert.equal(5, countOf(1007), "precondition: the requester does not hold v1")

		host:OnComm_RESPONSE(reply.prefix, reply.raw, "WHISPER", BANKER)

		assert.equal(9, countOf(1007), "the changed row was not applied")
		assert.equal(250, Store:GetAltMoney(GUILD, BANKER), "the money change was not applied")
		assert.equal(20, #Store:GetAltRecords(GUILD, BANKER), "a row was lost or invented by the apply")
		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		assert.equal(a.canon2, alt.inventoryHashV2, "the requester does not hold the author's canon after the chain")
		assert.equal(a.hash, alt.inventoryHash, "the author's revision-1 hash was not stamped")
		assert.equal(a.updatedAt, alt.inventoryUpdatedAt, "the author's publish time was not stamped")
		assert.equal(a.mailHash, alt.mailHash, "the author's mail hash was not stamped")
		assert.equal(250, alt.money)
		assert.is_true(Chain:Verify(Store:GetAltRecords(GUILD, BANKER), 250, a.canon2),
			"what the requester now holds does not hash to the author's canon")
		assert.is_nil(P2P.sessionsByAlt[BANKER], "the P2P session was not completed by the chain delivery")
		assert.equal(a.canon2, Chain:Newest(GUILD, BANKER), "the requester did not keep the author's link for relay")

		-- ---- THE REQUESTER AS RELAY: serves the same link on to a third client ----
		local sent2 = captureHost()
		TOGBankClassic_P2PSession:TryAcquireSendSlot(THIRD)
		Sync:OnDataRequest(THIRD, { type = "inv", hash = a.canon1, keys = { alt = BANKER } })
		local relayed = lastResponse(sent2)
		assert.is_table(relayed)
		assert.equal("inv-chain", relayed.body.type, "a relay that applied the chain could not serve it on")
		assert.same(reply.body.links, relayed.body.links, "the relayed link is not the author's, byte for byte")
	end)

	it("requester -> author: on sync-accept the session asks on the QUERY channel, naming the held canon", function()
		local a = authorWithTwoVersions()
		local P2P = requesterHoldingV1(a)
		local sent = captureHost()
		P2P.sessions["sid1"].state = "DISPATCHED"
		P2P:OnSyncAccept("sid1", BANKER)
		local q
		for _, m in ipairs(sent) do if m.channel == "QUERY" then q = m end end
		assert.is_table(q, "no QUERY went out on accept")
		assert.equal(TOGBankClassic_Core:WhisperAddress(BANKER), q.target, "the QUERY is not addressed by the one whisper rule")
		assert.equal("inv", q.body.type)
		assert.equal(a.canon1, q.body.hash)
		assert.equal(BANKER, q.body.keys.alt)
		assert.equal("ACTIVE", P2P.sessions["sid1"].state)

		-- ---- THE BYTES REACH THE AUTHOR'S HOST, and its own QUERY handler routes them to Sync ----
		env.reset()   -- the clock too: the author re-minted from the epoch produces the same canons
		authorWithTwoVersions()
		local sent2, host = captureHost()
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		host:OnComm_QUERY(q.prefix, q.raw, "WHISPER", "Otherguy")
		local reply = lastResponse(sent2)
		assert.is_table(reply, "the author's host did not route the requester's QUERY to Sync:OnDataRequest")
		assert.equal("inv-chain", reply.body.type)
		-- The host handed Sync the BARE sender; the slot is keyed by the full name and released
		-- (below), while the reply is addressed exactly as the requester's own QUERY was.
		assert.equal(TOGBankClassic_Core:WhisperAddress(PEER), reply.target, "the reply and the request are addressed by different rules")
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal())
	end)
end)

describe("step 3b: what the requester REFUSES, and what it does about it", function()
	before_each(env.reset)

	--- The author's genuine chain reply, captured.
	local function authorsReply()
		local a = authorWithTwoVersions()
		local sent = captureHost()
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = a.canon1, keys = { alt = BANKER } })
		return a, lastResponse(sent).body
	end

	local function deliver(body, sender)
		local host = TOGBankClassic_Core:DeltaHost()
		host:OnComm_RESPONSE(host.prefixes.RESPONSE, host:SerializeData(body), "WHISPER", sender or BANKER)
	end

	it("refuses a link whose body was tampered with -- the result does not hash to the canon -- and asks for the snapshot", function()
		local a, body = authorsReply()
		-- Change the count inside the serialized delta: the same field, a different number.
		local tampered = body.links[1][3]:gsub("%^N9%^", "^N8^", 1)
		assert.are_not.equal(body.links[1][3], tampered, "fixture: the count was not found in the body")
		body.links[1][3] = tampered

		local P2P = requesterHoldingV1(a)
		deliver(body)

		assert.equal(5, countOf(1007), "a chain that does not reproduce the author's canon was APPLIED")
		assert.equal(a.canon1, TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2, "the canon moved on a refused chain")
		assert.is_true(TOGBankClassic_Guild.forceFullRequests[BANKER] == true,
			"the alt was not marked for a forced-full request, so the next ask names the same canon and gets the same chain")
		assert.is_nil(P2P.sessionsByAlt[BANKER], "the session was left ACTIVE with nothing coming -- it must fail into catch-up")
		assert.is_nil(Chain:Newest(GUILD, BANKER), "a refused link was kept for relay")
	end)

	it("refuses a chain that does not connect from the canon it holds", function()
		local a, body = authorsReply()
		local P2P = requesterHoldingV1(a)
		TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2 = env.canon(a.updatedAt - 120, 0x5)
		deliver(body)
		assert.equal(5, countOf(1007))
		assert.is_true(TOGBankClassic_Guild.forceFullRequests[BANKER] == true)
		assert.is_nil(P2P.sessionsByAlt[BANKER])
	end)

	it("refuses a chain when it holds no version at all -- there is nothing to apply it to", function()
		local a, body = authorsReply()
		requesterHoldingV1(a)
		TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2 = nil
		deliver(body)
		assert.equal(5, countOf(1007))
		assert.is_true(TOGBankClassic_Guild.forceFullRequests[BANKER] == true)
	end)

	it("discards a chain that ends at a version OLDER than what it holds, without failing anything", function()
		local a, body = authorsReply()
		local P2P = requesterHoldingV1(a)
		-- We already hold something newer than the chain's newest (the ordering rule, HASH-CANON-001 rule 7).
		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		alt.inventoryHashV2 = a.canon1
		alt.inventoryUpdatedAt = a.updatedAt + 600
		-- Held time is read off the CANON when there is one, so give the held canon a later time.
		alt.inventoryHashV2 = env.canon(a.updatedAt + 600, tonumber(a.canon1:sub(11)))
		body.links[1][1] = alt.inventoryHashV2   -- connects, but is older
		deliver(body)
		assert.equal(5, countOf(1007), "an older chain overwrote a newer copy")
		assert.is_nil(TOGBankClassic_Guild.forceFullRequests and TOGBankClassic_Guild.forceFullRequests[BANKER],
			"a stale chain is not a broken one; it must not force a full request")
		assert.is_not_nil(P2P.sessionsByAlt[BANKER], "a stale chain failed the session")
	end)

	it("rejects a chain from a sender the roster does not know", function()
		local a, body = authorsReply()
		requesterHoldingV1(a)
		deliver(body, "Stranger-Elsewhere")
		assert.equal(5, countOf(1007), "a stranger's chain was applied")
		assert.is_nil(TOGBankClassic_Guild.forceFullRequests and TOGBankClassic_Guild.forceFullRequests[BANKER])
	end)

	it("never applies a chain for OUR OWN character (MULTIPC-001)", function()
		local a, body = authorsReply()
		requesterHoldingV1(a, "Bankchar")
		deliver(body, PEER)
		assert.equal(5, countOf(1007), "a delivery for our own character was applied over what this PC read")
	end)

	it("refuses malformed links rather than erroring", function()
		local a, body = authorsReply()
		requesterHoldingV1(a)
		body.links[1] = { a.canon1, a.canon2 }   -- no body
		deliver(body)
		assert.equal(5, countOf(1007))
		assert.is_true(TOGBankClassic_Guild.forceFullRequests[BANKER] == true)
		body.links = "not a table"
		deliver(body)
		assert.equal(5, countOf(1007))
	end)
end)

describe("step 3b: the snapshot on the host, and the chain window", function()
	before_each(env.reset)

	it("a requester holding a canon outside the author's window is sent the snapshot, and applies it through the one store path", function()
		local a = authorWithTwoVersions()
		local sent = captureHost()
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = env.canon(a.updatedAt - 9999, 0x42), keys = { alt = BANKER } })
		local reply = lastResponse(sent)
		assert.equal("inv-snapshot", reply.body.type)
		assert.is_true(TOGBankClassic_Inventory_Wire.isV2(reply.body.payload))

		local P2P = requesterHoldingV1(a)
		-- The requester holds a chain for the banker that the snapshot will leave behind.
		Chain:Append(GUILD, BANKER, { { parent = "p", canon = a.canon1, body = "^1^T^Schanges^T^t^t^^" } })
		local host = TOGBankClassic_Core:DeltaHost()
		host:OnComm_RESPONSE(reply.prefix, reply.raw, "WHISPER", BANKER)

		assert.equal(9, countOf(1007), "the snapshot was not applied")
		assert.equal(a.canon2, TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2)
		assert.is_nil(P2P.sessionsByAlt[BANKER], "the snapshot did not complete the session")
		assert.is_nil(Chain:Newest(GUILD, BANKER), "a chain that no longer connects to the record was kept")
	end)

	it("a snapshot arriving on togbank-d4 (the manual share) takes the same path", function()
		local a = authorWithTwoVersions()
		local payload = TOGBankClassic_Core:SerializeWithChecksum(Sync:SnapshotPayload(BANKER))
		requesterHoldingV1(a)
		TOGBankClassic_Chat:OnCommReceived("togbank-d4", payload, "GUILD", BANKER)
		assert.equal(9, countOf(1007))
		assert.equal(a.canon2, TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2)
	end)

	it("serves the whole run of links after an older held canon, and the receiver applies them in order", function()
		local a = authorWithTwoVersions()
		-- A third version on the author: another row changes.
		env.advance(60)
		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		local before = Store:GetAltRecords(GUILD, BANKER)
		local v3 = bigBank(9); v3[3] = Record.new(1003, 1)
		Store:SetAltRecords(GUILD, BANKER, v3, 250)
		local after = Store:GetAltRecords(GUILD, BANKER)
		TOGBankClassic_Bank:MintVersion(alt, BANKER, after, 250,
			TOGBankClassic_Core:ComputeInventoryHash(after, nil, nil, 250), before, 250, a.canon2)
		local canon3 = alt.inventoryHashV2
		local sent = captureHost()
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = a.canon1, keys = { alt = BANKER } })
		local reply = lastResponse(sent)
		assert.equal("inv-chain", reply.body.type)
		assert.equal(2, #reply.body.links, "the author did not send every link after the held canon")
		assert.equal(canon3, reply.body.links[2][2])

		requesterHoldingV1(a)
		local host = TOGBankClassic_Core:DeltaHost()
		host:OnComm_RESPONSE(reply.prefix, reply.raw, "WHISPER", BANKER)
		assert.equal(9, countOf(1007))
		assert.equal(1, countOf(1003))
		assert.equal(canon3, TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2)
		assert.equal(canon3, Chain:Newest(GUILD, BANKER))
	end)

	-- The ordering rule on the SNAPSHOT path, through the real receive rather than the predicate
	-- alone (inventoryordering_spec pins the predicate; this pins that the path consults it).
	it("discards a STALE snapshot -- authored before the version we hold -- without touching the store", function()
		local a = authorWithTwoVersions()
		local older = TOGBankClassic_Core:SerializeWithChecksum(Sync:SnapshotPayload(BANKER))
		requesterHoldingV1(a)
		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		alt.inventoryHashV2 = env.canon(a.updatedAt + 600, 0x5)   -- we hold something newer
		local host = TOGBankClassic_Core:DeltaHost()
		host:OnComm_RESPONSE(host.prefixes.RESPONSE, host:SerializeData({ type = "inv-snapshot", alt = BANKER,
			payload = select(2, TOGBankClassic_Core:DeserializeWithChecksum(older)) }), "WHISPER", BANKER)
		assert.equal(5, countOf(1007), "an older snapshot overwrote a newer copy")
		assert.equal(env.canon(a.updatedAt + 600, 0x5), alt.inventoryHashV2)
	end)

	it("a delivery cancels the 15s ACK-fallback timer armed for the alt, and reports progress when not muted", function()
		local a = authorWithTwoVersions()
		local payload = Sync:SnapshotPayload(BANKER)
		requesterHoldingV1(a)
		local cancelled = false
		TOGBankClassic_Guild.pendingP2PFallbackTimeouts = { [BANKER] = { Cancel = function() cancelled = true end } }
		local host = TOGBankClassic_Core:DeltaHost()
		host:OnComm_RESPONSE(host.prefixes.RESPONSE, host:SerializeData({ type = "inv-snapshot", alt = BANKER, payload = payload }), "WHISPER", BANKER)
		assert.is_true(cancelled, "the ACK fallback stayed armed after a delivery and will fire AdvanceCandidate on a sync that succeeded")
		assert.is_nil(TOGBankClassic_Guild.pendingP2PFallbackTimeouts[BANKER])

		-- The provider's progress line, when the player has not muted sync progress.
		client("Bankchar")
		Store:SetAltRecords(GUILD, BANKER, bigBank(5), 100)
		TOGBankClassic_Guild.Info.alts[BANKER] = { name = BANKER, money = 100, inventoryHashV2 = a.canon1, inventoryUpdatedAt = a.updatedAt - 60 }
		TOGBankClassic_Options.IsSyncProgressMuted = function() return false end
		captureHost()
		local infos = 0
		TOGBankClassic_Output.Info = function() infos = infos + 1 end
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = 0, keys = { alt = BANKER } })
		assert.equal(1, infos, "no 'Sharing guild bank data' line for an unmuted player")
	end)

	it("releases the slot when the store holds rows but no record exists to describe them", function()
		local a = authorWithTwoVersions()
		TOGBankClassic_Guild.Info.alts[BANKER] = nil   -- rows in the store, nothing to stamp them with
		local sent = captureHost()
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = a.canon1, keys = { alt = BANKER } })
		assert.is_nil(lastResponse(sent), "something was sent for an alt with no record")
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal(), "nothing-to-send kept the slot")
	end)

	it("ignores a chain naming no alt, and a RESPONSE of a type that is not ours", function()
		local a = authorWithTwoVersions()
		requesterHoldingV1(a)
		local host = TOGBankClassic_Core:DeltaHost()
		host:OnComm_RESPONSE(host.prefixes.RESPONSE, host:SerializeData({ type = "inv-chain", links = {} }), "WHISPER", BANKER)
		assert.equal(5, countOf(1007))
		assert.is_false(Sync:OnDataReceived(BANKER, { type = "roster", alt = BANKER }))
		assert.is_false(Sync:OnDataReceived(BANKER, "junk"))
		assert.equal(5, countOf(1007))
	end)

	it("Chain:Append replaces a chain the new links do not connect to", function()
		authorWithTwoVersions()
		local held = Chain:Append(GUILD, BANKER, { { parent = "elsewhere", canon = "z", body = "^1^T^Schanges^T^t^t^^" } })
		assert.equal(1, held, "links that do not connect were joined onto the old chain")
		assert.equal("z", Chain:Newest(GUILD, BANKER))
	end)

	it("a provider whose chain ends BEFORE the version it holds sends the snapshot, not a short chain", function()
		local a = authorWithTwoVersions()
		-- The record moves on without a link (what a snapshot receive does to a relay).
		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		local v3 = bigBank(9); v3[3] = Record.new(1003, 1)
		Store:SetAltRecords(GUILD, BANKER, v3, 250)
		TOGBankClassic_Core:StampInventoryHashes(alt, Store:GetAltRecords(GUILD, BANKER), nil, nil, 250, GetServerTime() + 60)
		assert.are_not.equal(alt.inventoryHashV2, Chain:Newest(GUILD, BANKER), "fixture: the chain still ends at the record")
		local sent = captureHost()
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = a.canon1, keys = { alt = BANKER } })
		assert.equal("inv-snapshot", lastResponse(sent).body.type,
			"a chain that ends before the provider's version was served; the requester would land one version short with a canon that says otherwise")
	end)

	-- CHAIN-003 (peer review F2) REVISED as CHAIN-004: the cap is enforced when the sync-request is
	-- accepted, and a QUERY with no accept used to be dropped. Read off both of the operator's
	-- clients on 2026-09-12: the banker's pull-path ACK took no slot, and a QUERY arriving after
	-- the 30-second state-wait found its accept released -- both dropped here, both then sat out
	-- the 180-second delivery watchdog ("no unclaimed accept -- ignored" / "FAILED (delivery_timeout)").
	-- What the gate protects is the CAP: so a QUERY with no accept is its own accept when there is
	-- room (a slot taken here, released on drain), and refused OUT LOUD when there is none.
	it("answers a QUERY from a requester holding no send slot when there is room, taking the slot for it", function()
		local a = authorWithTwoVersions()
		local host = TOGBankClassic_Core:DeltaHost()
		local pendingCb, pendingArg
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, _, _, _, _, cb, arg)
			if prefix == host.prefixes.RESPONSE then pendingCb, pendingArg = cb, arg end
		end
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal(), "precondition")
		assert.is_true(Sync:OnDataRequest(PEER, { type = "inv", hash = a.canon1, keys = { alt = BANKER } }),
			"the baseline type is ours; another consumer must not answer it either")
		assert.is_function(pendingCb, "a QUERY with no accept and three free slots was dropped (CHAIN-004)")
		assert.equal(1, TOGBankClassic_P2PSession:GetActiveSendTotal(),
			"the reply left without a slot -- a BULK send outside the cap (CHAIN-003's whole point)")
		pendingCb(pendingArg, 1, 1, true)
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal(), "the slot the query took was not released on drain")
	end)

	it("REFUSES a QUERY with no accept when at capacity, naming the alt so the requester advances now", function()
		local a = authorWithTwoVersions()
		local sent = captureHost()
		local whispers = {}
		TOGBankClassic_Core.SendWhisper = function(_, prefix, body, target)
			local _, d = TOGBankClassic_Core:DeserializeWithChecksum(body, {})
			whispers[#whispers + 1] = { prefix = prefix, body = d, target = target }
			return true
		end
		TOGBankClassic_P2PSession:TryAcquireSendSlot("A-Testrealm")
		TOGBankClassic_P2PSession:TryAcquireSendSlot("B-Testrealm")
		TOGBankClassic_P2PSession:TryAcquireSendSlot("C-Testrealm")
		assert.is_true(Sync:OnDataRequest(PEER, { type = "inv", hash = a.canon1, keys = { alt = BANKER } }))
		assert.is_nil(lastResponse(sent), "a fourth concurrent send was admitted")
		assert.equal(3, TOGBankClassic_P2PSession:GetActiveSendTotal())
		assert.equal(1, #whispers, "the requester was left to its 180-second delivery watchdog")
		assert.equal("togbank-rr", whispers[1].prefix)
		assert.equal("sync-busy", whispers[1].body.type)
		assert.equal(BANKER, whispers[1].body.alt, "the refusal does not say which alt, so the requester cannot advance the right session")
		assert.is_nil(whispers[1].body.sessionId, "a QUERY carries no session id; the refusal must not invent one")
	end)

	-- The requester's half of that refusal (P2PSession:OnQueryRefused): only the session waiting on
	-- THAT peer advances, and only while it is ACTIVE (a DISPATCHED one has its own dispatch timeout).
	it("advances the ACTIVE session waiting on the refusing peer, and no other", function()
		local a = authorWithTwoVersions()
		local P2P = requesterHoldingV1(a)
		captureHost()
		local advanced = {}
		P2P.AdvanceCandidate = function(_, sid, reason) advanced[#advanced + 1] = sid .. ":" .. reason end
		P2P:OnQueryRefused(BANKER, THIRD)   -- not the peer the session is on
		assert.same({}, advanced, "a stale refusal from a peer we left advanced the session")
		P2P:OnQueryRefused(BANKER, BANKER)
		assert.same({ "sid1:query_refused" }, advanced)
		P2P.sessions["sid1"].state = "DISPATCHED"
		P2P:OnQueryRefused(BANKER, BANKER)
		assert.equal(1, #advanced, "a DISPATCHED session was advanced by a refusal meant for an earlier accept")
	end)

	-- Peer review A1: ONE accept is ONE reply. A second QUERY inside the window before the first
	-- reply has drained used to pass the gate (the slot was still held) and earn a second BULK send
	-- for one accept. The accept is consumed on the QUERY now, and given back with the slot on drain.
	it("answers one QUERY per accept: a second inside the window is ignored, the next accept is answered", function()
		local a = authorWithTwoVersions()
		local host = TOGBankClassic_Core:DeltaHost()
		local sends = 0
		-- Hold the drain: capture the transport WITHOUT delivering, so the slot stays held.
		local pendingCb, pendingArg
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, _, _, _, _, cb, arg)
			if prefix == host.prefixes.RESPONSE then sends = sends + 1; pendingCb, pendingArg = cb, arg end
		end
		local q = { type = "inv", hash = a.canon1, keys = { alt = BANKER } }
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, q)
		assert.equal(1, sends)
		assert.equal(1, TOGBankClassic_P2PSession:GetActiveSendTotal(), "precondition: the reply has not drained")
		assert.is_true(Sync:OnDataRequest(PEER, q), "still ours to refuse")
		assert.equal(1, sends, "a second QUERY inside one accept's window earned a second BULK send")
		-- Drain: the slot and its claim go back together; a fresh accept is answered again.
		pendingCb(pendingArg, 1, 1, true)
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal())
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, q)
		assert.equal(2, sends, "the claim was not given back with the slot")
	end)

	-- Peer review F3: the drain watcher is keyed `prefix|target`, so TWO replies to ONE requester
	-- in one frame (two accepts, two QUERYs, both queued under AceCommQueue before either has left)
	-- share a key. That is safe only because `host:SendData` hands the message to the transport
	-- SYNCHRONOUSLY inside the call, where the proxy moves the watcher off the table and into that
	-- send's own completion closure -- so the second `WatchHostSend` never overwrites the first. This
	-- drives it: each queued reply must release exactly its own slot, in whichever order they drain.
	it("two replies to one requester queued in one frame each release their own slot on their own drain", function()
		local a = authorWithTwoVersions()
		-- A second bank this client can serve: two accepts for one requester are two ALTS (a session
		-- is per alt), and CHAIN-004 answers one query per requester per alt while a reply is leaving.
		local SECOND = "Otherbank-Testrealm"
		TOGBankClassic_Guild.Info.alts[SECOND] = { name = SECOND, money = 5, version = a.updatedAt, inventoryUpdatedAt = a.updatedAt, inventoryHash = 0x2, inventoryHashV2 = a.canon2, mailHash = 0 }
		Store:SetAltRecords(GUILD, SECOND, recs({ 2000, 1 }), 5)
		local host = TOGBankClassic_Core:DeltaHost()
		local pending = {}
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, _, _, _, _, cb, arg)
			if prefix == host.prefixes.RESPONSE then pending[#pending + 1] = { cb = cb, arg = arg } end
		end
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		Sync:OnDataRequest(PEER, { type = "inv", hash = a.canon1, keys = { alt = BANKER } })
		Sync:OnDataRequest(PEER, { type = "inv", hash = 0, keys = { alt = SECOND } })
		assert.equal(2, #pending, "two accepts for one requester did not earn two replies")
		assert.equal(2, TOGBankClassic_P2PSession:GetActiveSendTotal(), "precondition: neither reply has drained")
		-- Drain the SECOND first: with one shared watcher it would have been the only one to fire,
		-- and the first reply's drain below would then release nothing.
		pending[2].cb(pending[2].arg, 1, 1, true)
		assert.equal(1, TOGBankClassic_P2PSession:GetActiveSendTotal(), "the second reply's drain released more (or less) than its own slot")
		-- A completion that reports twice (a per-chunk transport) fires its watcher ONCE: the
		-- release is count-based, so a second fire here would take the FIRST reply's slot.
		pending[2].cb(pending[2].arg, 1, 1, true)
		assert.equal(1, TOGBankClassic_P2PSession:GetActiveSendTotal(), "a repeated completion released the other reply's slot")
		pending[1].cb(pending[1].arg, 1, 1, true)
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal(), "the first reply's drain found no watcher -- its slot leaked")
	end)
end)
