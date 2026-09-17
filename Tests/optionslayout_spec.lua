-- SHOP-SECTION-001 (the operator, 2026-09-15, a screenshot of "Ordering open" sitting under
-- Maximum Request Amount: "this is for shop orders correct, not for non-shop orders? if so, we need
-- to clarify that, as it could be confusing. maybe we make a seperate shop section in the officers
-- tab"): the Officer tab's LAYOUT, read off the real options table the way AceConfigDialog lays it
-- out (by `order`), so the shop's settings are their own section and say "shop orders".
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

describe("SHOP-SECTION-001: the Officer tab's sections", function()
	local officer

	before_each(function()
		env.reset(); env.stubOutput()
		TOGBankClassic_Options = nil
		require("env.frames").reset()   -- real frames: AceConfigDialog builds its popup at load
		require("env.ace").load("AceDB-3.0", "AceConfig-3.0", "AceConfigDialog-3.0")
		env.loadUI()
		env.loadModules({ "Modules/Constants.lua", "Modules/Guild.lua", "Modules/Donations.lua" })
		TOGBankClassic_Guild.Info = { name = "Testguild", alts = {}, requests = {}, settings = {} }
		env.loadFile("Modules/Options.lua")
		TOGBankClassic_Options:Init()
		-- The Officer tab's group is keyed `requests` (its name before the shop and the notes joined it).
		officer = LibStub("AceConfigRegistry-3.0"):GetOptionsTable("TOGBankClassic", "dialog", "Spec-1.0").args.requests.args
	end)
	after_each(function()
		env.releaseBlizOptions()
		TOGBankClassic_Options = nil
	end)

	-- REQUEST-LIMIT-ONE-RULE-001 (self-audit 4777d14a F3): the options getter IS the enforced read.
	it("GetMaxRequestPercent answers what Guild:AddRequest enforces -- clamped and floored -- and clamps its local fallback too", function()
		env.loadFile("Modules/RequestLog.lua")
		local s = TOGBankClassic_Guild.Info.settings
		for _, case in ipairs({ { nil, 100 }, { 33.7, 33 }, { 0, 1 }, { 250, 100 }, { 50, 50 } }) do
			s.maxRequestPercent = case[1]
			assert.equal(case[2], TOGBankClassic_Options:GetMaxRequestPercent(), "stored " .. tostring(case[1]))
			assert.equal(TOGBankClassic_Guild:MaxRequestPercent(), TOGBankClassic_Options:GetMaxRequestPercent())
		end
		-- Before the guild record exists: the local copy, clamped the same way.
		local info = TOGBankClassic_Guild.Info
		TOGBankClassic_Guild.Info = nil
		TOGBankClassic_Options.db.global.requests.maxRequestPercent = 0
		assert.equal(1, TOGBankClassic_Options:GetMaxRequestPercent())
		TOGBankClassic_Options.db.global.requests.maxRequestPercent = 40.9
		assert.equal(40, TOGBankClassic_Options:GetMaxRequestPercent())
		TOGBankClassic_Guild.Info = info
	end)

	--- The entries in the order the panel draws them.
	local function drawn()
		local keys = {}
		for k in pairs(officer) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return (officer[a].order or 0) < (officer[b].order or 0) end)
		return keys
	end

	local function indexOf(list, key)
		for i, k in ipairs(list) do if k == key then return i end end
		error("not drawn: " .. key)
	end

	it("draws the request settings whole, then a Shop section, then Donations and pricing, then the help notes", function()
		local order = drawn()
		-- The request section ends with its own example box, BEFORE the Shop heading.
		assert.is_true(indexOf(order, "maxRequestPercent") < indexOf(order, "exampleGroup"))
		assert.is_true(indexOf(order, "exampleGroup") < indexOf(order, "shopHeader"))
		-- The Shop section: heading, description, then the three shop settings and nothing else.
		assert.equal("header", officer.shopHeader.type); assert.equal("Shop", officer.shopHeader.name)
		assert.equal("description", officer.shopDesc.type)
		assert.same({ "shopHeader", "shopDesc", "shopEnabled", "storeOpen", "storeDiscountPercent", "donationsHeader" },
			{ unpack(order, indexOf(order, "shopHeader"), indexOf(order, "donationsHeader")) })
		-- Then the two settings that apply with or without the shop, under their own heading; then
		-- the sister-guild bank's section (XGUILD-SWITCH-001), then the help notes.
		assert.equal("header", officer.donationsHeader.type)
		assert.same({ "donationsHeader", "donationsDesc", "donationRate", "priceAuthority", "sisterHeader", "sisterDesc", "sisterBank", "helpNotesHeader" },
			{ unpack(order, indexOf(order, "donationsHeader"), indexOf(order, "helpNotesHeader")) })
		assert.equal("toggle", officer.sisterBank.type)
		assert.truthy(officer.sisterBank.desc:find("Guild Roster", 1, true), officer.sisterBank.desc)
		assert.truthy(officer.sisterBank.desc:find("their side too", 1, true), "the tooltip does not say both guilds must switch it on")
		-- Off by default, and the box is the ONE writer's reader.
		assert.is_false(officer.sisterBank.get())
		TOGBankClassic_Guild.Info.settings.sisterBank = true
		assert.is_true(officer.sisterBank.get())
	end)

	it("says SHOP orders on the sign, its box and the closed-ordering sentence", function()
		assert.equal("Shop ordering open", officer.storeOpen.name)
		assert.truthy(officer.storeOpen.desc:find("SHOP orders", 1, true), officer.storeOpen.desc)
		assert.truthy(officer.storeOpen.desc:find("plain bank requests never see it", 1, true), officer.storeOpen.desc)
		assert.truthy(officer.shopDesc.name:find("every order placed is a shop order", 1, true), officer.shopDesc.name)
		assert.truthy(TOGBankClassic_Guild.STORE_CLOSED_TEXT:find("closed shop ordering", 1, true))
		-- And the box is what it says: greyed with the shop off, live with it on.
		assert.is_true(officer.storeOpen.disabled())
		TOGBankClassic_Guild.Info.settings.shopEnabled = true
		assert.is_false(officer.storeOpen.disabled())
	end)
end)

