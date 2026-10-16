-- COVERAGE-MAIL-001 (Peer Review 074cdad6 / 5bd709cf, thread 0a7c03ad): the branches of
-- Modules/RequestLog.lua the rest of the suite never reached -- the refusals of every public request
-- method, the snapshot merge's tombstone / expiry / ratchet arms, the by-id responder and requester
-- queues, the chunked index sender and its coalescing, the throttle back-offs, /compact and /reqscan.
--
-- Each example runs a WHOLE client (env.standUpClient: every module, the real Core, a real roster),
-- so RequestLog's file-local queues start empty for every example. Only Core's two send calls are
-- replaced -- by a recorder, so what went on the wire can be decoded and read back -- and, where a
-- permission answer is the subject, the roster's officer / GM lookups.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local T0 = 1757000000
local DAY = 86400
local GUILD = "Testguild"
local BANKER, BANK2 = "Bankchar-Testrealm", "Banktwo-Testrealm"
local PEER, OTHER = "Peer-Testrealm", "Other-Testrealm"

local Guild, Core, STATUS
local sends, whisperOk
local savedCTL, savedUI

local function load()
	env.reset()
	savedUI = rawget(_G, "TOGBankClassic_UI_Requests")
	TOGBankClassic_UI_Requests = nil
	-- OTHER is a plain member ranked below this client's own rank, so the roster's officer threshold
	-- (every rank at or above the local player's) does not make them an officer.
	env.addGuildMember(OTHER, { rankIndex = 9 })
	env.standUpClient("Bankchar", { { name = BANKER, note = "gbank" }, { name = BANK2, note = "gbank" },
		{ name = PEER } }, GUILD)
	savedCTL = rawget(_G, "ChatThrottleLib")   -- after the libraries loaded, so the restore is the real one
	Guild, Core = TOGBankClassic_Guild, TOGBankClassic_Core
	STATUS = TOGBankClassic_Constants.ADOPTION_STATUS
	env.now = T0
	sends, whisperOk = {}, true
	Core.SendCommMessage = function(_, prefix, data, dist, target, prio, cb)
		sends[#sends + 1] = { prefix = prefix, data = data, dist = dist, target = target, prio = prio, cb = cb }
	end
	Core.SendWhisper = function(_, prefix, data, target, prio, cb)
		sends[#sends + 1] = { prefix = prefix, data = data, dist = "WHISPER", target = target, prio = prio, cb = cb }
		return whisperOk
	end
	Guild.Info.requests, Guild.Info.requestsTombstones = {}, {}
end

local function restore()
	_G.ChatThrottleLib = savedCTL
	TOGBankClassic_UI_Requests = savedUI
end

--- A ChatThrottleLib whose queues hold `depth` messages, in the ring shape ctlDepthForDrain walks.
local function busyCTL(depth)
	local pipe = {}
	for i = 1, depth do pipe[i] = true end
	pipe.next = pipe
	_G.ChatThrottleLib = { Prio = { NORMAL = { Ring = { pos = pipe }, Blocked = {} } } }
end

local function rec(id, fields)
	local r = { id = id, requester = PEER, bank = BANKER, item = "Linen Cloth", itemID = 2589, quantity = 5,
		fulfilled = 0, status = "open", date = T0 - 100, updatedAt = T0 - 100, notes = "" }
	for k, v in pairs(fields or {}) do r[k] = v end
	return r
end

local function count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

local function decode(send)
	local ok, data = Core:DeserializeWithChecksum(send.data)
	assert.is_true(ok, "a send did not decode")
	return data
end

local function sendsOf(prefix)
	local out = {}
	for _, s in ipairs(sends) do if s.prefix == prefix then out[#out + 1] = s end end
	return out
end

--- The recorded Output calls of one level carrying `fmt` as an argument.
local function outputs(level, fmt)
	local out = {}
	for _, c in ipairs(TOGBankClassic_Output.calls) do
		if c.level == level then
			for i = 1, c.n do
				if c[i] == fmt then out[#out + 1] = c; break end
			end
		end
	end
	return out
end

describe("COVERAGE-MAIL-001: RequestLog with no guild loaded", function()
	before_each(load)
	after_each(restore)

	it("every public request method answers 'nothing' rather than erroring", function()
		Guild.Info = nil
		Guild:EnsureRequestsInitialized()
		Guild:NormalizeRequestList()
		Guild:TouchRequestsVersion(T0)
		assert.same({ 0, 0, 0 }, { Guild:PruneRequestTombstones() })
		assert.same({ 0, 0, 0 }, { Guild:PruneRequests() })
		assert.equal(0, Guild:GetRequestsHash())
		assert.equal(0, Guild:GetRequestsVersion())
		assert.is_false(Guild:ApplyRequestSnapshot({ requests = {} }))
		assert.is_false(Guild:ApplyRequestMutation({ type = "add", requestId = "a" }, PEER))
		assert.equal(STATUS.IGNORED, Guild:ReceiveRequestsById({ requests = {} }))
		Guild:ReceiveRequestsIndex({ requests = {} }, PEER)
		Guild:ReceiveRequestMutations({ logEntries = {} }, PEER)
		Guild:SendRequestsIndex()
		assert.is_false(Guild:AddRequest(rec("a")))
		assert.is_false(Guild:CancelRequest("a", BANKER))
		assert.is_false(Guild:ReopenRequest("a", BANKER))
		assert.is_false(Guild:DeleteRequest("a", BANKER))
		assert.equal(0, Guild:ExpireStaleRequests(BANKER))
		assert.equal(0, Guild:FulfillRequest(BANKER, PEER, "Linen Cloth", 1))
		assert.equal(0, Guild:FulfillRequestById("a", 1, BANKER))
		Guild:Compact()
		Guild:ReqScan()
		env.advance(1)
		assert.same({}, sends, "something was sent with no guild loaded")
		assert.equal(1, #outputs("Response", "Compact: no guild info loaded."))
		assert.equal(1, #outputs("Response", "ReqScan: no requests loaded."))
	end)
end)

describe("COVERAGE-MAIL-001: sanitising a request", function()
	before_each(load)
	after_each(restore)

	it("refuses a non-table, an empty item, a missing or 'Unknown' requester, an empty bank and a zero quantity", function()
		assert.equal("a", Guild:SanitizeRequest(rec("a")).id, "precondition: the fixture record is valid")
		assert.is_nil(Guild:SanitizeRequest("a"))
		assert.is_nil(Guild:SanitizeRequest(rec("a", { item = "" })))
		assert.is_nil(Guild:SanitizeRequest(rec("a", { requester = "Unknown" })))
		assert.is_nil(Guild:SanitizeRequest(rec("a", { bank = "" })))
		assert.is_nil(Guild:SanitizeRequest(rec("a", { quantity = 0 })))
	end)

	it("repairs: a timestamp past 2038 falls back to now, an unknown status opens, a full Sent count reads fulfilled", function()
		local c = Guild:SanitizeRequest(rec("a", { updatedAt = 3000000000, date = 3000000000 }))
		assert.equal(T0, c.updatedAt); assert.equal(T0, c.date)
		assert.equal("open", Guild:SanitizeRequest(rec("b", { status = "weird" })).status)
		c = Guild:SanitizeRequest(rec("c", { fulfilled = 9 }))
		assert.equal("fulfilled", c.status); assert.equal(5, c.fulfilled, "the Sent count was not clamped to the quantity")
		assert.equal("cancelled", Guild:SanitizeRequest(rec("d", { fulfilled = 5, status = "cancelled" })).status,
			"a cancelled order was re-labelled fulfilled")
	end)
end)

describe("COVERAGE-MAIL-001: loading and normalising the stored list", function()
	before_each(load)
	after_each(restore)

	it("migrates an array-shaped list into the map and drops the retired request-log fields", function()
		local I = Guild.Info
		I.requests = { rec("a"), rec("b") }
		I.requestLog, I.requestLogSeq, I.requestsOps, I.requestIdSeq = {}, 3, {}, 7
		assert.is_table(I.requestLog); assert.is_table(I.requestsOps); assert.equal(7, I.requestIdSeq)
		assert.equal(3, I.requestLogSeq)
		Guild.requestsDirty = nil
		Guild:EnsureRequestsInitialized()
		assert.is_table(I.requests.a); assert.is_table(I.requests.b)
		assert.equal(2, count(I.requests), "the array slots survived beside the map")
		assert.is_nil(I.requestLog); assert.is_nil(I.requestLogSeq); assert.is_nil(I.requestsOps)
		assert.is_nil(I.requestIdSeq)
	end)

	it("drops a tombstoned order, keeps the newer of two copies of one id whichever is met first, and raises the version", function()
		for _, newerFirst in ipairs({ true, false }) do
			local old, new = rec("dup", { updatedAt = T0 - 50 }), rec("dup", { updatedAt = T0 - 10 })
			Guild.Info.requests = { k1 = newerFirst and new or old, k2 = newerFirst and old or new,
				gone = rec("gone", { updatedAt = T0 - 100 }) }
			assert.is_table(Guild.Info.requests.gone)
			Guild.Info.requestsTombstones = { gone = T0 - 90 }
			Guild.Info.requestsVersion = 5
			Guild.requestsDirty = nil
			Guild:NormalizeRequestList()
			assert.equal(T0 - 10, Guild.Info.requests.dup.updatedAt, "the older copy of a duplicated id won")
			assert.is_nil(Guild.Info.requests.gone, "a tombstoned order survived normalisation")
			assert.equal(T0 - 10, Guild.Info.requestsVersion)
		end
	end)

	it("warns once about an updatedAt at the 2038 ceiling and does not take it as the version there", function()
		Guild.Info.requests = { m = rec("m", { updatedAt = 2147483647 }) }
		Guild.Info.requestsVersion = 5
		Guild.requestsDirty = nil
		local prune = Guild.PruneRequests
		Guild.PruneRequests = function() end   -- isolate the normaliser's own version pick
		Guild:NormalizeRequestList()
		Guild.PruneRequests = prune
		assert.equal(1, #outputs("Warn", "Skipping corrupted updatedAt timestamp %s for request id=%s"))
		assert.equal(5, Guild.Info.requestsVersion)
	end)

	it("PruneRequests raises the version to the newest live order", function()
		Guild.Info.requests = { a = rec("a", { updatedAt = T0 - 10 }) }
		Guild.Info.requestsVersion = 0
		assert.same({ 0, 1, 1 }, { Guild:PruneRequests() })
		assert.equal(T0 - 10, Guild.Info.requestsVersion)
	end)

	it("the requests hash moves with a live tombstone and ignores a zero one", function()
		Guild.Info.requests = { a = rec("a") }
		Guild.requestsDirty = false
		local h1 = Guild:GetRequestsHash()
		Guild.Info.requestsTombstones.x = T0
		local h2 = Guild:GetRequestsHash()
		assert.is_not_equal(h1, h2)
		Guild.Info.requestsTombstones.y = 0
		assert.equal(h2, Guild:GetRequestsHash())
	end)

	it("GetRequestsVersion repairs a version outside 2000-2038, warning once", function()
		Guild.Info.requestsVersion = 5
		assert.equal(0, Guild:GetRequestsVersion())
		assert.equal(0, Guild.Info.requestsVersion)
		Guild.Info.requestsVersion = 5
		assert.equal(0, Guild:GetRequestsVersion())
		assert.equal(1, #outputs("Warn", "Invalid request version %s detected, resetting to 0"))
	end)
end)

describe("COVERAGE-MAIL-001: merging a received snapshot", function()
	before_each(load)
	after_each(restore)

	it("refuses a non-table payload and one with no request list", function()
		assert.is_false(Guild:ApplyRequestSnapshot("x"))
		assert.is_false(Guild:ApplyRequestSnapshot({ tombstones = {} }))
	end)

	it("keeps the newest tombstone per id", function()
		assert.is_true(Guild:ApplyRequestSnapshot({ requests = {}, tombstones = { x = T0 - 5 } }))
		assert.is_true(Guild:ApplyRequestSnapshot({ requests = {}, tombstones = { x = T0 - 50 } }))
		assert.equal(T0 - 5, Guild.Info.requestsTombstones.x)
	end)

	it("drops a malformed record and one deleted after its last update", function()
		Guild.Info.requestsTombstones.x = T0 - 5
		assert.is_true(Guild:ApplyRequestSnapshot({ requests = { { id = "bad", item = "" }, rec("x", { updatedAt = T0 - 10 }) } }))
		assert.equal(0, count(Guild.Info.requests))
	end)

	it("tombstones a finished order past retention at the day it expired, and an open one past the stale threshold at now", function()
		local old = T0 - 15 * DAY
		assert.is_true(Guild:ApplyRequestSnapshot({ requests = {
			rec("old", { status = "fulfilled", fulfilled = 5, updatedAt = old, date = old }),
			rec("stale", { updatedAt = T0 - 31 * DAY, date = T0 - 31 * DAY }) } }))
		assert.equal(0, count(Guild.Info.requests))
		assert.equal(old + 14 * DAY, Guild.Info.requestsTombstones.old)
		assert.equal(T0, Guild.Info.requestsTombstones.stale)
	end)

	it("never reverts a cancelled order to open, but takes the newer data and the higher Sent count", function()
		Guild:ApplyRequestSnapshot({ requests = { rec("r", { status = "cancelled", updatedAt = T0 - 100 }) } })
		assert.equal("cancelled", Guild.Info.requests.r.status)
		Guild:ApplyRequestSnapshot({ requests = { rec("r", { updatedAt = T0 - 50, fulfilled = 3, notes = "late fill" }) } })
		local r = Guild.Info.requests.r
		assert.equal("cancelled", r.status)
		assert.equal(3, r.fulfilled); assert.equal(T0 - 50, r.updatedAt); assert.equal("late fill", r.notes)
	end)
end)

describe("COVERAGE-MAIL-001: applying a received mutation", function()
	before_each(function()
		load()
		Guild:ApplyRequestSnapshot({ requests = { rec("a") } })
		assert.is_table(Guild.Info.requests.a)
		assert.is_false(Guild:CanManageRequests(OTHER), "precondition: OTHER is neither officer, banker nor GM")
	end)
	after_each(restore)

	it("refuses a malformed entry, an entry with no id, and an unknown type with no record", function()
		assert.is_false(Guild:ApplyRequestMutation("x", PEER))
		assert.is_false(Guild:ApplyRequestMutation({ type = "add" }, PEER))
		assert.is_false(Guild:ApplyRequestMutation({ type = "mystery", requestId = "a" }, PEER))
	end)

	it("refuses a fill from a non-banker and a fill of an order it does not hold", function()
		assert.is_false(Guild:ApplyRequestMutation({ type = "fulfill", requestId = "a", targetFulfilled = 5, ts = T0 }, PEER))
		assert.is_false(Guild:ApplyRequestMutation({ type = "fulfill", requestId = "ghost", targetFulfilled = 1, ts = T0 }, BANK2))
		assert.equal(0, Guild.Info.requests.a.fulfilled)
	end)

	it("applies an old client's additive fill delta", function()
		assert.is_true(Guild:ApplyRequestMutation({ type = "fulfill", requestId = "a", delta = 2, ts = T0 }, BANK2))
		assert.equal(2, Guild.Info.requests.a.fulfilled)
		assert.equal(T0, Guild.Info.requests.a.updatedAt)
	end)

	it("refuses an add claiming another requester, and a cancel or reopen from someone without standing", function()
		assert.is_false(Guild:ApplyRequestMutation({ type = "add", requestId = "n", request = rec("n", { requester = OTHER }) }, PEER))
		assert.equal(1, count(Guild.Info.requests))
		local newer = rec("a", { status = "cancelled", updatedAt = T0 })
		assert.is_false(Guild:ApplyRequestMutation({ type = "cancel", requestId = "a", request = newer }, OTHER))
		assert.is_false(Guild:ApplyRequestMutation({ type = "reopen", requestId = "a", request = rec("a", { updatedAt = T0, reopenedAt = T0 }) }, OTHER))
		assert.equal("open", Guild.Info.requests.a.status)
	end)
end)

describe("COVERAGE-MAIL-001: receiving mutation batches", function()
	before_each(load)
	after_each(restore)

	it("ignores a malformed payload and one with no entries", function()
		Guild:ReceiveRequestMutations(nil, PEER)
		Guild:ReceiveRequestMutations({}, PEER)
		assert.equal(1, #outputs("Debug", "ReceiveRequestMutations: Invalid payload from %s"))
		assert.equal(1, #outputs("Debug", "ReceiveRequestMutations: No logEntries in payload from %s"))
	end)

	it("asks the banker for an order it filled that this client has never seen", function()
		Guild:ReceiveRequestMutations({ logEntries = { { type = "fulfill", requestId = "ghost", targetFulfilled = 1, ts = T0 } } }, BANK2, "GUILD")
		local q = sendsOf("togbank-r")
		assert.equal(1, #q)
		assert.equal("WHISPER", q[1].dist); assert.equal(BANK2, q[1].target)
		local p = decode(q[1])
		assert.equal("requests-by-id", p.type); assert.same({ "ghost" }, p.ids)
	end)
end)

describe("COVERAGE-MAIL-001: broadcasting and the request window", function()
	before_each(load)
	after_each(restore)

	it("sends nothing for a malformed mutation, and says so when the client refuses one", function()
		Guild:BroadcastRequestMutation(nil)
		assert.same({}, sends)
		Guild:SendMutationPayload("data", "add", "GUILD")
		assert.equal(1, #sends)
		sends[1].cb(nil, 3, 10, false)
		local err = outputs("Error", "request update (%s) was refused by the client - other members will not see " ..
			"this change until the next full sync")
		assert.equal(1, #err); assert.equal("add", err[1][2])
	end)

	it("redraws the Requests window when it is open", function()
		local filters, drawn = 0, 0
		TOGBankClassic_UI_Requests = { isOpen = true, UpdateFilters = function() filters = filters + 1 end,
			DrawContent = function() drawn = drawn + 1 end }
		Guild:RefreshRequestsUI()
		assert.equal(1, filters); assert.equal(1, drawn)
	end)
end)

describe("COVERAGE-MAIL-001: the index-sync state", function()
	before_each(load)
	after_each(restore)

	it("holds a second query inside the cooldown, and allows it after", function()
		assert.is_true(Guild:BeginRequestsIndexSync(PEER))
		Guild:EndRequestsIndexSync()
		assert.is_false(Guild:CanQueryRequestsIndex(OTHER))
		env.now = T0 + 61
		assert.is_true(Guild:CanQueryRequestsIndex(OTHER))
	end)

	it("says 'Requests synced.' at the end of a sync the player asked to see", function()
		TOGBankClassic_Options.IsSyncProgressMuted = function() return false end
		Guild:BeginRequestsIndexSync(nil, true)
		Guild.requestsIndexSync.notify = true
		Guild:EndRequestsIndexSync()
		assert.equal(1, #outputs("Response", "Requests synced."))
		assert.is_false(Guild.requestsIndexSync.notify)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
	end)

	it("a refused whisper ends the query at once; a guild query clears itself after 10 s of silence", function()
		whisperOk = false
		assert.is_false(Guild:QueryRequestsIndex(PEER))
		assert.is_nil(Guild.requestsIndexSync.inFlight, "a refused query was left in flight")
		assert.is_true(Guild:QueryRequestsIndex(nil, nil, true))
		local g = sends[#sends]
		assert.equal("GUILD", g.dist); assert.equal("togbank-r", g.prefix)
		assert.equal("*", Guild.requestsIndexSync.inFlight)
		env.advance(10)
		assert.is_nil(Guild.requestsIndexSync.inFlight, "a guild query nobody answered stayed in flight")
	end)
end)

describe("COVERAGE-MAIL-001: answering by-id queries (togbank-rd2)", function()
	before_each(function()
		load()
		Guild:ApplyRequestSnapshot({ requests = { rec("a"), rec("u") }, tombstones = { t = T0 - 5, v = T0 - 6 } })
	end)
	after_each(restore)

	it("sends a record or a tombstone per id, to the guild once two people asked, and nothing for an id it does not hold", function()
		Guild:EnqueueRequestsById(PEER, { "a", "t", "u", "v", "zz" })
		Guild:EnqueueRequestsById(PEER, { "a" })            -- the same asker again: no change
		Guild:EnqueueRequestsById(OTHER, { "a", "t" })      -- a second asker: those go to the guild
		Guild:EnqueueRequestsById(OTHER, { "a" })           -- already the guild's: no change
		assert.equal(5, Guild:GetQueriedRequestsCount())
		env.advance(0)
		env.advance(1)
		assert.equal(0, Guild:GetQueriedRequestsCount())
		local got = {}
		for _, s in ipairs(sendsOf("togbank-rd2")) do
			local arr = decode(s)
			got[arr[2]] = (s.dist == "WHISPER" and s.target or s.dist) .. ":" .. (arr[3] == false and "tomb" or "rec")
		end
		assert.same({ a = "GUILD:rec", t = "GUILD:tomb", u = PEER .. ":rec", v = PEER .. ":tomb" }, got)
	end)

	it("drops the queue when the guild goes away before it drains", function()
		Guild:EnqueueRequestsById(PEER, { "a" })
		local info = Guild.Info
		Guild.Info = nil
		env.advance(0)
		Guild.Info = info
		assert.equal(0, Guild:GetQueriedRequestsCount())
		assert.same({}, sends)
	end)

	it("backs off while the throttle queue is deep, then sends", function()
		busyCTL(501)
		Guild:EnqueueRequestsById(PEER, { "a" })
		env.advance(0)
		assert.same({}, sends, "sent into a throttle queue already over its threshold")
		assert.equal(1, Guild:GetQueriedRequestsCount())
		_G.ChatThrottleLib = savedCTL
		env.advance(2)
		assert.equal(1, #sendsOf("togbank-rd2"))
	end)
end)

describe("COVERAGE-MAIL-001: asking for what an index says is missing", function()
	before_each(load)
	after_each(restore)

	local function index(n, extra)
		local arr = { 1, n }
		for i = 1, n do arr[#arr + 1] = "m" .. i; arr[#arr + 1] = T0 - 1 end
		for _, v in ipairs(extra or {}) do arr[#arr + 1] = v end
		return arr
	end

	it("asks in batches of 50, five seconds apart", function()
		Guild:ReceiveRequestsIndexV1(index(51), PEER)
		local q = sendsOf("togbank-r")
		assert.equal(1, #q); assert.equal(50, #decode(q[1]).ids)
		env.advance(5)
		q = sendsOf("togbank-r")
		assert.equal(2, #q); assert.equal(1, #decode(q[2]).ids)
	end)

	it("abandons the batches when a query cannot be sent, and ends the sync", function()
		whisperOk = false
		Guild:BeginRequestsIndexSync(PEER, true)
		Guild:ReceiveRequestsIndexV1(index(51), PEER)
		env.advance(10)
		assert.equal(1, #sendsOf("togbank-r"), "kept asking after a query could not be sent")
		assert.is_nil(Guild.requestsIndexSync.inFlight)
	end)

	it("applies the index's tombstones, removing an order deleted after its last update", function()
		Guild:ApplyRequestSnapshot({ requests = { rec("loc", { updatedAt = T0 - 10 }) } })
		assert.is_table(Guild.Info.requests.loc)
		Guild:ReceiveRequestsIndexV1(index(1, { "loc", T0 - 1 }), PEER)
		assert.is_nil(Guild.Info.requests.loc)
		assert.equal(T0 - 1, Guild.Info.requestsTombstones.loc)
		assert.same({ "m1" }, decode(sendsOf("togbank-r")[1]).ids)
	end)

	it("ends the sync when nothing is missing, and ignores a malformed index", function()
		Guild:BeginRequestsIndexSync(PEER, true)
		Guild:ReceiveRequestsIndex(nil, PEER)
		Guild:ReceiveRequestsIndex({}, PEER)
		assert.equal(PEER, Guild.requestsIndexSync.inFlight, "a malformed index ended the sync")
		Guild:ReceiveRequestsIndex({ requests = {} }, PEER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
	end)

	it("a by-id tombstone deletes the order; a zero one does nothing", function()
		Guild:ApplyRequestSnapshot({ requests = { rec("a"), rec("b") } })
		Guild:ReceiveRequestsByIdV1({ 1, "a", false, T0 })
		Guild:ReceiveRequestsByIdV1({ 1, "b", false, 0 })
		assert.is_nil(Guild.Info.requests.a)
		assert.is_table(Guild.Info.requests.b)
		assert.equal(T0, Guild.Info.requestsTombstones.a)
	end)

	it("QueryRequestsById refuses an empty list or an unsendable whisper, and asks the guild with no target", function()
		assert.is_false(Guild:QueryRequestsById(PEER, {}))
		whisperOk = false
		assert.is_false(Guild:QueryRequestsById(PEER, { "a" }))
		assert.is_true(Guild:QueryRequestsById(nil, { "a" }))
		assert.equal("GUILD", sends[#sends].dist)
	end)

	it("ReceiveRequestsById adopts a by-id reply and ends an index sync waiting on it, valid or not", function()
		Guild:BeginRequestsIndexSync(PEER, true); Guild:MarkRequestsIndexAwaitingById()
		assert.equal(STATUS.INVALID, Guild:ReceiveRequestsById(nil))
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		Guild:BeginRequestsIndexSync(PEER, true); Guild:MarkRequestsIndexAwaitingById()
		assert.equal(STATUS.INVALID, Guild:ReceiveRequestsById({ requests = "x" }))
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		Guild:BeginRequestsIndexSync(PEER, true); Guild:MarkRequestsIndexAwaitingById()
		assert.equal(STATUS.ADOPTED, Guild:ReceiveRequestsById({ requests = { rec("n") } }))
		assert.is_table(Guild.Info.requests.n)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
	end)
end)

describe("COVERAGE-MAIL-001: sending our index (togbank-ri)", function()
	before_each(function()
		load()
		local list = {}
		for i = 1, 21 do list[i] = rec(string.format("r%02d", i)) end
		Guild:ApplyRequestSnapshot({ requests = list, tombstones = { tb = T0 - 3, ta = T0 - 4 } })
		assert.equal(21, count(Guild.Info.requests))
	end)
	after_each(restore)

	it("sends 20 ids per chunk a second apart, the tombstones in the first, and warns when a chunk is refused", function()
		Guild:SendRequestsIndex(nil)
		env.advance(0)
		local ri = sendsOf("togbank-ri")
		assert.equal(1, #ri); assert.equal("GUILD", ri[1].dist)
		local first = decode(ri[1])
		assert.equal(20, first[2])
		assert.same({ "ta", T0 - 4, "tb", T0 - 3 }, { first[43], first[44], first[45], first[46] })
		env.advance(1)
		ri = sendsOf("togbank-ri")
		assert.equal(2, #ri)
		local second = decode(ri[2])
		assert.equal(1, second[2]); assert.is_nil(second[5], "the tombstones were repeated in a later chunk")
		ri[1].cb(nil, 5, 10, false)
		assert.equal(1, #outputs("Warn", "Request index chunk (%d ids) to %s was refused - they may be missing requests " ..
			"until the next index sync"))
	end)

	it("holds the chunks while the throttle queue is deep", function()
		busyCTL(21)
		Guild:SendRequestsIndex(nil)
		env.advance(0)
		assert.equal(0, #sendsOf("togbank-ri"))
		_G.ChatThrottleLib = savedCTL
		env.advance(1)
		assert.equal(1, #sendsOf("togbank-ri"))
	end)

	it("answers one asker by whisper, and two by one guild send", function()
		Guild:EnqueueIndexResponse(PEER)
		Guild:EnqueueIndexResponse(PEER)
		env.advance(41); env.advance(1)
		local ri = sendsOf("togbank-ri")
		assert.is_true(#ri >= 1)
		assert.equal("WHISPER", ri[1].dist); assert.equal(PEER, ri[1].target)
		env.advance(5)
		sends = {}
		Guild:EnqueueIndexResponse(PEER)
		Guild:EnqueueIndexResponse(OTHER)
		env.advance(41); env.advance(1)
		ri = sendsOf("togbank-ri")
		assert.is_true(#ri >= 1)
		for _, s in ipairs(ri) do assert.equal("GUILD", s.dist) end
	end)

	it("defers the answer while the throttle queue is deep", function()
		busyCTL(21)
		Guild:EnqueueIndexResponse(PEER)
		env.advance(41)
		assert.equal(0, #sendsOf("togbank-ri"))
		-- The first flush lands 20-40 s in (random jitter), so 41 s holds one or two deferrals.
		assert.is_true(#outputs("Debug", "flushIndexQueue: deferring index send (CTL=%d, by-id pending=%d)") >= 1)
		_G.ChatThrottleLib = savedCTL
		env.advance(21); env.advance(1); env.advance(1)
		assert.equal(PEER, sendsOf("togbank-ri")[1].target)
	end)

	it("does not queue a second copy of the index while a guild copy is still going out", function()
		busyCTL(21)
		Guild:SendRequestsIndex(nil)
		Guild:EnqueueIndexResponse(PEER)
		env.advance(41)
		assert.equal(1, #outputs("Debug", "flushIndexQueue: skipping — guild index already in flight (%d chunks remaining)"))
		_G.ChatThrottleLib = savedCTL
		env.advance(1); env.advance(1); env.advance(1)
		local ri = sendsOf("togbank-ri")
		assert.equal(2, #ri, "the index went out more than once")
		for _, s in ipairs(ri) do assert.equal("GUILD", s.dist) end
	end)

	it("stays quiet while another peer's index is arriving, and cancels its own guild answer when one does", function()
		Guild:ReceiveRequestsIndex({ requests = {} }, OTHER)
		Guild:EnqueueIndexResponse(PEER)
		assert.equal(1, #outputs("Debug", "EnqueueIndexResponse: suppressed — another peer is actively draining index (%.0fs remaining)"))
		env.advance(4)
		Guild:EnqueueIndexResponse(PEER)
		Guild:EnqueueIndexResponse(OTHER)
		Guild:ReceiveRequestsIndex({ requests = {} }, BANK2)
		env.advance(41); env.advance(1)
		assert.equal(0, #sendsOf("togbank-ri"), "answered an index query another peer was already answering")
		assert.equal(1, #outputs("Debug", "ReceiveRequestsIndex: cancelling pending guild index send — %s already responding"))
	end)
end)

describe("COVERAGE-MAIL-001: placing an order", function()
	before_each(load)
	after_each(restore)

	it("refuses a non-table, a view-only bank, and a record the sanitiser rejects", function()
		assert.is_false(Guild:AddRequest("x"))
		Guild.IsViewOnlyBank = function(_, n) return Guild:NormalizeName(n) == BANKER end
		local ok, why = Guild:AddRequest(rec("v"))
		assert.is_false(ok)
		assert.equal(BANKER .. " is a view-only bank -- its items cannot be requested.", why)
		Guild.IsViewOnlyBank = function() return false end
		assert.is_false(Guild:AddRequest({ bank = BANKER, item = "Linen Cloth", quantity = 1 }))
		assert.equal(0, count(Guild.Info.requests))
		assert.same({}, sends)
	end)
end)

describe("COVERAGE-MAIL-001: who may manage an order", function()
	before_each(load)
	after_each(restore)

	it("CanManageRequests: an officer, a banker, the caller's GM answer, or the roster's GM", function()
		assert.is_false(Guild:CanManageRequests(OTHER))
		assert.is_true(Guild:CanManageRequests(BANK2))
		assert.is_true(Guild:CanManageRequests(OTHER, true))
		assert.is_false(Guild:CanManageRequests(OTHER, false))
		Guild.SenderIsGM = function(_, n) return n == OTHER end
		assert.is_true(Guild:CanManageRequests(OTHER))
		Guild.SenderIsGM = function() return false end
		Guild.SenderIsOfficer = function(_, n) return n == OTHER end
		assert.is_true(Guild:CanManageRequests(OTHER))
	end)

	it("CanCancel / CanComplete / CanDelete refuse a non-record and an unresolvable actor, and honour a GM answer", function()
		local r = rec("a")
		assert.is_false(Guild:CanCancelRequest(nil, PEER))
		assert.is_true(Guild:CanCancelRequest(r, PEER), "the requester could not cancel their own order")
		assert.is_false(Guild:CanCancelRequest(r, OTHER))
		assert.is_false(Guild:CanCompleteRequest(nil, BANKER))
		assert.is_false(Guild:CanCompleteRequest(r, ""))
		assert.is_true(Guild:CanCompleteRequest(r, OTHER, true))
		assert.is_false(Guild:CanCompleteRequest(r, OTHER))
		assert.is_false(Guild:CanDeleteRequest(nil, BANKER))
		assert.is_false(Guild:CanDeleteRequest(r, ""))
		assert.is_true(Guild:CanDeleteRequest(r, OTHER, true))
		assert.is_false(Guild:CanDeleteRequest(r, OTHER))
		Guild.SenderIsGM = function(_, n) return n == OTHER end
		assert.is_true(Guild:CanCompleteRequest(r, OTHER))
		assert.is_true(Guild:CanDeleteRequest(r, OTHER))
	end)

	it("Cancel / Reopen / Delete refuse a missing id, an unknown order, the wrong state, and a caller without standing", function()
		Guild:ApplyRequestSnapshot({ requests = { rec("open"), rec("done", { status = "fulfilled", fulfilled = 5 }) } })
		for _, fn in ipairs({ "CancelRequest", "ReopenRequest", "DeleteRequest" }) do
			assert.is_false(Guild[fn](Guild, nil, BANKER), fn .. " accepted no id")
			assert.is_false(Guild[fn](Guild, "nope", BANKER), fn .. " accepted an unknown id")
		end
		assert.is_false(Guild:CancelRequest("done", BANKER), "a finished order was cancelled")
		assert.is_false(Guild:CancelRequest("open", OTHER), "a stranger cancelled someone's order")
		assert.is_false(Guild:ReopenRequest("open", BANKER), "an open order was 're-opened'")
		assert.is_false(Guild:ReopenRequest("done", OTHER), "a stranger re-opened an order")
		assert.is_false(Guild:DeleteRequest("open", PEER), "a non-GM deleted an order")
		assert.equal("open", Guild.Info.requests.open.status); assert.equal("fulfilled", Guild.Info.requests.done.status)
		assert.same({}, sends)
	end)

	it("ExpireStaleRequests refuses with no list or no standing", function()
		Guild:ApplyRequestSnapshot({ requests = { rec("a") } })
		Guild.Info.requests.a.updatedAt, Guild.Info.requests.a.date = T0 - 40 * DAY, T0 - 40 * DAY
		assert.equal(0, Guild:ExpireStaleRequests(OTHER))
		assert.is_table(Guild.Info.requests.a)
		local list = Guild.Info.requests
		Guild.Info.requests = nil
		assert.equal(0, Guild:ExpireStaleRequests(BANKER))
		Guild.Info.requests = list
	end)
end)

describe("COVERAGE-MAIL-001: recording a hand-off", function()
	before_each(function()
		load()
		Guild:ApplyRequestSnapshot({ requests = { rec("a"), rec("c", { status = "cancelled" }) } })
		Guild.Info.requests.f = rec("f", { fulfilled = 5 })   -- open but already fully sent
	end)
	after_each(restore)

	it("FulfillRequest refuses a missing argument or a non-positive count", function()
		assert.equal(0, Guild:FulfillRequest(nil, PEER, "Linen Cloth", 1))
		assert.equal(0, Guild:FulfillRequest(BANKER, PEER, "Linen Cloth", 0))
		assert.equal(0, Guild.Info.requests.a.fulfilled)
	end)

	it("FulfillRequestById refuses an unknown order, no count, a caller who cannot complete, a closed order, and nothing left", function()
		assert.equal(0, Guild:FulfillRequestById(nil, 1, BANKER))
		assert.equal(0, Guild:FulfillRequestById("nope", 1, BANKER))
		assert.equal(0, Guild:FulfillRequestById("a", 0, BANKER))
		assert.equal(0, Guild:FulfillRequestById("a", 1, OTHER))
		assert.equal(0, Guild:FulfillRequestById("c", 1, BANKER))
		assert.equal(0, Guild:FulfillRequestById("f", 1, BANKER))
		assert.equal(0, Guild.Info.requests.a.fulfilled)
		assert.same({}, sends)
	end)
end)

describe("COVERAGE-MAIL-001: /togbank compact", function()
	before_each(function()
		load()
		Guild.Info.requestsVersion = T0
		Guild.requestsDirty = false
	end)
	after_each(restore)

	local function lines()
		local out = {}
		for _, c in ipairs(TOGBankClassic_Output.calls) do
			if c.level == "Response" then out[#out + 1] = string.format(c[1], unpack(c, 2, c.n)) end
		end
		return out
	end
	local OLD = T0 - 20 * DAY

	it("says there is nothing to prune", function()
		Guild.Info.requests = { a = rec("a") }
		Guild:Compact()
		assert.same({ "Compact: nothing to prune.", "  Requests: 1, Tombstones: 0" }, lines())
	end)

	it("reports both kinds pruned", function()
		Guild.Info.requests = { a = rec("a"), o = rec("o", { status = "fulfilled", fulfilled = 5, updatedAt = OLD }) }
		Guild.Info.requestsTombstones = { x = OLD, y = T0 - 1 }
		Guild:Compact()
		assert.same({ "Compact: pruned 2 entries.", "  Requests: 2 -> 1 (-1)", "  Tombstones: 2 -> 1 (-1)" }, lines())
	end)

	it("reports only tombstones pruned, then only requests", function()
		Guild.Info.requests = { a = rec("a") }
		Guild.Info.requestsTombstones = { x = OLD }
		Guild:Compact()
		assert.same({ "Compact: pruned 1 entries.", "  Requests: 1", "  Tombstones: 1 -> 0 (-1)" }, lines())
		for i = #TOGBankClassic_Output.calls, 1, -1 do TOGBankClassic_Output.calls[i] = nil end
		Guild.Info.requests = { o = rec("o", { status = "cancelled", updatedAt = OLD }) }
		Guild:Compact()
		assert.same({ "Compact: pruned 1 entries.", "  Requests: 1 -> 0 (-1)", "  Tombstones: 0" }, lines())
	end)
end)

describe("COVERAGE-MAIL-001: /togbank reqscan", function()
	before_each(load)
	after_each(restore)

	it("buckets finished orders by age: none, future, and every band", function()
		local function done(id, ts)
			return { id = id, status = "fulfilled", quantity = 1, fulfilled = 1, updatedAt = ts, date = ts }
		end
		Guild.Info.requests = {
			none = done("none", nil), future = done("future", T0 + DAY), d3 = done("d3", T0 - 3 * DAY),
			d10 = done("d10", T0 - 10 * DAY), d17 = done("d17", T0 - 17 * DAY), d25 = done("d25", T0 - 25 * DAY),
			d40 = done("d40", T0 - 40 * DAY), live = rec("live"),
		}
		Guild:ReqScan()
		local b = outputs("Response", "    0-7d: %d  7-14d: %d  14-21d: %d  21-30d: %d  >30d: %d  future: %d")
		assert.equal(1, #b)
		assert.same({ 1, 1, 1, 1, 2, 1 }, { b[1][2], b[1][3], b[1][4], b[1][5], b[1][6], b[1][7] })
		local head = outputs("Response", "ReqScan: %d total, %d done, %d done+expired (by updatedAt, else date)")
		assert.same({ 8, 7, 4 }, { head[1][2], head[1][3], head[1][4] })
	end)
end)
