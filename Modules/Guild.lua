GBankClassic_Guild = {}

GBankClassic_Guild.Info = nil

---START CHANGES
function GetPlayerWithNormalizedRealm(name)
    if(string.match(name, "(.*)%-(.*)")) then
		return name
	end
	return name.."-"..GetNormalizedRealmName("player")
end

-- wrapper to ensure consistent normalization across the addon
local function NormalizePlayerName(name)
    if not name then return nil end
    -- Canonicalize hyphen spacing: convert "Name - Realm" or "Name- Realm" to "Name-Realm"
    local normalized = string.gsub(name, "%s*%-%s*", "-")
    if string.match(normalized, "^(.-)%-(.-)$") then
        return normalized
    end
    -- If helper exists, use it
    if GetPlayerWithNormalizedRealm then
        return GetPlayerWithNormalizedRealm(name)
    end
    -- Fallback: append current realm
    return name.."-"..GetNormalizedRealmName("player")
end
-- expose for other modules
GBankClassic_Guild.NormalizePlayerName = NormalizePlayerName
---END CHANGES

function GBankClassic_Guild:GetPlayer()
    ---START CHANGES
    --return UnitName("player")
    if GBankClassic_Bank.player then return GBankClassic_Bank.player end

    -- The below code should never be called, but is here for safety
    local function try()
      local name, realm = UnitName("player"), GetNormalizedRealmName()
      if name and realm then
        GBankClassic_Bank.player = name .. "-" .. realm
        return true
      end
    end
    if try() then return GBankClassic_Bank.player end
    local count, max, delay, timer = 0, 10, 15
    timer = C_Timer.NewTicker(delay, function()
      count = count + 1
      if try() or count >= max then
        if timer then timer:Cancel() end
      end
    end)
  
    return nil
    ---END CHANGES
end

function GBankClassic_Guild:GetGuild()
    return IsInGuild("player") and GetGuildInfo("player") or nil
end

function GBankClassic_Guild:GetPlayerInfo(name)
    for i = 1, GetNumGuildMembers() do
        local playerRealm, _, _, _, _, _, _, _, _, _, class = GetGuildRosterInfo(i)
        player, _ = string.match(playerRealm, "(.*)%-(.*)")
        ---START CHANGES
        --if player == name then
        if playerRealm == name then
        ---END CHANGES
            return class
        end
    end
    return nil
end

function GBankClassic_Guild:Reset(name)
    if not name then return end

    GBankClassic_UI_Inventory:Close()
    GBankClassic_Database:Reset(name)
    self.Info = GBankClassic_Database:Load(name)
end

function GBankClassic_Guild:Init(name)
    if not name then return false end
    if self.Info and self.Info.name == name then return false end

    self.hasRequested = false
    self.requestCount = 0

    self.Info = GBankClassic_Database:Load(name)
    if self.Info then return true end

    self:Reset(name)
    return true
end

-- Cleanup malformed entries in the saved guild data
-- This attempts to be conservative:
-- - remove alts that are not tables
-- - remove per-alt entries that have badly shaped bank/bags item lists
-- - ensure roster.alts is a proper array
-- Returns number of alts cleaned
function GBankClassic_Guild:CleanupMalformedAlts()
    if not self.Info or not self.Info.alts then return 0 end

    local cleaned = 0
    for name, alt in pairs(self.Info.alts) do
        local remove = false
        if type(alt) ~= "table" then
            remove = true
        else
            -- Ensure version is present, but malformed nested fields are problematic
            if alt.bank and type(alt.bank) == "table" and alt.bank.items then
                -- alt.bank.items should be an array or a map of items with ID fields; remove any empty entries
                for k, v in pairs(alt.bank.items) do
                    if not v or type(v) ~= "table" or not v.ID then
                        alt.bank.items[k] = nil
                    end
                end
            end
            if alt.bags and type(alt.bags) == "table" and alt.bags.items then
                for k, v in pairs(alt.bags.items) do
                    if not v or type(v) ~= "table" or not v.ID then
                        alt.bags.items[k] = nil
                    end
                end
            end
            -- If after cleaning the alt has no meaningful fields (no version, no money, no items), remove it
            local hasData = false
            if alt.version then hasData = true end
            if alt.money then hasData = true end
            if alt.bank and next(alt.bank.items or {}) then hasData = true end
            if alt.bags and next(alt.bags.items or {}) then hasData = true end
            if not hasData then remove = true end
        end

        if remove then
            self.Info.alts[name] = nil
            cleaned = cleaned + 1
        end
    end

    -- Ensure roster.alts is a proper array (remove nils and non-strings)
    if self.Info.roster and self.Info.roster.alts then
        local new_alts = {}
        for _, v in pairs(self.Info.roster.alts) do
            if type(v) == "string" and v ~= "" then
                table.insert(new_alts, v)
            end
        end
        self.Info.roster.alts = new_alts
    end

    return cleaned
