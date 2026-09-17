TOGBankClassic_Item = {}

-- WHAT THIS FILE IS NOW, and what it was. Until LINK-AUDIT-001 (docs/LINK_AUDIT.md, 2026-09-17) this
-- was the addon's item-identity layer: link parsers (`GetItemString`, `GetItemKey`, `GetSuffixID`),
-- a link-keyed aggregator (`Aggregate`), a 280-line async loader (`GetItems`) with its cache-warming
-- watchdog, a second `Info` builder (`GetInfo`), and a sort pre-pass that fabricated `Info` from a
-- link's brackets. All of it was written for a wire that shipped links and stripped them, and for a
-- client whose item cache had to be waited on. Neither is true any more: V2 stores
-- `{ id, count, suffix, enchant }`, `Scan.parseLink` is the one parser at the two edges where the
-- client hands over a link, `Record.key` / `Record.aggregate` are the one identity and the one
-- merge, and `Resolve.describe` (LibItemDB) answers at once -- so every row the UI draws is a
-- `Store.viewRow` that already carries `Info` and `Link`. What is left here is what is not about
-- links: the request's display name, the sort comparators, and the scanning tooltip.
--
-- INV2 step 10 deleted `Item:NeedsLink` (the send-side "is this link safe to strip?"). Step 1 of the
-- audit deleted its receive-side twin `ItemClassNeedsLink` and `GetClass`, the only reader of the
-- static `Modules/Static/ItemDB.lua` (3.7 MB parsed at every login, read by nothing since
-- `Database:PurgeLinklessGearGhosts` went in INV2-RETIRE-003). Step 4 deleted `GetSuffixID`, the
-- second parser of the item string's seventh field. Step 6 deleted the rest named above.

