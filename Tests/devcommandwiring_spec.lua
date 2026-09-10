-- CMD-002: a dev command must be registered in TWO places, and registering it in only one FAILS
-- SILENTLY IN THE MOST MISLEADING WAY AVAILABLE.
--
-- `Modules/Chat.lua` holds a single `COMMAND_REGISTRY` of every command, and a separate
-- `DEV_COMMAND_NAMES` set naming which of them live under `/togbank dev`. The dispatch loop sorts
-- every registry entry into one bucket or the other -- so a command present in the registry and
-- ABSENT from the names set does not fail to register. It registers as a TOP-LEVEL command.
-- `/togbank dev <name>` then answers "not a valid command" while `/togbank <name>` quietly works,
-- which reads as the command not existing at all rather than as being filed in the wrong drawer.
--
-- Cost one round trip with the operator on 2026-09-10, on `dev bandwidth`. This is the "one
-- concept, two places, nothing asserting they agree" shape the audit board already names as a
-- cross-cutting class -- so the guard is against the DOCUMENTED contract, which is the third copy
-- and the one a user actually reads.
--
-- A SOURCE-TEXT GUARD, DELIBERATELY. Both dispatch tables are file-locals and unreachable from a
-- spec, and the alternative -- driving each `/togbank dev <name>` and checking it is accepted --
-- would EXECUTE them. `dev wipeall` resets the database for the whole guild. Reading the source is
-- the only way to check this that is not itself dangerous.
package.path = "./Tests/?.lua;" .. package.path
require("env_togbank")

local CHAT_LUA = "Modules/Chat.lua"
local DOC_MD   = "docs/DEV_COMMANDS.md"

local function readFile(path)
	local fh = assert(io.open(path, "rb"), "cannot read " .. path)
	local src = fh:read("*a")
	fh:close()
	return src
end

--- The names inside the `DEV_COMMAND_NAMES = { ... }` table.
local function devCommandNames()
	local src = readFile(CHAT_LUA)
	local block = src:match("local DEV_COMMAND_NAMES = (%b{})")
	assert(block, "could not find the DEV_COMMAND_NAMES table in " .. CHAT_LUA ..
		" -- if it was renamed, this guard is now checking nothing and must be updated")
	local out = {}
	-- Two spellings appear in that table: bare `name = true` and `["quoted-name"] = true`.
	for name in block:gmatch("%[\"([%w%-_]+)\"%]%s*=%s*true") do out[name] = true end
	for name in block:gmatch("[\n{]%s*([%a_][%w_]*)%s*=%s*true") do out[name] = true end
	return out
end

--- Every command name declared in COMMAND_REGISTRY.
local function registryNames()
	local src = readFile(CHAT_LUA)
	local out = {}
	for name in src:gmatch("name%s*=%s*\"([%w%-_]+)\"") do out[name] = true end
	return out
end

--- Every `/togbank dev <name>` the documentation DEFINES as a command.
---
--- Matches only the list-item DEFINITION form and deliberately not every mention. Two rounds of
--- false positives shaped this pattern, and both are worth knowing before loosening it:
---
---   1. Prose mentions. `builddb` appeared in a paragraph explaining that command was REMOVED,
---      inside backticks, and `help` likewise. Restricting to list items fixed those.
---   2. REMOVAL NOTICES WRITTEN AS LIST ITEMS, which the first fix did not catch:
---      "- **`/togbank dev test` no longer exists**" has the exact shape of a definition and says
---      the opposite. The tell is what follows the closing backtick -- a definition closes
---      straight into `**`, a sentence about the command does not.
---
--- Hence `[^`\n]*` for an argument list (`switches [<name> on|off]`) followed by a backtick and
--- `**` with nothing between. A guard that cries wolf gets its complaints dismissed, which costs
--- more than the guard is worth, so it reports only what the document promises a user can run.
local function documentedDevCommands()
	local src = readFile(DOC_MD)
	local out = {}
	for name in src:gmatch("\n%-%s%*%*`/togbank dev ([%w%-_]+)[^`\n]*`%*%*") do out[name] = true end
	return out
end

describe("CMD-002: every documented dev command is actually wired as one", function()
	-- The guard proper. A command documented as `/togbank dev X` and missing from
	-- DEV_COMMAND_NAMES is reachable only as `/togbank X`, so the documentation is wrong about
	-- how to run it and the user is told it does not exist.
	it("declares every documented `/togbank dev` command in DEV_COMMAND_NAMES", function()
		local declared  = devCommandNames()
		local documented = documentedDevCommands()
		local missing = {}
		for name in pairs(documented) do
			if not declared[name] then missing[#missing + 1] = name end
		end
		table.sort(missing)
		assert.equal(0, #missing,
			"documented as `/togbank dev <name>` but absent from DEV_COMMAND_NAMES, so each " ..
			"registered as a TOP-LEVEL command and `/togbank dev <name>` reports 'not a valid " ..
			"command': " .. table.concat(missing, ", "))
	end)

	-- The other direction: a name in the set with no registry entry produces no handler at all,
	-- which is a command that exists in a list and nowhere else.
	it("has a COMMAND_REGISTRY entry behind every name in DEV_COMMAND_NAMES", function()
		local declared = devCommandNames()
		local registry = registryNames()
		local orphans = {}
		for name in pairs(declared) do
			if not registry[name] then orphans[#orphans + 1] = name end
		end
		table.sort(orphans)
		assert.equal(0, #orphans,
			"named in DEV_COMMAND_NAMES with no COMMAND_REGISTRY entry, so the name is filed as a " ..
			"dev command and no handler is ever bound to it: " .. table.concat(orphans, ", "))
	end)

	-- Proves the parsers actually found something. Without this, a rename of either table would
	-- make both examples above pass over an EMPTY set -- a guard that stops guarding and reports
	-- success, which is the failure mode this whole file exists to prevent one instance of.
	it("actually parsed both tables, so the guard cannot pass over nothing", function()
		local declared   = devCommandNames()
		local documented = documentedDevCommands()
		local n = 0
		for _ in pairs(declared) do n = n + 1 end
		assert.is_true(n >= 10,
			"parsed only " .. n .. " names out of DEV_COMMAND_NAMES -- the table's shape changed " ..
			"and this guard is now checking almost nothing")
		local d = 0
		for _ in pairs(documented) do d = d + 1 end
		assert.is_true(d >= 5,
			"parsed only " .. d .. " `/togbank dev` commands out of " .. DOC_MD ..
			" -- the documentation's shape changed and this guard is now checking almost nothing")
	end)

	-- The specific command this guard was written from, named so a regression is unambiguous.
	it("wires `dev bandwidth`, the command that exposed this class", function()
		assert.is_true(devCommandNames()["bandwidth"] == true,
			"`/togbank dev bandwidth` is not in DEV_COMMAND_NAMES -- it will register as " ..
			"`/togbank bandwidth` and the documented spelling will be refused (CMD-002)")
	end)
end)
