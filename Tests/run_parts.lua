-- FORWARD-PARTS-001: the one file discovery + slicing shared by Tests/run_forward.lua and
-- Tests/run_reverse.lua. It builds the spec list the way run.lua discovers it (same roots, same
-- exclusion), sorts it, optionally reverses it, cuts slice <part> of <parts>, and hands that slice
-- to run.lua as its argument list. It does not re-implement the runner.
--
-- WHY a shared file: the forward parts used to be writ suites listing their spec files by hand, and
-- every new spec file had to be added to one of them or it silently did not run in a split forward
-- run (Peer Review e1e13df8: mailcoverage, requestlogcoverage and localefill were in none). Slices
-- cut from the sorted glob find a new file by themselves, the way the reverse parts always have.
--
-- KNOWN COST (Peer Review 29bd8fac): the discovery below is a COPY of run.lua's local discover()
-- (Tests/wowapi/run.lua:737-756), which is not exported, so a harness change to discovery does not
-- reach this file. It also sorts, and the whole forward run does not (run.lua sorts only under
-- --order), so a forward slice's file order can differ from the whole run's; the union is the same.
--
-- run(opts): opts.reverse (boolean), opts.name (for the usage line and the banner), opts.flags
-- (run.lua flags placed before any the caller passes). Reads _G.arg: [<part> <parts> [flags...]].
local M = {}

function M.run(opts)
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

	local all = files
	if opts.reverse then
		all = {}
		for i = #files, 1, -1 do all[#all + 1] = files[i] end
	end
	local first, last = 1, #all
	if part and parts then
		assert(parts >= 1 and part >= 1 and part <= parts and part % 1 == 0 and parts % 1 == 0,
			"usage: lua Tests/" .. opts.name .. ".lua [<part> <parts>]")
		first = math.floor((part - 1) * #all / parts) + 1
		last = math.floor(part * #all / parts)
	end

	local runArgs = { [0] = "Tests/wowapi/run.lua" }
	for _, f in ipairs(opts.flags or {}) do runArgs[#runArgs + 1] = f end
	-- Anything after <part> <parts> is handed to run.lua as a flag (--times, --timeout=N), so a slice
	-- can be measured without re-listing its files by hand. run.lua reads flags anywhere in its
	-- argument list, so a later --timeout overrides the default above.
	for i = 3, #(arg or {}) do runArgs[#runArgs + 1] = arg[i] end
	local nflags = #runArgs
	for i = first, last do runArgs[#runArgs + 1] = all[i] end
	io.write(("%s: %d of %d spec file(s), %s (%d..%d)\n"):format(opts.name, #runArgs - nflags, #all,
		opts.reverse and "z to a" or "a to z", first, last))
	_G.arg = runArgs
	assert(loadfile("Tests/wowapi/run.lua"))()
end

return M
