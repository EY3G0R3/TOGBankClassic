-- THE CANON HASH CONTRACT — the operator's design, asserted as executable rules.
--
-- Their words, which are the specification this file exists to hold:
--
--   "I NEED CANON hashes written ONCE by the banker, then passed around. NEVER mutated.
--    The hash HAS to have the DTS in it and the NEWER V2 Hash wins"
--   "that hash bump can ONLY be on the bankers, not on non-bankers or we have a problem"
--
-- WHY THIS FILE IS BUILT AROUND A DELIBERATELY WRONG VALUE. The obvious way to test "the hash is
-- not recomputed" is to check that a record still holds the RIGHT hash after some path runs. That
-- test is worthless: a path that quietly recomputes produces the right number and passes. So every
-- no-mutation example here plants a SENTINEL — a canon that provably does not match the contents —
-- drives a path, and asserts the sentinel SURVIVED. Only a path that left the value alone can pass.
-- (The method is DeltaSync's own, README "Checking yourself".)
--
-- REAL HASHES, NOT `env.coreHashStub`. Every other pipeline spec stubs Core's hash surface to a
-- fixed number, which is right for those files and fatal here: a constant hash makes "identical
-- contents at different times differ" and "unchanged contents do not churn" BOTH pass by
-- construction, which are two of the four rules under test. Core forwards to the real DeltaComms.
--
-- WHAT THIS FILE DOES NOT COVER, stated so it is not read as more than it is:
--   * no live client and no second real build — the operator rolls out to test that, and no offline
--     suite can substitute. What is proven here is that the DESIGN behaves as specified.
--   * the P2P negotiation layer (broadcast/collect/dispatch) — p2psession_spec's ground.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local GUILD  = "Testguild"
local BANKER = "Bankchar-Testrealm"
local PEER   = "Someoneelse-Testrealm"

-- A canon nothing can legitimately produce for these contents. If it is still here afterwards, the
-- path under test carried it rather than deriving one. HASH-CANON-005: a canon is `<dts><hash>`,
-- one string, so the sentinel is one; the content checksum it would have been minted from is
-- planted separately because that field stays numeric.
local SENTINEL_CONTENT = 424242
local SENTINEL = env.canon(1757000000, SENTINEL_CONTENT)
local SENTINEL_V1 = 313131

local function checksum(str)
	local sum, len = 0, #str
	for i = 1, len do sum = (sum * 31 + string.byte(str, i)) % 2147483647 end
	return (sum * 31 + len) % 2147483647
end

--- Load the full chain with REAL hash functions wired into Core.
local function loadChain(playerName, bankers)
	env.stubOutput()
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
		"Modules/Bank.lua",
	})

	local D = TOGBankClassic_DeltaComms
	TOGBankClassic_Core = {
		Checksum                   = function(_, s) return checksum(s) end,
		ComputeInventoryHash       = function(_, ...) return D:ComputeInventoryHash(...) end,
		ComputeLegacyInventoryHash = function(_, ...) return D:ComputeLegacyInventoryHash(...) end,
		-- NO ComputeCanonHash here, on purpose (AUDIT-S1 follow-on). The real Core fronts exactly
		-- three hash methods and this one is not among them: the canon is minted at ONE production
		-- site, inside DeltaComms:StampInventoryHashes, which is the invariant the class guard below
		-- pins. This table used to carry a fourth delegate, making the test surface WIDER than
		-- production -- CMD-001 with the sign reversed: correct-looking code calling
		-- Core:ComputeCanonHash would pass every spec and be "attempt to call a nil value" in the
		-- client, on the hash path, at scan time. Specs that need the canon directly call D.
		StampInventoryHashes       = function(_, alt, ...) return D:StampInventoryHashes(alt, ...) end,
		-- The envelope is a pass-through HERE ONLY. This file is about which client may produce a
		-- hash, not about framing, and syncwire_spec drives the real checksum envelope end to end.
		-- Named as a deliberate narrowing rather than left to be discovered: a stub with a looser
		-- contract than the real function is the CMD-001 class, and it is only safe because nothing
		-- asserted in this file depends on serialisation behaviour.
		SerializeWithChecksum      = function(_, t) return t end,
		DeserializeWithChecksum    = function(_, m) return true, m end,
	}

	TOGBankClassic_Guild = {
		Info = { name = GUILD, alts = {} },
		GetNormalizedPlayer = function() return playerName end,
		GetPlayer = function() return playerName end,
		NormalizeName = function(_, n) return n and (n:find("-") and n or n .. "-Testrealm") or nil end,
		GetBanks = function() return bankers end,
		IsAltDataAllowed = function() return true end,
		ConsumePendingSync = function() return false end,
		MarkPendingSync = function() end,
		HasAltContent = function() return true end,
		UpdateOnlineMember = function() end,
		IsPlayerOnline = function() return true end,
		hasRequested = false,
		IsBank = function(_, n)
			for _, b in ipairs(bankers or {}) do if b == n then return true end end
			return false
		end,
	}
	TOGBankClassic_Options       = { GetBankEnabled = function() return true end }
	TOGBankClassic_Database      = {
		SaveSnapshot = function() return true end,
		RecordDeltaReceived = function() end,
		db = { global = {} },
	}
	TOGBankClassic_MailInventory = { hasUpdated = false }

	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	TOGBankClassic_Database.db.global.switches = { inventoryV2 = true, sendV2Wire = true }
	TOGBankClassic_Bank.hasUpdated = true
	TOGBankClassic_Bank.eventsRegistered = false
	return TOGBankClassic_Bank
