-- Inventory/Sync.lua -- THE DATA LEG ON THE DeltaSync HOST: the chain, or the snapshot, or "current".
--
-- THE DELTA RELEASE, step 3b (docs/DELTA_RELEASE.md section 3.4). The operator, 2026-09-11: "we need
-- to use the P2P deltasync with deltas, so we aren't transmitting a bunch of 'old' stuff".
--
-- WHAT THIS REPLACES. After a peer ACCEPTED a sync-request, the requester whispered a `togbank-state`
-- summary -- four hashes and the money -- and the provider decided from it whether to answer
-- `togbank-nochange` or a FULL tuple snapshot on `togbank-d4`. Every request that was not a no-change
-- re-sent the whole bank (Guild.lua's SendAltData: "KNOWN COST ... every V2 send is a FULL SNAPSHOT").
-- Both halves are gone: the round-trip is the host's QUERY channel (`host:RequestData`), the reply is
-- the host's RESPONSE channel (`host:SendData`), and the reply is the CHAIN when the provider has it.
--
-- THE THREE ANSWERS a provider gives, decided on the CANON alone (the identity of a version, minted
-- once by the author -- HASH-CANON-001):
--
--   * the requester HOLDS OUR VERSION (or a newer one)  ->  `inv-nochange`     (a few bytes)
--   * our chain CONNECTS from the version they hold     ->  `inv-chain`        (the author's own links
--                                                            after that canon -- a few tuples per
--                                                            changed row, Inventory/Chain.lua)
--   * anything else                                      ->  `inv-snapshot`     (the full tuple set,
--                                                            exactly what togbank-d4 carried)
--
-- "v1 is always red" (the operator): there is no revision-1 language here. A copy with no canon is a
-- copy with no version, and it is answered with the snapshot -- what the requester gets is the
-- author's canon riding with the data, which is how it acquires one.
--
-- THE RECEIVER PROVES THE CHAIN. Chain:ApplyAll applies the links in order and recomputes the content
-- hash against the newest link's canon; a chain that does not reproduce the author's number is refused
-- whole, the alt is marked for a forced-full request, and the session fails into the normal catch-up
-- -- which re-requests with no held canon and gets the snapshot. Nothing is ever applied on trust.
--
-- ONE STORE-AND-STAMP for every delivery. The snapshot path (togbank-d4 and `inv-snapshot`) and the
-- chain path end in the same `StoreDelivery`: write the records, log the diff, stamp the author's
-- hashes and publish time VERBATIM (never recomputed -- HASH-CANON-001), release the P2P session,
-- repaint. Peer Review's standing finding on this addon is "the same behaviour implemented more than
-- once"; the receive side had one implementation inside a 200-line comm handler and this gives it a
-- name so the second caller could not become a second copy.
--
-- THE SEND SLOT (P2P-024/028): the provider took a slot when it ACCEPTED and must give it back when
-- the reply has LEFT -- not when it was queued, or three queued snapshots would count as no load and
-- the cap that spreads a busy guild across holders would admit a fourth. DeltaSync exposes no
-- per-send completion (LIBREQ-DS-009, filed); Core's transport proxy does (`Core:WatchHostSend`), and
-- the release rides it. A no-change releases at once -- there is nothing to wait for.
--
-- WHICH ALT A PAYLOAD IS FOR IS IN THE PAYLOAD. The host's callbacks carry only the sender, so the
-- QUERY baseline names the alt in `keys.alt` and every reply names it in `alt`. `keys` is the
-- library's own baseline field for "what the requester holds"; the alt name is exactly that.
--
-- LIBREQ-DS-008: when the numbered handshake moves into DeltaSync, THIS file is what its data leg
-- calls -- OnDataRequest to answer, OnDataReceived to apply. It is deliberately independent of
-- P2PSession's internals beyond the slot and the completion, so the handshake can be swapped under it.

TOGBankClassic_Inventory_Sync = {}
local Sync = TOGBankClassic_Inventory_Sync

Sync.BASELINE_TYPE = "inv"           -- baseline.type on the QUERY channel
Sync.TYPE_CHAIN    = "inv-chain"     -- reply: the author's links after the held canon
Sync.TYPE_SNAPSHOT = "inv-snapshot"  -- reply: the full tuple payload (Wire.encode)
Sync.TYPE_NOCHANGE = "inv-nochange"  -- reply: you hold my version (or newer)

local function host()
	return TOGBankClassic_Core:DeltaHost()
end

local function Dbg(tag, fmt, ...)
	TOGBankClassic_Output:Debug("DELTA", tag, fmt, ...)
end

local function releaseSlot(requester, reason)
	local P2P = TOGBankClassic_P2PSession
	if P2P and P2P.ReleaseSendSlot then P2P:ReleaseSendSlot(requester, reason) end
end

--- The sender in TOGBank's one spelling. The host hands its callbacks the sender as AceComm gave it
--- -- a BARE name for a same-realm peer (DeltaSync's NormalizeSender only strips realm spaces) --
--- while every P2P record (the send slot, the state-wait, the session) is keyed by the requester's
--- `Name-Realm` from the handshake payload. Chat:OnCommReceived normalises the same way for every
--- TOGBank prefix; missing it here would leak the slot the accept took (P2P-028) and let the
--- state-wait release it a second time 30 seconds later (P2P-024). It also marks the sender online,
--- as Chat does: a peer that just spoke to us is online whatever the roster says yet.
local function normSender(sender)
	local G = TOGBankClassic_Guild
	local norm = G:NormalizeName(sender) or sender
	if G.UpdateOnlineMember then G:UpdateOnlineMember(norm, true, "host-message-received") end
	return norm
end

-- ─── Requester ─────────────────────────────────────────────────────────────────

--- The canon this client can honestly name as its baseline for `norm`: the one on the record, and
--- only while the store holds records for it -- a hash-list stub carries a canon and no contents, and
--- a chain applied over nothing would produce nothing. nil is "I hold no version": send everything.
---@return string|nil canon, number|nil publishedAt
function Sync:HeldCanon(norm)
	local G, Store, DC = TOGBankClassic_Guild, TOGBankClassic_Inventory_Store, TOGBankClassic_DeltaComms
	local guild = G and G.Info and G.Info.name
	local alt = G and G.Info and G.Info.alts and G.Info.alts[norm]
	if not (guild and alt and Store and alt.inventoryHashV2 ~= nil) then return nil end
	if #Store:GetAltRecords(guild, norm) == 0 then return nil end
	local canon = DC:CanonFrom(alt.inventoryHashV2, alt.inventoryUpdatedAt or alt.version)
	if not canon then return nil end
	return canon, DC:CanonPublishTime(canon)
end

--- A peer ACCEPTED our sync-request for `norm`: ask it for the data, naming the canon we hold as the
--- baseline. The provider answers on the host's RESPONSE channel and OnDataReceived applies it.
---
--- `forceFull` (or a standing `Guild.forceFullRequests[norm]`, set when a chain was refused) claims
--- no baseline at all, so the provider cannot answer "you hold my version" to a request that asked
--- for everything.
---
--- ALERT priority, per P2P-031: this is a 100-byte handshake message, and the ALERT lane is the one
--- ChatThrottleLib keeps clear of a busy provider's BULK payloads.
---@return boolean sent false when the host refused the send (offline target, no roster entry)
function Sync:RequestFrom(peer, norm, forceFull)
	local G = TOGBankClassic_Guild
	if type(peer) ~= "string" or type(norm) ~= "string" then return false end
	norm = G:NormalizeName(norm) or norm
	local standing = G.forceFullRequests and G.forceFullRequests[norm]
	if standing then G.forceFullRequests[norm] = nil end
	-- MULTIPC-002: a request for OUR OWN bank is the diff-base fetch (Bank:RequestDiffBase), and it
	-- wants the whole version: the store already holds this PC's fresh re-read, so a chain from the
	-- canon we last published could not be applied to anything we hold.
	if norm == G:GetNormalizedPlayer() then forceFull = true end
	local held, at
	if not (forceFull or standing) then held, at = self:HeldCanon(norm) end
	local ok = host():RequestData(TOGBankClassic_Core:WhisperAddress(peer), {
		type    = self.BASELINE_TYPE,
		hash    = held or 0,
		version = at or 0,
		keys    = { alt = norm },
	}, "ALERT")
	Dbg("WIRE", "[SYNC] asked %s for %s from %s%s", peer, norm,
		held and ("canon " .. held) or "nothing (full)",
		ok and "" or " -- the host REFUSED the send")
	return ok and true or false
end

-- ─── Provider ──────────────────────────────────────────────────────────────────

--- Send one reply and give the send slot back when it has left. A refused send (the host's roster
--- guard: the requester logged off) releases at once -- nothing will ever complete. The slot is
--- keyed by the requester's `Name-Realm`; the send (and the watch on it, which keys on what the
--- transport sees) is addressed by the one address rule, exactly as the handshake was.
local function reply(requester, payload, priority, slotReason, norm, canon)
	local h = host()
	local prefix = h.prefixes and h.prefixes.RESPONSE
	local addr = TOGBankClassic_Core:WhisperAddress(requester)
	-- CHAIN-004: ONE reply per requester per alt in flight. Peer review A1's rule ("one accept is one
	-- reply") is kept by this mark rather than by the accept claim alone, because a QUERY can now be
	-- answered without an accept (OnDataRequest) -- and a requester's two paths (a session accept
	-- and the pull-path ACK, both calling RequestFrom for the same bank) would otherwise earn two
	-- BULK sends of the same snapshot. Cleared when the send has left, or was never taken -- and
	-- stamped, so a transport that never reports (the slot's own 210-second safety release covers
	-- that case) cannot leave the pair refused for the rest of the session: InFlight reads it.
	Sync.inFlight = Sync.inFlight or {}
	local flightKey = requester .. "|" .. tostring(norm)
	Sync.inFlight[flightKey] = GetTime()
	TOGBankClassic_Core:WatchHostSend(prefix, addr, function(delivered)
		Sync.inFlight[flightKey] = nil
		releaseSlot(requester, delivered and slotReason or (slotReason .. "_refused"))
		-- SYNCED-001: a DELIVERED reply carrying `canon` of `norm` left this client whole -- the
		-- transport's verdict, counted as SENT; the requester's own next message is what makes it
		-- SEEN. Only the tracker's own version registers.
		if delivered and norm and canon and TOGBankClassic_Propagation then
			TOGBankClassic_Propagation:NoteHolder(norm, canon, requester, "sent")
		end
	end)
	local ok = h:SendData(addr, payload, false, priority)
	if not ok then
		TOGBankClassic_Core:UnwatchHostSend(prefix, addr)
		Sync.inFlight[flightKey] = nil
		releaseSlot(requester, slotReason .. "_not_sent")
	end
	return ok
