<!-- charset-ok: this file archives release notes VERBATIM from CHANGELOG.md, which has used em
     dashes and arrows since v0.10.x. Every section here arrives by being moved, unchanged, out of
     that file -- so the typography is inherited, not chosen, and the existing content already
     contains it. Rewriting the punctuation during the move would silently alter the text of
     releases that have already shipped, and would make an archived section stop matching a search
     for the wording it was published with. NEW prose written directly into this file should still
     use ASCII. -->
# TOGBankClassic Changelog - Archive

Older releases moved out of the main CHANGELOG.md to keep it under the GitHub release-body size limit (125,000 characters). See CHANGELOG.md for current releases.

Sections are moved here oldest-first as CHANGELOG.md approaches the limit, split at a version
boundary so each release stays whole. Newest archived release at the top.

## [v1.5.0] (2026-09-14) - extended engineering detail

<!-- Labelled v1.4.2 until 2026-09-13 (the operator: "the new UI is kinda a big deal, we should
     update v1.4.2 patch notes to v1.5.0"); every label in this section moved with it, verbatim
     operator quotes excepted. -->

The `### Internal` half of v1.5.0, moved here whole on 2026-09-12 so the live `CHANGELOG.md` stays
under GitHub's 125,000-character release-body limit. The New Features and Bug Fixes it belongs to
are still in `CHANGELOG.md`; nothing here was rewritten. **Later the same day** the OLDEST nine
Bug Fixes of v1.5.0 (OUTPUT-002 through PERF-023, the tail of that section) followed, byte for
byte, for the same reason -- the live file was 3,400 characters from the ceiling with the Mailbox
rebuild still to be written up. The newer Bug Fixes and every New Feature stay in `CHANGELOG.md`.

### Bug Fixes - the oldest of v1.5.0, moved 2026-09-12

<!-- The first five below (FULFIL-003 .. MULTIPC-001) followed on 2026-09-13, byte for byte, in the
     order they stood in CHANGELOG.md -- they sat directly above OUTPUT-002 there. -->

<!-- The ten below (WIRE-SKEW-001/002 .. WIRE-SKEW-005) followed later on 2026-09-13, byte for
     byte, in the order they stood in CHANGELOG.md -- the head of its Bug Fixes section. -->

<!-- The seven below (RAID-CONSULT-001 .. STATUSBAR-005) followed in the evening of 2026-09-13,
     byte for byte, in the order they stood in CHANGELOG.md -- the head of its Bug Fixes section,
     directly above WIRE-SKEW-001/002 there. The live file was at 107.6k with five entries
     written that session. -->

- **RAID-CONSULT-001: logging in inside a raid group marked the guild "consulted" on a broadcast
  nobody heard.** Found by LOG-HYGIENE-002 F6 (Peer Review db06c629), which asked for the
  HIDE-SYNC-001 hypotheses to be separated offline: the example for "the login broadcast is skipped
  by the raid guard" went red on first run. The guard in `Core:SendCommMessage` drops the hash
  broadcast and Chat drops every receive while `SyncPausedByRaid()`, so nobody hears us and nobody
  can answer -- but `Events:SyncDeltaVersion` still opened the P2P collect window, which closed 60 s
  later on "no offers" and called `MarkSelfConsulted`. A partial scan (bags at a vendor) then
  published on the strength of a broadcast that never left the client, which is the shared-account
  case MULTIPC-001's consult exists to prevent. Now the consult still BEGINS (a partial read is
  held) but the function returns before the send and opens no window; the hold settles on the
  fallback or on the first cycle that actually reaches the guild. The same example pins the other
  half of F6: exactly four production writers of `Bank.deferred`, all in `Bank.lua`, and none in
  the seven modules that touch the hold's neighbours. `Tests/multipc_spec.lua`. Location:
  `Modules/Events.lua`.

- **HIDDEN-TEXT-001: one table for every word the two windows say about a banker's own hidden
  rows.** Self-audit 5476e257 F2, agreed by Peer Review db06c629 (and misfiled for an afternoon
  under "the log's strings table"): the three tooltip lines and the two chat notices for a hidden /
  shown / soulbound-hidden row were spelled once in `UI/Inventory.lua` and again in
  `UI/Browse.lua`, so a wording change in one left the other describing the same row differently.
  `TOGBankClassic_UI.HIDDEN_TEXT` now holds all of them (plus the Browse status line from F3), and
  `UI:HiddenTooltipLines(hidden, why)` picks the tooltip entry; both windows read it. Two specs
  hold it: Browse's tooltip lines are the table's entries by identity, and no window file carries
  any of the seven phrases. The other half of that finding -- the own-hidden-rows MERGE spelled in
  both draw paths -- is filed for the next touch of either. Locations: `Modules/UI.lua`,
  `Modules/UI/Inventory.lua`, `Modules/UI/Browse.lua`.

- **LOG-HYGIENE-002 F3: a left click on your own hidden Browse row no longer opens a request
  dialog for it.** A hidden row is on the list only so its owner can right-click it back
  (HIDE-003); requesting your own hidden item from yourself was the one thing a left click could
  do there. The status line now says what the row is for. Pinned in the HIDE-003 example,
  `Tests/browse_spec.lua`. Location: `Modules/UI/Browse.lua`.

- **STALE-REQ-001: a request from a guildmate whose client cannot see the current bank is marked,
  and the "not found" fulfil tooltip says why.** The operator, on the banker's Requests tab: *"the
  issue is the request came in from someone on v1.3.2 and it's broken because of them. how can we
  handle this?"* A client that old is turned away from every bank delivery since v1.4.0
  (WIRE-SKEW-001..008), so it browses a months-old copy of the bank and requests from it -- here a
  Spiked Club variant the bank had not held since the night before -- and the request itself is
  well-formed, so nothing refused it and the fulfil icon could only say "not in your bags, bank or
  mail", which reads as a scan problem. The sync layer already knows what each peer runs
  (`Guild:PeerSpeaksDataLeg`, VersionCheck first, the broadcast field second); the Requests tab now
  reads it at draw time: an OPEN request whose requester is on a pre-data-leg version carries
  `v1.3.2` in amber beside the name, and the not-found tooltip adds *"<requester> is on v1.3.2, which
  cannot receive current bank contents -- they requested from an old copy of this bank, and the
  item may be long gone. Ask them to update TOG Bank."* Read, not stored: a requester who updates
  clears the mark on the next draw, and a peer nobody has heard from ("unknown") is not accused, as
  with the sync gate itself. Finished requests are never marked. One example in
  `Tests/browse_spec.lua` drives the gate per peer. Location: `Modules/UI/Requests.lua`.
  **Not changed, by the operator's word ("nope, i understand the issue"):** the row still shows
  the base item name for a suffixed item ("Spiked Club" for "Spiked Club of the Bear"); that is
  LINK-AUDIT-001's, recorded in `docs/LINK_AUDIT.md` section 3.4.
  **STALE-REQ-002, the same evening:** the operator reloaded and the mark did not appear -- "in VC
  he is v1.3.2 so that's how i know. the ? does not". Both live sources are SESSION memory:
  VersionCheck's table empties on every reload and refills only as each guildmate's client
  answers, and the broadcast field only as their hlb2 lands -- so a guildmate who is OFFLINE after
  a reload has no version at all, and the requester of an order is usually offline when the banker
  looks at it. The guild record now remembers the last addon version each guildmate was seen on
  (`Info.peerAddonVersions[norm] = { version, at }`, newer winning), fed by VersionCheck's
  `OnPeerVersion` callback (`Guild:HookVersionCheck`, registered at `Guild:Init`) and by the
  broadcast; `Guild:LastSeenAddonVersion(name)` answers live first, memory second, and the
  Requests tab reads the memory only when the live gate says "unknown". **The sync gate does not
  read it**: a remembered version is what a client ran, not what it runs, and refusing on it is the
  starvation WIRE-SKEW-004 removed. `Tests/wireskew_spec.lua` drives the real VersionCheck
  library through the callback and a simulated reload; the browse_spec example gains an offline
  requester marked from memory and one remembered on a current version who is not. Locations:
  `Modules/Guild.lua`, `Modules/Database.lua` (the field's default and backfill),
  `Modules/UI/Requests.lua`.

- **LOG-WIPE-001: `/togbank wipe` did not wipe the bank log -- it came back from a session cache.**
  Peer Review db06c629 F4. LOG-PERSIST-001's first cut cached the store's `g.log` table in
  `Log.buffers` for the session, and nothing in production ever cleared that cache; after a wipe
  replaced the guild table, the next log call found `log ~= g.log`, copied EVERY cached entry into
  the fresh table, and the wiped log was whole again. `buffer()` now reads `g.log` from the store on
  every call (a hash lookup) and never caches it; `Log.buffers` holds ONLY entries recorded before
  `Store:Init` and moves them once. A wipe takes effect by construction. Pinned in
  `Tests/logapi_spec.lua`: append, wipe the guild table, append again -> only the second entry.
  Location: `Modules/Log.lua`.

- **MAILUI-003: taking the last thing out of a mail moved the Mailbox window's expansion onto the
  wrong mail.** Peer Review ccd04f5e item 1. The client deletes a mail once its last attachment (or
  its money, when that is all it carried) is taken, and renumbers every mail above it down by one;
  the expansion set was keyed by mail index and did not follow, so the expanded state landed on
  whichever mail inherited the number. `Mailbox:TakeEmptiesMail(row)` reads the inbox as it stands
  BEFORE the take (item count plus money) and `Mailbox:ShiftExpanded(taken)` shifts the set down by
  the one rule the inbox uses; a take that leaves the mail standing changes nothing. Pinned in
  `Tests/mailbox_spec.lua`. Location: `Modules/UI/Mailbox.lua`.

- **STATUSBAR-005: the green "confirmed" status-bar line was blanked on a narrow window even when
  there was room for it.** Peer Review d0170ec1 item 1 on STATUSBAR-003: *"the green line yields to
  the SIDES when they need the room, but never to NOTHING."* A centre that did not fit centred on
  the whole bar beside the left text was cleared outright, so a synced banker on a narrow window saw
  an empty bar -- the failure the line was built against, from the other side. `RefreshSides` now
  bounds the centre's host frame to the room the sides leave (left text + gap .. right text + gap);
  the FontString centres and truncates inside that, taking the short form when the full one does not
  fit, and is blanked only when the room is under `CENTER_MIN_ROOM` (60px, about one word plus the
  ellipsis). The urgent yield still hands it the whole bar. **Visible change:** with left text on the
  bar, the centre line is centred in the REMAINING room, not on the bar's centre -- say if it should
  stay put. Pinned in `Tests/statusbaryield_spec.lua`. Location: `Modules/UI/StatusBar.lua`.

- **WIRE-SKEW-001/002: a guild still on v1.4.1 starved the two clients that could actually sync,
  and the guard written to stop it never fired once.** v1.5.0 replaced the `togbank-state` summary
  with the DeltaSync QUERY and kept no wire back-compat, so a v1.4.1 peer accepted by us answers
  with a summary this tree no longer reads -- it holds one of three send slots for the full
  30-second state-wait and requeues -- and one that accepts us never answers our query, so we sit
  out the 180-second watchdog. Read off the operator's own log: 22 v1.4.1 requesters queued for one
  banker, three slots cycling uselessly, and the one capable client starved at queue position 20.
  Every `hlb2` broadcast has carried the sender's addon version since v1.4.1 and nothing read it.
  Now `Guild:PeerSpeaksDataLeg` does: an older peer is told busy immediately (no slot, no queue
  position), is dropped from our candidate holders, and its pull-path ACK is ignored; unknown
  versions and dev builds are treated as capable so the operator's own working copies are never
  refused. **WIRE-SKEW-002 is why the first cut refused nobody.** `Guild.EncodeVersion` anchored its
  match at the start of the string, and a RELEASED client's `Version` is the packager's substitution
  of `@project-version@` -- the WHOLE git tag, `TOGBankClassic-v1.4.1`. Every released peer therefore
  encoded as `0`, read as a dev build, and passed the gate; the log after the fix shipped was
  unchanged. The match is unanchored: the first `d.d.d` anywhere in the string is the version. The
  spec had driven `"1.4.1"` -- the string I imagined rather than the one the field carries -- and
  passed for the wrong reason; it now drives the tag form. `Tests/wireskew_spec.lua`,
  `Tests/guild_spec.lua`. Locations: `Modules/Guild.lua`, `Modules/Chat.lua`,
  `Modules/P2PSession.lua`, `Modules/Constants.lua`.

- **CANON-TIME-001: a client could advertise a version of someone else's bank that nobody ever
  published, dated at its own login -- and the author could never out-publish it.** The load-time
  migration in `Database:Load` read `alt.inventoryUpdatedAt = alt.version or GetServerTime()`. The
  comment block directly above that line argues at length why this migration must never invent an
  identity for data the client never read (HASH-CANON-002/003 deleted the invented *hash* there) --
  and it left an invented *time* one field below, which is sufficient on its own:
  `Guild:ReencodeHeldCanons` runs immediately after the load and builds a canon as
  `<inventoryUpdatedAt><hash>` from any still-numeric v1.4.0 canon. So a record for another banker,
  carried in a pre-v1.4.0 file with no version of its own, was re-encoded as a canon stamped with
  **this client's login time** and then broadcast. Every peer -- the author included -- then read the
  author as behind a version that never existed, and rescanning could not clear it, because the
  phantom time moves forward with whoever logs in next. The backfill now takes `alt.version` only;
  with no publish time the canon is CLEARED and the record re-requested, which is the path the code
  already documents ("a version nobody can place in time"). **Nothing caught it because
  `hashcache_spec`'s clearing example stubs `Database.Load` wholesale** -- it proved the property
  against a loader with the migration removed, the one thing that defeats it. New
  `Tests/canontime_spec.lua` (5 examples) drives the real loader; proven red. Ruled out while
  looking, so nobody re-checks them: `Sync.lua`'s receive-time fallback cannot fabricate an
  advertised time (peers only ever see the canon string, carried verbatim), and
  `ReencodeHeldCanons` itself invents nothing. Location: `Modules/Database.lua`.

- **MULTIPC-003: a banker that had re-read everything sat "Behind" for ever, because only a SCAN
  could publish.** Found by reading the operator's SavedVariables: a banker holding a canon
  published two days earlier with bags, vault and mail all `lastScan`ed minutes before -- *"my bags
  hash should be the latest, but it's saying it's behind"*. `Bank:Scan` mints on "contents changed
  **or** we already know we are behind", and on the ordinary login order the first bag event scans
  while the guild's broadcasts are still in flight: nobody has advertised yet, so if the contents
  also did not change the scan takes the "version unchanged" branch and defers nothing. The news
  then arrives with nothing left to act on it -- `PublishIfDeferred` is a permanent no-op, and
  nothing rescans while the bags sit still. Learning it is behind is now itself a publish trigger
  (`Bank:NoteNewerSelfVersion`), releasing a publish against what this PC last published. Every
  MULTIPC-001/002 rule is untouched: a source not re-read since the newer publish still refuses to
  mint, a known holder is still asked for the diff base first, and the 180-second fallback still
  forces it out; an already-deferred publish is left alone, because its before-images are what the
  bank log diffs against. `Tests/multipc_spec.lua` (4 examples), proven red. Location:
  `Modules/Bank.lua`.

- **RAID-VISIBILITY-001: sync stops in a raid group, and for an afternoon nothing said so.** The
  addon suppresses every send and ignores every incoming message while `IsInRaid()` -- the addon
  chat channel is throttled and raid addons need it -- and logged that only under a debug category.
  The collect and dispatch timers kept printing "no offers" as if the guild were quiet, so a
  deliberate suppression read as a sync bug: *"i was in a raid, do you stop syncs while in a raid?"*
  -- *"i wasn't aware"*. Now one plain-chat line the first time a send is suppressed per raid stint
  (reset by the first send after leaving), and a grey **Sync paused: in a raid group** in every
  window's status bar for as long as it lasts, taking the centre over both the transport text and
  the banker's own propagation line -- an update cannot propagate from here until the raid is left,
  and that is the fact the banker needs. `Tests/raidvisibility_spec.lua`. Locations: `Core.lua`,
  `Modules/UI/StatusBar.lua`, `README.txt`.

- **DOC-007: the setup instructions named a setting that does not exist, and implied it gated
  sharing.** `README.txt` (twice), the CurseForge description and the in-game
  `/togbank help` setup text all said to enable **"Report bank contents"**. There is no such
  option. The tick beside it is **"Report contributions"** (`Options.lua`, `desc = "Enables
  contribution reports"`), and tracing its only two call sites -- `Mail.lua`'s "Received %s gold
  from %s" and "Received %s (%d) from %s" -- it does nothing but silence those two chat lines when
  opening donation mail. The setting that actually governs whether a character's bank is scanned
  and shared is **"Enable for &lt;character&gt;"** (`db.char.bank.enabled`), which is on by
  default. So a banker following the documented setup was looking for a control that is not there,
  and could reasonably conclude that leaving the one they *did* find switched off was why their
  bank was not reaching the guild. All four texts now name the real setting, say it is on by
  default, and say plainly that "Report contributions" is unrelated to sharing. The troubleshooting
  entry also stops saying "Scan bank on open" (the scan runs on CLOSE -- the same error v1.4.0
  corrected elsewhere and missed here) and gains the shared-account case. Locations: `README.txt`,
  `docs/Curseforge_Description.html`, `Modules/Chat.lua`.

- **CLAIM-TRACE-001: `/togbank dev trace` now names WHO is holding a banker's tab red.** A red tab
  means "somebody has a newer copy than yours", and nothing anywhere recorded which somebody --
  `newestAdvertisedAt` kept the time and discarded the sender. So when a banker reads as behind a
  version its own author never published (CANON-TIME-001 above is one way that happens, and will
  not be the last), the single question that identifies the culprit could not be answered from a
  live client at all: it took a session of reading SavedVariables off disk, and even that produced
  a mechanism without naming the peer. `Guild.newestAdvertisedBy[norm]` is now written on the same
  raise that moves the tab -- session-only, one small table -- and the trace prints
  `claimed by: <peer> canon=<publish time> (N ago)`, plus, for our own character, `newer copy held
  by:` off `Bank.newerSelf` (the peers a diff-base fetch would go to; "none recorded" is the state
  the fallback publishes out of). All four callers pass their sender. **Attribution is a
  diagnostic, never a gate:** a caller that cannot say who still raises the time, unattributed, and
  the peer recorded is the one whose claim *raised* it, so a later, older claim cannot overwrite
  it. Both pinned in `Tests/trace_spec.lua`. Locations: `Modules/Guild.lua`, `Modules/Chat.lua`,
  `Modules/P2PSession.lua`.

- **WIRE-SKEW-008: a claim from a peer that cannot serve us no longer moves anything -- the "Behind"
  that survived WIRE-SKEW-006, and the publish stall behind it.** The operator: *"elementals data
  still isn't syncing with galdof"*, then screenshots from both clients: Elementals ONLINE, its
  author's own client holding canon `1789076374...` (2d old, `inventoryContentHash` present, so the
  author's own scan), Galdof holding the identical one, and BOTH reading **Behind** -- with the
  author's log saying `Galdof-OldBlanchy holds 17890763741518426897` and, on the next line, `a peer
  holds a LATER version of this character than this PC`. Nothing newer existed. Five v1.4.1 relays
  had advertised Elementals with a LATER publish time than the author's: the old release still has
  the bug v1.5.0 fixed as CANON-TIME-001 (the clock stamped onto timestamp-less saved data on load),
  and every claim path -- `NoteAdvertisedPublishTime`, `NoteAdvertisedHashes`, `NoteSelfHolder` --
  took the maximum with no regard for who was claiming. One fabricated time did three things: set
  Galdof's tab red, set the author's OWN tab red (MULTIPC-001 reads the same table for our own
  name), and through MULTIPC-002 recorded a v1.4.1 relay as the holder of a phantom diff base, which
  the author's publish gate then tried to fetch before it would publish a rescan -- from a peer it
  cannot fetch from. That is why rescans on Elementals were not landing. It was the same on every
  other Behind row in the screenshot; WIRE-SKEW-006 cleared the *offered* red on those and could
  not touch this one, because it is a different flag. **One rule now, `Guild:ClaimantCanServe`,
  applied by all three writers:** a peer that cannot complete the data leg with us cannot move the
  tab, the advertised-hash cache, or the self-holder record. Red means "on its way", and nothing is
  on its way from a release we do not speak. The broadcast handler drops such a sender whole after
  reading its version -- its claims are refused anyway, and offering it our copy only produced a
  sync-request we then refused, read off the log as twenty refusals a minute. The misleading log
  line now names who raised the time and to what. **KNOWN COST, stated rather than hidden:** a bank
  genuinely rescanned on a v1.4.1 client reads Current on v1.5.0 clients until that client upgrades,
  at which point its broadcast turns the tab red and the fetch turns it yellow. Four examples in
  `Tests/wireskew_spec.lua`, each with a v1.5.0 control (one of which caught its own fixture
  passing for the wrong reason -- the control peer was the client itself). Confirmed live before
  this entry was written: Galdof went from 12 current to 35 on the next reload. **Self-audit, the
  same evening:** the hash-list REPLY handler refused the claims through the gated Note* calls and
  then, in its second pass, turned the same claims into one `BroadcastP2PRequest` per alt -- a
  guild broadcast each, on an old release's publish times, which is the fast-fill burst behind the
  pull-path ACK storm. A reply from a peer that cannot serve us is now skipped whole, and
  `RequestHashListFromBanker` no longer picks such a banker to ask (a reply it would then ignore);
  with no capable banker online the guild is asked instead. Two more examples, each with a capable
  control. Locations: `Modules/Guild.lua`, `Modules/Chat.lua`, `Modules/P2PSession.lua`.

- **WIRE-SKEW-007: a peer that BEHAVES like the old wire is treated as the old wire, before anyone
  names its version.** The banker's log after a `/reload`: Garlii, Freezeplug and Venshea were
  ACCEPTED -- nobody had told this client their version yet, and unknown is capable by the
  operator's rule -- each held a send slot for the whole 30-second state-wait, released
  `no_state_summary`, and were refused as v1.4.1 only minutes later once VersionCheck caught up.
  Three slots times thirty seconds, every login, before anyone capable could be served. Two things
  say "old wire" without a claim. The `togbank-state` summary a v1.4.1 requester whispers the
  moment we accept (a v1.5.0 one asks on the host's QUERY channel and never sends it) is registered
  again **receive-only, as a tripwire** -- the body is never deserialized, the sender is the whole
  message -- and hearing it marks the peer and releases every accept held for it at once instead of
  at the end of the wait. And thirty seconds of silence after an accept marks the peer the same way.
  `PeerSpeaksDataLeg` refuses a marked peer whose version is still unknown; **a real version claim
  from either source outranks the mark**, because the mark says what the peer did and the claim
  says what it runs -- so a capable peer whose one query whisper was lost is refused only until
  VersionCheck or its own broadcast names it, both of which land in the same login burst. Four
  examples, through the real receive. Locations: `Modules/Chat.lua`, `Modules/Constants.lua`,
  `Modules/Guild.lua`, `Modules/P2PSession.lua`.

- **WIRE-SKEW-006: every tab red, for banks already held current -- the "not syncing" the operator's
  two v1.5.0 clients showed.** Their words: *"why isn't it when you block 4.1 traffic, my 2x 4.2
  clients aren't syncing?"* Read off both accounts' SavedVariables rather than a log (the debug log
  was off on both): each held the IDENTICAL canon for Cardsngames -- there was nothing to fetch --
  so the symptom was the colour, not the data. A bare offer turns a tab red (TABCOLOUR-003) and the
  version query is what clears it when nobody really holds newer. WIRE-SKEW-004 drops old-release
  holders BEFORE that query opens, so an alt offered only by v1.4.1 peers reached `DispatchList` with
  an empty candidate list, was skipped there, and nothing ever cleared the red -- credited, in
  `/togbank dev trace`, to a peer that cannot serve us. Forty old clients offer every bank on every
  cycle (their compare is the revision-1 hash, which always differs), so this was every tab, for the
  whole session, and it was my WIRE-SKEW-004 that closed the only exit. Two changes, one file. An
  offer from a peer that cannot complete the data leg is now refused at `OnOffer`'s door -- not
  recorded as a holder, not folded into a live session, no red -- because its "I hold newer" is a
  revision-1 compare that carries no information and names nothing we could fetch. And when a
  peer's version is learned only AFTER its offer got in (VersionCheck and its broadcast both land in
  the same login burst), the `DispatchOrQuery` filter emptying an alt's list now clears the red that
  offer raised, since nobody we can hear from has claimed newer. A capable peer's offer is untouched
  on both paths. Three examples in `Tests/wireskew_spec.lua`, each with a control from a v1.5.0 peer
  so it cannot pass vacuously, all three proven red against the reverted code -- the first failure
  message is the operator's symptom verbatim. NOT CHANGED, stated plainly: a v1.4.1 banker's own
  hlb2 broadcast still names its canon, so a bank that really is newer on an old client still reads
  "behind" -- honestly, because it is, and no v1.5.0 client can fetch it until that banker upgrades.
  Location: `Modules/P2PSession.lua`.

- **WIRE-SKEW-005: the send QUEUE was a second door into an accept, and it had no version gate on
  it.** Found in the operator's live log *after* WIRE-SKEW-004 was already running: Cinia, Zurayli,
  Groucho and Bilgoth each appear REFUSED on one line and ACCEPTED on another, and every accept
  follows a `ReleaseSendSlot`. `HandleSyncRequest` refuses an old-release requester before it can
  take a slot, but a requester QUEUED while we were at capacity comes back through `ServeQueue`
  instead, which only ever re-checked whether the content still existed. So the old peer sat in the
  queue, a slot freed, it was accepted, and it burned the entire 30-second state-wait before
  releasing with `no_state_summary` -- three slots' worth, cycling. The queue can also hold entries
  from before we learned a peer's version, so re-checking at drain time is the only place that
  catches them. Two examples in `Tests/wireskew_spec.lua`, proven red: one that the drain refuses an
  old peer (no accept, no slot held, and a `sync-busy` carrying `addon_version` so its session moves
  on rather than hanging), and one that it still serves a CAPABLE peer out of the queue -- the gate
  must not become the starvation it was written to prevent. Location: `Modules/P2PSession.lua`.

<!-- The eighteen below (HELP-PULSE-002 .. CHAIN-004 / P2P-038) followed on the evening of
     2026-09-13, byte for byte, in the order they stood in CHANGELOG.md -- the block between
     WIRE-SKEW-005 above and FULFIL-003 below, which is where they sat there. -->

- **HELP-PULSE-002: the help icon's breath is per tab.** The operator: *"each i on each tab has
  different info. the 'breath' effect has to be on, for each one, until it's moused over. right now
  mousing over one, fills the stop breath effect for them all."* BROWSE-003 stored one boolean for
  the window; `helpSeen.browse` is now a table keyed by tab, `HelpSeen`/`MarkHelpSeen` take the tab
  (defaulting to the current one), and `SyncHelpPulse` plays or stops the breath on every tab change
  -- through `RememberTab`, the one place the current tab is set -- and when the icon is built. An
  account carrying the first cut's `true` reads as the Browse tab seen and the other two not (their
  text was never in front of them), and is migrated to the table on its next mark. The existing
  breath example now walks all three tabs; one more pins the migration. Location:
  `Modules/UI/Browse.lua`.

- **CANCEL-GLOW-002: every cancelled request breathes, not only the ones with a reason.** The
  operator: *"can we add the 'breath' effect to the cancelled items? i'd like to apply what we did
  yesterday to the old cancelled items to make them more noticible to the new tab too."*
  CANCEL-REASON-001 gated the glow on `cancelled AND has a reason`, so a request cancelled before
  reasons existed -- most of the archive -- stayed unmarked. The condition is now the status alone;
  the reason, when there is one, stays in the tooltip. The help line and the Appearance switch's
  wording say so. Pinned at the call site in `Tests/browse_spec.lua`. Locations:
  `Modules/UI/Requests.lua`, `Modules/Options.lua`.

- **SCROLLBAR-002: the Requests list's scrollbar sat over the last button of the Actions column.**
  The operator, with a screenshot: *"the reopen order button is overlapping the scroll bar."*
  AceGUI's ScrollFrame pulls the scroll frame's right edge in by 20px while the bar shows and hangs
  its bar OUTSIDE that edge; the thin-bar restyle had re-anchored ours by its RIGHT edge at the
  frame's right edge -- the 8px bar inside the rows -- so whatever was rightmost sat under it, and in
  the Actions column that is the reopen button. Anchored by its left edge at +6 instead, in the
  middle of the gap AceGUI already clears. One example reads the anchor and checks the bar's whole
  width lies inside that gap. **Self-audit, sideways:** Inventory and Search carried the identical
  restyle with the identical anchor, so their rightmost icon column sat under the bar too. One
  helper, `UI:ApplyThinScrollbar`, replaces the three copies. Locations: `Modules/UI.lua`,
  `Modules/UI/Requests.lua`, `Modules/UI/Inventory.lua`, `Modules/UI/Search.lua`.
  **The operator's look, with a screenshot:** *"it could use a few more px"* -- the thumb still read
  as touching the reopen button. The bar hangs at +10 now (ending at 18, inside the 20px gap); the
  example's bound is unchanged and still holds.

- **CANCEL-GLOW-003: the glow was invisible on the Guild Bank window's Requests tab.** The operator,
  with a screenshot of a cancelled row with no halo: *"cancel-glow-002 not working"*. The glow copies
  lived on a frame one level BELOW the date cell -- that put them under the glyphs, and also under
  whatever else sat at that level, which differs between the standalone window and the tab body. Now
  the glow frame is at the cell's OWN level, its copies on ARTWORK, and the cell's FontString (AceGUI
  draws a Label's text on BACKGROUND) is raised to OVERLAY while it glows and put back when the glow
  goes out or the Label is released -- within one frame level the client draws by layer across
  frames, so the copies are under the glyphs and over nothing else wherever the cell is hosted.
  `Tests/searchbox_spec.lua` pins the level, the raised layer and its restore. Not seen in game:
  the layering is the one thing that differs between the window where it was verified and the tab
  where it was not, but that is a reading, not an observation. Location: `Modules/UI/Requests.lua`.

- **HIDE-003: on the Guild Bank window a right-click hide made the item vanish with no way back.**
  The operator: *"by default right click on an item it 'just went away'. i don't see it and i can't
  unselect it. it was supposed to get the circle with a line through it."* `Browse:BuildRows` read
  `Guild:GetAltItems`, which by design never carries a banker's hidden rows; only the Inventory
  window's own tab appended `Store:GetAltHiddenView`. The Browse rows now do the same for the
  banker's own bank and nobody else's: the hidden row stays in the list greyed (desaturated icon --
  a new `_iconDesaturated` row flag the RowList honours -- and grey name behind the same
  ReadyCheck-NotReady badge the Inventory window uses), its hover says *right-click to show it*
  (or names the soulbound checkbox, HIDE-002), a visible own row's hover says *right-click to hide*,
  and the right-click prints the same confirmation line the Inventory window does. The help text's
  hide paragraph, which sent the banker back to the old window to unhide, now says right-click
  again. One example in `Tests/browse_spec.lua` against the real store: the hidden row present and
  marked for the banker, absent for a viewer, the hover lines, the right-click calling `SetHidden`
  false. Locations: `Modules/UI/Browse.lua`, `Modules/UI/RowList.lua`.

- **HELP-PULSE-003: `/togbank helpreset` forgets every hovered help icon.** The operator, testing
  the per-tab breath: *"you would need to 'unmark' mine so i can test this again."* The breath is a
  one-time attention-getter remembered per account, so there was no way to see it a second time.
  The command clears `helpSeen` and re-syncs the open window's icon at once. Location:
  `Modules/Chat.lua`.

- **HELP-TEXT-001: the main window's "How It Works" text lives on the Guild Bank window's Browse
  tab.** The operator: *"it's imparitive this tooltip lives on somewhere in the new main UI, maybe
  the bankers tab? not sure, where do you think it makes sense to put it?"* The Browse tab is the
  one that replaces the tab-by-tab view the old text described and it is the first tab people land
  on, so its `?` now opens with the same four things -- what the window is, how to donate (mail the
  bank character; the Bankers tab lists them), how to request, how a banker hides -- said for this
  window. The Bankers and Log tabs keep their own text. Location: `Modules/UI/Browse.lua`.

- **BROWSE-008: the Guild Bank window repaints on every signal the Inventory window gets, the Online
  column included.** The operator, on the Bankers tab: *"is there a refresh on the new banker tab
  when something updates?"* For data, yes and it already was: every claim raising a tab, every
  delivery, every cleared offer goes through `UI_Inventory:RefreshSoon`, which fans out to the Guild
  Bank window on the same half-second debounce. Two sites bypassed that with a direct `DrawContent`
  -- the hash-broadcast batch and the collect-window dispatch, the two "a tab is about to go red"
  moments -- and repainted the old window only; both now go through the fan-out. And for the
  **Online** column, no: nothing anywhere repainted on a roster change, so "yes" stayed on a banker
  who had logged off until some data signal happened along. `RefreshOnlineCache` (both the
  LibGuildRoster path and the legacy scan) and `UpdateOnlineMember` now compare the set of online
  BANKERS before and after and repaint only when it changed -- bankers only, because a repaint per
  roster event rebuilds the whole tab strip every ten seconds in a busy guild for nothing, and
  `UpdateOnlineMember` runs for every inbound message, so it takes the roster walk only when the
  member is a banker. Five examples in `Tests/browserefresh_spec.lua` against the real Guild and
  roster library, the online ones proven red. Locations: `Modules/Guild.lua`, `Modules/Chat.lua`,
  `Modules/P2PSession.lua`.

- **BROWSE-007: the Guild Bank window could be narrower than its Requests tab, and the column
  headers ran past the border.** The operator, with a screenshot of `Sent` and `Actions` floating
  outside the frame: *"the window can shrink smaller than the columns, and the column headers float
  outside the window."* The Requests body's column table cannot lay out below the sum of its column
  minimums -- 972 today -- and that number was the standalone Requests window's resize floor; the
  Guild Bank window hosting the same body had its own floor of 760 and a default of 900, so it could
  be dragged, or simply opened fresh, narrower than the tab it was showing. And a floor alone is not
  enough: resize bounds only stop the sizer, while a status table saved narrower than the floor
  (BROWSE-006 made the size persist) is applied by AceGUI's `ApplyStatus` as-is. Requests now
  publishes `MinWidth()`, the window's floor is the larger of its own and that -- read at draw time,
  since Requests is a later file in the TOC -- the default is no narrower than the floor, and a saved
  width or height below the floor is clamped on open (position untouched; a larger saved size is
  left alone). Three examples in `Tests/browsepersist_spec.lua` against the REAL Requests body, so
  the number under test is the one the columns actually add up to. Locations:
  `Modules/UI/Browse.lua`, `Modules/UI/Requests.lua`.

- **BROWSE-006: the Guild Bank window forgot its position, size and tab every time it was closed.**
  The operator: *"save the position/size/last tab of the new UI to SV so it persists through UI
  open/close and game login/logout."* It was the only window that did not -- Inventory, Search and
  Requests all attach a status table to `db.char.framePositions`, and this one carried a hard
  `SetWidth(900)`/`SetHeight(540)` pair instead, so it reopened centred at the default size every
  time. It now attaches its own status table, which is all that is needed: AceGUI writes
  `top`/`left`/`width`/`height` into it on every drag and resize and reads them back through
  `ApplyStatus`. The hard size pair is gone rather than merely moved -- `SetStatusTable` applies the
  table, so a `SetWidth` after it would have put the window back to the default on every open. The
  last tab is ours to keep and lives beside the position, per character for the same reason
  (it is part of how that alt has the window arranged); it is **validated against the window's own
  tab list** on the way out, because the saved value outlives the build that wrote it and a name
  that no longer exists would be handed to `SelectTab`, match nothing, and open the window on a
  blank body. Both assignment sites in `ShowTab` record it, the early return included -- that is the
  path taken when Requests is already on screen and the tab is re-selected, which is exactly what
  `Open()` does, so persisting only in the other branch would have failed to remember the Requests
  tab in the one case the player is most likely to be in at logout. The tab list is declared once
  and shared by `SetTabs` and the validator, so a tab cannot exist in one and not the other.
  Thirteen examples in `Tests/browsepersist_spec.lua`, including the reopen-after-logout case built
  from scratch against an already-resized table; proven red. Locations: `Modules/UI/Browse.lua`,
  `Modules/Options.lua`.

- **RECENTER-001: a window dragged off the edge of the screen could not be got back.** The
  operator, 2026-09-12: *"make a button in settings>appearance to recenter the addon in the middle
  of the screen. folks have it appearing off screen and they can't drag it."* The constraint is the
  whole feature -- the player cannot reach the title bar, so any fix that asks them to drag is no
  fix, and the only thing that existed was `/togbank wipeframes`: an expert-only command that also
  required a reload, because it replaced the saved table while every live widget kept a reference to
  the old one and so nothing on screen moved. **Settings > Appearance > Window Position** now
  carries a "Recenter All Windows" button that takes effect immediately, chosen because the options
  panel is the one TOGBank surface still reachable when the window itself is not. It works by
  deleting `top`/`left` from the status table and calling AceGUI's own `ApplyStatus`, whose
  else-branch is literally `frame:SetPoint("CENTER")` (`AceGUIContainer-Frame.lua:152-157`) --
  rather than anchoring the frame here, which would leave the stored coordinates behind to be
  restored on the next reload and would duplicate a rule the library already owns. Sizes are kept
  deliberately: the window is lost, not mis-sized. Both the saved table and the widget's
  `localstatus` are cleared, because a window built before its saved table was attached reads the
  latter, and clearing only one would recentre it until the next drag wrote the old coordinates
  straight back. `/togbank wipeframes` now calls the same function so an open window moves at once,
  and its message no longer implies the size reset took effect without a reload. Seven examples in
  `Tests/recenter_spec.lua`. Locations: `Modules/UI.lua`, `Modules/Options.lua`, `Modules/Chat.lua`.

- **WIRE-SKEW-004: a guild mid-upgrade spent its whole cycle timing out on peers it could never
  fetch from, and that is where the hours went.** The operator, on a guild where 40 of 42 clients
  were still on v1.4.1: *"it's taking HOURS to sync 1 banker ... it MAY be because of all the v1.4.1
  users, or it MAY be a problem with the work you did. I can't tell."* Both, and this half is ours.
  The capability check read `peerAddonVersions`, which only fills in when that peer's own `hlb2`
  broadcast reaches us -- **after** we have already had to decide whether to ask it for data -- so
  every peer not yet heard from read as "unknown", and unknown was capable. It was asked which
  version it held (a whisper out and a reply back, five per alt per round), counted as a holder, and
  picked as a fetch target: a full dispatch timeout, then the next candidate, then `All candidates
  busy ... retry 1/5 in 20s`, while forty old peers kept re-offering and restarting the cycle. Read
  off the operator's log verbatim: `to Kajind-Azuresong`, then `Dispatch timeout for
  Elementals-Azuresong/Kajind-Azuresong`, with Kajind in the refusal lists moments later once its
  broadcast landed. **The version now comes from VersionCheck-1.0 as well as the broadcast** -- the
  operator's own call: *"there data is there, VC has it ... could do a quick table lookup. anything
  older than v1.4.2 on a v1.4.2 or dev client is dropped."* (said when this release was still labelled
  v1.4.2) It is a declared dependency, it already
  holds the whole guild's versions before any sync traffic happens, and it costs no extra messages
  to do it (every client's version-check REQ is already broadcast carrying its full addon list).
  **The NEWER of the two claims wins, not VersionCheck's**, because the operator named the failure
  mode that a fixed priority creates: *"VC doesn't always get an answer due to congestion, so we
  can't hard block anyone with a not seen status."* The same congestion that loses an answer leaves
  stale ones behind, and a version only ever moves forward, so taking the higher claim is monotonic
  -- it can only let more peers through than either source alone, never fewer. A peer **neither**
  source has seen stays capable; not-seen is not a version, and there is an example pinning it.
  Incapable holders are now dropped at `DispatchOrQuery` rather than only at dispatch, so no version
  query and no dispatch timeout is ever spent on one, and the "not asking N holders" line prints a
  count and three names instead of forty. Eight examples in `Tests/wireskew_spec.lua` drive the REAL
  VersionCheck library through its own `RecordPeerVersion`. **Two defects were found by writing
  them, not before:** (1) an example passed against deliberately-reverted code because
  `BeginVersionQuery` returns before sending when the alt has no banker number, so its assertions
  held for an unrelated reason -- it now assigns one and asserts that precondition; (2) the lookup
  missed for most of a real guild, because VersionCheck keys by the sender string AceComm delivered
  and a **same-realm sender arrives bare** ("Oldguy") while we key on the realm-qualified form, so
  every spelling is tried now. Locations: `Modules/Guild.lua`, `Modules/P2PSession.lua`.

- **VERSION-TEXT-001 (peer review, thread 7b7efb1f): BRAND-001 was half-applied -- the window title
  read "TOG Bank v1.5.0" while `/togbank version` printed "TOGBankClassic version:
  TOGBankClassic-v1.5.0" beside it.** The rebrand exists only as display text (every identifier stays
  `TOGBankClassic`, by the operator's instruction), so it had to be applied by hand at each site, and
  two chat outputs were missed: `/togbank version` and the own-row of the `/togbank versioncheck`
  listing, both of which also printed the raw packager tag rather than a version. Now one place
  names and versions the addon to a player: `Constants.VersionText(raw)` (the `d.d.d` out of
  whatever the TOC carries, the raw string when it holds none, so a dev build shows
  `@project-version@` as FGI's does) and `Constants.BrandVersion()`, used by the window title and
  both chat sites. Two things deliberately NOT done, so nobody "fixes" them later: the OTHER rows of
  the versioncheck listing stay raw, because they are what each guildmate's client reported and
  normalising a peer's string would hide exactly the odd build that listing exists to expose; and
  `Guild.EncodeVersion` keeps its own parse, because it ORDERS peers where `VersionText` only
  DISPLAYS, and it must answer for strings the display helper hands back unchanged -- putting the
  data-leg gate and a label on one code path is how WIRE-SKEW-002 happened. Locations:
  `Modules/Constants.lua`, `Modules/UI.lua`, `Modules/Chat.lua`.

- **MULTIPC-004 (peer review, thread 7b7efb1f): a refused diff base left the fetch pinned, so the
  publish waited out the 180-second fallback with no link and nothing logged.** Two holders name two
  versions -- A names X, B names Y, Y newer, both newer than ours. The first claim defers the
  publish and asks A for X; the second replaces the wanted version with Y but finds the publish
  already deferred, so B is never asked. A delivers X, `Bank:ReceiveDiffBase` correctly refuses it
  as older than Y -- and used to `return false` with `awaitingDiffBase` still holding X, after which
  `RequestDiffBase` short-circuits on that flag before it ever looks at holders. The reviewer's
  remedy as specified -- clear the flag on every refusal and re-ask -- was implemented verbatim and
  turned an EXISTING example red (`multipc_spec`, "takes the base from a broadcast's holder too"):
  when the copy we asked for is still in flight and an OLDER one arrives from a third peer, dropping
  the flag makes the correct base bounce off the guard at the top of the function when it lands.
  Shipped narrower: the fetch is released and re-asked only when the version we WANT has moved since
  we asked (`awaitingDiffBase ~= want`). **Known incomplete, stated rather than hidden:** the spec
  asserts the flag is released, not that a second sync-request goes out, because `RequestDiffBase`
  also short-circuits on `P2P:HasActiveSession(me)` and the refused delivery does not complete that
  session -- so the re-ask can still be blocked by the stale session. Unpicking that is a
  session-completion change in the middle of the sync layer, not made untested immediately before a
  release; the cost if it bites is the same 180-second fallback as before, degraded logging rather
  than wrong data. `Tests/multipc_spec.lua`. Location: `Modules/Bank.lua`.

- **WIRE-SKEW-003: the fleet harness can now stand up a guild MID-UPGRADE, which is the one
  situation the operator has actually been stuck in and the one shape no test could express.** Every
  client in `Tests/env_fleet.lua` ran the same build, so "a peer on the old release" existed only as
  a hand-primed table in `wireskew_spec` -- and a hand-primed table is how WIRE-SKEW-002 shipped
  refusing nobody. Each fleet client now carries its own `addonVersion` (defaulting to the current
  tag form; `F.OLD_VERSION` is `TOGBankClassic-v1.4.1`, deliberately the packager's whole-tag shape
  rather than the bare `1.4.1` a spec would naturally write). Four end-to-end examples in
  `Tests/fullsync_spec.lua` drive banker, current viewer and v1.4.1 viewer as whole clients over the
  real message bus: the old client's announced version is read off its actual broadcast and
  `PeerSpeaksDataLeg` refuses it; it gets no send slot and no queue position while the capable
  viewer ends up holding the bank; a viewer does not ASK an old holder and so never sits out the
  delivery watchdog; and two current clients keep syncing across a second publish with the old one
  present. Proven red against the WIRE-SKEW-002 parse: with the version match anchored, the
  released v1.4.1 client reads as a dev build, passes the gate, takes the slot, and the first example
  fails on exactly the line that names it -- "a RELEASED v1.4.1 peer read as capable -- the tag
  prefix defeated the version match". `fleetreset_spec` extended so the two version strings are
  recognised as constants rather than per-fleet state.
  Locations: `Tests/env_fleet.lua`, `Tests/fullsync_spec.lua`, `Tests/fleetreset_spec.lua`.

- **BROWSE F1 (peer review): a banker role change while sitting on the embedded Requests tab did not
  rebuild the bottom cluster** -- no Fulfill Oldest or broom until the tab was switched away and
  back. Fixed on the roster event rather than on the tab: the guild-info refresh that already
  reaches the standalone Requests window now rebuilds the embedded body's role cluster too, and it
  caches on the role so it rebuilds only on a change. No timer, no poll. Location:
  `Modules/UI/Requests.lua`.

- **The 15-second delivery watch reported "successfully delivered" for a copy already held stale.**
  It compared arrival against the request rather than against the version the peer named, so a
  delivery that landed with nothing newer in it was still announced as a success. Location:
  `Modules/P2PSession.lua`.

- **CHAIN-004 / P2P-038: the banker's copies were never landing on the operator's other client.**
  Read off both clients on 2026-09-12 (a Bankers tab of "Old format / never" rows, a screen of
  `FAILED (delivery_timeout)`). Three handshake defects, one cause: the CHAIN-003 accept gate in
  `Sync:OnDataRequest` dropped any data QUERY with no unclaimed accept, and two real paths produce
  exactly that. (1) The BANKER's pull-path ACK (`Chat.lua`, `alt-request`) never took a send slot --
  the relay branch beside it did -- so every bank only the banker authored was ACKed and its query
  ignored: `Galdof-OldBlanchy sent a QUERY with no unclaimed accept -- ignored`. It reserves now,
  exactly as the relay does, and does not ACK at capacity. (2) A query arriving after the 30-second
  state-wait had released its accept was dropped the same way, and the requester then sat out the
  full 180-second delivery watchdog. The gate now serves a slot-less query when there is room (it
  takes the slot; the releases balance) and REFUSES it out loud when there is none -- `sync-busy`
  naming the alt, which the requester's `P2PSession:OnQueryRefused` turns into an advance to the
  next holder at once. One reply per requester per alt in flight (`Sync.inFlight`) keeps peer
  review A1's "one accept is one reply" now that a query can be its own accept. (3) A late accept
  for a session already ACTIVE elsewhere (`OnSyncAccept: wrong state ACTIVE`) was logged and left;
  the provider held that slot the whole state-wait for a query that never came. The requester now
  withdraws it with `sync-cancel`, and the provider's new `CancelAccept` (the state-wait keyed by
  session id) frees the slot at once. Also: `DispatchList` parks one item per alt -- every late
  offer re-parked the same banks and the park grew without bound. `AdvanceCandidate` cancels the
  delivery watchdog too. `Tests/pullpath_e2e_spec.lua` (10 examples) drives the real handlers on
  both sides of the ACK -- the join no spec drove before, because every data-leg spec hand-primed
  the slot; `chainwire_spec`'s CHAIN-003 example now pins the revised gate. Locations:
  `Modules/Inventory/Sync.lua`, `Modules/Chat.lua`, `Modules/P2PSession.lua`.

- **FULFIL-003: a request the bank could not fill wore the bag icon -- "it is in the bank, go get
  it".** The operator's screen, 2026-09-12: a recipe mailed out two days earlier, the next request
  for it still saying it was in the bank, with the bank open and empty of it. `Mail:CanFulfillRequest`
  computed `inBank` for the not-in-bags branch and then ignored it. An item in none of bags, bank or
  mail now says so (the question-mark icon); a name-only request (no itemID, an old client's) keeps
  the "check the bank" wording rather than claiming an absence it cannot look up. Two
  `fulfillhint_spec` examples had ratified the wrong string; corrected, plus the reported case.
  Location: `Modules/Mail.lua`.

- **BROWSE-005: the mailbox opens the Guild Bank window on its Requests tab.** The operator: *"when
  filling orders, it should just pop up the full new UI and go to the requests tab"*. The Send Mail
  tab hook opened the standalone Requests window; it opens `Browse:Open("requests")` now (a body
  already showing is redrawn for the fulfil icons the open mailbox changes). `events_spec`, three
  examples. Location: `Modules/Events.lua`.

- **STATUSBAR-002: the window's own status text drawn under the red "stay online" line.** The
  narrow-bar yield (SYNCED-001 / B2) only re-applied on the 0.5 s ticker, and every `DrawContent`
  between ticks -- one per incoming request merge -- painted the count straight onto the string.
  The window's `SetStatusText` now goes through the bar: parked while yielding, painted otherwise,
  the newest parked text restored when the line goes green or empty. Pool hygiene as in
  `Requests.lua`: the hook wraps the pristine method and comes off on release, so a pooled Frame's
  next owner is never parked. `Tests/statusbaryield_spec.lua`, seven examples. Location:
  `Modules/UI/StatusBar.lua`.

- **STATUSBAR-003: the "stay online" line overflowed a narrow window's status bar.** The operator,
  2026-09-12, with a screenshot: *"the stuff on the bank window overlaps the bank window status
  bar"* -- the amber "Bank update sent to 1, not confirmed by anyone yet -- stay online (29 online,
  5:03)" line ran past the bar's left edge into the window border and sat over the Close button on
  the right. The centre FontString was anchored by its centre alone, with no width, so a line longer
  than the bar overflowed both ends; the overlap rule bounded the LEFT and RIGHT sections against
  it but never the centre itself. Two halves: the centre is anchored to both edges of the bar with
  word wrap off, so the client truncates it with an ellipsis instead of overflowing; and
  `BuildPropagationText(short)` has a narrow-bar spelling of every state ("Update sent to 1,
  unconfirmed -- stay online (5:03)"), which `BuildSides` carries as a third return and
  `RefreshSides` swaps in when the full line is wider than the bar. Same state, same colour, same
  clock, no online count. `Tests/statusbaryield_spec.lua` (six examples on 300/400/560/2000-wide
  bars) and `Tests/propagation_spec.lua` (the short form of each state). Location:
  `Modules/UI/StatusBar.lua`.

- **MULTIPC-001: a banker played from several PCs on one shared account could publish a stale
  vault as the newest version.** The operator, 2026-09-11: *"one thing we have to accomodate, the
  banker CAN be red in its tab and out of date. For my guild we have a SHARED account many PC's in
  different states log into. so their data COULD be out of date until they open their bags/mail/
  bank. we need to account for that somehow."*

  **What was wrong, traced.** The sync design assumed ONE author per character, in five places:
  `NoteAdvertisedPublishTime` and `GetAltStaleness` refused any claim about our own name ("a peer
  cannot know a newer version of our bank than we do"), `P2PSession:OnOffer` dropped offers for our
  own number, HASH-CACHE-001 rule 1 said the same in prose, and the `togbank-d4` receive path did
  not refuse a payload for our own character. Each PC keeps its own SavedVariables, so the copy PC B
  holds of its own character can be weeks older than what PC A published -- and `Bank:Scan` reads
  only what is in reach (bags always, the vault at a bank NPC, mail at a mailbox) and merges it over
  whatever THIS PC's file holds for the rest, then mints a new version over the whole record. So PC B
  logging in stale and closing a VENDOR window merged today's bags with a vault PC A had since
  changed, stamped it as the newest version, and every peer adopted it over the correct copy. The
  red tab the operator described was the visible half; the silent half was worse.

  **Now -- the own tab can be red.** A peer naming a later version of our own character raises
  `newestAdvertisedAt` like any other banker's (`Guild:NewerSelfVersionAt` reads it against the
  canon we hold), `GetAltStaleness` reports our own name `"behind"` (winning over `"none"` / `"v1"`,
  because its tooltip is the one that says what fixes it: "Another computer published a newer copy
  of this bank ... Open your bank AND your mailbox on this character to refresh and republish it"),
  and a bare offer for our own number is let through to the version query so the PC learns it
  within the login cycle instead of waiting for someone else's broadcast. Nothing is ever FETCHED
  for our own name (`AdvertisedImproves` still answers `"self"`, the hash cache keeps its
  self-guard): the local record is the only copy kept per source, and adopting a flat copy would be
  carried forward beside freshly read bags and count every bag item twice -- which is also why the
  `togbank-d4` handler now ignores a payload naming our own character outright, and why the
  hash-list reply no longer seeds a STUB for our own name (a stub carries the peer's canon as if
  this PC held that version, so a wiped PC on the account would have read as current and published
  a bags-only scan over the real copy; with no record it reads as behind and the gate holds).

  **Now -- the publish gate (`Bank:CanPublish`).** Every source a scan reads is stamped with when
  THIS PC read it (`bank.lastScan` / `bags.lastScan`, the spelling `mail.lastScan` already used;
  local-only, never on the wire). A scan is always STORED; it is PUBLISHED (a canon minted, in the
  one place -- `Bank:MintVersion`) only when: (1) if a peer has named a later version of us, every
  source's stamp is at or after that publish time -- "until they open their bags/mail/bank" -- and
  the publish then happens even if the re-read came out identical, or the PC would advertise the old
  canon and stay red for ever; (2) if the login cycle has been opened but not yet answered
  (`P2PSession.consultBegun` / `selfConsulted`, settled by the collect window closing with nobody
  offering our bank or by the version query for our own number finishing), a PARTIAL read is
  deferred -- stored, with the before-images of the last PUBLISHED version kept for the bank-log
  diff -- and released the moment the cycle settles (`Bank:PublishIfDeferred`) or after 180 s if it
  never does; a read of all three sources this session is trusted on its own. A single-PC banker
  never meets either gate: nobody can name a version it did not publish, and the only cost is that a
  vendor scan in the first minute after login publishes a minute later. `/togbank dev trace <self>`
  prints the gate's inputs and verdict. While a publish is deferred, `Guild:CanServe` answers false
  for our own name (self-audit): the store already holds what this PC read but the canon still names
  the version before it, so serving those rows under that canon would be contents the identity does
  not describe -- nothing is advertised or served for ourselves until the gate releases.

  **KNOWN COST, stated.** A PC that is behind publishes NOTHING until it has read vault AND bags AND
  -- if the record has a mail block -- the mailbox, so a banker who uses mail and only visits the
  vault on that PC stays red until they also open a mailbox (the tooltip says so). A vault-only
  banker whose record never had a mail block publishes after the vault and bags alone (Peer Review
  on the self-audit: no mail block is "no mail source", not "stale mail"); the vault is never
  optional, since a record with no vault block is a PC that never read it. And a version published
  by a PC while nobody who holds it is online cannot be learned from anyone, so the login cycle
  answers "nothing newer" and a partial read publishes over it; only per-source versions on the wire
  would close that, and the wire is settled.

  **Three tightenings from the self-audit's peer review.** (F1) A version query for our own number
  whose asked peers all went SILENT does not settle the cycle -- the same rule the red tab already
  applied for every other banker eleven lines below, and this call site now uses it; a late reply
  still raises the newest time, and the wait is bounded by the 180 s fallback rather than
  open-ended. (F2) The consult begins the moment the login `SyncDeltaVersion` is CALLED
  (`P2PSession:BeginConsult`), before its collision-guard defer and its send, not when the collect
  window opens -- the login call is made from the roster-ready callback, which is also the first
  moment a scan can run, so the gap is a frame. (F3) is the mail rule above. Four more examples.

  `Tests/multipc_spec.lua`: 24 examples on a whole client through the real scan, receive paths and
  timers -- a single PC untouched (immediate publish before and after the cycle, the read stamps); a
  partial read before the cycle answers (stored not minted, released on the empty window, a full
  read trusted, the 180 s fallback, the bank-log diff spanning two deferred scans from the last
  published version); a PC that is behind (red with both times, no fetch, a bags-only scan stored
  and not published, published only once vault + bags + mail are re-read, identical contents still
  published, the log diff from the last published version when the NEXT scan releases a deferral,
  `stale:bank` first, unstamped records stale everywhere); a wiped PC (no stub seeded for our own
  name, reads as behind, holds a partial read, publishes on the full one); the offer path (a bare offer
  for our own number is queried, the reply turns the tab red and settles the cycle without a
  fetch, an answer no newer settles it yellow, never `"offered"` for self); and a delivery for our
  own character ignored with the per-source record intact. `Tests/tabstaleness_spec.lua`: the three
  examples that pinned "never behind on our own character" now pin the opposite, with the cache
  self-guard kept. NOT RUN IN GAME. Locations: `Modules/Bank.lua`, `Modules/Guild.lua`,
  `Modules/P2PSession.lua`, `Modules/Chat.lua`, `Modules/UI/Inventory.lua`.

- **OUTPUT-002: "[WHISPER-SPAM-FIX] Player X is not online" printed to every player's chat.**
  Reported from a live guild 2026-08-24, three in a row: *"also ensure they are behind a debug
  flag."* `Events:CHAT_MSG_SYSTEM` printed an unconditional `Output:Info` line for every bounced
  whisper, next to a `Debug` line saying the same thing. The Info line is gone; the bounce is
  logged once under `ROSTER` / `ONLINE` and shows only with that category on. One example in
  `Tests/events_spec.lua` asserts nothing user-visible is printed for a bounce and the debug
  channel still records it. Location: `Modules/Events.lua`.

- **TABCOLOUR-003: a number-only offer now turns the tab red.** The operator, after v1.4.1 tagged:
  *"if someone replies that they have a newer data set than us, we need to make that bankers tab go
  red until we can get it. we've done a great job in clearing the red, now we need to do just as
  good a job as setting the red."*

  **What was missing.** Red was decided by `newestAdvertisedAt` -- the publish time read off the
  newest canon anyone had mentioned. Since P2P-035 the offer is banker NUMBERS ONLY, so the reply to
  our own broadcast -- the one message that exists to say "I hold newer than what you advertised" --
  carried no time and moved no tab. Nor did the version reply that follows it (`ver-reply`, which
  DOES carry the canon): `OnVersionReply` filled in candidates and never told the tab or the
  advertised-hash cache. On the offer -> query -> fetch path the tab stayed yellow until the data
  landed and went... yellow. The broadcast-as-offer and hash-list-reply paths were unaffected; they
  carry the canon and raised the time.

  **Now.** A bare offer records `Guild.newerOfferedBy[alt] = peer` (`Guild:NoteNewerOffered`), and
  `GetAltStaleness` reports a fourth red state, `"offered"`, with the peer's name for the tooltip
  ("X says they hold a newer copy of this bank than yours"). It clears on exactly two events: the
  delivery lands for that alt (`Chat.lua`, after the tuples are stored -- if that copy is still older
  than a version someone NAMED, `newestAdvertisedAt` keeps it red on its own), or the version query
  finishes with nobody holding an improving version AND every asked peer having answered. A peer
  that never answers leaves it red -- "until we can get it" -- for the next cycle to settle. The
  version reply now feeds both caches (`NoteAdvertisedPublishTime`, `NoteAdvertisedHashes`), so from
  the reply on the tab is red by publish time like every other path and `hashdump`'s `known` column
  agrees with it. Our own character is never "offered" (we are the author). Session-scoped, reset
  with `newestAdvertisedAt` on Init.

  Seven examples: six in `Tests/p2psession_spec.lua` (offer -> offered; reply -> behind with the
  cache learning the canon; false alarm -> current; "nothing servable" -> current; silent offerer
  stays red; own character never offered) and one whole-client example in
  `Tests/tabstaleness_spec.lua` through the real `hash-offer2` receive path and a real `togbank-d4`
  delivery. NOT RUN IN GAME. Locations: `Modules/Guild.lua`, `Modules/P2PSession.lua`,
  `Modules/Chat.lua`, `Modules/UI/Inventory.lua`.

- **P2P-037: a holder with a NEWER copy than asked for refused to serve it, and the requester could
  not learn the new version.** Read off the banker account at 23:4x, five times in a row:
  `Galdof wants Togstone at ...1707..., we hold ...1713... - busy (version)`, with `sendqueue`
  showing 0/3 slots in use. Togstone's bank was rescanned six seconds after Galdof learned its
  version, so Galdof asked for the old one; the P2P-035 gate in `HandleSyncRequest` was an EXACT
  match, so an idle holder with the strictly better copy said "not that one"; and Galdof's live
  session could not pick up the post-scan broadcast because `OnOffer` skipped every offer for an
  alt with a session in flight. The retry cycle then re-asked the same peer for the same stale
  version.

  Two changes. The holder serves when it holds the requested version **or a later one**
  (`CanonIsNewer`); it refuses only when its own copy is OLDER than asked -- a relay behind the
  author, which is the case the gate was written for. And a canon-bearing offer that improves what
  we hold is no longer dropped for an alt with a live session: it adds or refreshes that peer among
  the session's candidates (so `AdvanceCandidate` and the retry can reach it, and the next request
  to that peer names the new version) and feeds the tab and the advertised-hash cache as any other
  offer does. Bare offers are still not folded in -- they name nothing a session can use. The
  earlier example that pinned "refuses a version it no longer holds" asserted the defect and is
  rewritten; one new example folds the author's rescan into a live session. NOT RUN IN GAME.
  Location: `Modules/P2PSession.lua`.

- **NAME-001: a request row reading `Item 7969`.** Reported from a live guild on 2026-08-16:
  *"item id did not resolve into a descriptive name."* Two defects behind one screenshot.

  **The request stored the placeholder.** `UI/Search.lua` mints a request's name from the
  inventory row's resolved name, and when the requester's client could not name the item (a cold
  cache on that client, before ItemDB shipped) the row's name was the resolver's stand-in, `Item
  <id>`. That went into `request.item`, was synced to every client, and stays for the life of the
  request -- the record is append-only and correct as written. But every request since REQ-001
  also carries `itemID`, so the name can be re-derived at any time. `Item:RequestDisplayName(req)`
  returns the stored name when it is a real one and re-resolves a placeholder from the id
  (ItemDB, then the client cache) at display time, never mutating the record; the Requests window
  cells, the fulfil tooltip, the delete and complete-quantity dialogs all read it, and Search
  resolves through it at creation so a new request never stores the placeholder when the id can
  be named. `Item:IsPlaceholderName` is the one spelling of the three stand-ins the addon produces.

  **The resolver's client step never asked for the name.** `Resolve.describe` step 2 uses
  `GetItemInfoInstant` -- cache-independent, and nameless -- and returned `Item <id>` even when
  `GetItemInfo` had the name cached. It now takes the name, link, quality and levels from
  `GetItemInfo` when that answers, and falls back to the id only on a genuinely cold cache. Every
  Inventory-window row for an id ItemDB lacks benefits, not only requests.

  `Tests/requestname_spec.lua` (6 examples: the placeholder spellings, passthrough, the live
  `Item 7969` case re-resolved through ItemDB without mutating the record, through the client
  cache, and the honest fallbacks) plus two in `Tests/resolve_spec.lua` (cached name used; cold
  cache still names by id). Locations: `Modules/Item.lua`, `Modules/Inventory/Resolve.lua`,
  `Modules/UI/Requests.lua`, `Modules/UI/Search.lua`.

- **RESOLVE-002: the V2 view's `equipId` was a string, the legacy row's a number.** Follow-up to
  RESOLVE-001's "audit the other `Resolve.describe` fields against what the UI consumes". Read
  every `Info.*` reader in `Modules/` against `Store:GetAltView`'s mapping: `name`, `icon`,
  `rarity` (from `quality`), `level` (from `itemLevel`), `reqLevel`, `class`, `subClass` all agree;
  `price` is legacy-only and read by nothing but a backfill. `equipId` did not: the legacy loader
  stores `C_Item.GetItemInventoryTypeByID` -- the numeric `Enum.InventoryType` -- and the view
  copied `Resolve.describe`'s `equipLoc`, the `INVTYPE_*` string that both LibItemDB
  (`LibItemDB-1.0.lua:259`) and `GetItemInfoInstant` return. The By-Type sort compares `equipId`
  with `<` as a tie-breaker, so V2 rows sorted slots by token spelling, and a Search result mixing
  a V2 alt with a legacy-only alt would compare a string against a number -- which raises inside
  `table.sort` (reasoned from the comparator and Lua 5.1's `<`; not observed in a client, and the
  mixed case is pinned on two hand-made rows rather than driven through Search). The view now maps the token to the enum value (`INVTYPE_HEAD` = 1 ... `INVTYPE_RELIC`
  = 28, from Era's `ItemConstantsDocumentation.lua`; non-equippable or unknown = 0, as the legacy
  path stores it). Three examples in `Tests/store_spec.lua`, including the mixed-row comparator.
  Location: `Modules/Inventory/Store.lua`.

- **ROSTER-005: a banker kicked or leaving mid-session stayed a banker until relog, even with the
  system message delivered.** Found establishing the ROSTER-002 residual ("what happens when the
  departure message is missed?") -- the answer was that the delivered case was no better.
  `OnMemberLeft` / `OnMemberJoined` invalidated `banksCache` only, on the belief that
  `GUILD_ROSTER_UPDATE` would drive `RebuildBankerRoster`; `Events.lua` ignores that event once
  login init completes, and `GetBanks()` re-derives from `memberRoster`, which nobody had rebuilt --
  so the departed banker came straight back into the list and `IsBank` stayed true. The existing
  ROSTER-002 example passed only because it called `RefreshOnlineCache` by hand after the message,
  which production never did. The callback now re-pulls `memberRoster` from the library (which has
  already applied the change before it fires, `LibGuildRoster-1.0.lua:2228` then `:2243`) and then
  invalidates the cache. One new example in `Tests/guildroster_integration_spec.lua` drives the kick
  message alone, no manual refresh: red before the fix, green after. Self-audit tightening: the
  callback calls `_RefreshFromRosterLib` directly rather than `RefreshOnlineCache`, whose not-ready
  fallback is the synchronous `GetGuildRosterInfo` walk PERF-008 deferred off the login path -- a
  chat event must never be able to reach it. **The residual, established:**
  a departure whose system message is never delivered persists until the next login build, in the
  library and therefore in TOGBank; the cost is one ex-banker listed until relog, whose whispers
  bounce and mark it offline. Accepted, no further change. Location: `Modules/Guild.lua`.

- **HIGHLIGHT-003 (audit finding 11, second read round 20): the "Highlight needed items" tick did
  not survive a reload.** `ItemHighlight:SetEnabled` wrote `highlightEnabled` to the raw AceDB root
  (`TOGBankClassicDB.settings`) and nothing in the tree read it; `Initialize` hardcoded off. The
  preference now lives in `db.global` (a per-player UI toggle, the tightest scope this addon uses
  for those) and `ItemHighlight:ApplySavedPreference` honours it from the login roster refresh in
  `Events.lua` -- the first moment `IsBank` can answer, the same hook `Options:InitGuild` uses -- so
  it never turns on for a non-banker whatever was saved. Four examples in
  `Tests/itemhighlight_spec.lua`. Location: `Modules/ItemHighlight.lua`, `Modules/Events.lua`.

- **DB-003 (audit finding 18, round 20 -- worse than filed): the `deltaMetrics` literal was in FOUR
  places and had diverged.** `Reset`, twice in `Load`, and `ResetDeltaMetrics` each carried their
  own copy; the first three had 16 keys and the fourth 20 (`totalComputeTime`, `computeCount`,
  `totalApplyTime`, `applyCount`), so a guild record created at first login lacked four counters a
  `/togbank`-reset one had, and every reader carried an `or 0` that was load-bearing rather than
  belt-and-braces. One `newDeltaMetrics()` constructor (20 keys) at all four sites; the second
  `Load` block, which could never take effect after the first, deleted; `Load` also backfills
  missing counters onto a record saved before they existed. Two examples in
  `Tests/database_spec.lua`: fresh, repaired and reset records share one key set (20), and an old
  record is backfilled without its existing counters being reset. Location: `Modules/Database.lua`.

- **PERF-023 (audit finding 20): `/togbank dev perfstats` printed `inf` per minute in the frame the
  session started.** `GetCurrentStats` divided by a zero session duration. Rates over no elapsed
  time are 0; one example in `Tests/performance_spec.lua`. Location: `Modules/Performance.lua`.

### Internal

- **INV2-RETIRE-002: the delta-snapshot cache is deleted -- it deep-copied every item row of the
  banker's record on every scan for a reader that no longer existed.** Found while enumerating the
  readers of the legacy item rows for the V1 retirement (bank #12531). `Database:SaveSnapshot` was
  called at the end of every `Bank:Scan` and `PublishIfDeferred` and deep-copied the whole alt
  record -- bags, bank and mail rows, `Info` tables, links -- into an in-memory cache read only by
  `Database:GetSnapshot`, whose one consumer (the legacy alt-delta's `ComputeDelta`) INV2 step 10
  deleted in v1.4.0. Since then the copy was made and nothing read it. Gone with it:
  `GetSnapshot`, `ValidateSnapshot`, `DeepCopy`, `PROTOCOL.DELTA_SNAPSHOT_MAX_AGE`, and
  `/togbank dev clearsnapshots`, which cleared the `db.deltaSnapshots` SavedVariables key that
  PERF-012 stopped writing and `Database:Init` nils on every load -- so the command has answered
  "No snapshots to clear" since v1.2 whatever the cache held. The load-time purge of that stale key
  stays. `Tests/database_spec.lua` now guards that none of the four methods exists; the
  `SaveSnapshot` stub was removed from the seven spec stand-ins of `TOGBankClassic_Database` so a
  scan that reaches for it fails rather than passing against a stub wider than production
  (the CMD-001 shape). 1187/0. Locations: `Modules/Database.lua`, `Modules/Bank.lua`,
  `Modules/Chat.lua`, `Modules/Constants.lua`, `docs/DEV_COMMANDS.md`, `README.txt`.

- **DOC-006: three texts said a hash-list broadcast happens "after every bank scan"; nothing does
  that, and by decision nothing will.** Found while tracing MULTIPC-001's deferred publish: no path
  calls `SyncDeltaVersion` from `Bank:Scan`; a fresh version reaches peers on the 10-minute share
  timer, `/togbank share`, `/togbank sync` (which opening the Inventory window runs), the P2P
  catch-up cycle, or by answering anyone's broadcast with an offer. The operator, 2026-09-11, on
  adding one: *"the problem with this is when, you risk doing a broadcast with 1/2 the data, and
  then creating another hash 5 seconds later. we rand into this issue where that was 'too close' and
  wasn't updating. right now you just do a /togbank share and it solves it ... i think we're
  covered."* The `/togbank share` help text, the `SyncDeltaVersion` docblock (now stating the
  decision and why) and README.txt's two lines say what actually happens. Locations:
  `Modules/Chat.lua`, `Modules/Events.lua`, `README.txt`.

- **N6: the pre-v1.4.1 KEYED `hash-list-broadcast` / `hash-offer` receive branches are switched
  OFF.** Peer Review's follow-up: nothing in this tree sends the keyed forms (v1.4.1+ sends only
  the numbered `hlb2` / `hash-offer2`), so their receive branches in `Chat.lua` were the last
  consumer, kept while old-build peers were still broadcasting. The operator, 2026-09-11: *"i'm ok
  with commenting it out first, then if nothing happens over a week or two, we can delete it."*
  The comment-out is a dev switch, `legacyKeyedReceive`, default OFF, so it can be undone in game
  (`/togbank dev switches legacyKeyedReceive on`) if an old-build peer turns up during the grace
  period; a keyed message is logged under `P2P` / `BROADCAST` and dropped. The `hlb2` shim, which
  re-types the numbered broadcast onto the shared path, marks its message `fromNumbered` so the
  gate never touches it. The switch's `retire` note names the deletion. Specs that drive the keyed
  path flip the switch on and say so; one new example in `Tests/tabstaleness_spec.lua` proves a
  keyed offer and broadcast do nothing at the default while the numbered one still lands.

- **PKG-001 (audit finding 22): dead `Libs/LibStub/` deleted and `CHANGELOG_ARCHIVE.md` kept out
  of the zip.** Neither TOC loaded the vendored LibStub (it arrives from the external Ace3
  dependency), so six dead files shipped to players; the folder is gone. `CHANGELOG_ARCHIVE.md` is
  now in `.pkgmeta`'s `ignore:` (bare name, per the file's own syntax notes), verified with
  `wow-version-replication.ps1 -DryRun`: the archive reads `[skip]`, `Libs/` holds only
  LibDataBroker and LibDBIcon, every shipped file reads `WOULD`.

- **Peer review finding 39 (round 19): the fulfil-button decision block was implemented twice.**
  The twelve-branch `if/elseif` turning `Mail:CanFulfillRequest`'s verdict into the button's
  enabled state, icon and tooltip sat byte-for-byte in both `_PopulateRow` and
  `_RefreshFulfillButtons` in `Modules/UI/Requests.lua`, so every new reason string had to be
  added to both by hand -- miss one and the icon differs between the full redraw and the next
  bag-update refresh, which reads as flicker. Now one local, `applyFulfillState`, called from
  both; `quantityNeeded` is the one spelling of the units-owed arithmetic. The refresh path also
  now hides the button for a row whose request completed between draws, as the full draw does --
  and its spacer with it (self-audit F1), so no gap is left until the next full redraw.
  Two source-level examples in `Tests/fulfillsplit_spec.lua` pin that the decision exists once and
  both entry points call it. The round's other note -- Log API callbacks run from a timer, never a
  hardware event -- is now in `RegisterCallback`'s docblock (see LOGAPI-001).

- **INV2-SUFFIX-002 (latent): `Item:Aggregate` dropped `Suffix`, `Enchant` and `Info`.** Every
  rebuilt row was `{ ID, Count, Link, ItemString, ForceLink }`, so the variant identity a row
  carried in went out as nothing. Harmless only because `UI/Search.lua` used the output for its
  name corpus alone; the first request-carrying row routed through it would have brought
  INV2-SUFFIX-001 straight back with no test to catch it. Rows now carry all three (a merge keeps
  the first non-nil), and the two byte-identical source loops are one `absorb` walk with a shared
  `mergeRow` / `newRow`. Three examples in `Tests/aggregate_mail_spec.lua`. Location:
  `Modules/Item.lua`.

- **P2P-035 H6 (peer review): two-account minting convergence is now DRIVEN, not argued.**
  `BankerNumbers.lua`'s header claims that two banker accounts minting independently converge on
  one table -- lower-sorting sender wins a same-version conflict, the loser re-mints its stragglers
  under a higher version, the winner adopts that back. Two examples in
  `Tests/bankernumbers_spec.lua` now run it as two real clients taking turns in the one Lua state
  (each booted from its own saved roster, speaking through the real `togbank-hl` receive path):
  the same-second conflict where both minted `0001` for different bankers resolves to one table with
  every number naming exactly one banker and is stable under a further exchange; and two accounts
  minting the same roster produce the identical table and never disturb each other. No code
  change -- the argument held.

- **CLOCK-001: the offline clock no longer starts at 0.** Self-audit H5(a), Peer Review's framing:
  `env_togbank.lua` defaulted `GetTime()` / `GetServerTime()` to 0, a server time no client ever
  reads, so every whole-client spec ran where any `ts <= 0` or `not ts or ts == 0` guard took the
  branch production never takes -- a suite-wide way to hide a defect, found because LOGAPI-001's
  examples had to set the clock by hand. The default is now a fixed 2026 epoch (`env.EPOCH`); a
  spec that needs 0 sets 0. The whole suite passed at the new default with no production change --
  four assertions in `smoke_spec`, `output_spec` and `store_spec` had hard-coded the 0 start and
  now read `env.EPOCH`.

- **CMD-001 FOLLOW-UP: the offline stubs audited against the real libraries.** Every stand-in in
  `Tests/` for a real library or Core function, read against the library source for return shape,
  argument order and sentinels -- not against what the caller expects. Found and fixed: (1)
  `env.aceGetArgs` was a RE-IMPLEMENTATION of AceConsole's `GetArgs` -- the same class as CMD-001
  one step removed -- and differed twice from `AceConsole-3.0.lua:140`: it dropped the third
  parameter (`startpos`, how a caller continues from `nextposition`) and split on any whitespace
  where the library splits on the space character and honours quotes. `env.stubCore` now installs
  the INSTALLED library's `GetArgs`; a new example in `Tests/coresurface_spec.lua` drives the two
  inputs the copy got wrong. (2) Three capture stubs of `Core:SendWhisper` returned nothing where
  the real one returns `true` for an online target, and seven production sites branch on that
  value (`RequestLog.lua:1321`, `Guild.lua:1668/2207/2809/2938/2972`, `Chat.lua:783`) -- so those
  specs were exercising the offline branch the client would not take. All return `true` now. (3)
  The `Options` stub in `env.standUpClient` lacked `GetAutoTombstoneDays` (found under
  LOGAPI-001, above). Read and found FAITHFUL or deliberately narrower: the LibItemDB stubs
  (`GetInfo` 6 of 7 returns, which the library documents as supported; `GetRequiredLevel` 0 for
  unknown where the library says nil, equivalent under the caller's `or 0`), `RegisterComm`,
  `SerializeWithChecksum` pass-throughs (documented as such where used), and every
  `SendCommMessage` capture (positional order matches `Core.lua:8`). LibGuildRoster is the real
  library throughout.

- **HASH-REV-001 gap (4) closed: the end-to-end negotiation spec now crosses the real serialiser.**
  `Tests/hashnegotiation_e2e_spec.lua` handed the second client the Lua table
  `BuildBankerHashList` returned, so every scan -> stamp -> advertise -> compare example compared
  two tables that never left the process. `advertise()` now serialises and deserialises the whole
  list through the installed AceSerializer-3.0 -- the library `Core:SerializeWithChecksum` wraps --
  before the peer compares it, so a value the serialiser mangles (the float-mangled-number concern
  `CanonIsNewer`'s docblock names) fails here. All nine examples green on the first run; the
  checksum framing and AceComm chunking remain `syncwire_spec`'s ground. Gaps (1) two real
  released versions and (5) the P2P layer above this chain remain open, the first blocked on two
  live clients.

- `Guild:CheckMailFulfillment` (`Modules/RequestLog.lua`) deleted: it never acquired a caller
  (`Mail:CanFulfillRequest` reads the actor's own mail directly) and it walked every `Info.alts`
  entry including ex-bankers, the TOOLTIP-002 class. A tombstone comment marks where it was.

- Dev docs that still said the share timer was "every 3 minutes" corrected to the real ten-minute /
  after-scan cadence (`docs/FEATURE_IMPROVEMENTS.md`, `docs/REQUEST_COMMS.md`,
  `docs/DELTA_IMPLEMENTATION_TODO.md`), and each brought to markdownlint-clean on the way: 85
  pre-existing violations in the TODO, 8 in REQUEST_COMMS, and a UTF-8 BOM on FEATURE_IMPROVEMENTS.

### Internal - The Delta Release, step 1: the legacy inventory retired

*Folded into v1.5.0 (then labelled v1.4.2) on 2026-09-11 at the operator's word -- "ALL our work is on v1.4.2" -- after
first accumulating under a provisional v1.5.0 heading. The design is `docs/DELTA_RELEASE.md`, and
the decision it follows, 2026-09-11: "rip it out and use the library" -- TOGBank's own sync
frameworks give way to DeltaSync-1.0. Build order: retire the legacy scan (this section), move onto
the DeltaSync host, deltas over the canon chain, then the bank log falls out of the deltas.*

- **INV2-RETIRE-003: the V2 store is the scan's source of truth -- the hash, the version stamp and
  the bank log are computed over its records, not the legacy aggregate.** The first step of
  retiring the V1 rows, and the prerequisite for every delta that follows: a receiver proves a
  chain of deltas by recomputing the content hash over ITS records and comparing to the author's
  canon, which only works if the author hashed the same shape. Until now the author hashed
  `alt.items` (the legacy aggregate, which merges suffix variants) while every receiver held V2
  tuples (which keep them apart) -- `CanonFrom`'s own note recorded that the two "can legitimately
  differ". So in `Bank:Scan` the V2 write is now UNCONDITIONAL and no longer inside a pcall -- it
  was a switch-gated mirror whose failure was "loud but non-fatal"; with the store feeding the hash,
  a fault in it is a scan fault and surfaces as one, and nothing is minted or stored over it. The
  before-images for the bank log and the deferred publish (MULTIPC-001) are the store's record set
  captured ahead of the write; `MintVersion` takes the records it stamps and logs; `PublishIfDeferred`
  reads them back from the store. The `inventoryV2` switch still governs the READ accessors until
  the legacy rows are stripped. The legacy walk and sub-tables are still written for the readers
  that remain (enumerated in `docs/DELTA_RELEASE.md` section 4). **Expect one version bump per
  character on the first scan after upgrading** -- the previous content hash was taken over the
  merged aggregate -- and then quiet, the same self-correcting blip `inventoryContentHash`'s own
  introduction caused.
  - **HASH-REV-002: revision 1 reads tuples.** `hashInventoryItemsV1` accepted only `.ID` rows, so
    with the scan hashing tuples it would have collapsed to money-only on every client at once. It
    now reads a tuple as id and count -- the identity is still `ID:Count`, still blind to suffix and
    enchant -- and a tuple hashes identically to the legacy row for the same item. The freeze it
    carried was for unmigrated clients, which the 2026-09-09 no-wire-back-compat directive ended;
    the value only has to agree between clients on this build, and now does. A suffix-variant pair
    the legacy aggregate merged is two entries here; that is inside the one-bump-per-character
    above. **KNOWN COST (Peer Review, 55250c0f F2): the one peer this can disagree with is a
    pre-v1.4.1 build reached through the N6 `legacyKeyedReceive` switch**, which ships in this
    same release, OFF by default. Off, no keyed message is accepted and no revision-1 value is ever
    compared with such a peer. Turned on for the grace period, a v1.4.0 peer's revision 1 (taken
    over merged legacy rows) differs from ours (over tuples) for any bank holding suffix variants,
    so those banks read as out of sync with that peer for as long as the switch is on. Accepted:
    the switch exists for a week or two at most, and the N6 directive deletes the branches and the
    switch in the release after this one -- the rev1 difference is one more reason not to extend
    its life.
  - Specs: `wiring_spec` re-pins the contract (the write is unconditional; the stamp is taken over
    tuples -- captured off the stamp call, since the hash stub returns a constant; a V2 fault
    surfaces and leaves no half-published state); `inventoryhash_spec`'s "ignores tuple rows"
    example inverted with its reasoning; `bank_spec`'s scan-gating block loads the inventory
    modules the scan now requires. 1188/0. NOT RUN IN GAME. Locations: `Modules/Bank.lua`,
    `Modules/DeltaComms.lua`, `Tests/wiring_spec.lua`, `Tests/inventoryhash_spec.lua`,
    `Tests/bank_spec.lua`.
  - **The legacy-only readers moved to the store, and "content" now means the store.**
    `Guild:HasAltContent` answers from the V2 store alone -- it used to fall through to the four
    legacy item arrays, saying "yes" for rows `CanServe` (`#records > 0`) would refuse to ship,
    which is the Peer Review F1 shape (accept a request, send nothing). The fulfil path's "in mail"
    / "in bank" hint (`Mail:CanFulfillRequest`) and the status bar's mail count read the store's
    per-source buckets through a new `Store:GetAltSourceRecords(guild, alt, source)` -- the local
    banker's own scans write per source, so the split the legacy sub-tables kept is there to read;
    a received record (one flat bucket) answers empty for a named source, correctly, because a
    receiver was never told which source a row sat in. The name-only match the hint used to allow
    (a request with no itemID, from a client older than REQ-001) reads as "not found elsewhere",
    since a tuple carries no name. `Guild:EnsureLegacyFields` is deleted with its three callers;
    the two stub writers (`RebuildBankerRoster`, the hash-list reply) create metadata-only records.
    `SendAltData`'s legacy-array debug counts are gone. A consequence pinned in `servablecanon_spec`:
    the version broadcast now EXCLUDES a legacy-only copy outright rather than advertising it with
    a nil canon -- the stronger form of HASH-CANON-009. Nine spec files that staged "we hold
    content" as a legacy `items = { ... }` array now seed the store (`env.freshV2` / `env.holdV2`,
    new in `Tests/env_togbank.lua`), and `Tests/fulfillhint_spec.lua` covers the hint and the
    per-source read for the first time (9 examples). 1198/0. Locations: `Modules/Guild.lua`,
    `Modules/Mail.lua`, `Modules/UI/StatusBar.lua`, `Modules/Chat.lua`,
    `Modules/Inventory/Store.lua`, `Tests/env_togbank.lua`, `Tests/fulfillhint_spec.lua`, and the
    re-seeded specs (`guild_spec`, `hashcache_spec`, `tabstaleness_spec`, `p2psession_spec`,
    `bankernumbers_spec`, `logapi_spec`, `trace_spec`, `hashdump_spec`, `inventoryordering_spec`,
    `servablecanon_spec`).
  - **THE LEGACY ITEM ROWS ARE GONE: one container walk, metadata-only records, an unconditional
    strip on load, and no switch left to choose a store.** The third and last increment of the
    retirement. `Bank:Scan` is `Inventory/Scan.lua`'s single walk -- the legacy `ScanBag` /
    `ScanBags` / `ScanBank` walkers, `IsBankAvailable`, the `alt.items` aggregate rebuild and the
    debug sample blocks are deleted; `alt.bank` / `alt.bags` are `{ slots, lastScan }` and
    `alt.mail` is `{ slots, version, lastScan }`, never rows. The mail bucket is written to the
    store only when the mailbox was actually read this scan and KEPT otherwise -- unread is unknown,
    not empty, the vault rule applied to mail -- and `mailHash` is taken over the mail tuples (a
    mail row is linkless in both shapes, so the value is unchanged). `Scan.lua` loses the
    `withLegacy` / `dualWrite` plumbing and emits tuples only. `Guild:GetAltItems` and
    `GetAltItemTotal` read the store and nothing else: the `inventoryV2` gate, the
    `IsAltComplete` gate (INV2-STALE-001) and the legacy fallback are deleted together, because
    with no legacy record the choice for a schema-1 record is a SHORT total or an EMPTY one, and
    short wins -- it heals on that banker's next mailbox visit. `GetAltItemTotal` walks the record
    cache (populated by the write) rather than resolving a view, so a tooltip hover never pays for
    names and links it does not print. `Database:Load` calls a new `StripLegacyItemRows` --
    synchronous, before any reader, idempotent, UNCONDITIONAL: `docs/DELTA_RELEASE.md` section 4
    said to gate it on `IsAltComplete` so the accessors' fallback could keep reading a schema-1
    record's rows, and with the fallback deleted the gate would only have kept 56% of the file
    (measured: ~35,900 of 64,123 lines on the operator's own account) for nothing. A second pass,
    `StripAllLegacyItemRows`, runs from `Database:Init` over EVERY guild record in the faction
    scope -- `Load` runs per guild name, so a record for a guild the player has since left would
    otherwise keep its rows in the file forever (self-audit F4). Deleted with
    the rows, each because the rows were its whole subject: `Database:PurgeLinklessGearGhosts`
    and its 30-second login timer (ITEM-004), `/togbank dev purgeghosts`, `/togbank dev compare`
    (two encodings of one walk, diffed -- there is one encoding), `Guild:UsesSYNC006` (no caller),
    the `items` clauses in `CleanupMalformedAlts` / `HasAltData` / the ROSTER-002 zero-stub test
    (the stub test asks the store instead), `dev trace`'s legacy-row column, and the `inventoryV2`
    and `dualWrite` switches -- retired on the schedule their own `retire` notes named, "when V2 is
    the only storage format". A stale value for either in an older `db.global.switches` is
    ignored; `/togbank dev switches inventoryV2 on` now reports `Unknown switch`. `sendV2Wire`
    and `legacyKeyedReceive` remain. **A closing debug line in `Bank:Scan` still read
    `#alt.mail.items` after the mail block stopped carrying rows** -- every scan with a mail block
    would have raised in game; the handoff called the 25 red examples "all specs", and 20 of them
    were this line. Caught by the suite before any client ran it; deleted. Specs: `bank_spec`,
    `multipc_spec` and `wiring_spec` re-pinned on the store's per-source buckets;
    `altitems_spec` rewritten for the V2-only accessors (with `writ-cannot` for the nine legacy-
    branch examples) and pins that `GetAltItemTotal` resolves no view; `switches_spec` re-pinned
    on the surviving switches, the dependency rule pinned through a pair the example registers,
    plus a new guard that no shipped file reads a retired switch; `scan_spec` pins tuples-only
    output; `chatcommand_spec` drives `legacyKeyedReceive` (off by default, so "on" is
    observable); `tooltipbankerinfo_spec` seeds the store, and its hook describe now loads its own
    modules instead of passing on the previous describe's leaked globals; `trace_spec` re-pinned
    on a tuple-less record; `database_spec` covers the strip (six examples: every row site, every
    metadata field kept, synchronous, unconditional with the store taken away, idempotent count,
    malformed input, the Init-time pass over every guild). `docs/DEV_COMMANDS.md` records the
    retired commands and switches. 1199/0,
    luacheck clean. NOT RUN IN GAME -- the tree now mixes v1.5.0 and this. Locations:
    `Modules/Bank.lua`, `Modules/Inventory/Scan.lua`, `Modules/Guild.lua`,
    `Modules/Database.lua`, `Modules/Chat.lua`, `Modules/Switches.lua`, `docs/DEV_COMMANDS.md`,
    and the specs named.
  - **INV2-COMPAT-001: `Info.alts[name].items` keeps answering for other addons, from the store.**
    The operator, on reading that the strip left TOGProfessionMaster's `[Bank]` button empty:
    *"we can't break the bank integration, why did you break it?"* I had. TPM's `Compat.lua`
    (`addon.Bank.GetStock` / `GetBanksWithItem`) reads `TOGBankClassic_Guild.Info.alts[name].items`
    directly -- `pairs` over the alts, `ipairs` over `.items`, `entry.ID` / `entry.Count` -- and
    deleting the rows without a replacement broke a shipped consumer; I filed it as a dependency
    instead of keeping it working. Now every alt record carries a metatable whose `__index` answers
    `items` from `Guild:GetAltItems(name)` -- the store's resolved view, the same array every TOGBank
    window reads -- and the alts table carries a `__newindex` that wraps any record created later at
    a new key (`Bank:Scan`, the roster stub, the hash-list stub, the tuple receive); `ResetPlayer`,
    which replaces at an existing key, wraps by hand. **It is a fix as well as a shim:** on v1.4.x
    TPM was already reading STALE rows for every received banker, because the tuple receive never
    refreshed `alt.items`; it now reads live data for all of them. It does not undo the strip: the
    client serializes a table's RAW contents, so a metatable-provided field never reaches the
    SavedVariables (AceDB's own defaults rely on the same property), and the strip reads through
    `rawget` so a wrapped record is not mistaken for one that still has rows. The receive stub's
    `items = {}` seed and the no-change slot-correction's `bank = { items = {} }` seeds are gone --
    a raw empty array would persist and shadow the shim. `Tests/altcompat_spec.lua` (13 examples)
    drives TPM's two functions COPIED VERBATIM from its `Compat.lua` against real Guild + Store +
    Database: totals and per-banker lists from the store, live after a write, empty-not-nil for an
    unseen banker, wrapped for a record added after load and for `ResetPlayer`, the same array
    `GetAltItems` returns, and a raw `pairs` walk that never yields `items`. 1212/0. TPM moving to
    the accessors is still worth doing on its side (its `GetStock` also counts ex-bankers), but
    nothing is broken while it does not. Locations: `Modules/Database.lua`, `Modules/Chat.lua`,
    `Tests/altcompat_spec.lua`, `Tests/database_spec.lua`, `.luarc.json` (`rawset`).
  - **HASH-PIN-001: the canon's bytes are frozen as literals, and the dead calling convention
    inside the hash function is gone.** Peer Review (608cc17a F2): leaving an unreachable branch
    in the one function that mints canons is the dangerous choice, because the next reader cannot
    tell which convention is live -- and "editing the hash function invites a canon change" does
    not apply to deleting a branch nothing reaches. Done in the order that proves it:
    `inventoryhash_spec` first pinned the exact string `computeInventoryHashWith` feeds the
    checksum for a fixed record set (revision 2 `123456|I:10132:863:0:1,...`, revision 1
    `123456|I:10132:1,...`, and the empty inventory) -- captured green BEFORE the deletion -- and
    then the pre-SYNC-006 `(bank, bags, money)` branch (reading `bank.items` / `bags.items`,
    emitting `B:` / `G:` parts through its own copy of the checksum loop) was deleted with the
    literals still green after. The old shape is now REFUSED with an error naming this ticket,
    where before a table in slot 2 would have silently hashed money-only. A real hardening fell
    out of it: the money-slot type guard (audit finding 26) sat only on the deleted branch; the
    live branch had `money or 0` and would have baked a table address into the hash. It is guarded
    now, and `database_spec`'s four legacy-hash examples are re-pinned on the live form (one now
    asserts the refusal). `Modules/DeltaComms.lua`, `Tests/inventoryhash_spec.lua`,
    `Tests/database_spec.lua`.
  - Peer Review's second read of INV2-COMPAT-001 (thread 77fcbb5a): `altcompat_spec` now asserts
    the wrapper is PRESENT on every loaded record (`Database:HasAltCompat`), not only that
    `alt.items` answers -- an AceDB `faction` default added later would attach its own metatable
    first, the shim would decline, and every answer-only example would still pass on the store's
    empty view. Comments at the two other tables named `alts` (`BankerNumbers:EntriesToAlts`,
    `Guild:GetVersion`'s payload) say they are not `Info.alts`; `Store:GetAltView` documents the
    per-name empty view (bounded, not a leak) and `GetAltSourceRecords` documents returning the
    live bucket.
  - **DS-HOST-001: TOGBankClassic runs on a DeltaSync-1.0 host, and the wire envelope is the
    host's.** Step 2 of the delta release begins. DeltaSync had been a declared dependency that
    nothing called; Core.lua carried its own byte-identical copies of the library's checksum and
    `<AceSerialized>\030<checksum>\031END` envelope -- ~140 lines, the "duplicate envelope code"
    LIBREQ-DS-003 named. Deleted: `Core:DeltaHost()` creates the host (`NewHost`, namespace
    `TOGBankClassic`, TOGBank's own AceComm) once, lazily and again from `OnInitialize` so its
    seven prefixes register at login; `Core:SerializeWithChecksum` / `DeserializeWithChecksum` /
    `Checksum` are one-line delegates. **The bytes did not move, and that is proven rather than
    reasoned:** `Tests/deltahost_spec.lua` pins the envelope for a fixed payload as a literal
    captured from Core's OWN implementation before the delegation and asserted unchanged after
    it -- every peer on every prior version parses this exact framing. The library's P2P module
    is deliberately NOT initialised (per-item hash offers are what banker numbers replaced); the
    numbered handshake stays TOGBank's layer on the host. DEBUG: the host gets a logger, so
    DeltaSync claims no chat tab and does no filtering of its own -- every library line lands in
    `Output:Debug` under a new `DELTASYNC` category (registered in all three registries) with the
    library's own category as the tag and its tag joined on (`COMMS-SEND`), so one toggle gates
    the library and its lines still filter. `PROTOCOL`'s `SERIAL` and `INTEGRITY-MISMATCH` tags
    retire with the code that emitted them; the tester's opt-in integrity chat alert stays in
    Core over the host's CRC verdict. The harness loads the REAL library wherever Core loads
    (`env.standUpClient`, `requestchain_spec`, `syncwire_spec`). 1229/0. NOT RUN IN GAME -- the
    seven extra prefixes against the client's registration cap is the thing to watch
    (`host.prefixRegistrationFailed` is nil offline; DeltaSync prints a red line in game if the
    client refuses one). Locations: `Core.lua`, `Modules/Constants.lua`, `Modules/Database.lua`,
    `Modules/Options.lua`, `Tests/deltahost_spec.lua`, `Tests/env_togbank.lua`.
  - **CHAIN-001: the per-version delta chain -- written first-hand at mint, kept 25 deep per
    banker, proven by the canon.** Step 3 of the delta release begins; the operator's "v2 SHOULD
    be using deltas too". New `Modules/Inventory/Chain.lua` (both TOCs). When `Bank:MintVersion`
    mints a version it now also computes, with DeltaSync's own engine (`ComputeStructuredDelta`,
    `keyFunc = Record.key`, `keyFields = {1, 3, 4}`, `strictKeys`), the delta from the records it
    published last to the ones it is publishing, labels it with the new canon and its PARENT
    canon, and stores it on the V2 SavedVariable as ONE string per banker -- links joined with
    `\029`, fields with `\028`, bytes AceSerializer always escapes, so a split is exact. The window
    is the last 25 versions (Blizzard's per-tab number; a banker is a tab). A first-ever scan has
    no parent and starts the chain at the next version. `Chain:Since(held)` answers the links
    after a held canon, empty for the newest, nil outside the window (= full snapshot);
    `Chain:ApplyAll` applies them in order on a COPY of the held records, checks each link's
    parent connects, and then RECOMPUTES the content hash against the newest link's canon --
    a chain that does not reproduce the author's number is refused whole. **Measured, not
    assumed:** with the canon, parent, empty arrays and zero metadata in the body, one changed
    count serialized to 209 bytes -- larger than a four-row snapshot -- so the body is pruned to
    the `changes` alone (the canon and parent are the link's index fields) and is now under 70.
    `Tests/chain_spec.lua` (27 examples) is section 7 of `docs/DELTA_RELEASE.md`: round-trips
    for count up/down/add/remove, suffix variants, enchants, money-only, empty<->full and
    no-change, all proven by `Verify`; the check shown RED on a corrupted count; no mutation of the
    caller's tuples; the window at 26; one SV string; `Since` on every boundary; a whole chain
    from v1 and from v2 landing on v4; a chain over the wrong base REFUSED (a first fixture
    differed on a row the chain removed, which erased the difference -- the fixture was wrong, the
    check was right, and the spec says so); disconnected links refused; and the mint site itself
    through the real `MintVersion`. NOT YET ON THE WIRE: the sync-request naming the held canon
    and the provider's chain reply are the next increment (3b), on the host's `RequestData` /
    `SendData`. 1254/0. NOT RUN IN GAME. `Store:GuildTable` exposed for the sibling module.
  - **CHAIN-002: the chain on the wire -- the data leg moves onto the DeltaSync host, and it
    sends the delta.** Step 3b. After a sync-accept the requester used to whisper a
    `togbank-state` summary (four hashes and the money) and the provider answered
    `togbank-nochange` or a FULL tuple snapshot on `togbank-d4`; every request that was not a
    no-change re-sent the whole bank. Both halves are gone. New `Modules/Inventory/Sync.lua`
    (both TOCs): `Sync:RequestFrom(peer, alt)` sends the host's QUERY (`host:RequestData`, ALERT
    per P2P-031) with the CANON this client holds for the alt as `baseline.hash` and the alt in
    `baseline.keys.alt` -- nil hash when it holds no canon, no rows for it (a hash-list stub), or
    a forced-full is standing; `Sync:OnDataRequest` answers on the host's RESPONSE channel, decided
    on the canon alone: `inv-nochange` when the requester holds our version OR A NEWER ONE (a
    case the summary could not express), `inv-chain` -- the author's links after the held canon,
    `Chain:Since`, but only when the chain also ENDS at the version we hold (a chain that ends
    earlier describes versions a snapshot has since left) -- otherwise `inv-snapshot`, the same
    `Wire.encode` array `togbank-d4` carries. "v1 is always red": the revision-1 fallback for two
    canon-less copies is gone; a copy with no canon gets the snapshot and the author's canon with
    it. The receiver (`Sync:ReceiveChain`) requires the first link's parent to equal the canon it
    holds, applies the ordering rule (`ShouldApplyTuplePayload`), runs `Chain:ApplyAll` -- the
    result must hash to the newest link's canon -- and on ANY refusal (tampered body, wrong base,
    no held version, malformed links) marks the alt in `Guild.forceFullRequests` (a registry that
    existed and was never written) and fails the session into catch-up, whose next request claims
    no baseline and gets the snapshot. Nothing is applied on trust. Applied links are KEPT
    (`Chain:Append`, new -- `Record` now goes through it) so a relay serves the author's links on,
    byte for byte; a snapshot clears a chain it no longer connects to. ONE STORE-AND-STAMP,
    `Sync:StoreDelivery`, for every delivery -- togbank-d4, `inv-snapshot` and `inv-chain` -- the
    ~200-line block that lived inside Chat.lua's comm handler; the no-change completion is
    `Chat:HandleNoChange`. THE SEND SLOT (P2P-024/028) is released when the reply has DRAINED, not
    when it was queued: DeltaSync exposes no per-send completion (LIBREQ-DS-009 filed to its
    inbox), so Core hands the host a transport PROXY -- `RegisterComm`/`SendCommMessage` forwarded
    to Core unchanged -- that chains the delivery callback and fires a one-shot
    `Core:WatchHostSend(prefix, target, fn)` on the terminal verdict (delivered, refused, or never
    attempted); a send the host refuses before the transport releases at once and withdraws the
    watcher. **Two defects found by the specs while writing this and fixed before it shipped:**
    the proxy's first terminal test ignored a refusal (`delivered == false` with `sent < total`),
    so a refused snapshot would have held its slot for the 210s safety timer; and the host hands
    its callbacks the sender as AceComm spells it -- a BARE name for a same-realm peer -- while
    every P2P record is keyed by `Name-Realm`, so without `Guild:NormalizeName` at the seam a
    same-realm requester's slot leaked AND the state-wait released it a second time (every
    earlier fixture used the full name and could not see it). DELETED: `Guild:ComputeStateSummary`,
    `SendStateSummary`, `RespondToStateSummary` (~250 lines), the `togbank-state` and
    `togbank-nochange` prefixes send and receive (Constants, `COMM_PREFIXES`, the Chat.lua table),
    `SendAltData`'s whisper branch and dead requester parameters (it is the GUILD manual share
    now, built by the one `Sync:SnapshotPayload`). Core's SEND log names the host's seven prefixes
    from the host itself (`(DeltaSync QUERY)`) rather than `(Unknown)`. **Measured:** a one-row
    change against a twenty-row bank is a 299-byte chain reply against a 639-byte snapshot; the
    reply's fixed cost is two canons and the author's stamps, so the ratio grows with the bank.
    `Tests/chainwire_spec.lua` (18 examples): author -> requester -> relay end to end through the
    host's own QUERY/RESPONSE handlers, the stamps verbatim, the session completed, the size; a
    tampered link refused with the forced-full mark and the failed session; wrong base, no held
    version, stale (discarded, NOT failed), a stranger, our own character, malformed links; the
    snapshot on the host and on togbank-d4 through the one path; a two-link run; a provider whose
    chain ends early sending the snapshot. `Tests/statesummary_spec.lua` re-pinned to the new
    seam (19 examples, including the bare-name case). 1280/0; Sync.lua and Chain.lua at 100% line
    coverage. NOT RUN IN GAME -- the thing to watch on first login: the RESPONSE prefix carrying
    BULK snapshots. (The other watch item this entry first named -- a reply addressed to
    `Name-Realm` where the handshake used the bare name -- was removed by the one address rule,
    `Core:WhisperAddress`, below.) KNOWN COST: a v1.4.1 peer's state summary is no
    longer answered; its session times out into catch-up, per the no-wire-back-compat rule
    v1.4.0 set.
  - **LOGWHO-001: the bank log names WHO, derived once by the author and carried in the chain
    link.** Step 4 of the delta release; the operator's log is "like the in game bank log", which
    names the player. A deposit that fills a request is attributed to the requester (`to`), a
    deposit that arrived by mail to its sender (`from`); everything else stays unattributed. The
    AUTHOR derives it at mint (`Log:AttributeChanges`) from the request events it just recorded
    -- `mailed` / `handed` fills, consumed through a weak-keyed `Log.attributed` set so a consumer's
    copy of an entry never carries bookkeeping -- and from the inbox senders the mail scan now
    reports (`MailInventory` returns `senders[itemKey][sender] = count`; `Bank.lastMailSenders`).
    An over-claim (fills adding up to more than the count actually rose) is ignored whole rather
    than trusted in part. `Log:RecordInventoryChange(..., who)` splits one item's change into one
    entry per attribution. The `who` rides INSIDE the chain link's body (`Chain:Record` stores it
    beside the changes; `ApplyAll` hands it back per step), so a viewer applying the chain logs the
    author's rows exactly -- and a chain receive now logs ONE DATED ENTRY PER LINK (`Sync:ReceiveChain`
    stamps each with `CanonPublishTime(link.canon)`) instead of one net diff, with `meta.logged` so
    `StoreDelivery` does not diff it a second time. A snapshot receive still logs the net change at
    the later time, as before. `Tests/logwho_spec.lua` (12 examples): the split, the over-claim, a
    fill for a different item / banker / suffix variant not claimed, the inbox aggregation per item
    AND per sender across mails with COD mail skipped, and the `who` surviving the link body byte
    for byte. `ToTOGToolsRow` does not copy the two fields -- whether TOGTools wants them is that
    repo's question. Locations: `Modules/Log.lua`, `Modules/MailInventory.lua`, `Modules/Bank.lua`,
    `Modules/Inventory/Chain.lua`, `Modules/Inventory/Sync.lua`.
  - **MULTIPC-002: a PC that is behind on its own character fetches the newer version as the DIFF
    BASE before it publishes -- never stored.** Section 3.5 of `docs/DELTA_RELEASE.md`. MULTIPC-001
    held a behind PC's publish until every source was re-read; when it then published, it diffed
    from the version IT last held, so its chain link did not connect to the version the guild holds
    (every viewer fell back to a snapshot) and its log repeated the other PC's moves as its own.
    Now the three paths that learn a peer holds a newer version of our character -- the hash-list
    reply, a broadcast naming our number, and the version reply to our own broadcast's bare offer
    -- record the holder (`Guild:NoteSelfHolder` -> `Bank:NoteNewerSelfVersion`; newest canon wins,
    holders accumulate). When the re-read completes, `Bank:Scan` asks a holder for that version
    through the ordinary handshake (`Bank:RequestDiffBase` -> `P2PSession:DispatchList` for our own
    name; `Sync:RequestFrom` forces full for our own name, since the store already holds this PC's
    fresh read), and `Sync:ReceiveSnapshot` routes the delivery to `Bank:ReceiveDiffBase` while it
    is awaited: KEPT FOR THE DIFF ONLY, never written to the store or the record (a flat copy beside
    freshly read bags is MULTIPC-001's double count), an older copy than the one awaited not taken.
    The deferred publish then mints against it: the link's parent is the guild's canon, the log is
    this PC's own moves. If nobody delivers, the existing 180s fallback publishes WITHOUT a base --
    no link, nothing logged, data exact -- and with no known holder there is nothing to wait for
    and the publish goes ahead against the last-published version as before. ASSUMPTION stated at
    `RequestDiffBase` (peer review F5): the only session ever opened for our own name is this
    fetch. `Tests/multipc_spec.lua` re-pinned (28 examples): the fetch goes to the peer that named
    the version, the base is never stored, the log and link diff from the FETCHED version, the
    fallback, a broadcast's holder preferred when newer, an older delivery refused, the held publish
    kept held, and the no-holder publish.
  - **FULLSYNC-001: a multi-client harness, and fourteen FULL SYNC scenarios end to end.** The
    operator: "you need COMPREHENSIVE end to end testing in the test harness. FULL SYNC, not just
    pieces." `Tests/env_fleet.lua` stands up SEVERAL WHOLE CLIENTS in one Lua state -- each in its
    own global environment with its own LibStub, Ace3, AceCommQueue, LibGuildRoster, DeltaSync host,
    store, roster and P2P state, loaded with `setfenv` from the installed libraries and the real
    `MODULE_ORDER` + `Core.lua` -- talking over a message bus with one clock: WHISPER routes to the
    online client of that name (so two PCs on one character are two clients), GUILD to everyone
    including the sender, the sender delivered BARE as AceComm spells a same-realm peer; per-client
    `C_Timer` re-enters the right client; BULK sends can be held (`F.bulkDrain`) to model a slow
    transport. Seam declared in the header: no chunking, ChatThrottleLib or AceCommQueue timing.
    `Tests/fullsync_spec.lua`, all green: cold viewer with the banker first; viewer first, then
    catch-up convergence through the numbers-table request/reply; a deposit arriving as ONE LINK at
    every viewer (284 bytes against a 562-byte snapshot); fulfilment `to` and mail `from` on every
    client from the author's link alone; a relay serving the chain with the author offline; four
    cold viewers against the three-slot cap, the fourth queued and served after a drain; a version
    outside the 25-deep window served the snapshot; a corrupted relay link refused end to end and
    recovered by snapshot; two banker accounts numbering identically; the manual GUILD share; the
    shared account on two PCs (the diff-base fetch through the own-name handshake, then one link to
    the viewers) and the same with nobody holding it; and an already-current requester answered
    no-change. `F.new` resets every module-level field of the fixture (`bulkDrain` leaked between
    examples until it did).
  - **CHAIN-003: the host's data QUERY is answered only for a requester that holds a send slot.**
    Peer review F2. The three-slot cap is enforced when a sync-request is ACCEPTED; `Sync:OnDataRequest`
    went straight from the sender to `CanServe` and the reply, so a QUERY that never went through
    the handshake was a BULK send outside the cap -- and every release on the way out gave back a
    slot that was never taken, which is why it was silent. Parity with the deleted `togbank-state`
    path, and no defence. `P2PSession:HoldsSendSlot(requester)` is new; a QUERY from a requester
    holding none is ignored and still claimed (`true`: the baseline type is TOGBank's alone, no other
    consumer of the host should answer it). `chainwire_spec` has the negative and its control;
    every provider-side fixture now takes the slot the accept would have. **And one accept is ONE
    reply** (peer review A1): the slot is ACCEPTED then SERVING -- `P2PSession:ClaimSendSlot`
    consumes the accept on the QUERY and the release on drain gives both back -- so a second QUERY
    inside the window before the first reply drains is ignored rather than earning a second BULK
    send for one accept. Counts, not identities: two accepts for one requester are two passes;
    the residual (a state-wait releasing the unclaimed one of two while the other serves) is one
    extra reply, which is what every accept used to allow. Pinned: accept, QUERY, QUERY -> one
    send; drain, accept, QUERY -> a second.
  - **MULTIPC-002 follow-up (peer review A2): the version reply records the HOLDER where the
    version is learned.** `P2PSession:OnVersionReply` raised the tab's newest time for our own
    character from ANY reply naming our number -- a late one after the self query settled, or one
    answering a query about some other banker -- while `Guild:NoteSelfHolder` ran only inside
    `FinishVersionQuery`, which such a reply never reaches. Bank then knew it was behind and knew
    nobody to fetch the diff base from, and the re-read published against its own last version
    (the documented fallthrough, now reachable only by hand). `NoteSelfHolder` moves to
    `OnVersionReply`; the loop in `FinishVersionQuery` goes. `multipc_spec` drives the
    other-banker reply end to end: holder recorded, the full re-read asks that peer for our bank.
  - **Peer review F4 / F6, and a full-suite-only leak.** (F4) `Core:WhisperAddress(target)` is the
    ONE rule for what a directed addon message is addressed to -- bare name for a same-realm target,
    `Name-Realm` for a cross-realm one -- extracted from `SendWhisper` and now used by every directed
    send on the DeltaSync host (`RequestFrom`, the reply, the no-change). Before this the handshake
    was addressed by SendWhisper's rule and the host's reply by the normalized `Name-Realm`, two rules
    that could disagree in game with the very specific symptom "every handshake works, every reply is
    lost"; now they cannot. The send-slot watch keys on the address the transport sees. (F6)
    `Bank:NoteNewerSelfVersion` and `ReceiveDiffBase` compared publish times in their own words;
    both call `Guild:CanonIsNewer` now -- the P2P-034 class, one compare with one spelling.
    (Leak) `env.reset()` now calls the harness's own `wow.reset()` before reinstalling its overlay.
    It used to reinstall only the globals it owns, so anything a spec steered in the harness's
    model survived into every later spec FILE: `mailbox_spec` filled `wow.mail` and only its own
    `load()` cleared it, so in a FULL-SUITE run `multipc_spec`'s "mailbox visited" scans read
    Alice's Linen Cloth x20 and logged three entries where one was expected -- green alone, red in
    the suite, the exact shape the reset rule exists to remove. The harness's reset already wiped
    the inbox; the consumer simply never invoked it (Peer Review's point, checked).
    1312/0; `Sync.lua` and `Chain.lua` at 100% line coverage, every MULTIPC-002 line in `Bank.lua`
    covered; luacheck clean. NOT RUN IN GAME.
  - **Peer review F3 / F7, the last two open from the delta-release review -- both pinned, neither
    a defect.** (F3) The send-slot drain watcher is keyed `prefix|target`, so two replies to ONE
    requester in one frame share a key. Read end to end: `host:SendData` hands the message to the
    transport synchronously inside the call, and the proxy moves the watcher off the table into that
    send's own completion closure before the next `WatchHostSend` can overwrite it -- so each queued
    reply hears exactly its own verdict. `chainwire_spec` (+1) drives two accepts, two QUERYs, two
    queued replies, drained second-first, with a repeated completion in between: each drain releases
    its own slot and only its own. Proven red by moving the lookup to drain time (the first reply's
    slot leaked). (F7) `Tests/fleetreset_spec.lua` (new, 3) enumerates `env_fleet`'s state fields by
    walking the fixture rather than a hand-written list, poisons each with a sentinel, and requires
    `F.new` to clear every one -- a field added later without a reset fails by name (proven red by
    removing the `bulkDrain` reset). 1394/0; luacheck clean.
  - **PERF-022: the tooltip's "Bankers:" block no longer scans every banker's whole bank per
    hover.** Audit finding 13 (2026-08-03), open since: `TooltipBankerInfo` asked each banker "how
    many of X" and `Guild:GetAltItemTotal` answered by walking that banker's entire record set --
    O(bankers x items) on `OnTooltipSetItem`, one of the client's hottest paths; ten bankers at a
    thousand rows is ten thousand iterations per mouseover. The audit's stated hard part was
    INVALIDATION: an index that misses a writer is worse than the scan. So the index lives where the
    writers are: `Store:GetAltItemTotal(guild, alt, itemID)` builds a per-alt `itemID -> count` map
    from the store's own record cache on first ask and drops it in the very same `InvalidateView`
    call that drops the record cache -- every writer of the store already goes through it
    (INV2-ISOLATE-001 pins the writer set at two), so the index can only be stale when the record
    cache the tooltip already trusted is. `GetGuildTotal` and `FindItem` read it too. Step 5 of the
    delta release. `Tests/store_spec.lua` (+5): the total across suffix variants, zero for an unheld
    item or alt, ONE record walk then none (counted, not trusted), a rebuild after `SetAltRecords`,
    `SetAltSources` and `RemoveAlt` each, the global invalidate, and the guild-wide queries.
  - **`Guild:RequestQuantityNeeded(req)` -- one spelling for "units still owed".** Peer review F2,
    step 5. `quantity - fulfilled` was written out at seven sites (Mail x4, ItemHighlight, the
    Requests window's own local and its complete-quantity prompt) and two more tested
    `fulfilled < quantity` for the same question. All nine call the helper, which reads both fields
    as numbers and never answers a negative. It says nothing about status; every caller gates on
    that beside it as before. `Mailbox:WantedByOpenOrders` (a zero quantity counts as wanted) and
    `isComplete` (status short-circuits) keep their own semantics deliberately. `fulfillhint_spec`
    loads the REAL Guild now rather than a stub table, overriding only the roster pieces it pins.
    `Tests/guild_spec.lua` (+4). 1321/0; `Store.lua` at 100%.
  - **SYNCED-001: the banker can see whether the version they just published has reached anyone
    -- on every window's status bar, and at the logout countdown.** The operator, 2026-09-11:
    *"figure out how to ensure the bankers data is being propagated after filling orders, some kind
    of visual to tell the banker not to log off yet, until data is synced"* and *"if we add the
    status bar to all the windows, it will work"*. A banker fills orders, closes the mailbox, the
    scan mints a new version -- and that version lives on their PC alone until a guildmate has
    received it; log off first and the guild keeps showing stock the banker no longer has until
    the next login republishes. New `Modules/Propagation.lua` (both TOCs) tracks the NEWEST
    version of our own bank from the mint (`Bank:MintVersion` -> `Propagation:OnPublished`) and
    counts holders from three things this client can actually observe, never from a broadcast
    going out: a chain or snapshot reply that DRAINED to a named requester (Sync's send watch,
    `delivered`), a requester answered no-change because it already holds it, and a peer NAMING
    our current canon (every such path lands in `Guild:NoteSelfHolder`, which now records a holder
    when the canon EQUALS ours and a newer-version claim when it is newer). `Status()` is `idle` /
    `pending` (nobody has it, someone is online to receive) / `alone` (nobody online can) /
    `synced` (N hold it); a new mint replaces the tracker whole. The banker is told ONCE, in chat,
    when the first guildmate has it ("safe to log off"). **The status bar is on every window now:**
    `StatusBar:AttachSides(window)` gives the Requests, Search, Mailbox and Donations windows the
    same centre/right sections the Inventory window has had (network parts, and the propagation
    line taking the centre -- red "not received by anyone yet -- stay online (N online, m:ss)",
    grey "no guildmate online to receive it", green "received by N guildmates" for 90 s), while each
    window keeps writing its own left-section messages; the ticker arms on show and stops on hide.
    `PLAYER_CAMPING` (the logout countdown; present in Era's and TBC's UIParent) warns in chat while
    pending or alone -- advisory, nothing cancels the logout. Session-scoped, nothing saved: the
    next login republishes regardless. **Look:** every window's title is now `UI:WindowTitle` --
    "TOGBankClassic v1.5.0 - Requests" -- the form the main window has always used. `Tests/
    propagation_spec.lua` (13) pins the tracker's rules and the line; `fullsync_spec` drives four
    whole-fleet scenarios: pending from the mint through the broadcast until the snapshot drains,
    then synced naming the viewer; a new mint resetting it and a CHAIN reply counting; a peer's
    broadcast naming the version counting with no data sent; alone, and the countdown warning in
    each state. **Fixture defect found by that last scenario, fixed:** `env_fleet`'s `F.presence`
    fired `GUILD_ROSTER_UPDATE` and claimed to flip presence -- LibGuildRoster builds its roster
    once and then ignores that event outright; presence is the "has gone offline" system line. Every
    earlier offline scenario passed only because the bus drops sends to an offline client. It sends
    the chat line now, and `F.with` returns what its function returns.
    **Peer review on the first cut (thread c69e9b0f), acted on the same evening:** (B1) "delivered"
    is the transport's verdict, not a receipt -- so the tracker carries TWO counts, **sent** (a reply
    drained) and **seen** (the peer's own message named the version), and only seen turns the line
    green; the line reads amber "sent to N, not confirmed by anyone yet" in between. And since
    nothing on the wire named the version back until the receiver's next login broadcast, there is
    now a RECEIPT: a client that stored a delivery with a canon whispers `sync-done { alt, canon }`
    on the handshake prefix at ALERT (~60 bytes) to whoever served it; `Chat` hands it to the
    tracker as seen. (B2) The narrow-bar rule is state-dependent: while the line is red or amber it
    wins the bar over the window's own left text, which comes back the moment it goes green or
    empty. Pinned in `propagation_spec` and the fleet (both the snapshot and the chain delivery
    earn a `sync-done`).
  - **SEARCH-006: ONE search box on the Requests window, above the dropdowns.** The operator, on
    seeing SEARCH-005's box under each of four columns: *"i don't need a search bar for each area,
    one bar that filters on all columns would work"* -- *"and can you put them above the dropdown,
    not below"*. The second header row is gone; one box sits above the Requester / Bank dropdowns
    and every word typed must appear somewhere across what the Date, Requester, Bank and Item
    columns show (`Requests:SearchMatches`, the library's tokenised rule over the four column
    texts; `#`, Sent and Actions are not searched). `searchText` replaces `columnSearch`;
    `SetSearch` replaces `SetColumnSearch`. `searchbox_spec` re-pinned, including that the source
    builds exactly one box and adds it before the dropdown row.
  - **CANCEL-REASON-001: a cancelled request's date glows so players know to hover for the
    reason.** Discord: *"make some way to show why things were cancelled, folks can't see why
    easily"*; the operator: *"there is info there, it's just not apparent to the users that they
    need to mouse over it ... maybe a background glow or something"* -- and on the first cut (a
    tinted block behind the cell): *"what i meant was a soft glow of the letters/numbers
    themselves"*. The reason stays in the date cell's timeline tooltip; a cancelled request that
    carries one now has a soft glow on the date's LETTERS. Three cuts on screen: a red 1px text
    shadow (*"red on red doesn't work"*), a gold one (*"it's just a 1px 'outline' can we
    actually make it 'glow'?"*), then the real thing -- the client has no text blur, so the glow is
    BUILT from 24 copies of the plain text drawn under the glyphs, three rings at 1/2/3 px in eight
    directions with alpha 0.12/0.06/0.03, so the overlaps stack at the edge and thin to nothing.
    Two things the fourth screenshot settled (*"now that's a cool glow, but i can't read it
    anymore"*): the copies sat on the cell at BACKGROUND sublevel -1 and painted OVER the glyphs
    regardless, so they live on a child frame one FRAME LEVEL below the cell, re-levelled on every
    draw; and the first alphas (0.4/0.2/0.1) stacked to a solid blob that filled the counters of
    the 0s and 8s -- eight copies overlap at the edge, coverage is 1-(1-a)^8, so 0.12 is 64% at
    the edge, not 99%. Colour is WARM CREAM (1, 0.9, 0.7), not gold: gold is red's neighbour and
    merged into the glyphs, a luminous halo is near-white. The glyphs' own black drop-shadow is off
    while glowing (it notched the halo) and put back when a pooled row is reused for an open
    request (`Requests:SetCancelGlow`). And the halo BREATHES -- offered five ways to say "hover
    here" (an (i) icon, a pulse, the reason inline, link-styled date, row highlight); the operator:
    *"oh, i like 2, can we do that? maybe do a 1 afterward, but i want to see how it looks
    first"*. One Alpha animation on the glow frame, 1 -> 0.35 over a second, `BOUNCE` looping,
    `IN_OUT` smoothing -- a two-second breath; the glyphs are not on that frame and hold still.
    Stopped and reset to full alpha when the row is reused, or the next cancelled request in that
    row would start from a dim halo. The (i) icon (`Interface\common\help-i`, verified in the Era
    tree) was offered as a follow-up; the operator on seeing the pulse: *"ok, i like it, we can
    leave it like this"* -- so the icon is NOT built. And it is a SETTING: *"some folks will whine
    about it, we need to add it as a setting to the appearance tab, and have it ON by default.
    folks can turn it off if they want"* -- `Options.db.global.cancelGlow` (account-wide, like
    the window alpha; default `true`), the "Pulsing glow on cancelled requests" toggle on the
    Appearance tab, whose setter repaints the open Requests window so a glow on screen goes out
    at once; `Requests:CancelGlowEnabled` gates `SetCancelGlow`, and answers ON when the options
    DB is absent or predates the key. The help tooltip says what the glow means. Pinned in
    `searchbox_spec`: 24 copies on a frame one level under the cell, colour escapes stripped,
    cream, the alpha ladder, the pulse's shape and that it plays, no texture behind the cell, the
    copies hidden, the pulse stopped at full alpha and the shadow restored on reuse; and the
    switch -- executed through the real `Options:Init` and the registered AceConfig table, not
    grepped: default true, on the appearance group, the setter flips the DB and repaints.
  - **SEARCH-006 follow-ups from the first screenshots:** the box is 220px, not full width
    (*"the search bar doesn't need to be this big, it's a waste of space"*), and its row is now in
    `AdjustTableHeight`'s budget -- left out, the table ran one row past the bottom under the
    status bar (*"things are now overlapping"*).
  - **DEFERRED, stated rather than hidden: hash-offer slimming (rev1 out of the hash-list entry).**
    Listed as the third cleanup of step 5. Read before touching: the revision-1 `hash` is not a
    stray field, it is the `expectedHash` the `alt-request` protocol still runs on -- three
    `BroadcastP2PRequest` callers, two senders, two receive handlers, the stub-seed gate in the HLR
    handler, `HashesAgreeWith`'s revision-1 branch and `NoteAdvertisedHashes`' V1-vs-V2 rule, plus
    the negotiation e2e specs. Every one of those lives in the `togbank-hl` / `-hlr` / `-rr` layer
    that LIBREQ-DS-008 deletes wholesale when TOGBank adopts the library's numbered P2P. Reworking a
    wire protocol that is about to be thrown away, immediately before the first in-game run of this
    release, is the wrong trade; rev1 leaves with that layer.
  - **`CHANGELOG.md` split at the v1.4.1 boundary.** The released v1.4.1 section (653 lines) moved
    whole into `CHANGELOG_ARCHIVE.md`; the live file had 14,000 characters of headroom under the
    120,000 working ceiling and the entry above would have taken most of it.

## [v1.4.1] (2026-09-10) - Collect From The Bank, Banker Numbers, Fast Sync

Two threads in one release. The bank-collect button and three peer-review fixes (namespaced globals,
the performance counters, the bank-bag range) came first. The rest is the sync rework read off two
live clients over one evening: the `<dts><hash>` canon, the five "same hash" gates that each stopped
a resync on its own, the send-slot leak, and then the redesign of the P2P cycle with the operator --
banker numbers, a one-chunk offer, the version query, and every broadcast as an offer.

**Rollout, stated once here and in the player notes:** the numbered broadcast and offer are not
readable by v1.4.0, so a v1.4.0 client stops receiving offers from updated ones (it is told nothing,
not something wrong). Any bank character not scanned since v1.4.0 stays red until its bank is opened
and closed once. The first banker account to log in (already owning a v1.4.0-scanned record) or to
scan (P2P-036) numbers every banker on the roster; everyone else adopts the table from the next
numbered message.

### New Features

- **BANKFILL-001: the fulfil button now also collects from the bank.** Requested from the guild
  (*"automated retrieve items from bank, use a button we click over and over"*) and scoped by the
  operator: *"it pulls from your bags, splits it, then attaches it. i need the same pull/split/put
  back into the bank."*

  **One button, two contexts, because the game will not give you both at once** -- a mailbox is
  never within reach of a bank. With the **bank** open each click pulls what an order still needs
  out of the vault; with the **mailbox** open it fills orders exactly as before. Each bank click
  takes the stack that overshoots the order least, and when it does overshoot it splits the surplus
  straight back into the bank. Bags full, no free bank slot, and nothing left to collect each report
  plainly rather than failing quietly.

  **Bank stock deliberately does NOT make an order look fillable at the mailbox.** The existing
  search decides what to work on while standing at the mailbox, where bank contents are unreachable;
  teaching it about the bank would have made it select orders it cannot fill and skip ones it can --
  a regression dressed as a feature. The bank search is a separate function for that reason.

  One honest limit: **none of this has run in the game client.** The container moves
  (`UseContainerItem`, `SplitContainerItem`, `PickupContainerItem`) are client calls the offline
  suite models rather than executes. The path IS specced -- `Tests/bankcollect_spec.lua`, 49
  examples, see Internal -- after an earlier draft of this entry claimed coverage that did not
  exist and the self-audit corrected it. The self-audit also found and fixed a stuck state in it
  (see below). Locations: `Modules/Mail.lua`, `Modules/Bank.lua`, `Modules/UI/Requests.lua`.

  Two small corrections made while writing that spec: the bank step now refuses a non-banker
  exactly as the mailbox step does (it was safe only because the button is built for bankers --
  the AUDIT-S3/S4 class), and the status message reports the order's TRUE shortfall rather than a
  figure capped at what the bank held, which under-reported "of the N needed" when the bank was
  short. Neither changes what gets pulled.

- **The item-matching rules are now in one place.** The bank source needed the same "is this the
  same item" test the bag search uses, and copying it would have left REQ-001 (id beats name) and
  REQ-003 (suffix siblings differ) as two implementations that must be corrected together.

### Bug Fixes

- **HASH-CANON-005 / TABCOLOUR-002: the V2 canon is now `<dts><hash>` -- one string, the publish time
  readable off its front -- and the Inventory tabs are coloured from it.** Reported live: bankers whose
  data had just arrived stayed red; the operator's own banker was red on its own bank; after fixes the
  tabs still took ~5 minutes to settle. The operator stopped the patching -- *"you're cobbling on
  something that existed. is there a better way to do this?"* -- and then stated the design in two
  sentences: *"v1 is always red, v2 does it by is someone newer"* and *"i wanted the hash to be
  `<dts><hash>` all one long string ... so you COULD read the DTS and do quick/easy comparison
  without having to pull the hash apart."*

  **What was wrong with the old mechanism, and why no patch could fix it.** Red was decided by whether
  the hash a peer last mentioned was *equal* to the one held. Equality cannot tell newer from older
  from garbage, so a copy-of-a-copy or a number an old client minted read as "different" forever; the
  cache it compared against had three writers with three rules (last-writer-wins, newest-by-time-but-
  drops-hashV2, and a login seed); and it only learned anything on the sync cycle's cadence. Three
  real defects were fixed on that path first -- a repaint that only ran when a tab was about to turn
  red and never when data landed; the cache overwrite; and a hash-list reply that **threw** on any
  banker this client had no record for, aborting before its request pass (a fresh or wiped client
  with a banker online errored at login and never asked for anything) -- and they stay fixed. But the
  operator was right that the mechanism itself was the defect.

  **The canon, `Modules/DeltaComms.lua`.** `ComputeCanonHash` returns `string.format("%010d%010d",
  publishTime, contentChecksum)`. The datestamp used to be *mixed into* the checksum, which made every
  publish unique but left nothing able to ask two canons which was newer. Now `canon:sub(1, 10)` is
  the publish time, two canons order as plain strings (later publish sorts higher until the year
  2286), and equality still identifies one exact publish. A **number** in the revision-2 slot is a
  v1.4.0 canon and carries no readable time.

  **No rehydration.** The operator's first reaction was *"fuck, so the v2 data i have now will be old
  again"*. It is not: `DeltaComms:CanonFrom` re-encodes a v1.4.0 numeric canon beside the author's
  publish time into `<dts><number>` -- both inputs are the author's own and the rule is deterministic,
  so every copy of one old publish converges on one string on every client, the author included, with
  no rescan. It runs once on load (`Guild:ReencodeHeldCanons`), on the wire (`Wire.decode`), and on
  every advertised entry (`Guild:CanonicaliseSummary`), and it touches **only the revision-2 slot** --
  a source-scan spec pins that no revision-1 hash is ever fed to it. Rebuilding the content half on
  the receiver was considered and rejected: the author hashes its legacy aggregate and a receiver
  holds the V2 view, which can legitimately differ, so that would be the recompute-on-receipt
  HASH-CANON-001 forbids. A numeric canon with no publish time beside it cannot be placed in time and
  is cleared.

  **The tab rule, `Guild:GetAltStaleness`.** `none` (nothing held), `v1` (no readable canon -- red,
  full stop), `behind` (someone mentioned a canon published later than the one held), `current`.
  `Guild.newestAdvertisedAt[banker]` is the newest publish time anyone has mentioned, read off the
  canon; every hash-list reply, hash-offer **and hash-list broadcast** raises it (never lowers it),
  claims with no readable canon are ignored, claims about our own character are ignored, and each
  raise repaints. It converges on the first message and goes yellow the instant the newer copy lands,
  because delivery stores the author's canon. The tooltip now says which red it is, with both publish
  times when it has them. `IsAltSyncPending` remains the sync layer's question and no longer colours
  anything.

  **The sending side is one string compare.** Answering a broadcast with an offer used to compare the
  sidecar `updatedAt` fields; it is now `mine > theirs` on the two canons, exactly as the operator
  described: *"now when you do a broadcast, super easy to figure out if you should whisper respond or
  not."* KNOWN COST, stated: a copy with no readable canon is never offered as newer -- "v1 is always
  red" applied to the sending side -- so a client holding only revision-1 data no longer relays it.

  **The ordering guard reads the canon too, and no longer defends a stub.** The self-audit found
  `ShouldApplyTuplePayload` still ordering by the sidecar time while everything else read the canon,
  so a sender whose two numbers disagreed would be ordered by one and displayed by the other; it now
  reads the canon's time on both sides and falls back to the sidecar only when there is no canon.
  Pinning that exposed a second edge: a record seeded from a hash-list reply carries the banker's
  canon and **no contents**, and the guard was refusing an older-but-real delivery to protect that
  empty record -- leaving the alt with nothing. Ordering defends content we hold; a stub holds none.
  The spec that covers this had been passing on a module leaked from another spec file in the shared
  Lua state; it now loads what it uses.

  **HASH-CANON-006: a pre-canon copy was never replaced, because four separate "same hash" gates
  each said it was current.** Read off the live guild rather than reasoned: on the banker's account
  Alchemyrcp carried a canon and revision-1 hash `808855588`; on the operator's viewer the copy from
  Sep 5 carried the same `808855588` and **no canon**. The bank had not changed since, so every
  revision-1 comparison said "in sync" and nothing was ever requested; the tab was yellow under the old
  rule and correctly red under the new one, and it could never clear because the client had no way to
  *acquire* a canon. `/togbank share` does not push data -- it advertises, and receivers decide whether
  to ask -- so "he received it" was the Sep-5 copy already matching. The operator's summary, *"V1 IS
  OVERWRITING V2"*, is the same outcome by a different mechanism: V1 was never being replaced.

  The negotiate-down rule was right while a guild ran mixed versions and is exactly wrong now that it
  does not. `HashesAgreeWith` now says **not in sync** when the peer advertises a canon and we hold
  none; the HLR compare's inline revision-1 test, `BroadcastP2PRequest`'s "PERF-005" skip and
  `FastFillMissingAlts`'s inline check -- three more spellings of the same decision, each of which
  would have swallowed the request on its own -- all defer to that one comparison, and the canon
  travels through `BroadcastP2PRequest` so the skip can see it. The e2e negotiation spec's two
  examples that pinned mixed-version agreement now assert the opposite, with the old assertion kept
  in the message; `Tests/tabstaleness_spec.lua` reproduces the Alchemyrcp state through the real
  hash-list path and asserts a request goes out. Reverting the one comparison turns exactly those
  three red.

  **The transport, hop by hop, because the operator asked for it end to end.** `Wire.encode` carries
  the canon as a string and never through `tonumber` (twenty digits would lose their low digits as a
  float); `Wire.decode` accepts a string canon, re-encodes a numeric one beside its time (**this
  claim was false when first written -- see HASH-CANON-008 below**), and drops
  garbage; `HashesAgreeWith` normalises both sides before comparing, so an old-encoding and a
  new-encoding copy of the same publish agree; the HLR stub seed, the cache writer, the offer path
  and the login seed all carry the canonicalised string. Every writer of `alt.inventoryHashV2` --
  there are five -- now produces a string or nil.

  **Specs.** `Tests/tabstaleness_spec.lua` (29 examples: the rule in isolation, every writer through
  the real receive paths, delivery clearing it, delivery of an *older* copy not clearing it, the
  offer decision); `Tests/inventoryhash_spec.lua` (the canon's shape, ordering, `CanonPublishTime`,
  `CanonFrom` over every input class, and the revision-1-never-re-encoded scan);
  `Tests/inventoryordering_spec.lua` (the canon crosses the wire byte for byte, and the three ways a
  bad revision-2 slot is handled); `Tests/hashagree_spec.lua` (old and new encodings of one publish
  agree; two unreadable numbers fall back to revision 1); `Tests/hashcache_spec.lua` (a v1.4.0 peer's
  numeric canon is re-encoded at the door; load-time re-encoding counts and clears). Red-proofs:
  reverting the canon format alone turns **13 examples red across five files**; reverting "v1 is
  always red" turns 3 red; reverting the string compare turns 2 red. `env.canon(dts, checksum)` is the
  one spelling a fixture uses. Locations: `Modules/DeltaComms.lua`, `Modules/Guild.lua`,
  `Modules/Chat.lua`, `Modules/P2PSession.lua`, `Modules/Inventory/Wire.lua`, `Modules/UI/Inventory.lua`.

  **HASH-CANON-008: the decoder dropped an old-build numeric canon although its publish time was the
  next field.** The paragraph above said `Wire.decode` re-encodes a numeric canon beside its time. It
  did not: `decodeV2` called `canonOrNil(payload[6])` without `payload[7]`, so `CanonFrom` had no
  time to lead with and returned nil. The spec that "covered" it built the payload through *this
  build's* `Wire.encode`, which re-encodes before the wire, so the decoder never saw a number. Read
  off the operator's viewer account: three bankers scanned that afternoon on the previous build --
  Elementals, Bsrecipe, Cardsngames -- held with the author's tuples, the author's exact publish
  time, and **no canon**, painting "v1". The publish time now goes in beside the canon on decode as
  it does on encode, and `Tests/inventoryordering_spec.lua` drives a **raw** old-build payload rather
  than one this build encoded. Location: `Modules/Inventory/Wire.lua`.

  **HASH-CANON-009: a canon was advertised that nobody could deliver.** Read off the operator's
  banker account after the re-encode: 36 records carried a revision-2 canon and **10** had tuple
  data in the V2 store -- v1.4.0's scan stamped both revisions whatever the switch said, so the other
  26 were revision-1 data wearing a canon. Every advertiser (the hash-list reply, both offer
  emitters, the version broadcast) read `alt.inventoryHashV2` straight off the record, so a viewer was
  told "a newer version exists", requested it, and the responder's `SendAltData` -- tuples from the V2
  store or nothing -- found no records and sent nothing: a request wasted every cycle and a tab on
  red for a version nobody could ship. `Guild:ServableCanon(norm)` is now the one spelling of "the
  canon I can serve" (nil unless the V2 store holds records for the alt) and all four advertisers
  read it. The relay responder on `togbank-r` answers only when it can serve too -- the Alchemyrcp
  shape again: a peer holding the Sep-5 copy (same revision-1 hash, no canon) would have won the race
  to answer and shipped tuples with no canon, leaving the requester on "v1" having been "answered".
  A banker still answers from its own record. `Tests/servablecanon_spec.lua` (12 examples: the
  predicate, both advertisers, the relay through the real `togbank-r` path with a positive control)
  and one new example in `Tests/tabstaleness_spec.lua`, whose offer fixtures now hold tuple records
  because an offer without them is the defect. Locations: `Modules/Guild.lua`, `Modules/Chat.lua`.

  **HASH-CANON-010: the FIFTH "same hash" gate, on the responder, and the one HASH-CANON-006 could
  not reach.** Read off Galdof's live log after the other four were fixed: Galdof requested
  Alchemyrcp (so the fix worked), Alchemy ACKed, Galdof whispered its state summary -- revision-1
  `808855588`, no canon -- and Alchemy answered `togbank-nochange`, because `RespondToStateSummary`
  compared revision 1 and the contents had not changed since Sep 5; only the canon had. "Answered",
  and still no canon. The state summary now carries the requester's canon (`hashV2`, nil when it
  holds none, forced nil on a full request), and the responder decides "do they already hold my
  version?" through `HashesAgreeWith` with the seats swapped -- the requester's summary as the held
  record, our record as the advertisement -- so a canon on our side and none on theirs is a send, and
  two canon-less copies still agree on revision 1. The "mail-only" and "inventory changed" branches
  that stood there called `SendAltData` identically and are one branch now.
  `Tests/statesummary_spec.lua` (Alchemyrcp's exact summary is sent the data; same canon is
  no-change; older canon, forced-full and mail-only are sent; canon-less pair falls back to
  revision 1; the summary carries the canon and drops it on forced-full). `syncwire_spec`'s
  no-change fixture now holds the responder's canon, because a canon-less requester earning a
  no-change was the defect. Location: `Modules/Guild.lua`.

  **HASH-CANON-011: a banker's broadcast did not feed the advertised-hash cache.** The operator,
  watching `/togbank share` from the banker: *"I should be getting the new hash from the broadcast at
  least."* The broadcast handler raised the tab's newest-time and never called `NoteAdvertisedHashes`
  -- only the hash-list reply and the offer path did -- so `hashdump` read `known=-` for a canon the
  whole guild had just heard, and `IsAltSyncPending` / catch-up could not see it either. The comment
  at the end of that handler had claimed the cache was updated there since PERF-020. It is now,
  through the one writer, so a revision-1-only broadcast still cannot displace a held V2 entry.
  Location: `Modules/Chat.lua`.

  **HASH-CANON-012: a banker never offered its OWN bank in answer to a broadcast.** Found by
  reading the offer loop while chasing a `known=-` that turned out to have a simpler cause -- the
  banker was not logged in -- so this one is established by the code and its specs, not by a live
  observation. The offer loop in `ProcessQueuedHashBroadcasts` skipped `norm == myPlayer` -- correct for the three `NoteAdvertised*` calls,
  which must refuse a peer's claim about our own bank (rule 1), but the same skip stopped us
  *offering* it, and Alchemyrcp's V2 data existed on exactly one client: Alchemyrcp's own. The only
  way a viewer ever got it was a direct hash-list request, which picks one online banker at random.
  The offer compare now runs for self on both emitters (the proactive one too, so a wiped viewer's
  empty list is answered by the author); the `NoteAdvertised*` calls keep their own self-guards, asserted in the
  same example. Three examples in `Tests/tabstaleness_spec.lua`. Location: `Modules/Chat.lua`.

  **P2P-028: the send-slot leak -- the whisper storm, and why the one client holding a bank could
  not hand it over.** Read off two live clients thirty seconds after a share: the banker answered
  dozens of sync-requests with short `togbank-rr` replies, received not one state summary and sent
  not one payload; the viewer's log was the mirror image. `HandleSyncRequest` (and the relay ACK
  on `togbank-r`) take one of THREE send slots on accept, and the only release was `SendAltData`'s
  chunk-complete callback -- so every accept that ended in a no-change, a "no data" early return,
  a nothing-to-send, or a requester that never followed up held its slot for the 210-second safety
  timer. Three leaked accepts and the banker is "busy" to everyone; every requester retries; the
  retries leak more. Now every terminal outcome in `RespondToStateSummary` and `SendAltData`
  releases, and an accept arms a 30-second wait for the requester's summary that releases if none
  comes (cancelled the moment it does). Five examples across `Tests/p2psession_spec.lua` and
  `Tests/statesummary_spec.lua`, including the two-in-flight case so the wait cannot free the
  other send's slot. Locations: `Modules/P2PSession.lua`, `Modules/Guild.lua`, `Modules/Chat.lua`.

  **CONFIRMED LIVE, 2026-09-10 ~21:20:** with everything above loaded on both clients, Alchemyrcp
  arrived on the viewer and every V2 bank's tab went yellow in one pass -- the operator's screenshot
  shows the nine V2 banks yellow and the rest red, exactly "v1 is always red". The three changes
  below were built after that observation, from what the same session's logs showed about speed.

  **P2P-032: offers are filtered and ordered by canon.** Read off the viewer's
  `/togbank dev sendqueue`: three fetch slots busy with old-build relays' offers -- one of them for
  a bank the viewer already held current (the peer answered no-change) -- and 23 banks queued behind
  them, the one that mattered included. Old-build peers offer everything whose revision-1 hash
  differs, and `OnOffer` accepted every offer unread. Now an offer enters the collect window only if
  we hold nothing for the alt, or it carries a canon newer than ours (a canon-less offer for a bank
  we hold is revision-1 data and cannot improve anything); at dispatch, alts with a canon-bearing
  offer go first and the canon-bearing peer is preferred over a relay with a newer sidecar time.
  Four examples in `Tests/p2psession_spec.lua`. Location: `Modules/P2PSession.lua`.

  **P2P-033: fetches run in parallel across peers.** The operator: *"why don't we introduce
  parallel processing."* The requester held every fetch behind a global cap of three -- the same
  arbitrary number as the sender's, on the other side. A fetch costs the requester ~300 bytes; the
  payload is the sender's bandwidth, and every sender serialises its own sends. The only cap now is
  **one session in flight per peer** -- a second request to one peer would only sit in that peer's
  queue while other peers stand idle -- and an alt whose peers are all busy with us waits and is
  retried as sessions complete. Two examples (six peers dispatch at once; a second alt for one peer
  waits and goes out on completion). Location: `Modules/P2PSession.lua`.

  **P2P-035: banker NUMBERS, a tiny offer, and every broadcast is an offer.** Designed with the
  operator on 2026-09-10 after Leatherrcp took ten minutes to cross a loaded banker's NORMAL lane;
  their words are quoted at the top of `Modules/BankerNumbers.lua` and recorded as directives.
  Every banker has a four-digit NUMBER, `0001`..`9999`, issued once and for life (a banker that
  leaves keeps it; one that returns has the same one; `next` only rises). It is minted by the ADDON,
  never typed: any account that OWNS a banker -- a record carrying `inventoryContentHash`, which
  only a local scan writes and which never travels -- numbers every unnumbered banker on the roster
  in alphabetical order from `next`, so two banker accounts minting at once from the same roster
  produce the identical table and "only one online" never has to be true. The table lives on the
  existing togbank roster (`Info.roster.numbers`, `numbersNext`, `numbersVersion`) and is 100%
  synced: the version rides in every numbered message, a client behind it whispers the sender once
  for the table (`numbers-request` / `numbers-reply`), and a same-version conflict goes to the
  lower-sorting sender with the loser re-minting its stragglers under a higher version. KNOWN COST,
  stated: in the seconds between two independent first mints a number can name two bankers on two
  clients; it self-heals on the first exchange and cannot recur once a table has been adopted.
  `/togbank roster` prints the number beside each banker and the table version.

  ON THE WIRE, fixed width, digits only, no separators: a broadcast (`hlb2`) is a run of
  `<number><canon>` entries, 24 characters each, for every banker we hold a number and a servable
  canon for -- ~900 bytes for 38 bankers, 4 chunks, where the keyed table was ~5 KB / 20 chunks on
  the guild channel from every member every login and every ten minutes. An offer (`hash-offer2`)
  is `<header><0001><0004>...` -- BARE NUMBERS, "hashless and TINY": 13 bankers is 52 bytes and it
  is one chunk however many are newer. Both carry the table version. Entries whose number this
  client cannot name are skipped and trigger the table request; a torn string decodes to nothing,
  never to a prefix.

  THE VERSION QUERY. A bare offer says WHO, not WHAT, so before asking anyone for data the requester
  whispers up to five of the offerers -- the banker itself first -- "what version do you hold for
  `0001`" (`ver-query` / `ver-reply` on `togbank-rr` at ALERT, 24 characters per answer), waits up
  to five seconds (the author answering ends the wait; so does every asked peer answering), judges
  the answers by the one rule (`AdvertisedImproves`), keeps the holders of the NEWEST version (the
  author wins a tie), and asks one of them -- the sync-request now NAMES the version, and a peer
  that no longer serves that exact version answers `sync-busy` (reason `version`) so the requester
  moves to the next holder. A peer that never answers is never asked for data. When the author is
  already among the candidates with its canon, nothing anyone else says can beat it, so the alt is
  dispatched at once and the version-less candidates dropped rather than asked.

  EVERY BROADCAST IS AN OFFER (the operator: "OH YES!"). A broadcast names the versions its sender
  can deliver, so hearing anyone advertise a version newer than ours is that peer saying "I hold
  newer"; the receive path feeds it to `OnOffer` with the canon attached, and it dispatches (inside
  a window: accumulates; outside one: at once, P2P-034) with no query and no wait for our own next
  broadcast. A banker's post-scan broadcast now fetches within seconds -- the Leatherrcp case.

  Peer Review F1 folded in: `Guild:CanServe(norm)` -- tuple records in the V2 store, exactly
  `SendAltData`'s own condition -- is the sync-request and queue gate, replacing `HasAltContent`
  (true for legacy-only content the send could not ship, costing the requester its 180-second
  watchdog); `ServableCanon` is `CanServe` plus a canon. The offer emitter's "is mine newer"
  compares publish times, the same compare as the receiving side (it compared whole strings).

  **CONFIRMED LIVE, 2026-09-10 ~23:00:** Metals' bank was opened on the banker account at
  23:00:05 and the viewer held and re-offered that exact version within the same minute -- the
  banker's post-scan broadcast fetched as an offer, no window, no wait. A peer's numbered broadcast
  decoded with versions on the viewer (the table had synced). Offers measured at 97-118 bytes, one
  chunk. The operator: "wow, it synced already!"

  **Self-audit, same session:** `/togbank dev hashdump` still judged OK/MISMATCH with
  `HashesAgreeWith` after P2P-034 moved the request rule to `AdvertisedImproves` -- a diagnostic
  disagreeing with what it diagnoses, and under P2P-035 it would have printed MISMATCH for every
  entry learned from a numbered broadcast (no mail hash; fails closed). Verdict is now
  `AdvertisedImproves`, pinned by an example that reddens under the old verdict. A peer that once
  answered a version query with "nothing" was never asked again on a later bare re-offer until the
  next window; it is now. `Guild:CanonIsNewer` is the ONE publish-time compare behind the offer
  emitter and `AdvertisedImproves` (they had two spellings). `Guild:CanServe` (Peer Review F1)
  as above.

  NOT DONE HERE, deliberately: Path B (`hash-list-request` -> keyed `hash-list-reply` -> guild
  `alt-request`) still speaks the keyed table and the revision-1 hash, per the directive to keep
  both paths; the state-summary round-trip is now redundant for a versioned request and is the next
  change. The keyed `hash-list-broadcast` / `hash-offer` RECEIVE branches remain (the decoded
  numbered forms feed the same code), the SEND side emits only the numbered forms -- no wire
  back-compat. Thirty-six new examples: `Tests/bankernumbers_spec.lua` (minting, for-life, adopt
  rules and tie-break, sync, the fixed-width wire, and the whole thing through the real receive
  paths including broadcast-as-offer and the emitted broadcast), the version query in
  `Tests/p2psession_spec.lua`, and the number-only offer in `Tests/tabstaleness_spec.lua`.
  Locations: `Modules/BankerNumbers.lua` (new, both TOCs), `Modules/Guild.lua`,
  `Modules/P2PSession.lua`, `Modules/Chat.lua`, `Modules/Events.lua`, `Modules/Constants.lua`.

  **What has and has not been seen live**, so the next reader does not take the suite for the
  client: the first banker account minted all 38 numbers on login and the viewer account held the
  identical table and version after one broadcast; numbered broadcasts decoded with versions on both
  sides; offers measured at 97-118 bytes, one chunk; broadcast-as-offer fetched a fresh scan within
  the minute (below). **Not yet observed live:** the `ver-query` / `ver-reply` exchange -- every
  live fetch so far arrived via broadcast-as-offer with the canon attached, so no query was needed
  -- and two banker accounts minting concurrently, which is unit-specced (adopt tie-break, re-mint)
  but has not been driven as two clients.

  **P2P-036: a brand-new bank account's first scan numbers the roster.** Minting ran only in
  `RebuildBankerRoster`, and an account owns nothing until its first scan writes
  `inventoryContentHash` -- so a banker set up from the help instructions (open and close the bank,
  then `/togbank roster`) showed no number, and its own post-scan broadcast left it out, until the
  next login. `Bank:Scan` now mints right after it stores the record; a no-op once numbered.
  `BankerNumbers:CanMint` walks `GetBanks()` rather than every alt through `IsBank` -- the same
  answer, one roster method instead of two, and the one `Bank:Scan`'s callers already carry. One
  new example on a whole client in `Tests/bankernumbers_spec.lua`. Locations: `Modules/Bank.lua`,
  `Modules/BankerNumbers.lua`.

  **DOC-004 again, in the client this time:** the `/togbank share` help text and the in-game setup
  instructions said the share ran "every 3 minutes"; it is `TIMER_INTERVALS.VERSION_BROADCAST`,
  ten minutes, and after every bank scan. The setup steps now say the bank close shares at once and
  that `/togbank roster` should show the new banker with a number. Location: `Modules/Chat.lua`.

  **Three wording defects from Peer Review, fixed:** the P2P request timeout log said "(no banker
  online)" whenever no banker was named on the request, which the fast-fill and no-banker callers
  always do -- it claimed a fact the code had not established, with the banker online; it says only
  what is known (F3, `Modules/Guild.lua`). The relay-skip log said "no content" when the gate is
  `ServableCanon`, sending a reader to the wrong condition (F4, `Modules/Chat.lua`). And the
  broadcast-as-offer path wrote the advertised-hash cache twice -- once in the receive handler and
  again inside `OnOffer` -- so the summary now carries `cachedByBroadcast` and `OnOffer` skips its
  write (F2, `Modules/Chat.lua`, `Modules/P2PSession.lua`).

  **P2P-034: one request rule, and a late offer is acted on.** Read off the viewer at 21:30 with
  P2P-031/032/033 loaded on both clients: seven banks arrived and went yellow in one pass, and the
  one that did not, Leatherrcp, showed two things. `OnOffer from Leatherrcp ignored (not
  collecting)` -- the banker's offer for it, whispered behind the three payloads it was serving,
  landed after the viewer's 60-second window and was thrown away. And 26 `No P2P response ...
  after 5s timeout` lines from ONE hash-list reply, Togweapons and Toglowweap among them -- banks
  the viewer held with the author's canon -- because the reply compare asked `HashesAgreeWith`
  ("the same version?") and requested on any difference, older canons and canon-less revision-1
  copies included; the offer path had asked the publish-time question since P2P-032. Two spellings
  of "can this claim improve my copy?", and the second one was the guild traffic P2P exists to
  remove. Now: **`Guild:AdvertisedImproves`** is the one answer -- hold nothing -> yes (if the claim
  carries anything); claim has no canon -> no; we hold no canon -> yes; both -> only a LATER publish
  time, read off the canon -- and `P2PSession:OfferIsUseful`, the hash-list compare, `IsAltSyncPending`
  (catch-up) and `BroadcastP2PRequest`'s guard all call it. Mail needs no clause: a mail scan changes
  `alt.items`, so the canon moves with it. And an offer arriving outside a window is judged by the
  same rule and, if useful, dispatched at once through `DispatchList` (one-per-peer still holds; a
  busy peer parks it). `HashesAgreeWith` is unchanged; it still answers "same version?" where that
  is the question. Three examples that used to pin the defects were rewritten to the rule --
  "ignores offers when no window is open" and "is pending on a hash mismatch" among them -- and
  thirteen added across `Tests/p2psession_spec.lua` and `Tests/hashcache_spec.lua`, three of them
  through the real `togbank-hlr` receive path counting guild broadcasts. Locations:
  `Modules/Guild.lua`, `Modules/P2PSession.lua`, `Modules/Chat.lua`.

  **HASH-CANON-013: a canon mangled through a number is not a version.** Read off the banker's
  log: `theirs=17890060850786974720` advertised for a real canon ending `...974116`. A peer on the
  previous release put the 20-digit string through `tonumber`, lost the low digits to a float, and
  re-advertised the float; re-encoding it produced a canon with the right date and a wrong checksum,
  unequal to the real one forever. A genuine v1.4.0 canon is `Core:Checksum` output, below 2^31
  (`% 2147483647`); `CanonFrom` now refuses anything larger. Finding the bound also found that
  `string.format("%d")` wraps negative above 2^31 in this Lua, which the spec records. Location:
  `Modules/DeltaComms.lua`.

  **The manual `/togbank sync` broadcast moved from ALERT to NORMAL** so the ALERT lane carries
  handshakes only (the operator: *"you can move it and we can test it"*). Location: `Modules/Chat.lua`.

  **P2P-031: every handshake whisper goes out at ALERT.** The operator, on Path B's 5-second
  timeout firing with the banker online: *"why don't we just make ack's a priority? it's a whisper,
  super fast."* All ten `togbank-rr` control messages (request, accept, queued, cancel, busy, and
  both alt-request ACKs) were NORMAL -- the same lane as the kilobyte offers and state summaries
  every client sprays -- and ChatThrottleLib splits its budget equally between lanes with
  something to send, so a 100-byte ACK could sit behind seconds of NORMAL. The ALERT lane is
  otherwise near-empty. They are still whispers; only the lane changed. Locations:
  `Modules/P2PSession.lua`, `Modules/Chat.lua`.

  **Self-audit, same session:** the 30-second state-wait was keyed by requester alone, so two
  accepts to one requester cancelled each other's wait; keyed by requester and alt now, one new
  example in `Tests/p2psession_spec.lua`.

  **P2P-029: at capacity, QUEUE -- never refuse.** The operator, on the cap P2P-028 exposed:
  *"that 3 was an arbitrary number ... make it so it 'buffers' all requests and then has only 3
  open responses, so nothing gets dropped"* -- and on why it was there: *"to force the P2P in a busy
  guild, so one player wasn't getting hammered."* Both hold. A sync-request past the cap is queued
  (FIFO; a repeat from the same requester refreshes its entry in place) and answered `sync-queued`
  with its position; every freed slot accepts the next live entry; an entry older than three
  minutes is dropped when it comes up. On the requester, `sync-queued` with another untried peer
  holding the bank sends `sync-cancel` and moves on -- so load still spreads -- and with nobody else
  to ask it holds the session open for the queue's lifetime instead of the 15-second ACK timeout,
  so the later accept lands on a live session. `sync-busy` now means only "I do not have it". Two
  new `togbank-rr` types, no new prefix. Six examples in `Tests/p2psession_spec.lua`. Locations:
  `Modules/P2PSession.lua`, `Modules/Chat.lua`.

  **`/togbank dev sendqueue`** (the operator: *"put a / command in so we can see the queue data"*):
  slots in use and who holds them (marked when we are still waiting on their summary), the queue
  with each waiter's position and age, and our own fetch sessions with state, peer and candidate
  count. Documented in `docs/DEV_COMMANDS.md`; driven through `ChatCommand` in `Tests/hashdump_spec.lua`.

  **P2P-030: state summaries were 6.5 KB of nothing.** Read off the viewer's log: every
  `togbank-state` carried the alt's bank, bags and mail item lists as a "delta baseline" for a
  `ComputeDelta` that INV2 step 10 deleted -- `SendAltData`'s `requesterBaseline` had been
  luacheck-ignored since. Every request in the guild paid six kilobytes to carry a table nothing
  read. The summary is the four identity fields and money, ~200 bytes. Location: `Modules/Guild.lua`.

  **Diagnosability, same session:** the per-bank offer decision (`mine=… theirs=… -> OFFER/skip`)
  is logged under `P2P/OFFER` -- it was not logged at all -- and the tuple send and store lines
  under `DELTA` now print the canon.

  **HASH-CANON-007: `/togbank dev hashdump` did not show the canon.** The operator, with a banker just
  re-published: *"is there a / command i can use to see if he did?"* There was not -- the one command
  for this printed only the revision-1 numbers after the canon had become the field that decides
  every verdict. It now prints, per banker, the tab state and the held and known canons with the
  publish time as a date, the revision-1 and mail hashes on a second line; a missing canon reads `-`
  and a v1.4.0 number is shown as the bare number rather than given an invented date.
  `Tests/hashdump_spec.lua` drives it through `ChatCommand`. Location: `Modules/Chat.lua`.

- **BANKFILL-002 (self-audit, same session): the bank-collect "return the surplus" phase could
  strand.** That phase can only be left by finding the pulled stack in bags. Walk away from the bank
  with it armed -- then use, mail or bank the item -- and every later click at any bank answered
  *"waiting for the stack to reach your bags"* and never collected anything. Closing the bank now
  clears the state (the mailbox side already did this on `MAIL_CLOSED`), and the phase gives up
  after three empty looks rather than waiting forever. Location: `Modules/Events.lua`,
  `Modules/Mail.lua`.

- **TOOLTIP-002 (reported from a live guild): the item tooltip listed characters who are no longer
  bankers.** Reporter's words: *"if I mouse-over an item that said banker used to have, the tooltip
  says they have it. They do not have gbank in their note"* -- and it survived a reload, which is
  the detail that rules out a stale cache and points at the real cause.

  `Guild.Info.alts` is **stored data, not a roster**. Removing `gbank` from someone's note stops
  them being a banker, but their last-synced inventory stays in the database indefinitely -- and
  should, so re-adding the note does not force a resync. `Modules/TooltipBankerInfo.lua` iterated
  that table gated only on `IsInCurrentGuildRoster` (still in the guild), never asking whether they
  were still a banker, so it reported them forever.

  **Why the Inventory window was right while this was wrong** -- the reporter confirmed the list
  behaves: `UI/Inventory.lua` iterates `Guild:GetRosterAlts()` (the banker roster) and *then* looks
  each name up in `info.alts`. It iterates the roster and reads the data; the tooltip iterated the
  data and never consulted the roster. One concept, two spellings -- and this was the only
  "who holds this item" surface on the wrong side of it, out of ~40 `IsBank` call sites.

  The gate is `IsBank` alone, deliberately **not** `IsBank and not IsViewOnlyBank`: VIEWBANK-001
  makes a view-only banker visible everywhere and merely not requestable, so their stock belongs in
  the tooltip. A spec pins that, so a later "tightening" cannot quietly remove them.

  **The fixture was corrected mid-fix and it matters:** the first version left `memberRoster` empty
  and drove `IsBank`'s legacy `GetGuildRosterInfo` fallback -- passing while never exercising the
  path the addon runs, since v1.4.0 takes the roster from **LibGuildRoster**. The specs now build it
  through the library and assert it produced members before trusting any answer. Both regression
  examples proven red.

- **NS-001 (HIGH, confirmed live, realised cost): another installed addon was overwriting this
  addon's debug categories, so `/togbank debug BANK` answered "Unknown debug category".** The
  command offered `AUTOJOIN, BROWSE, CREATE, MANAGE, SEARCH` and six others -- a group-finder
  addon's set -- while `BANK` sat defined in `Modules/Constants.lua` the whole time. The realised
  cost is the sharp part: the operator could not enable the `BANK` category to diagnose a live
  INV2 divergence, which is the exact diagnostic `DEV-UX-001` exists to make reachable.

  **Cause, named rather than inferred:** `Grouper/GrouperOutput.lua:16` declares `DEBUG_CATEGORY`
  as a bare global and `:7` declares `LOG_LEVEL`. Bare globals share ONE namespace across every
  addon installed, and last writer wins. `LOG_LEVEL` collided too and was harmless **only by
  coincidence** -- both tables happened to be byte-identical (`DEBUG = 1 .. RESPONSE = 5`) with
  nothing enforcing it, so either side renumbering would silently have changed the other addon's
  log filtering with no error anywhere.

  **The harm ran both ways**, which is why the remedy is not "declare ours later" -- this addon was
  equally clobbering Grouper. `Modules/Constants.lua` now publishes exactly ONE global,
  `TOGBankClassic_Constants`, with its eleven tables as file-scope locals; each consumer takes a
  local alias, and a local shadows any foreign global of the same name. `Guild.lua`'s bare
  `GetPlayerWithNormalizedRealm` -- generic enough that a collision would silently change how every
  player name is normalised -- moved onto the module table the same way.

  **Two guards, both proven red rather than assumed:** `Tests/constants_spec.lua` asserts none of
  the twelve names is a global after load, and `.luacheckrc` no longer lists them, so a stray bare
  `DEBUG_CATEGORY` is an undefined-variable warning instead of a silent read of another addon's
  table. The first red-proof was itself wrong -- `PROTOCOL = PROTOCOL` inside the file assigns the
  *local*, so the mutation was a no-op and the guard "passed" against it. A guard that passes
  against a broken mutation proves nothing.

- **PERF-013: the performance subsystem measured a code path that no longer exists and
  structurally could not measure the one that replaced it. Both halves failed silently.** 17 of the
  21 declared counters had no site that could ever record them -- 13 already dead, four killed by
  INV2 step 10, which deleted the functions and left the counters.

  **Where they actually leaked, checked rather than inherited from the report:** `PrintReport` does
  **not** print them (`if data.count > 0` skips a zero row), so the peer-review claim that
  `ComputeDelta: 0` reached chat every session is wrong and is not repeated here. What carried them
  is the `TOGBankClassic_PerfMetrics` SavedVariable and `GetCurrentStats`, which hands every declared
  key to its caller as a zero indistinguishable from "it ran and cost nothing".

  **The second half is the one with teeth.** The declared key doubled as an ALLOW-LIST, so a name
  not already in the table was silently dropped -- no count, no warning, no row explaining the
  absence, which is why the V2 tuple path could not be instrumented at all. An unknown name now
  creates its key; a typo'd name yields a spurious row instead of nothing, and a visible wrong row
  gets noticed while a measurement that never happens does not.

  `Modules/Performance.lua` had **no spec at all**; `Tests/performance_spec.lua` is new and covers
  both halves plus `Track`, `GetCurrentStats` and the profiling-off paths. Its class guard fails
  when a counter is declared that nothing records -- the check that would have caught all 17 -- and
  carries an anti-vacuous assertion. Both guards proven red by mutation.

- **BANKSLOT-001, second half: the two SCAN paths still hardcoded the bank-bag range, and one more
  literal turned up that nobody had counted.** `ItemHighlight.lua` was fixed on 2026-09-09 to read
  the geometry from the client; `Modules/Bank.lua` and `Modules/Inventory/Scan.lua` were knowingly
  left at `for bag = 5, 11` on the reasoning that they were **identically** wrong and so could not
  produce a legacy-vs-V2 divergence.

  **That reasoning holds only while both stay wrong together**, which makes it a trap for whoever
  fixes one file: the two scans would then walk different ranges and `/togbank dev compare` would
  report a divergence that is an artefact of the fix, with the addon's own comparison tool doing the
  lying. Both changed in one edit, using Blizzard's expression from `BankFrame.lua:245`
  (`NUM_BAG_SLOTS+1 .. NUM_BAG_SLOTS+NUM_BANKBAGSLOTS`, which is 5..10 on Classic Era).

  **The guard then found four more sites on its first run** -- `for bag = 0, 4`, the *carried* bag
  range, three times in `Bank.lua` and once in `ItemHighlight.lua`. Same class, on nobody's list.
  Neither range overran harmfully on Era, so the real cost is that a hardcoded end is wrong for any
  flavour whose count differs, and **too few silently drops a whole bag from every scan with nothing
  reporting it.** This addon ships Era and TBC from one source.

  `Inventory/Scan.lua` reads the constants at **call** time: they are engine-side globals an addon
  file can load before, so a file-scope capture would latch the fallback for the session and behave
  exactly like the hardcode it replaces, with nothing to show it had happened.

### Internal

- **AUDIT-S3 / AUDIT-S4: two public functions were safe only because of their single caller.**
  Peer review filed both in one session and named the class: *an invariant enforced at the call
  site and not stated at the callee is a guard with a half-life* -- the next caller is written by
  someone reading the function, not the call site, and silently loses the protection.

  **S3, `Modules/Inventory/Wire.lua`:** `Wire.decode` would decode a legacy link payload if handed
  one; only `Chat.lua`'s `isV2` check before the call stopped that. The check now lives in
  `Wire.decode` itself -- a non-tuple payload returns `"dropped"` and no records -- and the
  `decodeLegacy` function and the `"legacy"` format value are deleted, so there is no dead path for
  a future caller to reach and no value to branch on. Three specs were pinning the forbidden
  behaviour (one headed *"Permanent, not a migration aid: this is what lets a guild run mixed
  versions"*, which stopped being true on 2026-09-09); they now pin the drop. The CMD-004 bandwidth
  guard can no longer round-trip through a decoder, so it asserts the v1.3.2 shape directly.

  **S4, `Modules/RequestLog.lua`:** `ApplyRequestMutation` collapsed "no sender" and "sender that
  does not resolve" into one nil, and every permission gate was wrapped in `if normSender then` --
  so a DELETE from an unresolvable name applied with **no GM check at all**. Latent, not live: the
  real sender is server-supplied, and `NormalizePlayerName` returns nil in exactly two places (an
  empty name, or an empty character-part before the hyphen). Now three states -- a nil sender is
  refused (no caller applies locally; a future one must add an explicit flag), a malformed sender is
  refused, and only a resolving one reaches the gates. Both malformed inputs are driven through the
  real receive path in `Tests/requestchain_spec.lua`, proven red. **That fixture had stubbed
  `NormalizeName` looser than the real function on exactly these inputs** -- `"-Realm"` came back
  as-is instead of nil -- so the examples could not have gone red against it. The stub is gone; the
  env's realm already makes the real function deterministic.

- **The test stand-ins for `Core` were WIDER than the real one** (AUDIT-S1 follow-on). Two test
  surfaces installed a `ComputeCanonHash` method that the real `Core` does not have -- the canon is
  minted at exactly one site inside DeltaComms and Core never fronts it. CMD-001 with the sign
  reversed: correct-looking code calling it would pass every spec and fail in the client. Removed
  from both, and `Tests/coresurface_spec.lua` now reads the real surface (Core.lua's own methods plus
  the six Ace mixin lists from the sibling install) and fails if any stand-in installs a name
  outside it. Five spec files hand-roll a Core table; all checked, guard proven red.

- **The order-splitting logic has real coverage for the first time** (`Tests/fulfillsplit_spec.lua`,
  32 examples). `CalculateFulfillmentPlan` decides which whole stacks to attach and whether one must
  be split to hit the exact quantity -- get it wrong and a guildmate receives the wrong number of
  items, or an order the bags can cover is refused. It had no direct spec.

  All four phases are now driven against known stack layouts, plus the property that matters:
  **across twenty stack/quantity combinations, attached + split must equal exactly what was
  ordered.** The two most likely to go wrong silently are pinned specifically -- that it never
  splits from a stack it is already attaching whole (one stack counted twice sends the order short),
  and that it prefers an exact combination over a split when one exists.

  **Reported honestly: the planner passed every one on the first run.** Nothing was found broken;
  the behaviour is now pinned rather than assumed.

- **The bank-collect state machine has a spec** (`Tests/bankcollect_spec.lua`, 49 examples) -- the
  half that was missing above. It drives `BankCollectStep`, `FindOldestBankFillableOrder`,
  `FindEmptyBankSlot`, `FindItemsInBank` and `CountItemInBank` against a bag/bank model that actually
  moves stacks: the three container-moving APIs are implemented over the env's bag tables so the
  arithmetic can be asserted, not just the calls counted.

  The property that matters is pinned under BOTH client behaviours: after pull and return, bags hold
  exactly what they held plus the order and the bank holds exactly what it held minus it -- with the
  pulled stack merging into partial bag stacks (the client auto-stacks) and without, across seven
  layouts each, because the addon cannot know which happened. Also pinned: least-overshoot stack
  choice, re-choosing on every click, the three-look give-up, no-free-bank-slot, bags-full refusing
  before touching the bank, the oldest-by-date-then-id tiebreak agreeing with the mailbox search,
  bank stock NOT making an order serviceable at the mailbox, id-primacy and suffix equality on the
  bank side, and BANKFILL-002 -- closing the bank drops the armed phase. The BANKFRAME_CLOSED reset
  and the new banker guard were each reverted to prove exactly their examples go red. One
  expectation of mine was wrong on the first run, not the code: on a second click with a shortfall
  of 2 the step correctly takes the exact 2-stack rather than the 3 I had written down.

- **BANKSLOT-001, the last spelling.** The bank-bag and carried-bag ranges now have ONE spelling,
  `TOGBankClassic_Constants.CarriedBagRange()` / `BankBagRange()` (functions, read at call time --
  the globals are engine-side and can be unset when a file loads). Five files derived the arithmetic
  themselves; the guard in `Tests/itemhighlight_spec.lua` now requires `NUM_BANKBAGSLOTS` to appear
  only in `Constants.lua`, is anchored on `for bag =` so an unrelated literal loop cannot trip it,
  and covers `Mail.lua` -- where its first run found **two more** hardcoded `for bag = 0, 4` walks
  nobody had counted (the split popup and the empty-slot search). Those and `FindEmptyBankSlot`'s
  inner scan collapsed onto one `tog_firstEmptySlot(first, last)`.

- Three dead locals removed from the same function while covering it, and `Modules/Mail.lua`'s
  Send-Mail API calls added to `.luacheckrc` -- roughly 20 of its 43 warnings were the linter not
  knowing real WoW globals, which is real signal being drowned rather than real problems.

- `env.readFile` and `env.codeLines` lifted into `Tests/env_togbank.lua`. The identical bodies were
  open-coded across several spec files and the new specs would have added more; a scan helper copied
  per file can be corrected in one place and stay wrong in the others.

- **`CHANGELOG.md` split at the v1.4.0 boundary.** The v1.4.0 section (~113,000 characters) moved
  whole into `CHANGELOG_ARCHIVE.md`; with it here the release body was over GitHub's 125,000-
  character hard limit, which fails the GitHub release silently while the CurseForge upload succeeds.

## [v1.4.0] (2026-09-10) - Canon Hashes, Tuple Wire & LibGuildRoster Adoption

### Bug Fixes

- **VERIFIED IN GAME: the reported data-loss bug did not reproduce under the conditions that caused it.** The whole canon-hash rework was built from one live report -- *"I was getting V2 data from the banker, the banker logged off and then I was getting the mutated V1 hash that was 'newer' and it was over-writing my V2 data"*. That sequence was run deliberately on a real guild: **banker offline**, the reporting client online, and 9 of 11 online clients still unmigrated and therefore still re-minting and re-broadcasting hashes exactly as before. The inventory stayed correct and no overwrite occurred.

  **The banker being offline is the whole test, not a detail.** While the author is online they keep republishing their own canon, so a stale relayed copy loses on merit and the guard is never the thing that saved you. Only with the author gone does a third party's older copy get its chance -- which is precisely the sequence that lost data. An earlier "no overwrites" observation had the banker online for most of the window and was deliberately **not** counted.

  Stated at the strength the evidence supports: the failure **did not occur** under the conditions that previously produced it. One session is not a proof of impossibility, but it is the difference between *"mechanism-correct and spec-covered offline"* and *"the bug we set out to fix did not happen on the real guild"*. The guard is `Chat:ShouldApplyTuplePayload`, ordering on the author's publish time that `INV2-ORDER-001` put on the wire.

  **What this does NOT establish, because the same guild cannot show it:** whether the broadcast storm is quieter. The unmigrated majority still mutate hashes and the fix has no reach into them, so any traffic capture there is dominated by old clients behaving like old clients. That closes when a guild finishes upgrading.

- **MIGRATE-002 (release blocker, found while assessing whether v1.4.0 was shippable): the mixed-version warning had no throttle and would have flooded chat during exactly the rollout it exists to help.** Removing wire back-compat means a v1.4.0 client drops every v1.3.2 inventory payload, and the drop branch warns by name when the sender is a banker -- *"X is running an older TOGBank and its bank contents cannot be read. Ask them to update."* That diagnostic is right and load-bearing: without it the drop is silent and indistinguishable from the banker having no items, from the sync never being requested, and from a bug in the new path.

  **But the branch is reached on every legacy payload, not once per client.** An unmigrated banker re-broadcasts on every scan and answers every P2P query, so the warning fired repeatedly per person -- worst precisely mid-migration, when most bankers are still old. Measured against a live guild during this rollout: 9 of 11 online clients unmigrated, several of them bankers.

  Now latched once per **normalised** sender per session, so `Bob` and `Bob-Realm` cannot each claim a line. Session-scoped on purpose rather than persisted: if a banker updates mid-session the latch is irrelevant, and if they have not updated by the next login the reminder is worth one more line. **The DEBUG record is deliberately left unlatched** -- a diagnostic log should show every occurrence, and it is opt-in so it cannot flood anyone. Location: `Modules/Chat.lua`.

- **CHATWIN-001: `/togbank debugtab` could fail with a Lua error instead of a missing tab, on any client with deprecation fallbacks turned off.** Four loops in `Modules/Output.lua` iterated `for i = 1, NUM_CHAT_WINDOWS`, and that global is **not guaranteed on Classic Era**. Verified in Blizzard's own tree rather than assumed: the only assignment is `Blizzard_DeprecatedChatInfo/Deprecated_ChatFrame.lua:18`, and that file returns early at its line 4 unless `GetCVarBool("loadDeprecationFallbacks")` is true. With the CVar off the global is `nil`, so `for i = 1, nil` is a hard error -- the debug tab broke outright rather than simply not being found, and the same nil reached the tab's creation and removal paths.

  Now read from `Constants.ChatFrameConstants.MaxChatWindows`, which is engine-side and present regardless and is what the deprecated global forwards to; the bare global is the fallback and a literal is the last resort. This is the fleet's standing trap -- a bare global that exists **only** as a deprecation shim is not evidence the client prefers it, and feature-detection branches on exactly that. Location: `Modules/Output.lua`.

- **DEV-UX-002: `/togbank debugtab` reported success in a state where it could not possibly produce output.** It replied *"Debug output will now appear in 'TOGBank Debug' tab"* unconditionally -- but the tab is only the **fourth of four gates**, and the two before it are off by default: the log level, and at least one opt-in category. So a first-time user got a confident confirmation followed by silence, which reads as a broken tab rather than an unset switch. Same class as `DEV-UX-001`, which this codebase already filed against a confident confirmation for a typo.

  It now reports the gates that are actually shut, naming the command that opens each, and lists the enabled categories when output really is flowing. Location: `Modules/Chat.lua`.

- **INV2-SUFFIX-001: a random-suffix item's variant was recovered by parsing a link that does not always carry it, instead of being read from the record that always does.** Same class as the link-stripping the operator ruled out for V2 -- *"in V2 the link is just constructed on the other side from ItemDB"*, *"link stripping is causing a lot of problems"* -- and the data was on the record the whole time.

  A `Record` holds `{id, count, suffix, enchant}` with the suffix as a real field, but `Store:GetAltView` materialised rows as `{ID, Count, Link, Info}` and dropped it. Two consumers then recovered it with `Item:GetSuffixID(row.Link)`. That link is rebuilt by `Resolve.describe`, and **only its first step preserves the suffix**: step 2 emits a bare `item:<id>` and step 3 emits no link at all. So on any client whose ItemDB lacks that id -- or that loaded an older copy, or none -- the suffix silently read as `nil` and every "of the Tiger" matched every "of the Monkey".

  **The more severe of the two sites was the minting one.** `UI/Search.lua`'s request dialog is where a request's `suffixID` is first written, so the loss was not a failed match downstream -- the request was **created** with no variant at all and then matched any sibling for the rest of its life. The second site, `UI/Requests.lua`'s tooltip lookup, could only fail to resolve.

  **A third defect surfaced while tracing it**, and it made the other two moot: `Search.lua`'s lookup deduplicated on **itemID alone**, so two suffix variants held by one character were summed into a single row carrying one variant's link and both variants' counts. Search therefore offered a stock figure that no single variant actually had. Identity there is now id **plus** suffix, which is what `REQ-003` already says these items are.

  Fixed by carrying `Suffix` and `Enchant` through the view as first-class numbers and reading them via a new `Item:RowSuffixID(row)`. The helper is not a one-liner for a reason worth recording: on a V2 row `Suffix = 0` means *definitely no suffix*, while on a legacy row the field is **absent** and means *unknown, ask the link*. Collapsing those into `tonumber(row.Suffix) or GetSuffixID(row.Link)` would make legacy suffixed gear unmatchable, because `0` is truthy in Lua and would short-circuit the fallback away.

  **Three other call sites were enumerated by reading and deliberately left alone**: `Mail.lua:799`, `Mail.lua:1012` and `Bank.lua:556` parse live client links, which always encode the suffix. Those are safe and must not be confused with the two above -- the distinction is where the link came from, not what is done to it. Locations: `Modules/Inventory/Store.lua`, `Modules/Item.lua`, `Modules/UI/Search.lua`, `Modules/UI/Requests.lua`, `Tests/suffixcarry_spec.lua`.

- **HASH-CANON-002: the sync fingerprint was being re-minted by every client that touched it, not just by the bank character that produced it** -- reported from a live guild, and diagnosed there rather than here. The operator's words: *"the hash gets recomputed anytime anyone looks at the bank"*, *"V1 has a broadcast STORM because the hashes are ALWAYS updating"*, *"they are being mutated by EVERY user"*, and the sequence that cost them data: *"I was getting V2 data from the banker, the banker logged off and then I was getting the mutated V1 hash that was 'newer' and it was over-writing my V2 data"*.

  A fingerprint is the **identity of a version of a record**. That only works if every client holding that version reports the same number, which requires it be produced once, by the client that read the bank, and carried unchanged by everyone else. Three separate places broke that, and each looked entirely reasonable where it stood.

  **1. The query path.** `Chat.lua`'s `PERF-005` block ran on **every incoming query about a character** and stamped a freshly computed fingerprint whenever one was missing -- on a client that had not authored the record, computed from whatever its own copy happened to hold. This is literally "recomputed any time anyone looks at the bank". Deleted; a record with no fingerprint now advertises none and is re-requested from the client that can actually produce one.

  **2. The no-change correction.** The `togbank-nochange` handler read `hash` / `hashV2` / `mailHash` off the message and wrote them over stored values, **adopting from any sender rather than from the author**. Any peer holding a copy answers a state summary, so peer A minted a number, B stored it as its own, and B then served it to C. That is the propagation mechanism for "mutated by every user", and it is exactly the reported sequence: the banker went offline and a mutated revision-1 number arrived from a third party and replaced good data. Deleted on receive, **and the three fingerprint fields removed from the send side too** -- an older client still adopts whatever arrives, so refusing them on receive alone would leave the loop fed from the other end. The message itself is kept; it still closes the sync session, which is its real job.

  **3. The database migration**, which ran over saved data that mostly describes **other players'** bank characters received over the wire.

  **The second one's own comment recorded how it began** and should have been the warning: it existed to *"fix stale inventoryHash left by the pre-DELTA-025 bug"*. A repair for one client mis-stamping became the channel by which every client restamped every other. Its justification -- that the sender only reaches that path when the item baselines match, so its number must be right -- argues that the **data** matched and says nothing about how the sender's **number** was produced.

  **Four specs were deleted rather than re-baselined**, and that is worth naming: they were green, careful, and asserted the adoption as a **requirement**. A spec pinning a live data-loss bug is worse than no spec, because the next person to fix it meets a red test with a confident message. Locations: `Modules/Chat.lua`, `Modules/Guild.lua`, `Modules/Database.lua`, `Tests/syncwire_spec.lua`.

- **HASH-CANON-003: the fingerprint now includes the moment it was published, so two scans of coincidentally identical contents are two distinguishable versions** -- the operator's directive: *"The hash HAS to have the DTS in it and the NEWER V2 Hash wins"*.

  This looks circular and is the reason it had not been done: if the datestamp is inside the fingerprint, the fingerprint differs on every call by construction, so it cannot also be the thing that decides whether anything changed -- and comparing against it would make **every** bank close look like a change and republish to the whole guild. That is the broadcast storm, arrived at from the other direction.

  Resolved by keeping three numbers with three different jobs: a **content** fingerprint (no datestamp, never sent) which is the change detector; the **canon** (datestamp included, sent) which is the identity of a version; and the frozen original, which is what un-upgraded clients still compute. A scan computes the content fingerprint first, advances the datestamp only if it moved, and only then stamps the canon. Every publish gets a distinct identity with no churn.

  **The bump is bankers only, and that is now pinned rather than incidental.** `Bank:Scan` returns early for a character that is not in the banker list, and the stamp sits ~280 lines below that gate with nothing connecting them. Two guards close it: a class guard asserting exactly **one** production site can mint a fingerprint (which is what would have caught the three deleted above), and a behavioural example asserting a non-banker's scan stamps neither number -- proven red by removing the gate's `return`. Locations: `Modules/DeltaComms.lua`, `Modules/Bank.lua`, `Core.lua`, `Tests/canonhash_spec.lua`, `Tests/wiring_spec.lua`.

- **INV2-ORDER-001: the tuple receive path had no last-writer-wins guard at all, so a stale snapshot silently overwrote a fresher one** -- the other half of the operator's report, and a straightforward data-loss bug.

  The legacy path has always refused a record that is not newer. The tuple path called `Store:SetAltRecords` **unconditionally**. With several peers relaying the same character over the peer-to-peer layer, whichever snapshot arrived **last** won regardless of when it was authored, so a peer holding a days-old copy overwrote a fresh one and nothing anywhere said so.

  It could not have checked even if it had wanted to: the author's publish time was **not on the wire**, and the receiver stamped its own arrival time on everything it stored. **That second half is arguably worse**, because every receiver re-advertises what it holds and the peer-to-peer layer picks the holder with the newest timestamp -- so a relayed third-hand copy advertised itself as **fresher than the author's own record**, and the further a copy travelled the fresher it claimed to be.

  The publish time now rides as a trailing wire field, is stored verbatim rather than minted, and ordering is decided in exactly one place. A payload with no publish time is still accepted, deliberately: refusing it would freeze that character permanently rather than merely leaving it unordered, and unordered is what already shipped. Locations: `Modules/Inventory/Wire.lua`, `Modules/Guild.lua`, `Modules/Chat.lua`, `Tests/inventoryordering_spec.lua`.

- **INV2 step 10 remainder: the second inventory receive path is deleted, along with the link-reconstruction machinery it kept alive** -- about 680 lines.

  `Guild:ReceiveAltData` took a link-bearing legacy payload off the wire and wrote a character's items straight from it, reached through a `type == "alt"` branch sitting on the **request-mutation** prefix alongside the genuine request traffic. It never met the tuples-only guard, so the no-backwards-compatibility directive was being enforced on one inventory path and not the other.

  **Validated as unfed before deleting**, so nobody re-derives it: the released v1.3.2 sends inventory on `togbank-d4`, and its only sender on the request prefix is request mutations. No shipped version sends inventory there. So this was dead code and **not** the source of the reported corruption -- that was the two entries above -- but a bypass nothing currently drives is still a bypass.

  Removing it orphaned a cascade that had not been anticipated: `ReconstructItemLinks`, then the batched reconstruction queue behind it (a concurrency cap, a batch size, a re-queue path, asynchronous item-load callbacks), then the throttled UI refresh that existed to repaint as those loads trickled in. All of it existed **only** because the legacy format shipped links across the wire; tuples resolve on arrival and the display redraws once. `ReconstructItemLink` (singular) is alive and still used while drawing -- the names differ by one character. Locations: `Modules/Guild.lua`, `Modules/Chat.lua`.

- **LIBREQ-ALL-005: a comm prefix the client refuses to register is now reported instead of failing silently** -- and the obvious version of this guard would have been dead code.

  The registration call returns an **enum**, never a boolean and never nil. So `if not RegisterAddonMessagePrefix(p)` can never fire, because success is `0` and zero is truthy in Lua. Both spellings of the naive guard would have passed their specs against a harness stub that returned `true` and whose own comment admitted the return had never been checked against Blizzard's documentation. Confirmed against the generated documentation for this flavour before writing anything.

  A duplicate registration is deliberately silent: the embedded comms library registers first, so this addon checking its own gets "duplicate" for all eleven prefixes on every login, and a warning that fires every time is one that gets trained out. Only genuinely invalid prefixes and hitting the client-wide cap are loud -- the cap being the one a player with many addons can actually hit, which is the case worth knowing about because it silently costs you all guild bank sync. Locations: `Modules/Chat.lua`, `Tests/commprefix_spec.lua`.

- **INV2 step 10: the link-based sync protocol is deleted, in both directions** -- the standing directive was that V2 sends tuples only and the link-stripping machinery goes rather than being branched around. It has, and the operator then extended it: there is **no backwards compatibility on the wire at all**.

  **Gone:** `StripDeltaLinks` and `Item:NeedsLink` (the per-item "is this link safe to drop" guess -- a decision made on one machine about a *different* machine's item cache, and the corruption this whole rework exists to remove); `ComputeDelta`, `ComputeItemDelta`, `BuildItemIndex`, `ItemsEqual`, `GetChangedFields` and `DeltaHasChanges` on the send side; `ApplyDelta` and `ApplyItemDelta` with their `ITEM-003` ghost guards on the receive side; the `alt-delta` validators; seven `Guild` wrappers; and `Modules/Tests.lua` with its `/togbank test` command, an in-game harness written entirely against those functions. `DeltaComms.lua` went from 1,720 lines to about 380.

  **`ComputeItemDelta` is worth naming as the reason.** It matched a new row to a stored one through three successive guesses -- normalised link key, then an ID-only index for minimal baselines, then a per-ID candidate list with a used-set to stop two suffix variants of one base ID collapsing onto each other. Every layer compensated for identity being derived from a link that might not be there. `ComputeTupleDelta` is thirty lines because `id:suffix:enchant` comes from integers that always are. The ambiguity is not handled better; it stops existing.

  **Kept deliberately, and the design doc's deletion list was wrong about them:** `Item:GetSuffixID` has four live consumers reading *client* links (bank scanning, mail fulfilment, search, request matching), `GetItemString` backs mail inventory, and `ItemClassNeedsLink` still serves `PurgeLinklessGearGhosts`, which repairs damage already sitting in players' saved data. Deleting those removes features, not complexity. `docs/INVENTORY_V2.md` section 8 has been corrected.

  **KNOWN COST:** during a mixed-version window an upgraded member sees nothing from un-upgraded bankers and vice versa; it heals as members upgrade. Every send is now a full snapshot rather than a delta, because `ComputeTupleDelta` needs a tuple baseline that `togbank-state` does not yet carry -- tuple rows are small enough that this is not the regression it sounds like, but it is one. The V2 switches now default **on**, and off is a diagnostic rather than a rollback: there is nothing left to roll back to. Locations: `Modules/DeltaComms.lua`, `Modules/Guild.lua`, `Modules/Chat.lua`, `Modules/Item.lua`, `Modules/Switches.lua`, `Core.lua`, both `.toc` files.

- **INV2-SESSION-001: a V2 delivery never closed its sync session** -- found by deleting the legacy receive branch, which had been doing this work for a payload shape that never reached it.

  The tuple receive path returns as soon as it has stored the rows, and it returned *before* the code that ends a delivery. So every V2 sync leaked a session slot, left the 15-second acknowledgement timer armed -- which then fired and abandoned a sync that had **already succeeded** -- and recorded no inbound traffic. It sat behind an early return, which is why it looked covered. Locations: `Modules/Chat.lua`.

- **HASH-REV-001 follow-up: the no-change hash correction sent only one of the two hashes** -- `RespondToStateSummary` has two `no-change` senders and only the third one elsewhere had been wired for `HASH-REV-001`. Because the receiver **adopts** these values rather than comparing them, a corrected client ended up holding the sender's revision-1 hash beside its own older revision-2 one -- and revision 2 is what two upgraded clients actually compare. Locations: `Modules/Guild.lua`.

- **HASH-REV-001: upgrading no longer desyncs you from guildmates who have not upgraded** -- raised as audit finding 37, and it removes a protocol break this version was otherwise going to ship.

  Fixing `SYNC-031`/`SYNC-032` corrected what the sync fingerprint is computed from, and did it **in place**. That fingerprint is compared between clients, so changing it meant an upgraded client and an un-upgraded one could never agree again -- each seeing the other as permanently out of date and re-syncing forever. Worse, the "no changes" correction message **stores** the sender's fingerprint on the receiver, so the two versions would have kept overwriting each other's, leaving clients disagreeing with their own next scan.

  The addon now carries **both** fingerprints. The corrected one rides alongside the original, and two clients use it only when both have it; otherwise they fall back to the original, which every client can still compute. **A mixed guild needs no coordinated update** -- upgrade whenever you like, and each pair of clients quietly uses the best fingerprint they share.

  The original is now frozen and must stay wrong: it cannot see random-suffix or enchant differences, and specs assert those limitations deliberately, so nobody later "fixes" the one function whose job is to match what un-upgraded clients compute. Change detection still runs on the corrected fingerprint, so `SYNC-031` stays fixed. Fifteen new examples, **three confirmed red** against the wrong negotiation. Locations: `Modules/DeltaComms.lua`, `Modules/Guild.lua`, `Modules/Chat.lua`, `Modules/Bank.lua`, `Modules/Database.lua`, `Core.lua`.

- **P2P-027: a retry cycle could abandon a sync that was already succeeding elsewhere** -- the same defect as `P2P-026`, found by sweeping `Modules/P2PSession.lua` for it deliberately rather than by another report.

  When every peer holding a character's data replied "busy", the addon scheduled a retry cycle and reset its candidate list. If a peer then freed up before that cycle ran, the session moved on to it -- but **`AdvanceCandidate` cancelled the dispatch timeout and never the retry**. The superseded cycle stayed live, fired anyway, found no untried candidate left, and failed the session while a request to a perfectly good peer was still outstanding. It could also whisper a second sync-request for the same session and re-arm the dispatch timeout underneath the peer being waited on.

  All three session timers now arm through one `ArmSessionTimer`, and advancing cancels the retry it supersedes. **Three of five new examples proven red**, including the one that drives the session being destroyed. The fifth is the over-reach guard: a retry cycle that nothing supersedes must still fire and re-dispatch, or busy guilds would be worse off than before.

  **This is the third instance of one class in this version** (`P2P-026`, `P2P-027`, and audit finding 24 before them), and only the first was reported. The distinguishing detail: none of them was the `C_Timer.After` mistake that finding 24 named -- every handle was real. The defect each time was a **live handle being assigned over**, which reads as correct at the arm site. `BeginCollectWindow` in the same file already guarded against it and its comment explains why; nothing carried that rule to the other arm sites. Locations: `Modules/P2PSession.lua`.

- **HASH-REV-002: `/togbank hashdebug` reported `OK` for characters the addon was actively treating as out of sync** -- the local-vs-remote hash comparison existed in **four** places, and the fourth was wrong.

  Three copies were byte-equivalent (`Guild:IsAltSyncPending`, `Guild:ReportHashListCoverage`, and the hash-list compare in `Modules/Chat.lua`). The fourth, in `/togbank hashdebug`, compared **only the inventory hash** and ignored the mail hash entirely. So a character whose mail had changed printed a green `OK` while the sync layer was calling it pending and re-requesting it -- and `Guild.lua`'s own docstring claims the command and `IsAltSyncPending` share one definition. **A diagnostic that disagrees with the thing it diagnoses points whoever reads it away from the problem**, which is the same shape as `DOC-005`.

  All four now route through one `Guild:HashesAgreeWith`, and the command prints both hashes, because a `MISMATCH` verdict decided by a mail hash that is not on the line is unreadable. The rule that makes the comparison correct -- an absent field is **not** a wildcard, while `0` is a real value meaning "empty" and matches only another `0` -- is documented once and pinned by ten examples in `Tests/hashagree_spec.lua`.

  **This was done now, ahead of the hash-revision work (audit finding 37), specifically because that work edits this comparison.** Four unspecced copies about to be changed is how one gets fixed and the others do not. The fourth copy was found by the guard written to prevent a fifth, not by reading. Locations: `Modules/Guild.lua`, `Modules/Chat.lua`.

- **P2P-026: a repeated sync request for the same banker was aborted five seconds later by the request it replaced** -- the second half of audit finding 24, and the half the finding's own fix did not close.

  Finding 24's remedy was `C_Timer.NewTimer` at three timeout sites, so the stored handle stops being `nil` and `:Cancel()` finally does something. That fixed the path where a **peer answers**. It did nothing for the path where nobody answers at all: `BroadcastP2PRequest` has no in-flight guard, so a second request for the same banker inside the window armed a second timer and **overwrote the stored handle**, dropping the first on the floor with nothing left that could reach it.

  **Failure:** a request goes out, and within five seconds something re-requests the same banker -- a catch-up, a bank open, a manual sync. The first timer then fires and finds the **second** request's state sitting under its own key. It clears the pending entry and the expected hash, records a banker fallback against the guild, and calls `AdvanceCandidate` on a session it was never armed for. A live sync is abandoned and blamed on a timeout belonging to a request that had already been superseded. The 15-second ACK fallback in `Modules/Chat.lua` is the worse of the two, because 15 seconds is a long window to hold a stale claim on an alt.

  Fixed with one `Guild:ArmAltTimeout` helper that all three sites now arm through: it cancels whatever that alt already had in flight before storing the new handle, so *at most one timer per alt per registry* is a property of the helper rather than something three hand-written assignments each have to remember. Cancelling an already-fired handle is safe, and that was checked rather than assumed -- Blizzard's own `AsyncRequestMixin` cancels its timeout timer from inside that timer's own callback.

  **Six of eleven new examples in `Tests/p2ptimeout_spec.lua` confirmed red** against the pre-fix behaviour, including the finding's exact scenario. One of them exists to stop the fix over-reaching: a request that genuinely gets no answer must still time out at its **own** deadline. `Tests/timers_spec.lua`'s shape guard was updated to the stronger invariant it now pins -- arming through the helper, rather than each site remembering `NewTimer`. Locations: `Modules/Guild.lua`, `Modules/Chat.lua`, `Modules/Constants.lua`.

- **HIGHLIGHT-004: item highlighting silently did nothing whenever bags were opened out of order** -- raised as audit finding 29. Both call sites derived the container frame from the bag id (`containerID = (bag == 0) and 1 or (bag + 1)`), which assumes a fixed bag-to-frame mapping. **Classic Era has no such mapping**, and this is Blizzard's own code for this flavour rather than an inference: `ContainerFrame_GetOpenFrame` returns the first frame that is **not shown** and that is the frame a bag renders into, while `ToggleBag`, `OpenBag`, `CloseBag` and `IsBagOpen` all **search** by `frame:IsShown() and frame:GetID() == id`. Blizzard never derives the name anywhere.

  **Failure:** open bag 1 with the backpack closed and bag 1 renders into `ContainerFrame1`, while the addon looked up `ContainerFrame2` -- not shown, so `ApplyOverlay` bailed on its `IsVisible` guard and **nothing was highlighted, with no error**. Open bag 2 then bag 1 and it is worse than nothing: the lookups cross, so one bag is addressed using another bag's slot count.

  **The symptom was already on record and attributed elsewhere.** The `ELVUI-001` note describes *"the checkbox ticks and nothing happens"* -- the identical silent signature, because both failures end at the same `IsVisible` guard. ElvUI is a real cause of that; it was not the only one, and stock-UI reports would have stayed unexplained.

  Resolved now by searching, exactly as the client does, with the slot count taken from the frame's own `size` (which `ContainerFrame_GenerateFrame` stamps on it) rather than from the bag id. **This subsumes `HIGHLIGHT-001`/audit finding 9** -- that the bank path applied no button-order reversal while the bag path applied one, and the two could not both be right. There is now one resolution and one reversal, so the divergence has nowhere left to live. Six examples in `Tests/itemhighlight_spec.lua`, four **confirmed red** against the old arithmetic. Locations: `Modules/ItemHighlight.lua`, `.luacheckrc`, `.luarc.json`.

- **SYNC-034: a banker's mail was discarded by every receiver, and no rescan could ever fix it** -- raised as audit finding 34. `ApplyItemDelta`'s add step required `(newItem.Link or newItem.ItemString)` before it would look at a row at all, so a **linkless** row was skipped before any branch could consider it: no add, no block, no log line.

  **Linkless rows are a designed state here, not malformed input.** `Modules/MailInventory.lua` deliberately leaves `Link` nil when `GetInboxItemLink` returns nothing, `ComputeItemDelta` puts that row straight into `delta.added`, and `ApplyDelta` routes **mail** through this exact function. So a mail attachment whose link the client could not supply at scan time went out on the wire and was silently dropped by every peer -- and a rescan reproduced the same linkless row and the same drop, permanently.

  **Same user-visible symptom as `INV2-MAIL-001` -- "the banker's mail is missing" -- by a completely different mechanism.** That fix was on the SCAN side (the V2 store not recording mail); this is the SYNC side and was untouched by it. Two independent causes, one of which had been treated as solved.

  **The fix is not "always add linkless rows".** The `ITEM-003` guard immediately below is written to reject linkless *gear* (`if not newItem.Link ...`) and had simply never been reached by the rows it was written for. Blocking a row deliberately with a debug line is a decision; dropping it before the guard can look is not. Both halves are pinned in `Tests/applyitemdelta_spec.lua`: linkless mail is admitted, linkless weapons are still blocked.

  **The log actively concealed it.** It printed `#delta.added` beside `updated` and `added`, so two lost rows read as *"Applied 5 added items (0 updated existing, 3 new)"* -- numbers that do not reconcile, with nothing saying so. There is now a `dropped` count and a spec asserting `updated + added + dropped == #delta.added`. **Confirmed red:** restoring the old guard fails five examples, and instructively the two ITEM-003 blocking tests stay green -- a dropped row and a blocked row look identical from outside, which is why this survived. Location: `Modules/DeltaComms.lua`.

- **SYNC-033: `Record.aggregate` promised one bad row would not discard the rest, and a nil hole discarded every row after it** -- raised as audit finding 33. The docstring is explicit that invalid entries are skipped rather than aborting the batch, citing `ITEM-005`. The loop was `ipairs`, and **`ipairs` stops at the first nil** -- so a hole did not skip, it truncated, and `skipped` did not count it, so the return value reported nothing wrong.

  **The asymmetry is why this was worth fixing rather than documenting.** A hole in the *old* side under-reports it, so rows re-appear as `added` -- wasteful and self-correcting. A hole in the *new* side makes every row after it absent from the new map, so `ComputeTupleDelta` emits them all as **`removed`**: a delta instructing the receiver to delete items the sender still holds, in a message that looks entirely legitimate.

  The two paths also disagreed on the contract -- legacy `ComputeItemDelta` and `BuildItemIndex` use `pairs` throughout and are hole-tolerant, so the rework was quietly changing the iteration contract in the direction of *less* tolerance. Now a numeric-keyed `pairs` walk, which makes the docstring true. **No production path is known to create a hole** -- the reviewer said so plainly and so does this entry -- the finding is that nothing asserted density, nothing documented it, and the docstring asserted the opposite. Locations: `Modules/Inventory/Record.lua`.

- **SEC-001: receiving a message from someone was enough to be treated as a guild member** -- `Chat:OnCommReceived` marks the sender online for every inbound message, *before* any authorisation runs (`Modules/Chat.lua`). `Guild:UpdateOnlineMember` creates a stub roster entry when the name is unknown -- its own comment says *"shouldn't happen, but safeguard"* -- and `IsInCurrentGuildRoster` answered purely on whether an entry existed. So the sequence was: a stranger sends an addon message, the handler puts them in the roster, and the roster half of `IsAltDataAllowed` then passes.

  **What that allowed:** any player able to send an addon message on the guild channel could inject inventory data for **any character the addon already knows is a banker** -- the remaining `IsBank` check constrains the *claimed alt*, not the *sender*. The victim's client would store and display fabricated bank contents, and pass them on to other members as its own.

  **This is not new and it is not V2-specific.** It affects the `alt` and `alt-delta` paths exactly as much; it simply had never been exercised, because until now no spec drove `OnCommReceived` from a sender outside the roster. Found by `Tests/syncwire_spec.lua`'s two-client join, whose first version **passed vacuously** -- the roster was not stood up, so every payload was refused for the wrong reason and the guard got credit for work it never did. Standing the real `LibGuildRoster` up is what turned it red.

  **Fixed by marking provenance rather than by removing the stub.** The stub still exists (it genuinely covers the window before the roster loads), but now carries `isStub = true`, and `IsInCurrentGuildRoster` no longer accepts one as membership -- it falls through to the authoritative client roster scan. The marker is a security boundary, and the comment at both sites says so, because a later reader tidying "an unused flag" would silently reopen this. Locations: `Modules/Guild.lua`.

- **INV2-STRIP-001: deleted `Guild:StripAltLinks` and `Guild:StripItemLinks`, the per-item "is this link safe to drop" decision** -- both were **already dead**: `StripAltLinks` had no caller anywhere in the addon and was `StripItemLinks`'s only one. They survived because they read as the live transmission path; the live path is delta-only (`Modules/Guild.lua`'s `DELTA-ONLY: All syncs use delta protocol, no full sync fallback`), so nothing had reached them in a long time.

  **They are worth naming rather than quietly deleting, because they implemented the mechanism V2 exists to remove.** For each item they guessed whether the client cache would let the receiver rebuild a link -- keeping the full link for gear, uncached and `ForceLink` rows, substituting an `ItemString` otherwise. That guess is made at transmission time about a *different machine's* cache, and getting it wrong is how link-bearing rows go bad.

  **V2 does not make the guess.** A row on the wire is `{id, count, suffix, enchant}` and the receiver rebuilds the link from those integers through LibItemDB -- `Modules/Inventory/Resolve.lua` already does exactly this via `lib:GetSuffixLink(id, suffix, enchant)`, and `Store:GetAltView` already consumes it. There is no link to strip and so nothing to get wrong. `Modules/DeltaComms.lua`'s `StripDeltaLinks` is the remaining live instance and goes with the wire-format change.

- **INV2-SWITCH-001: `dualWrite` reported itself ON while nothing could read it** -- introduced and caught inside one session, which is the only reason this is a changelog line rather than a shipped defect. `INV2-VAULT-001` replaced `Bank:Scan`'s single `Scan:ScanAll()` call with separate `ScanBags`/`ScanBank` calls to get per-source output. That **orphaned `ScanAll`** -- and `ScanAll` held the only `IsEnabled("dualWrite")` in the addon, so the switch's sole reader became unreachable code while the dev-switch listing went on printing `ON dualWrite` beside a description promising it was keeping the legacy DB current from the same scan.

  **The legacy DB was never actually at risk**, which is worth stating because the description implies otherwise: the legacy scan path writes that DB unconditionally and is still the authoritative writer. What broke was the **diagnostic** -- the thing a rollback decision gets made on.

  **Fixed by un-orphaning `ScanAll` rather than by relabelling the switch.** `ScanAll` now returns the per-source shape itself -- `sources.bags` always, `sources.bank` **absent** when the vault was unreachable -- alongside the flat `records` array it always returned, both from the one walk so they cannot disagree. `Bank:Scan` makes one call again and no other caller or spec had to change.

  **The guard is the substantive part.** `Tests/switches_spec.lua` now sweeps every `.lua` the `.toc` ships and asserts each registered switch is genuinely read via `IsEnabled("<name>")`, or else declares a `pending` marker that makes the listing print `NOT YET ACTIVE`. The file set comes from the `.toc` for the reason `timers_spec` gives: a module missing from it does not load in game, so it is the one list that cannot silently omit a file. **The guard's first version matched the bare switch name and reported `dualWrite` as read because `Modules/Bank.lua:292` mentions it in a comment** -- prose about a switch is the opposite of a reader, and counting it would have concealed exactly what the guard exists to find. Both branches confirmed red: the `pending` branch by the real orphan, the primary branch by registering a throwaway unwired switch. Locations: `Modules/Inventory/Scan.lua`, `Modules/Bank.lua`, `Modules/Switches.lua`, `Modules/Chat.lua`.

- **FINDING 28: `ReleaseSendSlot` was documented as safe to call redundantly, and that is a property of its caller rather than of the function** -- raised by peer review, round 11. `P2P-024` gave each acquisition a generation token so a stale 210 s safety timer cannot free a slot belonging to a later send. **That protects the timer path from the completion path and does nothing to protect the completion path from itself.** A completion arrives with no token, so it retires the *oldest* outstanding token for that requester -- which, with two sends in flight for them, belongs to the **other** send. A duplicated completion therefore retires send B's token and decrements a slot B still holds, and the cap admits an extra concurrent send: `P2P-024`'s symptom returning through the door `P2P-024` did not close.

  **Not demonstrated, and the entry says so.** There is one production caller, `Modules/Guild.lua`'s send-complete callback, and a single call site cannot double-release on its own. What made the claim load-bearing is that `Tests/p2psession_spec.lua:136-137` deliberately calls it twice and passes -- **pinning redundancy as safe in the only case where it is.**

  **Fixed at the caller, not in the function, because only the caller knows which send finished.** The completion callback already owns per-send state in `sendStats`, so the release is guarded by `sendStats.slotReleased` and runs at most once per send. The reviewer's preferred remedy was to thread the token from acquisition through to completion; that was **not** done, and the reason is stated rather than hidden: the two acquire sites (`Modules/Chat.lua`, `Modules/P2PSession.lua`) are separated from the release by the whole send call chain, and rewiring the addon's core send path for a latent, single-caller defect is a worse trade than carrying the identity where it already exists. **KNOWN COST:** a *new* caller of `ReleaseSendSlot` does not inherit the guard. The docstring now says exactly that instead of claiming a safety it does not provide.

  **The spec is a source-text assertion and its limits are written into it.** `CreateOnChunkSentCallback` is a `local function`, so no spec can invoke it -- which is why every guard in `Tests/sendresult_spec.lua` reads the source. It will fail if the guard is deleted; it cannot tell a correct guard from a broken one. Saying so in the spec matters on a board whose recurring finding is checks that cannot fail for the reason their name gives.

- **INV2-VAULT-001: with `inventoryV2` on, a banker's own tooltip showed a different number from everyone else's** -- the same item, the same line of code, 68 on the banker and 71 on a non-banker. Viewer-dependent, which is only possible through the V2 branch of `Guild:GetAltItems`: a non-banker has no V2 record for that alt and falls back to the legacy store, so the two clients were reading two different databases.

  **The V2 mirror protected the bank vault by skipping the entire write.** The vault can only be read at a bank NPC, so a scan away from one sees empty vault slots -- writing that through would erase a character's whole bank from the guild's view. `Modules/Bank.lua` avoided that with `if not result.bankScanned and Store:HasAlt(...) then <keep the stored record> end`. It protected the vault and froze **everything else with it**: bags and mail included. A mailbox is almost never opened while standing at a banker, so opening one updated the legacy aggregate to 71 and skipped the V2 write, leaving V2 at 68 **permanently** -- the next scan skipped for the same reason.

  **This survived the `INV2-MAIL-001` fix**, which is why it looked like that fix had not worked. Mail did become a first-class V2 source; the write that would have carried it was being skipped.

  **The legacy DB never had this defect, and the reason is the remedy.** It stores its three sources separately -- `alt.bank.items` / `alt.bags.items` / `alt.mail.items` -- and aggregates on the way out, so it preserves the vault without skipping anything. The V2 store now does the same: `alts[name].sources = { bank = , bags = , mail = }`. `Store:SetAltSources` replaces the sources it is given and **keeps the ones it is not**, so `Bank:Scan` simply omits `bank` when the vault is out of reach and passes today's bags and mail regardless. The `bankScanned` skip is gone. Reads are unchanged -- `GetAltRecords` still returns one flat aggregated array, now cached beside the view cache.

  **Absent and empty are deliberately different.** An omitted source means "keep what is stored"; an empty table means "read, and genuinely empty". Conflating them would make mail a ratchet that only ever grows, so a spec drives an emptied mailbox and asserts the 3 stop being counted. **Both new specs were confirmed red** by restoring the skip: `actual: 108` against 111 (short by exactly the 3 in mail) and `actual: 71` against 68.

  **One collateral finding, and it is the recurring shape on this board.** `Tests/wiring_spec.lua`'s *"still completes the legacy scan when the V2 mirror throws"* stubbed `Scan.ScanAll` to raise -- and the mirror no longer calls `ScanAll`, so nothing threw, the `pcall` trivially succeeded and the spec passed while testing nothing. It now stubs `ScanBags`. Locations: `Modules/Bank.lua`, `Modules/Inventory/Store.lua`.

- **INV2-STALE-001: the V2 store was preferred even when it held fewer sources than the legacy record** -- `Guild:GetAltItems` gated the V2 branch on `#view > 0`, which cannot tell *"V2 is complete"* from *"V2 has some rows"*. Every alt scanned before `INV2-MAIL-001` holds bags and bank and no mail, so its total is **short rather than wrong** -- the worst shape to fall back on, because it looks like data rather than like an absence.

  `Store.SCHEMA` is now stamped on every write and records which **sources** a stored record set covers. It is bumped when the scan gains a source, **not** when the tuple layout changes -- `Record.lua` owns that, and the two version independently because they fail differently: a layout change makes rows unreadable, a source change makes totals short. An absent stamp reads as schema 1, not as "unknown", because the field was added with schema 2. Every record written before this release therefore reads as incomplete and falls back to the legacy store until that character rescans, which needs no migration pass and clears itself.

  **The rejected alternative is pinned by a spec so it cannot creep back in.** "Prefer whichever store reports more" would self-heal faster, but it masks a genuinely lagging V2 and it builds a permanent dependency on the legacy store that step 10 deletes. A complete V2 record that holds **less** than the legacy one still wins, and a spec asserts exactly that. Locations: `Modules/Guild.lua`, `Modules/Inventory/Store.lua`.

- **DOC-005: the addon told you to do the one thing that cannot trigger a scan** -- the bank scan fires on `BANKFRAME_CLOSED` (`Modules/Events.lua:518-520`); `BANKFRAME_OPENED` only marks the data dirty, and bags alone trigger nothing at all because no `BAG_UPDATE` is registered for scanning. Meanwhile `/togbank dev compare` said *"V2 store is empty - open your bank/bags to trigger a scan"*, `README.txt` said *"Open your bank to perform the initial scan"*, and the CurseForge page said *"Open your bank/bags/mail"*. Following any of them literally leaves the store empty and the same message repeating. **This cost a live debugging session**, and the addon's own setup instructions had it right all along (*"Open and close your bags and bank"*), so the two halves of the documentation disagreed with each other. All four now say open **and close**. Locations: `Modules/Chat.lua`, `README.txt`, `docs/Curseforge_Description.html`, `docs/DEV_COMMANDS.md`.

- **DEBUG-002: "was a scan even attempted?" was invisible to the debug category that exists to answer it** -- `Bank:OnUpdateStop` is the only caller of `Bank:Scan` on the bag/bank path, and its four diagnostic lines were logged under `MAIL`/`EVENTS`. So enabling `BANK` -- described in the options panel as *"Bank/bag inventory scanning, including why a scan was skipped"* -- produced silence, which reads as "no event fired" when it may equally mean "the trigger fired and `hasUpdated` was false". Found when exactly that happened. Now logged under `BANK`/`GATE`. Location: `Modules/Bank.lua`.

- **DEV-UX-001: `/togbank debug` raised the log level but could not enable a single category** -- categories are opt-in and default off, so the command a developer reaches for produced no debug output whatsoever, and the only way to turn one on was the options panel. On a busy guild "Enable All" is unusable, which is precisely why the category system exists -- so what was missing was a **surgical** way to drive it, not a bulk one. `/togbank debug <CATEGORY> [on|off]`, `/togbank debug <CATEGORY> <TAG> on|off`, `/togbank debug only <CATEGORY>` (everything off, then one on -- the isolating case), `/togbank debug none` and `/togbank debug list` now exist. Bare `/togbank debug` still toggles the log level exactly as before, and a spec pins that. **This could not have been built before `CMD-001`**: no argument reached a handler at all. Location: `Modules/Chat.lua`.

- **CMD-001: no `/togbank dev` subcommand could receive its arguments, in any release** -- `Chat:ChatCommand` called `Core:GetArgs(input, 2)`, and AceConsole's `GetArgs` **tokenizes**: its contract is `arg1, ..., argN, nextposition` (`Ace3/AceConsole-3.0/AceConsole-3.0.lua:138-139`), not "prefix and remainder". So `/togbank dev switches inventoryV2 on` yielded `"dev"` and `"switches"` and **silently discarded `inventoryV2 on`**. The dev dispatcher then took its no-argument branch and printed the switch list -- which is indistinguishable from a command that ran and had nothing to do. `dev switches <name> on|off`, `dev forcedelta`, `dev forcefull` and `dev test help` were all equally inert. Found by an operator whose switch would not turn on. `ChatCommand` now derives the remainder from `nextposition` and passes it as a **second** parameter, so every existing single-token handler receives exactly what it did before. Locations: `Modules/Chat.lua`.

  **The suite could not have caught it, and that is the more important half.** `Tests/wiring_spec.lua` *does* drive the real `ChatCommand` -- but it stubbed `Core:GetArgs` as `(prefix, remainder)` in **two** places, a **looser contract than the real library**, so code that dropped the remainder passed against the fake indefinitely. This is the same lesson as `MIGRATE-001`: **a stub cannot adjudicate a calling convention.** Both fakes are replaced by one `env.stubCore()` in `Tests/env_togbank.lua` implementing AceConsole's real tokenizing behaviour including the `1e9` end-of-string sentinel, and `Tests/chatcommand_spec.lua` drives the raw text a player types. **Confirmed red:** reverting the fix fails six examples, four of which had been green against the loose stub.

- **DOC-003: the P2P collect window was documented as 10 seconds and is 60** -- six times the stated value, in three places: `Modules/P2PSession.lua:7` and `:9` (the module header's phase timings) and `:116` (`BeginCollectWindow`'s docstring), against `COLLECT_WINDOW = 60` at `:34`. The header is the worse pair, because it is what a reader consults before touching dispatch. **Not fixed by writing 60 three times** -- all three now name the constant, so the only way to make them wrong again is to rename it, which does not silently pass. Also corrected a second wrong model the header implied: dispatch fires at `T+W` from the **last** broadcast, not the first, because a later broadcast *extends* the window -- which is the behaviour `TIMER-001` was about, and believing otherwise is what made the stacked timer hard to see. Raised as audit finding 23; answered on the board.

- **P2P-025: the status bar's "sends in flight" indicator could never appear** -- `StatusBar.NetTxText` read `TOGBankClassic_Guild.pendingSendCount`. **Four sites decrement that counter and nothing anywhere increments it**, so it sat at `0` for the life of every session, and the function returns `""` the moment it reads `0`. The `Tx:n/3` readout therefore never rendered, at any load, in any release -- and the failure is invisible by construction, because an empty string is exactly what "no sends in flight" is supposed to look like. Anyone watching the status bar to see whether a sync was moving saw nothing, always.

  **The send cap itself was never affected**, which is the reassuring half and worth stating so nobody hardens the wrong thing: the cap is enforced against `P2PSession.activeSends` (`Chat.lua:477`, `:605`), which is live and correct. Nothing floods.

  **The dead counter itself is now gone from `Modules/Guild.lua`**, and the proof that this was safe is stronger than the one it was deferred on. A peer review enumerated the sites by reading and found a **fifth** read of `pendingSendTimeouts` that the first pass missed -- `Guild.lua:2753`, `local isP2PSend = self.pendingSendTimeouts and self.pendingSendTimeouts[norm] ~= nil`. That is a **decision, not a cleanup**, and `releaseP2PSlot` wrapped its *entire body* in `if isP2PSend then`. So the helper and its four call sites were dead **at the guard** rather than at the counter -- a no-op by control flow, which is far easier to be certain of than reasoning about a decrement on a zero counter. Removed: both declarations, two identical dead cleanup blocks in the no-change paths, the `elseif pendingSendCount > 0` legacy branch in the send-complete callback, and `isP2PSend` / `releaseP2PSlot` with all four calls. `MAX_PENDING_SENDS` stays -- `Chat.lua` and the status bar both read it.

  **The stale comment was the real hazard**, and it is the reason this was not left alone: `Guild.lua:2749-2752` described a "P2P backoff timer path" that sets the registry "alongside `pendingSendCount++`". No such path exists. An accurate description of deleted code, sitting directly above the flag it describes, makes a reader conclude the registry is populated somewhere they simply have not looked yet.

  The underlying shape is **one number with five spellings** -- the sum over `activeSends` was hand-written at four call sites (`P2PSession.lua`, twice; `Chat.lua`, twice) and the status bar read a fifth, dead source. All five now call `P2PSession:GetActiveSendTotal()`. Pinned by `Tests/statusbar_spec.lua`, which drives the *rendering* path with sends in flight -- asserting `""` when idle would have passed against the bug throughout -- and which was **confirmed red** by restoring the old read. Locations: `Modules/UI/StatusBar.lua`, `Modules/P2PSession.lua`, `Modules/Chat.lua`.

- **The `TIMER-001` class guard did not cover two of the files that schedule timers** -- `Tests/timers_spec.lua` listed "every module that schedules anything" by hand, and the list was compiled from the files the audit finding happened to name. It omitted `Modules/Database.lua` (`C_Timer.After` at `:47`, `:338`) and `Modules/UI/StatusBar.lua` (`C_Timer.NewTicker` at `:414`). That is the same defect the guard exists to catch: coverage that looks complete and is not, so a clean run proves less than it appears to.

  The file set is now **derived from `TOGBankClassic.toc`**, which is the one list that cannot silently omit a module -- a file missing from it does not load in game -- so a new module is covered the moment it ships. The parse is itself pinned, because a `.toc` read that silently returned empty would make every assertion in the file pass without reading a line. Verified by breaking `Database.lua` on purpose and watching the sweep fail. **Result: no captured `C_Timer.After` return anywhere in the shipped source**, established by machine over every first-party file rather than by reading some of them.

- **ITEM-005: one bad item wedged the entire inventory load** — `Item:GetItems` increments `pendingAsync` before `Item.CreateFromItemID`, but **seven** failure branches incremented `processed` and called `checkComplete()` without ever decrementing it. Since `checkComplete` requires `pendingAsync == 0`, a single item taking any of those paths left the counter stuck above zero and the callback never fired — for the **whole batch**, discarding every healthy item alongside the bad one. The symptom was the Inventory window sitting on "Loading items…" forever. All seven now route through one `abandonAsync()` helper, so an eighth branch cannot reintroduce the leak by forgetting a line. Added a 10s watchdog for the other stall: an item whose `ContinueOnItemLoad` is accepted but never fires (an id the server never resolves) has nothing to decrement the counter, and the Blizzard API provides no error or timeout — it now delivers what did load rather than nothing. Also reworded the `TRACE-9` diagnostic, which shipped reading `FOUND CORRUPTION … THIS IS THE BUG!` and pointed at the wrong thing: a nil `itemData.itemID` was never the bug, failing to release the slot afterwards was. Location: `Modules/Item.lua`.

- **ACQ-004: a refused send was reported as delivered** — raised by AceCommQueue-1.0's owner after auditing this addon's call sites against v1.0.5, and confirmed here before changing anything. Three separate defects:

  `Modules/Guild.lua` compared the callback's 4th argument against a `SendAddonMessageResult` enum table. That argument is a **boolean** — the enum is lost two layers down (ChatThrottleLib retries only `AddonMessageThrottle`; AceComm's `ctlCallback` declares two parameters and drops the enum) — so `isThrottled` could never be true and the throttled counter had always been `0`. The comparisons are **deleted** rather than corrected, because no value of argument 4 could ever satisfy them, and the counter is removed with them: a permanent `0` printed in the send summary read as "no throttling occurred" while measuring nothing.

  `Modules/RequestLog.lua` assigned `SendCommMessage`'s return value and logged it. Neither AceComm nor AceCommQueue returns anything, so it had been printing `nil` since it was written while reading like a delivery result. This is the `togbank-rm` ALERT mutation broadcast, so a silent refusal diverges every member's request list permanently; it now passes a callback and surfaces a refusal as a player-visible error.

  Two `togbank-hl` sends passed argument-ignoring callbacks, which is also how a caller tells AceCommQueue "I will handle the verdict myself" — so the library deliberately would not report those refusals on our behalf. Both now accept the arguments, release the collision guard on refusal as well as completion (holding it after a failure blocked every later broadcast), and this closes **DOC-001**: the comment claimed the guard cleared "once the final chunk is confirmed sent by CTL", which the code could not previously determine.

  A fourth site was found by the library reporting a real loss in-game: `togbank-ri` request-index chunks passed no callback. That one matters disproportionately because the index is **chunked** — a receiver cannot tell a short index from a complete one, so a dropped chunk leaves them permanently unaware of those request ids and they never re-query. Locations: `Modules/Guild.lua`, `Modules/RequestLog.lua`, `Modules/Events.lua`.

- **EVENT-001: real-time online/offline tracking has never worked** — `Events:CHAT_MSG_SYSTEM` was declared as `function TOGBankClassic_Events:CHAT_MSG_SYSTEM(message)`, with no leading parameter to absorb the event name. AceEvent dispatches as `fn(eventName, ...)` — verified in `Ace3/AceEvent-3.0/AceEvent-3.0.lua:120` and `CallbackHandler-1.0.lua:54` — so `message` received the literal string `"CHAT_MSG_SYSTEM"`, every pattern match failed, and the handler silently did nothing in **every release the addon has ever shipped**. The code above it called this "the PRIMARY method for tracking online/offline state changes in real-time". Consequently `onlineMembers` only refreshed on a full `GUILD_ROSTER_UPDATE` sweep, degrading `Core:SendWhisper`'s online gate, banker selection in `Guild:RequestHashListFromBanker` and `Guild:QueryAltPullBased`, and the anti-spam guard that stops repeated whispers to an offline player. Location: `Modules/Events.lua`.

- **ROSTER-002: stale ex-banker entries are dropped when the departure is announced** — zero-data stubs for characters who left the banker roster lingered as permanent "HLR pending" rows, swept up only by a bespoke pass in `RebuildBankerRoster`. `Guild:_RefreshFromRosterLib` now wipes `memberRoster` and rebuilds it from `lib:GetAllMembers()`, so TOGBank holds exactly what the library holds and cannot accumulate stale entries of its own. Location: `Modules/Guild.lua:1757`.

  **This entry previously said "structurally impossible" and credited it to the library wiping and rebuilding "on every update". That was wrong, and the correction matters because it changes what the guarantee actually is.** LibGuildRoster is **build-once**: `LibGuildRoster-1.0.lua:1587` states the roster is never rebuilt, and `:1613` returns early from `GUILD_ROSTER_UPDATE` the moment it is initialized. It constructs the roster during the login stream and then maintains membership from `CHAT_MSG_SYSTEM` alone (`ERR_GUILD_JOIN_S`, `ERR_GUILD_LEAVE_S`, `ERR_GUILD_REMOVE_SS`).

  So the real guarantee is chat parsing plus a fresh build at the next login, which is weaker than "impossible" and worth stating honestly: a departure whose system message is never delivered persists in the roster until relog. The spec was rewritten to match, because it had been asserting the wrong mechanism. It emptied the fake roster and fired `GUILD_ROSTER_UPDATE`, which build-once ignores, so the ex-member survived and the failure read as a TOGBank bug when TOGBank was correct. It now announces the departure in chat and asserts removal through that path (`Tests/guildroster_integration_spec.lua`).

- **The offline suite is green for the first time: 473 passing, 0 failing.** It had been carrying 13 deliberately-failing specs, each written against the behaviour the code *should* have and pinning an open finding from `docs/AUDIT_2026-08-03.md`. Every one is now fixed in the code rather than by weakening an assertion.

  **`TIMER-001`** -- `C_Timer.After` returns nothing, so the four cancellable timers in `Modules/P2PSession.lua` stored nil and every `:Cancel()` sat behind an `if timer then` guard that was always false. A cancel that never happened was indistinguishable from one that did. The harmful instance: extending the collect window STACKED a second timer instead of replacing the first, so `Dispatch` fired at the original deadline -- discarding every offer that arrived during the extension -- and then fired again with the window already closed. On a busy login, where hash-list broadcasts arrive in bursts and re-open the window repeatedly, that cost real offers every time. All four moved to `C_Timer.NewTimer`; genuinely fire-and-forget `After` calls were left alone.

  **`TIMER-001` was then found to be only HALF fixed, by an outside review, and the other half was worse.** The finding named three further sites that the suite does not reach -- `Chat.lua` (the 5s peer timeout and the 15s ACK fallback) and `Guild.lua` (`PEER_RESPONSE_TIMEOUT`) -- and they were left on `C_Timer.After` because the failing specs only covered `P2PSession.lua`. Green was treated as evidence when no spec went near those files, and a comment naming `TIMER-001` was added to the fixed file, which is exactly what would stop the next reader looking. All three are now `NewTimer`.

  **The cause sits one step upstream of where the finding pointed, and that matters for anyone fixing a fourth site.** It is not that `:Cancel()` is a no-op. `After` returns nothing, so the assignment stores nil, and **a Lua table cannot hold a nil value -- so the key is never created.** `pendingP2PTimeouts` and `pendingP2PFallbackTimeouts` were therefore permanently EMPTY, and all five `if tbl[norm] then` cancel guards were permanently false. Anyone fixing the `:Cancel()` call would have changed nothing.

  **Why it was harmful rather than merely dead:** `BroadcastP2PRequest` has no in-flight guard, so a second request for the same alt inside the window re-populates the key. The orphaned timer then fires, sees the guard as true, and tears down the **new** request -- clearing `pendingP2PRequests`, `pendingAltRequests`, `expectedHashes` and `expectedHashUpdatedAt`, recording a banker fallback, and calling `AdvanceCandidate` on a session it was never armed for. A live delta sync abandoned and blamed on a timeout belonging to a request that had already succeeded. The 15s one is the worse of the two, simply because the window is longer.

  **`P2P-024`** -- `TryAcquireSendSlot` scheduled an unconditional 210s release. A send that completed normally released at completion **and** again when its stale safety timer fired, by which point the slot belonged to a different, later send from the same requester. The `> 0` guard prevents underflow but says nothing about over-release, so `MAX_ACTIVE_SENDS = 3` was quietly exceeded under sustained load. Each acquisition now carries a generation token; the real release consumes it, and the safety timer only acts if its own token is still outstanding.

  **`MIGRATE-001` is REFUTED, and the "fix" for it was reverted before release.** The finding said the migration called `ComputeInventoryHash(bank, bags, money)` against a signature of `(bank, bags, mail, money)`, dropping money. It does not survive reading the callee. `Core:ComputeInventoryHash` is a one-line forwarder, and **its parameter names are one caller's spelling, not the contract**: the behaviour is `DeltaComms:ComputeInventoryHash(bank, bags, mailOrMoney, money)`, which documents *both* conventions at `DeltaComms.lua:150-152` and, in the branch a `(bank, bags, ...)` call reaches, does `local actualMoney = mailOrMoney or 0` -- reading the **third** argument as money, with no type check. The three-argument call was correct.

  **Changing it to four arguments was a regression that would have shipped**, caught by an outside review (`docs/AUDIT.md` finding 25). Passing `alt.mail` there means `alt.mail` is read as money: nil for the pre-v0.8 saves this migration targets, so money is silently dropped from the hash and the real fourth argument is never read at all; and where an alt does carry mail, `tostring()` on a table yields **an address**, so the migrated hash differs on every login and matches nothing -- including itself an hour earlier. That is precisely the "re-syncs forever" failure the finding described, arriving as a consequence of the fix rather than of the bug. Reverted, with the calling convention documented at the call site so it is not "corrected" again.

  **The spec is why this got through, and that is the sharper half.** `Tests/database_spec.lua` replaced `TOGBankClassic_Core` wholesale with a stub whose third parameter it *named* `mail`, then asserted money must arrive in the fourth -- the spec asserting its own stub's parameter names back at itself. **A stub cannot adjudicate a calling convention.** It now asserts the real contract, driven through the real implementation.

  **The first replacement control could not fail either, and a further review round caught that too.** It asserted "the same inputs hash the same twice" while passing a **number** in every call -- so it never exercised the failing input -- and even with a table it could not have detected one, because `tostring` on a single table returns the same string for the life of the process. **An address only varies between sessions or between distinct table instances.** The property is that the hash depends on the **value** of its inputs, never on their **identity**. The spec now hashes two structurally identical but distinct tables and asserts they agree, and separately puts a table in the money slot and asserts the result matches hashing `0`. **That example was confirmed red before the fix** -- temporarily restoring the old line produced two differing hashes (`1070785157` against `1784462064`) -- rather than assumed to be meaningful.

- **`DeltaComms:ComputeInventoryHash` now type-guards the money slot**, which removes the hazard the revert above only worked around. The parameter is positional and overloaded (`mailOrMoney`), and `or 0` accepted a table without complaint, so `tostring()` could bake a table address into the hash from *any* caller -- reverting one call site fixed only the caller that happened to be wrong. A non-number now hashes as `0`. Location: `Modules/DeltaComms.lua`.

- **The legacy hash migration now produces the same hash a scan does, which is the half of `MIGRATE-001` that was real.** The arity claim was refuted above; this is the part that stood, and it is the part with a user-visible cost.

  `ComputeInventoryHash` has two branches that emit **different strings for the same character**: the aggregated branch emits `"I:"..hashItems(items)`, the container branch emits `"B:".."` and `"G:".."`. The migration passed containers, so a migrated character got a hash **nothing else in the addon could reproduce** -- `IsAltSyncPending` saw a mismatch on every comparison, forever, for that character.

  **The migration was the last caller of the container branch.** Every live producer already used the aggregated form -- `Bank.lua:345`, `Chat.lua:435`, `DeltaComms.lua:1325` -- so this call site was the odd one out rather than the standard. It now aggregates bank + bags + mail through `Item:Aggregate` and hashes the resulting array, matching `Bank:Scan` exactly, **including mail and including the merge**: an item held in both bank and bags must collapse to one row, or a different aggregation reintroduces the same divergence in a new form. Location: `Modules/Database.lua`.

  Pinned by a spec that first asserts the two conventions still disagree -- so it cannot pass by accident if the branches ever converge -- and then asserts the migration lands on the scan's value.

- **More discarded work removed from `Modules/DeltaComms.lua`.** `usedFallback` was set on the ID-only match path and never read -- the `fallbackMatches` counter beside it is the fact that is actually consumed. Three `= nil` initialisers that were immediately overwritten are gone. And `hasOnlineBanker` in the fast-fill path is computed by two passes -- **including a `GuildRoster()` server refresh and a full `GetNumGuildMembers()` scan on the miss path** -- and then never read: the loop below queries every missing alt regardless. That one is **kept and now logged rather than deleted**, because `GuildRoster()` is a side effect on the server and whether the refresh is still wanted there is a decision rather than a cleanup.

  **`DEBUG-001`** -- `SYSTEM` and `FULFILL` were being passed as debug categories by thirteen real call sites while not existing in `DEBUG_CATEGORY`, and `MIGRATION` was used where the registered tag is `MIGRATE`. An unrecognised value was treated as the format string, shifting every argument: players saw a raw `%d` and the real format string printed as data. Both categories are now registered across all three registries that must agree (`Constants.lua`, `Database:Init`'s defaults, `Options.CATEGORY_META`), `HASH-ADOPT` is registered under `SYNC`, and the typo is corrected. Separately, `Output:Debug` now detects a tag by its SHAPE rather than by registry membership -- an unregistered tag used to fall through and become the format string, contradicting the documented opt-out model where new tags auto-show.

  **`LOG-001`, fixed as a consequence rather than by direct repair.** `GarbageCollectPersistentLog` ends with a `Debug()` call and `Log()` appends every DEBUG message to the persistent log, so collection wrote an entry into the log it had just collected: it could never drain to empty and each pass seeded the next. That call passes `SYSTEM`, which was not a category -- so it took the uncategorised branch, which logs unconditionally. Registering `SYSTEM` puts it behind `IsCategoryEnabled`, and it defaults to off.

  **`ITEM-006`** -- `IsUnique` called `CreateFrame` on every invocation. WoW frames cannot be destroyed, so each call leaked one and clobbered the shared global name `scanTip`, handing any other addon reading it whichever frame we created last. Scanning a large bank calls this per item, so the leak scaled with the thing the addon exists to do. Created once and reused, under an addon-prefixed name. Also `ITEM_UNIQUE` is a localized string and was being used as a Lua pattern; it is now a plain find, so a locale whose wording contains a magic character does not silently stop matching.

  **`EVENT-002`** -- `PLAYER_LOGOUT`, `GUILD_ROSTER_UPDATE` and `PLAYER_ENTERING_WORLD` were registered and never unregistered, so after `OnDisable` the addon kept handling all three.

  **`PROTO-001`** -- `Guild:GetVersion` derived its comparable number by stripping the dots, producing an integer whose magnitude depends on DIGIT COUNT rather than precedence: `1.10.0` encoded as 1100 and `2.0.0` as 200, so a major-version bump ranked below a two-digit minor and protocol negotiation picked the older peer as authoritative. `1.3.2` against `1.10.0` happens to order correctly, which is what let it survive. Now parsed into fixed-width fields; the old and new encodings stay correctly ordered across the migration boundary, so a mixed-version guild is unaffected.

  **`REQ-004`** -- `Bank:FindItemsByName` returned empty whenever the name was nil or empty, even with a valid `itemID`, contradicting the ID-primacy rule `REQ-001` established and breaking the exact path `REQ-001` added for same-name variants: an ID-only lookup reported the item as not banked.

  **`DB-002`** -- `Database:ResetPlayer` dereferenced `faction[name].alts` with no guard on `faction[name]`, so resetting for a guild the addon had never stored raised a Lua error where the correct answer is "nothing to reset".

  **`BANK-002`** -- `TOGBankClassic_Bank = { ... }` at file scope captured the addon varargs, so the module table was born holding two phantom array entries.

- **`ITEM-007`: the cold-cache fallback discarded the item type it had just fetched** -- found while clearing a lint warning, not by a test. In `Item:GetItems`, the `GetItemInfoInstant` fallback named its returns `itemClassId`/`itemSubClassId`, shadowing the outer pair from the `GetItemInfo` call above -- which are nil there **by definition**, because a nil name from that call is what selects this branch. So the fallback stored `class = nil, subClass = nil` and threw away the values it had successfully fetched. Silent: the row still rendered, it just sorted and filtered as untyped. Location: `Modules/Item.lua`.

- **Dead scaffolding removed from `Modules/Guild.lua`, all of it found by clearing linter warnings rather than by a test.** Each was code that computed something and discarded it, which reads as live logic to the next person:

  **The wipe-recovery rate-limit bypass did not exist.** A loop walked every roster alt to compute `isWipeRecovery` under the comment *"Bypass rate limiting for bulk requests when user has blank DB"*, and nothing ever read the result. A user with a wiped database was rate-limited exactly like anyone else while the code claimed otherwise. The same shape as `P2P-025`. Removed rather than left in place -- if the bypass is wanted it has to be written, not restored as a flag.

  **`WipeMine` built a guild announcement it never sent** (*"I wiped all my addon data from &lt;guild&gt;."*). Worse than dead: the local was named `wipe`, which **shadowed the WoW `wipe()` global** for the rest of that scope, so any later code there calling `wipe(t)` would have tried to call a string.

  **`Share`'s `requestsMode` argument has never reached the send path** -- it was defaulted into a local nothing read. The parameter is still accepted so call sites are unaffected, and it is now documented as inert rather than looking wired.

  **`useDelta`** was set false, set true, and never read: DELTA-ONLY means every send is a delta, so the flag had nothing left to decide. **`senderIsBanker`** was computed and unused.

  Also cleaned: a stale `lastHave` shadow, a `name` shadow inside the banker-lookup loop, and an `incomingHasMail` redefinition whose debug line was reading the *outer* value.

- **BANKSLOT-001: the bank slot counts were hardcoded, wrong, and the offline env asserted a fourth wrong value on top of them** -- three numbers, three different places, none of them read from the client.

  `ItemHighlight:UpdateBankHighlighting` iterated a literal `1, 28` for the general bank slots and `5, 11` for the bank bags, with a comment stating that range as fact. **Measurement on a live Classic Era client (2026-09-09) proved both wrong**: `NUM_BANKGENERIC_SLOTS = 24`, `NUM_BAG_SLOTS = 4`, `NUM_BANKBAGSLOTS = 6` -- so the general loop ran four slots too many and the bag loop one bag too many. Neither overran harmfully, because `GetContainerItemInfo` returns nil for a slot that does not exist and `GetBankSlotButton` finds no `BankFrameItem25`; it was wasted work behind a false statement. Both loops now ask the client the way Blizzard's own `BankFrame.lua` does, with the measured Era numbers as fallbacks only.

  **The shape was wrong regardless of the values, and that is the part worth keeping**: this addon ships Era and TBC from one source tree and the two need not agree, so a literal is the cross-flavour answer to a per-flavour question. Reading the global means each client answers for itself.

  **These constants cannot be read from Blizzard's source at all.** `Blizzard_FrameXMLBase/Classic/Constants.lua` has `NUM_BANKGENERIC_SLOTS = Constants.InventoryConstants.NumGenericBankSlots`, and the generated documentation defines *that* as `Value = BANK_NUM_GENERIC_SLOTS` -- a symbol the engine supplies. The constant points at the docs and the docs point back at the constant, identically in the `classic_era` and `classic_anniversary` trees. A live client is the only route, which is why the test harness refused to guess it and asked us for it instead.

  **`Tests/env_togbank.lua` was itself asserting a guess.** It defined `NUM_BANKGENERIC_SLOTS = 28` -- invented here, four slots off, and the number every bank-scanning spec had been measured against. Corrected to the measured `24`, `NUM_BANKBAGSLOTS = 6` added (the env never defined it, so `ItemHighlight`'s fallback was the only thing being exercised), and both carry the measurement date and a note that TBC must not be assumed to match. The suite is 713 passing with the corrected values. Locations: `Modules/ItemHighlight.lua`, `Tests/env_togbank.lua`.

  Still open, and blocked on the operator rather than on us: **the TBC value is unknown.** One line on a TBC client answers it -- `/run local v,b,d,i=GetBuildInfo() print(v.." iface "..i.." generic="..tostring(NUM_BANKGENERIC_SLOTS).." bankbags="..tostring(NUM_BANKBAGSLOTS).." bags="..tostring(NUM_BAG_SLOTS))` -- and no bank visit or banker character is needed, since these are load-time constants.

### New Features

- **The bankers block is now callable by other addons: `TOGBankClassic_TooltipBankerInfo:AppendTo(tooltip, itemId)`** — it returns `true` if it added lines, `false` otherwise, and never raises, so a caller mid-tooltip with no item context is safe. Our own `OnTooltipSetItem` is now a four-line adapter that pulls the id out of the link and calls it, so there is exactly one implementation of the layout.

  The renderer had been a file-local closure reachable only through that hook, and the hook only fires for a tooltip carrying a real **item**. TOGProfessionMaster draws recipe tooltips for the roughly one third of recipes that are trainer-taught and have no teaching item at all — built from `AddLine` calls — so the block was silently absent on exactly the tooltips where a player is asking "can I get these reagents from the bank?". They had worked around it by rebuilding our block from `TOGBankClassic_Guild` themselves.

  Adopting it caught what the workaround cost, which was more than the expected "a restyle here stops matching there": the two had already diverged in **data**, not layout. Their copy walked designated bankers where we walk every rostered alt, showed the raw `"Name-Realm"` where we strip the realm, sorted by name where we sort by stock, and took only the first matching entry where we sum — so a banker holding three stacks of a reagent was reported as one stack, both in their tooltip and in their request dialog's stock cap. Fixed on their side; recorded here because it is the argument for exposing the renderer rather than against it.

  Also fixed while the file was open: the block's `AddLine` calls did not pass the tooltip **wrap** flag, which defaults to `false`. An unwrapped line ignores the client's engine-side preset width and stretches the shared `GameTooltip`, dragging every other addon's content out with it. The two `AddDoubleLine` calls take no such flag and need none — a character name and a stack count are short by construction. Specs: `Tests/tooltipbankerinfo_spec.lua` (14), one of which drives the hook and asserts it renders *through* `AppendTo`, so a copy grown back inside the hook fails rather than drifting silently. Raised as `docs/DEPENDENCY_CONTRACTS.md` §1 by TOGProfessionMaster on 2026-08-06. Location: `Modules/TooltipBankerInfo.lua`.

- **ROSTER-003: LibGuildRoster-1.0 is now a required dependency** — declared in both TOCs (folder name `GuildRoster`) and in `.pkgmeta` (CurseForge slug `libguildroster`). The two spellings differ deliberately and each fails silently in its own way — a wrong slug skips auto-install, a wrong folder name breaks load order — so both are asserted by spec. The library owns its own `PLAYER_LOGIN` / `GUILD_ROSTER_UPDATE` / `CHAT_MSG_SYSTEM` registration, which is what turns `EVENT-001` from a fixed instance into a fixed *class*: a consumer can no longer wire that event up incorrectly and have nothing notice.

  `Guild:_RefreshFromRosterLib` builds `memberRoster` from `lib:GetAllMembers()` / `GetMember()`, falling back to the legacy `GetGuildRosterInfo` scan when the library is absent or has not yet stabilised. `Guild:InitRosterCallbacks` subscribes to `OnMemberOnline` / `OnMemberOffline` / `OnMemberJoined` / `OnMemberLeft`. Banker identification — the `gbank` tag and the `VIEWBANK-001` view-only markers — deliberately **stays in this addon**; the library's job is to hand over the raw note fields, which is the correct boundary. Locations: `Modules/Guild.lua`, `Modules/Events.lua`, `Core.lua`.

  The whisper-failure signal (`"No player named X is currently playing"`) also stays here: it is `ERR_CHAT_PLAYER_NOT_FOUND_S`, which is **not** in the set LibGuildRoster matches. Deleting the handler outright would have fixed `EVENT-001` while silently dropping the one signal that stops the addon whispering someone who is not logged in.

- **ACQ-001: AceCommQueue-1.0 is a declared dependency, no longer vendored** — `Libs/AceCommQueue-1.0/` is deleted; the library is declared in both TOCs and `.pkgmeta` (slug `acecommqueue`). The shipped copy had drifted to MINOR 2 while the standalone reached 5, and MINOR 5 is where a refused send is finally reported as failed rather than delivered — so the `ACQ-004` fixes above would have been trusting a signal the embedded copy does not send. Two specs guard against a vendored copy returning.

- **ItemDB and DeltaSync are now declared dependencies** -- both TOCs gain `ItemDB, DeltaSync` on the `## Dependencies:` line and `.pkgmeta` gains the CurseForge slugs `libitemdb` and `deltasync`.

  **ItemDB is the one that was actually broken.** `docs/INVENTORY_V2.md` section 4 is explicit that rendering "asks IDB, never the wire": V2 stores integer tuples and derives the link at render time, so the library is what the whole storage rework rests on. It was not declared anywhere, and `Modules/Inventory/Resolve.lua` asks for it with `LibStub("LibItemDB-1.0", true)` -- the optional form, which returns nil rather than raising. On any install without ItemDB present, step 1 of the resolution chain never answered and every lookup fell through to `GetItemInfoInstant` or the "Item #12345" placeholder. That is exactly the cold-cache dependence the rework exists to delete, arriving silently, and nothing in the addon or the suite would have reported it.

  **The two spellings differ on purpose and each fails silently in its own way**, which is why both are now pinned by spec: the TOC takes the addon FOLDER name (`ItemDB`, `DeltaSync`) and a wrong one breaks load order, while `.pkgmeta` takes the CurseForge SLUG (`libitemdb`, `deltasync`) and a wrong one just skips auto-install. The slugs were taken from sibling consumers rather than guessed -- Dibs and TOGProfessionMaster both ship `libitemdb` for the folder `ItemDB`. This is the same folder-vs-slug trap already documented for `GuildRoster`/`libguildroster`. Four specs in `Tests/wiring_spec.lua` assert both spellings in both flavours plus the TOC lockstep rule.

  DeltaSync is declared ahead of its use: the migration off `Modules/DeltaComms.lua` and `Modules/P2PSession.lua` has not started, so nothing calls it yet.

- **Both TOC files stripped of comments** -- the header comments explaining library policy, load order and the INV2 module set are removed from `TOGBankClassic.toc` and `TOGBankClassic_BCC.toc`. They are duplicated in `docs/INVENTORY_V2.md` and this changelog, and the TOC ships to every player.

- **ALPHA-001: per-window transparency sliders** (requested by Vishiswaz) — a new **Appearance** tab in the options panel with one opacity slider per window: Inventory, Search, Requests, Donations and Mail Viewer. Changes apply immediately to a window that is already open. Account-wide, not per-character: it is a display preference with no per-character meaning, and setting it five times per alt is the chore the request was about. Window *positions* stay per-character. Locations: `Modules/UI.lua`, `Modules/Options.lua`, `Modules/UI/*.lua`.

  **Only the window chrome fades** — backdrop, border, title-bar art and the status bar — never the contents. `frame:SetAlpha()` would have been one line but it cascades to every child, so at 50% the item icons, stack counts and labels fade too. Fading only the chrome is what makes a see-through window still usable.

  **100% is now genuinely opaque, which is more solid than v1.3.2 looked.** The backdrop's parchment texture carries its own per-pixel alpha and `SetBackdropColor` multiplies over it, so a half-transparent parchment pixel stayed half-transparent no matter what alpha was passed — the slider could never reach solid. A black backing layer at `BACKGROUND` sublevel -8 scales with the same slider. Anyone who preferred the old lighter look can reproduce it from the slider; the mechanism is the one already proven in FGI.

  Two subtleties worth recording. The slider floors at 10% rather than 0 — an invisible window is one a player cannot find again to fix. And `Requests` releases and recreates its window on a banker-status change, so `UI:ClearWindowAlpha` resets the chrome to opaque *before* the release: AceGUI's frame pool is shared by every addon using the library, and a faded frame returned to it can reappear as somebody else's window carrying our black slab. 32 specs in `Tests/windowalpha_spec.lua`, run against the real AceGUI-3.0 rather than a stub.

- **CMD-002: `/togbank dev wipeall` was refused while `/togbank wipeall` quietly worked, so the guild-wide destructive reset sat one word closer to hand than intended.** A dev command must be declared in **two** places -- `COMMAND_REGISTRY` and `DEV_COMMAND_NAMES` -- and the dispatch loop sorts every registry entry into one bucket or the other. A command missing from the names set therefore does not fail to register: it registers as **top-level**. `wipeall` was documented as `/togbank dev wipeall`, was in the registry, and was absent from the set.

  Found by a guard written for a different instance of the same defect: `/togbank dev bandwidth`, added in this release, had it too and the symptom pointed away from the cause -- "not a valid command" reads as the command not existing rather than as being filed in the wrong drawer. A dead `test` entry naming a command deleted in the step-10 sweep went at the same time.

  `Tests/devcommandwiring_spec.lua` now cross-checks the two tables against the `/togbank dev` commands **documented in `DEV_COMMANDS.md`**, which is the third copy and the one a user actually follows. It is a source-text guard deliberately: both dispatch tables are file-locals, and the alternative -- driving each command to see if it is accepted -- would **execute** them, `wipeall` included. Two rounds of tightening were needed, and both are recorded in the spec: the first pattern matched prose mentions, the second still matched a **removal notice written in list form** (*"`/togbank dev test` no longer exists"*), which has the exact shape of a definition and says the opposite.

- **INV2-DOC-001 CLOSED: the bandwidth figures are measured and back on the store page, at 85%.** Run against a live guild's own bank characters, 4 characters and 227 rows: **19,740 bytes of legacy link payload against 2,873 bytes of tuples**, an 85% reduction.

  **The per-character spread is the part that makes it publishable rather than a lucky sample:** 85.7%, 84.4%, 85.8%, 85.3%, across inventories from 15 rows to 101. A figure that held within 1.4 points across a 7x size range is a property of the encoding, not of the sample.

  **It also corrects the claim that was pulled.** The old page said *"1-10% of bandwidth compared to full snapshots"* -- implying a 90-99% saving -- and it was removed in the v1.3.2 sweep precisely because nobody could show where it came from. The real number is 85%, which is lower than what was previously advertised. The page now states the measured figure and the sample it came from.

- **`/togbank dev bandwidth`** -- measures the V2 tuple wire against the legacy link wire on the records this client actually holds, and exists because the obvious method cannot work. `INV2-DOC-001` requires the CurseForge bandwidth figures to come from a real guild rather than a synthetic payload, and the natural route -- reading `togbank-d4` byte counts out of a live `COMMS` log -- delivers nothing: that payload is only sent when a peer is genuinely behind, so a healthy guild emits no sample at all. Two ~200-line live captures during this rollout contained zero of them.

  **Neither side of the comparison is invented.** The V2 figure is real `Wire.encode` output through `Wire.estimateSize`; the legacy figure is built from **the same rows** with each item's link resolved through `Resolve.describe`. One inventory measured two ways, rather than a measurement against an assumption about how long an item link is -- which is exactly the synthetic payload the item forbids. The reduction is rounded **down**, so nothing published from it can overstate the saving. Documented in `docs/DEV_COMMANDS.md`. Locations: `Modules/Chat.lua`.

- **`/togbank dev rostercheck`** — in-game verification for the migration. Compares the library against the WoW API directly (the only genuinely independent check of the three), then our cache against the library, then reports presence transitions seen since login. Documented in `docs/DEV_COMMANDS.md`.

<!-- MOVED-TO-ARCHIVE 2026-09-10: a second, longer write-up of HASH-CANON-002, HASH-CANON-003, the
     INV2 step 10 receiver deletion and INV2-ORDER-001 stood here. All four are already covered in
     the Bug Fixes section above -- they had been written up twice, in two separate sessions. The
     long treatment moved whole to CHANGELOG_ARCHIVE.md under "[v1.4.0] extended engineering
     detail"; nothing was deleted. -->

### Internal

- **`.luacheckrc` declared `StaticPopupDialogs` twice, and the read-only copy won.** It is in `globals` -- with a comment explaining that registering a dialog *is* writing a named field into it -- and was also in `read_globals`, which forbids field assignment. The duplicate silently defeated the deliberate declaration, so all four of `Modules/UI/Requests.lua`'s dialog registrations reported `W122 setting read-only field`: the exact warning the `globals` entry exists to prevent. Removed from `read_globals`, with a note there saying why it must not come back. `Requests.lua` now lints clean.

- **`Tests/staleformat_spec.lua`** (6 examples) pins MIGRATE-002 from both sides: one unmigrated banker earns exactly **one** line however many payloads it sends, two unmigrated bankers earn **two**, a non-banker earns none, and the debug record still counts every occurrence. **Proven red against the real mutation** -- removing the latch turned 25 payloads into 25 user-visible lines. Worth recording that the file's *first* red run was a false one: the fixture was missing `Guild:UpdateOnlineMember` and then a working envelope, so the examples failed at 0 warnings without ever reaching the branch. A red that arrives for the wrong reason proves nothing, which is why the latch was mutated deliberately afterwards.

- **`Tests/debugtab_spec.lua`** (12 examples) pins CHATWIN-001 and DEV-UX-002. The CHATWIN half drives the defect by **taking the globals away** -- `NUM_CHAT_WINDOWS` and `Constants` are nilled and restored in a `finally` -- because the absence *is* the condition under test and no fixture can reach it any other way; `.luacheckrc` declares both writable in `Tests` for the same reason `LibStub` already is. The DEV-UX half asserts **both directions** on every gate combination: level-off/category-off, level-on/category-off, level-off/category-on all warn, and only both-on confirms. Asserting the warning alone would pass for a command that always warns, which is the same false confirmation in the opposite direction.

- **The `Modules/Chat.lua` header now records WHY the channels are split**, not just what each prefix does. It had the complete prefix table and the sync sequence, and never the rationale -- so a reader could see that replies go by whisper and not that the GUILD channel being congested is the reason the whole P2P layer exists. Written from the operator's own words, with the trap stated explicitly: a COMMS log shows one GUILD broadcast followed by ten whispered replies, which reads as an amplifier and is the exact opposite -- those are ten messages *not* sent on the congested channel. It misled a reader three times in one session before being written down.

- **`Tests/suffixcarry_spec.lua`** (10 examples) pins INV2-SUFFIX-001 from both ends. Its ItemDB stub is **deliberately lossy** -- `GetSuffixLink` ignores the suffix it is handed and returns a bare link, exactly like `Resolve` step 2 on a client whose ItemDB lacks the id. A faithful stub would let the old link-parsing code pass and prove nothing, so one example asserts the fixture is actually reproducing the defect (`GetSuffixID(row.Link)` is nil) before asserting the fix reads through it. The `Suffix = 0` versus absent-field distinction gets its own example for the same reason: the two cases are one keystroke apart and the wrong one breaks legacy data rather than V2 data, where nothing would notice for a release.

- **LIBREQ-ALL-005: a comm prefix the client REFUSES to register is now reported instead of silently breaking sync** -- `TOGBankClassic_Chat:VerifyCommPrefixes()`, called at the end of `Chat:Init`. `C_ChatInfo.RegisterAddonMessagePrefix` can refuse, and until now nothing looked: AceComm registers each prefix inside `RegisterComm` and discards the result, so a refusal presented as a guild bank that simply never syncs, with no error anywhere. Location: `Modules/Chat.lua`.

  **The obvious guard would have been dead code, and that is why this was blocked on the harness rather than written months ago.** The return is a **number** from `Enum.RegisterAddonMessagePrefixResult` (`Success = 0`, `DuplicatePrefix = 1`, `InvalidPrefix = 2`, `MaxPrefixes = 3`) -- never a boolean, never nil, per Blizzard's generated `ChatInfoDocumentation.lua` for the classic_era tree (`Nilable = false`). So `if not C_ChatInfo.RegisterAddonMessagePrefix(p)` can **never** fire, because `Success` is `0` and `0` is truthy in Lua, and `result == false` never matches. Both read as guards and neither can execute. The harness stub returned `true` until `c9f3199` -- with its own comment admitting the return had never been checked against the docs -- so either guard would also have passed its spec. Writing it then would have ratified a branch that cannot run, which is worse than no guard.

  **`DuplicatePrefix` is deliberately silent, and that is the load-bearing decision.** AceComm registers our prefixes first, so re-registering to read the verdict returns `DuplicatePrefix` for all eleven, every login, forever. Treating it as failure would print eleven warnings a session, be trained out, and then a genuine `MaxPrefixes` refusal -- a client-wide cap a player running many addons can really hit -- would arrive on a channel nobody reads. Only `InvalidPrefix` and `MaxPrefixes` are loud.

  **Both failure modes are proven red, not merely covered.** `Tests/commprefix_spec.lua` (9 examples). Replacing the branch with the dead `if not result` guard reddens 3; treating `DuplicatePrefix` as a failure reddens exactly 1 -- the *"says NOTHING when the client reports DuplicatePrefix"* example, which no other assertion catches.

- **The eleven comm prefixes are registered from one list instead of eleven copy-pasted blocks** -- `TOGBankClassic_Chat.COMM_PREFIXES`, iterated to subscribe and again to verify. It is deliberately **not** derived from `COMM_PREFIX_DESCRIPTIONS`: that is a bare global, and NS-001 is a confirmed live case of another addon overwriting one of ours, so deriving registration from it would mean silently receiving nothing. `commprefix_spec` asserts the two hold the same set in both directions, so the second list cannot drift. Locations: `Modules/Chat.lua`, `Modules/Constants.lua` (new `PROTOCOL` / `PREFIX` debug tag).

- **Harness pinned to `c9f3199`** (from `f38f923`), which ships the real `RegisterAddonMessagePrefix` enum requested above, plus `GetServerTime`, `wow.pendingTimerCount()` and `wow.flushTimers()`. Suite green. **The local stand-ins for those last three are NOT yet deleted**: `Tests/env_togbank.lua` drives them from its own `M.now` clock rather than the harness's `wow.serverTimeOffset`, so removing them is the `ENV MIGRATION` work and not a side-edit.

- **INV2 step 7a: the UI reads through one accessor, and the `inventoryV2` switch is honoured in one place** -- `Guild:GetAltItems(altName)`. Six sites across three UI files open-coded *"use `alt.items` if it has anything, otherwise aggregate bank + bags + mail"*; wiring the switch would have meant repeating it six times. `INVENTORY_V2.md` 7.1 anticipated exactly this by having the V2 store expose a view in the shape the UI already consumes, so the read side needs no other change. With the switch off, behaviour is identical to before.

  **The fallback is the load-bearing part.** With `inventoryV2` on but an alt absent from the V2 store, the accessor returns the **legacy** rows rather than nothing -- during the `dualWrite` window only the local character is written to V2, while every other member's data still arrives over the legacy wire, so returning empty would blank most of the guild's inventory the instant the switch was flipped. Pinned by `Tests/altitems_spec.lua`, and the V2-read example was **confirmed red** by disabling the branch.

- **RESOLVE-001: every successfully-resolved V2 item drew as a question mark** -- `Resolve.describe`'s LibItemDB branch, the path taken when resolution *works*, hardcoded `icon = UNKNOWN_ICON`. Name, link, quality, stack count and rarity border were all correct beside it, which is exactly why it read as an icon-cache problem rather than a missing field. LibItemDB ships no icon (there is no `GetIcon` -- it carries names, quality, stats, prices and levels), so the icon comes from `GetItemInfoInstant`, chosen for the same reason the fallback step already uses it: it reads the client's **static** item data, needs no warm cache and never defers. An icon is a fixed per-item fileID, so there is nothing for the library to add and no contract to raise.

  **Icons are memoised per item id**, since an icon does not vary by suffix, enchant, stack, owner or locale: a bank holding 1,200 stacks across 400 distinct items costs 400 lookups rather than 1,200, later alts holding the same items cost none, and with Store's per-alt view cache the steady state is zero lookups per draw. Misses are remembered too -- caching only hits would mean exactly the ids that fail get retried on every rebuild. Both properties are asserted by counting calls rather than asserted in a comment.

  **The pre-existing guard could not have caught this**: `resolve_spec` asserted `d.icon ~= nil`, which the placeholder satisfies. A check that cannot distinguish the right answer from its own fallback proves nothing. Location: `Modules/Inventory/Resolve.lua`.

- **SEARCH-002: an item in a banker's mailbox was findable in one view and invisible in another** -- found while consolidating the above. Search's copy of the fallback aggregated bank + bags and **omitted mail**, while the Inventory tab's copy included it. Same character, same data, two answers, and neither view said which it was showing. Both now use `Guild:GetAltItems`, which includes mail. **This changes search results**: items sitting in a banker's mailbox now appear, and previously did not. Locations: `Modules/UI/Search.lua`, `Modules/UI/Inventory.lua`, `Modules/UI/Requests.lua`.

- **Dead link-parsing removed from Search** -- a `LINK_COLOR_RARITY` table and a `RarityFromLink()` that recovered an item's quality by parsing the colour prefix out of its link, called by nothing. Quality comes from `Info.quality`, which is resolved data rather than a display string parsed backwards, and deriving attributes from link text is the practice `INVENTORY_V2.md` section 8 exists to delete. Also removed an unused `allReqs` local and a `totalPages` that shadowed an identical value computed 90 lines above it, and blanked 13 whitespace-only lines. Locations: `Modules/UI/Search.lua`, `Modules/UI/Requests.lua`.

- **The status-bar module now follows the UI namespace rule** -- it declared `TOGBankClassic_StatusBar`, while every other UI sub-module uses `TOGBankClassic_UI_<Window>` and both linter configs already listed `TOGBankClassic_UI_StatusBar`. The code was the odd one out, so it was renamed rather than teaching the linter the wrong name. That alone cleared **31 luacheck warnings** in the file, which had been reporting its own module global as undefined on every line that touched it. Locations: `Modules/UI/StatusBar.lua`, `Modules/UI/Inventory.lua`.

- **Linter config gaps closed rather than suppressed** -- `SecondsToTime`, `IsShiftKeyDown`, `IsControlKeyDown` and `debugstack` are real client APIs that were missing from `.luacheckrc`'s `read_globals`, and upvalue-shadowing (luacheck 431/432) is now ignored there for the reason the language server already ignores it: `function(self, event)` is the universal AceGUI and frame-script idiom in this codebase, so an inner `self` shadowing an outer one is the convention rather than a mistake. **Equality between `.luacheckrc` and `.luarc.json` is explicitly not the rule** -- luacheck reports `undefined-global` with per-directory precision and the language server has it disabled outright, so copying names between them would only blunt the one tool that can still report a typo. Also removed a dead `scrollId` local in `Modules/UI/Inventory.lua` whose comment claimed it was the double-callback guard; the flag on the next line is, and always was, the whole mechanism.

- **INV2: the tuple-inventory foundation is in place, and off** — six new modules implementing the storage/wire rework designed in `docs/INVENTORY_V2.md`. `inventoryV2` defaults off; with it off nothing reaches them, and **no user behaviour changes in this release** either way — nothing reads the V2 store for display, sync, or fulfillment yet.

  | Module | Responsibility |
  | --- | --- |
  | `Modules/Switches.lua` | Dev-switch registry; each switch declares what it gates and when it should be deleted |
  | `Modules/Inventory/Record.lua` | The tuple `{id, count, suffix, enchant}`, its identity function, validation, aggregation |
  | `Modules/Inventory/Resolve.lua` | LibItemDB lookup plus the three-step fallback chain |
  | `Modules/Inventory/Store.lua` | The `TOGBankClassicInvDB` SavedVariable and the UI-compatibility view |
  | `Modules/Inventory/Scan.lua` | Containers → tuples, emitting both shapes from one walk under `dualWrite` |
  | `Modules/Inventory/Wire.lua` | Tuple encode/decode; send is switchable, receive always accepts both formats |

  **142 specs, 445 executable lines, 100% line coverage on every module.** Greenfield is the one point at which that is achievable — retrofitting reached 18% on `Guild.lua`.

  Three properties are asserted rather than assumed, because each is silent when it breaks. `Scan.parseLink` treats `item:10132::::::863` and `item:10132:0:0:0:0:0:863` as the same item — that equivalence is what makes the miscount class stop existing rather than be normalised around. Under `dualWrite` both shapes come from a **single** container walk, since a comparison across two walks could not distinguish an encoding bug from a stack that moved between passes. And an item arriving as a legacy link decodes to the same `Record.key` as the same item scanned locally, or a synced row and a scanned row would aggregate separately — the original bug reintroduced through the wire.

  `Wire.estimateSize` exists to put real figures back on the CurseForge page: `INV2-DOC-001` removed the bandwidth claims because they were unverified, and this measures rather than asserts.

- **INV2-WIRE-001: the V2 store is now fed from the live scan, behind the switch** — `Bank:Scan` mirrors each scan into `TOGBankClassicInvDB` when `inventoryV2` is on, and `Core:OnInitialize` attaches that SavedVariable. Writing only: nothing reads the V2 store, so with the switch off the addon is byte-for-byte what it was, and with it on the only change is a second table in the saved variables file.

  Three deliberate choices, each of which would be a silent data-loss bug the other way round. The mirror is wrapped in `pcall`, so a fault in brand-new code cannot abort the path every existing user depends on — the legacy scan completes and the failure is reported. It sits *after* the banker/enabled gates, so a non-banker never accumulates V2 data. And when the vault is out of reach the previously stored V2 record is **kept**, not replaced with a bags-only scan; the legacy path has always had this property and losing it would erase a character's whole vault from the guild's view on the first scan away from a banker.

  Note that the mirror currently re-walks the containers rather than sharing the legacy walk. That is the opposite of the single-walk arrangement `docs/INVENTORY_V2.md` §6.1 specifies, and it is intentional for exactly as long as the legacy path is authoritative: sharing the walk means editing it, and the property being protected here is that it is untouched. `Scan:ScanAll` already emits both shapes from one walk, so the swap is a deletion when V2 becomes the writer. Locations: `Modules/Bank.lua`, `Core.lua`.

- **`/togbank dev switches` and `/togbank dev compare`** — `switches` lists the INV2 dev switches with their live state (a dependent switch reads OFF while its parent is off, whatever its stored value says) and sets them. `compare` diffs the V2 store against the legacy one on live data.

  `compare` matches on **per-item-ID totals**, not rows: suffix variants legitimately split into separate V2 rows that a legacy link key may have merged, so a row-count comparison would flag every random-suffix item in the game. It also refuses to report agreement when there is nothing to compare — switch off, store empty, or no character in both — because a green result from a diagnostic that checked nothing is what a default-on decision would be justified by. 25 specs, including one that asserts the legacy scan result is identical with the switch on and off. Locations: `Modules/Chat.lua`, `Tests/wiring_spec.lua`.

- **The request chain now has end-to-end coverage, and it did not before** -- raised by the operator, who asked whether editing the request-mutation handler had broken request propagation. It was a fair question: that handler carries request traffic **and** used to carry an inventory branch, and the only existing coverage tested the send callback, so a break in request **receive** would not have shown up in a green suite.

  `Tests/requestchain_spec.lua` drives a mutation from one client's `AddRequest` through the real serializer and the real prefix dispatch into another client's list -- new order, cancel, complete, delete-as-tombstone, both permission refusals, and one asserting an inventory payload on the request prefix is now ignored. What crosses between the two clients is a serialised string and nothing else, so neither side can share a table reference and manufacture agreement.

  **Two of them failed for a while and were left red rather than weakened**, because a failing test is a found bug until proven otherwise. Both turned out to be the fixture: the message was being delivered **from the banker to a client the fixture had also made the banker**, and a message from yourself is correctly ignored -- indistinguishable from the merge rejecting it when all you can see is "the order stayed open". Reading the merge logic could never have explained it, because the break was upstream of the merge entirely; **instrumenting** the apply step and finding it was never reached is what settled it. The examples now assert each layer separately, so the next failure localises itself.

  Fixture facts worth knowing for any two-client spec, all paid for here: the harness clock starts at zero and request mutations order on their timestamp, so a tombstone can never be recorded (`0 > 0`); a realistic clock then reaches the pruning path; and selecting a message by "the last thing sent on that prefix" is wrong, because finalising a mutation puts further traffic on the same prefix straight after it.

- **`Tests/canonhash_spec.lua` holds the fingerprint rules as executable invariants**, built around a deliberately **wrong** value rather than a correct one. Checking that a record still holds the right number is worthless -- a path that quietly recomputes produces the right number and passes. Every no-mutation example plants a value that cannot be derived from the contents, runs a path, and asserts it survived. Proven red three ways: removing the datestamp from the fingerprint (4 examples), reinstating the no-change adoption (4, including the relaying-peer case that caused the live data loss), and pointing the change detector at the canon instead of the content hash (the churn example, verbatim).

- **33 new specs** in `Tests/guildroster_integration_spec.lua`, run against the **real** library rather than a stub. The harness gained `freshGuildRoster`, `readyGuildRoster` and `fireGuildRosterEvent`, plus two environment prerequisites now recorded in `Tests/HARNESS_CONTRACT.md` §4a/§4b: `securecallfunction` (a CallbackHandler file-scope upvalue) and the five localized `ERR_*` globals. The second is worth knowing — LibGuildRoster builds its chat patterns from those strings **at file scope**, so if they are missing when it loads it matches nothing at all, with no error. That failure looks exactly like a library defect and is not one; it cost two wrong diagnoses before the library's own spec settled it.

- **`GetNormalizedRealmName()` takes no arguments** — three call sites passed `"player"`. Harmless (the argument was ignored) but wrong, and it was the only genuine defect in a large batch of language-server warnings. Locations: `Core.lua`, `Modules/Guild.lua`.

- **`.luarc.json` brought in line with the other TOG addons** — added `redundant-parameter`, `undefined-field`, `missing-parameter`, `param-type-mismatch`, `duplicate-set-field` and `trailing-space` to `diagnostics.disable`, matching `GuildRoster/.luarc.json`. These are noise on dynamic WoW addon code: the language server cannot resolve a vararg method through a global module table, so it reported `Output:Debug(fmt, ...)` as taking zero arguments and flagged roughly a hundred correct call sites. `Tests` stays **analysed** — an earlier attempt at this excluded it via `workspace.ignoreDir`, which suppressed the symptom by giving up language-server support in the specs instead of configuring the rules that were wrong.

- **Verified in-game** on a 981-member guild: library and WoW API agree in both directions, no cache divergence, no normalization disagreement across 981 real character names, 38 bankers detected, and a live transition recorded (`online=1`, `recent: online Fartcaptain-OldBlanchy`) — the first direct evidence that real-time presence works.

## [v1.4.0] (unreleased) - extended engineering detail for the canon-hash rework

Moved out of `CHANGELOG.md` on 2026-09-10. **This is a SECOND, longer write-up of findings that
are already summarised in `CHANGELOG.md`'s v1.4.0 section** -- `HASH-CANON-002`, `HASH-CANON-003`,
the `INV2 step 10` receiver deletion and `INV2-ORDER-001` each appeared twice in that file, having
been written up in two separate sessions. The shorter treatment stays in the live changelog; this
is the long one, kept whole because it carries tables, red-proof counts and reasoning the short
version does not.

### Bug Fixes

- **HASH-CANON-002: the inventory hash was being re-minted by every client that touched it, not just by the bank character that authored it.** Diagnosed by the operator from live behaviour, in their words: *"the hash gets recomputed anytime anyone looks at the bank"*, *"they are being mutated by EVERY user"*, and *"V1 has a broadcast STORM because the hashes are ALWAYS updating"*. A hash is the **identity of a version**, so a number minted by a client that never read the bank is that client's opinion of somebody else's data -- and once advertised, peers adopt it. Three minting sites deleted, each of which looked locally reasonable:

  1. **The query path** (`Modules/Chat.lua`, PERF-005's *"compute hash on-demand if missing"*). Ran on **every incoming query about an alt** and stamped a freshly computed hash whenever one was absent, on a client that did not author the record, from whatever `alt.items` happened to hold locally. This is literally *"recomputed anytime anyone looks at the bank"*.
  2. **The no-change hash correction** (`Modules/Chat.lua`, `togbank-nochange`). Read `hash` / `hashV2` / `mailHash` off the message and wrote them over stored canon, **adopting from any sender rather than the author**. `Guild:RespondToStateSummary` is answered by any peer holding a copy, so peer A minted a number, B stored it as its own, B served it to C. **That is the propagation mechanism**, and it matches the reported sequence exactly: the banker logged off, a mutated revision-1 hash arrived from a third party, and it overwrote good V2 data. The three hash fields were removed from the **send** side too (`Modules/Guild.lua`) -- an older client still adopts whatever arrives, so refusing on receive alone leaves the loop fed from the other end. The message itself is kept; it still completes the P2P session, which is its real job.
  3. **The database migration** (`Modules/Database.lua`). Stamped both revisions so *"a migrated record advertises the same pair a scanned one does"* -- sound while a hash was a content digest, wrong once it is a version identity, because that migration runs over SavedVariables which mostly describe **other people's** bank characters received over the wire.

  **The block's own comment recorded the origin and should have been the warning:** it existed to *"fix stale inventoryHash left by the pre-DELTA-025 bug"*. A repair for one client mis-stamping became the channel by which every client restamped every other. Its justification -- *"the sender only reaches this path if our baseline matched their items, so their hash IS correct for our data"* -- argues the **data** matched and says nothing about how the sender's **number** was produced.

  **Four specs were deleted rather than re-baselined.** `syncwire_spec`'s *"adopts BOTH hash revisions from a no-change correction"* and three siblings were green, careful, and asserting a live data-loss bug as a requirement. Replaced by five asserting the opposite, including one driving a **relaying peer** (the shape that did the damage) and one covering the send side.

- **HASH-CANON-003: the hash now carries the publish datestamp, so two scans of coincidentally identical contents are two distinguishable versions.** Without it the hash identifies a *payload* rather than a *publish*, and a guild can report itself converged across a change that really happened -- which leaves *"the newer hash wins"* with nothing to compare. Locations: `Modules/DeltaComms.lua` (`ComputeCanonHash`), `Modules/Bank.lua`, `Core.lua`.

  **Three numbers now, with different jobs, and conflating any two reintroduces a bug fixed here:**

  | Field | Datestamp | Sent | Job |
  | --- | --- | --- | --- |
  | `inventoryContentHash` | no | **never** | the change detector -- decides whether to advance the datestamp |
  | `inventoryHashV2` | **yes** | yes | the canon: the identity of a version |
  | `inventoryHash` | no | yes | revision 1, frozen -- folding a datestamp in would change a number we do not own |

  **Why the split, and it answers the objection that a datestamped hash is impossible here:** a canon differs on every call by construction, so it cannot be its own change detector -- comparing against it makes every scan look like a change and republish to the whole guild, which is the storm. Compare content against content, advance the datestamp only when content moved, then mint the canon over both. An unchanged bank produces the same canon and generates no traffic. Two specs pin exactly that pair: the canon **must** differ across publish times, the content hash **must not**.

  **Bankers only, and now pinned rather than incidental.** `Bank:Scan` returns early for a character not in the banker list (`Bank.lua:152-157`) and the stamp is at `:433` -- 280 lines apart with nothing connecting them. `wiring_spec` adds a **class guard** (exactly one production site mints a hash; `Core.lua` and `DeltaComms.lua` are named as forwarder and implementation) plus a behavioural example that a non-banker's scan stamps **neither** the canon nor the content hash. That second assertion carries its own weight: a non-banker that stamped a content hash would compare against it on its next scan and believe it authored the record, so the bad state would persist instead of being one blip. **Proven red** by removing the `return` from the banker gate.

  **Known cost, stated rather than buried:** records saved before this have no `inventoryContentHash`, so the first scan after upgrading bumps the version once **per banker** -- one burst of republishes on first reload, then quiet. Continued churn past that first scan means the fix failed; category `SYNC` / tag `HASH-MATCH` now prints content and canon separately so it is visible which one is moving.

- **INV2 step 10 remainder: the legacy alt-data receiver is deleted, and ~680 lines went with it.** The 2026-09-09 directive says the legacy link format is deleted in both directions, and it was being enforced on one inventory path and not the other: `togbank-d4` dropped anything that was not a tuple payload, while a `data.type == "alt"` branch on the **`togbank-rm`** prefix handed a link-bearing legacy payload to `Guild:ReceiveAltData`, which wrote `alt.items` / `alt.bank.items` / `alt.bags.items` straight from the wire with no tuple guard at all.

  **Validated as unfed before deleting**, so nobody re-derives it: the released v1.3.2 (`4d8fe14`) sends alt inventory on `togbank-d4`, and its only `togbank-rm` sender is `RequestLog.lua:1070`, request mutations. No shipped version sends inventory on that prefix. So this was **dead code, not the source of the reported corruption** -- that was `INV2-ORDER-001` and `HASH-CANON-002`. It went because a bypass nothing currently drives is still a bypass.

  **The cascade is the part worth recording**, because it is the link complexity the rework exists to remove, falling out on its own once the receiver went:

  | Removed | Orphaned by |
  | --- | --- |
  | `Guild:ReceiveAltData` (~434 lines) | the directive |
  | Chat's `data.type == "alt"` branch | its only caller |
  | `SyncBankerHashAfterAdopt` | only called from that branch |
  | `Guild:ReconstructItemLinks` (plural) | only called from `ReceiveAltData` |
  | `ProcessItemQueue` + queue state (~130 lines) | only fed by `ReconstructItemLinks` |
  | `ThrottledUIRefresh` + `lastUIRefresh` | every caller was inside the above |

  That queue -- a concurrency cap, a batch size, a requeue path, `ContinueOnItemLoad` callbacks wrapped in `pcall`, and a repaint throttled to twice a second -- existed **only** because the legacy format shipped links and ItemStrings over the wire, so rows arrived link-less and had to be resolved slowly enough not to stutter the client. V2 sends `{id, count, suffix, enchant}` and resolves on arrival, so there is no trickle of late completions to coalesce.

  **`ReconstructItemLink` (SINGULAR) is alive and must stay** -- `Modules/UI.lua:320` and `:339` call it while drawing, for records that still carry an ItemString. The names differ by one character. `EnsureLegacyFields` also stays (`Guild.lua:603`, `:2983`, `Chat.lua:1533`).

  **`ReceiveAltData`'s one genuinely valuable part was extracted before deletion, not lost:** its DATA-004 / DATA-006 / OPTION-B checks were the only last-writer-wins logic in the addon, and reading them is what revealed the tuple path had none. That rule now lives in `Chat:ShouldApplyTuplePayload` (see `INV2-ORDER-001`).

- **The canon-hash contract is now held by an offline suite built around a deliberately WRONG value** -- `Tests/canonhash_spec.lua`, 18 examples across the five rules. The obvious test for *"the hash is not recomputed"* is to check a record still holds the **right** hash after a path runs, and that test cannot fail usefully: a path that quietly recomputes produces the right number and passes. So every no-mutation example plants a **sentinel** that provably cannot be derived from the record's contents, drives a path, and asserts the sentinel **survived**. Only a path that left the value alone can pass. (The method, and the class guard asserting the *count* of minting sites, are DeltaSync's own -- README, *"Checking yourself"*.)

  **It wires the real hash functions rather than `env.coreHashStub`, and that is load-bearing.** Every other pipeline spec stubs Core's hash surface to a fixed number, which is right for those files and fatal here: a constant hash makes *"identical contents at different times differ"* and *"unchanged contents do not churn"* **both pass by construction** -- two of the rules under test.

  **Proven red by three mutations**, each aimed at a different rule: dropping the datestamp from the canon (4 red); reinstating the deleted no-change adoption, which is the originally reported bug (4 red, including the relaying-peer case); and pointing the change detector at the canon instead of the content hash (the storm test, with its own message). That last one is the mutation a future reader is most likely to make while "tidying" the two hash fields into one.

  **Declared narrowing:** the no-change and tuple-receive examples use a pass-through checksum envelope. This file is about *which client may mint a hash*, not framing; `syncwire_spec` drives the real envelope end to end.

- **INV2-ORDER-001: a bank character's inventory could be overwritten by OLDER data, losing items that were really there.** Reported from a live guild -- two bank characters were replaced by stale contents. The V2 tuple receive path called `Store:SetAltRecords` **unconditionally**: it never compared what arrived against what was already held. The legacy receive path has always had that check (`Guild.lua:3327` and `:3362` refuse a record that is not newer), so this was a guard the new path silently lacked rather than a rule nobody had thought of. With several peers relaying the same character over P2P, **whichever snapshot arrived last won regardless of when it was authored**, so a peer holding a days-old copy overwrote a fresh one and nothing anywhere said so. Locations: `Modules/Chat.lua`, `Modules/Inventory/Wire.lua`, `Modules/Guild.lua`.

  **It could not have been fixed on its own, which is why the wire changed in the same commit.** `Wire.encode` carried `{version, alt, money, records, hash, hashV2}` and **no timestamp**, and the receiver stamped its own `GetServerTime()` on arrival -- so every record looked as though it had been published the instant this client heard of it, and there was no honest number to order by. The author's publish time is now trailing wire field 7, stamped by the same scan as both hashes (`Bank.lua:417-420`) and stored **verbatim** on receive.

  **The re-advertising half is the one that made it spread.** Every receiver re-advertises what it holds (`Guild.lua:358`, `:1033`, `:1582`) and `P2PSession` sorts candidate holders by `updatedAt` **descending** to pick the freshest (`P2PSession.lua:184-190`). With a receive-time stamp, the peer that received a snapshot *most recently* advertised the *newest* time -- so a relayed third-hand copy outranked the author's own record, and the further a copy travelled the fresher it claimed to be.

  **Ordering now lives in exactly one place**, `Chat:ShouldApplyTuplePayload`, per HASH-CANON-001 rule 7 (*"the hash says whether two clients differ; it cannot say whose is newer -- decide that at apply time, from the timestamp inside the record that arrived"*). Two deliberate choices: a **nil** author time is **accepted**, because refusing it would freeze an alt whose author is between builds while unordered is merely what already shipped; and the comparison is `>=` rather than `>`, so a retry after a lost chunk is not mistaken for a stale send. `Tests/inventoryordering_spec.lua`, 9 examples, **proven red** (2) by making the guard return true unconditionally.

  **A correction to what this project believed:** `INV2-ISOLATE-001` pins that legacy data cannot enter the V2 store, and that guard is real -- but it is about **who writes**, and says nothing about **which write wins**. It was cited as covering this and does not.

## [v1.3.2] (2026-08-03) - ElvUI & Baganator Item Highlighting, Offline Test Suite

### Bug Fixes

- **BAGANATOR-001: "Highlight needed items" did nothing when running Baganator** — Same failure as ELVUI-001 below and from the same cause: Baganator replaces the bag UI, so the Blizzard-frame fallback found only hidden buttons and `ApplyOverlay` bailed on its visibility guard. This is the path that affects the TBC install, where Baganator is the bag addon in use.

  Unlike ElvUI there is no public way to drive Baganator's search or its per-slot dimming — `Baganator.API` exposes no search setter, and the per-button `SetItemFiltered`/`SetMatchesSearch` methods live on internal mixins. The one sanctioned integration is the corner-widget API, so **the visual differs by design here**: needed items get a marker in the icon's top-left corner instead of everything else going grey. Registered via `Baganator.API.RegisterCornerWidget`, following the pattern of Baganator's own `equipment_set_icon` and CanIMogIt widgets in `API/ItemButton.lua` (lines 316-355), and refreshed through `Baganator.API.RequestItemButtonsRefresh({Baganator.Constants.RefreshReason.ItemWidgets})`.

  Three details worth recording. The `onUpdate` contract is tri-state — true shows, false hides, and **nil means "item data isn't available yet"** — so a cold item cache returns nil rather than false, which would otherwise latch the marker off until the next full refresh; ID-keyed requests skip that entirely since they need no cache. The marker uses `SetColorTexture` rather than a texture path because the Era client is missing many icon assets and a missing file renders as a blank square with no error. And `RegisterCornerWidget` asserts on a duplicate id, so registration is latched and wrapped in `pcall` — a Baganator API change degrades to the previous behaviour instead of breaking highlighting for everyone. **Not yet exercised in-game.** Locations: `Modules/ItemHighlight.lua`, `.luarc.json`.

- **BAGANATOR-001/ELVUI-001: integration latches were read out of scope** — `SetEnabled`'s disable path sits above the ElvUI and Baganator implementations in the file, so its reference to the `baganatorRegistered` latch resolved to a nil global rather than the local declared further down. The guard would never have fired, leaving markers on screen after unticking the box. Both latches now sit at the top of the file with the module's other state. Caught by the language server, not by `luac -p` — a bare global read is valid Lua. Location: `Modules/ItemHighlight.lua`.

- **ELVUI-001: "Highlight needed items" did nothing when running ElvUI** — The checkbox ticked, saved its state, and had no visible effect. `ItemHighlight` only ever supported two bag UIs: Bagnon (driven through its search string) and Blizzard's default `ContainerFrameNItemN` buttons. ElvUI replaces the bag UI wholesale, so the Bagnon branch found no `Bagnon`/`BagBrother` global, fell through to the Blizzard branch, and every button lookup landed on a frame ElvUI keeps hidden — where `ApplyOverlay`'s `if not button:IsVisible() then return end` guard bailed silently. No error, no message, nothing dimmed.

  Added a dedicated ElvUI path that reuses ElvUI's own per-slot `searchOverlay` texture — the dark overlay it already shows over items filtered out by its search box — rather than writing icon vertex colours that ElvUI overwrites on its next rebuild. Both writers of that overlay are hooked with `hooksecurefunc` (`B:UpdateSlot`, which sets it during a per-slot rebuild, and `B:InventorySearchUpdate`, which re-asserts it on search events) so our pass runs after ElvUI's and wins. We only ever turn the overlay *on* for unneeded items and never off, so a slot ElvUI is already hiding for its own search stays hidden and its search keeps working. Disabling the checkbox calls `B:UpdateAllBagSlots()` with `enabled` already false, making the hook a no-op so ElvUI reasserts its own state. ElvUI's bank is covered for free, since `UpdateSlot` is invoked with `B.BankFrame` too.

  Verified against `ElvUI/Game/Shared/Modules/Bags/Bags.lua` in `tukui-org/ElvUI`: `B:UpdateSlot(frame, bagID, slotID)` (line 678), `slot.searchOverlay:SetShown(info.isFiltered)` (lines 734, 742), `SetColorTexture(0, 0, 0, 0.6)` (line 2734), `B:InventorySearchUpdate` (line 824), `frame.Bags[bagID][slotID]` (lines 679-680), `B.BagFrame`/`B.BankFrame` (lines 3757-3758), `B:UpdateAllBagSlots()` (line 507), and `E:NewModule('Bags', ...)` in `Game/Shared/General/Initialize.lua`. That module is shared across flavours and branches internally on `E.Classic`/`E.Retail`, so one path serves Classic Era and TBC with no flavour-specific code on our side. **Not yet exercised in-game on either flavour** — ElvUI is not installed on the development machine. Every lookup fails safe: if any assumption is wrong the path returns nil and falls through to the previous behaviour rather than erroring. Locations: `Modules/ItemHighlight.lua`, `.luarc.json`.

- **ELVUI-001: ElvUI is only claimed when it is actually drawing the bags** — The `Bags` module object exists even when the user has switched ElvUI's bag replacement off (running Bagnon underneath it, for instance). Detecting the module alone would have let the ElvUI path claim a UI it wasn't driving and skip the Bagnon integration entirely. The check now also requires `B.BagFrame`, which is only assigned in `B:Initialize()`, so a disabled bag module falls through to the Bagnon and Blizzard paths as before. Location: `Modules/ItemHighlight.lua`.

### Internal

- **TEST-001: offline test suite** — The addon now carries a unit-test suite that runs against a fake WoW client with no game and no LuaRocks, matching the layout used by the other addons in the tree. `Tests/wowapi` is the shared [WoWAPITesting](https://github.com/Pimptasty/WoWAPITesting) harness as a git submodule; `Tests/env_togbank.lua` adds the environment this addon needs on top of it (a controllable clock and timer queue, the container/bag API, the guild roster API, the item and `ItemMixin` APIs, and a `.toc`-ordered module loader); `Tests/coverage.lua` is the zero-dependency line-coverage tool, copied from GuildRoster. Run with `lua Tests/wowapi/run.lua` from the addon root — Lua 5.1 is the only requirement. `Tests` is in `.pkgmeta`'s ignore list so none of it ships. New: `.busted`, `.luacheckrc`, `Tests/README.md`, `Tests/HARNESS_CONTRACT.md`.

  **211 specs across 8 files: 189 pass, 22 fail.** The 22 failures are deliberate — each one asserts correct behaviour against a defect recorded in `docs/AUDIT_2026-08-03.md` and names the audit ID in its failure message. They are the audit made executable and go green as the fixes land in v1.4.0; none should be made to pass by weakening an assertion.

  One environment decision is worth recording because it is load-bearing: **`C_Timer.After` returns nothing in the harness, exactly like the real API.** Only `NewTimer`/`NewTicker` return a cancellable handle. The convenient stub — returning a handle from `After` too — would have made all eight `TIMER-001` sites pass and hidden the entire bug class, since every one of those cancels sits behind an `if timer then` guard that makes a broken cancel indistinguishable from a working one.

- **AUDIT-001: full-codebase audit recorded** — `docs/AUDIT_2026-08-03.md` is the working document for the v1.4.0 overhaul: 2 critical, 4 high, 12 medium and 9 low findings, each with a greppable ticket ID, a location, a stated fix and a checkbox. It also records what was verified *healthy* (TOC lockstep, `.pkgmeta` correctness, comm-prefix registration, the three-way debug-category consistency) so a later pass does not re-litigate settled ground, and it is explicit about which modules were line-read and which were only mechanically scanned. Roughly half the codebase — `Chat`, `RequestLog`, `DeltaComms`, `Mail`, `Options` and the UI modules — still needs a second read pass, tracked as `AUDIT-PASS2`.

  Nothing in this release fixes any of those findings. The suite and the document exist so v1.4.0 can fix them against a safety net rather than by inspection.

- **DEBUG-001: five further mis-categorised debug calls found by the suite** — `Tests/constants_spec.lua` scans every `Debug()` call site in every file and validates the category/tag pair against `DEBUG_CATEGORY` and `DEBUG_TAGS`. It caught five `Debug("FULFILL", …)` calls in `Modules/RequestLog.lua` (lines 2070, 2075, 2077, 2153, 2158) that the manual read missed — `RequestLog.lua` is one of the modules not yet line-read. An unregistered category is not cosmetic: `Output:Debug` falls through to the category-only branch, the string becomes the format string, every argument shifts, and the line renders with a raw `%d` in it. Recorded in the audit, not yet fixed.

## [v1.3.1] (2026-08-02) - Banker Inventory Never Scanned

### Bug Fixes

- **SCAN-001: The per-character "enable scanning" flag could read as unset, silently disabling all scanning** — Found while investigating a report of a banker's Inventory tab staying empty. This is a real latent defect but it was **not** the cause of that report, and it is not TBC-specific.

  `Bank:Scan()` and `Mail:Scan()` both gate on `Options:GetBankEnabled()`, which reads `db.char.bank.enabled`. That key was missing from the AceDB `char` defaults in `Options:Init()` (the table declared only `donations = true`), so on any profile where it had not been explicitly written it read `nil` — falsy — and every scan returned early. The single place that ever wrote it was `Options:InitGuild()`, which was reachable only from inside `if TOGBankClassic_Guild:Init(guild) then` in the `GUILD_RANKS_UPDATE` handler. `Guild:Init` returns `false` as soon as `Info.name` matches the current guild, so `InitGuild` got exactly **one** attempt per session — and that attempt fires before the guild roster carries public/officer notes. With `memberRoster` still empty (it is built by `RefreshOnlineCache` behind a `C_Timer.After(0.5)`), `IsBank()` fell through to `GetBanks()`, which found no `gbank` notes, returned `nil`, and made `InitGuild` bail at its own `IsBank` guard. Nothing retried it, so `enabled` would stay `nil` in SavedVariables for the life of that character. `InitGuild` is also what registers the **Bank** options panel, so losing that race additionally left the "Enable for `<character>`" tick box absent from the options tree.

  Hardened in three parts: (1) `enabled = true` is now a declared default in the `char` scope, so the flag can never read `nil` — safe for non-bankers because both scan paths already gate on `IsBank()` independently; (2) `Options:InitGuild()` now latches on *success* via `self.guildInitialized` instead of relying on `Guild:Init`'s once-per-guild return, so it is safe to call repeatedly and retries until banker status is actually known — `AddToBlizOptions` still runs exactly once, so no duplicate Bank panels; (3) it is now called unconditionally on `GUILD_RANKS_UPDATE` *and* from the deferred block in `GUILD_ROSTER_UPDATE` immediately after `RebuildBankerRoster()`, which is the first moment `IsBank()` can answer correctly — `GUILD_RANKS_UPDATE` alone is not a reliable retry hook because it may not fire again after the roster loads. Locations: `Modules/Options.lua`, `Modules/Events.lua`.

- **SCAN-001: An empty Inventory tab showed "Loading items..." forever** — When a character's aggregated item list was empty, `OnGroupSelected` added the loading label and then skipped the entire `if items and #items > 0` block, so the `scroll:ReleaseChildren()` that clears the label — which lives inside the `Item:GetItems` callback — never ran. An empty record was therefore indistinguishable from a stalled load, which is what disguised the scan bug above as a hang. Empty tabs now clear the label and state the real situation, with different wording for your own character (which tells you to open the bank or run `/togbank share`) versus another banker's (which is waiting on them to share). Location: `Modules/UI/Inventory.lua`.

### Improvements

- **SCAN-001: `Bank:Scan()` now logs why it declined to scan** — All five early returns (nothing marked dirty, `Guild.Info` not loaded, no bankers found in guild notes, this character not in the banker list, scanning disabled for this character) previously returned in silence, and the function's first debug line sat well past all of them. Diagnosing a non-scanning banker meant reading the source and guessing which precondition was unmet. Each gate now emits a `BANK.GATE` line naming the precondition and, where useful, the remedy; a matching `BANK.SCAN` line on the success path reports the item and slot totals and whether the bank vault was included (it is skipped away from a bank NPC, which is expected and previously invisible). Enable with the **BANK** category in the debug options. Location: `Modules/Bank.lua`.

### Internal

- **Wired up the `BANK` debug category, which was declared but unreachable** — `DEBUG_CATEGORY.BANK` had existed in `Modules/Constants.lua` since the category system was introduced, but it had no `CATEGORY_META` row (so no toggle appeared in the debug options), no entry in `Database:Init()`'s `debugCategories` defaults, and no `DEBUG_TAGS` block — and not one line of `Modules/Bank.lua` ever wrote to it. Added all three, with `GATE` and `SCAN` tags. `ITEM` was likewise missing from the `debugCategories` defaults (it did have an options row) and has been added alongside, restoring the invariant in `CLAUDE.md` that the category list, the defaults table, and `CATEGORY_META` stay in sync. Locations: `Modules/Constants.lua`, `Modules/Database.lua`, `Modules/Options.lua`.

## [v1.3.0] (2026-08-02) - TBC Client Support

### New Features

- **TBC-001: Added a TBC TOC so the addon loads on Burning Crusade clients** — TOGBankClassic previously shipped a single `TOGBankClassic.toc` at Interface 11508, so a TBC client (2.5.x) treated it as out of date and the CurseForge listing offered no TBC build. Added `TOGBankClassic_BCC.toc` at Interface 20506, matching the file list of the Era TOC exactly (same libraries, same module load order, same SavedVariables, same `Ace3, VersionCheck-1.0` dependencies) and differing only in the `## Interface` value. The BigWigs packager reads every `*.toc` in the tree to decide which game versions to publish for, so the same source tree now produces both the Era and the TBC build. `.pkgmeta` keeps `enable-toc-creation: no` — both TOCs are checked in and maintained by hand. Location: `TOGBankClassic_BCC.toc`.

### Improvements

- **Bumped the Classic Era interface to 11509** — `TOGBankClassic.toc` still declared 11508 while the live Era client is 1.15.9, so the addon showed as out of date in the character-select AddOns list until "Load out of date AddOns" was ticked. Location: `TOGBankClassic.toc`.

### Internal

- **The two TOC files must be kept in lockstep.** Any new module, vendored library, SavedVariable, or metadata line has to be added to both `TOGBankClassic.toc` and `TOGBankClassic_BCC.toc` — a module added to only one silently fails to load on that flavour. Recorded in `CLAUDE.md`.

- **Added the dev-sync watcher so both flavours can be tested from one working tree** — ported `wow-version-replication.ps1` from the FastGuildInvite repo and retargeted it at this addon. It mirrors the `_classic_era_` source tree into `_anniversary_\Interface\AddOns\TOGBankClassic` (the TBC install) on a 2-second poll. Two independent launchers start it: the developer's global Claude Code `SessionStart` hook (which scans the project dir for the script) and, for editor-only sessions, a `folderOpen` task in `.vscode/tasks.json`. A per-repo named mutex plus the hook's own process scan mean whichever fires second exits cleanly instead of racing the first — confirmed in practice, the first live run logged one `LAUNCH` followed a second later by one `SKIP already-running`. `$WowVersions` deliberately lists only `_classic_era_` and `_anniversary_` — `_classic_` (MoP) and `_retail_` are excluded because there is no TOC for them and a copy there would sit permanently "out of date". The skip list is built by parsing `.pkgmeta`'s `ignore:` block, so the synced install mirrors the shipped zip; the repo's flavour-specific `.git` *pointer file* is hard-skipped so it can never resolve the `_anniversary_` copy back at the Era git dir. Verified end to end on the first real run: 50 files landed in the TBC install, no `.git`, no dot-prefixed entries anywhere in the tree, no `docs/` or `tools/` — matching the `-DryRun` projection exactly. Locations: `wow-version-replication.ps1`, `.vscode/tasks.json`, `.pkgmeta`.

- **`.pkgmeta` cleaned up to the documented ignore-syntax rules** — removed seven dot-prefixed entries (`.git`, `.github`, `.gitattributes`, `.gitignore`, `.vscode`, `.luarc.json`, `.markdownlint.json`) and the `"*.DS_Store"` glob. All eight matched nothing: the packager's `copy_directory_tree()` prunes dot-prefixed paths unconditionally, so listing them implied coverage the entries weren't providing. Rather than couple the packager config to the dev-sync script (the script had been reading those entries to build its skip list), `wow-version-replication.ps1` now mirrors the packager's prune directly in its own `$AlwaysSkip` — one dot-segment pattern replacing the `.gitignore`/`.gitattributes`/`.gitmodules`/`.pkgmeta` special cases. Verified equivalent with `-DryRun`: the same 50 files copy and the same 31 skip as before the change. Also documented the full ignore-syntax ruleset in a comment block (bare folder names, single-star quoted globs, no dot-prefixed entries, and the trailing-comment trap that ships empty zips), and corrected the stale `enable-toc-creation` comment which read "Enable …" above a `no`. Locations: `.pkgmeta`, `wow-version-replication.ps1`.

## [v1.2.1] (2026-07-30) - Settings Panel Open Fix

### Bug Fixes

- **SETTINGS-002: Opening the settings panel errored (`bad argument #1 to 'OpenSettingsPanel'`)** — Clicking the gear icon in the Inventory window or choosing Settings from the minimap button threw `Blizzard_Settings.lua:144: bad argument #1 to 'OpenSettingsPanel' (outside of expected range ...)` and the panel never opened. `Options:Open` called `Settings.OpenToCategory("TOGBankClassic")` — a *name*, which only ever worked because AceConfigDialog-3.0 overwrote the registered category's `ID` field with the category name. The current Ace3 build stops doing that override on any client exposing `C_SettingsUtil.OpenSettingsPanel` (which Classic Era now does), because `OpenSettingsPanel` requires a numeric category ID, so our name string reached it and was rejected. Fixed by capturing the real category ID from `AddToBlizOptions`' second return value at registration time and passing that to `Settings.OpenToCategory`. Added `Options:GetBlizCategoryID()`, which falls back to AceConfigDialog's `BlizOptionsIDMap` and finally to the bare name so older clients (where the ID *is* the name) keep working, plus a guard that reports an error instead of throwing if `Settings.OpenToCategory` is missing entirely. Also removed a stale comment claiming the call had to be made twice. Location: `Modules/Options.lua`.

## [v1.2.0] (2026-07-22) - API Compatibility Sweep, Manual-Fill & UI Fixes

### Bug Fixes

- **STATICPOPUP-001: Manual "Mark Filled" quantity was never recorded (order stayed open)** — Reported by multiple users in Classic: opening the Complete (hand-off) prompt, entering a quantity, and clicking Mark Filled did nothing — the amount never reached the Sent column and the order was never marked filled. Root cause is unrelated to the global-removal wave: the Era client's earlier StaticPopup refactor (the `Blizzard_StaticPopup` mixin rewrite) replaced the dialog's `.editBox` / `.button1` *fields* with `:GetEditBox()` / `:GetButton1()` accessor *methods*. The prompt read `self.editBox`, which is now `nil`, so the typed quantity read as `nil` and the code silently bailed (no error). Fixed with small `popupEditBox()` / `popupButton1()` helpers that read through the methods (falling back to the legacy fields), used in the prompt's `OnShow`, `OnAccept`, and `EditBoxOnEnterPressed`. The quantity is now captured and recorded via `FulfillRequestById` as designed. Location: `Modules/UI/Requests.lua`.

- **WRAP-001: Re-open button wrapped on top of the fulfill/mail button on smaller windows** — The per-row Actions column holds a 5-button group (fulfill + complete + cancel + delete + re-open) whose Flow layout reserves all 120px of buttons + 20px of spacers = exactly 140px even when some buttons are hidden. With the column pinned at 140px, the last button (re-open) sat exactly on the content-equals-column boundary and tipped into a second row — rendering on top of the fulfill (mail) button — whenever sub-pixel rounding shrank the usable width on a smaller window. Fixed by widening the Actions column to 152px so the button row always has headroom and can't wrap. Location: `Modules/UI/Requests.lua`.

- **ROSTER-001: Login/reload error `attempt to call a nil value 'GuildRoster'`** — A recent Classic Era client update removed the global `GuildRoster()` function, migrating it to `C_GuildInfo.GuildRoster()`. The addon called the old global from five places, so it threw on `PLAYER_ENTERING_WORLD` (login/reload), on guild join/leave system messages, on banker-roster fallback scans, and on the delta online-banker fallback — leaving the guild roster refresh dead. Fixed centrally by the new compatibility shim (see COMPAT-001); call sites keep calling `GuildRoster()`.

- **METADATA-001: Opening a window errored with `attempt to call a nil value 'GetAddOnMetadata'`** — Same removed-global class of bug: the client moved the global `GetAddOnMetadata()` to `C_AddOns.GetAddOnMetadata()`. The addon called the old global from seven places (the Inventory window title, `/togbank version`, version handshakes, and roster/request version stamps), so opening the Inventory window from the minimap icon threw at `Inventory.lua:85`. Fixed centrally by COMPAT-001.

- **OFFNOTE-001: `CanViewOfficerNote()` was removed — officer features silently disabled** — The client removed the global `CanViewOfficerNote()` (moved to `C_GuildInfo.CanViewOfficerNote()`), and unlike the item APIs below it has **no deprecation fallback**, so the bare global is already `nil`. One unguarded call (`Modules/Guild.lua:3229`) threw `attempt to call a nil value`; the other eight sites used the defensive `CanViewOfficerNote and CanViewOfficerNote()` idiom and so didn't crash but always evaluated to `false` — quietly turning off every officer-gated feature (the Requests Settings tab, cancel-reason editor, help-note editing, officer options). Fixed centrally by COMPAT-001, which restores the global so all nine sites — guarded and unguarded — work again. Found via a full audit of the addon's global usage against the current Era source (v1.15.9).

- **ITEMAPI-001 / COINAPI-001: Proactively migrated shim-gated item & currency globals** — `GetItemInfo`, `GetItemInfoInstant`, `GetItemQualityColor`, `PickupItem` (→ `C_Item.*`) and `GetCoinTextureString` (→ `C_CurrencyInfo.*`) still work today, but only through Blizzard's `Blizzard_DeprecatedItemScript` / `Blizzard_DeprecatedCurrencyScript` addons, which are gated behind the `loadDeprecationFallbacks` CVar and explicitly slated for removal. `GetItemInfo` alone has ~20 call sites across the addon. These would break the moment that CVar is flipped (the same removal wave that already took the three globals above), so they are pre-emptively covered by COMPAT-001. No user-visible change today; this is insurance against the next client update.

- **FONT-001: `SetFont` error on opening a window (`bad argument #3 ... ITALIC`)** — The status bar's centre text called `SetFont(font, size, "ITALIC")`, but `"ITALIC"` was never a valid `SetFont` flag (only `OUTLINE`/`THICKOUTLINE`/`MONOCHROME`/etc. are). Older clients silently ignored the bad flag; the current client validates strictly and errors, which broke opening the Inventory/Requests windows at `StatusBar.lua:325`. The text had always rendered non-italic anyway (the flag was ignored), so the fix re-applies the font with no flags — same appearance, no error. Location: `Modules/UI/StatusBar.lua`.

### Internal

- **PKGMETA-001: Fixed the packager ignore list so dev files stop shipping** — Several `ignore` entries used forms the BigWigs CurseForge packager silently doesn't match against files: trailing-slash directory entries (`docs/`, `tools/`, `.vscode/`) become `docs//*` after the packager appends its own `/*`, matching nothing, so the whole `docs/` tree and `tools/` were bleeding into the released zip; and `**/*.ps1` / `**/.DS_Store` miss root-level files. Rewrote the list in canonical packager syntax — directory entries with no trailing slash (the packager appends `/*` itself) and plain `*.ext` globs (verified that `*` matches `/` in the packager's `case`-based matcher, so a single `*` covers all depths) — and dropped the now-redundant inline comments. Location: `.pkgmeta`.

- **COMPAT-001: Central API compatibility shim (`Modules/Compat.lua`)** — Added a single, load-first module that re-establishes every bare global the client removed by aliasing it to its `C_*` namespace equivalent (`if _G[name] == nil and C_Foo and C_Foo[fn] then _G[name] = C_Foo[fn] end`), exactly as Blizzard's own deprecation addons do but **unconditionally** (independent of the `loadDeprecationFallbacks` CVar), so the addon works whether or not the fallback shim is loaded. This keeps ~35 call sites clean (no `C_*.` rewrites, guarded idioms keep working) and gives one authoritative map of "APIs Blizzard removed and where they went." Currently covers `GuildRoster`, `CanViewOfficerNote` (→ `C_GuildInfo`), `GetAddOnMetadata` (→ `C_AddOns`), `GetItemInfo`/`GetItemInfoInstant`/`GetItemQualityColor`/`PickupItem` (→ `C_Item`), and `GetCoinTextureString` (→ `C_CurrencyInfo`). Added to `TOGBankClassic.toc` as the first module; `C_GuildInfo` and `C_CurrencyInfo` added to `.luarc.json`. A full cross-reference of the addon's ~50 API globals against the Era v1.15.9 source confirmed all others (guild roster reads, mail APIs, chat/FCF helpers, memory profiling) are still called bare by Blizzard and remain safe.

## [v1.1.4] (2026-05-30) - Re-open Orders, Multi-Order Mail & Fulfillment Fixes

### New Features

- **REOPEN-001: Re-open a finished order** — A banker, officer, or GM can now re-open a completed order (filled, manually-completed, or cancelled) from the Requests window, in case it was marked done by mistake. A re-open icon appears on finished rows for those roles; confirming resets the order to `open`, clears its Sent count, and drops any cancel reason. New `Guild:ReopenRequest(requestId, actor)` (gated by `CanManageRequests` = banker/officer/GM), a `reopen` mutation type, and an optional `reopenedAt` field appended to the request record and the `togbank-rd2` wire format (slot 14, append-only). The request log normally *ratchets* terminal statuses — it refuses to un-cancel/un-complete an order during sync so a stale fulfillment can't revert a finished order — so the re-open carries a `reopenedAt` timestamp and a narrow exception in `mergeRequest` lets a re-open stamped *after* the terminal defeat the ratchet, so it survives sync instead of snapping back to done. Older clients (pre-REOPEN-001) keep the order terminal until they update. Locations: `Modules/RequestLog.lua` (`ReopenRequest`, `mergeRequest` ratchet exception, `ApplyRequestMutation` `reopen` auth, wire serialize/deserialize/sanitize), `Modules/UI/Requests.lua` (re-open button + confirm dialog).

### Bug Fixes

- **COMPLETEQTY-002: Manual "Mark Filled" hand-off didn't complete the order** — The row check-mark button (manual completion, for items handed over in person or mailed yourself) opened a quantity prompt whose confirm button read "Mark Sent", but entering the amount and confirming often left the order unchanged. The prompt routed through the by-name `FulfillRequest(bank, requester, item, …)` path, which re-matches the request on bank + requester + item and silently no-ops if any field doesn't compare equal — so nothing was recorded and the order stayed open (only a quiet "Unable to record that quantity." status line). It now completes the request **by its id** via the new `Guild:FulfillRequestById(requestId, count, actor)`: the amount is recorded into the Sent column and, once Sent reaches the requested quantity, the order is closed outright (status `complete`, broadcast as a full snapshot so peers replicate the Sent total and terminal status); a partial amount records the Sent total and leaves the order open. The confirm button is relabelled **"Mark Filled"** (covers both an in-person hand-off and mail you sent yourself) and the prompt wording generalised to match. Locations: `Modules/RequestLog.lua` (`FulfillRequestById`), `Modules/UI/Requests.lua` (prompt text, button label, OnAccept).

- **HITBOX-002: Bottom-row icons still dead in their bottom half (HITBOX-001 follow-up)** — The HITBOX-001 lift (v1.1.2) raised each bottom-row icon to `window.frame:GetFrameLevel() + 10` once, at construction time. But the Inventory/Search/Requests windows are `FULLSCREEN_DIALOG` AceGUI frames whose frame level jumps to a much higher value when they are *shown*; AceGUI's `sizer_s` resize strip tracks the parent up to `parentLevel + 1`, while the icons stayed pinned at the stale construction-time level — so once shown, the sizer sat back above the icons and swallowed clicks/hover across the bottom ~half of every bottom-row control (and AceGUI's own Close button, which HITBOX-001 never lifted at all). Fixed with a shared helper `TOGBankClassic_UI:KeepAboveResizeSizers(window, buttons)` that re-asserts the lift against the *live* parent level on every `OnShow` (plus a next-frame pass, since the final level lands just after OnShow), and that also locates and lifts AceGUI's Close button. The button set is stored on the frame and the `OnShow` hook is attached once per frame, so the Requests window's release/reacquire (banker-status change) and AceGUI's frame pooling neither stack hooks nor lift recycled buttons. Locations: `Modules/UI.lua`, `Modules/UI/Inventory.lua`, `Modules/UI/Search.lua`, `Modules/UI/Requests.lua`.

### Improvements

- **MULTIORDER-001: One mail can close several of a person's orders** — When a banker mails items to a guild member, the addon now credits *every* matching open order that member has with that banker, instead of only one. A fully manual mail already spread across multiple orders (matched by item name); this extends the same behaviour to addon-generated mails: if the banker uses the Fulfill button and then hand-attaches extra items to "save a mail," `OnSendMail` diffs the actual attachments against what the addon attached and records the surplus as `pending.extraItems`, and `ApplyPendingSend` credits the button's targeted order via the request's own stored item name (locale-safe, by `requestId`), then spills the hand-added extras across the recipient's other open orders by name. The addon's `pending.items` is deliberately **not** overwritten with `GetSendMailItem` names (the banker's client locale), which would break the targeted match in a mixed-locale guild. Orders assigned to a *different* banker are left untouched. Locations: `Modules/Mail.lua` (`OnSendMail`, `ApplyPendingSend`).

## [v1.1.3] (2026-05-30) - Cancel-Stale Broom Icon Hotfix

### Bug Fixes

- **BROOM-001: Cancel-Stale button was invisible** — The broom icon shipped in v1.1.2 used `Interface\Icons\INV_Broom_01`, which does not exist in the Classic Era client (it rendered as the blue missing-texture box, so the bulk-cancel button appeared blank). `INV_Misc_Broom_01` and `INV_Pet_Broom` are likewise absent from the Era texture set — Classic Era ships no broom icon at all. Fixed by bundling a custom broom texture with the addon (`Textures/broom.tga`, a 64×64 32-bit TGA with alpha) and pointing the Cancel-Stale button at it via addon path (`Interface\AddOns\TOGBankClassic\Textures\broom`), so the icon renders regardless of which icons the client happens to include. The new `Textures/` folder ships in the build; its spec note (`Textures/README.md`) is excluded via `.pkgmeta`. Location: `Modules/UI/Requests.lua`, `Textures/broom.tga`, `.pkgmeta`.

## [v1.1.2] (2026-05-30) - Requests Tabs, Custom Cancel Reasons & Armor Slot Filter

### New Features

- **REQUI-001: Officer-only Settings tab in the Requests window** — Added a third tab, `Settings`, to the Requests window, visible only to the GM and officers (gated on `CanViewOfficerNote()`). It renders as an opaque overlay panel over the request list with three editable numeric fields — Archive threshold (days), Auto-cancel stale (days), and Maximum request amount (%) — mirroring the three controls previously reachable only via the Blizzard options panel. Each field commits on Enter or focus-loss and only acts when the value actually changed, so unchanged focus-loss no longer re-broadcasts. The two guild-synced settings reuse the existing `TOGBankClassic_Guild:BroadcastSettings("ALERT")` path (SETTINGS-001), so changes propagate guild-wide exactly as the options panel does. New methods `BuildSettingsPanel`, `PopulateSettings`, `ShowSettings`. Location: `Modules/UI/Requests.lua`.
- **CANCELREASON-001: Custom guild cancel reasons (officer-authored, guild-synced)** — The officer Settings tab now includes a cancel-reason editor styled after the FastGuildInvite Filters tab: a `[Member] [Banker] [reason text] [Save]` strip over a banded, scrolling list. Officers add custom reasons and tick **Member** and/or **Banker** to choose whether each appears in the member self-cancel dropdown, the banker-cancel dropdown, or both. The built-in flavor presets also appear in the list, greyed/read-only (no edit, no delete), each with a single native-role tick officers can clear to stop offering that preset. Custom rows are click-to-edit and have a delete `X`. The whole config lives in `Info.settings.cancelReasons` (`{ custom = { {text, member, banker} }, presetDisabled = { banker = {key=true}, member = {key=true} } }`) and rides the existing `BroadcastSettings` path, so every member's cancel dialog offers the same reasons. Non-officers never see the editor (Settings tab is officer-only) but consume the synced reasons. The cancel dialog now builds its list from `buildPresetReasons(role)` minus `presetDisabled`, plus enabled customs for that role, and always offers at least one option. New methods `BuildReasonsEditor`, `RefreshReasonsList`, `_BuildReasonRow`, `_ConfigureReasonRow`, `_OnReasonToggle`, `_OnReasonDelete`, `_OnReasonEdit`, `_EnsureReasonConfig`. Locations: `Modules/UI/Requests.lua`, `Modules/Guild.lua`, `Modules/Database.lua`.

- **FILLALL-001: "Fulfill Oldest Order" stepped button (spam-to-fill)** — A new envelope icon in the Requests window's bottom-right cluster (bankers only) walks the **oldest order you can fully fill from your bags** through one action per click: select (sets the recipient, switches to the Send Mail tab) → **split** (only if a stack split is needed) → **attach** → **send**, then the next click picks the next-oldest. One WoW action per frame deliberately — the earlier single-click version raced the send ahead of the async split; stepping it lets the cursor/bag state settle between actions. The split commits into a free bag slot as its own stack (like the manual split), and ATTACH waits for it to land before grabbing it. Oldest-first (FIFO by `date`, with a stable request-id tiebreak so same-second orders pick deterministically instead of appearing to jump around the list) so item contention favours whoever asked first; only orders assigned to your own character are eligible (that's the constraint for fulfillment credit). **Mail collect:** if the oldest serviceable order's items are sitting in your mail inbox (not bags), each click first pulls one matching item into your bags (`TakeOneInboxItemFor`, gated on free bag space) until enough is collected, then it selects + fulfills — so the flow now spans bags **and** mail, only matching your own open orders. Orders you can't cover from bags + mail are skipped. After a send, a `batchInFlight` guard blocks re-selecting that order until the send confirms (cleared on `MAIL_SEND_SUCCESS`/`ApplyPendingSend`, mail error/`UI_ERROR_MESSAGE`, or a 5s safety timer); the step state resets on `MAIL_CLOSED`. The status bar shows the next step at each click. New `TOGBankClassic_Mail:FulfillStep` / `FindOldestServiceableOrder` / `TakeOneInboxItemFor` / `ResetFulfillStep` (+ inbox-match helpers), reusing `CalculateFulfillmentPlan` + the existing `pendingSend` → `FulfillRequest` path. `SendMail` added to `.luarc.json`. Locations: `Modules/Mail.lua`, `Modules/UI/Requests.lua`, `Modules/Events.lua`.
- **COMPLETEQTY-001: "Complete" now asks how much was handed over** — The row's check-mark button (for items given directly, not mailed) used to silently mark the whole request complete. It now opens a quantity prompt; the number you enter is recorded in the **Sent** column via `Guild:FulfillRequest(request.bank, …)`, and the order only flips to fulfilled once Sent reaches the amount requested — so partial hand-offs are tracked correctly. New `TOGBankClassic_CompleteQty` static popup (`hasEditBox`, numeric) + `showCompleteQtyPrompt`/`ensureCompleteQtyDialog`; applied against the request's own bank so it works whoever clicks (button visibility still gated by `CanCompleteRequest`). Location: `Modules/UI/Requests.lua`.
- **HELPNOTE-001: Officer help notes on the help (?) tooltips** — GM/officers can now add a custom note that appends to the bottom of the help "?" tooltip on each of the three windows (Inventory, Search, Requests) — e.g. how to submit a request and expected turnaround time. Edited in the Blizzard options panel (Esc → Options → AddOns → TOGBankClassic → Requests → "Guild Help Notes"), per window, as multi-line inputs gated to `CanViewOfficerNote()`. Stored in `Info.settings.helpNotes = { inventory, search, requests }`, synced guild-wide over the existing `BroadcastSettings` path (sanitized on receive by `SanitizeHelpNotes`, clamped to 400 chars/window). The tooltips read the note at hover time via a shared `TOGBankClassic_UI:AppendGuildHelpNote(windowKey)` (Inventory/Requests call it directly; Search passes a note key to `AttachTooltip`). New `TOGBankClassic_Guild:GetHelpNote`, `TOGBankClassic_Options:SetHelpNote`. Locations: `Modules/Guild.lua`, `Modules/Database.lua`, `Modules/Options.lua`, `Modules/UI.lua`, `Modules/UI/Inventory.lua`, `Modules/UI/Search.lua`, `Modules/UI/Requests.lua`.
- **VIEWBANK-001: View-only bank toons (visible but not requestable)** — A bank character can now be flagged "view only" so its stock stays visible everywhere (inventory, search, item tooltips) while guild members are blocked from sending requests for it — e.g. a raid bank. Officers flag it by adding a view-only marker to the toon's guild note alongside the usual `gbank` tag: `gbank viewonly` (also accepted: `view-only`, `readonly`, `read-only`, or the compact `gbankro`). New `TOGBankClassic_Guild:IsViewOnlyBank(name)` (O(1) via a `viewOnly` flag stored on `memberRoster`, computed from notes in `RefreshOnlineCache`/`RebuildBankerRoster`, with a roster-scan fallback). Enforced in three places: `Guild:AddRequest` hard-rejects any request whose target `bank` is view-only; the Search request dialog (`ShowRequestDialog`) refuses to open for a view-only banker and prints a reason; and Search result rows tag view-only banks with a `(view only)` marker. Items on both a normal and a view-only banker stay requestable from the normal one (requests are per-banker). Locations: `Modules/Guild.lua`, `Modules/RequestLog.lua`, `Modules/UI/Search.lua`.

### Bug Fixes

- **HITBOX-001: Bottom-row icons only clickable in a center sliver (clicks *and* tooltips)** — The gear, help `?`, `<` / `>` page arrows, broom, and fulfill envelope icons that sit along the bottom edge of the Inventory, Search, and Requests windows responded to clicks and hover only in a tiny center spot. Cause: AceGUI's `Frame` widget lays an invisible, mouse-enabled **resize strip** (`sizer_s`, full bottom width, 25px tall) plus a corner sizer across that whole row for the drag-to-resize handle. The parent frame is at frame level 100, so the sizers — and any icon added as a child of the same frame — all default to level **101**; two mouse-enabled frames overlapping at the *same* level produce ambiguous hit-testing, so the sizer swallowed most of each icon's input. Fixed by lifting every bottom-row icon to `window.frame:GetFrameLevel() + 10` (level 110) so it sits above the sizers and the full icon is live for both clicking and mouseover. Not a texture/`SetSize`/`SetHitRectInsets` issue (the gear's hit-rect was already *expanded* and still failed). Locations: `Modules/UI/Inventory.lua`, `Modules/UI/Search.lua`, `Modules/UI/Requests.lua`.
- **FILLALL-002: Mail collect over-pulled stackable items** — The "Fulfill Oldest Order" mail-collect step counted *attachments* pulled rather than *items*, so for a stackable item (where one mail attachment can be a whole stack) it kept pulling past the amount needed and filled your bags. `TakeOneInboxItemFor` now returns the quantity taken (via `GetInboxItem`) and the collector tracks items pulled against the deficit, stopping once enough is in your bags — correct for both single items (1 = 1) and stacks. Location: `Modules/Mail.lua`.
- **REQUI-005: Pagination "snapped back" to the first page** — Clicking the `<` / `>` page arrows would jump back to page 1 a split second later. A background request sync (`RefreshRequestsUI` → `DrawContent`) was unconditionally resetting `currentPage = 1` on every redraw. `DrawContent` now resets the page only when the active tab actually changed (tracked via `_lastDrawnTab`), and `DrawRows` clamps `currentPage` to the valid range so a shrinking data set can't strand the view on an empty page. Location: `Modules/UI/Requests.lua`.

### Improvements

- **OFFICERTAB-001: Options "Requests" group renamed to "Officer" and gated to officers only** — The Blizzard options group (Esc → Options → AddOns → TOGBankClassic) holding the request thresholds + help notes is now titled **Officer** and its `hidden` function is `not CanViewOfficerNote()`, so only the GM and officers can see or change those settings (previously bankers could too). Location: `Modules/Options.lua`.
- **REQUI-002: Requests window top strip decluttered + real tab widget** — The top strip now holds only the tabs (`Requests | Archive | Settings`), and they are now an AceGUI `TabGroup` (the proper WoW tab-shaped tabs, matching FastGuildInvite) instead of red `UIPanelButton`s. The widget is used purely as a tab bar — its content box backdrop is removed so only the tab row shows; the request list and Settings panel still render below as separate window children. Tab selection drives `currentTab` via `OnGroupSelected`; the old `UpdateTabButtons` text-prefix highlighting was removed (the tab widget shows the active tab itself). Per-tab hover tooltips use `OnTabEnter`/`OnTabLeave`. The `Cancel Stale` button and the full-width `< Prev` / `Next >` pagination buttons no longer crowd the top. Location: `Modules/UI/Requests.lua`.
- **REQUI-003: Pagination and Cancel Stale moved to compact status-bar icons** — The `< Prev` / `Next >` buttons are now compact page-turn arrow icons (`UI-SpellbookIcon-PrevPage`/`NextPage`) next to the bottom-right help `?` icon, dimming automatically at the first/last page. The `Cancel Stale` action is now a small broom icon (`Interface\Icons\INV_Broom_01`, the Hallow's End Magic Broom texture) in the same cluster, shown only to officers/bankers. The status bar's right edge auto-shrinks to clear the icon cluster (wider when the broom is present). On the Settings tab these icons are hidden since they don't apply. Location: `Modules/UI/Requests.lua`.
- **REQUI-004: Settings panel compacted + tooltip cleanup** — The three numeric settings (Archive, Auto-cancel, Max request %) now sit on a single compact row instead of three stacked label+description blocks, freeing ~110px the cancel-reason list now uses. The redundant "Request Settings" title was removed (the tab already says Settings). Field descriptions now live on the **label's** hover tooltip rather than the edit box, so the tooltip no longer covers the field while typing. The cancel-reason `Mbr` / `Bnk` / `Reason` column headers and the "Custom Cancel Reasons" heading now have hover tooltips (the heading's how-to text was moved off-screen into its tooltip), via a new `attachLabelTooltip` helper that overlays a hit frame on a FontString. Location: `Modules/UI/Requests.lua`.
- **REQUI-006: Bottom status-bar row tidied** — The status bar now extends right to meet the icon cluster instead of stopping ~22px short, and every bottom-row icon (help `?`, `<` / `>` page arrows, broom, fulfill envelope) is the same size (22px) with equal 8px gaps. The cluster sits in the gap left of the AceGUI Close button (which occupies x -127..-27), with the help icon at -133 so it never overlaps Close. Rather than a hardcoded right-edge inset, the status bar's `BOTTOMRIGHT` is anchored 6px to the left of whichever icon is actually leftmost (`self.FulfillOldestBtn or self.CancelStaleBtn or prevPageBtn`), so the bar always meets the cluster with even spacing regardless of which icons a given user has — fixing the large gap that appeared when the old fixed offsets didn't match the real cluster width. Location: `Modules/UI/Requests.lua`.
- **REQUI-007: Clickable text column headers (no more red buttons)** — The request-table column headers were red `UIPanelButton`s whose centered text didn't line up with the data cells below. They are now plain `InteractiveLabel` sort headers — gold text with a hover glow, click to sort, sort arrow appended — each justified to match its column's data so headers and rows align. Mirrors the FastGuildInvite RowList header style. A per-column `headerAlign` override centers the `Item` header, and a `headerSuffix` (trailing space) nudges the right-justified `#` header in by one character so it sits over the first digit of the quantity rather than the `x`. `EnsureHeaderRows` builds `InteractiveLabel`s instead of `Button`s. Location: `Modules/UI/Requests.lua`.
- **REQUI-008: Tightened vertical spacing above the request list** — The tab strip's `TabGroup` height was trimmed (34 → 30) to close the gap between the tabs and the filter dropdowns, and the column-header row gained ~3px of breathing room above it (header group content `y` offset `0 → -3`). Location: `Modules/UI/Requests.lua`.
- **SEARCH-001: Armor equip-slot filter in the Search window** — When the Filter is set to `Type → Armor`, a new `Slot` dropdown (between the subtype and Sort dropdowns) lets you narrow results to a specific equip slot — Head, Shoulder, Chest, Wrist, Hands, Waist, Legs, Feet, Back, Neck, Finger, Trinket, Shield, Held In Off-hand, or Relic. It combines with the existing armor subclass (Cloth/Leather/Mail/Plate) filter, so e.g. `Plate + Legs` works. The dropdown is disabled for non-armor types. Items' equip slot is resolved on demand from `GetItemInfo` (#9) and cached on the item's `Info` table (`equipSlot`), so no change to the synced data schema; `INVTYPE_CHEST`/`INVTYPE_ROBE` collapse to one `Chest` entry, etc. New `SLOT_LIST`/`SLOT_ORDER`/`INVTYPE_TO_SLOT` tables, a `resolveSlotKey` helper, a `subSlotDropdown` widget + `resetSlot` cascade, `self.SubFilterSlot` matching in `SubFilterMatches`. Location: `Modules/UI/Search.lua`.

### Internal

- Pagination buttons are now raw `Button` frames (with normal/pushed/disabled/highlight textures) rather than AceGUI buttons; a file-local `setBtnEnabled` helper replaces the old `SetDisabled` calls at the two page-state update sites. The Settings overlay is a `BackdropTemplate` frame rebuilt per window; its references (`SettingsOverlay`, the three editboxes, `SettingsTabBtn`, and the cancel-reason editor widgets/row pool) are cleared in the window's reset block, and `CancelStaleBtn` is cleared before its conditional creation so a lost-banker-status window recreation doesn't read a stale reference. Location: `Modules/UI/Requests.lua`.
- **CANCELREASON-001 sync/storage:** `cancelReasons` is added to the `guild-settings` broadcast payload and validated on receive by a new `TOGBankClassic_Guild.SanitizeCancelReasons` helper (clamps to 20 custom reasons × 160 chars, coerces booleans, ignores a missing field so old clients don't wipe local state). Defaults and a migration block were added to both `Info.settings` init sites in `Modules/Database.lua`. The built-in flavor presets were extracted from the cancel dialog into a shared `buildPresetReasons(role)` builder (keyed so they can be individually disabled). A `strtrim` global was added to `.luarc.json`. Locations: `Modules/Guild.lua`, `Modules/Database.lua`, `Modules/UI/Requests.lua`, `Modules/Constants.lua` (SETTINGS tag description).

## [v1.1.1] (2026-05-29) - Sorting Fixes & Random-Suffix Request Variants

### Bug Fixes

- **SORT-001: "By Type" split same-material gear across equip slots** — The inventory "By Type" sort ordered items by item class → **equip slot** → subclass, so a player's cloth pieces were broken up by slot and interleaved with leather/mail (e.g. 6 cloth, 3 leather, then 1 more cloth) instead of grouping all cloth together. Reordered the comparator to class → **subclass/material** → required level (see SORT-003) → equip slot → rarity → name, so all cloth groups, then all leather, then all mail. Location: `Modules/Item.lua` `Sort` (`type` mode). The Search window had **no** `type` sort case at all (selecting "By Type" left results in scan order); added a matching comparator there. Location: `Modules/UI/Search.lua` `DrawContent` sort block.

- **SORT-002: "Level" sort and the Min/Max level filters used item level, not required level** — `Info.level` was populated from `GetItemInfo`'s item-level return (#4) but was treated everywhere as the *required-to-use* level — in the "Level (High/Low)" sort, the Search window's "Minimum/Maximum Required Level" filters, and the "usable by my level" filter. Because item level and required level diverge non-monotonically, the "High to Low" sort looked like it descended, jumped back up, and repeated rather than producing a clean ordering. Now captures the required-level return (#5) into a new `Info.reqLevel` field and uses it for the level sort and all three level filters. Required level is resolved from the live item cache (`GetItemInfo`), which is warm by the time items are on screen. Items that arrive with a pre-existing `Info` table — item data synced from other players or loaded from saved data predates the field — are resolved at sort time, retrying whenever `reqLevel` is unresolved (nil **or** 0) and only writing a positive result. This avoids the bug where a 0 written during a cold-cache window stuck permanently and broke the ordering. Locations: `Modules/Item.lua` (Info captures, `Sort` prep + level comparators, `GetItems` backfill, `GetInfo`), `Modules/UI/Search.lua` (sort-prep resolution, level comparators, `SubFilterMatches`).

- **REQ-003: Requests for random-suffix items matched the wrong variant** — Random-property gear such as "Spiked Club of the Tiger" and "Spiked Club of the Monkey" share a single base item ID and differ only by their random-suffix ID. Because a request stored only the numeric item ID, the requests screen tooltip and the mail fulfillment/availability checks matched the *first* item sharing that base ID — so a request for the Tiger variant showed (and would be fulfilled by) the Monkey variant. Requests now also capture the random-suffix ID and match on it: the tooltip resolves to the requested variant, and bag scanning / fulfillment only count the matching suffix. New optional `suffixID` field appended to the request record and the `togbank-rd2` wire format (slot 13, append-only); older clients and pre-existing requests have no suffix data and fall back to the previous item-ID matching, so there is no regression. New helper `TOGBankClassic_Item:GetSuffixID(link)`. Locations: `Modules/Item.lua`, `Modules/RequestLog.lua`, `Modules/UI/Search.lua` (request creation), `Modules/UI/Requests.lua` (tooltip), `Modules/Bank.lua` (`FindItemsByName`/`CountItemInBags`), `Modules/Mail.lua` (`CanFulfillRequest`/`PrepareFulfillMail`).

### Improvements

- **SORT-003: "By Type" now orders each material by level** — Within each material/subclass group, items are ordered by required-to-use level high→low (then equip slot, rarity, name as tie-breakers), so a type-sorted list reads cleanly within each group (all plate: 50, 49, 48…) instead of relying on slot/name alone. Applies to both the inventory and Search windows. Locations: `Modules/Item.lua` `Sort` (`type` mode), `Modules/UI/Search.lua` `DrawContent` sort block.

### Internal

- **`.luarc.json`** — Added `strsplit` to `diagnostics.globals` (used by the new `GetSuffixID` helper).

<!-- The three entries below sat between the v1.1.1 and v1.1.0 headings in CHANGELOG.md and are
     recorded here under v1.1.1 on that basis. Their original section (Bug Fixes vs Improvements)
     could not be recovered because the heading above them was the one the archive pointer replaced
     during the move. Content is verbatim; only the grouping is inferred, and it is flagged rather
     than presented as certain. -->

- **FULFILL-001: Fulfill button icon stuck on shovel after a bag split** — After splitting a stack to fulfill an order, the bag-update event called `DrawRows()`, which skips non-dirty rows. The row was already drawn so `DrawRows()` was a no-op and the split icon never transitioned. Fixed by replacing the `DrawRows()` call in `OnBagUpdate` with `_RefreshFulfillButtons()`, which re-evaluates all visible rows regardless of dirty state. Location: `Modules/UI/Requests.lua`.

- **FULFILL-003: "Item in bank and mail" showed a blank red button** — The combined icon used `INV_Misc_Chest_01`, which does not exist in Classic Era; the engine renders a blank red placeholder for any missing texture. Fixed by replacing it with two confirmed-working icons rendered side-by-side at 14px: `INV_Misc_Bag_07` (bag) and `INV_Letter_06` (wax letter). Location: `Modules/UI/Requests.lua`.

- **HIGHLIGHT-001: Bagnon bag highlighting broken for recipe and pattern items** — `UpdateBagnonHighlighting` inserted raw item names into the Bagnon search string. Tradeskill items whose names include a colon prefix (`Pattern: Ironfeather Breastplate`, `Formula: Enchant Weapon`, etc.) caused Bagnon's search parser to silently discard the entire term. Fixed with a shared `stripRecipePrefix` helper that strips all known Blizzard craft prefixes before appending to the search string. Location: `Modules/ItemHighlight.lua`.

## [v1.1.0] (2026-05-23) - Data Corruption Fix: Linkless Gear Ghosts & Inflated Counts

### Bug Fixes

- **ITEM-004: `EnsureLegacyFields` was poisoning `alt.bank.items` with mail-item references** — When peer-relayed alt data arrived carrying only `alt.items` (the aggregated bank+bags+mail view) without the separate `bank/bags/mail` fields, `EnsureLegacyFields` "reconstructed" `alt.bank.items` by copying every entry from `alt.items` — including mail items. Subsequent re-aggregation in `ApplyDelta` then ran `Aggregate(bank, bags)` followed by `Aggregate(result, mail)`, summing mail items twice per delta application. Across many peer-relay cycles, gear item counts inflated monotonically — in real SavedVariables, "Battlefell Sabre of Power" (ID=15220) reached Count=6237 and base "Battlefell Sabre" reached Count=21 (both physically impossible for non-stacking weapons). Fix removes the copy loop entirely; the next direct delta from the actual banker repopulates `bank.items` cleanly. Location: `Modules/Guild.lua` `EnsureLegacyFields` (~line 2282). Root cause documented in `docs/DELTA_BUGS.md` ITEM-004.

- **ITEM-003 guard holes on `ApplyItemDelta` update/fallback paths** — The receive-side guard against linkless weapons/armor only fired on the new-insert paths. The ID-only fallback paths in both STEP 2 (modified) at line 904 and STEP 3 (added) at line 1010 silently mutated linkless gear ghost entries into suffixed entries via `for field, value in pairs(changes) do existingItem[field] = value end` and `existingItem.Count = newItem.Count`. This propagated whatever Count the inbound delta carried into a ghost that should never have existed, causing count divergence across replicas. Fix detects ID-only-fallback matches against linkless gear and DROPS the ghost before falling through to the clean-add path, where the existing ITEM-003 new-insert guard catches subsequent linkless gear payloads. Location: `Modules/DeltaComms.lua` `ApplyItemDelta` STEP 2 and STEP 3.

- **`NeedsLink` / `ItemClassNeedsLink` could strip gear links during cold-cache windows** — The fallback path in `NeedsLink` consulted the item's hyperlink suffix field when `GetItemInfo`'s class lookup returned nil (uncached). For base/no-suffix gear items the suffix is 0, so the fallback returned false and stripped the link, producing the linkless gear ghosts that ITEM-003 / ITEM-004 then propagated. Replaced both functions with a default-deny strip policy: a link is stripped ONLY when class can be positively confirmed as non-gear (class != 2 AND != 4). Uncached, unparseable, or unknown items now preserve the link. The "Weapons (class 2) and Armor (class 4) ALWAYS keep their Link" rule documented in the file finally actually holds. Location: `Modules/Item.lua` `NeedsLink`, `ItemClassNeedsLink`, plus new `Item:GetClass(itemID)` tiered-lookup helper.

### New Features

- **Generic tooltip helper `TOGBankClassic_UI:AttachTooltip(target, anchor, title, lines)`** — Single one-call API for non-item tooltips. Auto-detects AceGUI widget vs raw frame and wires `OnEnter`/`OnLeave` via the right API. Replaces the 5-line `GameTooltip:SetOwner` / `ClearLines` / `AddLine` / `Show` scriptlet pattern that was sprinkled across UI modules. New Search-window tooltips use it; existing call-sites kept as-is for now (gradual migration). Location: `Modules/UI.lua` (~line 230).

- **Search window: info "i" icon + Prev/Next at bottom-right** — Mirrors the inventory window's bottom-right layout. The "?" help icon explains how the Search window works (input field, filters, pagination). Pagination buttons moved from a full-width "< Previous / Next >" row to compact `<` / `>` icon-sized buttons next to the close button — saves ~30px of vertical space, freeing the result list. Status bar shrunk by ~210px to leave room. Both pagination buttons keep the existing `:SetDisabled(bool)` API so `DrawContent`'s page-state logic works unchanged. Location: `Modules/UI/Search.lua` bottom-right control row.

- **Search window: tooltips on Min lvl / Max lvl / Usable** — All three filter controls now have explanatory hover tooltips wired via the new `AttachTooltip` helper. Min/Max explain that empty/0 means "no constraint" and that items without a level are hidden when a min is set. Usable explains the gating (disabled until a Type/Quality is picked).

- **Search window: Sort tooltip moved from dropdown control to label** — Previously the Sort tooltip fired when hovering the dropdown itself, which competed with the click-to-open-dropdown gesture (popped up while the user was trying to click). Now it lives on a hit frame over the "Sort" label, matching the Filter dropdown's pattern.

- **Search window: filter row reordered (Min lvl, Max lvl, then the rest)** — The numeric inputs now lead the row so the small controls cluster densely in the top-left and don't get orphaned on their own row when the window is narrow.

- **Search window: Min/Max EditBox labels repositioned** — Labels shifted 5px right (+5, -2) so they no longer overhang the EditBox's left edge.

- **Min/Max level filter in the Search window** — Two new compact numeric inputs (`Min lvl` and `Max lvl`, 60px each) let players filter results by the item's required level. Empty or non-numeric input is treated as "no constraint" so partial ranges work (just a min, just a max, or both). Cheap to compute → no gating on other filters being set first. Combines with the existing Type/Quality/Usable filters. Location: `Modules/UI/Search.lua` `SubFilterMatches` and filter section.

- **Compact, auto-wrapping filter row in the Search window** — The filters used to be four full-width-stacked dropdowns plus an inline checkbox glued to the Filter dropdown's right edge — five tall rows that ate half the window before the results even started. They're now a single Flow-laid-out row with each control sized to its content (Filter 110px, Subtype 130, Sub-subtype 130, Sort 150, Min lvl 60, Max lvl 60, Usable 80 — total ~720px). On a wide search window everything fits on one row; resize the window narrower and they wrap onto multiple rows automatically. The "Usable by my level" checkbox is now a standalone AceGUI CheckBox (previously a raw CheckButton anchored to the Filter dropdown's frame), so it participates in the wrap layout instead of forcing the Filter dropdown to stay 165px wider than it needs to be. Location: `Modules/UI/Search.lua` filter section.

- **Settings gear icon on the main inventory window** — A new gear button sits next to the existing help "?" icon at the bottom-right of the inventory window. Clicking it opens the TOGBankClassic options panel directly (equivalent to Escape → Options → AddOns → TOGBankClassic), so players don't have to navigate through the game menu to change banker/scan configuration, minimap button, debug settings, etc. Hover for a tooltip. Location: `Modules/UI/Inventory.lua` (~line 144).

- **One-shot ghost-purge migration on `Database:Init`** — Scheduled 30 seconds after addon init (gives WoW's item cache time to warm). Walks every alt's `items`, `bank.items`, `bags.items`, and `mail.items` arrays; drops entries that have no `Link` field AND are confirmed by `ItemClassNeedsLink` to be class 2/4 gear. Recovers existing corruption in SavedVariables without requiring `/togbank wipe`. Always prints a result line so users know it ran (purged count + skipped-suspect count, even when zero). Can be manually re-run via `/togbank dev purgeghosts`. Location: `Modules/Database.lua` `PurgeLinklessGearGhosts`.

- **Static item DB populated from wago.tools (`Modules/Static/ItemDB.lua` + `SuffixDB.lua`)** — Ships with ~24,000 item entries (every item in Classic Era 1.15.8) and ~2,000 random-suffix fragments. `NeedsLink` / `ItemClassNeedsLink` consult `TOGBankClassic_ItemDB` first via a tiered lookup (static DB → `GetItemInfo` → default-deny), so strip decisions no longer depend on the volatile WoW client cache. Regenerated by `tools/build-itemdb.py` which pulls Blizzard's actual DB2 dumps (ItemSparse + Item + ItemRandomProperties + ItemRandomSuffix). Wire schema unchanged in this release; bandwidth-reduction changes (Phase 3) will land in a follow-up release.

- **`tools/build-itemdb.py` — wago.tools fetch + Lua generator** — Python script (no third-party deps, Python 3.9+) that fetches DB2 tables from wago.tools, joins, filters suffix junk (rejects fragments not starting with "of "), and emits `Modules/Static/{ItemDB,SuffixDB}.lua`. Caches downloaded CSVs under `tools/wago_cache/` (gitignored). Re-run when a new Classic patch ships new items. Pattern modelled on TOGProfessionMaster's `tools/wago_probe.py`. Excluded from packaged builds (`.pkgmeta` `tools/` entry).

- **Developer-only command namespace `/togbank dev <subcommand>`** — Twenty-two dev/debug commands previously listed in `/togbank help` (clearhistory, clearsnapshots, deltaerrors, deltahistory, deltastats, forcedelta, forcefull, perfstats, persistcheck, protocol, resetmetrics, test, versioncheck, hashupdate, hashdebug, hashdump, netq, reqscan, debugdump, debuglogsave, clear-delta-errors, plus the new purgeghosts) are now hidden from the user-facing help output and dispatched only via the `dev` namespace. `/togbank dev help` lists them for developers. Reduces the top-level command list from ~30 to ~11 entries. New `DEV_COMMAND_NAMES` lookup in `Modules/Chat.lua` controls which commands route through the dev dispatcher — flipping a command between user-facing and dev-only is a one-line change. Full catalogue and developer workflows documented in `docs/DEV_COMMANDS.md` (not packaged to users — `docs/` is ignored in `.pkgmeta`).

- **`/togbank dev purgeghosts` — manual ghost-purge trigger** — Re-runs the linkless-gear-ghost migration on demand. With the populated static `TOGBankClassic_ItemDB` shipping in this release, the purge can confidently classify almost any item without relying on the WoW client's session cache. Location: `Modules/Chat.lua` COMMAND_REGISTRY.

### Internal

- **Removed obsolete local-build pipeline** — Deleted `package.bat` (referenced a no-longer-existing `embeds.xml` and would have errored on run) and the stale `dist/` directory (contained one orphan `TOGBankClassic.@project-version@.zip` from before the move to the BigWigs CurseForge packager). All release builds now flow exclusively through `.pkgmeta` + the CurseForge auto-builder. Defensive `**/*.bat` ignore pattern kept in `.pkgmeta` to catch any future leftover scripts.

- **Removed dead `function s(a)` at `Guild.lua:3030`** — Generic table-entry counter, defined as a global (lowercase), never called from anywhere in the codebase. Eliminating it removes one `lowercase-global` warning and two `unused-local` hints (`c`, `d` loop variables).

- **CLAUDE.md updated** — Replaced the references to `package.bat`/`dist/` (now gone) with notes on the current packaging pipeline. The "scratch files use `tmpclaude-` prefix" rule is preserved but no longer mentions the obsolete robocopy exclusion.

- **Documentation cleanup** — Removed duplicate `docs/CHANGELOG.md` (the canonical changelog has always been the repo-root `CHANGELOG.md`). Updated `.pkgmeta` ignore list: `docs/` directory now fully excluded from packaged builds (was: `*.md` only), `CLAUDE.md` explicitly excluded, `*.md` no longer blanket-ignored so root-level `CHANGELOG.md` ships to CurseForge as intended.

- **README.txt cleanup** — Removed dev commands from the EXPERT COMMANDS section. Rewrote MONITORING DELTA SYNC and two TROUBLESHOOTING entries to direct players at debug logging instead of dev-only counters. Kept genuinely user-facing expert commands: `compact`, `debuglog`/`debuglogclear`/`debuglogstats`/`debugtab`/`debugtabremove`, `roster`, `wipe`, `wipeall`, `wipeframes`, `debug`.

- **`Tests.lua` lint fixes** — Suppressed two `duplicate-set-field` warnings on the mocked `Database.GetGuildDeltaSupport` reassignments using the established `---@diagnostic disable-next-line` pattern.

- **Minor lint cleanup in `Chat.lua`** — Removed an unused vararg and an unused loop-variable name in `ProcessQueue` and `PrintDeltaHistory` respectively (encountered while editing the dispatcher).

- **`.luarc.json` global registration** — Added `TOGBankClassic_ItemDB`, `TOGBankClassic_SuffixDB` to `diagnostics.globals`.

- **TOC additions** — new `Modules/Static/ItemDB.lua` and `Modules/Static/SuffixDB.lua` load entries (loaded early so anything that queries item class has them available).

### Developer / Sync architecture follow-ups (planned, not in this release)

- Bump `PROTOCOL.VERSION` to 3 once the static DB is populated and committed.
- Peer-aware `StripDeltaLinks`: emit minimal `{ID, Count, suffixID?, randomProperty?}` payload to peers known to support the static DB; continue sending legacy `{ID, Count, Link/ItemString}` to old peers. Backwards-compatible per Option A in the design discussion.
- Update `ApplyItemDelta` and `ReceiveAltData` to reconstruct items from minimal payloads using `TOGBankClassic_ItemDB` and `TOGBankClassic_SuffixDB`.
- Expected wire bandwidth reduction: 4-5x for non-gear items, 5-7x for random-suffix gear, 8-10x for fixed-roll gear once everyone is on the new protocol.

---

## [v1.0.0] (2026-04-11) - First Stable Release: Fulfill Location Awareness & Polish

### New Features

- **Fulfill button location awareness** — The fulfill button now shows distinct icons and contextual tooltips for three new states, making it clear why an item cannot be mailed immediately and where to find it:
  - *Item in mail inbox* — wax letter icon (`INV_Letter_06`); tooltip: "Item is in your mail inbox. Retrieve it first, then fulfill the order."
  - *Item split across bank and mail* — paired bag + letter icons; tooltip: "Item is split between your mail inbox and bank. Retrieve mail items first, then pick up the rest from the bank."
  - *Shortage — more available in bank/mail* — contextual icon matching the location; tooltip shows exact current bag count and target quantity (e.g. "Have 125 in bags. More available in your bank and mail inbox — pick up or retrieve the rest to reach 150."). Three sub-states: bank only, mail only, or both.

### Bug Fixes

- **TOOLTIP-001: Item link tooltips showed banker data for ex-guild members** — The `OnTooltipSetItem` hook in `TooltipBankerInfo.lua` iterated all database entries with no guild membership check, surfacing data from characters who had left the guild. Fixed by adding an `IsInCurrentGuildRoster()` check as a combined guard — only alts currently in `memberRoster` (O(1) lookup) are shown. Location: `Modules/TooltipBankerInfo.lua`.

## [v0.10.10] (2026-04-04) - Same-Name Item Variant Disambiguation

### Bug Fixes

- **REQ-001: Same-name item variants were indistinguishable in the request system** — All class-specific Punctured Voodoo Doll variants (Priest, Warrior, Druid, etc.) share an identical display name from `GetItemInfo`, but each has a unique numeric item ID. The request system stored only `request.item` (the name string), so every subsystem — bag scanning, mail fulfillment detection, item highlighting, and `CheckMailFulfillment` — matched solely by name and treated all class variants as identical. A banker holding only a Warrior doll would appear able to fulfill a Priest request, wrong bag slots were highlighted, and mail detection credited the wrong variant. Fixed by threading `request.itemID` (numeric Blizzard item ID) through the entire request lifecycle with full backward compatibility: old clients that never set `itemID` automatically fall back to name-based matching everywhere. Location: `Modules/RequestLog.lua`, `Modules/UI/Search.lua`, `Modules/Bank.lua`, `Modules/Mail.lua`, `Modules/ItemHighlight.lua`.

- **REQ-002: Requests UI item tooltip showed wrong same-name variant** — The `OnEnter` handler on each item row searched guild inventory by display name and took the first match, so hovering a Druid doll request always showed whichever class variant `pairs()` iterated first (typically Warrior). Fixed by storing `request.itemID` on the EditBox frame and using it for exact ID matching in the tooltip lookup; falls back to name search for legacy requests. Location: `Modules/UI/Requests.lua`.

- **ItemHighlight lint errors** — Five `undefined-field` warnings on `RegisterEvent` and `SetScript` calls after `CreateFrame` were suppressed with `---@diagnostic disable-next-line` comments, matching the established pattern in `Modules/UI/Requests.lua`. Location: `Modules/ItemHighlight.lua`.

### Internal

- **Pre-existing bug fixed (ItemHighlight)** — `BuildNeededItemsList` computed needed quantity as `request.quantity - request.quantityFulfilled`, but the schema field is `request.fulfilled` (`quantityFulfilled` never existed). The needed-quantity calculation therefore never subtracted already-fulfilled amounts. Fixed to use `request.fulfilled`. Location: `Modules/ItemHighlight.lua`.

---

## [v0.10.9] (2026-04-03) - Cancel Reason Overhaul, Fulfillment Sound Fix & Options Cleanup

### New Features

- **Role-aware cancel reasons** — The cancel request dialog now shows different reason lists depending on who is cancelling. Bankers see six flavour-text reasons (item unavailable, policy % limit, wrong banker, already claimed by an earlier requester, duplicate request, requester not in guild). Non-bankers cancelling their own orders see five separate reasons (changed mind, found on AH, already received elsewhere, wrong item/mistake, plans changed). Role is determined at dialog open time via `TOGBankClassic_Guild:IsBank(actor)`. Location: `Modules/UI/Requests.lua`.

- **Order fulfillment sound toggle** — New Options toggle "Play Sound on Order Fulfilled" (Options → TOGBankClassic, defaults on) lets players disable the mail-arrival sound without losing the chat notification. Location: `Modules/Options.lua`, `Modules/Mail.lua`.

### Bug Fixes

- **MAIL-014: Order fulfillment sound never played** — `PlaySound("AuctionWindowClose")` used a string-based sound name removed from the WoW API in Patch 7.3.0. Classic Era requires a numeric SoundKitID. Fixed by replacing with `SOUNDKIT.AUCTION_WINDOW_CLOSE` (with numeric fallback `11561`). Location: `Modules/Mail.lua`.

- **Tooltip bleed on Reset Database button** — The "Communication Protocol" description widget (now removed) was leaking its stale AceGUI Label text into the Reset Database button tooltip. Resolved by removing the widget entirely.

### Improvements

- **Reset Database button tooltip** — The Reset Database button in Options now has a proper `desc` tooltip explaining what it does, that it is irreversible, and that it is equivalent to `/togbank wipe`. Location: `Modules/Options.lua`.

### Internal

- **Removed Communication Protocol dropdown** — The "Communication Protocol" select dropdown (AUTO / Legacy Only / New Only) was dead UI — `FEATURES.PROTOCOL_MODE` was set by the dropdown but never read by any send or receive code path. Removed the dropdown, its description widget, the `PROTOCOL_MODES` constant table, the `PROTOCOL_MODE` field from `FEATURES`, the `protocolMode` SavedVariables default, and its nil-check initialiser. Location: `Modules/Options.lua`, `Modules/Constants.lua`.

---

## [v0.10.8] (2026-04-02) - Requests UI Pagination & Copyable Item Text

### New Features

- **Requests UI pagination** — The Requests window now shows 50 rows per page with Previous/Next navigation buttons and a page status display ("Showing 1–50 of 127 (Page 1/3)"). Eliminates game freezes when switching from a specific banker filter to "Any Banker" with 100+ requests. Follows the same pattern as the existing Search UI pagination. Location: `Modules/UI/Requests.lua`.

- **Copyable item text in Requests window** — Item name cells in the Requests window now have a transparent EditBox overlay. Click an item name to highlight the text, then Ctrl+C to copy it. Typing is blocked (original text is restored); Escape clears focus. Item coloring by status (red/cancelled, green/fulfilled, white/open) continues to render via the Label underneath. Location: `Modules/UI/Requests.lua`.

- **Item link tooltip on hover** — Hovering any item name in the Requests window shows the full WoW item tooltip (stats, quality, level requirements). Uses `SetHyperlink` with the stored item link from guild inventory; falls back to `item:ID` if no link is cached. Anchors to the right of the item name row. Location: `Modules/UI/Requests.lua`.

### Improvements

- **"Requests synced." confirmation message** — A brief chat confirmation is now printed when a user-triggered `/togbank sync` completes, consistent with other command responses. Location: `Modules/Chat.lua`.

---

## [v0.10.7] (2026-04-02) - P2P Delivery Watchdog Tuning

### Bug Fixes

- **P2P-032: Delivery watchdog shorter than AceCommQueue drain time** — The `OnSyncAccept` delivery watchdog fired after 60 seconds, which is shorter than the observed 68–70 second worst-case drain time for a 9 KB payload through AceCommQueue under load. This caused premature `OnFailed` calls, unnecessary catch-up cycles, and the add-on repeating sync work that was already in flight. Fix: raised `DELIVERY_TIMEOUT` to 180s and `SEND_TIMEOUT` to 210s to comfortably exceed observed worst-case drain times. Location: `Modules/P2PSession.lua`.

---

## [v0.10.6] (2026-04-01) - Send Cap Unification & Cross-Guild Guard

### Bug Fixes

- **P2P-031: Pull-based responder bypassed P2P send-slot cap** — The legacy `togbank-r` alt-request responder and the new `HandleSyncRequest` P2P responder maintained completely independent counters (`pendingSendCount` vs `P2P.activeSends`), allowing up to 6+ simultaneous outbound data streams. Observed symptom: 20–30 concurrent "Sharing guild bank data…" messages, with some taking 60–150 seconds. Fix: extracted `TryAcquireSendSlot` / `ReleaseSendSlot` helpers into `P2PSession.lua`; both paths now compete for the single shared 3-slot cap in `P2P.activeSends`. Location: `Modules/P2PSession.lua`, `Modules/Guild.lua`, `Modules/Chat.lua`.

- **ROSTER-004: Cross-guild alts polluting banker hash list** — `latestBankerHashes` accumulated entries for alts from other guilds or ex-bankers whose roster entries were stale in SavedVariables. The `togbank-hlr` handler accepted any alt name without validating `IsBank()`. Fix: (A) `BuildBankerHashList` now prefers the live `GetBanks()` cache over the persisted roster alts. (B) All three write paths in the `togbank-hlr` handler now guard on `IsBank(norm)` before writing. Location: `Modules/Guild.lua`, `Modules/Chat.lua`.

- **SEND-001: Send progress always showed "1 chunks, 0.0s"** — The chunk callback fired only once (at completion, not per chunk), so `startTime` was captured and read in the same frame, and `chunksSent` was always 1. Fix: capture `startTime` at closure creation; show estimated chunk count via `math.ceil(totalBytes / 254)`; move the progress message to fire at send *start* rather than completion. Location: `Modules/Guild.lua`.

---

## [v0.10.5] (2026-04-01) - Slash Command Aliases, CRC Recovery & Dead Code Removal

### New Features

- **`/bank` and `/gbank` slash command aliases** — Two new configurable aliases toggle the main inventory window. Each alias can be individually enabled or disabled in Options → TOGBankClassic → Commands. The `/bank` shortcut is enabled by default; `/gbank` disabled by default (in case another addon uses it). Location: `Modules/Chat.lua`, `Modules/Options.lua`.

### Bug Fixes

- **REQSYNC-009: Silent data loss on `togbank-ri` CRC mismatch** — When a request index chunk arrived with a valid stop-marker but a failed CRC (genuine bit corruption), the receiver logged the error and returned with no further action — leaving a permanent blind spot for the affected request IDs until the next sync cycle. Fix: added a recovery branch immediately after the INTEGRITY-MISMATCH log that re-requests the full index from that sender with `force=true` to bypass the per-sender cooldown. Location: `Modules/Chat.lua`.

- **ALIAS-001: Duplicate `/bank` registration in `Init()`** — A hardcoded `RegisterChatCommand("bank", ...)` in `Chat:Init()` predated the new alias system and overrode it on some load orderings. Removed; `/bank` is now exclusively owned by `RegisterAliasCommands()`. Location: `Modules/Chat.lua`.

### Internal

- **MAINT-001: Dead code removal campaign** — ~350 lines of unreachable code removed across 9 files, including: delta history cluster (`SaveDeltaHistory`, `GetDeltaHistory`, `CleanupDeltaHistory` + all call sites), `SanitizeDelta`, `SanitizeItemDelta`, `GetPeerCapabilities`, `MarkPlayerSeen`, orphaned Constants fields (`DELTA_HISTORY_*`, `DELTA_CHAIN_*`, `sendLegacy`/`sendNew`), dead `ItemHighlight` constants, and an unreachable two-header layout branch in `UI/Requests.lua`. Location: `Modules/Database.lua`, `Modules/Events.lua`, `Modules/Chat.lua`, `Modules/DeltaComms.lua`, `Modules/Guild.lua`, `Modules/Constants.lua`, `Modules/ItemHighlight.lua`, `Modules/UI/Requests.lua`.

---

## [v0.10.4] (2026-03-31) - AceCommQueue-1.0 Send Queue Library

### New Features

- **AceCommQueue-1.0 embedded library** — A new transparent send-queue library (`Libs/AceCommQueue-1.0/`) sits on top of AceComm-3.0 and prevents multipart message chunk interleaving on the wire. When two messages share the same prefix, AceComm's spool for that prefix is keyed on `prefix + sender`; a second `FIRST` chunk arriving mid-stream overwrites the partial assembly and causes CRC failures. AceCommQueue queues per `(prefix, distribution, target)` and only submits the next message after CTL confirms the last chunk of the current message was handed off. Priority ordering (`ALERT > NORMAL > BULK`) is preserved between messages. The library is fully transparent — existing `self:SendCommMessage(...)` call sites are unchanged. Includes debug output (`/acq on/off/status`) and LibStub versioning for future standalone distribution. Location: `Libs/AceCommQueue-1.0/AceCommQueue-1.0.lua`, `Core.lua`, `TOGBankClassic.toc`.

---

## [v0.10.3] (2026-03-30) - Cancel Reasons, Request Timeline Tooltips & P2P Stability

### New Features

- **Cancel reason dialog** — Cancelling a request now opens a dialog to select a reason before confirming. Three preset reasons are available, including one that dynamically reflects the current officer-configured request limit percentage. Location: `Modules/UI/Requests.lua`, `Modules/RequestLog.lua`.

- **Request timeline tooltip** — Hovering any row's date in the Requests window shows a "Request Timeline" tooltip with the submission timestamp, and (where applicable) the fill or cancellation timestamp. Cancelled rows also show the selected cancellation reason. Filled/completed rows include a note that mailed items take approximately 1 hour to arrive. Location: `Modules/UI/Requests.lua`.

### Improvements

- **Help tooltip updated** — The `?` icon on the Requests window now documents the date column mouseover tooltip and the cancel reason dialog. The obsolete "Delete" section has been removed. Location: `Modules/UI/Requests.lua`.

### Bug Fixes

- **P2P-030: Hash-list broadcast collision guard** — The `hashBroadcastInProgress` flag was previously cleared on a fixed 15-second timer. Under ChatThrottleLib congestion the drain could exceed 15 seconds, allowing a second broadcast to begin before the first finished draining, producing `INTEGRITY-MISMATCH` (`stop=PASS crc=FAIL`) errors on recipients. Fix: flag is now cleared via the AceComm `callbackFn`, which fires when ChatThrottleLib has finished queuing the last chunk — not on a timer guess. Location: `Modules/Events.lua`, `Modules/Guild.lua`.

---

## [v0.10.2] (2026-03-29) - Banker Tooltip Integration

### New Features

- **Item tooltip banker info** — Mousing over any item in-game now appends a "TOGBankClassic" section to the game tooltip listing every banker that stocks that item and their total quantity. Bankers are sorted by quantity descending, then alphabetically. Realm suffix is stripped for clean display. Location: `Modules/TooltipBankerInfo.lua`, `Core.lua`, `TOGBankClassic.toc`.

---

## [v0.10.1] (2026-03-29) - P2P Hash Reform & Integrity Diagnostics

### New Features

- **HASH-REFORM: P2P collect/offer as sole hash path** — The periodic hash sync now runs exclusively through the P2P collect/offer/dispatch pipeline. Fast-fill is suppressed during the collect window to prevent premature dispatch before all peers have responded. `/togbank hashdebug` now also reports alts with missing content. Location: `Modules/Events.lua`, `Modules/P2PSession.lua`, `Modules/Chat.lua`.

### Bug Fixes

- **P2P-023: Hash-list broadcast collision prevention** — Concurrent hash-list broadcasts on `togbank-hl` collided in the AceComm multipart spool (same spool key = second FIRST chunk overwrites partial data from the first, producing `CRC fail`). Fix: a `hashBroadcastInProgress` guard flag blocks new BULK broadcasts while one is in flight, and defers NORMAL/ALERT broadcasts with up to 3 retries (16s apart) before forcing through. Location: `Modules/Events.lua`.

- **P2P-REFORM: Dual-sync removed, first-run fixed, activeSessions cap corrected** — Removed a redundant second sync path that fired alongside the primary collect/offer cycle. Fixed a first-run edge case where no session was started. Corrected the `activeSessions` counter cap that could prevent new sessions from opening after prior ones closed. Location: `Modules/P2PSession.lua`.

### Internal

- **AceSerializer error captured in PAYLOAD-TYPE log line** — When a corrupt payload cannot be deserialized, the error string (e.g. `"Invalid serialized number: '136ation-Azuresong'"`) is now emitted alongside the `PAYLOAD-TYPE` diagnostic, making the exact splice point visible in the debug log. Location: `Core.lua`.

---

## [v0.10.0] (2026-03-28) - Sort Dropdowns, UI Consistency & Search Enhancements

### New Features

- **Sort dropdown in Search and Inventory windows** — Click the sort button to open a visual dropdown menu with 6-7 sort modes depending on the window:
  - **Search:** A-Z, By Type (armor/weapons/consumables/trade goods/etc.), By Rarity (epic→common), By Level (highest first), By Bank (groups by banker name), By Quantity (highest first)
  - **Inventory:** A-Z, By Type, By Rarity, By Level, By Slot (bags-1 through bags-5 then bank-1 through bank-7), By Quantity
  - Dropdown has collapsible "Sort Mode" and "Sort Options" sections with colored separators and bold headers
  - "Reverse" checkbox toggles ascending/descending sort order
  - Replaces old single-line button that cycled through modes directly
  - Location: `Modules/UI/Search.lua`, `Modules/UI/Inventory.lua`

- **Banker name shown in search results** — The Search window item list now displays the banker character name for each item, making it easier to identify which bank alt has what you're looking for. (UI-013) Location: `Modules/UI/Search.lua`.

- **Window sizes persist across reloads** — All three windows (Inventory, Search, Requests) now remember their dimensions between sessions via SavedVariables. (UI-014) Location: `Modules/UI/Inventory.lua`, `Modules/UI/Search.lua`, `Modules/UI/Requests.lua`.

### Improvements

- **Thin 8px scrollbars across all windows** — Search, Inventory, and Requests windows now use narrow 8px scrollbars with the `UI-SliderBar-Button-Vertical` texture (matches dropdown pullout menu style), replacing the previous 16px default. Scrollbars positioned at right edge with 20px top/bottom padding to avoid overlapping adjacent buttons. Classic Era compatible (no SetBackdrop calls). Location: `Modules/UI/Search.lua`, `Modules/UI/Inventory.lua`, `Modules/UI/Requests.lua`.

- **Sort dropdown visual alignment** — In the Inventory window, the sort dropdown frame is anchored to the Inventory window's frame edges rather than the parent group, ensuring the dropdown pullout aligns perfectly with the window border. Location: `Modules/UI/Inventory.lua`.

- **Bolder dropdown section headers and separators** — Requests window dropdowns (requester/banker filters) now use bold colored headers and thicker colored separators for better visual hierarchy. Location: `Modules/UI/Requests.lua`.

- **"Rebuild Availability" button removed** — The button was a temporary workaround for a now-fixed duplicate stack counting bug and created confusion. Availability recalculates automatically on every bank scan. Location: `Modules/UI/Search.lua`.

### Bug Fixes

- **Requests dropdown closes immediately when clicked** — Clicking a dropdown in the Requests window was instantly triggering the Frame's OnClose callback (from the mouse-down event), immediately closing the dropdown pullout before the user could select an option. Fix: the dropdowns now set `dialog = true` to prevent AceGUI Frame from treating clicks as "click outside to close" events. (DROPDOWN-001) Location: `Modules/UI/Requests.lua`.

- **Sort by Type equipment slot grouping fixed** — Gear was not grouping properly by equip slot due to two issues: (1) Uncached items with `nil` class/subclass/equipSlot were falling into a catch-all "Other" bucket, and (2) equip slots were not being compared as a primary key ahead of the subclass tiebreaker. Fix: added async item cache loading so all item metadata is available before sorting; restructured comparator to order by equip slot first (1H/2H/head/chest/etc.), then class+subclass within each slot. (SORT-001, SORT-002) Location: `Modules/Item.lua`.

- **Debug frame un-docks General chat tab** — When closing the debug frame (`Alt+D` toggle), the General tab was unintentionally remaining selected as the active chat tab instead of restoring the tab the user was previously viewing. Fix: stores the active tab on frame open and restores it on close. (UI-012) Location: `Modules/Options.lua`.

### Internal

- **Enhanced INTEGRITY-MISMATCH diagnostics** — Stop-marker check now logs which debug category/tag would have been assigned to the corrupt message (e.g., `SEARCH/SERIAL`, `COMMS/HASH-LIST`), helping diagnose the source of truncation/corruption events.

---

## [v0.9.17] (2026-03-26) - Requests Archive, UI Tooltips & Integrity Diagnostics

### New Features

- **Requests Archive tab** — A second "Archive" tab in the Requests window shows requests older than the configured threshold (default: 30 days), keeping the main tab focused on active/recent requests. Location: `Modules/UI/Requests.lua`.

- **Configurable archive threshold** — Days-before-archive is user-configurable via **Options → Requests → Archive Threshold (days)**. Validated, persisted per-user to SavedVariables. Location: `Modules/Options.lua`, `Modules/UI/Requests.lua`.

- **Auto-tombstone for stale open requests** — Open requests older than the threshold are automatically rejected and tombstoned on receipt, preventing indefinitely-re-syncing requests from long-offline players. Fires on every sync path via `mergeRequest()` (REQUEST-RETIRE-003). Location: `Modules/RequestLog.lua`.

- **Guild-synced `autoTombstoneDays`** — The stale-request cutoff is officer-configurable via **Options → Requests → Auto-cancel threshold (days)**, written to `Guild.Info.settings.autoTombstoneDays` and broadcast to all clients. Location: `Modules/Options.lua`, `Modules/Database.lua`.

- **"Cancel Stale" bulk-tombstone button** — Officers and bankers get a "Cancel Stale" button in the Requests tab strip. Confirmation dialog shows how many requests will be cancelled; on confirm, tombstones all matching open requests and broadcasts `delete` mutations guild-wide. Location: `Modules/UI/Requests.lua`, `Modules/RequestLog.lua`.

- **Help icons and tooltips across all windows** — `?` icons on the Inventory and Requests windows; descriptive tooltips on all buttons, tab buttons, column headers, filter dropdowns, the highlight checkbox, and the Search label. Location: `Modules/UI/Inventory.lua`, `Modules/UI/Requests.lua`, `Modules/UI/Search.lua`.

### Improvements

- **Unified thin border** — Inventory, Requests, and Search windows now use the thin tooltip-style border (`UI-Tooltip-Border`, edgeSize=16) via a shared `ApplyThinBorder()` helper. Location: `Modules/UI.lua` and each window file.

- **Requests button row alignment** — Tab-strip buttons now sit at the same vertical baseline as the Inventory top-bar buttons. Location: `Modules/UI/Requests.lua`.

- **Custom minimap button icon.** (v0.9.16)

### Bug Fixes

- **Guild settings not broadcast to all members** — Officer-configured settings (max request %, auto-cancel days) were not reliably reaching all online members. Fix: settings are now broadcast at ALERT priority immediately on change. (SETTINGS-001) Location: `Modules/Guild.lua`.

- **No-change whispers missing slot counts** — Slot counts were omitted from no-change whispers, causing the receiver to incorrectly skip a needed sync in some cases. (SLOTS-002) Location: `Modules/Guild.lua`.

### Internal / For Testers

- **Stop-marker integrity diagnostic** — A `\031END` stop-marker is now appended to every outgoing message. On receive, it is checked (O(4)) in parallel with the existing O(N) CRC. If the stop-marker is present but CRC fails — indicating genuine bit-corruption rather than truncation — a debug log entry is written. A new opt-in toggle in **Options → Debug → Show Integrity Mismatch Alerts** (off by default) also prints a visible chat error, allowing designated testers to monitor for non-truncation corruption and determine whether the cheaper stop-marker check can eventually replace the full CRC. Location: `Core.lua`, `Modules/Options.lua`.

---

## [v0.9.15] (2026-03-24) - Critical Sync Fixes & Performance Overhaul

**Status:** Production Ready

### Bug Fixes

- **Banker broadcast marked `isBanker=false` on every 10-minute sync cycle** — `Guild:Share()` sent a preliminary `hash-list-broadcast` for just the local banker alt before calling `SyncDeltaVersion()`. This preliminary payload had no `isBanker` field; receivers read `data.isBanker or false` → `false` and treated the banker as a regular peer, skipping the `latestBankerHashes` cache update and the HLR dispatch. `SyncDeltaVersion()` then arrived with the correct `isBanker=true` and all 36 alts, but the 0.15s batch dedup window sometimes processed the bad message independently, leaving peers in a broken state and causing them to whisper hash-offers back to the banker (up to 50 members × 36 alts per cycle). The preliminary single-alt broadcast was also entirely redundant — `SyncDeltaVersion()` already includes the banker's own alt. Fix: removed the pre-broadcast from `Guild:Share()` entirely. (P2P-021)

- **`/togbank hashupdate` broadcast also missing `isBanker` field** — Same root cause as P2P-021 in a separate code path: `Guild:HashUpdate()` sent `hash-list-broadcast` without an `isBanker` field. Receivers processed it as a non-banker broadcast — `latestBankerHashes` was not updated and no HLR dispatch fired. Fix: added `isBanker = true` to the payload. (P2P-022)

### Performance

- **Guild roster lookups replaced with O(1) cache** — Several functions that ran on every incoming comm message were doing live full-roster scans instead of using the existing `memberRoster` table: `IsInCurrentGuildRoster()` (500-member loop + 1,500 `string.gsub` calls per message), `IsBank()` (iterated `banksCache` with `NormalizeName` on each entry), `GetBanks()` (re-scanned all members via `GetGuildRosterInfo()` whenever `banksCache` was nil), `SenderIsGM()`, `GetPlayerInfo()`, and the `QueryAltPullBased()` fallback path. Additionally, all banker detection in `GetBanks()`, `SenderHasGbankNote()`, and `RebuildBankerRoster()` used a `(.*)gbank(.*)` greedy regex that backtracks on every guild note. With 50 members online and all syncing near the 10-minute broadcast cycle these scans fired dozens of times per second, causing visible frame stutters. Fix: added `isBank` flag to each `memberRoster` entry (set using plain-text `string.find(note, "gbank", 1, true)`); all six hot-path functions are now O(1) cache reads; `GetBanks()` derives the banker list by iterating `memberRoster` rather than calling `GetGuildRosterInfo()` again. Location: Guild.lua.

- **Byte-by-byte checksum removed from outgoing messages** — Every comm send ran a rolling polynomial checksum over the entire serialized payload (15–50KB) in Lua, costing up to 15ms per large inventory delta. The checksum provided no meaningful protection (WoW uses TCP; AceSerializer self-validates on parse failure; any sender can forge a valid checksum). Fix: `SerializeWithChecksum()` now returns the raw serialized string. `DeserializeWithChecksum()` is unchanged and still falls back to plain `Deserialize()` when no checksum is found, ensuring backward compatibility with older clients. Location: Core.lua.

- **`ApplyDelta()` reduced from 5 item passes to 2** — Three "defensive" `Aggregate()` dedup passes ran after `ApplyItemDelta()` for each of bank, bags, and mail independently (3 passes). These guarded against duplication bugs fixed by STALE-INDEX-FIX, DUPLICATION-FIX, and DUPLICATION-FIX-003; any remaining edge case is caught by the hash-mismatch self-heal cycle. The final recalculation called `Aggregate(bank, bags)` then `Aggregate(result, mail)` — the second call re-iterated the full bank+bags set (2 passes total). Each defensive pass also sorted all item keys unnecessarily (only the aggregated `current.items` is ever rendered). Net reduction: 5 passes → 2 passes, 3 unnecessary sorts eliminated. For a banker with 200 bank + 150 bag items, this is ~1750 iterations + `GetItemKey()` calls + table allocations saved per received delta. (PERF-022) Location: DeltaComms.lua `ApplyDelta()`.

- **Per-login `RecalculateAggregatedItems()` migration removed** — The deferred block in `Database:Load()` ran an "AGGRESSIVE FIX" unconditionally 0.5s after every login: cleared `alt.items` and called `RecalculateAggregatedItems()` (5 Aggregate passes) for every stored banker alt, plus a dedup pass for every synced alt. This was papering over item-count duplication bugs resolved in v0.9.6; all users are on v0.9.6 or later. Fix: removed the call, the dedup block, and `RecalculateAggregatedItems()` from Bank.lua entirely (no remaining callers). Three cheap guarded migrations (slot init, inventoryHash backfill, inventoryUpdatedAt backfill) are retained — they short-circuit in O(1) for already-migrated alts. (PERF-023) Locations: Database.lua, Bank.lua.

- **`ComputeItemDelta()` O(N²) fallback replaced with O(k) lookup** — When link normalization failed to match a new item to any old item (Fallback 2 / deep ID fallback), the function scanned all `oldItems` in a `for _, item in pairs(oldItems)` loop for each unmatched new item. After a match was found, a second O(N) reverse scan of `oldByKey` located and removed the matched entry by value. Fix: a per-ID candidate list `oldByIDList[idStr]` is built during the existing `oldByIDOnly` loop, storing each item's reference and its exact key in `oldByKey`. Fallback 2 is now an O(1) hash lookup + O(k) walk where k = number of items sharing the same base ID (almost always 1–2). The matched key is stored on the candidate, making removal from `oldByKey` O(1) — the reverse-scan block is eliminated. (PERF-024) Location: DeltaComms.lua `ComputeItemDelta()`.

### Internal

- **Dead `Sync()` block removed from Events.lua** — A `--[[ ... --]]` block containing a defunct `TOGBankClassic_Events:Sync()` function with corrupted `e` / `nd` keyword fragments and misplaced PERF-021 code was removed.
- **`/togbank share` now prints feedback** — The command now confirms "Broadcasting mail and inventory hashes to guild." before executing, consistent with other command responses.

---

## [v0.9.14] (2026-03-24) - Inventory Sort Improvements

**Status:** Production Ready

### Improvements

- **Sort by Rarity and Sort by Level added to inventory window** — The sort button now cycles through four modes: A-Z → By Type → By Rarity → By Level. Rarity sort orders highest rarity first (epic before rare before uncommon), with A-Z as a tiebreaker. Level sort orders by required level descending, also with A-Z as a tiebreaker. Location: `Item.lua Sort`; `UI/Inventory.lua`.

---

## [v0.9.13] (2026-03-23) - Request Index Flood Fix & UI Polish

**Status:** Production Ready

### Bug Fixes

- **Request index flood eliminated for large request logs** — Three compounding issues caused guilds with large request lists (500+ requests, 85+ index chunks) to flood guild chat when multiple peers responded to the same index query simultaneously:
  - **Duplicate drain on re-query** — New queries arriving while an 85-chunk drain was already in progress were coalescing and re-queuing a full second copy of the index on top of the active drain, repeating indefinitely. `flushIndexQueue` now drops the re-send when a guild-broadcast drain is already in flight. Location: `RequestLog.lua flushIndexQueue`.
  - **Multi-peer simultaneous send** — All peers responded at the same fixed delay, causing N×85 chunks from N peers. Index responses now use random jitter (20–40s instead of fixed 20s), and a first-responder rule cancels a peer's pending send if it sees another peer's `togbank-ri` already draining — one responder covers the whole guild. Location: `RequestLog.lua EnqueueIndexResponse`, `ReceiveRequestsIndex`.
  - **First-responder starvation** — Each incoming chunk from an active drain was restarting the suppression timer, permanently blocking other peers. A sliding suppression window (`indexResponseSuppressedUntil`) is now extended per chunk and expires ~3s after the last chunk arrives, at which point all peers compete fairly via jitter. Location: `RequestLog.lua`.

- **"Broadcasted hash for \<alt\>" respects Mute Sync Progress Messages** — The message printed during `/togbank share` was always shown regardless of settings. Now gated behind `IsSyncProgressMuted()`. Location: `Guild.lua Share`.

- **"Syncing requests with guild…" respects Mute Sync Progress Messages** — Same fix as above for the message printed during `/togbank sync`. Location: `Chat.lua PerformSync`.

---

## [v0.9.12] (2026-03-20) - Stale Banker Indicators, Version Check & Bug Fixes

**Status:** Production Ready

### Bug Fixes

- **Quality border colors fixed for all gear** — Three compounding issues caused weapons and armor to always show a white quality border regardless of actual rarity. (1) `GetItems` Branch 1 used `GetItemInfoInstant` (no rarity field) — fixed in v0.9.10 by switching to `GetItemInfo`. (2) `Item:Sort` was defaulting nil rarity to `1` (common/white) via `rarity = rarity or 1` before `DrawItem` ran — this masked nil rarity with a truthy value, making the sync/async fallbacks in `DrawItem` unreachable. The sort comparators already handle nil safely, so the assignment was both unnecessary and harmful; it has been removed. (3) Remote-synced gear not yet in the client cache still had nil rarity even after fix (1) — `DrawItem` now has a sync fallback (`GetItemInfo(item.Link)` at draw time) and an async fallback (`ContinueOnItemLoad` → `GetItemInfo(item.Link)` → `SetVertexColor`) for items that load into cache after first render. All lookups use the full item link; ID-based lookup is intentionally excluded because the base item ID returns the wrong rarity for suffixed gear. Locations: Item.lua `Sort` (~line 449); UI.lua `DrawItem` (~line 145).

- **Mail item tooltip fixed** — Items sourced from the mailbox were stored with a double `item:item:…` prefix, causing tooltips to fail and show a blank name. Location: UI.lua mail item handling.

- **Empty index responses after `/togbank wipe` eliminated** — After a wipe the local requests hash is `00000000`. We were still responding to peers' index queries with an empty index. Peers now skip responding when their own hash is zero (nothing to offer). Location: Chat.lua index query respond condition.

- **False `[WARN] Invalid request version 0` after `/togbank wipe` removed** — Version `0` is valid for a freshly wiped or initialised client; the out-of-range check now exempts it. Location: RequestLog.lua `GetRequestsVersion`.

- **P2P "peer acknowledged" message respects Mute Sync Progress Messages** — The "P2P: Peer X acknowledged Y – will send delta" line was always printed to chat regardless of settings. It is now gated behind the Mute Sync Progress Messages checkbox. Location: Chat.lua P2P acknowledgement handler.

### Improvements

- **Stale banker tab indicators** — Banker tabs in the inventory window now turn red when a peer has broadcast a newer hash for that banker (i.e. the alt is HLR-pending per the same definition as `/togbank hashdebug`). Hovering a red tab shows a tooltip explaining that other guild members have newer data and current availability may not be accurate. The staleness check (`Guild:IsAltSyncPending`) covers both inventory and mail hash mismatches, missing content, and is the single source of truth used by both the tab color and the tooltip — consistent with `/togbank hashdebug` output. Location: Guild.lua `IsAltSyncPending`; UI/Inventory.lua `DrawContent`.

- **`/togbank versioncheck`** — Broadcasts a version check to all online guild members using VersionCheck-1.0 (`VC:FireBatch`), waits 21 seconds for responses, then prints a sorted list of who is running which version. Because it piggybacks on VersionCheck-1.0's own protocol (`VC10_REQ`/`VC10_RSP`), it reaches members running any version of the addon that had the library — including those running versions too old to receive newer custom protocols. Replaces `/togbank versions`, which only saw members who had sent a message since login. Location: Chat.lua `versioncheck` command handler.

- **Version displayed in inventory window title** — The main inventory window title now shows the addon version (e.g. "TOGBankClassic v0.9.12") via `GetAddOnMetadata`. Location: UI/Inventory.lua `DrawWindow`.

### Performance

- **`NormalizeRequestList` dirty flag** — The function now skips its O(N) full-table rebuild when request data hasn't changed since the last run. Previously it was called twice per index send (once via `EnsureRequestsInitialized`, once directly) even in steady state. It now runs only after actual data changes: first load, peer data merges, and migrations. Location: RequestLog.lua `NormalizeRequestList`.

### Internal

- **Debug system overhaul** — All `DebugComm` calls converted to `Debug(category, tag, …)`. P2P, COMMS, SYNC, and REQUESTS categories cleaned up. New `REQUESTS/PROTO2` tag covers `togbank-ri` / `togbank-rd2` compact protocol traffic.
- **`/togbank versions` removed** — Superseded by `/togbank versioncheck`, which reaches all guild members regardless of when they last sent a message.
- **Removed `QueryRequestsSnapshot` shim** — No callers remain; the modern `QueryRequestsIndex` replaced it entirely.
- **PERF-002: removed `data.requests` from `togbank-dv2` broadcasts** — The request version/hash field was included in every periodic inventory broadcast but never consumed by receivers. Removed to avoid confusion and marginal bandwidth waste.

---

## [v0.9.10] (2026-03-19) - 60% Bandwidth Reduction for Request Sync

**Status:** Production Ready

### Performance

- **Request sync uses ~60% less bandwidth** — The request index and per-record wire format has been rewritten from verbose key-value dicts to compact positional arrays. Two new prefixes carry this traffic:
  - `togbank-ri` — requests index as a flat positional array (`{version, liveCount, id, updatedAt, ..., tombId, tombTs, ...}`), eliminating per-field string keys across hundreds of IDs.
  - `togbank-rd2` — individual request records as positional arrays, avoiding repeated field-name overhead when syncing large request logs.

  Guilds with 500+ requests will see the most noticeable improvement during initial sync and after being offline.

### Internal

- **Request IDs changed to 14-char random hex** — The previous `actor:random` composite format has been replaced with 14 random hex characters. Existing requests retain their old IDs.
- **Removed `statusUpdatedAt` field** — The per-request status-change timestamp field has been dropped from the wire format and storage schema.
- **Removed dead protocol slots** — `togbank-dr` and `togbank-dc` (DELTA-006 delta chain replay) were never triggered by current clients and have been removed.

---

## [v0.9.8] (2026-03-19) - Request Expiry Fixes & Dropdown Improvements

**Status:** Production Ready

### Bug Fixes

- **Expiry clock anchored to wrong timestamp** — `PruneRequests` used `updatedAt` as the 30-day expiry anchor, but `updatedAt` is bumped on every sync so done requests never actually aged out. The anchor is now `statusUpdatedAt`, which only changes when the request is fulfilled, cancelled, or completed. The 30-day clock now starts when the request was actually finished.
- **Expired requests re-imported from peers** — Stale done requests received from peers running older clients were being merged back into the local database, undoing the prune. They are now tombstoned on arrival (backdated timestamp so the tombstone itself also expires within 30 days).
- **Pruning skipped on login** — `PruneIfNeeded` was not called when the addon loaded from SavedVariables, so expired requests lingered until the first periodic share timer fired (~3 minutes). Pruning now runs immediately during `Guild:Init`.

### Improvements

- **Requester/Banker dropdowns show full history** — Previously only requesters and bankers with at least one open request appeared in the filter dropdowns, making it impossible to filter by someone whose requests were all fulfilled or cancelled. The dropdowns now show everyone, split into two labelled sections: "-- Open requests --" (active names, sorted by open count) and "-- History --" (completed-only names, sorted by total count).

### Internal

- **Removed legacy full-snapshot request sync** — The `type="requests"` snapshot protocol (replaced by the index/by-id protocol seven weeks ago) has been removed. A thin shim remains in `QueryRequestsSnapshot` to avoid crashes on mixed-version guilds during the transition.
- **`/togbank reqscan`** — New diagnostic command showing total/done/expired request counts, status breakdown, and `statusUpdatedAt` age distribution (0-7d, 7-14d, 14-21d, 21-30d, >30d).
- **COMMS log clarity** — `togbank-rd` log lines now include the subtype (idx / by-id) immediately before the byte-count line, making it easier to correlate log output with protocol activity.

---

## [v0.9.7] (2026-03-18) - Request Retirement Fix & Status Bar Cleanup

**Status:** Production Ready

### Bug Fixes

- **Expired requests never pruned** — Fulfilled and cancelled requests from 30+ days ago were accumulating indefinitely. `PruneIfNeeded` was only called after mutations, never on a timer, so requests were never cleaned up on clients that hadn't recently submitted or fulfilled a request. It now runs automatically every ~3 minutes via the periodic share timer.

### Improvements

- **Status bar network labels renamed** — The network counters in the inventory status bar are now labelled `Tx:` (outgoing sends), `Rx:` (P2P data fetches), and `Bcast:` (sync broadcast queue), replacing the cryptic `send:`, `P2P:`, and `q:` labels.
- **Status bar layout** — When the window is too narrow to show all three sections, the right section drops first (was: center). Left + center are shown until even narrower, then left only.
- **Status bar refactored into StatusBar.lua** — All status bar logic (formatters, inventory summary, network parts, ticker lifecycle, hover callbacks) is now in `Modules/UI/StatusBar.lua`. `Inventory.lua` retains only two lines of status bar surface.

---

## [v0.9.6] (2026-03-16) - Request Sync Throttle Overhaul & Network Status Bar

**Status:** Production Ready

### New Features

- **Request sync throttle overhaul** — The requests-index pipeline was reworked to eliminate multi-minute CTL backlogs on guilds with 1000+ requests:
  - **Deduplicating response drain** — Replaced `SendRequestsById` with a `queriedRequests` map. Duplicate requests for the same ID from the same peer are dropped; requests from two different peers are automatically upgraded to a guild broadcast. Responses drain at one batch per second, gated on CTL queue depth.
  - **Coalesced index responses** — Multiple guild members querying the requests index within a 20-second window now trigger a single response instead of N. If different senders query, one guild broadcast replaces N individual whispers; sends are also deferred while the CTL queue is busy.
  - **Chunked index sending** — Requests-index payloads are now split into chunks of 20 IDs sent 1 second apart (previously: one ~400-packet burst). Receivers can begin fetching missing requests after the very first chunk arrives. Old clients (v0.9.5 and below) remain compatible.
- **Network status bar** (opt-in) — The inventory window status bar now optionally shows live sync activity. Enable in Options -> General -> "Show Network Status in Status Bar":
  - Left: send / queue / fetch counters
  - Centre: "Sending [type] to [recipient]" (next queued CTL message)
  - Right: "Backlog: N packets[, N recipients][, N requests]"
  - Sections hide automatically when the window is too narrow to show all three without overlap.
- **/togbank netq** — New expert command showing a full CTL queue breakdown by message type and recipient count.
- **Request count in status bar** — The Requests window now shows the total request count alongside the filtered count (e.g. "3 / 47").

### Bug Fixes

- **Self-query loop on login** — If the logged-in character was the only eligible banker, `QueryAltPullBased` would whisper itself, triggering a useless sync loop. Self is now excluded from the banker search.

### Diagnostics

- Hash values in request-index log lines are now shown in hex, consistent with the rest of the codebase.
- Outgoing COMMS log messages now include the recipient.
- Requests-by-id queries and responses (both directions) are now logged under REQUESTS/SEND and REQUESTS/RECEIVE.
- Requests-index log lines now show both the querier's hash and the local hash side-by-side, making SYNC-011 hash-match decisions easier to trace.

---

## [v0.9.5] (2026-03-16) - Request Sync Diagnostics & UI Polish

**Status:** Production Ready

### ✨ New Features

- **Network queue status bar** — The main window status bar now shows live network activity: pending sends (`send:1/3`), outbound sync queue depth (`q:2`), P2P data fetches in flight (`fetch:1`), and request index sync state. During batch ID syncs the progress is shown as `r:2/7` (current batch / total batches).
- **Descriptive request sync status** — The request index query indicator in the status bar now shows the target player name (e.g. `Querying requests index from Skywise`) instead of the cryptic `r:idx` label.
- **/togbank versions restored** — Addon version tracking is now populated from two sources: banker hash-list-broadcasts and non-banker requests-index queries, so `/togbank versions` shows all online guild members regardless of role.

### 🐛 Bug Fixes

- **Request sync stalling on large guilds** — Three timing fixes for guilds with 1000+ requests:
  - `INDEX_INFLIGHT_TIMEOUT` increased from 30 s to 180 s — the old value expired before a 20-batch sync (20 × 5 s = 100 s) could complete, causing the sync to silently abort mid-flight.
  - `REQUESTS_BY_ID_BATCH_DELAY` increased from 2 s to 5 s — gives the responding peer more time to reply before the next query batch arrives.
  - requests-index inFlight fallback timer increased from 5 s to 10 s — reduces false "guild in sync" clears when the peer's send queue is momentarily congested.
- **Mail age showing "20000 days ago"** — `lastScan = 0` is truthy in Lua, so `time() - 0` produced a timestamp relative to the Unix epoch. `GetMailDataAge` now treats `lastScan = 0` as absent data.
- **Requests date column misaligned** — Dates in open/pending requests appeared shifted left of fulfilled/cancelled dates because centre-alignment repositions shorter strings. All rows now receive a same-width invisible prefix so the date text centres identically across all states.

### 🔍 Diagnostics

- **Outgoing requests-index responses now logged** — Previously only incoming queries were logged; the response send was silent, making it impossible to confirm whether we had responded.
- **Hash values shown in requests-index log** — The query log line now appends `(their:NNNN ours:NNNN)` to help diagnose SYNC-011 hash-match decisions.

## [v0.9.4] (2026-03-15) - Request Sync Overhaul & UI Fixes

**Status:** Production Ready

### ✨ New Features

- **Request status colours** — Fulfilled requests are now tinted green with a checkmark icon; cancelled requests are tinted red with an X icon, making it easy to scan request history at a glance.
- **Item sort toggle** — Inventory view now has an A–Z / By Type sort toggle button.

### 🐛 Bug Fixes

- **Request sync stalling on login** — Fixed a critical issue where syncing after being offline could stall indefinitely. Three root causes addressed:
  - `/togbank sync` was silently blocked by a 60-second cooldown; it now always fires immediately when invoked manually.
  - Querying a peer for 1500+ missing requests sent one massive message, overwhelming WoW's chat throttle. Queries are now batched (50 IDs each) and staggered 2 seconds apart.
  - The responding peer now also sends replies in staggered batches, preventing their outbound throttle queue from being monopolised for several minutes.
- **Options window crash** — Fixed crash on open (`AceConfig: expected a table, got 'function'`).
- **Debug message formatting** — Fixed `%d` appearing literally in bank-related debug messages instead of actual numbers.
- **`/togbank hello` crash** — Fixed crash when running from source due to unsubstituted `@project-version@` placeholder.
- **Slot counts showing 0/0** — Fixed slot count display for non-banker characters (UI-001).
- **Gold icon broken** — Fixed broken gold icon in the inventory UI (UI-002).
- **Zone transition errors** — Fixed ChatThrottleLib errors during zone transitions (PERF-021).
- **Delta sync crash** — Fixed delta syncs missing slot metadata and a nil crash on Info access (SLOTS-001, SYNC-015).

### 🗑️ Removed

- `/togbank requestlog` command — superseded by the Requests UI tab. The command had no handler and crashed on use.

---

## Unreleased - Hash Sync Fixes

**Status:** In Development
**Priority:** CRITICAL

### 🐛 Bug Fixes

#### [PERF-021] Eliminated ChatThrottleLib Errors During Zone Transitions (CRITICAL)

- **FIXED**: Added 2.5s zone-in cooldown period to defer expensive operations and give ChatThrottleLib breathing room
- **PROBLEM**: Despite PERF-019 (guard overlapping roster refreshes) and PERF-020 (batch hash broadcasts), users still got "script ran too long" errors when zoning. ChatThrottleLib itself (Despool function) + Bagnon + other addons exceeded cumulative execution budget during zone transitions
- **ROOT CAUSE**: When zoning with large message backlog (180+ queued messages from ongoing delta sends taking 26+ seconds), ChatThrottleLib's Despool() must process queue during zone transition (execution-budget-constrained window). If addon operations compete for budget (GUILD_ROSTER_UPDATE, periodic timer broadcasts, hash processing, Bagnon UI updates), cumulative execution exceeds limit
- **IMPACT**:
  - Intermittent "script ran too long" errors in ChatThrottleLib.lua:415 (Despool) when zoning mid-send
  - Bagnon execution errors (`Script from "Bagnon" has exceeded its execution time limit`)
  - Stuttering/freezing during zone transitions from budget exhaustion
  - Errors persisted even after PERF-019/020 because ChatThrottleLib needed isolation to drain queue
- **BEHAVIOR**:
  - User zones while 65-chunk send in progress (26+ seconds total) → 30-40 chunks still queued in CTL → 180+ pipe entries
  - PLAYER_ENTERING_WORLD fires → GUILD_ROSTER_UPDATE (even with PERF-019 guard) → other addons process events
  - Periodic OnShareTimer fires during zone window (3-minute cycle can coincide) → broadcasts compete with CTL
  - Guild members broadcast hashes during login waves (even with PERF-020 batching) → responses add CTL traffic
  - CTL Despool + our operations + Bagnon/other addons = cumulative budget exceeded
- **SOLUTION**:
  1. Add `zoningCooldown` flag set to `true` on PLAYER_ENTERING_WORLD (ANY type: login, reload, OR zone change)
  2. Clear flag after 2.5 seconds via C_Timer.After (gives CTL breathing room)
  3. Guard OnShareTimer: if zoningCooldown active, defer and reschedule without processing
  4. Guard SyncDeltaVersion: block BULK priority (timer-based) during cooldown, allow NORMAL priority (login broadcasts)
  5. Guard GUILD_ROSTER_UPDATE login broadcasts: if cooldown active when roster init completes, reschedule QueryRequestsIndex + SyncDeltaVersion for 2.6s
  6. Guard share-request handler: return early if zoningCooldown active
  7. Guard /togbank share command: defer 2.6s and warn user if zoningCooldown active
- **RESULT**:
  - **ChatThrottleLib gets 2.5s breathing room** after ANY world entry to drain queue without competition
  - **Periodic broadcasts deferred** until cooldown expires (timer reschedules normally)
  - **Login broadcasts still execute** but deferred by 2.6s if cooldown hasn't expired yet
  - **Share requests deferred** (both incoming and manual) to avoid adding work during cooldown
  - **No functional impact:** P2P collect windows are 60s, 2.5s delay = 4% increase (negligible)
  - **Execution errors eliminated** during zone transitions
  - **CTL Despool operates in isolation** during critical zone-in window
- **LOCATION**:
  - Events.lua PLAYER_ENTERING_WORLD (~284-310): zoningCooldown init + 2.5s timer
  - Events.lua OnShareTimer (~169-177): defer check + early return + reschedule
  - Events.lua SyncDeltaVersion (~252-260): priority filter (BULK blocked, NORMAL allowed)
  - Events.lua GUILD_ROSTER_UPDATE (~350-370): deferred login broadcast reschedule (2.6s)
  - Chat.lua share-request handler (~1850-1858): defer check + early return
  - Chat.lua share command (~2086-2104): defer with warning + 2.6s reschedule

#### [PERF-020] Eliminated Stuttering from Synchronous Hash Broadcast Processing (CRITICAL)

- **FIXED**: Hash-list broadcasts now batched with 0.15s timer to prevent main thread blocking during sync storms
- **PROBLEM**: Hash-list broadcasts from guild members processed immediately and synchronously when received
- **ROOT CAUSE**: When 4+ broadcasts arrived within seconds (common during login waves, zone changes, raids), each triggered 36 hash comparisons (timestamp lookups + HasAltContent checks + hash building). 4 broadcasts = 144 hash comparisons blocking main thread for 100-300ms = visible stuttering during gameplay
- **IMPACT**: Stuttering compounded when player simultaneously sending data (ChatThrottleLib chunk callbacks processing) or handling other sync operations. Game visibly froze during hash broadcast storms
- **BEHAVIOR**:
  - Player zones/logs in → guild members broadcast hashes
  - 4 broadcasts arrive within 2 seconds
  - Each processed immediately: 36 hash comparisons synchronously
  - Total: 144 comparisons + ongoing ChatThrottleLib callbacks = main thread blocked
  - Result: 100-300ms freeze, visible stuttering in game
- **SOLUTION**:
  1. Add batching queue and timer to Chat module (hashBroadcastQueue, hashBroadcastTimer, 0.15s delay)
  2. First broadcast starts 0.15s timer, additional broadcasts within window get queued
  3. When timer fires, process all queued broadcasts in one deferred operation
  4. Automatic sender deduplication (if same sender broadcasts twice, process most recent)
  5. ProcessQueuedHashBroadcasts() handles batch processing with performance timing
- **RESULT**:
  - **Spreads work across multiple frames** (~6 frames at 60 FPS with 0.15s delay)
  - **Prevents overlapping hash comparison operations** (no more synchronous storms)
  - **Adds only 0.25% latency** to 60s P2P collect window (150ms / 60,000ms = negligible)
  - **Eliminates stuttering** during sync storms (4+ broadcasts batched into single deferred operation)
  - **Reduces network congestion** (responses staggered by 0-150ms instead of all at once)
- **LOCATION**:
  - Chat.lua Init() (~23-26): Added hashBroadcastQueue, hashBroadcastTimer, HASH_BROADCAST_BATCH_DELAY variables
  - Chat.lua ProcessQueuedHashBroadcasts() (~569-653): New batch processor with deduplication, timing, queue management
  - Chat.lua OnCommReceived() hash-list-broadcast handler (~1820-1847): Replaced synchronous processing with queueing logic

#### [PERF-019] Prevented Overlapping Roster Refresh Operations During Zone Changes (CRITICAL)

- **FIXED**: GUILD_ROSTER_UPDATE handler now guards against concurrent execution to prevent cascading expensive operations
- **PROBLEM**: When player zoned while sending data (65-chunk ChatThrottleLib queue processing) or during roster refresh retries, WoW fires GUILD_ROSTER_UPDATE automatically during zone transition
- **ROOT CAUSE**: No guard flag preventing concurrent roster refresh operations. If `needsFullRosterRefresh=true` from previous retry attempt (roster API returned 0 members), GUILD_ROSTER_UPDATE would start another 0.5s deferred operation even if previous one still in progress
- **IMPACT**: Explained intermittent "execution limit exceeded" errors (1 in 5 login/reload/zone) - only occurred when multiple expensive operations overlapped during critical init/zone window
- **BEHAVIOR**:
  - Zone while sending → GUILD_ROSTER_UPDATE fires → starts InvalidateBanksCache + RefreshOnlineCache (loops all members) + RebuildBankerRoster (scans all notes)
  - If roster API slow, retry flag = true → next GUILD_ROSTER_UPDATE starts ANOTHER 0.5s timer
  - Multiple overlapping timers + ChatThrottleLib chunk callbacks (30 failures × callback overhead) = cumulative execution limit exceeded
- **SOLUTION**:
  1. Add `refreshInProgress` guard flag alongside existing `needsFullRosterRefresh` flag
  2. Check `needsFullRosterRefresh AND NOT refreshInProgress` before starting refresh cycle
  3. Set `refreshInProgress = true` when starting 0.5s deferred work
  4. Clear `refreshInProgress = false` at end of deferred function (after retry check, broadcasts)
  5. Log skip message when GUILD_ROSTER_UPDATE arrives while refresh in progress
- **RESULT**:
  - **Maximum one roster refresh operation in-flight at any time**
  - **Prevents cascading retries** when GUILD_ROSTER_UPDATE fires during zone transitions
  - **Eliminates overlap with ChatThrottleLib** chunk processing during sends
  - **Combined with PERF-008/013/014/015/016/017/018:** Should eliminate execution limit errors completely
- **LOCATION**:
  - Events.lua GUILD_ROSTER_UPDATE() (~305-360): Added refreshInProgress guard check at start, set flag before deferral, clear flag in deferred completion

#### [PERF-018] Deferred Debug Options UI Creation Until Needed (MEDIUM)

- **FIXED**: Debug options UI no longer built at addon load - created lazily on first access
- **PROBLEM**: BuildDebugArgs() created ~55 AceConfig entries (15 categories, 28 sub-tags, 12 headers/buttons) during Options:Init() at addon load
- **ROOT CAUSE**: Debug tab args field called BuildDebugArgs() directly in options table definition, executing at addon start regardless of whether user ever opens Debug tab
- **IMPACT**: Contributed to intermittent "execution limit exceeded" errors (1 in 5 login/reload/zone changes) when combined with other init operations (GUILD_ROSTER_UPDATE retries, event registration, AceComm prefixes)
- **BEHAVIOR**: Every login/reload created all debug category/tag options UI (~55 elements), even though most users never open Debug tab
- **SOLUTION**:
  1. Change debug tab args from direct BuildDebugArgs() call to lazy function
  2. Function checks TOGBankClassic_Options.debugArgsBuilt flag
  3. First access builds UI and caches result; subsequent accesses return cached table
- **RESULT**:
  - **Default (never open Debug tab):** Zero options UI creation overhead at addon load
  - **First time opening Debug tab:** Builds ~55 entries and caches
  - **Subsequent opens:** Instant (reuses cache)
  - **Combined with PERF-008/013/014/015/016/017:** Reduced intermittent execution limit errors
- **LOCATION**:
  - Options.lua Init() debug tab definition (~372-384): Changed args from BuildDebugArgs() call to lazy function with caching

#### [PERF-017] Cleaned Up Unnecessary SavedVariables Persistence (LOW)

- **FIXED**: Removed unnecessary SavedVariables from being persisted to disk
- **PROBLEM 1**: TOGBankClassicIcon was declared in SavedVariables but always nil (never used)
- **PROBLEM 2**: TOGBankClassic_PerfMetrics persisted ~400 lines per session even when TOGBankClassic_PerfEnabled = false
- **PROBLEM 3**: TOGBankClassic_MailDebugLog was developer debugging code left in production, persisting at every logout
- **ROOT CAUSE**: SavedVariables list included unused/debug variables; perf metrics didn't clear when disabled
- **IMPACT**: Unnecessary data written to SavedVariables on every logout, increasing file size and parse time
- **SOLUTION**:
  1. Removed TOGBankClassicIcon from .toc SavedVariables declaration
  2. Set TOGBankClassic_PerfMetrics = nil when performance tracking is disabled (similar to PERF-014/016 pattern)
  3. Removed TOGBankClassic_MailDebugLog entirely - deleted from .toc and removed entire debug block from PLAYER_LOGOUT
- **RESULT**:
  - **TOGBankClassicIcon:** No longer persisted (was always nil anyway)
  - **PerfMetrics:** Only persists when explicitly enabled; cleared to nil when disabled
  - **MailDebugLog:** Completely removed (was dev debugging, not production feature)
  - **File size savings:** ~400-600 lines removed from SavedVariables for typical user
- **LOCATION**:
  - TOGBankClassic.toc (~7): Removed TOGBankClassicIcon and TOGBankClassic_MailDebugLog from SavedVariables
  - Performance.lua Initialize() (~42): Added TOGBankClassic_PerfMetrics = nil when disabled
  - Events.lua PLAYER_LOGOUT (~278-345): Removed entire MailDebugLog collection block

#### [PERF-016] Fixed Performance Tracking Initialization Overhead (LOW)

- **FIXED**: Performance tracking now skips all initialization when disabled (default)
- **PROBLEM**: Performance:Initialize() always created sessions, ran GC, initialized data structures even when TOGBankClassic_PerfEnabled = false (default)
- **ROOT CAUSE**: Initialize() didn't check enabled flag before expensive operations
- **IMPACT**: Session creation, table inserts, GC loops for a disabled debugging feature on every addon load
- **BEHAVIOR**: Initialize() checked enabled flag AFTER creating tables and running GC
- **SOLUTION**:
  1. Move TOGBankClassic_PerfEnabled nil check to top of Initialize()
  2. Early return if TOGBankClassic_PerfEnabled is false
  3. Only create tables, run GC, and initialize session when explicitly enabled
- **RESULT**:
  - **Default (disabled):** Zero overhead - no tables created, no GC, no session initialization
  - **When enabled:** Normal behavior - creates sessions, tracks metrics, runs GC
  - **Load time savings:** Skip all performance tracking initialization for 99% of users
- **LOCATION**:
  - Performance.lua Initialize() (~33-48): Reordered to check flag first, early return if disabled

#### [PERF-015] Fixed UI Frame Creation During Addon Load (MEDIUM)

- **FIXED**: Inventory, Donations, Mail, Search, and Requests windows now defer frame creation until first Open()
- **PROBLEM**: All 5 UI modules called DrawWindow() during Init() at addon load, creating AceGUI frames (windows, buttons, scrollframes, etc.) that may never be opened
- **ROOT CAUSE**: Init() unconditionally called DrawWindow() instead of deferring to first use
- **IMPACT**: Frame creation overhead at load for 5 windows that most users won't open every session
- **BEHAVIOR**: Init() → DrawWindow() → AceGUI:Create("Frame") + create all child widgets → frames held in memory all session
- **LAZY PATTERN**: All 5 modules already had `if not self.Window then self:DrawWindow() end` check in Open() function
- **SOLUTION**:
  1. Remove DrawWindow() call from Init() in Inventory, Donations, Mail, Search, Requests
  2. Rely on existing lazy initialization check in Open() function: `if not self.Window then self:DrawWindow() end`
  3. Frame creation only happens when user actually opens the window
- **RESULT**:
  - **On load:** Init() does nothing (or just initializes state variables), zero frame creation
  - **First Open():** Checks `if not self.Window`, calls DrawWindow(), caches frame
  - **Subsequent opens:** Reuses cached frame
  - **Load time savings:** Skip creating 5 AceGUI windows + all child widgets unless actually used
  - **Memory savings:** Don't hold unused frame objects in memory
- **LOCATION**:
  - UI/Inventory.lua Init() (~3-5): Removed DrawWindow() call, added PERF-015 comment
  - UI/Donations.lua Init() (~3-5): Removed DrawWindow() call, added PERF-015 comment
  - UI/Mail.lua Init() (~3-5): Removed DrawWindow() call, added PERF-015 comment
  - UI/Search.lua Init() (~3-5): Removed DrawWindow() call, added PERF-015 comment
  - UI/Requests.lua Init() (~365-371): Removed DrawWindow() call, added PERF-015 comment

#### [PERF-014] Fixed Persistent Debug Log Loading Unconditionally (HIGH)

- **FIXED**: Persistent debug log (SavedVariables) now only loads/saves when explicitly enabled by user (OFF by default)
- **PROBLEM**: Output:Init() always loaded TOGBankClassicDB_DebugLog from SavedVariables (up to 50,000 entries) even though persistent logging was disabled by default
- **ROOT CAUSE**: Load/save logic didn't check TOGBankClassic_DebugLogEnabled flag before accessing SavedVariables
- **IMPACT**: Every player paid the cost of parsing 1-5 MB of debug log entries on every reload, plus garbage collection loop checking 50k timestamps, even though 99% never enable persistent logging
- **BEHAVIOR**: Init() unconditionally loaded log → GarbageCollectPersistentLog() looped through all entries → held 50k entries in memory all session
- **CLARIFICATION**: Regular debug logging (showing messages in chat/debug frame) works independently from persistent logging (saving to SavedVariables). Debug categories control what's shown; persistent logging checkbox controls whether messages are also saved to disk.
- **SOLUTION**:
  1. Check TOGBankClassic_DebugLogEnabled in Init() - only load if true
  2. Check TOGBankClassic_DebugLogEnabled in SavePersistentLog() - only save if true
  3. Check TOGBankClassic_DebugLogEnabled in AddToPersistentLog() - only add if true
  4. Updated option description to clarify persistent logging is separate from regular debug message display
- **RESULT**:
  - **Default (disabled):** Debug messages still show in chat but NOT saved to SavedVariables. Zero parsing overhead, zero GC, empty log array
  - **When enabled:** Debug messages shown in chat AND saved to SavedVariables for later review via /togbank debuglog
  - **Load time savings:** Skip parsing 1-5 MB of text and GC loop on every reload for 99% of users
  - **Memory savings:** Don't hold 50k log entries unless explicitly enabled
- **LOCATION**:
  - Output.lua Init() (~72-89): Added TOGBankClassic_DebugLogEnabled check before loading
  - Output.lua SavePersistentLog() (~456-470): Added early return if disabled
  - Output.lua AddToPersistentLog() (~418-433): Added early return if disabled
  - Options.lua debugLogEnabled (~302-324): Updated to clarify persistent logging vs regular debug messages

#### [PERF-013] Fixed ChatThrottleLib Timeout from Zone Change Message Spam (CRITICAL)

- **FIXED**: PLAYER_ENTERING_WORLD now only triggers roster refresh + broadcasts on login/reload, NOT on zone changes
- **PROBLEM**: "Script ran too long" in ChatThrottleLib.lua:389 during zone changes
- **ROOT CAUSE**: PLAYER_ENTERING_WORLD fires on EVERY zone change, triggering 2 GUILD broadcasts per player (togbank-r + togbank-hl)
- **IMPACT**: When 40+ players enter MC/BWL simultaneously, 80+ messages queue instantly and overwhelm ChatThrottleLib's message queue
- **BEHAVIOR**: Zone changes → PLAYER_ENTERING_WORLD → needsFullRosterRefresh=true → GUILD_ROSTER_UPDATE → QueryRequestsIndex + SyncDeltaVersion → 2 GUILD broadcasts
- **CUMULATIVE EFFECT**: Every player in guild broadcasts on every zone, causing "bMyTraffic = true" loops in ChatThrottleLib Despool to exceed execution time
- **SOLUTION**:
  1. Check `isInitialLogin` and `isReloadingUi` parameters from PLAYER_ENTERING_WORLD event
  2. Only set `needsFullRosterRefresh = true` on login/reload (not zone changes)
  3. Zone changes skip roster refresh entirely (no broadcasts)
  4. OnShareTimer still broadcasts every 10 minutes (periodic sync unaffected)
- **RESULT**:
  - **Login/Reload**: Normal behavior (2 GUILD broadcasts per player)
  - **Zone Change**: Zero broadcasts (no ChatThrottleLib queue spam)
  - **Raid Entry**: No more timeout errors when 40 players zone together
  - **Data Freshness**: OnShareTimer maintains 10-minute sync cycle
- **LOCATION**:
  - Events.lua PLAYER_ENTERING_WORLD (~348-367): Added isInitialLogin/isReloadingUi check
  - Events.lua GUILD_ROSTER_UPDATE (~362-413): Only fires deferred block when needsFullRosterRefresh=true

#### [PERF-008] Fixed Bagnon Execution Timeout from BAG_UPDATE Spam (CRITICAL)

- **FIXED**: ItemHighlight now registers BAG_UPDATE events ONLY when highlighting is actively enabled by a banker (on-demand registration)
- **PROBLEM**: Bagnon exceeded execution time limit during zone changes, affecting even non-banker characters
- **ROOT CAUSE 1**: BAG_UPDATE events were processed by ALL players during zone changes (50+ events in 0.2 seconds)
- **ROOT CAUSE 2**: Each addon with BAG_UPDATE handlers adds to cumulative execution budget, even if handler does nothing
- **ROOT CAUSE 3**: Highlighting doesn't need ANY events until a banker explicitly enables it, but events were registered at addon load
- **IMPACT**: "Script from Bagnon has exceeded its execution time limit" errors on zone change for ALL guild members
- **BEHAVIOR**: Zone changes fire 50+ rapid BAG_UPDATE events; cumulative processing across all addons exceeded Bagnon's execution time limit
- **SOLUTION**:
  1. **CRITICAL FIX**: Don't register ANY events at Initialize() - highlighting doesn't need them yet
  2. When banker clicks "Enable Highlighting" in Requests tab, check banker status and register events
  3. When banker clicks "Disable Highlighting", unregister ALL events
  4. **Result**: Zero overhead for everyone until feature is actively used
  5. Events include throttling (500ms) and search string caching when registered
  6. Prevents rapid-fire Bagnon UI rebuilds during zone transitions
- **RESULT**:
  - **Non-bankers:** NEVER register BAG_UPDATE events (zero overhead forever)
  - **Bankers with highlighting disabled:** Zero overhead (same as non-bankers)
  - **Bankers with highlighting enabled:** Events registered on-demand with throttling + caching
  - **Guild-wide:** Eliminated Bagnon execution timeout errors completely
- **WHY THIS IS THE CORRECT APPROACH**: Highlighting only needs to work when actively fulfilling orders. There's no reason to have ANY event handlers registered during normal gameplay, at addon load, or during zone changes. On-demand registration = zero overhead until actually needed.
- **COMPARISON TO PREVIOUS APPROACHES**:
  - v1: Registered events for all, checked `self.enabled` → all players processed 50+ events
  - v2: Early exit in Initialize if not banker → broke highlighting (guild data not loaded)
  - v3: Lazy check on first event, then unregister → non-bankers still processed first batch
  - v4: Wait for GUILD_ROSTER_UPDATE, then register → still registered events before needed
  - v5 (FINAL): On-demand registration only when highlighting enabled → zero overhead until used
- **LOCATION**:
  - ItemHighlight.lua registerBagEvents (~23-59): Register BAG_UPDATE events when highlighting enabled
  - ItemHighlight.lua unregisterBagEvents (~62-74): Unregister events when highlighting disabled
  - ItemHighlight.lua Initialize (~77-84): Minimal initialization, no event registration
  - ItemHighlight.lua SetEnabled (~87-136): Check banker status, register/unregister events based on enabled state

#### [HASH-001] Fixed Hash Broadcast Not Triggering P2P Requests (CRITICAL)

- **FIXED**: hash-list-broadcast handler now triggers P2P requests for changed data
- **PROBLEM**: `/togbank share` only updated latestBankerHashes cache without triggering any data requests
- **IMPACT**: Complete sync failure - receivers saw "Updated banker hashes" but never requested changed data
- **BEHAVIOR**: Users had to manually run `/togbank sync` or wait 3 minutes for auto-sync timer
- **ROOT CAUSE**: hash-list-broadcast (togbank-hl) only cached hashes, while hash-list-reply (togbank-hlr) also compared and broadcast P2P
- **INCONSISTENCY**: Same data (hash updates) handled differently depending on source (broadcast vs reply)
- **SOLUTION**:
  - hash-list-broadcast handler updates latestBankerHashes cache (immediate)
  - Converts message to hash-list-reply format
  - Recursively calls OnCommReceived with "togbank-hlr" prefix to reuse existing logic
  - hash-list-reply handler now updates cache incrementally (not replacement) to support partial broadcasts
  - Avoids code duplication - single code path for all hash processing
- **RESULT**: `/togbank share` now triggers immediate P2P broadcasts, data syncs automatically
- **LOCATION**: `Modules/Chat.lua` (~1773-1800, ~1816-1828): Forward broadcast to reply handler, incremental cache update
- **NOW**: Hash broadcasts work identically whether from `/togbank share` (broadcast) or `/togbank sync` (reply)

#### [COMM-003] Fixed Offline Player Detection from Whisper Errors

- **FIXED**: CHAT_MSG_SYSTEM now detects "No player named X is currently playing" errors
- **PROBLEM**: Addon repeatedly attempted whispers to offline players causing error spam
- **ROOT CAUSE**: CHAT_MSG_SYSTEM handler only detected "has gone offline" but not whisper failure errors
- **IMPACT**: Hundreds of error messages when trying to communicate with offline players
- **SOLUTION**:
  - Added pattern matching for "No player named X is currently playing" in CHAT_MSG_SYSTEM
  - When detected, immediately marks player as offline in both onlineMembers and recentlySeen caches
  - Updated UpdateOnlineMember() to clear recentlySeen cache when marking offline
  - Added debug logging for all online/offline state changes
- **RESULT**: Player marked offline immediately when whisper fails, preventing repeat attempts
- **LOCATION**:
  - Events.lua CHAT_MSG_SYSTEM (~334-375): Added error pattern detection
  - Guild.lua UpdateOnlineMember (~1425-1443): Clear recentlySeen on offline

#### [COMM-003b] Fixed Whisper Error Pattern Not Matching Single-Quoted Names

- **FIXED**: CHAT_MSG_SYSTEM now detects both single-quoted and unquoted variants of whisper failure messages
- **PROBLEM**: Pattern only matched `No player named Axkva is currently playing.` but Classic Era can also send `No player named 'Axkva' is currently playing.` (with single quotes around name)
- **ROOT CAUSE**: COMM-003 documentation incorrectly stated "Classic Era does NOT use quotes" but testing showed single quotes are sometimes used around player names
- **IMPACT**: Whisper failures with single-quoted names not detected, causing repeated whisper attempts and error spam
- **SOLUTION**:
  - Added dual pattern matching: tries single-quoted pattern `'(.+)'` first, falls back to unquoted `(.+)` if no match
  - Updated documentation to reflect both formats are possible
- **RESULT**: All whisper failure formats now detected, player marked offline immediately
- **LOCATION**:
  - Events.lua CHAT_MSG_SYSTEM (~353-361): Dual pattern matching
  - DELTA_BUGS.md (~2521-2527): Updated pattern documentation

#### [COMM-003c] Fixed Whisper Error Messages Still Appearing in Chat

- **FIXED**: Added chat message filter to suppress "No player named X is currently playing" errors from appearing in chat
- **PROBLEM**: While COMM-003/COMM-003b fixed offline detection, the error messages still appeared in chat window
- **ROOT CAUSE**: Event handler detected and processed errors but didn't suppress chat display
- **IMPACT**: Chat spam with "No player named 'X' is currently playing" even though addon correctly marked players offline
- **SOLUTION**:
  - Added ChatFrame_AddMessageEventFilter for CHAT_MSG_SYSTEM
  - Filter returns true to suppress any message matching "No player named .+ is currently playing."
  - Works for both single-quoted and unquoted name variants
- **RESULT**: Error messages silently handled - player marked offline without chat spam
- **LOCATION**:
  - Events.lua RegisterEvents (~59-66): Added chat message filter

#### [PERF-009] Fixed ChatFrame_AddMessageEventFilter Performance Issue

- **FIXED**: Optimized chat filter to use fast plain-text check before pattern matching
- **PROBLEM**: Stuttering during gameplay immediately after adding chat filter in COMM-003c
- **ROOT CAUSE**: Pattern match ran on EVERY CHAT_MSG_SYSTEM event (guild achievements, player online/offline, etc)
- **IMPACT**: 20-30 expensive pattern matches per minute causing ~10-30ms cumulative frame time waste
- **SOLUTION**:
  - Added fast plain-text prefix check: `find("No player named ", 1, true)` (~0.01ms)
  - Pattern match only runs if prefix found (rare - only actual whisper errors)
  - 99%+ of events skip expensive pattern matching
- **RESULT**: 50x performance improvement, stuttering eliminated while maintaining error suppression
- **LOCATION**:
  - Events.lua Initialize (~59-68): Added plain-text prefix check before pattern match

#### [PERF-010] Fixed Login Freeze from Synchronous Data Migrations

- **FIXED**: Deferred Database:Load() migrations and hash cache initialization to eliminate 3-5 second freeze on login/reload
- **PROBLEM**: Game completely froze for 3-5 seconds when logging in or reloading UI with large SavedVariables (70+ alts)
- **ROOT CAUSE**: Database:Load() synchronously looped through ALL alts performing migrations on EVERY login - most expensive was RecalculateAggregatedItems() for each banker alt (~30-50ms per alt)
- **IMPACT**: Cannot move, cast spells, or interact during freeze - appeared as if game crashed
- **WHY DEFERRABLE**: Data already loaded from SavedVariables, migrations are cleanup/optimization operations that don't need to be immediate
- **SOLUTION**:
  - Wrapped entire Database:Load() migration block in C_Timer.After(0.5)
  - Also deferred latestBankerHashes initialization in Guild:Init (lighter but still blocking)
  - Migrations run in background after UI becomes responsive
  - Still complete before first UI interaction or sync
- **RESULT**: Instant login, no freeze, migrations ready before first use
- **LOCATION**:
  - Database.lua Load (~175-243): Deferred migration block
  - Guild.lua Init (~295-313): Deferred latestBankerHashes initialization
- **LOCATION**:
  - Events.lua Initialize (~59-68): Added plain-text prefix check before pattern match

#### [COMM-003d] Fixed recentlySeen Cache Undermining Guild Roster Cache (CRITICAL)

- **FIXED**: Removed recentlySeen cache, IsPlayerOnline now uses only guild roster cache
- **PROBLEM**: Addon still tried to whisper players for 5 minutes after they logged off
- **ROOT CAUSE**: IsPlayerOnline checked both onlineMembers (accurate) and recentlySeen (5-minute stale cache)
- **FLOW**: Player sends message → added to recentlySeen → logs off → onlineMembers cleared correctly → but recentlySeen keeps them "online" for 5 minutes → whispers sent → errors
- **IMPACT**: Despite accurate guild roster updates (COMM-003), whisper errors still occurred due to secondary stale cache
- **WHY IT EXISTED**: Originally added for "cross-realm/cross-guild" players, but this is a guild-only addon
- **SOLUTION**:
  - Removed recentlySeen check from IsPlayerOnline - guild roster cache is single source of truth
  - Removed MarkPlayerSeen call in Chat.lua
  - MarkPlayerSeen() kept as no-op for backwards compatibility
- **RESULT**: IsPlayerOnline returns false immediately when player logs off, no stale 5-minute window
- **LOCATION**:
  - Guild.lua IsPlayerOnline (~1542-1547): Removed recentlySeen logic, only check onlineMembers
  - Guild.lua MarkPlayerSeen (~1533-1537): Made no-op
  - Chat.lua OnCommReceived (~617-619): Removed MarkPlayerSeen call

#### [DELTA-020] Fixed Delta Computation Using Wrong Baseline (CRITICAL)

- **FIXED**: ComputeDelta now uses requester's actual item structures from state summary instead of responder's snapshot
- **PROBLEM**: When responder broadcast multiple times (hash 461905621 → 317352773), GetSnapshot returned responder's NEW snapshot (317352773) instead of requester's OLD baseline (461905621)
- **IMPACT**: Item count duplication/corruption - delta computed as (317352773 - 317352773) = empty/minimal instead of (317352773 - 461905621) = proper changes
- **BEHAVIOR**: Requester with hash 461905621 applied incorrect delta to their old data, causing items to double instead of updating
- **ROOT CAUSE**:
  - Snapshot system stores ONE snapshot per alt (keyed only by altName, not hash)
  - When responder broadcasts twice, old snapshot overwritten (461905621 deleted, only 317352773 remains)
  - State summary previously sent aggregated items `{[itemID] = count}` (useless for delta computation)
  - ComputeDelta used GetSnapshot(altName) which returned responder's OWN latest state, not requester's actual baseline
- **DESIGN ISSUE**: Delta needs requester's actual item structure (bank/bags/mail) to compute `delta = current - requester's baseline`
- **SOLUTION**:
  1. Modified ComputeStateSummary to send minimal item structures `{ID, Count}` (no Links) for separate bank/bags/mail arrays
  2. Modified ComputeDelta to accept optional `requesterBaseline` parameter with minimal structures
  3. ComputeDelta now uses requester's sent baseline as `previous` instead of GetSnapshot when available
  4. RespondToStateSummary extracts bank/bags/mail from state summary and passes through SendAltData → ComputeDelta chain
  5. SendAltData signature updated to accept and forward requesterBaseline parameter
  6. All SendAltData call sites updated to pass baseline (or nil for legacy paths)
- **BANDWIDTH SAVINGS**: Minimal structures ~1-2KB vs full with Links ~20-50KB (~85% reduction)
- **RESULT**: Delta computation uses correct baseline - requester's actual data (what they have) vs responder's current (what to send)
- **LOCATIONS**:
  - Guild.lua ComputeStateSummary (~1485-1542): Send bank/bags/mail arrays with {ID, Count} only
  - Guild.lua SendStateSummary (~1593-1606): Updated logging to count bank+bags+mail items
  - Guild.lua RespondToStateSummary (~1640-1644): Extract requesterBaseline from state summary
  - Guild.lua SendAltData (~2231, ~2301): Added requesterBaseline parameter
  - Guild.lua ComputeDelta wrapper (~2862): Pass through requesterBaseline
  - DeltaComms.lua ComputeDelta (~565-620): Accept requesterBaseline, use expandMinimalItems() helper, compute from requester's actual data
- **NOW**: Proper delta application - item counts update correctly without duplication, works regardless of how many broadcasts requester missed
- **RELATED**: Completes DELTA-019 fix - hash stays at local value until correct delta (computed from actual baseline) received and applied

#### [DELTA-019] Fixed Premature Hash Update Before Data Received (CRITICAL)

- **FIXED**: Removed HLR first pass branch that updated hash when `localHash == 0`
- **PROBLEM**: Hash updated from banker's broadcast before delta data arrived and was applied
- **IMPACT**: Data/hash desynchronization - old data stored with new hash value
- **BEHAVIOR**: User has hash 529743613 with data, banker broadcasts 461905621, hash immediately updates to 461905621 but old data remains
- **CONSEQUENCE**: Future sync attempts see matching hashes and skip update, leaving permanent stale data until `/wipe` command
- **ROOT CAUSE**: HLR first pass had three branches:
  1. `if not localAlt` - Create new stub with banker's hash (CORRECT - for brand new alts)
  2. `elseif localHash == 0` - Update existing alt's hash (BUG - fires during pending sync)
  3. `elseif mismatch` - Log mismatch without updating (CORRECT)
- **TRIGGER SCENARIO**: Between HLR broadcasts, localHash becomes 0 (ApplyDelta creates stub, or other process clears it), next HLR hits branch 2 and updates hash prematurely
- **USER SCENARIO**: "i have hash 5xxxx with data, banker sends hash 4xxxx, I should use hash 4xxxx to trigger delta sync comparing hash 5xx with 4xx to determine the delta, and then get new data"
- **ACTUAL BUG BEHAVIOR**: Hash 5xxxx → 4xxxx update happens immediately in HLR first pass, before delta data request sent/received
- **SOLUTION**: Removed branch 2 entirely from HLR first pass (Chat.lua lines 1861-1873)
  - Only create NEW stubs for brand new alts (branch 1)
  - Only update hash in ApplyDelta after successful data application (DeltaComms.lua:971)
  - Hash mismatch detection (branch 3) triggers requests without updating hash
- **RESULT**: Hash stays at local value until delta received and applied, maintaining data/hash consistency
- **LOCATION**: Chat.lua HLR handler first pass (~1847-1878): Removed `elseif localHash == 0` branch
- **RELATED**: Works with DELTA-018 fix - latestBankerHashes cache tracks "what banker says", local inventoryHash tracks "what data we have", only ApplyDelta updates local hash

#### [DELTA-018] Fixed Hash Broadcast Circular Comparison (CRITICAL)

- **FIXED**: Hash sync protocol now maintains separate in-memory cache from local storage
- **PROBLEM**: hash-list-broadcast immediately updated local alt.inventoryHash, then comparison read from same local storage
- **IMPACT**: Complete sync failure - /togbank share broadcasts updated hash without triggering sync requests
- **BEHAVIOR**: Receivers had stale data but /togbank hashdebug showed "matched" (compared local hash against itself)
- **ROOT CAUSE**: Circular comparison - BuildBankerHashList() read from alt.inventoryHash, ReportHashListCoverage compared alt.inventoryHash vs BuildBankerHashList() output (both same source)
- **DESIGN FLAW**: No separation between "banker's authoritative hash" (what they broadcast) vs "hash of data we actually have" (what's in SavedVariables)
- **SOLUTION**:
  - Initialize `latestBankerHashes` in-memory cache on addon load from all local alt.inventoryHash values
  - hash-list-broadcast handler: Only update cache, never modify local storage
  - hash-list-reply handler: Only update cache on mismatch, never modify local storage
  - ReportHashListCoverage: Use latestBankerHashes exclusively (no BuildBankerHashList, no merge)
  - Local alt.inventoryHash: Only updated when actual delta data received and applied
- **CACHE STRUCTURE**: `{hash, updatedAt, version, mailHash, mailUpdatedAt}` per alt
- **COMPARISON LOGIC**: cache.hash ("what banker says") vs localAlt.inventoryHash ("what we have")
- **RESULT**: Proper mismatch detection - cache updated by broadcasts, local unchanged until delta received, comparison detects staleness
- **LOCATION**:
  - Guild.lua Init (~276-290): Initialize latestBankerHashes from SavedVariables
  - Guild.lua ReportHashListCoverage (~693-710): Use cache directly for comparison
  - Chat.lua hash-list-broadcast (~1773-1795): Update cache only
  - Chat.lua hash-list-reply (~1843-1847): Update cache only on mismatch
- **VERIFICATION**: Tested with manual hash revert - broadcast updated cache, local stayed stale, hashdebug showed pending, sync requested delta

#### [DELTA-016] Fixed Delta Protocol Sending Aggregated Items (CRITICAL)

- **FIXED**: ComputeDelta now sends separate bank/bags/mail inventories instead of aggregated items
- **PROBLEM**: Used `alt.items` (UI display field) which was often empty on sender side despite non-zero hash
- **IMPACT**: Complete data sync failure - deltas contained only money updates, no item data
- **BEHAVIOR**: Debug showed "hasChanges.items=false, itemCount=0" with non-zero inventoryHash (contradiction)
- **ROOT CAUSE**: `alt.items` computed during Bank:Scan() for UI aggregation, not guaranteed during delta computation
- **PROTOCOL DESIGN**: Should send bank/bags/mail separately so receiver populates individual inventories
- **SOLUTION**:
  - ComputeDelta: Source from `currentAlt.bank.items`, `bags.items`, `mail.items` separately
  - ApplyDelta: Apply to `current.bank.items`, `bags.items`, `mail.items` individually
  - Recalculate aggregated `current.items` after delta application (UI display only)
  - DeltaHasChanges: Check bank/bags/mail separately
  - ValidateDeltaStructure: Validate mail delta
  - SanitizeDelta: Sanitize mail delta
  - StripDeltaLinks: Strip mail links
- **RESULT**: Deltas now contain actual item data (ID + Count) in separate bank/bags/mail structures
- **LOCATION**: `DeltaComms.lua` ComputeDelta (~627-648), ApplyDelta (~912-969), DeltaHasChanges, validation/sanitization
- **NOW**: Full inventory synchronization working - items populate correctly on receiver side

#### [DELTA-017] Fixed Empty Baseline Missing Bank/Bags/Mail Structures (CRITICAL)

- **FIXED**: ComputeDelta empty baseline now includes bank/bags/mail structures
- **PROBLEM**: Empty baseline fallback only had `{ items = {}, money = 0, mailHash = 0 }` without bank/bags/mail
- **IMPACT**: First-time sync sent empty deltas despite sender having inventory data
- **BEHAVIOR**: ComputeDelta compared empty baseline to sender's current but both appeared empty
- **ROOT CAUSE**: When accessing `previous.bank.items`, defaulted to `{}` but didn't distinguish between incomplete baseline vs empty inventory
- **SOLUTION**:
  - Changed empty baseline to include complete structures:
    `{ items = {}, money = 0, mailHash = 0, bank = { items = {} }, bags = { items = {} }, mail = { items = {} } }`
  - Fixed in 3 locations: mail-only change without snapshot, hash mismatch without snapshot, requester has no data
- **RESULT**: First-time sync and hash mismatch scenarios now send actual items (not empty deltas)
- **LOCATION**: `DeltaComms.lua` ComputeDelta empty baseline initialization (~594, ~606, ~613)
- **NOW**: All sync scenarios populate receiver correctly with sender's inventory data

#### [MAIL-010] Fixed Mail-Only Change Sync Abort (CRITICAL)

- **FIXED**: ComputeDelta now uses empty baseline fallback instead of returning nil
- **PROBLEM**: When mail changed but inventory matched, and no snapshot existed, returned nil (line 567)
- **IMPACT**: Complete sync failure - requesters with matching inventory but outdated mail never received updates
- **BEHAVIOR**: Guild.lua aborted sync at line 2054-2055 with "Failed to compute delta" error
- **ROOT CAUSE**: Inconsistent error handling - inventory mismatch used empty baseline, mail-only change returned nil
- **SOLUTION**: Changed to `previous = { items = {}, money = 0, mailHash = 0 }` (same as inventory mismatch case)
- **RESULT**: Mail-only changes always sync successfully via delta (contains all items as additions against empty baseline)
- **LOCATION**: `DeltaComms.lua` (~557-567): Mail-only change handler now matches inventory mismatch fallback behavior
- **NOTE**: Still pure delta protocol - empty baseline causes delta to include all items, but transmitted as delta message

#### [P2P-010] Fixed P2P Broadcast Never Sent (CRITICAL)

- **FIXED**: togbank-rr handler now actually sends P2P broadcast to guild
- **PROBLEM**: Handler built P2P request but never serialized or sent it
- **IMPACT**: P2P only worked when no banker online initially; failed when banker responded with hash (common case)
- **BEHAVIOR**: Request was built, log said "Broadcasting", but SendCommMessage was missing
- **RESULT**: 5-second timeout always triggered, forcing 100% fallback to banker despite peers having data
- **LOCATION**: `Chat.lua` (~1053-1054): Added missing SerializeWithChecksum and SendCommMessage calls
- **NOW**: Full P2P flow works - peers receive broadcasts and respond with matching hashes

#### [P2P-011] Fixed pendingSendCount Leak

- **FIXED**: Added 30-second timeout to auto-decrement counter when requester never sends state summary
- **PROBLEM**: Peer ACKs request and increments counter, but if requester goes offline before sending state summary, counter never decrements
- **IMPACT**: After 3 stuck sends, peer permanently blocks all P2P responses with "send queue full" until `/reload`
- **BEHAVIOR**: Now auto-decrements counter after 30 seconds if SendAltData never called
- **RESULT**: Peers self-recover from stuck sends, preventing permanent P2P queue blocking
- **LOCATIONS**:
  - `Guild.lua` (~22): Added pendingSendTimeouts tracking table
  - `Chat.lua` (~829-838): Added 30-second safety timeout after incrementing counter
  - `Guild.lua` (~1997-2000): Cancel timeout when SendAltData actually called
- **NOW**: Robust P2P send queue management with automatic recovery from edge cases

#### [P2P-012] Added Peer-Side Fallback Timeout

- **FIXED**: Added 15-second timeout on requester side after peer ACK
- **PROBLEM**: If peer ACKs but never sends data (disconnect/crash), requester waits indefinitely
- **IMPACT**: User must manually retry with `/togbank sync`
- **BEHAVIOR**: Now falls back to banker after 15 seconds if peer never delivers
- **RESULT**: Automatic recovery from peer failures without manual intervention
- **LOCATION**: `Chat.lua` (~1091-1101): Secondary timeout after clearing pending P2P request
- **NOW**: Full fallback chain works - peer timeout → banker fallback → data arrives

#### [P2P-013] Fixed expectedHashUpdatedAt Memory Leak

- **FIXED**: Added cleanup for expectedHashUpdatedAt after successful hash validation
- **PROBLEM**: Timestamps stored but never cleared, accumulating indefinitely
- **IMPACT**: Minor memory leak (just timestamps), no functional impact
- **RESULT**: Clean memory management for hash tracking
- **LOCATION**: `Guild.lua` (~2250-2252): Clear expectedHashUpdatedAt after validation

#### [PERF-007] Fixed GUILD_ROSTER_UPDATE Stuttering

- **FIXED**: Changed OR to AND logic in initialization condition to stop repeated full roster refreshes
- **PROBLEM**: Used `fullRosterInitAttempts < 2 OR (roster incomplete)` which kept triggering after initialization
- **IMPACT**: Every online/offline event triggered full guild roster scan (1000+ members), causing 5-10ms+ stuttering
- **BEHAVIOR**: After 2 initialization attempts, `fullRosterInitAttempts >= 2` BUT condition stayed true due to OR
- **ROOT CAUSE**: Second condition `totalMembers <= onlineMembers` often true (WoW API reports equal values)
- **SOLUTION**: Changed to AND logic - only refresh if BOTH conditions true: (not initialized yet) AND (roster incomplete)
- **RESULT**: Full refresh only during addon load, online/offline uses lightweight CHAT_MSG_SYSTEM handler (<1ms)
- **LOCATION**: `Events.lua` (~305-313): Fixed needsFullRosterRefresh flag logic
- **OPERATIONS AVOIDED**: RefreshOnlineCache, RebuildBankerRoster, GetGuildRosterInfo loops, RefreshRequestsUI
- **NOW**: Smooth gameplay without stuttering, full scan only on joins/leaves (not online/offline)
- **DOCUMENTATION**: See `docs/DELTA_BUGS.md` for comprehensive analysis (PERF-005, PERF-007)

#### [DELTA-015] Fixed Delta Duplication Bug (Complete)

- **FIXED**: Added snapshot validation for inventory changes to prevent item duplication
- **PROBLEM**: When inventory changed but no snapshot existed, delta computed against empty baseline
- **IMPACT**: Requester would receive delta additions on top of existing stale data, causing duplicates
- **BEHAVIOR**: Now checks for snapshot before computing delta for both mail-only AND inventory changes
- **RESULT**: Forces full data (hash=0) when no snapshot available, preventing duplication
- **LOCATIONS**:
  - `Guild.lua` (~1568-1594): Mail-only change validation (previously fixed)
  - `Guild.lua` (~1596-1624): Inventory change validation (newly fixed)

#### [SYNC-009] Fixed Non-Banker Hash Sync

- **FIXED**: HLR handler now checks hash equality BEFORE skipping alts
- **PROBLEM**: Previously skipped any alt with hasContent=true without comparing hashes
- **IMPACT**: Non-banker updates never propagated to peers with stale data
- **BEHAVIOR**: Now only skips if BOTH hasContent AND hashes match
- **RESULT**: Non-banker-to-non-banker sync working correctly

#### [MAIL-009] Fixed mailHash Storage When Hashes Differ

- **FIXED**: HLR and HL-broadcast handlers now update mailHash when it differs from banker
- **PROBLEM**: Only stored mailHash when localHash=0, not when hashes differed
- **IMPACT**: Mail-only changes never cached banker's new mailHash
- **LOCATIONS**: Fixed in both HLR handler (togbank-hlr) and hash broadcast handler (togbank-hl)
- **RESULT**: Banker's authoritative mailHash properly cached in all scenarios

**Technical Details:**
```lua
// OLD: Only update when localHash == 0
elseif localHash == 0 then
    localAlt.inventoryHash = summary.hash
    if summary.mailHash then
        localAlt.mailHash = summary.mailHash  // Only here!
    end
end

// NEW: Also update when hashes differ
elseif localHash ~= summary.hash or (localAlt.mailHash or 0) ~= (summary.mailHash or 0) then
    localAlt.inventoryHash = summary.hash
    if summary.mailHash then
        localAlt.mailHash = summary.mailHash  // Now cached properly!
    end
end
```

**Files Changed:**
- `Modules/Chat.lua` (~1740-1753): HLR handler - added elseif block for hash diff
- `Modules/Chat.lua` (~1654-1679): HL broadcast handler - updated stub creation and hash updates
- `docs/DELTA_BUGS.md`: Documented SYNC-009 and MAIL-009 with full analysis

---

## Unreleased - Hash Broadcast Improvements

**Status:** In Development
**Priority:** MEDIUM

### 🔄 Hash Broadcasting Overhaul

#### Changes to `/togbank share`

- **CHANGED**: Now broadcasts hash for ONLY the current banker character (single alt)
- **CHANGED**: Uses togbank-hl channel for hash announcement (P2P discovery)
- **CHANGED**: No longer pushes full data - clients pull data via sync cycle
- **IMPACT**: Reduces spam when banker shares (1 hash vs 35+ data packets)

#### New Command: `/togbank hashupdate`

- **NEW**: Banker-only command to broadcast ALL bank alt hashes (the "nuke")
- **USE CASE**: Force guild-wide hash refresh after bulk inventory changes
- **BEHAVIOR**: Broadcasts hash-list for all bank alts on togbank-hl
- **OUTPUT**: "Broadcasted hash-list for N bank alts"

#### Hash Broadcast Enhancements

- **ENHANCED**: `BuildBankerHashList()` now includes `mailHash` and `mailUpdatedAt`
- **ENHANCED**: Hash-list-broadcast handler stores both inventory and mail hashes
- **ENHANCED**: Handler tracks what changed: "Updated AltName: inv: 123->456, mail: 789->999"
- **FIXED**: Non-bankers can now detect mail-only changes from hash broadcasts
- **BEHAVIOR**: No automatic requests triggered - users must run `/togbank sync` or wait for automatic sync cycle

#### Technical Details

- Hash broadcasts contain: `inventoryHash`, `inventoryUpdatedAt`, `version`, `mailHash`, `mailUpdatedAt`
- Clients update local hash stubs when received
- Actual data requests happen during next sync cycle (manual, UI open, or 3-minute timer)

**Files Changed:**
- `Modules/Guild.lua`:
  - Updated `BuildBankerHashList()` to include mail hashes
  - Modified `Share()` to broadcast single-alt hash on togbank-hl
  - Added `HashUpdate()` function for all-alts hash broadcast
- `Modules/Chat.lua`:
  - Updated hash-list-broadcast handler to store both inventory and mail hashes
  - Added `/togbank hashupdate` command registration
  - Enhanced hash change detection and logging

---

## [v0.8.9] (2026-02-07) - P2P Hash Backfill Complete

**Status:** Production Ready
**Priority:** HIGH

### 🎯 P2P Hash Backfill Implementation

#### Core Features Implemented

- **NEW**: Banker HLR (hash list reply) stores authoritative hashes for all roster alts
- **NEW**: Version broadcasts store peer hashes when local hash is missing
- **NEW**: 3-minute rebroadcast timer requests hash list and rebroadcasts P2P for missing alts
- **NEW**: Roster sync fallback for officer-note-only guilds (config option, default OFF)
- **FIXED**: /wipe now rebuilds banker roster immediately (progress shows 0/35 instead of 0/2)
- **FIXED**: Data payloads always use GUILD channel (removed WHISPER routing for togbank-d3/d4)
- **FIXED**: SendWhisper now correctly treats AceComm nil return as success
- **FIXED**: Nil table access errors in Guild.lua (table initialization before access)
- **FIXED**: Inventory disappearing during async item loads - added loading indicator [UI-005]
- **FIXED**: Severe tooltip performance issues causing PC stuttering
- **ENHANCED**: P2P broadcasts happen for both "pending" (hash mismatch) and "missingContent" (hash match, no data)

### 📝 Technical Details

**Hash Storage Priority System:**

1. **Primary: Banker HLR (togbank-hlr)** - Most authoritative
   - Banker has scanned all alts, provides definitive hash list
   - Stores hash+updatedAt for all roster alts immediately
   - Triggered on /sync, UI open, and every 3 minutes via timer
   - Implementation: Chat.lua lines 1476-1510

2. **Secondary: Peer Version Broadcasts (togbank-dv2)** - Supplemental
   - Fills gaps if HLR not received yet
   - Only stores hash if we don't have one (hash=0 or nil)
   - Implementation: Chat.lua lines 394-434

**Result:** After HLR, all 35 alts have authoritative hashes (pending=0)

**Files Changed:**
- `Modules/Chat.lua`:
  - Added hash storage in HLR handler (two-pass: store hashes, then compare)
  - Added hash storage in version broadcast handler (only if missing)
  - Added debug logging for pending/missingContent broadcasts
- `Modules/Guild.lua`:
  - Added `RebuildBankerRoster()` call to `Reset()` for immediate banker list after /wipe
  - Removed forceFull bypass logic (preserves P2P design)
  - Changed `SendAltData()` to always use GUILD channel for togbank-d3/d4
- `Modules/Events.lua`:
  - Added `RequestHashListFromBanker()` call to `OnShareTimer()` (3-minute rebroadcast)
- `Modules/DeltaComms.lua`:
  - Updated `FastFillMissingAlts()` to use P2P broadcasts when banker offline

**How It Works:**
1. **On /sync or UI open**: Request hash list from banker (togbank-hl)
2. **Banker replies**: Send all alt hashes via togbank-hlr
3. **Store hashes**: Create/update local alt stubs with banker's authoritative hash+updatedAt
4. **Compare**: Categorize as "pending" (hash mismatch) or "missingContent" (hash match, no data)
5. **Broadcast**: Send P2P requests to GUILD for missing alts with expectedHash
6. **Peers respond**: Players with matching hash send data via GUILD
7. **Fallback**: After 5s timeout, query banker directly via whisper
8. **Rebroadcast**: Every 3 minutes, repeat steps 1-7 for still-missing alts

**Design Principles:**
- Banker is authoritative source for hash list
- P2P broadcasts reduce banker load
- GUILD channel for data, WHISPER for handshakes
- Newest-wins conflict resolution using inventoryUpdatedAt timestamps

---

## [v0.8.4] (2026-02-02) - Mail Hash Synchronization Fix

**Status:** Critical Bug Fix
**Priority:** HIGH

### 🐛 Critical Bug Fix

#### [MAIL-012] Mail Hash Never Set - Fixed Mail Synchronization

- **FIXED**: `mailHash` field was referenced but never assigned, breaking mail synchronization
- **ROOT CAUSE**: Mail scan created mail data but never computed hash for change detection
- **IMPACT**: Mail items never synchronized between clients via `/togbank share` or `/togbank sync`
- **FIX**:
  - `Bank.lua` now computes `mailHash` after mail scan using `ComputeInventoryHash()`
  - `DeltaComms.lua` tracks `mailHash` changes in delta computation
  - `DeltaComms.lua` applies `mailHash` changes when receiving deltas
  - `DeltaComms.lua` recognizes `mailHash` as a valid change type
- **RESULT**: Mail data now properly syncs between guild members
- **LOGGING**: Added `[MAIL-012]` debug markers for mail hash operations

### 📝 Technical Details

**Files Changed:**
- `Modules/Bank.lua` - Added mailHash computation after mail scan (lines 289-310)
- `Modules/DeltaComms.lua` - Track mailHash in ComputeDelta() (lines 533-545)
- `Modules/DeltaComms.lua` - Apply mailHash in ApplyDelta() (lines 806-810)
- `Modules/DeltaComms.lua` - Recognize mailHash in DeltaHasChanges() (lines 590-593)
- `docs/DELTA_BUGS.md` - Comprehensive bug documentation with root cause analysis

**How It Works:**
1. When mail is scanned, `mailHash` is computed from `alt.mail.items`
2. `mailHash` changes trigger version updates in deltas
3. Receivers see `mailHash` and know mail data is "new format" (not legacy)
4. Clients can detect mail changes and request updates
5. Backward compatible: clients without `mailHash` still treated as "old format"

---

## [v0.8.0] (2026-01-21) - Pull-Based Delta Protocol

**Branch:** feature/pull-based-delta
**Status:** Testing Phase
**Latest Update:** 2026-01-21 (Evening)

### 🚀 Major Features

#### Pull-Based Protocol with Inventory Hashing

- **NEW**: Hash-based inventory comparison replaces version timestamps
- **NEW**: Automatic pull sync when inventory hashes differ
- **NEW**: Dual broadcast system (`togbank-v` + `togbank-dv`) for compatibility
- **NEW**: `/togbank share` command broadcasts version data with hashes
- **NEW**: Selective querying - only request data when hashes mismatch
- **NEW**: Data migration system computes hashes for existing alts on load
- **NEW**: Fast-fill feature - automatically requests missing banker alts when UI opens or `/togbank sync` is used
- **NEW**: Smart message prioritization - NORMAL priority for reliable delivery
- **NEW**: Communication debug filtering - Optional "(comm)" prefixed debug messages with separate toggle

#### Inventory Hashing System

- `ComputeInventoryHash()` generates numeric hash from bank + bags + money
- Hash computed automatically on bank scan (BANKFRAME_CLOSED event)
- Stored alongside version timestamp in `alt.inventoryHash` field
- More reliable than version timestamps for detecting real changes
- Minimal overhead (single number vs full data comparison)

#### Protocol Simplification

- **REMOVED**: Guild support threshold requirement (was 5% minimum)
- **NEW**: Delta protocol always enabled if `PROTOCOL.SUPPORTS_DELTA = true`
- **NEW**: Works immediately without waiting for guild adoption
- **SIMPLIFIED**: `ShouldUseDelta()` now only checks feature flags

#### Broadcast Enhancements

- **Version Broadcast (`togbank-v`)**: Legacy format with version timestamps only
- **Delta Version Broadcast (`togbank-dv`)**: New format with version + hash
- **Format**: `data.alts[name] = {version = X, hash = Y}`
- **Share Command**: Now sends BOTH broadcasts for maximum compatibility

#### Hash Comparison Logic

- Compares inventory hashes to detect changes
- **We have no data**: Query for everything
- **Hashes differ**: Query for update
- **Hashes match**: Skip query (no changes)
- **No hash available**: Fall back to version comparison
- Handles nil checks gracefully after database wipes

### 🐛 Bug Fixes

#### [SEARCH-003] Search Returning 0 Results

- **Fixed**: Search now correctly processes all aggregated items
- **Root Cause**: BuildSearchData was using `ipairs()` on hash table returned by `Aggregate()`
- **Solution**: Changed to `pairs()` for proper hash table iteration, fixed item counting
- **Impact**: Search functionality now works correctly for all item queries
- Location: Search.lua lines 405-410

#### Mail Data Persistence

- **Removed**: Unused `IsMailDataStale()` function and 1-hour staleness threshold
- **Change**: Mail data now persists indefinitely like bank/bags data
- **Impact**: Mail inventory remains visible regardless of age, with timestamp displayed for information
- Location: MailInventory.lua

#### [UI-002] Item Links Not Appearing After Integration

- **Fixed**: Items now display immediately after async item link reconstruction
- **Root Cause**: `ReconstructItemLinks()` was using async `Item:ContinueOnItemLoad()` callbacks without triggering UI refresh
- **Solution**: Added UI refresh calls after successful link reconstruction (both immediate and async)
- **Impact**: Items now appear in UI as soon as their links become available from WoW API
- Location: Guild.lua lines 970-995

#### [PROTO-001] Delta Validation

- **Fixed**: Delta validation now accepts link-less deltas without `baseVersion`
- Made `baseVersion` field optional in `ValidateDeltaStructure()`
- Maintains backwards compatibility with old protocol deltas
- Location: Core.lua line 118-122

#### [UI-001] Inventory UI Crash

- **Fixed**: UI handles missing `bank.slots` and `bags.slots` data
- Added defensive nil checks in Inventory.lua lines 177-187
- Data migration initializes missing slots fields with `{count = 0, total = 0}`
- Prevents crashes when opening UI with incomplete alt data

#### [DATA-001] Missing Inventory Hashes

- **Fixed**: Existing alt data migrated to include inventory hashes
- Migration runs once on addon load via `Database:InitializeDatabase()`
- Computes hashes from saved bank/bags/money data
- Successfully migrated 60+ existing alts in testing

#### Hash Comparison Edge Cases

- **Fixed**: Handles `nil` hash values after database wipe
- **Fixed**: Pull decision logic checks for missing data
- **Fixed**: Broadcasts send even when no alt data exists locally
- Debug output shows "has bank data for X (we have none), querying"

### 📝 Documentation Updates

- Updated DELTA_IMPLEMENTATION_TODO.md with current architecture
- Documented inventory hashing system and pull protocol flow
- Removed outdated guild support threshold documentation
- Added hash comparison algorithm documentation
- Updated bug tracker (DELTA_BUGS.md) with resolved issues

### 🔧 Technical Changes

- Guild.lua: Added dual broadcast to `Share()` function
- Guild.lua: `FastFillMissingAlts()` auto-requests missing banker alts (lines 458-498)
- Guild.lua: `ReconstructItemLinks()` now refreshes UI after async link loading (lines 970-1008)
- Events.lua: `SyncDeltaVersion()` uses NORMAL priority for reliable delivery (was BULK)
- Events.lua: Changed all query messages from BULK to NORMAL priority
- Chat.lua: Enhanced hash comparison logic with nil handling
- Chat.lua: Added UI auto-refresh when data adopted (togbank-d and togbank-d3 handlers)
- Chat.lua: `/togbank sync` command now also triggers fast-fill for missing alts
- Database.lua: Added hash migration for existing alts
- Database.lua: Added slots migration to prevent UI crashes
- Core.lua: Made baseVersion optional in delta validation
- UI/Inventory.lua: Calls `FastFillMissingAlts()` on Open() in delta mode (line 49)
- Output.lua: Added `DebugComm()` function for filterable communication debug logging
- Options.lua: Added `commDebug` toggle in config UI below log level

### 🎯 Performance Improvements

- Message priority optimization: Changed queries and delta broadcasts from BULK to NORMAL
- Improved responsiveness of pull-based protocol handshake
- Faster UI updates with async item link reconstruction
- Reduced query spam with fast-fill on-demand loading
- Communication debug filtering: Separate toggle for comm debug messages with "(comm)" prefix

### ⚠️ Breaking Changes

None - Full backwards compatibility maintained with v0.7.0 clients

---

## [v0.7.0](https://github.com/EY3G0R3/TOGBankClassic/tree/v0.7.0) (2025-01-17)

**Latest Update:** 2026-01-20 - Fixed error tracking issues

### 🐛 Bug Fixes (2026-01-20)

#### Error Tracking System

- **Fixed**: Error tracking now works even when Guild.Info is not initialized
  - Implemented temporary in-memory storage for errors occurring before guild initialization
  - Automatic migration to database when guild data loads
  - No error data loss during addon startup phase
  - Query functions check both temporary and database storage

- **Fixed**: `RecordDeltaError()` logs debug messages when using temporary storage
  - Shows: "Using temporary error storage for <alt> (<type>): Guild.Info not initialized"
  - Helps identify initialization timing issues

- **Fixed**: Test function `testDeltaErrorTracking()` parameter mismatch
  - Was calling `RecordDeltaError()` with 2 parameters instead of required 3
  - Now correctly passes: `altName`, `errorType`, `errorMessage`
  - Ensures proper error categorization in test suite

**Impact**: Error tracking is now fully functional throughout addon lifecycle, including early delta failures before guild initialization completes.

---

### 🚀 Major Features

#### Delta Sync Protocol

- **NEW**: Intelligent delta synchronization protocol reduces bandwidth by 90-99%
- **NEW**: Automatic protocol version negotiation between v0.6.8 and v0.7.0+ clients
- **NEW**: Smart snapshot management with automatic corruption recovery
- **NEW**: Comprehensive error handling with automatic full sync fallback
- **NEW**: Backward compatible with v0.6.8 clients (seamless mixed-guild support)

#### Bandwidth Optimization

- Only transmits changed items instead of entire inventories
- Automatic size comparison (uses delta only if <30% of full sync size)
- Estimated bandwidth savings: 90-99% for typical inventory updates
- Guild-wide adoption threshold (50%) ensures efficient operation

#### Performance Metrics

- Real-time bandwidth tracking (delta vs full sync)
- Performance monitoring (computation and application times)
- Success rate tracking with automatic failure detection
- Estimated bandwidth savings calculations

### ✨ New Commands

- `/togbank deltastats` - Display comprehensive delta sync statistics including:
  - Bandwidth usage breakdown (delta vs full syncs)
  - Estimated total bandwidth saved
  - Operation counts and success rates
  - Average performance metrics (computation/application times)

- `/togbank deltaerrors` - Show recent delta sync errors for debugging:
  - Last 10 errors with timestamps and error types
  - Failure counts per alt
  - Highlights alts with repeated failures (3+)
  - Persists across /reload

- `/togbank deltahistory` - Show stored delta chain history:
  - Delta storage per alt with version transitions
  - Change types and ages for each delta
  - Verifies chain replay infrastructure is working

- `/togbank protocol` - Show protocol version distribution:
  - Online member protocol versions (v1 vs v2)
  - All-time protocol adoption statistics
  - Delta sync enablement status with threshold indicator
  - Recently seen members with their protocol versions

- `/togbank clearsnapshots` - Clear all delta snapshots (forces next sync to be full)

- `/togbank forcefull` - Toggle forcing full sync mode (temporarily disables delta sync)

- `/togbank resetmetrics` - Reset all delta sync statistics to zero

### 🔧 Technical Improvements

#### Database Layer

- Added `deltaSnapshots` table for efficient snapshot storage (1-hour expiration)
- Added `guildProtocolVersions` table for peer protocol tracking
- Added `deltaMetrics` table for bandwidth and performance tracking
- Implemented snapshot validation and automatic corruption recovery
- Added 23 new database functions for delta operations

#### Guild Module

- Rewrote `SendAltData()` with intelligent protocol selection
- Implemented `ComputeDelta()` for efficient change detection
- Implemented `ApplyDelta()` with robust error handling
- Added error tracking system with repeated failure detection
- Enhanced debug output with detailed size and timing information

#### Communication Layer

- Registered new `togbank-d2` prefix for delta protocol
- Enhanced version broadcast to include protocol capabilities
- Added delta structure validation before application
- Implemented automatic QueryAlt on all failure paths

#### Error Handling & Recovery

- 6 error detection points covering all failure scenarios
- Automatic full sync fallback on any delta failure
- Per-alt failure tracking with user notification (after 3 consecutive failures)
- Automatic failure count reset on successful sync
- Snapshot corruption detection and automatic purge

### 📊 Monitoring & Visibility

#### Enhanced Debug Output

- Delta selection logging with size comparisons and savings calculations
- Performance timing for all delta operations
- Color-coded status indicators (✓/✗) for quick visual parsing
- Detailed error messages with context for troubleshooting

#### Statistics Display

- Bandwidth metrics with color-coded percentages
- Success rate with threshold-based coloring (green ≥95%, yellow ≥80%, red <80%)
- Performance averages for computation and application
- Protocol adoption visualization

### 🧪 Testing & Quality

- Created comprehensive test module with 30+ unit tests
- Test coverage for delta computation, size estimation, protocol negotiation
- Error handling tests for all failure scenarios
- Integration tests for full delta roundtrip
- Backwards compatibility tests for v0.6.8 mixed guilds

### 📝 Documentation

- Added comprehensive README.txt with all commands and features
- Updated installation instructions with CurseForge App (recommended) method
- Added troubleshooting section specific to delta sync issues
- Created detailed DELTA_IMPLEMENTATION_TODO.md documenting all phases
- Added FEATURE_IMPROVEMENTS.md with technical architecture

### 🔄 Protocol Specifications

#### Version 2 Features

- Protocol version: 2
- Supports delta updates: Yes
- Delta size threshold: 30% of full sync
- Snapshot max age: 1 hour
- Guild adoption threshold: 50%

#### Backwards Compatibility

- v0.7.0+ ↔ v0.7.0+: Delta sync via `togbank-d2` (when threshold met)
- v0.7.0+ ↔ v0.6.8: Full sync via `togbank-d` (automatic fallback)
- v0.6.8 ↔ v0.6.8: Full sync via `togbank-d` (unchanged)
- No breaking changes - seamless upgrade path

### 🐛 Bug Fixes

- Fixed potential race conditions in snapshot management
- Improved error messages for version mismatch scenarios
- Enhanced validation to prevent corrupted delta application
- Added nil checks throughout delta codepaths

### ⚙️ Configuration

New constants in `Modules/Constants.lua`:
```lua
PROTOCOL = {
    VERSION = 2,
    SUPPORTS_DELTA = true,
    MIN_DELTA_SIZE_RATIO = 0.3,     -- 30% threshold
    DELTA_SNAPSHOT_MAX_AGE = 3600,  -- 1 hour
    DELTA_SUPPORT_THRESHOLD = 0.5,  -- 50% adoption
}

FEATURES = {
    DELTA_ENABLED = true,           -- Master enable/disable
    FORCE_FULL_SYNC = false,        -- Force full sync for testing
}
```

### 📈 Performance Impact

- **Bandwidth Reduction**: 90-99% for typical inventory updates
- **Computation Overhead**: ~2-3ms average per delta computation
- **Application Overhead**: ~1-2ms average per delta application
- **Memory Impact**: Minimal (~50KB per snapshot, auto-expiring)

### 🔮 Known Limitations

- Delta sync requires 50%+ of online guild to use v0.7.0+ for enablement
- Snapshots expire after 1 hour (forces full sync on first update after expiration)
- Large inventory changes (>30% of items) automatically fall back to full sync
- Options panel GUI for delta configuration deferred to future update

---

## [v2.3.0](https://github.com/GrumpyPlayer/GBankClassic/tree/v2.3.0) (2025-10-27)

[Full Changelog](https://github.com/GrumpyPlayer/GBankClassic/compare/v2.2.0...v2.3.0) [Previous Releases](https://github.com/GrumpyPlayer/GBankClassic/releases)

- Merge pull request #3 from GrumpyPlayer/merge/fix-search-normalization-into-handle-malformed-data
    Merge/fix search normalization into handle malformed data
- fix issues related to clean-up and init, and also allow GM to author /bank roster updates
- Merge PR #1 (fix-search-normalization) into integration branch
- Perform cleanup of malformed data on addon initialization and handle malformed data better
- Fix nil version comparison in ReceiveAltData
  - Added nil check for existing alt data version before comparison
  - Prevents 'attempt to compare number with nil' error
  - Fixes crash when receiving data for alts without version field
- Fix Search.lua crash and implement name normalization with security improvements
  - Fixed nil table index crash in Search.lua duplicate detection
  - Added NormalizePlayerName helper for consistent 'Name-Realm' format
  - Implemented sender authentication to prevent communication spoofing
  - Added debug tools: /bank debug toggle and /bank debugdump command
  - Auto-enable bank reporting for detected bank characters
  - Relaxed delegation policy for multi-bank account support
  - Normalized player keys across all modules for data consistency
