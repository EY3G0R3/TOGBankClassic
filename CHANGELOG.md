# TOGBankClassic Changelog

## [v1.9.1] (2026-10-17) - Safer Order Sync

### Bug Fixes

- **MUT-ID-001: a received order change could overwrite a different order.** Peer Review eee82c0f,
  Q1. `Guild:ApplyRequestMutation` (`Modules/RequestLog.lua`) keys the merge by `entry.requestId`
  and looks up `requests[requestId]` for its permission checks, but `mergeRequest` stores the
  snapshot as it arrived, so a mutation whose `request.id` differed from its `requestId` put one
  order's record under another's key. An "add" passes when the snapshot's requester is the sender,
  so a peer could replace any order with a newer snapshot of its own. Every sender in this addon
  sets both ids from one value, so only a mismatched or hostile peer reaches it. A mutation whose
  two ids differ is now refused. `Tests/requestlogcoverage_spec.lua`, confirmed red with the check
  switched off. Not wire-visible: nothing this addon sends changes.
- **ADD-OWNER-001: an "add" could take over or close someone else's existing order.** Peer Review
  e5b7e0c8, R1, the other half of MUT-ID-001. The add check only compared the snapshot's requester
  with the sender, never the order already held under that id, so a peer naming itself requester
  could send a newer snapshot of another player's order and `mergeRequest` replaced it: the order
  changed hands, or arrived `cancelled` or `complete` without the cancel and complete permission
  checks, which run only for those mutation types. An add for an order already held is now refused
  unless the sender is that order's requester; the requester's own add arriving twice still merges.
  The only sender of an add, `Guild:AddRequest`, mints a fresh id, so a modified client is needed to
  reach it. `Tests/requestlogcoverage_spec.lua`: a takeover and a cancelling add are refused (red
  with the check switched off), and the requester's repeated add still merges.
- **ADD-OPEN-001: a requester could close or fill their own order by re-sending it as an "add".**
  Peer Review 70aaa39f, S1, the last piece of the same class. With ADD-OWNER-001 the requester is the
  one sender an add for a held order still accepts, and the add branch never looked at the
  snapshot's status or Sent count, so an add carrying `complete`, `fulfilled`, or a Sent count
  closed the order past the banker-only complete check. An add is a new order: `Guild:AddRequest`
  sends it `open` with nothing Sent, and the payload is serialized when it is sent, so a later
  change to the order never rides on it. An add with any other status, or a Sent count above zero,
  is now refused. `Tests/requestlogcoverage_spec.lua`, red with the check switched off.
- **REQ-GATE-002 / BYID-ASKED-001 / SYNC-OWNER-001: the full-record request sync bypassed all three
  fixes above.** Peer Review 385b8033, T1. MUT-ID-001, ADD-OWNER-001 and ADD-OPEN-001 live in
  `Guild:ApplyRequestMutation`; the by-id record sync (`togbank-rd2`, and the older `requests-by-id`
  on `togbank-rm` / `togbank-rd`) reached `Guild:ApplyRequestSnapshot` with no sender, no roster check
  and no check that the id was ever asked for, and `mergeRequest` replaces a held record wholesale
  when the incoming one is newer. So one whispered record from anyone, guildmate or not, could change
  an order's requester, status, quantity or Sent count, and one tombstone could delete it. Three
  checks now stand on that path:
  - **REQ-GATE-002** (`Modules/Chat.lua`, `IsRequestSyncPeer`): every by-id answer and every request
    index (`togbank-ri`, and `requests-index` on `togbank-rm` / `togbank-rd`, whose tombstones also
    delete orders) is dropped unless the sender passes `IsInCurrentGuildRoster` -- the same peers
    REQ-GATE-001 already required for the queries.
  - **BYID-ASKED-001** (`Modules/RequestLog.lua`): `Guild:QueryRequestsById` records each id it asks
    for and of whom (`requestedById`); `Guild:TakeRequestedById` accepts an answer only for an asked
    id, from that player (any guildmate for a query sent to the guild), within
    `REQUESTS_SYNC.REQUESTS_BY_ID_ANSWER_WINDOW` (300 s, `Modules/Constants.lua`, chosen, not
    measured), and once. An unasked answer no longer ends an index sync waiting on by-id records.
    An id asked of two players (an index sync and a SYNC-013 fulfill fetch can both ask for one)
    keeps both askees, each with its own ask time, and takes whichever answers first; a re-ask of
    one player does not extend another's window. Asks whose windows have all closed are swept on
    each new ask, so unanswered ones do not pile up for the session.
  - **BYID-WINDOW-001** (Peer Review 35aa4d69, P1): the window counts from the later of the ask and
    that player's last asked answer. A big sync's answers queue behind the responder's
    ChatThrottleLib and can land well after the ask; a responder still sending answers is slow, not
    gone, so its queued answers are no longer dropped. Not measured how late they run in a client.
  - **BYID-EMPTY-001** (Peer Review 35aa4d69, P2): an empty legacy `requests-by-id` table answers
    nothing, so it no longer ends an index sync. No shipped client sends a table by-id; a sync left
    waiting is still freed by `INDEX_INFLIGHT_TIMEOUT`.
  - **BYID-MALFORMED-001** (Peer Review 3a1998fa, P5): a `requests-by-id` payload that is not a table,
    or whose `requests` is not a table, answers nothing either, so it no longer ends an index sync
    (`Guild:ReceiveRequestsById`, `Modules/RequestLog.lua`). Each branch went red on its own first.
  - **BYID-SYNC-END-001** (Peer Review eeb82a62, F2 and F4): the FIRST asked by-id record ended the
    whole index sync while the rest were still being asked. A sync the player started printed
    "Requests synced." after one record, and with `inFlight` cleared only the 60 s query cooldown
    stood between the drain (5 s per 50 ids) and a second index sync; one to a different peer emptied
    the first peer's unsent batches. The sync now records the ids it asked for
    (`requestsIndexSync.pendingById`, filled by `Guild:EnqueueByIdBatches`) and
    `Guild:EndRequestsIndexSyncIfAnswered` ends it only once no batch is left to send and every one of
    them has been answered, from either receive path. A guild-wide query's 10 s "nobody answered"
    clear no longer ends a sync an index answer set fetching. With the sync now in flight for the
    whole drain, `INDEX_INFLIGHT_TIMEOUT` (180 s) would have cut off any drain past 36 batches, so each
    batch sent and each asked answer restarts the in-flight clock (`Guild:NoteRequestsIndexAnswer`);
    the timeout now measures silence, and an id never answered still leaves the sync to it.
    `Tests/requestlogcoverage_spec.lua`: four examples, all red against the old code.
  - **BYID-SYNC-END-001, multi-chunk** (Peer Review dc0455df, K1-K3): an index arrives in chunks of
    20 ids, one a second, and three paths still ended a sync early. A chunk with nothing missing
    called `EndRequestsIndexSync` outright while an earlier chunk's ids were still awaited (K1). The
    by-id drain cleared `byIdCurrentSender` once its queue emptied, so the same peer's next chunk
    looked like a new sender and wiped `pendingById` (K2); it is now cleared only when an index sync
    begins or ends. And the receiver could not tell the last chunk, so a chunk answered in full before
    the next arrived ended the sync between them (K3). Each `togbank-ri` chunk now ends with
    `false, <chunks still to come>`; an older client's tombstone loop stops at the `false`, so it reads
    the chunk as before, and a chunk from an older sender (no trailer) ends as it did. The new
    `Guild:SettleRequestsIndexSync` ends the sync only when every asked id is answered and no sender
    has said more is coming, checked again on each chunk and each answer -- no timer. The guild-wide
    10 s "nobody answered" clear also waits while chunks are still coming.
    `Tests/requestlogcoverage_spec.lua`: K1, K2 and K3 examples, red against the code before this
    change in their first form, before the chunks carried the trailer (desk run 20261016-172013.129);
    the index-sending example now pins the trailer.
    `docs/REQUEST_COMMS.md` no longer gives `INDEX_INFLIGHT_TIMEOUT` as 30 s.
  - **BYID-SYNC-END-001, other peers and the timeout** (Peer Review 5b13bb3a and e3fd248b; K4, K5, M1,
    G1): every client hears every guild-wide index, so another peer's chunk during a whispered sync
    switched the by-id sender and wiped `pendingById`, and the sync settled on that peer's answers (K4).
    A sender change now stops awaiting only the ids of the batches it drops unsent. That switch also
    left the new peer's batches unsent while the old peer's batch timer was pending, because the stale
    timer cleared `byIdDraining` and bailed; only the current drain clears it now, and a sender change
    starts its own. Index chunks did not restart the in-flight clock, so a long index could time out
    mid-way (K5); each chunk now does. The in-flight timeout cleared the sync by hand but not `notify`
    or `byIdCurrentSender`, so a later automatic sync printed "Requests synced." for the player's sync
    that never finished (M1); one `resetIndexSyncProgress` now serves Begin, End and the timeout, the
    timeout says "Request sync timed out." to a player who started the sync, and End clears `notify`
    even when muted. A chunk count that drops by more than one is a lost chunk (an AceCommQueue
    refusal, ACQ-004), and the sync now re-asks the peer it is reading for its whole index (G1). A guild
    query's 10 s check could also end a later sync, since the state table is shared; Begin now stamps a
    `generation` the check compares. `Tests/requestlogcoverage_spec.lua`: eight examples, all red with
    the fixes undone (desk run 20261016-174649.705).
  - **BYID-SYNC-END-001, interleaved peers** (Peer Review 79dfbfd2, P1 and P2): K4 made the hold right
    but not the fetch. Two peers' indexes arriving in one sync still emptied each other's unsent by-id
    batches at every sender change, and those ids were never asked in that sync. `EnqueueByIdBatches`
    no longer resets the queue: each batch already carries its sender, so every peer's batches share
    the queue and `batchTotal`/`batchSent` are running totals per drain run; `byIdCurrentSender` is
    gone. A by-id ask refused because that peer is offline used to abort the whole queue; it now drops
    only that peer's batches and the ids they would have answered, keeps asking the others, and the
    player's sync ends with "Request sync incomplete: a bank went offline before answering." instead of
    "Requests synced.". A re-ask (CRC or G1) to a peer who logged off printed "Requests synced." too;
    `EndRequestsIndexSync` takes a failure line and `QueryRequestsIndex` passes "Request sync failed:
    NAME is offline.". `Tests/requestlogcoverage_spec.lua`: the K4 "drops unsent" example is replaced
    by the interleaved-peers one, plus an offline-peer and a failed re-ask example; all three red with
    the old behaviour put back (desk run 20261016-181608.468). `docs/REQUEST_COMMS.md` has a
    BYID-SYNC-END-001 section.
  - **BYID-SYNC-END-001, a peer's sent batches** (Peer Review f3453dc9, N1 and N2): the offline branch
    released the refused batch's ids and that peer's queued ones, but not those of a batch already sent
    before it logged off, so the sync waited on them until `INDEX_INFLIGHT_TIMEOUT` and printed "Request
    sync timed out." instead of the incomplete line (N2). `pendingById` now maps each id to the peer it
    was asked of, and a refusal releases every id awaited of that peer; an id a later peer's index also
    listed stays awaited of that later peer. `byIdQueueGen` had no writer left after P1, so the guard
    it fed could never fire; it is deleted, and nothing cancels the by-id drain: a sync begun mid-drain
    still sends the queued batches (N1). `Tests/requestlogcoverage_spec.lua`: an N2 example, red with
    the old release put back (desk run 20261016-184424.699), and an N1 example pinning the drain.
  - **BYID-SYNC-END-001, a re-ask inside a guild-wide sync** (Peer Review 5063214b, P3): a CRC or G1
    re-ask of one peer went through `BeginRequestsIndexSync`'s full reset, which emptied `pendingById`,
    so in a guild-wide sync the ids another peer still owed stopped holding it and "Requests synced."
    printed before their records arrived. A forced ask of one peer while a sync is in flight is now a
    re-ask: it restarts only that peer's `chunksToCome`, keeps every awaited id, and leaves a guild-wide
    sync guild-wide (`inFlight` stays `*`). A refused re-ask in a guild-wide sync releases only that
    peer's ids and ends as incomplete once the others answer; a refused re-ask of the sync's only peer
    still prints "Request sync failed: NAME is offline.". `Tests/requestlogcoverage_spec.lua`: two P3
    examples, both red with the old reset put back (desk run 20261016-192300.784). The "10 s check"
    example again ends the guild query before beginning a new sync and expects that sync's peer; the
    re-ask that stays guild-wide past the check is its own P3 example.
  - **BYID-SYNC-END-001, a re-ask of another peer during a targeted sync** (Peer Review b0f108ef, F1):
    a CRC re-ask is not gated on the sync's peer, so one corrupt chunk of another peer's guild broadcast
    moved `inFlight` from the targeted peer to that one. The targeted peer's lost chunks were then no
    longer re-asked (G1 matched only the new peer), and a refused re-ask ended the sync "failed" with the
    targeted peer's ids still owed. A re-ask of a peer other than the one the sync reads now widens the
    sync to guild-wide (`*`). `Tests/requestlogcoverage_spec.lua`: an F1 example, red with the old line
    put back (desk run 20261016-195139.056). A2 (Peer Review 20851b90): an example pins the widened case
    end to end -- a refused re-ask of the FIRST peer after the widening drops only that peer, prints no
    "Request sync failed", and the sync still waits on the widened peer's id.
  - **BYID-SYNC-END-001, another peer's broadcast held a targeted sync open** (Peer Review 20851b90,
    N1; `Guild:ReceiveRequestsIndex`): the "chunks still to come" count was recorded for ANY sender
    while a sync was in flight, while the G1 re-ask beside it was already limited to the sync's own
    peer. A targeted sync that overheard another peer's guild broadcast whose last chunk never arrived
    waited on it until the in-flight timeout, then printed "Request sync timed out." instead of
    "Requests synced.". The count (and the in-flight clock it restarts) is now taken only from the
    peer the sync reads, or from anyone in a guild-wide sync. `Tests/requestlogcoverage_spec.lua`: an
    N1 example, red with the old gate put back (desk run 20261016-205138.391).
  - **SYNC-OWNER-001** (`Guild:ApplyRequestSnapshot`): a synced record naming a different requester
    for an order already held is refused. No client ever changes an order's requester.
  - The `togbank-ri` corrupt-chunk branch (`Modules/Chat.lua`) re-asked the sender for its index with
    the cooldown bypassed for anyone; it now does so only for a peer passing the same gate, so a
    stranger's garbage cannot buy a whisper back on every send.
  WHAT THIS DOES NOT DO (Peer Review 82a7a7af, T2): request sync still TRUSTS GUILDMATES. A snapshot
  carries no author, so the mutation path's role checks cannot be mirrored. A guildmate can still
  list an order in its index with a newer time and answer the fetch it provokes with a changed
  status or Sent count, or send an index tombstone that deletes it. These fixes stop outsiders,
  unasked answers and requester takeovers -- not a hostile guildmate running a modified client.
  `Tests/requestlogcoverage_spec.lua`: a non-guildmate's record, tombstone and index on every branch;
  a stranger's corrupt index chunk; unasked and wrong-player answers on both the record and the
  legacy table path; a table carrying an asked and an unasked id; a repeat and a late answer; two
  askees; a sweep; a slow responder; an empty table; a requester change. Each check was switched
  off on its own and its examples went red; a guild query answered by any guildmate stays green.
  KNOWN COST: a client used to
  merge by-id records broadcast to the guild for another member's query; it now drops them and
  fetches what it is missing itself on its own next index sync. Older clients still answer this
  client's queries unchanged, since nothing on the send side moved.
