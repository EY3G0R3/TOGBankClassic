# LINK-AUDIT-001 -- the item-identity / link layer, audited whole

Written 2026-09-12 (session 487eb157) against the working tree after v1.5.0's last fix
(STATUSBAR-003). The operator's directive (#13640, verbatim): _"this needs to be part of the
overhaul, how this logic is created. it was generated when full links went across the wire, and we
had link stripping to try to reduce traffic over the wire. we have ItemDB now that can fully
reconstruct links. A LOT of the logic is probably outdated, bad or just wrong. I need you to do a
FULL comprehensive audit."_

This document is the audit. Every claim in it was made by reading the file at the line cited; the
things that could not be verified are listed at the end, not folded into the findings. The overhaul
it specifies is **one release, after `TOGBankClassic-v1.5.0` is tagged** (the directive), because it
moves every banker's content hash and mail hash once.

## 1. The fact the layer predates

Since 2026-09-08 `ItemDB` (LibItemDB-1.0) is a **required** dependency in both TOCs. Its
`GetSuffixLink(id, propID, enchantID)` (`ItemDB/LibItemDB-1.0.lua:1243-1250`) returns a
quality-coloured, clickable link carrying the **suffixed display name** ("Dreadblade of the Bear")
whenever the base id and the property id are in its data; `GetInfo(id)` (`:777-781`) returns name,
quality, class, subClass, equipLoc, itemLevel, requiredLevel with no cache and no delay. The V2
record is `{ id, count, suffix, enchant }` (`Modules/Inventory/Record.lua:28-41`) and its identity
is `Record.key` = `id:suffix:enchant` (`:62-65`).

So a **link string is derived data**. It is a function of three integers and the library. Nothing
should store one, key on one, strip one or parse one, except at the **two edges** where the client
hands one over and the integers have to be pulled out of it:

- a container slot -- `C_Container.GetContainerItemInfo(bag, slot).hyperlink`
- an inbox attachment -- `GetInboxItemLink(mailIndex, attachmentIndex)`

The layer under audit was written before that was true. What follows is every function in it,
classified.

## 2. The one pipeline (the target)

```text
client link --Scan.parseLink--> (enchant, suffix) --Record.new--> { id, count, suffix, enchant }
                                                                          |
                              Record.key / Record.keyFor (id:suffix:enchant) is THE identity
                                                                          |
                                                          Resolve.describe(rec)
                                                                          |
              +--------------+--------------+--------------+--------------+--------------+
           Store.viewRow   Search corpus   Log entries    TOGTools rows   Request mint   tooltips
           (Info + Link)   (name -> rows)  (name, link)   (itemLink)      (itemID,       (link)
                                                                          suffixID)
```

Three rules fall out of it, and every finding below is a place one of them is broken:

1. **Parse at the edge, once.** `Scan.parseLink` is the only link parser. A live client link that
   has to be matched against a record is parsed to `(id, suffix, enchant)` and compared by key --
   never by string, never by a second parser.
2. **Build from the record, never from a hand-typed item string.** `Resolve.describe(rec).link` is
   the only link builder. Where the record is not in hand, `Record.new(id, 1, suffix, enchant)`
   makes one.
3. **One identity.** `Record.key`. Not `id`, not `id:suffix`, not `id:0`, not a 7-field link
   substring, not `id:suffix:enchant` built inline.

## 3. Classification -- every link-touching function

`EDGE` = the client hands us a link and we must read it. Keep. `DERIVED` = should be a call to
`Resolve`/`Record` and is not. Rewrite. `DEAD` = no production entry point. Delete.

### 3.1 The two item databases

