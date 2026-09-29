-- ESC-001: Escape closes TOG Bank's windows, and a setting turns that off.
--
-- A player, 2026-09-25: "Bank doesnt close with esc press, but togpm does". The operator: "the esc
-- behaviour needs to be a setting, so that it either doesn't close on escape, or does ... it should
-- have esc close the window by default."
--
-- The defect was the Guild Bank window -- what /togbank and the minimap button open -- getting
-- Escape only if the Inventory, Search, Requests or Donations window had been opened first in the
-- session: those four created the escape frame, and the Guild Bank window only showed it when it
-- already existed. So every example here opens the Guild Bank window FIRST AND ALONE.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

--- Blizzard's own Escape step, body for body: Classic Era
--- Blizzard_UIParentPanelManager/Shared/UIParentPanelManager.lua:1041. Every shown frame named in
--- UISpecialFrames is hidden, and a truthy return is what stops the game menu opening.
local function pressEscape()
	local found
	for _, name in pairs(UISpecialFrames) do
		local frame = _G[name]
		if frame and frame:IsShown() then
			frame:Hide()
			found = 1
		end
	end
	return found
end

--- Is anything of OURS on the Escape list and shown -- i.e. would Escape stop at TOG Bank rather
--- than open the game menu? Blizzard's seeded entries are not shown in the harness.
local function oursCatchesEscape()
	for _, name in ipairs(UISpecialFrames) do
		local frame = _G[name]
		if name:find("^TOGBankClassic") and frame and frame:IsShown() then return true end
	end
	return false
end

