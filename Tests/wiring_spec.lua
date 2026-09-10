-- INV2 wiring — the seams where the V2 store is fed from live code.
--
-- Record/Resolve/Store/Scan/Wire are covered by their own specs in isolation. What is NOT covered
-- there is the part that can actually hurt a player: the V2 mirror runs inside Bank:Scan, the
-- hottest path in the addon and the source of every number it shows. The contract this file
-- exists to hold is narrow and absolute:
--
--   the legacy scan must produce byte-identical results whether V2 is on, off, or broken.
--
-- Anything less and the switch is not a switch, it is a second way to lose data.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local GUILD = "Testguild"
local ME    = "Bankchar-Testrealm"

local function readFile(path)
	local fh = assert(io.open(path, "rb"), "cannot read " .. path)
	local src = fh:read("*a")
	fh:close()
	return src
end

--- Load Bank plus the INV2 chain and stand up the collaborators Bank:Scan reaches for.
local function loadWiring()
	env.stubOutput()
	env.loadFile("Modules/Item.lua")
	env.loadFile("Modules/Bank.lua")
	env.loadFile("Modules/Constants.lua")
	env.loadFile("Modules/Switches.lua")
	env.loadFile("Modules/Inventory/Record.lua")
	env.loadFile("Modules/Inventory/Resolve.lua")
	env.loadFile("Modules/Inventory/Store.lua")
	env.loadFile("Modules/Inventory/Scan.lua")

	TOGBankClassic_Guild = {
		Info = { name = GUILD, alts = {} },
		GetNormalizedPlayer = function() return ME end,
		NormalizeName = function(_, n) return n and (n:find("-") and n or n .. "-Testrealm") or nil end,
		GetBanks = function() return { ME } end,
	}
	TOGBankClassic_Options       = { GetBankEnabled = function() return true end }
	TOGBankClassic_Database      = { SaveSnapshot = function() return true end, db = { global = {} } }
	TOGBankClassic_MailInventory = { hasUpdated = false }
	TOGBankClassic_Core          = env.coreHashStub(12345)

	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	TOGBankClassic_Bank.hasUpdated = true
	TOGBankClassic_Bank.eventsRegistered = false
	return TOGBankClassic_Bank
end

local function setSwitch(name, on)
	TOGBankClassic_Database.db.global.switches = TOGBankClassic_Database.db.global.switches or {}
	TOGBankClassic_Database.db.global.switches[name] = on
end

