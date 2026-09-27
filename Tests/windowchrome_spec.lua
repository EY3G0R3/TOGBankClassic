-- WINDOW-CHROME-001 -- the bottom row every TOGBank window shares, spelled once.
--
-- SYNCED-001's follow-up ("make the requests window look like the main window"): the title and the
-- status bar were shared; the help "?" was still written out in Inventory, Requests, Search and
-- Browse, the gear in Inventory and Browse, and two of the four pinned the status bar's right edge
-- with a hand-summed constant. UI:DressWindow builds the row, caches it on the frame, ends the bar
-- at the leftmost icon by anchor, and lifts the set above the resize sizers; UI:AnchorStatusBar is
-- the one edge rule, which the Requests cluster moves and hands back.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

-- VISIBILITY-001 part 2: the status bar's three sections read at the accessibility scale. The left
-- one is AceGUI's own FontString on a POOLED Frame, so it must go back to its base font on release.
describe("VISIBILITY-001 part 2: the status bar's text", function()
	it("puts all three sections on the scaled font, and hands AceGUI's own line its base font back on release", function()
		env.reset(); env.stubOutput()
		_G.TOGBankClassic_Guild = nil
		require("env.frames").reset()
		require("env.ace").load("AceGUI-3.0")
		require("env.libs").load("LibAceGUIWidgets-1.0")
		local UI = env.loadUI()
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/UI/StatusBar.lua")
		_G.GameTooltip_SetDefaultAnchor = _G.GameTooltip_SetDefaultAnchor or function() end
		local W = LibStub("LibAceGUIWidgets-1.0")
		local win = UI:Create("Frame")
		win:Hide()
		TOGBankClassic_UI_StatusBar:Attach(win)
		local scaled = W:ScaledFont("GameFontNormal")
		assert.is_not_nil(scaled)
		assert.equal(scaled, win.statusCenter:GetFontObject())
		assert.equal(scaled, win.statusRight:GetFontObject())
		assert.equal(scaled, win.statustext:GetFontObject(), "AceGUI's status line is not on the scaled font")
		local statustext = win.statustext
		win:Release()
		assert.equal("GameFontNormal", statustext:GetFontObject(), "the pooled frame went back to AceGUI still on our scaled font")
	end)
end)

-- POOL-CHROME-001 (Peer Review, F5): AceGUI pools Frames across every addon. A released TOGBank
-- window left its "?", its gear and its status-bar sections shown on the frame, and each Attach built
-- another set of sections on top of the last.
describe("POOL-CHROME-001: a released window hands its frame back clean", function()
	it("hides the chrome and the status-bar sections on release, and the next life reuses them", function()
		env.reset(); env.stubOutput()
		_G.TOGBankClassic_Guild = nil
		require("env.frames").reset()
		require("env.ace").load("AceGUI-3.0")
		require("env.libs").load("LibAceGUIWidgets-1.0")
		local UI = env.loadUI()
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/UI/StatusBar.lua")
		_G.GameTooltip_SetDefaultAnchor = _G.GameTooltip_SetDefaultAnchor or function() end
		TOGBankClassic_Options = { db = { global = {}, char = {} } }

		local win = UI:Create("Frame")
		win:Hide()
		TOGBankClassic_UI_StatusBar:Attach(win)
		UI:DressWindow(win, { settings = { isOpen = false }, help = function() end, share = true })
		win:Show()
		local frame, host, right = win.frame, win.statusCenterHost, win.statusRight
		right:SetText("3 online")
		assert.is_true(frame.togChromeHelp:IsShown()); assert.is_true(frame.togChromeGear:IsShown())
		win:Release()

		-- The next acquirer -- another addon's plain Frame -- sees none of it.
		local other = UI:Create("Frame")
		assert.equal(frame, other.frame, "the pool did not hand the same frame back; this example proves nothing")
		other:Show()
		assert.is_false(frame.togChromeHelp:IsShown(), "our '?' rode along on the next window")
		assert.is_false(frame.togChromeGear:IsShown(), "our gear rode along on the next window")
		assert.is_false(frame.togShareWanted)
		assert.is_false(host:IsShown(), "our status-bar centre rode along on the next window")
		assert.is_false(right:IsShown()); assert.equal("", right:GetText())
		assert.is_nil(other.togStatusBar)
		other:Release()

		-- A TOGBank window on the frame again reuses the sections rather than stacking new ones.
		local again = UI:Create("Frame")
		assert.equal(frame, again.frame)
		TOGBankClassic_UI_StatusBar:Attach(again)
		assert.equal(host, again.statusCenterHost); assert.equal(right, again.statusRight)
		assert.is_true(host:IsShown()); assert.is_true(right:IsShown())
		again:Release()
		_G.TOGBankClassic_Options = nil
	end)
end)

