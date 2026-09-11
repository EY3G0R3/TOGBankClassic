-- HASH-CANON-010 / HASH-CANON-011: the last two places that still spoke revision 1.
--
-- READ OFF GALDOF'S LIVE LOG, 2026-09-10 ~18:20, after HASH-CANON-006 had fixed the four "same
-- hash" gates on the requester: Galdof requested Alchemyrcp (so the fix worked), Alchemy ACKed,
-- Galdof whispered its state summary -- revision-1 `808855588`, no canon -- and Alchemy answered
-- `togbank-nochange`, because RespondToStateSummary compared revision 1 and the contents had not
-- changed since Sep 5. Only the canon had. The requester was "answered" and still held no canon.
-- That is the FIFTH spelling of the test, on the RESPONDER, and the one the requester-side fix
-- could not reach.
--
-- And in the same session, the operator watching a `/togbank share` from the banker: "I should be
-- getting the new hash from the broadcast at least." They were not: the broadcast handler raised the
-- tab's newest-time but never wrote the advertised-hash cache, so `hashdump` read `known=-` for a
-- canon that had just been broadcast to the whole guild.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local OTHER  = "Otherbanker-Testrealm"
local PEER   = "Otherguy-Testrealm"
local GUILD  = "Testguild"
local C      = env.canon
local T      = 1757000000

local function client(who)
	env.standUpClient(who, {
		{ name = BANKER, note = "gbank" }, { name = OTHER, note = "gbank" }, { name = PEER },
	}, GUILD)
end

--- The responder's record: contents, revision-1 hash, canon (or nil), mail hash, tuple records.
local function hold(alt, canon, at)
	TOGBankClassic_Guild.Info.alts[alt] = {
		name = alt, items = { { ID = 858, Count = 5 } }, money = 0, version = at,
		inventoryHash = 0x10, inventoryHashV2 = canon, inventoryUpdatedAt = at, mailHash = 0x77,
		bank = { items = {}, slots = { count = 1, total = 28 } },
	}
	TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, alt, { TOGBankClassic_Inventory_Record.new(858, 5) }, 0)
end

describe("HASH-CANON-010: the responder decides 'do they hold my version?' on the canon", function()
	local sent

	before_each(function()
		env.reset(); client("Bankchar")
		sent = {}
		TOGBankClassic_Core.SendWhisper = function(_, prefix, body)
			sent[#sent + 1] = { prefix = prefix, body = body }
			return true
		end
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, body)
			sent[#sent + 1] = { prefix = prefix, body = body }
		end
	end)

	local function prefixes()
		local out = {}
		for _, m in ipairs(sent) do out[m.prefix] = true end
		return out
	end

	-- The Alchemyrcp case, exactly.
	it("SENDS the data when the requester's revision-1 hash matches but it holds no canon", function()
		hold(BANKER, C(T, 0x20), T)
		TOGBankClassic_Guild:RespondToStateSummary(BANKER, {
			name = BANKER, hash = 0x10, mailHash = 0x77, version = T, updatedAt = T,
		}, PEER)
		local p = prefixes()
		assert.is_nil(p["togbank-nochange"],
			"answered 'no change' to a requester holding the same contents and NO canon -- it can " ..
			"never acquire one that way (HASH-CANON-010)")
		assert.is_true(p["togbank-d4"] == true, "the tuple payload was not sent")
	end)

	it("answers no-change when the requester holds the same canon", function()
		hold(BANKER, C(T, 0x20), T)
		TOGBankClassic_Guild:RespondToStateSummary(BANKER, {
			name = BANKER, hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0x77, version = T,
		}, PEER)
		local p = prefixes()
		assert.is_true(p["togbank-nochange"] == true, "the same version was re-sent in full")
		assert.is_nil(p["togbank-d4"])
	end)

	it("SENDS when the requester holds an OLDER canon", function()
		hold(BANKER, C(T + 60, 0x21), T + 60)
		TOGBankClassic_Guild:RespondToStateSummary(BANKER, {
			name = BANKER, hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0x77, version = T,
		}, PEER)
		assert.is_true(prefixes()["togbank-d4"] == true)
	end)

	it("SENDS on a forced-full summary (hash 0, no canon)", function()
		hold(BANKER, C(T, 0x20), T)
		TOGBankClassic_Guild:RespondToStateSummary(BANKER, {
			name = BANKER, hash = 0, mailHash = 0x77, version = 0,
		}, PEER)
		assert.is_true(prefixes()["togbank-d4"] == true)
	end)

	it("still SENDS on a mail-only difference", function()
		hold(BANKER, C(T, 0x20), T)
		TOGBankClassic_Guild:RespondToStateSummary(BANKER, {
			name = BANKER, hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0x78, version = T,
		}, PEER)
		assert.is_true(prefixes()["togbank-d4"] == true, "a mail change stopped being delivered")
	end)

	-- P2P-028: the slot taken at accept is given back on the outcomes that send nothing.
	it("frees the send slot on a no-change", function()
		hold(BANKER, C(T, 0x20), T)
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		TOGBankClassic_Guild:RespondToStateSummary(BANKER, {
			name = BANKER, hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0x77, version = T,
		}, PEER)
		assert.is_true(prefixes()["togbank-nochange"] == true, "precondition: not a no-change")
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal(),
			"a no-change kept the slot it was accepted with; three of these and the banker is " ..
			"'busy' to everyone for 210 seconds (P2P-028)")
	end)

	it("frees the send slot when there is nothing to send for the alt", function()
		TOGBankClassic_Guild.Info.alts[BANKER] = {
			name = BANKER, items = { { ID = 858, Count = 5 } }, money = 0, version = T,
			inventoryHash = 0x10, inventoryHashV2 = C(T, 0x20), inventoryUpdatedAt = T, mailHash = 0x77,
		}   -- legacy content, NO tuple records: SendAltData has nothing to ship
		TOGBankClassic_P2PSession:TryAcquireSendSlot(PEER)
		TOGBankClassic_Guild:RespondToStateSummary(BANKER, { name = BANKER, hash = 0, mailHash = 0, version = 0 }, PEER)
		assert.is_nil(prefixes()["togbank-d4"], "precondition: something was sent after all")
		assert.equal(0, TOGBankClassic_P2PSession:GetActiveSendTotal(), "nothing-to-send kept the slot")
	end)

	it("falls back to revision 1 when NEITHER side holds a canon", function()
		hold(BANKER, nil, T)
		TOGBankClassic_Guild:RespondToStateSummary(BANKER, {
			name = BANKER, hash = 0x10, mailHash = 0x77, version = T, updatedAt = T,
		}, PEER)
		assert.is_true(prefixes()["togbank-nochange"] == true,
			"two canon-less copies with equal revision-1 hashes are the same version; revision 1 " ..
			"is the only language they share")
	end)
end)

