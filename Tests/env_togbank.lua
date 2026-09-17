-- env_togbank -- what TOGBankClassic needs OFFLINE on top of the shared WoWAPITesting harness
-- (`Tests/wowapi`): the addon's loaders, its fixture sugar, and the handful of client APIs the
-- harness does not yet model.
--
-- ============================================================================
-- ENV MIGRATION, 2026-09-14 (the operator: "just work with the test harness and update yourself,
-- this sounds like you could have bad tests if you're not using the harness, and you have
-- unnecessary bloat we can get rid of").
--
-- Until this date this file REPLACED most of the harness: its own clock and timer queue, its own
-- container, item and guild-roster APIs, its own bit library, string helpers, popups, chat frame
-- and localized strings -- all staged in 2026-08 as a proposed harness addition, all delivered by
-- the harness on 2026-08-07, and none of it dropped here for a month. So the suite went green on
-- every harness pin move with zero changes, because the harness was barely being used, and every
-- stand-in was free to diverge from the maintained model (it had: this file's GetItemInfoInstant
-- returned the equip location in the slots the client uses for item type and sub-type).
--
-- NOW: the harness owns every global it models. `env.wow` is reset first, `env.guild` on top of
-- it, and `M.install()` adds ONLY what the harness lacks, each item named as a GAP below so the
-- next reader can check whether it has since been delivered and delete it. The spec-facing names
-- (`env.now`, `env.bags`, `env.items`, `env.roster`, `env.advance`, ...) are kept as PROXIES onto
-- the harness's own state so ~200 call sites did not have to change, and so a spec steering
-- `env.bags` is steering `wow.bags` -- the same table the harness's cursor, send-mail slots and
-- container API read.
-- ============================================================================
--
-- THE HARNESS'S SHAPES, which every fixture here writes:
--   * items: `wow.items[id] = { name, link, quality, level, minLevel, itemType, subType, stackCount,
--     equipLoc, texture, sellPrice, classID, subclassID, ... }` (GetItemInfo's 18 returns). Register
--     through `env.defineItem`, which maps this addon's older fixture spelling onto those names.
--   * bags: `wow.bags[bagID] = { slots = n, family = 0, [slot] = { itemID, count, link, isBound } }`.
--   * roster: `env.guild.members`, filled by `guild.setMembers` -- `publicNote`, `officerNote`,
--     `isOnline`, `classFileName`, `rankIndex`. `env.addGuildMember` appends in that shape.
--   * clocks: `wow.time` is GetTime() (session uptime, starts at 0, never rewinds across files);
--     `wow.epoch` is time() / GetServerTime() / date(). `env.now` reads and writes the EPOCH,
--     because that is what the addon stamps records with; GetTime() is a different clock, as in
--     the client, and a spec comparing the two is asserting something the client never guarantees.
--
-- FAITHFULNESS OVER CONVENIENCE, still: C_Timer.After returns NOTHING (the harness verified it
-- rather than assumed it -- `env/wow.lua`, TIMER-001), and AceEvent handlers receive the event name
-- first (EVENT-001). ISOLATION, still: the whole suite runs in ONE Lua state, so `M.reset()` resets
-- the harness and reinstalls every gap global before each test.

-- The gap globals below are assigned on top of the harness's tables on purpose.
---@diagnostic disable: duplicate-set-field, lowercase-global, undefined-global
-- luacheck: std lua51

local wow   = require("env.wow")
local guild = require("env.guild")

-- ACEGUI-BIND-001: AceGUI is bound to the RICH frame model here, once, before any spec runs.
--
-- Every AceGUI file opens with `local CreateFrame, UIParent = CreateFrame, UIParent` and Ace3 loads
-- once per suite, so whichever file first loads it decides the model every widget in the whole run
-- is built on (harness README, "AceGUI captures CreateFrame at load ... a suite-wide decision, not a
-- per-spec one"). Until 2026-09-15 that file was whichever came first ALPHABETICALLY: browse_spec,
-- which happens to install the rich model before it loads AceGUI. Run in reverse order, a hollow-
-- model file got there first, AceGUI's core captured a HOLLOW UIParent, and 36 examples in six
-- files died in `Release()` -- `frames.lua:692: attempt to get length of local 'list' (a function
-- value)` -- while every one of them passes alone. The suite was green by accident of the sort.
-- `lua Tests/run_reverse.lua` is the gate that keeps it from becoming one again.
--
-- Requiring env.frames installs the rich furniture (UIParent, GameTooltip, MailFrame, ...) at
-- require time WITHOUT a reset; loading AceGUI now binds its upvalues to that. The first
-- `M.reset()` then puts the hollow CreateFrame back for the specs that want it (wow.reset does
-- that), which is exactly the state 80 of these files already ran in after browse_spec.
require("env.frames")
require("env.ace").load("AceGUI-3.0")

local M = { wow = wow, guild = guild }
M.EPOCH = wow.epoch   -- the harness's fixed epoch (2026-01-01 UTC); what `env.now` starts at

-- ---------------------------------------------------------------------------
-- State a spec may read or steer directly
-- ---------------------------------------------------------------------------
-- Owned HERE (the harness has no model of them):
M.sent         = {}    -- a spec's own capture of SendCommMessage/SendWhisper (its stub appends here)

-- PROXIED onto the harness, so the old spelling steers the harness's own state. `now` is the epoch
-- clock; the rest are the harness's tables, which its reset wipes IN PLACE (so an alias would hold)
-- except `guild.members`, which `guild.reset()` replaces -- hence a getter rather than an alias for
-- all of them, uniformly.
local PROXY = {
	now        = { get = function() return wow.epoch end,          set = function(v) wow.epoch = v end },
	money      = { get = function() return wow.money end,          set = function(v) wow.money = v end },
	timers     = { get = function() return wow.timers end },
	bags       = { get = function() return wow.bags end },
	items      = { get = function() return wow.items end },
	popups     = { get = function() return wow.popups end },
	printed    = { get = function() return wow.chat end },
	roster     = { get = function() return guild.members end,       set = function(v) guild.setMembers(v) end },
	playerName = { get = function() return wow.units.player.name end, set = function(v) wow.units.player.name = v end },
	realmName  = { get = function() return guild.realm end,         set = function(v) guild.realm = v; wow.realmName = v end },
	guildName  = { get = function() return guild.guildName end,     set = function(v) guild.guildName = v end },
	inGuild    = { get = function() return guild.inGuild end,       set = function(v) guild.inGuild = v end },
}
setmetatable(M, {
	__index = function(_, k)
		local p = PROXY[k]
		if p then return p.get() end
		return nil
	end,
	__newindex = function(t, k, v)
		local p = PROXY[k]
		if p then
			if not p.set then error("env." .. k .. " is the harness's table; steer it in place", 2) end
			p.set(v)
		else
			rawset(t, k, v)
		end
	end,
})

-- ---------------------------------------------------------------------------
-- Clock + timers: the harness's
-- ---------------------------------------------------------------------------

--- Advance the fake clock and run everything that comes due -- `wow.advanceTime`. A zero advance
--- is ONE TICK: the client fires an `After(0)` on the next frame, not inside the call, and the
--- harness's `advanceTime(0)` runs no slice at all, so `advance(0)` used to fire nothing.
function M.advance(seconds)
	seconds = tonumber(seconds) or 0
	if seconds <= 0 then seconds = wow.tickInterval end
	return wow.advanceTime(seconds)
end

--- Drain the one-shot queue -- `wow.flushTimers`. Tickers fire as the clock crosses them but never
--- hold the flush open (the harness's rule; a repeating ticker is never "done").
function M.flushTimers(rounds) return wow.flushTimers(rounds) end

--- How many timers are still pending -- `wow.pendingTimerCount`.
function M.pendingTimerCount() return wow.pendingTimerCount() end

-- ---------------------------------------------------------------------------
-- Global installation
-- ---------------------------------------------------------------------------

-- Everything the harness models is the harness's: the clock and timers, `C_Timer`, `wipe`,
-- `strtrim`/`string.trim`/`strsplit`, `securecallfunction`/`securecall`/`hooksecurefunc`,
-- `geterrorhandler`, `bit`, UnitName/GetRealmName, the whole item, container and guild-roster
-- surfaces (`env/wow.lua`, `env/guild.lua`), `Item`/`ItemMixin`, `DEFAULT_CHAT_FRAME`, the chat
-- window globals, `StaticPopup*`, the localized ERR_* strings, `C_AddOns.GetAddOnMetadata`,
-- `BANK_CONTAINER`, `NUM_BANKGENERIC_SLOTS`/`NUM_BANKBAGSLOTS` (from the flavour's build table --
-- 24 and 6 on Classic Era, measured 2026-09-09), `ATTACHMENTS_MAX_RECEIVE`, `NUM_BAG_SLOTS` -- and,
-- since pin 830dab2 (2026-09-15, inbox 91731fa6), item LINKS to GetItemInfo/GetItemInfoInstant,
-- `C_Item.GetItemNameByID` / `GetItemInventoryTypeByID`, `GetMoney` (`wow.money`), `GetClassColor`,
-- `C_CurrencyInfo.GetCoinTextureString` + `ITEM_UNIQUE`, and the SCANNING GameTooltip
-- (`SetHyperlink` fills `<name>TextLeft<n>` from `wow.items[id].tooltipLines`; `GetItem` answers)
-- -- which needs `env.frames`, loaded at the top of this file. The six stand-ins this function
-- carried for them were deleted that day.
--
-- What follows is ONLY what the harness does not model, each a GAP with the evidence. Delete an
-- entry the day the harness's `README.md` Adoption log says it landed.
function M.install()
	-- `env/frames.lua` builds UIParent and is required at the top of this file (ACEGUI-BIND-001),
	-- so the rich one is always there; UI modules anchor to it at load. The fallback stands for a
	-- spec that nils it.
	_G.UIParent = _G.UIParent or wow.newFrame()
end

-- ---------------------------------------------------------------------------
-- Reset
-- ---------------------------------------------------------------------------

--- Functions run at the START of every reset, before the harness's own. A fixture that leaves
--- something behind the harness reset cannot reach registers its teardown here (env_fleet: the frames
--- its clients made outlive `wow.reset()`, which drops the clients but keeps the frames registry).
M.resetHooks = {}

--- Total per-test reset. Call from before_each. Clears every piece of steerable
--- state AND reinstalls every global, so a spec that reassigned one cannot leak
--- into a later spec file.
---
--- `opts.frames`: reset through `env.frames` instead -- the RICH widget model for the whole
--- example, with this addon's fixture (the player's name, the guild, the officer flag) laid on top
--- of it. The alternative spelling, `env.reset()` and then `require("env.frames").reset()`, puts
--- the harness's defaults BACK over that fixture (wow.reset runs inside frames.reset: the player
--- is "Testchar" again, the addon version gone), which is fine for a spec that reads none of it
--- and silently wrong for one that does. A rich reset must never be followed by `wow.reset()`.
--- @param opts table|nil  { frames = true }
function M.reset(opts)
	for _, hook in ipairs(M.resetHooks) do hook() end
	-- VISIBILITY-001 part 3: LibAceGUIWidgets outlives a reset (one library object for the whole
	-- suite), and the Guild Bank window and the Requests body register a scale listener keyed by
	-- their MODULE table. A spec file that loaded those modules leaves them listening, so a later
	-- file's scale change re-drew a previous world's window against this world's stubs -- measured:
	-- requestsactions_spec's scale examples failed forward-order only, on Browse:ShowTab calling a
	-- Guild method its stub does not have. Every such module stops listening here, and the scale goes
	-- back to 1.0. Matched by SHAPE, not by the globals: specs nil the globals in teardown and some
	-- load a module twice, so an orphan is reachable only through the listener table -- a Browse
	-- module is registered with its own OnUIScaleChanged, a Requests module is the table carrying
	-- BuildBody. (The per-frame listeners -- RowLists, cells, chrome -- only re-lay frames nothing
	-- reads any more, and a pooled library widget's own listener must survive.)
	local W = LibStub and LibStub.libs and LibStub.libs["LibAceGUIWidgets-1.0"]
	if W and W._scaleListeners then
		local orphans = {}
		for owner, fn in pairs(W._scaleListeners) do
			if type(owner) == "table" and (fn == rawget(owner, "OnUIScaleChanged") or rawget(owner, "BuildBody")) then
				orphans[#orphans + 1] = owner
			end
		end
		for _, owner in ipairs(orphans) do W._scaleListeners[owner] = nil end
		if W.SetScale then W:SetScale(1) end
	end
	-- The harness first (it owns the clock, the timers, the items, the bags, the inbox, the chat
	-- log, the popups, ...), then the guild env on top of it (its reset does not reset env.wow, and
	-- the order matters because wow.reset() replaces C_ChatInfo wholesale), then this file's gaps.
	if opts and opts.frames then
		require("env.frames").reset()   -- calls wow.reset() itself, then installs the rich model over it
	else
		wow.reset()
	end
	guild.reset()
	-- This addon's fixture defaults, as STATE on the harness rather than stubs of it. CLOCK-001: the
	-- epoch is the harness's fixed 2026 date, never 0 -- a zero server time is one no client reads,
	-- and every `ts <= 0` guard would take the branch production never takes.
	M.EPOCH               = wow.epoch
	wow.units.player.name = "Bankchar"
	wow.realmName         = "Testrealm"
	guild.realm           = "Testrealm"
	guild.guildName       = "Testguild"
	guild.inGuild         = true
	-- TRUE here, against the harness's false default: every officer gate in this addon reads the
	-- bare `CanViewOfficerNote`, which `Modules/Compat.lua` aliases to the namespaced one, and the
	-- suite was written with the officer branch as the default; a spec driving the member branch
	-- sets it (or the bare global) itself.
	guild.canViewOfficerNote = true
	-- `GetAddOnMetadata("TOGBankClassic", "Version")` answered "1.3.2" for the life of the old stub.
	wow.addonMetadata.TOGBankClassic = { Version = "1.3.2" }
	M.sent         = {}
	M.install()
end

--- Put the player in (or out of) a raid, through the harness's own tunable: a `raid1` entry in
--- `wow.units` is what its `IsInRaid` reads, so this survives a harness reset the way a private
--- flag could not. `wow.reset()` clears it with the rest of `wow.units`.
function M.setInRaid(on)
	wow.units.raid1 = on and { name = "Raider" } or nil
end

-- ---------------------------------------------------------------------------
-- Addon module loading
-- ---------------------------------------------------------------------------

-- Module load order, mirroring TOGBankClassic.toc. Loading a prefix of this list
-- is enough for most specs; the modules are plain globals with no `local ns`
-- wrapper, so a file can be loaded on its own provided its dependencies (the
-- entries above it) are already present.
M.MODULE_ORDER = {
	"Modules/Compat.lua",
	"Modules/Constants.lua",
	"Modules/Output.lua",
	"Modules/Performance.lua",
	"Modules/DeltaComms.lua",
	"Modules/Bank.lua",
	"Modules/Chat.lua",
	"Modules/Database.lua",
	"Modules/Events.lua",
	"Modules/Guild.lua",
	"Modules/BankerNumbers.lua",
	"Modules/P2P.lua",
	"Modules/RequestLog.lua",
	"Modules/Donations.lua",
	"Modules/PriceList.lua",
	"Modules/Log.lua",
	"Modules/Propagation.lua",
	"Modules/Item.lua",
	"Modules/ItemHighlight.lua",
	"Modules/Switches.lua",
	"Modules/Inventory/Record.lua",
	"Modules/Inventory/Resolve.lua",
	"Modules/Inventory/Store.lua",
	"Modules/Inventory/Scan.lua",
	"Modules/Inventory/Wire.lua",
	"Modules/Inventory/Chain.lua",
	"Modules/Inventory/Sync.lua",
	"Modules/TooltipBankerInfo.lua",
	"Modules/Mail.lua",
	"Modules/MailInventory.lua",
}

--- Load one addon file the way the client does, passing (addonName, ns) as its
--- varargs. Returns whatever the chunk returned (usually nothing — these modules
--- publish themselves as globals).
function M.loadFile(path)
	local chunk, err = loadfile(path)
	if not chunk then
		-- Strip a UTF-8 BOM and retry, so a BOM'd file (audit LINT-001) reports
		-- as a real finding rather than an unexplained "could not load".
		local fh = io.open(path, "rb")
		if fh then
			local src = fh:read("*a"); fh:close()
			if src:sub(1, 3) == "\239\187\191" then
				chunk, err = loadstring(src:sub(4), "@" .. path)
			end
		end
	end
	if not chunk then error("env_togbank: could not load " .. path .. ": " .. tostring(err), 2) end
	return chunk("TOGBankClassic", {})
end

--- Load the named modules (paths relative to the addon root) in the order given.
function M.loadModules(paths)
	for _, p in ipairs(paths) do M.loadFile(p) end
end

--- Load Constants + Output and wire a minimal Database so Output:Debug routes.
--- Most specs want this: it is the smallest set that makes logging work.
--- @param enabledCategories table|nil  category name -> true (default: none enabled)
function M.loadOutput(enabledCategories)
	M.loadModules({ "Modules/Constants.lua", "Modules/Output.lua" })
	TOGBankClassic_Database = TOGBankClassic_Database or {}
	TOGBankClassic_Database.db = {
		global = {
			debugCategories       = enabledCategories or {},
			debugTags             = {},
			showUncategorizedDebug = true,
		},
	}
	-- Capture everything Output prints instead of routing it to a chat frame.
	TOGBankClassic_Core = TOGBankClassic_Core or {}
	function TOGBankClassic_Core:Print(a, b)
		M.printed[#M.printed + 1] = b and (tostring(a) .. " " .. tostring(b)) or tostring(a)
	end
	-- Output.level defaults to INFO, and Log() drops anything below the current level — so with
	-- the shipped default every Debug() call is silently discarded. In-game the user raises the
	-- level via Options; here we raise it at load so a spec that enables a category actually
	-- sees output. A spec that wants to exercise level filtering sets it back explicitly.
	TOGBankClassic_Output:SetLevel(TOGBankClassic_Constants.LOG_LEVEL.DEBUG)
	return TOGBankClassic_Output
end

--- Install a silent Output so a spec exercising a non-logging module isn't
--- forced to load Constants. Every level is a no-op that records the call.
--- The Core inventory-hash surface, stubbed as ONE consistent set.
---
--- CMD-001's class, and it bit immediately: HASH-REV-001 gave Core two more hash functions
--- (`ComputeLegacyInventoryHash`, `StampInventoryHashes`), and every spec that had hand-rolled
--- `TOGBankClassic_Core = { ComputeInventoryHash = function() return 12345 end }` was suddenly a stub
--- with a LOOSER contract than the real thing -- twenty-two examples failed on a nil method call.
--- They were the lucky ones: a stub that is merely incomplete rather than absent makes broken code
--- pass indefinitely, which is what CMD-001 and MIGRATE-001 both were.
---
--- Take this rather than writing the three by hand, so adding a fourth is one edit here.
---@param fixed number|nil the value both revisions return (default 12345)
---@param extra table|nil a table to install onto, so a spec can keep its own Core members
function M.coreHashStub(fixed, extra)
	local value = fixed or 12345
	local t = extra or {}
	t.ComputeInventoryHash       = t.ComputeInventoryHash       or function() return value end
	t.ComputeLegacyInventoryHash = t.ComputeLegacyInventoryHash or function() return value end

	-- HASH-CANON-003 / AUDIT-S1. The canon is content PLUS the publish datestamp, so a stub that
	-- ignores `updatedAt` is LOOSER than the real function -- exactly the CMD-001 class this helper
	-- was created to stop. Two distinct values are produced deliberately:
	--
	--   * the CANON varies with updatedAt, so a spec asserting "two publishes of identical contents
	--     differ" cannot pass by construction here;
	--   * the CONTENT hash does NOT, because it is the change detector.
	--
	-- AND `inventoryContentHash` MUST BE STAMPED. Bank:Scan compares the fresh content hash against
	-- it (Modules/Bank.lua:412-415) to decide whether to advance the version. A stub that leaves it
	-- nil makes EVERY scan look like a change and bump the version -- so a regression that
	-- reintroduced the broadcast storm would pass every spec built on this stub, silently. That was
	-- true for one session and is the finding this comment exists to stop recurring.
	--
	-- AUDIT-S1 FOLLOW-ON: the canon is a LOCAL closure, not a member of the stub. The real Core has
	-- no ComputeCanonHash -- it is a DeltaComms method that Core never delegates, and the canon is
	-- minted at exactly one production site inside StampInventoryHashes. Installing it on the stub
	-- made this surface WIDER than production, which is CMD-001 with the sign reversed: production
	-- code calling Core:ComputeCanonHash would pass every spec built here and fail in the client.
	-- The surface must MATCH the real thing, not merely be no looser than it.
	local function canonHash(self, bank, bags, mailOrMoney, money, updatedAt)
		local content = t.ComputeInventoryHash(self, bank, bags, mailOrMoney, money)
		return (tonumber(content) or value) + (tonumber(updatedAt) or 0)
	end
	t.StampInventoryHashes = t.StampInventoryHashes or function(self, alt, bank, bags, mailOrMoney, money, updatedAt)
		local legacy  = t.ComputeLegacyInventoryHash(self, bank, bags, mailOrMoney, money)
		local content = t.ComputeInventoryHash(self, bank, bags, mailOrMoney, money)
		local canon   = canonHash(self, bank, bags, mailOrMoney, money, updatedAt)
		if alt then
			alt.inventoryHash        = legacy
			alt.inventoryHashV2      = canon
			alt.inventoryContentHash = content
		end
		return legacy, canon, content
	end
	return t
end

function M.stubOutput()
	local calls = {}
	TOGBankClassic_Output = setmetatable({ calls = calls }, {
		__index = function(_, key)
			return function(_, ...) calls[#calls + 1] = { level = key, n = select("#", ...), ... } end
		end,
	})
	return TOGBankClassic_Output
end

-- ---------------------------------------------------------------------------
-- AceGUI-3.0
-- ---------------------------------------------------------------------------

--- Load Modules/UI.lua, which is `TOGBankClassic_UI = LibStub("AceGUI-3.0")` at line 1 and so
--- cannot load without the library present.
---
--- The REAL AceGUI, core and widgets, from the sibling Ace3 install through the harness's loader
--- -- already loaded at the top of this file (ACEGUI-BIND-001), so this is the idempotent no-op
--- path. It used to loadfile the core alone under whichever frame model the caller had, which is
--- how a hollow-model spec came to bind AceGUI for the run.
function M.loadUI()
	require("env.ace").load("AceGUI-3.0")
	M.loadFile("Modules/UI.lua")
	return TOGBankClassic_UI
end

--- Hand back what Options:Init registered with the Blizzard options window. That registration is
--- AceConfigDialog LIBRARY state and outlives the spec file, so a second Init in a later file
--- raises "TOGBankClassic has already been added to the Blizzard Options Window". Call it from an
--- `after_each` in every describe that runs the real Options:Init, so a red example still hands it
--- back (SPEC-ORDER-001: this was spelled in two files and missing from a third -- searchbox_spec --
--- which was fine only while it happened to sort last of the three).
function M.releaseBlizOptions()
	local ACD = LibStub.libs and LibStub.libs["AceConfigDialog-3.0"]
	if not ACD then return end
	ACD.BlizOptions["TOGBankClassic"] = nil
	ACD.BlizOptions["TOGBankClassic/Bank"] = nil
	ACD.BlizOptionsIDMap["TOGBankClassic"] = nil
end

--- A frame double faithful enough to assert window-chrome painting against.
---
--- The harness's catch-all frame swallows every call and reports nothing, so a spec using it
--- would pass whether or not the code under test did anything at all. This one records what was
--- painted and models the two structural facts ALPHA-001 depends on: `GetRegions` returns only
--- regions of THIS frame (AceGUI's title art), and textures carry a draw layer.
--- @param layers table|nil  draw layer per created texture, in creation order (default OVERLAY)
function M.newBackdropFrame(layers)
	local frame = { regions = {}, painted = {}, nextLayer = 1 }
	layers = layers or {}

	function frame:SetBackdropColor(r, g, b, a) self.painted.backdrop = { r, g, b, a } end
	function frame:SetBackdropBorderColor(r, g, b, a) self.painted.border = { r, g, b, a } end
	function frame:GetRegions() return unpack(self.regions) end
	function frame:CreateTexture(_, layer, _, sublevel)
		local tex = {
			layer = layer or "ARTWORK", sublevel = sublevel,
			GetObjectType = function() return "Texture" end,
		}
		function tex:GetDrawLayer() return self.layer, self.sublevel end
		function tex:SetAlpha(a) self.alpha = a end
		function tex:SetAllPoints() self.allPoints = true end
		function tex:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
		self.regions[#self.regions + 1] = tex
		return tex
	end

	-- Stand in for AceGUI's three title-bar header textures.
	for i = 1, 3 do
		local tex = frame:CreateTexture(nil, layers[i] or "OVERLAY")
		frame["title" .. i] = tex
	end
	frame.nextLayer = nil
	return frame
end

--- An AceGUI-Frame-shaped widget wrapping newBackdropFrame, with the status background reachable
--- the way the real widget exposes it: only via `statustext:GetParent()`.
function M.newWindowWidget(layers)
	local frame = M.newBackdropFrame(layers)
	local statusbg = {
		painted = {},
		SetBackdropColor = function(s, r, g, b, a) s.painted.backdrop = { r, g, b, a } end,
		SetBackdropBorderColor = function(s, r, g, b, a) s.painted.border = { r, g, b, a } end,
	}
	return {
		frame = frame,
		statusbg = statusbg,
		statustext = { GetParent = function() return statusbg end },
	}
end

-- ---------------------------------------------------------------------------
-- LibGuildRoster-1.0 (a required dependency as of v1.4.0)
-- ---------------------------------------------------------------------------

-- LibGuildRoster does LibStub("CallbackHandler-1.0") at file scope and cannot load without it.
-- The REAL one, through the harness's own Ace3 registry (`env.ace`), which knows where the
-- sibling install lives; a second loader here was HARNESS_CONTRACT.md 4a, delivered 2026-08-07.
local function ensureCallbackHandler()
	if LibStub.libs and LibStub.libs["CallbackHandler-1.0"] then return end
	require("env.ace").load("CallbackHandler-1.0")
end

-- ---------------------------------------------------------------------------
-- AceSerializer-3.0
-- ---------------------------------------------------------------------------

--- The REAL AceSerializer, mixed into a table carrying `:Serialize()` / `:Deserialize()`.
---
--- Loaded through the HARNESS's own `env.ace` rather than a `loadfile` here. That registry already
--- knows where each Ace library lives and what it depends on, and it is what `env.libs` uses to
--- satisfy the `ace` requirements of the libraries this addon actually ships beside -- DeltaSync-1.0
--- declares `ace = { "AceSerializer-3.0" }` for exactly this reason. A second, addon-local loader
--- would be a private copy of that knowledge, drifting the moment a path changes upstream, which is
--- the duplication the harness exists to remove.
---
--- Stubbing the serialiser is not an option for the spec that needs this: an end-to-end test exists
--- to prove a payload SURVIVES the round trip, and a fake that returns its input passes by
--- construction -- including for payloads the real library cannot encode. Same reasoning as CMD-001,
--- where a stub with a looser contract than the library hid a defect indefinitely.
function M.aceSerializer()
	require("env.ace").load("AceSerializer-3.0")
	local lib = LibStub("AceSerializer-3.0")
	if not lib then error("AceSerializer-3.0 failed to register with LibStub", 2) end
	local holder = {}
	lib:Embed(holder)
	return holder
end

--- Load a FRESH copy of LibGuildRoster-1.0, discarding any previously registered one.
--- LibStub:NewLibrary returns nil for an already-registered version, so without the
--- eviction a second call silently reuses the previous test's library and its state.
function M.freshGuildRoster()
	ensureCallbackHandler()
	LibStub.libs["LibGuildRoster-1.0"], LibStub.minors["LibGuildRoster-1.0"] = nil, nil
	M.loadFile("../GuildRoster/LibGuildRoster-1.0.lua")
	local lib = LibStub("LibGuildRoster-1.0")
	if not lib then error("LibGuildRoster-1.0 failed to register with LibStub", 2) end
	return lib
end

--- Drive an event into the library's own event frame. LibGuildRoster owns its
--- registration (PLAYER_LOGIN / GUILD_ROSTER_UPDATE / CHAT_MSG_SYSTEM) rather than
--- taking forwarded events, so this is how a spec makes it react.
function M.fireGuildRosterEvent(lib, event, ...)
	local frame = lib and lib.frame
	if not frame then error("LibGuildRoster has no event frame", 2) end
	local handler = frame:GetScript("OnEvent")
	if not handler then error("LibGuildRoster registered no OnEvent handler", 2) end
	return handler(frame, event, ...)
end

--- Bring the roster to its READY state.
---
--- The library retries the initial build until the member count stops changing, because
--- GetNumGuildMembers() returns 0 for a window after login. Presence transitions
--- (OnMemberOnline / OnMemberOffline) are deliberately suppressed until then, so that a
--- partial snapshot can't be misread as everyone logging in at once.
---
--- A single GUILD_ROSTER_UPDATE is therefore NOT enough to make the library react to chat
--- presence messages — it takes STABLE_THRESHOLD + 1. This mirrors the `ready()` helper in
--- GuildRoster's own Tests/chat_spec.lua.
function M.readyGuildRoster(lib)
	local n = (lib.STABLE_THRESHOLD or 2) + 1
	for _ = 1, n do M.fireGuildRosterEvent(lib, "GUILD_ROSTER_UPDATE") end
	return lib
end

--- A FRESH V2 store: the inventory modules loaded if a spec has not, and the store re-attached to
--- an empty SavedVariable so nothing seeded by an earlier example survives.
---
--- INV2-RETIRE-003. The store is the only content the addon serves, counts or hashes, so a spec
--- that stages "we hold content" for a banker must put it HERE -- a legacy `items = { ... }` array
--- on the alt record is metadata the negotiation layer no longer reads. Call from before_each.
function M.freshV2()
	if not TOGBankClassic_Inventory_Record then M.loadFile("Modules/Inventory/Record.lua") end
	if not TOGBankClassic_Inventory_Resolve then M.loadFile("Modules/Inventory/Resolve.lua") end
	if not TOGBankClassic_Inventory_Store then M.loadFile("Modules/Inventory/Store.lua") end
	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	return TOGBankClassic_Inventory_Store
end

--- Seed the V2 store with content for `alt`: `rows` are `{ id, count[, suffix[, enchant]] }`,
--- default one row of one item. `money` defaults to 0. Written through SetAltRecords, so the
--- record is schema-complete (as a received delivery is) and reads back through every accessor.
function M.holdV2(guild, alt, rows, money)
	local Store = TOGBankClassic_Inventory_Store
	if not (Store and Store.db) then Store = M.freshV2() end
	local Record = TOGBankClassic_Inventory_Record
	local recs = {}
	for _, r in ipairs(rows or { { 1, 1 } }) do
		local rec = Record.new(r[1], r[2], r[3], r[4])
		if rec then recs[#recs + 1] = rec end
	end
	Store:SetAltRecords(guild, alt, recs, money or 0)
	return Store
end

--- The real DeltaSync-1.0 (with AceCommQueue-1.0, its declared dependency) exactly as the client
--- loads it -- all eight files of its TOC, `DeltaSyncNumbers.lua` (LIBREQ-DS-008 part 1) and
--- `DeltaSyncP2PNumbered.lua` (part 2) included.
---
--- This used to load those two BY PATH after `libs.load`, because the harness manifest listed only
--- the six files of MINOR 17 and `libs.load` therefore handed back a host with no `InitNumbers` and
--- no numbered P2P class -- which TOGBank's adapters read as "library too old", so the version query
--- went quiet and nine examples failed for a reason that looked like a TOGBank bug. Contract
--- d66615e6; DELIVERED by WoWAPITesting in pin `90530f3` (`pathsOf` returns all eight in TOC order),
--- and the stand-in list is gone. The wrapper stays because every spec that stands the Core host up
--- calls it, and it is the one place the library's load is spelled.
function M.loadDeltaSync()
	require("env.libs").load("AceCommQueue-1.0", "DeltaSync-1.0")
end

--- Stand up a WHOLE client: every module in .toc order, the real Core, the V2 store, a real
--- LibGuildRoster roster, and the Database / Options stand-ins the sync layer reads.
---
--- Lifted from syncwire_spec's `loadClient` the day a second spec needed it (hashcache_spec);
--- a fixture copied per file is corrected in one place and stays wrong in the others.
---
--- `who` is the character this client IS, and it is set BEFORE the modules load: the roster
--- build and every "is this my own message" guard resolve self through UnitName, so assigning it
--- afterwards leaves the client believing it is still the default Bankchar -- which discards a
--- banker's own broadcast as its own echo and the delivery silently does nothing.
---
--- `members` is { { name=, note= }, ... }; a note carrying "gbank" makes a banker. The roster is
--- REAL: since v1.4.0 IsBank and IsInCurrentGuildRoster resolve through LibGuildRoster, and with
--- the library absent the roster is EMPTY, every payload is refused as unauthorised, and a spoof
--- test passes vacuously. readyGuildRoster is required too -- the library suppresses presence
--- until the member count stops changing.
--- @param who string bare character name this client plays
--- @param members table roster members to add
--- @param guild string|nil guild name, default "Testguild"
function M.standUpClient(who, members, guild)
	M.playerName = who or "Bankchar"
	M.stubOutput()
	require("env.ace").load("AceAddon-3.0", "AceComm-3.0", "AceConsole-3.0",
		"AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
	-- DS-HOST-001: Core stands up a DeltaSync-1.0 host and the wire envelope is the host's, so the
	-- REAL library loads here exactly as it does in game (a declared hard dependency).
	M.loadDeltaSync()
	M.loadModules(M.MODULE_ORDER)
	-- Re-stub AFTER the module load, which installs the real Output over the earlier stub. The
	-- real Output:Debug reads db.global.debugCategories/debugTags and the persistent log, none of
	-- which a sync spec is testing.
	M.stubOutput()

	local AceAddon = LibStub("AceAddon-3.0")
	if AceAddon and AceAddon.addons then
		AceAddon.addons["TOGBankClassic"] = nil
		if AceAddon.addonstatus then AceAddon.addonstatus["TOGBankClassic"] = nil end
	end
	M.loadFile("Core.lua")

	TOGBankClassic_Inventory_Store:Init({ faction = {} })
	TOGBankClassic_Database = {
		-- BOTH switches: inventoryV2 chooses local storage, sendV2Wire chooses what goes on the
		-- wire. A send test with only the first one on exercises the legacy emission path while
		-- looking like it covers V2.
		db = { global = { switches = { inventoryV2 = true, sendV2Wire = true } }, faction = {} },
		RecordDeltaSent = function() end, RecordDeltaSavings = function() end,
		RecordDeltaComputeTime = function() end, RecordNoChangeSent = function() end,
		RecordDeltaFailed = function() end,
		RecordDeltaReceived = function() end,
		-- HLR-CRASH-001: the hash-list reply handler used to die before its request pass, so
		-- nothing had ever reached the metric it records. Real method (Database.lua:702).
		RecordP2PRequestBroadcast = function() end,
		-- HASH-CANON-009: the relay-responder path (Chat.lua togbank-r) records an offer before it
		-- ACKs; nothing had driven that path on a whole client before. Real method (Database.lua:693).
		RecordP2POffered = function() end,
	}
	TOGBankClassic_Options = {
		IsIntegrityCheckDiagnosticsEnabled = function() return false end,
		IsSyncProgressMuted = function() return true end,
		GetBankEnabled = function() return true end,
		-- Options.lua's default. mergeRequest reads it whenever the clock is non-zero (M.now set), to
		-- tombstone an open request older than the threshold on receive.
		GetAutoTombstoneDays = function() return 30 end,
	}

	for _, m in ipairs(members or {}) do M.addGuildMember(m.name, { note = m.note }) end
	local roster = M.freshGuildRoster()
	M.readyGuildRoster(roster)
	TOGBankClassic_Guild.Info = { name = guild or M.guildName, alts = {} }
	TOGBankClassic_Guild:RefreshOnlineCache()
	return roster
end

-- ---------------------------------------------------------------------------
-- Fixture helpers
-- ---------------------------------------------------------------------------

--- A revision-2 canon as HASH-CANON-005 defines it: `<10-digit publish time><10-digit checksum>`.
--- The one spelling a spec uses to write one by hand, so a fixture cannot drift from the format
--- DeltaComms:ComputeCanonHash produces. A numeric `hashV2` in a fixture is a v1.4.0 canon and is
--- re-encoded on receipt beside its `updatedAt` -- so a spec that advertises `hashV2 = 0x20,
--- updatedAt = 100` and asserts the cache holds `0x20` is asserting the old format.
--- @param publishedAt number the author's publish time
--- @param checksum number the content checksum (any non-negative integer)
function M.canon(publishedAt, checksum)
	return string.format("%010d%010d", publishedAt, checksum % 10000000000)
end

--- Register an item in the harness's item cache (`wow.items`, what GetItemInfo reads).
---
--- Takes THIS ADDON'S fixture spelling and writes the HARNESS'S: `icon` -> `texture`, `price` ->
--- `sellPrice`, `class`/`subClass` -> `classID`/`subclassID`, `reqLevel` -> `minLevel`,
--- `className`/`subClassName` -> `itemType`/`subType`. Both spellings end up on the entry, so a
--- spec that reads `def.price` back still can; the harness reads only its own. `invType` and
--- `tooltipLines` are the harness's own fields (C_Item.GetItemInventoryTypeByID; the scanning
--- tooltip's SetHyperlink fill) and pass through untouched.
--- @param id number
--- @param def table  { name=, class=, subClass=, quality=, level=, reqLevel=, link=, price=, icon=, equipLoc=, invType=, tooltipLines= }
function M.defineItem(id, def)
	def = def or {}
	def.id   = id
	def.name = def.name or ("Item " .. id)
	def.link = def.link or ("|cffffffff|Hitem:" .. id .. ":0:0:0:0:0:0:0:60|h[" .. def.name .. "]|h|r")
	if def.icon         ~= nil and def.texture    == nil then def.texture    = def.icon end
	if def.price        ~= nil and def.sellPrice  == nil then def.sellPrice  = def.price end
	if def.class        ~= nil and def.classID    == nil then def.classID    = def.class end
	if def.subClass     ~= nil and def.subclassID == nil then def.subclassID = def.subClass end
	if def.reqLevel     ~= nil and def.minLevel   == nil then def.minLevel   = def.reqLevel end
	if def.className    ~= nil and def.itemType   == nil then def.itemType   = def.className end
	if def.subClassName ~= nil and def.subType    == nil then def.subType    = def.subClassName end
	wow.loadItem(id, def)
	return wow.items[id]
end

--- Fill a bag with items, in the harness's shape (`wow.bags[bagID] = { slots=, family=, [slot] =
--- { itemID, count, link, isBound, name } }`), which is what `C_Container`, the harness's cursor
--- and its send-mail slots all read. `contents` is an array of {id, count} or plain ids.
---
--- `suffix` and `enchant` build a link carrying them, because that is the ONLY way a spec can
--- express a random-suffix item: `Scan.parseLink` reads the enchant from link field 2 and the
--- suffix from field 7, so a spec that merely sets `suffix = 863` on the fixture and expects the
--- scanner to see it is driving nothing. That cost a green-looking end-to-end test its whole point
--- -- two suffix variants of one base ID were written as two identical suffix-0 links and
--- correctly aggregated into one row, which reads exactly like the collapse bug being tested for.
--- @param contents table array of ids, or of { id=, count=, suffix=, enchant=, link=, bound= }
function M.setBag(bagID, slots, contents)
	local bag = { slots = slots, family = 0 }
	for slot, entry in ipairs(contents or {}) do
		local tbl     = type(entry) == "table"
		local id      = tbl and entry.id or entry
		local count   = tbl and (entry.count or 1) or 1
		local suffix  = tbl and entry.suffix or 0
		local enchant = tbl and entry.enchant or 0
		local def     = wow.items[id] or M.defineItem(id, {})

		local link = tbl and entry.link or def.link
		if (suffix ~= 0 or enchant ~= 0) and not (tbl and entry.link) then
			-- Field order after the itemID: enchant, four gem slots, suffix, uniqueID, level.
			link = string.format("|cffffffff|Hitem:%d:%d:0:0:0:0:%d:0:60|h[%s]|h|r",
				id, enchant, suffix, def.name)
		end

		bag[slot] = { itemID = id, count = count, link = link, name = def.name,
			isBound = tbl and entry.bound == true or false }
	end
	wow.bags[bagID] = bag
	return bag
end

--- ENV MIGRATION: `harnessBag` and `useHarnessBags` were the bridge while this env kept its own
--- container model beside the harness's. There is one model now; both are `setBag`.
M.harnessBag = M.setBag
function M.useHarnessBags() return wow.bags end

--- Add a guild member to the harness's roster (`env.guild.members`). `note` carrying "gbank"
--- makes them a banker. Takes this addon's fixture spelling (`note`, `online`, `class`) and writes
--- the harness's (`publicNote`, `isOnline`, `classFileName`).
function M.addGuildMember(name, opts)
	opts = opts or {}
	local list = {}
	for i, m in ipairs(guild.members) do list[i] = m end
	list[#list + 1] = {
		name          = name,
		publicNote    = opts.note or opts.publicNote or "",
		officerNote   = opts.officerNote or "",
		isOnline      = opts.online ~= false,
		level         = opts.level or 60,
		classFileName = opts.class or "WARRIOR",
		rankIndex     = opts.rankIndex or 4,
	}
	guild.setMembers(list)
	return guild.members[#guild.members]
end

--- AceConsole-3.0's `GetArgs` -- THE REAL ONE, loaded from the sibling Ace3 install.
---
--- CMD-001: a spec once stubbed this as `(prefix, remainder)` -- a LOOSER contract than the real
--- library -- and that is what hid the defect. AceConsole **tokenizes**: it returns
--- `arg1, ..., argN, nextposition`, with `nextposition = 1e9` at end of string, so the caller must
--- use the position to reach the rest.
---
--- CMD-001 FOLLOW-UP: the replacement was a local RE-IMPLEMENTATION, which is the same class one
--- step removed. Read against `Ace3/AceConsole-3.0/AceConsole-3.0.lua:140`, it differed twice:
--- it dropped the third parameter (`startpos`, how a caller continues tokenizing from `nextpos`),
--- and it split on `%S` where the real one splits on the space character only. Neither bit the one
--- production caller today, and both would have passed a caller that the client then broke.
--- Loading the installed library removes the whole category of drift instead of the two found.
function M.aceGetArgs(str, numargs, startpos)
	require("env.ace").load("AceConsole-3.0")
	local AC = LibStub("AceConsole-3.0")
	return AC.GetArgs(AC, tostring(str or ""), numargs, startpos)
end

--- A minimal TOGBankClassic_Core carrying the AceConsole methods the chat path needs.
--- Specs that drive `Chat:ChatCommand` should use this rather than hand-rolling a stub, because
--- hand-rolled ones are how CMD-001 stayed invisible.
--- MERGES rather than replaces. In game, TOGBankClassic_Core is ONE object carrying several Ace
--- mixins at once (AceConsole's GetArgs, AceEvent, plus the addon's own Print, SendCommMessage,
--- SerializeWithChecksum). A stub that assigns a fresh table silently deletes whatever another
--- helper already installed -- env.loadOutput puts Core:Print there, and calling stubCore
--- afterwards made every Output call fail with "attempt to call method 'Print' (a nil value)".
--- Merging also means the order of the two calls stops mattering, which is one less thing for a
--- spec author to get right.
function M.stubCore(extra)
	local core = TOGBankClassic_Core or {}
	core.GetArgs = function(_, str, numargs, startpos) return M.aceGetArgs(str, numargs, startpos) end
	for k, v in pairs(extra or {}) do core[k] = v end
	TOGBankClassic_Core = core
	return core
end

--- Every first-party Lua file the addon SHIPS, in load order, read from the .toc.
---
--- Lives here because more than one class-guard spec needs it (timers_spec's TIMER-001 sweep and
--- constantprose_spec's DOC-004 sweep), and two copies of "which files does this addon ship" is
--- exactly the drift those guards exist to prevent -- one copy would be updated and the other would
--- keep passing over a smaller set.
---
--- THE .toc IS THE ONE LIST THAT CANNOT SILENTLY OMIT A MODULE: a file missing from it does not load
--- in game. timers_spec's first version listed schedulers by hand and missed two, because the list
--- was compiled from the files an audit happened to name -- a check whose coverage looks complete
--- and is not.
---
--- Libs/ is excluded: vendored upstream code we do not author and could only fix by forking, so a
--- hit there would have no remedy but to weaken the guard. Everything we write is in scope,
--- including generated data under Modules/Static -- "that file obviously has no <x>" is precisely
--- the reasoning that produced the hole above.
--- @param toc string|nil defaults to TOGBankClassic.toc
--- @return table array of repo-relative paths, in load order
function M.shippedModules(toc)
	local path = toc or "TOGBankClassic.toc"
	local fh = assert(io.open(path, "rb"), "cannot read " .. path)
	local src = fh:read("*a")
	fh:close()

	local paths = {}
	for line in (src .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
		local entry = line:match("^%s*([^#%s][^\r\n]-%.lua)%s*$")
		if entry then
			entry = entry:gsub("\\", "/")
			if not entry:match("^Libs/") then
				paths[#paths + 1] = entry
			end
		end
	end
	return paths
end

--- Read a shipped source file as a string, tolerating a UTF-8 BOM (audit LINT-001) and returning
--- "" rather than erroring when the path does not exist -- a class guard that scans files must be
--- able to report "nothing found HERE" without the whole spec dying.
---
--- Lifted here because the identical five-line body was open-coded in FOUR spec files
--- (timers, constantprose, itemhighlight, guildroster_integration) and performance_spec was about
--- to be the fifth. Same move as shippedModules() above, and the same reason: a scan helper copied
--- per file is a helper that can be corrected in one place and stay wrong in three.
--- @param path string repo-relative
--- @return string contents ("" when the file cannot be read)
function M.readFile(path)
	local fh = io.open(path, "rb")
	if not fh then return "" end
	local src = fh:read("*a")
	fh:close()
	if src:sub(1, 3) == "\239\187\191" then src = src:sub(4) end
	return src
end

--- Iterate the REAL CODE lines of a source string, skipping whole-line `--` comments, yielding
--- (lineNumber, line).
---
--- Every source-scanning guard needs this and none of them can do without it: the comments in this
--- addon quote the very patterns the guards hunt for -- Output.lua's header spells out
--- Debug("CATEGORY", "TAG", ...) and Bank.lua's BANKSLOT-001 note writes out the hardcoded `5, 11`
--- it exists to explain -- so a scan that reads comments reports its own documentation as a defect.
--- Lifted here rather than copied a second time, for the reason in readFile above.
--- @param src string
--- @return function iterator yielding lineNumber, line
function M.codeLines(src)
	local n = 0
	return coroutine.wrap(function()
		for line in (src .. "\n"):gmatch("([^\n]*)\n") do
			n = n + 1
			if not line:match("^%s*%-%-") then coroutine.yield(n, line) end
		end
	end)
end

M.install()

return M
