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

-- P2P-026 / P2P-027 AS A CLASS: a LIVE timer handle overwritten without being cancelled.
--
-- THIS IS A DIFFERENT DEFECT FROM TIMER-001 ABOVE, and the distinction is why this block exists.
-- TIMER-001 is "the handle was never real" (C_Timer.After returns nothing). This is "the handle was
-- real, and we dropped our only reference to it while it was still armed". Fixing TIMER-001 by
-- swapping to NewTimer is what MADE this one reachable: the handles became real, so overwriting one
-- became capable of losing a live timer instead of losing a nil.
--
-- IT HAS BITTEN TWICE, in one version -- P2P-026 (a repeated sync request aborted five seconds later
-- by the request it replaced) and P2P-027 (a retry cycle abandoning a sync that was already
-- succeeding). Both were found by hand-sweeping, twice, and a hand sweep is exactly what does not
-- survive the next edit.
--
-- THE FIVE SHAPES THAT ARE SAFE, all of which exist in this codebase today:
--   1. `:Cancel()` on the same slot immediately before  (P2PSession ArmSessionTimer)
--   2. a named stop method called first                 (UI/StatusBar StartTicker -> StopTicker)
--   3. a latch guard, `if not <slot> then`              (Chat hashBroadcastTimer)
--   4. a fresh `local` per call, self-cancelling        (Guild's player-name ticker)
--   5. unreachable while live, PROVEN and marked TIMER-SAFE with the reasoning  (P2PSession:154)
--
-- Shape 5 is the escape hatch and it is deliberately expensive: it costs a comment that has to say
-- WHY, and what would break it. A site that cannot justify itself in a sentence is a site that
-- should be cancelling.
describe("P2P-026/027 as a class: no live timer handle is overwritten", function()
	-- TWO SPELLINGS, BECAUSE THIS ADDON HAS TWO TIMER APIS. Watching only one is the enumeration
	-- mistake the audit item explicitly warned about: "the reviewer enumerated by PATTERN, which
	-- only finds the spellings thought of -- an aliased local, a wrapper, or AceTimer would not
	-- appear."
	--
	--   C_Timer.NewTimer / NewTicker  -- the client API. Both share the prefix `NewTi`.
	--   Core:ScheduleTimer            -- AceTimer, embedded on Core and used by four modules.
	--
	-- Lua patterns have no alternation, so these are two patterns rather than one. The first
	-- version of the C_Timer line tried to fake alternation with a character class and matched 2 of
	-- the 7 real sites, so the guard below passed while reading almost nothing. The anti-vacuous
	-- example at the bottom caught that on its first run.
	local ASSIGN_PATTERNS = {
		"([%w_%.%[%]\"']+)%s*=%s*C_Timer%.NewTi[%a]*%s*%(",
		"([%w_%.%[%]\"']+)%s*=%s*[%w_]+:ScheduleT[%a]*%s*%(",
	}

	--- Every line assigning a cancellable timer handle, as {line=, slot=, text=}.
	--- An UNassigned call is fire-and-forget and entirely correct -- the risk is only ever in
	--- holding a handle you might overwrite, so the test is the assignment, never the call.
	local function timerAssignments(path)
		local out, n = {}, 0
		local lines = {}
		for line in (readFile(path) .. "\n"):gmatch("([^\n]*)\n") do
			n = n + 1
			lines[n] = line
			for _, pat in ipairs(ASSIGN_PATTERNS) do
				local slot = line:match(pat)
				if slot then
					out[#out + 1] = { line = n, slot = slot, text = line }
					break
				end
			end
		end
		return out, lines
	end

	--- Is this assignment protected by one of the five safe shapes?
	local function isProtected(slot, lineNo, lines)
		-- The tail of the slot name: `self.collectTimer` -> `collectTimer`, `s.timers[name]` ->
		-- `timers`. Matching on the tail rather than the full expression is what lets a cancel
		-- written as `existing:Cancel()` count for an assignment to `s.timers[name]`.
		local tail = slot:match("([%w_]+)%s*$") or slot:match("([%w_]+)") or slot
		for i = math.max(1, lineNo - 10), lineNo do
			local L = lines[i]
			-- Shape 1, cancel-first. `Cancel[%w_]*%(` rather than `Cancel%(` because AceTimer
			-- spells it `CancelTimer(` -- the narrower pattern flagged Events.lua:168, which
			-- cancels three lines above, as unguarded.
			if L:find("Cancel[%w_]*%s*%(") then return true end
			-- Shape 2, a named stop method.
			if L:find(":Stop[%w_]*%s*%(") then return true end
			-- Shape 3, a latch. BOTH SPELLINGS: `if not X then <arm>` and the early-return
			-- `if X then return end`. Only the first was recognised at first, which flagged
			-- Chat.lua:3149 -- guarded by `if self.reprocessTimer then return end` three lines
			-- above. Requiring the slot name in the condition is what keeps this from matching
			-- any unrelated `if`.
			if L:find("if%s+not%s+[%w_%.%[%]]*" .. tail) then return true end
			if L:find("if%s+[%w_%.%[%]]*" .. tail .. "[%w_%.%[%]]*%s+then") then return true end
			-- Shape 4, a fresh local per call.
			if L:find("local%s+" .. tail) then return true end
			-- Shape 5, proven unreachable-while-live and justified in writing.
			if L:find("TIMER%-SAFE") then return true end
		end
		return false
	end

	it("guards every NewTimer/NewTicker assignment in every shipped module", function()
		local unguarded = {}
		for _, path in ipairs(MODULES) do
			local assigns, lines = timerAssignments(path)
			for _, a in ipairs(assigns) do
				if not isProtected(a.slot, a.line, lines) then
					unguarded[#unguarded + 1] = string.format("%s:%d: %s", path, a.line,
						(a.text:gsub("^%s+", "")))
				end
			end
		end
		assert.equal(0, #unguarded,
			"a live timer handle can be overwritten here without being cancelled, which is the " ..
			"P2P-026/027 class -- the old timer keeps running, fires into a state it does not " ..
			"belong to, and typically aborts work that was already succeeding. Cancel the slot " ..
			"first, or mark the site TIMER-SAFE with the reason it cannot be live:\n  " ..
			table.concat(unguarded, "\n  "))
	end)

	-- Anti-vacuous. If the pattern stops matching -- a rename, a formatting change, a new spelling
	-- of the call -- the example above passes while reading nothing, which is the exact failure
	-- this whole file was written about.
	it("actually finds the timer assignments, so the guard cannot pass over nothing", function()
		local total = 0
		for _, path in ipairs(MODULES) do
			total = total + #(timerAssignments(path))
		end
		assert.is_true(total >= 7,
			"found only " .. total .. " cancellable timer assignments across the shipped modules. " ..
			"There were 9 when this guard was written -- 7 via C_Timer.NewTimer/NewTicker and 2 " ..
			"via Core:ScheduleTimer. If they have genuinely gone, lower this number deliberately; " ..
			"a sudden drop means a pattern stopped matching and the guard above is now checking " ..
			"less than it appears to")

		-- BOTH SPELLINGS MUST BE FOUND, not just enough of one to clear the total. The AceTimer
		-- sites are the ones a C_Timer-only sweep misses, which is precisely the gap that made
		-- this guard incomplete when first written -- a count alone would let that recur silently.
		local sawC_Timer, sawAce = false, false
		for _, path in ipairs(MODULES) do
			local src = readFile(path)
			if src:find("=%s*C_Timer%.NewTi") then sawC_Timer = true end
			if src:find("=%s*[%w_]+:ScheduleT") then sawAce = true end
		end
		assert.is_true(sawC_Timer, "no C_Timer.NewTimer/NewTicker assignment found anywhere -- that " ..
			"pattern has stopped matching")
		assert.is_true(sawAce, "no Core:ScheduleTimer assignment found anywhere -- the AceTimer " ..
			"half of this sweep has stopped matching, which is the exact blind spot it was " ..
			"extended to close")
	end)
end)