end

-- The send slot's own safety release (P2PSession SEND_TIMEOUT); a mark older than this belongs to a
-- send the slot has already given up on.
local IN_FLIGHT_TTL = 210

--- Is a reply to `requester` for `norm` still leaving? A stale mark (see reply) reads as no.
---@return boolean
function Sync:InFlight(requester, norm)
	local at = self.inFlight and self.inFlight[requester .. "|" .. tostring(norm)]
	if not at then return false end
	if GetTime() - at > IN_FLIGHT_TTL then
		self.inFlight[requester .. "|" .. tostring(norm)] = nil
		return false
	end
	return true
end

--- The full tuple payload for `norm`, or nil when this client has nothing to ship. The same
--- Wire.encode array `togbank-d4` carries, so the receive side is one decoder.
---@return table|nil payload, number records
function Sync:SnapshotPayload(norm)
	local G, Store, Wire = TOGBankClassic_Guild, TOGBankClassic_Inventory_Store, TOGBankClassic_Inventory_Wire
	local guild = G.Info and G.Info.name
	local alt = G.Info and G.Info.alts and G.Info.alts[norm]
	if not (guild and alt and Store and Wire) then return nil, 0 end
	local records = Store:GetAltRecords(guild, norm)
	if #records == 0 then return nil, 0 end
	-- LOG-MAIL-001: the author's bank-log entries for the window ride with the snapshot, so a
	-- receiver applies the author's log rather than diffing two full sets (which carry the inbox).
	local Chain = TOGBankClassic_Inventory_Chain
	local logs = Chain and Chain.WireLogs and Chain:WireLogs(guild, norm) or nil
	local payload = Wire.encode(norm, records, alt.money,
		alt.inventoryHash, alt.inventoryHashV2, alt.inventoryUpdatedAt or alt.version, alt.mailHash, logs)
	return payload, #records
