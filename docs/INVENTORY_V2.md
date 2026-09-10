# Inventory V2 — tuple storage and wire format

Design contract for the v1.4.0 inventory rework. **No code has been written against this.**
It exists to be argued with first; the specs assert against it once it's agreed.

Ticket prefix for this work: `INV2-`.

---

## 1. What problem this solves

Today an inventory entry stores a full item link, and links are the addon's item identity.
Everything below is downstream of that one decision:

- **Miscounts.** The same physical item can reach the table under two spellings — a live client
  link writes `:0:0:0:0:0:`, a rebuilt or stripped link writes `::::::` — and `Item:GetItemKey`
  keeps those fields verbatim, so they key differently and aggregate as two rows with split
  counts.
- **The link-stripping subsystem.** `NeedsLink`, `ItemClassNeedsLink`, `ForceLink`,
  `StripItemLinks`, `StripDeltaLinks` exist solely to decide "is it safe to drop this link
  before sending". Guess wrong on a cold cache and gear arrives linkless.
- **Ghost rows.** `ITEM-003` / `ITEM-004` and the `PurgeLinklessGearGhosts` migration that still
  runs on every login are cleanup for damage that subsystem caused.
- **Bandwidth.** ~70–90 bytes per item on the wire, most of it a string the receiver could have
  derived.
- **Cold-cache defence.** `Item:GetItems` is a 250-line asynchronous fan-in — and `ITEM-005`
  lives inside it — because `GetItemInfo` returns nil until the client cache warms.

Storing `(itemID, count, suffixID, enchantID)` and deriving the link at render time removes all
of the above **structurally**. Two entries are the same item iff four integers match. There is
no second spelling, so there is nothing to normalise and nothing to strip.

---

## 2. Decisions already made

| Decision | Choice | Rationale |
| --- | --- | --- |
| Storage format | Integer tuples, links derived at render | Removes string identity entirely |
| Old data | **Separate new SavedVariable. No migration, no conversion.** | Additive; each DB written only by its own native path. A conversion that computes the wrong thing corrupts the original — see `MIGRATE-001` |
| Cold start | **Accept an empty DB.** Re-ingest by logging bankers in | No seed code, therefore no conversion bugs |
| Legacy DB upkeep | **`dualWrite` on** — keep it current from the same scan | Makes rollback land on live data rather than a stale snapshot, and makes v1-vs-v2 comparison valid |
| Flavour | **Vanilla / Classic Era only.** TBC follows | IDB's Vanilla set is complete below ID 25000; TBC data is a separate build |
| Scope | **Inventory only.** Requests follow | Requests already carry `itemID` + suffix, so they convert cleanly later |
| Rollout | New `.lua` files behind dev switches; old path untouched | Clean break, real rollback |

---

## 3. The record

### 3.1 Storage shape

Positional array, trailing optionals omitted:

```lua
{ id, count }                      -- plain item (the overwhelming majority)
{ id, count, suffix }              -- random-suffix gear
{ id, count, suffix, enchant }     -- enchanted
```

Positional rather than named keys because SavedVariables repeats every key string per row.
`{12345,20}` against `{id=12345,count=20}` is a large multiple across ~10k rows, and oversized
SavedVariables have already caused a load freeze here once (`PERF-012`: 18k lines / 0.5 MB).

`suffix` is signed — negative values index the random-property table rather than the
random-suffix table, and dropping the sign merges two genuinely different items.

### 3.2 Identity

```lua
key = string.format("%d:%d:%d", id, suffix or 0, enchant or 0)
```

Uniform, no branching, negative-safe. Two records aggregate iff their keys are equal. This
replaces `GetItemKey` / `GetItemString` / `GetSuffixID` string surgery entirely.

**Open question:** a numeric key would be faster but suffix can be negative and packing is
fragile. Proposing the string key unless profiling says otherwise.

### 3.3 What is deliberately NOT stored

