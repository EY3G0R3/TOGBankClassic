# Merging GuildShoppingList into TOGBank (GSL-MERGE-001)

Design note, 2026-09-17. The directive it answers, in the operator's words:

- GSL-MERGE-001 (2026-09-16): _"add to the todo list to merge the GSL addon into TOGBank, put it at
  the bottom"_.

Status: **DESIGN ONLY. NOTHING IS BUILT.** The todo item's own first step is _"read GuildShoppingList
end to end and write the merge design in `docs/` before touching code"_, and this is that document.
Section 8 is the build order; section 2 carries the decisions that need the operator's yes before any
of it starts, because two of them drop behaviour a guild may be using.

## 1. What was read, and what it settles

Everything below was read in the installed source on 2026-09-17: `..\GuildShoppingList`'s five TOC
files, `GSLCore.lua` (90 lines), `GSLUtilities.lua` (229), `GuildShoppingList.lua` (1,559),
`GSLComs.lua` (130), the eight `Recipes\*.lua` data files, `README.md` and `docs\AUDIT.md`. Nothing
here is recalled.

### 1.1 What GuildShoppingList actually is

One designated player, the **GSL player**, keeps a list of things the guild wants crafted. Everyone
else reads it. Mechanically:

- **The role is a guild-note marker.** `ScanGuildForGSLPlayer` walks `GetGuildRosterInfo` for a note
  containing `[GSL]` and takes the first match (`GuildShoppingList.lua:793-803`). This is the same
  pattern TOGBank uses for `gbank`, arrived at independently.
- **The list is an array of strings.** `GuildShoppingList_SavedItems` holds entries spelled
  `"<Recipe Name> x<N>"`, parsed back out with `item:match("^(.-) x(%d+)$")` at seven sites. There is
  no item id, no recipe id, and no profession on an entry.
- **Recipes are eight hand-written tables**, `Recipes\*.lua`, keyed by recipe NAME, whose reagents
  are `{ name = "<item name>", count = n }` -- keyed by item NAME as well. `RecipeData` is assembled
  in `GSLCore.lua:80-88` and a lowercase index is built beside it for case-insensitive lookup.
- **"What we already have" is ONE player's bags and bank.** `CacheGSLPlayerBagCache` and
  `CacheGSLPlayerBankCache` scan the GSL player's own containers into two name-keyed maps
  (`GuildShoppingList_GSLPlayerCache`, `GuildShoppingList_GSLBankCache`). Every other member's
  holdings are invisible to the list.
- **Sync is whole-state, newest-timestamp-wins.** `GSL:ShareShoppingList` serialises the list, both
  caches and the date range into one `GSLShare` message to GUILD; a receiver replaces its whole local
  state when the incoming timestamp is larger (`GSLComs.lua:65-88`). `GSLRequest` carries a
  timestamp, and anyone holding a newer one answers by whisper.
- **A gather window.** Two dates in `GuildShoppingList_Config`, set through a hand-rolled calendar
  picker of 42 day buttons per month with its own Zeller's-congruence weekday maths
  (`GuildShoppingList.lua:1262-1550`).
- **Two windows.** A main frame with a Shopping List tab and a Reagent List tab, and a separate
  draggable, borderless **Reagent Tracker** overlay showing the same reagent roll-up.

### 1.2 Every piece of it already exists here, better

This is the finding that decides the whole shape of the merge. GSL is not a feature TOGBank lacks; it
is a second, weaker implementation of machinery TOGBank already has, wrapped around one genuinely new
idea (recipe expansion into reagent demand).

| GuildShoppingList | TOGBank today |
| --- | --- |
| `[GSL]` note marker, one player | `gbank` note marker, `Guild:IsBank`, view-only markers, officer and GM ranks |
| whole-state timestamp-wins broadcast | canon hashes, per-banker delta records, the P2P handshake, AceCommQueue, checksum framing |
| GSL player's bags+bank, by item NAME | `Inventory/Store` per banker, `Guild:GetAltItemTotal(alt, itemID)`, O(1) through a per-alt index |
| `"Name xN"` strings | the request log: records with `itemID`, quantity, a fulfilled count, tombstones, a relay |
| `Recipes\*.lua` by name | `LibProfessionDB-1.0`, keyed by spell id, reagents keyed by **item id** |
| hand-rolled calendar, 290 lines | LibAceGUIWidgets' DatePicker widget |
| two hand-built frames, FontString pools | the Guild Bank window's tab set and `UI/RowList` |
| its own minimap button | already has one |
| `/gsl`, `/gslshare`, `/gslclear` and five more | the `/togbank` command table |

