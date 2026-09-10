-- MAIL-015 — mail items must survive aggregation into `alt.items`.
--
-- FROM A LIVE REPORT, 2026-09-08. A banker held 68 Black Diamond in bags and 3 in mail. TOGBank's
-- own saved record had both (a consumer reading `alt.bags.items` and `alt.mail.items` separately
-- displayed "71=68+3"), but the tooltip's "Bankers:" line -- which reads the aggregate
-- `alt.items` -- showed 68. So the aggregate that Bank:Scan builds from bank + bags + mail was
-- missing the mail contribution, while the sources it was built from had it.
--
-- The shape that matters: bag items carry a LINK, mail items are LINKLESS (MailInventory stores
-- {ID, Count} with no link, because GetInboxItem gives no link for every attachment). Aggregate
-- keys on ID .. GetItemKey(Link), so a linked and a linkless row for the same item produce
-- DIFFERENT keys unless the linkless-merge branch catches it. These specs drive exactly that pair.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Item

local function load()
	env.stubOutput()
	env.loadModules({ "Modules/Constants.lua", "Modules/Item.lua" })
	Item = TOGBankClassic_Item
	return Item
end

--- Total across every aggregated row carrying `id` -- which is how both the tooltip and the
--- inventory view count, so it is the number a player actually sees.
local function totalFor(aggregated, id)
	local total = 0
	for _, row in pairs(aggregated or {}) do
		if row.ID == id then total = total + (row.Count or 1) end
	end
	return total
end

describe("MAIL-015: aggregating linked bag items with linkless mail items", function()
	before_each(function() env.reset(); load() end)

	local LINK = "|cffffffff|Hitem:11754::::::|h[Black Diamond]|h|r"

	-- The exact live case.
	it("keeps the mail stack when bags carry a link and mail does not", function()
		local bags = { { ID = 11754, Count = 68, Link = LINK } }
		local mail = { { ID = 11754, Count = 3 } }

		local aggregated = Item:Aggregate({}, bags)
		aggregated = Item:Aggregate(aggregated, mail)

		assert.equal(71, totalFor(aggregated, 11754),
			"the 3 items in mail were dropped. Bank:Scan aggregates bank + bags + mail into " ..
			"alt.items, and the tooltip and inventory views read that aggregate -- so a banker's " ..
			"mail contents silently stop being counted (MAIL-015)")
	end)

	-- Order is not incidental: Bank:Scan does Aggregate(bank, bags) and then
	-- Aggregate(<result>, mail), so mail is always the SECOND argument of the second call.
	it("keeps the mail stack when the linkless rows come first instead", function()
		local mail = { { ID = 11754, Count = 3 } }
		local bags = { { ID = 11754, Count = 68, Link = LINK } }

		local aggregated = Item:Aggregate(mail, bags)
		assert.equal(71, totalFor(aggregated, 11754))
	end)

	it("keeps a mail-only item that no bag holds", function()
		local aggregated = Item:Aggregate({ { ID = 11754, Count = 68, Link = LINK } },
			{ { ID = 858, Count = 5 } })
		assert.equal(5, totalFor(aggregated, 858), "an item held ONLY in mail vanished entirely")
		assert.equal(68, totalFor(aggregated, 11754))
	end)

	-- Bank:Scan's real call shape, end to end, so a fix that works on a single pair but not on
	-- the two-call sequence is still caught.
	it("survives the bank-then-bags-then-mail sequence Bank:Scan actually performs", function()
		local bank = { { ID = 11754, Count = 10, Link = LINK } }
		local bags = { { ID = 11754, Count = 68, Link = LINK } }
		local mail = { { ID = 11754, Count = 3 } }

		local aggregated = Item:Aggregate(bank, bags)
		aggregated = Item:Aggregate(aggregated, mail)

		assert.equal(81, totalFor(aggregated, 11754),
			"bank + bags + mail must total 10 + 68 + 3")
	end)
end)
