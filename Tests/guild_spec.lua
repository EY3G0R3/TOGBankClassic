-- Guild.lua — name normalization, banker identification, and the view-only flag.
--
-- NormalizeName is the addon's identity function: every alt key, roster lookup, request record
-- and wire message is keyed by its output. A defect here does not error, it makes lookups miss.
-- IsBank / IsViewOnlyBank gate who can be scanned and who can be requested from.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local function loadGuild()
	env.stubOutput()
	env.loadFile("Modules/Constants.lua")
	env.loadFile("Modules/Guild.lua")
	return TOGBankClassic_Guild
end

describe("Guild:NormalizeName", function()
	local Guild
	before_each(function() env.reset(); Guild = loadGuild() end)

	it("appends the connected realm to a bare name", function()
		assert.equal("Bob-Testrealm", Guild:NormalizeName("Bob"))
	end)

	it("leaves an already-qualified name alone", function()
		assert.equal("Bob-Otherrealm", Guild:NormalizeName("Bob-Otherrealm"))
	end)

	it("returns nil for nil", function()
		assert.is_nil(Guild:NormalizeName(nil))
	end)

	it("trims surrounding whitespace", function()
		assert.equal("Bob-Testrealm", Guild:NormalizeName("  Bob  "))
	end)

	it("canonicalises spacing around the realm separator", function()
		assert.equal("Bob-Otherrealm", Guild:NormalizeName("Bob - Otherrealm"))
		assert.equal("Bob-Otherrealm", Guild:NormalizeName("Bob- Otherrealm"))
	end)

	it("coerces a non-string to a string", function()
		assert.equal("1234-Testrealm", Guild:NormalizeName(1234))
	end)

	it("returns nil for an empty string", function()
		assert.is_nil(Guild:NormalizeName(""))
	end)

	it("collapses any casing of Unknown to a single sentinel", function()
		assert.equal("Unknown", Guild:NormalizeName("unknown"))
		assert.equal("Unknown", Guild:NormalizeName("UNKNOWN"))
	end)

	it("is idempotent", function()
		local once = Guild:NormalizeName("Bob")
		assert.equal(once, Guild:NormalizeName(once))
	end)
end)

-- Peer review F2 / delta release step 5: "units still owed" had seven spellings across Mail,
-- ItemHighlight and the Requests window. This is the one; the sites call it.
-- BANKERS-FILTER-001: what a banker stores is whatever the officer wrote in the guild note beside
-- the gbank marker (the operator: "metadata for each banker, on the types of stuff they store").
describe("Guild:BankerStores", function()
	local Guild
	before_each(function()
		env.reset(); Guild = loadGuild()
		Guild.memberRoster = {
			["Alice-Testrealm"] = { name = "Alice-Testrealm", isBank = true, note = "gbank: herbs & potions" },
			["Bob-Testrealm"]   = { name = "Bob-Testrealm",   isBank = true, note = "Raid mats gbank" },
			["Cara-Testrealm"]  = { name = "Cara-Testrealm",  isBank = true, note = "GBANKRO view-only -- enchanting mats" },
			["Dan-Testrealm"]   = { name = "Dan-Testrealm",   isBank = true, note = "gbank" },
			["Eve-Testrealm"]   = { name = "Eve-Testrealm",   isBank = false },
		}
	end)

	it("is the note with every marker and the punctuation around it stripped", function()
		assert.equal("herbs & potions", Guild:BankerStores("Alice-Testrealm"))
		assert.equal("Raid mats", Guild:BankerStores("Bob"))   -- a bare name normalises
		assert.equal("enchanting mats", Guild:BankerStores("Cara-Testrealm"), "the view-only markers (any case) were not stripped")
	end)

	it("is empty for a marker-only note, a non-banker, an unknown name and nil", function()
		assert.equal("", Guild:BankerStores("Dan-Testrealm"))
		assert.equal("", Guild:BankerStores("Eve-Testrealm"))
		assert.equal("", Guild:BankerStores("Nobody-Testrealm"))
		assert.equal("", Guild:BankerStores(nil))
	end)
end)