- **SUITE-SPEED-002 (in game half)** (`Modules/UI/Requests.lua`, `labelHitFor`): the invisible
  hover frames over the Requests tab's "Requester" and "Bank" filter labels were created again on
  every build of the body, on AceGUI's POOLED dropdowns, and never removed. The body is rebuilt on
  every visit to the Guild Bank window's Requests tab, so each visit stacked two more mouse-enabled
  frames on those dropdowns, and a pooled dropdown later used by any other window kept a "Filter by
  ..." tooltip over its label. Now there is one per dropdown frame, found again on the next build,
  and it is hidden when the dropdown is released. Peer Review 7f4d4fdb, S2: the first version gave
  the hit frame its own `OnRelease`, which `scaleStock` replaced at any UI scale other than 1 (AceGUI
  keeps one `OnRelease`), so the fix only held at 1x. The hide now lives in the body's one release
  handler, `restoreWidgetOnRelease`, and `labelHitFor` registers it through `markForRestore`.
  `Tests/requestsactions_spec.lua`: a 2x example, red with the old callback put back. Peer Review
  584efe3b, P1: both filters also moved the pooled dropdown's label 3 px right, and AceGUI sets that
  anchor only in its constructor, so the next window to take the dropdown inherited the shift.
  `restoreWidgetOnRelease` now puts the label back on AceGUI's own TOPLEFT/TOPRIGHT 0,0; the same
  example asserts it, red without the reset. Not checked in a client.
- **SUITE-SPEED-002, two more things a released window left on AceGUI's pooled Frame**
  (`Modules/UI.lua`), both found by the frame-growth guard's registry walk (Peer Review 7f4d4fdb,
  S1): `KeepAboveResizeSizers` stored our bottom-row buttons on the Frame and its once-per-frame
  OnShow hook kept lifting them for whichever window took that Frame next; and `AnchorStatusBar`
  ended the status bar at one of our icons, so the next acquirer's bar kept that anchor. The list
  is now cleared through `OnWindowRelease`, and `undressWindow` puts the bar back on AceGUI's own
  anchors (15/15 and -132/15). Both find the status background through a new local,
  `statusBackground`: they used `statustext:GetParent()`, which while the left text breathes is the
  cached left host, so the re-anchor (and `AnchorStatusBar` itself, since it was written) could move
  the left host instead of the background, depending on which release hook ran first.
  `Tests/windowchrome_spec.lua` (POOL-CHROME-001) asserts the button list, the bar's anchors and the
  left host's anchors; it was red with the list clear off, with the re-anchor off, and with the old
  `GetParent()` lookup. Not checked in a client.
- **COMBAT-KEY-001: pressing keys in combat with the Requests window (or the Guild Bank window's
  Requests tab) open raised `ADDON_ACTION_BLOCKED` for `Frame:SetPropagateKeyboardInput()`.**
  Player BugSack report, 7x, `Modules/UI/Requests.lua:1184`. The window's key handler, added so
  Escape closes an open filter dropdown before the window, called `SetPropagateKeyboardInput` on
  every key press; the function is restricted (`HasRestrictions` in the Classic Era
  `SimpleFrameAPIDocumentation.lua`) and blocked for addon code in combat. It is now called only when
  the value changes and never in combat (`setPropagate`), the consumed Escape's key release puts the
  frame back to propagating, and a body built in combat leaves the hook for the next build out of
  combat. In combat an open dropdown still closes on Escape, but the key also reaches the game.
  The window's release now takes the key scripts and marker off the frame (`unhookChromeFrame`
  through `UI:OnWindowRelease`), because AceGUI pools Frames across every addon and the next window
  on that frame inherited our handler, as POOL-CHROME-001 found for the icons. The Inventory and
  Donations windows (`Modules/UI/Inventory.lua`, `Modules/UI/Donations.lua`) lost their keyboard
  hooks: each routed key presses to `UI:EventHandler`, which acts only on clicks and drags, so it did
  nothing, while `EnableKeyboard` (`IsProtectedFunction` in the same documentation) and the setter
  could be blocked the same way when the window was first built in combat.
  `InCombatLockdown` added to `.luacheckrc` and `.luarc.json`. `Tests/requestsactions_spec.lua`
  asserts no setter call for an unchanged key, the key-up restore, no call in combat, no hook built
  in combat, and the release clearing the scripts. Not checked in a client.
- **COMBAT-KEY-002: a Requests window could be left blocking every keybinding.** Peer Review
  a21c6a53, P1, on the COMBAT-KEY-001 self-audit. A keyboard-enabled frame that does not propagate
  stops all keybindings while it is shown (warcraft.wiki.gg, `API_Frame_SetPropagateKeyboardInput`).
  If combat began between an Escape that closed a dropdown and that key's release, COMBAT-KEY-001's
  combat guard refused the restore and the player lost every keybound ability for the rest of the
  fight; if the window was then released in combat, AceGUI pooled the frame that way for any addon's
  next window, even out of combat. A restore combat refuses is now queued (`pendingRestore` in
  `Modules/UI/Requests.lua`) and run on `PLAYER_REGEN_ENABLED`; a frame released in combat also gets
  its keyboard turned off then, unless our hook has taken it back. `Tests/requestsactions_spec.lua`
  drives both cases through combat and its end. Not checked in a client.

### Internal

- **Changelog archive:** the whole v1.7.0 section moved to `CHANGELOG_ARCHIVE.md`, which left this
  file 285 characters under the 120,000 ceiling before the move.
- **Release docs for v1.9.1:** `README.txt` gets the version line (it still said 1.8.0) and a 1.9.1
  Changelog Highlights block with its compatibility note.
