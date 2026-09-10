# Guild Store — pricing, donation credit and C.O.D. fulfillment

**Status:** design, not started. Deferred until the INV2 tuple rework and the DeltaSync migration
are finished — see [INVENTORY_V2.md](INVENTORY_V2.md). Everything here should be re-read against
the code once that lands, because several of the assumptions below are about code that is
currently being replaced.

**Ticket prefix:** `STORE-`.

---

## 1. The reframe

The addon has always been designed for a _guild bank_: a shared pool that members draw from, where
the only scarcity control is "don't take too much" (`maxRequestPercent`). That is not what at least
one guild is using it for.

Their guild bank is an **internally run auction house**. Members put in requests for items, a price
is quoted, and the order is filled **C.O.D. through the mail**. The bank is a shop; the members are
customers; the requests are orders.

Almost every open feature request makes sense as soon as you read it that way. Two separate
conversations turn out to be describing the same system from opposite ends:

| Asked for by | Request | What it is in shop terms |
| --- | --- | --- |
| Pimptasty | Assign value to an item from AH price sources | The price list |
| Pimptasty | Guild-wide % discount off AH, officer-set, synced | The markdown |
| Pimptasty | C.O.D. mail when the banker fills an order | Taking payment |
| Adestar | Officer setting to enable/disable ordering | Open / closed sign |
| Adestar | Tag items as unavailable or not eligible to order | Not for sale |
| Adestar | Guild-rank visibility / ordering filter | Customer tiers |
| Pimptasty | Value donations, weighted into donation points | The receipt, and the other half of the economy |

Read as seven unrelated features this is a grab bag. Read as a storefront it is one coherent system
with an obvious build order, which is why this document treats it as one.

The last row is what makes it an economy rather than a shop. Everything else is members _taking_
things; valuing donations is the direction that puts them back, in the same units.

---

## 2. What already exists to build on

Verified in the current tree, not assumed:

- **The banker's send is already automated.** `Modules/Mail.lua:1248` sets the recipient, attaches
  the items and calls `SendMail(st.requester, "Guild Bank Order", "")`. C.O.D. is an insertion into
  a flow that already exists, not a new flow.
- **`SendMail` is already hooked** (`Modules/Mail.lua:215`, `hooksecurefunc`) for fulfillment
  tracking, so the addon already observes every send.
- **Guild-synced officer settings exist and are auth-checked.** `Guild.Info.settings` +
  `BroadcastSettings` / the receive path (`Modules/Guild.lua:1523` onward) already carry
  `maxRequestPercent`, `autoTombstoneDays`, `cancelReasons` and `helpNotes`. Senders are validated
  (`IsBank` / `SenderIsOfficer` / `SenderIsGM`) and inbound values are sanitized and bounds-checked
  before they are written. New officer settings go here; none of that machinery needs building.
- **Rank data is already on the roster.** `memberRoster[name].rankIndex`, with the ordering rule
  documented at `Modules/Guild.lua:1828`: **lower `rankIndex` = more permissions**, GM is 0.
- **"Visible but not orderable" already exists** as a concept. `VIEW_ONLY_MARKERS`
  (`Modules/Guild.lua:428`) plus the hard gate in `Guild:AddRequest` (`Modules/RequestLog.lua:1731`)
  is exactly Adestar's item-level request in per-toon form. The new gates belong beside it, in the
  same function, for the same reason.
- **The request wire format tolerates new fields.** `togbank-rd2` is positional with a documented
  append-at-the-end convention and `false`/absent tolerance on receive — `itemID` at slot 12 was
  added this way for REQ-001. A price field follows the same path.
- **The price problem is already solved next door.** TOGProfessionMaster carries the auction-house
  integration and the vendor integrations for the other price addons. Auctionator and
  TradeSkillMaster are both installed on this machine, but they are inputs to _that_ layer —
  TOGBank should never learn either name, whether the layer stays in TOGPM or moves to a library.
  See §4.1.

One piece of existing code actively conflicts, and it is the most important thing in this section:

- **`MAIL-002` deliberately ignores C.O.D. mail.** `Modules/MailInventory.lua:55-56` scans incoming
  mail only when `CODAmount == 0`, and `Modules/Mail.lua:175` does the same, on the stated grounds
  that items cannot be taken without paying. That is correct today because no TOG mail is ever
  C.O.D. The moment the bank starts sending C.O.D., that assumption needs re-deriving from scratch
  — see §7.

---

## 3. The central rule: the banker's price is THE price

**Everything a member sees before the order is filled is an ESTIMATE, and every word of UI must say
so.** The price is whatever the banker's TSM says at the moment they fill the order and set the
C.O.D. amount. Nothing else is binding, because nothing else can be — the banker's client is
physically the thing that calls `SetSendMailCOD`, and hours or days can pass between order and fill
while the AH moves underneath both of them.

This is not a limitation to be worked around. It is what makes the rest of the design simple:

- **No quote round-trip.** The member does not have to accept anything; there is nothing to accept.
  Order → fill, exactly as today.
- **No stale-quote problem.** There is no promise to break, so an order sitting for three weeks
  needs no re-pricing protocol and no expiry rule.
- **No argument about whose data is right.** The banker's is, by definition.

The failure mode this design has to avoid is therefore **not** a wrong price — it is a member who
believed the estimate was a price. That is a wording problem, and it gets solved with wording:
"Estimated ~12g" and never "12g"; "Final price is set by the banker when your order is filled" on
the order confirmation; an `~` in the request list. If any surface shows a bare number that could be
mistaken for the amount charged, that surface is wrong.

### 3.1 Where the estimate comes from

Even an estimate has to be computed somewhere, and the same reasoning applies:

> **Only bankers need a price addon. Members need nothing at all.** The bankers pull AH data,
> publish an estimate per item alongside the inventory they already publish, and every member reads
> the same number off the same list. Requiring 200 guild members to install and regularly rescan a
> price addon would kill the feature on contact.

That also makes the estimate _auditable_: what the member saw is what the bank published, with a
timestamp, so a complaint is a stale-list conversation rather than a your-word-against-mine one.

### 3.2 Store the estimate on the order anyway

The estimate is not binding, but it should still be written into the request record — for three
reasons that have nothing to do with contracts:

1. **Disputes.** When a member says "it said 12g and you charged me 40g", the officer needs to see
   what the estimate actually was at order time and where it came from. Without the record there is
   no way to tell a market move from a bug.
2. **Catching mistakes before they are mailed.** The fill UI can show the banker "estimated 12g at
   order → your TSM now says 40g". A 233% jump is usually an AH crash, a mispriced item, or a bad
   scan, and the banker gets to notice _before_ sending rather than after.
3. **It is nearly free.** `togbank-rd2` already takes appended optional fields.

Record the pre-discount estimate, the discount applied, the source, and the timestamp — not just a
total. "12g" tells nobody anything six weeks later.

Whether a large estimate-to-actual gap should do more than warn — pause the order, ask the member to
confirm — is an open question, §6.

---

## 4. Proposed design

### 4.1 STORE-001 — where the estimate comes from

**TOGBank does not get its own AH integration, and never learns that Auctionator or TSM exist.**

That work is already done. TOGProfessionMaster carries the auction-house integration _and_ the
vendor integrations for the other price addons — it is already the layer that answers "what is this
worth" from whichever source a given machine has. TOGBank should ask one question, of one place, and
not care how the answer was reached.

Rebuilding any of it here produces two implementations that drift apart, which is exactly what
`ACQ-001` was: a vendored AceCommQueue sitting at MINOR 2 while the standalone reached 5, silently
missing the fix that made a refused send report as failed. That was **one library** and it still
shipped stale. Here it would be several integrations, each tracking a third party's API.

Whatever the mechanism, one property must hold: **the estimate is optional, and its absence costs
nothing.** Because the banker's price is THE price (§3), a machine with no price data shows no
estimate and the shop runs exactly as the guild runs it today — order, banker prices at fill,
C.O.D. That would _not_ be true under a binding-quote design, where the price source would have to
be a hard requirement because you cannot have a contract you are unable to compute. The correction
in §3 is what keeps this dependency cheap.

It also keeps the cost where it belongs: only **bankers** need a price source, because only bankers
publish estimates. Two or three characters per guild, not two hundred.

