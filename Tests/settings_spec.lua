-- SETTINGS-003 / SETTINGS-004 (Peer Review f5e52bcf, findings 1 and 5): who a RECEIVER trusts to
-- write the guild settings, and how a stale writer's untouched fields lose.
--
-- The REAL Guild (its roster built by the real LibGuildRoster from the harness roster, its own
-- SenderIsOfficer / SenderIsGM), the real Chat dispatch and Core envelope, the send captured. No
-- predicate is stubbed: the review's point was that every earlier wire example ran on a stub of
-- the very predicate that was wrong.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local GM, OFFICER, MEMBER = "Gm-Testrealm", "Officer-Testrealm", "Member-Testrealm"

local Guild, sent, me

local function loadWire()
	env.stubOutput()
	require("env.ace").load("AceAddon-3.0", "AceComm-3.0", "AceConsole-3.0",
		"AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
	env.loadDeltaSync()
	env.loadModules({
		"Modules/Constants.lua", "Modules/Switches.lua", "Modules/Item.lua",
		"Modules/Inventory/Record.lua", "Modules/Inventory/Resolve.lua", "Modules/Inventory/Store.lua",
		"Modules/Inventory/Scan.lua", "Modules/Inventory/Wire.lua", "Modules/DeltaComms.lua",
		"Modules/Guild.lua", "Modules/RequestLog.lua", "Modules/Donations.lua", "Modules/Chat.lua",
	})
	local AceAddon = LibStub("AceAddon-3.0")
	if AceAddon and AceAddon.addons then
		AceAddon.addons["TOGBankClassic"] = nil
		if AceAddon.addonstatus then AceAddon.addonstatus["TOGBankClassic"] = nil end
	end
	env.loadFile("Core.lua")
	env.now = 1757000000
	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	TOGBankClassic_Database = { db = { global = { switches = {} }, faction = {} }, RecordDeltaReceived = function() end, RecordNoChangeSent = function() end }
	TOGBankClassic_Options = {
		IsIntegrityCheckDiagnosticsEnabled = function() return false end, IsSyncProgressMuted = function() return true end,
		GetBankEnabled = function() return true end, GetAutoTombstoneDays = function() return 30 end,
		GetMaxRequestPercent = function() return 100 end, GetBankReporting = function() return false end,
		IsOrderFulfillmentSoundEnabled = function() return false end,
	}
	TOGBankClassic_Performance = { RecordOperation = function() end }
	Guild = TOGBankClassic_Guild
	-- The shop is ON, so the open/closed sign is read (IsStoreOpen answers open whenever it is off).
	Guild.Info = { name = "Testguild", alts = {}, roster = { alts = {} }, requests = {}, requestsTombstones = {}, settings = { shopEnabled = true } }
	Guild.memberRoster, Guild.onlineMembers, Guild.banksCache, Guild.lastSettingsPayload = {}, {}, nil, nil
	Guild.GetNormalizedPlayer = function() return me end
	Guild.GetPlayer = function() return me end
	TOGBankClassic_Chat.hashBroadcastQueue = {}
	sent = {}
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, body, dist, target, prio, cb, cbArg)
		sent[#sent + 1] = { prefix = prefix, body = body, dist = dist, target = target, prio = prio }
		if cb then cb(cbArg, #tostring(body), #tostring(body), true) end
	end
	_G.LibGuildRosterDB = nil
	local lib = env.freshGuildRoster()
	env.readyGuildRoster(lib)
	Guild:RefreshOnlineCache()
end

--- The guild-settings payloads captured, decoded, oldest first.
local function settingsSent()
	local out = {}
	for _, msg in ipairs(sent) do
		if msg.prefix == "togbank-hl" then
			local ok, decoded = TOGBankClassic_Core:DeserializeWithChecksum(msg.body, { sender = me, prefix = msg.prefix })
			assert.is_true(ok)
			if decoded.type == "guild-settings" then out[#out + 1] = decoded.settings end
		end
	end
	return out
end

local function clearSent() for i = #sent, 1, -1 do sent[i] = nil end end

--- A guild-settings broadcast as `from` would send it.
local function hear(from, settings)
	TOGBankClassic_Chat:OnCommReceived("togbank-hl", TOGBankClassic_Core:SerializeWithChecksum({ type = "guild-settings", settings = settings }), "GUILD", from)
end

local function roster()
	env.reset()
	env.addGuildMember(GM, { rankIndex = 0, online = true })
	env.addGuildMember(OFFICER, { rankIndex = 1, online = true })
	env.addGuildMember(MEMBER, { rankIndex = 4, online = true })
	_G.CanViewOfficerNote = function() return me == GM or me == OFFICER end
end

describe("SETTINGS-003: an officer's write reaches the members it governs", function()
	before_each(function() me = MEMBER; roster(); loadWire() end)

	it("BEFORE the GM has published a floor, a member's client drops a non-GM officer's write (the review's failure) and takes the GM's", function()
		assert.is_false(Guild:SenderIsOfficer(OFFICER), "the member's client judged the officer an officer with nothing to judge by")
		hear(OFFICER, { version = env.now, storeOpen = false, stamps = { storeOpen = env.now } })
		assert.is_true(Guild:IsStoreOpen(), "the write was applied; the failure the fix is for is gone from the fixture")
		hear(GM, { version = env.now, storeOpen = false, stamps = { storeOpen = env.now } })
		assert.is_false(Guild:IsStoreOpen(), "the GM's write did not apply")
	end)

	it("the GM publishes the floor from the client's rank permissions; from then on the officer's write applies, a member's never does, and a floor from a non-GM is ignored", function()
		-- A floor sent by the officer, in its own favour: not adopted.
		hear(OFFICER, { version = env.now, officerRankFloor = 1, stamps = { officerRankFloor = env.now } })
		assert.is_nil(Guild:OfficerRankFloor(), "a non-GM sender set the officer floor")
		-- The GM's: adopted, and the officer's later write applies through it.
		hear(GM, { version = env.now, officerRankFloor = 1, stamps = { officerRankFloor = env.now } })
		assert.equal(1, Guild:OfficerRankFloor())
		assert.is_true(Guild:SenderIsOfficer(OFFICER))
		assert.is_false(Guild:SenderIsOfficer(MEMBER))
		hear(OFFICER, { version = env.now + 1, storeOpen = false, stamps = { storeOpen = env.now + 1 } })
		assert.is_false(Guild:IsStoreOpen(), "the officer's write was still dropped with the floor published")
		hear(MEMBER, { version = env.now + 2, storeOpen = true, stamps = { storeOpen = env.now + 2 } })
		assert.is_false(Guild:IsStoreOpen(), "a plain member's broadcast wrote the settings")
		-- The floor is carried on every broadcast this client makes, so a joiner learns it too.
		me = OFFICER
		Guild:BroadcastSettings()
		assert.equal(1, settingsSent()[1].officerRankFloor)
	end)

	it("the GM's client READS the floor from C_GuildInfo.GuildControlGetRankFlags at the roster build and broadcasts it once; a member's client never does", function()
		-- Four ranks; ranks 1 and 2 (orders 1..2) may view officer notes -- index 11 of the flags.
		_G.GuildControlGetNumRanks = function() return 4 end
		_G.C_GuildInfo = _G.C_GuildInfo or {}
		_G.C_GuildInfo.GuildControlGetRankFlags = function(order)
			local flags = {}
			flags[Guild.VIEW_OFFICER_NOTE_FLAG] = (order <= 2)
			return flags
		end
		assert.equal(1, Guild:ReadOfficerRankFloor())
		-- On the member's client (the fixture's), the roster build publishes nothing.
		clearSent()
		Guild:RefreshOnlineCache()
		assert.equal(0, #settingsSent(), "a non-GM client published a floor")
		assert.is_nil(Guild:OfficerRankFloor())
		-- On the GM's client the roster build publishes it, stamped, and once.
		me = GM
		Guild:RefreshOnlineCache()
		local out = settingsSent()
		assert.equal(1, #out, "the GM's client did not publish the floor")
		assert.equal(1, out[1].officerRankFloor)
		assert.is_number(out[1].stamps.officerRankFloor)
		assert.equal(1, Guild:OfficerRankFloor())
		Guild:RefreshOnlineCache()
		assert.equal(1, #settingsSent(), "an unchanged floor was re-published")
		-- The API answering nothing (no data on this client): no floor, nothing sent.
		_G.C_GuildInfo.GuildControlGetRankFlags = function() return {} end
		assert.is_nil(Guild:ReadOfficerRankFloor())
		_G.C_GuildInfo.GuildControlGetRankFlags = nil
		_G.GuildControlGetNumRanks = nil
	end)
end)

describe("SETTINGS-004: per-field stamps -- a stale writer's untouched fields lose", function()
	before_each(function() me = MEMBER; roster(); loadWire() end)

	it("the GM closes ordering; a writer that never heard it writes the discount later: the discount lands, the sign stays closed", function()
		local T0, T1, T2 = env.now - 200, env.now - 100, env.now
		hear(GM, { version = T1, storeOpen = false, storeDiscountPercent = 0, stamps = { storeOpen = T1, storeDiscountPercent = T0 } })
		assert.is_false(Guild:IsStoreOpen())
		assert.equal(T1, Guild:SettingsStamp("storeOpen"))
		-- The GM has published the floor, so the officer is trusted at all.
		hear(GM, { version = T1, officerRankFloor = 1, stamps = { officerRankFloor = T1 } })
		-- The officer's write: a fresh stamp on the discount, the stale T0 stamp on the sign it
		-- still holds open.
		hear(OFFICER, { version = T2, storeOpen = true, storeDiscountPercent = 25, stamps = { storeOpen = T0, storeDiscountPercent = T2 } })
		assert.equal(25, Guild.Info.settings.storeDiscountPercent, "the officer's own write was not applied")
		assert.is_false(Guild:IsStoreOpen(), "the officer's STALE copy of the sign reopened ordering")
		assert.equal(T2, Guild:SettingsVersion())
		assert.equal(T2, Guild:SettingsStamp("storeDiscountPercent")); assert.equal(T1, Guild:SettingsStamp("storeOpen"))
		-- A field the payload carries NO stamp for is of unknown age: it displaces nothing held.
		hear(OFFICER, { version = T2 + 1, storeOpen = true, stamps = { storeDiscountPercent = T2 } })
		assert.is_false(Guild:IsStoreOpen())
		-- KNOWN COST: a pre-004 sender (no stamps at all) is still judged whole on its version.
		hear(GM, { version = T2 + 5, storeOpen = true })
		assert.is_true(Guild:IsStoreOpen())
	end)

	it("the writer stamps only the fields it changed, diffing against the last payload sent or applied; a re-announcement carries the held stamps", function()
		local T1 = env.now - 100
		hear(GM, { version = T1, officerRankFloor = 1, storeOpen = false, storeDiscountPercent = 0, notForSale = {},
			stamps = { officerRankFloor = T1, storeOpen = T1, storeDiscountPercent = T1, notForSale = T1 } })
		me = OFFICER
		-- A re-announcement first (the login piggyback): no new stamps, the snapshot taken.
		clearSent()
		Guild:BroadcastSettings()
		local out = settingsSent()
		assert.equal(1, #out)
		assert.equal(T1, out[1].stamps.storeOpen); assert.equal(T1, out[1].stamps.storeDiscountPercent)
		assert.equal(T1, out[1].version)
		-- The write: the discount's stamp moves, nothing else's does.
		clearSent()
		assert.is_true(Guild:SetStoreDiscount(25))
		out = settingsSent()
		assert.equal(1, #out)
		local v = out[1].version
		assert.is_true(v > T1)
		assert.equal(v, out[1].stamps.storeDiscountPercent, "the changed field was not stamped")
		assert.equal(T1, out[1].stamps.storeOpen, "an untouched field was stamped as a write")
		assert.equal(T1, out[1].stamps.notForSale)
		-- A nested table mutated IN PLACE (the Requests tab's cancel-reason editor does this) is
		-- still seen as a change: the snapshot is a copy, not a reference.
		Guild.Info.settings.cancelReasons = Guild.Info.settings.cancelReasons or { custom = {}, presetDisabled = { banker = {}, member = {} } }
		clearSent()
		Guild:BroadcastSettings("ALERT")
		local before = settingsSent()[1].stamps.cancelReasons
		table.insert(Guild.Info.settings.cancelReasons.custom, { text = "wrong stack", member = true, banker = true })
		env.now = env.now + 5
		clearSent()
		Guild:BroadcastSettings("ALERT")
		local after = settingsSent()[1].stamps.cancelReasons
		assert.is_true(after > before, "an in-place mutation of a nested setting was not stamped")
		assert.equal(T1, settingsSent()[1].stamps.storeOpen, "an untouched field's stamp moved")
	end)

	-- SETTINGS-STALE-001 (the operator, 2026-09-25: "we need to make sure someone logging on for the
	-- first time doesn't uncheck it, as that's the default"). Found live: the Sister-guild bank was
	-- unticked guild-wide, and a session's FIRST write with no snapshot stamped every field.
	it("a first write of the session, before any settings were sent or heard, stamps only the field it changed -- never the default Sister-guild bank off", function()
		me = GM
		Guild.lastSettingsPayload, Guild.lastSettingsFor = nil, nil
		assert.is_false(Guild:IsSisterBankEnabled(), "precondition: this client holds the default, off")
		clearSent()
		assert.is_true(Guild:SetStoreDiscount(25))
		local out = settingsSent()
		assert.equal(1, #out)
		assert.equal(out[1].version, out[1].stamps.storeDiscountPercent, "the changed field was not stamped")
		assert.is_nil(out[1].stamps.sisterBank, "the default 'off' was stamped as a write the GM never made")
		assert.is_false(out[1].sisterBank)
		-- The receiving side of the same payload: a client that holds the switch ON, stamped by the
		-- officer who ticked it, keeps it ON and takes the discount.
		local T1 = env.now - 100
		me = MEMBER
		Guild.Info.settings = { shopEnabled = true, sisterBank = true, version = T1, stamps = { sisterBank = T1, shopEnabled = T1 } }
		hear(GM, out[1])
		assert.is_true(Guild:IsSisterBankEnabled(), "a writer that never held the switch turned it off guild-wide")
		assert.equal(25, Guild.Info.settings.storeDiscountPercent)
	end)

	it("a write straight after settings were RECEIVED stamps only the field it changed (receiving no longer empties the baseline)", function()
		local T1 = env.now - 100
		me = OFFICER
		hear(GM, { version = T1, officerRankFloor = 1, storeOpen = false, sisterBank = true, storeDiscountPercent = 0,
			stamps = { officerRankFloor = T1, storeOpen = T1, sisterBank = T1, storeDiscountPercent = T1 } })
		assert.is_true(Guild:IsSisterBankEnabled())
		clearSent()
		assert.is_true(Guild:SetStoreDiscount(30))
		local out = settingsSent()
		assert.equal(1, #out)
		assert.equal(out[1].version, out[1].stamps.storeDiscountPercent)
		assert.equal(T1, out[1].stamps.storeOpen, "a field just received was re-stamped as this officer's write")
		assert.equal(T1, out[1].stamps.sisterBank, "the switch just received was re-stamped as this officer's write")
	end)
end)

-- SETTINGS-CANON-001 (the operator, 2026-09-16: "we need to ensure the the request % is being synced
-- and enforced. people are still allowed to request more than what was set. the officer setting
-- needs to be part of EVERY sync. they should have a canon has as well and if someones is older, they
-- need to pull the new settings as part of their sync").

--- Every togbank-hl message captured, decoded, with its target.
local function hlSent()
	local out = {}
	for _, msg in ipairs(sent) do
		if msg.prefix == "togbank-hl" then
			local ok, decoded = TOGBankClassic_Core:DeserializeWithChecksum(msg.body, { sender = me, prefix = msg.prefix })
			assert.is_true(ok)
			decoded._target, decoded._dist = msg.target, msg.dist
			out[#out + 1] = decoded
		end
	end
	return out
end

local function ofType(list, t)
	local out = {}
	for _, m in ipairs(list) do if m.type == t then out[#out + 1] = m end end
	return out
end

describe("SETTINGS-CANON-001: the settings canon, and the ask / answer on a sync", function()
	before_each(function() me = MEMBER; roster(); loadWire() end)

	it("the canon is a function of the VALUES: the same values however built agree, a changed limit disagrees, the stamps and version do not count", function()
		Guild.Info.settings = { shopEnabled = true, maxRequestPercent = 50, notForSale = { [3] = true, [1] = true } }
		local a = Guild:SettingsCanon()
		assert.is_string(a)
		Guild.Info.settings = { notForSale = { [1] = true, [3] = true }, maxRequestPercent = 50, shopEnabled = true, version = 99, stamps = { maxRequestPercent = 99 } }
		assert.equal(a, Guild:SettingsCanon(), "the same values built in another order, or with stamps, changed the canon")
		Guild.Info.settings.maxRequestPercent = 40
		assert.are_not.equal(a, Guild:SettingsCanon(), "a changed request limit left the canon as it was")
		Guild.Info = nil
		assert.is_nil(Guild:SettingsCanon())
	end)

	it("the writer's raw copy and the receiver's sanitized copy of the same settings agree on the canon -- no endless re-send between them", function()
		-- The officer's editor left a partial help-notes table and cancel reasons without the preset
		-- sets; the member applied the officer's broadcast, which sanitizes both.
		me = GM
		Guild.Info.settings = { shopEnabled = false, helpNotes = { inventory = "Ask in guild chat" },
			cancelReasons = { custom = { { text = "wrong stack", member = true, banker = true } } } }
		Guild:BroadcastSettings("ALERT")
		local writerCanon = Guild:SettingsCanon()
		local payload = settingsSent()[#settingsSent()]
		me = MEMBER
		Guild.Info.settings = { shopEnabled = false }
		Guild.lastSettingsPayload = nil
		hear(GM, payload)
		assert.equal("", Guild.Info.settings.helpNotes.search, "the receiver did not sanitize (the case this example is for)")
		assert.equal(writerCanon, Guild:SettingsCanon(), "the raw and sanitized copies of the same values hashed differently")
		-- So neither side asks or answers the other on a sync.
		clearSent()
		assert.is_false(Guild:OnSettingsAdvertised(GM, Guild:SettingsVersion(), writerCanon))
		assert.equal(0, #hlSent())
	end)

	it("BEHIND an authorized guildmate's advertised settings, the client asks it by whisper -- once per cooldown -- and never asks a plain member or itself", function()
		-- The GM holds v T; this member holds the defaults, never stamped.
		local T = env.now - 10
		clearSent()
		assert.is_true(Guild:OnSettingsAdvertised(GM, T, "some-canon"))
		local asks = ofType(hlSent(), "settings-request")
		assert.equal(1, #asks, "no ask went to the guildmate holding newer settings")
		assert.equal("WHISPER", asks[1]._dist)
		assert.equal(0, asks[1].held)
		assert.equal(Guild:SettingsCanon(), asks[1].canon)
		-- A burst of broadcasts is one ask.
		assert.is_false(Guild:OnSettingsAdvertised(GM, T, "some-canon"))
		assert.equal(1, #ofType(hlSent(), "settings-request"))
		-- ... until the cooldown has passed.
		env.now = env.now + Guild.SETTINGS_ASK_COOLDOWN
		assert.is_true(Guild:OnSettingsAdvertised(GM, T, "some-canon"))
		-- A guildmate with no standing (no officer floor published) advertising newer settings is not
		-- asked: its answer would be dropped.
		clearSent()
		assert.is_false(Guild:OnSettingsAdvertised(OFFICER, T + 5, "x"))
		assert.equal(0, #hlSent())
		-- Ourselves: nothing.
		assert.is_false(Guild:OnSettingsAdvertised(MEMBER, T + 5, "x"))
		-- The same version with the same canon: nothing.
		Guild.Info.settings.version = T + 5
		assert.is_false(Guild:OnSettingsAdvertised(GM, T + 5, Guild:SettingsCanon()))
		-- The same version with DIFFERENT values: asked.
		assert.is_true(Guild:OnSettingsAdvertised(GM, T + 5, "different"))
		assert.equal(1, #ofType(hlSent(), "settings-request"))
		-- Nothing from a broadcast without the field (a client before this build).
		assert.is_false(Guild:OnSettingsAdvertised(GM, nil, nil))
	end)

	it("AHEAD of a guildmate's advertised settings, an authorized client answers at once by whisper -- a member logging in with yesterday's limit is corrected on its own sync", function()
		me = GM
		Guild.Info.settings.maxRequestPercent = 50
		Guild:BroadcastSettings("ALERT")   -- the write: stamped
		local held = Guild:SettingsVersion()
		assert.is_true(held > 0)
		clearSent()
		assert.is_true(Guild:OnSettingsAdvertised(MEMBER, 0, "old"), "the GM did not answer a member advertising older settings")
		local out = ofType(hlSent(), "guild-settings")
		assert.equal(1, #out)
		assert.equal("WHISPER", out[1]._dist)
		assert.equal(50, out[1].settings.maxRequestPercent)
		assert.equal(held, out[1].settings.version)
		-- Once per answer cooldown per asker.
		assert.is_false(Guild:OnSettingsAdvertised(MEMBER, 0, "old"))
		-- A member holding the same version and values is not answered.
		env.now = env.now + Guild.SETTINGS_ANSWER_COOLDOWN
		clearSent()
		assert.is_false(Guild:OnSettingsAdvertised(MEMBER, held, Guild:SettingsCanon()))
		assert.equal(0, #hlSent())
		-- A client WITHOUT standing never answers.
		me = MEMBER
		assert.is_false(Guild:OnSettingsRequest(OFFICER, { held = 0 }))
	end)

	it("SETTINGS-FANOUT-001: defers to a guildmate sorting first only when it is recorded AHEAD of the asker; a private advertisement is always answered; a plain member is never recorded", function()
		-- The GM's client writes: the floor (so the officer has standing) and a limit. Its payload, as
		-- BroadcastSettings built it, is the GM's own word about what it holds.
		me = GM
		Guild.Info.settings.officerRankFloor = 1
		Guild.Info.settings.maxRequestPercent = 40
		Guild:BroadcastSettings("ALERT")
		local T, gmCanon = Guild:SettingsVersion(), Guild:SettingsCanon()
		local payload = settingsSent()[#settingsSent()]
		-- The officer's client hears it.
		me = OFFICER
		Guild.Info.settings = { shopEnabled = true }
		Guild.lastSettingsPayload = nil
		hear(GM, payload)
		assert.equal(T, Guild:SettingsVersion())
		assert.equal(T, Guild.settingsHeard[GM].version)
		assert.equal(gmCanon, Guild.settingsHeard[GM].canon, "the canon recorded from the GM's payload is not the canon the GM holds")
		-- "Gm-" sorts before "Officer-", byte by byte: a member behind both is the GM's to answer.
		clearSent()
		assert.is_false(Guild:OnSettingsAdvertised(MEMBER, 0, "old"))
		assert.equal(0, #hlSent(), "the officer answered a member the GM is recorded ahead of")
		assert.equal("Gm-Testrealm", Guild:SettingsResponderBefore(MEMBER, 0, "old"))
		assert.is_nil(Guild.settingsHeard[MEMBER], "a plain member's advertisement was recorded as a responder")
		-- Same version, different values: the GM's recorded canon differs from the member's, so still the GM's.
		assert.is_false(Guild:OnSettingsAdvertised(MEMBER, T, "different"))
		assert.equal(0, #hlSent())
		-- A hash-list reply reached us alone: nobody else heard it, so we answer.
		assert.is_true(Guild:OnSettingsAdvertised(MEMBER, 0, "old", true))
		assert.equal(1, #ofType(hlSent(), "guild-settings"))
		-- The GM's own later word that it holds nothing newer than the member: not ahead, not deferred to.
		env.now = env.now + Guild.SETTINGS_ANSWER_COOLDOWN
		Guild:OnSettingsAdvertised(GM, 0, "wiped")   -- answered by us (we are ahead of it); not what this checks
		clearSent()
		assert.equal(0, Guild.settingsHeard[GM].version, "the peer's own advertisement did not replace its record")
		assert.is_nil(Guild:SettingsResponderBefore(MEMBER, 0, "old"))
		assert.is_true(Guild:OnSettingsAdvertised(MEMBER, 0, "old"))
		assert.equal(1, #ofType(hlSent(), "guild-settings"))
	end)

	it("END TO END on the real Chat dispatch: the ask arrives as a settings-request, the answer as guild-settings, and the member enforces the new limit", function()
		-- The GM's side: it holds the officer's 25% write (a plain bank: with the shop on, every order
		-- is a shop order and this example's plain request would be refused for that instead).
		me = GM
		Guild.Info.settings.shopEnabled = false
		Guild.Info.settings.maxRequestPercent = 25
		Guild:BroadcastSettings("ALERT")
		local answerFrom = Guild:SettingsVersion()
		clearSent()
		TOGBankClassic_Chat:OnCommReceived("togbank-hl",
			TOGBankClassic_Core:SerializeWithChecksum({ type = "settings-request", held = 0, canon = "old" }), "WHISPER", MEMBER)
		local answer = ofType(hlSent(), "guild-settings")
		assert.equal(1, #answer, "the settings-request was not answered")
		-- The member's side: hear that answer; the limit is adopted and the gate enforces it.
		me = MEMBER
		Guild.Info.settings = { shopEnabled = false }
		Guild.lastSettingsPayload = nil
		hear(GM, answer[1].settings)
		assert.equal(25, Guild:MaxRequestPercent())
		assert.equal(answerFrom, Guild:SettingsVersion())
		env.defineItem(2589, { name = "Linen Cloth" })
		TOGBankClassic_Inventory_Store:SetAltRecords("Testguild", GM, { { 2589, 40 } })
		local ok, why = Guild:AddRequest({ requester = MEMBER, bank = GM, item = "Linen Cloth", itemID = 2589, quantity = 11 })
		assert.is_false(ok, "an order over 25% of 40 was accepted")
		assert.truthy(why:find("at most 10", 1, true), why)
		assert.is_true(Guild:AddRequest({ requester = MEMBER, bank = GM, item = "Linen Cloth", itemID = 2589, quantity = 10 }))
	end)
end)

describe("SETTINGS-CANON-002 (Peer Review on 4777d14a): nothing a receiver cannot store from its sender is in the canon", function()
	local BANKER = "Banker-Testrealm"
	before_each(function()
		me = MEMBER; roster()
		env.addGuildMember(BANKER, { rankIndex = 4, online = true, note = "gbank" })
		loadWire()
	end)

	it("the GM publishes the officer floor while the member is offline; a BANK CHARACTER answers the member; the member keeps its old floor and does not ask again", function()
		me = GM
		Guild.Info.settings.officerRankFloor = 1
		Guild.Info.settings.maxRequestPercent = 40
		Guild:BroadcastSettings("ALERT")
		local fromGM = settingsSent()[#settingsSent()]
		-- The bank character heard the GM and re-announces what it holds (its cycle, or an answer).
		me = BANKER
		Guild.Info.settings = { shopEnabled = true }
		Guild.lastSettingsPayload = nil
		hear(GM, fromGM)
		assert.equal(1, Guild:OfficerRankFloor())
		clearSent()
		Guild:BroadcastSettings()
		local fromBanker = settingsSent()[1]
		local bankerVersion, bankerCanon = Guild:SettingsVersion(), Guild:SettingsCanon()
		-- The member hears the bank character only.
		me = MEMBER
		Guild.Info.settings = { shopEnabled = true }
		Guild.lastSettingsPayload = nil
		hear(BANKER, fromBanker)
		assert.is_nil(Guild:OfficerRankFloor(), "a non-GM sender set the floor; the case this example is for is gone")
		assert.equal(bankerVersion, Guild:SettingsVersion())
		assert.equal(40, Guild:MaxRequestPercent())
		assert.equal(bankerCanon, Guild:SettingsCanon(), "the floor only the GM can deliver still splits the canon")
		clearSent()
		assert.is_false(Guild:OnSettingsAdvertised(BANKER, bankerVersion, bankerCanon))
		assert.equal(0, #hlSent(), "the member asked the bank character again for a field it can never adopt from it")
	end)

	it("a legacy stored 0% goes out as 1% -- what every receiver stores and enforces -- so the writer and its receivers agree", function()
		me = GM
		Guild.Info.settings.maxRequestPercent = 0
		Guild.Info.settings.autoTombstoneDays = 0
		Guild:BroadcastSettings("ALERT")
		local payload = settingsSent()[#settingsSent()]
		assert.equal(1, payload.maxRequestPercent)
		assert.equal(1, payload.autoTombstoneDays)
		local writerCanon = Guild:SettingsCanon()
		me = MEMBER
		Guild.Info.settings = { shopEnabled = true, maxRequestPercent = 60, autoTombstoneDays = 30 }
		Guild.lastSettingsPayload = nil
		hear(GM, payload)
		assert.equal(1, Guild.Info.settings.maxRequestPercent, "the receiver refused the writer's percent")
		assert.equal(writerCanon, Guild:SettingsCanon())
		-- 150 goes out as 100; a percent never set stays unsent.
		Guild.Info.settings.maxRequestPercent = 150
		assert.equal(100, Guild:SettingsFields().maxRequestPercent)
		Guild.Info.settings.maxRequestPercent = nil
		assert.is_nil(Guild:SettingsFields().maxRequestPercent)
	end)
end)

describe("SETTINGS-CANON-001: the maximum request % is ENFORCED by Guild:AddRequest", function()
	before_each(function()
		me = MEMBER; roster(); loadWire()
		Guild.Info.settings.shopEnabled = false
		env.defineItem(2589, { name = "Linen Cloth" })
		env.defineItem(14256, { name = "Felcloth" })
		TOGBankClassic_Inventory_Store:SetAltRecords("Testguild", GM, { { 2589, 20 }, { 14256, 1 } })
	end)

	local function order(qty, id, name, who)
		return Guild:AddRequest({ requester = who or MEMBER, bank = GM, item = name or "Linen Cloth", itemID = id or 2589, quantity = qty })
	end

	it("refuses more than the % of the bank's stock, whatever surface calls it (the dialog, TOGProfessionMaster, Dibs, PersonalShopper)", function()
		Guild.Info.settings.maxRequestPercent = 50
		local ok, why = order(11)
		assert.is_false(ok)
		assert.truthy(why:find("at most 10", 1, true), why)
		assert.is_true(order(10))
	end)

	it("counts the requester's OPEN orders of the same item from the same bank: the maximum cannot be placed twice", function()
		Guild.Info.settings.maxRequestPercent = 50
		assert.is_true(order(6))
		local ok, why = order(6)
		assert.is_false(ok, "a second order took the member past the limit")
		assert.truthy(why:find("4 more", 1, true), why)
		assert.is_true(order(4))
		ok, why = order(1)
		assert.is_false(ok)
		assert.truthy(why:find("already have 10 on order", 1, true), why)
		-- Another member has their own allowance; another item has its own.
		assert.is_true(order(10, nil, nil, OFFICER))
		assert.is_true(order(1, 14256, "Felcloth"))
	end)

	it("what is mailed, cancelled or complete no longer holds the allowance it used", function()
		Guild.Info.settings.maxRequestPercent = 50
		assert.is_true(order(10))
		local r
		for _, req in pairs(Guild.Info.requests) do if req.itemID == 2589 then r = req end end
		assert.is_table(r)
		r.fulfilled = 6                       -- six mailed: four still owed
		assert.equal(4, Guild:OpenRequestedQuantity(MEMBER, GM, 2589))
		assert.equal(6, (Guild:RequestAllowance(MEMBER, GM, 2589)))
		r.status = "cancelled"
		assert.equal(0, Guild:OpenRequestedQuantity(MEMBER, GM, 2589))
		r.status = "complete"
		assert.equal(0, Guild:OpenRequestedQuantity(MEMBER, GM, 2589))
	end)

	it("a single item stays requestable at a low %, 100% is no limit, an order with no itemID passes, and a bank this client holds none of the item for refuses", function()
		Guild.Info.settings.maxRequestPercent = 10
		assert.is_true(order(1, 14256, "Felcloth"), "the one Felcloth could not be ordered at 10%")
		local ok, why = order(1, 14256, "Felcloth")
		assert.is_false(ok)
		assert.truthy(why:find("already have 1 on order", 1, true), why)
		Guild.Info.settings.maxRequestPercent = 100
		assert.is_true(order(20))
		assert.is_true(order(20))
		Guild.Info.settings.maxRequestPercent = 10
		assert.is_true(Guild:AddRequest({ requester = MEMBER, bank = GM, item = "Old Item", quantity = 99 }))
		env.defineItem(4306, { name = "Silk Cloth" })
		ok, why = order(1, 4306, "Silk Cloth")
		assert.is_false(ok)
		assert.truthy(why:find("holds none of this item", 1, true), why)
	end)

	it("SHOP-ORDER-API-001: Guild:ShopOrderFields is the Guild Bank window's builder, and nil without it", function()
		local saved = _G.TOGBankClassic_UI_Browse
		local fields = { shopOrder = true, estimate = 75, prompt = "Shop order -- estimated ~75c each (x)." }
		local asked
		_G.TOGBankClassic_UI_Browse = { ShopOrderFields = function(_, id) asked = id; return fields end }
		assert.equal(fields, Guild:ShopOrderFields(2589))
		assert.equal(2589, asked)
		_G.TOGBankClassic_UI_Browse = nil
		assert.is_nil(Guild:ShopOrderFields(2589))
		_G.TOGBankClassic_UI_Browse = saved
	end)

	it("MaxRequestPercent reads the synced setting, clamped to 1..100, 100 when unset", function()
		Guild.Info.settings.maxRequestPercent = nil
		assert.equal(100, Guild:MaxRequestPercent())
		Guild.Info.settings.maxRequestPercent = 0
		assert.equal(1, Guild:MaxRequestPercent())
		Guild.Info.settings.maxRequestPercent = 250
		assert.equal(100, Guild:MaxRequestPercent())
		Guild.Info.settings.maxRequestPercent = 33.7
		assert.equal(33, Guild:MaxRequestPercent())
		Guild.Info = nil
		assert.equal(100, Guild:MaxRequestPercent())
	end)
end)
