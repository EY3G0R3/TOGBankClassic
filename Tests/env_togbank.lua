-- env_togbank — the offline WoW environment TOGBankClassic needs on top of the shared
-- WoWAPITesting harness (`Tests/wowapi`).
--
-- ============================================================================
-- THIS FILE IS A STAGING COPY OF A PROPOSED HARNESS ADDITION.
--
-- Almost nothing in here is TOGBank-specific: the controllable clock + timer
-- queue, the container/bag API, the guild roster API and the C_* item shims are
-- what every TOG addon that scans bags or reads the guild roster needs. The
-- intended end state is for these to live in WoWAPITesting (`env/timer.lua`,
-- `env/container.lua`, `env/guild.lua`, plus the universal globals folded into
-- `env/wow.lua`), at which point this file shrinks to the genuinely
-- addon-specific loader helpers and the specs change one line:
--
--     local env = require("env_togbank")   ->  local env = require("env.togbank")
--
-- See Tests/HARNESS_CONTRACT.md for the full contract and rationale.
-- ============================================================================
--
-- DESIGN NOTES
--
-- FAITHFULNESS OVER CONVENIENCE. Stubs honour the real API contract wherever
-- the contract is what bites. Two that matter enormously here:
--
--   * C_Timer.After returns NOTHING. Only NewTimer/NewTicker return a handle
--     with :Cancel(). This is the single most important stub in the file — the
--     addon currently stores After's result in eight places and calls :Cancel()
--     on it (audit TIMER-001). A convenience stub that returned a handle would
--     make those specs pass and hide the entire bug class.
--
--   * AceEvent dispatches handlers as fn(eventName, ...), so a registered
--     method receives the event name as its FIRST argument after self. The
--     harness's RegisterEvent mirrors that exactly (audit EVENT-001).
--
-- ISOLATION. The whole suite runs in ONE Lua state and specs are *expected* to
-- reassign globals to feed values. So every global this env owns is installed
-- by M.install(), which M.reset() calls before each test. Installing once at
-- require time is not enough: one spec nil-ing GetGuildRosterInfo, or pointing
-- GetItemInfo at a fixture, would silently corrupt every later spec FILE. That
-- class of bug is invisible in a single-file run and only shows up in a full
-- run, so the reset has to be total rather than partial.

-- This env deliberately REPLACES several stubs the base harness installs
-- (UnitName, GetRealmName, CreateFrame, ...) with state-driven versions a spec
-- can steer. Overriding them is the entire point, so the duplicate-field
-- warning is noise here.
---@diagnostic disable: duplicate-set-field, lowercase-global, undefined-global
-- luacheck: std lua51

local wow = require("env.wow")

local M = { wow = wow }

-- ---------------------------------------------------------------------------
-- State a spec may read or steer directly
-- ---------------------------------------------------------------------------

--- The clock behind GetTime() and GetServerTime(). CLOCK-001 (self-audit H5a, Peer Review): this
--- defaulted to 0, a server time no client ever reads, so every whole-client spec ran where any
--- `ts <= 0` / `not ts or ts == 0` guard took the branch production never takes -- a suite-wide
--- way to hide a real defect. A fixed 2026 epoch is the default; a spec that needs 0 sets 0.
M.EPOCH      = 1757000000
M.now        = M.EPOCH
M.timers     = {}     -- pending {at, fn, cancelled, kind}
M.bags       = {}     -- bagID -> { size = n, [slot] = {itemID=, stackCount=, hyperlink=} }
M.roster     = {}     -- array of { name, rank, rankIndex, level, class, zone, note, officerNote, online }
M.items      = {}     -- itemID -> { name, link, quality, level, reqLevel, icon, price, class, subClass, equipSlot }
M.money      = 0
M.playerName = "Bankchar"
M.realmName  = "Testrealm"
M.guildName  = "Testguild"
M.inGuild    = true
M.sent       = {}     -- captured SendCommMessage/SendWhisper traffic
M.printed    = {}     -- captured chat output
M.popups     = {}     -- captured StaticPopup_Show calls
M.tooltipLines = {}   -- text lines a scanning tooltip should report
M.tooltipLink  = nil  -- link GameTooltip:GetItem() should return

-- ---------------------------------------------------------------------------
-- Clock + timers
-- ---------------------------------------------------------------------------

