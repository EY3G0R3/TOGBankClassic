-- FILL-ALERT-001: THE INSTANT PATH FOR A FILLED ORDER, END TO END, ON THE REAL TRANSPORT.
--
-- The operator, 2026-09-17, on two whole clients of the v1.6.0 tree: "i filled a request, and the
-- instant path didn't work" -- "the instant path is supposed to be an alert and instantly upgrade
-- filled orders, i'm not receiving those alerts to update orders" -- "they come through fine in the
-- 'normal' sync which can take 10-60 mins dependant on congestion, the alert should cut through
-- that" -- "do you have end to end tests in the test harness for the alert sync path?"
--
-- No. requestchain_spec drives an ADD across two clients, xguildfleet_spec a sister guild's request
-- and its COMPLETION by whisper, logapi_spec applies a fulfill entry to one client by hand. Nothing
-- drove a banker's FILL -- the mail leaving, Mail:ApplyPendingSend crediting the order, the
-- `fulfill` mutation on `togbank-rm` at ALERT -- through the real AceCommQueue, AceComm and
-- ChatThrottleLib to a guildmate's request row. These examples do, on both of env_fleet's wires,
-- and they say what "instant" means: the row moves on the ALERT alone, with no index sync having
-- run, and it moves while the banker's login burst is still draining, because ALERT is the
-- priority that exists to go ahead of BULK.
package.path = "./Tests/?.lua;" .. package.path
local F   = require("env_fleet")
local env = F.env

local BANK, REQ, OTHER = "Bankchar", "Requester", "Bystander"
local ITEM_ID, ITEM, QTY = 2589, "Linen Cloth", 10

local function guild(wire)
	local c = F.new({
		{ name = BANK,  note = "gbank", client = true, money = 100 },
		{ name = REQ,   client = true },
		{ name = OTHER, client = true },
	}, { wire = wire })
	env.defineItem(ITEM_ID, { name = ITEM })
	return c
end

local function noErrors(c)
	assert.same({}, F.output(c, "Error"), c.name .. " raised an Error")
end

local function requestOn(c, id)
	return F.with(c, function() return c.G.TOGBankClassic_Guild.Info.requests[id] end)
end

