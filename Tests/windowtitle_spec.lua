-- BRAND-001: what a player reads in every window's title bar.
--
-- The operator, 2026-09-12, on "TOGBankClassic v@project-version@ - Guild Bank": "i've rebranded
-- as TOG Bank and removed the classic, can you remove it from here?" -- and "you don't have to
-- change the name in the files anywhere". So the folder, the TOC and every identifier stay
-- TOGBankClassic; the title reads "TOG Bank". And the version shown is `d.d.d`, because a released
-- client's Version is the whole git tag (WIRE-SKEW-002), which would otherwise render as
-- "TOG Bank vTOGBankClassic-v1.4.1".
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function titleWith(version, name)
	_G.GetAddOnMetadata = function() return version end
	return TOGBankClassic_UI:WindowTitle(name)
end

describe("BRAND-001: UI:WindowTitle", function()
	before_each(function()
		env.reset()
		env.standUpClient("Bankchar", {}, "Testguild")
		env.loadUI()   -- the real AceGUI-3.0 plus Modules/UI.lua; the module order stops before UI
	end)

	it("reads TOG Bank, not TOGBankClassic, and carries the window's name", function()
		assert.equal("TOG Bank v1.5.0 - Guild Bank", titleWith("1.5.0", "Guild Bank"))
		assert.equal("TOG Bank v1.5.0", titleWith("1.5.0", nil))
		assert.equal("TOG Bank v1.5.0", titleWith("1.5.0", ""))
	end)

	it("shows only the d.d.d of a released client's tag-shaped version", function()
		assert.equal("TOG Bank v1.4.1 - Requests", titleWith("TOGBankClassic-v1.4.1", "Requests"))
	end)

	it("shows a dev build's placeholder as it is", function()
		assert.equal("TOG Bank v@project-version@ - Guild Bank", titleWith("@project-version@", "Guild Bank"))
	end)

	it("says nothing about the identifiers: the addon, its frames and its options keep their name", function()
		-- The rename is what the PLAYER reads. Nothing that a SavedVariable, an AceAddon registry, a
		-- UISpecialFrames entry or another addon's lookup keys on may move with it.
		assert.is_not_nil(LibStub("AceAddon-3.0"):GetAddon("TOGBankClassic", true))
	end)
end)
