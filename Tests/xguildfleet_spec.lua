-- XGUILD-SYNC-001 step 6: TWO GUILDS, WHOLE CLIENTS, WHISPERS ONLY BETWEEN THEM.
--
-- docs/XGUILD_SYNC.md D5-D7 end to end: a sister guild's member holds nothing of the home guild's
-- bank; its federation pull (a whispered hash-list ask to one sighted member of the other guild)
-- draws the reply, the whispered alt-request, the ACK and the data leg, and it ends up holding the
-- bank -- with NO GUILD message crossing the boundary, because the bus delivers a GUILD send to the
-- sender's guild alone. Then a request placed by the sister member against the home banker crosses
-- by whisper, is relayed ONCE on the home guild, is completed by the banker, and the completion
-- crosses back and is relayed once on the sister guild. Every client of both guilds ends up with
-- the same request in the same state.
--
-- The library's own roster pull is not on the bus; F.federate feeds each side the other's roster
-- (with the gbank note LIBREQ-GR-002 will carry) and F.sighted stands in for its sighting stamp.
package.path = "./Tests/?.lua;" .. package.path
local F   = require("env_fleet")
local env = F.env

local HOME, SIS = F.GUILD, "Sister Guild"
local HB, HV, SB, SV = "Homebank", "Homeviewer", "Sisbank", "Sisviewer"

