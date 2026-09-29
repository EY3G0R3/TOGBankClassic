# TOGBankClassic Changelog

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

## [v1.7.0] (2026-09-26) - The Shopping List

GuildShoppingList merged into TOG Bank (GSL-MERGE-001; the operator, 2026-09-25: *"ok, we can do the gsl
integration in v1.7.0"*). Design and build order: `docs/GSL_MERGE.md`. The operator's standing rule
for the whole merge: *"i don't want to build new stuff as much as possible i want to use the
libraries"* -- LibProfessionDB, LibItemDB through `Inventory/Resolve`, LibAceGUIWidgets.

### New Features

- **GSL-MERGE-001 step 2: the shopping list's model** (`Modules/CraftList.lua`, new;
  `TOGBankClassic_CraftList`). What the guild wants crafted (a LibProfessionDB recipe) or gathered (a
  plain item, GuildShoppingList's Miscellaneous bucket), and the gather window. **Writers** (D2, the
  operator: *"so the GSL player is a tag like gbank, use what is in the GSL app for that. the
  officers/gm should be able to edit the shopping list"*): the GM, officers, and a home member whose
  PUBLIC note carries `[GSL]` (GuildShoppingList's own marker, `GuildShoppingList.lua:799`).
  **Sync:** four fields on the existing guild-settings payload -- `craftList` and `craftListStamps`
  merged entry by entry (a removal keeps its stamp; the `bankerOwners` rule), `gatherStart` /
  `gatherEnd` field by field. `BroadcastSettings` now sends from a `[GSL]` member, and
  `ApplyRemoteSettings` takes ONLY the list from one. The four fields are left out of
  `SettingsCanon`, so a v1.6.1 client with the same settings still matches (KNOWN COST in the code).
  A sister guild's list never crosses. **Demand:** a recipe expands into its reagents (LibProfessionDB,
  by item id) for what the HOME bank does not already hold of the crafted item; each reagent row nets
  the home bank (`Guild:GetAltItemTotal`) and your bags (`C_Item.GetItemCount`); items are named
  through `Inventory/Resolve`. **ProfessionDB is a required dependency** in every TOC and `.pkgmeta`
  (slug `libprofessiondb`). No window yet (step 3). Offline: `Tests/craftlist_spec.lua` (new, 20,
  on the real ProfessionDB Vanilla Alchemy data; the canon example goes red with the exclusion
  removed). Locations: `Modules/CraftList.lua`, `Modules/Guild.lua`, the TOCs, `.pkgmeta`,
  `.luacheckrc`, `.luarc.json`.
- **GSL-MERGE-001 step 3: the two tabs** (`Modules/UI/CraftList.lua`, new;
  `TOGBankClassic_UI_CraftList`). In the Guild Bank window, after the existing tabs so none moves:
  **Shopping List** for everyone (a View dropdown between what the guild wants, with its profession,
  how many the home bank holds and how many are still needed, and the reagents that takes, with
  Needed, Bank, You and Missing), and **List Setup** for the list's writers only (a search across
  LibProfessionDB recipes and, with no profession picked, LibItemDB items; a How many box; left-click
  puts an entry on the list or changes its count, right-click takes it off; the gather window on
  LibAceGUIWidgets' date picker). Built on the existing machinery, per the operator's rule: Browse's
  tab group and `BuildSimpleStrip`, `UI/RowList`, the shared chrome and status line, items named
  through `Inventory/Resolve`. Profession names and icons come from the client's
  `C_TradeSkillUI.GetTradeSkillDisplayName` / `GetTradeSkillTexture` (present in the Era, TBC and
  MoP trees). `Browse:SyncTabs` re-renders the tab strip on open when the set of tabs changed, since
  the writer role moves with the roster, and `Browse:RememberedTab` now validates its fallback too,
  so a demoted writer is not reopened on a tab the strip no longer carries. A refused edit says
  whether the player may not edit the list or the list already holds that count. The quality-coloured
  item name is one helper, `UI:QualityText`, which the Browse rows now use as well. Offline:
  `Tests/craftlistwindow_spec.lua` (new, 13, on the real Guild, ProfessionDB Alchemy data, LibItemDB
  for the item search, AceGUI, Browse and the date pickers; red with List Setup shown to everyone,
  and red with every open rebuilding the tab strip).
  `C_TradeSkillUI` comes from the harness (WoWAPITesting `ee56a45`, thread b856f5a5).
  `Modules/UI/CraftList.lua`, `Modules/UI/Browse.lua`, the three TOCs, `.luacheckrc`,
  `.luarc.json`.
- **GSL-MERGE-001 step 4: the Reagent Tracker** (`Modules/UI/CraftTracker.lua`, new;
  `TOGBankClassic_UI_CraftTracker`; D5). GuildShoppingList's detached overlay as a small window of
  its own, showing the Shopping List tab's reagent roll-up (`UI_CraftList:ReagentRows`, the same
  columns), sorted by Missing, persisted as `tracker`. It repaints on a list change, on
  `BAG_UPDATE_DELAYED` while shown (registered on open, dropped on close, as ItemHighlight does),
  when bank data lands (`UI_Inventory:RefreshSoon` now fans out to it on its own debounce, since it
  is often up with neither bank window open), and on a roster change (`Browse:Refresh`). It opens
  from a Tracker button on the Shopping List strip and from the new `/togbank tracker`. It is
  deliberately left out of Escape: a gathering overlay that the Escape stand-in counted would close
  on every Escape pressed in the world instead of the game menu opening. Offline: six examples in
  `Tests/craftlistwindow_spec.lua`; the bank-data one was red before the `RefreshSoon` fan-out
  existed, and the bag-update one fires the real event through the harness and asserts the
  registration on open and its removal on close (Peer Review F5, red with the registration taken
  out). `Modules/UI/CraftTracker.lua`, `Modules/UI/Inventory.lua`, `Modules/UI/Browse.lua`,
  `Modules/UI/CraftList.lua`, `Modules/Chat.lua`, the TOCs, `.luacheckrc`, `.luarc.json`,
  `README.txt`.
- **GSL-MERGE-001 step 5: GuildShoppingList's list comes across, once** (D9;
  `CraftList:ImportGSL`, `CraftList.ResolveGSLName`). On a roster refresh
  (`Guild:RefreshOnlineCache`, both the library and the legacy path, beside the officer-floor
  publish), a client that may edit the list and whose guild has never had one (no entries and no
  stamps) reads `GuildShoppingList_SavedItems` (`"<name> x<N>"`) and its gather dates
  (`GuildShoppingList_Config.GatherStartDate/GatherEndDate`), writes the entries, and publishes
  once. Each name is matched through LibProfessionDB by recipe name, then effect, then both with a
  trailing parenthetical stripped, and last as a plain item by its exact name through LibItemDB
  (GuildShoppingList's Miscellaneous turn-in items). A spelling two recipes or two items share maps
  to neither (REQ-001); an ambiguous name does not fall through to the effect. Repeats are summed.
  The entries are stamped `CraftList.IMPORT_STAMP` (1), older than any TOGBank edit, because the
  first roster refresh can come before this client has heard the guild's list: stamped "now", an
  import would have overwritten the guild's counts and brought back entries it had removed (Peer
  Review F1 on self-audit 13180dbf). What matches nothing is reported with `Output:Response`, which
  no setting mutes, and the names are kept in `db.global.gslImport.unmappedNames` (F2).
  GuildShoppingList's variables are account-wide, so the import runs once per account. KNOWN COST in
  the code: on an account with writers in two guilds the list goes to whichever guild such a
  character logs into first; the gather dates ride the ordinary settings stamp, so the race can
  still let imported dates replace a guild's newer ones; and on a client that has never held the
  guild's settings, an import racing an existing list is merged into it rather than refused (Peer
  Review on daa08281). The
  migration lives in `Modules/CraftList.lua`, beside the list's other writers, rather than
  `Modules/Database.lua` as the design first said, because it writes through the list's own rules.
  Offline: six `Tests/craftlist_spec.lua` examples on the real ProfessionDB Alchemy and Enchanting
  data and the real LibItemDB, including the race (red with the import stamped now), a recipe effect
  two recipes share (`Health +5`, red with the ambiguity marking removed) and a name nine items share
  (Punctured Voodoo Doll, red with the two-ids refusal removed); the importing examples went red
  with the roster hook removed. And one
  `Tests/xguildfleet_spec.lua` example: a home `[GSL]` bank character's list reaches its guild,
  and neither a whisper of it nor a federation pull puts it in the sister guild (red with the
  XGUILD-SETTINGS-001 gate taken out). `Modules/CraftList.lua`, `Modules/Guild.lua`.
