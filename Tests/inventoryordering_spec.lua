-- HASH-CANON-001 rule 7 — ordering is a different question from identity, and the tuple receive
-- path had no answer to it at all.
--
-- THE BUG THIS FILE EXISTS FOR WAS OBSERVED ON A LIVE GUILD, not inferred: a bank character's V2
-- record was replaced by older data. The legacy receive path always refused a record that was not
-- newer, inside Guild:ReceiveAltData -- deleted in commit 9c42109, which is why this cites the
-- behaviour and the commit rather than a line number. The tuple path called Store:SetAltRecords
-- unconditionally, so
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
	-- DeltaComms and Guild are loaded EXPLICITLY. This file used to load neither and pass anyway,
	-- on a TOGBankClassic_DeltaComms left in the shared Lua state by an earlier spec file -- the
	-- one-state hazard the harness README warns about. Wire.canonOrNil delegates to
	-- DeltaComms:CanonFrom and the ordering guard reads Guild:HasAltContent, so both are real here.
	env.loadModules({
		"Modules/Constants.lua", "Modules/Switches.lua", "Modules/Item.lua",
		"Modules/DeltaComms.lua", "Modules/Bank.lua", "Modules/Guild.lua",
		"Modules/Inventory/Record.lua", "Modules/Inventory/Wire.lua",
		"Modules/Chat.lua",
	})
	env.stubCore()
	TOGBankClassic_Database = { db = { global = {} } }
	Wire   = TOGBankClassic_Inventory_Wire
	Record = TOGBankClassic_Inventory_Record
end

--- Put a record for `name` into the alt table with a known publish time, and real contents in the
--- V2 store (INV2-RETIRE-003: that is what "holding content" means), which is what the ordering
--- guard defends. `updatedAt = nil` holds nothing at all.
local function holding(name, updatedAt)
	TOGBankClassic_Guild.Info = { name = "Testguild", alts = {} }
	env.freshV2()
	if updatedAt then
		TOGBankClassic_Guild.Info.alts[name] = { name = name, inventoryUpdatedAt = updatedAt }
		env.holdV2("Testguild", name, { { 858, 5 } })
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
		local canon = env.canon(1757000000, 222)
		local payload = Wire.encode("Toggems-Azuresong", { Record.new(858, 5) }, 100, 111, canon, 1757000000)
		local _, _, _, _, hash, hashV2, _, updatedAt = Wire.decode(payload)
		-- Rule 6's real content: version identity must not live in two places that can drift. These
		-- three are stamped by one scan (Bank.lua:417-420) and travel in one message, so they cannot.
		assert.equal(111, hash)
		assert.equal(canon, hashV2)
		assert.equal(1757000000, updatedAt)
	end)

	-- HASH-CANON-005: the canon is a 20-digit STRING and must cross the wire as one. `tonumber` on
	-- it turns twenty digits into a float and loses the low digits -- a canon that no longer equals
	-- itself after one hop. The exact publish that broke: 1757000000 followed by a ten-digit
	-- checksum is ~1.757e19, well past the 2^53 integer ceiling.
	it("carries the canon as a string, byte for byte, never through a number", function()
		local canon = env.canon(1757000000, 2147483646)
		local payload = Wire.encode("Toggems-Azuresong", { Record.new(858, 5) }, 100, 111, canon, 1757000000)
		assert.is_string(payload[6], "the canon was coerced on encode")
		local _, _, _, _, _, hashV2 = Wire.decode(payload)
		assert.is_string(hashV2, "the canon was coerced on decode")
		assert.equal(canon, hashV2)
		assert.equal(20, #hashV2)
	end)

	it("re-encodes a v1.4.0 numeric canon on the way in, beside its publish time", function()
		-- An un-upgraded banker still emits a number. Beside the time it stamped, that is the same
		-- publish the author will hold once upgraded, so the receiver re-encodes rather than drops.
		local payload = Wire.encode("Toggems-Azuresong", { Record.new(858, 5) }, 100, 111, 222, 1757000000)
		local _, _, _, _, _, hashV2 = Wire.decode(payload)
		assert.equal(env.canon(1757000000, 222), hashV2)
	end)

	-- HASH-CANON-008. The example above goes through THIS build's Wire.encode, which re-encodes the
	-- number before it is ever on the wire -- so it proved nothing about the decoder, and the decoder
	-- was calling canonOrNil WITHOUT the publish time. An old-build sender puts a raw number in slot
	-- 6; on the operator's viewer account that arrived as tuples + the author's time + NO canon for
	-- three bankers scanned that afternoon, and their tabs read "v1". This drives the raw payload.
	it("re-encodes a RAW numeric canon from an old-build sender, not only one this build encoded", function()
		local raw = { Wire.VERSION, "Toggems-Azuresong", 100, { { 858, 5 } }, 111, 222, 1757000000 }
		local _, _, _, _, hash, hashV2, _, updatedAt = Wire.decode(raw)
		assert.equal(111, hash)
		assert.equal(1757000000, updatedAt)
		assert.equal(env.canon(1757000000, 222), hashV2,
			"the decoder dropped an old-build numeric canon although its publish time was the very " ..
			"next field -- the receiver then holds the author's data with no canon and paints 'v1' " ..
			"(HASH-CANON-008)")
	end)

	it("drops a numeric canon that arrives with NO publish time -- there is nothing to lead with", function()
		local payload = Wire.encode("Toggems-Azuresong", { Record.new(858, 5) }, 100, 111, 222, nil)
		local _, _, _, _, hash, hashV2 = Wire.decode(payload)
		assert.equal(111, hash, "the revision-1 hash is untouched by this")
		assert.is_nil(hashV2)
	end)

	it("drops garbage in the revision-2 slot rather than carrying it", function()
		local raw = { Wire.VERSION, "Toggems-Azuresong", 100, { { 858, 5 } }, 111, "not-a-canon", 1757000000 }
		local _, _, _, _, hash, hashV2 = Wire.decode(raw)
		assert.equal(111, hash)
		assert.is_nil(hashV2)
	end)
end)