local function bank()
	local rows = {}
	for i = 1, 12 do rows[#rows + 1] = { id = 1000 + i, count = 3 } end
	return rows
end

local function noErrors(c)
	assert.same({}, F.output(c, "Error"), c.name .. " raised an Error")
end

local function federation()
	local c = F.new({
		{ name = HB, note = "gbank", client = true, money = 100, guild = HOME },
		{ name = HV, client = true, guild = HOME },
		{ name = SB, note = "gbank", client = true, guild = SIS },
		{ name = SV, client = true, guild = SIS },
	})
	F.federate(HOME, SIS)
	return c
end

describe("XGUILD-SYNC-001 fleet: a sister guild's member syncs the home guild's bank by whispers alone", function()
	it("stands up two guilds that see each other's bankers, tagged, and a GUILD send stays in its guild", function()
		local c = federation()
		local hv, sv = c[HV], c[SV]
		F.with(sv, function()
			local G = sv.G.TOGBankClassic_Guild
			assert.is_true(G:IsBank(HB .. "-" .. env.realmName), "the sister viewer does not know the home banker")
			assert.is_true(G:IsBank(SB .. "-" .. env.realmName))
			assert.is_true(G:IsFederated(HV .. "-" .. env.realmName)); assert.is_false(G:IsHomeMember(HV .. "-" .. env.realmName))
			assert.matches(HOME, G:GuildTag(HB .. "-" .. env.realmName))
			assert.equal("", G:GuildTag(SB .. "-" .. env.realmName))
		end)
		F.with(hv, function()
			local G = hv.G.TOGBankClassic_Guild
			assert.matches("Sister Guild", G:GuildTag(SB .. "-" .. env.realmName))
			assert.equal("", G:GuildTag(HB .. "-" .. env.realmName))
		end)
		-- The home banker's login broadcast reaches the home viewer and nobody in the sister guild.
		F.scan(c[HB], bank(), { bank = {}, money = 100 })
		F.login(c[HB])
		F.tick(2)
		assert.is_true(#F.sent({ from = HB, type = "hlb2", dist = "GUILD" }) >= 1)
		-- Every client holds a STUB for every banker (RebuildBankerRoster), so the record says
		-- nothing; what a hearing leaves behind is the viewer's numbers-request (fullsync_spec: a
		-- viewer that cannot name the broadcast's banker numbers asks for the table).
		assert.equal(1, #F.sent({ from = HV, type = "numbers-request" }), "the home viewer did not hear its own guild's broadcast")
		assert.equal(0, #F.sent({ from = SV, type = "numbers-request" }), "a GUILD broadcast crossed into the sister guild")
		assert.equal(0, #F.sent({ from = SB, type = "numbers-request" }))
		local held = F.held(sv, HB)
		assert.is_nil(next(held), "the sister viewer holds items it was never sent")
	end)

	-- LIBREQ-DS-008 part 2: the leg after the reply is the library's whispered session (sync-request
	-- -> sync-accept -> the data leg), not the pull path's alt-request / ACK. The sister viewer never
	-- hears the home guild's hlb2, so the reply carries the home banker's NUMBERS TABLE and the
	-- viewer adopts it (XGUILD-SYNC-001 D5) -- asserted, because a reply naming a banker the viewer
	-- cannot number would otherwise be judged by name and this example would pass for the fallback.
	it("the federation pull: hash-list ask -> reply (with the numbers) -> whispered sync-request -> accept -> data leg; the sister viewer holds the bank", function()
		local c = federation()
		local hb, sv = c[HB], c[SV]
		F.scan(hb, bank(), { bank = { { id = 2000, count = 2 } }, money = 100 })
		local rec = F.record(hb, HB)
		assert.is_string(rec.inventoryHashV2, "the banker's scan minted no canon")
		-- XGUILD-OWNERS-001: the home guild says who runs its bank character; the sister guild's
		-- viewer holds its own guild's entry for its own banker, which the answer must not wipe.
		assert.is_true(F.with(hb, function() return hb.G.TOGBankClassic_Guild:SetBankerOwner(hb.norm, "Alice") end))
		F.with(sv, function()
			local s = sv.G.TOGBankClassic_Guild.Info.settings
			s.bankerOwners = { [c[SB].norm] = "Sally" }
			s.bankerOwnerStamps = { [c[SB].norm] = 100 }
		end)
		-- The sister viewer's library has seen the home banker (the sighting its own pull stamps).
		F.sighted(sv, hb)
		assert.is_nil(F.with(sv, function() return sv.G.TOGBankClassic_BankerNumbers:NumberOf(hb.norm) end),
			"precondition: the sister viewer already numbers the home banker, so the table on the reply is not what this proves")
		local asked = F.with(sv, function() return sv.G.TOGBankClassic_Guild:PullFromFederation() end)
		assert.same({ hb.norm }, asked, "the sister viewer did not ask the home banker")
		F.tick(10)
		assert.equal(1, #F.sent({ from = SV, type = "hash-list-request", dist = "WHISPER", to = HB }))
		local replies = F.sent({ from = HB, type = "hash-list-reply", dist = "WHISPER", to = SV })
		assert.equal(1, #replies)
		assert.is_table(replies[1].body and replies[1].body.numbers, "the reply carried no numbers table for a sister client that never hears our hlb2")
		assert.equal("0001", F.with(sv, function() return sv.G.TOGBankClassic_BankerNumbers:NumberOf(hb.norm) end),
			"the sister viewer did not adopt the home guild's numbers from the reply")
		local ask = F.sent({ from = SV, type = "sync-request" })
		assert.equal(1, #ask, "the sister viewer did not ask for the bank")
		assert.equal("WHISPER", ask[1].dist, "the sync-request went to the sister GUILD, where nobody holds it")
		assert.equal(HB, ask[1].target and ask[1].target:match("^([^%-]+)"))
		assert.equal(hb.norm, ask[1].body.itemKey)
		assert.equal(1, #F.sent({ from = HB, type = "sync-accept", dist = "WHISPER", to = SV }))
		assert.equal(1, #F.sent({ from = HB, type = "inv-snapshot", dist = "WHISPER", to = SV }), "the data leg did not land")
		local want, wantMoney = F.held(hb, HB)
		local got, gotMoney = F.held(sv, HB)
		assert.same(want, got, "the sister viewer does not hold what the home banker holds")
		assert.equal(wantMoney, gotMoney)
		assert.equal(rec.inventoryHashV2, F.record(sv, HB).inventoryHashV2, "the sister viewer does not hold the author's canon")
		noErrors(hb); noErrors(sv)
		-- The home banker was told what the sister guild's cycle would have carried for it: the
		-- settings, the donation totals -- by whisper, to the asker.
		assert.equal(1, #F.sent({ from = HB, type = "guild-settings", dist = "WHISPER", to = SV }))
		F.with(sv, function()
			local G = sv.G.TOGBankClassic_Guild
			assert.equal("Alice", G:GetBankerOwner(hb.norm), "who runs the home bank character did not reach the sister guild")
			assert.equal("Sally", G:GetBankerOwner(c[SB].norm), "the home guild's answer wiped the sister guild's own owner")
		end)
		-- 70 s on, the requests-index ask follows, by whisper to the same peer.
		F.tick(70)
		assert.equal(1, #F.sent({ from = SV, type = "requests-index", dist = "WHISPER", to = HB }), "the index ask did not follow")
	end)

	it("a request from the sister viewer against the home banker crosses by whisper, is relayed once per guild, and its completion comes back the same way", function()
		local c = federation()
		local hb, hv, sb, sv = c[HB], c[HV], c[SB], c[SV]
		F.scan(hb, bank(), { bank = {}, money = 100 })
		-- Both guilds' clients have heard from each other once (a sighting each way), so whispers
		-- resolve as online on both sides.
		F.sighted(sv, hb); F.sighted(sb, hb); F.sighted(hb, sv); F.sighted(hv, sv); F.sighted(hb, sb); F.sighted(hv, sb)
		F.with(sv, function()
			local G = sv.G.TOGBankClassic_Guild
			assert.is_true(G:IsPlayerOnline(hb.norm), "the sister viewer does not see the home banker online after the sighting")
			assert.same({ hb.norm }, G:FederatedRelayTargets({ requester = sv.norm, bank = hb.norm }))
		end)
		local ok = F.with(sv, function()
			return sv.G.TOGBankClassic_Guild:AddRequest({ requester = sv.norm, bank = hb.norm, item = "Linen Cloth", itemID = 2589, quantity = 5 })
		end)
		assert.is_true(ok, "the sister viewer could not place the request")
		F.tick(2)
		local id = F.with(sv, function() return (next(sv.G.TOGBankClassic_Guild.Info.requests)) end)
		assert.is_string(id)
		-- One GUILD send in the sister guild (SB heard it), one whisper to the home banker, one relay
		-- on the home guild (HV heard it) -- marked, with the author kept. (FILL-ALERT-001: the
		-- mutation's guild send is spelled "GUILD" like every other; it was "Guild", which this bus
		-- carried and the harness's throttled wire silently dropped.)
		assert.equal(1, #F.sent({ from = SV, prefix = "togbank-rm", dist = "GUILD" }))
		assert.equal(1, #F.sent({ from = SV, prefix = "togbank-rm", dist = "WHISPER", to = HB }))
		local relay = F.sent({ from = HB, prefix = "togbank-rm", dist = "GUILD" })
		assert.equal(1, #relay, "the home banker did not relay the whispered request to its guild")
		assert.is_true(relay[1].body.logEntries[1].relayed)
		assert.equal(sv.norm, relay[1].body.logEntries[1].actor)
		for _, r in ipairs({ hb, hv, sb, sv }) do
			local req = F.with(r, function() return r.G.TOGBankClassic_Guild.Info.requests[id] end)
			assert.is_table(req, r.name .. " does not hold the request")
			assert.equal("open", req.status, r.name)
			assert.equal(sv.norm, req.requester)
		end
		assert.equal(0, #F.sent({ from = HV, prefix = "togbank-rm" }), "a relayed entry was relayed again")
		-- The banker completes it: GUILD at home, whispered back to the requester, relayed once in
		-- the sister guild.
		local done = F.with(hb, function() return hb.G.TOGBankClassic_Guild:CompleteRequest(id, hb.norm) end)
		assert.is_true(done)
		F.tick(2)
		assert.equal(1, #F.sent({ from = HB, prefix = "togbank-rm", dist = "WHISPER", to = SV }), "the completion did not cross back")
		local back = F.sent({ from = SV, prefix = "togbank-rm", dist = "GUILD" })
		assert.equal(2, #back, "the sister viewer did not relay the completion to its guild")
		assert.is_true(back[2].body.logEntries[1].relayed)
		assert.equal(hb.norm, back[2].body.logEntries[1].actor)
		for _, r in ipairs({ hb, hv, sb, sv }) do
			local req = F.with(r, function() return r.G.TOGBankClassic_Guild.Info.requests[id] end)
			assert.equal("complete", req.status, r.name .. " does not hold the completion")
		end
		for _, r in ipairs({ hb, hv, sb, sv }) do noErrors(r) end
	end)
end)