end

--- A QUERY arrived on the host: a requester we accepted names the canon it holds for an alt.
--- Returns true when the baseline was ours to answer (false lets another consumer of the host see it).
function Sync:OnDataRequest(sender, baseline)
	if type(baseline) ~= "table" or baseline.type ~= self.BASELINE_TYPE then return false end
	local G, Chain = TOGBankClassic_Guild, TOGBankClassic_Inventory_Chain
	local P2P = TOGBankClassic_P2PSession
	sender = normSender(sender)
	local norm = type(baseline.keys) == "table" and baseline.keys.alt or nil
	if type(norm) == "string" then norm = G:NormalizeName(norm) or norm end
	-- CHAIN-004: a reply for this requester and alt is already leaving -- a second QUERY for it (the
	-- session accept and the pull-path ACK both ask; a retry inside the drain) earns nothing more.
	-- Peer review A1's "one accept is one reply", kept here now that a QUERY can be its own accept.
	if type(norm) == "string" and self:InFlight(sender, norm) then
		Dbg("WIRE", "[SYNC] %s asked for %s again while our reply is still leaving -- ignored", sender, norm)
		-- Peer Review (LOW): if this duplicate arrived WITH an unclaimed accept, consume it now and
		-- give the slot back, rather than leaving that reservation to lapse on the 30s state-wait.
		if P2P and P2P.ClaimSendSlot and P2P:ClaimSendSlot(sender) then
			if P2P.StateSummaryArrived then P2P:StateSummaryArrived(sender, norm) end
			releaseSlot(sender, "duplicate_query")
		end
		return true
	end
	-- CHAIN-003 (peer review F2 / A1), REVISED as CHAIN-004: the send-slot cap is enforced when the
	-- sync-request is ACCEPTED, and the claim is consumed here on the QUERY and given back with the
	-- slot on drain. A QUERY with NO unclaimed accept used to be dropped on the floor. Read off both
	-- of the operator's clients on 2026-09-12: (1) the banker's pull-path ACK (Chat.lua, alt-request)
	-- never took a slot, so every bank only the banker authored was ACKed and then never delivered
	-- -- "Galdof-OldBlanchy sent a QUERY with no unclaimed accept -- ignored", and a Bankers tab
	-- of 'Old format / never' rows; (2) a QUERY that arrived after the 30-second state-wait had released the
	-- accept was dropped the same way, and the requester then sat out the full 180-second delivery
	-- watchdog ("FAILED (delivery_timeout)" x15 in one screen). What the gate is FOR is the cap --
	-- a BULK send outside it, and releases for a slot never taken. So a QUERY with no accept is its
	-- OWN accept when there is room: it takes a slot here and the releases below balance; and when
	-- there is no room it is REFUSED OUT LOUD (sync-busy naming the alt), so the requester's session
	-- advances to its next holder now rather than after the watchdog. Ours either way (true): the
	-- baseline type is TOGBank's alone.
	--
	-- WHY THIS REFUSES WHERE HandleSyncRequest QUEUES (P2P-029, the operator: "buffers all requests
	-- ... so nothing gets dropped"; Peer Review 2026-09-12 raised the contradiction). A DELIBERATE
	-- EXCEPTION, not an oversight: the queue is for a requester that has not been served yet and has
	-- nowhere else to be; this requester WAS accepted, waited the whole 30-second state-wait, and
	-- arrived after its place lapsed -- a second queue position would double a wait it has already
	-- paid, and the QUERY carries no session id to queue under. So it is answered the way every other
	-- "cannot serve you" reply in this handshake is (busy (version), nothing servable): advance to the
	-- next holder, bounded by AdvanceCandidate's retry cycle. Nothing is dropped -- the request lives
	-- on in the session. KNOWN COST: one hop of the P2P-029 shape, once per lapsed accept.
	if P2P and P2P.ClaimSendSlot and not P2P:ClaimSendSlot(sender) then
		if not (P2P.TryAcquireSendSlot and P2P:TryAcquireSendSlot(sender) and P2P:ClaimSendSlot(sender)) then
			Dbg("WIRE", "[SYNC] %s sent a QUERY with no unclaimed accept and we are at capacity -- refused", sender)
			if type(norm) == "string" then
				-- Through the handshake sender (prefix and priority live there, Peer Review c6819531 F2).
				P2P:SendHandshake(sender, { type = "sync-busy", alt = norm, reason = "no_slot" })
			end
			return true
		end
		Dbg("WIRE", "[SYNC] %s sent a QUERY with no unclaimed accept -- room for it, serving", sender)
	end
	if type(norm) ~= "string" then
		Dbg("WIRE", "[SYNC] %s asked for no alt at all -- ignored", tostring(sender))
		releaseSlot(sender, "bad_request")
		return true
	end
	-- The accept armed a short wait for exactly this message (P2P-028); it has arrived.
	if P2P and P2P.StateSummaryArrived then P2P:StateSummaryArrived(sender, norm) end

	if not G:CanServe(norm) then
		Dbg("WIRE", "[SYNC] %s asked for %s but we cannot serve it -- slot released", sender, norm)
		releaseSlot(sender, "no_data")
		return true
	end
	local alt   = G.Info.alts[norm]
	local guild = G.Info.name
	local held  = type(baseline.hash) == "string" and baseline.hash or nil
	local mine  = G:ServableCanon(norm)

	-- They hold our version, or a newer one: nothing we send could improve their copy. A no-change
	-- completes their session (and carries the slot counts, which are display data with no version
	-- identity -- HASH-CANON-002 kept exactly this much of the old message).
	if held and mine and (held == mine or G:CanonIsNewer(held, mine)) then
		Dbg("WIRE", "[SYNC] %s holds %s for %s%s -- no-change", sender, held, norm,
			held == mine and " (ours)" or " (newer than ours)")
		releaseSlot(sender, "no_change")
		-- SYNCED-001: a requester that already holds our version has received it.
		if held == mine and TOGBankClassic_Propagation then TOGBankClassic_Propagation:NoteHolder(norm, mine, sender) end
		host():SendData(TOGBankClassic_Core:WhisperAddress(sender), {
			type      = self.TYPE_NOCHANGE,
			alt       = norm,
			version   = alt.version or 0,
			bankSlots = alt.bank and alt.bank.slots or nil,
			bagsSlots = alt.bags and alt.bags.slots or nil,
		}, false, "ALERT")
		if guild then TOGBankClassic_Database:RecordNoChangeSent(guild) end
		return true
	end

	-- The chain, when it connects from what they hold AND ends at the version we would otherwise
	-- snapshot. A chain that ends earlier describes versions this client's record has since left by
	-- a snapshot, and serving it would leave the requester one version behind with a canon that says
	-- otherwise.
	if held and mine and Chain then
		local links = Chain:Since(guild, norm, held)
		if links and #links > 0 and links[#links].canon == mine then
			local wire = {}
			for i, l in ipairs(links) do wire[i] = { l.parent, l.canon, l.body } end
			local payload = {
				type      = self.TYPE_CHAIN,
				alt       = norm,
				links     = wire,
				hash      = alt.inventoryHash,
				updatedAt = alt.inventoryUpdatedAt or alt.version,
				mailHash  = alt.mailHash,
			}
			Dbg("WIRE", "[SYNC] %s holds %s for %s -- sending %d link(s) to %s", sender, held, norm, #links, mine)
			reply(sender, payload, "NORMAL", "send_complete", norm, mine)
			return true
		end
		Dbg("WIRE", "[SYNC] %s holds %s for %s -- %s; snapshot", sender, held, norm,
			(not links) and "outside our chain window" or
			(#links == 0 and "our chain has nothing after it") or
			("our chain ends at " .. tostring(links[#links].canon) .. ", not " .. tostring(mine)))
	end

	local payload, count = self:SnapshotPayload(norm)
	if not payload then
		-- CanServe said yes and encode said no: the record is there and every row is malformed.
		Dbg("WIRE", "[SYNC] nothing encodable for %s -- slot released", norm)
		releaseSlot(sender, "nothing_to_send")
		return true
	end
	if not TOGBankClassic_Options:IsSyncProgressMuted() then
		TOGBankClassic_Output:Info("Sharing guild bank data for %s (%d rows)...", norm, count)
	end
	Dbg("WIRE", "[SYNC] snapshot of %s (%d row(s), canon=%s) to %s", norm, count, tostring(mine), sender)
	reply(sender, { type = self.TYPE_SNAPSHOT, alt = norm, payload = payload }, "BULK", "send_complete", norm, mine)
	return true
end

-- ─── Receiver ──────────────────────────────────────────────────────────────────

--- Is this delivery for an alt `sender` may speak for, and not for our own character?
--- MULTIPC-001: NEVER OUR OWN CHARACTER -- a delivery is one flat record set, and adopting it beside
--- freshly read bags would count every bag item twice; a rescan here is the only writer.
---@return boolean allowed, string|nil why
local function authorised(sender, norm)
	local G, Chat = TOGBankClassic_Guild, TOGBankClassic_Chat
	if norm == G:GetNormalizedPlayer() then return false, "our own character" end
	local allowed = Chat:IsAltDataAllowed(sender, norm)
	if G:ConsumePendingSync("alt", sender, norm) then allowed = true end
	if not allowed then return false, "not allowed" end
	return true
end

--- THE ONE STORE-AND-STAMP. Every delivery -- snapshot or chain -- ends here.
---
--- `meta` is the AUTHOR'S statement about this version, stored VERBATIM (HASH-CANON-001): `hash`
--- (revision 1), `hashV2` (the canon), `updatedAt` (publish time), `mailHash`, and `dropped` (rows a
--- lossy decode discarded -- a copy that lost rows is NOT the author's version and claims no canon).
--- Nothing here recomputes a hash; a receiver's opinion of the author's data is exactly the thing
--- DeltaSync's canonical-hash rules forbid.
---@param sender string who delivered it
---@param norm string the alt
---@param records table the V2 records now held
---@param money number
---@param meta table { hash=, hashV2=, updatedAt=, mailHash=, dropped= }
---@param len number|nil bytes received, for the inbound metric
function Sync:StoreDelivery(sender, norm, records, money, meta, len)
	local G, Store = TOGBankClassic_Guild, TOGBankClassic_Inventory_Store
	local guild = G.Info and G.Info.name
	if not (guild and Store) then return false end
	meta = meta or {}

	-- LOGAPI-001: the version held BEFORE this delivery, for the bank-log diff. Only an alt we
	-- already held is diffed -- a first delivery is not a deposit of everything.
	local logBefore, logCanonBefore
	if Store:HasAlt(guild, norm) then
		logBefore = Store:GetAltRecords(guild, norm)
		local held = G.Info.alts and G.Info.alts[norm]
		logCanonBefore = held and held.inventoryHashV2 or nil
	end

	Store:SetAltRecords(guild, norm, records, money)

	-- LOG-MAIL-001: A RECEIVER NEVER DERIVES A LOG ENTRY. The author's entries -- computed over
	-- what the banker HOLDS, so an attachment sitting in the inbox is nobody's deposit -- arrive in
	-- the chain (per link, `meta.logged`: ReceiveChain records them) or in the snapshot's log window
	-- (`meta.logs`, Wire field 9): every link published after the version held is appended, stamped
	-- with its own time. A delivery that lost rows is not logged; nor is a first delivery (nothing
	-- was held); nor is a snapshot with no log window (an author whose chain is empty, or a payload
	-- built before the field existed) -- coarser than a diff, but never a deposit that did not happen.
	-- This used to diff held -> delivered here, which logged a mail arrival as a deposit on every
	-- viewer (the operator's screenshot, 2026-09-13).
	if TOGBankClassic_Log and logBefore and (meta.dropped or 0) == 0 and not meta.logged and meta.logs then
		local DC = TOGBankClassic_DeltaComms
		local heldAt = logCanonBefore and DC:CanonPublishTime(logCanonBefore) or nil
		TOGBankClassic_Log:ApplyWireLogs(norm, meta.logs, heldAt)
	end

	-- STAMP THE SYNC METADATA. The negotiation layer compares `inventoryHashV2` and the publish time
	-- to decide whether it is stale; storing tuples without stamping these leaves this client
	-- believing it never got the data -- it re-requests on every broadcast and never offers the alt on.
	local alts = G.Info.alts
	if alts then
		local alt = alts[norm]
		if not alt then
			-- No `items = {}` (INV2-RETIRE-003 / INV2-COMPAT-001): a raw empty array would persist as
			-- a legacy row set and shadow the store-backed `items` the record answers through its
			-- metatable.
			alt = { name = norm, money = 0 }
			alts[norm] = alt
		end
		alt.money = money or alt.money or 0
		if (meta.dropped or 0) > 0 then
			alt.inventoryHash   = nil
			alt.inventoryHashV2 = nil
			TOGBankClassic_Output:Warn(
				"Discarded %d malformed item row(s) in a bank update from %s for %s. " ..
				"That data will be re-requested.", meta.dropped, tostring(sender), tostring(norm))
		else
			-- Both revisions together, or neither (HASH-REV-001), and the author's mail hash
			-- (HASH-CANON-004) -- `or alt.mailHash` so an author that has not scanned mail since
			-- upgrading does not blank a value we already had.
			alt.inventoryHash   = meta.hash
			alt.inventoryHashV2 = meta.hashV2
			alt.mailHash        = meta.mailHash or alt.mailHash
		end
		-- THE AUTHOR'S PUBLISH TIME, not our arrival time: every receiver re-advertises what it
		-- holds, so a receive-time stamp made a relayed copy claim to be newer than the author's own.
		-- Our clock only when the author published none -- the same case the ordering guard lets in.
		alt.inventoryUpdatedAt = meta.updatedAt or GetServerTime()
		alt.version            = alt.inventoryUpdatedAt
	end

	Dbg("APPLY", "[INV2] stored %d tuple(s) for %s from %s (canon=%s)", #records, norm, sender,
		tostring(meta.hashV2))
	-- TABCOLOUR-003: the offer that turned the tab red has been answered by a delivery.
	if G.ClearNewerOffered then G:ClearNewerOffered(norm) end

	-- INV2-SESSION-001: CLOSE THE SYNC OFF -- the inbound metric, the ACK fallback timer, the session.
	local isFromBanker = G:IsBank(sender) or false
	TOGBankClassic_Database:RecordDeltaReceived(guild, len or 0, isFromBanker)
	local fallbacks = G.pendingP2PFallbackTimeouts
	if fallbacks and fallbacks[norm] then
		fallbacks[norm]:Cancel()
		fallbacks[norm] = nil
		TOGBankClassic_Output:Debug("P2P", "COMPLETE", "Cancelled fallback timeout for %s (tuples received)", norm)
	end
	if TOGBankClassic_P2PSession then TOGBankClassic_P2PSession:OnAltCompleted(norm, sender) end

	-- SYNCED-001 (peer review B1): THE RECEIPT. A drained reply only proves the data left the
	-- provider; nothing on the wire said "I hold it now" until the receiver's next broadcast, which
	-- may be its next login. So a delivery that was applied and stamped with a canon tells its
	-- sender so -- ~60 bytes on the handshake prefix at ALERT, the one message the provider's
	-- "has my update reached anyone" line can turn green on. A lossy delivery sends none: it was not
	-- the author's version.
	-- Through P2P:SendHandshake (the prefix and the priority live there, Peer Review c6819531 F2);
	-- a spec's Core stand-in may carry the envelope alone, hence the guard on its SendWhisper.
	local P2P = TOGBankClassic_P2PSession
	if (meta.dropped or 0) == 0 and type(meta.hashV2) == "string" and sender ~= G:GetNormalizedPlayer()
			and P2P and P2P.SendHandshake and TOGBankClassic_Core.SendWhisper then
		P2P:SendHandshake(G:NormalizeName(sender) or sender, { type = "sync-done", alt = norm, canon = meta.hashV2 })
	end

	-- TABCOLOUR-001: the data has landed, so this is the moment a red tab turns back. Not routed
	-- through OnAltCompleted, which returns early for a delivery no session asked for (a banker's
	-- own broadcast) -- a delivery all the same.
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.RefreshSoon then
		TOGBankClassic_UI_Inventory:RefreshSoon()
	end
	return true
end

--- A full tuple payload (the Wire.encode array), from `togbank-d4` or from an `inv-snapshot` reply.
--- Decodes, authorises, orders (HASH-CANON-001 rule 7, Chat:ShouldApplyTuplePayload), stores.
---@return boolean applied
function Sync:ReceiveSnapshot(data, sender, len)
	local Wire, G, Chat, Chain = TOGBankClassic_Inventory_Wire, TOGBankClassic_Guild, TOGBankClassic_Chat, TOGBankClassic_Inventory_Chain
	if not (Wire and Wire.isV2(data)) then return false end
	local altName, records, money, _, hash, hashV2, dropped, updatedAt, mailHash, logs = Wire.decode(data)
	local norm = altName and G:NormalizeName(altName)
	if not norm then return false end
	-- MULTIPC-002: OUR OWN character, while Bank is waiting for the newer version another PC
	-- published, is the ONE delivery for our own name that is taken -- and it is never stored. It
	-- goes to Bank as the diff base (docs/DELTA_RELEASE.md section 3.5); the session that asked for
	-- it completes like any other. A lossy decode is not the author's version and is not taken.
	local Bank = TOGBankClassic_Bank
	if norm == G:GetNormalizedPlayer() and Bank and Bank.awaitingDiffBase and Chat:IsAltDataAllowed(sender, norm) then
		local P2P = TOGBankClassic_P2PSession
		local taken, why = false, nil
		if (dropped or 0) == 0 then taken, why = Bank:ReceiveDiffBase(records, money, hashV2) end
		if taken then
			G:ConsumePendingSync("alt", sender, norm)
			if P2P then P2P:OnAltCompleted(norm, sender) end
			return true
		end
		Dbg("VALIDATE", "[MULTIPC-002] a delivery for our own character from %s was not taken as the diff base (canon %s, %d dropped)",
			tostring(sender), tostring(hashV2), dropped or 0)
		-- MULTIPC-004 follow-up: the holder we asked delivered what it had, and it is not the version
		-- we want any more -- that session is DONE (the sender did its part; the slot comes back, no
		-- catch-up broadcast), and only then can the re-ask reach the holder of the newer version:
		-- RequestDiffBase refuses to ask while a session for our own name is live.
		if why == "moved" then
			G:ConsumePendingSync("alt", sender, norm)
			if P2P then P2P:OnAltCompleted(norm, sender) end
			Bank:RequestDiffBase()
		end
		return false
	end
	local ok, why = authorised(sender, norm)
	if not ok then
		Dbg("VALIDATE", "[INV2] rejected tuple payload for %s from %s (%s)", norm, tostring(sender), why)
		return false
	end
	if not Chat:ShouldApplyTuplePayload(norm, updatedAt, hashV2) then
		Dbg("APPLY", "[INV2] discarded a STALE tuple payload for %s from %s (authored %s)",
			norm, tostring(sender), tostring(updatedAt))
		return false
	end
	local guild = G.Info and G.Info.name
	local stored = self:StoreDelivery(sender, norm, records, money,
		{ hash = hash, hashV2 = hashV2, updatedAt = updatedAt, mailHash = mailHash, dropped = dropped, logs = logs }, len)
	-- A snapshot is a jump: any chain this client held for the alt ends at a version the record has
	-- now left, unless it happens to end exactly here. Links that do not connect are not served.
	if stored and guild and Chain and Chain:Newest(guild, norm) ~= nil and Chain:Newest(guild, norm) ~= hashV2 then
		Chain:Clear(guild, norm)
	end
	return stored
end

--- The chain reply: the author's links after the canon we named. Applied on a copy, PROVEN against
--- the newest canon (Chain:ApplyAll), then stored through the same path as a snapshot -- and the
--- links are kept, so this client can serve them on.
---
--- A chain that does not connect from what we hold, or does not reproduce the author's canon, is
--- refused whole: the alt is marked for a forced-full request and the session fails into catch-up,
--- which asks again with no baseline and gets the snapshot. Nothing is applied on trust.
---@return boolean applied
function Sync:ReceiveChain(sender, data, len)
	local G, Store, Chain, Chat = TOGBankClassic_Guild, TOGBankClassic_Inventory_Store, TOGBankClassic_Inventory_Chain, TOGBankClassic_Chat
	local P2P = TOGBankClassic_P2PSession
	local norm = type(data.alt) == "string" and G:NormalizeName(data.alt) or nil
	if not norm then return false end
	local ok, why = authorised(sender, norm)
	if not ok then
		Dbg("VALIDATE", "[CHAIN] rejected a chain for %s from %s (%s)", norm, tostring(sender), why)
		return false
	end

	local function refuse(reason)
		Dbg("CHAIN", "[CHAIN] refused %s's chain for %s: %s -- asking for the snapshot", tostring(sender), norm, reason)
		G.forceFullRequests = G.forceFullRequests or {}
		G.forceFullRequests[norm] = true
		local sid = P2P and P2P.sessionsByAlt and P2P.sessionsByAlt[norm]
		if sid and P2P.OnFailed then P2P:OnFailed(sid, "chain_refused") end
		return false
	end

	-- Shape: an array of { parent, canon, body } strings.
	local links = {}
	if type(data.links) ~= "table" or #data.links == 0 then return refuse("no links") end
	for i, w in ipairs(data.links) do
		if type(w) ~= "table" or type(w[1]) ~= "string" or type(w[2]) ~= "string" or type(w[3]) ~= "string" then
			return refuse("link " .. i .. " is malformed")
		end
		links[i] = { parent = w[1], canon = w[2], body = w[3] }
	end
	local newest = links[#links].canon

	-- It must connect from what WE hold -- the canon we named in the request.
	local heldCanon = self:HeldCanon(norm)
	if not heldCanon then return refuse("we hold no version to apply it to") end
	if links[1].parent ~= heldCanon then
		return refuse(string.format("it starts from %s but we hold %s", links[1].parent, heldCanon))
	end
	-- Ordering, the same rule a snapshot obeys (HASH-CANON-001 rule 7).
	if not Chat:ShouldApplyTuplePayload(norm, data.updatedAt, newest) then
		Dbg("APPLY", "[CHAIN] discarded a STALE chain for %s from %s (ends at %s)", norm, tostring(sender), newest)
		return false
	end

	local guild = G.Info.name
	local records, money, canon, err, steps = Chain:ApplyAll(
		Store:GetAltRecords(guild, norm), Store:GetAltMoney(guild, norm), links)
	if not records then return refuse(tostring(err)) end

	local stored = self:StoreDelivery(sender, norm, records, money,
		{ hash = data.hash, hashV2 = canon, updatedAt = data.updatedAt, mailHash = data.mailHash, dropped = 0, logged = true }, len)
	if stored then
		-- THE DELTA RELEASE step 4 / LOG-MAIL-001: ONE LOG ENTRY PER VERSION, THE AUTHOR'S OWN. Each
		-- link carries the entries the author computed over what the banker HOLDS (`delta.log`), and
		-- they are appended verbatim, stamped with THAT link's canon time -- so this client's log is
		-- the author's row for row, a viewer never derives a version it did not see, and an attachment
		-- sitting in the banker's inbox is nobody's deposit. A link with no log (a version whose
		-- transition moved nothing the banker holds, or a link written before the field existed) logs
		-- nothing: a receiver does not fall back to diffing the full sets, which carry the inbox rows.
		local Log, DC = TOGBankClassic_Log, TOGBankClassic_DeltaComms
		if Log and steps then
			for _, s in ipairs(steps) do
				local packed = s.delta and s.delta.log or nil
				if packed then
					Log:RecordEntries(norm, Log:UnpackEntries(packed, norm),
						DC:CanonPublishTime(s.link.canon) or data.updatedAt, s.link.parent, s.link.canon)
				end
			end
		end
		local held = Chain:Append(guild, norm, links)
		Dbg("CHAIN", "[CHAIN] applied %d link(s) for %s from %s -> %s (chain holds %d)", #links, norm, tostring(sender), canon, held)
	end
	return stored
end

--- A RESPONSE arrived on the host. Returns true when it was one of ours.
function Sync:OnDataReceived(sender, data, len)
	if type(data) ~= "table" then return false end
	if data.type ~= self.TYPE_NOCHANGE and data.type ~= self.TYPE_SNAPSHOT and data.type ~= self.TYPE_CHAIN then
		return false
	end
	sender = normSender(sender)
	if data.type == self.TYPE_NOCHANGE then
		TOGBankClassic_Chat:HandleNoChange({
			name = data.alt, version = data.version, bankSlots = data.bankSlots, bagsSlots = data.bagsSlots,
		}, sender)
		return true
	end
	if data.type == self.TYPE_SNAPSHOT then
		self:ReceiveSnapshot(data.payload, sender, len)
		return true
	end
	self:ReceiveChain(sender, data, len)
	return true
end
