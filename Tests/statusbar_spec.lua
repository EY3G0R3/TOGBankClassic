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