`uniqueID`, item level, and the display name. All are either per-instance noise the addon
already strips, or derivable from IDB. Gems (fields 3–6) are **out of scope for Vanilla** and
must be revisited before TBC — a socketed item stored in a bank would lose its gems.

---

## 4. Resolution and the fallback chain

**IDB is a REQUIRED dependency, and that is a consequence of this section rather than a
preference.** Because rendering asks IDB and never the wire, the library is what the entire
storage format rests on: with it absent there is no way to turn `{id, count, suffix, enchant}`
back into an item. It is declared in both TOCs (folder name `ItemDB`) and in `.pkgmeta` (slug
`libitemdb` -- the two spellings differ and each fails silently in its own way).

**This was not true until 2026-09-08 and the gap was invisible.** `Resolve` asks for the library
through `LibStub("LibItemDB-1.0", true)`, the optional form, which returns nil rather than
raising -- and nothing declared the dependency. On any install without ItemDB, step 1 below never
answered and every single row fell through to step 2 or 3, silently. `Resolve` now reports a
missing library once, at a player-visible level, which is separate from the per-id logging noted
at the end of this section.

**Steps 2 and 3 are for ids the library does not CARRY. They are not a supported mode of
operation for a missing library.** The distinction matters: "this item is not in the DB" and
"there is no DB" are different facts, and collapsing them is precisely what let the second hide
inside the first.

Rendering asks IDB, never the wire. Order, first hit wins:

1. **`IDB:GetSuffixLink(id, suffix)`** — authoritative. Validated: `(10132, 863)` yields
   `|cff1eff00|Hitem:10132::::::863|h[Revenant Helmet of the Eagle]|h|r` with correct name,
   quality colour and suffix family.
2. **`GetItemInfoInstant(id)`** — cache-independent, so it works cold. Gives icon, class and
   subclass; build a bare `item:<id>` link from it.
3. **Placeholder** — `Item #<id>` with the default question-mark icon. Never blank, never an
   error.

Every fall-through past step 1 logs the id under a dedicated debug tag so unresolved items can
be collected and IDB topped up, rather than silently degrading.

### 4.1 Known IDB gaps (measured, not assumed)

Against TOGBank's own wago-derived static set (24,442 entries):

```
IDB base (Era/Hardcore)        17,593 items
IDB base + seasonal overlay    24,127 items
missing even with overlay         330  (all id >= 120000)
missing below id 25000              0
```

Two findings that need library-side attention before this ships:

- **`INV2-IDB-001`** — the >=25000 data is gated behind `lib:IsSeasonalRealm()`, true only for
  season 2 / 11 / 12. **On a plain Classic Era or Hardcore realm the overlay never loads.** Not
  everything above 25000 is seasonal: **Chronoboon Displacer (184937)** is Era-available, lives
  in guild banks constantly, and is unresolvable there today. The gate conflates "high item ID"
  with "seasonal realm". Fix upstream in ItemDB — either split the overlay into always-load
  modern-Era additions vs genuinely seasonal, or load high-ID data unconditionally.
