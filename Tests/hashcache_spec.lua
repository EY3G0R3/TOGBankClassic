-- HASH-CACHE-001: the advertised-hash cache, and the rule every writer of it obeys.
--
-- `Guild.latestBankerHashes` is what every "is this alt behind?" question is answered from: the
-- Inventory tab colour, the hash-list compare that decides what to re-request, and /togbank
-- hashdebug. It used to have THREE writers with THREE rules -- unconditional overwrite, newest-by-
-- time-but-drops-hashV2, and the login seed -- so it held whatever arrived last. The operator's
-- rule, verbatim: "I NEED CANON hashes written ONCE by the banker, then passed around. NEVER
-- mutated. The hash HAS to have the DTS in it and the NEWER V2 Hash wins." And the report the
-- whole thing was written from: "the banker logged off and then I was getting the mutated V1 hash
-- that was 'newer' and it was over-writing my V2 data."
--
-- Three defects, all reported from a live guild on 2026-09-10 and all reproduced below through
-- the real receive path before any code changed:
--   * a peer's stale revision-1-only claim displaced the author's V2 canon (tab red after the
--     data had arrived);
--   * the banker's OWN tab was red, because a peer's entry for the banker's own character was
--     accepted into the cache and the tab colouring never excluded self;
--   * the hash-list reply handler THREW on any alt this client had no record for (`localAlt.mailHash`
--     on a nil localAlt), which aborted the handler before its request pass -- a fresh or wiped
--     client with a banker online errored at login and never asked for anything.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local OTHER  = "Otherbanker-Testrealm"
local PEER   = "Otherguy-Testrealm"
local STALE  = "Stalepeer-Testrealm"
local GUILD  = "Testguild"

-- ---------------------------------------------------------------------------------------------
-- The rule, in isolation.
-- ---------------------------------------------------------------------------------------------
-- Bank.lua is loaded because GetNormalizedPlayer resolves self through TOGBankClassic_Bank.player;
-- DeltaComms because HashesAgreeWith normalises canons through DeltaComms:CanonFrom.
local LIGHT = { "Modules/Constants.lua", "Modules/Item.lua", "Modules/DeltaComms.lua", "Modules/Bank.lua", "Modules/Guild.lua" }

--- A canon in the HASH-CANON-005 format. Fixtures below advertise real canons, because a numeric
--- hashV2 is a v1.4.0 value that the receive paths re-encode beside its updatedAt -- and an
--- expectation written against the number is an expectation of the old format.
local C = env.canon

