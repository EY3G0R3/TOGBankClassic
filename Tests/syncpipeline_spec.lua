-- END-TO-END: one character's bank reaching another character's store.
--
-- WHY THIS FILE EXISTS. Every piece of the sync had a spec and the PIPELINE had none:
-- `wiring_spec` stops at the local V2 mirror, `wire_spec` encodes a payload nobody sends,
-- `tupledelta_spec` diffs in memory without serialising, and `p2psession_spec` drives a handshake
-- through which no data ever flows. Four green files, and not one of them would notice if a scan
-- produced rows the receiver could not apply.
--
-- That gap is not incidental. `ComputeDelta` and `ApplyDelta` have NO spec coverage at all, and
-- docs/AUDIT.md records the sync layer as the origin of every HIGH finding this board has
-- produced. The seams between the pieces are exactly where nobody has looked.
--
-- THE PROPERTY UNDER TEST, and it is one sentence: after A scans and B applies what A sent, B's
-- view of A's inventory equals A's own. Asserting the intermediate structures instead would pass
-- against a pipeline that is internally consistent and still wrong end to end.
--
-- REAL SERIALISATION, NOT A STUB. A fake serialiser that returns its input makes a round-trip test
-- pass by construction, including for payloads the real library cannot encode. This drives the
-- actual AceSerializer-3.0 that ships to players (see env.aceSerializer).
--
-- WHAT THIS DOES **NOT** COVER, stated so it is not read as more than it is:
--   * the P2P negotiation layer -- broadcast, collect, dispatch, sync-request/accept/busy. This
--     starts from "the payload arrived"; `p2psession_spec` owns getting there.
--   * `Chat:OnCommReceived`'s prefix dispatch, chunking and the checksum envelope.
--   * `ComputeDelta` / `ApplyDelta` themselves -- the legacy link-keyed path. This exercises the
--     TUPLE path, which is what replaces them. Those two remain uncovered and are named in the
--     round-2 audit request.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local GUILD = "Testguild"
local ME    = "Bankchar-Testrealm"

local Serializer

--- One client: the addon's inventory chain plus the collaborators Bank:Scan reaches for.
--- Mirrors wiring_spec's loadWiring, because a second, subtly different setup is how two specs
--- come to disagree about what "loaded" means.
local function loadClient()
	env.stubOutput()
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
		"Modules/Bank.lua",
	})

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
	TOGBankClassic_Database.db.global.switches = { inventoryV2 = true }
	TOGBankClassic_Bank.hasUpdated = true
	TOGBankClassic_Bank.eventsRegistered = false
end

--- An alt's stored tuples as a key -> count table, which is the comparison that matters: two
--- clients agree when they hold the same items in the same quantities, whatever the row order.
local function inventoryOf(altName)
	local Record = TOGBankClassic_Inventory_Record
	local out = {}
	for _, rec in ipairs(TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, altName)) do
		out[Record.key(rec)] = Record.count(rec)
	end
	return out
end

--- Serialise across the client boundary. Everything crossing this went through the real library,
--- so a value the wire cannot carry fails here rather than in production.
local function overTheWire(payload)
	local s = Serializer:Serialize(payload)
	assert.is_string(s, "the payload did not serialise at all")
	local ok, decoded = Serializer:Deserialize(s)
	assert.is_true(ok, "the payload did not survive deserialisation: " .. tostring(decoded))
	return decoded, #s
end