| Site | Class | What it is | Verdict |
| --- | --- | --- | --- |
| `Modules/Static/ItemDB.lua` (3,722,230 bytes, 24,450 lines, generated 2026-05-23), `TOGBankClassic.toc:19`, `TOGBankClassic_BCC.toc:19` | **DEAD** | `TOGBankClassic_ItemDB`, the addon's own static DB | Its only reader is `Item:GetClass` (`Modules/Item.lua:24-25`). `GetClass`'s only caller is `Item:ItemClassNeedsLink` (`:58`). `ItemClassNeedsLink` has **no caller in `Modules/` or `Core.lua`** -- its last one, `Database:PurgeLinklessGearGhosts`, was deleted (`Modules/Database.lua:43`, `Modules/Chat.lua:2875`). So 3.7 MB is parsed by every client at load and read by nothing. Delete the file, both TOC lines, both functions, `tools/build-itemdb.py`, and the two globals from `.luarc.json:160-161` / `.luacheckrc:47`. |
| `Modules/Static/SuffixDB.lua` (54 KB), TOC line 20 in both | **DEAD** | `TOGBankClassic_SuffixDB` | No reader anywhere outside the file itself. Delete with the above. |
| `Modules/Item.lua:38-46` comment, `Modules/DeltaComms.lua:495-498` comment, `docs/INVENTORY_V2.md:330-331` | stale | All three say `ItemClassNeedsLink` "deliberately survives" for `PurgeLinklessGearGhosts` | The function they defend has been gone since INV2-RETIRE-003. Three places asserting a caller that does not exist is how a 3.7 MB file stays shipped. |

### 3.2 Link parsers -- three spellings, one needed

| Site | Class | Verdict |
| --- | --- | --- |
| `Scan.parseLink` -- `Modules/Inventory/Scan.lua:35-43` | **EDGE** | The one parser. Fields 2 and 7 counted from the id, signed, empty and `0` equivalent. Keep. Give it a third return, the id (field 1), so callers matching a live link never need a second call. |
| `Item:GetItemString` -- `Modules/Item.lua:66-85` | **DEAD after 3.3** | Sole caller `MailInventory.lua:80`, which stores the result in `ItemString` on a row that `Bank:Scan` reduces to `Record.new(item.ID, item.Count)` (`Bank.lua:299`) -- the field is computed and thrown away. |
| `Item:GetItemKey` -- `Modules/Item.lua:90-143` | **DEAD after 3.3 + 3.6** | A manual colon splitter producing a 7-field link substring as identity, with a debug line inside. Callers: `MailInventory.lua:97` (the inbox aggregation key) and `Item:Aggregate` (`:726`). Both go. |
| `Item:GetSuffixID(link)` -- `Modules/Item.lua:151-172` | **EDGE, duplicate** | A second parser of the same field `Scan.parseLink` reads, with a different pattern (`[%d:%-]+` vs `[%-%d:]+`) and `strsplit`. Callers read **live** links: `Bank.lua:848` (fulfil match), `Mail.lua:1011` (inbox match), and `RowSuffixID`'s fallback. Replace every call with `select(2, Scan.parseLink(link))` and delete. |
| `Item:RowSuffixID(row)` -- `Modules/Item.lua:185-197` | **DERIVED** | Reads `row.Suffix` on a view row, falling back to parsing `row.Link`. Every row that reaches it is a `Store.viewRow` (`Store.lua:438-457`), which always sets `Suffix` as a number -- the fallback is unreachable. Callers `Log.lua:172`, `Search.lua:291/303/1057/1060`, `Requests.lua:2650` read `row.Suffix` directly (0 -> nil where a nil is wanted). Delete. |

### 3.3 The mail edge -- rows stored suffix-less (the operator's Dreadblade)