end

function GBankClassic_Guild:GetBanks()
    local hasBanks = false
    local banks = {}
    for i = 1, GetNumGuildMembers() do
        ---START CHANGES
        -- Allow use of either public or officer note, and allow the note to contain "gbank" instead of requiring it to be equal to "gbank" only (and no other characters)
        --local name, _, _, _, _, _, _, officer_note, _, _, _ = GetGuildRosterInfo(i)
        local name, _, _, _, _, _, publicNote, officer_note, _, _, _ = GetGuildRosterInfo(i)
        --if officer_note == "gbank" then
        if publicNote ~= nil or officer_note ~= nil then
            if string.match(publicNote, "(.*)gbank(.*)") or string.match(officer_note, "(.*)gbank(.*)") then
                --local player, _ = string.match(name, "(.*)%-(.*)")
                table.insert(banks, name)
                ---END CHANGES
                hasBanks = true
            end
        end
    end
    if not hasBanks then return nil end
    return banks
end

function GBankClassic_Guild:IsBank(player)
    local banks = GBankClassic_Guild:GetBanks()
    if banks == nil then return false end

    local isBank = false
    for _, v in pairs(banks) do
        if v == player then
            isBank = true
        end
    end

    return isBank
end

function GBankClassic_Guild:CheckVersion(version)
    if self.Info then return false end

    if version > self.Info.roster.version then
        return false
    end

    return true
end

function GBankClassic_Guild:GetVersion()
    if not self.Info then return nil end

    local versionInfo = GetAddOnMetadata("GBankClassic", "Version"):gsub("%.", "")
    local versionNumber = tonumber(versionInfo)
    local data = {
        addon = versionNumber,
        roster = nil,
        alts = {}
    }

    if self.Info.name then
        data.name = self.Info.name
    end

    if self.Info.roster.version then
        data.roster = self.Info.roster.version
    end

    for k, v in pairs(self.Info.alts) do
        ---START CHANGES
        -- Only store bank alt data if the sender is a bank alt
        --data.alts[k] = v.version
        if type(v) == "table" and v.version then
            data.alts[k] = v.version
        end
        ---END CHANGES
    end

    return data
end

function GBankClassic_Guild:RequestRosterSync(player, version)
    self.hasRequested = true
    if self.requestCount == nil then self.requestCount = 1 else self.requestCount = self.requestCount + 1 end
    local data = GBankClassic_Core:Serialize({player = player, type = "roster", version = version})
    GBankClassic_Core:SendCommMessage("gbank-r", data, "Guild", nil, "BULK")
end

function GBankClassic_Guild:RequestAltSync(player, name, version)
    self.hasRequested = true
    if self.requestCount == nil then self.requestCount = 1 else self.requestCount = self.requestCount + 1 end
    local data = GBankClassic_Core:Serialize({player = player, type = "alt", name = name, version = version})
    GBankClassic_Core:SendCommMessage("gbank-r", data, "Guild", nil, "BULK")
end

function GBankClassic_Guild:SendRosterData()
    local data = GBankClassic_Core:Serialize({type = "roster", roster = self.Info.roster})
    GBankClassic_Core:SendCommMessage("gbank-d", data, "Guild", nil, "BULK")
end

function GBankClassic_Guild:ReceiveRosterData(roster)
    if not self.Info then return end
    if self.Info.roster.version and roster.version and roster.version < self.Info.roster.version then return end
    if self.hasRequested then
      if self.requestCount == nil then self.requestCount = 0 else self.requestCount = self.requestCount - 1 end
        if self.requestCount == 0 then
            self.hasRequested = false
            shutup = GBankClassic_Options:GetBankVerbosity()
            if shutup == false then
                GBankClassic_Core:Print("Sync completed.")
            end
        end
    end

    self.Info.roster = roster
end

