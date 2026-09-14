-- CANON-TIME-001: THIS CLIENT NEVER INVENTS THE TIME A VERSION WAS PUBLISHED.
--
-- HASH-CANON-002/003 deleted every site that minted a HASH for data this client never read, and
-- Database.lua's migration carries the reasoning at length: "Minting one for those is this client
-- inventing an identity for data it never read ... it travels the same way, because we then
-- advertise our invented number and peers adopt it."
--
-- One field escaped that deletion. The same migration still read
-- `alt.inventoryUpdatedAt = alt.version or GetServerTime()` -- and a TIME is enough on its own,
-- because `Guild:ReencodeHeldCanons` runs immediately after the load and builds a canon as
-- `<inventoryUpdatedAt><hash>` from any still-numeric v1.4.0 canon. A record for SOMEONE ELSE'S
-- banker, carried in a pre-v1.4.0 file with no version of its own, was therefore re-encoded as a
-- canon stamped with THIS CLIENT'S LOGIN TIME -- later than anything the real author ever
-- published -- and then advertised. The author's own tab goes red against a version that never
-- existed, and no rescan clears it, because the author cannot out-publish a timestamp that moves
-- forward with whoever logs in next.
--
-- WHY NOTHING CAUGHT IT: hashcache_spec's "clears the ones with no publish time" example stubs
-- `Database.Load` wholesale, so it proved the clearing against a loader with the migration removed
-- -- the one thing that defeats it. This file drives the REAL loader.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local GUILD  = "Testguild"
local OTHER  = "Otherbanker-Testrealm"
local C      = env.canon

--- Put `alts` in the SavedVariables as a pre-v1.4.0 file holds them, run the REAL Database:Load
--- (its migration is deferred half a second) and then the load-time re-encode, exactly as
--- Guild:Init sequences them. Returns the loaded record set.
local function loadWith(alts)
	TOGBankClassic_Database.db = { global = {}, faction = { [GUILD] = {
		name = GUILD, alts = alts, roster = { alts = {} },
		requests = {}, requestsTombstones = {}, settings = {},
	} } }
	local info = TOGBankClassic_Database:Load(GUILD)
	env.advance(0.5)                     -- the migration block runs on a timer inside Load
	TOGBankClassic_Guild.Info = info
	TOGBankClassic_Guild:ReencodeHeldCanons()
	return info
end

describe("CANON-TIME-001: the load-time migration never stamps our own clock", function()
	before_each(function()
		env.reset()
		env.standUpClient("Bankchar", { { name = OTHER, note = "gbank" } }, GUILD)
		-- standUpClient substitutes a Database stub for the sync specs; the REAL loader is the
		-- subject here, and the migration under test is inside it.
		env.loadFile("Modules/Database.lua")
	end)

	it("backfills the publish time from the record's OWN version", function()
		local info = loadWith({ [OTHER] = { name = OTHER, money = 0, inventoryHash = 0x10, version = 100 } })
		assert.equal(100, info.alts[OTHER].inventoryUpdatedAt)
	end)

	it("leaves it NIL when the record carries no version -- rather than stamping now", function()
		local info = loadWith({ [OTHER] = { name = OTHER, money = 0, inventoryHash = 0x10 } })
		assert.is_nil(info.alts[OTHER].inventoryUpdatedAt,
			"the migration stamped this client's clock as another banker's publish time")
	end)

	it("CLEARS such a record's numeric canon instead of re-encoding it at our login time", function()
		-- The whole defect in one example: a pre-v1.4.0 record for ANOTHER banker, no version.
		local info = loadWith({ [OTHER] = { name = OTHER, money = 0, inventoryHash = 0x10, inventoryHashV2 = 0x20 } })
		assert.is_nil(info.alts[OTHER].inventoryHashV2,
			"a canon was minted for a bank this client never read, dated at its own login -- every peer, " ..
			"the author included, then reads the author as behind a version that never existed")
	end)

	it("still re-encodes a record that DOES carry its own publish time, at that time", function()
		local info = loadWith({ [OTHER] = { name = OTHER, money = 0,
			inventoryHash = 0x10, inventoryHashV2 = 0x20, version = 100 } })
		assert.equal(C(100, 0x20), info.alts[OTHER].inventoryHashV2)
	end)

	it("never advertises a canon dated later than the newest real publish it holds", function()
		-- The property, stated the way the guild experiences it: whatever this client ends up
		-- holding for a banker it never read, its publish time is one the AUTHOR chose.
		env.advance(5000)                       -- our clock is now far ahead of the stored data
		local now = TOGBankClassic_Guild and GetServerTime()
		local info = loadWith({
			[OTHER] = { name = OTHER, money = 0, inventoryHash = 0x10, inventoryHashV2 = 0x20 },
		})
		local canon = info.alts[OTHER].inventoryHashV2
		if canon then
			local at = TOGBankClassic_DeltaComms:CanonPublishTime(canon)
			assert.is_true(at < now, "the canon this client holds is stamped at its own clock")
		end
	end)
end)