| Site | Class | Verdict |
| --- | --- | --- |
| `MailInventory:ScanMailInventory` -- `Modules/MailInventory.lua:37-161` | **EDGE, wrong shape** | Reads `GetInboxItemLink` (`:71`) -- the link carries suffix and enchant -- then aggregates by `tostring(itemID) .. GetItemKey(link)` (`:97-98`) into legacy `{ ID, Count, Link, ItemString }` rows, and `Bank:Scan` builds the tuple from **ID and Count only** (`Modules/Bank.lua:299`, marked KNOWN WRONG at `:282-290`). Rewrite: parse each attachment with `Scan.parseLink`, build `Record.new(itemID, count, suffix, enchant)`, aggregate with `Record.aggregate`. The function returns **records**, not rows, and the `Link`/`ItemString` fields stop existing. |
| `senders` -- `MailInventory.lua:67-70`, `:148`; read by `Log:AttributeChanges` | **DERIVED, wrong key** | Keyed `itemID .. ":0"` because the row was suffix-less. Key by `Record.key(rec)` once the record carries the suffix, and the log's `from` can name the sender of a suffixed item. |
| `Bank:Scan` mail block -- `Modules/Bank.lua:293-319` | **DERIVED** | Takes the records from the rewritten scanner as-is; the `Record.new(item.ID, item.Count or 1)` loop goes. The mail hash (`:415-434`) and the content hash (`:359`) are then over the true tuples. **KNOWN COST:** one content-hash change and one mail-hash change per banker on their first mail-inclusive scan after upgrading -- one version bump each, self-correcting, the same class as HASH-REV-001's own introduction. Stated in the CHANGELOG. |

**Failure today, concretely:** a banker with a Dreadblade of the Bear in the inbox stores `{ 17240, 1 }`;
the same weapon taken into the bags stores `{ 17240, 1, 1196 }`. Two keys, two rows, the viewer sees
"Dreadblade" and "Dreadblade of the Bear" as different items; the log records a withdrawal of one and
a deposit of the other on the take; `senders["17240:0"]` can never match the deposit the bags-row
produces.

### 3.4 Link reconstruction -- four spellings, one needed

| Site | Class | Verdict |
| --- | --- | --- |
| `Resolve.describe` step 1 -- `Modules/Inventory/Resolve.lua:150-177` | **the builder, with one field wrong** | The LINK (`lib:GetSuffixLink(id, suffix, enchant)`, `:157`) is coloured, suffixed and tooltip-correct. Keep. But the NAME (`:154`) is `lib:GetInfo(id)`'s, which is the **base** name -- so `Info.name` for `{4564, 1, 1180}` is "Spiked Club" while the link in the same descriptor reads `[Spiked Club of the Bear]`. `Info.name` is what every row PRINTS (Browse `:187`, Search's corpus, the Log's `item`) and what a request's `item` is minted from (`Search.lua:285`), so two suffix variants of one base item are two identical rows to a requester, and the request that results names the base item to the banker. **Field report 2026-09-13** (operator: "the request came in without the suffix ... spiked club of the spirit i have, but it's not being seen"): request `90fe527732a434` carried `4564:1180` = "of the Bear", which was in Toglowweap's bags; the banker's "of Spirit" is `4564:28`, in the bank. Nothing was lost on the wire -- the requester chose between two rows both reading "Spiked Club", and the banker read the same word. Fix: take the name from the same source as the link -- `lib:ResolveSuffix(id, suffix).name` (`LibItemDB-1.0.lua:1255-1269`, base .. " " .. the random-property family name) when `suffix ~= 0`, else `GetInfo`'s. `Resolve.name` and `RequestDisplayName` inherit it. Cost: the Search corpus and the Log's `item` change for suffixed rows (both are display; TOGTools receives `item` -- say so in the contract thread). **BUILT 2026-09-13 as SUFFIX-NAME-002** (the operator reopened the hold: "the item in the requests HAS to show the link ... aka, the suffixes"): `Resolve.describe` takes the name from `lib:ResolveSuffix` when `suffix ~= 0` (feature-detected), and `Item:RequestDisplayName` resolves id + `suffixID` whenever a request carries one, so requests stored with the base name read the variant. Pinned in `resolve_spec` and `requestname_spec`. The TOGTools note is still owed. |
| `Resolve.describe` step 2 -- `:180-199` | **DERIVED, lossy** | `GetItemInfo(id)` returns the **base** link (`:191`), and `link or ("item:" .. id)` (`:193`) drops the suffix and enchant entirely. For an id LibItemDB lacks, the record's own suffix is thrown away here. Build `lib:BuildItemString(id, suffix, enchant)` (`LibItemDB-1.0.lua:1217`) and, when `GetItemInfo` answers, ask it for **that** string so the client returns the suffixed, coloured link; else emit the bare item string, which the client's tooltip still renders correctly. Never `"item:" .. id` for a suffixed record. |
| `Guild:ReconstructItemLink` -- `Modules/Guild.lua:3028-3048` | **DEAD** | Builds a WHITE link (colour `cffffffff`, the base name in the brackets, the stored `ItemString` as the hyperlink) from a `row.ItemString` no writer produces any more, else `GetItemInfo(item.ID)`'s base link. Callers `UI.lua:420` and `:439` run only when `item.Link` is nil, which for a view row is Resolve step 3 (placeholder -- the client cannot name it either). Delete; the two comment blocks at `Guild.lua:3023-3025` and `:3055-3057` defending it go too. |
| `Log:ItemLinkFor` -- `Modules/Log.lua:638-668` | **DERIVED, third spelling** | Hand-types `item:%d:0:0:0:0:0:%d`, asks `GetItemInfo`, verifies the seventh field by regex, then falls to Resolve, then to a **synthetic white link** (`:667`) -- because Resolve step 2 loses the suffix (above). Fix step 2 and this collapses to `Resolve.describe(Record.new(itemID, 1, suffix)).link`. The white synthetic link and the regex go. LOG-TAB-002 closes with it. |
| Requests tooltip -- `Modules/UI/Requests.lua:2686-2691` | **DERIVED, fourth spelling** | `string.format("item:%d:0:0:0:0:0:%d", itemID, requestSuffix)`, after scanning **every alt's every row** on hover (`:2645-2657`) to find a link. Replace the scan and the format with `Resolve.link(Record.new(requestItemID, 1, requestSuffix))`. O(1), coloured, suffixed. |
| `UI.lua:DrawItem` rarity fallback -- `Modules/UI.lua:479-502` | **DEAD for view rows** | `Item:CreateFromItemID` + `ContinueOnItemLoad` when `Info.rarity` is nil. `Store.viewRow` always sets `rarity` (`Store.lua:449`, `quality or 1` / `0`). Reachable only from `UI/Mail.lua`'s rows (3.5). Goes with the loader. |