end

--- The alt record the scanning character owns.
local function myRecord()
	return TOGBankClassic_Guild.Info.alts[BANKER]
end

--- Plant a canon that cannot be derived from the record's contents.
local function plantSentinel()
	local alt = TOGBankClassic_Guild.Info.alts[BANKER]
	alt.inventoryHash        = SENTINEL_V1
	alt.inventoryHashV2      = SENTINEL
	alt.inventoryContentHash = SENTINEL_CONTENT
	alt.inventoryUpdatedAt   = 1757000000
	alt.version              = 1757000000
	return alt
end

local function assertSentinelSurvived(what)
	local alt = TOGBankClassic_Guild.Info.alts[BANKER]
	assert.equal(SENTINEL, alt.inventoryHashV2, string.format(
		"%s CHANGED THE CANON. A hash is the identity of a version, written once by the client that " ..
		"read the bank and carried unchanged by everyone else. The value planted here cannot be " ..
		"derived from these contents, so any other value means this path derived one", what))
	assert.equal(SENTINEL_V1, alt.inventoryHash, what .. " changed the frozen revision-1 hash")
end

-- ===================================================================================
-- RULE: written ONCE, by the banker
-- ===================================================================================
describe("CANON RULE 1: only the banker's own scan mints a hash", function()
	before_each(function() env.reset() end)

	it("mints a canon when the scanning character IS a banker", function()
		local Bank = loadChain(BANKER, { BANKER })
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 858, count = 5 } })

		Bank:Scan()

		local alt = myRecord()
		assert.is_not_nil(alt, "the banker's scan produced no record at all")
		assert.is_not_nil(alt.inventoryHashV2,
			"a banker scanned its own bank and produced no canon -- nothing else in the addon may " ..
			"produce one, so this alt can never be synced")
		assert.is_not_nil(alt.inventoryContentHash,
			"no content hash was stored, so the next scan has nothing to compare against and will " ..
			"republish whether or not anything changed")
	end)

	it("mints NOTHING when the scanning character is NOT a banker", function()
		local Bank = loadChain(PEER, { BANKER })
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 858, count = 5 } })

		Bank:Scan()

		-- Asserted through a defaulted table rather than guarded with `if alt then`: a scan that
		-- produced no record at all would make a guarded version pass while testing nothing.
		local alt = TOGBankClassic_Guild.Info.alts[PEER] or {}
		assert.is_nil(alt.inventoryHashV2,
			"a NON-BANKER minted a canon for itself. The operator's constraint is explicit: the " ..
			"hash bump can only be on bankers. A non-banker publishing a version identity puts a " ..
			"record into the guild's sync that no banker authored")
		assert.is_nil(alt.inventoryContentHash,
			"a non-banker stored a content hash, so its NEXT scan compares against it and " ..
			"believes it authored this record -- the bad state persists instead of being one blip")
	end)
