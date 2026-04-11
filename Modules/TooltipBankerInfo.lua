-- TooltipBankerInfo.lua
-- When the player mouses over any item in-game, appends a "Bankers:" section
-- to the tooltip listing every banker that has that item and their total quantity.

TOGBankClassic_TooltipBankerInfo = {}
local TooltipBankerInfo = TOGBankClassic_TooltipBankerInfo

-- Reusable table to avoid per-hover allocations
local found = {}

local function GetItemIDFromLink(link)
	return link and tonumber(link:match("|Hitem:(%d+):"))
end

local function OnTooltipSetItem(tooltip)
	local info = TOGBankClassic_Guild and TOGBankClassic_Guild.Info
	if not info or not info.alts then return end

	local _, link = tooltip:GetItem()
	if not link then return end

	local itemID = GetItemIDFromLink(link)
	if not itemID then return end

	wipe(found)
	for altName, alt in pairs(info.alts) do
		if TOGBankClassic_Guild:IsInCurrentGuildRoster(altName) and alt.items then
			local total = 0
			for _, item in ipairs(alt.items) do
				if item.ID == itemID then
					total = total + (item.Count or 1)
				end
			end
			if total > 0 then
				-- Strip realm suffix for display ("Bankchar-Realm" → "Bankchar")
				local shortName = altName:match("^([^%-]+)") or altName
				found[#found + 1] = { name = shortName, count = total }
			end
		end
	end

	if #found == 0 then return end

	-- Sort: most stock first, then alphabetically
	table.sort(found, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.name < b.name
	end)

	tooltip:AddLine(" ")
	tooltip:AddLine("TOGBankClassic", 1, 0.82, 0)  -- gold addon label
	tooltip:AddLine("Bankers:", 0.4, 0.8, 1)  -- light blue header
	for _, entry in ipairs(found) do
		tooltip:AddDoubleLine(entry.name, tostring(entry.count), 1, 1, 1, 1, 1, 1)
	end
end

function TooltipBankerInfo:Initialize()
	GameTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
end
