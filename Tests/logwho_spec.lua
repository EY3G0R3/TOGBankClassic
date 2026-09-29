-- THE DELTA RELEASE step 4: the "who" on a bank-log entry (docs/DELTA_RELEASE.md section 3.6).
--
-- Blizzard's guild bank log names the member who deposited to a shared tab. This addon has no shared
-- tab: every movement through a bank character is a mail or a hand-off WITH a member, and the
-- banker's client knows the member on both sides -- a withdrawal by fulfilment is a `mailed` /
-- `handed` request event that names the requester, a deposit by mail is an inbox row whose sender
-- the mailbox scan saw. So the author derives `to` / `from` ONCE at mint (Log:AttributeChanges),
-- the attribution rides inside the chain link, and every receiver applies it verbatim
-- (RecordInventoryChange's `who`). Nothing is ever invented: a movement with no event behind it --
-- a trade, a vendor, a bag shuffle -- stays a plain deposit or withdraw.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local PEER   = "Otherguy-Testrealm"
local OTHER  = "Thirdguy-Testrealm"
local GUILD  = "Testguild"
local T      = 1757000000

local Log, Guild, Rec

local function client(who)
	env.standUpClient(who, { { name = BANKER, note = "gbank" }, { name = PEER }, { name = OTHER } }, GUILD)
	Log, Guild = TOGBankClassic_Log, TOGBankClassic_Guild
	Log.buffers, Log.diffedThisSession, Log.attributed = {}, nil, nil
	env.now = T
	TOGBankClassic_Core.SendCommMessage = function() end
	TOGBankClassic_Core.SendWhisper = function() return true end
	Rec = function(id, n, suffix) return TOGBankClassic_Inventory_Record.new(id, n, suffix) end
	env.defineItem(14256, { name = "Felcloth" })
	env.defineItem(858, { name = "Minor Healing Potion" })
end

local function ofType(entries, t)
	local out = {}
	for _, e in ipairs(entries) do if e.type == t then out[#out + 1] = e end end
	table.sort(out, function(a, b) return (a.count or 0) < (b.count or 0) end)
	return out
end

local function place(item, itemID, qty, requester)
	local ok = Guild:AddRequest({
		date = T, requester = requester or PEER, bank = BANKER,
		item = item, itemID = itemID, quantity = qty, fulfilled = 0, notes = "",
	})
	assert.is_true(ok, "precondition: AddRequest refused")
	for id, r in pairs(Guild.Info.requests) do
		if r.item == item and r.requester == (requester or PEER) then return id end
	end
	error("placed request not found")
end

describe("step 4: RecordInventoryChange applies a `who` it is handed", function()
	before_each(function() env.reset(); client("Bankchar") end)

	it("splits a withdrawal into one entry per requester, plus the unattributed remainder", function()
		local before, after = { Rec(14256, 20) }, { Rec(14256, 5) }
		-- The `who` is keyed by Record.key (id:suffix:enchant), as the sender table and the diff are.
		local who = { ["14256:0:0"] = { { count = 8, to = PEER }, { count = 5, to = OTHER } } }
		assert.equal(3, Log:RecordInventoryChange(BANKER, before, after, 0, 0, T, "p", "c", who))
		local w = ofType(Log:GetEntries(), "withdraw")
		assert.equal(3, #w)
		assert.equal(2, w[1].count); assert.is_nil(w[1].to, "the remainder was attributed to somebody")
		assert.equal(5, w[2].count); assert.equal(OTHER, w[2].to)
		assert.equal(8, w[3].count); assert.equal(PEER, w[3].to)
		for _, e in ipairs(w) do assert.equal(T, e.ts); assert.equal("c", e.toCanon) end
	end)

	it("names the sender on a mail deposit, and only a deposit gets `from`, only a withdrawal `to`", function()
		local who = { ["858:0:0"] = { { count = 3, from = OTHER, to = PEER } } }
		Log:RecordInventoryChange(BANKER, {}, { Rec(858, 3) }, 0, 0, T, nil, "c", who)
		local d = ofType(Log:GetEntries(), "deposit")
		assert.equal(1, #d)
		assert.equal(OTHER, d[1].from)
		assert.is_nil(d[1].to, "a deposit carried a `to`")
	end)

	it("ignores an attribution that claims MORE than moved -- the two records disagree", function()
		local who = { ["14256:0:0"] = { { count = 30, to = PEER } } }
		Log:RecordInventoryChange(BANKER, { Rec(14256, 20) }, { Rec(14256, 5) }, 0, 0, T, "p", "c", who)
		local w = ofType(Log:GetEntries(), "withdraw")
		assert.equal(1, #w)
		assert.equal(15, w[1].count)
		assert.is_nil(w[1].to, "an over-claiming attribution was applied")
	end)

	it("is unchanged by a nil or empty `who`", function()
		Log:RecordInventoryChange(BANKER, { Rec(14256, 20) }, { Rec(14256, 5) }, 100, 250, T, "p", "c", nil)
		Log:RecordInventoryChange(BANKER, { Rec(858, 1) }, { Rec(858, 4) }, 0, 0, T + 1, "c", "d", {})
		assert.equal(1, #ofType(Log:GetEntries(), "withdraw"))
		assert.equal(1, #ofType(Log:GetEntries(), "deposit"))
		assert.equal(1, #ofType(Log:GetEntries(), "money-deposit"))
	end)
end)

describe("step 4: AttributeChanges -- what the author's client knows", function()
	before_each(function() env.reset(); client("Bankchar") end)

	it("attributes a withdrawal to the requester it was mailed to, and consumes the fill", function()
		local id = place("Felcloth", 14256, 20)
		assert.equal(8, Guild:FulfillRequestById(id, 8, BANKER))
		local who = Log:AttributeChanges(BANKER, { Rec(14256, 20) }, { Rec(14256, 12) }, nil)
		assert.same({ ["14256:0:0"] = { { count = 8, to = PEER } } }, who)
		-- The same fill is not claimed by the next version.
		assert.is_nil(Log:AttributeChanges(BANKER, { Rec(14256, 12) }, { Rec(14256, 4) }, nil),
			"a fill already attributed to one version was attributed to the next as well")
	end)

	it("groups two requesters' fills for one item, and leaves a plain withdrawal plain", function()
		local a = place("Felcloth", 14256, 20, PEER)
		local b = place("Felcloth", 14256, 20, OTHER)
		Guild:FulfillRequestById(a, 5, BANKER)
		Guild:FulfillRequestById(b, 3, BANKER)
		Guild:FulfillRequestById(a, 2, BANKER)
		local who = Log:AttributeChanges(BANKER, { Rec(14256, 20), Rec(858, 9) }, { Rec(14256, 10), Rec(858, 2) }, nil)
		-- The whole answer: the Felcloth fills, and nothing for the plain 858 withdrawal.
		assert.same({ ["14256:0:0"] = { { count = 7, to = PEER }, { count = 3, to = OTHER } } }, who,
			"a withdrawal with no fill behind it was attributed")
	end)

	it("attributes a mail deposit to the inbox sender", function()
		local senders = { ["858:0:0"] = { [OTHER] = 4 } }
		local who = Log:AttributeChanges(BANKER, { Rec(858, 1) }, { Rec(858, 5) }, senders)
		assert.same({ ["858:0:0"] = { { count = 4, from = OTHER } } }, who)
		-- LINK-AUDIT-001 step 5: a SUFFIXED deposit is attributed under its own key -- the inbox
		-- sender table and the held-set diff agree on Record.key, so "of the Bear" matches "of the
		-- Bear" and not the plain item's arrival.
		local bear = { ["4564:1180:0"] = { [PEER] = 1 } }
		who = Log:AttributeChanges(BANKER, {}, { Rec(4564, 1, 1180) }, bear)
		assert.same({ ["4564:1180:0"] = { { count = 1, from = PEER } } }, who)
		assert.is_nil(Log:AttributeChanges(BANKER, {}, { Rec(4564, 1) }, bear), "a plain arrival was credited to a suffixed attachment's sender")
	end)

	it("answers nil when it knows nothing, and never for a first version", function()
		assert.is_nil(Log:AttributeChanges(BANKER, { Rec(858, 1) }, { Rec(858, 5) }, nil))
		assert.is_nil(Log:AttributeChanges(BANKER, nil, { Rec(858, 5) }, { ["858:0:0"] = { [OTHER] = 5 } }))
	end)

	it("does not claim a fill for a different item, a different banker, or a suffix variant", function()
		local id = place("Felcloth", 14256, 20)
		Guild:FulfillRequestById(id, 8, BANKER)
		assert.is_nil(Log:AttributeChanges(BANKER, { Rec(858, 20) }, { Rec(858, 12) }, nil))
		assert.is_nil(Log:AttributeChanges("Otherbanker-Testrealm", { Rec(14256, 20) }, { Rec(14256, 12) }, nil))
		assert.is_nil(Log:AttributeChanges(BANKER, { Rec(14256, 20, 863) }, { Rec(14256, 12, 863) }, nil))
	end)
end)

describe("step 4: the inbox scan reports who sent what", function()
	before_each(function() env.reset(); client("Bankchar") end)

	local function mail(sender, id, count, cod)
		return { sender = sender, subject = "x", cod = cod or 0,
			items = { { name = "Item " .. id, id = id, count = count,
				link = "|cffffffff|Hitem:" .. id .. ":0:0:0:0:0:0:0:60|h[Item " .. id .. "]|h|r" } } }
	end

	it("aggregates per item AND per sender across mails, and skips COD mail", function()
		env.wow.mail = { mail(PEER, 858, 4), mail(OTHER, 858, 6), mail(PEER, 14256, 2), mail(OTHER, 14256, 9, 500) }
		local MI = TOGBankClassic_MailInventory
		MI.hasUpdated = true
		local data = MI:ScanMailInventory()
		assert.is_table(data)
		assert.same({ [PEER] = 4, [OTHER] = 6 }, data.senders["858:0:0"])
		assert.same({ [PEER] = 2 }, data.senders["14256:0:0"], "a COD mail's attachment was counted as a deposit")
		-- LINK-AUDIT-001 step 5: the items are RECORDS, one per identity.
		local R = TOGBankClassic_Inventory_Record
		local counts = {}
		for _, rec in ipairs(data.items) do assert.is_true(R.isValid(rec), "a mail item is not a record"); counts[R.id(rec)] = R.count(rec) end
		assert.same({ [858] = 10, [14256] = 2 }, counts)
		assert.equal(2, data.slots.count)
		env.wow.mail = {}
	end)

	-- LINK-AUDIT-001 step 5 (docs/LINK_AUDIT.md 3.3, the operator's Dreadblade): an attachment keeps
	-- its suffix and enchant -- parsed at the inbox edge, the one parser -- so a "Dreadblade of the
	-- Bear" in the mail is the same record as the one in the bags, two of one variant merge, two
	-- variants stay apart, and the sender is keyed by that record.
	it("keeps a suffixed and an enchanted attachment's variant, merges one variant across mails and keeps two apart", function()
		local function suffixed(sender, id, count, suffix, enchant)
			return { sender = sender, subject = "x", cod = 0, items = { { name = "Dreadblade", id = id, count = count,
				link = ("|cff1eff00|Hitem:%d:%d:0:0:0:0:%d:0:60|h[Dreadblade]|h|r"):format(id, enchant or 0, suffix or 0) } } }
		end
		env.wow.mail = { suffixed(PEER, 17240, 1, 1196), suffixed(OTHER, 17240, 1, 1196), suffixed(PEER, 17240, 1, 1195), suffixed(OTHER, 17240, 1, 0, 2504) }
		local MI = TOGBankClassic_MailInventory
		MI.hasUpdated = true
		local data = MI:ScanMailInventory()
		local R = TOGBankClassic_Inventory_Record
		local byKey = {}
		for _, rec in ipairs(data.items) do byKey[R.key(rec)] = R.count(rec) end
		assert.same({ ["17240:1196:0"] = 2, ["17240:1195:0"] = 1, ["17240:0:2504"] = 1 }, byKey,
			"the mail records lost the variant, or did not merge one variant across two mails")
		assert.same({ [PEER] = 1, [OTHER] = 1 }, data.senders["17240:1196:0"])
		local senderKeys = {}
		for k in pairs(data.senders) do senderKeys[#senderKeys + 1] = k end
		table.sort(senderKeys)
		assert.same({ "17240:0:2504", "17240:1195:0", "17240:1196:0" }, senderKeys, "the senders are not keyed by the full record key")
		env.wow.mail = {}
	end)

	it("answers nil, and no senders, when the mailbox was not read", function()
		local MI = TOGBankClassic_MailInventory
		MI.hasUpdated = false
		assert.is_nil(MI:ScanMailInventory())
	end)
end)

describe("step 4: the `who` rides the chain link and comes back on apply", function()
	before_each(function() env.reset(); client("Bankchar") end)

	it("survives the link body byte-for-byte and is restored onto the delta", function()
		env.freshV2()
		local Chain = TOGBankClassic_Inventory_Chain
		local DC = TOGBankClassic_DeltaComms
		local before, after = { Rec(14256, 20) }, { Rec(14256, 12) }
		local parent = DC:ComputeCanonHash(before, nil, nil, 0, T)
		local canon  = DC:ComputeCanonHash(after,  nil, nil, 0, T + 60)
		local who = { ["14256:0:0"] = { { count = 8, to = PEER } } }
		local delta = Chain:Record(GUILD, BANKER, { records = before, money = 0 }, { records = after, money = 0 }, parent, canon, who)
		assert.same(who, delta.who)
		local links = Chain:Links(GUILD, BANKER)
		assert.equal(1, #links)
		local _, _, applied = Chain:Apply(before, 0, links[1].body, links[1])
		assert.same(who, applied.who, "the attribution did not come back off the wire")
		-- And a link with no `who` carries none, so the body stays small.
		Chain:Clear(GUILD, BANKER)
		Chain:Record(GUILD, BANKER, { records = before, money = 0 }, { records = after, money = 0 }, parent, canon)
		assert.is_nil(Chain:Links(GUILD, BANKER)[1].body:find("who", 1, true))
	end)
end)
