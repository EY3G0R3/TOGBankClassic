-- The test stand-ins for TOGBankClassic_Core must MATCH the real one -- not merely be no looser.
--
-- AUDIT-S1 FOLLOW-ON, from peer review of v1.4.0. Two independent test surfaces (env.coreHashStub
-- and canonhash_spec's hand-rolled table) both installed a `ComputeCanonHash` method on Core. The
-- real Core has no such method: the canon is minted at ONE production site inside
-- DeltaComms:StampInventoryHashes, and Core fronts exactly three hash methods. So the test surface
-- was WIDER than production -- CMD-001 with the sign reversed. CMD-001 was a stub LOOSER than the
-- real function letting broken code pass; this is a stub WIDER than the real object letting
-- correct-looking code pass that would be "attempt to call a nil value" in the client. Both files
-- understood the class as "must not be looser"; the invariant is "must match".
--
-- And it was the configuration where nothing goes red: the two test surfaces agreed with each
-- other and disagreed with production. This file is what makes that disagreement visible.
--
-- THE REAL SURFACE, read from source rather than assumed: every `function TOGBankClassic_Core:X`
-- in Core.lua, plus the mixin lists the six Ace libraries embed onto the addon object -- read from
-- the sibling Ace3 install, which is the exact code that ships. A stand-in may install a SUBSET of
-- that; it may never install a name outside it.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

--- Method names Core.lua defines on the addon object.
local function coreMethods()
	local names = {}
	for name in env.readFile("Core.lua"):gmatch("function%s+TOGBankClassic_Core[:%.]([%w_]+)") do
		names[name] = "Core.lua"
	end
	return names
end

--- Method names an Ace library's `local mixins = { ... }` block embeds. Handles both the string-list
--- shape (`"RegisterComm",`) and AceAddon's keyed shape (`NewModule = NewModule,`).
local function aceMixins(path)
	local src = env.readFile(path)
	local block = src:match("\nlocal mixins%s*=%s*{(.-)\n}")
	local names = {}
	if block then
		for name in block:gmatch('"([%w_]+)"') do names[name] = path end
		for name in block:gmatch("\n%s*([%w_]+)%s*=") do names[name] = path end
	end
	return names
end

local ACE = {
	"../Ace3/AceAddon-3.0/AceAddon-3.0.lua",
	"../Ace3/AceComm-3.0/AceComm-3.0.lua",
	"../Ace3/AceConsole-3.0/AceConsole-3.0.lua",
	"../Ace3/AceEvent-3.0/AceEvent-3.0.lua",
	"../Ace3/AceSerializer-3.0/AceSerializer-3.0.lua",
	"../Ace3/AceTimer-3.0/AceTimer-3.0.lua",
}

local function realSurface()
	local names = coreMethods()
	for _, path in ipairs(ACE) do
		for name, where in pairs(aceMixins(path)) do names[name] = where end
	end
	return names
end

--- Every spec file in Tests/ (not the harness submodule).
local function specFiles()
	local files = {}
	local sep = package.config:sub(1, 1)
	local cmd = (sep == "\\")
		and 'dir /b "Tests\\*_spec.lua" 2>nul'
		or  'ls Tests/*_spec.lua 2>/dev/null'
	local p = io.popen(cmd)
	if p then
		for line in p:lines() do
			line = line:gsub("%s+$", ""):gsub("^Tests[/\\]", "")
			if line ~= "" then files[#files + 1] = "Tests/" .. line end
		end
		p:close()
	end
	return files
end

--- Method names a spec installs on a HAND-ROLLED `TOGBankClassic_Core = {` table, by reading the
--- one-key-per-line shape every such table in this suite uses.
local function handRolledMethods(path)
	local found = {}
	local inTable = false
	for lineNo, line in env.codeLines(env.readFile(path)) do
		if line:match("^%s*TOGBankClassic_Core%s*=%s*{%s*$") then
			inTable = true
		elseif inTable then
			if line:match("^%s*}") then
				inTable = false
			else
				local name = line:match("^%s*([%w_]+)%s*=")
				if name then found[#found + 1] = { name = name, line = lineNo } end
			end
		end
	end
	return found
end

describe("TOGBankClassic_Core stand-ins match the real surface", function()
	local real

	before_each(function()
		env.reset()
		real = realSurface()
	end)

	-- ANTI-VACUOUS. Everything below compares against `real`; if it is empty or tiny, every
	-- assertion passes over nothing. Pin a few names that are known to be there.
	it("reads the real surface at all", function()
		assert.is_not_nil(real.StampInventoryHashes, "Core.lua's own methods were not read")
		assert.is_not_nil(real.SendCommMessage, "AceComm's mixins were not read from the sibling install")
		assert.is_not_nil(real.GetArgs, "AceConsole's mixins were not read")
		assert.is_not_nil(real.ScheduleTimer, "AceTimer's mixins were not read")
		assert.is_not_nil(real.NewModule, "AceAddon's keyed mixin table was not read")
	end)

	it("env.coreHashStub installs nothing the real Core lacks", function()
		local stub, extras = env.coreHashStub(1), {}
		for name in pairs(stub) do
			if not real[name] then extras[#extras + 1] = name end
		end
		table.sort(extras)
		assert.same({}, extras,
			"coreHashStub carries methods the real Core does not have -- a stand-in WIDER than " ..
			"production lets code that cannot run in the client pass every spec (AUDIT-S1)")
	end)

	it("env.stubCore installs nothing the real Core lacks", function()
		TOGBankClassic_Core = nil
		local stub, extras = env.stubCore(), {}
		for name in pairs(stub) do
			if not real[name] then extras[#extras + 1] = name end
		end
		table.sort(extras)
		assert.same({}, extras, "stubCore carries methods the real Core does not have (AUDIT-S1)")
	end)

	-- CMD-001 FOLLOW-UP: the name being present is not the contract. stubCore's GetArgs used to be
	-- a local re-implementation that dropped the third parameter (startpos, how a caller continues
	-- from nextposition) and split on any whitespace where AceConsole splits on the space character
	-- and honours quotes. It is now the installed library; these two inputs are the ones the
	-- re-implementation got wrong, so they go red if anyone stands a copy in again.
	it("env.stubCore's GetArgs IS AceConsole's: quotes and startpos behave as in the client", function()
		TOGBankClassic_Core = nil
		local stub = env.stubCore()
		local a, b, nextpos = stub:GetArgs('dev "two words" tail', 2)
		assert.equal("dev", a)
		assert.equal("two words", b, "a quoted argument was split on its space")
		assert.equal("tail", (stub:GetArgs('dev "two words" tail', 1, nextpos)), "startpos was ignored")
		local x, y = stub:GetArgs("a\tb", 2)
		assert.equal("a\tb", x, "AceConsole splits on the space character only; a tab is part of the token")
		assert.is_nil(y)
	end)

	describe("hand-rolled Core tables in spec files", function()
		local files, tables

		before_each(function()
			files, tables = specFiles(), {}
			for _, path in ipairs(files) do
				local methods = handRolledMethods(path)
				if #methods > 0 then tables[path] = methods end
			end
		end)

		-- ANTI-VACUOUS. The scan is a pattern over source text; a pattern that matches nothing
		-- passes every assertion built on it. Five files are known to hand-roll a table.
		it("finds the hand-rolled tables at all", function()
			assert.is_true(#files >= 20, "spec file listing came back short: " .. #files)
			local n = 0
			for _ in pairs(tables) do n = n + 1 end
			assert.is_true(n >= 4,
				"found only " .. n .. " hand-rolled Core tables -- the scan is broken, not the suite")
			assert.is_not_nil(tables["Tests/canonhash_spec.lua"],
				"canonhash_spec's table was not read, and it is the one this finding came from")
		end)

		it("install nothing the real Core lacks", function()
			local extras = {}
			for path, methods in pairs(tables) do
				for _, m in ipairs(methods) do
					if not real[m.name] then
						extras[#extras + 1] = string.format("%s:%d %s", path, m.line, m.name)
					end
				end
			end
			table.sort(extras)
			assert.same({}, extras,
				"these spec tables put methods on Core that the real Core does not have. A stand-in " ..
				"WIDER than production is CMD-001 with the sign reversed: correct-looking production " ..
				"code calling one of these passes every spec and is 'attempt to call a nil value' in " ..
				"the client. Call the owning module directly instead (AUDIT-S1).")
		end)
	end)
end)
