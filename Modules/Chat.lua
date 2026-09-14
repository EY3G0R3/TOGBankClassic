TOGBankClassic_Chat = {}

-- NS-001: aliased as file-scope locals so a foreign global of the same name cannot be read
-- instead. See the header of Modules/Constants.lua.
local ADOPTION_STATUS          = TOGBankClassic_Constants.ADOPTION_STATUS
local COMM_PREFIX_DESCRIPTIONS = TOGBankClassic_Constants.COMM_PREFIX_DESCRIPTIONS
local DEBUG_CATEGORY           = TOGBankClassic_Constants.DEBUG_CATEGORY
local DEBUG_TAGS               = TOGBankClassic_Constants.DEBUG_TAGS
local FEATURES                 = TOGBankClassic_Constants.FEATURES
local LOG_LEVEL                = TOGBankClassic_Constants.LOG_LEVEL
local PEER_TO_PEER             = TOGBankClassic_Constants.PEER_TO_PEER
local PROTOCOL                 = TOGBankClassic_Constants.PROTOCOL
local TIMER_INTERVALS          = TOGBankClassic_Constants.TIMER_INTERVALS

-- Store pre-debug log level for restoration
local preDebugLogLevel = nil

--[[
Comms system breakdown as of 2026-04-01:

  Active Protocol Messages

  ┌──────────────────┬────────────────┬─────────────┬───────────────────────────────────────────────────────────────────────────────────┐
  │      Prefix      │    Channel     │  Priority   │                                      Purpose                                      │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-d4       │ GUILD or       │ BULK        │ Delta inventory data (no item links, bandwidth-optimized) — current standard      │
  │                  │ WHISPER        │             │                                                                                   │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-hl       │ GUILD or       │ NORMAL/BULK │ Multi-purpose: hash-list-broadcast (banker→GUILD, BULK), share-request,          │
  │                  │ WHISPER        │             │ wipe-command, hash-offer (peer→banker WHISPER), hash-list-request (WHISPER)      │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-hlr      │ WHISPER        │ ALERT       │ Hash list reply — peer responds to banker's broadcast with their matching alts    │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-r        │ GUILD or       │ NORMAL/BULK │ Universal query — requests alt data, requests-index, or requests-by-id            │
  │                  │ WHISPER        │             │                                                                                   │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-rr       │ WHISPER        │ ALERT       │ P2P handshake control, every message through P2P:SendHandshake: sync-request /   │
  │                  │                │             │ sync-accept / sync-queued / sync-cancel / sync-busy / sync-done / ver-query /     │
  │                  │                │             │ ver-reply, and the alt-request-reply ACKs. busy = "I do not have it" (reasons:    │
  │                  │                │             │ version, addon_version); a sync-request at capacity is QUEUED, never refused --   │
  │                  │                │             │ ONE exception, CHAIN-004: a data QUERY whose accept lapsed gets busy (no_slot) at │
  │                  │                │             │ capacity, since it was accepted once already and carries no session id to queue  │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togban-q         │ WHISPER        │ ALERT       │ DeltaSync host QUERY: after sync-accept the requester names the alt and the canon │
  │ (host)           │                │             │ it holds (Inventory/Sync.lua RequestFrom). Replaced togbank-state in v1.5.0.      │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togban-r         │ WHISPER        │ NORMAL/BULK │ DeltaSync host RESPONSE: inv-chain (the author's links after the held canon,      │
  │ (host)           │                │ /ALERT      │ NORMAL), inv-snapshot (full tuples, BULK), inv-nochange (ALERT)                   │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-ri       │ GUILD or       │ NORMAL      │ Request index (compact positional v1): chunked list of request IDs sent to       │
  │                  │ WHISPER        │             │ queriers; supersedes togbank-rd for index delivery                                │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-rd2      │ GUILD or       │ NORMAL      │ Request records (compact positional v1): one message per record or tombstone;    │
  │                  │ WHISPER        │             │ supersedes togbank-rd for record delivery                                         │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-rd       │ GUILD or       │ NORMAL      │ LEGACY receive-only: key-value request index / records / mutations from pre-v0.9 │
  │                  │ WHISPER        │             │ clients; never sent by current code; registered for backward compatibility only   │
  ├──────────────────┼────────────────┼─────────────┼───────────────────────────────────────────────────────────────────────────────────┤
  │ togbank-rm       │ GUILD          │ ALERT       │ Request log mutations (add/cancel/complete) — ALERT priority so it isn't blocked  │
  │                  │                │             │ by BULK sends                                                                     │
  └──────────────────┴────────────────┴─────────────┴───────────────────────────────────────────────────────────────────────────────────┘

  Never Sent (receive-only for backward compat): togbank-rd
  Never Sent, never READ (receive-only tripwire, WIRE-SKEW-007): togbank-state -- a pre-v1.5.0
  requester whispers it after our accept; hearing it names that peer as the old wire and frees its
  slot at once. The message body is not deserialized.

  Retired in v1.5.0 (THE DELTA RELEASE step 3b) as a data leg, send AND receive: togbank-state (the
  requester's state summary) and togbank-nochange. The data leg after a sync-accept is the
  DeltaSync host's QUERY/RESPONSE pair above; a v1.4.1 peer that still whispers a state summary is
  not answered and its session times out into catch-up -- the same no-wire-back-compat rule
  v1.4.0 set for tuples.
  The host's other five prefixes (togban-v/-d/-x/-o/-h) are registered by the library and carry
  nothing from TOGBank yet.


 WHY THE CHANNELS ARE SPLIT THE WAY THEY ARE. Read this before "optimising" any send.

 The GUILD channel was the scarce resource -- it was HUGELY congested, and that is the problem
 this whole layer was built to solve. The operator's own words, 2026-09-10: "P2P was my answer to
 try to reduce the congestion on guild", and "there is a broadcast, and then the RESPONSE to the
 broadcast are in Whispers".

 So the split is one idea applied consistently:

   * GUILD carries ONLY the one-to-many hash-list broadcast, which genuinely serves every
     listener with a single message.
   * WHISPER carries everything addressed to a specific peer -- the replies to that broadcast,
     the entire P2P handshake, AND the bulk `togbank-d4` payload.

 THE P2P SESSION MACHINERY IS NOT AN OPTIMISATION BOLTED ON TOP OF A BROADCAST DESIGN. It IS the
 congestion fix. `togbank-d4` going to a WHISPER whenever a peer asked (Guild.lua:2825-2830) is
 therefore correct and deliberate, not drift.

 THE TRAP, which has now caught a reader three times in one session: a COMMS log makes the fix
 look like the disease. One `togbank-hl` to GUILD is followed by ten "Received: togbank-hl via
 WHISPER from <peer>" lines, and that reads as an amplifier. It is the opposite -- those ten
 whispers are ten messages NOT sent on the congested channel. A change that moves traffic from
 WHISPER back onto GUILD is not a win even when it lowers the TOTAL message count, because it
 spends the exact resource this design protects. MEASURE GUILD-CHANNEL BYTES, NEVER THE TOTAL.

 (One consequence, accepted with eyes open: after a banker scans, every peer goes stale at once,
 so the same snapshot is whispered once per requester rather than broadcast once. The operator
 reviewed exactly this cost and kept it -- "that's better, i'm glad that is what it is".)


 A typical sync looks like this:

  1. Banker scans bank → broadcasts togbank-hl (hash-list-broadcast) to guild
  2. Peer receives hashes, compares to local — if stale, initiates P2P session via togbank-rr handshake
  3. On sync-accept the peer asks on the host QUERY channel (togban-q), naming the canon it holds
  4. The holder answers on the host RESPONSE channel (togban-r), deciding on the canon alone:
    - They hold our version (or newer) → inv-nochange
    - Our delta chain connects from their canon → inv-chain (a few tuples per changed row)
    - Otherwise → inv-snapshot (the full tuple set)
  5. Separately, togbank-r (requests-index query) → togbank-rd (chunked index response) → togbank-r (requests-by-id) → togbank-rd (request
  data)
  6. New/changed requests propagate immediately via togbank-rm (ALERT priority)

]]

--- Every comm prefix this addon RECEIVES on. One list, iterated to register and again to verify.
---
--- Deliberately a local list rather than derived from `COMM_PREFIX_DESCRIPTIONS`: that is a bare
--- global, and NS-001 is a confirmed live case of another addon clobbering one of ours. Deriving
--- registration from a table a third party can overwrite would mean silently receiving nothing.
--- `chatcommand_spec` asserts this list and that table hold the same set, so the two cannot drift.
---
--- SYNC-010: `togbank-rm` is a dedicated prefix for request mutations (add/cancel/complete) so it
--- gets its own throttle bucket -- BULK snapshot syncs must not block ALERT mutations.
TOGBankClassic_Chat.COMM_PREFIXES = {
	"togbank-hl",
	"togbank-hlr",
	"togbank-d4",
	"togbank-rm",
	"togbank-rd",
	"togbank-r",
	"togbank-rr",
	"togbank-ri",
	"togbank-rd2",
	-- WIRE-SKEW-007: RECEIVE-ONLY TRIPWIRE. Never sent, never read -- the sender is the whole
	-- message. A v1.4.1 requester whispers its state summary on this prefix straight after our
	-- accept; a v1.5.0 one asks on the host's QUERY channel and never sends it. Hearing it names an
	-- old-wire peer before VersionCheck or its broadcast can, and frees its slot at once instead of
	-- at the end of the 30-second wait. Removing this line restores three burned slots per login.
	"togbank-state",
}

--- Documented values of `Enum.RegisterAddonMessagePrefixResult`, used only if the client does not
--- expose the enum. Blizzard's generated docs for the classic_era tree give these in
--- `ChatConstantsDocumentation.lua`.
local PREFIX_RESULT_FALLBACK = { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2, MaxPrefixes = 3 }

--- LIBREQ-ALL-005. Report a comm prefix the client refused to register.
---
--- AceComm registers each prefix on our behalf inside `RegisterComm` and throws the result away, so
--- re-registering here is the only way to read the verdict. That is not a side effect: the client's
--- prefix set is already what it is, and `DuplicatePrefix` is the expected answer.
---
--- THE RETURN IS AN ENUM -- never a boolean, never nil (`ChatInfoDocumentation.lua` declares the
--- result `Nilable = false`). So `if not C_ChatInfo.RegisterAddonMessagePrefix(p)` can NEVER fire,
--- because `Success` is `0` and `0` is truthy in Lua, and `result == false` never matches because no
--- boolean is ever returned. Both read as guards and are dead code. This names the values instead.
---
--- `DuplicatePrefix` IS NOT A FAILURE and must never be loud: AceComm always registers first, so we
--- get it for every prefix on every login, forever. Warning on it would cry wolf eleven times a
--- session and be trained out -- which is how a real refusal would then go unnoticed. Only
--- `InvalidPrefix` (our own constant is malformed) and `MaxPrefixes` (a client-wide cap a player
--- running many addons can genuinely hit) mean anything.
function TOGBankClassic_Chat:VerifyCommPrefixes()
	local register = C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix
	if type(register) ~= "function" then
		TOGBankClassic_Output:Debug("PROTOCOL", "PREFIX",
			"C_ChatInfo.RegisterAddonMessagePrefix is unavailable - prefix registration cannot be verified")
		return
	end

	local RESULT = (Enum and Enum.RegisterAddonMessagePrefixResult) or PREFIX_RESULT_FALLBACK
	local invalid, capped = {}, {}

	for _, prefix in ipairs(self.COMM_PREFIXES) do
		local result = register(prefix)
		if result == RESULT.InvalidPrefix then
			invalid[#invalid + 1] = prefix
		elseif result == RESULT.MaxPrefixes then
			capped[#capped + 1] = prefix
		end
	end

	-- MaxPrefixes first: it is the one a player can act on, and the one that silently breaks sync.
	if #capped > 0 then
		TOGBankClassic_Output:Error(
			"This client has hit its limit on addon message prefixes, so TOGBank cannot receive: %s. " ..
			"Guild bank data will not sync until you disable another addon and reload.",
			table.concat(capped, ", "))
	end
	if #invalid > 0 then
		TOGBankClassic_Output:Error(
			"TOGBank tried to register a malformed comm prefix and the client refused it: %s. " ..
			"This is an addon bug - please report it.",
			table.concat(invalid, ", "))
	end
	if #capped == 0 and #invalid == 0 then
		TOGBankClassic_Output:Debug("PROTOCOL", "PREFIX", "All %d comm prefixes registered", #self.COMM_PREFIXES)
	end
end

--- HASH-CANON-001 rule 7: ORDERING, DECIDED IN ONE PLACE. Should an arriving tuple payload for
--- `altName`, authored at `wireUpdatedAt`, replace what we already hold?
---
--- THIS GUARD DID NOT EXIST AND ITS ABSENCE IS A DATA-LOSS BUG, reported from a live guild: a V2
--- record replaced by older data. The legacy receive path always had the equivalent check -- it
--- refused a record that was not newer, inside `Guild:ReceiveAltData`, which was DELETED in the same
--- session that added this guard (commit 9c42109). Cited by behaviour and commit rather than by line
--- number on purpose: the numbers this comment used to give (`Guild.lua:3327`, `:3362`) now point
--- 130-odd lines PAST THE END of that file, so a reader chasing the prior art lands on nothing and
--- reasonably concludes the claim was invented. The tuple path, meanwhile, applied EVERY payload
--- unconditionally. With several peers relaying the same alt, whichever snapshot
--- arrived LAST won regardless of when it was authored, so a peer holding a days-old copy could
--- overwrite a fresh one and nothing anywhere said so.
---
--- It could not have been written before the wire carried the author's time, which is why the two
--- ship together: the receiver used to stamp its own arrival time, so there was no honest number to
--- compare -- every record looked like it had been published the instant we heard about it.
---
--- A NIL time IS ACCEPTED, deliberately. It means the author published no time: a client between
--- builds, or a record predating the field. Refusing those would freeze that alt permanently
--- rather than merely leaving it unordered, and unordered is what we already had.
---
--- HASH-CANON-005: THE TIME IS READ OFF THE CANON when the payload carries one, and only falls back
--- to the sidecar `wireUpdatedAt` when it does not. Every other "which is newer" question in the
--- addon (the tab colour, the newest-mentioned time, the offer decision) reads the canon's first ten
--- digits; this guard was the one still on the sidecar, so a sender whose two numbers disagreed
--- would have been ORDERED by one and DISPLAYED by the other. Both sides are read the same way.
--- @param altName string normalized alt name
--- @param wireUpdatedAt number|nil the AUTHOR'S publish time, from the payload's sidecar field
--- @param wireHashV2 string|nil the AUTHOR'S canon from the payload; its time wins when present
--- @return boolean
function TOGBankClassic_Chat:ShouldApplyTuplePayload(altName, wireUpdatedAt, wireHashV2)
	local DC = TOGBankClassic_DeltaComms
	local theirs = (DC and DC:CanonPublishTime(wireHashV2)) or wireUpdatedAt
	if not theirs then return true end
	local info = TOGBankClassic_Guild and TOGBankClassic_Guild.Info
	local existing = info and info.alts and info.alts[altName]
	if not existing then return true end
	-- A STUB is not worth protecting. The hash-list reply seeds a record carrying the banker's
	-- canon and NO contents so there is something to sync into; refusing an older-but-real
	-- delivery to defend that empty record leaves the alt with nothing at all. Ordering guards
	-- content we hold, and a stub holds none.
	if not TOGBankClassic_Guild:HasAltContent(existing, altName) then return true end
	local held = (DC and DC:CanonPublishTime(existing.inventoryHashV2))
		or existing.inventoryUpdatedAt or existing.version
	if not held then return true end
	-- `>=` rather than `>`: a re-send of the version we already hold is harmless and re-applying it
	-- costs nothing, while treating equal as stale would drop a legitimate retry after a lost chunk.
	return theirs >= held
end

local SHARES_COLOR = "|cff80bfffshares|r"
local QUERIES_COLOR = "|cffffff00queries|r"

local function ColorPlayerName(name)
	if not name or name == "" then
		return ""
	end
	local normalized = name
	if TOGBankClassic_Guild and TOGBankClassic_Guild.NormalizeName then
		normalized = TOGBankClassic_Guild:NormalizeName(name) or name
	end
	if TOGBankClassic_Guild and TOGBankClassic_Guild.GetPlayerInfo then
		local class = TOGBankClassic_Guild:GetPlayerInfo(normalized)
		if class then
			local _, _, _, color = GetClassColor(class)
			if color then
				return string.format("|c%s%s|r", color, name)
			end
		end
	end
	return string.format("|cff80bfff%s|r", name)
end

--- A provider answered "you already hold my version" (`inv-nochange` on the DeltaSync host --
--- Inventory/Sync.lua). Completes the P2P session for the alt and applies the slot counts it
--- carries; nothing else. `data` is { name=, version=, bankSlots=, bagsSlots= }.
---
--- HASH-CANON-002: THE "HASH-CORRECTION" BLOCK THAT USED TO LIVE IN THIS HANDLER IS DELETED. It
--- read `hash` / `hashV2` / `mailHash` off the no-change and wrote them over this client's stored
--- canon. IT ADOPTED FROM ANY SENDER, NOT FROM THE AUTHOR: any peer holding a copy answers a
--- request, carrying whatever number IT holds, so a hash minted by a non-author travelled the guild
--- and overwrote good records -- the operator's report exactly. A hash is written ONCE, by the
--- client that scanned the bank, and every other client carries it unchanged. The message itself
--- is kept because completing the session is its real job.
---
--- The SLOT COUNTS are kept for the opposite reason: display data with no bearing on version
--- identity, so a peer passing one along cannot make two clients disagree about which version they
--- hold. (Slots are not part of the item hash, so they never make a version by themselves; the
--- provider piggybacks them here so non-bankers still see accurate free/total counts.)
function TOGBankClassic_Chat:HandleNoChange(data, sender)
	local G = TOGBankClassic_Guild
	local altName = data and data.name
	if type(altName) ~= "string" then return end
	local norm = G:NormalizeName(altName)
	local version = data.version or 0
	if G.pendingAltRequests then G.pendingAltRequests[norm] = nil end
	if G.pendingP2PRequests then
		G.pendingP2PRequests[norm] = nil
		-- Cancel the 15s ACK fallback: the peer confirmed no changes.
		if G.pendingP2PFallbackTimeouts and G.pendingP2PFallbackTimeouts[norm] then
			G.pendingP2PFallbackTimeouts[norm]:Cancel()
			G.pendingP2PFallbackTimeouts[norm] = nil
			TOGBankClassic_Output:Debug("P2P", "COMPLETE", "Cancelled fallback timeout for %s (no-change received)", altName)
		end
	end

	-- P2P-006: a no-change is a completed sync.
	if TOGBankClassic_P2PSession then TOGBankClassic_P2PSession:OnAltCompleted(norm, sender) end

	TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Received no-change from %s for alt %s (version=%d)", sender, altName, version)
	self:Debug("SYNC", "RECEIVE", ">", ColorPlayerName(sender), QUERIES_COLOR,
		string.format("no changes for %s (v%d)", ColorPlayerName(altName), version))

	if (data.bankSlots or data.bagsSlots) and G.Info and G.Info.alts then
		local localAlt = G.Info.alts[norm]
		if localAlt then
			-- INV2-RETIRE-003: the sub-tables are metadata only -- no `items = {}` seed.
			if data.bankSlots then
				if not localAlt.bank then localAlt.bank = {} end
				localAlt.bank.slots = data.bankSlots
				TOGBankClassic_Output:Debug("SYNC", "SLOT-CORRECTION", "%s bankSlots %d/%d (from %s)",
					norm, data.bankSlots.count or 0, data.bankSlots.total or 0, sender)
			end
			if data.bagsSlots then
				if not localAlt.bags then localAlt.bags = {} end
				localAlt.bags.slots = data.bagsSlots
				TOGBankClassic_Output:Debug("SYNC", "SLOT-CORRECTION", "%s bagsSlots %d/%d (from %s)",
					norm, data.bagsSlots.count or 0, data.bagsSlots.total or 0, sender)
			end
		end
	end

	-- Mark sync as complete
	G:ConsumePendingSync("alt", sender, norm)
	if G.hasRequested then
		if G.requestCount == nil then
			G.requestCount = 0
		else
			G.requestCount = G.requestCount - 1
		end
		if G.requestCount == 0 then
			G.hasRequested = false
			TOGBankClassic_Output:Info("Sync completed.")
		end
	end
end

function TOGBankClassic_Chat:Init()
	TOGBankClassic_Output:Debug("PROTOCOL", "VERSION-BROADCAST", "[INIT] TOGBankClassic_Chat:Init() starting")
	TOGBankClassic_Core:RegisterChatCommand("togbank", function(input)
		return TOGBankClassic_Chat:ChatCommand(input)
	end)
	-- /bank and /gbank are registered after Options init via RegisterAliasCommands()

	self.addon_outdated = false
	self.online_bankers = {}  -- tracks online bankers for pull-based protocol

	self.last_alt_sync = {}
	self.sync_queue = {}
	self.is_syncing = false
	self.last_share_sync = nil

	-- PERF-020: Batch hash broadcast processing to prevent stuttering from sync storms
	self.hashBroadcastQueue = {}  -- {sender, data, distribution, isSenderBanker, altCount}
	self.hashBroadcastTimer = nil
	self.HASH_BROADCAST_BATCH_DELAY = 0.15  -- seconds to batch incoming broadcasts

	for _, prefix in ipairs(TOGBankClassic_Chat.COMM_PREFIXES) do
		TOGBankClassic_Core:RegisterComm(prefix, function(p, message, distribution, sender)
			TOGBankClassic_Chat:OnCommReceived(p, message, distribution, sender)
		end)
	end

	self:VerifyCommPrefixes()
end

-- Called from Core after Options is initialized — registers /bank and /gbank if enabled.
function TOGBankClassic_Chat:RegisterAliasCommands()
	if TOGBankClassic_Options:IsRegisterBankCommandEnabled() then
		TOGBankClassic_Core:RegisterChatCommand("bank", function(input)
			return TOGBankClassic_Chat:ChatCommand(input)
		end)
	end
	if TOGBankClassic_Options:IsRegisterGbankCommandEnabled() then
		TOGBankClassic_Core:RegisterChatCommand("gbank", function(input)
			return TOGBankClassic_Chat:ChatCommand(input)
		end)
	end
end

-- Wrapper for debug logging (delegates to centralized logger)
function TOGBankClassic_Chat:Debug(...)
	return TOGBankClassic_Output:Debug(...)
end

-- Centralized sync function for both /sync command and UI opening
function TOGBankClassic_Chat:PerformSync()
	-- SYNC-008 used ALERT here so a manual sync jumped the queue. P2P-031 made the ALERT lane the
	-- handshake lane -- 100-byte whispers that must not wait -- and this ~5 KB, ~20-chunk broadcast
	-- was the one other regular thing in it. The operator: "you can move it and we can test it."
	-- NORMAL is still ahead of the BULK payloads; the collision-guard retry logic in SyncDeltaVersion
	-- treats NORMAL and ALERT alike (only BULK is dropped on collision).
	TOGBankClassic_Events:SyncDeltaVersion("NORMAL")
	-- RequestHashListFromBanker's return was captured into `hashListRequested` and never read, so
	-- a refusal (no banker online, collision guard held) was invisible here. Called for its effect
	-- only; if the caller ever needs to report "no banker to ask", read the return rather than
	-- reinstating the unused local.
	if PEER_TO_PEER and PEER_TO_PEER.ENABLED then
		TOGBankClassic_Guild:RequestHashListFromBanker()
	end
	TOGBankClassic_Guild:FastFillMissingAlts()
	TOGBankClassic_Guild:ReportBankerDataProgress("sync", true)
	-- REQUEST-001: Use index-based request sync (modern delta protocol)
	-- Pass force=true to bypass the 60s cooldown — this is an explicit user action, not a timer.
	local sent = TOGBankClassic_Guild:QueryRequestsIndex(nil, "ALERT", true)
	if sent then
		if not TOGBankClassic_Options:IsSyncProgressMuted() then
			TOGBankClassic_Output:Response("Syncing requests with guild...")
		end
		-- Mark the sync as user-visible so EndRequestsIndexSync prints a completion message.
		TOGBankClassic_Guild:EnsureRequestsIndexSyncState()
		TOGBankClassic_Guild.requestsIndexSync.notify = true
	else
		TOGBankClassic_Output:Response("Request sync failed to send.")
	end
end

-- `SyncBankerHashAfterAdopt` WAS HERE and went with the legacy alt-data branch that was its only
-- caller. It re-pointed `latestBankerHashes[norm]` at whatever the local record held after adopting
-- a full legacy payload, so that `IsAltSyncPending` would stop reporting the alt as out of date.
--
-- It is not worth reviving on the tuple path, and the reason is the point of this whole change: it
-- copied `existing.inventoryHash` -- REVISION 1, and whatever this client happened to hold -- into
-- the advertisement this client then serves to everyone else. That is the same "publish a number I
-- did not author" shape as the three minting sites deleted in HASH-CANON-002, arrived at from the
-- advertising side rather than the stamping side.
--
-- The tuple path needs no equivalent: it stores the AUTHOR'S canon verbatim, so the record and the
-- advertisement already agree without anything copying between them.

local function FormatSyncStatus(status)
	if status == ADOPTION_STATUS.ADOPTED then
		return "(newer, integrating)"
	end
	if status == ADOPTION_STATUS.STALE then
		return "(older, discarding)"
	end
	if status == ADOPTION_STATUS.INVALID then
		return "(invalid, ignoring)"
	end
	if status == ADOPTION_STATUS.UNAUTHORIZED then
		return "(unauthorized, ignoring)"
	end
	if status == ADOPTION_STATUS.IGNORED then
		return "(ignored)"
	end
	return ""
end

-- SYNC-001 fix: Roster-based validation to prevent cross-guild data bleed
-- Only accept alt data if both sender and claimed alt are in current guild
function TOGBankClassic_Chat:IsAltDataAllowed_RosterBased(sender, claimedNorm)
	-- Check if sender is in the current guild
	if not TOGBankClassic_Guild:IsInCurrentGuildRoster(sender) then
		TOGBankClassic_Output:Debug(
			"PROTOCOL", "ALT-REQUEST",
			"Rejecting alt data from %s: sender not in current guild roster",
			sender
		)
		return false
	end

	-- Check if claimed alt is in the current guild's banker roster
	if not TOGBankClassic_Guild:IsBank(claimedNorm) then
		TOGBankClassic_Output:Debug(
			"PROTOCOL", "ALT-REQUEST",
			"Rejecting alt data for %s: not a banker in current guild roster",
			claimedNorm
		)
		return false
	end

	return true
end

function TOGBankClassic_Chat:IsAltDataAllowed(sender, claimedNorm)
	return self:IsAltDataAllowed_RosterBased(sender, claimedNorm)
end

-- togbank-v, togbank-dv, togbank-dv2 removed 2026-04-01: all dead prefixes, handlers deleted.

-- PERF-020: Process queued hash broadcasts in batch to prevent stuttering
function TOGBankClassic_Chat:ProcessQueuedHashBroadcasts()
	local startTime = debugprofilestop()
	local queueSize = #self.hashBroadcastQueue

	if queueSize == 0 then
		return
	end

	TOGBankClassic_Output:Debug("P2P", "OFFER", "Processing %d queued hash broadcasts", queueSize)

	-- Deduplicate by sender (if same sender broadcasted multiple times, process most recent)
	local uniqueBroadcasts = {}
	for _, entry in ipairs(self.hashBroadcastQueue) do
		uniqueBroadcasts[entry.sender] = entry  -- Later entries overwrite earlier ones
	end

	-- Process each unique broadcast
	for sender, entry in pairs(uniqueBroadcasts) do
		local data = entry.data
		-- WIRE-SKEW-008: a broadcast from a release we cannot exchange data with is read for its
		-- VERSION (NotePeerAddonVersion, at the door) and nothing else. Its claims cannot move a
		-- tab or the cache (Guild:ClaimantCanServe, on every Note*), and offering it our newer copy
		-- only produces a sync-request we refuse -- read off the operator's log as twenty refusals a
		-- minute. One line, then on to the next sender.
		local capable, why = TOGBankClassic_Guild:PeerSpeaksDataLeg(sender)
		if not capable then
			TOGBankClassic_Output:Debug("P2P", "BROADCAST", "HL broadcast from %s ignored: release %s is before the data leg changed",
				tostring(sender), tostring(why))
		else

		-- Build hash-offer: alts where WE have newer data than what the sender advertised
		local offerAlts  = {}
		local myAlts     = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts or {}

		-- Build a lookup of what alts the sender advertised
		local senderAlts = {}
		for altName, peerSummary in pairs(data.alts) do
			local norm = TOGBankClassic_Guild:NormalizeName(altName)
			-- HASH-CANON-012: OUR OWN CHARACTER IS NOT SKIPPED HERE ANY MORE. This read
			-- `if norm and norm ~= myPlayer`, and the three Note* calls below do refuse claims about
			-- ourselves (rule 1 -- nothing a peer says about our bank can be newer than what we
			-- hold); but the skip also stopped us OFFERING our own bank, which is the most
			-- authoritative offer there is. Read off the live guild: Alchemyrcp's V2 data existed on
			-- exactly one client -- Alchemyrcp's own -- and that client answered every broadcast
			-- about it with silence, so a viewer's `known=-` never filled and the data was only ever
			-- fetched by asking Alchemy directly for a hash list, which picks one online banker at
			-- random. The Note* calls keep their own self-guards; the offer compare runs for self.
			if norm then
				senderAlts[norm] = peerSummary
				-- TABCOLOUR-002: a broadcast is the earliest anyone mentions a version, so it is
				-- where the tab learns fastest that something newer exists.
				TOGBankClassic_Guild:CanonicaliseSummary(peerSummary)                -- HASH-CANON-005
				TOGBankClassic_Guild:NoteAdvertisedPublishTime(norm, peerSummary, sender)   -- CLAIM-TRACE-001
				-- HASH-CANON-011: the broadcast feeds the advertised-hash cache too, through the one
				-- writer. It did not -- only the hash-list REPLY and the offer path did -- so a
				-- banker's `/togbank share` raised the tab's newest-time and left `latestBankerHashes`
				-- (what hashdump prints as `known`, and what IsAltSyncPending / catch-up read) with
				-- no canon for it. The operator, watching exactly that: "I should be getting the new
				-- hash from the broadcast at least." The comment at the end of this function has
				-- claimed the cache was updated here since PERF-020; now it is.
				TOGBankClassic_Guild:NoteAdvertisedHashes(norm, peerSummary, sender)
				-- P2P-035: EVERY BROADCAST IS AN OFFER. The operator: "OH YES!" A broadcast names the
				-- versions its sender can DELIVER (ServableCanon), so a version newer than ours is a
				-- peer saying "I hold newer" -- exactly what a hash-offer says -- and there is no
				-- reason to wait for our own next broadcast to be answered. The summary carries the
				-- canon, so OnOffer needs no version query; inside a collect window it accumulates,
				-- outside one it dispatches at once (P2P-034).
				if TOGBankClassic_P2PSession and peerSummary.hashV2
						and TOGBankClassic_Guild:AdvertisedImproves(norm, peerSummary) then
					peerSummary.cachedByBroadcast = true   -- the two Note* calls above already ran
					TOGBankClassic_P2PSession:OnOffer(sender, { [norm] = peerSummary })
				end
				-- MULTIPC-002: a broadcast naming OUR OWN character at a later version than we hold is
				-- a peer telling us who holds the diff base this PC will need when it re-reads
				-- (docs/DELTA_RELEASE.md section 3.5). AdvertisedImproves is "self" for our own name,
				-- so it never reaches OnOffer; recorded for Bank here instead.
				if norm == TOGBankClassic_Guild:GetNormalizedPlayer() then
					TOGBankClassic_Guild:NoteSelfHolder(peerSummary.hashV2, sender)
				end
				local myAlt = myAlts[norm]
				if myAlt and TOGBankClassic_Guild:HasAltContent(myAlt, norm) then
					-- HASH-CANON-005, and the operator's point about it: "now when you do a
					-- broadcast, super easy to figure out if you should whisper respond or not. you
					-- don't have to do much computation to figure out if you have something newer."
					-- The canon is `<dts><hash>`, so "is mine newer?" is ONE STRING COMPARE. This
					-- used to compare the sidecar `updatedAt` fields, which the canon now carries.
					--
					-- Only a readable canon can claim to be newer: a copy with none (revision 1 only,
					-- or a v1.4.0 number with no time) is not a version anyone can place, so it is
					-- never offered as one -- "v1 is always red" applied to the sending side. KNOWN
					-- COST: a client holding only revision-1 data no longer relays it.
					-- HASH-CANON-009: and only a canon we can DELIVER -- ServableCanon is nil when
					-- the V2 store holds no records for the alt, so a legacy copy wearing a
					-- re-encoded canon is not offered as a version either; SendAltData could not
					-- have sent it.
					local mine   = TOGBankClassic_Guild:ServableCanon(norm)
					local theirs = peerSummary.hashV2   -- canonicalised above
					-- P2P-034: "newer" is the PUBLISH TIME off the front of the canon, the same
					-- compare the receiving side makes (AdvertisedImproves) -- one function, so the
					-- two sides cannot drift (Peer Review F6). A peer with no canon is offered anything.
					local offer = TOGBankClassic_Guild:CanonIsNewer(mine, theirs)
					-- The decision, per bank, or the log shows offers going out and nothing about
					-- the banks that were NOT offered -- which is the half that needs diagnosing.
					TOGBankClassic_Output:Debug("P2P", "OFFER", "  %s: mine=%s theirs=%s -> %s",
						norm, tostring(mine), tostring(theirs), offer and "OFFER" or "skip")
					if offer then offerAlts[norm] = true end
				end
			end
		end

		-- Also offer alts we have that the sender didn't mention at all (e.g. after a wipe
		-- the sender's list is empty, so we proactively advertise everything we have).
		-- IsBank() guard prevents account-wide SV alts from other guilds bleeding in.
		-- HASH-CANON-012: self is offered here too, for the same reason as above -- a wiped viewer's
		-- empty list must be answered by the banker itself, not only by relays.
		-- HASH-CANON-009: only a canon we can DELIVER is an offer; ServableCanon is nil otherwise.
		for norm, myAlt in pairs(myAlts) do
			if not senderAlts[norm] then
				if myAlt and TOGBankClassic_Guild:HasAltContent(myAlt, norm)
						and TOGBankClassic_Guild:IsBank(norm)
						and TOGBankClassic_Guild:ServableCanon(norm) then
					offerAlts[norm] = true
				end
			end
		end

		-- P2P-035: the offer is BANKER NUMBERS ONLY -- "we want to keep the offer hashless and TINY".
		-- Thirteen bankers is 52 bytes; it is one chunk however many are newer. The version is
		-- established by the requester's query step, to the few peers it chooses, not broadcast to
		-- everyone in every offer. A banker with no number yet cannot be offered by number and is
		-- left out; it is offered again once its account has numbered it.
		local BN = TOGBankClassic_BankerNumbers
		local numbers, unnumbered = {}, 0
		for norm in pairs(offerAlts) do
			local num = BN and BN:NumberOf(norm)
			if num then numbers[#numbers + 1] = num else unnumbered = unnumbered + 1 end
		end
		table.sort(numbers)
		if #numbers > 0 then
			local offerData = TOGBankClassic_Core:SerializeWithChecksum({
				type = "hash-offer2", v = BN:Version(), n = BN:EncodeNumbers(numbers),
			})
			TOGBankClassic_Core:SendWhisper("togbank-hl", offerData, sender, "NORMAL")
			TOGBankClassic_Output:Debug("P2P", "OFFER", "Sent hash-offer2 to %s for %d banker(s)%s (%d bytes)", sender, #numbers,
				unnumbered > 0 and string.format(", %d unnumbered left out", unnumbered) or "", offerData and #offerData or 0)
		elseif unnumbered > 0 then
			TOGBankClassic_Output:Debug("P2P", "OFFER", "Nothing offered to %s: %d newer banker(s) have no number yet", sender, unnumbered)
		end
		end -- WIRE-SKEW-008 capable sender
	end

	-- Clear queue and timer
	self.hashBroadcastQueue = {}
	self.hashBroadcastTimer = nil

	-- Refresh the tab colours now that latestBankerHashes has been updated. BROWSE-008: through
	-- RefreshSoon, not DrawContent -- RefreshSoon is the ONE place that also repaints the Guild
	-- Bank window (its Bankers tab and the status dots on Browse rows). This was a direct
	-- DrawContent, so a broadcast batch repainted the old window and left the new one stale until
	-- something else happened to raise a signal. The operator: "is there a refresh on the new
	-- banker tab when something updates?" -- not from here, it was not.
	if TOGBankClassic_UI_Inventory and TOGBankClassic_UI_Inventory.RefreshSoon then
		TOGBankClassic_UI_Inventory:RefreshSoon()
	end

	local duration = debugprofilestop() - startTime
	TOGBankClassic_Output:Debug("P2P", "OFFER", "Batch processed %d broadcasts in %.2fms", queueSize, duration)
end

--- A peer's ACK to our pull-path alt-request for `norm` has arrived: the "no response" timer is
--- answered, and the "ACKed but never delivered" watch takes over. Returns false when nothing was
--- pending for the alt (an ACK we did not ask for, or a second ACKer after the first -- only the
--- first is asked for data). ONE spelling for the relay ACK and the banker ACK (CHAIN-004, Peer
--- Review F1): the banker branch had none of this bookkeeping.
---
--- The 15-second watch: if the peer ACKs but never sends (disconnect, crash, an at-capacity refusal
--- with no session to hear it), advance the session that owns the alt, or schedule the catch-up.
--- TIMER-001 / AUDIT finding 24: a long window, and the callback advances whatever session owns
--- the alt when it fires. P2P-026: through ArmAltTimeout, so a re-ACK inside those 15s cancels the
--- previous watch instead of leaving two racing to advance the same session.
---@return boolean wasPending
function TOGBankClassic_Chat:OnPullAckAccepted(sender, altName, norm)
	local G = TOGBankClassic_Guild
	if not (G.pendingP2PRequests and G.pendingP2PRequests[norm]) then return false end
	if not TOGBankClassic_Options:IsSyncProgressMuted() then
		TOGBankClassic_Output:Info("P2P: Peer %s acknowledged %s - will send delta", sender, altName)
	end
	G.pendingP2PRequests[norm] = nil
	if G.pendingP2PTimeouts and G.pendingP2PTimeouts[norm] then
		G.pendingP2PTimeouts[norm]:Cancel()
		G.pendingP2PTimeouts[norm] = nil
	end
	if G.pendingAltRequests then G.pendingAltRequests[norm] = nil end
	-- "Delivered" is a VERSION that moved, not "has content": a bank we already held a stale copy
	-- of satisfied HasAltContent, and the watch printed "successfully delivered" over an ACK that
	-- was never followed by data (Galdof's log, 2026-09-12, against v1.4.1 relays that cannot
	-- answer this tree's QUERY at all). Compare the held canon / time before and after.
	local function heldVersion()
		local alt = G.Info and G.Info.alts and G.Info.alts[norm]
		if not alt then return nil end
		return tostring(alt.inventoryHashV2) .. "@" .. tostring(alt.inventoryUpdatedAt or alt.version)
	end
	local before = heldVersion()
	G:ArmAltTimeout("pendingP2PFallbackTimeouts", norm, 15, function()
		local alt = G.Info and G.Info.alts and G.Info.alts[norm]
		if not alt or not G:HasAltContent(alt, norm) or heldVersion() == before then
			TOGBankClassic_Output:Debug("P2P", "COMPLETE", "Peer %s ACKed %s but never delivered data - advancing session", sender, altName)
			if TOGBankClassic_P2PSession then
				local sid = TOGBankClassic_P2PSession.sessionsByAlt[norm]
				if sid then
					TOGBankClassic_P2PSession:AdvanceCandidate(sid, "ack_no_data")
				else
					TOGBankClassic_P2PSession:ScheduleCatchUp("ack_no_data")
				end
			end
		else
			TOGBankClassic_Output:Debug("P2P", "COMPLETE", "Peer %s successfully delivered data for %s", sender, altName)
		end
		if G.pendingP2PFallbackTimeouts then G.pendingP2PFallbackTimeouts[norm] = nil end
	end)
	return true
end

function TOGBankClassic_Chat:OnCommReceived(prefix, message, distribution, sender)
	local prefixDesc = COMM_PREFIX_DESCRIPTIONS[prefix] or "(Unknown)"

	if prefix == "togbank-hlr" then
		TOGBankClassic_Output:Debug("PROTOCOL", "HLR", "HLR incoming: from=%s via=%s (%d bytes)", tostring(sender), tostring(distribution), message and #message or 0)
	end

	-- WHISPER DEBUG
	if distribution == "WHISPER" or prefix == "togbank-r" or prefix == "togbank-rr" then
		TOGBankClassic_Output:Debug("COMMS", "RECEIVE", "Received: %s via %s from %s", prefix, distribution, sender)
	end

	if TOGBankClassic_Constants.SyncPausedByRaid() then
		self:Debug("PROTOCOL", "HASH-SKIP", "> (ignoring)", prefix, prefixDesc, "from", ColorPlayerName(sender), "(in raid)")
		return
	end
	local player = TOGBankClassic_Guild:GetPlayer()
	-- Normalize the sender so spacing/hyphen formats match
	sender = TOGBankClassic_Guild:NormalizeName(sender)

	-- Mark sender as online (they just sent us a message, so they're definitionally online)
	-- This is a FALLBACK for when CHAT_MSG_SYSTEM events haven't fired yet
	-- Source tracking helps debug where online status updates come from
	TOGBankClassic_Guild:UpdateOnlineMember(sender, true, "addon-message-received")

	if player == sender then
		self:Debug("PROTOCOL", "HASH-SKIP", "> (ignoring)", prefix, prefixDesc, "(our own)")
		return
	end

	-- WIRE-SKEW-007: the old wire's state summary. Not deserialized -- its format is the one this
	-- tree retired, and nothing in it is wanted. The SENDER is the fact: only a pre-v1.5.0 requester
	-- sends this, and it sends it the moment we accept, so it is the earliest and surest "old wire"
	-- signal there is. Retiring the receive in v1.5.0 was what let such a requester hold an accepted
	-- slot for the full state-wait; see P2PSession:OnOldWireSummary.
	if prefix == "togbank-state" then
		if TOGBankClassic_P2PSession and TOGBankClassic_P2PSession.OnOldWireSummary then
			TOGBankClassic_P2PSession:OnOldWireSummary(sender)
		end
		return
	end

	---@diagnostic disable-next-line: redundant-parameter
	local success, data = TOGBankClassic_Core:DeserializeWithChecksum(message, { sender = sender, prefix = prefix, distribution = distribution })
	if not success then
		self:Debug("PROTOCOL", "RECV", "> failed to deserialize", prefix, prefixDesc, "from", ColorPlayerName(sender), "error:", tostring(data))
		if prefix == "togbank-hlr" then
			TOGBankClassic_Output:Debug("PROTOCOL", "HLR", "HLR deserialize failed: %s", tostring(data))
		end
		-- A corrupt togbank-ri chunk means we may have missed request IDs from that range.
		-- The receiver would never know to query for those records, so re-request the full
		-- index from the sender. force=true bypasses the per-sender cooldown since this
		-- is a genuine data loss event, not a speculative re-query.
		if prefix == "togbank-ri" then
			TOGBankClassic_Output:Debug("REQUESTS", "INDEX", "togbank-ri CRC failure from %s — re-requesting index", sender)
			TOGBankClassic_Guild:QueryRequestsIndex(sender, "NORMAL", true)
		end
		return
	end

	if prefix ~= "togbank-r" then
		self:Debug("PROTOCOL", "RECV", ">", ColorPlayerName(sender), ">", prefix, prefixDesc)
	end

	if prefix == "togbank-r" then
		TOGBankClassic_Output:Debug("COMMS", "RECEIVE", "togbank-r DATA.TYPE = %s from %s", tostring(data.type), sender)

		-- Check if this is a pull-based request (has type == "alt-request")
		if data.type == "alt-request" then
			-- Pull-based request flow - respond with togbank-rr acknowledgment
			local altName = data.name
			local hashOnly = data.hashOnly or false
			local normAltName = TOGBankClassic_Guild:NormalizeName(altName)

			TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Received pull-based request from %s for alt %s (hashOnly=%s)", sender, altName, tostring(hashOnly))

			TOGBankClassic_Output:Debug("QUERIES", "RECEIVE", "> %s %s %s",
				ColorPlayerName(sender),
				hashOnly and "queries hash query for" or "queries pull-based request for",
				ColorPlayerName(altName)
			)

			-- Check if we have this alt
			local localPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()
			local isBanker = localPlayer and TOGBankClassic_Guild:IsBank(localPlayer) or false
			local hasData = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts and normAltName and TOGBankClassic_Guild.Info.alts[normAltName] ~= nil

			-- HASH-CANON-002: PERF-005's "compute hash on-demand if missing" WAS HERE, and it is
			-- deleted rather than narrowed.
			--
			-- It ran on the QUERY path -- every time any peer asked about an alt -- and stamped a
			-- freshly computed hash onto the record whenever one was absent. That is the defect the
			-- operator described from a live guild, in their words: "the hash gets recomputed
			-- anytime anyone looks at the bank", and "V1 has a broadcast STORM because the hashes
			-- are ALWAYS updating".
			--
			-- WHY A RECOMPUTE HERE IS NEVER CORRECT, even when the field is genuinely missing: a
			-- hash is the IDENTITY OF A VERSION, produced once by the client that authored that
			-- version. This code runs on a client that did NOT author the record -- it is answering
			-- a question about someone else's alt -- so whatever it computes is its own opinion of
			-- someone else's data, minted from whatever `alt.items` happens to hold locally. Two
			-- peers doing this from slightly different local views produce two different numbers for
			-- the same version, every comparison then disagrees, and each disagreement provokes
			-- another sync. That is the storm.
			--
			-- WHAT REPLACES IT: nothing. A record with no canon advertises no canon and is
			-- re-requested from its author, which is self-correcting and cannot go quiet while
			-- wrong. The author stamps at scan (Bank.lua) and that is the only place a hash is born.

			-- PERF-005: For hashOnly queries, only bankers respond (authoritative hash source)
			-- For regular queries, anyone with matching hash can respond (if P2P enabled)
			local shouldRespond = false
			local expectedHash = nil
			local expectedUpdatedAt = nil

			if hashOnly then
				-- Hash query: only banker responds with authoritative hash
				shouldRespond = isBanker and hasData
				if shouldRespond then
					local alt = TOGBankClassic_Guild.Info.alts[normAltName]
					expectedHash = alt.inventoryHash or 0
					expectedUpdatedAt = alt.inventoryUpdatedAt or alt.version or 0
				end
			else
				-- Regular query: bankers respond if they have content, peers respond if hash matches (P2P)
				if isBanker and hasData then
					local alt = TOGBankClassic_Guild.Info.alts[normAltName]
					local hasContent = TOGBankClassic_Guild:HasAltContent(alt, altName)
					if hasContent then
						shouldRespond = true
						expectedHash = alt.inventoryHash or 0
						expectedUpdatedAt = alt.inventoryUpdatedAt or alt.version or 0
					else
						TOGBankClassic_Output:Debug("QUERIES", "SKIP", "P2P-005: Banker skipping response for %s (no content - stub entry)", altName)
					end
				elseif PEER_TO_PEER and PEER_TO_PEER.ENABLED and hasData then
					local alt = TOGBankClassic_Guild.Info.alts[normAltName]
					local myHash = alt.inventoryHash or 0
					-- HASH-CANON-009: a RELAY answers only with a version it can deliver. "Content"
					-- here used to be HasAltContent, which a legacy-only copy satisfies -- and the
					-- Alchemyrcp case is exactly that: a peer holding the Sep-5 copy (same revision-1
					-- hash as the banker, no canon) would win this race, SendAltData would send its
					-- tuples with no canon, and the requester would be left on "v1" red having been
					-- "answered". A banker (the branch above) still answers from its own record.
					local hasContent = TOGBankClassic_Guild:ServableCanon(normAltName) ~= nil
					local p2pSendTotal = TOGBankClassic_P2PSession
						and TOGBankClassic_P2PSession:GetActiveSendTotal() or 0
					local sendQueueFull = p2pSendTotal >= TOGBankClassic_Guild.MAX_PENDING_SENDS
					local requesterHash = data.requesterInventoryHash or 0

					-- Allow response in two scenarios:
					-- 1. P2P with expectedHash: hash must match (normal P2P operation)
					-- 2. No expectedHash but requesterHash=0: post-wipe recovery, any peer can help
					local shouldRespondP2P = false
					if data.expectedHash and myHash == data.expectedHash and hasContent and not sendQueueFull then
						-- Normal P2P: hash match required
						shouldRespondP2P = true
						TOGBankClassic_Output:Debug("QUERIES", "RESPOND", "PERF-005: Peer responding for %s (hash match: %d)", altName, myHash)
					elseif not data.expectedHash and requesterHash == 0 and hasContent and not sendQueueFull then
						-- Post-wipe recovery: requester has no data, any peer can help
						shouldRespondP2P = true
						TOGBankClassic_Output:Debug("QUERIES", "RESPOND", "WIPE-RECOVERY: Peer responding for %s (requester wiped, providing fresh data)", altName)
					elseif sendQueueFull then
						TOGBankClassic_Output:Debug("QUERIES", "SKIP", "PERF-005: Skipping response (send queue full: %d/%d)",
							p2pSendTotal, TOGBankClassic_Guild.MAX_PENDING_SENDS)
					elseif data.expectedHash and myHash == data.expectedHash and not hasContent then
						-- Peer Review F4: the gate above is ServableCanon, so this is "nothing servable"
						-- (legacy-only copy, or no canon), not "no content" -- the old text sent a
						-- reader looking at the wrong condition.
						TOGBankClassic_Output:Debug("QUERIES", "SKIP", "PERF-005: Skipping response for %s (hash matches but nothing servable: no tuple records or no canon)", altName)
					elseif data.expectedHash and myHash ~= data.expectedHash then
						TOGBankClassic_Output:Debug("QUERIES", "SKIP", "PERF-005: Hash mismatch for %s (have %d, expected %d)", altName, myHash, data.expectedHash)
					end

					if shouldRespondP2P then
						-- FIX: Add random backoff to prevent multiple peers responding simultaneously
						local backoff = math.random() * 0.5  -- 0-500ms random delay
						C_Timer.After(backoff, function()
							-- Acquire unified P2P send slot (same cap as sync-request path).
							-- TryAcquireSendSlot atomically checks capacity and increments.
							if not TOGBankClassic_P2PSession or not TOGBankClassic_P2PSession:TryAcquireSendSlot(sender) then
								TOGBankClassic_Output:Debug("QUERIES", "SKIP", "PERF-005: Another peer beat us to it, not responding for %s", altName)
								return
							end
							-- P2P-028: this ACK is an accept too; the slot it took is freed by
							-- Sync:OnDataRequest or by the state-wait timer, never by nothing.
							TOGBankClassic_P2PSession:ArmStateWait(sender, normAltName)

							shouldRespond = true
							expectedHash = myHash
							TOGBankClassic_Output:Debug("P2P", "RESPOND", "P2P: Responding to %s with data for %s (hash=%08x)",
								sender, altName, myHash)
							if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name then
								TOGBankClassic_Database:RecordP2POffered(TOGBankClassic_Guild.Info.name)
							end

							-- Actually send the ACK now
							if shouldRespond then
								local ack = {
									type = "alt-request-reply",
									name = normAltName or altName,
									isBanker = isBanker,
									hasData = hasData,
									hashOnly = hashOnly,
									expectedHash = expectedHash,
									expectedUpdatedAt = expectedUpdatedAt,
								}
								local ackData = TOGBankClassic_Core:SerializeWithChecksum(ack)
								TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Sending ACK: togbank-rr via WHISPER to %s (isBanker=%s, hasData=%s, hash=%s, updatedAt=%s)",
									sender, tostring(isBanker), tostring(hasData), tostring(expectedHash), tostring(expectedUpdatedAt))
								TOGBankClassic_Core:SendCommMessage("togbank-rr", ackData, "WHISPER", sender, "ALERT")   -- P2P-031
								TOGBankClassic_Chat:Debug(
									"SYNC",
									"SEND",
									"<",
									"Sent togbank-rr to",
									ColorPlayerName(sender),
									string.format("(isBanker=%s, hasData=%s, hash=%s)", tostring(isBanker), tostring(hasData), tostring(expectedHash))
								)
							end
						end)
						return  -- Exit early since we'll send ACK in timer
					end
				end
			end

			-- CHAIN-004: the BANKER's ACK is an accept too, and it reserves a send slot exactly as the
			-- relay branch above does -- it never did, so the QUERY it invited arrived at Sync's
			-- accept gate with nothing to claim and was dropped: "Galdof-OldBlanchy sent a QUERY with
			-- no unclaimed accept -- ignored", for every bank only the banker authored. At capacity
			-- the banker does not ACK (the relay rule: "send queue full"); the requester's 5-second
			-- timeout then leads to the catch-up, whose session path queues at this banker in turn.
			if shouldRespond and not hashOnly then
				if TOGBankClassic_P2PSession and not TOGBankClassic_P2PSession:TryAcquireSendSlot(sender) then
					TOGBankClassic_Output:Debug("QUERIES", "SKIP", "Banker not ACKing %s for %s (send queue full: %d/%d)",
						altName, sender, TOGBankClassic_P2PSession:GetActiveSendTotal(), TOGBankClassic_Guild.MAX_PENDING_SENDS)
					return
				elseif TOGBankClassic_P2PSession then
					TOGBankClassic_P2PSession:ArmStateWait(sender, normAltName)
				end
			end

			if shouldRespond then
				-- Send acknowledgment with banker flag and hash
				-- Note: P2P responses with backoff are handled above and return early
				local ack = {
					type = "alt-request-reply",
					name = normAltName or altName,
					isBanker = isBanker,
					hasData = hasData,
					hashOnly = hashOnly,
					expectedHash = expectedHash,
					expectedUpdatedAt = expectedUpdatedAt,
				}
				local ackData = TOGBankClassic_Core:SerializeWithChecksum(ack)

				-- Send acknowledgment via WHISPER to reduce guild channel spam
				TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Sending ACK: togbank-rr via WHISPER to %s (isBanker=%s, hasData=%s, hash=%s, updatedAt=%s)",
					sender, tostring(isBanker), tostring(hasData), tostring(expectedHash), tostring(expectedUpdatedAt))
				if TOGBankClassic_Core:SendWhisper("togbank-rr", ackData, sender, "ALERT") then   -- P2P-031
					self:Debug(
						"SYNC",
						"SEND",
						"<",
						"Sent togbank-rr to",
						ColorPlayerName(sender),
						string.format("(isBanker=%s, hasData=%s, hash=%s)", tostring(isBanker), tostring(hasData), tostring(expectedHash))
					)
				end

			else
				-- Don't respond if we don't have the data
				if not hasData then
					TOGBankClassic_Output:Debug(
						"QUERIES",
						"SKIP",
						"Ignoring pull-based request for %s (no data): isBanker=%s, hasInfo=%s",
						altName,
						tostring(isBanker),
						tostring(TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts and TOGBankClassic_Guild.Info.alts[normAltName] ~= nil)
					)
				else
					-- We have data but not responding - explain why
					local reason = "unknown"
					if hashOnly and not isBanker then
						reason = "hash query but not banker"
					elseif not hashOnly and not isBanker then
						if not PEER_TO_PEER or not PEER_TO_PEER.ENABLED then
							reason = "P2P disabled"
						else
							local alt = TOGBankClassic_Guild.Info.alts[normAltName]
							local myHash = alt and alt.inventoryHash or 0
							local hasContent = alt and TOGBankClassic_Guild:HasAltContent(alt, altName) or false
							local p2pTotal = TOGBankClassic_P2PSession
								and TOGBankClassic_P2PSession:GetActiveSendTotal() or 0
							local sendQueueFull = p2pTotal >= TOGBankClassic_Guild.MAX_PENDING_SENDS
							local requesterHash = data.requesterInventoryHash or 0

							if sendQueueFull then
								reason = string.format("send queue full (%d/%d)", p2pTotal, TOGBankClassic_Guild.MAX_PENDING_SENDS)
							elseif not hasContent then
								reason = "no content (stub entry)"
							elseif data.expectedHash and myHash ~= data.expectedHash then
								reason = string.format("hash mismatch (have %d, expected %d)", myHash, data.expectedHash)
							elseif not data.expectedHash and requesterHash ~= 0 then
								reason = string.format("no expectedHash but requester has data (requesterHash=%d)", requesterHash)
							else
								reason = "shouldRespond logic failed"
							end
						end
					end
					TOGBankClassic_Output:Debug("QUERIES", "SKIP", "Ignoring pull-based request for %s (%s)", altName, reason)
				end
			end

			return
		end

		-- Legacy request handling
		if data.player then
			-- Use REQUESTS category for request-related queries, SYNC for alt queries
			local isRequestQuery = data.type and string.find(data.type, "^requests") ~= nil
			local category = isRequestQuery and "REQUESTS" or "SYNC"
			local extraInfo = ""
			if data.type == "requests-index" and data.hash then
				local myHash = TOGBankClassic_Guild:GetRequestsHash()
				local querierHash = tonumber(data.hash) or 0
				extraInfo = string.format(" (their:%08x ours:%08x)", querierHash, myHash)
			end
			self:Debug(
				category,
				"RECEIVE",
				">",
				ColorPlayerName(sender),
				QUERIES_COLOR,
				isRequestQuery and "[REQ]" or "",
				data.type,
				(data.name and ColorPlayerName(TOGBankClassic_Guild:NormalizeName(data.name)) or "") .. extraInfo
			)

			if data.type == "requests-index" then
				local matches = (data.player == "*" or data.player == player)
				if matches then
					-- SYNC-011: Only respond if our hash differs from the querier's.
					-- If hashes match, querier already has exactly what we have - stay silent.
					-- If our hash is 0 we have nothing to offer - stay silent.
					local myHash = TOGBankClassic_Guild:GetRequestsHash()
					local querierHash = tonumber(data.hash) or 0
					if myHash ~= 0 and myHash ~= querierHash then
						TOGBankClassic_Output:Debug("REQUESTS", "INDEX", "Responding to requests-index query from %s (mine=%08x theirs=%08x)", tostring(sender), myHash, querierHash)
						TOGBankClassic_Guild:EnqueueIndexResponse(sender)
					else
						TOGBankClassic_Output:Debug("REQUESTS", "INDEX", "Skipping requests-index query from %s (mine=%08x theirs=%08x)", tostring(sender), myHash, querierHash)
					end
				end
			end
			if data.type == "requests-by-id" then
				local matches = (data.player == "*" or data.player == player)
				if matches then
					TOGBankClassic_Output:Debug("REQUESTS", "INDEX",
						"%s queries [REQ] requests-by-id (%d IDs)", tostring(sender), data.ids and #data.ids or 0)
					TOGBankClassic_Guild:EnqueueRequestsById(sender, data.ids)
				end
			end
		end

		-- Alt queries are per-player, only respond if query is for us
		if data.player and data.player == player then
			-- Roster query removed: Roster is now rebuilt locally from guild notes

			if data.type == "alt" then
				local nameNorm = TOGBankClassic_Guild:NormalizeName(data.name)

				table.insert(self.sync_queue, nameNorm)
				if not self.is_syncing then
					TOGBankClassic_Chat:ProcessQueue()
				end
			end
		end
	end

	if prefix == "togbank-rr" then
		-- P2P-006: Session handshake — sync-request (we are the data provider).
		-- Requester asks us to send data for one alt; we accept or reject based on capacity.
		if data.type == "sync-request" then
			local sessionId = data.sessionId
			local requester = data.requester or sender
			local altName   = data.altName
			TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "sync-request from %s for %s (sid=%s, canon=%s)",
				requester, tostring(altName), tostring(sessionId), tostring(data.canon))
			if TOGBankClassic_P2PSession and altName and sessionId then
				TOGBankClassic_P2PSession:HandleSyncRequest(sessionId, requester, altName, data.canon)
			end
			return
		end
		-- P2P-035: "what version do you hold for these?" -- the requester's query to a few of the
		-- peers that offered, before it asks any of them for data. Both halves are ALERT and tiny.
		if data.type == "ver-query" then
			if TOGBankClassic_P2PSession then
				TOGBankClassic_P2PSession:HandleVersionQuery(sender, data.n)
			end
			return
		end
		if data.type == "ver-reply" then
			if TOGBankClassic_P2PSession then
				TOGBankClassic_P2PSession:OnVersionReply(sender, data.e)
			end
			return
		end
		-- P2P-006: sync-accept / sync-busy (we are the requester; peer answered our sync-request).
		if data.type == "sync-accept" then
			local sessionId = data.sessionId
			TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "sync-accept from %s (sid=%s)", sender, tostring(sessionId))
			if TOGBankClassic_P2PSession and sessionId then
				TOGBankClassic_P2PSession:OnSyncAccept(sessionId, sender)
			end
			return
		end
		if data.type == "sync-busy" then
			local sessionId = data.sessionId
			TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "sync-busy from %s (sid=%s, alt=%s)", sender, tostring(sessionId), tostring(data.alt))
			if TOGBankClassic_P2PSession and sessionId then
				TOGBankClassic_P2PSession:OnSyncBusy(sessionId, sender)
			elseif TOGBankClassic_P2PSession and type(data.alt) == "string" then
				-- CHAIN-004: the provider refused our data QUERY (it had no accept for it and no room):
				-- named by alt, because the QUERY carries no session id. Our session for that alt, if
				-- this peer is the one it is waiting on, moves to its next holder now.
				TOGBankClassic_P2PSession:OnQueryRefused(data.alt, sender)
			end
			return
		end
		-- SYNCED-001: a receiver applied a version we served it -- the receipt the propagation tracker
		-- turns green on. Only our own bank's current version registers (Propagation checks).
		if data.type == "sync-done" then
			if TOGBankClassic_Propagation and type(data.alt) == "string" and type(data.canon) == "string" then
				local norm = TOGBankClassic_Guild:NormalizeName(data.alt) or data.alt
				TOGBankClassic_Propagation:NoteHolder(norm, data.canon, sender, "seen")
			end
			return
		end
		-- P2P-029: a requester we queued found another peer (or gave up): forget it.
		if data.type == "sync-cancel" then
			if TOGBankClassic_P2PSession then
				TOGBankClassic_P2PSession:DequeueSend(data.sessionId, sender)
				-- P2P-038: and an accept still waiting on its query gives its slot back now.
				TOGBankClassic_P2PSession:CancelAccept(data.sessionId, sender)
			end
			return
		end
		-- P2P-029: the peer has our request in its queue and will accept when a slot frees. We wait
		-- unless another untried peer holds the bank -- OnSyncQueued decides.
		if data.type == "sync-queued" then
			local sessionId = data.sessionId
			TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "sync-queued from %s (sid=%s, position=%s)", sender, tostring(sessionId), tostring(data.position))
			if TOGBankClassic_P2PSession and sessionId then
				TOGBankClassic_P2PSession:OnSyncQueued(sessionId, sender)
			end
			return
		end
		if data.type == "alt-request-reply" then
			local altName = data.name
			local isBanker = data.isBanker or false
			local hasData = data.hasData or false
			local hashOnly = data.hashOnly or false
			local expectedHash = data.expectedHash
			local expectedUpdatedAt = data.expectedUpdatedAt

			TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Received ACK: togbank-rr from %s for alt %s (isBanker=%s, hasData=%s, hashOnly=%s, hash=%s, updatedAt=%s)",
				sender, altName, tostring(isBanker), tostring(hasData), tostring(hashOnly), tostring(expectedHash), tostring(expectedUpdatedAt))

			self:Debug(
				"SYNC",
				"RECEIVE",
				">",
				ColorPlayerName(sender),
				QUERIES_COLOR,
				string.format("acknowledged request for %s (banker=%s, hasData=%s, hash=%s)",
					ColorPlayerName(altName),
					tostring(isBanker),
					tostring(hasData),
					tostring(expectedHash))
			)

			-- WIRE-SKEW-001: an ACK from a peer on a release before the data leg changed invites a
			-- query it cannot answer; asking would only arm the 15-second watch to no purpose. The
			-- next ACKer, or the catch-up, carries on.
			local capable, why = TOGBankClassic_Guild:PeerSpeaksDataLeg(sender)
			if hasData and not hashOnly and not capable then
				TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Ignoring %s's ACK for %s: it runs %s, before the data leg changed", sender, altName, tostring(why))
				return
			end

			-- PERF-005: If we have a hash from banker, broadcast to GUILD to enable P2P
			-- Any peer with matching hash can respond instead of just the banker
			if isBanker and hashOnly and expectedHash and PEER_TO_PEER and PEER_TO_PEER.ENABLED then
				-- Store expected hash for validation when peers respond
				if not TOGBankClassic_Guild.expectedHashes then
					TOGBankClassic_Guild.expectedHashes = {}
				end
				local norm = TOGBankClassic_Guild:NormalizeName(altName)
				TOGBankClassic_Guild.expectedHashes[norm] = expectedHash
				if expectedUpdatedAt then
					TOGBankClassic_Guild.expectedHashUpdatedAt = TOGBankClassic_Guild.expectedHashUpdatedAt or {}
					TOGBankClassic_Guild.expectedHashUpdatedAt[norm] = expectedUpdatedAt
				end

				-- Track pending P2P request for fallback
				TOGBankClassic_Guild.pendingP2PRequests = TOGBankClassic_Guild.pendingP2PRequests or {}
				TOGBankClassic_Guild.pendingP2PRequests[norm] = { banker = sender, requestedAt = GetTime() }

				-- Now broadcast regular request to GUILD with expectedHash so peers can respond
			-- MAIL-SYNC: Include requester's mailHash for mail change detection
			local ourAlt = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts and TOGBankClassic_Guild.Info.alts[altName]
			local ourMailHash = (ourAlt and ourAlt.mailHash) or 0
			local p2pRequest = {
				type = "alt-request",
				name = altName,
				requester = TOGBankClassic_Guild:GetNormalizedPlayer(),
				hashOnly = false,
				expectedHash = expectedHash,  -- Peers will validate against this
				requesterMailHash = ourMailHash,
			}
			local p2pData = TOGBankClassic_Core:SerializeWithChecksum(p2pRequest)
			TOGBankClassic_Core:SendCommMessage("togbank-hl", p2pData, "GUILD", nil, "NORMAL")
				if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name then
					TOGBankClassic_Database:RecordP2PRequestBroadcast(TOGBankClassic_Guild.Info.name)
				end

				-- Fallback: if no peer responds, request from banker directly
				-- TIMER-001 / AUDIT finding 24: NewTimer, so the handle stored by ArmAltTimeout is
				-- real. With After it assigned nil, the key was never created (a Lua table cannot
				-- hold nil), so every `if pendingP2PTimeouts[norm] then` guard was false and no
				-- cancel ever ran. The harm is ACROSS requests: BroadcastP2PRequest has no
				-- in-flight guard, so a second request for the same alt inside this window
				-- re-populates the key, and an orphaned timer then tears down the NEW request and
				-- blames a timeout belonging to a request that already succeeded.
				-- P2P-026: arming through ArmAltTimeout cancels this alt's previous timer, which is
				-- what closes that second path -- making the cancels work only covered the case
				-- where a peer actually ACKed.
				TOGBankClassic_Guild:ArmAltTimeout("pendingP2PTimeouts", norm, 5, function()
					-- Closes over the `norm` computed above rather than recomputing it: identical
					-- expression over the same `altName` upvalue, so this is the same value, and
					-- shadowing it here only made the two look like they could differ.
					-- One clearing (Guild:ClearPendingP2PRequest): pending entry, expected hashes, the
					-- alt-request marker, both timers -- it used to be spelled out here as well.
					local pending = TOGBankClassic_Guild:ClearPendingP2PRequest(norm)
					if pending then
						TOGBankClassic_Output:Debug("P2P", "COMPLETE", "PERF-005: No P2P response for %s, scheduling catch-up", altName)
						if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name then
							TOGBankClassic_Database:RecordP2PBankerFallback(TOGBankClassic_Guild.Info.name)
						end
						TOGBankClassic_P2PSession:ScheduleCatchUp("p2p_no_response")
					end
				end)
			elseif not isBanker and hasData and TOGBankClassic_Guild.pendingP2PRequests then
				-- P2P: Non-banker (peer) acknowledged - continue with delta sync
				local norm = TOGBankClassic_Guild:NormalizeName(altName)
				if self:OnPullAckAccepted(sender, altName, norm) then
					-- THE DELTA RELEASE step 3b: the data leg is the host's QUERY, naming our canon.
					if hasData and expectedHash then
						TOGBankClassic_Inventory_Sync:RequestFrom(sender, norm)
					end
				end
			elseif hasData then
				-- Banker (non-P2P path) or fallback. A responder that advertised no hash at all is
				-- asked for everything (PERF-006).
				-- CHAIN-004 (Peer Review F1): the banker's ACK answers OUR broadcast too, so it takes
				-- the same bookkeeping the relay branch above does -- the 5-second "no response" timer
				-- is cancelled (it used to fire anyway, logging "banker ... online, did not answer"
				-- under an ACK that had arrived), and the 15-second "ACKed but never delivered" watch is
				-- armed, which is what carries an at-capacity refusal or a lost reply into catch-up.
				local norm = TOGBankClassic_Guild:NormalizeName(altName)
				self:OnPullAckAccepted(sender, altName, norm)
				TOGBankClassic_Inventory_Sync:RequestFrom(sender, norm, expectedHash == nil)
			else
				TOGBankClassic_Output:Debug("P2P", "HANDSHAKE", "Not asking %s for data (hasData=false)", sender)
			end
	end
end

	-- THE DELTA RELEASE step 3b: the `togbank-state` and `togbank-nochange` branches WERE HERE.
	-- The state summary is gone (the requester asks on the DeltaSync host's QUERY channel, naming
	-- the canon it holds -- Inventory/Sync.lua), and the no-change rides the host's RESPONSE as
	-- `inv-nochange`, handled by HandleNoChange below. Both prefixes are retired, send and receive.

	if prefix == "togbank-rm" then
		TOGBankClassic_Output:Debug("COMMS", "RECEIVE", "[SYNC-003p] togbank-rm received from %s: type=%s", sender, tostring(data.type))

		-- SYNC-010: Critical debug for request mutations
		if data.type == "requests-log" then
			TOGBankClassic_Output:Debug("SYNC", "MERGE", "[SYNC-010] togbank-rm requests-log received from %s, about to call ReceiveRequestMutations", sender)
		end

		if data.type == "requests-index" then
			self:Debug("REQUESTS", "RECEIVE", ">", ColorPlayerName(sender), SHARES_COLOR, "requests index. We accept it by default.")
			TOGBankClassic_Guild:ReceiveRequestsIndex(data, sender)
		end
		if data.type == "requests-by-id" then
			local status = TOGBankClassic_Guild:ReceiveRequestsById(data)
			self:Debug(
				"REQUESTS",
				"RECEIVE",
				">",
				ColorPlayerName(sender),
				SHARES_COLOR,
				"requests by-id data. We accept it by default.",
				FormatSyncStatus(status)
			)
		end
		if data.type == "requests-log" then
			self:Debug("REQUESTS", "RECEIVE", ">", ColorPlayerName(sender), SHARES_COLOR, "request mutations. We accept by default.")
			TOGBankClassic_Guild:ReceiveRequestMutations(data, sender)
		end

		-- INV2 step 10 / the 2026-09-09 directive: THE SECOND INVENTORY RECEIVE PATH WAS HERE, and
		-- it is deleted along with `Guild:ReceiveAltData`, its only caller.
		--
		-- WHAT IT WAS: `data.type == "alt"` on the `togbank-rm` prefix, handing a link-bearing
		-- LEGACY alt payload to `ReceiveAltData`, which wrote `alt.items` / `alt.bank.items` /
		-- `alt.bags.items` straight from the wire. It never met the tuples-only guard on
		-- `togbank-d4`, so the no-backwards-compatibility directive was enforced on one inventory
		-- path and not the other -- a second way in, on the request-mutation channel.
		--
		-- VALIDATED AS UNFED BEFORE DELETING, so nobody re-derives this: the released v1.3.2
		-- (`4d8fe14`) sends alt inventory on `togbank-d4` (`Guild.lua:2697`) and its ONLY
		-- `togbank-rm` sender is `RequestLog.lua:1070`, request mutations. No shipped version sends
		-- inventory on this prefix. So this was dead code rather than the source of the operator's
		-- reported corruption -- that was INV2-ORDER-001 and HASH-CANON-002 -- and it is removed
		-- because a bypass that nothing currently drives is still a bypass.
		--
		-- THE REQUEST BRANCHES ABOVE ARE UNTOUCHED. `requests-index`, `requests-by-id` and
		-- `requests-log` are the request framework and share this prefix legitimately; only the
		-- inventory branch squatting alongside them is gone.
	end

	if prefix == "togbank-d4" then
		-- INV2 step 7b: a V2 tuple payload arrives on the SAME prefix and is recognised by SHAPE,
		-- not by a flag -- it is a positional array whose first element is the wire version, while
		-- a legacy delta is a map with named fields. Sniffing the shape is what lets a client that
		-- never learned to set a marker still be classified correctly.
		--
		-- RECEIVE IS NEVER GATED BY `sendV2Wire`. That switch governs emission only.
		--
		-- This used to say accepting BOTH formats was permanent mixed-version compatibility. That is
		-- superseded by the 2026-09-09 directive: the legacy link format is deleted in both
		-- directions and tuples are the only thing spoken here. The shape sniff below is therefore no
		-- longer a fork between two formats -- it is a guard that drops anything which is not a tuple
		-- payload, including an old client's delta.
		if TOGBankClassic_Inventory_Wire and TOGBankClassic_Inventory_Wire.isV2(data) then
			-- THE DELTA RELEASE step 3b: decode, authorise (never our own character -- MULTIPC-001;
			-- IsAltDataAllowed or a pending sync), order (HASH-CANON-001 rule 7) and store, in
			-- Inventory/Sync -- the same path an `inv-snapshot` on the host takes, so the manual
			-- GUILD share and the whispered reply cannot apply a payload differently. The ~200 lines
			-- that stood here are that function.
			TOGBankClassic_Inventory_Sync:ReceiveSnapshot(data, sender, #message)
			return
		end
		-- A payload we no longer speak. THIS LINE IS THE WHOLE DIAGNOSTIC for the commonest support
		-- question a mixed-version guild will produce -- "why can't I see their bank?" -- so it says
		-- WHO sent it and WHAT it was, and it says it at WARN rather than debug when the sender is a
		-- banker, because that is the case a player actually needs to act on.
		--
		-- Without this the old format is dropped in total silence, which is indistinguishable from
		-- the banker having no items, from the sync never being requested, and from a bug in the new
		-- path. Deleting a protocol is not a reason to stop reporting that someone is still speaking
		-- it.
		local staleType = type(data) == "table" and data.type or nil
		if staleType == "alt-delta" or staleType == "alt" then
			TOGBankClassic_Output:Debug("DELTA", "VALIDATE",
				"[INV2] discarded a legacy '%s' payload from %s for %s -- that client predates the " ..
				"tuple wire format and its data cannot be read. It will sync once they update.",
				tostring(staleType), tostring(sender), tostring(data.name))
			-- ONCE PER SENDER PER SESSION. The Warn above is user-visible and this branch is
			-- reached on EVERY legacy payload, not once per client -- an unmigrated banker
			-- re-broadcasts on every scan and every P2P answer, so an unlatched warning is a chat
			-- flood exactly when a guild is mid-migration and most bankers are still old. Measured
			-- against a real guild during the v1.4.0 rollout: 9 of 11 online clients unmigrated,
			-- several of them bankers.
			--
			-- Latched per NORMALIZED sender rather than per raw name, so "Bob" and "Bob-Realm"
			-- cannot each claim a warning for one person.
			--
			-- Session-scoped on purpose (a plain table, not SavedVariables): if a banker updates
			-- mid-session the latch is irrelevant, and if they have not updated by the next login
			-- the reminder is worth one more line.
			local normSender = TOGBankClassic_Guild:NormalizeName(sender)
			if normSender and TOGBankClassic_Guild:IsBank(normSender) then
				self.staleFormatWarned = self.staleFormatWarned or {}
				if not self.staleFormatWarned[normSender] then
					self.staleFormatWarned[normSender] = true
					TOGBankClassic_Output:Warn(
						"%s is running an older TOGBank and its bank contents cannot be read. " ..
						"Ask them to update.", tostring(sender))
				end
			end
			return
		end

		-- INV2 step 10 / the 2026-09-09 directive: the `alt-delta` RECEIVE branch was deleted here.
		--
		-- It accepted the legacy LINK format -- validate, ReconstructItemLinks over every added,
		-- modified and removed row, then ApplyDelta with its link-keyed identity and ITEM-003 ghost
		-- guards. That is the machinery the rework exists to remove, and keeping it to read
		-- unmigrated peers meant keeping all of it: the identity functions, the ghost guards and the
		-- reconstruction queue.
		--
		-- KNOWN COST, decided rather than discovered: an unmigrated peer's data is now IGNORED, not
		-- misread. A payload in the old format reaches this point, matches no branch, and is dropped
		-- silently -- which is the correct outcome for a format we no longer speak. Mixed-version
		-- guilds see nothing from un-upgraded bankers until they upgrade, and it heals by itself.
		--
		-- The tuple branch above is the only receive path. It has its own authorisation
		-- (IsAltDataAllowed, SEC-001), its own session completion and its own hash stamping.
	end

	-- togbank-ri: positional request index (v1). Separate prefix from togbank-rd.
	if prefix == "togbank-ri" then
		local liveCount  = tonumber(data[2]) or 0
		local tombCount  = data[2] and math.max(0, math.floor((#data - 2 - liveCount * 2) / 2)) or 0
		self:Debug("REQUESTS", "PROTO2", ">", ColorPlayerName(sender), SHARES_COLOR,
			string.format("requests index v1 (%d requests, %d tombstones).", liveCount, tombCount))
		TOGBankClassic_Guild:ReceiveRequestsIndexV1(data, sender)
	end

	-- togbank-rd2: positional single-record request data (v1).
	if prefix == "togbank-rd2" then
		local isTombstone = data[3] == false
		self:Debug("REQUESTS", "PROTO2", ">", ColorPlayerName(sender), SHARES_COLOR,
			isTombstone and "request tombstone v1." or "request record v1.")
		TOGBankClassic_Guild:ReceiveRequestsByIdV1(data)
	end

	if prefix == "togbank-rd" then
		TOGBankClassic_Output:Debug("COMMS", "RECEIVE", "[SYNC-003p] togbank-rd received from %s: type=%s", sender, tostring(data.type))

		if data.type == "requests-index" then
			local reqCount = data.requests and #data.requests or 0
			local tombCount = data.tombstones and #data.tombstones or 0
			self:Debug("REQUESTS", "RECEIVE", ">", ColorPlayerName(sender), SHARES_COLOR,
				string.format("requests index (%d requests, %d tombstones).", reqCount, tombCount))
			TOGBankClassic_Guild:ReceiveRequestsIndex(data, sender)
		end
		if data.type == "requests-by-id" then
			local status = TOGBankClassic_Guild:ReceiveRequestsById(data)
			self:Debug(
				"REQUESTS",
				"RECEIVE",
				">",
				ColorPlayerName(sender),
				SHARES_COLOR,
				"requests by-id data.",
				FormatSyncStatus(status)
			)
		end
		if data.type == "requests-log" then
			self:Debug("REQUESTS", "RECEIVE", ">", ColorPlayerName(sender), SHARES_COLOR, "request mutations.")
			TOGBankClassic_Guild:ReceiveRequestMutations(data, sender)
		end
	end

	if prefix == "togbank-hl" then
		-- P2P-035: the numbered broadcast. Decoded AT THE DOOR into the same `alts` summary table the
		-- keyed broadcast carried, so everything downstream (offer building, the advertised-hash
		-- cache, the tab colour) is one path. A number we cannot name is skipped and, because the
		-- sender's table version rides with it, triggers a request for the table.
		if data.type == "hlb2" then
			-- WIRE-SKEW-001: the broadcast names the sender's addon version; the data-leg gate reads it.
			if TOGBankClassic_Guild.NotePeerAddonVersion then
				TOGBankClassic_Guild:NotePeerAddonVersion(sender, data.addon)
			end
			local BN = TOGBankClassic_BankerNumbers
			if BN then
				BN:OnAdvertisedVersion(sender, data.v)
				local entries = BN:DecodeEntries(data.e)
				local alts, unknown = BN:EntriesToAlts(entries)
				if unknown > 0 then
					TOGBankClassic_Output:Debug("P2P", "BROADCAST", "hlb2 from %s: %d entries name banker numbers this client does not hold (numbers v%s vs ours v%d)",
						tostring(sender), unknown, tostring(data.v), BN:Version())
				end
				data.alts = alts
				data.type = "hash-list-broadcast"
				-- N6: marks this as the NUMBERED wire re-typed for the shared path below, so the
				-- legacyKeyedReceive gate on that path never applies to it.
				data.fromNumbered = true
			end
		end
		-- N6: the KEYED forms only old-build (<= v1.4.0) peers send. Off by default; see Switches.lua.
		local acceptKeyed = TOGBankClassic_Switches and TOGBankClassic_Switches:IsEnabled("legacyKeyedReceive")
		if (data.type == "hash-list-broadcast" and not data.fromNumbered or data.type == "hash-offer") and not acceptKeyed then
			TOGBankClassic_Output:Debug("P2P", "BROADCAST", "N6: ignoring keyed %s from %s (legacyKeyedReceive is off)",
				tostring(data.type), tostring(sender))
			return
		end
		if data.type == "hash-list-request" then
			local replyTarget = data.requester or sender
			TOGBankClassic_Output:Debug("PROTOCOL", "HL", "HL request from %s (replyTarget=%s)", tostring(sender), tostring(replyTarget))
			TOGBankClassic_Guild:SendHashList(replyTarget)
		elseif data.type == "numbers-request" then
			if TOGBankClassic_BankerNumbers then TOGBankClassic_BankerNumbers:HandleRequest(sender) end
			return
		elseif data.type == "numbers-reply" then
			if TOGBankClassic_BankerNumbers then TOGBankClassic_BankerNumbers:HandleReply(sender, data.numbers) end
			return
		elseif data.type == "hash-offer2" then
			-- P2P-035: "I have newer for these" as bare banker numbers -- one chunk, no version. The
			-- version is established by the query step before anything is requested (P2PSession).
			local BN = TOGBankClassic_BankerNumbers
			if BN and TOGBankClassic_P2PSession then
				BN:OnAdvertisedVersion(sender, data.v)
				local alts, unknown = {}, 0
				for _, num in ipairs(BN:DecodeNumbers(data.n)) do
					local name = BN:NameOf(num)
					if name then alts[name] = {} else unknown = unknown + 1 end
				end
				TOGBankClassic_Output:Debug("P2P", "OFFER", "hash-offer2 from %s: %d banker(s)%s", tostring(sender),
					#BN:DecodeNumbers(data.n), unknown > 0 and string.format(" (%d unknown numbers)", unknown) or "")
				TOGBankClassic_P2PSession:OnOffer(sender, alts)
			end
			return
		elseif data.type == "hash-list-broadcast" and data.alts then
			-- PERF-020: Queue hash broadcasts for batched processing to prevent stuttering
			-- When 4+ broadcasts arrive within seconds (144 hash comparisons), synchronous
			-- processing blocks main thread causing stuttering. Batch with 0.15s delay spreads
			-- work across multiple frames while adding negligible latency (0.25% of 60s collect window).
			local isSenderBanker = data.isBanker or false
			local altCount = 0
			for _ in pairs(data.alts) do altCount = altCount + 1 end
			TOGBankClassic_Output:Debug("P2P", "BROADCAST", "HL broadcast from %s (alts=%d, isBanker=%s)",
				tostring(sender), altCount, tostring(isSenderBanker))

			-- Queue this broadcast for batched processing
			table.insert(self.hashBroadcastQueue, {
				sender = sender,
				data = data,
				distribution = distribution,
				isSenderBanker = isSenderBanker,
				altCount = altCount,
			})

			-- Start batch timer if not already running
			--
			-- TIMER-002: this handle is a LATCH ("is a batch already scheduled?"), not a
			-- cancellation handle, and that makes the C_Timer.After bug bite the opposite way.
			-- After returns nothing, so the latch was always nil, so `if not ...` was always
			-- TRUE -- and every queued broadcast started ANOTHER batch timer. The batching did
			-- not batch: N queued broadcasts armed N timers and logged "Started batch timer" N
			-- times, which is precisely the coalescing this code exists to do.
			--
			-- CLEARING IT IN THE CALLBACK IS REQUIRED, not tidiness. Nothing else resets it
			-- between batches (only Init and the module reset do), so with a real handle the
			-- latch would stay set after the first fire and no further batch would EVER be
			-- scheduled -- turning a broken batcher into a silently stalled one. Swapping to
			-- NewTimer without this line is worse than leaving the bug.
			if not self.hashBroadcastTimer then
				self.hashBroadcastTimer = C_Timer.NewTimer(self.HASH_BROADCAST_BATCH_DELAY, function()
					TOGBankClassic_Chat.hashBroadcastTimer = nil
					TOGBankClassic_Chat:ProcessQueuedHashBroadcasts()
				end)
				TOGBankClassic_Output:Debug("P2P", "OFFER", "Started batch timer (%ds) for hash broadcasts", self.HASH_BROADCAST_BATCH_DELAY)
			end
			return
		elseif data.type == "hash-offer" and data.alts then
			-- P2P-006: A peer is signalling it has newer data for some of our alts.
			-- Feed into the session manager collect window so Dispatch() can pick it up.
			if TOGBankClassic_P2PSession then
				TOGBankClassic_P2PSession:OnOffer(sender, data.alts)
			end
			return
		elseif data.type == "alt-request" then
			-- PERF-006: P2P broadcast on togbank-hl channel (modern code only)
			-- Process exactly the same as togbank-r alt-request, but only modern peers see this
			TOGBankClassic_Output:Debug("PROTOCOL", "ALT-REQUEST", "P2P alt-request from %s for %s (expectedHash=%s)",
				tostring(sender), tostring(data.name), tostring(data.expectedHash))
			-- Forward to togbank-r handler by recursively calling OnCommReceived
			self:OnCommReceived("togbank-r", message, distribution, sender)
			return
		-- SYNC-013: share/wipe/roster migrated from dead prefixes onto togbank-hl type dispatch
		elseif data.type == "share-request" then
			-- PERF-021: Defer share replies during zone-in cooldown
			if TOGBankClassic_Events.zoningCooldown then
				TOGBankClassic_Output:Debug("EVENTS", "TIMER", "Share reply deferred (zone-in cooldown active)")
				return
			end
			TOGBankClassic_Guild:Share("reply")
			local now = GetServerTime()
			if not self.last_share_sync or now - self.last_share_sync > 30 then
				self.last_share_sync = now
			end
		elseif data.type == "wipe-command" then
			TOGBankClassic_Guild:Wipe("reply")
		-- SETTINGS-001: Receive and apply guild-wide settings broadcast from an authorized sender
		elseif data.type == "guild-settings" then
			if data.settings then
				TOGBankClassic_Guild:ApplyRemoteSettings(sender, data.settings)
			end
		end
	end
	if prefix == "togbank-hlr" then
		-- WIRE-SKEW-008 (self-audit): the reply's claims are refused by every Note* below, but the
		-- SECOND PASS of this handler turned them into one BroadcastP2PRequest per alt -- a guild
		-- broadcast each, on the strength of an old release's fabricated publish times, which is the
		-- fast-fill burst behind the pull-path ACK storm. Nothing in a reply we cannot act on is
		-- worth acting on; one line, and the whole handler is skipped.
		if data.type == "hash-list-reply" and not TOGBankClassic_Guild:ClaimantCanServe(sender) then
			TOGBankClassic_Output:Debug("PROTOCOL", "HLR", "HLR from %s ignored: release %s is before the data leg changed",
				tostring(sender), tostring(select(2, TOGBankClassic_Guild:PeerSpeaksDataLeg(sender))))
			return
		end
		if data.type == "hash-list-reply" and data.alts then
			local altCount = 0
			for _ in pairs(data.alts) do
				altCount = altCount + 1
			end
			TOGBankClassic_Output:Debug("PROTOCOL", "HLR-COMPARE", "HLR received from %s (alts=%d)", tostring(sender), altCount)
			-- HASH-CACHE-001: every entry goes through the ONE writer, which applies the operator's
			-- rule -- the newer V2 hash wins, a revision-1-only claim never displaces a V2 one, and
			-- nothing a peer says about OUR OWN character is accepted. This used to be an
			-- unconditional `latestBankerHashes[norm] = summary`: last writer won, so a stale relayer's
			-- mutated number replaced the author's canon, the tab went red and the client re-requested
			-- from a peer whose data it cannot read. Reported from a live guild.
			for altName, summary in pairs(data.alts) do
				local norm = TOGBankClassic_Guild:NormalizeName(altName)
				if norm and summary then
					TOGBankClassic_Guild:CanonicaliseSummary(summary)                -- HASH-CANON-005
					TOGBankClassic_Guild:NoteAdvertisedHashes(norm, summary, sender)
					TOGBankClassic_Guild:NoteAdvertisedPublishTime(norm, summary, sender)   -- TABCOLOUR-002
					-- MULTIPC-002: the replier can serve every version it lists -- our own included.
					if norm == TOGBankClassic_Guild:GetNormalizedPlayer() then
						TOGBankClassic_Guild:NoteSelfHolder(summary.hashV2, sender)
					end
				end
			end
			local localAlts = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts or {}
			local pending = {}
			local totalCount = 0

			-- First pass: Store banker's authoritative hashes locally if we don't have them
			if TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts then
				-- HLR-CRASH-001: the reply is trusted to seed a stub when it comes FROM A BANKER. This
				-- used to read `data.isBanker`, a field the reply has never carried (SendHashList
				-- builds { type, alts, banker } and nothing else), so the stub branch was dead and
				-- the `elseif` below indexed `localAlt.mailHash` on a nil localAlt -- a hard error
				-- on the first reply naming an alt this client had never seen, which aborted the
				-- whole handler before the request pass ran. A fresh or freshly-wiped client with a
				-- banker online therefore errored at login and never asked for anything. Found by
				-- driving the real receive path; the sender's identity is server-supplied, so it is
				-- the honest form of "is this a banker's reply".
				local normSender = TOGBankClassic_Guild:NormalizeName(sender)
				local fromBanker = normSender and TOGBankClassic_Guild:IsBank(normSender) or false
				local me = TOGBankClassic_Guild:GetNormalizedPlayer()
				for altName, summary in pairs(data.alts) do
					local norm = TOGBankClassic_Guild:NormalizeName(altName)
					local localAlt = localAlts[norm]
					local localHash = localAlt and localAlt.inventoryHash or 0

					if summary and summary.hash and summary.hash > 0 then
						-- MULTIPC-001: NO STUB FOR OUR OWN CHARACTER. A stub exists "so there is something
						-- to sync into", and nothing is ever synced into our own name. Worse, it would
						-- carry the PEER'S canon as if this PC held that version: a wiped PC on a shared
						-- account would then read as current and publish a bags-only scan over the real
						-- copy. With no record it reads as behind, and Bank:Scan holds publishing until
						-- the vault and mailbox have been read here.
						if not localAlt and fromBanker and TOGBankClassic_Guild:IsBank(norm) and norm ~= me then
							-- Create stub entry with banker's authoritative hash (only trusted banker replies).
							-- Both revisions together, or neither -- the rule the delivery path follows.
							-- INV2-RETIRE-003: metadata only, no legacy item arrays (see the roster stub
							-- in Guild:RebuildBankerRoster for the same shape and why).
							TOGBankClassic_Guild.Info.alts[norm] = {
								name = norm,
								version = summary.version or 0,
								money = 0,
								inventoryHash = summary.hash,
								inventoryHashV2 = summary.hashV2,
								inventoryUpdatedAt = summary.updatedAt,
								mail = { slots = { count = 0, total = 0 }, lastScan = 0, version = 0 },
								mailHash = summary.mailHash or 0,
							}
							TOGBankClassic_Output:Debug("PROTOCOL", "HLR", "HLR: Stored banker hash for new alt %s: hash=%08x, mailHash=%08x, updatedAt=%s", norm, summary.hash, summary.mailHash or 0, tostring(summary.updatedAt))
						elseif localAlt and (localHash ~= summary.hash or (localAlt.mailHash or 0) ~= (summary.mailHash or 0)) then
							-- Hash mismatch detected - banker has different hash than our local data
							-- DO NOT update local hash here - it will be updated when we receive and apply the delta
							-- Second pass will detect this mismatch and trigger a delta sync request
							TOGBankClassic_Output:Debug("PROTOCOL", "HLR-COMPARE", "HLR: Hash mismatch detected for %s - local inv=%d/mail=%d vs banker inv=%d/mail=%d (delta sync needed)",
								norm, localHash, localAlt.mailHash or 0, summary.hash, summary.mailHash or 0)
						end
					end
				end
			-- Refresh localAlts reference after potentially creating new entries
			localAlts = TOGBankClassic_Guild.Info.alts
		end

		-- Second pass: Compare hashes and categorize alts
		local currentPlayer = TOGBankClassic_Guild:GetNormalizedPlayer()
		for altName, summary in pairs(data.alts) do
				local norm = TOGBankClassic_Guild:NormalizeName(altName)

				-- Skip current player and alts not in the current guild banker roster.
				-- Prevents stale ex-banker entries from triggering sync requests.
				if norm ~= currentPlayer and TOGBankClassic_Guild:IsBank(norm) then
					local localAlt = localAlts and localAlts[norm]
					totalCount = totalCount + 1
					-- P2P-034: ONE question, the same one an offer is judged by -- can this claim
					-- improve what we hold? This used to be HashesAgreeWith (equality) plus a
					-- has-content check, three branches deep: any DIFFERENT version was requested,
					-- including older canons and canon-less revision-1 copies of banks we held current.
					-- Read off a live viewer: 26 guild broadcasts from one reply, all timed out. The
					-- "hash matches but no content" case is inside "no data" now; HASH-CANON-006 (held
					-- copy, no canon, banker has one -> ask) is the "canon" reason.
					local improves, why = TOGBankClassic_Guild:AdvertisedImproves(norm, summary)
					TOGBankClassic_Output:Debug("PROTOCOL", "HLR-COMPARE",
						"HLR check: %s -> %s (%s; local canon=%s banker canon=%s local inv=%s banker inv=%s)",
						tostring(norm), improves and "REQUEST" or "skip", why,
						tostring(localAlt and localAlt.inventoryHashV2), tostring(summary.hashV2),
						tostring(localAlt and localAlt.inventoryHash), tostring(summary.hash))
					if improves then
						pending[norm] = summary
					end
				else
					TOGBankClassic_Output:Debug("PROTOCOL", "HLR", "HLR: Skipping %s (current player)", tostring(norm))
				end
			end

			local pendingCount = 0
			for _ in pairs(pending) do
				pendingCount = pendingCount + 1
			end
			TOGBankClassic_Output:Debug(
				"PROTOCOL",
				"HLR-COMPARE",
				"HLR compare complete: total=%d pending=%d",
				totalCount,
				pendingCount
			)
			if pendingCount > 0 then
				local haveCount, bankerTotal = TOGBankClassic_Guild:GetBankerDataProgress()
				TOGBankClassic_Output:Debug("DELTA", "FAST-FILL", "Fast-fill: Requesting %d missing alts (have %d/%d)", pendingCount, haveCount, bankerTotal)
				TOGBankClassic_Guild:ReportBankerDataProgress("fast-fill", true)
			end

			for altName, summary in pairs(pending) do
				TOGBankClassic_Output:Debug(
					"PROTOCOL",
					"HLR-COMPARE",
					"HLR broadcast pending: %s (hash=%s, updatedAt=%s)",
					tostring(altName),
					tostring(summary and summary.hash),
					tostring(summary and summary.updatedAt)
				)
				if summary.hash then
					TOGBankClassic_Guild:BroadcastP2PRequest(altName, summary.hash, summary.updatedAt, sender, summary.hashV2)
				else
					-- BroadcastP2PRequest cannot ask for an alt without a revision-1 hash to expect.
					TOGBankClassic_Output:Debug("PROTOCOL", "HLR-COMPARE",
						"HLR pending no hash: %s - scheduling catch-up", tostring(altName))
					TOGBankClassic_P2PSession:ScheduleCatchUp("hlr_missing_hash")
				end
			end
		end
	end
end

-- Help text color codes
local HELP_COLOR = {
	HEADER = "|cff33ff99",
	COMMAND = "|cffe6cc80",
	RESET = "|r",
}

--- A canon as the dev commands print it: `<date time> <checksum>` when the publish time is readable,
--- the raw value for a v1.4.0 numeric canon (no readable date -- shown as what it is), and "-" for
--- nil so a missing canon cannot be mistaken for 0. ONE spelling, shared by hashdump and trace.
local function canonStr(c)
	if c == nil then return "-" end
	local at = TOGBankClassic_DeltaComms and TOGBankClassic_DeltaComms:CanonPublishTime(c)
	if at then
		return string.format("%s %s", date("%Y-%m-%d %H:%M:%S", at), tostring(c):sub(11))
	end
	return tostring(c)
end

-- Command registry: name, usage, help, expert, handler
-- Commands are displayed in help in the order they appear here.
-- Set help = nil to hide from help output.
local COMMAND_REGISTRY = {
	-- Basic commands
	{
		name = "help",
		help = "this message",
		handler = function()
			TOGBankClassic_Chat:ShowHelp()
		end,
	},
	{
		name = "version",
		help = "display the TOG Bank version",
		handler = function()
			-- BRAND-001 / VERSION-TEXT-001: what a window title says, said the same way here. This
			-- printed the raw tag under the old name -- "TOGBankClassic version:
			-- TOGBankClassic-v1.5.0" beside a title reading "TOG Bank v1.5.0".
			TOGBankClassic_Output:Response(TOGBankClassic_Constants.BrandVersion())
		end,
	},
	{
		-- MAILUI-001: opens by itself for bankers at a mailbox; this is for everyone else, and for
		-- re-opening it after closing it while the mailbox is still open.
		name = "mailbox",
		help = "open the Mailbox window: every attachment in your inbox as a row, with a filter and Take buttons (needs an open mailbox)",
		handler = function()
			if not (TOGBankClassic_Mail and TOGBankClassic_Mail:IsMailboxOpen()) then
				TOGBankClassic_Output:Response("Open a mailbox first -- the Mailbox window reads the live inbox.")
				return
			end
			TOGBankClassic_UI_Mailbox:Toggle()
		end,
	},
	{
		-- ENTRY-001 (operator 2026-09-13: "make the MMB open the new UI and browse open the legacy
		-- ui", then "rename it from togbank browse to togbank legacy"): the minimap click is the
		-- Guild Bank window now, and this command is the old tab-per-banker Inventory window, kept
		-- only until BROWSE-002 follow-on (d) retires it. (BROWSE-001 had `browse` opening the new
		-- window while it settled; that name is gone.)
		name = "legacy",
		help = "open the old Inventory window (a tab per bank character); the minimap button opens the Guild Bank window",
		handler = function()
			TOGBankClassic_UI_Inventory:Toggle()
		end,
	},
	{
		name = "sync",
		help = "manually receive the latest data from other online users with guild bank data; this is done every 10 minutes automatically",
		handler = function()
			TOGBankClassic_Chat:PerformSync()
		end,
	},
	{
		name = "share",
		help = "manually share the contents of your guild bank with other online users of TOGBankClassic; this is done every 10 minutes automatically and whenever you open the Inventory window",
		handler = function()
			-- PERF-021: Warn user if zone-in cooldown is active
			if TOGBankClassic_Events.zoningCooldown then
				TOGBankClassic_Output:Response("Zone-in cooldown active, deferring share for 2.5s...")
				C_Timer.After(2.6, function()
					TOGBankClassic_Bank:OnUpdateStart()
					TOGBankClassic_Bank:OnUpdateStop()
					TOGBankClassic_Guild:Share()
				end)
				return
			end
			TOGBankClassic_Bank:OnUpdateStart()
			TOGBankClassic_Bank:OnUpdateStop()
			TOGBankClassic_Output:Response("Broadcasting mail and inventory hashes to guild.")
			TOGBankClassic_Guild:Share()
		end,
	},
	{
		name = "hashupdate",
		help = "(banker only) broadcast hash-list for ALL bank alts to force guild-wide hash refresh",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:HashUpdate()
		end,
	},
	{
		name = "reset",
		help = "reset your own TOGBankClassic database",
		handler = function()
			local guild = TOGBankClassic_Guild:GetGuild()
			if not guild then
				return
			end
			TOGBankClassic_Guild:Reset(guild)
		end,
	},
	-- Expert commands (alphabetically sorted)
	{
		name = "clearhistory",
		help = "clear delta chain history (removes saved deltas)",
		expert = true,
		handler = function()
			local guild = TOGBankClassic_Guild:GetGuild()
			if not guild then
				TOGBankClassic_Output:Response("Not in a guild")
				return
			end
			local db = TOGBankClassic_Database.db.faction[guild]
			if db and db.deltaHistory then
				local count = 0
				for _, deltas in pairs(db.deltaHistory) do
					if type(deltas) == "table" then
						count = count + #deltas
					end
				end
				db.deltaHistory = {}
				TOGBankClassic_Output:Response("Cleared %d delta(s) from history", count)
			else
				TOGBankClassic_Output:Response("No delta history to clear")
			end
		end,
	},
	-- INV2-RETIRE-002: `/togbank dev clearsnapshots` was deleted here. It cleared `db.deltaSnapshots`,
	-- the SavedVariables key PERF-012 stopped writing and Database:Init nils on every load -- so it
	-- has printed "No snapshots to clear" since v1.2, and the in-memory cache it was meant to reach
	-- is gone with the legacy alt-delta (see the header of Modules/Database.lua).
	{
		name = "compact",
		help = "manually run compaction to prune old requests and tombstones",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:Compact()
		end,
	},
	{
		name = "reqscan",
		help = "scan done requests and report why expired ones are not being pruned",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:ReqScan()
		end,
	},
	{
		name = "deltaerrors",
		help = "show recent delta sync errors and failure counts",
		expert = true,
		handler = function()
			TOGBankClassic_Chat:PrintDeltaErrors()
		end,
	},
	{
		name = "clear-delta-errors",
		help = "clear all recorded delta sync errors (DELTA-011 cleanup)",
		expert = true,
		handler = function()
			local guild = TOGBankClassic_Guild:GetGuild()
			if not guild then
				TOGBankClassic_Output:Response("Not in a guild")
				return
			end

			local db = TOGBankClassic_Database.db.faction[guild]
			if db and db.deltaErrors then
				db.deltaErrors.lastErrors = {}
				db.deltaErrors.failureCounts = {}
				db.deltaErrors.notifiedAlts = {}
				TOGBankClassic_Output:Response("Cleared all delta sync errors")
			else
				TOGBankClassic_Output:Response("No delta errors to clear")
			end
		end,
	},
	{
		name = "deltahistory",
		help = "show stored delta chain history for offline recovery",
		expert = true,
		handler = function()
			TOGBankClassic_Chat:PrintDeltaHistory()
		end,
	},
	{
		name = "deltastats",
		help = "show delta sync statistics and bandwidth savings",
		expert = true,
		handler = function()
			TOGBankClassic_Chat:PrintDeltaStats()
		end,
	},
	{
		name = "debuglog",
		usage = "[N] [filter]",
		help = "export last N debug log entries (default 500), optionally filtered by keyword",
		expert = true,
		handler = function(arg1)
			local args = tostring(arg1 or ""):trim()
			local count, filter = 500, nil

			-- Parse arguments: first is count, rest is filter
			if args ~= "" then
				local firstSpace = args:find(" ")
				if firstSpace then
					count = tonumber(args:sub(1, firstSpace - 1)) or 500
					filter = args:sub(firstSpace + 1):trim()
					if filter == "" then filter = nil end
				else
					count = tonumber(args) or 500
				end
			end

			local log, matchCount = TOGBankClassic_Output:ExportPersistentLogCompact(count, filter)
			if log == "" then
				TOGBankClassic_Output:Response("No debug log entries found")
			else
				if filter then
					TOGBankClassic_Output:Response("Last %d debug log entries (filtered: '%s', %d matches):", count, filter, matchCount)
				else
					TOGBankClassic_Output:Response("Last %d debug log entries:", count)
				end
				TOGBankClassic_Output:Response(log)
			end
		end,
	},
	{
		name = "debuglogclear",
		help = "clear all persistent debug log entries",
		expert = true,
		handler = function()
			TOGBankClassic_Output:ClearPersistentLog()
			TOGBankClassic_Output:Response("Debug log cleared")
		end,
	},
	{
		name = "debuglogsave",
		help = "manually save debug log to SavedVariables (normally done on logout)",
		expert = true,
		handler = function()
			TOGBankClassic_Output:SavePersistentLog()
			TOGBankClassic_Output:Response("Persistent debug log saved")
		end,
	},
	{
		name = "debuglogstats",
		help = "show statistics about the persistent debug log",
		expert = true,
		handler = function()
			local count = #TOGBankClassic_Output.persistentLog
			if count == 0 then
				TOGBankClassic_Output:Response("No debug log entries")
				return
			end

			local oldest = TOGBankClassic_Output.persistentLog[1]
			local newest = TOGBankClassic_Output.persistentLog[count]
			local oldestTime = date("%Y-%m-%d %H:%M:%S", oldest.timestamp)
			local newestTime = date("%Y-%m-%d %H:%M:%S", newest.timestamp)
			local ageSeconds = newest.timestamp - oldest.timestamp
			local ageDays = ageSeconds / 86400

			TOGBankClassic_Output:Response("Debug log: %d entries", count)
			TOGBankClassic_Output:Response("Oldest: %s", oldestTime)
			TOGBankClassic_Output:Response("Newest: %s", newestTime)
			TOGBankClassic_Output:Response("Span: %.1f days", ageDays)
			TOGBankClassic_Output:Response("Max entries: %d", TOGBankClassic_Output.persistentLogMaxEntries)
			TOGBankClassic_Output:Response("Max age: %d days", TOGBankClassic_Output.persistentLogMaxAge / 86400)
		end,
	},
	{
		name = "debugtab",
		help = "create a dedicated chat tab for debug output",
		expert = true,
		handler = function()
			if TOGBankClassic_Output:CreateDebugTab() then
				local Out = TOGBankClassic_Output
				-- DEV-UX-002: this used to say "Debug output will now appear in 'TOGBank Debug'
				-- tab" unconditionally. That is FALSE in the default state and it is the state
				-- every first-time user is in: the tab is only the fourth of four gates, and the
				-- two before it (log level, and at least one opt-in category) are both off by
				-- default. So the addon confidently reported success and then produced nothing,
				-- which reads as a broken tab rather than as an unset switch -- the same
				-- "confident confirmation for something that cannot work" class as DEV-UX-001.
				-- Report the gates that are actually shut instead of claiming the outcome.
				local levelOn = Out:GetLevel() == LOG_LEVEL.DEBUG
				local enabled = {}
				for name in pairs(DEBUG_CATEGORY) do
					if Out:IsCategoryEnabled(name) then enabled[#enabled + 1] = name end
				end
				table.sort(enabled)

				Out:Response("'TOGBank Debug' tab is ready.")
				if levelOn and #enabled > 0 then
					Out:Response("Debug output |cff44ff44IS|r flowing to it. Categories on: |cffffff00%s|r",
						table.concat(enabled, ", "))
					return
				end

				Out:Response("|cffff8800Nothing will appear in it yet.|r Two switches feed the tab:")
				if not levelOn then
					Out:Response("  |cffff4444OFF|r  log level - turn it on with |cffffff00/togbank debug|r")
				else
					Out:Response("  |cff44ff44ON |r  log level")
				end
				if #enabled == 0 then
					Out:Response("  |cffff4444OFF|r  every category - turn one on with |cffffff00/togbank debug only <CATEGORY>|r")
					Out:Response("      |cff888888/togbank debug list shows them all.|r")
				else
					Out:Response("  |cff44ff44ON |r  categories: |cffffff00%s|r", table.concat(enabled, ", "))
				end
			end
		end,
	},
	{
		name = "debugtabremove",
		help = "remove the TOGBank Debug chat tab",
		expert = true,
		handler = function()
			TOGBankClassic_Output:RemoveDebugTab()
		end,
	},
	{
		name = "forcedelta",
		help = "force delta sync mode (on|off) - bypass thresholds for testing",
		expert = true,
		handler = function(arg)
			if arg == "on" then
				FEATURES.FORCE_DELTA_SYNC = true
				FEATURES.FORCE_FULL_SYNC = false
				TOGBankClassic_Output:Response("Force delta sync: ENABLED (will always use delta)")
			elseif arg == "off" then
				FEATURES.FORCE_DELTA_SYNC = false
				TOGBankClassic_Output:Response("Force delta sync: DISABLED (normal behavior)")
			else
				local status = FEATURES.FORCE_DELTA_SYNC and "ON" or "OFF"
				TOGBankClassic_Output:Response("Force delta sync: %s", status)
				TOGBankClassic_Output:Response("Usage: /togbank forcedelta [on|off]")
			end
		end,
	},
	{
		name = "forcefull",
		help = "force full sync mode (on|off) - disable delta for testing",
		expert = true,
		handler = function(arg)
			if arg == "on" then
				FEATURES.FORCE_FULL_SYNC = true
				FEATURES.FORCE_DELTA_SYNC = false
				TOGBankClassic_Output:Response("Force full sync: ENABLED (will never use delta)")
			elseif arg == "off" then
				FEATURES.FORCE_FULL_SYNC = false
				TOGBankClassic_Output:Response("Force full sync: DISABLED (normal behavior)")
			else
				local status = FEATURES.FORCE_FULL_SYNC and "ON" or "OFF"
				TOGBankClassic_Output:Response("Force full sync: %s", status)
				TOGBankClassic_Output:Response("Usage: /togbank forcefull [on|off]")
			end
		end,
	},
	{
		name = "perfstats",
		help = "show performance metrics for current session",
		expert = true,
		handler = function()
			TOGBankClassic_Performance:PrintReport()
		end,
	},
	{
		name = "persistcheck",
		help = "check current request persistence state (for debugging SYNC-001)",
		expert = true,
		handler = function()
			local G = TOGBankClassic_Guild
			if not G or not G.Info then
				TOGBankClassic_Output:Response("Guild info not loaded")
				return
			end

			local logCount = #(G.Info.requestLog or {})
			local appliedCount = 0
			local appliedActors = {}
			if G.Info.requestLogApplied then
				for actor, seq in pairs(G.Info.requestLogApplied) do
					appliedCount = appliedCount + 1
					table.insert(appliedActors, string.format("%s=%d", actor, seq))
				end
			end
			local requestCount = (function()
				local n = 0
				for _ in pairs(G.Info.requests or {}) do n = n + 1 end
				return n
			end)()
			local seqCount = 0
			if G.Info.requestLogSeq then
				for _ in pairs(G.Info.requestLogSeq) do
					seqCount = seqCount + 1
				end
			end

			TOGBankClassic_Output:Response("=== Request Persistence State ===")
			TOGBankClassic_Output:Response("requests: %d items", requestCount)
			TOGBankClassic_Output:Response("requestLog: %d entries", logCount)
			TOGBankClassic_Output:Response("requestLogApplied: %d actors", appliedCount)
			if appliedCount > 0 then
				TOGBankClassic_Output:Response("  %s", table.concat(appliedActors, ", "))
			end
			TOGBankClassic_Output:Response("requestLogSeq: %d actors", seqCount)

			-- Check if data is referencing SavedVariables
			local db = TOGBankClassic_Database and TOGBankClassic_Database.db
			if db and db.faction then
				local guildName = G:GetGuild()
				if guildName and db.faction[guildName] then
					local isSameRef = (G.Info == db.faction[guildName])
					TOGBankClassic_Output:Response("Guild.Info %s SavedVariables reference",
						isSameRef and "IS" or "IS NOT")
				end
			end
		end,
	},
	{
		name = "protocol",
		help = "show protocol version distribution across guild members",
		expert = true,
		handler = function()
			TOGBankClassic_Chat:PrintProtocolInfo()
		end,
	},
	{
		name = "resetmetrics",
		help = "reset delta sync statistics and metrics",
		expert = true,
		handler = function()
			local guild = TOGBankClassic_Guild:GetGuild()
			if not guild then
				TOGBankClassic_Output:Response("Not in a guild")
				return
			end
			if TOGBankClassic_Database:ResetDeltaMetrics(guild) then
				TOGBankClassic_Output:Response("Delta metrics reset")
			else
				TOGBankClassic_Output:Response("Failed to reset metrics")
			end
		end,
	},
	{
		name = "roster",
		help = "print the list of known guild bank characters from your local guild notes",
		handler = function()
			local banks = TOGBankClassic_Guild:GetBanks()
			if not banks or #banks == 0 then
				TOGBankClassic_Output:Response("No guild bank characters found (no 'gbank' in public or officer notes).")
				return
			end
			-- P2P-035: the number beside each banker, and the table version every client should agree on.
			local BN = TOGBankClassic_BankerNumbers
			TOGBankClassic_Output:Response("Guild bank characters (%d), banker numbers v%d:", #banks, BN and BN:Version() or 0)
			-- By number, unnumbered last: the print is the table, so it reads as one.
			local rows = {}
			for _, name in ipairs(banks) do
				rows[#rows + 1] = { num = BN and BN:NumberOf(name), name = name }
			end
			table.sort(rows, function(a, b)
				if (a.num ~= nil) ~= (b.num ~= nil) then return a.num ~= nil end
				if a.num ~= b.num then return (a.num or "") < (b.num or "") end
				return a.name < b.name
			end)
			for _, r in ipairs(rows) do
				TOGBankClassic_Output:Response("  %s  %s", r.num or "----", r.name)
			end
		end,
	},
	-- INV2 step 10: the `/togbank test` command and `Modules/Tests.lua` behind it were deleted. That
	-- harness ran ComputeDelta, ApplyDelta, ComputeItemDelta, ItemsEqual, GetChangedFields and
	-- ValidateDeltaStructure against hand-built fixtures -- every one of which is now gone with the
	-- link protocol, so the file would have been a shell of setup around nothing.
	--
	-- The offline busted suite replaced it and is not a like-for-like substitute but a better one:
	-- it runs on every change rather than when someone remembers to type a slash command, it drives
	-- the REAL Ace libraries and the real serialiser, and it is what found the defects this rework
	-- is built on. Run it from the addon root with `busted`, or through writ's `test`.
	{
		name = "versioncheck",
		help = "broadcast version request to guild via VersionCheck-1.0 and print responses after collection window",
		expert = true,
		handler = function()
			local VC = LibStub and LibStub:GetLibrary("VersionCheck-1.0", true)
			if not VC then
				TOGBankClassic_Output:Response("VersionCheck-1.0 library not available")
				return
			end
			local hostEntry = VC.hosts and VC.hosts["TOGBankClassic"]
			if not hostEntry then
				TOGBankClassic_Output:Response("TOGBankClassic not registered with VersionCheck-1.0")
				return
			end
			-- FireBatch resets VersionResponses and VersionCheckActive, then broadcasts VC10_REQ to guild.
			-- Peers respond via whisper (VC10_RSP) with up to 8s jitter; VC collects for 12s.
			-- We wait 21s to be sure we capture all responses before reading.
			VC:FireBatch()
			TOGBankClassic_Output:Response("Version check broadcast sent — waiting 21 seconds for responses...")
			C_Timer.After(21, function()
				-- VERSION-TEXT-001: our own row reads like the title bar. The OTHER rows below stay
				-- raw on purpose -- they are what each guildmate's client reported, and normalising
				-- someone else's string would hide a peer running something unexpected.
				local myVersion = TOGBankClassic_Constants.VersionText(GetAddOnMetadata("TOGBankClassic", "Version"))
				local myPlayer = TOGBankClassic_Guild:GetNormalizedPlayer() or "unknown"
				local responses = hostEntry.VersionResponses or {}

				local list = {}
				for sender, version in pairs(responses) do
					table.insert(list, { name = sender, version = tostring(version) })
				end
				table.sort(list, function(a, b)
					local cmp = VC:CompareVersion(b.version, a.version)
					if cmp ~= 0 then return cmp > 0 end
					return a.name < b.name
				end)

				TOGBankClassic_Output:Response("Version check: %d guild member(s) responded", #list)
				TOGBankClassic_Output:Response("  %s: %s (you)", myPlayer, myVersion)
				for _, entry in ipairs(list) do
					TOGBankClassic_Output:Response("  %s: %s", entry.name, entry.version)
				end
				if #list == 0 then
					TOGBankClassic_Output:Response("  No responses received.")
				end
			end)
		end,
	},
	{
		name = "wipe",
		help = "reset your own TOGBankClassic database",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:WipeMine()
		end,
	},
	{
		name = "wipeall",
		help = "officer only: reset your own TOGBankClassic database and that of all online guild members",
		expert = true,
		handler = function()
			TOGBankClassic_Guild:Wipe()
		end,
	},
	{
		name = "wipeframes",
		help = "reset all saved window positions to default",
		expert = true,
		handler = function()
			if TOGBankClassic_Options and TOGBankClassic_Options.db and TOGBankClassic_Options.db.char then
				local count = 0
				for _ in pairs(TOGBankClassic_Options.db.char.framePositions or {}) do
					count = count + 1
				end
				TOGBankClassic_Options.db.char.framePositions = {}
				-- RECENTER-001: a live widget holds a REFERENCE to its old status table, so replacing
				-- the saved one above moves nothing that is currently on screen -- which is why this
				-- command used to end by telling you to reload. RecenterWindows clears the table the
				-- widget is actually reading and re-applies, so an open window moves now. Sizes still
				-- need the reload (they are read from a table the widget no longer points at), and
				-- the message says so rather than implying the whole reset took effect.
				local moved = TOGBankClassic_UI:RecenterWindows()
				TOGBankClassic_Output:Response(
					"Cleared %d saved window position(s); recentred %d open window(s). Sizes reset on /reload.",
					count, moved)
			else
				TOGBankClassic_Output:Response("No frame positions to clear")
			end
		end,
	},
	{
		-- HELP-PULSE-003: the breath is a one-time attention-getter remembered per account, so once
		-- hovered there is no way to see it again -- the operator, testing the per-tab change: "you
		-- would need to 'unmark' mine so i can test this again". Forgets every hover; the icon on the
		-- open window starts breathing again at once.
		name = "helpreset",
		help = "forget which help icons you have hovered, so they breathe again",
		expert = true,
		handler = function()
			local db = TOGBankClassic_Options and TOGBankClassic_Options.db
			if not (db and db.global) then
				TOGBankClassic_Output:Response("Settings are not loaded yet.")
				return
			end
			db.global.helpSeen = {}
			local Browse = TOGBankClassic_UI_Browse
			if Browse and Browse.SyncHelpPulse then Browse:SyncHelpPulse() end
			TOGBankClassic_Output:Response("Help icons reset: each one breathes again until you hover it.")
		end,
	},
	{
		name = "netq",
		help = "show a breakdown of the ChatThrottleLib outbound queue by message type and recipient",
		expert = true,
		handler = function()
			local ctl = _G.ChatThrottleLib
			if not ctl or not ctl.Prio then
				TOGBankClassic_Output:Response("ChatThrottleLib not available.")
				return
			end

			-- Tally messages by "prefix/chattype/target" bucket
			local buckets = {}
			local grandTotal = 0

			local function walkRing(ring, _)
				if not ring or not ring.pos then return end
				local pipe = ring.pos
				repeat
					for i = 1, #pipe do
						local msg = pipe[i]
						local prefix   = tostring(msg[1] or "?")
						local chattype = tostring(msg[3] or "?")
						local target   = msg[4] and tostring(msg[4]) or nil
						local desc = COMM_PREFIX_DESCRIPTIONS[prefix]
						local prefixLabel = desc and (prefix .. " " .. desc) or prefix
						local key = target and (prefixLabel .. " -> " .. chattype .. "/" .. target)
						              or (prefixLabel .. " -> " .. chattype)
						buckets[key] = (buckets[key] or 0) + 1
						grandTotal = grandTotal + 1
					end
					pipe = pipe.next
				until pipe == ring.pos
			end

			for prioName, prio in pairs(ctl.Prio) do
				walkRing(prio.Ring,    prioName)
				walkRing(prio.Blocked, prioName)
			end

			if grandTotal == 0 then
				TOGBankClassic_Output:Response("ChatThrottleLib queue is empty.")
				return
			end

			-- Sort buckets by count descending
			local sorted = {}
			for key, count in pairs(buckets) do
				table.insert(sorted, { key = key, count = count })
			end
			table.sort(sorted, function(a, b) return a.count > b.count end)

			TOGBankClassic_Output:Response("ChatThrottleLib queue: %d msgs total", grandTotal)
			for _, entry in ipairs(sorted) do
				local pct = math.floor(entry.count / grandTotal * 100 + 0.5)
				TOGBankClassic_Output:Response("  %s: %d (%d%%)", entry.key, entry.count, pct)
			end
		end,
	},
	-- Hidden commands (no help text)
	{
		name = "debug",
		-- DEV-UX-001: bare `/togbank debug` toggles the LOG LEVEL only. That is necessary and not
		-- sufficient: categories are opt-in and default false, so on its own it produces no debug
		-- output at all, and the only way to enable one was the options panel. On an active guild
		-- "Enable All" is unusable -- thousands of lines a second -- so the category system is the
		-- right design and what was missing is a SURGICAL way to drive it. Hence the arguments
		-- below; `only` is the one that matters, because isolating one subsystem in a single
		-- command is the actual task. This could not have existed before CMD-001: no argument
		-- reached a handler at all.
		handler = function(arg1, tail)
			local Out = TOGBankClassic_Output
			local sub = arg1 and tostring(arg1):upper() or nil

			if sub then
				local function categories()
					local names = {}
					for name in pairs(DEBUG_CATEGORY) do names[#names + 1] = name end
					table.sort(names)
					return names
				end

				if sub == "LIST" then
					Out:Response("|cffffff00Debug categories|r (log level is %s)",
						TOGBankClassic_Output:GetLevel() == LOG_LEVEL.DEBUG and "Debug" or "NOT Debug - run /togbank debug")
					for _, name in ipairs(categories()) do
						Out:Response("  %s %s", Out:IsCategoryEnabled(name) and "|cff00ff00ON |r" or "|cff888888OFF|r", name)
					end
					return
				end

				if sub == "NONE" then
					Out:DisableAllCategories()
					Out:Response("All debug categories off.")
					return
				end

				-- `only <CATEGORY>`: everything off, then one on. The escape hatch for a live guild.
				if sub == "ONLY" then
					local target = tail and tostring(tail):match("^(%S+)") or nil
					target = target and target:upper() or nil
					if not target or not DEBUG_CATEGORY[target] then
						Out:Error("Usage: /togbank debug only <CATEGORY>")
						Out:Response("Categories: %s", table.concat(categories(), ", "))
						return
					end
					Out:DisableAllCategories()
					Out:SetCategoryEnabled(target, true)
					Out:Response("Debug category |cffffff00%s|r ON, every other category off.", target)
					return
				end

				if not DEBUG_CATEGORY[sub] then
					Out:Error("Unknown debug category: %s", tostring(arg1))
					Out:Response("Categories: %s", table.concat(categories(), ", "))
					Out:Response("Usage: /togbank debug <CATEGORY> [on|off] | only <CATEGORY> | none | list")
					return
				end

				-- `<CATEGORY> [on|off]` and `<CATEGORY> <TAG> on|off`.
				--
				-- The pattern is anchored with no trailing remainder on purpose: an earlier version
				-- used `^(%S+)%s*(%S*)$`, which matched only the first two words of a longer line,
				-- so `/togbank debug BANK on extra` parsed as tag "ON" state "extra" -- it set a
				-- tag that does not exist, to false, and reported success. A confident confirmation
				-- for a typo is the exact class DEV-UX-001 was filed against.
				local first, second, extra = nil, nil, nil
				if tail then
					first, second, extra = tostring(tail):match("^(%S+)%s*(%S*)%s*(.*)$")
				end
				local function truthy(v) return v == "on" or v == "true" or v == "1" end
				local function stateWord(v) return truthy(v) or v == "off" or v == "false" or v == "0" end

				if extra and extra ~= "" then
					Out:Error("Too many arguments: /togbank debug %s [on|off]  or  %s <TAG> on|off", sub, sub)
					return
				end

				if first and second and second ~= "" then
					local tag = first:upper()
					-- A tag must be one the category actually declares. Tags are opt-out at READ
					-- time (an unknown tag shows by default), but accepting an unknown one at WRITE
					-- time stores a setting that can never affect any output.
					local known = DEBUG_TAGS and DEBUG_TAGS[sub]
					if not (known and known[tag]) then
						Out:Error("Unknown tag %s for category %s", tag, sub)
						if known then
							local names = {}
							for name in pairs(known) do names[#names + 1] = name end
							table.sort(names)
							Out:Response("Tags: %s", table.concat(names, ", "))
						end
						return
					end
					if not stateWord(second:lower()) then
						Out:Error("Usage: /togbank debug %s %s on|off", sub, tag)
						return
					end
					Out:SetTagEnabled(sub, tag, truthy(second:lower()))
					Out:Response("Debug %s / %s: %s", sub, tag, truthy(second:lower()) and "ON" or "OFF")
					return
				end

				local enable = first and truthy(first:lower()) or (first == nil)
				if first and not (truthy(first:lower()) or first:lower() == "off") then
					-- A single unrecognised word is a tag with no state, which is a usage error
					-- rather than something to guess at.
					Out:Error("Usage: /togbank debug %s [on|off]  or  /togbank debug %s <TAG> on|off", sub, sub)
					return
				end
				Out:SetCategoryEnabled(sub, enable)
				Out:Response("Debug category |cffffff00%s|r: %s", sub, enable and "ON" or "OFF")
				return
			end

			local currentLevel = TOGBankClassic_Output:GetLevel()
			if currentLevel == LOG_LEVEL.DEBUG then
				-- Restore to pre-debug level
				local restoreLevel = preDebugLogLevel or LOG_LEVEL.INFO
				preDebugLogLevel = nil
				TOGBankClassic_Output:SetLevel(restoreLevel)
				TOGBankClassic_Options.db.global.bank["logLevel"] = restoreLevel

				-- Get level name for response message
				local levelName = "Info"
				if restoreLevel == LOG_LEVEL.RESPONSE then levelName = "Quiet"
				elseif restoreLevel == LOG_LEVEL.ERROR then levelName = "Error"
				elseif restoreLevel == LOG_LEVEL.WARN then levelName = "Warn"
				end
				TOGBankClassic_Output:Response("Debug: off (log level: " .. levelName .. ")")
			else
				-- Save current level before entering debug mode
				preDebugLogLevel = TOGBankClassic_Options.db.global.bank["logLevel"]
				TOGBankClassic_Output:SetLevel(LOG_LEVEL.DEBUG)
				TOGBankClassic_Options.db.global.bank["logLevel"] = LOG_LEVEL.DEBUG
				TOGBankClassic_Output:Response("Debug: on (log level: Debug)")
			end
		end,
	},
	{
		name = "debugdump",
		handler = function()
			local G = TOGBankClassic_Guild
			if not G or not G.Info or not G.Info.alts then
				TOGBankClassic_Output:Response("no alts table available")
				return
			end
			TOGBankClassic_Output:Response("Listing Info.alts keys:")
			local i = 0
			for k, v in pairs(G.Info.alts) do
				i = i + 1
				TOGBankClassic_Output:Response(i, tostring(k), type(v))
				if i >= 200 then
					TOGBankClassic_Output:Response("truncated at 200 entries")
					break
				end
			end
			if i == 0 then
				TOGBankClassic_Output:Response("no entries")
			end
		end,
	},
	{
		name = "hashdebug",
		help = "show hash-list coverage and missing alts",
		expert = true,
		handler = function()
			if TOGBankClassic_Guild and TOGBankClassic_Guild.ReportHashListCoverage then
				TOGBankClassic_Guild:ReportHashListCoverage()
			end
		end,
	},
	{
		-- INV2: list the dev switches and their live state.
		name  = "switches",
		usage = "[<name> on|off]",
		help = "list or set the INV2 dev switches",
		handler = function(arg)
			local S, Out = TOGBankClassic_Switches, TOGBankClassic_Output
			if not S then Out:Error("Switches module not loaded"); return end

			local name, value = tostring(arg or ""):match("^(%S+)%s+(%S+)$")
			if name then
				local on = (value == "on" or value == "true" or value == "1")
				if S:Set(name, on) then
					Out:Response("Switch |cffffff00%s|r set to %s", name, on and "ON" or "OFF")
				elseif not S.registry[name] then
					Out:Error("Unknown switch: %s", name)
				else
					-- Set() also returns false when db.global is not attached yet. Reporting that
					-- as "unknown switch" would send someone hunting for a typo that isn't there.
					Out:Error("Cannot set %s yet - the database is not loaded.", name)
				end
				return
			end

			Out:Response("|cffffff00=== INV2 dev switches ===|r")
			for _, e in ipairs(S:GetAll()) do
				-- `enabled` is the LIVE answer, so a dependent switch shows OFF while its
				-- parent is off even though its own stored value says otherwise. Showing the
				-- stored value here would claim an effect the switch is not having.
				local state = e.enabled and "|cff44ff44ON|r " or "|cffff4444OFF|r"
				local note  = e.overridden and "" or " |cff888888(default)|r"
				Out:Response("  %s %s%s", state, e.name, note)
				Out:Response("      |cff888888%s|r", e.description)
				if e.requires then
					Out:Response("      |cff888888requires: %s|r", e.requires)
				end
				-- A staged switch must say so where the state is read, not only in the source.
				-- Without this the listing shows it ON and nothing contradicts it.
				if e.pending then
					Out:Response("      |cffff8800NOT YET ACTIVE: %s|r", e.pending)
				end
			end
			Out:Response("Usage: /togbank dev switches <name> on|off")
		end,
	},
	{
		-- INV2-DOC-001: measure the tuple wire against the link wire ON THIS GUILD'S REAL DATA.
		--
		-- The bandwidth claims were pulled from the CurseForge page in the v1.3.2 sweep because
		-- they were unverified, and the item that replaced them insists on a REAL guild rather
		-- than a synthetic payload. Scraping a live COMMS log cannot supply it: `togbank-d4` only
		-- appears when a peer is actually behind, so a healthy guild produces no sample at all.
		--
		-- NEITHER SIDE OF THIS IS INVENTED. The V2 number is the real `Wire.encode` output for the
		-- records actually held. The legacy number is built from the SAME rows with each item's
		-- link resolved through `Resolve.describe` -- the real link for the real item -- so the
		-- comparison is one inventory measured two ways, not a measurement against a guess about
		-- how long a link is.
		name = "bandwidth",
		help = "measure the V2 tuple wire against the legacy link wire, on real stored data",
		handler = function()
			local Out    = TOGBankClassic_Output
			local Store  = TOGBankClassic_Inventory_Store
			local Wire   = TOGBankClassic_Inventory_Wire
			local Record = TOGBankClassic_Inventory_Record
			local Resolve = TOGBankClassic_Inventory_Resolve
			local info   = TOGBankClassic_Guild and TOGBankClassic_Guild.Info

			Out:Response("|cffffff00=== wire size: V2 tuples vs legacy links ===|r")
			if not (Store and Wire and Record and Resolve) then
				Out:Error("INV2 modules not loaded"); return
			end
			if not (info and info.name) then Out:Error("No guild data loaded"); return end

			local alts = Store:GetAltNames(info.name)
			if #alts == 0 then
				Out:Response("|cffffcc00V2 store is empty - no scan has run yet.|r")
				Out:Response("Open your bank and CLOSE it (the scan runs on close), then retry.")
				return
			end

			local totalV2, totalLegacy, totalRows, measured = 0, 0, 0, 0
			local totalResolved = 0
			for _, altName in ipairs(alts) do
				local records = Store:GetAltRecords(info.name, altName)
				if #records > 0 then
					local encoded = Wire.encode(altName, records, 0)
					-- A nil encode would measure as 0 bytes and report a 100% saving -- a wrong
					-- figure that looks like a triumph rather than an error. Skip the character
					-- and say so instead.
					if not encoded then
						Out:Response("  |cffff4444%s: could not encode, skipped|r", altName)
					else
						local v2 = Wire.estimateSize(encoded) or 0
						-- CMD-004: the legacy shape comes from Wire.legacyShapeFor, which lives
						-- beside the decoder that defines it. It used to be rebuilt inline here,
						-- which made it a second spelling with nothing keeping the two in step.
						local shape, resolved = Wire.legacyShapeFor(altName, records, 0)
						local legacy = Wire.estimateSize(shape) or 0

						totalV2, totalLegacy = totalV2 + v2, totalLegacy + legacy
						totalRows      = totalRows + #records
						totalResolved  = totalResolved + resolved
						measured       = measured + 1
						Out:Response("  %s: %d rows, V2 %d B, legacy %d B", altName, #records, v2, legacy)
					end
				end
			end

			if measured == 0 or totalLegacy == 0 then
				Out:Response("|cffffcc00Nothing measurable - every stored character has no rows.|r")
				return
			end

			-- REFUSE TO REPORT A PERCENTAGE THE MEASUREMENT CANNOT SUPPORT. The legacy side is only
			-- big because it carries item LINKS; if ItemDB could not resolve them the rows come out
			-- link-less, the legacy payload is nearly as small as the tuple one, and the reduction
			-- reads as spectacular for the worst possible reason -- the comparison is measuring an
			-- absence. This is not hypothetical: ItemDB is a required dependency, so the failure
			-- appears exactly on a broken install, which is where a wrong number is least likely to
			-- be questioned. Whole numbers only, so a partial resolve is still reported rather than
			-- rounded into looking fine.
			if totalResolved < totalRows then
				Out:Error("Only %d of %d items resolved to a link.", totalResolved, totalRows)
				Out:Response("|cffffcc00No percentage reported: the legacy figure is only meaningful " ..
					"when the links it is made of exist. Check ItemDB is installed.|r")
				Out:Response("  V2 tuples : %d bytes over %d rows", totalV2, totalRows)
				return
			end

			-- Reported as a REDUCTION because that is the claim the page makes. Rounded down, so
			-- the published figure is never better than what was measured.
			local pct = math.floor(((totalLegacy - totalV2) / totalLegacy) * 100)
			Out:Response("|cffffff00TOTAL|r %d characters, %d rows", measured, totalRows)
			Out:Response("  V2 tuples : |cff44ff44%d bytes|r", totalV2)
			Out:Response("  legacy    : |cffff8800%d bytes|r", totalLegacy)
			Out:Response("  reduction : |cff44ff44%d%%|r", pct)
		end,
	},
	-- INV2-RETIRE-003: `/togbank dev compare` -- "prove the V2 store agrees with the legacy one, on
	-- live data" -- was deleted here. Its whole subject was the dual-write period: two encodings of
	-- one container walk, diffed per item id. The legacy rows are no longer written or kept, so
	-- there is nothing left to compare the store against.
	{
		-- ROSTER-003: in-game verification for the LibGuildRoster migration. The offline suite
		-- proves the library works and that our derivations are right, but it cannot prove the
		-- two agree against a REAL guild roster on a live client -- which is exactly where a
		-- normalization or note-visibility mismatch would show up.
		name = "rostercheck",
		help = "compare our roster cache against LibGuildRoster (dev)",
		handler = function()
			local G   = TOGBankClassic_Guild
			local Out = TOGBankClassic_Output
			local lib = G and G.RosterLib and G:RosterLib()

			Out:Response("|cffffff00=== Roster check ===|r")
			if not lib then
				Out:Response("LibGuildRoster-1.0: |cffff4444NOT LOADED|r - using the legacy scan.")
				Out:Response("It is a required dependency; check it is installed and enabled.")
				return
			end
			Out:Response("LibGuildRoster-1.0: loaded, ready=%s", tostring(lib:IsReady()))
			if not lib:IsReady() then
				Out:Response("|cffffcc00Roster still stabilizing - re-run in a few seconds.|r")
				return
			end

			local libNames = lib:GetAllMembers() or {}
			local ourCount = 0
			for _ in pairs(G.memberRoster or {}) do ourCount = ourCount + 1 end
			Out:Response("Members: library=%d, our cache=%d", #libNames, ourCount)

			-- GROUND TRUTH. Comparing our cache's isOnline against lib:IsOnline is nearly
			-- vacuous -- _RefreshFromRosterLib copies that value straight out of the library,
			-- so it compares the library against a copy of itself and can only catch a bug in
			-- the copy loop. The independent source is the WoW API itself, so scan it directly
			-- and check the LIBRARY against that.
			--
			-- Caveat: GetGuildRosterInfo iteration is filtered by the guild panel's "Show
			-- Offline Members" toggle. With it off the scan only returns online members, so
			-- rawTotal below can legitimately be far smaller than the library's count -- that
			-- is the filter, not a defect. The online SET is still trustworthy either way.
			local rawOnline, rawTotal = {}, (GetNumGuildMembers() or 0)
			for i = 1, rawTotal do
				local rname, _, _, _, _, _, _, _, rOnline = GetGuildRosterInfo(i)
				if rname and rOnline then
					local n = G:NormalizeName(rname)
					if n then rawOnline[n] = true end
				end
			end

			local libSaysOffline, libSaysOnline = {}, {}
			for _, name in ipairs(libNames) do
				local libOn = (lib:IsOnline(name) == true)
				if rawOnline[name] and not libOn then
					libSaysOffline[#libSaysOffline + 1] = name
				elseif libOn and not rawOnline[name] then
					libSaysOnline[#libSaysOnline + 1] = name
				end
			end

			-- Copy fidelity: our cache vs the library. Narrow by construction (see above), but
			-- it does catch a member dropped during the rebuild.
			local missing, nameMismatch = {}, {}
			for _, name in ipairs(libNames) do
				if not (G.memberRoster and G.memberRoster[name]) then
					missing[#missing + 1] = name
				end
				-- Normalization must agree or every alt key, request and wire message misses.
				-- This one IS independent: two separate implementations, compared.
				if G.NormalizeName and lib:NormalizeName(name) ~= G:NormalizeName(name) then
					nameMismatch[#nameMismatch + 1] = name
				end
			end

			local function report(label, list, colour)
				if #list == 0 then
					Out:Response("%s: |cff44ff44none|r", label)
					return
				end
				local shown = {}
				for i = 1, math.min(#list, 10) do shown[i] = list[i] end
				Out:Response("%s: %s%d|r - %s%s", label, colour, #list,
					table.concat(shown, ", "), #list > 10 and " ..." or "")
			end
			Out:Response("|cffffff00-- Library vs the WoW API (independent) --|r")
			report("API says online, library says offline", libSaysOffline, "|cffff4444")
			report("Library says online, API says offline", libSaysOnline,  "|cffff4444")
			Out:Response("|cffffff00-- Our cache vs the library --|r")
			report("In library but not our cache", missing,      "|cffff4444")
			report("Normalization disagreement",   nameMismatch, "|cffff4444")

			-- The part a snapshot cannot show: are the presence callbacks actually firing?
			-- Both sides agreeing proves the copy is faithful, not that the mechanism is live.
			-- On a busy roster a zero count after a while is itself the signal.
			local s = G.rosterStats
			Out:Response("|cffffff00-- Presence transitions since login --|r")
			if not s then
				Out:Response("|cffff4444Callbacks were never bound|r - Guild:InitRosterCallbacks " ..
					"did not run, or LibGuildRoster was missing at login.")
			else
				Out:Response("online=%d  offline=%d  whisper-not-found=%d",
					s.online or 0, s.offline or 0, s.notFound or 0)
				if #(s.recent or {}) > 0 then
					Out:Response("recent: %s", table.concat(s.recent, ", "))
				elseif (s.online or 0) + (s.offline or 0) == 0 then
					Out:Response("|cffffcc00No transitions seen yet. Expected on a quiet roster; " ..
						"on a busy one, re-run after someone logs on or off.|r")
				end
			end

			-- Bankers are derived from notes; if officer notes are unreadable, bankers tagged
			-- only there are invisible. Surface that rather than silently listing none.
			local banks = G.GetBanks and G:GetBanks()
			Out:Response("Bankers detected: %d", banks and #banks or 0)
			if CanViewOfficerNote and not CanViewOfficerNote() then
				Out:Response("|cffffcc00Note: you cannot read officer notes, so any banker " ..
					"tagged only there will not appear.|r")
			end
		end,
	},
	-- INV2-RETIRE-003: `/togbank dev purgeghosts` (re-run Database:PurgeLinklessGearGhosts) was
	-- deleted here with the migration it re-ran; the legacy rows it walked are stripped on load.
	{
		name = "hashdump",
		help = "dump raw latestBankerHashes table used for sync comparison",
		expert = true,
		handler = function()
			local lbh = TOGBankClassic_Guild and TOGBankClassic_Guild.latestBankerHashes
			if not lbh then
				TOGBankClassic_Output:Response("latestBankerHashes is nil (not initialized yet)")
				return
			end
			local count = 0
			for _ in pairs(lbh) do count = count + 1 end
			TOGBankClassic_Output:Response(string.format("latestBankerHashes: %d entries", count))
			local localAlts = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.alts or {}
			local rows = {}
			for norm, summary in pairs(lbh) do
				local localAlt = localAlts[norm]
				-- HASH-REV-002: this was a FOURTH copy of the comparison and it was WRONG --
				-- `match = (summary.hash == localHash)`, ignoring mailHash entirely. So an alt whose
				-- mail hash differed printed OK here while IsAltSyncPending called it pending, and
				-- Guild.lua's own docstring claims this command and that function share one
				-- definition. A diagnostic that disagrees with the thing it diagnoses sends whoever
				-- reads it in the wrong direction, which this addon has paid for before (DOC-005).
				-- P2P-034/035: the verdict is IsAltSyncPending's -- AdvertisedImproves, the one request
				-- rule -- not HashesAgreeWith. HashesAgreeWith answers "the same version?" and fails
				-- closed on a missing mail hash; a numbered broadcast carries no mail hash, so it would
				-- print MISMATCH for every entry learned that way while nothing was pending. Same
				-- class as the HASH-REV-002 note above: a diagnostic that disagrees with what it
				-- diagnoses.
				local matches = not TOGBankClassic_Guild:AdvertisedImproves(norm, summary)
				local localHash = localAlt and localAlt.inventoryHash or 0
				local localMailHash = localAlt and localAlt.mailHash or 0
				-- HASH-CANON-007: the CANON is printed, and first. This command printed only the
				-- revision-1 numbers after the canon had become the field that decides the verdict,
				-- so "did the new hash arrive?" could not be answered from chat at all -- the
				-- operator asked exactly that on 2026-09-10 and the answer was "hover the tab". The
				-- tab state (GetAltStaleness) is printed beside it so this line and the tab colour
				-- cannot disagree without it being visible here.
				local state = TOGBankClassic_Guild:GetAltStaleness(norm)
				table.insert(rows, {
					norm = norm,
					state = state,
					knownCanon = summary.hashV2,
					localCanon = localAlt and localAlt.inventoryHashV2,
					knownHash = summary.hash or 0,
					knownMailHash = summary.mailHash or 0,
					localHash = localHash,
					localMailHash = localMailHash,
					match = matches,
				})
			end
			table.sort(rows, function(a, b) return a.norm < b.norm end)
			for _, r in ipairs(rows) do
				local matchStr = r.match and "|cff00ff00OK|r" or "|cffff4444MISMATCH|r"
				TOGBankClassic_Output:Response(string.format(
					"  %s %s [%s] canon local=%s known=%s",
					matchStr, r.norm, r.state, canonStr(r.localCanon), canonStr(r.knownCanon)
				))
				-- Mail hashes are printed because they decide the verdict too. Reporting MISMATCH on
				-- two identical canons with nothing else on the line is unreadable.
				TOGBankClassic_Output:Response(string.format(
					"      rev1 local=%08x/mail=%08x known=%08x/mail=%08x",
					r.localHash, r.localMailHash, r.knownHash, r.knownMailHash
				))
			end
		end,
	},
	{
		-- P2P-029: the operator asked for a way to see the queue. Both sides of this client's
		-- P2P state in one place: what we are SENDING (slots in use, who is waiting for one, who we
		-- have accepted and are waiting on a summary from) and what we are FETCHING (our own
		-- sessions, including the ones parked in someone else's queue).
		name = "sendqueue",
		help = "show P2P send slots, the send queue, and our own fetch sessions",
		expert = true,
		handler = function()
			local P2P, Out = TOGBankClassic_P2PSession, TOGBankClassic_Output
			if not P2P then Out:Error("P2PSession module not loaded"); return end
			local now = GetTime()

			Out:Response("|cffffff00=== P2P send slots: %d/%d in use ===|r", P2P:GetActiveSendTotal(), P2P.MAX_ACTIVE_SENDS or 0)
			local any = false
			for requester, n in pairs(P2P.activeSends or {}) do
				if n > 0 then
					any = true
					local waiting = P2P:IsAwaitingSummary(requester) and " (awaiting their state summary)" or ""
					Out:Response("  %s x%d%s", requester, n, waiting)
				end
			end
			if not any then Out:Response("  (none)") end

			local q = P2P.sendQueue or {}
			Out:Response("|cffffff00=== send queue: %d waiting ===|r", #q)
			for i, e in ipairs(q) do
				Out:Response("  #%d %s wants %s (queued %ds ago)", i, e.requester, e.altName, math.floor(now - (e.at or now)))
			end

			local count = 0
			for _ in pairs(P2P.sessions or {}) do count = count + 1 end
			Out:Response("|cffffff00=== our fetch sessions: %d (%d active) ===|r", count, P2P.activeSessions or 0)
			local rows = {}
			for _, s in pairs(P2P.sessions or {}) do
				rows[#rows + 1] = s
			end
			table.sort(rows, function(a, b) return tostring(a.altName) < tostring(b.altName) end)
			for _, s in ipairs(rows) do
				local tried = 0
				for _ in pairs(s.triedPeers or {}) do tried = tried + 1 end
				Out:Response("  %s <- %s [%s] candidates=%d tried=%d", tostring(s.altName), tostring(s.peer),
					tostring(s.state), #(s.candidates or {}), tried)
			end
			local pd = P2P.pendingDispatch or {}
			if #pd > 0 then
				Out:Response("  waiting for a session slot of our own: %d alt(s)", #pd)
			end
		end,
	},
	{
		-- DOUBLE-001: the operator, 2026-09-12: "i only have 3x archaic defenders. the ui is showing 6.
		-- most of the things on toglowweap are doubled in the UI". The view SUMS the store's per-source
		-- buckets (bags + bank + mail, or a wholesale `all`), so a doubled count almost always means one
		-- item sitting in two buckets -- and nothing in the game could show which. This prints every
		-- bucket, visible and hidden, with when each source was last read, and an item's count in each.
		name = "sources",
		usage = "<banker> [item name]",
		help = "print the store's per-source buckets for one banker (bags / bank / mail / all, visible and hidden), and an item's count in each",
		expert = true,
		handler = function(arg)
			local G, Out, Store = TOGBankClassic_Guild, TOGBankClassic_Output, TOGBankClassic_Inventory_Store
			local Record, Item = TOGBankClassic_Inventory_Record, TOGBankClassic_Item
			local text = tostring(arg or ""):trim()
			local name, item = text:match("^(%S+)%s*(.-)$")
			if not name or name == "" then Out:Response("Usage: /togbank dev sources <banker> [item name]"); return end
			if not (G and G.Info and G.Info.name and Store) then Out:Error("No guild data loaded"); return end
			local norm = G:NormalizeName(name) or name
			local g = Store:GuildTable(G.Info.name, false)
			local alt = g and g.alts and g.alts[norm]
			if not alt then Out:Response("%s: no V2 record held", norm); return end
			local rec = G.Info.alts and G.Info.alts[norm]
			item = (item or ""):lower()
			Out:Response("|cffffff00=== sources %s ===|r  schema=%s  updated=%s  canon=%s", norm,
				tostring(alt.schema), tostring(alt.updated), tostring(rec and rec.inventoryHashV2))
			local function nameOf(r)
				local d = Item and Item.RequestDisplayName and Item:RequestDisplayName({ item = "Item " .. Record.id(r), itemID = Record.id(r), suffixID = Record.suffix(r) })
				return d or ("item " .. tostring(Record.id(r)))
			end
			local function dump(label, buckets)
				for source, bucket in pairs(buckets or {}) do
					local rows, units = #bucket, 0
					for _, r in ipairs(bucket) do units = units + Record.count(r) end
					local at = rec and rec[source] and rec[source].lastScan
					Out:Response("  %s %s: %d row(s), %d unit(s), last read %s", label, source, rows, units, at and tostring(at) or "?")
					if item ~= "" then
						for _, r in ipairs(bucket) do
							local n = nameOf(r)
							if n:lower():find(item, 1, true) then
								Out:Response("      %s x%d  (key %s)", n, Record.count(r), Record.key(r))
							end
						end
					end
				end
			end
			dump("visible", alt.sources)
			dump("|cffff4444hidden|r", alt.hidden)
			local total = 0
			for _, r in ipairs(Store:GetAltRecords(G.Info.name, norm)) do
				if item == "" or nameOf(r):lower():find(item, 1, true) then total = total + Record.count(r) end
			end
			Out:Response("  the view sums the visible buckets: %d unit(s)%s", total, item ~= "" and (" of '" .. item .. "'") or "")
		end,
	},
	{
		-- P2P-035 follow-up (Peer Review): sendqueue's sibling. ONE alt, walked through every gate in
		-- the order the code asks them, printing each answer WITH ITS INPUTS and stopping at the
		-- first "no" on the serving side. Every gate here is the production predicate itself
		-- (IsBank, HasAltContent, CanServe, ServableCanon, the slot count, the state-wait table,
		-- AdvertisedImproves, GetAltStaleness), never a copy of one -- a diagnostic that disagrees
		-- with what it diagnoses is the DOC-005 / HASH-REV-002 class this file has paid for twice.
		name = "trace",
		usage = "<banker>",
		help = "walk one banker through every P2P gate, serving side then fetching side, and name the first that says no",
		expert = true,
		handler = function(arg)
			local G, P2P, Out = TOGBankClassic_Guild, TOGBankClassic_P2PSession, TOGBankClassic_Output
			local Store, BN = TOGBankClassic_Inventory_Store, TOGBankClassic_BankerNumbers
			local name = tostring(arg or ""):trim()
			if name == "" then Out:Response("Usage: /togbank dev trace <banker>"); return end
			if not (G and G.Info) then Out:Error("No guild data loaded"); return end
			local norm = G:NormalizeName(name) or name
			local YES, NO = "|cff00ff00yes|r", "|cffff4444NO|r"

			Out:Response("|cffffff00=== trace %s ===|r", norm)
			-- ── Serving side: could we deliver this alt to a requester right now? ──
			Out:Response("|cffffff00-- serving side (the order HandleSyncRequest asks) --|r")
			local isBank = G:IsBank(norm)
			Out:Response("  1. banker on the roster: %s%s", isBank and YES or NO,
				(BN and BN:NumberOf(norm)) and (" number " .. BN:NumberOf(norm)) or " (unnumbered)")
			local alt = G.Info.alts and G.Info.alts[norm]
			local records = (Store and G.Info.name) and Store:GetAltRecords(G.Info.name, norm) or {}
			Out:Response("  2. record held: %s  V2 tuples=%d  HasAltContent=%s",
				alt and YES or NO, #records, tostring(G:HasAltContent(alt, norm)))
			local canServe = G:CanServe(norm)
			Out:Response("  3. CanServe (V2 tuples > 0, SendAltData's own test): %s", canServe and YES or NO)
			if not canServe then
				Out:Response("  |cffff4444STOP:|r a sync-request for %s gets 'busy' here -- only a rescan by the banker or a delivery fills the V2 store", norm)
			else
				local servable = G:ServableCanon(norm)
				Out:Response("  4. ServableCanon: %s  held canon=%s  publish=%s", servable and YES or NO,
					canonStr(alt and alt.inventoryHashV2), tostring(alt and (alt.inventoryUpdatedAt or alt.version)))
				if not servable then
					Out:Response("  |cffff4444STOP:|r tuples but no canon -- this copy is advertised as nothing and a versioned request is refused")
				end
				if P2P then
					local total, cap = P2P:GetActiveSendTotal(), P2P.MAX_ACTIVE_SENDS or 0
					Out:Response("  5. send slot: %s  %d/%d in use", total < cap and YES or "|cffffff00queue|r", total, cap)
					for i, e in ipairs(P2P.sendQueue or {}) do
						if e.altName == norm then Out:Response("     queued: %s at position %d", e.requester, i) end
					end
					local waiting = false
					for key in pairs(P2P.stateWaits or {}) do
						local who, what = key:match("^(.-)|(.*)$")
						if what == norm then waiting = true; Out:Response("  6. state-wait: accepted %s, still waiting on their summary", who) end
					end
					if not waiting then Out:Response("  6. state-wait: none open for this alt") end
				end
			end

			-- ── Fetching side: do we want a newer copy, and where is the session? ──
			Out:Response("|cffffff00-- fetching side --|r")
			local state, _, _, who = G:GetAltStaleness(norm)
			Out:Response("  tab state: %s%s", tostring(state), who and (" (offered by " .. tostring(who) .. ")") or "")
			local known = G.latestBankerHashes and G.latestBankerHashes[norm]
			if known then
				local improves, reason = G:AdvertisedImproves(norm, known)
				Out:Response("  newest known: canon=%s  AdvertisedImproves=%s (%s)", canonStr(known.hashV2), improves and YES or NO, tostring(reason))
			else
				Out:Response("  newest known: nothing advertised yet this session")
			end
			Out:Response("  newestAdvertisedAt=%s  IsAltSyncPending=%s",
				tostring(G.newestAdvertisedAt and G.newestAdvertisedAt[norm]), tostring(G:IsAltSyncPending(norm)))
			-- CLAIM-TRACE-001: WHO SAID SO. A red tab means "somebody has newer than you", and until
			-- this line nothing in the game could name the somebody -- so a banker sitting behind a
			-- version its own author never published (CANON-TIME-001 was one way that happens) could
			-- not be diagnosed from a live client at all. If the claimed time is far ahead of every
			-- real publish, or the claimant is a viewer rather than the banker, that is the culprit.
			local by = G.newestAdvertisedBy and G.newestAdvertisedBy[norm]
			if by then
				Out:Response("  claimed by: %s  canon=%s  (%s ago)", tostring(by.peer or "unattributed"),
					canonStr(by.canon), tostring(GetServerTime() - (by.at or 0)))
			else
				Out:Response("  claimed by: nobody has named a version for this banker yet")
			end
			-- MULTIPC-001: for our own character the question is not "fetch?" but "may this PC
			-- publish?" -- the same predicate Bank:Scan asks, with the inputs it reads.
			if norm == G:GetNormalizedPlayer() and TOGBankClassic_Bank and TOGBankClassic_Bank.CanPublish then
				local Bank = TOGBankClassic_Bank
				local ok, why = Bank:CanPublish(alt)
				local newer = G.NewerSelfVersionAt and G:NewerSelfVersionAt()
				Out:Response("|cffffff00-- publish gate (this is us) --|r")
				Out:Response("  newer version elsewhere: %s  consulted this session: %s",
					newer and tostring(newer) or "none named", tostring(P2P and P2P.IsSelfConsulted and P2P:IsSelfConsulted()))
				for _, source in ipairs({ "bank", "bags", "mail" }) do
					local at = alt and alt[source] and alt[source].lastScan
					Out:Response("  %s: last read on this PC %s%s", source, at and tostring(at) or "never",
						(Bank.readThisSession or {})[source] and " (this session)" or "")
				end
				Out:Response("  CanPublish: %s (%s)%s", ok and YES or NO, tostring(why),
					Bank.deferred and "  -- a scan is waiting to publish" or "")
				-- HIDE-SYNC-001: the operator's trace read 'NO (unconsulted)' 33 minutes into a session
				-- with nothing deferred, and the three facts that decide between "the login consult
				-- never began", "it began and never settled" and "the fallback never fired" were not on
				-- it. Every value here is the production state, read raw.
				Out:Response("  consult: begun=%s settled=%s  fallback timer armed=%s  raid-paused=%s",
					tostring(P2P and P2P.consultBegun), tostring(P2P and P2P.selfConsulted),
					tostring(Bank.deferredFallbackArmed or false),
					tostring(TOGBankClassic_Constants.SyncPausedByRaid and TOGBankClassic_Constants.SyncPausedByRaid()))
				-- Stored vs current content hash: equal means the next scan takes the "no changes" branch
				-- and defers nothing, whatever the gate says.
				local S = TOGBankClassic_Inventory_Store
				local recs = S and G.Info.name and S:GetAltRecords(G.Info.name, norm) or {}
				local current = TOGBankClassic_Core.ComputeInventoryHash
					and TOGBankClassic_Core:ComputeInventoryHash(recs, nil, nil, alt and alt.money or 0) or nil
				Out:Response("  content hash: stored=%s  current=%s (%s)", tostring(alt and alt.inventoryContentHash),
					tostring(current), (alt and alt.inventoryContentHash == current) and "same -- a scan would defer nothing" or "differs -- a scan would publish or defer")
				-- CLAIM-TRACE-001: and for OUR OWN character, who is holding the version we are behind
				-- on -- the peers a diff-base fetch would go to. "none recorded" beside a `newer`
				-- version means nobody can supply it, which is the state the fallback publishes out of.
				local ns = Bank.newerSelf
				Out:Response("  newer copy held by: %s", ns and (#(ns.holders or {}) > 0
					and (table.concat(ns.holders, ", ") .. "  canon=" .. canonStr(ns.canon))
					or ("none recorded  canon=" .. canonStr(ns.canon))) or "nobody named one")
			end
			if P2P then
				local sid = P2P.sessionsByAlt and P2P.sessionsByAlt[norm]
				local s = sid and P2P.sessions and P2P.sessions[sid]
				if s then
					local tried, wanted = 0, nil
					for _ in pairs(s.triedPeers or {}) do tried = tried + 1 end
					-- The version the request names is the chosen peer's candidate canon (SendSyncRequest).
					for _, c in ipairs(s.candidates or {}) do if c.peer == s.peer then wanted = c.canon end end
					Out:Response("  session: [%s] peer=%s candidates=%d tried=%d wanted=%s",
						tostring(s.state), tostring(s.peer), #(s.candidates or {}), tried, canonStr(wanted))
				else
					Out:Response("  session: none")
				end
				for _, e in ipairs(P2P.pendingDispatch or {}) do
					if type(e) == "table" and e.altName == norm then
						Out:Response("  waiting for a session slot of our own")
					end
				end
			end
		end,
	},
}

-- Developer-only commands: hidden from /togbank help, only dispatched via /togbank dev <name>.
-- Catalogued in docs/DEV_COMMANDS.md (not shipped to players; docs/ is ignored in .pkgmeta).
-- Add a name here to flip a command from top-level user-facing to dev-only without touching the
-- COMMAND_REGISTRY entry itself.
-- A dev command must be in BOTH this list and COMMAND_REGISTRY. Registering it in only one is
-- silent: the dispatch loop below sorts every registry entry into one bucket or the other, so a
-- name missing HERE becomes a TOP-LEVEL command instead. `/togbank dev <name>` then reports "not
-- a valid command" while `/togbank <name>` quietly works -- which reads as the command having
-- failed to register at all. Cost one round trip with the operator on 2026-09-10; `chatcommand_spec`
-- now cross-checks this list against the `/togbank dev` commands documented in DEV_COMMANDS.md.
local DEV_COMMAND_NAMES = {
	bandwidth              = true,
	["clear-delta-errors"] = true,
	clearhistory           = true,
	debugdump              = true,
	debuglogsave           = true,
	deltaerrors            = true,
	deltahistory           = true,
	deltastats             = true,
	forcedelta             = true,
	forcefull              = true,
	hashdebug              = true,
	hashdump               = true,
	hashupdate             = true,
	netq                   = true,
	perfstats              = true,
	persistcheck           = true,
	protocol               = true,
	-- INV2-RETIRE-003: `purgeghosts` and `compare` were removed from this list with their handlers.
	reqscan                = true,
	resetmetrics           = true,
	rostercheck            = true,
	sendqueue              = true,
	-- DOUBLE-001: registered in COMMAND_REGISTRY without this line first, so `/togbank dev sources`
	-- answered "Unknown dev subcommand" on the operator's client while the handler sat bound at
	-- top level -- the CMD-002 class again, in the other direction. The registry and this list are
	-- two spellings of one fact; chatcommand_spec pins that every `expert` registry entry is here.
	sources                = true,
	switches               = true,
	trace                  = true,
	versioncheck           = true,
	-- CMD-002: `wipeall` was MISSING here while being documented as `/togbank dev wipeall`, so the
	-- guild-wide destructive reset was reachable as top-level `/togbank wipeall` and the documented
	-- spelling was refused. Of everything this class could have misfiled, an officer-tier command
	-- that resets the database for every online member is the worst one to make EASIER to reach.
	wipeall                = true,
	-- `test` was removed from this list: it named an in-game test command that no longer exists in
	-- COMMAND_REGISTRY, so no handler was ever bound to it. DEV_COMMANDS.md is explicit that it must
	-- not come back ("Do not re-add an in-game test command to stand in for" the offline suite).
}

-- Build lookup tables for fast command dispatch.
-- Top-level COMMAND_HANDLERS excludes dev commands; DEV_COMMAND_HANDLERS holds only those.
local COMMAND_HANDLERS = {}
local DEV_COMMAND_HANDLERS = {}
for _, cmd in ipairs(COMMAND_REGISTRY) do
	if DEV_COMMAND_NAMES[cmd.name] then
		DEV_COMMAND_HANDLERS[cmd.name] = cmd.handler
	else
		COMMAND_HANDLERS[cmd.name] = cmd.handler
	end
end

-- /togbank dev <subcommand> [args] — dispatcher for developer-only commands.
-- Top-level command, no help text → hidden from /togbank help output.
COMMAND_HANDLERS["dev"] = function(arg1, tail)
	-- CMD-001: `arg1` is the subcommand token and `tail` is everything after it. This used to take
	-- a single string and split it on the first space, which could not work: ChatCommand had
	-- already tokenized the input, so arg1 never contained a space and subArgs was always nil.
	local subcommand = tostring(arg1 or ""):trim()
	local subArgs    = tail and tostring(tail):trim() or nil
	if subArgs == "" then subArgs = nil end

	if subcommand == "" or subcommand == "help" then
		TOGBankClassic_Chat:ShowDevHelp()
		return
	end

	local devHandler = DEV_COMMAND_HANDLERS[subcommand]
	if devHandler then
		devHandler(subArgs)
	else
		TOGBankClassic_Output:Response("Unknown dev subcommand: %s", subcommand)
		TOGBankClassic_Chat:ShowDevHelp()
	end
end

-- Instructions as multiline strings for readability
local HELP_INSTRUCTIONS = {
	{
		title = "Instructions for setting up a new guild bank:",
		text = [[
1. Log in with the guild bank character, ensuring they are in the guild.
2. Add |cffe6cc80gbank|r to their guild or officer note, then type |cffe6cc80/reload|r.
3. In addon options (Escape -> Options -> Addons -> TOGBankClassic), click on the |cffe6cc80-|r icon (expand/collapse) to the left of the entry, and check |cffe6cc80Enable for <character>|r is ticked in the |cffe6cc80Bank|r section. It is on by default, so there is usually nothing to change.
4. Open your bank and then CLOSE it - the scan runs on close.
5. Type |cffe6cc80/togbank roster|r and confirm your bank character is listed with a four-digit number.
6. The guild picks the scan up on the next 10-minute check-in, or straight away if you type |cffe6cc80/togbank share|r.
7. Verify with a guild member (they click the minimap button and look at the Bankers tab).]],
	},
	{
		title = "Instructions for removing a guild bank:",
		text = [[
1. Log in with an officer or another bank character in the same guild (or a character from a different guild).
2. If the bank character is still in the guild, remove |cffe6cc80gbank|r from their notes.
3. Type |cffe6cc80/togbank roster|r and confirm the bank character is no longer listed or the roster is empty.
4. Verify with a guild member (they click the minimap button and look at the Bankers tab).]],
	},
}

function TOGBankClassic_Chat:ChatCommand(input)
	if input == nil or input == "" then
		TOGBankClassic_UI_Inventory:Toggle()
	else
		-- CMD-001: GetArgs TOKENIZES; it does not hand back a remainder. Its contract is
		-- `arg1, ..., argN, nextposition` (AceConsole-3.0.lua:138-139), with nextposition = 1e9 at
		-- end of string -- so `GetArgs(input, 2)` gave us "dev" and "switches" and silently DROPPED
		-- "inventoryV2 on". Every `/togbank dev <sub> <args>` command was therefore unable to
		-- receive its arguments in game: `dev switches inventoryV2 on` fell through to the
		-- no-argument branch and printed the list, which looks exactly like a command that ran.
		-- The offline specs missed it because they call the handlers directly.
		--
		-- `rest` is passed as a SECOND parameter rather than replacing arg1, so every existing
		-- single-token handler keeps receiving exactly what it received before.
		local prefix, arg1, nextpos = TOGBankClassic_Core:GetArgs(input, 2)
		local rest = nil
		if nextpos and nextpos < 1e9 then
			rest = tostring(input):sub(nextpos):trim()
			if rest == "" then rest = nil end
		end
		local handler = COMMAND_HANDLERS[prefix]
		if handler then
			handler(arg1, rest)
		else
			TOGBankClassic_Output:Response("Unknown command: ", prefix)
			TOGBankClassic_Chat:ShowHelp()
		end
	end

	return false
end

function TOGBankClassic_Chat:ShowHelp()
	local H = HELP_COLOR.HEADER
	local C = HELP_COLOR.COMMAND
	local R = HELP_COLOR.RESET

	-- Basic commands header
	TOGBankClassic_Output:Response("\n%sCommands:%s", H, R)
	TOGBankClassic_Output:Response("%s/togbank%s - display the TOGBankClassic interface", C, R)

	-- Print basic commands (skip dev commands)
	for _, cmd in ipairs(COMMAND_REGISTRY) do
		if cmd.help and not cmd.expert and not DEV_COMMAND_NAMES[cmd.name] then
			local usage = cmd.usage and (" " .. cmd.usage) or ""
			TOGBankClassic_Output:Response("%s/togbank %s%s%s - %s", C, cmd.name, usage, R, cmd.help)
		end
	end

	-- Expert commands header
	TOGBankClassic_Output:Response("\n%sExpert commands:%s", H, R)

	-- Print expert commands (skip dev commands)
	for _, cmd in ipairs(COMMAND_REGISTRY) do
		if cmd.help and cmd.expert and not DEV_COMMAND_NAMES[cmd.name] then
			local usage = cmd.usage and (" " .. cmd.usage) or ""
			TOGBankClassic_Output:Response("%s/togbank %s%s%s - %s", C, cmd.name, usage, R, cmd.help)
		end
	end

	-- Print instructions
	for _, instruction in ipairs(HELP_INSTRUCTIONS) do
		TOGBankClassic_Output:Response("\n%s%s%s", H, instruction.title, R)
		TOGBankClassic_Output:Response(instruction.text)
	end
end

-- Show dev commands. Only invoked via /togbank dev help; not advertised to players.
-- Full documentation lives in docs/DEV_COMMANDS.md (not shipped to users).
function TOGBankClassic_Chat:ShowDevHelp()
	local H = HELP_COLOR.HEADER
	local C = HELP_COLOR.COMMAND
	local R = HELP_COLOR.RESET

	TOGBankClassic_Output:Response("\n%sDeveloper commands (not user-facing):%s", H, R)
	TOGBankClassic_Output:Response("%s/togbank dev help%s - this list", C, R)

	-- Collect and alphabetize dev command entries
	local entries = {}
	for _, cmd in ipairs(COMMAND_REGISTRY) do
		if DEV_COMMAND_NAMES[cmd.name] then
			table.insert(entries, cmd)
		end
	end
	table.sort(entries, function(a, b) return a.name < b.name end)

	for _, cmd in ipairs(entries) do
		local usage = cmd.usage and (" " .. cmd.usage) or ""
		local helpText = cmd.help or "(no description)"
		TOGBankClassic_Output:Response("%s/togbank dev %s%s%s - %s", C, cmd.name, usage, R, helpText)
	end

	TOGBankClassic_Output:Response("\n%sSee docs/DEV_COMMANDS.md for detailed usage and workflows.%s", H, R)
end

function TOGBankClassic_Chat:ProcessQueue()
	if TOGBankClassic_Constants.SyncPausedByRaid() then
		return
	end
	if #self.sync_queue == 0 then
		self.is_syncing = false
		return
	end

	self.is_syncing = true
	local startTime = debugprofilestop()

	local time = GetServerTime()

	local name = table.remove(self.sync_queue)
	if not self.last_alt_sync[name] or time - self.last_alt_sync[name] > 180 then
		self.last_alt_sync[name] = time
		-- DELTA-014: Broadcast mode - no specific requester, use empty baseline (0,0)
		-- This sends full delta to everyone
		TOGBankClassic_Guild:SendAltData(name)
	end
	local duration = debugprofilestop() - startTime
	TOGBankClassic_Output:Debug("EVENTS", "TIMER", "ProcessQueue took %.2fms (name=%s, queue=%d)", duration, tostring(name), #self.sync_queue)

	if #self.sync_queue > 0 then
		TOGBankClassic_Chat:ReprocessQueue()
	end
end

function TOGBankClassic_Chat:ReprocessQueue()
	if self.reprocessTimer then
		return
	end
	self.reprocessTimer = TOGBankClassic_Core:ScheduleTimer(function()
		TOGBankClassic_Chat.reprocessTimer = nil
		TOGBankClassic_Chat:OnTimer()
	end, TIMER_INTERVALS.ALT_DATA_QUEUE_RETRY)
end

function TOGBankClassic_Chat:OnTimer()
	TOGBankClassic_Chat:ProcessQueue()
end

function TOGBankClassic_Chat:PrintDeltaStats()
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		TOGBankClassic_Output:Response("Not in a guild")
		return
	end

	local metrics = TOGBankClassic_Database:GetDeltaMetrics(guild)
	if not metrics then
		TOGBankClassic_Output:Response("No delta sync metrics available")
		return
	end

	local function formatBytes(bytes)
		if bytes < 1024 then
			return string.format("%d B", bytes)
		elseif bytes < 1024 * 1024 then
			return string.format("%.1f KB", bytes / 1024)
		else
			return string.format("%.1f MB", bytes / (1024 * 1024))
		end
	end

	TOGBankClassic_Output:Response("|cff00ffffDelta Sync Statistics|r")
	TOGBankClassic_Output:Response("")

	-- Outbound: what this client served to others
	local sentCount = metrics.deltasSentCount or 0
	local sentBytes = metrics.bytesSentDelta or 0
	local p2pSent = metrics.p2pSentCount or 0
	local p2pOffered = metrics.p2pOffered or 0
	local noChangeSent = metrics.noChangeSentCount or 0
	TOGBankClassic_Output:Response("|cffffff00Outbound (what I served):|r")
	if sentCount > 0 then
		local avgBytes = sentBytes / sentCount
		local bytesSaved = metrics.bytesSavedByDelta or 0
		TOGBankClassic_Output:Response("  Data sends:        %d sends, %s (avg %s/send)",
			sentCount, formatBytes(sentBytes), formatBytes(avgBytes))
		TOGBankClassic_Output:Response("  Bandwidth saved:   %s vs full sync (%.0f%% reduction)",
			formatBytes(bytesSaved), bytesSaved / (sentBytes + bytesSaved) * 100)
		if p2pSent > 0 then
			TOGBankClassic_Output:Response("  Of which P2P:      %d sends (%.0f%%)",
				p2pSent, (p2pSent / sentCount) * 100)
		else
			TOGBankClassic_Output:Response("  Of which P2P:      0 (all sent in banker role)")
		end
	else
		TOGBankClassic_Output:Response("  Data sends:        0 (no data served yet)")
	end
	if p2pOffered > 0 then
		local converted = p2pSent
		TOGBankClassic_Output:Response("  P2P offered/sent:  %d offered, %d sent (%.0f%% resulted in data)",
			p2pOffered, converted, (converted / p2pOffered) * 100)
	end
	TOGBankClassic_Output:Response("  No-change replies: %d", noChangeSent)
	TOGBankClassic_Output:Response("")

	-- Inbound: what this client received from others
	local bytesReceived = metrics.bytesReceived or 0
	local fromBanker = metrics.deltasReceivedFromBanker or 0
	local fromPeer = metrics.deltasReceivedFromPeer or 0
	local totalReceived = fromBanker + fromPeer
	TOGBankClassic_Output:Response("|cffffff00Inbound (what I received):|r")
	if totalReceived > 0 then
		TOGBankClassic_Output:Response("  Received:          %d deltas, %s", totalReceived, formatBytes(bytesReceived))
		TOGBankClassic_Output:Response("  From banker:       %d (%.0f%%)", fromBanker, (fromBanker / totalReceived) * 100)
		TOGBankClassic_Output:Response("  From peers:        %d (%.0f%%)", fromPeer, (fromPeer / totalReceived) * 100)
	else
		TOGBankClassic_Output:Response("  Received:          0 deltas")
	end
	TOGBankClassic_Output:Response("")

	-- P2P requests: what this client asked peers for
	local p2pBroadcast = metrics.p2pRequestsBroadcast or 0
	local p2pFulfilled = metrics.p2pFulfilledByPeer or 0
	local p2pFallback = metrics.p2pBankerFallback or 0
	TOGBankClassic_Output:Response("|cffffff00P2P Requests (what I asked peers for):|r")
	if p2pBroadcast > 0 then
		local p2pUnresolved = math.max(0, p2pBroadcast - p2pFulfilled - p2pFallback)
		TOGBankClassic_Output:Response("  Broadcast:           %d", p2pBroadcast)
		TOGBankClassic_Output:Response("  Peer responded:      %d (%.0f%%)",
			p2pFulfilled, (p2pFulfilled / p2pBroadcast) * 100)
		TOGBankClassic_Output:Response("  Fell back to banker: %d (%.0f%%)",
			p2pFallback, (p2pFallback / p2pBroadcast) * 100)
		if p2pUnresolved > 0 then
			TOGBankClassic_Output:Response("  Still pending:       %d", p2pUnresolved)
		end
	else
		TOGBankClassic_Output:Response("  No P2P requests broadcast yet")
	end
	TOGBankClassic_Output:Response("")

	-- Protocol health
	local deltasApplied = metrics.deltasApplied or 0
	local deltasFailed = metrics.deltasFailed or 0
	local fullSyncFallbacks = metrics.fullSyncFallbacks or 0
	local totalOps = deltasApplied + deltasFailed
	TOGBankClassic_Output:Response("|cffffff00Protocol Health:|r")
	TOGBankClassic_Output:Response("  Deltas applied:      %d", deltasApplied)
	TOGBankClassic_Output:Response("  Deltas failed:       %d", deltasFailed)
	TOGBankClassic_Output:Response("  Full sync fallbacks: %d", fullSyncFallbacks)
	if totalOps > 0 then
		local successRate = (deltasApplied / totalOps) * 100
		local rateColor = "|cff00ff00"
		if successRate < 95 then rateColor = "|cffffff00" end
		if successRate < 80 then rateColor = "|cffff0000" end
		TOGBankClassic_Output:Response("  Success rate:        %s%.1f%%|r", rateColor, successRate)
	end

	-- P2P-023: Hash-list broadcast collision prevention statistics
	if TOGBankClassic_Events then
		local totalBroadcasts = TOGBankClassic_Events.hashBroadcastCount or 0
		local blockedBroadcasts = TOGBankClassic_Events.hashBroadcastBlocked or 0
		if totalBroadcasts > 0 then
			TOGBankClassic_Output:Response("  Hash broadcasts:     %d sent, %d blocked (%.1f%% collision rate)",
				totalBroadcasts, blockedBroadcasts, (blockedBroadcasts / (totalBroadcasts + blockedBroadcasts)) * 100)
		end
	end

	-- Performance (only show if populated)
	local computeCount = metrics.computeCount or 0
	local applyCount = metrics.applyCount or 0
	if computeCount > 0 or applyCount > 0 then
		TOGBankClassic_Output:Response("")
		TOGBankClassic_Output:Response("|cffffff00Performance:|r")
		if computeCount > 0 then
			local avgCompute = (metrics.totalComputeTime or 0) / computeCount
			TOGBankClassic_Output:Response("  Avg compute time: %.2fms (%d computed)", avgCompute, computeCount)
		end
		if applyCount > 0 then
			local avgApply = (metrics.totalApplyTime or 0) / applyCount
			TOGBankClassic_Output:Response("  Avg apply time:   %.2fms (%d applied)", avgApply, applyCount)
		end
	end

	if sentCount == 0 and totalReceived == 0 and p2pBroadcast == 0 then
		TOGBankClassic_Output:Response("No delta sync activity yet")
	end
end

-- Print recent delta errors and failure counts
function TOGBankClassic_Chat:PrintDeltaErrors()
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		TOGBankClassic_Output:Response("Not in a guild")
		return
	end

	-- Try to get errors from database first, fall back to temp storage
	local errors = nil
	local db = TOGBankClassic_Database.db.faction[guild]
	if db and db.deltaErrors then
		errors = db.deltaErrors
	elseif TOGBankClassic_Guild.tempDeltaErrors then
		-- Use temp storage if database not available
		errors = TOGBankClassic_Guild.tempDeltaErrors
		TOGBankClassic_Output:Response("|cffffaa00Using temporary error storage (Guild.Info not initialized)|r")
	end

	if not errors then
		TOGBankClassic_Output:Response("No error tracking data available")
		return
	end

	-- Print header
	TOGBankClassic_Output:Response("|cff00ff00=== Delta Sync Errors ===|r")

	-- Print recent errors
	if errors.lastErrors and #errors.lastErrors > 0 then
		TOGBankClassic_Output:Response("|cffffff00Recent Errors:|r (%d)", #errors.lastErrors)
		for i, err in ipairs(errors.lastErrors) do
			local timeStr = date("%H:%M:%S", err.timestamp or 0)
			local typeColor = err.errorType == "VERSION_MISMATCH" and "|cffff8800" or "|cffff0000"
			TOGBankClassic_Output:Response("  %d. %s[%s]|r |cffaaaaaa%s|r", i, typeColor, err.errorType, timeStr)
			TOGBankClassic_Output:Response("     |cff88ccff%s|r: %s", err.altName or "Unknown", err.message or "No details")
		end
	else
		TOGBankClassic_Output:Response("|cffffff00Recent Errors:|r None")
	end

	-- Print failure counts per alt
	if errors.failureCounts and next(errors.failureCounts) then
		TOGBankClassic_Output:Response("|cffffff00Failure Counts by Alt:|r")
		local sortedAlts = {}
		for altName, count in pairs(errors.failureCounts) do
			table.insert(sortedAlts, {name = altName, count = count})
		end
		table.sort(sortedAlts, function(a, b) return a.count > b.count end)
		for _, entry in ipairs(sortedAlts) do
			local notified = errors.notifiedAlts and errors.notifiedAlts[entry.name] and " |cffff0000(notified)|r" or ""
			TOGBankClassic_Output:Response("  |cff88ccff%s|r: %d%s", entry.name, entry.count, notified)
		end
	else
		TOGBankClassic_Output:Response("|cffffff00Failure Counts:|r None")
	end

	-- Print summary
	local totalErrors = #(errors.lastErrors or {})
	local totalAlts = 0
	if errors.failureCounts then
		for _ in pairs(errors.failureCounts) do
			totalAlts = totalAlts + 1
		end
	end
	TOGBankClassic_Output:Response("|cffffff00Summary:|r %d error(s) tracked, %d alt(s) affected", totalErrors, totalAlts)
end

-- Print stored delta chain history
function TOGBankClassic_Chat:PrintDeltaHistory()
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		TOGBankClassic_Output:Response("Not in a guild")
		return
	end

	local db = TOGBankClassic_Database.db.faction[guild]
	if not db or not db.deltaHistory then
		TOGBankClassic_Output:Response("No delta history available")
		return
	end

	TOGBankClassic_Output:Response("|cff00ff00=== Delta Chain History ===|r")

	local totalDeltas = 0
	local altCount = 0

	-- Count total deltas and alts
	for _, deltas in pairs(db.deltaHistory) do
		altCount = altCount + 1
		if type(deltas) == "table" then
			totalDeltas = totalDeltas + #deltas
		end
	end

	if totalDeltas == 0 then
		TOGBankClassic_Output:Response("No delta history stored yet")
		return
	end

	TOGBankClassic_Output:Response("|cffffff00Total:|r %d delta(s) stored for %d alt(s)", totalDeltas, altCount)
	TOGBankClassic_Output:Response("")

	-- Show per-alt breakdown
	for altName, deltas in pairs(db.deltaHistory) do
		if type(deltas) == "table" and #deltas > 0 then
			TOGBankClassic_Output:Response("|cff88ccff%s|r: %d delta(s)", altName, #deltas)

			-- Show details for each delta (newest first)
			for i, delta in ipairs(deltas) do
				local age = GetServerTime() - (delta.timestamp or 0)
				local ageStr = age < 60 and string.format("%ds ago", age)
					or age < 3600 and string.format("%dm ago", math.floor(age / 60))
					or string.format("%dh ago", math.floor(age / 3600))

				local changeCount = 0
				-- Delta is nested: historyEntry.delta.changes
				local changes = delta.delta and delta.delta.changes or nil
				if changes then
					if changes.bank then changeCount = changeCount + 1 end
					if changes.bags then changeCount = changeCount + 1 end
					if changes.money then changeCount = changeCount + 1 end
				end

				TOGBankClassic_Output:Response(
					"  %d. v%d->v%d (%d change(s), %s)",
					i,
					delta.baseVersion or 0,
					delta.version or 0,
					changeCount,
					ageStr
				)
			end
		end
	end
end

function TOGBankClassic_Chat:PrintProtocolInfo()
	local guild = TOGBankClassic_Guild:GetGuild()
	if not guild then
		TOGBankClassic_Output:Response("Not in a guild")
		return
	end

	TOGBankClassic_Output:Response("|cff00ffffProtocol Version Distribution|r")
	TOGBankClassic_Output:Response("")

	-- Get guild delta support
	local support = TOGBankClassic_Database:GetGuildDeltaSupport(guild)
	local threshold = PROTOCOL.DELTA_SUPPORT_THRESHOLD

	-- Count versions
	local db = TOGBankClassic_Database.db.faction[guild]
	if not db or not db.guildProtocolVersions then
		TOGBankClassic_Output:Response("No protocol data available")
		return
	end

	local now = GetServerTime()
	local onlineV1 = 0
	local onlineV2 = 0
	local allTimeV1 = 0
	local allTimeV2 = 0
	local recentMembers = {}

	for sender, info in pairs(db.guildProtocolVersions) do
		if info then
			local version = info.version or 1
			local isOnline = info.lastSeen and (now - info.lastSeen) < 600

			-- All time counts
			if version >= 2 then
				allTimeV2 = allTimeV2 + 1
			else
				allTimeV1 = allTimeV1 + 1
			end

			-- Online counts (last 10 minutes)
			if isOnline then
				if version >= 2 then
					onlineV2 = onlineV2 + 1
				else
					onlineV1 = onlineV1 + 1
				end
			end

			-- Track recent members for display
			if isOnline then
				table.insert(recentMembers, {
					name = sender,
					version = version,
					lastSeen = info.lastSeen,
				})
			end
		end
	end

	-- Sort recent members by last seen
	table.sort(recentMembers, function(a, b)
		return a.lastSeen > b.lastSeen
	end)

	-- Display online distribution
	local totalOnline = onlineV1 + onlineV2
	if totalOnline > 0 then
		TOGBankClassic_Output:Response("|cffffff00Online (last 10 minutes):|r")
		TOGBankClassic_Output:Response("  Protocol v2 (delta): %d (%.1f%%)", onlineV2, (onlineV2 / totalOnline) * 100)
		TOGBankClassic_Output:Response("  Protocol v1 (full):  %d (%.1f%%)", onlineV1, (onlineV1 / totalOnline) * 100)
		TOGBankClassic_Output:Response("  Total online: %d", totalOnline)
		TOGBankClassic_Output:Response("")
	end

	-- Display all-time distribution
	local totalAllTime = allTimeV1 + allTimeV2
	if totalAllTime > 0 then
		TOGBankClassic_Output:Response("|cffffff00All time:|r")
		TOGBankClassic_Output:Response("  Protocol v2: %d", allTimeV2)
		TOGBankClassic_Output:Response("  Protocol v1: %d", allTimeV1)
		TOGBankClassic_Output:Response("")
	end

	-- Display threshold status
	-- GLYPH-001: ASCII only -- the client's fonts have no check mark, warning sign or >= glyph, and
	-- each rendered as an empty box (operator screenshot, 2026-09-13).
	local statusIcon = support >= threshold and "|cff00ff00[OK]|r" or "|cffff0000[LOW]|r"
	local statusText = support >= threshold and "enabled" or "disabled"
	TOGBankClassic_Output:Response("%s Delta sync %s (%.1f%% %s %.0f%% threshold)",
		statusIcon, statusText, support * 100,
		support >= threshold and ">=" or "<",
		threshold * 100)

	-- Display recent members
	if #recentMembers > 0 then
		TOGBankClassic_Output:Response("")
		TOGBankClassic_Output:Response("|cffffff00Recently seen members:|r")
		local shown = 0
		for _, member in ipairs(recentMembers) do
			if shown >= 10 then
				TOGBankClassic_Output:Response("  ... and %d more", #recentMembers - shown)
				break
			end

			local age
			local seconds = now - member.lastSeen
			if seconds < 60 then
				age = "now"
			elseif seconds < 3600 then
				age = string.format("%dm ago", math.floor(seconds / 60))
			else
				age = string.format("%dh ago", math.floor(seconds / 3600))
			end

			TOGBankClassic_Output:Response("  %s: v%d (%s)", member.name, member.version, age)
			shown = shown + 1
		end
	end

	if totalOnline == 0 and totalAllTime == 0 then
		TOGBankClassic_Output:Response("No protocol version data available")
	end
end
