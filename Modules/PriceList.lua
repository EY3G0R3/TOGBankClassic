-- STORE-002 / DONATION-VALUE-001 (b) (GUILD_STORE.md 4.2.1, decided 2026-09-14): ONE GUILD PRICE
-- LIST, so every banker values a gift the same and every member is shown the same estimate.
--
-- The operator, on two bankers valuing one donation differently: "we need a way to determine what
-- the value is so any banker applies the same value. need some way for me with TSM to sync my TSM
-- values with other folks that don't sync up. especially the bankers, so we're all using the same
-- value". STORE-001 and STORE-007 price on each VIEWER'S OWN ItemDB sources, so a banker without
-- TSM values a gift at its own scan or the vendor floor while the operator's client would have said
-- something else -- and the ledger is permanent, so the disagreement is forever.
--
-- THE SHAPE, each rule from the design note:
--
--   * A PRICE AUTHORITY, officer-chosen: `Guild.Info.settings.priceAuthority` (Name-Realm), set
--     through the shop settings and synced like the discount (SETTINGS-002 stamped). ONLY that
--     character's client publishes; every other client applies what it receives. Unset (the
--     default), there is no guild list and every client prices on its own sources as before.
--   * WHAT THE LIST CARRIES: for every distinct itemID any banker holds (the store's union, the same
--     set the Shop tab prices) -- `sell` (the authority's default statistic, what the Est. column
--     shows), `value` (its conservative ladder, min buyout then historical -- what a donation is
--     valued at, Donations.STATISTICS), which statistic each came from, and when the authority's
--     source observed it. Two figures on purpose: the sell side and the value side are different
--     statistics (LIBREQ-PRICE-003) and one list must serve both.
--   * THE WIRE: `togbank-pl`, GUILD at BULK, positional chunks (PL_VERSION, the list version, the
--     publisher, chunk i of n, the item count, then six slots per item) with the version the
--     authority's server time at publish; a receiver applies only a NEWER version from the NAMED
--     authority (a relay cannot speak for it) and keeps it in `Guild.Info.priceList` (SavedVariables,
--     so a member who logs in while the authority is away still has the last list). The authority's
--     login/version broadcast (hlb2) names the version it holds; a client behind it asks by whisper
--     (`togbank-plq`) and is answered by whisper.
--   * WHEN IT PUBLISHES: at the authority's login and on its ten-minute cycle when the list CHANGED
--     (an unchanged list is never re-sent -- peers already hold that version), when its ItemDB
--     reports a scan or a source change (debounced), and at most once an hour from the cycle.
--   * WHO READS IT, IN WHAT ORDER: Browse:PriceRows / PriceOne (the Shop tab, the request dialog's
--     estimate) and Donations:Value consult THIS list first and their own ItemDB only for an item the
--     list lacks; the provenance says so -- source "guild", sourceName "guild list (<authority>)",
--     the statistic and the age -- so a hover and a ledger entry read where the figure came from.
--     The vendor floor still applies to a valuation.
--   * ItemDB: when the library carries the FED source of LIBREQ-PRICE-011 (`StoreExternalPrices`,
--     MINOR 26, feature-detected), a received list is fed in so every OTHER ItemDB consumer on the
--     machine sees the guild's figure. NEVER on the authority itself -- its own sources are the truth
--     the list is built from, and feeding its own list back would make a stale figure outrank a
--     fresh scan. The consult-first order above is NOT replaced by the feed: the library's `best`
--     walks a fed source min buyout first (the sell side would come back as the value side), its
--     ladder is per statistic (an item the list prices only by history would be valued by the
--     banker's own scan first -- two bankers disagreeing again), and a banker can switch the fed
--     source off in /itemdb. Measured against the real library in pricelist_spec, 2026-09-15.
--
-- KNOWN COST, stated: the authority's absence freezes the list at its last publish; every entry
-- carries its observation time and the hover says the age, which is the honest state.
TOGBankClassic_PriceList = {}
local PL = TOGBankClassic_PriceList

PL.WIRE_VERSION       = 1
PL.CHUNK_SIZE         = 100      -- items per togbank-pl message (~4 KB serialized)
PL.ITEMS_MAX          = 5000     -- a list larger than any bank could hold is not a list
PL.REPUBLISH_INTERVAL = 3600     -- seconds; the cycle republishes a changed list at most this often
PL.CALLBACK_DEBOUNCE  = 10       -- seconds; ItemDB fires several events per scan
PL.QUERY_COOLDOWN     = 300      -- seconds; a client asks for one announced version at most this often
PL.ANSWER_COOLDOWN    = 60       -- seconds; the authority answers one requester at most this often
PL.SOURCE_ID          = "guildpricelist"   -- the fed ItemDB source id (LIBREQ-PRICE-011)

-- The statistic a figure came from, as one small number on the wire. Anything else is `false`.
PL.STAT_CODES = { minBuyout = 1, market = 2, historical = 3 }
PL.STAT_NAMES = { "minBuyout", "market", "historical" }

local function now()
	return (GetServerTime and GetServerTime()) or (time and time()) or 0
end

local function isInt(n)
	return type(n) == "number" and n == n and n == math.floor(n) and n ~= math.huge and n ~= -math.huge
end

-- ---------------------------------------------------------------------------
-- Who publishes, what is held
-- ---------------------------------------------------------------------------

--- The guild's price authority (Name-Realm), or nil when none is set.
function PL:Authority()
	local G = TOGBankClassic_Guild
	return G and G.GetPriceAuthority and G:GetPriceAuthority() or nil
end

--- Is the character this client is on the authority?
function PL:IsAuthority()
	local G = TOGBankClassic_Guild
	return G and G.IsPriceAuthority and G:IsPriceAuthority() or false
end

--- The held list, only when it was published by the CURRENT authority -- a list left behind by a
--- demoted one is not the guild's price list, and no authority means no list. nil otherwise.
function PL:Held()
	local G = TOGBankClassic_Guild
	local info = G and G.Info
	local held = info and info.priceList
	local authority = self:Authority()
	if type(held) ~= "table" or type(held.items) ~= "table" or not authority then return nil end
	if held.publisher ~= authority then return nil end
	return held
end

--- How many items the guild list prices right now (0 without a list).
function PL:Count()
	local held = self:Held()
	if not held then return 0 end
	local n = 0
	for _ in pairs(held.items) do n = n + 1 end
	return n
end

--- The list's entry for one item, or nil: `{ sell, sellStat, value, valueStat, at }`.
function PL:Entry(itemID)
	local held = self:Held()
	itemID = tonumber(itemID)
	if not held or not itemID then return nil end
	local e = held.items[itemID]
	return type(e) == "table" and e or nil
end

--- "guild list (Pimptasty)" -- the source name every provenance and hover prints.
function PL:SourceName(publisher)
	local name = publisher or (self:Held() or {}).publisher or self:Authority() or "?"
	name = tostring(name):match("^([^%-]+)") or tostring(name)
	return string.format("guild list (%s)", name)
end

--- The provenance a consumer hangs on a figure, in the shape ItemDB's own answers take:
--- `{ source, sourceName, statistic, age, at }`. `age` nil when the authority's source did not say.
function PL:Provenance(entry, stat)
	local at = tonumber(entry.at)
	return {
		source     = "guild",
		sourceName = self:SourceName(),
		statistic  = stat or "guild",
		age        = at and math.max(0, now() - at) or nil,
		at         = at,
	}
end

--- The SELL figure (the Shop tab's estimate) for one item, and its provenance, or nil when the
--- list has none for it. The shape `Browse:PriceRows` reads (`value` beside the provenance).
function PL:SellInfo(itemID)
	local e = self:Entry(itemID)
	if not e or not (tonumber(e.sell) and e.sell > 0) then return nil end
	local p = self:Provenance(e, e.sellStat)
	p.value = math.floor(e.sell)
	return p
end

--- The VALUE figure (what a donation is credited at) for one item, and its provenance, or nil.
function PL:ValueInfo(itemID)
	local e = self:Entry(itemID)
	if not e or not (tonumber(e.value) and e.value > 0) then return nil end
	return math.floor(e.value), self:Provenance(e, e.valueStat)
end

-- ---------------------------------------------------------------------------
-- Building (the authority's client)
-- ---------------------------------------------------------------------------

--- The price library, when it can price a set at once. Feature-detected on the METHOD.
function PL:PriceLibrary()
	local lib = LibStub and LibStub("LibItemDB-1.0", true)
	if lib and type(lib.GetPrices) == "function" and type(lib.GetPrice) == "function" then return lib end
	return nil
end

--- Every distinct itemID any banker holds -- the store's union, the set the Shop tab prices.
function PL:CatalogueIDs()
	local G = TOGBankClassic_Guild
	local ids = {}
	if not (G and G.Info and G.GetRosterAlts) then return ids end
	for _, player in ipairs(G:GetRosterAlts() or {}) do
		local norm = G:NormalizeName(player)
		for _, item in ipairs(norm and G:GetAltItems(norm) or {}) do
			local id = type(item) == "table" and tonumber(item.ID)
			if id and id >= 1 then ids[id] = true end
		end
	end
	return ids
end

--- Build the list from THIS client's own sources: `{ items = { [id] = entry }, count }`. The sell
--- side is one bulk GetPrices at the account's default statistic; the value side is the donation
--- ladder (Donations:OwnValue -- min buyout, then historical, never market). `at` is the source's
--- observation time when it says, else nil. Returns nil when no library can price.
function PL:Build()
	local lib = self:PriceLibrary()
	if not lib then return nil end
	local ids = self:CatalogueIDs()
	local ok, sells = pcall(lib.GetPrices, lib, ids)
	if not ok or type(sells) ~= "table" then sells = {} end
	local D = TOGBankClassic_Donations
	local items, count = {}, 0
	for id in pairs(ids) do
		local entry = {}
		local s = sells[id]
		if s and type(s.value) == "number" and s.value > 0 then
			entry.sell = math.floor(s.value)
			entry.sellStat = self.STAT_CODES[s.statistic] and s.statistic or nil
			entry.at = tonumber(s.at)
		end
		local unit, info = nil, nil
		if D and D.OwnValue then unit, info = D:OwnValue(id) end
		if unit and unit > 0 then
			entry.value = math.floor(unit)
			entry.valueStat = info and self.STAT_CODES[info.statistic] and info.statistic or nil
			if not entry.at and info and tonumber(info.age) then entry.at = now() - info.age end
		end
		if entry.sell or entry.value then
			items[id] = entry
			count = count + 1
			if count >= self.ITEMS_MAX then break end
		end
	end
	return { items = items, count = count }
end

--- Are two lists the same figures? Version and time are not compared -- only what a consumer would
--- read -- so an unchanged market is never re-sent to peers that already hold it.
function PL:SameItems(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	local function covers(x, y)
		for id, e in pairs(x) do
			local f = y[id]
			if type(f) ~= "table" or f.sell ~= e.sell or f.value ~= e.value
				or f.sellStat ~= e.sellStat or f.valueStat ~= e.valueStat then
				return false
			end
		end
		return true
	end
	return covers(a, b) and covers(b, a)
end

-- ---------------------------------------------------------------------------
-- The wire
-- ---------------------------------------------------------------------------

--- One chunk as the positional array the wire carries. `false` is the absent value on every slot,
--- as the request wires do -- AceSerializer keeps nil holes only as `false`.
function PL:EncodeChunk(version, publisher, index, chunkCount, total, ids, items)
	local arr = { self.WIRE_VERSION, version, publisher, index, chunkCount, total }
	for _, id in ipairs(ids) do
		local e = items[id]
		local age = tonumber(e.at) and math.max(0, version - e.at) or false
		arr[#arr + 1] = id
		arr[#arr + 1] = e.sell or false
		arr[#arr + 1] = self.STAT_CODES[e.sellStat] or false
		arr[#arr + 1] = e.value or false
		arr[#arr + 1] = self.STAT_CODES[e.valueStat] or false
		arr[#arr + 1] = age
	end
	return arr
end

--- The chunks of a list, in order, each an encoded array. Sorted by id so two publishes of one
--- list emit the same bytes.
function PL:Chunks(version, publisher, items)
	local ids = {}
	for id in pairs(items) do ids[#ids + 1] = id end
	table.sort(ids)
	local chunkCount = math.max(1, math.ceil(#ids / self.CHUNK_SIZE))
	local out = {}
	for i = 1, chunkCount do
		local slice = {}
		for j = (i - 1) * self.CHUNK_SIZE + 1, math.min(i * self.CHUNK_SIZE, #ids) do slice[#slice + 1] = ids[j] end
		out[i] = self:EncodeChunk(version, publisher, i, chunkCount, #ids, slice, items)
	end
	return out
end

--- Send a held list's chunks: to the guild (BULK) or by whisper to one requester.
function PL:SendList(held, target)
	local Core = TOGBankClassic_Core
	if not (Core and held) then return 0 end
	local chunks = self:Chunks(held.version, held.publisher, held.items)
	for _, arr in ipairs(chunks) do
		local data = Core:SerializeWithChecksum(arr)
		if target then
			Core:SendWhisper("togbank-pl", data, target, "BULK")
		else
			Core:SendCommMessage("togbank-pl", data, "GUILD", nil, "BULK")
		end
	end
	TOGBankClassic_Output:Debug("PROTOCOL", "PRICELIST", "sent price list v%s (%d items, %d chunk%s) to %s",
		tostring(held.version), self:CountOf(held.items), #chunks, #chunks == 1 and "" or "s", target or "guild")
	return #chunks
end

function PL:CountOf(items)
	local n = 0
	for _ in pairs(items or {}) do n = n + 1 end
	return n
end

--- Build and, when the figures changed, publish. `reason` names the trigger for the log and decides
--- the hourly bound: "cycle" republishes a changed list only REPUBLISH_INTERVAL after the last
--- publish; every other reason (login, an ItemDB scan or source change, being made the authority)
--- publishes a changed list now. Returns the new version, or nil when nothing was sent.
function PL:MaybePublish(reason)
	local G = TOGBankClassic_Guild
	if not (G and G.Info) or not self:IsAuthority() then return nil end
	local built = self:Build()
	if not built then
		TOGBankClassic_Output:Debug("PROTOCOL", "PRICELIST", "not published (%s): no price library can price", tostring(reason))
		return nil
	end
	local held = G.Info.priceList
	local me = G:GetNormalizedPlayer()
	if type(held) == "table" and held.publisher == me and self:SameItems(held.items, built.items) then
		TOGBankClassic_Output:Debug("PROTOCOL", "PRICELIST", "not published (%s): the %d figures are unchanged since v%s",
			tostring(reason), built.count, tostring(held.version))
		return nil
	end
	if reason == "cycle" and type(held) == "table" and held.publisher == me
		and now() - (tonumber(held.at) or 0) < self.REPUBLISH_INTERVAL then
		TOGBankClassic_Output:Debug("PROTOCOL", "PRICELIST", "not published (cycle): changed, but v%s is under an hour old", tostring(held.version))
		return nil
	end
	local version = math.max(now(), (type(held) == "table" and tonumber(held.version) or 0) + 1)
	local list = { version = version, publisher = me, at = now(), items = built.items }
	G.Info.priceList = list
	self:SendList(list, nil)
	TOGBankClassic_Output:Info("Published the guild price list: %d items (v%d).", built.count, version)
	self:OnListChanged()
	return version
end

--- The ten-minute cycle (Events:SyncDeltaVersion), which is also the login broadcast.
function PL:OnCycle()
	if not self:IsAuthority() then return end
	self:MaybePublish(self.cycleSeen and "cycle" or "login")
	self.cycleSeen = true
end

--- The version the authority names in its hlb2 broadcast, or nil for everyone else.
function PL:AnnouncedVersion()
	if not self:IsAuthority() then return nil end
	local held = self:Held()
	return held and tonumber(held.version) or nil
end

--- XGUILD-SYNC-001 (D6): tell one federated asker, by whisper, which price-list version this
--- client holds -- the hlb2 `pl` field for a member who never hears our hlb2. Any holder may say
--- it (OnAnnounced only acts on the AUTHORITY's word, so a non-authority's line is just a
--- sighting); nothing is sent while no list is held.
function PL:AnnounceTo(target)
	local held = self:Held()
	local Core = TOGBankClassic_Core
	if not (held and target and Core) then return false end
	local data = Core:SerializeWithChecksum({ type = "pl-version", version = held.version, publisher = held.publisher })
	return Core:SendWhisper("togbank-hl", data, target, "NORMAL") and true or false
end

--- A peer's hlb2 named a price-list version. Only the authority's word counts; behind it, ask by
--- whisper -- once per announced version per QUERY_COOLDOWN, so a burst of broadcasts is one ask.
--- XGUILD-SYNC-001: a federated holder's `pl-version` line names the PUBLISHER it holds the list
--- from; when that is the authority, the ask goes to the authority (the only client that answers).
function PL:OnAnnounced(sender, version, publisher)
	local G = TOGBankClassic_Guild
	version = tonumber(version)
	if not (G and version) then return false end
	local authority = self:Authority()
	if not authority or G:NormalizeName(publisher or sender) ~= authority then return false end
	local held = self:Held()
	if held and (tonumber(held.version) or 0) >= version then return false end
	self.asked = self.asked or {}
	local last = self.asked[version]
	if last and now() - last < self.QUERY_COOLDOWN then return false end
	self.asked[version] = now()
	local Core = TOGBankClassic_Core
	local payload = { type = "pl-query", held = held and held.version or 0 }
	local sent = Core and Core:SendWhisper("togbank-plq", Core:SerializeWithChecksum(payload), authority, "NORMAL")
	TOGBankClassic_Output:Debug("PROTOCOL", "PRICELIST", "asked %s for price list v%d (holding v%s): %s",
		authority, version, tostring(held and held.version or 0), sent and "sent" or "not sent")
	return sent and true or false
end

--- A whispered ask for the list. Answered by whisper, only by the authority, only when the list is
--- newer than what the asker holds, at most once per ANSWER_COOLDOWN per asker.
function PL:OnQuery(sender, data)
	if not self:IsAuthority() or type(data) ~= "table" or data.type ~= "pl-query" then return false end
	local held = self:Held()
	if not held then return false end
	if (tonumber(data.held) or 0) >= (tonumber(held.version) or 0) then return false end
	self.answered = self.answered or {}
	local last = self.answered[sender]
	if last and now() - last < self.ANSWER_COOLDOWN then return false end
	self.answered[sender] = now()
	return self:SendList(held, sender) > 0
end

--- One item slot-set from a chunk into a clean entry, or nil when the id is not an item or neither
--- figure survives. `age` is turned back into `at` on the list's version clock.
function PL:DecodeEntry(version, id, sell, sellStat, value, valueStat, age)
	id = tonumber(id)
	if not isInt(id) or id < 1 then return nil end
	local e = {}
	sell = tonumber(sell)
	if isInt(sell) and sell > 0 then
		e.sell = sell
		e.sellStat = self.STAT_NAMES[tonumber(sellStat) or 0]
	end
	value = tonumber(value)
	if isInt(value) and value > 0 then
		e.value = value
		e.valueStat = self.STAT_NAMES[tonumber(valueStat) or 0]
	end
	if not (e.sell or e.value) then return nil end
	age = tonumber(age)
	if isInt(age) and age >= 0 then e.at = version - age end
	return id, e
end

--- A togbank-pl chunk arrived. Refused unless the sender IS the named authority and names itself
--- as publisher, and the version is newer than the held list's (or the held list is a former
--- authority's). Chunks of one version are assembled; a newer version's first chunk discards a
--- half-assembled older one. Returns true when the whole list was installed.
function PL:ReceiveChunk(sender, arr)
	local G = TOGBankClassic_Guild
	if not (G and G.Info) or type(arr) ~= "table" or arr[1] ~= self.WIRE_VERSION then return false end
	local version, publisher = tonumber(arr[2]), arr[3]
	local index, chunkCount, total = tonumber(arr[4]), tonumber(arr[5]), tonumber(arr[6])
	local authority = self:Authority()
	sender = G:NormalizeName(sender)
	if not authority or sender ~= authority or G:NormalizeName(publisher) ~= authority then
		TOGBankClassic_Output:Debug("PROTOCOL", "PRICELIST", "chunk from %s ignored: the price authority is %s (publisher named %s)",
			tostring(sender), tostring(authority), tostring(publisher))
		return false
	end
	if not (isInt(version) and version > 0 and isInt(index) and isInt(chunkCount) and index >= 1 and chunkCount >= index
		and isInt(total) and total >= 0 and total <= self.ITEMS_MAX) then
		return false
	end
	local held = self:Held()
	if held and (tonumber(held.version) or 0) >= version then
		TOGBankClassic_Output:Debug("PROTOCOL", "PRICELIST", "chunk v%d from %s ignored: holding v%s", version, sender, tostring(held.version))
		return false
	end
	local p = self.pending
	if not p or p.version ~= version or p.publisher ~= authority or p.chunkCount ~= chunkCount then
		p = { version = version, publisher = authority, chunkCount = chunkCount, total = total, chunks = {}, received = 0, items = {} }
		self.pending = p
	end
	if p.chunks[index] then return false end   -- a repeat of a chunk already held
	p.chunks[index] = true
	p.received = p.received + 1
	for i = 7, #arr, 6 do
		local id, e = self:DecodeEntry(version, arr[i], arr[i + 1], arr[i + 2], arr[i + 3], arr[i + 4], arr[i + 5])
		if id and self:CountOf(p.items) < self.ITEMS_MAX then p.items[id] = e end
	end
	TOGBankClassic_Output:Debug("PROTOCOL", "PRICELIST", "price list v%d chunk %d/%d from %s", version, index, chunkCount, sender)
	if p.received < chunkCount then return false end
	self.pending = nil
	G.Info.priceList = { version = version, publisher = authority, at = now(), items = p.items }
	TOGBankClassic_Output:Debug("PROTOCOL", "PRICELIST", "installed price list v%d from %s (%d items)", version, authority, self:CountOf(p.items))
	self:OnListChanged()
	return true
end

-- ---------------------------------------------------------------------------
-- After a list lands: the ItemDB feed, the windows
-- ---------------------------------------------------------------------------

--- Feed the held list into ItemDB as a source (LIBREQ-PRICE-011), when the library carries the
--- call. Never on the authority: its own sources ARE the list, and a fed copy ranked first would
--- have the next Build read yesterday's figures back as today's.
function PL:FeedItemDB()
	local lib = LibStub and LibStub("LibItemDB-1.0", true)
	if not (lib and type(lib.StoreExternalPrices) == "function") then return false end
	local held = self:Held()
	if not held or self:IsAuthority() then
		if type(lib.ClearExternalPrices) == "function" then pcall(lib.ClearExternalPrices, lib, self.SOURCE_ID) end
		return false
	end
	-- The library's entry keys are the three statistics (minBuyout | market | historical -- its
	-- reply of 2026-09-15 on LIBREQ-PRICE-011); `best` is a walk over them, not a key. An estimate
	-- whose statistic the wire could not name is a market figure; a value's is the conservative one.
	local entries = {}
	for id, e in pairs(held.items) do
		local row = { at = e.at or held.at }
		if e.sell then row[e.sellStat or "market"] = e.sell end
		if e.value then row[e.valueStat or "minBuyout"] = e.value end
		entries[id] = row
	end
	local ok = pcall(lib.StoreExternalPrices, lib, self.SOURCE_ID, self:SourceName(held.publisher), entries)
	return ok and true or false
end

--- The list (or the authority) changed: feed ItemDB and repaint an open Shop tab.
function PL:OnListChanged()
	self:FeedItemDB()
	local B = TOGBankClassic_UI_Browse
	if B and B.OnShopSettingChanged then B:OnShopSettingChanged() end
end

--- Guild:SetPriceAuthority wrote, or a settings broadcast carried a new authority. A client that
--- IS the new authority publishes now; every client re-reads what it holds against the new name.
function PL:OnAuthorityChanged()
	self.pending = nil
	self.asked = nil
	if self:IsAuthority() then
		self:MaybePublish("authority")
	else
		self:OnListChanged()
	end
end

-- ---------------------------------------------------------------------------
-- ItemDB's events (the authority's client)
-- ---------------------------------------------------------------------------

--- Register for the library's scan and source events, once. Each is debounced into one publish
--- attempt: a scan completes as several events, and a source toggle is often two clicks.
function PL:Init()
	if self.callbacksBound then return end
	local lib = LibStub and LibStub("LibItemDB-1.0", true)
	if not (lib and type(lib.RegisterCallback) == "function") then return end
	local function bump(reason)
		return function() PL:ScheduleAfterLibraryChange(reason) end
	end
	lib.RegisterCallback(self, "LibItemDB_ScanComplete", bump("scan"))
	lib.RegisterCallback(self, "LibItemDB_PriceSettingsChanged", bump("sources"))
	self.callbacksBound = true
end

function PL:ScheduleAfterLibraryChange(reason)
	if not self:IsAuthority() then return end
	if self.libraryTimer then return end
	local Core = TOGBankClassic_Core
	if not (Core and Core.ScheduleTimer) then return end
	self.libraryTimer = true
	Core:ScheduleTimer(function()
		PL.libraryTimer = nil
		PL:MaybePublish(reason)
	end, self.CALLBACK_DEBOUNCE)
end
