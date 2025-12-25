TOGBankClassic_Guild = {}

TOGBankClassic_Guild.Info = nil

---START CHANGES
function GetPlayerWithNormalizedRealm(name)
	if string.match(name, "(.*)%-(.*)") then
		return name
	end
	return name .. "-" .. GetNormalizedRealmName("player")
end

-- wrapper to ensure consistent normalization across the addon
local function NormalizePlayerName(name)
	if not name then
		return nil
	end
	-- Canonicalize hyphen spacing: convert "Name - Realm" or "Name- Realm" to "Name-Realm"
	local normalized = string.gsub(name, "%s*%-%s*", "-")
	if string.match(normalized, "^(.-)%-(.-)$") then
		return normalized
	end
	-- If helper exists, use it
	if GetPlayerWithNormalizedRealm then
		return GetPlayerWithNormalizedRealm(name)
	end
	-- Fallback: append current realm
	return name .. "-" .. GetNormalizedRealmName("player")
end
-- expose for other modules
TOGBankClassic_Guild.NormalizePlayerName = NormalizePlayerName

function TOGBankClassic_Guild:NormalizeName(name)
	if not name then
		return nil
	end
	local normalize = self.NormalizePlayerName
	if normalize then
		return normalize(name)
	end
	return name
end

function TOGBankClassic_Guild:GetNormalizedPlayer(name)
	return self:NormalizeName(name or self:GetPlayer())
end

-- Request sync helpers
local VALID_REQUEST_STATUS = {
	open = true,
	fulfilled = true,
	cancelled = true,
}

-- Completed/cancelled requests older than this many seconds will be pruned
local REQUEST_EXPIRY_SECONDS = 30 * 24 * 60 * 60

local function legacyRequestId(req)
	if not req or type(req) ~= "table" then
		return nil
	end
	local ts = tonumber(req.date or req.updatedAt or 0) or 0
	local requester = tostring(req.requester or "")
	local bank = tostring(req.bank or "")
	local item = tostring(req.item or "")
	if requester == "" and bank == "" and item == "" and ts == 0 then
		return nil
	end
	return string.format("%s-%s-%s-%d", bank, requester, item, ts)
end

local function generateRequestId()
	local now = GetServerTime()
	local rand = math.random(100000, 999999)
	return string.format("%d-%d", now, rand)
end

local function sanitizeRequest(req)
	if not req or type(req) ~= "table" then
		return nil
	end

	local now = GetServerTime()

	local quantity = math.max(tonumber(req.quantity or 0) or 0, 0)
	local fulfilled = math.max(tonumber(req.fulfilled or 0) or 0, 0)
	if quantity > 0 then
		fulfilled = math.min(fulfilled, quantity)
	end

	local bank = TOGBankClassic_Guild:NormalizeName(req.bank)
	local requester = TOGBankClassic_Guild:NormalizeName(req.requester)

	local updatedAt = tonumber(req.updatedAt or req.date or now) or now
	local dateVal = tonumber(req.date or updatedAt) or updatedAt
	local status = req.status
	if not VALID_REQUEST_STATUS[status] then
		status = "open"
	end
	if quantity > 0 and fulfilled >= quantity then
		status = "fulfilled"
	end

	local id = req.id or legacyRequestId(req) or generateRequestId()

	return {
		id = id,
		date = dateVal,
		updatedAt = updatedAt,
		requester = requester or "Unknown",
		bank = bank or "",
		item = tostring(req.item or ""),
		quantity = quantity,
		fulfilled = fulfilled,
		status = status,
		notes = tostring(req.notes or ""),
	}
end
---END CHANGES

function TOGBankClassic_Guild:GetPlayer()
	---START CHANGES
	--return UnitName("player")
	if TOGBankClassic_Bank.player then
		return TOGBankClassic_Bank.player
	end

	-- The below code should never be called, but is here for safety
	local function try()
		local name, realm = UnitName("player"), GetNormalizedRealmName()
		if name and realm then
			TOGBankClassic_Bank.player = name .. "-" .. realm
			return true
		end
	end
	if try() then
		return TOGBankClassic_Bank.player
	end
	local count, max, delay, timer = 0, 10, 15
	timer = C_Timer.NewTicker(delay, function()
		count = count + 1
		if try() or count >= max then
			if timer then
				timer:Cancel()
			end
		end
	end)

	return nil
	---END CHANGES
