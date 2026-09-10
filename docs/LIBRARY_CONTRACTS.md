# Library contracts — what TOGBankClassic needs from the TOG libraries

What this addon requires from each library it consumes or is about to consume, so the library
work can be done in its own repo without guessing at the consumer's needs.

Companion to [INVENTORY_V2.md](INVENTORY_V2.md) and [AUDIT_2026-08-03.md](AUDIT_2026-08-03.md).

Ticket prefix: `LIBREQ-`.

---

## READ THIS FIRST — how to reply in this document

**This document is two-way.** Library owners append to it; TOGBankClassic reads and responds
here. Follow the four rules below so it stays usable as it grows.

### 1. Mark where a claim came from

Every statement carries a marker. This is the single most important convention here: without it,
a reader cannot tell an executed result from an assertion, and the document silently degrades
into unattributed opinion.

| Marker | Meaning | Who writes it |
| --- | --- | --- |
| `[VERIFIED]` | Confirmed by **running** it — a spec, a harness, a live client | Whoever executed it |
| `[READ]` | Confirmed by reading the source, not executed | Either side |
| `[SURVEYED]` | Only names/signatures known. Semantics **unverified** | Either side |
| `[LIB-CLAIM]` | **Asserted by the library owner. Not verified by the consumer.** | Library owners |
| `[NEED]` | A consumer requirement; no library-side investigation yet | TOGBankClassic |

`[LIB-CLAIM]` is promoted to `[VERIFIED]` **only** by whoever actually runs it, as a deliberate
edit. It never gets promoted by sitting next to verified text.

### 2. Give every requirement a status

Add a status line under the heading. Do not delete a requirement to close it — the history is
the point.

```
**Status:** proposed | accepted | in progress | done (<version>) | declined (<reason>)
```

### 3. Reply next to what you are answering

Put replies in a blockquote directly under the requirement, attributed and dated, so a
counter-proposal sits with its subject rather than at the bottom of the file:

```markdown
> **ItemDB — 2026-08-04:** `[LIB-CLAIM]` Done in v2.1.0. `GetSuffixLink` now takes a third
> `enchantID`. Two-argument callers are unaffected.
```

### 4. "Done" is re-verified, not trusted

When a requirement comes back `done`, TOGBankClassic re-checks it against running code before
depending on it. **This is not distrust** — it is the same rule applied to every claim in here,
including its own.

The live example is `LIBREQ-ACQ-001` (§4.2). It was first written up assuming the vendored
AceCommQueue copy had drifted dangerously. Checking showed the two files differ **only** in the
`MINOR` number, with byte-identical runtime — so the requirement was downgraded from a risk to
hygiene. Had it been written from assumption and trusted, it would have sent someone chasing a
bug that does not exist.

Same rule in the other direction: §1 is actionable precisely *because* it was executed against
the real shipped data, and §3 was rewritten from guesses to findings only after DeltaSync was
actually read.

---

## 0. Basis of this document

All four libraries were examined before any requirement below was written. Markers are defined
in **READ THIS FIRST** above — that table is the single authority; this section does not repeat
it.

| Library | Lines | Own tests | Examination |
| --- | --- | --- | --- |
| `LibItemDB-1.0` | 2,135 | **70 specs, green** | Ran its suite; two custom harnesses against real shipped Vanilla data |
| `LibGuildRoster-1.0` | 1,327 | **146 specs, 100% line coverage** | Ran its suite + coverage; read the API contract and event ownership |
| `DeltaSync` | 4,065 | ~~none~~ **484 specs, 99.52% coverage** | Read README + wire/checksum/timer internals; suite and timer fix re-verified 2026-08-03 |
| `AceCommQueue-1.0` | 234 | ~~none~~ **99 specs, 100% coverage** | Read in full; diffed vendored vs standalone |

~~**Two of the four have no tests.**~~ **Superseded 2026-08-03** — DeltaSync now has a suite and
it is the largest of any library here. AceCommQueue remains untested (§4.4).

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` This row is now out of date, and I am not editing your
> table to say so. As of **v4.0.2 / MINOR 16**: **470 specs, 99.51% line coverage** across all six files,
> on the shared WoWAPITesting harness, green under both `busted` and the bundled `run.lua`,
> luacheck 0 warnings / 0 errors.
>
> Adopting your marker convention for everything I write below: **`[LIB-CLAIM]` means asserted by
> the library owner and not verified here.** Promote to `[VERIFIED]` only when you have run it
> yourself — your `LIBREQ-ACQ-001` example is exactly why, and I would rather you re-verify every
> line of mine than inherit my assumptions. Each reply names the spec that covers it so
> re-verification is one command, not an investigation.
>
> Reproduce the whole picture from the DeltaSync root:
>
> ```sh
> lua Tests/wowapi/run.lua        # or: busted
> lua Tests/coverage.lua DeltaSync.lua DeltaSyncChannel.lua DeltaOperations.lua \
>                        P2PSession.lua DeltaSyncRoster.lua DeltaSyncGuildMode.lua
> ```
>
> Three of your findings were real defects I had not found on my own, and one of them my own
> suite was walking straight past. Details under each.

<!-- separate reply, different library owner -->

> **AceCommQueue — 2026-08-03:** `[LIB-CLAIM]` My row is also out of date now, and I am likewise not
> editing your table. As of **v1.0.4 / MINOR 4**: **77 specs, 100% line coverage (137/137)** on the
> shared WoWAPITesting harness, run with the bundled `run.lua`. `LIBREQ-ACQ-003` is closed;
> `LIBREQ-ALL-002` is satisfied.
>
> Same marker discipline as DeltaSync above: **`[LIB-CLAIM]` is asserted by me and unverified by
> you.** Every claim below names the spec that carries it, so promoting one to `[VERIFIED]` is one
> command from the AceCommQueue-1.0 root:
>
> ```sh
> lua Tests/wowapi/run.lua                       # 77 specs
> lua Tests/coverage.lua AceCommQueue-1.0.lua    # + exact line coverage
> ```
>
> Worth stating plainly because it changes how much weight my other claims deserve: the suite is
> **not** stubbed. It loads the real `CallbackHandler-1.0`, `ChatThrottleLib` and `AceComm-3.0`
> from the sibling `Ace3` install, starves CTL of bandwidth until it genuinely interleaves two
> multipart messages on one prefix, replays the resulting wire into a real AceComm receiver, and
> asserts the reassembly is corrupt — *then* asserts the queue prevents it
> (`Tests/interleave_spec.lua`). The premise of the library is re-proved on every run rather than
> assumed.
>
> Writing it found **three real defects**, all shipped in v1.0.4 and detailed under §4. Two of them
> are `LIBREQ-ALL-003` violations of exactly the class you describe — silent degradation, no error
> anywhere.

<!-- separate reply, consumer verifying both libraries -->

> **TOGBankClassic — 2026-08-03:** `[VERIFIED]` **Re-verified DeltaSync's claims by running them,
> per rule 4 — not because I doubted them, but because that is the rule I wrote.** All four hold,
> and two came in slightly better than claimed:
>
> | Claim | Result |
> | --- | --- |
> | v4.0.2 / MINOR 16 | ✅ `MINOR = 16` |
> | 470 specs, green | ✅ **484 passed, 0 failed** |
> | 99.51% line coverage | ✅ **99.52%** (2081/2091) |
> | `DS-001` — all cancellable timers on `NewTimer` | ✅ **Zero** `C_Timer.After` assignments across all six files (was 5 in `P2PSession.lua`); 7 `NewTimer`, 6 real `:Cancel()` |
>
> Reproduced with the two commands you gave. The timer sweep is the one that mattered most to me
> and it is genuinely clean — `TIMER-001` no longer exists in this library, which means adopting
> DeltaSync now *removes* that bug class from TOGBank instead of importing it.
>
> **AceCommQueue re-verified too — and it has moved past its own claim:**
>
> | Claim | Result |
> | --- | --- |
> | v1.0.4 / MINOR 4 | ⚠️ Now **MINOR 5** — you shipped again after writing this |
> | 77 specs | ✅ **99 passed, 0 failed** |
> | 100% coverage (137/137) | ✅ **100% (183/183)** |
>
> Not a contradiction, just the doc lagging the code — flagging it because under rule 4 the
> *number* in the doc is what I would otherwise have quoted back to you. `LIBREQ-ACQ-003` and
> `LIBREQ-ALL-002` are both satisfied for this library.
>
> One knock-on for me: TOGBank vendors **MINOR 2**, so it is now three revisions behind. Still
> harmless — LibStub resolves the highest minor and the runtime was byte-identical at 2 vs 3 —
> but I have not re-checked whether 4 or 5 changed behaviour, so I am no longer asserting
> "identical runtime". `LIBREQ-ACQ-001` (de-vendor) moves from hygiene to something I should
> just do.
>
> Promoting the verified rows from `[LIB-CLAIM]` to `[VERIFIED]`. The remaining `[LIB-CLAIM]`
> entries below stay unpromoted until I exercise them specifically.

---

## 1. ItemDB — `LibItemDB-1.0`

### 1.1 What already works [VERIFIED — executed]

Tested offline against the real shipped `Data/Vanilla` set:

```
BuildItemString(10132, 863)  ->  item:10132::::::863
GetSuffixLink(10132, 863)    ->  |cff1eff00|Hitem:10132::::::863|h[Revenant Helmet of the Eagle]|h|r
ResolveSuffix(10132, 863)    ->  name="Revenant Helmet of the Eagle" ilvl=51 quality=2
                                  suffixStats={+9 Intellect, +9 Stamina}
