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

	it("MUT-ID-001: refuses a record whose own id differs from the mutation's requestId", function()
		-- PEER is the requester of both, so the add permission check alone would let this through and
		-- the newer snapshot of "b" would overwrite order "a".
		local planted = rec("b", { quantity = 99, updatedAt = T0 })
		assert.is_false(Guild:ApplyRequestMutation({ type = "add", requestId = "a", request = planted }, PEER))
		assert.equal("a", Guild.Info.requests.a.id)
		assert.equal(5, Guild.Info.requests.a.quantity)
		assert.is_nil(Guild.Info.requests.b)
	end)

	it("ADD-OWNER-001: refuses an add that would take over or close someone else's order", function()
		-- OTHER names itself as requester, so the claimed-requester check passes; the ids agree, so
		-- MUT-ID-001 passes; only the held order's own requester stands in the way.
		local takeover = rec("a", { requester = OTHER, quantity = 99, updatedAt = T0 })
		assert.is_false(Guild:ApplyRequestMutation({ type = "add", requestId = "a", request = takeover }, OTHER))
		local closer = rec("a", { requester = OTHER, status = "cancelled", updatedAt = T0 })
		assert.is_false(Guild:ApplyRequestMutation({ type = "add", requestId = "a", request = closer }, OTHER))
		assert.equal(PEER, Guild.Info.requests.a.requester)
		assert.equal("open", Guild.Info.requests.a.status)
		assert.equal(5, Guild.Info.requests.a.quantity)
	end)

	it("ADD-OWNER-001: still merges the requester's own add for an order already held", function()
		assert.is_true(Guild:ApplyRequestMutation({ type = "add", requestId = "a", request = rec("a", { notes = "again", updatedAt = T0 }) }, PEER))
		assert.equal("again", Guild.Info.requests.a.notes)
	end)

	it("ADD-OPEN-001: refuses the requester's own add that closes or fills their order", function()
		for _, fields in ipairs({
			{ status = "complete", updatedAt = T0 },
			{ status = "fulfilled", fulfilled = 5, updatedAt = T0 },
			{ fulfilled = 5, updatedAt = T0 },
		}) do
			assert.is_false(Guild:ApplyRequestMutation({ type = "add", requestId = "a", request = rec("a", fields) }, PEER))
		end
		assert.equal("open", Guild.Info.requests.a.status)
		assert.equal(0, Guild.Info.requests.a.fulfilled)
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
		Guild:QueryRequestsById(PEER, { "a", "b" })
		Guild:ReceiveRequestsByIdV1({ 1, "a", false, T0 }, PEER)
		Guild:ReceiveRequestsByIdV1({ 1, "b", false, 0 }, PEER)
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

	-- BYID-MALFORMED-001 (Peer Review 3a1998fa, P5): a malformed by-id answers nothing that was asked, so
	-- like an empty one (BYID-EMPTY-001) it must not end the sync; INDEX_INFLIGHT_TIMEOUT still frees it.
	it("ReceiveRequestsById refuses a malformed reply without ending an index sync, and an asked reply ends it", function()
		Guild:BeginRequestsIndexSync(PEER, true); Guild:MarkRequestsIndexAwaitingById()
		assert.equal(STATUS.INVALID, Guild:ReceiveRequestsById(nil, PEER))
		assert.is_true(Guild.requestsIndexSync.awaitingById)
		assert.is_not_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(STATUS.INVALID, Guild:ReceiveRequestsById({ requests = "x" }, PEER))
		assert.is_true(Guild.requestsIndexSync.awaitingById)
		assert.is_not_nil(Guild.requestsIndexSync.inFlight)
		Guild:QueryRequestsById(PEER, { "n" })
		assert.equal(STATUS.ADOPTED, Guild:ReceiveRequestsById({ requests = { rec("n") } }, PEER))
		assert.is_table(Guild.Info.requests.n)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
	end)

	-- BYID-SYNC-END-001 (Peer Review eeb82a62, F2): the first asked record ended the whole sync, printing
	-- 'Requests synced.' while the rest were still being asked and letting a second index sync start under them.
	local function rd2(id)
		local r = rec(id)
		return { 1, r.id, r.date, r.updatedAt, r.requester, r.bank, r.item, r.quantity, r.fulfilled, r.status, r.notes, r.itemID }
	end

	it("a sync stays in flight until every id it asked for is answered", function()
		TOGBankClassic_Options.IsSyncProgressMuted = function() return false end
		Guild:BeginRequestsIndexSync(PEER, true)
		Guild.requestsIndexSync.notify = true
		Guild:ReceiveRequestsIndexV1(index(51), PEER)
		Guild:ReceiveRequestsByIdV1(rd2("m1"), PEER)
		assert.equal(PEER, Guild.requestsIndexSync.inFlight, "the first record ended the sync")
		assert.equal(0, #outputs("Response", "Requests synced."))
		for i = 2, 50 do Guild:ReceiveRequestsByIdV1(rd2("m" .. i), PEER) end
		assert.equal(PEER, Guild.requestsIndexSync.inFlight, "ended with the second batch still unsent")
		env.advance(5)
		Guild:ReceiveRequestsByIdV1(rd2("m51"), PEER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(1, #outputs("Response", "Requests synced."))
	end)

	it("a table by-id reply ends the sync only once every id it asked for is answered", function()
		Guild:BeginRequestsIndexSync(PEER, true)
		Guild:ReceiveRequestsIndexV1(index(2), PEER)
		assert.equal(STATUS.ADOPTED, Guild:ReceiveRequestsById({ requests = { rec("m1") } }, PEER))
		assert.equal(PEER, Guild.requestsIndexSync.inFlight)
		Guild:ReceiveRequestsById({ requests = { rec("m2") } }, PEER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
	end)

	it("a guild query's 10 s silence check does not end a sync that is fetching records", function()
		assert.is_true(Guild:QueryRequestsIndex(nil, nil, true))
		Guild:ReceiveRequestsIndexV1(index(51), PEER)
		env.advance(10)
		assert.equal("*", Guild.requestsIndexSync.inFlight)
	end)

	-- BYID-SYNC-END-001 (Peer Review eeb82a62, F4): a long drain outlived INDEX_INFLIGHT_TIMEOUT once the sync
	-- stays in flight for it, so each asked answer restarts the in-flight clock.
	it("each asked answer keeps a long sync from timing out", function()
		Guild:BeginRequestsIndexSync(PEER, true)
		Guild:ReceiveRequestsIndexV1(index(51), PEER)
		env.now = T0 + 170
		Guild:ReceiveRequestsByIdV1(rd2("m1"), PEER)
		env.now = T0 + 200
		assert.is_false(Guild:CanQueryRequestsIndex(OTHER))
		assert.equal(PEER, Guild.requestsIndexSync.inFlight)
		env.now = T0 + 171 + 180
		assert.is_true(Guild:CanQueryRequestsIndex(OTHER), "a silent peer is still freed by the timeout")
	end)

	-- BYID-SYNC-END-001 (Peer Review dc0455df, K1-K3): an index comes in chunks of 20 ids, one a second, and
	-- the receiver cannot tell the last one. A chunk with nothing missing ended the sync outright (K1); each
	-- chunk after the first forgot the ids the earlier ones still waited on (K2); and a chunk whose ids were all
	-- answered before the next arrived ended the sync between chunks (K3). Each chunk now ends with
	-- `false, <chunks still to come>`, so the receiver knows the last one without a timer.
	local function chunk(toCome, ...)
		---@type any[]
		local arr = { 1, select("#", ...) }
		for _, id in ipairs({ ... }) do arr[#arr + 1] = id; arr[#arr + 1] = T0 - 1 end
		if toCome then arr[#arr + 1] = false; arr[#arr + 1] = toCome end
		return arr
	end
	local function notifying()
		TOGBankClassic_Options.IsSyncProgressMuted = function() return false end
		Guild:BeginRequestsIndexSync(PEER, true)
		Guild.requestsIndexSync.notify = true
	end

	it("K1: a later chunk with nothing missing does not end a sync still fetching an earlier chunk's ids", function()
		notifying()
		Guild:ReceiveRequestsIndexV1(chunk(1, "m1"), PEER)
		env.advance(1)
		Guild:ReceiveRequestsIndexV1(chunk(0), PEER)
		assert.equal(PEER, Guild.requestsIndexSync.inFlight, "a 0-missing chunk ended the sync")
		assert.equal(0, #outputs("Response", "Requests synced."))
		Guild:ReceiveRequestsByIdV1(rd2("m1"), PEER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(1, #outputs("Response", "Requests synced."))
	end)

	it("K2: a second chunk from the same peer adds to the ids awaited instead of replacing them", function()
		notifying()
		Guild:ReceiveRequestsIndexV1(chunk(1, "m1"), PEER)
		env.advance(1)
		Guild:ReceiveRequestsIndexV1(chunk(0, "m2"), PEER)
		assert.equal(2, #sendsOf("togbank-r"))
		Guild:ReceiveRequestsByIdV1(rd2("m2"), PEER)
		assert.equal(PEER, Guild.requestsIndexSync.inFlight, "ended with the first chunk's id unanswered")
		assert.equal(0, #outputs("Response", "Requests synced."))
		Guild:ReceiveRequestsByIdV1(rd2("m1"), PEER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(1, #outputs("Response", "Requests synced."))
	end)

	it("K3: a chunk answered in full before the next chunk arrives does not end the sync between them", function()
		notifying()
		Guild:ReceiveRequestsIndexV1(chunk(1, "m1"), PEER)
		Guild:ReceiveRequestsByIdV1(rd2("m1"), PEER)
		assert.equal(PEER, Guild.requestsIndexSync.inFlight, "ended between chunks")
		assert.equal(0, #outputs("Response", "Requests synced."))
		Guild:ReceiveRequestsIndexV1(chunk(0, "m2"), PEER)
		Guild:ReceiveRequestsByIdV1(rd2("m2"), PEER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(1, #outputs("Response", "Requests synced."))
	end)

	it("K3: an index of chunks with nothing missing ends on its last chunk, and the 10 s check waits for it", function()
		assert.is_true(Guild:QueryRequestsIndex(nil, nil, true))
		Guild:ReceiveRequestsIndexV1(chunk(2), PEER)
		env.advance(10)
		assert.equal("*", Guild.requestsIndexSync.inFlight, "ended with two chunks still to come")
		Guild:ReceiveRequestsIndexV1(chunk(1), PEER)
		assert.equal("*", Guild.requestsIndexSync.inFlight)
		Guild:ReceiveRequestsIndexV1(chunk(0), PEER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
	end)

	-- BYID-SYNC-END-001 (Peer Review 5b13bb3a, K4): every client hears every guild-wide index, so another
	-- peer's chunk switched the by-id sender and forgot the ids already asked of the first; the sync then
	-- settled on the second peer's answers. K5: chunks arriving did not restart the in-flight clock.
	it("K4: another peer's index does not forget the ids already asked of the sync's peer", function()
		notifying()
		Guild:ReceiveRequestsIndexV1(chunk(0, "m1"), PEER)
		Guild:ReceiveRequestsIndexV1(chunk(0, "m2"), OTHER)
		Guild:ReceiveRequestsByIdV1(rd2("m2"), OTHER)
		assert.equal(PEER, Guild.requestsIndexSync.inFlight, "settled on the other peer's answer")
		assert.equal(0, #outputs("Response", "Requests synced."))
		Guild:ReceiveRequestsByIdV1(rd2("m1"), PEER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(1, #outputs("Response", "Requests synced."))
	end)

	-- Peer Review 79dfbfd2, P1: a sender change emptied the by-id queue, so two peers' indexes interleaved in
	-- one sync dropped each other's unsent batches and those ids were never asked in that sync.
	local function byIdAsks()
		local asked = {}
		for _, s in ipairs(sendsOf("togbank-r")) do
			local p = decode(s)
			if p.type == "requests-by-id" then
				for _, id in ipairs(p.ids) do asked[id] = s.target end
			end
		end
		return asked
	end

	it("P1: two peers' interleaved indexes each have every missing id asked of their own peer", function()
		notifying()
		Guild:ReceiveRequestsIndexV1(index(51), PEER)
		Guild:ReceiveRequestsIndexV1(chunk(0, "x1"), OTHER)
		Guild:ReceiveRequestsIndexV1(chunk(0, "m52"), PEER)
		Guild:ReceiveRequestsIndexV1(chunk(0, "x2"), OTHER)
		env.advance(5); env.advance(5); env.advance(5); env.advance(5)
		local asked = byIdAsks()
		for i = 1, 52 do assert.equal(PEER, asked["m" .. i], "m" .. i .. " was not asked of its peer") end
		assert.equal(OTHER, asked.x1)
		assert.equal(OTHER, asked.x2)
		for i = 1, 52 do Guild:ReceiveRequestsByIdV1(rd2("m" .. i), PEER) end
		Guild:ReceiveRequestsByIdV1(rd2("x1"), OTHER)
		assert.equal(PEER, Guild.requestsIndexSync.inFlight, "settled with an id still unanswered")
		Guild:ReceiveRequestsByIdV1(rd2("x2"), OTHER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(1, #outputs("Response", "Requests synced."))
	end)

	-- P1/P2: a by-id ask refused because that peer went offline drops only that peer's batches, and the
	-- sync the user started does not claim success.
	it("P1: a peer gone offline loses only its own batches, and the sync says it was incomplete", function()
		notifying()
		Guild:ReceiveRequestsIndexV1(index(51), PEER)
		Guild:ReceiveRequestsIndexV1(chunk(0, "x1"), OTHER)
		for i = 1, 50 do Guild:ReceiveRequestsByIdV1(rd2("m" .. i), PEER) end
		local stubWhisper = Core.SendWhisper
		Core.SendWhisper = function(core, prefix, text, target, ...)
			if target == PEER then return false end
			return stubWhisper(core, prefix, text, target, ...)
		end
		env.advance(5); env.advance(5)
		Core.SendWhisper = stubWhisper
		assert.equal(OTHER, byIdAsks().x1, "the other peer's batch was dropped with the offline peer's")
		assert.equal(PEER, Guild.requestsIndexSync.inFlight)
		Guild:ReceiveRequestsByIdV1(rd2("x1"), OTHER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(0, #outputs("Response", "Requests synced."))
		assert.equal(1, #outputs("Response", "Request sync incomplete: a bank went offline before answering."))
	end)

	-- Peer Review f3453dc9, N2: the offline branch released the refused batch's ids and the queued ones, but
	-- not those of a batch already sent before the peer logged off, so the sync waited for the timeout.
	it("N2: a peer gone offline after its first batch went out ends the sync as incomplete, not on the timeout", function()
		notifying()
		Guild:ReceiveRequestsIndexV1(index(51), PEER)
		whisperOk = false
		env.advance(5)
		assert.is_nil(Guild.requestsIndexSync.inFlight, "waited on the batch sent before the peer logged off")
		assert.equal(0, #outputs("Response", "Requests synced."))
		assert.equal(1, #outputs("Response", "Request sync incomplete: a bank went offline before answering."))
	end)

	-- Peer Review f3453dc9, N1: nothing cancels the by-id drain. A new sync begun mid-drain (a CRC or G1
	-- re-ask) still sends the batches already queued, because the ids they ask for are still missing.
	it("N1: a sync begun while by-id batches are queued still sends them to the peer they were for", function()
		Guild:BeginRequestsIndexSync(PEER, true)
		Guild:ReceiveRequestsIndexV1(index(101), PEER)
		Guild:BeginRequestsIndexSync(PEER, true)
		env.advance(5); env.advance(5)
		local asked = byIdAsks()
		for i = 1, 101 do assert.equal(PEER, asked["m" .. i], "m" .. i .. " was dropped by the new sync") end
	end)

	it("P2: a re-ask to a peer who logged off says the sync failed, not 'Requests synced.'", function()
		notifying()
		whisperOk = false
		assert.is_false(Guild:QueryRequestsIndex(PEER, "NORMAL", true))
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(0, #outputs("Response", "Requests synced."))
		assert.equal(1, #outputs("Response", "Request sync failed: " .. PEER .. " is offline."))
	end)

	it("K5: each index chunk keeps a long index from timing out the sync", function()
		Guild:BeginRequestsIndexSync(PEER, true)
		Guild:ReceiveRequestsIndexV1(chunk(2), PEER)
		env.now = T0 + 170
		Guild:ReceiveRequestsIndexV1(chunk(1), PEER)
		env.now = T0 + 200
		assert.is_false(Guild:CanQueryRequestsIndex(OTHER), "timed out mid-index")
		assert.equal(PEER, Guild.requestsIndexSync.inFlight)
	end)

	-- Peer Review e3fd248b, M1: the in-flight timeout cleared the sync but not `notify`, so the next automatic
	-- sync printed 'Requests synced.' for the user's sync that never finished.
	it("M1: a user's sync that times out says so, and the next automatic sync prints nothing", function()
		notifying()
		Guild:ReceiveRequestsIndexV1(chunk(1), PEER)
		env.now = T0 + 181
		assert.is_true(Guild:CanQueryRequestsIndex(OTHER))
		assert.equal(1, #outputs("Response", "Request sync timed out."))
		assert.is_false(Guild.requestsIndexSync.notify)
		Guild:BeginRequestsIndexSync(PEER, true)
		Guild:ReceiveRequestsIndexV1(chunk(0), PEER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(0, #outputs("Response", "Requests synced."))
	end)

	it("M1: a muted sync's notify is cleared when it ends, so it never prints later", function()
		notifying()
		TOGBankClassic_Options.IsSyncProgressMuted = function() return true end
		Guild:ReceiveRequestsIndexV1(chunk(0), PEER)
		assert.is_false(Guild.requestsIndexSync.notify)
	end)

	-- Peer Review e3fd248b, G1: one index's chunks count down by one, so a bigger drop is a lost chunk; the
	-- sync re-asks that peer for its whole index instead of reading a short one as complete.
	local function indexQueriesTo(target)
		local n = 0
		for _, s in ipairs(sendsOf("togbank-r")) do
			if s.target == target and decode(s).type == "requests-index" then n = n + 1 end
		end
		return n
	end

	it("G1: a chunk count that skips one re-asks the sync's peer for its index", function()
		Guild:BeginRequestsIndexSync(PEER, true)
		Guild:ReceiveRequestsIndexV1(chunk(3), PEER)
		Guild:ReceiveRequestsIndexV1(chunk(2), PEER)
		assert.equal(0, indexQueriesTo(PEER), "an unbroken countdown re-asked")
		Guild:ReceiveRequestsIndexV1(chunk(0), PEER)
		assert.equal(1, indexQueriesTo(PEER))
		assert.equal(PEER, Guild.requestsIndexSync.inFlight, "the re-asked sync is not in flight")
	end)

	it("G1: a rising count is a new index, and another peer's gap is not this sync's to re-ask", function()
		Guild:BeginRequestsIndexSync(PEER, true)
		Guild:ReceiveRequestsIndexV1(chunk(0, "m1"), PEER)
		Guild:ReceiveRequestsIndexV1(chunk(4), PEER)
		Guild:ReceiveRequestsIndexV1(chunk(3), OTHER)
		Guild:ReceiveRequestsIndexV1(chunk(0), OTHER)
		assert.equal(0, indexQueriesTo(PEER))
		assert.equal(0, indexQueriesTo(OTHER))
	end)

	-- The state table is the same across syncs, so a guild query's 10 s check could end a later sync.
	it("a guild query's 10 s check does not end a later sync", function()
		assert.is_true(Guild:QueryRequestsIndex(nil, nil, true))
		env.advance(5)
		Guild:EndRequestsIndexSync()
		Guild:BeginRequestsIndexSync(PEER, true)
		env.advance(5)
		assert.equal(PEER, Guild.requestsIndexSync.inFlight, "the earlier query's check ended this sync")
	end)

	it("P3: a re-ask of one peer inside a guild-wide sync keeps it guild-wide past the 10 s check", function()
		assert.is_true(Guild:QueryRequestsIndex(nil, nil, true))
		env.advance(5)
		Guild:BeginRequestsIndexSync(PEER, true)
		env.advance(5)
		assert.equal("*", Guild.requestsIndexSync.inFlight, "the re-ask narrowed or ended the guild-wide sync")
	end)

	-- Peer Review 5063214b, P3: a re-ask of one peer during a guild-wide sync reset the whole sync, so the ids
	-- another peer still owed stopped holding it and 'Requests synced.' printed before their records arrived.
	it("P3: a re-ask of one peer in a guild-wide sync still waits for the ids another peer owes", function()
		TOGBankClassic_Options.IsSyncProgressMuted = function() return false end
		assert.is_true(Guild:QueryRequestsIndex(nil, nil, true))
		Guild.requestsIndexSync.notify = true
		Guild:ReceiveRequestsIndexV1(chunk(0, "x1"), OTHER)
		Guild:ReceiveRequestsIndexV1(chunk(3), PEER)
		Guild:ReceiveRequestsIndexV1(chunk(1), PEER)
		assert.equal(1, indexQueriesTo(PEER), "the lost chunk was not re-asked")
		Guild:ReceiveRequestsIndexV1(chunk(0), PEER)
		assert.equal("*", Guild.requestsIndexSync.inFlight, "settled with x1 still owed by the other peer")
		assert.equal(0, #outputs("Response", "Requests synced."))
		Guild:ReceiveRequestsByIdV1(rd2("x1"), OTHER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(1, #outputs("Response", "Requests synced."))
	end)

	it("P3: a re-ask refused in a guild-wide sync drops only that peer, and the sync says it was incomplete", function()
		TOGBankClassic_Options.IsSyncProgressMuted = function() return false end
		assert.is_true(Guild:QueryRequestsIndex(nil, nil, true))
		Guild.requestsIndexSync.notify = true
		Guild:ReceiveRequestsIndexV1(chunk(0, "x1"), OTHER)
		whisperOk = false
		assert.is_false(Guild:QueryRequestsIndex(PEER, "NORMAL", true))
		assert.equal("*", Guild.requestsIndexSync.inFlight, "ended with x1 still owed by the other peer")
		assert.equal(0, #outputs("Response", "Request sync failed: " .. PEER .. " is offline."))
		whisperOk = true
		Guild:ReceiveRequestsByIdV1(rd2("x1"), OTHER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(1, #outputs("Response", "Request sync incomplete: a bank went offline before answering."))
	end)

	-- Peer Review b0f108ef, F1: a CRC re-ask is not gated on the sync's peer, so a targeted sync of PEER that
	-- re-asked OTHER moved inFlight to OTHER: PEER's lost chunks stopped being re-asked, and a refused OTHER
	-- ended the sync 'failed' with PEER's ids still owed.
	it("F1: a re-ask of another peer during a targeted sync widens it, and the first peer is still read", function()
		notifying()
		Guild:ReceiveRequestsIndexV1(chunk(3, "m1"), PEER)
		whisperOk = false
		assert.is_false(Guild:QueryRequestsIndex(OTHER, "NORMAL", true))
		assert.equal("*", Guild.requestsIndexSync.inFlight, "the refused re-ask ended the sync with m1 still owed")
		assert.equal(0, #outputs("Response", "Request sync failed: " .. OTHER .. " is offline."))
		whisperOk = true
		Guild:ReceiveRequestsIndexV1(chunk(1), PEER)
		assert.equal(1, indexQueriesTo(PEER), "the first peer's lost chunk was not re-asked")
		Guild:ReceiveRequestsByIdV1(rd2("m1"), PEER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(1, #outputs("Response", "Request sync incomplete: a bank went offline before answering."))
	end)

	-- Peer Review 20851b90, A2: once a re-ask has widened a targeted sync, a refused re-ask of its FIRST peer is
	-- one peer of a guild-wide sync dropping out, not the whole sync failing; the widened peer's ids still hold it.
	it("A2: a refused re-ask of the first peer after the sync widened drops only that peer", function()
		notifying()
		assert.is_true(Guild:QueryRequestsIndex(OTHER, "NORMAL", true))
		assert.equal("*", Guild.requestsIndexSync.inFlight)
		Guild:ReceiveRequestsIndexV1(chunk(0, "x1"), OTHER)
		whisperOk = false
		assert.is_false(Guild:QueryRequestsIndex(PEER, "NORMAL", true))
		assert.equal(0, #outputs("Response", "Request sync failed: " .. PEER .. " is offline."))
		assert.equal("*", Guild.requestsIndexSync.inFlight, "ended with x1 still owed by the widened peer")
		assert.equal(OTHER, Guild.requestsIndexSync.pendingById.x1)
		whisperOk = true
		Guild:ReceiveRequestsByIdV1(rd2("x1"), OTHER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
		assert.equal(1, #outputs("Response", "Request sync incomplete: a bank went offline before answering."))
	end)

	-- Peer Review 20851b90, N1: a targeted sync recorded the chunk count of any peer it overheard, so another
	-- peer's guild broadcast that never finished held the sync open until INDEX_INFLIGHT_TIMEOUT.
	it("N1: another peer's unfinished broadcast does not hold a targeted sync open", function()
		notifying()
		Guild:ReceiveRequestsIndexV1(chunk(2), OTHER)
		Guild:ReceiveRequestsIndexV1(chunk(0, "m1"), PEER)
		Guild:ReceiveRequestsByIdV1(rd2("m1"), PEER)
		assert.is_nil(Guild.requestsIndexSync.inFlight, "waited on the other peer's broadcast")
		assert.equal(1, #outputs("Response", "Requests synced."))
	end)

	it("an older sender's chunk, which says nothing of what is to come, ends the sync once its ids are answered", function()
		Guild:BeginRequestsIndexSync(PEER, true)
		Guild:ReceiveRequestsIndexV1(chunk(nil, "m1"), PEER)
		Guild:ReceiveRequestsByIdV1(rd2("m1"), PEER)
		assert.is_nil(Guild.requestsIndexSync.inFlight)
	end)
end)

-- Peer Review 385b8033, T1: the full-record sync path wrote the request store with no sender, roster or
-- asked-for check, so one forged by-id record or tombstone did everything MUT-ID-001, ADD-OWNER-001 and
-- ADD-OPEN-001 refuse on the mutation path. Every example goes through the real receive path.
describe("T1: by-id answers and indexes are taken only from a peer, only when asked, never as a takeover", function()
	local STRANGER = "Stranger-Otherrealm"
	before_each(function()
		load()
		Guild:ApplyRequestSnapshot({ requests = { rec("a"), rec("b") } })
	end)
	after_each(restore)

	local function deliver(prefix, payload, from)
		TOGBankClassic_Chat:OnCommReceived(prefix, Core:SerializeWithChecksum(payload), "WHISPER", from)
	end
	local function rd2(r)
		return { 1, r.id, r.date, r.updatedAt, r.requester, r.bank, r.item, r.quantity, r.fulfilled, r.status, r.notes, r.itemID }
	end
	local function untouched()
		assert.equal("open", Guild.Info.requests.a.status)
		assert.equal(PEER, Guild.Info.requests.a.requester)
		assert.is_table(Guild.Info.requests.b)
		assert.equal(0, count(Guild.Info.requestsTombstones))
	end

	it("REQ-GATE-002: a non-guildmate's record, tombstone or index is dropped, even for an id asked of them", function()
		Guild:QueryRequestsById(STRANGER, { "a", "b" })
		deliver("togbank-rd2", rd2(rec("a", { status = "cancelled", updatedAt = T0 })), STRANGER)
		deliver("togbank-rd2", { 1, "b", false, T0 }, STRANGER)
		deliver("togbank-rd", { type = "requests-by-id", requests = { rec("a", { status = "cancelled", updatedAt = T0 }) },
			tombstones = { b = T0 } }, STRANGER)
		deliver("togbank-rm", { type = "requests-by-id", requests = { rec("a", { status = "cancelled", updatedAt = T0 }) } }, STRANGER)
		deliver("togbank-ri", { 1, 0, "a", T0, "b", T0 }, STRANGER)
		deliver("togbank-rd", { type = "requests-index", requests = {}, tombstones = { { id = "a", ts = T0 } } }, STRANGER)
		deliver("togbank-rm", { type = "requests-index", requests = {}, tombstones = { { id = "b", ts = T0 } } }, STRANGER)
		untouched()
	end)

	it("REQ-GATE-002: a corrupt index chunk re-asks a guildmate for the index, never a stranger", function()
		TOGBankClassic_Chat:OnCommReceived("togbank-ri", "not a payload", "WHISPER", STRANGER)
		assert.equal(0, #sendsOf("togbank-r"), "a stranger's corrupt chunk bought a whisper back")
		TOGBankClassic_Chat:OnCommReceived("togbank-ri", "not a payload", "WHISPER", PEER)
		local q = sendsOf("togbank-r")
		assert.equal(1, #q); assert.equal(PEER, q[1].target)
	end)

	it("BYID-ASKED-001: an answer nobody asked for, or from the wrong player, is dropped and does not end a sync", function()
		Guild:BeginRequestsIndexSync(PEER, true); Guild:MarkRequestsIndexAwaitingById()
		deliver("togbank-rd2", rd2(rec("a", { status = "cancelled", updatedAt = T0 })), OTHER)
		deliver("togbank-rd2", { 1, "b", false, T0 }, OTHER)
		deliver("togbank-rd", { type = "requests-by-id", requests = { rec("a", { status = "cancelled", updatedAt = T0 }) },
			tombstones = { b = T0 } }, OTHER)
		Guild:QueryRequestsById(PEER, { "a", "b" })
		deliver("togbank-rd2", rd2(rec("a", { status = "cancelled", updatedAt = T0 })), OTHER)
		deliver("togbank-rd2", { 1, "b", false, T0 }, OTHER)
		untouched()
		assert.equal(PEER, Guild.requestsIndexSync.inFlight, "an unasked answer ended the sync")
	end)

	it("BYID-ASKED-001: an asked-for answer merges once; a repeat, or one after the window, is dropped", function()
		Guild:QueryRequestsById(PEER, { "a", "b" })
		deliver("togbank-rd2", rd2(rec("a", { notes = "answered", updatedAt = T0 })), PEER)
		assert.equal("answered", Guild.Info.requests.a.notes)
		deliver("togbank-rd2", rd2(rec("a", { status = "cancelled", updatedAt = T0 + 1 })), PEER)
		assert.equal("open", Guild.Info.requests.a.status, "a second answer to one ask was merged")
		env.now = T0 + 301
		deliver("togbank-rd2", { 1, "b", false, T0 + 301 }, PEER)
		assert.is_table(Guild.Info.requests.b, "an answer after the window was merged")
	end)

	it("BYID-ASKED-001: an id asked of two players takes whichever answers first, once", function()
		Guild:QueryRequestsById(PEER, { "a" })
		Guild:QueryRequestsById(BANK2, { "a" })
		deliver("togbank-rd2", rd2(rec("a", { notes = "from peer", updatedAt = T0 })), PEER)
		assert.equal("from peer", Guild.Info.requests.a.notes, "the first askee's answer was dropped")
		deliver("togbank-rd2", rd2(rec("a", { notes = "from bank", updatedAt = T0 + 1 })), BANK2)
		assert.equal("from peer", Guild.Info.requests.a.notes, "a second answer to one id was merged")
	end)

	it("BYID-ASKED-001: an unanswered ask is swept once its window has passed", function()
		Guild:QueryRequestsById(PEER, { "a", "b" })
		assert.equal(2, Guild:GetRequestedByIdCount())
		env.now = T0 + 301
		Guild:QueryRequestsById(PEER, { "c" })
		assert.equal(1, Guild:GetRequestedByIdCount(), "expired asks were kept")
	end)

	it("BYID-ASKED-001: a query sent to the guild can be answered by any guildmate", function()
		Guild:QueryRequestsById(nil, { "b" })
		deliver("togbank-rd2", { 1, "b", false, T0 }, OTHER)
		assert.is_nil(Guild.Info.requests.b)
		assert.equal(T0, Guild.Info.requestsTombstones.b)
	end)

	it("BYID-WINDOW-001: a slow responder that keeps answering keeps its window open", function()
		Guild:QueryRequestsById(PEER, { "a", "b" })
		env.now = T0 + 250
		deliver("togbank-rd2", rd2(rec("a", { notes = "late a", updatedAt = T0 + 250 })), PEER)
		assert.equal("late a", Guild.Info.requests.a.notes)
		env.now = T0 + 500
		deliver("togbank-rd2", rd2(rec("b", { notes = "later b", updatedAt = T0 + 500 })), PEER)
		assert.equal("later b", Guild.Info.requests.b.notes, "a working responder's queued answer was dropped")
	end)

	it("BYID-WINDOW-001: a re-ask of one player does not extend another player's window", function()
		Guild:QueryRequestsById(PEER, { "a" })
		env.now = T0 + 200
		Guild:QueryRequestsById(BANK2, { "a" })
		env.now = T0 + 301
		deliver("togbank-rd2", rd2(rec("a", { notes = "from peer", updatedAt = T0 + 301 })), PEER)
		assert.equal("", Guild.Info.requests.a.notes, "the first askee's closed window was reopened by the second ask")
		deliver("togbank-rd2", rd2(rec("a", { notes = "from bank", updatedAt = T0 + 301 })), BANK2)
		assert.equal("from bank", Guild.Info.requests.a.notes)
	end)

	it("BYID-EMPTY-001: an empty legacy by-id table from the askee does not end a sync", function()
		Guild:BeginRequestsIndexSync(PEER, true); Guild:MarkRequestsIndexAwaitingById()
		Guild:QueryRequestsById(PEER, { "a" })
		deliver("togbank-rd", { type = "requests-by-id", requests = {}, tombstones = {} }, PEER)
		assert.equal(PEER, Guild.requestsIndexSync.inFlight, "an empty answer ended the sync")
	end)

	it("BYID-ASKED-001: a legacy by-id table keeps the asked ids and drops the rest", function()
		Guild:BeginRequestsIndexSync(PEER, true); Guild:MarkRequestsIndexAwaitingById()
		Guild:QueryRequestsById(PEER, { "a" })
		deliver("togbank-rd", { type = "requests-by-id", requests = { rec("a", { notes = "asked", updatedAt = T0 }) },
			tombstones = { b = T0 } }, PEER)
		assert.equal("asked", Guild.Info.requests.a.notes)
		assert.is_table(Guild.Info.requests.b, "an unasked tombstone in the same payload was merged")
		assert.is_nil(Guild.requestsIndexSync.inFlight, "an asked answer did not end the sync")
	end)

	it("BYID-ASKED-001: a legacy by-id table from the wrong player after an ask is dropped", function()
		Guild:QueryRequestsById(PEER, { "a", "b" })
		deliver("togbank-rd", { type = "requests-by-id", requests = { rec("a", { status = "cancelled", updatedAt = T0 }) },
			tombstones = { b = T0 } }, OTHER)
		untouched()
		deliver("togbank-rd2", rd2(rec("a", { notes = "from peer", updatedAt = T0 })), PEER)
		assert.equal("from peer", Guild.Info.requests.a.notes, "the wrong player's answer used up the ask")
	end)

	it("SYNC-OWNER-001: an asked-for record naming another requester for a held order is refused", function()
		Guild:QueryRequestsById(PEER, { "a" })
		deliver("togbank-rd2", rd2(rec("a", { requester = OTHER, quantity = 99, updatedAt = T0 })), PEER)
		Guild:ApplyRequestSnapshot({ requests = { rec("b", { requester = OTHER, status = "cancelled", updatedAt = T0 }) } })
		assert.equal(PEER, Guild.Info.requests.a.requester)
		assert.equal(5, Guild.Info.requests.a.quantity)
		assert.equal(PEER, Guild.Info.requests.b.requester)
		assert.equal("open", Guild.Info.requests.b.status)
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
		-- BYID-SYNC-END-001: each chunk ends `false, <chunks still to come>`; an older reader's tombstone loop
		-- stops at the `false`, so the second chunk still carries no tombstones for it.
		assert.same({ false, 1 }, { first[47], first[48] })
		assert.equal(1, second[2])
		assert.same({ false, 0 }, { second[5], second[6] }, "the tombstones were repeated in a later chunk")
		assert.is_nil(second[7])
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
