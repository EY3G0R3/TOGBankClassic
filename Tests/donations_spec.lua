-- STORE-007: DONATION CREDIT (GUILD_STORE.md 4.7, build-order step 6).
--
-- The rules under test are the design's, each the answer to an argument: a donation is valued ONCE,
-- at ingest, by the banker who receives it, from a CONSERVATIVE statistic floored at what a vendor
-- pays; points are written by bankers and officers and never by the member; each writer publishes
-- only its own totals and a balance is the sum across writers; adjustments carry a reason; the old
-- vendor-valued scores are an opening balance, never re-valued.
--
-- THE WIRE HALF RUNS THE SHIPPED CODE: the real Guild + Chat dispatch + Core envelope, the send
-- captured, so what a peer receives is the bytes Broadcast() really produced. THE INGEST HALF drives
-- the real Mail:Open against the harness inbox model (wow.mail / wow.mailActions).
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")
local wow = require("env.wow")

local GUILD  = "Testguild"
local ME     = "Bankchar-Testrealm"       -- a banker
-- LEDGER-PC-001: a WRITER is the character on a machine; the fixture pins this machine's id.
local W      = ME .. "@pc1"
local OFFICER = "Officer-Testrealm"
local PEER   = "Member-Testrealm"         -- a plain member

local sent
local D

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
		db = { global = { switches = {}, donationMachineID = "pc1" }, faction = {} },
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
	TOGBankClassic_Guild.Info = { name = GUILD, alts = {}, requests = {}, requestsTombstones = {}, settings = {} }
	TOGBankClassic_Guild.GetNormalizedPlayer = function() return ME end
	TOGBankClassic_Guild.GetPlayer = function() return ME end
	TOGBankClassic_Guild.GetBanks = function() return { ME } end
	TOGBankClassic_Guild.IsBank = function(_, n) return n == ME end
	TOGBankClassic_Guild.SenderHasGbankNote = function(_, n) return n == ME end
	TOGBankClassic_Guild.SenderIsOfficer = function(_, n) return n == OFFICER end
	TOGBankClassic_Guild.SenderIsGM = function() return false end
	TOGBankClassic_Guild.UpdateOnlineMember = function() end
	TOGBankClassic_Guild.IsPlayerOnline = function() return true end
	_G.CanViewOfficerNote = function() return false end
	_G.ATTACHMENTS_MAX_RECEIVE = 16

	sent = {}
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, body, dist, target, _, cb, cbArg)
		sent[#sent + 1] = { prefix = prefix, body = body, dist = dist, target = target }
		if cb then cb(cbArg, #tostring(body), #tostring(body), true) end
	end
	-- Timers fire at once: a scheduled broadcast is the broadcast.
	TOGBankClassic_Core.ScheduleTimer = function(_, fn) fn() end

	-- No price library unless an example installs one.
	LibStub.libs["LibItemDB-1.0"] = nil
	LibStub.minors["LibItemDB-1.0"] = nil

	D = TOGBankClassic_Donations
	D.broadcastPending = nil
	D.ENTRIES_MAX = 300
	return D
end

--- A LibItemDB answering GetPrice from `prices[itemID][statistic] = copper`.
local function stubPriceLibrary(prices, calls)
	LibStub.libs["LibItemDB-1.0"] = {
		GetPrice = function(_, itemID, statistic)
			if calls then calls[#calls + 1] = { itemID, statistic } end
			local p = prices[itemID] and prices[itemID][statistic]
			if not p then return nil end
			return p, { source = "scan", sourceName = "own scan", statistic = statistic, age = 60 }
		end,
	}
	LibStub.minors["LibItemDB-1.0"] = 25
end

local function becomeCharacter(name)
	TOGBankClassic_Guild.GetNormalizedPlayer = function() return name end
	TOGBankClassic_Guild.GetPlayer = function() return name end
end

--- The last donation-points payload put on the wire, decoded, and the raw message.
local function lastPublished()
	for i = #sent, 1, -1 do
		local msg = sent[i]
		if msg.prefix == "togbank-hl" then
			local ok, decoded = TOGBankClassic_Core:DeserializeWithChecksum(msg.body, { sender = ME, prefix = msg.prefix })
			if ok and type(decoded) == "table" and decoded.type == "donation-points" then return decoded, msg end
		end
	end
	return nil
end

local function lastSettings()
	for i = #sent, 1, -1 do
		local msg = sent[i]
		if msg.prefix == "togbank-hl" then
			local ok, decoded = TOGBankClassic_Core:DeserializeWithChecksum(msg.body, { sender = ME, prefix = msg.prefix })
			if ok and type(decoded) == "table" and decoded.type == "guild-settings" then return decoded.settings end
		end
	end
	return nil
end

local function deliver(msg, from)
	assert.is_table(msg, "nothing was captured, so the example would deliver a message that was never sent")
	TOGBankClassic_Chat:OnCommReceived(msg.prefix, msg.body, msg.dist or "GUILD", from)
end

--- Every Response line, FORMATTED the way Output would print it (the stub records the raw args).
local function responses()
	local out = {}
	for _, c in ipairs(TOGBankClassic_Output.calls) do
		if c.level == "Response" then
			out[#out + 1] = c.n > 1 and string.format(c[1], unpack(c, 2, c.n)) or c[1]
		end
	end
	return out
end

--- The stub records into ONE table captured by its closure; empty it in place.
local function clearOutput()
	local calls = TOGBankClassic_Output.calls
	for i = #calls, 1, -1 do calls[i] = nil end
end

-- ─── Valuation ─────────────────────────────────────────────────────────────────

describe("STORE-007: valuing a donation", function()
	before_each(function() env.reset(); loadStack() end)

	it("with no price library the vendor sell price is the value, times the count", function()
		local copper, info = D:Value(2589, 20, 13)
		assert.equal(260, copper)
		assert.equal("vendor", info.source)
		assert.equal(13, info.unit)
	end)

	it("asks for the CONSERVATIVE statistics in order and never market value", function()
		local calls = {}
		stubPriceLibrary({ [2589] = { historical = 50, market = 900 } }, calls)
		local copper, info = D:Value(2589, 2, 13)
		assert.equal(100, copper, "historical was not used")
		assert.equal("historical", info.statistic)
		assert.equal("own scan", info.source)
		assert.equal(60, info.age)
		assert.equal(2, #calls)
		assert.equal("minBuyout", calls[1][2]); assert.equal("historical", calls[2][2])
		-- An item only market can price is valued at the floor: market is never asked for.
		calls = {}
		stubPriceLibrary({ [2590] = { market = 900 } }, calls)
		copper, info = D:Value(2590, 1, 7)
		assert.equal(7, copper); assert.equal("vendor", info.source)
		for _, c in ipairs(calls) do assert.is_not_equal("market", c[2]) end
	end)

	it("the vendor price is a FLOOR: a listing below it does not lower the value", function()
		stubPriceLibrary({ [2589] = { minBuyout = 5 } })
		local copper, info = D:Value(2589, 3, 13)
		assert.equal(39, copper); assert.equal("vendor", info.source)
		stubPriceLibrary({ [2589] = { minBuyout = 40 } })
		copper, info = D:Value(2589, 3, 13)
		assert.equal(120, copper); assert.equal("minBuyout", info.statistic)
	end)

	it("nothing values it: 0 copper, source none -- never refused, never an error", function()
		local copper, info = D:Value(nil, 1, nil)
		assert.equal(0, copper); assert.equal("none", info.source)
		copper, info = D:Value(99999, 0, 0)
		assert.equal(0, copper); assert.equal("none", info.source)
	end)

	it("a library that throws is a library that cannot price", function()
		LibStub.libs["LibItemDB-1.0"] = { GetPrice = function() error("boom") end }
		local copper, info = D:Value(2589, 1, 13)
		assert.equal(13, copper); assert.equal("vendor", info.source)
	end)

	it("the rate: default 1 point per gold, an officer's value applied, garbage read as the default", function()
		assert.equal(1, D:Rate())
		assert.equal(1.5, D:PointsFor(15000))
		TOGBankClassic_Guild.Info.settings.donationRate = 2.5
		assert.equal(2.5, D:Rate())
		assert.equal(3.75, D:PointsFor(15000))
		assert.equal(0.02, D:PointsFor(75), "not rounded to two decimals")
		assert.equal(0, D:PointsFor(-5))
		TOGBankClassic_Guild.Info.settings.donationRate = "lots"
		assert.equal(1, D:Rate())
		TOGBankClassic_Guild.Info.settings.donationRate = 0
		assert.equal(1, D:Rate())
		TOGBankClassic_Guild.Info.settings.donationRate = 5000
		assert.equal(1, D:Rate())
	end)
end)

-- ─── The ledger ────────────────────────────────────────────────────────────────

describe("STORE-007: the writer's own ledger", function()
	before_each(function() env.reset(); loadStack() end)

	it("a credit is written ONCE into this character's ledger, and the total follows", function()
		TOGBankClassic_Guild.Info.settings.donationRate = 2
		local e = D:Credit({ donor = "Alice", kind = "item", itemID = 2589, name = "Linen Cloth", count = 20, copper = 30000, source = "own scan", statistic = "minBuyout", age = 60 })
		assert.is_table(e)
		assert.equal(6, e.points, "30000 copper at 2 per gold")
		assert.equal(ME, e.by)
		assert.equal(env.now, e.at)
		local L = TOGBankClassic_Guild.Info.donationLedger[W]
		assert.equal(1, #L.entries)
		assert.same({ Alice = 6 }, D:LedgerTotals(L))
		-- The rate changes; the entry does not.
		TOGBankClassic_Guild.Info.settings.donationRate = 1
		assert.equal(6, L.entries[1].points)
		assert.same({ Alice = 6 }, D:LedgerTotals(L))
		-- Money.
		D:Credit({ donor = "Alice", kind = "money", copper = 12345 })
		assert.equal(1.23, L.entries[2].points)
		assert.same({ Alice = 7.23 }, D:LedgerTotals(L))
		assert.equal(7.23, D:PointsOf("Alice"))
		assert.equal(7.23, D:PointsOf("Alice-Testrealm"), "the normalized name did not find the bare-name balance")
	end)

	it("refuses a credit with no donor or no guild, and says so with nil", function()
		assert.is_nil(D:Credit({ kind = "money", copper = 100 }))
		assert.is_nil(D:Credit({ donor = "", kind = "money", copper = 100 }))
		local info = TOGBankClassic_Guild.Info
		TOGBankClassic_Guild.Info = nil
		assert.is_nil(D:Credit({ donor = "Alice", kind = "money", copper = 100 }))
		TOGBankClassic_Guild.Info = info
	end)

	it("an adjustment needs an officer, a donor, a non-zero number and a reason, and may be negative", function()
		local e, why = D:Adjust("Alice", 5, "mis-sent")
		assert.is_nil(e); assert.truthy(why:find("officer", 1, true))
		_G.CanViewOfficerNote = function() return true end
		e, why = D:Adjust(nil, 5, "x"); assert.is_nil(e); assert.truthy(why:find("whose", 1, true))
		e, why = D:Adjust("Alice", 0, "x"); assert.is_nil(e); assert.truthy(why:find("how many", 1, true))
		assert.is_nil((D:Adjust("Alice", "many", "x")))
		e, why = D:Adjust("Alice", 5, "   "); assert.is_nil(e); assert.truthy(why:find("reason", 1, true))
		e = D:Adjust("Alice", -2.5, "  returned the Black Lotus  ")
		assert.is_table(e)
		assert.equal("adjust", e.kind); assert.equal(-2.5, e.points); assert.equal("returned the Black Lotus", e.reason)
		assert.equal(-2.5, D:PointsOf("Alice"))
		-- The reason is clamped, not refused.
		e = D:Adjust("Alice", 1, string.rep("r", 500))
		assert.equal(D.REASON_MAX_LEN, #e.reason)
	end)

	-- DONOR-KEY-001 (Peer Review f5e52bcf F7): the mail header, a cross-realm header and an officer's
	-- typing are three spellings of one donor; the board used to split them.
	it("one donor, one key: the header's bare name, a realm-qualified name and an officer's casing all land on the same balance", function()
		_G.CanViewOfficerNote = function() return true end
		D:Credit({ donor = "Alice", kind = "money", copper = 300000 })          -- the header, same realm
		D:Credit({ donor = "Alice-Otherrealm", kind = "money", copper = 10000 })  -- a cross-realm header
		local e = D:Adjust("alice", -5, "mailed the wrong stack")             -- the officer, as typed
		assert.equal("Alice", e.donor, "the adjustment was keyed as typed")
		assert.same({ Alice = 26 }, D:Balances())
		assert.equal(26, D:PointsOf("ALICE-Testrealm")); assert.equal(26, D:PointsOf(" alice "))
		local board = D:Scoreboard()
		assert.equal(1, #board, "one donor is on the board under more than one name")
		-- A donor new to the board is written as WoW spells names.
		D:Adjust("bOB", 2, "raid help")
		assert.equal(2, D:PointsOf("Bob"))
		assert.is_nil(D:DonorKey("")); assert.is_nil(D:DonorKey("  -Realm")); assert.is_nil(D:DonorKey(7))
	end)

	it("the log is capped, and what falls off rolls into the opening balance so no total moves", function()
		D.ENTRIES_MAX = 3
		for i = 1, 5 do D:Credit({ donor = "Alice", kind = "money", copper = 10000 * i }) end
		local L = TOGBankClassic_Guild.Info.donationLedger[W]
		assert.equal(3, #L.entries)
		assert.equal(3, L.entries[1].points, "the oldest kept entry is not the third")
		assert.equal(3, L.opening.Alice, "1 + 2 did not roll into the opening balance")
		assert.equal(15, D:PointsOf("Alice"))
		-- Newest first, optionally one donor's.
		D:Credit({ donor = "Bob", kind = "money", copper = 10000 })
		local all = D:Entries()
		assert.equal(3, #all); assert.equal("Bob", all[1].donor); assert.equal(5, all[2].points)
		assert.equal(2, #D:Entries("Alice"))
		assert.equal(0, #D:Entries("Nobody"))
	end)

	it("carries the old vendor-valued scores of THIS character into its opening balance, once", function()
		TOGBankClassic_Guild.Info.alts[ME] = { ledger = { Alice = 12.345, Bob = 0, Carl = "x" } }
		assert.is_true(D:MigrateOwnLedger())
		local L = TOGBankClassic_Guild.Info.donationLedger[W]
		assert.equal(12.35, L.opening.Alice)
		assert.is_nil(L.opening.Bob, "a zero score was carried")
		assert.is_nil(L.opening.Carl)
		assert.is_nil(TOGBankClassic_Guild.Info.alts[ME].ledger, "the old table was left behind to be counted twice")
		assert.is_false(D:MigrateOwnLedger(), "a second migration found something to move")
		assert.equal(12.35, D:PointsOf("Alice"))
		-- A credit after the migration adds to it.
		D:Credit({ donor = "Alice", kind = "money", copper = 10000 })
		assert.equal(13.35, D:PointsOf("Alice"))
		-- Another character's legacy table is NOT ours to migrate, and is not touched.
		TOGBankClassic_Guild.Info.alts["Otherbank-Testrealm"] = { ledger = { Alice = 1 } }
		assert.is_false(D:MigrateOwnLedger())
		assert.is_table(TOGBankClassic_Guild.Info.alts["Otherbank-Testrealm"].ledger)
	end)
end)

-- ─── Balances across writers ───────────────────────────────────────────────────

describe("STORE-007: a balance is the sum across writers", function()
	before_each(function() env.reset(); loadStack() end)

	it("own ledger first, then a published bucket, then a legacy score not yet migrated -- one per writer", function()
		local info = TOGBankClassic_Guild.Info
		D:Credit({ donor = "Alice", kind = "money", copper = 10000 })              -- ME: 1
		info.donationPoints = {
			[W] = { totals = { Alice = 99 }, version = 5 },                         -- ignored: this machine's ledger is the source
			["Otherbank-Testrealm"] = { totals = { Alice = 2, Bob = 4 }, version = 3 },
			[OFFICER] = { totals = { Alice = -0.5 }, version = 1 },
		}
		info.alts["Thirdbank-Testrealm"] = { ledger = { Alice = 3, Zed = 1, Yan = 1 } }   -- legacy, counted
		info.alts["Otherbank-Testrealm"] = { ledger = { Alice = 1000 } }                  -- legacy, but a bucket wins
		local b = D:Buckets()
		assert.same({ Alice = 1 }, b[W])
		assert.same({ Alice = 2, Bob = 4 }, b["Otherbank-Testrealm"])
		assert.same({ Alice = 3, Zed = 1, Yan = 1 }, b["Thirdbank-Testrealm"])
		assert.same({ Alice = 5.5, Bob = 4, Zed = 1, Yan = 1 }, D:Balances())
		local board = D:Scoreboard()
		assert.equal(4, #board)
		assert.equal("Alice", board[1].player); assert.equal(5.5, board[1].points)
		assert.equal("Bob", board[2].player)
		assert.equal("Yan", board[3].player, "a tie is not broken by name"); assert.equal("Zed", board[4].player)
		assert.equal(0, D:PointsOf("Nobody")); assert.equal(0, D:PointsOf(nil))
	end)

	it("a zero balance is not on the board", function()
		_G.CanViewOfficerNote = function() return true end
		D:Adjust("Alice", 2, "test"); D:Adjust("Alice", -2, "undo")
		assert.equal(0, #D:Scoreboard())
	end)
end)

-- ─── The wire ──────────────────────────────────────────────────────────────────

describe("STORE-007: publishing totals and receiving them", function()
	before_each(function() env.reset(); loadStack() end)

	it("a banker's credit publishes its OWN bucket on togbank-hl, and a member holds it", function()
		D:Credit({ donor = "Alice", kind = "money", copper = 25000 })
		local payload, msg = lastPublished()
		assert.is_table(payload, "the credit did not publish")
		assert.equal(W, payload.writer, "the writer is the character on this machine")
		assert.same({ Alice = 2.5 }, payload.totals)
		assert.is_number(payload.version)
		-- A member receives it, keyed by the machine-qualified writer.
		local info = TOGBankClassic_Guild.Info
		becomeCharacter(PEER)
		info.donationLedger = nil
		deliver(msg, ME)
		assert.same({ Alice = 2.5 }, info.donationPoints[W].totals)
		assert.equal(2.5, D:PointsOf("Alice"), "the member does not see the banker's total")
		-- Nothing a member does publishes anything: not a banker, not an officer.
		local before = #sent
		assert.is_false(D:Broadcast())
		assert.equal(before, #sent)
	end)

	-- DONATION-VALUE-001 (the operator, 2026-09-14: "flesh out the donation points = to gold value
	-- now that we have the monetary tie in to ItemDB"): the gold behind the points rides the same
	-- bucket, sums across writers the same way, survives the ledger's roll-off, and prints beside
	-- the points on the board, the chat line and the window.
	it("the gold VALUE behind the points: kept per credit, rolled with the cap, published beside the totals, summed across writers", function()
		D:Credit({ donor = "Alice", kind = "money", copper = 25000 })
		D:Credit({ donor = "Alice", kind = "item", itemID = 2589, name = "Linen Cloth", count = 20, copper = 500, source = "own scan", statistic = "minBuyout" })
		D:Credit({ donor = "Bob", kind = "money", copper = 10000 })
		_G.CanViewOfficerNote = function() return true end
		becomeCharacter(OFFICER)
		D:Adjust("Alice", 5, "raid help")          -- points with no value behind them
		becomeCharacter(ME)
		local L = D:Ledger(W)
		assert.same({ Alice = 25500, Bob = 10000 }, D:LedgerValues(L))
		assert.same({ Alice = 25500, Bob = 10000 }, D:Values())
		assert.equal(25500, D:ValueOf("Alice")); assert.equal(25500, D:ValueOf("Alice-Testrealm"))
		assert.equal(0, D:ValueOf("Nobody"))
		-- The board carries copper; the adjustment's points count, its value is nothing.
		local board = D:Scoreboard()
		assert.equal("Alice", board[1].player); assert.equal(7.55, board[1].points); assert.equal(25500, board[1].copper)
		assert.equal("Bob", board[2].player); assert.equal(10000, board[2].copper)
		-- Roll-off: with the cap at two, the two oldest credits (both Alice's) move their value to
		-- the opening value and the totals do not move.
		D.ENTRIES_MAX = 2
		D:Credit({ donor = "Carol", kind = "money", copper = 100 })
		assert.equal(2, #L.entries)
		assert.same({ Alice = 25500, Bob = 10000, Carol = 100 }, D:LedgerValues(L))
		assert.equal(25500, L.openingValue.Alice)
		assert.is_nil(L.openingValue.Bob, "a credit still in the log was rolled")
		assert.same({ Alice = 25500, Bob = 10000, Carol = 100 }, D:Values())
		-- The wire: values beside totals; a member sums the banker's values with nothing of its own;
		-- a pre-VALUE sender's bucket is valueless, never zero-valued.
		local payload, msg = lastPublished()
		assert.same({ Alice = 25500, Bob = 10000, Carol = 100 }, payload.values)
		local info = TOGBankClassic_Guild.Info
		becomeCharacter(PEER)
		info.donationLedger = nil
		deliver(msg, ME)
		assert.same({ Alice = 25500, Bob = 10000, Carol = 100 }, info.donationPoints[W].values)
		assert.equal(25500, D:ValueOf("Alice"))
		local v = info.donationPoints[W].version
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "donation-points", writer = W, version = v + 1, totals = { Alice = 9 } }) }, ME)
		assert.same({}, info.donationPoints[W].values)
		assert.equal(0, D:ValueOf("Alice"))
		assert.equal(9, D:PointsOf("Alice"))
		-- Inbound values are sanitized: negatives, junk and non-string donors drop; fractions floor.
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "donation-points", writer = W, version = v + 2, totals = { Alice = 9 }, values = { Alice = 123.9, Bob = -5, Dave = "x", [7] = 100 } }) }, ME)
		assert.same({ Alice = 123 }, info.donationPoints[W].values)
		-- The figure: gold to the copper, never rounded up.
		assert.equal("2g 55s", D:FormatGold(25500)); assert.equal("1g", D:FormatGold(10000))
		assert.equal("34s 5c", D:FormatGold(3405)); assert.equal("5c", D:FormatGold(5)); assert.equal("0c", D:FormatGold(0))
		D.ENTRIES_MAX = 300
	end)

	it("only a NEWER version from the SAME writer replaces a held bucket", function()
		local info = TOGBankClassic_Guild.Info
		becomeCharacter(PEER)
		local function bucket(version, totals, writer)
			return { prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "donation-points", writer = writer or ME, version = version, totals = totals }) }
		end
		deliver(bucket(10, { Alice = 1 }), ME)
		assert.same({ Alice = 1 }, info.donationPoints[ME].totals)
		deliver(bucket(9, { Alice = 50 }), ME)
		assert.same({ Alice = 1 }, info.donationPoints[ME].totals, "an older bucket replaced a newer one")
		deliver(bucket(10, { Alice = 50 }), ME)
		assert.same({ Alice = 1 }, info.donationPoints[ME].totals, "the same version replaced the held one")
		deliver(bucket(11, { Alice = 3 }), ME)
		assert.same({ Alice = 3 }, info.donationPoints[ME].totals)
		-- A relay naming ANOTHER writer is refused, whoever sends it.
		deliver(bucket(99, { Alice = 500 }, OFFICER), ME)
		assert.is_nil(info.donationPoints[OFFICER], "a banker spoke for the officer's bucket")
		-- A plain member's publication is refused.
		deliver(bucket(99, { Alice = 500 }, "Someone-Testrealm"), "Someone-Testrealm")
		assert.is_nil(info.donationPoints["Someone-Testrealm"])
		-- An officer's own is accepted.
		deliver(bucket(1, { Alice = -1 }, OFFICER), OFFICER)
		assert.same({ Alice = -1 }, info.donationPoints[OFFICER].totals)
		assert.equal(2, D:PointsOf("Alice"))
	end)

	it("a bucket for one of THIS account's own characters is never overwritten by the wire", function()
		local info = TOGBankClassic_Guild.Info
		D:Credit({ donor = "Alice", kind = "money", copper = 10000 })
		local L = info.donationLedger[W]
		-- Now on another of our characters, a stale copy of this machine's bucket arrives from a
		-- relay claiming to be ME -- the ledger we hold IS the source.
		becomeCharacter("Mysecond-Testrealm")
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "donation-points", writer = W, version = L.version + 100, totals = { Alice = 999 } }) }, ME)
		assert.is_nil(info.donationPoints, "our own writer's bucket was stored from the wire")
		assert.equal(1, D:PointsOf("Alice"))
	end)

	-- LEDGER-PC-001 (Peer Review f5e52bcf F2): the operator's banker is a SHARED ACCOUNT on several
	-- PCs. Keyed by the character alone, PC2's first publish replaced PC1's bucket on every client
	-- and PC1's credits vanished from every board. Each PC is its own writer now.
	it("two PCs on one banker account are two writers: a member holds both buckets and sums them; neither PC's publish erases the other's", function()
		local info = TOGBankClassic_Guild.Info
		-- PC1 credits Alice 3 and publishes.
		D:Credit({ donor = "Alice", kind = "money", copper = 30000 })
		local _, fromPC1 = lastPublished()
		-- PC2, the same character on another machine, days later: an empty ledger there, Bob 0.5.
		TOGBankClassic_Database.db.global.donationMachineID = "pc2"
		info.donationLedger = {}
		env.now = env.now + 86400
		D:Credit({ donor = "Bob", kind = "money", copper = 5000 })
		local pc2Payload, fromPC2 = lastPublished()
		assert.equal(ME .. "@pc2", pc2Payload.writer)
		-- A member hears PC1 first, then PC2: both kept, Alice's 3 not erased by PC2's newer bucket.
		becomeCharacter(PEER)
		info.donationLedger = nil
		deliver(fromPC1, ME)
		deliver(fromPC2, ME)
		assert.same({ Alice = 3 }, info.donationPoints[W].totals)
		assert.same({ Bob = 0.5 }, info.donationPoints[ME .. "@pc2"].totals)
		assert.equal(3, D:PointsOf("Alice")); assert.equal(0.5, D:PointsOf("Bob"))
		-- Back on PC1 (its own ledger under W): PC2's bucket for the SAME character is not "ours" --
		-- Receive's rule, driven directly: the dispatch drops a message from oneself, and in game the
		-- same account is never online twice, so no wire carries this (KNOWN COST: a PC's board lacks
		-- the other PCs' credits for its own character).
		becomeCharacter(ME)
		TOGBankClassic_Database.db.global.donationMachineID = "pc1"
		info.donationPoints = nil
		info.donationLedger = { [W] = { opening = { Alice = 3 }, entries = {}, version = 1 } }
		assert.is_true(D:Receive(ME, pc2Payload))
		assert.same({ Bob = 0.5 }, info.donationPoints[ME .. "@pc2"].totals, "another machine's bucket for our own character was refused")
		assert.equal(3, D:PointsOf("Alice")); assert.equal(0.5, D:PointsOf("Bob"))
		-- A writer key whose CHARACTER is not the sender is still refused, machine or no machine.
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "donation-points", writer = OFFICER .. "@pc9", version = 99, totals = { Alice = 500 } }) }, ME)
		assert.is_nil(info.donationPoints[OFFICER .. "@pc9"])
		-- A ledger this PC wrote under the bare character key (the build before the machine id)
		-- moves under this machine's writer key, once, and the old key is gone.
		info.donationLedger = { [ME] = { opening = { Carol = 7 }, entries = {}, version = 1 } }
		D:Credit({ donor = "Alice", kind = "money", copper = 10000 })
		assert.is_nil(info.donationLedger[ME], "the bare-keyed ledger was left behind")
		assert.equal(7, info.donationLedger[W].opening.Carol)
		assert.equal(8, D:PointsOf("Alice") + D:PointsOf("Carol") - 0)
		TOGBankClassic_Database.db.global.donationMachineID = "pc1"
	end)

	it("inbound totals are sanitized: string donors, finite numbers, two decimals, capped", function()
		local info = TOGBankClassic_Guild.Info
		becomeCharacter(PEER)
		local junk = { Alice = 1.23456, [7] = 9, Bob = "x", Carl = math.huge, Dee = -2 }
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "donation-points", writer = ME, version = 1, totals = junk }) }, ME)
		assert.same({ Alice = 1.23, Dee = -2 }, info.donationPoints[ME].totals)
		local many = {}
		for i = 1, 600 do many["Donor" .. i] = i end
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "donation-points", writer = ME, version = 2, totals = many }) }, ME)
		local n = 0
		for _ in pairs(info.donationPoints[ME].totals) do n = n + 1 end
		assert.equal(D.DONORS_MAX, n)
		-- Not a table at all: stored empty, never an error.
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "donation-points", writer = ME, version = 3, totals = "none" }) }, ME)
		assert.same({}, info.donationPoints[ME].totals)
	end)

	it("the rate travels with the guild settings: the ONE writer, bounds, an old client leaves it alone", function()
		TOGBankClassic_Guild.SenderIsOfficer = function(_, n) return n == ME or n == OFFICER end		assert.is_false(TOGBankClassic_Guild:SetDonationRate(0))
		assert.is_false(TOGBankClassic_Guild:SetDonationRate("x"))
		assert.is_false(TOGBankClassic_Guild:SetDonationRate(5000))
		assert.is_true(TOGBankClassic_Guild:SetDonationRate(2.5))
		assert.equal(2.5, D:Rate())
		assert.is_false(TOGBankClassic_Guild:SetDonationRate(2.5), "no change was reported as one")
		assert.equal(2.5, lastSettings().donationRate)
		-- A peer applies it, refuses garbage, and keeps it when an old client's broadcast omits it.
		becomeCharacter(PEER)
		TOGBankClassic_Guild.Info.settings = {}
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { donationRate = 2.5 } }) }, ME)
		assert.equal(2.5, D:Rate())
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { donationRate = -1 } }) }, ME)
		assert.equal(2.5, D:Rate())
		deliver({ prefix = "togbank-hl", body = TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = { maxRequestPercent = 100 } }) }, ME)
		assert.equal(2.5, D:Rate(), "an old client's broadcast reset the rate")
		-- The default is sent as a real number, so "1" and "absent" differ on the wire.
		becomeCharacter(ME)
		TOGBankClassic_Guild.Info.settings = {}
		TOGBankClassic_Guild:BroadcastSettings()
		assert.equal(1, lastSettings().donationRate)
	end)
