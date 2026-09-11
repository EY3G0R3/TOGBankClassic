-- TooltipBankerInfo.lua — the "Bankers:" block, and the public renderer behind it.
--
-- The renderer is public because our own OnTooltipSetItem hook only fires for a tooltip carrying a
-- real item, and TOGProfessionMaster draws recipe tooltips that carry none. Exposing it is
-- DEPENDENCY_CONTRACTS.md §1; these specs pin the contract it promised — returns whether it added
-- lines, and never raises whatever it is handed — so a caller that is mid-tooltip with no item
-- context cannot be taken down by us.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

-- Captures what was drawn, in order, without depending on the real tooltip's layout.
local function fakeTooltip()
	local t = { lines = {}, doubles = {} }
	function t:AddLine(text, r, g, b, wrap)
		self.lines[#self.lines + 1] = { text = text, r = r, g = g, b = b, wrap = wrap }
	end
	function t:AddDoubleLine(left, right)
		self.doubles[#self.doubles + 1] = { left = left, right = right }
	end
	return t
end

--- Install alts, using the REAL Guild module.
---
--- INV2 step 7a: this used to build a fake Guild table with just `Info` and
--- `IsInCurrentGuildRoster`. Once the item rows started coming from `Guild:GetAltItems`, a fake
--- missing that method took every example down -- and had the fake merely *supplied* one, these
--- specs would have been asserting against a stand-in for the exact function that decides which
--- store the tooltip reads. That is the CMD-001 trap. Loading the real module means these examples
--- exercise the real accessor, including its inventoryV2 branch, for free.
---
--- Only `IsInCurrentGuildRoster` is overridden, because it reaches for roster state these specs
--- have no business standing up.
---
--- TOOLTIP-002: BANKER STATUS IS **NOT** OVERRIDDEN, and that is deliberate. The tooltip's question
--- is now "is this character still a banker", which is decided by whether `gbank` appears in their
--- note -- so these examples build a REAL guild roster with real notes and let the real
--- `Guild:IsBank` read it. Stubbing IsBank here would stand a fake in front of the exact function
--- the fix turns on, which is the CMD-001 trap this file's header already describes.
---
--- Every alt is given a `gbank` note by default, so the pre-existing examples keep meaning what they
--- meant. `notes` overrides that per alt -- "" for an ex-banker, "gbank viewonly" for VIEWBANK-001.
---
--- THE ROSTER IS BUILT THROUGH LibGuildRoster, WHICH IS THE PRODUCTION PATH. Guild:IsBank reads
--- memberRoster.isBank, and since v1.4.0 that table is populated by
--- Guild:_RefreshFromRosterLib -- it takes `publicNote`/`officerNote` from the LIBRARY and does the
--- `gbank` find itself (Guild.lua:2117-2120). The legacy GetGuildRosterInfo scan is only the
--- fallback for when the library is absent or not ready.
---
--- An earlier version of this helper drove that FALLBACK instead, by leaving memberRoster empty. It
--- would have passed while never once exercising the code the addon actually runs -- the same shape
--- as the CMD-001 trap in this file's header, one level up: not a stubbed function, but a real
--- function reached down a path no player takes.
--- @param alts table altName -> stored record
--- @param rosterMembers table|nil altName -> true (nil means everyone is in the guild)
--- @param notes table|nil altName -> note string (default "gbank")
local function installGuild(alts, rosterMembers, notes)
	TOGBankClassic_Guild.Info = { name = "Testguild", alts = alts }
	TOGBankClassic_Guild.IsInCurrentGuildRoster = function(_, name)
		if not rosterMembers then return true end
		return rosterMembers[name] == true
	end

	for altName in pairs(alts) do
		env.addGuildMember(altName, { note = (notes and notes[altName]) or "gbank" })
	end
	env.readyGuildRoster(env.freshGuildRoster())
	TOGBankClassic_Guild.memberRoster = nil
	TOGBankClassic_Guild.banksCache = nil
	TOGBankClassic_Guild:RefreshOnlineCache()
	assert.is_truthy(TOGBankClassic_Guild.memberRoster
		and next(TOGBankClassic_Guild.memberRoster),
		"precondition: the roster library produced no members, so every IsBank answer below " ..
		"would be a fallback result rather than the path the addon runs")
end

describe("TooltipBankerInfo:AppendTo", function()
	local TBI
	before_each(function()
		env.reset(); env.stubOutput()
		env.loadModules({
			"Modules/Constants.lua",
			"Modules/Switches.lua",
			-- RefreshOnlineCache records a perf timing on both its paths, so the real module has to
			-- be here; without it the roster refresh dies indexing a nil Performance.
			"Modules/Performance.lua",
			"Modules/Item.lua",
			"Modules/Inventory/Record.lua",
			"Modules/Inventory/Resolve.lua",
			"Modules/Inventory/Store.lua",
			"Modules/Guild.lua",
			"Modules/TooltipBankerInfo.lua",
		})
		TOGBankClassic_Database = { db = { global = {} } }
		TOGBankClassic_Inventory_Store:Init({ faction = {} })
		TBI = TOGBankClassic_TooltipBankerInfo
	end)

	it("draws the block and reports that it did", function()
		installGuild({ ["Bank1-Realm"] = { items = { { ID = 2589, Count = 20 } } } })
		local tip = fakeTooltip()
		assert.is_true(TBI:AppendTo(tip, 2589))
		assert.equal("TOGBankClassic", tip.lines[2].text)
		assert.equal("Bankers:", tip.lines[3].text)
		assert.equal(1, #tip.doubles)
		assert.equal("Bank1", tip.doubles[1].left)
		assert.equal("20", tip.doubles[1].right)
	end)

	it("passes the wrap flag on every line it appends", function()
		-- Default is false, and an unwrapped line stretches the shared GameTooltip
		-- frame past the engine's preset, dragging every other addon out with it.
		installGuild({ ["Bank1-Realm"] = { items = { { ID = 2589, Count = 20 } } } })
		local tip = fakeTooltip()
		TBI:AppendTo(tip, 2589)
		for i, line in ipairs(tip.lines) do
			if line.text ~= " " then
				assert.is_true(line.wrap, "line " .. i .. " (" .. tostring(line.text) .. ") did not wrap")
			end
		end
	end)

	it("sums every stack one banker holds", function()
		installGuild({ ["Bank1-Realm"] = { items = {
			{ ID = 2589, Count = 20 }, { ID = 999, Count = 5 }, { ID = 2589, Count = 20 },
		} } })
		local tip = fakeTooltip()
		TBI:AppendTo(tip, 2589)
		assert.equal("40", tip.doubles[1].right)
	end)

	it("counts an entry with no Count as one, not zero", function()
		installGuild({ ["Bank1-Realm"] = { items = { { ID = 2589 } } } })
		local tip = fakeTooltip()
		assert.is_true(TBI:AppendTo(tip, 2589))
		assert.equal("1", tip.doubles[1].right)
	end)

	it("orders by stock descending, then by name", function()
		installGuild({
			["Abe-Realm"]  = { items = { { ID = 2589, Count = 5 } } },
			["Zed-Realm"]  = { items = { { ID = 2589, Count = 9 } } },
			["Bob-Realm"]  = { items = { { ID = 2589, Count = 5 } } },
		})
		local tip = fakeTooltip()
		TBI:AppendTo(tip, 2589)
		assert.equal("Zed", tip.doubles[1].left)
		assert.equal("Abe", tip.doubles[2].left)
		assert.equal("Bob", tip.doubles[3].left)
	end)

	it("ignores an alt that is no longer in the guild roster", function()
		installGuild({
			["Abe-Realm"]   = { items = { { ID = 2589, Count = 5 } } },
			["Gone-Realm"]  = { items = { { ID = 2589, Count = 99 } } },
		}, { ["Abe-Realm"] = true })
		local tip = fakeTooltip()
		TBI:AppendTo(tip, 2589)
		assert.equal(1, #tip.doubles)
		assert.equal("Abe", tip.doubles[1].left)
	end)

	-- TOOLTIP-002, reported from a live guild: "if I mouse-over an item that said banker used to
	-- have, the tooltip says they have it. They do not have gbank in their note." It survived a
	-- reload, because nothing was stale -- the data is stored and correct, and the tooltip simply
	-- never asked whether the character was still a banker.
	it("ignores an alt whose gbank note was removed, even though their data is still stored",
		function()
			installGuild({
				["Abe-Realm"]      = { items = { { ID = 2589, Count = 5 } } },
				["ExBanker-Realm"] = { items = { { ID = 2589, Count = 99 } } },
			}, nil, { ["ExBanker-Realm"] = "" })
			local tip = fakeTooltip()
			TBI:AppendTo(tip, 2589)
			assert.equal(1, #tip.doubles,
				"an ex-banker was still listed -- their stored inventory outlives their gbank note " ..
				"by design, so the tooltip has to ask Guild:IsBank rather than trust info.alts")
			assert.equal("Abe", tip.doubles[1].left)
		end)

	it("reports false when the ONLY holder is no longer a banker", function()
		installGuild({
			["ExBanker-Realm"] = { items = { { ID = 2589, Count = 99 } } },
		}, nil, { ["ExBanker-Realm"] = "" })
		local tip = fakeTooltip()
		assert.is_false(TBI:AppendTo(tip, 2589),
			"the block was drawn with no eligible banker in it")
		assert.equal(0, #tip.lines)
	end)

	-- VIEWBANK-001 draws the line the other way: a view-only banker is visible everywhere and merely
	-- not requestable, so their stock belongs here. The gate is IsBank, NOT `IsBank and not
	-- IsViewOnlyBank`, and this is what stops someone "tightening" it later.
	it("still lists a VIEW-ONLY banker, who is visible but not requestable", function()
		installGuild({ ["Viewer-Realm"] = { items = { { ID = 2589, Count = 7 } } } },
			nil, { ["Viewer-Realm"] = "gbank viewonly" })
		assert.is_true(TOGBankClassic_Guild:IsViewOnlyBank("Viewer-Realm"),
			"precondition: the note was not read as view-only, so this proves nothing")
		local tip = fakeTooltip()
		assert.is_true(TBI:AppendTo(tip, 2589),
			"a view-only banker was dropped from the tooltip -- VIEWBANK-001 makes them visible " ..
			"everywhere and only blocks REQUESTS")
		assert.equal("Viewer", tip.doubles[1].left)
	end)

	it("draws nothing and reports false when no banker holds the item", function()
		installGuild({ ["Bank1-Realm"] = { items = { { ID = 999, Count = 20 } } } })
		local tip = fakeTooltip()
		assert.is_false(TBI:AppendTo(tip, 2589))
		assert.equal(0, #tip.lines)
	end)

	it("draws nothing for a banker whose stacks total zero", function()
		installGuild({ ["Bank1-Realm"] = { items = { { ID = 2589, Count = 0 } } } })
		local tip = fakeTooltip()
		assert.is_false(TBI:AppendTo(tip, 2589))
		assert.equal(0, #tip.lines)
	end)

	-- Three distinct absences, because a mid-tooltip caller can hit any of them: the module not
	-- loaded at all, loaded with no guild yet, and a guild with no alts. installGuild is not used
	-- here -- it now writes into the real Guild table, which is the thing being taken away.
	it("reports false rather than raising when the bank data is absent", function()
		local realGuild = TOGBankClassic_Guild
		local tip = fakeTooltip()

		_G.TOGBankClassic_Guild = nil
		assert.is_false(TBI:AppendTo(tip, 2589))

		_G.TOGBankClassic_Guild = { IsInCurrentGuildRoster = function() return true end }
		assert.is_false(TBI:AppendTo(tip, 2589))

		_G.TOGBankClassic_Guild = { Info = {}, IsInCurrentGuildRoster = function() return true end }
		assert.is_false(TBI:AppendTo(tip, 2589))

		assert.equal(0, #tip.lines)
		_G.TOGBankClassic_Guild = realGuild
	end)

	it("reports false rather than raising on arguments a mid-tooltip caller may hold", function()
		installGuild({ ["Bank1-Realm"] = { items = { { ID = 2589, Count = 20 } } } })
		assert.is_false(TBI:AppendTo(nil, 2589))
		assert.is_false(TBI:AppendTo({}, 2589))
		assert.is_false(TBI:AppendTo(fakeTooltip(), nil))
		assert.is_false(TBI:AppendTo(fakeTooltip(), "2589"))
	end)

	it("leaves a tooltip it declines exactly as it found it", function()
		installGuild({ ["Bank1-Realm"] = { items = { { ID = 999, Count = 20 } } } })
		local tip = fakeTooltip()
		tip:AddLine("someone else's line")
		TBI:AppendTo(tip, 2589)
		assert.equal(1, #tip.lines)
		assert.equal("someone else's line", tip.lines[1].text)
	end)
end)

describe("TooltipBankerInfo's own hook", function()
	local TBI
	before_each(function()
		env.reset(); env.stubOutput()
		env.loadFile("Modules/TooltipBankerInfo.lua")
		TBI = TOGBankClassic_TooltipBankerInfo
	end)

	-- One implementation of the layout, reached two ways. If the hook grew its own copy this
	-- would still pass on the hook and silently drift from what TOGProfessionMaster renders.
	local function fireHook(tip)
		local handler
		local realHook = GameTooltip.HookScript
		GameTooltip.HookScript = function(_, script, fn)
			if script == "OnTooltipSetItem" then handler = fn end
		end
		TBI:Initialize()
		GameTooltip.HookScript = realHook
		assert.is_function(handler)
		handler(tip)
	end

	it("renders through AppendTo, so there is only one layout", function()
		installGuild({ ["Bank1-Realm"] = { items = { { ID = 2589, Count = 20 } } } })
		local tip = fakeTooltip()
		function tip:GetItem()
			return "Copper Bar", "|cffffffff|Hitem:2589:0:0:0:0:0:0|h[Copper Bar]|h|r"
		end
		local calledWith
		local real = TBI.AppendTo
		TBI.AppendTo = function(self, t, id) calledWith = id; return real(self, t, id) end
		fireHook(tip)
		TBI.AppendTo = real
		assert.equal(2589, calledWith)
		assert.equal("Bankers:", tip.lines[3].text)
	end)

	it("does nothing for a tooltip carrying no item link", function()
		installGuild({ ["Bank1-Realm"] = { items = { { ID = 2589, Count = 20 } } } })
		local tip = fakeTooltip()
		function tip:GetItem() return nil, nil end
		fireHook(tip)  -- a raise here fails the test, which is the assertion
		assert.equal(0, #tip.lines)
	end)

	it("does nothing for a link that carries no parseable item id", function()
		installGuild({ ["Bank1-Realm"] = { items = { { ID = 2589, Count = 20 } } } })
		local tip = fakeTooltip()
		function tip:GetItem() return "Thing", "|cffffffff|Hspell:2589|h[Thing]|h|r" end
		fireHook(tip)  -- a raise here fails the test, which is the assertion
		assert.equal(0, #tip.lines)
	end)
end)
