-- STORE-002 / DONATION-VALUE-001 (b): THE GUILD PRICE LIST (GUILD_STORE.md 4.2.1).
--
-- The rules under test are the design's: ONE officer-chosen price authority publishes; every other
-- client applies only a NEWER list from THAT name; the list carries a sell figure and a value
-- figure per item with their statistics and age; an unchanged list is never re-sent; a client
-- behind the version the authority's broadcast names asks by whisper and is answered by whisper;
-- Browse:PriceRows and Donations:Value consult the list FIRST and their own sources only for what
-- it lacks, the vendor floor still applying; ItemDB's fed source (LIBREQ-PRICE-011) is filled
-- when the library carries it, never on the authority.
--
-- THE WIRE HALF RUNS THE SHIPPED CODE: the real Guild + Chat dispatch + Core envelope with the send
-- captured, so what a peer receives is the bytes Publish() really produced.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local GUILD   = "Testguild"
local ME      = "Pricer-Testrealm"      -- an officer; the authority in most examples
local OFFICER = "Officer-Testrealm"
local BANKER  = "Bankchar-Testrealm"    -- the one bank character
local PEER    = "Member-Testrealm"      -- a plain member

local LINEN, THUNDERFURY, CLUB, SHIRT = 2589, 19019, 10132, 2575

local sent
local PL, G, D

--- What the one banker holds -- the catalogue the list is built from.
local BANK = { { ID = LINEN, Count = 40 }, { ID = THUNDERFURY, Count = 1 }, { ID = CLUB, Count = 2 }, { ID = SHIRT, Count = 1 } }

--- The authority's figures. Rebuilt per example (loadStack), because examples move them.
local PRICES
local function freshPrices()
	return {
		[LINEN]       = { minBuyout = 120,   market = 150,   historical = 110,  age = 3600 },
		[THUNDERFURY] = { minBuyout = 900000, historical = 800000, age = 86400 },   -- no market figure
		[CLUB]        = { historical = 4000 },                                       -- only history, no age
		-- SHIRT: nothing prices it
	}
end

