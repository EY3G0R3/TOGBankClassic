-- WHOLE-ADDON-CLIENT-PROOF (harness contract aa1853c95b31, parts 1 and 2 delivered as 5df0015 and
-- f8495a3): TOGBank's REAL module set loaded into TWO of the harness's own clients, on the harness's
-- own wire -- no setfenv of ours, no bus of ours.
--
-- WHY. env_fleet stood up "several whole clients in one Lua state" by building each client's global
-- environment by hand and carrying a message bus of its own, because the harness could not host a
-- plain-global addon per client (its client-model limit 1). The operator: "why are you doing this
-- instead of building it into the harness with a contract?" (CONGESTION-HARNESS-001). The harness now
-- can; WoWAPITesting built it and said plainly what it could not prove: "that TOGBank's real addon
-- loads this way ... Your MODULE_ORDER is the real test, and it is yours to run." This file is that
-- run, kept as a spec: each client loads the libraries and the addon through `client:loadFile`, the
-- sends go out through the client's real AceCommQueue / AceComm / ChatThrottleLib into `wow.wire`,
-- and the recipient's real AceComm reassembles them. When it holds, env_fleet's client half is
-- ported onto it and deleted.
package.path = "./Tests/?.lua;" .. package.path
local env  = require("env_togbank")
local wow  = require("env.wow")
local ace  = require("env.ace")
local libs = require("env.libs")

local BANK, VIEW = "Bankchar", "Viewer"

-- The dependency order env_fleet proved: ChatThrottleLib BEFORE AceComm-3.0 (AceComm-3.0.lua:21
-- captures it at load).
local ACE_ORDER = { "CallbackHandler-1.0", "AceAddon-3.0", "AceEvent-3.0", "AceTimer-3.0",
	"AceSerializer-3.0", "AceConsole-3.0", "ChatThrottleLib", "AceComm-3.0" }
local LIB_ORDER = { "AceCommQueue-1.0", "LibGuildRoster-1.0", "DeltaSync-1.0", "VersionCheck-1.0", "LibItemDB-1.0" }