- **GSL-MERGE-001 step 7: order from a Shopping List row** (D6; `UI_CraftList:OnListRowClick`,
  `UI_CraftList:OrderSource`). A left click on a row in either view (a wanted item, the item a wanted
  recipe makes, or a reagent) opens the existing request dialog on the bank character holding the
  most of it. The row comes from `Browse:BuildRows`, the Browse tab's own rows, so a sister guild's
  bank character counts as it does there, and the click goes through `Browse:OnBrowseRowClick`, so
  ordering closed, not-for-sale and the request limit refuse it exactly as on the Browse tab. A
  view-only bank and a hidden row are skipped when choosing. An enchant (no item) and an item no bank
  character holds say so on the status line; Shift/Ctrl-click links or previews; a right-click does
  nothing. A tie goes to the first bank character in name order. Offline: eight
  `Tests/craftlistwindow_spec.lua` examples (six red before the change). The spec's bank fixture now
  runs the real `Guild:RebuildBankerRoster` from the banker's gbank note, the path a live client
  takes on `GUILD_ROSTER_UPDATE`, rather than a hand-set roster (Peer Review on self-audit
  93c01c04). `Modules/UI/CraftList.lua`.
- **WANTED-BREATH-001: Still needed breathes** (the operator: "can you have the wanted stuff
  'breath' using the function from the widgets library?"). On the Shopping List tab's Wanted view
  the Still needed number pulses through LibAceGUIWidgets' `W:Breathe` (the call the help icon, the
  cancelled date and the stay-online line make) while it is above zero, and stops at full alpha when
  the bank covers it. The breath animates a frame, so the column builds its own cell (a frame
  holding the number) and the list's `onRowRender` paints it; a pooled row reused for a met entry is
  stopped, not left dim. Offline: one `Tests/craftlistwindow_spec.lua` example (red before).
  `Modules/UI/CraftList.lua`.
- **SETUP-SPLIT-001: List Setup split, TOGPM's shopping-list box on top** (the operator: "split
  the list setup into whats on the list on top and the selection bit on the bottom. lets make it
  look like TOGPM's 'shopping list' bit at the top of the professions page"). What is on the list is
  now a bordered box at the top of the tab (`UI_CraftList.SetupBox`, a RowList): icon,
  quality-coloured name, type, then TOGPM's `-` count `+` and red `x`. It is capped at 40% of the
  tab's height and scrolls beyond that, as TOGPM's is. The search results sit under it, and an
  empty search no longer lists the list there. `-` from 1 and `x` take an entry off; every control
  goes through the list's own writers and the same may-edit gate as a result click
  (`UI_CraftList:StepEntry` / `RemoveEntry` / `WriteEntry`). TOGPM's "!" alert and reagent expander
  are not carried: they are per-character craft features with no meaning for a guild list.
  `OnSetupRowClick`'s branch for on-list rows could no longer be reached and is removed.
  `Browse:AnchorLists` calls `UI_CraftList:AnchorSetup` to put the box over the results. Offline:
  the old "empty search lists the list" example is replaced by four (box over results, the
  controls, a member refused, the height cap). `Modules/UI/CraftList.lua`, `Modules/UI/Browse.lua`.
- **GATHER-BREATH-001: the gather dates breathe** (the operator, of the Shopping List tab's
  "3 wanted -- gathering 2026-09-26 to 2026-10-03": "the date isn't breathing"). That line was what
  "the wanted stuff" in WANTED-BREATH-001 meant, and I built the Still needed pulse instead; the
  Still needed pulse stays unless the operator wants it gone. The status bar gains
  `Instance:SetLeftBreathing(on)`: the left text is AceGUI's FontString on the pooled status
  background, which cannot host the breath (BREATH-001), so the first request moves it onto a frame of
  the bar's own (cached on the pooled background, as the centre host is, POOL-CHROME-001) and the
  bar's release hands it back, still. `UI_CraftList:Draw` asks for the breath while the Shopping List
  tab shows a gather window; `HideLists`, which every tab switch passes through, stops it, so no other
  tab's line breathes. Offline: two `Tests/statusbaryield_spec.lua` examples on the real bar (the
  breath and its release) and one `Tests/craftlistwindow_spec.lua` example (on, both views, off on
  Browse). `Modules/UI/StatusBar.lua`, `Modules/UI/CraftList.lua`.
- **SETUP-SPLIT-002: the box's scrollbar came in at 3 rows** (the operator: "i don't mind the
  scrollbar, but we need to expand more than 3 items before we introduce it. how does TOGPM do
  it?"). TOGPM shows every row until its 40% cap and pads the section past the rows. My box was
  sized to exactly its rows, and RowList counts rows with `floor`, so one pixel lost to the client's
  pixel snapping dropped the last row and showed the scrollbar. The box now carries
  `UICL.SETUP_BOX_SLACK` (2). Offline: a `Tests/craftlistwindow_spec.lua` example shaves a pixel off
  the box and requires three rows and no scrollbar (red before). Not yet seen in a client.
  `Modules/UI/CraftList.lua`.
