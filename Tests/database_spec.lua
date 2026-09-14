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

	-- DB-003 (audit finding 18, round 20): the deltaMetrics literal lived in FOUR places and had
	-- diverged -- Reset/Load carried 16 keys, ResetDeltaMetrics 20 -- so a fresh guild record lacked
	-- the four timing counters a reset one had, and every reader carried an `or 0` to survive it.
	local function keySet(t)
		local keys = {}
		for k in pairs(t) do keys[#keys + 1] = k end
		table.sort(keys)
		return keys
	end

	it("gives a fresh record, a Load-repaired record and a reset record the SAME metric keys", function()
		local fresh = DB:Load("Testguild").deltaMetrics
		DB.db.faction["Repaired"] = { name = "Repaired" }
		local repaired = DB:Load("Repaired").deltaMetrics
		assert.is_true(DB:ResetDeltaMetrics("Testguild"))
		local reset = DB.db.faction["Testguild"].deltaMetrics
		assert.same(keySet(fresh), keySet(repaired))
		assert.same(keySet(fresh), keySet(reset), "Reset and ResetDeltaMetrics disagree on the metric keys (DB-003)")
		assert.equal(0, fresh.computeCount, "the timing counters are missing from a fresh record")
		assert.equal(20, #keySet(fresh))
	end)

	it("backfills the timing counters onto a record saved before they existed, without touching the rest", function()
		DB.db.faction["Old"] = { name = "Old", deltaMetrics = { bytesSentDelta = 77, deltasApplied = 3 } }
		local m = DB:Load("Old").deltaMetrics
		assert.equal(77, m.bytesSentDelta, "an existing counter was reset")
		assert.equal(3, m.deltasApplied)
		assert.equal(0, m.computeCount, "a counter the old record lacked was not backfilled -- readers must carry `or 0` forever")
		assert.equal(0, m.totalApplyTime)
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

	-- HASH-PIN-001 (2026-09-11): the four examples below used to drive the (bank, bags, money)
	-- container form. That branch was unreachable from production and is DELETED; the form is now
	-- refused. Each property they pinned still holds and is pinned on the one live convention.
	it("hashes on the value of its inputs, not on table identity", function()
		local core = realHasher()

		-- Structurally identical, deliberately DISTINCT tables. Two separate instances is what
		-- makes an address observable; reusing one hides it.
		local itemsA = { { ID = 858, Count = 5 }, { ID = 2589, Count = 20 } }
		local itemsB = { { ID = 858, Count = 5 }, { ID = 2589, Count = 20 } }

		assert.equal(core:ComputeInventoryHash(itemsA, nil, nil, 5000),
			core:ComputeInventoryHash(itemsB, nil, nil, 5000),
			"two structurally identical inventories hashed differently, so the hash depends on " ..
			"table identity rather than contents -- an address is in it")
	end)

	-- Names the defect rather than a property. Per finding 26 this failed against the reverted
	-- code too, because `mailOrMoney or 0` accepted a table without complaint -- the revert worked
	-- around the hazard rather than removing it. The guard sat ONLY on the deleted branch until
	-- HASH-PIN-001; the live branch had `money or 0`, and this is the example that would have
	-- caught it had it driven the live form.
	it("does not let a table in the money slot reach the hash", function()
		local core = realHasher()
		local items = { { ID = 858, Count = 5 }, { ID = 2589, Count = 20 } }

		local withTable = core:ComputeInventoryHash(items, nil, nil, { items = {} })
		local withZero  = core:ComputeInventoryHash(items, nil, nil, 0)

		assert.equal(withZero, withTable,
			"a table in the money slot changed the hash, so tostring() put a TABLE ADDRESS in it. " ..
			"That address differs between sessions, so the hash matches nothing -- including " ..
			"itself an hour earlier (audit finding 25/26)")
		assert.is_nil(tostring(withTable):find("table:", 1, true),
			"the hash string literally contains a table address")
	end)

	-- AUDIT finding 3, SECOND HALF, re-pinned. It used to assert that the two calling conventions
	-- hash DIFFERENTLY and that the migration lands on the scan's side. There is one convention
	-- now, so the property is that the old shape cannot be hashed at all -- a caller that passes
	-- it gets an error, never a silent money-only hash that agrees with no peer.
	it("refuses the retired (bank, bags, money) container form rather than hashing it money-only", function()
		local core = realHasher()
		local bank = { items = { { ID = 858, Count = 5 } } }
		local bags = { items = { { ID = 2589, Count = 20 } } }

		local ok, err = pcall(function() return core:ComputeInventoryHash(bank, bags, 5000) end)
		assert.is_false(ok, "the container form was accepted -- which convention is live is ambiguous again")
		assert.truthy(tostring(err):find("HASH-PIN-001", 1, true), tostring(err))
		assert.is_false((pcall(function() return core:ComputeInventoryHash(nil, nil, nil, 5000) end)))
	end)

	it("changes when money changes", function()
		local core = realHasher()
		local items = { { ID = 858, Count = 5 }, { ID = 2589, Count = 20 } }

		assert.is_true(core:ComputeInventoryHash(items, nil, nil, 5000)
			~= core:ComputeInventoryHash(items, nil, nil, 9999),
			"money is not reaching the hash: changing it left the hash unchanged, which is what " ..
			"happens when a nil lands in the money slot and `or 0` collapses to 0")
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

-- INV2-RETIRE-002: the delta-snapshot cache is gone, and the guard is that it STAYS gone. Its only
-- reader (the legacy alt-delta) was deleted in v1.4.0; a snapshot save that comes back is a deep copy
-- of every item row per scan for nothing. See the header of Modules/Database.lua.
-- writ-cannot: the eight examples that stood here drove SaveSnapshot / GetSnapshot / DeepCopy, which
-- were removed on purpose as dead code with a per-scan cost; the feature they covered no longer exists.
describe("Database snapshots (deleted)", function()
	local DB
	before_each(function()
		env.reset()
		DB = loadDatabase()
	end)

	it("exposes no snapshot surface", function()
		assert.is_nil(DB.SaveSnapshot)
		assert.is_nil(DB.GetSnapshot)
		assert.is_nil(DB.ValidateSnapshot)
		assert.is_nil(DB.DeepCopy)
		assert.is_nil(TOGBankClassic_Constants.PROTOCOL.DELTA_SNAPSHOT_MAX_AGE)
	end)
end)

-- INV2-RETIRE-003: THE LEGACY ITEM ROWS ARE STRIPPED ON LOAD, unconditionally. Measured on the
-- operator's account they were 56% of a 1.52 MB SavedVariables file, and nothing writes or reads
-- them any more. The record itself and its per-source METADATA (slots, lastScan, version, mailHash)
-- must survive: the status bar and the MULTIPC-001 publish gate read them.
describe("Database:Load strips the legacy item rows (INV2-RETIRE-003)", function()
	local DB
	before_each(function()
		env.reset()
		DB = loadDatabase()
		TOGBankClassic_Core = env.coreHashStub(4242)
	end)

	local function legacyRecord()
		return {
			name = "Bob-Testrealm", version = 7, money = 1234, inventoryHashV2 = "canon", mailHash = 9,
			items = { { ID = 858, Count = 5, Link = "|Hitem:858|h[x]|h" }, { ID = 2589, Count = 20 } },
			bank  = { slots = { count = 1, total = 24 }, lastScan = 100, items = { { ID = 858, Count = 5 } } },
			bags  = { slots = { count = 1, total = 16 }, lastScan = 100, items = { { ID = 2589, Count = 20 } } },
			mail  = { slots = { count = 0, total = 0 }, lastScan = 50, version = 1, items = {} },
		}
	end

	-- `rawget`, because after Load the record answers `items` from the store through its metatable
	-- (INV2-COMPAT-001, altcompat_spec). "Stripped" means gone from the RAW record -- which is what
	-- the client serializes -- not that the field reads nil.
	it("removes items, bank.items, bags.items and mail.items from every alt", function()
		DB.db.faction["Testguild"] = { name = "Testguild", alts = { ["Bob-Testrealm"] = legacyRecord(),
			["Carol-Testrealm"] = { version = 1, items = { { ID = 1, Count = 1 } } } } }
		local db = DB:Load("Testguild")
		for _, name in ipairs({ "Bob-Testrealm", "Carol-Testrealm" }) do
			local alt = db.alts[name]
			assert.is_nil(rawget(alt, "items"), name .. ": alt.items survived the load")
			assert.is_nil(alt.bank and alt.bank.items, name .. ": bank.items survived the load")
			assert.is_nil(alt.bags and alt.bags.items, name .. ": bags.items survived the load")
			assert.is_nil(alt.mail and alt.mail.items, name .. ": mail.items survived the load")
		end
	end)

	it("keeps the record and every piece of metadata on it", function()
		DB.db.faction["Testguild"] = { name = "Testguild", alts = { ["Bob-Testrealm"] = legacyRecord() } }
		local alt = DB:Load("Testguild").alts["Bob-Testrealm"]
		assert.equal(7, alt.version)
		assert.equal(1234, alt.money)
		assert.equal("canon", alt.inventoryHashV2)
		assert.equal(9, alt.mailHash)
		assert.same({ count = 1, total = 24 }, alt.bank.slots)
		assert.equal(100, alt.bank.lastScan, "the MULTIPC-001 read stamp was lost with the rows")
		assert.same({ count = 1, total = 16 }, alt.bags.slots)
		assert.equal(50, alt.mail.lastScan)
		assert.equal(1, alt.mail.version)
	end)

	it("strips synchronously, before Load returns -- not on a timer", function()
		DB.db.faction["Testguild"] = { name = "Testguild", alts = { ["Bob-Testrealm"] = legacyRecord() } }
		local db = DB:Load("Testguild")
		assert.is_nil(rawget(db.alts["Bob-Testrealm"], "items"),
			"the rows were still there when Load returned -- a reader running before a deferred " ..
			"strip would see them, and the SV would keep them if the session ended first")
	end)

	it("is unconditional -- a record the V2 store has never seen is stripped too", function()
		-- The V2 store is taken away for this example, which is the strongest form of "not gated on
		-- IsAltComplete": the strip cannot even ask. (Removed explicitly rather than assumed absent:
		-- module globals loaded by an earlier spec file survive env.reset in the shared Lua state.)
		local realStore = TOGBankClassic_Inventory_Store
		_G.TOGBankClassic_Inventory_Store = nil
		DB.db.faction["Testguild"] = { name = "Testguild", alts = { ["Bob-Testrealm"] = legacyRecord() } }
		local ok, err = pcall(function() return DB:Load("Testguild") end)
		_G.TOGBankClassic_Inventory_Store = realStore
		assert.is_true(ok, tostring(err))
		assert.is_nil(rawget(DB.db.faction["Testguild"].alts["Bob-Testrealm"], "items"))
	end)

	it("reports how many rows it removed, and zero on a second load", function()
		local db = { alts = { ["Bob-Testrealm"] = legacyRecord() } }
		assert.equal(4, DB:StripLegacyItemRows(db))   -- 2 aggregate + 1 bank + 1 bags + 0 mail, per row
		assert.equal(0, DB:StripLegacyItemRows(db), "a second pass found rows the first left behind")
	end)

	-- Load runs per guild; a record for a guild the player has since left would keep its rows in
	-- the file forever. Init strips every guild the faction scope holds.
	it("strips every guild record in the faction scope at Init time, not only the one being loaded", function()
		DB.db.faction["Current"] = { name = "Current", alts = { ["Bob-Testrealm"] = legacyRecord() } }
		DB.db.faction["Former"]  = { name = "Former",  alts = { ["Old-Testrealm"] = legacyRecord() } }
		assert.equal(8, DB:StripAllLegacyItemRows())
		assert.is_nil(DB.db.faction["Former"].alts["Old-Testrealm"].items,
			"a guild Load never runs for kept its legacy rows")
		assert.is_nil(DB.db.faction["Former"].alts["Old-Testrealm"].bank.items)
		assert.equal(0, DB:StripAllLegacyItemRows())
		DB.db = nil
		assert.equal(0, DB:StripAllLegacyItemRows(), "no database is zero rows, not an error")
	end)

	it("is called from Init, after the database is attached", function()
		local src = env.readFile("Modules/Database.lua")
		local init = src:match("function TOGBankClassic_Database:Init%(%)(.-)\nend")
		assert.is_not_nil(init, "could not locate Database:Init")
		local new, strip = init:find("AceDB%-3%.0", 1, false), init:find("StripAllLegacyItemRows", 1, true)
		assert.is_not_nil(strip, "Init does not call StripAllLegacyItemRows -- a former guild's rows stay in the SV")
		assert.is_true(new < strip, "the strip runs before the database exists")
	end)

	it("tolerates a malformed record without raising", function()
		local db = { alts = {
			["NotATable"] = "junk",
			["NoSubTables"] = { version = 1 },
			["ItemsNotATable"] = { items = "junk", bank = { items = 5 } },
		} }
		assert.has_no_error(function() DB:StripLegacyItemRows(db) end)
		assert.is_nil(db.alts["ItemsNotATable"].items)
		assert.is_nil(db.alts["ItemsNotATable"].bank.items)
		assert.equal(0, DB:StripLegacyItemRows(nil))
		assert.equal(0, DB:StripLegacyItemRows({}))
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
