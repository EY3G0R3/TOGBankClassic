-- XGUILD-LIVE-001: THE SISTER-GUILD SYNC, WHOLE LIFECYCLE, ON THE REAL TRANSPORT STACK.
--
-- The operator, 2026-09-17, after v1.6.0 shipped: "build complete end to end tests for the sister
-- guild sync, still having issues with that". What existed: xguild_spec drives ONE client;
-- xguildfleet_spec four whole clients with the rosters hand-fed, on the plain bus; xguilde2e_spec
-- the roster crossing on Guild Roster's own pull, still on the plain bus. Nothing ran the federation
-- on the THROTTLED wire -- each client's real AceCommQueue, AceComm and ChatThrottleLib -- and until
-- FILL-ALERT-001 the request channel could not have crossed it at all (its "Guild" spelling was
-- dropped there with a delivered verdict). So every leg below runs on that wire, from each client's
-- own login, in the order a guild lives it, in ONE example so each leg starts from the state the
-- previous one left -- which is what the plain-bus specs, each starting clean, could never show:
--
--   1. the officers list each other; every client enters the world and logs in (the hard clamp,
--      the hlb2 broadcast, the numbers, the home syncs);
--   2. ONE pull by name (the Guild Roster window's box) -- the one manual step in game -- and the
--      library's own whispered pull and click-sent /who carry the rosters, the gbank notes and
--      presence both ways;
--   3. each side's banker union and its Bankers tab rows list the other guild's bank, tagged;
--   4. the sister viewer's next CYCLE (Events:SyncDeltaVersion, what the ten-minute timer calls)
--      whispers the federation ask; the reply carries the home numbers; the library's whispered
--      session and data leg follow; the viewer holds the home bank; nothing between the guilds
--      travelled on GUILD;
--   5. the same ask brought the home settings; a sister member's order crosses by whisper, is
--      relayed once on the home guild, and the home banker FILLS it the real way (the mail
--      leaving); the fill crosses back by whisper at ALERT and is relayed once on the sister guild;
--      every client of both guilds holds the same request in the same state;
--   6. an officer's later settings write and a who-runs entry reach the sister guild on its next
--      ask, without wiping the sister guild's own entry;
--   7. the sister banker, which never pulled first-hand, gets the roster from its guildmate's relay
--      and reaches the home bank on its own cycle;
--   8. the home banker logs off, and sends nothing after; the sister viewer's next cycle asks the
--      banker Guild Roster still calls online (its presence for another guild's member only ages
--      out), the server bounces the whisper, and the addon asks the other home member AT ONCE, is
--      answered, and shows the banker offline (XGUILD-BOUNCE-001);
--   9. a cycle with nothing new sends no data leg.
--
-- What this spec found on its first runs, 2026-09-17: (a) the harness let a logged-out client's
-- timers keep SENDING -- six library messages in the ten minutes after logout, each re-stamping the
-- banker online on the sister side, and it dropped a whisper to an offline character silently where
-- the server answers the sender (harness contract XGUILD-LIVE-001, DELIVERED as `58ff098` and
-- adopted at pin `4ffccf4`; both env_fleet stand-ins are gone and the bounce is the harness's own);
-- (b) Guild Roster's relay re-stamps every relayed name at
-- receive time, so an offline sister member never ages out while two guildmates relay (filed to its
-- inbox); (c) the addon's own bounce handling set a flag nothing read for a sister member -- fixed
-- as XGUILD-BOUNCE-001, docs/XGUILD_SYNC.md D9.
package.path = "./Tests/?.lua;" .. package.path
local F = require("env_fleet")

local HOME, SIS = F.GUILD, "Sister Guild"
local HB, HV, SB, SV = "Homebank", "Homeviewer", "Sisbank", "Sisviewer"
local ITEM_ID, ITEM, QTY = 2589, "Linen Cloth", 5

local function bank(base)
	local rows = {}
	for i = 1, 12 do rows[#rows + 1] = { id = base + i, count = 3 } end
	return rows
end

local function noErrors(c)
	assert.same({}, F.output(c, "Error"), c.name .. " raised an Error")
end

local function lib(c)
	return c.G.LibStub("LibGuildRoster-1.0")
end

local function G(c) return c.G.TOGBankClassic_Guild end

local function requestOn(c, id)
	return F.with(c, function() return G(c).Info.requests[id] end)
end

--- The Guild Roster window's "Pull from <name>" on `c`, then time for the ack, the roster and the
--- pull back to land -- every player clicking now and then, because the library verifies an asker
--- from another guild with a /who that only a click can send (xguilde2e_spec).
local function pullByName(c, peer)
	assert.is_true(F.with(c, function() return lib(c):PullSisterRoster(peer.norm, c.sisterKey) end),
		c.name .. "'s library would not pull")
	for _ = 1, 6 do
		F.tick(5)
		for _, r in ipairs(F.clients) do F.click(r) end
	end
end

--- The Bankers tab's rows on `c`, built by the real Browse module loaded into that client.
local function bankerRows(c)
	return F.with(c, function()
		if not c.G.TOGBankClassic_UI_Browse then
			c.G.TOGBankClassic_UI = { FILTER_INSET = 8 }
			c:loadFile("Modules/UI/Browse.lua", "TOGBankClassic")
		end
		return c.G.TOGBankClassic_UI_Browse:BankerRows()
	end)
end

local function rowFor(rows, norm)
	for _, r in ipairs(rows) do if r.norm == norm then return r end end
	return nil
end

--- A client's login on the real stack: enter the world (the clamp), let the roster settle, broadcast.
local function loginLive(c)
	F.enterWorld(c); F.tick(6); F.login(c)
end

--- The ten-minute cycle on `c`: what TIMER_INTERVALS.VERSION_BROADCAST fires. Past the federated
--- answer's five-minute rate limit and the peer's answer grace, so the ask is not judged pending.
local function nextCycle(c)
	F.tick(600)
	F.login(c)
end

--- The banker's mail to the requester has just left (MAIL_SEND_SUCCESS): what Mail:ApplyPendingSend
--- credits -- the fill's real entry point (fillalert_spec).
local function mailLeft(b, r, id)
	F.with(b, function()
		local Mail = b.G.TOGBankClassic_Mail
		Mail.pendingSend = { sender = b.norm, recipient = r.norm, requestId = id, items = { { name = ITEM, quantity = QTY, requestId = id } } }
		Mail:ApplyPendingSend()
	end)
end

local function crossGuild(from, to)
	local out = {}
	for _, m in ipairs(F.sent({ from = from.name })) do
		if m.target and m.target:match("^([^%-]+)") == to.name then out[#out + 1] = m end
	end
	return out
end

describe("XGUILD-LIVE-001: the sister-guild sync, whole lifecycle, on the real transport stack", function()
	it("rosters cross on the library's pull, the bank on the cycle, orders and fills both ways, settings and owners on the ask, failover and a quiet cycle", function()
		local c = F.new({
			{ name = HB, note = "gbank", client = true, money = 100, guild = HOME },
			{ name = HV, client = true, guild = HOME },
			{ name = SB, note = "gbank", client = true, money = 50, guild = SIS },
			{ name = SV, client = true, guild = SIS },
		}, { wire = "throttled" })
		local hb, hv, sb, sv = c[HB], c[HV], c[SB], c[SV]
		F.sisters(HOME, SIS)

		-- 1. Both guilds live: the bankers scan, everyone logs in on the clamp, the home guild syncs
		-- its own bank among itself first (the state a sister guild always meets).
		F.scan(hb, bank(1000), { bank = { { id = ITEM_ID, count = 40 } }, money = 100 })
		F.scan(sb, bank(3000), { bank = {}, money = 50 })
		loginLive(hb); F.tick(10)
		loginLive(sb); F.tick(10)
		loginLive(hv); loginLive(sv)
		F.tick(90)
		assert.same(F.held(hb, HB), F.held(hv, HB), "the home viewer did not sync its own guild's bank before anything crossed")
		assert.is_false(F.with(sv, function() return G(sv):IsBank(hb.norm) end), "precondition: the sister viewer knows the home banker before any roster crossed")
		assert.equal(0, #crossGuild(sv, hb), "precondition: something reached the home banker from the sister guild before the rosters crossed")

		-- 2. One pull by name. The library's own traffic carries the roster, the gbank notes and the
		-- presence stamp both ways, over the same throttled wire.
		pullByName(sv, hb)
		F.with(sv, function()
			local roster = lib(sv):GetRoster(sv.sisterKey)
			assert.is_table(roster, "the sister viewer's library holds no home roster")
			assert.is_table(roster[hb.norm], "the home banker is not on the roster that arrived")
			assert.equal("gbank", roster[hb.norm].note, "the served roster lost the gbank public note")
		end)
		F.with(hb, function()
			local roster = lib(hb):GetRoster(hb.sisterKey)
			assert.is_table(roster, "the home banker's library did not pull the sister roster back")
			assert.equal("gbank", roster[sb.norm] and roster[sb.norm].note)
		end)

		-- 3. The banker union and the Bankers tab, both sides.
		F.with(sv, function()
			assert.is_true(G(sv):IsBank(hb.norm), "the sister viewer did not take the home banker from its note")
			assert.is_false(G(sv):IsBank(hv.norm), "a member with no gbank note became a banker")
			assert.is_true(G(sv):IsPlayerOnline(hb.norm), "a sister member the library has just seen reads offline")
		end)
		local home = rowFor(bankerRows(sv), hb.norm)
		assert.is_table(home, "the sister viewer's Bankers tab has no row for the home banker")
		assert.matches("%(" .. HOME .. "%)", home.name)
		local back = rowFor(bankerRows(hb), sb.norm)
		assert.is_table(back, "the home banker's Bankers tab has no row for the sister banker")
		assert.matches("%(" .. SIS .. "%)", back.name)

		-- 4. The sister viewer's cycle: the federation ask by whisper, the reply with the numbers, the
		-- library's whispered session, the data leg. Nothing between the guilds on GUILD.
		F.login(sv)
		F.tick(120)
		assert.equal(1, #F.sent({ from = SV, type = "hash-list-request", dist = "WHISPER", to = HB }), "the sister viewer's cycle asked nobody in the home guild")
		local replies = F.sent({ from = HB, type = "hash-list-reply", dist = "WHISPER", to = SV })
		assert.equal(1, #replies, "the home banker did not answer the whispered ask")
		assert.is_table(replies[1].body and replies[1].body.numbers, "the reply carried no numbers table for a client that never hears the home hlb2")
		local want, wantMoney = F.held(hb, HB)
		local got, gotMoney = F.held(sv, HB)
		assert.is_not_nil(next(want))
		assert.same(want, got, "the sister viewer does not hold the home bank")
		assert.equal(wantMoney, gotMoney)
		assert.equal(F.record(hb, HB).inventoryHashV2, F.record(sv, HB).inventoryHashV2, "the sister viewer does not hold the author's canon")
		for _, m in ipairs(crossGuild(sv, hb)) do assert.equal("WHISPER", m.dist, m.prefix .. " crossed the guilds on " .. tostring(m.dist)) end
		for _, m in ipairs(crossGuild(hb, sv)) do assert.equal("WHISPER", m.dist, m.prefix .. " crossed the guilds on " .. tostring(m.dist)) end
		-- (Its own guild's table it asked its own banker for at login, as any viewer does; the HOME
		-- table it must never have to ask for -- the reply carried it.)
		assert.equal(0, #F.sent({ from = SV, type = "numbers-request", to = HB }), "the sister viewer asked the home guild for numbers it should have got on the reply")
		assert.equal(0, #F.sent({ from = SV, type = "numbers-request", to = HV }))
		-- XGUILD-SETTINGS-001: no owner is named yet, so nothing of the settings rides the answer --
		-- the officer settings never cross between guilds.
		assert.equal(0, #F.sent({ from = HB, type = "guild-settings", to = SV }), "settings crossed to the sister guild with no owner to carry")

		-- 5. A sister member's order against the home banker, and the banker's fill, the real way.
		local ok, why = F.with(sv, function()
			return G(sv):AddRequest({ requester = sv.norm, bank = hb.norm, item = ITEM, itemID = ITEM_ID, quantity = QTY })
		end)
		assert.is_true(ok, "the sister viewer could not order from the home banker: " .. tostring(why))
		F.tick(15)
		local id = F.with(sv, function() return (next(G(sv).Info.requests)) end)
		assert.is_string(id)
		assert.equal(1, #F.sent({ from = SV, prefix = "togbank-rm", dist = "WHISPER", to = HB }), "the order was not whispered to the home banker")
		local relay = F.sent({ from = HB, prefix = "togbank-rm", dist = "GUILD" })
		assert.equal(1, #relay, "the home banker did not relay the whispered order to its guild")
		assert.is_true(relay[1].body.logEntries[1].relayed)
		for _, r in ipairs({ hb, hv, sb, sv }) do
			local req = requestOn(r, id)
			assert.is_table(req, r.name .. " does not hold the order")
			assert.equal("open", req.status, r.name)
			assert.equal(0, tonumber(req.fulfilled) or 0, r.name)
		end
		mailLeft(hb, sv, id)
		assert.equal(QTY, requestOn(hb, id).fulfilled, "precondition: the banker did not credit its own fill")
		F.tick(15)
		assert.equal(1, #F.sent({ from = HB, prefix = "togbank-rm", dist = "WHISPER", to = SV }), "the fill did not cross back to the requester by whisper")
		local fills = F.sent({ from = HB, prefix = "togbank-rm", dist = "WHISPER", to = SV })
		assert.equal("ALERT", fills[1].prio, "the fill's whisper is not ALERT")
		assert.equal("fulfill", fills[1].body.logEntries[1].type)
		local relayBack = F.sent({ from = SV, prefix = "togbank-rm", dist = "GUILD" })
		assert.equal(2, #relayBack, "the sister viewer did not relay the fill to its own guild")
		assert.is_true(relayBack[2].body.logEntries[1].relayed)
		for _, r in ipairs({ hb, hv, sb, sv }) do
			local req = requestOn(r, id)
			assert.equal(QTY, tonumber(req.fulfilled) or 0, r.name .. " does not hold the fill")
			assert.equal("fulfilled", req.status, r.name)
		end

		-- 6. A who-runs entry made after the last ask reaches the sister guild on its NEXT ask, and the
		-- sister guild's own who-runs entry survives the answer. XGUILD-SETTINGS-001: the officer's
		-- request-limit write does NOT -- each guild's officer settings are its own.
		F.with(sv, function() assert.is_true(G(sv):SetBankerOwner(sb.norm, "Sally")) end)
		F.with(hb, function()
			assert.is_true(G(hb):SetBankerOwner(hb.norm, "Alice"))
			G(hb).Info.settings.maxRequestPercent = 25
			G(hb):BroadcastSettings("ALERT")
		end)
		F.tick(10)
		assert.equal(100, F.with(sv, function() return G(sv):MaxRequestPercent() end), "the sister viewer heard a home GUILD write: the scenario is not the field case")
		nextCycle(sv)
		F.tick(60)
		assert.equal(100, F.with(sv, function() return G(sv):MaxRequestPercent() end), "the home officer's request limit became the sister guild's")
		F.with(sv, function()
			assert.equal("Alice", G(sv):GetBankerOwner(hb.norm), "who runs the home bank character did not reach the sister guild")
			assert.equal("Sally", G(sv):GetBankerOwner(sb.norm), "the home guild's answer wiped the sister guild's own owner")
		end)

		-- 7. The sister banker never pulled by name: the library relays the roster within its guild on
		-- its own rounds, and the sister banker's cycle reaches the home bank through that.
		F.with(sb, function()
			assert.is_table(lib(sb):GetRoster(sb.sisterKey), "the sister banker never got the home roster from its guildmate")
			assert.is_true(G(sb):IsBank(hb.norm), "the sister banker does not list the home banker")
		end)
		nextCycle(sb)
		F.tick(90)
		assert.same(F.held(hb, HB), F.held(sb, HB), "the sister banker does not hold the home bank")
		-- And the home side holds the sister bank: the home banker pulled the sister roster back and
		-- its cycles asked the sister guild.
		nextCycle(hb)
		F.tick(90)
		assert.same(F.held(sb, SB), F.held(hb, SB), "the home banker does not hold the sister bank")
		assert.is_not_nil(next((F.held(hb, SB))), "the home banker holds an empty sister bank")

		-- 8. The home banker logs off. Nothing tells the sister guild: Guild Roster's presence for
		-- another guild's member is a sighting stamp that ages out over PRESENCE_TTL (900 s) and is
		-- re-stamped by every roster relay in the meantime. So the sister viewer goes on whispering the
		-- banker it believes online, the server bounces the first of those whispers ("No player named
		-- 'Homebank' is currently playing."), and the addon must take that bounce as the answer
		-- (XGUILD-BOUNCE-001): the banker reads offline, the Bankers tab agrees, and every further ask
		-- goes to the other home member, who is online and holding the bank.
		--
		-- WHAT MOVED WHEN THE HARNESS STARTED BOUNCING FOR REAL (pin `4ffccf4`), because this spec used
		-- to assert a tighter story and the change is not a weakening: the fixture's stand-in bounced
		-- only the whispers it was handed by TOGBank's Core wrapper, so the FIRST bounce was always this
		-- cycle's hash-list ask and the pair read "ask the banker, then re-ask the other member". The
		-- server bounces EVERY whisper to a logged-out character, and the earliest one here is the
		-- requests-index ask an earlier cycle staggered behind itself (AskFederationPeer's C_Timer). So
		-- the viewer now learns the banker is gone slightly sooner and never spends this cycle's ask on
		-- it. That is the addon behaving better, not differently, and the assertions below pin the
		-- OUTCOME -- one real bounce, nothing further asked of the banker, failover complete -- rather
		-- than which whisper happened to be the one that bounced. The "our own ask bounced, re-ask at
		-- once" leg keeps its own focused example in `xguild_spec` step 4.
		local asksBefore = #F.sent({ from = SV, type = "hash-list-request", dist = "WHISPER" })
		local repliesBefore = #F.sent({ from = HV, type = "hash-list-reply", dist = "WHISPER", to = SV })
		local hbSentBefore, wireBefore = #F.sent({ from = HB }), #require("env.wow").wire
		F.offline(hb)
		assert.is_true(F.with(sv, function() return G(sv):IsPlayerOnline(hb.norm) end),
			"precondition: the sister viewer should still believe the home banker online -- nothing has told it otherwise")
		nextCycle(sv)
		F.tick(60)
		-- The HARNESS's half since pin `4ffccf4`: a logged-out client SENDS nothing -- its three send
		-- seams are gated on the sender being online. Before that held, the banker's own Guild Roster
		-- kept whispering its pulls and relaying its roster for the whole ten minutes, and every one
		-- was a sighting that re-stamped it online on the sister side.
		do
			local late, all, wire = {}, F.sent({ from = HB }), require("env.wow").wire
			for i = hbSentBefore + 1, #all do late[#late + 1] = all[i].prefix .. ">" .. tostring(all[i].target) end
			for i = wireBefore + 1, #wire do
				if wire[i].from == HB then late[#late + 1] = "wire:" .. tostring(wire[i].prefix) .. ">" .. tostring(wire[i].target) end
			end
			assert.equal(0, #late, "the offline home banker still sent: " .. table.concat(late, ", "))
		end
		-- The SERVER's half, asserted separately from the addon's reaction: the sister viewer whispered
		-- the logged-out banker and the bounce came back to it, and to nobody else.
		assert.is_true(#(hv.sysLines or {}) > 0,
			"WIRING PROBE: the home viewer heard no system line at all, so the fixture's CHAT_MSG_SYSTEM frame is not being dispatched")
		local bounced = {}
		for _, line in ipairs(sv.sysLines or {}) do
			if line:find("is currently playing", 1, true) then bounced[#bounced + 1] = line end
		end
		assert.equal(1, #bounced, "the sister viewer got " .. #bounced .. " bounce lines, not one: " .. table.concat(sv.sysLines or {}, " | "))
		assert.is_truthy(bounced[1]:find(HB, 1, true), "the bounce named " .. bounced[1] .. ", not the banker")
		local asks = F.sent({ from = SV, type = "hash-list-request", dist = "WHISPER" })
		local askTrail = {}
		for i = asksBefore + 1, #asks do askTrail[#askTrail + 1] = tostring(asks[i].target) end
		assert.is_true(#askTrail > 0, "the sister viewer's cycle asked nobody at all after the banker logged off")
		-- The sharp one: once the bounce has landed, NOTHING further is asked of the character who is
		-- gone. An hour of silence per wrong pick is what XGUILD-BOUNCE-001 exists to stop.
		for _, target in ipairs(askTrail) do
			assert.equal(HV, target:match("^([^%-]+)"),
				"the sister viewer asked " .. target .. " after the bounce; new asks were: " .. table.concat(askTrail, ", "))
		end
		assert.equal(repliesBefore + #askTrail,
			#F.sent({ from = HV, type = "hash-list-reply", dist = "WHISPER", to = SV }),
			"the home viewer did not answer every failover ask it was sent")
		assert.same(F.held(hb, HB), F.held(sv, HB), "the sister viewer's copy of the home bank moved on failover")
		F.with(sv, function()
			assert.is_false(G(sv):IsPlayerOnline(hb.norm), "the bounced banker still reads online to the sister viewer")
			assert.is_true(G(sv):IsPlayerOnline(hv.norm), "the online home member reads offline to the sister viewer")
		end)
		local gone = rowFor(bankerRows(sv), hb.norm)
		assert.is_table(gone, "the logged-off banker left the sister viewer's Bankers tab")
		assert.equal(0, gone._sort_online, "the sister viewer's Bankers tab still shows the logged-off banker online")

		-- 9. Nothing new: a further cycle asks, is answered, and fetches nothing.
		local legsBefore = #F.sent({ type = "sync-request", from = SV })
		nextCycle(sv)
		F.tick(60)
		assert.equal(legsBefore, #F.sent({ type = "sync-request", from = SV }), "a cycle with nothing new opened a data leg")

		for _, r in ipairs({ hb, hv, sb, sv }) do noErrors(r) end
	end)
end)
