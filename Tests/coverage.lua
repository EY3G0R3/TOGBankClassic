-- coverage.lua — exact line coverage for a single Lua file, with no dependencies.
--
--     lua Tests/coverage.lua <target.lua> [spec files...]
--
-- Why not a heuristic: the usual "strip blanks and comments, call the rest
-- executable" approach miscounts `end`, multi-line calls, and table literals,
-- so a run can report 100% while real branches are unexecuted, or report
-- misses on lines that can never be hit. Both make the number worthless.
--
-- Instead the executable-line set is read from the DEBUG INFO the Lua 5.1
-- compiler emits: string.dump() the loaded chunk and walk every nested function
-- prototype's `lineinfo` array (one entry per VM instruction, giving the source
-- line it came from). That set is exactly "lines that can execute" by
-- construction. Executed lines are then collected with a debug line hook and
-- the two are differenced.
--
-- This is generic (nothing GuildRoster-specific) and is a candidate to move
-- into the WoWAPITesting harness alongside run.lua — see Tests/HARNESS_CONTRACT.md.
---@diagnostic disable: lowercase-global, undefined-global
-- luacheck: std lua51

local target = arg[1]
if not target then
	io.write("usage: lua Tests/coverage.lua <target.lua> [spec files...]\n")
	os.exit(2)
end

-- ---------------------------------------------------------------------------
-- Lua 5.1 bytecode reader — just enough to reach every prototype's lineinfo
-- ---------------------------------------------------------------------------
local function newReader(bytes)
	local pos = 1
	local R = {}
	function R.bytes(n)
		local s = bytes:sub(pos, pos + n - 1)
		pos = pos + n
		return s
	end
	function R.byte() return bytes:byte(pos), R.bytes(1) end
	R.sizeInt, R.sizeT = 4, 4
	-- Little-endian unsigned integer of `n` bytes.
	function R.uint(n)
		local s = R.bytes(n)
		local v = 0
		for i = n, 1, -1 do v = v * 256 + s:byte(i) end
		return v
	end
	function R.int() return R.uint(R.sizeInt) end
	function R.string()
		local len = R.uint(R.sizeT)
		if len == 0 then return "" end
		return R.bytes(len):sub(1, -2)   -- drop the trailing \0
	end
	return R
end

-- Lua 5.1 opcode 22 = OP_JMP (the opcode is the low 6 bits of the instruction).
--
-- A line whose instructions are ALL jumps is not observable by a line hook: the
-- jump hands control to another line, and the hook reports the destination, not
-- the jump itself. The `end` closing a loop body's final `if` is the common case
-- — it carries the loop's back-edge and nothing else. Verified empirically: a
-- three-iteration loop reports lines 3/4/5 and never the `end` on line 6, even
-- though line 6 has a lineinfo entry.
--
-- Counting those lines as "executable" makes 100% unreachable and quietly turns
-- the metric into noise, so they are excluded rather than perpetually reported
-- as misses.
local OP_JMP = 22

-- Collect the union of every prototype's lineinfo entries.
local function executableLines(chunk)
	local dump = string.dump(chunk)
	local R = newReader(dump)

	R.bytes(4)                       -- signature "\27Lua"
	local version = R.uint(1)
	assert(version == 0x51, ("unsupported bytecode version 0x%x (expected 0x51)"):format(version))
	R.uint(1)                        -- format
	R.uint(1)                        -- endianness (little assumed; Lua on all our targets is LE)
	R.sizeInt = R.uint(1)
	R.sizeT   = R.uint(1)
	local sizeInstr  = R.uint(1)
	local sizeNumber = R.uint(1)
	R.uint(1)                        -- integral flag

	-- line -> true once the line owns at least one non-JMP instruction
	local lines = {}

	local function readFunction()
		R.string()                   -- source
		R.int()                      -- linedefined
		R.int()                      -- lastlinedefined
		R.uint(1)                    -- nups
		R.uint(1)                    -- numparams
		R.uint(1)                    -- is_vararg
		R.uint(1)                    -- maxstacksize

		-- Keep each instruction's opcode: lineinfo[i] pairs with code[i], and
		-- the opcode is what tells us whether the line is hook-observable.
		local nCode = R.int()
		local opcodes = {}
		for i = 1, nCode do
			opcodes[i] = R.uint(sizeInstr) % 64   -- low 6 bits
		end

		local nConst = R.int()
		for _ = 1, nConst do
			local t = R.uint(1)
			if t == 1 then R.uint(1)              -- boolean
			elseif t == 3 then R.bytes(sizeNumber) -- number
			elseif t == 4 then R.string() end      -- string ("0 == nil" reads nothing)
		end

		local nProto = R.int()
		for _ = 1, nProto do readFunction() end   -- nested functions

		local nLines = R.int()
		for i = 1, nLines do
			local ln = R.int()
			-- Only a non-JMP instruction makes the line observable; a line that
			-- owns nothing but jumps stays out of the executable set entirely.
			if ln > 0 and opcodes[i] ~= OP_JMP then lines[ln] = true end
		end

		local nLocals = R.int()
		for _ = 1, nLocals do R.string(); R.int(); R.int() end

		local nUp = R.int()
		for _ = 1, nUp do R.string() end
	end

	readFunction()
	return lines
end

-- ---------------------------------------------------------------------------
-- Measure
-- ---------------------------------------------------------------------------
local targetChunk = assert(loadfile(target))
local executable  = executableLines(targetChunk)

-- Match the hook's reported source against the target regardless of how the
-- path was spelled at load time (./Foo.lua vs Foo.lua vs an absolute path).
local basename = target:match("([^/\\]+)$")
local executed = {}

debug.sethook(function(_, line)
	local info = debug.getinfo(2, "S")
	if info and info.source and info.source:sub(-#basename) == basename then
		executed[line] = true
	end
end, "l")

-- Run the specs via the harness runner, which os.exit()s when done; intercept
-- that so the report still prints, and keep its exit status.
local realExit, specStatus = os.exit, 0
os.exit = function(code) specStatus = code or 0; error("__coverage_exit__", 0) end

local specs = {}
for i = 2, #arg do specs[#specs + 1] = arg[i] end

local runner = "Tests/wowapi/run.lua"
local ok, err = pcall(function()
	local chunk = assert(loadfile(runner))
	local saved = arg
	arg = specs
	arg[0] = runner
	chunk()
	arg = saved
end)

debug.sethook()
os.exit = realExit

if not ok and err ~= "__coverage_exit__" then
	io.write("coverage: spec run failed: " .. tostring(err) .. "\n")
	realExit(1)
end

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------
local total, hit, missed = 0, 0, {}
for line in pairs(executable) do
	total = total + 1
	if executed[line] then hit = hit + 1 else missed[#missed + 1] = line end
end
table.sort(missed)

local srcLines = {}
do
	local f = assert(io.open(target, "r"))
	for l in f:lines() do srcLines[#srcLines + 1] = l end
	f:close()
end

io.write(("\n=== Coverage: %s ===\n"):format(target))
if #missed > 0 then
	io.write(("Uncovered lines (%d):\n"):format(#missed))
	for _, l in ipairs(missed) do
		io.write(("  %4d | %s\n"):format(l, (srcLines[l] or ""):gsub("^%s+", "")))
	end
end
io.write(("\n%d/%d executable lines covered (%.2f%%)\n"):format(
	hit, total, total > 0 and (hit / total * 100) or 100))

-- Fail the run if the specs failed OR coverage is short of 100%.
realExit((specStatus == 0 and #missed == 0) and 0 or 1)
