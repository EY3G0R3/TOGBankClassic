-- HASH-CANON-007: `/togbank dev hashdump` must show the CANON.
--
-- The operator, 2026-09-10, with a banker just re-published on the new format: "galdof should have
-- gotten the new v2 hash, is there a / command i can use to see if he did?" There was not. The
-- command that exists for exactly this printed only the revision-1 numbers, after the canon had
-- become the field that decides every verdict -- so the one diagnostic for "did the new version
-- arrive?" could not answer it, and the answer had to be "hover the tab".
--
-- Driven through ChatCommand with the text a player types (CMD-001), against the real Guild and
-- DeltaComms, asserting on what reaches chat.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local ME     = "Bankchar-Testrealm"
local OTHER  = "Otherbanker-Testrealm"
local GUILD  = "Testguild"
local C      = env.canon
local T      = 1757000000

local function loadAll()
	env.stubOutput()
	env.loadModules({ "Modules/Constants.lua", "Modules/Item.lua", "Modules/DeltaComms.lua",
		"Modules/Bank.lua", "Modules/Guild.lua", "Modules/Switches.lua", "Modules/Chat.lua" })
	env.stubCore()
	TOGBankClassic_Database = { db = { global = {} } }
	env.freshV2()
	local Guild = TOGBankClassic_Guild
	Guild.Info = { name = GUILD, alts = {} }
	Guild.IsBank = function(_, n) return n == ME or n == OTHER end
	Guild.newestAdvertisedAt = {}
	Guild.latestBankerHashes = {}
	return Guild
end

--- INV2-RETIRE-003: "we hold OTHER" means the V2 store holds records for it; the record itself
--- carries only the version metadata the dump prints.
local function holdOther(fields)
	local alt = { name = OTHER }
	for k, v in pairs(fields) do alt[k] = v end
	TOGBankClassic_Guild.Info.alts[OTHER] = alt
	env.holdV2(GUILD, OTHER)
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

describe("HASH-CANON-007: /togbank dev hashdump shows the canon", function()
	local Guild

	before_each(function()
		env.reset()
		Guild = loadAll()
	end)

	it("prints the held canon and the known canon, with the publish time readable", function()
		holdOther({ inventoryHash = 7, inventoryHashV2 = C(T, 5) })
		Guild.latestBankerHashes[OTHER] = { hash = 7, hashV2 = C(T + 60, 9), updatedAt = T + 60, mailHash = 0 }

		TOGBankClassic_Chat:ChatCommand("dev hashdump")

		local text = responses()
		assert.truthy(text:find(C(T, 5):sub(11), 1, true),
			"the canon we hold is not printed -- the command still shows only revision-1 numbers, " ..
			"so it cannot answer whether a banker's new version arrived (HASH-CANON-007)")
		assert.truthy(text:find(C(T + 60, 9):sub(11), 1, true), "the canon a peer advertised is not printed")
		assert.truthy(text:find(date("%Y-%m-%d %H:%M:%S", T), 1, true),
			"the publish time is not shown as a date; a bare 10-digit prefix is not readable in chat")
	end)

	it("names the tab state beside the canon, so this line and the tab colour cannot silently disagree", function()
		holdOther({ inventoryHash = 7, inventoryHashV2 = C(T, 5) })
		Guild.latestBankerHashes[OTHER] = { hash = 7, hashV2 = C(T + 60, 9), updatedAt = T + 60, mailHash = 0 }
		Guild.newestAdvertisedAt[OTHER] = T + 60

		TOGBankClassic_Chat:ChatCommand("dev hashdump")
		assert.truthy(responses():find("[behind]", 1, true))
	end)

	it("shows '-' for a missing canon and 'v1' for the state -- the Galdof/Alchemyrcp case", function()
		holdOther({ inventoryHash = 7 })
		Guild.latestBankerHashes[OTHER] = { hash = 7, hashV2 = C(T, 9), updatedAt = T, mailHash = 0 }

		TOGBankClassic_Chat:ChatCommand("dev hashdump")
		local text = responses()
		assert.truthy(text:find("[v1]", 1, true))
		assert.truthy(text:find("local=- ", 1, true), "a missing canon must read as absent, not as 0")
	end)

	-- P2P-035 / self-audit A1. The verdict is the request rule's (AdvertisedImproves), not
	-- HashesAgreeWith: an entry learned from a NUMBERED broadcast carries no mail hash, and
	-- HashesAgreeWith fails closed on a missing mail hash -- so under the old verdict every such
	-- entry printed MISMATCH while nothing was pending. Reverting the command to HashesAgreeWith
	-- reddens exactly this example.
	it("prints OK for the same version learned from a numbered broadcast, which carries no mail hash", function()
		holdOther({ inventoryHash = 7, inventoryHashV2 = C(T, 5), mailHash = 3 })
		Guild.latestBankerHashes[OTHER] = { hashV2 = C(T, 5), updatedAt = T }   -- as BN:EntriesToAlts shapes it

		TOGBankClassic_Chat:ChatCommand("dev hashdump")
		local text = responses()
		assert.truthy(text:find("OK|r " .. OTHER, 1, true),
			"the same version reads as MISMATCH because the diagnostic asks HashesAgreeWith, " ..
			"which fails closed on the mail hash a numbered broadcast does not carry")
		assert.is_false(Guild:IsAltSyncPending(OTHER), "and the thing it diagnoses agrees")
	end)

	-- P2P-029: "put a / command in so we can see the queue data".
	it("/togbank dev sendqueue shows slots in use, the queue with positions, and our sessions", function()
		env.loadModules({ "Modules/P2PSession.lua" })
		local P2P = TOGBankClassic_P2PSession
		P2P.activeSends, P2P.sendQueue, P2P.sessions, P2P.stateWaits = {}, {}, {}, {}
		P2P.activeSessions, P2P.pendingDispatch = 0, {}
		P2P:TryAcquireSendSlot("Busyguy-Testrealm")
		P2P:EnqueueSend("sid9", "Waiter-Testrealm", OTHER)
		P2P.sessions["s1"] = { sessionId = "s1", altName = OTHER, state = "DISPATCHED", peer = "Peer-Testrealm",
			candidates = { { peer = "Peer-Testrealm" } }, triedPeers = { ["Peer-Testrealm"] = true }, timers = {} }

		TOGBankClassic_Chat:ChatCommand("dev sendqueue")

		local text = responses()
		assert.truthy(text:find("1/3 in use", 1, true), "slot usage not shown: " .. text)
		assert.truthy(text:find("Busyguy-Testrealm x1", 1, true))
		assert.truthy(text:find("#1 Waiter-Testrealm wants " .. OTHER, 1, true), "queue entry not shown: " .. text)
		assert.truthy(text:find(OTHER .. " <- Peer-Testrealm [DISPATCHED]", 1, true), "our session not shown: " .. text)
	end)

	it("shows a v1.4.0 numeric canon as the bare number rather than inventing a date for it", function()
		holdOther({ inventoryHash = 7, inventoryHashV2 = 424242 })
		Guild.latestBankerHashes[OTHER] = { hash = 7, mailHash = 0 }

		TOGBankClassic_Chat:ChatCommand("dev hashdump")
		assert.truthy(responses():find("local=424242 ", 1, true))
	end)
end)
