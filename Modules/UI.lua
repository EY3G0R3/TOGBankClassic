TOGBankClassic_UI = LibStub("AceGUI-3.0")

-- Tooltip throttling to prevent performance issues
TOGBankClassic_UI.tooltipThrottle = 0
TOGBankClassic_UI.TOOLTIP_THROTTLE_MS = 50  -- 50ms between tooltip updates
TOGBankClassic_UI.currentTooltipLink = nil

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
	end)
	--insert to global escape table
	table.insert(UISpecialFrames, "TOGBankClassic")
end

function TOGBankClassic_UI:EventHandler(self, event, ...)
	if event == "OnClick" then
		if IsShiftKeyDown() then
			ChatEdit_InsertLink(self.link)
		elseif IsControlKeyDown() then
			if self.link then
				DressUpItemLink(self.link)
			end
		else
			if self.link then
				PickupItem(self.link)
			end
		end
	end
	if event == "OnDragStart" then
		if self.link then
			PickupItem(self.link)
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
				TOGBankClassic_UI:ShowItemTooltip(link)
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

	if item.Link then
		--handle on click or drag
		slot:SetCallback("OnClick", function(self, event)
			TOGBankClassic_UI:EventHandler(self, event)
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
	local addChildStart = GetTime()
	parent:AddChild(slot)
	local addChildTime = GetTime() - addChildStart
	if addChildTime > 0.01 then
		TOGBankClassic_Output:Debug("UI", "DRAW", "AddChild(slot) took %.3fs for ID=%d", addChildTime, item.ID or 0)
	end

	return slot
end

function TOGBankClassic_UI:ShowItemTooltip(link)
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
