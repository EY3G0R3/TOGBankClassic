-- END-TO-END: HASH-REV-001's revision negotiation, driven through a real scan.
--
-- WHY THIS FILE EXISTS. HASH-REV-001 was specced at the unit level -- `hashagree_spec` feeds
-- `HashesAgreeWith` hand-built summary tables, and `inventoryhash_spec` calls the two hash functions
-- directly. Both pass against a negotiation that is internally consistent and wrong in place: NOTHING
-- proved that the hashes a real scan STAMPS are the ones a real advertisement CARRIES, or that a peer
-- comparing them reaches the same verdict. Hand-built fixtures cannot show that, because I wrote both
-- sides of them.
--
-- The claim HASH-REV-001 rests on is one sentence: **an upgraded client and an un-upgraded one still
-- agree about an identical inventory.** That claim spans scan -> stamp -> advertise -> compare, and
-- until this file nothing exercised it end to end.
--
-- REAL HASHES, NOT `env.coreHashStub`. Every other pipeline spec stubs Core's hash surface to a fixed
-- number. That is right for those files and fatal here: a constant hash makes every negotiation
-- example agree by construction, including a negotiation that compares revision 2 against revision 1.
-- Core's hash functions below forward to the real DeltaComms, over the real ComputeChecksum.
--
-- WHAT THIS DOES **NOT** COVER, so it is not read as more than it is:
--   * the transport. This compares what `BuildBankerHashList` produces against what another client
--     stamped; it does not send it. Serialisation of that table is `syncpipeline_spec`'s ground.
--   * `Guild:GetBanks` and `GetNormalizedPlayer` are stubbed, because they need a live roster.
--     `NormalizeName`, `BuildBankerHashList` and `HashesAgreeWith` -- the functions under test --
--     are the REAL ones.
--   * a genuinely old client. "Unmigrated" here is modelled by deleting the revision-2 fields, which
--     is what an old client's record and advertisement lack. It is a faithful shape, not a real peer.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local GUILD = "Testguild"
local ME    = "Bankchar-Testrealm"

--- Core's real checksum, reproduced exactly (Core.lua:125-139). Frozen cross-implementation value:
--- DeltaComms carries a character-for-character identical copy, and neither may be "improved".
local function checksum(str)
	if not str or type(str) ~= "string" then return 0 end
	local sum, len = 0, #str
	for i = 1, len do
		sum = (sum * 31 + string.byte(str, i)) % 2147483647
	end
	return (sum * 31 + len) % 2147483647
end

local function loadClient()
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
		"Modules/Guild.lua",
		"Modules/Bank.lua",
	})

	local D = TOGBankClassic_DeltaComms
	TOGBankClassic_Core = {
		Checksum                   = function(_, str) return checksum(str) end,
		ComputeInventoryHash       = function(_, ...) return D:ComputeInventoryHash(...) end,
		ComputeLegacyInventoryHash = function(_, ...) return D:ComputeLegacyInventoryHash(...) end,
		StampInventoryHashes       = function(_, alt, ...) return D:StampInventoryHashes(alt, ...) end,
	}

	TOGBankClassic_Guild.Info = { name = GUILD, alts = {} }
	TOGBankClassic_Guild.GetNormalizedPlayer = function() return ME end
	TOGBankClassic_Guild.GetBanks = function() return { ME } end

	TOGBankClassic_Options       = { GetBankEnabled = function() return true end }
	TOGBankClassic_Database      = { SaveSnapshot = function() return true end, db = { global = {} } }
	TOGBankClassic_MailInventory = { hasUpdated = false }

	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	TOGBankClassic_Database.db.global.switches = { inventoryV2 = true }
	TOGBankClassic_Bank.hasUpdated = true
	TOGBankClassic_Bank.eventsRegistered = false
end

--- Stage one bag and scan it as this client. Returns the alt record the scan stamped.
local function scan(contents)
	env.defineItem(858,   { name = "Minor Healing Potion" })
	env.defineItem(15260, { name = "Stone Hammer" })
	env.setBag(0, 4, contents)
	TOGBankClassic_Bank.hasUpdated = true
	TOGBankClassic_Bank:Scan()
	return TOGBankClassic_Guild.Info.alts[ME]
