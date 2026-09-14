-- Inventory/Resolve.lua — turn a V2 tuple back into something displayable.
--
-- See docs/INVENTORY_V2.md §4. V2 stores integers; links and item metadata are DERIVED here at
-- render time and thrown away. Nothing persists what this returns.
--
-- LibItemDB-1.0 is a REQUIRED dependency, declared in both TOCs and as the slug `libitemdb` in
-- .pkgmeta. That is not a preference: V2 stores integer tuples and rebuilds the link here, so
-- with no library there is nothing to rebuild from. It is still requested through LibStub's
-- optional form below, because a nil handle has to be REPORTED rather than raised in the middle
-- of a draw -- see reportLibraryMissing.
--
-- The chain, first hit wins:
--   1. LibItemDB-1.0        authoritative, ships the data, never cold
--   2. GetItemInfoInstant   cache-independent, so it still answers on a cold client
--   3. Placeholder          "Item #12345" and a question-mark icon
--
-- Steps 2 and 3 are for ids the library does not CARRY. They are not a supported mode of
-- operation for a missing library: with ItemDB absent every row degrades to step 2 or 3 at once,
-- which is the cold-cache dependence this rework exists to delete, wearing a different hat.
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

--- itemID -> icon fileID, memoised for the session.
---
--- RESOLVE-001: an icon is a PURE FUNCTION OF ITEM ID -- it does not vary by suffix, enchant,
--- stack size, owner or locale, and it cannot change while the client is running. So the lookup is
--- done once per distinct id rather than once per row: a bank holding 1,200 stacks across 400
--- distinct items costs 400 calls, not 1,200, and every later alt holding the same items costs
--- none. Combined with the per-alt view cache in Store, the steady-state cost of drawing the
--- inventory is zero icon lookups.
---
--- `false` is stored for an id the client has no icon for, so a miss is remembered too --
--- otherwise exactly the ids that fail would be retried on every rebuild, which is backwards.
local iconCache = {}

--- The client's icon for an item id, or nil.
---
--- GetItemInfoInstant is used rather than GetItemInfo deliberately: it reads the client's STATIC
--- item data, needs no warm cache and never defers, so it answers immediately after login. It is
--- also strictly cheaper than the GetItemInfo + ContinueOnItemLoad pair the legacy loader used per
--- item (audit ITEM-005), which this replaces rather than adds to.
local function iconFor(id)
	local hit = iconCache[id]
	if hit ~= nil then return hit or nil end
	local icon
	if GetItemInfoInstant then
		icon = select(5, GetItemInfoInstant(id))
	end
	iconCache[id] = icon or false
	return icon
end

--- Drop the memo. Only needed if the client's item data could change under us, which in practice
--- means a reload -- exposed so a spec can prove the memo is a cache and not a leak.
function Resolve.ClearIconCache()
	iconCache = {}
end

-- Resolved ids seen this session, so the debug log reports each unknown once rather than on
-- every draw. Purely a noise guard; it holds no data anything depends on.
Resolve.unresolved = {}

--- The library, or nil. Resolved per call rather than cached at load: a cached nil from an early
--- call would outlive the condition, and ItemDB can legitimately arrive after this file does.
---
--- A nil here means a REQUIRED dependency did not load. The addon still renders rather than
--- erroring, but it says so once through reportLibraryMissing -- degrading quietly is what this
--- returning nil used to do, and it is the bug that hid the missing declaration for as long as
--- it did.
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

--- Whether the missing-library error has already been shown this session.
---
--- ItemDB is a REQUIRED dependency (declared in both TOCs, slug `libitemdb` in .pkgmeta). The
--- V2 store holds integer tuples and rebuilds the link at render time, so with no library there
--- is nothing to rebuild from and EVERY row degrades to a placeholder.
---
--- This is reported at a level the player actually sees, once, and deliberately NOT through
--- noteUnresolved: that is keyed per item id, so a missing library would report itself once per
--- distinct item -- thousands of lines saying the same thing, in a debug category that is off by
--- default. A required dependency that did not load is not a debug detail.
---
--- It stays SEPARATE from the three-step fallback rather than replacing it. The fallback exists
--- for ids the library genuinely does not carry (330 above id 120000 -- see
--- docs/LIBRARY_CONTRACTS.md section 1.7), and "this item is not in the DB" is a different fact
--- from "there is no DB". Collapsing the two is what let the second hide inside the first.
Resolve.libraryReported = false

