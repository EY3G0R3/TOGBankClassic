-- DS-HOST-001 -- TOGBankClassic runs on a DeltaSync-1.0 HOST, and the wire envelope is the host's.
--
-- Step 2 of THE DELTA RELEASE (docs/DELTA_RELEASE.md section 5; the operator's decision, 2026-09-11:
-- "rip it out and use the library"). Until this, TOGBank declared DeltaSync as a dependency and
-- called NOTHING in it -- Core.lua carried its own byte-identical copies of the checksum and the
-- `<AceSerialized>\030<checksum>\031END` envelope. Those copies are gone: Core delegates to the host.
--
-- THE BYTES ON THE WIRE MUST NOT MOVE. Every client in the guild, on every version since the
-- envelope was introduced, parses this exact framing; a checksum computed differently is a message
-- every peer rejects as corrupt. So the envelope for a fixed payload is pinned as a LITERAL, captured
-- from Core's own implementation BEFORE the delegation and asserted unchanged after it -- the same
-- order of proof as HASH-PIN-001.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function loadCore()
	env.stubOutput()
	require("env.ace").load("AceAddon-3.0", "AceComm-3.0", "AceConsole-3.0",
		"AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
	require("env.libs").load("AceCommQueue-1.0", "DeltaSync-1.0")
	env.loadModules({ "Modules/Constants.lua", "Modules/DeltaComms.lua" })
	-- AceAddon refuses a second NewAddon for the same name and the suite shares one Lua state.
	local AceAddon = LibStub("AceAddon-3.0")
	if AceAddon and AceAddon.addons then
		AceAddon.addons["TOGBankClassic"] = nil
		if AceAddon.addonstatus then AceAddon.addonstatus["TOGBankClassic"] = nil end
	end
	env.loadFile("Core.lua")
	TOGBankClassic_Database = { db = { global = { debugCategories = {} }, faction = {} } }
	TOGBankClassic_Options = { IsIntegrityCheckDiagnosticsEnabled = function() return false end }
	return TOGBankClassic_Core
end

-- An ARRAY payload: AceSerializer walks the array part in order, so the bytes are deterministic
-- across runs, where a hash-keyed table's key order is whatever `pairs` gives.
local PAYLOAD = { 1, "two", 3.5, true, "\030 and \031 inside are fine" }
-- Captured 2026-09-11 from Core.lua's own envelope, before the delegation. Do not regenerate.
local BODY     = "^1^T^N1^N1^N2^Stwo^N3^N3.5^N4^B^N5^S~z~`and~`~_~`inside~`are~`fine^t^^"
local CHECKSUM = 1682830732
local ENVELOPE = BODY .. "\030" .. CHECKSUM .. "\031END"

describe("DS-HOST-001: the wire envelope is byte-identical through the host", function()
	local Core
	before_each(function() env.reset(); Core = loadCore() end)

	it("serializes a fixed payload to exactly the bytes Core's own envelope produced", function()
		assert.equal(ENVELOPE, Core:SerializeWithChecksum(PAYLOAD),
			"THE ENVELOPE MOVED. Every peer on every prior version rejects this message as corrupt")
	end)

	it("deserializes that literal back to the payload, through the same two-return contract", function()
		local ok, value = Core:DeserializeWithChecksum(ENVELOPE, { sender = "x", prefix = "togbank-d4" })
		assert.is_true(ok, tostring(value))
		assert.same(PAYLOAD, value)
	end)

	it("rejects a corrupted body as a checksum mismatch, with the same two-return shape", function()
		local corrupt = ENVELOPE:gsub("two", "twx")
		local ok, err = Core:DeserializeWithChecksum(corrupt, { sender = "x", prefix = "togbank-d4" })
		assert.is_false(ok)
		assert.is_string(err)
	end)

	it("still accepts a pre-checksum message (no separator) by plain deserialize", function()
		local ok, value = Core:DeserializeWithChecksum("^1^N7^^")
		assert.is_true(ok)
		assert.equal(7, value)
	end)

	-- Core:Checksum is what DeltaComms feeds the hash input string through (HASH-PIN-001). A string
	-- through the library's ComputeHash is that same multiplicative checksum over the same bytes.
	it("computes the same checksum number for a string as before", function()
		assert.equal(CHECKSUM, Core:Checksum(BODY))
		assert.equal(0, Core:Checksum(nil))
		assert.equal(0, Core:Checksum(42))
	end)

	-- The proof that it IS the host and not a surviving copy: Core.lua carries no checksum loop and
	-- no separator literal of its own any more.
	it("carries no envelope implementation of its own in Core.lua", function()
		local src = env.readFile("Core.lua")
		assert.is_nil(src:find("sum * 31", 1, true), "Core.lua still has its own checksum loop")
		assert.is_nil(src:find('"\\030"', 1, true), "Core.lua still defines the checksum separator")
		assert.is_nil(src:find('"\\031END"', 1, true), "Core.lua still defines the stop marker")
		assert.is_not_nil(src:find("DeltaHost():SerializeWithChecksum", 1, true))
		assert.is_not_nil(src:find("DeltaHost():DeserializeWithChecksum", 1, true))
	end)
end)

describe("DS-HOST-001: the host itself", function()
	local Core
	before_each(function() env.reset(); Core = loadCore() end)

	it("is a real DeltaSync-1.0 host in TOGBank's namespace, created once", function()
		local host = Core:DeltaHost()
		assert.is_table(host)
		assert.equal("TOGBankClassic", host.namespace)
		assert.equal(host, Core:DeltaHost(), "a second call built a second host")
		assert.is_function(host.RequestData)
		assert.is_function(host.SendData)
		assert.is_function(host.ComputeStructuredDelta or host.ComputeDelta)
	end)

	it("is stood up by OnInitialize, so its prefixes register at login", function()
		local src = env.readFile("Core.lua")
		local init = src:match("function TOGBankClassic_Core:OnInitialize%(%)(.-)\nend")
		assert.is_not_nil(init)
		assert.is_not_nil(init:find("self:DeltaHost()", 1, true), "OnInitialize does not create the host")
	end)

	it("registered its seven comm prefixes on TOGBank's AceComm, none refused", function()
		local host = Core:DeltaHost()
		assert.is_true(host.commsRegistered)
		assert.is_nil(host.prefixRegistrationFailed, "the client refused a DeltaSync prefix")
		local n = 0
		for _ in pairs(host.prefixes) do n = n + 1 end
		assert.equal(7, n)
	end)

	it("does NOT run the library's P2P module -- the numbered handshake is TOGBank's own", function()
		assert.is_false(Core:DeltaHost().p2p, "InitP2P was called; per-item hash offers are the design P2P-035 replaced")
	end)

	-- The logger: the library's (category, tag, fmt) / (category, fmt) / (fmt) forms all land in
	-- Output under DELTASYNC, with the library's category as the tag and its own tag joined on.
	it("routes every library debug line into Output under DELTASYNC", function()
		local host = Core:DeltaHost()   -- created first: its own init lines are not the subject
		local seen = {}
		TOGBankClassic_Output.Debug = function(_, ...) seen[#seen + 1] = { n = select("#", ...), ... } return true end
		host:Debug("COMMS", "SEND", "%d bytes", 12)
		host:Debug("INIT", "Initialized %s", "x")
		host:Debug("no category at all %d", 1)
		assert.same({ n = 4, "DELTASYNC", "COMMS-SEND", "%d bytes", 12 }, seen[1])
		assert.same({ n = 4, "DELTASYNC", "INIT", "Initialized %s", "x" }, seen[2])
		assert.same({ n = 3, "DELTASYNC", "no category at all %d", 1 }, seen[3])
	end)

	-- The SEND log names every prefix it sees; the host's seven are generated by the library and
	-- read off the host rather than listed in Constants (commprefix_spec pins Constants to what
	-- Chat registers, and the host registers its own).
	it("names the host's prefixes in the SEND log instead of printing (Unknown)", function()
		local host = Core:DeltaHost()
		local lines = {}
		TOGBankClassic_Output.Debug = function(_, cat, tag, fmt, ...)
			if cat == "COMMS" and tag == "SEND" then lines[#lines + 1] = string.format(fmt, ...) end
			return true
		end
		host:RequestData("Someone", { hash = 0, version = 0, keys = {} })
		assert.equal(1, #lines, "the QUERY did not reach Core's SEND log")
		assert.is_not_nil(lines[1]:find(host.prefixes.QUERY .. " (DeltaSync QUERY)", 1, true),
			"the host's QUERY prefix was logged as: " .. lines[1])
		assert.is_nil(lines[1]:find("(Unknown)", 1, true))
	end)

	it("claims no chat tab of its own -- the logger owns output", function()
		local host = Core:DeltaHost()
		assert.is_nil(host.debugFrame)
		assert.is_false(host.debugEnabled)
	end)

	-- DEBUG-001's three-registry rule, applied to the new category.
	it("registers DELTASYNC in all three debug registries", function()
		assert.equal("DELTASYNC", TOGBankClassic_Constants.DEBUG_CATEGORY.DELTASYNC)
		assert.is_table(TOGBankClassic_Constants.DEBUG_TAGS.DELTASYNC)
		assert.is_not_nil(env.readFile("Modules/Database.lua"):find("DELTASYNC = false", 1, true))
		assert.is_not_nil(env.readFile("Modules/Options.lua"):find("DELTASYNC = {", 1, true))
	end)
end)
