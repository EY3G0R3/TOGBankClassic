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

Not "fixes" — deletes, because the conditions that made them necessary stop existing:

| Going away | Why it existed |
| --- | --- |
| `Item:GetItemKey`, `GetItemString`, `GetSuffixID` | String identity |
| `NeedsLink`, `ItemClassNeedsLink`, `ForceLink` | Deciding whether a link was safe to strip |
| `StripItemLinks`, `StripDeltaLinks` | Stripping links for bandwidth |
| `PurgeLinklessGearGhosts` | Cleaning up damage from the above |
| Most of `Item:GetItems`' async fan-in (`ITEM-005`) | Cold client cache; IDB is never cold |
| `Item:Sort`'s `reqLevel` retry loops (`SORT-002/003`) | Same — pending `INV2-IDB-002` |

---

## 9. Risks

| Risk | Mitigation |
| --- | --- |
| IDB can't resolve an id | Three-step fallback; never blank, never an error. Unresolved ids logged for DB top-up |
| Era realms miss high-ID items | `INV2-IDB-001` — must be fixed upstream before default-on |
| Empty DB after flip | Accepted. Log bankers in to re-ingest |
| Rollback lands on stale data | `dualWrite` keeps the legacy DB current (§6.1) |
| Two writes diverge silently | Both written from one scan; `/togbank dev compare` diffs them. Divergence is a bug to investigate, never to paper over |
| Mixed-version guild | Receive always accepts both formats; `sendV2Wire` gates emission |
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

---

## 11. Sequence

1. Agree this document.
2. `Modules/Switches.lua` + `Record.lua` + `Resolve.lua`, with specs. Pure logic, no I/O —
   should reach near-100% coverage, unlike the 18% retrofit on `Guild.lua`.
3. `Store.lua` + `Scan.lua` behind `inventoryV2`, off by default.
4. `Wire.lua` + receive-side dual-format support, emission behind `sendV2Wire`.
5. Fix `INV2-IDB-001` and `INV2-IDB-002` in ItemDB.
6. Live test with switches on. Default them on only after that.
7. Delete the superseded code (§8) as its own commit, once green.
8. **Re-measure bandwidth and restore the figures to the CurseForge page.**

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