local function loadStack()
	env.stubOutput()
	require("env.ace").load("AceAddon-3.0", "AceComm-3.0", "AceConsole-3.0",
		"AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
	env.loadDeltaSync()
	env.loadModules({
		"Modules/Constants.lua",
		"Modules/Switches.lua",
		"Modules/Item.lua",
		"Modules/Inventory/Record.lua",
		"Modules/Inventory/Resolve.lua",
		"Modules/Inventory/Store.lua",
		"Modules/Inventory/Scan.lua",
		"Modules/Inventory/Wire.lua",
		"Modules/DeltaComms.lua",
		"Modules/Guild.lua",
		"Modules/RequestLog.lua",
		"Modules/Donations.lua",
		"Modules/PriceList.lua",
		"Modules/Chat.lua",
	})
	local AceAddon = LibStub("AceAddon-3.0")
	if AceAddon and AceAddon.addons then
		AceAddon.addons["TOGBankClassic"] = nil
		if AceAddon.addonstatus then AceAddon.addonstatus["TOGBankClassic"] = nil end
	end
	env.loadFile("Core.lua")
	env.now = 1757000000

	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	TOGBankClassic_Database = {
		db = { global = { switches = {} }, faction = {} },
		RecordDeltaReceived = function() end,
		RecordNoChangeSent = function() end,
	}
	TOGBankClassic_Options = {
		IsIntegrityCheckDiagnosticsEnabled = function() return false end,
		IsSyncProgressMuted = function() return true end,
		GetBankEnabled = function() return true end,
		GetAutoTombstoneDays = function() return 30 end,
		GetMaxRequestPercent = function() return 100 end,
		GetBankReporting = function() return false end,
		IsOrderFulfillmentSoundEnabled = function() return false end,
	}
	G = TOGBankClassic_Guild
	G.Info = { name = GUILD, alts = { [BANKER] = {} }, requests = {}, requestsTombstones = {}, settings = {} }
	G.GetNormalizedPlayer = function() return ME end
	G.GetPlayer = function() return ME end
	G.GetBanks = function() return { BANKER } end
	G.IsBank = function(_, n) return n == BANKER end
	G.SenderHasGbankNote = function(_, n) return n == BANKER end
	G.SenderIsOfficer = function(_, n) return n == OFFICER or n == ME end
	G.SenderIsGM = function() return false end
	G.UpdateOnlineMember = function() end
	G.IsPlayerOnline = function() return true end
	G.GetRosterAlts = function() return { BANKER } end
	G.GetAltItems = function(_, n) return n == BANKER and BANK or {} end
	_G.CanViewOfficerNote = function() return false end
	-- The hlb2 branch queues the broadcast for batching when a BankerNumbers module is present
	-- (one may be, left in the shared state by an earlier spec file); Chat:Init is what creates
	-- that queue, and it is not run here.
	TOGBankClassic_Chat.hashBroadcastQueue = {}

	sent = {}
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, body, dist, target, prio, cb, cbArg)
		sent[#sent + 1] = { prefix = prefix, body = body, dist = dist, target = target, prio = prio }
		if cb then cb(cbArg, #tostring(body), #tostring(body), true) end
	end
	-- Timers fire at once: a scheduled publish is the publish.
	TOGBankClassic_Core.ScheduleTimer = function(_, fn) fn() end

	LibStub.libs["LibItemDB-1.0"] = nil
	LibStub.minors["LibItemDB-1.0"] = nil

	PL, D = TOGBankClassic_PriceList, TOGBankClassic_Donations
	PL.pending, PL.asked, PL.answered, PL.cycleSeen, PL.libraryTimer, PL.callbacksBound = nil, nil, nil, nil, nil, nil
	PL.CHUNK_SIZE = 100
	PRICES = freshPrices()
	return PL
end

--- A LibItemDB whose figures come from `prices[itemID] = { minBuyout=, market=, historical=, age= }`.
--- The account's default statistic ("best") answers the source's own preference: market first,
--- then min buyout -- so the SELL side and the VALUE side of one item can differ, as they do with
--- TradeSkillMaster in the field. `opts.external` adds the LIBREQ-PRICE-011 fed-source calls.
local function stubLibrary(prices, opts)
	local function info(p, stat)
		return { source = "tsm", sourceName = "TradeSkillMaster", statistic = stat,
			age = p.age, at = p.age and (env.now - p.age) or nil }
	end
	local lib = {
		calls = {},
		GetPrice = function(self, id, stat)
			self.calls[#self.calls + 1] = { "GetPrice", id, stat }
			local p = prices[id]
			if not (p and p[stat]) then return nil end
			return p[stat], info(p, stat)
		end,
		GetPrices = function(self, ids, stat)
			self.calls[#self.calls + 1] = { "GetPrices", ids, stat }
			local out = {}
			for id in pairs(ids) do
				local p = prices[id]
				if p then
					local s = p.market and "market" or (p.minBuyout and "minBuyout") or nil
					if s then
						local i = info(p, s); i.value = p[s]
						out[id] = i
					end
				end
			end
			return out
		end,
		HasPriceData = function() return true end,
	}
	if opts and opts.external then
		lib.StoreExternalPrices = function(self, id, name, entries) self.fed = { id = id, name = name, entries = entries } end
		lib.ClearExternalPrices = function(self, id) self.cleared = id end
	end
	if opts and opts.callbacks then
		lib.handlers = {}
		lib.RegisterCallback = function(_, event, fn) lib.handlers[event] = fn end
	end
	LibStub.libs["LibItemDB-1.0"] = lib
	LibStub.minors["LibItemDB-1.0"] = 25
	return lib
end

local function becomeCharacter(name)
	G.GetNormalizedPlayer = function() return name end
	G.GetPlayer = function() return name end
end

--- Every captured message on `prefix`, decoded through the real envelope, oldest first.
local function captured(prefix)
	local out = {}
	for _, msg in ipairs(sent) do
		if msg.prefix == prefix then
			local ok, decoded = TOGBankClassic_Core:DeserializeWithChecksum(msg.body, { sender = ME, prefix = prefix })
			assert.is_true(ok, "a " .. prefix .. " message did not decode")
			out[#out + 1] = { data = decoded, msg = msg }
		end
	end
	return out
end

local function lastSettings()
	local all = captured("togbank-hl")
	for i = #all, 1, -1 do
		if type(all[i].data) == "table" and all[i].data.type == "guild-settings" then return all[i].data.settings, all[i].msg end
	end
	return nil
end

local function deliver(msg, from)
	assert.is_table(msg, "nothing was captured, so the example would deliver a message that was never sent")
	TOGBankClassic_Chat:OnCommReceived(msg.prefix, msg.body, msg.dist or "GUILD", from)
end

local function clearSent()
	for i = #sent, 1, -1 do sent[i] = nil end
end

--- Publish as ME (the authority) and hand back the captured chunks; the wire is then cleared.
local function publishAsAuthority(reason)
	G.Info.settings.priceAuthority = ME
	stubLibrary(PRICES)
	local version = PL:MaybePublish(reason or "login")
	local chunks = captured("togbank-pl")
	clearSent()
	return version, chunks
end

-- ─── The setting ───────────────────────────────────────────────────────────────

describe("STORE-002: the price authority setting", function()
	before_each(function() env.reset(); loadStack() end)

	it("the ONE writer: a bare name is normalised, the change broadcasts stamped, no change is refused", function()
		assert.is_nil(G:GetPriceAuthority())
		assert.is_false(G:IsPriceAuthority())
		assert.is_true(G:SetPriceAuthority("  Pricer "))
		assert.equal(ME, G:GetPriceAuthority())
		assert.is_true(G:IsPriceAuthority())
		local s = lastSettings()
		assert.equal(ME, s.priceAuthority)
		assert.is_true(s.version > 0, "the write was not stamped (SETTINGS-002)")
		assert.is_false(G:SetPriceAuthority("Pricer-Testrealm"), "the same name again was reported as a change")
		assert.is_true(G:SetPriceAuthority("   "), "blank while set is a clear, which is a change")
		assert.is_nil(G:GetPriceAuthority())
		assert.equal("", lastSettings().priceAuthority, "a cleared authority must travel as an empty string, not vanish")
		assert.is_false(G:SetPriceAuthority(""), "clearing what is already clear is not a change")
		assert.is_false(G:SetPriceAuthority(nil))
	end)

	it("a peer applies the broadcast normalised; an old client's broadcast, or garbage, leaves it alone", function()
		G:SetPriceAuthority("Pricer")
		local _, msg = lastSettings()
		clearSent()
		env.reset(); loadStack()
		becomeCharacter(PEER)
		G.Info.settings.version = 0
		deliver(msg, OFFICER)
		assert.equal(ME, G:GetPriceAuthority(), "the peer did not take the authority from an officer's broadcast")
		-- A pre-STORE-002 client carries no field: nothing moves.
		local old = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = G:SettingsVersion() + 1 } })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", old, "GUILD", OFFICER)
		assert.equal(ME, G:GetPriceAuthority())
		-- Garbage is not a name.
		local bad = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = G:SettingsVersion() + 1, priceAuthority = 42 } })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", bad, "GUILD", OFFICER)
		assert.equal(ME, G:GetPriceAuthority())
		-- A bare name from a hand-built payload is normalised on the way in, and "" clears.
		local bare = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = G:SettingsVersion() + 1, priceAuthority = "Officer" } })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", bare, "GUILD", OFFICER)
		assert.equal(OFFICER, G:GetPriceAuthority())
		local none = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { version = G:SettingsVersion() + 1, priceAuthority = "" } })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", none, "GUILD", OFFICER)
		assert.is_nil(G:GetPriceAuthority())
	end)