### 3.5 The async loader and its era

| Site | Class | Verdict |
| --- | --- | --- |
| `Item:GetItems(items, cb)` -- `Modules/Item.lua:234-513` (280 lines) | **DERIVED / DEAD** | Written for a cold `GetItemInfo` cache and links that had to be preserved until it warmed. For a view row (`Link` and `Info` set) branch 1 runs synchronously and only re-asks `GetItemInfo(link)` for `reqLevel` (`:379-384`) -- which `Resolve` already filled from `lib:GetRequiredLevel` (`Resolve.lua:161`). Branch 2 (async, `:390-505`) is reached only for a Resolve step-3 placeholder, whose id the client cannot load either -- so the 10 s watchdog (`:295-303`) fires and delivers what was there. Callers: `UI/Inventory.lua:600`, `UI/Search.lua:1018`, `UI/Mail.lua:183`. Delete; each caller takes its rows synchronously. |
| `Item:GetInfo(id, link)` -- `:515-556` | **DERIVED** | `GetItemInfo(link)` then `(id)` then a placeholder `{ name = "Item N", rarity = 1, icon = 134400 }`. `Search.lua:1071` calls it to build `Info` for a row that **already carries** `itemEntry.Info` from Resolve -- so a cold client overwrites a LibItemDB name with `Item N`. Replace with the row's own `Info`; the loader's `ContinueOnItemLoad` callback (`:483`) was its other caller. Delete. |
| `Item:Sort` -- `:560-687` | **DERIVED, partly** | The comparators are fine and stay. The pre-pass (`:562-603`) fabricates `Info` from `Link:match("%[(.-)%]")` and re-asks `GetItemInfo(item.Link or item.ID)` for `reqLevel` -- both for rows that predate Resolve. Keep the sort, delete the pre-pass. |
| `Item:IsPlaceholderName` -- `:204-208`, `Item:RequestDisplayName` -- `:220-232` | **DERIVED, correct** | Already go through `Record.new` + `Resolve.name`. Keep. |
| `Item:Aggregate` -- `:695-760` | **DEAD after 3.6** | Legacy row aggregation by `GetItemKey(v.Link or v.ItemString)` with an ID-only merge for linkless rows (MAIL-015). Sole caller `Search.lua:1014`. The store already aggregates by `Record.key` before `viewRow`; Search should not re-aggregate rows that are already one-per-key. |
| `Item:IsUnique(link)` -- `:762-795` | **EDGE** | Scanning tooltip over a **live** inbox link (`Mail.lua:197/:508`, `UI/Mail.lua:169`). Keep as is. |