end)

-- ===================================================================================
-- RULE: NEVER mutated — the sentinel sweep
-- ===================================================================================
describe("CANON RULE 2: no path re-mints a hash it did not author", function()
	local Bank

	before_each(function()
		env.reset()
		Bank = loadChain(PEER, { BANKER })  -- we are NOT the banker; this is somebody else's record
		TOGBankClassic_Guild.Info.alts[BANKER] = {
			name = BANKER, items = { { ID = 858, Count = 5 } }, money = 100,
		}
		plantSentinel()
	end)

	it("survives a no-change message that carries different hashes", function()
		env.loadFile("Modules/Chat.lua")
		local msg = {
			type = "no-change", name = BANKER, version = 999,
			hash = 777, hashV2 = 888, mailHash = 555,
		}
		TOGBankClassic_Chat:OnCommReceived("togbank-nochange",
			TOGBankClassic_Core:SerializeWithChecksum(msg), "WHISPER", BANKER)

		assertSentinelSurvived("a no-change message")
	end)

	-- The migration is the third site deleted in HASH-CANON-002 and the least obvious of the three,
	-- because it looks like local housekeeping. It runs over SavedVariables that mostly describe
	-- OTHER PEOPLE'S bank characters, so a hash minted here is an identity invented for data this
	-- client never read -- and it then gets advertised.
	it("survives the database migration", function()
		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		alt.bank = { items = {} }
		alt.bags = { items = {} }

		-- Database.lua REPLACES the module table on load, so the fixture is installed afterwards or
		-- it is silently discarded and this example asserts against a migration that never ran.
		env.loadFile("Modules/Database.lua")
		TOGBankClassic_Database.db = TOGBankClassic_Database.db or {}
		TOGBankClassic_Database.db.global = TOGBankClassic_Database.db.global or {}
		TOGBankClassic_Database.db.faction = {
			[GUILD] = { name = GUILD, alts = { [BANKER] = alt } },
		}

		assert.is_function(TOGBankClassic_Database.Load,
			"Database:Load is absent, so this example would pass without exercising the migration")
		TOGBankClassic_Database:Load(GUILD)
		env.flushTimers()   -- the migration runs inside a C_Timer.After(0.5, ...)

		assertSentinelSurvived("the database migration")
	end)

	it("survives a scan by a character that is not this alt", function()
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 858, count = 5 } })

		Bank:Scan()

		assertSentinelSurvived("another character's scan")
	end)

	-- THE CLASS GUARD, because the three examples above can only cover the paths that exist today
	-- and the failure that actually happens is a fourth appearing. Three were deleted this session
	-- and every one of them looked locally reasonable.
	it("has exactly ONE production site that can mint a hash", function()
		local ALLOWED = {
			["Modules/Bank.lua"]       = "the author's own scan, behind the isBank gate",
			["Core.lua"]               = "one-line forwarder",
			["Modules/DeltaComms.lua"] = "the implementation itself",
		}
		local found = {}
		for _, path in ipairs(env.shippedModules()) do
			local fh = io.open(path, "rb")
			if fh then
				local src = fh:read("*a")
				fh:close()
				for line in (src .. "\n"):gmatch("([^\n]*)\n") do
					local code = line:match("^(.-)%-%-") or line
					if code:find("StampInventoryHashes", 1, true)
						or code:find("ComputeCanonHash", 1, true) then
						found[path] = true
					end
				end
			end
		end
		for path in pairs(found) do
			assert.is_not_nil(ALLOWED[path], string.format(
				"%s mints an inventory hash. Only the client that READ THE BANK may produce one -- " ..
				"anywhere else it is that client's opinion of somebody else's data, it gets " ..
				"advertised, and peers adopt it. Three such sites were deleted in HASH-CANON-002 " ..
				"(a query-path recompute, a no-change adoption, and the database migration) and " ..
				"each looked reasonable where it stood", path))
		end
		assert.is_not_nil(found["Modules/Bank.lua"],
			"Bank.lua no longer mints, so either the author's stamp was removed or this guard's " ..
			"detection broke -- and a guard that finds nothing passes")
	end)
