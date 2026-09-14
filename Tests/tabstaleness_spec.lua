-- TABCOLOUR-002 / HASH-CANON-005: the Inventory tab colour, decided from the canon.
--
-- THE OPERATOR'S RULE, verbatim: "it has to ask which is newer, but v1 didn't do that well, with v2
-- we can. we need it to be newer, so v1 is always red, v2 does it by is someone newer." And on the
-- canon that makes it possible: "i wanted the hash to be <dts><hash> all one long string ... so you
-- COULD read the DTS and do quick/easy comparison without having to pull the hash apart."
--
-- So: the revision-2 canon is `<10-digit publish time><10-digit checksum>`; "am I behind?" is the
-- newest canon anyone has mentioned for a banker against the canon I hold, read off the front;
-- a held copy with no readable canon is red, full stop; our own character CAN be behind on its own
-- bank when another PC on a shared account published later (MULTIPC-001 -- the publish gate that
-- follows from it is multipc_spec's ground); and a broadcast is answered with an offer by ONE
-- string compare.
--
-- Every writer of "newest mentioned" is driven through the real receive path below, because the
-- previous mechanism's defect was precisely that its three writers disagreed.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local OTHER  = "Otherbanker-Testrealm"
local PEER   = "Otherguy-Testrealm"
local STALE  = "Stalepeer-Testrealm"
local GUILD  = "Testguild"
local C      = env.canon
local T      = 1757000000

local LIGHT = { "Modules/Constants.lua", "Modules/Item.lua", "Modules/DeltaComms.lua", "Modules/Bank.lua", "Modules/Guild.lua" }

-- ---------------------------------------------------------------------------------------------
-- The rule, in isolation.
-- ---------------------------------------------------------------------------------------------
describe("Guild:GetAltStaleness", function()
	local Guild

	before_each(function()
		env.reset(); env.stubOutput()
		env.loadModules(LIGHT)
		env.freshV2()
		Guild = TOGBankClassic_Guild
		Guild.Info = { name = GUILD, alts = {} }
		Guild.IsBank = function(_, n) return n == BANKER or n == OTHER end
		Guild.newestAdvertisedAt = {}
	end)

	-- INV2-RETIRE-003: content lives in the V2 store; the alt record carries the canon only.
	-- `items = {}` (explicitly empty) means "held, no content".
	local function hold(alt, canon, items)
		Guild.Info.alts[alt] = { name = alt, inventoryHash = 1, inventoryHashV2 = canon }
		if items == nil or #items > 0 then env.holdV2(GUILD, alt) end
	end

	it("is 'none' when we hold nothing, or hold a record with no content", function()
		assert.equal("none", (Guild:GetAltStaleness(OTHER)))
		hold(OTHER, C(T, 5), {})
		assert.equal("none", (Guild:GetAltStaleness(OTHER)))
	end)

	-- "v1 is always red"
	it("is 'v1' for a held copy with no revision-2 canon, whatever anyone advertised", function()
		hold(OTHER, nil)
		assert.equal("v1", (Guild:GetAltStaleness(OTHER)))
		Guild.newestAdvertisedAt[OTHER] = T + 100
		assert.equal("v1", (Guild:GetAltStaleness(OTHER)))
	end)

	it("is 'v1' for a v1.4.0 numeric canon that could not be re-encoded -- no readable time", function()
		hold(OTHER, 424242)
		assert.equal("v1", (Guild:GetAltStaleness(OTHER)))
	end)

	it("is 'current' for a V2 copy nobody has said anything newer about", function()
		hold(OTHER, C(T, 5))
		local state, heldAt, newestAt = Guild:GetAltStaleness(OTHER)
		assert.equal("current", state)
		assert.equal(T, heldAt, "the held time is read off the canon")
		assert.equal(0, newestAt)
	end)

	it("is 'current' when the newest mentioned is the same time, or older", function()
		hold(OTHER, C(T, 5))
		Guild.newestAdvertisedAt[OTHER] = T
		assert.equal("current", (Guild:GetAltStaleness(OTHER)))
		Guild.newestAdvertisedAt[OTHER] = T - 1
		assert.equal("current", (Guild:GetAltStaleness(OTHER)))
	end)

	-- "v2 does it by is someone newer"
	it("is 'behind' when someone mentioned a strictly newer publish time", function()
		hold(OTHER, C(T, 5))
		Guild.newestAdvertisedAt[OTHER] = T + 1
		local state, heldAt, newestAt = Guild:GetAltStaleness(OTHER)
		assert.equal("behind", state)
		assert.equal(T, heldAt)
		assert.equal(T + 1, newestAt)
	end)

	it("reads the held time off the CANON, not off a sidecar field that may disagree", function()
		Guild.Info.alts[OTHER] = { name = OTHER, inventoryHashV2 = C(T, 5), inventoryUpdatedAt = T + 999 }
		env.holdV2(GUILD, OTHER)
		Guild.newestAdvertisedAt[OTHER] = T + 1
		assert.equal("behind", (Guild:GetAltStaleness(OTHER)), "the sidecar time masked the canon's")
	end)

	-- MULTIPC-001. This used to pin "never 'behind' on OUR OWN character -- we are the author". The
	-- operator's guild runs its bankers on a SHARED ACCOUNT played from several PCs, each with its own
	-- SavedVariables: "the banker CAN be red in its tab and out of date ... their data COULD be out of
	-- date until they open their bags/mail/bank." A peer naming a later version of our own bank is
	-- right, and the tab says so.
	it("is 'behind' on OUR OWN character when another PC published a later version", function()
		hold(BANKER, C(T, 5))
		Guild.newestAdvertisedAt[BANKER] = T + 60
		local state, heldAt, newestAt = Guild:GetAltStaleness(BANKER)
		assert.equal("behind", state)
		assert.equal(T, heldAt)
		assert.equal(T + 60, newestAt)
		assert.equal(T + 60, Guild:NewerSelfVersionAt(), "the publish gate reads the same answer")
	end)

	it("is 'current' on our own character when what was named is the same time, or older", function()
		hold(BANKER, C(T, 5))
		Guild.newestAdvertisedAt[BANKER] = T
		assert.equal("current", (Guild:GetAltStaleness(BANKER)))
		assert.is_nil(Guild:NewerSelfVersionAt())
		Guild.newestAdvertisedAt[BANKER] = T - 1
		assert.equal("current", (Guild:GetAltStaleness(BANKER)))
	end)

	it("is 'behind' on our own character even with no canon or no content, once a later version is named", function()
		-- "behind" wins over "v1" and "none" for our own name: its tooltip is the one that says what
		-- fixes it (re-read the bank and the mailbox here).
		hold(BANKER, nil)
		Guild.newestAdvertisedAt[BANKER] = T + 60
		local state, heldAt = Guild:GetAltStaleness(BANKER)
		assert.equal("behind", state)
		assert.equal(0, heldAt)
		Guild.Info.alts[BANKER] = nil
		assert.equal("behind", (Guild:GetAltStaleness(BANKER)))
	end)

	it("can still be 'v1' or 'none' on our own character -- only opening the bank fixes that", function()
		hold(BANKER, nil)
		assert.equal("v1", (Guild:GetAltStaleness(BANKER)))
		Guild.Info.alts[BANKER] = nil
		assert.equal("none", (Guild:GetAltStaleness(BANKER)))
	end)
end)

describe("Guild:NoteAdvertisedPublishTime", function()
	local Guild

	before_each(function()
		env.reset(); env.stubOutput()
		env.loadModules(LIGHT)
		Guild = TOGBankClassic_Guild
		Guild.Info = { name = GUILD, alts = {} }
		Guild.IsBank = function(_, n) return n == BANKER or n == OTHER end
		Guild.newestAdvertisedAt = {}
	end)

	it("raises the newest time from a canon, and reports that it did", function()
		assert.is_true(Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T, 1) }))
		assert.equal(T, Guild.newestAdvertisedAt[OTHER])
		assert.is_true(Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T + 5, 1) }))
		assert.equal(T + 5, Guild.newestAdvertisedAt[OTHER])
	end)

	it("never LOWERS it -- a stale relayer cannot regress what we know", function()
		Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T + 5, 1) })
		assert.is_false(Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T, 1) }))
		assert.is_false(Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T + 5, 9) }), "equal time is not a raise")
		assert.equal(T + 5, Guild.newestAdvertisedAt[OTHER])
	end)

	it("reads the time off the canon, and ignores a claim with no readable canon", function()
		assert.is_false(Guild:NoteAdvertisedPublishTime(OTHER, { hash = 0xDEAD, updatedAt = T + 99999 }),
			"a revision-1-only claim raised the newest time -- it says nothing about recency")
		assert.is_false(Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = 424242 }),
			"a numeric canon with no time raised it")
		assert.is_nil(Guild.newestAdvertisedAt[OTHER])
	end)

	it("re-encodes a v1.4.0 numeric canon beside its publish time and reads that", function()
		assert.is_true(Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = 424242, updatedAt = T + 7 }))
		assert.equal(T + 7, Guild.newestAdvertisedAt[OTHER])
	end)

	it("prefers the canon's time over a sidecar updatedAt that disagrees", function()
		assert.is_true(Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T, 1), updatedAt = T + 99999 }))
		assert.equal(T, Guild.newestAdvertisedAt[OTHER], "the sidecar field was believed over the canon")
	end)

	it("ignores claims about non-bankers, and junk", function()
		assert.is_false(Guild:NoteAdvertisedPublishTime("Nobody-Testrealm", { hashV2 = C(T, 1) }))
		assert.is_false(Guild:NoteAdvertisedPublishTime(nil, { hashV2 = C(T, 1) }))
		assert.is_false(Guild:NoteAdvertisedPublishTime(OTHER, nil))
		assert.is_false(Guild:NoteAdvertisedPublishTime(OTHER, "junk"))
		assert.same({}, Guild.newestAdvertisedAt)
	end)

	-- MULTIPC-001: this used to be in the list above. A claim about OUR OWN character is recorded like
	-- any other -- on a shared account another PC can have published a version this PC never saw.
	-- The hash CACHE keeps refusing it (nothing is ever fetched for our own name), which is the half
	-- the "self-guard there must stay" example in the offer section pins.
	it("records a claim about our own character (a shared account on another PC can be ahead)", function()
		assert.is_true(Guild:NoteAdvertisedPublishTime(BANKER, { hashV2 = C(T, 1) }))
		assert.equal(T, Guild.newestAdvertisedAt[BANKER])
	end)

	it("asks the Inventory window to repaint only when it raised the time", function()
		local repaints = 0
		TOGBankClassic_UI_Inventory = { RefreshSoon = function() repaints = repaints + 1 end }
		Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T, 1) })
		Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T, 1) })       -- no raise
		Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T - 1, 1) })   -- no raise
		Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T + 1, 1) })
		TOGBankClassic_UI_Inventory = nil
		assert.equal(2, repaints)
	end)