### 3.6 The consumers of the fabricated legacy row

`Store.viewRow` (`Modules/Inventory/Store.lua:438-457`) presents every record as
`{ ID, Count, Suffix, Enchant, Link, Info = {...} }` so UI written for link-bearing rows kept
working. That shape stays for this release (INV2-COMPAT-001 pins it for TOGProfessionMaster), but
every consumer that re-derives from it what it already carries changes:

| Site | Verdict |
| --- | --- |
| `UI/Search.lua:BuildSearchData` `:998-1093` | Drop `Item:Aggregate` (`:1014`) and `Item:GetItems` (`:1018`); walk `GetAltItems` rows directly. **Identity defect:** `itemNames[v.ID] = v.Info.name` (`:1024-1026`) keys the corpus by **id only**, so the first suffix variant seen names every variant -- "Dreadblade of the Tiger" is filed under "Dreadblade of the Bear" and cannot be found by its own name, while the per-row suffix match at `:1057-1060` then keeps the rows apart under the wrong heading. Key the corpus by the row's own `Info.name`. Drop `Item:GetInfo` at `:1071` for `itemEntry.Info`. |
| `UI/Search.lua:ShowRequestDialog` `:285-305` | `RowSuffixID(itemEntry)` twice -> `itemEntry.Suffix ~= 0 and itemEntry.Suffix or nil` once. Otherwise correct: the request is minted with `itemID` and `suffixID`. |
| `UI/Inventory.lua:546-616` | Drop `GetItems` (`:600`); draw the rows it already has; keep `Item:Sort` on them. |
| `UI/Requests.lua:2626-2701` | See 3.4. `RowSuffixID` at `:2650` goes with the scan. |
| `UI/Browse.lua:190-209` | Already reads the view row without re-deriving. `_id` at `:205` hand-builds `id:suffix:enchant@norm` -- use `Record.keyFor(...) .. "@" .. norm` so the key has one spelling. |
| `UI.lua:DrawItem` `:373-543` | Drop the two `ReconstructItemLink` calls (`:419-421`, `:438-441`) and the rarity fallback (`:479-502`). A row with no link (placeholder) shows the name-only tooltip it already has at `:444-448`. |
| `UI/Mail.lua:160-188` | Rows built from `GetInboxItemLink` as `{ ID, Link, Count }`, fed to `GetItems` for `Info`. Build them through the edge instead: `Scan.parseLink` -> `Record.new` -> `Store.viewRow`'s shape via a small `Resolve`-backed helper (`Store.viewRow` is file-local; expose it as `Store.ViewRowFor(rec)` or move it beside `Resolve.describe`). Same for `UI/Mailbox.lua:34-68`, whose rows carry `link` and key `needed` by `itemID` alone (`:52`) -- a request for one suffix variant lights every variant. |
| `Modules/Log.lua:countsByKey` `:165-184` | Accepts "either row shape"; the legacy `row.ID` branch (`:170-172`) has no producer once `Bank:Scan` hands it records only. Delete the branch. **Identity defect:** the key is `id:suffix` (`:177`) -- no enchant -- while the store's is `id:suffix:enchant`, so an enchant applied to a stored weapon reads as no change in the log. Use `Record.key`. |
| `Modules/DeltaComms.lua:hashInventoryItems` `:39-87` | The `item.ID` (legacy row) branch (`:51-59`) has no producer: all four callers (`Bank.lua:359/417/780`, `Chain.lua:286`, `Chat.lua:3158`) pass records. Delete the branch -- the hash of a **record** must not depend on a code path nothing reaches. (Revision 1, `:89+`, is frozen and untouched.) |
| `Modules/Inventory/Wire.lua:legacyShapeFor` `:215-235` | Measurement only (`/togbank dev bandwidth`). Keep; it is the one honest record of what the old shape cost. |

