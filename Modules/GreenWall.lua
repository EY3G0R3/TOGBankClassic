TOGBankClassic_GreenWall = {}

-- XGUILD-SYNC-001 step 7 (docs/XGUILD_SYNC.md 4.6): THE GREENWALL NUDGE.
--
-- GreenWall bridges guild chat between the guilds of a confederation over a hidden custom CHANNEL and
-- exposes that channel to other addons (GreenWall/API.lua: `GreenWallAPI.SendMessage(addon, message)`,
-- `AddMessageHandler(fn, addon, priority)` with `fn(addon, sender, message, echo, isOwnGuild)`,
-- `GetChannelNumbers()`). It cannot carry TOGBank's sync -- a CHANNEL send is hardware-gated on
-- Classic, a segment is 255 bytes, and the handler is not told which guild spoke (XGUILD_SYNC.md 1.1)
-- -- but ONE short line from a click can ride it: the player opening the Guild Bank window. A
-- federated client hearing that line treats it as a TOGBank message from the sender -- the same
-- sighting an addon whisper leaves (Guild:UpdateOnlineMember) -- so the sender's guild is asked for
-- its hash list NOW (Guild:OnFederationPeerProven) instead of on the next ten-minute cycle. First
-- contact between two guilds' banks then costs one click rather than up to a cycle. Without GreenWall
-- nothing here runs and nothing is owed.
--
-- THE HARDWARE GATE IS THE CALLER'S. `Nudge` is called from `Browse:Toggle` ONLY -- the minimap
-- button, `/togbank` typed in chat, the legacy window's Browse button: a click or a keypress each.
-- Never from a timer or an event: GreenWall sends with SendChatMessage(..., 'CHANNEL'), which the
-- client blocks outside a hardware event, and a segment GreenWall could not send is PARKED for its
-- next flush (GwChannel:tl_flush), which may then run from its own timer. `Bridge` therefore also
-- refuses while the guild channel is not joined (its number is 0, GwChannel:is_connected): a parked
-- segment is exactly that later send.
--
-- THE LINE: `hlq:<this client's addon version>` -- "I hold a hash list, ask me", plus the version the
-- receiver's peer picker needs (Guild:PeerSpeaksDataLeg reads what the hlb2 field feeds; this feeds
-- the same record), so a nudge from a release too old to sync with is heard and not asked.

-- NS-001: file-scope alias, so a foreign global of the same name cannot be read instead.
local TIMER_INTERVALS = TOGBankClassic_Constants.TIMER_INTERVALS

local ADDON  = "TOGBankClassic"   -- the TOC name GreenWall validates the caller against
local PREFIX = "hlq:"

--- At most one nudge per sync cycle, so a player toggling the window costs the channel one line.
TOGBankClassic_GreenWall.NUDGE_COOLDOWN = TIMER_INTERVALS.VERSION_BROADCAST

--- GreenWall's API when GreenWall is loaded and has a channel JOINED; nil otherwise. The channel query
--- indexes GreenWall's own config, nil until its ADDON_LOADED, hence the pcall.
---
--- A NON-ZERO NUMBER IS THE WHOLE TEST, and it is what the parked-segment hazard turns on:
--- `GwChannel:is_connected` refreshes `self.number` from `GetChannelName` and calls the channel
--- connected only when it is non-zero (`GreenWall/Channel.lua:125-138`), so a channel that exists but
--- is not joined reports 0 -- and a send on it is PARKED for the next flush, which is the later,
--- non-hardware send this gate exists to prevent. `GetChannelNumbers` returns guild then officer,
--- each only when present (`API.lua:132-141`), so WHICH entry is which is not knowable here and is not
--- asked: any joined channel answers "GreenWall is up". Peer Review 8e933d44 read this as a caveat
--- defending a value the code does not use and suggested `#numbers == 0`; that would accept a channel
--- whose number is 0, which is exactly the un-joined case, so the non-zero test stays and only the
--- claim about WHICH channel is gone.
---@return table|nil api
function TOGBankClassic_GreenWall:Bridge()
	local api = _G.GreenWallAPI
	if type(api) ~= "table" or type(api.SendMessage) ~= "function" or type(api.GetChannelNumbers) ~= "function" then
		return nil
	end
	local ok, numbers = pcall(api.GetChannelNumbers)
	if not ok or type(numbers) ~= "table" then return nil end
	for _, n in ipairs(numbers) do
		if (tonumber(n) or 0) ~= 0 then return api end
	end
	return nil
