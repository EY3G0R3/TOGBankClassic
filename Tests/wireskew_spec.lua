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

-- LIBREQ-DS-008 part 2 (2026-09-15): the handshake, the offer and the version query are DeltaSync's
-- numbered P2P (`TOGBankClassic_P2P:Lib()`); TOGBank's gate (PeerSpeaksDataLeg) reaches it as the
-- `peerCapable` hook, which the library asks at every door -- the offer, the broadcast, the queue
-- drain, the request, every dispatch. The data leg changed AGAIN with that adoption (the whole wire
-- moved onto the host's prefixes), so DATA_LEG_MIN_ADDON_VERSION is 1.6.0 and a v1.5.1 client is
-- "old" here exactly as v1.4.1 was: KNOWN COST, one wire break, stated in the CHANGELOG.
local CAPABLE = "1.6.0"

local function client(who)
	env.standUpClient(who, { { name = BANKER, note = "gbank" }, { name = OLD }, { name = NEW }, { name = MYSTERY } }, GUILD)
	-- The numbered wire names bankers by NUMBER; every client here holds the same table.
	TOGBankClassic_BankerNumbers:Adopt({ v = 5, n = 2, t = { [BANKER] = 1 } }, NEW)
	assert.equal("0001", TOGBankClassic_BankerNumbers:NumberOf(BANKER), "precondition: the numbers table was not adopted")
end

--- The library's numbered P2P on this client's host.
local function p2p()
	local lib = TOGBankClassic_P2P:Lib()
	assert.is_table(lib, "precondition: the host has no numbered P2P")
	return lib
end

local function host() return TOGBankClassic_Core:DeltaHost() end

--- A bare numbered offer for the banker, as a peer whispers it.
local function bareOffer()
	return { type = "hash-offer2", v = TOGBankClassic_BankerNumbers:Version(), n = TOGBankClassic_BankerNumbers:EncodeNumbers({ "0001" }) }
end

--- A numbered broadcast naming the banker with `canon`, as a peer on `version` sends it.
local function hlb2(canon, version)
	local BN = TOGBankClassic_BankerNumbers
	return { type = "hlb2", v = BN:Version(), addon = version, e = BN:EncodeEntries({ { number = "0001", canon = canon } }) }
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
		-- The target in TOGBank's `Name-Realm` spelling whichever address rule sent it (the host's
		-- sends are addressed by SendWhisper's rule: bare for same-realm).
		sent[#sent + 1] = { channel = byChannel[prefix] or prefix, prefix = prefix, body = decoded, dist = dist,
			target = target and (TOGBankClassic_Guild:NormalizeName(target) or target) or nil }
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
	-- Two real receives, because a v1.4.1-v1.5.1 client broadcasts on togbank-hl (read there for its
	-- versions and nothing else since LIBREQ-DS-008) and a client on this build on the host's OFFER
	-- prefix, where the library acts on it -- and TOGBank must have read the version BEFORE the
	-- library asks the gate about that same sender (the library fires onOfferReceived first,
	-- LIBREQ-DS-008 ask 3).
	it("reads the version off the hlb2 broadcast, through the real receive, in the packager's tag form", function()
		local G = TOGBankClassic_Guild
		local body = TOGBankClassic_Core:SerializeWithChecksum({ type = "hlb2", v = 0, e = "", banker = OLD, isBanker = false, addon = "TOGBankClassic-v1.4.1" })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", body, "GUILD", OLD)
		assert.equal("TOGBankClassic-v1.4.1", G.peerAddonVersions[OLD], "the broadcast's addon version was not recorded")
		local ok, why = G:PeerSpeaksDataLeg(OLD)
		assert.is_false(ok, "a released v1.4.1 peer was read as capable -- the tag prefix defeated the version match")
		assert.equal("TOGBankClassic-v1.4.1", why)
		-- The host's prefix: the version is read there too.
		host():OnComm_OFFER(host().prefixes.OFFER, TOGBankClassic_Core:SerializeWithChecksum(hlb2(C(T, 0x20), "TOGBankClassic-v1.5.1")), "GUILD", MYSTERY)
		assert.equal("TOGBankClassic-v1.5.1", G.peerAddonVersions[MYSTERY], "the host-prefix broadcast's addon version was not recorded")
		assert.is_false((G:PeerSpeaksDataLeg(MYSTERY)), "a v1.5.1 peer was read as capable: the wire moved with LIBREQ-DS-008 and that release cannot complete it")
	end)

	it("is false before " .. CAPABLE .. ", true from " .. CAPABLE .. ", true for a peer never heard from, true for a dev build", function()
		local G = TOGBankClassic_Guild
		G:NotePeerAddonVersion(OLD, "1.4.1")
		G:NotePeerAddonVersion(NEW, CAPABLE)
		assert.is_false(G:PeerSpeaksDataLeg(OLD))
		assert.is_true(G:PeerSpeaksDataLeg(NEW))
		-- The same two, as the packager spells them on a released client.
		G:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.4.1")
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v" .. CAPABLE)
		assert.is_false(G:PeerSpeaksDataLeg(OLD))
		assert.is_true(G:PeerSpeaksDataLeg(NEW))
		G:NotePeerAddonVersion(NEW, "1.10.0")
		assert.is_true(G:PeerSpeaksDataLeg(NEW), "a two-digit minor ranked below " .. CAPABLE .. " (PROTO-001's class)")
		local ok, why = G:PeerSpeaksDataLeg(MYSTERY)
		assert.is_true(ok, "a peer we have not heard from was refused -- that refuses the operator's own clients at login")
		assert.equal("unknown", why)
		G:NotePeerAddonVersion(MYSTERY, "@project-version@")
		ok, why = G:PeerSpeaksDataLeg(MYSTERY)
		assert.is_true(ok); assert.equal("dev", why)
		assert.equal(CAPABLE, TOGBankClassic_Constants.PROTOCOL.DATA_LEG_MIN_ADDON_VERSION)
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
		VC:RecordPeerVersion(NEW, "TOGBankClassic", "TOGBankClassic-v1.6.0", "REQ")
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
		VC:RecordPeerVersion(NEW, "TOGBankClassic", "TOGBankClassic-v1.6.0", "REQ")
		assert.is_true((G:PeerSpeaksDataLeg(NEW)), "a stale broadcast refused a peer that had updated")
		-- Stale VERSIONCHECK, fresh broadcast -- the case a VersionCheck-wins rule would get wrong,
		-- and the one the operator's congestion note is about.
		VC:RecordPeerVersion(MYSTERY, "TOGBankClassic", "TOGBankClassic-v1.4.1", "REQ")
		G:NotePeerAddonVersion(MYSTERY, "TOGBankClassic-v1.6.0")
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
		VC:RecordPeerVersion(NEW, "TOGBankClassic", "TOGBankClassic-v1.6.0", "REQ")
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
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v1.6.0")
		assert.equal("TOGBankClassic-v1.6.0", mem[NEW].version)
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v1.4.1")
		assert.equal("TOGBankClassic-v1.6.0", mem[NEW].version, "an older claim rewound the memory")
		-- A reload: the session sources are gone, the memory is not.
		VC.peerVersions = {}
		G.peerAddonVersions = {}
		local raw, remembered = G:LastSeenAddonVersion(OLD)
		assert.equal("TOGBankClassic-v1.3.2", raw); assert.is_true(remembered)
		-- The sync gate still says unknown -> capable: memory is not a refusal.
		local ok, why = G:PeerSpeaksDataLeg(OLD)
		assert.is_true(ok, "the sync gate refused a peer on a REMEMBERED version"); assert.equal("unknown", why)
		-- A live sighting outranks the memory and refreshes it.
		VC:RecordPeerVersion(OLD, "TOGBankClassic", "TOGBankClassic-v1.6.0", "RSP")
		raw, remembered = G:LastSeenAddonVersion(OLD)
		assert.equal("TOGBankClassic-v1.6.0", raw); assert.is_false(remembered)
		assert.equal("TOGBankClassic-v1.6.0", mem[OLD].version)
		-- Never seen anywhere: nil. With no guild record the live source still answers and the
		-- memory is simply absent -- no error either way.
		assert.is_nil((G:LastSeenAddonVersion(MYSTERY)))
		local info = G.Info; G.Info = nil
		raw, remembered = G:LastSeenAddonVersion(OLD)
		assert.equal("TOGBankClassic-v1.6.0", raw); assert.is_false(remembered)
		assert.is_nil((G:LastSeenAddonVersion(MYSTERY)))
		G:RememberPeerAddonVersion(OLD, "1.0.0")   -- no record: nothing to write to, no error
		G.Info = info
		assert.equal("TOGBankClassic-v1.6.0", mem[OLD].version, "a write with no record reached the memory")
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
		local P2P = p2p()
		VC:RecordPeerVersion(OLD, "TOGBankClassic", "TOGBankClassic-v1.4.1", "REQ")
		-- THE ALT NEEDS A BANKER NUMBER or BeginVersionQuery returns before it sends anything, and
		-- both assertions below would hold for a reason that has nothing to do with the fix. Found
		-- exactly that way: this example stayed green against the deliberately-reverted code while
		-- its three siblings went red. Asserted, not assumed, so it cannot rot back into a skip.
		assert.equal("0001", TOGBankClassic_BankerNumbers:NumberOf(BANKER),
			"precondition: without a banker number the version query never sends and this example proves nothing")
		local sent = captureAll()
		-- One alt, one holder, that holder on the old release and carrying no version for the alt --
		-- the exact shape that produced a ver-query and then a dispatch timeout.
		P2P:DispatchOrQuery({ { key = BANKER, candidates = { { peer = OLD, updatedAt = T } } } })
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
		P2P = p2p()
		TOGBankClassic_Guild:NotePeerAddonVersion(OLD, "1.4.1")
		TOGBankClassic_Guild:NotePeerAddonVersion(NEW, CAPABLE)
	end)

	-- WIRE-SKEW-005: THE SECOND DOOR INTO AcceptSend. HandleSyncRequest refuses an old requester
	-- before it can take a slot, but a requester QUEUED while we were at capacity comes back through
	-- ServeQueue, which only ever re-checked whether the content still exists. Read off the
	-- operator's live log 2026-09-12, after the WIRE-SKEW-004 fix was already running: Cinia,
	-- Zurayli, Groucho and Bilgoth each appear REFUSED on one line and ACCEPTED on another, and every
	-- accept follows a ReleaseSendSlot -- which is this drain. Each one then burned the full
	-- 30-second state-wait and released with `no_state_summary`.
	-- LIBREQ-DS-008: the library's ServeQueue asks peerCapable again at the drain, and its busy
	-- reason for a refused release is "version" (the one reason word for "not this candidate").
	it("refuses an old-release requester at QUEUE DRAIN too, instead of accepting it into a slot", function()
		P2P:EnqueueSend("sidq", OLD, BANKER)
		P2P:ServeQueue()
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "sync-accept" end),
			"the queue drain accepted an old-release peer -- it takes a send slot and burns the 30s state-wait")
		local busy = find(sent, function(m) return m.body and m.body.type == "sync-busy" end)
		assert.is_table(busy, "the refused requester was told nothing, so its session hangs rather than moving on")
		assert.equal("version", busy.body.reason)
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
		assert.equal("version", busy.body.reason)
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
		P2P = p2p()
		P2P.sessions, P2P.sessionsByKey, P2P.pendingDispatch, P2P.activeSessions = {}, {}, {}, 0
		TOGBankClassic_Guild:NotePeerAddonVersion(OLD, "1.4.1")
		TOGBankClassic_Guild:NotePeerAddonVersion(BANKER, CAPABLE)
	end)

	it("does not ask a holder on the old release; asks the capable one; parks nothing when nobody capable holds it", function()
		P2P:DispatchList({ { key = BANKER, candidates = {
			{ peer = OLD, canon = C(T, 0x20), updatedAt = T + 5 },   -- freshest sidecar, would be picked first
			{ peer = BANKER, canon = C(T, 0x20), updatedAt = T },
		} } })
		local req = find(sent, function(m) return m.body and m.body.type == "sync-request" end)
		assert.is_table(req, "no sync-request went out")
		assert.equal(BANKER, req.target, "the old-release holder was asked; it will accept and never answer the query (180s)")
		-- Nobody capable: nothing dispatched, nothing parked, no error.
		P2P.sessions, P2P.sessionsByKey = {}, {}
		local before = #sent
		P2P:DispatchList({ { key = "Otherbank-Testrealm", candidates = { { peer = OLD, canon = C(T, 0x21), updatedAt = T } } } })
		assert.equal(before, #sent)
		assert.equal(0, #P2P.pendingDispatch, "an alt with no capable holder was parked forever")
	end)

	it("drops an old-release holder folded into a live session when it advances", function()
		P2P.sessions["s"] = { sessionId = "s", key = BANKER, peer = MYSTERY, state = "DISPATCHED", timers = {},
			triedPeers = { [MYSTERY] = true },
			candidates = { { peer = MYSTERY, canon = C(T, 0x20) }, { peer = OLD, canon = C(T, 0x20) }, { peer = BANKER, canon = C(T, 0x20) } } }
		P2P.sessionsByKey[BANKER] = "s"
		P2P:AdvanceCandidate("s", "timeout")
		assert.equal(BANKER, P2P.sessions["s"].peer, "the session advanced to the old-release holder")
	end)

	-- writ-cannot: "ignores a pull-path ACK from an old-release relay rather than querying it" WAS
	-- HERE and must not exist any more -- the feature it covered was removed on purpose. The pull path
	-- (Guild:BroadcastP2PRequest, the togbank-rr `alt-request-reply` ACK, Guild.pendingP2PRequests)
	-- is deleted with LIBREQ-DS-008 part 2 (directive #12702, "strip the chaff out of TOGBank"):
	-- nothing sends the request, the prefix is unregistered, and nothing hears the ACK, so there is
	-- no relay to be queried. The rule it pinned -- a QUERY never goes to a release that cannot
	-- answer it -- is the dispatch gate the two examples above pin on the library's session path.
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
		P2P, G = p2p(), TOGBankClassic_Guild
		P2P.sessions, P2P.sessionsByKey, P2P.pendingDispatch, P2P.activeSessions = {}, {}, {}, 0
		P2P.offers, P2P.versionQueries, P2P.isCollecting = {}, {}, true
		G.newerOfferedBy = {}
		G:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.4.1")
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v1.6.0")
		assert.equal("current", (G:GetAltStaleness(BANKER)), "precondition: the bank we hold must start yellow")
	end)

	-- LIBREQ-DS-008: the bare offer is the library's `hash-offer2` (numbers, no canon) and the
	-- canon-bearing claim is its hlb2 broadcast; both doors ask TOGBank's gate as `peerCapable`.
	it("is refused at the door: no red, nothing recorded -- while a capable peer's still counts", function()
		P2P:OnOffer(OLD, bareOffer())
		assert.is_nil(G.newerOfferedBy[BANKER], "a v1.4.1 peer's bare offer turned the tab red for a bank we hold current")
		assert.is_nil(P2P.offers[BANKER], "a v1.4.1 peer was recorded as a holder to ask")
		assert.equal("current", (G:GetAltStaleness(BANKER)))
		-- The control: the same offer from a capable peer is the claim TABCOLOUR-003 is about.
		P2P:OnOffer(NEW, bareOffer())
		assert.equal(NEW, G.newerOfferedBy[BANKER], "the door refused a CAPABLE peer's offer too -- too wide")
		assert.equal(1, #P2P.offers[BANKER])
		assert.equal("offered", (G:GetAltStaleness(BANKER)))
	end)

	it("is not folded into a live session's candidates either", function()
		P2P.sessions["s"] = { sessionId = "s", key = BANKER, peer = MYSTERY, state = "DISPATCHED", timers = {},
			triedPeers = { [MYSTERY] = true }, candidates = { { peer = MYSTERY, canon = C(T, 0x20) } } }
		P2P.sessionsByKey[BANKER] = "s"
		local newer = C(T + 10, 0x21)
		P2P:OnBroadcast(OLD, hlb2(newer, "TOGBankClassic-v1.4.1"))
		assert.equal(1, #P2P.sessions["s"].candidates, "an old-release holder was added to a live session -- it will be advanced to and time out")
		P2P:OnBroadcast(NEW, hlb2(newer, "TOGBankClassic-v1.6.0"))
		assert.equal(2, #P2P.sessions["s"].candidates, "the control: a capable peer's canon-bearing offer must still fold in")
	end)

	it("clears the red it raised when its version is learned only after the offer got in", function()
		-- MYSTERY is unknown when it offers, so the door lets it through and the tab goes red.
		P2P:OnOffer(MYSTERY, bareOffer())
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
--
-- writ-cannot: the four examples that stood here -- "hears a togbank-state summary through the real
-- receive, frees the accepted slot at once, and refuses the peer from then on", "treats thirty
-- seconds of silence after an accept the same way", "is outranked by a real version claim, in either
-- direction", "registers the tripwire prefix and documents it, and never sends on it" -- must not
-- exist any more: the feature they covered was removed on purpose. LIBREQ-DS-008 part 2 (directive
-- #12702) deleted Guild:NotePeerOldWire / Guild.peerOldWire and unregistered the `togbank-state`
-- tripwire prefix (Modules/Guild.lua, the note above PeerSpeaksDataLeg): the state-wait is the
-- library's, a v1.4.1 requester is refused by its VERSION (VersionCheck names it at login, its own
-- broadcast names it, WIRE-SKEW-004), and the whole handshake now runs on the host's prefixes,
-- where a v1.4.1 client never speaks at all. What survives of the rule is below: the retired
-- prefix is gone from the registration and from the descriptions, and nothing is sent on it.
describe("WIRE-SKEW-007: the old-wire tripwire is retired with the pull path", function()
	it("does not register the tripwire prefix, does not describe it, and never sends on it", function()
		env.reset(); client("Bankchar")
		hold(BANKER, C(T, 0x20), T)
		local sent = captureAll()
		for _, p in ipairs(TOGBankClassic_Chat.COMM_PREFIXES) do
			assert.not_equal("togbank-state", p, "togbank-state is registered again -- the old wire's summary has no reader on this build")
		end
		assert.is_nil(TOGBankClassic_Constants.COMM_PREFIX_DESCRIPTIONS["togbank-state"], "a description outlived the prefix")
		assert.is_nil(TOGBankClassic_Guild.NotePeerOldWire, "the old-wire observer is back")
		-- The provider's whole handshake against an old peer produces nothing on it, and the old
		-- wire's summary arriving on it reaches nothing (the prefix has no branch; no error either).
		TOGBankClassic_Guild:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.4.1")
		p2p():HandleSyncRequest("sid4", OLD, BANKER, C(T, 0x20))
		assert.is_nil(find(sent, function(m) return m.prefix == "togbank-state" end), "this tree sent on the retired prefix")
		assert.has_no_error(function()
			TOGBankClassic_Chat:OnCommReceived("togbank-state", "^1^Sstate-summary^^", "WHISPER", MYSTERY)
		end)
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
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v1.6.0")
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
		G:NotePeerAddonVersion(NEW, "TOGBankClassic-v1.6.0")
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
	it("are dropped whole at the hash-list-reply handler too: no request for what an old release claims", function()
		local sent = captureAll()
		local reply = TOGBankClassic_Core:SerializeWithChecksum({ type = "hash-list-reply", banker = OLD,
			alts = { [BANKER] = { hash = 0x99, hashV2 = newer.hashV2, updatedAt = newer.updatedAt, mailHash = 0 } } })
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", reply, "WHISPER", OLD)
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "sync-request" end),
			"a v1.4.1 banker's hash list produced a request to it -- a session that sits out the delivery watchdog")
		assert.equal("current", (G:GetAltStaleness(BANKER)))
		-- The control: the same reply from a capable banker is asked for it (LIBREQ-DS-008: the
		-- library's sync-request to the replier, not the pull path's guild alt-request).
		G:NotePeerAddonVersion(MYSTERY, "TOGBankClassic-v1.6.0")
		TOGBankClassic_Chat:OnCommReceived("togbank-hl", reply, "WHISPER", MYSTERY)
		local req = find(sent, function(m) return m.body and m.body.type == "sync-request" end)
		assert.is_table(req, "the control: a capable banker's newer claim must still be requested")
		assert.equal(MYSTERY, req.target)
		assert.equal(BANKER, req.body.itemKey)
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
		TOGBankClassic_Guild:NotePeerAddonVersion(OLD, "TOGBankClassic-v1.6.0")
		TOGBankClassic_Guild:RequestHashListFromBanker()
		local ask = find(sent, function(m) return m.body and m.body.type == "hash-list-request" end)
		assert.is_table(ask, "the control: a capable banker is not asked either -- the picker is broken, not gated")
		assert.equal(OLD, ask.target)
	end)

	-- LIBREQ-DS-008 part 2: the broadcast arrives on the host's OFFER prefix and the LIBRARY judges
	-- it (the gate as peerCapable, the caches through onAdvertised, the offer back). The version it
	-- carries must have been read before that judgement -- DeltaSync fires Core's onOfferReceived
	-- first (LIBREQ-DS-008 ask 3); the first example below drives a peer
	-- neither VersionCheck nor any earlier broadcast has named, which is the case that ordering
	-- decides.
	local function broadcastFrom(who, version)
		host():OnComm_OFFER(host().prefixes.OFFER, TOGBankClassic_Core:SerializeWithChecksum(hlb2(newer.hashV2, version)), "GUILD", who)
	end

	-- TAB-STATE-003 reaches this path now: the old broadcast handler dropped the claim before any
	-- Note* saw it (so the tab stayed YELLOW, false of what exists); the library reports every claim
	-- through onAdvertised and the gate inside NoteAdvertisedPublishTime files a refused peer's newer
	-- claim as GREY -- the same answer the first example of this describe pins for the reply path.
	-- One rule for every path, which is what the rule was for.
	it("are dropped whole at the broadcast handler, through the real receive: grey not red, no cache, no offer back, no request", function()
		assert.equal("0001", TOGBankClassic_BankerNumbers:NumberOf(BANKER), "precondition: without a number the broadcast names nothing and this proves nothing")
		local sent = captureAll()
		broadcastFrom(OLD, "TOGBankClassic-v1.4.1")
		local state, _, newestAt, peer = G:GetAltStaleness(BANKER)
		assert.equal("refused", state, "a v1.4.1 broadcast naming a later canon turned the tab red, or left it yellow as if nothing newer existed")
		assert.equal(0, newestAt, "a refused claim raised the newest-advertised time")
		assert.equal(OLD, peer)
		assert.is_nil(G.latestBankerHashes[BANKER])
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "hash-offer2" end),
			"we offered our copy to a peer that cannot fetch it -- that is the sync-request we then refuse")
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "sync-request" end),
			"we asked a peer that cannot serve us for the version it advertised")
		-- The control: the identical broadcast from a capable peer does all of it. MYSTERY, not NEW:
		-- this client IS Newguy, and its own broadcast is dropped at the door as our own message --
		-- which passed the first half of this example for the wrong reason until the control caught it.
		broadcastFrom(MYSTERY, "TOGBankClassic-v1.6.0")
		assert.equal("behind", (G:GetAltStaleness(BANKER)), "the control: a capable peer's broadcast must still raise the tab")
		assert.is_table(G.latestBankerHashes[BANKER])
		local req = find(sent, function(m) return m.body and m.body.type == "sync-request" end)
		assert.is_table(req, "the control: a capable peer's newer claim must be requested from it")
		assert.equal(MYSTERY, req.target)
	end)

	it("are dropped even when the broadcast is the FIRST word from that peer -- its own `addon` field is read before the library judges it", function()
		-- Nobody has named OLD's version yet: not VersionCheck (a LibStub library, whose table
		-- outlives env.reset -- the WIRE-SKEW-004 describe above recorded OLD there), not an earlier
		-- broadcast. Both cleared for OLD to make that so.
		G.peerAddonVersions[OLD] = nil
		if G.Info.peerAddonVersions then G.Info.peerAddonVersions[OLD] = nil end
		local VC = LibStub("VersionCheck-1.0", true)
		if VC then VC.peerVersions = {} end
		assert.is_true((G:PeerSpeaksDataLeg(OLD)), "precondition: with no version known the gate must read OLD as capable")
		local sent = captureAll()
		broadcastFrom(OLD, "TOGBankClassic-v1.4.1")
		assert.is_false((G:PeerSpeaksDataLeg(OLD)), "the broadcast's own version was not read")
		assert.equal("refused", (G:GetAltStaleness(BANKER)),
			"the library judged the broadcast before its version was read: a v1.4.1 peer's first word turned the tab red")
		assert.is_nil(G.latestBankerHashes[BANKER], "... and entered the fetch cache")
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "sync-request" end),
			"... and was dispatched to -- a session that sits out the 180 s delivery watchdog (the WIRE-SKEW-004 hours, again)")
		assert.is_nil(find(sent, function(m) return m.body and m.body.type == "hash-offer2" end))
	end)
end)