describe("Guild:NoteAdvertisedHashes -- the one writer", function()
	local Guild

	before_each(function()
		env.reset(); env.stubOutput()
		env.loadModules(LIGHT)
		Guild = TOGBankClassic_Guild
		Guild.Info = { name = GUILD, alts = {} }
		Guild.IsBank = function(_, n) return n == BANKER or n == OTHER end
		-- env.playerName is "Bankchar", so GetNormalizedPlayer() is BANKER: this client IS a banker.
	end)

	local V1 = function(at, hash) return { hash = hash or 0x1111, updatedAt = at, mailHash = 0 } end
	local V2 = function(at, n) return { hash = 0x2222, hashV2 = C(at, n or 0xAAAA), updatedAt = at, mailHash = 0 } end

	describe("what it refuses outright", function()
		it("refuses a missing name or a non-table summary", function()
			assert.is_false(Guild:NoteAdvertisedHashes(nil, V2(10)))
			assert.is_false(Guild:NoteAdvertisedHashes(OTHER, nil))
			assert.is_false(Guild:NoteAdvertisedHashes(OTHER, "junk"))
			assert.is_nil(Guild.latestBankerHashes and Guild.latestBankerHashes[OTHER])
		end)

		it("refuses an alt that is not a current banker (stale ex-banker entries in a peer's SV)", function()
			assert.is_false(Guild:NoteAdvertisedHashes("Exbanker-Testrealm", V2(10)))
			assert.is_nil(Guild.latestBankerHashes and Guild.latestBankerHashes["Exbanker-Testrealm"])
		end)

		-- Rule 1. The report: "for the banker that is on, it should probably NEVER be red".
		it("refuses ANY entry for our own character -- we are the author, nothing a peer says is newer", function()
			assert.is_false(Guild:NoteAdvertisedHashes(BANKER, V2(10)))
			assert.is_false(Guild:NoteAdvertisedHashes(BANKER, V2(999999)))
			assert.is_false(Guild:NoteAdvertisedHashes(BANKER, V1(999999)))
			assert.is_nil(Guild.latestBankerHashes and Guild.latestBankerHashes[BANKER])
		end)
	end)

	describe("an empty cache", function()
		it("accepts a V2 claim", function()
			assert.is_true(Guild:NoteAdvertisedHashes(OTHER, V2(10)))
			assert.equal(C(10, 0xAAAA), Guild.latestBankerHashes[OTHER].hashV2)
		end)

		it("accepts a revision-1-only claim when it holds nothing better", function()
			assert.is_true(Guild:NoteAdvertisedHashes(OTHER, V1(10)))
			assert.equal(0x1111, Guild.latestBankerHashes[OTHER].hash)
		end)

		it("stores the summary WHOLE, not a field-by-field copy that can forget hashV2", function()
			local s = { hash = 1, hashV2 = 2, updatedAt = 3, mailHash = 4, version = 5, extra = "kept" }
			Guild:NoteAdvertisedHashes(OTHER, s)
			assert.same(s, Guild.latestBankerHashes[OTHER])
		end)
	end)

	-- Rule 2: V2 and V1-only are not in the same contest.
	describe("revision 2 versus revision-1-only", function()
		it("never lets a V1-only claim displace a V2 entry, however much NEWER its time", function()
			Guild:NoteAdvertisedHashes(OTHER, V2(100))
			-- The exact shape that did the damage: a recomputed number stamped with the relayer's
			-- own clock, so it looks newer than the author's publish time.
			assert.is_false(Guild:NoteAdvertisedHashes(OTHER, V1(100 + 86400, 0xDEAD)))
			assert.equal(C(100, 0xAAAA), Guild.latestBankerHashes[OTHER].hashV2,
				"a mutated revision-1 number replaced the author's V2 canon")
		end)

		it("lets a V2 claim displace a V1-only entry even when the V2 time is OLDER", function()
			Guild:NoteAdvertisedHashes(OTHER, V1(100 + 86400))
			assert.is_true(Guild:NoteAdvertisedHashes(OTHER, V2(100)))
			assert.equal(C(100, 0xAAAA), Guild.latestBankerHashes[OTHER].hashV2,
				"a V1-only entry with a self-stamped 'newer' clock kept out the real canon")
		end)

		it("lets a V2 claim displace a V1-only entry at equal time", function()
			Guild:NoteAdvertisedHashes(OTHER, V1(100))
			assert.is_true(Guild:NoteAdvertisedHashes(OTHER, V2(100)))
			assert.equal(C(100, 0xAAAA), Guild.latestBankerHashes[OTHER].hashV2)
		end)
	end)

	-- Rule 3: within a revision, strictly newer wins.
	describe("within the same revision, the NEWER publish time wins, strictly", function()
		it("takes a newer V2 claim", function()
			Guild:NoteAdvertisedHashes(OTHER, V2(100, 0xAAAA))
			assert.is_true(Guild:NoteAdvertisedHashes(OTHER, V2(101, 0xBBBB)))
			assert.equal(C(101, 0xBBBB), Guild.latestBankerHashes[OTHER].hashV2)
		end)

		it("keeps the held V2 entry against an older V2 claim", function()
			Guild:NoteAdvertisedHashes(OTHER, V2(100, 0xAAAA))
			assert.is_false(Guild:NoteAdvertisedHashes(OTHER, V2(99, 0xBBBB)))
			assert.equal(C(100, 0xAAAA), Guild.latestBankerHashes[OTHER].hashV2)
		end)

		it("keeps the held V2 entry against a DIFFERENT V2 number at the SAME time -- a mutation cannot prove itself newer", function()
			Guild:NoteAdvertisedHashes(OTHER, V2(100, 0xAAAA))
			assert.is_false(Guild:NoteAdvertisedHashes(OTHER, V2(100, 0xBBBB)))
			assert.equal(C(100, 0xAAAA), Guild.latestBankerHashes[OTHER].hashV2)
		end)

		it("applies the same strict rule between two revision-1-only claims", function()
			Guild:NoteAdvertisedHashes(OTHER, V1(100, 0x1111))
			assert.is_false(Guild:NoteAdvertisedHashes(OTHER, V1(100, 0x3333)))
			assert.is_false(Guild:NoteAdvertisedHashes(OTHER, V1(50, 0x3333)))
			assert.equal(0x1111, Guild.latestBankerHashes[OTHER].hash)
			assert.is_true(Guild:NoteAdvertisedHashes(OTHER, V1(101, 0x3333)))
			assert.equal(0x3333, Guild.latestBankerHashes[OTHER].hash)
		end)

		it("treats a missing or non-numeric updatedAt as zero rather than erroring", function()
			Guild:NoteAdvertisedHashes(OTHER, { hash = 1, hashV2 = C(5, 2), updatedAt = "garbage" })
			assert.is_true(Guild:NoteAdvertisedHashes(OTHER, V2(1, 0xCCCC)),
				"a real time must beat an unparseable one")
			assert.is_false(Guild:NoteAdvertisedHashes(OTHER, { hash = 1, hashV2 = C(5, 3) }),
				"no time at all is zero, which is not newer than 1")
			assert.equal(C(1, 0xCCCC), Guild.latestBankerHashes[OTHER].hashV2)
		end)
	end)

	it("keeps entries for different alts independent", function()
		local THIRD = "Thirdbanker-Testrealm"
		Guild.IsBank = function(_, n) return n == OTHER or n == THIRD end
		Guild:NoteAdvertisedHashes(OTHER, V2(100, 0xAAAA))
		Guild:NoteAdvertisedHashes(THIRD, V2(50, 0xBBBB))
		assert.equal(C(100, 0xAAAA), Guild.latestBankerHashes[OTHER].hashV2)
		assert.equal(C(50, 0xBBBB), Guild.latestBankerHashes[THIRD].hashV2)
	end)
end)

