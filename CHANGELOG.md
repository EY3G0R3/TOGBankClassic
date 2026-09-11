# TOGBankClassic Changelog

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

> Releases **v1.4.0 and older** have been moved to
> [`CHANGELOG_ARCHIVE.md`](CHANGELOG_ARCHIVE.md) to keep this file under GitHub's 125,000-character
> release-body limit. Nothing was deleted; each section moved whole, at a version boundary.