describe("HASH-CANON-001 rule 7: a stale payload must not overwrite a newer record", function()
	local ALT = "Toggems-Azuresong"

	-- freshV2 in before_each: the store outlives env.reset (it is addon state, not WoW state), so
	-- an example that stages a content-less stub must not inherit the previous example's records.
	before_each(function() env.reset(); loadModules(); env.freshV2() end)

	it("REFUSES a payload authored before the record we hold", function()
		holding(ALT, 1757000000)
		assert.is_false(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1756000000),
			"a days-old snapshot relayed by another peer overwrote a fresh record -- this is the " ..
			"live data-loss bug, and the legacy path always refused it in Guild:ReceiveAltData " ..
			"(deleted in 9c42109)")
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

	-- INV2-RETIRE-003: "with content" is the V2 store, seeded beside each record below.
	local function withContent(alt)
		TOGBankClassic_Guild.Info = { name = "Testguild", alts = { [ALT] = alt } }
		env.holdV2("Testguild", ALT, { { 858, 5 } })
	end

	it("falls back to version when inventoryUpdatedAt is absent", function()
		withContent({ name = ALT, version = 1757000000 })
		assert.is_false(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1756000000),
			"older records carry only `version`; ignoring it would leave them unprotected")
	end)

	-- A STUB -- the banker's canon seeded by a hash-list reply, with NO contents -- is not worth
	-- defending. Refusing an older-but-real delivery to protect an empty record leaves the alt with
	-- nothing; the operator's peers relay days-old copies all the time and those are better than air.
	it("accepts an older payload when all we hold is a content-less stub", function()
		TOGBankClassic_Guild.Info = { name = "Testguild", alts = { [ALT] = {
			name = ALT, inventoryHashV2 = env.canon(1758000000, 1), inventoryUpdatedAt = 1758000000 } } }
		assert.is_true(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1757000000, env.canon(1757000000, 2)),
			"an empty stub was defended against real contents")
	end)

	-- HASH-CANON-005: the guard reads the time off the CANON, like every other newer-question in the
	-- addon, so a sender whose sidecar and canon disagree cannot be ORDERED by one and DISPLAYED by
	-- the other. The sidecar is only consulted when there is no canon to read.
	describe("reads the time off the canon, not the sidecar", function()
		it("refuses a payload whose canon is older even though its sidecar claims newer", function()
			withContent({ name = ALT, inventoryHashV2 = env.canon(1757000000, 1), inventoryUpdatedAt = 1757000000 })
			assert.is_false(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1758000000, env.canon(1756000000, 2)),
				"the sidecar's newer time overrode the canon's older one")
		end)

		it("accepts a payload whose canon is newer even though its sidecar claims older", function()
			withContent({ name = ALT, inventoryHashV2 = env.canon(1757000000, 1), inventoryUpdatedAt = 1757000000 })
			assert.is_true(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1756000000, env.canon(1758000000, 2)))
		end)

		it("reads the HELD side off its canon too, over a sidecar that disagrees", function()
			withContent({ name = ALT, inventoryHashV2 = env.canon(1758000000, 1), inventoryUpdatedAt = 1750000000 })
			assert.is_false(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1757000000, env.canon(1757000000, 2)),
				"the held record's stale sidecar let an older payload through")
		end)

		it("falls back to the sidecar when the payload carries no canon", function()
			holding(ALT, 1757000000)
			assert.is_false(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1756000000, nil))
			assert.is_true(TOGBankClassic_Chat:ShouldApplyTuplePayload(ALT, 1758000000, nil))
		end)
	end)
end)
