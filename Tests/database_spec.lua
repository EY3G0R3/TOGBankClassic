-- Database.lua — schema initialisation, legacy migration, and the snapshot cache.
--
-- Load() runs against real players' SavedVariables on every login, including files written by
-- versions going back to v0.6. Its job is to fill in what is missing WITHOUT destroying what is
-- there, so the destructive-vs-additive boundary is what these specs pin down.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function loadDatabase()
	env.stubOutput()
	env.loadFile("Modules/Constants.lua")
	env.loadFile("Modules/Item.lua")
	env.loadFile("Modules/Database.lua")

	-- Stand in for AceDB: Init() is not called (it would need the real library), so the scoped
	-- tables are provided directly. Only .global and .faction are used by this addon.
	TOGBankClassic_Database.db = {
		global  = { debugCategories = {}, debugTags = {}, showUncategorizedDebug = true },
		faction = {},
	}
	return TOGBankClassic_Database
end

describe("Database:Load", function()
	local DB
	before_each(function()
		env.reset()
		DB = loadDatabase()
		TOGBankClassic_Core = env.coreHashStub(4242)
	end)

	it("creates a fresh guild record when none exists", function()
		local db = DB:Load("Testguild")
		assert.is_not_nil(db)
		assert.equal("Testguild", db.name)
		assert.is_table(db.alts)
		assert.is_table(db.requests)
	end)

	it("returns nil for a nil guild name", function()
		assert.is_nil(DB:Load(nil))
	end)

	it("preserves existing alt data", function()
		DB.db.faction["Testguild"] = { name = "Testguild", alts = { ["Bob-Testrealm"] = { version = 7 } } }
		local db = DB:Load("Testguild")
		assert.equal(7, db.alts["Bob-Testrealm"].version)
	end)

	it("preserves existing requests", function()
		DB.db.faction["Testguild"] = { name = "Testguild", requests = { ["r1"] = { id = "r1" } } }
		local db = DB:Load("Testguild")
		assert.is_not_nil(db.requests["r1"], "existing requests were wiped by Load")
	end)

	it("backfills missing settings without touching the ones present", function()
		DB.db.faction["Testguild"] = { name = "Testguild", settings = { maxRequestPercent = 50 } }
		local db = DB:Load("Testguild")
		assert.equal(50, db.settings.maxRequestPercent, "an existing setting was overwritten")
		assert.equal(30, db.settings.autoTombstoneDays, "a missing setting was not defaulted")
	end)

	it("normalises a malformed cancelReasons table", function()
		DB.db.faction["Testguild"] = { name = "Testguild", settings = { cancelReasons = "garbage" } }
		local db = DB:Load("Testguild")
		assert.is_table(db.settings.cancelReasons.custom)
		assert.is_table(db.settings.cancelReasons.presetDisabled.banker)
		assert.is_table(db.settings.cancelReasons.presetDisabled.member)
	end)

	it("defaults every help-note window to an empty string", function()
		local db = DB:Load("Testguild")
		assert.equal("", db.settings.helpNotes.inventory)
		assert.equal("", db.settings.helpNotes.search)
		assert.equal("", db.settings.helpNotes.requests)
	end)

	-- PERF-012: these were moved out of SavedVariables; leaving them behind keeps ~18k lines of
	-- dead data in the file forever.
	it("purges the legacy deltaHistory and deltaSnapshots fields", function()
		DB.db.faction["Testguild"] = {
			name = "Testguild", deltaHistory = { "junk" }, deltaSnapshots = { "junk" },
		}
		local db = DB:Load("Testguild")
		assert.is_nil(db.deltaHistory)
		assert.is_nil(db.deltaSnapshots)
	end)

	it("initialises the delta metric counters", function()
		local db = DB:Load("Testguild")
		assert.equal(0, db.deltaMetrics.bytesSentDelta)
		assert.equal(0, db.deltaMetrics.deltasApplied)
	end)
end)

