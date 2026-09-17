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
	env.loadDeltaSync()   -- DS-HOST-001: Core needs the host

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

--- Place an order. `extra` merges further fields onto the request -- `{ shopOrder = true }` while
--- the shop is selling (SHOP-NOFREE-001), because a plain request is then refused by design.
local function addOrder(item, qty, extra)
	local req = { requester = ME, bank = PEER, item = item, quantity = qty or 1 }
	for k, v in pairs(extra or {}) do req[k] = v end
	return TOGBankClassic_Guild:AddRequest(req)
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

-- ─── STORE-006: the shop's open/closed sign ────────────────────────────────────
--
-- GUILD_STORE.md 4.6, build-order step 1 (the operator, 2026-09-14: "can we not do this work now?").
-- One officer-set boolean on the guild-synced settings; off, Guild:AddRequest mints nothing. Run on
-- the REAL Guild + RequestLog + Chat dispatch of this fixture, with the wire captured, so the
-- broadcast is the shipped togbank-hl payload and the receive is the shipped ApplyRemoteSettings.
describe("STORE-006: the open/closed sign", function()
	before_each(function()
		env.reset(); loadRequestStack()
		-- BroadcastSettings sends only for a banker, officer or GM; make ME the officer.
		TOGBankClassic_Guild.SenderIsOfficer = function(_, n) return n == ME end
		TOGBankClassic_Guild.SenderIsGM = function() return false end
		-- SHOP-TAB-001: the sign and the list exist only while the guild's shop is on. On here;
		-- the example below is the one that turns it off.
		TOGBankClassic_Guild.Info.settings.shopEnabled = true
	end)

	local function infos()
		local out = {}
		for _, c in ipairs(TOGBankClassic_Output.calls) do if c.level == "Info" then out[#out + 1] = c[1] end end
		return out
	end

	--- The settings table inside the last guild-settings broadcast, decoded.
	local function lastSettingsBroadcast()
		for i = #sent, 1, -1 do
			local msg = sent[i]
			if msg.prefix == "togbank-hl" then
				local ok, decoded = TOGBankClassic_Core:DeserializeWithChecksum(msg.body, { sender = ME, prefix = msg.prefix })
				if ok and type(decoded) == "table" and decoded.type == "guild-settings" then return decoded.settings, msg end
			end
		end
		return nil
	end

	-- SHOP-TAB-001 (the operator, 2026-09-14): "a setting to turn it on/off ... off by default".
	it("with the shop OFF (the default) there is no sign and no list: ordering is open and nothing is blocked", function()
		TOGBankClassic_Guild.Info.settings.shopEnabled = nil
		assert.is_false(TOGBankClassic_Guild:IsShopEnabled(), "the shop is on by default")
		TOGBankClassic_Guild.Info.settings.storeOpen = false
		TOGBankClassic_Guild.Info.settings.notForSale = { [2589] = true }
		assert.is_true(TOGBankClassic_Guild:IsStoreOpen(), "a closed sign applied with the shop off")
		assert.is_false(TOGBankClassic_Guild:IsNotForSale(2589), "the shop list applied with the shop off")
		assert.is_true(TOGBankClassic_Guild:AddRequest({ requester = ME, bank = PEER, item = "Linen Cloth", itemID = 2589, quantity = 1 }))
		-- The ONE writer turns it on, broadcasts a real boolean, and the stored sign then applies.
		assert.is_true(TOGBankClassic_Guild:SetShopEnabled(true))
		assert.is_true(TOGBankClassic_Guild:IsShopEnabled())
		assert.is_false(TOGBankClassic_Guild:SetShopEnabled(true), "no change was reported as one")
		local settings = lastSettingsBroadcast()
		assert.is_true(settings.shopEnabled)
		assert.is_false(settings.storeOpen, "the broadcast carried the shop-gated read, not the stored sign")
		assert.is_false(TOGBankClassic_Guild:IsStoreOpen())
		assert.is_true(TOGBankClassic_Guild:IsNotForSale(2589))
		assert.truthy(infos()[#infos()]:find("Shop is ON", 1, true))
		-- It reaches a peer, and an old client's broadcast (no field) leaves it alone.
		local _, msg = lastSettingsBroadcast()
		becomeFreshPeer()
		TOGBankClassic_Guild.Info.settings = {}
		deliver(msg, ME)
		assert.is_true(TOGBankClassic_Guild:IsShopEnabled(), "the shop switch did not reach the peer")
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { maxRequestPercent = 100 } }) }, ME)
		assert.is_true(TOGBankClassic_Guild:IsShopEnabled(), "an old client's broadcast switched the shop off")
		-- Off again from the officer: the peer's shop goes, its stored sign and list stay inert.
		TOGBankClassic_Guild.GetNormalizedPlayer = function() return ME end
		TOGBankClassic_Guild.GetPlayer = function() return ME end
		assert.is_true(TOGBankClassic_Guild:SetShopEnabled(false))
		assert.truthy(infos()[#infos()]:find("Shop is OFF", 1, true))
		assert.is_true(TOGBankClassic_Guild:IsStoreOpen())
	end)

	it("is OPEN when the setting has never been written -- every guild ran without the sign", function()
		assert.is_nil(TOGBankClassic_Guild.Info.settings.storeOpen)
		assert.is_true(TOGBankClassic_Guild:IsStoreOpen())
		-- SHOP-NOFREE-001: open with the shop on is SELLING, so the order carries the shop mark.
		assert.is_true(addOrder("Copper Bar", 1, { shopOrder = true }))
	end)

	it("closed: nothing is minted, nothing goes on the wire, and the ONE writer broadcasts a real false", function()
		assert.is_true(TOGBankClassic_Guild:SetStoreOpen(false))
		assert.is_false(TOGBankClassic_Guild:IsStoreOpen())
		assert.is_false(TOGBankClassic_Guild.Info.settings.storeOpen)
		local settings = lastSettingsBroadcast()
		assert.is_table(settings, "closing did not broadcast the guild settings")
		assert.is_false(settings.storeOpen, "the sign went out as something other than a boolean false")
		assert.truthy(infos()[#infos()]:find("CLOSED", 1, true))
		-- A second close is not a change: no broadcast, no line, and the answer says so.
		local before = #sent
		assert.is_false(TOGBankClassic_Guild:SetStoreOpen(false))
		assert.equal(before, #sent)
		-- The gate: AddRequest refuses, and no togbank-rm mutation leaves the client.
		before = #sent
		assert.is_false(addOrder("Copper Bar", 1))
		assert.is_nil(orderFor("Copper Bar"))
		assert.equal(before, #sent, "a refused request still put something on the wire")
	end)

	it("reaches the other clients through the shipped settings broadcast, and reopens the same way", function()
		TOGBankClassic_Guild:SetStoreOpen(false)
		local _, closeMsg = lastSettingsBroadcast()
		becomeFreshPeer()
		TOGBankClassic_Guild.Info.settings = {}   -- a fresh peer has its own settings too
		assert.is_true(TOGBankClassic_Guild:IsStoreOpen(), "precondition: the peer started closed")
		deliver(closeMsg, ME)
		assert.is_false(TOGBankClassic_Guild:IsStoreOpen(), "the closed sign did not reach the peer")
		local ok, why = TOGBankClassic_Guild:AddRequest({ requester = PEER, bank = PEER, item = "Tin Bar", quantity = 1 })
		assert.is_false(ok)
		assert.equal(TOGBankClassic_Guild.STORE_CLOSED_TEXT, why, "the gate gave no reason (Peer Review f5e52bcf F9)")
		-- Reopen from the officer, delivered to the same peer.
		TOGBankClassic_Guild.GetNormalizedPlayer = function() return ME end
		TOGBankClassic_Guild.GetPlayer = function() return ME end
		assert.is_true(TOGBankClassic_Guild:SetStoreOpen(true))
		local _, openMsg = lastSettingsBroadcast()
		becomeFreshPeer()
		TOGBankClassic_Guild.Info.settings.storeOpen = false
		deliver(openMsg, ME)
		assert.is_true(TOGBankClassic_Guild:IsStoreOpen(), "the reopen did not reach the peer")
	end)

	it("a broadcast from a client that predates the sign does NOT reopen a closed shop", function()
		TOGBankClassic_Guild.Info.settings.storeOpen = false
		local old = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { maxRequestPercent = 100, autoTombstoneDays = 30 } })
		deliver({ prefix = "togbank-hl", body = old }, PEER)
		assert.is_false(TOGBankClassic_Guild:IsStoreOpen(), "an old client's settings broadcast reopened the shop")
		assert.equal(100, TOGBankClassic_Guild.Info.settings.maxRequestPercent, "the rest of the old broadcast was not applied")
		-- And a sender that carries the field as a non-boolean truthy closes rather than opens.
		local odd = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { storeOpen = "yes" } })
		deliver({ prefix = "togbank-hl", body = odd }, PEER)
		assert.is_false(TOGBankClassic_Guild:IsStoreOpen())
	end)

	-- STORE-006 step 2: the not-for-sale list, by itemID.
	it("not for sale: keyed by itemID, the ONE writer broadcasts the list, the gate refuses, an id-less request passes", function()
		assert.is_false(TOGBankClassic_Guild:IsNotForSale(2589))
		assert.is_true(TOGBankClassic_Guild:SetNotForSale(2589, true, "Linen Cloth"))
		assert.is_true(TOGBankClassic_Guild:IsNotForSale(2589))
		assert.is_true(TOGBankClassic_Guild:IsNotForSale("2589"), "a string id did not match")
		assert.is_false(TOGBankClassic_Guild:IsNotForSale(2590))
		local settings = lastSettingsBroadcast()
		assert.is_table(settings and settings.notForSale, "the list did not go out with the settings")
		assert.is_true(settings.notForSale[2589])
		assert.truthy(infos()[#infos()]:find("NOT FOR SALE", 1, true))
		-- Not a change: no second broadcast.
		local before = #sent
		assert.is_false(TOGBankClassic_Guild:SetNotForSale(2589, true))
		assert.equal(before, #sent)
		-- The gate: an itemID on the list mints nothing; the same name WITHOUT an id (an old client's
		-- request) still passes, because a name cannot be matched against an id list.
		before = #sent
		local ok, why = TOGBankClassic_Guild:AddRequest({ requester = ME, bank = PEER, item = "Linen Cloth", itemID = 2589, quantity = 1, shopOrder = true })
		assert.is_false(ok)
		assert.equal(TOGBankClassic_Guild.NOT_FOR_SALE_TEXT:format("Linen Cloth"), why, "the gate gave no reason (Peer Review f5e52bcf F9)")
		assert.equal(before, #sent, "a refused request still put something on the wire")
		assert.is_true(addOrder("Linen Cloth", 1, { shopOrder = true }), "an id-less request was refused by the id list")
		-- Back on sale: the list entry goes, the broadcast carries an EMPTY table, not nil.
		assert.is_true(TOGBankClassic_Guild:SetNotForSale(2589, false, "Linen Cloth"))
		assert.is_false(TOGBankClassic_Guild:IsNotForSale(2589))
		settings = lastSettingsBroadcast()
		assert.is_table(settings.notForSale)
		assert.is_nil(next(settings.notForSale))
		-- Garbage ids are refused by the writer.
		assert.is_false(TOGBankClassic_Guild:SetNotForSale("cloth", true))
		assert.is_false(TOGBankClassic_Guild:SetNotForSale(0, true))
		assert.is_false(TOGBankClassic_Guild:SetNotForSale(1.5, true))
	end)

	it("the list reaches a peer, is sanitized on the way in, and an old client's broadcast does not clear it", function()
		TOGBankClassic_Guild:SetNotForSale(2589, true)
		local _, msg = lastSettingsBroadcast()
		becomeFreshPeer()
		TOGBankClassic_Guild.Info.settings = {}
		deliver(msg, ME)
		assert.is_true(TOGBankClassic_Guild:IsNotForSale(2589), "the list did not reach the peer")
		-- A malformed list from a peer: string keys, zero, a fraction, a false value -- only the
		-- integer ids survive, and the cap holds.
		local junk = { [2590] = true, ["x"] = true, [0] = true, [1.5] = true, [2591] = false, ["2592"] = true }
		-- From ME, not PEER: the local player IS PEER after becomeFreshPeer, and a message from
		-- yourself is ignored (see becomeThirdParty's note). SETTINGS-002: a hand-built payload
		-- must be NEWER than what the peer holds to be heard at all.
		local v = TOGBankClassic_Guild:SettingsVersion()
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = v + 1, notForSale = junk } }) }, ME)
		assert.is_true(TOGBankClassic_Guild:IsNotForSale(2590))
		assert.is_true(TOGBankClassic_Guild:IsNotForSale(2592), "a numeric string key was dropped")
		assert.is_false(TOGBankClassic_Guild:IsNotForSale(2591))
		assert.is_false(TOGBankClassic_Guild:IsNotForSale(2589), "a delivered list did not REPLACE the held one")
		local n = 0
		for _ in pairs(TOGBankClassic_Guild.Info.settings.notForSale) do n = n + 1 end
		assert.equal(2, n)
		-- The cap: 600 valid ids arrive, 500 are kept (which 500 is pairs order, so only the count).
		local many = {}
		for i = 1, 600 do many[10000 + i] = true end
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = v + 2, notForSale = many } }) }, ME)
		n = 0
		for _ in pairs(TOGBankClassic_Guild.Info.settings.notForSale) do n = n + 1 end
		assert.equal(500, n, "the cap did not hold")
		-- A pre-STORE client's broadcast carries no list and clears nothing (and, carrying no
		-- version either, is not even heard by a client holding a stamped copy -- SETTINGS-002).
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { maxRequestPercent = 100 } }) }, ME)
		n = 0
		for _ in pairs(TOGBankClassic_Guild.Info.settings.notForSale) do n = n + 1 end
		assert.equal(500, n, "an old client's broadcast put everything back on sale")
		-- And the writer refuses a 501st.
		assert.is_false(TOGBankClassic_Guild:SetNotForSale(99999, true))
	end)

	-- STORE-003: the discount, a number on the same wire.
	it("the discount: the ONE writer bounds it, broadcasts it, a peer applies it, an old client leaves it, the shop off reads 0", function()
		assert.equal(0, TOGBankClassic_Guild:GetStoreDiscount())
		assert.is_false(TOGBankClassic_Guild:SetStoreDiscount(-1))
		assert.is_false(TOGBankClassic_Guild:SetStoreDiscount(101))
		assert.is_false(TOGBankClassic_Guild:SetStoreDiscount("half"))
		assert.is_true(TOGBankClassic_Guild:SetStoreDiscount(50.7))
		assert.equal(50, TOGBankClassic_Guild:GetStoreDiscount(), "not floored to a whole percent")
		assert.is_false(TOGBankClassic_Guild:SetStoreDiscount(50), "no change was reported as one")
		assert.truthy(infos()[#infos()]:find("Shop discount set to", 1, true))   -- the stub keeps the raw format
		local settings, msg = lastSettingsBroadcast()
		assert.equal(50, settings.storeDiscountPercent)
		-- A peer applies it; garbage and an old client's broadcast leave it; the shop off reads 0
		-- while the stored number is kept.
		becomeFreshPeer()
		TOGBankClassic_Guild.Info.settings = { shopEnabled = true }
		deliver(msg, ME)
		assert.equal(50, TOGBankClassic_Guild:GetStoreDiscount(), "the discount did not reach the peer")
		local v = TOGBankClassic_Guild:SettingsVersion()
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = v + 1, storeDiscountPercent = 500 } }) }, ME)
		assert.equal(50, TOGBankClassic_Guild:GetStoreDiscount(), "an out-of-range discount was applied")
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = v + 2, maxRequestPercent = 100 } }) }, ME)
		assert.equal(50, TOGBankClassic_Guild:GetStoreDiscount(), "a broadcast without the field cleared it")
		TOGBankClassic_Guild.Info.settings.shopEnabled = false
		assert.equal(0, TOGBankClassic_Guild:GetStoreDiscount())
		assert.equal(50, TOGBankClassic_Guild.Info.settings.storeDiscountPercent, "the stored number was lost with the shop off")
		-- Removing it says so.
		TOGBankClassic_Guild.GetNormalizedPlayer = function() return ME end
		TOGBankClassic_Guild.GetPlayer = function() return ME end
		assert.is_true(TOGBankClassic_Guild:SetStoreDiscount(0))
		assert.truthy(infos()[#infos()]:find("discount removed", 1, true))
	end)

	-- BANKER-OWNER-001: who runs each bank character, on the same wire.
	it("banker owners: the ONE writer trims, caps and clears, broadcasts the table, a peer applies it sanitized, an old client leaves it", function()
		local G = TOGBankClassic_Guild
		assert.is_nil(G:GetBankerOwner(PEER))
		assert.is_false(G:SetBankerOwner(nil, "x"))
		assert.is_false(G:SetBankerOwner(PEER, ""), "clearing nothing was reported as a change")
		assert.is_true(G:SetBankerOwner("Someoneelse", "  Alice  "))   -- a bare name is normalised
		assert.equal("Alice", G:GetBankerOwner(PEER))
		assert.equal("Alice", G:GetBankerOwner("Someoneelse"))
		assert.is_false(G:SetBankerOwner(PEER, "Alice"), "no change was reported as one")
		assert.truthy(infos()[#infos()]:find("is run by", 1, true))   -- the stub keeps the raw format
		local settings = lastSettingsBroadcast()
		assert.same({ [PEER] = "Alice" }, settings.bankerOwners)
		-- Free text, capped at 40.
		assert.is_true(G:SetBankerOwner(PEER, string.rep("shared account ", 5)))
		assert.equal(40, #G:GetBankerOwner(PEER))
		-- Clear: the entry goes, the broadcast carries an EMPTY table, not nil, and says so.
		assert.is_true(G:SetBankerOwner(PEER, ""))
		assert.is_nil(G:GetBankerOwner(PEER))
		settings = lastSettingsBroadcast()
		assert.is_table(settings.bankerOwners); assert.is_nil(next(settings.bankerOwners))
		assert.truthy(infos()[#infos()]:find("no owner listed", 1, true))
		-- A peer applies the delivered table, sanitized: non-string keys and values drop, text is
		-- trimmed and capped, the count is capped at 100.
		G:SetBankerOwner(PEER, "Alice")
		local _, msg = lastSettingsBroadcast()
		becomeFreshPeer()
		G.Info.settings = {}
		deliver(msg, ME)
		assert.equal("Alice", G:GetBankerOwner(PEER), "the owner did not reach the peer")
		local v = G:SettingsVersion()
		local junk = { [PEER] = "  Bob  ", [42] = "x", ["Other-Testrealm"] = 7, ["Third-Testrealm"] = "", ["Fourth-Testrealm"] = string.rep("y", 60) }
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = v + 1, bankerOwners = junk } }) }, ME)
		assert.equal("Bob", G:GetBankerOwner(PEER))
		assert.is_nil(G:GetBankerOwner("Other-Testrealm")); assert.is_nil(G:GetBankerOwner("Third-Testrealm"))
		assert.equal(40, #G:GetBankerOwner("Fourth-Testrealm"))
		local many = {}
		for i = 1, 150 do many["B" .. i .. "-Testrealm"] = "someone" end
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = v + 2, bankerOwners = many } }) }, ME)
		local n = 0
		for _ in pairs(G.Info.settings.bankerOwners) do n = n + 1 end
		assert.equal(100, n, "the cap did not hold")
		-- The writer refuses a 101st, and a broadcast without the field leaves the table alone.
		assert.is_false(G:SetBankerOwner("New-Testrealm", "someone"))
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = v + 3, maxRequestPercent = 100 } }) }, ME)
		n = 0
		for _ in pairs(G.Info.settings.bankerOwners) do n = n + 1 end
		assert.equal(100, n, "an old client's broadcast cleared the owners")
	end)

	it("SetStoreOpen with no Info is a no-op that says so", function()
		local info = TOGBankClassic_Guild.Info
		TOGBankClassic_Guild.Info = nil
		assert.is_false(TOGBankClassic_Guild:SetStoreOpen(false))
		assert.is_true(TOGBankClassic_Guild:IsStoreOpen())
		TOGBankClassic_Guild.Info = info
		-- And with Info but no settings table yet, it creates one.
		TOGBankClassic_Guild.Info.settings = nil
		assert.is_true(TOGBankClassic_Guild:SetStoreOpen(false))
		assert.is_false(TOGBankClassic_Guild.Info.settings.storeOpen)
	end)
