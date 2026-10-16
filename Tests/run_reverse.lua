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
-- Discovery and slicing are Tests/run_parts.lua's, shared with Tests/run_forward.lua
-- (FORWARD-PARTS-001).
--
-- REVERSE-GATE-001: `lua Tests/run_reverse.lua <part> <parts>` runs one contiguous slice of the
-- reversed list (part 1 is the z end). The whole run outgrew the desk's 15-minute budget on
-- 2026-09-25, as the forward run had; the slices are declared as writ suites "reverse 1/3" .. "3/3".
-- KNOWN COST: an order dependency that crosses a slice boundary is not seen -- the same trade the
-- forward split makes. No arguments still runs the whole list.
--
-- REVERSE-TIMEOUT-001: the harness's per-file limit (60 s, from pin e6b42c3) is too short for
-- the a-end slice. Every frames.reset() runs a full collect over whatever earlier files left alive,
-- and by browse_spec that is ~450 MB and ~150k frames, so a file that takes 9 s alone took 97 s
-- there (measured 2026-09-29, --times; all 696 passed with the limit raised). The limit is WALL
-- time on Windows, not CPU (WoWAPITesting, harness thread 1a91c3ca, 2026-10-07: os.clock is the
-- CRT's wall clock), so it also scales with how busy the machine is: on 2026-10-07, with three
-- other desk runs in flight, browse_spec ran past 240 s here twice at the same example and
-- passed 697/0 at 600 s. 600 s still stops a real hang well inside the desk's 15-minute budget.
-- KNOWN COST: a file that slows down in this order is caught at 600 s, not 60. The retention
-- itself is SUITE-HEAP-001's.
assert(loadfile("Tests/run_parts.lua"))().run({
	reverse = true,
	name = "run_reverse",
	flags = { "--timeout=600" },
})