describe("Bank:Scan INV2 mirror", function()
	local Bank

	before_each(function()
		env.reset()
		Bank = loadWiring()
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 858, count = 5 } })
	end)

	-- The switch is turned off EXPLICITLY. INV2 step 9 made it default on, and this example is about
	-- whether the switch gates the mirror -- not about which way it points out of the box.
	it("leaves the V2 store untouched while the switch is off", function()
		setSwitch("inventoryV2", false)
		Bank:Scan()
		assert.is_false(TOGBankClassic_Inventory_Store:HasAlt(GUILD, ME),
			"the V2 store was written with inventoryV2 off — the switch does not actually gate it")
	end)

	it("writes the V2 store when the switch is on", function()
		setSwitch("inventoryV2", true)
		Bank:Scan()
		local records = TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME)
		assert.equal(1, #records)
		assert.equal(858, TOGBankClassic_Inventory_Record.id(records[1]))
		assert.equal(5, TOGBankClassic_Inventory_Record.count(records[1]))
	end)

	-- INV2-MAIL-001, from a live report on 2026-09-08 and reproduced from both sides of it.
	--
	-- A banker held 68 Black Diamond in bags and 3 in mail. On the BANKER (V2 populated) the
	-- tooltip read 68; on a NON-banker (V2 empty for that alt, so GetAltItems falls back to the
	-- legacy record) the same line read 71. One line of code, two numbers, because the V2 store is
	-- built from Scan:ScanAll -- which walks bags and bank and has no mail in it at all -- while
	-- the legacy aggregate is bank + bags + MAIL.
	--
	-- This is not a display bug and it cannot be fixed at read time for long: step 10 deletes the
	-- legacy path, so a V2 store that structurally cannot hold mail blocks steps 9 and 10 forever.
	it("mirrors mail into the V2 store, not just bags and bank", function()
		setSwitch("inventoryV2", true)
		env.defineItem(11754, { name = "Black Diamond", class = 7 })
		env.setBag(0, 4, { { id = 11754, count = 68 } })
		-- What MailInventory produces: an array of linkless {ID, Count}, already scanned into the
		-- alt record by the time the mirror runs.
		TOGBankClassic_MailInventory.hasUpdated = true
		TOGBankClassic_MailInventory.ScanMailInventory = function()
			return { items = { { ID = 11754, Count = 3 } }, version = 1, lastScan = 0 }
		end

		Bank:Scan()

		local total = 0
		for _, rec in ipairs(TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME)) do
			if TOGBankClassic_Inventory_Record.id(rec) == 11754 then
				total = total + TOGBankClassic_Inventory_Record.count(rec)
			end
		end
		assert.equal(71, total,
			"the V2 store holds only the 68 in bags. Mail is a first-class source in the legacy " ..
			"aggregate, so with inventoryV2 on a banker's mail silently stops being counted -- " ..
			"and the same tooltip shows a DIFFERENT number on a non-banker, where the legacy " ..
			"fallback still runs (INV2-MAIL-001)")
	end)

	it("records money alongside the tuples", function()
		setSwitch("inventoryV2", true)
		env.money = 987654
		Bank:Scan()
		assert.equal(987654, TOGBankClassic_Inventory_Store:GetAltMoney(GUILD, ME))
	end)

	-- The whole point of running the mirror inside the legacy scan rather than replacing it.
	it("produces the same legacy result with the switch on as with it off", function()
		Bank:Scan()
		local without = TOGBankClassic_Guild.Info.alts[ME]
		local snapshot = { count = #without.items, id = without.items[1].ID, n = without.items[1].Count }

		env.reset()
		Bank = loadWiring()
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 858, count = 5 } })
		setSwitch("inventoryV2", true)
		Bank:Scan()
		local with = TOGBankClassic_Guild.Info.alts[ME]

		assert.equal(snapshot.count, #with.items)
		assert.equal(snapshot.id, with.items[1].ID)
		assert.equal(snapshot.n, with.items[1].Count)
	end)

	-- A fault in brand-new code must not take down the path every existing user depends on.
	it("still completes the legacy scan when the V2 mirror throws", function()
		setSwitch("inventoryV2", true)
		-- Stub the function the mirror ACTUALLY calls. This used to stub ScanAll, which the mirror
		-- stopped calling when INV2-VAULT-001 split the scan per source -- so nothing threw, the
		-- pcall trivially succeeded, and the spec passed while testing nothing.
		TOGBankClassic_Inventory_Scan.ScanBags = function() error("boom") end
		local ok = pcall(function() Bank:Scan() end)
		assert.is_true(ok, "a fault in the V2 mirror escaped and aborted Bank:Scan")
		local alt = TOGBankClassic_Guild.Info.alts[ME]
		assert.is_not_nil(alt, "the legacy scan produced nothing after the V2 mirror failed")
		assert.equal(5, alt.items[1].Count)
	end)

	-- Mirrors the legacy behaviour verified in bank_spec: away from a banker the vault slots read
	-- as empty, and writing that emptiness through would erase the character's whole vault from
	-- the guild's view.
	it("keeps previously stored records when the vault is out of reach", function()
		setSwitch("inventoryV2", true)
		env.setBag(-1, 4, { { id = 858, count = 40 } })
		Bank:Scan()
		assert.equal(45, TOGBankClassic_Inventory_Record.count(
			TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME)[1]))

		env.bags[-1] = nil  -- walked away from the banker
		Bank:Scan()
		assert.equal(45, TOGBankClassic_Inventory_Record.count(
			TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME)[1]),
			"the bank-less rescan overwrote the stored vault contents with bags only")
	end)

	it("does replace the stored records once the vault is reachable again", function()
		setSwitch("inventoryV2", true)
		env.setBag(-1, 4, { { id = 858, count = 40 } })
		Bank:Scan()
		env.setBag(-1, 4, { { id = 858, count = 10 } })
		Bank:Scan()
		assert.equal(15, TOGBankClassic_Inventory_Record.count(
			TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME)[1]),
			"a reachable vault did not update the stored record")
	end)

	-- INV2-VAULT-001. The two specs above prove the vault survives a bank-less rescan. They do NOT
	-- prove anything else does, and it did not: the old mirror protected the vault by skipping the
	-- WHOLE write, so bags and mail were frozen too. That is the live defect the operator saw --
	-- 68 on the banker, 71 on a non-banker -- surviving the INV2-MAIL-001 fix, because a mailbox is
	-- almost never opened while standing at a bank NPC.
	it("takes mail scanned away from a banker WITHOUT losing the stored vault", function()
		setSwitch("inventoryV2", true)
		env.defineItem(11754, { name = "Black Diamond", class = 7 })

		-- At the banker: 40 in the vault, 68 in bags, no mail.
		env.setBag(-1, 4, { { id = 11754, count = 40 } })
		env.setBag(0, 4, { { id = 11754, count = 68 } })
		Bank:Scan()

		-- Walk away, then open the mailbox and find 3 more.
		env.bags[-1] = nil
		TOGBankClassic_MailInventory.hasUpdated = true
		TOGBankClassic_MailInventory.ScanMailInventory = function()
			return { items = { { ID = 11754, Count = 3 } }, version = 1, lastScan = 0 }
		end
		Bank:Scan()

		local total = 0
		for _, rec in ipairs(TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME)) do
			if TOGBankClassic_Inventory_Record.id(rec) == 11754 then
				total = total + TOGBankClassic_Inventory_Record.count(rec)
			end
		end
		assert.equal(111, total,
			"expected vault 40 + bags 68 + mail 3. Short by 3 means the bank-less rescan was " ..
			"skipped wholesale to protect the vault, so mail never reached V2 and the banker's " ..
			"own tooltip keeps showing the pre-mail number. Short by 40 means the opposite -- " ..
			"the vault was overwritten by a scan that could not see it")
	end)

	it("clears the mail source when the mailbox is emptied", function()
		setSwitch("inventoryV2", true)
		env.defineItem(11754, { name = "Black Diamond", class = 7 })
		env.setBag(0, 4, { { id = 11754, count = 68 } })

		TOGBankClassic_MailInventory.hasUpdated = true
		TOGBankClassic_MailInventory.ScanMailInventory = function()
			return { items = { { ID = 11754, Count = 3 } }, version = 1, lastScan = 0 }
		end
		Bank:Scan()

		-- Collected the attachment. An empty mail source must REPLACE the old one, not be treated
		-- as "no information" and carried forward -- otherwise the count only ever grows.
		TOGBankClassic_MailInventory.hasUpdated = true
		TOGBankClassic_MailInventory.ScanMailInventory = function()
			return { items = {}, version = 1, lastScan = 0 }
		end
		Bank:Scan()

		local total = 0
		for _, rec in ipairs(TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME)) do
			if TOGBankClassic_Inventory_Record.id(rec) == 11754 then
				total = total + TOGBankClassic_Inventory_Record.count(rec)
			end
		end
		assert.equal(68, total,
			"an emptied mailbox left its 3 counted. Absent means 'keep what is stored' and empty " ..
			"means 'this source is now empty' -- conflating them makes mail a ratchet")
	end)

	-- The gates are checked before the mirror runs, so a non-banker never accumulates V2 data.
	it("does not mirror for a character that fails the banker gate", function()
		setSwitch("inventoryV2", true)
		TOGBankClassic_Guild.GetBanks = function() return { "SomeoneElse-Testrealm" } end
		Bank:Scan()
		assert.is_false(TOGBankClassic_Inventory_Store:HasAlt(GUILD, ME))
	end)