end)

-- ===================================================================================
-- RULE: the DTS is inside the hashed input
-- ===================================================================================
describe("CANON RULE 3: the datestamp is inside the hashed input", function()
	local D

	before_each(function()
		env.reset()
		loadChain(BANKER, { BANKER })
		D = TOGBankClassic_DeltaComms
	end)

	local function items() return { { ID = 858, Count = 5 } } end

	it("gives identical contents a DIFFERENT canon at a different publish time", function()
		assert.is_not.equal(
			D:ComputeCanonHash(items(), nil, nil, 0, 1757000000),
			D:ComputeCanonHash(items(), nil, nil, 0, 1757000001),
			"two publishes of identical contents collided as one version. The guild then reports " ..
			"itself converged across a change that really happened, and 'the newer hash wins' has " ..
			"nothing to compare")
	end)

	it("gives identical contents the SAME canon at the same publish time", function()
		assert.equal(
			D:ComputeCanonHash(items(), nil, nil, 0, 1757000000),
			D:ComputeCanonHash(items(), nil, nil, 0, 1757000000),
			"the canon is not reproducible from its inputs, so no two clients can ever agree")
	end)

	it("gives different contents a different canon at the same publish time", function()
		assert.is_not.equal(
			D:ComputeCanonHash({ { ID = 858, Count = 5 } }, nil, nil, 0, 1757000000),
			D:ComputeCanonHash({ { ID = 858, Count = 6 } }, nil, nil, 0, 1757000000),
			"a change in contents did not change the canon, so a real change syncs as 'no change'")
	end)

	-- THE OTHER HALF, and it is what stops the broadcast storm coming back. The CONTENT hash must
	-- NOT move with time, because it is what decides whether to advance the datestamp at all.
	it("keeps the CONTENT hash free of the datestamp", function()
		assert.equal(
			D:ComputeInventoryHash(items(), nil, nil, 0),
			D:ComputeInventoryHash(items(), nil, nil, 0),
			"the change detector is not stable, so every scan looks like a change and republishes")
		assert.is_not.equal(
			D:ComputeInventoryHash(items(), nil, nil, 0),
			D:ComputeCanonHash(items(), nil, nil, 0, 1757000000),
			"the canon and the content hash are the same number, so the datestamp is not actually " ..
			"in the hashed input")
	end)
end)

-- ===================================================================================
-- RULE: no churn — the broadcast storm must not come back
-- ===================================================================================
describe("CANON RULE 4: an unchanged bank does not produce a new version", function()
	local Bank

	before_each(function()
		env.reset()
		Bank = loadChain(BANKER, { BANKER })
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 858, count = 5 } })
	end)

	-- THE STORM TEST. The operator's report: "V1 has a broadcast STORM because the hashes are
	-- ALWAYS updating". If rescanning unchanged contents produces a new canon, every bank close
	-- republishes to the whole guild.
	it("produces the SAME canon when rescanned with nothing changed", function()
		Bank:Scan()
		local first = myRecord().inventoryHashV2
		local firstVersion = myRecord().version
		assert.is_not_nil(first, "precondition: the first scan produced no canon")

		env.now = (env.now or 0) + 3600   -- an hour later, same contents
		TOGBankClassic_Bank.hasUpdated = true
		Bank:Scan()

		assert.equal(first, myRecord().inventoryHashV2,
			"rescanning an UNCHANGED bank produced a new canon. Every bank close would then " ..
			"republish to the whole guild -- this is the broadcast storm, and it is what putting " ..
			"the datestamp inside the hash costs if the CONTENT hash is not the change detector")
		assert.equal(firstVersion, myRecord().version,
			"the version was bumped for an unchanged bank, so peers re-sync data they already have")
	end)

	it("produces a NEW canon when the contents actually change", function()
		Bank:Scan()
		local first = myRecord().inventoryHashV2

		env.now = (env.now or 0) + 3600
		env.setBag(0, 4, { { id = 858, count = 9 } })   -- a real change
		TOGBankClassic_Bank.hasUpdated = true
		Bank:Scan()

		assert.is_not.equal(first, myRecord().inventoryHashV2,
			"a real change in bank contents did not move the canon, so no peer will ever learn of " ..
			"it -- the sync reports itself healthy while clients run different data")
	end)