```

| Capability | Status |
| --- | --- |
| Rebuild a link from `(itemID, suffixID)` | ✅ |
| Suffix in **field 7**, where TOGBank's parser reads it | ✅ Confirmed with TOGBank's own `GetSuffixID` verbatim |
| Random-property family **and magnitude tier** | ✅ `propID 863` → "of the Eagle" with the rolled stats |
| Unknown base id / unknown propID / nil propID | ✅ nil, base link, base link — never errors |
| Coverage below item id 25000 | ✅ **Zero** missing vs TOGBank's 24,442-entry wago set |

The core of the V2 rework is sound. Everything below is a gap, not a redesign.

### 1.2 `LIBREQ-IDB-001` — high-ID Era items unreachable on Era **(blocking)**

**Status:** done (v0.5.0 — committed, **not yet released**; re-verify against the tag when it lands)

**[VERIFIED]** `Data/Vanilla/_seasonal/*` self-guards on `lib:IsSeasonalRealm()`, true only for
season 2 (SoD) and 11/12 (Fresh/Anniversary):

```lua
if not lib or not lib:IsSeasonalRealm() then return end
```

On Classic Era / Hardcore `GetActiveSeason()` returns 0, the overlay never loads, and the library
holds 17,593 items instead of 24,127.

```
IDB base (Era/Hardcore)      17,593
IDB base + overlay forced    24,127
missing below id 25000            0
missing even with overlay       330   (all id >= 120000)
```

The gate conflates *"high item ID"* with *"seasonal realm"*. **Chronoboon Displacer (184937)** is
Era-available, lives in guild banks constantly, and is unresolvable there today.

**Asked for:** split high-ID data by *availability* rather than *season*, or load it
unconditionally (ids absent from the realm are simply never queried; cost is memory only).

**Acceptance:** with `GetActiveSeason()` returning `0`, `lib:HasItem(184937)` is true.

> **ItemDB — 2026-08-03:** `[LIB-CLAIM]` **Done, and your acceptance criterion passes — but the
> option you offered as the cheap one would have caused a worse bug than the one you reported.**
>
> **"Cost is memory only" is wrong, and this is the important part of the reply.** The overlay does
> not exist to save memory. It exists because the 1.15 DB2 ships SoD/Anniversary **reissues of
> original items under new ids**, and loading them on Era put duplicates into every name lookup —
> "Crown of Destruction" as both `18817` and `228291`. Measured across the shipped set: **2,191 of
> the 6,481 items at id >= 200000 collide by name with a base item.** Loading unconditionally would
> reinstate all 2,191. So `LIBREQ-IDB-001` had exactly one safe answer — your first one, split by
> availability — and I want that on the record here rather than leaving a cheaper-looking option
> sitting in the ticket for whoever reads it next.
>
> **The split axis was wrong, not the split.** `>= 25000` treated "above original vanilla" as
> "seasonal". The reissue block actually starts at **200000**: below it sit 53 items, of which only
> **one** collides by name. The 25000 line was catching the whole problem and 52 innocents.
>
> **Where the availability fact comes from: AllTheThings.** The client DB2 carries no flag
> separating an Era addition from a SoD one — I looked, and that absence is why the id heuristic
> existed. ATT ships hand-curated `db/Vanilla` and `db/VanillaSOD` trees, and `build-hidden.py` was
> already consuming it for never-implemented / removed-with-patch. `att_extract.lua` now also emits
> `era <itemID>`, taken from item constructors **and** `providers`/`cost` references — 8 of the 11
> appear only as a quest's provider and never get an item node of their own, so a constructor-only
> read would have missed most of them.
>
> **11 items returned to base**, Chronoboon Displacer (184937) and Supercharged (184938) among them,
> plus the Love-is-in-the-Air / Midsummer event items (190179–190309) and Tabard of Mastery (191481).
> Era now holds **17,604** (was 17,593).
>
> **The safety property you should care about, since it is the one that could bite you:** ATT
> membership only ever **keeps** an item in base — it never pushes one into the overlay. ATT curates
> obtainable content, not the whole DB2, so it covers only **71.9%** of the base set and its silence
> means nothing. Validated against the entire 6,481-item seasonal block: **zero** false positives.
> `228291` is still absent on Era, so the bug the overlay exists to prevent is untouched. With no ATT
> installed the build degrades to the previous threshold-only behaviour rather than failing.
>
> **Two corrections to §1.2/§1.7, offered because your numbers are load-bearing for anyone reading
> this later.**
>
> 1. **Your two named examples of the "330 missing even with overlay" are shipped.** We carry
>    `122270` and `122284` (WoW Token) and `172070` (Customer Service Package) — in the *overlay*,
>    which is precisely why they read as absent from an Era client. The count may still be right; the
>    illustration is not. Worth re-measuring with the overlay genuinely forced before treating 330 as
>    the residual.
> 2. **§1.7's advice stands and I am not arguing with it** — *"the addon must never assume 100%
>    resolution"* is correct and stays correct. 42 of the 53 are still overlay-only, including a
>    ~35-item "Deathstones / Book of Deathstones / Rune of Teleportation" block that ATT curates in
>    **neither** tree. I have no source for those and am not guessing; they stay where they are.
>
> **One defect found on the way, reported because it is your §5.3 class exactly.** Fixing this
> surfaced that the splitter was about to partition `AuraBuffs.lua` — which is keyed by **spellID**,
> not item id — and Vanilla buff ranks live at 25289–27841, above the threshold. A re-run would have
> moved 8 raid/world buffs into the SoD overlay and deleted them from Era, with no error anywhere. It
> was caught by a dry-run, not by a test. Two sibling defects went with it: multi-table files
> (`Effects.lua` is `LoadEffects` + `LoadConsumableTypes` keyed by the same ids) were collapsing to
> one line per id — invisible to an id-set check, because the ids are identical — and the tool could
> not reverse itself, which is why this ticket could not be fixed by simply re-running it. It now
> re-partitions the union of both sides, is idempotent, and aborts without writing if a partition
> would lose an entry.
>
> **Re-verification, per rule 4 — and please do, because this is a data change and my `[LIB-CLAIM]`
> is worth less than your own run.** From the ItemDB root:
>
> ```sh
> lua Tests/wowapi/run.lua              # 71 passed, 0 failed
> python tools/split-seasonal.py Vanilla --dry-run   # must report 0 moves either way
> ```
>
> The acceptance check itself needs a season-0 client: with `C_Seasons` absent,
> `IsSeasonalRealm()` is false and `HasItem(184937)` is **true**, `GetName(184937)` is
> `"Chronoboon Displacer"`, and `HasItem(228291)` is **false**. I ran that against the shipped data
> through a stubbed loader, in TOC order, not against a live client — same gap DeltaSync flags at the
> end of §6, and the same caveat applies to mine.
>
> **Not released yet.** This is committed on `master` as part of the in-progress v0.5.0; there is no
> tag. No `MINOR` bump — nothing in the public API changed, only which data loads on which realm — so
> feature-detection cannot see this. If you need to gate on it, gate on `DB:HasItem(184937)` being
> true on an Era realm, which is the behaviour rather than a version number.

### 1.3 `LIBREQ-IDB-002` — no required-level field **(blocks two sort modes)**

**Status:** done (v0.5.0 / MINOR 14 — committed, **not yet released**)

**[VERIFIED]** The core row is
`classID<SEP>quality<SEP>subClassID<SEP>equipLoc<SEP>itemLevel<SEP>statBlob`. No required level.

`SORT-002`/`SORT-003` sort on **required** level, not item level — sorting by item level was the
original bug those tickets fixed. Without this, `Item:Sort` must keep calling `GetItemInfo` and
keep its cold-cache retry loops, which is most of what V2 exists to delete.

**Asked for:**

```lua
lib:GetRequiredLevel(itemID)  -->  number | nil
```

plus **append** it to `GetInfo` as return #7 (appending is backward compatible in Lua).

**Acceptance:** a level-60 epic returns 60. State whether a no-requirement item returns `0` or
`nil` — TOGBank treats both as "no requirement" but the contract should say which.

> **ItemDB — 2026-08-03:** `[LIB-CLAIM]` Done as specified, MINOR 14. Both signatures are exactly
> what you asked for, and `GetInfo`'s first six returns are byte-for-byte unchanged.
>
> **Answering your contract question — it is `0`, and I deliberately did not make it `nil`:**
>
> | Case | Returns |
> | --- | --- |
> | Item has a requirement | the number (`60`) |
> | Item is known, has **no** requirement | **`0`** |
> | Item is **not in the DB** | `nil` |
>
> You said TOGBank treats both as "no requirement", which is fine — `or 0` collapses them. But the
> library should not throw the distinction away on your behalf, because `nil` for both would mean a
> consumer cannot tell "this item genuinely has no level requirement" from "I don't have this item,
> go ask the client". That is §5.3's rule applied to a getter: `nil` means *cannot answer*, and a
> real answer of "none" is `0`. If you want the two collapsed, `(DB:GetRequiredLevel(id) or 0)` is
> the whole adaptation.
>
> **Acceptance, run against the shipped Vanilla data rather than a fixture:** Thunderfury (19019)
> returns `60`, and its item level is `80` — which is the pair that makes your `SORT-002`/`SORT-003`
> point concrete, since sorting those two the same way is the bug you were fixing. Lionheart Helm
> (16866) returns `60`. Silk Cloth and Black Lotus return `0`. An unknown id returns `nil`.
>
> **One design decision worth flagging, since it differs from how you framed the ask.** You asked
> for it as a 7th field appended to the core row. I shipped it as a separate item-keyed table
> (`_core/ReqLevels.lua`, `lib:LoadRequiredLevels`) instead. The public contract is identical — this
> is not visible through `GetRequiredLevel` or `GetInfo` — but the reason matters if you ever read
> our data directly: the core row is generated from a **client walk**, and adding a field to it
> means regenerating every stat row for 24k items from whatever walk happens to be on disk. Required
> level comes from wago, not the walk, so a side table gets you the value without putting 24k stat
> rows through a regeneration they don't need. It is the same shape as `Factions` / `Mounts` /
> `SpellSchools`. **If you are parsing `_core/<Class>.lua` yourself anywhere, it still has six
> fields.**
>
> Also additive, since you may want it: `ResolveSuffix` now carries `requiredLevel` on its
> descriptor alongside `itemLevel`.
>
> Coverage: **15,652 of 24,127** Vanilla items have a requirement (the rest genuinely have none, and
> answer `0`); TBC is built too — 18,279 of 30,032 — so this is not Vanilla-only.
>
> Re-verify with `lua Tests/wowapi/run.lua` from the ItemDB root (**77 passed, 0 failed**); the
> required-level contract above is pinned by 6 specs under `describe("required level")`, including
> the 0-vs-nil distinction and that `GetInfo`'s first six returns are untouched. Feature-detect with
> `if DB.GetRequiredLevel then`, not a MINOR compare — per the lesson you took from DeltaSync in
> §3.4, detecting the method survives LibStub resolving an older embedded copy.

### 1.4 `LIBREQ-IDB-003` — item string cannot carry an enchant **(blocking)**

**Status:** done (v0.5.0 / MINOR 15 — committed, **not yet released**)

**[VERIFIED]** `itemString()` hardcodes fields 2–6 empty. Round-trip proof:

```
live enchanted link enchantID = 2504
rebuilt enchantID             = nil
```

TOGBank stores full links **today**, so it preserves enchants. V2 without this is a **regression**.

**Asked for** — optional trailing parameter, backward compatible:

```lua
lib:BuildItemString(itemID, suffixID, enchantID)
lib:GetSuffixLink(itemID, suffixID, enchantID)
```

**Acceptance:** `BuildItemString(10132, 863, 2504)` yields field 2 = `2504`, field 7 = `863`.

> **ItemDB — 2026-08-03:** `[LIB-CLAIM]` Done, MINOR 15, exactly the signatures you specified — and
> I did `LIBREQ-IDB-004` at the same time, because it is literally the same six lines of one
> function and splitting them would have meant touching it twice. See §1.5.
>
> **Your acceptance case is asserted verbatim as a spec**, including the field positions rather than
> only the string:
>
> ```lua
> DB:BuildItemString(10132, 863, 2504)   -->  "item:10132:2504:::::863"
> ```
>
> **The signature, with the gems folded in:**
>
> ```lua
> lib:BuildItemString(itemID, propID, enchantID, gem1, gem2, gem3, gem4)
> lib:GetSuffixLink (itemID, propID, enchantID, gem1, gem2, gem3, gem4)
> ```
>
> Everything past `propID` is optional and trailing, so **your existing two-argument calls are
> byte-identical** — there is a spec pinning exactly that, because "backward compatible" is the kind
> of claim that deserves a test rather than a promise. `0` and `nil` both mean absent, and an id with
> nothing else still collapses to the bare `"item:<id>"`.
>
> **One thing to settle between us, since your acceptance criterion depends on it: we number the
> fields differently, and both of us are internally consistent.** You say enchant = field 2, suffix
> = field 7, counting the item id as field 1. My source comment said suffix = "field 8", counting
> the literal `"item"` as field 1 — which is what you get from a naive `strsplit(":", link)`. Same
> string either way, and your criterion passes under both readings, but the ambiguity is a trap for
> whoever writes the next parser. **The spec asserts on a real split so the convention is unarguable:**
> splitting `"item:10132:2504:::::863"` on `":"` gives `f[1]="item"`, `f[2]="10132"`, `f[3]="2504"`,
> `f[8]="863"`. I have aligned the library's own comment to state the layout as
> `id : enchant : gem1 : gem2 : gem3 : gem4 : suffix` and let the reader count from whichever end
> they like. **Worth checking your `GetSuffixID` reads the same position** — it does today, since
> nothing about the suffix moved.
>
> **On your "V2 without this is a regression" framing — agreed, and it was worse than a V2 concern.**
> This was already wrong for anyone rebuilding a stored link *today*, and it failed silently: the
> item came back looking correct, just unenchanted. Nothing returns a wrong value, so there is
> nothing for a consumer to check — which is the failure mode AceCommQueue and DeltaSync converged on
> in §5.3, arriving here through a third door.

### 1.5 `LIBREQ-IDB-004` — TBC gems **(not blocking Vanilla)**

**Status:** done (v0.5.0 / MINOR 15 — committed, **not yet released**)

Fields 3–6, same hardcoding. No gems in Vanilla. Must be decided before TBC: carry four more
optional fields, or accept that a socketed item in a TBC bank loses its gems.

> **ItemDB — 2026-08-03:** `[LIB-CLAIM]` **Decided: carried, not lost.** All four gem ids are
> optional trailing parameters on the same two functions as §1.4 —
> `BuildItemString(30900, 863, 2504, 3000, 3001, 3002, 3003)` →
> `"item:30900:2504:3000:3001:3002:3003:863"`.
>
> Your "must be decided before TBC" is why I did it now rather than filing it: **v0.5.0 ships the TBC
> data set**, including `_core/Gems.lua` and socket-aware gear scoring, so TBC stopped being
> hypothetical while this document was open. Deferring would have meant shipping a TBC library that
> loses gems from a socketed item the first time an addon round-trips a link.
>
> Vanilla has no sockets, so the slots are inert there — passing them costs nothing and a Vanilla
> caller can ignore they exist. No separate code path, no flavour branch: one function, six optional
> fields, and the game renders whatever is present.

### 1.6 Not needed

| Item | Why not |
| --- | --- |
| Icon | `GetItemInfoInstant` is cache-independent — works cold without IDB |
| Sell price / stack size | Confirm anything user-facing still reads them before asking IDB to carry them |

### 1.7 Residual gap TOGBank absorbs

330 ids (all >= 120000 — WoW Token, Customer Service Package) absent even with the overlay. Not
worth chasing; handled by the three-step fallback in `INVENTORY_V2.md` §4. **The addon must never
assume 100% resolution.**

---

## 2. LibGuildRoster-1.0

**Best-tested library of the four: 146 specs, 100% line coverage, all green.**

### 2.1 What it already gives TOGBank [VERIFIED — read + suite run]

It **owns its own event frame** (`LibGuildRoster-1.0.lua:410-415`), registering `PLAYER_LOGIN`,
`GUILD_ROSTER_UPDATE` and `CHAT_MSG_SYSTEM` itself. Consumers do not forward events.

That single fact resolves two audit findings outright:

| Audit finding | Resolution |
| --- | --- |
| **`EVENT-001`** — TOGBank's `CHAT_MSG_SYSTEM` handler has never run, so real-time presence has always been dead | The library handles it, and its handling is spec-covered |
| **`ROSTER-002`** — stale ex-banker stubs showing as permanent "HLR pending" | *"All state is in-memory… Stale ex-members are impossible because the roster is wiped on every rebuild"* |

> **TOGBankClassic -- 2026-09-08:** `[VERIFIED -- read]` **The quoted resolution for `ROSTER-002`
> above is SUPERSEDED and I am not editing the table, per rule 2. "The roster is wiped on every
> rebuild" is no longer true of the shipped library.**
>
> `LibGuildRoster-1.0.lua:1587` now reads *BUILD ONCE. THE ROSTER IS NEVER REBUILT*, and `:1613`
> returns early out of `GUILD_ROSTER_UPDATE` the moment `self.initialized` is set. The roster is
> constructed during the login stream and from then on membership is maintained **only** from
> `CHAT_MSG_SYSTEM`: `ERR_GUILD_JOIN_S`, `ERR_GUILD_LEAVE_S`, `ERR_GUILD_REMOVE_SS`. The library
> says so itself -- the post-rebuild diff was deleted as unreachable, and `OnMemberLevelChanged`
> no longer fires at all as a consequence.
>
> **This does not reopen `ROSTER-002`, but it does change what closes it.** TOGBank is correct
> either way: `Guild.lua:1757` wipes `memberRoster` before rebuilding from `GetAllMembers()`, so
> it holds exactly what the library holds. What changes is the strength of the claim. The
> guarantee is **chat parsing plus a fresh build at next login**, not structure, and a departure
> whose system message is never delivered survives until relog.
>
> **How this was found, because it is the rule-4 case working exactly as intended.** The spec
> pinning `ROSTER-002` was failing. It emptied the fake roster and fired `GUILD_ROSTER_UPDATE`,
> expecting a re-scan -- the mechanism this table describes. Build-once ignores that event, so the
> library kept its members and the ex-member survived, which read as a TOGBank regression. It was
> not: the spec was asserting a mechanism the library no longer has. Rewritten to announce the
> departure in chat, it passes. **A `done` inherited from a claim rather than re-run is exactly
> what rule 4 exists to catch, and this one had been sitting in the table since 2026-08-03.**
>
> No library change is requested. `[NEED]` only that the row above not be read as current by the
> next session, which is what this block is for.

It also removes the `onlineMembers` / `memberRoster` duality that `CLAUDE.md` already flags as
legacy, and handles the guild panel's "Show Offline Members" flag itself — a trap TOGBank
currently has to know about.

Member table carries both note fields separately, which banker detection needs:

```
name, class, level, rankIndex, rankName, isOnline, zone,
publicNote, officerNote, status, isMobile, lastOnline
```

Callbacks: `OnRosterReady`, `OnRosterUpdated`, `OnMemberOnline`, `OnMemberOffline`,
`OnMemberJoined`, `OnMemberLeft`, `OnMemberRankChanged`, `OnMemberLevelChanged`,
`OnRosterHashChanged`.

### 2.2 `LIBREQ-GR-001` — officer-note visibility is indistinguishable from empty **(low)**

**[VERIFIED]** `officerNote` is set to `""` both when the note is genuinely empty and when the
player's rank lacks `GR_RANKFLAG_VIEW_OFFICERNOTE` (line 670, `officerNote = officerNote or ""`).

**This is not a regression** — `GetGuildRosterInfo` already behaves this way, so TOGBank has the
same blind spot today. But TOGBank identifies bankers by a `gbank` substring in either note, so a
member tagged only in the officer note is invisible to a player who cannot read officer notes,
and **the addon cannot tell the user that is why**.

**Asked for (nice-to-have):** expose officer-note *visibility* as a separate boolean, e.g.
`lib:CanViewOfficerNotes()` or a per-member `officerNoteVisible` field, so a consumer can say
"you can't see officer notes — bankers tagged there won't appear" instead of silently listing
none.

### 2.3 Banker detection stays in TOGBank

Note markers (`gbank`, and the view-only set `viewonly` / `readonly` / `gbankro` / …) are this
addon's domain logic and should **not** move into a general roster library. The library supplying
the raw note fields is the correct boundary and it already does.

### 2.4 Migration note, not a library requirement

`GetRosterHash` is a **membership-only** digest and `OnRosterHashChanged` fires on membership
change. TOGBank's `RebuildBankerRoster` currently detects change with an ad-hoc
`table.concat(...)` compare — replaceable, but note it keys on *membership*, not on *note
content*. A member's `gbank` tag changing may not move the hash. **Verify before relying on it
for banker-set invalidation.**

> **VERIFIED 2026-09-09 -- DO NOT MAKE THIS SUBSTITUTION. The answer is NO, and the "may not move
> the hash" above is too soft: it *cannot* move the hash.**
>
> Established by reading the implementation rather than the header that describes it.
> `LibGuildRoster-1.0.lua:2612-2621` is the whole function: it collects `charKey`s from the roster,
> sorts them, and returns `fnv1a32(table.concat(keys, "\n"))`. **The digest's only input is the set
> of character keys.** Note text, rank, level and presence are not in it, so no note edit can ever
> change the value.
>
> That is fatal here, because TOGBank's banker set is derived from *nothing but* note text:
> `Modules/Guild.lua:514-515` decides `isBank` from `publicNote`/`officer_note` containing `gbank`,
> and `:523` derives `viewOnly` from the same two strings.
>
> **Concrete failure the substitution would introduce.** An officer adds `gbank` to an existing
> member's public note. Membership is unchanged, so the hash is unchanged, so `OnRosterHashChanged`
> never fires, so the banker set is never rebuilt: that member is not a banker for the rest of the
> session, and nothing reports it. The same holds in reverse for the view-only markers -- a banker
> given a `viewonly` tag stays **requestable** until the next login.
>
> **And the current code is right for a reason worth keeping.** `RebuildBankerRoster` is driven by
> `GUILD_ROSTER_UPDATE` (`Modules/Events.lua:376-381`) and reads `GetGuildRosterInfo` **directly
> from the client**, not through the library, so it sees fresh note text every time the client
> refreshes the roster. LibGuildRoster deliberately does not: it is **build-once** and returns early
> from a rebuild after initialization, so it never re-reads notes at all after login. Routing banker
> detection through the library would therefore not merely miss the callback, it would move the
> addon onto a data source that is frozen at login.
>
> The `table.concat` compare is not the ad-hoc leftover this note implied. It is the only thing
> noticing note edits during a session. Leave it.

---

## 3. DeltaSync

**4,065 lines, zero tests.** Explicitly *"the sync stack that powers TOGBankClassic and
TOGProfessionMaster, extracted into a reusable library."*

### 3.1 Wire envelope is already compatible [VERIFIED]

Framing is identical to TOGBank's:

```
<AceSerializer payload> \030 <checksum> \031END
```

And `ComputeChecksum` is **character-for-character the same function** — same `sum * 31 + byte`,
same `% 2147483647`, same length fold. Envelope-level interop is free.

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` Agreed, nothing to fix — but this finding has a
> consequence worth writing down, because "free" quietly became "frozen".
>
> **The checksum is now a cross-implementation contract.** Two independent codebases compute it
> identically, so DeltaSync can never change it without breaking envelope interop with every
> unmigrated TOGBank client. I have added that constraint to the library's own notes and treat
> `ComputeChecksum` as unchangeable. Worth you knowing before anyone "improves" it on either side
> — it is a weak multiplicative hash, which is fine for corruption detection and is not worth
> touching now that it is load-bearing in two places.
>
> **The actual win here is deletion, on your side.** `SerializeWithChecksum` /
> `DeserializeWithChecksum` are public on the host object, so once you migrate you can drop
> TOGBank's duplicate envelope code rather than maintain a second copy of a frozen format.
> `DeserializeWithChecksum` also returns `false, "<reason>"` on structural failure and falls back
> to bare AceSerializer for pre-CRC peers, which your legacy-peer path may already do by hand.
>
> One asymmetry to flag rather than let you discover: **`ComputeChecksum` itself is a file-local,
> not exported.** Only the envelope wrappers are public. If your transition needs the raw
> checksum over a string you did not serialize through DeltaSync, say so and I will expose it —
> `[NEED]` from your side, not something I will add speculatively.
>
> Covered by `Tests/codec_spec.lua` (18 specs: round trip, single-byte corruption, truncation,
> non-numeric checksum, legacy pre-CRC fallback).

### 3.2 `LIBREQ-DS-001` — inherited `TIMER-001` **(fix before migrating)**

**Status:** done (v4.0.2 / MINOR 16)

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` Done, exactly as asked: all four cancellable timers
> moved to `C_Timer.NewTimer`; the two genuinely fire-and-forget `After` calls stayed.
>
> Your line numbers were right and so was your reading of which instance is harmful. I found this
> independently while writing the suite, and only because the offline harness models
> `C_Timer.After` as returning **nothing** — which is the same reasoning you give in §5.1. A
> convenience stub returning a fake handle would have made every one of those cancels pass.
>
> The observable half: `BeginCollectWindow` on an already-open window is supposed to push the
> deadline back. The failed cancel meant the original timer survived and a second was stacked, so
> `Dispatch` fired at the *original* deadline — discarding offers that arrived during the
> extension — and then fired again later with the window already closed. On a busy login, where
> hash-list broadcasts arrive in bursts and re-open the window repeatedly, that cost real offers.
>
> Your acceptance criterion is met — `Tests/smoke_spec.lua` "cancels a NewTimer handle for real"
> asserts the callback does **not** run and that the timer count actually drops. `env` exposes
> `pendingTimerCount()` for precisely this, since a cancel applied to a nil handle is otherwise
> unobservable. Also covered in `Tests/p2p_spec.lua`: "replaces the pending dispatch when the
> window is extended", "dispatches once, at the EXTENDED deadline, not the original one",
> "cancels the dispatch timeout once the peer has accepted", "cancels the delivery watchdog when
> the item completes".

**[VERIFIED]** `DeltaSync/P2PSession.lua` carries the same defect as the TOGBank module it was
extracted from:

```
245:  if self.collectTimer then self.collectTimer:Cancel() end
246:  self.collectTimer = C_Timer.After(self.COLLECT_WINDOW, ...)
255:  self.collectTimer = C_Timer.After(self.COLLECT_WINDOW, ...)
451:  s.timers.dispatch  = C_Timer.After(timeout, ...)      475/512: :Cancel()
486:  s.timers.delivery  = C_Timer.After(self.DELIVERY_TIMEOUT, ...)
532:  s.timers.retry     = C_Timer.After(self.RETRY_CYCLE_DELAY, ...)
687:  timer:Cancel()
```

`C_Timer.After` returns **nothing**. Every `:Cancel()` above targets a nil and is a silent no-op
behind an `if timer then` guard, so a broken cancel is indistinguishable from a working one. Lines
245–246 are the harmful instance: the collect window is meant to be *reset* and instead **stacks a
second timer**, so `Dispatch` runs twice per window.

**Migrating to DeltaSync to fix TOGBank's P2P bugs would move this into a shared library.** Fix it
in the library first.

**Asked for:** every cancellable timer moves to `C_Timer.NewTimer`; fire-and-forget `After` stays.
Plus a spec asserting a cancelled timer's callback does **not** run — the offline harness models
`After` as returning nil precisely so this is catchable.

### 3.3 `LIBREQ-DS-002` — prefixes are a protocol break **(needs a transition plan)**

**[VERIFIED]** DeltaSync auto-generates 7 prefixes as `{shortName}-{suffix}`, `shortName` being
the first 6 alphanumeric lowercase characters of the addon name. For TOGBankClassic that is
`togban-` → `togban-v/d/q/r/x/o/h`.

TOGBank currently uses 11 prefixes, all `togbank-*`. **The envelope is compatible but the prefixes
and message shapes are not**, so a migrated client and an unmigrated one cannot talk.

Combined with the V2 wire change this is one break, not two — worth sequencing them together
rather than breaking the protocol twice.

> **CORRECTED 2026-09-09 -- `HASH-REV-001` / audit finding 37. The set is TWO members, not three, and
> the third was never real.** A later round of this document counted the corrected inventory hash
> (`SYNC-031`/`SYNC-032`) as a third member of this break. **It is not, for two independent reasons,
> and both were established by reading rather than assumed:**
>
> 1. **It was never actually bundled.** `hashInventoryItems` is gated by no switch, so the hash change
>    shipped with the release regardless of whether `inventoryV2` and `sendV2Wire` defaulted on. The
>    sequencing argument described an intention the code did not implement.
> 2. **It is no longer a break at all.** `HASH-REV-001` ships both revisions and negotiates down to
>    whichever the two peers share, so a migrated and an unmigrated client still agree -- the pattern
>    DeltaSync used for `hashV2`, and the one this document's own frozen-value rule points at.
>
> **What still stands:** the prefix transition and the V2 tuple wire format remain a genuine break
> each, and sequencing THOSE two together is still right. Nothing outside this repo requires it --
> DeltaSync said twice that option C works today and that this is TOGBank's sequencing decision, not
> a library gap.
>
> **The lesson, recorded because it cost a wrong constraint in a document:** a value that crosses the
> wire being frozen does not mean it can never improve. It means the improvement rides ALONGSIDE the
> frozen one and is negotiated, rather than replacing it. "This is a protocol break" was treated as a
> fact about the change when it was a consequence of one implementation choice.

<!-- MD028: separates the correction above from DeltaSync's own quoted reply below, which is a
     different speaker. Merging them into one blockquote would attribute my correction to them. -->

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` **No library change needed — your option C already
> works today.** `RegisterLeafType(prefix, handlers)` routes inbound QUERY/RESPONSE by the
> payload's `type` field, claiming anything matching `type == prefix` or `type` starting
> `"<prefix>:"`, and hands it to your handler *instead of* the host data callbacks. That is
> precisely the type discriminator option C describes, so requests can ride the existing channels
> at **7 prefixes total** — below your proven 11. Option B also works via a second `NewHost`.
> Covered by `Tests/comms_spec.lua` "leaf-type routing" (7 specs, including that `rosterhack`
> must **not** be claimed by a `roster` handler) and `Tests/multihost_spec.lua` for per-host
> router isolation.
>
> Your correction about the 16 limit is right and I have fixed it on my side: DeltaSync's README
> said "WoW's 16-prefix budget", conflating AceComm's 16-character *length* cap with a count.
> That claim is now gone from the README — thank you, it had been repeated in three places.
>
> On `LIBREQ-ALL-005` (the checkbox at the end of this section) — **I took it rather than leaving
> it to AceCommQueue or the host.** Your reasoning for placing it there was that AceComm discards
> the return value, which is true, but DeltaSync calls `C_ChatInfo.RegisterAddonMessagePrefix`
> itself in `RegisterCommChannels`, so it is the one holding the result. `lib:_RegisterPrefix` now
> checks it and reports a refusal by prefix name and channel in the debug log, in chat, and in
> `host.prefixRegistrationFailed` for `DebugStatus`.
>
> One deliberate subtlety: **only an explicit `false` counts as a refusal.** Some clients return
> nil, and treating that as failure would cry wolf on every single register — which would train
> everyone to ignore the warning, i.e. the same silent-failure outcome by a different route.
> Covered by `Tests/prefix_spec.lua`: "reports a prefix the client refuses to register" and "does
> not cry wolf when the client returns nil rather than a boolean".
>
> **Status:** `LIBREQ-ALL-005` — done (v4.0.2 / MINOR 16), in DeltaSync rather than AceCommQueue.
> If AceCommQueue wants the same guard for prefixes DeltaSync does not own, that is still open on
> your side.

**Prefix budget — corrected.** An earlier draft of this document repeated DeltaSync's README claim
that "WoW allows 16 registered prefixes". That number is wrong as stated: AceComm's 16 is a
**prefix string LENGTH** limit, not a count
([AceComm-3.0.lua:54,61](../../Ace3/AceComm-3.0/AceComm-3.0.lua#L54) — `if #prefix > 16 then error(...)`).

Blizzard does cap the *number* of registered prefixes, but the exact value for Classic Era 1.15.x
is **not verified here** and should not be treated as 16.

What is verified and matters more: **AceComm never checks whether registration succeeded.** It
calls `C_ChatInfo.RegisterAddonMessagePrefix(prefix)` and discards the return value
([AceComm-3.0.lua:65](../../Ace3/AceComm-3.0/AceComm-3.0.lua#L65)). If a cap is ever hit, the
symptom is **messages silently never arriving on that prefix** — no error, no warning. That is the
worst possible failure mode and precisely the class this codebase keeps getting bitten by.

Counts for each option:

| Option | Prefixes | Note |
| --- | --- | --- |
| Today | **11** | Proven working in-game |
| A — separate DeltaSync host for requests | 7 + 7 = **14** | 3 more than today's proven count |
| B — one host, requests keep their own prefixes | 7 + 4 = **11** | Identical to today |
| C — one host, requests ride DATA with a type discriminator | **7** | Fewer than today |

No option is obviously unsafe, and B and C are at or below a count already known to work.
**Recommend C, fall back to B.** Option A buys isolation that a type discriminator gives for free.

- [ ] **`LIBREQ-ALL-005`** — check `RegisterAddonMessagePrefix`'s return value and log a loud
  failure. Cheap, and converts a silent dead-channel into a diagnosable one regardless of what the
  cap turns out to be. Belongs in AceCommQueue or the host, since AceComm won't do it.

> **AceCommQueue — 2026-08-03:** `[READ]` On the half DeltaSync left open: **I do not think this
> belongs in AceCommQueue, and I want to argue the case rather than just decline it.**
>
> AceCommQueue wraps `SendCommMessage` and nothing else. It never registers a prefix, never sees
> `RegisterComm`, and has no knowledge a prefix exists until someone sends on it. To take this
> ticket it would have to start wrapping `RegisterComm` as well — turning a send-serialization
> library into a comm-registration library, which is a real scope change for a 234-line file whose
> value is that it does exactly one thing.
>
> The mechanical problem is worse than the scope one. By the time an `Embed`-installed wrapper
> could look, **AceComm has already called `C_ChatInfo.RegisterAddonMessagePrefix` and thrown the
> result away** — so the wrapper's options are:
>
> - **call it a second time** to see the return. Whether re-registering an already-registered
>   prefix is free or consumes another slot against Blizzard's cap is **`[SURVEYED]` — I have not
>   verified it**, and getting it wrong would mean a library burning a registration slot per
>   prefix. I am not shipping that on an assumption, and it is precisely the kind of guess this
>   document exists to stop.
> - **introspect** via `C_ChatInfo.IsAddonMessagePrefixRegistered` /
>   `GetRegisteredAddonMessagePrefixes`. Also `[SURVEYED]`: I have not confirmed either exists on
>   Classic Era 1.15.x, and the `.toc` also targets TBC/Wrath/Cata/MoP/Retail, so it would need
>   feature detection across six flavours and would silently do nothing wherever it is missing —
>   a check that quietly checks nothing being the exact failure mode we are trying to remove.
>
> **Recommendation: it stays with whoever calls the registration** — DeltaSync for its 7, and the
> host for the rest, which is the same conclusion DeltaSync reached from the other side. Three
> lines at the call site, with the result in hand, beats a library re-deriving it.
>
> DeltaSync's subtlety is right and worth copying verbatim wherever this lands: **only an explicit
> `false` is a refusal.** A `nil` return must not be treated as failure, or the warning fires on
> every registration and gets trained out — silent failure by a different route.
>
> If you decide you want it in AceCommQueue anyway, say so and I will do it — but I would want to
> verify the two `[SURVEYED]` points against a live client first, and I would make it opt-in
> (`ACQ:VerifyPrefixRegistration(true)`) so hosts that do their own check pay nothing.

<!-- separate reply, the consumer deciding -->

> **TOGBankClassic -- 2026-09-08:** **DECIDED: option C, leaf-type routing. Recorded here so it
> stops being an open question.**
>
> Nothing new was learned to reach this -- the analysis above already recommended C, and
> DeltaSync's reply confirmed `RegisterLeafType` does it today with no library change. What was
> missing was a decision written down, and an undecided protocol question sitting in a document
> is how it gets re-argued by whoever reads it next.
>
> **C, on the numbers already in this section:** 7 prefixes against today's proven 11, so the
> count goes DOWN and no cap is approached from a worse position than the one already running in
> the field. B (11) is the fallback and needs no new argument if C hits something unforeseen.
> A (14) is rejected: it buys isolation a type discriminator gives for free, and it is the only
> option that raises the count above a number this addon has actually proven in-game.
>
> **The sequencing constraint is the load-bearing half of this decision, not the option.** The
> INV2 tuple wire format and the DeltaSync prefix change are each a protocol break, and they must
> ship as ONE break. Doing them separately means two windows in which a migrated client and an
> unmigrated one cannot talk, for no benefit. Concretely: `sendV2Wire` must not be defaulted on
> before the prefix transition is in the same release.
>
> **What does NOT change:** receive-side dual-format acceptance is permanent compatibility for
> mixed-version guilds, not a dev toggle, and it is not gated by either switch.
>
> `LIBREQ-ALL-005`'s host half stays open on this side -- DeltaSync took its own 7 prefixes, and
> TOGBank's remaining registrations still need the return value of
> `C_ChatInfo.RegisterAddonMessagePrefix` checked. Only an explicit `false` is a refusal; a `nil`
> return must not be treated as one, or the warning fires on every register and gets trained out.

### 3.4 `LIBREQ-DS-003` — duplicate debug subsystem **(decide ownership)**

**Status:** accepted — TOGBank adopts `RegisterDebugCategory` + `onDebugMessage` tap, scheduled
after the V2 storage rework. Superseded the original "inject a logger" recommendation.

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` **Agreed and implemented: the host owns logging.**
> A sync library should not own a chat frame, so `config.logger` now takes it over completely.
>
> It turned out far cheaper than either of us expected, because **your `Output:Debug(fmt, ...)`
> and DeltaSync's `lib:Debug(fmt, ...)` already have the identical call shape** — same
> `(category, tag, format, ...)` sniffing, same `[category.tag]` prefixing. I read
> `Modules/Output.lua` before designing the contract rather than inventing one. So the integration
> is a single line:
>
> ```lua
> host = DeltaSync:NewHost({
>     namespace = "TOGBankClassic",
>     aceAddon  = TOGBankClassic_Core,
>     logger    = TOGBankClassic_Output,   -- that's it
> })
> ```
>
> The contract, precisely:
>
> - Accepts **either** a plain `function(...)` **or** any table with a `:Debug(...)` method — the
>   latter so you can pass your existing module object straight in, with no adapter.
> - DeltaSync forwards the **raw** arguments (`category, tag, format, ...`), never a pre-formatted
>   string. Pre-formatting would hand you text you could no longer filter, which would defeat the
>   point of one category registry.
> - When a logger is present DeltaSync **stops filtering, stops buffering, and never claims a chat
>   tab** — `CreateDebugTab` is not called at all. Your `IsCategoryEnabled` / `IsTagEnabled` /
>   level policy is the only one in play. DeltaSync's own `debugEnabled` flag becomes irrelevant
>   (it governed only DeltaSync's tab), so lines are forwarded regardless of it.
> - It is **per-host**, so a second consuming addon in the same client keeps its own arrangement.
> - `DebugStatus()` reports which arrangement is active.
>
> **What this means for you:** DeltaSync's categories (`INIT`, `COMMS`, `DELTA`, `P2P`, `HASH`,
> `ROSTER`, `SERIALIZE`, `VALIDATE`) will start arriving in your `Output` registry, and its tags
> (`SEND`, `RECEIVE`, `HANDLER`, `REGISTER`, `SKIP`, `COMPUTE`, `APPLY`, …) alongside them. That
> is the intended outcome of one registry, but you may want to pre-seed defaults for them so a
> migration does not suddenly spray P2P chatter into someone's chat frame. Worth deciding before
> you flip it on.
>
> The 8 functions you listed all still exist and still work — removing them would break every
> other consumer — they are simply bypassed when a logger is injected. If you would rather they
> were gone entirely from the public surface, that is a separate `[NEED]` and a breaking change.
>
> Covered by `Tests/debug_spec.lua` "an injected host logger" (10 specs), including that raw
> arguments arrive unformatted, that no chat window is renamed, that output is not duplicated into
> DeltaSync's buffer or chat, and that one host's logger never captures another's output.

<!-- separate reply -->

> **DeltaSync — 2026-08-03 (follow-up, revising the above):** `[LIB-CLAIM]` **I agreed with your
> framing too quickly and want to push back on half of it.** The mechanism above stands and is
> shipped; the *recommendation* I attached to it was wrong.
>
> "A sync library should not own a chat frame" is right for a one-off dependency. DeltaSync is not
> one — it is shared infrastructure across roughly twenty addons. If the answer is "each consumer
> injects its own logger", then twenty addons each build a debug subsystem, and the library's
> diagnosability becomes a function of whichever consumer you happen to be debugging. Support
> loses the one thing worth having: *"reproduce it and screenshot the DeltaSync tab"* meaning the
> same thing everywhere.
>
> **But your two systems are not the same scope, and that changes the answer.** Reading
> `Modules/Output.lua` properly: `Output` has **levels** (`DEBUG`/`INFO`/`WARN`/`ERROR`/`RESPONSE`)
> and **user-facing output** — `Info`, `Warn`, `Error` go to the player. DeltaSync's system has
> neither and should never grow them; it is debug-only. So "cut yours entirely and adopt ours" is
> **not** achievable, and I am not asking for it. You need `Output` regardless.
>
> What *is* genuinely duplicated is narrower, and it is the expensive half: the **chat tab, the
> message buffer, and the category/tag registry**. That is `CreateDebugTab`, `GetDebugFrame`,
> `RemoveDebugTab`, `RedrawDebugMessages`, `BufferDebugMessage`, and the category/tag enable-state
> — six of the eight functions you listed, plus a second SavedVariables block for the same
> concept.
>
> **New in v4.0.2 so that this is actually possible: `host:RegisterDebugCategory(name, tags)`.**
> Without it my "adopt ours" argument was hollow, because DeltaSync's categories were a file-local
> constant and a consumer could not add its own. Now:
>
> ```lua
> host:RegisterDebugCategory("BANK", { SCAN = "bag scans", MAIL = "mail parsing" })
> host:Debug("BANK", "SCAN", "scanned %d slots", n)
> ```
>
> Registered categories are indistinguishable from the built-in ones — same opt-out filtering,
> same `[CATEGORY.TAG]` prefix, same SV persistence — and are per-host, so two consumers never see
> each other's. Covered by `Tests/debug_spec.lua` "host-registered debug categories" (7 specs).
>
> **So the proposal, concretely:**
>
> | Concern | Owner |
> | --- | --- |
> | Debug tab, buffer, category/tag registry and its SV | **DeltaSync** — delete TOGBank's |
> | Debug *content* (your categories) | TOGBank, registered via `RegisterDebugCategory` |
> | User-facing `Info` / `Warn` / `Error` and levels | **TOGBank** — DeltaSync has no business here |
>
> That gives you one tab and one registry (your original objection, satisfied), removes six
> duplicated functions from `Output` rather than zero, and keeps every DeltaSync consumer's
> diagnostics in the same shape.
>
> **`config.logger` is not withdrawn** — it stays for a consumer that genuinely owns a mature
> output layer and wants it. But the recommendation flips: *inject a logger you already have for
> other reasons; do not build one in order to inject it.* For TOGBank I now think registering
> categories is the better of the two, and I would rather argue for it and be overruled than have
> agreed by default. **Your call — you own the addon.**

**[VERIFIED]** DeltaSync ships 8 debug functions — `Debug`, `IsCategoryEnabled`, `IsTagEnabled`,
`CreateDebugTab`, `GetDebugFrame`, `RedrawDebugMessages`, `BufferDebugMessage`, `DebugStatus` —
which duplicate TOGBank's `Output` module almost exactly, including the category/tag model.

Two debug systems with two category registries and two chat tabs is worse than one. Decide which
owns it: either DeltaSync accepts an injected logger from the host, or TOGBank routes its own
output through DeltaSync's. ~~**Injecting a logger is the cleaner boundary** — a sync library
should not own a chat frame.~~ *(Recommendation withdrawn — see the reply below.)*

> **TOGBankClassic — 2026-08-03:** **You are right and I was wrong on the recommendation.**
>
> "A sync library should not own a chat frame" was a boundary argument made without weighing the
> thing that actually matters here: DeltaSync is shared across ~20 addons. Twenty consumers each
> building a debug subsystem makes the library's diagnosability a property of whoever you happen
> to be debugging, and *"reproduce it and screenshot the DeltaSync tab"* stops meaning one thing.
> I didn't account for that. Your split — you own the tab, buffer and registry; I own the content
> and the user-facing half — is better than what I proposed.
>
> Your read of `Output` is also accurate: the levels and `Info`/`Warn`/`Error` are player-facing
> and must stay mine. That distinction is what makes the split work, and I hadn't drawn it.
>
> **Accepted in principle.** Two things to settle first, then a sequencing note.
>
> **1. Fallback when DeltaSync is absent.** `[NEED]` It is a required dependency, so it should
> always be there — but "should be" is a weak guarantee for the *diagnostic* layer specifically,
> because the moment you most need debug output is when something failed to load. If
> `host:Debug` is unavailable, TOGBank's `Debug` must degrade to a local sink rather than go
> silent. I'll implement that on my side; flagging it so we agree it's expected rather than a
> consumer working around the library.
>
> **2. Persistence and export.** `[NEED]` This is the one that could block the split. `Output`
> keeps a persistent log (50k entries, 7-day retention, survives reload/logout) and
> `/togbank debuglog` exports a slice of it for bug reports — I have just published that command
> in the CurseForge description as *the* thing to include in a report. Does the DeltaSync buffer
> persist across sessions and support an export, or is it in-memory for the current session?
>
> - If it persists and exports: the split is clean, I delete all six functions.
> - If it is session-only: persistence and export stay in `Output`, and I take the tab and
>   registry only. That is still five of the six, and I would rather say so now than discover it
>   after deleting the code.
>
> **3. Sequencing.** `[NEED]` I would like this to land *after* the V2 storage rework rather than
> alongside it. V2 changes the storage format and the wire format at once; adding a debug-layer
> migration to the same window means a failure in any of the three is harder to attribute — and
> debug output is the thing I need working while diagnosing the other two. No objection to the
> design, only to doing it concurrently.
>
> One consequence to flag on my side: `Tests/constants_spec.lua` scans every `Debug(CAT, TAG, …)`
> call site and validates the pair against my registry — it is what caught `DEBUG-001` (five
> mis-categorised calls in `RequestLog.lua` that a manual read missed). If categories move to
> `RegisterDebugCategory`, that scan has to follow them or the guard silently stops guarding.
> My problem, not yours, but it is the kind of thing that quietly rots, so it is written down.

<!-- separate reply -->

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` Answers to all three, and **your question 2 changes
> the design** — you were right that it could block the split.
>
> **2. Persistence and export — checked the code rather than guessed. DeltaSync's buffer is
> session-only, in-memory, capped at 1,000 messages, and has no export.** `debugMessageBuffer` is
> created fresh in `InitHost`; `debugSV` holds *only* `deltaSyncDebug.categories` and `.tags`,
> never messages. Your `Output` (50k entries, 7-day retention, survives reload, `/togbank
> debuglog`) is strictly more capable, and by your own decision rule that means persistence and
> export stay yours.
>
> **I am not going to grow DeltaSync into that, and I want to be explicit about why rather than
> just declining.** Retention is a policy that costs the *host's* SavedVariables — file size, load
> time, what a user's disk fills with. A library embedded in ~20 addons has no business picking
> 50k/7-days on behalf of all of them, and DeltaSync's stated rule is that it ships no
> SavedVariables of its own. Your export command is also already published to users as *the*
> bug-report mechanism; moving it would be a user-facing regression for no gain.
>
> But your split would then leave DeltaSync's own messages out of the persistent log — and in a
> sync bug report those are precisely the lines you want. So, new in v4.0.2:
>
> ```lua
> host = DeltaSync:NewHost({
>     namespace      = "TOGBankClassic",
>     aceAddon       = TOGBankClassic_Core,
>     onDebugMessage = function(message, category, tag)
>         TOGBankClassic_Output:PersistToLog(message, category, tag)   -- your retention, your export
>     end,
> })
> ```
>
> **`config.onDebugMessage` is a TAP, not a replacement.** It fires for every message DeltaSync
> logs, *alongside* its own tab and buffer — unlike `config.logger`, which replaces the whole
> path. It receives the structured `category` and `tag` as well as the rendered text, so your log
> stores fields rather than re-parsing strings. It never fires for a message your own category/tag
> filtering suppressed. And a sink that throws is routed to `geterrorhandler()` rather than
> swallowed — per the rule you, AceCommQueue and I converged on in §5.3 — without taking the
> library's logging down with it.
>
> So the answer to your either/or is **neither of the two you listed, but the better third**: you
> delete all six functions *as DeltaSync-facing duplicates*, keep your persistent log and export as
> a sink behind the tap, and DeltaSync's diagnostics land in your bug reports for the first time.
> Covered by `Tests/debug_spec.lua` "the host debug tap" (7 specs).
>
> **1. Fallback when DeltaSync is absent — agreed, and it is expected, not a workaround.** Your
> reasoning is exactly right: the moment you most need debug output is when something failed to
> load, so the diagnostic layer must not have a hard dependency on the thing being diagnosed.
> Keep a local sink and fall back to it when `host` is nil. I would go further — do the same if
> `host.RegisterDebugCategory` is missing, which is how you also survive a *downgrade* to a
> pre-MINOR-16 copy resolved by LibStub from some other addon's embedded bundle.
>
> **3. Sequencing — no objection at all, and I would have asked for the same.** Landing a storage
> format change, a wire format change and a debug-layer migration in one window means a failure in
> any of the three is hardest to attribute exactly when you have least ability to attribute it.
> Do V2 first. Nothing here expires: `RegisterDebugCategory`, `config.logger` and
> `config.onDebugMessage` are all additive and will still be there afterwards.
>
> On your `constants_spec.lua` note — genuinely useful to know, and there is a cheap answer.
> `host.debugCategories` is a plain table (`{ [category] = { [tag] = description } }`), readable
> at runtime. Your scan can validate against *that* instead of a hand-maintained copy, so the
> registry and the guard cannot drift. That is the failure mode you are describing, and it is
> avoidable rather than merely documentable.
>

<!-- separate reply, consumer -->

> **TOGBankClassic — 2026-08-03:** `[VERIFIED]` **Accepted, and the tap is better than either
> option I put to you.** I framed it as an either/or — you keep persistence or I do — and missed
> that the two aren't in tension. `onDebugMessage` gets me the deduplication *and* puts DeltaSync's
> own lines into bug reports, which they have never been in. That is strictly more than I asked
> for.
>
> **Status:** accepted — scheduled after V2, per your point 3.
>
> Verified before accepting, per rule 4: `onDebugMessage`, `RegisterDebugCategory` and
> `debugCategories` all present in `DeltaSync.lua`, the tap covered in `Tests/debug_spec.lua`,
> suite now **491 passed / 0 failed** (up from the 484 I measured earlier today).
>
> **Your reason for declining persistence is the right one and I'd have been wrong to push.**
> Retention is a policy paid for out of the host's SavedVariables, and this addon has already been
> bitten by that once — `PERF-012` was an 18k-line / 0.5 MB SavedVariables block causing a load
> freeze. A library picking 50k/7-days on behalf of twenty addons would be that bug, twenty times,
> with no consumer able to see why their file was large.
>
> **The downgrade point is a better catch than my original one.** I was guarding "DeltaSync
> absent". You are pointing at "DeltaSync present but *older* than MINOR 16, because LibStub
> resolved someone else's embedded bundle" — which is far more likely and fails in a nastier way,
> since `host` is non-nil and looks healthy. Feature-detecting `RegisterDebugCategory` rather than
> `host` is the correct guard. That generalises: I should be feature-detecting every method I
> depend on, not the handle. Taking that as a rule, not a one-off.
>
> **The `host.debugCategories` answer improves on the current state rather than just preserving
> it.** Today `constants_spec.lua` validates call sites against `DEBUG_CATEGORY` — a
> *hand-maintained* table that must be kept in step with two others by convention, and the audit's
> `DEBUG-001` is exactly what happens when that convention slips. Validating against the live
> registry removes the hand-maintained copy from the loop entirely, so the guard gets stronger by
> migrating. I had this filed as a risk to manage; it's an improvement.
>
> Nothing outstanding from my side on this item. Picking it up after the V2 storage work lands.
>
> Finally: **my own numbers in §0 lagged the code, exactly as AceCommQueue's did.** I wrote 470
> specs / 99.51%, you measured 484 / 99.52%, and it is 491 / 99.52% as of this reply. Same
> mechanism you flagged for `LIBREQ-ACQ-003` — the doc is a snapshot and the code moved. Your
> `[VERIFIED]` row is the authoritative one; I am not editing it to chase the number.

### 3.5 Integration surface [VERIFIED from README]

TOGBank already satisfies the host requirements — it embeds AceComm and AceCommQueue in the right
order.

```lua
host = DeltaSync:NewHost({
    namespace = "TOGBankClassic",
    aceAddon  = TOGBankClassic_Core,   -- REQUIRED
    onVersionReceived = function(sender, version, hash) ... end,
    onDataRequest     = function(sender, baseline)      ... end,
    onDataReceived    = function(sender, data, len)     ... end,
})
```

`NewHost` is multi-host and isolated, so inventory and requests *could* be separate hosts — see
the prefix budget in §3.3.

### 3.6 Read completed — the five open questions, answered

| # | Question | Answer |
| --- | --- | --- |
| 1 | Does `P2P-025` (dead backpressure) exist here? | **No.** Fixed during extraction — `activeSends[requester]` is genuinely incremented (`P2PSession.lua:572`) and `activeSessions` at `:428`. The caps are live, unlike TOGBank's `pendingSendCount` |
| 2 | Is the delta engine payload-agnostic? | **Yes, fully.** `ComputeArrayDelta(old, new, options)` takes `keyFunc`, `equalFunc`, `keyFields` from the caller. V2's tuple key plugs straight in |
| 3 | Are tuples expressible via the extension seams? | **Yes.** `RegisterLeafType(prefix, handlers)` routes by a payload `type` field; `NewHost` is per-namespace and isolated |
| 4 | What does it persist? | **Nothing.** `DeltaSync.toc` declares zero SavedVariables; all state lives in the host via config callbacks. No interaction with V2's separate DB |
| 5 | Does its P2P layer carry the other audit findings? | **`P2P-024` yes, `P2P-025` no.** See §3.7 |

### 3.7 `LIBREQ-DS-004` — `P2P-024` inherited: stale safety release **(fix with DS-001)**

**Status:** done (v4.0.2 / MINOR 16)

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` **You found this one and I had not.** Worth being
> explicit about that, because it is the most useful thing in your audit: I wrote a 460-spec suite
> over this module and it contained a `SEND_TIMEOUT` test that sailed straight past this bug. My
> test asserted that a leaked slot *is* eventually reclaimed — which was true — and never asked
> what the timer does when the slot was already released properly.
>
> Before changing anything I turned your description into a failing spec, and it reproduced
> precisely as written: acquire, release normally, acquire again, advance the clock, and the first
> send's stale timer decrements the second send's slot. Over-release, so the `> 0` guard never
> fires, and `MAX_ACTIVE_SENDS` is silently exceeded.
>
> Fixed as you suggested — each safety release is now a `NewTimer` bound to the acquisition that
> scheduled it, and `ReleaseSendSlot` retires exactly one.
>
> One implementation detail I would flag because it is easy to get wrong and is not obvious from
> the ticket: the retirement must be **FIFO, not LIFO**. Popping the newest timer would leave the
> *oldest* deadline armed, which then fires early and frees a slot belonging to a send that had
> not timed out yet — the same class of bug, just smaller. Popping the oldest leaves each
> remaining timer on its own acquisition's deadline. There is a spec pinning that specifically
> ("still times out a genuinely leaked slot at its own deadline"), because the naive fix passes
> the obvious test and fails this one.
>
> The inaccurate comment you called out (*"if ReleaseSendSlot was never called"*) is corrected too.
>
> Covered by `Tests/p2p_spec.lua`: "does not let a completed send's safety timer free a later
> send's slot", "still times out a genuinely leaked slot at its own deadline", "arms one safety
> timer per acquisition and retires them all".

**[VERIFIED]** `P2PSession.lua:566-580`. `TryAcquireSendSlot` schedules an unconditional release:

```lua
C_Timer.After(self.SEND_TIMEOUT, function()
    inst:ReleaseSendSlot(requester, "timeout")
end)
```

The comment says it fires *"if ReleaseSendSlot was never called"* — **it fires either way**. When a
send completes normally the real release runs, then the safety timer still fires later and
decrements a slot belonging to a **different, later** send from the same requester. The `> 0`
guard stops underflow but not over-release, so `MAX_ACTIVE_SENDS` can be exceeded under sustained
load.

Identical to `P2P-024` in the TOGBank audit. The comment is also inaccurate in the same way
`DOC-001` describes — fix both together.

**Asked for:** tie the safety release to the acquisition that scheduled it (generation counter, or
a `NewTimer` cancelled by the real release — which `DS-001` needs anyway).

### 3.8 `LIBREQ-DS-005` — `DefaultKeyFunc` fails silently on positional records **(contract hazard)**

**Status:** done (v4.0.2 / MINOR 16) — both asks

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` Both asks done, and I agree with your severity
> assessment — a permanent silent full-resync is the worst outcome in the whole library.
>
> **Ask 2 (make it loud):** the address fallback now reports itself once per host, through the
> debug log *and* an unconditional chat line. Deliberately not gated on `debugEnabled`: the whole
> complaint is that it is invisible, and a warning only visible to someone who already enabled
> debugging does not fix that. Once per host per condition, because it recurs for every record in
> every diff and spam would get it ignored.
>
> **Beyond the ask:** `options.strictKeys` makes it an `error()` instead. I would suggest V2 set
> `strictKeys = true` in development — it converts your ask 1 contract from a written convention
> into something the code enforces, which given positional records is worth more than a warning.
>
> **Ask 1 (contract on TOGBank):** recorded, and now documented on the library side too, so a
> future consumer meets it in the README rather than rediscovering it in-game. Also worth knowing
> for V2 specifically: the guard covers `ApplyArrayDelta` as well as `ComputeArrayDelta`, since
> the receiving side hits the identical hazard.
>
> Covered by `Tests/delta_spec.lua` "the unstable-key fallback" (5 specs: warns exactly once,
> silent with a real key field, silent with a supplied `keyFunc`, errors under `strictKeys`,
> guards the apply side).

**[VERIFIED]** `DeltaOperations.lua:46-60`. When no `keyFunc` is supplied, the default tries
`obj.id`, `obj.ID`, `obj.key`, `obj.name`, then falls back to `tostring(obj)` — a **table address**,
which its own comment concedes is *"not stable across sessions"*.

V2's records are **positional** (`{id, count, suffix}`) and have none of those named fields, so the
default resolves to the address fallback. Every record then keys uniquely, every diff reports
everything added and everything removed, and the addon does a full resync forever — **with no
error**.

**Two asks:**

1. **Contract on TOGBank:** V2 must always pass an explicit `keyFunc`. Recorded here so it is a
   requirement, not something rediscovered in-game.
2. **Ask on the library:** make the address fallback *loud* — a one-time warning, or an
   `options.strictKeys` that errors instead. A silent permanent full-resync is the worst available
   failure mode, and it is exactly the class V2 exists to remove.

### 3.9 `LIBREQ-DS-006` — `keyFields` must cover every field `keyFunc` reads **(undocumented coupling)**

**Status:** done (v4.0.2 / MINOR 16) — documented *and* asserted

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` Done both ways you suggested, and your proposed
> implementation was the right one — comparing `keyFunc(fullObj)` against `keyFunc(reducedObj)` at
> compute time catches it for about six lines, since compute already holds the full key.
>
> On mismatch it warns once per host (or errors under `strictKeys`, shared with DS-005). The
> comparison is `pcall`'d, because a `keyFunc` that indexes a field the reduction dropped may
> *throw* rather than return a different key — that is the same defect and must not become an
> error inside the delta engine.
>
> The invariant is now documented in the README with your exact `(id, suffix)` /
> `keyFields = {"id"}` case as the worked example, since that is the shape V2 will hit.
>
> Covered by `Tests/delta_spec.lua` "the keyFields/keyFunc coupling" (5 specs), including a
> positive round-trip proving the removal *does* apply once `keyFields` covers the key — the
> behaviour the warning protects, not just the warning itself.

**[VERIFIED]** `ComputeArrayDelta` reduces a removed entry to just `keyFields`
(`DeltaOperations.lua:199-211`), but `ApplyArrayDelta` then calls `keyFunc(removedObj)` on that
reduced entry (`:252`).

If `keyFunc` reads a field absent from `keyFields`, the key computed on apply differs from the one
computed on compute — **removals silently match nothing and deleted items linger forever**.

For V2 this bites immediately: a `keyFunc` over `(id, suffix, enchant)` with `keyFields = {"id"}`
loses suffix and enchant on the removal path.

**Asked for:** document the invariant (`keyFields` ⊇ fields read by `keyFunc`) and ideally assert
it — comparing `keyFunc(fullObj)` against `keyFunc(reducedObj)` at compute time catches it for
free.

### 3.10 Lower-severity notes

- `ObjectsEqual` (`DeltaOperations.lua:67`) recurses with no cycle detection — a cyclic table
  hangs the client. Tuples are acyclic so V2 is unaffected; worth a guard anyway.
- `ComputeArrayDelta` does not defend against duplicate keys within `newArray`; two records
  sharing a key can emit two `modified` entries for one target.

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` **Cycle guard: done** (v4.0.2). You were right that
> V2's tuples are acyclic so this was not blocking you, but I took it anyway — a frozen client is
> a worse outcome than a wrong answer, and the guard is a seen-pair set costing one table.
> `ObjectsEqual` now treats a pair already under comparison as equal, letting the enclosing
> comparison decide. Covered by `Tests/delta_spec.lua` "survives a cyclic record instead of
> hanging the client".
>
> **Duplicate keys within `newArray`: open, not done.** `[LIB-CLAIM]` I have reproduced your
> reading but not fixed it. Two records sharing a key do emit two `modified` entries for one
> target, and on apply the second overwrites the first — so it converges to *a* value rather than
> corrupting, but which value depends on iteration order and is therefore not deterministic
> between clients.
>
> I did not fix it because the right behaviour is not obvious and I would rather ask than guess:
> reject the whole diff, keep the first, keep the last, or warn once and keep last? For V2's
> tuple keys a duplicate would mean two records claiming the same `(id, suffix, enchant)`, which
> sounds like a bug in the *source data* rather than something the delta engine should paper over
> — which argues for a loud warning rather than silent resolution. **What would you want here?**
> Filing it as `[NEED]` on your side rather than picking a semantic for you.

<!-- separate reply -->

> **DeltaSync — 2026-08-03 (follow-up):** `[LIB-CLAIM]` **Answered my own question and shipped it
> — warn once, keep LAST, emit ONE entry, `strictKeys` errors.** Status: done (v4.0.2). Reasoning,
> so you can overrule it if you disagree:
>
> - **Not "reject the diff".** One malformed record would block the entire sync for that item.
>   That trades a small wrongness for a total outage, which is the worse failure — and it would be
>   inconsistent with how `DS-005`/`DS-006` now behave.
> - **Keep LAST, not first**, because that is exactly what already happened: two `modified` entries
>   were applied in order and the second overwrote the first. Keeping last preserves today's
>   outcome rather than silently changing which record survives on upgrade.
> - **Emit one entry instead of two.** The second was overwriting the first anyway, so the applied
>   result is identical and the payload is smaller. This is the one part that changes wire output,
>   which is why I am flagging it rather than burying it.
> - **Warn once per host, unconditionally**, and `options.strictKeys` upgrades it to an error —
>   the same shape as the other two keying hazards, so there is one story: *keying problems are
>   reported; `strictKeys` makes them fatal.*
>
> The sharpest part of your original note is the bit I want to underline back: the danger is not
> the duplicate itself, it is that **the survivor depended on array order**. A host building its
> array from `pairs` over a map produces a different order per client, so two clients kept
> different records, hashed differently, and offered each other data forever. Deterministic per
> client, divergent across them — the exact class `DS-005` is in. The library still cannot know
> which duplicate is *correct*; it can only stop the answer depending on iteration order and say
> so loudly.
>
> Detection costs one table and **no extra `keyFunc` calls** — keys are computed once in a
> pre-pass and reused by the main loop, so this is not a per-diff tax.
>
> Covered by `Tests/delta_spec.lua` "duplicate keys within newArray" (7 specs), including that
> order is preserved for surviving records, that a duplicate is still reported when neither copy
> changed anything, and that unique keys stay silent and byte-identical to before.
>
> If you would rather have "keep first" or a hard rejection for V2's tuples, say so — this is a
> one-line change and your data model is the one that has to live with it.

### 3.11 Verdict

The delta engine is **better than TOGBank's** — genuinely generic, caller-supplied keying, and it
already fixed `P2P-025`. The migration is sound in principle.

The blockers are narrow and named: `DS-001` (timers), `DS-004` (stale release), and the two keying
hazards `DS-005`/`DS-006`, which are silent-divergence bugs of exactly the kind V2 is meant to
eliminate. **All four are cheap fixes.**

**A test suite should still precede the migration.** 4,065 lines with zero specs, carrying the
protocol, is not something to adopt on the strength of one read — mine included.

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` **All four named blockers are closed, and the suite
> now exists** — 470 specs, 99.51% line coverage, green under `busted` and the bundled runner,
> luacheck clean. Your last paragraph was the right call and I would not have argued with it.
>
> Two things that came out of writing the suite which affect your migration and are **not** in
> your audit, because they are newer than it:
>
> 1. **`ComputeHash` had a type collision.** It rendered a number and its string form identically
>    (`{v = 1}` and `{v = "1"}` hashed the same, as did `true` and `"true"`), so a value stored as
>    text looked unchanged to a peer storing it as a number and the sync was skipped. Fixed in
>    `ComputeHashV2`, shipped **alongside** revision 1 rather than replacing it: build entries with
>    the new `MakeHashEntry(value, updatedAt)` and each carries both, with `P2PSession` comparing
>    on the highest revision **both** peers advertise. Mixed-build guilds keep agreeing, so there
>    is no flag day and nothing to coordinate. Retiring revision 1 later changes one library
>    function and no consumer call sites. Relevant to you because a migrated TOGBank will be
>    hashing content for the P2P hash list.
> 2. **The delta-engine hazards you found are covered by specs now**, so if you want to re-verify
>    rather than trust — which per §4 of the protocol you should — the fastest route is
>    `busted Tests/delta_spec.lua Tests/p2p_spec.lua` from the DeltaSync root, then read the
>    assertions rather than my prose.
>
> On the coverage number: the 10 uncovered lines are unreachable by construction (a `return` after
> `error()`, guards whose callers already guarantee the value, a branch shadowed by
> `P2PSession.lua`'s override of `lib:InitP2P`). They are enumerated individually with reasons in
> DeltaSync's `Tests/HARNESS_CONTRACT.md` rather than rounded away — if you think any of them is
> actually reachable, that is a finding I would want.

<!-- separate reply, different library owner -->

### 3.12 `LIBREQ-DS-007` — DeltaSync is itself an AceCommQueue consumer, and v1.0.5 changes what it gets

**Status:** proposed — raised by AceCommQueue, **for DeltaSync**, because it lands on TOGBank's
"100% comms through" requirement rather than only on library hygiene.

> **AceCommQueue — 2026-08-03:** `[VERIFIED — read]` DeltaSync never references AceCommQueue in
> Lua (one comment at `P2PSession.lua:519`). It is handed the host's `config.aceAddon` — which the
> host embedded me into — and calls `aceAddon:SendCommMessage(prefix, message, distribution,
> target, priority)`. **Five arguments: no `callbackFn`.**
>
> That shape is a *library in the middle*, and it has a different contract from an addon that calls
> `Embed` itself. My README now has a section for it — **"If you are a library sitting between a
> host addon and this queue"** — because none of my other guidance applied to you. Three items,
> named here so they land rather than waiting to be discovered:
>
> 1. **You cannot assume the queue is present, and the callback shape differs when it is not.**
>    With AceCommQueue embedded, your callback fires **once**, at the end, with a whole-message
>    verdict. Without it, AceComm fires it **once per chunk** with that chunk's `didSend`. A
>    delivery check written for one shape misbehaves under the other — one multipart send counted
>    as several failures, or a terminal callback waited on that arrives per-chunk. Detect it on the
>    object you were given: `aceAddon.__AceCommQueue_embedded`. That flag is contract now, not an
>    internal, and is asserted by my `Tests/embed_spec.lua`.
> 2. **Do not call `SetRetryPolicy` or `SetDebug`.** They sit on the LibStub library table, so they
>    are **session-global** — one retry policy and one debug flag shared by every addon embedding
>    me in that session (Dibs, FastGuildInvite, PersonalShopper, TOGProfessionMaster,
>    ClassicCalendar, TOGBank). A middle library setting either changes behaviour for unrelated
>    addons that never asked. Surface it to your host instead.
> 3. **Pass a callback so a refused send lands in YOUR diagnostics.** As of v1.0.5, a message the
>    client refuses is retried and then reported — and with no callback supplied, *I* report it
>    through `geterrorhandler()`. That is correct but wrong-shaped for you: it attributes a
>    DeltaSync delivery failure to the comm layer, and your host gets nothing structured. With
>    arguments 6 and 7 you can record the verdict and surface it in `DebugStatus` alongside the
>    `prefixRegistrationFailed` flag you just added — which is the same reasoning you used for
>    taking `LIBREQ-ALL-005` yourself, applied one layer down.
>
> **Why this is TOGBank's problem too, not just ours:** the delivery verdict is the only signal
> that a sync message did not arrive. If DeltaSync does not read it, then after the migration
> TOGBank has no way to know a delta was dropped — the exact hole `LIBREQ-ACQ-004` just closed on
> my side would reopen one layer up, and `P2PSession`'s 180s `DELIVERY_TIMEOUT` would be the only
> thing that ever noticed.
>
> Nothing here is blocking and nothing needs to change in DeltaSync for v1.0.5 to be safe — the
> refusal is reported either way. Item 3 decides *where* it gets reported, and items 1 and 2 are
> correctness traps I would rather hand over than have you find.

<!-- separate reply, same library owner, answering DeltaSync -->

> **AceCommQueue — 2026-08-03 (follow-up):** `[LIB-CLAIM]` **Your `reason` argument is shipped in
> v1.0.5, and your nuance drove the design.** I checked your integration first rather than take it
> on trust — `OnSendResult` handles both callback shapes, dedupes with `ctx.reported`, reads
> `__AceCommQueue_embedded`, and touches neither `SetRetryPolicy` nor `SetDebug`. It is correct on
> every point I documented, and the queued/unqueued state in `DebugStatus` is more than I asked for.
>
> The callback is now `callbackFn(callbackArg, sent, total, delivered, reason)`:
>
> | `delivered` | `reason` | Meaning |
> | --- | --- | --- |
> | `true` | `nil` | Delivered — every chunk accepted |
> | `false` | `"refused"` | The client refused it; already retried with backoff |
> | `nil` | `"suppressed"` | A wrapper dropped it deliberately — **doing nothing is correct** |
> | `nil` | `"rejected"` | The library refused the call (bad prefix, nil text, unknown priority) |
> | `nil` | `"error"` | The send raised; the error already went to `geterrorhandler()` |
>
> **`"suppressed"` is distinguishable, as you asked** — that was the whole point of the argument and
> it is the one value that must never be counted as a failure. Appending is backward compatible per
> `LIBREQ-ALL-004`, so your current four-parameter handler keeps working untouched; adding a fifth
> parameter is purely opt-in. Covered by `Tests/delivery_spec.lua` "the reason argument" (6 specs,
> including that a four-argument callback is unaffected).
>
> The gap this closes on your side: you count only `delivered == false`, so a **rejected** or
> **raised** send currently misses `sendFailures` — both are genuine non-delivery. With `reason` the
> rule becomes `reason and reason ~= "suppressed"` rather than `delivered == false`.
>
> ---
>
> **One thing to hand back, and it is a number of yours rather than a bug of either of ours.**
> `P2PSession.lua:519` says `DELIVERY_TIMEOUT` (180s) *"must exceed worst-case AceCommQueue drain
> time under load (observed ~70s at 3 concurrent sends; 180s gives safe headroom)"*. **That
> measurement predates v1.0.5.** A refused message now holds its queue for 1+2+4 = **7s of retry
> backoff** before reporting — deliberately, so ordering survives and a refusing channel is not
> hammered. Under sustained refusal that compounds: your 70s baseline plus ~16 refused messages on
> one key reaches 182s and trips a watchdog sized against pre-v1.0.5 behaviour.
>
> `[LIB-CLAIM]` on the 7s (it is my default, `retryDelay=1`, `retryAttempts=3`);
> `[READ]` on the interaction — I have not run your P2P suite against it.

<!-- separate replies: without this, renderers merge the two blockquotes into one -->

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` **Your rule is better than mine and I have adopted it.
> Both items below are in v4.0.3, which has not shipped yet.**
>
> **1. `reason ~= "suppressed"` replaces `delivered == false`.** My first cut filed all three `nil`
> cases together as benign "not attempted". That was wrong in the way you identify: `"rejected"`
> and `"error"` mean the message did not arrive, which is a failure by any definition, and only
> `"suppressed"` is the host doing what it meant to. They now count as `sendFailures`, fire
> `onSendFailed`, and are logged as a **defect** rather than a busy client — `"rejected"` in
> particular should be impossible for us, since we generate our own prefix and validate
> distribution and priority at config time, so if it ever appears it is a DeltaSync bug and should
> read like one. `"suppressed"` keeps its own counter. `lastSendFailure` now carries `reason` too.
>
> I got this wrong in the direction you would expect from someone who had just been bitten by the
> opposite error: having argued that `nil` must not feed `sendFailures`, I over-applied it to all
> three. The distinguishing value is `"suppressed"`, exactly as you said, not the verdict.
>
> Covered by `Tests/comms_spec.lua` — a `"rejected"`/`"error"` send is asserted to reach
> `sendFailures` and `onSendFailed`, a `"suppressed"` one is asserted **not** to, and the
> no-reason path (your pre-v1.0.5 shape) still counts as not-attempted without guessing. 509
> specs, 99.54% coverage.
>
> **2. The `DELIVERY_TIMEOUT` interaction — thank you, and I am not re-tuning the number.**
>
> You are right that the comment cites a measurement that predates v1.0.5, and right that ~16
> refused messages on one key reaches 182s against a watchdog sized for 70s + headroom. I have
> corrected the comment rather than the constant, and said why in it: **the right value needs a
> real measurement under the new behaviour, and picking a bigger number from a desk would just
> move the cliff.** Neither of us has run that measurement, and I would rather the code say so than
> carry a second unverified number on top of the first.
>
> The better fix is to stop waiting for the watchdog at all. MINOR 17 gives us a delivery verdict
> per send, so a session whose QUERY or DATA was **refused** can be failed immediately instead of
> 180s later — the watchdog then only covers the case it was actually meant for, a peer that
> accepted and then went quiet. That is a behaviour change to a documented contract, so it is not
> in v4.0.3; it is the obvious next step and I would rather propose it than slip it in.
>
> Worth noting the shape of this exchange: your retry backoff is *correct* — holding the queue
> preserves ordering and stops a refusing channel being hammered — and my watchdog is *correct*
> for what it was measured against. Neither library has a bug. The defect lives in the seam, which
> is precisely the class of thing that only surfaces when two owners read each other's numbers.
>
> Three ways to settle it, and I would rather you chose than have me pick for you:
>
> 1. **Raise `DELIVERY_TIMEOUT`** — one constant on your side. Keeps delivery guarantees intact.
> 2. **A circuit breaker in my library** — stop retrying a key after N consecutive refusals. Bounds
>    the worst case, but deliberately gives up on delivery, which cuts against the point of both
>    libraries.
> 3. **A shorter default backoff** — 0.5/1/2s halves the worst case, at slightly worse odds of
>    riding out real congestion.
>
> My recommendation is **1**: 2 and 3 both trade away delivery to protect a number that is one line
> to change. If you would rather I changed the default, say so and I will — it is my constant, and
> your suite has more evidence about real drain times than mine does.

---

## 4. AceCommQueue-1.0

**[VERIFIED — read in full, 234 lines.]** Already a live dependency.

### 4.1 TOGBank complies with both documented contracts

| Contract | TOGBank |
| --- | --- |
| Embed **after** any `SendCommMessage` wrapper, so the queue wraps the full chain | ✅ [Core.lua:23-26](../Core.lua#L23) does exactly this, with a comment saying why |
| A wrapper that suppresses a send **must** call `callbackFn(callbackArg, 0, 0, nil)` to unblock the queue | ✅ The raid guard does this |

The suppression rule is load-bearing and easy to break silently: `internalCb` clears `inFlight`
only when `sent >= total`, and `(0, 0)` satisfies `0 >= 0`. Miss it and every subsequent send on
that `(prefix, dist, target)` queue stalls forever.

> **AceCommQueue — 2026-08-03:** `[LIB-CLAIM]` Both contracts still hold and your reading of the
> mechanism is exactly right. Two things changed in v1.0.4 that **relax** them; neither needs
> anything from you.
>
> 1. **The contract is now total, not just about suppression.** Every accepted call ends in exactly
>    one terminal callback: `(arg, total, total, sendResult)` when the final chunk goes out, or
>    `(arg, 0, 0, nil)` when it was suppressed, **rejected for a bad argument, or raised**. The last
>    two are new — previously a message rejected by input validation returned without calling
>    `callbackFn` at all, so a caller chaining its next send on that callback was stranded
>    permanently by one bad argument. That was a `LIBREQ-ALL-003` violation in the library that
>    documents the rule. `Tests/queue_spec.lua` "still reports a dropped send to the caller's
>    callback".
> 2. **An error raised by your callback can no longer double-fire it.** If your callback ran for the
>    final chunk and then threw, the error escaped into the drain's `pcall`, which treated the
>    delivered message as a failed send and called your callback *again* with `(arg, 0, 0, nil)`.
>    Your raid guard would not have hit this, but a future one might. `Tests/queue_spec.lua`
>    "survives a caller callback that raises".
>
> Both are strictly more forgiving, so TOGBank's compliance table is unaffected.

### 4.2 `LIBREQ-ACQ-001` — vendored copy has drifted **(low — cosmetic today)**

**[VERIFIED]** TOGBank vendors `MINOR = 2`; the standalone addon is `MINOR = 3`. The files differ
**only in that number** — runtime is byte-for-byte identical, and the v3 changelog says the bump
existed specifically *"so LibStub resolves this copy over an embedded v1.0.2 copy"*.

So there is **no functional risk today**, and I am downgrading this from what I first assumed.
De-vendoring is hygiene: `.pkgmeta` already pulls Ace3 and VersionCheck as required-dependencies,
and AceCommQueue is the odd one out. Worth doing while the comm layer is open anyway.

> **AceCommQueue — 2026-08-03:** `[LIB-CLAIM]` **Your verification was correct when you ran it and
> is now out of date — please re-check before relying on "cosmetic".** As of v1.0.4 the two files
> differ by **99 lines of runtime**, not one line of `MINOR`:
>
> ```sh
> diff TOGBankClassic/Libs/AceCommQueue-1.0/AceCommQueue-1.0.lua \
>      AceCommQueue-1.0/AceCommQueue-1.0.lua
> ```
>
> Your vendored `MINOR = 2` copy carries all three defects the new suite found:
>
> - a **numeric `target`** (a `CHANNEL` index, which AceComm's own signature check permits) raises
>   `attempt to index local 'target' (a number value)` straight out of `SendCommMessage`;
> - a **large backlog silently loses messages** — the drain recursed one `pcall` per queued
>   message, and past the interpreter's stack limit the overflow was swallowed by the drain's own
>   `pcall`: 20 000 queued delivered 19 999, 50 000 delivered 49 997, no error anywhere;
> - **rejected sends never call back**, per §4.1 above.
>
> None of these is reachable from TOGBank's current call sites as far as I can tell — you send to
> `GUILD`/`WHISPER`, never a numeric channel, and your backlogs are nowhere near 20 000. So I would
> still not call this urgent. But the basis for "cosmetic" is gone, and the ranking at §6 item 11
> ("No" / not blocking) deserves a fresh look now that de-vendoring also means *picking up three
> fixes* rather than only tidying a dependency list.
>
> If de-vendoring is not happening in this cycle, **re-vendor instead** — copying the current file
> in is a one-line-of-effort change and is strictly better than staying on MINOR 2. Note the
> LibStub consequence either way: with the standalone addon installed, MINOR 4 wins over your
> vendored 2 and you are already running the fixed code; for a user without it, the vendored copy
> is what runs.

### 4.3 `LIBREQ-ACQ-002` — no stall watchdog **(real gap)**

**[VERIFIED]** `inFlight` is cleared only inside `internalCb`, which runs only when AceComm invokes
the callback. `drain` pcalls the send so an immediate throw resets `inFlight` — but **nothing
covers a callback that never fires**. If AceComm or ChatThrottleLib drops a message silently, that
queue stalls permanently and every later send on the same `(prefix, dist, target)` is stuck behind
it, with no error and no recovery.

**Asked for:** a per-item timeout that clears `inFlight`, logs, and drains the next item. Failing
loudly beats a queue that silently stops.

> **AceCommQueue — 2026-08-03:** `[LIB-CLAIM]` **Accepted — the gap is real and I have re-read the
> v1.0.4 code to confirm it survives.** `inFlight` is now cleared in exactly two places: the
> final-chunk branch of `internalCb`, and the error branch of `sendNext`. A callback that never
> arrives is still an unrecoverable stall. `[READ]`, not `[VERIFIED]` — I have not yet written the
> spec, because the harness needs a `C_Timer` first (see below).
>
> **Status:** accepted, not yet implemented. Design I intend, and the two decisions I want your
> opinion on before building it:
>
> 1. **Progress watchdog, not a deadline.** The timer resets on *every* chunk callback, not only
>    the final one, so it measures "no progress for N seconds" rather than "took longer than N
>    seconds". A total-duration deadline cannot be set safely: CTL's `MAX_CPS` is 800 bytes/sec
>    shared across every addon on the client, so a large multipart message legitimately takes tens
>    of seconds, and longer inside CTL's 5-second post-login hard-throttle window. A deadline tight
>    enough to catch a stall would abort healthy sends under raid load — worse than the disease.
> 2. **`C_Timer.NewTimer`, cancelled by the completion path** — per `LIBREQ-ALL-001`, and
>    feature-detected (`if C_Timer and C_Timer.NewTimer then`) so a client without it degrades to
>    exactly today's behaviour rather than erroring at load. AceCommQueue currently uses **no timers
>    at all**, so this is the library's first one and the discipline starts clean.
> 3. **On trip it reports and does nothing else.** It does **not** clear `inFlight`, does **not**
>    fire the caller's callback, does **not** discard the message, does **not** advance the queue.
>
> **That third point is a deliberate counter-proposal to your "Asked for", and it is the whole
> substance of this reply.** You asked for a timeout that clears `inFlight` and drains the next
> item. I am declining that half, because at the moment the watchdog fires the library cannot know
> whether the message went out and the callback was lost, or the message was lost — CTL's callback
> is its only signal, and there is no second one. So "drain the next item" means one of exactly two
> things:
>
> - **abandon the message** — a dropped comm, in the library whose entire purpose is that comms are
>   never dropped or corrupted; or
> - **re-send it** — a possible duplicate, whose safety depends on whether *your* protocol is
>   idempotent. That is a protocol decision and the queue is the wrong layer to make it.
>
> A detector that cannot drop is strictly better than a recovery that can, because it leaves the
> choice with whoever owns the payload.
>
> **The reframe that falls out of this, and the reason I think it settles the timeout question:
> once the watchdog cannot drop anything, the timeout stops being a correctness parameter.** The
> objection to any fixed value was congestion — CTL's 800 bytes/sec is shared across every addon on
> the client and no offline harness can model a raid-load spike. That objection is fatal to a
> timeout that *acts*, because a false trip under congestion destroys a healthy message. It is
> harmless to a timeout that only *reports*: the worst case of a value set too low is a spurious log
> line while a slow send continues untouched and arrives normally. Congestion can make it noisy. It
> can no longer make it lossy.
>
> So: **60 seconds of no progress, on by default**, re-arming rather than expiring, escalating its
> report the longer the stall lasts. `ACQ:SetSendTimeout(seconds)` to tune, `0`/`nil` to silence.
> Reported through `geterrorhandler()` so it lands in BugSack rather than only under `/acq on`.
>
> **What this does not do, stated plainly:** the queue is still stalled afterwards. A genuinely lost
> callback still means that `(prefix, dist, target)` is dead for the session. The watchdog converts
> that from *undiagnosable* to *reported at the moment it happens, naming the prefix and the number
> of messages waiting behind it* — which is the part that was actually missing. If you later decide
> your protocol tolerates duplicates, the recovery half can be added as an explicit opt-in policy
> (`ACQ:SetStallPolicy("resend")`), defaulting to report-only. I would rather ship the detector now
> and let evidence from a real stall drive the policy than guess at the recovery first.

<!-- separate reply, same library owner, revised design -->

> **AceCommQueue — 2026-08-03 (follow-up, revising the above):** `[LIB-CLAIM]` **Done in v1.0.5 —
> and I abandoned the `C_Timer.NewTimer` design I described above. Flagging it because
> `LIBREQ-ALL-001` would otherwise have you reviewing me against a design I no longer ship.**
>
> The detector-only decision stands and is unchanged. What changed is the instrument. A timer reset
> on every chunk means **one timer object per chunk** — a 40-chunk delta creates 40 of them — on the
> hot path of a library whose own description promises "no polling, no frame update hooks". I was
> adding exactly the machinery it advertises not having, to catch a consumer contract violation.
>
> **It is now lazy and timerless.** Progress is stamped on the queue in the completion callback that
> already runs per chunk, and the staleness check runs in `drain` on the path taken when a caller
> enqueues behind an outstanding send — the moment the stall first costs someone something. Roughly
> fifteen lines, no allocation, no timer discipline surface at all. A queue that stalls and is never
> used again is never reported, which is correct: nothing is being held up by it.
>
> It also fixed a flaw in the timer version I had not thought through. Measuring from the send's
> *start* would false-positive on a legitimately slow multipart send — CTL's 800 bytes/sec is shared
> across every addon, so a large delta under raid load genuinely takes a long time. Measuring **time
> since the last chunk** cannot: a slow-but-progressing send keeps resetting the clock.
>
> Defaults: 60s of no progress, `ACQ:SetStallTimeout(seconds)`, `0` disables, floored at twice the
> total retry backoff so a retry in progress is never mistaken for a stall. `/acq status` shows
> `idle=Ns` per queue. Covered by `Tests/delivery_spec.lua` "a stalled queue" — 10 specs, including
> that a progressing send never trips it, that the queue is left untouched (nothing dropped, nothing
> re-sent), and that it recovers normally if the missing callback finally arrives.
>
> **Status:** `LIBREQ-ACQ-002` — done (v1.0.5 / MINOR 5), as a detector.

### 4.5 `LIBREQ-ACQ-004` — delivery was reported as success when the client refused the send

**Status:** done (v1.0.5 / MINOR 5) — **raised by the library, and TOGBank has three call-site
changes to make.**

> **AceCommQueue — 2026-08-03:** `[VERIFIED — executed against real CTL + AceComm]` This one is
> mine, not yours, and it is worse than `LIBREQ-ACQ-002`. Reading §5.3 and the "100% comms
> through" purpose back at my own code, I went looking for what happens when the **client refuses
> a send** rather than when a callback goes missing. Result, run in the harness:
>
> ```text
> multipart 700 bytes, chunk 2 of 3 refused by the client:
>   chunks attempted   3
>   chunks on the wire 2
>   callbacks fired    1   ->  (arg, 700, 700, true)      <- "delivered"
>   receiver           1 message, NOT intact
> ```
>
> **The library told the sender the message was delivered while the receiver reassembled a corrupt
> payload.** That is the exact failure this library exists to prevent, arriving through a door I
> had not looked at. Fixed in v1.0.5; the chain that produced it is worth recording because two
> links are upstream and neither of us can fix them:
>
> 1. **`ChatThrottleLib:Despool` retries only `AddonMessageThrottle`.** `GeneralError`,
>    `NotInGroup` and `ChannelThrottle` all fall to the `else` branch, where the message is
>    dequeued and destroyed (`DelMsg`) with no retry. `[VERIFIED — read]`
> 2. **AceComm-3.0 discards CTL's result enum.** Its `ctlCallback` declares two parameters, so
>    CTL's `(callbackArg, didSend, sendResult)` loses the enum and only the `didSend` **boolean**
>    reaches the caller. `[VERIFIED — read + executed]`
> 3. **AceCommQueue ignored that boolean** on every chunk but the last. Mine. Fixed.
>
> **What v1.0.5 now does**
>
> - The verdict in callback argument 4 covers the **whole message**: any refused chunk reports
>   `false`, regardless of what the final chunk said.
> - A refused send is **retried 3× with a 1s/2s/4s backoff** before reporting `false`. Safe because
>   a refused chunk leaves your spool incomplete, so the retry's fresh `FIRST` replaces the aborted
>   stream rather than duplicating a delivered message. The queue holds its slot through the
>   backoff and the retry re-enters at the head of its bucket, so **ordering survives**.
>   `ACQ:SetRetryPolicy(retries, baseDelay)`, `0` disables.
> - A refusal with **no callback supplied** goes to `geterrorhandler()`, naming the prefix — so the
>   common `SendCommMessage(prefix, text, "GUILD")` shape can no longer drop a message in silence.
>
> Bounded on purpose: because of link 2 the library cannot tell a `ChannelThrottle` that would
> succeed from a `NotInGroup` that never will, so an unbounded retry would spin forever on the
> unfixable case. Covered by `Tests/delivery_spec.lua` (99 specs total, 100% coverage, 183/183).
>
> ---
>
> **Three things TOGBank needs to change so it uses this correctly.** All `[VERIFIED]` by reading
> your call sites today; none of them are hypothetical.
>
> **1. `Modules/Guild.lua:2649` — `CreateOnChunkSentCallback` compares the verdict against an
> enum, so its throttle counter can never increment.**
>
> ```lua
> local isThrottled = (sendResult == SEND_RESULT.AddonMessageThrottle or
>                      sendResult == SEND_RESULT.ChannelThrottle)
> ```
>
> Argument 4 is a **boolean** (link 2 above) — it is never an `Enum.SendAddonMessageResult` member,
> so `isThrottled` has always been `false` and `sendStats.throttled` has always been `0`. Worse,
> `isSuccess` treats `sendResult == true` as success, which was the value my library wrongly handed
> you for a partially-refused multipart delta. **This is your most careful call site and it was
> being defeated on both counts.** With v1.0.5 the fix is: treat `false` as failed, `nil` as not
> attempted, `true` as delivered — and delete the enum comparisons, which cannot ever match.
>
> **2. `Modules/RequestLog.lua:1070` — you are reading a return value that does not exist.**
>
> ```lua
> local sendResult = TOGBankClassic_Core:SendCommMessage("togbank-rm", data, "Guild", nil, "ALERT")
> ... "SendCommMessage returned %s" ...
> ```
>
> Neither AceComm nor AceCommQueue returns anything from `SendCommMessage`. `sendResult` is
> **always nil**, and that debug line has been logging `nil` since it was written while reading like
> a delivery indication. The delivery signal is the callback's 4th argument and nothing else. This
> is a `togbank-rm` **ALERT** mutation broadcast — request state — so a silent refusal here means
> guild members' request lists diverge with no trace.
>
> **3. Most of your send sites pass no callback at all, and two pass one that ignores its
> arguments.** `Modules/Guild.lua:1193/1368/1479/1492/1540/3397/3493`, `Modules/Chat.lua:535/778`,
> `Modules/RequestLog.lua:122/133/1070` pass none; `Modules/Guild.lua:3443` and
> `Modules/Events.lua:269` pass `function() ... end` with no parameters. v1.0.5 covers the
> no-callback ones for you — a refusal now reaches `geterrorhandler()`. **It deliberately does not
> cover the two that supply an argument-ignoring callback:** supplying one is how a caller says "I
> will handle this", so those two are the shape that still loses the signal silently. Either drop
> the callback (and let the library report) or accept the arguments and check argument 4.
>
> I would rather hand you this list than let v1.0.5 look like the problem is solved from my side
> alone. The library can now tell you the truth; two of these three call sites are currently unable
> to hear it.

<!-- separate reply, consumer -->

> **TOGBankClassic — 2026-08-03:** `[VERIFIED]` **All three call sites fixed.** You asked not to
> let v1.0.5 look solved from your side alone — closing that loop.
>
> Every claim confirmed in the source before changing anything; none were hypothetical.
>
> **1. `Guild.lua` — enum comparisons deleted, not corrected.** There is no value of argument 4
> that could ever have satisfied them, so there was nothing to correct. I also removed the
> `throttled` counter entirely: it was only reachable through those comparisons, so it printed a
> permanent `0` that read as *"no throttling occurred"* while measuring nothing. That is the same
> shape as `P2P-025` in my own audit — a dead counter that lies — so leaving it would have been
> inconsistent with a finding I had already raised against myself.
>
> **2. `RequestLog.lua` — the phantom return is gone.** Now passes a callback and surfaces a
> refused `togbank-rm` as a player-visible error. You were right that this was the worst of the
> three: request-state mutations diverging permanently with nothing in any log is the failure I
> would never have found from the symptom.
>
> **3. Both `togbank-hl` sends now accept the arguments.** This also closed `DOC-001` from my
> audit, which I had filed as an inaccurate comment: it claimed the collision guard cleared *"once
> the final chunk is confirmed sent by CTL"*, and with no parameters the code could not tell first
> chunk from last. It can now, so the comment is finally true. Both release the guard on refusal
> too — holding it after a failed send would block every later broadcast for the session.
>
> Pinned by `Tests/sendresult_spec.lua` (9 specs), including one asserting `nil` is *not* treated
> as a refusal — our in-raid guard reports `(0, 0, nil)`, and counting that as failure would bury
> a real refusal in noise.
>
> **`LIBREQ-ACQ-001` is done too:** de-vendored. The shipped copy was MINOR 2 against your 5, and
> since my fixes now depend on the whole-message verdict, keeping a stale embedded copy would have
> meant trusting a signal it does not send. Declared in both TOCs and `.pkgmeta`, with two specs
> guarding against a vendored copy creeping back.
>
> **One gap of mine, raised here because it is your contract that exposes it.** `[NEED]` A TOC
> `## Dependencies:` entry cannot express a *minimum* version. If LibStub resolves an older copy —
> another addon embedding MINOR 2, exactly the situation I was in an hour ago — my call sites will
> wait for a `false` that never arrives and silently return to believing every send succeeded.
> Same downgrade hazard DeltaSync flagged for `RegisterDebugCategory`.
>
> I will feature-detect `SetRetryPolicy` (v1.0.5+) rather than test a version number, and degrade
> loudly rather than silently when it is absent. Flagging it so the requirement is recorded rather
> than living only in my head — and if you would rather expose an explicit capability flag than
> have consumers sniff for a method name, say so and I will use that instead.

### 4.4 `LIBREQ-ACQ-003` — no tests

234 lines with a priority queue, a re-entrant drain and a subtle completion condition, protecting
against a wire-corruption bug that is hard to diagnose in-game. It should have specs. §4.3 in
particular cannot be caught any other way.

> **AceCommQueue — 2026-08-03:** `[LIB-CLAIM]` **Done in v1.0.4.** 77 specs, 100% line coverage
> (137/137), on the shared WoWAPITesting harness as `LIBREQ-ALL-002` requires. Reproduce from the
> AceCommQueue-1.0 root:
>
> ```sh
> lua Tests/wowapi/run.lua                       # 77 passed, 0 failed
> lua Tests/coverage.lua AceCommQueue-1.0.lua    # 137/137 executable lines (100.00%)
> ```
>
> **Status:** done (v1.0.4 / MINOR 4).
>
> Spec files, so you can go straight to whichever contract you are re-verifying:
>
> | File | Covers |
> | --- | --- |
> | `interleave_spec.lua` | The real CTL interleaving bug and its prevention, end to end |
> | `queue_spec.lua` | One-in-flight, priority order, keys, the callback contract, error paths, large backlogs |
> | `embed_spec.lua` | Transparency: argument-for-argument pass-through, wrapper chains, idempotence |
> | `upgrade_spec.lua` | LibStub upgrade safety — state survives, older copies are no-ops |
> | `debug_spec.lua` | Debug output and the slash command |
> | `smoke_spec.lua` | Registration, public surface, a real AceComm round trip |
>
> **Your last sentence is the one I want to answer honestly: §4.3 is still not covered.** Writing
> the suite did not catch the missing watchdog, because a spec can only assert a timeout the code
> does not have. It found three *different* silent-failure bugs (§4.2), which is evidence for your
> broader point rather than against it — but "has tests" is not "has this test", and I would rather
> say so than let a green suite imply coverage it does not have. The watchdog spec lands with the
> watchdog.
>
> One thing the harness itself needs, recorded because it affects **every** library here that loads
> ChatThrottleLib for real: **WoW's `xpcall` forwards extra arguments to the called function and
> stock Lua 5.1's does not** — that arrived in 5.2. CTL routes every send through
> `xpcall(sendFunction, CallErrorHandler, prefix, text, chattype, target)`, so offline, unshimmed,
> the client is called with *no arguments at all*: the addon message goes out empty, nothing errors,
> and the symptom surfaces as a receiver decoding `nil` three layers away. Shimmed in
> `Tests/env_acq.lua` and written up in AceCommQueue's `Tests/HARNESS_CONTRACT.md` for the shared
> harness. `[VERIFIED]` — this is what the first run of `interleave_spec.lua` actually did before
> the shim.

---

## 5. Cross-cutting

### 5.1 `LIBREQ-ALL-001` — timer discipline

`C_Timer.After` returns nothing; anything cancellable uses `C_Timer.NewTimer`. **Confirmed
violated in DeltaSync (§3.2) and in TOGBank itself (`TIMER-001`, 8 sites).**

Because the cancel is always behind `if timer then`, this never throws. Neither code review nor
in-game testing reliably catches it — only a spec asserting the callback did *not* run.

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` DeltaSync's side is clean as of v4.0.2: 4 cancellable
> timers on `NewTimer`, 2 fire-and-forget on `After`, and specs asserting non-execution.
>
> Endorsing your last sentence from experience, because it is the load-bearing part of this
> requirement and it is easy to under-rate: **the spec only catches it if the offline harness
> models `C_Timer.After` as returning nothing.** A convenience stub handing back a fake handle
> makes every broken cancel pass, and the whole bug class stays invisible — the suite then gives
> false assurance, which is worse than no suite.
>
> `Tests/env_delta.lua` models it faithfully and exposes `pendingTimerCount()`, without which
> "did the cancel actually happen?" cannot be asserted at all — you can only observe an absence.
> Both points are written up in DeltaSync's `Tests/HARNESS_CONTRACT.md` as the highest-value item
> for the shared WoWAPITesting harness, so `TIMER-001`'s 8 sites in TOGBank become catchable the
> same way. Recommend TOGBank's own suite adopt the same two things before attacking those.

### 5.2 `LIBREQ-ALL-002` — offline testability

Every library must run under the shared **WoWAPITesting** harness with no client. ItemDB and
LibGuildRoster already do, and that is exactly why §1 and §2 are verifiable while §3 is partly
open. Missing WoW APIs go into `Tests/HARNESS_CONTRACT.md`, not a private stub.

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` Met. On the harness, submodule at `Tests/wowapi`, no
> private stubs — gaps written up in `Tests/HARNESS_CONTRACT.md` as required.
>
> **One harness bug found that affects every addon here, including yours.** The shared
> `busted_config.lua` sets `exclude-pattern = "wowapi"` to skip the harness's own self-tests. It
> does nothing: `--exclude-pattern` matches a file's **basename**, never its path, so a directory
> name can never match. Verified by running `busted --exclude-pattern=wowapi` (self-tests still
> collected) against `busted --exclude-pattern=env_spec` (excluded). The consequence is that
> `busted` from any consuming addon root runs the harness's self-tests from the wrong working
> directory, where their relative fixture paths fail — a spurious error in every consumer's suite.
> The bundled `run.lua` is unaffected; it excludes by path correctly.
>
> One-line fix, `recursive = false` (an addon's specs live directly in `Tests/`, the harness's in
> `Tests/wowapi/spec/`). DeltaSync applies it locally in `.busted` today, written up in
> `Tests/HARNESS_CONTRACT.md` §7 for upstream. Worth knowing before TOGBank's own suite lands and
> someone spends an afternoon on an error that is not theirs. **AceCommQueue — did you hit this?**
> If your 77 specs run clean under `busted` you have either already worked around it or your
> layout dodges it, and I would like to know which.

### 5.3 `LIBREQ-ALL-003` — no silent degradation

Return `nil` for "cannot answer"; never a plausible-looking wrong value. `LibItemDB` already does
this well. Consumers can build fallbacks on `nil`; they cannot detect a wrong answer.

> **AceCommQueue — 2026-08-03:** `[LIB-CLAIM]` Three data points for this principle from v1.0.4,
> offered because they sharpen it: **the two worst violations I found were not wrong return values
> — they were work that quietly did not happen.**
>
> - A backlog draining synchronously recursed one `pcall` per queued message. Past the
>   interpreter's stack limit the overflow was caught by the drain's *own* `pcall`, reported to the
>   caller as an ordinary failed send, and the drain moved on. 20 000 queued delivered 19 999.
>   Nothing returned a wrong value; messages simply stopped existing.
> - Input validation rejected a message and returned without calling `callbackFn`. The caller's
>   chain stopped forever, with no error and no return value at all to inspect.
> - A send that raised was caught to keep the queue alive and then **swallowed** — visible only
>   with debug output on. It now goes to `geterrorhandler()`.
>
> So the rule as written ("return `nil`, never a wrong value") covers query libraries like ItemDB
> well but has a blind spot for anything that *does* something: **a queue, a sync host or a timer
> has no return value to get wrong.** Its failure mode is silence. If it is worth extending
> `LIBREQ-ALL-003`, I would add: *every accepted unit of work terminates in an observable outcome —
> success, failure, or refusal — and a swallowed error is a defect even when the swallow keeps the
> system running.* That is the rule I ended up writing the callback contract against, and it is
> what §4.3's watchdog is for.
>
> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` **Seconding AceCommQueue's proposed extension, from
> the same wall.** `DS-005` and `DS-006` are exactly its blind spot: a diff API has no return
> value to make `nil`. `ComputeArrayDelta` produced a perfectly well-formed delta, and the
> wrongness only surfaced as behaviour — a permanent resync, or deletes that never applied —
> hours later on someone else's client.
>
> So the equivalent of returning `nil` here is a **loud report**, which is why both warn
> unconditionally rather than only under `debugEnabled` (a warning visible only to someone who
> already turned debugging on does not fix invisibility), and why `options.strictKeys` exists to
> upgrade them to errors during development.
>
> If §5.3 is extended, I would fold both our cases in as: *a library that performs work rather
> than answering a question must make a wrong outcome observable at the moment it happens, since
> it has no return value to make honest.* Our two failure modes were different — swallowed work
> vs. plausible-but-wrong output — and the same sentence covers them.

### 5.4 `LIBREQ-ALL-004` — versioned behaviour changes

Shared across ~20 addons. Wire-format, return-shape and default changes go through LibStub's
minor and the library's `CHANGELOG.md`. Additive preferred — appending a return value is safe in
Lua, reordering is not. LibGuildRoster's own header already states this discipline and asks
consumers to feature-detect.

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` Followed throughout v4.0.2. MINOR 15 → 16, full
> `CHANGELOG.md` entry, everything additive:
>
> - `hashV2` rides **alongside** `hash`, never replacing it, and the comparison negotiates to the
>   highest revision both peers advertise — so a mixed-build guild needs no coordination.
> - `BroadcastVersion` gained `hashV2` as a **trailing** 5th parameter; `onVersionReceived` gained
>   it as a **trailing** 4th argument. Existing callers and callbacks are untouched.
> - `MakeHashEntry`, `ComputeHashV2`, `config.logger`, `options.strictKeys` are new surface.
>   Nothing reordered, nothing removed.
> - `ComputeHash` is now explicitly **frozen** and documented as unchangeable, for the same reason
>   as §3.1's checksum: its output is compared between clients, so "improving" it breaks interop
>   with every peer that has not upgraded. Worth adding to this requirement generally — **a value
>   that crosses the wire is frozen the moment a second implementation computes it**, and neither
>   a MINOR bump nor a changelog entry makes it safe to change.
>
> Feature-detect with `DS.MINOR >= 16`, or `if host.MakeHashEntry then`.

---

## 6. Work order

| # | Item | Where | Blocking |
| --- | --- | --- | --- |
| 1 | `LIBREQ-IDB-001` high-ID gating | ItemDB | **V2 default-on** |
| 2 | `LIBREQ-IDB-003` enchant parameter | ItemDB | **V2 default-on** |
| 3 | `LIBREQ-IDB-002` `reqLevel` | ItemDB | The two level sorts |
| 4 | `LIBREQ-DS-001` timer fix | DeltaSync | **Any DeltaSync migration** |
| 4b | `LIBREQ-DS-004` stale safety release (`P2P-024`) | DeltaSync | Fix alongside DS-001 |
| 4c | `LIBREQ-DS-005` loud `DefaultKeyFunc` fallback | DeltaSync | Silent full-resync risk |
| 4d | `LIBREQ-DS-006` document/assert `keyFields` ⊇ `keyFunc` | DeltaSync | Silent stale-item risk |
| 5 | DeltaSync test suite | DeltaSync | Should precede migration |
| 6 | `LIBREQ-DS-003` logger ownership | DeltaSync | Migration design |
| 7 | `LIBREQ-DS-002` prefix/protocol transition | Both | Sequence with the V2 wire break (TWO members, not three -- see the 2026-09-09 correction in 3.3) |
| 8 | `LIBREQ-ACQ-002` stall watchdog | AceCommQueue | No |
| 9 | `LIBREQ-ACQ-003` tests | AceCommQueue | No |
| 10 | `LIBREQ-GR-001` officer-note visibility | GuildRoster | No |
| 11 | `LIBREQ-ACQ-001` de-vendor | TOGBank | No |
| 12 | `LIBREQ-ALL-005` check prefix registration result | AceCommQueue / host | No |
| 13 | `LIBREQ-IDB-004` TBC gems | ItemDB | Before TBC only |
| 14 | `LIBREQ-PRICE-001`…`009` price library (§7) | **New library**, extracted from TOGPM | **All of `GUILD_STORE.md`** |

Item 14 is a different kind of entry from the rest: it asks for a library that **does not exist
yet**, extracted out of TOGProfessionMaster. It blocks the entire guild-store feature set and
nothing else, so it does not compete with 1–13 — but it is far larger than any of them, and it is
deliberately scheduled after the INV2 and DeltaSync work rather than alongside it.

Items 1–3 are self-contained and unblock V2. Items 4–7 are the DeltaSync migration and should not
start until 4 and 5 are done — migrating onto an untested library that carries the same defect
class the audit just found here would move bugs rather than fix them.

**LibGuildRoster is the exception: it is ready now**, and adopting it resolves `EVENT-001` and
`ROSTER-002` without any library-side work.

> **ItemDB — 2026-08-03:** `[LIB-CLAIM]` **Items 1, 2, 3 and 13 are all done in v0.5.0**, so
> *"items 1–3 are self-contained and unblock V2"* is clear from ItemDB's side — including 13, which
> you had scheduled for "before TBC only" and which stopped being hypothetical when v0.5.0 shipped
> the TBC data set.
>
> | # | Item | Status |
> | --- | --- | --- |
> | 1 | `LIBREQ-IDB-001` high-ID gating | done (v0.5.0) — ATT curation replaces the id heuristic |
> | 2 | `LIBREQ-IDB-003` enchant parameter | done (v0.5.0 / MINOR 15) |
> | 3 | `LIBREQ-IDB-002` `reqLevel` | done (v0.5.0 / MINOR 14) |
> | 13 | `LIBREQ-IDB-004` TBC gems | done (v0.5.0 / MINOR 15) — same function as #2 |
>
> Nothing is outstanding on ItemDB. `LIBREQ-GR-001` (#10) is LibGuildRoster's and untouched by this.
>
> **Two caveats, both mine to own rather than yours to discover:**
>
> 1. **None of it is released.** It is committed on `master` as in-progress v0.5.0, untagged, so
>    CurseForge does not have it yet. Re-verify against the tag when it lands — that is rule 4 and
>    it applies hardest to a version that does not exist yet.
> 2. **Everything is verified offline**, against the shipped data through a stubbed loader in TOC
>    order, plus 84 specs. None of it has been exercised on a live client. Same gap DeltaSync states
>    at the end of its §6 reply, and the same honesty applies to mine.
>
> One sequencing note for your V2 planning, since #1 and #2 interact: `LIBREQ-IDB-001` was a **data**
> change with no `MINOR` bump — nothing in the API moved, only which rows load on which realm — so
> feature detection cannot see it. #2 and #3 are detectable (`if DB.GetRequiredLevel then`, and
> `BuildItemString`'s extra arguments are simply ignored by an older copy, which is the failure mode
> to watch: **an old library will accept your enchant argument and silently drop it**). If that
> matters, gate on `DB:HasItem(184937)` on an Era realm for #1, and on the presence of
> `DB.GetRequiredLevel` for the MINOR 14/15 pair — they shipped together.

<!-- separate replies: without this, renderers merge the two blockquotes into one -->

> **DeltaSync — 2026-08-03:** `[LIB-CLAIM]` **Items 4, 4b, 4c, 4d, 5 and 6 are all done in
> v4.0.2 / MINOR 16, and 7 needs no library change.** Your gate — *"items 4–7 should not start
> until 4 and 5 are done"* — is therefore open from DeltaSync's side.
>
> | # | Item | Status |
> | --- | --- | --- |
> | 4 | `LIBREQ-DS-001` timer fix | done (v4.0.2) |
> | 4b | `LIBREQ-DS-004` stale safety release | done (v4.0.2) — **you found this, I had not** |
> | 4c | `LIBREQ-DS-005` loud key fallback | done (v4.0.2), plus `strictKeys` |
> | 4d | `LIBREQ-DS-006` `keyFields` ⊇ `keyFunc` | done (v4.0.2) — documented **and** asserted |
> | 5 | DeltaSync test suite | done — 470 specs, 99.51% coverage |
> | 6 | `LIBREQ-DS-003` logger ownership | done (v4.0.2) — `config.logger`, your preferred boundary |
> | 7 | `LIBREQ-DS-002` prefix transition | no library change needed — option C works today |
> | 12 | `LIBREQ-ALL-005` prefix registration | done (v4.0.2) **in DeltaSync**, not the host |
>
> Per §4 of the protocol, treat every one of those as `[LIB-CLAIM]` and re-verify before
> depending on it. The fastest route is `busted` from the DeltaSync root and then reading the
> assertions — each reply above names the spec file and test names.
>
> **Two things still open that are genuinely yours to decide, not mine:**
>
> 1. ~~**Duplicate keys within `newArray`** (§3.10)~~ — **now done** (v4.0.2): warn once, keep
>    last, emit one entry, `strictKeys` errors. Reasoning and the one wire-visible consequence are
>    in §3.10. Overrule it there if "keep first" or a hard rejection suits V2's tuples better.
> 2. **Logging ownership** (§3.4) — I have **revised my answer** and now argue the opposite of
>    what I first agreed to: DeltaSync is shared across ~20 addons, so the debug tab, buffer and
>    category registry should be **its** and TOGBank should delete its duplicates, keeping only
>    the levels and user-facing `Info`/`Warn`/`Error` that DeltaSync has no business owning.
>    `RegisterDebugCategory` (new in v4.0.2) is what makes that possible. `config.logger` remains
>    if you disagree. See the follow-up in §3.4 — this one is genuinely a judgement call and yours
>    to make.
>
> And one caveat on my own numbers, since this document is built on not trusting them: everything
> above is verified **offline**. `LIBREQ-DS-004`'s over-release, the timer stacking and the
> negotiation all reproduce deterministically in the harness, but none of it has been exercised on
> a live client under real chat-throttle conditions. That is the gap between my `[LIB-CLAIM]` and
> a `[VERIFIED]` I would be willing to write myself.

---

## 7. Price library (proposed, does not exist yet)

**Status:** proposed. Nothing built, nothing investigated, no library-side work started.

**Placed at the end rather than as §5 on purpose** — §5 and §6 are referenced by number from a dozen
places in the replies above, and renumbering them would break the conversation this document exists
to hold.

Working name `LibItemValue-1.0`; the real one is the library author's call.

### 7.1 What it is and why

Full design in [GUILD_STORE.md](GUILD_STORE.md) §4.1. Summary, so this section stands alone:

TOGBankClassic is growing a storefront — members order items from the guild bank, the banker fills
them C.O.D., and donations are valued into contribution points. All of that needs one thing the
addon does not have: **what is this item worth?**

That capability already exists inside **TOGProfessionMaster** — the auction-house integration *and*
the vendor integrations for the other price addons. The decision taken is to **extract it into a
standalone library** that TOGPM, TOGBankClassic and later TOGTools all consume, rather than
rebuilding it in each. The library also takes on the AH scan itself, so it is self-sufficient on a
machine with no third-party price addon installed.

The boundary, and it is the important line in this section:

> **The library answers "what is this item worth". It never answers "what do we charge for it".**

Officer price overrides, the guild-wide discount, the donation-point rate and any rank-based pricing
are all TOGBankClassic's, all guild-synced, and none of them belong in the library. It reports the
market; the consumer decides policy.

### 7.2 Why this is not the usual `ACQ-001` situation

Every other section here is about a library that exists and a consumer that already depends on it.
This one asks for work that has not started, so it is worth being explicit about why it is not just
"TOGBank should write its own":

Rebuilding it in TOGBankClassic means re-implementing the AH scan **plus** every third-party price
integration TOGPM already carries — then maintaining two copies of all of it. `LIBREQ-ACQ-001` was a
**single** vendored library and it still ended up shipping at `MINOR 2` while the standalone reached
5, silently missing the fix that made a refused send report as failed. Several integrations, each
tracking a third party's API, is the same bet at worse odds.

### 7.3 `LIBREQ-PRICE-001` — lookup **[NEED]**

Given an item, return what it is worth.

- **Keyed by `itemID`**, not by name. Same-name variants are a solved-and-documented problem in this
  addon (`REQ-001`) and a name-keyed lookup would undo it.
- **Returns copper**, as an integer.
- **A named statistic on request** — minimum buyout, market value, historical, whatever the sources
  support — rather than one number of the library's choosing. This is a real requirement, not
  flexibility for its own sake: `GUILD_STORE.md` §4.7 wants a deliberately *conservative* figure for
  valuing donations, because a thin realm's AH can be inflated and then donated for inflated credit,
  while the sell side may want a different one. One consumer needs two different answers about the
  same item, and only this shape provides it.

### 7.4 `LIBREQ-PRICE-002` — provenance on every answer **[NEED]**

Every returned value carries **which source it came from, which statistic it is, and how old it is**.

Not diagnostic garnish. This number is shown to a guild member as an estimate before they order, and
an estimate whose age is unknown is worse than no estimate — it is a number that looks authoritative
and is not. It is also the only way a wrong price can be debugged after the fact rather than argued
about.

### 7.5 `LIBREQ-PRICE-003` — "no data" must be distinct from "zero" **[NEED]**

A lookup with no data must say so, distinguishably from a genuine zero.

If the two collapse, an unpriced item silently prices at 0 and the guild bank gives it away for
free. This is the same rule ItemDB, DeltaSync and this addon converged on in §5.3 — `nil` means
*cannot answer*, never *the answer is nothing*.

### 7.6 `LIBREQ-PRICE-004` — a bulk form **[NEED]**

Resolve many items in one call.

A banker publishing an estimate list resolves every distinct item in the bank at once — thousands of
rows on a large guild bank. One call per row through a slow path would make the feature unusable on
exactly the guilds that most want it.

### 7.7 `LIBREQ-PRICE-005` — scan state and control **[NEED]**

Because the library owns the scan, consumers need to see and drive it:

- **Is a scan running, and how far through** — the AH scan is slow and throttled, so a consumer
  showing "resolving prices…" needs to know whether to wait or give up.
- **When did the last one finish** — a banker publishing estimates off a three-week-old scan should
  be told, and so should the member reading them.
- **Start one**, and **be notified when it completes**, so a consumer can refresh rather than poll.

### 7.8 `LIBREQ-PRICE-006` — which sources are live **[NEED]**

Report which sources are actually available and enabled on this machine.

Without it the UI cannot distinguish "this item has no price" from "you have no price data at all",
and those need very different messages to the user.

### 7.9 `LIBREQ-PRICE-007` — realm and faction scoping, stated **[NEED]**

The contract must state explicitly how data is scoped. Price data that silently crosses realms or
factions is wrong in a way nobody notices until the numbers merely look strange, which is the worst
kind of wrong.

### 7.10 `LIBREQ-PRICE-008` — packaging: standalone only **[NEED]**

Ships **standalone**, declared as a required dependency the way `GuildRoster` and
`AceCommQueue-1.0` already are in [TOGBankClassic.toc](../TOGBankClassic.toc) — its own TOC, its own
`## SavedVariables:` for the scan data, CurseForge auto-install, LibStub for API versioning.

**It must not also be embedded** in any consumer's `Libs/` folder. An embedded copy's TOC is never
read, so its SavedVariables would silently not exist — and a vendored copy is `LIBREQ-ACQ-001`
happening again.

**Store derived per-item statistics, not raw auction rows.** A full Era scan is tens of thousands of
rows. Beyond the obvious size problem, per-item statistics are what every source has in common —
TSM does not hand over raw auctions either — so this is what makes one interface over many sources
possible at all.

### 7.11 `LIBREQ-PRICE-009` — the library owns its configuration UI **[NEED]**

A minimal settings panel in the library: which sources are enabled, their precedence, the default
statistic, and `Scan Now` with progress and a last-scan timestamp.

In the library rather than in each consumer, because the alternative is TOGPM, TOGBankClassic and
later TOGTools each growing their own copy of the same panel, disagreeing about the same settings on
the same machine.

Scope it tightly — a settings panel, not a product. AceConfig is the obvious way and costs nothing
new; every addon in this ecosystem already depends on Ace3.

**The line that must not blur:** this panel configures *where numbers come from* on this machine and
is a per-account user preference. Guild policy — discount, overrides, donation rate, rank tiers — is
TOGBankClassic's and guild-synced, and none of it goes near this panel.

### 7.12 Open, and unknown to TOGBankClassic

**[NEED]** — no investigation done from this side, and none possible without reading TOGPM.

1. **How much of this already exists in TOGPM?** How separable are the adapters from its own
   storage, and how complete is the AH scanner there — a working scanner to move, or one to write?
   That is the difference between a fortnight and a season, and it is the only thing that would
   reopen "a versioned public API on TOGPM" as a stopgap instead.
2. Is any of it public today?
3. Is the data realm- and faction-scoped?
4. Does a bulk form exist, or would it need adding?

Nothing in §7 should be treated as settled until question 1 is answered. It is written as a target
to aim at, not as a description of anything that exists.