### 3.7 Live-link matchers (the fulfil side)

| Site | Class | Verdict |
| --- | --- | --- |
| `Bank.lua:MatchContainers` `:831-861` | **EDGE** | Matches a slot to a request by `itemInfo.itemID == targetID` then `GetSuffixID(hyperlink) == targetSuffix` (`:848`), and by name when there is no id. Correct rule (REQ-001/REQ-003). Parser swap only: `select(2, Scan.parseLink(itemInfo.hyperlink))`. |
| `Mail.lua:tog_linkMatchesReq` `:1003-1020` | **EDGE** | Same rule for an inbox link, `GetItemInfoInstant(link)` for the id. Parser swap only. |
| `Bank.lua:FindUnneededBagStack` `:931-949` | **EDGE** | `GetItemInfo(info.hyperlink)` for a name to protect a legacy name-only request. Correct; unchanged. |
| `ItemHighlight.lua` `:10`, `:213-215`, `:234-236` | **identity defect** | `neededItemIDs` keyed by `itemID` only. A request for "of the Bear" highlights every Dreadblade in the bags. Key `id:suffix` (a request has no enchant), read the slot's suffix through `Scan.parseLink` at the three `C_Container` sites (`:712`, `:756`, `:777`) and the Bagnon `details.itemLink` site (`:443-473`). Small; in scope because it is the same identity. |

### 3.8 Request identity (already right, listed for completeness)

`request.itemID` + `request.suffixID` on the wire (`togbank-rd2` slot 12 and the appended suffix
slot, `Modules/RequestLog.lua`), minted at `Search.lua:290-305`, displayed through
`Item:RequestDisplayName` (`Record.new` + `Resolve.name`). Nothing to change beyond 3.6.

## 4. Cross-cutting findings (read sideways)

- **One concept, seven spellings.** "The same item" is spelled: `Record.key` / `keyFor`
  (`id:suffix:enchant`); `Log.countsByKey` (`id:suffix`); `MailInventory.senders` (`id:0`);
  `Browse._id` (inline `id:suffix:enchant@norm`); `Item:GetItemKey` (7-field link substring);
  `Search.itemNames` and `ItemHighlight.neededItemIDs` and `Mailbox.WantedByOpenOrders` (`id`
  alone). Each of the id-only and id:suffix ones has a concrete wrong answer today (3.6, 3.7).
  After the release: `Record.key`, and one spec that greps `Modules/` for `":%d:"`-style
  hand-built keys the way `INV2-ISOLATE-001` pins the writer set.
- **The same behaviour implemented more than once:** two link parsers (3.2), four link builders
  (3.4), two `Info` builders (`Resolve.describe` and `Item:GetInfo`), two aggregators
  (`Record.aggregate` and `Item:Aggregate`), two item databases (3.1).
- **Code with no production entry point:** `ItemClassNeedsLink`, `GetClass`, the two static DBs,
  `ReconstructItemLink`, the `row.ID` branches of `countsByKey` and `hashInventoryItems`, the
  `RowSuffixID` link fallback, `GetItems` branch 2 for anything the client can load.
- **A constant maintained in two places with nothing asserting agreement:** the item-string field
  layout -- `Scan.parseLink` (fields 2/7), `Item:GetSuffixID` (`select(7, strsplit)`),
  `Log:ItemLinkFor`'s regex (six `[^:|]*` groups), `Requests.lua:2688`'s and `Log.lua:667`'s
  `%d:0:0:0:0:0:%d` literals, `MailInventory.lua:89-93`'s prefix stripping. LibItemDB owns the
  layout (`itemString`, `LibItemDB-1.0.lua:312-322`); after the release only `Scan.parseLink` reads
  it and only LibItemDB writes it.
