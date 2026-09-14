-- INV2 wiring — the seams where the V2 store is fed from live code.
--
-- Record/Resolve/Store/Scan/Wire are covered by their own specs in isolation. What is NOT covered
-- there is the part that can actually hurt a player: the V2 write runs inside Bank:Scan, the
-- hottest path in the addon and the source of every number it shows.
--
-- INV2-RETIRE-003 changed the contract this file holds. It used to be "the legacy scan must produce
-- byte-identical results whether V2 is on, off, or broken", because V2 was a switch-gated mirror
-- and the legacy aggregate fed the hash. Now the V2 store IS the scan's source of truth: the write
-- is unconditional, the hash / version stamp / bank log read the store's records, a fault in the
-- V2 scan is a scan fault, and the `inventoryV2` / `dualWrite` switches that gated the mirror are
-- retired -- the record's sub-tables carry metadata only (docs/DELTA_RELEASE.md section 4).
-- writ-cannot: the "/togbank dev compare" describe (nine examples: agreement, count divergence, a
-- missing source, an item in one store only in each direction, suffix variants, the switch-off and
-- empty-store refusals, and characters-in-both) is gone with the command -- its whole subject was
-- diffing the V2 store against legacy rows that no longer exist; and "registers switches and
-- compare as dev subcommands" is re-pinned on `switches` alone for the same reason.
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
	TOGBankClassic_Database      = { db = { global = {} } }
	TOGBankClassic_MailInventory = { hasUpdated = false }
	TOGBankClassic_Core          = env.coreHashStub(12345)

	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	TOGBankClassic_Bank.hasUpdated = true
	TOGBankClassic_Bank.eventsRegistered = false
	return TOGBankClassic_Bank
end

