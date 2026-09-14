-- ComputeInventoryHash -- the gate that decides whether ANY sync happens.
--
-- This hash is compared before a delta is computed, so a distinction it cannot see is a change the
-- addon cannot notice. Audit findings 31 and 32 are both about that, and both are HIGH for the same
-- reason: they fail by making the hash MATCH when it should differ, and a false "in sync" is silent.
--
-- ASSERTED ON THE HASH INPUT, deliberately. `Core:Checksum` is stubbed to return its argument, so
-- these examples compare the string that goes INTO the checksum. That is where both findings live --
-- a checksum cannot recover a distinction its input never contained -- and it makes a failure say
-- which field went missing instead of "two numbers differ". The real Checksum is exercised by
-- syncwire_spec through the actual envelope.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local D

local function load()
	env.stubOutput()
	env.loadModules({
		"Modules/Constants.lua",
		"Modules/Inventory/Record.lua",
		"Modules/Inventory/Scan.lua",
		"Modules/DeltaComms.lua",
	})
	TOGBankClassic_Core = TOGBankClassic_Core or {}
	TOGBankClassic_Core.Checksum = function(_, s) return s end
	D = TOGBankClassic_DeltaComms
	return D
end

--- A legacy row carrying a link, which is the only place a pre-tuple row records suffix/enchant.
local function linked(id, count, suffix, enchant)
	return {
		ID = id, Count = count,
		Link = string.format("|cffffffff|Hitem:%d:%d:0:0:0:0:%d:0:60|h[Item %d]|h|r",
			id, enchant or 0, suffix or 0, id),
	}
end

--- HASH-REV-001 — revision 1 is FROZEN, and these examples assert its BUGS on purpose.
---
--- That is not a mistake and it is the only place in this suite where it is correct. Revision 1 is
--- what every unmigrated client in the wild computes; its value crosses the wire to be compared
--- against theirs, so "fixing" it breaks interop with every peer that has not upgraded. A spec that
--- pins the broken behaviour is what stops a later reader treating findings 31 and 32 as unfinished
--- work and helpfully correcting a function whose whole job is to stay wrong.
describe("ComputeLegacyInventoryHash: frozen revision 1", function()
	before_each(function() env.reset(); load() end)

	it("CANNOT see suffix, and must not learn to", function()
		local tiger  = D:ComputeLegacyInventoryHash({ linked(10132, 1, 863) },  nil, nil, 0)
		local monkey = D:ComputeLegacyInventoryHash({ linked(10132, 1, 2504) }, nil, nil, 0)
		assert.equal(tiger, monkey,
			"revision 1 became suffix-aware. It is FROZEN -- see hashInventoryItemsV1. Fixing it " ..
			"desyncs every client that has not upgraded, which is the break HASH-REV-001 avoids")
	end)

	it("CANNOT see enchant either", function()
		local plain     = D:ComputeLegacyInventoryHash({ linked(10132, 1, 0, 0) },    nil, nil, 0)
		local enchanted = D:ComputeLegacyInventoryHash({ linked(10132, 1, 0, 2504) }, nil, nil, 0)
		assert.equal(plain, enchanted, "revision 1 became enchant-aware; it is frozen")
	end)

	-- HASH-REV-002 (INV2-RETIRE-003). This example used to assert the OPPOSITE: that tuple rows
	-- contribute nothing and revision 1 collapses to money-only, because "unmigrated clients cannot
	-- read tuples, so it must not". That reasoning ended with the 2026-09-09 no-wire-back-compat
	-- directive -- there is no unmigrated client to agree with -- and the scan now hashes the V2
	-- record set, so a revision 1 that ignored tuples would be money-only on EVERY client at once.
	-- The IDENTITY is still frozen (`ID:Count`, the two examples above), and a tuple is read as
	-- exactly what a legacy row would have been: id and count, nothing else.
	it("reads a tuple as id and count, and nothing else (HASH-REV-002)", function()
		local tuples = D:ComputeLegacyInventoryHash({ { 858, 5 }, { 10132, 1, 863 } }, nil, nil, 7)
		local legacy = D:ComputeLegacyInventoryHash({ linked(858, 5), linked(10132, 1, 863) }, nil, nil, 7)
		assert.equal(legacy, tuples,
			"a tuple and the legacy row for the same item must hash the same under revision 1 -- the " ..
			"scan hashes tuples now, and a mixed shape must not move the value")
		local moneyOnly = D:ComputeLegacyInventoryHash({}, nil, nil, 7)
		assert.not_equal(moneyOnly, tuples,
			"revision 1 ignored the tuple rows and collapsed to money-only: every change on every " ..
			"client would hash the same as no change")
		-- Still blind to the suffix, on a tuple exactly as on a link.
		assert.equal(D:ComputeLegacyInventoryHash({ { 10132, 1, 863 } }, nil, nil, 0),
			D:ComputeLegacyInventoryHash({ { 10132, 1, 2504 } }, nil, nil, 0),
			"revision 1 became suffix-aware through the tuple path")
	end)

	it("still distinguishes what it always could -- id, count and money", function()
		-- Frozen does not mean inert. If revision 1 stopped discriminating at ALL it would report
		-- every inventory as identical, and mixed-version guilds would silently stop syncing.
		local five = D:ComputeLegacyInventoryHash({ linked(858, 5) }, nil, nil, 0)
		local six  = D:ComputeLegacyInventoryHash({ linked(858, 6) }, nil, nil, 0)
		local other = D:ComputeLegacyInventoryHash({ linked(859, 5) }, nil, nil, 0)
		local rich = D:ComputeLegacyInventoryHash({ linked(858, 5) }, nil, nil, 9999)
		assert.is_not.equal(five, six)
		assert.is_not.equal(five, other)
		assert.is_not.equal(five, rich)
	end)

	it("differs from revision 2 for a suffixed item, which is the entire reason both exist", function()
		local items = { linked(10132, 1, 863) }
		assert.is_not.equal(
			D:ComputeLegacyInventoryHash(items, nil, nil, 0),
			D:ComputeInventoryHash(items, nil, nil, 0))
	end)

	it("is stable across calls", function()
		local a = D:ComputeLegacyInventoryHash({ linked(858, 5), linked(10132, 1, 863) }, nil, nil, 42)
		local b = D:ComputeLegacyInventoryHash({ linked(858, 5), linked(10132, 1, 863) }, nil, nil, 42)
		assert.equal(a, b)
	end)
end)

