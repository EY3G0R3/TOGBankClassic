-- P2P-025 — the status bar's "sends in flight" indicator, and the counter it reads.
--
-- WHY THIS FILE EXISTS:
--
-- NetTxText read TOGBankClassic_Guild.pendingSendCount. Four sites DECREMENT that counter and
-- nothing anywhere increments it, so it sat at 0 for the life of every session -- and NetTxText
-- returns "" the moment it reads 0. The indicator could therefore never appear, at any load, and
-- the failure is invisible by construction: an empty string is exactly what "no sends in flight"
-- is supposed to look like.
--
-- That is the same shape as the four findings on docs/AUDIT.md that preceded it -- a mechanism
-- that cannot run -- and it survived because nothing asserted the indicator ever renders. So the
-- assertions below drive the RENDERING path with sends actually in flight, rather than checking
-- that the function exists or that it returns "" when idle (which it did, correctly, throughout).
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function loadStatusBar()
	env.stubOutput()
	env.loadFile("Modules/Constants.lua")
	TOGBankClassic_Guild = { MAX_PENDING_SENDS = 3 }
	TOGBankClassic_P2PSession = {
		activeSends = {},
		GetActiveSendTotal = function(self)
			local total = 0
			for _, c in pairs(self.activeSends) do total = total + c end
			return total
		end,
	}
	env.loadFile("Modules/UI/StatusBar.lua")
	return TOGBankClassic_UI_StatusBar
end

describe("StatusBar.NetTxText", function()
	local SB
	before_each(function() env.reset(); SB = loadStatusBar() end)

	it("renders nothing when no send is in flight", function()
		assert.equal("", SB.NetTxText())
	end)

	-- The assertion the old implementation could not satisfy at any input.
	it("renders the count once a send is in flight", function()
		TOGBankClassic_P2PSession.activeSends = { Requester = 1 }
		local text = SB.NetTxText()
		assert.is_not_nil(text:find("Tx:1/3", 1, true),
			"the indicator did not render with a send in flight -- it read a counter that nothing " ..
			"increments, so it was pinned at 0 and the `sends == 0` early return fired every time " ..
			"(P2P-025). Got: " .. string.format("%q", text))
	end)

	it("sums sends across every requester, as the cap does", function()
		TOGBankClassic_P2PSession.activeSends = { A = 1, B = 2 }
		assert.is_not_nil(SB.NetTxText():find("Tx:3/3", 1, true))
	end)

	it("warns in red once the cap is reached", function()
		TOGBankClassic_P2PSession.activeSends = { A = 1 }
		assert.is_not_nil(SB.NetTxText():find("ffff9900", 1, true), "an under-cap send was not amber")
		TOGBankClassic_P2PSession.activeSends = { A = 3 }
		assert.is_not_nil(SB.NetTxText():find("ffff4444", 1, true), "at the cap the indicator was not red")
	end)

	-- The status bar is built during UI construction, which can beat P2PSession's file scope on a
	-- cold load. An indicator that errors takes the whole window with it.
	it("renders nothing rather than erroring before P2PSession exists", function()
		TOGBankClassic_P2PSession = nil
		assert.equal("", SB.NetTxText())
	end)
end)

-- STATUSBAR-COVERAGE-001 (Peer Review d0170ec1 item 3): the formatters and the other network parts
-- had no examples -- 84% of the file. Each is a pure function of its inputs, so each is driven at
-- its boundaries rather than merely called.
describe("StatusBar.FormatMoney", function()
	local SB
	before_each(function() env.reset(); SB = loadStatusBar() end)

	it("renders zero, nil and a negative amount as the grey 0c", function()
		assert.equal("|cff7f7f7f0c|r", SB.FormatMoney(0))
		assert.equal("|cff7f7f7f0c|r", SB.FormatMoney(nil))
		assert.equal("|cff7f7f7f0c|r", SB.FormatMoney(-5))
	end)

	it("shows only the denominations that carry, and always the copper when nothing above it does", function()
		assert.equal("|cffb46a2f42c|r", SB.FormatMoney(42))
		assert.equal("|cffc0c0c03s|r", SB.FormatMoney(300), "a whole-silver amount showed a 0c tail")
		assert.equal("|cffc0c0c03s|r |cffb46a2f7c|r", SB.FormatMoney(307))
	end)

	it("shows the silver beside any gold even when it is zero, and skips a zero copper", function()
		assert.equal("|cffFFD7002g|r |cffc0c0c00s|r", SB.FormatMoney(20000))
		assert.equal("|cffFFD7002g|r |cffc0c0c05s|r |cffb46a2f9c|r", SB.FormatMoney(20509))
	end)
end)

