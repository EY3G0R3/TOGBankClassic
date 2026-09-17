-- XGUILD-E2E-001 / XGUILD-INVENTORY-001: TWO GUILDS, NOTHING HAND-FED.
--
-- The operator, 2026-09-16: "did you write full end to end tests, to test getting the roster data from
-- GR, using the gbank tags to identify their bankers like you do in the main bank, and then use that
-- data to populate the bankers list?" -- and, after seeing the sister bankers in game: "now we need to
-- get the inventory sync working". xguildfleet_spec feeds each side the other's roster
-- (`F.federate`) and stamps presence by hand (`F.sighted`); neither happens in game. Here the officers
-- LIST each other's guild (`F.sisters`) and that is all: the roster, the `gbank` public notes and every
-- presence stamp cross on LibGuildRoster's own whispered pull over the harness's wire, TOGBank reads
-- its bankers from what arrived, the Bankers tab builds its rows from it, and the bank contents come
-- over on TOGBank's own cycle.
--
-- THE ONE MANUAL STEP, declared: a first pull by name (the Guild Roster window's "Pull from" box). In
-- game the first contact is that box or a /who sent from a click (LibGuildRoster's StartSisterSync);
-- both are hardware events, and the /who answer is the server's, which this wire does not model.
package.path = "./Tests/?.lua;" .. package.path
local F   = require("env_fleet")

local HOME, SIS = F.GUILD, "Sister Guild"
local HB, HV, SB, SV = "Homebank", "Homeviewer", "Sisbank", "Sisviewer"

local function bank(base)
	local rows = {}
	for i = 1, 12 do rows[#rows + 1] = { id = base + i, count = 3 } end
	return rows
end

local function noErrors(c)
	assert.same({}, F.output(c, "Error"), c.name .. " raised an Error")
end

local function lib(c)
	return c.G.LibStub("LibGuildRoster-1.0")
end

--- Both guilds up, each listing the other, no roster crossed yet.
local function federation()
	local c = F.new({
		{ name = HB, note = "gbank", client = true, money = 100, guild = HOME },
		{ name = HV, client = true, guild = HOME },
		{ name = SB, note = "gbank", client = true, guild = SIS },
		{ name = SV, client = true, guild = SIS },
	})
	F.sisters(HOME, SIS)
	return c
end

--- The Guild Roster window's "Pull from <name>" on `c`, then time for the ack, the roster and the
--- pull back to land -- with every player clicking once in a while, because the library verifies an
--- asker from another guild with a /who that only a click can send.
local function pullByName(c, peer)
	assert.is_true(F.with(c, function() return lib(c):PullSisterRoster(peer.norm, c.sisterKey) end),
		c.name .. "'s library would not pull")
	for _ = 1, 6 do
		F.tick(5)
		for _, r in ipairs(F.clients) do F.click(r) end
	end
end

--- The Bankers tab's rows on `c`, built by the real Browse module loaded into that client.
local function bankerRows(c)
	return F.with(c, function()
		if not c.G.TOGBankClassic_UI_Browse then
			-- Browse reads one constant from the AceGUI module at load; nothing else of the window.
			c.G.TOGBankClassic_UI = { FILTER_INSET = 8 }
			c:loadFile("Modules/UI/Browse.lua", "TOGBankClassic")
		end
		return c.G.TOGBankClassic_UI_Browse:BankerRows()
	end)
end

local function rowFor(rows, norm)
	for _, r in ipairs(rows) do if r.norm == norm then return r end end
	return nil
end

describe("XGUILD-E2E-001: sister bankers come from Guild Roster's served roster", function()
	it("one pull by name brings each guild the other's roster with its gbank notes, and each side's Bankers tab lists the other guild's bank, tagged", function()
		local c = federation()
		local hb, hv, sb, sv = c[HB], c[HV], c[SB], c[SV]
		assert.is_false(F.with(sv, function() return sv.G.TOGBankClassic_Guild:IsBank(hb.norm) end),
			"precondition: the sister viewer knows the home banker before any roster crossed")

		pullByName(sv, hb)

		-- The library's own traffic carried it: the pull, and the pull back.
		F.with(sv, function()
			local roster = lib(sv):GetRoster(sv.sisterKey)
			assert.is_table(roster, "the sister viewer's library holds no home roster")
			assert.is_table(roster[hb.norm], "the home banker is not on the roster that arrived")
			assert.equal("gbank", roster[hb.norm].note, "the served roster lost the gbank public note")
		end)
		F.with(hb, function()
			local roster = lib(hb):GetRoster(hb.sisterKey)
			assert.is_table(roster, "the home banker's library did not pull the sister roster back")
			assert.equal("gbank", roster[sb.norm] and roster[sb.norm].note)
		end)

		-- TOGBank identifies the bank characters by the tag, as for its own guild.
		F.with(sv, function()
			local G = sv.G.TOGBankClassic_Guild
			assert.is_true(G:IsBank(hb.norm), "the sister viewer did not take the home banker from its note")
			assert.is_false(G:IsBank(hv.norm), "a member with no gbank note became a banker")
			assert.is_true(G:IsBank(sb.norm))
		end)

		-- The Bankers tab rows, tagged with the guild.
		local rows = bankerRows(sv)
		local home = rowFor(rows, hb.norm)
		assert.is_table(home, "the sister viewer's Bankers tab has no row for the home banker")
		assert.matches("%(" .. HOME .. "%)", home.name)
		assert.equal(HOME, home.guildName)
		local own = rowFor(rows, sb.norm)
		assert.is_table(own)
		assert.not_matches("%(", own.name, "an own-guild banker was tagged")
		assert.is_nil(rowFor(rows, hv.norm))
		local back = rowFor(bankerRows(hb), sb.norm)
		assert.is_table(back, "the home banker's Bankers tab has no row for the sister banker")
		assert.matches("%(" .. SIS .. "%)", back.name)
		for _, r in ipairs({ hb, hv, sb, sv }) do noErrors(r) end
	end)
end)

describe("XGUILD-INVENTORY-001: the sister guild's bank contents arrive on TOGBank's own cycle", function()
	it("after the roster pull, the sister viewer's cycle asks the home guild by whisper and ends up holding the home bank", function()
		local c = federation()
		local hb, sv = c[HB], c[SV]
		F.scan(hb, bank(1000), { bank = { { id = 2000, count = 2 } }, money = 100 })
		pullByName(sv, hb)

		-- The library has seen the home banker (its pull answer stamped it), and TOGBank's member cache
		-- was built before that stamp: the whisper must read the stamp, not the cache.
		F.with(sv, function()
			assert.same({ hb.norm }, lib(sv):GetOnlineMembersScoped(sv.sisterKey))
			assert.is_true(sv.G.TOGBankClassic_Guild:IsPlayerOnline(hb.norm), "a sister member the library has just seen reads offline")
		end)
		F.login(sv)
		F.tick(90)

		assert.equal(1, #F.sent({ from = SV, type = "hash-list-request", dist = "WHISPER", to = HB }),
			"the sister viewer's cycle asked nobody in the home guild")
		local want, wantMoney = F.held(hb, HB)
		local got, gotMoney = F.held(sv, HB)
		assert.is_not_nil(next(want))
		assert.same(want, got, "the sister viewer does not hold the home bank")
		assert.equal(wantMoney, gotMoney)
		noErrors(hb); noErrors(sv)
	end)

	it("a client that never pulled first-hand -- its roster came from a guildmate's relay -- still reaches the other guild's bank", function()
		local c = federation()
		local hb, hv, sb, sv = c[HB], c[HV], c[SB], c[SV]
		F.scan(sb, bank(3000), { bank = {}, money = 50 })
		-- The sister banker pulls the home guild's roster from the home banker; the home banker pulls
		-- the sister roster back. The home VIEWER spoke to nobody.
		pullByName(sb, hb)
		-- The library relays what it pulled within its guild on its own rounds.
		F.tick(600)
		F.with(hv, function()
			assert.is_table(lib(hv):GetRoster(hv.sisterKey), "the home viewer never got the sister roster from its guild")
			assert.is_true(hv.G.TOGBankClassic_Guild:IsBank(sb.norm), "the home viewer does not list the sister banker")
		end)

		F.login(hv)
		F.tick(90)

		local got = F.held(hv, SB)
		assert.same(F.held(sb, SB), got, "the home viewer does not hold the sister bank")
		assert.is_not_nil(next(got))
		for _, r in ipairs({ hb, hv, sb, sv }) do noErrors(r) end
	end)
end)
