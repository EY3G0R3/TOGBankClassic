# Cross-guild bank -- sister-guild members use the bank (XGUILD-SYNC-001 / XGUILD-LABEL-001)

Design note, 2026-09-14. The directives it answers, in the operator's words:

- XGUILD-SYNC-001 (19:05): _"now that we have the sister guild roster in guildroster, can we look
  at opening the bank up to work for sister guild members? and do the full sync through greenwall
  somehow? / use greenwall for the broadcast, then do the rest in whispers?"_
- XGUILD-LABEL-001 (19:28): _"we're going to need some way (label or something) which bankers are
  in which guild."_ -- built as part of this, not after it.

Status: **BUILT (steps 2-6), NOT SEEN IN A CLIENT.** Section 6 is the build order and says where
each leg stands and what it found.

## 1. What was read, and what it settles

Everything below was read in the installed source on 2026-09-14; nothing is recalled.

### 1.1 GreenWall's bridge cannot carry a timer-fired broadcast

GreenWall exposes a transport API (`GreenWall/API.lua`): `GreenWallAPI.SendMessage(addon, message)`
and `GreenWallAPI.AddMessageHandler(fn, addon, priority)` with `fn(addon, sender, message, echo,
isOwnGuild)`. Three facts about it decide the design:

1. **It is a chat CHANNEL message, and CHANNEL sends are hardware-gated on Classic.** GreenWall
   sends every bridged segment with `SendChatMessage(segment, 'CHANNEL', nil, number)` on a hidden
   custom channel (`Channel.lua:366-370`; `CLAUDE.md:129` -- "GreenWall does not use
   SendAddonMessage"). The client's `ChatInfoDocumentation.lua` for the classic_era tree marks
   `SendChatMessage` `HasRestrictions = true`, and the API reference is specific: since 8.2.5 /
   1.13.3, _"'SAY', 'YELL' and 'CHANNEL' must be triggered by a hardware event"_, CHANNEL
   _"restricted for both outdoors and indoors"_. GreenWall's own 1.11.0 changelog is the same
   fact from the other side: it REMOVED its achievement / promotion / loot relays because _"events
   that are not triggered by hardware events cannot use the function."_ Every TOGBank GUILD leg
   fires from a timer or an event -- the login broadcast, the ten-minute cycle, the settings
   piggyback, a scan's mint, a request mutation from a dialog's callback chain -- so none of them
   can ride the bridge. A send attempted there is `ADDON_ACTION_BLOCKED`, not a slow path.
2. **255-byte segments, no chunking.** `tl_send` truncates the framed segment to
   `GW_MAX_MESSAGE_LENGTH = 255` (`Channel.lua:322`); `al_encode` base64s the payload
   (`:295`). Framing (`E#<guild_id>##TOGBankClassic:`) leaves roughly 170 payload bytes per
   call. An hlb2 for 38 bankers is ~900 bytes; a settings broadcast 1-2 KB; a price list 45 KB.
3. **The handler is not told the origin guild.** It gets `isOwnGuild` (a boolean), and the
   confederation is GreenWall's own configuration (Guild Info text), not LibGuildRoster's
   sister list -- two federations that may disagree.

So "use GreenWall for the broadcast" is not buildable as the broadcast is built. What remains
possible on the bridge is a **nudge from a hardware event** -- the user opening the Guild Bank
window is a click -- carrying one short line ("I hold banker numbers vN, ask me"). Section 4.6
keeps that as an optional later step; nothing else depends on it.

### 1.2 LibGuildRoster already solved the same problem, by whisper

The sister roster is fed by the library's OWN sync (MINOR 18, `LibGuildRoster-1.0.lua:2960-3667`):
a member of a listed sister guild is PULLED from by WHISPER (`PullSisterRoster`, prefix
`LibGRxpull`), the answer is the provider's home roster, and it is then relayed within the home
guild on GUILD (`BroadcastSisterRosters`). Presence for sister members is a sighting stamp --
any addon message from them (`sawOnline`) -- read back through `GetOnlineMembersScoped(key)`
inside `PRESENCE_TTL` (900 s). _Corrected 2026-09-15:_ "any addon message" was wrong --
`sawOnline` runs only from `OnSisterPullComm`, the library's OWN pull prefix -- so TOGBank stamps
the library itself (`UpdateOnlineMember` -> `MarkOnline`) when a sister member speaks TOGBank
to us. The first draft used DeltaSync and was cut back to two whispers
on the operator's question _"do we need deltasync and acecommqueue or is that overkill?"_.

That is the shape TOGBank should copy: **a broadcast is for one's own guild; everything that
crosses a guild boundary is a whisper to a member the roster says is there.** Addon whispers are
not hardware-gated and cross guilds today (the whole P2P layer already runs on them).

### 1.3 What the sister roster carries, and what it does not

`SetSisterRoster` stores `{ name, class, level, rank, guild }` per member (`:2772-2775`); the
served roster is `{ n, c, l }` and _"Rank and notes are deliberately excluded"_ (`:3512`). So a
sister client CANNOT tell who the home guild's bankers are from the roster: banker identity is
the `gbank` note (CLAUDE.md), and the note does not travel. Two ways round it:

- **The durable one (a contract, filed 2026-09-14):** LibGuildRoster serves the PUBLIC note with
  the roster and keeps it on the member (`note`). Public notes are visible to every member of
  that guild through the guild panel, exactly like the class and level it already serves, so the
  library's "leaks nothing" rule holds. Officer notes do not travel (they are not public); a
  federated guild tags its bankers in the public note, which ROSTER-004 already recommends.
- **The wire, meanwhile:** a home peer's `numbers-reply` (whispered on request) names every
  banker its account has numbered, and its `hash-list-reply` names the bankers it holds canons
  for. Both are already whispered to whoever asks. They make a usable banker list for a sister
  client until the note arrives -- but a name learned from the wire is a CLAIM by a peer, not the
  roster's word, so it is trusted only for READING (which bankers to fetch), never for authority.

### 1.4 TOGBank's GUILD legs today

From `Modules/Chat.lua`'s header table and the send sites: `togbank-hl` hlb2 (the login /
ten-minute version broadcast, `Events:SyncDeltaVersion`), the guild-settings piggyback and the
donation-points bucket on the same cycle, `share-request` / `wipe-command`, `numbers-request` when
broadcast, `togbank-rm` request mutations (ALERT), `togbank-ri` / `togbank-rd2` when the
coalescing turns several askers into one broadcast, and `togbank-pl` (the price list). Every one
of them is answered or followed by WHISPERS that already cross guilds: `togbank-hlr`, the P2P
handshake (`togbank-rr`), the DeltaSync data leg, `togbank-r` queries and their `-ri` / `-rd2`
answers to a single asker, `togbank-plq`. _Correction, 2026-09-15, from the two-guild fleet:_
one leg in that chain was NOT a whisper -- the `alt-request` a client sends after a
`hash-list-reply` (`Guild:BroadcastP2PRequest`) went to GUILD. It now goes by whisper to the
replying peer when that peer is a federated non-guildmate; the responder's `alt-request` branch
never reads the transport and ACKs by whisper either way.