end)

-- ---------------------------------------------------------------------------------------------
-- Every writer, through the REAL paths on a whole client; and delivery clearing it.
-- ---------------------------------------------------------------------------------------------
describe("the tab colour through the real receive paths", function()
	local function client(who)
		env.standUpClient(who, {
			{ name = BANKER, note = "gbank" }, { name = OTHER, note = "gbank" },
			{ name = PEER }, { name = STALE },
		}, GUILD)
		assert.is_true(TOGBankClassic_Guild:IsBank(BANKER) and TOGBankClassic_Guild:IsBank(OTHER),
			"precondition: the roster did not come up; every path below would refuse silently")
	end

	local function hashListReplyFrom(sender, alts)
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-list-reply", alts = alts })
		TOGBankClassic_Chat:OnCommReceived("togbank-hlr", body, "WHISPER", sender)
	end

	-- N6: the KEYED offer / broadcast are what old-build peers send; off by default since v1.5.0 and
	-- accepted only under this switch. The paths they feed are shared with the numbered forms.
	local function hashOfferFrom(sender, alts)
		TOGBankClassic_Switches:Set("legacyKeyedReceive", true)
		TOGBankClassic_P2PSession:BeginCollectWindow({})
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-offer", alts = alts })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "WHISPER", sender)
	end

	local function hashListBroadcastFrom(sender, alts)
		TOGBankClassic_Switches:Set("legacyKeyedReceive", true)
		TOGBankClassic_Chat.hashBroadcastQueue = TOGBankClassic_Chat.hashBroadcastQueue or {}
		TOGBankClassic_Chat.HASH_BROADCAST_BATCH_DELAY = 0.15
		local body = TOGBankClassic_Core:SerializeWithChecksum({
			type = "hash-list-broadcast", alts = alts, banker = sender, isBanker = false,
		})
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "GUILD", sender)
		env.advance(1)   -- PERF-020: batched
	end

	-- INV2-RETIRE-003: the content is in the V2 store (standUpClient attaches one); the record
	-- carries the version metadata.
	local function holdCurrent(alt, at)
		TOGBankClassic_Guild.Info.alts[alt] = {
			name = alt, money = 0,
			inventoryHash = 0x10, inventoryHashV2 = C(at, 0x20), inventoryUpdatedAt = at, mailHash = 0,
		}
		env.holdV2(GUILD, alt)
	end

	before_each(function() env.reset() end)

	it("turns red on a hash-list reply that mentions a newer canon", function()
		client("Otherguy")
		holdCurrent(OTHER, T)
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(OTHER)))
		hashListReplyFrom(BANKER, { [OTHER] = { hash = 0x10, hashV2 = C(T + 60, 0x21), updatedAt = T + 60, mailHash = 0 } })
		assert.equal("behind", (TOGBankClassic_Guild:GetAltStaleness(OTHER)))
	end)

	it("turns red on a hash-offer that mentions a newer canon", function()
		client("Bankchar")
		holdCurrent(OTHER, T)
		hashOfferFrom(PEER, { [OTHER] = { hash = 0x10, hashV2 = C(T + 60, 0x21), updatedAt = T + 60, mailHash = 0 } })
		assert.equal("behind", (TOGBankClassic_Guild:GetAltStaleness(OTHER)))
	end)

	-- N6: the KEYED forms are off by default from v1.5.0 -- the operator's "comment it out first".
	-- The same messages that turn the tab red above do NOTHING with the switch at its default, and
	-- the numbered forms are untouched by it.
	it("IGNORES a keyed hash-offer and hash-list broadcast while legacyKeyedReceive is off (N6)", function()
		client("Bankchar")
		holdCurrent(OTHER, T)
		TOGBankClassic_Chat.hashBroadcastQueue = TOGBankClassic_Chat.hashBroadcastQueue or {}
		TOGBankClassic_Chat.HASH_BROADCAST_BATCH_DELAY = 0.15
		assert.is_false(TOGBankClassic_Switches:IsEnabled("legacyKeyedReceive"), "precondition: the switch ships off")
		local newer = { [OTHER] = { hash = 0x10, hashV2 = C(T + 60, 0x21), updatedAt = T + 60, mailHash = 0 } }
		TOGBankClassic_P2PSession:BeginCollectWindow({})
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-offer", alts = newer }), "WHISPER", PEER)
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-list-broadcast", alts = newer, banker = PEER, isBanker = false }), "GUILD", PEER)
		env.advance(1)
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(OTHER)), "a keyed message moved the tab with the switch off")
		assert.equal(0, #TOGBankClassic_Chat.hashBroadcastQueue, "a keyed broadcast was queued with the switch off")
		-- The numbered form still lands.
		local BN = TOGBankClassic_BankerNumbers
		BN:Adopt({ v = 5, n = 3, t = { [BANKER] = 1, [OTHER] = 2 } }, PEER)
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", TOGBankClassic_Core:SerializeWithChecksum({ type = "hlb2", v = 5, banker = PEER, isBanker = false,
			e = BN:EncodeEntries({ { number = "0002", canon = C(T + 60, 0x21) } }) }), "GUILD", PEER)
		env.advance(1)
		assert.equal("behind", (TOGBankClassic_Guild:GetAltStaleness(OTHER)), "the numbered broadcast was gated too")
	end)

	it("turns red on a hash-list BROADCAST that mentions a newer canon -- the earliest signal there is", function()
		client("Bankchar")
		holdCurrent(OTHER, T)
		hashListBroadcastFrom(PEER, { [OTHER] = { hash = 0x10, hashV2 = C(T + 60, 0x21), updatedAt = T + 60, mailHash = 0 } })
		assert.equal("behind", (TOGBankClassic_Guild:GetAltStaleness(OTHER)))
	end)

	it("stays yellow on a reply carrying the same canon, an older one, or a revision-1-only number with a newer time", function()
		client("Otherguy")
		holdCurrent(OTHER, T)
		hashListReplyFrom(BANKER, { [OTHER] = { hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0 } })
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(OTHER)))
		hashListReplyFrom(STALE,  { [OTHER] = { hash = 0x10, hashV2 = C(T - 60, 0x19), updatedAt = T - 60, mailHash = 0 } })
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(OTHER)))
		hashListReplyFrom(STALE,  { [OTHER] = { hash = 0xDEAD, updatedAt = T + 86400, mailHash = 0 } })
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(OTHER)),
			"a revision-1-only number with a self-stamped clock turned the tab red")
	end)

	-- MULTIPC-001: this used to pin "stays yellow on our OWN character whatever a peer claims".
	it("turns red on our OWN character when a peer names a later version -- another PC on the account published it", function()
		client("Bankchar")
		holdCurrent(BANKER, T)
		hashListReplyFrom(PEER, { [BANKER] = { hash = 0xDEAD, hashV2 = C(T + 60, 0xBEEF), updatedAt = T + 60, mailHash = 0 } })
		assert.equal("behind", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))
		assert.is_nil((TOGBankClassic_Guild.latestBankerHashes or {})[BANKER],
			"the claim reached the FETCH cache -- our own bank is re-read, never fetched")
		-- And not on a claim that is no newer than what this PC holds.
		env.reset(); client("Bankchar")
		holdCurrent(BANKER, T)
		hashListReplyFrom(PEER, { [BANKER] = { hash = 0xDEAD, hashV2 = C(T, 0xBEEF), updatedAt = T, mailHash = 0 } })
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(BANKER)))
	end)

	it("goes yellow the instant the newer copy is delivered, because delivery stores the author's canon", function()
		-- Client A publishes a newer version; client B, holding the older one and having heard of
		-- the newer, receives it.
		client("Bankchar")
		local Record = TOGBankClassic_Inventory_Record
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, BANKER, { Record.new(858, 5) }, 0)
		TOGBankClassic_Guild.Info.alts[BANKER] = { name = BANKER, items = {}, money = 0 }
		TOGBankClassic_Core:StampInventoryHashes(TOGBankClassic_Guild.Info.alts[BANKER],
			TOGBankClassic_Inventory_Store:GetAltView(GUILD, BANKER), nil, nil, 0, T + 60)
		local newCanon = TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2
		assert.equal(T + 60, TOGBankClassic_DeltaComms:CanonPublishTime(newCanon), "precondition: the stamp did not lead with the time")
		local sent = {}
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, text) sent[#sent + 1] = { prefix = prefix, text = text } end
		TOGBankClassic_Guild:SendAltData(BANKER, 0, 0, PEER)
		local d4
		for _, m in ipairs(sent) do if m.prefix == "togbank-d4" then d4 = m end end
		assert.is_table(d4, "no payload was sent")

		env.reset()
		client("Otherguy")
		holdCurrent(BANKER, T)
		hashListReplyFrom(BANKER, { [BANKER] = { hash = 0x10, hashV2 = newCanon, updatedAt = T + 60, mailHash = 0 } })
		assert.equal("behind", (TOGBankClassic_Guild:GetAltStaleness(BANKER)), "precondition: not behind before delivery")

		TOGBankClassic_Chat:OnCommReceived("togbank-d4", d4.text, "WHISPER", BANKER)
		local state, heldAt = TOGBankClassic_Guild:GetAltStaleness(BANKER)
		assert.equal("current", state, "the newer copy landed and the tab is still red")
		assert.equal(T + 60, heldAt)
		assert.equal(newCanon, TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2, "delivery did not store the author's canon verbatim")
	end)

	-- TABCOLOUR-003: the number-only offer (P2P-035) is the reply to our own broadcast, and until now
	-- it moved no tab -- it names no version. The operator: "if someone replies that they have a newer
	-- data set than us, we need to make that bankers tab go red until we can get it."
	it("turns red on a NUMBER-ONLY offer through the real path, and yellow again when the delivery lands", function()
		client("Bankchar")
		local Record = TOGBankClassic_Inventory_Record
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, BANKER, { Record.new(858, 5) }, 0)
		TOGBankClassic_Guild.Info.alts[BANKER] = { name = BANKER, items = {}, money = 0 }
		TOGBankClassic_Core:StampInventoryHashes(TOGBankClassic_Guild.Info.alts[BANKER],
			TOGBankClassic_Inventory_Store:GetAltView(GUILD, BANKER), nil, nil, 0, T + 60)
		local sent = {}
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, text) sent[#sent + 1] = { prefix = prefix, text = text } end
		TOGBankClassic_Guild:SendAltData(BANKER, 0, 0, PEER)
		local d4
		for _, m in ipairs(sent) do if m.prefix == "togbank-d4" then d4 = m end end
		assert.is_table(d4, "no payload was sent")

		env.reset()
		client("Otherguy")
		local BN = TOGBankClassic_BankerNumbers
		BN:Adopt({ v = 5, n = 3, t = { [BANKER] = 1, [OTHER] = 2 } }, PEER)
		holdCurrent(BANKER, T)
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(BANKER)), "precondition")
		TOGBankClassic_Core.SendWhisper = function() return true end   -- the version query goes nowhere here
		-- The offer comes from the banker itself: on this client PEER is us, and our own echo is dropped.
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-offer2", v = 5, n = BN:EncodeNumbers({ "0001" }) })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "WHISPER", BANKER)
		local state, _, _, who = TOGBankClassic_Guild:GetAltStaleness(BANKER)
		assert.equal("offered", state, "a bare offer for a bank we hold left the tab yellow")
		assert.equal(BANKER, who)

		TOGBankClassic_Chat:OnCommReceived("togbank-d4", d4.text, "WHISPER", BANKER)
		assert.equal("current", (TOGBankClassic_Guild:GetAltStaleness(BANKER)), "the delivery landed and the tab is still red")
	end)

	it("does not go yellow on delivery of a copy OLDER than the newest mentioned", function()
		client("Bankchar")
		local Record = TOGBankClassic_Inventory_Record
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, BANKER, { Record.new(858, 5) }, 0)
		TOGBankClassic_Guild.Info.alts[BANKER] = { name = BANKER, items = {}, money = 0 }
		TOGBankClassic_Core:StampInventoryHashes(TOGBankClassic_Guild.Info.alts[BANKER],
			TOGBankClassic_Inventory_Store:GetAltView(GUILD, BANKER), nil, nil, 0, T + 30)
		local sent = {}
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, text) sent[#sent + 1] = { prefix = prefix, text = text } end
		TOGBankClassic_Guild:SendAltData(BANKER, 0, 0, PEER)
		local d4
		for _, m in ipairs(sent) do if m.prefix == "togbank-d4" then d4 = m end end

		env.reset()
		client("Otherguy")
		hashListReplyFrom(BANKER, { [BANKER] = { hash = 0x10, hashV2 = C(T + 60, 0x21), updatedAt = T + 60, mailHash = 0 } })
		TOGBankClassic_Chat:OnCommReceived("togbank-d4", d4.text, "WHISPER", BANKER)
		assert.equal("behind", (TOGBankClassic_Guild:GetAltStaleness(BANKER)),
			"a delivery older than the newest known version cleared the red")
	end)

	-- HASH-CANON-006: THE ALCHEMYRCP CASE, exactly as read off the live saved variables. The
	-- viewer holds a pre-canon copy whose revision-1 hash EQUALS the banker's current one (the bank
	-- has not changed since); the banker advertises a canon. Revision 1 agreeing must not stop the
	-- request, or the viewer never acquires a canon and the tab stays red forever.
	it("REQUESTS the data when the banker advertises a canon and we hold a pre-canon copy with the same revision-1 hash", function()
		client("Otherguy")
		TOGBankClassic_Guild.Info.alts[OTHER] = {
			name = OTHER, money = 127821,
			inventoryHash = 808855588, inventoryUpdatedAt = 1788651417, mailHash = 0,   -- no canon
		}
		env.holdV2(GUILD, OTHER, { { 13491, 27 } }, 127821)
		local sent = {}
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, text, dist, target)
			sent[#sent + 1] = { prefix = prefix, text = text, dist = dist, target = target }
		end
		TOGBankClassic_Core.SendWhisper = function(_, prefix, text, target)
			sent[#sent + 1] = { prefix = prefix, text = text, target = target }
			return true   -- the real one returns true for an online target, and callers branch on it
		end
		assert.equal("v1", (TOGBankClassic_Guild:GetAltStaleness(OTHER)), "precondition: the pre-canon copy reads as v1")
		hashListReplyFrom(BANKER, { [OTHER] = {
			hash = 808855588, hashV2 = C(1789007890, 486957224), updatedAt = 1789007890, mailHash = 0,
		} })
		local asked = false
		for _, m in ipairs(sent) do
			local ok, data = TOGBankClassic_Core:DeserializeWithChecksum(m.text)
			if ok and type(data) == "table" and data.type == "alt-request" and data.name == OTHER then asked = true end
		end
		assert.is_true(asked,
			"revision 1 matched and the client did not ask for the banker's canon -- it can never " ..
			"acquire one this way, and the tab reads 'v1' forever")
	end)

	it("is wiped and re-seeded per guild on Init", function()
		client("Otherguy")
		TOGBankClassic_Guild.newestAdvertisedAt = { [OTHER] = T + 999 }
		-- CLAIM-TRACE-001: the CLAIMANT is wiped with the time it belongs to. Asserted here rather
		-- than in a file of its own because the defect was exactly that it was NOT in this block:
		-- created lazily inside NoteAdvertisedPublishTime, so switching guilds left the trace naming
		-- a peer from the previous one -- a diagnostic built to identify a culprit, naming the wrong
		-- player with confidence, which is worse than printing nothing.
		TOGBankClassic_Guild.newestAdvertisedBy = { [OTHER] = { peer = "Stale-Testrealm", canon = "x", at = T + 999 } }
		TOGBankClassic_Database.Load = function()
			return { name = GUILD, alts = {}, requests = {}, requestsTombstones = {}, settings = {}, roster = { alts = {} } }
		end
		TOGBankClassic_Guild.Info = nil
		assert.is_true(TOGBankClassic_Guild:Init(GUILD))
		env.advance(1.5)
		assert.same({}, TOGBankClassic_Guild.newestAdvertisedAt)
		assert.same({}, TOGBankClassic_Guild.newestAdvertisedBy,
			"the claimant table outlived the guild it belongs to")
	end)
end)

