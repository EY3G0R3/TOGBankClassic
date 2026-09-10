-- HASH-CANON-001 rule 7 — ordering is a different question from identity, and the tuple receive
-- path had no answer to it at all.
--
-- THE BUG THIS FILE EXISTS FOR WAS OBSERVED ON A LIVE GUILD, not inferred: a bank character's V2
-- record was replaced by older data. The legacy receive path has always refused a record that is
-- not newer (Guild.lua:3327, :3362). The tuple path called Store:SetAltRecords unconditionally, so
-- with several peers relaying the same alt, whichever snapshot arrived LAST won -- regardless of
-- when it was authored. A peer holding a days-old copy overwrote a fresh one silently.
--
-- AND IT COULD NOT HAVE BEEN FIXED IN ISOLATION, which is why the wire change and the guard ship
-- together. Wire.encode carried { version, alt, money, records, hash, hashV2 } and NO TIMESTAMP, and
-- the receiver stamped its own GetServerTime() on arrival. So every record looked as though it had
-- been published the moment we heard of it, and there was no honest number to order by.
--
-- THE SECOND HALF MATTERS AS MUCH AS THE FIRST, and is easy to miss: every receiver re-advertises
-- what it holds (Guild.lua:358, :1033, :1582) and P2PSession sorts candidate holders by updatedAt
-- DESCENDING to pick the freshest (P2PSession.lua:184-190). With a receive-time stamp, the peer who
-- received a snapshot MOST RECENTLY advertised the NEWEST time -- so a relayed third-hand copy
-- outranked the author's own record, and the further a copy travelled the fresher it claimed to be.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Wire, Record

local function loadModules()
	env.stubOutput()
	env.loadModules({
		"Modules/Constants.lua", "Modules/Switches.lua",
		"Modules/Inventory/Record.lua", "Modules/Inventory/Wire.lua",
		"Modules/Chat.lua",
	})
	env.stubCore()
	TOGBankClassic_Database = { db = { global = {} } }
	Wire   = TOGBankClassic_Inventory_Wire
	Record = TOGBankClassic_Inventory_Record
end

--- Put a record for `name` into the legacy alt table with a known publish time, which is what the
--- ordering guard reads.
local function holding(name, updatedAt)
	TOGBankClassic_Guild = TOGBankClassic_Guild or {}
	TOGBankClassic_Guild.Info = { name = "Testguild", alts = {} }
	if updatedAt then
		TOGBankClassic_Guild.Info.alts[name] = { name = name, inventoryUpdatedAt = updatedAt }
	end
end

describe("HASH-CANON-001 rule 7: the author's publish time travels", function()
	before_each(function() env.reset(); loadModules() end)

	it("round-trips updatedAt through encode and decode", function()
		local payload = Wire.encode("Toggems-Azuresong", { Record.new(858, 5) }, 100, 111, 222, 1757000000)
		local _, _, _, _, _, _, _, updatedAt = Wire.decode(payload)
		assert.equal(1757000000, updatedAt,
			"the author's publish time did not survive the wire, so a receiver has nothing to " ..
			"order by and must fall back to its own arrival time -- the defect this fixes")
	end)

	it("keeps nil as nil rather than inventing a time", function()
		local payload = Wire.encode("Toggems-Azuresong", { Record.new(858, 5) }, 100, 111, 222, nil)
		local _, _, _, _, _, _, _, updatedAt = Wire.decode(payload)
		assert.is_nil(updatedAt,
			"'the author published no time' must stay distinguishable from a real value -- " ..
			"defaulting to 0 or to now would make an unstamped record order against real ones")
	end)

	it("carries the time alongside both hashes, from one payload", function()
		local payload = Wire.encode("Toggems-Azuresong", { Record.new(858, 5) }, 100, 111, 222, 1757000000)
		local _, _, _, _, hash, hashV2, _, updatedAt = Wire.decode(payload)
		-- Rule 6's real content: version identity must not live in two places that can drift. These
		-- three are stamped by one scan (Bank.lua:417-420) and travel in one message, so they cannot.
		assert.equal(111, hash)
		assert.equal(222, hashV2)
		assert.equal(1757000000, updatedAt)
	end)
end)

describe("HASH-CANON-001 rule 7: a stale payload must not overwrite a newer record", function()
	local ALT = "Toggems-Azuresong"

	before_each(function() env.reset(); loadModules() end)

	it("REFUSES a payload authored before the record we hold", function()
		holding(ALT, 1757000000)
		assert.is_false(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1756000000),
			"a days-old snapshot relayed by another peer overwrote a fresh record -- this is the " ..
			"live data-loss bug, and the legacy path has always refused it (Guild.lua:3362)")
	end)

	it("accepts a payload authored after the record we hold", function()
		holding(ALT, 1756000000)
		assert.is_true(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1757000000))
	end)

	-- A retry after a lost chunk re-sends the same version. Treating equal as stale would drop it
	-- and leave the alt permanently short, which is a worse failure than re-applying it.
	it("accepts a re-send of the version we already hold", function()
		holding(ALT, 1757000000)
		assert.is_true(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1757000000))
	end)

	it("accepts anything for an alt we hold nothing for", function()
		holding(ALT, nil)
		assert.is_true(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1756000000))
	end)

	-- Refusing an unstamped payload would freeze that alt forever rather than merely leaving it
	-- unordered, and unordered is exactly the behaviour that shipped before this guard existed.
	it("accepts a payload from an author that published no time", function()
		holding(ALT, 1757000000)
		assert.is_true(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, nil),
			"an author between builds publishes no time; refusing it would freeze the alt")
	end)

	it("falls back to version when inventoryUpdatedAt is absent", function()
		TOGBankClassic_Guild.Info = { name = "Testguild", alts = { [ALT] = { name = ALT, version = 1757000000 } } }
		assert.is_false(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1756000000),
			"older records carry only `version`; ignoring it would leave them unprotected")
	end)
end)