end

function TOGBankClassic_Guild:GetGuild()
	return IsInGuild("player") and GetGuildInfo("player") or nil
end

local function buildRequestIndex(list)
	local map = {}
	for idx, req in ipairs(list) do
		if req and req.id then
			map[req.id] = idx
		end
	end
	return map
end

function TOGBankClassic_Guild:EnsureRequestsInitialized()
	if not self.Info then
		return
	end
	if not self.Info.requests then
		self.Info.requests = {}
	end
	if not self.Info.requestsVersion then
		self.Info.requestsVersion = 0
	end
	self:NormalizeRequestList()
end

function TOGBankClassic_Guild:NormalizeRequestList()
	if not self.Info or not self.Info.requests then
		return
	end

	local normalized = {}
	local byId = {}
	local latest = tonumber(self.Info.requestsVersion or 0) or 0

	for _, req in ipairs(self.Info.requests) do
		local clean = sanitizeRequest(req)
		if clean and clean.id then
			local existingIdx = byId[clean.id]
			if existingIdx then
				local existing = normalized[existingIdx]
				local existingUpdated = tonumber(existing.updatedAt or existing.date or 0) or 0
				local incomingUpdated = tonumber(clean.updatedAt or clean.date or 0) or 0
				if incomingUpdated > existingUpdated then
					normalized[existingIdx] = clean
				end
			else
				table.insert(normalized, clean)
				byId[clean.id] = #normalized
			end
			if clean.updatedAt and clean.updatedAt > latest then
				latest = clean.updatedAt
			end
		end
	end

	self.Info.requests = normalized
	self.Info.requestsVersion = latest
	self:PruneRequests()
end

function TOGBankClassic_Guild:PruneRequests()
	if not self.Info or not self.Info.requests then
		return
	end

	local now = GetServerTime()
	local keep = {}
	local changed = false
	local latest = tonumber(self.Info.requestsVersion or 0) or 0

	for _, req in ipairs(self.Info.requests) do
		local updated = tonumber(req.updatedAt or req.date or 0) or 0
		local quantity = tonumber(req.quantity or 0) or 0
		local fulfilled = tonumber(req.fulfilled or 0) or 0
		local isDone = req.status == "fulfilled"
			or req.status == "cancelled"
			or (quantity > 0 and fulfilled >= quantity)
		local tooOld = isDone and (now - updated) > REQUEST_EXPIRY_SECONDS
		if not tooOld then
			table.insert(keep, req)
			if updated > latest then
				latest = updated
			end
		else
			changed = true
		end
	end

	self.Info.requests = keep
	self.Info.requestsVersion = latest
	return changed
end

function TOGBankClassic_Guild:TouchRequestsVersion(ts)
	if not self.Info then
		return
	end
	local current = tonumber(self.Info.requestsVersion or 0) or 0
	local incoming = tonumber(ts or GetServerTime()) or current
	if incoming > current then
		self.Info.requestsVersion = incoming
	end
end

function TOGBankClassic_Guild:RefreshRequestsUI()
	if TOGBankClassic_UI_Requests and TOGBankClassic_UI_Requests.isOpen then
		TOGBankClassic_UI_Requests:DrawContent()
	end
end

function TOGBankClassic_Guild:BroadcastRequestsUpdate(ts)
	self:TouchRequestsVersion(ts)
	self:PruneRequests()
	self:SendRequestsData()
	self:RefreshRequestsUI()
end

function TOGBankClassic_Guild:GetPlayerInfo(name)
	for i = 1, GetNumGuildMembers() do
		local playerRealm, _, _, _, _, _, _, _, _, _, class = GetGuildRosterInfo(i)
		player, _ = string.match(playerRealm, "(.*)%-(.*)")
		---START CHANGES
		--if player == name then
		if playerRealm == name then
			---END CHANGES
			return class
		end
	end
	return nil
end

function TOGBankClassic_Guild:Reset(name)
	if not name then
		return
	end

	TOGBankClassic_UI_Inventory:Close()
	TOGBankClassic_Database:Reset(name)
	self.Info = TOGBankClassic_Database:Load(name)
	self:EnsureRequestsInitialized()
end

function TOGBankClassic_Guild:Init(name)
	if not name then
		return false
	end
	if self.Info and self.Info.name == name then
		return false
	end

	self.hasRequested = false
	self.requestCount = 0

	self.Info = TOGBankClassic_Database:Load(name)
	if self.Info then
		self:EnsureRequestsInitialized()
		return true
	end

	self:Reset(name)
	return true