- **GSL-SENDTO-001: the Shopping List tab says who to send items to** (the operator: "on the
  shopping list tab, we need to show who is the GSL character, so people know who to send items
  to"). A "Send items to:" line on the tab's strip names every home-guild member with `[GSL]` in
  their public note (`CraftList:GSLPlayers`, the same test as `IsGSLPlayer`), online ones first in
  green, offline ones grey and marked, and tells a guild with none how to name one. Painted by
  `UI_CraftList:Draw`, which a roster change reaches, so online state stays current. Offline: one
  `Tests/craftlistwindow_spec.lua` example. `Modules/CraftList.lua`, `Modules/UI/CraftList.lua`.
- **ITEM-SEARCH-001: every item is searchable on List Setup, whatever the profession** (the
  operator: "we need to ensure the eko's that make juju's are on the list, why don't we just have
  the itemdb searchable on the GSL add list?"). The search skipped LibItemDB whenever the Profession
  dropdown named a profession, so an item no profession makes (the E'kos are Quest items) could not
  be found from a profession view. A profession now narrows the recipes only. Offline: a
  `Tests/craftlistwindow_spec.lua` example loads LibItemDB's shipped Quest data and finds all seven
  E'kos (12430-12436) with Alchemy picked. KNOWN LIMIT: LibItemDB's search is a plain substring, so
  "eko" without the apostrophe still finds nothing; a punctuation-insensitive match is requested
  from ItemDB (contract `e860cddb848a`). `Modules/UI/CraftList.lua`.
- **SETUP-REAGENTS-001: made items show their reagents, TOGPM's expander** (the operator: "i would
  like to do a TOGPM like thing, where each 'made' item shows the mats to make it. so we can say we
  need 5 flask OR x reagent y reagent etc. then it can generate a complete reagent list based on the
  end items required"). In the List Setup box a made item carries TOGPM's `+`; a click opens its
  reagents under it (indented, at per-craft count times the count wanted, no controls) and `-`
  closes them. The box is no longer sortable, as TOGPM's is not, so a reagent stays under its item.
  The complete roll-up across every end item is the Shopping List tab's Reagents view
  (`CraftList:Demand`), unchanged; a raw reagent can still be put on the list directly as an item.
  Offline: one `Tests/craftlistwindow_spec.lua` example. `Modules/UI/CraftList.lua`.
- **SHOPLIST-SPLIT-001: the Shopping List tab laid out like List Setup** (the operator: "the + and
  the shopping list totals need to be on the shopping list tab as well. the guild needs to see how
  many dreamfoil etc they need to send ... the shopping list tab needs to be like the list setup
  tab, the items on the top, but instead of a search bit on the bottom, the bottom rows should be
  all the reagents we need to make the items in the list"). The wanted items are a bordered box on
  top (unsorted, so an item's reagents stay under it) and the full reagent roll-up
  (`CraftList:Demand`, Needed / Bank / You / Missing) is always shown under it; the Show dropdown
  that switched between the two is removed. A crafted item's `+` opens its reagents at the count
  still to make (wanted less what the bank holds of it), so an opened item agrees with the roll-up.
  Because a row click orders the item (step 7), the `+` is a button of its own in the first column
  (`buildArrowCell`), not a row click as on List Setup. Both boxes are now one builder, one height
  rule (`UICL:BoxHeight`) and one expander (`UICL.WithReagents`), so the two cannot drift. The
  status line reads "N wanted, N reagents, N still missing". Offline: two new
  `Tests/craftlistwindow_spec.lua` examples; the four that drove the old dropdown now open the tab
  as it is. `Modules/UI/CraftList.lua`.
- **GSL-BANK-001: the [GSL] character is the shopping list's banker** (the operator: "we also need
  what is on the GSL player (bank/bags/mail) just like a banker. they are the 'special' banker for
  the shopping list" / "the missing tab should be what the GSL banker is missing"). One rule now
  decides what a guild note makes a character a bank, `noteBankRole` in `Modules/Guild.lua`, and
  the six sites that decide who is a bank ask it instead of testing for `gbank` on their own:
  `GetBanks`' fallback, `_SisterBankers`, `RebuildBankerRoster`, `IsViewOnlyBank`'s fallback, and
  both roster builds (library and legacy) plus the sister roster. `SenderHasGbankNote` deliberately
  stays `gbank`-only, because it grants settings and donation authority, not bank status. An earlier
  draft of this entry said "every site", which missed it; and because the sister roster stores a
  `[GSL]`-only character as `isBank`, its sister-guild branch gave such a character that authority
  until it was changed to re-read the note for `gbank` (new `Tests/xguild_spec.lua` example).
  `[GSL]` in the PUBLIC note makes a banker flagged `gsl` (the field on
  `memberRoster`, read by the new `Guild:IsGSLBank`), so the GSL character's own client scans and
  publishes its bags, bank and mail through the banker pipeline. It is view-only unless the note
  also says `gbank`: the guild sends to it, and does not order the shopping list's stock back out.
  It therefore shows on the Browse and Bankers tabs as a view-only bank, and `BankerStores` strips
  `[GSL]` from its note. On the Shopping List tab the reagent roll-up gains a GSL column
  (`CraftList:GSLHolds`), Bank no longer counts the GSL character (`CraftList:BankHolds`, both
  through `HomeBankersHold`), and Missing is the need less what the GSL character holds; Bank and
  You are shown beside it, not netted out. The Reagent Tracker shows the same columns. Found while
  wiring it: my new rule made `IsViewOnlyBank`'s fallback depend on being a banker, which broke the
  existing "GBANK VIEWONLY" case (the banker test is case-sensitive); the fallback keeps the marker's
  own answer. Offline: two `Tests/craftlistwindow_spec.lua` examples (the note rule, and the GSL
  column); the roll-up and tracker examples in `craftlistwindow_spec` and `craftlist_spec` now
  expect the new Missing. `Modules/Guild.lua`, `Modules/CraftList.lua`, `Modules/UI/CraftList.lua`,
  `Modules/UI/CraftTracker.lua`.
- **GSL-YOU-001: You and GSL disagreed on the GSL character** (the operator 2026-09-26, with a
  screenshot of 120 against 160 Dreamfoil: "when i'm on the GSL toon, the GSL and You columns should
  match"). `CraftList:YouHold` was `C_Item.GetItemCount(itemID)`, bags only. A bank character (the
  `[GSL]` one included) now reads its own scanned total (`Guild:GetAltItemTotal`: bags, bank and
  mail), the number the GSL and Bank columns read for it; anyone else gets bags plus bank
  (`includeBank`, Classic Era `ItemDocumentation.lua:242`). The mail half is only as fresh as the
  character's last mailbox visit, since the inbox can be read only while it is open
  (`Modules/Bank.lua:303`). Offline: a `Tests/craftlistwindow_spec.lua` example with bag and mail
  stock on the GSL character. `Modules/CraftList.lua`.
- **TRACE-REALM-001: `/togbank dev trace <name>` traced the wrong realm** (the operator's own trace,
  2026-09-26). A bare name normalised to the PLAYER's realm, so "trace Togcloth" typed on Old
  Blanchy traced Togcloth-OldBlanchy, which does not exist, and printed the real Togcloth-Azuresong
  as "banker on the roster: NO". A bare name now resolves to the one bank character (then the one
  roster member) with that name on any connected realm; an ambiguous name keeps the old reading.
  Offline: a `Tests/trace_spec.lua` example. `Modules/Chat.lua`.
- **ESC-SPLIT-001: one window list was doing two jobs** (Peer Review, inbox a0556886).
  `UI.ALPHA_WINDOWS` was both the transparency-slider list and the Escape registry, so the Reagent
  Tracker could not get a slider without also being closed by Escape. Escape now reads its own
  `UI.ESCAPE_WINDOWS` (the seven existing windows); the tracker is in `ALPHA_WINDOWS` only, so it
  has its own Appearance slider and is also moved by Recenter Windows. Offline: a
  `Tests/windowalpha_spec.lua` example pins the two lists against each other, and a
  `Tests/craftlistwindow_spec.lua` example drives the tracker's slider and checks the Escape
  stand-in stays hidden with only the tracker open; both went red with the tracker added back to
  the Escape list. `Modules/UI.lua`, `Modules/UI/CraftTracker.lua`.

### Bug Fixes

- **XGUILD-SETTINGS-002: a sister guild's officer still had settings authority behind one branch**
  (Peer Review F4 on self-audit 13180dbf, traced by them). `SenderHasGbankNote`, `SenderIsGM` and
  `SenderIsOfficer` each read the SENDER'S guild roster, so they answer true for a sister guild's
  bank characters, officers and GM -- right where they authorize that guild's bank data, wrong for
  settings. The XGUILD-SETTINGS-001 branch at the top of `ApplyRemoteSettings` was the only thing
  between another guild and every officer setting. `SettingsSenderAuthorized` now refuses a sender
  placed in another guild (the same test that branch uses), and `ApplyRemoteSettings` asks it rather
  than repeating the three helpers, so the refusal holds even without that branch. The helpers are
  unchanged. Offline: the `Tests/xguildfleet_spec.lua` list example asserts the home bank character
  has a gbank note but no settings standing from the sister client (red without the new line), and
  with the sister branch disabled the home list still stays out. `Modules/Guild.lua`.
- **SETTINGS-TIE-001: two clients holding different settings at the same stamp never agreed**
  (Peer Review F1 on the step-2 self-audit). An equal stamp was taken from whichever payload arrived
  last, so two officers' writes in the same second flipped each client back and forth; the `[GSL]`
  path also spelled the same rule differently. Both paths now go through one `adoptSettingsField`:
  a newer stamp wins, an unset field is seeded, and an equal stamp goes to the greater canonical
  value, so every client picks the same winner. Found while wiring it: `ApplyRemoteSettings` moved
  the held version BEFORE judging the fields, so a field with no stamp of its own read as exactly
  the payload's stamp; it now moves after. KNOWN COST in the code: a plain member that sees a tie
  while the writer holding the greater value is offline asks the other writer once a minute until
  the two meet. The shopping list's entry merge (`CraftList:Merge`) and the bank-character owner
  merge (`Guild:MergeBankerOwners`, Peer Review on the follow-up audit) had the same defect per entry:
  on an equal stamp the list now takes the greater count and the owners the greater name. KNOWN COST
  in both: a removal or a clear counts as nothing and so always loses a tie, and comes back.
  `Modules/Guild.lua`, `Modules/CraftList.lua`; `Tests/craftlist_spec.lua` (five examples; the
  settings and owner ones go red on the old rule).
- **POOL-CHROME-001: a released TOG Bank window left its "?", gear, share button and status-bar
  text on AceGUI's pooled frame** (Peer Review F5, which asked for a trace; the trace found the
  defect, wider than asked). `UI:DressWindow` cached the icons on the frame and never hid them, so
  the next window built on that frame, another addon's included, showed our help icon and a working
  gear. The share button's OnShow hook still showed it on a bank character. `StatusBar:Attach` built
  a NEW centre frame and right-hand text on every attach, left the old ones shown with their last
  text, and stacked one more OnShow hook per life that redrew a dead bar. Now: one release
  dispatcher (`UI:OnWindowRelease`, because AceGUI holds a single OnRelease per widget) runs the
  chrome's and the status bar's clean-up. The bar's sections are cached on the pooled bar and
  reused, and its show/hide hooks are set once per frame and read the frame's current bar. Seen
  offline only, not in a client. `Modules/UI.lua`, `Modules/UI/StatusBar.lua`;
  `Tests/windowchrome_spec.lua` (red without the release step).

### Internal

- **Changelog archive:** the whole v1.6.0 section moved to `CHANGELOG_ARCHIVE.md`. Forward part A8a
  (A5a plus `craftlist_spec` and `craftlistwindow_spec`) replaces A5a in the gate.
- **The real LibItemDB in `craftlist_spec`** (Peer Review F2): one describe loads the installed
  ItemDB with its shipped Vanilla Miscellaneous, Consumable and enUS name data and asserts both
  entries resolve through it; the existing naming example pins the no-library client fallback.
- **CurseForge page checked with the harness's `cfhtml.lua`** (declared as the writ suite
  `cfhtml`): well-formed, 64,542 characters. It flagged two CurseForge links (TOG Profession
  Master, TOG Tools) against the Discord-only rule for player pages; both names are now plain
  bold text. `docs/Curseforge_Description.html`.
- **The whole-client test env was missing `Modules/CraftList.lua`.** `Tests/env_togbank.lua`'s
  `MODULE_ORDER` is a second copy of the TOC's load order, and every fleet client built from it
  silently dropped a heard shopping list, so a fleet example about the list would have passed for the
  wrong reason. Added where the TOC loads it, with `Modules/Usable.lua`, which it also lacked.
  MODULE-ORDER-001 (Peer Review F6): a `Tests/wiring_spec.lua` example now reads the Era TOC and
  requires `MODULE_ORDER` to equal its non-UI module lines in order (red with `Usable.lua` removed).
- **Release docs for v1.7.0:** `README.txt` brought level with the CurseForge page and the code --
  version 1.7.0, the shopping list in Key Features and the tab lists, a `[GSL]` setup section, the
  You column counting bags and bank, List Setup (not the Shopping List tab) setting the gather
  dates, the Reagent Tracker's transparency slider, a v1.7.0 compatibility note, Changelog
  Highlights and ProfessionDB under Libraries. The CurseForge page gains ProfessionDB under
  Required (it was a TOC dependency and missing there), List Setup in both tab lists, the `[GSL]`
  setup step, the You column wording, and two New notes: older versions keep syncing but do not see
  the list or the `[GSL]` stock, and ProfessionDB is required.
- **GSL-MERGE-001 step 6, TOGBank's half:** a "Guild Shopping List" section in the CurseForge
  page's Core Features (telling a GuildShoppingList guild to keep that addon enabled until a list
  writer has logged in once, since the import can only read its saved variables while it loads),
  the Shopping List tab in the page's tab lists, and a Shopping List section in `README.txt`.
  GuildShoppingList's final release is requested from its own workspace (contract `27dae11a3e42`).
  `docs/Curseforge_Description.html`, `README.txt`, `docs/GSL_MERGE.md`.
- **Harness pin `23d11b1` -> `ee56a45`** (WoWAPITesting delivered `C_TradeSkillUI`, thread
  b856f5a5). The spec-local `C_TradeSkillUI` stand-in in `Tests/craftlistwindow_spec.lua` is
  deleted; the spec now runs on the harness's.
- Gate: forward 470 + 504 + 961 = 1,935, reverse 537 + 711 + 687 = 1,935, none failed.

## [v1.6.1] (2026-09-25) - Sister-Guild Failover

### New Features

- **ESC-001: Escape closes the Guild Bank window, and a setting turns Escape off.** A player: *"Bank
  doesnt close with esc press, but togpm does"*; the operator: *"it should have esc close the window
  by default."* The escape frame was only CREATED by the first open of Inventory, Search, Requests
  or Donations, so the Guild Bank window opened on its own never had Escape; closing Inventory also
  hid it and took the Guild Bank window down. Now one stand-in (`TOGBankClassicEscProxy`) on
  UISpecialFrames, shown while any window is open, closes them all. Appearance setting "Close
  windows with Escape" (`db.global.closeOnEscape`, default on). `_G.TOGBankClassic` is gone.
  Offline: `Tests/escape_spec.lua` (new, 10). Locations: `Modules/UI.lua`, `Modules/Options.lua`,
  every `Modules/UI/*.lua` window.
- **XGUILD-SEARCH-001: the Bankers search matches a sister guild's name.** The operator, 2026-09-25:
  *"the guild tag name needs to be searchable, so i can search for bankers in the sister guild."*
  `Browse:FilterBankerRows` passes the row's `guildName` to `SearchMatch`. Offline:
  `Tests/browse_spec.lua` (+1). Locations: `Modules/UI/Browse.lua`.
- **SSYNC-001: `/togbank ssync [<name>]` starts a sister-guild sync now.** The operator, 2026-09-25:
  *"do we have a /togbank command to start a cross guild sync? i need that, especially for testing,
  and if i could do /togbank ssync <name> that would be helpful. it could do a roster lookup so i can
  be lazy with the realm."* With no name, each listed sister guild's usual peer is asked at once, past
  the cycle's pending and silent-for-an-hour waits. With a name, that sister member is found in the
  sister rosters (realm optional, any case; `Guild:FindSisterMembers`) and asked directly -- the
  hash-list ask and the requests index behind it, the cycle's own `AskFederationPeer` -- with any
  "left alone" mark on it cleared. It refuses, sending nothing and saying why, when the Sister-guild
  bank is off, no sister guild is listed, the name is not a sister member, it matches characters on
  more than one realm, or the member is offline. Offline: `Tests/xguild_spec.lua` (one example).
  Locations: `Modules/Guild.lua` (`SisterSyncCommand`), `Modules/Chat.lua`, `README.txt`.
- **XGUILD-NUDGE-001: a GreenWall guild hears you open the bank, and its members pull at once**
  (`docs/XGUILD_SYNC.md` 4.6, build-order step 7 -- the optional last step, gated on steps 2-6 being
  seen in game, which the operator closed on 2026-09-16). GreenWall's bridge cannot carry the sync
  (a CHANNEL send is hardware-gated on Classic, a segment is 255 bytes, the handler is not told the
  guild -- 1.1 of the design note), but ONE line from a click can ride it: `Browse:Toggle` -- the
  minimap button, `/togbank`, the legacy window's Browse button -- sends `hlq:<addon version>`
  through `GreenWallAPI.SendMessage` when the sister-guild bank is on, GreenWall is loaded and its
  guild channel is JOINED (a segment GreenWall cannot send is parked for its next flush, which may run
  from its timer, so an un-joined channel refuses rather than risks a blocked send), at most once per
  sync cycle. A federated client hearing it (`GreenWallAPI.AddMessageHandler`, registered from Core's
  init) notes the version and treats the line as a TOGBank message from the sender
  (`Guild:UpdateOnlineMember(..., "greenwall-nudge")`), so `OnFederationPeerProven` asks that guild for
  its hash list NOW instead of on the next ten-minute cycle -- after Guild Roster places the sender in
  a LISTED sister roster; echo, a home guildmate and a name only GreenWall's confederation knows are
  ignored. Nothing runs without GreenWall (`## OptionalDeps: GreenWall` in every TOC, so it loads
  first when present). Offline: `Tests/xguild_spec.lua` step 7 (three examples; the API's signatures
  pinned against the installed `GreenWall/API.lua`). Not seen in a client. Locations:
  `Modules/GreenWall.lua` (new), `Modules/UI/Browse.lua`, `Modules/Guild.lua`, `Core.lua`,
  the TOCs, `Tests/env_togbank.lua`, `.luarc.json`, `.luacheckrc`.

### Bug Fixes

- **POOL-CLUSTER-001: a released Requests window handed on its broom and envelope.**
  `ReleaseWindow` (role change, or the body moving into the Guild Bank tab) returned the frame to
  AceGUI's shared pool with the cluster and officer overlay still shown; they now hide first. Not
  seen in game. `Tests/requestsactions_spec.lua` +1. Locations: `Modules/UI/Requests.lua`.
- **REQ-GATE-001: a stranger could pull the guild's request history** (Peer Review on audit
  `31294783`, F5). `requests-index` / `requests-by-id` now answer only `IsInCurrentGuildRoster`
  senders (a guildmate, or a sister member while the switch is on). Also F4: `SendBankerOwnersTo`
  skips the receiver's own guild's entries. `Tests/xguild_spec.lua` +1. Locations: `Modules/Chat.lua`,
  `Modules/Guild.lua`.
- **XGUILD-SETTINGS-001: officer settings crossed between sister guilds, and who runs each bank
  character mostly did not.** The operator, 2026-09-25: *"the banker metadata isn't syncing though"*,
  then *"we should NOT be syncing the officer settings between sister guilds, this would allow any
  guild to target another guild and force it into being a sister."* A sister guild's bank character
  passed `SenderHasGbankNote` (the sister roster's note), its officers `SenderIsOfficer`
  (`member.isOfficer`) and its GM `SenderIsGM` (rank 0), so `ApplyRemoteSettings` adopted that guild's
  request limit, shop, discount, Sister-guild bank switch and rank floor as OURS whenever its stamp was
  newer. And `AnswerFederatedAsker` sent settings only when the answering client was a bank
  character or officer, while a pull usually asks a plain member -- so the owners rarely crossed.
  Now a sister member's payload yields only its own guild's bank characters' owners (merged entry by
  entry, the field stamp moved with it), from ANY member; the answer to a sister guild's ask is the
  owners alone (`Guild:SendBankerOwnersTo`), from any client. Supersedes `docs/XGUILD_SYNC.md`
  D1/D4/D6 on settings. Offline: `Tests/xguild_spec.lua` (+2, one existing example rewritten),
  `Tests/xguildlive_spec.lua` step 6 (the request limit no longer crosses). Locations:
  `Modules/Guild.lua`, `docs/XGUILD_SYNC.md`.
- **SCALE-DOCK-001: a Window and Text Size change pulled Search and Requests off the Inventory
  window.** Peer Review's residual on 593238c3: the scale listener re-applies AceGUI's status table,
  whose `ClearAllPoints` dropped the hand-made dock. `UI:SetPersistedAnchor` lets a window re-dock
  right after. Offline: `Tests/browsepersist_spec.lua`. Locations: `Modules/UI.lua`,
  `Modules/UI/Search.lua`, `Modules/UI/Requests.lua`.
- **SCALE-FLOOR-002: a released window could still be resized by a Window and Text Size change.**
  LibAceGUIWidgets now registers its own scale listeners -- the resize handle's and `PersistWindow`'s
  record (`widget._lagwPersist`) -- and both went into AceGUI's addon-wide pool with the frame.
  `UI:ForgetPersistedWindow` now removes the record's listener (through the library's public
  `OnScaleChanged(owner, nil)`; the library has no forget call, asked for on its inbox `3d96003a`)
  and puts a ClearFrame's handle back on the bounds it had before `UI:PersistWindow` raised them
  (recorded there as `handle._togOrigBounds`). The handle is NOT destroyed: it is made once in the
  ClearFrame constructor, and my first version of this fix destroyed it, which would have left the
  frame's next owner with no resize grips -- caught by this session's own audit before release.
  Also `browsepersist_spec`'s SCALE-DOCK example used a width under the doubled floor, which the
  library now correctly raises. Offline: `Tests/browsepersist_spec.lua` (+1 ClearFrame example).
  Locations: `Modules/UI.lua`, `Tests/browsepersist_spec.lua`.