-- ---------------------------------------------------------------------------------------------
-- The sending side of the same rule: answering a broadcast is ONE string compare.
-- ---------------------------------------------------------------------------------------------
describe("answering a hash-list broadcast with an offer", function()
	local function client(who)
		env.standUpClient(who, {
			{ name = BANKER, note = "gbank" }, { name = OTHER, note = "gbank" }, { name = PEER },
		}, GUILD)
	end

	local sent
	local function broadcastFrom(sender, alts)
		TOGBankClassic_Chat.hashBroadcastQueue = TOGBankClassic_Chat.hashBroadcastQueue or {}
		TOGBankClassic_Chat.HASH_BROADCAST_BATCH_DELAY = 0.15
		sent = {}
		TOGBankClassic_Core.SendWhisper = function(_, prefix, text, target)
			local ok, data = TOGBankClassic_Core:DeserializeWithChecksum(text)
			sent[#sent + 1] = { prefix = prefix, data = ok and data or nil, target = target }
			return true   -- the real one returns true for an online target, and callers branch on it
		end
		-- N6: the keyed broadcast is accepted only under the switch; the OFFER these examples assert
		-- on is the numbered hash-offer2, which is what the shared path emits regardless.
		TOGBankClassic_Switches:Set("legacyKeyedReceive", true)
		local body = TOGBankClassic_Core:SerializeWithChecksum({
			type = "hash-list-broadcast", alts = alts, banker = sender, isBanker = false,
		})
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "GUILD", sender)
		env.advance(1)
	end

	--- P2P-035: the offer is bare banker numbers ("we want to keep the offer hashless and TINY").
	--- Decoded back to `{ [name] = true }` so the examples below read as they did: WHO was offered.
	local function offered()
		for _, m in ipairs(sent) do
			if m.prefix == "togbank-hl" and m.data and m.data.type == "hash-offer2" then
				local BN = TOGBankClassic_BankerNumbers
				local names = {}
				for _, num in ipairs(BN:DecodeNumbers(m.data.n)) do names[BN:NameOf(num)] = true end
				assert.is_nil(m.data.alts, "the offer still carries a keyed table")
				assert.is_nil(m.data.e, "the offer carries canons; it must carry numbers only")
				return names
			end
		end
		return nil
	end

	--- The numbers every client in these examples agrees on. Set directly: minting is BankerNumbers'
	--- own spec's business, and this describe is about the offer decision.
	local function numbered()
		TOGBankClassic_Guild.Info.roster = {
			alts = {}, numbers = { [BANKER] = 1, [OTHER] = 2 }, numbersNext = 3, numbersVersion = 1,
		}
	end

	--- Hold a copy WITH tuple records, which is what an offer promises to deliver (HASH-CANON-009).
	--- `legacyOnly` holds the same canon beside legacy items and nothing in the V2 store.
	local function hold(alt, canon, at, legacyOnly)
		TOGBankClassic_Guild.Info.alts[alt] = {
			name = alt, items = { { ID = 1, Count = 1 } }, money = 0,
			inventoryHash = 0x10, inventoryHashV2 = canon, inventoryUpdatedAt = at, mailHash = 0,
		}
		if not legacyOnly then
			TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, alt, { TOGBankClassic_Inventory_Record.new(1, 1) }, 0)
		end
	end

	before_each(function() env.reset(); client("Bankchar"); numbered() end)

	-- HASH-CANON-009, from the operator's own account: 36 records carried a canon, 10 had tuple
	-- data. An offer is a promise SendAltData keeps only from the V2 store, so the other 26 were
	-- promises nobody could keep -- requested every cycle, nothing sent, tab stuck on red.
	it("does not offer a canon it cannot deliver -- a canon beside legacy-only content", function()
		hold(OTHER, C(T + 60, 0x21), T + 60, true)
		broadcastFrom(PEER, { [OTHER] = { hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0 } })
		assert.is_nil(offered(),
			"offered a version the V2 store holds no records for; the request it provokes is " ..
			"answered with nothing (HASH-CANON-009)")
	end)

	it("offers when my canon is newer than the one advertised", function()
		hold(OTHER, C(T + 60, 0x21), T + 60)
		broadcastFrom(PEER, { [OTHER] = { hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0 } })
		local names = offered()
		assert.is_table(names, "no offer was whispered back")
		assert.is_true(names[OTHER] == true)
	end)

	-- P2P-035: the offer names bankers by NUMBER; a banker nobody has numbered yet cannot be named
	-- and is left out (it is offered again once its account has numbered it).
	it("does not offer a banker that has no number yet", function()
		TOGBankClassic_Guild.Info.roster.numbers[OTHER] = nil
		hold(OTHER, C(T + 60, 0x21), T + 60)
		broadcastFrom(PEER, { [OTHER] = { hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0 } })
		assert.is_nil(offered(), "an unnumbered banker was put on the numbered wire")
	end)

	it("is one chunk for a whole roster of newer banks, and carries the table version", function()
		TOGBankClassic_Guild.IsBank = function() return true end
		for i = 1, 30 do
			local name = string.format("Bank%02d-Testrealm", i)
			TOGBankClassic_Guild.Info.roster.numbers[name] = i + 2
			hold(name, C(T + 60, i), T + 60)
		end
		TOGBankClassic_Guild.Info.roster.numbersVersion = 77
		broadcastFrom(PEER, {})
		local msg
		for _, m in ipairs(sent) do if m.data and m.data.type == "hash-offer2" then msg = m end end
		assert.is_table(msg)
		assert.equal(77, msg.data.v, "the offer did not carry the banker-number table version")
		assert.equal(30 * 4, #msg.data.n)
		local body = TOGBankClassic_Core:SerializeWithChecksum(msg.data)
		assert.is_true(#body < 255, "a thirty-bank offer is " .. #body .. " bytes; it must fit one chunk")
	end)

	it("offers when the peer advertised NO canon for the alt at all", function()
		hold(OTHER, C(T, 0x20), T)
		broadcastFrom(PEER, { [OTHER] = { hash = 0xDEAD, updatedAt = T + 86400, mailHash = 0 } })
		assert.is_table(offered(), "a readable version was not offered to a peer with none")
	end)

	it("does not offer when my canon is the same, or older", function()
		hold(OTHER, C(T, 0x20), T)
		broadcastFrom(PEER, { [OTHER] = { hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0 } })
		assert.is_nil(offered(), "offered the same version back")
		broadcastFrom(PEER, { [OTHER] = { hash = 0x10, hashV2 = C(T + 1, 0x20), updatedAt = T + 1, mailHash = 0 } })
		assert.is_nil(offered(), "offered an older version")
	end)

	-- "v1 is always red", sending side: a copy with no readable canon is not a version anyone
	-- can place, so it is never claimed to be newer.
	it("does not offer a copy that has no readable canon, however new its sidecar time says it is", function()
		hold(OTHER, nil, T + 86400)
		broadcastFrom(PEER, { [OTHER] = { hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0 } })
		assert.is_nil(offered(), "a revision-1-only copy was offered as newer")
	end)

	-- HASH-CANON-012, from the live guild: Alchemyrcp's V2 data existed on exactly one client --
	-- Alchemyrcp's own -- and that client skipped its own character when building offers, so a
	-- viewer's broadcast about it was answered with silence and `known=-` never filled. The cache
	-- rightly refuses a PEER'S claim about our own bank; that is not a reason to refuse to OFFER it.
	it("offers OUR OWN bank when the broadcaster holds no canon for it", function()
		hold(BANKER, C(T, 0x20), T)
		broadcastFrom(PEER, { [BANKER] = { hash = 0x10, updatedAt = T - 86400, mailHash = 0 } })
		local names = offered()
		assert.is_table(names, "the author of a bank answered a broadcast about it with silence (HASH-CANON-012)")
		assert.is_true(names[BANKER] == true)
		assert.is_nil((TOGBankClassic_Guild.latestBankerHashes or {})[BANKER],
			"the peer's claim about our own bank reached the cache -- the self-guard there must stay")
	end)

	it("offers OUR OWN bank when the broadcaster did not mention it at all (a wiped viewer)", function()
		hold(BANKER, C(T, 0x20), T)
		broadcastFrom(PEER, {})
		local names = offered()
		assert.is_table(names, "an empty broadcast was not answered with our own bank")
		assert.is_true(names[BANKER] == true)
	end)

	it("does not offer our own bank back to a broadcaster who already holds this version", function()
		hold(BANKER, C(T, 0x20), T)
		broadcastFrom(PEER, { [BANKER] = { hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0 } })
		assert.is_nil(offered())
	end)

	it("offers a re-encoded v1.4.0 numeric canon when that publish is newer", function()
		hold(OTHER, 0x21, T + 60)   -- not yet re-encoded on this client
		broadcastFrom(PEER, { [OTHER] = { hash = 0x10, hashV2 = C(T, 0x20), updatedAt = T, mailHash = 0 } })
		local names = offered()
		assert.is_table(names, "a v1.4.0 numeric canon was not re-encoded before the compare")
		assert.is_true(names[OTHER] == true)
	end)
end)