-- ---------------------------------------------------------------------------------------------
-- What the cache DRIVES: the pending question the tab colour is painted from.
-- ---------------------------------------------------------------------------------------------
describe("Guild:IsAltSyncPending", function()
	local Guild

	before_each(function()
		env.reset(); env.stubOutput()
		env.loadModules(LIGHT)
		Guild = TOGBankClassic_Guild
		Guild.Info = { name = GUILD, alts = {} }
		Guild.IsBank = function(_, n) return n == BANKER or n == OTHER end
	end)

	local function held(alt, hash, hashV2, mail, items)
		Guild.Info.alts[alt] = {
			name = alt, inventoryHash = hash, inventoryHashV2 = hashV2, mailHash = mail,
			items = items or {},
		}
	end
	local SIX, SEVEN = C(1, 6), C(1, 7)

	it("is never pending on OUR OWN character, whatever the cache says", function()
		Guild.latestBankerHashes = { [BANKER] = { hash = 0xDEAD, hashV2 = C(999, 0xBEEF), updatedAt = 999, mailHash = 0 } }
		held(BANKER, 1, C(1, 2), 0)
		assert.is_false(Guild:IsAltSyncPending(BANKER),
			"the banker's own tab reads as behind on their own bank")
	end)

	it("is not pending with no cache, or no entry for the alt", function()
		Guild.latestBankerHashes = nil
		assert.is_false(Guild:IsAltSyncPending(OTHER))
		Guild.latestBankerHashes = {}
		assert.is_false(Guild:IsAltSyncPending(OTHER))
	end)

	it("is pending when a peer advertises the alt and we hold nothing", function()
		Guild.latestBankerHashes = { [OTHER] = { hash = 5, hashV2 = SIX, updatedAt = 1, mailHash = 0 } }
		assert.is_true(Guild:IsAltSyncPending(OTHER))
	end)

	-- P2P-034. This example used to be "is pending on a hash mismatch": two canons at the SAME
	-- publish time with different numbers read as pending. That is equality, and equality is what
	-- produced 26 guild broadcasts from one hash-list reply on a live viewer. The rule is the
	-- operator's: "v2 does it by is someone newer" -- and a different number at the same time is a
	-- mutation, which cannot prove itself newer (HASH-CACHE-001 rule 3).
	it("is pending when the cache holds a NEWER canon than we do", function()
		Guild.latestBankerHashes = { [OTHER] = { hash = 5, hashV2 = C(2, 6), updatedAt = 2, mailHash = 0 } }
		held(OTHER, 5, SEVEN, 0, { { ID = 1, Count = 1 } })
		assert.is_true(Guild:IsAltSyncPending(OTHER))
	end)

	it("is NOT pending on a different canon at the same time, nor on an older one", function()
		Guild.latestBankerHashes = { [OTHER] = { hash = 5, hashV2 = SIX, updatedAt = 1, mailHash = 0 } }
		held(OTHER, 5, SEVEN, 0, { { ID = 1, Count = 1 } })
		assert.is_false(Guild:IsAltSyncPending(OTHER),
			"a different number at the same publish time is a mutation, not a newer version")
		held(OTHER, 5, C(3, 7), 0, { { ID = 1, Count = 1 } })
		assert.is_false(Guild:IsAltSyncPending(OTHER), "an OLDER advertised canon reads as pending")
	end)

	it("is NOT pending when the cache holds a revision-1-only claim for a bank we hold", function()
		-- The Togweapons case: the viewer held the author's canon; a relayer's hash-list reply
		-- carried a different revision-1 number and no canon. Nothing it holds can improve ours.
		Guild.latestBankerHashes = { [OTHER] = { hash = 0xDEAD, updatedAt = 99999, mailHash = 0 } }
		held(OTHER, 5, SEVEN, 0, { { ID = 1, Count = 1 } })
		assert.is_false(Guild:IsAltSyncPending(OTHER))
		held(OTHER, 5, nil, 0, { { ID = 1, Count = 1 } })
		assert.is_false(Guild:IsAltSyncPending(OTHER), "revision-1 data cannot improve a revision-1 copy -- v1 is always red")
	end)

	it("is pending when we hold a copy with NO canon and the cache holds one, however old", function()
		Guild.latestBankerHashes = { [OTHER] = { hash = 5, hashV2 = SIX, updatedAt = 1, mailHash = 0 } }
		held(OTHER, 5, nil, 0, { { ID = 1, Count = 1 } })
		assert.is_true(Guild:IsAltSyncPending(OTHER), "fetching is the only way to acquire a canon (HASH-CANON-006)")
	end)

	it("is pending when hashes match but we hold no content", function()
		Guild.latestBankerHashes = { [OTHER] = { hash = 5, hashV2 = SIX, updatedAt = 1, mailHash = 0 } }
		held(OTHER, 5, SIX, 0, {})
		assert.is_true(Guild:IsAltSyncPending(OTHER))
	end)

	it("is not pending when hashes match and we hold content", function()
		Guild.latestBankerHashes = { [OTHER] = { hash = 5, hashV2 = SIX, updatedAt = 1, mailHash = 0 } }
		held(OTHER, 5, SIX, 0, { { ID = 1, Count = 1 } })
		assert.is_false(Guild:IsAltSyncPending(OTHER))
	end)
end)

