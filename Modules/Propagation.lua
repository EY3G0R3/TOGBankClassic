-- Propagation.lua -- has the version of MY bank I just published reached anyone yet?
--
-- SYNCED-001. The operator: "figure out how to ensure the bankers data is being propagated after
-- filling orders, some kind of visual to tell the banker not to log off yet, until data is synced."
--
-- A banker fills orders at the mailbox, closes it, and the scan mints a new version of their bank
-- (Bank:MintVersion -- the one place a canon is born). That version lives on this PC alone until a
-- guildmate has RECEIVED it: the login/rescan broadcast names it, peers that are behind ask, and
-- this client serves them (Inventory/Sync.lua). If the banker logs off before anyone asked and was
-- served, every viewer keeps showing stock the banker no longer has until the banker's next login
-- republishes -- nothing is lost, but the guild is blind to the fill for that long.
--
-- WHAT COUNTS AS "RECEIVED". Three things this client can actually observe, and nothing inferred:
--   * a reply carrying this version (chain or snapshot) DRAINED to a named requester (Sync's
--     send-completion watch: delivered, not merely queued);
--   * a requester asked for it already holding it -- the no-change answer -- so it has it;
--   * a peer NAMED this exact canon for our character (a hash-list reply, a broadcast, a version
--     reply -- every path lands in Guild:NoteSelfHolder), which it could only do by holding it.
-- Each is the peer's own message or the transport's own verdict about that peer. A broadcast going
-- out is NOT counted: nobody has anything until they asked and were served.
--
-- HOW STRONG EACH IS, said plainly: the second and third are RECEIPTS -- the peer's own message
-- proves it holds the version. The first is the transport's verdict: under AceCommQueue "delivered"
-- means every chunk was handed to the client's send and none was refused, which is as far as an
-- addon message can be followed -- there is no acknowledgement from the far end. A reply that left
-- whole and was then lost in flight would count. The peer's next broadcast corrects nothing here
-- (the count only rises), but it will name an older version and the tab logic asks again.
--
-- One version at a time: the newest. Minting a new version replaces the tracker whole -- what
-- matters is whether the CURRENT contents have reached anyone, and a peer holding the previous
-- version is behind again. A consumer (the on-screen indicator, the logout warning) reads
-- `Status()`; `RegisterCallback` hears every change so the indicator repaints without polling.
--
-- PROP-PERSIST-001: SAVED per character, and restored at login while the held canon is still the
-- one it describes. This used to say "session-scoped, deliberately not saved: at the next login the
-- version is republished anyway" -- and the operator, 2026-09-13, having logged out to test it:
-- "we should have this live through so they know no one synced the data if they are disconnected
-- or any other reason." A disconnect or a crash is exactly when the banker never saw the line, so
-- the fact that nobody has the version must be there when they come back. The login broadcast
-- still goes out; a peer that names the canon then counts as SEEN and the line goes green as before.

TOGBankClassic_Propagation = {}
local P = TOGBankClassic_Propagation

-- TWO COUNTS, because they are two different facts (peer review B1). SENT: a reply carrying this
-- version drained to a peer -- the transport's verdict, "left this client whole". SEEN: a peer's
-- OWN message named this version -- it is held over there. The banker's question is answered by
-- SEEN; SENT is the progress towards it. `holders[peer]` is "sent" or "seen" (seen wins).
P.current   = nil   -- { player=, canon=, publishedAt= (server time), since= (GetTime), holders={}, sent=0, seen=0, lastHolderAt= (GetTime) }
P.callbacks = {}

local function Dbg(tag, fmt, ...)
	TOGBankClassic_Output:Debug("SYNC", tag, fmt, ...)
end

local fire   -- defined below Save/Restore, which it calls and Restore calls

--- PROP-PERSIST-001: the per-character slot the tracker is saved in, or nil before Options is up.
local function slot()
	local O = TOGBankClassic_Options
	local db = O and O.db
	return db and db.char or nil
end