-- Fire every timer whose deadline has passed, oldest first. Re-scanned after
-- each callback because callbacks routinely schedule more timers.
local function fireDue()
	local guard = 0
	while true do
		guard = guard + 1
		if guard > 1000 then
			error("env_togbank: timer storm — over 1000 timer callbacks in one advance()")
		end
		local nextIdx, nextAt = nil, nil
		for i, t in ipairs(M.timers) do
			if not t.cancelled and not t.fired and t.at <= M.now then
				if nextAt == nil or t.at < nextAt then nextIdx, nextAt = i, t.at end
			end
		end
		if not nextIdx then return end
		local t = M.timers[nextIdx]
		t.fired = true
		t.fn()
	end
end

--- Advance the fake clock and run everything that comes due.
function M.advance(seconds)
	M.now = M.now + (seconds or 0)
	fireDue()
end

--- Run all pending timers regardless of their deadline (jump to the end).
function M.flushTimers()
	local maxAt = M.now
	for _, t in ipairs(M.timers) do
		if not t.cancelled and not t.fired and t.at > maxAt then maxAt = t.at end
	end
	M.now = maxAt
	fireDue()
end

--- How many timers are still scheduled and un-fired. Lets a spec assert that a
--- cancel actually cancelled something rather than silently no-op'ing.
function M.pendingTimerCount()
	local n = 0
	for _, t in ipairs(M.timers) do
		if not t.cancelled and not t.fired then n = n + 1 end
	end
	return n
end

-- ---------------------------------------------------------------------------
-- Global installation
-- ---------------------------------------------------------------------------