end)

-- ─── Building ──────────────────────────────────────────────────────────────────

describe("STORE-002: building the list from the authority's own sources", function()
	before_each(function() env.reset(); loadStack() end)

	it("one entry per catalogue item a source can price: the sell side at the default statistic, the value side on the donation ladder", function()
		local lib = stubLibrary(PRICES)
		local built = PL:Build()
		assert.equal(3, built.count, "the shirt nothing prices must be absent, not zero-valued")
		assert.is_nil(built.items[SHIRT])
		-- Linen: the default statistic answered market (150); the ladder asks min buyout first (120).
		assert.same({ sell = 150, sellStat = "market", value = 120, valueStat = "minBuyout", at = env.now - 3600 }, built.items[LINEN])
		-- Thunderfury has no market figure: the sell side falls to min buyout, the same as the value.
		assert.same({ sell = 900000, sellStat = "minBuyout", value = 900000, valueStat = "minBuyout", at = env.now - 86400 }, built.items[THUNDERFURY])
		-- The club has only history: no sell figure at all, a value from the ladder's second rung, no age.
		assert.same({ value = 4000, valueStat = "historical" }, built.items[CLUB])
		-- The sell side was ONE bulk call over the catalogue set; the ladder never asked for market.
		local bulk = 0
		for _, c in ipairs(lib.calls) do
			if c[1] == "GetPrices" then bulk = bulk + 1; assert.is_true(c[2][LINEN] and c[2][SHIRT] and true, "the bulk call did not carry the catalogue") end
			if c[1] == "GetPrice" then assert.not_equal("market", c[3], "the value ladder asked for market value") end
		end
		assert.equal(1, bulk)
	end)

	it("no library that can price: no list", function()
		assert.is_nil(PL:Build())
		LibStub.libs["LibItemDB-1.0"] = { GetPrice = function() end }   -- MINOR 24: no GetPrices
		assert.is_nil(PL:Build())
	end)

	it("SameItems compares the figures a consumer reads, not the clock", function()
		local a = { [1] = { sell = 5, sellStat = "market", at = 1 }, [2] = { value = 7, valueStat = "historical" } }
		local b = { [1] = { sell = 5, sellStat = "market", at = 99 }, [2] = { value = 7, valueStat = "historical" } }
		assert.is_true(PL:SameItems(a, b))
		b[2].value = 8
		assert.is_false(PL:SameItems(a, b))
		assert.is_false(PL:SameItems(a, { [1] = a[1] }), "a missing item read as the same list")
		assert.is_false(PL:SameItems({ [1] = a[1] }, a))
	end)
end)

-- ─── Publishing ────────────────────────────────────────────────────────────────