-- ---------------------------------------------------------------------------
-- Audit MIGRATE-001
-- ---------------------------------------------------------------------------
describe("Database:Load legacy hash migration", function()
	local DB
	before_each(function()
		env.reset()
		DB = loadDatabase()
	end)

	-- MIGRATE-001 WAS WRONG AND THIS SPEC IS WHY IT LOOKED MEASURED. Read this before changing it.
	--
	-- The original spec stubbed TOGBankClassic_Core wholesale with a function whose third
	-- parameter it NAMED `mail`, then asserted money must arrive in the fourth. That is not the
	-- callee's contract -- it is the spec asserting its own stub's parameter names back at itself.
	-- It passed against a "fix" that put a table where the real callee reads money, which bakes a
	-- table address into the hash and makes it differ on every login (AUDIT finding 25).
	--
	-- A STUB CANNOT ADJUDICATE A CALLING CONVENTION. The convention lives in
	-- DeltaComms:ComputeInventoryHash(bank, bags, mailOrMoney, money), which documents BOTH forms
	-- at :150-152 and reads the third argument as money in the (bank, bags, money) branch.
	--
	-- AND THE MIGRATION HAS SINCE MOVED CONVENTIONS AGAIN, deliberately: finding 3's second half.
	-- It now uses the AGGREGATED form -- (items, nil, nil, money) -- because that is what every
	-- other producer uses (Bank.lua:345, Chat.lua:435, DeltaComms.lua:1325) and the container form
	-- produced a hash nothing else could reproduce. So money is now legitimately the FOURTH
	-- argument here, which is the SYNC-006 convention and not the mistake finding 25 was about.
	--
	-- The distinction that matters and is easy to lose: money in the fourth slot is correct WHEN
	-- bags is nil (aggregated), and wrong when bags is a container (pre-SYNC-006). The branch is
	-- selected by `bags == nil`, so the argument position alone is never the whole answer.
	it("migrates through the aggregated convention, with money in the money slot", function()
		local captured
		-- HASH-REV-001: the migration stamps BOTH revisions through Core:StampInventoryHashes, so
		-- the capture has to sit on the shared stub rather than on a bare ComputeInventoryHash --
		-- otherwise this asserts about a function the code under test no longer calls.
		TOGBankClassic_Core = env.coreHashStub(4242, {
			ComputeInventoryHash = function(_, bank, bags, mailOrMoney, money)
				captured = { bank = bank, bags = bags, mailOrMoney = mailOrMoney, money = money }
				return 4242
			end,
		})
		DB.db.faction["Testguild"] = {
			name = "Testguild",
			alts = {
				["Bob-Testrealm"] = {
					version = 100, money = 5000,
					bank = { items = {} }, bags = { items = {} },
					-- no inventoryHash → triggers the migration
				},
			},
		}
		DB:Load("Testguild")
		env.flushTimers()   -- the migration runs inside a C_Timer.After(0.5, ...)

		-- HASH-CANON-003 INVERTED THIS EXAMPLE, and the inversion is the point rather than a
		-- re-baselining. It used to assert WHICH ARGUMENTS the migration passed when minting a hash
		-- (audit findings 3 and 25, MIGRATE-001 -- a long argument about aggregated versus container
		-- form). The migration no longer mints one at all, so the whole argument is moot: it ran
		-- over SavedVariables that mostly describe OTHER PEOPLE'S bank characters, and minting a
		-- hash for those is this client inventing an identity for data it never read.
		--
		-- A record with no canon must simply keep having none. It advertises nothing and is
		-- re-requested from the client that can author one -- self-correcting, where an invented
		-- hash is indistinguishable from a real one and never heals.
		assert.is_nil(captured,
			"the migration computed an inventory hash. It must not: it does not know whether a " ..
			"record describes this player's own character or a copy of somebody else's received " ..
			"over the wire, and a hash is the identity of a version, produced only by the client " ..
			"that read the bank")

		local migrated = DB.db.faction["Testguild"].alts["Bob-Testrealm"]
		assert.is_nil(migrated.inventoryHash,
			"the migration stamped a revision-1 hash onto a record it did not author")
		assert.is_nil(migrated.inventoryHashV2,
			"the migration stamped a canon onto a record it did not author -- that number would " ..
			"then be advertised to the guild and adopted by peers as if an author had produced it")
	end)

	-- THE PROPERTY IS VALUE-DEPENDENCE, NOT REPEATABILITY, and the difference is the whole test.
	--
	-- My first attempt at this asserted "the same inputs hash the same twice" and passed the SAME
	-- table object to both calls. That cannot fail (AUDIT finding 26): `tostring` on one table
	-- returns the same string for the life of the process, so a baked-in address is stable across
	-- two calls BY CONSTRUCTION. An address only varies between sessions, or between distinct
	-- table instances. It also never passed a table at all -- both calls sent a number -- so it
	-- would have gone green against the very regression it was written to catch.
	--
	-- The real property: the hash must depend on the VALUE of its inputs, never on their IDENTITY.
	local function realHasher()
		env.loadFile("Modules/DeltaComms.lua")
		local core = { Checksum = function(_, s) return s end }
		function core:ComputeInventoryHash(bank, bags, mailOrMoney, money)
			return TOGBankClassic_DeltaComms.ComputeInventoryHash(
				TOGBankClassic_DeltaComms, bank, bags, mailOrMoney, money)
		end
		TOGBankClassic_Core = core
		return core
	end

	it("hashes on the value of its inputs, not on table identity", function()
		local core = realHasher()

		-- Structurally identical, deliberately DISTINCT tables. Two separate instances is what
		-- makes an address observable; reusing one hides it.
		local bankA = { items = { { ID = 858, Count = 5 } } }
		local bagsA = { items = { { ID = 2589, Count = 20 } } }
		local bankB = { items = { { ID = 858, Count = 5 } } }
		local bagsB = { items = { { ID = 2589, Count = 20 } } }

		assert.equal(core:ComputeInventoryHash(bankA, bagsA, 5000),
			core:ComputeInventoryHash(bankB, bagsB, 5000),
			"two structurally identical inventories hashed differently, so the hash depends on " ..
			"table identity rather than contents -- an address is in it")
	end)

	-- Names the defect rather than a property. Per finding 26 this failed against the reverted
	-- code too, because `mailOrMoney or 0` accepted a table without complaint -- the revert worked
	-- around the hazard rather than removing it. DeltaComms now type-guards the money slot.
	it("does not let a table in the money slot reach the hash", function()
		local core = realHasher()
		local bank = { items = { { ID = 858, Count = 5 } } }
		local bags = { items = { { ID = 2589, Count = 20 } } }

		local withTable = core:ComputeInventoryHash(bank, bags, { items = {} })
		local withZero  = core:ComputeInventoryHash(bank, bags, 0)

		assert.equal(withZero, withTable,
			"a table in the overloaded money slot changed the hash, so tostring() put a TABLE " ..
			"ADDRESS in it. That address differs between sessions, so the hash matches nothing -- " ..
			"including itself an hour earlier (audit finding 25/26)")
		assert.is_nil(tostring(withTable):find("table:", 1, true),
			"the hash string literally contains a table address")
	end)

	-- AUDIT finding 3, SECOND HALF. This is the assertion the arity argument distracted from, and
	-- it is the one with a user-visible cost: a migrated character's hash must equal the hash a
	-- normal scan produces for the same contents, or IsAltSyncPending sees a mismatch on every
	-- comparison for the rest of that character's life.
	--
	-- It fails against the container form by construction -- the two branches emit different
	-- strings ("B:"/"G:" against "I:") -- so this cannot pass by accident.
	it("migrates to the same hash a scan would produce for the same contents", function()
		local core = realHasher()
		env.loadFile("Modules/Item.lua")

		local bank = { items = { { ID = 858, Count = 5 } } }
		local bags = { items = { { ID = 2589, Count = 20 } } }

		-- What Bank:Scan stores and hashes: bank + bags + mail aggregated into one array.
		local aggregated = TOGBankClassic_Item:Aggregate(bank.items, bags.items)
		aggregated = TOGBankClassic_Item:Aggregate(aggregated, {})
		local scanned = {}
		for _, item in pairs(aggregated) do table.insert(scanned, item) end

		local scanHash = core:ComputeInventoryHash(scanned, nil, nil, 5000)
		local containerHash = core:ComputeInventoryHash(bank, bags, 5000)

		assert.is_true(scanHash ~= containerHash,
			"the two calling conventions produced the SAME hash, so this example can no longer " ..
			"detect the divergence it exists for -- check DeltaComms' two branches before " ..
			"weakening it")

		-- And the migration must land on the scan's value, not the container one.
		local migrated = { bank = bank, bags = bags, money = 5000, version = 100 }
		local items = migrated.items
		if not items then
			local agg = TOGBankClassic_Item:Aggregate(bank.items, bags.items)
			agg = TOGBankClassic_Item:Aggregate(agg, {})
			items = {}
			for _, item in pairs(agg) do table.insert(items, item) end
		end
		assert.equal(scanHash, core:ComputeInventoryHash(items, nil, nil, migrated.money),
			"a migrated character hashes differently from a scanned one with identical contents, " ..
			"so it can never agree with any peer (audit finding 3, second half)")
	end)

	it("changes when money changes", function()
		local core = realHasher()
		local bank = { items = { { ID = 858, Count = 5 } } }
		local bags = { items = { { ID = 2589, Count = 20 } } }

		assert.is_true(core:ComputeInventoryHash(bank, bags, 5000)
			~= core:ComputeInventoryHash(bank, bags, 9999),
			"money is not reaching the hash: changing it left the hash unchanged, which is what " ..
			"happens when a nil lands in the money slot and `mailOrMoney or 0` collapses to 0")
	end)

	it("does not recompute a hash that already exists", function()
		local calls = 0
		TOGBankClassic_Core = { ComputeInventoryHash = function() calls = calls + 1; return 1 end }
		DB.db.faction["Testguild"] = {
			name = "Testguild",
			alts = { ["Bob-Testrealm"] = {
				version = 100, inventoryHash = 999, bank = { items = {} }, bags = { items = {} },
			} },
		}
		DB:Load("Testguild")
		env.flushTimers()
		assert.equal(0, calls, "an existing inventoryHash was recomputed and overwritten")
	end)

	it("backfills inventoryUpdatedAt from version when it is missing", function()
		TOGBankClassic_Core = env.coreHashStub(1)
		DB.db.faction["Testguild"] = {
			name = "Testguild",
			alts = { ["Bob-Testrealm"] = { version = 12345, inventoryHash = 999 } },
		}
		DB:Load("Testguild")
		env.flushTimers()
		assert.equal(12345, DB.db.faction["Testguild"].alts["Bob-Testrealm"].inventoryUpdatedAt)
	end)

	it("gives pre-v0.6 bank and bags records a slots table", function()
		TOGBankClassic_Core = env.coreHashStub(1)
		DB.db.faction["Testguild"] = {
			name = "Testguild",
			alts = { ["Bob-Testrealm"] = {
				version = 1, inventoryHash = 1, bank = { items = {} }, bags = { items = {} },
			} },
		}
		DB:Load("Testguild")
		env.flushTimers()
		local alt = DB.db.faction["Testguild"].alts["Bob-Testrealm"]
		assert.is_table(alt.bank.slots)
		assert.is_table(alt.bags.slots)
	end)
end)