describe("Guild:RequestQuantityNeeded", function()
	local Guild
	before_each(function() env.reset(); Guild = loadGuild() end)

	it("is quantity minus the Sent column", function()
		assert.equal(6, Guild:RequestQuantityNeeded({ quantity = 10, fulfilled = 4 }))
		assert.equal(10, Guild:RequestQuantityNeeded({ quantity = 10 }), "an unfilled request needs all of it")
	end)

	it("is never negative, and reads the fields as numbers even when a wire left them as strings", function()
		assert.equal(0, Guild:RequestQuantityNeeded({ quantity = 4, fulfilled = 10 }), "an over-filled request owes nothing, not a negative")
		assert.equal(0, Guild:RequestQuantityNeeded({ quantity = 4, fulfilled = 4 }))
		assert.equal(3, Guild:RequestQuantityNeeded({ quantity = "5", fulfilled = "2" }))
	end)

	it("answers zero for junk rather than raising", function()
		assert.equal(0, Guild:RequestQuantityNeeded(nil))
		assert.equal(0, Guild:RequestQuantityNeeded({}))
		assert.equal(0, Guild:RequestQuantityNeeded({ quantity = "lots" }))
	end)

	it("says nothing about status -- callers gate on that beside it", function()
		assert.equal(2, Guild:RequestQuantityNeeded({ quantity = 2, fulfilled = 0, status = "cancelled" }))
	end)
end)

describe("Guild:GetBanks", function()
	local Guild
	before_each(function()
		env.reset()
		Guild = loadGuild()
		Guild.memberRoster, Guild.banksCache = {}, nil
	end)

	it("finds a banker by the gbank tag in the public note", function()
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		env.addGuildMember("Regular-Testrealm", { note = "" })
		assert.same({ "Banker-Testrealm" }, Guild:GetBanks())
	end)

	it("finds a banker by the gbank tag in the officer note", function()
		env.addGuildMember("Banker-Testrealm", { officerNote = "gbank" })
		assert.same({ "Banker-Testrealm" }, Guild:GetBanks())
	end)

	it("matches gbank anywhere in the note", function()
		env.addGuildMember("Banker-Testrealm", { note = "raid gbank alt" })
		assert.same({ "Banker-Testrealm" }, Guild:GetBanks())
	end)

	it("returns nil when no member carries the tag", function()
		env.addGuildMember("Regular-Testrealm", { note = "" })
		assert.is_nil(Guild:GetBanks())
	end)

	it("caches the result", function()
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		Guild:GetBanks()
		env.roster = {}   -- pull the roster out from under it
		assert.same({ "Banker-Testrealm" }, Guild:GetBanks(), "the second call re-scanned the roster")
	end)

	it("re-scans after the cache is invalidated", function()
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		Guild:GetBanks()
		Guild:InvalidateBanksCache()
		env.roster = {}
		assert.is_nil(Guild:GetBanks())
	end)
end)

describe("Guild:IsBank", function()
	local Guild
	before_each(function()
		env.reset()
		Guild = loadGuild()
		Guild.memberRoster, Guild.banksCache = {}, nil
	end)

	it("is true for a tagged member", function()
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		assert.is_true(Guild:IsBank("Banker-Testrealm"))
	end)

	it("accepts an unqualified name", function()
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		assert.is_true(Guild:IsBank("Banker"))
	end)

	it("is false for an untagged member", function()
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		env.addGuildMember("Regular-Testrealm", { note = "" })
		assert.is_false(Guild:IsBank("Regular-Testrealm"))
	end)

	it("is false for nil", function()
		assert.is_false(Guild:IsBank(nil))
	end)

	it("prefers the O(1) memberRoster entry when one exists", function()
		Guild.memberRoster = { ["Banker-Testrealm"] = { name = "Banker-Testrealm", isBank = true } }
		assert.is_true(Guild:IsBank("Banker-Testrealm"))
	end)
end)

-- VIEWBANK-001: a view-only banker stays visible everywhere but cannot be requested from.
describe("Guild:IsViewOnlyBank", function()
	local Guild
	before_each(function()
		env.reset()
		Guild = loadGuild()
		Guild.memberRoster, Guild.banksCache = {}, nil
	end)

	for _, marker in ipairs({ "viewonly", "view-only", "view only", "readonly", "read-only", "gbankro" }) do
		it("recognises the '" .. marker .. "' marker", function()
			env.addGuildMember("Raidbank-Testrealm", { note = "gbank " .. marker })
			assert.is_true(Guild:IsViewOnlyBank("Raidbank-Testrealm"))
		end)
	end

	it("is case-insensitive", function()
		env.addGuildMember("Raidbank-Testrealm", { note = "GBANK VIEWONLY" })
		assert.is_true(Guild:IsViewOnlyBank("Raidbank-Testrealm"))
	end)

	it("is false for a plain banker", function()
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		assert.is_false(Guild:IsViewOnlyBank("Banker-Testrealm"))
	end)

	it("is false for nil", function()
		assert.is_false(Guild:IsViewOnlyBank(nil))
	end)

	it("reads the flag from memberRoster when present", function()
		Guild.memberRoster = {
			["Raidbank-Testrealm"] = { name = "Raidbank-Testrealm", isBank = true, viewOnly = true },
		}
		assert.is_true(Guild:IsViewOnlyBank("Raidbank-Testrealm"))
	end)
end)

