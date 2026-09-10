-- TIMER-001 across the whole addon, not just the file that had specs.
--
-- WHY THIS FILE EXISTS, because the history is the justification:
--
-- TIMER-001 was filed against four files. The specs for it only ever exercised P2PSession.lua, so
-- that file was fixed, the suite went green, and the finding was treated as closed -- while
-- Chat.lua and Guild.lua still assigned C_Timer.After to a handle and stored it to cancel later.
-- An outside review caught it (docs/AUDIT.md finding 24) and named the real cost: a fix applied to
-- one file of four converts an open finding into a closed-looking one.
--
-- The behavioural specs live with their modules. This file is the CLASS guard: it reads the
-- shipped source and asserts the defect's SHAPE cannot reappear anywhere, including in a file
-- nobody has written a behavioural spec for yet. That is deliberate -- the gap that let this
-- happen was a file with no specs, so a guard that only covers files with specs would not have
-- caught it either.
--
-- THE DEFECT'S SHAPE, stated precisely, because the obvious description sends a fixer to the wrong
-- line. It is NOT "the :Cancel() is a no-op". C_Timer.After returns NOTHING, so the assignment
-- stores nil -- and a Lua table cannot hold a nil value, so the registry key is never created.
-- Every `if registry[key] then ... :Cancel()` guard is then permanently false and the registry is
-- permanently empty. Fixing the cancel call would change nothing; the assignment is the bug.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function readFile(path)
	local fh = assert(io.open(path, "rb"), "cannot read " .. path)
	local src = fh:read("*a")
	fh:close()
	return src
end

-- WHY THE LIST IS DERIVED AND NOT WRITTEN OUT:
--
-- This file's first version listed "every module that schedules anything" by hand, on the argument
-- that an explicit list makes inclusion a deliberate decision. It missed two schedulers --
-- Modules/Database.lua (C_Timer.After at :47 and :338) and Modules/UI/StatusBar.lua
-- (C_Timer.NewTicker at :414) -- because the list was compiled from the files the audit happened to
-- name. That is the SAME defect this file guards against: a check whose coverage looks complete and
-- is not, so a clean run proves less than it appears to.
--
-- The shipped file set already exists, in the .toc, and it is the one list that cannot silently omit
-- a module: a file missing from it does not load in game. So the guard reads it. A new module is
-- covered the moment it ships, with no second list to remember.
--
-- The reader itself moved to env.shippedModules() when constantprose_spec (DOC-004) needed the same
-- set: two copies of "which files does this addon ship" is the very drift these guards exist to
-- catch, and only one of them would ever get updated.
local MODULES = env.shippedModules()

