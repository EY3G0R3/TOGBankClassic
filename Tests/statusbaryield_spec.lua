-- STATUSBAR-002: the narrow-bar yield (SYNCED-001 / peer review B2) against a window that keeps
-- writing its own left text.
--
-- Read off the banker's Requests window on 2026-09-12: "Showing 47 requests out of 1717 total" drawn
-- straight under the red "Bank update not received by anyone yet -- stay online" line. The yield
-- existed, but only the 0.5 s ticker applied it; DrawContent wrote the count between two ticks
-- (every incoming request merge redraws) and it sat under the line until the next one. Now the
-- window's SetStatusText goes through the bar: parked while yielding, painted otherwise, and the
-- newest parked text is what comes back when the line stops being urgent.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local SB
local urgent, propLine

--- A window shaped like AceGUI's Frame as far as the bar reads it: the frame, `statustext` on the
--- status background, SetStatusText writing that string, SetCallback. Real harness frames, so
--- GetStringWidth is the harness's per-character metric and a narrow bar can be staged.
local function window(barWidth)
	local frame = CreateFrame("Frame")
	local statusbg = CreateFrame("Frame", nil, frame)
	statusbg:SetWidth(barWidth)
	statusbg:SetHeight(20)
	local statustext = statusbg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	statustext:SetText("")
	local w = { frame = frame, statustext = statustext, callbacks = {} }
	function w:SetStatusText(text) self.statustext:SetText(text) end
	function w:SetCallback(name, fn) self.callbacks[name] = fn end
	return w
end

local function load()
	env.stubOutput()
	require("env.frames").reset()   -- real harness frames: CreateFontString and GetStringWidth are live
	env.loadFile("Modules/Constants.lua")
	-- BREATH-001: the bar's breath is the library's (W:Breathe), reached through UI.Widgets.
	require("env.libs").load("LibAceGUIWidgets-1.0")
	TOGBankClassic_UI = TOGBankClassic_UI or {}
	TOGBankClassic_UI.Widgets = LibStub("LibAceGUIWidgets-1.0")
	env.loadFile("Modules/UI/StatusBar.lua")
	SB = TOGBankClassic_UI_StatusBar
	TOGBankClassic_Options = { IsStatusBarNetworkInfoEnabled = function() return false end }
	urgent, propLine = true, "|cffff4444Bank update not received by anyone yet -- stay online (35 online, 7:27)|r"
	SB.PropagationIsUrgent = function() return urgent end
	SB.BuildPropagationText = function() return urgent and propLine or "" end
end

