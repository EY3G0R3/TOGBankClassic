-- BROWSE-008: the Guild Bank window repaints when something it shows changes.
--
-- The operator, 2026-09-12, looking at the Bankers tab: "is there a refresh on the new banker tab
-- when something updates?" For DATA -- a claim raising a tab, a delivery landing, an offer cleared --
-- yes: every one of those goes through UI_Inventory:RefreshSoon, which fans out to the Guild Bank
-- window. Two sites bypassed it with a direct DrawContent (the hash-broadcast batch and the
-- collect-window dispatch), and NOTHING repainted on a roster change, so the Online column stayed
-- as it was when the window opened until some data signal happened along.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local OTHER  = "Newguy-Testrealm"
local GUILD  = "Testguild"

describe("BROWSE-008: repaint signals reach the Guild Bank window", function()
	local roster, calls

	before_each(function()
		env.reset()
		roster = env.standUpClient("Newguy", { { name = BANKER, note = "gbank" }, { name = OTHER } }, GUILD)
		calls = 0
		-- The fan-out point. What is under test is that these paths REACH it; what it does from
		-- there is Inventory.lua's own and is not re-proven here.
		TOGBankClassic_UI_Inventory = { isOpen = false, RefreshSoon = function() calls = calls + 1 end }
	end)

	describe("a banker's online state", function()
		it("repaints when a banker comes online or goes offline through the single-member update", function()
			assert.is_true(TOGBankClassic_Guild:IsPlayerOnline(BANKER), "precondition: the banker starts online")
			TOGBankClassic_Guild:UpdateOnlineMember(BANKER, false, "spec")
			assert.equal(1, calls, "a banker going offline did not repaint -- the Online column reads 'yes' until the next data signal")
			TOGBankClassic_Guild:UpdateOnlineMember(BANKER, true, "spec")
			assert.equal(2, calls, "a banker coming online did not repaint")
		end)

		it("does not repaint when nothing changed, nor for a member who is not a banker", function()
			TOGBankClassic_Guild:UpdateOnlineMember(BANKER, true, "spec")   -- already online
			assert.equal(0, calls, "a no-op online mark repainted -- this runs for EVERY inbound message")
			TOGBankClassic_Guild:UpdateOnlineMember(OTHER, false, "spec")
			TOGBankClassic_Guild:UpdateOnlineMember(OTHER, true, "spec")
			assert.equal(0, calls, "a non-banker's presence repainted a window that shows nothing about them")
		end)

		-- ONLINE-COL-001 (Peer Review bee7f23f F1): the offline update carries no realm (the system
		-- message never does) and matches by BASE name across realm variants -- so a connected-realm
		-- banker's offline can arrive under a name IsBank does not know, and the repaint was gated on it.
		it("repaints when a CONNECTED-REALM banker goes offline under a bare name the roster keys with its own realm", function()
			local far = "Farbank-Otherrealm"
			TOGBankClassic_Guild.memberRoster[far] = { name = far, isOnline = true, isBank = true, class = "Mage", level = 60, note = "gbank" }
			TOGBankClassic_Guild.onlineMembers[far] = true
			local isBank = TOGBankClassic_Guild.IsBank
			TOGBankClassic_Guild.IsBank = function(self, n) return n == far or isBank(self, n) end
			assert.is_false(TOGBankClassic_Guild:IsBank("Farbank-Testrealm"), "precondition: the bare name normalises to a realm the banker is not on")
			TOGBankClassic_Guild:UpdateOnlineMember("Farbank", false, "spec")   -- "Farbank has gone offline."
			assert.is_false(TOGBankClassic_Guild.memberRoster[far].isOnline, "precondition: the base-name match marked the banker offline")
			assert.equal(1, calls, "a connected-realm banker going offline did not repaint")
			TOGBankClassic_Guild.IsBank = isBank
		end)

		it("repaints when the roster refresh finds a banker's state changed, and only then", function()
			TOGBankClassic_Guild:RefreshOnlineCache()
			assert.equal(0, calls, "a roster refresh with no change repainted -- that is every ten seconds in a busy guild")
			env.fireGuildRosterEvent(roster, "CHAT_MSG_SYSTEM", "Bankchar has gone offline.")
			TOGBankClassic_Guild:RefreshOnlineCache()
			assert.is_false(TOGBankClassic_Guild:IsPlayerOnline(BANKER), "precondition: the refresh must have seen the banker go offline")
			assert.equal(1, calls, "the roster refresh saw a banker go offline and repainted nothing")
			TOGBankClassic_Guild:RefreshOnlineCache()
			assert.equal(1, calls)
		end)
	end)

	describe("the two sites that used to repaint the Inventory window directly", function()
		it("the hash-broadcast batch goes through the fan-out", function()
			TOGBankClassic_Chat.hashBroadcastQueue = { { sender = OTHER, data = { alts = {} }, distribution = "GUILD", isSenderBanker = false, altCount = 0 } }
			TOGBankClassic_Chat:ProcessQueuedHashBroadcasts()
			assert.equal(1, calls, "the broadcast batch repainted the old window only")
		end)

		it("the collect-window dispatch goes through the fan-out", function()
			local P2P = TOGBankClassic_P2PSession
			P2P.offers, P2P.isCollecting = {}, true
			P2P:Dispatch()
			-- Dispatch with no offers still ends the cycle and repaints. (Nothing is asserted about
			-- what it dispatched: the fan-out is the subject.)
			assert.equal(0, calls, "precondition: no-offer dispatch returns before the repaint; this example needs an offer")
			TOGBankClassic_Guild:NotePeerAddonVersion(OTHER, "TOGBankClassic-v1.5.0")
			P2P.offers = { [BANKER] = { { peer = OTHER, updatedAt = 1, hash = 0, mailHash = 0 } } }
			P2P.isCollecting = true
			P2P:Dispatch()
			assert.is_true(calls >= 1, "the dispatch repainted the old window only")
		end)
	end)
end)
