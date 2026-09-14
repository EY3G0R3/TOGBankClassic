-- `/togbank dev trace <banker>` -- the P2P-035 follow-up Peer Review asked for: one alt walked
-- through every gate, printing the first that says no with its inputs.
--
-- Driven through ChatCommand with the text a player types (CMD-001), on a WHOLE client (real Store,
-- real P2PSession, real Guild), asserting on what reaches chat. The command must call the
-- production predicates rather than copy them, so the examples set up real state -- tuple records
-- in the V2 store, a canon on the record, an advertised summary -- and read the verdicts back.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local C = env.canon
local T = 1757000000
local GUILD = "Testguild"
local BANKER, OTHER, PEER = "Bankchar-Testrealm", "Otherbanker-Testrealm", "Otherguy-Testrealm"

local function client(who)
	env.standUpClient(who, {
		{ name = BANKER, note = "gbank" }, { name = OTHER, note = "gbank" }, { name = PEER },
	}, GUILD)
	env.stubCore()
	TOGBankClassic_Core.SendWhisper = function() return true end
	TOGBankClassic_Core.SendCommMessage = function() end
end

--- Everything the command printed through Output:Response, joined.
local function responses()
	local out = {}
	for _, call in ipairs(TOGBankClassic_Output.calls) do
		if call.level == "Response" then
			out[#out + 1] = string.format(call[1], select(2, unpack(call, 1, call.n)))
		end
	end
	return table.concat(out, "\n")
end

describe("/togbank dev trace", function()
	before_each(function() env.reset(); client("Otherguy") end)

	it("is a dev command that needs a name", function()
		TOGBankClassic_Chat:ChatCommand("dev trace")
		assert.truthy(responses():find("Usage: /togbank dev trace", 1, true))
	end)

	-- INV2-RETIRE-003: this was "for a banker we hold only legacy rows for". There are no legacy rows
	-- any more; the case is a record (a hash-list stub, say) with NO tuples in the store.
	it("stops at CanServe for a banker whose record has no tuples behind it, and says why", function()
		TOGBankClassic_Guild.Info.alts[OTHER] = { name = OTHER, money = 0,
			inventoryHash = 1, inventoryHashV2 = C(T, 7), inventoryUpdatedAt = T }
		TOGBankClassic_Chat:ChatCommand("dev trace Otherbanker")
		local text = responses()
		assert.truthy(text:find("1. banker on the roster: |cff00ff00yes|r", 1, true), "did not identify the banker")
		assert.truthy(text:find("record held: |cff00ff00yes|r  V2 tuples=0", 1, true), "the inputs to the record gate are not printed")
		assert.truthy(text:find("3. CanServe (V2 tuples > 0, SendAltData's own test): |cffff4444NO|r", 1, true))
		assert.truthy(text:find("STOP:", 1, true), "the first refusing gate was not named")
		assert.truthy(text:find("only a rescan by the banker or a delivery fills the V2 store", 1, true), "the remedy for tuple-less content is not stated")
		assert.is_nil(text:find("4. ServableCanon", 1, true), "walked past the gate that said no")
	end)

	it("walks every serving gate green for a banker we hold tuples and a canon for", function()
		TOGBankClassic_Guild.Info.alts[OTHER] = { name = OTHER, money = 0,
			inventoryHash = 1, inventoryHashV2 = C(T, 7), inventoryUpdatedAt = T }
		TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, OTHER, { TOGBankClassic_Inventory_Record.new(858, 5) }, 0)
		TOGBankClassic_Chat:ChatCommand("dev trace Otherbanker")
		local text = responses()
		assert.truthy(text:find("3. CanServe (V2 tuples > 0, SendAltData's own test): |cff00ff00yes|r", 1, true))
		assert.truthy(text:find("4. ServableCanon: |cff00ff00yes|r", 1, true))
		assert.truthy(text:find(date("%Y-%m-%d %H:%M:%S", T), 1, true), "the held canon's publish time is not readable")
		assert.truthy(text:find("5. send slot: |cff00ff00yes|r  0/3 in use", 1, true))
		assert.truthy(text:find("6. state-wait: none open for this alt", 1, true))
		assert.is_nil(text:find("STOP:", 1, true))
	end)

	it("reports the fetching side: tab state and the AdvertisedImproves verdict with its reason", function()
		TOGBankClassic_Guild.Info.alts[OTHER] = { name = OTHER, money = 0,
			inventoryHash = 1, inventoryHashV2 = C(T, 7), inventoryUpdatedAt = T }
		env.holdV2(GUILD, OTHER, { { 858, 5 } })   -- INV2-RETIRE-003: 'behind' needs held content
		-- Seeded by Init at +1.5s in the client; standUpClient does not run Init.
		TOGBankClassic_Guild.latestBankerHashes = { [OTHER] = { hash = 1, hashV2 = C(T + 60, 9), updatedAt = T + 60, mailHash = 0 } }
		assert.is_true(TOGBankClassic_Guild:NoteAdvertisedPublishTime(OTHER, TOGBankClassic_Guild.latestBankerHashes[OTHER]),
			"precondition: the newer publish time was not recorded")
		TOGBankClassic_Chat:ChatCommand("dev trace Otherbanker")
		local text = responses()
		assert.truthy(text:find("tab state: behind", 1, true), "the tab state is not the one GetAltStaleness gives")
		assert.truthy(text:find("AdvertisedImproves=|cff00ff00yes|r (newer)", 1, true), "the verdict and its reason are not printed")
		assert.truthy(text:find("session: none", 1, true))
	end)

	-- CLAIM-TRACE-001: a red tab says "somebody has newer than you" and nothing could name the
	-- somebody. On 2026-09-12 a banker sat behind a version its own author never published and the
	-- only way to chase it was reading SavedVariables off disk -- which produced a mechanism and
	-- still could not name the peer. These two lines are what makes it a one-command question.
	it("names WHO claimed the newer version, and the canon they claimed", function()
		TOGBankClassic_Guild.Info.alts[OTHER] = { name = OTHER, money = 0,
			inventoryHash = 1, inventoryHashV2 = C(T, 7), inventoryUpdatedAt = T }
		env.holdV2(GUILD, OTHER, { { 858, 5 } })
		assert.is_true(TOGBankClassic_Guild:NoteAdvertisedPublishTime(OTHER,
			{ hash = 1, hashV2 = C(T + 60, 9), updatedAt = T + 60 }, "Claimant-Testrealm"),
			"precondition: the newer publish time was not recorded")
		TOGBankClassic_Chat:ChatCommand("dev trace Otherbanker")
		local text = responses()
		assert.truthy(text:find("claimed by: Claimant-Testrealm", 1, true),
			"the trace does not name the peer whose claim is holding the tab red:\n" .. text)
		assert.truthy(text:find("canon=" .. date("%Y-%m-%d %H:%M:%S", T + 60), 1, true),
			"the claimed canon is not printed, so a phantom publish time cannot be spotted")
	end)

	it("says so plainly when nobody has claimed anything, rather than printing a blank", function()
		TOGBankClassic_Guild.Info.alts[OTHER] = { name = OTHER, money = 0,
			inventoryHash = 1, inventoryHashV2 = C(T, 7), inventoryUpdatedAt = T }
		env.holdV2(GUILD, OTHER, { { 858, 5 } })
		TOGBankClassic_Chat:ChatCommand("dev trace Otherbanker")
		assert.truthy(responses():find("claimed by: nobody has named a version", 1, true))
	end)

	it("raises the time even when the caller cannot say who -- unattributed, never dropped", function()
		-- Every raise still moves the tab; attribution is a diagnostic, not a gate.
		assert.is_true(TOGBankClassic_Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T + 60, 9) }))
		assert.equal(T + 60, TOGBankClassic_Guild.newestAdvertisedAt[OTHER])
		assert.is_nil(TOGBankClassic_Guild.newestAdvertisedBy[OTHER].peer)
		assert.equal(C(T + 60, 9), TOGBankClassic_Guild.newestAdvertisedBy[OTHER].canon)
	end)

	it("keeps the claimant of the NEWEST version, not the latest message", function()
		TOGBankClassic_Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T + 60, 9) }, "First-Testrealm")
		-- An older claim arriving later must not overwrite it: the raise is what records the peer.
		assert.is_false(TOGBankClassic_Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T + 10, 9) }, "Older-Testrealm"))
		assert.equal("First-Testrealm", TOGBankClassic_Guild.newestAdvertisedBy[OTHER].peer)
		TOGBankClassic_Guild:NoteAdvertisedPublishTime(OTHER, { hashV2 = C(T + 90, 9) }, "Newer-Testrealm")
		assert.equal("Newer-Testrealm", TOGBankClassic_Guild.newestAdvertisedBy[OTHER].peer)
	end)

	it("shows a live fetch session with the version the request names", function()
		TOGBankClassic_Guild.Info.alts[OTHER] = { name = OTHER, money = 0 }
		local P2P = TOGBankClassic_P2PSession
		P2P.sessions["sid1"] = { sessionId = "sid1", altName = OTHER, state = "DISPATCHED", peer = BANKER,
			candidates = { { peer = BANKER, canon = C(T + 60, 9), updatedAt = T + 60 } }, triedPeers = { [BANKER] = true }, timers = {} }
		P2P.sessionsByAlt[OTHER] = "sid1"
		TOGBankClassic_Chat:ChatCommand("dev trace Otherbanker")
		local text = responses()
		assert.truthy(text:find("session: [DISPATCHED] peer=" .. BANKER .. " candidates=1 tried=1 wanted=" .. date("%Y-%m-%d %H:%M:%S", T + 60), 1, true),
			"the live session line is missing or names the wrong version:\n" .. text)
	end)
end)
