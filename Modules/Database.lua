GBankClassic_Database = {}

function GBankClassic_Database:Init()
    self.db = LibStub("AceDB-3.0"):New("GBankClassicDB")
end

function GBankClassic_Database:Reset(name)
    if not name then return end

    ---START CHANGES
    --self.db.factionrealm[name] = {
    self.db.faction[name] = {
    ---END CHANGES
        name = name,
        roster = {},
        alts = {},
    }

    GBankClassic_Core:Printf("Reset Database")
end

function GBankClassic_Database:ResetPlayer(name, player)
    if not name then return end
    if not player then return end

    ---START CHANGES
    --if not self.db.factionrealm[name].alts[player] then return end
    if not self.db.faction[name].alts[player] then return end

    --self.db.factionrealm[name].alts[player] = {}
    self.db.faction[name].alts[player] = {}
    ---END CHANGES

    GBankClassic_Core:Printf("Reset Player Database")
end

function GBankClassic_Database:Load(name)
    if not name then return end

    ---START CHANGES
    --local db = self.db.factionrealm[name]
    local db = self.db.faction[name]
    ---END CHANGES

    if db == nil or db.roster == nil then
        GBankClassic_Database:Reset(name)
        ---START CHANGES
        --db = self.db.factionrealm[name]
        db = self.db.faction[name]
        ---END CHANGES
    elseif db.name == nil then
        db.name = name
    end

    return db
end
