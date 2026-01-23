TOGBankClassic_Core = LibStub("AceAddon-3.0"):NewAddon("TOGBankClassic", "AceComm-3.0", "AceConsole-3.0", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
local AceComm_SendCommMessage = TOGBankClassic_Core.SendCommMessage

function TOGBankClassic_Core:SendCommMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)
    local prefixDesc = COMM_PREFIX_DESCRIPTIONS[prefix] or "(Unknown)"
    if IsInRaid() then
        TOGBankClassic_Output:Debug("< (suppressing) %s %s (in raid)", prefix, prefixDesc)
        return
    end
    if not AceComm_SendCommMessage then
        return
    end

    local bytes = text and #text or 0
    TOGBankClassic_Output:Debug("< %s %s to %s (%d bytes)", prefix, prefixDesc, distribution, bytes)

    return AceComm_SendCommMessage(self, prefix, text, distribution, target, prio, callbackFn, callbackArg)
end

-- Centralized WHISPER send with automatic online check
-- Returns true if sent, false if target offline or send failed
function TOGBankClassic_Core:SendWhisper(prefix, text, target, prio, callbackFn, callbackArg)
    -- Check if target is online
    if not TOGBankClassic_Guild:IsPlayerOnline(target) then
        TOGBankClassic_Output:Debug("Cannot send %s WHISPER to %s - player is offline", prefix, target)
        return false
    end
    
    -- Send the whisper
    self:SendCommMessage(prefix, text, "WHISPER", target, prio, callbackFn, callbackArg)
    return true
end

function TOGBankClassic_Core:OnInitialize()
    -- Called when the addon is loaded
    TOGBankClassic_Output:Init()
    TOGBankClassic_Database:Init()
    TOGBankClassic_Chat:Init()
    TOGBankClassic_Options:Init()
    TOGBankClassic_UI:Init()
    
    -- Enable VersionCheck-1.0 addon integration
    do
        local VC = LibStub:GetLibrary("VersionCheck-1.0", true)
        if VC and VC.Enable then
            -- Create a host addon object for VersionCheck
            local hostAddon = {
                GetName = function() return "TOGBankClassic" end,
                Version = (C_AddOns and C_AddOns.GetAddOnMetadata("TOGBankClassic", "Version")) or GetAddOnMetadata("TOGBankClassic", "Version") or "@project-version@"
            }
            VC:Enable(hostAddon)
            TOGBankClassic_Output:Debug("VersionCheck-1.0 integration enabled (v%s)", hostAddon.Version)
        end
    end
end

function TOGBankClassic_Core:OnEnable()
    -- Called when the addon is enabled
    TOGBankClassic_Events:RegisterEvents()
end

function TOGBankClassic_Core:OnDisable()
    -- Called when the addon is disabled
    TOGBankClassic_Events:UnregisterEvents()
end

-- Checksum implementation for message integrity
-- Uses a simple but effective hash that detects corruption
local CHECKSUM_SEPARATOR = "\030" -- ASCII Record Separator, not used by AceSerializer

local function ComputeChecksum(str)
    if not str or type(str) ~= "string" then
        return 0
    end
    -- Simple additive checksum with bit mixing for better distribution
    local sum = 0
    local len = #str
    for i = 1, len do
        local byte = string.byte(str, i)
        sum = (sum * 31 + byte) % 2147483647
    end
    -- Include length to catch truncation
    sum = (sum * 31 + len) % 2147483647
    return sum
end

-- Serialize data with appended checksum for integrity verification
function TOGBankClassic_Core:SerializeWithChecksum(data)
    local serialized = self:Serialize(data)
    if not serialized then
        return nil
    end
    local checksum = ComputeChecksum(serialized)
    return serialized .. CHECKSUM_SEPARATOR .. tostring(checksum)
end

-- Deserialize data and verify checksum; returns success, data (or nil, error)
function TOGBankClassic_Core:DeserializeWithChecksum(message)
    if not message or type(message) ~= "string" then
        return false, "invalid message"
    end

    -- Find the checksum separator from the end
    local sepPos = string.find(message, CHECKSUM_SEPARATOR, 1, true)
    if not sepPos then
        -- No checksum found - fall back to regular deserialize for backwards compatibility
        return self:Deserialize(message)
    end

    local serialized = string.sub(message, 1, sepPos - 1)
    local checksumStr = string.sub(message, sepPos + 1)
    local expectedChecksum = tonumber(checksumStr)

    if not expectedChecksum then
        return false, "invalid checksum format"
    end

    local actualChecksum = ComputeChecksum(serialized)
    if actualChecksum ~= expectedChecksum then
        return false, "checksum mismatch (expected " .. expectedChecksum .. ", got " .. actualChecksum .. ")"
    end

    return self:Deserialize(serialized)
end
-- Delta Validation Functions

-- Validate that a delta structure is well-formed
function TOGBankClassic_Core:ValidateDeltaStructure(delta)
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

	return true
end

-- Validate an item delta structure (added/modified/removed)
function TOGBankClassic_Core:ValidateItemDelta(itemDelta)
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
			if not item.Link or type(item.Link) ~= "string" then
				return false, "added item missing or invalid Link"
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
			if not item.Link or type(item.Link) ~= "string" then
				return false, "modified item missing or invalid Link"
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
			if not item.Link or type(item.Link) ~= "string" then
				return false, "removed item missing or invalid Link"
			end
		end
	end

	return true
end

-- Sanitize a delta structure by removing malformed data
function TOGBankClassic_Core:SanitizeDelta(delta)
	if not delta or type(delta) ~= "table" then
		return nil
	end

	-- Create sanitized copy
	local sanitized = {
		type = delta.type,
		name = delta.name,
		version = delta.version,
		baseVersion = delta.baseVersion,
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

	return sanitized
end

-- Compute a hash of inventory state to detect actual changes (v0.8.0)
-- Only updates version timestamps when this hash changes
function TOGBankClassic_Core:ComputeInventoryHash(bank, bags, money)
	local parts = {}
	
	-- Include money
	table.insert(parts, tostring(money or 0))
	
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
	
	-- Include bank items
	if bank and bank.items then
		table.insert(parts, "B:" .. hashItems(bank.items))
	end
	
	-- Include bag items
	if bags and bags.items then
		table.insert(parts, "G:" .. hashItems(bags.items))
	end
	
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

-- Sanitize an item delta structure
function TOGBankClassic_Core:SanitizeItemDelta(itemDelta)
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