- **`INV2-IDB-002`** — IDB's core carries `classID, quality, subClassID, equipLoc, itemLevel,
  stats` plus per-locale name. It does **not** carry `reqLevel` or vendor price. `reqLevel` is
  what the "By Level" sorts use (`SORT-002`/`SORT-003`) and what `Item:Sort` currently burns
  retry loops chasing. Wanted as an ItemDB addition. Icon is fine via `GetItemInfoInstant`.

---

## 5. Storage location

New SavedVariable, declared in **both** TOCs:

```
## SavedVariables: ..., TOGBankClassicInvDB
```

Scoped exactly like the existing DB — AceDB, per-guild under `db.faction[guildName]` — so the
scoping rule in `CLAUDE.md` still holds and nothing new has to be learned to read it.

`TOGBankClassicDB` keeps being written while `dualWrite` is on (§6.1), by the **existing,
unmodified** v1 write path. So the safety property is not "the legacy DB is never touched" — it
is the narrower and more useful one:

> **No data is ever translated between formats.** Each DB is written only by its own native
> path, from the same source scan. Nothing reads v1 data to produce v2 data, or the reverse.

That is what removes the corruption class. `MIGRATE-001` is a live example of the alternative:
a conversion that computed the wrong thing and silently gave every pre-v0.8 character a bogus
hash, with the original already overwritten.

### 5.2 Per-alt shape -- sources kept apart, aggregated on read (`INV2-VAULT-001`)

```lua
TOGBankClassicInvDB.faction[guild].alts[name] = {
    sources = { bank = { <tuple>, ... }, bags = { ... }, mail = { ... } },
    money   = <copper>,
    updated = <server time>,
    schema  = <Store.SCHEMA at write time>,
}
```

**The split is not tidiness, it is the only shape that can express "I could not read this
source".** The vault is readable only at a bank NPC; bags and mail are readable anywhere. A single
flat record set forces a writer that is away from the vault to choose between overwriting the
stored vault with nothing and skipping the write entirely -- and the first cut chose to skip,
which also discarded the bags and mail it had just read. Since a mailbox is almost never opened at
a banker, mail could never reach the store however many times a character rescanned.

`Store:SetAltSources` replaces the sources it is handed and keeps the ones it is not.
**Absent and empty are different on purpose:** absent means "keep what is stored", empty means
"read, and genuinely empty". Conflating them turns mail into a ratchet that only grows, which a
spec in `Tests/wiring_spec.lua` drives directly.

**The legacy DB has always had this shape** -- `alt.bank.items` / `alt.bags.items` /
`alt.mail.items`, aggregated into `alt.items` on the way out -- and that is exactly why it never
had this defect. This is the "right idiom already exists and the new code did not use it" pattern
from `docs/REVIEW.md`, found in production rather than in review.

`Store.SCHEMA` records which **sources** a stored set covers. It is bumped when the scan gains a
source, **not** when the tuple layout changes -- `Record.lua` owns that, and the two version
independently because they fail differently: a layout change makes rows unreadable, a source
change makes totals **short**. An absent stamp reads as `1` (bags + bank), never as "unknown",
because the field was added with `2`. `Guild:GetAltItems` refuses a record below the current
schema and falls back to the legacy store, which self-clears on that character's next scan
(`INV2-STALE-001`).

### 5.1 Retirement

The old DB needs a stated end or it rots: `TOGBankClassicOptionDB` is still declared in both
TOCs and CLAUDE.md already calls it "legacy options".

- [ ] **`INV2-RETIRE-001`** — once V2 has been the default for **three** releases with no
  rollback, a cleanup release nils `TOGBankClassicDB` and drops it from both TOCs. Tracked in
  `docs/AUDIT_2026-08-03.md`, not left to memory.

---

## 6. Dev switches

New switches do **not** go into the bare-global `FEATURES` table — `NS-001` already flags those
eleven globals for namespacing, and adding to them makes that worse.

Proposed: one namespaced registry, `TOGBankClassic_Switches`, where each entry declares what it
gates, its default, and when it should be deleted. `/togbank dev switches` lists every switch
and its live state.

| Switch | Default | Gates |
| --- | --- | --- |
| `inventoryV2` | off | Read routing and V2 writes: V2 store vs legacy |
| `sendV2Wire` | off | Emit tuple payloads instead of link payloads |
| `dualWrite` | **on** *(while `inventoryV2` is on)* | Also keep writing the legacy DB from the same scan |

Receiving is **not** switchable — both payload formats are always accepted. That is permanent
protocol compatibility for mixed-version guilds, not a dev toggle.

Rationale for the split: `sendV2Wire` is safely reversible in both directions. Storage would not
have been, which is why the separate-DB decision matters — no data is ever translated between
the two formats, so neither can corrupt the other.

### 6.1 Why `dualWrite` defaults on

Without it, flipping `inventoryV2` off returns you to a legacy DB that is byte-identical to the
moment you flipped on — which after a week of use is **stale, not useful**. That is a rollback
in name only.

With `dualWrite`, the legacy DB stays current, so rolling back lands on live data. It also makes
`/togbank dev compare` meaningful: both DBs were written from the *same* scan pass at the *same*
instant, so any divergence is a genuine encoding bug rather than a timing artifact. That is the
measurement that proves the miscount problem is actually gone instead of assumed gone.

**Implementation requirement: one scan, two writes.** The container API is walked **once** and
the single result is written in both shapes. Running two independent scans would double the cost
of the addon's hottest path and — worse — invalidate the comparison, because the bank could
change between passes.

`dualWrite` retires together with the legacy DB (`INV2-RETIRE-001`); it has no purpose after.

**Deviation, deliberate and temporary (`INV2-WIRE-001`).** `Scan:ScanAll` implements the
one-walk/two-shapes rule and is tested for it. The wiring in `Bank:Scan` does **not** use it that
way yet: the legacy walk runs as it always has, and the V2 mirror re-walks the containers
afterwards. That is a second walk, and it is the arrangement §6.1 argues against.

It is correct for exactly as long as the legacy path is authoritative. Sharing the walk means
editing the legacy scan, and the property being protected right now is that the legacy scan is
untouched — a bug in the shared walk would hit every existing user, whereas a bug in a mirror
that nothing reads costs a switch flip. The cost is one extra container walk on a banker with
`inventoryV2` on, which is opt-in.

The consequence to be honest about: `/togbank dev compare` is therefore comparing two walks, not
one, so a divergence it reports *could* in principle be a stack that moved between them rather
than an encoding bug. In practice the two walks are microseconds apart inside a single
`Bank:Scan` call with no yield between them, so this is close to theoretical — but "close to
theoretical" is not "impossible", and a divergence should be reproduced before it is believed.
Once V2 becomes the writer, `Bank:Scan` calls `ScanAll` once and the legacy branch is deleted,
which removes both the second walk and this caveat.

---

## 7. Module layout

New files, added to **both** TOCs in dependency order. Nothing in the existing tree is edited
until the switch defaults to on.

| File | Responsibility |
| --- | --- |
| `Modules/Inventory/Record.lua` | Tuple encode/decode, the key function, validation |
| `Modules/Inventory/Resolve.lua` | IDB lookup + the three-step fallback chain |
| `Modules/Inventory/Store.lua` | The V2 SavedVariable: read/write, per-alt aggregation |
| `Modules/Inventory/Scan.lua` | Bag/bank/mail scan → tuples. Under `dualWrite`, emits **both** shapes from one container walk (§6.1) |
| `Modules/Inventory/Wire.lua` | Tuple serialise/deserialise, both directions |
| `Modules/Switches.lua` | The switch registry and its slash command |

### 7.1 UI compatibility

Every UI module reads `Guild.Info.alts[name].items`. Rather than editing each one behind a
switch, `Store` exposes a **view** in that same shape, materialised from tuples + IDB.

The view is cached per alt and invalidated on data change — resolving ~10k rows on every draw
would be worse than what it replaces. This keeps the UI diff near zero for the first cut and
lets the UI be simplified later, separately.

---

## 8. What this deletes once V2 is default

**DONE 2026-09-09.** Not "fixes" -- deletes, because the conditions that made them necessary stop
existing.

**THE ORIGINAL TABLE HERE WAS WRONG AND IS CORRECTED BELOW. Do not work from a copy of it.** It
listed three categories as one list, with very different risk, and following it literally would have
deleted live features.

**Deleted -- the link-stripping decision, and the whole legacy link wire format:**

| Gone | Why it existed |
| --- | --- |
| `StripDeltaLinks`, `Guild:StripDeltaLinks` | Guessing whether a link was safe to drop before sending |
| `Item:NeedsLink` | The send-side half of that guess; `StripDeltaLinks` was its only caller |
| `ComputeDelta`, `ComputeItemDelta`, `BuildItemIndex`, `ItemsEqual`, `GetChangedFields`, `DeltaHasChanges` | Computing a link-keyed delta |
| `ApplyDelta`, `ApplyItemDelta` | Applying one, with the `ITEM-003` ghost guards |
| `ValidateDeltaStructure`, `ValidateItemDelta`, `Core:ValidateDeltaStructure` | Validating the `alt-delta` envelope |
| Seven `Guild:` wrappers delegating to the above | -- |
| `Modules/Tests.lua` and `/togbank test` | An in-game harness written entirely against those functions |

**KEPT, and deleting these removes FEATURES rather than complexity:**

| Kept | Why it is NOT wire code |
| --- | --- |
| `Item:GetSuffixID` | Four live consumers read **client** links: bank scanning, mail fulfilment matching, search, request matching |
| `Item:GetItemString` | Backs `MailInventory` |
| `Item:GetItemKey` | Still used by `Item:GetItems` aggregation for the legacy store |
| `Item:ItemClassNeedsLink` | The **receive-side** check, still used by `PurgeLinklessGearGhosts` |
| `Database:PurgeLinklessGearGhosts` | Repairs damage **already in players' SavedVariables**; runs at load |
| `Item:GetItems`' async fan-in, `Item:Sort`'s `reqLevel` retries | Still reached; pending `INV2-IDB-002` |

---

## 9. Risks

| Risk | Mitigation |
| --- | --- |
| IDB can't resolve an id | Three-step fallback; never blank, never an error. Unresolved ids logged for DB top-up |
| Era realms miss high-ID items | `INV2-IDB-001` — must be fixed upstream before default-on |
| Empty DB after flip | Accepted. Log bankers in to re-ingest |
| Rollback lands on stale data | `dualWrite` keeps the legacy DB current (§6.1) |
| Two writes diverge silently | Both written from one scan; `/togbank dev compare` diffs them. Divergence is a bug to investigate, never to paper over |
| Mixed-version guild | **SUPERSEDED 2026-09-09.** There is NO backwards compatibility on the wire, in either direction: an unmigrated peer can neither read us nor be read by us. An upgraded member sees nothing from un-upgraded bankers until they upgrade, and it heals by itself. `sendV2Wire` is no longer a rollback -- with it off there is no send path at all |
| Enchants lost | Carried explicitly in the tuple. `IDB:BuildItemString` hardcodes fields 2–6 empty and needs an enchant parameter — library change |
| TBC gems lost | **Unresolved.** Out of scope for Vanilla; must be decided before TBC |
| View cache goes stale | Invalidate on write; spec the invalidation, don't assume it |

---

## 10. Open questions

1. **Numeric vs string key** (§3.2) — string proposed; profile before changing.
2. **TBC gems** (§3.3) — carry four more optional fields, or accept the loss? Must be answered
   before TBC, not before Vanilla.
3. **Requests** — confirmed as a follow-up, but worth deciding whether they share `Record.lua`
   or get their own encoding.
4. **`/togbank dev compare` output** — how much detail? Per-alt totals are enough to spot a
   miscount; per-item divergence is what you'd need to diagnose one. Suggest summary by default,
   `verbose` argument for the full list.

*Resolved:* `dualWrite` — **in**, default on, see §6.1.

*Resolved 2026-09-08:* **icons are NOT persisted to SavedVariables.** Raised after `RESOLVE-001`,
when the icon lookup moved into `Resolve.describe`: should the resolved fileID be stored alongside
the tuple instead of looked up?

**No, and the reasoning is this document's own.** An icon is derivable from the item ID, which the
tuple already carries, so persisting it keeps a second copy of a recomputable value -- exactly the
practice section 8 deletes rather than a new case. It can also go **stale**: Blizzard changes icons
in patches and nothing would invalidate a stored one, whereas a session memo is rebuilt from the
current client every login. It costs the very thing the tuple format is shrinking, since
SavedVariables are serialised Lua read at login and written at logout. And it would not help the
case that motivates the question: whether the client knows an item's static data is a property of
the **client build**, not of the session, so a fileID stored last session cannot rescue an id this
client cannot resolve.

The memo in `Resolve` is the right level -- session-scoped, derived, never stale, one lookup per
distinct id, and a table read thereafter. **Anything else that is a pure function of item ID
belongs there too, not in the store.**

---

## 11. Sequence

1. ~~Agree this document.~~ **Done.**
2. ~~`Modules/Switches.lua` + `Record.lua` + `Resolve.lua`, with specs.~~ **Done** — 100% line
   coverage on each, verified with `lua Tests/wowapi/coverage.lua <file> Tests/*_spec.lua`.
3. ~~`Store.lua` + `Scan.lua` behind `inventoryV2`, off by default.~~ **Done**, 100% each.
4. ~~`Wire.lua` + receive-side dual-format support, emission behind `sendV2Wire`.~~ **Done**, 100%.
5. **Wire it up — write side only (`INV2-WIRE-001`). Done.** `Bank:Scan` mirrors into the V2
   store behind `inventoryV2`; `Core:OnInitialize` attaches `TOGBankClassicInvDB`;
   `/togbank dev switches` and `/togbank dev compare` exist. Nothing *reads* V2 yet, so the
   addon's behaviour is unchanged in both switch positions. See the deviation note in §6.1.
6. ~~Live test on a banker: `inventoryV2` on, open bags + bank, `/togbank dev compare`.~~
   **Done, 2026-09-08** -- *"Compared 1 character(s) present in both stores. No divergence. Every
   item total agrees."* First evidence the two encodings agree on real data. Note the instruction
   above was wrong and is corrected elsewhere: the scan fires when the bank **closes**
   (`BANKFRAME_CLOSED`), not when it opens, and bags alone trigger nothing (`DOC-005`). What this
   proves is bounded: **one** character, on **per-item-ID totals** rather than rows, so
   suffix/enchant fidelity is not what was measured, and `sendV2Wire` was off throughout.

7. **7a done, 2026-09-08.** The UI reads through `Guild:GetAltItems`, which is the single place
   the `inventoryV2` switch chooses a source; the per-alt view cache and its invalidation are
   specced rather than assumed. With `inventoryV2` on but an alt absent from V2, it falls back to
   the legacy record -- required during `dualWrite`, when only the local character is in V2 and
   the rest of the guild still arrives over the legacy wire. 7b (route sends through `Wire` behind
   `sendV2Wire`) is next.
7. Point the UI at `Store:GetAltView` behind the switch (§7.1), then route sends through `Wire`
   behind `sendV2Wire`.
8. Fix `INV2-IDB-001` and `INV2-IDB-002` in ItemDB.
9. Default the switches on, only after 6 and 7 are green on a real guild.
10. Delete the superseded code (§8) as its own commit, once green.
11. **Re-measure bandwidth and restore the figures to the CurseForge page.**

### 11.1 `INV2-DOC-001` — bandwidth claims pulled pending measurement

`docs/Curseforge_Description.html` previously advertised "90-99% bandwidth reduction" and "1-10%
of bandwidth compared to full snapshots". Those were removed in the v1.3.2 page sweep because
they describe protocol internals that are mid-rework and could not be verified against current
behaviour.

This is **temporary and should not be left to lapse** — the page now understates the addon.
Once the tuple wire format lands, measure it properly and put real figures back. The expectation
is that they improve: the tuple change is ~80-85% off item payloads *on its own*, and it
compounds with delta sync rather than competing with it.

Measure against a real guild, not a synthetic payload, and state what was measured.
