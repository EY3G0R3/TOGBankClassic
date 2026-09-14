-- HIDE-001 -- a banker hides items from the guild.
--
-- Discord (Vishiswaz, 2026-08-25): "right click and hide or unhide items in this interface while on
-- a gbank toon, which will change whether or not the item is transmitted as being in the inventory
-- when syncing ... indicated in this interface either with a red glow or by being turned grey
-- scale or a red dot". The operator: "the users want bankers to be able to right click on items
-- and to be able to show/hide them from the bank list".
--
-- The property that makes this safe is WHERE the split happens: at the store write, not on the
-- wire. A hidden row is absent from GetAltRecords, so it is absent from the content hash, the
-- canon, the chain, the snapshot, the log and every viewer -- there is no second code path that
-- could forget to filter. The hidden rows are kept beside the visible ones, per source, so the
-- banker can unhide away from the vault and their own tab can draw them greyed.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local Record, Store

local function stubItemDB(items)
	LibStub.libs["LibItemDB-1.0"] = {
		HasItem = function(_, id) return items[id] ~= nil end,
		GetInfo = function(_, id)
			local d = items[id]
			if not d then return nil end
			return d.name, d.quality, d.class, d.subClass, d.equipLoc, d.itemLevel
		end,
		GetSuffixLink = function(_, id) return "|cffffffff|Hitem:" .. id .. "|h[" .. items[id].name .. "]|h|r" end,
		GetRequiredLevel = function(_, id) return items[id] and items[id].reqLevel or 0 end,
	}
	LibStub.minors["LibItemDB-1.0"] = 15
end

local ITEMS = {
	[6948] = { name = "Hearthstone", quality = 1, class = 15, subClass = 0, equipLoc = "", itemLevel = 1, reqLevel = 0 },
	[858]  = { name = "Minor Healing Potion", quality = 1, class = 0, subClass = 0, equipLoc = "", itemLevel = 5, reqLevel = 0 },
	[2589] = { name = "Linen Cloth", quality = 1, class = 7, subClass = 5, equipLoc = "", itemLevel = 5, reqLevel = 0 },
}

local function loadStore()
	env.stubOutput()
	stubItemDB(ITEMS)
	env.loadFile("Modules/Inventory/Record.lua")
	env.loadFile("Modules/Inventory/Resolve.lua")
	env.loadFile("Modules/Inventory/Store.lua")
	Record = TOGBankClassic_Inventory_Record
	Store  = TOGBankClassic_Inventory_Store
	TOGBankClassicInvDB = nil
	Store.db = nil
	Store:Init()
	Store:InvalidateView()
end

local G, BOB = "Testguild", "Bob-Testrealm"
local HS = "6948:0:0"   -- Record.key of a plain hearthstone