Availability is checked at **call time, not load time** — an addon can be disabled, absent on one
character, or load in an order TOGBank does not control, so a cached "is it there" answer from login
is a bug waiting to happen. Feature-detect the method, not a version, exactly as INV2's `Resolve`
does.

#### The three options

| | Rebuild in TOGBank | Versioned public API on TOGPM | Own library, owning the scan |
| --- | --- | --- | --- |
| Integrations to write | The AH scan **plus** every price-addon integration TOGPM already has | None — TOGPM keeps them | None new — they move, and the scan moves with them |
| Third-party APIs TOGBank tracks | Auctionator's, TSM's, any future one | None | None |
| Versioning | n/a | Hand-rolled MAJOR/MINOR on an addon | LibStub, already proven here |
| TOGBank's dependency | None, and permanent weight instead | TOGPM installed **and enabled** | The library only |
| Adding a new price addon | Fix it twice, forever | One place | One place |
| Third consumer (TOGTools) | Fix it three times | Couples TOGTools to TOGPM too | Free |
| Works with no price addons installed | Only if TOGBank writes a scanner | Only if TOGPM's own scan is present | **Yes — it scans** |
| Where the work lands | TOGBank, mid-overhaul | TOGPM, small | An extraction from TOGPM, plus a scanner |
| Cost when unavailable | n/a — always your problem | No estimate; shop unaffected | No estimate; shop unaffected |

Rebuilding is out on the first two rows alone. **The third column is the decision** — see below for
what it commits to.

#### The library, and what it owns

_This supersedes an earlier draft, which argued against a library on the grounds that the expensive
part was the scan data. That was the wrong conclusion — the scan should move into the library too,
which is what the rest of this section describes._

Break "AH and price-addon integration" into what it actually contains:

**Decided: the AH scan moves into the library too.** Not just adapters over other people's addons —
the library does its own auction-house scanning, so a local scan is available to any addon that
consumes it, and the TSM integration lives there as well. One source-agnostic surface: a consumer
asks what an item is worth and gets the same answer shape whether it came from the library's own
scan, from TSM, or from anywhere else.

That is the correct boundary, and it is a bigger commitment than an adapter shim. Worth being clear
which one is being built.

| Piece | Has state? | Where it lives |
| --- | --- | --- |
| Its own auction-house scan | **Yes** | **Library** |
| TSM integration | No | **Library** |
| Adapters for other price addons | No | **Library** |
| Source selection, precedence, fallback | No | **Library** |
| Normalization — one vocabulary of statistics, one unit (copper) | No | **Library** |
| Provenance and freshness | No | **Library** |
| Source configuration UI (which sources, precedence, scan controls) | Yes | **Library** |
| Officer overrides, the guild discount, what we _charge_ | Yes | TOGBank |
| Profession costing | Yes | TOGPM |

The dividing line: **the library answers "what is this worth", never "what do we charge for it".**
Overrides, discounts, donation rates and rank tiers are all consumer policy and none of them belong
in there.

#### Why owning the scan is the right call

- **Self-sufficient.** An adapter-only library gives nothing to a user who has none of the supported
  addons. One that scans works on a bare install, which for a guild bank matters — you cannot tell a
  banker to go install TSM before the shop works.
- **One scanner, many consumers.** TOGPM, TOGBank and later TOGTools all want prices. Without this,
  either each grows a scanner or two of them are permanently dependent on the third.
- **The abstraction only pays off if it is complete.** "Same shape regardless of source" is the whole
  value, and it is undermined the moment one important source sits outside it.

#### What owning state changes — the parts that need designing

1. **It owns its own SavedVariables, in its own TOC.** Standalone, declared as a required dependency
   the way `GuildRoster` and `AceCommQueue-1.0` already are in `TOGBankClassic.toc` — its TOC is
   read by the client, so `## SavedVariables:` works normally and the scan data belongs to the
   library rather than being donated by whichever consumer happened to register first.

   The one thing to hold to: **it must not also be embedded** in a consumer's `Libs/` folder. An
   embedded copy's TOC is never read, so its SavedVariables would silently not exist, and the same
   `ACQ-001` drift returns. Standalone only.