end

-- Cleanup malformed entries in the saved guild data
-- This attempts to be conservative:
-- - remove alts that are not tables
-- - remove per-alt entries that have badly shaped bank/bags item lists
-- - ensure roster.alts is a proper array
-- Returns number of alts cleaned
function TOGBankClassic_Guild:CleanupMalformedAlts()
	if not self.Info or not self.Info.alts then
		return 0
	end

	local cleaned = 0
	for name, alt in pairs(self.Info.alts) do
		local remove = false
		if type(alt) ~= "table" then
			remove = true
		else
			-- Ensure version is present, but malformed nested fields are problematic
			if alt.bank and type(alt.bank) == "table" and alt.bank.items then
				-- alt.bank.items should be an array or a map of items with ID fields; remove any empty entries
				for k, v in pairs(alt.bank.items) do
					if not v or type(v) ~= "table" or not v.ID then
						alt.bank.items[k] = nil
					end
				end
			end
			if alt.bags and type(alt.bags) == "table" and alt.bags.items then
				for k, v in pairs(alt.bags.items) do
					if not v or type(v) ~= "table" or not v.ID then
						alt.bags.items[k] = nil
					end
				end
			end
			-- If after cleaning the alt has no meaningful fields (no version, no money, no items), remove it
			local hasData = false
			if alt.version then
				hasData = true
			end
			if alt.money then
				hasData = true
			end
			if alt.bank and next(alt.bank.items or {}) then
				hasData = true
			end
			if alt.bags and next(alt.bags.items or {}) then
				hasData = true
			end
			if not hasData then
				remove = true
			end
		end

		if remove then
			TOGBankClassic_Core:Print("Removing malformed bank entry for", name)
			self.Info.alts[name] = nil
			cleaned = cleaned + 1
		end
	end

	-- Ensure roster.alts is a proper array (remove nils and non-strings)
	if self.Info.roster and self.Info.roster.alts then
		local new_alts = {}
		for _, v in pairs(self.Info.roster.alts) do
			if type(v) == "string" and v ~= "" then
				table.insert(new_alts, v)
			end
		end
		self.Info.roster.alts = new_alts
	end

	return cleaned
end

function TOGBankClassic_Guild:GetRequestsVersion()
	if not self.Info then
		return 0
	end
	return tonumber(self.Info.requestsVersion or 0) or 0
end

function TOGBankClassic_Guild:SendRequestsData(target)
	if not self.Info or not self.Info.requests then
		return
	end
	self:NormalizeRequestList()
	local payload = {
		type = "requests",
		version = self:GetRequestsVersion(),
		requests = self.Info.requests,
	}
	local data = TOGBankClassic_Core:Serialize(payload)
	TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", target, "BULK")
end

function TOGBankClassic_Guild:RequestRequestsSync(player, version)
	if not player then
		return
	end
	local data = TOGBankClassic_Core:Serialize({ player = player, type = "requests", version = version })
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, "BULK")
end

function TOGBankClassic_Guild:ReceiveRequestsData(payload)
	if not payload or type(payload) ~= "table" then
		return
	end
	if not self.Info then
		return
	end
	self:EnsureRequestsInitialized()

	local incomingList = payload.requests
	if not incomingList or type(incomingList) ~= "table" then
		return
	end
	local incomingVersion = tonumber(payload.version or 0) or 0

	local byId = buildRequestIndex(self.Info.requests)
	local changed = false

	for _, req in ipairs(incomingList) do
		local clean = sanitizeRequest(req)
		if clean and clean.id then
			local idx = byId[clean.id]
			if idx then
				local existing = self.Info.requests[idx]
				local existingUpdated = tonumber(existing.updatedAt or existing.date or 0) or 0
				local incomingUpdated = tonumber(clean.updatedAt or clean.date or 0) or 0
				if incomingUpdated > existingUpdated then
					self.Info.requests[idx] = clean
					changed = true
				end
			else
				table.insert(self.Info.requests, clean)
				byId[clean.id] = #self.Info.requests
				changed = true
			end
		end
	end

	if changed or incomingVersion > (self.Info.requestsVersion or 0) then
		self:TouchRequestsVersion(math.max(incomingVersion, self.Info.requestsVersion or 0))
		self:PruneRequests()
		self:RefreshRequestsUI()
	end
