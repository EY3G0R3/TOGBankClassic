# The Delta Release -- deltas over the canon chain, and the bank log that falls out of them

_Design record, 2026-09-11. It is the durable form of a day's conversation with the operator
(bank #12521, #12522, #12531, #12549); the todo item "THE DELTA RELEASE" points here. Read this
before touching `Bank:Scan`, `SendAltData`, the tuple receive path, or `Modules/Log.lua`. Step 1
(section 4, the legacy retirement) is built; steps 2-4 are not._

**SEQUENCING, as it stands on 2026-09-13.** Step 1 (the INV2 legacy retirement, section 4) is built
and ships in **v1.5.0** -- the release labelled v1.4.2 until the operator renamed it on 2026-09-13
(_"the new UI is kinda a big deal, we should update v1.4.2 patch notes to v1.5.0"_). Steps 2-4 are
**THE DELTA RELEASE, the release after v1.5.0**, blocked on v1.5.0 shipping (the todo list's
in-flight item; bank #12549 is the design). History, so nobody re-derives it: on 2026-09-11 the
operator folded everything into the then-v1.4.2 -- _"ALL our work is on v1.4.2"_ -- and this
document said so; on 2026-09-12 the sync work was set to ship first and the rest to follow as one
release, which is the plan above.

## 0. The operator's words, verbatim, in the order they were said

These are the directives this design implements. They are quoted because the record of _why_ is the
part a summary loses first.

- On the log's shape: _"i think it should work like the in game bank log, look at the f: docs"_
- On persistence, first form: _"the log can't persist, i don't want to use SV space on it, why it
  needs to integrate with TOGTools, who will persist it"_
- On accuracy: _"so the whole ask was a 'accurate' bank log, how do we ensure that? I don't want to
  keep 1000's of lines of data per user, but i'm not seeing a way around it"_
- On scope: _"maybe we limit it to bankers? in our addon all of the bank transactions happen with a
  banker getting an item (mail or trade), storing an item (bank/bag/mail) and passing out an item
  (mail or trade). maybe we only keep the logs on banker accounts from bankers?"_
- On the shared account: _"yes, this is why we do need some kind of a sync, and that's where i'm
  struggling. maybe we bring officers into it to help bridge the gap? i don't want it guild wide"_
- On encoding: _"it's that, or we need some way to make the log encoded. i could see everyone
  wanting to see it, and the only way to do that is give them the data. but what if we did some type
  of encoding like we did with the offer sync and the updated itemDB data flows"_
- On the SV rule, the clarification that governs everything below: _"it's not that we can't have
  stuff in the SV, it's that the SV is limited, and the larger it is, the more impact it has on init
  performance. to the point that it can crash the game if it's too large. we need some way to get
  the v1 data OUT of the SV safely at some point too"_
- On size: _"5000 lines in a guild bank log is a LOT"_
- On the bank's shape: _"our bank is by design different. we don't have one bank, we have 10s of
  bankers, or 1 or 10 or 30, wholly depends on the guild"_
- On transport: _"for this we need to use the P2P deltasync with deltas, so we aren't transmitting a
  bunch of 'old' stuff"_ -- and, on being told the V2 wire sends full snapshots: _"if this is true,
  i have a problem, v2 SHOULD be using deltas too, is it not doing that?"_, then _"then we need to
  fully record this log shit, and finish the v2 sync, because we can make it better/smaller by using
  deltas"_, and _"its why we have the library called... wait for it.... deltasync"_.

## 1. The two problems this solves, and why they are one

### 1.1 The log is not accurate

`Modules/Log.lua` (LOGAPI-001, v1.5.0) records bank movements by _deriving_ them: every client diffs
a received version of a banker against the version it held and logs the difference as deposits and
withdrawals ([Chat.lua:1398-1418](../Modules/Chat.lua#L1398-L1418), [Bank.lua:671-674](../Modules/Bank.lua#L671-L674)).
That is exact only when the client saw every version. When it did not:

- A missed version logs the **net** as if it were a movement. 20 in then 20 out inside the gap is
  invisible; a deposit and a later withdrawal of the same item cancel.
- A fresh install, a wiped SV, or a banker never held before logs **nothing** for the history up to
  that point (deliberately -- otherwise a new install logs a whole bank as a deposit).
- Two clients that held **different** prior versions produce **different** rows for the same
  movement with the same publish time. TOGTools dedupes on tuple + `occ`, so merging those two logs
  double-counts. Nothing on the wire says whether a diff is contiguous, so nothing can tell a span
  from a step.

The principle that fixes it: **an entry is accurate only when computed by a client that held the
version immediately before.** The banker's own client always does -- it wrote the previous version.
And, per the operator, every movement physically happens _on a banker character_ (mail or trade in;
bank, bag or mail store; mail or trade out). So the banker's client is a first-hand witness to every
version it publishes, and nobody else needs to derive anything.

### 1.2 The V2 wire sends full snapshots

Verified 2026-09-11, and it is a regression against what V2 should be: `ComputeTupleDelta` and
`ApplyTupleDelta` ([DeltaComms.lua:409-470](../Modules/DeltaComms.lua#L409-L470)) exist and are
specced (`tupledelta_spec`, `syncpipeline_spec`) and have **no production caller**. `SendAltData`
([Guild.lua:3362-3401](../Modules/Guild.lua#L3362-L3401)) takes `Store:GetAltRecords` for the whole
alt and sends it, every time. The v1.4.0 changelog recorded it as a known cost and the same words
sit at [Guild.lua:3416](../Modules/Guild.lua#L3416); it was then left for two releases.

Why it was left: a delta needs a baseline. The legacy path had the requester send its own
per-source ID+count list in `togbank-state`; that is the wrong shape for tuples, sending a tuple
baseline the other way costs what the snapshot costs, and the provider holds only the **latest**
version of each banker, so it cannot diff against a version the requester names. There is no cheap
rewiring that saves bandwidth. The provider needs _history_.

### 1.3 Why they are one

The per-version diff the log needs -- "what moved between this version and its parent" -- **is**
the delta the sync needs. Written once, first-hand, by the banker at mint, it serves both. The
bounded history that makes deltas possible is the same bounded history the log reads. One store,
one message shape, nothing sent twice, nothing old sent.

## 2. What was ruled out, and why (so nobody re-derives it)

| Design | Why not |
| --- | --- |
| TOGTools merges derived rows from peers | Spanned entries (section 1.1) double-count on merge; the source data is wrong before it reaches TOGTools. |
| Banker-only recording, read from whichever banker is online | Exact, but **partial** on the operator's shared account: PC A and PC B hold different halves in separate TOGTools files and are never online together, so neither can complete the other. |
| Keepers = banker accounts + officers (`C_GuildInfo.CanEditOfficerNote()`, present in the Era and Anniversary client source) syncing per-version batches among themselves | Works, but every keeper needs TOGTools, a keeper must be online to read, and the operator said _"i don't want it guild wide"_ then asked for encoding instead. |
| A separate log wire with its own backfill message | Redundant once the inventory sync sends the chain -- the chain _is_ the backfill. |
| A 30-day window | Unbounded in a busy guild: at 100 versions/day (an assumption -- nothing today records version frequency) that is 3,000 versions and 10,000+ movements. The operator: _"5000 lines in a guild bank log is a LOT"_. |
| Keeping every version | The storage the operator is refusing, rightly; it is also what the load-freeze in PERF-012 came from (persisted delta snapshots added ~18k lines / 0.5 MB). |

## 3. The design

### 3.1 The unit: a version's delta, written first-hand -- and it is a DeltaSync delta

_Revised 2026-09-11 after the operator: "we need to re-evaluate, i'm not sure i agree with 1"
(1 being "our own packed format rather than the library's"). They were right; the first draft of
this section is preserved in bank #12549 as the thing that was ruled out._

At mint ([Bank.lua `MintVersion`](../Modules/Bank.lua#L665)) the banker's client already holds
before and after. It computes the delta over **V2 records** with the library that exists for it:

```lua
host:ComputeStructuredDelta(
    { records = beforeRecords, money = beforeMoney },
    { records = afterRecords,  money = afterMoney },
    { canon = canon, parent = parentCanon, who = { ... } },   -- metadata, section 3.6
    { arrayFields = { "records" }, scalarFields = { "money" },
      arrayOptions = { records = { keyFunc = Record.keyFor, keyFields = { 1, 3, 4 } } } })
```

- `keyFunc = Record.keyFor` is the identity the addon already uses everywhere (id, suffix, enchant).
- `keyFields = { 1, 3, 4 }` names every field the key reads, which the library checks at compute
  time -- a removal is reduced to its key fields on the wire and re-keyed on apply, so a missing
  one makes deletions linger silently (the README's own warning).
- `metadata` is the library's slot for exactly the two things the chain needs -- the version's
  **canon** and its **parent canon** -- plus the "who" annotations.

**Why not our own packed string, which the first draft proposed.** Three reasons it was wrong:
the library's `RequestData` baseline is already `{ hash, version, keys, type, parent }` -- "the
canon I hold", with no records attached -- so the chain design is the library's shape used as
intended, not something bolted beside it; the log entry does not need to be the wire format,
because a movement is `new.count - old.count` and both the author at mint and the receiver at
apply hold `old` (section 3.3); and a second delta engine beside the one the addon depends on for
this is the "same behaviour implemented more than once" finding. `DeltaComms.lua`'s unused
`ComputeTupleDelta` / `ApplyTupleDelta` are deleted, not wired.

**Serialized once, at mint** (`host:SerializeData`), and that string is what the window stores and
the wire carries -- no translation on send. Size is a tuple of 2-4 integers per changed row plus
the serializer's framing; measured on the harness in the test plan rather than asserted here.

**Viewers never derive.** The receive-side `RecordInventoryChange` call in `Chat.lua` is deleted. A
client that did not author a version logs it only by applying the author's delta.

### 3.2 The window: the last 25 versions per banker

Every client keeps, per banker, the last **25** serialized deltas as **one SV line** (joined),
oldest dropped as new ones land. One constant.

- 25 is Blizzard's per-tab number, and in this addon **a banker is a tab** -- the operator's point
  that a guild has 1, 10 or 30 bankers means the cap scales with the roster exactly as the inventory
  store already does. A version with a handful of changed rows is on the order of 100 bytes
  serialized, so ~2-3 KB per banker -- comparable to the banker's inventory record itself.
  30 bankers -> under 100 KB. Measured, not assumed, once built.
- A quiet banker holds months, a busy one holds days, and the busy one is the one whose recent
  history matters.
- The window is BOTH the delta history a provider serves from AND the history the reader shows.
- The rate assumption (100 versions/day) is unmeasured; once the log exists it measures itself and
  the constant moves if it should.

### 3.3 The sync: deltas over the canon chain

1. **The requester names the canon it holds** as its baseline:
   `host:RequestData(holder, { hash = heldCanon, version = heldPublishTime })`. That is the
   library's baseline shape used as intended, and it replaces the state-summary round-trip that is
   on the list as redundant (P2P-035 follow-up). No records travel in the request.
2. **The provider answers with the chain**: in `onDataRequest(sender, baseline)` it looks the
   baseline's canon up in its window and replies `host:SendData(sender, chain, true)` -- the stored
   serialized deltas from that canon to the newest, in order. Baseline canon not in the window, or
   no canon held -> `host:SendData(sender, fullRecordSet, false)`, exactly as today. So a viewer
   who missed two versions of Metals gets two small deltas instead of ~1.5 KB, and a viewer who is
   current gets nothing.
3. **The receiver applies the chain** with `host:ApplyStructuredDelta` per step, in order, then
   **recomputes the content hash and checks it against the newest canon**. A match proves the chain
   was exact; a mismatch falls back to a full snapshot. The integrity check is free because the
   canon already carries the hash.
4. **Each applied step is a log entry**, derived at apply time from what the receiver held and what
   the delta changed: for every key in `added` / `modified` / `removed`, the movement is
   `new.count - old.count` (added: `old` = 0; removed: `new` = 0), money likewise, stamped with the
   delta's canon time and carrying its `who`. The author computes the identical entries at mint from
   the identical inputs. No separate log wire.

The delta operations and the transport are both the library's; the addon supplies the key
function, the window, the chain lookup, and the hash check.

**AS BUILT (step 3b, CHAIN-002, 2026-09-11 -- `Modules/Inventory/Sync.lua`), where it differs
from the four points above:**

- The baseline also names the ALT (`keys = { alt = norm }`): the host's callbacks carry only the
  sender, and a requester may have several sessions open with one peer.
- Every reply travels on the host's RESPONSE channel (`isDelta = false`), the chain included. The
  DELTA channel runs the library's `ValidateDelta`, which requires `type == "delta"` and a
  `changes` table -- a payload carrying several links under `type = "inv-chain"` is not that
  shape. Three reply types: `inv-nochange`, `inv-chain`, `inv-snapshot`.
- The provider serves the chain only when it also ENDS at the version it holds. A relay whose
  record moved by a snapshot has a chain that ends earlier; serving it would leave the requester
  one version short under a canon that says otherwise. Otherwise: snapshot.
- A requester that holds a NEWER canon than the provider is answered no-change: nothing the
  provider sends could improve the copy, and a snapshot would be discarded as stale on arrival.
- A refused chain does not "fall back to a snapshot" inside the same exchange. The receiver marks
  the alt in `Guild.forceFullRequests` and fails the session into the normal catch-up; the next
  request claims no baseline and is answered with the snapshot. One path, the slot rules intact.
- Applied links are KEPT (`Chain:Append`): a receiver that applied the chain can serve the
  author's links on, so the chain travels the mesh the way the data does.
- The send slot is released on the transport's terminal verdict, through Core's transport proxy
  (`Core:WatchHostSend`), because the library exposes no per-send completion (LIBREQ-DS-009).
- Point 4 (the log entry per applied step) is step 4 and is NOT built yet; a chain delivery is
  logged as one diff, held -> applied, exactly as a snapshot is.

### 3.4 Rules that do not move

- **The canon is final.** Minted once, at scan, by the client that read the bank; carried unchanged
  by everyone else (HASH-CANON-001/002/005).
- **Ordering is the author's publish time** (`Chat:ShouldApplyTuplePayload`). DeltaSync's README
  says outright that a peer may legitimately receive an older copy and that the consumer owns the
  merge rule.
- **The offer stays hashless and tiny**; the version query stays; the wire carries banker numbers.
- **TOGBankClassic pushes to TOGTools unchanged** (`Log:PushToTOGTools`, `occ` = publish time,
  `source = "TOGB"`). TOGTools keeps the long history if it wants one.

### 3.5 The shared account (MULTIPC)

A PC that logs in behind another PC's publish knows a newer version exists (the MULTIPC-001 gate).
Before minting, it **fetches that version as its diff base** -- used for the diff only, never stored
as its own record (a flat copy would double-count bags on the next scan) -- so it logs only what
_it_ moved and its diff's parent is the true parent. If nobody online has it, that PC publishes
with the true parent and logs nothing; whichever client holds the parent derives the step when the
new version reaches it, and everyone else gets it from the chain.

**Residual, stated:** a version that no other client ever held before its successor arrived -- the
only PC that saw v3 never logs in again -- is on nobody. It gets a gap marker, never a fabricated
net. Nothing short of every client keeping every version closes that.

**AS BUILT (MULTIPC-002, 2026-09-11), where it differs from the paragraph above:** the fetch goes
through the ordinary handshake for our own name (`Bank:RequestDiffBase` -> `P2PSession:DispatchList`;
`Sync:RequestFrom` forces full for self), `Sync:ReceiveSnapshot` routes the delivery to
`Bank:ReceiveDiffBase` while it is awaited, and the deferred publish mints against it. The
"nobody has it" case is NOT "publish with the true parent": a PC cannot name a parent it never
held, so the 180s fallback publishes with **no link and no log entry** (data exact), and a viewer
that held the previous version snapshots to the new one and logs the net. The holder list comes
from the three paths that learn of a newer self version (`Guild:NoteSelfHolder`). Pinned by
`Tests/multipc_spec.lua` and two `fullsync_spec` scenarios.

### 3.6 The "who"

Blizzard's log says who deposited to a shared tab. Ours has no shared tab -- every movement is a
mail or trade _with a member_, and the banker's client knows the member on both sides:

- a withdrawal by fulfilment is a request event (`mailed` -> requester);
- a deposit by mail is a mail whose sender the banker's inbox scan saw.

So a diff can carry `to` / `from` where the banker's client knows it, and a plain deposit/withdraw
where it does not (trade, vendor, bag shuffle). With N bankers this is what makes the guild-wide
view readable at all.

**AS BUILT (LOGWHO-001, 2026-09-11):** derived once by the author at mint (`Log:AttributeChanges`
from the `mailed`/`handed` request events it just recorded and the inbox senders the mail scan
reports), stored INSIDE the chain link's body beside the changes, handed back per step by
`Chain:ApplyAll`, and logged per link on a chain receive -- so every viewer's rows carry the
author's names without deriving anything. An over-claim is ignored whole. A snapshot receive still
logs the unattributed net.

### 3.7 Two views, one store

- **Per banker** -- Blizzard's per-tab view: what moved through Metals.
- **Guild-wide recent** -- every banker's batches merged newest-first.

Both are reads over the same 25-per-banker window. For a one-banker guild they are the same view.

## 4. Prerequisite: retire the legacy scan (INV2-RETIRE-001)

The diffs come from V2 records, and today `Bank:Scan` is **legacy-first**
([Bank.lua:201-588](../Modules/Bank.lua#L201-L588)): the container walks write the legacy
sub-tables, the aggregate `alt.items` is rebuilt at :352, and the V2 store is a `pcall`'d mirror
that re-walks the containers. Everything downstream reads the legacy aggregate: the content hash
(:474), `MintVersion`'s stamp (:669), the bank-log diff (:208/:672), `PublishIfDeferred` (:690), the
mail hash (:523). So the retirement is not "strip rows" -- it is **make the V2 walk the scan and
feed hash / stamp / log from Store records, then strip.**

Measured on the operator's own account (2026-09-11): the SV is 1.52 MB / 64,123 lines; the V1 item
rows are ~35,900 lines (56%), the 30-day request window ~22,700 lines (35%, 1,735 requests -- ~58 a
day), the V2 store ~5,200 lines (8%). Nothing in the V1 rows is unique: every banker's rows are
re-derivable from the V2 store or the next delivery/scan, so a rollback needs no V1 copy.

The reader enumeration is done (bank #12531), by reading, not grep:

- **Already on the accessors, no change:** `UI/Inventory.lua`, `UI/Search.lua`, `UI/Requests.lua`
  -> `Guild:GetAltItems`; `TooltipBankerInfo.lua` -> `Guild:GetAltItemTotal`.
- **The accessors** (`Guild.lua:970-1078`): V2 branch gated on `Store:IsAltComplete`, legacy
  fallback after. The fallback dies with the rows. ~~**Gate the strip on `IsAltComplete`** -- a
  schema-1 V2 record (scanned before INV2-MAIL-001, no mail bucket) still needs the legacy rows for
  a correct total and strips on its next scan or delivery.~~ **Superseded during the build
  (2026-09-11): the strip is UNCONDITIONAL.** The gate existed to keep the legacy rows for the
  accessors' fallback; once the fallback itself is deleted there is nothing for the rows to be
  kept FOR, and the gate would only have preserved 56% of the SV for a record whose short total
  heals on the banker's next mailbox visit anyway. A schema-1 record now answers SHORT rather than
  empty, which is the better of the two remaining choices.
- **Legacy-only readers needing a V2 spelling:** `Mail.lua:829-830` / `:857-858` (the "in mail" /
  "in bank" hint reads the local banker's per-source rows -- needs a per-source Store read;
  `SetAltSources` keeps the buckets apart); `UI/StatusBar.lua:153` (mail count, same read);
  `Guild:HasAltContent` legacy half; `HasAltData` / `CleanupMalformedAlts` / ROSTER-002 stub test
  (item clauses become dead); `Guild:EnsureLegacyFields` and its three callers; `Database:PurgeLinklessGearGhosts`
  (legacy-only migration -> no-op -> delete); `/togbank dev compare` and `trace`.
- **Hashing:** `hashInventoryItems` accepts tuples (finding 32); `hashInventoryItemsV1` (frozen
  rev1) sees only `.ID` rows and would hash money-only over tuples -- compute rev1 from
  `Store:GetAltView`, or retire rev1 (HASH-OFFER SLIMMING already calls it dead weight).
- **Expect one version bump per banker** on the first post-retirement scan: the legacy aggregate
  merged suffix variants (INV2-SUFFIX-001), `Record.keyFor` does not, so the content hash can differ
  for the same bank. A single blip, stated in the changelog.
- **Cross-addon:** TOGProfessionMaster `Compat.lua:272-318` reads `Info.alts[name].items`
  directly -- already stale for received bankers on v1.4.x. **The operator: "we can't break the
  bank integration."** So `alt.items` KEEPS ANSWERING, from the store, through a per-record
  metatable (INV2-COMPAT-001, `Database:AttachAltsCompat`) that never reaches the SV; TPM reads
  live data on this release without a change on its side. Moving TPM to `Guild:GetAltItems` /
  `GetAltItemTotal` is still the right thing for TPM (its `GetStock` also counts ex-bankers), but
  it is no longer a dependency of this release.
- **Done ahead of it (INV2-RETIRE-002, v1.5.0):** the dead delta-snapshot cache --
  `Database:SaveSnapshot` deep-copied every item row on every scan for a reader deleted in v1.4.0.

## 5. Build order

One release -- v1.5.0 itself, per the operator -- in this order; each step leaves the suite green on
its own:

1. **Retire the legacy scan** (section 4). V2 walk is the scan; hash, stamp, log and deferred
   publish read Store records; legacy-only readers moved; strip unconditional (see section 4);
   `EnsureLegacyFields`, `PurgeLinklessGearGhosts`, the legacy half of `HasAltContent`, the
   `inventoryV2` / `dualWrite` switches and `/togbank dev compare` deleted. **DONE 2026-09-11**
   in three increments -- see `CHANGELOG.md` v1.5.0, "The Delta Release, step 1". Not run in game.
2. **DeltaSync host migration** (LIBREQ-DS-003): `NewHost`, `RegisterDebugCategory` plus the
   `onDebugMessage` tap into `Output:PersistToLog` (persistence and export stay in `Output` --
   `/togbank debuglog` is the thing the CurseForge page tells users to attach); a local debug sink
   for when the library failed to load; `constants_spec`'s call-site scan follows the categories;
   delete the duplicate envelope code (`SerializeWithChecksum` / `DeserializeWithChecksum` /
   `ComputeChecksum` -- the checksum is a frozen cross-implementation contract, unchanged on either
   side). **Increment 1 DONE 2026-09-11 (DS-HOST-001):** the host exists, the envelope and checksum
   are the host's with the bytes pinned as literals, library debug routes into `Output` under
   `DELTASYNC`. **The registry consolidation is SUPERSEDED (2026-09-11):** DeltaSync's own
   `RegisterDebugCategory` doc (`DeltaSync.lua:2049-2057`) says `config.logger` is for a host with
   a mature output layer and the two are alternatives, not halves -- TOGBank took the logger route
   in DS-HOST-001, so there is no registry to consolidate. Nothing further owed under step 2 until
   2b.
   - **2b. THE NUMBERED P2P MOVES INTO DELTASYNC.** The operator, 2026-09-11, choosing between
     "move P2P-035 into DeltaSync as the library's P2P" and "keep it as TOGBank's layer on the
     host": _"use deltasync, the whole point of this effort was to strip the chaff out of TOGBank
     and make it function better"_ (directive #12702). The library's current P2P is a port of the
     OLD P2P-006 design (its own header says so) -- per-name offers carrying hashes, offer-on-differ,
     no version query, least-loaded dispatch that falls back to an older holder -- every one of
     which a P2P-035 directive forbids. So the library gains the numbered protocol as a feature:
     filed to DeltaSync's inbox as **LIBREQ-DS-008** (thread `c20eb5b527e1`), specified from
     `Modules/P2PSession.lua` and `Modules/BankerNumbers.lua` as the reference implementation.
     TOGBank adopts on the DeltaSync release that ships it and deletes both modules and the
     `togbank-hl` / `-hlr` / `-rr` prefixes (`-state` and `-nochange` went with step 3b). Until then
     step 3 proceeds on the host's data leg with TOGBank's own P2PSession driving the handshake --
     nothing here blocks v1.5.0, and the deletion is the adoption.
3. **Deltas over the canon chain** (sections 3.1-3.5): the packed diff at mint; the 25-per-banker
   window; the sync-request naming the held canon; the chain reply or full-snapshot fallback; apply,
   verify against the canon, fall back on mismatch; the MULTIPC diff-base fetch.
   **3a DONE 2026-09-11 (CHAIN-001):** the link at mint, the window, `Since` / `ApplyAll` / `Verify`.
   **3b DONE 2026-09-11 (CHAIN-002):** the data leg on the host -- `Inventory/Sync.lua`; the
   state summary and `togbank-state` / `togbank-nochange` deleted; see "AS BUILT" under 3.3 for
   where the shipped shape differs from the sketch. Not run in game.
   **3.5 DONE 2026-09-11 (MULTIPC-002):** the diff-base fetch; see "AS BUILT" under 3.5.
   **CHAIN-003 (peer review F2):** the QUERY is answered only for a requester holding a send slot.
   **Full-sync e2e (FULLSYNC-001):** `Tests/env_fleet.lua` + `Tests/fullsync_spec.lua`, fourteen
   whole-fleet scenarios through the real libraries.
4. **The log** (sections 3.6-3.7) falls out of 3: each applied step is an entry; the receive-side
   derivation is deleted; `to` / `from` ride in the batch; the two views.
   **DONE 2026-09-11 (LOGWHO-001):** each applied link is one dated entry; `to` / `from` derived
   once by the author and carried in the link; see "AS BUILT" under 3.6. The two views (3.7) are a
   reader concern for TOGTools, which stores the log; nothing in TOGBank renders it.
5. **Cleanup that rides the same release:** PERF-022's `itemID -> {banker, count}` index (built now
   because step 3 is what settles the writers it must be invalidated by); F2's
   `Guild:RequestQuantityNeeded` helper; HASH-OFFER SLIMMING (rev1 gone from the hash-list entry).
   **PERF-022 and the helper DONE 2026-09-11** (the index is the Store's, dropped with its record
   cache). **HASH-OFFER SLIMMING DEFERRED to the LIBREQ-DS-008 adoption:** rev1 is the
   `expectedHash` the live `alt-request` protocol runs on, and every site that reads it is in the
   `togbank-hl` / `-hlr` / `-rr` layer that adoption deletes wholesale -- rev1 goes with it. The
   reasoning is in `CHANGELOG.md` v1.5.0 under "DEFERRED".

## 6. What stays open

- **Request retention.** Done requests are 35% of the SV at the 30-day `EXPIRY_SECONDS`. Asked
  three times on 2026-09-11, unanswered; **assumed to stay at 30 days** until the operator says
  otherwise. Not to be re-asked.
- **Version frequency.** Unmeasured. The log measures it; the window constant moves if it should.
- **Whether the guild-wide recent view or the per-banker view opens by default.** Asked once; the
  answer decides whether the reader is "a feed with a banker filter" or "banker tabs with a feed
  behind them". Either is built over the same store.

## 7. Test plan (offline, on the harness)

- **Diff correctness:** for every pair (before, after) of record sets, `apply(before, diff(before,
  after))` hashes to `after`'s canon -- including suffix variants, money-only changes, empty -> full
  and full -> empty. Prove red by corrupting one count.
- **Chain application:** two clients on the harness's rich frame layer; A publishes v1..v4; B holds
  v2 and asks; B receives exactly the v3 and v4 batches, applies them, and its content hash equals
  A's v4 canon. B holding a canon outside A's window receives a full snapshot.
- **Window:** the 26th version drops the oldest; the SV line stays one string per banker.
- **Log entries:** B's log after the chain equals A's log for v3 and v4, row for row, with identical
  `occ`; nothing is logged for a full-snapshot fallback except a gap marker.
- **MULTIPC:** a stale PC fetches the newest version as diff base and its diff's parent is that
  version; with nobody holding it, it publishes with the true parent and logs nothing.
- **Retirement:** every reader in section 4 answers from the Store with the legacy rows absent; the
  strip skips a schema-1 record; the first post-strip scan bumps the version once and the second is
  quiet.
- **Coverage:** 100% on every file touched, `lua Tests/wowapi/coverage.lua` from the addon root.