describe("StatusBar.GetSlotColor / FormatSlots", function()
	local SB
	before_each(function() env.reset(); SB = loadStatusBar() end)

	it("steps white, green, yellow, orange, red at 25 / 50 / 75 / 90 percent, each bound inclusive", function()
		assert.equal("ffffffff", SB.GetSlotColor(0))
		assert.equal("ffffffff", SB.GetSlotColor(0.25))
		assert.equal("ff00ff00", SB.GetSlotColor(0.26))
		assert.equal("ff00ff00", SB.GetSlotColor(0.5))
		assert.equal("ffffff00", SB.GetSlotColor(0.75))
		assert.equal("ffff9900", SB.GetSlotColor(0.9))
		assert.equal("ffff0000", SB.GetSlotColor(0.91))
		assert.equal("ffff0000", SB.GetSlotColor(1))
	end)

	it("colours used/total by the fill, and treats an empty total as empty rather than dividing by zero", function()
		assert.equal("|cffff000095/100|r", SB.FormatSlots(95, 100))
		assert.equal("|cffffffff0/0|r", SB.FormatSlots(0, 0))
	end)
end)

describe("StatusBar.BuildInventorySummary", function()
	local SB
	before_each(function()
		env.reset(); SB = loadStatusBar()
		TOGBankClassic_Guild.NormalizeName = function(_, n) return n end
	end)

	it("sums money and bank + bag slots over the roster, skipping alts with no record or no slot data", function()
		local info = { alts = {
			A = { money = 10000, bank = { slots = { count = 10, total = 24 } }, bags = { slots = { count = 5, total = 16 } } },
			B = { money = 300, bags = { slots = { count = 1, total = 4 } } },
			C = "not a table",
		} }
		local text = SB.BuildInventorySummary(info, { "A", "B", "C", "D" })
		assert.equal(SB.FormatMoney(10300) .. "    " .. SB.FormatSlots(16, 44), text)
	end)

	it("is the grey 0c and 0/0 for an empty roster", function()
		assert.equal(SB.FormatMoney(0) .. "    " .. SB.FormatSlots(0, 0), SB.BuildInventorySummary({ alts = {} }, {}))
	end)
end)

describe("StatusBar.BuildAltDetail", function()
	local SB, mailRecords, mailAge
	before_each(function()
		env.reset(); SB = loadStatusBar()
		TOGBankClassic_Guild.Info = { name = "Testguild" }
		mailRecords, mailAge = {}, nil
		TOGBankClassic_Inventory_Store = { GetAltSourceRecords = function(_, guild, name, source)
			assert.equal("Testguild", guild); assert.equal("mail", source)
			return name == "Alt-Realm" and mailRecords or {}
		end }
		TOGBankClassic_MailInventory = { GetMailDataAge = function() return mailAge end }
		-- SecondsToTime is Blizzard_SharedXML/TimeUtil.lua:309; the harness does not model it.
		_G.SecondsToTime = function(s) return s .. " Sec" end
	end)

	it("says so for a missing record and for one that has never synced", function()
		assert.equal("No data available", SB.BuildAltDetail(nil, "Alt-Realm"))
		assert.equal("No data available", SB.BuildAltDetail("x", "Alt-Realm"))
		assert.equal("Waiting for sync...", SB.BuildAltDetail({}, "Alt-Realm"))
		assert.equal("Waiting for sync...", SB.BuildAltDetail({ version = 0 }, "Alt-Realm"))
	end)

	it("reads the version time, the money and the summed slots, with no mail part when the mail bucket is empty", function()
		local alt = { version = 1700000000, money = 20509,
			bank = { slots = { count = 10, total = 24 } }, bags = { slots = { count = 5, total = 16 } } }
		local text = SB.BuildAltDetail(alt, "Alt-Realm")
		assert.equal(("As of %s    %s    %s"):format(date("%Y-%m-%d %H:%M:%S", 1700000000), SB.FormatMoney(20509), SB.FormatSlots(15, 40)), text)
	end)

	it("counts the mail bucket's ROWS for the named alt, singular or plural, with the age when known -- and no mail for a nil name", function()
		local alt = { version = 1700000000 }
		mailRecords = { { 2589, 20 } }
		assert.truthy(SB.BuildAltDetail(alt, "Alt-Realm"):find("|cff87ceebMail: 1 item|r", 1, true))
		mailRecords, mailAge = { { 2589, 20 }, { 858, 5 } }, 90
		assert.truthy(SB.BuildAltDetail(alt, "Alt-Realm"):find("|cff87ceebMail: 2 items (90 Sec ago)|r", 1, true))
		assert.is_nil(SB.BuildAltDetail(alt, nil):find("Mail:", 1, true), "a nil name still read a mail bucket")
	end)
end)

