-- LOGAPI-001: the bank-log API another addon reads. The operator, 2026-08-17: "create a 'log' API
-- to allow TOGTools to pull data for the bank log"; 2026-09-11: "it should work like the in game
-- bank log" and "the log can't persist, i don't want to use SV space on it ... TOGTools ... will
-- persist it."
--
-- So: a TRANSACTION feed in Blizzard's shape (GetGuildBankTransaction -- deposit/withdraw/money per
-- banker, plus request events), recorded from real transitions on a WHOLE client, pushed to a
-- consumer's callback, held in memory only.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local C = env.canon
local T = 1757000000
local GUILD = "Testguild"
local BANKER, OTHER, PEER = "Bankchar-Testrealm", "Otherbanker-Testrealm", "Otherguy-Testrealm"

local Log, Guild

local function client(who)
	env.standUpClient(who, {
		{ name = BANKER, note = "gbank" }, { name = OTHER, note = "gbank" }, { name = PEER },
	}, GUILD)
	Log, Guild = TOGBankClassic_Log, TOGBankClassic_Guild
	Log.buffers = {}   -- the env resets globals, not this module's session state
	Log.diffedThisSession = nil
	env.now = T        -- a live client never reads a server time of 0; a scan stamps this as its publish time
	assert.is_true(Guild:IsBank(BANKER), "precondition: the roster did not come up")
	-- Mutations broadcast; the wire is not under test here.
	TOGBankClassic_Core.SendCommMessage = function() end
	TOGBankClassic_Core.SendWhisper = function() return true end
end

local function place(item, itemID, qty, bank, requester, at)
	local ok = Guild:AddRequest({
		date = at, requester = requester or PEER, bank = bank or BANKER,
		item = item, itemID = itemID, quantity = qty, fulfilled = 0, notes = "",
	})
	assert.is_true(ok, "precondition: AddRequest refused " .. tostring(item))
	for id, r in pairs(Guild.Info.requests) do
		if r.item == item and r.date == at then return id end
	end
	error("placed request not found")
end

