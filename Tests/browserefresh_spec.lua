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

	-- LIBREQ-DS-008: the two sites that used to repaint the Inventory window directly -- the
	-- hash-broadcast batch (Chat:ProcessQueuedHashBroadcasts) and the collect-window dispatch
	-- (P2PSession:Dispatch) -- no longer exist: both are the library's now, and the library repaints
	-- nothing itself. What repaints on the P2P path is TOGBank's hooks (Modules/P2P.lua Config):
	-- every claim the library reports through onAdvertised / onNewerOffered / onNewerCleared lands
	-- in Guild's Note* writers, which fan out through RefreshSoon. writ-cannot: the two examples that
	-- drove the deleted functions must not exist; these two drive the hooks that replaced them.
	describe("the P2P hooks the library reports through", function()
		local hooks
		before_each(function()
			env.loadModules({ "Modules/P2P.lua" })
			hooks = TOGBankClassic_P2P:Config()
			TOGBankClassic_Guild:NotePeerAddonVersion(OTHER, "TOGBankClassic-v" .. TOGBankClassic_Constants.PROTOCOL.DATA_LEG_MIN_ADDON_VERSION)
		end)

		it("a claim naming a newer version (onAdvertised) goes through the fan-out", function()
			hooks.onAdvertised(BANKER, env.canon(1757000000, 9), OTHER)
			assert.is_true(calls >= 1, "a peer's canon-bearing claim raised the tab and repainted nothing")
		end)

		it("a bare offer (onNewerOffered) and its clearing (onNewerCleared) go through the fan-out", function()
			hooks.onNewerOffered(BANKER, OTHER)
			assert.equal(1, calls, "the offer that turns the tab red repainted the old window only")
			hooks.onNewerCleared(BANKER)
			assert.equal(2, calls, "clearing the offer repainted nothing")
		end)
	end)
end)