local function ids(records)
	local out = {}
	for _, rec in ipairs(records) do out[#out + 1] = Record.id(rec) end
	table.sort(out)
	return out
end

describe("HIDE-001: the store splits hidden rows at the write", function()
	before_each(function() env.reset(); loadStore() end)

	it("keeps a hidden key out of every read a viewer uses, and in the hidden set", function()
		Store:SetAltSources(G, BOB, {
			bank = { Record.new(6948, 1), Record.new(858, 5) },
			bags = { Record.new(2589, 20) },
		}, 0, { [HS] = true })
		assert.same({ 858, 2589 }, ids(Store:GetAltRecords(G, BOB)), "the hearthstone is still in the record set")
		assert.same({ 6948 }, ids(Store:GetAltHiddenRecords(G, BOB)))
		assert.equal(0, Store:GetAltItemTotal(G, BOB, 6948), "the totals index counts a hidden item")
		assert.same({}, Store:FindItem(G, 6948), "FindItem names a banker for a hidden item")
		for _, row in ipairs(Store:GetAltView(G, BOB)) do
			assert.is_not.equal(6948, row.ID, "the UI view (Search, tooltips, TPM) carries the hidden row")
		end
		local hidden = Store:GetAltHiddenView(G, BOB)
		assert.equal(1, #hidden)
		assert.equal(6948, hidden[1].ID)
		assert.is_true(hidden[1].Hidden)
		assert.equal("Hearthstone", hidden[1].Info.name, "the hidden view is not resolved like the visible one")
		-- On disk: the visible bank bucket has one row, the hidden bank bucket the other.
		local alt = TOGBankClassicInvDB.faction[G].alts[BOB]
		assert.equal(1, #alt.sources.bank)
		assert.equal(1, #alt.hidden.bank)
		assert.is_nil(alt.hidden.bags, "an empty hidden bucket was written")
	end)

	it("writes no hidden table at all when nothing is hidden (nil or empty keys)", function()
		Store:SetAltSources(G, BOB, { bags = { Record.new(2589, 20) } }, 0, nil)
		assert.is_nil(TOGBankClassicInvDB.faction[G].alts[BOB].hidden)
		Store:SetAltSources(G, BOB, { bags = { Record.new(2589, 20) } }, 0, {})
		assert.is_nil(TOGBankClassicInvDB.faction[G].alts[BOB].hidden)
		assert.same({}, Store:GetAltHiddenRecords(G, BOB))
		assert.same({}, Store:GetAltHiddenView(G, BOB))
	end)

	-- The vault can only be read at a banker. Hiding a vault item from anywhere else re-partitions
	-- the bucket carried forward from the last visit; so does showing it again.
	it("re-splits a carried-forward vault bucket, so hiding and showing work away from the bank", function()
		Store:SetAltSources(G, BOB, {
			bank = { Record.new(6948, 1), Record.new(858, 5) },
			bags = { Record.new(2589, 20) },
		}, 0, nil)
		assert.same({ 858, 2589, 6948 }, ids(Store:GetAltRecords(G, BOB)))

		-- Away from the vault: only bags are supplied, and the hearthstone is now hidden.
		Store:SetAltSources(G, BOB, { bags = { Record.new(2589, 18) } }, 0, { [HS] = true })
		assert.same({ 858, 2589 }, ids(Store:GetAltRecords(G, BOB)), "the carried vault bucket was not re-split")
		assert.same({ 6948 }, ids(Store:GetAltHiddenRecords(G, BOB)))
		assert.equal(18, Store:GetAltItemTotal(G, BOB, 2589), "the fresh bags write was lost")
		assert.equal(5, Store:GetAltItemTotal(G, BOB, 858), "the carried vault row was lost")

		-- Still away from the vault: shown again. The row comes back from the hidden bucket.
		Store:SetAltSources(G, BOB, { bags = { Record.new(2589, 18) } }, 0, {})
		assert.same({ 858, 2589, 6948 }, ids(Store:GetAltRecords(G, BOB)), "the unhidden vault row did not come back")
		assert.same({}, Store:GetAltHiddenRecords(G, BOB))
		assert.is_nil(TOGBankClassicInvDB.faction[G].alts[BOB].hidden)
	end)

	it("hides every variant only by its own key: two suffix variants split independently", function()
		Store:SetAltSources(G, BOB, {
			bags = { Record.new(2589, 1, 863), Record.new(2589, 1, 865) },
		}, 0, { ["2589:863:0"] = true })
		local shown = Store:GetAltRecords(G, BOB)
		assert.equal(1, #shown)
		assert.equal(865, Record.suffix(shown[1]))
		local hidden = Store:GetAltHiddenRecords(G, BOB)
		assert.equal(1, #hidden)
		assert.equal(863, Record.suffix(hidden[1]))
	end)

	-- A received delivery is written by SetAltRecords with no hidden list. It must never carry a
	-- hidden bucket -- and it must never resurrect one this client happened to hold before.
	it("leaves the receive path (SetAltRecords) untouched: no hidden bucket, nothing carried", function()
		Store:SetAltSources(G, BOB, { bank = { Record.new(6948, 1) } }, 0, { [HS] = true })
		assert.equal(1, #Store:GetAltHiddenRecords(G, BOB))
		Store:SetAltRecords(G, BOB, { Record.new(858, 3) }, 10)
		assert.same({ 858 }, ids(Store:GetAltRecords(G, BOB)))
		assert.same({}, Store:GetAltHiddenRecords(G, BOB))
		assert.is_nil(TOGBankClassicInvDB.faction[G].alts[BOB].hidden)
	end)

	it("drops the caches on a write that only changes the hidden list", function()
		Store:SetAltSources(G, BOB, { bags = { Record.new(6948, 1), Record.new(858, 5) } }, 0, nil)
		assert.equal(2, #Store:GetAltView(G, BOB))
		assert.equal(1, Store:GetAltItemTotal(G, BOB, 6948))
		Store:SetAltSources(G, BOB, {}, 0, { [HS] = true })
		assert.equal(1, #Store:GetAltView(G, BOB), "the view cache survived a hide")
		assert.equal(0, Store:GetAltItemTotal(G, BOB, 6948), "the totals cache survived a hide")
	end)
end)

-- ─── The scan carries the banker's list, and a toggle re-reads and republishes ──────────────

describe("HIDE-001: Bank:SetHidden re-reads, and the scan publishes without the hidden rows", function()
	local Bank
	local scans

	before_each(function()
		env.reset()
		env.stubOutput()
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/Item.lua")
		env.loadFile("Modules/Bank.lua")
		env.loadModules({
			"Modules/Inventory/Record.lua",
			"Modules/Inventory/Resolve.lua",
			"Modules/Inventory/Store.lua",
			"Modules/Inventory/Scan.lua",
		})
		Bank = TOGBankClassic_Bank
		Record, Store = TOGBankClassic_Inventory_Record, TOGBankClassic_Inventory_Store
		Store:Init({ faction = {} })
		TOGBankClassic_Guild = {
			Info = { name = G, alts = {} },
			GetNormalizedPlayer = function() return BOB end,
			NormalizeName = function(_, n) return n and (n:find("-") and n or n .. "-Testrealm") or nil end,
			GetBanks = function() return { BOB } end,
		}
		TOGBankClassic_Options  = { GetBankEnabled = function() return true end, db = { char = {} } }
		TOGBankClassic_Database = {}
		TOGBankClassic_MailInventory = { hasUpdated = false }
		-- HIDE-SHARE-001: MintVersion shares through Events; in a full-suite run the REAL Events
		-- module survives from an earlier file and reaches for Guild:GetGuild, which this stub lacks.
		TOGBankClassic_Events = { SyncDeltaVersion = function() end }
		TOGBankClassic_P2PSession = nil
		-- A content hash that depends on the records, so "hiding changes what is published" is a
		-- real assertion rather than one the constant stub would pass by construction.
		TOGBankClassic_Core = env.coreHashStub(nil, {
			ComputeInventoryHash = function(_, records)
				local keys = {}
				for _, rec in ipairs(records or {}) do keys[#keys + 1] = Record.key(rec) .. "x" .. Record.count(rec) end
				table.sort(keys)
				return table.concat(keys, ",")
			end,
		})
		scans = 0
		local realScan = Bank.Scan
		Bank.Scan = function(self) scans = scans + 1; return realScan(self) end
		Bank.hasUpdated = true
		Bank.eventsRegistered = false
		env.defineItem(6948, { name = "Hearthstone", class = 15 })
		env.defineItem(858,  { name = "Minor Healing Potion", class = 0 })
		env.setBag(0, 4, { { id = 6948, count = 1 }, { id = 858, count = 5 } })
	end)

	it("answers an empty list before the options DB exists, and never errors", function()
		TOGBankClassic_Options.db = nil
		assert.same({}, Bank:HiddenKeys())
		assert.is_false(Bank:IsHidden(6948, 0, 0))
		assert.is_false(Bank:SetHidden(6948, 0, 0, true), "a hide with no DB to write reported success")
		assert.equal(0, scans)
	end)

	it("hides on the scan: the store, and therefore the hash, no longer carry the item", function()
		Bank:Scan()
		local before = TOGBankClassic_Guild.Info.alts[BOB].inventoryContentHash
		assert.same({ 858, 6948 }, ids(Store:GetAltRecords(G, BOB)))

		assert.is_true(Bank:SetHidden(6948, 0, 0, true))
		assert.is_true(TOGBankClassic_Options.db.char.hiddenItems[HS])
		assert.is_true(Bank:IsHidden(6948, 0, 0))
		assert.equal(2, scans, "SetHidden did not re-scan")
		assert.same({ 858 }, ids(Store:GetAltRecords(G, BOB)), "the hidden item is still in the published records")
		assert.same({ 6948 }, ids(Store:GetAltHiddenRecords(G, BOB)))
		local after = TOGBankClassic_Guild.Info.alts[BOB].inventoryContentHash
		assert.is_not.equal(before, after, "the content hash did not change, so the guild would never be told")

		-- Show it again: back in the records, hash back to what it was.
		assert.is_true(Bank:SetHidden(6948, 0, 0, false))
		assert.is_nil(TOGBankClassic_Options.db.char.hiddenItems[HS], "an unhidden key was left as false instead of removed")
		assert.same({ 858, 6948 }, ids(Store:GetAltRecords(G, BOB)))
		assert.equal(before, TOGBankClassic_Guild.Info.alts[BOB].inventoryContentHash)
	end)

	-- HIDE-SHARE-001 (the operator, on seeing the status bar sit still after a show: "can we have
	-- the game do a /togbank share when we do the hide/unhide?"). The version a hide mints is
	-- broadcast at once; a hide the publish gate defers shares when the deferred publish mints; a
	-- hide of something the bank does not hold mints nothing and shares nothing.
	it("shares the version a hide or show mints, the moment it is minted -- and only then", function()
		local shared = {}
		TOGBankClassic_Events = { SyncDeltaVersion = function(_, prio) shared[#shared + 1] = prio or "nil" end }
		Bank:Scan()
		assert.equal(0, #shared, "the plain scan shared -- the post-scan broadcast the operator ruled out is back")
		assert.is_true(Bank:SetHidden(6948, 0, 0, true))
		assert.equal(1, #shared, "the hide minted a version and did not share it")
		assert.equal("NORMAL", shared[1])
		assert.is_nil(Bank.shareOnMint, "the share flag outlived the mint")
		assert.is_true(Bank:SetHidden(6948, 0, 0, false))
		assert.equal(2, #shared, "the show minted a version and did not share it")
		-- Hiding a key this bank does not hold: no content change, no version, no share.
		assert.is_true(Bank:SetHidden(19019, 0, 0, true))
		assert.equal(2, #shared, "a hide that changed nothing shared anyway")
		assert.is_nil(Bank.shareOnMint, "the flag lingered past a no-change scan")
		-- A DEFERRED hide (the publish gate says no) shares when the deferred publish mints.
		TOGBankClassic_P2PSession = { BeginConsult = function() end, IsSelfConsulted = function() return false end }
		Bank.readThisSession = {}
		assert.is_true(Bank:SetHidden(858, 0, 0, true))
		assert.equal(2, #shared, "a deferred hide shared before anything was minted")
		assert.is_true(Bank.shareOnMint, "the deferred hide dropped the share flag")
		assert.is_table(Bank.deferred, "the hide was not deferred -- the example is not testing the deferred path")
		TOGBankClassic_P2PSession.IsSelfConsulted = function() return true end
		assert.is_true(Bank:PublishIfDeferred())
		assert.equal(3, #shared, "the deferred publish minted without sharing")
		assert.is_nil(Bank.shareOnMint)
	end)

	it("does nothing for a no-op toggle or a malformed key", function()
		assert.is_false(Bank:SetHidden(6948, 0, 0, false), "showing an item that was never hidden reported a change")
		assert.is_false(Bank:SetHidden(nil, 0, 0, true))
		assert.is_false(Bank:SetHidden("potato", 0, 0, true))
		assert.equal(0, scans)
	end)

	-- Once the bag events are registered, Scan refuses to run unless something marked it dirty.
	-- SetHidden IS the change, and must mark it so.
	it("marks the scan dirty first, so the toggle is not skipped by the hasUpdated gate", function()
		Bank.eventsRegistered = true
		Bank.hasUpdated = false
		assert.is_true(Bank:SetHidden(6948, 0, 0, true))
		assert.same({ 858 }, ids(Store:GetAltRecords(G, BOB)), "the gate skipped the scan the toggle needed")
	end)

	-- HIDE-002 (the operator: "a setting for bankers in settings in the banker only settings, a
	-- check box"). Every slot the client reports bound is hidden while the box is ticked.
	describe("HIDE-002: the 'hide soulbound items' checkbox", function()
		local SWORD = 2011   -- a bound sword in the bags; potions stay unbound

		before_each(function()
			env.defineItem(SWORD, { name = "Bound Sword", class = 2 })
			env.setBag(0, 4, { { id = 6948, count = 1, bound = true }, { id = 858, count = 5 }, { id = SWORD, count = 1, bound = true } })
			TOGBankClassic_Options.db.char.bank = { hideSoulbound = false }
			TOGBankClassic_Options.GetHideSoulbound = function(self) return self.db.char.bank.hideSoulbound == true end
		end)

		it("is OFF by default: bound items are published like any other", function()
			Bank:Scan()
			assert.same({ 858, SWORD, 6948 }, ids(Store:GetAltRecords(G, BOB)))
			assert.same({}, Store:GetAltHiddenRecords(G, BOB))
			-- The bound keys are remembered regardless, so ticking the box later needs no re-read.
			assert.is_true(TOGBankClassic_Options.db.char.boundKeys.bags[HS])
			assert.is_true(TOGBankClassic_Options.db.char.boundKeys.bags["2011:0:0"])
			assert.is_nil(TOGBankClassic_Options.db.char.boundKeys.bags["858:0:0"], "an unbound slot was remembered as bound")
			assert.is_nil(TOGBankClassic_Options.db.char.boundKeys.bank, "the vault was not read, yet a bank entry was written")
		end)

		it("hides every bound slot when ticked, and answers 'soulbound' as the reason", function()
			TOGBankClassic_Options.db.char.bank.hideSoulbound = true
			Bank:Scan()
			assert.same({ 858 }, ids(Store:GetAltRecords(G, BOB)), "a bound item is still published")
			assert.same({ SWORD, 6948 }, ids(Store:GetAltHiddenRecords(G, BOB)))
			assert.equal("soulbound", Bank:HiddenReason(6948, 0, 0))
			assert.is_nil(Bank:HiddenReason(858, 0, 0))
			assert.is_false(Bank:IsHidden(6948, 0, 0), "the checkbox wrote into the MANUAL list")
			-- A right-clicked item still reads as manual even while also bound.
			assert.is_true(Bank:SetHidden(SWORD, 0, 0, true))
			assert.equal("manual", Bank:HiddenReason(SWORD, 0, 0))
		end)

		it("keeps the VAULT's bound keys when a later scan happens away from the bank", function()
			TOGBankClassic_Options.db.char.bank.hideSoulbound = true
			env.setBag(-1, 24, { { id = SWORD, count = 1, bound = true } })   -- at the bank
			Bank:Scan()
			assert.same({ 858 }, ids(Store:GetAltRecords(G, BOB)))
			-- Away from the bank: the vault is unreadable, the bags are re-read.
			env.bags[-1] = nil
			env.setBag(0, 4, { { id = 858, count = 4 } })
			Bank:OnUpdateStart(); Bank:Scan()
			assert.same({ 858 }, ids(Store:GetAltRecords(G, BOB)), "the carried vault sword came back into view")
			assert.is_true(TOGBankClassic_Options.db.char.boundKeys.bank["2011:0:0"], "the vault's bound key was forgotten")
			assert.equal(4, Store:GetAltItemTotal(G, BOB, 858))
		end)

		it("shows every bound item again when unticked, leaving the manual list alone", function()
			TOGBankClassic_Options.db.char.bank.hideSoulbound = true
			Bank:Scan()
			Bank:SetHidden(858, 0, 0, true)                     -- a manual hide beside the checkbox
			assert.same({}, ids(Store:GetAltRecords(G, BOB)))
			TOGBankClassic_Options.db.char.bank.hideSoulbound = false
			Bank:OnUpdateStart(); Bank:Scan()
			assert.same({ SWORD, 6948 }, ids(Store:GetAltRecords(G, BOB)), "unticking did not show the bound items")
			assert.same({ 858 }, ids(Store:GetAltHiddenRecords(G, BOB)), "unticking touched the manual list")
		end)

		it("is a checkbox on the banker-only Bank panel, default off, whose setter rescans", function()
			local src = env.readFile("Modules/Options.lua")
			local panel = src:match("local bankOptions = {(.-)\n%s*}\n\n%s*LibStub%(\"AceConfig%-3%.0\"%):RegisterOptionsTable%(\"TOGBankClassic/Bank\"")
			assert.is_not_nil(panel, "the banker-only options table was not found where it is registered")
			assert.truthy(panel:find('%["hideSoulbound"%]'), "the checkbox is not on the banker-only Bank panel")
			assert.truthy(panel:find('type = "toggle"'), "not a checkbox")
			assert.truthy(panel:find("TOGBankClassic_Bank:Scan%(%)"), "ticking it does not rescan")
			assert.is_nil(src:find("hideSoulbound = true", 1, true), "the default is ON")
		end)
	end)
end)

-- ─── The banker's own tab: greyed rows, a badge, a right click ─────────────────────────────

describe("HIDE-001: the slot, the tooltip and the right click", function()
	local UI

	before_each(function()
		env.reset()
		env.stubOutput()
		-- The rich frame model, not the hollow default: DrawItem builds a real AceGUI Icon, whose
		-- constructor needs CreateFontString and CreateTexture to return objects.
		require("env.frames").reset()
		require("env.ace").load("AceGUI-3.0")
		UI = env.loadUI()
		TOGBankClassic_Options = { db = { global = {}, char = {} } }
		TOGBankClassic_Guild = TOGBankClassic_Guild or {}
		TOGBankClassic_Guild.ReconstructItemLink = function() end
	end)

	local function row(hidden)
		return {
			ID = 6948, Count = 1, Suffix = 0, Enchant = 0, Hidden = hidden or nil,
			Link = "|cffffffff|Hitem:6948|h[Hearthstone]|h|r",
			Info = { name = "Hearthstone", icon = 134414, rarity = 1 },
		}
	end

	it("greys a hidden row and badges it; a reused slot drawing a visible row loses both", function()
		local parent = UI:Create("SimpleGroup")
		local slot = UI:DrawItem(row(true), parent)
		assert.is_true(slot.image:IsDesaturated(), "a hidden row is not greyed")
		local badge = slot.frame.togHiddenBadge
		assert.is_not_nil(badge, "no badge on a hidden row")
		assert.is_true(badge:IsShown())
		assert.equal("Interface\\RaidFrame\\ReadyCheck-NotReady", badge:GetTexture())
		-- Both buttons reach OnClick: AceGUI's Icon registers none, so a Button would default to
		-- the left button only and the right click would never arrive.
		assert.same({ "LeftButtonUp", "RightButtonUp" }, slot.frame._clickTypes)

		-- AceGUI pools Icons, and the pool is shared with every addon: the Inventory tab releases
		-- its slots on every reload, so the RELEASE itself must undo the greying and the badge --
		-- whoever acquires the Icon next may not be DrawItem.
		parent:ReleaseChildren()
		assert.is_false(slot.image:IsDesaturated(), "a released slot went back to the pool greyed")
		assert.is_false(slot.frame.togHiddenBadge:IsShown(), "a released slot went back to the pool with the badge up")
		local again = UI:DrawItem(row(false), parent)
		assert.equal(slot.frame, again.frame, "the pool handed back a different frame; the reuse case is untested")
		assert.is_false(again.image:IsDesaturated(), "a pooled slot stayed greyed for a visible row")
		assert.is_false(again.frame.togHiddenBadge:IsShown(), "a pooled slot kept the hidden badge for a visible row")
		-- And a second hidden draw on the same pooled Icon re-registers the release hook (AceGUI
		-- wiped it), so the pool is protected on the second release too.
		parent:ReleaseChildren()
		local third = UI:DrawItem(row(true), parent)
		assert.equal(slot.frame, third.frame)
		assert.is_true(third.image:IsDesaturated())
		parent:ReleaseChildren()
		assert.is_false(slot.image:IsDesaturated(), "the second release left the slot greyed: the hook was registered once, not per acquire")
	end)

	it("never picks an item up on a right click through the default handler", function()
		local picked = 0
		_G.PickupItem = function() picked = picked + 1 end
		UI:EventHandler({ link = "|Hitem:6948|h" }, "OnClick", "RightButton")
		assert.equal(0, picked, "a right click picked the item up")
		UI:EventHandler({ link = "|Hitem:6948|h" }, "OnClick", "LeftButton")
		assert.equal(1, picked)
	end)

end)

describe("HIDE-001: the tooltip hint", function()
	local UI
	-- env_togbank's own GameTooltip (SetHyperlink stubbed, AddLine recorded), not the rich frame
	-- model, which has no SetHyperlink.
	before_each(function() env.reset(); env.stubOutput(); UI = env.loadUI() end)

	it("appends the hint lines under the item tooltip", function()
		UI.currentTooltipLink = nil
		UI:ShowItemTooltip("|Hitem:6948|h", { { "Hidden from the guild -- right-click to show it", 1, 0.3, 0.3 } })
		local lines = env.tooltipAdded
		assert.equal(1, #lines)
		assert.equal("Hidden from the guild -- right-click to show it", lines[1].text)
		assert.equal(1, lines[1].r)
		assert.is_true(lines[1].wrap, "a long hint line is not wrapped")
		-- And none without the argument.
		UI.currentTooltipLink = nil
		env.tooltipAdded = {}
		UI:ShowItemTooltip("|Hitem:6948|h")
		assert.equal(0, #env.tooltipAdded)
	end)
end)

describe("HIDE-001: the Inventory window's toggle", function()
	local Inv, calls

	before_each(function()
		env.reset()
		env.stubOutput()
		env.loadUI()
		env.loadFile("Modules/Constants.lua")
		env.loadFile("Modules/Item.lua")
		env.loadFile("Modules/Bank.lua")
		env.loadFile("Modules/UI/Inventory.lua")
		Inv = TOGBankClassic_UI_Inventory
		calls = {}
		TOGBankClassic_Bank.SetHidden = function(_, id, suffix, enchant, hidden)
			calls[#calls + 1] = { id, suffix, enchant, hidden }
			return true
		end
		Inv.isOpen = true
		Inv.TabGroup = { SelectTab = function(_, tab) calls.selected = tab end }
		Inv.currentTab, Inv.tabLoaded = "Bob", true
	end)

	-- The whole suite is one Lua state and env.reset() reinstalls only the globals the env owns:
	-- a REAL Inventory module left here with isOpen=true made every later spec's RefreshSoon run a
	-- DrawContent against their stubs (multipc_spec, p2psession_spec went red in the full run only).
	after_each(function()
		-- Through _G: the language server types the module globals from their definitions and
		-- refuses a bare `= nil`; the intent is exactly to unset them.
		_G.TOGBankClassic_UI_Inventory = nil
		_G.TOGBankClassic_Bank = nil
	end)

	it("flips the flag through Bank:SetHidden and reloads the tab so the row moves", function()
		Inv:ToggleHidden({ ID = 6948, Suffix = 0, Enchant = 0, Info = { name = "Hearthstone" } }, "Bob")
		assert.same({ 6948, 0, 0, true }, calls[1])
		assert.equal("Bob", calls.selected, "the tab was not reloaded")
		assert.is_nil(Inv.currentTab, "DrawContent's UI-004 guard would have kept the stale rows")
		local said = TOGBankClassic_Output.calls[#TOGBankClassic_Output.calls]
		assert.equal("Info", said.level)
		assert.equal("Hearthstone is now hidden from the guild -- right-click it again to show it.", said[1])

		Inv:ToggleHidden({ ID = 6948, Suffix = 0, Enchant = 0, Hidden = true, Info = { name = "Hearthstone" } }, "Bob")
		assert.same({ 6948, 0, 0, false }, calls[2])
	end)

	-- HIDDEN-TEXT-001 (self-audit 5476e257 F2, Peer Review db06c629): every word about a banker's
	-- own hidden rows lives in UI.HIDDEN_TEXT and nowhere else, so the Inventory window and the
	-- Browse tab cannot describe the same row differently. The soulbound notice goes through it too.
	it("says the hidden-row words from UI.HIDDEN_TEXT, and no window carries its own copy", function()
		TOGBankClassic_Bank.HiddenReason = function() return "soulbound" end
		Inv:ToggleHidden({ ID = 6948, Suffix = 0, Enchant = 0, Hidden = true, Info = { name = "Hearthstone" } }, "Bob")
		local said = TOGBankClassic_Output.calls[#TOGBankClassic_Output.calls]
		assert.equal(TOGBankClassic_UI.HIDDEN_TEXT.noticeSoulbound:format("Hearthstone"), said[1])
		assert.equal(0, #calls, "a soulbound-hidden row was toggled")
		local T = TOGBankClassic_UI.HIDDEN_TEXT
		assert.equal(T.tooltipSoulbound, TOGBankClassic_UI:HiddenTooltipLines(true, "soulbound"))
		assert.equal(T.tooltipHidden,    TOGBankClassic_UI:HiddenTooltipLines(true, "manual"))
		assert.equal(T.tooltipShown,     TOGBankClassic_UI:HiddenTooltipLines(false, nil))
		-- The words appear in UI.lua only: a second copy in either window is the drift this exists to stop.
		local phrases = { "Right-click to hide this item from the guild", "right-click to show it",
			"Hide soulbound items)", "is hidden because it is soulbound", "is now hidden from the guild",
			"is visible to the guild again", "right-click it to show it again" }
		for _, path in ipairs({ "Modules/UI/Inventory.lua", "Modules/UI/Browse.lua", "Modules/UI/Search.lua" }) do
			local src = env.readFile(path)
			for _, phrase in ipairs(phrases) do
				assert.is_nil(src:find(phrase, 1, true), path .. " carries its own copy of '" .. phrase .. "'")
			end
		end
		local ui = env.readFile("Modules/UI.lua")
		for _, phrase in ipairs(phrases) do assert.truthy(ui:find(phrase, 1, true), "UI.lua lost '" .. phrase .. "'") end
	end)

	it("does not reload when the toggle changed nothing, and ignores a row with no ID", function()
		TOGBankClassic_Bank.SetHidden = function() return false end
		Inv:ToggleHidden({ ID = 6948 }, "Bob")
		assert.is_nil(calls.selected)
		Inv:ToggleHidden({}, "Bob")
		Inv:ToggleHidden(nil, "Bob")
		assert.is_nil(calls.selected)
	end)

	-- The own-tab merge is a source property: the hidden view is appended ONLY on the banker's
	-- own tab, and only there does the right click do anything. HIDDEN-MERGE-001: the merge is
	-- spelled ONCE, in Guild:GetAltItemsWithOwnHidden; both windows read it and neither reaches the
	-- hidden view itself (they did, identically, until 2026-09-13).
	it("appends the hidden view on the banker's own tab only", function()
		local src = env.readFile("Modules/UI/Inventory.lua")
		assert.truthy(src:find("GetAltItemsWithOwnHidden(normTab)", 1, true))
		assert.truthy(src:find("if ownTab then self:ToggleHidden(item, tab) end", 1, true))
		assert.truthy(env.readFile("Modules/UI/Browse.lua"):find("GetAltItemsWithOwnHidden(norm)", 1, true))
		-- And no other consumer reaches the hidden view: Search, tooltips and TPM read GetAltView.
		for _, path in ipairs({ "Modules/UI/Inventory.lua", "Modules/UI/Browse.lua", "Modules/UI/Search.lua", "Modules/ItemHighlight.lua", "Modules/Mail.lua" }) do
			assert.is_nil(env.readFile(path):find("GetAltHiddenView", 1, true), path .. " reads the hidden view")
		end
		-- The accessor itself, on the REAL Guild module: own bank -> visible + hidden rows; anyone
		-- else's, or a non-banker's own name -> GetAltItems verbatim (the same table, not a copy).
		env.loadFile("Modules/Guild.lua")
		local G = TOGBankClassic_Guild
		G.Info = { name = "Testguild", alts = {} }
		local player = G:GetNormalizedPlayer()
		local visible, hiddenRows = { { ID = 1 } }, { { ID = 2, Hidden = true } }
		_G.TOGBankClassic_Inventory_Store = {
			GetAltView = function() return visible end,
			GetAltHiddenView = function(_, _, alt) return alt == player and hiddenRows or {} end,
		}
		G.IsBank = function(_, n) return n == player end
		local merged = G:GetAltItemsWithOwnHidden(player)
		assert.same({ { ID = 1 }, { ID = 2, Hidden = true } }, merged)
		assert.are_not.equal(visible, merged, "the store's cached view was appended to in place")
		assert.equal(visible, G:GetAltItemsWithOwnHidden("Someoneelse-Testrealm"), "another banker's rows gained a hidden view")
		G.IsBank = function() return false end
		assert.equal(visible, G:GetAltItemsWithOwnHidden(player), "a non-banker's own name gained a hidden view")
		_G.TOGBankClassic_Inventory_Store = nil
		_G.TOGBankClassic_Guild = nil
		-- The right button now reaches EVERY slot's OnClick (DrawItem registers it). The Search
		-- window's own handler must drop it, or a right click there opens the request dialog.
		local search = env.readFile("Modules/UI/Search.lua")
		local handler = search:match('itemWidget:SetCallback%("OnClick", function%(widget, event, button%)(.-)end%)')
		assert.is_not_nil(handler, "Search's slot OnClick does not take the button argument")
		assert.truthy(handler:find('if button == "RightButton" then return end', 1, true),
			"a right click on a Search result opens the request dialog")
	end)
end)
