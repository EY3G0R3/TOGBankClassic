-- Inventory/Resolve.lua — turn a V2 tuple back into something displayable.
--
-- See docs/INVENTORY_V2.md §4. V2 stores integers; links and item metadata are DERIVED here at
-- render time and thrown away. Nothing persists what this returns.
--
-- The chain, first hit wins:
--   1. LibItemDB-1.0        authoritative, ships the data, never cold
--   2. GetItemInfoInstant   cache-independent, so it still answers on a cold client
--   3. Placeholder          "Item #12345" and a question-mark icon
--
-- Step 3 exists because the addon must NEVER assume 100% resolution. IDB is complete below item
-- id 25000 and carries the Era-available high-id items (LIBREQ-IDB-001), but 330 ids above
-- 120000 are absent by design and a future patch can always add more. A blank row or a Lua
-- error in place of an item is a worse outcome than a clearly-labelled unknown.
--
-- Every fall past step 1 is logged so unresolved ids can be collected and the DB topped up.
-- Silent degradation is the failure mode this whole rework exists to remove.

TOGBankClassic_Inventory_Resolve = {}
local Resolve = TOGBankClassic_Inventory_Resolve

local Record = TOGBankClassic_Inventory_Record

local UNKNOWN_ICON = 134400  -- the standard grey question mark

-- Resolved ids seen this session, so the debug log reports each unknown once rather than on
-- every draw. Purely a noise guard; it holds no data anything depends on.
Resolve.unresolved = {}

--- The library, or nil. Resolved per call rather than cached at load: the addon must keep
--- working if the user disables ItemDB, and a cached nil from an early call would outlive it.
---
--- Feature-detects the METHODS it uses, not a version number. LibStub resolves the highest
--- registered minor, so an older copy embedded by some other addon can win — and then the handle
--- is non-nil and looks healthy while the method is missing. Checking the method is the only
--- form of this test that cannot be fooled.
local function itemDB()
	local lib = LibStub and LibStub("LibItemDB-1.0", true)
	if not lib or not lib.GetSuffixLink or not lib.GetInfo then return nil end
	return lib
end
Resolve.ItemDB = itemDB

local function noteUnresolved(id, stage)
	if Resolve.unresolved[id] then return end
	Resolve.unresolved[id] = stage
	TOGBankClassic_Output:Debug("ITEM", "LOAD",
		"[INV2] item %d not resolvable by %s - falling back", id, stage)
end

--- Full descriptor for a record. Always returns a table; never nil, never errors.
---
--- Fields mirror what the UI already consumes from the legacy `item.Info`, so the V2 store can
--- present the same shape and the UI diff stays near zero for the first cut:
---   name, link, icon, quality, itemLevel, reqLevel, class, subClass, equipLoc, resolved
---
--- `resolved` names which step answered ("itemdb" / "client" / "placeholder"), so a caller can
--- tell a real answer from a guess. Nothing else in the addon can currently make that
--- distinction, which is how cold-cache values ended up persisted as if they were facts.
function Resolve.describe(rec)
	if not Record.isValid(rec) then
		return {
			name = "Invalid item", link = nil, icon = UNKNOWN_ICON, quality = 0,
			itemLevel = 0, reqLevel = 0, class = 0, subClass = 0, equipLoc = "",
			resolved = "invalid",
		}
	end

	local id      = Record.id(rec)
	local suffix  = Record.suffix(rec)
	local enchant = Record.enchant(rec)

	-- Step 1: LibItemDB.
	local lib = itemDB()
	if lib and lib:HasItem(id) then
		local name, quality, class, subClass, equipLoc, itemLevel = lib:GetInfo(id)
		-- Suffixed items get their full display name and the correctly-scaled tooltip from the
		-- link; a plain item's link carries no suffix field at all.
		local link = lib:GetSuffixLink(id, suffix ~= 0 and suffix or nil,
			enchant ~= 0 and enchant or nil)
		-- LIBREQ-IDB-002. Feature-detected because it landed later than the rest of the API:
		-- an older resolved copy has the item data but not this method.
		local reqLevel = lib.GetRequiredLevel and lib:GetRequiredLevel(id) or 0
		return {
			name = name, link = link, icon = UNKNOWN_ICON, quality = quality or 1,
			itemLevel = itemLevel or 0, reqLevel = reqLevel or 0,
			class = class or 0, subClass = subClass or 0, equipLoc = equipLoc or "",
			resolved = "itemdb",
		}
	end
	noteUnresolved(id, lib and "itemdb" or "itemdb (library absent)")

	-- Step 2: the client's own static data. GetItemInfoInstant does NOT need a warm cache, so
	-- it answers immediately after login where GetItemInfo returns nil. That property is the
	-- entire reason the legacy loader had to be asynchronous.
	if GetItemInfoInstant then
		local iid, _, _, equipLoc, icon, class, subClass = GetItemInfoInstant(id)
		if iid then
			return {
				name = "Item " .. id, link = "item:" .. id, icon = icon or UNKNOWN_ICON,
				quality = 1, itemLevel = 0, reqLevel = 0,
				class = class or 0, subClass = subClass or 0, equipLoc = equipLoc or "",
				resolved = "client",
			}
		end
	end

	-- Step 3: never blank, never an error.
	return {
		name = "Item " .. id, link = nil, icon = UNKNOWN_ICON, quality = 0,
		itemLevel = 0, reqLevel = 0, class = 0, subClass = 0, equipLoc = "",
		resolved = "placeholder",
	}
end

--- Just the display name. Convenience for search indexing, where the rest is unwanted.
function Resolve.name(rec)
	return Resolve.describe(rec).name
end

--- Just the clickable link, or nil when none can be built. Callers must handle nil rather than
--- feeding it to SetHyperlink, which fails silently and shows no tooltip.
function Resolve.link(rec)
	return Resolve.describe(rec).link
end

--- Ids this session could not resolve through IDB, for `/togbank dev` reporting and for
--- deciding what the shipped data is missing.
function Resolve.getUnresolved()
	local out = {}
	for id, stage in pairs(Resolve.unresolved) do
		out[#out + 1] = { id = id, stage = stage }
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

function Resolve.resetUnresolved()
	Resolve.unresolved = {}
end
