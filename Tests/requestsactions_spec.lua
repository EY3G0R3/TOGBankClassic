-- REQUESTS-ACTIONS: everything on the Requests body that is NOT the list -- the dialogs behind the
-- action icons (cancel with a reason, delete, re-open, mark hand-off), the bottom-row cluster's
-- buttons (Cancel Stale, Fulfill Oldest), the bag listener behind the fulfil icons, the dropdown
-- click-outside catcher and Escape, the help text, the tab tooltips -- and the officer Settings
-- panel: the three numeric fields and the custom cancel-reason editor.
--
-- Self-audit 1ebe87b4 F3: Requests.lua stood at 65% line coverage, the uncovered ~700 lines being
-- exactly this -- shipped, never driven offline, and REQUESTS-ROWLIST-002 (an error on the tab's
-- FIRST open in game) is what a 1580-green suite could not see there. Every function below is
-- driven against the REAL AceGUI-3.0 and the harness's frame model; the Guild, Mail, Options and
-- StatusBar modules are steerable stubs because this file is about the body's own behaviour, not
-- theirs. The standalone window is the host: it is the simpler of the two renderings and the body
-- is the same in both (browse_spec covers the embedded chrome).
package.path = "./Tests/?.lua;" .. package.path
local env    = require("env_togbank")
local wow    = require("env.wow")
local frames = require("env.frames")

local ME, ALICE, GALDOF = "Bankchar-Testrealm", "Alice-Testrealm", "Galdof-Testrealm"
local R, G, calls

