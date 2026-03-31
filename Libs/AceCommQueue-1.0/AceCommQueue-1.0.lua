--- AceCommQueue-1.0
-- Transparently wraps AceComm-3.0's SendCommMessage on embedded addon objects to
-- serialize sends on a per-(prefix, distribution, target) queue, preventing
-- ChatThrottleLib chunk interleaving that causes CRC errors on receivers.
--
-- Background: AceComm splits large messages into FIRST/NEXT/LAST chunks and submits
-- them all to ChatThrottleLib (CTL) in sequence. If a second message is submitted on
-- the same prefix before CTL drains the first message's chunks, and the two messages
-- use different CTL priorities (e.g. BULK then NORMAL), CTL drains the NORMAL chunks
-- ahead of remaining BULK chunks — corrupting the receiver's spool and causing CRC errors.
---@diagnostic disable: undefined-global
--
-- This library ensures only one message per (prefix, distribution, target) is in-flight
-- in CTL at a time. The next queued message is not submitted until the previous one's
-- final chunk has been confirmed via CTL's callback.
--
-- Priority order within the app-level queue (highest first): ALERT > NORMAL > BULK.
-- Between messages, higher-priority items drain first.
--
-- Usage:
--   1. Embed AceComm-3.0 as normal (and define any SendCommMessage wrappers you need).
--   2. THEN embed AceCommQueue-1.0 LAST so it wraps the complete wrapper chain:
--        local ACQ = LibStub("AceCommQueue-1.0")
--        ACQ:Embed(myAddon)   -- must be called after AceComm:Embed(myAddon)
--   3. Use myAddon:SendCommMessage(...) as normal — queueing is fully transparent.
--
-- Suppression: If your SendCommMessage wrapper suppresses a send (e.g. an in-raid guard),
-- it MUST call callbackFn(callbackArg, 0, 0, nil) to unblock the queue.
-- The condition (0 >= 0) satisfies last-chunk detection and drains the next item.

local MAJOR, MINOR = "AceCommQueue-1.0", 2
local AceCommQueue, oldminor = LibStub:NewLibrary(MAJOR, MINOR)
if not AceCommQueue then return end  -- newer or same version already loaded

-- ALERT drains before NORMAL before BULK, matching CTL's own priority ordering.
local PRIO_ORDER = { "ALERT", "NORMAL", "BULK" }

-- Per-(prefix, dist, target) queue tables. Preserved across LibStub upgrades.
AceCommQueue.queues = AceCommQueue.queues or {}

-- Debug flag. Off by default. Toggle at runtime with AceCommQueue:SetDebug(true).
-- When standalone, read your SavedVariables in ADDON_LOADED and call SetDebug accordingly.
AceCommQueue.debug = AceCommQueue.debug or false

--- Enable or disable debug output at runtime.
-- @param flag  boolean
function AceCommQueue:SetDebug(flag)
	self.debug = flag and true or false
end

local function dbg(...)
	if AceCommQueue.debug then
		print("|cff88aaff[AceCommQueue-1.0]|r", string.format(...))
	end
end