- **Comments asserting callers that do not exist:** `Item.lua:38-46`, `DeltaComms.lua:495-498`,
  `Guild.lua:3023-3025` and `:3055-3057` (UI.lua line numbers there are also stale -- the calls are
  at `:420` and `:439`), `INVENTORY_V2.md:327-332`.

## 5. Behaviour changes and their costs

| Change | Player-visible effect | Cost |
| --- | --- | --- |
| Mail rows carry suffix and enchant | A suffixed item in a banker's inbox shows its full name and merges with the same item once taken into the bags; the log's `from` names the sender of a suffixed deposit | **One content-hash and one mail-hash change per banker** on the first mail-inclusive scan after upgrading -- a version bump each, self-correcting. Every viewer fetches that version once. |
| Static DBs removed | 3.7 MB less parsed at every login on every client | None functionally -- nothing read them. `.luarc.json` / `.luacheckrc` globals removed. |
| Resolve step 2 keeps the suffix | An id LibItemDB lacks still shows and links its variant | **No TOGTools cost** (corrected 2026-09-13, Peer Review on 2a82f9ad, verified in `TOGTools/Modules/GuildBankLog/GuildBankLog.lua:141-145`): `linkSig` strips a link to its itemID and `baseKey` (:176-197) deliberately excludes `name`, so a suffixed link and its base link have the SAME `itemSig`. This row used to say the sig changes; it does not. Display only. |
| `Log:ItemLinkFor` = `Resolve.link` | Log tab and TOGTools rows are quality-coloured with the suffixed name (LOG-TAB-002) | **No TOGTools cost**, same reason: a synthetic white link and the coloured suffixed link carry the same itemID, so `itemSig` and the dedupe key are unchanged. The one line worth telling TOGTools (SUFFIX-NAME-002 already made it true): the `item` string for suffixed rows now carries the family; `itemSig` unchanged. |
| `countsByKey` keys by `Record.key` | An enchant change on a stored item is a log entry | A one-off diff on the first version after upgrading where enchanted rows exist. |
| Search corpus keyed by name | Every suffix variant is findable by its own name | None. |
| ItemHighlight / Mailbox by `id:suffix` | Only the requested variant lights up | None. |
| Async loader deleted | The Inventory window and Search never show "Loading items..." | A placeholder row (Resolve step 3) is drawn immediately with a question-mark icon instead of after a 10 s wait -- which is what happened anyway. |

**No wire format changes.** Records already carry the suffix; the wire (`Wire.lua`) and the chain
(`Chain.lua`) are untouched. `RD2_VERSION` / `RI_VERSION` unchanged.

## 6. Specs

Rewrite, not re-baseline: the spec says how it should behave, then the code moves.

| Spec | Pins |
| --- | --- |
| `Tests/mailinventory_spec.lua` (new) | `ScanMailInventory` returns **records**; a suffixed and an enchanted attachment keep their fields; two attachments of one variant aggregate to one record; a COD mail is skipped; `senders` keyed by `Record.key`. |
| `Tests/bank_spec.lua` | The stored mail source equals the scanner's records; the mail hash over a suffixed attachment differs from the same item unsuffixed (the one-off bump, stated). |
| `Tests/resolve_spec.lua` | Step 2 builds the link from `BuildItemString(id, suffix, enchant)`; a suffixed record for an id LibItemDB lacks never yields `"item:<id>"`. |
| `Tests/log_spec.lua` / `logwho_spec.lua` | `ItemLinkFor` returns `Resolve.link`'s coloured suffixed link; no white synthetic link exists (grep the file for `cffffffff`); `countsByKey` separates enchant variants. |
| `Tests/togtoolsbridge_spec.lua` | Rows carry the coloured suffixed link; the itemSig-affecting cases stated. |
| `Tests/search_spec.lua` (new or extended) | Corpus keyed by name; two variants of one id are two corpus entries; `GetAltItems` rows reach `Lookup` with `Info` intact on a cold client (no `Item N`). |
| `Tests/item_spec.lua` | Delete the blocks for `GetItemKey`, `GetItemString`, `GetSuffixID`, `ItemClassNeedsLink`, `GetItems`, `GetInfo`, `Aggregate`; keep `RequestDisplayName`, `IsPlaceholderName`, `IsUnique`, `Sort` comparators. |
| `Tests/suffixcarry_spec.lua`, `hideitems_spec.lua` | `RowSuffixID` -> `row.Suffix`; assertions unchanged in meaning. |
| `Tests/inv2_isolate_spec.lua` (existing INV2-ISOLATE-001) | Extend: `Modules/` has exactly ONE link parser (`Scan.parseLink`) and ONE link builder (`Resolve.describe`), by reading the files -- the same technique that pins the writer set. |
| `Tests/wiring_spec.lua` / TOC spec | Neither TOC lists `Modules/Static/`; `TOGBankClassic_ItemDB` and `TOGBankClassic_SuffixDB` are not globals after load. |
| `Tests/itemhighlight_spec.lua` | A request for suffix 1196 does not highlight suffix 0 of the same id. |

