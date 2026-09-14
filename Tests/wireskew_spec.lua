-- WIRE-SKEW-001: a peer on a release before the data leg changed is neither asked nor accepted.
--
-- v1.5.0 retired the togbank-state summary for the DeltaSync QUERY with no wire back-compat. Read
-- off the operator's two clients (both on this tree) against a guild on v1.4.1, 2026-09-12: 22
-- v1.4.1 requesters queued for the banker's bank, each accept held a slot for the 30-second
-- state-wait (they answer with a summary this tree ignores) and requeued, and the one client that
-- could complete starved at queue position 20; every session TO a v1.4.1 holder sat out the
-- 180-second delivery watchdog. The hlb2 broadcast has carried the sender's addon version since
-- v1.4.1 and nothing read it. Now the provider refuses such a requester before a slot or a queue
-- position, the requester drops such holders from its candidates, and an ACK from one is ignored.
package.path = "./Tests/?.lua;" .. package.path
local env = require("env_togbank")

local BANKER = "Bankchar-Testrealm"
local OLD    = "Oldguy-Testrealm"
local NEW    = "Newguy-Testrealm"
local MYSTERY = "Quiet-Testrealm"
local GUILD  = "Testguild"
local C      = env.canon
local T      = 1757000000

local function client(who)
	env.standUpClient(who, { { name = BANKER, note = "gbank" }, { name = OLD }, { name = NEW }, { name = MYSTERY } }, GUILD)
end

local function hold(alt, canon, at)
	TOGBankClassic_Guild.Info.alts[alt] = {
		name = alt, money = 0, version = at,
		inventoryHash = 0x10, inventoryHashV2 = canon, inventoryUpdatedAt = at, mailHash = 0,
	}
	TOGBankClassic_Inventory_Store:SetAltRecords(GUILD, alt, { TOGBankClassic_Inventory_Record.new(858, 5) }, 0)
end