2. **Store derived statistics, not raw auctions.** A full Era scan is tens of thousands of rows and
   nobody wants that in their SavedVariables. Store per-item figures — minimum buyout, market value,
   historical — with a timestamp.

   This is not just a size optimisation; **it is what makes the abstraction possible.** TSM does not
   hand over raw auction rows either, it hands over derived statistics. Per-item statistics are the
   common denominator across every source, which is precisely why every source can normalize into
   one shape.
3. **The scan is a subsystem, not a helper.** Classic AH querying is throttled and slow — a full pass
   takes minutes. It needs progress reporting, cancellation, back-off, and a "last scanned N hours
   ago" that consumers can show. Budget for that honestly.
4. **Multi-version.** Era 1.15 and TBC 2.5.6 use the older `QueryAuctionItems` path, not retail's
   `C_AuctionHouse`. If the library is ever meant to reach retail, that is a second scan
   implementation behind one interface — fine, but decide it up front rather than discovering it.
5. **Precedence policy.** Own scan two hours old versus TSM three days old — which wins? Freshness-
   weighted by default, with the consumer able to demand a specific source, is the shape most likely
   to be right; it needs deciding rather than defaulting.
6. **A minimal configuration UI**, in the library itself. Which vendor/AH sources are enabled, their
   precedence, the default statistic, and the scan controls. Deliberately in the library and not in
   each consumer: the alternative is TOGPM, TOGBank and later TOGTools each growing their own copy
   of the same panel, disagreeing about the same settings, on the same machine.

   Keep it genuinely small — a source list with enable/disable and ordering, a default-statistic
   picker, and `Scan Now` with progress and a last-scan timestamp. Nothing else. This is a settings
   panel, not a product.

   **The line that must not blur:** this configures _where numbers come from_ on this machine. It is
   a per-account user preference. It is not guild policy — the discount, the officer overrides, the
   donation rate and the rank tiers are all TOGBank's and all guild-synced, and none of them belong
   anywhere near this panel.

   AceConfig is the obvious way to build it, and costs nothing new: every addon in this ecosystem
   already depends on Ace3.

**Eyes open on scope:** writing an AH scanner is a real project, and it is a large part of why
Auctionator and TSM are large addons. The mitigation is that none of _their_ bulk is needed here —
no posting, no shopping lists, no search UI, no cancel/undercut logic. Only scan → per-item
statistics → serve, plus the small settings panel above. That is the core of those addons without
the product around it, but it is not nothing, and it should not be estimated as if it were an
afternoon of adapters.

#### The versioning question was the tell

Reaching for a MAJOR/MINOR scheme on an addon's public API is reaching for LibStub — that is
precisely the problem it exists to solve, and its highest-revision-wins rule is already relied on
across this ecosystem. Hand-rolling version negotiation into TOGPM would be reimplementing it, less
well, for one consumer.

#### Cost and benefit

Costs:

- **The work lands outside TOGBank**, in an extraction from TOGPM plus a new scanner, while TOGBank
  is already mid-overhaul.
- **Sequencing risk.** It must exist and be stable before TOGBank codes against it, putting it on the
  critical path for STORE-001 and everything downstream.
- Extractions are rarely as clean as a table makes them look.

Benefits:

- **TOGBank depends on the library, not on TOGPM at all.** TOGPM becomes a peer consumer.
- A new price addon appears → one adapter, one place, every consumer gets it.
- TOGTools gets prices for the bank log later at no additional cost.
- The API is dogfooded by its own author, because TOGPM consumes it too — pressure a TOGPM-only
  public API would never feel.
- It is genuinely publishable. Unlike an adapter shim, a source-agnostic price service is something
  other addon authors would use, which fits how GuildRoster, DeltaSync, ItemDB and AceCommQueue are
  already published.

Naming is yours; `LibItemValue-1.0` or similar is the shape.

### 4.1.1 The contract

Whichever delivery mechanism wins, TOGBank must **not** reach into TOGPM's internals. That is the
drift problem wearing a different coat: an internal table renamed in TOGPM breaks TOGBank silently,
and nothing tells either side.