--- Lines assigning C_Timer.After's return to something, which is always wrong: it returns nothing.
--- Returns a list of "path:line: text" so a failure names the site rather than just counting.
local function capturedAfterCalls(path)
	local hits = {}
	local n = 0
	for line in (readFile(path) .. "\n"):gmatch("([^\n]*)\n") do
		n = n + 1
		-- `local x = C_Timer.After(` or `something.x = C_Timer.After(` or `x = C_Timer.After(`.
		-- An UNassigned `C_Timer.After(...)` is fire-and-forget and entirely correct, so the
		-- test is the assignment, never the call.
		if line:find("=%s*C_Timer%.After%s*%(") then
			hits[#hits + 1] = string.format("%s:%d:%s", path, n, (line:gsub("^%s+", "")))
		end
	end
	return hits
end

describe("TIMER-001 as a class, across every scheduling module", function()
	-- The sweep below iterates MODULES. If the .toc parse ever returns an empty or truncated list,
	-- every assertion in this file passes without reading a line of source -- a guard that cannot
	-- fail, which is the failure this whole board has been finding all day. So the list itself is
	-- pinned before anything trusts it.
	it("derives the shipped file set from the .toc rather than a hand-written list", function()
		assert.is_true(#MODULES > 25,
			"the .toc parse produced only " .. #MODULES .. " files, so the sweep below would be " ..
			"reading almost nothing while still reporting green")

		local seen = {}
		for _, path in ipairs(MODULES) do seen[path] = true end

		-- The three the audit named, and the two the hand-written list missed. If the parse regressed
		-- in a way the count above tolerates, these are the files whose absence actually costs.
		for _, path in ipairs({
			"Modules/Chat.lua", "Modules/Guild.lua", "Modules/P2PSession.lua",
			"Modules/Database.lua", "Modules/UI/StatusBar.lua", "Core.lua",
		}) do
			assert.is_true(seen[path] == true,
				path .. " is shipped in TOGBankClassic.toc but did not survive the parse, so it is " ..
					"not " ..
				"being swept (Database.lua and UI/StatusBar.lua are the two the hand-written list " ..
				"omitted -- they are named here so the same omission cannot recur silently)")
		end

		assert.is_nil(seen["Libs/LibDataBroker-1.1/LibDataBroker-1.1.lua"],
			"vendored libraries are deliberately out of scope -- see the comment on shippedModules")
	end)

	-- The assertion is on the ASSIGNMENT, not on `:Cancel()`. See the header: the cancel site is
	-- downstream of the defect and fixing it changes nothing.
	it("never captures the return of C_Timer.After", function()
		local offenders = {}
		for _, path in ipairs(MODULES) do
			for _, hit in ipairs(capturedAfterCalls(path)) do
				offenders[#offenders + 1] = hit
			end
		end
		assert.equal(0, #offenders,
			"C_Timer.After returns NOTHING, so each of these stores nil. If the value is put in a " ..
			"cancellation registry the key is never created, every `if registry[k] then` guard is " ..
			"permanently false, and the cancel silently never happens -- indistinguishable from a " ..
			"cancel that works. Use C_Timer.NewTimer when the handle is kept, or do not assign it " ..
			"at all when the timer is fire-and-forget (audit TIMER-001, docs/AUDIT.md finding 24)." ..
			"\n    " .. table.concat(offenders, "\n    "))
	end)

	-- The three sites finding 24 named, pinned individually. The sweep above would catch them, but
	-- a named assertion is what tells the next reader these were the regression, not a hypothetical.
	--
	-- P2P-026 UPDATED THE SHAPE THIS LOOKS FOR, and deliberately rather than to make a red example
	-- green: all three sites now arm through Guild:ArmAltTimeout, which holds the single
	-- C_Timer.NewTimer call and cancels whatever the alt already had in flight. That is a STRONGER
	-- invariant than "each site uses NewTimer" -- NewTimer alone only fixed the path where a peer
	-- ACKs, because the second of two requests overwrote the first's handle and orphaned it. The
	-- behaviour is driven in Tests/p2ptimeout_spec.lua; this pins the shape so a hand-written
	-- arm site cannot quietly reappear beside the helper.
	it("arms the three sites audit finding 24 named through ArmAltTimeout", function()
		local chat  = readFile("Modules/Chat.lua")
		local guild = readFile("Modules/Guild.lua")

		assert.is_not_nil(chat:find('ArmAltTimeout%("pendingP2PTimeouts", norm, 5,'),
			"Chat.lua's 5s peer timeout must arm through the helper: without the replace-and-cancel " ..
			"it does, a second request for the same alt inside the window is torn down by the FIRST " ..
			"request's orphaned timer")
		assert.is_not_nil(chat:find('ArmAltTimeout%("pendingP2PFallbackTimeouts", norm, 15,'),
			"Chat.lua's 15s ACK fallback must arm through the helper. This is the worse of the two " ..
			"-- 15s is a long window and its callback calls AdvanceCandidate on whatever session " ..
			"owns the alt when it fires, which need not be the session it was armed for")
		assert.is_not_nil(guild:find('ArmAltTimeout%("pendingP2PTimeouts", norm, timeout,'),
			"Guild.lua's PEER_RESPONSE_TIMEOUT must arm through the helper")

		assert.is_not_nil(guild:find("local timer = C_Timer%.NewTimer%(delay, callback%)"),
			"ArmAltTimeout itself must use NewTimer -- it is now the ONLY place these three sites " ..
			"get a handle from, so an After here would re-empty both registries at a stroke")
	end)

	-- The registries the finding is really about. Both are declared as cancellation registries and
	-- were permanently empty; this asserts nothing writes an un-cancellable value into them again.
	it("only stores cancellable handles in the P2P timeout registries", function()
		for _, path in ipairs({ "Modules/Chat.lua", "Modules/Guild.lua" }) do
			local src = readFile(path)
			for registry in ("pendingP2PTimeouts pendingP2PFallbackTimeouts"):gmatch("%S+") do
				-- Any assignment INTO the registry whose right-hand side is a direct After call.
				assert.is_nil(src:find(registry .. "%[[%w_]+%]%s*=%s*C_Timer%.After"),
					path .. " writes C_Timer.After's nil return straight into " .. registry ..
					", so the key is never created and the registry stays empty (TIMER-001)")
			end
		end
	end)
end)