describe("StatusBar network parts: Bcast, r:, Rx, Req", function()
	local SB
	before_each(function()
		env.reset(); SB = loadStatusBar()
		TOGBankClassic_Guild.GetQueriedRequestsCount = function() return 0 end
	end)

	it("Bcast is empty without a queue and shows its depth with one", function()
		TOGBankClassic_Chat = nil
		assert.equal("", SB.NetBcastText())
		TOGBankClassic_Chat = { sync_queue = {} }
		assert.equal("", SB.NetBcastText())
		TOGBankClassic_Chat.sync_queue = { 1, 2 }
		assert.equal("|cffffff00Bcast:2|r", SB.NetBcastText())
	end)

	it("r: is empty until an index handshake awaits ids, then counts the batch, or says ids before a batch exists", function()
		assert.equal("", SB.NetReqSyncText())
		TOGBankClassic_Guild.requestsIndexSync = { awaitingById = false }
		assert.equal("", SB.NetReqSyncText())
		TOGBankClassic_Guild.requestsIndexSync = { awaitingById = true }
		assert.equal("|cff87ceebr:ids|r", SB.NetReqSyncText())
		TOGBankClassic_Guild.requestsIndexSync = { awaitingById = true, batchTotal = 10, batchSent = 3 }
		assert.equal("|cff87ceebr:3/10|r", SB.NetReqSyncText())
		TOGBankClassic_Guild.requestsIndexSync = { awaitingById = true, batchTotal = 10 }
		assert.equal("|cff87ceebr:0/10|r", SB.NetReqSyncText(), "an unsent batch did not read as 0 sent")
	end)

	it("Rx counts the pending P2P fetches, empty when there are none", function()
		assert.equal("", SB.NetRxText())
		TOGBankClassic_Guild.pendingP2PRequests = {}
		assert.equal("", SB.NetRxText())
		TOGBankClassic_Guild.pendingP2PRequests = { A = { requestedAt = 0 }, B = { requestedAt = 0 } }
		assert.equal("|cff87ceebRx:2|r", SB.NetRxText())
	end)

	it("Req shows the queried-request count, empty at zero", function()
		assert.equal("", SB.NetQueriedReqText())
		TOGBankClassic_Guild.GetQueriedRequestsCount = function() return 5 end
		assert.equal("|cff98fb98Req:5|r", SB.NetQueriedReqText())
	end)
end)

describe("P2P-025: one source for the send total", function()
	before_each(function() env.reset() end)

	-- The cap is enforced against P2PSession's own accounting. A second counter that looks like the
	-- same number but is maintained elsewhere is how this defect happened, so the guard is that the
	-- status bar reads the live one and no other.
	it("does not read Guild.pendingSendCount, which nothing increments", function()
		local fh = assert(io.open("Modules/UI/StatusBar.lua", "rb"))
		local src = fh:read("*a"); fh:close()
		local _, body = src:find("function TOGBankClassic_UI_StatusBar.NetTxText", 1, true)
		assert.is_not_nil(body, "NetTxText was renamed -- this guard no longer covers anything")
		local fnEnd = src:find("\nend", body, true)
		local fn = src:sub(body, fnEnd)
		assert.is_nil(fn:find("pendingSendCount", 1, true),
			"NetTxText is reading Guild.pendingSendCount again. Four sites decrement it and none " ..
			"increment it, so it is always 0 and this indicator can never render (P2P-025)")
	end)

	-- The sum was hand-written at four call sites before P2P-025; each copy is a place the next
	-- change has to be remembered.
	it("has one implementation of the sum, on P2PSession", function()
		for _, path in ipairs({ "Modules/Chat.lua", "Modules/UI/StatusBar.lua" }) do
			local fh = assert(io.open(path, "rb"))
			local src = fh:read("*a"); fh:close()
			assert.is_nil(src:find("pairs(TOGBankClassic_P2PSession.activeSends)", 1, true),
				path .. " sums activeSends by hand instead of calling " ..
				"TOGBankClassic_P2PSession:GetActiveSendTotal() (P2P-025)")
		end
	end)
end)
