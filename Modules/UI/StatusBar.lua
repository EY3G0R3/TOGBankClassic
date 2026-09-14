-- StatusBar.lua
-- Tri-part status bar system: left (inventory summary), center (activity),
-- right (network stats). Each section degrades gracefully when space is tight:
-- all three shown when they fit, left+center when the right won't fit, left
-- only when even the center won't fit.
--
-- FORMATTERS  (pure formatting, no data access)
--   FormatMoney(copper)          colored gold/silver/copper text
--   GetSlotColor(percent)        color hex for a slot-fill percentage
--   FormatSlots(used, total)     colored "X/Y" slot count
--
-- INVENTORY STATUS  (read Guild.Info to build left-section text)
--   BuildInventorySummary(info, roster_alts)
--       Total money + slots across all banker alts. Used as the normal
--       left section text.
--   BuildAltDetail(alt, name)
--       Per-alt hover detail: sync time, money, slots, mail count + age.
--       Returns a fallback string for unsynced or missing alts.
--
-- NETWORK STATUS  (right/center section; each returns "" when idle)
--   NetTxText()                  P2P sends in flight     e.g. "Tx:1/3"
--   NetBcastText()               broadcast queue depth   e.g. "Bcast:2"
--   NetReqSyncText()             request-index handshake e.g. "r:3/10"
--   NetRxText()                  P2P fetches in flight   e.g. "Rx:2"
--   NetQueriedReqText()          queried requests        e.g. "Req:5"
--   NetCTLParts() -> ctr, right  CTL queue (one pass, two outputs)
--
-- PROPAGATION  (SYNCED-001: the banker's own "has my update reached anyone" line)
--   BuildPropagationText(short)  "" or the red/grey/green line for the center;
--                                `short` is the narrow-bar spelling (STATUSBAR-003)
--
-- COMPOSITION
--   BuildNetworkParts() -> centerText, rightText
--       Calls all Net* functions and assembles the "Network: ..." right
--       string. Returns "", "" when network info is disabled in options.
--   BuildSides() -> centerText, rightText, shortCenter
--       The network parts with the propagation line taking the center when
--       it has something to say. What every window's ticker draws. The third
--       is the centre's short form, or nil (STATUSBAR-003).
--
-- INSTANCE
--   TOGBankClassic_UI_StatusBar:Attach(window) -> sb
--       Wires up the tri-part FontStrings on an AceGUI Frame's status bar
--       and returns a controller. Call once in DrawWindow.
--
--   sb:Draw(info, roster_alts, tabGroup)
--       One-shot setup for an inventory window: computes summary text, does
--       the initial refresh, starts the 0.5 s ticker, and registers the
--       OnEnter/OnLeave hover callbacks. Call once per DrawContent pass.
--       Teardown is automatic — the ticker stops on window Hide.
--   TOGBankClassic_UI_StatusBar:AttachSides(window) -> sb
--       For every OTHER window: the window keeps writing its own left text,
--       the bar owns center/right and arms its ticker on each show.
--   sb:DrawSides()                    the sides-only draw (called by the show hook)
--   sb:Refresh(left, center, right, short)   apply all three sections (no-op while hovered)
--   sb:RefreshSides(center, right, short)    apply center/right against the current left;
--                                            `short` replaces `center` when the full line is
--                                            wider than the bar (STATUSBAR-003)
--   sb:SetLeft(text)                  push hover content; bypasses hovered guard
--   sb:SetHovered(bool)               block/unblock Refresh
--   sb:StartTicker(interval, fn)      low-level ticker control (used by Draw)
--   sb:StopTicker()                   cancel the ticker (called automatically on Hide)

TOGBankClassic_UI_StatusBar = {}

-- NS-001: aliased as a file-scope local so a foreign global of the same name cannot be read
-- instead. See the header of Modules/Constants.lua.
local COMM_PREFIX_DESCRIPTIONS = TOGBankClassic_Constants.COMM_PREFIX_DESCRIPTIONS

-- ---------------------------------------------------------------------------
-- FORMATTERS
-- ---------------------------------------------------------------------------

-- Formats a copper amount as colored text (gold/silver/copper).
-- Replaces GetCoinTextureString() which renders broken square icons in AceGUI status bars.
function TOGBankClassic_UI_StatusBar.FormatMoney(copper)
	copper = copper or 0
	if copper <= 0 then
		return "|cff7f7f7f0c|r"
	end
	local gold   = math.floor(copper / 10000)
	local silver = math.floor((copper % 10000) / 100)
	local cp     = copper % 100
	local parts  = {}
	if gold > 0 then
		table.insert(parts, string.format("|cffFFD700%dg|r", gold))
	end
	if silver > 0 or gold > 0 then
		table.insert(parts, string.format("|cffc0c0c0%ds|r", silver))
	end
	if cp > 0 or (gold == 0 and silver == 0) then
		table.insert(parts, string.format("|cffb46a2f%dc|r", cp))
	end
	return table.concat(parts, " ")
end

-- Returns a color hex string for a slot-fill percentage.
function TOGBankClassic_UI_StatusBar.GetSlotColor(percent)
	if percent <= 0.25 then
		return "ffffffff"
	elseif percent <= 0.5 then
		return "ff00ff00"
	elseif percent <= 0.75 then
		return "ffffff00"
	elseif percent <= 0.9 then
		return "ffff9900"
	else
		return "ffff0000"
	end
end

-- Returns a colored "|cXXXXXXXXused/total|r" slot string.
function TOGBankClassic_UI_StatusBar.FormatSlots(used, total)
	local percent = total > 0 and (used / total) or 0
	local color = TOGBankClassic_UI_StatusBar.GetSlotColor(percent)
	return string.format("|c%s%d/%d|r", color, used, total)
end

-- ---------------------------------------------------------------------------
-- INVENTORY STATUS
-- ---------------------------------------------------------------------------

-- Builds the normal left-section text: total money and slots across all banker alts.
function TOGBankClassic_UI_StatusBar.BuildInventorySummary(info, roster_alts)
	local total_gold = 0
	local slots, total_slots = 0, 0
	for _, player in pairs(roster_alts) do
		local norm = TOGBankClassic_Guild:NormalizeName(player)
		local alt = info.alts[norm]
		if alt and type(alt) == "table" then
			total_gold = total_gold + (alt.money or 0)
			if alt.bank and alt.bank.slots then
				slots       = slots       + alt.bank.slots.count
				total_slots = total_slots + alt.bank.slots.total
			end
			if alt.bags and alt.bags.slots then
				slots       = slots       + alt.bags.slots.count
				total_slots = total_slots + alt.bags.slots.total
			end
		end
	end
	return TOGBankClassic_UI_StatusBar.FormatMoney(total_gold)
		.. "    "
		.. TOGBankClassic_UI_StatusBar.FormatSlots(slots, total_slots)
end

-- Builds the hover detail string for a single alt.
-- Returns a plain fallback string if the alt is missing or not yet synced.
-- `name` is the normalized alt name, needed to read the V2 store (INV2-RETIRE-003); nil is
-- tolerated and reads as no mail.
function TOGBankClassic_UI_StatusBar.BuildAltDetail(alt, name)
	if not alt or type(alt) ~= "table" then
		return "No data available"
	end
	if not alt.version or alt.version == 0 then
		return "Waiting for sync..."
	end

	local slot_count, slot_total = 0, 0
	if alt.bank and alt.bank.slots then
		slot_count = slot_count + alt.bank.slots.count
		slot_total = slot_total + alt.bank.slots.total
	end
	if alt.bags and alt.bags.slots then
		slot_count = slot_count + alt.bags.slots.count
		slot_total = slot_total + alt.bags.slots.total
	end

	-- INV2-RETIRE-003: the mail count comes from the V2 store's mail bucket -- only the local
	-- banker's own scan writes one, which is also the only record that ever carried `alt.mail`, so
	-- this reads the same population it always did. Rows, not units: one row per distinct item in
	-- the mailbox, as the legacy array counted.
	local mailCount = 0
	local Store = TOGBankClassic_Inventory_Store
	local guildName = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name
	if Store and guildName and name then
		mailCount = #Store:GetAltSourceRecords(guildName, name, "mail")
	end

	local mailText = ""
	if mailCount > 0 then
		local age = TOGBankClassic_MailInventory:GetMailDataAge(alt)
		local ageText = age and (" (" .. SecondsToTime(age) .. " ago)") or ""
		mailText = string.format("    |cff87ceebMail: %d item%s%s|r",
			mailCount, mailCount > 1 and "s" or "", ageText)
	end

	return string.format("As of %s    %s    %s%s",
		date("%Y-%m-%d %H:%M:%S", alt.version),
		TOGBankClassic_UI_StatusBar.FormatMoney(alt.money or 0),
		TOGBankClassic_UI_StatusBar.FormatSlots(slot_count, slot_total),
		mailText)
end

-- ---------------------------------------------------------------------------
-- NETWORK STATUS
-- Each function returns a formatted string, or "" when the part is inactive.
-- ---------------------------------------------------------------------------

-- P2P sends in flight: "Tx:1/3"
-- P2P-025: this read TOGBankClassic_Guild.pendingSendCount, a legacy counter that four sites
-- DECREMENT and nothing increments -- so it was pinned at 0 and the `sends == 0` early return
-- meant this indicator could never render, at any load. The live count is P2PSession's, which is
-- also the one the cap is actually enforced against.
function TOGBankClassic_UI_StatusBar.NetTxText()
	local sends = TOGBankClassic_P2PSession
		and TOGBankClassic_P2PSession:GetActiveSendTotal() or 0
	if sends == 0 then return "" end
	local max = TOGBankClassic_Constants.PEER_TO_PEER.MAX_ACTIVE_SENDS   -- the one spelling; no literal fallback
	local c = (sends >= max) and "ffff4444" or "ffff9900"
	return string.format("|c%sTx:%d/%d|r", c, sends, max)
end

-- Broadcast queue depth: "Bcast:2"
function TOGBankClassic_UI_StatusBar.NetBcastText()
	local syncQ = TOGBankClassic_Chat and TOGBankClassic_Chat.sync_queue and #TOGBankClassic_Chat.sync_queue or 0
	if syncQ == 0 then return "" end
	return string.format("|cffffff00Bcast:%d|r", syncQ)
end

-- Request-index handshake: "r:3/10" or "r:ids"
function TOGBankClassic_UI_StatusBar.NetReqSyncText()
	local rSync = TOGBankClassic_Guild.requestsIndexSync
	if not rSync or not rSync.awaitingById then return "" end
	local bTotal = rSync.batchTotal
	if bTotal and bTotal > 0 then
		return string.format("|cff87ceebr:%d/%d|r", rSync.batchSent or 0, bTotal)
	end
	return "|cff87ceebr:ids|r"
end

-- P2P fetches in flight: "Rx:2"
function TOGBankClassic_UI_StatusBar.NetRxText()
	local fetches = 0
	if TOGBankClassic_Guild.pendingP2PRequests then
		for _ in pairs(TOGBankClassic_Guild.pendingP2PRequests) do fetches = fetches + 1 end
	end
	if fetches == 0 then return "" end
	return string.format("|cff87ceebRx:%d|r", fetches)
end

-- Queried requests pending reply: "Req:5"
function TOGBankClassic_UI_StatusBar.NetQueriedReqText()
	local count = TOGBankClassic_Guild:GetQueriedRequestsCount()
	if count == 0 then return "" end
	return string.format("|cff98fb98Req:%d|r", count)
end

-- ChatThrottleLib queue — two outputs from one inspection pass.
-- Returns centerText ("Sending X to Y"), rightText ("CTL:42").
-- Both are "" when the CTL queue is empty.
local CTL_PRIO_ORDER = {"ALERT", "NORMAL", "BULK"}
function TOGBankClassic_UI_StatusBar.NetCTLParts()
	local ctl = _G.ChatThrottleLib
	if not ctl or not ctl.Prio then return "", "" end

	local total = 0
	local nextPrefix, nextDest
	local recipients = {}

	local function walkRing(ring)
		if not ring or not ring.pos then return end
		local pipe = ring.pos
		repeat
			for i = 1, #pipe do
				local msg = pipe[i]
				total = total + 1
				local dest = msg[4] or msg[3]
				if dest then recipients[dest] = true end
				if not nextPrefix and msg[1] then
					nextPrefix = msg[1]
					nextDest = dest
				end
			end
			pipe = pipe.next
		until pipe == ring.pos
	end

	for _, prioName in ipairs(CTL_PRIO_ORDER) do
		local prio = ctl.Prio[prioName]
		if prio then
			walkRing(prio.Ring)
			walkRing(prio.Blocked)
		end
	end

	if total == 0 then return "", "" end

	local centerText = ""
	if nextPrefix then
		local desc = COMM_PREFIX_DESCRIPTIONS and COMM_PREFIX_DESCRIPTIONS[nextPrefix]
		local msgType = (desc and string.match(desc, "^%((.-)%)$")) or nextPrefix
		centerText = string.format("|cff888888Sending %s to %s|r", msgType, nextDest or "?")
	end

	local recipientCount = 0
	for _ in pairs(recipients) do recipientCount = recipientCount + 1 end
	local c = total >= 1000 and "ffff4444" or "ffff9900"
	local rightText = string.format("|c%sCTL:%d|r", c, total)
	if recipientCount > 1 then
		rightText = rightText .. string.format(" (%d recipients)", recipientCount)
	end

	return centerText, rightText
end

-- SYNCED-001: has the version of MY bank I published this session reached anyone? The banker's
-- "don't log off yet" signal, on every window's status bar. Reads Propagation:Status(); "" when
-- there is nothing to say (not a banker, nothing published, or the synced line has aged out).
-- NOT gated by the network-info option: this is a warning about the banker's own data, not stats.
--
-- STATUSBAR-003: `short` asks for the narrow-bar form -- the same fact in fewer words, dropping the
-- online count and the "Bank" prefix. RefreshSides picks it when the full line is wider than the
-- bar itself (it overflowed BOTH ends of the Mailbox window's bar and sat over Close); the wording
-- is the same state, so the two never disagree.
local SYNCED_SHOWN_FOR = 90   -- seconds the green "received by N" line stays after the last holder

local function clockText(seconds)
	local elapsed = math.floor(math.max(0, seconds))
	return string.format("%d:%02d", math.floor(elapsed / 60), elapsed % 60)
end

--- DEFERRED-LINE-001: a scan of OUR bank that is stored but not yet published (Bank.deferred --
--- the publish gate held it: the login consult has not settled, another PC's publish is newer and
--- a source is not re-read, or the newer copy is being fetched as the diff base). The tracker knows
--- nothing until the mint, so without this the whole wait -- up to the 180 s fallback -- showed an
--- empty bar, and a deferred hide/show read as one that did nothing (the operator, 2026-09-13:
--- "hiding/unhiding and now it doesn't show up immediately like it did before"). Amber: the banker
--- must stay online for it to go out. The wording says what ends the wait.
---@return string line "" when nothing is deferred
local function deferredText(short)
	local Bank = TOGBankClassic_Bank
	local d = Bank and Bank.deferred
	if type(d) ~= "table" then return "" end
	local clock = clockText(GetTime() - (tonumber(d.since) or GetTime()))
	local why = tostring(d.why or "")
	if why:find("^stale:") then
		if short then return string.format("|cffff9900Update stored, not published -- open bank + mailbox (%s)|r", clock) end
		return string.format("|cffff9900Bank update stored, not published yet -- open your bank and a mailbox to publish it (%s)|r", clock)
	end
	if short then return string.format("|cffff9900Update stored, not published -- waiting for the guild (%s)|r", clock) end
	return string.format("|cffff9900Bank update stored, not published yet -- waiting for the guild to answer, stay online (%s)|r", clock)
end

function TOGBankClassic_UI_StatusBar.BuildPropagationText(short)
	local P = TOGBankClassic_Propagation
	if not P then return "" end
	local deferred = deferredText(short)
	if deferred ~= "" then return deferred end
	local state, cur, online = P:Status()
	if state == "idle" then return "" end
	-- Two facts, two words (peer review B1): SENT is the transport's verdict, CONFIRMED is a peer's
	-- own message naming the version. Only confirmed turns the line green.
	if state == "synced" then
		if GetTime() - (cur.lastHolderAt or cur.since) > SYNCED_SHOWN_FOR then return "" end
		local more = cur.sent > 0 and string.format(", sent to %d more", cur.sent) or ""
		if short then
			return string.format("|cff00ff00Update confirmed by %d%s|r", cur.seen, more)
		end
		return string.format("|cff00ff00Bank update confirmed by %d guildmate%s%s|r", cur.seen, cur.seen == 1 and "" or "s", more)
	end
	local clock = clockText(P:Elapsed())
	if state == "alone" then
		if short then
			return string.format("|cff888888Update: nobody online to receive it (%s)|r", clock)
		end
		return string.format("|cff888888Bank update: no guildmate online to receive it (%s)|r", clock)
	end
	if cur.sent > 0 then
		if short then
			return string.format("|cffff9900Update sent to %d, unconfirmed -- stay online (%s)|r", cur.sent, clock)
		end
		return string.format("|cffff9900Bank update sent to %d, not confirmed by anyone yet -- stay online (%d online, %s)|r", cur.sent, online, clock)
	end
	if short then
		return string.format("|cffff4444Update not received yet -- stay online (%s)|r", clock)
	end
	return string.format("|cffff4444Bank update not received by anyone yet -- stay online (%d online, %s)|r", online, clock)
end

--- Is the propagation line one the banker must not miss -- pending or alone? Decides the narrow-bar
--- priority in RefreshSides (peer review B2).
function TOGBankClassic_UI_StatusBar.PropagationIsUrgent()
	local P = TOGBankClassic_Propagation
	if not P then return false end
	if deferredText() ~= "" then return true end   -- DEFERRED-LINE-001: it cannot go out if they log off
	local state = P:Status()
	return state == "pending" or state == "alone"
end

-- ---------------------------------------------------------------------------
-- COMPOSITION
-- ---------------------------------------------------------------------------

-- The center and right sections every window shows: the network parts, with the propagation
-- line taking the center whenever it has something to say.
-- Returns centerText, rightText, shortCenter -- the third is the narrow-bar form of the centre
-- (STATUSBAR-003), or nil when the centre has no shorter spelling. Only RefreshSides knows the
-- bar's width, so the choice between the two is made there, not here.
function TOGBankClassic_UI_StatusBar.BuildSides()
	local center, right = TOGBankClassic_UI_StatusBar.BuildNetworkParts()
	local short
	local prop = TOGBankClassic_UI_StatusBar.BuildPropagationText()
	if prop ~= "" then
		center = prop
		short = TOGBankClassic_UI_StatusBar.BuildPropagationText(true)
	end
	-- RAID-VISIBILITY-001: nothing is sent or received in a raid group (Core:SendCommMessage,
	-- Chat:OnCommReceived), so no sync line is true while one is up -- this one is. It takes the
	-- centre over both the transport text and the propagation line: an update cannot propagate
	-- from here until the raid is left, and that is the fact the banker needs. RAID-SYNC-001: the
	-- same predicate as the gates, so the line disappears the moment the setting opens them.
	if TOGBankClassic_Constants.SyncPausedByRaid() then
		center, short = "|cff888888Sync paused: in a raid group|r", nil
	end
	return center, right, short
end

-- Builds the center and right network sections from all active parts.
-- Returns centerText, rightText.
-- Returns "", "" if network info is disabled in options.
function TOGBankClassic_UI_StatusBar.BuildNetworkParts()
	if TOGBankClassic_Options and not TOGBankClassic_Options:IsStatusBarNetworkInfoEnabled() then
		return "", ""
	end

	local rightParts = {}
	local function add(s) if s ~= "" then table.insert(rightParts, s) end end

	add(TOGBankClassic_UI_StatusBar.NetTxText())
	add(TOGBankClassic_UI_StatusBar.NetBcastText())
	add(TOGBankClassic_UI_StatusBar.NetReqSyncText())
	add(TOGBankClassic_UI_StatusBar.NetRxText())
	add(TOGBankClassic_UI_StatusBar.NetQueriedReqText())

	local ctlCenter, ctlRight = TOGBankClassic_UI_StatusBar.NetCTLParts()
	add(ctlRight)

	local right = #rightParts > 0 and ("Network: " .. table.concat(rightParts, "  ")) or ""
	return ctlCenter, right
end

-- ---------------------------------------------------------------------------
-- INSTANCE
-- ---------------------------------------------------------------------------

local Instance = {}
Instance.__index = Instance

-- STATUSBAR-003: how far the centre section stays inside each edge of the bar -- the same 7 the
-- right section already keeps, so a truncated centre ends where the right would have started.
local CENTER_INSET = 7
-- STATUSBAR-005: the narrowest room between the sides the centre still paints into -- about one
-- word of the small font plus the ellipsis; below it the line is blanked rather than shown as "…".
local CENTER_MIN_ROOM = 60

-- Attaches a StatusBar controller to an AceGUI Frame window.
-- Creates center and right FontStrings for tri-part layout.
-- Returns an instance with Refresh/SetLeft/SetHovered/StartTicker/StopTicker methods.
function TOGBankClassic_UI_StatusBar:Attach(window)
	local sb = setmetatable({ window = window, hovered = false }, Instance)

	local statusbg = window.statustext:GetParent()
	window.statusbg = statusbg

	-- BREATH-001 (operator 2026-09-13, of the "stay online" line: "can you make it 'breath' as
	-- well?"): the centre text lives on its own frame so the frame's alpha can breathe -- the
	-- library's breath (LibAceGUIWidgets W:Breathe, MINOR 28, built for this ask on inbox thread
	-- 370504bb: full to a third over a second, BOUNCE, eased -- the cancelled date's glow and the
	-- help icon are the same call) -- while the line is one the banker must not miss
	-- (PropagationIsUrgent). A FontString cannot host the breath offline (the harness gives
	-- CreateAnimationGroup to Frames only), which is why the text sits on a frame of its own.
	local centerHost = CreateFrame("Frame", nil, statusbg)
	centerHost:SetPoint("LEFT", statusbg, "LEFT", CENTER_INSET, 0)
	centerHost:SetPoint("RIGHT", statusbg, "RIGHT", -CENTER_INSET, 0)
	centerHost:SetHeight(20)
	window.statusCenterHost = centerHost

	local statusCenter = centerHost:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	-- STATUSBAR-003: anchored to BOTH edges of the bar, not by its centre. A centre-only anchor has
	-- no width, so a line longer than the bar ran past the bar's left edge into the window border
	-- and over the Close button on the right (the operator's screenshot, 2026-09-12). Bounded to the
	-- bar with wrapping off, the client truncates it with an ellipsis instead; the justify keeps it
	-- centred whenever it fits, exactly as before.
	statusCenter:SetPoint("LEFT", centerHost, "LEFT", 0, 0)
	statusCenter:SetPoint("RIGHT", centerHost, "RIGHT", 0, 0)
	statusCenter:SetHeight(20)
	statusCenter:SetJustifyH("CENTER")
	statusCenter:SetWordWrap(false)
	statusCenter:SetText("")
	-- FONT-001: "ITALIC" is not a valid SetFont flag (only OUTLINE/THICKOUTLINE/MONOCHROME/
	-- etc. are). Older clients silently ignored the bad flag; the current client validates
	-- strictly and errors. The text has always rendered non-italic anyway, so re-apply with no
	-- flags to preserve appearance and stop the error. (True italic needs an italic font file.)
	local scFont, scSize = statusCenter:GetFont()
	statusCenter:SetFont(scFont, scSize, "")
	window.statusCenter = statusCenter

	local statusRight = statusbg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	statusRight:SetPoint("RIGHT", statusbg, "RIGHT", -7, 0)
	statusRight:SetHeight(20)
	statusRight:SetJustifyH("RIGHT")
	statusRight:SetText("")
	window.statusRight = statusRight

	-- STATUSBAR-002: the window's own left-text writes go through the bar. While the bar is YIELDING
	-- the left to the urgent propagation line (RefreshSides), a write is parked rather than painted
	-- -- read off the banker's Requests window on 2026-09-12, "Showing 47 requests out of 1717 total"
	-- drawn straight under the red "stay online" line: DrawContent wrote the count between two
	-- ticks (every incoming request merge redraws), and the bar only re-hid it on the next one.
	-- The newest parked text is what comes back when the line goes green or empty.
	-- POOL HYGIENE (Requests.lua's rule): the Frame goes back to AceGUI's shared pool with its
	-- instance fields intact, so the hook wraps the PRISTINE method (never a previous life's hook,
	-- whose bar might be yielding forever) and is taken off again on release -- a dialog that never
	-- attaches a bar must not inherit a SetStatusText that parks everything it is told.
	local raw = window.togRawSetStatusText or window.SetStatusText
	window.togRawSetStatusText = raw
	sb.rawSetStatusText = raw
	window.togStatusBar = sb
	window.SetStatusText = function(w, text)
		local bar = w.togStatusBar
		if bar and bar.yielding then bar.parkedLeft = text or "" else raw(w, text) end
	end
	window:SetCallback("OnRelease", function(w)
		w.SetStatusText, w.togStatusBar, w.togRawSetStatusText = raw, nil, nil
	end)

	-- Auto-stop the ticker whenever the window is hidden (covers both
	-- the close button and any programmatic Hide() call).
	window.frame:HookScript("OnHide", function() sb:StopTicker() end)
	-- A sides-only bar (DrawSides) restarts itself when its persistent window is shown again; the
	-- Inventory bar is redrawn by DrawContent on every open and needs nothing here.
	window.frame:HookScript("OnShow", function() if sb.sidesOnly then sb:DrawSides() end end)

	return sb
end

-- Attach for a window that OWNS ITS LEFT SECTION -- every window but Inventory writes its own
-- messages there with SetStatusText -- and wants the shared center/right: the network parts and
-- the SYNCED-001 propagation line. The operator, 2026-09-11: "if we add the status bar to all the
-- windows, it will work". Call once in DrawWindow (the window is hidden then): the ticker arms on
-- each show and stops on each hide, so a hidden persistent window costs nothing.
function TOGBankClassic_UI_StatusBar:AttachSides(window)
	local sb = self:Attach(window)
	sb.sidesOnly = true
	if window.frame:IsShown() then sb:DrawSides() end
	return sb
end

-- The sides-only draw: initial refresh plus the 0.5 s ticker. Re-armed by the OnShow hook.
function Instance:DrawSides()
	self.sidesOnly = true
	local c, r, s = TOGBankClassic_UI_StatusBar.BuildSides()
	self:RefreshSides(c, r, s)
	self:StartTicker(0.5, function()
		local c2, r2, s2 = TOGBankClassic_UI_StatusBar.BuildSides()
		self:RefreshSides(c2, r2, s2)
	end)
end

-- Sets up the full inventory status bar for a DrawContent pass.
-- Computes the summary text, does the initial refresh, starts the ticker,
-- and registers OnEnter/OnLeave hover callbacks on the window.
-- tabGroup is used by the hover handler to identify the currently viewed alt.
function Instance:Draw(info, roster_alts, tabGroup)
	self.baseStatusText = TOGBankClassic_UI_StatusBar.BuildInventorySummary(info, roster_alts)

	local center, right, short = TOGBankClassic_UI_StatusBar.BuildSides()
	self:Refresh(self.baseStatusText, center, right, short)

	self:StartTicker(0.5, function()
		local c, r, s = TOGBankClassic_UI_StatusBar.BuildSides()
		self:Refresh(self.baseStatusText or "", c, r, s)
	end)

	self.window:SetCallback("OnEnterStatusBar", function(_)
		local tab     = tabGroup.localstatus.selected
		local normTab = TOGBankClassic_Guild:NormalizeName(tab)
		self:SetHovered(true)
		self:SetLeft(TOGBankClassic_UI_StatusBar.BuildAltDetail(info.alts[normTab], normTab))
	end)
	self.window:SetCallback("OnLeaveStatusBar", function(_)
		self:SetHovered(false)
		local c, r, s = TOGBankClassic_UI_StatusBar.BuildSides()
		self:Refresh(self.baseStatusText or "", c, r, s)
	end)
end

-- Sets all three sections with overlap detection.
-- No-op while hovered.
function Instance:Refresh(left, center, right, short)
	if self.hovered then return end
	self.window:SetStatusText(left)
	self:RefreshSides(center, right, short)
end

-- Sets the center and right sections against whatever the left section currently shows, with
-- overlap detection: the right goes first when space is tight, then the center. The left is the
-- window's own (a sides-only bar) or was just set by Refresh. No-op while hovered.
--
-- SYNCED-001 / peer review B2, the narrow-bar rule: WHILE THE BANKER'S UPDATE IS UNCONFIRMED the
-- propagation line wins the bar over the window's own left text -- it is transient and it is the
-- one line that is about them, exactly when it matters; the left text is the window's permanent
-- label and comes back the moment the line goes green or empty. The window keeps calling
-- SetStatusText meanwhile (parked by the Attach hook while yielding, STATUSBAR-002): the newest
-- text is what is measured here and what is restored.
--
-- STATUSBAR-003: `short` is the centre's narrow-bar spelling (BuildSides). It replaces `center`
-- when the full line is wider than the bar itself -- not when it merely collides with the sides,
-- which the yield below already handles. A short line that STILL does not fit is left to the
-- FontString's own truncation (Attach), so nothing can overflow the bar either way.
function Instance:RefreshSides(center, right, short)
	if self.hovered then return end
	local w = self.window
	local rawSet = self.rawSetStatusText
	local barWidth = w.statusbg and w.statusbg:GetWidth() or 500
	w.statusCenter:SetText(center)
	if short and short ~= center and w.statusCenter:GetStringWidth() > barWidth - 2 * CENTER_INSET then
		center = short
		w.statusCenter:SetText(center)
	end
	w.statusRight:SetText(right)
	-- Measure the left the window WANTS, not the blank it was given while yielding.
	if self.yielding then rawSet(w, self.parkedLeft or "") end

	local leftW       = w.statustext:GetStringWidth()
	local centerW     = w.statusCenter:GetStringWidth()
	local rightW      = w.statusRight:GetStringWidth()
	local gap         = 12

	local centerLeft  = barWidth / 2 - centerW / 2
	local centerRight = barWidth / 2 + centerW / 2
	local rightLeft   = barWidth - 7 - rightW

	local centerFits = center ~= "" and (leftW + gap <= centerLeft)
	if not centerFits and center ~= "" and TOGBankClassic_UI_StatusBar.PropagationIsUrgent() then
		-- The urgent line does not fit beside the left text: the left yields. What the window
		-- wanted is parked, so it comes back intact -- and so a write between two ticks is parked
		-- too, rather than painted under the line until the next tick.
		self.parkedLeft = w.statustext:GetText() or ""
		self.yielding = true
		rawSet(w, "")
		centerFits = true
	else
		-- Not urgent any more, or it fits: the wanted text is already on the string.
		self.yielding, self.parkedLeft = false, nil
	end

	local allThreeFit = centerFits and (centerRight + gap <= rightLeft)
	local rightShown = right ~= "" and allThreeFit
	if not rightShown then w.statusRight:SetText("") end
	-- STATUSBAR-005 (Peer Review d0170ec1 on STATUSBAR-003: "the green line yields to the SIDES when
	-- they need the room, but never to NOTHING"): a centre that does not fit CENTRED on the bar
	-- beside the left text used to be blanked outright, so a synced banker on a narrow window saw
	-- an empty bar -- the failure the whole line was built against, seen from the other side. The
	-- centre's host frame is bounded to the ROOM the sides leave (left text + gap .. right text +
	-- gap) and the FontString centres and truncates inside it, so it says something whenever there
	-- is room for a word; only a room too small for that (under CENTER_MIN_ROOM) blanks it. The
	-- urgent yield above still hands it the whole bar.
	local host = w.statusCenterHost
	local leftEdge  = CENTER_INSET + ((leftW > 0 and not self.yielding) and (leftW + gap) or 0)
	local rightEdge = CENTER_INSET + (rightShown and (rightW + gap) or 0)
	if host then
		host:ClearAllPoints()
		host:SetPoint("LEFT",  w.statusbg, "LEFT",  leftEdge, 0)
		host:SetPoint("RIGHT", w.statusbg, "RIGHT", -rightEdge, 0)
		host:SetHeight(20)
	end
	local room = barWidth - leftEdge - rightEdge
	if not centerFits then
		if short and short ~= center then
			center = short
			w.statusCenter:SetText(center)
		end
		if room < CENTER_MIN_ROOM then
			center = ""
			w.statusCenter:SetText("")
		end
	end
	-- BREATH-001: the line breathes while it is one the banker must not miss, and only while it is
	-- actually on the bar; a green or empty centre sits still at full alpha.
	local W = TOGBankClassic_UI.Widgets
	if host and W and W.Breathe then
		if center ~= "" and TOGBankClassic_UI_StatusBar.PropagationIsUrgent() then
			W:Breathe(host)
		else
			W:StopBreathing(host)
		end
	end
end

-- Sets only the left section and clears center/right.
-- Bypasses the hovered guard AND the yield (hover content is what the operator asked to see);
-- use this to push hover content.
function Instance:SetLeft(text)
	self.rawSetStatusText(self.window, text)
	self.window.statusCenter:SetText("")
	self.window.statusRight:SetText("")
	local host, W = self.window.statusCenterHost, TOGBankClassic_UI.Widgets
	if host and W and W.StopBreathing then W:StopBreathing(host) end
end

-- Controls whether Refresh() is a no-op.
function Instance:SetHovered(hovered)
	self.hovered = hovered
end

-- Starts a recurring ticker. fn() is called each tick.
function Instance:StartTicker(interval, fn)
	self:StopTicker()
	self.ticker = C_Timer.NewTicker(interval, fn)
end

-- Cancels the ticker if running.
function Instance:StopTicker()
	if self.ticker then
		self.ticker:Cancel()
		self.ticker = nil
	end
end