end

--- What a peer actually receives about this client's own alt: the real hash-list entry.
local function advertise()
	return TOGBankClassic_Guild:BuildBankerHashList()[ME]
end

--- Build a SECOND client from scratch and scan `contents` on it. Fresh env, fresh modules, fresh
--- store -- reusing the first client's tables would let a shared reference produce agreement that
--- nothing on the wire earned.
local function asSecondClient(contents)
	env.reset()
	loadClient()
	return scan(contents), advertise()
end

--- Strip the revision-2 fields, which is exactly what a client running the previous release lacks:
--- its records carry no `inventoryHashV2` and its advertisements carry no `hashV2`.
local function asUnmigrated(alt, summary)
	if alt then alt.inventoryHashV2 = nil end
	if summary then summary.hashV2 = nil end
	return alt, summary
end

local PLAIN   = { { id = 858, count = 5 } }
local TIGER   = { { id = 858, count = 5 }, { id = 15260, count = 1, suffix = 863 } }
local MONKEY  = { { id = 858, count = 5 }, { id = 15260, count = 1, suffix = 2504 } }

describe("HASH-REV-001 end to end: scan -> stamp -> advertise -> compare", function()
	before_each(function()
		env.reset()
		loadClient()
	end)

	it("stamps both revisions from a real scan, and they differ", function()
		local alt = scan(TIGER)
		assert.is_not_nil(alt, "precondition: the scan produced no alt record at all")
		assert.is_not_nil(alt.inventoryHash,   "the scan stamped no revision-1 hash")
		assert.is_not_nil(alt.inventoryHashV2, "the scan stamped no revision-2 hash")
		assert.is_not.equal(alt.inventoryHash, alt.inventoryHashV2,
			"both revisions produced the same value for a suffixed item, so one of them is not " ..
			"the function it claims to be")
	end)

	it("advertises both revisions, carrying exactly what the scan stamped", function()
		local alt = scan(TIGER)
		local summary = advertise()
		assert.is_not_nil(summary, "the banker advertised nothing for its own alt")
		assert.equal(alt.inventoryHash,   summary.hash,
			"the advertisement's revision-1 hash is not the one the scan stamped")
		assert.equal(alt.inventoryHashV2, summary.hashV2,
			"the advertisement's revision-2 hash is not the one the scan stamped")
	end)

	--- The everyday case: two upgraded clients, identical inventories, no sync needed.
	it("two migrated clients agree about an identical inventory", function()
		scan(TIGER)
		local summaryA = advertise()
		local altB = asSecondClient(TIGER)
		assert.is_true(TOGBankClassic_Guild:HashesAgreeWith(altB, summaryA),
			"two clients holding identical inventories reported a mismatch, so each would re-request " ..
			"the other's data on every hash-list broadcast, forever")
	end)

	--- Finding 31's exact scenario, now caught -- and this example proves WHICH revision caught it.
	it("two migrated clients notice a suffix swap that revision 1 cannot see", function()
		scan(TIGER)
		local summaryA = advertise()
		local altB = asSecondClient(MONKEY)

		-- The load-bearing half: revision 1 AGREES here. Same base id, same count, different suffix
		-- -- exactly the blindness finding 31 filed. If this assertion ever fails, revision 1 has
		-- been "fixed" and interop with un-upgraded clients is broken.
		assert.equal(summaryA.hash, altB.inventoryHash,
			"revision 1 distinguished a suffix swap. It is FROZEN -- see hashInventoryItemsV1")

		assert.is_false(TOGBankClassic_Guild:HashesAgreeWith(altB, summaryA),
			"a banker swapped one suffix variant for another at the same count and the negotiation " ..
			"reported agreement -- so no delta is computed and the change never propagates")
	end)

	--- HASH-CANON-006 REVERSED THIS EXAMPLE, and the old assertion is kept in the message so nobody
	--- restores it. It used to assert agreement -- "upgrading must not cut you off from the guild" --
	--- which was right while the guild ran mixed versions and is the exact defect once it does not
	--- (the no-backwards-compatibility directive): a client holding a copy with NO canon whose
	--- revision-1 hash equals the banker's current one was told "in sync", never requested, and could
	--- never ACQUIRE a canon. Read off the live guild: Alchemyrcp, banker 808855588 + canon, viewer
	--- 808855588 + none, tab red forever. The only way to get a canon is to fetch, so this pair must
	--- DISAGREE, and the disagreement is what triggers the fetch.
	it("a client with NO canon does NOT agree with a peer advertising one, even on an identical inventory", function()
		scan(PLAIN)
		local summaryA = advertise()
		local altB = asSecondClient(PLAIN)
		asUnmigrated(altB, nil)  -- B holds a pre-canon copy

		assert.is_nil(altB.inventoryHashV2, "precondition: B still looks migrated")
		assert.is_false(TOGBankClassic_Guild:HashesAgreeWith(altB, summaryA),
			"a pre-canon copy was called in sync with the banker's canon on revision 1 alone -- this " ..
			"client will never request, and never acquire, the canon it lacks")
	end)

	it("agrees in the other direction too: migrated client, unmigrated ADVERTISEMENT", function()
		scan(PLAIN)
		local summaryA = advertise()
		asUnmigrated(nil, summaryA)  -- A is running the previous release
		local altB = asSecondClient(PLAIN)

		assert.is_nil(summaryA.hashV2, "precondition: A still advertises revision 2")
		assert.is_true(TOGBankClassic_Guild:HashesAgreeWith(altB, summaryA),
			"an upgraded client disagreed with an un-upgraded peer's advertisement")
	end)

	it("two unmigrated clients agree, exactly as they did before any of this", function()
		scan(PLAIN)
		local summaryA = advertise()
		local altB = asSecondClient(PLAIN)
		asUnmigrated(altB, summaryA)

		assert.is_true(TOGBankClassic_Guild:HashesAgreeWith(altB, summaryA),
			"the frozen revision-1 path stopped working, which would desync every pair of clients " ..
			"that has not upgraded -- a regression caused entirely by code they do not run")
	end)

	--- HASH-CANON-006 changed the first half of this example. It used to assert that a client with no
	--- canon AGREED with a canon-bearing advertisement across a suffix swap ("the honest limitation
	--- ... blind to suffix"); under the no-back-compat rule that client disagrees for the prior
	--- reason -- it holds no canon at all -- and the fetch that follows is what heals it. The half
	--- that still matters is unchanged: a peer advertising NO canon is compared on revision 1, which
	--- is blind to the swap, and two canon-bearing clients catch it.
	it("a suffix swap is caught once both sides hold a canon; a canon-less ADVERTISEMENT is blind to it", function()
		scan(TIGER)
		local summaryA = advertise()

		-- A canon-less advertisement against our canon-bearing copy: revision 1 decides, and it
		-- cannot see the swap. That is the status quo for a peer that has not upgraded, and it heals
		-- the moment that peer scans on the new build.
		local altB = asSecondClient(MONKEY)
		local oldAdvert = { hash = summaryA.hash, updatedAt = summaryA.updatedAt, mailHash = summaryA.mailHash }
		assert.is_true(TOGBankClassic_Guild:HashesAgreeWith(altB, oldAdvert),
			"unexpected: the revision-1 fallback saw a difference revision 1 cannot represent")

		-- Both hold a canon: caught. Same two inventories, different verdict -- the entire value of
		-- shipping revision 2 at all.
		local altB2 = asSecondClient(MONKEY)
		assert.is_false(TOGBankClassic_Guild:HashesAgreeWith(altB2, summaryA),
			"once BOTH sides speak revision 2 the swap must be caught")
	end)

	it("still reports a mismatch a mixed pair CAN see: a changed count", function()
		-- The fallback must not be a rubber stamp. Revision 1 is blind to suffix, not to quantity,
		-- and a mixed guild has to keep syncing ordinary changes or upgrading one client silently
		-- freezes everybody else's view of it.
		scan(PLAIN)
		local summaryA = advertise()
		local altB = asSecondClient({ { id = 858, count = 4 } })
		asUnmigrated(altB, nil)

		assert.is_false(TOGBankClassic_Guild:HashesAgreeWith(altB, summaryA),
			"a mixed pair failed to notice a changed stack count, so ordinary changes would stop " ..
			"propagating to un-upgraded clients")
	end)
end)