describe("StampInventoryHashes", function()
	before_each(function()
		env.reset(); load()
		-- HASH-CANON-005: the canon is `<dts><hash>` with the content checksum zero-padded to ten
		-- digits, so it needs a NUMERIC checksum -- the identity stub the rest of this file uses
		-- (see the header) would put the whole hashed input where a number must go. This is the
		-- same 31-multiply the legacy hash uses; the value is irrelevant, the type is not.
		TOGBankClassic_Core.Checksum = function(_, s)
			local sum = 0
			for i = 1, #s do sum = (sum * 31 + string.byte(s, i)) % 2147483647 end
			return sum
		end
	end)

	it("writes both revisions from one item set", function()
		local alt = {}
		D:StampInventoryHashes(alt, { linked(10132, 1, 863) }, nil, nil, 0, 1757000000)
		assert.is_not_nil(alt.inventoryHash)
		assert.is_not_nil(alt.inventoryHashV2)
		assert.is_not.equal(alt.inventoryHash, alt.inventoryHashV2)
	end)

	-- HASH-CANON-005: the shape, asserted directly. The operator's words are the spec: "i wanted
	-- the hash to be <dts><hash> all one long string ... so you COULD read the DTS and do
	-- quick/easy comparison without having to pull the hash apart."
	it("mints the canon as <dts><hash>: twenty digits, the publish time first", function()
		local items = { linked(858, 5) }
		local canon = D:ComputeCanonHash(items, nil, nil, 0, 1757000000)
		assert.is_string(canon, "the canon is a STRING now, not a checksum with the date mixed in")
		assert.equal(20, #canon)
		assert.truthy(canon:match("^%d+$"), "the canon contains something other than digits: " .. canon)
		assert.equal("1757000000", canon:sub(1, 10), "the publish time is not the first ten digits")
		assert.equal(string.format("%010d", D:ComputeInventoryHash(items, nil, nil, 0)), canon:sub(11),
			"the last ten digits are not the content checksum")
	end)

	it("reads the publish time straight back off the canon", function()
		local canon = D:ComputeCanonHash({ linked(858, 5) }, nil, nil, 0, 1757000000)
		assert.equal(1757000000, D:CanonPublishTime(canon))
	end)

	-- The comparison the whole redesign is for: a LATER publish sorts HIGHER as a plain string,
	-- because the datestamp is fixed-width and leads. No parsing, no arithmetic.
	it("orders two canons by publish time with a plain string compare", function()
		local items = { linked(858, 5) }
		local earlier = D:ComputeCanonHash(items, nil, nil, 0, 1757000000)
		local later   = D:ComputeCanonHash(items, nil, nil, 0, 1757000001)
		assert.is_true(earlier < later, "the later publish does not sort higher")
		-- And a wildly different content at an earlier time still sorts LOWER: time dominates.
		local otherEarlier = D:ComputeCanonHash({ linked(2589, 20), linked(10132, 1, 863) }, nil, nil, 99, 1700000000)
		assert.is_true(otherEarlier < earlier)
	end)

	it("pads a small checksum and a small time so the width never varies", function()
		local canon = D:ComputeCanonHash({}, nil, nil, 0, 1)
		assert.equal(20, #canon)
		assert.equal("0000000001", canon:sub(1, 10))
	end)

	it("treats a missing or negative publish time as zero rather than erroring", function()
		assert.equal("0000000000", D:ComputeCanonHash({}, nil, nil, 0, nil):sub(1, 10))
		assert.equal("0000000000", D:ComputeCanonHash({}, nil, nil, 0, -5):sub(1, 10))
		assert.equal("0000000000", D:ComputeCanonHash({}, nil, nil, 0, "junk"):sub(1, 10))
	end)

	-- HASH-CANON-003: revision 2 is now the CANON and carries the publish datestamp, so it is
	-- ComputeCanonHash that must agree with it -- NOT ComputeInventoryHash, which is the
	-- datestamp-free CONTENT hash and is now the private change detector.
	it("agrees with computing each revision separately", function()
		local items = { linked(858, 5), linked(10132, 1, 863) }
		local alt = {}
		D:StampInventoryHashes(alt, items, nil, nil, 42, 1757000000)
		assert.equal(D:ComputeLegacyInventoryHash(items, nil, nil, 42), alt.inventoryHash)
		assert.equal(D:ComputeCanonHash(items, nil, nil, 42, 1757000000), alt.inventoryHashV2)
		assert.equal(D:ComputeInventoryHash(items, nil, nil, 42), alt.inventoryContentHash)
	end)

	-- THE PROPERTY THE WHOLE DESIGN RESTS ON. Identical contents published at two different times
	-- are two different versions and must be distinguishable, or "the newer hash wins" has nothing
	-- to compare. This is what the datestamp is in the hashed input FOR.
	it("gives the SAME contents a different canon at a different publish time", function()
		local items = { linked(858, 5) }
		assert.is_not.equal(
			D:ComputeCanonHash(items, nil, nil, 0, 1757000000),
			D:ComputeCanonHash(items, nil, nil, 0, 1757000001),
			"two publishes of identical contents collided as one version, so a guild can report " ..
			"itself converged across a change that really happened")
	end)

	-- And the other half, which is what stops the broadcast storm: the CONTENT hash must NOT move
	-- with time, because it is what decides whether to advance the datestamp at all. If this ever
	-- becomes time-dependent, every scan looks like a change and republishes to the whole guild.
	it("keeps the CONTENT hash free of the datestamp", function()
		local items = { linked(858, 5) }
		assert.equal(
			D:ComputeInventoryHash(items, nil, nil, 0),
			D:ComputeInventoryHash(items, nil, nil, 0),
			"the change detector is not stable, so every scan would look like a change")
		assert.is_not.equal(
			D:ComputeInventoryHash(items, nil, nil, 0),
			D:ComputeCanonHash(items, nil, nil, 0, 1757000000),
			"the canon and the content hash are the same number, so the datestamp is not actually " ..
			"in the hashed input")
	end)

	it("returns both without needing a record to write into", function()
		local legacy, current = D:StampInventoryHashes(nil, { linked(858, 5) }, nil, nil, 0, 1757000000)
		assert.is_not_nil(legacy)
		assert.is_not_nil(current)
	end)
end)

-- HASH-CANON-005: reading a canon back, and re-encoding what v1.4.0 left behind.
describe("CanonPublishTime / CanonFrom", function()
	before_each(function() env.reset(); load() end)

	describe("CanonPublishTime", function()
		it("reads the time off a canon", function()
			assert.equal(1757000000, D:CanonPublishTime("17570000000000424242"))
		end)

		it("is nil, never zero, for anything that is not a canon", function()
			-- Zero would sort as OLDER than everything and make garbage read as ancient data rather
			-- than as no data.
			assert.is_nil(D:CanonPublishTime(nil))
			assert.is_nil(D:CanonPublishTime(424242), "a v1.4.0 numeric canon has no readable time")
			assert.is_nil(D:CanonPublishTime("424242"), "too short")
			assert.is_nil(D:CanonPublishTime("175700000000042424200"), "too long")
			assert.is_nil(D:CanonPublishTime("1757000000000042424x"), "not all digits")
			assert.is_nil(D:CanonPublishTime("00000000000000424242"), "a zero time is not a time")
			assert.is_nil(D:CanonPublishTime({}))
		end)
	end)

	describe("CanonFrom -- the ONE spelling of 'is this a canon we carry'", function()
		it("passes a canon through unchanged", function()
			assert.equal("17570000000000424242", D:CanonFrom("17570000000000424242", 999))
			assert.equal("17570000000000424242", D:CanonFrom("17570000000000424242", nil))
		end)

		-- The re-encoding that spares the guild a rehydration: a v1.4.0 numeric canon plus the
		-- author's publish time becomes `<dts><number>`, deterministically, on every client.
		it("re-encodes a v1.4.0 numeric canon beside its publish time", function()
			assert.equal("17570000000000424242", D:CanonFrom(424242, 1757000000))
			-- A string is either a canon or nothing: a numeric STRING in the slot is not a v1.4.0
			-- canon (those are numbers, and the serializer keeps them numbers), so it is not guessed at.
			assert.is_nil(D:CanonFrom("424242", 1757000000))
		end)

		-- HASH-CANON-013, read off the live guild: `theirs=17890060850786974720` advertised for a
		-- real canon ending `...974116`. A peer on the previous release put the 20-digit string
		-- through `tonumber`, lost the low digits to a float, and re-advertised the float. A v1.4.0
		-- numeric canon is a 32-bit checksum; anything larger is a mangled string, not a version.
		it("refuses a number too large to be a v1.4.0 canon -- a string canon mangled through a float", function()
			assert.is_nil(D:CanonFrom(17890060850786974720, 1789006085),
				"a float-mangled canon was re-encoded into a canon with the right date and a wrong " ..
				"checksum, which compares unequal to the real one forever (HASH-CANON-013)")
			-- The bound is Core:Checksum's modulus (Core.lua:138, `% 2147483647`), which is also the
			-- most `%d` carries in this Lua without wrapping negative -- 4294967295 formats as
			-- "-2147483648", which is how this example first found the bound was wrong.
			assert.is_nil(D:CanonFrom(2147483647, 1757000000))
			assert.equal("17570000002147483646", D:CanonFrom(2147483646, 1757000000), "the top of the checksum range is still a canon")
		end)

		it("re-encodes identically wherever it runs -- author and receiver converge", function()
			assert.equal(D:CanonFrom(424242, 1757000000), D:CanonFrom(424242, 1757000000))
			assert.equal(D:CanonFrom(424242, 1757000000.7), D:CanonFrom(424242, 1757000000), "a fractional time floors")
		end)

		it("cannot re-encode a numeric canon with no publish time, and says nil", function()
			assert.is_nil(D:CanonFrom(424242, nil))
			assert.is_nil(D:CanonFrom(424242, 0))
			assert.is_nil(D:CanonFrom(424242, "junk"))
		end)

		it("is nil for garbage in the revision-2 slot", function()
			assert.is_nil(D:CanonFrom(nil, 1757000000))
			assert.is_nil(D:CanonFrom({}, 1757000000))
			assert.is_nil(D:CanonFrom("not a canon", 1757000000))
			assert.is_nil(D:CanonFrom(-1, 1757000000), "a negative number is not a checksum")
		end)

		it("only ever touches the revision-2 slot -- a revision-1 hash is never fed to it", function()
			-- Pinned as a source scan: the operator's "but ONLY for v2 hashes". Every call site
			-- passes hashV2 / inventoryHashV2; none passes hash / inventoryHash.
			local offenders = {}
			for _, path in ipairs({ "Modules/Guild.lua", "Modules/Chat.lua", "Modules/P2PSession.lua",
				"Modules/Inventory/Wire.lua", "Modules/DeltaComms.lua" }) do
				for lineNo, line in env.codeLines(env.readFile(path)) do
					local arg = line:match("CanonFrom%(%s*([%w_%.]+)") or line:match("canonOrNil%(%s*([%w_%.]+)")
					if arg and (arg == "hash" or arg:match("%.hash$") or arg:match("inventoryHash$")) then
						offenders[#offenders + 1] = string.format("%s:%d %s", path, lineNo, (line:gsub("^%s+", "")))
					end
				end
			end
			assert.same({}, offenders, "a revision-1 hash is being re-encoded as a canon")
		end)
	end)
end)

describe("ComputeInventoryHash: identity (finding 31)", function()
	before_each(function() env.reset(); load() end)

	-- The finding's own worked example. Same base ID, same count, different random suffix.
	it("distinguishes two suffix variants of one base ID", function()
		local tiger  = D:ComputeInventoryHash({ linked(10132, 1, 863) },  nil, nil, 0)
		local monkey = D:ComputeInventoryHash({ linked(10132, 1, 2504) }, nil, nil, 0)
		assert.is_not_equal(tiger, monkey,
			"a Spiked Club of the Tiger hashes identically to one of the Monkey, so a banker " ..
			"swapping one for the other never bumps the version and NO delta is ever computed -- " ..
			"peers keep showing the old variant until some unrelated change moves the hash")
	end)

	it("distinguishes two enchant variants of one base ID", function()
		local plain    = D:ComputeInventoryHash({ linked(10132, 1, 0, 0) },    nil, nil, 0)
		local enchanted = D:ComputeInventoryHash({ linked(10132, 1, 0, 2504) }, nil, nil, 0)
		assert.is_not_equal(plain, enchanted, "the enchant is absent from the hashed identity")
	end)

	-- Guards the other direction: the fix must not make the hash so specific that identical
	-- inventories stop matching, which would drive a permanent re-sync instead of a permanent stall.
	it("still matches two identical inventories", function()
		local a = D:ComputeInventoryHash({ linked(858, 5), linked(10132, 1, 863) }, nil, nil, 42)
		local b = D:ComputeInventoryHash({ linked(858, 5), linked(10132, 1, 863) }, nil, nil, 42)
		assert.equal(a, b)
	end)

	it("is independent of row order", function()
		local a = D:ComputeInventoryHash({ linked(858, 5), linked(10132, 1, 863) }, nil, nil, 0)
		local b = D:ComputeInventoryHash({ linked(10132, 1, 863), linked(858, 5) }, nil, nil, 0)
		assert.equal(a, b, "row order changed the hash, so a rescan that reorders forces a resync")
	end)

	it("still notices a count change", function()
		local five = D:ComputeInventoryHash({ linked(858, 5) }, nil, nil, 0)
		local six  = D:ComputeInventoryHash({ linked(858, 6) }, nil, nil, 0)
		assert.is_not_equal(five, six)
	end)

	it("still notices a money change", function()
		local poor = D:ComputeInventoryHash({ linked(858, 5) }, nil, nil, 0)
		local rich = D:ComputeInventoryHash({ linked(858, 5) }, nil, nil, 99999)
		assert.is_not_equal(poor, rich)
	end)
end)

describe("ComputeInventoryHash: tuple records (finding 32)", function()
	before_each(function() env.reset(); load() end)

	-- The failure this prevents: the old guard was `if item and item.ID`, and a tuple is positional
	-- with no `.ID`. Every row failed it, the item part of the hash came out EMPTY, and the hash
	-- collapsed to money-only -- so every inventory change hashed the same as no change and V2
	-- inventories would stop syncing entirely, with no error and a hash that still looks like a
	-- number. Worse than a hash that changes too often, because nothing draws attention to it.
	it("does not collapse to money-only when given tuples", function()
		local withItems = D:ComputeInventoryHash({ { 858, 5 }, { 10132, 1, 863 } }, nil, nil, 7)
		local moneyOnly = D:ComputeInventoryHash({}, nil, nil, 7)
		assert.is_not_equal(withItems, moneyOnly,
			"tuple rows were skipped entirely, so the hash saw no items at all -- every inventory " ..
			"change would hash the same as no change and syncing would stop silently")
	end)

	it("distinguishes tuple suffix variants", function()
		local tiger  = D:ComputeInventoryHash({ { 10132, 1, 863 } },  nil, nil, 0)
		local monkey = D:ComputeInventoryHash({ { 10132, 1, 2504 } }, nil, nil, 0)
		assert.is_not_equal(tiger, monkey)
	end)

	-- THE PROPERTY THAT MAKES THE STORAGE SWITCH SAFE, and the reason this file exists rather than
	-- two separate ones: a tuple and the legacy row it replaces must hash the SAME. If they did not,
	-- flipping `inventoryV2` would change every hash at once and every client would resync against
	-- every peer -- indistinguishable from the addon deciding all data everywhere is stale.
	it("hashes a tuple identically to the legacy row it replaces", function()
		local legacy = D:ComputeInventoryHash(
			{ linked(858, 5), linked(10132, 1, 863), linked(15260, 2, 0, 2504) }, nil, nil, 4242)
		local tuples = D:ComputeInventoryHash(
			{ { 858, 5 }, { 10132, 1, 863 }, { 15260, 2, 0, 2504 } }, nil, nil, 4242)
		assert.equal(legacy, tuples,
			"the same inventory hashes differently depending on which store it came from, so " ..
			"flipping inventoryV2 would invalidate every hash and force a guild-wide resync")
	end)

	-- A linkless legacy row (mail) records no suffix, and the tuple built from one carries 0/0.
	-- Those must agree, or mail alone would move the hash on every format flip.
	it("treats a linkless legacy row and its tuple the same", function()
		local legacy = D:ComputeInventoryHash({ { ID = 11754, Count = 3 } }, nil, nil, 0)
		local tuple  = D:ComputeInventoryHash({ { 11754, 3 } }, nil, nil, 0)
		assert.equal(legacy, tuple)
	end)

	it("survives a mixed array of both shapes without erroring", function()
		local mixed = D:ComputeInventoryHash({ linked(858, 5), { 10132, 1, 863 } }, nil, nil, 0)
		assert.is_string(mixed)
		assert.is_not_equal("", mixed)
	end)

	it("returns a value for an empty inventory rather than erroring", function()
		assert.is_string(D:ComputeInventoryHash({}, nil, nil, 0))
	end)
end)

-- HASH-PIN-001: THE CANON'S BYTES, FROZEN AS LITERALS.
--
-- Every example above compares two hashes with each other; none compares a hash to a VALUE. So a
-- change to the function that moved every hash by the same amount would pass them all -- and a
-- moved hash is a canon that no longer matches what every client in the guild already holds: one
-- version bump for every banker at once, and worse, a "content changed" for banks that did not.
-- These literals were captured on 2026-09-11 BEFORE the unreachable pre-SYNC-006 branch of
-- `computeInventoryHashWith` was deleted (Peer Review on 608cc17a: dead code in the one function
-- that mints canons is the dangerous choice), and they are what proves the deletion left the live
-- branch's bytes untouched. What is pinned is the string that goes INTO the checksum, under the
-- identity stub -- that is the whole of what DeltaComms contributes; the checksum itself is Core's
-- (ComputeChecksum, a local there, exercised through the real envelope by syncwire_spec), and
-- Core.lua cannot be loaded a second time in the shared state to pin the number here.
describe("HASH-PIN-001: the canon's bytes are frozen", function()
	local RECORDS = { { 858, 5 }, { 10132, 1, 863 }, { 15260, 2, 0, 2504 }, { 2589, 40 } }
	local MONEY = 123456

	before_each(function() env.reset(); load() end)

	it("revision 2 feeds the checksum exactly this string for a fixed record set", function()
		assert.equal("123456|I:10132:863:0:1,15260:0:2504:2,2589:0:0:40,858:0:0:5",
			D:ComputeInventoryHash(RECORDS, nil, nil, MONEY),
			"THE CANON MOVED. Every banker in every guild bumps a version on the next scan, and " ..
			"unchanged banks report as changed. If this was deliberate, it is a wire-visible " ..
			"change that belongs in the changelog under its own ticket, and this literal moves with it")
	end)

	it("revision 1 feeds the checksum exactly this string for the same records", function()
		assert.equal("123456|I:10132:1,15260:2,2589:40,858:5",
			D:ComputeLegacyInventoryHash(RECORDS, nil, nil, MONEY))
	end)

	it("hashes an empty inventory to exactly this", function()
		assert.equal("0|I:", D:ComputeInventoryHash({}, nil, nil, 0))
	end)
end)
