-- RECENTER-001: bring every window back to the middle of the screen, immediately.
--
-- The operator, 2026-09-12: "make a button in settings>appearance to recenter the addon in the
-- middle of the screen. folks have it appearing off screen and they can't drag it." The constraint
-- is the whole feature: the player CANNOT reach the title bar, so anything that asks them to drag,
-- or to find a hidden command and then reload, does not help them. `/togbank wipeframes` was both --
-- expert-only, and it replaced the saved table while every live widget kept a reference to the old
-- one, so nothing on screen moved until a reload.
--
-- The mechanism is AceGUI's, not ours: `ApplyStatus` centres a frame when `status.top` and
-- `status.left` are absent (AceGUIContainer-Frame.lua:152-157, `else frame:SetPoint("CENTER")`).
-- So the reset DELETES those two fields and re-applies, rather than anchoring the frame by hand and
-- leaving the stored coordinates behind to be restored on the next reload.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

describe("RECENTER-001: TOGBankClassic_UI:RecenterWindows", function()
	local UI, created

	--- A stand-in for a live AceGUI Frame: the two fields RecenterWindows touches, and a record of
	--- whether the library's own re-layout was asked for.
	local function liveWidget(status)
		return {
			status  = status,
			applied = 0,
			ApplyStatus = function(self) self.applied = self.applied + 1 end,
		}
	end

	local function positions()
		return TOGBankClassic_Options.db.char.framePositions
	end

	before_each(function()
		env.reset()
		env.standUpClient("Bankchar", { { name = "Bankchar-Testrealm", note = "gbank" } }, "Testguild")
		UI = TOGBankClassic_UI
		-- Options is not stood up by standUpClient, and RecenterWindows reads db.char.framePositions.
		-- Same shape browse_spec uses, so the two specs cannot disagree about where positions live.
		TOGBankClassic_Options.db = TOGBankClassic_Options.db or {}
		TOGBankClassic_Options.db.char = TOGBankClassic_Options.db.char or {}
		TOGBankClassic_Options.db.char.framePositions = {}
		-- RecenterWindows resolves a live window as `_G[entry.module].Window`, and this env does not
		-- load every UI sub-module. Create the missing globals so an example can hand any window a
		-- widget regardless of load order, and REMEMBER which ones were created so after_each can
		-- remove exactly those -- a leaked module global would be a fixture that silently changes
		-- what a later spec file sees.
		created = {}
		for _, entry in ipairs(UI.ALPHA_WINDOWS) do
			if _G[entry.module] then
				_G[entry.module].Window = nil
			else
				_G[entry.module] = {}
				created[#created + 1] = entry.module
			end
		end
	end)

	after_each(function()
		for _, name in ipairs(created or {}) do _G[name] = nil end
		created = nil
	end)

	it("drops the saved coordinates and keeps the saved size", function()
		positions().inventory = { left = -1800, top = 42, width = 550, height = 500 }
		assert.equal(1, UI:RecenterWindows())
		local saved = positions().inventory
		assert.is_nil(saved.left, "the off-screen left coordinate survived and returns on the next reload")
		assert.is_nil(saved.top, "the off-screen top coordinate survived and returns on the next reload")
		assert.equal(550, saved.width, "the window was resized; it was lost, not mis-sized")
		assert.equal(500, saved.height)
	end)

	it("moves an OPEN window now, through the library's own ApplyStatus", function()
		local status = { left = -1800, top = 42, width = 550, height = 500 }
		positions().inventory = status
		local widget = liveWidget(status)
		TOGBankClassic_UI_Inventory.Window = widget

		assert.equal(1, UI:RecenterWindows())
		assert.equal(1, widget.applied, "the open window was never re-laid-out, so it is still off screen")
		assert.is_nil(status.left, "the live status table kept its coordinate; the next drag writes it straight back")
		assert.is_nil(status.top)
	end)

	-- A window built before its saved table was attached reads `localstatus` instead. Clearing only
	-- the saved copy would appear to work and then be undone by the widget's own bookkeeping.
	it("clears localstatus too, for a widget that never had a status table attached", function()
		local widget = liveWidget(nil)
		widget.localstatus = { left = -900, top = 10, width = 300, height = 200 }
		TOGBankClassic_UI_Search.Window = widget

		assert.equal(1, UI:RecenterWindows())
		assert.is_nil(widget.localstatus.left, "localstatus was ignored, so this window stays where it was")
		assert.is_nil(widget.localstatus.top)
		assert.equal(1, widget.applied)
	end)

	it("counts each window once when both its saved and live tables carried a position", function()
		local status = { left = -1800, top = 42 }
		positions().inventory = status
		TOGBankClassic_UI_Inventory.Window = liveWidget(status)
		assert.equal(1, UI:RecenterWindows(), "one window was reported as two")
	end)

	-- Found in the self-audit, not before it. AceGUI's ApplyStatus re-applies the SIZE as well as
	-- the position (`SetWidth(status.width or 700)`), so calling it on a window that needed no
	-- moving resizes it. Mail Viewer, Mailbox and Donations are in ALPHA_WINDOWS but never call
	-- SetStatusTable, so their localstatus carries no width or height at all -- pressing Recenter
	-- with one of those open snapped it to 700x500 for no reason.
	it("does not re-apply the layout of a window that needed no moving", function()
		local widget = liveWidget({ width = 300, height = 200 })   -- on screen, no coordinates
		TOGBankClassic_UI_Inventory.Window = widget
		assert.equal(0, UI:RecenterWindows())
		assert.equal(0, widget.applied,
			"ApplyStatus ran on a window that was not moved -- that re-applies the SIZE and resizes it")
	end)

	it("reports nothing to do when every window is already centred, and still does not error", function()
		positions().inventory = { width = 550, height = 500 }
		TOGBankClassic_UI_Inventory.Window = liveWidget(positions().inventory)
		assert.equal(0, UI:RecenterWindows(),
			"a window with no stored coordinate was counted as moved -- the button would always claim it did something")
	end)

	it("moves every window that has a position, not just the first", function()
		positions().inventory = { left = -1800, top = 42 }
		positions().search    = { left = 9000,  top = -5 }
		positions().requests  = { left = -1,    top = -1 }
		assert.equal(3, UI:RecenterWindows())
		for _, key in ipairs({ "inventory", "search", "requests" }) do
			assert.is_nil(positions()[key].left, key .. " kept its coordinate")
			assert.is_nil(positions()[key].top, key .. " kept its coordinate")
		end
	end)

	it("survives a database that has no saved positions at all", function()
		TOGBankClassic_Options.db.char.framePositions = {}
		assert.equal(0, UI:RecenterWindows())
	end)
end)
