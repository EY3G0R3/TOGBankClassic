-- Switches.lua — the dev-switch registry (INV2).
--
-- Deliberately NOT added to the bare-global FEATURES table in Constants.lua. That table already
-- carries FEATURES.DELTA_ENABLED / FORCE_DELTA_SYNC / FORCE_FULL_SYNC — switches from a previous
-- round of exactly this exercise that outlived it and are still there. Audit NS-001 flags those
-- eleven bare globals for namespacing; adding to them would make that worse.
--
-- Every switch declares what it gates and when it should be deleted. A switch that outlives its
-- rework is a bug, not a feature, and `retire` is what makes that checkable rather than
-- remembered.
--
-- State lives in db.global so it survives a reload and is per-account, not per-character: a
-- half-migrated account with V2 on for one character and off for another would write both
-- storage formats from the same machine.

TOGBankClassic_Switches = {}
local Switches = TOGBankClassic_Switches

--- Registry. `default` applies until the user (or a later release) changes it.
--- `requires` names another switch that must be on for this one to have any effect.
--- `pending` marks a switch NOTHING READS YET -- see the note on `dualWrite`. A switch carrying it
--- is reported as not-yet-active in the listing, and `switches_spec` requires it of any switch with
--- no reader in the shipped source. That pairing is the point: a switch may be staged ahead of the
--- code that uses it, but it may not silently claim an effect it does not have.
Switches.registry = {
	-- INV2 step 9. BOTH DEFAULT ON, and they are no longer optional in the way the word "switch"
	-- suggests: the legacy link wire format is DELETED in both directions (the 2026-09-09 directive),
	-- so with these off the addon has no send path and no receive path at all. Turning them off is a
	-- diagnostic, not a rollback -- there is nothing left to roll back TO.
	inventoryV2 = {
		default     = true,
		description = "Read from and write to the V2 tuple store instead of the legacy inventory DB",
		retire      = "when V2 is the only storage format (INV2-RETIRE-001)",
	},
	sendV2Wire = {
		default     = true,
		description = "Emit tuple payloads on the wire. The legacy link format is gone, so off means send nothing",
		retire      = "together with the switch machinery, once V2 has been default for three releases",
	},
	-- Read by `Scan:ScanAll`, which is reached from `Bank:Scan`. That chain was broken for one
	-- session: INV2-VAULT-001 replaced the ScanAll call with per-source ScanBags/ScanBank calls,
	-- orphaning ScanAll and leaving this switch read only by unreachable code -- a switch the
	-- listing still reported as ON, with a description promising it was maintaining the legacy DB.
	-- ScanAll now returns the per-source shape itself, so there is one scan entry point again.
	-- `switches_spec`'s wiring guard is what caught it and is what stops it recurring.
	dualWrite = {
		default     = true,
		requires    = "inventoryV2",
		description = "Also keep the legacy DB current from the same scan, so a rollback lands on live data",
		retire      = "together with the legacy DB (INV2-RETIRE-001)",
	},
}

local function store()
	local db = TOGBankClassic_Database and TOGBankClassic_Database.db
	if not db or not db.global then return nil end
	db.global.switches = db.global.switches or {}
	return db.global.switches
end

--- True if `name` is on. Unknown names are false rather than an error: a switch read from a
--- newer release's saved state must not break an older client.
function Switches:IsEnabled(name)
	local entry = self.registry[name]
	if not entry then return false end

	-- A dependent switch is inert while its parent is off, whatever its own stored value says.
	-- Reporting it as on would make `dualWrite` look active with V2 disabled, which is exactly
	-- the sort of half-truth a diagnostic switch must not tell.
	if entry.requires and not self:IsEnabled(entry.requires) then
		return false
	end

	local s = store()
	if not s then return entry.default end
	local v = s[name]
	if v == nil then return entry.default end
	return v == true
end

--- Set a switch. Returns false for an unknown name so a typo at the slash command is reported
--- rather than silently creating a switch nothing reads.
function Switches:Set(name, enabled)
	if not self.registry[name] then return false end
	local s = store()
	if not s then return false end
	s[name] = enabled and true or false
	return true
end

--- Registry entries sorted by name, each with its live state. Used by the slash command and by
--- anything that wants to report configuration.
function Switches:GetAll()
	local out = {}
	for name, entry in pairs(self.registry) do
		out[#out + 1] = {
			name        = name,
			enabled     = self:IsEnabled(name),
			default     = entry.default,
			description = entry.description,
			requires    = entry.requires,
			retire      = entry.retire,
			pending     = entry.pending,
			-- Distinguishes "explicitly set to the default" from "never touched", which matters
			-- when diagnosing whether a user changed something or inherited it.
			overridden  = (store() or {})[name] ~= nil,
		}
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end
