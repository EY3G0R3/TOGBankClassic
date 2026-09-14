-- Inventory/Chain -- the per-version delta chain (THE DELTA RELEASE, step 3; docs/DELTA_RELEASE.md
-- sections 3.1-3.3 and the test plan in section 7).
--
-- Driven through the REAL DeltaSync-1.0 host (Core:DeltaHost) and the real AceSerializer, because
-- the property under test is "apply(before, diff(before, after)) reproduces after EXACTLY, and the
-- canon proves it" -- a stub delta engine would make that true by construction.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local GUILD, ALT = "Testguild", "Bankchar-Testrealm"
local C = env.canon
local T = 1757000000

local Chain, Store, Record, DC

local function load()
	env.reset(); env.stubOutput()
	require("env.ace").load("AceAddon-3.0", "AceComm-3.0", "AceConsole-3.0",
		"AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
	require("env.libs").load("AceCommQueue-1.0", "DeltaSync-1.0")
	env.loadModules({
		"Modules/Constants.lua",
		"Modules/Inventory/Record.lua",
		"Modules/Inventory/Resolve.lua",
		"Modules/Inventory/Store.lua",
		"Modules/Inventory/Scan.lua",
		"Modules/Inventory/Chain.lua",
		"Modules/DeltaComms.lua",
	})
	local AceAddon = LibStub("AceAddon-3.0")
	if AceAddon and AceAddon.addons then
		AceAddon.addons["TOGBankClassic"] = nil
		if AceAddon.addonstatus then AceAddon.addonstatus["TOGBankClassic"] = nil end
	end
	env.loadFile("Core.lua")
	TOGBankClassic_Database = { db = { global = { debugCategories = {} }, faction = {} } }
	TOGBankClassic_Options  = { IsIntegrityCheckDiagnosticsEnabled = function() return false end }
	Chain, Store, Record = TOGBankClassic_Inventory_Chain, TOGBankClassic_Inventory_Store, TOGBankClassic_Inventory_Record
	DC = TOGBankClassic_DeltaComms
	Store:Init({ faction = {} })
end

--- The canon the author would mint for this record set: publish time + the real content hash.
local function canonOf(records, money, at)
	return DC:ComputeCanonHash(records, nil, nil, money or 0, at)
end

local function recs(...)
	local out = {}
	for _, r in ipairs({ ... }) do out[#out + 1] = Record.new(r[1], r[2], r[3], r[4]) end
	return out
end

--- Sort-insensitive comparison of two record sets by key -> count.
local function sameRecords(a, b)
	local ma, mb = {}, {}
	for _, r in ipairs(a) do ma[Record.key(r)] = Record.count(r) end
	for _, r in ipairs(b) do mb[Record.key(r)] = Record.count(r) end
	assert.same(ma, mb)
end

describe("Chain: diff correctness -- apply(before, diff(before, after)) hashes to after's canon", function()
	before_each(load)

	--- Round-trip one transition and prove it by the canon, the way a receiver would.
	local function roundTrip(before, beforeMoney, after, afterMoney)
		local parent = canonOf(before, beforeMoney, T)
		local canon  = canonOf(after, afterMoney, T + 60)
		local _, body = Chain:Compute({ records = before, money = beforeMoney },
			{ records = after, money = afterMoney }, parent, canon)
		-- The canon and parent are the LINK's index fields, not repeated in the body; Apply restores
		-- them onto the delta from the link it is handed.
		assert.is_nil(body:find(canon, 1, true), "the canon travelled inside the body as well as the link index")
		local got, gotMoney, delta, err = Chain:Apply(before, beforeMoney, body, { parent = parent, canon = canon })
		assert.is_not_nil(got, tostring(err))
		assert.equal(canon, delta.canon)
		assert.equal(parent, delta.parent)
		sameRecords(after, got)
		assert.equal(afterMoney, gotMoney)
		assert.is_true(Chain:Verify(got, gotMoney, canon), "the applied result does not hash to the author's canon")
		return body
	end

	it("count up, count down, add, remove -- in one link", function()
		roundTrip(recs({ 858, 5 }, { 2589, 20 }, { 4306, 3 }), 100,
			recs({ 858, 9 }, { 2589, 18 }, { 15260, 1 }), 100)
	end)

	it("keeps suffix variants apart -- a Tiger and a Monkey of one item are two rows", function()
		roundTrip(recs({ 10132, 1, 863 }, { 10132, 1, 2504 }), 0,
			recs({ 10132, 2, 863 }), 0)
	end)

	it("carries an enchant through the key", function()
		roundTrip(recs({ 15260, 1, 0, 2504 }), 0, recs({ 15260, 1, 0, 2504 }, { 15260, 1 }), 0)
	end)

	it("money-only change", function()
		local body = roundTrip(recs({ 858, 5 }), 100, recs({ 858, 5 }), 5000)
		assert.is_nil(body:find("858", 1, true), "an unchanged row travelled in a money-only link")
	end)

	it("empty -> full and full -> empty", function()
		roundTrip({}, 0, recs({ 858, 5 }, { 2589, 20 }), 10)
		roundTrip(recs({ 858, 5 }, { 2589, 20 }), 10, {}, 0)
	end)

	it("no change at all is an empty link that still verifies", function()
		roundTrip(recs({ 858, 5 }), 7, recs({ 858, 5 }), 7)
	end)

	-- Prove the check can go RED: corrupt one count in the link and the canon refuses it.
	it("REFUSES a link whose result does not hash to the canon", function()
		local before, after = recs({ 858, 5 }), recs({ 858, 9 })
		local parent, canon = canonOf(before, 0, T), canonOf(after, 0, T + 60)
		local _, body = Chain:Compute({ records = before, money = 0 }, { records = after, money = 0 }, parent, canon)
		local corrupt = body:gsub("%^N9", "^N8", 1)
		assert.is_not.equal(body, corrupt, "precondition: the count was not found in the link to corrupt")
		local got, gotMoney = Chain:Apply(before, 0, corrupt)
		assert.is_not_nil(got)
		assert.is_false(Chain:Verify(got, gotMoney, canon), "a corrupted link verified against the canon -- the check is not checking")
	end)

	it("never mutates the held records or their tuples", function()
		local before = recs({ 858, 5 })
		local tuple = before[1]
		local after = recs({ 858, 9 }, { 2589, 1 })
		local _, body = Chain:Compute({ records = before, money = 0 }, { records = after, money = 0 },
			canonOf(before, 0, T), canonOf(after, 0, T + 1))
		Chain:Apply(before, 0, body)
		assert.equal(5, Record.count(tuple), "apply wrote into the caller's tuple")
		assert.equal(1, #before)
	end)

	-- MEASURED, not assumed (docs/DELTA_RELEASE.md 3.1 said the size would be measured here): with
	-- the canon, parent, empty arrays and zero metadata in the body, one changed count serialized to
	-- 209 bytes -- larger than a four-row snapshot. Pruned, it is the changed tuple plus framing.
	it("a link is small: a few integers per changed row, no names, no links", function()
		local before = recs({ 858, 5 }, { 2589, 20 }, { 4306, 3 }, { 10132, 1, 863 })
		local after  = recs({ 858, 6 }, { 2589, 20 }, { 4306, 3 }, { 10132, 1, 863 })
		local _, body = Chain:Compute({ records = before, money = 0 }, { records = after, money = 0 },
			canonOf(before, 0, T), canonOf(after, 0, T + 1))
		assert.is_true(#body <= 70, "one changed count serialized to " .. #body .. " bytes")
		assert.is_nil(body:find("|H", 1, true))
		assert.is_nil(body:find("2589", 1, true), "an unchanged row travelled in the link")
	end)
end)

describe("Chain: the window", function()
	before_each(load)

	--- Mint `n` versions of one banker: version i holds item 858 x i.
	local function mint(n)
		local prev, prevCanon = {}, C(T, 1)
		for i = 1, n do
			local cur = recs({ 858, i })
			local canon = canonOf(cur, 0, T + i)
			Chain:Record(GUILD, ALT, { records = prev, money = 0 }, { records = cur, money = 0 }, prevCanon, canon)
			prev, prevCanon = cur, canon
		end
		return prevCanon
	end

	it("keeps the last 25 links and drops the oldest on the 26th", function()
		mint(26)
		local links = Chain:Links(GUILD, ALT)
		assert.equal(25, #links)
		assert.equal(canonOf(recs({ 858, 1 }), 0, T + 1), links[1].parent,
			"the oldest surviving link should be version 1 -> 2; version 0 -> 1 was dropped")
		assert.equal(canonOf(recs({ 858, 26 }), 0, T + 26), links[25].canon)
		assert.equal(Chain.WINDOW, 25, "Blizzard's per-tab number")
	end)

	it("is ONE string per banker on the V2 SavedVariable", function()
		mint(5)
		local g = Store:GuildTable(GUILD, false)
		assert.is_string(g.chains[ALT])
		assert.equal(4, select(2, g.chains[ALT]:gsub(Chain.LINK_SEP, "")), "five links, four separators")
	end)

	it("Newest is the last link's canon", function()
		local newest = mint(3)
		assert.equal(newest, Chain:Newest(GUILD, ALT))
		assert.is_nil(Chain:Newest(GUILD, "Nobody-Testrealm"))
	end)

	it("Since(held) returns exactly the links after the held canon, oldest first", function()
		mint(5)
		local held = canonOf(recs({ 858, 3 }), 0, T + 3)
		local tail = Chain:Since(GUILD, ALT, held)
		assert.equal(2, #tail)
		assert.equal(held, tail[1].parent)
		assert.equal(canonOf(recs({ 858, 4 }), 0, T + 4), tail[1].canon)
		assert.equal(canonOf(recs({ 858, 5 }), 0, T + 5), tail[2].canon)
	end)

	it("Since(newest) is empty -- nothing to send", function()
		local newest = mint(3)
		assert.same({}, Chain:Since(GUILD, ALT, newest))
	end)

	it("Since(the oldest link's PARENT) serves the whole window", function()
		mint(4)
		assert.equal(4, #Chain:Since(GUILD, ALT, C(T, 1)))
	end)

	it("Since(a canon outside the window) is nil -- the requester gets a snapshot", function()
		mint(30)
		assert.is_nil(Chain:Since(GUILD, ALT, canonOf(recs({ 858, 2 }), 0, T + 2)))
		assert.is_nil(Chain:Since(GUILD, ALT, "00000000000000000000"))
		assert.is_nil(Chain:Since(GUILD, ALT, nil))
		assert.is_nil(Chain:Since(GUILD, "Nobody-Testrealm", C(T, 1)))
	end)

	it("Clear drops the banker's chain", function()
		mint(2)
		Chain:Clear(GUILD, ALT)
		assert.same({}, Chain:Links(GUILD, ALT))
	end)
end)

describe("Chain: applying a whole chain, proven by the newest canon", function()
	before_each(load)

	local function build()
		local v1 = recs({ 858, 5 }, { 2589, 20 })
		local v2 = recs({ 858, 5 }, { 2589, 15 }, { 4306, 2 })
		local v3 = recs({ 858, 7 }, { 4306, 2 })
		local v4 = recs({ 858, 7 }, { 4306, 2 }, { 10132, 1, 863 })
		local c1, c2, c3, c4 = canonOf(v1, 10, T + 1), canonOf(v2, 10, T + 2), canonOf(v3, 99, T + 3), canonOf(v4, 99, T + 4)
		Chain:Record(GUILD, ALT, { records = v1, money = 10 }, { records = v2, money = 10 }, c1, c2)
		Chain:Record(GUILD, ALT, { records = v2, money = 10 }, { records = v3, money = 99 }, c2, c3)
		Chain:Record(GUILD, ALT, { records = v3, money = 99 }, { records = v4, money = 99 }, c3, c4)
		return { v1 = v1, v2 = v2, v3 = v3, v4 = v4, c1 = c1, c2 = c2, c3 = c3, c4 = c4 }
	end

	it("a holder of v2 applies v3 and v4 and lands on v4 exactly", function()
		local s = build()
		local links = Chain:Since(GUILD, ALT, s.c2)
		assert.equal(2, #links)
		local got, money, canon, err = Chain:ApplyAll(s.v2, 10, links)
		assert.is_not_nil(got, tostring(err))
		assert.equal(s.c4, canon)
		assert.equal(99, money)
		sameRecords(s.v4, got)
	end)

	it("a holder of v1 applies all three", function()
		local s = build()
		local got, _, canon = Chain:ApplyAll(s.v1, 10, Chain:Since(GUILD, ALT, s.c1))
		assert.equal(s.c4, canon)
		sameRecords(s.v4, got)
	end)

	it("REFUSES the chain whole when the held records are not the parent -- the canon disagrees", function()
		local s = build()
		-- Claims to be v2 but is not: 4306 x3 where v2 had x2. The row SURVIVES the chain unchanged
		-- (v3 and v4 keep 4306 x2), so the result carries x3 and cannot hash to v4. (A first draft
		-- differed on 2589 instead -- a row the v2->v3 link REMOVES, which erased the difference and
		-- let the wrong base land on v4 exactly; the check was right and the fixture was wrong.)
		local wrongHeld = recs({ 858, 5 }, { 2589, 15 }, { 4306, 3 })
		local got, _, _, err = Chain:ApplyAll(wrongHeld, 10, Chain:Since(GUILD, ALT, s.c2))
		assert.is_nil(got, "a chain applied over the wrong base was accepted")
		assert.truthy(tostring(err):find("does not match canon", 1, true), tostring(err))
	end)

	it("REFUSES a chain whose links do not connect", function()
		local s = build()
		local links = Chain:Since(GUILD, ALT, s.c1)
		table.remove(links, 2)   -- v2->v3 missing: v3->v4's parent is not where the chain is
		local got, _, _, err = Chain:ApplyAll(s.v1, 10, links)
		assert.is_nil(got)
		assert.truthy(tostring(err):find("expects parent", 1, true), tostring(err))
	end)

	it("an empty chain is not a version", function()
		local got, money, canon, err = Chain:ApplyAll(recs({ 858, 1 }), 0, {})
		assert.is_not_nil(got)
		assert.equal(0, money)
		assert.is_nil(canon)
		assert.equal("empty chain", err)
	end)

	it("a link that does not deserialize is refused with a reason", function()
		local got, _, _, err = Chain:Apply(recs({ 858, 1 }), 0, "not a payload")
		assert.is_nil(got)
		assert.is_string(err)
	end)
end)

describe("Chain: written first-hand at mint (Bank:MintVersion)", function()
	before_each(function()
		load()
		env.loadModules({ "Modules/Bank.lua", "Modules/Log.lua" })
		TOGBankClassic_Guild = { Info = { name = GUILD, alts = {} } }
	end)

	it("records the link from the version last published to the one being minted", function()
		local before, after = recs({ 858, 5 }), recs({ 858, 9 }, { 2589, 1 })
		local alt = {}
		local parent = canonOf(before, 0, T)
		env.now = T + 60
		TOGBankClassic_Bank:MintVersion(alt, ALT, after, 0, 12345, before, 0, parent)
		local links = Chain:Links(GUILD, ALT)
		assert.equal(1, #links, "MintVersion recorded no link")
		assert.equal(parent, links[1].parent)
		assert.equal(alt.inventoryHashV2, links[1].canon, "the link is not labelled with the canon MintVersion stamped")
		local got, money, canon = Chain:ApplyAll(before, 0, links)
		assert.equal(alt.inventoryHashV2, canon)
		assert.equal(0, money)
		sameRecords(after, got)
	end)

	it("starts no chain on a first-ever scan -- there is no parent to diff from", function()
		local alt = {}
		TOGBankClassic_Bank:MintVersion(alt, ALT, recs({ 858, 9 }), 0, 12345, nil, nil, nil)
		assert.same({}, Chain:Links(GUILD, ALT))
	end)
end)
