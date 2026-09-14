-- HASH-CANON-009: a canon is advertised only where it can be DELIVERED.
--
-- Read off the operator's banker account on 2026-09-10 after the <dts><hash> re-encode: 36 records
-- carried a revision-2 canon and 10 of them had tuple data in the V2 store. The other 26 were
-- revision-1 data wearing a canon, because v1.4.0's scan stamped both revisions whatever the V2
-- switch said. Every advertiser read `alt.inventoryHashV2` straight off the record, so a viewer was
-- told "a newer version exists", requested it, and the responder's SendAltData -- which sends tuples
-- from the V2 store and nothing else -- found no records and sent nothing. A request wasted every
-- cycle, and the requester's tab on red for a version nobody could deliver.
--
-- The rule: Guild:ServableCanon(norm) is the ONE spelling of "the canon I can serve", nil when the
-- V2 store holds no records for the alt, and every advertiser and every relay-responder reads it.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local OTHER  = "Otherbanker-Testrealm"
local PEER   = "Otherguy-Testrealm"
local STALE  = "Stalepeer-Testrealm"
local GUILD  = "Testguild"
local C      = env.canon
local T      = 1757000000

local function client(who)
	env.standUpClient(who, {
		{ name = BANKER, note = "gbank" }, { name = OTHER, note = "gbank" },
		{ name = PEER }, { name = STALE },
	}, GUILD)
end

--- A record with a canon, and either tuple records behind it or only legacy items.
local function hold(alt, canon, at, legacyOnly)
	TOGBankClassic_Guild.Info.alts[alt] = {
		name = alt, items = { { ID = 1, Count = 1 } }, money = 0, version = at,
		inventoryHash = 0x10, inventoryHashV2 = canon, inventoryUpdatedAt = at, mailHash = 0,
	}
	if not legacyOnly then
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, alt, { TOGBankClassic_Inventory_Record.new(1, 1) }, 0)
	end
end

describe("Guild:ServableCanon", function()
	before_each(function() env.reset(); client("Otherguy") end)

	it("is the canon when the V2 store holds records for the alt", function()
		hold(OTHER, C(T, 0x20), T)
		assert.equal(C(T, 0x20), TOGBankClassic_Guild:ServableCanon(OTHER))
	end)

	it("is nil for a canon beside legacy-only content -- the 26 records on the operator's account", function()
		hold(OTHER, C(T, 0x20), T, true)
		assert.is_nil(TOGBankClassic_Guild:ServableCanon(OTHER),
			"a canon with no tuple records behind it was reported as servable")
	end)

	it("is nil for the hash-list stub: a canon and no contents at all", function()
		TOGBankClassic_Guild.Info.alts[OTHER] = { name = OTHER, items = {}, inventoryHash = 0x10, inventoryHashV2 = C(T, 0x20) }
		assert.is_nil(TOGBankClassic_Guild:ServableCanon(OTHER))
	end)

	it("is nil when there is no record, or no canon", function()
		assert.is_nil(TOGBankClassic_Guild:ServableCanon(OTHER))
		hold(OTHER, nil, T)
		assert.is_nil(TOGBankClassic_Guild:ServableCanon(OTHER))
		assert.is_nil(TOGBankClassic_Guild:ServableCanon(nil))
	end)

	it("re-encodes a v1.4.0 numeric canon beside its publish time, like every other reader", function()
		hold(OTHER, 0x21, T + 60)
		assert.equal(C(T + 60, 0x21), TOGBankClassic_Guild:ServableCanon(OTHER))
	end)
end)

describe("HASH-CANON-009: advertisers carry only a servable canon", function()
	before_each(function() env.reset(); client("Otherguy") end)

	it("hash-list reply: hashV2 is nil for a canon beside legacy-only content, present with records", function()
		hold(OTHER, C(T, 0x20), T, true)
		hold(BANKER, C(T, 0x30), T)
		local list = TOGBankClassic_Guild:BuildBankerHashList()
		assert.is_table(list[OTHER], "precondition: the alt is on the list at all")
		assert.is_nil(list[OTHER].hashV2,
			"the hash-list reply advertised a canon this client cannot deliver (HASH-CANON-009)")
		assert.equal(0x10, list[OTHER].hash, "revision 1 still rides, it is a different statement")
		assert.equal(C(T, 0x30), list[BANKER].hashV2)
	end)

	-- INV2-RETIRE-003: this used to expect the legacy-only alt IN the broadcast with a nil canon.
	-- Legacy rows are no longer content (HasAltContent is the V2 store), so a canon beside them is a
	-- stub and the broadcast excludes it outright -- the stronger form of the same rule.
	it("version broadcast: the same rule -- a legacy-only copy is not advertised at all", function()
		hold(OTHER, C(T, 0x20), T, true)
		hold(BANKER, C(T, 0x30), T)
		local data = TOGBankClassic_Guild:GetVersion()
		assert.is_nil(data.alts[OTHER],
			"the version broadcast advertised a bank this client holds no records for (HASH-CANON-009)")
		assert.is_table(data.alts[BANKER], "the bank with records is missing from the broadcast")
		assert.equal(C(T, 0x30), data.alts[BANKER].hashV2)
	end)
end)

describe("HASH-CANON-009: a relay answers a request only with a version it can deliver", function()
	local sent

	local function requestFrom(sender, alt, expectedHash)
		sent = {}
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, text, dist, target)
			local ok, data = TOGBankClassic_Core:DeserializeWithChecksum(text)
			sent[#sent + 1] = { prefix = prefix, data = ok and data or nil, dist = dist, target = target }
		end
		local body = TOGBankClassic_Core:SerializeWithChecksum({
			type = "alt-request", name = alt, requester = sender, hashOnly = false,
			expectedHash = expectedHash, requesterMailHash = 0,
		})
		TOGBankClassic_Chat:OnCommReceived("togbank-r", body, "GUILD", sender)
		env.advance(1)   -- the 0-500ms responder backoff
	end

	local function acked()
		for _, m in ipairs(sent) do
			if m.prefix == "togbank-rr" and m.data and m.data.type == "alt-request-reply" then return m end
		end
		return nil
	end

	before_each(function() env.reset(); client("Otherguy") end)

	it("answers when it holds tuple records with a canon", function()
		hold(OTHER, C(T, 0x20), T)
		requestFrom(STALE, OTHER, 0x10)
		assert.is_table(acked(), "a relay holding a deliverable version did not answer")
	end)

	-- The Alchemyrcp case from the live guild: a peer holding the Sep-5 copy -- same revision-1
	-- hash as the banker, no canon -- would win the race to answer, SendAltData would ship its
	-- tuples with no canon, and the requester would be left on "v1" red having been "answered".
	it("stays silent when its copy has no readable canon, even though revision 1 matches", function()
		hold(OTHER, nil, T)
		requestFrom(STALE, OTHER, 0x10)
		assert.is_nil(acked(),
			"a relay with no canon answered a request; its delivery cannot carry a version " ..
			"(HASH-CANON-009)")
	end)

	it("stays silent when its canon sits beside legacy-only content", function()
		hold(OTHER, C(T, 0x20), T, true)
		requestFrom(STALE, OTHER, 0x10)
		assert.is_nil(acked(),
			"a relay answered with a canon it has no tuple records for; SendAltData would send nothing")
	end)
end)