- **SUITE-SPEED-002** (desk timing run 2026-10-16: from windowchrome_spec on, ~46,300 live frames
  and a 145 MB heap, and requestsactions_spec over the 60 s per-file limit in the forward run while
  passing alone). The forward run held three kinds of leftovers from earlier examples:
  - `Tests/env_togbank.lua` `forgetFrameCaches` only HID the Requests body's cluster buttons,
    Settings overlay and list host, so they stayed children of the pooled window frame. They are
    now detached (`SetParent(nil)`), as `releaseWindow` already did for the content's frames.
  - `Tests/requestsactions_spec.lua` never released the cancel-reason dialog. The module builds it
    once and keeps it, which is right in the client; here every example built a new one, and its
    buttons (AceGUI names them as globals) kept that example's module, window and list alive
    through their OnClick closures. `unload` now releases `R.CancelDialog`.
  - `Tests/mailbox_spec.lua`'s window block never released the Mailbox window; its `after_each`
    now closes and releases it.
  Measured on the per-file timing run: live frames from windowchrome_spec on went from ~46,300 to
  ~16,700, and the heap from ~145 MB to ~65 MB; requestsactions_spec alone went from 15 s and
  21,072 frames to 6 s and 4,354. Forward 2181 passed in one run of the default forward suite;
  reverse 569 + 852 + 760 = 2181. The wall times in the whole-run timing were taken on a busy
  machine and are not comparable run to run.
  New guard: `Tests/requestsactions_spec.lua`, "the third build-and-release holds no more live
  frames than the second", which counts live frames per parent chain and, on failure, names what
  still references a leaked frame (a walk from the Lua registry). It failed (20,160 against
  21,013) before the cancel-dialog release and passes after it. `browse_spec` still adds ~4,000
  live frames to the run (not chased further); the whole-run timing was not repeated after the
  mailbox_spec fix, so its effect there is not measured (alone, the file ends at 6,760 frames).
  Peer Review 7f4d4fdb, S1 -- why releasing a dialog the guard never opens fixed it: the walk took its
  root from any detached frame, including older examples' pins. It now takes one only from frames
  the third cycle made, and `cycle()` drops the file's own `R` (which always reaches the newest
  window). With the dialog release switched off once (a desk run of requestsactions alone), it named the dialog
  example's unreleased Confirm button (a named AceGUI global): its `pendingCancelUI` led to a list
  whose row cells' handlers each reached the NEXT example's module and list, so one pinned dialog held
  every later window, one more per example. On the way it also found the Settings overlay's named
  scroll frame and the template's child globals (`TOGBankClassicReasonsScroll*`) keeping the last
  overlay; `unload` clears them, and the two Frame leftovers above. Peer Review N1: two examples
  loaded a second window without releasing the first; both now `unload()` first. requestsactions_spec
  alone now ends at 2,652 frames. On the final tree (with P1 and `statusBackground`): forward in its
  four parts 556 + 585 + 560 + 483 = 2184; reverse 569 + 855 + 760 = 2184. A whole forward run on
  the same tree timed out two files at the 60 s limit while the machine read 100% CPU with another
  run in flight; no assertion failed.

## [v1.9.0] (2026-10-16) - My Characters

### New Features

- **ACCOUNT-MODE-001: "My characters" in the Requests window's Requester filter.** Discord, Terra
  2026-10-15: *"curious if an 'account mode' can be added so that all requests per-account are shown
  in the requests window regardless of which toon you're on."* Every character that logs in is noted
  account-wide (`accountCharacters` in `TOGBankClassicOptionDB.global`, written by
  `Events:PLAYER_LOGIN` and again whenever the Requests filters update). When the account has more
  than one, the Requester dropdown offers "(N) My characters" at the top, and it shows the requests of
  all of them. Picking it turns account mode on (`requests.accountMode`), so the list opens there on
  every character; picking any other requester turns it off. Bankers still open on their own Bank
  filter. `Modules/Options.lua` (`NoteAccountCharacter`, `GetAccountCharacters`,
  `IsAccountModeEnabled`, `SetAccountMode`), `Modules/UI/Requests.lua`, `Modules/Events.lua`; the
  Requester label tooltip and the "?" help describe it. Specs in `Tests/requestsactions_spec.lua` and
  `Tests/optionslayout_spec.lua`. A character only counts once it has logged in with this version.
  Checked in the Classic Era client by the operator, 2026-10-16.

### Bug Fixes

- **SEARCH-007: the Requests search box now matches every column.** The operator, 2026-10-15:
  *"the search requests needs to filter off the data in any column, right now it doesn't"*. SEARCH-006
  matched only Date, Requester, Bank and Item, so a quantity, a sent count or the status shown by the
  date's glyph found nothing. `#` and `Sent` are now marked `search = true` in `COLUMNS`, and
  `ColumnText` returns what each column shows: the quantity as `3x`, the date followed by its status
  word (open / fulfilled / cancelled, matching the glyph), and the banker followed by the sister-guild
  name XGUILD-LABEL-001 prints beside it. Only Actions, a row of buttons, is not searched.
  `Modules/UI/Requests.lua`; `Tests/searchbox_spec.lua` (its old assertion that the quantity was not
  searched is reversed, and it now loads the real Guild and RequestLog modules for the status and
  guild name). Checked in the Classic Era client by the operator, 2026-10-16.

