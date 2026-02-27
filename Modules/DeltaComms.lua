-- DeltaComms.lua
-- Handles all delta synchronization communication and protocol logic for TOGBankClassic v0.7.0+
-- This includes delta validation, computation, application, error tracking, and protocol coordination

TOGBankClassic_DeltaComms = {}

-- VALIDATION FUNCTIONS --

-- Validate that a delta structure is well-formed
function TOGBankClassic_DeltaComms:ValidateDeltaStructure(delta)
	if not delta or type(delta) ~= "table" then
		return false, "delta is not a table"
	end

	-- Check required fields
	if delta.type ~= "alt-delta" then
		return false, "invalid delta type"
	end

	if not delta.name or type(delta.name) ~= "string" then
		return false, "missing or invalid name"
	end

	if not delta.version or type(delta.version) ~= "number" then
		return false, "missing or invalid version"
	end

	if delta.inventoryHash and type(delta.inventoryHash) ~= "number" then
		return false, "invalid inventoryHash"
	end
	if delta.updatedAt and type(delta.updatedAt) ~= "number" then
		return false, "invalid updatedAt"
	end

	-- v0.8.0: baseVersion is optional (removed from new protocol)
	-- Old protocol deltas will still have it, new protocol won't
	if delta.baseVersion and type(delta.baseVersion) ~= "number" then
		return false, "invalid baseVersion"
	end

	if not delta.changes or type(delta.changes) ~= "table" then
		return false, "missing or invalid changes"
	end

	-- Validate changes structure
	local changes = delta.changes

	-- Money is optional but must be number if present
	if changes.money and type(changes.money) ~= "number" then
		return false, "invalid money in changes"
	end

	-- Validate bank delta if present
	if changes.bank then
		local valid, err = self:ValidateItemDelta(changes.bank)
		if not valid then
			return false, "invalid bank delta: " .. err
		end
	end

	-- Validate bags delta if present
	if changes.bags then
		local valid, err = self:ValidateItemDelta(changes.bags)
		if not valid then
			return false, "invalid bags delta: " .. err
		end
	end

	-- Validate mail delta if present
	if changes.mail then
		local valid, err = self:ValidateItemDelta(changes.mail)
		if not valid then
			return false, "invalid mail delta: " .. err
		end
	end

	return true
end