end

-- Record a bank item request alongside guild bank data
function TOGBankClassic_Guild:AddRequest(request)
	if not self.Info then
		return false
	end
	if not request or type(request) ~= "table" then
		return false
	end

	self:EnsureRequestsInitialized()

	local now = GetServerTime()
	request.date = request.date or now
	request.updatedAt = now
	request.status = request.status or "open"
	request.fulfilled = tonumber(request.fulfilled or 0) or 0

	local clean = sanitizeRequest(request)
	if not clean then
		return false
	end

	local byId = buildRequestIndex(self.Info.requests)
	if byId[clean.id] then
		self.Info.requests[byId[clean.id]] = clean
	else
		table.insert(self.Info.requests, clean)
	end

	self:BroadcastRequestsUpdate(clean.updatedAt)
	return true
end

function TOGBankClassic_Guild:CanManageRequests(actor)
	if CanViewOfficerNote and CanViewOfficerNote() then
		return true
	end

	local normActor = self:NormalizeName(actor)

	if normActor and self.IsBank and self:IsBank(normActor) then
		return true
	end

	if normActor and self.SenderIsGM and self:SenderIsGM(normActor) then
		return true
	end

	return false
end

function TOGBankClassic_Guild:CanCancelRequest(req, actor)
	if not req or type(req) ~= "table" then
		return false
	end

	local normActor = self:NormalizeName(actor or self:GetPlayer())
	local requester = self:NormalizeName(req.requester)

	if normActor and requester and normActor == requester then
		return true
	end

	return self:CanManageRequests(normActor)
end

function TOGBankClassic_Guild:CancelRequest(requestId, actor)
	if not self.Info or not self.Info.requests then
		return false
	end
	if not requestId then
		return false
	end

	self:EnsureRequestsInitialized()

	local byId = buildRequestIndex(self.Info.requests)
	local idx = byId[requestId]
	if not idx then
		return false
	end

	local req = self.Info.requests[idx]
	if not req then
		return false
	end

	local quantity = tonumber(req.quantity or 0) or 0
	local fulfilled = tonumber(req.fulfilled or 0) or 0
	if req.status == "cancelled" then
		return false
	end
	if req.status == "fulfilled" or (quantity > 0 and fulfilled >= quantity) then
		return false
	end

	local actorName = actor or self:GetPlayer()
	if not self:CanCancelRequest(req, actorName) then
		return false
	end

	local now = GetServerTime()
	req.status = "cancelled"
	req.updatedAt = now

	local clean = sanitizeRequest(req)
	if clean then
		self.Info.requests[idx] = clean
	end

	self:BroadcastRequestsUpdate(now)

	return true
end

-- Increment fulfillment for matching requests; returns amount applied
function TOGBankClassic_Guild:FulfillRequest(bank, requester, itemName, count)
	if
		not self.Info
		or not self.Info.requests
		or not bank
		or not requester
		or not itemName
		or not count
		or count <= 0
	then
		return 0
	end

	local normBank = self:NormalizeName(bank) or bank
	local normRequester = self:NormalizeName(requester) or requester
	local targetItem = string.lower(itemName)

	local applied = 0
	local updated = false
	local now = GetServerTime()
	for _, req in ipairs(self.Info.requests) do
		local reqBank = req.bank
		local reqRequester = req.requester
		local reqItem = req.item and string.lower(req.item) or ""
		local qty = tonumber(req.quantity or 0) or 0
		local fulfilled = tonumber(req.fulfilled or 0) or 0

		if reqBank == normBank and reqRequester == normRequester and reqItem == targetItem and fulfilled < qty then
			local remaining = qty - fulfilled
			local delta = math.min(remaining, count)
			req.fulfilled = fulfilled + delta
			req.updatedAt = now
			if req.fulfilled >= qty and qty > 0 then
				req.status = "fulfilled"
			end
			count = count - delta
			applied = applied + delta
			updated = true
		end

		if count <= 0 then
			break
		end
	end

	if updated then
		self:BroadcastRequestsUpdate(now)
	end

	return applied
end

