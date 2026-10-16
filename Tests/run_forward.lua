-- FORWARD-PARTS-001: the forward (a to z) suite in slices, one Lua state per slice.
--
--   lua Tests/run_forward.lua <part> <parts> [run.lua flags...]   (from the addon root)
--
-- The fallback for a loaded machine, when the whole forward run ("forward-order, failures only")
-- will not fit the desk's budget. Declared as writ suites "forward 1/4" .. "4/4". Before this the
-- forward parts (A8a, A6c, B3a, B3b) listed their spec files by hand, so a new spec file ran in
-- none of them until someone added it (Peer Review e1e13df8). Slices of the sorted glob cannot
-- miss one, and the forward parts now add up to the whole forward run the same way the reverse
-- parts do. Discovery and slicing are Tests/run_parts.lua's.
--
-- --quiet and --timeout=240 are what the hand-listed parts ran with; flags after <part> <parts>
-- are passed on and a later --timeout wins. KNOWN COST: an order dependency that crosses a slice
-- boundary is not seen, as before. No arguments runs the whole list.
assert(loadfile("Tests/run_parts.lua"))().run({
	reverse = false,
	name = "run_forward",
	flags = { "--quiet", "--timeout=240" },
})
