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

	it("keeps memberRoster's viewOnly flag in step", function()
		Guild.memberRoster = { ["Raidbank-Testrealm"] = { name = "Raidbank-Testrealm", isBank = false } }
		env.addGuildMember("Raidbank-Testrealm", { note = "gbank viewonly" })
		Guild:RebuildBankerRoster()
		assert.is_true(Guild.memberRoster["Raidbank-Testrealm"].viewOnly)
	end)
end)

describe("Guild:HasAltContent", function()
	local Guild
	before_each(function() env.reset(); Guild = loadGuild() end)

	it("is false for nil", function()
		assert.falsy(Guild:HasAltContent(nil, "X"))
	end)

	it("is false for an empty stub", function()
		assert.falsy(Guild:HasAltContent({ version = 0, items = {} }, "X"))
	end)

	it("is true when aggregated items are present", function()
		assert.truthy(Guild:HasAltContent({ items = { { ID = 858 } } }, "X"))
	end)

	it("is true when only bank items are present", function()
		assert.truthy(Guild:HasAltContent({ bank = { items = { { ID = 858 } } } }, "X"))
	end)

	it("is true when only mail items are present", function()
		assert.truthy(Guild:HasAltContent({ mail = { items = { { ID = 858 } } } }, "X"))
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
