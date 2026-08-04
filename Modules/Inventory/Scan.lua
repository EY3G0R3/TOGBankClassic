-- Inventory/Scan.lua — read the player's containers into V2 tuples.
--
-- See docs/INVENTORY_V2.md §6.1. The container API is walked ONCE and the single result is
-- emitted in both shapes when dualWrite is on:
--
--   > Running two independent scans would double the cost of the addon's hottest path and --
--   > worse -- invalidate the comparison, because the bank could change between passes.
--
-- That second point is the important one. dualWrite exists so a rollback lands on live data and
-- so `/togbank dev compare` can prove the two encodings agree. A comparison between two separate
-- walks proves nothing: any divergence could be a real encoding bug or just a stack that moved
-- between passes, and there is no way to tell which.

TOGBankClassic_Inventory_Scan = {}
local Scan = TOGBankClassic_Inventory_Scan

local Record = TOGBankClassic_Inventory_Record

-- Bag ids. 0-4 are carried bags; BANK_CONTAINER plus 5-11 are the vault and its bag slots.
local CARRIED_FIRST, CARRIED_LAST = 0, 4
local BANK_BAG_FIRST, BANK_BAG_LAST = 5, 11

--- Pull (enchantID, suffixID) out of an item link.
---
--- Field 2 is the enchant and field 7 the random-suffix, counting from the itemID. Both are
--- returned as 0 when absent, so callers never branch on nil. The suffix is SIGNED: a negative
--- value indexes the random-property table rather than the random-suffix table, and losing the
--- sign would merge two genuinely different items.
---
--- Empty fields (`item:10132::::::863`) and explicit zeros (`item:10132:0:0:0:0:0:863`) are both
--- valid and mean the same thing. That equivalence is exactly what link-keying got wrong -- the
--- two spellings produced different keys for one item -- and parsing to integers here is what
--- makes the distinction stop existing.
function Scan.parseLink(link)
	if type(link) ~= "string" then return 0, 0 end
	local body = link:match("|Hitem:([%-%d:]+)") or link:match("^item:([%-%d:]+)")
	if not body then return 0, 0 end
	local fields = {}
	for field in (body .. ":"):gmatch("([^:]*):") do fields[#fields + 1] = field end
	-- fields[1] is the itemID; enchant is 2, suffix is 7.
	return tonumber(fields[2]) or 0, tonumber(fields[7]) or 0
end

--- Walk one container, appending to `records` (V2) and, when supplied, `legacy` (v1 shape).
--- Returns the number of occupied slots seen.
local function scanContainer(bag, records, legacy)
	local slots = C_Container.GetContainerNumSlots(bag) or 0
	local used = 0
	for slot = 1, slots do
		local info = C_Container.GetContainerItemInfo(bag, slot)
		if info and info.itemID then
			used = used + 1
			local enchant, suffix = Scan.parseLink(info.hyperlink)
			local rec = Record.new(info.itemID, info.stackCount or 1, suffix, enchant)
			if rec then records[#records + 1] = rec end
			-- Same walk, second shape. Deliberately the legacy structure verbatim rather than a
			-- conversion of the tuple: each format is produced by its own native path, so
			-- neither can corrupt the other (INVENTORY_V2.md §5).
			if legacy then
				legacy[#legacy + 1] = {
					ID = info.itemID, Count = info.stackCount or 1, Link = info.hyperlink,
				}
			end
		end
	end
	return used
end

--- True when the bank vault is reachable (the player is at a banker). Away from one, the vault
--- slots read as empty, which would otherwise look like the bank having been emptied.
local function bankAvailable()
	local _, bagType = C_Container.GetContainerNumFreeSlots(BANK_CONTAINER)
	return bagType ~= nil
end

--- Scan carried bags.
--- @return table records, table|nil legacy, number slotsUsed, number slotsTotal
function Scan:ScanBags(withLegacy)
	local records, legacy = {}, withLegacy and {} or nil
	local used, total = 0, 0
	for bag = CARRIED_FIRST, CARRIED_LAST do
		used = used + scanContainer(bag, records, legacy)
		total = total + (C_Container.GetContainerNumSlots(bag) or 0)
	end
	return records, legacy, used, total
end

--- Scan the bank vault and its bag slots. Returns nil when the player is not at a banker, which
--- callers must treat as "unknown", NOT as "empty" -- overwriting stored bank contents with an
--- empty scan is how a character's whole vault disappears from the guild's view.
--- @return table|nil records, table|nil legacy, number slotsUsed, number slotsTotal
function Scan:ScanBank(withLegacy)
	if not bankAvailable() then return nil, nil, 0, 0 end
	local records, legacy = {}, withLegacy and {} or nil
	local used = scanContainer(BANK_CONTAINER, records, legacy)
	local total = NUM_BANKGENERIC_SLOTS or 0
	for bag = BANK_BAG_FIRST, BANK_BAG_LAST do
		used = used + scanContainer(bag, records, legacy)
		total = total + (C_Container.GetContainerNumSlots(bag) or 0)
	end
	return records, legacy, used, total
end

--- Full scan: carried bags always, vault when reachable.
---
--- `legacy` is populated only when dualWrite is on, and comes from the SAME container walk --
--- see the header. When the bank is out of reach the result carries `bankScanned = false` so the
--- caller can preserve previously-stored vault contents instead of replacing them with nothing.
function Scan:ScanAll()
	local dual = TOGBankClassic_Switches
		and TOGBankClassic_Switches:IsEnabled("dualWrite")
		or false

	local records, legacy, bagsUsed, bagsTotal = self:ScanBags(dual)
	local bankRecords, bankLegacy, bankUsed, bankTotal = self:ScanBank(dual)

	if bankRecords then
		for _, rec in ipairs(bankRecords) do records[#records + 1] = rec end
		if legacy and bankLegacy then
			for _, item in ipairs(bankLegacy) do legacy[#legacy + 1] = item end
		end
	end

	return {
		records     = records,
		legacy      = legacy,
		money       = GetMoney and GetMoney() or 0,
		bankScanned = bankRecords ~= nil,
		slots       = {
			bags = { used = bagsUsed, total = bagsTotal },
			bank = { used = bankUsed, total = bankTotal },
		},
	}
end
