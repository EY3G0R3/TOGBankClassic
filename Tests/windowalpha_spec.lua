-- ALPHA-001 — per-window transparency.
--
-- Two things make this worth specs rather than a look at the client. First, a bad saved value
-- must never make a window disappear, and "you cannot see it" is not a failure mode a player can
-- diagnose or report usefully. Second, AceGUI's widget pool is shared with every other addon
-- using the library, so a frame released while faded is a bug that shows up in SOMEONE ELSE'S
-- UI — which is exactly the kind of defect no amount of testing this addon in isolation finds.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function loadUI()
	env.stubOutput()
	local UI = env.loadUI()
	-- GetWindowAlpha reads through TOGBankClassic_Options.db.
	TOGBankClassic_Options = { db = { global = {} } }
	return UI
end

describe("TOGBankClassic_UI.ALPHA_WINDOWS", function()
	local UI
	before_each(function() env.reset(); UI = loadUI() end)

	it("covers every window the addon opens", function()
		local keys = {}
		for _, entry in ipairs(UI.ALPHA_WINDOWS) do keys[entry.key] = true end
		for _, expected in ipairs({ "inventory", "search", "requests", "donations", "mail", "mailbox", "browse" }) do
			assert.is_true(keys[expected] == true, "no transparency slider for the " .. expected .. " window")
		end
	end)

	-- Each entry names the global holding the live window. A typo here is silent: the slider
	-- appears, stores its value, and simply never repaints anything.
	it("names a module global that exists and stores its window as .Window", function()
		env.loadFile("Modules/Item.lua")
		env.loadFile("Modules/Bank.lua")
		local sources = {
			inventory = "Modules/UI/Inventory.lua",
			search    = "Modules/UI/Search.lua",
			requests  = "Modules/UI/Requests.lua",
			donations = "Modules/UI/Donations.lua",
			mail      = "Modules/UI/Mail.lua",
			mailbox   = "Modules/UI/Mailbox.lua",
			browse    = "Modules/UI/Browse.lua",
		}
		for _, entry in ipairs(UI.ALPHA_WINDOWS) do
			local path = sources[entry.key]
			assert.is_not_nil(path, "no source file mapped for " .. entry.key)
			local fh = assert(io.open(path, "rb"))
			local src = fh:read("*a"); fh:close()
			assert.is_not_nil(src:find(entry.module, 1, true),
				entry.module .. " is not the global declared in " .. path)
			assert.is_not_nil(src:find("self.Window =", 1, true),
				path .. " does not store its window as self.Window, so the slider cannot find it")
		end
	end)
end)

describe("TOGBankClassic_UI:GetWindowAlpha", function()
	local UI
	before_each(function() env.reset(); UI = loadUI() end)

	it("is fully opaque when nothing has been stored", function()
		assert.equal(1, UI:GetWindowAlpha("inventory"))
	end)

	it("returns a stored value unchanged", function()
		TOGBankClassic_Options.db.global.windowAlpha = { inventory = 0.4 }
		assert.equal(0.4, UI:GetWindowAlpha("inventory"))
	end)

	it("keeps windows independent", function()
		TOGBankClassic_Options.db.global.windowAlpha = { inventory = 0.3 }
		assert.equal(0.3, UI:GetWindowAlpha("inventory"))
		assert.equal(1, UI:GetWindowAlpha("search"))
	end)

	-- A corrupt or hand-edited SavedVariable must not make a window invisible. There is no way
	-- for a player to work out why a window stopped appearing, so every bad value reads opaque.
	it("falls back to opaque for a value that is not a usable number", function()
		for _, bad in ipairs({ "0.5", true, {} }) do
			TOGBankClassic_Options.db.global.windowAlpha = { inventory = bad }
			assert.equal(1, UI:GetWindowAlpha("inventory"),
				"a stored " .. type(bad) .. " did not fall back to opaque")
		end
		TOGBankClassic_Options.db.global.windowAlpha = { inventory = 0 / 0 }
		assert.equal(1, UI:GetWindowAlpha("inventory"), "a stored NaN did not fall back to opaque")
	end)

	it("clamps out-of-range values into 0..1", function()
		TOGBankClassic_Options.db.global.windowAlpha = { inventory = 5 }
		assert.equal(1, UI:GetWindowAlpha("inventory"))
		TOGBankClassic_Options.db.global.windowAlpha = { inventory = -3 }
		assert.equal(0, UI:GetWindowAlpha("inventory"))
	end)

	-- Windows are created lazily; a scan or a UI open can beat Options:Init on a fresh profile.
	it("is opaque rather than an error before the options database exists", function()
		TOGBankClassic_Options = nil
		assert.equal(1, UI:GetWindowAlpha("inventory"))
	end)
end)