### 1.3 The one thing GSL has that TOGBank does not

**Recipe expansion.** "The guild wants 20 Elixirs of Fortitude" becomes "40 Wild Steelbloom, 20
Goldthorn, 20 Crystal Vial", and that demand is then checked against what is already held. TOGBank
tracks items and orders against them; it has never modelled a thing that has to be MADE out of other
things. That expansion, and the reagent roll-up it feeds, is the feature worth carrying over. Almost
nothing else is.

### 1.4 LibProfessionDB-1.0 already holds the recipe data, keyed correctly

`..\ProfessionDB` ships `LibProfessionDB-1.0`, a fleet library whose entries are
`[profId][recipeId] = { name, reagents, difficulty, requiredSkill, craftedItemId, itemId, ... }` with
**`reagents` keyed by item id** (`LibProfessionDB-1.0.lua:17`, and `lib:GetReagents(profId,
recipeId)` at `:685`). It exposes `GetProfessions`, `GetRecipes`, `GetRecipe`, `GetName`,
`GetReagents`, `GetCraftedItemID` and a `Search`.

Two consequences:

1. **The eight `Recipes\*.lua` files are redundant** and can be deleted rather than ported. They are
   also incomplete and partly wrong: `AlchemyRecipes.lua` has TBC flasks commented out, and carries
   at least two entries whose reagent list names the crafted item itself (`Elixir of Detect Undead`,
   `Gurubashi Mojo Madness`), which would make the tracker demand an item in order to make it.
2. **The name-keyed matching goes away at the root.** GSL matches reagents by item name, which is the
   exact defect class this addon already fought and wrote a rule about: item names are not unique
   (REQ-001, the Punctured Voodoo Doll variants). An item-id-keyed reagent list matched against
   `GetAltItemTotal(alt, itemID)` is correct by construction.

### 1.5 The coverage is measured, and the large part of the shortfall is naming, not missing data

Build step 1 was run on 2026-09-17 rather than left as an assumption: GSL's eight tables loaded
beside the library's Vanilla core and enUS name data, diffed by lowercased name.

| | count |
| --- | --- |
| recipes the library holds (Vanilla, enUS) | 1,534 |
| names across GSL's eight tables | 1,106 |
| matched by exact name | 924 |
| unmatched | 182 |

The 182 break down into three causes. The first is verified against the data and is the large one;
the second is the one claim in this document that is NOT verified, and it is the only one that could
still turn out to be missing data:

1. **GSL's own shorthand naming, which is most of it.** All 103 unmatched Enchanting names and
   several Blacksmithing ones are GSL's spellings, not the game's. GSL writes
   `Crusader (enchant)`; the library holds `Enchant Weapon - Crusader` **with `effect = "Crusader"`**
   (`Data/Vanilla/enUS/Enchanting.lua:476-477`). GSL writes `Blight (polearm)`, `Corruption (sword)`,
   `Nightfall (axe)`, `Serenity (mace)`; the library holds `Blight`, `Corruption`, `Nightfall`,
   `Serenity` (`Data/Vanilla/enUS/Blacksmithing.lua:377,575,581,683`). The library carries MORE
   Enchanting recipes than GSL does, 199 against 117.
2. **Recipes the Vanilla data does not carry, which look like later-expansion entries**: the forged
   weapons in the Blacksmithing list (`Earthforged Leggings`, `Light Earthforged Blade`,
   `Light Emberforged Hammer`, `Light Skyforged Axe`) and most of the unmatched Cooking
   (`Delicious Chocolate Cake`, `Fancy Darkmoon Feast`, `Juicy Bear Burger`, `Lynx Steak`,
   `Hot Apple Cider`). **NOT VERIFIED, and it is the weakest claim in this document:** that these are
   post-Vanilla recipes is recall, not a lookup. What IS measured is only that the Vanilla data does
   not carry them. If any turns out to be a Vanilla recipe the library is missing, that is a gap to
   raise with ProfessionDB and it would weaken the "coverage is complete" reading below. Cause 1 is
   the one verified against the data, and it is the large one.
