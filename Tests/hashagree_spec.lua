-- HASH-REV-002 — Guild:HashesAgreeWith, the single local-vs-remote hash comparison.
--
-- This comparison existed three times byte for byte (Guild:IsAltSyncPending,
-- Guild:ReportHashListCoverage, and Chat.lua's HLR compare) and none of the three was reached by a
-- spec. It is consolidated now specifically because the NEXT change to it is HASH-REV-001's hash
-- revision negotiation (audit finding 37) -- three unspecced copies about to be edited is how one
-- copy gets fixed and the others do not.
--
-- The rule these examples exist to hold is that a nil field is NOT a wildcard. `hash == 0` is a real
-- value meaning "empty inventory" and matches only another 0; an ABSENT field means the peer said
-- nothing, which cannot be read as agreement. Getting that backwards makes a client skip a sync it
-- needs, silently -- and "skipped a sync" looks identical to "was already in sync".
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function loadGuild()
	env.stubOutput()
	env.loadFile("Modules/Constants.lua")
	-- HASH-CANON-005: the comparison normalises both revision-2 slots through DeltaComms:CanonFrom.
	env.loadFile("Modules/DeltaComms.lua")
	env.loadFile("Modules/Guild.lua")
	return TOGBankClassic_Guild
end

describe("Guild:HashesAgreeWith", function()
	local Guild

	before_each(function()
		env.reset()
		Guild = loadGuild()
	end)

	it("agrees when both hashes match", function()
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 42, mailHash = 7 }, { hash = 42, mailHash = 7 })
		assert.is_true(matches)
	end)

	it("disagrees when the inventory hash differs", function()
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 42, mailHash = 7 }, { hash = 43, mailHash = 7 })
		assert.is_false(matches)
	end)

	it("disagrees when only the MAIL hash differs", function()
		-- Both halves are required. An inventory-only comparison would call this a match and skip a
		-- mail sync that is genuinely needed.
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 42, mailHash = 7 }, { hash = 42, mailHash = 8 })
		assert.is_false(matches)
	end)

	it("agrees when both sides are legitimately empty", function()
		-- 0 is a real value, not a sentinel: two clients that both hold nothing for an alt DO agree,
		-- and treating this as a mismatch would re-request an empty inventory forever.
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 0, mailHash = 0 }, { hash = 0, mailHash = 0 })
		assert.is_true(matches)
	end)

	it("does NOT treat our 0 as matching a peer's real hash", function()
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 0, mailHash = 0 }, { hash = 99, mailHash = 0 })
		assert.is_false(matches)
	end)

	it("does NOT treat an absent peer hash as agreement", function()
		-- The wildcard rule, and the reason it is written down: nil means the peer said nothing.
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 42, mailHash = 7 }, { mailHash = 7 })
		assert.is_false(matches)
	end)

	it("does NOT treat an absent peer MAIL hash as agreement", function()
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 42, mailHash = 7 }, { hash = 42 })
		assert.is_false(matches)
	end)

	it("reports zeros rather than raising when we hold no record for the alt", function()
		-- Every caller passes a possibly-absent localAlt; two of the three did so through an
		-- `and`/`or` chain of their own.
		local matches, localHash, localMailHash = Guild:HashesAgreeWith(nil, { hash = 42, mailHash = 7 })
		assert.is_false(matches)
		assert.equal(0, localHash)
		assert.equal(0, localMailHash)
	end)

	it("reports our own hashes back for the callers that log them", function()
		local matches, localHash, localMailHash =
			Guild:HashesAgreeWith({ inventoryHash = 42, mailHash = 7 }, { hash = 42, mailHash = 7 })
		assert.is_true(matches)
		assert.equal(42, localHash)
		assert.equal(7, localMailHash)
	end)

	it("disagrees, without raising, when the peer advertised nothing at all", function()
		local matches, localHash = Guild:HashesAgreeWith({ inventoryHash = 42, mailHash = 7 }, nil)
		assert.is_false(matches)
		assert.equal(42, localHash)
	end)
end)