end)

-- ─── Ingest: the real Mail:Open ────────────────────────────────────────────────

describe("STORE-007: a donation received at the mailbox is credited once, valued then", function()
	local timers
	--- Run every scheduled timer (the take-retry, the broadcast), in order, once.
	local function flush()
		local due = timers
		timers = {}
		for _, fn in ipairs(due) do fn() end
	end
	local function loadMail()
		env.loadModules({ "Modules/Mail.lua" })
		-- Mail:Open takes ONE thing and re-enters itself on a 1 s timer so the server can act in
		-- between. A timer that fires at once re-enters before the model has changed and recurses
		-- forever, so here the timers are captured and the example plays the server's part.
		timers = {}
		TOGBankClassic_Core.ScheduleTimer = function(_, fn) timers[#timers + 1] = fn end
		TOGBankClassic_Mail.Roster = { [ME] = true }
		TOGBankClassic_Mail.CheckForFulfilledRequest = function() return false end
		TOGBankClassic_Mail.ResetScan = function() end
		TOGBankClassic_UI_Mail = { ScoreMail = true, Close = function() end }
		TOGBankClassic_Bank = TOGBankClassic_Bank or {}
		TOGBankClassic_Bank.HasInventorySpace = function() return true end
		TOGBankClassic_Item.IsUnique = function() return false end
		-- The harness owns GetItemInfo; env_togbank only teaches it to take a link. `price` is this
		-- addon's fixture spelling of the harness's `sellPrice`, mapped by defineItem.
		env.defineItem(2589, { name = "Linen Cloth", price = 13 })
	end

	before_each(function() env.reset(); loadStack(); loadMail() end)

	it("money and one attachment: two entries, the item at the library's conservative price", function()
		stubPriceLibrary({ [2589] = { minBuyout = 25 } })
		wow.mail[1] = { sender = "Alice", subject = "gift", money = 30000, cod = 0, items = {
			{ name = "Linen Cloth", id = 2589, count = 20, link = "|cffffffff|Hitem:2589|h[Linen Cloth]|h|r" } } }
		TOGBankClassic_Mail:Open(1)          -- takes the money, schedules the retry for the item
		local L = TOGBankClassic_Guild.Info.donationLedger[W]
		assert.equal(1, #L.entries)
		local money = L.entries[1]
		assert.equal("money", money.kind); assert.equal(30000, money.copper); assert.equal(3, money.points)
		assert.equal("takeMoney", wow.mailActions[1].action)
		wow.mail[1].money = 0                -- the server acted on the take
		flush()                              -- the retry, and the broadcast the credit scheduled
		assert.equal(2, #L.entries, "the money was credited again on the retry, or the item was not")
		local item = L.entries[2]
		assert.equal("item", item.kind); assert.equal(2589, item.itemID); assert.equal("Linen Cloth", item.name)
		assert.equal(20, item.count); assert.equal(500, item.copper, "20 x 25c min buyout")
		assert.equal("minBuyout", item.statistic); assert.equal("own scan", item.source); assert.equal(60, item.age)
		assert.equal(0.05, item.points)
		assert.equal("take", wow.mailActions[#wow.mailActions].action)
		assert.equal(3.05, D:PointsOf("Alice"))
		assert.is_table(lastPublished(), "the credit did not publish")
		assert.same({ Alice = 3 }, lastPublished().totals, "the first broadcast went out before the retry")
		flush()                              -- the broadcast the item's credit scheduled
		assert.same({ Alice = 3.05 }, lastPublished().totals)
	end)

	it("a slow server: the retry sees the money still there, takes again, but credits it ONCE", function()
		wow.mail[1] = { sender = "Alice", subject = "gift", money = 30000, cod = 0, items = {
			{ name = "Linen Cloth", id = 2589, count = 20, link = "|cffffffff|Hitem:2589|h[Linen Cloth]|h|r" } } }
		TOGBankClassic_Mail:Open(1)
		flush()                              -- the retry, with the money NOT yet cleared
		local L = TOGBankClassic_Guild.Info.donationLedger[W]
		assert.equal(1, #L.entries, "the money was credited twice")
		assert.equal("takeMoney", wow.mailActions[2].action, "the retry did not take again (harmless, and what the client does)")
		-- A genuinely new gift of the same amount, outside the window, is a second credit.
		env.now = env.now + 11
		wow.mail[1].money = 0
		wow.mail[2] = { sender = "Alice", subject = "again", money = 30000, cod = 0 }
		TOGBankClassic_Mail:Open(2)
		assert.equal(2, #L.entries)
		assert.equal(6, D:PointsOf("Alice"))
	end)

	-- Peer Review f5e52bcf F4: the harness's TakeInboxItem only RECORDS the take and never removes the
	-- attachment -- the slow-server case exactly -- so a two-attachment mail is what drives the retry
	-- against a stack still in the mail.
	it("a slow server: the retry sees the FIRST attachment still there, takes again, but credits it ONCE; the second attachment is its own credit", function()
		stubPriceLibrary({ [2589] = { minBuyout = 25 } })
		local link = "|cffffffff|Hitem:2589|h[Linen Cloth]|h|r"
		wow.mail[1] = { sender = "Alice", subject = "gift", money = 0, cod = 0, items = {
			{ name = "Linen Cloth", id = 2589, count = 20, link = link },
			{ name = "Linen Cloth", id = 2589, count = 20, link = link } } }
		TOGBankClassic_Mail:Open(1)          -- credits and takes slot 1, schedules the retry
		local L = TOGBankClassic_Guild.Info.donationLedger[W]
		assert.equal(1, #L.entries)
		flush()                              -- the retry: slot 1 is still in the mail
		flush()                              -- and again
		assert.equal(1, #L.entries, "the first attachment was credited more than once across the retries")
		assert.equal(3, #wow.mailActions, "the retries did not take again (harmless, and what the client does)")
		for _, a in ipairs(wow.mailActions) do assert.equal(1, a.attachment) end
		-- The server acts: slot 1 goes; the next retry credits slot 2 -- the same link and count,
		-- a different slot, so it is a second stack and a second entry.
		wow.mail[1].items[1] = nil
		flush()
		assert.equal(2, #L.entries, "the second attachment was not credited")
		assert.equal(0.1, D:PointsOf("Alice"), "2 x 20 x 25c at 1 point per gold")
	end)

	it("with no library the item is credited at what a vendor pays", function()
		wow.mail[1] = { sender = "Alice", subject = "gift", money = 0, cod = 0, items = {
			{ name = "Linen Cloth", id = 2589, count = 20, link = "|cffffffff|Hitem:2589|h[Linen Cloth]|h|r" } } }
		TOGBankClassic_Mail:Open(1)
		local e = D:Entries()[1]
		assert.equal(260, e.copper); assert.equal("vendor", e.source); assert.equal(0.03, e.points)
		assert.equal(1, #D:Entries())
	end)

	it("'Add to score' unticked, mail from another bank character, or a returned mail, credits nothing", function()
		wow.mail[1] = { sender = "Alice", subject = "gift", money = 10000, cod = 0 }
		TOGBankClassic_UI_Mail.ScoreMail = false
		TOGBankClassic_Mail:Open(1)
		assert.is_nil(TOGBankClassic_Guild.Info.donationLedger)
		assert.equal("takeMoney", wow.mailActions[1].action, "the money was not taken")
		TOGBankClassic_UI_Mail.ScoreMail = true
		-- The inbox header spells a same-realm sender BARE. This example used to hand Open the
		-- normalised "Bankchar-Testrealm", which the client never sends, and the shipped check
		-- compared the bare name against a Name-Realm set -- so in game a banker's transfer WAS
		-- credited. IsDonation normalises first; the bare spelling is the one that must refuse.
		TOGBankClassic_Guild.IsBank = function(_, n) return n == ME or n == "Otherbanker-Testrealm" end
		wow.mail[2] = { sender = "Otherbanker", subject = "transfer", money = 10000, cod = 0 }
		TOGBankClassic_Mail:Open(2)
		assert.is_nil(TOGBankClassic_Guild.Info.donationLedger, "a transfer from another bank character was credited as a donation")
		-- A mail of ours that bounced back is not a gift.
		wow.mail[3] = { sender = "Alice", subject = "returned", money = 10000, cod = 0, wasReturned = true }
		TOGBankClassic_Mail:Open(3)
		assert.is_nil(TOGBankClassic_Guild.Info.donationLedger, "a returned mail was credited")
		-- And not on a character that is not a bank character at all.
		TOGBankClassic_Guild.IsBank = function() return false end
		assert.is_false(TOGBankClassic_Mail:IsDonation("Alice", false, true))
	end)

	-- UX-WATERFALL-001 (crimsonmane, 2026-09-14: "we see the original plus the new window pops up.
	-- the two windows are two separate settings"). The Mailbox window is the mailbox for a banker,
	-- and until this its takes earned NO points -- the credit lived only in the popup's Open. Both
	-- takers now go through Mail:IsDonation / CreditMoney / CreditItem, and the popup's Scan stands
	-- aside while the Mailbox window auto-opens.
	it("the Mailbox window's take credits a donation exactly as the popup's Open does, and the popup stands aside for it", function()
		env.loadModules({ "Modules/UI/Mailbox.lua" })
		local Mailbox = TOGBankClassic_UI_Mailbox
		Mailbox.taking = nil
		stubPriceLibrary({ [2589] = { minBuyout = 25 } })
		wow.mail[1] = { sender = "Alice", subject = "gift", money = 30000, cod = 0, items = {
			{ name = "Linen Cloth", id = 2589, count = 20, link = "|cffffffff|Hitem:2589|h[Linen Cloth]|h|r" } } }
		local rows = Mailbox:BuildRows()
		assert.equal(2, #rows)
		assert.is_false(rows[1].wasReturned)
		-- The attachment, then the money, each through TakeRow.
		assert.is_true(Mailbox:TakeRow(rows[1]))
		assert.is_true(Mailbox:TakeRow(rows[2]))
		local L = TOGBankClassic_Guild.Info.donationLedger[W]
		assert.equal(2, #L.entries, "the Mailbox window's takes did not credit")
		assert.equal("item", L.entries[1].kind); assert.equal(2589, L.entries[1].itemID); assert.equal(20, L.entries[1].count)
		assert.equal(500, L.entries[1].copper, "20 x 25c min buyout"); assert.equal("minBuyout", L.entries[1].statistic)
		assert.equal("money", L.entries[2].kind); assert.equal(30000, L.entries[2].copper)
		assert.equal(3.05, D:PointsOf("Alice"))
		assert.equal("take", wow.mailActions[1].action); assert.equal("takeMoney", wow.mailActions[2].action)
		-- A COD row is refused before anything is credited; a returned mail is taken but not credited;
		-- a transfer from another bank character is taken but not credited.
		wow.mail[2] = { sender = "Bob", subject = "cod", money = 0, cod = 500, items = { { name = "Linen Cloth", id = 2589, count = 1, link = "|cffffffff|Hitem:2589|h[Linen Cloth]|h|r" } } }
		wow.mail[3] = { sender = "Bob", subject = "back", money = 100, cod = 0, wasReturned = true }
		TOGBankClassic_Guild.IsBank = function(_, n) return n == ME or n == "Otherbanker-Testrealm" end
		wow.mail[4] = { sender = "Otherbanker", subject = "transfer", money = 100, cod = 0 }
		rows = Mailbox:BuildRows()
		assert.is_false((Mailbox:TakeRow(rows[3])))
		assert.is_true(rows[4].wasReturned)
		assert.is_true(Mailbox:TakeRow(rows[4]))
		assert.is_true(Mailbox:TakeRow(rows[5]))
		assert.equal(2, #L.entries, "a COD, returned or banker-to-banker take was credited")
		-- The popup's Scan stands aside while the Mailbox window auto-opens, and runs when it does not.
		local opened = 0
		TOGBankClassic_UI_Mail.SetMailId = function() end
		TOGBankClassic_UI_Mail.Open = function() opened = opened + 1 end
		TOGBankClassic_Mail.isOpen = true
		TOGBankClassic_Mail.isScanning = false
		TOGBankClassic_Options.GetBankReporting = function() return false end
		wow.mail[5] = { sender = "Carol", subject = "gift", money = 100, cod = 0 }
		Mailbox.AutoOpens = function() return true end
		TOGBankClassic_Mail:Scan()
		assert.equal(0, opened, "the Donation popup opened beside an auto-opening Mailbox window")
		Mailbox.AutoOpens = function() return false, "off" end
		TOGBankClassic_Mail:Scan()
		assert.equal(1, opened, "with the Mailbox window's auto-open off, the popup did not return")
		-- The retired setting is read by nothing: no Options accessor for it remains.
		assert.is_nil(TOGBankClassic_Options.GetDonationEnabled)
		assert.is_nil(env.readFile("Modules/Options.lua"):find('["donations"] = {', 1, true), "the 'Enable donations' box is back")
	end)

	-- Audit a228508b F3: every example above stubs IsUnique false, so nothing drove a take through the
	-- REAL IsUnique reading the REAL scanning tooltip (harness pin 830dab2). A unique item is what a
	-- bank cannot hold two of, and it must not be credited; a plain stack must. Rich frames, because
	-- IsUnique's tooltip is one it creates itself and a hollow NumLines() is nil.
	it("the Mailbox window's take credits a stackable gift and refuses a UNIQUE one, through the real IsUnique on the real scanning tooltip", function()
		env.reset({ frames = true }); loadStack(); loadMail()
		env.loadFile("Modules/Item.lua")   -- loadMail stubbed IsUnique on the module; the real one back
		env.loadModules({ "Modules/UI/Mailbox.lua" })
		local Mailbox = TOGBankClassic_UI_Mailbox
		Mailbox.taking = nil
		env.defineItem(2589, { name = "Linen Cloth", price = 13, tooltipLines = { "Linen Cloth", "Sell Price: 13c" } })
		env.defineItem(6948, { name = "Hearthstone", price = 0, tooltipLines = { "Hearthstone", ITEM_UNIQUE, "Binds when picked up" } })
		stubPriceLibrary({ [2589] = { minBuyout = 25 }, [6948] = { minBuyout = 100000 } })
		wow.mail[1] = { sender = "Alice", subject = "gift", money = 0, cod = 0, items = {
			{ name = "Hearthstone", id = 6948, count = 1, link = "|cffffffff|Hitem:6948|h[Hearthstone]|h|r" },
			{ name = "Linen Cloth", id = 2589, count = 20, link = "|cffffffff|Hitem:2589|h[Linen Cloth]|h|r" } } }
		local rows = Mailbox:BuildRows()
		assert.equal(2, #rows)
		assert.is_true(Mailbox:TakeRow(rows[1]))   -- the unique item: taken, not credited
		assert.is_true(Mailbox:TakeRow(rows[2]))   -- the stack: taken and credited
		assert.equal(2, #wow.mailActions, "both takes reached the client")
		local L = TOGBankClassic_Guild.Info.donationLedger[W]
		assert.equal(1, #L.entries, "the unique item was credited, or the stack was not")
		assert.equal(2589, L.entries[1].itemID); assert.equal(500, L.entries[1].copper)
		assert.equal(0.05, D:PointsOf("Alice"))
		-- It was the tooltip that decided: the same Hearthstone with no Unique line IS credited.
		env.defineItem(6948, { name = "Hearthstone", price = 0, tooltipLines = { "Hearthstone", "Binds when picked up" } })
		env.now = env.now + 11
		wow.mail[2] = { sender = "Alice", subject = "again", money = 0, cod = 0, items = {
			{ name = "Hearthstone", id = 6948, count = 1, link = "|cffffffff|Hitem:6948|h[Hearthstone]|h|r" } } }
		local again
		for _, r in ipairs(Mailbox:BuildRows()) do if r.mailIndex == 2 then again = r end end
		assert.is_not_nil(again, "no row for the second mail")
		assert.is_true(Mailbox:TakeRow(again))
		assert.equal(2, #L.entries, "the same item without the Unique line was refused -- the scan is not what decided")
		assert.equal(6948, L.entries[2].itemID)
	end)
end)

-- ─── The command ───────────────────────────────────────────────────────────────

describe("STORE-007: /togbank donations", function()
	before_each(function() env.reset(); loadStack() end)

	it("the board, one member, the log, and an officer's adjustment", function()
		TOGBankClassic_Chat:DonationsCommand(nil, nil)
		assert.truthy(responses()[1]:find("No donation points", 1, true))
		D:Credit({ donor = "Alice", kind = "item", itemID = 2589, name = "Linen Cloth", count = 20, copper = 30000, source = "own scan", statistic = "minBuyout" })
		D:Credit({ donor = "Bob", kind = "money", copper = 10000 })
		clearOutput()
		TOGBankClassic_Chat:DonationsCommand(nil, nil)
		local r = responses()
		assert.truthy(r[1]:find("1 point per gold", 1, true))
		assert.truthy(r[2]:find("Alice -- 3 points (3g given)", 1, true), r[2])   -- DONATION-VALUE-001
		assert.truthy(r[3]:find("Bob -- 1 point (1g given)", 1, true), r[3])
		assert.truthy(r[4]:find("You have 0 points.", 1, true), r[4])
		clearOutput()
		TOGBankClassic_Chat:DonationsCommand("Alice", nil)
		assert.truthy(responses()[1]:find("Alice has 3 points", 1, true))
		clearOutput()
		TOGBankClassic_Chat:DonationsCommand("log", nil)
		r = responses()
		assert.truthy(r[1]:find("newest first (2)", 1, true))
		assert.truthy(r[2]:find("Bob  +1 point  1 gold", 1, true))
		assert.truthy(r[3]:find("20x Linen Cloth (own scan, minBuyout)", 1, true))
		clearOutput()
		TOGBankClassic_Chat:DonationsCommand("log", "Nobody")
		assert.truthy(responses()[1]:find("No entries for Nobody", 1, true))
		-- Adjust: refused for a member, done for an officer, and the log shows the reason.
		clearOutput()
		TOGBankClassic_Chat:DonationsCommand("adjust", "Alice -1 mailed the wrong stack")
		assert.truthy(responses()[1]:find("Only an officer", 1, true))
		_G.CanViewOfficerNote = function() return true end
		clearOutput()
		TOGBankClassic_Chat:DonationsCommand("adjust", "Alice -1 mailed the wrong stack")
		assert.truthy(responses()[1]:find("Alice: -1 point -- mailed the wrong stack (now 2 points)", 1, true), responses()[1])
		clearOutput()
		TOGBankClassic_Chat:DonationsCommand("adjust", "Alice")
		assert.truthy(responses()[1]:find("Usage:", 1, true))
		clearOutput()
		TOGBankClassic_Chat:DonationsCommand("adjust", "Alice 5")
		assert.truthy(responses()[1]:find("reason", 1, true))
		clearOutput()
		TOGBankClassic_Chat:DonationsCommand("log", "Alice")
		assert.truthy(responses()[2]:find("adjustment: mailed the wrong stack", 1, true))
	end)

	it("without a guild it says so", function()
		TOGBankClassic_Guild.Info = nil
		TOGBankClassic_Chat:DonationsCommand(nil, nil)
		assert.truthy(responses()[1]:find("Not in a guild", 1, true))
	end)

	-- The Donations window's button was removed from the old Inventory window on 2025-12-22 and
	-- nothing opened it since. This is the way in, and this example is what says so.
	it("'window' is the Donations window's one entry point", function()
		local toggled = 0
		TOGBankClassic_UI_Donations = { Toggle = function() toggled = toggled + 1 end }
		TOGBankClassic_Chat:DonationsCommand("window", nil)
		assert.equal(1, toggled)
		TOGBankClassic_UI_Donations = nil
		TOGBankClassic_Chat:DonationsCommand("window", nil)   -- before the UI has loaded: nothing, no error
		-- And nothing else in the shipped modules opens it (the guard that found it dead).
		-- The file that DEFINES Toggle and Open is skipped: a definition reads like a call.
		local sites = 0
		for _, path in ipairs(env.shippedModules()) do
			if path ~= "Modules/UI/Donations.lua" then
				local src = env.readFile(path)
				for _ in src:gmatch("TOGBankClassic_UI_Donations:Toggle%(") do sites = sites + 1 end
				for _ in src:gmatch("TOGBankClassic_UI_Donations:Open%(") do sites = sites + 1 end
			end
		end
		assert.equal(1, sites, "the Donations window gained or lost an entry point -- update the README and this example")
	end)
end)