--- Write a switch's stored value directly, as a reload would find it. INV2-RETIRE-003: the
--- `inventoryV2` value is written by two examples below as a STALE override -- a SavedVariables
--- file from before the retirement still carries it -- to pin that the scan ignores it.
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

	-- INV2-RETIRE-003. This example used to assert the switch GATES the write ("leaves the V2 store
	-- untouched while the switch is off"). It no longer does, on purpose: the store is what gets
	-- hashed, stamped and logged, so a scan that skipped it would publish a version describing
	-- nothing. The switch itself is retired; a stale `inventoryV2 = false` left in a SavedVariables
	-- file from before must change nothing.
	it("writes the V2 store regardless of a stale inventoryV2 override", function()
		setSwitch("inventoryV2", false)
		Bank:Scan()
		assert.is_true(TOGBankClassic_Inventory_Store:HasAlt(GUILD, ME),
			"the V2 store was NOT written with a stale inventoryV2=false -- the write is gated " ..
			"again, so the hash and the canon below would describe records that were never stored")
	end)

	-- THE change: what gets hashed and stamped is the store's record set, not the legacy aggregate.
	-- Captured off the stamp call rather than compared by value, because coreHashStub returns a
	-- constant -- a value comparison would pass for either input.
	it("hashes and stamps the V2 records, not the legacy aggregate", function()
		local stampedWith
		TOGBankClassic_Core.StampInventoryHashes = function(_, alt, rows, _, _, _, updatedAt)
			stampedWith = rows
			alt.inventoryHash, alt.inventoryHashV2, alt.inventoryContentHash = 1, env.canon(updatedAt, 2), 3
			return 1, alt.inventoryHashV2, 3
		end
		Bank:Scan()
		assert.is_not_nil(stampedWith, "nothing was stamped")
		assert.equal(1, #stampedWith)
		assert.is_true(TOGBankClassic_Inventory_Record.isValid(stampedWith[1]),
			"the stamp was taken over legacy rows, not tuples")
		assert.is_nil(stampedWith[1].ID, "a legacy-shaped row reached the stamp")
		assert.equal(858, TOGBankClassic_Inventory_Record.id(stampedWith[1]))
		assert.equal(5,   TOGBankClassic_Inventory_Record.count(stampedWith[1]))
	end)

	it("writes the V2 store", function()
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
		env.money = 987654
		Bank:Scan()
		assert.equal(987654, TOGBankClassic_Inventory_Store:GetAltMoney(GUILD, ME))
	end)

	-- INV2-RETIRE-003. This used to compare the LEGACY aggregate with the switch on and off, back
	-- when the mirror ran inside the legacy scan. There is no legacy aggregate and no switch any
	-- more: the scan writes the store only, whatever a stale override says, so what is pinned is
	-- that the record carries no rows in either state and the store's result is the same in both.
	it("writes no legacy rows onto the record, whatever a stale inventoryV2 override says", function()
		local Record = TOGBankClassic_Inventory_Record
		local function stored()
			local recs = TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME)
			return { count = #recs, id = Record.id(recs[1]), n = Record.count(recs[1]) }
		end
		local function noLegacyRows(alt)
			assert.is_nil(alt.items, "the legacy aggregate was written")
			assert.is_nil(alt.bags and alt.bags.items, "legacy bag rows were written")
			assert.is_nil(alt.bank and alt.bank.items, "legacy vault rows were written")
			assert.is_nil(alt.mail and alt.mail.items, "legacy mail rows were written")
		end

		setSwitch("inventoryV2", false)
		Bank:Scan()
		noLegacyRows(TOGBankClassic_Guild.Info.alts[ME])
		local without = stored()
		assert.equal(1, without.count)

		env.reset()
		Bank = loadWiring()
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 858, count = 5 } })
		Bank:Scan()
		noLegacyRows(TOGBankClassic_Guild.Info.alts[ME])
		local with = stored()

		assert.same(without, with)
	end)

	-- INV2-RETIRE-003. This used to be "still completes the legacy scan when the V2 mirror throws":
	-- the write sat in a pcall so a fault in new code could not take down the path every user read.
	-- The store IS that path now, so a fault in it is a scan fault and must SURFACE -- a scan that
	-- swallowed it would carry on to hash and publish a version over records it never stored.
	-- Nothing is minted and nothing is stored: the fault leaves no half-published state behind.
	it("surfaces a fault in the V2 scan instead of publishing around it", function()
		TOGBankClassic_Inventory_Scan.ScanBags = function() error("boom") end
		local ok, err = pcall(function() Bank:Scan() end)
		assert.is_false(ok, "a fault in the V2 scan was swallowed; the scan went on to publish")
		assert.truthy(tostring(err):find("boom", 1, true))
		assert.is_false(TOGBankClassic_Inventory_Store:HasAlt(GUILD, ME), "a half-written store survived the fault")
		local alt = TOGBankClassic_Guild.Info.alts[ME]
		assert.is_true(alt == nil or alt.inventoryHashV2 == nil, "a version was minted over a failed scan")
	end)

	-- Mirrors the legacy behaviour verified in bank_spec: away from a banker the vault slots read
	-- as empty, and writing that emptiness through would erase the character's whole vault from
	-- the guild's view.
	it("keeps previously stored records when the vault is out of reach", function()
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
	-- INV2-RETIRE-003: `compare` is gone with the legacy store it compared against, and must stay
	-- gone -- a name in either table with no partner is the CMD-002 class.
	it("registers switches as a dev subcommand, and compare not at all", function()
		local chat = readFile("Modules/Chat.lua")
		assert.is_not_nil(chat:match("name%s*=%s*[\"']switches[\"']"), "switches has no COMMAND_REGISTRY entry")
		assert.is_not_nil(chat:match("\n\tswitches%s+=%s*true"),
			"switches is missing from DEV_COMMAND_NAMES, so /togbank dev switches reports an unknown subcommand")
		for _, name in ipairs({ "compare", "purgeghosts" }) do
			assert.is_nil(chat:match("name%s*=%s*[\"']" .. name .. "[\"']"), name .. " has a COMMAND_REGISTRY entry again")
			assert.is_nil(chat:match("\n\t" .. name .. "%s+=%s*true"), name .. " is in DEV_COMMAND_NAMES again")
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

-- INV2-RETIRE-003: the "/togbank dev compare" describe stood here. writ-cannot: its nine examples
-- (agreement, count divergence, a missing source, an item in one store only in each direction,
-- suffix variants, the switch-off and empty-store refusals, characters-in-both) covered a command
-- that was removed on purpose -- its whole subject was diffing the V2 store against legacy rows
-- that are no longer written or kept (docs/DELTA_RELEASE.md section 4), so there is nothing for
-- it to compare and nothing for these to drive.

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

	-- INV2-RETIRE-003: driven on `legacyKeyedReceive` (defaults OFF, so "on" is observable) now
	-- that `inventoryV2` is retired.
	it("turns a switch on", function()
		TOGBankClassic_Chat:ChatCommand("dev switches legacyKeyedReceive on")
		assert.is_true(TOGBankClassic_Switches:IsEnabled("legacyKeyedReceive"))
	end)

	it("turns a switch off again", function()
		TOGBankClassic_Switches:Set("legacyKeyedReceive", true)
		TOGBankClassic_Chat:ChatCommand("dev switches legacyKeyedReceive off")
		assert.is_false(TOGBankClassic_Switches:IsEnabled("legacyKeyedReceive"))
	end)

	it("reports a typo as an unknown switch", function()
		TOGBankClassic_Chat:ChatCommand("dev switches sendV3Wire on")
		assert.is_not_nil(output():find("Unknown switch", 1, true), output())
	end)

	-- A retired switch is an unknown one: the listing must not accept a name from an older release
	-- and report success for a setting nothing reads.
	it("reports a retired switch as unknown", function()
		TOGBankClassic_Chat:ChatCommand("dev switches inventoryV2 on")
		assert.is_not_nil(output():find("Unknown switch", 1, true), output())
	end)

	-- Set() also returns false when db.global is not attached. Collapsing that into "unknown
	-- switch" sends someone hunting for a typo that is not there.
	it("distinguishes an unready database from a typo", function()
		TOGBankClassic_Database.db = nil
		TOGBankClassic_Chat:ChatCommand("dev switches sendV2Wire on")
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
		-- THE DELTA RELEASE step 3b moved the wire writer out of Chat.lua's comm handler into
		-- Inventory/Sync (StoreDelivery): the one store-and-stamp every delivery -- a togbank-d4
		-- snapshot, an inv-snapshot on the host, or a chain applied and PROVEN against the author's
		-- canon -- passes through. Still wire-sourced, still exactly two.
		local WRITERS = {
			["Modules/Inventory/Sync.lua"] = "tuple payload decoded from the wire, or a delta chain applied to what the wire delivered",
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