describe("sync pipeline: A scans, B applies", function()
	before_each(function()
		env.reset()
		Serializer = env.aceSerializer()
		loadClient()
	end)

	--- Scan the current env state as character A and return its stored inventory.
	local function scanAsA()
		TOGBankClassic_Bank.hasUpdated = true
		TOGBankClassic_Bank:Scan()
		return inventoryOf(ME)
	end

	--- Rebuild the world as a SECOND client holding `baseline` for A, then apply `delta`.
	--- A genuine second client: fresh env, fresh modules, fresh store. Reusing A's tables would
	--- let a shared reference make the test pass without anything crossing the wire.
	local function applyAsB(baseline, delta)
		env.reset()
		Serializer = env.aceSerializer()
		loadClient()
		local Store = TOGBankClassic_Inventory_Store
		Store:SetAltRecords(GUILD, ME, baseline)
		local applied = TOGBankClassic_DeltaComms:ApplyTupleDelta(
			Store:GetAltRecords(GUILD, ME), delta)
		Store:SetAltRecords(GUILD, ME, applied)
		return inventoryOf(ME)
	end

	it("delivers a first-time inventory to a client that has nothing", function()
		env.defineItem(858, { name = "Minor Healing Potion" })
		env.defineItem(11754, { name = "Black Diamond" })
		env.setBag(0, 4, { { id = 858, count = 5 }, { id = 11754, count = 68 } })

		local a = scanAsA()
		assert.equal(5, a["858:0:0"], "precondition: A did not scan its own bags")

		local delta = TOGBankClassic_DeltaComms:ComputeTupleDelta({},
			TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME))
		local b = applyAsB({}, (overTheWire(delta)))

		assert.same(a, b,
			"B's view of A's bank does not equal A's own after a full first delivery")
	end)

	it("delivers a change to a client that already holds the previous state", function()
		env.defineItem(11754, { name = "Black Diamond" })
		env.setBag(0, 4, { { id = 11754, count = 68 } })
		scanAsA()
		local before = TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME)
		-- Copy, because the store hands back its own array and the rescan below replaces it.
		local baseline = {}
		for i, rec in ipairs(before) do baseline[i] = { rec[1], rec[2], rec[3], rec[4] } end

		-- A spends three and gains a new stack.
		env.defineItem(858, { name = "Minor Healing Potion" })
		env.setBag(0, 4, { { id = 11754, count = 65 }, { id = 858, count = 2 } })
		local a = scanAsA()

		local delta = TOGBankClassic_DeltaComms:ComputeTupleDelta(baseline,
			TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME))
		local b = applyAsB(baseline, (overTheWire(delta)))

		assert.same(a, b, "B diverged from A after an incremental update")
		assert.equal(65, b["11754:0:0"])
		assert.equal(2, b["858:0:0"])
	end)

    -- The case link-keyed identity got wrong, carried all the way across the wire. REQ-001 is the
    -- same defect on the request side: names are not unique and neither are base IDs.
	it("keeps suffix variants distinct across the wire", function()
		env.defineItem(15260, { name = "Stone Hammer" })
		-- BOTH variants in ONE bag, as two slots. Two setBag calls for the same bag id REPLACE it,
		-- so the first draft left a single variant on the client and the "collapse" it reported
		-- was the fixture, not the pipeline.
		env.setBag(0, 4, {
			{ id = 15260, count = 1, suffix = 863 },
			{ id = 15260, count = 1, suffix = 2504 },
		})
		local a = scanAsA()
		assert.equal(2, (function()
			local n = 0
			for _ in pairs(a) do n = n + 1 end
			return n
		end)(), "precondition: A's own scan did not produce two distinct suffix rows")

		local delta = TOGBankClassic_DeltaComms:ComputeTupleDelta({},
			TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME))
		local b = applyAsB({}, (overTheWire(delta)))

		assert.same(a, b)
		assert.equal(2, (function()
			local n = 0
			for _ in pairs(b) do n = n + 1 end
			return n
		end)(), "two suffix variants of one base ID collapsed into a single row in transit")
	end)

	it("removes an item on B when A no longer has it", function()
		env.defineItem(858, { name = "Minor Healing Potion" })
		env.defineItem(11754, { name = "Black Diamond" })
		env.setBag(0, 4, { { id = 858, count = 5 }, { id = 11754, count = 1 } })
		scanAsA()
		local baseline = {}
		for i, rec in ipairs(TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME)) do
			baseline[i] = { rec[1], rec[2], rec[3], rec[4] }
		end

		env.setBag(0, 4, { { id = 858, count = 5 } })   -- the diamond is gone
		local a = scanAsA()

		local delta = TOGBankClassic_DeltaComms:ComputeTupleDelta(baseline,
			TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME))
		local b = applyAsB(baseline, (overTheWire(delta)))

		assert.same(a, b)
		assert.is_nil(b["11754:0:0"], "an item A no longer holds survived on B")
	end)

	-- A duplicated message is normal on a lossy transport with retries. It must not double a stack.
	it("is unchanged when the same payload arrives twice", function()
		env.defineItem(11754, { name = "Black Diamond" })
		env.setBag(0, 4, { { id = 11754, count = 68 } })
		local a = scanAsA()

		local delta = TOGBankClassic_DeltaComms:ComputeTupleDelta({},
			TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME))
		local wire = (overTheWire(delta))

		env.reset()
		Serializer = env.aceSerializer()
		loadClient()
		local Store = TOGBankClassic_Inventory_Store
		local once = TOGBankClassic_DeltaComms:ApplyTupleDelta({}, wire)
		local twice = TOGBankClassic_DeltaComms:ApplyTupleDelta(once, wire)
		Store:SetAltRecords(GUILD, ME, twice)

		assert.same(a, inventoryOf(ME), "a replayed delta changed B's inventory")
	end)

	-- Mail is a first-class source (INV2-MAIL-001) and must survive the trip like any other.
	it("carries mail across, not just bags and bank", function()
		env.defineItem(11754, { name = "Black Diamond" })
		env.setBag(0, 4, { { id = 11754, count = 68 } })
		TOGBankClassic_MailInventory.hasUpdated = true
		TOGBankClassic_MailInventory.ScanMailInventory = function()
			return { items = { { ID = 11754, Count = 3 } }, version = 1, lastScan = 0 }
		end
		local a = scanAsA()
		assert.equal(71, a["11754:0:0"], "precondition: mail did not reach A's own store")

		local delta = TOGBankClassic_DeltaComms:ComputeTupleDelta({},
			TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, ME))
		local b = applyAsB({}, (overTheWire(delta)))

		assert.equal(71, b["11754:0:0"], "the 3 in mail did not cross the wire")
		assert.same(a, b)
	end)
end)