describe("WINDOW-CHROME-001: UI:DressWindow", function()
	local UI, window, wow

	before_each(function()
		env.reset(); env.stubOutput()
		-- SPEC-ALONE-001: this file never uses the real Guild module, and the share button asks it
		-- "am I a bank character?" whenever the (pooled) window SHOWS -- including while this setup
		-- builds the window, before SHARE-BTN-001's stand-in exists. A real Guild an earlier file left
		-- (optionslayout_spec loads one with no Bank module) then errored in Guild:GetPlayer. Absent,
		-- the ask answers "not a banker", which is what every example outside SHARE-BTN-001 expects.
		_G.TOGBankClassic_Guild = nil
		-- The rich frame model and the REAL AceGUI Frame widget (the whole of AceGUI, widgets
		-- included -- env.loadUI alone registers no widget types and Create("Frame") answers nil).
		require("env.frames").reset()
		require("env.ace").load("AceGUI-3.0")
		wow = package.loaded["env.wow"]
		UI = env.loadUI()
		_G.GameTooltip_SetDefaultAnchor = _G.GameTooltip_SetDefaultAnchor or function() end   -- harness gap (audit 1ebe87b4 F5)
		window = UI:Create("Frame")
		window:Hide()
		TOGBankClassic_Options = { db = { global = {}, char = {} } }
	end)

	after_each(function()
		if window then window:Release() end
		_G.TOGBankClassic_Options = nil
	end)

	local function tipText()
		local out = {}
		for _, l in ipairs(GameTooltip:GetLines()) do out[#out + 1] = l.left or "" end
		return table.concat(out, "\n")
	end

	it("puts the '?' at -133,15 (24px) and the gear at -165,17 (20px) on the window's frame, and records both", function()
		local chrome = UI:DressWindow(window, { settings = { isOpen = false }, help = function() end })
		local C = UI.CHROME
		assert.equal(window.togChrome, chrome)
		assert.equal(window.frame, chrome.help:GetParent())
		local point, rel, relPoint, x, y = chrome.help:GetPoint(1)
		assert.equal("BOTTOMRIGHT", point); assert.equal(window.frame, rel); assert.equal("BOTTOMRIGHT", relPoint)
		assert.equal(C.HELP_X, x); assert.equal(C.HELP_Y, y)
		assert.equal(-133, x); assert.equal(15, y)
		assert.equal(24, chrome.help:GetWidth()); assert.equal(24, chrome.help:GetHeight())
		assert.equal(window.frame, chrome.settings:GetParent())
		point, rel, relPoint, x, y = chrome.settings:GetPoint(1)
		assert.equal("BOTTOMRIGHT", point); assert.equal(window.frame, rel); assert.equal("BOTTOMRIGHT", relPoint)
		assert.equal(-165, x); assert.equal(17, y)
		assert.equal(20, chrome.settings:GetWidth())
		-- The gear's centre lines up with the "?"'s: 17 + 10 == 15 + 12.
		assert.equal(C.HELP_Y + C.HELP_SIZE / 2, C.GEAR_Y + C.GEAR_SIZE / 2)
		-- Both are cached on the frame, and the frame's lift set is exactly the row.
		assert.equal(chrome.help, window.frame.togChromeHelp)
		assert.equal(chrome.settings, window.frame.togChromeGear)
		assert.same({ chrome.help, chrome.settings }, chrome.icons)
		assert.equal(chrome.icons, window.togBottomIcons)
		assert.equal(chrome.icons, window.frame.togHitboxButtons)
		assert.equal(chrome.settings, chrome.anchor, "the anchor is not the leftmost icon")
	end)

	it("ends the status bar at the leftmost icon by anchor: the gear, the '?' without one, the last extra with extras", function()
		local statusbg = window.statustext:GetParent()
		local function edge()
			local _, rel, relPoint, x, y = statusbg:GetPoint(2)
			local p1, rel1, rp1, x1, y1 = statusbg:GetPoint(1)
			assert.equal("BOTTOMLEFT", p1); assert.equal(window.frame, rel1); assert.equal("BOTTOMLEFT", rp1)
			assert.equal(15, x1); assert.equal(15, y1)
			assert.equal("BOTTOMLEFT", relPoint); assert.equal(-6, x); assert.equal(0, y)
			return rel
		end
		local chrome = UI:DressWindow(window, { settings = { isOpen = false }, help = function() end })
		assert.equal(chrome.settings, edge(), "with a gear the bar does not end at the gear")

		local plain = UI:Create("Frame")
		plain:Hide()
		local c2 = UI:DressWindow(plain, { help = function() end })
		assert.is_nil(c2.settings)
		assert.equal(c2.help, c2.anchor)
		local _, rel = plain.statustext:GetParent():GetPoint(2)
		assert.equal(c2.help, rel, "without a gear the bar does not end at the '?'")
		plain:Release()

		local arrows = UI:Create("Frame")
		arrows:Hide()
		local prev = CreateFrame("Button", nil, arrows.frame)
		local nxt = CreateFrame("Button", nil, arrows.frame)
		local c3 = UI:DressWindow(arrows, { help = function() end, extra = { prev, nxt } })
		assert.same({ c3.help, prev, nxt }, c3.icons)
		assert.equal(nxt, c3.anchor, "the anchor is not the last extra")
		_, rel = arrows.statustext:GetParent():GetPoint(2)
		assert.equal(nxt, rel, "with extras the bar does not end at the last one")
		assert.equal(c3.icons, arrows.frame.togHitboxButtons, "the extras are not in the lift set")
		arrows:Release()
	end)

	it("reuses the cached icons on a second dress of the same frame, and hides a gear the new window did not ask for", function()
		local first = UI:DressWindow(window, { settings = { isOpen = false }, help = function() end })
		local count = 0
		for _, o in pairs(require("env.frames").objects) do
			if o.GetParent and o:GetParent() == window.frame and (o == first.help or o == first.settings) then count = count + 1 end
		end
		assert.equal(2, count)
		local again = UI:DressWindow(window, { settings = { isOpen = false }, help = function() end })
		assert.equal(first.help, again.help, "a second '?' was built under the first")
		assert.equal(first.settings, again.settings, "a second gear was built under the first")
		-- A pooled frame that came back to a window without a gear: the gear is hidden, not left up.
		local bare = UI:DressWindow(window, { help = function() end })
		assert.is_nil(bare.settings)
		assert.is_false(first.settings:IsShown(), "the previous window's gear stayed showing")
		assert.equal(bare.help, bare.anchor)
		assert.same({ bare.help }, bare.icons)
	end)

	it("the '?' shows the window's own text on hover, after the pre-hook, and hides on leave", function()
		local order = {}
		local chrome = UI:DressWindow(window, {
			onHelpEnter = function() order[#order + 1] = "pre" end,
			help = function()
				order[#order + 1] = "fill"
				GameTooltip:AddLine("This Window -- How It Works")
				GameTooltip:AddLine("Body.", 0.9, 0.9, 0.9, true)
			end,
		})
		chrome.help:GetScript("OnEnter")(chrome.help)
		assert.same({ "pre", "fill" }, order)
		assert.is_true(GameTooltip:IsShown())
		assert.is_true(GameTooltip:IsOwned(chrome.help), "the tooltip is not owned by the '?'")
		assert.equal("This Window -- How It Works\nBody.", tipText())
		chrome.help:GetScript("OnLeave")()
		assert.is_false(GameTooltip:IsShown())
		-- The gear says what it opens.
		local c2 = UI:DressWindow(window, { settings = { isOpen = false }, help = function() end })
		c2.settings:GetScript("OnEnter")(c2.settings)
		assert.equal("TOGBankClassic Settings\n" .. UI.CHROME.GEAR_TOOLTIP, tipText())
		c2.settings:GetScript("OnLeave")()
		assert.is_false(GameTooltip:IsShown())
	end)

	it("the gear opens the options panel and puts a window the panel closed back on the next frame", function()
		local opened, reopened = 0, 0
		local module = { isOpen = true, Open = function() reopened = reopened + 1 end }
		TOGBankClassic_Options.Open = function()
			opened = opened + 1
			module.isOpen = false   -- Blizzard's panel took focus and closed us
		end
		local chrome = UI:DressWindow(window, { settings = module, help = function() end })
		chrome.settings:GetScript("OnClick")(chrome.settings)
		assert.equal(1, opened)
		assert.equal(0, reopened, "reopened before the next frame")
		wow.advanceTime(0.01)
		assert.equal(1, reopened, "a window the options panel closed was not put back")
		-- Still open after the panel: nothing to put back.
		TOGBankClassic_Options.Open = function() opened = opened + 1; module.isOpen = true end
		chrome.settings:GetScript("OnClick")(chrome.settings)
		wow.advanceTime(0.01)
		assert.equal(1, reopened)
		-- A window that was closed when the gear was clicked stays closed.
		module.isOpen = false
		TOGBankClassic_Options.Open = function() opened = opened + 1 end
		chrome.settings:GetScript("OnClick")(chrome.settings)
		wow.advanceTime(0.01)
		assert.equal(1, reopened)
		assert.equal(3, opened)
		-- No options module: the click is inert.
		TOGBankClassic_Options = nil
		chrome.settings:GetScript("OnClick")(chrome.settings)
		assert.equal(3, opened)
	end)

	it("UI:AnchorStatusBar moves the edge to a given frame and back to the chrome's own anchor", function()
		local chrome = UI:DressWindow(window, { settings = { isOpen = false }, help = function() end })
		local statusbg = window.statustext:GetParent()
		local cluster = CreateFrame("Button", nil, window.frame)
		assert.is_true(UI:AnchorStatusBar(window, cluster))
		local _, rel = statusbg:GetPoint(2)
		assert.equal(cluster, rel)
		assert.is_true(UI:AnchorStatusBar(window))
		_, rel = statusbg:GetPoint(2)
		assert.equal(chrome.settings, rel, "the edge did not come back to the window's own leftmost icon")
		-- Nothing to anchor: says so rather than erroring.
		assert.is_false(UI:AnchorStatusBar({ frame = CreateFrame("Frame") }))
		assert.is_false(UI:AnchorStatusBar(nil))
	end)

	-- SHARE-BTN-001 (the operator, 2026-09-16: "for the bankers, we need to add a button to the right
	-- of the gear wheel settings icon that is the /togbank share button. shorten the status bar to
	-- make up for the space").
	describe("SHARE-BTN-001: the share button beside the gear", function()
		local savedGuild, savedChat, banker

		before_each(function()
			savedGuild, savedChat = _G.TOGBankClassic_Guild, _G.TOGBankClassic_Chat
			banker = true
			_G.TOGBankClassic_Guild = {
				GetPlayer = function() return "Banker-Realm" end,
				IsBank = function(_, name) return banker and name == "Banker-Realm" end,
			}
		end)

		after_each(function()
			_G.TOGBankClassic_Guild, _G.TOGBankClassic_Chat = savedGuild, savedChat
		end)

		local function x(f)
			local _, _, _, px = f:GetPoint(1)
			return px
		end

		it("on a bank character: share at the gear's old place, the gear one slot left, the bar ending at the gear", function()
			local C = UI.CHROME
			local chrome = UI:DressWindow(window, { settings = { isOpen = false }, share = true, help = function() end })
			assert.is_not_nil(chrome.share)
			assert.is_true(chrome.share:IsShown())
			assert.equal(window.frame, chrome.share:GetParent())
			assert.equal(-165, x(chrome.share)); assert.equal(C.SHARE_X, x(chrome.share))
			assert.equal(20, chrome.share:GetWidth())
			assert.equal(-193, x(chrome.settings), "the gear did not move left of the share button")
			-- Same 8px gap on both sides: gear | share | "?".
			assert.equal(C.GEAR_X_BESIDE_SHARE + C.SHARE_SIZE + 8, C.SHARE_X)
			assert.equal(C.SHARE_X + 8 + C.HELP_SIZE, C.HELP_X)
			assert.same({ chrome.help, chrome.share, chrome.settings }, chrome.icons)
			assert.equal(chrome.settings, chrome.anchor, "the gear is no longer the leftmost icon")
			local _, rel = window.statustext:GetParent():GetPoint(2)
			assert.equal(chrome.settings, rel, "the status bar does not end at the moved gear")
			assert.equal(chrome.icons, window.frame.togHitboxButtons, "the share button is not in the lift set")
		end)

		it("on any other character: no share button, the gear in its own place", function()
			banker = false
			local chrome = UI:DressWindow(window, { settings = { isOpen = false }, share = true, help = function() end })
			assert.is_false(chrome.share:IsShown())
			assert.equal(UI.CHROME.GEAR_X, x(chrome.settings))
			assert.equal(chrome.settings, chrome.anchor)
		end)

		-- VISIBILITY-001 part 2: the row follows the accessibility scale -- each icon grows about the
		-- row's centre line and the chain moves left by the growth, so nothing overlaps the "?" or
		-- AceGUI's Close button (which does not scale). Real LibAceGUIWidgets.
		it("re-lays the row on the scale signal: sizes, the gap and the chain double at 2x, and come back at 1x", function()
			require("env.libs").load("LibAceGUIWidgets-1.0")
			local W = LibStub("LibAceGUIWidgets-1.0")
			W:SetScale(1)
			local chrome = UI:DressWindow(window, { settings = { isOpen = false }, share = true, help = function() end })
			local function y(f) local _, _, _, _, py = f:GetPoint(1) return py end
			local ok, err = pcall(function()
				W:SetScale(2)
				assert.equal(48, chrome.help:GetWidth());     assert.equal(-133, x(chrome.help)); assert.equal(3, y(chrome.help))
				assert.equal(40, chrome.share:GetWidth());    assert.equal(-133 - 48 - 16, x(chrome.share)); assert.equal(7, y(chrome.share))
				assert.equal(40, chrome.settings:GetWidth()); assert.equal(-197 - 40 - 16, x(chrome.settings)); assert.equal(7, y(chrome.settings))
				W:SetScale(1)
				assert.equal(24, chrome.help:GetWidth()); assert.equal(-133, x(chrome.help)); assert.equal(15, y(chrome.help))
				assert.equal(UI.CHROME.SHARE_X, x(chrome.share)); assert.equal(UI.CHROME.SHARE_Y, y(chrome.share))
				assert.equal(UI.CHROME.GEAR_X_BESIDE_SHARE, x(chrome.settings)); assert.equal(UI.CHROME.GEAR_Y, y(chrome.settings))
			end)
			W:SetScale(1)   -- the library's scale is suite-wide state: never leave it moved, even on a failure
			assert(ok, err)
		end)

		it("asks again every time the window shows, so a banker the roster learns about later gets the button", function()
			banker = false
			local chrome = UI:DressWindow(window, { settings = { isOpen = false }, share = true, help = function() end })
			assert.is_false(chrome.share:IsShown())
			banker = true
			window:Show()
			assert.is_true(chrome.share:IsShown(), "OnShow did not re-check banker status")
			assert.equal(UI.CHROME.GEAR_X_BESIDE_SHARE, x(chrome.settings))
			window:Hide()
			banker = false
			window:Show()
			assert.is_false(chrome.share:IsShown())
			assert.equal(UI.CHROME.GEAR_X, x(chrome.settings))
		end)

		it("SHARE-BTN-LIVE-001: a roster refresh re-decides it on an OPEN window, without a reopen", function()
			local savedBrowse, savedInv = _G.TOGBankClassic_UI_Browse, _G.TOGBankClassic_UI_Inventory
			banker = false
			local chrome = UI:DressWindow(window, { settings = { isOpen = false }, share = true, help = function() end })
			window:Show()
			assert.is_false(chrome.share:IsShown())
			_G.TOGBankClassic_UI_Browse, _G.TOGBankClassic_UI_Inventory = { Window = window }, nil
			banker = true                       -- the roster just recognised the player
			UI:SyncShareButtons()               -- what Guild:RefreshOnlineCache calls
			assert.is_true(chrome.share:IsShown(), "the open window did not get the button")
			assert.equal(UI.CHROME.GEAR_X_BESIDE_SHARE, x(chrome.settings))
			-- A module with no window yet is skipped, not an error.
			_G.TOGBankClassic_UI_Inventory = {}
			UI:SyncShareButtons()
			_G.TOGBankClassic_UI_Browse, _G.TOGBankClassic_UI_Inventory = savedBrowse, savedInv
			-- And Guild:RefreshOnlineCache calls it on both of its return paths.
			local _, calls = env.readFile("Modules/Guild.lua"):gsub("TOGBankClassic_UI:SyncShareButtons%(%)", "")
			assert.equal(2, calls, "RefreshOnlineCache does not re-sync the share button on both of its return paths")
		end)

		it("a click runs the /togbank share command itself", function()
			local ran = {}
			_G.TOGBankClassic_Chat = { ChatCommand = function(_, input) ran[#ran + 1] = input end }
			local chrome = UI:DressWindow(window, { settings = { isOpen = false }, share = true, help = function() end })
			chrome.share:GetScript("OnClick")(chrome.share)
			assert.same({ "share" }, ran)
			chrome.share:GetScript("OnEnter")(chrome.share)
			assert.equal("Share Your Bank\n" .. UI.CHROME.SHARE_TOOLTIP, tipText())
			chrome.share:GetScript("OnLeave")()
			assert.is_false(GameTooltip:IsShown())
		end)

		it("is never built without a gear or without the ask, and a pooled frame dressed without it hides it", function()
			local noGear = UI:DressWindow(window, { share = true, help = function() end })
			assert.is_nil(noGear.share)
			local first = UI:DressWindow(window, { settings = { isOpen = false }, share = true, help = function() end })
			assert.is_true(first.share:IsShown())
			local again = UI:DressWindow(window, { settings = { isOpen = false }, share = true, help = function() end })
			assert.equal(first.share, again.share, "a second share button was built under the first")
			local plain = UI:DressWindow(window, { settings = { isOpen = false }, help = function() end })
			assert.is_nil(plain.share)
			assert.is_false(first.share:IsShown(), "the previous window's share button stayed showing")
			assert.equal(UI.CHROME.GEAR_X, x(plain.settings))
			assert.same({ plain.help, plain.settings }, plain.icons)
		end)

		it("the Guild Bank window and the legacy window both ask for it", function()
			for _, path in ipairs({ "Modules/UI/Browse.lua", "Modules/UI/Inventory.lua" }) do
				assert.truthy(env.readFile(path):find("share = true", 1, true), path .. " does not ask for the share button")
			end
		end)
	end)

	-- The drift this exists to stop: a window growing its own copy of the row again.
	it("every window with a bottom row goes through DressWindow, and none carries its own '?', gear or bar edge", function()
		local windows = { "Modules/UI/Inventory.lua", "Modules/UI/Requests.lua", "Modules/UI/Search.lua", "Modules/UI/Browse.lua" }
		for _, path in ipairs(windows) do
			local src = env.readFile(path)
			assert.truthy(src:find("TOGBankClassic_UI:DressWindow(", 1, true), path .. " does not dress its window through UI:DressWindow")
			assert.is_nil(src:find("help-i", 1, true), path .. " draws its own help icon")
			assert.is_nil(src:find("Trade_Engineering", 1, true), path .. " draws its own gear")
			assert.is_nil(src:find("statustext:GetParent()", 1, true), path .. " anchors the status bar itself")
			-- The one lift outside the helper is the Requests cluster re-lifting with its own icons added.
			local _, lifts = src:gsub("KeepAboveResizeSizers%(", "")
			assert.equal(path == "Modules/UI/Requests.lua" and 1 or 0, lifts, path .. " lifts its own bottom row (DressWindow does)")
		end
	end)
end)
