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

--- Applies the thin tooltip-style border to an AceGUI Frame widget.
--- Pass the AceGUI widget object (e.g. `window`), not its `.frame` child.
function TOGBankClassic_UI:ApplyThinBorder(widget)
	local frame = widget.frame or widget
	if not frame.SetBackdrop then return end
	frame:SetBackdrop(ThinFrameBackdrop)
	frame:SetBackdropColor(0, 0, 0, 1)
	frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
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
function TOGBankClassic_UI:AttachTooltip(target, anchor, title, lines)
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