-- ---------------------------------------------------------------------------------------------
-- P2P-034: THE ONE REQUEST RULE. "Can what this peer advertises improve the copy I hold?" It had
-- two spellings -- offers used the publish-time rule, the hash-list reply / catch-up / broadcast
-- guard used equality -- and the second produced 26 guild broadcasts from one reply on a live
-- viewer, for banks it held current, every one timing out because nobody had anything newer.
-- ---------------------------------------------------------------------------------------------
describe("Guild:AdvertisedImproves -- the one request rule", function()
	local Guild
	local T = 1757000000

	before_each(function()
		env.reset(); env.stubOutput()
		env.loadModules(LIGHT)
		Guild = TOGBankClassic_Guild
		Guild.Info = { name = GUILD, alts = {} }
		Guild.IsBank = function(_, n) return n == BANKER or n == OTHER end
	end)

	local function hold(canon, items)
		Guild.Info.alts[OTHER] = {
			name = OTHER, inventoryHash = 5, inventoryHashV2 = canon, inventoryUpdatedAt = T,
			items = items or { { ID = 1, Count = 1 } },
		}
	end

	it("wants anything for a bank we hold nothing for -- but not a claim that carries nothing", function()
		assert.is_true(Guild:AdvertisedImproves(OTHER, { hash = 1 }))
		assert.is_true(Guild:AdvertisedImproves(OTHER, { hash = 0, hashV2 = C(T, 1) }))
		hold(nil, {})   -- a stub: hashes but no content
		assert.is_true(Guild:AdvertisedImproves(OTHER, { hash = 1 }))
		local ok, why = Guild:AdvertisedImproves(OTHER, { hash = 0 })
		assert.is_false(ok, "a peer that holds nothing either was asked for it")
		assert.equal("nothing", why)
		assert.is_false(Guild:AdvertisedImproves(OTHER, {}))
	end)

	it("refuses a canon-less claim for a bank we hold, whatever its hash or time", function()
		hold(C(T, 1))
		local ok, why = Guild:AdvertisedImproves(OTHER, { hash = 0xDEAD, updatedAt = T + 99999, mailHash = 9 })
		assert.is_false(ok, "revision-1 data was allowed to 'improve' a copy holding the author's canon")
		assert.equal("no canon", why)
		hold(nil)
		assert.is_false(Guild:AdvertisedImproves(OTHER, { hash = 0xDEAD }),
			"revision-1 data cannot improve a revision-1 copy -- v1 is always red")
	end)

	it("takes any canon when ours has none, a NEWER one when we hold one, and nothing else", function()
		hold(nil)
		assert.is_true(Guild:AdvertisedImproves(OTHER, { hashV2 = C(T - 100, 1) }),
			"a copy with no canon must take ANY canon-bearing claim; that is the only way it acquires one")
		hold(C(T, 1))
		assert.is_false(Guild:AdvertisedImproves(OTHER, { hashV2 = C(T, 1) }))
		assert.is_false(Guild:AdvertisedImproves(OTHER, { hashV2 = C(T, 2) }),
			"a different number at the same publish time is a mutation, not a newer version")
		assert.is_false(Guild:AdvertisedImproves(OTHER, { hashV2 = C(T - 1, 1) }))
		local ok, why = Guild:AdvertisedImproves(OTHER, { hashV2 = C(T + 1, 1) })
		assert.is_true(ok)
		assert.equal("newer", why)
	end)

	it("compares the PUBLISH TIME, not the whole string, so a float-mangled tail cannot look newer", function()
		hold(C(T, 1431912204))
		-- Same date, garbage tail that compares greater as a string (read off a live login).
		assert.is_false(Guild:AdvertisedImproves(OTHER, { hashV2 = C(T, 1431912720) }))
	end)

	it("re-encodes a v1.4.0 numeric canon at the door, like every other receive path", function()
		hold(C(T, 0x20))
		local s = { hash = 0x10, hashV2 = 0x20, updatedAt = T + 60 }
		assert.is_true(Guild:AdvertisedImproves(OTHER, s))
		assert.equal(C(T + 60, 0x20), s.hashV2, "the summary was not canonicalised in place")
	end)

	it("never wants a peer's claim about our own character", function()
		assert.is_false(Guild:AdvertisedImproves(BANKER, { hash = 1, hashV2 = C(T + 999, 1) }))
	end)

	it("wants nothing from a non-table claim", function()
		assert.is_false(Guild:AdvertisedImproves(OTHER, nil))
		assert.is_false(Guild:AdvertisedImproves(OTHER, "junk"))
		assert.is_false(Guild:AdvertisedImproves(nil, { hash = 1 }))
	end)
end)