local function reportLibraryMissing()
	if Resolve.libraryReported then return end
	Resolve.libraryReported = true
	TOGBankClassic_Output:Error(
		"LibItemDB-1.0 did not load. It is a required dependency: without it, item names and " ..
		"links cannot be rebuilt, so the inventory will show placeholders instead of items. " ..
		"Reinstall the ItemDB addon.")
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
	if not lib then reportLibraryMissing() end
	if lib and lib:HasItem(id) then
		local name, quality, class, subClass, equipLoc, itemLevel = lib:GetInfo(id)
		-- Suffixed items get their full display name and the correctly-scaled tooltip from the
		-- link; a plain item's link carries no suffix field at all.
		local link = lib:GetSuffixLink(id, suffix ~= 0 and suffix or nil,
			enchant ~= 0 and enchant or nil)
		-- SUFFIX-NAME-001 (docs/LINK_AUDIT.md 3.4; the operator, 2026-09-13: "the item in the
		-- requests HAS to show the link or i'm not able to fill the order properly ... aka, the
		-- suffixes"): the NAME comes from the same source as the link. GetInfo's is the BASE name, so
		-- "Spiked Club of the Bear" and "of Spirit" were two rows both reading "Spiked Club" -- to
		-- the requester choosing, and to the banker reading the request. ResolveSuffix's `name` is
		-- base .. " " .. the random-property family (LibItemDB-1.0.lua:1255-1269), exactly what the
		-- link's brackets carry. An unknown property answers the base name, as the link does.
		if suffix ~= 0 and lib.ResolveSuffix then
			local full = lib:ResolveSuffix(id, suffix)
			if full and full.name and full.name ~= "" then name = full.name end
		end
		-- A base the library has in `core` but not in `names` answers no name (GetInfo nil,
		-- ResolveSuffix "" -- LibItemDB-1.0.lua:1260 `base or ""`). That is not a resolution: fall
		-- through to the client's data rather than hand back a descriptor with no name to show.
		if name ~= nil and name ~= "" then
			-- LIBREQ-IDB-002. Feature-detected because it landed later than the rest of the API:
			-- an older resolved copy has the item data but not this method.
			local reqLevel = lib.GetRequiredLevel and lib:GetRequiredLevel(id) or 0
			-- RESOLVE-001: this hardcoded UNKNOWN_ICON, so every item that resolved SUCCESSFULLY
			-- rendered as a question mark -- name, link, quality and level all correct beside it,
			-- which is what made it read as an icon-cache problem rather than a missing field.
			--
			-- LibItemDB carries no icon (there is no GetIcon; it ships names, quality, stats, prices
			-- and levels). The client does, and GetItemInfoInstant is the right source for exactly
			-- the reason step 2 below uses it: it is CACHE-INDEPENDENT, so it answers on a cold
			-- client where GetItemInfo returns nil. An icon is a fixed per-item fileID, so there is
			-- nothing for the library to add here and no contract to raise.
			return {
				name = name, link = link, icon = iconFor(id) or UNKNOWN_ICON, quality = quality or 1,
				itemLevel = itemLevel or 0, reqLevel = reqLevel or 0,
				class = class or 0, subClass = subClass or 0, equipLoc = equipLoc or "",
				resolved = "itemdb",
			}
		end
		noteUnresolved(id, "itemdb (no name)")
	else
		noteUnresolved(id, lib and "itemdb" or "itemdb (library absent)")
	end

	-- Step 2: the client's own static data. GetItemInfoInstant does NOT need a warm cache, so
	-- it answers immediately after login where GetItemInfo returns nil. That property is the
	-- entire reason the legacy loader had to be asynchronous.
	if GetItemInfoInstant then
		local iid, _, _, equipLoc, icon, class, subClass = GetItemInfoInstant(id)
		if iid then
			-- NAME-001: GetItemInfoInstant carries no name, and this step used to hand back
			-- "Item <id>" even when the client's cache HAD the name. Reported from a live guild
			-- ("item id did not resolve into a descriptive name" -- a request row reading `Item
			-- 7969`). GetItemInfo is cache-dependent, so it may still be nil here; when it answers,
			-- its name, quality and link are the real ones and are used.
			local name, link, quality, itemLevel, reqLevel = GetItemInfo(id)
			return {
				name = name or ("Item " .. id), link = link or ("item:" .. id), icon = icon or UNKNOWN_ICON,
				quality = quality or 1, itemLevel = itemLevel or 0, reqLevel = reqLevel or 0,
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