end)

describe("Store lifecycle", function()
	before_each(function() env.reset() end)

	-- Init is unconditional in Core so that flipping the switch mid-session starts collecting
	-- without a reload. If it were behind the switch, the first scan after enabling would find no
	-- db and silently drop everything.
	it("is initialised by Core regardless of the switch state", function()
		local core = readFile("Core.lua")
		local init = core:match("function TOGBankClassic_Core:OnInitialize%(%)(.-)\nend")
		assert.is_not_nil(init, "could not locate Core:OnInitialize")
		assert.is_not_nil(init:find("TOGBankClassic_Inventory_Store:Init", 1, true),
			"Core:OnInitialize never attaches the V2 SavedVariable, so the first scan has nowhere " ..
			"to write")
		assert.is_nil(init:match("IsEnabled%([\"']inventoryV2[\"']%)[^\n]*\n[^\n]*Inventory_Store:Init"),
			"Store:Init is gated on the switch — enabling V2 mid-session would then need a reload")
	end)

	it("creates the SavedVariable when none is supplied", function()
		env.loadFile("Modules/Inventory/Record.lua")
		env.loadFile("Modules/Inventory/Resolve.lua")
		env.loadFile("Modules/Inventory/Store.lua")
		_G.TOGBankClassicInvDB = nil
		local db = TOGBankClassic_Inventory_Store:Init()
		assert.is_table(db.faction)
		assert.equal(db, _G.TOGBankClassicInvDB)
	end)
end)

describe("INV2 dev commands", function()
	before_each(function() env.reset() end)

	-- Registration is what makes them reachable; the dispatcher only sees names in both tables.
	it("registers switches and compare as dev subcommands", function()
		local chat = readFile("Modules/Chat.lua")
		for _, name in ipairs({ "switches", "compare" }) do
			assert.is_not_nil(chat:match("name%s*=%s*[\"']" .. name .. "[\"']"),
				name .. " has no COMMAND_REGISTRY entry")
			assert.is_not_nil(chat:match("\n\t" .. name .. "%s+=%s*true"),
				name .. " is missing from DEV_COMMAND_NAMES, so /togbank dev " .. name ..
				" reports an unknown subcommand")
		end
	end)

	-- Set() returns false for an unknown name AND for a db that is not attached yet. Collapsing
	-- the two sends someone hunting for a typo that is not there.
	it("distinguishes an unknown switch from an unready database", function()
		local chat = readFile("Modules/Chat.lua")
		local handler = chat:match("name%s*=%s*\"switches\".-\n%s*%},")
		assert.is_not_nil(handler, "could not locate the switches handler")
		assert.is_not_nil(handler:find("registry[name]", 1, true),
			"the switches handler reports every Set() failure as an unknown switch")
	end)

end)

