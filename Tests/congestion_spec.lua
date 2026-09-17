-- CONGESTION-001: THE SYNC ON A CONGESTED CLIENT.
--
-- The operator, 2026-09-15, believing sync was misbehaving in game while every fleet spec was
-- green: "can you simulate congestion in the harness? we should have some congestion tests" --
-- "don't forget we have acecommqueue on top of ace3" -- and, on why: "i HATE timers. i would rather
-- have handshake comms instead of timers whenever possible."
--
-- Every other fleet spec runs on the ORDERED wire: whole messages, delivered in send order. A live
-- client is not that. AceCommQueue lets one message per (prefix, distribution, target) into AceComm
-- at a time; AceComm cuts it into 255-byte chunks on one ChatThrottleLib pipe per prefix; CTL
-- round-robins the pipes a chunk at a time under 800 bytes/s shared with every other addon, and
-- clamps to a tenth of that for five seconds after the player enters the world -- which is exactly
-- when the login cycle runs. So on a real client a one-chunk offer sent AFTER a four-chunk table
-- can leave BEFORE it, a broadcast can take seconds to drain, and any step of the protocol that
-- assumes the wire keeps send order, or that an answer arrives inside a timer, is a step that works
-- in the fleet and fails in a guild. These examples run the same syncs on env_fleet's THROTTLED
-- wire -- the real AceCommQueue, AceComm and ChatThrottleLib per client, despooled by the clock --
-- and pin what the protocol must survive.
package.path = "./Tests/?.lua;" .. package.path
local F = require("env_fleet")
local wow = require("env.wow")

local BANK, V1, V2, V3, V4, V5 = "Bankchar", "Viewer", "Secondviewer", "Thirdviewer", "Fourthviewer", "Fifthviewer"

local function bare(name) return type(name) == "string" and name:match("^([^%-]+)") or name end

