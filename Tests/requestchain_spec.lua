-- THE REQUEST CHAIN, END TO END — one player's order reaching another player's list.
--
-- WHY THIS FILE EXISTS, and it is a gap the operator found rather than a routine addition. The
-- request framework had NO end-to-end coverage at all: `sendresult_spec` tests the send CALLBACK
-- plumbing (whether a refusal is detected), and nothing anywhere drove a mutation from one client's
-- `AddRequest` through to another client's `Info.requests`. So the whole of request propagation was
-- resting on the send half being green.
--
-- THAT MATTERED IMMEDIATELY. `togbank-rm` is a SHARED prefix: it carries `requests-index`,
-- `requests-by-id` and `requests-log` for the request framework, and it also used to carry a
-- `data.type == "alt"` branch handing legacy inventory to `Guild:ReceiveAltData`. Deleting that
-- inventory branch (INV2 step 10) meant editing the same handler the request branches live in --
-- and with no end-to-end test, a break in request receive would not have shown up in a green suite.
-- The operator asked the right question: "are you sure you didn't break anything with the requests
-- propagating?" These examples are the answer, and they would fail if the answer were no.
--
-- REAL ENVELOPE, REAL DISPATCH. This loads the actual Core.lua with AceSerializer and drives
-- `Chat:OnCommReceived` with the bytes `BroadcastRequestMutation` really produced. A hand-built
-- payload delivered straight to `ReceiveRequestMutations` would skip the prefix dispatch, which is
-- precisely the layer under test.
--
-- HOW TWO CLIENTS ARE MODELLED IN ONE LUA STATE: capture what client A puts on the wire, then wipe
-- the request table to stand in for client B -- a different player who has never seen this order --
-- and deliver A's bytes. What crosses between them is a serialised string and nothing else, so
-- neither side can accidentally share a table reference and manufacture agreement.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local GUILD = "Testguild"
local ME    = "Requester-Testrealm"
local PEER  = "Someoneelse-Testrealm"

--- Everything sent, in order, so an example can find the message it cares about.
local sent

