-- BROWSE-006: the Guild Bank window remembers where it was, how big it was, and which tab it was on.
--
-- The operator, 2026-09-12: "save the position/size/last tab of the new UI to SV so it persists
-- through UI open/close and game login/logout." It was the only window that did not: Inventory,
-- Search and Requests all attach a status table to db.char.framePositions, and this one had a hard
-- SetWidth(900)/SetHeight(540) pair instead, so it reopened centred at the default size every time.
--
-- Position and size are AceGUI's own doing once a status table is attached -- it writes top/left/
-- width/height on every drag and resize and reads them back through ApplyStatus -- so the examples
-- here prove the table is ATTACHED and is the SAVED one, not that AceGUI works. The tab is ours.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

describe("BROWSE-006: the Guild Bank window persists its position, size and tab", function()
	local Browse

	local function db()
		return TOGBankClassic_Options.db
	end

	--- The window half needs the real UI stack, the same way browse_spec's own loadBrowse builds it.
	--- Factored out because two examples rebuild it from scratch to prove the REOPEN case, which is
	--- the whole point of persisting anything.
	local function standUp(positions, tab)
		-- SUITE-HEAP-001: an example that stands up a second world releases the first world's window.
		if Browse and Browse.Window then env.releaseWindow(Browse.Window); Browse.Window = nil end
		env.reset()
		require("env.frames").reset()
		env.stubOutput()
		require("env.libs").load("LibAceGUIWidgets-1.0")
		env.loadFile("Modules/Constants.lua")
		env.loadModules({ "Modules/Inventory/Record.lua", "Modules/Inventory/Resolve.lua", "Modules/Inventory/Store.lua" })
		env.loadUI()
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
			db = { global = { helpSeen = {} }, char = { framePositions = positions or {}, browseTab = tab or "browse" } },
		}
		Browse:Init()
		return Browse
	end

	before_each(function() standUp() end)

	after_each(function()
		-- SUITE-HEAP-001: every example builds a fresh window; hand it back so it does not stay alive
		-- (through AceGUI's tab globals) for the rest of the run.
		if Browse and Browse.Window then env.releaseWindow(Browse.Window); Browse.Window = nil end
		TOGBankClassic_UI_Browse = nil
	end)

	describe("RememberedTab", function()
		it("returns the saved tab", function()
			db().char.browseTab = "bankers"
			assert.equal("bankers", Browse:RememberedTab())
		end)

		-- The saved value outlives the build that wrote it. A tab that no longer exists must not be
		-- handed to SelectTab, which would match nothing and open the window on a blank body.
		it("falls back to Browse for a tab name that no longer exists", function()
			db().char.browseTab = "grid"
			assert.equal("browse", Browse:RememberedTab(),
				"a stale tab name was trusted -- SelectTab matches nothing and the window opens blank")
		end)

		it("falls back to Browse with nothing saved, and survives no database at all", function()
			db().char.browseTab = nil
			assert.equal("browse", Browse:RememberedTab())
			TOGBankClassic_Options = nil
			assert.equal("browse", Browse:RememberedTab())
		end)

		it("accepts every tab the window actually renders", function()
			-- Driven off the window's OWN list, so a tab added to the strip without being accepted
			-- here fails rather than silently falling back to Browse on the next login.
			assert.is_true(#Browse.TABS >= 3)
			for _, entry in ipairs(Browse.TABS) do
				db().char.browseTab = entry.value
				assert.equal(entry.value, Browse:RememberedTab(), entry.value .. " is rendered but not remembered")
			end
		end)
	end)

	describe("RememberTab", function()
		it("writes the tab to the saved variables and to the live field", function()
			Browse:RememberTab("bankers")
			assert.equal("bankers", db().char.browseTab, "the tab was not saved, so it is forgotten at logout")
			assert.equal("bankers", Browse.currentTab)
		end)

		it("does not error when there is no database", function()
			TOGBankClassic_Options = nil
			Browse:RememberTab("requests")
			assert.equal("requests", Browse.currentTab)
		end)

		it("round-trips through RememberedTab", function()
			Browse:RememberTab("requests")
			Browse.currentTab = nil
			assert.equal("requests", Browse:RememberedTab())
		end)
	end)

	describe("the window's status table", function()
		it("is the SAVED table, so AceGUI's own writes land in the saved variables", function()
			Browse:DrawWindow()
			local saved = db().char.framePositions.browse
			assert.is_table(saved, "no status table was stored for this window -- nothing persists")
			assert.equal(saved, Browse.Window.status,
				"the window is using a table that is not the saved one, so drags and resizes are lost")
		end)

		it("defaults to the window's own size, and does not overwrite a saved one", function()
			Browse:DrawWindow()
			assert.equal(900, db().char.framePositions.browse.width)
			assert.equal(540, db().char.framePositions.browse.height)

			-- A second window built against a table the player has already resized and moved must
			-- keep those values -- this is the reopen-after-logout case, and the whole feature.
			standUp({ browse = { width = 1200, height = 800, top = 700, left = 250 } })
			Browse:DrawWindow()
			local kept = TOGBankClassic_Options.db.char.framePositions.browse
			assert.equal(1200, kept.width, "the saved width was overwritten by the default")
			assert.equal(800, kept.height, "the saved height was overwritten by the default")
			assert.equal(700, kept.top, "the saved position was discarded")
			assert.equal(250, kept.left)
		end)

		it("still builds a window when the database has no framePositions table", function()
			TOGBankClassic_Options.db.char.framePositions = nil
			Browse:DrawWindow()
			assert.is_table(Browse.Window, "the window failed to build without a positions table")
		end)
	end)

	-- BROWSE-007: the operator, 2026-09-12, with a screenshot of `Sent` and `Actions` past the right
	-- border: "the window can shrink smaller than the columns, and the column headers float outside
	-- the window." This window hosts the Requests body, whose column table cannot lay out below the
	-- sum of its column minimums (972), and its own floor was 760 with a default of 900 -- so it could
	-- be dragged, or simply opened, narrower than the tab it was showing. The REAL Requests body is
	-- loaded here so the number under test is the one the columns actually add up to.
	describe("BROWSE-007: the window cannot be narrower than the Requests tab", function()
		local R
		before_each(function()
			env.loadModules({ "Modules/Item.lua" })
			env.loadFile("Modules/UI/Requests.lua")
			R = TOGBankClassic_UI_Requests
			assert.is_function(R.MinWidth, "Requests publishes no minimum width -- nothing can size the host to it")
			assert.is_true(R:MinWidth() > 760, "precondition: the Requests floor must exceed the window's own, or this proves nothing")
		end)

		it("sets its resize floor to the Requests floor, and defaults no narrower", function()
			Browse:DrawWindow()
			local minW, minH = Browse.Window.frame:GetResizeBounds()
			assert.equal(R:MinWidth(), minW, "the sizer still lets the window go narrower than the Requests columns")
			assert.equal(380, minH)
			assert.is_true(db().char.framePositions.browse.width >= R:MinWidth(),
				"the default width is below the Requests floor -- a fresh window opens with the headers past the border")
		end)

		it("clamps a saved size below the floor on open, and leaves a larger one alone", function()
			standUp({ browse = { width = 700, height = 300, top = 700, left = 250 } })
			env.loadFile("Modules/UI/Requests.lua")
			Browse:DrawWindow()
			local saved = TOGBankClassic_Options.db.char.framePositions.browse
			assert.equal(TOGBankClassic_UI_Requests:MinWidth(), saved.width,
				"a saved width below the floor was applied as-is -- resize bounds do not stop AceGUI's ApplyStatus")
			assert.equal(380, saved.height)
			assert.equal(700, saved.top, "the saved position was lost while clamping the size")
			assert.equal(250, saved.left)
			standUp({ browse = { width = 1200, height = 800 } })
			env.loadFile("Modules/UI/Requests.lua")
			Browse:DrawWindow()
			assert.equal(1200, TOGBankClassic_Options.db.char.framePositions.browse.width, "a larger saved width was clamped down")
		end)

		it("keeps its own floor when the Requests body is not loaded", function()
			TOGBankClassic_UI_Requests = nil
			local w, h = Browse.ResizeFloor()
			assert.equal(760, w); assert.equal(380, h)
		end)
	end)

	-- SCALE-FLOOR-001: a player's report against v1.6.0 (2026-09-17, the Window and Text Size slider at
	-- 80%): "Window size at minimum has widget overflow after resizing/reloading text in config". The
	-- library multiplies a window's floor by the accessibility scale, so at 80% the floor was 80% of
	-- the normal one -- while the Browse strip's stock dropdowns, edit boxes, checkbox and button keep
	-- their fixed widths (only their text scales), so at the minimum they ran past the border. And a
	-- scale change on a LIVE window changed nothing about its bounds (the library re-applies them only
	-- through a resize handle, which an AceGUI Frame has none of), so the old floor stayed until the
	-- next reload. Real LibAceGUIWidgets and the real Requests body: the floor under test is the sum
	-- the columns add up to.
	describe("SCALE-FLOOR-001: the floor never drops below the normal-size floor, and follows a live scale change", function()
		local W, R
		before_each(function()
			env.loadModules({ "Modules/Item.lua" })
			env.loadFile("Modules/UI/Requests.lua")
			R = TOGBankClassic_UI_Requests
			W = LibStub("LibAceGUIWidgets-1.0")
			W:SetScale(1)
		end)
		-- The library's scale is suite-wide state: never leave it moved, even on a failure.
		after_each(function() if W then W:SetScale(1) end end)

		--- The width the strip's FIRST row needs: its five controls side by side with the Table
		--- layout's gaps between them. The stock controls' widths are what they were given (150, 130,
		--- 140, 110); only the search box scales.
		local function stripRowNeeds(strip)
			local cols = strip:GetUserData("table")
			local total, n = 0, 0
			for i = 1, math.min(5, #strip.children) do
				total = total + (strip.children[i].frame:GetWidth() or 0)
				n = n + 1
			end
			return total + (cols.spaceH or 0) * (n - 1)
		end

		it("keeps the 100% floor at 80%, so the Browse strip still fits at the minimum", function()
			W:SetScale(0.8)
			Browse:DrawWindow()
			local minW, minH = Browse.Window.frame:GetResizeBounds()
			assert.equal(R:MinWidth(), minW,
				"the floor shrank with the scale -- the strip's dropdowns did not, and spill past the border at the minimum")
			assert.equal(380, minH)
			assert.equal(900, db().char.framePositions.browse.width, "the default width (above the floor) was changed")
			-- The symptom itself: at the floor, the strip's first row fits inside the window.
			Browse:Open("browse")
			assert.is_true(stripRowNeeds(Browse.FilterStrip) <= minW,
				("the strip needs %d px and the window can be %d px: the controls run past the border"):format(stripRowNeeds(Browse.FilterStrip), minW))
		end)

		it("still enlarges the floor above 100%, where the rows and the strip really do grow", function()
			W:SetScale(2)
			Browse:DrawWindow()
			local minW, minH = Browse.Window.frame:GetResizeBounds()
			assert.equal(2 * R:MinWidth(), minW)
			assert.equal(760, minH)
			assert.equal(2 * R:MinWidth(), db().char.framePositions.browse.width, "a default under the doubled floor was applied as-is")
		end)

		-- Found by this session's own audit, not by a failure: the record that carries the scale
		-- registration lives ON the widget, and `Requests:ReleaseWindow` hands its widget back to
		-- AceGUI's LIBRARY-WIDE pool (its own comment: "a faded frame released here can turn up as
		-- another addon's window"). A listener left behind would re-apply this window's size, position
		-- and saved table to whoever acquired that frame next -- so their drags would write into
		-- TOGBank's SavedVariables and ours into theirs.
		it("drops the scale registration when a window is released, so a pooled frame is never re-applied to", function()
			Browse:DrawWindow()
			local window = Browse.Window
			local rec = window._togPersist
			assert.is_table(rec, "the window carries no persistence record, so this proves nothing")
			assert.equal(window, rec.window)
			assert.is_true(TOGBankClassic_UI:ForgetPersistedWindow(window))
			assert.is_nil(window._togPersist, "the record is still on the widget going back to the pool")
			assert.is_nil(rec.window, "the record still points at the released widget")
			-- The listener is gone: a scale change must not touch the frame through it. Driven by
			-- moving the scale for real and checking the frame was left alone.
			local w, h = window.frame:GetWidth(), window.frame:GetHeight()
			W:SetScale(2)
			assert.equal(w, window.frame:GetWidth(), "a released window was resized by the scale signal")
			assert.equal(h, window.frame:GetHeight())
			assert.is_false(TOGBankClassic_UI:ForgetPersistedWindow(window), "forgetting twice should report nothing to do")
			assert.is_false(TOGBankClassic_UI:ForgetPersistedWindow(nil))
		end)

		-- SCALE-FLOOR-002: a ClearFrame carries the library's resize handle, made ONCE in its constructor.
		-- Releasing it must hand the pooled frame back with its grips and its own 400 x 200 floor, not
		-- TOGBank's -- the first version of this fix Destroyed the handle and left the next owner a
		-- window that could not be resized (found by the session's own audit).
		it("a released ClearFrame keeps its resize grips and gets its own floor back", function()
			local cf = TOGBankClassic_UI:Create("ClearFrame")
			local handle = W:GetResizeHandle(cf)
			assert.is_table(handle, "precondition: a ClearFrame without the library's resize handle proves nothing")
			local ownW, ownH = handle.minW, handle.minH
			TOGBankClassic_UI:PersistWindow(cf, "sfloor002", 1200, 800, R:MinWidth(), 380)
			assert.is_true(handle.minW > ownW, "precondition: PersistWindow did not raise the handle's floor")
			assert.is_true(TOGBankClassic_UI:ForgetPersistedWindow(cf))
			assert.equal(ownW, handle.minW, "the pooled ClearFrame still carries TOGBank's floor")
			assert.equal(ownH, handle.minH)
			assert.is_table(handle.grips.SE, "the release took the frame's resize grips away from its next owner")
			cf:Release()
		end)

		-- The assumption the whole re-apply rests on, and the one I could not state as verified when I
		-- filed the audit: re-running PersistWindow goes through AceGUI's ApplyStatus, which
		-- ClearAllPoints and re-points -- to the SAVED top/left when both are there, and to CENTER when
		-- they are not. So a scale change must not move a window the player has dragged, and must not
		-- move one they have never dragged either (it is already centred). Asserted rather than reasoned.
		it("a scale change does not move a window: a dragged one keeps its saved position, an undragged one stays centred", function()
			standUp({ browse = { width = 1200, height = 800, top = 700, left = 250 } })
			env.loadFile("Modules/UI/Requests.lua")
			Browse:DrawWindow()
			local saved = TOGBankClassic_Options.db.char.framePositions.browse
			W:SetScale(2)
			assert.equal(700, saved.top, "the scale change lost the saved top")
			assert.equal(250, saved.left, "the scale change lost the saved left")
			W:SetScale(1)
			assert.equal(700, saved.top); assert.equal(250, saved.left)

			-- No saved position: the point before and after must be the same one.
			standUp()
			env.loadFile("Modules/UI/Requests.lua")
			Browse:DrawWindow()
			local frame = Browse.Window.frame
			local before = { frame:GetPoint(1) }
			assert.is_nil(TOGBankClassic_Options.db.char.framePositions.browse.top, "precondition: this window must have no saved position")
			W:SetScale(2)
			assert.same(before, { frame:GetPoint(1) },
				"a scale change moved a window the player had never dragged")
		end)

		it("re-applies the floor on a live scale change, raises a window sitting under it, and never shrinks one", function()
			standUp({ browse = { width = R:MinWidth(), height = 380, top = 700, left = 250 } })
			env.loadFile("Modules/UI/Requests.lua")
			R = TOGBankClassic_UI_Requests
			Browse:DrawWindow()
			local frame = Browse.Window.frame
			assert.equal(R:MinWidth(), frame:GetWidth())
			W:SetScale(2)
			local minW, minH = frame:GetResizeBounds()
			assert.equal(2 * R:MinWidth(), minW, "the bounds set at draw time stayed at the old scale")
			assert.equal(760, minH)
			assert.equal(2 * R:MinWidth(), frame:GetWidth(), "the window was left under its new floor with twice the text inside")
			assert.equal(760, frame:GetHeight())
			local saved = TOGBankClassic_Options.db.char.framePositions.browse
			assert.equal(2 * R:MinWidth(), saved.width, "the raise did not reach the saved size, so a reload would undo it")
			assert.equal(700, saved.top, "the position was lost in the re-apply"); assert.equal(250, saved.left)
			W:SetScale(1)
			minW, minH = frame:GetResizeBounds()
			assert.equal(R:MinWidth(), minW); assert.equal(380, minH)
			assert.equal(2 * R:MinWidth(), frame:GetWidth(), "a scale-down shrank the window the player had sized")
			W:SetScale(0.8)
			minW = frame:GetResizeBounds()
			assert.equal(R:MinWidth(), minW, "under 100% the floor dropped below the normal one")
		end)
	end)

	-- SCALE-DOCK-001: the residual Peer Review handed back on the SCALE-FLOOR-001 thread (593238c3).
	-- The example above proves a scale change does not move a window AceGUI positions. It does move a
	-- window TOGBank positions: ApplyStatus runs ClearAllPoints unconditionally, so a window docked to
	-- the Inventory window's edge by hand loses that anchor the first time the player touches the
	-- slider, and the cluster comes apart while the Inventory window stays put. Two of the five
	-- persisted windows dock: Search and Requests.
	describe("SCALE-DOCK-001: a window that anchors itself keeps its anchor across a scale change", function()
		local W, inventoryFrame, savedInventory

		before_each(function()
			W = TOGBankClassic_UI.Widgets
			savedInventory = TOGBankClassic_UI_Inventory
			inventoryFrame = CreateFrame("Frame", nil, UIParent)
			TOGBankClassic_UI_Inventory = { isOpen = true, Window = { frame = inventoryFrame } }
			if W then W:SetScale(1) end
		end)

		-- The library's scale is suite-wide state and the Inventory stand-in is a global: restore both
		-- here rather than at the end of an example, so a red assertion cannot leak either.
		after_each(function()
			if W then W:SetScale(1) end
			TOGBankClassic_UI_Inventory = savedInventory
		end)

		describe("DockBesideInventory", function()
			it("sits on either edge of the Inventory window, and reports what it did", function()
				Browse:DrawWindow()
				local frame = Browse.Window.frame

				assert.is_true(TOGBankClassic_UI:DockBesideInventory(Browse.Window, "RIGHT"))
				local point, relativeTo, relPoint = frame:GetPoint(1)
				assert.equal("TOPLEFT", point)
				assert.equal(inventoryFrame, relativeTo, "the window did not anchor to the Inventory window")
				assert.equal("TOPRIGHT", relPoint)

				assert.is_true(TOGBankClassic_UI:DockBesideInventory(Browse.Window, "LEFT"))
				point, relativeTo, relPoint = frame:GetPoint(1)
				assert.equal("TOPRIGHT", point)
				assert.equal(inventoryFrame, relativeTo)
				assert.equal("TOPLEFT", relPoint)
			end)

			it("refuses when there is nothing to dock to, leaving the window where it is", function()
				Browse:DrawWindow()
				local before = { Browse.Window.frame:GetPoint(1) }

				TOGBankClassic_UI_Inventory.isOpen = false
				assert.is_false(TOGBankClassic_UI:DockBesideInventory(Browse.Window, "RIGHT"))
				TOGBankClassic_UI_Inventory.isOpen = true
				TOGBankClassic_UI_Inventory.Window = nil
				assert.is_false(TOGBankClassic_UI:DockBesideInventory(Browse.Window, "RIGHT"))
				TOGBankClassic_UI_Inventory = nil
				assert.is_false(TOGBankClassic_UI:DockBesideInventory(Browse.Window, "RIGHT"))
				assert.is_false(TOGBankClassic_UI:DockBesideInventory(nil, "RIGHT"))

				assert.same(before, { Browse.Window.frame:GetPoint(1) }, "a refused dock moved the window anyway")
			end)
		end)

		-- The fix itself, driven by moving the scale for real: the dock is re-applied AFTER the status
		-- table, so it is the anchor that survives rather than the saved top/left.
		it("re-applies the window's own anchor after the status table, so the dock survives", function()
			-- Wider than the doubled floor, so the width asserted below is the status table's and not
			-- the floor raise (at scale 2 a 1200-wide window is correctly raised to 2 * MinWidth).
			standUp({ browse = { width = 2000, height = 800, top = 700, left = 250 } })
			Browse:DrawWindow()
			local window, frame = Browse.Window, Browse.Window.frame
			assert.is_true(TOGBankClassic_UI:SetPersistedAnchor(window, function(w)
				TOGBankClassic_UI:DockBesideInventory(w, "RIGHT")
			end))
			assert.is_true(TOGBankClassic_UI:DockBesideInventory(window, "RIGHT"))

			W:SetScale(2)
			local point, relativeTo, relPoint = frame:GetPoint(1)
			assert.equal(inventoryFrame, relativeTo,
				"the scale change tore the window off the Inventory window and re-pointed it at the saved position")
			assert.equal("TOPLEFT", point)
			assert.equal("TOPRIGHT", relPoint)

			-- The status table is still applied: this is an addition to the re-apply, not a bypass of it.
			assert.equal(2000, TOGBankClassic_Options.db.char.framePositions.browse.width)
		end)

		-- The control for the example above: without a registered anchor the window really is
		-- re-pointed, so the assertion there is testing the fix and not the harness.
		it("still re-points a window that has NOT registered an anchor -- the defect, unfixed", function()
			standUp({ browse = { width = 1200, height = 800, top = 700, left = 250 } })
			Browse:DrawWindow()
			local window, frame = Browse.Window, Browse.Window.frame
			assert.is_nil(window._togPersist.reanchor, "precondition: this window must have no anchor registered")
			assert.is_true(TOGBankClassic_UI:DockBesideInventory(window, "RIGHT"))

			W:SetScale(2)
			local _, relativeTo = frame:GetPoint(1)
			assert.not_equal(inventoryFrame, relativeTo,
				"ApplyStatus did not clear the hand-made anchor, so SCALE-DOCK-001 is not the bug it was filed as")
		end)

		it("drops the anchor with the record when a window is released, so a pooled frame is never re-anchored", function()
			Browse:DrawWindow()
			local window = Browse.Window
			TOGBankClassic_UI:SetPersistedAnchor(window, function() error("the anchor outlived the window") end)
			assert.is_true(TOGBankClassic_UI:ForgetPersistedWindow(window))
			assert.is_nil(window._togPersist)
			assert.is_false(TOGBankClassic_UI:SetPersistedAnchor(window, function() end),
				"an anchor can be registered on a window that is no longer persisted")
			W:SetScale(2)   -- the erroring anchor must not run
		end)
	end)
end)