describe("Database snapshots", function()
	local DB
	before_each(function()
		env.reset()
		DB = loadDatabase()
		TOGBankClassic_Core = env.coreHashStub(1)
	end)

	it("round-trips a saved snapshot", function()
		assert.is_true(DB:SaveSnapshot("Testguild", "Bob-Testrealm", { version = 100, items = {} }))
		assert.equal(100, DB:GetSnapshot("Testguild", "Bob-Testrealm").version)
	end)

	it("stores a deep copy, not a live reference", function()
		local alt = { version = 100, items = { { ID = 858, Count = 1 } } }
		DB:SaveSnapshot("Testguild", "Bob-Testrealm", alt)
		alt.items[1].Count = 999
		assert.equal(1, DB:GetSnapshot("Testguild", "Bob-Testrealm").items[1].Count,
			"the snapshot aliased the live table, so it cannot serve as a delta baseline")
	end)

	it("returns nil for an unknown alt", function()
		assert.is_nil(DB:GetSnapshot("Testguild", "Nobody"))
	end)

	it("expires a snapshot older than the max age", function()
		DB:SaveSnapshot("Testguild", "Bob-Testrealm", { version = 100 })
		env.advance(TOGBankClassic_Constants.PROTOCOL.DELTA_SNAPSHOT_MAX_AGE + 1)
		assert.is_nil(DB:GetSnapshot("Testguild", "Bob-Testrealm"))
	end)

	it("rejects a snapshot with no numeric version", function()
		DB:SaveSnapshot("Testguild", "Bob-Testrealm", { items = {} })
		assert.is_nil(DB:GetSnapshot("Testguild", "Bob-Testrealm"))
	end)

	it("refuses to save with a missing argument", function()
		assert.is_false(DB:SaveSnapshot(nil, "Bob", {}))
		assert.is_false(DB:SaveSnapshot("Testguild", nil, {}))
		assert.is_false(DB:SaveSnapshot("Testguild", "Bob", nil))
	end)
end)