describe("TOGBankClassic_UI:SetWindowAlpha", function()
	local UI
	before_each(function() env.reset(); UI = loadUI() end)

	it("stores the value", function()
		assert.is_true(UI:SetWindowAlpha("requests", 0.6))
		assert.equal(0.6, TOGBankClassic_Options.db.global.windowAlpha.requests)
		assert.equal(0.6, UI:GetWindowAlpha("requests"))
	end)

	it("creates the storage table on first use", function()
		TOGBankClassic_Options.db.global.windowAlpha = nil
		assert.is_true(UI:SetWindowAlpha("mail", 0.5))
		assert.equal(0.5, UI:GetWindowAlpha("mail"))
	end)

	-- Setting from the options panel must repaint a window that is already on screen, or the
	-- slider looks broken until the window is closed and reopened.
	it("repaints the live window immediately", function()
		local widget = env.newWindowWidget()
		TOGBankClassic_UI_Requests = { Window = widget }
		UI:SetWindowAlpha("requests", 0.25)
		assert.equal(0.25, widget.frame.painted.backdrop[4])
	end)

	it("reports failure rather than erroring when the database is not ready", function()
		TOGBankClassic_Options = nil
		assert.is_false(UI:SetWindowAlpha("mail", 0.5))
	end)
end)

describe("TOGBankClassic_UI:ApplyWindowAlpha", function()
	local UI, widget
	before_each(function()
		env.reset()
		UI = loadUI()
		widget = env.newWindowWidget()
	end)

	it("fades the backdrop and the border together", function()
		UI:SetWindowAlpha("inventory", 0.35)
		UI:ApplyWindowAlpha("inventory", widget)
		assert.equal(0.35, widget.frame.painted.backdrop[4])
		assert.equal(0.35, widget.frame.painted.border[4])
	end)

	it("fades the title-bar art", function()
		UI:SetWindowAlpha("inventory", 0.5)
		UI:ApplyWindowAlpha("inventory", widget)
		for i = 1, 3 do
			assert.equal(0.5, widget.frame["title" .. i].alpha,
				"title-bar texture " .. i .. " kept full opacity, so the header floats over a faded window")
		end
	end)

	it("fades the status bar background", function()
		UI:SetWindowAlpha("inventory", 0.2)
		UI:ApplyWindowAlpha("inventory", widget)
		assert.equal(0.2, widget.statusbg.painted.backdrop[4])
		assert.equal(0.2, widget.statusbg.painted.border[4])
	end)

	-- The backdrop's parchment texture has its own per-pixel alpha, and SetBackdropColor
	-- multiplies over it -- so a solid backing layer is what makes 100% actually opaque.
	it("adds a solid backing layer behind the backdrop", function()
		UI:SetWindowAlpha("inventory", 1)
		UI:ApplyWindowAlpha("inventory", widget)
		local fill = widget.frame.togOpaqueFill
		assert.is_not_nil(fill, "no backing layer was created, so 100% cannot reach genuinely opaque")
		assert.equal("BACKGROUND", fill.layer, "the backing layer is not behind the backdrop")
		assert.is_true((fill.sublevel or 0) < 0, "the backing layer is not below the backdrop's sublevel")
		assert.equal(1, fill.color[4])
	end)

	it("scales the backing layer with the slider", function()
		UI:SetWindowAlpha("inventory", 0.4)
		UI:ApplyWindowAlpha("inventory", widget)
		assert.equal(0.4, widget.frame.togOpaqueFill.color[4],
			"the backing layer stayed solid while the backdrop faded, so the window never gets see-through")
	end)

	it("reuses the backing layer instead of stacking a new one per repaint", function()
		UI:ApplyWindowAlpha("inventory", widget)
		local first = widget.frame.togOpaqueFill
		local count = #widget.frame.regions
		UI:ApplyWindowAlpha("inventory", widget)
		UI:ApplyWindowAlpha("inventory", widget)
		assert.equal(first, widget.frame.togOpaqueFill)
		assert.equal(count, #widget.frame.regions,
			"each repaint created another backing texture; WoW textures are never collected")
	end)

	-- The backing layer sits at BACKGROUND, so it must not also be caught by the title-art
	-- sweep -- SetColorTexture alpha and SetAlpha would multiply and the window would render
	-- at alpha squared.
	it("does not double-apply alpha to the backing layer", function()
		UI:SetWindowAlpha("inventory", 0.5)
		UI:ApplyWindowAlpha("inventory", widget)
		assert.is_nil(widget.frame.togOpaqueFill.alpha,
			"the backing layer got SetAlpha on top of its colour alpha, rendering at alpha squared")
	end)

	-- Blizzard's BackdropTemplate draws the backdrop with named textures parented to the frame.
	-- Fading those as well as calling SetBackdropColor would square the alpha.
	it("leaves Blizzard's backdrop textures alone", function()
		local center = widget.frame:CreateTexture(nil, "OVERLAY")
		widget.frame.Center = center
		UI:SetWindowAlpha("inventory", 0.5)
		UI:ApplyWindowAlpha("inventory", widget)
		assert.is_nil(center.alpha,
			"a BackdropTemplate texture was faded on top of SetBackdropColor, squaring the alpha")
	end)

	-- Only the header art is OVERLAY. Anything on another layer belongs to the backdrop or the
	-- content and must not be touched.
	it("only touches OVERLAY textures", function()
		local w = env.newWindowWidget({ "OVERLAY", "ARTWORK", "BORDER" })
		UI:SetWindowAlpha("inventory", 0.5)
		UI:ApplyWindowAlpha("inventory", w)
		assert.equal(0.5, w.frame.title1.alpha)
		assert.is_nil(w.frame.title2.alpha, "an ARTWORK texture was faded")
		assert.is_nil(w.frame.title3.alpha, "a BORDER texture was faded")
	end)

	it("resolves the live window from its module when no widget is passed", function()
		TOGBankClassic_UI_Search = { Window = widget }
		UI:SetWindowAlpha("search", 0.45)
		assert.equal(0.45, widget.frame.painted.backdrop[4])
	end)

	-- Requests nils its Window on release. Painting must report that it did nothing rather than
	-- erroring inside an options callback.
	it("reports no-op for a window that does not exist", function()
		TOGBankClassic_UI_Requests = { Window = nil }
		assert.is_false(UI:ApplyWindowAlpha("requests"))
		assert.is_false(UI:ApplyWindowAlpha("nosuchwindow"))
	end)
end)

