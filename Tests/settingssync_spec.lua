-- SETTINGS-CANON-001: THE OFFICER SETTINGS RIDE EVERY SYNC, ON WHOLE CLIENTS.
--
-- The operator, 2026-09-16: "we need to ensure the the request % is being synced and enforced. people
-- are still allowed to request more than what was set. the officer setting needs to be part of EVERY
-- sync. they should have a canon has as well and if someones is older, they need to pull the new
-- settings as part of their sync".
--
-- The field case, on the fleet: a member is OFFLINE when an officer (here the banker, which has the
-- same standing) lowers the maximum request %. Before this build the member logged in holding 100%
-- and kept it until some authorized client's ten-minute re-announcement happened to reach it -- and
-- its request dialog, the only place the limit was checked, enforced 100% meanwhile. Now the member's
-- own login broadcast names the settings it holds; the banker, holding newer ones, answers by whisper
-- on that sync; and Guild:AddRequest refuses the over-limit order. Run on both wires: the ordered bus
-- and the throttled one (the real AceCommQueue / AceComm / ChatThrottleLib per client, CONGESTION-001).
package.path = "./Tests/?.lua;" .. package.path
local F = require("env_fleet")

local BANK, VIEW = "Bankchar", "Viewer"

for _, wire in ipairs({ "ordered", "throttled" }) do
	describe("SETTINGS-CANON-001 on the " .. wire .. " wire: a member offline through the officer's change", function()
		it("logs in behind, is answered on ITS OWN login sync (not a later cycle), and cannot order past the new limit", function()
			local c = F.new({
				{ name = BANK, note = "gbank", client = true, money = 100 },
				{ name = VIEW, client = true },
			}, { wire = wire })
			local A, V = c[BANK], c[VIEW]
			F.scan(A, { { id = 2589, count = 40 } }, { bank = {}, money = 100 })
			F.login(A); F.tick(10)

			-- The member goes offline; the officer's write happens without it.
			F.offline(V)
			F.with(A, function()
				local G = A.G.TOGBankClassic_Guild
				G.Info.settings.maxRequestPercent = 25
				G:BroadcastSettings("ALERT")
			end)
			F.tick(10)
			local function limit(client)
				return F.with(client, function() return client.G.TOGBankClassic_Guild:MaxRequestPercent() end)
			end
			assert.equal(25, limit(A))
			assert.equal(100, limit(V), "the offline member heard the write: the scenario is not the field case")

			-- It logs back in. No cycle of the banker's runs in this window, so the only way the new
			-- limit reaches the member is the handshake on the member's own login broadcast.
			local answersBefore = #F.sent({ type = "guild-settings", from = BANK, to = VIEW })
			F.online(V)
			if wire == "throttled" then F.enterWorld(V); F.tick(6) end
			F.login(V)
			F.tick(20)
			assert.equal(25, limit(V), "the member logged in and still holds the old limit after its own sync")
			assert.equal(answersBefore + 1, #F.sent({ type = "guild-settings", from = BANK, to = VIEW, dist = "WHISPER" }),
				"the banker did not answer the member's login broadcast with the settings, once, by whisper")
			local hlb2 = F.sent({ type = "hlb2", from = VIEW })
			assert.equal(1, #hlb2)
			assert.equal(0, hlb2[#hlb2].body.sv, "the member's broadcast did not name the settings version it held")
			assert.is_string(hlb2[#hlb2].body.sh, "the member's broadcast did not carry the settings canon")

			-- Once the bank's contents have synced, the limit is ENFORCED on the member's client.
			F.tick(75)
			local ok, why = F.with(V, function()
				return V.G.TOGBankClassic_Guild:AddRequest({ requester = V.norm, bank = A.norm, item = "Linen Cloth", itemID = 2589, quantity = 11 })
			end)
			assert.is_false(ok, "the member ordered 11 of 40 under a 25% limit")
			assert.truthy(tostring(why):find("at most 10", 1, true), tostring(why))
			assert.is_true((F.with(V, function()
				return V.G.TOGBankClassic_Guild:AddRequest({ requester = V.norm, bank = A.norm, item = "Linen Cloth", itemID = 2589, quantity = 10 })
			end)))
			assert.same({}, F.output(A, "Error")); assert.same({}, F.output(V, "Error"))
		end)
	end)

	-- SETTINGS-FANOUT-001 (self-audit 4777d14a F2): every banker and officer online answered the
	-- behind member's login broadcast -- one whisper each where one does the job. The writer here
	-- sorts LAST, so "the writer answers" and "the lowest-sorting answers" cannot be confused.
	describe("SETTINGS-FANOUT-001 on the " .. wire .. " wire: several bank characters online, one answer", function()
		local ALPHA, BRAVO, WRITER = "Abank", "Bbank", "Cbank"

		--- Three bank characters and a member; the member is offline through the writer's change, and
		--- each bank character's next sync cycle has run since (so each has heard what the others hold).
		local function fleet()
			local c = F.new({
				{ name = WRITER, note = "gbank", client = true, money = 100 },
				{ name = ALPHA, note = "gbank", client = true },
				{ name = BRAVO, note = "gbank", client = true },
				{ name = VIEW, client = true },
			}, { wire = wire })
			F.scan(c[WRITER], { { id = 2589, count = 40 } }, { bank = {}, money = 100 })
			for _, n in ipairs({ WRITER, ALPHA, BRAVO }) do F.login(c[n]) end
			F.tick(10)
			F.offline(c[VIEW])
			F.with(c[WRITER], function()
				local G = c[WRITER].G.TOGBankClassic_Guild
				G.Info.settings.maxRequestPercent = 25
				G:BroadcastSettings("ALERT")
			end)
			F.tick(10)
			for _, n in ipairs({ WRITER, ALPHA, BRAVO }) do F.login(c[n]); F.tick(10) end
			for _, n in ipairs({ WRITER, ALPHA, BRAVO }) do
				assert.equal(25, F.with(c[n], function() return c[n].G.TOGBankClassic_Guild:MaxRequestPercent() end), n .. " does not hold the write")
			end
			return c
		end

		local function memberLogsIn(c)
			local V = c[VIEW]
			F.online(V)
			if wire == "throttled" then F.enterWorld(V); F.tick(6) end
			F.login(V)
			F.tick(20)
			assert.equal(25, F.with(V, function() return V.G.TOGBankClassic_Guild:MaxRequestPercent() end),
				"the member logged in and still holds the old limit after its own sync")
		end

		--- Who whispered the member the settings since `mark` log entries.
		local function answerers(mark)
			local who = {}
			local all = F.sent({ type = "guild-settings", to = VIEW, dist = "WHISPER" })
			for i = mark + 1, #all do who[#who + 1] = all[i].from.name end
			return who
		end

		it("the lowest-sorting bank character answers, and nobody else does", function()
			local c = fleet()
			local mark = #F.sent({ type = "guild-settings", to = VIEW, dist = "WHISPER" })
			memberLogsIn(c)
			assert.same({ ALPHA }, answerers(mark))
			for _, n in ipairs({ WRITER, ALPHA, BRAVO, VIEW }) do assert.same({}, F.output(c[n], "Error")) end
		end)

		it("with the lowest-sorting one offline, the next one answers -- the member is still corrected, once", function()
			local c = fleet()
			F.offline(c[ALPHA])
			F.tick(2)
			local mark = #F.sent({ type = "guild-settings", to = VIEW, dist = "WHISPER" })
			memberLogsIn(c)
			assert.same({ BRAVO }, answerers(mark))
		end)
	end)
end