--- Write the tracker to the character's SavedVariables (or clear it). `since` is a GetTime()
--- reading and meaningless across sessions; it is rebuilt from publishedAt on restore.
function P:Save()
	local char = slot()
	if not char then return false end
	local cur = self.current
	if not cur then char.propagation = nil return true end
	local holders = {}
	for peer, how in pairs(cur.holders) do holders[peer] = how end
	char.propagation = {
		player = cur.player, canon = cur.canon, publishedAt = cur.publishedAt,
		holders = holders, sent = cur.sent, seen = cur.seen,
	}
	return true
end

--- Bring a saved tracker back at login, if it still describes the version this character holds:
--- same player, same canon as the record's current inventoryHashV2 (a version minted since --
--- impossible offline, but a wiped or rolled-back record is not -- means the saved one is stale
--- and is dropped). A tracker that had already been SEEN is dropped too: the question it answers
--- ("has it reached anyone?") was answered yes, and a green line from a past session is noise.
--- Idempotent: nothing happens once a tracker is live this session.
---@return boolean restored
function P:Restore()
	if self.current then return false end
	local char = slot()
	local saved = char and char.propagation
	if type(saved) ~= "table" then return false end
	local G = TOGBankClassic_Guild
	local me = G and G.GetNormalizedPlayer and G:GetNormalizedPlayer()
	-- The record is not LOADED yet (Guild:Init has not run Database:Load): nothing can be judged,
	-- and dropping the save here is what lost the line on the operator's first relog -- the roster
	-- init hook ran before the guild record was up. Leave it for the call that follows the load.
	if not (G and G.Info and G.Info.alts and me) then return false end
	local alt = G.Info.alts[me]
	local held = alt and alt.inventoryHashV2
	if saved.player ~= me or type(saved.canon) ~= "string" or saved.canon ~= held or (tonumber(saved.seen) or 0) > 0 then
		char.propagation = nil
		Dbg("PROPAGATION", "[PROP-PERSIST-001] saved tracker dropped (player=%s canon=%s held=%s seen=%s)",
			tostring(saved.player), tostring(saved.canon), tostring(held), tostring(saved.seen))
		return false
	end
	local holders, sent = {}, 0
	for peer, how in pairs(saved.holders or {}) do
		if how == "sent" then holders[peer] = "sent"; sent = sent + 1 end
	end
	local publishedAt = tonumber(saved.publishedAt) or GetServerTime()
	self.current = {
		player = me, canon = saved.canon, publishedAt = publishedAt,
		since = GetTime() - math.max(0, GetServerTime() - publishedAt),
		holders = holders, sent = sent, seen = 0,
	}
	Dbg("PROPAGATION", "[PROP-PERSIST-001] %s's %s from %s restored -- still unconfirmed (sent to %d)",
		me, saved.canon, date("%H:%M", publishedAt), sent)
	fire()
	return true
end

fire = function()
	P:Save()
	for owner, fn in pairs(P.callbacks) do
		local ok, err = pcall(fn, owner)
		if not ok then Dbg("PROPAGATION", "[SYNCED-001] listener raised: %s", tostring(err)) end
	end
end

--- A new version of OUR OWN bank was minted. Called from Bank:MintVersion; a mint for any other
--- name (none exists in production -- INV2-ISOLATE-001 -- but a spec may drive one) is ignored.
---@param player string normalized name the version belongs to
---@param canon string the canon just minted
function P:OnPublished(player, canon)
	local G = TOGBankClassic_Guild
	-- A spec driving MintVersion with a Guild stand-in has no player to compare against: not ours.
	if not (G and G.GetNormalizedPlayer) then return false end
	if type(canon) ~= "string" or not player or player ~= G:GetNormalizedPlayer() then return false end
	self.current = {
		player      = player,
		canon       = canon,
		publishedAt = GetServerTime(),
		since       = GetTime(),
		holders     = {},
		sent        = 0,
		seen        = 0,
	}
	Dbg("PROPAGATION", "[SYNCED-001] %s published %s -- waiting for a guildmate to receive it", player, canon)
	fire()
	return true
end