describe("TOGBankClassic_UI:ClearWindowAlpha", function()
	local UI
	before_each(function() env.reset(); UI = loadUI() end)

	-- AceGUI's frame pool is shared across every addon using the library. Requests really does
	-- release and recreate its window on a banker-status change, so a frame released while faded
	-- can be handed to an unrelated addon carrying our black backing slab and faded header.
	it("restores every faded surface to opaque before release", function()
		local widget = env.newWindowWidget()
		UI:SetWindowAlpha("requests", 0.2)
		UI:ApplyWindowAlpha("requests", widget)

		UI:ClearWindowAlpha(widget)

		assert.equal(1, widget.frame.painted.backdrop[4])
		assert.equal(1, widget.frame.painted.border[4])
		assert.equal(1, widget.frame.togOpaqueFill.color[4],
			"the black backing layer went back to AceGUI's pool still opaque-black over a faded window")
		assert.equal(1, widget.statusbg.painted.backdrop[4])
		for i = 1, 3 do
			assert.equal(1, widget.frame["title" .. i].alpha, "title art " .. i .. " was released faded")
		end
	end)

	it("ignores the stored setting rather than repainting from it", function()
		local widget = env.newWindowWidget()
		UI:SetWindowAlpha("requests", 0.2)
		UI:ApplyWindowAlpha("requests", widget)
		UI:ClearWindowAlpha(widget)
		assert.equal(1, widget.frame.painted.backdrop[4])
		-- ...and the setting itself survives, so reopening the window is still transparent.
		assert.equal(0.2, UI:GetWindowAlpha("requests"))
	end)

	it("is called before Requests releases its window", function()
		local fh = assert(io.open("Modules/UI/Requests.lua", "rb"))
		local src = fh:read("*a"); fh:close()
		local clearPos = src:find("ClearWindowAlpha", 1, true)
		local releasePos = src:find("self.Window:Release()", 1, true)
		assert.is_not_nil(releasePos, "Requests no longer releases its window — this spec needs revisiting")
		assert.is_not_nil(clearPos,
			"Requests releases its window without resetting the chrome, so a faded frame goes back " ..
			"into AceGUI's shared pool")
		assert.is_true(clearPos < releasePos, "the chrome is reset after the frame is already released")
	end)
end)