The ecosystem already has the right answer and uses it four times over — ItemDB, GuildRoster,
DeltaSync and AceCommQueue all publish a documented contract that consumers code against. This gets
the same treatment, written in [LIBRARY_CONTRACTS.md](LIBRARY_CONTRACTS.md) alongside the other four.

**Write the contract before the library is built, not after.** It is the same shape whichever
mechanism ships, so agreeing it first unblocks TOGBank's design, gives the extraction a target, and
is what lets TOGBank be written against it in parallel rather than after.

Sketch, to be negotiated properly in that document rather than assumed here.

**Lookup:**

- By **`itemID`** (not name — REQ-001 same-name variants), returning copper.
- **A named statistic on request**, not one number of the provider's choosing — §4.7 wants a
  conservative figure for donations while the sell side may want another, so one caller needs two
  different answers about the same item.
- **Provenance with every answer**: which source, which statistic, and how old. A price with no
  provenance cannot be debugged, cannot be shown honestly to a member, and cannot be argued about
  usefully. An estimate whose age is unknown is worse than no estimate.
- **"No data" distinct from "zero".** An unpriced item must be visibly unpriced; a bug that silently
  prices something at 0 gives it away for free.
- A cheap **bulk** form. A banker publishing a list resolves every distinct item in stock at once,
  and that must not be one call per row through a slow path.

**Because it owns the scan, it also needs:**

- **Scan state** — is one running, how far through, when did the last one finish. A banker publishing
  estimates off a three-week-old scan should be told.
- **A way to start one**, and a way to be told it finished, so a consumer can refresh afterwards
  rather than poll.
- **Which sources are live** on this machine, so the UI can say "no price data yet — run a scan"
  rather than silently showing nothing.
- **Realm and faction scoping**, stated explicitly. Price data that silently crosses realms is
  wrong in a way nobody notices until the numbers are strange.

**Open, and genuinely unknown to me:** what TOGPM exposes today, how entangled its adapters are with
its scan storage, and how much of a scanner already exists there versus needing to be written. Those
decide whether §4.1 is a fortnight or a season. Question 1 in §6; nothing here is settled until it
is answered.

### 4.2 STORE-002 — the published estimate list

`itemID → copper`, published by bankers alongside the inventory. Only items actually in stock need
an estimate, so the list is bounded by the bank's distinct-item count rather than by the item
database.

This is deliberately **after INV2**: the tuple store already keys everything by `itemID`, so the
list is one number per row of something the addon will already be sending, and it composes with
delta sync rather than competing with it. Building it against the current link-based storage would
mean building it twice.

The list needs its own refresh cadence, tied to when the banker's AH data refreshes rather than to
inventory changes — stock and prices move independently. Every entry carries its age, and the UI
shows it: "est. ~12g (2 days old)" is honest, "12g" is not.

### 4.3 STORE-003 — the discount

A guild-wide percentage off the resolved price, officer-set, synced through
`Guild.Info.settings.storeDiscountPercent` with the same sanitization and bounds-checking as
`maxRequestPercent`. Set 30%, everything is 30% off. This is what was asked for and it should ship
first.

**Extrapolation, not requested:** once ranks are in the picture (§4.6), a per-rank discount tier is
the obvious next shape — trials pay AH, raiders pay 30% off, officers pay 50% off. Adestar did not
ask for this and it should not be built on speculation, but the discount should be _stored_ as
something a per-rank table can grow out of rather than as a bare number that has to be migrated
later.

### 4.4 STORE-004 — the estimate on the order

The estimate shown at order time is **written into the request record** as new trailing fields on
`togbank-rd2`: the pre-discount value, the discount applied, the source, and the timestamp. Not just
a total — "12g" tells nobody anything six weeks later, and every dispute needs the breakdown.

Note what this field is _not_. It does not bind the banker and it is not what gets charged; §3 is
unambiguous that the banker's price at fill is the price. It is a record of what the member was
shown, kept for the three reasons in §3.2: settling disputes, letting the banker spot a bad number
before mailing, and costing almost nothing.

