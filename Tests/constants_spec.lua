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

local function readFile(path)
	local fh = io.open(path, "rb")
	if not fh then return "" end
	local src = fh:read("*a")
	fh:close()
	if src:sub(1, 3) == "\239\187\191" then src = src:sub(4) end   -- tolerate a BOM
	return src
end

-- Iterate real code lines, skipping `--` comments. Without this the scans below trip over
-- Output.lua's own doc header, which spells out the signature as Debug("CATEGORY", "TAG", ...).
local function codeLines(src)
	local n = 0
	return coroutine.wrap(function()
		for line in (src .. "\n"):gmatch("([^\n]*)\n") do
			n = n + 1
			if not line:match("^%s*%-%-") then coroutine.yield(n, line) end
		end
	end)
end

describe("Constants", function()
	before_each(function()
		env.reset()
		env.loadFile("Modules/Constants.lua")
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