- **SETTINGS-STALE-001: an officer whose client still held an old or default setting could push it to
  the whole guild by changing a DIFFERENT setting.** Found live 2026-09-25: the Sister-guild bank was
  unticked guild-wide, so the sister guild's inventory handshakes were answered "busy" by every client
  (a non-member fails `isValidPeer`, `Modules/P2P.lua:136`) while its request queries -- which have no
  membership gate -- kept crossing. The operator: *"we need to make sure someone logging on for the
  first time doesn't uncheck it, as that's the default. how do we guard this?"* SETTINGS-004's
  per-field stamps diff a write's payload against a snapshot of the last settings sent or applied, and
  that snapshot was EMPTY at two moments -- a session's first write before any settings were heard or
  sent, and every write after settings were RECEIVED (`ApplyRemoteSettings` cleared it) -- and an empty
  snapshot stamped EVERY field as freshly written. Now the snapshot is the held settings from the
  moment the record is bound (`Guild:Init`) and whenever settings are applied (`Guild:SnapshotSettings`),
  tied to that settings table; a write that still finds none diffs against the DEFAULTS
  (`Guild:DefaultSettingsFields`), so a default value is never stamped by a write that did not change
  it. KNOWN COST: v1.6.0 clients still have the old behaviour until they update, so an officer on
  v1.6.0 can still do this. Offline: `Tests/settings_spec.lua`, two examples, both red with the fix
  reverted. Locations: `Modules/Guild.lua`.