local function ofType(entries, t)
	local out = {}
	for _, e in ipairs(entries) do if e.type == t then out[#out + 1] = e end end
	return out
end

local Rec = function(id, n, suffix) return TOGBankClassic_Inventory_Record.new(id, n, suffix) end

describe("LOGAPI-001: request transactions", function()
	before_each(function() env.reset(); client("Otherguy"); env.defineItem(14256, { name = "Felcloth" }) end)

	it("is versioned, and lists every type it can emit", function()
		assert.equal(1, Log.API_VERSION)
		for _, t in ipairs({ "deposit", "withdraw", "money-deposit", "money-withdraw",
				"requested", "mailed", "handed", "cancelled", "reopened" }) do
			assert.is_true(Log.TYPES[t], t .. " is missing from TYPES")
		end
	end)

	it("returns an empty table, never nil, with no guild", function()
		Guild.Info = nil
		assert.same({}, Log:GetEntries())
		assert.same({}, Log:GetBankers())
	end)

	it("records 'requested' when a request is placed -- who asked whom for what", function()
		local id = place("Felcloth", 14256, 20, BANKER, PEER, T)
		local r = ofType(Log:GetEntries(), "requested")
		assert.equal(1, #r)
		assert.equal(T, r[1].ts)
		assert.equal(PEER, r[1].name, "the name on a request is the requester, as on a deposit it is the depositor")
		assert.equal(BANKER, r[1].to)
		assert.equal("Felcloth", r[1].item)
		assert.equal(14256, r[1].itemID)
		assert.equal(20, r[1].count)
		assert.equal(id, r[1].requestId)
	end)

	it("records EVERY fill as its own 'mailed' transaction with that fill's count -- the in-game log shape", function()
		local id = place("Felcloth", 14256, 20, BANKER, PEER, T)
		assert.equal(5, Guild:FulfillRequestById(id, 5, BANKER))
		assert.equal(15, Guild:FulfillRequestById(id, 15, BANKER))
		local m = ofType(Log:GetEntries(), "mailed")
		local h = ofType(Log:GetEntries(), "handed")
		-- FulfillRequestById closes the order as "complete" on the final fill (a hand-off).
		assert.equal(2, #m + #h, "two fills must be two transactions, not one running total")
		local counts = {}
		for _, e in ipairs(m) do counts[#counts + 1] = e.count end
		for _, e in ipairs(h) do counts[#counts + 1] = e.count end
		table.sort(counts)
		assert.same({ 5, 15 }, counts)
		assert.equal(BANKER, (m[1] or h[1]).name)
		assert.equal(PEER, (m[1] or h[1]).to)
	end)

	it("records a mail fulfilment through the by-name path as 'mailed'", function()
		place("Felcloth", 14256, 20, BANKER, PEER, T)
		assert.equal(8, Guild:FulfillRequest(BANKER, PEER, "Felcloth", 8))
		local m = ofType(Log:GetEntries(), "mailed")
		assert.equal(1, #m)
		assert.equal(8, m[1].count)
	end)

	it("records 'cancelled' with the reason, and 'reopened' when a finished order is re-opened", function()
		local id = place("Felcloth", 14256, 20, BANKER, PEER, T)
		assert.is_true(Guild:CancelRequest(id, PEER, "Found some myself"))
		local c = ofType(Log:GetEntries(), "cancelled")
		assert.equal(1, #c)
		assert.equal("Found some myself", c[1].note)
		assert.is_true(Guild:ReopenRequest(id, BANKER))
		assert.equal(1, #ofType(Log:GetEntries(), "reopened"))
	end)

	it("records a received mutation once, and our own echoed broadcast NOT AGAIN", function()
		local id = place("Felcloth", 14256, 20, BANKER, PEER, T)
		local req = Guild.Info.requests[id]
		-- The banker's fulfil arrives from the wire.
		assert.is_true(Guild:ApplyRequestMutation({ type = "fulfill", requestId = id, targetFulfilled = 5, ts = T + 10 }, BANKER))
		assert.equal(1, #ofType(Log:GetEntries(), "mailed"))
		-- The same mutation again (a relay, or our own echo): the state does not move, nothing is logged.
		assert.is_true(Guild:ApplyRequestMutation({ type = "fulfill", requestId = id, targetFulfilled = 5, ts = T + 10 }, BANKER))
		assert.equal(1, #ofType(Log:GetEntries(), "mailed"), "an idempotent re-apply was logged as a second fill")
		-- Our own "add" echoed back through the snapshot merge: the record is not newer, so the merge
		-- KEEPS ours (ApplyRequestMutation reports false -- nothing applied) and nothing is logged.
		assert.is_false(Guild:ApplyRequestMutation({ type = "add", requestId = id, request = req, ts = T }, PEER))
		assert.equal(1, #ofType(Log:GetEntries(), "requested"))
	end)

	it("names a request stored with a placeholder from its id (NAME-001)", function()
		env.defineItem(7969, { name = "Nightshade" })
		place("Item 7969", 7969, 3, BANKER, PEER, T)
		assert.equal("Nightshade", ofType(Log:GetEntries(), "requested")[1].item)
	end)
end)

describe("LOGAPI-001: bank transactions", function()
	before_each(function() env.reset(); client("Otherguy") end)

	it("diffs a delivered version against the one held: deposits, withdrawals and money", function()
		env.defineItem(858, { name = "Minor Healing Potion" })
		env.defineItem(2589, { name = "Linen Cloth" })
		env.defineItem(4306, { name = "Silk Cloth" })
		local before = { Rec(858, 5), Rec(2589, 40) }
		local after  = { Rec(858, 2), Rec(2589, 40), Rec(4306, 20) }
		assert.equal(3, Log:RecordInventoryChange(BANKER, before, after, 1000, 1500, T + 100))
		local entries = Log:GetEntries()
		local w, d, md = ofType(entries, "withdraw"), ofType(entries, "deposit"), ofType(entries, "money-deposit")
		assert.equal(1, #w); assert.equal(858, w[1].itemID); assert.equal(3, w[1].count); assert.equal("Minor Healing Potion", w[1].item)
		assert.equal(1, #d); assert.equal(4306, d[1].itemID); assert.equal(20, d[1].count)
		assert.equal(1, #md); assert.equal(500, md[1].money)
		for _, e in ipairs(entries) do
			assert.equal(BANKER, e.name)
			assert.equal(T + 100, e.ts, "a bank transaction is stamped with the author's publish time")
		end
	end)

	-- LOG-MAIL-001: the wire spelling of the author's entries, and the receiver's read of it.
	it("packs entries for the wire and unpacks them field by field, dropping what is malformed", function()
		env.defineItem(858, { name = "Minor Healing Potion" })
		env.defineItem(10132, { name = "Revenant Helmet" })
		local entries = Log:DiffEntries(BANKER,
			{ Rec(858, 5), Rec(10132, 1, 863) }, { Rec(858, 2), Rec(10132, 1, 863), Rec(10132, 1, 870) }, 100, 600,
			{ ["858:0"] = { { count = 3, to = PEER } }, ["10132:870"] = { { count = 1, from = OTHER } } })
		local packed = Log:PackEntries(entries)
		assert.same({
			{ t = "d", i = 10132, s = 870, c = 1, from = OTHER },
			{ t = "w", i = 858, c = 3, to = PEER },
			{ t = "D", m = 500 },
		}, packed)
		assert.is_nil(Log:PackEntries({}), "an empty list must put nothing on the wire")
		assert.is_nil(Log:PackEntries(nil))
		-- The read side: names resolved here, types mapped back, a `to` on a deposit ignored.
		local back = Log:UnpackEntries(packed, BANKER)
		assert.equal(3, #back)
		assert.equal("deposit", back[1].type); assert.equal(870, back[1].suffixID); assert.equal(OTHER, back[1].from); assert.equal("Revenant Helmet", back[1].item)
		assert.equal("withdraw", back[2].type); assert.is_nil(back[2].suffixID); assert.equal(PEER, back[2].to); assert.equal("Minor Healing Potion", back[2].item)
		assert.equal("money-deposit", back[3].type); assert.equal(500, back[3].money)
		-- Garbage from a peer: a wrong type letter, a missing count, a zero money, a non-table element.
		assert.same({}, Log:UnpackEntries({ { t = "x", i = 858, c = 1 }, { t = "d", i = 858 }, { t = "W", m = 0 }, "junk", { t = "d", i = "abc", c = 1 } }, BANKER))
		assert.same({}, Log:UnpackEntries(nil, BANKER))
	end)

	it("applies a snapshot's log window: only the links published after the version held, stamped with each link's time", function()
		env.defineItem(858, { name = "Minor Healing Potion" })
		local logs = {
			{ p = C(T, 1),      c = C(T + 10, 2), l = { { t = "d", i = 858, c = 1 } } },
			{ p = C(T + 10, 2), c = C(T + 20, 3), l = { { t = "d", i = 858, c = 2 } } },
			{ p = C(T + 20, 3), c = C(T + 30, 4), l = { { t = "w", i = 858, c = 1 } } },
			{ p = C(T + 30, 4), c = "not a canon", l = { { t = "d", i = 858, c = 9 } } },   -- unreadable: skipped
			"junk",
		}
		-- Holding the version published at T+10: the T+20 and T+30 links are new, the T+10 one is not.
		assert.equal(2, Log:ApplyWireLogs(BANKER, logs, T + 10))
		local got = Log:GetEntries()
		assert.equal(2, #got)
		assert.equal(T + 30, got[1].ts); assert.equal("withdraw", got[1].type); assert.equal(C(T + 20, 3), got[1].fromCanon); assert.equal(C(T + 30, 4), got[1].toCanon)
		assert.equal(T + 20, got[2].ts); assert.equal(2, got[2].count)
		assert.is_true(got[2].firstThisSession); assert.is_nil(got[1].firstThisSession)
		-- No earlier copy held: nothing, as a first delivery never logged anything.
		assert.equal(0, Log:ApplyWireLogs(BANKER, logs, nil))
		assert.equal(0, Log:ApplyWireLogs(BANKER, nil, T))
	end)

	-- LOG-MAIL-001: the sender of a TAKEN attachment is known only from the inbox read before the
	-- take, so every inbox update is compared with the last and what left it is remembered until
	-- the mint spends it. COD mail is never a candidate; a close ends the comparison.
	it("remembers who sent what LEFT the inbox between two reads, until the mint clears it", function()
		local MI = TOGBankClassic_MailInventory
		local silk = { name = "Silk Cloth", id = 4306, count = 12, link = "|cffffffff|Hitem:4306:0:0:0:0:0:0:0:60|h[Silk Cloth]|h|r" }
		local wool = { name = "Wool Cloth", id = 2592, count = 5, link = "|cffffffff|Hitem:2592:0:0:0:0:0:0:0:60|h[Wool Cloth]|h|r" }
		env.wow.mail = {
			{ sender = PEER, subject = "donation", items = { silk } },
			{ sender = OTHER, subject = "cod", cod = 500, items = { wool } },
		}
		assert.is_nil(MI:TakenSenders(), "something was taken before any read")
		MI:NoteInbox()                                  -- the open
		assert.is_nil(MI:TakenSenders(), "a read with nothing gone recorded a take")
		env.wow.mail = { { sender = OTHER, subject = "cod", cod = 500, items = { wool } } }
		MI:NoteInbox()                                  -- after the take of the silk
		assert.same({ ["4306:0"] = { [PEER] = 12 } }, MI:TakenSenders())
		env.wow.mail = {}
		MI:NoteInbox()                                  -- the COD mail gone (returned, or paid elsewhere): never a candidate
		assert.same({ ["4306:0"] = { [PEER] = 12 } }, MI:TakenSenders(), "a COD mail leaving the inbox was recorded as a take")
		-- A second take of the same item from the same sender adds up; a close then a reopen starts
		-- the comparison afresh (what was in the inbox while it was closed is not observed).
		MI:CloseInbox()
		env.wow.mail = { { sender = PEER, subject = "more", items = { { name = "Silk Cloth", id = 4306, count = 3, link = silk.link } } } }
		MI:NoteInbox()
		assert.same({ ["4306:0"] = { [PEER] = 12 } }, MI:TakenSenders(), "a reopen read counted the sitting mail as taken")
		env.wow.mail = {}
		MI:NoteInbox()
		assert.same({ ["4306:0"] = { [PEER] = 15 } }, MI:TakenSenders())
		MI:ClearTakenSenders()
		assert.is_nil(MI:TakenSenders())
		MI:CloseInbox()
	end)

	it("records nothing for the FIRST version held -- a fresh install is not a deposit of everything", function()
		assert.equal(0, Log:RecordInventoryChange(BANKER, nil, { Rec(858, 5) }, nil, 100, T))
		assert.equal(0, #Log:GetEntries())
	end)

	it("keeps suffix variants apart, and reads both row shapes", function()
		env.defineItem(10132, { name = "Revenant Helmet" })
		local before = { Rec(10132, 1, 863) }
		local after  = { { ID = 10132, Count = 1, Suffix = 863 }, { ID = 10132, Count = 1, Suffix = 870 } }
		assert.equal(1, Log:RecordInventoryChange(BANKER, before, after, 0, 0, T))
		local d = ofType(Log:GetEntries(), "deposit")
		assert.equal(1, #d)
		assert.equal(870, d[1].suffixID)
	end)

	-- LOG-MAIL-001: a RECEIVER NEVER DERIVES an entry. The author's link carries the entries it
	-- computed (over what it holds), and a snapshot carries the window's links' entries (Wire field
	-- 9); the viewer appends the author's rows, stamped with the author's times. A snapshot with no
	-- log window logs nothing -- the old held->delivered diff is gone, because it logged a mail
	-- sitting in the banker's inbox as a deposit on every viewer.
	it("is wired to a RECEIVED delivery: the viewer logs the banker's own entries with the banker's time, and derives none", function()
		-- Client A publishes two versions of its bank; client B receives both.
		env.defineItem(858, { name = "Minor Healing Potion" })
		local canon1
		local function publish(count, at, link)
			env.reset(); client("Bankchar")
			TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, BANKER, { Rec(858, count) }, 0)
			-- The record a scan leaves behind: Bank.lua stamps version/inventoryUpdatedAt itself and
			-- then mints the hashes; SendAltData puts inventoryUpdatedAt on the wire as the publish time.
			Guild.Info.alts[BANKER] = { name = BANKER, items = {}, money = 0, version = at, inventoryUpdatedAt = at }
			TOGBankClassic_Core:StampInventoryHashes(Guild.Info.alts[BANKER],
				TOGBankClassic_Inventory_Store:GetAltView(GUILD, BANKER), nil, nil, 0, at)
			local canon = Guild.Info.alts[BANKER].inventoryHashV2
			if link then link(canon) end
			local sent = {}
			TOGBankClassic_Core.SendCommMessage = function(_, prefix, text) sent[#sent + 1] = { prefix = prefix, text = text } end
			Guild:SendAltData(BANKER, 0, 0, PEER)
			for _, m in ipairs(sent) do if m.prefix == "togbank-d4" then return m.text, canon end end
			error("no payload")
		end
		local v1
		v1, canon1 = publish(5, T)
		-- The second version's link, as MintVersion writes it: the delta plus the author's entries.
		local v2 = publish(2, T + 60, function(canon2)
			local Chain = TOGBankClassic_Inventory_Chain
			local entries = Log:DiffEntries(BANKER, { Rec(858, 5) }, { Rec(858, 2) }, 0, 0, nil)
			assert.equal(1, #entries); assert.equal("withdraw", entries[1].type)
			Chain:Record(GUILD, BANKER, { records = { Rec(858, 5) }, money = 0 }, { records = { Rec(858, 2) }, money = 0 },
				canon1, canon2, nil, Log:PackEntries(entries))
		end)
		-- And a version published with NO link behind it (a chain the author does not hold).
		local v2bare = publish(2, T + 60)

		env.reset(); client("Otherguy"); env.defineItem(858, { name = "Minor Healing Potion" })
		TOGBankClassic_Chat:OnCommReceived("togbank-d4", v1, "WHISPER", BANKER)
		assert.equal(0, #Log:GetEntries(), "the first version held was logged as a transaction")
		TOGBankClassic_Chat:OnCommReceived("togbank-d4", v2, "WHISPER", BANKER)
		local w = ofType(Log:GetEntries(), "withdraw")
		assert.equal(1, #w, "the second version's entry did not arrive with the snapshot")
		assert.equal(3, w[1].count)
		assert.equal(T + 60, w[1].ts)
		assert.equal(BANKER, w[1].name)
		assert.equal("Minor Healing Potion", w[1].item, "the receiver did not resolve the item name off the wire entry")

		-- The same two versions, the second without a log window: nothing is derived.
		env.reset(); client("Otherguy"); env.defineItem(858, { name = "Minor Healing Potion" })
		TOGBankClassic_Chat:OnCommReceived("togbank-d4", v1, "WHISPER", BANKER)
		TOGBankClassic_Chat:OnCommReceived("togbank-d4", v2bare, "WHISPER", BANKER)
		assert.equal(0, #ofType(Log:GetEntries(), "withdraw"), "a receiver derived an entry from two full record sets")
		assert.equal(2, TOGBankClassic_Inventory_Store:GetAltItemTotal(GUILD, BANKER, 858), "the data itself was not stored")

		-- Back to the logged delivery for the rest of the assertions.
		env.reset(); client("Otherguy"); env.defineItem(858, { name = "Minor Healing Potion" })
		TOGBankClassic_Chat:OnCommReceived("togbank-d4", v1, "WHISPER", BANKER)
		TOGBankClassic_Chat:OnCommReceived("togbank-d4", v2, "WHISPER", BANKER)
		w = ofType(Log:GetEntries(), "withdraw")
		assert.equal(1, #w)
		-- The span is on the entry: which version it was diffed from and to, and that it is the
		-- first diff for this banker since login (its "before" is the copy held when we last looked).
		assert.is_string(w[1].fromCanon, "fromCanon missing")
		assert.is_string(w[1].toCanon, "toCanon missing")
		assert.is_not_equal(w[1].fromCanon, w[1].toCanon)
		assert.equal(TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2, w[1].toCanon, "toCanon is not the version now held")
		assert.is_true(w[1].firstThisSession, "the first diff of the session was not marked")
	end)

	it("marks only the FIRST diff per banker as firstThisSession, and chains fromCanon to the previous toCanon", function()
		env.defineItem(858, { name = "Minor Healing Potion" })
		local n = Log:RecordInventoryChange(BANKER, { Rec(858, 1) }, { Rec(858, 3) }, 0, 0, T + 25, C(T, 1), C(T + 25, 2))
		assert.equal(1, n)
		n = Log:RecordInventoryChange(BANKER, { Rec(858, 3) }, { Rec(858, 4) }, 0, 0, T + 50, C(T + 25, 2), C(T + 50, 3))
		assert.equal(1, n)
		local d = ofType(Log:GetEntries(), "deposit")   -- newest first
		assert.equal(2, #d)
		assert.is_nil(d[1].firstThisSession, "a later diff was marked as the first of the session")
		assert.is_true(d[2].firstThisSession)
		assert.equal(d[2].toCanon, d[1].fromCanon, "consecutive entries do not chain -- a reader could not tell a span from a step")
		-- Another banker's first diff is its own first.
		n = Log:RecordInventoryChange(OTHER, { Rec(858, 1) }, { Rec(858, 2) }, 0, 0, T + 75, nil, C(T + 75, 9))
		assert.equal(1, n)
		local o = Log:GetEntries({ bank = OTHER })
		assert.is_true(o[1].firstThisSession)
		assert.is_nil(o[1].fromCanon, "a pre-canon older copy must read as no fromCanon, not as a wrong one")
	end)

	it("is wired to the banker's OWN scan, and an unchanged rescan logs nothing", function()
		env.reset(); client("Bankchar")
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		TOGBankClassic_Bank.hasUpdated = true
		TOGBankClassic_Bank.eventsRegistered = false
		env.setBag(0, 4, { { id = 858, count = 5 } })
		TOGBankClassic_Bank:Scan()
		assert.equal(0, #Log:GetEntries(), "the first scan has nothing to diff against")
		env.advance(60)
		TOGBankClassic_Bank:Scan()
		assert.equal(0, #Log:GetEntries(), "an unchanged rescan logged a transaction")
		env.advance(60)
		env.setBag(0, 4, { { id = 858, count = 9 } })
		TOGBankClassic_Bank:Scan()
		local d = ofType(Log:GetEntries(), "deposit")
		assert.equal(1, #d)
		assert.equal(4, d[1].count)
		assert.equal(BANKER, d[1].name)
		assert.equal(T + 120, d[1].ts, "stamped with the scan's publish time, the one the canon carries")
	end)
end)

describe("LOGAPI-001: reading and filtering the session buffer", function()
	before_each(function() env.reset(); client("Otherguy") end)

	it("orders newest first and honours since, limit, types, bank and player", function()
		env.defineItem(14256, { name = "Felcloth" })
		env.defineItem(4306, { name = "Silk Cloth" })
		place("Felcloth", 14256, 20, BANKER, PEER, T)
		place("Silk Cloth", 4306, 10, OTHER, "Someone-Testrealm", T + 50)
		Log:RecordInventoryChange(BANKER, { Rec(858, 1) }, { Rec(858, 3) }, 0, 0, T + 25)

		local all = Log:GetEntries()
		assert.equal(3, #all)
		assert.is_true(all[1].ts >= all[2].ts and all[2].ts >= all[3].ts, "not newest first")

		assert.equal(2, #Log:GetEntries({ since = T }), "since must be strictly after")
		assert.equal(1, #Log:GetEntries({ limit = 1 }))
		assert.equal(0, #Log:GetEntries({ limit = 0 }))
		assert.equal(1, #Log:GetEntries({ types = { deposit = true } }))
		assert.equal(2, #Log:GetEntries({ bank = BANKER }), "bank filter: the request TO the banker and its deposit")
		assert.equal(1, #Log:GetEntries({ player = PEER }))
		assert.equal(1, #Log:GetEntries({ player = "Someone" }), "player filter did not normalise a short name")
	end)

	it("caps the buffer, keeping the newest", function()
		local cap = Log.MAX_ENTRIES
		for i = 1, cap + 10 do
			Log:Append({ ts = T + i, type = "deposit", name = BANKER, itemID = 1, count = 1 })
		end
		local all = Log:GetEntries()
		assert.equal(cap, #all)
		assert.equal(T + cap + 10, all[1].ts)
		assert.equal(T + 11, all[#all].ts, "the oldest were not the ones pruned")
	end)

	-- LOG-PERSIST-001. The operator, on a Log tab empty after /reload: "i think we do need some small
	-- amount of the bank log to persist in TOGBank, but not a lot." The buffer is the V2 store's
	-- guild table (`<guild>.log`, beside the delta chain) -- the same table, so an append is a save,
	-- the cap bounds the SavedVariables cost, and a reload reads it back. Nothing goes on the main
	-- guild record (TOGBankClassicDB), which is the per-character file.
	it("persists the capped buffer on the V2 store's guild table, and reads it back after a reload", function()
		local Store = TOGBankClassic_Inventory_Store
		Log:Append({ ts = T, type = "deposit", name = BANKER, itemID = 1, count = 1 })
		local saved = Store:GuildTable(GUILD, false).log
		assert.is_table(saved, "the log was not written to the store's guild table")
		assert.equal(1, #saved); assert.equal(T, saved[1].ts)
		for k in pairs(Guild.Info) do
			assert.is_not_equal("bankLog", k, "the log was written into the per-character guild record")
		end
		-- A reload: the in-memory cache is gone, the SavedVariable is what is left.
		Log.buffers = {}
		assert.equal(1, #Log:GetEntries(), "the saved entry did not come back after the cache was dropped")
		assert.equal(T, Log:GetEntries()[1].ts)
		-- The cap prunes the SAVED table, not a copy.
		for i = 1, Log.MAX_ENTRIES + 5 do
			Log:Append({ ts = T + i, type = "deposit", name = BANKER, itemID = 1, count = 1 })
		end
		assert.equal(Log.MAX_ENTRIES, #Store:GuildTable(GUILD, false).log, "the SavedVariable grew past the cap")
		assert.is_true(Log.MAX_ENTRIES <= 250, "'not a lot': the cap is " .. Log.MAX_ENTRIES)
	end)

	it("moves entries recorded before the store was up into the saved table, rather than caching them in memory for the session", function()
		local Store = TOGBankClassic_Inventory_Store
		local db = Store.db
		Store.db = nil                                   -- before Store:Init: Log.lua loads first
		Log.buffers = {}
		Log:Append({ ts = T, type = "deposit", name = BANKER, itemID = 1, count = 1 })
		assert.equal(1, #Log:GetEntries())
		Store.db = db                                    -- Store:Init has run
		Log:Append({ ts = T + 1, type = "deposit", name = BANKER, itemID = 1, count = 1 })
		local saved = Store:GuildTable(GUILD, false).log
		assert.equal(2, #saved, "the early entry stayed in memory and the later one went elsewhere")
		Log.buffers = {}
		assert.equal(2, #Log:GetEntries(), "after a reload only the saved table is left, and it must hold both")
	end)

	-- LOG-WIPE-001 (Peer Review db06c629): the first cut cached the store's log table for the session
	-- and, when a wipe replaced the guild table, poured every cached entry into the fresh one -- a
	-- wiped log came straight back. The store's table is read fresh on every call now; only entries
	-- recorded before the store was up are held here, and moved once.
	it("does not resurrect a wiped log from a session cache: append, wipe the guild table, append again -> only the second entry", function()
		local Store = TOGBankClassic_Inventory_Store
		Log:Append({ ts = T, type = "deposit", name = BANKER, itemID = 1, count = 1 })
		assert.equal(1, #Store:GuildTable(GUILD, false).log)
		assert.is_nil(Log.buffers[GUILD], "the store's table was cached on the module -- the wipe below cannot take effect")
		Store.db.faction[GUILD] = nil                     -- /togbank wipe: the guild table is replaced whole
		Log:Append({ ts = T + 1, type = "deposit", name = BANKER, itemID = 1, count = 1 })
		local saved = Store:GuildTable(GUILD, false).log
		assert.equal(1, #saved, "the wiped entries came back from the session cache")
		assert.equal(T + 1, saved[1].ts)
		assert.equal(1, #Log:GetEntries())
	end)

	it("returns copies, so a consumer may keep or mutate what it is handed", function()
		env.defineItem(14256, { name = "Felcloth" })
		place("Felcloth", 14256, 20, BANKER, PEER, T)
		local a = Log:GetEntries()
		a[1].item = "Mutated"
		assert.equal("Felcloth", Log:GetEntries()[1].item)
	end)

	it("lists the bankers with number, last scan time and tab state, A->Z", function()
		local BN = TOGBankClassic_BankerNumbers
		BN:Adopt({ v = 5, n = 3, t = { [BANKER] = 1, [OTHER] = 2 } }, PEER)
		Guild.Info.alts[BANKER] = { name = BANKER, money = 0,
			inventoryHash = 1, inventoryHashV2 = C(T, 7), inventoryUpdatedAt = T }
		env.holdV2(GUILD, BANKER, { { 858, 5 } })   -- INV2-RETIRE-003: content is the store's
		local b = Log:GetBankers()
		assert.equal(2, #b)
		assert.equal(BANKER, b[1].name)
		assert.equal("0001", b[1].number)
		assert.equal(T, b[1].lastScanned)
		assert.equal("current", b[1].state)
		assert.is_false(b[1].viewOnly)
		assert.equal(OTHER, b[2].name)
		assert.is_nil(b[2].lastScanned)
		assert.equal("none", b[2].state)
	end)
end)

describe("LOGAPI-001: the feed", function()
	before_each(function() env.reset(); client("Otherguy"); env.defineItem(14256, { name = "Felcloth" }) end)

	it("delivers ONE coalesced batch of NEW entries, oldest first, for a burst of changes", function()
		local batches = {}
		assert.is_true(Log:RegisterCallback("consumer", function(entries) batches[#batches + 1] = entries end))
		local id = place("Felcloth", 14256, 20, BANKER, PEER, T)
		Guild:FulfillRequestById(id, 5, BANKER)
		Guild:CancelRequest(id, PEER, "no longer needed")
		assert.equal(0, #batches, "delivered synchronously; it must coalesce")
		env.advance(1)
		assert.equal(1, #batches, "three transactions produced " .. #batches .. " deliveries")
		local types = {}
		for _, e in ipairs(batches[1]) do types[#types + 1] = e.type end
		assert.same({ "requested", "mailed", "cancelled" }, types)
	end)

	it("hands each consumer its own copies", function()
		local mine, theirs
		Log:RegisterCallback("a", function(entries) mine = entries end)
		Log:RegisterCallback("b", function(entries) theirs = entries end)
		place("Felcloth", 14256, 20, BANKER, PEER, T)
		env.advance(1)
		mine[1].item = "Mutated"
		assert.equal("Felcloth", theirs[1].item)
		assert.equal("Felcloth", Log:GetEntries()[1].item)
	end)

	it("also fires the AceEvent message with the batch, for consumers that embed AceEvent", function()
		local got
		TOGBankClassic_Events:RegisterMessage(Log.MESSAGE, function(_, entries) got = entries end)
		place("Felcloth", 14256, 20, BANKER, PEER, T)
		env.advance(1)
		assert.is_table(got, "TOGBANK_LOG_CHANGED did not fire")
		assert.equal("requested", got[1].type)
	end)

	it("keeps delivering to the others when one consumer's callback throws", function()
		local delivered = false
		Log:RegisterCallback("bad", function() error("consumer bug") end)
		Log:RegisterCallback("good", function() delivered = true end)
		place("Felcloth", 14256, 20, BANKER, PEER, T)
		assert.has_no_error(function() env.advance(1) end)
		assert.is_true(delivered)
	end)

	-- LOG-DEBUG-001: the operator, watching a banker's entries fail to reach a viewer: "is there
	-- debugging for the new log sync? is it exposed as a type in the debug tab so i can select it".
	-- Every line the log emits goes under its OWN category, so the Debug tab's LOG row isolates it.
	describe("LOG-DEBUG-001: every debug line the log emits is under the LOG category", function()
		local seen
		-- Only the log's own lines are formatted; the rest of the addon also logs during a request
		-- mutation (some without a tag), and those are recorded by category alone.
		before_each(function()
			seen = {}
			TOGBankClassic_Output.Debug = function(_, cat, tag, fmt, ...)
				local line = cat == "LOG" and string.format(fmt, ...) or nil
				seen[#seen + 1] = { cat = cat, tag = tag, line = line }
				return true
			end
		end)

		-- A name is a literal inside a Lua pattern only once its hyphen is escaped.
		local function lit(s) return (s:gsub("%-", "%%-")) end

		local function under(cat, tag)
			local out = {}
			for _, s in ipairs(seen) do if s.cat == cat and s.tag == tag then out[#out + 1] = s.line end end
			return out
		end

		it("says what was RECORDED, what was DELIVERED, and under nothing but LOG", function()
			Log:RegisterCallback("consumer", function() end)
			place("Felcloth", 14256, 20, BANKER, PEER, T)
			env.advance(1)
			assert.is_true(#under("LOG", "RECORD") >= 1, "no LOG/RECORD line for a placed request")
			assert.matches("requested: " .. lit(PEER) .. " %-> " .. lit(BANKER) .. " x20", under("LOG", "RECORD")[1])
			assert.is_true(#under("LOG", "DELIVER") >= 1, "no LOG/DELIVER line for the batch")
			assert.matches("batch of 1 entry to 1 callback", under("LOG", "DELIVER")[1])
			-- Other modules log under their own categories during the mutation; the pin that the
			-- LOG module cannot emit under another category is on its source: one Debug call site,
			-- and it names LOG.
			local f = assert(io.open("Modules/Log.lua", "r")); local src = f:read("*a"); f:close()
			local sites = {}
			for cat in src:gmatch("Output:Debug%(%s*\"(%u+)\"") do sites[#sites + 1] = cat end
			assert.same({ "LOG" }, sites)
		end)

		it("reports a consumer that threw under LOG / FAIL, naming the consumer", function()
			Log:RegisterCallback("bad", function() error("consumer bug") end)
			place("Felcloth", 14256, 20, BANKER, PEER, T)
			env.advance(1)
			local fails = under("LOG", "FAIL")
			assert.equal(1, #fails)
			assert.matches("log callback for bad failed: .*consumer bug", fails[1])
			assert.equal(0, #under("SYNC", "LOGAPI"), "the failure still went out under the old SYNC/LOGAPI spelling")
		end)

		it("says why an inventory change was NOT diffed, and how many entries a diff recorded", function()
			assert.equal(0, Log:RecordInventoryChange(BANKER, nil, { Rec(14256, 5) }, 0, 0, T, nil, C(T, 1)))
			assert.matches("NOT diffed: no earlier copy held", under("LOG", "RECORD")[1])
			seen = {}
			assert.equal(1, Log:RecordInventoryChange(BANKER, {}, { Rec(14256, 5) }, 0, 0, T, nil, C(T, 1)))
			local lines = under("LOG", "RECORD")
			assert.matches("diffing " .. lit(BANKER) .. ": 0 %-> 1 rows", lines[1])
			assert.matches("deposit: " .. lit(BANKER) .. " x5", lines[2])
			assert.matches("1 entry recorded %(first diff this session", lines[3])
		end)
	end)

	it("replaces a re-registration and honours unregister", function()
		local a, b = 0, 0
		Log:RegisterCallback("x", function() a = a + 1 end)
		Log:RegisterCallback("x", function() b = b + 1 end)
		place("Felcloth", 14256, 20, BANKER, PEER, T); env.advance(1)
		assert.equal(0, a); assert.equal(1, b)
		assert.is_true(Log:UnregisterCallback("x"))
		assert.is_false(Log:UnregisterCallback("x"))
		place("Felcloth", 14256, 20, BANKER, PEER, T + 1); env.advance(1)
		assert.equal(1, b)
	end)
end)

describe("LOGAPI-001: shipping", function()
	it("is listed in both TOCs, after RequestLog", function()
		for _, toc in ipairs({ "TOGBankClassic.toc", "TOGBankClassic_BCC.toc" }) do
			local src = env.readFile(toc)
			local rl, lg = src:find("Modules/RequestLog.lua", 1, true), src:find("Modules/Log.lua", 1, true)
			assert.truthy(lg, toc .. " does not ship Modules/Log.lua")
			assert.is_true(rl < lg, toc .. ": Log.lua must load after RequestLog.lua")
		end
	end)
end)