--- HASH-REV-001 — the revision negotiation. This is the whole point of freezing revision 1: a
--- migrated and an unmigrated client must still be able to agree, so the corrected hash can ship
--- without a coordinated release across the guild (audit finding 37).
describe("Guild:HashesAgreeWith revision negotiation", function()
	local Guild

	before_each(function()
		env.reset()
		Guild = loadGuild()
	end)

	-- HASH-CANON-005: a canon is `<dts><hash>`, one string. These fixtures write real ones.
	local T = 1757000000

	it("uses revision 2 when both sides advertise it", function()
		-- Revision 1 AGREES here and revision 2 does not. Revision 1 is the blind one -- it cannot
		-- see suffix -- so trusting it when a better answer exists is exactly finding 31's failure:
		-- a banker swaps one suffix variant for another and nobody notices.
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 42, inventoryHashV2 = env.canon(T, 111), mailHash = 7 },
			{ hash = 42,          hashV2 = env.canon(T, 222),          mailHash = 7 })
		assert.is_false(matches)
	end)

	it("agrees on revision 2 even when the frozen revision 1 disagrees", function()
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 42, inventoryHashV2 = env.canon(T, 999), mailHash = 7 },
			{ hash = 43,          hashV2 = env.canon(T, 999),          mailHash = 7 })
		assert.is_true(matches)
	end)

	-- HASH-CANON-005: the same publish in the OLD encoding on one side and the new on the other is
	-- ONE version and must agree -- this is what spares the guild a rehydration on upgrade. The
	-- numeric canon is re-encoded beside its publish time before the comparison.
	it("agrees when one side holds a v1.4.0 numeric canon and the other its re-encoding", function()
		assert.is_true(Guild:HashesAgreeWith(
			{ inventoryHash = 42, inventoryHashV2 = 999, inventoryUpdatedAt = T, mailHash = 7 },
			{ hash = 42,          hashV2 = env.canon(T, 999),                    mailHash = 7 }))
		assert.is_true(Guild:HashesAgreeWith(
			{ inventoryHash = 42, inventoryHashV2 = env.canon(T, 999),          mailHash = 7 },
			{ hash = 42,          hashV2 = 999, updatedAt = T,                   mailHash = 7 }))
	end)

	it("treats a numeric canon with NO publish time as no revision 2 at all, and falls back to revision 1", function()
		-- Nothing can place that number in time, so it cannot be a canon; revision 1 decides.
		assert.is_true(Guild:HashesAgreeWith(
			{ inventoryHash = 42, inventoryHashV2 = 999, mailHash = 7 },
			{ hash = 42,          hashV2 = 111,          mailHash = 7 }),
			"two unreadable numbers were compared as revision 2 instead of falling back")
		assert.is_false(Guild:HashesAgreeWith(
			{ inventoryHash = 42, inventoryHashV2 = 999, mailHash = 7 },
			{ hash = 43,          hashV2 = 999,          mailHash = 7 }),
			"two equal unreadable numbers were taken as agreement")
	end)

	it("does not agree on revision 2 for the same content published at two different times", function()
		-- Two publishes are two versions, whatever their contents.
		assert.is_false(Guild:HashesAgreeWith(
			{ inventoryHash = 42, inventoryHashV2 = env.canon(T, 999),     mailHash = 7 },
			{ hash = 42,          hashV2 = env.canon(T + 1, 999),          mailHash = 7 }))
	end)

	it("falls back to revision 1 when the PEER does not speak revision 2", function()
		-- The peer is an unmigrated client. Revision 1 is the only shared language, and it must
		-- still produce agreement -- otherwise upgrading one client desyncs it from the whole guild,
		-- which is the break this design exists to avoid.
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 42, inventoryHashV2 = env.canon(T, 999), mailHash = 7 },
			{ hash = 42,                                               mailHash = 7 })
		assert.is_true(matches)
	end)

	-- HASH-CANON-006. This example used to assert the OPPOSITE ("falls back to revision 1 when WE do
	-- not have one yet") and it was pinning the live defect: read off the guild on 2026-09-10,
	-- Alchemyrcp's banker held canon + revision-1 808855588, the viewer held revision-1 808855588
	-- and NO canon (a copy from before canons existed). Revision 1 said "in sync", the viewer never
	-- requested, could never ACQUIRE a canon, and its tab read "v1" forever. The only way to get a
	-- canon is to fetch, so a peer having one when we do not is a mismatch by definition.
	it("does NOT agree when the peer holds a canon and we hold none -- fetching is the only way to get one", function()
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 42, mailHash = 7 },
			{ hash = 42, hashV2 = env.canon(T, 999), mailHash = 7 })
		assert.is_false(matches,
			"revision 1 agreed, so this client will never request the canon it lacks")
	end)

	it("still requires the mail hash to match, whichever revision decided the inventory", function()
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 42, inventoryHashV2 = env.canon(T, 999), mailHash = 7 },
			{ hash = 42,          hashV2 = env.canon(T, 999),          mailHash = 8 })
		assert.is_false(matches)
	end)

	it("negotiates down, never up: a revision-2 value is never compared against a revision-1 one", function()
		-- The mistake this guards against is reading `summary.hashV2 or summary.hash`, which would
		-- compare our revision-2 hash against their revision-1 hash -- two different functions over
		-- the same inventory, so it would report a mismatch forever and re-sync on every broadcast.
		-- The mail hashes MATCH deliberately, so the inventory comparison is the only thing that can
		-- decide the verdict. An earlier version of this example omitted mailHash entirely and went
		-- green under the very mutation it exists to catch, because the absent mail hash failed it
		-- for an unrelated reason -- a passing assertion that was testing nothing.
		local matches = Guild:HashesAgreeWith(
			{ inventoryHash = 500, inventoryHashV2 = env.canon(T, 42), mailHash = 7 },
			{ hash = 42, mailHash = 7 })
		assert.is_false(matches,
			"our revision-2 hash was compared against their revision-1 hash")
	end)
