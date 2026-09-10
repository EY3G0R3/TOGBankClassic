-- DOC-004: prose that restates a constant, swept MECHANICALLY over every file the .toc ships.
--
-- WHY THIS IS A GUARD AND NOT A READ-THROUGH, which is the whole point of the item:
--
-- DOC-003 was three sites where a comment said the collect window was 10 seconds while
-- COLLECT_WINDOW was 60. It was found by reading. The follow-up checked P2PSession's other three
-- timeouts by hand, found them documented only at their definitions, and called the area clean --
-- but that is ONE FILE, and this board has now three separate times found a hand-checked list short
-- (audit finding 24: 3 of 4 files; DOC-003 itself: 1 of 3 docstrings; round 8: 4 of 5 reads). A
-- fourth careful read is not a different method from the three that came up short.
--
-- THE SHAPE THIS CATCHES, stated narrowly so a failure is always a real defect:
--
--   a comment NAMES a numeric constant defined in the same file, AND states a number with a unit
--   in the same comment, AND the two disagree.
--
-- That is exactly the remedy DOC-003 settled on -- "name the constant, never re-synchronise the
-- number" -- turned into something enforced. Once a comment names its constant, this keeps it
-- honest forever; a comment that names no constant is out of scope and deliberately so.
--
-- WHAT IT DOES NOT CATCH, said plainly rather than left for someone to discover:
--
--   * a comment that states a number and names NO constant ("waits 10 seconds"). Catching those
--     needs guessing which constant a sentence is about, and a guess produces false positives,
--     which is how a guard gets weakened and then ignored.
--   * a magic number in CODE duplicating a constant's value.
--   * prose in docs/ or README.txt -- this sweeps shipped Lua only.
--
-- So a clean run here means "no comment contradicts a constant it names", NOT "no prose restates a
-- constant anywhere". Those are different claims and only the first one is being made.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function readFile(path)
	local fh = assert(io.open(path, "rb"), "cannot read " .. path)
	local src = fh:read("*a")
	fh:close()
	return src
end

local MODULES = env.shippedModules()

--- Units that make a bare number in prose a CLAIM about a quantity rather than a citation.
---
--- Deliberately excludes anything that would match a line reference, a date, a ticket id or a
--- version -- those are the four things comments in this codebase are full of, and matching them
--- would bury a real hit under noise. A number only counts when a unit word follows it.
local UNITS = {
	"seconds?", "secs?", "ms", "milliseconds?", "minutes?", "mins?", "hours?", "days?",
	"bytes?", "chars?", "characters?", "entries", "items?", "rows?", "slots?", "chunks?",
}

--- Numeric constants a file defines: `local NAME = 123`, `NAME = 123`, and `T.NAME = 123`.
--- Only SCREAMING_CASE names, because those are the ones prose refers to by name -- a lower-case
--- local is a variable and a comment naming it is not making a claim about a tunable.
local function constantsIn(src)
	local found = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		-- Strip a trailing comment so `local FOO = 60 -- was 10` cannot define FOO twice.
		local code = line:match("^(.-)%-%-") or line
		local name, value = code:match("([%u][%u%d_]+)%s*=%s*(%d+%.?%d*)%s*$")
		if name and value and #name >= 4 then
			found[name] = tonumber(value)
		end
	end
	return found
end

