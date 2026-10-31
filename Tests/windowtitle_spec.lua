-- BRAND-001 / BRAND-002: what a player reads in every window's title bar.
--
-- The operator, 2026-09-12, on "TOGBankClassic v@project-version@ - Guild Bank": "i've rebranded
-- as TOG Bank and removed the classic, can you remove it from here?" -- and "you don't have to
-- change the name in the files anywhere". So the folder, the TOC and every identifier stay
-- TOGBankClassic. BRAND-002 (2026-10-31, "the same rebranding i did in Dibs and TOGPM"): the name
-- is now "Ultimate Bank", drawn in the fleet's brand orange like Ultimate Profession Master's
-- title. And the version shown is `d.d.d`, because a released client's Version is the whole git
-- tag (WIRE-SKEW-002), which would otherwise render as "Ultimate Bank vTOGBankClassic-v1.4.1".
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BRAND = "|cffFF8000Ultimate Bank|r"

local function titleWith(version, name)
	_G.GetAddOnMetadata = function() return version end
	return TOGBankClassic_UI:WindowTitle(name)
end

describe("BRAND-002: UI:WindowTitle", function()
	before_each(function()
		env.reset()
		env.standUpClient("Bankchar", {}, "Testguild")
		env.loadUI()   -- the real AceGUI-3.0 plus Modules/UI.lua; the module order stops before UI
	end)

	it("reads Ultimate Bank in the brand orange, and carries the window's name", function()
		assert.equal(BRAND .. " v1.5.0 - Guild Bank", titleWith("1.5.0", "Guild Bank"))
		assert.equal(BRAND .. " v1.5.0", titleWith("1.5.0", nil))
		assert.equal(BRAND .. " v1.5.0", titleWith("1.5.0", ""))
	end)

	it("shows only the d.d.d of a released client's tag-shaped version", function()
		assert.equal(BRAND .. " v1.4.1 - Requests", titleWith("TOGBankClassic-v1.4.1", "Requests"))
	end)

	it("shows a dev build's placeholder as it is", function()
		assert.equal(BRAND .. " v@project-version@ - Guild Bank", titleWith("@project-version@", "Guild Bank"))
	end)

	it("says nothing about the identifiers: the addon, its frames and its options keep their name", function()
		-- The rename is what the PLAYER reads. Nothing that a SavedVariable, an AceAddon registry, a
		-- UISpecialFrames entry or another addon's lookup keys on may move with it.
		assert.is_not_nil(LibStub("AceAddon-3.0"):GetAddon("TOGBankClassic", true))
	end)
end)

describe("BRAND-002: chat prefix", function()
	before_each(function()
		env.reset()
		env.standUpClient("Bankchar", {}, "Testguild")
	end)

	it("starts every chat line with Ultimate Bank in the brand orange, not the AceAddon name", function()
		local lines = {}
		local frame = { AddMessage = function(_, text) lines[#lines + 1] = text end }
		TOGBankClassic_Core:Print(frame, "hello", 3)
		assert.equal(BRAND .. ": hello 3", lines[1])
		TOGBankClassic_Core:Printf(frame, "%d items", 5)
		assert.equal(BRAND .. ": 5 items", lines[2])
	end)
end)
