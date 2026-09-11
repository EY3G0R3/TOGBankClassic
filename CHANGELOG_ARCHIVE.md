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