describe("HASH-CANON-010: the requester's canon rides in its state summary", function()
	before_each(function() env.reset(); client("Otherguy") end)

	it("carries the held canon", function()
		hold(BANKER, C(T, 0x20), T)
		local s = TOGBankClassic_Guild:ComputeStateSummary(BANKER)
		assert.equal(C(T, 0x20), s.hashV2, "the responder cannot see what version we hold")
	end)

	it("carries nil when we hold none, and nil on a forced-full request", function()
		hold(BANKER, nil, T)
		assert.is_nil(TOGBankClassic_Guild:ComputeStateSummary(BANKER).hashV2)

		hold(BANKER, C(T, 0x20), T)
		local msg
		TOGBankClassic_Core.SendWhisper = function(_, prefix, body)
			if prefix == "togbank-state" then
				local _, d = TOGBankClassic_Core:DeserializeWithChecksum(body, {})
				msg = d
			end
			return true
		end
		TOGBankClassic_Guild:SendStateSummary(BANKER, PEER, true)
		assert.is_table(msg, "no state summary was whispered")
		assert.equal(0, msg.summary.hash)
		assert.is_nil(msg.summary.hashV2,
			"a forced-full request still claimed a version, so a responder holding that version " ..
			"would answer no-change to a request that asked for everything")
	end)
end)

describe("HASH-CANON-011: a hash-list broadcast feeds the advertised-hash cache", function()
	before_each(function()
		env.reset(); client("Otherguy")
		TOGBankClassic_Chat.hashBroadcastQueue = TOGBankClassic_Chat.hashBroadcastQueue or {}
		TOGBankClassic_Chat.HASH_BROADCAST_BATCH_DELAY = 0.15
		TOGBankClassic_Guild.latestBankerHashes = {}
		TOGBankClassic_Core.SendWhisper = function() return true end
	end)

	local function broadcastFrom(sender, alts)
		local body = TOGBankClassic_Core:SerializeWithChecksum({
			type = "hash-list-broadcast", alts = alts, banker = sender, isBanker = true,
		})
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "GUILD", sender)
		env.advance(1)
	end

	it("records the banker's canon so hashdump / IsAltSyncPending see it", function()
		broadcastFrom(BANKER, { [BANKER] = { hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0 } })
		local known = TOGBankClassic_Guild.latestBankerHashes[BANKER]
		assert.is_table(known,
			"a banker's own broadcast left the cache empty for it -- `known=-` in hashdump for a " ..
			"canon the whole guild just heard (HASH-CANON-011)")
		assert.equal(C(T, 0x20), known.hashV2)
	end)

	it("goes through the one writer: a revision-1-only broadcast does not displace a held V2 entry", function()
		TOGBankClassic_Guild.latestBankerHashes[BANKER] = { hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0 }
		broadcastFrom(PEER, { [BANKER] = { hash = 0xDEAD, updatedAt = T + 86400, mailHash = 0 } })
		assert.equal(C(T, 0x20), TOGBankClassic_Guild.latestBankerHashes[BANKER].hashV2)
	end)
end)