-- compare is the only thing that will ever prove, on live data, that the two encodings agree.
-- A diagnostic that reports agreement it did not actually check is worse than no diagnostic:
-- it is what a switch flip to V2-by-default would be justified by. So it gets exercised, not
-- grepped.
describe("/togbank dev compare", function()
	local function loadChat()
		env.stubOutput()
		env.loadFile("Modules/Item.lua")
		env.loadFile("Modules/Bank.lua")
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/Switches.lua")
		env.loadFile("Modules/Inventory/Record.lua")
		env.loadFile("Modules/Inventory/Resolve.lua")
		env.loadFile("Modules/Inventory/Store.lua")
		env.loadFile("Modules/Inventory/Scan.lua")
		env.loadFile("Modules/Chat.lua")

		TOGBankClassic_Guild    = { Info = { name = GUILD, alts = {} } }
		TOGBankClassic_Database = { db = { global = {} } }
		-- CMD-001: this used to hand-roll GetArgs as `(prefix, remainder)`. AceConsole TOKENIZES
		-- and returns `arg1, ..., argN, nextposition`, so the fake implemented a LOOSER contract
		-- than the library -- and ChatCommand, which discarded the remainder, passed against it
		-- while every `/togbank dev <sub> <args>` lost its arguments in game. env.stubCore is the
		-- faithful one; do not replace it with a convenient local.
		env.stubCore()
		TOGBankClassic_Inventory_Store:Init({ faction = {} })
		return TOGBankClassic_Chat
	end

	--- Every line the command emitted, joined — the assertions care about what it concluded.
	-- The stub Output records (format, ...) unformatted, so a spec that just concatenated the
	-- pieces would never see "Compared 1 character" — only "Compared %d character(s)" and a
	-- lone 1. Format here so the assertions read the line a player would actually see.
	local function output()
		local parts = {}
		for _, call in ipairs(TOGBankClassic_Output.calls) do
			local args = {}
			for i = 1, call.n do args[i] = call[i] end
			local ok, line = pcall(string.format, unpack(args, 1, call.n))
			if not ok then
				-- Not a format string, or mismatched args. Fall back to the raw pieces rather
				-- than letting the helper itself error and take the assertion down with it.
				line = {}
				for i = 1, call.n do line[i] = tostring(args[i]) end
				line = table.concat(line, " ")
			end
			parts[#parts + 1] = line
		end
		return table.concat(parts, "\n")
	end

	--- Put one item into both stores for `alt`, at the counts given.
	local function seed(alt, itemID, legacyCount, v2Count)
		TOGBankClassic_Guild.Info.alts[alt] = { items = { { ID = itemID, Count = legacyCount } } }
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, alt,
			{ TOGBankClassic_Inventory_Record.new(itemID, v2Count) }, 0)
	end

	before_each(function()
		env.reset()
		loadChat()
		setSwitch("inventoryV2", true)
	end)

	it("reports agreement when the two stores hold the same totals", function()
		seed(ME, 858, 5, 5)
		TOGBankClassic_Chat:ChatCommand("dev compare")
		assert.is_not_nil(output():find("No divergence", 1, true), "expected agreement, got:\n" .. output())
	end)

	it("reports a divergence when the counts differ", function()
		seed(ME, 858, 5, 4)
		TOGBankClassic_Chat:ChatCommand("dev compare")
		local out = output()
		assert.is_nil(out:find("No divergence", 1, true),
			"compare called a 5-vs-4 mismatch agreement:\n" .. out)
		assert.is_not_nil(out:find("legacy=5 v2=4", 1, true), "the divergence was not described:\n" .. out)
	end)

	-- INV2-MAIL-001 follow-up: compare reported "No divergence" on a live client at the moment the
	-- V2 store was missing an entire source (mail). Two explanations were possible -- compare has a
	-- blind spot, or compare was right because the legacy record ALSO had no mail yet at the time
	-- it ran. This distinguishes them: it drives the exact shape the defect produces, a legacy
	-- record carrying bags + mail against a V2 record carrying bags only.
	--
	-- If this passes, compare has no blind spot and the live "No divergence" was CORRECT for the
	-- state at that instant -- which makes it a timing artefact, not a diagnostic that lies.
	it("reports the divergence when V2 is missing an entire source", function()
		seed(ME, 11754, 71, 68)   -- legacy: 68 bags + 3 mail. V2: bags only.
		TOGBankClassic_Chat:ChatCommand("dev compare")
		local out = output()
		assert.is_nil(out:find("No divergence", 1, true),
			"compare called a missing-mail V2 record agreement. If this is what happened live, " ..
			"compare cannot be the gate for INV2 step 9:\n" .. out)
		assert.is_not_nil(out:find("legacy=71 v2=68", 1, true),
			"the missing source was not described:\n" .. out)
	end)

	it("reports an item the legacy store has and V2 does not", function()
		TOGBankClassic_Guild.Info.alts[ME] = { items = { { ID = 858, Count = 5 } } }
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, ME, {}, 0)
		TOGBankClassic_Chat:ChatCommand("dev compare")
		assert.is_not_nil(output():find("legacy=5 v2=0", 1, true))
	end)

	it("reports an item V2 has and the legacy store does not", function()
		TOGBankClassic_Guild.Info.alts[ME] = { items = {} }
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, ME,
			{ TOGBankClassic_Inventory_Record.new(858, 3) }, 0)
		TOGBankClassic_Chat:ChatCommand("dev compare")
		assert.is_not_nil(output():find("legacy=absent v2=3", 1, true), output())
	end)

	-- Suffix variants split into separate V2 rows but share a legacy row. Comparing row counts
	-- would flag every random-suffix item in the game as a divergence; comparing per-id totals
	-- is the only thing the two encodings actually promise to agree on.
	it("does not flag suffix variants that split into extra V2 rows", function()
		TOGBankClassic_Guild.Info.alts[ME] = { items = { { ID = 10132, Count = 2 } } }
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, ME, {
			TOGBankClassic_Inventory_Record.new(10132, 1, 863),
			TOGBankClassic_Inventory_Record.new(10132, 1, 865),
		}, 0)
		TOGBankClassic_Chat:ChatCommand("dev compare")
		assert.is_not_nil(output():find("No divergence", 1, true),
			"two suffix variants summing to the legacy count were reported as a mismatch:\n" .. output())
	end)

	it("says so rather than claiming agreement when the switch is off", function()
		setSwitch("inventoryV2", false)
		seed(ME, 858, 5, 4)
		TOGBankClassic_Chat:ChatCommand("dev compare")
		local out = output()
		assert.is_nil(out:find("No divergence", 1, true),
			"compare reported agreement while V2 was not being written:\n" .. out)
		assert.is_not_nil(out:find("inventoryV2 is OFF", 1, true), out)
	end)

	it("says so rather than claiming agreement when the V2 store is empty", function()
		TOGBankClassic_Guild.Info.alts[ME] = { items = { { ID = 858, Count = 5 } } }
		TOGBankClassic_Chat:ChatCommand("dev compare")
		local out = output()
		assert.is_nil(out:find("No divergence", 1, true),
			"an empty V2 store was reported as agreeing with a populated legacy store:\n" .. out)
		assert.is_not_nil(out:find("empty", 1, true), out)
	end)

	-- A character present in only one store is not a divergence -- it has simply not been
	-- scanned under the new path yet. Counting it as one would bury the real mismatches.
	it("only compares characters present in both stores", function()
		seed(ME, 858, 5, 5)
		TOGBankClassic_Guild.Info.alts["Other-Testrealm"] = { items = { { ID = 999, Count = 1 } } }
		TOGBankClassic_Chat:ChatCommand("dev compare")
		local out = output()
		assert.is_not_nil(out:find("Compared 1 character", 1, true), out)
		assert.is_not_nil(out:find("No divergence", 1, true), out)
	end)