describe("Guild:RebuildBankerRoster", function()
	local Guild
	before_each(function()
		env.reset()
		Guild = loadGuild()
		Guild.memberRoster, Guild.banksCache = {}, nil
		Guild.Info = { name = "Testguild", roster = { alts = {} }, alts = {} }
	end)

	it("records the banker list on the roster", function()
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		Guild:RebuildBankerRoster()
		assert.same({ "Banker-Testrealm" }, Guild.Info.roster.alts)
	end)

	it("creates a stub alt record for a new banker", function()
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		Guild:RebuildBankerRoster()
		assert.is_not_nil(Guild.Info.alts["Banker-Testrealm"])
		assert.equal(0, Guild.Info.alts["Banker-Testrealm"].version)
	end)

	-- ROSTER-002: a stub left behind by an ex-banker shows as a permanent "HLR pending" entry.
	it("removes an empty stub for someone who is no longer a banker", function()
		Guild.Info.alts["ExBanker-Testrealm"] = {
			name = "ExBanker-Testrealm", version = 0, inventoryHash = 0, mailHash = 0, items = {},
		}
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		Guild:RebuildBankerRoster()
		assert.is_nil(Guild.Info.alts["ExBanker-Testrealm"])
	end)

	it("keeps real data for someone who is no longer a banker", function()
		Guild.Info.alts["ExBanker-Testrealm"] = {
			name = "ExBanker-Testrealm", version = 500, inventoryHash = 99,
			items = { { ID = 858, Count = 1 } },
		}
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		Guild:RebuildBankerRoster()
		assert.is_not_nil(Guild.Info.alts["ExBanker-Testrealm"],
			"an ex-banker's real inventory data was deleted; only zero-stubs may be removed")
	end)

	it("keeps memberRoster's isBank flag in step", function()
		Guild.memberRoster = { ["Banker-Testrealm"] = { name = "Banker-Testrealm", isBank = false } }
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		Guild:RebuildBankerRoster()
		assert.is_true(Guild.memberRoster["Banker-Testrealm"].isBank)
	end)

	-- BROWSE F1 (Peer Review, 2026-09-12): the embedded Requests tab re-checks its role HERE, on the
	-- event that propagates a note edit -- and only when the list actually moved.
	it("tells the Requests body when the banker list changed, and not otherwise", function()
		local calls = 0
		TOGBankClassic_UI_Requests = { OnBankerRosterChanged = function() calls = calls + 1 end }
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		Guild:RebuildBankerRoster()
		assert.equal(1, calls, "a changed banker list did not reach the Requests body (F1)")
		Guild:RebuildBankerRoster()
		assert.equal(1, calls, "an unchanged list re-checked the role anyway")
		TOGBankClassic_UI_Requests = nil
	end)

	it("keeps memberRoster's viewOnly flag in step", function()
		Guild.memberRoster = { ["Raidbank-Testrealm"] = { name = "Raidbank-Testrealm", isBank = false } }
		env.addGuildMember("Raidbank-Testrealm", { note = "gbank viewonly" })
		Guild:RebuildBankerRoster()
		assert.is_true(Guild.memberRoster["Raidbank-Testrealm"].viewOnly)
	end)
end)