end)

-- ─── SHOP-NOFREE-001: while the bank is selling, every request is a shop order ──
--
-- The operator, 2026-09-14: "when the shop tab is shown and ordering is enabled, there should be no
-- 'free' item requests." The gate is Guild:AddRequest (the one place a request is minted); the mark
-- is `shopOrder`, and STORE-004's estimate fields ride the record so a banker filling it sees what
-- the member was shown. Both wires -- the togbank-rm mutation and the positional togbank-rd2 record
-- -- carry them; the rd2 round trip had no example at all before this (REOPEN-001's arr[14] was
-- never driven end to end either), so this is the first.
describe("SHOP-NOFREE-001: no free requests while the bank is selling", function()
	before_each(function()
		env.reset(); loadRequestStack()
		TOGBankClassic_Guild.SenderIsOfficer = function(_, n) return n == ME end
		TOGBankClassic_Guild.SenderIsGM = function() return false end
	end)

	local SHOP = { shopOrder = true, estimate = 75, estimateBase = 151, discount = 50, estimateSource = "min buyout, Auctionator" }

	it("IsShopSelling is the shop on AND ordering open, and nothing else", function()
		assert.is_false(TOGBankClassic_Guild:IsShopSelling(), "a plain bank is selling")
		TOGBankClassic_Guild.Info.settings.shopEnabled = true
		assert.is_true(TOGBankClassic_Guild:IsShopSelling())
		TOGBankClassic_Guild.Info.settings.storeOpen = false
		assert.is_false(TOGBankClassic_Guild:IsShopSelling(), "a closed shop is selling")
		TOGBankClassic_Guild.Info.settings.shopEnabled = false
		assert.is_false(TOGBankClassic_Guild:IsShopSelling(), "the shop off with a stale closed sign is selling")
	end)

	it("a plain bank takes a plain request, and a shop order too, with nothing on the record but what was sent", function()
		assert.is_true(addOrder("Copper Bar", 1))
		local plain = orderFor("Copper Bar")
		assert.is_nil(plain.shopOrder); assert.is_nil(plain.estimate)
		-- A shop-marked request on a plain bank is not refused: the mark is what the dialog wrote,
		-- and the shop being turned off between the dialog and Submit is not the member's fault.
		assert.is_true(addOrder("Tin Bar", 1, SHOP))
		assert.is_true(orderFor("Tin Bar").shopOrder)
	end)

	it("selling: a request without the shop mark is refused and nothing goes on the wire; a shop order is minted with its estimate", function()
		TOGBankClassic_Guild.Info.settings.shopEnabled = true
		local before = #sent
		assert.is_false(addOrder("Copper Bar", 1), "a free request was minted while the bank was selling")
		assert.is_false(addOrder("Copper Bar", 1, { shopOrder = "yes" }), "a non-boolean mark passed the gate")
		assert.is_nil(orderFor("Copper Bar"))
		assert.equal(before, #sent, "a refused request still put something on the wire")
		assert.is_true(addOrder("Copper Bar", 3, SHOP))
		local got = orderFor("Copper Bar")
		assert.is_true(got.shopOrder)
		assert.equal(75, got.estimate); assert.equal(151, got.estimateBase); assert.equal(50, got.discount)
		assert.equal("min buyout, Auctionator", got.estimateSource)
		-- Ordering closed: the closed sign refuses first, mark or no mark.
		TOGBankClassic_Guild.Info.settings.storeOpen = false
		assert.is_false(addOrder("Tin Bar", 1, SHOP))
		-- Shop off: plain requests again.
		TOGBankClassic_Guild.Info.settings.shopEnabled = false
		assert.is_true(addOrder("Tin Bar", 1))
	end)

	it("the fields are sanitized: garbage numbers drop, an empty source drops, a long source is cut, false is never stored", function()
		TOGBankClassic_Guild.Info.settings.shopEnabled = true
		assert.is_true(addOrder("Copper Bar", 1, { shopOrder = true, estimate = "lots", estimateBase = {}, discount = "half", estimateSource = "" }))
		local got = orderFor("Copper Bar")
		assert.is_true(got.shopOrder)
		assert.is_nil(got.estimate); assert.is_nil(got.estimateBase); assert.is_nil(got.discount); assert.is_nil(got.estimateSource)
		assert.is_true(addOrder("Tin Bar", 1, { shopOrder = true, estimate = "75", estimateSource = string.rep("x", 200) }))
		got = orderFor("Tin Bar")
		assert.equal(75, got.estimate, "a numeric string was not read as a number")
		assert.equal(64, #got.estimateSource, "the source was not capped")
		-- A plain request's absent mark is nil on the record, not false (an old client's request
		-- has no mark either, and the two must read the same).
		TOGBankClassic_Guild.Info.settings.shopEnabled = false
		assert.is_true(addOrder("Silver Bar", 1, { shopOrder = false }))
		assert.is_nil(orderFor("Silver Bar").shopOrder)
	end)

	it("the mark and the estimate reach a peer on the togbank-rm mutation", function()
		TOGBankClassic_Guild.Info.settings.shopEnabled = true
		assert.is_true(addOrder("Copper Bar", 3, SHOP))
		local msg = lastMutation("add")
		becomeFreshPeer()
		deliver(msg, ME)
		local got = orderFor("Copper Bar")
		assert.is_table(got, "the shop order did not reach the peer")
		assert.is_true(got.shopOrder)
		assert.equal(75, got.estimate); assert.equal(151, got.estimateBase); assert.equal(50, got.discount)
		assert.equal("min buyout, Auctionator", got.estimateSource)
	end)

	it("the positional togbank-rd2 record carries them too, and an old client's shorter record reads as unmarked", function()
		TOGBankClassic_Guild.Info.settings.shopEnabled = true
		assert.is_true(addOrder("Copper Bar", 3, SHOP))
		local id = orderFor("Copper Bar").id
		-- PEER asks ME for the record by id; the drain answers on a whisper one tick later.
		TOGBankClassic_Guild:EnqueueRequestsById(PEER, { id })
		env.advance(0)
		local msg = lastSentOn("togbank-rd2")
		assert.is_table(msg, "the by-id drain sent no record")
		assert.equal(PEER, msg.target)
		local ok, arr = TOGBankClassic_Core:DeserializeWithChecksum(msg.body, { sender = ME, prefix = "togbank-rd2" })
		assert.is_true(ok)
		assert.equal(id, arr[2])
		assert.is_true(arr[15]); assert.equal(75, arr[16]); assert.equal(151, arr[17]); assert.equal(50, arr[18])
		assert.equal("min buyout, Auctionator", arr[19])
		becomeFreshPeer()
		TOGBankClassic_Chat:OnCommReceived("togbank-rd2", msg.body, "WHISPER", ME)
		local got = TOGBankClassic_Guild.Info.requests[id]
		assert.is_table(got, "the rd2 record was not applied")
		assert.is_true(got.shopOrder); assert.equal(75, got.estimate); assert.equal(151, got.estimateBase)
		assert.equal(50, got.discount); assert.equal("min buyout, Auctionator", got.estimateSource)
		-- A record from a client that predates the fields: fourteen slots, nothing after. Delivered
		-- as a NEWER updatedAt so it is adopted over what the peer holds.
		local old = {}
		for i = 1, 14 do old[i] = arr[i] end
		old[4] = arr[4] + 10
		TOGBankClassic_Chat:OnCommReceived("togbank-rd2", TOGBankClassic_Core:SerializeWithChecksum(old), "WHISPER", ME)
		got = TOGBankClassic_Guild.Info.requests[id]
		assert.equal(old[4], got.updatedAt, "precondition: the older-format record was not adopted")
		assert.is_nil(got.shopOrder); assert.is_nil(got.estimate); assert.is_nil(got.estimateSource)
	end)

	it("a plain request that carries no mark is not refused when it comes FROM the wire -- the gate is the minting side only", function()
		TOGBankClassic_Guild.Info.settings.shopEnabled = true
		-- An old client's order arrives on the mutation wire; the peer's shop being on does not drop it.
		TOGBankClassic_Guild.Info.settings.shopEnabled = false
		assert.is_true(addOrder("Copper Bar", 1))
		local msg = lastMutation("add")
		becomeFreshPeer()
		TOGBankClassic_Guild.Info.settings.shopEnabled = true
		deliver(msg, ME)
		assert.is_table(orderFor("Copper Bar"), "a received plain request was dropped by the selling gate")
	end)
end)

-- ─── SETTINGS-002: the settings carry a version; only newer is applied ─────────
--
-- Found 2026-09-14 while STORE-007's rate was wired onto the same plumbing: the periodic piggyback
-- (Events.lua SyncDeltaVersion) has every authorized client re-broadcast the settings it HOLDS, and
-- ApplyRemoteSettings was last-writer-wins -- so a banker logging in with yesterday's settings
-- reverted an officer's close / shop-off / not-for-sale / rate on every client within ten minutes.
describe("SETTINGS-002: a stale client cannot revert an officer's settings", function()
	before_each(function()
		env.reset(); loadRequestStack()
		TOGBankClassic_Guild.SenderIsOfficer = function(_, n) return n == ME or n == PEER end
		TOGBankClassic_Guild.SenderIsGM = function() return false end
		TOGBankClassic_Guild.Info.settings.shopEnabled = true
	end)

	local function lastSettingsMsg()
		for i = #sent, 1, -1 do
			local msg = sent[i]
			if msg.prefix == "togbank-hl" then
				local ok, decoded = TOGBankClassic_Core:DeserializeWithChecksum(msg.body, { sender = ME, prefix = msg.prefix })
				if ok and type(decoded) == "table" and decoded.type == "guild-settings" then return decoded.settings, msg end
			end
		end
		return nil
	end

	it("an officer's write stamps a version newer than anything held; a re-announcement does not", function()
		assert.equal(0, TOGBankClassic_Guild:SettingsVersion())
		assert.is_true(TOGBankClassic_Guild:SetStoreOpen(false))
		local v1 = TOGBankClassic_Guild:SettingsVersion()
		assert.equal(env.now, v1, "the stamp is not the server time of the write")
		assert.equal(v1, lastSettingsMsg().version, "the broadcast did not carry the version")
		-- Two writes in one second still order.
		assert.is_true(TOGBankClassic_Guild:SetStoreOpen(true))
		assert.equal(v1 + 1, TOGBankClassic_Guild:SettingsVersion())
		-- The periodic re-announcement carries the held version and bumps nothing.
		TOGBankClassic_Guild:BroadcastSettings()
		assert.equal(v1 + 1, TOGBankClassic_Guild:SettingsVersion())
		assert.equal(v1 + 1, lastSettingsMsg().version)
	end)

	it("newer then stale: the stale re-announcement is dropped WHOLE, every field", function()
		TOGBankClassic_Guild.Info.settings.maxRequestPercent = 50
		assert.is_true(TOGBankClassic_Guild:SetStoreOpen(false))            -- the officer closes: version N
		local _, closeMsg = lastSettingsMsg()
		-- A banker who logged in with yesterday's settings re-announces them (version N-100).
		local stale = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = {
			version = TOGBankClassic_Guild:SettingsVersion() - 100, storeOpen = true, maxRequestPercent = 100, shopEnabled = false } })
		-- A fresh peer hears the close first, then the stale one.
		becomeFreshPeer()
		TOGBankClassic_Guild.Info.settings = {}
		deliver(closeMsg, ME)
		assert.is_false(TOGBankClassic_Guild:IsStoreOpen())
		assert.equal(50, TOGBankClassic_Guild.Info.settings.maxRequestPercent)
		deliver({ prefix = "togbank-hl", body = stale }, THIRD)
		assert.is_false(TOGBankClassic_Guild:IsStoreOpen(), "a stale re-announcement reopened the shop")
		assert.equal(50, TOGBankClassic_Guild.Info.settings.maxRequestPercent, "a stale re-announcement changed a field")
		assert.is_true(TOGBankClassic_Guild:IsShopEnabled(), "a stale re-announcement switched the shop off")
	end)

	it("stale then newer: the newer one is applied and its version adopted, so a later local write stamps above it", function()
		local stale = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = 5, storeOpen = true } })
		local newer = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = 9, storeOpen = false } })
		becomeFreshPeer()
		TOGBankClassic_Guild.Info.settings = { shopEnabled = true }
		deliver({ prefix = "togbank-hl", body = stale }, ME)
		assert.equal(5, TOGBankClassic_Guild:SettingsVersion())
		deliver({ prefix = "togbank-hl", body = newer }, ME)
		assert.equal(9, TOGBankClassic_Guild:SettingsVersion())
		assert.is_false(TOGBankClassic_Guild:IsStoreOpen())
		deliver({ prefix = "togbank-hl", body = stale }, ME)
		assert.is_false(TOGBankClassic_Guild:IsStoreOpen(), "the stale one applied after the newer")
		-- The peer's own officer write is newer than 9, whatever the clock says.
		env.now = 3
		assert.is_true(TOGBankClassic_Guild:SetStoreOpen(true))
		assert.equal(10, TOGBankClassic_Guild:SettingsVersion())
	end)

	it("a pre-002 client (no version) can seed a client that holds nothing, and nothing else", function()
		local old = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { storeOpen = false, maxRequestPercent = 40 } })
		becomeFreshPeer()
		TOGBankClassic_Guild.Info.settings = { shopEnabled = true }
		deliver({ prefix = "togbank-hl", body = old }, ME)
		assert.is_false(TOGBankClassic_Guild:IsStoreOpen(), "an old client's settings did not seed an empty peer")
		assert.equal(0, TOGBankClassic_Guild:SettingsVersion())
		-- Once anything stamped has been held, the old client is ignored.
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = 7, storeOpen = true } }) }, ME)
		assert.is_true(TOGBankClassic_Guild:IsStoreOpen())
		deliver({ prefix = "togbank-hl", body = old }, ME)
		assert.is_true(TOGBankClassic_Guild:IsStoreOpen(), "a pre-002 client overwrote a stamped copy")
		assert.equal(7, TOGBankClassic_Guild:SettingsVersion())
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