--- Register a slash command to toggle debug mode at runtime.
-- Only call this once — either from an addon's OnInitialize, or from a
-- standalone wrapper's ADDON_LOADED handler.
--
-- Supported commands (replace "/acq" with your chosen cmd):
--   /acq on      — enable debug output
--   /acq off     — disable debug output
--   /acq status  — print current state of all queues
--   /acq         — toggle
--
-- @param cmd  Slash command string, e.g. "/acq" (include the slash)
function AceCommQueue:RegisterSlashCommand(cmd)
	if type(cmd) ~= "string" or cmd:sub(1,1) ~= "/" then
		dbg("RegisterSlashCommand: cmd must be a slash command string, e.g. '/acq' — skipped")
		return
	end

	local name = "ACECOMMQUEUE_" .. cmd:upper():gsub("[^A-Z0-9]", "_")
	_G["SLASH_" .. name .. "1"] = cmd
	SlashCmdList[name] = function(arg)
		arg = arg and arg:lower():match("^%s*(.-)%s*$") or ""
		if arg == "on" then
			AceCommQueue:SetDebug(true)
			print("|cff88aaff[AceCommQueue-1.0]|r Debug ON")
		elseif arg == "off" then
			AceCommQueue:SetDebug(false)
			print("|cff88aaff[AceCommQueue-1.0]|r Debug OFF")
		elseif arg == "status" then
			print("|cff88aaff[AceCommQueue-1.0]|r Queue status:")
			local any = false
			for key, q in pairs(AceCommQueue.queues) do
				any = true
				local displayKey = key:gsub("\031", "|")
				print(string.format("  %s — inFlight=%s A=%d N=%d B=%d",
					displayKey, tostring(q.inFlight), #q.ALERT, #q.NORMAL, #q.BULK))
			end
			if not any then print("  (no queues registered)") end
		else
			AceCommQueue:SetDebug(not AceCommQueue.debug)
			print("|cff88aaff[AceCommQueue-1.0]|r Debug " .. (AceCommQueue.debug and "ON" or "OFF"))
		end
	end
end

-- Normalize the queue key so case variants ("Guild" vs "GUILD") share the same slot.
local function makeKey(prefix, dist, target)
	local d = dist and dist:upper() or ""
	local t = target and target:lower() or ""
	return prefix .. "\031" .. d .. "\031" .. t
end

-- Forward-declare so the closure inside drain can reference it by name.
local drain
drain = function(key)
	local q = AceCommQueue.queues[key]
	if not q or q.inFlight then
		dbg("drain(%s): skipped — %s", key, not q and "no queue" or "in-flight")
		return
	end

	for _, pri in ipairs(PRIO_ORDER) do
		local bucket = q[pri]
		if bucket and #bucket > 0 then
			local item = table.remove(bucket, 1)
			q.inFlight = true
			local userFn  = item.callbackFn
			local userArg = item.callbackArg

			dbg("drain(%s): sending prefix=%s dist=%s prio=%s qlen(A/N/B)=%d/%d/%d",
				key, item.prefix, item.dist or "GUILD", pri,
				#q.ALERT, #q.NORMAL, #q.BULK)

			-- AceComm fires callbackFn(callbackArg, bytesSentSoFar, totalBytes, sendResult)
			-- once per chunk. We detect the final chunk when sent >= total.
			-- Suppression signals (0, 0) satisfy 0 >= 0, unblocking stalled queues.
			local internalCb = function(_, sent, total, sendResult)
				if sent and total and sent >= total then
					dbg("drain(%s): complete sent=%d total=%d suppressed=%s",
						key, sent, total, tostring(sent == 0 and total == 0))
					q.inFlight = false
					if userFn then userFn(userArg, sent, total, sendResult) end
					drain(key)
				end
			end

			-- Call the original SendCommMessage captured at Embed time directly,
			-- bypassing the queued dispatcher to prevent recursive re-queueing.
			-- pcall so a send error resets inFlight instead of stalling the queue.
			local ok, err = pcall(item.originalSend, item.commObj, item.prefix, item.text, item.dist, item.target, pri, internalCb)
			if not ok then
				dbg("drain(%s): send error (prefix=%s prio=%s): %s", key, item.prefix, pri, tostring(err))
				q.inFlight = false
				if userFn then userFn(userArg, 0, 0, nil) end
				drain(key)  -- drain next item rather than stalling forever
			end
			return
		end
	end
	-- All priority buckets empty — queue is idle.
	dbg("drain(%s): idle — all buckets empty", key)
end

--- Embed AceCommQueue into an AceComm-3.0-enabled addon object.
--
-- Wraps the object's existing SendCommMessage with a queued dispatcher.
-- The original SendCommMessage (AceComm's, or any wrapper already on the object)
-- is called internally by the drain — all existing send paths continue to work.
--
-- Must be called AFTER AceComm-3.0 (and any SendCommMessage wrappers) have already
-- been set up, so the queue wraps the complete wrapper chain.
--
-- @param target  The addon table to embed into. Must already have SendCommMessage.
-- @return target (for chaining)
function AceCommQueue:Embed(target)
	if not (target and target.SendCommMessage) then
		dbg("Embed: target must have AceComm-3.0 embedded before AceCommQueue — skipped")
		return
	end
	if target.__AceCommQueue_embedded then
		dbg("Embed: AceCommQueue already embedded in this object — skipped")
		return
	end

	local originalSend = target.SendCommMessage
	local ACQ          = AceCommQueue  -- upvalue; avoids global lookup in hot path

	-- Replace SendCommMessage with the queued dispatcher.
	-- Signature matches AceComm-3.0's SendCommMessage exactly.
	target.SendCommMessage = function(commObj, prefix, text, dist, target_name, prio, callbackFn, callbackArg)
		prio = prio or "NORMAL"

		-- Input validation
		if type(prefix) ~= "string" or prefix == "" then
			dbg("enqueue: dropped — prefix must be a non-empty string, got %s", tostring(prefix))
			return
		end
		if text == nil then
			dbg("enqueue: dropped — text is nil (prefix=%s)", prefix)
			return
		end
		if prio ~= "ALERT" and prio ~= "NORMAL" and prio ~= "BULK" then
			dbg("enqueue: dropped — invalid priority '%s', must be ALERT/NORMAL/BULK (prefix=%s)", tostring(prio), prefix)
			return
		end

		local key = makeKey(prefix, dist, target_name)

		if not ACQ.queues[key] then
			ACQ.queues[key] = {
				inFlight = false,
				ALERT    = {},
				NORMAL   = {},
				BULK     = {},
			}
		end

		local q = ACQ.queues[key]
		dbg("enqueue: prefix=%s dist=%s prio=%s inFlight=%s qlen(A/N/B)=%d/%d/%d",
			prefix, dist or "GUILD", prio, tostring(q.inFlight),
			#q.ALERT, #q.NORMAL, #q.BULK)

		table.insert(q[prio], {
			prefix       = prefix,
			text         = text,
			dist         = dist,
			target       = target_name,
			callbackFn   = callbackFn,
			callbackArg  = callbackArg,
			commObj      = commObj,
			originalSend = originalSend,
		})

		drain(key)
	end

	target.__AceCommQueue_embedded = true
	return target
end