function TOGBankClassic_Guild:GetBanks()
	local hasBanks = false
	local banks = {}

	for i = 1, GetNumGuildMembers() do
		---START CHANGES
		-- Allow use of either public or officer note, and allow the note to contain "gbank" instead of requiring it to be equal to "gbank" only (and no other characters)
		--local name, _, _, _, _, _, _, officer_note, _, _, _ = GetGuildRosterInfo(i)
		local name, _, _, _, _, _, publicNote, officer_note, _, _, _ = GetGuildRosterInfo(i)
		--if officer_note == "gbank" then
		if publicNote ~= nil or officer_note ~= nil then
			if string.match(publicNote, "(.*)gbank(.*)") or string.match(officer_note, "(.*)gbank(.*)") then
				--local player, _ = string.match(name, "(.*)%-(.*)")
				table.insert(banks, name)
				---END CHANGES
				hasBanks = true
			end
		end
	end
	if not hasBanks then
		return nil
	end
	return banks
end

function TOGBankClassic_Guild:GetRosterAlts()
	if not self.Info then
		return nil
	end

	local roster = self.Info.roster
	local list = {}

	if roster and roster.alts then
		for _, v in pairs(roster.alts) do
			if type(v) == "string" and v ~= "" then
				table.insert(list, v)
			end
		end
	end

	if #list > 0 then
		return list
	end

	for name, alt in pairs(self.Info.alts or {}) do
		if type(alt) == "table" then
			table.insert(list, name)
		end
	end

	if #list == 0 then
		return nil
	end

	return list
end

function TOGBankClassic_Guild:IsBank(player)
	if not player then
		return false
	end
	local banks = TOGBankClassic_Guild:GetBanks()
	if banks == nil then
		return false
	end

	local normPlayer = self:NormalizeName(player) or player
	local isBank = false
	for _, v in pairs(banks) do
		local norm = self:NormalizeName(v) or v
		if norm == normPlayer then
			isBank = true
		end
	end

	return isBank
end

function TOGBankClassic_Guild:CheckVersion(version)
	if self.Info then
		return false
	end

	if version > self.Info.roster.version then
		return false
	end

	return true
end

function TOGBankClassic_Guild:GetVersion()
	if not self.Info then
		return nil
	end

	local versionInfo = GetAddOnMetadata("TOGBankClassic", "Version"):gsub("%.", "")
	local versionNumber = tonumber(versionInfo)
	local data = {
		addon = versionNumber,
		roster = nil,
		alts = {},
		requests = self:GetRequestsVersion(),
	}

	if self.Info.name then
		data.name = self.Info.name
	end

	if self.Info.roster.version then
		data.roster = self.Info.roster.version
	end

	for k, v in pairs(self.Info.alts) do
		---START CHANGES
		-- Only store bank alt data if the sender is a bank alt
		--data.alts[k] = v.version
		if type(v) == "table" and v.version then
			data.alts[k] = v.version
		end
		---END CHANGES
	end

	return data
end

local PENDING_SYNC_TTL_SECONDS = 180

function TOGBankClassic_Guild:MarkPendingSync(syncType, sender, name)
	if not syncType or not sender then
		return
	end
	local now = GetServerTime()
	local normSender = self:NormalizeName(sender)
	if not self.pending_sync then
		self.pending_sync = { roster = {}, alts = {} }
	end
	if syncType == "roster" then
		self.pending_sync.roster[normSender] = now
	elseif syncType == "alt" and name then
		local normName = self:NormalizeName(name)
		if not self.pending_sync.alts[normName] then
			self.pending_sync.alts[normName] = {}
		end
		self.pending_sync.alts[normName][normSender] = now
	end
end

function TOGBankClassic_Guild:ConsumePendingSync(syncType, sender, name)
	if not syncType or not sender then
		return false
	end
	if not self.pending_sync then
		return false
	end
	local now = GetServerTime()
	local normSender = self:NormalizeName(sender)
	if syncType == "roster" then
		local roster = self.pending_sync.roster
		local ts = roster and roster[normSender]
		if ts and now - ts <= PENDING_SYNC_TTL_SECONDS then
			roster[normSender] = nil
			return true
		end
		if ts then
			roster[normSender] = nil
		end
		return false
	end
	if syncType == "alt" and name then
		local normName = self:NormalizeName(name)
		local alts = self.pending_sync.alts and self.pending_sync.alts[normName]
		local ts = alts and alts[normSender]
		if ts and now - ts <= PENDING_SYNC_TTL_SECONDS then
			alts[normSender] = nil
			if next(alts) == nil then
				self.pending_sync.alts[normName] = nil
			end
			return true
		end
		if ts then
			alts[normSender] = nil
			if next(alts) == nil then
				self.pending_sync.alts[normName] = nil
			end
		end
	end
	return false
