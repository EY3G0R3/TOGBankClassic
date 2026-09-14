-- P2PSession.lua — the collect/dispatch/handshake loop and its timer handling.
--
-- Every timeout, retry and slot release in this module is built on C_Timer. The distinction
-- between C_Timer.After (fire-and-forget, returns NOTHING) and C_Timer.NewTimer (returns a
-- cancellable handle) is the whole ballgame here: a cancel against an After result is a silent
-- no-op behind an `if timer then` guard, so a broken cancel looks exactly like a working one.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function loadP2P()
	env.stubOutput()
	env.loadFile("Modules/Constants.lua")   -- the send cap is Constants' (one spelling)
	env.loadFile("Modules/P2PSession.lua")
	return TOGBankClassic_P2PSession
end

local function stubGuild(opts)
	opts = opts or {}
	TOGBankClassic_Guild = {
		Info = { name = "Testguild", alts = opts.alts or {} },
		NormalizeName       = function(_, n) return n end,
		GetNormalizedPlayer = function() return "Me-Testrealm" end,
		IsBank              = function(_, n) return opts.banks == nil or opts.banks[n] == true end,
		HasAltContent       = function(_, alt) return alt ~= nil and alt.hasContent == true end,
		-- Peer Review F1: the sync-request gate is CanServe (tuple records), not HasAltContent. The
		-- stub treats `hasContent` as "servable"; the real predicate is specified in servablecanon_spec.
		CanServe            = function(self, norm)
			local alt = self.Info.alts[norm]
			return alt ~= nil and alt.hasContent == true
		end,
		HasMissingContent   = function() return opts.missingContent == true end,
		-- The real rule is Guild's and is specified against the real Guild (hashcache_spec,
		-- "Guild:AdvertisedImproves"). The mechanics here only need "we hold nothing -> useful".
		AdvertisedImproves  = function(self, norm)
			local held = self.Info.alts[norm]
			return not (held and held.hasContent), "stub"
		end,
	}
	TOGBankClassic_Core = {
		-- Called as a method, so the payload arrives in the second slot.
		SerializeWithChecksum = function(_, t) return "ser:" .. tostring(t and t.type) end,
		SendWhisper = function(_, prefix, data, target)
			env.sent[#env.sent + 1] = { prefix = prefix, data = data, target = target }
			return true
		end,
	}
	-- THE DELTA RELEASE step 3b: on accept the session asks for the data through Inventory/Sync
	-- (the host's QUERY channel). The mechanics under test here are the handshake's; the request
	-- itself is specified in chainwire_spec against the real host. Recorded so an example can see
	-- that the accept DID hand off.
	TOGBankClassic_Inventory_Sync = {
		RequestFrom = function(_, peer, norm)
			env.sent[#env.sent + 1] = { prefix = "host-query", data = norm, target = peer }
			return true
		end,
	}
	return TOGBankClassic_Guild
end

describe("P2PSession collect window", function()
	local P2P

	before_each(function()
		env.reset()
		P2P = loadP2P()
		stubGuild()
		P2P.sessions, P2P.sessionsByAlt, P2P.offers = {}, {}, {}
		P2P.activeSessions, P2P.activeSends = 0, {}
		P2P.isCollecting, P2P.collectTimer = false, nil
		P2P.pendingDispatch, P2P.catchUpTimer, P2P.catchUpCycles = {}, nil, 0
	end)

	it("opens a collect window and marks itself collecting", function()
		P2P:BeginCollectWindow({})
		assert.is_true(P2P.isCollecting)
	end)

	it("gathers offers while the window is open", function()
		P2P:BeginCollectWindow({})
		P2P:OnOffer("Peer1-Testrealm", { ["Banker-Testrealm"] = { hash = 1, updatedAt = 100 } })
		assert.equal(1, #P2P.offers["Banker-Testrealm"])
	end)

	-- P2P-034. This example used to assert the opposite ("ignores offers when no window is open")
	-- and it was pinning the live defect: `OnOffer from Leatherrcp ignored (not collecting)` -- the
	-- banker's offer for the one bank the viewer lacked, whispered behind three payloads, landed
	-- after the 60-second window and was thrown away. An offer is a peer saying "I hold newer than
	-- you"; late, it opens its session at once instead of waiting for the next catch-up broadcast.
	-- The offers here carry a canon (the shape a broadcast-as-offer has), so they dispatch without
	-- the version query; the bare number-only offer and its query are specified further down.
	local CANON = "17890000000000000001"
	it("dispatches an offer that arrives AFTER the window closed, rather than dropping it", function()
		P2P:BeginCollectWindow({})
		env.flushTimers()   -- the window closes with nothing in it
		assert.is_false(P2P.isCollecting, "precondition: the window is still open")
		env.sent = {}
		P2P:OnOffer("Peer1-Testrealm", { ["Banker-Testrealm"] = { hashV2 = CANON } })
		assert.truthy(env.sent[1] and env.sent[1].data:find("sync%-request"),
			"a late offer was ignored; the viewer learned nothing from the one peer that had the bank")
		assert.equal("Peer1-Testrealm", env.sent[1].target)
		assert.is_not_nil(P2P.sessionsByAlt["Banker-Testrealm"])
	end)

	it("does not open a session from a late offer for a bank we already hold", function()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true } } })
		env.sent = {}
		P2P:OnOffer("Peer1-Testrealm", { ["Banker-Testrealm"] = { hashV2 = CANON } })
		assert.equal(0, #env.sent, "a late offer bypassed the usefulness filter")
		assert.is_nil(P2P.sessionsByAlt["Banker-Testrealm"])
	end)

	it("parks a late offer for a peer we already have a session with, and dispatches it when that frees", function()
		P2P:BeginCollectWindow({})
		P2P:OnOffer("Peer1-Testrealm", { ["Alpha-Testrealm"] = { hashV2 = CANON } })
		env.flushTimers()   -- Dispatch: one session with Peer1 for Alpha
		env.sent = {}
		P2P:OnOffer("Peer1-Testrealm", { ["Beta-Testrealm"] = { hashV2 = CANON } })
		assert.equal(0, #env.sent, "a second request went to a peer that already has one of ours in flight")
		assert.equal(1, #P2P.pendingDispatch, "the late offer was not parked for that peer")
		P2P:OnAltCompleted("Alpha-Testrealm", "Peer1-Testrealm")
		assert.truthy(env.sent[1] and env.sent[1].data:find("sync%-request"), "the parked late offer never dispatched")
	end)

	it("sorts candidates newest first", function()
		P2P:BeginCollectWindow({})
		P2P:OnOffer("Old-Testrealm", { ["Banker-Testrealm"] = { hash = 1, updatedAt = 100 } })
		P2P:OnOffer("New-Testrealm", { ["Banker-Testrealm"] = { hash = 2, updatedAt = 500 } })
		assert.equal("New-Testrealm", P2P.offers["Banker-Testrealm"][1].peer)
	end)

	it("rejects offers for an alt that is not a banker in this guild", function()
		stubGuild({ banks = { ["Banker-Testrealm"] = true } })
		P2P:BeginCollectWindow({})
		P2P:OnOffer("Peer1-Testrealm", { ["Stranger-Testrealm"] = { hash = 1, updatedAt = 100 } })
		assert.is_nil(P2P.offers["Stranger-Testrealm"],
			"an alt from another guild's saved data leaked into the offer list")
	end)

	-- TIMER-001. Re-opening the window is meant to RESET the deadline. It cancels
	-- self.collectTimer first — but that holds the result of C_Timer.After, which is nil, so the
	-- cancel never happens and a second timer is stacked on top. Both fire Dispatch().
	it("replaces the pending dispatch rather than stacking a second one", function()
		P2P:BeginCollectWindow({})
		P2P:BeginCollectWindow({})   -- extend
		assert.equal(1, env.pendingTimerCount(),
			"extending the collect window left " .. env.pendingTimerCount() .. " timers pending. " ..
			"self.collectTimer holds the return of C_Timer.After, which is nil, so :Cancel() is " ..
			"never reached and every extension stacks another Dispatch (audit TIMER-001)")
	end)

	it("dispatches only once when the window is extended", function()
		local dispatches = 0
		local realDispatch = P2P.Dispatch
		P2P.Dispatch = function(self, ...) dispatches = dispatches + 1; return realDispatch(self, ...) end
		P2P:BeginCollectWindow({})
		P2P:BeginCollectWindow({})
		env.flushTimers()
		P2P.Dispatch = realDispatch
		assert.equal(1, dispatches,
			"Dispatch ran " .. dispatches .. " times for one collect window (audit TIMER-001)")
	end)
end)

describe("P2PSession send slots", function()
	local P2P

	before_each(function()
		env.reset()
		P2P = loadP2P()
		stubGuild()
		P2P.activeSends = {}
	end)

	it("grants a slot when under the cap", function()
		assert.is_true(P2P:TryAcquireSendSlot("Requester1"))
	end)

	it("refuses a slot once the cap is reached", function()
		assert.is_true(P2P:TryAcquireSendSlot("R1"))
		assert.is_true(P2P:TryAcquireSendSlot("R2"))
		assert.is_true(P2P:TryAcquireSendSlot("R3"))
		assert.is_false(P2P:TryAcquireSendSlot("R4"), "a fourth concurrent send was allowed")
	end)

	it("frees the slot on release", function()
		P2P:TryAcquireSendSlot("R1")
		P2P:ReleaseSendSlot("R1", "complete")
		assert.equal(0, P2P.activeSends["R1"])
	end)

	it("does not underflow on a redundant release", function()
		P2P:TryAcquireSendSlot("R1")
		P2P:ReleaseSendSlot("R1", "complete")
		P2P:ReleaseSendSlot("R1", "again")
		assert.equal(0, P2P.activeSends["R1"])
	end)

	-- P2P-024. Each acquisition schedules an unconditional 210s release. When the send finishes
	-- normally the real release runs, and the safety timer STILL fires later — decrementing a
	-- slot that by then belongs to a different, later send from the same requester.
	-- TIME MUST PASS BETWEEN THE TWO ACQUISITIONS, and that is the point of the test rather than
	-- a detail of it. Acquiring both at the same simulated instant arms both safety timers for
	-- the same deadline, so advancing to it brings send #2's OWN timeout due as well -- and then
	-- the slot is released legitimately, by #2's timer, in every possible implementation. The
	-- assertion would be unsatisfiable and would say nothing about staleness.
	--
	-- Offsetting them separates the two: at t=210 send #1's timer is due and send #2's (t=215)
	-- is not, so the ONLY thing that can free the slot is the stale release this test is about.
	-- Without the fix this still fails, which is what makes it a real test: send #1's timer runs
	-- unconditionally and decrements a slot belonging to send #2.
	it("does not let a stale safety release free a newer send's slot", function()
		P2P:TryAcquireSendSlot("R1")        -- send #1, safety timer due at t=210
		P2P:ReleaseSendSlot("R1", "complete")
		assert.equal(0, P2P.activeSends["R1"])

		env.advance(5)                      -- send #2 genuinely starts later than send #1
		P2P:TryAcquireSendSlot("R1")        -- send #2, still in flight, safety timer due at t=215
		assert.equal(1, P2P.activeSends["R1"])

		env.advance(205)                    -- t=210: send #1's timer is due, send #2's is not

		assert.equal(1, P2P.activeSends["R1"],
			"send #1's safety timer released send #2's slot. The safety release is not tied to " ..
			"the acquisition that scheduled it, so the cap can be exceeded (audit P2P-024)")
	end)
end)

-- P2P-032: which offers are worth a session, and which go first. Read off the viewer's sendqueue:
-- three fetch slots on old-build relays' offers (one for a bank already held current), 23 queued
-- behind them, the bank that mattered among the 23.
describe("P2P-032: offers are filtered and ordered by canon", function()
	local P2P
	local C = env.canon
	local T = 1757000000

	-- The REAL Guild here (Bank.lua for GetNormalizedPlayer, DeltaComms for the canons): P2P-034 moved
	-- the rule into Guild:AdvertisedImproves, and a stub of the rule under test would test nothing.
	before_each(function()
		env.reset()
		env.stubOutput()
		env.loadModules({ "Modules/Constants.lua", "Modules/Item.lua", "Modules/DeltaComms.lua",
			"Modules/Bank.lua", "Modules/Guild.lua", "Modules/BankerNumbers.lua" })
		P2P = loadP2P()
		-- P2P-035: every banker these examples name has a number, so the number-only offer and the
		-- version query can be driven. Set directly; minting has its own spec.
		local numbers = {}
		local i = 0
		for _, n in ipairs({ "Banker", "Alpha", "Beta", "Zed", "Alt1", "Alt2", "Alt3", "Alt4", "Alt5", "Alt6" }) do
			i = i + 1
			numbers[n .. "-Testrealm"] = i
		end
		TOGBankClassic_Guild.Info = { name = "Testguild", alts = {},
			roster = { alts = {}, numbers = numbers, numbersNext = i + 1, numbersVersion = 1 } }
		env.freshV2()
		TOGBankClassic_Guild.IsBank = function() return true end
		TOGBankClassic_Guild.HasMissingContent = function() return false end
		TOGBankClassic_Core = {
			-- The type, and the canon when the message names one, so a spec can see what was asked for.
			SerializeWithChecksum = function(_, t)
				return "ser:" .. tostring(t and t.type) .. (t and t.canon and (":" .. t.canon) or "")
			end,
			SendWhisper = function(_, prefix, data, target)
				env.sent[#env.sent + 1] = { prefix = prefix, data = data, target = target }
				return true
			end,
		}
		P2P.sessions, P2P.sessionsByAlt, P2P.offers = {}, {}, {}
		P2P.activeSessions, P2P.activeSends = 0, {}
		P2P.isCollecting, P2P.collectTimer = false, nil
		P2P.pendingDispatch, P2P.catchUpTimer, P2P.catchUpCycles = {}, nil, 0
	end)

	-- INV2-RETIRE-003: content in the V2 store, version metadata on the record.
	local function hold(alt, canon)
		TOGBankClassic_Guild.Info.alts[alt] = {
			name = alt, inventoryHash = 1, inventoryHashV2 = canon, inventoryUpdatedAt = T,
		}
		env.holdV2("Testguild", alt)
	end

	it("takes any offer for a bank we hold nothing for", function()
		assert.is_true(P2P:OfferIsUseful("Banker-Testrealm", { hash = 1 }))
		assert.is_true(P2P:OfferIsUseful("Banker-Testrealm", { hash = 1, hashV2 = C(T, 1) }))
	end)

	it("refuses a canon-less offer for a bank we already hold", function()
		hold("Banker-Testrealm", C(T, 1))
		assert.is_false(P2P:OfferIsUseful("Banker-Testrealm", { hash = 0xDEAD, updatedAt = T + 99999 }),
			"an old-build relay's revision-1 offer took a fetch slot for a bank we already hold (P2P-032)")
		hold("Banker-Testrealm", nil)
		assert.is_false(P2P:OfferIsUseful("Banker-Testrealm", { hash = 0xDEAD }),
			"revision-1 data cannot improve a revision-1 copy -- v1 is always red")
	end)

	it("refuses the same or an older canon, takes a newer one, and takes any canon when ours has none", function()
		hold("Banker-Testrealm", C(T, 1))
		assert.is_false(P2P:OfferIsUseful("Banker-Testrealm", { hashV2 = C(T, 1) }))
		assert.is_false(P2P:OfferIsUseful("Banker-Testrealm", { hashV2 = C(T - 1, 1) }))
		assert.is_true(P2P:OfferIsUseful("Banker-Testrealm", { hashV2 = C(T + 1, 1) }))
		hold("Banker-Testrealm", nil)
		assert.is_true(P2P:OfferIsUseful("Banker-Testrealm", { hashV2 = C(T - 100, 1) }),
			"a copy with no canon must take ANY canon-bearing offer; that is the only way it acquires one")
	end)

	-- P2P-033: "why don't we introduce parallel processing." No global cap; one session per peer.
	it("dispatches every alt at once when each has an idle peer -- no global cap of three", function()
		P2P:BeginCollectWindow({})
		for i = 1, 6 do
			P2P:OnOffer("Peer" .. i .. "-Testrealm", { ["Alt" .. i .. "-Testrealm"] = { hash = 1, hashV2 = C(T, i) } })
		end
		env.sent = {}
		P2P:Dispatch()
		local requests = 0
		for _, m in ipairs(env.sent) do if m.data:find("sync%-request") then requests = requests + 1 end end
		assert.equal(6, requests,
			"six alts held by six different peers were not all requested at once -- a global cap " ..
			"is holding fetches that cost this client 300 bytes each (P2P-033)")
		assert.equal(0, #P2P.pendingDispatch)
	end)

	it("holds a second alt for the SAME peer until the first session with that peer completes", function()
		P2P:BeginCollectWindow({})
		P2P:OnOffer("Author-Testrealm", {
			["Alpha-Testrealm"] = { hash = 1, hashV2 = C(T, 1) },
			["Beta-Testrealm"]  = { hash = 1, hashV2 = C(T, 2) },
		})
		env.sent = {}
		P2P:Dispatch()
		local requests = 0
		for _, m in ipairs(env.sent) do if m.data:find("sync%-request") then requests = requests + 1 end end
		assert.equal(1, requests, "two requests went to one peer; the second only sits in its queue")
		assert.equal(1, #P2P.pendingDispatch, "the second alt was not parked for that peer")

		env.sent = {}
		P2P:OnAltCompleted("Alpha-Testrealm", "Author-Testrealm")
		assert.truthy(env.sent[1] and env.sent[1].data:find("sync%-request"),
			"the parked alt was not dispatched when the peer became free")
		assert.equal("Author-Testrealm", env.sent[1].target)
	end)

	it("dispatches an alt whose AUTHOR offered with its canon at once, and asks the others what they hold", function()
		P2P:BeginCollectWindow({})
		P2P:OnOffer("Relay-Testrealm",  { ["Zed-Testrealm"]   = {} })     -- bare: version unknown
		P2P:OnOffer("Relay-Testrealm",  { ["Alpha-Testrealm"] = {} })
		P2P:OnOffer("Alpha-Testrealm",  { ["Alpha-Testrealm"] = { hashV2 = C(T, 1) } })   -- the author
		env.sent = {}
		P2P:Dispatch()
		local request, query
		for _, m in ipairs(env.sent) do
			if m.data:find("sync%-request") then request = request or m end
			if m.data:find("ver%-query") then query = query or m end
		end
		assert.truthy(request, "nothing was dispatched")
		assert.equal("Alpha-Testrealm", request.target,
			"Alpha's request did not go to its author, whose version nothing can beat (P2P-035)")
		assert.truthy(query and query.target == "Relay-Testrealm",
			"Zed's only offer named no version, so the relay should have been asked what it holds")
	end)

	-- P2P-035: THE VERSION QUERY. The operator: "you have a bunch of people that responded <0001>
	-- and you have no idea what version. you need to ask 3-5 or some number of those people, what
	-- version do you have, and then find the latest one ... once you know the latest, then you
	-- request the data."
	describe("the version query", function()
		local BN
		local function bareOffer(peer, alt) P2P:OnOffer(peer, { [alt] = {} }) end
		local function reply(peer, alt, canon)
			P2P:OnVersionReply(peer, BN:EncodeEntries({ { number = BN:NumberOf(alt), canon = canon } }))
		end
		local function requestsTo(target)
			local n = 0
			for _, m in ipairs(env.sent) do
				if m.data:find("sync%-request") and (target == nil or m.target == target) then n = n + 1 end
			end
			return n
		end
		before_each(function() BN = TOGBankClassic_BankerNumbers end)

		it("asks the offerers what they hold, the author first, at most five, one whisper per peer", function()
			P2P:BeginCollectWindow({})
			for i = 1, 7 do bareOffer("Peer" .. i .. "-Testrealm", "Zed-Testrealm") end
			bareOffer("Zed-Testrealm", "Zed-Testrealm")   -- the author, offered last
			env.sent = {}
			P2P:Dispatch()
			local queried = {}
			for _, m in ipairs(env.sent) do
				assert.is_nil(m.data:find("sync%-request"), "data was requested before any version was known")
				if m.data:find("ver%-query") then queried[#queried + 1] = m.target end
			end
			assert.equal(5, #queried, "asked " .. #queried .. " peers; the cap is five")
			assert.equal("Zed-Testrealm", queried[1], "the author was not asked first")
		end)

		it("requests the data from the holder of the NEWEST version, naming that version", function()
			P2P:BeginCollectWindow({})
			bareOffer("Old-Testrealm", "Zed-Testrealm")
			bareOffer("New-Testrealm", "Zed-Testrealm")
			P2P:Dispatch()
			env.sent = {}
			reply("Old-Testrealm", "Zed-Testrealm", C(T, 1))
			reply("New-Testrealm", "Zed-Testrealm", C(T + 60, 2))
			assert.equal(1, requestsTo(), "expected exactly one request once every asked peer answered")
			assert.equal("New-Testrealm", env.sent[#env.sent].target, "the older holder was asked")
			assert.truthy(env.sent[#env.sent].data:find(C(T + 60, 2), 1, true),
				"the request did not name the version it wants")
		end)

		it("the author's answer ends the wait at once, whoever else is still to answer", function()
			P2P:BeginCollectWindow({})
			bareOffer("Relay-Testrealm", "Zed-Testrealm")
			bareOffer("Zed-Testrealm", "Zed-Testrealm")
			P2P:Dispatch()
			env.sent = {}
			reply("Zed-Testrealm", "Zed-Testrealm", C(T, 1))
			assert.equal(1, requestsTo("Zed-Testrealm"), "the author answered and was not asked for the data")
		end)

		it("asks nobody when no offered version improves what we hold", function()
			hold("Zed-Testrealm", C(T + 100, 1))
			P2P:BeginCollectWindow({})
			bareOffer("Relay-Testrealm", "Zed-Testrealm")
			P2P:Dispatch()
			env.sent = {}
			reply("Relay-Testrealm", "Zed-Testrealm", C(T, 1))   -- older than ours
			assert.equal(0, requestsTo(), "requested a version older than the one we hold")
			assert.is_nil(P2P.sessionsByAlt["Zed-Testrealm"])
		end)

		it("gives up on a peer that never answers when the window closes, and asks the ones that did", function()
			P2P:BeginCollectWindow({})
			bareOffer("Silent-Testrealm", "Zed-Testrealm")
			bareOffer("Talker-Testrealm", "Zed-Testrealm")
			P2P:Dispatch()
			env.sent = {}
			reply("Talker-Testrealm", "Zed-Testrealm", C(T, 1))
			assert.equal(0, requestsTo(), "asked before the silent peer had a chance to answer")
			env.advance(6)
			assert.equal(1, requestsTo("Talker-Testrealm"))
			assert.equal(0, requestsTo("Silent-Testrealm"), "a peer with no known version was asked for data")
		end)

		-- Self-audit A2. A peer answered "nothing servable" (its scan was not done), then scanned and
		-- offered again; the earlier answer must not stand in the way of asking it again.
		it("asks a peer again when it re-offers after having answered nothing", function()
			P2P:BeginCollectWindow({})
			bareOffer("Late-Testrealm", "Zed-Testrealm")
			P2P:Dispatch()
			reply("Late-Testrealm", "Zed-Testrealm", nil)   -- nothing servable
			env.advance(6)
			assert.equal(0, requestsTo())
			env.sent = {}
			bareOffer("Late-Testrealm", "Zed-Testrealm")   -- late, outside any window
			local asked = false
			for _, m in ipairs(env.sent) do if m.data:find("ver%-query") and m.target == "Late-Testrealm" then asked = true end end
			assert.is_true(asked, "a peer that once answered nothing was never asked again until the next window")
			reply("Late-Testrealm", "Zed-Testrealm", C(T, 1))
			assert.equal(1, requestsTo("Late-Testrealm"))
		end)

		-- TABCOLOUR-003. The operator: "if someone replies that they have a newer data set than us, we
		-- need to make that bankers tab go red until we can get it." A bare offer names no version, so
		-- it cannot raise newestAdvertisedAt -- it needs its own flag, and its own two clearing events.
		describe("TABCOLOUR-003: the offer itself sets the red", function()
			local function state(alt) return TOGBankClassic_Guild:GetAltStaleness(alt) end

			it("turns a current tab red on a bare offer, naming who offered", function()
				hold("Zed-Testrealm", C(T, 1))
				assert.equal("current", (state("Zed-Testrealm")), "precondition")
				P2P:BeginCollectWindow({})
				bareOffer("Relay-Testrealm", "Zed-Testrealm")
				local s, _, _, who = state("Zed-Testrealm")
				assert.equal("offered", s, "a peer said it holds newer and the tab stayed yellow")
				assert.equal("Relay-Testrealm", who)
			end)

			it("moves to 'behind' when the version reply names a newer canon, and the cache learns it", function()
				hold("Zed-Testrealm", C(T, 1))
				P2P:BeginCollectWindow({})
				bareOffer("Relay-Testrealm", "Zed-Testrealm")
				P2P:Dispatch()
				reply("Relay-Testrealm", "Zed-Testrealm", C(T + 60, 2))
				local s, heldAt, newestAt = state("Zed-Testrealm")
				assert.equal("behind", s, "the reply named a newer version and the tab did not learn its time")
				assert.equal(T, heldAt)
				assert.equal(T + 60, newestAt)
				local cached = TOGBankClassic_Guild.latestBankerHashes and TOGBankClassic_Guild.latestBankerHashes["Zed-Testrealm"]
				assert.equal(C(T + 60, 2), cached and cached.hashV2, "hashdump's `known` did not learn the replied canon")
			end)

			it("goes back to yellow when the offerer turns out to hold nothing newer", function()
				hold("Zed-Testrealm", C(T + 100, 1))
				P2P:BeginCollectWindow({})
				bareOffer("Relay-Testrealm", "Zed-Testrealm")
				assert.equal("offered", (state("Zed-Testrealm")), "precondition")
				P2P:Dispatch()
				reply("Relay-Testrealm", "Zed-Testrealm", C(T, 1))   -- older than ours
				assert.equal("current", (state("Zed-Testrealm")), "a false alarm left the tab red for good")
			end)

			it("goes back to yellow when the offerer answers 'nothing servable' and the window closes", function()
				hold("Zed-Testrealm", C(T, 1))
				P2P:BeginCollectWindow({})
				bareOffer("Relay-Testrealm", "Zed-Testrealm")
				P2P:Dispatch()
				reply("Relay-Testrealm", "Zed-Testrealm", nil)
				env.advance(6)
				assert.equal("current", (state("Zed-Testrealm")))
			end)

			it("stays red while the offerer never answers -- 'until we can get it'", function()
				hold("Zed-Testrealm", C(T, 1))
				P2P:BeginCollectWindow({})
				bareOffer("Silent-Testrealm", "Zed-Testrealm")
				P2P:Dispatch()
				env.advance(6)
				assert.equal("offered", (state("Zed-Testrealm")),
					"an unanswered offer cleared itself; the operator wants red until the data lands")
			end)

			it("never marks our OWN character as offered", function()
				local me = TOGBankClassic_Guild:GetNormalizedPlayer()
				hold(me, C(T, 1))
				P2P:BeginCollectWindow({})
				bareOffer("Relay-Testrealm", me)
				assert.equal("current", (state(me)))
			end)
		end)

		it("answers a query with the versions it can SERVE, and answers even when that is nothing", function()
			TOGBankClassic_Guild.ServableCanon = function(_, name)
				return name == "Alpha-Testrealm" and C(T, 9) or nil
			end
			env.sent = {}
			P2P:HandleVersionQuery("Asker-Testrealm", BN:EncodeNumbers({ BN:NumberOf("Alpha-Testrealm"), BN:NumberOf("Beta-Testrealm") }))
			assert.equal(1, #env.sent)
			assert.equal("Asker-Testrealm", env.sent[1].target)
			assert.truthy(env.sent[1].data:find("ver%-reply"))
			env.sent = {}
			P2P:HandleVersionQuery("Asker-Testrealm", BN:EncodeNumbers({ BN:NumberOf("Beta-Testrealm") }))
			assert.equal(1, #env.sent, "an empty answer must still be sent, or the asker waits the whole window")
		end)

		-- P2P-037. Read off the banker account: Togstone rescanned six seconds after the requester
		-- learned its version; an exact-match gate answered "busy (version)" five times from an idle
		-- holder with the BETTER copy. We serve what was asked for or anything newer; we refuse only
		-- when ours is older than asked (a relay behind the author), so the requester moves on.
		it("serves a request for the version it holds OR an older one, and refuses only when its own copy is older", function()
			hold("Alpha-Testrealm", C(T + 5, 1))
			TOGBankClassic_Guild.CanServe = function() return true end
			TOGBankClassic_Guild.ServableCanon = function() return C(T + 5, 1) end
			env.sent = {}
			assert.is_true(P2P:HandleSyncRequest("sid1", "Requester", "Alpha-Testrealm", C(T, 1)),
				"refused a requester asking for an OLDER version than we hold -- the Togstone loop (P2P-037)")
			assert.truthy(env.sent[1].data:find("sync%-accept"))
			P2P:ReleaseSendSlot("Requester", "test")
			env.sent = {}
			assert.is_true(P2P:HandleSyncRequest("sid2", "Requester", "Alpha-Testrealm", C(T + 5, 1)))
			assert.truthy(env.sent[1].data:find("sync%-accept"))
			P2P:ReleaseSendSlot("Requester", "test")
			env.sent = {}
			assert.is_false(P2P:HandleSyncRequest("sid3", "Requester", "Alpha-Testrealm", C(T + 10, 1)),
				"served a version OLDER than the one asked for")
			assert.truthy(env.sent[1].data:find("sync%-busy"))
		end)

		it("folds a canon-bearing offer for an alt with a LIVE session into that session's candidates", function()
			P2P:BeginCollectWindow({})
			P2P:OnOffer("Relay-Testrealm", { ["Zed-Testrealm"] = { hashV2 = C(T, 1) } })
			P2P:Dispatch()
			local sid = P2P.sessionsByAlt["Zed-Testrealm"]
			assert.truthy(sid, "precondition: no session was opened")
			-- The author rescans and broadcasts while the session is in flight.
			P2P:OnOffer("Zed-Testrealm", { ["Zed-Testrealm"] = { hashV2 = C(T + 60, 2) } })
			local s = P2P.sessions[sid]
			local author
			for _, c in ipairs(s.candidates) do if c.peer == "Zed-Testrealm" then author = c end end
			assert.truthy(author, "the author's newer offer was thrown away because a session was live (P2P-037)")
			assert.equal(C(T + 60, 2), author.canon)
			assert.equal(T + 60, TOGBankClassic_Guild.newestAdvertisedAt["Zed-Testrealm"], "the tab did not learn the newer time")
		end)
	end)
end)

describe("P2PSession handshake", function()
	local P2P

	before_each(function()
		env.reset()
		P2P = loadP2P()
		P2P.sessions, P2P.sessionsByAlt = {}, {}
		P2P.activeSessions, P2P.activeSends = 0, {}
		P2P.pendingDispatch = {}
	end)

	it("replies busy when it has no content for the requested alt", function()
		stubGuild({ alts = {} })
		local accepted = P2P:HandleSyncRequest("sid1", "Requester", "Banker-Testrealm")
		assert.is_false(accepted)
		assert.equal(1, #env.sent)
		assert.truthy(env.sent[1].data:find("sync%-busy"))
	end)

	it("accepts when it has content and capacity", function()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true } } })
		local accepted = P2P:HandleSyncRequest("sid1", "Requester", "Banker-Testrealm")
		assert.is_true(accepted)
		assert.truthy(env.sent[1].data:find("sync%-accept"))
	end)

	-- P2P-029. The operator: "that 3 was an arbitrary number ... make it so it 'buffers' all
	-- requests and then has only 3 open responses, so nothing gets dropped." And on why the cap
	-- was there: "to force the P2P in a busy guild, so one player wasn't getting hammered." A
	-- request past the cap is QUEUED and told its position; it is accepted, in order, as slots
	-- free; a requester with another peer to try cancels and moves on.
	it("QUEUES a request at the send cap rather than refusing it, and reports the position", function()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true } } })
		P2P:TryAcquireSendSlot("A"); P2P:TryAcquireSendSlot("B"); P2P:TryAcquireSendSlot("C")
		local accepted = P2P:HandleSyncRequest("sid1", "Requester", "Banker-Testrealm")
		assert.is_false(accepted)
		assert.truthy(env.sent[#env.sent].data:find("sync%-queued"),
			"a request past the cap was refused with sync-busy -- every refused requester retries " ..
			"every peer, which is the storm (P2P-029)")
		assert.equal(1, P2P:EnqueueSend("sid1", "Requester", "Banker-Testrealm"), "a repeat keeps its position")
		assert.equal(2, P2P:EnqueueSend("sid2", "Other", "Banker-Testrealm"))
	end)

	it("accepts the queued request, in order, as slots free", function()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true } } })
		P2P:TryAcquireSendSlot("A"); P2P:TryAcquireSendSlot("B"); P2P:TryAcquireSendSlot("C")
		P2P:HandleSyncRequest("sid1", "First", "Banker-Testrealm")
		P2P:HandleSyncRequest("sid2", "Second", "Banker-Testrealm")
		env.sent = {}
		P2P:ReleaseSendSlot("A", "complete")
		assert.equal(1, #env.sent, "freeing one slot should accept exactly one queued requester")
		assert.equal("First", env.sent[1].target)
		assert.truthy(env.sent[1].data:find("sync%-accept"))
		assert.equal(3, P2P:GetActiveSendTotal(), "the accepted requester took the freed slot")
		P2P:ReleaseSendSlot("B", "complete")
		assert.equal("Second", env.sent[2].target)
	end)

	it("forgets a queued requester that cancels", function()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true } } })
		P2P:TryAcquireSendSlot("A"); P2P:TryAcquireSendSlot("B"); P2P:TryAcquireSendSlot("C")
		P2P:HandleSyncRequest("sid1", "First", "Banker-Testrealm")
		P2P:HandleSyncRequest("sid2", "Second", "Banker-Testrealm")
		P2P:DequeueSend("sid1", "First")
		env.sent = {}
		P2P:ReleaseSendSlot("A", "complete")
		assert.equal("Second", env.sent[1].target, "a cancelled entry was still served")
	end)

	it("drops a queued entry whose requester has long since given up", function()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true } } })
		P2P:TryAcquireSendSlot("A"); P2P:TryAcquireSendSlot("B"); P2P:TryAcquireSendSlot("C")
		P2P:HandleSyncRequest("sid1", "First", "Banker-Testrealm")
		env.advance(400)
		env.sent = {}
		P2P:ReleaseSendSlot("A", "complete")
		assert.equal(0, #env.sent, "an accept was sent to a requester whose wait expired minutes ago")
	end)

	-- The requester's half.
	it("moves on to another untried peer when queued, and tells the queuing peer", function()
		stubGuild()
		P2P.sessions["sid1"] = {
			sessionId = "sid1", altName = "Banker-Testrealm", state = "DISPATCHED", peer = "Busy",
			candidates = { { peer = "Busy", updatedAt = 2 }, { peer = "Free", updatedAt = 1 } },
			triedPeers = { Busy = true }, timers = {},
		}
		P2P.sessionsByAlt["Banker-Testrealm"] = "sid1"
		P2P.activeSessions = 1
		env.sent = {}
		P2P:OnSyncQueued("sid1", "Busy")
		local cancel, request
		for _, m in ipairs(env.sent) do
			if m.data:find("sync%-cancel") and m.target == "Busy" then cancel = true end
			if m.data:find("sync%-request") and m.target == "Free" then request = true end
		end
		assert.is_true(cancel == true, "the queuing peer was not told to drop us")
		assert.is_true(request == true, "the other peer was not asked")
	end)

	it("waits in the queue when nobody else holds the bank, past the normal ACK timeout", function()
		stubGuild()
		P2P.sessions["sid1"] = {
			sessionId = "sid1", altName = "Banker-Testrealm", state = "DISPATCHED", peer = "Busy",
			candidates = { { peer = "Busy", updatedAt = 2 } }, triedPeers = { Busy = true }, timers = {},
		}
		P2P.sessionsByAlt["Banker-Testrealm"] = "sid1"
		P2P.activeSessions = 1
		P2P:OnSyncQueued("sid1", "Busy")
		env.advance(60)
		assert.equal("DISPATCHED", P2P.sessions["sid1"].state,
			"the session gave up inside the queue wait, so the later accept would land on nothing")
		P2P:OnSyncAccept("sid1", "Busy")
		assert.equal("ACTIVE", P2P.sessions["sid1"].state)
	end)

	-- P2P-028: THE SLOT LEAK, read off two live clients on 2026-09-10. The banker answered dozens
	-- of sync-requests in thirty seconds, received no state summary and sent no payload: every
	-- one of its three slots was held by an accept that ended in nothing, for the 210-second
	-- safety timer, and every requester was told "busy" and retried. An accept must give its
	-- slot back on every path that will never send.
	it("frees an accepted slot when the requester never sends its state summary", function()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true } } })
		assert.is_true(P2P:HandleSyncRequest("sid1", "Requester", "Banker-Testrealm"))
		assert.equal(1, P2P:GetActiveSendTotal(), "precondition: the accept took a slot")
		env.advance(31)
		assert.equal(0, P2P:GetActiveSendTotal(),
			"an accept nobody followed up held its slot past the state-summary window; with a " ..
			"guild's worth of requesters that is a permanently busy banker (P2P-028)")
	end)

	it("keeps the slot when the state summary DOES arrive, until the send itself releases it", function()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true } } })
		P2P:HandleSyncRequest("sid1", "Requester", "Banker-Testrealm")
		P2P:StateSummaryArrived("Requester", "Banker-Testrealm")
		env.advance(31)
		assert.equal(1, P2P:GetActiveSendTotal(),
			"the state-wait fired although the summary had arrived -- a live send would lose its slot")
	end)

	it("does not free a slot the wait did not own when the requester has two in flight", function()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true } } })
		P2P:HandleSyncRequest("sid1", "Requester", "Banker-Testrealm")
		P2P:StateSummaryArrived("Requester", "Banker-Testrealm")
		P2P:HandleSyncRequest("sid2", "Requester", "Banker-Testrealm")   -- second accept, unanswered
		env.advance(31)
		assert.equal(1, P2P:GetActiveSendTotal(), "the unanswered accept freed one slot, not both")
	end)

	-- Self-audit F2: two accepts to ONE requester for TWO alts; the summary for one must not
	-- cancel the wait for the other, and the second accept must not cancel the first's wait.
	it("keys the state-wait by requester AND alt", function()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true }, ["Other-Testrealm"] = { hasContent = true } } })
		P2P:HandleSyncRequest("sid1", "Requester", "Banker-Testrealm")
		P2P:HandleSyncRequest("sid2", "Requester", "Other-Testrealm")
		P2P:StateSummaryArrived("Requester", "Banker-Testrealm")   -- only the first is answered
		env.advance(31)
		assert.equal(1, P2P:GetActiveSendTotal(),
			"the unanswered accept for the OTHER alt kept its slot: keyed by requester alone, its " ..
			"wait was cancelled by the first alt's summary (or by the second accept) and the slot " ..
			"fell back to the 210s timer -- the P2P-028 leak, narrowed to this shape")
	end)

	it("ignores a sync-accept for an unknown session", function()
		stubGuild()
		local ok = pcall(function() P2P:OnSyncAccept("nosuchsession", "Peer") end)
		assert.is_true(ok)
	end)

	it("releases the session slot on completion", function()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true } } })
		P2P.sessions["sid1"] = {
			sessionId = "sid1", altName = "Banker-Testrealm", state = "ACTIVE",
			peer = "Peer", candidates = {}, triedPeers = {}, timers = {},
		}
		P2P.sessionsByAlt["Banker-Testrealm"] = "sid1"
		P2P.activeSessions = 1
		P2P:OnAltCompleted("Banker-Testrealm", "Peer")
		assert.equal(0, P2P.activeSessions)
		assert.is_nil(P2P.sessions["sid1"])
		assert.is_nil(P2P.sessionsByAlt["Banker-Testrealm"])
	end)

	it("reports an in-flight session via HasActiveSession", function()
		stubGuild()
		P2P.sessions["sid1"] = { sessionId = "sid1", altName = "B", state = "DISPATCHED", timers = {} }
		P2P.sessionsByAlt["B"] = "sid1"
		assert.is_true(P2P:HasActiveSession("B"))
	end)

	it("reports no session for an unknown alt", function()
		stubGuild()
		assert.is_false(P2P:HasActiveSession("Nobody"))
	end)
