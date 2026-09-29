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
--
-- REVERSE-GATE-001: `lua Tests/run_reverse.lua <part> <parts>` runs one contiguous slice of the
-- reversed list (part 1 is the z end). The whole run outgrew the desk's 15-minute budget on
-- 2026-09-25, as the forward run had; the slices are declared as writ suites "reverse 1/3" .. "3/3".
-- KNOWN COST: an order dependency that crosses a slice boundary is not seen -- the same trade the
-- forward split makes. No arguments still runs the whole list.
local part, parts = tonumber(arg and arg[1]), tonumber(arg and arg[2])
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

local all = {}
for i = #files, 1, -1 do all[#all + 1] = files[i] end
local first, last = 1, #all
if part and parts then
	assert(parts >= 1 and part >= 1 and part <= parts and part % 1 == 0 and parts % 1 == 0,
		"usage: lua Tests/run_reverse.lua [<part> <parts>]")
	first = math.floor((part - 1) * #all / parts) + 1
	last = math.floor(part * #all / parts)
end
-- REVERSE-TIMEOUT-001: the harness's per-file limit (60 s CPU, from pin e6b42c3) is too short for
-- the a-end slice. Every frames.reset() runs a full collect over whatever earlier files left alive,
-- and by browse_spec that is ~450 MB and ~150k frames, so a file that takes 9 s alone took 97 s
-- there (measured 2026-09-29, --times; all 696 passed with the limit raised). 240 s leaves room
-- under the desk's 15-minute budget and still stops a real hang. KNOWN COST: a file that slows
-- down in this order is caught at 240 s, not 60. The retention itself is SUITE-HEAP-001's.
local reversed = { [0] = "Tests/wowapi/run.lua", "--timeout=240" }
-- Anything after <part> <parts> is handed to run.lua as a flag (--times, --timeout=N), so a slice
-- can be measured without re-listing its files by hand.
for i = 3, #(arg or {}) do reversed[#reversed + 1] = arg[i] end
local nflags = #reversed
for i = first, last do reversed[#reversed + 1] = all[i] end
io.write(("run_reverse: %d of %d spec file(s), z to a (%d..%d)\n"):format(#reversed - nflags, #all, first, last))
_G.arg = reversed
assert(loadfile("Tests/wowapi/run.lua"))()