-- INV2-RETIRE-003: content is the V2 store, full stop. The three examples that stood here asserted
-- "true when aggregated / bank-only / mail-only LEGACY items are present"; that is the content the
-- client cannot serve (CanServe is `#records > 0`), so saying yes for it is the Peer Review F1
-- defect -- accept a request, ship nothing -- reintroduced.
describe("Guild:HasAltContent", function()
	local Guild
	before_each(function()
		env.reset(); Guild = loadGuild()
		env.freshV2()
		Guild.Info = { name = "Testguild", alts = {} }
	end)

	it("is false for nil", function()
		assert.falsy(Guild:HasAltContent(nil, "X-Testrealm"))
	end)

	it("is false for an empty stub", function()
		assert.falsy(Guild:HasAltContent({ version = 0 }, "X-Testrealm"))
	end)

	it("is true when the V2 store holds records for the alt", function()
		env.holdV2("Testguild", "X-Testrealm", { { 858, 1 } })
		assert.truthy(Guild:HasAltContent(Guild.Info.alts["X-Testrealm"], "X-Testrealm"))
	end)

	it("is true from the V2 store even when the legacy record is absent entirely", function()
		env.holdV2("Testguild", "X-Testrealm", { { 858, 1 } })
		assert.truthy(Guild:HasAltContent(nil, "X-Testrealm"))
	end)

	it("is FALSE for legacy-only content -- rows the client could not serve", function()
		assert.falsy(Guild:HasAltContent({ items = { { ID = 858, Count = 1 } } }, "X-Testrealm"))
		assert.falsy(Guild:HasAltContent({ bank = { items = { { ID = 858, Count = 1 } } } }, "X-Testrealm"))
		assert.falsy(Guild:HasAltContent({ mail = { items = { { ID = 858, Count = 1 } } } }, "X-Testrealm"))
	end)

	it("reads the name off the record when no name is passed", function()
		env.holdV2("Testguild", "X-Testrealm", { { 858, 1 } })
		assert.truthy(Guild:HasAltContent({ name = "X-Testrealm" }))
	end)
end)

describe("Guild:GetVersion", function()
	local Guild
	before_each(function()
		env.reset()
		Guild = loadGuild()
		Guild.memberRoster, Guild.banksCache = {}, nil
		Guild.Info = { name = "Testguild", alts = {} }
	end)

	-- PROTO-001. Stripping the dots turns the version into a plain integer whose magnitude
	-- depends on DIGIT COUNT rather than on precedence, so a version with more digits always
	-- wins. "1.10.0" becomes 1100 and "2.0.0" becomes 200 — a major-version bump reads as a
	-- downgrade. (1.3.2 vs 1.10.0 happens to come out right, which is what makes this easy to
	-- miss; the inversion only shows up once the digit counts differ across a boundary.)
	local function numericVersion(v)
		_G.GetAddOnMetadata = function() return v end
		return Guild:GetVersion().addon
	end

	it("ranks a major bump above a two-digit minor", function()
		local v1_10_0 = numericVersion("1.10.0")
		local v2_0_0  = numericVersion("2.0.0")
		assert.truthy(v2_0_0 > v1_10_0,
			"2.0.0 encoded as " .. tostring(v2_0_0) .. " but 1.10.0 encoded as " ..
			tostring(v1_10_0) .. ", so a major-version bump reads as a DOWNGRADE. Stripping the " ..
			"dots makes ordering depend on digit count (audit PROTO-001)")
	end)

	it("ranks a two-digit minor above a one-digit minor", function()
		local v1_9_0  = numericVersion("1.9.0")
		local v1_10_0 = numericVersion("1.10.0")
		assert.truthy(v1_10_0 > v1_9_0,
			"1.10.0 encoded as " .. tostring(v1_10_0) .. ", 1.9.0 as " .. tostring(v1_9_0) ..
			" (audit PROTO-001)")
	end)

	it("reports zero for an unpackaged dev build", function()
		_G.GetAddOnMetadata = function() return "@project-version@" end
		assert.equal(0, Guild:GetVersion().addon)
	end)

	-- WIRE-SKEW-002: a RELEASED client's Version is the packager's substitution of
	-- @project-version@, which is the WHOLE git tag. An anchored match read every released peer
	-- as a dev build, and the data-leg gate never refused one.
	it("reads the version out of the packager's tag-shaped string", function()
		assert.equal(numericVersion("1.4.1"), numericVersion("TOGBankClassic-v1.4.1"))
		assert.truthy(numericVersion("TOGBankClassic-v1.4.1") > 0, "a released build encoded as a dev build")
		assert.truthy(numericVersion("TOGBankClassic-v1.5.0") > numericVersion("TOGBankClassic-v1.4.1"))
		assert.equal(0, numericVersion("dev"))
	end)

	it("excludes an alt with no content from the broadcast", function()
		env.addGuildMember("Banker-Testrealm", { note = "gbank" })
		Guild.Info.alts["Banker-Testrealm"] = { version = 100, inventoryHash = 5, items = {} }
		assert.is_nil(Guild:GetVersion().alts["Banker-Testrealm"],
			"a stub entry was broadcast, which makes peers send empty deltas back")
	end)

	it("excludes an alt who is not a banker in the current guild", function()
		Guild.Info.alts["Stranger-Testrealm"] = {
			version = 100, inventoryHash = 5, items = { { ID = 858 } },
		}
		assert.is_nil(Guild:GetVersion().alts["Stranger-Testrealm"],
			"data from another guild's banker leaked into the version broadcast")
	end)
end)
