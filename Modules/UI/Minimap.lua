TOGBankClassic_UI_Minimap = {}

function TOGBankClassic_UI_Minimap:Init()
	self.icon = LibStub("LibDBIcon-1.0")
	local iconDB = LibStub("LibDataBroker-1.1"):NewDataObject("TOGBankClassicIcon", {
		type = "data source",
		text = TOGBankClassic_Constants.BRAND,
		label = TOGBankClassic_Constants.BRAND,
		-- BRAND-002: the operator's Ultimate Bank art (Textures/UB-MMB-Icon.tga, 64x64).
		icon = "Interface/AddOns/TOGBankClassic/Textures/UB-MMB-Icon",
		-- ICON-CROP-001: the window holds the WHOLE drawn coin, measured from the TGA by
		-- Tests/icon_spec.lua (TOGTools' method): opaque non-white pixels run x 4..59, y 2..59 of 64.
		-- The previous window, { 0.024, 0.914, 0.024, 0.914 }, was fitted by eye for the round minimap
		-- slot, where LibDBIcon's ring hides the rim -- it cut 1.5 file px off the coin's right and
		-- bottom, which Ultimate Tools' Square icons bag (no ring, iconCoords drawn as given) showed as
		-- flat edges (TOGTools, 2026-11-17). Now a 60px square, x 1..60 and y 0..59: the coin
		-- touches the right and bottom of it and has 3px/2px spare on the left/top, so it still
		-- draws ~1 file px down and right of centre -- the offset the operator asked for on
		-- 2026-10-31 ("needs the same small positioning adjustment UPM used to center it"), kept
		-- without cutting the coin. On the round minimap LibDBIcon trims a further 5% of the window
		-- itself (updateCoord) and the ring covers that. Order is { left, right, top, bottom }.
		iconCoords = { 1 / 64, 61 / 64, 0, 60 / 64 },
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
	GameTooltip:AddLine(TOGBankClassic_Constants.BrandName())
	GameTooltip:AddDoubleLine("Click", "Guild Bank", 1, 1, 1)
	GameTooltip:AddDoubleLine("Shift-Click", "Options", 1, 1, 1)
	GameTooltip:Show()
end