3. **The Miscellaneous bucket, which is not recipes at all.** All seven entries are the Winterspring
   E'ko turn-in items. They are guild sundries, which is what that catch-all list was for.

**What this changes:** nothing in D3, which stands. It sharpens **D9**: the migration matches a saved
name against the library's `name`, then its `effect`, then the name with a trailing parenthetical
stripped, in that order, which recovers the bulk of cause 1. Causes 2 and 3 are reported to the player
as unmapped, which is the correct answer for both. And it is the argument for the whole design in one
line: **a list that stores names needs three fallbacks and still loses entries; a list that stores
recipe ids needs none.**

## 2. The decisions

**D1. The shopping list becomes a CRAFT LIST that lives in guild settings, and GSL's sync is
deleted.** The list is small (a few dozen entries of `{ profId, recipeId, count }`, well under a
kilobyte) and it is guild-wide state written by a few people, which is exactly what
`Guild.Info.settings` already carries on the `togbank-hl` rail, with per-field stamps
(SETTINGS-004), an authorization gate on banker/officer/GM, and a federated whisper to sister guilds
for free. GSL's timestamp-wins whole-state broadcast is not ported. `bankerOwners` /
`bankerOwnerStamps` is the precedent to copy: a stamped map inside settings, merged entry by entry.

**D2. SETTLED 2026-09-25 by the operator: the GSL player stays, as a note tag like `gbank`, and
officers and the GM edit the list too.** The operator's words: _"so the GSL player is a tag like
gbank, use what is in the GSL app for that. the officers/gm should be able to edit the shopping
list"_. So the list's writers are: the GM, officers (the existing `SenderIsOfficer` /
`SenderIsGM` gate), and any member whose public note contains `[GSL]` -- GuildShoppingList's own
marker, matched the way it matches it (`note:find("%[GSL%]")`, `GuildShoppingList.lua:799`), so a
guild's existing tag keeps working after the switch. It joins the D1 settings gate as a third
writer and is detected beside `gbank` in the roster pass. Everyone reads the list.
(This paragraph first recommended dropping the role; the operator ruled the other way, and the
recommendation is not reopened.)

**D3. Recipe data comes from `LibProfessionDB-1.0`; the eight `Recipes\*.lua` files are deleted.**
Reagents keyed by item id (1.4). The library becomes a declared dependency in both TOCs.

> **KNOWN COST, now measured (1.5) rather than guessed:** the library carries every Vanilla recipe
> GSL's tables do, and more. What it does not carry is GSL's Miscellaneous bucket -- seven
> Winterspring E'ko turn-in items, which are not recipes. A guild that used Miscellaneous for guild
> sundries loses that list unless a plain "wanted item" entry is added beside the recipe entries.
> **Resolved 2026-09-25 by reading the operator's ruling** that the officer tab have _"the
> same/improved functionality in gsl"_: GSL could list those items, so the model carries a plain
> wanted-item row (`{ itemID, count }`, no recipe) beside the recipe rows. That is an inference from
> "same functionality", not a separate answer; if the operator says otherwise, the row type comes out.

**D4. "What the guild already has" is the BANK, not one person's bags.** The demand column is
the sum over `Guild:GetBanks()` of `Guild:GetAltItemTotal(banker, reagentItemID)`. This is strictly
more useful than what GSL showed and costs nothing new: the index already exists and is already
synced. The player's own bags stay as a separate "You" column, as GSL had.

**D5. The Reagent Tracker overlay is kept, as a detached view of the same data.** It is the piece of
GSL a gatherer actually uses while out in the world, and nothing in TOGBank replaces it. It is
rebuilt on `UI/RowList` against the shared computation, not ported frame by frame.

**D6. A craft-list row can become a REQUEST with one click.** "The guild wants 20 of this and the
bank holds the reagents" is one click away from the existing order pipeline, which already handles
assignment to a banker, mail fulfilment and the fulfilled count. This is the join that makes the
merge worth more than the sum of the two addons, and it is deliberately LAST in the build order so
the list ships without it if it proves awkward.

