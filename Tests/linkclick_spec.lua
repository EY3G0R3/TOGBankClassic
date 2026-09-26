-- LINKCLICK-001: a MODIFIED click on an item link in this addon does what it does everywhere else in
-- the game. The operator, 2026-09-17: "what shift+click and ctrl+click does to the links in the
-- addon? i'd like it to mirror game functionality".
--
-- What the game does, read in F:\Blizzard API Docs (both trees this addon ships, classic_era and
-- classic_anniversary): a modified click on any item link runs `HandleModifiedItemClick(link)`
-- (Blizzard_ItemButton/Classic/ItemButtonTemplate.lua:137) -- `IsModifiedClick("CHATLINK")` (Shift by
-- default, but the PLAYER'S binding) inserts the link through `ChatFrameUtil.InsertLink` (the open chat
-- box, else the auction house's search box, else a macro being edited; false when nowhere takes it),
-- `IsModifiedClick("DRESSUP")` (Ctrl by default) previews it with `DressUpItemLink`. The bare
-- `ChatEdit_InsertLink` is an ALIAS of the real function in Blizzard_DeprecatedChatInfo/
-- Deprecated_ChatFrame.lua:43, behind `loadDeprecationFallbacks`, with no call site in either tree.
--
-- What the addon did until this: read IsShiftKeyDown / IsControlKeyDown (a rebound player got
-- nothing), called the alias (nil with the CVar off), gave the Browse and Shop rows no dress-up at all
-- (a Ctrl-click REQUESTED the item), and hooked the alias for its own "shift-click fills the Search
-- box" feature -- which therefore never saw a shift-click from a bag or a chat line.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")
local wow = require("env.wow")

local LINK = "|cffffffff|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"

local function clearModifiers()
	wow.modifiedClicks.CHATLINK, wow.modifiedClicks.DRESSUP = nil, nil
	wow.activeChatWindow = nil
end

