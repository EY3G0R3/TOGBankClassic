-- P2P-035: banker NUMBERS -- minted by a banker account, for life, four digits, synced everywhere --
-- and the fixed-width wire that names bankers by them.
--
-- The operator's rules, verbatim, are quoted at the top of Modules/BankerNumbers.lua. Each example
-- below is one of them.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local C = env.canon
local T = 1757000000
local GUILD = "Testguild"

local LIGHT = { "Modules/Constants.lua", "Modules/Item.lua", "Modules/DeltaComms.lua",
	"Modules/Bank.lua", "Modules/Guild.lua", "Modules/BankerNumbers.lua" }

local A, B, Cc, D = "Alpha-Testrealm", "Beta-Testrealm", "Charlie-Testrealm", "Delta-Testrealm"

describe("BankerNumbers: the table on the roster", function()
	local BN, Guild
	local banks

	before_each(function()
		env.reset(); env.stubOutput()
		env.loadModules(LIGHT)
		BN, Guild = TOGBankClassic_BankerNumbers, TOGBankClassic_Guild
		Guild.Info = { name = GUILD, alts = {} }
		banks = { Cc, A, B }   -- deliberately unsorted
		Guild.GetBanks = function() return banks end
		Guild.IsBank = function(_, n) for _, b in ipairs(banks) do if b == n then return true end end return false end
		env.sent = {}
		TOGBankClassic_Core = {
			SerializeWithChecksum = function(_, t) return t end,
			SendWhisper = function(_, prefix, data, target, prio)
				env.sent[#env.sent + 1] = { prefix = prefix, data = data, target = target, prio = prio }
				return true
			end,
		}
	end)

	--- This account owns `name`: a record only a local scan writes.
	local function own(name)
		Guild.Info.alts[name] = { name = name, items = { { ID = 1, Count = 1 } }, inventoryContentHash = 12345 }
	end

	it("creates the columns on Info.roster beside the banker list, and nothing else", function()
		local r = BN:Table()
		assert.same({}, r.numbers)
		assert.equal(1, r.numbersNext)
		assert.equal(0, r.numbersVersion)
		assert.equal(r, Guild.Info.roster)
	end)

	it("formats every number as four zero-padded digits -- 0001 first, 9999 last", function()
		assert.equal("0001", BN:Format(1))
		assert.equal("9999", BN:Format(9999))
		assert.equal(9999, BN.MAX)
	end)

	-- "no, not a USER setting ... you have an alphabetical list of ALL my bankers right now. you can
	-- just go in and give the one closes to A a 1"
	it("mints the current roster A->Z from 0001, only when this account owns a banker", function()
		assert.equal(0, BN:Mint(), "an account that owns no banker minted numbers")
		assert.is_nil(BN:NumberOf(A))
		own(B)
		assert.equal(3, BN:Mint())
		assert.equal("0001", BN:NumberOf(A))
		assert.equal("0002", BN:NumberOf(B))
		assert.equal("0003", BN:NumberOf(Cc))
		assert.equal(A, BN:NameOf("0001"))
		assert.equal(Cc, BN:NameOf("0003"))
		assert.is_nil(BN:NameOf("0004"))
		assert.is_true(BN:Version() > 0)
	end)

	-- "when new bankers are added or removed, you update the table" + "numbers are for life ... if a
	-- banker comes back, no problem"
	it("appends a new banker at the next number, keeps a removed banker's number, and gives it back on return", function()
		own(A)
		BN:Mint()
		local v1 = BN:Version()
		banks = { A, B, Cc, D }
		assert.equal(1, BN:Mint())
		assert.equal("0004", BN:NumberOf(D), "a new banker did not get the next number")
		assert.is_true(BN:Version() > v1, "the version did not rise on a mint")

		banks = { A, Cc, D }                  -- Beta leaves
		assert.equal(0, BN:Mint())
		assert.equal("0002", BN:NumberOf(B), "a removed banker lost its number")
		banks = { A, B, Cc, D }               -- Beta returns
		assert.equal(0, BN:Mint(), "a returning banker was re-minted")
		assert.equal("0002", BN:NumberOf(B))
		assert.equal(5, BN:Table().numbersNext, "a number was reused")
	end)

	it("does not mint the same thing twice, and the version only moves when something was minted", function()
		own(A)
		BN:Mint()
		local v = BN:Version()
		assert.equal(0, BN:Mint())
		assert.equal(v, BN:Version())
	end)

	it("keeps the version strictly rising even when two mints land in the same second", function()
		own(A)
		BN:Mint()
		local v1 = BN:Version()
		banks = { A, B, Cc, D }
		BN:Mint()   -- same GetServerTime
		assert.is_true(BN:Version() > v1)
	end)

	it("stops at 9999 and says so once", function()
		own(A)
		local r = BN:Table()
		r.numbersNext = 9999
		banks = { A, B }
		assert.equal(1, BN:Mint())
		assert.equal("9999", BN:NumberOf(A))
		assert.is_nil(BN:NumberOf(B), "a number past 9999 was issued")
	end)
end)

describe("BankerNumbers: adopting a peer's table", function()
	local BN, Guild
	local banks

	before_each(function()
		env.reset(); env.stubOutput()
		env.loadModules(LIGHT)
		BN, Guild = TOGBankClassic_BankerNumbers, TOGBankClassic_Guild
		Guild.Info = { name = GUILD, alts = {} }
		banks = { A, B }
		Guild.GetBanks = function() return banks end
		Guild.IsBank = function(_, n) for _, b in ipairs(banks) do if b == n then return true end end return false end
		-- env.playerName is "Bankchar": this client is Bankchar-Testrealm.
	end)

	local function own(name)
		Guild.Info.alts[name] = { name = name, items = { { ID = 1, Count = 1 } }, inventoryContentHash = 12345 }
	end

	it("takes a NEWER table wholesale -- '100% synced, the same on EVERY client'", function()
		assert.is_true(BN:Adopt({ v = 50, n = 3, t = { [A] = 1, [B] = 2 } }, "Anyone-Testrealm"))
		assert.equal("0001", BN:NumberOf(A))
		assert.equal("0002", BN:NumberOf(B))
		assert.equal(50, BN:Version())
		assert.equal(3, BN:Table().numbersNext)
	end)

	it("ignores an OLDER table, and an identical one at the same version", function()
		BN:Adopt({ v = 50, n = 3, t = { [A] = 1, [B] = 2 } }, "Anyone-Testrealm")
		assert.is_false(BN:Adopt({ v = 40, n = 2, t = { [A] = 9 } }, "Anyone-Testrealm"))
		assert.equal("0001", BN:NumberOf(A), "an older table displaced a newer one")
		assert.is_false(BN:Adopt({ v = 50, n = 3, t = { [A] = 1, [B] = 2 } }, "Aaa-Testrealm"))
	end)

	-- Two banker accounts minted independently in the same second from different rosters. One
	-- table has to win everywhere, and the same one on every client: the lower-sorting SENDER's.
	it("resolves a same-version conflict in favour of the lower-sorting sender, on both sides", function()
		BN:Adopt({ v = 50, n = 2, t = { [A] = 1 } }, "Zed-Testrealm")
		-- We are Bankchar. A conflicting table from Aaa (sorts below us) wins ...
		assert.is_true(BN:Adopt({ v = 50, n = 2, t = { [B] = 1 } }, "Aaa-Testrealm"))
		assert.equal("0001", BN:NumberOf(B))
		-- ... and one from Zed (sorts above us) does not.
		assert.is_false(BN:Adopt({ v = 50, n = 2, t = { [Cc] = 1 } }, "Zed-Testrealm"))
		assert.equal("0001", BN:NumberOf(B))
	end)

	it("re-mints the roster bankers the adopted table lacks, under a higher version, when it may mint", function()
		own(A)
		assert.is_true(BN:Adopt({ v = 50, n = 2, t = { [B] = 1 } }, "Other-Testrealm"))
		assert.equal("0001", BN:NumberOf(B), "the adopted entry was not kept")
		assert.equal("0002", BN:NumberOf(A), "our own banker was left unnumbered after adopting")
		assert.is_true(BN:Version() > 50, "the re-mint did not raise the version, so the peer never adopts it back")
	end)

	it("never lets numbersNext fall below a number in the adopted table", function()
		BN:Adopt({ v = 50, n = 1, t = { [A] = 7 } }, "Other-Testrealm")   -- a lying `n`
		assert.equal(8, BN:Table().numbersNext)
	end)

	it("drops junk entries rather than adopting them", function()
		BN:Adopt({ v = 50, n = 3, t = { [A] = 1, [B] = "two", [Cc] = 0, [D] = 10000, [42] = 5 } }, "Other-Testrealm")
		assert.equal("0001", BN:NumberOf(A))
		assert.is_nil(BN:NumberOf(B))
		assert.is_nil(BN:NumberOf(Cc))
		assert.is_nil(BN:NumberOf(D))
	end)

	it("refuses anything that is not a table with a table in it", function()
		assert.is_false(BN:Adopt(nil, "x"))
		assert.is_false(BN:Adopt("junk", "x"))
		assert.is_false(BN:Adopt({ v = 99 }, "x"))
		assert.equal(0, BN:Version())
	end)
end)

describe("BankerNumbers: sync", function()
	local BN, Guild

	before_each(function()
		env.reset(); env.stubOutput()
		env.loadModules(LIGHT)
		BN, Guild = TOGBankClassic_BankerNumbers, TOGBankClassic_Guild
		Guild.Info = { name = GUILD, alts = {}, roster = { alts = {}, numbers = { [A] = 1 }, numbersNext = 2, numbersVersion = 10 } }
		env.sent = {}
		TOGBankClassic_Core = {
			SerializeWithChecksum = function(_, t) return t end,
			SendWhisper = function(_, prefix, data, target, prio)
				env.sent[#env.sent + 1] = { prefix = prefix, data = data, target = target, prio = prio }
				return true
			end,
		}
	end)

	it("asks the sender for the table when it advertises a HIGHER version, once per cooldown", function()
		assert.is_false(BN:OnAdvertisedVersion("Peer-Testrealm", 10), "asked for a table we already hold")
		assert.is_false(BN:OnAdvertisedVersion("Peer-Testrealm", 9))
		assert.equal(0, #env.sent)
		assert.is_true(BN:OnAdvertisedVersion("Peer-Testrealm", 11))
		assert.equal(1, #env.sent)
		assert.equal("togbank-hl", env.sent[1].prefix)
		assert.equal("numbers-request", env.sent[1].data.type)
		assert.equal("Peer-Testrealm", env.sent[1].target)
		assert.is_false(BN:OnAdvertisedVersion("Other-Testrealm", 11), "a second request for the same version went out inside the cooldown")
		env.advance(BN.REQUEST_COOLDOWN + 1)
		assert.is_true(BN:OnAdvertisedVersion("Other-Testrealm", 11))
	end)

	it("answers a request with the whole table, and adopts a reply", function()
		assert.is_true(BN:HandleRequest("Asker-Testrealm"))
		local m = env.sent[1]
		assert.equal("numbers-reply", m.data.type)
		assert.equal(10, m.data.numbers.v)
		assert.equal(1, m.data.numbers.t[A])
		assert.is_true(BN:HandleReply("Peer-Testrealm", { v = 12, n = 3, t = { [A] = 1, [B] = 2 } }))
		assert.equal("0002", BN:NumberOf(B))
	end)
end)

describe("BankerNumbers: the fixed-width wire", function()
	local BN

	before_each(function()
		env.reset(); env.stubOutput()
		env.loadModules(LIGHT)
		BN = TOGBankClassic_BankerNumbers
		TOGBankClassic_Guild.Info = { name = GUILD, alts = {}, roster = { alts = {}, numbers = { [A] = 1, [B] = 2 }, numbersNext = 3, numbersVersion = 1 } }
	end)

	it("encodes <number><canon> entries at exactly 24 characters each, with no separators", function()
		local s = BN:EncodeEntries({ { number = "0001", canon = C(T, 1) }, { number = "0002", canon = C(T, 2) } })
		assert.equal(48, #s)
		assert.equal("0001" .. C(T, 1) .. "0002" .. C(T, 2), s)
		local back = BN:DecodeEntries(s)
		assert.equal(2, #back)
		assert.equal("0002", back[2].number)
		assert.equal(C(T, 2), back[2].canon)
	end)

	it("drops a malformed entry on encode and decodes a torn string to NOTHING, never to a prefix", function()
		assert.equal("", BN:EncodeEntries({ { number = "1", canon = C(T, 1) }, { number = "0001", canon = "short" } }))
		assert.same({}, BN:DecodeEntries("0001" .. C(T, 1) .. "0002"))   -- 28 chars: torn
		assert.same({}, BN:DecodeEntries("000x" .. C(T, 1)))
		assert.same({}, BN:DecodeEntries(nil))
		assert.same({}, BN:DecodeEntries(""))
	end)

	it("encodes bare numbers four characters each", function()
		local s = BN:EncodeNumbers({ "0001", "0004", "0014", "bad", "00001" })
		assert.equal("000100040014", s)
		assert.same({ "0001", "0004", "0014" }, BN:DecodeNumbers(s))
		assert.same({}, BN:DecodeNumbers("00010"))
	end)

	it("decodes entries into the advertised-summary shape by name, counting numbers it cannot name", function()
		local alts, unknown = BN:EntriesToAlts(BN:DecodeEntries(
			BN:EncodeEntries({ { number = "0002", canon = C(T, 2) }, { number = "0009", canon = C(T, 9) } })))
		assert.equal(1, unknown)
		assert.is_nil(alts[A])
		assert.equal(C(T, 2), alts[B].hashV2)
		assert.equal(T, alts[B].updatedAt, "the publish time was not read off the canon")
	end)

	it("a whole roster of 38 bankers is under 1 KB", function()
		local entries = {}
		for i = 1, 38 do entries[i] = { number = BN:Format(i), canon = C(T + i, i) } end
		assert.equal(38 * 24, #BN:EncodeEntries(entries))
		assert.is_true(38 * 24 < 1024)
	end)
end)

-- ---------------------------------------------------------------------------------------------
-- Through the real receive paths, on a whole client.
-- ---------------------------------------------------------------------------------------------
describe("BankerNumbers through the real wire", function()
	local BANKER, OTHER, PEER = "Bankchar-Testrealm", "Otherbanker-Testrealm", "Otherguy-Testrealm"

	local function client(who)
		env.standUpClient(who, {
			{ name = BANKER, note = "gbank" }, { name = OTHER, note = "gbank" }, { name = PEER },
		}, GUILD)
	end

	local sent
	local function capture()
		sent = {}
		TOGBankClassic_Chat.hashBroadcastQueue = TOGBankClassic_Chat.hashBroadcastQueue or {}
		TOGBankClassic_Chat.HASH_BROADCAST_BATCH_DELAY = 0.15
		TOGBankClassic_Core.SendWhisper = function(_, prefix, text, target)
			local ok, data = TOGBankClassic_Core:DeserializeWithChecksum(text)
			sent[#sent + 1] = { prefix = prefix, data = ok and data or nil, target = target }
		end
	end
	local function whisperFrom(sender, payload)
		local body = TOGBankClassic_Core:SerializeWithChecksum(payload)
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "WHISPER", sender)
	end
	local function broadcastFrom(sender, payload)
		local body = TOGBankClassic_Core:SerializeWithChecksum(payload)
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "GUILD", sender)
	end

	before_each(function() env.reset(); client("Otherguy"); capture() end)

	it("a broadcast from a client on a newer table makes us ask for it, and the reply is adopted", function()
		local BN = TOGBankClassic_BankerNumbers
		-- The client is Otherguy; broadcasts come from Bankchar (its own echo would be discarded).
		broadcastFrom(BANKER, { type = "hlb2", v = 5, e = "", banker = BANKER, isBanker = true })
		local req
		for _, m in ipairs(sent) do if m.data and m.data.type == "numbers-request" then req = m end end
		assert.is_table(req, "a higher table version went by and we did not ask for the table")
		assert.equal(BANKER, req.target)
		whisperFrom(BANKER, { type = "numbers-reply", numbers = { v = 5, n = 3, t = { [BANKER] = 1, [OTHER] = 2 } } })
		assert.equal("0002", BN:NumberOf(OTHER))
		assert.equal(5, BN:Version())
	end)

	it("decodes a numbered broadcast into the advertised-hash cache and the tab's newest time", function()
		local BN = TOGBankClassic_BankerNumbers
		BN:Adopt({ v = 5, n = 3, t = { [BANKER] = 1, [OTHER] = 2 } }, PEER)
		broadcastFrom(BANKER, { type = "hlb2", v = 5, banker = BANKER, isBanker = true,
			e = BN:EncodeEntries({ { number = "0002", canon = C(T, 0x20) } }) })
		env.advance(1)   -- the batch timer
		local cached = TOGBankClassic_Guild.latestBankerHashes and TOGBankClassic_Guild.latestBankerHashes[OTHER]
		assert.is_table(cached, "the numbered broadcast never reached the cache")
		assert.equal(C(T, 0x20), cached.hashV2)
		assert.equal(T, TOGBankClassic_Guild.newestAdvertisedAt[OTHER])
	end)

	it("answers a numbered broadcast with a number-only offer", function()
		local BN = TOGBankClassic_BankerNumbers
		BN:Adopt({ v = 5, n = 3, t = { [BANKER] = 1, [OTHER] = 2 } }, PEER)
		TOGBankClassic_Guild.Info.alts[OTHER] = {
			name = OTHER, items = { { ID = 1, Count = 1 } }, money = 0,
			inventoryHash = 0x10, inventoryHashV2 = C(T + 60, 0x21), inventoryUpdatedAt = T + 60, mailHash = 0,
		}
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, OTHER, { TOGBankClassic_Inventory_Record.new(1, 1) }, 0)
		broadcastFrom(BANKER, { type = "hlb2", v = 5, banker = BANKER, isBanker = true,
			e = BN:EncodeEntries({ { number = "0002", canon = C(T, 0x20) } }) })
		env.advance(1)
		local offer
		for _, m in ipairs(sent) do if m.data and m.data.type == "hash-offer2" then offer = m end end
		assert.is_table(offer, "no offer went back")
		assert.equal("0002", offer.data.n)
		assert.equal(5, offer.data.v)
	end)

	-- "OH YES!" -- every broadcast is an offer. Hearing a peer advertise a version newer than ours
	-- is that peer saying "I hold newer"; we ask it, naming the version, without waiting for our own
	-- next broadcast to be answered. This is what fetches a banker's fresh scan within seconds.
	it("asks a broadcaster for a version newer than ours, straight from its broadcast, naming that version", function()
		local BN = TOGBankClassic_BankerNumbers
		BN:Adopt({ v = 5, n = 3, t = { [BANKER] = 1, [OTHER] = 2 } }, PEER)
		TOGBankClassic_Guild.Info.alts[OTHER] = {
			name = OTHER, items = { { ID = 1, Count = 1 } }, money = 0,
			inventoryHash = 0x10, inventoryHashV2 = C(T, 0x20), inventoryUpdatedAt = T, mailHash = 0,
		}
		assert.is_false(TOGBankClassic_P2PSession.isCollecting, "precondition: no collect window is open")
		broadcastFrom(BANKER, { type = "hlb2", v = 5, banker = BANKER, isBanker = true,
			e = BN:EncodeEntries({ { number = "0002", canon = C(T + 60, 0x21) } }) })
		env.advance(1)
		local req
		for _, m in ipairs(sent) do if m.prefix == "togbank-rr" and m.data and m.data.type == "sync-request" then req = m end end
		assert.is_table(req, "a broadcast advertising a newer version was not treated as an offer")
		assert.equal(BANKER, req.target)
		assert.equal(OTHER, req.data.altName)
		assert.equal(C(T + 60, 0x21), req.data.canon, "the request did not name the advertised version")
	end)

	it("does not ask a broadcaster for a version we already hold, or an older one", function()
		local BN = TOGBankClassic_BankerNumbers
		BN:Adopt({ v = 5, n = 3, t = { [BANKER] = 1, [OTHER] = 2 } }, PEER)
		TOGBankClassic_Guild.Info.alts[OTHER] = {
			name = OTHER, items = { { ID = 1, Count = 1 } }, money = 0,
			inventoryHash = 0x10, inventoryHashV2 = C(T, 0x20), inventoryUpdatedAt = T, mailHash = 0,
		}
		broadcastFrom(BANKER, { type = "hlb2", v = 5, banker = BANKER, isBanker = true,
			e = BN:EncodeEntries({ { number = "0002", canon = C(T, 0x20) } }) })
		broadcastFrom(BANKER, { type = "hlb2", v = 5, banker = BANKER, isBanker = true,
			e = BN:EncodeEntries({ { number = "0002", canon = C(T - 60, 0x19) } }) })
		env.advance(1)
		for _, m in ipairs(sent) do
			assert.is_not_equal("sync-request", m.data and m.data.type, "requested a version no newer than ours")
		end
	end)

	-- A brand-new bank account owns nothing until its first scan writes inventoryContentHash, and
	-- minting used to wait for the next roster rebuild -- the next login -- so the setup steps
	-- ("open and close your bank, then /togbank roster") showed no number, and the post-scan
	-- broadcast left the new banker out. The scan that makes the account eligible now mints.
	it("a bank account's FIRST scan numbers the roster, so its own post-scan broadcast can carry it", function()
		env.reset(); client("Bankchar"); capture()
		local BN = TOGBankClassic_BankerNumbers
		assert.is_nil(BN:NumberOf(BANKER), "precondition: nothing is numbered before the first scan")
		env.defineItem(858, { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 858, count = 5 } })
		TOGBankClassic_Bank.hasUpdated = true
		TOGBankClassic_Bank.eventsRegistered = false
		TOGBankClassic_Bank:Scan()
		assert.is_not_nil(TOGBankClassic_Guild.Info.alts[BANKER].inventoryContentHash, "precondition: the scan stored a content hash")
		assert.equal("0001", BN:NumberOf(BANKER), "the scan that made this account a banker-owner did not number the roster")
		assert.equal("0002", BN:NumberOf(OTHER), "the other banker was not numbered alongside (alphabetical from next)")
		assert.is_true(BN:Version() > 0)
	end)

	it("SyncDeltaVersion emits a numbered broadcast carrying only numbered, servable canons", function()
		local BN = TOGBankClassic_BankerNumbers
		BN:Adopt({ v = 5, n = 3, t = { [BANKER] = 1, [OTHER] = 2 } }, PEER)
		-- OTHER: numbered and servable. BANKER: numbered, canon, but NO tuple records -> not servable.
		for _, name in ipairs({ OTHER, BANKER }) do
			TOGBankClassic_Guild.Info.alts[name] = {
				name = name, items = { { ID = 1, Count = 1 } }, money = 0,
				inventoryHash = 0x10, inventoryHashV2 = C(T, 0x20), inventoryUpdatedAt = T, mailHash = 0,
			}
		end
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, OTHER, { TOGBankClassic_Inventory_Record.new(1, 1) }, 0)
		local guildSends = {}
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, text, dist)
			local ok, data = TOGBankClassic_Core:DeserializeWithChecksum(text)
			guildSends[#guildSends + 1] = { prefix = prefix, data = ok and data or nil, dist = dist }
		end
		TOGBankClassic_Events:SyncDeltaVersion("NORMAL")
		local b
		for _, m in ipairs(guildSends) do if m.data and m.data.type == "hlb2" then b = m end end
		assert.is_table(b, "no numbered broadcast went out")
		assert.equal("GUILD", b.dist)
		assert.equal(5, b.data.v)
		local entries = BN:DecodeEntries(b.data.e)
		assert.equal(1, #entries, "an unservable canon was advertised")
		assert.equal("0002", entries[1].number)
		assert.equal(C(T, 0x20), entries[1].canon)
		assert.is_nil(b.data.alts, "the keyed table is still on the wire")
	end)
end)
