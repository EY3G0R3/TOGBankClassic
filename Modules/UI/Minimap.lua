TOGBankClassic_UI_Minimap = {}

function TOGBankClassic_UI_Minimap:Init()
	self.icon = LibStub("LibDBIcon-1.0")
	local iconDB = LibStub("LibDataBroker-1.1"):NewDataObject("TOGBankClassicIcon", {
		type = "data source",
		text = "TOGBankClassic",
		icon = "Interface/AddOns/TOGBankClassic/Media/TOGBankClassic_MMB_Icon",
		OnEnter = function()
			self:ShowTooltip()
		end,
		OnLeave = function()
			TOGBankClassic_UI:HideTooltip()
		end,
		-- ENTRY-001 (operator 2026-09-13: "can you make the MMB open the new UI and browse open the
		-- legacy ui?"): the click is the Guild Bank window; `/togbank legacy` is the old Inventory
		-- window for as long as it exists (BROWSE-002 follow-on (d) retires it).
		OnClick = function(_, _)
			if IsShiftKeyDown() then
				TOGBankClassic_Options:Open()
			else
				TOGBankClassic_UI_Browse:Toggle()
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
	GameTooltip:AddDoubleLine("Click", "Guild Bank", 1, 1, 1)
	GameTooltip:AddDoubleLine("Shift-Click", "Options", 1, 1, 1)
	GameTooltip:Show()
end
