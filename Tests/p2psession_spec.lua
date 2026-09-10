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
		HasMissingContent   = function() return opts.missingContent == true end,
		SendStateSummary    = function() end,
	}
	TOGBankClassic_Core = {
		-- Called as a method, so the payload arrives in the second slot.
		SerializeWithChecksum = function(_, t) return "ser:" .. tostring(t and t.type) end,
		SendWhisper = function(_, prefix, data, target)
			env.sent[#env.sent + 1] = { prefix = prefix, data = data, target = target }
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

	it("ignores offers when no window is open", function()
		P2P:OnOffer("Peer1-Testrealm", { ["Banker-Testrealm"] = { hash = 1, updatedAt = 100 } })
		assert.is_nil(P2P.offers["Banker-Testrealm"])
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

	it("replies busy once at the send cap", function()
		stubGuild({ alts = { ["Banker-Testrealm"] = { hasContent = true } } })
		P2P:TryAcquireSendSlot("A"); P2P:TryAcquireSendSlot("B"); P2P:TryAcquireSendSlot("C")
		local accepted = P2P:HandleSyncRequest("sid1", "Requester", "Banker-Testrealm")
		assert.is_false(accepted)
		assert.truthy(env.sent[#env.sent].data:find("sync%-busy"))
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
