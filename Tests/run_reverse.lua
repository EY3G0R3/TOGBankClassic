-- SPEC-ORDER-001: the whole suite in REVERSE file order, one Lua state, as run.lua runs it.
--
--   lua Tests/run_reverse.lua        (from the addon root; writ suite "reverse-order")
--
-- WHY. The runner walks the spec files alphabetically in ONE Lua state, and a file that leaves a
-- global behind (an addon module, a stubbed frame, a library registration) hands it to every file
-- after it. A spec that passes only on what an earlier file left is order-dependent, and the
-- forward run cannot see that: on 2026-09-15 the suite was 1811/0 forwards and 1775/36 backwards,
-- every one of the 36 passing alone. The alphabet was the fixture. Backwards is not a proof of
-- independence either -- it is one more order -- but it is the cheapest one that catches the
-- common shape, "the file that sets this up happens to sort first".
--
-- This does not re-implement the runner: it builds the reversed list the way run.lua discovers
-- it (same roots, same exclusion) and hands it to run.lua as its argument list.
package.path = "./Tests/wowapi/?.lua;" .. package.path
local paths = require("runner_paths")
local sep = package.config:sub(1, 1)

local files = {}
for _, r in ipairs(paths.ROOTS) do
	local cmd
	if sep == "\\" then
		cmd = 'dir /b /s "' .. r .. '\\*_spec.lua" 2>nul'
	else
		cmd = 'find "' .. r .. '" -name "*_spec.lua" 2>/dev/null'
	end
	local p = io.popen(cmd)
	if p then
		for line in p:lines() do
			line = line:gsub("%s+$", "")
			if line ~= "" and not paths.isExcluded(line) then files[#files + 1] = line end
		end
		p:close()
	end
end
table.sort(files)

local reversed = { [0] = "Tests/wowapi/run.lua" }
for i = #files, 1, -1 do reversed[#reversed + 1] = files[i] end
io.write("run_reverse: " .. #files .. " spec file(s), z to a\n")
_G.arg = reversed
assert(loadfile("Tests/wowapi/run.lua"))()
