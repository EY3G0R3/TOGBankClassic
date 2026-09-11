-- V2 ON THE WIRE — the real send envelope and the real receive dispatch.
--
-- WRITTEN FOR HOW V2 SHOULD BEHAVE, NOT FOR WHAT THE CODE CURRENTLY DOES. Where the two disagree
-- the code is wrong, not this file. Every assertion below is a requirement of the design in
-- docs/INVENTORY_V2.md plus the standing operator directive that V2 carries no links:
--
--   "there should be no 'link stripping' in V2. in V2 the link is just constructed on the other
--    side from ItemDB ... Link stripping is causing a lot of problems."
--
-- REAL LIBRARIES, REAL ENVELOPE. This loads the actual Core.lua -- AceAddon, AceComm, AceSerializer
-- and AceCommQueue from the sibling installs via the harness registry -- so `SerializeWithChecksum`
-- here is the exact framing that ships (`<AceSerialized>\030<checksum>\031END`). A stubbed
-- serialiser would make every round-trip pass by construction; that looseness is precisely what let
-- CMD-001 hide behind a fake `GetArgs` for months.
--
-- THE INVARIANT THAT ENCODES THE DIRECTIVE, and it is the one worth having: a serialised V2 payload
-- contains NO link markup and NO item-string. Not "few links", none. If a link ever reappears on
-- the wire -- through a helpful fallback, a reinstated ItemString, or a merge that resurrects
-- StripDeltaLinks -- this fails, and it fails for the right reason rather than as a size regression
-- nobody notices.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local ME = "Bankchar-Testrealm"