--- The body on its standalone window, over stubs a spec can steer. `opts.me` is who is looking
--- (a banker by default), `opts.officer` gives them the Settings tab, `opts.members` the roster
--- size GetNumGuildMembers reports (0 = "not loaded yet").
local function load(opts)
	opts = opts or {}
	env.reset()
	frames.reset()
	env.stubOutput()
	require("env.libs").load("LibAceGUIWidgets-1.0")
	env.loadUI()
	env.loadModules({ "Modules/Constants.lua", "Modules/Item.lua" })
	env.loadFile("Modules/UI/RowList.lua")
	env.loadFile("Modules/UI/Requests.lua")
	R = TOGBankClassic_UI_Requests
	R:Init()
	env.defineItem(2589, { name = "Linen Cloth" })
	calls = {}
	local function rec(name, ret)
		return function(_, ...)
			calls[#calls + 1] = { name, ... }
			if ret ~= nil then return ret end
			return true
		end
	end
	G = {
		Info = { name = "Testguild", alts = {}, roster = { alts = {} }, requests = {}, settings = {} },
		GetNormalizedPlayer = function() return opts.me or ME end,
		NormalizeName = function(_, n) return n end,
		IsBank = function(_, n) return n == ME or n == ALICE end,
		SenderIsGM = function() return opts.gm or false end,
		CanCancelRequest = function() return true end,
		CanCompleteRequest = function() return true end,
		CanDeleteRequest = function() return true end,
		CanManageRequests = function() return true end,
		RequestQuantityNeeded = function(_, req) return (tonumber(req.quantity) or 0) - (tonumber(req.fulfilled) or 0) end,
		QueryRequestsIndex = function() end,
		CancelRequest = rec("CancelRequest", opts.cancelOk),
		DeleteRequest = rec("DeleteRequest", opts.deleteOk),
		ReopenRequest = rec("ReopenRequest", opts.reopenOk),
		FulfillRequestById = function(_, id, n, actor)
			calls[#calls + 1] = { "FulfillRequestById", id, n, actor }
			if opts.fulfillApplied ~= nil then return opts.fulfillApplied end
			return n
		end,
		ExpireStaleRequests = function(_, actor)
			calls[#calls + 1] = { "ExpireStaleRequests", actor }
			return opts.expired or 0
		end,
		BroadcastSettings = rec("BroadcastSettings"),
		PeerSpeaksDataLeg = function() return true end,
		GetAltItems = function() return {} end,
	}
	TOGBankClassic_Guild = G
	TOGBankClassic_UI_StatusBar = { AttachSides = function() return {} end }
	TOGBankClassic_Mail = {
		isOpen = opts.mailboxOpen or false,
		IsBankOpen = function() return opts.bankOpen or false end,
		CanFulfillRequest = function() return false, opts.fulfillReason or "not in bags", 0 end,
		PrepareFulfillMail = function() calls[#calls + 1] = { "PrepareFulfillMail" }; return true, "prepared" end,
		BankCollectStep = function() calls[#calls + 1] = { "BankCollectStep" }; return true, "collected one" end,
		FulfillStep = function() calls[#calls + 1] = { "FulfillStep" }; return true, "filled one" end,
	}
	TOGBankClassic_ItemHighlight = {
		enabled = false,
		SetEnabled = function(self, v) self.enabled = v end,
		ClearAllOverlays = function() end,
	}
	TOGBankClassic_Options = {
		db = { global = { requests = {} }, char = { framePositions = {} } },
		GetAutoTombstoneDays = function(self) return self.db.global.requests.autoTombstoneDays or 30 end,
		GetMaxRequestPercent = function(self) return self.db.global.requests.maxRequestPercent or 100 end,
	}
	TOGBankClassic_UI_Inventory = { isOpen = false }
	TOGBankClassic_UI_Browse = nil
	_G.TOGBankClassic = { Show = function() end, Hide = function() end }
	_G.CanViewOfficerNote = function() return opts.officer or false end
	-- Harness gap (audit 1ebe87b4 F5): UI:HideTooltip re-anchors through this FrameXML helper.
	_G.GameTooltip_SetDefaultAnchor = _G.GameTooltip_SetDefaultAnchor or function() end
	_G.GetNumGuildMembers = function() if opts.members ~= nil then return opts.members end return 3 end
	_G.MailFrame = nil
end

local function unload()
	if R and R.isOpen then R:Close() end
	_G.TOGBankClassic_UI_Requests = nil
	_G.TOGBankClassic_UI_StatusBar = nil
	_G.TOGBankClassic_UI_Inventory = nil
	_G.TOGBankClassic_ItemHighlight = nil
	_G.TOGBankClassic = nil
end

local function addReq(over)
	over = over or {}
	local r = { id = "r1", date = time() - 3600, requester = GALDOF, bank = ME, item = "Linen Cloth", itemID = 2589,
		quantity = 5, fulfilled = 0, status = "open" }
	for k, v in pairs(over) do r[k] = v end
	G.Info.requests[r.id] = r
	return r
end

--- The first drawn row's cells.
local function row(i)
	local r = R.List.rows[i or 1]
	assert(r and r:IsShown(), "no drawn row " .. tostring(i or 1))
	return r
end

local function named(what)
	local out = {}
	for _, c in ipairs(calls) do if c[1] == what then out[#out + 1] = c end end
	return out
end

local function status() return R.Window.statustext:GetText() end

--- Every line on the (harness's rich) GameTooltip, joined.
local function tipText()
	local out = {}
	for _, l in ipairs(GameTooltip:GetLines()) do out[#out + 1] = l.left or "" end
	return table.concat(out, "\n")
end

-- ─── The cancel-reason dialog ──────────────────────────────────────────────────

describe("REQUESTS-ACTIONS: the cancel-reason dialog", function()
	before_each(function() load() end)
	after_each(unload)

	--- The dialog's AceGUI buttons, found by their text rather than their position (AceGUI's Button
	--- writes the text on its fontstring, not the button).
	local function button(text)
		for _, child in ipairs(R.CancelDialog.children) do
			if child.type == "Button" and child.text:GetText() == text then return child end
		end
		error("no button " .. text .. " on the cancel dialog")
	end

	it("opens from the cancel icon with the banker presets, the default selected, and cancels with the chosen reason", function()
		local req = addReq()
		R:Open()
		local actions = row().cells.actions
		assert.is_true(actions.cancel:IsShown(), "the cancel icon is not shown on an open request the actor may cancel")
		actions.cancel:Fire("OnClick")
		assert.is_table(R.CancelDialog, "no dialog was built")
		assert.is_true(R.CancelDialog.frame:IsShown())
		-- A banker cancelling someone's request sees the banker presets; the default is "unavailable".
		local dd = R.CancelDropdown
		assert.equal("unavailable", dd:GetValue())
		assert.truthy(dd.list.policy and dd.list.policy:find("100%", 1, true), "the policy preset does not carry the live max-request percent")
		assert.is_nil(dd.list.changed_mind, "a member preset was offered to a banker")
		-- Pick another reason, confirm: the request is cancelled with THAT reason's text.
		dd:Fire("OnValueChanged", "wrong_bank")
		button("Cancel Request"):Fire("OnClick")
		local c = named("CancelRequest")
		assert.equal(1, #c)
		assert.equal(req.id, c[1][2]); assert.equal(ME, c[1][3])
		assert.truthy(c[1][4]:find("another banker's keep", 1, true), "the chosen reason's text was not passed")
		assert.is_false(R.CancelDialog.frame:IsShown(), "the dialog stayed up after confirming")
	end)

	it("Keep Request closes it with nothing cancelled; a second open reuses the one frame; closing it via the X too", function()
		addReq()
		R:Open()
		row().cells.actions.cancel:Fire("OnClick")
		local dialog = R.CancelDialog
		button("Keep Request"):Fire("OnClick")
		assert.is_false(dialog.frame:IsShown())
		assert.equal(0, #named("CancelRequest"))
		row().cells.actions.cancel:Fire("OnClick")
		assert.equal(dialog, R.CancelDialog, "a second dialog frame was built")
		assert.is_true(dialog.frame:IsShown())
		-- While it is up a second click on the icon does nothing (no re-arm of the pending request).
		row().cells.actions.cancel:Fire("OnClick")
		assert.is_true(dialog.frame:IsShown())
		dialog:Fire("OnClose")
		assert.is_false(dialog.frame:IsShown())
		-- Confirm with nothing pending (the dialog was closed): no cancel is issued.
		button("Cancel Request"):Fire("OnClick")
		assert.equal(0, #named("CancelRequest"))
	end)

	it("says so on the status line when the cancel is refused", function()
		load({ cancelOk = false })
		addReq()
		R:Open()
		row().cells.actions.cancel:Fire("OnClick")
		button("Cancel Request"):Fire("OnClick")
		assert.equal("Unable to cancel request.", status())
	end)

	it("offers a MEMBER the member presets with 'changed_mind' as the default", function()
		load({ me = GALDOF })
		addReq()
		R:Open()
		row().cells.actions.cancel:Fire("OnClick")
		assert.equal("changed_mind", R.CancelDropdown:GetValue())
		assert.is_nil(R.CancelDropdown.list.unavailable, "a banker preset was offered to a member")
		assert.truthy(R.CancelDropdown.list.found_ah)
	end)

	it("drops the presets officers disabled, appends the custom reasons for the role, and falls back when the default is gone", function()
		G.Info.settings.cancelReasons = {
			presetDisabled = { banker = { unavailable = true, policy = true } },
			custom = {
				{ text = "Ask an officer first.", banker = true, member = false },
				{ text = "Members only.", banker = false, member = true },
				"garbage",
				{ text = "", banker = true },
			},
		}
		addReq()
		R:Open()
		row().cells.actions.cancel:Fire("OnClick")
		local dd = R.CancelDropdown
		assert.is_nil(dd.list.unavailable); assert.is_nil(dd.list.policy)
		assert.equal("wrong_bank", dd:GetValue(), "with the default disabled the first remaining preset should be selected")
		assert.equal("Ask an officer first.", dd.list.custom1)
		assert.is_nil(dd.list.custom2, "a member-only custom reason was offered to a banker")
		-- The custom reason is what gets recorded when picked.
		dd:Fire("OnValueChanged", "custom1")
		button("Cancel Request"):Fire("OnClick")
		assert.equal("Ask an officer first.", named("CancelRequest")[1][4])
	end)

	it("always offers at least one reason when every preset is disabled and nothing custom targets the role", function()
		G.Info.settings.cancelReasons = {
			presetDisabled = { banker = { unavailable = true, policy = true, wrong_bank = true, first_come = true, duplicate = true, not_in_guild = true } },
			custom = {},
		}
		addReq()
		R:Open()
		row().cells.actions.cancel:Fire("OnClick")
		assert.equal("none", R.CancelDropdown:GetValue())
		assert.equal("Request cancelled.", R.CancelDropdown.list.none)
	end)
end)

-- ─── The StaticPopup dialogs ───────────────────────────────────────────────────

describe("REQUESTS-ACTIONS: delete, re-open and mark hand-off", function()
	before_each(function() load() end)
	after_each(unload)

	local function lastPopup()
		local p = wow.popups[#wow.popups]
		assert(p, "no StaticPopup was shown")
		return p
	end

	it("delete: confirms with the request's details, then deletes on Yes -- and says so when refused", function()
		local req = addReq()
		R:Open()
		row().cells.actions.delete:Fire("OnClick")
		local p = lastPopup()
		assert.equal("TOGBankClassic_DeleteRequest", p.which)
		assert.truthy(p.text1:find("5x Linen Cloth from " .. GALDOF .. " to " .. ME, 1, true), p.text1)
		assert.equal(req.id, p.data.requestId); assert.equal(ME, p.data.actor)
		p.info.OnAccept(nil, p.data)
		assert.same({ "DeleteRequest", req.id, ME }, named("DeleteRequest")[1])
		-- No data (the client can call OnAccept without it): nothing happens.
		p.info.OnAccept(nil, nil)
		assert.equal(1, #named("DeleteRequest"))
		-- Registered once: a second show reuses the dialog table.
		row().cells.actions.delete:Fire("OnClick")
		assert.equal(p.info, StaticPopupDialogs["TOGBankClassic_DeleteRequest"])
		-- Refused: the status line says so.
		G.DeleteRequest = function() return false end
		p.info.OnAccept(nil, p.data)
		assert.equal("Unable to delete request.", status())
	end)

	it("re-open: only a finished order shows the icon; Yes re-opens it, a refusal is said", function()
		addReq({ status = "complete", fulfilled = 5 })
		R:Open()
		local actions = row().cells.actions
		assert.is_true(actions.reopen:IsShown(), "no re-open icon on a completed order")
		assert.is_false(actions.cancel:IsShown(), "a completed order still offers cancel")
		assert.is_false(actions.fulfill:IsShown(), "a completed order still offers fulfil")
		actions.reopen:Fire("OnClick")
		local p = lastPopup()
		assert.equal("TOGBankClassic_ReopenRequest", p.which)
		assert.truthy(p.text1:find("Re-open the request for 5x Linen Cloth from " .. GALDOF, 1, true), p.text1)
		p.info.OnAccept(nil, p.data)
		assert.same({ "ReopenRequest", "r1", ME }, named("ReopenRequest")[1])
		p.info.OnAccept(nil, nil)
		assert.equal(1, #named("ReopenRequest"))
		G.ReopenRequest = function() return false end
		p.info.OnAccept(nil, p.data)
		assert.equal("Unable to re-open request.", status())
	end)

	it("mark hand-off: asks how many, defaults to what is still owed, clamps to it, and records by id", function()
		addReq({ quantity = 5, fulfilled = 2 })
		R:Open()
		row().cells.actions.complete:Fire("OnClick")
		local p = lastPopup()
		assert.equal("TOGBankClassic_CompleteQty", p.which)
		assert.truthy(p.text1:find("up to 3 remaining", 1, true), p.text1)
		assert.equal(3, p.data.defaultQty); assert.equal(3, p.data.maxQty)
		-- STATICPOPUP-001: the Era dialog exposes its edit box through GetEditBox, and OnShow seeds it.
		local dialog = CreateFrame("Frame")
		local eb = CreateFrame("EditBox", nil, dialog)
		dialog.GetEditBox = function() return eb end
		dialog.data = p.data
		p.info.OnShow(dialog)
		assert.equal("3", eb:GetText(), "the edit box was not seeded with the remaining quantity")
		assert.is_true(eb:HasFocus())
		-- Over the cap: clamped to what is owed.
		eb:SetText("9")
		p.info.OnAccept(dialog)
		assert.same({ "FulfillRequestById", "r1", 3, ME }, named("FulfillRequestById")[1])
		-- Under one: refused with a message, nothing recorded.
		eb:SetText("0")
		p.info.OnAccept(dialog)
		assert.equal(1, #named("FulfillRequestById"))
		assert.equal("Enter a quantity of 1 or more.", status())
		-- A fractional entry is floored.
		eb:SetText("2.7")
		p.info.OnAccept(dialog)
		assert.equal(2, named("FulfillRequestById")[2][3])
		-- The guild applied nothing: said.
		G.FulfillRequestById = function() return 0 end
		eb:SetText("1")
		p.info.OnAccept(dialog)
		assert.equal("Unable to record that quantity.", status())
		-- No data on the dialog: nothing happens.
		p.info.OnAccept({ data = nil })
	end)

	it("mark hand-off: reads the LEGACY editBox / button1 fields when the accessors are absent, and Enter / Escape drive the dialog", function()
		addReq()
		R:Open()
		row().cells.actions.complete:Fire("OnClick")
		local p = lastPopup()
		local dialog = CreateFrame("Frame")
		local eb = CreateFrame("EditBox", nil, dialog)
		local btn = CreateFrame("Button", nil, dialog)
		local clicked = 0
		btn:SetScript("OnClick", function() clicked = clicked + 1 end)
		dialog.editBox, dialog.button1, dialog.data = eb, btn, p.data
		p.info.OnShow(dialog)
		assert.equal("5", eb:GetText(), "the legacy editBox field was not read")
		p.info.EditBoxOnEnterPressed(eb)
		assert.equal(1, clicked, "Enter did not click button1 through the legacy field")
		dialog:Show()
		p.info.EditBoxOnEscapePressed(eb)
		assert.is_false(dialog:IsShown(), "Escape did not hide the dialog")
		-- The accessor forms win when present.
		local btn2 = CreateFrame("Button", nil, dialog)
		local clicked2 = 0
		btn2:SetScript("OnClick", function() clicked2 = clicked2 + 1 end)
		dialog.GetButton1 = function() return btn2 end
		p.info.EditBoxOnEnterPressed(eb)
		assert.equal(1, clicked2); assert.equal(1, clicked)
		-- OnShow with no edit box at all is a no-op.
		p.info.OnShow({ data = p.data })
	end)

	it("does nothing when the client has no StaticPopup at all", function()
		addReq()
		R:Open()
		local show = _G.StaticPopup_Show
		_G.StaticPopup_Show = nil
		row().cells.actions.delete:Fire("OnClick")
		row().cells.actions.complete:Fire("OnClick")
		_G.StaticPopup_Show = show
		assert.equal(0, #wow.popups)
	end)
end)

-- ─── The bottom-row cluster ────────────────────────────────────────────────────

describe("REQUESTS-ACTIONS: the Cancel Stale broom and the Fulfill Oldest envelope", function()
	before_each(function() load() end)
	after_each(unload)

	it("broom: confirms with the configured threshold, expires on Yes, and reports the count (or none)", function()
		load({ expired = 2 })
		TOGBankClassic_Options.db.global.requests.autoTombstoneDays = 14
		addReq()
		R:Open()
		assert.is_table(R.CancelStaleBtn, "a banker has no broom")
		R.CancelStaleBtn:Fire("OnClick")
		local p = wow.popups[#wow.popups]
		assert.equal("TOGBankClassic_CancelStale", p.which)
		assert.truthy(p.text1:find("older than 14 days", 1, true), p.text1)
		p.info.OnAccept(nil, p.data)
		assert.equal(ME, named("ExpireStaleRequests")[1][2])
		assert.equal("Cancelled 2 stale requests.", status())
		G.ExpireStaleRequests = function() return 1 end
		p.info.OnAccept(nil, p.data)
		assert.equal("Cancelled 1 stale request.", status())
		G.ExpireStaleRequests = function() return 0 end
		p.info.OnAccept(nil, p.data)
		assert.equal("No stale requests found.", status())
		p.info.OnAccept(nil, nil)
		-- Its tooltip names the threshold.
		R.CancelStaleBtn:Fire("OnEnter", R.CancelStaleBtn)
		assert.is_true(GameTooltip:IsShown())
		assert.truthy(tipText():find("older than 14 days", 1, true), "the broom's tooltip does not name the threshold")
		R.CancelStaleBtn:Fire("OnLeave")
		assert.is_false(GameTooltip:IsShown())
	end)

	it("envelope: at a MAILBOX it fills, at the BANK it collects, and the status line carries the step's message", function()
		addReq()
		R:Open()
		assert.is_table(R.FulfillOldestBtn, "a banker has no envelope")
		R.FulfillOldestBtn:Fire("OnClick")
		assert.equal(1, #named("FulfillStep")); assert.equal(0, #named("BankCollectStep"))
		assert.equal("filled one", status())
		TOGBankClassic_Mail.IsBankOpen = function() return true end
		R.FulfillOldestBtn:Fire("OnClick")
		assert.equal(1, #named("BankCollectStep"))
		assert.equal("collected one", status())
		R.FulfillOldestBtn:Fire("OnEnter", R.FulfillOldestBtn)
		assert.is_true(GameTooltip:IsShown())
		R.FulfillOldestBtn:Fire("OnLeave")
	end)

	it("a member has neither; an officer who is not a banker has the broom only", function()
		load({ me = GALDOF })
		R:Open()
		assert.is_nil(R.CancelStaleBtn); assert.is_nil(R.FulfillOldestBtn)
		load({ me = GALDOF, officer = true })
		R:Open()
		assert.is_table(R.CancelStaleBtn); assert.is_nil(R.FulfillOldestBtn)
	end)
end)

-- ─── The bag listener ──────────────────────────────────────────────────────────

describe("REQUESTS-ACTIONS: the fulfil icons follow the bags", function()
	before_each(function() load() end)
	after_each(unload)

	--- Deliver a bag event to the frames THIS window built. Other spec files' modules keep their own
	--- listeners alive across files (the frame registry is weak, and a module global still holds
	--- them), so a bare fireEvent counts theirs too in a full run.
	local function fireBags(before)
		return frames.fireEventFiltered(function(o) return not before[o] end, "BAG_UPDATE_DELAYED")
	end
	local function snapshot()
		local seen = {}
		for _, o in pairs(frames.objects) do seen[o] = true end
		return seen
	end

	it("refreshes the fulfil icons on BAG_UPDATE_DELAYED at once, throttles a burst to one deferred refresh, and stops when the window closes", function()
		addReq()
		local before = snapshot()
		R:Open()
		local refreshed = 0
		local real = R._RefreshFulfillButtons
		R._RefreshFulfillButtons = function(self, ...) refreshed = refreshed + 1; return real(self, ...) end
		-- The first event past the throttle window refreshes immediately.
		wow.advanceTime(1)
		assert.equal(1, fireBags(before), "the banker's bag listener is not registered")
		assert.equal(1, refreshed)
		-- Two more inside the window: ONE deferred refresh, not two.
		fireBags(before); fireBags(before)
		assert.equal(1, refreshed)
		assert.equal(1, wow.pendingTimerCount(), "a burst armed more than one deferred refresh")
		wow.advanceTime(0.6)
		assert.equal(2, refreshed, "the deferred refresh did not run")
		-- Closed: the deferred refresh finds the window shut and does nothing; the listener is gone.
		fireBags(before)   -- inside the window again: arms a timer
		R:Close()
		wow.advanceTime(1)
		assert.equal(2, refreshed, "a refresh ran on a closed window")
		assert.equal(0, fireBags(before), "the listener survived Close")
	end)

	it("a member's window registers no bag listener", function()
		load({ me = GALDOF })
		local before = snapshot()
		R:Open()
		assert.equal(0, fireBags(before))
	end)

	it("the refresh hides the icon on a row whose request completed between draws", function()
		local req = addReq()
		R:Open()
		local actions = row().cells.actions
		assert.is_true(actions.fulfill:IsShown())
		req.status = "complete"
		R:_RefreshFulfillButtons(ME, true, false)
		assert.is_false(actions.fulfill:IsShown())
		R.List = nil
		R:_RefreshFulfillButtons(ME, true, false)   -- no list: a no-op
	end)
end)

-- ─── Dropdowns, Escape, help, tabs ─────────────────────────────────────────────

describe("REQUESTS-ACTIONS: the dropdown click-outside catcher, Escape, the help text and the tab tooltips", function()
	before_each(function() load() end)
	after_each(unload)

	it("opening a filter dropdown lays an invisible catcher under it; a click on the catcher closes the pullout; Escape closes it and is consumed", function()
		R:Open()
		local dd = R.FilterRequester
		dd.pullout:Open("TOPLEFT", dd.frame, "BOTTOMLEFT", 0, 0)
		assert.is_true(dd.pullout.frame:IsShown())
		local catcher
		for _, o in pairs(frames.objects) do
			if o._strata == "FULLSCREEN_DIALOG" and o:GetScript("OnMouseDown") and o:GetParent() == UIParent then catcher = o end
		end
		assert.is_table(catcher, "no click catcher was laid under the open pullout")
		assert.is_true(catcher:IsShown())
		catcher:Fire("OnMouseDown")
		assert.is_false(dd.pullout.frame:IsShown(), "a click outside did not close the pullout")
		assert.is_false(catcher:IsShown())
		-- Escape on the window: an open pullout is closed and the key consumed; otherwise it propagates.
		-- (SetPropagateKeyboardInput is a harness no-op with no getter, so the instance records it.)
		local frame = R.Window.frame
		local propagate
		frame.SetPropagateKeyboardInput = function(_, v) propagate = v end
		R.FilterBank.pullout:Open("TOPLEFT", R.FilterBank.frame, "BOTTOMLEFT", 0, 0)
		frame:Fire("OnKeyDown", "ESCAPE")
		assert.is_false(R.FilterBank.pullout.frame:IsShown())
		assert.is_false(propagate, "Escape that closed a dropdown was propagated to the window")
		frame:Fire("OnKeyDown", "ESCAPE")
		assert.is_true(propagate, "Escape with nothing to close was consumed")
		propagate = nil
		frame:Fire("OnKeyDown", "A")
		assert.is_true(propagate)
		frame.SetPropagateKeyboardInput = nil
		-- Installed once per frame.
		assert.is_true(frame.togRequestsKeyHooked)
	end)

	it("the help icon's tooltip is the body's help text, and the sub-tabs carry their own", function()
		R:Open()
		-- WINDOW-CHROME-001: the "?" is the shared chrome's (UI:DressWindow), cached on the frame.
		local help = R.Window.frame.togChromeHelp
		assert.is_table(help)
		assert.equal(help, R.Window.togChrome.help)
		help:Fire("OnEnter", help)
		assert.is_true(GameTooltip:IsShown())
		assert.truthy(tipText():find("Guild Requests", 1, true))
		assert.truthy(tipText():find("Mark hand%-off"))
		help:Fire("OnLeave")
		assert.is_false(GameTooltip:IsShown())
		-- Tab tooltips: the TabGroup fires OnTabEnter with the value and the tab frame.
		local tabFrame = CreateFrame("Button")
		R.TabGroup:Fire("OnTabEnter", "archive", tabFrame)
		assert.is_true(GameTooltip:IsShown())
		assert.truthy(tipText():find("Completed and cancelled", 1, true), "the Archive tab's tooltip was not shown")
		R.TabGroup:Fire("OnTabLeave")
		assert.is_false(GameTooltip:IsShown())
		R.TabGroup:Fire("OnTabEnter", "nonsense", tabFrame)   -- no tip: nothing shown
		assert.is_false(GameTooltip:IsShown())
		-- The Requester / Bank labels have hover tooltips of their own (a hit frame over each).
		local hits = 0
		for _, o in pairs(frames.objects) do
			if o.GetScript and o:GetParent() == R.FilterRequester.frame and o:GetScript("OnEnter") then
				o:Fire("OnEnter", o); o:Fire("OnLeave"); hits = hits + 1
			end
		end
		assert.is_true(hits >= 1, "no hover hit frame over the Requester label")
	end)

	it("the highlight checkbox: built for a banker once the roster is loaded, from the strip or from a later UpdateFilters", function()
		load({ members = 0 })
		R:Open()
		assert.is_nil(R.HighlightCheckbox, "a checkbox was built before the roster loaded")
		_G.GetNumGuildMembers = function() return 3 end
		R:UpdateFilters()
		assert.is_table(R.HighlightCheckbox, "UpdateFilters did not add the checkbox once the roster was there")
		assert.same({ colspan = 3 }, R.HighlightCheckbox:GetUserData("cell"), "the late-built checkbox is not on its own strip row")
		assert.is_false(R:EnsureHighlightCheckbox(), "a second call built another")
		R.HighlightCheckbox:Fire("OnValueChanged", true)
		assert.is_true(TOGBankClassic_ItemHighlight.enabled)
		R.HighlightCheckbox:Fire("OnEnter"); assert.is_true(GameTooltip:IsShown()); R.HighlightCheckbox:Fire("OnLeave")
		-- A member never gets one.
		load({ me = GALDOF })
		R:Open()
		assert.is_nil(R.HighlightCheckbox)
	end)
end)

-- ─── The tails: filters, fulfil states, docking, Toggle ────────────────────────

describe("REQUESTS-ACTIONS: the filter dropdowns, the fulfil icon's states, docking and Toggle", function()
	before_each(function() load() end)
	after_each(unload)

	it("a dropdown pick narrows to that name from the top; 'Any' clears it; a section separator snaps back to the current value", function()
		addReq({ id = "a", requester = GALDOF })
		addReq({ id = "b", requester = ALICE, bank = ALICE })
		R:Open()
		R.requesterFilter, R.bankFilter = nil, nil
		R:DrawRows()
		local drawn, scrolls = 0, {}
		local real = R.DrawRows
		R.DrawRows = function(self, preserve) drawn = drawn + 1; scrolls[drawn] = preserve; return real(self, preserve) end
		R.FilterRequester:Fire("OnValueChanged", GALDOF)
		assert.equal(GALDOF, R.requesterFilter)
		assert.is_false(scrolls[1], "a new filter kept the scroll position")
		assert.equal(1, #R.rowsShown)
		R.FilterRequester:Fire("OnValueChanged", "__tog_any__")
		assert.is_nil(R.requesterFilter)
		assert.equal(2, #R.rowsShown)
		-- The dropdown's section headings are not values: picking one puts the current value back.
		local before = drawn
		R.FilterBank:Fire("OnValueChanged", "__tog_sep_hist__")
		assert.equal(before, drawn, "a separator pick redrew")
		assert.equal("__tog_any__", R.FilterBank:GetValue())
		R.FilterBank:Fire("OnValueChanged", ALICE)
		assert.equal(ALICE, R.bankFilter)
		R.FilterBank:Fire("OnValueChanged", "__tog_sep_hist__")
		assert.equal(ALICE, R.FilterBank:GetValue(), "the separator did not snap back to the current bank")
	end)

	it("the dropdown history section: names with no open request sit under a second heading, ordered by count then name", function()
		load({ me = "Nobody-Testrealm" })
		addReq({ id = "a", requester = GALDOF, status = "complete", fulfilled = 5 })
		addReq({ id = "b", requester = ALICE, status = "complete", fulfilled = 5 })
		addReq({ id = "c", requester = ALICE, status = "complete", fulfilled = 5 })
		addReq({ id = "d", requester = "Zed-Testrealm" })
		addReq({ id = "e", requester = "Amy-Testrealm" })
		R:Open()
		local order = R.cachedRequesterOrder
		-- me, [sep], any, [open heading], Amy, Zed (one open each, by name), [history heading], Alice (2), Galdof (1)
		assert.same({ "Nobody-Testrealm", "__tog_sep_me_any__", "__tog_any__", "__tog_sep_any_rest__", "Amy-Testrealm", "Zed-Testrealm",
			"__tog_sep_hist__", ALICE, GALDOF }, order)
		assert.equal("(2) " .. ALICE, R.cachedRequesterList[ALICE])
	end)

	it("the fulfil icon's state follows Mail:CanFulfillRequest's verdict, one icon and tooltip per reason", function()
		addReq({ quantity = 5 })
		R:Open()
		local icon = row().cells.actions.fulfill
		local seen = {}
		local function state(canFulfill, reason, inBags, mailboxOpen)
			TOGBankClassic_Mail.CanFulfillRequest = function() return canFulfill, reason, inBags or 0 end
			R:_RefreshFulfillButtons(ME, true, mailboxOpen or false)
			local detail = icon.togTooltipDetail
			assert.is_string(detail)
			seen[#seen + 1] = icon.icon:GetText() .. "|" .. detail
			return detail
		end
		assert.truthy(state(true, nil, 5, true):find("Attach 5", 1, true))
		assert.is_false(icon.togDisabled); assert.equal(1, icon:GetAlpha())
		assert.equal("Open a mailbox to fulfill this request.", state(true, nil, 5, false))
		assert.is_true(icon.togDisabled); assert.equal(0.4, icon:GetAlpha())
		assert.equal("Partial: 3 of 5", state(true, "Partial: 3 of 5", 3, true))
		assert.equal("Split the stack first", state(true, "Split the stack first", 5, true))
		assert.truthy(state(false, "in mail and bank"):find("split between", 1, true))
		assert.truthy(state(false, "in mail"):find("mail inbox", 1, true))
		assert.truthy(state(false, "shortfall in bank and mail", 2):find("Have 2 in bags. More available in your bank and mail", 1, true))
		assert.truthy(state(false, "shortfall in mail", 2):find("Have 2 in bags. More available in your mail", 1, true))
		assert.truthy(state(false, "shortfall in bank", 2):find("Have 2 in bags. More available in your bank", 1, true))
		assert.equal("not in bags (3 short)", state(false, "not in bags (3 short)"))
		assert.equal("Pick up items from bank first.", state(false, nil))
		-- STALE-REQ-001 rides on the not-found branch only.
		G.PeerSpeaksDataLeg = function() return false, "1.3.2" end
		assert.truthy(state(false, "not found anywhere"):find("is on v1.3.2", 1, true))
		assert.is_nil(state(false, "in mail"):find("is on v1.3.2", 1, true))
	end)

	it("the item cell's hover shows the bank's own link for the requested variant, else a suffixed item string, else the name", function()
		local req = addReq({ itemID = 4564, suffixID = 1180, item = "Spiked Club" })
		G.Info.alts = { [ME] = {} }
		G.GetAltItems = function() return {
			{ ID = 4564, Link = "|cff1eff00|Hitem:4564:0:0:0:0:0:28|h[Spiked Club of Spirit]|h|r" },
			{ ID = 4564, Link = "|cff1eff00|Hitem:4564:0:0:0:0:0:1180|h[Spiked Club of the Bear]|h|r" },
		} end
		TOGBankClassic_Item.RowSuffixID = function(_, item) return tonumber(item.Link:match("item:%d+:%d*:%d*:%d*:%d*:%d*:(%d+)")) end
		local links = {}
		rawset(GameTooltip, "SetHyperlink", function(_, l) links[#links + 1] = l end)
		R:Open()
		local eb = row().cells.item.editbox
		eb:Fire("OnEnter", eb)
		assert.truthy(links[1]:find("[Spiked Club of the Bear]", 1, true), "the hover did not pick the requested variant's own link: " .. tostring(links[1]))
		eb:Fire("OnLeave")
		-- No bank holds it: a suffixed item string is built for the tooltip.
		G.GetAltItems = function() return {} end
		eb:Fire("OnEnter", eb)
		assert.equal("item:4564:0:0:0:0:0:1180", links[2])
		-- No suffix on the request: the bare item string.
		req.suffixID = nil
		R:DrawRows()
		eb:Fire("OnEnter", eb)
		assert.equal("item:4564", links[3])
		-- A legacy request (no itemID) searches by name and shows the name when nothing matches.
		req.itemID = nil
		R:DrawRows()
		eb:Fire("OnEnter", eb)
		assert.equal(3, #links, "a nameless lookup set a hyperlink")
		assert.truthy(tipText():find("Spiked Club", 1, true))
		G.GetAltItems = function() return { { ID = 4564, Link = "|cff1eff00|Hitem:4564|h[Spiked Club]|h|r", Info = { name = "Spiked Club" } } } end
		eb:Fire("OnEnter", eb)
		assert.truthy(links[4]:find("[Spiked Club]", 1, true), "the legacy name lookup did not find the bank's link")
		-- Nothing to name: no tooltip work at all.
		eb._itemName = ""
		eb:Fire("OnEnter", eb)
		assert.equal(4, #links)
	end)

	it("Toggle opens and closes; a window opened beside the Inventory window docks to its right edge; a role change rebuilds it", function()
		R:Toggle()
		assert.is_true(R.isOpen)
		R:Toggle()
		assert.is_false(R.isOpen)
		assert.is_false(R.Window.frame:IsShown())
		R:Close()   -- already closed: a no-op
		-- Docked beside the open Inventory window -- placed, on a screen with room to its right, or
		-- ClampFrameToScreen (rightly) pulls the docked window back on-screen and off the anchor.
		UIParent:SetSize(4000, 2000)
		local inv = TOGBankClassic_UI:Create("Frame")
		inv:SetWidth(500); inv:SetHeight(400)
		inv.frame:ClearAllPoints(); inv.frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 100, 100)
		TOGBankClassic_UI_Inventory = { isOpen = true, Window = inv }
		R:Open()
		local docked
		for i = 1, R.Window.frame:GetNumPoints() do
			local point, rel, relPoint = R.Window.frame:GetPoint(i)
			if rel == inv.frame then docked = point .. "/" .. relPoint end
		end
		assert.equal("TOPLEFT/TOPRIGHT", docked, "the window did not dock to the Inventory window's right edge")
		-- The banker status changed since the window was built: the window is released and rebuilt
		-- for the new role (AceGUI pools frames, so the same widget object comes back -- the proof
		-- is the role-bound cluster and the remembered role, not the identity).
		assert.is_true(R.wasBank); assert.is_table(R.CancelStaleBtn)
		local released = 0
		local realRelease = R.ReleaseWindow
		R.ReleaseWindow = function(self) released = released + 1; return realRelease(self) end
		R:Close()
		G.IsBank = function() return false end
		R:Open()
		assert.equal(1, released, "the window was not rebuilt for the role change")
		assert.is_false(R.wasBank)
		assert.is_nil(R.CancelStaleBtn)
		R.ReleaseWindow = nil
		-- Escape closes the Requester pullout too.
		R.FilterRequester.pullout:Open("TOPLEFT", R.FilterRequester.frame, "BOTTOMLEFT", 0, 0)
		R.Window.frame:Fire("OnKeyDown", "ESCAPE")
		assert.is_false(R.FilterRequester.pullout.frame:IsShown())
		-- The Bank label's hover, and a Settings label's (an officer's).
		for _, o in pairs(frames.objects) do
			if o.GetScript and o:GetParent() == R.FilterBank.frame and o:GetScript("OnEnter") then o:Fire("OnEnter", o) end
		end
		assert.truthy(tipText():find("Filter by Banker", 1, true))
		load({ officer = true })
		R:Open()
		R.TabGroup:SelectTab("settings")
		local found
		for _, o in pairs(frames.objects) do
			if o.GetScript and o:GetParent() == R.SettingsOverlay and o:GetScript("OnEnter") then
				o:Fire("OnEnter", o)
				if tipText():find("Archive threshold", 1, true) then found = true end
				o:Fire("OnLeave")
			end
		end
		assert.is_true(found or false, "no hover hit frame over the Archive label")
	end)

	it("the Archive tab keeps only requests older than the archive threshold; Requests keeps the rest", function()
		TOGBankClassic_Options.db.global.requests.archiveDays = 10
		addReq({ id = "old", date = time() - 11 * 86400, status = "complete", fulfilled = 5 })
		addReq({ id = "new", date = time() - 3600 })
		addReq({ id = "undated", date = 0 })
		R:Open()
		R.requesterFilter, R.bankFilter = nil, nil
		R:DrawRows()
		local ids = {}
		for _, e in ipairs(R.rowsShown) do ids[e.req.id] = true end
		assert.same({ new = true, undated = true }, ids)
		R.TabGroup:SelectTab("archive")
		R.requesterFilter, R.bankFilter = nil, nil
		R:DrawRows()
		assert.equal(1, #R.rowsShown); assert.equal("old", R.rowsShown[1].req.id)
	end)
end)

-- ─── The officer Settings panel ────────────────────────────────────────────────

describe("REQUESTS-ACTIONS: the officer Settings panel", function()
	before_each(function() load({ officer = true }) end)
	after_each(unload)

	local function openSettings()
		R:Open()
		R.TabGroup:SelectTab("settings")
		assert.equal("settings", R.currentTab)
		assert.is_table(R.SettingsOverlay, "no settings overlay")
		assert.is_true(R.SettingsOverlay:IsShown())
	end

	local function commit(eb, text)
		eb:SetText(text)
		eb:Fire("OnEnterPressed", eb)
	end

	local function infos()
		local out = {}
		for _, c in ipairs(TOGBankClassic_Output.calls) do if c.level == "Info" then out[#out + 1] = c[1] end end
		return out
	end

	it("is a tab for an officer only, hides the list while up, and shows the current values", function()
		openSettings()
		assert.is_false(R.ListHost:IsShown(), "the list is still showing under the panel")
		assert.is_false(R.SearchBox.frame:IsShown())
		assert.equal("30", R.SettingsArchiveEB:GetText())
		assert.equal("30", R.SettingsTombstoneEB:GetText())
		assert.equal("100", R.SettingsMaxPctEB:GetText())
		assert.truthy(status():find("Officer settings", 1, true))
		R.TabGroup:SelectTab("active")
		assert.is_false(R.SettingsOverlay:IsShown())
		assert.is_true(R.ListHost:IsShown())
		-- A non-officer has no Settings tab at all, and ShowSettings(true) with no panel is a no-op.
		load({})
		R:Open()
		assert.is_nil(R.SettingsOverlay)
		R:ShowSettings(true)
		assert.is_true(R.ListHost:IsShown() == false, "ShowSettings hid nothing it could not replace")
	end)

	it("archive days: a whole number of at least 1 is saved locally and announced; anything else is ignored and the field re-filled", function()
		openSettings()
		commit(R.SettingsArchiveEB, "45")
		assert.equal(45, TOGBankClassic_Options.db.global.requests.archiveDays)
		assert.equal("Archive threshold set to %d days.", infos()[1])
		commit(R.SettingsArchiveEB, "0")
		assert.equal(45, TOGBankClassic_Options.db.global.requests.archiveDays)
		assert.equal("45", R.SettingsArchiveEB:GetText(), "a refused value was left in the field")
		commit(R.SettingsArchiveEB, "45")   -- unchanged: no second announcement
		assert.equal(1, #infos())
		assert.equal(0, #named("BroadcastSettings"), "the archive threshold is local, not guild-wide")
		R.SettingsArchiveEB:Fire("OnEscapePressed", R.SettingsArchiveEB)
	end)

	it("auto-cancel days: written to the guild settings AND the local copy, then broadcast", function()
		openSettings()
		commit(R.SettingsTombstoneEB, "7")
		assert.equal(7, G.Info.settings.autoTombstoneDays)
		assert.equal(7, TOGBankClassic_Options.db.global.requests.autoTombstoneDays)
		assert.equal(1, #named("BroadcastSettings"))
		assert.equal("ALERT", named("BroadcastSettings")[1][2])
		assert.equal("7", R.SettingsTombstoneEB:GetText())
		commit(R.SettingsTombstoneEB, "7")
		assert.equal(1, #named("BroadcastSettings"), "an unchanged value was broadcast again")
		commit(R.SettingsTombstoneEB, "x")
		assert.equal(7, G.Info.settings.autoTombstoneDays)
	end)

	it("max request percent: clamped to 1..100, floored, guild-wide", function()
		openSettings()
		commit(R.SettingsMaxPctEB, "250")
		-- Clamped to 100, which IS the current value: nothing written, nothing broadcast.
		assert.is_nil(TOGBankClassic_Options.db.global.requests.maxRequestPercent)
		assert.is_nil(G.Info.settings.maxRequestPercent)
		assert.equal(0, #named("BroadcastSettings"), "an unchanged (clamped) value was broadcast")
		assert.equal("100", R.SettingsMaxPctEB:GetText(), "the field was not re-filled with the clamped value")
		commit(R.SettingsMaxPctEB, "0")
		assert.equal(1, G.Info.settings.maxRequestPercent)
		assert.equal(1, #named("BroadcastSettings"))
		commit(R.SettingsMaxPctEB, "33.9")
		assert.equal(33, G.Info.settings.maxRequestPercent)
		assert.equal("33", R.SettingsMaxPctEB:GetText())
		-- The banker's "policy" cancel preset carries the new number.
		addReq()
		R.TabGroup:SelectTab("active")
		row().cells.actions.cancel:Fire("OnClick")
		assert.truthy(R.CancelDropdown.list.policy:find("33%", 1, true))
	end)

	it("the settings survive a tab revisit on the same frame: one overlay, found again", function()
		openSettings()
		local overlay = R.SettingsOverlay
		R.TabGroup:SelectTab("active")
		R.TabGroup:SelectTab("settings")
		assert.equal(overlay, R.SettingsOverlay)
		R:Close()
		R:Open()
		R.TabGroup:SelectTab("settings")
		assert.equal(overlay, R.SettingsOverlay, "a second overlay was built on the pooled frame")
		assert.equal(overlay.togRefs.SettingsArchiveEB, R.SettingsArchiveEB, "the found-again overlay's fields were not re-pointed")
	end)
end)

-- ─── The custom cancel-reason editor ───────────────────────────────────────────

describe("REQUESTS-ACTIONS: the custom cancel-reason editor", function()
	before_each(function()
		load({ officer = true })
		R:Open()
		R.TabGroup:SelectTab("settings")
	end)
	after_each(unload)

	local PRESETS = 6 + 5   -- banker presets, then member presets, in the list

	local function rowsShown()
		local n = 0
		for _, r in ipairs(R.ReasonRows) do if r:IsShown() then n = n + 1 end end
		return n
	end

	local function save(text, member, banker)
		R.ReasonInput:SetText(text)
		if member ~= nil then R.ReasonNewMember:SetChecked(member) end
		if banker ~= nil then R.ReasonNewBanker:SetChecked(banker) end
		R.ReasonSaveBtn:Fire("OnClick")
	end

	it("lists the built-in presets greyed with their native-role tick, then the custom reasons", function()
		assert.equal(PRESETS, rowsShown())
		local first = R.ReasonRows[1]
		assert.equal("preset", first._entry.kind); assert.equal("banker", first._entry.role)
		assert.is_true(first.bankerCB:IsShown()); assert.is_false(first.memberCB:IsShown())
		assert.is_true(first.bankerCB:GetChecked()); assert.is_false(first.deleteBtn:IsShown())
		local member = R.ReasonRows[7]
		assert.equal("member", member._entry.role)
		assert.is_true(member.memberCB:IsShown()); assert.is_false(member.bankerCB:IsShown())
		-- Banded: every second row shows its background.
		assert.is_false(R.ReasonRows[1].bg:IsShown()); assert.is_true(R.ReasonRows[2].bg:IsShown())
		assert.equal(PRESETS * 18, R.ReasonContent:GetHeight())
	end)

	it("adds a reason from the strip (Save or Enter), trims it, resets the strip, syncs, and lists it with both ticks", function()
		save("  Ask an officer first.  ", true, false)
		local cfg = G.Info.settings.cancelReasons
		assert.same({ { text = "Ask an officer first.", member = true, banker = false } }, cfg.custom)
		assert.equal(1, #named("BroadcastSettings"))
		assert.equal("", R.ReasonInput:GetText())
		assert.is_true(R.ReasonNewMember:GetChecked()); assert.is_true(R.ReasonNewBanker:GetChecked())
		assert.equal(PRESETS + 1, rowsShown())
		local last = R.ReasonRows[PRESETS + 1]
		assert.equal("custom", last._entry.kind)
		assert.is_true(last.memberCB:GetChecked()); assert.is_false(last.bankerCB:GetChecked())
		assert.is_true(last.deleteBtn:IsShown())
		-- Enter saves too; blank saves nothing.
		R.ReasonInput:SetText("Second")
		R.ReasonInput:Fire("OnEnterPressed", R.ReasonInput)
		assert.equal(2, #cfg.custom)
		R.ReasonInput:SetText("   ")
		R.ReasonInput:Fire("OnEnterPressed", R.ReasonInput)
		assert.equal(2, #cfg.custom)
		-- Escape abandons the strip.
		R.ReasonInput:SetText("typed")
		R.ReasonInput:Fire("OnEscapePressed", R.ReasonInput)
		assert.equal("", R.ReasonInput:GetText())
	end)

	it("toggling a custom row's ticks writes the config; un-ticking a preset disables it for its role -- and the cancel dialog follows", function()
		save("Custom one", true, true)
		local custom = R.ReasonRows[PRESETS + 1]
		custom.memberCB:SetChecked(false)
		custom.memberCB:Fire("OnClick", custom.memberCB)
		assert.is_false(G.Info.settings.cancelReasons.custom[1].member)
		assert.equal(2, #named("BroadcastSettings"))
		-- The first banker preset ("unavailable"), off.
		local first = R.ReasonRows[1]
		first.bankerCB:SetChecked(false)
		first.bankerCB:Fire("OnClick", first.bankerCB)
		assert.is_true(G.Info.settings.cancelReasons.presetDisabled.banker.unavailable)
		first.bankerCB:SetChecked(true)
		first.bankerCB:Fire("OnClick", first.bankerCB)
		assert.is_nil(G.Info.settings.cancelReasons.presetDisabled.banker.unavailable)
		first.bankerCB:SetChecked(false)
		first.bankerCB:Fire("OnClick", first.bankerCB)
		-- Now cancel a request as the banker: "unavailable" is gone, the custom reason is offered.
		addReq()
		R.TabGroup:SelectTab("active")
		row().cells.actions.cancel:Fire("OnClick")
		assert.is_nil(R.CancelDropdown.list.unavailable)
		assert.equal("policy", R.CancelDropdown:GetValue())
		assert.equal("Custom one", R.CancelDropdown.list.custom1)
	end)

	it("click a custom row to edit it in the strip; Save rewrites it in place; the X deletes it and fixes up the edit index", function()
		save("Alpha", true, true); save("Beta", true, true); save("Gamma", true, true)
		local cfg = G.Info.settings.cancelReasons
		local beta = R.ReasonRows[PRESETS + 2]
		beta:Fire("OnClick")
		assert.equal(2, R.ReasonEditIndex)
		assert.equal("Beta", R.ReasonInput:GetText())
		assert.is_true(R.ReasonInput:HasFocus())
		save("Beta edited", false, true)
		assert.same({ text = "Beta edited", member = false, banker = true }, cfg.custom[2])
		assert.is_nil(R.ReasonEditIndex)
		assert.equal(3, #cfg.custom, "an edit added a row instead of rewriting")
		-- Editing Gamma (3) while Alpha (1) is deleted: the edit index slides down to 2.
		R.ReasonRows[PRESETS + 3]:Fire("OnClick")
		assert.equal(3, R.ReasonEditIndex)
		R.ReasonRows[PRESETS + 1].deleteBtn:Fire("OnClick")
		assert.equal(2, #cfg.custom); assert.equal("Beta edited", cfg.custom[1].text)
		assert.equal(2, R.ReasonEditIndex, "the edit index did not follow the row it points at")
		-- Deleting the row being edited abandons the edit and clears the strip.
		R.ReasonRows[PRESETS + 2].deleteBtn:Fire("OnClick")
		assert.equal(1, #cfg.custom)
		assert.is_nil(R.ReasonEditIndex); assert.equal("", R.ReasonInput:GetText())
		assert.equal(PRESETS + 1, rowsShown())
		-- A preset row: no edit on click, no delete.
		R.ReasonRows[1]:Fire("OnClick")
		assert.is_nil(R.ReasonEditIndex)
		R.ReasonRows[1].deleteBtn:Fire("OnClick")
		assert.equal(1, #cfg.custom)
		-- The X's tooltip.
		R.ReasonRows[PRESETS + 1].deleteBtn:Fire("OnEnter", R.ReasonRows[PRESETS + 1].deleteBtn)
		assert.is_true(GameTooltip:IsShown())
		R.ReasonRows[PRESETS + 1].deleteBtn:Fire("OnLeave")
	end)

	it("refuses the 21st custom reason with a status message", function()
		for i = 1, 20 do save("Reason " .. i) end
		assert.equal(20, #G.Info.settings.cancelReasons.custom)
		save("One too many")
		assert.equal(20, #G.Info.settings.cancelReasons.custom)
		assert.equal("Custom reason limit reached (20).", status())
		-- Editing an existing one at the cap still works.
		R.ReasonRows[PRESETS + 20]:Fire("OnClick")
		save("Reason 20 edited")
		assert.equal("Reason 20 edited", G.Info.settings.cancelReasons.custom[20].text)
	end)

	it("the wheel scrolls the list three rows at a time, clamped to its range", function()
		for i = 1, 20 do save("Reason " .. i) end
		local scroll = R.ReasonScroll
		scroll:Fire("OnMouseWheel", 1)     -- up from the top: stays at 0
		assert.equal(0, scroll:GetVerticalScroll())
		scroll:Fire("OnMouseWheel", -1)
		assert.equal(math.min(54, scroll:GetVerticalScrollRange()), scroll:GetVerticalScroll())
		for _ = 1, 50 do scroll:Fire("OnMouseWheel", -1) end
		assert.equal(scroll:GetVerticalScrollRange(), scroll:GetVerticalScroll(), "scrolled past the end")
	end)

	it("tolerates a guild with no settings table (a member client before the first sync)", function()
		G.Info.settings = nil
		assert.is_nil(R:_EnsureReasonConfig())
		save("Nothing to write to")
		assert.equal(0, #named("BroadcastSettings"))
		R:_OnReasonToggle({ kind = "custom", index = 1 }, "member", true)
		R:_OnReasonDelete(1)
		R:_OnReasonEdit(1)
		assert.is_nil(R.ReasonEditIndex)
	end)
end)