-- returns true if the given normalized sender has a public or officer note containing 'gbank'
function GBankClassic_Guild:SenderHasGbankNote(sender)
    if not sender then return false end
    for i = 1, GetNumGuildMembers() do
        local playerRealm, _, _, _, _, _, publicNote, officer_note = GetGuildRosterInfo(i)
        if playerRealm then
            local norm = NormalizePlayerName(playerRealm)
            if norm == sender then
                if (publicNote and string.match(publicNote, "(.*)gbank(.*)")) or (officer_note and string.match(officer_note, "(.*)gbank(.*)")) then
                    return true
                end
            end
        end
    end
    return false
end

function GBankClassic_Guild:SendAltData(name, force)
    if not name then return end
    local norm = NormalizePlayerName(name)
    if not self.Info or not self.Info.alts or not self.Info.alts[norm] then return end

    -- Bump the version so this transfer wins conflict resolution
    if force then
        self.Info.alts[norm].version = GetServerTime()
    end

    local data = GBankClassic_Core:Serialize({type = "alt", name = norm, alt = self.Info.alts[norm]})
    ---START CHANGES
    GBankClassic_Core:SendCommMessage("gbank-d", data, "Guild", nil, "BULK", OnChunkSent)
end

---START CHANGES
function OnChunkSent(arg, sent, total)
    shutup = GBankClassic_Options:GetBankVerbosity()
    if shutup == false then
        if sent <= 255 then GBankClassic_Core:Print("Sharing guild bank data...") end
        if sent == total then GBankClassic_Core:Print("Sharing guild bank data has completed.") end
    end
end
---END CHANGES

function GBankClassic_Guild:ReceiveAltData(name, alt)
    if not self.Info then return end

    -- Sanitize incoming alt data
    local function sanitizeAlt(a)
        if not a or type(a) ~= "table" then return nil end
        if a.bank and type(a.bank) == "table" and a.bank.items then
            for k, v in pairs(a.bank.items) do
                if not v or type(v) ~= "table" or not v.ID then a.bank.items[k] = nil end
            end
        end
        if a.bags and type(a.bags) == "table" and a.bags.items then
            for k, v in pairs(a.bags.items) do
                if not v or type(v) ~= "table" or not v.ID then a.bags.items[k] = nil end
            end
        end
        return a
    end

    alt = sanitizeAlt(alt)
    if not alt then return end

    local norm = NormalizePlayerName(name)
    local existing = self.Info.alts[norm]
    if existing and alt.version ~= nil and existing.version ~= nil and alt.version < existing.version then return end

    -- Accept incoming if newer version
    -- If same version, accept the alt with more items
    local function itemCount(a)
        local c = 0
        if a and a.bank and a.bank.items then for _, v in pairs(a.bank.items) do if v and v.ID then c = c + 1 end end end
        if a and a.bags and a.bags.items then for _, v in pairs(a.bags.items) do if v and v.ID then c = c + 1 end end end
        return c
    end

    if existing and existing.version and alt.version and alt.version < existing.version then
        -- Incoming is older; ignore
        return
    elseif existing and existing.version and alt.version and alt.version == existing.version then
        -- Tie-breaker: choose the one with more items
        if itemCount(alt) <= itemCount(existing) then
            return
        end
    end

    if self.Info.alts[name] and alt.version ~= nil and alt.version < self.Info.alts[name].version then return end
    if self.hasRequested then
        if self.requestCount == nil then self.requestCount = 0 else self.requestCount = self.requestCount - 1 end
        if self.requestCount == 0 then
            self.hasRequested = false
            shutup = GBankClassic_Options:GetBankVerbosity()
            if shutup == false then
                GBankClassic_Core:Print("Sync completed.")
            end
        end
    end

    self.Info.alts[norm] = alt

end

---START CHANGES
function s(a)
    local b=0
    for c,d in pairs(a) do 
        b=b+1 
    end
    return b 
end 

