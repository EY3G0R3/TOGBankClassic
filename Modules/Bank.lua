---@class TOGBankClassic_Bank
-- BANK-002: `{ ... }` at file scope captures the addon varargs the client passes in, so the
-- module table was born holding [1]="TOGBankClassic" and [2]=<addon namespace table>, with
-- #TOGBankClassic_Bank == 2. Harmless while nothing iterated it, and a trap for the first
-- ipairs or `#` over the module table -- which would have failed far from this line.
TOGBankClassic_Bank = {}

-- BANKSLOT-001: the one spelling of the container geometry, read at call time (see Constants.lua).
local CarriedBagRange = TOGBankClassic_Constants.CarriedBagRange
local BankBagRange    = TOGBankClassic_Constants.BankBagRange

local function HasUpdated()
	return TOGBankClassic_Bank.hasUpdated
end

-- INV2-WIRE-001 WAS TRIED HERE AND REVERTED, 2026-09-09. Read this before attempting it again.
--
-- INV2-RETIRE-003 (2026-09-11) CHANGED THE PREMISE THIS NOTE ARGUES FROM, and the note is kept as
-- the record of why the walks were not merged at the time. The invariant below -- "the legacy store
-- must not depend on the V2 scanner's output" -- protected the legacy rows because they FED the
-- hash and every reader. They no longer exist: the V2 store is the scan's source of truth, the V2
-- write is unconditional and no longer inside a pcall, a V2 fault is a scan fault, the legacy walk
-- is deleted and the legacy rows are stripped on load (docs/DELTA_RELEASE.md section 4). The
-- "third option" at the end of this note became simply "one walk": Inventory/Scan.lua.
--
-- The plan was: delete this second container walk and build the legacy shape from Scan:ScanAll's
-- output, so `/togbank dev compare` diffs ONE walk instead of two taken microseconds apart. It was
-- implemented, and `wiring_spec`'s "still completes the legacy scan when the V2 mirror throws"
-- turned red -- correctly.
--
-- WHAT THE COLLAPSE COSTS: with the legacy shape derived from Scan:ScanAll, any fault in the V2
-- scanner stops the legacy scan too -- and the legacy store is what every character without a V2
-- record still reads. A bug in new code would freeze the whole guild's inventory rather than just
-- the new path.
--
-- THE INVARIANT IS "THE LEGACY STORE MUST NOT DEPEND ON THE V2 SCANNER'S OUTPUT". It is NOT "two
-- walks", and this note said "two independent walks is what makes that impossible" until a peer
-- review showed the code beside it disagrees: the V2 mirror at :320 runs AFTER the legacy aggregate
-- and inside a `pcall` whose failure is loud but non-fatal (:366-371, "legacy scan unaffected"), so
-- a V2 fault is already contained by ORDERING plus that pcall -- and would still be contained if
-- the two shapes shared a walk. The walk COUNT was never carrying the property.
--
-- What the collapse would really change is the DEPENDENCY DIRECTION: it makes legacy a CONSUMER of
-- the V2 scanner, and then no pcall helps, because a pcall protects the caller from the fault -- it
-- cannot conjure legacy data that was never derived. That is why the spec went red, and it is a
-- stronger reason than the one this note used to give, because it survives noticing the pcall.
--
-- WHAT IT BUYS, measured against that: the todo's own words are that a divergence caused by a stack
-- moving between the two walks is "close to theoretical" -- they are microseconds apart inside one
-- Bank:Scan call with no yield. So the trade is a real robustness guarantee for a theoretical
-- consistency gain. Not worth it, and the revert stands.
--
-- IF IT IS EVER REVISITED, START FROM THE THIRD OPTION, not from the binary this note used to pose.
-- The old wording asked "what should happen to the legacy store when the SHARED SCAN throws?" -- a
-- question that only exists if the shared scan is assumed to be V2's, which forecloses the shape
-- that could actually work: ONE NEUTRAL RAW CONTAINER PASS THAT NEITHER FORMAT OWNS, with the
-- legacy shape built from it first and the V2 tuples derived from it second, still inside the
-- existing pcall. Then the dilemma dissolves rather than needing an answer -- a raw pass throwing
-- is exactly what a legacy-walk throw is today, so it needs no new policy.
--
-- NOT COSTED, and the reason this is a pointer rather than a plan: the neutral pass must carry the
-- UNION of what both shapes consume. Legacy rows carry Link/ItemString; V2 tuples are
-- {id, count, suffix, enchant} integers. Whether Scan:ScanAll already retains enough to build both
-- has not been established, and if it does not, the neutral pass costs more memory per slot than
-- either walk alone.

-- INV2-RETIRE-003: ScanBag / ScanBags / ScanBank -- the legacy container walkers that wrote the
-- link-bearing rows -- were deleted here. Inventory/Scan.lua is the one walk; BANKSLOT-001's shared
-- range spelling lives in Constants.lua and is read there.

-- ============================================================================
-- HIDE-001: items a banker keeps from the guild
-- ============================================================================
-- Discord (Vishiswaz, 2026-08-25): "right click and hide or unhide items in this interface while on
-- a gbank toon, which will change whether or not the item is transmitted as being in the inventory
-- when syncing" -- the hearthstone, the resale stock, the soulbound leftovers of a repurposed main.
-- The operator's own line in that thread is the design constraint: the indication lives in
-- TOGBank's window, never in the bags, because bag addons interfere. The list is per character
-- (Options.db.char.hiddenItems, `Record.key -> true`); the store applies it at the write
-- (Store:SetAltSources), so everything downstream of the write -- hash, canon, chain, log,
-- snapshot, every viewer -- sees the banker as not having the item. KNOWN COST, stated in the
-- CHANGELOG: to the guild's bank log, hiding reads as a withdrawal and unhiding as a deposit,
-- because that is exactly what the published record did.

--- This character's hidden keys, or an empty table before the options DB exists.
---@return table keys `Record.key -> true`
function TOGBankClassic_Bank:HiddenKeys()
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	local char = db and db.char
	if not char then return {} end
	char.hiddenItems = char.hiddenItems or {}
	return char.hiddenItems
end

---@return boolean
function TOGBankClassic_Bank:IsHidden(itemID, suffix, enchant)
	local key = TOGBankClassic_Inventory_Record.keyFor(itemID, suffix, enchant)
	return key ~= nil and self:HiddenKeys()[key] == true
end

-- HIDE-002: the banker's "hide soulbound items" checkbox (Bank settings, per character). The scan
-- reports which keys sat in a bound slot, PER SOURCE, and the bank source is only readable at a
-- banker -- so the keys are REMEMBERED per source (`Options.db.char.boundKeys`) and a scan away
-- from the vault keeps the vault's. Kept apart from the manual list: unticking the box must show
-- every bound item again without touching what the banker hid by hand.

--- Fold this scan's bound keys into the per-source memory. A source the scan did not read keeps
--- what it had.
---@param bound table|nil `{ bags = { key = true }, bank = { key = true }|nil }` from Scan:ScanAll
function TOGBankClassic_Bank:RememberBoundKeys(bound)
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	if not (db and db.char and type(bound) == "table") then return end
	db.char.boundKeys = db.char.boundKeys or {}
	for source, keys in pairs(bound) do db.char.boundKeys[source] = keys end
end

--- The list the store splits on: the manual list, plus every remembered bound key while the
--- checkbox is on. A NEW table -- the manual list is never written to by this.
---@return table keys `Record.key -> true`
function TOGBankClassic_Bank:EffectiveHiddenKeys()
	local out = {}
	for key in pairs(self:HiddenKeys()) do out[key] = true end
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	if TOGBankClassic_Options and TOGBankClassic_Options.GetHideSoulbound
		and TOGBankClassic_Options:GetHideSoulbound() and db and db.char and db.char.boundKeys then
		for _, keys in pairs(db.char.boundKeys) do
			for key in pairs(keys) do out[key] = true end
		end
	end
	return out
end

--- Why a row is hidden: "manual" (right-clicked), "soulbound" (the checkbox), or nil.
---@return string|nil reason
function TOGBankClassic_Bank:HiddenReason(itemID, suffix, enchant)
	local key = TOGBankClassic_Inventory_Record.keyFor(itemID, suffix, enchant)
	if not key then return nil end
	if self:HiddenKeys()[key] then return "manual" end
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	if TOGBankClassic_Options and TOGBankClassic_Options.GetHideSoulbound
		and TOGBankClassic_Options:GetHideSoulbound() and db and db.char and db.char.boundKeys then
		for _, keys in pairs(db.char.boundKeys) do
			if keys[key] then return "soulbound" end
		end
	end
	return nil