describe("ESC-001: Escape and the Guild Bank window", function()
	local Browse, UI

	before_each(function()
		env.reset()
		require("env.frames").reset()
		env.stubOutput()
		require("env.libs").load("LibAceGUIWidgets-1.0")
		env.loadFile("Modules/Constants.lua")
		env.loadModules({ "Modules/Inventory/Record.lua", "Modules/Inventory/Resolve.lua", "Modules/Inventory/Store.lua" })
		UI = env.loadUI()
		env.loadFile("Modules/UI/Search.lua")
		env.loadFile("Modules/UI/RowList.lua")
		env.loadFile("Modules/Usable.lua")
		env.loadFile("Modules/UI/Browse.lua")
		Browse = TOGBankClassic_UI_Browse
		TOGBankClassicInvDB = nil
		TOGBankClassic_Inventory_Store.db = nil
		TOGBankClassic_Inventory_Store:Init()
		TOGBankClassic_Guild = {
			Info = { name = "Testguild", alts = {}, roster = { alts = {} } },
			GetRosterAlts = function() return {} end,
			NormalizeName = function(_, n) return n and (n:find("-") and n or n .. "-Testrealm") or nil end,
			GetNormalizedPlayer = function() return "Bankchar-Testrealm" end,
			IsBank = function() return false end,
			IsViewOnlyBank = function() return false end,
			IsPlayerOnline = function() return false end,
			GetAltStaleness = function() return "current", 1757000000, 1757000000 end,
			GetAltItems = function() return {} end,
		}
		TOGBankClassic_Bank = TOGBankClassic_Bank or {}
		TOGBankClassic_UI_StatusBar = { AttachSides = function() return {} end }
		TOGBankClassic_Options = {
			db = { global = { helpSeen = {} }, char = { framePositions = {}, browseTab = "browse" } },
		}
		Browse:Init()
	end)

	after_each(function()
		-- SUITE-HEAP-001: each example builds a fresh window; hand it (and Search's) back.
		for _, module in ipairs({ Browse, TOGBankClassic_UI_Search }) do
			if module and module.Window then env.releaseWindow(module.Window); module.Window = nil end
		end
		TOGBankClassic_UI_Browse = nil
	end)

	it("is on by default: nothing stored reads as 'Escape closes'", function()
		-- Nothing Escape-related is stored at all, found by scanning rather than by naming the key.
		local stored = {}
		for k in pairs(TOGBankClassic_Options.db.global) do
			if type(k) == "string" and k:lower():find("escape", 1, true) then stored[#stored + 1] = k end
		end
		assert.same({}, stored, "an Escape setting is stored before the player chose one")
		assert.is_true(UI:CloseOnEscape())
	end)

	it("closes the Guild Bank window opened on its own -- the player's report", function()
		Browse:Open("browse")
		assert.is_true(Browse.Window.frame:IsShown())
		assert.is_true(oursCatchesEscape(), "nothing of TOG Bank's is on the Escape list while its window is open")
		assert.is_truthy(pressEscape())
		assert.is_false(Browse.isOpen, "Escape left the Guild Bank window open")
		assert.is_false(Browse.Window.frame:IsShown())
	end)

	it("closes it on EVERY Escape, not only the first of the session", function()
		for round = 1, 3 do
			Browse:Open("browse")
			pressEscape()
			assert.is_false(Browse.isOpen, "round " .. round .. ": Escape did not close the window")
		end
	end)

	it("lets Escape reach the game menu once the window is closed", function()
		Browse:Open("browse")
		Browse:Close()
		assert.is_false(oursCatchesEscape(),
			"a closed window still catches Escape -- the game menu would not open")
	end)

	it("puts one entry on the Escape list however often the window opens", function()
		for _ = 1, 3 do Browse:Open("browse"); Browse:Close() end
		local count = 0
		for _, name in ipairs(UISpecialFrames) do
			if name:find("^TOGBankClassic") then count = count + 1 end
		end
		assert.equal(1, count)
	end)

	it("leaves the window open when the setting is off", function()
		assert.is_true(UI:SetCloseOnEscape(false))
		assert.is_false(UI:CloseOnEscape())
		Browse:Open("browse")
		assert.is_false(oursCatchesEscape(), "the setting is off and TOG Bank still catches Escape")
		pressEscape()
		assert.is_true(Browse.isOpen, "Escape closed the window with the setting off")
	end)

	it("applies a change to the window already open, both ways", function()
		Browse:Open("browse")
		UI:SetCloseOnEscape(false)
		assert.is_false(oursCatchesEscape(), "turning it off did not release Escape")
		assert.is_true(Browse.isOpen, "turning the setting off closed the window")
		UI:SetCloseOnEscape(true)
		assert.is_true(oursCatchesEscape(), "turning it back on did not take Escape for the open window")
		pressEscape()
		assert.is_false(Browse.isOpen)
	end)

	it("closes the Search window too, and the Guild Bank window with it", function()
		Browse:Open("browse")
		TOGBankClassic_UI_Search:Open()
		assert.is_true(TOGBankClassic_UI_Search.isOpen)
		pressEscape()
		assert.is_false(TOGBankClassic_UI_Search.isOpen, "Escape left the Search window open")
		assert.is_false(Browse.isOpen, "Escape left the Guild Bank window open")
		assert.is_false(oursCatchesEscape())
	end)

	it("keeps Escape for the Guild Bank window when another window closes first", function()
		Browse:Open("browse")
		TOGBankClassic_UI_Search:Open()
		TOGBankClassic_UI_Search:Close()
		assert.is_true(Browse.isOpen, "closing Search closed the Guild Bank window")
		assert.is_true(oursCatchesEscape(), "closing Search took Escape away from the Guild Bank window")
	end)

	-- Self-audit 35130c29 F1: the owner dialog is the Guild Bank window's own; Escape closing the
	-- window must not leave it alone on screen.
	it("closes the 'Who runs this bank' dialog with the Guild Bank window", function()
		Browse:Open("bankers")
		local dialog = Browse:EnsureOwnerDialog()
		dialog:Show()
		assert.is_true(dialog.frame:IsShown(), "fixture: the dialog did not open")
		pressEscape()
		assert.is_false(Browse.isOpen)
		assert.is_false(dialog.frame:IsShown(), "the owner dialog stayed open after the Guild Bank window closed")
	end)

	-- Alt+Z hides UIParent, and the stand-in with it. That is not an Escape: the window must stay.
	it("does not close anything when the stand-in is hidden with its parent", function()
		Browse:Open("browse")
		local proxy = assert(_G.TOGBankClassicEscProxy, "no stand-in was made")
		local hides = 0
		proxy:HookScript("OnHide", function() hides = hides + 1 end)
		UIParent:Hide()
		UIParent:Show()
		assert.equal(1, hides, "the parent hide never reached the stand-in, so this example proves nothing")
		assert.is_true(Browse.isOpen, "hiding the whole UI closed the window")
	end)
end)
