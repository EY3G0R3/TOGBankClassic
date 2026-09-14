-- SEARCH-005: one search box for the whole addon, built on LibAceGUIWidgets, and the per-column
-- search it gives the Requests window.
--
-- THE OPERATOR, 2026-08-19 (Discord): "add search on requestors to find someone easily"; and on
-- 2026-09-11: "we need to add a search bar to each column in the request tab. we should use the
-- search bar look with the icon from libaceGUIwidgets for it, maybe even plumb the library in now
-- ... now might be a good time to centralize the layout/look."
--
-- Three things are pinned here, each against the REAL library and the REAL AceGUI-3.0 from the
-- sibling install, never a stub: the widget type `TOGBankSearchBox` (registered once in
-- Modules/UI.lua, built on the library's SearchBoxTemplate box, with AceGUI's EditBox contract for
-- SetText / OnTextChanged); `TOGBankClassic_UI:SearchMatch`, which delegates to the library's
-- tokenised matcher and degrades to a substring test without it; and the Requests window's
-- column search, which is a pure function over a request and a table of column queries.
--
-- NOT COVERED, stated so it is not read as more than it is: the rendering of the boxes inside the
-- Requests header table, the Search window and the Mailbox window (no AceGUI widget files load
-- offline, and those windows' DrawWindow functions do not run here).
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function loadUIWithLibrary()
	require("env.libs").load("LibAceGUIWidgets-1.0")
	local UI = env.loadUI()
	assert(UI.Widgets, "precondition: LibAceGUIWidgets-1.0 did not resolve; the widget would be built on the fallback")
	return UI
end

describe("TOGBankSearchBox", function()
	local UI

	before_each(function()
		env.reset(); env.stubOutput()
		-- The rich widget layer, not the hollow default frame: a widget constructor needs
		-- CreateFrame to return an OBJECT whose template children exist and whose unknown members
		-- are nil (the hollow frame answers every key with a truthy no-op, so `eb.Instructions` would
		-- be a function and the placeholder branch would take the wrong path).
		require("env.frames").reset()
		UI = loadUIWithLibrary()
	end)

	it("registers with the real AceGUI-3.0", function()
		assert.is_function(UI.WidgetRegistry and UI.WidgetRegistry["TOGBankSearchBox"],
			"the widget type is not in AceGUI's registry; every window that Creates it would raise")
	end)

	it("is the library's search box: Blizzard's SearchBoxTemplate, with the magnifier and the placeholder", function()
		local w = UI:Create("TOGBankSearchBox")
		assert.is_table(w.editbox)
		assert.is_table(w.editbox.searchIcon, "no magnifier -- the box was not built from SearchBoxTemplate")
		assert.is_table(w.editbox.Instructions, "no placeholder FontString")
		assert.equal(w.editbox:GetParent(), w.frame)
	end)

	it("shows a placeholder and clears it back to the template's own", function()
		local w = UI:Create("TOGBankSearchBox")
		w:SetPlaceholder("name...")
		assert.equal("name...", w.editbox.Instructions:GetText())
		w:SetPlaceholder(nil)
		assert.is_string(w.editbox.Instructions:GetText())
	end)

	it("keeps AceGUI's EditBox contract: SetText is silent, typing fires OnTextChanged with the text", function()
		local w = UI:Create("TOGBankSearchBox")
		local fired = {}
		w:SetCallback("OnTextChanged", function(_, _, text) fired[#fired + 1] = text end)
		w:SetText("Togstone")
		assert.equal("Togstone", w:GetText())
		assert.equal(0, #fired, "a programmatic SetText fired OnTextChanged -- a window writing its query back on redraw would loop")
		w.editbox:SetText("Tog")
		w.editbox:Fire("OnTextChanged", true)   -- the user typed
		assert.same({ "Tog" }, fired)
	end)

	it("fires OnTextChanged from the clear-X, which empties the box WITHOUT user input", function()
		-- Era's SearchBoxTemplateClearButton_OnClick -> SearchBoxTemplate_ClearText is SetText("")
		-- + ClearFocus() on the parent (InputBoxTemplates.lua:48-56): programmatic, so the text
		-- hook rightly ignores it and the report comes from the button's own click.
		local w = UI:Create("TOGBankSearchBox")
		local fired = {}
		w:SetCallback("OnTextChanged", function(_, _, text) fired[#fired + 1] = text end)
		w:SetText("Tog")
		w.editbox:SetText("")                      -- what the template's click does
		w.editbox:Fire("OnTextChanged", false)     -- ...and the OnTextChanged that follows
		assert.same({}, fired, "a programmatic empty was reported before the button said so")
		w.editbox.clearButton:Fire("OnClick")
		assert.same({ "" }, fired)
	end)

	it("does not fire OnTextChanged for ANY non-user change, including one that empties the box", function()
		local w = UI:Create("TOGBankSearchBox")
		local fired = 0
		w:SetCallback("OnTextChanged", function() fired = fired + 1 end)
		w.editbox:SetText("x")
		w.editbox:Fire("OnTextChanged", false)
		w.editbox:SetText("")
		w.editbox:Fire("OnTextChanged", false)
		assert.equal(0, fired, "another code path's SetText on the raw box was reported as the user's clear")
	end)

	it("fires OnEnterPressed with the text, and passes focus through", function()
		local w = UI:Create("TOGBankSearchBox")
		local got
		w:SetCallback("OnEnterPressed", function(_, _, text) got = text end)
		w:SetText("hammer")
		w.editbox:Fire("OnEnterPressed")
		assert.equal("hammer", got)
		w:SetFocus()
		assert.is_true(w:HasFocus())
		w:ClearFocus()
		assert.is_false(w:HasFocus())
	end)

	it("comes back clean from the pool", function()
		-- Driven through the widget's own OnRelease / OnAcquire rather than AceGUI:Release ->
		-- AceGUI:Create: AceGUI-3.0.lua:41 captures `UIParent` as an upvalue when the library first
		-- loads, which in a whole-suite run happened under the hollow frame of an earlier spec, so
		-- Release's `frame:SetParent(UIParent)` here would re-parent to a hollow object. A
		-- suite-order artefact of the shared Lua state, not a property of the widget.
		local w = UI:Create("TOGBankSearchBox")
		w:SetText("stale")
		w:SetPlaceholder("stale...")
		w:SetMaxLetters(5)
		w:SetFocus()
		w:OnRelease()
		assert.is_false(w:HasFocus(), "a released box kept keyboard focus")
		w:OnAcquire()
		assert.equal("", w:GetText(), "a pooled box came back with the previous window's query")
		assert.equal(0, w.editbox:GetMaxLetters())
		assert.is_not_equal("stale...", w.editbox.Instructions:GetText(), "the previous placeholder survived")
	end)
end)

describe("TOGBankClassic_UI:SearchMatch", function()
	local UI

	before_each(function()
		env.reset(); env.stubOutput()
		UI = loadUIWithLibrary()
	end)

	it("delegates to the library: every word must appear, case-insensitive, across the fields", function()
		assert.is_true(UI:SearchMatch("stone ham", "Stone Hammer"))
		assert.is_true(UI:SearchMatch("STONE", "Stone Hammer"))
		assert.is_true(UI:SearchMatch("ham stone", "Stone Hammer"), "token order must not matter")
		assert.is_false(UI:SearchMatch("stone axe", "Stone Hammer"))
		assert.is_true(UI:SearchMatch("tog", "Stone Hammer", "Togstone-Testrealm"), "later fields are searched too")
	end)

	it("matches everything on an empty or nil query, and skips nil fields", function()
		assert.is_true(UI:SearchMatch("", "anything"))
		assert.is_true(UI:SearchMatch(nil, "anything"))
		assert.is_true(UI:SearchMatch("x", nil, "x"))
	end)

	it("degrades to a substring test without the library, rather than to no filter", function()
		UI.Widgets = nil
		assert.is_true(UI:SearchMatch("one ham", "Stone Hammer"))
		assert.is_false(UI:SearchMatch("ham stone", "Stone Hammer"), "the fallback is one token, not the library's rule")
		assert.is_false(UI:SearchMatch("axe", "Stone Hammer"))
		assert.is_true(UI:SearchMatch("", "Stone Hammer"))
	end)
end)

-- SEARCH-006. The operator, 2026-09-11, on seeing SEARCH-005's box under each column: "i don't
-- need a search bar for each area, one bar that filters on all columns would work" -- "put them
-- above the dropdown, not below". One box; every word must appear somewhere across the four text
-- columns; the box sits above the Requester / Bank dropdowns.
describe("Requests: ONE search across every column", function()
	local R

	before_each(function()
		env.reset(); env.stubOutput()
		loadUIWithLibrary()
		env.loadModules({ "Modules/Constants.lua", "Modules/Item.lua" })
		env.loadFile("Modules/UI/Requests.lua")
		R = TOGBankClassic_UI_Requests
		R:Init()
		env.defineItem(15260, { name = "Stone Hammer" })
	end)

	local function req(over)
		local r = { id = "r1", date = 1757000000, requester = "Galdof-Azuresong", bank = "Togstone-Azuresong",
			item = "Stone Hammer", itemID = 15260, quantity = 3 }
		for k, v in pairs(over or {}) do r[k] = v end
		return r
	end

	it("searches the text a column SHOWS: the formatted date, the names, the item's display name", function()
		local r = req()
		assert.equal(date("%Y-%m-%d %H:%M", 1757000000), R:ColumnText(r, "date"))
		assert.equal("Galdof-Azuresong", R:ColumnText(r, "requester"))
		assert.equal("Togstone-Azuresong", R:ColumnText(r, "bank"))
		assert.equal("Stone Hammer", R:ColumnText(r, "item"))
		assert.equal("Unknown", R:ColumnText(req({ date = 0 }), "date"))
	end)

	it("passes a request when EVERY word appears somewhere across the four text columns", function()
		local r = req()
		assert.is_true(R:SearchMatches(r, nil))
		assert.is_true(R:SearchMatches(r, ""))
		assert.is_true(R:SearchMatches(r, "gald"))
		assert.is_true(R:SearchMatches(r, "gald hammer"), "words from two columns must both count")
		assert.is_true(R:SearchMatches(r, "tog"), "the bank column is searched")
		assert.is_true(R:SearchMatches(r, date("%Y-%m", 1757000000)), "the date as shown is searched")
		assert.is_false(R:SearchMatches(r, "gald axe"), "one word missing everywhere must fail the row")
		assert.is_false(R:SearchMatches(req({ quantity = 777 }), "777"), "the quantity is not searched")
	end)

	it("SetSearch trims, drops an empty query, and redraws from the top of the list", function()
		local drawn, preserved = 0, {}
		R.DrawRows = function(_, preserveScroll) drawn = drawn + 1; preserved[drawn] = preserveScroll end
		R:SetSearch("  gald ")
		assert.equal("gald", R.searchText)
		assert.is_false(preserved[1], "a new search kept the old scroll position")
		R:SetSearch("   ")
		assert.is_nil(R.searchText, "an emptied box must clear the search, not search for spaces")
		assert.equal(2, drawn)
	end)

	it("ApplyFilters narrows by the search on top of the requester / bank filters", function()
		local a = req({ id = "a" })
		local b = req({ id = "b", requester = "Nimbus-Azuresong", item = "Minor Healing Potion", itemID = 858 })
		env.defineItem(858, { name = "Minor Healing Potion" })
		local all = { a = a, b = b }
		local function ids(list) local out = {} for _, r in ipairs(list) do out[#out + 1] = r.id end table.sort(out) return out end

		R.searchText = nil
		assert.equal(all, R:ApplyFilters(all), "no filters: the same table back, untouched")
		R.searchText = "potion"
		assert.same({ "b" }, ids(R:ApplyFilters(all)))
		R.searchText = "azuresong"
		assert.same({ "a", "b" }, ids(R:ApplyFilters(all)))
		R.bankFilter = "Togstone-Azuresong"
		R.searchText = "nimbus"
		assert.same({ "b" }, ids(R:ApplyFilters(all)))
		R.searchText = "nimbus hammer"
		assert.same({}, ids(R:ApplyFilters(all)))
	end)

	-- CANCEL-REASON-001. The operator (Discord, relayed 2026-09-11): "make some way to show why things
	-- were cancelled, folks can't see why easily" -- "there is info there, it's just not apparent to
	-- the users that they need to mouse over it ... maybe a background glow or something".
	-- "you made it a highlight, what i meant was a soft glow of the letters/numbers themselves", then
	-- on the coloured 1px shadow: "it's just a 1px 'outline' can we actually make it 'glow'?". The
	-- glow is BUILT from copies of the text under the glyphs, rings of falling alpha; a block behind
	-- the cell and a single offset shadow are both what it is NOT.
	it("glows the date's LETTERS (layered cream copies under the glyphs) for a cancelled request with a reason, and restores the cell's own shadow after", function()
		require("env.frames").reset()
		local frame = CreateFrame("Frame")
		frame:SetFrameLevel(5)
		local fs = frame:CreateFontString()
		fs:SetJustifyH("LEFT")
		fs:SetText("|cffff66662026-09-11 18:10|r")
		local calls = {}
		fs.SetShadowColor  = function(_, r, g, b, a) calls[#calls + 1] = { "color", r, g, b, a } end
		fs.SetShadowOffset = function(_, x, y) calls[#calls + 1] = { "offset", x, y } end
		local label = { label = fs, frame = frame }
		R:SetCancelGlow(label, true)
		assert.is_true(fs.togCancelGlow)
		-- The glyphs' own drop shadow is OFF while glowing: black at 1px would notch the halo.
		assert.same({ "color", 0, 0, 0, 0 }, calls[1], "the cell's black drop-shadow was left under the glow")
		assert.is_nil(label.frame.togCancelGlow, "a texture was drawn behind the cell -- the first cut the operator rejected")
		local layers = fs.togGlowLayers
		assert.equal(24, #layers, "three rings of eight directions")
		-- CANCEL-GLOW-003: UNDER the glyphs by draw LAYER at the cell's OWN frame level -- copies on
		-- ARTWORK, the glyphs raised to OVERLAY while they glow. A BACKGROUND/-1 copy on the cell
		-- painted over the text; a frame one level BELOW the cell (the previous cut) sat under
		-- whatever else was at that level, and on the Guild Bank tab the operator saw no glow.
		local glow = frame.togGlowFrame
		assert.equal(frame, glow:GetParent())
		assert.equal(5, glow:GetFrameLevel(), "the glow frame is not at the cell's own level")
		assert.equal("OVERLAY", fs:GetDrawLayer(), "the glyphs were not raised above the copies")
		-- The halo BREATHES ("oh, i like 2"): one Alpha animation, full to a third over a second,
		-- bouncing back, eased -- on the glow frame only, so the glyphs hold still. BREATH-001: the
		-- library's breath (W:Breathe), under its own key.
		local pulse = glow._lagwBreath
		assert.is_true(pulse:IsPlaying(), "the glow is not pulsing")
		assert.equal("BOUNCE", pulse:GetLooping())
		local fade = pulse:GetAnimations()
		assert.equal("Alpha", fade._animType)
		assert.equal(1, fade:GetFromAlpha())
		assert.equal(0.35, fade:GetToAlpha())
		assert.equal(1.0, fade:GetDuration())
		assert.equal("IN_OUT", fade:GetSmoothing())
		local byOffset = {}
		for _, g in ipairs(layers) do
			assert.equal(glow, g:GetParent(), "a glow copy is drawn on the cell itself, where it covers the glyphs")
			assert.equal("2026-09-11 18:10", g:GetText(), "a glow copy kept the colour escape and would paint red")
			assert.equal("LEFT", g:GetJustifyH(), "a glow copy is justified differently from the glyphs and would drift")
			assert.same({ 1, 0.9, 0.7, 1 }, { g:GetTextColor() }, "the glow is not warm cream (gold merged into the red glyphs)")
			assert.is_true(g:IsShown())
			local _, rel, _, dx, dy = g:GetPoint(1)
			assert.equal(fs, rel, "a glow copy is not anchored to the glyphs it copies")
			local r = math.max(math.abs(dx), math.abs(dy))
			byOffset[r] = byOffset[r] or {}
			byOffset[r][#byOffset[r] + 1] = g:GetAlpha()
		end
		-- Alpha falls with distance: 1px 0.12, 2px 0.06, 3px 0.03, eight copies each. The first
		-- numbers (0.4/0.2/0.1) stacked to a solid blob -- "now that's a cool glow, but i can't read
		-- it anymore".
		for r, alpha in ipairs({ 0.12, 0.06, 0.03 }) do
			assert.equal(8, #byOffset[r], "ring " .. r .. " is not eight directions")
			for _, a in ipairs(byOffset[r]) do assert.equal(alpha, a, "ring " .. r .. " alpha") end
		end
		-- A redraw with new text refreshes the copies and creates no more.
		fs:SetText("|cffff66662026-09-12 09:00|r")
		R:SetCancelGlow(label, true)
		assert.equal(layers, fs.togGlowLayers, "a second SetCancelGlow(true) built a second set of copies")
		assert.equal("2026-09-12 09:00", layers[1]:GetText())
		assert.equal(pulse, glow._lagwBreath, "a second SetCancelGlow(true) built a second pulse")
		glow:SetAlpha(0.5)   -- mid-breath when the row is reused
		R:SetCancelGlow(label, false)
		assert.is_nil(fs.togCancelGlow, "a pooled cell reused for an open request kept its glow")
		assert.is_false(pulse:IsPlaying(), "the pulse kept running on a reused row")
		assert.equal(1, glow:GetAlpha(), "a stopped bounce left the halo dim for the next cancelled request")
		assert.same({ "color", 0, 0, 0, 1 }, calls[3], "the cell's own shadow was not put back")
		assert.same({ "offset", 1, -1 }, calls[4])
		assert.is_not_equal("OVERLAY", fs:GetDrawLayer(), "a pooled cell reused for an open request kept its glyphs raised")
		for _, g in ipairs(layers) do assert.is_false(g:IsShown(), "a glow copy stayed visible on a reused row") end
		R:SetCancelGlow(label, false)                                 -- already off: no calls
		assert.equal(4, #calls)
		R:SetCancelGlow({ frame = CreateFrame("Frame") }, true)      -- no FontString: nothing to raise on
		R:SetCancelGlow(nil, true)
	end)

	-- AceGUI's pool is shared with every addon; the Requests window is Released whole when banker
	-- status changes. A Label handed back glowing would pulse our date under someone else's text.
	it("switches the glow off when the Label is released to the shared pool", function()
		require("env.frames").reset()
		local label = TOGBankClassic_UI:Create("Label")
		label:SetText("|cffff66662026-09-11 18:10|r")
		local fs = label.label
		fs.SetShadowColor  = fs.SetShadowColor  or function() end
		fs.SetShadowOffset = fs.SetShadowOffset or function() end
		R:SetCancelGlow(label, true)
		assert.is_true(fs.togCancelGlow)
		assert.is_true(label.frame.togGlowFrame._lagwBreath:IsPlaying())
		label:Release()
		assert.is_nil(fs.togCancelGlow, "the Label went back to the pool with the glow on")
		assert.is_false(label.frame.togGlowFrame._lagwBreath:IsPlaying(), "the pulse kept running in the pool")
		for _, g in ipairs(fs.togGlowLayers) do assert.is_false(g:IsShown(), "a glow copy stayed visible in the pool") end
		-- The same widget object comes back from the pool with its callbacks wiped: a second
		-- switch-on must register the release hook again, or the second release leaks.
		local again = TOGBankClassic_UI:Create("Label")
		assert.equal(label, again, "the pool handed back a different widget; the re-acquire case is untested")
		again:SetText("|cffff66662026-09-12 09:00|r")
		R:SetCancelGlow(again, true)
		again:Release()
		assert.is_nil(fs.togCancelGlow, "the second release went back to the pool with the glow on -- the hook was registered once, not per switch-on")
	end)

	-- "some folks will whine about it, we need to add it as a setting to the appearance tab, and
	-- have it ON by default. folks can turn it off if they want"
	it("is ON by default and OFF at the Appearance-tab switch, which also puts out a glow already on screen", function()
		require("env.frames").reset()
		local frame = CreateFrame("Frame")
		local fs = frame:CreateFontString()
		fs:SetText("2026-09-11 18:10")
		fs.SetShadowColor  = function() end
		fs.SetShadowOffset = function() end
		local label = { label = fs, frame = frame }

		TOGBankClassic_Options = nil                       -- before Options:Init: the default, not off
		assert.is_true(R:CancelGlowEnabled())
		TOGBankClassic_Options = { db = { global = {} } }  -- an older options DB with no key: still on
		assert.is_true(R:CancelGlowEnabled())
		R:SetCancelGlow(label, true)
		assert.is_true(fs.togCancelGlow)

		TOGBankClassic_Options.db.global.cancelGlow = false
		assert.is_false(R:CancelGlowEnabled())
		R:SetCancelGlow(label, true)                       -- the next repaint of a cancelled row
		assert.is_nil(fs.togCancelGlow, "the switch is off and the glow stayed on")
		assert.is_false(frame.togGlowFrame._lagwBreath:IsPlaying())
		for _, g in ipairs(fs.togGlowLayers) do assert.is_false(g:IsShown()) end

		-- The real Options: the default is true, the toggle is on the APPEARANCE tab, and its
		-- setter repaints the open window. Executed, not grepped.
		TOGBankClassic_Options = nil
		require("env.ace").load("AceDB-3.0", "AceConfig-3.0", "AceConfigDialog-3.0")
		env.loadFile("Modules/Options.lua")
		TOGBankClassic_Options:Init()
		assert.is_true(TOGBankClassic_Options.db.global.cancelGlow, "the Options default is not ON")
		local table = LibStub("AceConfigRegistry-3.0"):GetOptionsTable("TOGBankClassic", "dialog", "Spec-1.0")
		local toggle = table.args.appearance.args.cancelGlow
		assert.equal("toggle", toggle.type)
		assert.is_true(toggle.get())
		local repainted = 0
		R.DrawRows = function() repainted = repainted + 1 end
		toggle.set(nil, false)
		assert.is_false(TOGBankClassic_Options.db.global.cancelGlow)
		assert.is_false(toggle.get())
		assert.equal(1, repainted, "turning the glow off did not repaint the Requests window")
	end)

	it("searches exactly the four text columns, and builds ONE box, above the dropdowns, none under a header", function()
		local src = env.readFile("Modules/UI/Requests.lua")
		local with = {}
		for key in src:gmatch('{ key = "(%w+)",[^\n]-search = true') do with[#with + 1] = key end
		assert.same({ "date", "requester", "bank", "item" }, with)
		local boxes = 0
		for _ in src:gmatch('Create%("TOGBankSearchBox"%)') do boxes = boxes + 1 end
		assert.equal(1, boxes, "the Requests window must build exactly one search box")
		local boxAt = src:find('Create("TOGBankSearchBox")', 1, true)
		local dropdownAt = src:find('requesterFilter = TOGBankClassic_UI:Create("Dropdown")', 1, true)
		assert.is_true(boxAt < dropdownAt, "the search box must be added to the window BEFORE the dropdown row")
	end)
end)