- **LOCALE-SENDTRIM-001: in a guild with players on different client languages, an order mailed
  with the Fulfill buttons could go uncredited.** Peer Review 4d7fc1c4. At send time
  `Mail:OnSendMail` (`Modules/Mail.lua`) cuts each order on the mail to what is really attached, and
  it matched the attachment by name: the slot's name from `GetSendMailItem` is in the banker's
  language, the order's is in the requester's, so a German requester's order on an English banker's
  mail matched nothing and was dropped. The send slots now record their item id
  (`GetSendMailItem`'s second return), each order on the mail carries its request's `itemID`
  (`PrepareFulfillMail` and `FulfillStep`), and the cut matches by id. Random-suffix variants share
  one base id, so every order first takes the slots matching its id AND name, and only then what is
  left by id alone; otherwise, with one variant detached by hand, its order took its sibling's slot
  and the wrong order was credited (found in this fix's self-audit, specced). An order with no stored id
  (from a pre-REQ-001 client) still matches by name, which is safe because such an order was found
  in the banker's bags by that same name. `GetSendMailItem` returns the id second in every flavour's
  UI source (Classic Era, TBC, MoP, Forever; Peer Review f6aa732c). `Tests/multifill_spec.lua`, red
  with the name match.
  The same bug sat one call further on (Peer Review f6aa732c, F3/F4): `Guild:FulfillRequest`
  (`Modules/RequestLog.lua`) matched orders only by lowercased name, so a mail the banker built by
  hand, or a stack hand-added to an addon mail, credited nothing when the two clients' languages
  differed (a German banker mailing 20 Teufelsstoff left an English order for 20 Felcloth open).
  `FulfillRequest` now takes an optional item id and matches on it when the order has one, serving
  every order that matches id AND name before any that matches id alone, for the suffix reason above.
  `Mail:ApplyPendingSend` passes the slot's id from both of its loops, and the hand-added extras are
  grouped by id rather than by the banker's name for them. `Mail:DebugSendMailState` now reads the
  slots through the same `tog_readSendSlots` as the send hook (F5). Decided with it: when one mail
  covers part of several of a person's orders for one item, the OLDEST is filled first
  (`Guild.RequestOlderFirst`, moved to `Modules/Guild.lua` from Mail.lua's `tog_olderFirst`, which
  now calls it); it used to be whichever order `pairs()` reached first, so a partial mail could
  complete a newer order and leave the older one open. Because of that sort, a spill with no target
  order now skips cancelled orders (found in this round's self-audit): the old loop never skipped
  them either, but oldest first made a cancelled order left short the likeliest to take the credit
  ahead of the open order the items were for. A targeted send still credits its own order whatever
  its state, as before. FINISHED-001 (Peer Review 2073754c) widened that skip to every finished
  order: an order closed short as `complete` (a peer's `complete` mutation is applied after only a
  permission check, and the load-time normaliser keeps it) took the spill the same way. "Is this
  order finished" is now one function, `Guild.IsRequestFinished`, used by the spill, `CancelRequest`
  and `ReopenRequest`, and the three "a fill must not overwrite this status" checks read one
  `CLOSED_STATUS` table; there were seven hand-written copies, and the cancelled-only skip already
  disagreed with the rest. `Guild:CompleteRequest` had no caller outside the specs since
  COMPLETEQTY-001 moved the hand-off button to `FulfillRequestById`, so it is removed and its four
  spec uses (`requestchain_spec`, `xguild_spec`, `xguildfleet_spec`) call `FulfillRequestById`.
  `Tests/localefill_spec.lua`, each example red
  first (no id match and no sort: the manual mail, the extra and the oldest-first examples; the exact
  pass ignoring the name: the suffix example; the cancelled filter off: the cancelled example; the
  cancelled-only skip: the short-`complete` example). The oldest-first example keys its two orders
  under ids `pairs()` walks newer first and asserts that walk as a precondition, so a change in
  Lua's hash order fails it rather than letting it pass unsorted.
  One residual, LOW: in a MIXED-language guild, two suffix variants on one mail (for example "of the
  Bear" and "of the Monkey" bracers, which share a base id) can still be credited to each other's
  orders, because the id-and-name pass needs equal names and the id-alone pass takes them in order.
  `GetSendMailItemLink` carries the suffix and is the named remedy; not done. Not checked in a game
  client: a mixed-language guild was not available, and the operator closed it without one
  (2026-10-16, *"mark the language stuff as done, i'm not going to test it"*).
- **COLLECT-LAG-001: Fulfill Oldest could pull one stack too many from the mail.** Peer Review
  bf89d59d. Taking an item out of the mail is not instant: the inbox drops it before the bags show
  it. In that moment the order being collected for reads short, and Fulfill Oldest serves another
  order. The count of what had already been pulled was one shared `collectState`, replaced then; when
  the first order came back it was recomputed from the bag count, which did not yet include the
  stack on its way, and that stack was pulled again. `FulfillStep` (`Modules/Mail.lua`) now keeps the
  count per order (`collectStates[req.id]`), drops an order's entry once its bags cover it, and drops
  them all when the mailbox closes. One consequence kept on purpose: if the banker moves a pulled
  stack away before the order is sent, that order says it is waiting until the mailbox is closed and
  reopened, as the single shared count already did for the order in front. `Tests/bankcollect_spec.lua`,
  red without the fix (three stacks pulled for an order that needed two).
- **MAIL-SLOTCAP-001: an order needing more than twelve stacks was mailed short and credited in
  full.** Peer Review bf89d59d, finding B1. `CalculateFulfillmentPlan` never looks at the mail's
  twelve attachment slots, and `Mail:FindOldestServiceableOrder` (`Modules/Mail.lua`) accepted the
  plan whatever its size; ATTACH stopped at slot 12, and SEND credited the full quantity. An order
  for 13 Linen held as 13 single stacks went out with 12 and was marked filled for 13. Now a plan
  that does not fit is cut to its twelve largest whole stacks (`tog_capPlanToMail`), the mail is
  credited what those stacks hold, and the order stays open and oldest so the next click mails the
  rest. ATTACH also returns what it actually attached and SEND credits no more than that. The
  mailbox message says the mail is part of the order ("Order: 12 of 13x Linen Cloth for Alice ...
  (one mail holds 12 stacks; the rest goes next)"; the capped plan carries `cappedFrom`; self-audit
  9da6eefd F2). `Tests/multifill_spec.lua` drives the two-mail case end to end, through the real
  send hook `Mail:OnSendMail` before each send (F1). Covered by the operator's in-game confirmation
  of the mail section, 2026-10-16; the debug log captured shows no capped send (not checked per
  item). The twelve-slot
  cap is now one helper, `tog_mailCap`, at all nine sites that spelled it out, and the capped plan's
  never-shown `reason` text is gone (Peer Review 024ada6d F2).
- **SEND-SNAPSHOT-001: an addon send could credit nothing if the client empties the attachment slots
  inside `SendMail`.** Peer Review 024ada6d F1. The send hook is a `hooksecurefunc` post-hook and read
  what went from `GetSendMailItem`; when the client empties those slots is not in its UI source
  (`MAIL_SEND_SUCCESS` only resets the name, subject and body boxes). The slots are now also recorded
  on `MAIL_SEND_INFO_UPDATE` (`Mail:OnSendInfoUpdate`, wired in `Modules/Events.lua`), and
  `Mail:SendAttachments` uses that record when the hook finds the slots empty -- but only when they
  went empty in the same frame as the send (`GetTime()` is frozen within a frame), so stacks the
  banker took off the mail earlier are never credited. The record is consumed by each send and
  dropped on `MAIL_CLOSED`. A MAIL debug line in the hook says how many slots it saw and whether it
  used the record. `Tests/multifill_spec.lua` sends the capped mail through the real hook with the
  slots emptied before the hook and still full in it (both credit 12), and a hand-detached mail
  (credits nothing); each guard was switched off once and went red. Those examples fire
  `MAIL_SEND_INFO_UPDATE` and `MAIL_CLOSED` through the real `Events:RegisterEvents` registration, so
  dropping either wiring line fails them (Peer Review 1aa094de F2). Measured in the Classic Era
  client by the operator, 2026-10-16, over three Fulfill sends in a row: the hook found 1, 2 and 3
  slots still attached, the recorded update agreed each time, every order was credited, and no
  "Mail sent." reached the mail-error path. So on Classic Era the slots are still full inside the
  post-hook, and the record is a fallback for a case not seen in game (Peer Review c46172df). The
  test harness pin moved to WoWAPITesting `be92d12` (inbox
  da34acf1): its `SendMail` now keeps the slots until `wow.completeMailSend()`, the stand-in for the
  server's confirmation, so `Tests/multifill_spec.lua` confirms each batch send through a
  `confirmSend` helper instead of relying on the send click to empty them. The "slots still full"
  example now uses the harness's own `SendMail`; the "already empty" one installs its own. The
  manual `MAIL_SEND_INFO_UPDATE` fires stay, because that describe registers the addon's handlers
  into a captured table the harness's event never reaches. The pin then moved on to `9f4d90a`
  (`f6e5fde`: a second `SendMail` before the first is answered now raises, and `SetPoint` binds a
  frame name at call time). The four `Tests/multifill_spec.lua` examples the harness named as at
  risk already pass, because `confirmSend` answers every send; the whole suite stayed green with no
  spec change.
- **SUFFIX-KEY-001: an order with no random suffix and an "of the Bear" order of the same item did
  not hold each other's place in the queue.** Peer Review bf89d59d. An order with no suffix counts
  every variant of its item in the bags, but it was keyed apart from the Bear order, so first come,
  first served did not apply between them: a newer Bear order could take the stack an older
  any-variant order was waiting on, and the other way round. Such orders still exist (stored before
  INV2-SUFFIX-001, from an older client, or placed by another addon through `Guild:AddRequest`; the
  addon's own request dialog always carries the suffix). `Modules/Mail.lua` now measures each order
  against a pool of its competitors (`tog_newPool`/`tog_poolAdd`/`tog_poolFor`): two orders compete
  when they share a key, or share an item id and either has no suffix. The mailbox hold, the
  ride-along reservation and the bank shortfall all use it; Bear and Tiger orders still never hold
  each other up. At the bank the error is toward pulling a stack too many for a suffixed order, never
  toward leaving one short. `Tests/bankcollect_spec.lua`, red without the fix. `Tests/multifill_spec.lua`
  now loads `Modules/Inventory/Record.lua`, which it needed and had only been inheriting from an
  earlier spec file.
- **NAME-POOL-001: an order with no item id and an order with one did not hold each other's place.**
  Peer Review 1aa094de F1, the same class as SUFFIX-KEY-001. An order with no item id (stored before
  REQ-001, or from an old client) counts its item in the bags by name, so it takes every item of that
  name, but it was pooled only with other no-id orders. The pool now also sums by lowercased name
  (`tog_nameKey`): a no-id order competes with every order of its name, and every id order with the
  no-id orders of its name. Where two items share a name it over-holds; where the stored names match
  it never under-holds (two orders placed from clients in different languages store different names
  and still do not hold each other, deferred with the other locale work). At the bank the over-hold
  is toward pulling a stack too many for an id order, never toward leaving one short. An order with
  no usable name pools by name with nothing: the key used to be `tostring(item)`, so every nameless
  order shared the key `"nil"` and a nameless no-id order held every nameless order behind it (Peer
  Review 104ff6f7 N1). How many no-id orders still exist is not known, so the path is kept rather
  than deleted. `Tests/bankcollect_spec.lua`, three of the first four new examples red without the
  fix (the fourth, a different name, passes either way by design), plus one for the nameless case.
  `Tests/multifill_spec.lua`'s event-wiring examples now put back the `TOGBankClassic_Core` methods
  and the addon globals they set, and assert it (Peer Review 104ff6f7 F3).
- **FCFS-SELF-001: one requester's newer order could ride along on stock their own older order
  needed.** Peer Review bf89d59d. `Mail:FindMoreOrdersFor` reserved stock only for other people's
  orders; an order of the same requester that could not ride now reserves its quantity too.
  `Tests/bankcollect_spec.lua`.
- **The mailbox now says which order is holding the queue.** When Fulfill Oldest has nothing it can
  send because the oldest order for an item cannot be covered yet, the message names that order's
  requester, quantity and item instead of a bare "no orders" (Peer Review bf89d59d, B2).
- **MAIL-ADDPARTIAL-001: adding an order to a mail that ran out of slots said "Click Send to
  complete".** Found by COVERAGE-MAIL-001. When a banker added a second order to a mail already open
  for the same person, `Mail:PrepareFulfillMail` (`Modules/Mail.lua`) replaced its message with the
  "N orders on this mail. Click Send to complete." line whatever was attached, so an order of 20 with
  only 10 slots' worth attached read as done. It now says "Attached 10 of 20 ... (partial) -- N
  orders on this mail. Click Send, then fulfill again." when the order is short. The credit was
  always right (the pending send carries what was really attached); only the message was wrong.
  `Tests/mailcoverage_spec.lua`. That example was not confirmed red on the old code.
- **EVENTS-UIERR-001: a failed mail send left Fulfill answering "waiting for the last order" for up
  to five seconds.** Found by COVERAGE-EVENTS-001. `TOGBankClassic_Events:UI_ERROR_MESSAGE`
  (`Modules/Events.lua`) took `(_, message)`, but the event's payload is `(errorType, message)` on
  every flavour this addon ships (`Blizzard_APIDocumentationGenerated/SystemDocumentation.lua`,
  `UiErrorMessage`, read in the classic_era, classic_anniversary, classic and forever trees). So
  `message` was the numeric error type, no mail error ever matched, and `Mail.batchInFlight` was only
  cleared by the 5 s safety timer `Mail` starts with each batch send (`Modules/Mail.lua`, after
  `SendMail` in the batch path). An earlier draft of this entry said "until a reload"; that was
  wrong. It now takes `(_, _, message)`. `Tests/eventscoverage_spec.lua` fires
  the event with both values; that example was not run against the old code, the failure there is by
  reading.
  Follow-up, EVENTS-UIERR-002 (Peer Review 511e37b8, L1): the message is the client's own localized
  text, and the test was `message:lower():find("mail")`, so a mail failure on a non-English client
  still left the batch blocked. A file-local `isMailError` in `Modules/Events.lua` now decides by the
  error's id: `GetGameMessageInfo(errorType)` returns the error's string name
  (`Blizzard_APIDocumentationGenerated/GameErrorDocumentation.lua`; Blizzard's own
  `UIErrorsFrame.lua` calls it with the same index), and a name starting `ERR_MAIL_` is a mail
  error, in any language. The English word is only the fallback when the function is absent or knows
  no name for the index (it is documented `MayReturnNothing`). Peer Review 6639c74e (R1) proposed
  this; the first draft of the fix matched the text against every `ERR_MAIL_*` string in `_G`
  instead, which walked all of `_G` on the first UI error of a session (combat included) and could
  never match a template string. The handler now names its second parameter `errorType`. Which
  error names exist and which indexes map to them is not verified (GlobalStrings are not in the
  local source trees); `GetGameMessageInfo` is documented in the classic_era tree read here and, per
  Peer Review, in classic, classic_anniversary and forever. `Tests/eventscoverage_spec.lua` stubs
  it: index 3 names `ERR_OUT_OF_RANGE` with a text that says "mail" and leaves the batch alone,
  index 51 names `ERR_MAIL_DATABASE_ERROR` with a German text and frees it, and an unknown index
  falls back to the English word. Not run against the old code. `GetGameMessageInfo` is added to
  `.luarc.json` and `.luacheckrc` (read-only for the addon, writable for the Tests).
  Follow-up, EVENTS-UIERR-004 (Peer Review 030b8a0a, F2): any mail error cleared the batch flag,
  including one from an inbox action. The flag is set only by a batch send and cleared on its
  confirmation or by its 5 s safety timer, so the exposure was an inbox error landing while a send
  was unconfirmed: it freed the next click early. `UI_ERROR_MESSAGE` now leaves the flag set for the
  two `ERR_MAIL_*` names that can only come from the inbox, by their enUS text in the classic_era
  GlobalStrings (Ketho/BlizzardInterfaceResources, `Resources/GlobalStrings/enUS.lua`, read on the
  web because GlobalStrings are not in the local trees): `ERR_MAIL_ATTACHMENT_EXPIRED` ("That item
  has expired.") and `ERR_MAIL_DELETE_ITEM_ERROR` ("You can't delete that."). The text of
  `ERR_MAIL_DATABASE_ERROR` names no side, so it may come from either and still frees the batch: a
  wrong free costs one early click, a wrong block costs the 5 s timer on every failed send. Inbox
  errors without the `ERR_MAIL_` prefix (a full bag) were already ignored. Only the flag skips the
  two: they still write the MAIL debug line and put "Mail error: ..." in an open Requests window's
  status bar, so a failed take is still reported (Peer Review ca15a538, U1; the first cut skipped
  that whole branch).
  The English-text fallback cannot tell the sides apart and is unchanged. A gate on
  `Mail.pendingSend` was built and then removed (Peer Review 7562cf08, G1): whenever the flag is set,
  `pendingSend` is set too, so the gate never changed an outcome. `MAIL_FAILED` was not used: Blizzard's
  own Open All listens for it during inbox takes too (`Blizzard_UIPanels_Game/Classic/MailFrame.lua`),
  so it has the same breadth. `Tests/eventscoverage_spec.lua` fires both inbox-only ids with a batch
  pending and the flag stays set; confirmed red with the exclusion removed. Which index each name has
  in a client, and whether those two are ever raised during a send, is not verified in a client.
- **BATCH-TIMER-001: an earlier send's safety timer could free Fulfill Oldest while a later send was
  unconfirmed.** Peer Review 030b8a0a (N1). Every batch send in `Mail:FulfillStep`
  (`Modules/Mail.lua`) starts a 5 s timer that cleared `batchInFlight` unconditionally. Send A
  confirms, send B starts two seconds later, A's timer fires and frees a third click before B
  confirms. Each send now stamps `Mail.sendGen`, and its timer clears the flag only if no later send
  has stamped it since. How often a confirmation takes long enough for this to matter in a client is
  not measured. `Tests/multifill_spec.lua` drives two sends two seconds apart on the harness clock;
  confirmed red with the unguarded timer put back.

- **SEND-RECIPIENT-001: a mail to one person could credit another person's order.** Peer Review
  f4c6a142 (R1). `Mail:OnSendMail` (`Modules/Mail.lua`) kept any pending send under 10 s old without
  checking who the mail was going to. Two ways in: a Fulfill Oldest send that failed leaves its pending
  send behind (nothing clears it on failure), and after a row's Fulfill the banker can retype the name
  box. Either way, a mail to Bob carrying the same item credited Alice's orders, and any extra stacks
  spilled to Alice's other orders. The pending send is now kept only when the mail goes to the same
  person, compared without case because the client sends to a name typed in any case; otherwise the
  mail is tracked as a hand-built mail to its real recipient. `NormalizePlayerName` does not fold case,
  and Lua's `lower` folds only ASCII, so a name whose accented capital is typed in lower case falls to
  the hand-built path: the order loses its id targeting but nobody is wrongly credited.
  `Tests/multifill_spec.lua`: a row Fulfill for Alice mailed to Bob credits Alice nothing, and the same
  name typed in lower case still credits the prepared order. The first was confirmed red without the
  check. Covered by the operator's in-game confirmation of the mail section, 2026-10-16; the debug
  log captured shows no redirected send (not checked per item).

### Internal

- **COVERAGE-MAIL-001: `Modules/Mail.lua` and `Modules/RequestLog.lua` at 100% line coverage.**
  Peer Review 074cdad6 and 5bd709cf. Mail.lua went from 86.90% to 1138/1138 lines and RequestLog.lua
  from about 79% to 1560/1560, measured with the harness's `coverage.lua` over the whole forward run
  (2094 passing). New `Tests/mailcoverage_spec.lua` and `Tests/requestlogcoverage_spec.lua`, 85
  examples between them. Three blocks that could not run were deleted rather than covered, each
  checked against its callers: `mergeRequest`'s nil-id/nil-record guard (both callers,
  `ApplyRequestSnapshot` and `ApplyRequestMutation`, refuse those first); the per-sender cooldown in
  `CanQueryRequestsIndex` and its `perSender` map (written in the same step as `lastQueryAt`, the only
  writer of either, so it could never refuse when the global cooldown had passed); and the "single
  large stack" branch at the end of Mail.lua's fulfillment plan (for a positive need PHASE 3 already
  splits from the largest stack, and a need of 0 returns at PHASE 1; only a negative need reached it,
  and it planned a negative split, which now fails closed). No production caller can pass a negative
  need: all four take it from `RequestQuantityNeeded`, which never returns below 0.

- **COVERAGE-EVENTS-001: `Modules/Events.lua` at 100% line coverage.** Peer Review 074cdad6. It went
  from 56.28% to 100%, measured with the harness's `coverage.lua` over the whole forward run: 420/420
  lines, with Mail.lua at 1144/1144 after BATCH-TIMER-001 and SEND-RECIPIENT-001 (2137 passing;
  reverse parts 569 + 809 + 759 = 2137). After EVENTS-UIERR-004 the gate is 2138 forward and
  569 + 809 + 760 = 2138 reverse, with Events.lua at 423/423. New `Tests/eventscoverage_spec.lua`. It found
  EVENTS-UIERR-001 above.

- **Changelog archive:** the whole v1.6.1 section moved to `CHANGELOG_ARCHIVE.md` (Peer Review
  e1e13df8). This file was 115,152 characters, 4,848 under the 120,000 ceiling.

- **FORWARD-PARTS-001: the fallback forward parts find new spec files by themselves.** Peer Review
  e1e13df8. The four forward parts (A8a, A6c, B3a, B3b) were writ suites listing their spec files by
  hand, and `mailcoverage_spec`, `requestlogcoverage_spec` and `localefill_spec` were in none of
  them, so a forward run split into parts skipped them. New `Tests/run_forward.lua <part> <parts>`
  slices the sorted spec glob the way `Tests/run_reverse.lua` always has; both now share the
  discovery and slicing in new `Tests/run_parts.lua`. Declared as writ suites `forward 1/4` ..
  `4/4`; the old hand-listed parts and their superseded predecessors (A, A2-A5b, A7a, B) were
  removed. Forward parts 556 + 547 + 508 + 483 = 2094 over all 102 files, reverse 568 + 806 + 720 =
  2094 after the refactor.

- **ENV-SWEEP-LIB-001: the test reset no longer silences once-loaded libraries.** Peer Review
  bf89d59d, B3. `env.reset` in `Tests/env_togbank.lua` wiped every AceComm/AceEvent handler, so a
  library that registers once per run (VersionCheck-1.0 registers its comm prefixes on AceComm itself
  behind a flag that never resets) went deaf for the rest of the run after the first reset. Handlers
  owned by a LibStub library are now kept; an event left with none is removed. The whole forward run
  passed with the sparing switched off, so `Tests/envreset_spec.lua` now pins it (red without the
  fix, checked). Forward-run time on a machine shared with other test runs: 229 s with the sparing off,
  174 s with it on, heap about 135 MB at the end in both -- one run each, so not a measured speed-up.
- Peer Review bf89d59d B2 (the bank search should hold newer orders behind an older one of the same
  item) needed no code change: orders with one item key match the same bank stock, so the bank never
  helps a newer order it could not help the older one with. A spec pins the review's worked case.
  (Orders of one item with and without a suffix do not share a key; SUFFIX-KEY-001 above covers them.)
- **SLOW-REQACTIONS-001: why `Tests/requestsactions_spec.lua` timed out under load.** Peer Review
  074cdad6 A7. One forward run (20261015-141135) aborted the file at the runner's 60 s per-FILE limit;
  the example it named is only where the file's total crossed 60 s. The runner's per-example
  telemetry for that run shows the time was the reset, not the tests: `reset_ms` was over 90% of
  most examples (47-78% in a few) and most of it was garbage collection (the slowest example: 11.7 s,
  11.5 s of it reset, 8.2 s collecting). The spec's `load()` called `env.reset()` and then
  `frames.reset()`. `frames.reset()` runs one full collection (its own `wow.reset()` defers its
  collection to it, `Tests/wowapi/env/frames.lua:7288-7315`); the bare `wow.reset()` inside
  `env.reset()` runs another, but only while the hollow frame registry is not empty
  (`Tests/wowapi/env/wow.lua:2044`). The telemetry says it was not empty: `gc_n` (collections per
  example) was 2 for each `load()` in the timed-out run (4 and 6 for examples that load two or three
  times), and is 1 for each `load()` after the change (2 and 3), in a later forward run
  (telemetry run 20261015T215820). The hollow frame count itself was not read. So every reset
  collected twice over a heap of about 52 MB (`heap_kb` 53518 at the file's first example in the
  timed-out run's telemetry; one sample read). The machine was shared with other test runs (that whole
  forward run took 10m56s against 4m52s for a green one later the same day), and the runner's
  deadline is `os.clock()`, which on Windows is wall time (the harness's own note, `run.lua:970`), so
  CPU starvation counts against it. This halves the work; it does not make the file immune to a
  badly starved machine.
  `load()` now calls `env.reset({ frames = true })`, the single-reset form `Tests/env_togbank.lua`
  documents: the file alone went from 10.12 s to 4.21 s CPU, 47 passing before and after, same heap
  and frame counts. `Tests/browsepersist_spec.lua` had the same pair and got the same change, and
  so did 12 more spec files that reset twice per example (`browse`, `craftlistwindow`, `escape`, `hideitems`, `item`, `mailbox`, `mailwindow`, `optionslayout`,
  `search`, `searchbox`, `statusbaryield`, `windowchrome`); each passed alone with the same count
  before and after. Each of the 12 diffs was read (Peer Review aa437aa8 B6). Every hunk swaps the
  pair for the single reset, with three exceptions. First, in `craftlistwindow` and
  `statusbaryield` the frames reset left a shared `loadStack()`/`load()`, and every caller now
  resets first (checked for both). Second, `mailbox`'s "is ON by default" example used to run
  `frames.reset()` partway through, after `load(true)` and its first assert. It now resets once
  at the start, so nothing resets between `load(true)` and the rest of the example. What the old
  mid-example reset cleared was not read. It passes either way. Third, a stray `wow =package.loaded` spacing slip in
  `windowchrome` is fixed. The other changes in `browse` (FINISHED-001) and `optionslayout`
  (ACCOUNT-MODE-001) are their own entries.
- **FINISHED-001, follow-up (Peer Review f40a8e77 H2).** The Requests window's own "is this order
  finished" check (`Modules/UI/Requests.lua`, which decides whether Cancel and Complete show) and
  `ExpireStaleRequests`, `PruneRequests` and the `/reqscan` diagnostic `Guild:ReqScan` (Peer Review
  7b5e912d) (`Modules/RequestLog.lua`) now call `Guild.IsRequestFinished` instead of their own
  copies, so the window can no longer offer a Cancel that `CancelRequest` refuses, and `/reqscan`
  counts as done exactly the set the prune drops. No behaviour change: every path that stores an order gives it a
  known status (the normaliser maps anything else to "open"), so the old "status is open" test and
  "not finished" select the same orders. `ExpireStaleRequests` had no spec at all;
  `Tests/localefill_spec.lua` now runs it on stale open, part-filled, filled, closed-short,
  cancelled and recent orders and checks which ones it tombstones, and one example pins `/reqscan`'s
  done count (it had no spec either). `Tests/browse_spec.lua` and
  `Tests/requestsactions_spec.lua` lift the real function onto their stub Guild tables rather than
  copying it.
- **REQSCAN-AGE-001: `/reqscan` reported a recent finished order as expired (Peer Review aa437aa8
  B2).** It aged a finished order by `updatedAt` alone, so one with no `updatedAt` aged from 0 and
  counted as "done+expired" while `PruneRequests`, which ages by `updatedAt` and then `date`, kept it.
  `Guild:ReqScan` (`Modules/RequestLog.lua`) now ages by the prune's own spelling, for the expired
  count and the age buckets, and its two labels say "updatedAt, else date"; the missing-`updatedAt`
  count still reads the raw field. Narrow reach: `AddRequest` stamps `updatedAt` and the normaliser
  fills it from `date`, so only a record that skipped both could show it. A red-first example in
  `Tests/localefill_spec.lua` (a finished order with no `updatedAt` and today's `date`) failed with
  "1 done+expired" before the change.
  Follow-up, REQ-AGE-001 (Peer Review ca7dc86f): the expression `tonumber(req.updatedAt or req.date
  or 0) or 0` was written out in five places and had a flaw of its own. A non-numeric `updatedAt`
  string won the `or`, `tonumber` turned it into nil, and the order aged from 0 without falling back
  to `date`. So `PruneRequests` dropped such a finished order at once, whatever its date. All five
  sites now call one file-local `requestAgeTs` helper that converts each field on its own:
  `PruneRequests`, `ExpireStaleRequests`, `ReqScan`, and the duplicate pick in
  `NormalizeRequestList`. Left as it was: `sanitizeRequest`'s `validateTimestamp(req.updatedAt or
  req.date or now, now)`, which falls back to now rather than 0 and is the normaliser's own job.
  Reach is narrow, because `sanitizeRequest` replaces a non-numeric `updatedAt` on every stored path.
  Only a record not yet normalised can carry one. A red-first `Tests/localefill_spec.lua` example
  (a finished order with `updatedAt = "garbage"` and today's `date` must survive the prune and show
  0 expired in `/reqscan`) failed with "1 done+expired" before the helper.

## [v1.8.1] (2026-10-09) - Oldest Order First

### Bug Fixes

- **BANKCOLLECT-SHARE-001: at the bank, Fulfill Oldest skipped a newer order for the same item.**
  crimsonmane, Discord 2026-10-08: Fulfill Oldest *"does not fulfill the oldest order first"* when a
  second player orders the same item plus more. `Mail:FindOldestBankFillableOrder`
  (`Modules/Mail.lua`) measured every order against the whole bag count, so the stack I pulled for
  the older order also "covered" a newer order of the same item, and the newer one was never
  collected for -- it then could not be filled at the mailbox, and only that player's other items
  went out. The bags are now handed to open orders oldest-first, and each order's shortfall is what
  is left after the older orders' share. `Tests/bankcollect_spec.lua` pins both the search and the
  click-through. Not yet checked in a game client.
- **FCFS-001: at the mailbox, Fulfill Oldest mailed a newer order ahead of an older one for the same
  item.** The operator, 2026-10-09: *"you are supposed to fill the oldest order first. first come
  first server"*. `Mail:FindOldestServiceableOrder` (`Modules/Mail.lua`) picked the oldest order the
  bags could fully fill and skipped any it could not, so a newer, smaller order for the same item went
  out first and spent the stock the older order was waiting on. I had described that skip as by design
  in this entry and in my Discord reply to crimsonmane; it contradicted the operator's rule. Now the
  first order for an item that cannot be filled yet holds its place: no newer order for that item is
  sent until it is. Orders for other items still go out, since they do not use the same stacks.
  `Mail:FindMoreOrdersFor` (the same person's other orders riding on one mail) now leaves the stock
  other people's older orders need, so riding along cannot jump the queue either. The three
  fulfillment searches share one "oldest" ordering and one item key. The envelope's tooltip and the
  Requests "?" help in `Modules/UI/Requests.lua` said unfillable orders "are skipped"; both now
  describe the first-come-first-served rule, as does the Fulfill Oldest feature line on the
  CurseForge page. Four examples in
  `Tests/bankcollect_spec.lua`, including crimsonmane's case. Not yet checked in a game client.

### Internal

- **SUITE-SPEED-001: the whole forward test run fits in one run again.** Every spec builds a fresh
  copy of the addon, and libraries that load once per run (AceComm, AceEvent and the other Ace
  mixins, AceAddon's queue of addons waiting to load, VersionCheck's listener list) kept a strong
  reference to every earlier copy, so the run held tens of thousands of dead frames and each reset's
  garbage collection grew slower; late files took 40 seconds or more that take under one alone.
  `env.reset` in `Tests/env_togbank.lua` now clears those references, and a test window's close
  releases its tab contents instead of only hiding them. Measured: objects left after `browse_spec`
  30,800 to 5,400. The forward run passes whole (1970 examples, 2026-10-09) and matches the three
  reverse parts (545 + 722 + 703). Clearing the handler lists means no spec can rely on an addon copy
  from an earlier file still hearing messages; the reverse parts passing is the check on that. No
  addon code changed.

## [v1.8.0] (2026-10-08) - Donations Setting

The "Enable donations" setting is back, off by default, and the Donation popup can be turned off
again. Checked in a game client by the operator on 2026-10-08 (the Donation popup, the tooltip
toggle and the outstanding in-game checks from earlier releases all passed).

### New Features

- **TOOLTIP-TOGGLE-001: a setting to turn the bank stock off in item tooltips.** The operator,
  2026-10-07: *"someone asked to be able to turn it off"* / *"we need to add one to settings, and have
  it on by default"*. There was no such setting: `Modules/TooltipBankerInfo.lua` drew its "Bankers:"
  block on every item tooltip unconditionally. General settings gain "Show bank stock in item
  tooltips" (`db.global.bank.itemTooltipBankers`, account-wide like the Mailbox switches, AceDB default
  `true`; `Options:IsItemTooltipBankersEnabled` also reads a missing key or no DB as on). The check is
  in `TooltipBankerInfo:AppendTo`, the one renderer, so it also covers TOGProfessionMaster's recipe
  tooltips, which call it. `Tests/tooltipbankerinfo_spec.lua` pins the default, the off state and the
  shipped toggle.

### Bug Fixes

- **MAILBOX-POPUP-001: the Donation popup could not be stopped on a bank character.** GUNNEY,
  Discord 2026-10-07: *"donation window pops up on all bankers even when unchecked and I cannot get
  it to stop poping up"*. Confirmed in the code: `Mail:Scan` (`Modules/Mail.lua`) stood aside only
  while the Mailbox window auto-opened, so unticking the General setting "Open the Mailbox window at
  a mailbox" (a global setting, so every banker at once) brought the per-mail Donation popup back in
  its place on every mailbox visit -- and v1.5.2 (UX-WATERFALL-001) had removed the per-character
  "Enable donations" box that used to turn the popup off. The only remaining off switch was "Enable
  for <player>", which also stops bank scanning. That "the popup returns when unticked" rule was my
  design choice in UX-WATERFALL-001, not a request, and it contradicted the setting's own
  description ("Untick to stop that").
- **DONATIONS-BOX-001: the "Enable donations" setting is back, unticked by default.** The operator,
  2026-10-07: *"we should have the setting to enable/disable donations back where it was, and have
  it unchecked by default."* The per-character box returns to the Bank panel at its old place (order
  2, `db.char.bank.donations`, `Options:GetDonationEnabled`), and it alone decides whether the
  Donation popup opens at a mailbox: `Mail:Scan` no longer consults the Mailbox window's setting or
  verdict, so the two settings are independent. The AceDB default changes from `true` to `false`;
  AceDB never wrote the old default to disk, so every character that never touched the box starts
  unticked. This replaces the first fix above, which had tied the popup to the Mailbox window's
  setting a second way. KNOWN COST: a banker who ticks both gets both windows, as before v1.5.2;
  gifts taken through the Mailbox window are credited either way. `Tests/donations_spec.lua` pins
  the popup following the box alone, the box's place, key and OFF default, and the real accessor.

- **PKG-EMBED-001: the CurseForge app stopped installing LibDBIcon for Classic Era, TBC and MoP.**
  The copy of LibDBIcon bundled for WoW Forever in v1.7.1 (`Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua`,
  taken from TOGProfessionMaster) began with the packager's `--@curseforge-project-slug:
  libdbicon-1-0@` marker. The BigWigs packager greps every packaged `.lua` for that marker and records
  the slug as `embeddedLibrary` (release.sh:1882-1889), overriding `.pkgmeta`'s required dependency,
  so the upload told CurseForge LibDBIcon was embedded and the app did not install the standalone
  addon -- while the Era, TBC and MoP TOCs list it under `## Dependencies` and never load the bundled
  copy. Marker removed; the harness `.pkgmeta` checker now reports `libdbicon-1-0=requiredDependency`
  for the upload, and `Tests/wiring_spec.lua` fails if the marker comes back. Whether v1.7.1's
  CurseForge file actually shows LibDBIcon as embedded was not checked on the site (not verified).
  The design is the operator's (2026-10-07): bundled ONLY for WoW Forever, an external required
  dependency everywhere else. `.pkgmeta` also lost all its comments, per the operator's no-comments
  rule of 2026-10-03; release.sh skips whole-line comments, so that change alters nothing uploaded.

### Internal

- **HARNESS-PIN c2fd446: Tests/wowapi moved from a49127f.** Taken for WoWAPITesting's fix to
  harness thread `1a91c3ca`. Under load the runner's per-file TIMEOUT used to escape as a bare
  `lua.exe: (error object is not a string)`, with no file named; it is now a named failure.
  Adoption fix: two `Tests/searchbox_spec.lua` fixtures built a FontString with no font, which the
  harness now refuses as the client does (`FontString:SetText(): Font not set`); they use
  `GameFontHighlightSmall`, the real cells' font. Production was already right (`Requests.lua`
  gives every glow copy a font object).
- **GATE-LOAD-001: the gate survives a busy machine.** run.lua's per-file limit is wall time on
  Windows (WoWAPITesting, same thread), so it tripped whenever other desk runs shared the machine.
  Every forward part now passes `--timeout=240`, and `Tests/run_reverse.lua` passes `--timeout=600`
  (browse_spec ran past 240 s late in the reverse order with three other runs in flight, and passed
  697/0 at 600 s). Forward B2 is split into B3a and B3b, because under load its 52 files outran the
  desk's 15 minutes. `CLAUDE.md` names the new parts.
- **BOARDS-REMOVED-001: the last boards are gone.** `docs/LIBRARY_CONTRACTS.md`,
  `docs/DEPENDENCY_CONTRACTS.md`, `Tests/HARNESS_CONTRACT.md`, `docs/contracts.md` and
  `docs/AUDIT.md` were imported into the writ inbox and deleted. Writ, 2026-10-07: the operator's
  directive is "the boards should be removed after a migration"; git history keeps them. All 81
  imported items were triaged the same day: 79 were already delivered, fixed or board prose. The
  other two were closed with a comment-level change: LOG-001's self-logging is kept on purpose and
  now says so (`Modules/Output.lua`), and Q1's false "nil when there is no link" claim was
  corrected (`Modules/MailInventory.lua`).

## [v1.7.1] (2026-09-29) - WoW Forever

TOG Bank on WoW Forever, the fourth supported client. Checked in a Forever client by the operator on
2026-09-29: *"everything seems to be working right now ... the display and everything is working, no
more lua errors"*, and order highlighting *"works now as intended"*. What that session could NOT
check, for lack of other guild members running the addon: sync between players on Forever, and
other players' names arriving over addon messages there.

### New Features

- **FOREVER-001: WoW Forever is a supported flavour** (`TOGBankClassic_Camelot.toc`, new, Interface
  16001; the operator, 2026-09-28: *"i have wow forever now, we need to onboard to make that a
  supporeted version with it's own .toc and updating the .ps1"*). The fourth TOC is the Era TOC with
  one deliberate difference: LibDBIcon-1.0 is not published for Forever (it is absent from the
  `_classic_beta_` install; TOGProfessionMaster's Forever TOC embeds it for the same reason), so a
  hard `## Dependencies:` entry would stop the whole addon loading there. That TOC lists it under
  `## OptionalDeps:` instead and loads a bundled `Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua` (MINOR 56,
  the copy TOGProfessionMaster ships) straight after LibDataBroker; LibStub keeps the higher MINOR
  if a standalone copy is also installed. TEMPORARY: once LibDBIcon-1.0 ships for Forever, make it a
  dependency again and delete the bundled copy. Every other dependency (Ace3, AceCommQueue-1.0,
  VersionCheck-1.0, DeltaSync, LibAceGUIWidgets, GuildRoster, ItemDB, ProfessionDB) already
  declares Interface 16001 or ships a `_Camelot` TOC. **Not yet checked against the Forever client
  API** (`F:\Blizzard API Docs\wow-ui-source-forever`) and not yet run in a Forever client.
- **FOREVER-HIGHLIGHT-001: order highlighting reaches the WoW Forever bank.** `Modules/ItemHighlight.lua`
  looked only for Classic's `BankFrameItemN` buttons and the `-1` vault, neither of which Forever has.
  Its bank is the tabbed `BankPanel` (Forever `Camelot/BankFrame.xml:85`), which draws one tab from a
  pool of buttons. `UpdateBankPanelHighlighting` walks `BankPanel:EnumerateValidItems()` and reads each
  button's own `GetBankTabID()` / `GetContainerSlotID()`. A tab switch re-inits the pooled buttons with
  no bag event (`GenerateItemSlotsForSelectedTab`), so that is hooked to refresh, and the refresh clears
  every button it dimmed first. The dim-or-clear step for one slot is now one helper,
  `HighlightBankButton`, which the Classic vault and bank-bag loops also use. Spec'd in
  `Tests/itemhighlight_spec.lua`. **Not run in a Forever client.** The icon key on Forever's bank item
  button (`icon` or `Icon`) was not found in the Forever source; both are tried, and a button with
  neither is left undimmed rather than raising.
- **FOREVER-HIGHLIGHT-002: the bags too.** The operator, on Forever with no orders open, ticked
  "Highlight needed items" and nothing in the Combined Backpack greyed. That is not a Forever
  difference in what is needed: every item should grey. The bag path looked up Classic's
  `ContainerFrameNItemM` buttons, and Forever's modern container frames (`ContainerFrameCombinedBags`,
  and `ContainerFrameContainer.ContainerFrames` for split bags) draw pooled buttons with no such names.
  `UpdateModernBagHighlighting` walks each shown frame's `EnumerateValidItems()` and reads each button's
  `GetBagID()` / `GetID()` (Forever `Mainline/ContainerFrame.lua:560`, `:566-567`). It answers false on
  a client without those frames, so Classic Era, TBC and MoP keep the Classic path unchanged.
  **Not run in a Forever client.** Whether Forever's own button refresh resets the grey before our
  next refresh is not known.

### Bug Fixes

- **FOREVER-002: TOG Bank raised a Lua error at login on WoW Forever** (the operator, from game,
  2026-09-28: `bad argument #2 to '?' (Usage: local success = self:HookScript(scriptTypeName, script
  [, bindingType]))` at `Modules/TooltipBankerInfo.lua:117`). The Forever client's GameTooltip has no
  `OnTooltipSetItem` script -- nothing in `wow-ui-source-forever` references it -- and builds item
  tooltips through `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, ...)`
  (`Blizzard_SharedXMLGame/Tooltip/TooltipDataHandler.lua:199`). `TooltipBankerInfo:Initialize` now tries
  the old hook under `pcall` first, so every client that has it keeps exactly its behaviour, and falls
  back to the item post-call, limited to GameTooltip (the only tooltip the old hook reached). `pcall`
  rather than `HasScript`: the offline harness does not claim the client's `HasScript` semantics.
  `Tests/tooltipbankerinfo_spec.lua`: a client refusing the script gets the post-call, which renders
  through `AppendTo` on GameTooltip and leaves any other tooltip alone. `TooltipDataProcessor` added to
  `.luacheckrc` and `.luarc.json`. Not yet re-run in a Forever client.
- **FOREVER-NAME-001: a banker on WoW Forever was not a banker to itself, so the Bank settings page
  never appeared** (the operator, 2026-09-28: *"i set myself as gbank, and show up on the roster ...
  but i don't have the options in the settings menu to make myself visible as a banker"*; `/togbank`
  listed them as `Quebeldorf Flamehammer`). Forever characters have a first name and a surname: the
  roster lists `First Surname`, and `UnitName("player")` returns the two as separate values (Blizzard's
  `Blizzard_FrameXMLUtil/Camelot/NameUtil.lua:4-12` joins them with
  `Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR`). `Guild:GetPlayer` used only
  the first, so the player was `Quebeldorf-Realm`, matched no roster key, `IsBank(self)` was false and
  `Options:InitGuild` never registered the page. The same wrong name reached every self-check (own
  scans, own requests, own-echo guards). New `Guild:GetPlayerFullName()` (`Modules/Guild.lua`) appends
  the second value as a surname only on a client that has that separator constant and only when it is
  not the realm (the documented second return is `unitServer`, and `UnitPopupUtils.lua:126` shows the
  slot can carry either); it is used by `GetPlayer` and the request dialog's fallback
  (`Modules/UI/Search.lua`). Era, TBC and MoP have no such constant and keep the bare name.
  `Tests/guild_spec.lua`: four examples (surname joined and IsBank true; realm in the second slot
  ignored; a surname already in the first slot not doubled; no constant, second value ignored).
  `Constants` added to `.luarc.json`. Not yet re-run in a Forever client, and other players' names
  arriving over addon messages on Forever have not been checked for the same split.
- **PENDING-STATE-001: a banker's own bank read "Old format" between its scan and its first
  publish** (the operator, 2026-09-29, on a brand-new Forever banker's Bankers tab: *"there is only
  one format of data on newer clients, right?"*). `Guild:GetAltStaleness` returns `"v1"` for any held
  copy with no canon, and a canon is minted only AT publish -- so a banker whose scan was stored but
  held by the MULTIPC-001 publish gate (the guild had not answered yet; the status bar's countdown)
  was labelled old-format. New state `"pending"`: our OWN bank, no canon, and `Bank.deferred` set.
  The Bankers tab says "Not published yet" in yellow (`Modules/UI/Browse.lua` STATE_TEXT /
  STATE_COLOR / STATE_RANK), the Inventory tab is not painted red and its tooltip explains the hold
  (`Modules/UI/Inventory.lua`). A later version named by another PC still wins ("behind"), and
  anyone else's canon-less copy is still "v1". Every flavour, not only Forever -- any new banker in
  a quiet guild saw it. `Tests/tabstaleness_spec.lua`: one example walking pending -> behind wins ->
  another banker stays v1 -> published is current.
- **FOREVER-BANK-001: on WoW Forever every bank-character scan raised an error, so a banker's items
  never reached the Guild Bank window** (the operator, 2026-09-29, with BANK debug on: `OnUpdateStop
  called` / `Calling Scan()` and nothing after, then `Inventory/Scan.lua:77: bad argument #1 to
  'GetContainerNumFreeSlots'` from `Bank:Scan` on closing the bank). Forever has no `BANK_CONTAINER`,
  `NUM_BANKGENERIC_SLOTS` or `NUM_BANKBAGSLOTS` -- the Forever tree defines only `NUM_BAG_SLOTS` --
  because its bank is the modern bank-TAB system: each purchased character tab is a container whose
  id comes from `C_Bank.FetchPurchasedBankTabData(Enum.BankType.Character)`, which is how Forever's own
  `Blizzard_UIPanels_Game/Camelot/BankFrame.lua:91-98` counts them. New
  `TOGBankClassic_Constants.BankContainers()` (`Modules/Constants.lua`) is the one list of the
  character's bank containers: on Classic Era, TBC and MoP the vault then the bank-bag range, the
  same ids in the same order as before; on Forever the character tabs. The ACCOUNT (warband) bank
  is left out on purpose -- it is shared by every character on the account, so each alt would
  publish the same items as its own. `Inventory/Scan.lua` walks the tabs when there is no
  `BANK_CONTAINER` (`Scan:ScanBankTabs`; the Classic branch is untouched) and treats tabs reporting no
  slots as "bank out of sight", keeping the stored bank rather than emptying it (INV2-VAULT-001).
  `Bank:FindItemsInBank` and `Mail:FindEmptyBankSlot` walk the same list; on Forever both would have
  raised the same way. `Tests/scan_spec.lua`: four examples (both character tabs read and the account
  bank not; no tab or no slots returns nil; a whole ScanAll completes; the Classic list is the vault
  then BankBagRange). `Tests/itemhighlight_spec.lua`'s BANKSLOT-001 one-spelling guard accepts
  `BankContainers` as the shared spelling and pins that it is built on `BankBagRange`. `C_Bank` added
  to `.luacheckrc` and `.luarc.json`. FOREVER-BANK-002 (the same session's self-audit): the tabs are
  read only while the bank window is open (`Bank.atBank`, set on `BANKFRAME_OPENED`, cleared after the
  close's own scan in `Modules/Events.lua`), because a tab reporting slots is not proof its contents
  are readable away from the bank, and an empty read there would have replaced the stored bank on the
  next vendor or mailbox scan; `scan_spec` pins nil away from the bank. Item highlighting on
  Forever's bank followed as FOREVER-HIGHLIGHT-001, above.
- **FOREVER-NAME-002: on WoW Forever a character's name carries no realm, and TOG Bank added one**
  (the operator, 2026-09-28: *"could it have something to do with the fact that Forever doesn't
  have <name><realm> it has <first name><last name>"*). Forever runs regional unique names
  (`RegionalUniqueNamesEnabled()`, which exists only in the Forever tree): the full name is the
  identity, with no realm. The guild roster returns it bare, Forever's own AceDB keys the character
  as `First Surname` (`AceDB-3.0.lua:263-278` in the `_classic_beta_` install), and LibGuildRoster
  keys its roster by the bare full name (`LibGuildRoster-1.0.lua:1264`, `:1345`, `:1659`). TOGBank's
  `memberRoster` is keyed by the library's names (`Guild:_RefreshFromRosterLib`), but every lookup
  went through `NormalizeName`, which appended `-<realm>`, so on Forever every direct roster lookup
  (IsBank's fast path, IsInCurrentGuildRoster, IsPlayerOnline's fallback, whisper targets) missed.
  On a regional-names client `NormalizeName` now keeps a bare name bare and drops a realm suffix,
  and `GetPlayer` is the bare full name -- the library's rule, in the library's words. The earlier
  FOREVER-NAME-001 surname join is now gated on the same switch instead of on the separator
  constant. Era, TBC and MoP have no `RegionalUniqueNamesEnabled` and take the old path unchanged.
  `Tests/guild_spec.lua`: five examples (the player is the bare full name and IsBank finds them under
  the library's key; a realm suffix is dropped; a surname already in the first slot is not doubled;
  no switch, or a switch answering false, changes nothing). The zero-data banker record saved under
  the old `-ClassicBetaPvE` key is removed by the existing stale-stub cleanup at the next roster
  rebuild. Not yet re-run in a Forever client.
- **FOREVER-EVENTS-001: on WoW Forever the addon stopped half-way through setting up its event
  handling, so a banker's bags were never stored and the Guild Bank window stayed empty** (the
  operator, 2026-09-28: bags full, Guild Bank window "0 items across 0 banks", no debug output with
  BANK and uncategorized debug on). `Events:RegisterEvents` called the bare
  `ChatFrame_AddMessageEventFilter`, which on Era and Forever alike is only a deprecation alias of
  `ChatFrameUtil.AddMessageEventFilter` (`Blizzard_DeprecatedChatInfo/Deprecated_ChatFrame.lua:51`,
  loaded only while the `loadDeprecationFallbacks` CVar is on). On the operator's Forever client it
  was nil, so the call raised and everything after it was skipped: the mailbox hooks, the share
  timer and `eventsRegistered`. It now calls `ChatFrameUtil.AddMessageEventFilter`, the same
  function the alias points at on Era, TBC and MoP (`ChatFrameFilters.lua:195` in each tree), with
  the alias only as the fallback. A sweep of every global Forever defines only in its
  `Blizzard_Deprecated*` files found two more, both in the debug chat tab (`Modules/Output.lua`):
  `ChatFrame_RemoveAllMessageGroups` and `ChatFrame_RemoveAllChannels`, now called as the chat
  frame's own `ChatFrameMixin` methods, present on all four clients. `Tests/events_spec.lua`:
  RegisterEvents finishes with the alias absent and installs the offline-whisper filter through
  `ChatFrameUtil`. Not yet re-run in a Forever client; whether this is the whole reason the scan
  stored nothing there is NOT established -- the empty debug output is consistent with it, but the
  scan's own path was not shown to raise.

### Internal

- **FOREVER-001: the lockstep specs cover the Forever TOC.** `Tests/wiring_spec.lua` pins it as the
  Era TOC with only its Interface line and the LibDBIcon difference changed, so a module added to
  one TOC only still fails; the per-TOC "is this module loaded" examples in `browse`, `item`,
  `logapi`, `mailbox`, `pricelist`, `sendresult`, `togtoolsbridge`, `usable`, `windowalpha` and
  `guildroster_integration` now include it. LIBDBICON-DEP-001's "not vendored" example keeps the
  three other TOCs and names Forever as the exception.
- **`wow-version-replication.ps1` also mirrors into `_classic_beta_`**, the WoW Forever install.
- **Harness pin `ee56a45` -> `a49127f`; `frames.setScreenSize` adopted.** `Tests/browsepersist_spec.lua`'s
  `standUp` now makes one `frames.setScreenSize(2560, 1440)` call. It replaces three hand writes, one of
  them into the harness's private `UIParent._fixedRect` (harness thread `36d5a55f`). The undragged-window
  scale example is back at scale 2. Its 1.25 workaround was hiding a gap in my own hand-rolled resize,
  not a harness defect.
- **REVERSE-TIMEOUT-001: the reverse runner passes `--timeout=240`.** This pin brings in a 60 s
  per-file CPU limit. In the a-end reverse slice, `browse_spec` took 97 s where it takes 9 s alone,
  because every `frames.reset()` fully collects what earlier files left alive (~450 MB, ~150k frames
  by then). All 696 examples passed once the limit was raised. `Tests/run_reverse.lua` now also forwards
  flags after `<part> <parts>` to `run.lua` (`--times`), so a slice can be measured. The timeout was
  escaping as `(error object is not a string)` with no file named; reported to WoWAPITesting on thread
  `5f29b50a` and fixed there in `2b63397` (now a named `TIMEOUT` line and one failure). The harness's
  new `.pkgmeta` checker (`pkgmeta.lua`) reports no FAIL here; its six WARNs are the defensive ignore
  entries that match no tracked file today (`tmpclaude-*`, `*.bak` and the like), kept on purpose. KNOWN COST: a file that slows down in reverse order is now caught at 240 s, not 60. The
  retained heap is still SUITE-HEAP-001's.
- **SPEC-NIL-001: 19 weak `is_nil` assertions strengthened** in the five spec files above that
  writ's new spec-shape check flagged (Writ inbox thread `004cbf2f`: `is_nil` on a literal key passes
  for ever if the literal is misspelt). Removed members are now pinned by an enumerated key set
  (`browse`, `item`); a state that is cleared is first asserted present (`mailbox`, `pricelist`,
  `guildroster_integration`). The PriceList debounce example now holds the timer, so it sees the
  latch set, one publish per burst, and the latch released -- it previously ran the timer
  synchronously and never observed the latch at all. The remaining 59 sites in 22 more spec files
  followed the same day, so writ's spec-shape check is clean repo-wide (`Tests/wowapi` excepted, per the
  thread). The method, in order of preference: a whole-table `assert.same` where the table should hold
  exactly something (`L.opening`, `info.alts`, the answer kinds a responder sent); an enumeration of keys
  by pattern where a removed member must not come back under any name (snapshot helpers, the Escape and
  store settings, the old-wire observer, vendored libraries); an `assert.is_not_nil` on the same
  expression BEFORE the state that clears it (batch state, pending sends, the legacy rows); a local
  constant shared by fixture and check for bracketed string keys, which the checker does not pair; and
  the public API where one answers the question (`D:Entries()`, `Guild:IsBank`, `Switches:IsEnabled`).
- **LAGW-PERSIST-SCALE-001 + LAGW-FORGET-001: TOGBank's window-scale stand-ins retired onto
  LibAceGUIWidgets MINOR 35/36** (released as v0.2.7). The library's `PersistWindow` follows a live
  scale change itself for an AceGUI Frame and re-evaluates a FUNCTION floor on each change, so
  `UI:PersistWindow` now hands it the max(1, scale) floor rule as `floorAt(px)` and registers no
  listener of its own; `Persist_OnScaleChanged`, the `window._togPersist` record and
  `UI:SetPersistedAnchor` (SCALE-DOCK-001's re-dock hook, and its two callers in `Requests.lua` and
  `Search.lua`) are deleted. The re-dock hook existed only because the old listener re-ran
  `PersistWindow`, whose `ApplyStatus` cleared a hand-made dock; the library's listener raises size and
  bounds only, so a docked window keeps its anchor with nothing registered. `UI:ForgetPersistedWindow`
  is now `W:ForgetWindow` (which also restores a ClearFrame handle's own floor, SCALE-FLOOR-002).
  An older library copy without `ForgetWindow` keeps the pre-35 hand-removal of the library record,
  and gets NO floor (LAGW-OLD-FLOOR-001, below).
  `browsepersist_spec`: the live-scale examples pass unchanged on the library's listener alone; the
  released-window example checks the library's record; SCALE-DOCK-001's three examples now pin a dock
  surviving a scale change with nothing registered, a control proving `ApplyStatus` would clear it, and
  a released docked window left alone by the next scale change. **Not run in a client.**
- **DS-422-001 / CLAMP-SCREEN-001: 11 offline failures fixed, all from two sibling-library releases
  the specs had not caught up with** (the addon code was right in each case). Whole suite now
  1939 forward and 1939 reverse, 0 failed.
  - *DeltaSync v4.4.0 (MINOR 22) parks a broadcast whose numbers a listener cannot yet resolve and
    replays it once the table lands.* A viewer now requests straight from the banker's replayed login
    broadcast, with no offer and no version query, seconds after adopting the table. `fullsync_spec`
    pinned the old offer + query round (4 examples): the first-sync example now asserts the shorter
    path and that it goes to the author; "four cold viewers" counts the slots while they drain; "already
    current" counts offers from the second broadcast on; SYNCED-001 reads "pending" as the broadcast
    leaves, not two seconds later when the receipt has genuinely arrived. `congestion_spec`'s park
    example stamped its offer `v = 99`, and a table version is a timestamp, so 99 now reads as a table
    BEHIND the viewer's and is dropped rather than parked; it uses the viewer's own version.
  - *LibAceGUIWidgets v0.2.7 (MINOR 36): `PersistWindow` clamps a saved window to the screen.*
    `browsepersist_spec` saved windows 1200-2000 wide on the harness's 1024x768 screen (6 examples).
    Its fixture now stands up a 2560x1440 screen (tunable, size AND the anchor rectangle, guarded by
    `screenMismatch`), saved tops sit on-screen, and the undragged-window example uses a 1.25 scale:
    that window's CENTER still resolved against a 1024x768 parent after the resize (cause not
    established), so at 2x it hung off the left edge and the clamp correctly moved it. TOGBank's own
    scale listeners were searched for the cause: only the standalone Requests window re-runs
    `PersistWindow` (`Requests_OnUIScaleChanged`, `Modules/UI/Requests.lua:1345`); Browse's
    (`Browse.lua:1181`) only re-lays its lists. A harness helper that resizes the screen coherently is
    requested on WoWAPITesting's inbox (harness thread `36d5a55f`). Delivered and adopted later in
    this release (the harness-pin entry above): the `_fixedRect` write and the 1.25 scale are gone.
  - *Coverage moved, stated so nobody looks for it here:* `fullsync_spec`'s "four cold viewers" now
    drives four requesters through DeltaSync's replay path, so the simultaneous-login-broadcast storm
    is covered only by `congestion_spec`'s storm example.
- **LAGW-OLD-FLOOR-001: an outdated LibAceGUIWidgets (no `ForgetWindow`, before MINOR 35) is handed no
  window floor** (Peer Review on self-audit `587af509`, finding 2). Such a copy never gives a released
  ClearFrame's resize handle its own floor back, and AceGUI's frame pool is shared by every addon, so
  TOGBank's floor would have ridden a pooled frame into another addon's window. With no floor set there
  is nothing to leak. KNOWN COST: on an outdated library TOGBank windows can be dragged below their
  minimum; `UI:PersistWindow` prints one warning per session asking the player to update the library.
  `browsepersist_spec`: an outdated stand-in is handed width and height only and warns once across two
  windows; the control shows a current library still gets the floor as a function.

> Releases **v1.7.0 and older** have been moved to
> [`CHANGELOG_ARCHIVE.md`](CHANGELOG_ARCHIVE.md) to keep this file under GitHub's 125,000-character
> release-body limit. Nothing was deleted; each section moved whole, at a version boundary.