Coverage stays at the harness gate (`lua Tests/wowapi/coverage.lua` on every touched module).

## 7. The release, in order

1. **Delete the dead weight** (3.1, `ReconstructItemLink`, `RowSuffixID`'s fallback, the two
   `row.ID` branches, the loader's async branch). Suite green with no behaviour change -- proves
   nothing reached it.
2. **Fix Resolve step 2** (suffix-preserving). Specs first.
3. **Collapse the builders** onto `Resolve` (`ItemLinkFor`, Requests tooltip, `UI/Mail.lua`,
   `Mailbox.lua`). LOG-TAB-002 closes here.
4. **Collapse the parsers** onto `Scan.parseLink` (`Bank.lua:848`, `Mail.lua:1011`,
   `ItemHighlight`). Delete `GetSuffixID`.
5. **The mail edge** (3.3): `ScanMailInventory` returns records; `Bank:Scan` stores them; `senders`
   by key. This is the step that bumps hashes -- last, so everything before it ships as a no-bump
   change if the release has to be split.
6. **Search and the loader** (3.5, 3.6): delete `GetItems`, `GetInfo`, `Aggregate`,
   `GetItemKey`, `GetItemString`; Search keyed by name.
7. **One identity spec** (section 4) and the docs: `INVENTORY_V2.md` section 8 rewritten,
   `CHANGELOG.md` with the hash-bump cost stated, the player notes. (The TOGTools contract thread
   no longer needs an `itemSig` warning -- section 5 was corrected on 2026-09-13: the sig is the
   itemID alone and does not move.)

## 8. Not covered / least sure of

- **TBC negative suffix ids.** `Scan.parseLink` and `Record.key` preserve a negative suffix, but
  LibItemDB's `randomProps` holds only positive `ItemRandomProperties` ids
  (`LibItemDB-1.0.lua:406-415`; no negative key in any `Data/*/RandomProps.lua`). A TBC item with a
  negative (ItemRandomSuffix) id would resolve to the **base name** with the right item string, so
  the tooltip is correct and the name is not. I have not verified that Classic-TBC links ever carry
  a negative seventh field -- the client source does not say. If they do, it is a LibItemDB contract
  (`LIBREQ-IDB-00x`), not a TOGBank change.
- **TBC gems.** Fields 3-6 are not carried in the record at all (`INVENTORY_V2.md:347`, still
  "Unresolved"). Out of this audit's scope; noted so it is not mistaken for covered.
- **TOGProfessionMaster's read** of `Info.alts[name].items` (INV2-COMPAT-001) is unchanged by
  everything above -- the view row shape is kept -- but I have not read TPM's consumer to confirm it
  reads nothing beyond `ID`, `Count`, `Link`, `Info`.
- **`GetItemInfo(itemString)` behaviour on a cold client** for the step-2 rewrite: I have read the
  Blizzard documentation for `SetHyperlink` accepting an item string, not measured what
  `GetItemInfo` returns for a suffixed item string the client has never seen. The spec must drive
  both answers (nil and a link) and the code must be right for both.
- **The P2P handshake, the chain, the publish gate, the UI layout** -- out of scope by the
  directive, not read for this.