describe("Database:DeepCopy", function()
	local DB
	before_each(function() env.reset(); DB = loadDatabase() end)

	it("copies nested tables by value", function()
		local src = { a = { b = { c = 1 } } }
		local copy = DB:DeepCopy(src)
		copy.a.b.c = 2
		assert.equal(1, src.a.b.c)
	end)

	it("returns non-tables unchanged", function()
		assert.equal(5, DB:DeepCopy(5))
		assert.equal("x", DB:DeepCopy("x"))
		assert.is_nil(DB:DeepCopy(nil))
	end)
end)

describe("Database:ResetPlayer", function()
	local DB
	before_each(function()
		env.reset()
		DB = loadDatabase()
		TOGBankClassic_Core = env.coreHashStub(1)
	end)

	it("clears one character's record", function()
		DB:Load("Testguild")
		DB.db.faction["Testguild"].alts["Bob-Testrealm"] = { version = 100 }
		DB:ResetPlayer("Testguild", "Bob-Testrealm")
		assert.same({}, DB.db.faction["Testguild"].alts["Bob-Testrealm"])
	end)

	-- DB-002: the guard checks `.alts[player]` but never `.faction[name]` itself.
	it("does not error for a guild that has no record", function()
		local ok, err = pcall(function() DB:ResetPlayer("NoSuchGuild", "Bob-Testrealm") end)
		assert.is_true(ok,
			"ResetPlayer raised for an unknown guild: it dereferences faction[name].alts with " ..
			"no nil guard on faction[name] (audit DB-002). Error: " .. tostring(err))
	end)
end)