--- Load the whole addon into `c` and bring it to the state env_fleet's newClient leaves a client in.
local function standUp(c)
	for _, mod in ipairs(ACE_ORDER) do c:loadFile(ace.pathOf(mod), mod) end
	for _, lib in ipairs(LIB_ORDER) do
		for _, path in ipairs(libs.pathsOf(lib)) do c:loadFile(path, lib) end
	end
	for _, path in ipairs(env.MODULE_ORDER) do c:loadFile(path, "TOGBankClassic") end
	c:loadFile("Modules/UI/StatusBar.lua", "TOGBankClassic")
	c:loadFile("Core.lua", "TOGBankClassic")
	-- WIRE-SKEW-003: the addon version this player runs, per client (`client.addonMetadata`, the
	-- harness's point B6), in the packager's tag form and READ from the addon's own data-leg floor --
	-- the host's fixture says "1.3.2", and a peer on that release is refused the data leg, correctly.
	c.addonMetadata.TOGBankClassic = { Version = "TOGBankClassic-v" .. c.env.TOGBankClassic_Constants.PROTOCOL.DATA_LEG_MIN_ADDON_VERSION }
	c.out = {}
	c:run(function()
		local G = c.env
		G.TOGBankClassic_Output = setmetatable({}, { __index = function(_, key)
			return function(_, ...) c.out[#c.out + 1] = { level = key, n = select("#", ...), ... } return true end
		end })
		G.TOGBankClassic_Database = {
			db = { global = { switches = { sendV2Wire = true }, debugCategories = {}, debugTags = {} }, faction = {} },
			RecordDeltaSent = function() end, RecordDeltaSavings = function() end,
			RecordDeltaComputeTime = function() end, RecordNoChangeSent = function() end,
			RecordDeltaFailed = function() end, RecordDeltaReceived = function() end,
			RecordP2PRequestBroadcast = function() end, RecordP2POffered = function() end,
			RecordP2PBankerFallback = function() end,
		}
		G.TOGBankClassic_Options = {
			IsIntegrityCheckDiagnosticsEnabled = function() return false end,
			IsSyncProgressMuted = function() return true end,
			GetBankEnabled = function() return true end,
			GetAutoTombstoneDays = function() return 30 end,
		}
		G.TOGBankClassic_Inventory_Store:Init({ faction = {} })
		local roster = G.LibStub("LibGuildRoster-1.0")
		local handler = roster.frame:GetScript("OnEvent")
		for _ = 1, (roster.STABLE_THRESHOLD or 2) + 1 do handler(roster.frame, "GUILD_ROSTER_UPDATE") end
		G.TOGBankClassic_Guild.Info = { name = "Testguild", alts = {}, roster = {}, requests = {}, requestsTombstones = {}, settings = {} }
		G.TOGBankClassic_Guild:RefreshOnlineCache()
		G.TOGBankClassic_Chat:Init()
		G.TOGBankClassic_Core:DeltaHost()
		G.TOGBankClassic_Bank.eventsRegistered = false
		G.TOGBankClassic_MailInventory.hasUpdated = false
	end)
	return c
end

local function errors(c)
	local out = {}
	for _, o in ipairs(c.out) do
		if o.level == "Error" then
			local ok, s = pcall(string.format, tostring(o[1]), unpack(o, 2, o.n))
			out[#out + 1] = ok and s or tostring(o[1])
		end
	end
	return out
end

describe("WHOLE-ADDON-CLIENT-PROOF: TOGBank in two of the harness's own clients", function()
	local bank, view

	before_each(function()
		env.reset({ frames = true })
		env.addGuildMember(BANK .. "-Testrealm", { note = "gbank" })
		env.addGuildMember(VIEW .. "-Testrealm", {})
		bank = standUp(wow.client(BANK))
		view = standUp(wow.client(VIEW))
	end)

	it("each client's addon globals are its own: two Guilds, two Cores, two P2P modules, neither the host's", function()
		for _, name in ipairs({ "TOGBankClassic_Guild", "TOGBankClassic_Core", "TOGBankClassic_P2P", "TOGBankClassic_Inventory_Store" }) do
			assert.is_table(rawget(bank.env, name), name .. " did not land in the banker's env")
			assert.is_table(rawget(view.env, name), name .. " did not land in the viewer's env")
			assert.are_not.equal(rawget(bank.env, name), rawget(view.env, name), name .. " is shared between the clients")
			-- The host's copy (another spec file may have loaded the addon onto the shared _G) is
			-- neither client's.
			assert.are_not.equal(rawget(_G, name), rawget(bank.env, name), name .. " is the host's copy")
			assert.are_not.equal(rawget(_G, name), rawget(view.env, name), name .. " is the host's copy")
		end
		assert.equal(BANK .. "-Testrealm", bank:run(function() return bank.env.TOGBankClassic_Guild:GetNormalizedPlayer() end))
		assert.equal(VIEW .. "-Testrealm", view:run(function() return view.env.TOGBankClassic_Guild:GetNormalizedPlayer() end))
		assert.is_true(bank:run(function() return bank.env.TOGBankClassic_Guild:IsBank(BANK .. "-Testrealm") end))
		assert.same({}, errors(bank)); assert.same({}, errors(view))
	end)

	it("the banker's login cycle reaches the viewer over the harness's wire, and the viewer holds the bank", function()
		bank:run(function()
			env.setBag(0, 16, { { id = 2589, count = 20 }, { id = 2592, count = 7 } })
			env.setBag(-1, 24, {})
			bank.money = 100
			bank.env.TOGBankClassic_Bank.hasUpdated = true
			bank.env.TOGBankClassic_Bank:Scan()
			bank.env.TOGBankClassic_Events:SyncDeltaVersion("NORMAL")
		end)
		env.advance(10)
		-- The broadcast left the banker as chunks on the harness's own wire.
		local fromBank = wow.wireTrace({ from = BANK })
		assert.is_true(#fromBank > 0, "nothing the banker sent reached wow.wire:\n" .. wow.formatWire({}))
		view:run(function() view.env.TOGBankClassic_Events:SyncDeltaVersion("NORMAL") end)
		env.advance(90)
		assert.is_true(#wow.wireTrace({ from = VIEW }) > 0, "nothing the viewer sent reached wow.wire:\n" .. wow.formatWire({}))
		local function held(c)
			return c:run(function()
				local Store = c.env.TOGBankClassic_Inventory_Store
				local out = {}
				for _, r in ipairs(Store:GetAltView("Testguild", BANK .. "-Testrealm") or {}) do out[r.ID] = (out[r.ID] or 0) + r.Count end
				return out
			end)
		end
		local function debugLines(c)
			local out = {}
			for _, o in ipairs(c.out) do
				local ok, s = pcall(string.format, tostring(o[3] or o[1]), unpack(o, 4, o.n))
				out[#out + 1] = tostring(o[1]) .. "/" .. tostring(o[2]) .. ": " .. (ok and s or tostring(o[3]))
			end
			return table.concat(out, "\n")
		end
		assert.same(held(bank), held(view), "the viewer does not hold what the banker holds\nWIRE:\n" .. wow.formatWire({})
			.. "\nVIEWER OUTPUT:\n" .. debugLines(view))
		assert.equal(20, held(view)[2589])
		assert.same({}, errors(bank)); assert.same({}, errors(view))
	end)
end)