describe("LINKCLICK-001: a modified click on an item link does what the game does with it", function()
	local UI, picked, insertedBefore, dressedBefore

	before_each(function()
		env.reset(); env.stubOutput()
		UI = env.loadUI()
		clearModifiers()
		picked = {}
		_G.PickupItem = function(link) picked[#picked + 1] = link end
		insertedBefore, dressedBefore = #wow.insertedLinks, #wow.dressUps
	end)

	after_each(function()
		clearModifiers()
	end)

	local function inserted() return #wow.insertedLinks - insertedBefore end
	local function dressed() return #wow.dressUps - dressedBefore end

	it("a plain click is not a link click: nothing is consumed, and a slot's own action runs", function()
		assert.is_false(UI:HandleLinkClick(LINK))
		UI:EventHandler({ link = LINK }, "OnClick", "LeftButton")
		assert.same({ LINK }, picked, "a plain click on a slot did not pick the item up")
		assert.equal(0, inserted()); assert.equal(0, dressed())
	end)

	it("the chat-link binding inserts the link where the client puts one, through the client's dispatcher, and the slot's own action does not run", function()
		wow.modifiedClicks.CHATLINK = true
		wow.activeChatWindow = { Insert = function() end }   -- a chat box is open
		assert.is_true(UI:HandleLinkClick(LINK))
		assert.equal(1, inserted(), "the link was not inserted")
		assert.equal(LINK, wow.insertedLinks[#wow.insertedLinks])
		UI:EventHandler({ link = LINK }, "OnClick", "LeftButton")
		assert.same({}, picked, "a chat-link click picked the item up as well")
		assert.equal(2, inserted())
	end)

	it("the chat-link binding with nowhere to put the link still consumes the click -- the request dialog and the pickup never run under a modifier", function()
		wow.modifiedClicks.CHATLINK = true   -- no chat box open
		assert.is_true(UI:HandleLinkClick(LINK), "a held modifier was reported as a plain click")
		assert.equal(0, inserted())
		UI:EventHandler({ link = LINK }, "OnClick", "LeftButton")
		assert.same({}, picked)
	end)

	it("the dress-up binding previews the item and consumes the click", function()
		wow.modifiedClicks.DRESSUP = true
		assert.is_true(UI:HandleLinkClick(LINK))
		assert.equal(1, dressed(), "the item was not sent to the dressing room")
		assert.equal(LINK, wow.dressUps[#wow.dressUps])
		UI:EventHandler({ link = LINK }, "OnClick", "LeftButton")
		assert.same({}, picked)
	end)

	it("a right click and a click with no link are left to the caller", function()
		wow.modifiedClicks.CHATLINK = true
		UI:EventHandler({ link = LINK }, "OnClick", "RightButton")
		assert.equal(0, inserted(), "a right click inserted the link")
		assert.is_true(UI:HandleLinkClick(nil), "a modified click on a slot with no link fell through to the plain action")
	end)

	it("without the client's dispatcher the same two bindings are honoured through the real insert function and DressUpItemLink", function()
		local dispatcher, dressUpFn = _G.HandleModifiedItemClick, _G.DressUpItemLink
		local previews = {}
		_G.HandleModifiedItemClick = nil
		_G.DressUpItemLink = function(link) previews[#previews + 1] = link return true end
		wow.modifiedClicks.CHATLINK = true
		wow.activeChatWindow = { Insert = function() end }
		assert.is_true(UI:HandleLinkClick(LINK))
		assert.equal(1, inserted(), "the fallback did not insert through ChatFrameUtil.InsertLink")
		clearModifiers()
		wow.modifiedClicks.DRESSUP = true
		assert.is_true(UI:HandleLinkClick(LINK))
		assert.same({ LINK }, previews, "the fallback did not preview the item")
		_G.HandleModifiedItemClick, _G.DressUpItemLink = dispatcher, dressUpFn
	end)

	it("InsertLink prefers the function the client calls and reports whether anything took the link", function()
		assert.is_false(UI:InsertLink(LINK), "nothing was open, and the insert reported success")
		wow.activeChatWindow = { Insert = function() end }
		assert.is_true(UI:InsertLink(LINK))
		assert.is_false(UI:InsertLink(nil))
		-- With the client's table absent and the alias present (a client that only has the fallback).
		-- The env's alias IS the real function (as the client's is), so it cannot stand without the
		-- table; a standalone fallback stands in for it here.
		local util, alias = _G.ChatFrameUtil, _G.ChatEdit_InsertLink
		local viaAlias = {}
		_G.ChatFrameUtil = nil
		_G.ChatEdit_InsertLink = function(text) viaAlias[#viaAlias + 1] = text return true end
		assert.is_true(UI:InsertLink(LINK), "the alias was not used when the client's table is absent")
		assert.same({ LINK }, viaAlias)
		_G.ChatEdit_InsertLink = nil
		assert.is_false(UI:InsertLink(LINK), "with neither function the insert reported success")
		_G.ChatFrameUtil, _G.ChatEdit_InsertLink = util, alias
	end)
end)

describe("LINKCLICK-001: the Search box fills from a shift-click ANYWHERE, because the hook is on the function the client calls", function()
	local seen

	before_each(function()
		env.reset(); env.stubOutput()
		clearModifiers()
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/Events.lua")
		-- RegisterEvents' collaborators, stubbed as events_spec stubs them (Events:RegisterEvent
		-- forwards to Core's AceEvent registration).
		TOGBankClassic_Core  = { RegisterEvent = function() end, UnregisterEvent = function() end,
		                         RegisterMessage = function() end, SendMessage = function() end,
		                         ScheduleTimer = function() return {} end, CancelTimer = function() end,
		                         Print = function() end }
		TOGBankClassic_Bank  = { eventsRegistered = false }
		TOGBankClassic_Guild = { GetNormalizedPlayer = function() return "Bankchar-Testrealm" end,
		                         IsBank = function() return false end }
		seen = {}
		TOGBankClassic_UI    = { OnInsertLink = function(_, link) seen[#seen + 1] = link end }
		TOGBankClassic_UI_Requests = { isOpen = false }
		_G.ChatFrame_AddMessageEventFilter = function() end
		_G.MailFrame, _G.MailFrameTab2 = nil, nil
	end)

	after_each(function() clearModifiers() end)

	it("a link the client inserts -- a shift-click on a bag item or a chat line -- reaches OnInsertLink, whether or not a chat box took it", function()
		TOGBankClassic_Events:RegisterEvents()
		ChatFrameUtil.InsertLink(LINK)            -- no chat box open: the client returns false...
		assert.same({ LINK }, seen, "...and the hook must still have seen the link (that is the Search-box case)")
		wow.modifiedClicks.CHATLINK = true
		HandleModifiedItemClick(LINK)             -- what a bag button runs on a modified click
		assert.same({ LINK, LINK }, seen, "a shift-click through the client's dispatcher did not reach the hook")
	end)

	it("on a client with only the deprecated alias, the alias is hooked; with neither, registration does not raise", function()
		local util, alias = _G.ChatFrameUtil, _G.ChatEdit_InsertLink
		_G.ChatFrameUtil = nil
		_G.ChatEdit_InsertLink = function() return false end
		TOGBankClassic_Events:RegisterEvents()
		ChatEdit_InsertLink(LINK)
		assert.same({ LINK }, seen, "the alias was not hooked when it is all the client has")
		_G.ChatEdit_InsertLink = nil
		TOGBankClassic_Bank.eventsRegistered = false
		assert.has_no_error(function() TOGBankClassic_Events:RegisterEvents() end)
		_G.ChatFrameUtil, _G.ChatEdit_InsertLink = util, alias
	end)
end)
