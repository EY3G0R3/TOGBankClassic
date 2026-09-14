-- INV2-RETIRE-003: the "where else is it" hint on a request the bags cannot cover.
--
-- Mail:CanFulfillRequest tells the banker where to look when the bags come up short -- "in mail",
-- "in bank", both -- and it used to read the legacy `alt.mail.items` / `alt.bank.items` sub-tables
-- for that. Those rows are on their way out; the hint reads the V2 store's per-source buckets
-- (Store:GetAltSourceRecords) now, which only the local banker's own scan writes. This path had no
-- coverage before the move, so every branch is asserted here for the first time.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local GUILD  = "Testguild"
local BANKER = "Bankchar-Testrealm"

local Mail, Store, Record

local function load()
	env.stubOutput()
	env.loadModules({ "Modules/Constants.lua", "Modules/Item.lua", "Modules/Bank.lua", "Modules/Guild.lua", "Modules/Mail.lua" })
	Store = env.freshV2()
	Record = TOGBankClassic_Inventory_Record
	Mail = TOGBankClassic_Mail
	-- The REAL Guild (so Mail's helpers on it -- RequestQuantityNeeded -- are the shipped ones),
	-- with only the roster/identity pieces this fixture pins overridden.
	local G = TOGBankClassic_Guild
	G.Info = { name = GUILD, alts = { [BANKER] = { name = BANKER } } }
	G.GetPlayer = function() return BANKER end
	G.NormalizeName = function(_, n) return n and (n:find("-") and n or n .. "-Testrealm") or nil end
	G.IsBank = function(_, n) return n == BANKER end
end

--- The banker's own scan, per source: what SetAltSources stores.
local function scanned(sources)
	local recs = {}
	for source, rows in pairs(sources) do
		recs[source] = {}
		for _, r in ipairs(rows) do recs[source][#recs[source] + 1] = Record.new(r[1], r[2], r[3]) end
	end
	Store:SetAltSources(GUILD, BANKER, recs, 0)
end

local function request(itemID, qty, suffix)
	return { id = "r1", item = "Thing", itemID = itemID, quantity = qty, fulfilled = 0, status = "open", suffixID = suffix }
end

describe("Store:GetAltSourceRecords", function()
	before_each(function() env.reset(); load() end)

	it("returns one source's bucket, and an empty table for a source the record does not carry", function()
		scanned({ bags = { { 858, 5 } }, mail = { { 2589, 20 } } })
		assert.equal(1, #Store:GetAltSourceRecords(GUILD, BANKER, "bags"))
		assert.equal(2589, Record.id(Store:GetAltSourceRecords(GUILD, BANKER, "mail")[1]))
		assert.same({}, Store:GetAltSourceRecords(GUILD, BANKER, "bank"))
	end)

	it("is empty for every named source on a RECEIVED record, which holds one flat bucket", function()
		Store:SetAltRecords(GUILD, BANKER, { Record.new(858, 5) }, 0)
		assert.same({}, Store:GetAltSourceRecords(GUILD, BANKER, "bags"))
		assert.same({}, Store:GetAltSourceRecords(GUILD, BANKER, "mail"))
		assert.equal(1, #Store:GetAltRecords(GUILD, BANKER), "the flat read still sees the rows")
	end)

	it("is empty, never nil, for an unknown alt or guild", function()
		assert.same({}, Store:GetAltSourceRecords(GUILD, "Nobody-Testrealm", "mail"))
		assert.same({}, Store:GetAltSourceRecords("Otherguild", BANKER, "mail"))
	end)
end)

describe("Mail:CanFulfillRequest -- where else the item is", function()
	before_each(function()
		env.reset(); load()
		env.defineItem(858, { name = "Thing", class = 0 })
		env.setBag(0, 4, {})   -- nothing in bags
	end)

	it("says 'in mail' when the mailbox holds it", function()
		scanned({ bags = {}, mail = { { 858, 5 } } })
		local ok, reason = Mail:CanFulfillRequest(request(858, 5))
		assert.is_false(ok)
		assert.equal("in mail", reason)
	end)

	it("says 'in mail and bank' when both hold it", function()
		scanned({ bags = {}, mail = { { 858, 5 } }, bank = { { 858, 1 } } })
		local _, reason = Mail:CanFulfillRequest(request(858, 5))
		assert.equal("in mail and bank", reason)
	end)

	it("points at the bank when only the vault holds it", function()
		scanned({ bags = {}, bank = { { 858, 5 } } })
		local _, reason = Mail:CanFulfillRequest(request(858, 5))
		assert.equal("Items not in bags. Pick up from bank first.", reason)
	end)

	local NOWHERE = "Not in your bags, bank or mail (as of your last bank scan)."

	-- FULFIL-003, read off the banker's own screen on 2026-09-12: a recipe mailed out two days
	-- earlier, the next request for it wearing the bag icon -- "it is in the bank, go get it" -- with
	-- the bank open and empty of it. `inBank` was computed and then ignored on this branch.
	it("says the item is NOWHERE when neither bags, bank nor mail hold it -- not 'pick it up from the bank'", function()
		scanned({ bags = {}, bank = { { 2589, 20 } }, mail = {} })
		local ok, reason = Mail:CanFulfillRequest(request(858, 1))
		assert.is_false(ok)
		assert.equal(NOWHERE, reason,
			"the bank does not hold this item and the banker was told to go and pick it up (FULFIL-003)")
	end)

	it("is suffix-aware: a different variant in the mail is not the item asked for", function()
		scanned({ bags = {}, mail = { { 10132, 1, 863 } } })
		local _, reason = Mail:CanFulfillRequest(request(10132, 1, 2504))
		assert.equal(NOWHERE, reason)
		local _, reason2 = Mail:CanFulfillRequest(request(10132, 1, 863))
		assert.equal("in mail", reason2)
	end)

	it("does not read another character's record for the hint", function()
		Store:SetAltSources(GUILD, "Other-Testrealm", { mail = { Record.new(858, 5) } }, 0)
		local _, reason = Mail:CanFulfillRequest(request(858, 5))
		assert.equal(NOWHERE, reason)
	end)

	-- A request with no itemID (an old client's) cannot be looked up in the tuple store, so an
	-- absence is not claimed for it: it keeps the "check the bank" wording rather than telling the
	-- banker something nobody verified.
	it("keeps the 'pick up from bank' wording for a name-only request it cannot look up", function()
		scanned({ bags = {}, bank = {} })
		local req = request(nil, 1)
		local _, reason = Mail:CanFulfillRequest(req)
		assert.equal("Items not in bags. Pick up from bank first.", reason)
	end)

	it("reports the shortfall's whereabouts when bags hold some but not enough", function()
		env.setBag(0, 4, { { id = 858, count = 2 } })
		scanned({ bags = { { 858, 2 } }, bank = { { 858, 10 } } })
		local ok, reason, inBags = Mail:CanFulfillRequest(request(858, 5))
		assert.is_false(ok)
		assert.equal("shortfall in bank", reason)
		assert.equal(2, inBags)
	end)
end)