end

function TOGBankClassic_Guild:RequestRosterSync(player, version)
	self.hasRequested = true
	if self.requestCount == nil then
		self.requestCount = 1
	else
		self.requestCount = self.requestCount + 1
	end
	self:MarkPendingSync("roster", player)
	local data = TOGBankClassic_Core:Serialize({ player = player, type = "roster", version = version })
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, "BULK")
end

function TOGBankClassic_Guild:RequestAltSync(player, name, version)
	self.hasRequested = true
	if self.requestCount == nil then
		self.requestCount = 1
	else
		self.requestCount = self.requestCount + 1
	end
	self:MarkPendingSync("alt", player, name)
	local data = TOGBankClassic_Core:Serialize({ player = player, type = "alt", name = name, version = version })
	TOGBankClassic_Core:SendCommMessage("togbank-r", data, "Guild", nil, "BULK")
end

function TOGBankClassic_Guild:SendRosterData()
	local data = TOGBankClassic_Core:Serialize({ type = "roster", roster = self.Info.roster })
	TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", nil, "BULK")
end

function TOGBankClassic_Guild:ReceiveRosterData(roster)
	if not self.Info then
		return
	end
	if self.Info.roster.version and roster.version and roster.version < self.Info.roster.version then
		return
	end
	if self.hasRequested then
		if self.requestCount == nil then
			self.requestCount = 0
		else
			self.requestCount = self.requestCount - 1
		end
		if self.requestCount == 0 then
			self.hasRequested = false
			shutup = TOGBankClassic_Options:GetBankVerbosity()
			if shutup == false then
				TOGBankClassic_Core:Print("Sync completed.")
			end
		end
	end

	self.Info.roster = roster
end

-- returns true if the given normalized sender has a public or officer note containing 'gbank'
function TOGBankClassic_Guild:SenderHasGbankNote(sender)
	if not sender then
		return false
	end
	for i = 1, GetNumGuildMembers() do
		local playerRealm, _, _, _, _, _, publicNote, officer_note = GetGuildRosterInfo(i)
		if playerRealm then
			local norm = self:NormalizeName(playerRealm)
			if norm == sender then
				if
					(publicNote and string.match(publicNote, "(.*)gbank(.*)"))
					or (officer_note and string.match(officer_note, "(.*)gbank(.*)"))
				then
					return true
				end
			end
		end
	end
	return false
end

function TOGBankClassic_Guild:SendAltData(name, force)
	if not name then
		return
	end
	local norm = self:NormalizeName(name)
	if not self.Info or not self.Info.alts or not self.Info.alts[norm] then
		return
	end

	-- Bump the version so this transfer wins conflict resolution
	if force then
		self.Info.alts[norm].version = GetServerTime()
	end

	local data = TOGBankClassic_Core:Serialize({ type = "alt", name = norm, alt = self.Info.alts[norm] })
	---START CHANGES
	TOGBankClassic_Core:SendCommMessage("togbank-d", data, "Guild", nil, "BULK", OnChunkSent)
end

---START CHANGES
function OnChunkSent(arg, sent, total)
	shutup = TOGBankClassic_Options:GetBankVerbosity()
	if shutup == false then
		if sent <= 255 then
			TOGBankClassic_Core:Print("Sharing guild bank data, chunk", sent, "of", total)
		end
		if sent == total then
			TOGBankClassic_Core:Print("Sharing guild bank data has completed. (", sent, "of", total, "chunks)")
		end
	end
end
---END CHANGES