Because it binds nothing, **no expiry rule is needed.** An order sitting unfilled for three weeks
carries a three-week-old estimate, which is fine — it is labelled as an estimate, it is stamped with
its age, and the banker prices it fresh when they fill it. This is one of the places the
banker-is-authoritative rule quietly deletes a whole subsystem that a binding-quote design would
have needed.

### 4.5 STORE-005 — C.O.D. fulfillment

`SetSendMailCOD(amount)` before the existing `SendMail` call at `Modules/Mail.lua:1248`. The amount
comes from the banker's own price source at that moment — **not** from the estimate stored on the
order. The banker does not type a number, but the number is theirs.

The fill UI shows both, so a large divergence is visible before the mail goes out (§3.2). What
happens on a big gap beyond warning is an open question, §6.

This is a small code change sitting on top of a large pile of unverified behaviour — see §7, which
should be read before anyone estimates this.

### 4.6 STORE-006 — storefront controls

All three of Adestar's asks, all living in `Guild.Info.settings` and all enforced in
`Guild:AddRequest` beside the existing `VIEWBANK-001` gate:

- **Shop open/closed** — one officer toggle disabling ordering guild-wide. The simplest of the six
  and the one most likely to be wanted immediately (stocktake, an officer away, a pricing mistake).
  The Search window should say _why_ ordering is unavailable rather than just greying out, or every
  officer will field the same question.
- **Not for sale** — a per-item block, keyed by `itemID` and not by name, because same-name variants
  are a solved-and-documented problem in this codebase (REQ-001) and re-introducing a name-keyed
  list would undo it.
- **Rank floor** — per bank toon and per item. The per-toon form generalizes the existing view-only
  marker: today a toon is orderable by everyone or nobody, and this makes that a threshold instead
  of a boolean.

### 4.7 STORE-007 — donation credit

Today donations are tracked but not valued: the addon records that someone gave something, and
nothing more. With a price source in the picture, a donation can be valued and converted to
**donation points** at an officer-configurable rate — 1g of value = 1 point by default, with the
rate synced through `Guild.Info.settings` exactly like the discount.

This is the half of the economy that is currently missing. The store is one-directional — members
take. Points make contribution and consumption the same currency, which is what turns a stocked
room into an economy, and it gives a donor an actual receipt instead of a shrug. It also reuses
everything already being built: the same TOGPM lookup, the same officer-setting plumbing, the same
banker-is-authoritative rule.

It is also the piece most likely to cause an argument, so the rules matter more here than anywhere
else in this document.

**A donation's value is locked at the moment it is received. Permanently.** Points are a ledger of
past events, not a live valuation of past events. If the balance is recomputed from current prices,
somebody who donated 40 Black Lotus last year watches their standing swing every time the market
moves, and there is no explanation that will make that feel fair. Value it once, write it down,
never touch it again.

**The banker who ingests the donation sets the value**, using their TOGPM data at that moment —
the same rule as §3, applied to the other direction. This falls out naturally, because donations
already arrive through the banker's mailbox scan. An officer override per donation is needed for
the cases the AH gets wrong, and it should be recorded as an override rather than silently
replacing the number.

**Points are written by bankers, never by the member who earned them.** A member's own client must
not be able to author its own balance — same client-side reality as §4.8, but with more incentive
to cheat, because unlike a request a point balance is permanent and comparative. The banker
computes, stores and broadcasts; everyone else reads.

**Adjustments must exist, and must be auditable.** Returned donations, mail mis-sends, a wrong
valuation, a member leaving and rejoining. An officer needs to be able to correct a balance with a
reason attached, or the first mistake poisons the ledger for good.

**No retroactive valuation.** Existing donation history stays unvalued and the ledger starts at
zero on the day the feature ships. Back-valuing years of donations at today's prices is the
live-valuation bug wearing a hat, and it would hand points to whoever happened to donate the things
that appreciated.

Two exposures worth designing against rather than discovering:

- **Bulk-trash farming.** If 1g = 1 point, members will discover that dumping vendor greys and
  cheap herbs is points-per-hour. Needs a floor value, a per-item multiplier, or a
  not-accepted-for-points list — likely the same mechanism as the not-for-sale list in §4.6, though
  probably not the same list, since a bank may happily sell something it does not want more of.