end)

--- The consolidation itself. Three copies agreeing today was never the problem; nothing keeping them
--- agreeing was. This refuses a fourth spelling in the two files that carried the first three.
describe("the local-vs-remote hash comparison has exactly one implementation", function()
	--- Lines, numbered correctly. `gmatch("[^\n]*")` looks right and is not: it yields an EMPTY
	--- match between every pair of lines, so a counter driven by it reports roughly double the real
	--- line number. A source guard whose whole output is a `file:line` cannot afford that, and it
	--- only shows up once the guard actually fires -- which is the worst time to discover it.
	local function lines(path)
		local fh = assert(io.open(path, "r"), "could not open " .. path)
		local src = fh:read("*a")
		fh:close()
		local out = {}
		for line in (src .. "\n"):gmatch("(.-)\r?\n") do
			out[#out + 1] = line
		end
		return out
	end

	it("computes the match nowhere but in HashesAgreeWith", function()
		local offenders = {}
		for _, path in ipairs({ "Modules/Guild.lua", "Modules/Chat.lua" }) do
			for lineNo, line in ipairs(lines(path)) do
				-- Comment lines are skipped, and that is not a convenience: the fix for the fourth
				-- copy DESCRIBES the old comparison in a comment, so a guard that reads prose
				-- flags the explanation of the thing it is enforcing. Code only.
				local isComment = line:match("^%s*%-%-") ~= nil
				-- The distinctive half of the duplicated block: comparing a summary field against a
				-- local hash. HashesAgreeWith's own body reads `summary.hash ~= nil and summary.hash
				-- == localHash`, so it is excluded by file rather than by pattern.
				if not isComment and (line:find("summary%.hash%s*==%s*localHash")
					or line:find("summary%.mailHash%s*==%s*localMailHash")) then
					offenders[#offenders + 1] = path .. ":" .. lineNo
				end
			end
		end
		-- Guild.lua holds the one legitimate implementation, so two hits there are expected and
		-- named; anything else is a reintroduced copy.
		assert.equal(2, #offenders,
			"expected exactly the two lines inside Guild:HashesAgreeWith itself; a further hit is a " ..
			"fourth spelling of the comparison, which is what HASH-REV-002 removed\n    " ..
			table.concat(offenders, "\n    "))
		for _, hit in ipairs(offenders) do
			assert.is_not_nil(hit:find("^Modules/Guild%.lua:"),
				"the only implementation must live in Guild.lua, found: " .. hit)
		end
	end)
end)