function TOGBankClassic_Guild:ReceiveAltData(name, alt)
	if not self.Info then
		return
	end

	-- Sanitize incoming alt data
	local function sanitizeAlt(a)
		if not a or type(a) ~= "table" then
			return nil
		end
		if a.bank and type(a.bank) == "table" and a.bank.items then
			for k, v in pairs(a.bank.items) do
				if not v or type(v) ~= "table" or not v.ID then
					a.bank.items[k] = nil
				end
			end
		end
		if a.bags and type(a.bags) == "table" and a.bags.items then
			for k, v in pairs(a.bags.items) do
				if not v or type(v) ~= "table" or not v.ID then
					a.bags.items[k] = nil
				end
			end
		end
		return a
	end

	alt = sanitizeAlt(alt)
	if not alt then
		return
	end

	local norm = self:NormalizeName(name)
	local existing = self.Info.alts[norm]
	if existing and alt.version ~= nil and existing.version ~= nil and alt.version < existing.version then
		return
	end

	-- Accept incoming if newer version
	-- If same version, accept the alt with more items
	local function itemCount(a)
		local c = 0
		if a and a.bank and a.bank.items then
			for _, v in pairs(a.bank.items) do
				if v and v.ID then
					c = c + 1
				end
			end
		end
		if a and a.bags and a.bags.items then
			for _, v in pairs(a.bags.items) do
				if v and v.ID then
					c = c + 1
				end
			end
		end
		return c
	end

	if existing and existing.version and alt.version and alt.version < existing.version then
		-- Incoming is older; ignore
		return
	elseif existing and existing.version and alt.version and alt.version == existing.version then
		-- Tie-breaker: choose the one with more items
		if itemCount(alt) <= itemCount(existing) then
			return
		end
	end

	if self.Info.alts[name] and alt.version ~= nil and alt.version < self.Info.alts[name].version then
		return
	end
	if self.hasRequested then
		if self.requestCount == nil then
			self.requestCount = 0
		else
			self.requestCount = self.requestCount - 1
		end
		if self.requestCount == 0 then
			self.hasRequested = false
			shutup = TOGBankClassic_Options:GetBankVerbosity()
			if shutup == false then
				TOGBankClassic_Core:Print("Sync completed.")
			end
		end
	end

	self.Info.alts[norm] = alt
end

---START CHANGES
function s(a)
	local b = 0
	for c, d in pairs(a) do
		b = b + 1
	end
	return b
end

function TOGBankClassic_Guild:Hello(type)
	local addon_data = TOGBankClassic_Guild:GetVersion()
	local current_data = TOGBankClassic_Guild.Info
	if addon_data and current_data then
		local roster_alts = ""
		local guild_bank_alts = ""
		local hello = "Hi! " .. TOGBankClassic_Guild:GetPlayer() .. " is using version " .. addon_data.addon .. "."
		if s(current_data.roster) > 0 and s(current_data.alts) > 0 then
			for _, v in pairs(current_data.roster.alts) do
				if roster_alts ~= "" then
					roster_alts = roster_alts .. ", "
				end
				roster_alts = roster_alts .. v
			end
			if roster_alts ~= "" then
				roster_alts = " (" .. roster_alts .. ")"
			end
			for k, _ in pairs(current_data.alts) do
				if guild_bank_alts ~= "" then
					guild_bank_alts = guild_bank_alts .. ", "
				end
				guild_bank_alts = guild_bank_alts .. k
			end
			if guild_bank_alts ~= "" then
				guild_bank_alts = " (" .. guild_bank_alts .. ")"
			end
			if current_data.roster.alts then
				hello = hello .. "\n"
				hello = hello
					.. "I know about "
					.. #current_data.roster.alts
					.. " guild bank alts"
					.. roster_alts
					.. " on the roster."
				hello = hello .. "\n"
				hello = hello
					.. "I have guild bank data from "
					.. s(current_data.alts)
					.. " alts"
					.. guild_bank_alts
					.. "."
			end
		else
			hello = hello .. " I know about 0 guild bank alts on the roster, and have guild bank data from 0 alts."
		end

		local pending_count = 0
		local fulfilled_count = 0
		local pending_banks = {}
		for _, req in pairs(current_data.requests or {}) do
			local clean = sanitizeRequest(req)
			if clean and clean.item and clean.item ~= "" then
				local qty = tonumber(clean.quantity or 0) or 0
				local fulfilled = tonumber(clean.fulfilled or 0) or 0
				if qty > 0 then
					local is_fulfilled = clean.status == "fulfilled" or fulfilled >= qty
					local is_pending = clean.status == "open" or fulfilled < qty
					if is_fulfilled then
						fulfilled_count = fulfilled_count + 1
					elseif is_pending then
						pending_count = pending_count + 1
						if clean.bank and clean.bank ~= "" then
							pending_banks[clean.bank] = true
						end
					end
				end
			end
		end

		local pending_bank_list = {}
		for name in pairs(pending_banks) do
			table.insert(pending_bank_list, name)
		end
		table.sort(pending_bank_list)

		hello = hello
			.. "\n"
			.. string.format(
				"I have %d pending item requests and %d fulfilled item requests.",
				pending_count,
				fulfilled_count
			)
		if #pending_bank_list > 0 then
			hello = hello .. "\n" .. "Pending requests for bank alts: " .. table.concat(pending_bank_list, ", ") .. "."
		else
			hello = hello .. "\n" .. "Pending requests for bank alts: none."
		end

		TOGBankClassic_Core:Print(hello)
		local data = TOGBankClassic_Core:Serialize(hello)
		if type ~= "reply" then
			TOGBankClassic_Core:SendCommMessage("togbank-h", data, "Guild", nil, "BULK")
		else
			TOGBankClassic_Core:SendCommMessage("togbank-hr", data, "Guild", nil, "BULK")
		end
	end