end

--- Hide or show one item variant, then re-read and republish so the guild sees the change now
--- rather than at the next vault visit. The scan re-partitions every stored source on the new
--- list -- including a vault bucket carried forward from the last visit -- so this works away from
--- the bank. Returns false when the options DB is not up yet or the key is malformed.
---@param hidden boolean
---@return boolean changed
function TOGBankClassic_Bank:SetHidden(itemID, suffix, enchant, hidden)
	local key = TOGBankClassic_Inventory_Record.keyFor(itemID, suffix, enchant)
	local db = TOGBankClassic_Options and TOGBankClassic_Options.db
	if not (key and db and db.char) then return false end
	local keys = self:HiddenKeys()
	local want = hidden and true or nil
	if keys[key] == want then return false end
	keys[key] = want
	TOGBankClassic_Output:Debug("BANK", "HIDE", "%s %s from the guild -- rescanning", want and "hiding" or "showing", key)
	-- HIDE-SHARE-001 (operator 2026-09-13: "can we have the game do a /togbank share when we do the
	-- hide/unhide?"): the version this change mints is broadcast the moment it exists, so the guild
	-- sees the hide now rather than on the 10-minute timer. Set here, spent by MintVersion -- the
	-- ONE place a canon is born -- so a hide the publish gate defers (MULTIPC-001: unconsulted, or a
	-- stale source) still shares when PublishIfDeferred mints it later. The post-SCAN broadcast the
	-- operator ruled out on 2026-09-11 (a vault scan can be half the data) is not this: a hide
	-- re-partitions sources already held, so the version it mints is whole by construction.
	self.shareOnMint = true
	-- Scan's own gate skips when nothing is dirty once the bag events are live; this IS the change.
	self:OnUpdateStart()
	self:Scan()
	return true
end

-- SCAN-001: every early return below logs under BANK.GATE. These five gates used to fail
-- silently, so a character that never scanned gave no signal at all -- the Inventory tab
-- just sat on "Loading items..." with no way to tell which precondition was unmet.
function TOGBankClassic_Bank:Scan()
	if TOGBankClassic_Bank.eventsRegistered then
		if not HasUpdated() then
			TOGBankClassic_Output:Debug("BANK", "GATE", "Scan skipped: nothing marked dirty (hasUpdated=false)")
			return
		end
	end

	local info = TOGBankClassic_Guild.Info
	if not info then
		TOGBankClassic_Output:Debug("BANK", "GATE", "Scan skipped: Guild.Info is nil (guild data not loaded yet)")
		return
	end

	-- Normalize player name to ensure consistent keying in saved DB
	local player = TOGBankClassic_Guild:GetNormalizedPlayer()

	local isBank = false
	local banks = TOGBankClassic_Guild:GetBanks()
	if banks == nil then
		TOGBankClassic_Output:Debug("BANK", "GATE",
			"Scan skipped: no bankers found in guild notes (roster may not be loaded yet)")
		return
	end
	for _, v in pairs(banks) do
		local normV = TOGBankClassic_Guild:NormalizeName(v)
		if normV == player then
			isBank = true
			break
		end
	end
	if not isBank then
		TOGBankClassic_Output:Debug("BANK", "GATE",
			"Scan skipped: '%s' is not in the banker list (%d banker(s) known) - check for 'gbank' in the guild/officer note",
			tostring(player), #banks)
		return
	end
	if not TOGBankClassic_Options:GetBankEnabled() then
		TOGBankClassic_Output:Debug("BANK", "GATE",
			"Scan skipped: bank scanning is disabled for '%s' (Options -> Bank -> Enable)", tostring(player))
		return
	end

	local alt = {}
	-- Load from aggregate view (info.alts)
	if info.alts and info.alts[player] then
		alt = info.alts[player]
	end
	-- INV2-RETIRE-003: THE V2 STORE IS THE SCAN'S SOURCE OF TRUTH. The version held BEFORE this scan
	-- -- for the bank-log diff and the deferred publish -- is the store's record set, captured here
	-- before the write below replaces it. `GetAltRecords` hands back a cached array the write drops
	-- from its cache rather than mutating, so this reference stays the old version. nil when the
	-- store has never held this character (a first scan has no before to diff against).
	local Store, V2Scan, Record = TOGBankClassic_Inventory_Store, TOGBankClassic_Inventory_Scan,
		TOGBankClassic_Inventory_Record
	if not (Store and V2Scan and Record) then
		-- Declared in both TOCs ahead of this module. Absence is a load-order defect and a hard error
		-- is the right outcome; a scan that silently fell back to the legacy rows would hash a
		-- different aggregate from the one every receiver verifies against.
		error("TOGBankClassic_Bank:Scan: the V2 inventory modules are not loaded", 2)
	end
	local logBefore, logMoneyBefore, logCanonBefore, heldBefore
	if info.name and Store:HasAlt(info.name, player) then
		logBefore, logMoneyBefore = Store:GetAltRecords(info.name, player), Store:GetAltMoney(info.name, player)
		-- LOG-MAIL-001: the bank LOG diffs what the banker HOLDS (bags + bank), so an attachment
		-- sitting unopened in the inbox is not a deposit until it is taken. The chain link and the
		-- hash still diff and cover the full set above.
		heldBefore = Store:GetAltHeldRecords(info.name, player)
	end
	logCanonBefore = alt.inventoryHashV2

	-- ONE WALK (INV2-RETIRE-003). The legacy container walk that used to run here -- ScanBank /
	-- ScanBags writing `alt.bank.items` / `alt.bags.items`, then the `alt.items` aggregate -- is
	-- gone. Nothing reads those rows any more (docs/DELTA_RELEASE.md section 4), the store is what
	-- gets hashed, stamped, logged and shipped, and the INV2-WIRE-001 dilemma at the top of this file
	-- (which walk owns the legacy shape when the shared scan throws) has no second shape left to
	-- ask about. What the alt record keeps per source is METADATA: `slots` for the status bar and
	-- `lastScan` for the MULTIPC-001 publish gate.
	--
	-- MULTIPC-001: every source this scan READS is stamped with when THIS PC read it (`lastScan`,
	-- the spelling `alt.mail` has carried since MAIL-002). Local-only -- the sub-tables never go on
	-- the wire. The publish gate below reads them: on a shared account played from several PCs a
	-- source this PC has not read since another PC's publish is a stale copy, however fresh the
	-- rest of the scan is.
	local readAt = GetServerTime()
	self.readThisSession = self.readThisSession or {}

	-- Per source, not one flat set -- INV2-VAULT-001. Bags and mail are readable anywhere; the
	-- vault is readable only at a banker. `sources.bank` is ABSENT when the vault was out of reach,
	-- and an absent source is KEPT by the store rather than cleared. A fault in the walk is a scan
	-- fault and surfaces as one: nothing below is minted over a scan that did not complete.
	local result = V2Scan:ScanAll()

	if result.bankScanned then
		alt.bank = { slots = { count = result.slots.bank.used, total = result.slots.bank.total }, lastScan = readAt }
		self.readThisSession.bank = true
	end
	alt.bags = { slots = { count = result.slots.bags.used, total = result.slots.bags.total }, lastScan = readAt }
	self.readThisSession.bags = true

	local money = result.money
	alt.money = money

	-- SCAN-001: counterpart to the BANK.GATE lines above -- confirms a scan actually ran
	-- and shows whether the vault half was included (it is skipped away from a bank NPC).
	TOGBankClassic_Output:Debug("BANK", "SCAN",
		"Scanned '%s': %d record(s) across %d slot(s) (bank vault %s)",
		tostring(player), #result.records, result.slots.bags.total + result.slots.bank.total,
		result.bankScanned and "included" or "skipped - not at a bank")

	-- Mail, when the mailbox was read. INV2-MAIL-001: it can only be read while the mailbox is
	-- open, so it arrives through MailInventory rather than a container walk. Its rows go into the
	-- store as tuples -- MailInventory hands over {ID, Count, Link}, and the tuple is built from ID
	-- and Count ONLY: every mail row is stored suffix-less. KNOWN WRONG, NOT FIXED HERE (LINK-AUDIT-001):
	-- the line below used to be justified by "suffix and enchant are unknowable for a mail attachment
	-- because GetInboxItem does not report them", which is false -- `GetInboxItemLink` is read two
	-- lines up in MailInventory and carries both. The operator, on a Dreadblade of the Bear read in
	-- the inbox: "some items are loosing suffixes ... it's showing up as dreadblade". A suffix-less
	-- mail row is a DIFFERENT KEY from the same item once it is in the bags, and the log's `from`
	-- (keyed id:suffix) can never match it. The operator stopped a one-line fix here on 2026-09-12:
	-- this is one symptom of the link-era identity logic (stripping, reconstruction, keys) that the
	-- LINK-AUDIT-001 overhaul covers whole, and it is fixed there. `alt.mail` keeps the metadata only.
	TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Bank:Scan() for player '%s', hasUpdated=%s",
		player, tostring(TOGBankClassic_MailInventory.hasUpdated))
	local mailRecords, mailSkipped, mailRead = nil, 0, false
	if TOGBankClassic_MailInventory.hasUpdated then
		local mailData = TOGBankClassic_MailInventory:ScanMailInventory()
		if mailData then
			mailRecords, mailRead = {}, true
			for _, item in ipairs(mailData.items or {}) do
				local rec = Record.new(item.ID, item.Count or 1)
				if rec then
					mailRecords[#mailRecords + 1] = rec
				else
					mailSkipped = mailSkipped + 1
				end
			end
			alt.mail = {
				slots    = mailData.slots or { count = #mailRecords, total = 0 },
				version  = mailData.version,
				lastScan = mailData.lastScan,
			}
			-- LOG-MAIL-001: the mint's deposit attribution is MailInventory:TakenSenders (what LEFT
			-- the inbox), not this read's senders -- an arrival is not a deposit.
			self.readThisSession.mail = true   -- MULTIPC-001: MailInventory stamps mail.lastScan
			TOGBankClassic_Output:Debug("MAIL", "STORE", "[MAIL-002] mail scanned for '%s': %d record(s), %d bad, lastScan=%s",
				player, #mailRecords, mailSkipped, tostring(mailData.lastScan))
		end
		TOGBankClassic_Output:Debug("MAIL", "SCAN", "[MAIL-002] Clearing hasUpdated flag after scan")
		TOGBankClassic_MailInventory.hasUpdated = false
	end

	-- `bags` is always supplied: an emptied bag must clear the source rather than leave yesterday's
	-- rows counted. `mail` is supplied only when the mailbox was read this scan (an unread mailbox
	-- is unknown, not empty -- the same rule as the vault). `bank` only when the vault was in reach.
	local sources = { bags = result.sources.bags }
	if result.sources.bank then sources.bank = result.sources.bank end
	if mailRead then sources.mail = mailRecords end

	-- HIDE-001 / HIDE-002: the banker's hidden list -- right-clicked keys plus, when the checkbox is
	-- on, every remembered soulbound key -- rides the write; the store keeps those rows aside.
	self:RememberBoundKeys(result.bound)
	local stored, skipped = Store:SetAltSources(info.name, player, sources, money, self:EffectiveHiddenKeys())
	TOGBankClassic_Output:Debug("BANK", "SCAN",
		"[INV2] stored %d record(s) for %s (%d skipped, vault %s, mail %s)",
		stored, player, skipped,
		result.bankScanned and "rescanned" or "kept - out of reach",
		mailRead and (#mailRecords .. " row(s)") or "kept - not read")
	-- THE record set this scan publishes: hashed, stamped and logged below, and what SendAltData
	-- ships. One flat aggregated array per the store's own read.
	local records = Store:GetAltRecords(info.name, player)

	-- Compute a hash of the current inventory state, OVER THE V2 RECORDS (INV2-RETIRE-003).
	--
	-- HASH-REV-001: change detection runs on REVISION 2, the accurate identity. Revision 1 cannot
	-- see suffix or enchant, so gating on it would reproduce audit finding 31 exactly -- a banker
	-- swapping one suffix variant for another at the same count would not bump the version and no
	-- delta would ever be computed. Revision 1 is still STAMPED (HASH-REV-002: now over the same
	-- tuples), but it must never be the gate.
	-- HASH-CANON-003: THE CHANGE DETECTOR IS THE CONTENT HASH, WHICH CARRIES NO DATESTAMP, and the
	-- distinction is what makes a DTS-bearing canon possible at all. A canon differs on every call by
	-- construction, so comparing against it would make every scan look like a change and republish to
	-- the whole guild -- the broadcast storm this work exists to end. Compare content against content;
	-- advance the datestamp only when content moved; then mint the canon over both.
	--
	-- ONE VERSION BUMP PER CHARACTER on the first scan after this change, and it is expected: the
	-- previous content hash was taken over the legacy aggregate, which merged suffix variants into
	-- one row where `Record.keyFor` keeps them apart, so the two can differ for an unchanged bank.
	-- Self-correcting, like the bump the content hash's own introduction caused: the second scan
	-- compares tuples against tuples and goes quiet.
	local currentHash = TOGBankClassic_Core:ComputeInventoryHash(records, nil, nil, money)
	local previousHash = alt.inventoryContentHash
	-- LOG-MAIL-001: a take out of the inbox moves a row from `mail` to `bags` and leaves the merged
	-- set -- and so the content hash -- exactly as it was. The bank LOG is the diff of what the
	-- banker HOLDS (bags + bank), so that take IS a change worth a version: the held set is hashed
	-- beside the whole, and a move between the two mints a new canon (same content half, a new
	-- publish time) whose chain link carries the deposit entry and no row changes. Local metadata,
	-- never on the wire; nil on the first scan after the upgrade, which costs one version bump.
	local heldHash = TOGBankClassic_Core:ComputeInventoryHash(Store:GetAltHeldRecords(info.name, player), nil, nil, money)
	local heldChanged = heldHash ~= alt.heldContentHash

	-- MULTIPC-001: a version is also minted when the contents did NOT change but this PC is BEHIND
	-- on its own character (another PC published later) and has now re-read everything -- the
	-- publish gate passing is what says the re-read is complete. Without this a PC whose full
	-- re-read happens to equal its old contents would keep advertising the old canon and stay red
	-- against the newer one forever.
	local G = TOGBankClassic_Guild
	local behind = G.NewerSelfVersionAt and G:NewerSelfVersionAt() or nil
	if currentHash ~= previousHash or heldChanged or behind then
		local ok, why = self:CanPublish(alt)
		if ok and why == "reread" and not self:HasDiffBase() and self:RequestDiffBase() then
			-- MULTIPC-002 (docs/DELTA_RELEASE.md section 3.5): this PC is BEHIND another PC's publish
			-- and has now re-read everything, but the version it would diff from is the one IT last
			-- published, not the one the guild holds -- so its link would not connect and its log would
			-- repeat the other PC's moves as its own. When a peer is known to HOLD the newer version
			-- (RequestDiffBase asked, or is still waiting), fetch it first, for the diff only -- never
			-- stored: a flat copy beside freshly read bags double-counts them (MULTIPC-001) -- and
			-- publish when it lands; the deferred-publish fallback publishes without it if nobody
			-- delivers. With no known holder there is nothing to ask, and the publish goes ahead
			-- against the version this PC last published, as MULTIPC-001 always did.
			self:DeferPublish(logBefore, logMoneyBefore, logCanonBefore, "diff base", heldBefore)
			self:ArmDeferredPublishFallback()
			TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH",
				"[MULTIPC-002] %s re-read on this PC but a peer holds a later version -- fetching it as the diff base before publishing", player)
		elseif ok then
			-- A hold already waiting (an earlier deferred scan, or one restored across a reload --
			-- DEFER-PERSIST-001) carries the before-images of the last PUBLISHED version; this scan's
			-- own are the rows that earlier scan already stored, and diffing from them would drop its
			-- changes out of the log and the chain link. The hold's win.
			self:MintPublished(alt, player, records, money, currentHash, why,
				self.deferred or { logBefore = logBefore, logMoneyBefore = logMoneyBefore, logCanonBefore = logCanonBefore, heldBefore = heldBefore })
		else
			-- The scan is STORED (the record now shows what this PC read) but NOT PUBLISHED: no new
			-- canon, so peers keep the version they hold rather than adopting a stale-vault merge.
			-- The before-images are kept from the FIRST deferred scan, because the bank-log diff is
			-- against the last PUBLISHED version, not the last scan.
			self:DeferPublish(logBefore, logMoneyBefore, logCanonBefore, why, heldBefore)
			TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH",
				"[MULTIPC-001] Inventory changed for %s but NOT published (%s) -- stored locally, will publish once %s",
				player, why, why == "unconsulted" and "the guild has answered this session's broadcast"
					or "every source has been re-read on this PC (open the bank and the mailbox)")
			if why == "unconsulted" then self:ArmDeferredPublishFallback() end
		end
	else
		-- No changes detected, preserve existing version
		TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "No inventory changes for %s, version unchanged (hash: %s)", player, tostring(currentHash))
		-- DEFER-CLOCK-001: "no changes" is against the last PUBLISHED version; with a hold waiting
		-- this scan is the latest change (the contents came back), so the hold's clock restarts.
		-- HIDE-SHARE-001: a hide of a key this bank does not hold changes nothing; nothing to share.
		-- But NOT while a hold is waiting: the hide that started the hold asked for the share, and the
		-- mint that ends the hold still owes it (a hide then an unhide is that exact sequence).
		if not self:TouchDeferred() then self.shareOnMint = nil end
		-- Backfill inventoryUpdatedAt if missing
		if not alt.inventoryUpdatedAt and alt.version then
			alt.inventoryUpdatedAt = alt.version
		end
	end

	-- MAIL-012: Compute mailHash for mail-specific change detection
	-- This allows receivers to detect when mail data exists and has changed
	-- mailHash is computed whenever mail is scanned (even if empty) to track all mail state changes
	-- nil mailHash = "never scanned mail" vs hash value = "mail scanned" (could be empty or full)
	-- INV2-RETIRE-003: computed over the mail TUPLES this scan read. A mail row is linkless in both
	-- shapes (suffix/enchant 0), so the value is identical to what the legacy rows produced.
	if mailRead then
		-- Compute hash even for empty mail - this allows detecting empty→full and full→empty transitions
		local currentMailHash = TOGBankClassic_Core:ComputeInventoryHash(mailRecords, nil, nil, nil)
		local previousMailHash = alt.mailHash

		if currentMailHash ~= previousMailHash then
			alt.mailHash = currentMailHash
			TOGBankClassic_Output:Debug("MAIL", "STORE", "[MAIL-012] Mail hash changed for %s: %s (was: %s, %d rows)",
				player, tostring(currentMailHash), tostring(previousMailHash), #mailRecords)
		else
			-- Ensure mailHash is set even if unchanged (in case it was missing before)
			alt.mailHash = currentMailHash
			TOGBankClassic_Output:Debug("MAIL", "STORE", "[MAIL-012] Mail hash unchanged for %s: %s (%d rows)",
				player, tostring(currentMailHash), #mailRecords)
		end
	else
		-- No mail data structure (mail was never scanned this session)
		-- Keep previous mailHash if it exists to preserve data across sessions
		TOGBankClassic_Output:Debug("MAIL", "STORE", "[MAIL-012] Mail not scanned this session for %s, preserving existing mailHash", player)
	end

	-- Initialize tables if needed
	if not info.alts then
		info.alts = {}
	end

	-- Write to aggregate view (info.alts) for normal use
	info.alts[player] = alt

	-- LOGAPI-001: the bank-log diff is recorded by MintVersion, beside the canon it is stamped with.

	-- P2P-035: this scan may be the one that makes the account a banker-owner (the record now
	-- carries inventoryContentHash), so number the roster here rather than waiting for the next
	-- roster rebuild -- a brand-new bank character would otherwise be left out of its own
	-- post-scan broadcast until the next login. No-op once numbered.
	if TOGBankClassic_BankerNumbers then
		TOGBankClassic_BankerNumbers:Mint()
	end

	-- INV2-RETIRE-003: the closing "Saved mail (%d items)" line read `alt.mail.items`, which no
	-- longer exists; the [INV2] stored line above already reports the mail row count.
	-- INV2-RETIRE-002: the DELTA-021 snapshot save that ended this function is gone -- see the
	-- header of Modules/Database.lua.
end

-- MULTIPC-001: THE PUBLISH GATE. The operator: "the banker CAN be red in its tab and out of date.
-- For my guild we have a SHARED account many PC's in different states log into. so their data COULD
-- be out of date until they open their bags/mail/bank."
--
-- A scan reads only what is in reach -- bags always, the vault at a bank NPC, mail at a mailbox --
-- and merges it over whatever THIS PC's SavedVariables hold for the rest. On one PC that is always
-- right: the stored vault is the vault as this character last saw it. On a shared account it is
-- not: PC B logging in with a weeks-old file and closing a vendor window would merge today's bags
-- with a vault PC A has since changed, stamp the lot as the newest version, and every peer would
-- adopt it over the correct copy PC A published. The version identity is one publish time for the
-- whole record, so a partial read cannot be published as a version unless the parts it did not read
-- are known to be current.
--
-- Two questions, in order:
--   * Has a peer named a LATER version of this character than this PC holds
--     (Guild:NewerSelfVersionAt)? Then every source must have been read on this PC since that
--     publish -- "until they open their bags/mail/bank" -- or nothing is minted.
--   * Has the guild ANSWERED yet this session (P2PSession:IsSelfConsulted)? Before the login
--     broadcast's collect window and version query have closed, "nobody named a newer version" means
--     nothing, so a PARTIAL read is deferred until they have; a read of all three sources this
--     session is trusted on its own, because it is the whole truth whatever anyone holds.
-- A single-PC banker never meets either: nobody can name a version it did not publish, and the only
-- cost is that a vendor scan in the first minute after login publishes a minute later.
--
-- KNOWN COST, stated: a PC that is behind publishes NOTHING until it has read vault AND bags AND
-- (if the record has a mail block) the mailbox, so a banker who uses mail and only visits the
-- vault on that PC stays red until they also open a mailbox. The tab tooltip says so. A silent
-- guild (nobody answers the version query) holds a partial publish for at most
-- DEFERRED_PUBLISH_FALLBACK seconds. And a version another PC published while NOBODY who holds it is
-- online cannot be learned from anyone, so the login cycle answers "nothing newer" and a partial
-- read publishes over it; only per-source versions on the wire would close that, and the wire is
-- settled.
---@param alt table the record this PC holds for its own character, after the scan stored into it
---@return boolean ok
---@return string why "ok" | "reread" | "full read" | "stale:<source>" | "unconsulted"
function TOGBankClassic_Bank:CanPublish(alt)
	local G = TOGBankClassic_Guild
	local newer = G and G.NewerSelfVersionAt and G:NewerSelfVersionAt() or nil
	if newer then
		-- The vault and the bags must EXIST and be fresh: a banker has a vault by definition, and
		-- a record with no vault block is a PC that has never read it (the wiped-PC case) -- that
		-- is stale, not absent. Mail is a source this record may never have had (a vault-only
		-- banker that has not opened a mailbox on any PC): no mail block is "no mail source", not
		-- "stale mail" (Peer Review, self-audit F3). A mail block that exists must be fresh.
		for _, source in ipairs({ "bank", "bags" }) do
			local at = alt and alt[source] and tonumber(alt[source].lastScan) or 0
			if at < newer then return false, "stale:" .. source end
		end
		if alt and alt.mail and (tonumber(alt.mail.lastScan) or 0) < newer then return false, "stale:mail" end
		return true, "reread"
	end
	local P2P = TOGBankClassic_P2PSession
	if P2P and P2P.IsSelfConsulted and not P2P:IsSelfConsulted() then
		local r = self.readThisSession or {}
		if r.bank and r.bags and r.mail then return true, "full read" end
		return false, "unconsulted"
	end
	return true, "ok"
end

--- THE ONE AND ONLY PLACE A CANON IS BORN. Every other site that used to stamp a hash has been
--- deleted (HASH-CANON-002): the query-path recompute and the no-change adoption. A hash is written
--- once, here, by the client that actually read the bank, and carried unchanged by everyone else.
--- Called from Scan when the gate passes, and from PublishIfDeferred when it passes later.
---
--- LOGAPI-001: the bank log is the DIFF between the version held before and the one minted here
--- -- deposits, withdrawals, money -- stamped with the new version's publish time. A first-ever
--- scan has no before to diff against.
---
--- INV2-RETIRE-003: `records` -- the V2 store's record set -- is what is stamped and logged. The
--- legacy aggregate is neither, from this change on: the canon a receiver verifies against must be
--- minted over the same shape the receiver holds, and receivers hold tuples.
---@param alt table
---@param player string normalized name
---@param records table the V2 records this version publishes (Store:GetAltRecords)
---@param money number
---@param currentHash number the content hash of records + money, already computed
---@param logBefore table|nil the V2 records held before the scan that produced these contents
---@param logMoneyBefore number|nil
---@param logCanonBefore string|nil
---@param heldBefore table|nil the HELD records (bags + bank, no mail) before the scan -- the log's
---       before-image (LOG-MAIL-001). nil when the before-image has no source split (a diff base
---       fetched from a peer): the log then diffs the full sets, mail rows included, as it always
---       did -- KNOWN COST, once per MULTIPC-002 publish.
function TOGBankClassic_Bank:MintVersion(alt, player, records, money, currentHash, logBefore, logMoneyBefore, logCanonBefore, heldBefore)
	local updatedAt = GetServerTime()
	alt.version = updatedAt
	alt.inventoryUpdatedAt = updatedAt
	TOGBankClassic_Core:StampInventoryHashes(alt, records, nil, nil, money, updatedAt)
	-- LOG-MAIL-001: the held (bags + bank) hash Scan's change gate compares against next time.
	do
		local Store, guild = TOGBankClassic_Inventory_Store, TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name
		if Store and Store.GetAltHeldRecords and guild then
			alt.heldContentHash = TOGBankClassic_Core:ComputeInventoryHash(Store:GetAltHeldRecords(guild, player), nil, nil, money)
		end
	end
	TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "Inventory changed for %s, version updated to %d (content: %s, canon: %s)", player, alt.version, tostring(currentHash), tostring(alt.inventoryHashV2))
	-- SYNCED-001: a new version of our bank exists on this PC alone until a guildmate receives it.
	if TOGBankClassic_Propagation then TOGBankClassic_Propagation:OnPublished(player, alt.inventoryHashV2) end
	if logBefore and alt.inventoryHashV2 ~= logCanonBefore then
		-- LOG-MAIL-001: THE LOG IS THE AUTHOR'S STATEMENT, computed once here over what the banker
		-- HOLDS -- bags + bank, not the inbox (Store:GetAltHeldRecords) -- so a mail sitting unopened
		-- is nobody's deposit until it is taken. The operator: "the log should only show the
		-- 'deposit' when it's taken from the mail, not when it's scanned in the inbox. it may sit
		-- there and be sent back." The entries ride in the chain link and the snapshot, and every
		-- receiver appends them verbatim (Sync); no viewer diffs the full sets any more.
		-- THE DELTA RELEASE, step 4: the "who" is derived HERE, once, by the author -- the requester
		-- each withdrawal was mailed or handed to (this client's own request events since the last
		-- version), the sender each taken attachment came from (MailInventory:TakenSenders).
		local Log, Store, MI = TOGBankClassic_Log, TOGBankClassic_Inventory_Store, TOGBankClassic_MailInventory
		local guild = TOGBankClassic_Guild.Info and TOGBankClassic_Guild.Info.name
		local before, after = logBefore, records
		if heldBefore and Store and Store.GetAltHeldRecords and guild then
			before, after = heldBefore, Store:GetAltHeldRecords(guild, player)
		end
		local taken = MI and MI.TakenSenders and MI:TakenSenders() or nil
		local who = Log and Log.AttributeChanges and Log:AttributeChanges(player, before, after, taken) or nil
		local entries = Log and Log.DiffEntries and Log:DiffEntries(player, before, after, logMoneyBefore, alt.money, who) or nil
		if MI and MI.ClearTakenSenders then MI:ClearTakenSenders() end
		-- THE DELTA RELEASE, step 3: the link in the chain is written HERE, first-hand, by the one
		-- client that holds both the version it published last and the one it is publishing now.
		-- Labelled with the new canon and its parent; a client that missed this version applies
		-- this exact delta rather than deriving its own (Inventory/Chain.lua). A first-ever scan
		-- has no parent to diff from and starts the chain at the next version.
		-- The delta engine is the DeltaSync host's (Core:DeltaHost); a Core stand-in without one --
		-- a spec driving MintVersion for the stamp alone -- records no chain, which is correct.
		local Chain = TOGBankClassic_Inventory_Chain
		if Chain and guild and type(logCanonBefore) == "string" and TOGBankClassic_Core.DeltaHost then
			Chain:Record(guild, player, { records = logBefore, money = logMoneyBefore },
				{ records = records, money = alt.money }, logCanonBefore, alt.inventoryHashV2, who,
				Log and Log.PackEntries and Log:PackEntries(entries) or nil)
		end
		if Log and entries then
			Log:RecordEntries(player, entries, alt.inventoryUpdatedAt, logCanonBefore, alt.inventoryHashV2)
		end
	end
	-- HIDE-SHARE-001: a version minted for a hide/show is announced now (SetHidden set the flag).
	-- The raid guard and the collision guard are SyncDeltaVersion's own; nothing here bypasses them.
	if self.shareOnMint then
		self.shareOnMint = nil
		if TOGBankClassic_Events and TOGBankClassic_Events.SyncDeltaVersion then
			TOGBankClassic_Output:Debug("BANK", "HIDE", "sharing the version the hide/show minted (%s)", tostring(alt.inventoryHashV2))
			TOGBankClassic_Events:SyncDeltaVersion("NORMAL")
		end
	end
end

--- A scan is stored but NOT published: hold the before-images of the last PUBLISHED version for the
--- bank-log diff, and say when and why. Kept from the FIRST deferred scan (a later one replaces
--- nothing but the reason: the diff is against the last publish, not the last scan).
---
--- DEFERRED-LINE-001 (operator 2026-09-13: "hiding/unhiding and now it doesn't show up immediately
--- like it did before"): a hide inside the login consult window, or while another PC's publish is
--- newer, is deferred here for up to DEFERRED_PUBLISH_FALLBACK seconds -- and until this, nothing
--- on screen said so. The propagation tracker only starts at the mint, so the status bar was empty
--- for the whole wait and a deferred hide looked like a hide that did nothing. `since` and `why`
--- are what the status bar reads to show the wait (StatusBar.BuildPropagationText).
---@param logBefore table|nil
---@param logMoneyBefore number|nil
---@param logCanonBefore string|nil
---@param why string CanPublish's reason, or "diff base" while MULTIPC-002 waits for the newer copy
---@param heldBefore table|nil the held (bags + bank) before-image for the log, LOG-MAIL-001
function TOGBankClassic_Bank:DeferPublish(logBefore, logMoneyBefore, logCanonBefore, why, heldBefore)
	local d = self.deferred
	if not d then
		d = { logBefore = logBefore, logMoneyBefore = logMoneyBefore, logCanonBefore = logCanonBefore, heldBefore = heldBefore }
		self.deferred = d
	end
	-- DEFER-CLOCK-001 (operator 2026-09-13: "if i do a hide, and wait 10 secs, then do an UNHIDE it
	-- should be a new hash so ensure it is a new hash and start the timer over on the NEW HASH"):
	-- every change that lands on a hold restarts its clock -- the wait shown is for the LATEST
	-- contents, which are what will be minted. The before-images are not touched: the diff is still
	-- against the last published version.
	d.since, d.startedAt = GetTime(), GetServerTime()
	d.why = why
	self:SaveDeferred()
	return d
end

--- DEFER-CLOCK-001: a scan that lands on a hold with the contents back where the published
--- version had them (a hide, then the unhide) takes Scan's "no changes" branch -- nothing to
--- diff, but it IS the latest change, so the clock restarts on it too. The mint that follows is
--- still a new canon (the canon carries its publish time) over the current contents.
function TOGBankClassic_Bank:TouchDeferred()
	local d = self.deferred
	if not d then return false end
	d.since, d.startedAt = GetTime(), GetServerTime()
	self:SaveDeferred()
	return true
end

--- DEFER-PERSIST-001: the per-character slot the hold is saved in, or nil before Options is up.
local function deferredSlot()
	local O = TOGBankClassic_Options
	local db = O and O.db
	return db and db.char or nil
end

--- DEFER-PERSIST-001 (operator 2026-09-13, after a hide inside the login window and a /reload:
--- "still not living through reload, you need to save it to SV when you 'start' it ... you can
--- clear it and remove it from sv when it's filled"): a hold is written to the character's
--- SavedVariables the moment it starts and cleared the moment it publishes. Until this only a
--- MINTED update was saved (PROP-PERSIST-001); a scan the gate held was session-only, so a reload
--- during the wait lost the before-images (the log diff and the chain link for that version) and
--- the wait itself -- and the next login's scan, finding the store already holding the hidden
--- state, had nothing to publish until the bags changed again. The before-images are the records
--- of the last PUBLISHED version, which peers hold; they are bounded (one banker's rows) and gone
--- again at the mint.
function TOGBankClassic_Bank:SaveDeferred()
	local char = deferredSlot()
	if not char then return false end
	local d = self.deferred
	if not d then char.deferredPublish = nil return true end
	local G = TOGBankClassic_Guild
	local function copyRows(records)
		if not records then return nil end
		local rows = {}
		for i, rec in ipairs(records) do
			local c = {}
			for k, v in pairs(rec) do c[k] = v end
			rows[i] = c
		end
		return rows
	end
	char.deferredPublish = {
		player = G and G.GetNormalizedPlayer and G:GetNormalizedPlayer() or nil,
		startedAt = d.startedAt or GetServerTime(), why = d.why,
		logCanonBefore = d.logCanonBefore, logMoneyBefore = d.logMoneyBefore,
		logBefore = copyRows(d.logBefore),
		heldBefore = copyRows(d.heldBefore),   -- LOG-MAIL-001: the log's own before-image
	}
	return true
end

--- Bring a saved hold back at login, if it still describes this record: same character, and the
--- held canon is still the PARENT the hold was diffing from (a mint since -- another PC's publish
--- adopted, or a wiped record -- means the hold is stale and is dropped). Called from Guild:Init
--- after Database:Load, like Propagation:Restore, and leaves the save alone while the record is not
--- loaded. The restored hold re-arms the fallback, so it publishes once the guild answers even if
--- no bag event ever fires; the login scan, finding `deferred` set, keeps these before-images.
---@return boolean restored
function TOGBankClassic_Bank:RestoreDeferred()
	if self.deferred then return false end
	local char = deferredSlot()
	local saved = char and char.deferredPublish
	if type(saved) ~= "table" then return false end
	local G = TOGBankClassic_Guild
	local me = G and G.GetNormalizedPlayer and G:GetNormalizedPlayer()
	local info = G and G.Info
	if not (info and info.alts and me) then return false end
	local alt = info.alts[me]
	local held = alt and alt.inventoryHashV2
	if saved.player ~= me or held ~= saved.logCanonBefore then
		char.deferredPublish = nil
		TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "[DEFER-PERSIST-001] saved hold dropped (player=%s parent=%s held=%s)",
			tostring(saved.player), tostring(saved.logCanonBefore), tostring(held))
		return false
	end
	local startedAt = tonumber(saved.startedAt) or GetServerTime()
	self.deferred = {
		logBefore = saved.logBefore, logMoneyBefore = saved.logMoneyBefore, logCanonBefore = saved.logCanonBefore,
		heldBefore = saved.heldBefore,
		why = saved.why or "unconsulted", startedAt = startedAt,
		since = GetTime() - math.max(0, GetServerTime() - startedAt),
	}
	self:ArmDeferredPublishFallback()
	TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "[DEFER-PERSIST-001] %s's held publish from %s restored (%s) -- waiting for the guild",
		me, date("%H:%M", startedAt), tostring(self.deferred.why))
	return true
end

--- Mint a version the gate has passed, choosing what it is diffed FROM:
---   * behind another PC (`why == "reread"`) with the newest version fetched (HasDiffBase): from THAT
---     -- so the link connects to what the guild holds and the log carries only this PC's moves;
---   * behind, but the fetch never came (`force`, the fallback): from nothing -- no link, no log.
---     The true parent is not held, and a diff from the wrong one would be a wrong log entry;
---   * otherwise: from the version this PC last published -- the before-images the scan (or the
---     first deferred scan) captured.
---@param alt table
---@param player string
---@param records table
---@param money number
---@param currentHash number
---@param why string CanPublish's reason
---@param d table { logBefore=, logMoneyBefore=, logCanonBefore=, heldBefore= }
---@param force boolean|nil the fallback: publish without a diff base
function TOGBankClassic_Bank:MintPublished(alt, player, records, money, currentHash, why, d, force)
	if why == "reread" then
		local base = self.diffBase
		self.diffBase, self.awaitingDiffBase, self.newerSelf = nil, nil, nil
		if base then
			-- No held before-image: the fetched copy has no source split (LOG-MAIL-001 known cost).
			self:MintVersion(alt, player, records, money, currentHash, base.records, base.money, base.canon, nil)
			TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "[MULTIPC-002] %s published against the fetched %s: the link connects, the log is this PC's moves only", player, tostring(base.canon))
		elseif force then
			self:MintVersion(alt, player, records, money, currentHash, nil, nil, nil, nil)
			TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "[MULTIPC-002] %s published WITHOUT the newer version (nobody delivered it): no link, nothing logged", player)
		else
			self:MintVersion(alt, player, records, money, currentHash, d.logBefore, d.logMoneyBefore, d.logCanonBefore, d.heldBefore)
		end
	else
		self:MintVersion(alt, player, records, money, currentHash, d.logBefore, d.logMoneyBefore, d.logCanonBefore, d.heldBefore)
	end
	self.deferred = nil
	self:SaveDeferred()   -- DEFER-PERSIST-001: published, so nothing is owed across a reload
end

-- ─── MULTIPC-002: the diff base (docs/DELTA_RELEASE.md section 3.5) ──────────────────────────────

--- A peer holds a LATER version of this character than this PC. Called from the version query
--- (P2PSession:FinishVersionQuery, the reply to our own broadcast's bare offers) and from a
--- broadcast naming our number with a newer canon (Chat:ProcessQueuedHashBroadcasts). The newest
--- canon wins; holders of that canon accumulate.
---@param canon string
---@param holders table array of normalized peer names
function TOGBankClassic_Bank:NoteNewerSelfVersion(canon, holders)
	local G, DC = TOGBankClassic_Guild, TOGBankClassic_DeltaComms
	if type(canon) ~= "string" or not DC:CanonPublishTime(canon) then return false end
	local cur = self.newerSelf
	if cur and cur.canon ~= canon then
		-- The one "is this a later publish" compare (Guild:CanonIsNewer), not a second spelling.
		if not G:CanonIsNewer(canon, cur.canon) then return false end
		cur = nil
	end
	cur = cur or { canon = canon, holders = {} }
	local seen = {}
	for _, p in ipairs(cur.holders) do seen[p] = true end
	for _, p in ipairs(holders or {}) do
		if type(p) == "string" and not seen[p] then cur.holders[#cur.holders + 1] = p; seen[p] = true end
	end
	self.newerSelf = cur

	-- MULTIPC-003: LEARNING we are behind is a trigger to republish, exactly as a content change is.
	--
	-- Until this, the only thing that could mint was Bank:Scan -- and a scan that finds NO content
	-- change and is not YET known to be behind takes the "version unchanged" branch, which sets no
	-- deferred publish. That is the ordinary login order: the scan runs on the first bag event, the
	-- guild's broadcasts arrive AFTER it, and the "a peer holds a newer version of you" news lands
	-- with nothing left to act on it. `PublishIfDeferred` is then a no-op forever (nothing deferred),
	-- nothing rescans while the bags do not change, and the banker sits RED against a version it has
	-- already re-read every source for. Read off the operator's own client 2026-09-12: Bagsbagsbags
	-- holding a canon published 2 days earlier with bags, vault and mail all `lastScan`ed minutes ago
	-- -- "my bags hash should be the latest, but it's saying it's behind".
	--
	-- The before-images are what this PC last PUBLISHED, which -- no content change having been seen
	-- -- is what it holds now. The release goes through the normal path, so every MULTIPC-001 rule
	-- still applies: a source not re-read since that publish still refuses to mint (the gate), and a
	-- known holder is still asked for the diff base first (MULTIPC-002).
	if not self.deferred then
		local info = G and G.Info
		local me = info and G:GetNormalizedPlayer()
		local alt = me and info.alts and info.alts[me]
		local Store = TOGBankClassic_Inventory_Store
		if alt and info.name and Store then
			self:DeferPublish(Store:GetAltRecords(info.name, me), Store:GetAltMoney(info.name, me), alt.inventoryHashV2, "behind",
				Store.GetAltHeldRecords and Store:GetAltHeldRecords(info.name, me) or nil)
			TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH",
				"[MULTIPC-003] %s learned a peer holds %s, newer than the copy this PC published -- releasing a publish without waiting for a rescan",
				me, canon)
			self:PublishIfDeferred()
		end
	end
	return true
end

--- Is the newest version we know of already fetched?
function TOGBankClassic_Bank:HasDiffBase()
	local base, newer = self.diffBase, self.newerSelf
	if not base then return false end
	if newer and newer.canon ~= base.canon then return false end
	return true
end

--- Ask a holder for the newest version of OUR OWN bank, through the normal handshake -- the same
--- session, slot and queue rules as any fetch (P2PSession:DispatchList) -- so the provider needs
--- nothing special. Sync routes the delivery to ReceiveDiffBase because `awaitingDiffBase` is set.
--- True when a fetch is in hand -- asked now, or asked earlier and still waiting; false when there
--- is nothing to ask: nobody was recorded holding a newer version.
---@return boolean fetching
function TOGBankClassic_Bank:RequestDiffBase()
	local G, P2P, DC = TOGBankClassic_Guild, TOGBankClassic_P2PSession, TOGBankClassic_DeltaComms
	local newer = self.newerSelf
	if not (newer and P2P and P2P.DispatchList) then return false end
	if self.awaitingDiffBase then return true end
	local me = G:GetNormalizedPlayer()
	-- ASSUMPTION (peer review F5): the only session ever opened for OUR OWN name is this fetch --
	-- AdvertisedImproves never improves self, and IsAltSyncPending answers false for self -- so a
	-- live session for `me` IS the fetch in flight. If something else ever opens one, this would
	-- wait the fallback out (180s) on an unrelated session; give HasActiveSession a reason then.
	if P2P.HasActiveSession and P2P:HasActiveSession(me) then return true end
	local candidates = {}
	for _, peer in ipairs(newer.holders) do
		candidates[#candidates + 1] = { peer = peer, canon = newer.canon, updatedAt = DC:CanonPublishTime(newer.canon) or 0 }
	end
	if #candidates == 0 then return false end
	self.awaitingDiffBase = newer.canon
	P2P:DispatchList({ { altName = me, candidates = candidates } })
	TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "[MULTIPC-002] asking %d holder(s) for %s's newer version %s as the diff base",
		#candidates, me, newer.canon)
	return true
end

--- The newer version of our own bank arrived (Sync:ReceiveSnapshot, own character, while awaiting).
--- Kept for the diff ONLY -- never written to the store or the record -- and the deferred publish is
--- released against it.
---@param records table
---@param money number
---@param canon string|nil
---@return boolean taken
---@return string|nil why "moved" when the copy was refused because the version wanted moved on
---        since it was asked for -- the caller ends the delivering session and asks again
---        (Sync:ReceiveSnapshot); nil for every other refusal
function TOGBankClassic_Bank:ReceiveDiffBase(records, money, canon)
	if not self.awaitingDiffBase or type(canon) ~= "string" then return false end
	local want = self.newerSelf and self.newerSelf.canon or self.awaitingDiffBase
	if canon ~= want and TOGBankClassic_Guild:CanonIsNewer(want, canon) then
		-- MULTIPC-004 (Peer Review, thread 7b7efb1f): REFUSING THIS COPY MUST ALSO RELEASE THE FETCH.
		-- Two holders name two versions -- A names X, B names Y, Y newer, both newer than ours. The
		-- first call sets `deferred` and asks A for X; the second replaces `newerSelf` with Y but
		-- finds `deferred` already set, so B is never asked. A then delivers X, which is correctly
		-- refused here -- and this used to `return false` with `awaitingDiffBase` still holding X.
		-- From then on RequestDiffBase short-circuits on `if self.awaitingDiffBase then return true`
		-- BEFORE it looks at holders, so B is never asked for Y either: the publish waits out the
		-- 180-second fallback and goes out with no link and nothing logged. Clearing it and asking
		-- again puts the request on whoever holds the version we actually want.
		TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "[MULTIPC-002] a diff base arrived at %s but %s is newer -- not taken", canon, want)
		-- ONLY when the version we want has MOVED since we asked. Clearing unconditionally is wrong
		-- and was caught by the example above: when `awaitingDiffBase == want`, the copy we asked for
		-- is still on its way and an older one arriving from some other peer must not cancel it --
		-- dropping the flag there makes the CORRECT base bounce off the guard at the top of this
		-- function when it lands.
		-- MULTIPC-004 follow-up (the other half, Peer Review 7b7efb1f): the re-ask is NOT made here.
		-- This runs inside the delivery from the holder we asked, whose session for our own name is
		-- still live -- and RequestDiffBase short-circuits on HasActiveSession(me) BEFORE it looks at
		-- holders, so a re-ask from here never reached the second holder either; the publish still
		-- waited out the fallback. The caller (Sync:ReceiveSnapshot) completes that session first,
		-- then asks -- "moved" is how it knows to.
		if self.awaitingDiffBase ~= want then
			self.awaitingDiffBase = nil
			return false, "moved"
		end
		return false
	end
	local copy = {}
	for i, rec in ipairs(records or {}) do
		local c = {}
		for k, v in pairs(rec) do c[k] = v end
		copy[i] = c
	end
	self.diffBase = { records = copy, money = money or 0, canon = canon }
	self.awaitingDiffBase = nil
	if self.newerSelf then self.newerSelf.canon = canon end
	TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "[MULTIPC-002] diff base %s received (%d row(s)); publishing against it", canon, #copy)
	self:PublishIfDeferred()
	return true
end

--- MULTIPC-001: publish the scan the gate deferred, if it now passes. Called by P2PSession the
--- moment the login cycle settles (MarkSelfConsulted), by the fallback timer, by ReceiveDiffBase,
--- and by the next scan through the normal path. No-op when nothing was deferred.
---@param force boolean|nil the fallback timer: publish even without the diff base a behind PC waits for
---@return boolean published
function TOGBankClassic_Bank:PublishIfDeferred(force)
	local d = self.deferred
	if not d then return false end
	local G = TOGBankClassic_Guild
	local info = G and G.Info
	local player = G and G:GetNormalizedPlayer()
	local alt = info and info.alts and player and info.alts[player]
	if not alt then self.deferred = nil; self:SaveDeferred(); return false end
	local ok, why = self:CanPublish(alt)
	if not ok then
		d.why = why   -- DEFERRED-LINE-001: the status bar names the current reason for the wait
		self:SaveDeferred()
		TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "[MULTIPC-001] Deferred publish for %s still held (%s)", player, why)
		return false
	end
	if why == "reread" and not self:HasDiffBase() and not force and self:RequestDiffBase() then
		-- MULTIPC-002: behind, a peer holds the newer version, and it is not here yet. Keep waiting;
		-- the fallback timer is what ends the wait. (No known holder: nothing to wait for -- publish.)
		d.why = "diff base"
		self:ArmDeferredPublishFallback()
		TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "[MULTIPC-002] Deferred publish for %s waits for the diff base", player)
		return false
	end
	-- INV2-RETIRE-003: the records the deferred scan stored are what get published, read back from
	-- the store rather than the legacy aggregate (the same source Scan hashes).
	local records = TOGBankClassic_Inventory_Store:GetAltRecords(info.name, player)
	local currentHash = TOGBankClassic_Core:ComputeInventoryHash(records, nil, nil, alt.money)
	self:MintPublished(alt, player, records, alt.money, currentHash, why, d, force)
	TOGBankClassic_Output:Debug("SYNC", "HASH-MATCH", "[MULTIPC-001] Deferred publish for %s released (%s)", player, why)
	return true
end

-- MULTIPC-001: how long a partial scan waits for the guild to answer before it is published anyway.
-- The login cycle is one collect window (60s) plus one version-query window (5s) after a broadcast
-- that may itself be deferred by the collision guard (up to 48s); this only fires if that cycle
-- never runs at all, which no current path produces while a scan is possible -- it is the net
-- under "never publishes", which would be the worse failure.
local DEFERRED_PUBLISH_FALLBACK = 180

--- MULTIPC-001: arm the one-shot net. Latched, so repeated deferred scans share one timer.
function TOGBankClassic_Bank:ArmDeferredPublishFallback()
	if self.deferredFallbackArmed then return end
	self.deferredFallbackArmed = true
	C_Timer.After(DEFERRED_PUBLISH_FALLBACK, function()
		TOGBankClassic_Bank.deferredFallbackArmed = nil
		local P2P = TOGBankClassic_P2PSession
		if P2P and P2P.MarkSelfConsulted then
			-- Marking it releases the deferred publish through the same path a real answer does.
			P2P:MarkSelfConsulted("no answer within " .. DEFERRED_PUBLISH_FALLBACK .. "s")
		end
		-- MULTIPC-002: a publish still held for a diff base nobody delivered goes out without one.
		TOGBankClassic_Bank:PublishIfDeferred(true)
	end)
end

function TOGBankClassic_Bank:HasInventorySpace()
	local total = 0
	local firstBag, lastBag = CarriedBagRange()   -- BANKSLOT-001: ask the client, not a literal
	for bag = firstBag, lastBag do
		local slots, _ = C_Container.GetContainerNumFreeSlots(bag)
		total = total + slots
	end
	return total > 0
end

--- Append every slot in containers `first`..`last` holding the wanted item to `results`.
---
--- BANKFILL-001: the one place the identity rules live, because the bank fill source needs the
--- identical match and a second copy would let REQ-001 (id primacy) and REQ-003 (suffix equality)
--- drift apart -- two spellings of "is this the same item" is the shape that produced REQ-001 in
--- the first place.
--- @param results table rows are appended to this
--- @param first number first container id (inclusive)
--- @param last number last container id (inclusive)
--- @param targetID number|nil itemID; takes precedence over the name when present
--- @param targetName string|nil lowercased name, used only when there is no id
--- @param targetSuffix number|nil when set, the slot's suffix must equal it
local function MatchContainers(results, first, last, targetID, targetName, targetSuffix)
	for bag = first, last do
		local slots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local itemInfo = C_Container.GetContainerItemInfo(bag, slot)
			if itemInfo and itemInfo.hyperlink then
				local matched
				if targetID then
					-- ID-based match: precise, handles same-name variants
					matched = (itemInfo.itemID == targetID)
				else
					-- Legacy name-based match
					local name = GetItemInfo(itemInfo.hyperlink)
					matched = name and string.lower(name) == targetName
				end
				-- REQ-003: enforce suffix equality when the request carries one.
				if matched and targetSuffix then
					matched = (TOGBankClassic_Item:GetSuffixID(itemInfo.hyperlink) == targetSuffix)
				end
				if matched then
					table.insert(results, {
						bag = bag,
						slot = slot,
						count = itemInfo.stackCount or 1,
						link = itemInfo.hyperlink,
					})
				end
			end
		end
	end
end

-- Find all slots containing an item by name (case-insensitive), optionally filtered by item ID
-- and random-suffix ID.
-- When itemID is provided it takes precedence and the name is only used as a display fallback;
-- this correctly distinguishes same-named variants (e.g. Punctured Voodoo Doll by class).
-- REQ-003: when suffixID is also provided, the slot's own suffix must match too, so random-suffix
-- siblings that share a base itemID ("of the Tiger" vs "of the Monkey") are kept apart. suffixID
-- is nil for plain items and legacy requests, in which case suffix is not considered.
-- Returns: table of {bag, slot, count, link}
function TOGBankClassic_Bank:FindItemsByName(itemName, itemID, suffixID)
	local results = {}
	local targetID = tonumber(itemID) or nil
	local targetSuffix = tonumber(suffixID) or nil
	local hasName = itemName ~= nil and itemName ~= ""

	-- REQ-004: bail only when there is NOTHING to match on. This used to return empty whenever
	-- the name was nil or empty, even with a perfectly good itemID -- which contradicts the
	-- ID-primacy rule REQ-001 established, and silently broke the exact path REQ-001 was added
	-- for: an ID-only lookup for a same-name variant reported the item as not banked at all.
	if not hasName and not targetID then
		return results
	end

	local targetName = hasName and string.lower(itemName) or nil

	-- BANKFILL-001: the matcher moved out so the BANK search below can use it. It was open-coded
	-- here and nowhere else until the bank became a fill source; copying it would have made the
	-- REQ-001 id-primacy rule and the REQ-003 suffix rule two implementations that must be
	-- corrected together, which is exactly the divergence this codebase keeps finding.
	local firstBag, lastBag = CarriedBagRange()
	MatchContainers(results, firstBag, lastBag, targetID, targetName, targetSuffix)
	return results
end

--- Every container slot in the BANK -- the vault plus its bag slots -- holding the requested item.
---
--- BANKFILL-001. Same row shape as FindItemsByName, so a caller can treat the two identically; the
--- only difference is which containers are walked. READABLE ONLY AT A BANKER: the container API
--- reports nothing for bank slots when the bank frame has never been opened this session, so an
--- empty result means "not visible from here", NOT "the bank does not have it". Callers must not
--- turn one into the other -- that conflation is what INV2-VAULT-001 was.
--- @return table rows { bag, slot, count, link }
function TOGBankClassic_Bank:FindItemsInBank(itemName, itemID, suffixID)
	local results = {}
	local targetID = tonumber(itemID) or nil
	local targetSuffix = tonumber(suffixID) or nil
	local hasName = itemName ~= nil and itemName ~= ""
	if not hasName and not targetID then
		return results
	end
	local targetName = hasName and string.lower(itemName) or nil

	-- The vault itself is a single container id, then the bank bags -- the same geometry
	-- Bank:Scan walks, read from the client (BANKSLOT-001) rather than hardcoded.
	MatchContainers(results, BANK_CONTAINER, BANK_CONTAINER, targetID, targetName, targetSuffix)
	local firstBankBag, lastBankBag = BankBagRange()
	MatchContainers(results, firstBankBag, lastBankBag, targetID, targetName, targetSuffix)
	return results
end

--- COLLECT-002: the first carried stack that no open order needs -- what the collect step swaps
--- into the bank when the bags are full. `needed` is the set the orders want, keyed both ways the
--- matcher above knows an item: `id[<itemID>] = true` and `name[<lowercased name>] = true` (a
--- legacy request carries a name and no id, and must still protect its stack). The hearthstone is
--- never offered: a banker parked at the bank with no hearthstone is a worse day than a click that
--- says "make room". Walks the carried bags in slot order so the choice is predictable.
local HEARTHSTONE_ID = 6948
--- @param needed table { id = { [itemID]=true }, name = { [lowername]=true } }
--- @return table|nil { bag, slot, count, itemID, name }
function TOGBankClassic_Bank:FindUnneededBagStack(needed)
	needed = needed or {}
	local byID, byName = needed.id or {}, needed.name or {}
	local firstBag, lastBag = CarriedBagRange()
	for bag = firstBag, lastBag do
		local slots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID and info.itemID ~= HEARTHSTONE_ID and not byID[info.itemID] then
				local name = info.hyperlink and GetItemInfo(info.hyperlink) or nil
				if not (name and byName[string.lower(name)]) then
					return { bag = bag, slot = slot, count = info.stackCount or 1, itemID = info.itemID,
						name = name or ("item " .. info.itemID) }
				end
			end
		end
	end
	return nil
end

--- Total of the item held in the BANK. See FindItemsInBank on why zero is ambiguous away from a
--- banker.
--- @return number total, table rows
function TOGBankClassic_Bank:CountItemInBank(itemName, itemID, suffixID)
	local items = self:FindItemsInBank(itemName, itemID, suffixID)
	local total = 0
	for _, item in ipairs(items) do
		total = total + item.count
	end
	return total, items
end

-- Count total of named item in bags (0-4), optionally filtered by item ID and random-suffix ID.
-- Returns: totalCount, itemsTable
function TOGBankClassic_Bank:CountItemInBags(itemName, itemID, suffixID)
	local items = self:FindItemsByName(itemName, itemID, suffixID)
	local total = 0
	for _, item in ipairs(items) do
		total = total + item.count
	end
	return total, items
end

function TOGBankClassic_Bank:OnUpdateStart()
	self.hasUpdated = true
end

-- DEBUG-002: these four lines were logged under MAIL/EVENTS. This is the ONLY caller of
-- Bank:Scan on the bag/bank path, so "was a scan attempted at all?" was invisible to the BANK
-- category -- whose own description is "Bank/bag inventory scanning, including why a scan was
-- skipped". Someone enabling exactly the category the question belongs to got silence, which
-- reads as "no event fired" when it may equally be "the trigger fired and hasUpdated was false".
-- Found 2026-09-08 while diagnosing an empty V2 store: the operator had BANK on, correctly, and
-- saw nothing. The mail scan this function also triggers keeps its own MAIL logging inside Scan.
function TOGBankClassic_Bank:OnUpdateStop()
	TOGBankClassic_Output:Debug("BANK", "GATE", "OnUpdateStop called, hasUpdated=%s", tostring(self.hasUpdated))
	if self.hasUpdated then
		TOGBankClassic_Output:Debug("BANK", "GATE", "Calling Scan()")
		self:Scan()
		TOGBankClassic_Output:Debug("BANK", "GATE", "Scan() completed")
	else
		TOGBankClassic_Output:Debug("BANK", "GATE", "Skipping Scan() because hasUpdated is false")
	end
	self.hasUpdated = false
end