-- VISIBILITY-001: the accessibility scale slider. Same fixture -- the real options table, read as
-- AceConfigDialog reads it -- plus the round trip through the REAL LibAceGUIWidgets, because the
-- whole feature is "the setting reaches the library": a slider that saves a number nothing applies
-- looks identical from the options table alone.
describe("VISIBILITY-001: the Window and Text Size slider", function()
	local general, W

	before_each(function()
		env.reset(); env.stubOutput()
		TOGBankClassic_Options = nil
		require("env.frames").reset()
		require("env.ace").load("AceDB-3.0", "AceConfig-3.0", "AceConfigDialog-3.0")
		-- The REAL library, as the client loads it: its bounds are what the slider declares, and the
		-- round trip below is the feature. A stub with the same three constants would pass the first
		-- example and prove nothing about the second.
		require("env.libs").load("LibAceGUIWidgets-1.0")
		env.loadUI()
		env.loadModules({ "Modules/Constants.lua", "Modules/Guild.lua", "Modules/Donations.lua" })
		TOGBankClassic_Guild.Info = { name = "Testguild", alts = {}, requests = {}, settings = {} }
		env.loadFile("Modules/Options.lua")
		TOGBankClassic_Options:Init()
		general = LibStub("AceConfigRegistry-3.0"):GetOptionsTable("TOGBankClassic", "dialog", "Spec-1.0").args.general.args
		W = LibStub("LibAceGUIWidgets-1.0", true)
	end)
	-- BOTH halves, and the second is the one the reverse-order gate found. The library is ONE
	-- instance for the whole suite, so a scale left set enlarges every later spec file's widgets --
	-- and `TOGBankClassicOptionDB` is a SavedVariable GLOBAL that outlives `env.reset()`, so a
	-- saved 1.5 here is re-applied by the next spec file's own `Options:Init()` however carefully
	-- this one puts the library back. Forward-order runs hid it (this file sorts after the window
	-- specs); reverse order reported five failures across mailbox_spec and browsepersist_spec, each
	-- a window measured at 1.5x its floor. Production is doing exactly the right thing there.
	after_each(function()
		env.releaseBlizOptions()
		TOGBankClassic_Options = nil
		_G.TOGBankClassicOptionDB = nil
		if W and W.SetScale then W:SetScale(W.SCALE_DEFAULT) end
	end)

	it("is a percentage range over the LIBRARY's own bounds, not numbers copied from it", function()
		assert.equal("range", general.uiScale.type)
		assert.is_true(general.uiScale.isPercent)
		assert.equal(0.1, general.uiScale.step)
		assert.is_table(W, "LibAceGUIWidgets is a declared dependency and did not load")
		assert.equal(W.SCALE_MIN, general.uiScale.min)
		assert.equal(W.SCALE_MAX, general.uiScale.max)
		-- Read off the library at load, so a library that widens its range widens the slider.
		assert.equal(W.SCALE_MIN, TOGBankClassic_Options.SCALE_MIN)
		assert.equal(W.SCALE_MAX, TOGBankClassic_Options.SCALE_MAX)
		assert.equal(W.SCALE_DEFAULT, TOGBankClassic_Options.SCALE_DEFAULT)
	end)

	it("starts at the library's normal size and reaches the library when moved", function()
		assert.equal(W.SCALE_DEFAULT, general.uiScale.get())
		assert.equal(W.SCALE_DEFAULT, W:GetScale())
		general.uiScale.set(nil, 1.6)
		assert.equal(1.6, general.uiScale.get(), "the slider does not read back what was set")
		assert.equal(1.6, W:GetScale(), "the setting never reached the library")
		assert.equal(1.6, TOGBankClassic_Options.db.char.uiScale, "it was not saved per character")
	end)

	it("comes back at the saved size on the next login, without the slider being touched", function()
		general.uiScale.set(nil, 1.4)
		W:SetScale(W.SCALE_DEFAULT)                      -- a fresh session: the library is in memory only
		assert.equal(W.SCALE_DEFAULT, W:GetScale())
		TOGBankClassic_Options:ApplyUIScale()            -- what Init does
		assert.equal(1.4, W:GetScale(), "the saved scale was not restored at load")
	end)

	it("clamps a saved value outside the library's range, and reads a missing one as normal size", function()
		TOGBankClassic_Options.db.char.uiScale = 99
		assert.equal(W.SCALE_MAX, TOGBankClassic_Options:GetUIScale())
		TOGBankClassic_Options.db.char.uiScale = 0.1
		assert.equal(W.SCALE_MIN, TOGBankClassic_Options:GetUIScale())
		-- A profile from before the setting existed, and a junk value: normal size, never 0.
		TOGBankClassic_Options.db.char.uiScale = nil
		assert.equal(W.SCALE_DEFAULT, TOGBankClassic_Options:GetUIScale())
		TOGBankClassic_Options.db.char.uiScale = "large"
		assert.equal(W.SCALE_DEFAULT, TOGBankClassic_Options:GetUIScale())
	end)

	it("is silent, not broken, against a library without the scale", function()
		local real = LibStub.libs["LibAceGUIWidgets-1.0"]
		LibStub.libs["LibAceGUIWidgets-1.0"] = { SCALE_MIN = 0.8, SCALE_MAX = 2.0 }   -- no SetScale
		assert.has_no.errors(function() TOGBankClassic_Options:SetUIScale(1.5) end)
		assert.equal(1.5, TOGBankClassic_Options.db.char.uiScale, "the preference is still saved")
		LibStub.libs["LibAceGUIWidgets-1.0"] = real
	end)
end)
