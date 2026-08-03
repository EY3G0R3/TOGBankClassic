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
		TOGBankClassic_Core = { ComputeInventoryHash = function() return 4242 end }
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

	-- ComputeInventoryHash's signature is (bank, bags, mail, money). The migration calls it with
	-- three arguments, so `money` lands in the `mail` slot and `money` arrives nil. Every
	-- pre-v0.8 character is migrated to a hash computed from the wrong inputs — and that hash
	-- then drives every downstream sync comparison.
	it("passes money as the money argument, not as mail", function()
		local captured
		TOGBankClassic_Core = {
			ComputeInventoryHash = function(_, bank, bags, mail, money)
				captured = { bank = bank, bags = bags, mail = mail, money = money }
				return 4242
			end,
		}
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

		assert.is_not_nil(captured, "the legacy hash migration never ran")
		assert.equal(5000, captured.money,
			"money was passed positionally into the `mail` parameter — ComputeInventoryHash " ..
			"takes (bank, bags, mail, money) but the migration passes only three arguments, so " ..
			"every pre-v0.8 character gets a hash computed from the wrong inputs (audit MIGRATE-001)")
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
		TOGBankClassic_Core = { ComputeInventoryHash = function() return 1 end }
		DB.db.faction["Testguild"] = {
			name = "Testguild",
			alts = { ["Bob-Testrealm"] = { version = 12345, inventoryHash = 999 } },
		}
		DB:Load("Testguild")
		env.flushTimers()
		assert.equal(12345, DB.db.faction["Testguild"].alts["Bob-Testrealm"].inventoryUpdatedAt)
	end)

	it("gives pre-v0.6 bank and bags records a slots table", function()
		TOGBankClassic_Core = { ComputeInventoryHash = function() return 1 end }
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
		TOGBankClassic_Core = { ComputeInventoryHash = function() return 1 end }
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
		env.advance(PROTOCOL.DELTA_SNAPSHOT_MAX_AGE + 1)
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
		TOGBankClassic_Core = { ComputeInventoryHash = function() return 1 end }
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