local function captureAll()
	local host = TOGBankClassic_Core:DeltaHost()
	local byChannel = {}
	for channel, prefix in pairs(host.prefixes) do byChannel[prefix] = channel end
	local sent = {}
	local function record(prefix, body, dist, target)
		local _, decoded = TOGBankClassic_Core:DeserializeWithChecksum(body, {})
		sent[#sent + 1] = { channel = byChannel[prefix] or prefix, prefix = prefix, body = decoded, dist = dist, target = target }
	end
	TOGBankClassic_Core.SendCommMessage = function(_, prefix, body, dist, target, _, cb, arg)
		record(prefix, body, dist, target)
		if cb then cb(arg, #body, #body, true) end
	end
	TOGBankClassic_Core.SendWhisper = function(_, prefix, body, target)
		record(prefix, body, "WHISPER", target)
		return true
	end
	return sent
end

local function find(sent, pred)
	for _, m in ipairs(sent) do if pred(m) then return m end end
end

describe("WIRE-SKEW-001: Guild:PeerSpeaksDataLeg", function()
	before_each(function() env.reset(); client("Bankchar") end)

	-- WIRE-SKEW-002: the string a RELEASED client puts in `addon` is the packager's substitution of
	-- @project-version@, which is the WHOLE git tag -- not "1.4.1". The first cut of this example
	-- drove "1.4.1", passed, and the gate refused nobody real for an afternoon.
	it("reads the version off the hlb2 broadcast, through the real receive, in the packager's tag form", function()
		local G = TOGBankClassic_Guild
		-- Chat:Init's state for the batched broadcast path this message falls through to.
		TOGBankClassic_Chat.hashBroadcastQueue = TOGBankClassic_Chat.hashBroadcastQueue or {}
		TOGBankClassic_Chat.HASH_BROADCAST_BATCH_DELAY = TOGBankClassic_Chat.HASH_BROADCAST_BATCH_DELAY or 0.15
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hlb2", v = 0, e = "", banker = OLD, isBanker = false, addon = "TOGBankClassic-v1.4.1" })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "GUILD", OLD)
		assert.equal("TOGBankClassic-v1.4.1", G.peerAddonVersions[OLD], "the broadcast's addon version was not recorded")
		local ok, why = G:PeerSpeaksDataLeg(OLD)
		assert.is_false(ok, "a released v1.4.1 peer was read as capable -- the tag prefix defeated the version match")
		assert.equal("TOGBankClassic-v1.4.1", why)
	end)

	it("is false before 1.5.0, true from 1.5.0, true for a peer never heard from, true for a dev build", function()
		local G = TOGBankClassic_Guild
		G:NotePeerAddonVersion(OLD, "1.4.1")
		G:NotePeerAddonVersion(NEW, "1.5.0")
		assert.is_false(G:PeerSpeaksDataLeg(OLD))
		assert.is_true(G:PeerSpeaksDataLeg(NEW))
		-- The same two, as the packager spells them on a released client.
		G:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.4.1")
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v1.5.0")
		assert.is_false(G:PeerSpeaksDataLeg(OLD))
		assert.is_true(G:PeerSpeaksDataLeg(NEW))
		G:NotePeerAddonVersion(NEW, "1.10.0")
		assert.is_true(G:PeerSpeaksDataLeg(NEW), "a two-digit minor ranked below 1.5.0 (PROTO-001's class)")
		local ok, why = G:PeerSpeaksDataLeg(MYSTERY)
		assert.is_true(ok, "a peer we have not heard from was refused -- that refuses the operator's own clients at login")
		assert.equal("unknown", why)
		G:NotePeerAddonVersion(MYSTERY, "@project-version@")
		ok, why = G:PeerSpeaksDataLeg(MYSTERY)
		assert.is_true(ok); assert.equal("dev", why)
		assert.equal("1.5.0", TOGBankClassic_Constants.PROTOCOL.DATA_LEG_MIN_ADDON_VERSION)
	end)
end)

-- WIRE-SKEW-004: THE VERSION COMES FROM VersionCheck-1.0 FIRST, AND ONLY THEN FROM THE BROADCAST.
--
-- The operator, 2026-09-12, on a guild where 40 of 42 clients ran v1.4.1: "it's taking HOURS to sync
-- 1 banker ... it MAY be because of all the v1.4.1 users, or it MAY be a problem with the work you
-- did. I can't tell." It was both, and this is the half that is ours. `peerAddonVersions` only fills
-- in when that peer's own hlb2 broadcast reaches us -- which is AFTER we have had to decide whether
-- to ask it for data -- so every peer not yet heard from read as "unknown", and unknown was capable.
-- It was asked which version it held (a whisper out, a reply back, five per alt per round), counted
-- as a holder, and picked as a fetch target: a full dispatch timeout, the next candidate, then `All
-- candidates busy ... retry 1/5 in 20s`. Read off their log verbatim: `→ Togstone-Azuresong to
-- Kajind-Azuresong`, then `Dispatch timeout for Elementals-Azuresong/Kajind-Azuresong`, with Kajind
-- appearing in the refusal lists moments later once its broadcast landed.
--
-- Their instruction, and it is the better design: "there data is there, VC has it. who is on what
-- version, so it has to be available to you, could do a quick table lookup. anything older than
-- v1.5.0 on a v1.5.0 or dev client is dropped." VersionCheck holds the whole guild before any sync
-- traffic and costs no extra messages to do it.
describe("WIRE-SKEW-004: the capability verdict reads VersionCheck-1.0", function()
	local VC

	before_each(function()
		env.reset(); client("Bankchar")
		-- The REAL library, driven through its OWN writer, because the risk being tested is whether
		-- the two agree on the KEY: VersionCheck stores under LibGuildRoster's CanonName and we look
		-- up under ours. A stub keyed the way this spec happens to imagine would pass while the live
		-- lookup silently missed and fell back -- which is indistinguishable from the bug.
		LibStub.libs["VersionCheck-1.0"], LibStub.minors["VersionCheck-1.0"] = nil, nil
		env.loadFile("../VersionCheck-1.0/VersionCheck-1.0.lua")
		VC = LibStub("VersionCheck-1.0")
	end)

	it("refuses a peer VersionCheck saw on v1.4.1 that has never broadcast to us", function()
		local G = TOGBankClassic_Guild
		assert.is_nil(G.peerAddonVersions[OLD], "precondition: this peer has not broadcast to us")
		VC:RecordPeerVersion(OLD, "TOGBankClassic", "TOGBankClassic-v1.4.1", "REQ")
		local ok, why = G:PeerSpeaksDataLeg(OLD)
		assert.is_false(ok, "a peer VersionCheck knows is on v1.4.1 was still treated as capable")
		assert.equal("TOGBankClassic-v1.4.1", why)
	end)

	it("accepts one VersionCheck saw on v1.5.0, and a dev build, with no broadcast either", function()
		local G = TOGBankClassic_Guild
		VC:RecordPeerVersion(NEW, "TOGBankClassic", "TOGBankClassic-v1.5.0", "REQ")
		assert.is_true((G:PeerSpeaksDataLeg(NEW)))
		VC:RecordPeerVersion(MYSTERY, "TOGBankClassic", "@project-version@", "REQ")
		local ok, why = G:PeerSpeaksDataLeg(MYSTERY)
		assert.is_true(ok, "a dev build was refused -- the operator's own two clients must never refuse each other")
		assert.equal("dev", why)
	end)

	-- The operator: "VC doesn't always get an answer due to congestion, so we can't hard block anyone
	-- with a not seen status." The same congestion leaves STALE answers behind too, so neither source
	-- may outrank the other by position -- the NEWER claim wins, in both directions. A version only
	-- moves forward, so that can only ever let more peers through than either source alone.
	it("takes the NEWER claim whichever source it came from, so a stale entry cannot refuse anyone", function()
		local G = TOGBankClassic_Guild
		-- Stale BROADCAST, fresh VersionCheck.
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v1.4.1")
		VC:RecordPeerVersion(NEW, "TOGBankClassic", "TOGBankClassic-v1.5.0", "REQ")
		assert.is_true((G:PeerSpeaksDataLeg(NEW)), "a stale broadcast refused a peer that had updated")
		-- Stale VERSIONCHECK, fresh broadcast -- the case a VersionCheck-wins rule would get wrong,
		-- and the one the operator's congestion note is about.
		VC:RecordPeerVersion(MYSTERY, "TOGBankClassic", "TOGBankClassic-v1.4.1", "REQ")
		G:NotePeerAddonVersion(MYSTERY, "TOGBankClassic-v1.5.0")
		assert.is_true((G:PeerSpeaksDataLeg(MYSTERY)), "a stale VersionCheck entry refused a peer that had updated")
		-- And with nothing in VersionCheck at all, the broadcast still decides.
		G:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.4.1")
		assert.is_false((G:PeerSpeaksDataLeg(OLD)), "the broadcast fallback stopped working")
	end)

	-- The half that must never regress: VersionCheck not having an answer is NOT evidence of an old
	-- build. A congested REQ that never came back would otherwise silently cut that player out.
	it("never blocks a peer neither source has seen, however long VersionCheck has been running", function()
		local G = TOGBankClassic_Guild
		-- A populated VersionCheck that simply has no row for this player -- not an empty library.
		VC:RecordPeerVersion(OLD, "TOGBankClassic", "TOGBankClassic-v1.4.1", "REQ")
		VC:RecordPeerVersion(NEW, "TOGBankClassic", "TOGBankClassic-v1.5.0", "REQ")
		assert.is_nil(G.peerAddonVersions[MYSTERY], "precondition: no broadcast from this peer either")
		local ok, why = G:PeerSpeaksDataLeg(MYSTERY)
		assert.is_true(ok, "a peer VersionCheck never got an answer from was hard-blocked -- congestion is not a version")
		assert.equal("unknown", why)
	end)

	-- THE SILENT-MISS CASE. Handshake messages arrive under whatever name the sender's client put on
	-- the wire, which is not always realm-qualified, and VersionCheck stores under LibGuildRoster's
	-- CanonName. If the two spellings do not meet, the lookup finds nothing, falls through to
	-- "unknown", and every old peer is capable again -- the original bug, restored, with no error and
	-- a green suite. Driven in BOTH directions because only one of them is symmetric by luck.
	it("matches a peer whose wire name is spelled differently from VersionCheck's key", function()
		local G = TOGBankClassic_Guild
		local bare = OLD:match("^[^-]+")
		assert.is_string(bare); assert.not_equal(bare, OLD, "precondition: the two spellings differ")

		-- Recorded BARE, asked QUALIFIED.
		VC:RecordPeerVersion(bare, "TOGBankClassic", "TOGBankClassic-v1.4.1", "REQ")
		assert.is_false((G:PeerSpeaksDataLeg(OLD)),
			"a version recorded under the bare name was not found when asked with the realm -- the lookup misses silently")

		-- Recorded QUALIFIED, asked BARE: the shape a handshake off the wire actually takes.
		env.reset(); client("Bankchar")
		LibStub.libs["VersionCheck-1.0"], LibStub.minors["VersionCheck-1.0"] = nil, nil
		env.loadFile("../VersionCheck-1.0/VersionCheck-1.0.lua")
		local vc2 = LibStub("VersionCheck-1.0")
		vc2:RecordPeerVersion(OLD, "TOGBankClassic", "TOGBankClassic-v1.4.1", "REQ")
		assert.is_false((TOGBankClassic_Guild:PeerSpeaksDataLeg(bare)),
			"a version recorded under the realm-qualified name was not found when asked with the bare one")
	end)

	-- STALE-REQ-001, 2026-09-13: the operator's v1.3.2 requester is "ßlackcloud-Azuresong" -- a
	-- multibyte first letter -- and the Requests tab did not mark him after a reload. The bare-name
	-- split (`^[^-]+`) and CanonName are byte-wise, so a multibyte name must round-trip like any
	-- other, in both spellings and through the real library's REQ writer (FROM_KEY or bare sender).
	it("matches a name with a multibyte first letter, recorded bare or qualified, asked either way", function()
		local G = TOGBankClassic_Guild
		local QUAL, BARE = "\195\159lackcloud-Testrealm", "\195\159lackcloud"
		VC:RecordPeerVersion(BARE, "TOGBankClassic", "TOGBankClassic-v1.3.2", "REQ")
		local ok, why = G:PeerSpeaksDataLeg(QUAL)
		assert.is_false(ok, "a multibyte bare key was not found when asked qualified")
		assert.equal("TOGBankClassic-v1.3.2", why)
		env.reset(); client("Bankchar")
		LibStub.libs["VersionCheck-1.0"], LibStub.minors["VersionCheck-1.0"] = nil, nil
		env.loadFile("../VersionCheck-1.0/VersionCheck-1.0.lua")
		local vc2 = LibStub("VersionCheck-1.0")
		vc2:RecordPeerVersion(QUAL, "TOGBankClassic", "1.3.2", "REQ")
		ok, why = TOGBankClassic_Guild:PeerSpeaksDataLeg(QUAL)
		assert.is_false(ok, "a multibyte qualified key was not found when asked qualified")
		assert.equal("1.3.2", why)
		assert.is_false((TOGBankClassic_Guild:PeerSpeaksDataLeg(BARE)), "... nor when asked bare")
	end)

	-- STALE-REQ-002: VersionCheck's table and peerAddonVersions are SESSION memory; a guildmate who
	-- is offline after a reload has no version at all, and the Requests tab's mark (STALE-REQ-001)
	-- read "unknown" for the one requester it was built for. The guild record now remembers the
	-- last version each guildmate was seen on -- fed by VersionCheck's callback and the broadcast --
	-- and the tab reads it when the live sources have nothing. The SYNC GATE does not: a memory is
	-- what a client ran, and refusing on it is the starvation WIRE-SKEW-004 removed.
	it("remembers the last version each guildmate was seen on in the guild record, from VersionCheck and the broadcast, newer winning -- and the sync gate ignores it", function()
		local G = TOGBankClassic_Guild
		assert.is_true(G:HookVersionCheck(), "the VersionCheck callback did not register")
		VC:RecordPeerVersion(OLD, "TOGBankClassic", "TOGBankClassic-v1.3.2", "REQ")
		local mem = G.Info.peerAddonVersions
		assert.is_table(mem, "no memory on the guild record")
		assert.equal("TOGBankClassic-v1.3.2", mem[OLD].version)
		assert.is_number(mem[OLD].at)
		-- The broadcast feeds it too, and an OLDER claim never overwrites a newer memory.
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v1.5.0")
		assert.equal("TOGBankClassic-v1.5.0", mem[NEW].version)
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v1.4.1")
		assert.equal("TOGBankClassic-v1.5.0", mem[NEW].version, "an older claim rewound the memory")
		-- A reload: the session sources are gone, the memory is not.
		VC.peerVersions = {}
		G.peerAddonVersions = {}
		local raw, remembered = G:LastSeenAddonVersion(OLD)
		assert.equal("TOGBankClassic-v1.3.2", raw); assert.is_true(remembered)
		-- The sync gate still says unknown -> capable: memory is not a refusal.
		local ok, why = G:PeerSpeaksDataLeg(OLD)
		assert.is_true(ok, "the sync gate refused a peer on a REMEMBERED version"); assert.equal("unknown", why)
		-- A live sighting outranks the memory and refreshes it.
		VC:RecordPeerVersion(OLD, "TOGBankClassic", "TOGBankClassic-v1.5.0", "RSP")
		raw, remembered = G:LastSeenAddonVersion(OLD)
		assert.equal("TOGBankClassic-v1.5.0", raw); assert.is_false(remembered)
		assert.equal("TOGBankClassic-v1.5.0", mem[OLD].version)
		-- Never seen anywhere: nil. With no guild record the live source still answers and the
		-- memory is simply absent -- no error either way.
		assert.is_nil((G:LastSeenAddonVersion(MYSTERY)))
		local info = G.Info; G.Info = nil
		raw, remembered = G:LastSeenAddonVersion(OLD)
		assert.equal("TOGBankClassic-v1.5.0", raw); assert.is_false(remembered)
		assert.is_nil((G:LastSeenAddonVersion(MYSTERY)))
		G:RememberPeerAddonVersion(OLD, "1.0.0")   -- no record: nothing to write to, no error
		G.Info = info
		assert.equal("TOGBankClassic-v1.5.0", mem[OLD].version, "a write with no record reached the memory")
	end)

	-- A dev build encodes as 0, which loses every numeric comparison -- so "take the newer claim"
	-- would hand a v1.4.1 claim the win and refuse the operator's own working copy.
	it("lets a dev build win over an older claim from the other source", function()
		local G = TOGBankClassic_Guild
		VC:RecordPeerVersion(MYSTERY, "TOGBankClassic", "TOGBankClassic-v1.4.1", "REQ")
		G:NotePeerAddonVersion(MYSTERY, "@project-version@")
		local ok, why = G:PeerSpeaksDataLeg(MYSTERY)
		assert.is_true(ok, "a dev build lost to a stale v1.4.1 claim -- that refuses the operator's own client")
		assert.equal("dev", why)
	end)

	it("ignores an empty or non-string version rather than reading it as ancient", function()
		local G = TOGBankClassic_Guild
		-- Straight into the observation table: RecordPeerVersion rejects these at the door, so this
		-- is about our READER surviving a row some future writer leaves behind.
		local seen = VC:GetPeerVersions()
		seen[OLD] = { TOGBankClassic = { version = "", at = 0, via = "REQ" } }
		local ok, why = G:PeerSpeaksDataLeg(OLD)
		assert.is_true(ok, "an empty version string was treated as a real one")
		assert.equal("unknown", why)
		seen[OLD] = { TOGBankClassic = { version = 141, at = 0, via = "REQ" } }
		assert.is_true((G:PeerSpeaksDataLeg(OLD)), "a non-string version was read rather than ignored")
	end)

	-- Peer Review c6819531 F3: EncodeVersion answers 0 for a dev build AND for garbage, and every
	-- 0 used to read as "dev, capable" -- so an unparseable claim from one source outranked a real
	-- v1.4.1 claim from the other. Only the two dev spellings are dev; the rest is not evidence.
	it("treats only '@project-version@' and 'dev' as a dev build; an unparseable claim is dropped, not read as dev", function()
		local G = TOGBankClassic_Guild
		assert.is_true(G.IsDevVersion("@project-version@")); assert.is_true(G.IsDevVersion("dev"))
		assert.is_false(G.IsDevVersion("?")); assert.is_false(G.IsDevVersion("unknown")); assert.is_false(G.IsDevVersion(""))
		-- 'dev' from the broadcast beats a v1.4.1 sighting, as '@project-version@' does.
		VC:RecordPeerVersion(MYSTERY, "TOGBankClassic", "TOGBankClassic-v1.4.1", "REQ")
		G:NotePeerAddonVersion(MYSTERY, "dev")
		local ok, why = G:PeerSpeaksDataLeg(MYSTERY)
		assert.is_true(ok); assert.equal("dev", why)
	end)

	it("does not let a garbage claim outrank a real v1.4.1 claim from the other source", function()
		local G = TOGBankClassic_Guild
		VC:RecordPeerVersion(OLD, "TOGBankClassic", "TOGBankClassic-v1.4.1", "REQ")
		G:NotePeerAddonVersion(OLD, "?")
		assert.equal("TOGBankClassic-v1.4.1", G:ObservedAddonVersion(OLD), "garbage from the broadcast outranked VersionCheck's real claim")
		local ok, why = G:PeerSpeaksDataLeg(OLD)
		assert.is_false(ok, "a v1.4.1 peer passed the gate on the strength of a garbage broadcast"); assert.equal("TOGBankClassic-v1.4.1", why)
	end)

	it("reads a peer whose ONLY claim is garbage as unknown -- capable, but not 'dev'", function()
		local G = TOGBankClassic_Guild
		G:NotePeerAddonVersion(MYSTERY, "unknown")
		assert.is_nil(G:ObservedAddonVersion(MYSTERY), "a garbage-only claim was handed back as a version")
		local ok, why = G:PeerSpeaksDataLeg(MYSTERY)
		assert.is_true(ok); assert.equal("unknown", why)
		-- And the guild memory never records it, nor lets it overwrite a real one.
		local mem = G.Info.peerAddonVersions or {}
		assert.is_nil(mem[MYSTERY], "garbage was remembered as the last-seen version")
		G:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.4.1")
		G:NotePeerAddonVersion(OLD, "?")
		assert.equal("TOGBankClassic-v1.4.1", G.Info.peerAddonVersions[OLD].version, "garbage overwrote a remembered real version")
	end)

	it("neither version-queries nor dispatches to a holder it can never fetch from", function()
		local P2P = TOGBankClassic_P2PSession
		VC:RecordPeerVersion(OLD, "TOGBankClassic", "TOGBankClassic-v1.4.1", "REQ")
		-- THE ALT NEEDS A BANKER NUMBER or BeginVersionQuery returns before it sends anything, and
		-- both assertions below would hold for a reason that has nothing to do with the fix. Found
		-- exactly that way: this example stayed green against the deliberately-reverted code while
		-- its three siblings went red. Asserted, not assumed, so it cannot rot back into a skip.
		local roster = TOGBankClassic_BankerNumbers:Table()
		roster.numbers[BANKER] = 1
		roster.numbersVersion = roster.numbersVersion + 1
		assert.equal("0001", TOGBankClassic_BankerNumbers:NumberOf(BANKER),
			"precondition: without a banker number the version query never sends and this example proves nothing")
		local sent = captureAll()
		-- One alt, one holder, that holder on the old release and carrying no version for the alt --
		-- the exact shape that produced a ver-query and then a dispatch timeout.
		P2P:DispatchOrQuery({ { altName = BANKER, candidates = { { peer = OLD, updatedAt = T } } } })
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "ver-query" end),
			"asked an old-release peer which version it holds -- a round trip for a peer we can never fetch from")
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "sync-request" end),
			"dispatched to an old-release peer -- this is where the operator's hours went")
	end)
