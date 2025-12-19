TOGBankClassic_UI_Minimap = {}

function TOGBankClassic_UI_Minimap:Init()
	self.icon = LibStub("LibDBIcon-1.0")
	local iconDB = LibStub("LibDataBroker-1.1"):NewDataObject("TOGBankClassicIcon", {
		type = "data source",
		text = "TOGBankClassic",
		icon = "Interface/ICONS/INV_Box_04", --purplebox
		OnEnter = function()
			self:ShowTooltip()
		end,
		OnLeave = function()
			TOGBankClassic_UI:HideTooltip()
		end,
		OnClick = function(_, b)
			if IsShiftKeyDown() then
				TOGBankClassic_Options:Open()
			else
				TOGBankClassic_UI_Inventory:Toggle()
			end
		end,
	})
	self.db = LibStub("AceDB-3.0"):New("TOGBankClassicIconDB", {
		profile = {
			minimap = {
				hide = not TOGBankClassic_Options.db.char.minimap["enabled"],
			},
		},
	})
	self.icon:Register("TOGBankClassic", iconDB, self.db.profile.minimap)
end

function TOGBankClassic_UI_Minimap:Toggle()
	if not TOGBankClassic_Options:GetMinimapEnabled() then
		self.icon:Hide("TOGBankClassic")
	else
		self.icon:Show("TOGBankClassic")
	end
end

function TOGBankClassic_UI_Minimap:ShowTooltip()
	GameTooltip:SetOwner(WorldFrame, "ANCHOR_CURSOR")
	GameTooltip:AddLine("TOGBankClassic")
	GameTooltip:AddDoubleLine("Click", "Inventory", 1, 1, 1)
	GameTooltip:AddDoubleLine("Shift-Click", "Options", 1, 1, 1)
	GameTooltip:Show()
end

