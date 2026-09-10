-- Output:Debug dispatch — category gating, tag gating, and argument handling.
--
-- Every module in the addon logs through this one function, and its argument handling is
-- positional and untyped: Debug(fmt, ...) / Debug(CATEGORY, fmt, ...) / Debug(CATEGORY, TAG,
-- fmt, ...) are told apart by *inspecting the values*. That makes it the single highest-traffic
-- place where a caller mistake turns into silently wrong output rather than an error.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function lastPrinted()
	return env.printed[#env.printed]
end

describe("Output:Debug", function()
	local Output

	before_each(function()
		env.reset()
		Output = env.loadOutput({ BANK = true, SYNC = true })
	end)

	describe("category gating", function()
		it("emits when the category is enabled", function()
			Output:Debug("BANK", "hello")
			assert.equal(1, #env.printed)
		end)

		it("stays silent when the category is disabled", function()
			Output:Debug("ROSTER", "hello")
			assert.equal(0, #env.printed)
		end)

		it("returns false when suppressed so callers can branch on it", function()
			assert.is_false(Output:Debug("ROSTER", "hello"))
		end)

		it("labels the line with the category", function()
			Output:Debug("BANK", "hello")
			assert.truthy(lastPrinted():find("[BANK]", 1, true))
		end)
	end)

	describe("tag gating", function()
		it("labels the line CATEGORY.TAG for a registered tag", function()
			Output:Debug("BANK", "SCAN", "scanned %d", 7)
			assert.truthy(lastPrinted():find("[BANK.SCAN]", 1, true))
			assert.truthy(lastPrinted():find("scanned 7", 1, true))
		end)

		it("shows a tag that has never been configured (opt-out model)", function()
			Output:Debug("BANK", "GATE", "gated")
			assert.equal(1, #env.printed)
		end)

		it("suppresses a tag explicitly set to false", function()
			Output:SetTagEnabled("BANK", "SCAN", false)
			Output:Debug("BANK", "SCAN", "scanned")
			assert.equal(0, #env.printed)
		end)

		it("still emits other tags in the same category", function()
			Output:SetTagEnabled("BANK", "SCAN", false)
			Output:Debug("BANK", "GATE", "gated")
			assert.equal(1, #env.printed)
		end)
	end)

	-- This is the failure mode behind audit DEBUG-001. An unregistered tag is not treated as a
	-- tag; it becomes the format string, and the REAL format string is appended as data. The
	-- assertion states what should happen: the message must render its arguments.
	describe("unregistered tag handling", function()
		it("does not emit the format string as literal text", function()
			Output:Debug("BANK", "NOSUCHTAG", "scanned %d items", 7)
			local msg = lastPrinted()
			assert.is_not_nil(msg)
			assert.falsy(msg:find("%%d"),
				"the format string leaked into the output verbatim — the unregistered tag was " ..
				"treated as the format string and every argument shifted (audit DEBUG-001)")
			assert.truthy(msg:find("7", 1, true), "the formatted argument is missing")
		end)
	end)

	describe("argument handling", function()
		it("formats when the format string carries specifiers", function()
			Output:Debug("BANK", "%s has %d", "Bob", 3)
			assert.truthy(lastPrinted():find("Bob has 3", 1, true))
		end)

		it("concatenates with spaces when there are no specifiers", function()
			Output:Debug("BANK", "value", 42)
			assert.truthy(lastPrinted():find("value 42", 1, true))
		end)

		it("passes a lone message through untouched", function()
			Output:Debug("BANK", "plain message")
			assert.truthy(lastPrinted():find("plain message", 1, true))
		end)

		-- A % in user-supplied data (item names, notes) must not be read as a specifier.
		it("does not crash on a percent sign with no arguments", function()
			Output:Debug("BANK", "100% full")
			assert.truthy(lastPrinted():find("100% full", 1, true))
		end)
	end)

	describe("uncategorised messages", function()
		it("emits when showUncategorizedDebug is on", function()
			Output:Debug("not a category")
			assert.equal(1, #env.printed)
		end)

		it("stays silent when showUncategorizedDebug is off", function()
			TOGBankClassic_Database.db.global.showUncategorizedDebug = false
			Output:Debug("not a category")
			assert.equal(0, #env.printed)
		end)
	end)

	describe("category helpers", function()
		it("enables every known category at once", function()
			Output:DisableAllCategories()
			Output:EnableAllCategories()
			for category in pairs(DEBUG_CATEGORY) do
				assert.is_true(Output:IsCategoryEnabled(category), category .. " was not enabled")
			end
		end)

		it("disables every known category at once", function()
			Output:EnableAllCategories()
			Output:DisableAllCategories()
			for category in pairs(DEBUG_CATEGORY) do
				assert.is_false(Output:IsCategoryEnabled(category), category .. " was not disabled")
			end
		end)

		it("treats an unset tag as enabled", function()
			assert.is_true(Output:IsTagEnabled("BANK", "NEVER_SET"))
		end)
	end)
end)

describe("Output persistent log", function()
	local Output

	before_each(function()
		env.reset()
		Output = env.loadOutput({})
		TOGBankClassic_DebugLogEnabled = true
		Output.persistentLog = {}
	end)

	it("records entries with a timestamp", function()
		env.advance(1000)
		Output:AddToPersistentLog("first")
		assert.equal(1, #Output.persistentLog)
		assert.equal(1000, Output.persistentLog[1].timestamp)
		assert.equal("first", Output.persistentLog[1].message)
	end)

	it("records nothing while logging is disabled", function()
		TOGBankClassic_DebugLogEnabled = false
		Output:AddToPersistentLog("dropped")
		assert.equal(0, #Output.persistentLog)
	end)

	it("caps the log at persistentLogMaxEntries, dropping oldest first", function()
		Output.persistentLogMaxEntries = 3
		for i = 1, 5 do Output:AddToPersistentLog("entry" .. i) end
		assert.equal(3, #Output.persistentLog)
		assert.equal("entry3", Output.persistentLog[1].message)
		assert.equal("entry5", Output.persistentLog[3].message)
	end)

	it("garbage-collects entries older than the max age", function()
		Output:AddToPersistentLog("EXPIRED-ENTRY")
		env.advance(Output.persistentLogMaxAge + 1)
		Output:AddToPersistentLog("FRESH-ENTRY")
		Output:GarbageCollectPersistentLog()

		-- Exact match, not substring: the collector's own summary line ("collected 1 old debug
		-- log entries…") is itself appended to the log, and a loose check matches that instead.
		local function has(message)
			for _, e in ipairs(Output.persistentLog) do if e.message == message then return true end end
			return false
		end
		assert.is_false(has("EXPIRED-ENTRY"), "the expired entry survived collection")
		assert.is_true(has("FRESH-ENTRY"), "the fresh entry was collected")
	end)

	-- LOG-001, now FIXED, and this spec is the inversion of the one that recorded it.
	--
	-- GarbageCollectPersistentLog ends with a Debug() call and Log() appends every DEBUG-level
	-- message to the persistent log, so collection used to write a new entry into the log it had
	-- just collected: the log could never drain to empty and every pass seeded the next one. The
	-- old spec asserted that self-logging happened, and said in its own failure message that the
	-- note should be removed if it ever stopped being true.
	--
	-- It stopped being true as a CONSEQUENCE OF FIXING DEBUG-001 rather than by direct repair.
	-- That call passes "SYSTEM" as its category. SYSTEM was not in DEBUG_CATEGORY, so it fell
	-- through to the uncategorised branch, which logs unconditionally. Registering SYSTEM as a
	-- real category (which DEBUG-001 required, because the same absence was mangling other
	-- messages) puts it behind IsCategoryEnabled, and it defaults to off -- so the collector's
	-- own summary is no longer written into the log it collects.
	it("does not write its own summary back into the persistent log", function()
		Output:AddToPersistentLog("old")
		env.advance(Output.persistentLogMaxAge + 1)
		Output:GarbageCollectPersistentLog()
		for _, e in ipairs(Output.persistentLog) do
			assert.is_nil(e.message:find("Garbage collected", 1, true),
				"the collector logged its own summary into the log it just collected, so the log " ..
				"can never drain to empty and each pass seeds the next (audit LOG-001)")
		end
	end)

	it("filters the compact export by substring, case-insensitively", function()
		Output:AddToPersistentLog("alpha message")
		Output:AddToPersistentLog("beta message")
		local text, count = Output:ExportPersistentLogCompact(100, "ALPHA")
		assert.equal(1, count)
		assert.truthy(text:find("alpha message", 1, true))
		assert.falsy(text:find("beta", 1, true))
	end)
end)