end)

describe("WIRE-SKEW-001: the provider", function()
	local sent, P2P
	before_each(function()
		env.reset(); client("Bankchar")
		hold(BANKER, C(T, 0x20), T)
		sent = captureAll()
		P2P = TOGBankClassic_P2PSession
		TOGBankClassic_Guild:NotePeerAddonVersion(OLD, "1.4.1")
		TOGBankClassic_Guild:NotePeerAddonVersion(NEW, "1.5.0")
	end)

	-- WIRE-SKEW-005: THE SECOND DOOR INTO AcceptSend. HandleSyncRequest refuses an old requester
	-- before it can take a slot, but a requester QUEUED while we were at capacity comes back through
	-- ServeQueue, which only ever re-checked whether the content still exists. Read off the
	-- operator's live log 2026-09-12, after the WIRE-SKEW-004 fix was already running: Cinia,
	-- Zurayli, Groucho and Bilgoth each appear REFUSED on one line and ACCEPTED on another, and every
	-- accept follows a ReleaseSendSlot -- which is this drain. Each one then burned the full
	-- 30-second state-wait and released with `no_state_summary`.
	it("refuses an old-release requester at QUEUE DRAIN too, instead of accepting it into a slot", function()
		P2P:EnqueueSend("sidq", OLD, BANKER)
		P2P:ServeQueue()
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "sync-accept" end),
			"the queue drain accepted an old-release peer -- it takes a send slot and burns the 30s state-wait")
		local busy = find(sent, function(m) return m.body and m.body.type == "sync-busy" end)
		assert.is_table(busy, "the refused requester was told nothing, so its session hangs rather than moving on")
		assert.equal("addon_version", busy.body.reason)
		assert.equal(0, P2P:GetActiveSendTotal(), "a send slot is held for a peer that can never complete")
	end)

	-- The other half: the gate must not be so wide that it starves the peers that DO work, which is
	-- the failure the whole WIRE-SKEW line exists to prevent.
	it("still serves a capable requester out of the queue", function()
		P2P:EnqueueSend("sidq2", NEW, BANKER)
		P2P:ServeQueue()
		assert.is_table(find(sent, function(m) return m.body and m.body.type == "sync-accept" end),
			"the queue drain refused a CAPABLE peer -- the version gate is too wide")
	end)

	it("answers an old-release requester busy at once: no slot, no queue position, its session moves on", function()
		assert.is_false(P2P:HandleSyncRequest("sid1", OLD, BANKER, C(T, 0x20)))
		local busy = find(sent, function(m) return m.body and m.body.type == "sync-busy" end)
		assert.is_table(busy, "the old requester was accepted -- it will hold the slot for the state-wait and requeue")
		assert.equal("sid1", busy.body.sessionId)
		assert.equal("addon_version", busy.body.reason)
		assert.equal(0, P2P:GetActiveSendTotal())
		assert.equal(0, #(P2P.sendQueue or {}), "the old requester was queued instead")
		-- Three old requesters at capacity are still not queued: they cannot take a turn they cannot use.
		P2P:TryAcquireSendSlot("A-Testrealm"); P2P:TryAcquireSendSlot("B-Testrealm"); P2P:TryAcquireSendSlot("C-Testrealm")
		P2P:HandleSyncRequest("sid2", OLD, BANKER, C(T, 0x20))
		assert.equal(0, #(P2P.sendQueue or {}))
	end)

	it("still accepts (or queues) a requester on the new release or of unknown version", function()
		assert.is_true(P2P:HandleSyncRequest("sid3", NEW, BANKER, C(T, 0x20)))
		assert.is_true(P2P:HandleSyncRequest("sid4", MYSTERY, BANKER, C(T, 0x20)))
		assert.equal(2, P2P:GetActiveSendTotal())
	end)
end)

describe("WIRE-SKEW-001: the requester", function()
	local sent, P2P
	before_each(function()
		env.reset(); client("Newguy")
		sent = captureAll()
		P2P = TOGBankClassic_P2PSession
		P2P.sessions, P2P.sessionsByAlt, P2P.pendingDispatch, P2P.activeSessions = {}, {}, {}, 0
		TOGBankClassic_Guild:NotePeerAddonVersion(OLD, "1.4.1")
		TOGBankClassic_Guild:NotePeerAddonVersion(BANKER, "1.5.0")
	end)

	it("does not ask a holder on the old release; asks the capable one; parks nothing when nobody capable holds it", function()
		P2P:DispatchList({ { altName = BANKER, candidates = {
			{ peer = OLD, canon = C(T, 0x20), updatedAt = T + 5 },   -- freshest sidecar, would be picked first
			{ peer = BANKER, canon = C(T, 0x20), updatedAt = T },
		} } })
		local req = find(sent, function(m) return m.body and m.body.type == "sync-request" end)
		assert.is_table(req, "no sync-request went out")
		assert.equal(BANKER, req.target, "the old-release holder was asked; it will accept and never answer the query (180s)")
		-- Nobody capable: nothing dispatched, nothing parked, no error.
		P2P.sessions, P2P.sessionsByAlt = {}, {}
		local before = #sent
		P2P:DispatchList({ { altName = "Otherbank-Testrealm", candidates = { { peer = OLD, canon = C(T, 0x21), updatedAt = T } } } })
		assert.equal(before, #sent)
		assert.equal(0, #P2P.pendingDispatch, "an alt with no capable holder was parked forever")
	end)

	it("drops an old-release holder folded into a live session when it advances", function()
		P2P.sessions["s"] = { sessionId = "s", altName = BANKER, peer = MYSTERY, state = "DISPATCHED", timers = {},
			triedPeers = { [MYSTERY] = true },
			candidates = { { peer = MYSTERY, canon = C(T, 0x20) }, { peer = OLD, canon = C(T, 0x20) }, { peer = BANKER, canon = C(T, 0x20) } } }
		P2P.sessionsByAlt[BANKER] = "s"
		P2P:AdvanceCandidate("s", "timeout")
		assert.equal(BANKER, P2P.sessions["s"].peer, "the session advanced to the old-release holder")
	end)

	it("ignores a pull-path ACK from an old-release relay rather than querying it", function()
		TOGBankClassic_Guild:BroadcastP2PRequest(BANKER, 0x10, T, nil, nil)
		local n = #sent
		local ack = TOGBankClassic_Core:SerializeWithChecksum({
			type = "alt-request-reply", name = BANKER, isBanker = false, hasData = true, hashOnly = false, expectedHash = 0x10,
		})
		TOGBankClassic_Chat:OnCommReceived("togbank-rr", ack, "WHISPER", OLD)
		assert.equal(n, #sent, "a QUERY went to a relay that cannot answer it")
		assert.is_table(TOGBankClassic_Guild.pendingP2PRequests[BANKER], "the pull request was consumed by an ACK that leads nowhere")
	end)
end)

-- WIRE-SKEW-006: AN OFFER FROM AN OLD-RELEASE PEER IS NOT AN OFFER.
--
-- The operator's two v1.5.0 clients, 2026-09-12: "why isn't it when you block 4.1 traffic, my 2x 4.2
-- clients aren't syncing?" Their SavedVariables held the IDENTICAL canon for Cardsngames on both
-- accounts -- nothing to fetch -- and every tab was red. A bare offer turns the tab red
-- (TABCOLOUR-003) and only the version query clears it; WIRE-SKEW-004 drops old-release holders
-- BEFORE that query, so an alt offered only by v1.4.1 peers reached DispatchList with no candidates,
-- was skipped, and stayed red for the session, credited to a peer that cannot serve us. Forty old
-- clients offer every bank on every cycle ("v1 is always red" is their compare), so that was every
-- tab, always. Such an offer is refused at OnOffer's door; and when a peer's version is learned only
-- after its offer got in, the filter emptying the list clears the red it raised.
describe("WIRE-SKEW-006: an old-release peer's offer", function()
	local sent, P2P, G
	before_each(function()
		env.reset(); client("Newguy")
		hold(BANKER, C(T, 0x20), T)
		sent = captureAll()
		P2P, G = TOGBankClassic_P2PSession, TOGBankClassic_Guild
		P2P.sessions, P2P.sessionsByAlt, P2P.pendingDispatch, P2P.activeSessions = {}, {}, {}, 0
		P2P.offers, P2P.versionQueries, P2P.isCollecting = {}, {}, true
		G.newerOfferedBy = {}
		G:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.4.1")
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v1.5.0")
		assert.equal("current", (G:GetAltStaleness(BANKER)), "precondition: the bank we hold must start yellow")
	end)

	it("is refused at the door: no red, nothing recorded -- while a capable peer's still counts", function()
		P2P:OnOffer(OLD, { [BANKER] = {} })
		assert.is_nil(G.newerOfferedBy[BANKER], "a v1.4.1 peer's bare offer turned the tab red for a bank we hold current")
		assert.is_nil(P2P.offers[BANKER], "a v1.4.1 peer was recorded as a holder to ask")
		assert.equal("current", (G:GetAltStaleness(BANKER)))
		-- The control: the same offer from a v1.5.0 peer is the claim TABCOLOUR-003 is about.
		P2P:OnOffer(NEW, { [BANKER] = {} })
		assert.equal(NEW, G.newerOfferedBy[BANKER], "the door refused a CAPABLE peer's offer too -- too wide")
		assert.equal(1, #P2P.offers[BANKER])
		assert.equal("offered", (G:GetAltStaleness(BANKER)))
	end)

	it("is not folded into a live session's candidates either", function()
		P2P.sessions["s"] = { sessionId = "s", altName = BANKER, peer = MYSTERY, state = "DISPATCHED", timers = {},
			triedPeers = { [MYSTERY] = true }, candidates = { { peer = MYSTERY, canon = C(T, 0x20) } } }
		P2P.sessionsByAlt[BANKER] = "s"
		local newer = { hashV2 = C(T + 10, 0x21), updatedAt = T + 10 }
		P2P:OnOffer(OLD, { [BANKER] = newer })
		assert.equal(1, #P2P.sessions["s"].candidates, "an old-release holder was added to a live session -- it will be advanced to and time out")
		P2P:OnOffer(NEW, { [BANKER] = newer })
		assert.equal(2, #P2P.sessions["s"].candidates, "the control: a capable peer's canon-bearing offer must still fold in")
	end)

	it("clears the red it raised when its version is learned only after the offer got in", function()
		-- MYSTERY is unknown when it offers, so the door lets it through and the tab goes red.
		P2P:OnOffer(MYSTERY, { [BANKER] = {} })
		assert.equal(MYSTERY, G.newerOfferedBy[BANKER], "precondition: an unknown peer's offer must raise the red, or this proves nothing")
		assert.equal("offered", (G:GetAltStaleness(BANKER)))
		-- Its broadcast lands during the window: v1.4.1. The window closes.
		G:NotePeerAddonVersion(MYSTERY, "TOGBankClassic-v1.4.1")
		local before = #sent
		P2P:Dispatch()
		assert.is_nil(G.newerOfferedBy[BANKER], "the tab stayed red for the session, credited to a peer that cannot serve us")
		assert.equal("current", (G:GetAltStaleness(BANKER)))
		assert.equal(before, #sent, "something was still sent for an alt nobody capable offered")
		assert.is_nil(P2P.versionQueries[BANKER])
	end)
end)

-- WIRE-SKEW-007: A PEER THAT BEHAVES LIKE THE OLD WIRE IS THE OLD WIRE, version claim or not.
--
-- The banker's log after a /reload, 2026-09-12: Garlii, Freezeplug and Venshea ACCEPTED (nobody had
-- named their version yet), each held a slot for the whole 30-second state-wait, released
-- `no_state_summary`, and were refused as v1.4.1 only minutes later once VersionCheck caught up --
-- three slots times thirty seconds, every login. Two things say "old wire" before any claim does:
-- the `togbank-state` summary a v1.4.1 requester whispers after our accept (registered again,
-- receive-only, never read -- the sender is the fact), and thirty seconds of silence.
describe("WIRE-SKEW-007: old-wire behaviour is remembered", function()
	local sent, P2P, G
	before_each(function()
		env.reset(); client("Bankchar")
		hold(BANKER, C(T, 0x20), T)
		sent = captureAll()
		P2P, G = TOGBankClassic_P2PSession, TOGBankClassic_Guild
		G.peerOldWire = {}
		assert.is_nil(G.peerAddonVersions[MYSTERY], "precondition: this peer's version must be unknown")
	end)

	it("hears a togbank-state summary through the real receive, frees the accepted slot at once, and refuses the peer from then on", function()
		assert.is_true(P2P:HandleSyncRequest("sid1", MYSTERY, BANKER, C(T, 0x20)), "precondition: an unknown peer is accepted")
		assert.equal(1, P2P:GetActiveSendTotal())
		-- The old wire's summary, in the old wire's format -- deliberately NOT this tree's checksum
		-- framing, because nothing in it may be read.
		TOGBankClassic_Chat:OnCommReceived("togbank-state", "^1^Sstate-summary^^", "WHISPER", MYSTERY)
		assert.equal(0, P2P:GetActiveSendTotal(), "the slot was held for the whole state-wait after the peer had already told us what it runs")
		assert.is_nil(next(P2P.stateWaits or {}), "a state-wait was left armed for a slot already released")
		local ok, why = G:PeerSpeaksDataLeg(MYSTERY)
		assert.is_false(ok, "a peer that sent the old wire's summary was still treated as capable")
		assert.equal("old wire (state-summary)", why)
		local n = #sent
		assert.is_false(P2P:HandleSyncRequest("sid2", MYSTERY, BANKER, C(T, 0x20)), "its next request took a slot")
		local busy = find(sent, function(m) return m.body and m.body.type == "sync-busy" and m.body.sessionId == "sid2" end)
		assert.is_table(busy, "the refused requester was told nothing"); assert.equal("addon_version", busy.body.reason)
		assert.equal(n + 1, #sent)
		assert.equal(0, P2P:GetActiveSendTotal())
	end)

	it("treats thirty seconds of silence after an accept the same way", function()
		assert.is_true(P2P:HandleSyncRequest("sid3", MYSTERY, BANKER, C(T, 0x20)))
		env.advance(31)
		assert.equal(0, P2P:GetActiveSendTotal(), "precondition: the state-wait must have released the slot")
		local ok, why = G:PeerSpeaksDataLeg(MYSTERY)
		assert.is_false(ok, "a peer that answered an accept with silence was given another slot to sit in")
		assert.equal("old wire (silent)", why)
	end)

	it("is outranked by a real version claim, in either direction", function()
		G:NotePeerOldWire(MYSTERY, "silent")
		assert.is_false((G:PeerSpeaksDataLeg(MYSTERY)))
		-- The claim arrives afterwards and names a capable release: the mark only said what the
		-- peer DID, the claim says what it RUNS.
		G:NotePeerAddonVersion(MYSTERY, "TOGBankClassic-v1.5.0")
		assert.is_true((G:PeerSpeaksDataLeg(MYSTERY)), "a v1.5.0 claim lost to an earlier silence -- a lost whisper refuses a capable peer for good")
		-- And a mark on a peer already known to be old changes nothing.
		G:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.4.1")
		G:NotePeerOldWire(OLD, "state-summary")
		local ok, why = G:PeerSpeaksDataLeg(OLD)
		assert.is_false(ok); assert.equal("TOGBankClassic-v1.4.1", why, "the version claim is the better answer when there is one")
	end)

	it("registers the tripwire prefix and documents it, and never sends on it", function()
		local registered = false
		for _, p in ipairs(TOGBankClassic_Chat.COMM_PREFIXES) do if p == "togbank-state" then registered = true end end
		assert.is_true(registered, "togbank-state is not registered -- the old wire's summary is never heard")
		assert.is_string(TOGBankClassic_Constants.COMM_PREFIX_DESCRIPTIONS["togbank-state"])
		-- Never sent: the provider's whole handshake against an old peer produces nothing on it.
		G:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.4.1")
		P2P:HandleSyncRequest("sid4", OLD, BANKER, C(T, 0x20))
		assert.is_nil(find(sent, function(m) return m.prefix == "togbank-state" end), "this tree sent on the retired prefix")
	end)
end)

-- WIRE-SKEW-008: A CLAIM FROM A PEER THAT CANNOT SERVE US MOVES NOTHING.
--
-- Both of the operator's v1.5.0 clients, 2026-09-12: Elementals -- ONLINE, its author's own client
-- holding canon 1789076374..., Galdof holding the identical one -- read "Behind" on both, and the
-- author's client logged `a peer holds a LATER version of this character than this PC` under a
-- reply naming the very canon it held. Nothing newer existed: five v1.4.1 relays had advertised
-- Elementals with a later publish time than the author's (the old release still stamps the clock
-- onto timestamp-less saved data on load), and every claim path took the maximum with no regard for
-- who was claiming. One lie set Galdof's tab red, the author's own tab red, and had the author
-- fetching a phantom diff base before it would publish a rescan. Red means "on its way", and nothing
-- is on its way from a release we do not speak.
describe("WIRE-SKEW-008: claims from an old-release peer", function()
	local G, newer
	-- A VIEWER holding the banker's copy (the Galdof side); the self-holder example stands up the
	-- author instead, because the tab and the cache both refuse claims about our own character on
	-- their own rules and would pass the control for the wrong reason.
	local function viewer()
		env.reset(); client("Newguy")
		hold(BANKER, C(T, 0x20), T)
		G = TOGBankClassic_Guild
		G.newestAdvertisedAt, G.newestAdvertisedBy, G.latestBankerHashes, G.refusedNewerBy = {}, {}, {}, {}
		TOGBankClassic_Bank.newerSelf = nil
		G:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.4.1")
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v1.5.0")
		newer = { hashV2 = C(T + 600, 0x21), updatedAt = T + 600 }
		assert.equal("current", (G:GetAltStaleness(BANKER)), "precondition: the bank we hold must start yellow")
	end
	before_each(viewer)

	-- TAB-STATE-003 (Peer Review 498a84f3 F3): the refused claim moves nothing that fetches, but
	-- "Current" was false of what exists. A third state, GREY: a newer copy is held only where this
	-- release cannot fetch it. Red still wins the moment a capable peer claims the same or newer.
	it("do not move the tab red -- they turn it GREY, naming the peer and its version, while the same claim from a capable peer turns it red", function()
		assert.is_false(G:NoteAdvertisedPublishTime(BANKER, newer, OLD), "a v1.4.1 relay's later timestamp turned a current bank red")
		local state, heldAt, newestAt, peer, version = G:GetAltStaleness(BANKER)
		assert.equal("refused", state)
		assert.equal(T, heldAt); assert.equal(0, newestAt, "a refused claim raised the newest-advertised time")
		assert.equal(OLD, peer); assert.equal("TOGBankClassic-v1.4.1", version)
		assert.is_nil(G.newestAdvertisedBy[BANKER])
		assert.is_true(G:NoteAdvertisedPublishTime(BANKER, newer, NEW), "the control: a capable peer's claim must still raise it")
		assert.equal("behind", (G:GetAltStaleness(BANKER)))
		assert.equal(NEW, G.newestAdvertisedBy[BANKER].peer)
		assert.is_nil(G.refusedNewerBy[BANKER], "the refused record outlived the capable claim that made it irrelevant")
	end)

	it("keep the grey only while the refused claim is newer than the copy held, and never for an older claim, our own name, or a non-banker", function()
		-- An OLDER claim from a refused peer is nothing at all.
		assert.is_false(G:NoteAdvertisedPublishTime(BANKER, { hashV2 = C(T - 600, 0x19), updatedAt = T - 600 }, OLD))
		assert.equal("current", (G:GetAltStaleness(BANKER)))
		-- The newest refused claim is the one kept.
		assert.is_false(G:NoteAdvertisedPublishTime(BANKER, newer, OLD))
		assert.is_false(G:NoteAdvertisedPublishTime(BANKER, { hashV2 = C(T + 300, 0x22), updatedAt = T + 300 }, OLD))
		assert.equal(T + 600, G.refusedNewerBy[BANKER].at, "an older refused claim replaced a newer one")
		assert.is_false(G:NoteAdvertisedPublishTime(BANKER, { hashV2 = C(T + 900, 0x23), updatedAt = T + 900 }, OLD))
		assert.equal(T + 900, G.refusedNewerBy[BANKER].at)
		-- The copy catches up (a delivery from anyone that stores a canon at or past it): grey gone.
		hold(BANKER, C(T + 900, 0x23), T + 900)
		assert.equal("current", (G:GetAltStaleness(BANKER)), "the grey outlived the copy catching up")
		-- Our own character never goes grey (MULTIPC-001 owns that name); nor does a non-banker.
		assert.is_false(G:NoteRefusedNewer(G:GetNormalizedPlayer(), T + 9999, OLD))
		assert.is_false(G:NoteRefusedNewer(OLD, T + 9999, NEW))
		assert.is_nil(G.refusedNewerBy[G:GetNormalizedPlayer()]); assert.is_nil(G.refusedNewerBy[OLD])
	end)

	it("do not enter the advertised-hash cache", function()
		assert.is_false(G:NoteAdvertisedHashes(BANKER, newer, OLD), "a v1.4.1 relay's claim entered the cache that drives fetching and catch-up")
		assert.is_nil(G.latestBankerHashes[BANKER])
		assert.is_true(G:NoteAdvertisedHashes(BANKER, newer, NEW), "the control")
		assert.equal(newer, G.latestBankerHashes[BANKER])
	end)

	it("do not record a phantom newer version of our OWN character, so the publish gate is not held on it", function()
		env.reset(); client("Bankchar")
		hold(BANKER, C(T, 0x20), T)
		G = TOGBankClassic_Guild
		TOGBankClassic_Bank.newerSelf = nil
		G:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.4.1")
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v1.5.0")
		local me = G:GetNormalizedPlayer()
		assert.equal(BANKER, me, "precondition: this client is the author")
		assert.is_false(G:NoteSelfHolder(newer.hashV2, OLD), "a v1.4.1 relay's claim about our own bank was recorded as a diff base to fetch")
		assert.is_nil(TOGBankClassic_Bank.newerSelf)
		assert.is_nil(G:NewerSelfVersionAt())
		assert.is_true(G:NoteSelfHolder(newer.hashV2, NEW), "the control")
		assert.equal(newer.hashV2, TOGBankClassic_Bank.newerSelf.canon)
	end)

	-- Self-audit: the hash-list REPLY handler refused the claims (every Note* gated) and then, in its
	-- second pass, turned the same claims into one BroadcastP2PRequest per alt -- a guild broadcast
	-- each, on an old release's publish times. And RequestHashListFromBanker would pick that banker
	-- to ask in the first place, for a reply it then ignores.
	it("are dropped whole at the hash-list-reply handler too: no guild alt-request for what an old release claims", function()
		local sent = captureAll()
		local reply = TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-list-reply", banker = OLD,
			alts = { [BANKER] = { hash = 0x99, hashV2 = newer.hashV2, updatedAt = newer.updatedAt, mailHash = 0 } } })
		TOGBankClassic_Chat:OnCommReceived("togbank-hlr", reply, "WHISPER", OLD)
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "alt-request" end),
			"a v1.4.1 banker's hash list produced a guild alt-request -- the fast-fill burst behind the ACK storm")
		assert.equal("current", (G:GetAltStaleness(BANKER)))
		-- The control: the same reply from a capable banker asks the guild for it.
		G:NotePeerAddonVersion(MYSTERY, "TOGBankClassic-v1.5.0")
		TOGBankClassic_Chat:OnCommReceived("togbank-hlr", reply, "WHISPER", MYSTERY)
		assert.is_table(find(sent, function(m) return m.body and m.body.type == "alt-request" end),
			"the control: a capable banker's newer claim must still be requested")
	end)

	it("are not asked for a hash list when a capable banker could be asked instead", function()
		-- OLD is the only banker online: nothing is whispered to it, the no-banker path runs instead.
		TOGBankClassic_Guild.Info.alts[OLD] = TOGBankClassic_Guild.Info.alts[OLD] or { name = OLD }
		local roster = TOGBankClassic_Guild.memberRoster
		roster[OLD].isBank = true
		TOGBankClassic_Guild:InvalidateBanksCache()
		assert.is_true(TOGBankClassic_Guild:IsBank(OLD), "precondition: OLD must be a banker for this to prove anything")
		assert.is_true(TOGBankClassic_Guild:IsPlayerOnline(OLD), "precondition: OLD must be online")
		-- The only OTHER banker goes offline THROUGH THE ROSTER LIBRARY, which IsPlayerOnline reads
		-- first (ROSTER-003); a memberRoster flip alone leaves it online there.
		local lib = LibStub("LibGuildRoster-1.0", true)
		assert.is_table(lib, "precondition: the roster library must be loaded for presence to be driven")
		env.fireGuildRosterEvent(lib, "CHAT_MSG_SYSTEM", "Bankchar has gone offline.")
		TOGBankClassic_Guild:UpdateOnlineMember(BANKER, false, "spec")
		assert.is_false(TOGBankClassic_Guild:IsPlayerOnline(BANKER), "precondition: OLD must be the only banker online, or the picker may never reach it")
		local sent = captureAll()
		TOGBankClassic_Guild:RequestHashListFromBanker()
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "hash-list-request" end),
			"asked a v1.4.1 banker for a hash list whose reply is then ignored")
		-- The control: once OLD is on the new release it is asked.
		TOGBankClassic_Guild:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.5.0")
		TOGBankClassic_Guild:RequestHashListFromBanker()
		local ask = find(sent, function(m) return m.body and m.body.type == "hash-list-request" end)
		assert.is_table(ask, "the control: a capable banker is not asked either -- the picker is broken, not gated")
		assert.equal(OLD, ask.target)
	end)

	it("are dropped whole at the broadcast handler, through the real receive: no tab, no cache, no offer back", function()
		TOGBankClassic_Chat.hashBroadcastQueue = TOGBankClassic_Chat.hashBroadcastQueue or {}
		TOGBankClassic_Chat.HASH_BROADCAST_BATCH_DELAY = TOGBankClassic_Chat.HASH_BROADCAST_BATCH_DELAY or 0.15
		local BN = TOGBankClassic_BankerNumbers
		local roster = BN:Table()
		roster.numbers[BANKER] = 1
		roster.numbersVersion = roster.numbersVersion + 1
		assert.equal("0001", BN:NumberOf(BANKER), "precondition: without a number the broadcast names nothing and this proves nothing")
		local sent = captureAll()
		local function broadcastFrom(who, version)
			local body = TOGBankClassic_Core:SerializeWithChecksum({
				type = "hlb2", v = BN:Version(), banker = who, isBanker = false, addon = version,
				e = BN:EncodeEntries({ { number = BN:NumberOf(BANKER), canon = newer.hashV2 } }),
			})
			TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "GUILD", who)
			assert.equal(1, #TOGBankClassic_Chat.hashBroadcastQueue, "precondition: the broadcast from " .. who .. " was not queued -- the path under test never ran")
			TOGBankClassic_Chat:ProcessQueuedHashBroadcasts()
		end
		broadcastFrom(OLD, "TOGBankClassic-v1.4.1")
		assert.equal("current", (G:GetAltStaleness(BANKER)), "a v1.4.1 broadcast naming a later canon turned the tab red")
		assert.is_nil(G.latestBankerHashes[BANKER])
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "hash-offer2" end),
			"we offered our copy to a peer that cannot fetch it -- that is the sync-request we then refuse")
		-- The control: the identical broadcast from a v1.5.0 peer does all three. MYSTERY, not NEW:
		-- this client IS Newguy, and its own broadcast is dropped at the door as our own message --
		-- which passed the first half of this example for the wrong reason until the control caught it.
		broadcastFrom(MYSTERY, "TOGBankClassic-v1.5.0")
		assert.equal("behind", (G:GetAltStaleness(BANKER)), "the control: a capable peer's broadcast must still raise the tab")
		assert.is_table(G.latestBankerHashes[BANKER])
	end)
end)