local function loadRequestStack()
	env.stubOutput()
	require("env.ace").load("AceAddon-3.0", "AceComm-3.0", "AceConsole-3.0",
		"AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
	require("env.libs").load("AceCommQueue-1.0")

	env.loadModules({
		"Modules/Constants.lua",
		"Modules/Switches.lua",
		"Modules/Item.lua",
		"Modules/Inventory/Record.lua",
		"Modules/Inventory/Resolve.lua",
		"Modules/Inventory/Store.lua",
		"Modules/Inventory/Scan.lua",
		"Modules/Inventory/Wire.lua",
		"Modules/DeltaComms.lua",
		"Modules/Guild.lua",
		"Modules/RequestLog.lua",
		"Modules/Chat.lua",
	})

	-- AceAddon refuses a second NewAddon for the same name and the suite shares one Lua state.
	local AceAddon = LibStub("AceAddon-3.0")
	if AceAddon and AceAddon.addons then
		AceAddon.addons["TOGBankClassic"] = nil
		if AceAddon.addonstatus then AceAddon.addonstatus["TOGBankClassic"] = nil end
	end
	env.loadFile("Core.lua")

	-- A REAL CLOCK, not the harness default of 0. Request mutations are ordered by `ts`, and the
	-- tombstone is only recorded when `entryTs > tombstoneTs` -- which at a frozen zero is `0 > 0`
	-- and can never be true. A delete would then remove the order and record NO tombstone, so the
	-- next peer holding it re-adds it. That is an artefact of the stopped clock rather than a
	-- defect, but it is the kind of artefact that reads exactly like one.
	env.now = 1757000000

	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	TOGBankClassic_Database = {
		db = { global = { switches = {} }, faction = {} },
		SaveSnapshot = function() return true end,
		RecordDeltaReceived = function() end,
		RecordNoChangeSent = function() end,
	}
	TOGBankClassic_Options = {
		IsIntegrityCheckDiagnosticsEnabled = function() return false end,
		IsSyncProgressMuted = function() return true end,
		GetBankEnabled = function() return true end,
		-- Reached only once the clock is realistic: FinalizeMutation prunes, and pruning asks how
		-- old a tombstone may get. With the harness clock at 0 nothing looked stale so this was
		-- never called, which is why a realistic timestamp surfaced it.
		GetAutoTombstoneDays = function() return 30 end,
		GetMaxRequestPercent = function() return 100 end,
	}

	TOGBankClassic_Guild.Info = {
		name = GUILD,
		alts = {},
		requests = {},
		requestsTombstones = {},
		settings = {},
	}
	-- THE REAL NormalizeName IS USED, DELIBERATELY. This fixture used to stub it as
	-- `n:find("-") and n or (n .. "-Testrealm")`, which is LOOSER than the real function on exactly
	-- the inputs AUDIT-S4 is about: the real NormalizePlayerName returns nil for "-Realm" (empty
	-- character part), the stub returned "-Realm" as-is, so the malformed-sender examples below
	-- could not go red against it. The stub existed for determinism, and the env already provides
	-- that -- GetNormalizedRealmName returns "Testrealm" -- so the real function yields the same
	-- names for every well-formed input and the right nil for the malformed ones. CMD-001 class:
	-- a stub looser than the real thing is how a hole stays invisible.
	TOGBankClassic_Guild.GetNormalizedPlayer = function() return ME end
	TOGBankClassic_Guild.GetPlayer = function() return ME end
	TOGBankClassic_Guild.GetBanks = function() return { PEER } end
	TOGBankClassic_Guild.IsBank = function(_, n) return n == PEER end
	TOGBankClassic_Guild.CanManageRequests = function() return true end
	TOGBankClassic_Guild.UpdateOnlineMember = function() end
	TOGBankClassic_Guild.IsPlayerOnline = function() return true end
	TOGBankClassic_Guild.SenderHasGbankNote = function() return true end

	-- Capture the wire rather than sending it. This is the ONLY stub in the chain: everything from
	-- AddRequest through serialisation, and everything from OnCommReceived through the merge, is the
	-- shipped code.
	sent = {}
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, body, dist, target, _, cb, cbArg)
		sent[#sent + 1] = { prefix = prefix, body = body, dist = dist, target = target }
		if cb then cb(cbArg, #tostring(body), #tostring(body), true) end
	end
	TOGBankClassic_Core.SendWhisper = function(_, prefix, body, target)
		sent[#sent + 1] = { prefix = prefix, body = body, target = target }
		return true
	end

	return TOGBankClassic_Guild
end

--- The last thing put on `prefix`, or nil.
local function lastSentOn(prefix)
	for i = #sent, 1, -1 do
		if sent[i].prefix == prefix then return sent[i] end
	end
	return nil
end

--- The last MUTATION of a given kind, chosen by decoding the payload rather than by position.
---
--- Position is not reliable here and that cost three failing examples before it was understood: a
--- mutation is followed by `FinalizeMutation`, which touches the version and can prune, and those
--- put further traffic on the SAME `togbank-rm` prefix. "The last thing sent" is therefore often not
--- the mutation just performed, and delivering the wrong message reads as the mutation being
--- rejected -- which is indistinguishable from a permission gate refusing it.
local function lastMutation(kind)
	for i = #sent, 1, -1 do
		local msg = sent[i]
		if msg.prefix == "togbank-rm" then
			local ok, decoded = TOGBankClassic_Core:DeserializeWithChecksum(msg.body,
				{ sender = ME, prefix = msg.prefix })
			if ok and type(decoded) == "table" and type(decoded.logEntries) == "table" then
				local first = decoded.logEntries[1]
				if first and first.type == kind then return msg end
			end
		end
	end
	return nil
end

--- Stand in for a THIRD character -- neither the requester nor the banker.
---
--- Needed wherever the message under test is sent BY the banker: `becomeFreshPeer` makes the local
--- player PEER, and delivering a message from PEER to PEER is a message from yourself, which the
--- addon correctly ignores. That looked exactly like the merge rejecting the mutation, and only
--- instrumenting `ApplyRequestMutation` (never reached) told the two apart.
local THIRD = "Thirdplayer-Testrealm"
local function becomeThirdParty()
	TOGBankClassic_Guild.Info.requests = {}
	TOGBankClassic_Guild.Info.requestsTombstones = {}
	TOGBankClassic_Guild.GetNormalizedPlayer = function() return THIRD end
	TOGBankClassic_Guild.GetPlayer = function() return THIRD end
end

--- Stand in for a DIFFERENT client: same addon, none of this order's history.
local function becomeFreshPeer()
	TOGBankClassic_Guild.Info.requests = {}
	TOGBankClassic_Guild.Info.requestsTombstones = {}
	TOGBankClassic_Guild.GetNormalizedPlayer = function() return PEER end
	TOGBankClassic_Guild.GetPlayer = function() return PEER end
end

--- Deliver a captured message through the REAL prefix dispatch.
local function deliver(msg, from)
	assert.is_table(msg,
		"nothing was captured for this prefix, so the example would assert against a message that " ..
		"was never sent -- fix the fixture rather than letting it pass")
	TOGBankClassic_Chat:OnCommReceived(msg.prefix, msg.body, msg.dist or "GUILD", from or ME)
end

local function addOrder(item, qty)
	return TOGBankClassic_Guild:AddRequest({
		requester = ME, bank = PEER, item = item, quantity = qty or 1,
	})
end

local function orderFor(item)
	for _, req in pairs(TOGBankClassic_Guild.Info.requests or {}) do
		if req.item == item then return req end
	end
	return nil
end

describe("REQUEST CHAIN: a mutation reaches another player's list", function()
	before_each(function() env.reset(); loadRequestStack() end)

	-- THE ONE THAT COVERS THE EDIT. If the `togbank-rm` handler were damaged by removing the
	-- inventory branch that shared it, this is what goes red.
	it("propagates a NEW order from one client to another", function()
		assert.is_true(addOrder("Copper Bar", 20), "precondition: the order was not created locally")

		local msg = lastSentOn("togbank-rm")
		assert.is_table(msg, "AddRequest put nothing on togbank-rm, so nothing propagates at all")

		becomeFreshPeer()
		assert.is_nil(orderFor("Copper Bar"), "precondition: the peer already had the order")

		deliver(msg, ME)

		local got = orderFor("Copper Bar")
		assert.is_table(got,
			"a new order did NOT reach the other client. The togbank-rm handler carries request " ..
			"mutations AND used to carry a legacy inventory branch; if that deletion damaged the " ..
			"dispatch, request propagation stops and nothing else in the suite would notice")
		assert.equal(20, got.quantity)
	end)

	it("propagates a CANCEL", function()
		addOrder("Tin Bar", 5)
		local id = orderFor("Tin Bar").id

		TOGBankClassic_Guild:CancelRequest(id, ME)
		local msg = lastSentOn("togbank-rm")

		becomeFreshPeer()
		deliver(msg, ME)

		local got = TOGBankClassic_Guild.Info.requests[id]
		assert.is_table(got, "the cancel did not create the order on the peer at all")
		assert.equal("cancelled", got.status,
			"a cancelled order arrived without its cancelled status, so the peer keeps showing it " ..
			"as open and a banker may fill an order nobody wants")
	end)

	-- DELIVERED FROM THE BANKER, and that is not a fixture detail -- `complete` is gated to bankers
	-- and GMs (ApplyRequestMutation -> CanCompleteRequest), so who it arrives FROM decides whether
	-- it applies. My first version of this example delivered from an ordinary player and the
	-- mutation was correctly refused; the gate working is what it caught.
	-- THE REALISTIC SHAPE: the peer already HAS the open order -- everyone sees an order while it is
	-- open -- and the completion has to close it on their copy. My first version delivered to a peer
	-- that had never seen the order at all, which is a different question (should a closed order be
	-- created from nothing?) and not the one that matters for propagation.
	-- DECLARED PENDING, NOT DELETED AND NOT WEAKENED. I could not stand this fixture up and I do not
	-- yet know whether the cause is the fixture or the code, so leaving it green by loosening the
	-- assertion would be the worst of the three options.
	--
	-- WHAT IS ESTABLISHED: `mergeRequest` (RequestLog.lua:591-635) reads correctly for this case --
	-- existing open, incoming terminal, incoming `updatedAt` higher -> `requests[id] = clean`, so
	-- the status should become complete. The permission gate is also satisfied (delivered from the
	-- order's own bank, which `CanCompleteRequest` accepts at :1837). The fixture advances the clock
	-- 60s between the order and its completion so the incoming record IS newer.
	--
	-- WHAT IS NOT: why the peer's copy stays open regardless. Next step is to log the mergeRequest
	-- branch actually taken rather than reason about it further.
	--
	-- WHY IT IS WORTH KEEPING VISIBLE: if this turns out to be the code, the consequence is that a
	-- filled order stays OPEN on every other player's list, and a second banker may fill it again.
	it("propagates a COMPLETE from the banker onto the peer's open copy", function()
		addOrder("Silver Bar", 3)
		local open = orderFor("Silver Bar")
		local id = open.id
		local openCopy = {}
		for k, v in pairs(open) do openCopy[k] = v end

		-- TIME MUST MOVE between the order and its completion. Merging is last-writer-wins on
		-- `updatedAt`, so at a frozen clock the completion carries the SAME timestamp as the open
		-- copy and is discarded as not-newer -- which reads as the completion failing to propagate
		-- when it is the fixture standing still.
		env.now = env.now + 60

		TOGBankClassic_Guild:CompleteRequest(id, PEER)
		local msg = lastMutation("complete")

		becomeThirdParty()
		TOGBankClassic_Guild.Info.requests[id] = openCopy
		assert.equal("open", TOGBankClassic_Guild.Info.requests[id].status,
			"precondition: the peer's copy was not open, so closing it proves nothing")

		-- INSTRUMENTED rather than reasoned about: several rounds of reading the merge logic did not
		-- explain the failure, which is the point at which to measure. Capturing the entry the
		-- receiver actually sees, and what ApplyRequestMutation makes of it, localises the break to
		-- one of three places instead of leaving "it stayed open" as the only evidence.
		local seenEntry, applyResult
		local realApply = TOGBankClassic_Guild.ApplyRequestMutation
		TOGBankClassic_Guild.ApplyRequestMutation = function(selfRef, entry, from)
			seenEntry = entry
			applyResult = realApply(selfRef, entry, from)
			return applyResult
		end

		deliver(msg, PEER)
		TOGBankClassic_Guild.ApplyRequestMutation = realApply

		assert.is_table(seenEntry,
			"ApplyRequestMutation was never reached, so the break is in the prefix dispatch or in " ..
			"ReceiveRequestMutations, not in the merge")
		assert.equal("complete", seenEntry.type,
			"the entry that arrived was not the completion")
		assert.is_table(seenEntry.request,
			"the completion arrived with NO request snapshot, so there is nothing to merge -- " ..
			"ApplyRequestMutation falls through to its 'no request data' branch and returns false")
		assert.equal("complete", seenEntry.request.status,
			"the completion travelled with status=" .. tostring(seenEntry.request.status) ..
			", so the sender broadcast the order BEFORE marking it complete")
		assert.is_true(applyResult or false,
			"ApplyRequestMutation REJECTED the completion. Permission and merge both read as " ..
			"correct for this case, so this is where to look next")

		local got = TOGBankClassic_Guild.Info.requests[id]
		assert.is_table(got, "the peer's copy of the order vanished instead of being updated")
		assert.equal("complete", got.status,
			"a completed order stayed OPEN on the peer, so every other player keeps seeing an " ..
			"order that has already been filled, and a second banker may fill it again")
	end)

	it("REFUSES a complete from someone who is neither banker nor GM", function()
		addOrder("Silver Bar", 3)
		local id = orderFor("Silver Bar").id
		TOGBankClassic_Guild:CompleteRequest(id, PEER)
		local msg = lastMutation("complete")

		becomeFreshPeer()
		deliver(msg, "Randomplayer-Testrealm")

		assert.is_nil(TOGBankClassic_Guild.Info.requests[id],
			"an ordinary player closed somebody else's order on every client in the guild")
	end)

	-- A delete is a TOMBSTONE, not an absence: it has to travel, or the order comes back from any
	-- peer that still holds it on the next sync.
	it("propagates a DELETE as a tombstone, from a GM", function()
		addOrder("Gold Bar", 1)
		local id = orderFor("Gold Bar").id

		-- DeleteRequest is GM-gated on the SENDING side too, so without this nothing is broadcast
		-- and the example fails with "nothing was captured" rather than telling you anything.
		TOGBankClassic_Guild.SenderIsGM = function(_, p)
			return TOGBankClassic_Guild:NormalizeName(p) == ME
		end
		TOGBankClassic_Guild:DeleteRequest(id, ME)
		local msg = lastMutation("delete")

		becomeFreshPeer()
		TOGBankClassic_Guild.SenderIsGM = function(_, p)
			return TOGBankClassic_Guild:NormalizeName(p) == ME
		end
		-- The peer still holds the order, which is the case a tombstone exists for.
		TOGBankClassic_Guild.Info.requests[id] = { id = id, item = "Gold Bar", quantity = 1, status = "open" }

		deliver(msg, ME)

		assert.is_nil(TOGBankClassic_Guild.Info.requests[id],
			"a deleted order survived on the peer. Without the tombstone landing, the order is " ..
			"resurrected from that peer at the next sync and cannot be got rid of")
		assert.is_not_nil((TOGBankClassic_Guild.Info.requestsTombstones or {})[id],
			"the order was removed but NO tombstone was recorded, so the next peer holding it " ..
			"re-adds it and the delete undoes itself")
	end)

	-- TWO DIFFERENT GM CHECKS, and conflating them is what made this example hard to stand up:
	-- `DeleteRequest` gates the SENDER locally (no GM, no broadcast at all), and
	-- `ApplyRequestMutation` gates the RECEIVER. This drives the receive-side gate, so the message
	-- has to be produced by an authorised sender first and only then arrive from somebody who is not.
	it("REFUSES a delete from a non-GM", function()
		addOrder("Gold Bar", 1)
		local id = orderFor("Gold Bar").id
		TOGBankClassic_Guild.SenderIsGM = function(_, p)
			return TOGBankClassic_Guild:NormalizeName(p) == ME
		end
		TOGBankClassic_Guild:DeleteRequest(id, ME)
		local msg = lastMutation("delete")

		becomeFreshPeer()
		-- On THIS client nobody is a GM, so the arriving delete must be refused.
		TOGBankClassic_Guild.SenderIsGM = function() return false end
		TOGBankClassic_Guild.Info.requests[id] = { id = id, item = "Gold Bar", quantity = 1, status = "open" }

		deliver(msg, "Randomplayer-Testrealm")

		assert.is_table(TOGBankClassic_Guild.Info.requests[id],
			"a non-GM deleted an order for the whole guild -- delete is the one mutation that " ..
			"cannot be undone by re-sending, so its permission gate is the one that matters most")
	end)

	-- AUDIT-S4. ApplyRequestMutation used to collapse "no sender" and "sender that does not resolve"
	-- into one nil, and every permission gate was wrapped in `if normSender then` -- so a DELETE from
	-- a sender whose name failed to normalise applied with NO GM CHECK AT ALL. NormalizePlayerName
	-- returns nil in exactly two places, traced by peer review: a trimmed-empty name, and an empty
	-- character-part before the hyphen. Both are driven here, through the real receive path, and both
	-- must be REFUSED rather than applied unchecked or treated as a local apply.
	--
	-- Latent rather than live -- the real sender is server-supplied and a hostile client does not
	-- control it -- but the function is public and was safe only because of its one caller.
	describe("AUDIT-S4: a sender that does not resolve is refused, not trusted", function()
		local function deleteFromMalformedSender(sender)
			addOrder("Gold Bar", 1)
			local id = orderFor("Gold Bar").id
			TOGBankClassic_Guild.SenderIsGM = function(_, p)
				return TOGBankClassic_Guild:NormalizeName(p) == ME
			end
			TOGBankClassic_Guild:DeleteRequest(id, ME)
			local msg = lastMutation("delete")

			becomeFreshPeer()
			-- A GM check that would say YES to anyone, so the only thing standing between the
			-- malformed sender and the delete is the resolve gate under test.
			TOGBankClassic_Guild.SenderIsGM = function() return true end
			TOGBankClassic_Guild.Info.requests[id] = { id = id, item = "Gold Bar", quantity = 1, status = "open" }

			deliver(msg, sender)
			return id
		end

		it("refuses a delete from an empty sender name", function()
			local id = deleteFromMalformedSender("")
			assert.is_table(TOGBankClassic_Guild.Info.requests[id],
				"an EMPTY sender name deleted an order. The name did not resolve, so the old code " ..
				"took the nil for 'local apply, no auth needed' and skipped the GM gate (AUDIT-S4)")
		end)

		it("refuses a delete from a sender with no character part", function()
			local id = deleteFromMalformedSender("-Testrealm")
			assert.is_table(TOGBankClassic_Guild.Info.requests[id],
				"a sender of '-Realm' deleted an order -- the second of the two inputs that " ..
				"normalise to nil (AUDIT-S4)")
		end)

		-- Driven at the public function directly: the wire always supplies a sender (AceComm fills it
		-- in), and this fixture's `deliver` defaults a nil to ME, so a nil can only reach
		-- ApplyRequestMutation from a caller that passes it on purpose -- which is the case the
		-- state exists to refuse.
		it("refuses a delete with no sender at all rather than treating it as local", function()
			addOrder("Gold Bar", 1)
			local id = orderFor("Gold Bar").id
			TOGBankClassic_Guild.SenderIsGM = function() return true end
			local applied = TOGBankClassic_Guild:ApplyRequestMutation(
				{ type = "delete", requestId = id, ts = env.now + 60 }, nil)
			assert.is_false(applied, "a nil sender was accepted")
			assert.is_table(TOGBankClassic_Guild.Info.requests[id],
				"a nil sender was treated as a local apply. No caller applies mutations locally; " ..
				"a future one must add an explicit flag, not acquire unauthenticated writes by " ..
				"passing nil (AUDIT-S4)")
		end)

		-- The gate must not have broken the authenticated path: the same message from a resolving
		-- GM still applies. (The GM-delete example above already proves this; this one pins it in
		-- the same fixture so the two cannot drift apart.)
		it("still applies the same delete from a resolving GM", function()
			local id = deleteFromMalformedSender(ME)
			assert.is_nil(TOGBankClassic_Guild.Info.requests[id],
				"the resolve gate refused a sender that DOES resolve")
		end)
	end)

	-- The request branches and the deleted inventory branch shared one handler. This asserts the
	-- deletion was surgical: requests still work (above) AND inventory no longer rides this prefix.
	it("IGNORES a legacy inventory payload on the request prefix", function()
		becomeFreshPeer()
		local body = TOGBankClassic_Core:SerializeWithChecksum({
			type = "alt",
			name = PEER,
			alt = { name = PEER, items = { { ID = 858, Count = 99 } }, money = 0 },
		})

		assert.has_no_error(function()
			TOGBankClassic_Chat:OnCommReceived("togbank-rm", body, "GUILD", PEER)
		end, "an alt payload on the request prefix raised rather than being ignored")

		local alt = TOGBankClassic_Guild.Info.alts[PEER]
		assert.is_true(alt == nil or alt.items == nil or #alt.items == 0,
			"inventory arrived through the REQUEST prefix. That was a second receive path which " ..
			"never met the tuples-only guard on togbank-d4, and the no-backwards-compatibility " ..
			"directive deleted it -- if it is back, the directive is being enforced on one " ..
			"inventory path and not the other")
	end)
end)

describe("REQUEST CHAIN: the index and by-id query", function()
	before_each(function() env.reset(); loadRequestStack() end)

	-- The other half of the chain: a peer advertises a version, and a client that disagrees asks
	-- for the records by id. Nothing drove this end to end before either.
	it("puts an index on the wire that another client can receive", function()
		addOrder("Mageweave Cloth", 10)

		TOGBankClassic_Guild:SendRequestsIndex(PEER)
		env.flushTimers()   -- the index send stages through C_Timer; without this nothing is on the wire yet

		local msg = lastSentOn("togbank-ri") or lastSentOn("togbank-rd")
		assert.is_table(msg,
			"no request index reached the wire, so a peer has no way to learn that this client's " ..
			"request list has moved")

		becomeFreshPeer()
		assert.has_no_error(function() deliver(msg, ME) end,
			"the index could not be received through the real prefix dispatch")
	end)

	-- The index is what tells a peer WHICH orders exist and how fresh each one is. If it arrives
	-- carrying nothing, the peer concludes the sender has no orders and never asks for any.
	it("carries the orders it knows about", function()
		addOrder("Mageweave Cloth", 10)
		addOrder("Runecloth", 4)

		TOGBankClassic_Guild:SendRequestsIndex(PEER)
		env.flushTimers()   -- the index send stages through C_Timer; without this nothing is on the wire yet
		local msg = lastSentOn("togbank-ri") or lastSentOn("togbank-rd")
		assert.is_table(msg, "no index reached the wire")

		local ok, decoded = TOGBankClassic_Core:DeserializeWithChecksum(msg.body,
			{ sender = ME, prefix = msg.prefix })
		assert.is_true(ok, "the index did not survive the real checksum envelope")
		assert.is_table(decoded)
		assert.is_true(#tostring(msg.body) > 0,
			"an empty index is indistinguishable from 'this player has no orders'")
	end)
end)
