-- Inventory/Wire — V2 payload encode/decode.
--
-- The property that must never regress: RECEIVE accepts both formats, unconditionally. Send is
-- switchable; receive is not. A client that only understood tuples would silently ignore every
-- peer still sending links, and an ignored peer is indistinguishable from a banker with no
-- items — which is the exact class of silent wrongness this rework exists to remove.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Record, Wire

local function loadWire()
	env.stubOutput()
	env.loadFile("Modules/Switches.lua")
	env.loadFile("Modules/Inventory/Record.lua")
	env.loadFile("Modules/Inventory/Scan.lua")
	env.loadFile("Modules/Inventory/Wire.lua")
	Record = TOGBankClassic_Inventory_Record
	Wire   = TOGBankClassic_Inventory_Wire
	TOGBankClassic_Database = { db = { global = {} } }
	return Wire
end

describe("Wire.encode", function()
	before_each(function() env.reset(); loadWire() end)

	it("builds a positional payload", function()
		local p = Wire.encode("Bob-Testrealm", { Record.new(858, 20) }, 5000)
		assert.equal(Wire.VERSION, p[1])
		assert.equal("Bob-Testrealm", p[2])
		assert.equal(5000, p[3])
		assert.equal(1, #p[4])
	end)

	it("drops invalid records rather than transmitting them", function()
		local p = Wire.encode("Bob", { Record.new(858, 5), { 0, 1 }, { 858 } })
		assert.equal(1, #p[4])
	end)

	it("encodes an empty inventory as an empty record list", function()
		local p = Wire.encode("Bob", {})
		assert.equal(0, #p[4])
	end)

	it("refuses a missing or empty alt name", function()
		assert.is_nil(Wire.encode(nil, {}))
		assert.is_nil(Wire.encode("", {}))
	end)

	it("defaults money to zero", function()
		assert.equal(0, Wire.encode("Bob", {})[3])
	end)
end)

describe("Wire round-trip", function()
	before_each(function() env.reset(); loadWire() end)

	it("preserves id, count, suffix and enchant", function()
		local sent = { Record.new(858, 20), Record.new(10132, 1, 863, 2504) }
		local alt, records, money, format = Wire.decode(Wire.encode("Bob", sent, 999))

		assert.equal("Bob", alt)
		assert.equal("v2", format)
		assert.equal(999, money)
		assert.equal(2, #records)
		assert.equal(863, Record.suffix(records[2]))
		assert.equal(2504, Record.enchant(records[2]))
	end)

	it("preserves a negative suffix", function()
		local _, records = Wire.decode(Wire.encode("Bob", { Record.new(10132, 1, -25) }))
		assert.equal(-25, Record.suffix(records[1]))
	end)

	-- Keys must survive the wire, or a synced item and a locally-scanned one become two rows.
	it("produces identical keys either side of the wire", function()
		local original = Record.new(10132, 3, 863, 2504)
		local _, records = Wire.decode(Wire.encode("Bob", { original }))
		assert.equal(Record.key(original), Record.key(records[1]))
	end)

	-- A malformed tuple from a buggy or hostile peer must not reach the store.
	it("rebuilds records rather than trusting the wire", function()
		local payload = { Wire.VERSION, "Bob", 0, { { 858, 20 }, { 0, 5 }, { 859, -1 } } }
		local _, records = Wire.decode(payload)
		assert.equal(1, #records, "invalid tuples were accepted from the wire")
	end)

	-- Guessing at an unknown layout would apply wrong values silently; refusing lets the sender
	-- retry once the receiver upgrades.
	it("refuses a payload from a newer wire version", function()
		local alt, records = Wire.decode({ Wire.VERSION + 1, "Bob", 0, { { 858, 20 } } })
		assert.is_nil(alt)
		assert.equal(0, #records)
	end)
end)

describe("Wire legacy compatibility", function()
	before_each(function() env.reset(); loadWire() end)

	local function legacyPayload(items, money)
		return { name = "Bob-Testrealm", money = money or 0, items = items }
	end

	-- Permanent, not a migration aid: this is what lets a guild run mixed versions.
	it("decodes a legacy link payload", function()
		local alt, records, money, format = Wire.decode(legacyPayload({
			{ ID = 858, Count = 20, Link = "|cffffffff|Hitem:858|h[Potion]|h|r" },
		}, 1234))
		assert.equal("Bob-Testrealm", alt)
		assert.equal("legacy", format)
		assert.equal(1234, money)
		assert.equal(20, Record.count(records[1]))
	end)

	it("extracts suffix and enchant from a legacy link", function()
		local _, records = Wire.decode(legacyPayload({
			{ ID = 10132, Count = 1, Link = "|cff1eff00|Hitem:10132:2504:0:0:0:0:863:1:60|h[X]|h|r" },
		}))
		assert.equal(863, Record.suffix(records[1]))
		assert.equal(2504, Record.enchant(records[1]))
	end)

	-- The convergence that makes mixed guilds safe: an item arriving as a link and the same item
	-- scanned locally must produce the SAME key, or they aggregate as two rows.
	it("produces the same key as a local scan of the same item", function()
		local link = "|cff1eff00|Hitem:10132:2504:0:0:0:0:863:1:60|h[X]|h|r"
		local _, fromWire = Wire.decode(legacyPayload({ { ID = 10132, Count = 1, Link = link } }))
		local enchant, suffix = TOGBankClassic_Inventory_Scan.parseLink(link)
		local scanned = Record.new(10132, 1, suffix, enchant)
		assert.equal(Record.key(scanned), Record.key(fromWire[1]))
	end)

	it("tolerates a legacy item with no link", function()
		local _, records = Wire.decode(legacyPayload({ { ID = 858, Count = 5 } }))
		assert.equal(1, #records)
		assert.equal(0, Record.suffix(records[1]))
	end)

	it("skips malformed legacy entries", function()
		local _, records = Wire.decode(legacyPayload({ { Count = 5 }, "junk", { ID = 858, Count = 1 } }))
		assert.equal(1, #records)
	end)

	it("returns nothing useful for an unrecognisable payload", function()
		local alt, records, _, format = Wire.decode("not a table")
		assert.is_nil(alt)
		assert.equal(0, #records)
		assert.equal("invalid", format)
	end)
end)

describe("Wire format detection", function()
	before_each(function() env.reset(); loadWire() end)

	-- Structural, not a flag: an old client never learned to set a marker, so the shape itself
	-- has to be the discriminator.
	it("identifies a V2 payload by shape", function()
		assert.is_true(Wire.isV2(Wire.encode("Bob", {})))
	end)

	it("does not mistake a legacy payload for V2", function()
		assert.is_false(Wire.isV2({ name = "Bob", items = {} }))
	end)

	it("does not mistake junk for V2", function()
		assert.is_false(Wire.isV2(nil))
		assert.is_false(Wire.isV2("x"))
		assert.is_false(Wire.isV2({}))
	end)
end)

describe("Wire send gating", function()
	before_each(function() env.reset(); loadWire() end)

	it("does not emit tuples by default", function()
		assert.is_false(Wire.shouldSendV2())
	end)

	it("emits tuples once sendV2Wire is on", function()
		TOGBankClassic_Switches:Set("sendV2Wire", true)
		assert.is_true(Wire.shouldSendV2())
	end)

	-- Receiving is deliberately NOT gated. If this ever becomes switchable, a client could stop
	-- understanding its own guild.
	it("decodes both formats regardless of the send switch", function()
		TOGBankClassic_Switches:Set("sendV2Wire", false)
		local _, v2 = Wire.decode(Wire.encode("Bob", { Record.new(858, 1) }))
		local _, legacy = Wire.decode({ name = "Bob", items = { { ID = 858, Count = 1 } } })
		assert.equal(1, #v2)
		assert.equal(1, #legacy)
	end)
end)

describe("Wire.estimateSize", function()
	before_each(function() env.reset(); loadWire() end)

	-- Measuring, not asserting a figure. INV2-DOC-001 pulled the bandwidth claims from the
	-- CurseForge page because they were unverified; this is what puts real numbers back.
	it("reports a tuple payload as substantially smaller than the legacy equivalent", function()
		local records, legacyItems = {}, {}
		for i = 1, 50 do
			records[i] = Record.new(800 + i, 20)
			legacyItems[i] = {
				ID = 800 + i, Count = 20,
				Link = ("|cffffffff|Hitem:%d:0:0:0:0:0:0:0:60|h[Some Item Name]|h|r"):format(800 + i),
			}
		end
		local v2     = Wire.estimateSize(Wire.encode("Bob-Testrealm", records))
		local legacy = Wire.estimateSize({ name = "Bob-Testrealm", items = legacyItems })
		assert.truthy(v2 < legacy,
			("tuple payload (%d) was not smaller than legacy (%d)"):format(v2, legacy))
	end)

	it("returns zero for a non-table", function()
		assert.equal(0, Wire.estimateSize(nil))
	end)
end)