- **Thin-market manipulation.** On a quiet realm an item's AH price is a few auctions deep, so it
  can be inflated and then donated for inflated credit. Points to a conservative statistic (minimum
  buyout or historical rather than market value) and possibly an officer review threshold above
  some value.

**Explicitly not in scope for a first version: spending points.** Points as a _record_ of
contribution is a small, self-contained, useful feature. Points as _currency_ that pays for orders
is a second system with balance checks, partial payments, refunds on cancelled orders, and a
reconciliation problem between two ledgers the addon cannot enforce. That is the obvious next step
and it should be designed on purpose, later, not fallen into.

Cheaper than it looks in build terms: donation credit needs a price source (§4.1) but **not** the
published estimate list (§4.2), because donations are valued banker-side at ingest and never quoted
to a member in advance. What syncs is one number per member, not a price per item. It can therefore
land well before the storefront does.

### 4.8 Enforcement, honestly

_A principle the sections above are held to, not a deliverable — hence no ticket ID._

Every gate above is client-side. `Guild:AddRequest` runs on the **requester's** machine, and the
resulting mutation is broadcast to everyone. A member running v1.3.x has none of this code, and
their orders will sail straight through every one of these controls.

That is not a reason to skip them — it is a reason to be precise about what they are:

- The UI gate is a **guardrail**. It stops the 99% of cases that are people not knowing the rules.
- The real boundary is the **banker's client**, which is the thing that actually mails the goods. A
  banker auto-rejecting an order that violates the current rules is enforcement in the only sense
  that matters: the items do not leave the bank.

The officer-facing text should say which is which. An officer who believes the rank filter is a
security boundary and finds out otherwise during a loot dispute is a worse outcome than one who was
told up front it is a UI control backed by a banker-side check.

---

## 5. Build order

Deliberately not the order the features were asked in. Each step is independently useful and none
of them strand the next.

1. **STORE-006 shop open/closed.** No pricing, no protocol change, one synced boolean. Ships in
   days, wanted immediately.
2. **STORE-006 not-for-sale list.** Still no pricing. Direct extension of `VIEWBANK-001`.
3. **The price contract** (§4.1.1), agreed in `LIBRARY_CONTRACTS.md` first. Everything from here
   down is blocked on it, and agreeing it early is what lets TOGBank be written against it in
   parallel with the library rather than after.
4. **The library** (§4.1): the adapters extracted out of TOGPM, the AH scanner, the source
   configuration panel, and TOGPM converted to a consumer of it. Not TOGBank work, but squarely on
   TOGBank's critical path — and by some distance the largest single item on this list.
5. **STORE-001 estimate lookup, banker-local.** No sync yet — a banker can see resolved values in
   their own UI and sanity-check them against reality before anyone is charged or credited.
6. **STORE-007 donation credit.** Deliberately ahead of the storefront: it needs a price source but
   not the published list, so it is reachable much sooner, and it is the half members feel good
   about rather than the half they pay for.
7. **STORE-002 the published estimate list.** Needs INV2 done.
8. **STORE-003 the discount** and **STORE-004 the estimate on the order**.
9. **STORE-005 C.O.D.**, once §7 is resolved.
10. **STORE-006 rank floors**, last, because they interact with everything above and are the easiest
    to get subtly wrong.

Steps 1-2 need neither the sync overhaul nor a price source, and could ship at any point. Steps 3-6
need the price layer settled but not INV2. Only step 7 onward waits for the overhaul.

---

## 6. Open questions

Not yet discussed. Each of these changes the work materially, so none should be answered by
guessing.

1. **How much of the library already exists inside TOGPM?** The single biggest unknown, and
   everything from §4.1 down is blocked on it. How separable are the adapters from TOGPM's own
   storage, and how complete is the AH scanner there — a working scanner to be moved, or one to be
   written? That is the difference between a fortnight and a season, and it is the only thing that
   could reopen the versioned-TOGPM-API route as a stopgap. Also needed: is any of it public today,
   is the data realm- and faction-scoped, and does a bulk form exist?
