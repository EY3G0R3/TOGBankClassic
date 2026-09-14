-- Inventory/Scan.lua — read the player's containers into V2 tuples.
--
-- THE one container walk (INV2-RETIRE-003). Until 2026-09-11 this walk also emitted the legacy
-- link-bearing row shape when the `dualWrite` switch was on, so a rollback would land on live data
-- and `/togbank dev compare` could prove the two encodings agreed from a single pass. The legacy
-- rows are not written by anything any more (docs/DELTA_RELEASE.md section 4), so the second shape,
-- the switch and the `withLegacy` parameters are gone with them.

TOGBankClassic_Inventory_Scan = {}
local Scan = TOGBankClassic_Inventory_Scan

local Record = TOGBankClassic_Inventory_Record

-- Bag ids. The carried bags come first, then BANK_CONTAINER (the vault) and its bag slots.
--
-- BANKSLOT-001: these were `0, 4` and `5, 11` here, and the second end was one too many on Classic
-- Era. The arithmetic now has ONE spelling, in Modules/Constants.lua, shared with Bank.lua,
-- ItemHighlight.lua and Mail.lua -- because the two scan paths walking different ranges is a
-- divergence `/togbank dev compare` would report as an encoding bug. Still read at CALL time, for
-- the reason given there.
local carriedBagRange = TOGBankClassic_Constants.CarriedBagRange
local bankBagRange    = TOGBankClassic_Constants.BankBagRange

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

--- Walk one container, appending tuples to `records`. Returns the number of occupied slots seen.
---
--- HIDE-002: `bound` (`Record.key -> true`) collects the key of every slot the client reports as
--- bound (`ContainerItemInfo.isBound`, in Era's ContainerDocumentation.lua) -- the input to the
--- banker's "hide soulbound items" setting. Keyed, not per stack, because the store aggregates by
--- key: a bound and an unbound copy of the same variant are one row, and hiding is per row.
local function scanContainer(bag, records, bound)
	local slots = C_Container.GetContainerNumSlots(bag) or 0
	local used = 0
	for slot = 1, slots do
		local info = C_Container.GetContainerItemInfo(bag, slot)
		if info and info.itemID then
			used = used + 1
			local enchant, suffix = Scan.parseLink(info.hyperlink)
			local rec = Record.new(info.itemID, info.stackCount or 1, suffix, enchant)
			if rec then
				records[#records + 1] = rec
				if bound and info.isBound then bound[Record.key(rec)] = true end
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
--- @return table records, number slotsUsed, number slotsTotal, table boundKeys
function Scan:ScanBags()
	local records, bound = {}, {}
	local used, total = 0, 0
	local firstBag, lastBag = carriedBagRange()
	for bag = firstBag, lastBag do
		used = used + scanContainer(bag, records, bound)
		total = total + (C_Container.GetContainerNumSlots(bag) or 0)
	end
	return records, used, total, bound
end

--- Scan the bank vault and its bag slots. Returns nil when the player is not at a banker, which
--- callers must treat as "unknown", NOT as "empty" -- overwriting stored bank contents with an
--- empty scan is how a character's whole vault disappears from the guild's view.
--- @return table|nil records, number slotsUsed, number slotsTotal, table|nil boundKeys
function Scan:ScanBank()
	if not bankAvailable() then return nil, 0, 0, nil end
	local records, bound = {}, {}
	local used = scanContainer(BANK_CONTAINER, records, bound)
	local total = NUM_BANKGENERIC_SLOTS or 0
	local firstBankBag, lastBankBag = bankBagRange()
	for bag = firstBankBag, lastBankBag do
		used = used + scanContainer(bag, records, bound)
		total = total + (C_Container.GetContainerNumSlots(bag) or 0)
	end
	return records, used, total, bound
end

--- Full scan: carried bags always, vault when reachable.
---
--- When the bank is out of reach the result carries `bankScanned = false` so the caller can
--- preserve previously-stored vault contents instead of replacing them with nothing.
---
--- `sources` is the per-source view the store writes through (INV2-VAULT-001): `sources.bags` is
--- always present, `sources.bank` is ABSENT when the vault was unreachable. That absence is the
--- whole signal -- `Store:SetAltSources` keeps a source it is not given, so an unreadable vault
--- leaves the stored one alone instead of cancelling the write.
---
--- `records` stays the flat combined array it always was. Both are derived from the one walk, so
--- they cannot disagree, and keeping it means no caller or spec had to change to gain `sources`.
function Scan:ScanAll()
	local bagRecords, bagsUsed, bagsTotal, bagsBound = self:ScanBags()
	local bankRecords, bankUsed, bankTotal, bankBound = self:ScanBank()

	-- Per source, before they are combined. `bank` stays nil when unreachable.
	local sources = { bags = bagRecords }
	if bankRecords then sources.bank = bankRecords end
	-- HIDE-002: the bound keys, per source, in the same shape -- `bank` nil when unreachable, so
	-- the caller keeps the bound keys it remembered from the last vault read rather than losing them.
	local bound = { bags = bagsBound }
	if bankBound then bound.bank = bankBound end

	local records = {}
	for _, rec in ipairs(bagRecords) do records[#records + 1] = rec end
	if bankRecords then
		for _, rec in ipairs(bankRecords) do records[#records + 1] = rec end
	end

	return {
		records     = records,
		sources     = sources,
		bound       = bound,
		money       = GetMoney and GetMoney() or 0,
		bankScanned = bankRecords ~= nil,
		slots       = {
			bags = { used = bagsUsed, total = bagsTotal },
			bank = { used = bankUsed, total = bankTotal },
		},
	}
end