--- Comments in a file, as { line = <n>, text = <string> }. Handles `--` line comments only;
--- `--[[ ]]` blocks are not used for prose in this codebase.
local function commentsIn(src)
	local out, n = {}, 0
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		n = n + 1
		local text = line:match("%-%-+%s?(.*)$")
		if text and text ~= "" then
			out[#out + 1] = { line = n, text = text }
		end
	end
	return out
end

--- Every "<number> <unit>" claim in a comment, as an array of numbers.
local function quantitiesIn(text)
	local nums = {}
	for _, unit in ipairs(UNITS) do
		for value in text:gmatch("(%d+%.?%d*)%s*" .. unit .. "%f[%W]") do
			nums[#nums + 1] = tonumber(value)
		end
	end
	return nums
end

--- Comments that name a constant and state a quantity that disagrees with it.
local function contradictions(path)
	local src = readFile(path)
	local constants = constantsIn(src)
	if not next(constants) then return {} end

	local hits = {}
	for _, comment in ipairs(commentsIn(src)) do
		for name, value in pairs(constants) do
			if comment.text:find(name, 1, true) then
				for _, stated in ipairs(quantitiesIn(comment.text)) do
					if stated ~= value then
						hits[#hits + 1] = string.format(
							"%s:%d: names %s (= %s) but states %s -- %s",
							path, comment.line, name, tostring(value), tostring(stated),
							comment.text)
					end
				end
			end
		end
	end
	return hits
end

describe("DOC-004: comments must not contradict a constant they name", function()
	it("finds no comment stating a quantity that disagrees with the constant it names", function()
		local hits = {}
		for _, path in ipairs(MODULES) do
			for _, hit in ipairs(contradictions(path)) do
				hits[#hits + 1] = hit
			end
		end
		assert.equal(0, #hits, string.format(
			"%d comment(s) state a number that contradicts a constant named in the same comment. " ..
			"The remedy is to NAME the constant and delete the number, never to re-synchronise " ..
			"the two -- a number written twice diverges again:\n  %s",
			#hits, table.concat(hits, "\n  ")))
	end)

	-- A guard that sweeps nothing passes. These pin the sweep itself, because every failure this
	-- file exists to catch is invisible if the file set or the parsers silently come up empty.
	it("actually sweeps the shipped modules", function()
		assert.is_true(#MODULES >= 20,
			"the .toc parse returned " .. #MODULES .. " modules, which is too few to be the whole " ..
			"addon -- the sweep would pass by covering almost nothing")
	end)

	it("finds constants to check against", function()
		local withConstants = 0
		for _, path in ipairs(MODULES) do
			if next(constantsIn(readFile(path))) then withConstants = withConstants + 1 end
		end
		assert.is_true(withConstants >= 3, string.format(
			"only %d shipped file(s) parsed as defining a SCREAMING_CASE numeric constant. The " ..
			"sweep compares comments against those, so a broken constant parser makes this file " ..
			"green while checking nothing", withConstants))
	end)

	it("detects a contradiction when one exists", function()
		-- Proves the three parsers compose, without waiting for a real defect to appear.
		local src = table.concat({
			"local COLLECT_WINDOW = 60",
			"-- Waits COLLECT_WINDOW, which is 10 seconds, before dispatching.",
		}, "\n")
		local tmp = "Tests/tmpclaude-doc004-fixture.lua"
		local fh = assert(io.open(tmp, "wb"))
		fh:write(src)
		fh:close()

		local hits = contradictions(tmp)
		os.remove(tmp)

		assert.equal(1, #hits,
			"the sweep did not flag a comment naming COLLECT_WINDOW (= 60) while stating " ..
			"10 seconds -- which is DOC-003 verbatim, so a green run proves nothing")
	end)

	it("does not flag a comment that agrees with the constant", function()
		local src = table.concat({
			"local COLLECT_WINDOW = 60",
			"-- Waits COLLECT_WINDOW, which is 60 seconds, before dispatching.",
		}, "\n")
		local tmp = "Tests/tmpclaude-doc004-agree.lua"
		local fh = assert(io.open(tmp, "wb"))
		fh:write(src)
		fh:close()

		local hits = contradictions(tmp)
		os.remove(tmp)

		assert.equal(0, #hits,
			"a comment that states the CORRECT number was flagged -- the guard would then be " ..
			"reporting on every accurate comment in the addon and would be turned off")
	end)

	it("ignores a line reference, which is not a quantity", function()
		local src = table.concat({
			"local COLLECT_WINDOW = 60",
			"-- See COLLECT_WINDOW at P2PSession.lua:34, filed 2026-09-09 as TIMER-001.",
		}, "\n")
		local tmp = "Tests/tmpclaude-doc004-refs.lua"
		local fh = assert(io.open(tmp, "wb"))
		fh:write(src)
		fh:close()

		local hits = contradictions(tmp)
		os.remove(tmp)

		assert.equal(0, #hits,
			"a line number, a date or a ticket id was read as a quantity -- this is the noise that " ..
			"buries real hits, and comments here are full of all three")
	end)
end)
