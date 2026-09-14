-- FULL SYNC, END TO END, ACROSS WHOLE CLIENTS.
--
-- The operator, 2026-09-11: "you need COMPREHENSIVE end to end testing in the test harness. FULL
-- SYNC, not just pieces." Every other spec drives one client and hands it bytes. This one stands up
-- a GUILD -- bankers and viewers, each a whole client with its own libraries, store, roster, host and
-- P2P state (Tests/env_fleet.lua) -- and lets them talk: the login broadcast, the offers it draws,
-- the banker-number table travelling to a client that lacks it, the version query, the dispatch,
-- the handshake, the data leg on the DeltaSync host (chain or snapshot), the completion, the slot
-- release, the catch-up cycle when the first round learnt nothing, the send queue when a provider is
-- at capacity, and a relay serving the author's chain on. Time passes in one-second ticks; nothing
-- below reaches into a peer's tables to make anything happen -- what a client holds at the end is
-- what the wire gave it.
--
-- The one seam is the bus (env_fleet's header): whole messages, no chunking, delivered in order.
package.path = "./Tests/?.lua;" .. package.path
local F   = require("env_fleet")
local env = F.env

local BANK, BANK2, V1, V2, V3, V4 = "Bankchar", "Otherbanker", "Viewer", "Secondviewer", "Thirdviewer", "Fourthviewer"

--- Twenty rows, one of them variable, so a one-row change is visibly smaller than the whole.
local function bank(changed)
	local rows = {}
	for i = 1, 20 do rows[#rows + 1] = { id = 1000 + i, count = 5 } end
	rows[7].count = changed or 5
	return rows
end

--- A guild: one banker with a client, one banker whose account is never on, and viewers.
local function guild(viewers)
	local members = {
		{ name = BANK,  note = "gbank", client = true, money = 100 },
		{ name = BANK2, note = "gbank" },
	}
	for _, v in ipairs(viewers) do members[#members + 1] = { name = v, client = true } end
	return F.new(members)
end

local function noErrors(c)
	local errs = F.output(c, "Error")
	assert.same({}, errs, c.name .. " raised an Error during the sync")
end

local function syncedTo(viewer, banker)
	local want, wantMoney = F.held(banker, BANK)
	local got, gotMoney = F.held(viewer, BANK)
	assert.same(want, got, viewer.name .. " does not hold what " .. banker.name .. " holds")
	assert.equal(wantMoney, gotMoney, viewer.name .. "'s money for the banker differs")
	local theirs, ours = F.record(banker, BANK), F.record(viewer, BANK)
	assert.is_table(ours, viewer.name .. " has no record for the banker")
	assert.equal(theirs.inventoryHashV2, ours.inventoryHashV2, viewer.name .. " does not hold the author's canon")
	assert.equal(theirs.inventoryHash, ours.inventoryHash, viewer.name .. " does not hold the author's revision-1 hash")
	assert.equal(theirs.inventoryUpdatedAt, ours.inventoryUpdatedAt, viewer.name .. " does not hold the author's publish time")
end

local function quiet(c)
	local P2P = c.G.TOGBankClassic_P2PSession
	assert.same({}, P2P.sessionsByAlt, c.name .. " still has a P2P session open")
	assert.equal(0, P2P:GetActiveSendTotal(), c.name .. " still holds a send slot")
	assert.equal(0, #(P2P.sendQueue or {}), c.name .. " still has requesters queued")
end

describe("FULL SYNC: a banker publishes, a viewer that holds nothing ends up holding it", function()
	it("banker online first: the viewer's login broadcast draws the offer and the snapshot lands", function()
		local c = guild({ V1 })
		local A, V = c[BANK], c[V1]

		F.scan(A, bank(5), { bank = { { id = 2000, count = 3 } }, money = 100 })
		local rec = F.record(A, BANK)
		assert.is_string(rec.inventoryHashV2, "the banker's scan minted no canon")
		assert.equal(21, (function() local n = 0 for _ in pairs(F.held(A, BANK)) do n = n + 1 end return n end)())
		-- The banker's account owns a banker, so it numbers EVERY banker on the roster (P2P-035),
		-- including the one whose account is never online.
		local BN = A.G.TOGBankClassic_BankerNumbers
		assert.is_string(BN:NumberOf(BANK .. "-Testrealm"), "the banker did not number itself")
		assert.is_string(BN:NumberOf(BANK2 .. "-Testrealm"), "the offline banker was not numbered by the account that could")

		F.login(A)
		F.tick(2)
		-- The viewer heard the broadcast but could not name its numbers, so it asked for the table.
		assert.equal(1, #F.sent({ from = V1, type = "numbers-request" }), "the viewer did not ask for the banker numbers")
		assert.equal(1, #F.sent({ from = BANK, type = "numbers-reply" }))
		assert.equal(BN:Version(), V.G.TOGBankClassic_BankerNumbers:Version(), "the viewer did not adopt the table")

		F.login(V)
		F.tick(70)   -- collect window (60) + version query (5) + handshake + data

		syncedTo(V, A)
		assert.equal(1, #F.sent({ type = "hash-offer2", from = BANK, to = V1 }), "the banker did not offer by number")
		-- A bare offer names WHO, not WHAT: the version query settles what is held before any request.
		assert.equal(1, #F.sent({ type = "ver-query", from = V1, to = BANK }), "the viewer did not ask which version the offerer holds")
		assert.equal(1, #F.sent({ type = "ver-reply", from = BANK, to = V1 }))
		local req = F.sent({ type = "sync-request", from = V1 })
		assert.equal(1, #req, "the viewer did not request")
		assert.equal(rec.inventoryHashV2, req[1].body.canon, "the request did not name the version the query established")
		assert.same({}, F.output(V, "Warn"), "the viewer warned during a clean sync")
		assert.same({}, F.output(A, "Warn"), "the banker warned during a clean sync")
		assert.equal(1, #F.sent({ type = "sync-accept", from = BANK }))
		assert.equal(1, #F.sent({ type = "inv", from = V1 }), "the viewer did not ask on the host's QUERY channel")
		assert.equal(1, #F.sent({ type = "inv-snapshot", from = BANK, to = V1 }), "a viewer holding nothing was not sent the snapshot")
		assert.equal(0, #F.sent({ type = "inv-chain" }))
		-- Data never rides the GUILD channel in a P2P sync; only the two broadcasts did.
		for _, m in ipairs(F.sent({ dist = "GUILD" })) do
			assert.equal("hlb2", m.type, "something other than a hash-list broadcast went to GUILD: " .. tostring(m.type))
		end
		quiet(A); quiet(V)
		noErrors(A); noErrors(V)
	end)

	it("viewer online first: the first round learns nothing but the numbers; catch-up converges", function()
		local c = guild({ V1 })
		local A, V = c[BANK], c[V1]
		F.scan(A, bank(5), { bank = {}, money = 100 })

		F.login(V)
		F.tick(3)
		-- The banker offered, by numbers the viewer could not yet name; the viewer requested the
		-- table and got it. Nothing could be fetched in this round.
		assert.equal(1, #F.sent({ type = "hash-offer2", from = BANK, to = V1 }))
		assert.equal(1, #F.sent({ type = "numbers-reply", from = BANK, to = V1 }))
		assert.equal(0, #F.sent({ type = "sync-request" }))

		F.tick(60)   -- the window closes empty
		assert.equal(0, #F.sent({ type = "sync-request" }), "a request went out with no offer to act on")
		F.tick(50)   -- catch-up (45s) re-broadcasts; the offer now names numbers the viewer holds
		assert.equal(2, #F.sent({ type = "hlb2", from = V1 }), "the catch-up cycle did not re-broadcast")
		F.tick(70)   -- its window, query, handshake, data

		syncedTo(V, A)
		assert.equal(1, #F.sent({ type = "inv-snapshot", from = BANK, to = V1 }))
		quiet(A); quiet(V)
		noErrors(A); noErrors(V)
	end)
end)

describe("FULL SYNC: the delta on the wire, relays, and the send queue", function()
	--- A guild where the banker has published and every viewer given holds that version.
	local function synced(viewers)
		local c = guild(viewers)
		local A = c[BANK]
		F.scan(A, bank(5), { bank = { { id = 2000, count = 3 } }, money = 100 })
		F.login(A)
		F.tick(2)
		for _, v in ipairs(viewers) do F.login(c[v]) end
		F.tick(75)
		for _, v in ipairs(viewers) do syncedTo(c[v], A) end
		return c
	end

	it("a deposit reaches every viewer as ONE LINK, applied and proven, not as the bank again", function()
		local c = synced({ V1, V2 })
		local A, V, W = c[BANK], c[V1], c[V2]
		local before = #F.log
		local canon1 = F.record(A, BANK).inventoryHashV2

		-- The banker deposits: one count changes, the purse changes.
		env.advance(30)
		F.scan(A, bank(9), { bank = { { id = 2000, count = 3 } }, money = 250 })
		local canon2 = F.record(A, BANK).inventoryHashV2
		assert.are_not.equal(canon1, canon2, "the deposit minted no new version")
		assert.equal(canon2, A.G.TOGBankClassic_Inventory_Chain:Newest(F.GUILD, BANK .. "-Testrealm"), "the link was not written at mint")

		-- The banker's next broadcast names the new version; every broadcast is an offer.
		F.login(A)
		F.tick(20)

		syncedTo(V, A); syncedTo(W, A)
		local chains = F.sent({ type = "inv-chain", from = BANK })
		assert.equal(2, #chains, "the banker did not answer both viewers with the chain")
		for _, m in ipairs(chains) do
			assert.equal(1, #m.body.links, "more than one link for one deposit")
			assert.equal(canon1, m.body.links[1][1]); assert.equal(canon2, m.body.links[1][2])
		end
		local snapshots = 0
		for i = before + 1, #F.log do if F.log[i].type == "inv-snapshot" then snapshots = snapshots + 1 end end
		assert.equal(0, snapshots, "a viewer one version behind was sent the whole bank")
		-- What the delta cost against what the snapshot would have, measured on this wire: 284 bytes
		-- against 562 for a 21-row bank when this was written. The reply's fixed cost -- two canons,
		-- the author's three stamps, the envelope -- is ~200 bytes, so the saving is modest on a
		-- twenty-row fixture and grows with the bank; a real banker has hundreds of rows.
		local snapshotBytes = #A.G.TOGBankClassic_Core:SerializeWithChecksum({ type = "inv-snapshot", alt = BANK .. "-Testrealm",
			payload = A.G.TOGBankClassic_Inventory_Sync:SnapshotPayload(BANK .. "-Testrealm") })
		assert.is_true(chains[1].bytes < snapshotBytes * 0.6,
			string.format("the chain reply (%d bytes) is not well under the snapshot (%d)", chains[1].bytes, snapshotBytes))
		-- The viewers kept the author's link, so either can serve it on.
		assert.equal(canon2, V.G.TOGBankClassic_Inventory_Chain:Newest(F.GUILD, BANK .. "-Testrealm"))
		-- STEP 4: the viewers' bank log for this version IS the banker's, row for row -- the same
		-- entries, the same publish time, the same version labels -- because each applied the
		-- author's link rather than deriving anything.
		local function rows(c)
			local out = {}
			for _, e in ipairs(c.G.TOGBankClassic_Log:GetEntries({ bank = BANK .. "-Testrealm" })) do
				if e.toCanon == canon2 then
					out[#out + 1] = table.concat({ e.type, tostring(e.itemID), tostring(e.count or e.money), tostring(e.ts), tostring(e.fromCanon) }, "|")
				end
			end
			table.sort(out)
			return out
		end
		local authors = rows(A)
		assert.equal(2, #authors, "the banker logged something other than one deposit and one money entry")
		assert.same(authors, rows(V), "the viewer's log for this version differs from the banker's")
		assert.same(authors, rows(W))
		quiet(A); quiet(V); quiet(W)
		noErrors(A); noErrors(V); noErrors(W)
	end)

	-- HIDE-001, end to end: the hide is applied at the store write, so it must reach a viewer through
	-- the same mint -> link -> apply path a deposit does -- and showing it again must bring it back.
	it("a banker HIDES an item: the viewer's copy drops it as one link; showing it brings it back", function()
		local c = synced({ V1 })
		local A, V = c[BANK], c[V1]
		A.G.TOGBankClassic_Options.db = { char = {} }   -- the banker's per-character hidden list
		local key = "1007:0:0"
		assert.equal(5, F.held(V, BANK)[key], "precondition: the viewer holds the row about to be hidden")
		local canon1 = F.record(A, BANK).inventoryHashV2

		env.advance(30)
		F.with(A, function() assert.is_true(A.G.TOGBankClassic_Bank:SetHidden(1007, 0, 0, true)) end)
		assert.is_nil(F.held(A, BANK)[key], "the banker's own published set still carries the hidden row")
		local canon2 = F.record(A, BANK).inventoryHashV2
		assert.are_not.equal(canon1, canon2, "hiding minted no new version -- the guild would never be told")

		F.login(A)
		F.tick(20)
		syncedTo(V, A)
		assert.is_nil(F.held(V, BANK)[key], "the viewer still holds the hidden item")
		local chains = F.sent({ type = "inv-chain", from = BANK, to = V1 })
		assert.equal(1, #chains, "the hide did not travel as a delta")
		assert.equal(canon2, chains[1].body.links[1][2])

		-- Shown again: back on the wire, back in the viewer's copy, exact.
		env.advance(30)
		F.with(A, function() assert.is_true(A.G.TOGBankClassic_Bank:SetHidden(1007, 0, 0, false)) end)
		assert.equal(5, F.held(A, BANK)[key])
		F.login(A)
		F.tick(20)
		syncedTo(V, A)
		assert.equal(5, F.held(V, BANK)[key], "the shown item did not come back to the viewer")
		quiet(A); quiet(V)
		noErrors(A); noErrors(V)
	end)

	it("a fulfilment: the withdrawal names the requester on EVERY client, from the author's link alone", function()
		local c = synced({ V1, V2 })
		local A, V, W = c[BANK], c[V1], c[V2]
		local norm, vnorm = BANK .. "-Testrealm", V1 .. "-Testrealm"
		env.defineItem(1007, { name = "Item 1007" })

		-- The viewer places a request with the banker; the mutation reaches everyone.
		F.with(V, function()
			assert.is_true(V.G.TOGBankClassic_Guild:AddRequest({
				date = env.now, requester = vnorm, bank = norm, item = "Item 1007", itemID = 1007,
				quantity = 4, fulfilled = 0, notes = "",
			}))
		end)
		F.tick(2)
		local reqId
		for id, r in pairs(A.G.TOGBankClassic_Guild.Info.requests or {}) do
			if r.itemID == 1007 and r.requester == vnorm then reqId = id end
		end
		assert.is_not_nil(reqId, "the request did not reach the banker")

		-- The banker fills it by mail and later rescans: four fewer of the item.
		F.with(A, function() assert.equal(4, A.G.TOGBankClassic_Guild:FulfillRequestById(reqId, 4, norm)) end)
		F.tick(2)
		env.advance(30)
		F.scan(A, bank(1), { bank = { { id = 2000, count = 3 } }, money = 100 })
		F.login(A)
		F.tick(20)
		syncedTo(V, A); syncedTo(W, A)

		local function withdrawal(client)
			for _, e in ipairs(client.G.TOGBankClassic_Log:GetEntries({ types = { withdraw = true } })) do
				if e.itemID == 1007 then return e end
			end
		end
		for _, client in ipairs({ A, V, W }) do
			local e = withdrawal(client)
			assert.is_table(e, client.name .. " logged no withdrawal")
			assert.equal(4, e.count)
			assert.equal(vnorm, e.to, client.name .. "'s withdrawal does not name the requester it was mailed to")
		end
		-- The link carried it; W never saw the fill event and could not have derived it.
		local chains = F.sent({ type = "inv-chain", from = BANK, to = V2 })
		assert.equal(1, #chains)
		assert.is_not_nil(chains[1].body.links[1][3]:find(vnorm, 1, true), "the requester's name did not ride in the link body")
		noErrors(A); noErrors(V); noErrors(W)
	end)

	-- LOG-MAIL-001 (operator 2026-09-13: "the log should only show the 'deposit' when it's taken from
	-- the mail, not when it's scanned in the inbox. it may sit there and be sent back"): the arrival
	-- is a version (the inbox rows are the bank's data) but NOBODY's deposit; the take is the deposit,
	-- named for the sender, on the banker and -- through the chain link -- on the viewer.
	it("a mail sitting in the inbox is a version but no deposit; taking it is the deposit, naming the sender, on every client", function()
		local c = synced({ V1 })
		local A, V = c[BANK], c[V1]
		env.defineItem(4306, { name = "Silk Cloth" })
		local function deposits(client)
			local out = {}
			for _, e in ipairs(client.G.TOGBankClassic_Log:GetEntries({ types = { deposit = true } })) do
				if e.itemID == 4306 then out[#out + 1] = e end
			end
			return out
		end
		-- The viewer mailed the banker twelve Silk Cloth; the banker opens the mailbox (the client's
		-- inbox update is read) and closes it without taking anything: a rescan with the mail rows.
		env.wow.mail = { { sender = V1, subject = "donation", items = { { name = "Silk Cloth", id = 4306, count = 12,
			link = "|cffffffff|Hitem:4306:0:0:0:0:0:0:0:60|h[Silk Cloth]|h|r" } } } }
		F.with(A, function()
			A.G.TOGBankClassic_MailInventory:NoteInbox()
			A.G.TOGBankClassic_MailInventory.hasUpdated = true
		end)
		env.advance(30)
		F.scan(A, bank(5), { bank = { { id = 2000, count = 3 } }, money = 100 })
		F.with(A, function() A.G.TOGBankClassic_MailInventory:CloseInbox() end)
		local sitting = F.record(A, BANK).inventoryHashV2
		assert.equal(12, (F.held(A, BANK))["4306:0:0"], "the mail row did not enter the banker's record set")
		F.login(A)
		F.tick(20)
		syncedTo(V, A)
		assert.equal(sitting, F.record(V, BANK).inventoryHashV2, "the viewer did not receive the version with the inbox rows")
		assert.equal(0, #deposits(A), "the banker logged a deposit for a mail still sitting in the inbox")
		assert.equal(0, #deposits(V), "the viewer logged a deposit for a mail still sitting in the banker's inbox")

		-- The banker comes back, TAKES the attachment (the inbox update after the take shows it gone),
		-- closes the mailbox: the twelve are in the bags now, and THAT is the deposit, from V1.
		F.with(A, function() A.G.TOGBankClassic_MailInventory:NoteInbox() end)   -- the open: still there
		env.wow.mail = {}
		F.with(A, function()
			A.G.TOGBankClassic_MailInventory:NoteInbox()                          -- after the take: gone
			A.G.TOGBankClassic_MailInventory.hasUpdated = true
		end)
		env.advance(30)
		local bags = bank(5); bags[#bags + 1] = { id = 4306, count = 12 }
		F.scan(A, bags, { bank = { { id = 2000, count = 3 } }, money = 100 })
		F.with(A, function() A.G.TOGBankClassic_MailInventory:CloseInbox() end)
		assert.equal(12, (F.held(A, BANK))["4306:0:0"], "the take changed the count the banker holds")
		local taken = F.record(A, BANK).inventoryHashV2
		assert.are_not.equal(sitting, taken, "the take did not mint a version (the mail hash moved)")
		local before = #F.log
		F.login(A)
		F.tick(20)
		syncedTo(V, A)
		-- The take's link has EMPTY changes (mail -> bags leaves the merged set identical). Peer Review
		-- on 6f421e806c84: DeltaSync's ApplyStructuredDelta refuses `changes = nil` and no-ops on
		-- `changes = {}` (DeltaOperations.lua:518), so what matters is what the WIRE carries. This
		-- reads the bytes the bus delivered: the link went as a chain, its serialized body decodes
		-- to an empty `changes` TABLE, and the viewer applied it -- no snapshot fallback was needed.
		local chains = F.sent({ type = "inv-chain", from = BANK, to = V1 })
		local link = chains[#chains] and chains[#chains].body.links[1]
		assert.is_table(link, "the take did not travel as a chain link")
		assert.equal(sitting, link[1]); assert.equal(taken, link[2])
		local ok, body = A.G.TOGBankClassic_Core:Deserialize(link[3])
		assert.is_true(ok, "the link body on the wire does not deserialize")
		assert.is_table(body.changes, "the empty changes table was dropped on the wire -- the live library refuses a nil")
		assert.is_nil(next(body.changes), "the take's link carries changes; mail -> bags should leave the set identical")
		assert.is_table(body.log, "the take's link carries no log window -- the viewer would have nothing to apply")
		for i = before + 1, #F.log do
			assert.are_not.equal("inv-snapshot", F.log[i].type, "the viewer fell back to a snapshot for a no-op link")
		end
		assert.equal(taken, V.G.TOGBankClassic_Inventory_Chain:Newest(F.GUILD, BANK .. "-Testrealm"), "the viewer did not apply and keep the no-op link")
		for _, client in ipairs({ A, V }) do
			local found = deposits(client)
			assert.equal(1, #found, client.name .. " logged " .. #found .. " deposit(s) for the take, not one")
			assert.equal(12, found[1].count)
			assert.equal(V1, found[1].from, client.name .. "'s deposit does not name the sender")
		end
		noErrors(A); noErrors(V)
	end)

	it("a relay serves the author's chain to a viewer one version behind when the author is offline", function()
		local c = synced({ V1, V2 })
		local A, V, W = c[BANK], c[V1], c[V2]
		local canon1 = F.record(A, BANK).inventoryHashV2

		-- Only V learns the deposit: W is offline for it.
		F.offline(W)
		env.advance(30)
		F.scan(A, bank(9), { bank = { { id = 2000, count = 3 } }, money = 250 })
		local canon2 = F.record(A, BANK).inventoryHashV2
		F.login(A)
		F.tick(20)
		syncedTo(V, A)
		assert.equal(canon1, F.record(W, BANK).inventoryHashV2, "the offline viewer learnt the version anyway")

		-- The author goes away; W comes back and broadcasts what it holds.
		F.offline(A)
		F.online(W)
		local before = #F.log
		F.login(W)
		F.tick(75)

		syncedTo(W, V)
		assert.equal(canon2, F.record(W, BANK).inventoryHashV2)
		local relayed = F.sent({ type = "inv-chain", from = V1, to = V2 })
		assert.equal(1, #relayed, "the relay did not serve the chain")
		assert.equal(canon1, relayed[1].body.links[1][1]); assert.equal(canon2, relayed[1].body.links[1][2])
		for i = before + 1, #F.log do
			assert.are_not.equal(BANK, F.log[i].from.name, "the offline author sent something")
		end
		-- Peer review B5: the roster READS offline now (env_fleet.F.presence sends the system line),
		-- so Core:SendWhisper's gate refuses a handshake to the author up front. Under the old
		-- fixture the roster still read ONLINE, the request went out, the bus dropped it and the
		-- scenario passed on the TIMEOUT path instead -- the presence read at Core.lua:55 is
		-- load-bearing, and this is the assertion that goes red under the old fixture.
		for i = before + 1, #F.log do
			local m = F.log[i]
			local target = type(m.target) == "string" and m.target:match("^([^%-]+)") or m.target
			assert.is_false(m.type == "sync-request" and target == BANK,
				"a sync-request was sent to the author the roster says is offline")
		end
		quiet(V); quiet(W)
		noErrors(V); noErrors(W)
	end)

	it("four cold viewers at once: three are served, the fourth waits in the queue and is served next", function()
		local c = guild({ V1, V2, V3, V4 })
		local A = c[BANK]
		F.scan(A, bank(5), { bank = { { id = 2000, count = 3 } }, money = 100 })
		F.login(A)
		F.tick(2)
		-- A BULK send takes time to drain on a real client; here it holds the slot 10 seconds.
		F.bulkDrain = 10
		for _, v in ipairs({ V1, V2, V3, V4 }) do F.login(c[v]) end
		F.tick(66)

		local queued = F.sent({ type = "sync-queued", from = BANK })
		assert.equal(1, #queued, "with three slots and four requesters, exactly one should have been queued")
		local P2P = A.G.TOGBankClassic_P2PSession
		assert.equal(3, P2P:GetActiveSendTotal(), "the provider is not holding three slots while three snapshots drain")

		F.tick(30)   -- the drains complete, the queue is served, its drain completes
		for _, v in ipairs({ V1, V2, V3, V4 }) do syncedTo(c[v], A) end
		assert.equal(4, #F.sent({ type = "inv-snapshot", from = BANK }))
		quiet(A)
		for _, v in ipairs({ V1, V2, V3, V4 }) do quiet(c[v]); noErrors(c[v]) end
		noErrors(A)
	end)

	it("a viewer whose version fell out of the chain window is sent the snapshot, and is exact afterwards", function()
		local c = synced({ V1 })
		local A, V = c[BANK], c[V1]
		local Chain = A.G.TOGBankClassic_Inventory_Chain
		-- Twenty-six deposits while the viewer is away: the window holds twenty-five.
		F.offline(V)
		for i = 1, 26 do
			env.advance(60)
			F.scan(A, bank(5 + i), { bank = { { id = 2000, count = 3 } }, money = 100 + i })
		end
		local canonN = F.record(A, BANK).inventoryHashV2
		assert.equal(canonN, Chain:Newest(F.GUILD, BANK .. "-Testrealm"))
		assert.equal(25, #Chain:Links(F.GUILD, BANK .. "-Testrealm"), "the window did not cap at 25")

		local before = #F.log
		F.online(V)
		F.login(V)
		F.tick(75)
		syncedTo(V, A)
		local snapshots, chains = 0, 0
		for i = before + 1, #F.log do
			if F.log[i].type == "inv-snapshot" then snapshots = snapshots + 1 end
			if F.log[i].type == "inv-chain" then chains = chains + 1 end
		end
		assert.equal(1, snapshots, "a viewer outside the window was not sent the snapshot")
		assert.equal(0, chains)
		quiet(A); quiet(V)
		noErrors(A); noErrors(V)
	end)

	it("a corrupted link on a relay is REFUSED end to end, and the catch-up fetches the snapshot instead", function()
		local c = synced({ V1, V2 })
		local A, V, W = c[BANK], c[V1], c[V2]
		local norm = BANK .. "-Testrealm"

		-- Only V learns the deposit, then the author leaves; V is the only holder of v2.
		F.offline(W)
		env.advance(30)
		F.scan(A, bank(9), { bank = { { id = 2000, count = 3 } }, money = 250 })
		local canon2 = F.record(A, BANK).inventoryHashV2
		F.login(A); F.tick(20)
		syncedTo(V, A)
		F.offline(A)

		-- V's copy of the author's link is damaged in its SavedVariables: the count inside the body.
		local Chain = V.G.TOGBankClassic_Inventory_Chain
		local links = Chain:Links(F.GUILD, norm)
		assert.equal(1, #links)
		local tampered = links[1].body:gsub("%^N9%^", "^N8^", 1)
		assert.are_not.equal(links[1].body, tampered, "fixture: the count was not found in the body")
		Chain:Clear(F.GUILD, norm)
		Chain:Append(F.GUILD, norm, { { parent = links[1].parent, canon = links[1].canon, body = tampered } })

		F.online(W)
		local before = #F.log
		F.login(W)
		F.tick(70)
		-- Round one: V served the (damaged) chain, W refused it and its session failed.
		local firstChain
		for i = before + 1, #F.log do if F.log[i].type == "inv-chain" then firstChain = F.log[i] end end
		assert.is_table(firstChain, "the relay did not serve its chain")
		assert.are_not.equal(canon2, F.record(W, BANK).inventoryHashV2, "a chain that does not hash to the canon was APPLIED")
		assert.is_true(W.G.TOGBankClassic_Guild.forceFullRequests[norm] == true, "the refusal did not mark the alt for a full request")

		-- Round two: the catch-up broadcast, the offer again, and this time the request claims no
		-- baseline, so the relay answers with the snapshot.
		F.tick(130)
		syncedTo(W, V)
		assert.equal(canon2, F.record(W, BANK).inventoryHashV2)
		local snapshotsToW = 0
		for i = before + 1, #F.log do
			if F.log[i].type == "inv-snapshot" and F.log[i].from == V then snapshotsToW = snapshotsToW + 1 end
		end
		assert.equal(1, snapshotsToW, "the fallback snapshot did not arrive exactly once")
		assert.is_nil(W.G.TOGBankClassic_Guild.forceFullRequests[norm], "the forced-full mark outlived the request it was for")
		quiet(V); quiet(W)
		noErrors(V); noErrors(W)
	end)

	it("two banker accounts number the roster identically, and a viewer ends up holding both banks", function()
		local c = F.new({
			{ name = BANK,  note = "gbank", client = true, money = 100 },
			{ name = BANK2, note = "gbank", client = true, money = 7 },
			{ name = V1, client = true },
		})
		local A, B, V = c[BANK], c[BANK2], c[V1]
		F.scan(A, bank(5), { bank = { { id = 2000, count = 3 } }, money = 100 })
		F.scan(B, { { id = 3001, count = 2 }, { id = 3002, count = 20 } }, { bank = {}, money = 7 })
		-- Both accounts own a banker; both minted the whole roster, alphabetically, from 1.
		local BNa, BNb = A.G.TOGBankClassic_BankerNumbers, B.G.TOGBankClassic_BankerNumbers
		assert.equal(BNa:NumberOf(BANK .. "-Testrealm"), BNb:NumberOf(BANK .. "-Testrealm"), "the two accounts numbered the same banker differently")
		assert.equal(BNa:NumberOf(BANK2 .. "-Testrealm"), BNb:NumberOf(BANK2 .. "-Testrealm"))
		assert.are_not.equal(BNa:NumberOf(BANK .. "-Testrealm"), BNa:NumberOf(BANK2 .. "-Testrealm"))

		F.login(A); F.login(B)
		F.tick(70)
		-- Each banker learnt the other's bank from the other's broadcast (every broadcast is an offer).
		local wantB = F.held(B, BANK2)
		assert.same(wantB, (F.held(A, BANK2)), "banker A did not receive banker B's bank")
		assert.same((F.held(A, BANK)), (F.held(B, BANK)), "banker B did not receive banker A's bank")

		F.login(V)
		F.tick(75)
		syncedTo(V, A)
		local gotB, gotBMoney = F.held(V, BANK2)
		assert.same(wantB, gotB, "the viewer did not receive the second bank")
		assert.equal(7, gotBMoney)
		assert.equal(F.record(B, BANK2).inventoryHashV2, F.record(V, BANK2).inventoryHashV2)
		-- Two alts, two peers: dispatched in parallel, one session with each (P2P-033).
		assert.equal(2, #F.sent({ type = "sync-request", from = V1 }))
		quiet(A); quiet(B); quiet(V)
		noErrors(A); noErrors(B); noErrors(V)
	end)

	it("a manual share broadcasts the snapshot to GUILD and every viewer applies it through the same path", function()
		local c = synced({ V1, V2 })
		local A, V, W = c[BANK], c[V1], c[V2]
		env.advance(30)
		F.scan(A, bank(9), { bank = { { id = 2000, count = 3 } }, money = 250 })
		local canon2 = F.record(A, BANK).inventoryHashV2
		local before = #F.log
		F.with(A, function() A.G.TOGBankClassic_Guild:SendAltData(BANK .. "-Testrealm") end)
		F.tick(2)
		local shares = F.sent({ prefix = "togbank-d4", from = BANK, dist = "GUILD" })
		assert.equal(1, #shares, "the manual share did not broadcast on togbank-d4")
		syncedTo(V, A); syncedTo(W, A)
		assert.equal(canon2, F.record(V, BANK).inventoryHashV2)
		-- Nobody asked for anything: the broadcast carried the data.
		for i = before + 1, #F.log do
			assert.are_not.equal("inv", F.log[i].type, "a viewer requested after the share delivered the version")
		end
		noErrors(A); noErrors(V); noErrors(W)
	end)

	it("a shared account on two PCs: the PC that was behind fetches the newest version as its diff base, so its link connects and its log is its own moves", function()
		local c = guild({ V1, V2 })
		local PC1, V, W = c[BANK], c[V1], c[V2]
		local norm = BANK .. "-Testrealm"
		-- The same character on a second machine, with its own (empty) saved data, logged out for now.
		local PC2 = F.newClient(BANK, { money = 100, offline = true })

		-- PC2 plays first: v1 reaches the viewers.
		F.offline(PC1); F.online(PC2)
		F.scan(PC2, bank(5), { bank = { { id = 2000, count = 3 } }, money = 100 })
		local canon1 = F.record(PC2, BANK).inventoryHashV2
		F.login(PC2); F.tick(2)
		F.login(V); F.login(W); F.tick(75)
		syncedTo(V, PC2); syncedTo(W, PC2)

		-- PC2 logs out. PC1 -- which has never seen this bank -- logs in and deposits: v2.
		F.offline(PC2); F.online(PC1)
		env.advance(60)
		F.scan(PC1, bank(9), { bank = { { id = 2000, count = 3 } }, money = 250 })
		local canon2 = F.record(PC1, BANK).inventoryHashV2
		assert.are_not.equal(canon1, canon2)
		F.login(PC1); F.tick(70)
		syncedTo(V, PC1); syncedTo(W, PC1)

		-- PC1 logs out. PC2 is back, still holding v1 in its own file. Its login broadcast advertises
		-- v1 for its own number; the viewers offer newer; the version query names v2 and who holds it.
		F.offline(PC1); F.online(PC2)
		F.login(PC2); F.tick(70)
		assert.equal("behind", (PC2.G.TOGBankClassic_Guild:GetAltStaleness(norm)), "PC2 did not learn it is behind")
		assert.equal(canon1, F.record(PC2, BANK).inventoryHashV2, "PC2 adopted a copy of its own bank -- MULTIPC-001 forbids that")
		local before = #F.log

		-- PC2 opens the bank: the real vault is what PC1 left, plus PC2's own deposit -- one new item
		-- and 50 more copper. The gate passes (everything re-read), so this is v3 -- but first PC2
		-- must fetch v2 as the base to diff from.
		env.advance(30)
		local v3 = bank(9); v3[#v3 + 1] = { id = 2001, count = 1 }
		F.scan(PC2, v3, { bank = { { id = 2000, count = 3 } }, money = 300 })
		assert.equal(canon1, F.record(PC2, BANK).inventoryHashV2, "PC2 published before it had the diff base")
		assert.is_table(PC2.G.TOGBankClassic_Bank.deferred, "the publish was not deferred for the fetch")
		F.tick(20)
		local canon3 = F.record(PC2, BANK).inventoryHashV2
		assert.are_not.equal(canon1, canon3, "PC2 did not publish v3 after the diff base arrived")
		assert.are_not.equal(canon2, canon3)
		-- The fetch was a normal handshake for its own name, answered with the snapshot of v2, never
		-- stored: PC2's store holds what PC2 read.
		local fetched = 0
		for i = before + 1, #F.log do
			if F.log[i].type == "inv-snapshot" and F.log[i].target and F.log[i].target:match("^Bankchar") then fetched = fetched + 1 end
		end
		assert.equal(1, fetched, "the diff base was not fetched exactly once")
		assert.equal(1, (F.held(PC2, BANK))["2001:0:0"])
		-- The link connects to v2, and PC2's log for v3 is PC2's moves only -- not PC1's deposit again.
		local Chain = PC2.G.TOGBankClassic_Inventory_Chain
		local links = Chain:Links(F.GUILD, norm)
		assert.equal(canon2, links[#links].parent, "PC2's link does not connect to the version the guild holds")
		assert.equal(canon3, links[#links].canon)
		local own = {}
		for _, e in ipairs(PC2.G.TOGBankClassic_Log:GetEntries({ bank = norm })) do
			if e.toCanon == canon3 then own[#own + 1] = e.type .. "|" .. tostring(e.itemID or e.money) .. "|" .. tostring(e.count or "") end
		end
		table.sort(own)
		assert.same({ "deposit|2001|1", "money-deposit|50|" }, own, "PC2 logged PC1's moves as its own")

		-- PC2's next broadcast: the viewers, holding v2, are answered with ONE LINK each.
		F.login(PC2); F.tick(20)
		syncedTo(V, PC2); syncedTo(W, PC2)
		local chains = F.sent({ type = "inv-chain", from = BANK })
		assert.equal(2, #chains, "the viewers were not brought to v3 by the chain")
		for _, m in ipairs(chains) do assert.equal(canon2, m.body.links[1][1]) end
		quiet(PC2); quiet(V); quiet(W)
		noErrors(PC2); noErrors(V); noErrors(W)
	end)

	-- MULTIPC-003 END TO END, and it is the operator's own stuck banker of 2026-09-12 reproduced:
	-- bags, vault and mail all read minutes ago, the canon two days old, the tab red. Their words:
	-- "my bags hash should be the latest, but it's saying it's behind".
	--
	-- THE ORDERING IS THE WHOLE TEST. The PC re-reads everything BEFORE it hears that anyone holds
	-- anything newer -- which is the ordinary login order, the first bag event firing while the
	-- guild's broadcasts are still in flight. Its contents have not changed, so the scan takes the
	-- "version unchanged" branch and defers NOTHING; the news then lands with nothing left to act on
	-- it, and before MULTIPC-003 the banker sat red for ever because only a SCAN could mint.
	--
	-- multipc_spec pins this single-client. Nothing drove it across real clients, which is gap (2) of
	-- the two I named in the self-audit; this is that gap closed, and it also turns Peer Review's
	-- "the operator's case is exactly the one that now heals" (thread 7b7efb1f, a code trace) into a
	-- measured fact.
	it("a PC that re-read everything BEFORE it learned it was behind republishes with NO second scan", function()
		local c = guild({ V1, V2 })
		local PC1, V, W = c[BANK], c[V1], c[V2]
		local norm = BANK .. "-Testrealm"
		local PC2 = F.newClient(BANK, { money = 100, offline = true })
		local vault, money = { { id = 2000, count = 3 } }, 100

		-- PC2 publishes v1 and the viewers take it.
		F.offline(PC1); F.online(PC2)
		F.scan(PC2, bank(5), { bank = vault, money = money })
		local canon1 = F.record(PC2, BANK).inventoryHashV2
		F.login(PC2); F.tick(2)
		F.login(V); F.login(W); F.tick(75)
		syncedTo(V, PC2); syncedTo(W, PC2)

		-- PC1 -- same character, its own empty saved data -- logs in later and scans the IDENTICAL
		-- contents. Having no prior record of its own it mints regardless, so v2 is the same bank at
		-- a later time. That is the operator's shape: a newer canon elsewhere, nothing actually moved.
		F.offline(PC2); F.online(PC1)
		env.advance(120)
		F.scan(PC1, bank(5), { bank = vault, money = money })
		local canon2 = F.record(PC1, BANK).inventoryHashV2
		assert.are_not.equal(canon1, canon2, "PC1 did not mint a later version of the same contents")
		F.login(PC1); F.tick(70)
		syncedTo(V, PC1); syncedTo(W, PC1)

		-- PC2 is back. IT SCANS FIRST, BEFORE ANY BROADCAST: every source read, contents unchanged.
		F.offline(PC1); F.online(PC2)
		env.advance(120)
		F.scan(PC2, bank(5), { bank = vault, money = money })
		assert.equal(canon1, F.record(PC2, BANK).inventoryHashV2,
			"precondition: an unchanged re-read must not mint")
		assert.is_nil(PC2.G.TOGBankClassic_Bank.deferred,
			"precondition: an unchanged scan must defer nothing -- that is what makes this the bug")

		-- NOW the guild tells it. Nothing rescans from here on.
		F.login(PC2); F.tick(75)

		local canon3 = F.record(PC2, BANK).inventoryHashV2
		assert.are_not.equal(canon1, canon3,
			"the banker never republished: it learned it was behind and, with no scan following, nothing could mint")
		assert.equal("current", (PC2.G.TOGBankClassic_Guild:GetAltStaleness(norm)),
			"the banker is still showing itself as behind after republishing")
		-- It published what IT read, not the copy it fetched to diff against.
		assert.same((F.held(PC1, BANK)), (F.held(PC2, BANK)))
		-- And the guild adopts it, so the whole cycle closes. The mint STORES; the next broadcast is
		-- what OFFERS it (every other example here does the same -- the deposit one above says so).
		F.login(PC2); F.tick(70)
		syncedTo(V, PC2); syncedTo(W, PC2)
		quiet(PC2); quiet(V); quiet(W)
		noErrors(PC2); noErrors(V); noErrors(W)
	end)

	it("a shared account whose newer version nobody online holds publishes without a base: no link, nothing logged, data exact", function()
		local c = guild({ V1 })
		local PC1, V = c[BANK], c[V1]
		local norm = BANK .. "-Testrealm"
		local PC2 = F.newClient(BANK, { money = 100, offline = true })
		F.offline(PC1); F.online(PC2)
		F.scan(PC2, bank(5), { bank = {}, money = 100 })
		F.login(PC2); F.tick(2); F.login(V); F.tick(75)
		syncedTo(V, PC2)
		F.offline(PC2); F.online(PC1)
		env.advance(60)
		F.scan(PC1, bank(9), { bank = {}, money = 250 })
		local canon2 = F.record(PC1, BANK).inventoryHashV2
		F.login(PC1); F.tick(70)
		syncedTo(V, PC1)
		-- PC2 hears about v2 from the viewer, then the viewer leaves before PC2 can fetch it.
		F.offline(PC1); F.online(PC2)
		F.login(PC2); F.tick(70)
		assert.equal("behind", (PC2.G.TOGBankClassic_Guild:GetAltStaleness(norm)))
		F.offline(V)
		env.advance(30)
		F.scan(PC2, bank(9), { bank = {}, money = 300 })
		F.tick(200)   -- the fetch goes nowhere; the fallback publishes without a base
		local rec = F.record(PC2, BANK)
		assert.are_not.equal(canon2, rec.inventoryHashV2)
		assert.equal(300, rec.money)
		local Chain = PC2.G.TOGBankClassic_Inventory_Chain
		assert.is_nil(Chain:Newest(F.GUILD, norm), "a link was written from a version this PC did not hold")
		for _, e in ipairs(PC2.G.TOGBankClassic_Log:GetEntries({ bank = norm })) do
			assert.are_not.equal(rec.inventoryHashV2, e.toCanon, "something was logged for a version whose parent was never held")
		end
		-- The viewer comes back and is brought current -- by the snapshot, since no link connects.
		F.online(V)
		F.login(PC2); F.tick(75)
		syncedTo(V, PC2)
		noErrors(PC2); noErrors(V)
	end)

	it("a viewer that is already current is answered no-change and asks for nothing more", function()
		local c = synced({ V1 })
		local A, V = c[BANK], c[V1]
		local before = #F.log
		-- A broadcast from the banker that names the version the viewer already holds.
		F.login(A)
		F.tick(70)
		for i = before + 1, #F.log do
			assert.are_not.equal("sync-request", F.log[i].type, "a current viewer requested the version it holds")
		end
		-- And the viewer's own broadcast draws no offer from the banker.
		F.login(V)
		F.tick(70)
		-- One offer in the whole log: the one from the first sync. The second broadcast drew none.
		assert.equal(1, #F.sent({ type = "hash-offer2", from = BANK, to = V1 }), "the banker offered a version the viewer already holds")
		syncedTo(V, A)
		quiet(A); quiet(V)
		noErrors(A); noErrors(V)
	end)
end)

-- SYNCED-001. The operator: "figure out how to ensure the bankers data is being propagated after
-- filling orders, some kind of visual to tell the banker not to log off yet, until data is synced."
-- The banker's client tracks whether the version it just minted has REACHED anyone -- from the
-- transport's delivered verdict, a no-change to a requester that holds it, or a peer naming it --
-- and every window's status bar says so. Driven across whole clients: what the banker's tracker
-- says at the end is what the wire told it.
-- WIRE-SKEW-003: A GUILD MID-UPGRADE, which is the one situation the operator has actually been
-- stuck in and the one shape this fixture could not express -- every client in it ran the same
-- build, so "a peer on the old release" existed only as a hand-primed table in wireskew_spec.
--
-- v1.5.0 retired the togbank-state summary for the DeltaSync QUERY with no wire back-compat. An
-- old peer ACCEPTED by us answers with a summary we no longer read -- it holds one of three send
-- slots for the whole 30-second state-wait and requeues -- and one that accepts US never answers
-- our query, so we sit out the 180-second watchdog. Read off the operator's live guild on
-- 2026-09-12: 22 old requesters queued for one banker, three slots cycling uselessly, and the one
-- capable client starved at queue position 20.
--
-- THE OLD CLIENT'S VERSION IS THE PACKAGER'S TAG FORM, deliberately. WIRE-SKEW-002 was exactly
-- this: the gate shipped, refused nobody, and the log after it was unchanged, because a released
-- client reports the whole git tag and an anchored version parse read every one of them as a dev
-- build. A spec driving "1.4.1" passes while the gate is broken.
describe("FULL SYNC: a guild mid-upgrade -- an old client cannot starve the ones that work", function()
	--- A guild where VIEWER TWO is still on the previous release.
	local function mixedGuild()
		return F.new({
			{ name = BANK, note = "gbank", client = true, money = 100 },
			{ name = V1,   client = true },
			{ name = V2,   client = true, addonVersion = F.OLD_VERSION },
		})
	end

	it("the old client announces the tag-shaped version, and the banker reads it as older", function()
		local c = mixedGuild()
		local A, OLD = c[BANK], c[V2]
		F.scan(A, bank(5), { money = 100 })
		F.login(OLD)
		F.tick(2)
		-- Through the REAL broadcast: what the old client put in `addon`, and what the banker made of it.
		local G = A.G.TOGBankClassic_Guild
		assert.equal(F.OLD_VERSION, G.peerAddonVersions[OLD.norm],
			"the banker did not read the old client's announced version off its broadcast")
		local ok, why = G:PeerSpeaksDataLeg(OLD.norm)
		assert.is_false(ok, "a RELEASED v1.4.1 peer read as capable -- the tag prefix defeated the version match")
		assert.equal(F.OLD_VERSION, why)
		-- And the current clients are not caught by it.
		assert.is_true((G:PeerSpeaksDataLeg(c[V1].norm)), "a current client was refused")
	end)

	it("refuses the old client a send slot at once, so a capable viewer is served instead of queued", function()
		local c = mixedGuild()
		local A, V, OLD = c[BANK], c[V1], c[V2]
		F.scan(A, bank(5), { money = 100 })
		F.login(A); F.login(V); F.login(OLD)
		F.tick(70)

		-- THE POINT: the capable viewer ends up holding the bank.
		syncedTo(V, A)
		-- The old client was told busy rather than given a slot or a queue position -- the two
		-- outcomes that made the live guild grind. Nothing of its is left occupying the banker.
		assert.equal(0, #F.sent({ type = "sync-accept", from = BANK, to = V2 }),
			"the banker accepted a client that cannot complete the data leg")
		quiet(A)
		assert.equal(0, A.G.TOGBankClassic_P2PSession:GetActiveSendTotal(),
			"the banker is still holding a send slot for a peer that can never finish")
		noErrors(A); noErrors(V)
	end)

	it("does not ASK an old holder either -- no 180-second watchdog spent on a peer that cannot answer", function()
		local c = mixedGuild()
		local A, V, OLD = c[BANK], c[V1], c[V2]
		-- The old client is the only other peer that has heard of the bank, and it goes quiet.
		F.scan(A, bank(5), { money = 100 })
		F.login(A); F.login(OLD)
		F.tick(70)
		A.offline = true
		F.presence(A, false)

		F.login(V)
		F.tick(70)
		assert.equal(0, #F.sent({ type = "sync-request", from = V1, to = V2 }),
			"the viewer asked a peer on the old release, and will now sit out the delivery watchdog")
		quiet(V)
		noErrors(V)
	end)

	it("two CURRENT clients still sync normally while an old one is in the guild", function()
		-- The refusal must be aimed at the old peer only: a gate that quietly broke the working
		-- path would look identical in the log the operator was reading.
		local c = mixedGuild()
		local A, V, OLD = c[BANK], c[V1], c[V2]
		F.scan(A, bank(5), { money = 100 })
		F.login(A); F.login(OLD); F.login(V)
		F.tick(70)
		syncedTo(V, A)
		-- A second publish, offered the way every other one is: the banker's next broadcast names
		-- the new version (a scan STORES, a broadcast OFFERS -- the deposit example above).
		env.advance(30)
		F.scan(A, bank(9), { money = 100 })
		F.login(A)
		F.tick(30)
		syncedTo(V, A)
		assert.equal(0, #F.sent({ type = "sync-accept", from = BANK, to = V2 }),
			"the old client was accepted on the second round")
		noErrors(A); noErrors(V)
	end)
end)

describe("FULL SYNC: the banker knows when its update has reached someone (SYNCED-001)", function()
	local function status(c)
		return F.with(c, function() return c.G.TOGBankClassic_Propagation:Status() end)
	end
	local function line(c)
		return F.with(c, function() return c.G.TOGBankClassic_UI_StatusBar.BuildPropagationText() end)
	end

	it("is PENDING from the mint until the viewer's copy has drained, then SYNCED naming that viewer", function()
		local c = guild({ V1 })
		local A, V = c[BANK], c[V1]
		F.scan(A, bank(5), { bank = { { id = 2000, count = 3 } }, money = 100 })
		local state, cur, online = status(A)
		assert.equal("pending", state, "a fresh mint with a viewer online must read as not yet received")
		assert.equal(2, online, "the viewer and the other banker (on the roster, no client)")
		assert.equal(F.record(A, BANK).inventoryHashV2, cur.canon, "the tracker is not on the version just minted")
		assert.is_truthy(line(A):find("stay online", 1, true), "the status line does not tell the banker to stay: " .. line(A))

		F.login(A); F.tick(2)
		assert.equal("pending", (status(A)), "a broadcast going out is not a receipt")
		F.login(V); F.tick(70)
		syncedTo(V, A)
		state, cur = status(A)
		-- Peer review B1: the drain is SENT; the viewer's receipt (sync-done, sent when it stored
		-- the delivery) is what makes it SEEN, and only seen is "synced".
		assert.equal(1, #F.sent({ type = "sync-done", from = V1, to = BANK }), "the viewer did not send a receipt for the delivery it stored")
		assert.equal("synced", state, "the viewer's receipt arrived and the banker still reads pending")
		assert.same({ [V1 .. "-Testrealm"] = "seen" }, cur.holders)
		assert.equal(0, cur.sent, "a peer upgraded to seen is still counted as merely sent")
		assert.is_truthy(line(A):find("confirmed by 1 guildmate", 1, true), line(A))
		assert.equal(1, #F.output(A, "Info"), "the banker was not told, once, that the update had reached someone")
		assert.is_truthy(F.output(A, "Info")[1]:find("safe to log off", 1, true))
		-- The viewer's tracker has nothing to say: it published nothing.
		assert.equal("idle", (status(V)))
		noErrors(A); noErrors(V)
	end)

	it("a new mint resets it: the viewer holding the OLD version is behind again, and the chain reply counts when it drains", function()
		local c = guild({ V1 })
		local A, V = c[BANK], c[V1]
		F.scan(A, bank(5), { bank = { { id = 2000, count = 3 } }, money = 100 })
		F.login(A); F.tick(2); F.login(V); F.tick(70)
		syncedTo(V, A)
		assert.equal("synced", (status(A)))
		-- A deposit: a new version, nobody has it.
		env.advance(30)
		F.scan(A, bank(9), { bank = { { id = 2000, count = 3 } }, money = 100 })
		local state, cur = status(A)
		assert.equal("pending", state, "the previous version's receipt was carried over to a version nobody has")
		assert.equal(0, cur.seen); assert.equal(0, cur.sent)
		F.login(A); F.tick(70)
		syncedTo(V, A)
		assert.equal(1, #F.sent({ type = "inv-chain", from = BANK, to = V1 }), "precondition: the deposit went as a link")
		assert.equal(2, #F.sent({ type = "sync-done", from = V1, to = BANK }), "the CHAIN delivery did not earn a receipt")
		assert.equal("synced", (status(A)), "an applied CHAIN reply's receipt did not count")
		noErrors(A); noErrors(V)
	end)

	it("a peer NAMING the version counts too -- a viewer's login broadcast after the fact, with no data sent", function()
		local c = guild({ V1 })
		local A, V = c[BANK], c[V1]
		F.scan(A, bank(5), { bank = { { id = 2000, count = 3 } }, money = 100 })
		F.login(A); F.tick(2); F.login(V); F.tick(70)
		syncedTo(V, A)
		-- The banker relogs (its tracker is session state and starts empty), rescans with no change:
		-- no new version, nothing to track...
		F.with(A, function() A.G.TOGBankClassic_Propagation:Reset() end)
		assert.equal("idle", (status(A)))
		-- ...but a version minted THIS session that the viewer already holds -- a scan whose canon the
		-- viewer's next broadcast names -- is received the moment that broadcast arrives.
		F.with(A, function()
			A.G.TOGBankClassic_Propagation:OnPublished(A.norm, F.record(A, BANK).inventoryHashV2)
		end)
		assert.equal("pending", (status(A)))
		local before = #F.sent({ type = "inv-snapshot" }) + #F.sent({ type = "inv-chain" })
		F.login(V); F.tick(70)
		assert.equal(before, #F.sent({ type = "inv-snapshot" }) + #F.sent({ type = "inv-chain" }), "data was sent to a viewer that already held it")
		assert.equal("synced", (status(A)), "the viewer's broadcast named our canon and was not counted as a receipt")
		noErrors(A); noErrors(V)
	end)

	it("reads ALONE when no guildmate is online to receive it, and the logout countdown warns either way", function()
		local c = guild({ V1 })
		local A, V = c[BANK], c[V1]
		F.offline(V)
		F.presence({ norm = BANK2 .. "-Testrealm" }, false)   -- the client-less banker's roster entry
		F.scan(A, bank(5), { bank = { { id = 2000, count = 3 } }, money = 100 })
		local state, _, online = status(A)
		assert.equal("alone", state, "a guildmate the roster says is online still counts as able to receive")
		assert.equal(0, online)
		assert.is_truthy(line(A):find("no guildmate online", 1, true), line(A))
		local warned = F.with(A, function() return A.G.TOGBankClassic_Propagation:OnCamping() end)
		assert.is_true(warned)
		assert.equal(1, #F.output(A, "Warn"))
		assert.is_truthy(F.output(A, "Warn")[1]:find("next login", 1, true))
		-- The viewer comes on: pending now, and the countdown says stay.
		F.online(V)
		assert.equal("pending", (status(A)))
		F.with(A, function() A.G.TOGBankClassic_Propagation:OnCamping() end)
		assert.equal(2, #F.output(A, "Warn"))
		assert.is_truthy(F.output(A, "Warn")[2]:find("Stay logged in", 1, true))
		-- And once it has landed, the countdown says nothing.
		F.login(A); F.tick(2); F.login(V); F.tick(70)
		assert.equal("synced", (status(A)))
		assert.is_false(F.with(A, function() return A.G.TOGBankClassic_Propagation:OnCamping() end))
		assert.equal(2, #F.output(A, "Warn"))
	end)
end)