-- ---------------------------------------------------------------------------------------------
-- Every writer, through the REAL paths on a whole client.
-- ---------------------------------------------------------------------------------------------
describe("the writers, through the real receive paths", function()
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

	--- A peer's hash-OFFER (its answer to our broadcast), which is what feeds P2PSession:OnOffer
	--- and, through it, the cache. (A hash-list-BROADCAST does not write the cache: it only makes
	--- the receiver build offers back to the sender.)
	local function hashOfferFrom(sender, alts)
		-- Inside the collect window an offer accumulates for Dispatch; outside it (P2P-034) a
		-- useful one opens a session at once. These examples are about the CACHE, so the window is
		-- opened as the broadcast would have, and nothing here dispatches.
		TOGBankClassic_P2PSession:BeginCollectWindow({})
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-offer", alts = alts })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "WHISPER", sender)
	end

	describe("the hash-list reply (togbank-hlr)", function()
		before_each(function() env.reset() end)

		-- HLR-CRASH-001, the reproduction. The reply carries no isBanker field in the client
		-- (Guild:SendHashList builds { type, alts, banker }), so the stub branch was dead and the
		-- elseif indexed a nil localAlt.
		it("does not error on an alt this client has never seen, and seeds a stub from a BANKER's reply", function()
			client("Otherguy")
			assert.is_nil(TOGBankClassic_Guild.Info.alts[OTHER], "precondition: alt already known")
			assert.has_no_error(function()
				hashListReplyFrom(BANKER, { [OTHER] = { hash = 0x10, hashV2 = C(100, 0x20), updatedAt = 100, mailHash = 0, version = 100 } })
			end)
			local stub = TOGBankClassic_Guild.Info.alts[OTHER]
			assert.is_table(stub, "a banker's reply naming an unseen alt should seed a stub to sync into")
			assert.equal(0x10, stub.inventoryHash)
			assert.equal(C(100, 0x20), stub.inventoryHashV2, "the stub took revision 1 and not revision 2 -- both together, or neither")
			assert.is_true(TOGBankClassic_Guild:IsAltSyncPending(OTHER), "a stub with no content is pending")
		end)

		it("does not error on an unseen alt from a NON-banker, and seeds nothing from it", function()
			client("Bankchar")
			assert.has_no_error(function()
				hashListReplyFrom(PEER, { [OTHER] = { hash = 0x10, hashV2 = 0x20, updatedAt = 100, mailHash = 0 } })
			end)
			assert.is_nil(TOGBankClassic_Guild.Info.alts[OTHER],
				"a non-banker's reply must not fabricate a banker record")
			assert.is_true(TOGBankClassic_Guild:IsAltSyncPending(OTHER),
				"the cache still learned the alt exists, so it is pending until data arrives")
		end)

		it("still runs its request pass after an unseen alt -- the crash used to abort it", function()
			client("Otherguy")
			local sent = {}
			TOGBankClassic_Core.SendCommMessage = function(_, prefix, text, dist, target)
				sent[#sent + 1] = { prefix = prefix, text = text, dist = dist, target = target }
			end
			hashListReplyFrom(BANKER, { [OTHER] = { hash = 0x10, hashV2 = 0x20, updatedAt = 100, mailHash = 0 } })
			assert.is_true(#sent > 0,
				"nothing was sent after the reply: the handler stopped before asking for the data")
		end)

		-- P2P-034, the reproduction: 26 `No P2P response ... after 5s timeout` lines from one reply,
		-- Togweapons and Toglowweap among them -- banks the viewer held with the author's canon.
		local function guildRequestsAfter(sender, alts)
			local sent = {}
			TOGBankClassic_Core.SendCommMessage = function(_, prefix, text, dist)
				if prefix == "togbank-hl" and dist == "GUILD" and text:find("alt%-request") then
					sent[#sent + 1] = text
				end
			end
			hashListReplyFrom(sender, alts)
			return #sent
		end

		it("does NOT broadcast a request for a bank we hold with a canon when a reply carries only a differing revision-1 hash", function()
			client("Otherguy")
			TOGBankClassic_Guild.Info.alts[OTHER] = {
				name = OTHER, items = { { ID = 1, Count = 1 } }, money = 0,
				inventoryHash = 0x10, inventoryHashV2 = C(100, 0x20), inventoryUpdatedAt = 100, mailHash = 0,
			}
			assert.equal(0, guildRequestsAfter(STALE, { [OTHER] = { hash = 0xDEAD, updatedAt = 100 + 86400, mailHash = 0 } }),
				"a guild-wide alt-request went out for a bank nobody advertised anything newer for; " ..
				"it will time out in 5s and count against the catch-up budget (P2P-034)")
		end)

		it("does NOT broadcast for an OLDER or same-time canon, and DOES for a newer one", function()
			client("Otherguy")
			TOGBankClassic_Guild.Info.alts[OTHER] = {
				name = OTHER, items = { { ID = 1, Count = 1 } }, money = 0,
				inventoryHash = 0x10, inventoryHashV2 = C(100, 0x20), inventoryUpdatedAt = 100, mailHash = 0,
			}
			assert.equal(0, guildRequestsAfter(STALE, { [OTHER] = { hash = 0x11, hashV2 = C(99, 0x21), updatedAt = 99, mailHash = 0 } }))
			assert.equal(0, guildRequestsAfter(STALE, { [OTHER] = { hash = 0x11, hashV2 = C(100, 0x21), updatedAt = 100, mailHash = 0 } }))
			assert.equal(1, guildRequestsAfter(BANKER, { [OTHER] = { hash = 0x11, hashV2 = C(101, 0x21), updatedAt = 101, mailHash = 0 } }),
				"the banker published a newer version and the viewer did not ask for it")
		end)

		it("DOES broadcast for a bank we hold with NO canon when the reply carries one", function()
			client("Otherguy")
			TOGBankClassic_Guild.Info.alts[OTHER] = {
				name = OTHER, items = { { ID = 1, Count = 1 } }, money = 0,
				inventoryHash = 0x10, mailHash = 0,
			}
			assert.equal(1, guildRequestsAfter(BANKER, { [OTHER] = { hash = 0x10, hashV2 = C(100, 0x20), updatedAt = 100, mailHash = 0 } }),
				"revision 1 agreed, so the canon was never requested (HASH-CANON-006)")
		end)

		it("ignores what a peer advertises about OUR OWN character", function()
			client("Bankchar")
			TOGBankClassic_Guild.Info.alts[BANKER] = {
				name = BANKER, items = { { ID = 1, Count = 1 } }, money = 0,
				inventoryHash = 0x11, inventoryHashV2 = 0x22, mailHash = 0,
			}
			hashListReplyFrom(PEER, {
				[BANKER] = { hash = 0xDEAD, hashV2 = 0xBEEF, updatedAt = 99999, mailHash = 0 },
				[OTHER]  = { hash = 0x10, hashV2 = 0x20, updatedAt = 100, mailHash = 0 },
			})
			-- ANTI-VACUOUS: the other alt proves the reply was processed at all.
			assert.is_table(TOGBankClassic_Guild.latestBankerHashes[OTHER], "the reply was not processed")
			assert.is_nil(TOGBankClassic_Guild.latestBankerHashes[BANKER],
				"a peer's claim about our own character reached the cache")
			assert.is_false(TOGBankClassic_Guild:IsAltSyncPending(BANKER),
				"the banker's own tab would be red")
		end)

		it("keeps the held V2 entry against a later reply carrying a revision-1-only claim", function()
			-- Client is Otherguy, so the stale reply must come from someone ELSE: a reply from the
			-- character this client plays is its own echo and is discarded before the cache -- which
			-- made the first draft of this example pass with the rule deleted.
			client("Otherguy")
			hashListReplyFrom(BANKER, { [OTHER] = { hash = 0x10, hashV2 = C(100, 0x20), updatedAt = 100, mailHash = 0 } })
			hashListReplyFrom(STALE,  { [OTHER] = { hash = 0xDEAD, updatedAt = 100 + 86400, mailHash = 0 } })
			assert.equal(C(100, 0x20), TOGBankClassic_Guild.latestBankerHashes[OTHER].hashV2)
			-- ANTI-VACUOUS: the same sender CAN write when the rule allows it.
			hashListReplyFrom(STALE,  { [OTHER] = { hash = 0x30, hashV2 = C(101, 0x40), updatedAt = 101, mailHash = 0 } })
			assert.equal(C(101, 0x40), TOGBankClassic_Guild.latestBankerHashes[OTHER].hashV2,
				"the stale sender's replies never reach the cache, so the refusal above proved nothing")
		end)

		-- HASH-CANON-005: a peer still on v1.4.0 advertises a NUMERIC canon beside its publish time.
		-- It is re-encoded at the door, so the cache, the compare and the tab all see the same
		-- `<dts><hash>` the author will hold once they upgrade -- no rehydration.
		it("re-encodes a v1.4.0 peer's numeric canon on receipt, and it agrees with the re-encoded local copy", function()
			client("Otherguy")
			TOGBankClassic_Guild.Info.alts[OTHER] = {
				name = OTHER, items = { { ID = 1, Count = 1 } }, money = 0,
				inventoryHash = 0x10, inventoryHashV2 = 0x20, inventoryUpdatedAt = 100, mailHash = 0,
			}
			hashListReplyFrom(BANKER, { [OTHER] = { hash = 0x10, hashV2 = 0x20, updatedAt = 100, mailHash = 0 } })
			assert.equal(C(100, 0x20), TOGBankClassic_Guild.latestBankerHashes[OTHER].hashV2,
				"the numeric canon reached the cache un-re-encoded")
			assert.is_false(TOGBankClassic_Guild:IsAltSyncPending(OTHER),
				"the same old publish, held as a number and advertised as a number, reads as a mismatch")
		end)
	end)

	describe("the hash-offer (togbank-hl -> P2PSession:OnOffer)", function()
		before_each(function() env.reset() end)

		-- The client is Bankchar throughout: an offer FROM the character this client plays is its
		-- own echo and is (correctly) discarded before it reaches anything.
		it("stores the offer with its hashV2 intact", function()
			client("Bankchar")
			hashOfferFrom(PEER, { [OTHER] = { hash = 0x10, hashV2 = C(100, 0x20), updatedAt = 100, mailHash = 0 } })
			local cached = TOGBankClassic_Guild.latestBankerHashes and TOGBankClassic_Guild.latestBankerHashes[OTHER]
			assert.is_table(cached, "the offer never reached the cache")
			assert.equal(C(100, 0x20), cached.hashV2, "the offer path dropped hashV2 while copying the entry")
		end)

		it("does not let a revision-1-only offer with a newer time displace a V2 entry", function()
			client("Bankchar")
			hashOfferFrom(PEER, { [OTHER] = { hash = 0x10, hashV2 = C(100, 0x20), updatedAt = 100, mailHash = 0 } })
			assert.equal(C(100, 0x20), TOGBankClassic_Guild.latestBankerHashes[OTHER].hashV2, "precondition")
			hashOfferFrom(STALE, { [OTHER] = { hash = 0xDEAD, updatedAt = 100 + 86400, mailHash = 0 } })
			assert.equal(C(100, 0x20), TOGBankClassic_Guild.latestBankerHashes[OTHER].hashV2)
			-- ANTI-VACUOUS: the stale sender CAN write when the rule allows it, so the line above
			-- is the rule refusing and not the sender being dropped as unknown.
			hashOfferFrom(STALE, { [OTHER] = { hash = 0x30, hashV2 = C(101, 0x40), updatedAt = 101, mailHash = 0 } })
			assert.equal(C(101, 0x40), TOGBankClassic_Guild.latestBankerHashes[OTHER].hashV2,
				"the stale sender's offers never reach the cache at all, so the refusal above proved nothing")
		end)

		it("ignores an offer's claim about our own character, while still taking the others", function()
			client("Bankchar")
			hashOfferFrom(PEER, {
				[BANKER] = { hash = 0xDEAD, hashV2 = 0xBEEF, updatedAt = 99999, mailHash = 0 },
				[OTHER]  = { hash = 0x10, hashV2 = 0x20, updatedAt = 100, mailHash = 0 },
			})
			-- ANTI-VACUOUS: the other alt proves the offer was processed at all, so the nil below
			-- is a refusal and not a path that never ran.
			assert.is_table(TOGBankClassic_Guild.latestBankerHashes[OTHER], "the offer was not processed")
			assert.is_nil(TOGBankClassic_Guild.latestBankerHashes[BANKER],
				"a peer's claim about our own character reached the cache")
			assert.is_false(TOGBankClassic_Guild:IsAltSyncPending(BANKER))
		end)
	end)

	describe("the login seed (Guild:Init)", function()
		before_each(function() env.reset() end)

		local function initWith(alts)
			local info = {
				name = GUILD, alts = alts,
				requests = {}, requestsTombstones = {}, settings = {},
				roster = { alts = {} },   -- RebuildBankerRoster (deferred 1s) writes here
			}
			TOGBankClassic_Database.Load = function() return info end
			TOGBankClassic_Guild.Info = nil
			assert.is_true(TOGBankClassic_Guild:Init(GUILD))
			env.advance(1.5)   -- PERF-010: the seed is deferred behind RebuildBankerRoster
			return info
		end

		it("seeds the cache from our own stored records WITH hashV2, so a V2 claim cannot displace it on time alone", function()
			client("Otherguy")
			initWith({
				[OTHER] = { name = OTHER, items = { { ID = 1, Count = 1 } }, money = 0,
					inventoryHash = 0x10, inventoryHashV2 = C(100, 0x20), inventoryUpdatedAt = 100, version = 100, mailHash = 0 },
			})
			local seeded = TOGBankClassic_Guild.latestBankerHashes and TOGBankClassic_Guild.latestBankerHashes[OTHER]
			assert.is_table(seeded, "the seed never ran, or dropped the stored banker")
			assert.equal(C(100, 0x20), seeded.hashV2, "the seed wrote a revision-1-only entry from a record that carries hashV2")
			assert.is_false(TOGBankClassic_Guild:IsAltSyncPending(OTHER), "our own stored state reads as behind itself")
		end)

		-- HASH-CANON-005: what v1.4.0 left in the saved variables is re-encoded ONCE, on load, so
		-- the guild does not rehydrate. A numeric canon with no publish time cannot be placed in
		-- time and is cleared rather than left to compare a number against strings forever.
		it("re-encodes every held v1.4.0 numeric canon on load, and clears the ones with no publish time", function()
			client("Otherguy")
			local info = initWith({
				[OTHER]  = { name = OTHER, items = { { ID = 1, Count = 1 } }, money = 0,
					inventoryHash = 0x10, inventoryHashV2 = 0x20, inventoryUpdatedAt = 100, version = 100, mailHash = 0 },
				[BANKER] = { name = BANKER, items = { { ID = 2, Count = 1 } }, money = 0,
					inventoryHash = 0x11, inventoryHashV2 = 0x21, mailHash = 0 },        -- no time at all
				["Already-Testrealm"] = { name = "Already-Testrealm", items = {}, money = 0,
					inventoryHash = 0x12, inventoryHashV2 = C(50, 0x22), inventoryUpdatedAt = 50, mailHash = 0 },
			})
			assert.equal(C(100, 0x20), info.alts[OTHER].inventoryHashV2, "the numeric canon was not re-encoded")
			assert.is_nil(info.alts[BANKER].inventoryHashV2, "a numeric canon with no publish time was kept")
			assert.equal(C(50, 0x22), info.alts["Already-Testrealm"].inventoryHashV2, "an already-encoded canon was touched")
			assert.equal(C(100, 0x20), TOGBankClassic_Guild.latestBankerHashes[OTHER].hashV2,
				"the seed ran before the re-encode and cached the number")
		end)

		it("reports how many it re-encoded and cleared", function()
			client("Otherguy")
			TOGBankClassic_Guild.Info = { name = GUILD, alts = {
				a = { inventoryHashV2 = 1, inventoryUpdatedAt = 10 },
				b = { inventoryHashV2 = 2, version = 20 },                -- falls back to version
				c = { inventoryHashV2 = 3 },                              -- nothing to lead with
				d = { inventoryHashV2 = C(5, 4) },                        -- already a canon
				e = { inventoryHash = 5 },                                -- revision 1 only: untouched
			} }
			local reencoded, cleared = TOGBankClassic_Guild:ReencodeHeldCanons()
			assert.equal(2, reencoded)
			assert.equal(1, cleared)
			assert.equal(C(20, 2), TOGBankClassic_Guild.Info.alts.b.inventoryHashV2)
			assert.equal(5, TOGBankClassic_Guild.Info.alts.e.inventoryHash, "a revision-1 hash was touched")
			assert.is_nil(TOGBankClassic_Guild.Info.alts.e.inventoryHashV2)
		end)
	end)
end)