end

function TOGBankClassic_Guild:Wipe(type)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild and not CanViewOfficerNote() then
		return
	end
	local wipe = "I wiped all addon data from " .. guild .. "."
	TOGBankClassic_Guild:Reset(guild)

	local data = TOGBankClassic_Core:Serialize(wipe)
	if type ~= "reply" then
		TOGBankClassic_Core:SendCommMessage("togbank-w", data, "Guild", nil, "BULK")
	else
		TOGBankClassic_Core:SendCommMessage("togbank-wr", data, "Guild", nil, "BULK")
	end
end

function TOGBankClassic_Guild:WipeMine(type)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		return
	end
	local wipe = "I wiped all my addon data from " .. guild .. "."
	TOGBankClassic_Guild:Reset(guild)
end

function TOGBankClassic_Guild:Share(type)
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		return
	end
	self.Info = TOGBankClassic_Database:Load(guild)
	local player = TOGBankClassic_Guild:GetPlayer()
	local normPlayer = TOGBankClassic_Guild:GetNormalizedPlayer(player)
	local share = "I'm sharing my bank data. Share yours please."
	if not self.Info.alts[normPlayer] then
		if type ~= "reply" then
			share = "Share your bank data please."
		else
			share = "Nothing to share."
		end
	end
	if self.Info.alts[normPlayer] and TOGBankClassic_Guild:IsBank(normPlayer) then
		TOGBankClassic_Guild:SendAltData(normPlayer)
	end

	-- Share current requests state alongside bank data so everyone stays in sync
	self:SendRequestsData()

	local data = TOGBankClassic_Core:Serialize(share)
	if type ~= "reply" then
		TOGBankClassic_Core:SendCommMessage("togbank-s", data, "Guild", nil, "BULK")
	else
		TOGBankClassic_Core:SendCommMessage("togbank-sr", data, "Guild", nil, "BULK")
	end
end

function TOGBankClassic_Guild:AuthorRosterData()
	if not self.Info then
		return
	end
	local info = self.Info
	local isBank = false
	local banks = TOGBankClassic_Guild:GetBanks()
	local player = TOGBankClassic_Guild:GetPlayer()
	if banks then
		for _, v in pairs(banks) do
			if v == player then
				isBank = true
				break
			end
		end
	end
	if isBank or CanViewOfficerNote() then
		info.roster.alts = banks
		info.roster.version = GetServerTime()
		if not banks then
			info.roster.version = nil
		end
		TOGBankClassic_Guild:SendRosterData()
		if banks then
			local characterNames = {}
			for _, bankChar in pairs(banks) do
				table.insert(characterNames, bankChar)
			end
			if #characterNames > 0 then
				TOGBankClassic_Core:Print(
					"Sent updated roster containing the follow banks: " .. table.concat(characterNames, ", ")
				)
			else
				TOGBankClassic_Core:Print("Sent empty roster.")
			end
		else
			TOGBankClassic_Core:Print("Sent empty roster.")
		end
	else
		TOGBankClassic_Core:Print("You lack permissions to share the roster.")
		return
	end
end

function TOGBankClassic_Guild:SenderIsGM(player)
	if not player then
		return false
	end
	if not IsInGuild() then
		return false
	end
	for i = 1, GetNumGuildMembers() do
		local playerRealm, _, rankIndex, _, _, _, publicNote, officer_note = GetGuildRosterInfo(i)
		if playerRealm then
			local norm = self:NormalizeName(playerRealm)
			if rankIndex == 0 and norm == player then
				return true
			end
		end
	end
	return false
end
---END CHANGES