describe("STATUSBAR-002: the window's left text yields to the urgent line and stays yielded", function()
	local w, sb
	local LEFT = "Showing 47 requests out of 1717 total"

	before_each(function()
		env.reset(); load()
		w = window(200)   -- far too narrow for both
		sb = SB:AttachSides(w)
		w:SetStatusText(LEFT)
		sb:DrawSides()
	end)

	it("hides the left text under an urgent line that does not fit beside it", function()
		assert.equal("", w.statustext:GetText(), "the count was painted under the stay-online line")
		assert.equal(propLine, w.statusCenter:GetText())
	end)

	-- BREATH-001 (operator 2026-09-13: "it's in the status bar, but can you make it 'breath' as
	-- well?"): the centre text lives on its own frame, and that frame's alpha breathes -- the
	-- cancelled-date glow's numbers -- while the line is urgent and on the bar; still at full alpha
	-- otherwise, and while hover content has the bar.
	it("BREATHES the urgent line -- the request glow's pulse on the centre's own frame -- and sits still otherwise", function()
		local host, W = w.statusCenterHost, TOGBankClassic_UI.Widgets
		assert.is_not_nil(host, "the centre has no frame of its own to breathe")
		assert.equal(host, w.statusCenter:GetParent())
		assert.is_true(W:IsBreathing(host), "the urgent line is not breathing")
		-- The library's breath, at its defaults -- the cancelled-date glow's numbers.
		local fade = host._lagwBreath:GetAnimations()
		assert.equal(0.35, fade:GetToAlpha()); assert.equal(1.0, fade:GetDuration()); assert.equal("BOUNCE", host._lagwBreath:GetLooping())
		-- Green (not urgent): stopped, full alpha.
		urgent, propLine = false, "|cff00ff00Bank update confirmed by 1 guildmate|r"
		SB.BuildPropagationText = function() return propLine end
		sb:DrawSides()
		assert.is_false(W:IsBreathing(host), "a confirmed line still breathes")
		assert.equal(1, host:GetAlpha())
		-- Urgent again, then hover content takes the bar: the breath stops with the line.
		urgent, propLine = true, "|cffff4444Bank update not received by anyone yet -- stay online (35 online, 7:27)|r"
		sb:DrawSides()
		assert.is_true(W:IsBreathing(host))
		sb:SetLeft("hover detail")
		assert.is_false(W:IsBreathing(host), "the breath outlived the line on hover")
		assert.equal(1, host:GetAlpha())
	end)

	it("PARKS a write made between two ticks instead of painting it -- the reported overlap", function()
		w:SetStatusText("Showing 48 requests out of 1718 total")   -- DrawContent, mid-tick
		assert.equal("", w.statustext:GetText(),
			"a redraw between ticks painted the count under the line; it stayed there until the next tick (STATUSBAR-002)")
	end)

	it("restores the NEWEST parked text, not the first, when the line stops being urgent", function()
		w:SetStatusText("Showing 48 requests out of 1718 total")
		urgent = false
		-- env.frames installs env.wow's C_Timer over env_togbank's, so the ticker lives on that clock.
		require("env.wow").advanceTime(0.5)
		assert.equal("Showing 48 requests out of 1718 total", w.statustext:GetText(),
			"the left came back with a stale count (or not at all)")
		-- And writes paint straight through again.
		w:SetStatusText("Showing 1 request out of 1 total")
		assert.equal("Showing 1 request out of 1 total", w.statustext:GetText())
	end)

	it("paints the left when the bar is wide enough for both, urgent or not", function()
		local wide = window(2000)
		local bar = SB:AttachSides(wide)
		wide:SetStatusText(LEFT)
		bar:DrawSides()
		assert.equal(LEFT, wide.statustext:GetText())
		assert.equal(propLine, wide.statusCenter:GetText())
	end)

	it("hover content bypasses the yield (SetLeft), and the yield resumes on leave", function()
		sb:SetLeft("hover detail")
		assert.equal("hover detail", w.statustext:GetText(), "the hover text was parked instead of shown")
		sb:Refresh(LEFT, propLine, "")
		assert.equal("", w.statustext:GetText())
	end)

	-- POOL HYGIENE: the Frame goes back to AceGUI's pool with its fields; the hook must not.
	it("takes the hook off on release, so a pooled frame's next owner is not parked forever", function()
		assert.is_function(w.callbacks.OnRelease, "no OnRelease registered")
		w.callbacks.OnRelease(w)
		w:SetStatusText("a dialog's own message")
		assert.equal("a dialog's own message", w.statustext:GetText(),
			"a released frame kept a SetStatusText that parks everything (the previous bar was yielding)")
		assert.is_nil(w.togStatusBar)
	end)

	it("wraps the pristine method on a re-attach, never a previous life's hook", function()
		local sb2 = SB:AttachSides(w)   -- the same widget, attached again without a release
		assert.equal(sb.rawSetStatusText, sb2.rawSetStatusText, "the second bar wrapped the first bar's hook")
	end)
end)

-- STATUSBAR-003 (operator 2026-09-12, screenshot: "the stuff on the bank window overlaps the bank
-- window status bar"): the amber "sent to 1, not confirmed by anyone yet -- stay online (29 online,
-- 5:03)" line is wider than a narrow window's bar. Anchored by its centre alone it overflowed both
-- ends -- into the window border on the left, over Close on the right. Two halves, both pinned:
-- the FontString is bounded to the bar, and a line wider than the bar is swapped for its short form.
describe("STATUSBAR-003: the centre line can never be wider than the bar", function()
	-- 7 px per character offline: LONG is 651 wide, SHORT 427.
	local LONG  = "|cffff9900Bank update sent to 1, not confirmed by anyone yet -- stay online (29 online, 5:03)|r"
	local SHORT = "|cffff9900Update sent to 1, unconfirmed -- stay online (5:03)|r"

	local function withShort()
		SB.BuildPropagationText = function(short)
			if not urgent then return "" end
			return short and SHORT or LONG
		end
	end

	before_each(function() env.reset(); load(); withShort() end)

	--- The bar placed on screen, so the centre's anchors resolve to a real rectangle: an unplaced
	--- bar resolves to nothing and a FontString on it reports 0 wide, which would pass any bound.
	local function placed(barWidth)
		local w = window(barWidth)
		w.statustext:GetParent():SetPoint("CENTER", UIParent, "CENTER", 0, 0)
		return w
	end

	-- STATUSBAR-005 (Peer Review d0170ec1): the green line yields to the SIDES, never to NOTHING. A
	-- non-urgent centre that cannot sit centred beside the left text is bounded to the room the
	-- sides leave -- short form, truncated by the FontString -- and only a room too small for a word
	-- blanks it.
	it("keeps a non-urgent centre on the bar in the room beside the left text, and blanks it only when there is no room", function()
		local GREEN, GREEN_SHORT = "|cff00ff00Bank update confirmed by 1 guildmate|r", "|cff00ff00Update confirmed by 1|r"
		SB.PropagationIsUrgent = function() return false end
		SB.BuildPropagationText = function(short) return short and GREEN_SHORT or GREEN end
		local w = placed(300)
		local sb = SB:AttachSides(w)
		w:SetStatusText("Showing 47")   -- 70 wide: leaves ~200 of room
		sb:DrawSides()
		assert.equal("Showing 47", w.statustext:GetText(), "a non-urgent line took the left text")
		assert.equal(GREEN_SHORT, w.statusCenter:GetText(), "the synced line was blanked on a bar with room for it")
		local host = w.statusCenterHost
		local _, _, _, lx = host:GetPoint(1)
		assert.equal(7 + 70 + 12, lx, "the centre's room does not start after the left text")
		assert.is_true(host:GetWidth() < 300 - lx, "the room runs under the left text")
		-- No room: the left text nearly fills the bar.
		w:SetStatusText("Showing 47 requests out of 1717 total")   -- 266 wide
		sb:DrawSides()
		assert.equal("", w.statusCenter:GetText(), "a centre was painted into a room narrower than a word")
		assert.equal("Showing 47 requests out of 1717 total", w.statustext:GetText())
	end)

	-- STATUSBAR-COVERAGE-001: the other way into the short form. Above, the full line was wider
	-- than the BAR (336 on 300) and swapped before anything was measured against the left text.
	-- Here the bar holds the full line on its own (336 on 420) and it is the LEFT TEXT that
	-- denies it a centred place; the non-urgent path then takes the short form into the room
	-- beside the left text rather than blanking or overlapping.
	it("takes the short form when the full line fits the bar but not beside the left text", function()
		local GREEN, GREEN_SHORT = "|cff00ff00Bank update confirmed by 1 guildmate|r", "|cff00ff00Update confirmed by 1|r"
		SB.PropagationIsUrgent = function() return false end
		SB.BuildPropagationText = function(short) return short and GREEN_SHORT or GREEN end
		local w = placed(420)
		local sb = SB:AttachSides(w)
		w:SetStatusText("Showing 47")   -- 70 wide; the full line centred would start at 42
		sb:DrawSides()
		assert.equal("Showing 47", w.statustext:GetText())
		assert.equal(GREEN_SHORT, w.statusCenter:GetText(), "the full line was kept (or blanked) instead of shortened beside the left text")
		local _, _, _, lx = w.statusCenterHost:GetPoint(1)
		assert.equal(7 + 70 + 12, lx)
		-- The same bar without left text: the full line fits centred and stays.
		w:SetStatusText("")
		sb:DrawSides()
		assert.equal(GREEN, w.statusCenter:GetText(), "the short form was kept on a bar with room for the full line")
	end)

	it("is anchored to BOTH edges of the bar with wrapping off, so its width is the bar's, not the text's", function()
		local w = placed(400)
		SB:AttachSides(w)
		local fs = w.statusCenter
		local points = {}
		for i = 1, fs:GetNumPoints() do points[(fs:GetPoint(i))] = true end
		assert.is_true(points.LEFT and points.RIGHT or false, "the centre is still anchored by its centre alone")
		local width = fs:GetWidth()
		assert.is_true(width > 0 and width <= 400, ("the centre resolves %d wide on a 400 bar"):format(width))
	end)

	it("shows the SHORT form when the full line is wider than the bar (the Mailbox window's 560)", function()
		local w = window(560)
		local sb = SB:AttachSides(w)
		sb:DrawSides()
		assert.equal(SHORT, w.statusCenter:GetText(), "the 651-wide line was drawn on a 560 bar")
		assert.equal("", w.statustext:GetText(), "an urgent line still takes the bar over the left text")
	end)

	it("keeps the FULL line when the bar is wide enough for it", function()
		local w = window(2000)
		local sb = SB:AttachSides(w)
		sb:DrawSides()
		assert.equal(LONG, w.statusCenter:GetText(), "the short form was used on a bar that fits the full line")
	end)

	it("swaps back to the full line as the bar widens, on the next tick", function()
		local w = window(560)
		local sb = SB:AttachSides(w)
		sb:DrawSides()
		assert.equal(SHORT, w.statusCenter:GetText())
		w.statusbg:SetWidth(2000)
		require("env.wow").advanceTime(0.5)
		assert.equal(LONG, w.statusCenter:GetText(), "the bar grew and the centre stayed short")
	end)

	it("still shows the short form on a bar too narrow even for that -- the FontString truncates, nothing overflows", function()
		local w = placed(300)
		local sb = SB:AttachSides(w)
		sb:DrawSides()
		assert.equal(SHORT, w.statusCenter:GetText(), "the centre was blanked (or left long) instead of truncated")
		local width = w.statusCenter:GetWidth()
		assert.is_true(width > 0 and width <= 300, ("the centre resolves %d wide on a 300 bar"):format(width))
	end)

	-- The Inventory window's full bar (sb:Draw) carries the short form through the same path: the
	-- initial refresh, the ticker, and the hover leave. Stubs stand in for the guild the summary reads.
	it("carries the short form through the Inventory window's own Draw, its ticker and its hover", function()
		TOGBankClassic_Guild = { NormalizeName = function(_, n) return n end }
		local w = window(560)
		local sb = SB:Attach(w)
		sb:Draw({ alts = {} }, { "Bankchar" }, { localstatus = { selected = "Bankchar" } })
		assert.equal(SHORT, w.statusCenter:GetText(), "Draw's initial refresh did not swap to the short form")
		assert.equal("", w.statustext:GetText(), "the summary was painted under the urgent line")
		w.callbacks.OnEnterStatusBar()
		assert.equal("No data available", w.statustext:GetText(), "hover detail was parked")
		assert.equal("", w.statusCenter:GetText())
		w.callbacks.OnLeaveStatusBar()
		assert.equal(SHORT, w.statusCenter:GetText(), "the short form did not come back on leave")
		w.statusbg:SetWidth(2000)
		require("env.wow").advanceTime(0.5)
		assert.equal(LONG, w.statusCenter:GetText(), "Draw's ticker did not widen the line with the bar")
	end)

	it("offers no short form for the raid line or the transport text, so nothing else is rewritten", function()
		local Constants = TOGBankClassic_Constants
		local was = Constants.SyncPausedByRaid
		Constants.SyncPausedByRaid = function() return true end
		local _, _, short = SB.BuildSides()
		Constants.SyncPausedByRaid = was
		assert.is_nil(short, "the raid line grew a short form; RefreshSides would swap it for the propagation short")
		urgent = false
		local c, _, s = SB.BuildSides()
		assert.equal("", c)
		assert.is_nil(s)
	end)
end)