**D7. The gather window is kept, on LibAceGUIWidgets' DatePicker.** Two dates in the same settings
map as the list, so it syncs by the same rail with no extra work. The 290 lines of hand-rolled
calendar are not ported.

**D8. GuildShoppingList is RETIRED, not left running beside TOGBank.** Two addons both scanning the
same bags and both drawing a reagent list is the duplicate-implementation problem this merge exists
to end. Its CurseForge project gets a final release whose description points at TOGBank; its
SavedVariables are read once by a migration (D9) and then left alone.

**D9. A one-time migration reads GSL's saved list, by name, and says what it could not map.** On
first load with `GuildShoppingList_SavedItems` present and no craft list yet, each `"Name xN"` entry
is resolved through LibProfessionDB to a `{ profId, recipeId, count }` by **name, then `effect`, then
the name with a trailing parenthetical stripped** -- the three spellings 1.5 measured GSL actually
using. Anything that still does not resolve is reported to the player by name, once, rather than
dropped silently. The two GSL bag
and bank caches are NOT migrated: they are a snapshot of one player's containers keyed by item name,
and the bank the addon already tracks supersedes them.

## 3. What it looks like to a player

**SETTLED 2026-09-25 by the operator:** _"make a tab for the shopping list itself, and then an
officer only tab to set it up with the same/improved functionality in gsl. but i want to use the
look and feel of the new bank for the tabs."_ So there are **TWO tabs** in the Guild Bank window,
beside Browse, Shop, Bankers, Requests and Log, both built like those tabs (the strip, `UI/RowList`,
the shared chrome):

- **Shopping List**, for everyone: what the guild wants and the reagent roll-up, described below.
- **Shopping List setup**, shown only to the list's writers (D2): adding and removing recipes and
  wanted items, counts, the gather window -- everything GSL's own editing did, improved where
  TOGBank's machinery allows (recipe search through LibProfessionDB, item-id matching).

The paragraph below predates the ruling and describes the editing controls as part of one tab; read
them as living on the setup tab.

- **Top strip**, the shape every other tab uses: a search box, a profession dropdown, and the gather
  window as two date buttons. Officers also get a recipe search box and an Add control; everyone else
  sees the strip without them, exactly as the Requests tab already varies by role.
- **The list**, one row per wanted item: the item's icon and name, the profession, how many are
  wanted, how many the bank already holds of the finished item, and a per-row state. Officers get
  edit and remove controls on the row; a right-click menu carries "order this from a banker" (D6).
- **A Reagents view** of the same list, one row per reagent: the reagent, how many the whole list
  still needs, how many the bank holds, how many you are carrying, and what is still missing. This is
  GSL's Reagent List tab and its overlay, computed once.
- **The detached tracker**, toggled from the tab and from the minimap button's right-click, showing
  the reagent view in a small movable window for use while gathering.

## 4. Wire changes, in full

| Change | Prefix | Distribution | New? |
| --- | --- | --- | --- |
| `craftList` and its stamp inside the settings payload | `togbank-hl` | GUILD, and WHISPER to a federated asker | no new prefix, two new fields |
| `gatherStart` / `gatherEnd` in the same payload | `togbank-hl` | as above | two new fields |

**No new prefix, no new message type, no change to any positional format.** A client too old to know
the fields ignores them, as `ApplyRemoteSettings` already does for any unknown key, and keeps
working; it simply shows no craft list. That is the mixed-version cost, and it is the smallest one
available.

## 5. The pieces, by file

- **`Modules/CraftList.lua` (new)**, `TOGBankClassic_CraftList`. The model: read and write the list
  through the settings rail (D1), the officer gate, the expansion of a list into reagent demand
  through LibProfessionDB (D3), and the demand-against-bank computation (D4). No frames.
- **`Modules/Guild.lua`**: `craftList`, `craftListStamps`, `gatherStart`, `gatherEnd` added to
  `SettingsFields` and to the per-field adopt list in `ApplyRemoteSettings`. Mechanically identical
  to what `bankerOwners` already does.
