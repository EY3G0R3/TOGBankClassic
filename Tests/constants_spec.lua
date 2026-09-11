-- Constants registry consistency.
--
-- CLAUDE.md requires three tables to stay in lockstep: DEBUG_CATEGORY (Constants.lua), the
-- `debugCategories` defaults (Database:Init) and CATEGORY_META (Options.lua). It also requires
-- every comm prefix to be registered in COMM_PREFIX_DESCRIPTIONS or the SEND log prints
-- "(Unknown)". Those are invariants a human has to remember on every change — so they are
-- asserted here instead.
--
-- The last block is the important one. Output:Debug detects an optional tag by testing whether
-- arg 2 is a known key in DEBUG_TAGS[category]; when it is NOT, the tag string is silently
-- treated as the FORMAT STRING and every subsequent argument shifts by one. The result is
-- garbled output with raw %d in it, and nothing errors. Audit DEBUG-001 found three live cases.
-- This scans the source so the class cannot come back.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

-- Every source file that can contain a Debug() call.
local function sourceFiles()
	local files = {}
	local sep = package.config:sub(1, 1)
	local cmd = (sep == "\\")
		and 'dir /b /s "Modules\\*.lua" "Core.lua" 2>nul'
		or  'find Modules Core.lua -name "*.lua" 2>/dev/null'
	local p = io.popen(cmd)
	if p then
		for line in p:lines() do
			line = line:gsub("%s+$", "")
			-- Report repo-relative paths; `dir /s` yields absolute ones and they drown the diff.
			line = line:gsub(".*[/\\](Modules[/\\].*)$", "%1"):gsub(".*[/\\](Core%.lua)$", "%1")
			-- Skip the multi-megabyte generated data tables; they contain no Debug calls.
			if line ~= "" and not line:find("Static") then files[#files + 1] = line end
		end
		p:close()
	end
	return files
end

-- Both lifted into the env: the identical bodies were open-coded across several spec files, and a
-- scan helper copied per file can be corrected in one place and stay wrong in the others. The
-- comment-skipping in codeLines is load-bearing here -- without it these scans trip over
-- Output.lua's own doc header, which spells out the signature as Debug("CATEGORY", "TAG", ...).
local readFile  = env.readFile
local codeLines = env.codeLines

describe("Constants", function()
	-- NS-001: the constant tables are no longer bare globals -- Constants.lua publishes ONE global,
	-- TOGBankClassic_Constants, because another installed addon (Grouper) declared DEBUG_CATEGORY and
	-- LOG_LEVEL at file scope and won. Captured in before_each rather than at file scope because
	-- Constants.lua has not been loaded when this file is read.
	local DEBUG_CATEGORY, DEBUG_TAGS, COMM_PREFIX_DESCRIPTIONS

	before_each(function()
		env.reset()
		env.loadFile("Modules/Constants.lua")
		DEBUG_CATEGORY           = TOGBankClassic_Constants.DEBUG_CATEGORY
		DEBUG_TAGS               = TOGBankClassic_Constants.DEBUG_TAGS
		COMM_PREFIX_DESCRIPTIONS = TOGBankClassic_Constants.COMM_PREFIX_DESCRIPTIONS
	end)

	-- NS-001 guard. The collision this fixes was invisible in game: `/togbank debug BANK` answered
	-- "Unknown debug category" and offered another addon's eleven, because that addon's bare
	-- DEBUG_CATEGORY had overwritten ours. Nothing errored. Asserting the ABSENCE of the old bare
	-- globals is what stops one being reintroduced by a later edit -- luacheck no longer lists them,
	-- but a spec that reads _G is the check that survives someone re-adding them to .luacheckrc.
	it("publishes its constants under ONE namespace and leaves no bare global behind", function()
		local leaked = {}
		for _, name in ipairs({
			"ADOPTION_STATUS", "TIMER_INTERVALS", "LOG_LEVEL", "DEBUG_CATEGORY", "DEBUG_TAGS",
			"REQUEST_LOG", "REQUESTS_SYNC", "COMM_PREFIX_DESCRIPTIONS", "PROTOCOL", "PEER_TO_PEER",
			"FEATURES",
		}) do
			assert.is_not_nil(TOGBankClassic_Constants[name],
				name .. " is missing from TOGBankClassic_Constants")
			if rawget(_G, name) ~= nil then leaked[#leaked + 1] = name end
		end
		assert.same({}, leaked,
			"these are bare globals again -- another addon declaring the same name silently " ..
			"replaces them, which is audit NS-001 (see Modules/Constants.lua's header)")
	end)

	-- The same rule for the one bare FUNCTION Guild.lua used to declare. Its name is generic enough
	-- that a collision is a live risk rather than a theoretical one.
	it("declares no bare GetPlayerWithNormalizedRealm global", function()
		env.loadFile("Modules/Guild.lua")
		assert.is_nil(rawget(_G, "GetPlayerWithNormalizedRealm"),
			"GetPlayerWithNormalizedRealm is a bare global again (audit NS-001)")
		assert.is_function(TOGBankClassic_Guild.GetPlayerWithNormalizedRealm,
			"it should be published on the module table instead")
	end)

	it("gives every debug category a default in Database:Init", function()
		local dbSrc = readFile("Modules/Database.lua")
		-- The defaults block is `debugCategories = { NAME = false, ... }`.
		local block = dbSrc:match("debugCategories%s*=%s*{(.-)}")
		assert.is_not_nil(block, "could not find the debugCategories defaults block")
		for category in pairs(DEBUG_CATEGORY) do
			assert.is_not_nil(block:match("%f[%w]" .. category .. "%s*="),
				"DEBUG_CATEGORY." .. category .. " has no default in Database:Init")
		end
	end)

	it("gives every debug category a display row in CATEGORY_META", function()
		local meta = readFile("Modules/Options.lua"):match("CATEGORY_META%s*=%s*{(.-)\n}")
		assert.is_not_nil(meta, "could not find CATEGORY_META")
		for category in pairs(DEBUG_CATEGORY) do
			assert.is_not_nil(meta:match("%f[%w]" .. category .. "%s*="),
				"DEBUG_CATEGORY." .. category .. " has no CATEGORY_META row")
		end
	end)

	it("declares no DEBUG_TAGS entry for an unknown category", function()
		for category in pairs(DEBUG_TAGS) do
			assert.is_not_nil(DEBUG_CATEGORY[category],
				"DEBUG_TAGS has a block for '" .. category .. "', which is not a DEBUG_CATEGORY")
		end
	end)

	it("registers a description for every comm prefix sent by the addon", function()
		local seen = {}
		for _, path in ipairs(sourceFiles()) do
			for prefix in readFile(path):gmatch('"(togbank%-[%a%d]+)"') do seen[prefix] = path end
		end
		assert.truthy(next(seen), "found no togbank- prefixes in the source; the scan is broken")
		for prefix, path in pairs(seen) do
			assert.is_not_nil(COMM_PREFIX_DESCRIPTIONS[prefix],
				"comm prefix '" .. prefix .. "' (used in " .. path ..
				") is missing from COMM_PREFIX_DESCRIPTIONS — the SEND log will print (Unknown)")
		end
	end)

	-- DEBUG-001. An unregistered tag is not a cosmetic problem: Output:Debug falls through to
	-- the category-only branch, the tag becomes the format string, and the real format string
	-- is printed as a literal argument alongside a raw %d.
	it("uses only registered category+tag pairs in Debug calls", function()
		local bad = {}
		for _, path in ipairs(sourceFiles()) do
			for lineNo, line in codeLines(readFile(path)) do
				local category, tag = line:match(':Debug%(%s*"([%u%d_%-]+)"%s*,%s*"([%u%d_%-]+)"')
				if category then
					if not DEBUG_CATEGORY[category] then
						bad[#bad + 1] = string.format("%s:%d  '%s' is not a DEBUG_CATEGORY", path, lineNo, category)
					elseif not (DEBUG_TAGS[category] and DEBUG_TAGS[category][tag]) then
						bad[#bad + 1] = string.format("%s:%d  '%s' is not a registered DEBUG_TAGS.%s tag",
							path, lineNo, tag, category)
					end
				end
			end
		end
		assert.same({}, bad,
			"unregistered debug category/tag pairs produce garbled output (audit DEBUG-001)")
	end)

	-- Separate check: a bare Debug("SYSTEM", fmt, ...) where SYSTEM isn't a category at all.
	-- Caught by the scan above only when arg 2 is also all-caps, so it gets its own pass.
	it("passes a real DEBUG_CATEGORY as the first argument of every Debug call", function()
		local bad = {}
		for _, path in ipairs(sourceFiles()) do
			for lineNo, line in codeLines(readFile(path)) do
				local category = line:match(':Debug%(%s*"([%u][%u%d_]+)"%s*,')
				-- An all-caps first argument is unambiguously intended as a category.
				if category and not DEBUG_CATEGORY[category] then
					bad[#bad + 1] = string.format("%s:%d  '%s' is not a DEBUG_CATEGORY", path, lineNo, category)
				end
			end
		end
		assert.same({}, bad, "Debug() called with a category that does not exist (audit DEBUG-001)")
	end)
end)
