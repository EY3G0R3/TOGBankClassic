TOGBankClassic_UI = LibStub("AceGUI-3.0")

-- Tooltip throttling to prevent performance issues
TOGBankClassic_UI.tooltipThrottle = 0
TOGBankClassic_UI.TOOLTIP_THROTTLE_MS = 50  -- 50ms between tooltip updates
TOGBankClassic_UI.currentTooltipLink = nil

-- The filter strip's inset from a tab's border, ONE number for every tab of the Guild Bank window
-- (Browse's two strips and the Requests strip) so their left edges line up. Browse.lua and
-- Requests.lua each kept their own `FILTER_INSET = 8` with a comment saying they matched and
-- nothing asserting it (self-audit 9bce8d86 F3); browse_spec pins that both read this one.
TOGBankClassic_UI.FILTER_INSET = 8

-- Thinner backdrop used on all windows.
local ThinFrameBackdrop = {
	bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 32, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- ALPHA-001: per-window transparency.
--
-- What fades is the window CHROME -- backdrop, border, title-bar art, status-bar background --
-- and not its contents. `frame:SetAlpha()` would have been one line, but it cascades to every
-- child: at 50% the item icons, counts and labels fade too, which is the opposite of what a
-- see-through window is for. Fading only the chrome means you can see the game through the
-- window while the items stay perfectly readable.
--
-- `module` names the global holding the live window as `.Window`. Resolving through it rather
-- than caching frames is deliberate: AceGUI pools frames across ALL addons using the library, so
-- a cached reference to a released window can later be a different addon's frame, and moving our
-- slider would repaint theirs. `Requests` genuinely does release and recreate its window (banker
-- status change), so this is a live case, not a hypothetical.
TOGBankClassic_UI.ALPHA_WINDOWS = {
	{ key = "inventory", label = "Inventory",   module = "TOGBankClassic_UI_Inventory" },
	{ key = "search",    label = "Search",      module = "TOGBankClassic_UI_Search"    },
	{ key = "requests",  label = "Requests",    module = "TOGBankClassic_UI_Requests"  },
	{ key = "donations", label = "Donations",   module = "TOGBankClassic_UI_Donations" },
	{ key = "mail",      label = "Mail Viewer", module = "TOGBankClassic_UI_Mail"      },
	{ key = "mailbox",   label = "Mailbox",     module = "TOGBankClassic_UI_Mailbox"   },
	{ key = "browse",    label = "Guild Bank (Browse)", module = "TOGBankClassic_UI_Browse" },
}

-- Blizzard's BackdropTemplate mixin draws the backdrop with textures parented to the frame under
-- these names. They must NOT be faded here: SetBackdropColor already carries the alpha, and
-- multiplying a second SetAlpha on top would square it (0.5 rendering as 0.25). They are excluded
-- by name as well as by draw layer because the layer they sit on is a client-side detail this
-- addon cannot check from source.
local BACKDROP_PIECES = {
	"Center", "TopEdge", "BottomEdge", "LeftEdge", "RightEdge",
	"TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
}

--- The title every TOGBank window carries: the addon and its version, then the window's name --
--- "TOG Bank v1.5.0 - Requests". The Inventory window (the "main window") has always been
--- titled this way; the operator, 2026-09-11: "we should make the requests window 'look' like the
--- main window". One spelling, so the windows cannot drift apart on it.
---
--- BRAND-001 (operator, 2026-09-12): the addon is "TOG Bank" to players now -- the folder, the
--- TOC and every identifier keep TOGBankClassic ("you don't have to change the name in the
--- files anywhere"); only what a player reads changes. The version is shown as `d.d.d`: a
--- released client's Version is the packager's substitution of @project-version@, the WHOLE git
--- tag (`TOGBankClassic-v1.4.1`, see WIRE-SKEW-002), which would otherwise render as
--- "TOG Bank vTOGBankClassic-v1.4.1". A dev build has no such run of digits and shows its raw
--- placeholder, as FGI's status bar does.
---@param name string|nil the window's name; nil for the main window
---@return string
function TOGBankClassic_UI:WindowTitle(name)
	-- VERSION-TEXT-001: the ONE brand+version spelling (Constants.BrandVersion). This used to carry
	-- its own copy of the version extraction, which is how the title and `/togbank version` came to
	-- disagree about the same build.
	local base = TOGBankClassic_Constants.BrandVersion()
	if name and name ~= "" then return base .. " - " .. name end
	return base
end

--- SCROLLBAR-002: the thin 8px scrollbar every list window uses, IN THE GAP AceGUI CLEARS. The
--- ScrollFrame container pulls its scroll frame's right edge in by 20px while the bar is shown and
--- hangs its own bar OUTSIDE that edge (TOPLEFT at the frame's TOPRIGHT +4). Three windows carried
--- their own copy of this restyle and all three anchored the bar by its RIGHT edge at the frame's
--- right edge -- 8px INSIDE the content, over whatever was rightmost: the reopen button in the
--- Requests list (the operator's report), the last icon column on Inventory and Search. One helper,
--- anchored by the LEFT edge inside the 20px, over nothing. At +6 the operator's next look said
--- "it could use a few more px" -- the bar's thumb still read as touching the reopen button -- so
--- it sits at +10: the 8px bar ends at 18, still inside the gap.
---@param scroll table an AceGUI ScrollFrame widget
function TOGBankClassic_UI:ApplyThinScrollbar(scroll)
	local bar, sf = scroll and scroll.scrollbar, scroll and scroll.scrollframe
	if not (bar and sf) then return end
	bar:ClearAllPoints()
	bar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 10, -20)
	bar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 10, 20)
	bar:SetWidth(8)
	bar:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Vertical")
end

--- Applies the thin tooltip-style border to an AceGUI Frame widget.
--- Pass the AceGUI widget object (e.g. `window`), not its `.frame` child.
--- `alphaKey`, when given, also applies that window's stored transparency (ALPHA-001).
function TOGBankClassic_UI:ApplyThinBorder(widget, alphaKey)
	local frame = widget.frame or widget
	if not frame.SetBackdrop then return end
	frame:SetBackdrop(ThinFrameBackdrop)
	frame:SetBackdropColor(0, 0, 0, 1)
	frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
	if alphaKey then
		self:ApplyWindowAlpha(alphaKey, widget)
	end
end

--- Stored transparency for a window, 0 (invisible chrome) to 1 (opaque). Always a number in
--- range: an out-of-range or non-numeric saved value reads as fully opaque rather than making
--- a window disappear with no obvious cause.
function TOGBankClassic_UI:GetWindowAlpha(key)
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	local stored = db and db.global and db.global.windowAlpha and db.global.windowAlpha[key]
	if type(stored) ~= "number" or stored ~= stored then return 1 end
	if stored < 0 then return 0 end
	if stored > 1 then return 1 end
	return stored
end

--- Store a window's transparency and apply it immediately if that window exists.
function TOGBankClassic_UI:SetWindowAlpha(key, value)
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	if not (db and db.global) then return false end
	db.global.windowAlpha = db.global.windowAlpha or {}
	db.global.windowAlpha[key] = value
	self:ApplyWindowAlpha(key)
	return true
end

--- Resolve the live window for `key`, or nil. Only used by ApplyWindowAlpha.
local function liveWindow(key)
	for _, entry in ipairs(TOGBankClassic_UI.ALPHA_WINDOWS) do
		if entry.key == key then
			local module = _G[entry.module]
			return module and module.Window
		end
	end
	return nil
end

--- Paint a resolved alpha onto a window's chrome. Split out from ApplyWindowAlpha so the release
--- path can reset a frame to opaque without going through a stored setting.
local function paintChrome(widget, alpha)
	local frame = widget and (widget.frame or widget)
	if not (frame and frame.SetBackdropColor) then return false end

	-- SetBackdropColor alone cannot reach genuinely opaque, even at 1.0. The backdrop's bgFile
	-- (UI-DialogBox-Background, the parchment) carries its own per-pixel alpha channel, and
	-- SetBackdropColor MULTIPLIES over it -- so a half-transparent parchment pixel stays half
	-- transparent whatever alpha is passed. The fix, taken from the same feature in FGI: a solid
	-- black texture behind the backdrop at BACKGROUND sublevel -8, scaled by the same slider. Both
	-- layers move together, so 1.0 is really solid and lower values still let the scene through.
	if not frame.togOpaqueFill and frame.CreateTexture then
		local fill = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
		fill:SetAllPoints(frame)
		frame.togOpaqueFill = fill
	end
	if frame.togOpaqueFill then
		frame.togOpaqueFill:SetColorTexture(0, 0, 0, alpha)
	end

	frame:SetBackdropColor(0, 0, 0, alpha)
	frame:SetBackdropBorderColor(0.4, 0.4, 0.4, alpha)

	-- The title-bar header art: three OVERLAY textures created directly on the frame by AceGUI's
	-- Frame widget. The title TEXT is a FontString on a separate child frame and is untouched, so
	-- a near-transparent window still shows its name and stays draggable by the title.
	local skip = {}
	for _, piece in ipairs(BACKDROP_PIECES) do
		if frame[piece] then skip[frame[piece]] = true end
	end
	if frame.GetRegions then
		for _, region in ipairs({ frame:GetRegions() }) do
			if not skip[region] and region ~= frame.togOpaqueFill
				and region.GetDrawLayer and region.SetAlpha
				and region:GetObjectType() == "Texture" and region:GetDrawLayer() == "OVERLAY" then
				region:SetAlpha(alpha)
			end
		end
	end

	-- The status bar along the bottom. `statustext` is created ON the status background, so its
	-- parent is that background exactly -- AceGUI does not expose the background itself. Only its
	-- backdrop fades; the text is a child FontString and stays readable.
	local statusbg = widget.statustext and widget.statustext:GetParent()
	if statusbg and statusbg.SetBackdropColor then
		statusbg:SetBackdropColor(0.1, 0.1, 0.1, alpha)
		statusbg:SetBackdropBorderColor(0.4, 0.4, 0.4, alpha)
	end

	return true
end

--- Paint `key`'s stored transparency onto a window. `widget` is optional and exists for the
--- construction-time call, which happens before the module has stored `self.Window`.
--- @return boolean applied
function TOGBankClassic_UI:ApplyWindowAlpha(key, widget)
	widget = widget or liveWindow(key)
	return paintChrome(widget, self:GetWindowAlpha(key))
end

--- Reset a window's chrome to opaque immediately before releasing it back to AceGUI.
---
--- Not optional housekeeping. AceGUI's widget pool is shared by EVERY addon using the library, so
--- a released frame can be handed to someone else's `Create("Frame")` -- carrying our black
--- backing texture and our faded title art with it. `Requests` really does release and recreate
--- its window when banker status changes, so without this a guild officer toggling ranks could
--- leave a black slab across an unrelated addon's window.
function TOGBankClassic_UI:ClearWindowAlpha(widget)
	return paintChrome(widget, 1)
end

--- Re-apply every window's stored transparency to whichever windows currently exist.
function TOGBankClassic_UI:RefreshWindowAlpha()
	for _, entry in ipairs(self.ALPHA_WINDOWS) do
		self:ApplyWindowAlpha(entry.key)
	end
end

--- RECENTER-001: put every window back in the middle of the screen, now.
---
--- The operator, 2026-09-12: "make a button in settings>appearance to recenter the addon in the
--- middle of the screen. folks have it appearing off screen and they can't drag it." That is the
--- whole constraint -- the player CANNOT reach the title bar, so a fix that needs them to drag,
--- or to find a hidden command and then reload, is not a fix. `/togbank wipeframes` was both.
---
--- Works by DELETING `top`/`left` from the status table and calling AceGUI's own `ApplyStatus`,
--- whose else-branch is literally `frame:SetPoint("CENTER")` -- rather than anchoring the frame
--- here. Anchoring by hand would leave the stored position behind to be restored on the next
--- reload, and would duplicate a rule the library already owns. `width`/`height` are deliberately
--- kept: the window is lost, not mis-sized, and silently resizing it would be a second surprise.
---
--- Both tables are cleared because they are not always the same one. A window built before its
--- status table was attached reads `localstatus`, and clearing only the saved copy would recentre
--- it until the next drag wrote the old coordinates straight back.
--- MAILBOX-PERSIST-001 (operator 2026-09-13: "ensure the mail inbox window saves size/position and
--- persists through reload and open/close like the main window. use the same helper from the GUI
--- library, and if ... there isn't one, we need to ... open a contract with the library"): make an
--- AceGUI Frame remember its position AND size per character, under `key` in
--- `db.char.framePositions` -- AceGUI writes top/left/width/height into the table on every drag and
--- resize and reads them back through ApplyStatus, so there is nothing to save by hand. A saved
--- size under the floor (an older save, a smaller UI scale) is raised to it, because a status table
--- is applied as-is and a window narrower than its floor has nothing to drag. Without a db (a spec)
--- the defaults are applied directly. The work is the LIBRARY's `W:PersistWindow(widget, table,
--- opts)` (LibAceGUIWidgets MINOR 28, built for this ask on inbox thread 3ba9f0f7); this wrapper
--- only resolves the per-character slot, which the library cannot know. A library too old to carry
--- it gets the same rule spelled here. WINDOW-PERSIST-002: every window -- Inventory, Search,
--- Requests, Browse, Mailbox -- comes through here; none carries its own SetStatusTable line.
---@param window table AceGUI Frame
---@param key string framePositions key
---@param defW number default width
---@param defH number default height
---@param minW number|nil floor width, applied to the saved size and as the resize bound
---@param minH number|nil floor height
function TOGBankClassic_UI:PersistWindow(window, key, defW, defH, minW, minH)
	minW, minH = minW or 0, minH or 0
	defW, defH = math.max(defW, minW), math.max(defH, minH)
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	local positions = db and db.char and db.char.framePositions
	local W = self.Widgets
	if W and W.PersistWindow then
		if positions then positions[key] = positions[key] or {} end
		return W:PersistWindow(window, positions and positions[key] or nil,
			{ width = defW, height = defH, minWidth = minW, minHeight = minH })
	end
	if positions then
		positions[key] = positions[key] or { width = defW, height = defH }
		local saved = positions[key]
		if (saved.width or 0) < minW then saved.width = minW end
		if (saved.height or 0) < minH then saved.height = minH end
		window:SetStatusTable(saved)
	else
		window:SetWidth(defW)
		window:SetHeight(defH)
	end
	if minW > 0 and window.frame.SetResizeBounds then window.frame:SetResizeBounds(minW, minH) end
	return positions and positions[key] or nil
end

---@return number windows the number of windows that were moved or had a stored position cleared
function TOGBankClassic_UI:RecenterWindows()
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	local positions = db and db.char and db.char.framePositions
	local moved = 0
	for _, entry in ipairs(self.ALPHA_WINDOWS) do
		local touched = false
		local stored = positions and positions[entry.key]
		if stored and (stored.top or stored.left) then
			stored.top, stored.left = nil, nil
			touched = true
		end
		local widget = liveWindow(entry.key)
		if widget and widget.ApplyStatus then
			local live = widget.status or widget.localstatus
			if live and (live.top or live.left) then
				live.top, live.left = nil, nil
				touched = true
			end
			-- ONLY when something was actually cleared. AceGUI's ApplyStatus re-applies the SIZE as
			-- well as the position -- `SetWidth(status.width or 700)`, `SetHeight(status.height or
			-- 500)` -- so calling it on a window that needed no moving RESIZES it. The Mail Viewer
			-- and Donations windows are in ALPHA_WINDOWS but never call SetStatusTable (the Mailbox
			-- window does, since MAILBOX-PERSIST-001), so AceGUI gives them an empty `localstatus`
			-- with no width or height: pressing Recenter with one of those open would have snapped
			-- it to 700x500 for no reason.
			if touched then widget:ApplyStatus() end
		end
		if touched then moved = moved + 1 end
	end
	return moved
end

-- HITBOX-001: AceGUI Frame's bottom resize strip (sizer_s) and corner (sizer_se) are
-- mouse-enabled children that sit at the parent frame level + 1. The Frame is a
-- FULLSCREEN_DIALOG that gets raised to a high level when it is SHOWN, so a frame level
-- captured at construction time (window.frame:GetFrameLevel() + N before :Show()) goes stale:
-- once shown, the sizer rides up with the parent and wins the Z-fight over any bottom-row
-- button in its overlap band — the dead "bottom half" players see on the Close/help/etc. icons.
-- Re-assert the lift against the LIVE parent level on every show. `buttons` is a list of the
-- bottom-row Frame/Button regions to keep above the sizers; AceGUI's own Close button (created
-- by the library, located here by its label) is detected and lifted too.
function TOGBankClassic_UI:KeepAboveResizeSizers(window, buttons)
	local parent = window and window.frame
	if not parent then return end

	-- Locate AceGUI's own bottom Close button (same Z-fight, created by the library).
	local closeButton
	if parent.GetChildren then
		for _, child in ipairs({ parent:GetChildren() }) do
			if child.GetText and (child:GetText() == CLOSE or child:GetText() == "Close") then
				closeButton = child
				break
			end
		end
	end

	-- Store the current bottom-row set ON the frame, so the single OnShow hook below always
	-- lifts the latest buttons. Requests releases/reacquires its window (banker-status change)
	-- and AceGUI pools frames, so a per-call closure could capture recycled buttons and the hook
	-- could stack across reuse; reading frame fields + a hook-once guard avoids both.
	parent.togHitboxButtons = buttons
	parent.togHitboxClose = closeButton

	local function lift()
		local level = parent:GetFrameLevel() + 10
		-- pairs (not ipairs) so optional/conditional buttons stored as nil holes are skipped.
		if parent.togHitboxButtons then
			for _, b in pairs(parent.togHitboxButtons) do
				if b.SetFrameLevel then
					b:SetFrameLevel(level)
				end
			end
		end
		if parent.togHitboxClose then
			parent.togHitboxClose:SetFrameLevel(level)
		end
	end

	lift()
	-- Fires on every Show() (windows are persistent: hidden on close, re-shown on open). Re-lift
	-- immediately and again on the next frame tick, since the FULLSCREEN_DIALOG frame's final
	-- level may not be assigned until just after OnShow runs. Hook once per frame.
	if not parent.togHitboxHooked then
		parent.togHitboxHooked = true
		parent:HookScript("OnShow", function()
			lift()
			if C_Timer and C_Timer.After then
				C_Timer.After(0, lift)
			end
		end)
	end
end

-- ---------------------------------------------------------------------------------------------
-- WINDOW CHROME: the bottom row every TOGBank window shares, spelled once.
-- ---------------------------------------------------------------------------------------------
-- Right to left from the frame's bottom-right corner (AceGUI's own Close button spans x -127..-27):
-- the help "?" at -133 (24px, bottom 15), the settings gear at -165 (20px, bottom 17 so its centre
-- lines up with the "?"'s), then whatever the window adds of its own (Search's page arrows, the
-- Requests cluster), and the status bar's right edge meets the leftmost of them at a 6px gap.
--
-- WINDOW-CHROME-001 (SYNCED-001's follow-up, "make the requests window look like the main
-- window"): the title and the status bar were shared already; the "?" block was still written out
-- in Inventory, Requests, Search and Browse, the gear in Inventory and Browse, and two of the four
-- pinned the status bar's right edge with a hand-summed constant (-195, -210) that had to be
-- re-summed whenever an icon moved. Two of the copies cached their icons on the frame because
-- AceGUI pools frames and a window that comes back grows a second set under the first; the other
-- two had not learned that. One helper: the icons are built here, cached on the frame, the bar
-- ends at the leftmost icon BY ANCHOR (never by arithmetic), and the whole row is lifted above the
-- resize sizers (HITBOX-001). The Requests cluster keeps hanging left of `anchor` exactly as before.
TOGBankClassic_UI.CHROME = {
	HELP_SIZE = 24, HELP_X = -133, HELP_Y = 15,
	GEAR_SIZE = 20, GEAR_X = -165, GEAR_Y = 17,
	STATUS_LEFT = 15, STATUS_BOTTOM = 15, STATUS_GAP = 6,
	HELP_TEXTURE = "Interface\\Common\\help-i",
	GEAR_TEXTURE = "Interface\\Icons\\Trade_Engineering",
	GEAR_TOOLTIP = "Open the addon options panel (banker/scan configuration, appearance, debug logging, minimap button).",
}

--- Put the status bar's right edge at `anchor`'s left, the one rule every window follows. Without
--- `anchor` the window's own leftmost chrome icon is used (DressWindow recorded it); the Requests
--- cluster passes its own leftmost while it is on the window and hands the edge back on leaving.
---@param window table AceGUI Frame
---@param anchor table|nil the frame the bar ends at
function TOGBankClassic_UI:AnchorStatusBar(window, anchor)
	local C = self.CHROME
	local statusbg = window and window.statustext and window.statustext:GetParent()
	anchor = anchor or (window and window.togChrome and window.togChrome.anchor)
	if not (statusbg and anchor) then return false end
	statusbg:ClearAllPoints()
	statusbg:SetPoint("BOTTOMLEFT",  window.frame, "BOTTOMLEFT", C.STATUS_LEFT, C.STATUS_BOTTOM)
	statusbg:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMLEFT", -C.STATUS_GAP, 0)
	return true
end

--- The shared bottom row on an AceGUI Frame. Call once per DrawWindow, after the status bar is
--- attached and after any of the window's OWN bottom icons exist.
---
--- `opts.help` fills the CURRENT GameTooltip (owner set, lines cleared; Show follows) -- each
--- window's text is its own. `opts.onHelpEnter`, when given, runs first (the Guild Bank window
--- stops its breath and marks the tab read). `opts.settings` is the window module the gear
--- reopens after Blizzard's options panel takes focus: the panel can close other top-level frames
--- as it opens (this window is on UISpecialFrames through the controller), so the click remembers
--- whether the window was open and puts it back on the next frame; without it there is no gear.
--- `opts.extra` are further bottom-row frames the window built itself, LEFTMOST LAST -- the status
--- bar ends at the last one.
---
--- Returns the chrome record, also stored as `window.togChrome`: `help`, `settings` (nil without
--- one), `icons` (help, gear, extras -- the lift set, and what Requests' ShowCluster reads as
--- `window.togBottomIcons`) and `anchor`, the leftmost.
---@param window table AceGUI Frame
---@param opts table { help = fn, onHelpEnter = fn|nil, settings = table|nil, extra = table|nil }
---@return table chrome
function TOGBankClassic_UI:DressWindow(window, opts)
	local C = self.CHROME
	local frame = window.frame
	opts = opts or {}

	-- The "?" -- cached on the frame (AceGUI pools frames; a second icon on a frame that came back
	-- would sit under the first). The tooltip closure is re-pointed on every call so a pooled frame
	-- never keeps a previous window's help text.
	local help = frame.togChromeHelp
	if not help then
		help = CreateFrame("Frame", nil, frame)
		help:SetSize(C.HELP_SIZE, C.HELP_SIZE)
		help:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", C.HELP_X, C.HELP_Y)
		help:EnableMouse(true)
		local tex = help:CreateTexture(nil, "OVERLAY")
		tex:SetAllPoints(help)
		tex:SetTexture(C.HELP_TEXTURE)
		help:SetScript("OnLeave", function() TOGBankClassic_UI:HideTooltip() end)
		frame.togChromeHelp = help
	end
	help:SetScript("OnEnter", function(f)
		if opts.onHelpEnter then opts.onHelpEnter() end
		GameTooltip:SetOwner(f, "ANCHOR_TOP")
		GameTooltip:ClearLines()
		if opts.help then opts.help() end
		GameTooltip:Show()
	end)
	help:Show()

	-- The gear -- 20x20 to match FastGuildInvite's, the Trade_Engineering icon cropped to
	-- (0.08-0.92) because Blizzard's icon files carry ~8% transparent padding and the gear would
	-- otherwise float in the middle of its button. Only for a window that asked (Inventory, Browse).
	local gear = frame.togChromeGear
	if opts.settings then
		if not gear then
			gear = CreateFrame("Button", nil, frame)
			gear:SetSize(C.GEAR_SIZE, C.GEAR_SIZE)
			gear:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", C.GEAR_X, C.GEAR_Y)
			gear:EnableMouse(true)
			gear:SetNormalTexture(C.GEAR_TEXTURE)
			gear:SetPushedTexture(C.GEAR_TEXTURE)
			local normal = gear:GetNormalTexture()
			if normal then normal:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
			local pushed = gear:GetPushedTexture()
			if pushed then pushed:SetTexCoord(0.08, 0.92, 0.08, 0.92); pushed:SetVertexColor(0.7, 0.7, 0.7) end
			-- 2px past the visible button, so the click target has the feel of a 24px icon.
			gear:SetHitRectInsets(-2, -2, -2, -2)
			gear:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
			gear:SetScript("OnEnter", function(f)
				GameTooltip:SetOwner(f, "ANCHOR_TOP")
				GameTooltip:ClearLines()
				GameTooltip:AddLine("TOGBankClassic Settings")
				GameTooltip:AddLine(C.GEAR_TOOLTIP, 0.9, 0.9, 0.9, true)
				GameTooltip:Show()
			end)
			gear:SetScript("OnLeave", function() TOGBankClassic_UI:HideTooltip() end)
			frame.togChromeGear = gear
		end
		local module = opts.settings
		gear:SetScript("OnClick", function()
			if not (TOGBankClassic_Options and TOGBankClassic_Options.Open) then return end
			local wasOpen = module.isOpen
			TOGBankClassic_Options:Open()
			if wasOpen then
				C_Timer.After(0, function()
					if not module.isOpen then module:Open() end
				end)
			end
		end)
		gear:Show()
	elseif gear then
		gear:Hide()
		gear = nil
	end

	local icons = { help }
	if gear then icons[#icons + 1] = gear end
	for _, f in ipairs(opts.extra or {}) do icons[#icons + 1] = f end

	local chrome = { help = help, settings = gear, icons = icons, anchor = icons[#icons] }
	window.togChrome = chrome
	window.togBottomIcons = icons
	self:AnchorStatusBar(window, chrome.anchor)
	self:KeepAboveResizeSizers(window, icons)
	return chrome
end

function TOGBankClassic_UI:Init()
	TOGBankClassic_UI_Minimap:Init()
	TOGBankClassic_UI_Inventory:Init()
	TOGBankClassic_UI_Donations:Init()
	TOGBankClassic_UI_Requests:Init()
	TOGBankClassic_UI_Search:Init()
	TOGBankClassic_UI_Mail:Init()
end

function TOGBankClassic_UI:Controller()
	local controller = CreateFrame("Frame", "TOGBankClassic", UIParent)
	controller:SetScript("OnHide", function()
		TOGBankClassic_UI_Inventory:Close()
		-- BROWSE-001: Escape closes the Guild Bank window the same way.
		if TOGBankClassic_UI_Browse and TOGBankClassic_UI_Browse.isOpen then TOGBankClassic_UI_Browse:Close() end
	end)
	--insert to global escape table
	table.insert(UISpecialFrames, "TOGBankClassic")
end

--- Click / drag on an item slot drawn by DrawItem. `widget` is the AceGUI Icon carrying `.link`;
--- it used to be named `self`, shadowing the module's own `self` (luacheck W412) for no reason.
function TOGBankClassic_UI:EventHandler(widget, event, button)
	if event == "OnClick" then
		-- HIDE-001: slots take right clicks now (the banker's hide/show); a right click that reaches
		-- this default handler must not pick the item up.
		if button == "RightButton" then return end
		if IsShiftKeyDown() then
			ChatEdit_InsertLink(widget.link)
		elseif IsControlKeyDown() then
			if widget.link then
				DressUpItemLink(widget.link)
			end
		else
			if widget.link then
				PickupItem(widget.link)
			end
		end
	end
	if event == "OnDragStart" then
		if widget.link then
			PickupItem(widget.link)
		end
	end
end

function TOGBankClassic_UI:DrawItem(item, parent, size, height, imageSize, imageHeight, labelXOffset, labelYOffset)
	if not size then
		size = 40
	end

	if not height then
		height = 40
	end

	if not imageSize then
		imageSize = 40
	end

	if not imageHeight then
		imageHeight = 40
	end

	if not labelXOffset then
		labelYOffset = 0
	end

	if not labelYOffset then
		labelYOffset = 0
	end

	local slot = TOGBankClassic_UI:Create("Icon")
	local label = slot.label
	local image = slot.image
	local frame = slot.frame

	image:SetPoint("TOP", image:GetParent(), "TOP", 0, 0)
	if item.Count > 1 then
		slot:SetLabel(item.Count)
		--format the label
		local fontName, fontHeight = label:GetFont()
		label:SetFont(fontName, fontHeight, "OUTLINE")
		--clear the set points
		label:ClearAllPoints()
		label:SetPoint("BOTTOMRIGHT", label:GetParent(), "BOTTOMRIGHT", labelXOffset, labelYOffset) --use this to position label
		label:SetHeight(14)
		label:SetShadowColor(0, 0, 0)
	else
		slot:SetLabel(" ")
	end

	-- Generate link on-demand if needed (synchronous from cache if available)
	if item.ID and not item.Link then
		TOGBankClassic_Guild:ReconstructItemLink(item)
	end

	-- Icon should already be populated in item.Info
	if item.Info and item.Info.icon then
		slot:SetImage(item.Info.icon)
	end
	slot:SetImageSize(imageSize, imageHeight)
	slot:SetWidth(size)
	slot:SetHeight(height)

	-- Always register OnEnter/OnLeave so items without a link at draw time (e.g. mail
	-- consumables whose link is still being reconstructed async) still show tooltips.
	-- The callback attempts a lazy reconstruction at hover time; if that also fails it
	-- falls back to a plain-text tooltip from item.Info.name.
	if item.ID or item.Link then
		slot:SetCallback("OnEnter", function()
			local link = item.Link
			if not link and item.ID then
				TOGBankClassic_Guild:ReconstructItemLink(item)
				link = item.Link
			end
			if link then
				TOGBankClassic_UI:ShowItemTooltip(link, slot.tooltipLines)
			elseif item.Info and item.Info.name then
				GameTooltip:SetOwner(WorldFrame, "ANCHOR_CURSOR")
				GameTooltip:SetText(item.Info.name, 1, 1, 1)
				GameTooltip:Show()
			end
		end)
		slot:SetCallback("OnLeave", function()
			TOGBankClassic_UI:HideTooltip()
		end)
	end

	-- HIDE-001: both buttons reach OnClick (AceGUI's Icon registers none, so a Button's default is
	-- the left button only); the callback's third argument says which.
	frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	if item.Link then
		--handle on click or drag
		slot:SetCallback("OnClick", function(self, event, button)
			TOGBankClassic_UI:EventHandler(self, event, button)
		end)
		frame:RegisterForDrag("LeftButton")
		frame:SetScript("OnDragStart", function(_)
			TOGBankClassic_UI:EventHandler(slot, "OnDragStart")
		end)
	end

	slot.info = item.Info
	slot.link = item.Link

	--border highlight
	local border = frame:CreateTexture(nil, "OVERLAY")
	border:SetAllPoints(image)
	border:SetTexCoord(0, 0, 0, 1, 1, 0, 1, 1)
	border:SetBlendMode("BLEND")
	border:SetTexture("Interface\\Common\\WhiteIconFrame")
	-- Set border color based on rarity. item.Info.rarity may be nil for uncached remote gear.
	local rarity = item.Info and item.Info.rarity
	if not rarity and item.Link then
		-- Sync fallback: item may have entered the cache between GetItems and draw time.
		local _, _, r2 = GetItemInfo(item.Link)
		rarity = r2
	end
	if rarity and rarity >= 1 then
		local r, g, b = GetItemQualityColor(rarity)
		border:SetVertexColor(r, g, b)
	elseif item.Link then
		-- Async fallback: not cached yet — update border once WoW loads the item.
		local itemObj = Item:CreateFromItemID(item.ID)
		if itemObj then
			pcall(function()
				itemObj:ContinueOnItemLoad(function()
					local _, _, asyncRarity = GetItemInfo(item.Link)
					if asyncRarity and asyncRarity >= 1 and border:IsObjectType("Texture") then
						local r, g, b = GetItemQualityColor(asyncRarity)
						border:SetVertexColor(r, g, b)
					end
				end)
			end)
		end
	end

	slot.border = border

	-- HIDE-001: a row the banker keeps from the guild (`item.Hidden`, only ever set by the banker's
	-- own tab) is drawn greyed with a red "not ready" badge -- Blizzard's own ReadyCheck-NotReady,
	-- verified in the Era tree -- so it reads as "in the bag, not on offer". The badge is created
	-- only when needed; Icon widgets are pooled by AceGUI, so an existing badge is reused and hidden
	-- when the pooled slot next draws a visible item.
	if item.Hidden then
		image:SetDesaturated(true)
		local badge = frame.togHiddenBadge
		if not badge then
			badge = frame:CreateTexture(nil, "OVERLAY", nil, 2)
			badge:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
			badge:SetSize(14, 14)
			badge:SetPoint("TOPRIGHT", image, "TOPRIGHT", 2, 2)
			frame.togHiddenBadge = badge
		end
		badge:Show()
		-- Self-audit 2026-09-12: the Icon pool is shared with every addon and the Inventory tab
		-- releases its slots on every reload. Handed back grey with the badge up, this Icon would
		-- come out that way in whoever acquires it next. Undo both on release (AceGUI wipes the
		-- callback with the widget, so this is per acquire, not per frame).
		slot:SetCallback("OnRelease", function(widget)
			widget.image:SetDesaturated(false)
			if widget.frame.togHiddenBadge then widget.frame.togHiddenBadge:Hide() end
		end)
	else
		image:SetDesaturated(false)
		if frame.togHiddenBadge then frame.togHiddenBadge:Hide() end
	end

	local addChildStart = GetTime()
	parent:AddChild(slot)
	local addChildTime = GetTime() - addChildStart
	if addChildTime > 0.01 then
		TOGBankClassic_Output:Debug("UI", "DRAW", "AddChild(slot) took %.3fs for ID=%d", addChildTime, item.ID or 0)
	end

	return slot
end

--- HIDDEN-TEXT-001 (self-audit 5476e257 F2, agreed by Peer Review db06c629): every word the two
--- windows say about a banker's OWN hidden rows, once. The Inventory window's own tab (HIDE-001)
--- and the Guild Bank window's Browse tab (HIDE-003) describe the same row, and each carried its
--- own copy of these strings -- so a wording change in one left the other describing the same
--- item differently. Both windows read this table; the spec pins that their tooltip lines for a
--- row are these very entries (identity), so a fresh copy cannot appear without failing it.
--- Tooltip entries are `{ { text, r, g, b } }` as ShowItemTooltip / DrawItem take them; the
--- notices are format strings taking the item's name.
TOGBankClassic_UI.HIDDEN_TEXT = {
	tooltipSoulbound = { { "Hidden from the guild -- soulbound (Bank settings: Hide soulbound items)", 1, 0.3, 0.3 } },
	tooltipHidden    = { { "Hidden from the guild -- right-click to show it", 1, 0.3, 0.3 } },
	tooltipShown     = { { "Right-click to hide this item from the guild", 0.6, 0.6, 0.6 } },
	noticeSoulbound  = "%s is hidden because it is soulbound -- untick 'Hide soulbound items from the guild' in the Bank settings to show it.",
	noticeHidden     = "%s is now hidden from the guild -- right-click it again to show it.",
	noticeShown      = "%s is visible to the guild again.",
	statusHidden     = "%s is hidden from the guild -- right-click it to show it again.",
}

--- The tooltip lines for one of the banker's own rows: which of the three the row's state picks.
---@param hidden boolean the row is on the hidden list
---@param why string|nil Bank:HiddenReason's answer for a hidden row ("soulbound" or "manual")
---@return table lines one of the HIDDEN_TEXT tooltip entries, by identity
function TOGBankClassic_UI:HiddenTooltipLines(hidden, why)
	local T = self.HIDDEN_TEXT
	if hidden and why == "soulbound" then return T.tooltipSoulbound end
	if hidden then return T.tooltipHidden end
	return T.tooltipShown
end

--- `extraLines` (HIDE-001): optional `{ { text, r, g, b }, ... }` appended under the item's own
--- tooltip -- the banker's "hidden from the guild / right-click to hide" hint.
function TOGBankClassic_UI:ShowItemTooltip(link, extraLines)
	if not link then
		return
	end

	-- Throttle tooltip updates to prevent performance issues
	local now = debugprofilestop()
	if self.currentTooltipLink == link and (now - self.tooltipThrottle) < self.TOOLTIP_THROTTLE_MS then
		return
	end

	self.tooltipThrottle = now
	self.currentTooltipLink = link

	GameTooltip:SetOwner(WorldFrame, "ANCHOR_CURSOR")
	GameTooltip:SetHyperlink(link)
	for _, line in ipairs(extraLines or {}) do
		GameTooltip:AddLine(line[1], line[2], line[3], line[4], true)
	end
	GameTooltip:Show()
end

function TOGBankClassic_UI:HideTooltip()
	self.currentTooltipLink = nil
	GameTooltip:Hide()
	GameTooltip_SetDefaultAnchor(GameTooltip, UIParent)
end

-- AttachTooltip(target, anchor, title, lines)
--   target: AceGUI widget (has SetCallback + .frame) OR raw frame (CreateFrame).
--   anchor: GameTooltip anchor string, e.g. "ANCHOR_RIGHT", "ANCHOR_TOP", "ANCHOR_BOTTOM".
--           Defaults to "ANCHOR_RIGHT".
--   title:  string shown as the first line in default-yellow tooltip title style.
--   lines:  optional array of body lines (each shown gray, wrapped). Each entry is
--           either a plain string OR a {text, r, g, b, wrap} table for custom colour.
--
-- Behaviour:
--   - Auto-detects AceGUI vs raw frame and wires OnEnter/OnLeave via the right API.
--   - GameTooltip:SetOwner is called on the trigger's .frame (AceGUI) or the trigger
--     itself (raw frame) so the tooltip anchors visually where the cursor is.
--   - OnLeave delegates to TOGBankClassic_UI:HideTooltip() so the default-anchor reset
--     matches the rest of the addon.
--
-- Use this for ALL non-item tooltips. The pattern of manually calling
-- GameTooltip:SetOwner / AddLine / Show is being phased out — prefer this helper
-- so adding new tooltips is one call instead of a 5-line scriptlet.
-- HELPNOTE-001: append the officer-authored note for a window to the bottom of the
-- CURRENT GameTooltip, if one is set. windowKey: "inventory" / "search" / "requests".
-- Read at hover time so it always reflects the latest synced value.
function TOGBankClassic_UI:AppendGuildHelpNote(windowKey)
	local note = TOGBankClassic_Guild and TOGBankClassic_Guild.GetHelpNote
		and TOGBankClassic_Guild:GetHelpNote(windowKey)
	if note and note ~= "" then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("|cffffd100Guild Note:|r", 1, 1, 1, false)
		GameTooltip:AddLine(note, 0.9, 0.9, 0.9, true)
	end
end

-- noteWindowKey (optional): when set, AppendGuildHelpNote(noteWindowKey) runs just
-- before the tooltip is shown so the officer note is appended at the bottom.
function TOGBankClassic_UI:AttachTooltip(target, anchor, title, lines, noteWindowKey)
	if not target then return end
	local anchorFrame = target.frame or target
	local resolvedAnchor = anchor or "ANCHOR_RIGHT"

	local function onEnter()
		GameTooltip:SetOwner(anchorFrame, resolvedAnchor)
		GameTooltip:ClearLines()
		if title then GameTooltip:AddLine(title) end
		if lines then
			for _, line in ipairs(lines) do
				if type(line) == "string" then
					GameTooltip:AddLine(line, 0.9, 0.9, 0.9, true)
				elseif type(line) == "table" then
					GameTooltip:AddLine(
						line[1] or "",
						line[2] or 0.9, line[3] or 0.9, line[4] or 0.9,
						line[5] ~= false
					)
				end
			end
		end
		if noteWindowKey then
			TOGBankClassic_UI:AppendGuildHelpNote(noteWindowKey)
		end
		GameTooltip:Show()
	end
	local function onLeave()
		TOGBankClassic_UI:HideTooltip()
	end

	if type(target.SetCallback) == "function" then
		target:SetCallback("OnEnter", onEnter)
		target:SetCallback("OnLeave", onLeave)
	else
		target:SetScript("OnEnter", onEnter)
		target:SetScript("OnLeave", onLeave)
	end
end

function TOGBankClassic_UI:OnInsertLink(link)
	if TOGBankClassic_UI_Search.searchField and TOGBankClassic_UI_Search.searchField.editbox:HasFocus() then
		TOGBankClassic_UI_Search.SearchText = link
		TOGBankClassic_UI_Search:DrawContent()
	end
end

-- Clamp a frame to stay within screen boundaries
function TOGBankClassic_UI:ClampFrameToScreen(frame)
	if not frame then
		return
	end

	-- Get the actual frame object (handle both AceGUI widgets and raw frames)
	local actualFrame = frame.frame or frame
	if not actualFrame or not actualFrame.GetRect then
		return
	end

	-- Get frame dimensions
	local left, bottom, width, height = actualFrame:GetRect()
	if not left or not bottom or not width or not height then
		return
	end

	local right = left + width
	local top = bottom + height

	-- Get screen dimensions
	local screenWidth = UIParent:GetWidth()
	local screenHeight = UIParent:GetHeight()

	-- Calculate adjustments needed
	local xOffset = 0
	local yOffset = 0

	-- Check horizontal bounds
	if left < 0 then
		xOffset = -left
	elseif right > screenWidth then
		xOffset = screenWidth - right
	end

	-- Check vertical bounds
	if bottom < 0 then
		yOffset = -bottom
	elseif top > screenHeight then
		yOffset = screenHeight - top
	end

	-- Apply adjustments if needed
	if xOffset ~= 0 or yOffset ~= 0 then
		actualFrame:ClearAllPoints()
		actualFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left + xOffset, bottom + yOffset)
	end
end

-- ---------------------------------------------------------------------------------------------
-- SEARCH-005: ONE search box for the whole addon, built on LibAceGUIWidgets.
-- ---------------------------------------------------------------------------------------------
-- The operator, 2026-09-11: "we should use the search bar look with the icon from libaceGUIwidgets
-- for it, maybe even plumb the library in now ... now might be a good time to centralize the
-- layout/look." Before this the Search window and the Mailbox window each hand-rolled an AceGUI
-- EditBox with a label above it, and the Requests window had no text search at all.
--
-- `LibAceGUIWidgets-1.0` is the TOG suite's shared toolkit (Dibs, FastGuildInvite) and a declared
-- dependency of this addon as of v1.5.0 (both TOCs, .pkgmeta). Its `CreateSearchBox` is Blizzard's
-- own `SearchBoxTemplate` -- magnifier icon, greyed placeholder, clear-X -- as a RAW frame for a
-- manual layout; every window here lays out through AceGUI, so this file wraps it as an AceGUI
-- widget type, `TOGBankSearchBox`, that drops into a Table or Flow layout like any other widget.
-- Registered here, once, so the three windows cannot drift apart in look or behaviour.
--
-- Feature-detected against an OLDER library copy, as the suite's consumers do: `CreateSearchBox`
-- and `SearchMatch` are MINOR 9. With an older copy the box is built from the same template
-- directly (it is one CreateFrame) and the matcher degrades to a plain substring test.
TOGBankClassic_UI.Widgets = LibStub("LibAceGUIWidgets-1.0", true)

--- Tokenised, case-insensitive "does every word of `query` appear somewhere in these fields".
--- An empty query matches everything. The library's rule; the fallback is the one-token case.
---@param query string|nil
---@vararg string|number|nil the haystack fields
---@return boolean
function TOGBankClassic_UI:SearchMatch(query, ...)
	local W = self.Widgets
	if W and W.SearchMatch then return W:SearchMatch(query, ...) end
	if not query or query == "" then return true end
	local parts = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if v ~= nil then parts[#parts + 1] = tostring(v) end
	end
	return table.concat(parts, " "):lower():find(tostring(query):lower(), 1, true) ~= nil
end

do
	local Type, Version = "TOGBankSearchBox", 1
	local AceGUI = TOGBankClassic_UI

	local methods = {
		OnAcquire = function(self)
			self:SetHeight(24)
			self:SetWidth(200)
			self:SetDisabled(false)
			self:SetText("")
			self:SetPlaceholder(nil)
			self:SetMaxLetters(0)
		end,
		OnRelease = function(self)
			self:SetText("")
			self.editbox:ClearFocus()
		end,
		--- Programmatic: does NOT fire OnTextChanged, exactly as AceGUI's EditBox behaves, so a
		--- window that writes the query back into its own box on redraw cannot loop.
		SetText = function(self, text)
			self._settingText = true
			self.editbox:SetText(text or "")
			self._settingText = nil
		end,
		GetText = function(self) return self.editbox:GetText() or "" end,
		--- The greyed instruction shown while the box is empty; nil restores the template's "Search".
		SetPlaceholder = function(self, text)
			local ins = self.editbox.Instructions
			if ins then ins:SetText(text or (SEARCH or "Search")) end
		end,
		SetMaxLetters = function(self, n) self.editbox:SetMaxLetters(n or 0) end,
		SetDisabled = function(self, disabled)
			self.disabled = disabled
			if disabled then
				self.editbox:EnableMouse(false)
				self.editbox:ClearFocus()
			else
				self.editbox:EnableMouse(true)
			end
		end,
		SetFocus = function(self) self.editbox:SetFocus() end,
		ClearFocus = function(self) self.editbox:ClearFocus() end,
		HasFocus = function(self) return self.editbox:HasFocus() end,
	}

	local function Constructor()
		local frame = CreateFrame("Frame", nil, UIParent)
		frame:Hide()

		local W = TOGBankClassic_UI.Widgets
		local editbox
		if W and W.CreateSearchBox then
			editbox = W:CreateSearchBox(frame, {})
		else
			editbox = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
			editbox:SetAutoFocus(false)
		end
		-- The template draws its own art; the box fills the widget's frame with a 2px inset so two
		-- boxes side by side in a table row do not touch.
		editbox:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -1)
		editbox:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 1)

		local widget = { frame = frame, editbox = editbox, type = Type }
		for name, fn in pairs(methods) do widget[name] = fn end

		-- Hooked, not replaced: the template's own OnTextChanged runs the clear button and the
		-- placeholder. Fires for the user's TYPING only; the widget's own SetText is silent.
		editbox:HookScript("OnTextChanged", function(eb, userInput)
			if widget._settingText or not userInput then return end
			widget:Fire("OnTextChanged", eb:GetText() or "")
		end)
		-- The clear-X empties the box with a programmatic SetText("") (ClearButtonMixin:OnClick in
		-- the template), which the hook above rightly ignores -- so the clear is reported from the
		-- button itself, after the template has emptied the box. Peer Review, self-audit F6: this
		-- used to be `userInput or text == ""` on OnTextChanged, which would also have reported any
		-- other code's SetText("") on the raw box as a clear.
		if editbox.clearButton and editbox.clearButton.HookScript then
			editbox.clearButton:HookScript("OnClick", function()
				widget:Fire("OnTextChanged", editbox:GetText() or "")
			end)
		end
		editbox:HookScript("OnEnterPressed", function(eb)
			widget:Fire("OnEnterPressed", eb:GetText() or "")
		end)
		editbox:HookScript("OnEnter", function() widget:Fire("OnEnter") end)
		editbox:HookScript("OnLeave", function() widget:Fire("OnLeave") end)

		return AceGUI:RegisterAsWidget(widget)
	end

	AceGUI:RegisterWidgetType(Type, Constructor, Version)
end