local function bank(rows, changed)
	local out = {}
	for i = 1, rows or 20 do out[#out + 1] = { id = 1000 + i, count = 5 } end
	if changed then out[7].count = changed end
	return out
end

--- A guild on the THROTTLED wire: one banker with a client, `extraBankers` bankers whose accounts
--- are never on (they still get numbered, so the table has a size), and viewers.
local function guild(viewers, extraBankers)
	local members = { { name = BANK, note = "gbank", client = true, money = 100 } }
	for i = 1, extraBankers or 1 do members[#members + 1] = { name = "Otherbanker" .. i, note = "gbank" } end
	for _, v in ipairs(viewers) do members[#members + 1] = { name = v, client = true } end
	return F.new(members, { wire = "throttled" })
end

local function noErrors(c)
	assert.same({}, F.output(c, "Error"), c.name .. " raised an Error during the sync")
end

local function syncedTo(viewer, banker)
	local want, wantMoney = F.held(banker, BANK)
	local got, gotMoney = F.held(viewer, BANK)
	assert.same(want, got, viewer.name .. " does not hold what " .. banker.name .. " holds")
	assert.equal(wantMoney, gotMoney, viewer.name .. "'s money for the banker differs")
	local theirs, ours = F.record(banker, BANK), F.record(viewer, BANK)
	assert.is_table(ours, viewer.name .. " has no record for the banker")
	assert.equal(theirs.inventoryHashV2, ours.inventoryHashV2, viewer.name .. " does not hold the author's canon")
end

local function quiet(c)
	local P2P = c.G.TOGBankClassic_P2P:Lib()
	assert.is_table(P2P, c.name .. " has no numbered P2P on its host")
	assert.same({}, P2P.sessionsByKey, c.name .. " still has a P2P session open")
	assert.equal(0, P2P:GetActiveSendTotal(), c.name .. " still holds a send slot")
	assert.equal(0, #(P2P.sendQueue or {}), c.name .. " still has requesters queued")
end

--- Index in the harness's wire trace (`wow.wire`, every chunk in the order it LEFT a client) of the
--- first chunk of the message `m` (its text is the first 254 bytes after the control byte, or the
--- whole message), and of its last.
local function chunkSpan(m)
	local first, last
	for i, ch in ipairs(wow.wire) do
		if ch.from == m.from.name and ch.prefix == m.prefix and bare(ch.target) == bare(m.target) then
			local body = ch.text:match("^[\001-\009](.*)") or ch.text
			if not first and m.text:sub(1, #body) == body and #body > 0 then first = i end
			if first and m.text:sub(-#body) == body then last = i; break end
		end
	end
	return first, last
end

describe("CONGESTION-001: the real transport stack is on the wire", function()
	it("a send is held by ChatThrottleLib's clamp, leaves later as chunks on the clock, and is reassembled by the recipient's AceComm", function()
		-- ChatThrottleLib clamps hard for the five seconds after its OWN Init (`HardThrottlingBeginTime
		-- = GetTime()`, ChatThrottleLib.lua:228; the test is `now - HardThrottlingBeginTime < 5` at
		-- :321) -- at whatever the clock reads, not from zero: the harness clock never rewinds across
		-- reset(), so a full suite reaches this example well past 0. F.new loads each client's CTL
		-- inside this example, so the client is inside that clamp (about 80 bytes/s) from here, exactly
		-- as a client that just logged in is. (This comment used to blame GetTime() starting at 0;
		-- WoWAPITesting read the source and corrected the cause on thread 12c11189, 2026-09-16.)
		local c = guild({ V1 })
		local A, V = c[BANK], c[V1]
		F.scan(A, bank(20), { bank = {}, money = 100 })
		F.login(A)
		local hlb2 = F.sent({ from = BANK, type = "hlb2" })
		assert.equal(1, #hlb2)
		assert.is_nil(hlb2[1].leftAt, "a 148-byte broadcast left inside the clamp with an empty gauge")
		assert.equal(0, #wow.wire, "a chunk left with no bandwidth to leave on:\n" .. wow.formatWire({}))
		F.tick(2)
		assert.is_nil(hlb2[1].leftAt, "two seconds of the clamp is ~160 bytes; a 188-byte chunk cannot have left")
		F.tick(8)
		assert.is_number(hlb2[1].leftAt, "AceCommQueue never reported the broadcast's last chunk")
		assert.is_true(hlb2[1].leftAt > hlb2[1].sentAt, "the clamp held the broadcast; it cannot have left the second it was sent")
		assert.equal(true, hlb2[1].verdict, "the terminal verdict is ChatThrottleLib's didSend, once")
		-- The viewer asked for the table it could not read; the banker's reply -- two bankers -- is
		-- one chunk, and the viewer adopted it through its own AceComm.
		assert.equal(1, #F.sent({ from = V1, type = "numbers-request" }))
		assert.equal(A.G.TOGBankClassic_BankerNumbers:Version(), V.G.TOGBankClassic_BankerNumbers:Version(),
			"the viewer did not adopt the table over the throttled wire")
		-- A 20-row snapshot is over 255 bytes: it leaves as several chunks and lands as one message.
		F.enterWorld(V); F.tick(6); F.login(V); F.tick(75)
		local snap = F.sent({ type = "inv-snapshot", from = BANK, to = V1 })
		assert.equal(1, #snap)
		local first, last = chunkSpan(snap[1])
		assert.is_number(first, "the snapshot's first chunk is not in the chunk log")
		assert.is_true(last > first, "a 20-row snapshot should not fit in one chunk")
		syncedTo(V, A)
		noErrors(A); noErrors(V)
	end)

	it("the plain sync converges on the throttled wire: banker online first, the viewer logs in under the hard clamp", function()
		local c = guild({ V1 })
		local A, V = c[BANK], c[V1]
		F.scan(A, bank(20), { bank = { { id = 2000, count = 3 } }, money = 100 })
		F.login(A); F.tick(10)

		F.enterWorld(V)          -- the gauge to zero, five seconds of ~80 bytes/s
		F.tick(6)                -- the roster settles meanwhile
		F.login(V)
		F.tick(75)               -- collect window (60) + version query (5) + handshake + data

		syncedTo(V, A)
		assert.equal(1, #F.sent({ type = "sync-request", from = V1 }), "the viewer did not request in its first round")
		assert.equal(1, #F.sent({ type = "inv-snapshot", from = BANK, to = V1 }))
		quiet(A); quiet(V)
		noErrors(A); noErrors(V)
	end)
end)

describe("CONGESTION-001: the numbers table and the offer that names it", function()
	--- The race: a viewer that holds no table broadcasts; the banker, INSIDE its own login clamp,
	--- answers with the 38-banker table (a 1165-byte HANDSHAKE whisper, five chunks) and then the
	--- one-chunk OFFER whisper naming a number in it. fullsync_spec pins "the table travels AHEAD
	--- of the offer" on the ordered wire, because the library's OnBroadcast sends it first -- and on this
	--- wire that order does not survive: the two ride different ChatThrottleLib pipes, round-robined
	--- a chunk at a time under the clamp.
	local function race()
		local c = guild({ V1 }, 37)
		local A, V = c[BANK], c[V1]
		F.scan(A, bank(20), { bank = {}, money = 100 })
		F.enterWorld(V)
		F.tick(6)
		F.enterWorld(A)          -- the banker just logged in too: gauge empty, ~80 bytes/s for 5 s
		F.login(V)
		F.tick(20)               -- the table and the offer are both out by now; the window is open
		return c, A, V
	end

	it("MEASURED: the one-chunk offer leaves BEFORE the last chunk of the five-chunk table it names", function()
		local _, A, V = race()
		local replies = F.sent({ type = "numbers-reply", from = BANK, to = V1 })
		local offer   = F.sent({ type = "hash-offer2", from = BANK, to = V1 })
		assert.is_true(#replies >= 1, "the banker did not send its table")
		assert.equal(1, #offer, "the banker did not offer")
		local tableFirst, tableLast = chunkSpan(replies[1])
		local offerAt = chunkSpan(offer[1])
		assert.is_number(tableLast, "the table's last chunk never left")
		assert.is_number(offerAt, "the offer never left")
		assert.is_true(tableFirst < offerAt, "the table's FIRST chunk left before the offer: the banker sent it first")
		assert.is_true(offerAt < tableLast, string.format(
			"the offer (chunk #%d) should have left before the table's last chunk (#%d) on a round-robined wire", offerAt, tableLast))
		-- So the offer named a number the viewer could not resolve yet: DeltaSync parks it (LIBREQ-DS-008
		-- ask 2) and replays it when the table lands. By now the table has landed, so the park is empty.
		local parked = V.G.TOGBankClassic_P2P:Lib().parkedOffers
		assert.is_table(parked, "the library keeps no park: DeltaSync predates LIBREQ-DS-008 ask 2")
		assert.is_true(next(parked) == nil, "the park should be EMPTY once the table has landed and the offer was replayed")
		noErrors(A); noErrors(V)
	end)

	it("HANDSHAKE, NOT TIMER: the table landing replays the parked offer, and the viewer holds the bank at the end of its FIRST window -- not on the 45 s catch-up", function()
		local _, A, V = race()
		F.tick(60)   -- the rest of the viewer's collect window, the version query, the handshake, the data
		assert.equal(1, #F.sent({ type = "sync-request", from = V1 }), "the viewer did not act on the offer in its first round")
		syncedTo(V, A)
		-- One broadcast from the viewer: the login one. A second is the catch-up, which is the
		-- timer this example exists to make unnecessary.
		assert.equal(1, #F.sent({ type = "hlb2", from = V1 }), "the catch-up broadcast went out: the first round did not converge")
		assert.equal(1, #F.sent({ type = "hash-offer2", from = BANK, to = V1 }), "the banker offered twice: the first offer was lost")
		quiet(A); quiet(V)
		noErrors(A); noErrors(V)
	end)

	it("a login STORM: five viewers enter the world within ten seconds of each other, and every one holds the bank at the end of its own first window", function()
		local c = guild({ V1, V2, V3, V4, V5 }, 37)
		local A = c[BANK]
		F.scan(A, bank(20), { bank = {}, money = 100 })
		F.login(A); F.tick(10)
		local viewers = { c[V1], c[V2], c[V3], c[V4], c[V5] }
		for i, V in ipairs(viewers) do
			F.enterWorld(V)
			F.tick(2)          -- two seconds apart: five broadcasts, five tables, five offers, one banker
			F.login(V)
			assert.equal(i, #F.sent({ type = "hlb2", dist = "GUILD" }) - 1, "a login broadcast is missing")
		end
		F.tick(90)             -- the last viewer's window (60) + query + handshake + data, all five in flight
		for _, V in ipairs(viewers) do
			syncedTo(V, A)
			assert.equal(1, #F.sent({ type = "hlb2", from = V.name }), V.name .. " broadcast twice: its first window did not converge")
			assert.equal(1, #F.sent({ type = "sync-request", from = V.name }), V.name .. " requested more than once")
			quiet(V); noErrors(V)
		end
		-- The banker served five snapshots inside its three send slots, queueing the rest (P2P-024).
		assert.equal(5, #F.sent({ type = "inv-snapshot", from = BANK }))
		quiet(A); noErrors(A)
	end)

	-- The park is DeltaSync's since 2026-09-16 (LIBREQ-DS-008 ask 2; TOGBank's ParkUnresolved /
	-- ReplayParkedOffers deleted), so this drives the library's own OnOffer and OnNumbersChanged on the
	-- viewer's real client.
	it("a parked number that a later table STILL cannot resolve stays parked; a later offer from the same peer replaces its park", function()
		local _, A, V = race()
		local p2p = V.G.TOGBankClassic_P2P:Lib()
		-- A stranger-to-the-table number from the banker: the library parks it.
		F.with(V, function() p2p:OnOffer(A.norm, { type = "hash-offer2", v = 99, n = "9999" }) end)
		assert.same({ "9999" }, p2p.parkedOffers[A.norm].numbers)
		-- A table change that does not name 9999 replays nothing and keeps it.
		F.with(V, function() p2p:OnNumbersChanged("adopt") end)
		assert.same({ "9999" }, p2p.parkedOffers[A.norm].numbers)
		-- The same peer's next offer, fully resolvable, is its current word: the park goes.
		local num = V.G.TOGBankClassic_BankerNumbers:NumberOf(A.norm)
		F.with(V, function() p2p:OnOffer(A.norm, { type = "hash-offer2", v = 99, n = num }) end)
		assert.is_nil(p2p.parkedOffers[A.norm])
		noErrors(V)
	end)
end)

describe("CONGESTION-001: a busy client -- other addons' traffic, a low frame rate, and the lanes", function()
	it("a viewer whose other addons spend 600 of the 800 bytes/s still holds the bank at the end of its first window", function()
		local c = guild({ V1 })
		local A, V = c[BANK], c[V1]
		F.scan(A, bank(20), { bank = {}, money = 100 })
		F.login(A); F.tick(10)
		F.background(V, 600)     -- a raid frame, a DPS meter, a boss mod, all on GUILD
		F.background(A, 600)
		F.enterWorld(V); F.tick(6); F.login(V)
		F.tick(90)
		syncedTo(V, A)
		assert.equal(1, #F.sent({ type = "hlb2", from = V1 }), "the catch-up broadcast went out: the first window did not converge")
		-- The other addons' bytes really were on the wire, charged to the same gauge.
		local foreign = 0
		for _, ch in ipairs(wow.wireTrace({ prefix = "OtherAddon" })) do foreign = foreign + ch.bytes end
		assert.is_true(foreign > 50000, "the background traffic was not sent: " .. foreign .. " bytes")
		quiet(A); quiet(V); noErrors(A); noErrors(V)
	end)

	it("a client below ChatThrottleLib's MIN_FPS (its throughput halved, no burst) still syncs in its first window", function()
		local c = guild({ V1 })
		local A, V = c[BANK], c[V1]
		F.scan(A, bank(20), { bank = {}, money = 100 })
		F.login(A); F.tick(10)
		wow.framerate = 12       -- below MIN_FPS (20): UpdateAvail refills at half rate and caps at MAX_CPS
		F.enterWorld(V); F.tick(6); F.login(V)
		F.tick(90)
		syncedTo(V, A)
		assert.equal(1, #F.sent({ type = "hlb2", from = V1 }), "the catch-up broadcast went out: the first window did not converge")
		quiet(A); quiet(V); noErrors(A); noErrors(V)
	end)

	it("P2P-031 on the wire: a 400-row BULK snapshot drains over many chunks on a shared gauge, and the ALERT handshake to a second requester is not stuck behind it", function()
		local c = guild({ V1, V2 })
		local A, V, W = c[BANK], c[V1], c[V2]
		F.scan(A, bank(400), { bank = {}, money = 100 })   -- ~12 KB of snapshot
		-- The banker's other addons spend 300 bytes/s, which ChatThrottleLib's hook charges at ~400 with
		-- its per-message overhead (ChatThrottleLib.lua:291-301). That is UNDER the 800 bytes/s refill,
		-- so while the banker waits for requests its gauge still banks the full 4000-byte burst
		-- (UpdateAvail, :315-339) -- the gauge is shared, not spent. So the payload has to outlast the
		-- burst: 12 KB is 4 KB at once and ~20 s more at the ~400 bytes/s left, long enough that the
		-- second viewer's request, a few seconds behind the first, lands while it drains. (This example
		-- said "~6 KB, ~12 s under a spent gauge" until the fleet moved onto the harness's wire, where a
		-- 200-row snapshot measured 4 s and the two requests no longer overlapped: it had rested on
		-- timing the old bus happened to produce.)
		F.background(A, 300)
		F.login(A); F.tick(10)
		F.enterWorld(V); F.tick(6); F.login(V)
		F.enterWorld(W); F.tick(4); F.login(W)
		F.tick(120)
		local snap = F.sent({ type = "inv-snapshot", from = BANK, to = V1 })
		assert.equal(1, #snap, "the first viewer was not sent the snapshot")
		local first, last = chunkSpan(snap[1])
		assert.is_number(last, "the snapshot never finished draining")
		assert.is_true(last - first >= 20, "a 400-row snapshot should be tens of chunks, not " .. (last - first + 1))
		assert.is_true(snap[1].leftAt > snap[1].sentAt, "the snapshot drained inside one tick despite a spent gauge")
		-- The second viewer's handshake rides ALERT on HANDSHAKE while that BULK payload is on
		-- RESPONSE: its accept must have gone out before the snapshot finished draining.
		local accept = F.sent({ type = "sync-accept", from = BANK, to = V2 })
		assert.equal(1, #accept, "the second viewer's request was not accepted")
		assert.is_number(accept[1].leftAt, "the accept never left")
		assert.is_true(accept[1].leftAt <= snap[1].leftAt, string.format(
			"the ALERT accept waited for the BULK snapshot to finish: the lanes are not independent (snapshot sent %s left %s; accept sent %s left %s)",
			tostring(snap[1].sentAt), tostring(snap[1].leftAt), tostring(accept[1].sentAt), tostring(accept[1].leftAt)))
		syncedTo(V, A); syncedTo(W, A)
		quiet(A); quiet(V); quiet(W); noErrors(A); noErrors(V); noErrors(W)
	end)
end)