### 1.5 Where "is this name one of us?" is decided in TOGBank

- Bankers: `Guild:RebuildBankerRoster` reads `GetGuildRosterInfo` notes (home guild only) into
  `Info.roster.alts`; `Guild:IsBank` reads the cache built from it; `SenderHasGbankNote` walks
  `GetGuildRosterInfo` again.
- Officers / GM: `SenderIsOfficer`, `SenderIsGM` -- home roster rank.
- Members: `memberRoster` (`RefreshOnlineCache`, home roster; the library path
  `_RefreshFromRosterLib`), `IsPlayerOnline`, `UpdateOnlineMember` (a sighting from any addon
  message -- already guild-agnostic).
- Data: `IsAltDataAllowed` (SEC-001) decides whether a received record for `alt` is stored.
- Storage: `Guild.Info` is `db.faction[<home guild name>]` -- one record per guild, on every
  client. A sister member's client has its OWN `Info`, for its own guild.

## 2. The decisions

**D1. One federation, one bank, stored per guild as today.** A federated guild's client keeps
storing under its own `Info`; what changes is what it holds there: the union of bankers across
every roster the library knows (home + sisters), the data for them, the requests against them,
and the settings. No SavedVariables re-key -- a guild that federates later, or stops, changes
nothing about where its record lives. (The alternative -- a federation-keyed record -- was
rejected: it moves every client's history the day the sister list changes.)

**D2. Membership = LibGuildRoster's `IsInAnyRoster(name)`.** `Guild:IsFederated(name)` is the ONE
predicate, and every gate that today means "in my guild" reads it: `IsAltDataAllowed`'s sender
and alt checks, the request-mutation validation, the settings and donation receivers, the
hash-list reply. A name in no roster is a stranger, exactly as now.

_Added 2026-09-15 (XGUILD-SWITCH-001, the operator: "shouldn't there be some officer
configuration to turn it on or make it work?"):_ the whole federation sits behind an OFFICER
SWITCH, `Info.settings.sisterBank`, off by default and guild-synced like the shop switch.
`Guild:SisterGuildKeys()` is the one gate -- the library's listed keys while the switch is on,
none otherwise -- read by the member union, the banker union, the cycle's pull and `GuildOf`.
With it off a sister member is a stranger to every gate above, so both guilds must tick it for
anything to cross: a guild that has not is neither served nor asked. Guild Roster's list still
says WHICH guilds are sisters; this says WHETHER this bank spans them.

**D3. Bankers = every `gbank` note in every federated roster.** `RebuildBankerRoster` unions the
home scan with each sister roster's members whose `note` carries the marker (feature-detected:
absent until the contract lands, and then only for guilds whose members carry the field).
`SenderHasGbankNote` reads the same note source. `memberRoster` gains the sister members with
`guildKey` set, so `IsPlayerOnline` / `IsBank` / `IsViewOnlyBank` answer for them.

**D4. Authority stays with the guild the actor is in.** An officer of ANY federated guild may
write the shared settings (SETTINGS-002's version resolves two writers); a banker publishes only
its own bank; donation ledgers are per writer as now. Nothing here needs a "home" guild to be
declared -- the federation is symmetric, which is what the sister list already is.

**D5. The broadcast legs stay on GUILD; the cross-guild copy is a whisper PULL from a peer.**
Copying LibGuildRoster (1.2): on its cycle, a client whose federation has another guild picks a
FEDERATION PEER per foreign guild -- the freshest-seen online member of it
(`GetOnlineMembersScoped`, presence from sightings) -- and whispers it `hash-list-request` on
`togbank-hl`. The peer's `hash-list-reply` (already whispered) carries every banker canon it
holds; the P2P session, the version query and the data leg follow as they do now, all whispers.
The `numbers-request` / `numbers-reply` pair (already whispered) fills the banker-number table.
A client with no roster for a guild yet (before the library's first pull) has no peer to ask
and waits; LibGuildRoster's own pull cadence (300 s) fills it.

**D6. What a federated peer is told when it asks.** Answering a `hash-list-request` from a name
that is federated but NOT in my home guild, the responder also whispers what it would have
piggybacked on its GUILD cycle: the guild-settings broadcast (when authorized), its own
donation-points bucket, and the price-list version it holds (as a `pl-version` line, so the asker
can `togbank-plq` the authority if behind). One extra whisper each, rate-limited per asker
(5 minutes) like the price-list answer. This is the whole "broadcast leg" for a sister member:
one ask, four answers, every ten minutes.

**D7. Requests cross by whisper, relayed once.** A mutation minted on a client (`togbank-rm`)
still goes GUILD; when the request's banker or requester is federated but not in the minter's
home guild the same bytes are ALSO whispered to that name when online, else to the federation
peer for its guild (`Guild:FederatedRelayTargets`). A client that receives a `togbank-rm` by
WHISPER from a federated non-guildmate applies it and re-broadcasts it ONCE on its own GUILD
with a `relayed = true` mark and the entry's `actor` kept (a relayed message is never relayed
again). Mutations made by the banker's side (filled, cancelled, deleted, reopened) reach a
sister-guild requester the same way. Everyone else on the far side catches up through the
existing index query (`togbank-r` requests-index, answered by `-ri` / `-rd2` by whisper), which
`PullFromFederation` now whispers to the federation peer 70 s after the hash-list ask (past the
GUILD index query's 60 s cooldown, so the one-at-a-time index state is not asked to hold two).

_Correction, 2026-09-15, of what this paragraph first said:_ the sanitizer does NOT check the
author -- `ApplyRequestMutation` checks the WIRE SENDER (`normSender`) against the request, which
on GUILD is the author by the transport. A relayed re-broadcast therefore needed its own rule,
`Guild:MutationAuthor`: on GUILD an entry marked `relayed` is checked against `entry.actor`,
accepted only when that actor is federated and NOT a guildmate (a guildmate can speak for itself
on GUILD, so a relayed entry in its name is a forgery); by WHISPER the sender is the author and
must be federated (a guildmate's whisper applies without a relay; a stranger's is refused; a
`relayed` entry by whisper is refused). The courier's word is trusted exactly as far as an
index reply's already is -- `requests-by-id` from any guildmate merges with no per-request
authorship check -- so the relay opens nothing the request sync did not already allow.

**D8. Labels (XGUILD-LABEL-001).** `Guild:GuildOf(banker)` = the key `IsInAnyRoster` answers;
`Guild:GuildTag(banker)` = "" for a home-guild banker, a space and `(<GuildName>)` otherwise, from the key's
`Faction-GuildName` spelling. Applied on the Bankers tab row, the Browse / Shop Banker column, the
banker tooltips, the request dialog's "from X" line and the Requests tab's Bank column. Own-guild
bankers untagged; the operator's call at build.

## 3. Wire changes, in full

| Change | Prefix | Distribution | New? |
| --- | --- | --- | --- |
| `hash-list-request` from a client to its federation peer, on the cycle | `togbank-hl` | WHISPER | no (existing type; new sender) |
| settings / donation-points / `pl-version` whispered to a federated asker | `togbank-hl` | WHISPER | `pl-version` is a new type |
| `togbank-rm` whispered to the banker / peer, `relayed` mark on the re-broadcast | `togbank-rm` | WHISPER + GUILD | one new field |
| `numbers-request` to the federation peer when the table names unknown numbers | `togbank-hl` | WHISPER | no |

No new prefix. No change to any positional format. A pre-XGUILD client that receives the
whispered `hash-list-request` answers it exactly as it answers a guildmate's -- it has always been
sender-agnostic -- so a sister member on this build can read a home guild still on a v1.6.0 build without the federation; it
cannot place a request that the far side re-broadcasts until the far side upgrades (the relay is
the receiver's job). Stated as the mixed-version cost.

## 4. The pieces, by file

### 4.1 `Modules/Guild.lua`

- `Guild:RosterLib()` already wraps LibGuildRoster; add `Guild:IsFederated(name)` (home member OR
  `lib:IsInAnyRoster(name)`), `Guild:GuildOf(name)`, `Guild:GuildTag(name)`, `Guild:IsHomeMember(name)`.
- `RebuildBankerRoster`: after the home scan, walk `lib:GetSisterGuildKeys()` then `lib:GetRoster(key)`
  and add every member whose `note` (feature-detected) carries `gbank`; keep `viewOnly` from the
  same note. Stubs and numbers as today.
- `_RefreshFromRosterLib` / `RefreshOnlineCache`: add sister members to `memberRoster` with
  `guildKey`, `isOnline` from `GetOnlineMembersScoped(key)` (a stamp inside the TTL), `isBank` /
  `viewOnly` / `note` from the note when present, `isOfficer` from `rank` only when the library
  says so (else false -- an unknown rank is not an officer).
- `SenderHasGbankNote`: the note source above. `SenderIsOfficer` / `SenderIsGM`: home roster, or
  the sister member's `isOfficer`.
- `IsAltDataAllowed` and every "guildmate" gate: `IsFederated`.

### 4.2 `Modules/Events.lua` -- the federation pull on the cycle

After the GUILD hlb2: for each sister key with a roster, `Guild:FederationPeer(key)` (freshest
online member not already answering), whisper `{ type = "hash-list-request", requester = me }`
on `togbank-hl` at NORMAL; note the ask so the reply is expected. Paced by the existing
ten-minute cycle; a manual `/togbank share` does the same.

### 4.3 `Modules/Chat.lua` / `Guild:SendHashList` -- answering a federated asker

`hash-list-request` from a non-guildmate that `IsFederated`: reply as now, then
`BroadcastSettings` / `Donations:Broadcast` / `PriceList:AnnounceTo` addressed by WHISPER to the
asker (each module gains a `target` parameter on its send; the payloads are unchanged). Receivers
of those types by WHISPER apply them under the same authorization as today.

### 4.4 `Modules/RequestLog.lua` -- the relay

`BroadcastRequestMutation`: after the GUILD send (`SendMutationPayload`), whisper the same bytes
to each of `FederatedRelayTargets(request)` -- the request comes from the mutation's snapshot,
the local record, or `relayFor` (a local-only hint `DeleteRequest` passes, since its record is
gone by then). `ReceiveRequestMutations(payload, sender, distribution)`: `MutationAuthor` decides
whose word each entry is (D7); an applied WHISPER from a federated non-guildmate is re-sent on
GUILD by `RelayMutation` with `relayed = true`. The SYNC-013 by-id fetch for an unknown request
goes to the courier, who holds it.

### 4.5 The label sites

`Modules/UI/Browse.lua`, `Modules/UI/Requests.lua`, `Modules/UI/Search.lua`,
`Modules/TooltipBankerInfo.lua`: `Guild:GuildTag(norm)` appended to the banker name at the five
sites in D8.

### 4.6 Optional, later: a GreenWall nudge from a hardware event

If GreenWall is loaded (`GreenWallAPI`), the Guild Bank window's open (a click) may send ONE
short line through `GreenWallAPI.SendMessage("TOGBankClassic", "hlq:<numbersVersion>")`; a
federated client hearing it treats it as a sighting of the sender and pulls from them at once
instead of on the next cycle. Saves up to ten minutes of latency on first contact; costs nothing
when GreenWall is absent. Not part of the build below.

## 5. Offline spec plan

- `Tests/env_fleet.lua` grows a SECOND guild key: two clients in different guilds, LibGuildRoster's
  sister rosters fed for both (`SetSisterRoster` with `note` on the bankers), presence stamped by
  sightings.
- `xguild_spec.lua`: membership and banker union (with and without the note field); the label at
  each site; the federation peer choice; the whispered `hash-list-request` on the cycle and the
  reply with settings / donations / `pl-version`; a full data sync sister to home banker by
  whispers only (no GUILD message crosses); a request minted by a sister member reaching the
  banker's guild once (the relay mark), the fill reaching the requester; a stranger refused at
  every gate; a pre-XGUILD far side (no relay) stated as the cost.

## 6. Build order

1. **Contract to GuildRoster** (filed 2026-09-14, this session): the public note on the served
   and stored sister roster. Everything in step 3 is feature-detected on it.
2. `Guild:IsFederated` / `GuildOf` / `GuildTag` + the five label sites (D8) + `memberRoster`
   union with `guildKey`. Buildable today; the tag shows the moment the library holds a roster.
3. Banker union from sister notes (D3) + the authority reads (D4) + `IsAltDataAllowed`.
4. The federation pull on the cycle (D5) and the whispered answers (D6).
5. The request relay (D7).
6. Fleet spec (section 5), docs, CHANGELOG, CurseForge, README.
7. (4.6) the GreenWall nudge, if wanted after the rest is seen in game.

**Where it stands (2026-09-14 23:30):** step 1 filed (thread `e2ec2c27e46a`); steps 2, 3 and 4
BUILT (`Guild:GuildOf` / `IsHomeMember` / `IsFederated` / `GuildNameOf` / `GuildTag`,
`_AddSisterMembers`, `_SisterBankers` into `RebuildBankerRoster`, `SenderHasGbankNote` across
rosters, the five label sites; `Guild:FederationPeer` / `PullFromFederation` /
`NoteFederationAnswer` / `AnswerFederatedAsker`, `BroadcastSettings` and `Donations:Broadcast`
with a whisper target, `PriceList:AnnounceTo` and the `pl-version` line; `Tests/xguild_spec.lua`,
suite 1793/0); `IsAltDataAllowed` passes a sister member through `IsInCurrentGuildRoster`
without a change of its own. One departure from 4.2: the pull runs at the END of
`Events:SyncDeltaVersion`, so a cycle the collision guard defers defers the pull with it.

**2026-09-15:** step 5 BUILT (`FederatedRelayTargets` / `SendMutationPayload` /
`MutationAuthor` / `RelayMutation`, the `distribution` argument on `ReceiveRequestMutations`,
the staggered requests-index whisper in `PullFromFederation`; six step-5 examples, suite
1799/0). Found on the way and fixed: `GuildOf` / `IsHomeMember` answered the home key for a
STUB entry, so any sender's first message made it "federated" -- the class of bypass `isStub`
exists to stop; both skip stubs now, and the refused-cases example pins it.

**2026-09-15, later:** step 6 BUILT -- `Tests/env_fleet.lua` spans two guilds (per-client
roster swap, GUILD delivered within the sender's guild, `F.federate`, `F.sighted`);
`Tests/xguildfleet_spec.lua` (3) drives the whole pull and the request round-trip across four
whole clients; the CurseForge bullet and the README section are written. The fleet found and
fixed the GUILD `alt-request` (1.4's correction; `BroadcastP2PRequest` whispers it to a
federated peer) and had `UpdateOnlineMember` stamp the library's presence for a sister member
who spoke to us. Suite 1802/0. Status: **BUILT (steps 2-6), NOT SEEN IN A CLIENT**, and gated
in the field on LIBREQ-GR-002 (the note on the sister roster) -- until that lands, a sister
guild's members see no bankers and nothing crosses. Step 7 (the GreenWall nudge) optional.

**2026-09-15 16:35 -- LIBREQ-GR-002 SHIPPED** by GuildRoster in its working tree (0.8.0 / MINOR 19;
`LIBRARY_CONTRACTS.md` 2.5 has the response) and adopted here the same hour: the fixtures
(`xguild_spec` `feedSister`, `env_fleet` `F.federate`) now feed the note through the library's own
`SetSisterRoster` entry, the shape `takeServedRoster` produces, and assert the library kept it.
No production change: `member.note` was already the read. The field gate is now a VERSION gate --
the client serving each guild's roster needs Guild Roster 0.8.0 -- and GuildRoster's caveat
stands: the same release fixes a provider serving a PARTIAL roster all session, so until every
provider runs it a received roster may be short and missing its `gbank` members.

**2026-09-16 -- seen in a client (bankers), and the inventory traced end to end.** The operator saw
the sister bankers listed and "No data" for their contents. `Tests/xguilde2e_spec.lua` stands up the
federation with nothing hand-fed -- rosters, notes and presence cross on Guild Roster's own pull and
its click-sent /who -- and found three defects: Guild Roster dropped every same-realm roster
(GR-SAMEREALM-001, fixed in its 0.8.2); `Guild:IsPlayerOnline` read a sister member's presence from
the rebuilt-only `memberRoster`, so the whisper to the peer `FederationPeer` had just picked was
refused as offline; and `FederationPeer` took any sighted member, TOGBank or not (XGUILD-PEER-001:
now version-aware, and a proven peer is asked at once). Owners now merge per entry across the
guilds (XGUILD-OWNERS-001). Both suite orders 1810/0. Status: **bankers seen in a client; contents
and owners proven offline only.**
