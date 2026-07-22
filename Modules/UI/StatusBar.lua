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
--   BuildAltDetail(alt)
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
-- COMPOSITION
--   BuildNetworkParts() -> centerText, rightText
--       Calls all Net* functions and assembles the "Network: ..." right
--       string. Returns "", "" when network info is disabled in options.
--
-- INSTANCE
--   TOGBankClassic_StatusBar:Attach(window) -> sb
--       Wires up the tri-part FontStrings on an AceGUI Frame's status bar
--       and returns a controller. Call once in DrawWindow.
--
--   sb:Draw(info, roster_alts, tabGroup)
--       One-shot setup for an inventory window: computes summary text, does
--       the initial refresh, starts the 0.5 s ticker, and registers the
--       OnEnter/OnLeave hover callbacks. Call once per DrawContent pass.
--       Teardown is automatic — the ticker stops on window Hide.
--   sb:Refresh(left, center, right)   apply all three sections (no-op while hovered)
--   sb:SetLeft(text)                  push hover content; bypasses hovered guard
--   sb:SetHovered(bool)               block/unblock Refresh
--   sb:StartTicker(interval, fn)      low-level ticker control (used by Draw)
--   sb:StopTicker()                   cancel the ticker (called automatically on Hide)

TOGBankClassic_StatusBar = {}

-- ---------------------------------------------------------------------------
-- FORMATTERS
-- ---------------------------------------------------------------------------

-- Formats a copper amount as colored text (gold/silver/copper).
-- Replaces GetCoinTextureString() which renders broken square icons in AceGUI status bars.
function TOGBankClassic_StatusBar.FormatMoney(copper)
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
function TOGBankClassic_StatusBar.GetSlotColor(percent)
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
function TOGBankClassic_StatusBar.FormatSlots(used, total)
	local percent = total > 0 and (used / total) or 0
	local color = TOGBankClassic_StatusBar.GetSlotColor(percent)
	return string.format("|c%s%d/%d|r", color, used, total)
end

-- ---------------------------------------------------------------------------
-- INVENTORY STATUS
-- ---------------------------------------------------------------------------

-- Builds the normal left-section text: total money and slots across all banker alts.
function TOGBankClassic_StatusBar.BuildInventorySummary(info, roster_alts)
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
	return TOGBankClassic_StatusBar.FormatMoney(total_gold)
		.. "    "
		.. TOGBankClassic_StatusBar.FormatSlots(slots, total_slots)
end

-- Builds the hover detail string for a single alt.
-- Returns a plain fallback string if the alt is missing or not yet synced.
function TOGBankClassic_StatusBar.BuildAltDetail(alt)
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

	local mailCount = 0
	if alt.mail and alt.mail.items then
		for _ in pairs(alt.mail.items) do mailCount = mailCount + 1 end
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
		TOGBankClassic_StatusBar.FormatMoney(alt.money or 0),
		TOGBankClassic_StatusBar.FormatSlots(slot_count, slot_total),
		mailText)
end

-- ---------------------------------------------------------------------------
-- NETWORK STATUS
-- Each function returns a formatted string, or "" when the part is inactive.
-- ---------------------------------------------------------------------------

-- P2P sends in flight: "Tx:1/3"
function TOGBankClassic_StatusBar.NetTxText()
	local sends = TOGBankClassic_Guild.pendingSendCount or 0
	if sends == 0 then return "" end
	local max = TOGBankClassic_Guild.MAX_PENDING_SENDS or 3
	local c = (sends >= max) and "ffff4444" or "ffff9900"
	return string.format("|c%sTx:%d/%d|r", c, sends, max)
end

-- Broadcast queue depth: "Bcast:2"
function TOGBankClassic_StatusBar.NetBcastText()
	local syncQ = TOGBankClassic_Chat and TOGBankClassic_Chat.sync_queue and #TOGBankClassic_Chat.sync_queue or 0
	if syncQ == 0 then return "" end
	return string.format("|cffffff00Bcast:%d|r", syncQ)
end

-- Request-index handshake: "r:3/10" or "r:ids"
function TOGBankClassic_StatusBar.NetReqSyncText()
	local rSync = TOGBankClassic_Guild.requestsIndexSync
	if not rSync or not rSync.awaitingById then return "" end
	local bTotal = rSync.batchTotal
	if bTotal and bTotal > 0 then
		return string.format("|cff87ceebr:%d/%d|r", rSync.batchSent or 0, bTotal)
	end
	return "|cff87ceebr:ids|r"
end

-- P2P fetches in flight: "Rx:2"
function TOGBankClassic_StatusBar.NetRxText()
	local fetches = 0
	if TOGBankClassic_Guild.pendingP2PRequests then
		for _ in pairs(TOGBankClassic_Guild.pendingP2PRequests) do fetches = fetches + 1 end
	end
	if fetches == 0 then return "" end
	return string.format("|cff87ceebRx:%d|r", fetches)
end

-- Queried requests pending reply: "Req:5"
function TOGBankClassic_StatusBar.NetQueriedReqText()
	local count = TOGBankClassic_Guild:GetQueriedRequestsCount()
	if count == 0 then return "" end
	return string.format("|cff98fb98Req:%d|r", count)