describe("TOGBankClassic_UI:RefreshWindowAlpha", function()
	local UI
	before_each(function() env.reset(); UI = loadUI() end)

	it("repaints every window that currently exists", function()
		local inv, req = env.newWindowWidget(), env.newWindowWidget()
		TOGBankClassic_UI_Inventory = { Window = inv }
		TOGBankClassic_UI_Requests  = { Window = req }
		TOGBankClassic_UI_Search    = { Window = nil }
		TOGBankClassic_Options.db.global.windowAlpha = { inventory = 0.3, requests = 0.7 }

		UI:RefreshWindowAlpha()

		assert.equal(0.3, inv.frame.painted.backdrop[4])
		assert.equal(0.7, req.frame.painted.backdrop[4])
	end)
end)

describe("ApplyThinBorder alpha integration", function()
	local UI
	before_each(function() env.reset(); UI = loadUI() end)

	-- The border is applied at construction with a hardcoded opaque colour. If the alpha did not
	-- follow in the same call, every window would open solid and only fade once the slider moved.
	it("applies the stored alpha, not the hardcoded opaque colour", function()
		local widget = env.newWindowWidget()
		widget.frame.SetBackdrop = function() end
		UI:SetWindowAlpha("inventory", 0.4)
		UI:ApplyThinBorder(widget, "inventory")
		assert.equal(0.4, widget.frame.painted.backdrop[4],
			"the window opened opaque despite a stored transparency setting")
	end)

	it("leaves the window opaque when no alpha key is given", function()
		local widget = env.newWindowWidget()
		widget.frame.SetBackdrop = function() end
		UI:SetWindowAlpha("inventory", 0.4)
		UI:ApplyThinBorder(widget)
		assert.equal(1, widget.frame.painted.backdrop[4])
		assert.is_nil(widget.frame.togOpaqueFill)
	end)

	-- Both TOCs load Options.lua BEFORE UI.lua, so TOGBankClassic_UI does not exist yet while
	-- Options.lua is being read. The sliders are built from UI.ALPHA_WINDOWS, and reading that at
	-- file scope would be a hard error during addon load — the loudest possible failure, on every
	-- login, for every user. Executed rather than grepped: this is the one that actually matters.
	it("does not read the window list while Options.lua is loading", function()
		env.loadFile("Modules/Constants.lua")
		TOGBankClassic_UI = nil
		local ok, err = pcall(function() env.loadFile("Modules/Options.lua") end)
		assert.is_true(ok,
			"Options.lua touches TOGBankClassic_UI at file scope, but the TOC loads it before " ..
			"UI.lua — this errors on every login. Error: " .. tostring(err))
	end)

	it("keeps both TOCs in the load order this depends on", function()
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_BCC.toc" }) do
			local fh = assert(io.open(toc, "rb"))
			local src = fh:read("*a"); fh:close()
			local options = src:find("Modules/Options.lua", 1, true)
			local ui = src:find("Modules/UI.lua", 1, true)
			assert.is_not_nil(options, toc .. " does not load Modules/Options.lua")
			assert.is_not_nil(ui, toc .. " does not load Modules/UI.lua")
			assert.is_true(options < ui,
				toc .. " loads UI.lua before Options.lua — the reverse of what the spec above " ..
				"guards against. One of the two is now wrong.")
		end
	end)

	-- Every window must actually be wired up, or its slider is a control that does nothing.
	it("is wired at each window's construction site", function()
		local wired = {
			["Modules/UI/Inventory.lua"] = 'ApplyThinBorder(window, "inventory")',
			["Modules/UI/Search.lua"]    = 'ApplyThinBorder(searchWindow, "search")',
			["Modules/UI/Requests.lua"]  = 'ApplyThinBorder(window, "requests")',
			["Modules/UI/Donations.lua"] = 'ApplyWindowAlpha("donations", donations)',
			["Modules/UI/Mail.lua"]      = 'ApplyWindowAlpha("mail", window)',
			["Modules/UI/Browse.lua"]    = 'ApplyThinBorder(window, "browse")',
		}
		for path, expected in pairs(wired) do
			local fh = assert(io.open(path, "rb"))
			local src = fh:read("*a"); fh:close()
			assert.is_not_nil(src:find(expected, 1, true),
				path .. " never applies its window transparency, so its slider does nothing")
		end
	end)
end)