function GBankClassic_Guild:Hello(type)
    local addon_data = GBankClassic_Guild:GetVersion()
    local current_data = GBankClassic_Guild.Info
    if addon_data and current_data then
        local roster_alts = ""
        local guild_bank_alts = ""
        local hello = "Hi! "..GBankClassic_Guild:GetPlayer().." is using version "..addon_data.addon.."."
        if s(current_data.roster) > 0 and s(current_data.alts) > 0 then
            for _, v in pairs(current_data.roster.alts) do if roster_alts ~= "" then roster_alts = roster_alts..", " end roster_alts = roster_alts..v end
            if roster_alts ~= "" then roster_alts = " ("..roster_alts..")" end
            for k, _ in pairs(current_data.alts) do if guild_bank_alts ~= "" then guild_bank_alts = guild_bank_alts..", " end guild_bank_alts = guild_bank_alts..k end 
            if guild_bank_alts ~= "" then guild_bank_alts = " ("..guild_bank_alts..")" end
            if current_data.roster.alts then 
                hello = hello.."\n"
                hello = hello.."I know about "..#current_data.roster.alts.." guild bank alts"..roster_alts.." on the roster."
                hello = hello.."\n"
                hello = hello.."I have guild bank data from "..s(current_data.alts).." alts"..guild_bank_alts.."." 
            end
        else
            hello = hello.." I know about 0 guild bank alts on the roster, and have guild bank data from 0 alts."
        end
        GBankClassic_Core:Print(hello)
        local data = GBankClassic_Core:Serialize(hello)
        if type ~= "reply" then
            GBankClassic_Core:SendCommMessage("gbank-h", data, "Guild", nil, "BULK")
        else
            GBankClassic_Core:SendCommMessage("gbank-hr", data, "Guild", nil, "BULK")
        end
    end
end

function GBankClassic_Guild:Wipe(type)
    local guild = GBankClassic_Guild:GetGuild()
    if not guild and not CanViewOfficerNote() then return end
    local wipe = "I wiped all addon data from "..guild.."."
    GBankClassic_Guild:Reset(guild)

    local data = GBankClassic_Core:Serialize(wipe)
    if type ~= "reply" then
        GBankClassic_Core:SendCommMessage("gbank-w", data, "Guild", nil, "BULK")
    else
        GBankClassic_Core:SendCommMessage("gbank-wr", data, "Guild", nil, "BULK")
    end
end

function GBankClassic_Guild:WipeMine(type)
    local guild = GBankClassic_Guild:GetGuild()
    if not guild then return end
    local wipe = "I wiped all my addon data from "..guild.."."
    GBankClassic_Guild:Reset(guild)
end

function GBankClassic_Guild:Share(type)
    local guild = GBankClassic_Guild:GetGuild()
    if not guild then return end
    self.Info = GBankClassic_Database:Load(guild)
    local player = GBankClassic_Guild:GetPlayer()
    local normPlayer = (GBankClassic_Guild and GBankClassic_Guild.NormalizePlayerName) and GBankClassic_Guild.NormalizePlayerName(player) or player
    local share = "I'm sharing my bank data. Share yours please."
    if not self.Info.alts[normPlayer] then if type ~= "reply" then share = "Share your bank data please." else share = "Nothing to share." end end
    if self.Info.alts[normPlayer] and GBankClassic_Guild:IsBank(normPlayer) then GBankClassic_Guild:SendAltData(normPlayer) end

    local data = GBankClassic_Core:Serialize(share)
    if type ~= "reply" then
        GBankClassic_Core:SendCommMessage("gbank-s", data, "Guild", nil, "BULK")
    else
        GBankClassic_Core:SendCommMessage("gbank-sr", data, "Guild", nil, "BULK")
    end
end

function GBankClassic_Guild:AuthorRosterData()
  if not self.Info then return end
  local info = self.Info
  local isBank = false
  local banks = GBankClassic_Guild:GetBanks()
  local player = GBankClassic_Guild:GetPlayer()
  if banks then
      for _, v in pairs(banks) do
          if v == player then
              isBank = true
              break
          end
      end
  end
  if isBank or CanViewOfficerNote() then
      info.roster.alts = banks
      info.roster.version = GetServerTime()
      if not banks then info.roster.version = nil end
      GBankClassic_Guild:SendRosterData()
      if banks then
          local characterNames = {}
          for _, bankChar in pairs(banks) do
              table.insert(characterNames, bankChar)
          end
          if #characterNames > 0 then
              GBankClassic_Core:Print("Sent updated roster containing the follow banks: " .. table.concat(characterNames, ", "))
          else
              GBankClassic_Core:Print("Sent empty roster.")
          end
      else
          GBankClassic_Core:Print("Sent empty roster.")
      end
  else
      GBankClassic_Core:Print("You lack permissions to share the roster.")
      return
  end
end

function GBankClassic_Guild:SenderIsGM(player)
    if not player then return false end
    if not IsInGuild() then return false end
    for i = 1, GetNumGuildMembers() do
        local playerRealm, _, rankIndex, _, _, _, publicNote, officer_note = GetGuildRosterInfo(i)
        if playerRealm then
            local norm = GBankClassic_Guild.NormalizePlayerName(playerRealm)
            if rankIndex == 0 and norm == player then
                return true
            end
        end
    end
    return false
end
---END CHANGES