end

-- ChatThrottleLib queue — two outputs from one inspection pass.
-- Returns centerText ("Sending X to Y"), rightText ("CTL:42").
-- Both are "" when the CTL queue is empty.
local CTL_PRIO_ORDER = {"ALERT", "NORMAL", "BULK"}
function TOGBankClassic_StatusBar.NetCTLParts()
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

-- ---------------------------------------------------------------------------
-- COMPOSITION
-- ---------------------------------------------------------------------------

-- Builds the center and right network sections from all active parts.
-- Returns centerText, rightText.
-- Returns "", "" if network info is disabled in options.
function TOGBankClassic_StatusBar.BuildNetworkParts()
	if TOGBankClassic_Options and not TOGBankClassic_Options:IsStatusBarNetworkInfoEnabled() then
		return "", ""
	end

	local rightParts = {}
	local function add(s) if s ~= "" then table.insert(rightParts, s) end end

	add(TOGBankClassic_StatusBar.NetTxText())
	add(TOGBankClassic_StatusBar.NetBcastText())
	add(TOGBankClassic_StatusBar.NetReqSyncText())
	add(TOGBankClassic_StatusBar.NetRxText())
	add(TOGBankClassic_StatusBar.NetQueriedReqText())

	local ctlCenter, ctlRight = TOGBankClassic_StatusBar.NetCTLParts()
	add(ctlRight)

	local right = #rightParts > 0 and ("Network: " .. table.concat(rightParts, "  ")) or ""
	return ctlCenter, right
end

-- ---------------------------------------------------------------------------
-- INSTANCE
-- ---------------------------------------------------------------------------

local Instance = {}
Instance.__index = Instance

-- Attaches a StatusBar controller to an AceGUI Frame window.
-- Creates center and right FontStrings for tri-part layout.
-- Returns an instance with Refresh/SetLeft/SetHovered/StartTicker/StopTicker methods.
function TOGBankClassic_StatusBar:Attach(window)
	local sb = setmetatable({ window = window, hovered = false }, Instance)

	local statusbg = window.statustext:GetParent()
	window.statusbg = statusbg

	local statusCenter = statusbg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	statusCenter:SetPoint("CENTER", statusbg, "CENTER", 0, 0)
	statusCenter:SetHeight(20)
	statusCenter:SetJustifyH("CENTER")
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

	-- Auto-stop the ticker whenever the window is hidden (covers both
	-- the close button and any programmatic Hide() call).
	window.frame:HookScript("OnHide", function() sb:StopTicker() end)

	return sb
end

-- Sets up the full inventory status bar for a DrawContent pass.
-- Computes the summary text, does the initial refresh, starts the ticker,
-- and registers OnEnter/OnLeave hover callbacks on the window.
-- tabGroup is used by the hover handler to identify the currently viewed alt.
function Instance:Draw(info, roster_alts, tabGroup)
	self.baseStatusText = TOGBankClassic_StatusBar.BuildInventorySummary(info, roster_alts)

	local center, right = TOGBankClassic_StatusBar.BuildNetworkParts()
	self:Refresh(self.baseStatusText, center, right)

	self:StartTicker(0.5, function()
		local c, r = TOGBankClassic_StatusBar.BuildNetworkParts()
		self:Refresh(self.baseStatusText or "", c, r)
	end)

	self.window:SetCallback("OnEnterStatusBar", function(_)
		local tab     = tabGroup.localstatus.selected
		local normTab = TOGBankClassic_Guild:NormalizeName(tab)
		self:SetHovered(true)
		self:SetLeft(TOGBankClassic_StatusBar.BuildAltDetail(info.alts[normTab]))
	end)
	self.window:SetCallback("OnLeaveStatusBar", function(_)
		self:SetHovered(false)
		local c, r = TOGBankClassic_StatusBar.BuildNetworkParts()
		self:Refresh(self.baseStatusText or "", c, r)
	end)
end

-- Sets all three sections with overlap detection.
-- No-op while hovered.
function Instance:Refresh(left, center, right)
	if self.hovered then return end
	local w = self.window
	w:SetStatusText(left)
	w.statusCenter:SetText(center)
	w.statusRight:SetText(right)

	local barWidth    = w.statusbg and w.statusbg:GetWidth() or 500
	local leftW       = w.statustext:GetStringWidth()
	local centerW     = w.statusCenter:GetStringWidth()
	local rightW      = w.statusRight:GetStringWidth()
	local gap         = 12

	local centerLeft  = barWidth / 2 - centerW / 2
	local centerRight = barWidth / 2 + centerW / 2
	local rightLeft   = barWidth - 7 - rightW

	local allThreeFit = (leftW + gap <= centerLeft) and (centerRight + gap <= rightLeft)
	if not (right  ~= "" and allThreeFit)                 then w.statusRight:SetText("")  end
	if not (center ~= "" and (leftW + gap <= centerLeft)) then w.statusCenter:SetText("") end
end

-- Sets only the left section and clears center/right.
-- Bypasses the hovered guard; use this to push hover content.
function Instance:SetLeft(text)
	self.window:SetStatusText(text)
	self.window.statusCenter:SetText("")
	self.window.statusRight:SetText("")
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