describe("STORE-002: the authority publishes", function()
	before_each(function() env.reset(); loadStack() end)

	it("positional chunks on togbank-pl to GUILD at BULK, the list installed locally, one chat line", function()
		PL.CHUNK_SIZE = 2
		local version, chunks = publishAsAuthority("login")
		assert.equal(env.now, version, "the version is the server time at publish")
		assert.equal(2, #chunks, "3 items at 2 per chunk is 2 chunks")
		for i, c in ipairs(chunks) do
			assert.equal("GUILD", c.msg.dist); assert.equal("BULK", c.msg.prio)
			local arr = c.data
			assert.same({ PL.WIRE_VERSION, version, ME, i, 2, 3 }, { arr[1], arr[2], arr[3], arr[4], arr[5], arr[6] })
		end
		-- Sorted by id: 2589 (linen), 10132 (club) in chunk 1; 19019 in chunk 2. Six slots each,
		-- `false` for an absent figure, the age on the version's clock.
		local a1 = chunks[1].data
		assert.same({ LINEN, 150, 2, 120, 1, 3600 }, { a1[7], a1[8], a1[9], a1[10], a1[11], a1[12] })
		assert.same({ CLUB, false, false, 4000, 3, false }, { a1[13], a1[14], a1[15], a1[16], a1[17], a1[18] })
		local a2 = chunks[2].data
		assert.same({ THUNDERFURY, 900000, 1, 900000, 1, 86400 }, { a2[7], a2[8], a2[9], a2[10], a2[11], a2[12] })
		assert.is_nil(a2[13])
		-- Installed here too, so the authority's own consumers read the guild list like everyone.
		local held = PL:Held()
		assert.equal(version, held.version); assert.equal(ME, held.publisher); assert.equal(3, PL:Count())
		assert.equal(150, PL:SellInfo(LINEN).value)
		local infoLine
		for _, c in ipairs(TOGBankClassic_Output.calls) do if c.level == "Info" then infoLine = c[1] end end
		assert.matches("Published the guild price list", infoLine)
	end)

	it("an unchanged list is never re-sent; a changed one waits an hour on the cycle but not at login or after a scan", function()
		local v1 = publishAsAuthority("login")
		assert.is_nil(PL:MaybePublish("login"), "the same figures were published twice")
		assert.equal(0, #captured("togbank-pl"))
		PRICES[LINEN].market = 160
		env.now = env.now + 600
		assert.is_nil(PL:MaybePublish("cycle"), "the cycle republished a change under an hour old")
		env.now = env.now + 3001
		local v2 = PL:MaybePublish("cycle")
		assert.is_true(v2 > v1, "the hourly cycle did not publish the changed list")
		assert.equal(160, PL:SellInfo(LINEN).value)
		PRICES[LINEN].market = 170
		env.now = env.now + 5
		assert.is_true(PL:MaybePublish("scan") > v2, "a scan did not publish the changed list at once")
		PRICES[LINEN].market = 180
		env.now = env.now + 5
		assert.is_true(PL:MaybePublish("login") > v2, "a login did not publish the changed list at once")
	end)

	it("only the authority publishes; OnCycle is login the first time and cycle after", function()
		stubLibrary(PRICES)
		assert.is_nil(PL:MaybePublish("login"), "published with no authority set")
		G.Info.settings.priceAuthority = OFFICER
		assert.is_nil(PL:MaybePublish("login"), "published while another character is the authority")
		assert.is_nil(PL:AnnouncedVersion())
		assert.equal(0, #captured("togbank-pl"))
		G.Info.settings.priceAuthority = ME
		PL:OnCycle()
		local v = PL:Held().version
		assert.equal(v, PL:AnnouncedVersion())
		PRICES[LINEN].market = 160
		env.now = env.now + 60
		PL:OnCycle()
		assert.equal(v, PL:Held().version, "the second cycle, a minute later, republished")
	end)

	it("being made the authority publishes at once; ItemDB's scan and source events publish through the debounce", function()
		local lib = stubLibrary(PRICES, { callbacks = true })
		PL:Init()
		assert.is_function(lib.handlers["LibItemDB_ScanComplete"])
		assert.is_function(lib.handlers["LibItemDB_PriceSettingsChanged"])
		lib.handlers["LibItemDB_ScanComplete"]("LibItemDB_ScanComplete", "full", "complete")
		assert.equal(0, #captured("togbank-pl"), "a scan published on a client that is not the authority")
		assert.is_true(G:SetPriceAuthority("Pricer"))
		assert.is_true(#captured("togbank-pl") > 0, "becoming the authority did not publish")
		clearSent()
		PRICES[LINEN].market = 160
		env.now = env.now + 5
		lib.handlers["LibItemDB_PriceSettingsChanged"]("LibItemDB_PriceSettingsChanged", "order", {})
		assert.is_true(#captured("togbank-pl") > 0, "a source change did not republish")
		assert.is_nil(PL.libraryTimer, "the debounce latch was not released")
	end)
end)

-- ─── Receiving ─────────────────────────────────────────────────────────────────

describe("STORE-002: a member receives the list", function()
	before_each(function() env.reset(); loadStack() end)

	local function asPeerHolding(authority)
		becomeCharacter(PEER)
		G.Info.settings.priceAuthority = authority
		G.Info.priceList = nil
	end

	it("assembles every chunk from the named authority, installs it, and answers the consumers' shapes", function()
		PL.CHUNK_SIZE = 2
		local version, chunks = publishAsAuthority()
		asPeerHolding(ME)
		LibStub.libs["LibItemDB-1.0"] = nil
		deliver(chunks[1].msg, ME)
		assert.is_nil(PL:Held(), "installed on the first of two chunks")
		assert.equal(1, PL.pending.received)
		deliver(chunks[2].msg, ME)
		local held = PL:Held()
		assert.equal(version, held.version); assert.equal(ME, held.publisher); assert.equal(3, PL:Count())
		assert.is_nil(PL.pending)
		assert.same({ sell = 150, sellStat = "market", value = 120, valueStat = "minBuyout", at = version - 3600 }, held.items[LINEN])
		assert.same({ value = 4000, valueStat = "historical" }, held.items[CLUB])
		env.now = version + 1800
		local sell = PL:SellInfo(LINEN)
		assert.same({ value = 150, source = "guild", sourceName = "guild list (Pricer)", statistic = "market", age = 5400, at = version - 3600 }, sell)
		local copper, prov = PL:ValueInfo(LINEN)
		assert.equal(120, copper); assert.equal("minBuyout", prov.statistic); assert.equal(5400, prov.age)
		assert.is_nil(PL:SellInfo(CLUB), "a club with no sell figure answered one")
		local c2, p2 = PL:ValueInfo(CLUB)
		assert.equal(4000, c2); assert.is_nil(p2.age, "an unknown age read as fresh")
		assert.is_nil(PL:SellInfo(SHIRT))
	end)

	it("refuses a chunk from anyone but the authority, one naming another publisher, and an older or equal version", function()
		local version, chunks = publishAsAuthority()
		asPeerHolding(ME)
		deliver(chunks[1].msg, BANKER)
		assert.is_nil(PL:Held(), "a banker's chunk was taken as the authority's")
		assert.is_nil(PL.pending)
		-- The authority relaying a list that names someone else as publisher.
		local arr = chunks[1].data
		arr[3] = OFFICER
		TOGBankClassic_Chat:OnCommReceived("togbank-pl", TOGBankClassic_Core:SerializeWithChecksum(arr), "GUILD", ME)
		assert.is_nil(PL:Held())
		arr[3] = ME
		deliver(chunks[1].msg, ME)
		assert.equal(version, PL:Held().version)
		-- The same version again, and an older one, change nothing.
		G.Info.priceList.items[LINEN].sell = 1
		deliver(chunks[1].msg, ME)
		assert.equal(1, PL:Held().items[LINEN].sell, "an equal version was re-installed")
		arr[2] = version - 1
		TOGBankClassic_Chat:OnCommReceived("togbank-pl", TOGBankClassic_Core:SerializeWithChecksum(arr), "GUILD", ME)
		assert.equal(1, PL:Held().items[LINEN].sell, "an older version was installed")
	end)

	it("drops garbage slots, caps the count, ignores a repeated chunk, and a newer version discards a half-assembled older one", function()
		asPeerHolding(ME)
		local function chunk(version, i, n, total, items)
			local arr = { PL.WIRE_VERSION, version, ME, i, n, total }
			for _, it in ipairs(items) do for _, v in ipairs(it) do arr[#arr + 1] = v end end
			return TOGBankClassic_Core:SerializeWithChecksum(arr)
		end
		local v = env.now
		TOGBankClassic_Chat:OnCommReceived("togbank-pl", chunk(v, 1, 1, 4, {
			{ LINEN, 150, 9, 120, 1, 60 },        -- stat code 9 is not a statistic: kept, stat nil
			{ 0, 5, 1, 5, 1, 0 },                 -- id 0 is not an item
			{ CLUB, -4, 1, false, false, false },  -- a negative sell and no value: nothing survives
			{ SHIRT, 7.5, 1, 20, 3, -1 },          -- a fractional sell is dropped, the value kept, a negative age dropped
			{ "19019", 10, 1, false, false, "5" }, -- numeric strings decode
		}), "GUILD", ME)
		local held = PL:Held()
		assert.same({ sell = 150, value = 120, valueStat = "minBuyout", at = v - 60 }, held.items[LINEN])
		assert.is_nil(held.items[0]); assert.is_nil(held.items[CLUB])
		assert.same({ value = 20, valueStat = "historical" }, held.items[SHIRT])
		assert.same({ sell = 10, sellStat = "minBuyout", at = v - 5 }, held.items[THUNDERFURY])
		-- A two-chunk newer version: chunk 2 twice counts once; a NEWER version's chunk restarts.
		TOGBankClassic_Chat:OnCommReceived("togbank-pl", chunk(v + 10, 2, 2, 2, { { LINEN, 1, 1, 1, 1, 0 } }), "GUILD", ME)
		TOGBankClassic_Chat:OnCommReceived("togbank-pl", chunk(v + 10, 2, 2, 2, { { LINEN, 1, 1, 1, 1, 0 } }), "GUILD", ME)
		assert.equal(1, PL.pending.received, "a repeated chunk was counted twice")
		assert.equal(v, PL:Held().version)
		TOGBankClassic_Chat:OnCommReceived("togbank-pl", chunk(v + 20, 1, 2, 2, { { CLUB, 2, 1, 2, 1, 0 } }), "GUILD", ME)
		assert.equal(v + 20, PL.pending.version, "a newer version did not restart the assembly")
		assert.equal(1, PL.pending.received)
		TOGBankClassic_Chat:OnCommReceived("togbank-pl", chunk(v + 20, 2, 2, 2, { { LINEN, 3, 1, 3, 1, 0 } }), "GUILD", ME)
		assert.equal(v + 20, PL:Held().version)
		assert.equal(2, PL:Count())
		-- Malformed framing is refused whole.
		TOGBankClassic_Chat:OnCommReceived("togbank-pl", chunk(v + 30, 3, 2, 2, {}), "GUILD", ME)
		TOGBankClassic_Chat:OnCommReceived("togbank-pl", chunk(v + 30, 1, 1, PL.ITEMS_MAX + 1, {}), "GUILD", ME)
		assert.equal(v + 20, PL:Held().version)
		assert.is_nil(PL.pending)
	end)

	it("a list from a FORMER authority is not the guild's list; no authority, no list", function()
		local version, chunks = publishAsAuthority()
		asPeerHolding(ME)
		deliver(chunks[1].msg, ME)
		assert.equal(version, PL:Held().version)
		G.Info.settings.priceAuthority = OFFICER
		assert.is_nil(PL:Held()); assert.equal(0, PL:Count()); assert.is_nil(PL:SellInfo(LINEN))
		G.Info.settings.priceAuthority = ""
		assert.is_nil(PL:Held())
		G.Info.settings.priceAuthority = ME
		assert.equal(version, PL:Held().version, "the list came back when its publisher was the authority again")
	end)
end)

-- ─── The announce and the ask ──────────────────────────────────────────────────

describe("STORE-002: the authority's broadcast names its version; a client behind it asks by whisper", function()
	before_each(function() env.reset(); loadStack() end)

	local function hlb2(from, pl)
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hlb2", v = 0, e = "", banker = from, isBanker = false, addon = "1.6.0", pl = pl })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "GUILD", from)
	end

	it("asks the authority, once per announced version, only when behind, and never anyone else", function()
		becomeCharacter(PEER)
		G.Info.settings.priceAuthority = ME
		hlb2(OFFICER, 5000)
		assert.equal(0, #captured("togbank-plq"), "asked on a non-authority's word")
		hlb2(ME, 5000)
		local asks = captured("togbank-plq")
		assert.equal(1, #asks)
		assert.equal("WHISPER", asks[1].msg.dist)
		assert.matches("^Pricer", asks[1].msg.target)
		assert.same({ type = "pl-query", held = 0 }, asks[1].data)
		hlb2(ME, 5000)
		assert.equal(1, #captured("togbank-plq"), "the same version was asked for twice inside the cooldown")
		env.now = env.now + PL.QUERY_COOLDOWN + 1
		hlb2(ME, 5000)
		assert.equal(2, #captured("togbank-plq"), "after the cooldown the ask was not repeated")
		G.Info.priceList = { version = 5000, publisher = ME, at = env.now, items = {} }
		hlb2(ME, 5000)
		hlb2(ME, 4000)
		assert.equal(2, #captured("togbank-plq"), "asked while holding the announced version or newer")
		hlb2(ME, 5001)
		assert.equal(3, #captured("togbank-plq"))
		assert.equal(5000, captured("togbank-plq")[3].data.held)
	end)

	it("the authority answers a whispered ask with the list by whisper, only when the asker is behind, at most once a minute per asker", function()
		local version = publishAsAuthority()
		local function ask(from, held)
			TOGBankClassic_Chat:OnCommReceived("togbank-plq", TOGBankClassic_Core:SerializeWithChecksum({ type = "pl-query", held = held }), "WHISPER", from)
		end
		ask(PEER, 0)
		local answers = captured("togbank-pl")
		assert.equal(1, #answers)
		assert.equal("WHISPER", answers[1].msg.dist); assert.matches("^Member", answers[1].msg.target)
		assert.equal(version, answers[1].data[2])
		ask(PEER, 0)
		assert.equal(1, #captured("togbank-pl"), "the same asker was answered twice inside a minute")
		env.now = env.now + PL.ANSWER_COOLDOWN + 1
		ask(PEER, version)
		assert.equal(1, #captured("togbank-pl"), "answered an asker who already holds the version")
		ask(OFFICER, version - 1)
		assert.equal(2, #captured("togbank-pl"))
		-- Not the authority: silence.
		becomeCharacter(OFFICER)
		ask(PEER, 0)
		assert.equal(2, #captured("togbank-pl"))
	end)
end)

-- ─── Consumers ─────────────────────────────────────────────────────────────────

describe("STORE-002: the consumers read the guild list first", function()
	before_each(function() env.reset(); loadStack() end)

	--- A peer holding the authority's list, with its OWN library saying something else.
	local function peerWithList()
		local version, chunks = publishAsAuthority()
		becomeCharacter(PEER)
		G.Info.priceList = nil
		for _, c in ipairs(chunks) do deliver(c.msg, ME) end
		assert.equal(version, PL:Held().version)
		local lib = stubLibrary({
			[LINEN] = { minBuyout = 900, market = 950, historical = 800, age = 10 },
			[SHIRT] = { minBuyout = 30, historical = 25, age = 10 },
		})
		return lib
	end

	it("Donations:Value credits at the guild's figure, floored by the vendor, and falls to its own sources only for an item the list lacks", function()
		local lib = peerWithList()
		local copper, info = D:Value(LINEN, 2, 100)
		assert.equal(240, copper, "the guild's 120 was not what the peer's own 900 was overruled by")
		assert.equal("guild list (Pricer)", info.source); assert.equal("minBuyout", info.statistic); assert.equal(120, info.unit)
		copper, info = D:Value(LINEN, 1, 130)
		assert.equal(130, copper); assert.equal("vendor", info.source, "the vendor floor did not apply over the guild figure")
		copper, info = D:Value(SHIRT, 1, 0)
		assert.equal(30, copper); assert.equal("TradeSkillMaster", info.source, "an item the list lacks was not valued on the peer's own ladder")
		assert.equal(0, #(function() local n = {} for _, c in ipairs(lib.calls) do if c[2] == LINEN then n[#n + 1] = c end end return n end)(),
			"the peer's own library was asked about an item the guild list prices")
		-- With no authority the list is not consulted: the old behaviour, exactly.
		G.Info.settings.priceAuthority = ""
		copper, info = D:Value(LINEN, 1, 0)
		assert.equal(900, copper); assert.equal("TradeSkillMaster", info.source)
	end)

	it("Browse:PriceRows and PriceOne take the guild's sell figure first, the peer's own library only for the rest", function()
		local lib = peerWithList()
		TOGBankClassic_UI = TOGBankClassic_UI or {}
		TOGBankClassic_UI.FILTER_INSET = TOGBankClassic_UI.FILTER_INSET or 8
		env.loadFile("Modules/UI/Browse.lua")
		local B = TOGBankClassic_UI_Browse
		G.GetStoreDiscount = function() return 0 end
		local rows = B:PriceRows({ { ID = LINEN }, { ID = SHIRT }, { ID = CLUB } })
		assert.equal(150, rows[1].value, "linen did not take the guild list's sell figure over the peer's own 950")
		assert.equal("guild", rows[1].priceInfo.source); assert.equal("guild list (Pricer)", rows[1].priceInfo.sourceName)
		assert.equal("market value, guild list (Pricer)", B:EstimateSourceText(rows[1].priceInfo))
		assert.equal(30, rows[2].value, "the shirt, absent from the list, was not priced by the peer's own library")
		assert.equal("tsm", rows[2].priceInfo.source)
		assert.is_nil(rows[3].value, "the club has no sell figure anywhere and must stay unpriced")
		-- The one bulk call carried only what the list lacked.
		local bulk
		for _, c in ipairs(lib.calls) do if c[1] == "GetPrices" then bulk = c[2] end end
		assert.is_nil(bulk[LINEN]); assert.is_true(bulk[SHIRT]); assert.is_true(bulk[CLUB])
		local one = B:PriceOne(LINEN)
		assert.equal(150, one.value); assert.equal("guild", one.priceInfo.source)
		-- No own library at all: the guild list still prices.
		LibStub.libs["LibItemDB-1.0"] = nil
		rows = B:PriceRows({ { ID = LINEN }, { ID = SHIRT } })
		assert.equal(150, rows[1].value); assert.is_nil(rows[2].value)
	end)
end)

-- ─── The ItemDB feed ───────────────────────────────────────────────────────────

describe("STORE-002: feeding the list into ItemDB (LIBREQ-PRICE-011), when the library carries it", function()
	before_each(function() env.reset(); loadStack() end)

	it("a member's library is fed the list as one named source; the authority's never is; clearing the authority clears it", function()
		local version, chunks = publishAsAuthority()
		local mine = stubLibrary({}, { external = true })
		PL:OnListChanged()
		assert.is_nil(mine.fed, "the authority fed its own list back into its own sources")
		assert.equal(PL.SOURCE_ID, mine.cleared)
		becomeCharacter(PEER)
		G.Info.priceList = nil
		local theirs = stubLibrary({}, { external = true })
		for _, c in ipairs(chunks) do deliver(c.msg, ME) end
		assert.equal(PL.SOURCE_ID, theirs.fed.id)
		assert.equal("guild list (Pricer)", theirs.fed.name)
		assert.same({ market = 150, minBuyout = 120, at = version - 3600 }, theirs.fed.entries[LINEN])
		assert.same({ historical = 4000, at = PL:Held().at }, theirs.fed.entries[CLUB])
		assert.is_nil(theirs.fed.entries[SHIRT])
		G:SetPriceAuthority("")
		assert.equal(PL.SOURCE_ID, theirs.cleared)
		-- A library without the call: nothing to do, no error.
		stubLibrary({})
		assert.is_false(PL:FeedItemDB())
	end)
end)

-- LIBREQ-PRICE-011 ADOPTION: the pin against the REAL library (ItemDB MINOR 26, adopted from its
-- working tree under LIB-RELEASE-ORDER -- the operator releases the library after TOGBank is done).
-- The stub above proves what TOGBank HANDS the library; this proves the library SERVES it back the
-- way the contract says: first in the ladder, under TOGBank's source id, and gone on a clear.
--
-- `env.libs` loads only the core file for LibItemDB (its manifest says so: the price ladder is
-- addon payload from the loader's point of view), so `Price/Sources.lua` is loaded here by its
-- installed path, exactly as ItemDB's own `Tests/env_price.lua` does.
describe("LIBREQ-PRICE-011: the real LibItemDB serves the fed list", function()
	local libs = require("env.libs")

	before_each(function() env.reset(); loadStack() end)
	after_each(function()
		-- The real library must not outlive this describe: every other file in the suite stubs or
		-- nils the LibStub entry and a spec that feature-detects `LibStub("LibItemDB-1.0", true)`
		-- without doing either would silently find a real one (SPEC-ORDER-001's class).
		libs.forget("LibItemDB-1.0")
		_G.LibItemDB_PriceDB = nil
	end)

	local function realLibrary()
		libs.fresh("LibItemDB-1.0")   -- loadStack evicted the LibStub entry; fresh() re-registers
		require("env.ace").load("CallbackHandler-1.0")
		require("env.wow").loadAddonFile(libs.pathOf("LibItemDB-1.0", "Price/Sources.lua"), "ItemDB")
		_G.LibItemDB_PriceDB = {}   -- a fresh SavedVariables table, as a first-run client has
		local lib = LibStub("LibItemDB-1.0")
		assert.is_function(lib.StoreExternalPrices, "the installed ItemDB is older than MINOR 26 -- no fed source")
		assert.is_function(lib.GetPriceSources)
		return lib
	end

	it("a received list lands in the library FIRST in precedence, answers each statistic under TOGBank's source id, and a cleared authority removes it", function()
		if not libs.available("LibItemDB-1.0") then pending("ItemDB is not installed beside this addon") end
		local version, chunks = publishAsAuthority()
		becomeCharacter(PEER)
		G.Info.priceList = nil
		local lib = realLibrary()
		assert.is_nil(lib:GetPrice(LINEN, "market"), "a fresh library priced linen before anything fed it")
		assert.is_false(lib:HasPriceData(), "a fresh library with no scan claimed price data")

		for _, c in ipairs(chunks) do deliver(c.msg, ME) end
		assert.equal(version, PL:Held().version)

		-- The ladder: the fed source is first, external, detected for this realm + faction, and
		-- counts the three entries the list carried (the shirt nothing priced is absent).
		local sources = lib:GetPriceSources()
		assert.equal(PL.SOURCE_ID, sources[1].id)
		assert.equal("guild list (Pricer)", sources[1].name)
		assert.is_true(sources[1].external); assert.is_true(sources[1].detected); assert.is_true(sources[1].enabled)
		assert.equal(1, sources[1].precedence)
		assert.equal(3, sources[1].count)
		assert.is_true(lib:HasPriceData())

		-- Each statistic the wire carried, named, under TOGBank's id and display name.
		local price, info = lib:GetPrice(LINEN, "market")
		assert.equal(150, price)
		assert.equal(PL.SOURCE_ID, info.source); assert.equal("guild list (Pricer)", info.sourceName); assert.equal("market", info.statistic)
		assert.equal(version - 3600, info.at, "the entry's own observation time did not travel through")
		assert.equal(120, (lib:GetPrice(LINEN, "minBuyout")))
		assert.equal(900000, (lib:GetPrice(THUNDERFURY, "minBuyout")))
		assert.is_nil(lib:GetPrice(THUNDERFURY, "market"), "a statistic the list did not carry was answered")
		assert.equal(4000, (lib:GetPrice(CLUB, "historical")))
		assert.is_nil(lib:GetPrice(SHIRT), "an item the list lacks was priced")
		-- The account default ("best") walks the fed source's statistics minBuyout first.
		local best, bestInfo = lib:GetPrice(LINEN)
		assert.equal(120, best); assert.equal("minBuyout", bestInfo.statistic); assert.equal(PL.SOURCE_ID, bestInfo.source)
		-- The bulk form Browse uses answers from the same source.
		local rows, n = lib:GetPrices({ LINEN, CLUB, SHIRT }, "market")
		assert.equal(1, n); assert.equal(150, rows[LINEN].value); assert.equal(PL.SOURCE_ID, rows[LINEN].source)

		-- And it is in the SavedVariables the library keeps, keyed by this realm + faction.
		local saved = _G.LibItemDB_PriceDB.realms[lib:GetPriceScope()]
		assert.is_table(saved.external[PL.SOURCE_ID])
		assert.equal(150, saved.external[PL.SOURCE_ID].items[LINEN].market)

		-- Clearing the authority clears the fed data; the row stays (not detected) so the user's
		-- precedence survives the next feed.
		G:SetPriceAuthority("")
		assert.is_nil(lib:GetPrice(LINEN, "market"), "the fed list still priced after the authority was cleared")
		sources = lib:GetPriceSources()
		assert.equal(PL.SOURCE_ID, sources[1].id); assert.is_false(sources[1].detected); assert.equal(0, sources[1].count)
		assert.is_false(lib:HasPriceData())
	end)

	it("the authority's own client never feeds itself, and re-naming it clears what it held as a member", function()
		if not libs.available("LibItemDB-1.0") then pending("ItemDB is not installed beside this addon") end
		local _, chunks = publishAsAuthority()
		becomeCharacter(PEER)
		G.Info.priceList = nil
		local lib = realLibrary()
		for _, c in ipairs(chunks) do deliver(c.msg, ME) end
		assert.equal(150, (lib:GetPrice(LINEN, "market")))
		-- The officer makes THIS character the authority: what it held from Pricer is no longer the
		-- guild's list, and its library must stop serving it.
		G:SetPriceAuthority("Member")
		assert.is_true(G:IsPriceAuthority())
		assert.is_nil(lib:GetPrice(LINEN, "market"), "the new authority's library still served the old list")
	end)
end)

-- ─── Shipping ──────────────────────────────────────────────────────────────────

describe("STORE-002: shipping", function()
	it("both TOCs load Modules/PriceList.lua after Donations.lua; the two prefixes are registered", function()
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_TBC.toc", "TOGBankClassic_Mists.toc" }) do
			local text = env.readFile(toc)
			local d, p = text:find("Modules/Donations.lua", 1, true), text:find("Modules/PriceList.lua", 1, true)
			assert.is_true(d ~= nil and p ~= nil and p > d, toc .. " does not load PriceList after Donations")
		end
		env.reset(); loadStack()
		local have = {}
		for _, p in ipairs(TOGBankClassic_Chat.COMM_PREFIXES) do have[p] = true end
		assert.is_true(have["togbank-pl"] and have["togbank-plq"])
		assert.is_string(TOGBankClassic_Constants.COMM_PREFIX_DESCRIPTIONS["togbank-pl"])
		assert.is_string(TOGBankClassic_Constants.COMM_PREFIX_DESCRIPTIONS["togbank-plq"])
	end)
end)