--- A peer is known to hold `canon` of `player`'s bank. `how` is "seen" (the peer's own message
--- named it -- a receipt) or "sent" (a reply carrying it drained to the peer -- the transport's
--- verdict). Ignored unless it is the version being tracked; a peer counts once per fact, and a
--- peer already SEEN is not re-counted as SENT.
---@param player string normalized name
---@param canon string
---@param peer string normalized peer name
---@param how string|nil "seen" (default) or "sent"
---@return boolean counted true when this call changed a count
function P:NoteHolder(player, canon, peer, how)
	local cur = self.current
	if not cur or type(peer) ~= "string" or peer == "" then return false end
	local G = TOGBankClassic_Guild
	peer = G:NormalizeName(peer) or peer
	if player ~= cur.player or canon ~= cur.canon or peer == cur.player then return false end
	how = how == "sent" and "sent" or "seen"
	local had = cur.holders[peer]
	if had == "seen" or had == how then return false end
	cur.holders[peer] = how
	if how == "seen" then
		cur.seen = cur.seen + 1
		if had == "sent" then cur.sent = cur.sent - 1 end
	else
		cur.sent = cur.sent + 1
	end
	cur.lastHolderAt = GetTime()
	Dbg("PROPAGATION", "[SYNCED-001] %s: %s's %s (%s; sent %d, seen %d)", peer, player, canon, how, cur.sent, cur.seen)
	if how == "seen" and cur.seen == 1 then
		TOGBankClassic_Output:Info("Your bank update has reached %s -- safe to log off.", (peer:match("^([^%-]+)") or peer))
	end
	fire()
	return true
end

--- Guildmates online other than this character -- the people who COULD receive the version.
---@return number
function P:OnlinePeerCount()
	local G = TOGBankClassic_Guild
	local me = G:GetNormalizedPlayer()
	local n = 0
	for name, m in pairs(G.memberRoster or {}) do
		if m and m.isOnline and name ~= me then n = n + 1 end
	end
	return n
end

--- The one question. States:
---   "idle"    nothing published this session (or not a banker) -- nothing to show;
---   "pending" published, nobody has CONFIRMED it (cur.sent may be > 0: replies left, no receipt
---             yet), and at least one guildmate is online to receive it;
---   "alone"   published, nobody has confirmed it, and no guildmate is online -- nobody CAN;
---   "synced"  at least one guildmate's own message named the current version (cur.seen > 0).
---@return string state, table|nil current, number onlinePeers
function P:Status()
	local cur = self.current
	local online = self:OnlinePeerCount()
	if not cur then return "idle", nil, online end
	if cur.seen > 0 then return "synced", cur, online end
	if online == 0 then return "alone", cur, online end
	return "pending", cur, online
end

--- Seconds since the tracked version was published (GetTime clock), 0 when nothing is tracked.
function P:Elapsed()
	local cur = self.current
	return cur and math.max(0, GetTime() - cur.since) or 0
end

--- Hear every change: a publish, a new holder. fn(owner) is called synchronously.
function P:RegisterCallback(owner, fn)
	if owner == nil or type(fn) ~= "function" then return false end
	self.callbacks[owner] = fn
	return true
end

function P:UnregisterCallback(owner)
	if owner == nil then return false end
	local had = self.callbacks[owner] ~= nil
	self.callbacks[owner] = nil
	return had
end

--- PLAYER_CAMPING: the player started the logout countdown. Say so, once, if the current version
--- has reached nobody. Advisory -- nothing here cancels a logout.
function P:OnCamping()
	local state, cur, online = self:Status()
	if state == "pending" then
		TOGBankClassic_Output:Warn("Your bank update from %s has not been confirmed by any guildmate yet (sent to %d, %d online). Stay logged in a moment so it can sync.",
			date("%H:%M", cur.publishedAt), cur.sent, online)
		return true
	elseif state == "alone" then
		TOGBankClassic_Output:Warn("Your bank update from %s has not reached anyone -- no guildmate is online to receive it. It will be published again at your next login.",
			date("%H:%M", cur.publishedAt))
		return true
	end
	return false
end

--- Test / logout reset.
function P:Reset()
	self.current = nil
	fire()
end