end)

describe("P2PSession catch-up", function()
	local P2P

	before_each(function()
		env.reset()
		P2P = loadP2P()
		P2P.catchUpTimer, P2P.catchUpCycles = nil, 0
		TOGBankClassic_Events = { SyncDeltaVersion = function() env.sent[#env.sent + 1] = "sync" end }
	end)

	it("does not schedule when nothing is missing", function()
		stubGuild({ missingContent = false })
		P2P:ScheduleCatchUp("test")
		assert.equal(0, env.pendingTimerCount())
	end)

	it("schedules a broadcast when content is missing", function()
		stubGuild({ missingContent = true })
		P2P:ScheduleCatchUp("test")
		assert.equal(1, env.pendingTimerCount())
	end)

	-- ScheduleCatchUp latches on self.catchUpTimer, which it sets to `true` explicitly with the
	-- comment "set before C_Timer.After in case it returns nil". That workaround is correct —
	-- and is the one place in the addon that acknowledges After's return value.
	it("does not double-schedule while one is already pending", function()
		stubGuild({ missingContent = true })
		P2P:ScheduleCatchUp("first")
		P2P:ScheduleCatchUp("second")
		assert.equal(1, env.pendingTimerCount(), "a second catch-up was scheduled concurrently")
	end)

	it("gives up after the maximum number of cycles", function()
		stubGuild({ missingContent = true })
		for _ = 1, 8 do
			P2P.catchUpTimer = nil
			P2P:ScheduleCatchUp("loop")
		end
		assert.truthy(P2P.catchUpCycles <= 5,
			"catch-up cycles ran away to " .. tostring(P2P.catchUpCycles))
	end)
end)

-- P2P-027 — a session timer must not outlive the attempt that armed it.
--
-- Same class as P2P-026 in Guild.lua/Chat.lua, and NOT the C_Timer.After-versus-NewTimer axis this
-- file was already corrected on by audit finding 24. Every handle here is real; the defect is that
-- `AdvanceCandidate` cancelled `s.timers.dispatch` and never `s.timers.retry`, so a retry cycle
-- scheduled by an earlier advance stayed live while the session moved on to a different peer.
--
-- These constants are P2PSession's own (DISPATCH_TIMEOUT 15, RETRY_CYCLE_DELAY 20) and the clock is
-- stepped so that only ONE of them is due at a time. Advancing past both at once makes the result
-- depend on the order the harness happens to fire them in, which is not what is under test.
describe("P2P-027: a superseded retry cycle", function()
	local P2P

	local function dispatchedSession()
		P2P.sessions["sid1"] = {
			sessionId = "sid1",
			altName   = "Banker-Testrealm",
			state     = "DISPATCHED",
			peer      = "P1",
			candidates = { { peer = "P1" }, { peer = "P2" } },
			-- Both already tried, so the FIRST AdvanceCandidate takes the "all candidates busy"
			-- branch: it schedules a retry cycle and resets triedPeers.
			triedPeers = { P1 = true, P2 = true },
			timers    = {},
			retryCount = 0,
		}
		P2P.sessionsByAlt["Banker-Testrealm"] = "sid1"
		P2P.activeSessions = 1
		return P2P.sessions["sid1"]
	end

	before_each(function()
		env.reset()
		P2P = loadP2P()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true } }, missingContent = false })
		P2P.sessions, P2P.sessionsByAlt, P2P.offers = {}, {}, {}
		P2P.activeSessions, P2P.activeSends = 0, {}
		P2P.pendingDispatch, P2P.catchUpTimer, P2P.catchUpCycles = {}, nil, 0
	end)

	it("is cancelled when the session advances to another peer instead", function()
		local s = dispatchedSession()
		P2P:AdvanceCandidate("sid1", "busy")   -- all tried: schedules the retry, resets triedPeers
		assert.is_not_nil(s.timers.retry, "precondition: the retry cycle was scheduled")

		P2P:AdvanceCandidate("sid1", "busy")   -- a second BUSY: a candidate is free again
		assert.is_nil(s.timers.retry,
			"advancing to a new peer must cancel the retry cycle it supersedes")
	end)

	it("leaves one live timer for the session, not two", function()
		dispatchedSession()
		P2P:AdvanceCandidate("sid1", "busy")
		P2P:AdvanceCandidate("sid1", "busy")
		-- Only the dispatch timeout for the peer now being waited on.
		assert.equal(1, env.pendingTimerCount())
	end)

	--- The harm, driven rather than reasoned about. The orphaned retry fires after the session has
	--- already moved on and tried its last candidate, finds nothing left to pick, and fails the
	--- session -- destroying a dispatch that was still legitimately in flight.
	it("does not destroy a session that is still waiting on a peer", function()
		dispatchedSession()
		P2P:AdvanceCandidate("sid1", "busy")
		P2P:AdvanceCandidate("sid1", "busy")   -- now dispatched to P1, dispatch timeout at t=15

		env.advance(16)                        -- only the dispatch timeout is due; advances to P2
		assert.is_not_nil(P2P.sessions["sid1"], "precondition: still alive after the dispatch timeout")

		env.advance(5)                         -- t=21: the orphaned retry's deadline has passed
		assert.is_not_nil(P2P.sessions["sid1"],
			"a retry cycle from a superseded advance failed the session while a dispatch to another " ..
			"peer was still outstanding")
	end)

	--- The over-reach guard, and it is the reason this fix is not simply "cancel more". A retry cycle
	--- that nothing supersedes must still fire and re-dispatch -- a change that quietly stopped every
	--- retry would pass all three examples above while making busy guilds worse.
	it("still re-dispatches when the retry has not been superseded", function()
		dispatchedSession()
		P2P:AdvanceCandidate("sid1", "busy")   -- schedules the retry and nothing supersedes it
		local before = #env.sent

		env.advance(21)

		assert.is_true(#env.sent > before,
			"the retry cycle must still send a sync-request when it has not been superseded")
		assert.is_not_nil(P2P.sessions["sid1"])
	end)
end)

--- Shape guard: the three session timers are armed in one place. Written because P2P-026 and
--- P2P-027 are the same defect found twice, a fortnight apart, in two modules -- and both times the
--- arm site read as correct.
describe("P2PSession arms its session timers through one helper", function()
	local function lines(path)
		local fh = assert(io.open(path, "r"), "could not open " .. path)
		local src = fh:read("*a")
		fh:close()
		local out = {}
		for line in (src .. "\n"):gmatch("(.-)\r?\n") do out[#out + 1] = line end
		return out
	end

	it("assigns no session timer slot directly", function()
		local offenders = {}
		for lineNo, line in ipairs(lines("Modules/P2PSession.lua")) do
			-- Code only; the fix's own comments describe the old assignment.
			if not line:match("^%s*%-%-")
				and line:find("s%.timers%.[%w_]+%s*=%s*C_Timer%.") then
				offenders[#offenders + 1] = "Modules/P2PSession.lua:" .. lineNo
			end
		end
		assert.same({}, offenders)
	end)
end)
