TOGBankClassic_UI_Minimap = {}

function TOGBankClassic_UI_Minimap:Init()
	self.icon = LibStub("LibDBIcon-1.0")
	local iconDB = LibStub("LibDataBroker-1.1"):NewDataObject("TOGBankClassicIcon", {
		type = "data source",
		text = TOGBankClassic_Constants.BRAND,
		label = TOGBankClassic_Constants.BRAND,
		-- BRAND-002: the operator's Ultimate Bank art (Textures/UB-MMB-Icon.tga, 64x64).
		icon = "Interface/AddOns/TOGBankClassic/Textures/UB-MMB-Icon",
		-- Centred the way Ultimate Profession Master's button is: LibDBIcon crops by
		-- dataObject.iconCoords (LibDBIcon-1.0 updateCoord), default a 5% trim. Measured from the
		-- TGA's alpha, this art's visible disc runs x 3..59 and y 2..60 -- centre 31.5 on both axes,
		-- so it already fills the square, unlike UPM's (10..53 / 7..52, cropped to 0.135..0.825). The
		-- window is the disc's 58px, then given UPM's in-game offset: the operator, 2026-10-31, with an
		-- in-game screenshot of the button, "needs the same small positioning
		-- adjustment UPM used to center it" -- UPM's window ends 0.02 up and left of its coin ("needs to
		-- go down 1px and right 1px", then "about 50% of that back up and left"), which draws the art
		-- down and right in the slot. 0.02 was copied first and was invisible ("are you sure you moved
		-- it? it looks like its still in the default position"): LibDBIcon draws the icon 17px square
		-- (TOPLEFT 7,-6 on a 31px button, so 1px high of centre) and trims 5% of the window itself
		-- (updateCoord), leaving ~52 texels of this art on 17px -- one screen pixel is ~0.048 here, so
		-- 0.02 moved it under half a pixel. UPM's CODE (one value in its history, 375d1ca): a square
		-- window as wide as its coin (0.69; coin x 0.156..0.844), placed ~0.02 up and left of the coin's
		-- centre -- on its scale (~0.0365 per pixel after the trim) the art draws ~0.55px down and right.
		-- Same art design here, drawn bigger: the coin is 0.89 wide (x 0.047..0.938, centre 0.492 on
		-- both axes), so the window is 0.89 square. 1px (~0.048) down and right, UPM's first step, was
		-- too far here as it was there (the operator, in game: "now you moved it too far down and
		-- right"); half of it back, as UPM did, puts the window 0.024 up and left of the coin's centre.
		-- Order is { left, right, top, bottom }.
		iconCoords = { 0.024, 0.914, 0.024, 0.914 },
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