end)

describe("/togbank dev switches", function()
	before_each(function()
		env.reset()
		env.stubOutput()
		env.loadFile("Modules/Item.lua")
		env.loadFile("Modules/Bank.lua")
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/Switches.lua")
		env.loadFile("Modules/Inventory/Record.lua")
		env.loadFile("Modules/Inventory/Resolve.lua")
		env.loadFile("Modules/Inventory/Store.lua")
		env.loadFile("Modules/Inventory/Scan.lua")
		env.loadFile("Modules/Chat.lua")
		TOGBankClassic_Database = { db = { global = {} } }
		-- CMD-001: second copy of the same loose GetArgs fake. Both are now env.stubCore, which
		-- implements AceConsole's real tokenizing contract.
		env.stubCore()
	end)

	-- The stub Output records (format, ...) unformatted, so a spec that just concatenated the
	-- pieces would never see "Compared 1 character" — only "Compared %d character(s)" and a
	-- lone 1. Format here so the assertions read the line a player would actually see.
	local function output()
		local parts = {}
		for _, call in ipairs(TOGBankClassic_Output.calls) do
			local args = {}
			for i = 1, call.n do args[i] = call[i] end
			local ok, line = pcall(string.format, unpack(args, 1, call.n))
			if not ok then
				-- Not a format string, or mismatched args. Fall back to the raw pieces rather
				-- than letting the helper itself error and take the assertion down with it.
				line = {}
				for i = 1, call.n do line[i] = tostring(args[i]) end
				line = table.concat(line, " ")
			end
			parts[#parts + 1] = line
		end
		return table.concat(parts, "\n")
	end

	it("lists every registered switch", function()
		TOGBankClassic_Chat:ChatCommand("dev switches")
		local out = output()
		for name in pairs(TOGBankClassic_Switches.registry) do
			assert.is_not_nil(out:find(name, 1, true), name .. " was not listed:\n" .. out)
		end
	end)

	it("turns a switch on", function()
		TOGBankClassic_Chat:ChatCommand("dev switches inventoryV2 on")
		assert.is_true(TOGBankClassic_Switches:IsEnabled("inventoryV2"))
	end)

	it("turns a switch off again", function()
		TOGBankClassic_Switches:Set("inventoryV2", true)
		TOGBankClassic_Chat:ChatCommand("dev switches inventoryV2 off")
		assert.is_false(TOGBankClassic_Switches:IsEnabled("inventoryV2"))
	end)

	it("reports a typo as an unknown switch", function()
		TOGBankClassic_Chat:ChatCommand("dev switches inventoryV3 on")
		assert.is_not_nil(output():find("Unknown switch", 1, true), output())
	end)

	-- Set() also returns false when db.global is not attached. Collapsing that into "unknown
	-- switch" sends someone hunting for a typo that is not there.
	it("distinguishes an unready database from a typo", function()
		TOGBankClassic_Database.db = nil
		TOGBankClassic_Chat:ChatCommand("dev switches inventoryV2 on")
		local out = output()
		assert.is_nil(out:find("Unknown switch", 1, true),
			"a valid switch name was reported as unknown because the database was not ready:\n" .. out)
		assert.is_not_nil(out:find("database is not loaded", 1, true), out)
	end)
end)

-- INV2 turns two libraries from nice-to-have into load-bearing, and both spellings of a
-- dependency fail SILENTLY in different ways: a wrong folder name in the TOC breaks load order,
-- a wrong CurseForge slug in .pkgmeta skips auto-install. Neither raises. So both are asserted.
--
-- ItemDB is the one that changes character. docs/INVENTORY_V2.md section 4 is explicit that
-- rendering "asks IDB, never the wire" -- V2 stores integer tuples and DERIVES the link, so
-- without the library there is nothing to derive from and every lookup falls through to
-- GetItemInfoInstant or a placeholder. That is precisely the cold-cache behaviour the rework
-- exists to delete, and it would degrade quietly rather than erroring.
--
-- The slugs are NOT the folder names and are taken from sibling consumers rather than guessed:
-- Dibs and TOGProfessionMaster both ship `libitemdb` for the folder `ItemDB`, and five addons
-- in this tree ship `deltasync`. The same trap already applies to GuildRoster/libguildroster.
describe("INV2 library dependencies", function()
	before_each(function() env.reset() end)

	local TOCS = { "TOGBankClassic.toc", "TOGBankClassic_BCC.toc" }

	it("declares ItemDB as a dependency in both TOCs", function()
		for _, toc in ipairs(TOCS) do
			local deps = readFile(toc):match("## Dependencies:([^\n]*)")
			assert.is_not_nil(deps, toc .. " has no Dependencies line")
			assert.truthy(deps:find("ItemDB", 1, true),
				toc .. " does not declare ItemDB, so Resolve.lua's LibStub lookup returns nil " ..
				"and every V2 link falls back to a placeholder")
		end
	end)

	it("declares DeltaSync as a dependency in both TOCs", function()
		for _, toc in ipairs(TOCS) do
			local deps = readFile(toc):match("## Dependencies:([^\n]*)")
			assert.is_not_nil(deps, toc .. " has no Dependencies line")
			assert.truthy(deps:find("DeltaSync", 1, true),
				toc .. " does not declare DeltaSync")
		end
	end)

	it("lists both CurseForge slugs in .pkgmeta", function()
		local pkg = readFile(".pkgmeta")
		assert.truthy(pkg:find("libitemdb", 1, true),
			".pkgmeta must list the slug 'libitemdb' (NOT the folder name 'ItemDB') under " ..
			"required-dependencies, or CurseForge will not auto-install it")
		assert.truthy(pkg:find("deltasync", 1, true),
			".pkgmeta must list the slug 'deltasync' under required-dependencies")
	end)

	-- The TOC lockstep rule. There is a sibling of this in guildroster_integration_spec.lua;
	-- kept here too because this file is where a new INV2 dependency gets added, and the
	-- failure it catches (adding to one flavour only) is silent on the flavour you did not test.
	it("keeps the two TOC dependency lines identical", function()
		local a = readFile("TOGBankClassic.toc"):match("## Dependencies:([^\n]*)")
		local b = readFile("TOGBankClassic_BCC.toc"):match("## Dependencies:([^\n]*)")
		assert.equal(a, b, "the TOC lockstep rule requires both flavours declare the same deps")
	end)
end)

-- INV2-ISOLATE-001 -- THE LEGACY STORE MUST NEVER BE A SOURCE FOR THE V2 STORE.
--
-- Asked by the operator, 2026-09-09, and it is the right question: the legacy DB has demonstrably
-- held corrupt data on a live account, and the whole value of the tuple rework evaporates if a
-- migration or a convenience fallback quietly copies that corruption forward. An empty V2 store is
-- recoverable by scanning; a V2 store seeded from bad legacy rows looks like data and is not.
--
-- Store.lua's header already states the intent -- "NO MIGRATION FROM THE LEGACY DB ... the worst
-- case is an empty V2 DB and a switch flipped back". These specs make it ENFORCED rather than
-- intended, in the two different ways it can be broken:
--
--   * BEHAVIOURALLY -- a scan running with a corrupt legacy record present must produce a V2 store
--     that reflects the CONTAINERS, not the legacy rows.
--   * STRUCTURALLY -- a future writer of the V2 store, added by someone who has not read this file,
--     must be a deliberate decision rather than an accident. The class guard below fails on any new
--     call site, so adding one means coming here and saying where its data comes from.
describe("INV2-ISOLATE-001: legacy data cannot reach the V2 store", function()
	local Bank

	before_each(function()
		env.reset()
		Bank = loadWiring()
		setSwitch("inventoryV2", true)
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
	end)

	it("ignores a corrupt legacy aggregate and stores what the CONTAINERS hold", function()
		-- The exact shape seen live: a legacy aggregate whose counts are wildly inflated relative
		-- to what the character actually carries.
		TOGBankClassic_Guild.Info.alts[ME] = {
			name = ME,
			items = { { ID = 858, Count = 99999, Link = "|cff9d9d9d|Hitem:858::::::::1:::::|h[Corrupt]|h|r" } },
			money = 0,
		}
		env.setBag(0, 4, { { id = 858, count = 5 } })

		Bank:Scan()

		-- GetGuildTotal rather than a per-alt total, which the store does not expose. ME is the
		-- only alt Bank:Scan writes into V2 here, so the guild total IS this character's total --
		-- asserted below rather than assumed, because a second alt appearing would silently turn
		-- this into a different measurement.
		assert.same({ ME }, TOGBankClassic_Inventory_Store:GetAltNames(GUILD),
			"precondition: the V2 store holds an alt other than the scanning character, so " ..
			"GetGuildTotal is no longer that character's total and the assertion below is measuring " ..
			"something else")
		local total = TOGBankClassic_Inventory_Store:GetGuildTotal(GUILD, 858)
		assert.equal(5, total, string.format(
			"the V2 store holds %d of item 858 but the bags hold 5 -- a corrupt legacy aggregate " ..
			"(99999) reached the tuple store, which is the one thing the rework exists to prevent",
			total))
	end)

	it("does not resurrect a legacy-only item that the containers no longer hold", function()
		-- Item 4611 is in the legacy record and in NO container. If anything aggregated the legacy
		-- rows into V2 it would appear; a container-sourced scan cannot invent it.
		TOGBankClassic_Guild.Info.alts[ME] = {
			name = ME,
			items = { { ID = 4611, Count = 2 } },
			money = 0,
		}
		env.setBag(0, 4, { { id = 858, count = 5 } })

		Bank:Scan()

		assert.equal(0, TOGBankClassic_Inventory_Store:GetGuildTotal(GUILD, 4611),
			"an item present ONLY in the legacy record appeared in the V2 store, so something is " ..
			"reading the legacy aggregate as a scan source")
	end)

	-- THE CLASS GUARD. The two behavioural examples above can only cover the writers that exist
	-- today; this one fails the moment a third appears, which is the failure mode that actually
	-- happens -- somebody adds a convenience "seed V2 from legacy" helper in six months.
	it("has exactly TWO production writers of the V2 store, and both are container/wire sourced", function()
		local WRITERS = {
			["Modules/Chat.lua"] = "tuple payload decoded from the wire (togbank-d4)",
			["Modules/Bank.lua"] = "Scan:ScanAll() over live containers, plus MailInventory",
		}

		local found = {}
		for _, path in ipairs(env.shippedModules()) do
			local n = 0
			for line in (readFile(path) .. "\n"):gmatch("([^\n]*)\n") do
				n = n + 1
				-- A CALL, not the definition in Store.lua and not a mention in a comment.
				local code = line:match("^(.-)%-%-") or line
				if code:find("Store:SetAlt[RS]", 1, false)
					or code:find("Inventory_Store:SetAlt[RS]", 1, false) then
					found[path] = (found[path] or 0) + 1
				end
			end
		end

		-- Store.lua defines them and SetAltRecords delegates to SetAltSources; that is the
		-- implementation, not a writer, so it is expected and excluded by name.
		found["Modules/Inventory/Store.lua"] = nil

		for path in pairs(found) do
			assert.is_not_nil(WRITERS[path], string.format(
				"%s writes the V2 store and is not one of the two known writers. If its data comes " ..
				"from live containers or the wire, add it to WRITERS here with that stated. IF IT " ..
				"COMES FROM THE LEGACY DB, IT MUST NOT EXIST -- seeding V2 from legacy carries " ..
				"corruption forward into the store built to escape it (Store.lua's header: 'NO " ..
				"MIGRATION FROM THE LEGACY DB')", path))
		end

		for path, why in pairs(WRITERS) do
			assert.is_not_nil(found[path], string.format(
				"%s no longer writes the V2 store (expected: %s). Either the mirror was removed or " ..
				"this guard's detection broke -- and a guard that finds nothing passes", path, why))
		end
	end)

	-- HASH-CANON-003: THE SAME GUARD FOR HASH AUTHORSHIP, and it is needed for a sharper reason.
	--
	-- A canon may only be minted by the client that READ THE BANK. That is true today because
	-- Bank:Scan returns early for a character not in the banker list (Bank.lua:152-157) -- but the
	-- stamp is ~280 lines below that gate, and nothing connects them. A new stamp site added
	-- anywhere else would author an identity for data its client never read, and the operator's
	-- constraint is explicit: the re-stamp "can ONLY be on the bankers, not on non-bankers".
	--
	-- Three sites minting hashes were deleted for exactly this (HASH-CANON-002/003): the query-path
	-- recompute, the no-change adoption, and the database migration. Each looked locally reasonable.
	-- This is what makes a fourth fail loudly instead of shipping.
	it("has exactly ONE production site that mints an inventory hash", function()
		local MINTERS = {
			["Modules/Bank.lua"] = "the author's own bank scan, behind the isBank gate",
			-- Core.lua is a one-line forwarder to DeltaComms, and DeltaComms is the implementation.
			-- Both are the mechanism, not a decision to mint, so they are named and excluded.
			["Core.lua"] = "forwarder",
			["Modules/DeltaComms.lua"] = "implementation",
		}

		local found = {}
		for _, path in ipairs(env.shippedModules()) do
			for line in (readFile(path) .. "\n"):gmatch("([^\n]*)\n") do
				local code = line:match("^(.-)%-%-") or line
				if code:find("StampInventoryHashes", 1, true)
					or code:find("ComputeCanonHash", 1, true) then
					found[path] = (found[path] or 0) + 1
				end
			end
		end

		for path in pairs(found) do
			assert.is_not_nil(MINTERS[path], string.format(
				"%s mints an inventory hash and is not the author's scan. A hash is the IDENTITY OF " ..
				"A VERSION and may only be produced by the client that read the bank -- anywhere " ..
				"else it is that client's opinion of somebody else's data, it gets advertised, and " ..
				"peers adopt it. That is the mutation loop HASH-CANON-002 removed from three " ..
				"separate places", path))
		end

		assert.is_not_nil(found["Modules/Bank.lua"],
			"Bank.lua no longer mints a hash, so either the author's stamp was removed or this " ..
			"guard's detection broke -- and a guard that finds nothing passes")
	end)

	-- The behavioural half: the gate the guard above assumes is real, driven rather than read.
	it("mints NO hash when the scanning character is not a banker", function()
		TOGBankClassic_Guild.GetBanks = function() return { "Someoneelse-Azuresong" } end
		TOGBankClassic_Guild.Info.alts[ME] = { name = ME, items = {}, money = 0 }
		env.setBag(0, 4, { { id = 858, count = 5 } })

		Bank:Scan()

		local alt = TOGBankClassic_Guild.Info.alts[ME]
		assert.is_nil(alt.inventoryHashV2,
			"a non-banker stamped a canon for itself. The operator's constraint is that the " ..
			"post-upgrade re-stamp happens on BANKERS ONLY -- a non-banker publishing a version " ..
			"identity puts a record into the guild's sync that no banker authored")
		assert.is_nil(alt.inventoryContentHash,
			"a non-banker stamped a content hash, so its next scan will compare against it and " ..
			"believe it is the author of this record")
	end)
end)