-- Validate an item delta structure (added/modified/removed)
function TOGBankClassic_DeltaComms:ValidateItemDelta(itemDelta)
	if not itemDelta or type(itemDelta) ~= "table" then
		return false, "itemDelta is not a table"
	end

	-- Check added array
	if itemDelta.added then
		if type(itemDelta.added) ~= "table" then
			return false, "added is not a table"
		end
		for _, item in pairs(itemDelta.added) do
			if type(item) ~= "table" then
				return false, "added item is not a table"
			end
			if not item.ID or type(item.ID) ~= "number" then
				return false, "added item missing or invalid ID"
			end
			-- v0.8.0: Link is optional (bandwidth optimization - receiver reconstructs)
			if item.Link and type(item.Link) ~= "string" then
				return false, "added item has invalid Link"
			end
			if item.ItemString and type(item.ItemString) ~= "string" then
				return false, "added item has invalid ItemString"
			end
			-- slot is optional (merged items don't have slots)
		end
	end

	-- Check modified array
	if itemDelta.modified then
		if type(itemDelta.modified) ~= "table" then
			return false, "modified is not a table"
		end
		for _, item in pairs(itemDelta.modified) do
			if type(item) ~= "table" then
				return false, "modified item is not a table"
			end
			if not item.ID or type(item.ID) ~= "number" then
				return false, "modified item missing or invalid ID"
			end
			-- v0.8.0: Link is optional (bandwidth optimization - receiver reconstructs)
			if item.Link and type(item.Link) ~= "string" then
				return false, "modified item has invalid Link"
			end
			if item.ItemString and type(item.ItemString) ~= "string" then
				return false, "modified item has invalid ItemString"
			end
			-- slot is optional (merged items don't have slots)
		end
	end

	-- Check removed array
	if itemDelta.removed then
		if type(itemDelta.removed) ~= "table" then
			return false, "removed is not a table"
		end
		for _, item in pairs(itemDelta.removed) do
			if type(item) ~= "table" then
				return false, "removed item is not a table"
			end
			if not item.ID or type(item.ID) ~= "number" then
				return false, "removed item missing or invalid ID"
			end
			-- v0.8.0: Link is optional in removed items (bandwidth optimization)
			-- Only ID is required; Link is backfilled during application if needed
		end
	end

	return true
end

-- Sanitize a delta structure by removing malformed data
function TOGBankClassic_DeltaComms:SanitizeDelta(delta)
	if not delta or type(delta) ~= "table" then
		return nil
	end

	-- Create sanitized copy
	local sanitized = {
		type = delta.type,
		name = delta.name,
		version = delta.version,
		baseVersion = delta.baseVersion,
		inventoryHash = delta.inventoryHash,
		updatedAt = delta.updatedAt,
		changes = {},
	}

	if not delta.changes or type(delta.changes) ~= "table" then
		return sanitized
	end

	local changes = delta.changes

	-- Sanitize money
	if changes.money and type(changes.money) == "number" then
		sanitized.changes.money = changes.money
	end

	-- Sanitize bank delta
	if changes.bank and type(changes.bank) == "table" then
		sanitized.changes.bank = self:SanitizeItemDelta(changes.bank)
	end

	-- Sanitize bags delta
	if changes.bags and type(changes.bags) == "table" then
		sanitized.changes.bags = self:SanitizeItemDelta(changes.bags)
	end

	-- Sanitize mail delta
	if changes.mail and type(changes.mail) == "table" then
		sanitized.changes.mail = self:SanitizeItemDelta(changes.mail)
	end

	return sanitized
end

-- Sanitize an item delta structure
function TOGBankClassic_DeltaComms:SanitizeItemDelta(itemDelta)
	local sanitized = {
		added = {},
		modified = {},
		removed = {},
	}

	-- Sanitize added items
	if itemDelta.added and type(itemDelta.added) == "table" then
		for _, item in pairs(itemDelta.added) do
			if type(item) == "table" and item.ID and item.slot then
				table.insert(sanitized.added, item)
			end
		end
	end

	-- Sanitize modified items
	if itemDelta.modified and type(itemDelta.modified) == "table" then
		for _, item in pairs(itemDelta.modified) do
			if type(item) == "table" and item.slot then
				table.insert(sanitized.modified, item)
			end
		end
	end

	-- Sanitize removed slots
	if itemDelta.removed and type(itemDelta.removed) == "table" then
		for _, slot in pairs(itemDelta.removed) do
			if type(slot) == "number" then
				table.insert(sanitized.removed, slot)
			end
		end
	end

	return sanitized
end

-- Compute a hash of inventory state to detect actual changes (v0.8.0)
-- Only updates version timestamps when this hash changes
function TOGBankClassic_DeltaComms:ComputeInventoryHash(bank, bags, mailOrMoney, money)
	-- Handle multiple calling conventions:
	-- SYNC-006 (aggregated): ComputeInventoryHash(items, nil, nil, money) - items is direct array
	-- Pre-SYNC-006: ComputeInventoryHash(bank, bags, money) - bank/bags have .items, no mail

	-- Detect SYNC-006 aggregated call: first param is array, second is nil
	if bank and type(bank) == "table" and bags == nil and mailOrMoney == nil then
		-- SYNC-006: bank is actually the aggregated items array, money is the 4th param
		local items = bank
		local actualMoney = money or 0

		local parts = {}
		table.insert(parts, tostring(actualMoney))

		-- Hash aggregated items directly
		local function hashItems(itemsArray)
			if not itemsArray or type(itemsArray) ~= "table" then
				return ""
			end
			local sorted = {}
			for _, item in ipairs(itemsArray) do
				if item and item.ID then
					table.insert(sorted, string.format("%d:%d", item.ID, item.Count or 0))
				end
			end
			table.sort(sorted)
			return table.concat(sorted, ",")
		end

		table.insert(parts, "I:" .. hashItems(items))
		local combined = table.concat(parts, "|")
		return TOGBankClassic_Core:Checksum(combined)
	end

	-- Pre-SYNC-006 calling convention: ComputeInventoryHash(bank, bags, money)
	-- mailOrMoney is actually money (number), no mail parameter exists
	local actualMoney = mailOrMoney or 0

	local parts = {}

	-- Include money
	table.insert(parts, tostring(actualMoney))

	-- Helper to hash an items array
	local function hashItems(items)
		if not items or type(items) ~= "table" then
			return ""
		end

		-- Sort items by ID+Count to get consistent order
		local sorted = {}
		for _, item in ipairs(items) do
			if item and item.ID then
				table.insert(sorted, string.format("%d:%d", item.ID, item.Count or 0))
			end
		end
		table.sort(sorted)
		return table.concat(sorted, ",")
	end

	-- Include bank items (pre-SYNC-006 structure: bank.items)
	if bank and bank.items then
		table.insert(parts, "B:" .. hashItems(bank.items))
	end

	-- Include bag items (pre-SYNC-006 structure: bags.items)
	if bags and bags.items then
		table.insert(parts, "G:" .. hashItems(bags.items))
	end

	-- Note: Pre-SYNC-006 clients never had mail, so no mail hashing

	-- Concatenate all parts and compute simple hash
	local combined = table.concat(parts, "|")

	-- Use same hash function as checksum for consistency
	local sum = 0
	local len = #combined
	for i = 1, len do
		local byte = string.byte(combined, i)
		sum = (sum * 31 + byte) % 2147483647
	end
	sum = (sum * 31 + len) % 2147483647

	return sum
end

-- DELTA PROTOCOL FUNCTIONS --

-- Check if delta sync should be used
function TOGBankClassic_DeltaComms:ShouldUseDelta()
	-- Check force flags first (for testing)
	if FEATURES and FEATURES.FORCE_DELTA_SYNC then
		return true
	end

	-- Check feature flags
	if not FEATURES or not FEATURES.DELTA_ENABLED then
		return false
	end
	if FEATURES.FORCE_FULL_SYNC then
		return false
	end

	-- v0.8.0: Delta protocol always enabled if feature flag is on
	-- No guild support threshold - clients will use delta if both sides support it
	return PROTOCOL.SUPPORTS_DELTA
end

-- Get peer protocol capabilities
function TOGBankClassic_DeltaComms:GetPeerCapabilities(guildName, sender)
	if not guildName or not sender then
		return nil
	end

	return TOGBankClassic_Database:GetPeerProtocol(guildName, sender)
end

-- Strip Links from delta for bandwidth savings (v0.8.0)
function TOGBankClassic_DeltaComms:StripDeltaLinks(delta)
	if not delta or not delta.changes then
		return nil
	end

	local function stripItemArray(items)
		if not items then return nil end
		local stripped = {}
		for _, item in ipairs(items) do
			local strippedItem = {
				ID = item.ID,
				Count = item.Count
				-- Link removed - receiver will reconstruct
			}
			local forceLink = item.ForceLink == true
			-- Preserve full link for gear/uncached/forced items, otherwise store ItemString
			if item.Link then
				if forceLink or (TOGBankClassic_Item and TOGBankClassic_Item.NeedsLink and TOGBankClassic_Item:NeedsLink(item.Link)) then
					strippedItem.Link = item.Link
				else
					local itemString = string.match(item.Link, "item:([^|]+)")
					if itemString then
						strippedItem.ItemString = itemString
					end
				end
			elseif item.ItemString then
				strippedItem.ItemString = item.ItemString
			end
			-- Preserve Info if present (for modified items)
			if item.Info then
				strippedItem.Info = item.Info
			end
			table.insert(stripped, strippedItem)
		end
		return stripped
	end

	local strippedDelta = {
		type = delta.type,
		name = delta.name,
		version = delta.version,
		updatedAt = delta.updatedAt,
		inventoryHash = delta.inventoryHash,
		-- v0.8.0: baseVersion no longer included (8 bytes saved)
		changes = {}
	}

	-- Copy money change (no Link to strip)
	if delta.changes.money then
		strippedDelta.changes.money = delta.changes.money
	end

	-- Copy mailHash change
	if delta.changes.mailHash then
		strippedDelta.changes.mailHash = delta.changes.mailHash
	end

	-- Strip Links from bank changes
	if delta.changes.bank then
		strippedDelta.changes.bank = {
			added = stripItemArray(delta.changes.bank.added),
			modified = stripItemArray(delta.changes.bank.modified),
			removed = stripItemArray(delta.changes.bank.removed)
		}
	end

	-- Strip Links from bags changes
	if delta.changes.bags then
		strippedDelta.changes.bags = {
			added = stripItemArray(delta.changes.bags.added),
			modified = stripItemArray(delta.changes.bags.modified),
			removed = stripItemArray(delta.changes.bags.removed)
		}
	end

	-- Strip Links from mail changes
	if delta.changes.mail then
		strippedDelta.changes.mail = {
			added = stripItemArray(delta.changes.mail.added),
			modified = stripItemArray(delta.changes.mail.modified),
			removed = stripItemArray(delta.changes.mail.removed)
		}
	end

	return strippedDelta
end

-- DELTA COMPUTATION FUNCTIONS --

-- Compare two items for equality
function TOGBankClassic_DeltaComms:ItemsEqual(item1, item2)
	if not item1 and not item2 then
		return true
	end
	if not item1 or not item2 then
		return false
	end

	-- Compare key fields
	if item1.ID ~= item2.ID then
		return false
	end
	if item1.Count ~= item2.Count then
		return false
	end
	-- Only compare Links when both items have them.
	-- Minimal baseline items (from state-summary expandMinimalItems) have no Link.
	-- Comparing nil vs an actual link would always return false, causing every
	-- unchanged item to land in modified[] and producing full-sized deltas.
	if item1.Link ~= nil and item2.Link ~= nil then
		if item1.Link ~= item2.Link then
			return false
		end
	end

	-- Compare Info table if present (deep comparison)
	if item1.Info or item2.Info then
		if not item1.Info or not item2.Info then
			return false
		end
		for k, v in pairs(item1.Info) do
			if item2.Info[k] ~= v then
				return false
			end
		end
		for k, v in pairs(item2.Info) do
			if item1.Info[k] ~= v then
				return false
			end
		end
	end

	return true
end

-- Extract only the fields that changed between two items
function TOGBankClassic_DeltaComms:GetChangedFields(oldItem, newItem)
	-- Always include ID and Link for identification (merged items use these as keys)
	local changes = {
		ID = newItem.ID,
		Link = newItem.Link,
		ItemString = newItem.ItemString,
	}

	-- Include changed fields
	if oldItem.Count ~= newItem.Count then
		changes.Count = newItem.Count
	end
	if oldItem.Info or newItem.Info then
		if not oldItem.Info or not newItem.Info or not self:ItemsEqual(oldItem, newItem) then
			changes.Info = newItem.Info
		end
	end

	return changes
end

-- Build a slot-indexed lookup table from items array
function TOGBankClassic_DeltaComms:BuildItemIndex(items)
	local index = {}
	if not items then
		return index
	end

	local withLinks = 0
	local withoutLinks = 0
	
	for _, item in pairs(items) do
		if item and item.ID then
			-- DUPLICATION-FIX: Handle items without Links (from minimal baselines)
			-- Items without Links use ID-only key for deduplication
			if item.Link or item.ItemString then
				-- Full item with Link - use normalized key (strips character level)
				local normalizedKey = TOGBankClassic_Item:GetItemKey(item.Link or item.ItemString)
				local key = tostring(item.ID) .. normalizedKey
				index[key] = item
				withLinks = withLinks + 1
			else
				-- Minimal item without Link - use ID-only key as fallback
				-- This allows baseline items (ID+Count only) to be matched during delta computation
				local key = tostring(item.ID)
				-- Only add if not already present (prefer items with Links)
				if not index[key] then
					index[key] = item
					withoutLinks = withoutLinks + 1
				end
			end
		end
	end
	
	if withoutLinks > 0 then
		TOGBankClassic_Output:Debug("DELTA", "[DEDUP-FIX] BuildItemIndex: indexed %d items (%d with links, %d without links)",
			withLinks + withoutLinks, withLinks, withoutLinks)
	end

	return index
end

-- Compute delta between old and new item sets
function TOGBankClassic_DeltaComms:ComputeItemDelta(oldItems, newItems)
	local delta = { added = {}, modified = {}, removed = {} }

	oldItems = oldItems or {}
	newItems = newItems or {}

	-- Build item index for old items by itemID+Link key
	local oldByKey = self:BuildItemIndex(oldItems)
	
	-- Build ID-only lookup for items without Links (from minimal baselines)
	local oldByIDOnly = {}
	for _, item in pairs(oldItems) do
		if item and item.ID and not (item.Link or item.ItemString) then
			oldByIDOnly[tostring(item.ID)] = item
		end
	end

	-- DUPLICATION-FIX-003: Track which oldItems entries have been matched by deep fallback.
	-- Without this, multiple new items with the same base ID (e.g. "Stone Hammer" plain and
	-- "Stone Hammer of Tiger" suffix, both ID=15260) would both deep-fallback to the same
	-- old item, marking both as "modified" rather than one matched + one new.
	local deepFallbackUsed = {}  -- keyed by item identity (the table itself)

	-- Find added and modified items
	local fallbackMatches = 0
	local deepFallbackMatches = 0
	for _, newItem in pairs(newItems) do
		if newItem and newItem.ID then
			-- DUPLICATION-FIX: Try full key first, then fallback to ID-only
			local key
			local oldItem = nil
			local usedFallback = false
			local usedDeepFallback = false
			
			if newItem.Link or newItem.ItemString then
				-- Full item with Link - use normalized key (strips character level)
				local normalizedKey = TOGBankClassic_Item:GetItemKey(newItem.Link or newItem.ItemString)
				key = tostring(newItem.ID) .. normalizedKey
				oldItem = oldByKey[key]
				
				-- Fallback 1: check ID-only index if not found (handles minimal baseline items)
				if not oldItem then
					oldItem = oldByIDOnly[tostring(newItem.ID)]
					if oldItem then
						key = tostring(newItem.ID)  -- Use ID-only key for marking processed
						usedFallback = true
						fallbackMatches = fallbackMatches + 1
					end
				end
				
				-- Fallback 2: search all oldItems by ID if normalized key lookup failed.
				-- DUPLICATION-FIX-003: Skip items already matched by a previous deep fallback.
				-- Without this guard, "Stone Hammer" (plain) and "Stone Hammer of Tiger" (suffix)
				-- would BOTH match the same minimal baseline entry {ID=15260, Count=N}, causing
				-- one to be treated as modified (correct) and the other to send a spurious
				-- second "modified" for the same old item.
				if not oldItem then
					for _, item in pairs(oldItems) do
						if item and item.ID == newItem.ID and not deepFallbackUsed[item] then
							oldItem = item
							key = tostring(newItem.ID)  -- Use ID as key for tracking
							usedDeepFallback = true
							deepFallbackUsed[item] = true  -- Mark so next item won't re-use it
							deepFallbackMatches = deepFallbackMatches + 1
							break
						end
					end
				end
			else
				-- Minimal item without Link - use ID-only key
				key = tostring(newItem.ID)
				oldItem = oldByKey[key] or oldByIDOnly[key]
			end
			
			if not oldItem then
				-- Item was added
				table.insert(delta.added, newItem)
			elseif not self:ItemsEqual(oldItem, newItem) then
				-- Item was modified (quantity or other field changed)
				table.insert(delta.modified, self:GetChangedFields(oldItem, newItem))
			end

			-- Mark as processed
			if key then
				oldByKey[key] = nil
				oldByIDOnly[key] = nil
			end
			
			-- If we used deep fallback, we need to remove the matched item from indices
			-- since it was found under a different key than expected
			if usedDeepFallback and oldItem then
				-- Remove from oldByKey by searching for the item
				for k, v in pairs(oldByKey) do
					if v == oldItem then
						oldByKey[k] = nil
						break
					end
				end
				-- Remove from oldByIDOnly as well
				local idKey = tostring(oldItem.ID)
				if oldByIDOnly[idKey] == oldItem then
					oldByIDOnly[idKey] = nil
				end
			end
		end
	end
	
	if fallbackMatches > 0 then
		TOGBankClassic_Output:Debug("DELTA", "[DEDUP-FIX] ComputeItemDelta: matched %d items using ID-only fallback (prevents duplication)",
			fallbackMatches)
	end
	
	if deepFallbackMatches > 0 then
		TOGBankClassic_Output:Debug("DELTA", "[DEDUP-FIX] ComputeItemDelta: matched %d items using deep ID fallback - link normalization mismatch detected",
			deepFallbackMatches)
	end

	-- Remaining old items were removed
	-- DUPLICATION-FIX-003: Preserve Link/ItemString in removes for items that have them.
	-- ID-only removes can't distinguish "Stone Hammer" from "Stone Hammer of Tiger" when
	-- both variants of ID=15260 exist on the receiver — the wrong one gets removed.
	for _, item in pairs(oldByKey) do
		local removed = { ID = item.ID }
		if item.Link then
			removed.Link = item.Link
		elseif item.ItemString then
			removed.ItemString = item.ItemString
		end
		table.insert(delta.removed, removed)
	end
	for _, item in pairs(oldByIDOnly) do
		-- Also check ID-only items that weren't processed
		table.insert(delta.removed, { ID = item.ID })
	end

	return delta
end

-- Compute full delta for an alt
function TOGBankClassic_DeltaComms:ComputeDelta(guildName, altName, currentAlt, requesterInventoryHash, requesterMailHash, requesterBaseline)
	return TOGBankClassic_Performance:Track("ComputeDelta", function()
		if not guildName or not altName or not currentAlt then
			return nil
		end

		-- DELTA-020: Compute delta using requester's actual baseline from state summary
		-- requesterBaseline = { bank = {}, bags = {}, mail = {}, money = 0 } with minimal item structures
		local previous = nil
		local currentHash = currentAlt.inventoryHash or 0
		local currentMailHash = currentAlt.mailHash or 0
		requesterMailHash = requesterMailHash or 0  -- Default to 0 if not provided

		-- Helper: Convert minimal item structure to full structure (without Links)
		local function expandMinimalItems(minimalItems)
			if not minimalItems then return {} end
			local expanded = {}
			for _, item in ipairs(minimalItems) do
				-- Create full item structure with ID and Count, Link will be nil
				table.insert(expanded, { ID = item.ID, Count = item.Count or 1 })
			end
			return expanded
		end

		if requesterInventoryHash and requesterInventoryHash ~= 0 then
			-- Requester has data - check if it matches current (both inventory AND mail)
			if requesterInventoryHash == currentHash and requesterMailHash == currentMailHash then
				-- Hash match (both hashes) - no changes needed (empty delta)
				TOGBankClassic_Output:Debug("DELTA", "[MAIL-SYNC] Hash match: requester inv=%d mail=%d, banker inv=%d mail=%d (no changes)",
					requesterInventoryHash, requesterMailHash, currentHash, currentMailHash)
				previous = currentAlt  -- Use current as previous (results in empty delta)
			elseif requesterInventoryHash == currentHash and requesterMailHash ~= currentMailHash then
				-- Inventory matches but mail changed - use requester's actual baseline if available
				if requesterBaseline then
					-- DELTA-020: Use requester's sent baseline (correct approach)
					previous = {
						items = {},
						money = requesterBaseline.money or 0,
						mailHash = requesterMailHash,
						bank = { items = expandMinimalItems(requesterBaseline.bank) },
						bags = { items = expandMinimalItems(requesterBaseline.bags) },
						mail = { items = expandMinimalItems(requesterBaseline.mail) },
					}
					TOGBankClassic_Output:Debug("DELTA", "[DELTA-020] Mail changed: using requester's actual baseline (bank=%d, bags=%d, mail=%d)",
						#previous.bank.items, #previous.bags.items, #previous.mail.items)
				else
					-- BUGFIX: No requester baseline - cannot compute accurate delta
					-- GetSnapshot returns RESPONDER's saved data, not REQUESTER's actual data
					-- This causes severe duplication (items added multiple times)
					-- Force full sync by using empty baseline instead
					previous = { items = {}, money = 0, mailHash = 0, bank = { items = {} }, bags = { items = {} }, mail = { items = {} } }
					TOGBankClassic_Output:Warn("DELTA", "[DUPLICATION-FIX] Missing requester baseline (mail change) - forcing full sync for %s (mail=%d→%d)",
						altName, requesterMailHash, currentMailHash)
				end
			else
				-- Hash mismatch - use requester's actual baseline if available
				if requesterBaseline then
					-- DELTA-020: Use requester's sent baseline (correct approach - fixes duplication bug!)
					previous = {
						items = {},
						money = requesterBaseline.money or 0,
						mailHash = requesterMailHash,
						bank = { items = expandMinimalItems(requesterBaseline.bank) },
						bags = { items = expandMinimalItems(requesterBaseline.bags) },
						mail = { items = expandMinimalItems(requesterBaseline.mail) },
					}
					TOGBankClassic_Output:Debug("DELTA", "[DELTA-020] Using requester's actual baseline: inv=%d→%d (bank=%d, bags=%d, mail=%d items)",
						requesterInventoryHash, currentHash,
						#previous.bank.items, #previous.bags.items, #previous.mail.items)
				else
					-- BUGFIX: No requester baseline - cannot compute accurate delta
					-- GetSnapshot returns RESPONDER's saved data, not REQUESTER's actual data
					-- This causes severe duplication (items added multiple times)
					-- Force full sync by using empty baseline instead
					previous = { items = {}, money = 0, mailHash = 0, bank = { items = {} }, bags = { items = {} }, mail = { items = {} } }
					TOGBankClassic_Output:Warn("DELTA", "[DUPLICATION-FIX] Missing requester baseline - forcing full sync for %s (hash=%d→%d)",
						altName, requesterInventoryHash or 0, currentHash)
				end
			end
		else
			-- Requester has no data (hash 0 or nil) - send everything as delta additions
			previous = { items = {}, money = 0, mailHash = 0, bank = { items = {} }, bags = { items = {} }, mail = { items = {} } }
			TOGBankClassic_Output:Debug("DELTA", "[DELTA-014] Requester has no data (hash=%s), sending all as additions",
				tostring(requesterInventoryHash))
		end

		if not previous then
			return nil
		end

		-- Build delta structure
		-- v0.8.0: baseVersion removed (8 bytes saved)
		-- In pull-based protocol, receiver states what they have, making baseVersion redundant
		local delta = {
			type = "alt-delta",
			name = altName,
			version = currentAlt.version or GetServerTime(),
			updatedAt = currentAlt.inventoryUpdatedAt or currentAlt.version or GetServerTime(),
			inventoryHash = currentAlt.inventoryHash or 0,
			-- baseVersion removed for v0.8.0 (still accepted when receiving for backwards compatibility)
			changes = {},
		}

		-- Money change
		if currentAlt.money ~= previous.money then
			delta.changes.money = currentAlt.money
		end

		-- MAIL-012: Track mailHash changes so receivers can detect mail updates
		-- mailHash allows clients to identify when mail data has changed without comparing full item arrays
		if currentAlt.mailHash ~= previous.mailHash then
			delta.changes.mailHash = currentAlt.mailHash
			TOGBankClassic_Output:Debug(
				"DELTA",
				"[MAIL-012] Mail hash changed for %s: %s → %s",
				altName,
				tostring(previous.mailHash),
				tostring(currentAlt.mailHash)
			)
		end

		-- Compute separate deltas for bank, bags, and mail inventories
		-- These are sent individually (not aggregated) so receiver can populate them correctly
		local previousBank = (previous.bank and previous.bank.items) or {}
		local currentBank = (currentAlt.bank and currentAlt.bank.items) or {}
		delta.changes.bank = self:ComputeItemDelta(previousBank, currentBank)

		local previousBags = (previous.bags and previous.bags.items) or {}
		local currentBags = (currentAlt.bags and currentAlt.bags.items) or {}
		delta.changes.bags = self:ComputeItemDelta(previousBags, currentBags)

		local previousMail = (previous.mail and previous.mail.items) or {}
		local currentMail = (currentAlt.mail and currentAlt.mail.items) or {}
		delta.changes.mail = self:ComputeItemDelta(previousMail, currentMail)

		-- Debug: Log what's being sent
		TOGBankClassic_Output:Debug(
			"DELTA",
			"[SEPARATE-INV] Delta for %s: bank=%d→%d, bags=%d→%d, mail=%d→%d",
			altName,
			#previousBank, #currentBank,
			#previousBags, #currentBags,
			#previousMail, #currentMail
		)

		return delta
	end)
end

-- Estimate serialized size of a data structure
function TOGBankClassic_DeltaComms:EstimateSize(data)
	if not data then
		return 0
	end

	-- Rough estimate: serialize and measure length
	local serialized = TOGBankClassic_Core:SerializeWithChecksum(data)
	return string.len(serialized or "")
end

-- Check if delta has any actual changes
function TOGBankClassic_DeltaComms:DeltaHasChanges(delta)
	if not delta or not delta.changes then
		return false
	end

	local changes = delta.changes

	-- Check money change
	if changes.money then
		return true
	end

	-- MAIL-012: Check mailHash change
	if changes.mailHash ~= nil then
		return true
	end

	-- Check bank changes
	if changes.bank then
		if next(changes.bank.added) or next(changes.bank.modified) or next(changes.bank.removed) then
			return true
		end
	end

	-- Check bags changes
	if changes.bags then
		if next(changes.bags.added) or next(changes.bags.modified) or next(changes.bags.removed) then
			return true
		end
	end

	-- Check mail changes
	if changes.mail then
		if next(changes.mail.added) or next(changes.mail.modified) or next(changes.mail.removed) then
			return true
		end
	end

	-- Legacy: Check aggregated items changes (for backwards compatibility)
	if changes.items then
		if next(changes.items.added) or next(changes.items.modified) or next(changes.items.removed) then
			return true
		end
	end

	return false
end

-- DELTA APPLICATION FUNCTIONS --

-- Apply item delta to an items table
function TOGBankClassic_DeltaComms:ApplyItemDelta(items, delta)
	if not items or not delta then
		return false
	end

	-- Build current items index by itemKey
	local itemsByKey = self:BuildItemIndex(items)
	
	-- Build ID-only lookup for items without Links
	local itemsByIDOnly = {}
	for _, item in pairs(items) do
		if item and item.ID and not (item.Link or item.ItemString) then
			itemsByIDOnly[tostring(item.ID)] = item
		end
	end

	-- STALE-INDEX-FIX: Process operations in order: removed → modified → added
	-- This prevents indexes from becoming invalid when Aggregate() clears the array
	
	-- STEP 1: Remove items
	-- v0.8.0: Removed items now only have ID (Link removed for bandwidth savings)
	if delta.removed then
		for _, removedItem in ipairs(delta.removed) do
			if removedItem and removedItem.ID then
				-- v0.8.0: Match by ID only (Link field removed)
				-- Still support old format with Link for backwards compatibility
				if removedItem.Link then
					-- Has Link (new format with link-preserved remove, OR old v0.7.0 format):
					-- Match by normalized key so suffix variants are distinguished precisely
					local normalizedRemovedKey = TOGBankClassic_Item:GetItemKey(removedItem.Link)
					local key = tostring(removedItem.ID) .. normalizedRemovedKey
					for i = #items, 1, -1 do
						local item = items[i]
						if item and item.ID and (item.Link or item.ItemString) then
							local normalizedItemKey = TOGBankClassic_Item:GetItemKey(item.Link or item.ItemString)
							local itemKey = tostring(item.ID) .. normalizedItemKey
							if itemKey == key then
								table.remove(items, i)
								break
							end
						end
					end
				else
					-- New format (v0.8.0): Only has ID, match by ID only
					for i = #items, 1, -1 do
						local item = items[i]
						if item and item.ID == removedItem.ID then
							table.remove(items, i)
							break  -- Remove first match only
						end
					end
				end
			end
		end
	end

	-- STEP 2: Modify existing items (MUST be before added to use valid indexes)
	if delta.modified then
		for _, changes in ipairs(delta.modified) do
			if changes and changes.ID then
				-- DUPLICATION-FIX: Try full key first, then fallback to ID-only
				local existingItem = nil
				
				if changes.Link or changes.ItemString then
					-- Full item with Link - use normalized key
					local normalizedKey = TOGBankClassic_Item:GetItemKey(changes.Link or changes.ItemString)
					local key = tostring(changes.ID) .. normalizedKey
					existingItem = itemsByKey[key]
					
					-- Fallback: check ID-only index if not found
					if not existingItem then
						existingItem = itemsByIDOnly[tostring(changes.ID)]
					end
				else
					-- Minimal item without Link - use ID-only key
					local key = tostring(changes.ID)
					existingItem = itemsByKey[key] or itemsByIDOnly[key]
				end

				if existingItem then
					-- Apply changed fields to existing item
					for field, value in pairs(changes) do
						existingItem[field] = value
					end
				else
					-- Item doesn't exist (shouldn't happen), add as new.
					-- ITEM-003 GUARD: Reject linkless items for weapon/armor types (same logic as STEP 3).
					local guardBlock = false
					if not changes.Link and TOGBankClassic_Item then
						local needsLink = TOGBankClassic_Item:ItemClassNeedsLink(changes.ID)
						if needsLink == true then
							guardBlock = true
							TOGBankClassic_Output:Debug("DELTA", "[ITEM-003] STEP2: blocked linkless modified-as-new weapon/armor ID=%d", changes.ID)
						elseif needsLink == nil then
							-- Class not cached; block if any linked entry already exists for this base ID
							for _, existingEntry in ipairs(items) do
								if existingEntry and existingEntry.ID == changes.ID and existingEntry.Link then
									guardBlock = true
									TOGBankClassic_Output:Debug("DELTA", "[ITEM-003] STEP2: blocked linkless modified-as-new ID=%d (linked entry exists, class uncached)", changes.ID)
									break
								end
							end
						end
					end
					if not guardBlock then
						table.insert(items, changes)
						TOGBankClassic_Output:Debug("DELTA", "[STALE-INDEX-FIX] Modified item not found, adding as new: ID=%d", changes.ID)
					end
				end
			end
		end
	end

	-- STEP 3: Add new items (CAN invalidate indexes, but no more operations depend on them)
	if delta.added then
		-- DUPLICATION-FIX-003: Use normalized key (Link/ItemString → GetItemKey) to find existing items.
		-- The previous ID-only lookup caused items with same base ID but different suffixes
		-- (e.g., "Stone Hammer" ×4 and "Stone Hammer of Tiger" ×1, both ID=15260) to collide:
		-- the second item processed would find the first by ID and overwrite it, corrupting
		-- counts and links. Fix: match by normalized key; only fall back to ID-only for
		-- truly linkless existing entries (old-format upgrade: {ID,Count} → linked item).
		local updated = 0
		local added = 0

		for _, newItem in ipairs(delta.added) do
			if newItem and newItem.ID and (newItem.Link or newItem.ItemString) then
				local existingItem = nil
				local newNormKey = TOGBankClassic_Item:GetItemKey(newItem.Link or newItem.ItemString)
				local newFullKey = tostring(newItem.ID) .. newNormKey

				-- Primary: exact normalized-key match (distinguishes suffix variants)
				for _, item in ipairs(items) do
					if item and item.ID == newItem.ID then
						local existingNormKey = TOGBankClassic_Item:GetItemKey(item.Link or item.ItemString or "")
						if (tostring(item.ID) .. existingNormKey) == newFullKey then
							existingItem = item
							break
						end
					end
				end

				-- Fallback: ID-only match ONLY for linkless existing entries
				-- (upgrades old-format {ID,Count} stubs to linked items)
				if not existingItem then
					for _, item in ipairs(items) do
						if item and item.ID == newItem.ID and not item.Link and not item.ItemString then
							existingItem = item
							break
						end
					end
				end

				if existingItem then
					-- Item exists - UPDATE quantities and fields
					existingItem.Count = newItem.Count
					existingItem.Link = newItem.Link or existingItem.Link
					existingItem.ItemString = newItem.ItemString or existingItem.ItemString
					existingItem.ForceLink = newItem.ForceLink or existingItem.ForceLink
					if newItem.Info then
						existingItem.Info = newItem.Info
					end
					updated = updated + 1
				else
					-- Item doesn't exist - ADD it.
					-- ITEM-003 GUARD: Reject linkless items for weapon/armor types.
					-- When GetItemInfo confirms class 2 (Weapon) or 4 (Armor), a Link is required
					-- to distinguish suffix variants (e.g. plain vs. "of the Wolf"). Accepting an
					-- ItemString-only entry would create a ghost plain-weapon stack that dedup
					-- cannot merge with existing suffixed entries sharing the same base ID.
					-- If the item class is uncached, fall back to: block if any linked entry for
					-- this base ID already exists in storage (the linked version is authoritative).
					local guardBlock = false
					if not newItem.Link and TOGBankClassic_Item then
						local needsLink = TOGBankClassic_Item:ItemClassNeedsLink(newItem.ID)
						if needsLink == true then
							guardBlock = true
							TOGBankClassic_Output:Debug("DELTA", "[ITEM-003] STEP3: blocked linkless weapon/armor ID=%d (class confirmed)", newItem.ID)
						elseif needsLink == nil then
							-- Class not cached; block if any linked entry already exists for this base ID
							for _, existingEntry in ipairs(items) do
								if existingEntry and existingEntry.ID == newItem.ID and existingEntry.Link then
									guardBlock = true
									TOGBankClassic_Output:Debug("DELTA", "[ITEM-003] STEP3: blocked linkless ID=%d (linked entry exists, class uncached)", newItem.ID)
									break
								end
							end
						end
					end
					if not guardBlock then
						table.insert(items, newItem)
						added = added + 1
					end
				end
			end
		end

		TOGBankClassic_Output:Debug("DELTA", "Applied %d added items (%d updated existing, %d new)",
			#delta.added, updated, added)
	end

	return true
end

-- Apply a delta to alt data
function TOGBankClassic_DeltaComms:ApplyDelta(guildInfo, altName, deltaData, sender)
	return TOGBankClassic_Performance:Track("ApplyDelta", function()
		if not guildInfo then
			return ADOPTION_STATUS.IGNORED
		end

		local applyStart = debugprofilestop()
		local norm = TOGBankClassic_Guild:NormalizeName(altName)
		local current = guildInfo.alts[norm]
		local currentIsBanker = TOGBankClassic_Guild:IsBank(norm)

		-- Validate base version matches
		if not current then
			-- No existing data: adopt delta against empty baseline to avoid full sync fallback
			if not guildInfo.alts then
				guildInfo.alts = {}
			end
			current = {
				name = norm,
				version = 0,
				money = 0,
				items = {},
				inventoryHash = 0,
				inventoryUpdatedAt = 0,
				mailHash = 0,
			}
			guildInfo.alts[norm] = current
			TOGBankClassic_Output:Debug("DELTA", "No existing data for %s; applying delta against empty baseline", norm)
		end

		-- DATA-004: Protect banker data - bankers are the source of truth
		local player = UnitName("player")
		local realm = GetNormalizedRealmName()
		local playerFull = player .. "-" .. realm
		local playerNorm = TOGBankClassic_Guild:NormalizeName(playerFull)
		local playerIsBanker = TOGBankClassic_Guild:IsBank(playerNorm)

		if playerIsBanker then
			-- We are a banker - protect our own data and other banker data

			-- CRITICAL: If this delta is about US, reject it (we are the source of truth for our own data)
			if norm == playerNorm then
				local errorMsg = string.format(
					"Rejected delta from %s about ourselves (banker is source of truth for own data)",
					sender or "unknown"
				)
				TOGBankClassic_Output:Debug("DELTA", "[DATA-004] %s", errorMsg)
				-- Not an error - this is expected banker protection, don't record as error
				return ADOPTION_STATUS.UNAUTHORIZED
			end

			-- Also protect OTHER banker data from non-banker updates
			local senderNorm = sender and TOGBankClassic_Guild:NormalizeName(sender) or nil
			local senderIsBanker = senderNorm and TOGBankClassic_Guild:IsBank(senderNorm) or false

			if currentIsBanker and not senderIsBanker then
				-- Reject: non-banker trying to update banker data
				local errorMsg = string.format(
					"Rejected delta from non-banker %s for banker %s (bankers are source of truth)",
					sender or "unknown",
					norm
				)
				TOGBankClassic_Output:Debug("DELTA", "[DATA-004] %s", errorMsg)
				-- Not an error - this is expected banker protection, don't record as error
				return ADOPTION_STATUS.UNAUTHORIZED
			end
		end
		-- Non-bankers accept all deltas (they're not the authority)

		-- Newest-wins for non-banker alts
		local incomingUpdatedAt = deltaData.updatedAt or deltaData.version
		local existingUpdatedAt = current.inventoryUpdatedAt or current.version
		if not currentIsBanker and incomingUpdatedAt and existingUpdatedAt and incomingUpdatedAt < existingUpdatedAt then
			return ADOPTION_STATUS.STALE
		end

		local currentVersion = current.version or 0
		-- v0.8.0: baseVersion no longer sent; retained as fallback for log output only
		local baseVersion = deltaData.baseVersion or currentVersion

		-- Apply changes (wrapped in pcall for safety)
		local success, err = pcall(function()
			local changes = deltaData.changes

			if changes.money then
				current.money = changes.money
			end

			-- MAIL-012: Apply mailHash changes
			-- This allows receivers to detect when mail data has been updated
			if changes.mailHash ~= nil then
				current.mailHash = changes.mailHash
				TOGBankClassic_Output:Debug("DELTA", "[MAIL-012] Updated mailHash for %s to %s", norm, tostring(changes.mailHash))
			end

			-- Apply bank changes
			if changes.bank then
				if not current.bank then
					current.bank = { items = {} }
				end
				if not current.bank.items then
					current.bank.items = {}
				end
				self:ApplyItemDelta(current.bank.items, changes.bank)
				-- DEFENSIVE: Deduplicate bank items after delta application
				if TOGBankClassic_Item and #current.bank.items > 0 then
					local deduped = TOGBankClassic_Item:Aggregate(current.bank.items, nil)
					current.bank.items = {}
					local keys = {}
					for k in pairs(deduped) do table.insert(keys, k) end
					table.sort(keys)
					for _, k in ipairs(keys) do
						table.insert(current.bank.items, deduped[k])
					end
				end
				TOGBankClassic_Output:Debug("DELTA", "[SEPARATE-INV] Applied bank delta for %s: now %d items", norm, #current.bank.items)
			end

			-- Apply bags changes
			if changes.bags then
				if not current.bags then
					current.bags = { items = {} }
				end
				if not current.bags.items then
					current.bags.items = {}
				end
				self:ApplyItemDelta(current.bags.items, changes.bags)
				-- DEFENSIVE: Deduplicate bags items after delta application
				if TOGBankClassic_Item and #current.bags.items > 0 then
					local deduped = TOGBankClassic_Item:Aggregate(current.bags.items, nil)
					current.bags.items = {}
					local keys = {}
					for k in pairs(deduped) do table.insert(keys, k) end
					table.sort(keys)
					for _, k in ipairs(keys) do
						table.insert(current.bags.items, deduped[k])
					end
				end
				TOGBankClassic_Output:Debug("DELTA", "[SEPARATE-INV] Applied bags delta for %s: now %d items", norm, #current.bags.items)
			end

			-- Apply mail changes
			if changes.mail then
				if not current.mail then
					current.mail = { items = {} }
				end
				if not current.mail.items then
					current.mail.items = {}
				end
				self:ApplyItemDelta(current.mail.items, changes.mail)
				-- DEFENSIVE: Deduplicate mail items after delta application
				if TOGBankClassic_Item and #current.mail.items > 0 then
					local deduped = TOGBankClassic_Item:Aggregate(current.mail.items, nil)
					current.mail.items = {}
					local keys = {}
					for k in pairs(deduped) do table.insert(keys, k) end
					table.sort(keys)
					for _, k in ipairs(keys) do
						table.insert(current.mail.items, deduped[k])
					end
				end
				TOGBankClassic_Output:Debug("DELTA", "[SEPARATE-INV] Applied mail delta for %s: now %d items", norm, #current.mail.items)
			end

			-- Recalculate aggregated items for UI display
			if changes.bank or changes.bags or changes.mail then
				local bankItems = (current.bank and current.bank.items) or {}
				local bagItems = (current.bags and current.bags.items) or {}
				local mailItems = (current.mail and current.mail.items) or {}
				
				-- Aggregate all three sources using Item module
				if TOGBankClassic_Item then
					local aggregated = TOGBankClassic_Item:Aggregate(bankItems, bagItems)
					aggregated = TOGBankClassic_Item:Aggregate(aggregated, mailItems)
					current.items = {}
					-- DETERMINISTIC-ORDER-FIX: Sort keys before inserting to ensure consistent array ordering
					local keys = {}
					for k in pairs(aggregated) do
						table.insert(keys, k)
					end
					table.sort(keys)
					for _, k in ipairs(keys) do
						table.insert(current.items, aggregated[k])
					end
					TOGBankClassic_Output:Debug("DELTA", "[SEPARATE-INV] Recalculated aggregated items for %s: %d items (bank=%d, bags=%d, mail=%d)",
						norm, #current.items, #bankItems, #bagItems, #mailItems)
				end
			end

			-- Legacy: Apply aggregated items changes (for backwards compatibility with old deltas)
			if changes.items then
				if not current.items then
					current.items = {}
				end
				self:ApplyItemDelta(current.items, changes.items)
				TOGBankClassic_Output:Debug("DELTA", "[LEGACY] Applied aggregated items delta for %s: now %d items", norm, #current.items)
			end

			-- Update version
			current.version = deltaData.version
			current.inventoryUpdatedAt = deltaData.updatedAt or deltaData.version or current.inventoryUpdatedAt
			if deltaData.inventoryHash and deltaData.inventoryHash ~= 0 then
				current.inventoryHash = deltaData.inventoryHash
			end
		end)

		if not success then
			-- Delta application failed, request full sync
			local errorMsg = string.format("Delta application error: %s", tostring(err))
			TOGBankClassic_Output:Error("Failed to apply delta for %s: %s", norm, tostring(err))
			self:RecordDeltaError(guildInfo.name, norm, "APPLICATION_ERROR", errorMsg)
			TOGBankClassic_Guild:QueryAlt(nil, norm, nil)
			if guildInfo and guildInfo.name then
				TOGBankClassic_Database:RecordDeltaFailed(guildInfo.name)
			end
			return ADOPTION_STATUS.INVALID
		end

		-- Save new snapshot for future deltas
		if guildInfo and guildInfo.name then
			TOGBankClassic_Database:SaveSnapshot(guildInfo.name, norm, current)
			TOGBankClassic_Database:RecordDeltaApplied(guildInfo.name)

			-- Record apply time
			local applyTime = debugprofilestop() - applyStart
			TOGBankClassic_Database:RecordDeltaApplyTime(guildInfo.name, applyTime)
			TOGBankClassic_Output:Debug(
				"DELTA",
				"✓ Applied delta for %s (v%d→v%d) in %.2fms",
				norm,
				baseVersion,
				deltaData.version,
				applyTime
			)
		end

		-- Reset error count on successful application
		self:ResetDeltaErrorCount(guildInfo.name, norm)

		-- Trigger UI refresh if Inventory window is open AND viewing this alt
		if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.isOpen then
			-- Only refresh if we're viewing the alt that was updated
			if not TOGBankClassic_UI_Inventory.currentTab or TOGBankClassic_UI_Inventory.currentTab == norm then
				TOGBankClassic_UI_Inventory:DrawContent()
			end
		end

		return ADOPTION_STATUS.ADOPTED
	end)
end

-- ERROR TRACKING FUNCTIONS --

function TOGBankClassic_DeltaComms:RecordDeltaError(guildName, altName, errorType, errorMessage)
	local error = {
		altName = altName,
		errorType = errorType,
		message = errorMessage,
		timestamp = GetServerTime(),
	}

	-- Try to use database storage first
	if guildName then
		local db = TOGBankClassic_Database.db.faction[guildName]
		if db and db.deltaErrors then
			-- Use database storage
			table.insert(db.deltaErrors.lastErrors, 1, error)

			-- Keep only recent errors (max 10)
			while #db.deltaErrors.lastErrors > 10 do
				table.remove(db.deltaErrors.lastErrors)
			end

			-- Track failure count per alt
			if not db.deltaErrors.failureCounts[altName] then
				db.deltaErrors.failureCounts[altName] = 0
			end
			db.deltaErrors.failureCounts[altName] = db.deltaErrors.failureCounts[altName] + 1

			-- Notify user if repeated failures (3+ failures for same alt) and player is online
			if db.deltaErrors.failureCounts[altName] >= 3 and not db.deltaErrors.notifiedAlts[altName] then
				if TOGBankClassic_Guild:IsPlayerOnline(altName) then
					TOGBankClassic_Output:Warn(
						"Repeated delta sync failures for %s. Falling back to full sync.",
						altName
					)
					db.deltaErrors.notifiedAlts[altName] = true
				end
			end
			return
		end
	end

	-- Fallback: Use temporary in-memory storage
	TOGBankClassic_Output:Debug(
		"DELTA",
		"Using temporary error storage for %s (%s): Guild.Info not initialized",
		altName or "unknown",
		errorType or "unknown"
	)

	if not TOGBankClassic_Guild.tempDeltaErrors then
		TOGBankClassic_Guild.tempDeltaErrors = {
			lastErrors = {},
			failureCounts = {},
			notifiedAlts = {}
		}
	end

	table.insert(TOGBankClassic_Guild.tempDeltaErrors.lastErrors, 1, error)

	-- Keep only recent errors (max 10)
	while #TOGBankClassic_Guild.tempDeltaErrors.lastErrors > 10 do
		table.remove(TOGBankClassic_Guild.tempDeltaErrors.lastErrors)
	end

	-- Track failure count per alt
	if not TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] then
		TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] = 0
	end
	TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] = TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] + 1

	-- Notify user if repeated failures (3+ failures for same alt) and player is online
	if TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] >= 3 and not TOGBankClassic_Guild.tempDeltaErrors.notifiedAlts[altName] then
		if TOGBankClassic_Guild:IsPlayerOnline(altName) then
			TOGBankClassic_Output:Warn(
				"Repeated delta sync failures for %s. Falling back to full sync.",
				altName
			)
			TOGBankClassic_Guild.tempDeltaErrors.notifiedAlts[altName] = true
		end
	end
end

-- Reset failure count for an alt (called on successful sync)
function TOGBankClassic_DeltaComms:ResetDeltaErrorCount(guildName, altName)
	-- Reset in database if available
	if guildName then
		local db = TOGBankClassic_Database.db.faction[guildName]
		if db and db.deltaErrors then
			if db.deltaErrors.failureCounts[altName] then
				db.deltaErrors.failureCounts[altName] = 0
			end
			if db.deltaErrors.notifiedAlts[altName] then
				db.deltaErrors.notifiedAlts[altName] = nil
			end
		end
	end

	-- Also reset in temporary storage
	if TOGBankClassic_Guild.tempDeltaErrors then
		if TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] then
			TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] = 0
		end
		if TOGBankClassic_Guild.tempDeltaErrors.notifiedAlts[altName] then
			TOGBankClassic_Guild.tempDeltaErrors.notifiedAlts[altName] = nil
		end
	end
end

-- Get recent delta errors
function TOGBankClassic_DeltaComms:GetRecentDeltaErrors(guildName)
	-- Return from database if available
	if guildName then
		local db = TOGBankClassic_Database.db.faction[guildName]
		if db and db.deltaErrors then
			return db.deltaErrors.lastErrors
		end
	end

	-- Fallback to temporary storage
	if TOGBankClassic_Guild.tempDeltaErrors then
		return TOGBankClassic_Guild.tempDeltaErrors.lastErrors
	end

	return {}
end

-- Get failure count for an alt
function TOGBankClassic_DeltaComms:GetDeltaFailureCount(guildName, altName)
	-- Check database first if available
	if guildName then
		local db = TOGBankClassic_Database.db.faction[guildName]
		if db and db.deltaErrors then
			return db.deltaErrors.failureCounts[altName] or 0
		end
	end

	-- Fallback to temporary storage
	if TOGBankClassic_Guild.tempDeltaErrors then
		return TOGBankClassic_Guild.tempDeltaErrors.failureCounts[altName] or 0
	end

	return 0
end

-- Clear error counters for all offline players (called on roster update)
function TOGBankClassic_DeltaComms:ClearOfflineErrorCounters(guildName)
	if not guildName then
		return
	end

	local db = TOGBankClassic_Database.db.faction[guildName]
	if not db or not db.deltaErrors then
		return
	end

	-- Check each alt with error counters
	for altName, _ in pairs(db.deltaErrors.failureCounts) do
		if not TOGBankClassic_Guild:IsPlayerOnline(altName) then
			db.deltaErrors.failureCounts[altName] = nil
			db.deltaErrors.notifiedAlts[altName] = nil
		end
	end
end

-- PULL-BASED PROTOCOL FUNCTIONS --

-- Fast-fill missing alts using pull-based protocol (v0.8.0)
function TOGBankClassic_DeltaComms:FastFillMissingAlts(guildInfo)
	if not guildInfo then
		return
	end

	-- SYNC-001 fix: Get live banker roster from current guild instead of using
	-- cached roster.alts which may contain stale cross-guild data
	local rosterAlts = TOGBankClassic_Guild:GetBanks()
	if not rosterAlts or #rosterAlts == 0 then
		return
	end

	local missing = {}
	local missingDebug = {}
	local missingInfo = {}
	TOGBankClassic_Output:Debug("PROTOCOL", "FastFill: Starting check of %d roster alts", #rosterAlts)
	for _, altName in ipairs(rosterAlts) do
		local norm = TOGBankClassic_Guild:NormalizeName(altName)
		local localAlt = guildInfo.alts and norm and guildInfo.alts[norm]
		local hasEntry = localAlt ~= nil
		local hasContent = hasEntry and TOGBankClassic_Guild:HasAltContent(localAlt, norm)
		
		-- Check for hash mismatch (stale data)
		local bankerCache = TOGBankClassic_Guild.latestBankerHashes and TOGBankClassic_Guild.latestBankerHashes[norm]
		local hashMismatch = false
		local mismatchReason = nil
		if bankerCache and hasEntry and localAlt then
			local localHash = (localAlt.inventoryHash) or 0
			local bankerHash = bankerCache.hash or 0
			local localMailHash = (localAlt.mailHash) or 0
			local bankerMailHash = bankerCache.mailHash or 0
			if localHash ~= bankerHash then
				hashMismatch = true
				mismatchReason = string.format("inventory hash mismatch (local=%s, banker=%s)", tostring(localHash), tostring(bankerHash))
			elseif localMailHash ~= bankerMailHash then
				hashMismatch = true
				mismatchReason = string.format("mail hash mismatch (local=%s, banker=%s)", tostring(localMailHash), tostring(bankerMailHash))
			end
		end
		
		-- DEBUG: Log every alt to see what's happening
		TOGBankClassic_Output:Debug("PROTOCOL", "FastFill check: %s hasEntry=%s hasContent=%s hashMismatch=%s", 
			tostring(norm), tostring(hasEntry), tostring(hasContent), tostring(hashMismatch))
		
		-- Check if we need to request this alt: no entry, no content, OR hash mismatch
		if not hasEntry or not hasContent or hashMismatch then
			table.insert(missing, norm)
			local hasRaw = guildInfo.alts and guildInfo.alts[altName] ~= nil
			local reason = mismatchReason or (hasEntry and "no content" or "no entry")
			missingInfo[norm] = {
				reason = reason,
				hash = (bankerCache and bankerCache.hash) or (localAlt and localAlt.inventoryHash) or nil,
				updatedAt = (bankerCache and bankerCache.updatedAt) or (localAlt and (localAlt.inventoryUpdatedAt or localAlt.version)) or nil,
			}
			table.insert(
				missingDebug,
				string.format("%s (norm=%s, rawKey=%s, reason=%s)", tostring(altName), tostring(norm), tostring(hasRaw), reason)
			)
		end
	end

	if #missing == 0 then
		TOGBankClassic_Output:Debug("DELTA", "Fast-fill: All %d roster alts present locally", #rosterAlts)
		return
	end

	local haveCount, totalCount = TOGBankClassic_Guild:GetBankerDataProgress()
	if not (TOGBankClassic_Options and TOGBankClassic_Options.IsSyncProgressMuted and TOGBankClassic_Options:IsSyncProgressMuted()) then
		TOGBankClassic_Output:Info("Fast-fill: Requesting %d missing alts (have %d/%d)", #missing, haveCount, totalCount)
	end
	TOGBankClassic_Guild:ReportBankerDataProgress("fast-fill", true)
	if #missingDebug > 0 then
		TOGBankClassic_Output:Debug("DELTA", "Fast-fill missing alts: %s", table.concat(missingDebug, ", "))
	end

	local hasOnlineBanker = false
	for member, _ in pairs(TOGBankClassic_Guild.onlineMembers or {}) do
		if TOGBankClassic_Guild:IsBank(member) and TOGBankClassic_Guild:IsPlayerOnline(member) then
			hasOnlineBanker = true
			break
		end
	end
	if not hasOnlineBanker then
		GuildRoster()
		for i = 1, GetNumGuildMembers() do
			local rosterName, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
			if rosterName and online then
				local normRoster = TOGBankClassic_Guild:NormalizeName(rosterName)
				if TOGBankClassic_Guild:IsBank(normRoster) then
					hasOnlineBanker = true
					break
				end
			end
		end
	end

	-- Query each missing alt using pull-based protocol
	for _, norm in ipairs(missing) do
		local info = missingInfo[norm]
		TOGBankClassic_Output:Debug(
			"PROTOCOL",
			"Fast-fill processing: %s (info=%s, hash=%s, hasHash=%s, hashNotZero=%s)",
			tostring(norm),
			tostring(info ~= nil),
			tostring(info and info.hash),
			tostring(info and info.hash and true or false),
			tostring(info and info.hash and info.hash ~= 0 or false)
		)
		-- PERF-006: Use P2P whenever we have a hash, regardless of banker online status
		if info and info.hash and info.hash ~= 0 then
			-- We have hash but no content - broadcast P2P request (GUILD → timeout → banker fallback)
			TOGBankClassic_Output:Debug(
				"PROTOCOL",
				"Fast-fill P2P broadcast: requesting %s (expectedHash=%s, updatedAt=%s)",
				tostring(norm),
				tostring(info.hash),
				tostring(info.updatedAt)
			)
			TOGBankClassic_Guild:BroadcastP2PRequest(norm, info.hash, info.updatedAt, nil)
		else
			-- No hash available - go straight to banker whisper as last resort
			TOGBankClassic_Output:Debug(
				"PROTOCOL",
				"Fast-fill banker query: requesting %s (no hash or hash=0)",
				tostring(norm)
			)
			TOGBankClassic_Guild:QueryAltPullBased(norm, false)
		end
	end
end
