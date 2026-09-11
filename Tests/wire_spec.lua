-- Inventory/Wire — V2 payload encode/decode.
--
-- The property pinned here: `Wire.decode` is CAPABLE of reading both formats. That is a statement
-- about this decoder and nothing more.
--
-- IT IS NOT A STATEMENT ABOUT THE ADDON'S BEHAVIOUR, and this header used to imply it was --
-- "RECEIVE accepts both formats, unconditionally". Since the 2026-09-09 no-backwards-compatibility
-- directive, `Modules/Chat.lua`'s `togbank-d4` handler DROPS any payload that is not a tuple
-- payload before `Wire.decode` is reached, and warns the user by name when the sender is a banker.
-- So a green run of the legacy examples below says the decoder still works; it does NOT say a
-- legacy peer's inventory is accepted, because it is not.
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

-- AUDIT-S3. This block used to be "Wire legacy compatibility" and its first example was headed
-- "Permanent, not a migration aid: this is what lets a guild run mixed versions." It pinned
-- `Wire.decode` DECODING a legacy link payload -- the behaviour the 2026-09-09 no-backwards-
-- compatibility directive deleted -- and it stayed green because the decoder still could, even
-- though Modules/Chat.lua gated every real call on `isV2` first. A spec pinning a forbidden path is
-- worse than no spec: the next person to delete the path hits a red test with a confident message.
--
-- writ-cannot: the five legacy-decoding examples that stood here asserted a feature the operator
-- removed on purpose (directive of 2026-09-09: no backwards compatibility on the wire, delete the
-- legacy receive path); the decoder they exercised no longer exists, and keeping them would pin the
-- forbidden behaviour. They are replaced below by examples pinning the opposite.
--
-- The guard now lives in `Wire.decode` itself. These pin THAT: a non-tuple payload is dropped by
-- the callee, so there is nothing for a future caller to forget.
describe("Wire.decode drops anything that is not a tuple payload", function()
	before_each(function() env.reset(); loadWire() end)

	local function legacyPayload(items, money)
		return { name = "Bob-Testrealm", money = money or 0, items = items }
	end

	it("drops a legacy link payload rather than decoding it", function()
		local alt, records, money, format = Wire.decode(legacyPayload({
			{ ID = 858, Count = 20, Link = "|cffffffff|Hitem:858|h[Potion]|h|r" },
		}, 1234))
		assert.equal("dropped", format,
			"a legacy payload was classified as something other than dropped -- the decoder is " ..
			"accepting a format the wire no longer carries (AUDIT-S3)")
		assert.is_nil(alt, "a dropped payload must not yield an alt name to write under")
		assert.equal(0, #records, "a dropped payload must not yield records")
		assert.equal(0, money)
	end)

	-- The value a caller could branch on is the dangerous half: `if format == "legacy"` is a branch
	-- that can never run, and nothing about the code would say so.
	it("never returns a 'legacy' format value", function()
		local shapes = {
			legacyPayload({ { ID = 858, Count = 5 } }),
			{ name = "Bob-Testrealm", items = {} },
			{ alt = "Bob-Testrealm", items = { { ID = 1, Count = 1 } } },
			{},
		}
		for i, shape in ipairs(shapes) do
			local _, _, _, format = Wire.decode(shape)
			assert.is_not_equal("legacy", format, "shape " .. i .. " came back as 'legacy'")
		end
	end)

	it("still decodes a tuple payload", function()
		local alt, records, money, format = Wire.decode(Wire.encode("Bob-Testrealm", {
			Record.new(858, 20),
		}, 1234))
		assert.equal("v2", format)
		assert.equal("Bob-Testrealm", alt)
		assert.equal(1234, money)
		assert.equal(20, Record.count(records[1]))
	end)

	it("returns nothing useful for an unrecognisable payload", function()
		local alt, records, _, format = Wire.decode("not a table")
		assert.is_nil(alt)
		assert.equal(0, #records)
		assert.equal("invalid", format)
	end)

	-- The guard is the callee's, so the production caller's own check is belt-and-braces. Pin that
	-- the callee is sufficient on its own: a well-formed legacy payload with a real link yields
	-- nothing, so no caller can reach a legacy record by skipping a check.
	it("yields no records from a well-formed legacy payload, whatever the caller did first", function()
		local _, records = Wire.decode({ name = "Bob-Testrealm", items = {
			{ ID = 10132, Count = 1, Link = "|cff1eff00|Hitem:10132:2504:0:0:0:0:863:1:60|h[X]|h|r" },
		} })
		assert.equal(0, #records)
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

	-- INV2 step 9 flipped the default. The gate itself is what these two examine, so each now sets
	-- the switch explicitly and neither depends on which way the default happens to point.
	it("emits tuples by default", function()
		assert.is_true(Wire.shouldSendV2())
	end)

	it("stops emitting once sendV2Wire is turned off", function()
		TOGBankClassic_Switches:Set("sendV2Wire", false)
		assert.is_false(Wire.shouldSendV2())
	end)

	it("emits again when it is turned back on", function()
		TOGBankClassic_Switches:Set("sendV2Wire", false)
		TOGBankClassic_Switches:Set("sendV2Wire", true)
		assert.is_true(Wire.shouldSendV2())
	end)

	-- Receiving is deliberately NOT gated. If this ever becomes switchable, a client could stop
	-- understanding its own guild. AUDIT-S3: this used to assert "both formats" decode regardless
	-- of the switch; there is one format now, so it asserts that the switch cannot stop TUPLES
	-- decoding, and that a legacy payload is dropped whether the switch is on or off.
	it("decodes tuples regardless of the send switch, and drops legacy either way", function()
		TOGBankClassic_Switches:Set("sendV2Wire", false)
		local _, v2 = Wire.decode(Wire.encode("Bob", { Record.new(858, 1) }))
		local _, legacy, _, format = Wire.decode({ name = "Bob", items = { { ID = 858, Count = 1 } } })
		assert.equal(1, #v2, "the send switch must never affect receiving")
		assert.equal(0, #legacy)
		assert.equal("dropped", format)
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

-- CMD-004: the legacy shape now has ONE spelling, and this is what keeps it honest.
--
-- `/togbank dev bandwidth` compares a tuple payload against the legacy payload the same rows would
-- have been sent as, and THE RESULT OF THAT COMPARISON IS PUBLISHED -- it is the "85% less data"
-- figure on the CurseForge page and in README.txt. The legacy side was originally rebuilt inline in
-- Modules/Chat.lua, a second spelling with nothing asserting the two agreed. A silent divergence
-- there does not break anything visibly; it puts a wrong number in front of users.
--
-- AUDIT-S3 changed what the guard can be. These used to round-trip the shape through
-- `decodeLegacy`; that decoder is deleted (the wire is tuples-only), so `legacyShapeFor` is now the
-- ONLY spelling of the old format in the addon and there is nothing to round-trip through. The
-- examples assert the shape DIRECTLY instead -- the field names v1.3.2 put on the wire, the row
-- count, and that the suffix survives inside the link via the same `Scan.parseLink` the scanner
-- uses. If the shape drifts, these go red rather than the measurement quietly moving.
describe("CMD-004: Wire.legacyShapeFor emits the shape v1.3.2 put on the wire", function()
	before_each(function()
		env.reset()
		loadWire()
		-- A resolver that returns a realistic link. Without one, every row comes back link-less and
		-- the examples below would pass over a shape that proves nothing about links at all.
		TOGBankClassic_Inventory_Resolve = {
			describe = function(rec)
				local id = Record.id(rec)
				return { link = ("|cffffffff|Hitem:%d:0:0:0:0:0:%d:0:60|h[Item %d]|h|r")
					:format(id, Record.suffix(rec), id) }
			end,
		}
	end)

	it("produces the v1.3.2 payload shape, with the rows intact", function()
		local records = { Record.new(858, 7), Record.new(10132, 1, 863), Record.new(4306, 40) }
		local shape = Wire.legacyShapeFor("Bob-Testrealm", records, 1234)

		assert.equal("Bob-Testrealm", shape.name, "the old format carried the alt under `name`")
		assert.equal(1234, shape.money)
		assert.equal(#records, #shape.items,
			"rows were lost, so the published bandwidth comparison is measuring a payload nobody " ..
			"would have sent")
		for i, row in ipairs(shape.items) do
			assert.equal(Record.id(records[i]), row.ID, "row " .. i .. " ID")
			assert.equal(Record.count(records[i]), row.Count, "row " .. i .. " Count")
			assert.is_string(row.Link, "row " .. i .. " has no link, so it is not the old format")
		end
		-- And it must NOT be mistaken for a tuple payload, or the comparison compares V2 to V2.
		assert.is_false(Wire.isV2(shape), "legacyShapeFor produced something isV2 accepts")
	end)

	-- The identity must survive, not merely the row count: a shape that dropped the suffix would
	-- still pass by length while describing a different item. Read back through the scanner's own
	-- link parser, which is what a v1.3.2 receiver did with it.
	it("carries the suffix inside the link", function()
		local shape = Wire.legacyShapeFor("Bob-Testrealm", { Record.new(10132, 1, 863) }, 0)
		local _, suffix = TOGBankClassic_Inventory_Scan.parseLink(shape.items[1].Link)
		assert.equal(863, suffix,
			"the suffix did not survive -- legacyShapeFor is emitting links the variant cannot be " ..
			"read out of, so the comparison is against a lossier payload than the real legacy " ..
			"format was")
	end)

	-- The count that tells "the legacy payload really was this small" from "ItemDB is missing, so
	-- there are no links to measure". Without it a broken install reports a spectacular saving.
	it("reports how many rows actually resolved to a link", function()
		local records = { Record.new(858, 7), Record.new(10132, 1, 863) }
		local _, resolved, rows = Wire.legacyShapeFor("Bob-Testrealm", records, 0)
		assert.equal(2, rows)
		assert.equal(2, resolved)
	end)

	it("reports zero resolved when the resolver cannot produce links", function()
		TOGBankClassic_Inventory_Resolve = { describe = function() return { link = nil } end }
		local shape, resolved, rows = Wire.legacyShapeFor("Bob-Testrealm", { Record.new(858, 7) }, 0)
		assert.equal(1, rows)
		assert.equal(0, resolved,
			"an unresolvable item was counted as resolved, so a client with no ItemDB would " ..
			"report a huge bandwidth saving that is really just the absence of links")
		-- Still a well-formed legacy payload, just a link-less one -- the case an older client that
		-- could not resolve an item put on the wire.
		assert.equal(1, #shape.items)
		assert.is_nil(shape.items[1].Link)
	end)

	it("survives an absent resolver rather than erroring", function()
		TOGBankClassic_Inventory_Resolve = nil
		local shape, resolved = Wire.legacyShapeFor("Bob-Testrealm", { Record.new(858, 7) }, 0)
		assert.equal(0, resolved)
		assert.equal(1, #shape.items)
	end)

	it("returns an empty item list for no records", function()
		local shape, resolved, rows = Wire.legacyShapeFor("Bob-Testrealm", {}, 0)
		assert.same({}, shape.items)
		assert.equal(0, resolved)
		assert.equal(0, rows)
	end)
end)