end)

-- ===================================================================================
-- RULE: the newer hash wins
-- ===================================================================================
describe("CANON RULE 5: the newer version wins, decided in one place", function()
	before_each(function()
		env.reset()
		loadChain(PEER, { BANKER })
		env.loadFile("Modules/Chat.lua")
		TOGBankClassic_Guild.Info.alts[BANKER] = {
			name = BANKER, items = {}, money = 0, inventoryUpdatedAt = 1757000000,
		}
	end)

	it("REFUSES a payload authored before the record we hold", function()
		assert.is_false(TOGBankClassic_Chat:ShouldApplyTuplePayload(BANKER, 1756000000),
			"a days-old snapshot relayed by another peer would overwrite a fresher record")
	end)

	it("accepts a payload authored after the record we hold", function()
		assert.is_true(TOGBankClassic_Chat:ShouldApplyTuplePayload(BANKER, 1757000001))
	end)

	it("accepts a re-send of the version we already hold", function()
		assert.is_true(TOGBankClassic_Chat:ShouldApplyTuplePayload(BANKER, 1757000000),
			"a retry after a lost chunk re-sends the same version; treating equal as stale drops " ..
			"it and leaves the alt permanently short")
	end)

	it("accepts a payload from an author that published no time", function()
		assert.is_true(TOGBankClassic_Chat:ShouldApplyTuplePayload(BANKER, nil),
			"refusing an unstamped payload freezes that alt rather than merely leaving it unordered")
	end)
end)