- **XGUILD-BOUNCE-001: a sister-guild bank character who logged off stayed "online" to the other
  guild, which kept asking them for the bank.** The operator, straight after v1.6.0: *"build complete
  end to end tests for the sister guild sync, still having issues with that"*. Guild Roster never
  hears "X has gone offline." for another guild's member: its presence for one is a sighting stamp
  that only ages out (`PRESENCE_TTL`, 900 s) -- and its guild relay carries every name still inside
  that window and the receiver re-stamps them at receive time (`LibGuildRoster-1.0.lua:3976`,
  `:4194`, `:3297`, on a 270 s relay interval), so a member who logged off reads online for as long
  as two guildmates keep relaying (filed to Guild Roster's inbox 2026-09-17). The one authoritative
  "not online" a client gets for them is the server bouncing a whisper
  (`ERR_CHAT_PLAYER_NOT_FOUND_S`), which `Events:CHAT_MSG_SYSTEM` already turned into
  `UpdateOnlineMember(X, false)` -- a flag on `memberRoster` that `IsPlayerOnline`, `FederationPeer`
  and `_AddSisterMembers` never read for a sister member. So the sister viewer whispered its
  hash-list ask to the logged-off banker, waited the whole cycle, marked them silent for an hour and
  only then asked the other member, while the Bankers tab said "yes". Now the bounce is remembered
  (`Guild.sisterBounced`, frame clock) and outranks the library's sighting for the library's own
  window (`Guild:SisterSightingHolds`, read by all three sites; the library's stamps are NOT compared
  against it, because a relay re-stamps within the minute -- measured); a TOGBank message from the
  member clears it at once; and when the bounced whisper was our ask, the ask is withdrawn, the member
  is left alone for `FEDERATION_SILENT_FOR`, and the guild is asked through `FederationPeer`'s next
  choice NOW (`Guild:OnSisterMemberBounced`). Design: `docs/XGUILD_SYNC.md` D9. Offline:
  `Tests/xguild_spec.lua` (bounce, re-ask, clear, window) and `Tests/xguildlive_spec.lua` step 8 on
  the real transport stack. Locations: `Modules/Guild.lua`.
- **LINKCLICK-001: a modified click on an item link does what it does everywhere else in the game.**
  The operator: *"what shift+click and ctrl+click does to the links in the addon? i'd like it to
  mirror game functionality"*. Read in both client trees this addon ships (`classic_era`,
  `classic_anniversary`): a modified click on any item link runs `HandleModifiedItemClick`
  (`Blizzard_ItemButton/Classic/ItemButtonTemplate.lua:137`) -- `IsModifiedClick("CHATLINK")` (Shift
  by default, but the PLAYER'S binding) inserts the link through `ChatFrameUtil.InsertLink` (the open
  chat box, else the auction house's search box, else a macro being edited), `IsModifiedClick("DRESSUP")`
  (Ctrl by default) previews it with `DressUpItemLink`. The bare `ChatEdit_InsertLink` exists on both
  clients ONLY as an alias of the real function in `Blizzard_DeprecatedChatInfo/Deprecated_ChatFrame.lua:43`,
  behind `loadDeprecationFallbacks`, and nothing in either tree calls it. Four defects against that:
  (1) the item slots (`UI:EventHandler`, Inventory and Search windows) read `IsShiftKeyDown` /
  `IsControlKeyDown`, so a player who rebound "chat link" or "dress up" got nothing; (2) the Browse
  and Shop rows handled Shift only, and a Ctrl-click REQUESTED the item; (3) every insert called the
  deprecated alias, nil with that CVar off; (4) `Events:RegisterEvents` hooked the alias for the
  "shift-click fills the Search box" feature (`UI:OnInsertLink`), so the hook never saw a shift-click
  on a bag item or a chat line -- only this addon's own slots -- and raised outright with the CVar off.
  Now `UI:HandleLinkClick(link)` runs the client's dispatcher (the same logic spelled out for a client
  without it), consumes the click whenever a link modifier is held so no plain-click action runs under
  one, and is what every site calls; `UI:InsertLink` prefers `ChatFrameUtil.InsertLink`; the hook is on
  the function the client calls, the alias only as a fallback, and neither present raises nothing.
  The mail window's shift-click (take everything, MAILCLICK-002) is unchanged: the game's own inbox
  has no modified-click handling (`MailFrame.lua:828`), so there is nothing to mirror. Offline:
  `Tests/linkclick_spec.lua` (new) and `Tests/browse_spec.lua`. Locations: `Modules/UI.lua`,
  `Modules/UI/Inventory.lua`, `Modules/UI/Search.lua`, `Modules/UI/Browse.lua`, `Modules/Events.lua`,
  `.luarc.json`, `.luacheckrc`.
