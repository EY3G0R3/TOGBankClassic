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

M.now        = 0      -- drives GetTime() and GetServerTime()
M.timers     = {}     -- pending {at, fn, cancelled, kind}
M.bags       = {}     -- bagID -> { size = n, [slot] = {itemID=, stackCount=, hyperlink=} }
M.roster     = {}     -- array of { name, rank, rankIndex, level, class, zone, note, officerNote, online }
M.items      = {}     -- itemID -> { name, link, quality, level, reqLevel, icon, price, class, subClass, equipSlot }
M.money      = 0
M.playerName = "Bankchar"
M.realmName  = "Testrealm"
M.guildName  = "Testguild"
M.inGuild    = true
M.inRaid     = false
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
	_G.date             = function(fmt) return tostring(fmt or "") end
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
	_G.IsInRaid                = function() return M.inRaid end
	_G.IsInGuild               = function() return M.inGuild end
	_G.GetGuildInfo            = function() return M.inGuild and M.guildName or nil end

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
	_G.NUM_BANKGENERIC_SLOTS   = 28
	_G.ATTACHMENTS_MAX_RECEIVE = 16
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
	_G.GetItemQualityColor = function() return 1, 1, 1, "|cffffffff" end
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
	_G.CreateFrame = function(frameType, name)
		local f = wow.newFrame()
		if frameType == "GameTooltip" then
			f.NumLines    = function() return #M.tooltipLines end
			f.ClearLines  = function() end
			f.SetOwner    = function() end
			f.SetHyperlink = function() end
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
	M.now, M.timers          = 0, {}
	M.bags, M.roster, M.items = {}, {}, {}
	M.money                  = 0
	M.playerName             = "Bankchar"
	M.realmName              = "Testrealm"
	M.guildName              = "Testguild"
	M.inGuild, M.inRaid      = true, false
	M.sent, M.printed        = {}, {}
	M.popups                 = {}
	M.tooltipLines           = {}
	M.tooltipLink            = nil
	M.guildRosterCalls       = 0
	M.install()
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
	"Modules/P2PSession.lua",
	"Modules/RequestLog.lua",
	"Modules/Item.lua",
	"Modules/ItemHighlight.lua",
	"Modules/Switches.lua",
	"Modules/Inventory/Record.lua",
	"Modules/Inventory/Resolve.lua",
	"Modules/Inventory/Store.lua",
	"Modules/Inventory/Scan.lua",
	"Modules/Inventory/Wire.lua",
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
	TOGBankClassic_Output:SetLevel(LOG_LEVEL.DEBUG)
	return TOGBankClassic_Output
end

--- Install a silent Output so a spec exercising a non-logging module isn't
--- forced to load Constants. Every level is a no-op that records the call.
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

-- ---------------------------------------------------------------------------
-- Fixture helpers
-- ---------------------------------------------------------------------------

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
function M.setBag(bagID, size, contents)
	local bag = { size = size, bagType = 0 }
	for slot, entry in ipairs(contents or {}) do
		local id    = type(entry) == "table" and entry.id or entry
		local count = type(entry) == "table" and (entry.count or 1) or 1
		local def   = M.items[id] or M.defineItem(id, {})
		bag[slot] = {
			itemID     = id,
			stackCount = count,
			hyperlink  = (type(entry) == "table" and entry.link) or def.link,
		}
	end
	M.bags[bagID] = bag
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

M.install()

return M