-- ===================================================================================
-- RULE: the canon travels, and a receiver stores it VERBATIM
-- ===================================================================================
describe("CANON RULE 6: the wire carries the author's canon, stored verbatim", function()
	before_each(function()
		env.reset()
		loadChain(PEER, { BANKER })
	end)

	-- HASH-CANON-004. THIS EXISTS BECAUSE A GREEN SUITE MISSED THE REGRESSION THAT CAUSED IT.
	--
	-- `Guild:HashesAgreeWith` (Guild.lua:1097) requires BOTH the inventory hash AND the mail hash to
	-- match before it calls an alt in sync. Only the author's own scan stamps `alt.mailHash`
	-- (Bank.lua:454). HASH-CANON-002 deleted the two paths that used to produce one for a REMOTE
	-- alt -- the query-path recompute and the no-change adoption -- correctly, because both minted a
	-- number on a client that had never read that mail. Nothing replaced them, and the wire did not
	-- carry it, so a receiver held nil for every remote banker while the banker advertised a real
	-- value: `mailHashMatches` false forever, every banker permanently sync-pending, re-requested
	-- indefinitely. A broadcast storm of the exact shape this work exists to remove.
	--
	-- 713 examples passed throughout. Nothing compared what the WIRE carries against what
	-- AGREEMENT needs, so the gap was invisible from both ends.
	it("carries the author's MAIL hash, which agreement also depends on", function()
		local Wire   = TOGBankClassic_Inventory_Wire
		local Record = TOGBankClassic_Inventory_Record
		local payload = Wire.encode(BANKER, { Record.new(858, 5) }, 100,
			SENTINEL_V1, SENTINEL, 1757000000, 99887766)
		-- NINE returns, not eight: the public `Wire.decode` wrapper yields one more value at
		-- position 4 than `decodeV2` does, so the mail hash is ninth. Counting the underscores
		-- against the inner function is how the first version of this landed on `updatedAt`.
		local _, _, _, _, _, _, _, _, mailHash = Wire.decode(payload)

		assert.equal(99887766, mailHash,
			"the author's mail hash did not survive the wire. A receiver cannot mint one -- only " ..
			"the client that read the mail may -- so it compares the banker's advertised value " ..
			"against nil and the alt never agrees, forever")
	end)

	it("keeps a nil mail hash nil rather than defaulting it", function()
		local Wire   = TOGBankClassic_Inventory_Wire
		local Record = TOGBankClassic_Inventory_Record
		local payload = Wire.encode(BANKER, { Record.new(858, 5) }, 100, 1, 2, 3, nil)
		-- NINE returns, not eight: the public `Wire.decode` wrapper yields one more value at
		-- position 4 than `decodeV2` does, so the mail hash is ninth. Counting the underscores
		-- against the inner function is how the first version of this landed on `updatedAt`.
		local _, _, _, _, _, _, _, _, mailHash = Wire.decode(payload)

		assert.is_nil(mailHash,
			"'this author has not scanned mail' must stay distinguishable from a real value -- " ..
			"coercing it to 0 would claim the banker's mail is empty, and 0 is a real hash meaning " ..
			"exactly that")
	end)

	it("round-trips the canon and the publish time", function()
		local Wire   = TOGBankClassic_Inventory_Wire
		local Record = TOGBankClassic_Inventory_Record
		local payload = Wire.encode(BANKER, { Record.new(858, 5) }, 100, SENTINEL_V1, SENTINEL, 1757000000)
		local _, _, _, _, hash, hashV2, _, updatedAt = Wire.decode(payload)

		assert.equal(SENTINEL_V1, hash)
		assert.equal(SENTINEL, hashV2,
			"the author's canon did not survive the wire, so a receiver has nothing to store and " ..
			"must derive its own -- which is the mutation this whole design removes")
		assert.equal(1757000000, updatedAt,
			"the author's publish time did not survive the wire, so ordering falls back to the " ..
			"receiver's arrival time and a relayed copy claims to be fresher than the original")
	end)

	-- THE SENTINEL AGAIN, on the one path that IS allowed to write a canon it did not compute.
	-- Storing the author's value verbatim is rule 5 of the canon rules; DERIVING one here is the
	-- defect. A hash that provably does not match the payload's contents proves which happened.
	it("stores a canon that does NOT match the contents, rather than recomputing one", function()
		local Wire   = TOGBankClassic_Inventory_Wire
		local Record = TOGBankClassic_Inventory_Record
		local payload = Wire.encode(BANKER, { Record.new(858, 5) }, 100, SENTINEL_V1, SENTINEL, 1757000000)

		TOGBankClassic_Guild.IsAltDataAllowed = function() return true end
		TOGBankClassic_Guild.ConsumePendingSync = function() return true end
		env.loadFile("Modules/Chat.lua")
		TOGBankClassic_Chat.IsAltDataAllowed = function() return true end

		TOGBankClassic_Chat:OnCommReceived("togbank-d4",
			TOGBankClassic_Core:SerializeWithChecksum(payload), "WHISPER", BANKER)

		-- Asserted unconditionally. Guarding on `alt.inventoryHashV2` being present would let a
		-- receive path that stored NOTHING pass this example, which is the failure it is closest to.
		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		assert.is_table(alt, "the tuple payload was not applied at all, so nothing here is tested")
		assert.equal(SENTINEL, alt.inventoryHashV2,
			"the receiver produced its own number instead of storing the author's. DeltaSync's " ..
			"rules name this exactly: 'recompute on receipt -- you overwrite the author's " ..
			"statement with your own opinion of their data. Now nobody is authoritative'")
		assert.equal(1757000000, alt.inventoryUpdatedAt,
			"the receiver stamped its own arrival time over the author's publish time, so a relayed " ..
			"copy will advertise itself as fresher than the original the further it travels")
	end)
end)
