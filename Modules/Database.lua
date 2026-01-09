TOGBankClassic_Database = {}

function TOGBankClassic_Database:Init()
	self.db = LibStub("AceDB-3.0"):New("TOGBankClassicDB")
end

function TOGBankClassic_Database:Reset(name)
	if not name then
		return
	end

	---START CHANGES
	--self.db.factionrealm[name] = {
	self.db.faction[name] = {
		---END CHANGES
		name = name,
		roster = {},
		alts = {},
		requests = {},
		requestsVersion = 0,
		requestLog = {},
		requestLogSeq = {},
		requestLogApplied = {},
		requestsTombstones = {},
	}

	TOGBankClassic_Core:Printf("Reset Database")
end

function TOGBankClassic_Database:ResetPlayer(name, player)
	if not name then
		return
	end
	if not player then
		return
	end

	---START CHANGES
	--if not self.db.factionrealm[name].alts[player] then return end
	if not self.db.faction[name].alts[player] then
		return
	end

	--self.db.factionrealm[name].alts[player] = {}
	self.db.faction[name].alts[player] = {}
	---END CHANGES

	TOGBankClassic_Core:Printf("Reset Player Database")
end

function TOGBankClassic_Database:Load(name)
	if not name then
		return
	end

	---START CHANGES
	--local db = self.db.factionrealm[name]
	local db = self.db.faction[name]
	---END CHANGES

	if db == nil or db.roster == nil then
		TOGBankClassic_Database:Reset(name)
		---START CHANGES
		--db = self.db.factionrealm[name]
		db = self.db.faction[name]
		---END CHANGES
	elseif db.name == nil then
		db.name = name
	end

	if not db.requests then
		db.requests = {}
	end

	if not db.requestsVersion then
		db.requestsVersion = 0
	end
	if not db.requestLog then
		db.requestLog = {}
	end
	if not db.requestLogSeq then
		db.requestLogSeq = {}
	end
	if not db.requestLogApplied then
		db.requestLogApplied = {}
	end
	if not db.requestsTombstones then
		db.requestsTombstones = {}
	end

	return db
end
