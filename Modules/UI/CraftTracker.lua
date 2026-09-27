-- Modules/UI/CraftTracker.lua -- GSL-MERGE-001 build step 4 (v1.7.0): the Reagent Tracker, D5 of
-- docs/GSL_MERGE.md. GuildShoppingList's detached overlay -- "the piece of GSL a gatherer actually
-- uses while out in the world" -- as a small window of its own showing the Shopping List tab's
-- reagent roll-up: what the list still needs, what the bank and the [GSL] character hold, what you
-- carry, and what the [GSL] character is still missing (GSL-BANK-001).
--
-- Nothing new underneath (the operator's rule): the rows are UI_CraftList:ReagentRows, the columns
-- its REAGENT_COLUMNS, the list UI/RowList, the position and size UI:PersistWindow. It repaints when
-- the list changes (UI_CraftList:OnListChanged), and on BAG_UPDATE_DELAYED while shown -- the You
-- column moves as you gather -- registered on show and dropped on hide, as ItemHighlight
-- does with its bag events.
--
-- NOT on Escape, deliberately: it is meant to stay up while you play, and a window the Escape
-- stand-in counts would swallow every Escape pressed in the world (closing the tracker instead of
-- opening the game menu). Its close button and /togbank tracker close it. It IS in
-- UI.ALPHA_WINDOWS (its own transparency slider) and not in UI.ESCAPE_WINDOWS (ESC-SPLIT-001).
TOGBankClassic_UI_CraftTracker = {}
local Tracker = TOGBankClassic_UI_CraftTracker

Tracker.DEFAULT_W, Tracker.DEFAULT_H = 400, 260
Tracker.MIN_W, Tracker.MIN_H = 320, 160

function Tracker:Build()
	local UI = TOGBankClassic_UI
	local window = UI:Create("Frame")
	window:Hide()
	window:SetTitle(UI:WindowTitle("Reagent Tracker"))
	window:SetLayout("Fill")
	window:SetCallback("OnClose", function() Tracker:Close() end)
	UI:PersistWindow(window, "tracker", Tracker.DEFAULT_W, Tracker.DEFAULT_H, Tracker.MIN_W, Tracker.MIN_H)
	UI:ApplyThinBorder(window, "tracker")
	self.Window = window
	local host = CreateFrame("Frame", nil, window.content)
	host:SetAllPoints(window.content)
	self.List = TOGBankClassic_UI_RowList:New(host, {
		columns = TOGBankClassic_UI_CraftList.REAGENT_COLUMNS,
		onRowEnter = function(entry) if entry and entry.link then UI:ShowItemTooltip(entry.link) end end,
		onRowLeave = function() UI:HideTooltip() end,
	})
	self.List:SetSort("missing", true)
	local events = CreateFrame("Frame")
	events:SetScript("OnEvent", function() if Tracker.isOpen then Tracker:Refresh() end end)
	self.Events = events
end

function Tracker:Open()
	if not self.Window then self:Build() end
	self.isOpen = true
	self.Window:Show()
	self.Events:RegisterEvent("BAG_UPDATE_DELAYED")
	self:Refresh()
end

function Tracker:Close()
	if not self.isOpen then return end
	self.isOpen = false
	if self.Events then self.Events:UnregisterEvent("BAG_UPDATE_DELAYED") end
	if self.Window then self.Window:Hide() end
end

function Tracker:Toggle()
	if self.isOpen then self:Close() else self:Open() end
end

--- Repaint from the model. The status line counts what is still missing.
function Tracker:Refresh()
	if not (self.isOpen and self.List) then return end
	local rows, unknown = TOGBankClassic_UI_CraftList:ReagentRows()
	self.rowsShown = rows
	self.List:SetData(rows, true)
	local missing = 0
	for _, r in ipairs(rows) do if r.missing > 0 then missing = missing + 1 end end
	local text
	if #rows == 0 then
		text = "Nothing to gather: the shopping list is empty or already covered"
	elseif missing == 0 then
		text = string.format("All %d reagent%s covered", #rows, #rows == 1 and "" or "s")
	else
		text = string.format("%d of %d reagent%s still missing", missing, #rows, #rows == 1 and "" or "s")
	end
	if #unknown > 0 then text = text .. string.format(" (%d recipe%s not in your ProfessionDB)", #unknown, #unknown == 1 and "" or "s") end
	self.statusText = text
	self.Window:SetStatusText(text)
end