2. **Price statistic — and whose choice is it?** Market value, historical, minimum buyout and
   region average give very different numbers for the same item, and the difference is the whole
   business model of the shop. But since TOGBank never touches the price addons directly (§4.1),
   this is really a question about the contract: does TOGPM decide and hand back one number, or does
   it let the caller ask for a named statistic? The latter matters, because §4.7 wants a
   _conservative_ statistic for donations specifically — so TOGBank may need two different answers
   about the same item, and only one of those two shapes can give it that.
3. **Estimate-vs-actual gap.** §3.2 has the banker warned when the two diverge sharply. Should a
   big gap do more — pause the order, ask the member to confirm — or is warning the banker enough?
4. **Rank discount tiers.** Extrapolated in §4.3 — wanted, or scope creep?
5. **Visibility vs orderability.** Adestar said "visible or orderable". Orderability is cheap.
   Visibility is not: the inventory is _already synced to every member's SavedVariables_, so hiding
   it in the UI is a filter, not a permission — anyone who opens the file sees everything. Making it
   real means not sending the data, which makes those members' guild totals and search results
   genuinely incomplete. Which of the three is wanted?
6. **Partial fills and refunds.** An order for 20 filled with 12 — does the C.O.D. drop
   proportionally? Who decides? This is where a real shop's edge cases live.
7. **Unpriced items.** Blocked from ordering, orderable at a banker-set price, or orderable free?
   And on the donation side: accepted for zero points, or refused?
8. **Donation points: one list or two?** Is the not-accepted-for-points set the same as the
   not-for-sale set (§4.7)? They overlap but are not obviously identical — a bank may be glad to
   sell something it does not want more of.
9. **Donation points: do they ever get spent?** Out of scope for a first version (§4.7), but the
   answer changes how the ledger is stored, so it is worth knowing the intent now even if the
   feature waits.
10. **Version target.** v1.4.0 alongside the sync work, or v1.5.0 after it?

---

## 7. Unverified — must be checked before STORE-005 is estimated

Called out separately because C.O.D. looks like a one-line change and may not be. **None of the
following has been verified**; they are the questions, not the answers.

- **`SetSendMailCOD` on Classic Era 11509 and TBC 20506** — availability and any cap on the amount.
- **C.O.D. and money-in-mail together.** Believed mutually exclusive; not checked.
- **C.O.D. to your own characters.** Members with a bank alt may want the goods sent to an alt.
- **What happens to an unpaid order.** A C.O.D. mail the requester never pays for returns to the
  banker. Does it come back with the C.O.D. still set? Does it come back at all, or expire?
- **`MAIL-002` collision — the important one.** `Modules/MailInventory.lua:55` skips every C.O.D.
  mail when scanning the bank's mailbox. If a returned unpaid order arrives still flagged C.O.D.,
  the addon will **not see the returned stock**, and the bank's inventory will under-report by
  exactly the amount of every order that was never paid for. That is a silent, compounding
  discrepancy in the numbers the whole addon exists to report, and it is the single most likely way
  this feature does damage.
- **Whether the `SendMail` hook still fires** for a C.O.D. send, since fulfillment tracking depends
  on it.

The first five are answerable from the Blizzard API documentation and one test send between two
characters. The sixth is answerable the same way. Do that before writing any of STORE-005.

---

## 8. What this deliberately does not do

- **No gold handling.** The addon sets a C.O.D. amount; the game moves the money. The addon never
  holds, transfers or reconciles gold.
- **No AH scanning, and no price-addon integrations of its own.** TOGProfessionMaster already
  carries the auction-house integration and the vendor integrations for the other price addons.
  Asking it for a number is reasonable; rebuilding that stack here is how you end up maintaining two
  of everything and shipping the older one — see `ACQ-001`, which was a single library and still
  managed it.
- **No knowledge of Auctionator, TSM, or any other price addon by name.** If either string appears
  in this codebase, the boundary in §4.1 has been crossed.
- **No price negotiation.** A published estimate and a fixed discount, not a haggling protocol.
- **No binding quotes.** The banker's price at fill is the price; everything shown before that says
  "estimate" (§3).
- **No spending donation points**, in a first version (§4.7).
- **No enforcement claims it cannot keep.** See §4.8.