end

--- Register the receive handler with GreenWall. Once; from Core's OnInitialize. GreenWall is an
--- OptionalDep, so when present it has loaded first; absent, nothing is registered.
---@return boolean listening
function TOGBankClassic_GreenWall:Init()
	if self.handlerId then return true end
	local api = _G.GreenWallAPI
	if type(api) ~= "table" or type(api.AddMessageHandler) ~= "function" then return false end
	local ok, id = pcall(api.AddMessageHandler, function(...) return TOGBankClassic_GreenWall:OnMessage(...) end, ADDON, 0)
	if not ok then
		TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "GreenWall refused the nudge handler: %s", tostring(id))
		return false
	end
	self.handlerId = id
	TOGBankClassic_Output:Debug("PROTOCOL", "INIT", "GreenWall bridge: listening for sister-guild nudges")
	return true
end

--- FROM A HARDWARE EVENT ONLY (see the header). Sends the line when the sister-guild bank is on (a
--- listed sister guild exists), GreenWall's channel is up and the last nudge is a cycle old.
---@return boolean sent, string|nil why not
function TOGBankClassic_GreenWall:Nudge()
	local G = TOGBankClassic_Guild
	if not (G and G.SisterGuildKeys and G.RosterLib) then return false, "no federation" end
	if #G:SisterGuildKeys(G.RosterLib()) == 0 then return false, "no sister guilds" end   -- XGUILD-SWITCH-001: off, or none listed
	local api = self:Bridge()
	if not api then return false, "no bridge" end
	local now = GetServerTime() or 0
	if self.lastNudge and now - self.lastNudge < self.NUDGE_COOLDOWN then return false, "cooldown" end
	local version = (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or ""
	local ok, err = pcall(api.SendMessage, ADDON, PREFIX .. version)
	if not ok then
		-- THE COOLDOWN IS STAMPED ON A REFUSAL TOO (Peer Review 8e933d44): the one configuration that
		-- reaches here and always will -- an officer channel joined and no guild channel, where
		-- SendMessage indexes a nil `gw.config.channel.guild` -- would otherwise pay a failed call and
		-- a debug line on EVERY window open, forever. Stamping bounds it to once per cycle. Only THIS
		-- path stamps: a refusal before the send (no bridge, no sister guilds) leaves the cooldown
		-- alone, so GreenWall finishing its load a moment later is not made to wait a cycle.
		self.lastNudge = GetServerTime() or 0
		TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "GreenWall refused the nudge: %s", tostring(err))
		return false, "refused"
	end
	self.lastNudge = now
	TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "nudged the federation through GreenWall (%s)", version ~= "" and version or "version unknown")
	return true
end

--- GreenWall's handler: `fn(addon, sender, message, echo, isOwnGuild)`. Returns whether the line was
--- acted on. Our own echo and a home guildmate's line are ignored (the home guild has its own cycle);
--- so is a sender the roster library does not place in a LISTED sister guild -- GreenWall's
--- confederation and Guild Roster's sister list are two configurations that may disagree, and a name
--- heard on a channel is a claim, not the roster's word.
---@return boolean acted
function TOGBankClassic_GreenWall:OnMessage(addon, sender, message, echo, isOwnGuild)
	if addon ~= ADDON or echo or isOwnGuild then return false end
	if type(message) ~= "string" or message:sub(1, #PREFIX) ~= PREFIX then return false end
	local G = TOGBankClassic_Guild
	if not (G and G.NormalizeName and G.GuildOf and G.UpdateOnlineMember) then return false end
	local norm = G:NormalizeName(sender)
	if not norm or norm == G:GetNormalizedPlayer() then return false end
	if (G.IsHomeMember and G:IsHomeMember(norm)) or not G:GuildOf(norm) then
		TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "GreenWall nudge from %s, who is not in a listed sister roster; ignored", norm)
		return false
	end
	local version = message:sub(#PREFIX + 1)
	if version ~= "" and G.NotePeerAddonVersion then G:NotePeerAddonVersion(norm, version) end
	TOGBankClassic_Output:Debug("PROTOCOL", "FEDERATION", "GreenWall nudge from %s (%s)", norm, version ~= "" and version or "version unknown")
	-- The sighting: what a TOGBank whisper from them leaves, federation ask included.
	G:UpdateOnlineMember(norm, true, "greenwall-nudge")
	return true
end