- **`Modules/UI/CraftList.lua` (new)**, `TOGBankClassic_UI_CraftList`. The tab: the strip, the two
  RowList views, the row menus. Follows `Modules/UI/Browse.lua`'s shape, which is the canonical one.
- **`Modules/UI/Browse.lua`**: one more entry in `TABS`, one more branch in `RedrawCurrent`, the
  floor recomputed for the new columns.
- **`Modules/UI/CraftTracker.lua` (new)**: the detached overlay (D5), persisted through
  `UI:PersistWindow` like every other window.
- **`Modules/Chat.lua`**: `/togbank craft` opens the tab, `/togbank tracker` toggles the overlay.
  The `/gsl` commands are NOT carried over; the retired addon owned those names.
- **`Modules/Database.lua`**: the one-time GSL migration (D9), beside the existing load-time
  migrations.
- **Both TOC files**: `LibProfessionDB` added to `## Dependencies`, the three new modules added in
  dependency order, in lockstep.

## 6. Offline spec plan

- **`Tests/craftlist_spec.lua`**: the model alone. An officer writes, a member cannot; the list
  round-trips through the settings payload and merges entry by entry against an older and a newer
  stamp; expansion of a list into reagent demand against a stubbed LibProfessionDB, including a
  recipe the library does not carry; demand against a bank with two bankers holding the same reagent;
  the migration, including an entry that resolves and one that does not.
- **`Tests/craftlistwindow_spec.lua`**: the tab on the real AceGUI stack. Both views' rows and
  columns, the officer-only controls appearing and disappearing with the role, the accessibility
  scale, the tracker's persistence.
- **`Tests/xguildfleet_spec.lua`**: one added example, an officer's craft-list write reaching a
  sister guild on the existing federated whisper without wiping that guild's own copy. The
  `bankerOwners` example beside it is the model to copy.
- **The real `LibProfessionDB-1.0` is loaded from the sibling install**, as every other library in
  this suite already is, rather than stubbed.

## 7. What is deliberately NOT carried over

Named so a later session does not read the absence as an oversight:

- **The whole-state timestamp-wins sync** (D1), the `GSLShare` / `GSLRequest` prefixes, and
  `GuildShoppingList_GSLDataSyncTimestamp`.
- **The eight `Recipes\*.lua` tables** (D3), including their commented-out TBC entries.
- **The two name-keyed caches** `GuildShoppingList_GSLPlayerCache` and
  `GuildShoppingList_GSLBankCache` (D4, D9).
- **The hand-rolled calendar** and its Zeller's-congruence weekday maths (D7).
- **Every `/gsl` slash command** and the separate minimap button.
- **`GuildShoppingList_ForcedGSLPlayer`**, a debug override with no UI.

## 8. Build order

1. **Measure the recipe coverage. DONE 2026-09-17, section 1.5.** 924 of 1,106 names match exactly;
   the 182 that do not are GSL's own shorthand, later-expansion recipes, and the non-recipe
   Miscellaneous bucket. D3 stands, D9 gained two fallbacks, and no contract to ProfessionDB is
   needed.
2. **The model** (`Modules/CraftList.lua`) and its settings fields, with `craftlist_spec`. Buildable
   and provable with no UI at all.
3. **The tab** (`Modules/UI/CraftList.lua`, the Browse wiring) with `craftlistwindow_spec`.
4. **The tracker overlay** (`Modules/UI/CraftTracker.lua`).
5. **The migration** (D9) and the federated example in `xguildfleet_spec`.
6. **Docs, changelog, the CurseForge page and README**, and the final GuildShoppingList release
   pointing at TOGBank (D8).
7. **The order-from-a-row join** (D6), last, because the list is useful without it.

**Where it stands (2026-09-25):** **step 1 is done** (1.5) and nothing else is built. The two open
decisions are answered: D2 (writers: GM, officers and the `[GSL]` tag) and the Miscellaneous
bucket (a plain wanted-item row). **Timing, SETTLED by the operator the same day:** _"we aren't doign
the work yet right? i want to push out what we've done, then start a new major patch version for the
GSL integration"_ -- v1.6.1 ships first, and this merge is the next version after it, not part of
v1.6.1. The version number is chosen when that release is committed.