- **SCALE-FLOOR-001: with Window and Text Size under 100%, a window at its minimum had its filter
  strip past the border.** A player's report against v1.6.0 (2026-09-17, the slider at 80%): *"Window
  size at minimum has widget overflow after resizing/reloading text in config"*. Two defects, both
  mine from VISIBILITY-001. (1) LibAceGUIWidgets' `PersistWindow` multiplies a window's floor by the
  accessibility scale -- right for a window made of its own widgets, whose every region scales -- but
  TOGBank's floors are sums of FIXED widths too: the Browse strip's stock AceGUI dropdowns, edit boxes,
  checkbox and button (their template art is fixed; `ScaleStockWidget` grows only the text), the
  frame's insets, RowList's gutter. At 80% the Guild Bank window's floor fell from 784 to 627 px while
  the strip's first row still needed 738, so a window dragged to its minimum, or reloaded at a saved
  size the floor no longer raised, spilled. Now the pixel floor is never below the normal-size one
  (`minW x max(1, scale)`, handed to the library as `minW x max(1, scale) / scale` so its own multiply
  lands there). KNOWN COST: under 100% a window cannot be dragged smaller than it can at 100%; the
  text shrinks, the minimum does not. (2) The library re-applies a floor on a scale change only
  through a resize handle, which an AceGUI Frame (every TOGBank window) has none of, so the bounds set
  at draw time stayed at the old scale until the next reload -- a window at the 100% minimum kept it
  at 200% with twice the text inside (finding filed to LibAceGUIWidgets' inbox 2026-09-17; TOGBank's
  own listener is the stand-in). `UI:PersistWindow` now re-runs itself on the scale signal for every
  window -- Inventory, Search, Requests, Browse, Mailbox -- raising a window sitting under the new
  floor and re-applying the bounds; nothing shrinks on a scale-down. Offline:
  `Tests/browsepersist_spec.lua` (three examples against the real library and the real Requests
  floor; two fail without the fix at 627 vs 784); forward A4 882/0, forward B2 936/0, reverse-order
  1818/0 after it. Locations: `Modules/UI.lua`, `README.txt`.

### Internal

- **SUITE-HEAP-002, harness pin 23d11b1.** `browse_spec`, `requestsactions_spec` and
  `mailwindow_spec` release their windows; `env.releaseWindow` drops Requests' frame caches. The
  `GetClassColor` stand-in and `browse_spec`'s fake LibDBIcon are gone. Heap not measured.
- **UI-OWN-TABLE-001: `TOGBankClassic_UI` is its own table**, reading through to AceGUI-3.0; it
  was the shared library table itself (Peer Review 35130c29). Escape also closes the owner dialog.
- **OWNERS-STAMP-001, harness pin 35f697b.** One `Guild:AdvanceOwnersStamp` for both owners-merge
  routes (Peer Review 31294783). Harness 17d5211 -> 35f697b: `GetClassColor` stand-in, two specs on
  the rich layer, `canonhash_spec` loads `Inventory/Sync.lua`, windows released in two specs.
- **USABLE-LIBITEMDB-001: "Usable by me" asks LibItemDB's `ClassProficient`** (ItemDB v0.10.0,
  MINOR 27; ItemDB inbox 10a85af75c12). The five proficiency tables copied from Dibs and
  `Usable.ArmorCap` are deleted. One answer changed on purpose: a class off the tables may hold a
  shield. Offline: `Tests/usable_spec.lua`, `Tests/browse_spec.lua` (the installed library).
  Locations: `Modules/Usable.lua`.
