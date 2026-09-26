-- The Donation (Mail) window's attachment rows -- LINK-AUDIT-001 step 3 (docs/LINK_AUDIT.md 3.6).
--
-- An inbox attachment is one of the two EDGES where the client hands the addon a link. The window
-- parses it once (Scan.parseLink), makes a record, and draws the same view row every inventory
-- window draws (Store.ViewRowFor) -- synchronously. It used to build `{ ID, Link, Count }` rows
-- and hand them to Item:GetItems, the async loader whose only remaining reason to exist was those
-- rows; a suffixed weapon in the mail then drew as its base item.
--
-- Real AceGUI (env.loadUI), the harness's inbox model (wow.mail), a stubbed LibItemDB honouring
-- docs/LIBRARY_CONTRACTS.md section 1.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")
local wow = require("env.wow")

local Mail, UI, drawn, scheduled

local function stubItemDB(items, suffixes)
	LibStub.libs["LibItemDB-1.0"] = {
		HasItem = function(_, id) return items[id] ~= nil end,
		GetInfo = function(_, id)
			local d = items[id]
			if not d then return nil end
			return d.name, d.quality, d.class, d.subClass, d.equipLoc, d.itemLevel
		end,
		GetSuffixLink = function(_, id, suffix, enchant)
			local s = "item:" .. id
			if enchant then s = ("item:%d:%d:::::%d"):format(id, enchant, suffix or 0)
			elseif suffix then s = ("item:%d::::::%d"):format(id, suffix) end
			local family = suffix and suffixes[suffix]
			return "|cff1eff00|H" .. s .. "|h[" .. items[id].name .. (family and (" " .. family) or "") .. "]|h|r"
		end,
		ResolveSuffix = function(_, id, prop)
			local family = suffixes[prop]
			return { id = id, name = items[id].name .. (family and (" " .. family) or "") }
		end,
		GetRequiredLevel = function(_, id) return items[id] and items[id].reqLevel or 0 end,
	}
	LibStub.minors["LibItemDB-1.0"] = 15
end

local function load()
	env.reset()
	env.stubOutput()
	require("env.frames").reset()
	stubItemDB({
		[4564] = { name = "Spiked Club", quality = 2, class = 2, subClass = 4, equipLoc = "INVTYPE_WEAPON", itemLevel = 20, reqLevel = 15 },
		[2589] = { name = "Linen Cloth", quality = 1, class = 7, subClass = 5, equipLoc = "", itemLevel = 5 },
	}, { [1180] = "of the Bear" })
	UI = env.loadUI()
	env.loadModules({
		"Modules/Constants.lua", "Modules/Inventory/Record.lua", "Modules/Inventory/Resolve.lua",
		"Modules/Inventory/Store.lua", "Modules/Inventory/Scan.lua", "Modules/UI/Mail.lua",
	})
	Mail = TOGBankClassic_UI_Mail
	Mail.Window, Mail.Content, Mail.isOpen = nil, nil, nil
	TOGBankClassic_Options = { db = { global = {}, char = {} } }
	TOGBankClassic_Guild = { GetPlayerInfo = function() return nil end }
	TOGBankClassic_Mail = { Open = function() end }
	scheduled = 0
	TOGBankClassic_Core = { ScheduleTimer = function() scheduled = scheduled + 1 end }
	-- The loader is GONE from this path: reaching it is the regression this file exists to catch.
	TOGBankClassic_Item = {
		IsUnique = function() return false end,
		GetItems = function() error("the Mail window handed its rows to the async loader again") end,
	}
	_G.GetInboxText = function() return nil end
	drawn = {}
	local realDraw = UI.DrawItem
	UI.DrawItem = function(self, item, ...) drawn[#drawn + 1] = item; return realDraw(self, item, ...) end
	Mail:DrawWindow()
	Mail:SetMailId(1)
end

describe("MAILWINDOW: the attachment rows are view rows built at the edge", function()
	before_each(load)
	after_each(function()
		TOGBankClassic_Item = nil
		-- SUITE-HEAP-002: each example draws a fresh window; hand it back.
		if Mail and Mail.Window then env.releaseWindow(Mail.Window); Mail.Window, Mail.Content = nil, nil end
	end)

	it("draws each attachment as the record it is -- suffix, enchant and count intact -- through Resolve, with no async loader", function()
		wow.mail[1] = { sender = "Alice", subject = "donation", money = 0, cod = 0, daysLeft = 29, items = {
			{ name = "Spiked Club of the Bear", id = 4564, count = 1, link = "|cff1eff00|Hitem:4564:2504:0:0:0:0:1180:0:60|h[Spiked Club of the Bear]|h|r" },
			{ name = "Linen Cloth", id = 2589, count = 20, link = "|cffffffff|Hitem:2589|h[Linen Cloth]|h|r" },
		} }
		Mail:DrawContent()
		assert.equal(2, #drawn, "not every attachment was drawn")
		local club, linen = drawn[1], drawn[2]
		assert.equal(4564, club.ID); assert.equal(1, club.Count)
		assert.equal(1180, club.Suffix, "the suffix was dropped at the edge"); assert.equal(2504, club.Enchant)
		assert.equal("Spiked Club of the Bear", club.Info.name, "the row names the base item, not the variant")
		assert.truthy(club.Link:find("::::::1180", 1, true) or club.Link:find(":2504:::::1180", 1, true), "the drawn link lost the variant: " .. tostring(club.Link))
		assert.equal(2, club.Info.rarity); assert.equal(15, club.Info.reqLevel)
		assert.equal(2589, linen.ID); assert.equal(20, linen.Count); assert.equal(0, linen.Suffix)
		assert.equal("Linen Cloth", linen.Info.name)
		assert.equal(0, scheduled, "a fully-linked mail scheduled a redraw")
	end)

	it("skips a unique attachment, and redraws later when the client has not delivered a link yet", function()
		TOGBankClassic_Item.IsUnique = function(_, link) return link:find("2589", 1, true) ~= nil end
		wow.mail[1] = { sender = "Alice", subject = "donation", money = 0, cod = 0, daysLeft = 29, items = {
			{ name = "Spiked Club", id = 4564, count = 1, link = "|cffffffff|Hitem:4564|h[Spiked Club]|h|r" },
			{ name = "Linen Cloth", id = 2589, count = 20, link = "|cffffffff|Hitem:2589|h[Linen Cloth]|h|r" },
		} }
		Mail:DrawContent()
		assert.equal(1, #drawn); assert.equal(4564, drawn[1].ID)
		-- The header is in but an attachment's link is not: nothing is drawn yet, a redraw is booked.
		drawn = {}
		wow.mail[1].items[2].link = nil
		Mail:DrawContent()
		assert.equal(0, #drawn, "rows were drawn from a mail whose links have not arrived")
		assert.equal(1, scheduled, "no redraw was scheduled for the missing link")
	end)
end)
