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
end)