- **TOC-MISTS-001: a MoP Classic TOC, and the TBC TOC renamed `_BCC` -> `_TBC`** (the operator,
  2026-09-25: *"make a mop toc"*, *"update the _BCC toc to be _TBC"*). New `TOGBankClassic_Mists.toc`
  at Interface 50504: the Era TOC byte for byte apart from the Interface line. Every required
  dependency already ships MoP (Ace3, VersionCheck-1.0, AceCommQueue-1.0, DeltaSync, LibAceGUIWidgets
  and LibDBIcon-1.0 list 50504; GuildRoster and ItemDB ship their own `_Mists.toc`, ItemDB with
  `Data\Mists\` item data). **Loads in a MoP client with no Lua errors** (the operator, 2026-09-25,
  on a character in no guild); **NOT VERIFIED: every guild feature** -- nothing past loading has run
  in MoP, and the code has not been read against the MoP API. `TOGBankClassic_BCC.toc` is
  now `TOGBankClassic_TBC.toc` (same content), matching the fleet's `GuildRoster_TBC.toc` /
  `ItemDB_TBC.toc`. New lockstep guard `Tests/wiring_spec.lua` (TOC-LOCKSTEP-001): every TOC must
  equal the Era TOC apart from its Interface line; the ten specs that looped over two TOCs now loop
  over three. `wow-version-replication.ps1` now also mirrors into `_classic_` (MoP). Locations:
  `TOGBankClassic_Mists.toc` (new), `TOGBankClassic_TBC.toc` (renamed), `.pkgmeta`,
  `wow-version-replication.ps1`, `CLAUDE.md`, `Tests/*_spec.lua`.
- **LIBDBICON-DEP-001: LibDBIcon-1.0 is a required dependency, no longer vendored** (TOGTools inbox
  contract `1eab38f9`, the operator's decision of 2026-09-25). An embedded copy only updates when
  TOGBank releases; as a CurseForge required dependency it updates for every player on its own.
  `Libs/LibDBIcon-1.0/` is deleted, every TOC declares `LibDBIcon-1.0` in `## Dependencies` and no
  longer load the copy, and `.pkgmeta` lists the slug `libdbicon-1-0`. **LibDataBroker-1.1 stays
  bundled** on the operator's word (*"change it to not get rid of libdatabroker"*), although the
  standalone LibDBIcon also loads one (`LibDBIcon-1.0/embeds.xml:6`); LibStub keeps whichever copy
  has the higher MINOR. No Lua changed -- `Modules/UI/Minimap.lua` still resolves both through
  LibStub. KNOWN COST: a player installing by hand must also install LibDBIcon-1.0. Seen in an Era
  client 2026-09-25: the standalone (TOC `## LoadOnDemand: 1`) loads and the minimap button shows;
  TBC and MoP not checked. Pinned by `Tests/sendresult_spec.lua` ("de-vendored LibDBIcon-1.0").
  Locations: the TOCs, `.pkgmeta`, `README.txt`, `CLAUDE.md`.
- **Peer review of this session's own audit, acted on** (inbox `593238c3`, reply `8e933d44`). Three of
  its four points changed code. (1) `c.offline` is deleted from `Tests/env_fleet.lua`: one concept with
  two spellings, where the write-only one was the plausible-looking one, so a future guard written
  against it would have been true for a client taken offline through `F.offline` and false for one
  created with `opts.offline`. The reviewer also spotted that `Tests/fullsync_spec.lua:864` was a
  hand-inlined `F.offline` -- the one call site that could not benefit from the change that gave
  `F.offline` its presence call -- so it now calls the helper and one of the three deletions came
  free. (2) `GreenWall:Bridge` no longer claims `GetChannelNumbers()[1]` is the guild channel, and the
  six-line caveat defending that claim is gone; it now accepts any joined channel. **The reviewer's
  suggested `#numbers == 0` was NOT taken, with a reason:** `GwChannel:is_connected` calls a channel
  connected only when its number is non-zero, so a channel that exists un-joined reports 0 and a send
  on it is PARKED for the next flush -- the later non-hardware send this gate exists to prevent. The
  non-zero test is load-bearing; only the claim about which entry it is was wrong. (3) `Nudge` now
  stamps the cooldown on a refusal FROM GreenWall, so the one configuration that always fails there
  costs one attempt per cycle instead of one per window open; a refusal before the send still leaves
  the cooldown alone, so a client whose GreenWall loads a moment later does not wait a cycle. New
  example in `Tests/xguild_spec.lua`. The fourth point was routed rather than fixed: the desk's
  `file move-span` reports success after moving an incomplete span, which is writ's defect and is
  filed to its inbox. Locations: `Modules/GreenWall.lua`, `Tests/env_fleet.lua`,
  `Tests/fullsync_spec.lua`, `Tests/xguild_spec.lua`.
- **GSL-MERGE-001, first step: GuildShoppingList read end to end, and the merge design written**
  (`docs/GSL_MERGE.md`, new). The operator, 2026-09-16: *"add to the todo list to merge the GSL addon
  into TOGBank, put it at the bottom"*, with the item's own first step being the read and the design
  before any code. **Nothing is built and no code was touched.** What the read settled: GuildShopping-
  List is a second, weaker implementation of machinery this addon already has -- its own guild-note
  role marker (`[GSL]`), its own whole-state newest-timestamp-wins broadcast, its own name-keyed
  cache of ONE player's bags and bank, its own 290-line calendar picker, its own two frames -- wrapped
  around one genuinely new idea, expanding a recipe into reagent demand. So the merge is a new Craft
  List tab on the rails that already exist (the stamped guild-settings payload for the list, the
  request log for orders, `Guild:GetAltItemTotal` for what the bank holds), not a port of its code.
  `LibProfessionDB-1.0` already carries the recipe data keyed by spell id with **reagents keyed by
  item id**, which deletes GSL's eight vendored `Recipes\*.lua` tables and removes its name-matching
  at the root -- the same defect class as REQ-001. **Build step 1 was then run rather than assumed**
  (section 1.5): GSL's eight tables diffed against the library's Vanilla enUS data, 924 of 1,106
  names matching exactly, and the 182 that do not are GSL's own shorthand (`Crusader (enchant)`
  against the library's `Enchant Weapon - Crusader`, whose `effect` field is literally `Crusader`;
  `Blight (polearm)` against `Blight`), names the Vanilla data does not carry and which look like
  later-expansion recipes (recall, not a lookup -- flagged in the document as its weakest claim), and
  the Miscellaneous bucket, which is seven Winterspring E'ko turn-in items and not recipes at all. So
  the shorthand cause is verified and large, and the migration gained two name fallbacks.
  Both open decisions were answered 2026-09-25: GM, officers and the `[GSL]` note tag edit the list,
  on a Shopping List tab plus an officer setup tab; the build is the release after v1.6.1.
  Locations: `docs/GSL_MERGE.md`.
- **Harness pin `bb80c1b` -> `17d5211`; both XGUILD-LIVE-001 stand-ins are deleted, and the fleet
  now takes a REAL bounce.** (Two deliveries in the same move: `58ff098` below, and `4ca9566`, which
  bumped `LibItemDB-1.0`'s `tocOmits` 98 -> 99 after the drift this repo's newly-declared
  `verify-libs` suite caught at the previous pin. `verify-libs` is now 9/9, 0 failed.) WoWAPITesting delivered the two halves contracted yesterday (`58ff098`).
  (1) A logged-out client sends nothing: all three of the harness's send seams are gated on the
  sender being online, so `Tests/env_fleet.lua` no longer shadows each client's own `C_ChatInfo`
  while it is offline. (2) The server answers the sender of a whisper to a logged-out character with
  `ERR_CHAT_PLAYER_NOT_FOUND_S`, so `F.bounceIfOffline` -- which MANUFACTURED that line -- is gone.
  What replaced it is one frame per fleet client registered for `CHAT_MSG_SYSTEM` that hands the
  event to `Events:CHAT_MSG_SYSTEM`, because a fleet client never runs `Events:RegisterEvents`; the
  bounce is now real and only its delivery is wired here, with every line kept on `client.sysLines`
  so a spec can assert what the SERVER said separately from how the addon reacted. Two things cost
  time and are worth the next session knowing: that frame must be held on the client rather than in
  a local, because the frames registry keeps its candidate lists WEAK and a frame nothing references
  is collected and silently stops hearing its event (it received nothing at all, which reads exactly
  like the harness not firing); and `Tests/xguildlive_spec.lua` step 8 had to stop asserting WHICH
  whisper bounced. The stand-in only ever bounced whispers handed to it by TOGBank's own Core
  wrapper, so the first bounce was always that cycle's hash-list ask; the server bounces every
  whisper to a logged-out character, and the earliest here is the requests-index ask an earlier cycle
  staggered behind itself, so the viewer learns sooner and never spends the cycle's ask on the
  banker who is gone. The step now pins the outcome -- exactly one real bounce naming the banker,
  nothing further asked of it, every failover ask answered, the bank intact -- and the "our own ask
  bounced, re-ask at once" leg keeps its focused example in `Tests/xguild_spec.lua` step 4. Green in
  all three orders: forward A4 882/0, forward B2 939/0, reverse-order 1821/0. Locations:
  `Tests/wowapi` (pointer), `Tests/env_fleet.lua`, `Tests/xguildlive_spec.lua`.
- **Harness pin `6181ba5` -> `bb80c1b`; the LAGW-RESIZE-FILE-001 stand-in is deleted.** The contract
  filed earlier today (thread `a6cfd6a8`) was answered ALREADY SHIPPED: WoWAPITesting had landed
  `2aac908` -- `LibAceGUIWidgets-Resize.lua` in the `LibAceGUIWidgets-1.0` manifest, in TOC order,
  `tocOmits` unchanged -- hours before the message, so the fix was a pin move and nothing else. The
  wrapper `Tests/env_togbank.lua` put round `libs.load` is gone. Three more behaviour changes ride
  the same move and needed nothing here, each checked rather than assumed: `8b36d23` routes the
  addon-message chatType case-insensitively (TOGBank's own report, inbox `22460a4b` -- the recorded
  spelling is unchanged, so FILL-ALERT-001's "GUILD" assertions are untouched); `bcd81e3` keys
  `Settings.GetCategory` on the numeric category id, which is what makes an `AddToBlizOptions`
  SUB-panel resolvable offline at all; `82387fa` adds `C_Spell.GetSpellName` and `C_Seasons`. The
  Adoption log's warning for a library that splits a file -- a per-file load line is needed in any
  spec using `wow.loadAddonFile` as well as the manifest line -- does not reach this addon: the one
  by-path satellite load here (`browse_spec.lua:326`, the DatePicker) runs after `libs.load`. Green
  on the new pin in all three orders: forward A4 882/0, forward B2 939/0, reverse-order 1821/0.
  Locations: `Tests/wowapi` (pointer), `Tests/env_togbank.lua`.
- **XGUILD-LIVE-001: the sister-guild sync, whole lifecycle, on the real transport stack**
  (`Tests/xguildlive_spec.lua`, new). Four whole clients in two guilds over each client's real
  AceCommQueue, AceComm and ChatThrottleLib, in ONE example so each leg starts from the state the
  previous one left: both guilds log in on the clamp; one "Pull from" by name crosses the rosters,
  the `gbank` notes and presence on the library's own whispered pull and click-sent /who; both
  Bankers tabs list the other guild's bank, tagged; the sister viewer's cycle asks by whisper and
  holds the home bank with the author's canon and nothing between the guilds on GUILD; a sister
  member's order and the banker's fill (from `Mail:ApplyPendingSend`) cross by whisper at ALERT and
  are relayed once each way until all four clients agree; an officer's settings write and a who-runs
  entry ride the next ask without wiping the sister guild's own entry; the sister banker, which never
  pulled, reaches the home bank through its guildmate's relay and the home banker holds the sister
  bank; the home banker logs off (step 8, above); a quiet cycle opens no data leg. What its first
  runs found, 2026-09-17: (a) the `invalid key to 'next'` the previous session stopped on was MY
  spec bug -- `next(F.held(hb, SB))` passed `F.held`'s second return, the money total, as the key --
  and steps 5-7 were passing behind it; (b) the harness lets a logged-out client's timers keep
  SENDING (six Guild Roster messages measured in the 660 s after logout, each re-stamping the banker
  online on the sister side) and drops a whisper to an offline character silently where the server
  bounces it -- both stood in by `Tests/env_fleet.lua` (`F.offline` shadows the client's own
  `C_ChatInfo` send seams, `F.bounceIfOffline` hands the bounce to `Events:CHAT_MSG_SYSTEM`) and
  filed as harness contract XGUILD-LIVE-001; `F.presence` no longer clears the library's stamps by
  hand, which had let the failover leg pass without the bounce the addon has to act on; (c) the
  Guild Roster relay finding and (d) XGUILD-BOUNCE-001, above. Two more spec gaps the same runs
  surfaced, both mine from earlier sessions: `bankcollect_spec` never loaded `Inventory/Record` and
  `Inventory/Scan`, which Bank's matchers have read since LINK-AUDIT-001 step 4 -- it passed in the
  declared halves on a Scan an earlier file left behind and failed alone (REQ-003, two examples);
  and LibAceGUIWidgets v0.2.0 moved its resize framework into `LibAceGUIWidgets-Resize.lua`, which
  the harness's hand-copied manifest does not list, so `PersistWindow` called a nil `GetResizeHandle`
  in 103 window examples -- `Tests/env_togbank.lua` loads the satellite when the library comes up
  without it (LAGW-RESIZE-FILE-001, harness contract filed; delete on adoption). The WHOLE forward
  run no longer finishes inside the desk's 15-minute budget, so the full-suite claim is the declared
  halves: forward A4 (altcompat..logwho incl. `linkclick_spec`, declared today) 879/0, forward B2
  (mailbox..xguildlive, declared today) 936/0, reverse-order 1815/0 -- after LINKCLICK-001 as well.
- **MDLINT-BACKLOG-001: every Markdown file in the repo lints clean.** A whole-repo `markdownlint`
  (60 files) reported 100 violations, all pre-existing and all in five design docs nobody had linted
  since they were written: `docs/MAIL_INVENTORY_DESIGN.md` (31), `docs/ORDER_FULFILLMENT_LOGIC.md`
  (18), `docs/MAIL_PERSISTENCE_INVESTIGATION.md` (16), `docs/TESTING.md` (a UTF-8 byte-order mark,
  8 headings, a table's pipe spacing, a double blank line) and `docs/fulfill-button-plan.md` (10
  headings, a table). Every one was a blank line missing after a heading (MD022) or a table row's
  pipe spacing (MD060) bar the BOM and the blank; the text is unchanged. None of these files ships
  (`docs` is in `.pkgmeta`'s ignore); the point is that the whole-tree lint is now a usable gate.

> Releases **v1.6.0 and older** have been moved to
> [`CHANGELOG_ARCHIVE.md`](CHANGELOG_ARCHIVE.md) to keep this file under GitHub's 125,000-character
> release-body limit. Nothing was deleted; each section moved whole, at a version boundary.