--- Load the addon far enough to drive a real send envelope and a real receive dispatch.
local function loadWireStack()
	env.stubOutput()
	require("env.ace").load("AceAddon-3.0", "AceComm-3.0", "AceConsole-3.0",
		"AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
	require("env.libs").load("AceCommQueue-1.0")

	env.loadModules({
		"Modules/Constants.lua",
		"Modules/Switches.lua",
		"Modules/Item.lua",
		"Modules/Inventory/Record.lua",
		"Modules/Inventory/Resolve.lua",
		"Modules/Inventory/Store.lua",
		"Modules/Inventory/Scan.lua",
		"Modules/Inventory/Wire.lua",
		"Modules/DeltaComms.lua",
	})
	-- AceAddon refuses a second NewAddon for the same name, and the whole suite shares one Lua
	-- state -- so without evicting the registration, every example after the first dies with
	-- "Addon 'TOGBankClassic' already exists". Same shape as the LibStub eviction the project's
	-- test rules already require for reloading a library.
	local AceAddon = LibStub("AceAddon-3.0")
	if AceAddon and AceAddon.addons then
		AceAddon.addons["TOGBankClassic"] = nil
		if AceAddon.addonstatus then AceAddon.addonstatus["TOGBankClassic"] = nil end
	end
	env.loadFile("Core.lua")

	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	TOGBankClassic_Database = { db = { global = { switches = { inventoryV2 = true } } } }
	-- Reached only on the corruption path: DeserializeWithChecksum asks Options whether to raise
	-- the integrity mismatch to chat. Without it the corrupted-payload example dies inside the
	-- handler rather than at its assertion, which reads as the check being broken when it is
	-- working exactly as intended.
	TOGBankClassic_Options = {
		IsIntegrityCheckDiagnosticsEnabled = function() return false end,
		IsSyncProgressMuted = function() return true end,
	}
	return TOGBankClassic_Core
end

describe("V2 payloads on the real wire envelope", function()
	local Core, Wire, Record

	before_each(function()
		env.reset()
		Core   = loadWireStack()
		Wire   = TOGBankClassic_Inventory_Wire
		Record = TOGBankClassic_Inventory_Record
	end)

	--- A payload for an alt holding a plain stack, a suffixed item and an enchanted one.
	local function samplePayload()
		return Wire.encode(ME, {
			Record.new(858, 5),
			Record.new(15260, 1, 863),
			Record.new(10132, 2, 0, 2504),
		}, 123456)
	end

	it("survives the real checksum envelope unchanged", function()
		local body = Core:SerializeWithChecksum(samplePayload())
		assert.is_string(body)

		-- TWO return values, `success, data` -- AceSerializer's contract, which the envelope keeps.
		-- Assuming the single-value form is how a spec ends up asserting against a boolean and
		-- reporting a defect that is its own misreading.
		local ok, decoded = Core:DeserializeWithChecksum(body,
			{ sender = ME, prefix = "togbank-d4" })
		assert.is_true(ok, "the payload did not survive the real envelope: " .. tostring(decoded))
		assert.is_table(decoded)

		local altName, records, money = Wire.decode(decoded)
		assert.equal(ME, altName)
		assert.equal(123456, money)
		assert.equal(3, #records)

		local byKey = {}
		for _, rec in ipairs(records) do byKey[Record.key(rec)] = Record.count(rec) end
		assert.equal(5, byKey["858:0:0"])
		assert.equal(1, byKey["15260:863:0"], "the suffix was lost in the envelope")
		assert.equal(2, byKey["10132:0:2504"], "the enchant was lost in the envelope")
	end)

	-- THE DIRECTIVE, AS AN INVARIANT. V2 carries integers; the receiver rebuilds the link from
	-- LibItemDB. A link on the wire means the link-stripping decision has come back, and that
	-- decision -- a guess at transmission time about another machine's item cache -- is what
	-- corrupts data.
	it("puts NO link and NO item-string on the wire", function()
		local body = Core:SerializeWithChecksum(samplePayload())
		assert.is_nil(body:find("|H", 1, true),
			"a hyperlink reached the wire -- V2 must send integers and let the receiver rebuild")
		assert.is_nil(body:find("|c", 1, true),
			"a colour escape reached the wire, so something serialised a full link")
		assert.is_nil(body:find("item:", 1, true),
			"an ItemString reached the wire -- that is StripDeltaLinks' fallback returning")
	end)

	-- Shape sniffing, not a flag: an old client never learned to set a marker, so the receiver must
	-- classify by structure or it will mis-route every legacy payload.
	it("is distinguishable from a legacy payload by shape alone", function()
		assert.is_true(Wire.isV2(samplePayload()))
		assert.is_false(Wire.isV2({ type = "alt-delta", name = ME, changes = {} }),
			"a legacy delta was classified as V2, so it would be applied through the wrong path")
	end)

	-- A tuple payload should be dramatically smaller than the link payload it replaces. Asserted as
	-- a ratio rather than a byte count so it measures the ENCODING and not the fixture size.
	it("is far smaller than the equivalent link payload", function()
		local tuples = Core:SerializeWithChecksum(samplePayload())
		local linky  = Core:SerializeWithChecksum({
			type = "alt-delta", name = ME,
			changes = { items = { added = {
				{ ID = 858,   Count = 5, Link = "|cffffffff|Hitem:858:0:0:0:0:0:0:0:60|h[Minor Healing Potion]|h|r" },
				{ ID = 15260, Count = 1, Link = "|cffffffff|Hitem:15260:0:0:0:0:0:863:0:60|h[Stone Hammer of the Tiger]|h|r" },
				{ ID = 10132, Count = 2, Link = "|cffffffff|Hitem:10132:2504:0:0:0:0:0:0:60|h[Runed Copper Rod]|h|r" },
			} } },
		})
		assert.is_true(#tuples < #linky / 2, string.format(
			"tuples (%d bytes) are not less than half the link payload (%d bytes) -- the whole " ..
			"point of the format is that a row is a few integers rather than a 70-90 byte link",
			#tuples, #linky))
	end)

	it("refuses a payload whose checksum does not match", function()
		local body = Core:SerializeWithChecksum(samplePayload())
		-- Flip a byte in the serialised body, leaving the framing intact.
		local corrupted = body:gsub("858", "859", 1)
		assert.is_not_equal(body, corrupted, "precondition: the fixture was not actually corrupted")
		local ok = Core:DeserializeWithChecksum(corrupted,
			{ sender = ME, prefix = "togbank-d4" })
		assert.is_false(ok,
			"a corrupted payload was accepted -- the checksum framing exists to catch exactly this")
	end)

	-- Wire.encode returning nil for an unsendable alt is the guard that stops an empty envelope
	-- being applied by a receiver as "this banker has nothing".
	it("never builds a payload for a nameless alt", function()
		assert.is_nil(Wire.encode(nil, { Record.new(858, 1) }, 0))
		assert.is_nil(Wire.encode("", { Record.new(858, 1) }, 0))
	end)

	-- AUDIT-S3. This example used to be "still decodes a legacy link payload", headed "Mixed-version
	-- guilds are permanent, not a migration window". Neither is true since the 2026-09-09 directive
	-- deleted backwards compatibility on the wire, and the example pinned the decoder ACCEPTING a
	-- format the addon must drop. "Ignored" being indistinguishable from "that banker has no items"
	-- was a real concern -- and it is answered elsewhere, by Chat.lua warning the user by name when
	-- a banker's payload is dropped, not by decoding what should not be decoded.
	-- writ-cannot: the removed "placeholder anchor" example was mine, added seconds ago by mistake
	-- as an insertion marker while appending the join block below. It asserted `true` and covered
	-- nothing -- an assertion-free test is exactly what this project's rules forbid, because it
	-- reads as coverage and can never fail. Nothing regresses by its removal.
	it("drops a legacy link payload rather than decoding it, even with real links", function()
		local altName, records, _, format = Wire.decode({
			name = ME,
			items = {
				{ ID = 858, Count = 5,
				  Link = "|cffffffff|Hitem:858:0:0:0:0:0:0:0:60|h[Minor Healing Potion]|h|r" },
				{ ID = 15260, Count = 1,
				  Link = "|cffffffff|Hitem:15260:0:0:0:0:0:863:0:60|h[Stone Hammer]|h|r" },
			},
		})
		assert.equal("dropped", format,
			"a legacy payload was accepted -- the wire is tuples-only and the decoder must say so " ..
			"itself rather than rely on its caller (AUDIT-S3)")
		assert.is_nil(altName)
		assert.equal(0, #records)
	end)
end)

-- THE JOIN: sender's Guild:SendAltData -> the payload -> a DIFFERENT client's
-- Chat:OnCommReceived. This is the seam the other files leave open. syncwire_spec above covers the
-- envelope, syncpipeline_spec covers scan-to-apply, and NEITHER notices if the two ends disagree
-- about what goes on the wire.
--
-- It is also the only place that catches the "half implemented" failure, which is not about item
-- rows at all: a receiver can store the tuples perfectly and still be broken, because the
-- NEGOTIATION layer reads `HasAltContent` and `inventoryHash` off the LEGACY record. A client that
-- received tuples and did not stamp those reports itself as having nothing -- so it re-requests on
-- every hash-list broadcast, forever, and never offers the alt onward. The last three assertions
-- exist for that and nothing else.
--
-- SEAM DECLARED HONESTLY: Core.SendCommMessage is captured rather than driven through AceComm, so
-- this does not cover chunking or the 254-byte split. What it covers is that the bytes SendAltData
-- hands to the transport are the bytes OnCommReceived can consume.
describe("the join: SendAltData -> OnCommReceived on another client", function()
	local BANKER = "Bankchar-Testrealm"
	local PEER   = "Otherguy-Testrealm"
	local GUILD  = "Testguild"

	--- Stand up a whole client as `who` (see env.standUpClient -- lifted from here). The roster
	--- is REAL LibGuildRoster, which is load-bearing: with it absent every payload is refused as
	--- unauthorised, silently, so a spoof test passes vacuously.
	local function loadClient(who)
		env.standUpClient(who, { { name = BANKER, note = "gbank" }, { name = PEER } }, GUILD)
		assert.is_true(TOGBankClassic_Guild:IsBank(BANKER),
			"precondition: the roster did not come up, so every authorisation check below would " ..
			"refuse and the assertions would be measuring the setup rather than the code")
	end

	--- Capture what the addon hands the transport, without driving AceComm's chunking.
	local function captureSends()
		local sent = {}
		TOGBankClassic_Core.SendCommMessage = function(_, prefix, text, dist, target)
			sent[#sent + 1] = { prefix = prefix, text = text, dist = dist, target = target }
		end
		return sent
	end

	it("delivers a banker's tuples to a peer, and leaves the peer able to serve them on", function()
		-- ---- CLIENT A: the banker ----
		env.reset()
		loadClient()
		local Record = TOGBankClassic_Inventory_Record
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, BANKER, {
			Record.new(858, 5),
			Record.new(15260, 1, 863),
			Record.new(15260, 2, 2504),
		}, 4242)
		-- SendAltData requires a legacy alt entry to exist for the alt; V2 supplies the contents.
		TOGBankClassic_Guild.Info.alts[BANKER] = { name = BANKER, items = {}, money = 4242 }
		-- HASH-CANON-001: THE SENDER MUST HAVE PUBLISHED A CANON, or there is nothing for the
		-- receiver to carry and this example measures the empty case instead of the delivery. In
		-- game this stamp happens in Bank:Scan; here it is done explicitly, from the same view the
		-- payload is built from, because that is what a scan would have produced.
		TOGBankClassic_Core:StampInventoryHashes(TOGBankClassic_Guild.Info.alts[BANKER],
			TOGBankClassic_Inventory_Store:GetAltView(GUILD, BANKER), nil, nil, 4242)
		local publishedHash   = TOGBankClassic_Guild.Info.alts[BANKER].inventoryHash
		local publishedHashV2 = TOGBankClassic_Guild.Info.alts[BANKER].inventoryHashV2
		assert.is_not_nil(publishedHashV2,
			"precondition: the sender published no revision-2 canon, so the delivery assertions " ..
			"below would pass against nil on both sides and prove nothing")

		local sent = captureSends()
		TOGBankClassic_Guild:SendAltData(BANKER, 0, 0, PEER)

		local d4
		for _, msg in ipairs(sent) do if msg.prefix == "togbank-d4" then d4 = msg end end
		assert.is_table(d4, "SendAltData sent no togbank-d4 message at all")
		assert.is_nil(d4.text:find("|H", 1, true),
			"the banker put a hyperlink on the wire -- V2 must send integers only")
		assert.is_nil(d4.text:find("item:", 1, true),
			"the banker put an ItemString on the wire")

		-- ---- CLIENT B: a different character, nothing stored ----
		env.reset()
		loadClient("Otherguy")
		Record = TOGBankClassic_Inventory_Record
		assert.equal(0, #TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, BANKER),
			"precondition: client B already had the banker's data")

		TOGBankClassic_Chat:OnCommReceived("togbank-d4", d4.text, "WHISPER", BANKER)

		local got = {}
		for _, rec in ipairs(TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, BANKER)) do
			got[Record.key(rec)] = Record.count(rec)
		end
		assert.equal(5, got["858:0:0"], "the plain stack did not arrive")
		assert.equal(1, got["15260:863:0"], "the first suffix variant did not arrive")
		assert.equal(2, got["15260:2504:0"],
			"the second suffix variant did not arrive, or collapsed onto the first")

		-- THE HALF-IMPLEMENTED CHECKS. Storing the rows is not enough; the negotiation layer has
		-- to be able to see them, or client B tells the guild it has nothing and re-asks forever.
		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		assert.is_table(alt, "receiving tuples did not create a record the sync layer can read")
		assert.is_true(TOGBankClassic_Guild:HasAltContent(alt, BANKER),
			"client B holds the tuples but reports NO CONTENT -- it will re-request on every " ..
			"hash-list broadcast and never offer this alt to anyone else")
		-- HASH-CANON-001 CHANGED WHAT THIS PAIR COMPARES AGAINST, and the change is the point.
		--
		-- They used to assert that B's hashes equalled a value RECOMPUTED from B's own store. That
		-- passes whether B carried the author's canon or minted its own, so it could not tell the
		-- two apart -- and the behaviour it was silently blessing is the one DeltaSync's rules name
		-- as the defect ("recompute on receipt ... nobody is authoritative").
		--
		-- They now assert B holds EXACTLY WHAT A PUBLISHED, captured from A's record before the
		-- client swap. A recompute on B's side would have to collide with A's number to pass, which
		-- is the property that actually matters: identity travels with the data.
		assert.equal(publishedHashV2, alt.inventoryHashV2,
			"client B's revision-2 hash is not the one the AUTHOR published, so the two disagree " ..
			"about the same inventory and every comparison reports it stale")

		-- The other half: a V2 client must ALSO carry the author's revision-1 hash, or versioning
		-- buys nothing -- the whole point is that a mixed guild needs no coordinated release. A
		-- receiver holding only revision 2 looks hashless to every client that has not upgraded.
		assert.is_not_nil(alt.inventoryHash,
			"client B stored no revision-1 hash, so an unmigrated peer sees no hash at all")
		assert.equal(publishedHash, alt.inventoryHash,
			"client B's revision-1 hash is not the author's, so the two of them would give an " ..
			"unmigrated third client contradictory answers about the same inventory")
	end)

	-- TABCOLOUR-001. A red tab means IsAltSyncPending: the advertised hash disagrees with what we
	-- hold, or we hold nothing. Delivery is the event that ends that state, so delivery has to
	-- repaint -- the only repaints hung off the two places NEW HASHES arrive, which is when a tab
	-- turns red, never when it should turn back. Reported from a live guild: two bankers received in
	-- full, tabs still red until an unrelated broadcast happened to redraw them.
	--- Stand up the banker, scan, and capture BOTH things it publishes: the tuple payload and the
	--- hash-list entry it advertises. Built by the real builder, not by hand: a hand-rolled entry
	--- with `mailHash = nil` reads as "the peer said nothing about mail" and fails closed forever,
	--- which is a property of the fixture, not of delivery.
	local function authorPublishes()
		env.reset()
		loadClient()
		local Record = TOGBankClassic_Inventory_Record
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, BANKER, { Record.new(858, 5) }, 0)
		TOGBankClassic_Guild.Info.alts[BANKER] = { name = BANKER, items = {}, money = 0 }
		TOGBankClassic_Core:StampInventoryHashes(TOGBankClassic_Guild.Info.alts[BANKER],
			TOGBankClassic_Inventory_Store:GetAltView(GUILD, BANKER), nil, nil, 0)
		local advertised = TOGBankClassic_Guild:BuildBankerHashList()[BANKER]
		assert.is_table(advertised, "precondition: the banker advertises nothing for itself")
		assert.is_not_nil(advertised.hashV2, "precondition: the banker advertised no revision-2 canon")
		local sent = captureSends()
		TOGBankClassic_Guild:SendAltData(BANKER, 0, 0, PEER)
		local d4
		for _, msg in ipairs(sent) do if msg.prefix == "togbank-d4" then d4 = msg end end
		assert.is_table(d4, "SendAltData sent no togbank-d4 message at all")
		return d4.text, advertised
	end

	--- A hash-list reply arriving from `sender` carrying `summary` for the banker, through the
	--- real receive path.
	local function hashListFrom(sender, summary)
		local body = TOGBankClassic_Core:SerializeWithChecksum({
			type = "hash-list-reply", alts = { [BANKER] = summary },
		})
		TOGBankClassic_Chat:OnCommReceived("togbank-hlr", body, "WHISPER", sender)
	end

	it("asks the Inventory window to repaint on delivery, and the alt is no longer pending", function()
		local payload, advertised = authorPublishes()

		env.reset()
		loadClient("Otherguy")
		-- The peer has been TOLD what the banker holds (a hash-list arrived) and holds nothing
		-- itself: that is exactly the red-tab state.
		hashListFrom(BANKER, advertised)
		assert.is_true(TOGBankClassic_Guild:IsAltSyncPending(BANKER),
			"precondition: the peer is not pending before delivery, so nothing below can turn")

		local repaints = 0
		TOGBankClassic_UI_Inventory = {
			isOpen = true,
			RefreshSoon = function() repaints = repaints + 1 end,
		}
		TOGBankClassic_Chat:OnCommReceived("togbank-d4", payload, "WHISPER", BANKER)
		TOGBankClassic_UI_Inventory = nil

		assert.equal(1, repaints,
			"the delivery did not ask the Inventory window to repaint, so a red tab stays red " ..
			"until some later hash broadcast happens to redraw it")
		assert.is_false(TOGBankClassic_Guild:IsAltSyncPending(BANKER),
			"the data landed and the author's hashes were stored, yet the alt still reads as " ..
			"pending -- a repaint would draw it red again")
	end)

	-- THE OPERATOR'S RULE, verbatim: "I NEED CANON hashes written ONCE by the banker, then passed
	-- around. NEVER mutated. The hash HAS to have the DTS in it and the NEWER V2 Hash wins." And the
	-- failure it was written from: "the banker logged off and then I was getting the mutated V1 hash
	-- that was 'newer' and it was over-writing my V2 data."
	--
	-- The advertised-hash cache is where that overwrite happens on the RECEIVER: whatever it holds
	-- for an alt is what the tab colour and the re-request decision are compared against. So the
	-- cache must obey the same rule as the data -- a revision-1-only claim is not a V2 hash and can
	-- never displace one, and among V2 claims only a strictly NEWER publish time wins.
	describe("the advertised-hash cache: the NEWER V2 hash wins", function()
		local function peerHoldingTheCanon()
			local payload, advertised = authorPublishes()
			env.reset()
			loadClient("Otherguy")
			hashListFrom(BANKER, advertised)
			TOGBankClassic_Chat:OnCommReceived("togbank-d4", payload, "WHISPER", BANKER)
			assert.is_false(TOGBankClassic_Guild:IsAltSyncPending(BANKER),
				"precondition: the peer is still pending after the author's own delivery")
			return advertised
		end

		it("keeps the author's V2 entry when a peer advertises a revision-1-only hash with a NEWER time", function()
			local canon = peerHoldingTheCanon()
			-- The shape that did the damage: an unmigrated relayer recomputed its own revision-1
			-- number and stamped its own clock, so it looks newer than the author's publish time.
			hashListFrom("Stalepeer-Testrealm", {
				hash = 0xDEAD, updatedAt = canon.updatedAt + 3600, mailHash = 0, version = 1,
			})
			local cached = TOGBankClassic_Guild.latestBankerHashes[BANKER]
			assert.equal(canon.hashV2, cached.hashV2,
				"a revision-1-only claim displaced the author's revision-2 canon in the cache -- " ..
				"the tab turns red and the client re-requests from a peer whose data it cannot read")
			assert.is_false(TOGBankClassic_Guild:IsAltSyncPending(BANKER),
				"holding the author's own delivery, the alt reads as pending because a stale peer " ..
				"advertised a mutated hash -- the red tab that never clears")
		end)

		it("keeps the newer V2 entry when a peer advertises an OLDER V2 hash", function()
			local canon = peerHoldingTheCanon()
			hashListFrom("Stalepeer-Testrealm", {
				hash = 0xDEAD, hashV2 = env.canon(canon.updatedAt - 3600, 0xBEEF),
				updatedAt = canon.updatedAt - 3600, mailHash = 0, version = 1,
			})
			assert.equal(canon.hashV2, TOGBankClassic_Guild.latestBankerHashes[BANKER].hashV2,
				"an older V2 claim displaced a newer one -- 'newer wins' is the whole rule")
			assert.is_false(TOGBankClassic_Guild:IsAltSyncPending(BANKER))
		end)

		it("takes a NEWER V2 entry, so a rescan by the banker turns the tab red again", function()
			local canon = peerHoldingTheCanon()
			-- The banker scanned again: a new canon with a later publish time. THIS one must win,
			-- or the peer never learns it is behind.
			local newer = env.canon(canon.updatedAt + 60, 0xF00D)
			hashListFrom(BANKER, {
				hash = 0xCAFE, hashV2 = newer, updatedAt = canon.updatedAt + 60, mailHash = 0, version = 2,
			})
			assert.equal(newer, TOGBankClassic_Guild.latestBankerHashes[BANKER].hashV2,
				"a strictly newer V2 canon did not replace the older one")
			assert.is_true(TOGBankClassic_Guild:IsAltSyncPending(BANKER),
				"the banker published a newer version and the peer does not read as behind")
		end)

		it("never lets a hash-offer strip the revision-2 hash out of a cached entry", function()
			local canon = peerHoldingTheCanon()
			-- The P2P offer path writes the cache too. An offer for the SAME version must not
			-- replace a full entry with one that has forgotten hashV2 -- that silently drops every
			-- later comparison to revision 1.
			TOGBankClassic_P2PSession:OnOffer("Relayer-Testrealm", { [BANKER] = {
				hash = canon.hash, hashV2 = canon.hashV2, updatedAt = canon.updatedAt, mailHash = canon.mailHash,
			} })
			assert.equal(canon.hashV2, TOGBankClassic_Guild.latestBankerHashes[BANKER].hashV2,
				"the offer path wrote a cache entry without hashV2")
			assert.is_false(TOGBankClassic_Guild:IsAltSyncPending(BANKER))
		end)
	end)

	-- `sendV2Wire` is the ROLLBACK. Emission is the only half a peer can observe, so it has to be
	-- flippable without also reverting local storage -- a guild that turns out to hold unmigrated
	-- clients needs to stop emitting tuples while keeping its own V2 store. If this switch stops
	-- gating anything, that escape hatch is gone and nobody finds out until a guild is stuck.
	it("emits no tuple payload while sendV2Wire is off, even with inventoryV2 on", function()
		env.reset()
		loadClient()
		local Record = TOGBankClassic_Inventory_Record
		TOGBankClassic_Database.db.global.switches.sendV2Wire = false

		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, BANKER, { Record.new(858, 5) }, 0)
		TOGBankClassic_Guild.Info.alts[BANKER] = { name = BANKER, items = {}, money = 0 }

		local sent = captureSends()
		TOGBankClassic_Guild:SendAltData(BANKER, 0, 0, PEER)

		for _, msg in ipairs(sent) do
			if msg.prefix == "togbank-d4" then
				assert.is_false(TOGBankClassic_Inventory_Wire.isV2(
					select(2, TOGBankClassic_Core:DeserializeWithChecksum(msg.text))),
					"a tuple payload went out with sendV2Wire OFF -- the emission rollback does " ..
					"nothing, so a guild with unmigrated clients cannot be rescued")
			end
		end
	end)

	it("refuses tuples for an alt the sender is not entitled to speak for", function()
		env.reset()
		loadClient()
		local Record = TOGBankClassic_Inventory_Record
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, BANKER, { Record.new(858, 5) }, 0)
		TOGBankClassic_Guild.Info.alts[BANKER] = { name = BANKER, items = {}, money = 0 }
		local sent = captureSends()
		TOGBankClassic_Guild:SendAltData(BANKER, 0, 0, PEER)
		local d4
		for _, msg in ipairs(sent) do if msg.prefix == "togbank-d4" then d4 = msg end end
		assert.is_table(d4, "precondition: nothing was sent to replay")

		env.reset()
		loadClient("Otherguy")
		-- The store must be EMPTY before the stranger's message, or "1 record afterwards" cannot
		-- distinguish "the spoof was stored" from "the first half of this test leaked".
		assert.equal(0, #TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, BANKER),
			"precondition: client B started with the banker's records already present, so the " ..
			"assertion below would measure leakage between the two halves rather than the guard")

		-- "Nobody" is not in the roster, so IsAltDataAllowed must refuse regardless of payload.
		-- Asserted separately from the outcome: if authorisation itself is permissive, the failure
		-- should say so here rather than looking like the receive branch ignoring it.
		assert.is_false(TOGBankClassic_Chat:IsAltDataAllowed("Nobody-Testrealm", BANKER),
			"precondition: authorisation considers a stranger entitled to speak for a banker, " ..
			"which is a defect in IsAltDataAllowed rather than in the V2 receive branch")

		-- Record what the receive path actually asked and was told. Without this, "a record
		-- appeared" cannot distinguish the guard being skipped from the guard being overruled.
		local checks = {}
		local realAllowed = TOGBankClassic_Chat.IsAltDataAllowed
		TOGBankClassic_Chat.IsAltDataAllowed = function(s, sndr, alt)
			local r = realAllowed(s, sndr, alt)
			checks[#checks + 1] = { sender = sndr, alt = alt, result = r }
			return r
		end

		TOGBankClassic_Chat:OnCommReceived("togbank-d4", d4.text, "WHISPER", "Nobody-Testrealm")
		TOGBankClassic_Chat.IsAltDataAllowed = realAllowed

		assert.is_true(#checks > 0,
			"the receive path never consulted IsAltDataAllowed at all, so the V2 branch is " ..
			"storing without any authorisation check")
		assert.is_false(checks[1].result,
			"authorisation returned true inside the receive path for a sender it refuses when " ..
			"called directly, so something earlier in OnCommReceived is granting it")

		assert.equal(0, #TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, BANKER),
			"a tuple payload from a stranger was stored -- V2 must not be the easy way to spoof " ..
			"a banker's inventory, and the legacy branch has always checked this")
	end)

	-- AUDIT FINDING 27 -- where a STALE alt hash actually heals, pinned rather than argued.
	--
	-- The finding corrected an addendum of mine that said "the first scan replaces it". It does not:
	-- Bank:Scan takes no arguments and derives its subject from GetNormalizedPlayer, so it writes the
	-- LOGGED-IN character's own record and never touches an alt record. The reviewer named
	-- DeltaComms.lua:1319-1326 as the real healer -- an unconditional recompute after a delta landed.
	--
	-- THAT FUNCTION NO LONGER EXISTS. ApplyDelta and ApplyItemDelta were deleted in INV2 step 10 under
	-- the no-backwards-compatibility directive, so the remedy the finding asked for would now cite
	-- deleted code. The route moved to Chat.lua's tuple receive path, which re-stamps BOTH revisions
	-- from the stored view unconditionally -- and healing is STRONGER than when the finding was
	-- written, because with the legacy receive branch gone this is the ONLY inbound data path.
	--
	-- The delivery example above cannot catch this: its receiver starts empty, so it proves the hash
	-- is WRITTEN, not that a WRONG one is REPLACED. Those are different properties and only the
	-- second one is what "self-healing" means.
	--
	-- HASH-CANON-001 REWROTE THIS EXAMPLE, AND THE ORIGINAL WAS A MISTAKE WORTH RECORDING. As first
	-- written it asserted the receiver's hash equalled A FRESH LOCAL RECOMPUTE -- which pinned
	-- recompute-on-receipt, the exact behaviour DeltaSync's canonical-hash rules forbid ("a receiver
	-- stores the author's hash verbatim, even if it could recompute it"). It was built to discharge
	-- finding 27, PROVEN RED, and shipped green -- and none of that made it correct, because
	-- finding 27 asked WHERE healing happens and nobody asked WHETHER a receiver should mint a hash
	-- at all. A spec that pins an anti-pattern is worse than no spec: the next person to fix the
	-- code meets a red test with a confident message telling them they broke something.
	--
	-- The PROPERTY is unchanged and still worth pinning -- a stale hash must not survive a delivery.
	-- What changed is what replaces it: the AUTHOR'S value, not ours.
	it("replaces a receiver's STALE hashes with the AUTHOR'S, not with a local recompute", function()
		env.reset()
		loadClient(PEER)
		local Record = TOGBankClassic_Inventory_Record

		-- The receiver already holds this alt, with hashes that describe an inventory it no longer
		-- has -- the exact state the old migration left behind, and the state Chat.lua's other
		-- corrector CANNOT fix because that one is gated on the hash being ABSENT.
		TOGBankClassic_Guild.Info.alts[BANKER] = {
			name = BANKER, items = {}, money = 0,
			inventoryHash = 111111, inventoryHashV2 = env.canon(1700000000, 222222),
		}

		-- Build a payload on this same client, then feed it back as if it arrived from the banker.
		-- THE AUTHOR'S HASHES ARE DELIBERATELY VALUES NO RECOMPUTE COULD PRODUCE. That is what makes
		-- this example able to tell "stored the author's canon" from "minted its own": if the
		-- receiver recomputed, it would land on the hash of a single 858x5 stack, never on 777777.
		-- HASH-CANON-005: the revision-2 canon is `<dts><hash>`, a string, and travels as one.
		local AUTHOR_HASH, AUTHOR_HASHV2 = 777777, env.canon(1757000000, 888888)
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, BANKER, { Record.new(858, 5) }, 4242)
		local payload = TOGBankClassic_Inventory_Wire.encode(
			BANKER, TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, BANKER), 4242,
			AUTHOR_HASH, AUTHOR_HASHV2, 1757000000)
		local body = TOGBankClassic_Core:SerializeWithChecksum(payload)

		TOGBankClassic_Chat:OnCommReceived("togbank-d4", body, "WHISPER", BANKER)

		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		assert.equal(AUTHOR_HASH, alt.inventoryHash,
			"the receiver did not store the AUTHOR'S revision-1 hash. If it holds the stale 111111 " ..
			"the delivery did not correct it; if it holds anything else it minted its own opinion " ..
			"of the sender's data, which is the recompute-on-receipt DeltaSync's rules forbid")
		assert.equal(AUTHOR_HASHV2, alt.inventoryHashV2,
			"the receiver did not store the AUTHOR'S revision-2 hash -- and revision 2 is what two " ..
			"migrated clients negotiate on, so this is the one that decides what overwrites what")

		-- AND THE INVERSE, which is the assertion that actually enforces the rule: the receiver must
		-- NOT hold what it would have computed itself. Without this the example still passes if a
		-- future change reinstates the recompute AND the author's hash happens to agree with it --
		-- which is the common case, since two honest clients usually do agree. Naming the wrong
		-- answer explicitly is what stops that regression hiding behind a coincidence.
		local localRecompute = TOGBankClassic_Core:ComputeInventoryHash(
			TOGBankClassic_Inventory_Store:GetAltView(GUILD, BANKER), nil, nil, 4242)
		assert.is_not.equal(localRecompute, alt.inventoryHashV2,
			"the receiver stored a hash it derived from its OWN view rather than the author's. " ..
			"That is recompute-on-receipt: it overwrites the author's statement about their own " ..
			"version, and once every client does it nobody is authoritative")
	end)

	-- HASH-CANON-001, the lossy-decode path. This is the answer to the objection the old
	-- recompute-on-receive code was built on: "a sender-supplied hash that disagrees with the
	-- stored rows produces a false in-sync state that silences future syncs while the data is
	-- wrong." The disagreement it feared can only arise when the decode DISCARDED a row, so the
	-- remedy is to notice the discard -- not to mint a different number that hides it.
	--
	-- A receiver that dropped rows does not hold the author's version, so it must not claim the
	-- author's hash. Publishing nothing gets it re-requested; publishing a number it cannot
	-- reproduce is how a sync goes quiet while wrong.
	it("refuses the author's canon when the decode DROPPED rows, rather than claiming a version it does not hold", function()
		env.reset()
		loadClient(PEER)

		TOGBankClassic_Guild.Info.alts[BANKER] = {
			name = BANKER, items = {}, money = 0,
			inventoryHash = 111111, inventoryHashV2 = env.canon(1700000000, 222222),
		}

		-- Hand-build a payload carrying one GOOD row and one MALFORMED one. Record.new rejects a
		-- zero count, so decodeV2 keeps the first and drops the second -- the receiver ends up
		-- holding strictly less than the author sent, which is exactly the case in question.
		local payload = {
			TOGBankClassic_Inventory_Wire.VERSION, BANKER, 4242,
			{ { 858, 5 }, { 10132, 0 } },
			777777, env.canon(1757000000, 888888), 1757000000,
		}
		local body = TOGBankClassic_Core:SerializeWithChecksum(payload)

		TOGBankClassic_Chat:OnCommReceived("togbank-d4", body, "WHISPER", BANKER)

		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		assert.is_nil(alt.inventoryHashV2,
			"the receiver stored the author's revision-2 hash after DROPPING a row -- it is now " ..
			"advertising a version it does not hold, so every peer comparing against it concludes " ..
			"they are in sync when they are not")
		assert.is_nil(alt.inventoryHash,
			"same for revision 1: a partial record must publish NO canon, not half of one")

		-- The good row must still land. Refusing the canon is not refusing the data -- dropping
		-- both would lose an item the author really has and turn a reporting problem into a
		-- data-loss one.
		local Record = TOGBankClassic_Inventory_Record
		local got = {}
		for _, rec in ipairs(TOGBankClassic_Inventory_Store:GetAltRecords(GUILD, BANKER)) do
			got[Record.key(rec)] = Record.count(rec)
		end
		assert.equal(5, got["858:0:0"],
			"the valid row was discarded along with the malformed one -- refusing the CANON must " ..
			"not mean refusing the CONTENT")
	end)

	-- HASH-CANON-002: `togbank-nochange` MUST NOT TOUCH STORED CANON.
	--
	-- THESE SPECS REPLACE FOUR THAT ASSERTED THE OPPOSITE, and the reason is worth keeping because
	-- the old ones were green, careful, and pinning a live data-loss bug. They asserted that a
	-- no-change message's `hash` / `hashV2` were ADOPTED into the receiver's record, on the reasoning
	-- that "the sender only reaches this path if our baseline matched their items, so their hash IS
	-- correct for our data". That argues the DATA matched. It says nothing about how the sender's
	-- NUMBER was produced.
	--
	-- ANY PEER HOLDING A COPY ANSWERS A STATE SUMMARY (`Guild:RespondToStateSummary`), not just the
	-- banker who authored it. So adoption let a hash minted by a non-author travel: peer A writes a
	-- number, B stores it as its own, B then serves it to C. Reported from a live guild -- the banker
	-- logged off and a mutated revision-1 hash arrived from somebody else and overwrote good V2 data.
	--
	-- THE RULE NOW: a hash is written ONCE, by the client that scanned the bank, and carried
	-- unchanged by everyone else. A no-change says "your version is current" and nothing more.
	-- Re-baselining the old assertions was not an option -- the behaviour they described is gone.
	local function noChangeFrom(sender, hash, hashV2)
		local msg = {
			type = "no-change",
			name = BANKER,
			version = 999,
			hash = hash,
			hashV2 = hashV2,
			mailHash = 0,
		}
		local body = TOGBankClassic_Core:SerializeWithChecksum(msg)
		TOGBankClassic_Chat:OnCommReceived("togbank-nochange", body, "WHISPER", sender)
	end

	-- THE CENTRAL ONE. Everything else in this block is a variation on it.
	it("does NOT adopt hashes from a no-change, even when the sender is the banker itself", function()
		TOGBankClassic_Guild.Info.alts[BANKER] = {
			name = BANKER, items = {}, money = 0,
			inventoryHash = 111, inventoryHashV2 = 222,
		}

		noChangeFrom(BANKER, 777, 888)

		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		assert.equal(111, alt.inventoryHash,
			"a no-change message rewrote our stored revision-1 hash. A hash is the identity of a " ..
			"version and is written once, by the client that scanned the bank -- a message saying " ..
			"'you are current' is not an authoring event")
		assert.equal(222, alt.inventoryHashV2,
			"a no-change message rewrote our stored revision-2 hash")
	end)

	-- The sender being the alt's own banker does not make it an authoring event either, which is
	-- why the case above uses BANKER. This one is the shape that actually did the damage: ANY peer
	-- holding a copy answers a state summary, so a relayer's number used to become our stored truth.
	it("does NOT adopt hashes from a RELAYING PEER that is not the alt at all", function()
		TOGBankClassic_Guild.Info.alts[BANKER] = {
			name = BANKER, items = {}, money = 0,
			inventoryHash = 111, inventoryHashV2 = 222,
		}

		noChangeFrom("Someoneelse-Azuresong", 777, 888)

		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		assert.equal(111, alt.inventoryHash,
			"a peer that merely holds a copy of this banker's data rewrote our canon for it -- this " ..
			"is the live bug: the banker logged off, a mutated hash arrived from somebody else, and " ..
			"it overwrote good data")
		assert.equal(222, alt.inventoryHashV2)
	end)

	-- A record with NO revision-2 hash is the tempting case, because adoption is the only way it can
	-- ever acquire one for a remote alt this client never scans. It still must not adopt: a hash
	-- nobody authored for this client is not better than no hash. No canon advertises no canon, and
	-- the alt is re-requested from the client that can actually author one.
	it("does NOT fill in a missing revision 2 from a no-change", function()
		env.reset()
		loadClient(PEER)
		TOGBankClassic_Guild.Info.alts[BANKER] = {
			name = BANKER, items = {}, money = 0,
			inventoryHash = 111, -- revision 1 only
		}

		noChangeFrom(BANKER, 777, 888)

		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		assert.equal(111, alt.inventoryHash)
		assert.is_nil(alt.inventoryHashV2,
			"a revision-2 hash was invented for this record from a message that only said 'you are " ..
			"current' -- no scan produced it and no author stands behind it")
	end)

	-- Slot counts are DISPLAY data with no bearing on version identity, so a peer passing one along
	-- cannot make two clients disagree about which version they hold. They are still applied, and
	-- asserting that here is what stops the fix above being over-applied into deleting the handler.
	it("still applies slot counts, which carry no version identity", function()
		TOGBankClassic_Guild.Info.alts[BANKER] = {
			name = BANKER, items = {}, money = 0,
			inventoryHash = 111, inventoryHashV2 = 222,
		}

		local msg = {
			type = "no-change", name = BANKER, version = 999,
			bankSlots = { count = 12, total = 28 },
		}
		TOGBankClassic_Chat:OnCommReceived("togbank-nochange",
			TOGBankClassic_Core:SerializeWithChecksum(msg), "WHISPER", BANKER)

		local alt = TOGBankClassic_Guild.Info.alts[BANKER]
		assert.is_table(alt.bank and alt.bank.slots, "slot counts stopped being applied")
		assert.equal(12, alt.bank.slots.count)
	end)

	-- THE SEND SIDE, because refusing them on receive is only half the fix: an older client still
	-- adopts whatever arrives, so continuing to publish a hash we may not have authored would keep
	-- feeding the same loop from the other end.
	it("publishes NO hashes on a no-change it sends", function()
		local sent
		TOGBankClassic_Core.SendWhisper = function(_, prefix, body)
			if prefix == "togbank-nochange" then
				local _, decoded = TOGBankClassic_Core:DeserializeWithChecksum(body, {})
				sent = decoded
			end
			return true
		end

		TOGBankClassic_Guild.Info.alts[BANKER] = {
			name = BANKER, items = {}, money = 0, version = 999,
			inventoryHash = 111, inventoryHashV2 = 222, mailHash = 0,
			bank = { items = {}, slots = { count = 1, total = 28 } },
		}
		-- HASH-CANON-010: the requester holds OUR canon (same publish, same number), which is what
		-- earns a no-change now. This summary used to carry revision 1 only, and the responder used
		-- to call that "current" -- the exact gate that swallowed Alchemyrcp's canon on the live
		-- guild. A requester with no canon is now sent the data; see Tests/statesummary_spec.lua.
		TOGBankClassic_Guild:RespondToStateSummary(BANKER, {
			name = BANKER, hash = 111, hashV2 = 222, updatedAt = 999, mailHash = 0, version = 999,
		}, PEER)

		-- Asserted, not guarded with `if sent then`: a no-change that was never sent would make every
		-- assertion below vacuous and the example would pass while testing nothing.
		assert.is_table(sent,
			"RespondToStateSummary did not send a no-change, so this example proves nothing about " ..
			"what a no-change carries -- fix the fixture rather than letting it pass")
		assert.is_nil(sent.hash,
			"a no-change still carried a revision-1 hash -- an older client will adopt it, so " ..
			"publishing one keeps the mutation loop alive from the sending end")
		assert.is_nil(sent.hashV2, "a no-change still carried a revision-2 hash")
		assert.is_nil(sent.mailHash, "a no-change still carried a mail hash")
	end)

	-- A no-change correction is a statement ABOUT a record, not a way to create one. Fabricating one
	-- here would produce an alt carrying hashes and no items, which every reader would treat as a
	-- banker whose bank is genuinely empty.
	it("does not fabricate a record for an alt it does not hold", function()
		env.reset()
		loadClient(PEER)
		assert.is_nil(TOGBankClassic_Guild.Info.alts[BANKER],
			"precondition: the record already existed, so the assertion below proves nothing")

		noChangeFrom(BANKER, 777, 888)

		assert.is_nil(TOGBankClassic_Guild.Info.alts[BANKER],
			"a no-change correction created an alt record from nothing -- it now reads as a banker " ..
			"holding no items at all")
	end)
end)
