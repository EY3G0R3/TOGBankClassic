-- TooltipBankerInfo.lua
-- When the player mouses over any item in-game, appends a "Bankers:" section
-- to the tooltip listing every banker that has that item and their total quantity.
--
-- The renderer is PUBLIC (`:AppendTo`) rather than a file-local closure, because
-- our own `OnTooltipSetItem` hook only fires for a tooltip carrying a real item.
-- TOGProfessionMaster draws recipe tooltips for the ~1/3 of recipes that are
-- trainer-taught and have no teaching item at all -- built from AddLine calls, so
-- the hook never fires and this block was silently absent on exactly the tooltips
-- where a player is asking "can I get these reagents from the bank?". It had
-- copied our heading text, colours and AddDoubleLine shape to work around that,
-- which meant restyling here would quietly stop matching there.
-- Raised as DEPENDENCY_CONTRACTS.md §1 by TOGProfessionMaster, 2026-08-06.

TOGBankClassic_TooltipBankerInfo = {}
local TooltipBankerInfo = TOGBankClassic_TooltipBankerInfo

-- Reusable table to avoid per-hover allocations
local found = {}

local function GetItemIDFromLink(link)
	return link and tonumber(link:match("|Hitem:(%d+):"))
end

--- Draw the "Bankers:" block into a tooltip the caller owns.
-- Returns true if it added lines, false if no banker holds the item (or the
-- arguments/data make the question unanswerable). Never raises: the caller may
-- be mid-tooltip with no item context.
-- @param tooltip table the tooltip being built
-- @param itemID  number the item to report bank stock for
function TooltipBankerInfo:AppendTo(tooltip, itemID)
	if type(tooltip) ~= "table" or type(tooltip.AddLine) ~= "function" then return false end
	if type(itemID) ~= "number" then return false end

	local info = TOGBankClassic_Guild and TOGBankClassic_Guild.Info
	if not info or not info.alts then return false end

	wipe(found)
	for altName in pairs(info.alts) do
		if TOGBankClassic_Guild:IsInCurrentGuildRoster(altName) then
			-- INV2 step 7a: this read `alt.items` directly and was missed when the other six read
			-- sites moved to Guild:GetAltItems -- so with inventoryV2 on, every other view read the
			-- V2 store and this one still read the legacy record. Two sources for one number is
			-- exactly the divergence 7a exists to remove.
			--
			-- SELF-AUDIT FINDING 3: 7a used GetAltItems, whose legacy branch BUILDS A FRESH ARRAY OF
			-- EVERY ITEM per call -- an allocation per banker per hover, in the file whose own header
			-- says it keeps a reusable table to avoid exactly that, on the shared GameTooltip path.
			-- GetAltItemTotal answers the question actually being asked, so no branch materialises a
			-- list, and it keeps 7a's switch semantics so the two cannot disagree about the source.
			local total = TOGBankClassic_Guild:GetAltItemTotal(altName, itemID)
			if total > 0 then
				-- Strip realm suffix for display ("Bankchar-Realm" → "Bankchar")
				local shortName = altName:match("^([^%-]+)") or altName
				found[#found + 1] = { name = shortName, count = total }
			end
		end
	end

	if #found == 0 then return false end

	-- Sort: most stock first, then alphabetically
	table.sort(found, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.name < b.name
	end)

	-- The trailing `true` is the wrap flag. It defaults to FALSE, and an
	-- unwrapped line ignores the client's engine-side preset width and stretches
	-- the frame -- dragging every other addon's content out with it, since
	-- GameTooltip is shared. AddDoubleLine below takes no such flag; the two
	-- halves here are a character name and a stack count, both short by
	-- construction, so there is nothing to wrap.
	tooltip:AddLine(" ")
	tooltip:AddLine("TOGBankClassic", 1, 0.82, 0, true)  -- gold addon label
	tooltip:AddLine("Bankers:", 0.4, 0.8, 1, true)  -- light blue header
	for _, entry in ipairs(found) do
		tooltip:AddDoubleLine(entry.name, tostring(entry.count), 1, 1, 1, 1, 1, 1)
	end
	return true
end

local function OnTooltipSetItem(tooltip)
	local _, link = tooltip:GetItem()
	if not link then return end
	TooltipBankerInfo:AppendTo(tooltip, GetItemIDFromLink(link))
end

function TooltipBankerInfo:Initialize()
	GameTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
end