-- INV2-SUFFIX-001: the suffix of an INVENTORY ROW, read from its stored field, nil for none.
--
-- Rows from the V2 store (Inventory/Store.lua GetAltView) carry Suffix as a first-class number
-- where 0 means "no suffix". This once fell back to parsing `row.Link` for a legacy row with no
-- field; LINK-AUDIT-001 step 1 deleted that -- every caller (Search, Requests) reads Guild:GetAltItems
-- view rows, which always carry the field, and the legacy log path that did not is gone. Parsing a
-- link is lossy anyway (Resolve's fallback steps drop the suffix).
function TOGBankClassic_Item:RowSuffixID(row)
	local n = row and tonumber(row.Suffix)
	if n and n ~= 0 then
		return n
	end
	return nil
end

--- Is this the stand-in a resolver hands back when it has no name? These three spellings are the
--- ones the addon produces (Inventory/Resolve.lua, UI/Search.lua); a real item is never called any
--- of them.
---@param name string|nil
---@return boolean
function TOGBankClassic_Item:IsPlaceholderName(name)
	if name == nil or name == "" then return true end
	if name == "Unknown item" or name == "Unknown" then return true end
	return name:match("^Item %d+$") ~= nil
end

--- NAME-001: the name to SHOW for a request. Reported from a live guild: a request row reading
--- `Item 7969`. The requester's client could not name the item when the request was created (cold
--- cache, and before ItemDB), so the placeholder was stored in `request.item` and synced to every
--- client, where it stays for the life of the request -- the record is append-only and correct as
--- written. But the request also carries `itemID`, and by the time anyone looks at it the name is
--- almost always available (ItemDB, or the client's cache). So: a real name is returned as stored;
--- a placeholder is re-resolved from the id at display time, and only if that also fails does the
--- placeholder show. Never mutates the request -- the stored record is the wire's, not the UI's.
---@param request table a request record ({ item, itemID, suffixID, ... })
---@return string name
function TOGBankClassic_Item:RequestDisplayName(request)
	if type(request) ~= "table" then return "Unknown" end
	local stored = request.item
	local id = tonumber(request.itemID)
	local suffix = tonumber(request.suffixID) or 0
	-- SUFFIX-NAME-001: a request for a random-suffix variant names the VARIANT. Every request minted
	-- before Resolve.describe named suffixed rows stored the base name ("Spiked Club" for a
	-- `4564:1180` = "of the Bear" order), and the banker filling it could not tell which club was
	-- asked for (the operator, 2026-09-13: "it's still a problem ... aka, the suffixes"). The stored
	-- name is real and stays as written; when the record carries a suffix the shown name is
	-- resolved from id + suffix, which is where the link's name comes from too.
	if not self:IsPlaceholderName(stored) and suffix == 0 then return stored end
	local Record, Resolve = TOGBankClassic_Inventory_Record, TOGBankClassic_Inventory_Resolve
	if id and Record and Resolve then
		local rec = Record.new(id, 1, suffix)
		local name = rec and Resolve.name(rec)
		if name and not self:IsPlaceholderName(name) then return name end
	end
	return stored or "Unknown"
end

-- NOTE: Sort was adapted from ElvUI.
-- mode: "alpha" (default) = A-Z by name; "type" = grouped by item class/slot/subclass then name
--
-- LINK-AUDIT-001 step 6: the pre-pass that fabricated `Info` from a link's brackets and re-asked
-- GetItemInfo for `reqLevel` is gone. Every row sorted here is a Store.viewRow, whose `Info` Resolve
-- filled (reqLevel from LibItemDB's GetRequiredLevel) -- there is nothing to backfill.
function TOGBankClassic_Item:Sort(items, mode)
	if mode == "type" then
		-- SORT-001: By Type groups by item class (armor/weapon/consumable/etc.), then by
		-- subclass/material (all cloth together, all leather together, all swords together).
		-- Subclass must outrank equip slot so same-material gear stays contiguous; ordering slot
		-- first split a player's cloth across slot groups (6 cloth, 3 leather, 1 cloth).
		-- SORT-003: within each material, order by required-to-use level high→low (so all plate
		-- reads 50, 49, 48…), then equip slot, then rarity, then name as tie-breakers.
		table.sort(items, function(a, b)
			if a.Info.class ~= b.Info.class then
				return (a.Info.class or 99) < (b.Info.class or 99)
			end
			if a.Info.subClass ~= b.Info.subClass then
				return (a.Info.subClass or 99) < (b.Info.subClass or 99)
			end
			local aLevel = a.Info.reqLevel or 0
			local bLevel = b.Info.reqLevel or 0
			if aLevel ~= bLevel then
				return aLevel > bLevel
			end
			local aEquip = a.Info.equipId or 0
			local bEquip = b.Info.equipId or 0
			if aEquip ~= bEquip then
				return aEquip < bEquip
			end
			if a.Info.rarity ~= b.Info.rarity then
				return (a.Info.rarity or 0) < (b.Info.rarity or 0)
			end
			return (a.Info.name or "") < (b.Info.name or "")
		end)
	elseif mode == "rarity" then
		-- By Rarity: highest rarity first (epic before rare before uncommon etc.), then A-Z
		table.sort(items, function(a, b)
			local aRarity = a.Info.rarity or 0
			local bRarity = b.Info.rarity or 0
			if aRarity ~= bRarity then
				return aRarity > bRarity
			end
			return (a.Info.name or "") < (b.Info.name or "")
		end)
	elseif mode == "rarity_asc" then
		-- By Rarity (ascending): lowest rarity first (poor before common before uncommon etc.), then A-Z
		table.sort(items, function(a, b)
			local aRarity = a.Info.rarity or 0
			local bRarity = b.Info.rarity or 0
			if aRarity ~= bRarity then
				return aRarity < bRarity
			end
			return (a.Info.name or "") < (b.Info.name or "")
		end)
	elseif mode == "level" then
		-- SORT-002: By Level (High to Low) = highest required-to-use level first, then A-Z.
		-- Uses reqLevel (GetItemInfo #5), not item level (#4) — sorting by item level made the
		-- order look scrambled/repeating because it diverges from the required level players read.
		table.sort(items, function(a, b)
			local aLevel = a.Info.reqLevel or 0
			local bLevel = b.Info.reqLevel or 0
			if aLevel ~= bLevel then
				return aLevel > bLevel
			end
			return (a.Info.name or "") < (b.Info.name or "")
		end)
	elseif mode == "level_asc" then
		-- SORT-002: By Level (Low to High) = lowest required-to-use level first, then A-Z.
		table.sort(items, function(a, b)
			local aLevel = a.Info.reqLevel or 0
			local bLevel = b.Info.reqLevel or 0
			if aLevel ~= bLevel then
				return aLevel < bLevel
			end
			return (a.Info.name or "") < (b.Info.name or "")
		end)
	elseif mode == "alpha_desc" then
		-- Alphabetical descending: pure Z-A by name
		table.sort(items, function(a, b)
			return (a.Info.name or "") > (b.Info.name or "")
		end)
	else
		-- Alphabetical (default): pure A-Z by name
		table.sort(items, function(a, b)
			return (a.Info.name or "") < (b.Info.name or "")
		end)
	end
end

--- The tooltip line the client prints for a soulbound-count limit: "Unique" or "Unique (%d)"
--- (`ITEM_UNIQUE` / `ITEM_UNIQUE_MULTIPLE`, both localized). UNIQUE-EQUIPPED-001 (the operator,
--- 2026-09-15): a Unique-EQUIPPED item ("Unique-Equipped", `ITEM_UNIQUE_EQUIPPABLE`) is NOT one of
--- these -- it limits what you can wear, not what you can carry, so a bank can hold several and it
--- is taken, collected and credited like any other item. Only a truly Unique item is left to sit
--- in the mail and counted from there. The old substring test caught "Unique-Equipped" too (in
--- English; other locales differ), which is why the match is the WHOLE line now.
local function isUniqueLine(l)
	if l == ITEM_UNIQUE then return true end
	local multiple = ITEM_UNIQUE_MULTIPLE
	if type(multiple) ~= "string" then return false end
	-- "Unique (%d)" -> a plain-text prefix and suffix around the number, matched without patterns
	-- so a locale's magic characters cannot break it.
	local at = multiple:find("%d", 1, true)
	if not at then return l == multiple end
	local head, tail = multiple:sub(1, at - 1), multiple:sub(at + 2)
	if #l <= #head + #tail then return false end
	if l:sub(1, #head) ~= head then return false end
	if tail ~= "" and l:sub(-#tail) ~= tail then return false end
	local middle = l:sub(#head + 1, #l - #tail)
	return middle:match("^%d+$") ~= nil
end

function TOGBankClassic_Item:IsUnique(link)
	if not link then
		return false
	end

	-- ITEM-006: created ONCE and reused. This used to run CreateFrame per call, and WoW frames
	-- cannot be destroyed -- so every IsUnique leaked a frame, and each one clobbered the shared
	-- global name `scanTip`, handing any other addon reading it whichever frame we made last.
	-- Scanning a large bank calls this per item, so the leak scaled with the thing the addon is
	-- for.
	local tip = TOGBankClassic_Item._scanTip
	if not tip then
		tip = CreateFrame("GameTooltip", "TOGBankClassicScanTooltip", UIParent, "GameTooltipTemplate")
		TOGBankClassic_Item._scanTip = tip
	end

	tip:ClearLines()
	tip:SetOwner(UIParent, "ANCHOR_NONE")
	tip:SetHyperlink(link)
	for i = 1, tip:NumLines() do
		local line = _G["TOGBankClassicScanTooltipTextLeft" .. i]
		if line and line:IsVisible() then
			local l = line:GetText()
			if l and isUniqueLine(l) then
				return true
			end
		end
	end

	return false
end
