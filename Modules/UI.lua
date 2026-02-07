TOGBankClassic_UI = LibStub("AceGUI-3.0")

-- Tooltip throttling to prevent performance issues
TOGBankClassic_UI.tooltipThrottle = 0
TOGBankClassic_UI.TOOLTIP_THROTTLE_MS = 50  -- 50ms between tooltip updates
TOGBankClassic_UI.currentTooltipLink = nil

function TOGBankClassic_UI:Init()
	TOGBankClassic_UI_Minimap:Init()
	TOGBankClassic_UI_Inventory:Init()
	TOGBankClassic_UI_Donations:Init()
	TOGBankClassic_UI_Requests:Init()
	TOGBankClassic_UI_Search:Init()
	TOGBankClassic_UI_Mail:Init()
end

function TOGBankClassic_UI:Controller()
	--this is used to process escape to exit events
	local controller = CreateFrame("Frame", "TOGBankClassic", UIParent)
	controller:SetScript("OnHide", function()
		TOGBankClassic_UI_Inventory:Close()
	end)
	--insert to global escape table
	table.insert(UISpecialFrames, "TOGBankClassic")
end

--handle all events
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

	-- Get icon from Info (already loaded by GetItems), fallback to cached GetItemInfo only if needed
	local icon = item.Info and item.Info.icon
	if not icon and item.ID then
		-- Only query if not in Info (fallback for old data)
		icon = select(10, GetItemInfo(item.ID))
	end
	if icon then
		slot:SetImage(icon)
	end
	slot:SetImageSize(imageSize, imageHeight)
	slot:SetWidth(size)
	slot:SetHeight(height)

	if item.Link then
		slot:SetCallback("OnEnter", function()
			TOGBankClassic_UI:ShowItemTooltip(item.Link)
		end)
		slot:SetCallback("OnLeave", function()
			TOGBankClassic_UI:HideTooltip()
		end)

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
	--fix issue where rarity doesn't return immediately
	if item.Info.rarity then
		local r, g, b = GetItemQualityColor(item.Info.rarity)
		border:SetVertexColor(r, g, b)
	end

	slot.border = border
	parent:AddChild(slot)

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

function TOGBankClassic_UI:OnInsertLink(link)
	if TOGBankClassic_UI_Search.searchField and TOGBankClassic_UI_Search.searchField.editbox:HasFocus() then
		TOGBankClassic_UI_Search.SearchText = link
		TOGBankClassic_UI_Search:DrawContent()
	end
end