--- The requester orders QTY of the item from the banker; every client of the guild holds it open.
local function place(c)
	local b, r = c[BANK], c[REQ]
	F.scan(b, { { id = ITEM_ID, count = 40 } }, { bank = {}, money = 100 })
	local ok, why = F.with(r, function()
		return r.G.TOGBankClassic_Guild:AddRequest({ requester = r.norm, bank = b.norm, item = ITEM, itemID = ITEM_ID, quantity = QTY })
	end)
	assert.is_true(ok, "the requester could not place the order: " .. tostring(why))
	-- Fifteen seconds: a fresh ChatThrottleLib is inside its five-second hard clamp (~80 bytes/s),
	-- and the add carries the whole request record, so it is two chunks.
	F.tick(15)
	local id = F.with(r, function() return (next(r.G.TOGBankClassic_Guild.Info.requests)) end)
	assert.is_string(id)
	local add = F.sent({ from = REQ, prefix = "togbank-rm" })
	assert.equal(1, #add, "the order put no mutation on togbank-rm")
	for _, x in ipairs({ b, r, c[OTHER] }) do
		local req = requestOn(x, id)
		assert.is_table(req, string.format("%s does not hold the order (the add's mutation: %d bytes, prio %s, leftAt=%s, verdict=%s, reason=%s)",
			x.name, add[1].bytes, tostring(add[1].prio), tostring(add[1].leftAt), tostring(add[1].verdict), tostring(add[1].reason)))
		assert.equal(0, tonumber(req.fulfilled) or 0, x.name)
		assert.equal("open", req.status, x.name)
	end
	return id
end

--- The banker's mail to the requester has just left (MAIL_SEND_SUCCESS): the record OnSendMail
--- kept, credited by Mail:ApplyPendingSend exactly as the event handler does it.
local function mailLeft(b, r, id)
	F.with(b, function()
		local Mail = b.G.TOGBankClassic_Mail
		Mail.pendingSend = {
			sender = b.norm, recipient = r.norm, requestId = id,
			items = { { name = ITEM, quantity = QTY, requestId = id } },
		}
		Mail:ApplyPendingSend()
	end)
	local req = requestOn(b, id)
	assert.equal(QTY, req.fulfilled, "precondition: the banker did not credit its own fill")
	assert.equal("fulfilled", req.status)
end

--- The one ALERT the fill puts on the wire, and nothing of the index sync beside it.
local function theAlert()
	local rm = F.sent({ from = BANK, prefix = "togbank-rm" })
	assert.equal(1, #rm, "the fill did not put exactly one mutation on togbank-rm")
	assert.equal("ALERT", rm[1].prio, "the fill's mutation is not ALERT priority")
	local entry = rm[1].body and rm[1].body.logEntries and rm[1].body.logEntries[1]
	assert.is_table(entry, "the mutation carries no log entry")
	assert.equal("fulfill", entry.type)
	assert.equal(QTY, entry.targetFulfilled)
	assert.equal(0, #F.sent({ from = BANK, prefix = "togbank-ri" }), "an index sync ran; the ALERT is not what moved the row")
	assert.equal(0, #F.sent({ from = BANK, prefix = "togbank-rd2" }), "a by-id sync ran; the ALERT is not what moved the row")
	return rm[1]
end

local function landedOn(c, id)
	local req = requestOn(c, id)
	assert.equal(QTY, tonumber(req.fulfilled) or 0, c.name .. " did not get the fill on the ALERT (Sent stayed " .. tostring(req.fulfilled) .. ")")
	assert.equal("fulfilled", req.status, c.name)
end

describe("FILL-ALERT-001: a banker's fill reaches every guildmate's request row on the ALERT alone", function()
	it("on the ordered wire: the mail leaves, the mutation goes out at ALERT, and both other clients' rows move in the same second", function()
		local c = guild("ordered")
		local b, r, o = c[BANK], c[REQ], c[OTHER]
		local id = place(c)
		mailLeft(b, r, id)
		F.tick(1)
		theAlert()
		landedOn(r, id); landedOn(o, id)
		noErrors(b); noErrors(r); noErrors(o)
	end)

	it("on the throttled wire: through the real AceCommQueue, AceComm and ChatThrottleLib, the row moves within seconds and the send reports delivered", function()
		local c = guild("throttled")
		local b, r, o = c[BANK], c[REQ], c[OTHER]
		local id = place(c)
		mailLeft(b, r, id)
		F.tick(5)
		local m = theAlert()
		assert.is_number(m.leftAt, "AceCommQueue never reported the mutation's last chunk leaving")
		assert.equal(true, m.verdict, "ChatThrottleLib did not report the mutation sent")
		landedOn(r, id); landedOn(o, id)
		noErrors(b); noErrors(r); noErrors(o)
	end)

	it("cuts through the banker's own login burst: entered the world, broadcast, other addons talking -- the fill still lands in seconds", function()
		local c = guild("throttled")
		local b, r, o = c[BANK], c[REQ], c[OTHER]
		local id = place(c)
		-- The banker has just logged in: the five-second hard clamp, its own hlb2 broadcast queued
		-- behind it, and another addon using a third of the channel.
		F.enterWorld(b); F.tick(1)
		F.login(b)
		F.background(b, 250)
		mailLeft(b, r, id)
		F.tick(20)
		F.background(b, 0)
		local m = theAlert()
		assert.is_number(m.leftAt, "the mutation never left under the login burst")
		assert.is_true(m.leftAt - m.sentAt <= 20, "the ALERT took " .. tostring(m.leftAt - m.sentAt) .. " s to leave; BULK is ahead of it")
		landedOn(r, id); landedOn(o, id)
		noErrors(b); noErrors(r); noErrors(o)
	end)
end)