function M.install()
	-- Clock ------------------------------------------------------------------
	_G.GetTime          = function() return M.now end
	_G.GetServerTime    = function() return math.floor(M.now) end
	_G.time             = function() return math.floor(M.now) end
	-- HARNESS-DATE-001: this used to be `function(fmt) return tostring(fmt or "") end` -- it
	-- ignored the timestamp argument entirely and handed back the FORMAT STRING. That is the
	-- "a permissive stub PICKS the answer" class this file's own design note opens with: a spec
	-- asserting a rendered date was asserting "%Y-%m-%d %H:%M" and passing for the wrong reason,
	-- and `date("*t")` returned the string "*t" rather than a table. Now a real os.date driven
	-- off this env's clock, which is the shape the harness ships (env/wow.lua:763) -- adopted
	-- deliberately rather than by deleting the override, because this env drives its OWN clock.
	_G.date             = function(fmt, when) return os.date(fmt, when or math.floor(M.now)) end
	_G.debugprofilestop = function() return M.now * 1000 end

	-- Timers. C_Timer.After returns NOTHING — see the design note at the top.
	_G.C_Timer = {
		After = function(delay, fn)
			M.timers[#M.timers + 1] = { at = M.now + delay, fn = fn, kind = "After" }
			-- deliberately returns nil, exactly like the real API
		end,
		NewTimer = function(delay, fn)
			local rec = { at = M.now + delay, fn = fn, kind = "NewTimer" }
			M.timers[#M.timers + 1] = rec
			return { Cancel = function() rec.cancelled = true end, _rec = rec }
		end,
		NewTicker = function(delay, fn, iterations)
			local rec = { at = M.now + delay, kind = "NewTicker", count = 0 }
			local handle
			rec.fn = function()
				rec.count = rec.count + 1
				fn(handle)
				if not iterations or rec.count < iterations then
					rec.fired = false
					rec.at = M.now + delay
				end
			end
			M.timers[#M.timers + 1] = rec
			handle = { Cancel = function() rec.cancelled = true end, _rec = rec }
			return handle
		end,
	}

	-- Lua-ish WoW helpers ----------------------------------------------------
	_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	-- WoW adds strtrim() AND installs it on the string metatable, so addon code writes
	-- `s:trim()`. Stock Lua 5.1 has neither, and a missing method is a hard error rather
	-- than a wrong answer -- so any spec touching a trimming code path dies without this.
	_G.strtrim = function(s, chars)
		local set = "[" .. (chars or " \t\r\n") .. "]*"
		return (tostring(s):gsub("^" .. set, ""):gsub(set .. "$", ""))
	end
	string.trim = _G.strtrim
	_G.strsplit = function(sep, str, limit)
		local out, start = {}, 1
		while true do
			if limit and #out == limit - 1 then
				out[#out + 1] = str:sub(start)
				break
			end
			local a, b = str:find(sep, start, true)
			if not a then out[#out + 1] = str:sub(start) break end
			out[#out + 1] = str:sub(start, a - 1)
			start = b + 1
		end
		return unpack(out)
	end
	-- CallbackHandler-1.0 captures this as a file-scope upvalue and calls it for every
	-- dispatch. Offline there is no secure context, so it is a plain forwarding call — but it
	-- must EXIST before CallbackHandler loads or every callback dispatch errors.
	_G.securecallfunction = function(fn, ...) return fn(...) end
	_G.securecall         = _G.securecall or function(fn, ...) return fn(...) end
	_G.hooksecurefunc = function(tbl, name, post)
		-- Two-arg form hooks a global function.
		if type(tbl) == "string" then tbl, name, post = _G, tbl, name end
		local orig = tbl[name]
		tbl[name] = function(...)
			local r = { orig(...) }
			post(...)
			return unpack(r)
		end
	end

	-- Player / realm ---------------------------------------------------------
	_G.UnitName                = function() return M.playerName end
	_G.GetRealmName            = function() return M.realmName end
	_G.GetNormalizedRealmName  = function() return M.realmName end
	_G.GetMoney                = function() return M.money end
	-- IsInRaid / GetNumGroupMembers / IsInGroup are the harness's (pin f845a14), DERIVED from
	-- `wow.units`; a private `M.inRaid` flag behind a stand-in here was overridden by any harness
	-- reset run mid-spec (raidvisibility_spec re-loads env.frames). Steer the raid with M.setInRaid.
	_G.IsInGuild               = function() return M.inGuild end
	_G.GetGuildInfo            = function() return M.inGuild and M.guildName or nil end

	--- GetClassColor(classFilename) -> r, g, b, colourString.
	---
	--- Four returns, and the FOURTH is the one this addon uses: `Chat.lua`'s ColorPlayerName reads
	--- `local _, _, _, color = GetClassColor(class)` and builds `|c<color><name>|r`, so the string
	--- is the hex WITHOUT the `|c` prefix. Returning three values, or the string in slot 1, would
	--- make every coloured name silently fall through to the default blue -- a stub that is wrong
	--- in a way nothing asserts.
	---
	--- Absent entirely until 2026-09-09, which is why no spec had ever driven ColorPlayerName: the
	--- first one to reach it died with "attempt to call global 'GetClassColor'". Colours here are
	--- the client's real class colours for the two classes fixtures use, and any unknown class
	--- falls back to white rather than nil, because a nil fourth return silently disables colouring.
	_G.GetClassColor = function(classFilename)
		local COLOURS = {
			WARRIOR = { 0.78, 0.61, 0.43, "ffc79c6e" },
			MAGE    = { 0.41, 0.80, 0.94, "ff69ccf0" },
		}
		local c = COLOURS[classFilename] or { 1, 1, 1, "ffffffff" }
		return c[1], c[2], c[3], c[4]
	end

	-- Guild roster -----------------------------------------------------------
	-- Faithful positional contract:
	--   name, rank, rankIndex, level, class, zone, note, officernote, online, ...
	_G.GetNumGuildMembers = function() return #M.roster end
	_G.GetGuildRosterInfo = function(i)
		local m = M.roster[i]
		if not m then return nil end
		return m.name, m.rank or "Member", m.rankIndex or 4, m.level or 60,
			m.classLocalized or "Warrior", m.zone or "Orgrimmar",
			m.note or "", m.officerNote or "", m.online and true or false,
			0, m.class or "WARRIOR"
	end
	_G.C_GuildInfo = {
		GuildRoster        = function() M.guildRosterCalls = (M.guildRosterCalls or 0) + 1 end,
		CanViewOfficerNote = function() return true end,
	}
	_G.C_AddOns = {
		GetAddOnMetadata = function(_, key) return key == "Version" and "1.3.2" or nil end,
	}
	_G.C_CurrencyInfo = { GetCoinTextureString = function(c) return tostring(c) .. "c" end }

	-- Containers -------------------------------------------------------------
	_G.BANK_CONTAINER          = -1
	-- BANKSLOT-001: MEASURED on a live Classic Era client 2026-09-09, not guessed. These are
	-- engine-side (`Constants.InventoryConstants.NumGenericBankSlots` -> `BANK_NUM_GENERIC_SLOTS`,
	-- which the client supplies), so no source read can produce them and the harness deliberately
	-- ships neither -- see `Tests/wowapi/env/wow.lua:2337`. This env carried 28 for
	-- `NUM_BANKGENERIC_SLOTS`, which was a guess and wrong by four slots; a spec asserting against
	-- it was asserting against fiction. `NUM_BAG_SLOTS = 4` comes from the harness.
	-- TBC is NOT known to match and must not be assumed to: this addon ships both flavours.
	_G.NUM_BANKGENERIC_SLOTS   = 24
	_G.NUM_BANKBAGSLOTS        = 6
	_G.ATTACHMENTS_MAX_RECEIVE = 16
	-- The harness's own container API is COMPLETE at this point (wow.reset() ran just before this
	-- overlay) and reads `wow.bags` in the harness shape (`count`/`link`/`slots`). It is kept so a
	-- spec that drives the harness's cursor and send-mail slots -- which move stacks in `wow.bags`,
	-- not in this env's `M.bags` -- can put it back with `M.useHarnessBags()` instead of carrying a
	-- private cursor model beside the harness's (adoption of harness 1211a3a, step 2). The env's
	-- own readers below stay the default until the env migration moves `M.bags` onto that shape.
	M.harnessContainer = _G.C_Container
	_G.C_Container = {
		GetContainerNumSlots = function(bag)
			local b = M.bags[bag]
			return b and b.size or 0
		end,
		GetContainerNumFreeSlots = function(bag)
			local b = M.bags[bag]
			if not b then return 0, nil end
			local used = 0
			for s = 1, (b.size or 0) do if b[s] then used = used + 1 end end
			return (b.size or 0) - used, b.bagType or 0
		end,
		GetContainerItemInfo = function(bag, slot)
			local b = M.bags[bag]
			local it = b and b[slot]
			if not it then return nil end
			return {
				itemID     = it.itemID,
				stackCount = it.stackCount or 1,
				hyperlink  = it.hyperlink,
				quality    = it.quality,
				-- HIDE-002: Era's ContainerItemInfo carries `isBound` (ContainerDocumentation.lua:622).
				-- Steered per slot with `bound = true` in setBag's contents; false otherwise, as the
				-- client reports for an unbound stack.
				isBound    = it.isBound == true,
			}
		end,
	}

	-- Items ------------------------------------------------------------------
	-- Real GetItemInfo returns nil for an uncached item; M.items is the cache.
	local function lookup(key)
		if type(key) == "number" then return M.items[key] end
		if type(key) == "string" then
			local id = tonumber(key:match("|?H?item:(%d+)")) or tonumber(key)
			return id and M.items[id] or nil
		end
		return nil
	end
	_G.GetItemInfo = function(key)
		local d = lookup(key)
		if not d then return nil end
		--    1     2      3        4       5          6      7      8  9  10     11       12       13
		-- name, link, quality, itemLevel, reqLevel, class, subclass, _, _, icon, price, classID, subClassID
		return d.name, d.link, d.quality or 1, d.level or 1, d.reqLevel or 0,
			d.className or "", d.subClassName or "", 1, d.equipLoc or "",
			d.icon or 134400, d.price or 0, d.class or 0, d.subClass or 0
	end
	_G.GetItemInfoInstant = function(key)
		local d = lookup(key)
		if not d then return nil end
		return d.id, d.equipLoc or "", d.equipLoc or "", d.equipLoc or "",
			d.icon or 134400, d.class or 0, d.subClass or 0
	end
	-- The client's per-quality colours (the same table env/wow.lua carries), not a stub that answers
	-- white for everything: BROWSE-001 colours row names by quality, and a stub that could not tell
	-- a legendary from linen would have passed that spec by construction. Installed here because
	-- this env owns the item globals and reinstalls them on every reset.
	local QUALITY_COLORS = {
		[0] = { 0.62, 0.62, 0.62, "ff9d9d9d" }, [1] = { 1, 1, 1, "ffffffff" }, [2] = { 0.12, 1, 0, "ff1eff00" },
		[3] = { 0, 0.44, 0.87, "ff0070dd" }, [4] = { 0.64, 0.21, 0.93, "ffa335ee" }, [5] = { 1, 0.5, 0, "ffff8000" },
	}
	_G.GetItemQualityColor = function(quality)
		local c = QUALITY_COLORS[quality] or QUALITY_COLORS[1]
		return c[1], c[2], c[3], "|c" .. c[4]
	end
	_G.C_Item = {
		GetItemNameByID = function(id) local d = M.items[id]; return d and d.name or nil end,
		GetItemInventoryTypeByID = function(id) local d = M.items[id]; return d and d.invType or 0 end,
		GetItemInfo = _G.GetItemInfo,
		GetItemInfoInstant = _G.GetItemInfoInstant,
		GetItemQualityColor = _G.GetItemQualityColor,
	}

	-- ItemMixin. Faithful: CreateFromItemID yields an object carrying .itemID,
	-- and ContinueOnItemLoad defers via the timer queue (so a spec must
	-- advance() for the callback to land) — mirroring the real async contract.
	_G.Item = {
		CreateFromItemID = function(_, itemID)
			return {
				itemID = itemID,
				ContinueOnItemLoad = function(_, cb) C_Timer.After(0, cb) end,
			}
		end,
	}

	-- Chat / UI --------------------------------------------------------------
	_G.DEFAULT_CHAT_FRAME = {
		AddMessage = function(_, msg) M.printed[#M.printed + 1] = msg end,
	}
	_G.NUM_CHAT_WINDOWS   = 10
	_G.GetChatWindowInfo  = function() return "" end
	_G.ITEM_UNIQUE        = "Unique"

	-- Localized system-message templates. LibGuildRoster derives its online/offline/join/leave
	-- match patterns from these at FILE SCOPE (LibGuildRoster-1.0.lua:293-306), so they must
	-- exist BEFORE the library is loaded — setting them afterwards is a silent no-op and the
	-- library then matches nothing at all. Building patterns from the localized strings rather
	-- than hardcoding English is the library's design, and it is why these are required.
	-- The online form deliberately carries the player hyperlink the real message has.
	_G.ERR_FRIEND_ONLINE_SS = "|Hplayer:%s|h[%s]|h has come online."
	_G.ERR_FRIEND_OFFLINE_S = "%s has gone offline."
	_G.ERR_GUILD_JOIN_S     = "%s has joined the guild."
	_G.ERR_GUILD_LEAVE_S    = "%s has left the guild."
	_G.ERR_GUILD_REMOVE_SS  = "%s has been kicked out of the guild by %s."
	_G.UIParent           = wow.newFrame()

	-- CreateFrame with a "GameTooltip" type must yield something that can actually be scanned:
	-- the base harness's catch-all no-op frame returns nil from NumLines(), which makes a
	-- `for i = 1, tip:NumLines()` loop raise "'for' limit must be a number" — a harness artifact
	-- that would masquerade as an addon bug. Tooltip text is driven by M.tooltipLines.
	M.tooltipLines = M.tooltipLines or {}
	-- Lines the ADDON adds (GameTooltip:AddLine), the other direction from tooltipLines above,
	-- which is what a scanning tooltip reports TO the addon. Cleared by ClearLines and reset().
	M.tooltipAdded = M.tooltipAdded or {}
	_G.CreateFrame = function(frameType, name)
		local f = wow.newFrame()
		if frameType == "GameTooltip" then
			f.NumLines    = function() return #M.tooltipLines end
			f.ClearLines  = function() M.tooltipAdded = {} end
			f.SetOwner    = function() end
			f.SetHyperlink = function() end
			f.AddLine     = function(_, text, r, g, b, wrap)
				M.tooltipAdded[#M.tooltipAdded + 1] = { text = text, r = r, g = g, b = b, wrap = wrap }
			end
			f.GetItem     = function() return nil, M.tooltipLink end
			-- Real scanning tooltips are read via the global _G[name.."TextLeftN"] font strings.
			if name then
				for i = 1, 30 do
					_G[name .. "TextLeft" .. i] = {
						GetText   = function() return M.tooltipLines[i] end,
						IsVisible = function() return M.tooltipLines[i] ~= nil end,
					}
				end
			end
		end
		return f
	end
	_G.GameTooltip = _G.CreateFrame("GameTooltip", "TestGameTooltip")

	-- Modules register popups into this at load time, so it must be a real table.
	_G.StaticPopupDialogs = {}
	_G.StaticPopup_Show   = function(which, ...) M.popups[#M.popups + 1] = { which = which, ... } end
	_G.StaticPopup_Hide   = function() end
	_G.ACCEPT, _G.CANCEL, _G.YES, _G.NO, _G.CLOSE = "Accept", "Cancel", "Yes", "No", "Close"

	-- Bit library (WoW ships LuaBitOp; stock Lua 5.1 has none) ---------------
	if not _G.bit then
		local function toSigned(n)
			n = n % 4294967296
			if n >= 2147483648 then n = n - 4294967296 end
			return n
		end
		local function bitwise(a, b, op)
			a, b = a % 4294967296, b % 4294967296
			local result, place = 0, 1
			for _ = 1, 32 do
				local x, y = a % 2, b % 2
				local v
				if op == "xor" then v = (x ~= y) and 1 or 0
				elseif op == "and" then v = (x == 1 and y == 1) and 1 or 0
				else v = (x == 1 or y == 1) and 1 or 0 end
				result = result + v * place
				a, b, place = (a - x) / 2, (b - y) / 2, place * 2
			end
			return toSigned(result)
		end
		_G.bit = {
			bxor   = function(a, b) return bitwise(a, b, "xor") end,
			band   = function(a, b) return bitwise(a, b, "and") end,
			bor    = function(a, b) return bitwise(a, b, "or") end,
			bnot   = function(a) return toSigned(4294967295 - (a % 4294967296)) end,
			lshift = function(a, n) return toSigned(a * (2 ^ n)) end,
			rshift = function(a, n) return toSigned(math.floor((a % 4294967296) / (2 ^ n))) end,
		}
	end
end

-- ---------------------------------------------------------------------------
-- Reset
-- ---------------------------------------------------------------------------

--- Total per-test reset. Call from before_each. Clears every piece of steerable
--- state AND reinstalls every global, so a spec that reassigned one cannot leak
--- into a later spec file.
function M.reset()
	M.now, M.timers          = M.EPOCH, {}
	M.bags, M.roster, M.items = {}, {}, {}
	M.money                  = 0
	M.playerName             = "Bankchar"
	M.realmName              = "Testrealm"
	M.guildName              = "Testguild"
	M.inGuild                = true
	M.sent, M.printed        = {}, {}
	M.popups                 = {}
	M.tooltipLines           = {}
	M.tooltipLink            = nil
	M.tooltipAdded           = {}
	M.guildRosterCalls       = 0
	-- The harness's own reset FIRST, then this env's overlay on top of it. The harness owns the
	-- inbox model (wow.mail / wow.mailActions) among much else, and its reset() wipes all of it;
	-- this env used to reinstall only its own globals, so anything a spec steered in the harness
	-- survived into every later spec FILE. Found as mailbox_spec's inbox being read by
	-- multipc_spec's mail scan in a FULL-SUITE run only: two extra deposits and a count of 20.
	wow.reset()
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
	"Modules/P2PSession.lua",
	"Modules/RequestLog.lua",
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
--- The REAL AceGUI is loaded from the sibling Ace3 install, not a stub. Its core file loads
--- clean against this env — the widget files are not needed, because nothing here creates
--- widgets. A stubbed AceGUI would be a table we wrote, so a spec asserting against it would
--- only be asserting about our own stub.
function M.loadUI()
	if not (LibStub.libs and LibStub.libs["AceGUI-3.0"]) then
		local ACE3 = "../Ace3/AceGUI-3.0/AceGUI-3.0.lua"
		local chunk = loadfile(ACE3)
		if not chunk then
			error("AceGUI-3.0 unavailable: " .. ACE3 .. " not found. Modules/UI.lua cannot " ..
				"load without it.", 2)
		end
		chunk("AceGUI-3.0", {})
	end
	M.loadFile("Modules/UI.lua")
	return TOGBankClassic_UI
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

-- LibGuildRoster does LibStub("CallbackHandler-1.0") at file scope and cannot load
-- without it. Load the REAL one from the sibling Ace3 install rather than stubbing:
-- that is the exact code that ships to players, and a stub would hide the very
-- integration bugs this suite exists to catch. Mirrors GuildRoster's own env_guild.lua
-- (see Tests/HARNESS_CONTRACT.md — env/CallbackHandler.lua is a proposed harness addition).
local function ensureCallbackHandler()
	if LibStub.libs and LibStub.libs["CallbackHandler-1.0"] then return end
	-- CallbackHandler calls geterrorhandler() on every dispatch.
	_G.geterrorhandler = _G.geterrorhandler or function() return function(err) error(err, 0) end end
	local ACE3 = "../Ace3/CallbackHandler-1.0/CallbackHandler-1.0.lua"
	local chunk = loadfile(ACE3)
	if not chunk then
		error("CallbackHandler-1.0 unavailable: " .. ACE3 .. " not found. LibGuildRoster " ..
			"cannot load without it.", 2)
	end
	chunk("CallbackHandler-1.0", {})
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
	require("env.libs").load("AceCommQueue-1.0", "DeltaSync-1.0")
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

--- Register an item in the fake client cache.
--- @param id number
--- @param def table  { name=, class=, subClass=, quality=, level=, reqLevel=, link=, price=, icon= }
function M.defineItem(id, def)
	def = def or {}
	def.id = id
	def.name = def.name or ("Item " .. id)
	def.link = def.link or ("|cffffffff|Hitem:" .. id .. ":0:0:0:0:0:0:0:60|h[" .. def.name .. "]|h|r")
	M.items[id] = def
	return def
end

--- Fill a bag with items. `contents` is an array of {id, count} or plain ids.
---
--- `suffix` and `enchant` build a link carrying them, because that is the ONLY way a spec can
--- express a random-suffix item: `Scan.parseLink` reads the enchant from link field 2 and the
--- suffix from field 7, so a spec that merely sets `suffix = 863` on the fixture and expects the
--- scanner to see it is driving nothing. That cost a green-looking end-to-end test its whole point
--- -- two suffix variants of one base ID were written as two identical suffix-0 links and
--- correctly aggregated into one row, which reads exactly like the collapse bug being tested for.
--- @param contents table array of ids, or of { id=, count=, suffix=, enchant=, link= }
function M.setBag(bagID, size, contents)
	local bag = { size = size, bagType = 0 }
	for slot, entry in ipairs(contents or {}) do
		local tbl     = type(entry) == "table"
		local id      = tbl and entry.id or entry
		local count   = tbl and (entry.count or 1) or 1
		local suffix  = tbl and entry.suffix or 0
		local enchant = tbl and entry.enchant or 0
		local def     = M.items[id] or M.defineItem(id, {})

		local link = tbl and entry.link or def.link
		if (suffix ~= 0 or enchant ~= 0) and not (tbl and entry.link) then
			-- Field order after the itemID: enchant, four gem slots, suffix, uniqueID, level.
			link = string.format("|cffffffff|Hitem:%d:%d:0:0:0:0:%d:0:60|h[%s]|h|r",
				id, enchant, suffix, def.name)
		end

		bag[slot] = { itemID = id, stackCount = count, hyperlink = link, isBound = tbl and entry.bound == true or nil }
	end
	M.bags[bagID] = bag
	return bag
end

--- Hand the container surface back to the harness for this example: `C_Container` becomes the
--- harness's complete table (readers, `PickupContainerItem`, `SplitContainerItem`), which reads and
--- moves stacks in `wow.bags`. Use it in a spec that drives the harness's cursor or send-mail slots
--- (`ClickSendMailItemButton`, `GetSendMailItem`, `SendMail`): those work on `wow.bags`, so a bag
--- filled with `setBag` (this env's `M.bags`) would be invisible to them. Fill bags with
--- `harnessBag` after calling this. Undone by the next `reset()`.
function M.useHarnessBags()
	_G.C_Container = M.harnessContainer
	return wow.bags
end

--- `setBag` for `wow.bags`: the harness shape (`slots`, `count`, `link`), with the record carrying
--- `name` so the harness's `GetSendMailItem` can answer it (its item cache is `wow.items`, not this
--- env's). Same `contents` form as `setBag`, minus `suffix`/`enchant`/`bound`, which no spec on
--- this path uses yet -- add them here when one does, not in the spec.
function M.harnessBag(bagID, slots, contents)
	local bag = { slots = slots }
	for slot, entry in ipairs(contents or {}) do
		local tbl   = type(entry) == "table"
		local id    = tbl and entry.id or entry
		local count = tbl and (entry.count or 1) or 1
		local def   = M.items[id] or M.defineItem(id, {})
		bag[slot] = { itemID = id, count = count, link = tbl and entry.link or def.link, name = def.name }
	end
	wow.bags[bagID] = bag
	return bag
end

--- Add a guild member. `note` carrying "gbank" makes them a banker.
function M.addGuildMember(name, opts)
	opts = opts or {}
	M.roster[#M.roster + 1] = {
		name        = name,
		note        = opts.note or "",
		officerNote = opts.officerNote or "",
		online      = opts.online ~= false,
		level       = opts.level or 60,
		class       = opts.class or "WARRIOR",
		rankIndex   = opts.rankIndex or 4,
	}
	return M.roster[#M.roster]
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
