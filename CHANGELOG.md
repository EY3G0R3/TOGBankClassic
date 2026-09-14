# TOGBankClassic Changelog

## [v1.5.1] (2026-09-14) - /togbank Opens The Guild Bank Window

### New Features

- **MAILBOX-TOGGLE-001: a General-tab setting to stop the Mailbox window opening by itself.** The
  operator, the morning after v1.5.0: *"we also need the ability to turn on/off the mail window,
  some folks might not want that"* -- and, on where: *"put a settings in the general settings for
  that"*. **Open the Mailbox window at a mailbox**, account-wide (`db.global.bank.mailboxAutoOpen`),
  ON by default so an upgrade changes nothing; `Options:IsMailboxAutoOpenEnabled()` reads a missing
  value as on, so a profile saved before the setting existed is on too. `Mailbox:AutoOpens()` reads
  it ahead of the banker check, so the setting only ever narrows -- a non-banker is never opened for
  either way (until MAILBOX-TOGGLE-002, next) -- and off, the window is still one click away on the mail frame's TOG Bank button or
  `/togbank mailbox`. `mailbox_spec` drives the REAL Options module and its AceConfig toggle
  (raidvisibility_spec's pattern): the default, the nil-reads-as-on rule, the gate closing and
  reopening at `MAIL_SHOW`; proven red with the gate removed. Locations: `Modules/Options.lua`,
  `Modules/UI/Mailbox.lua`.
- **MAILBOX-TOGGLE-002: a second General-tab box opens the Mailbox window on non-bank characters
  too.** The operator, with the first box ticked and no window on a non-banker: *"it used to open
  for normal characters, which is why i wanted the check box. it could be useful for non-bankers
  too"* -- then *"make a 2nd check box that enables/disables it, and have it on by default for
  bankers only"*. **Mailbox window on non-bank characters** (first cut *"Open it on characters
  that are not bank characters too"*; the operator: *"open what? the hatch to the nuclear bomb?
  come on, make it short but descriptive and then you put the detail in the tooltip"*)
  (`db.global.bank.mailboxAutoOpenNonBankers`), OFF by default and greyed while the first box is
  off; `Options:IsMailboxAutoOpenForNonBankersEnabled()` reads a missing value as off. So
  `Mailbox:AutoOpens()` is: first box on, then a bank character opens on that alone and anyone
  else needs the second box. It now also returns *why* when the answer is no, and
  `Mailbox:OnMailShow` logs it on `MAIL.EVENTS` -- the first box, the guild note or the second box
  -- because "ticked but it doesn't pop up" looks the same from outside whichever gate it was.
  `mailbox_spec` drives the real toggle: the default, the order under the first box, the greying,
  a non-banker opening once ticked, the master switch overriding it, nil-reads-as-off, and a
  banker unaffected by it. Locations: `Modules/Options.lua`, `Modules/UI/Mailbox.lua`.

### Bug Fixes

- **ENTRY-002: bare `/togbank` opens the Guild Bank window.** The operator, minutes after v1.5.0:
  *"the /togbank command still brings up the old UI, we need it to bring up the new UI, we have a
  /togbank legacy for the old UI."* ENTRY-001 had moved the minimap button to the Guild Bank window
  and deliberately left the bare command on the old Inventory window (its self-audit F4: "not
  changing it unasked"); v1.5.0's own notes said so. Now `ChatCommand("")` toggles
  `TOGBankClassic_UI_Browse`, so `/togbank`, `/bank` and `/gbank` (the aliases route through the
  same dispatcher) all open the Guild Bank window, and `/togbank legacy` alone opens the old
  tab-per-banker window. The `/togbank help` line and the `legacy` help text say so. `browse_spec`'s
  ENTRY-001 example flips from pinning the old window to pinning the new one -- the directive
  changed the spec, the one legitimate reason. Location: `Modules/Chat.lua`.

## [v1.5.0] (2026-09-14) - Setting The Red

<!-- This release was labelled v1.4.2 until 2026-09-13, when the operator renamed it -- "the new UI
     is kinda a big deal, we should update v1.4.2 patch notes to v1.5.0". Every label below, in
     CHANGELOG_ARCHIVE.md, the docs, the code comments and the specs moved with it; verbatim
     operator quotes that say "v1.4.2" were left as spoken. No v1.4.2 was ever tagged. -->

### New Features

- **RAID-SYNC-001: "Keep syncing in a raid group" -- a General-tab checkbox, OFF by default.** The
  operator, after RAID-VISIBILITY-001 made the pause visible: *"can you make a setting so sync will
  work during a raid? have it uncheked by default?"*. The guard stays the default behaviour and the
  setting opts out of it, so an upgrade changes nothing for anyone who does not tick it. **One
  predicate, `TOGBankClassic_Constants.SyncPausedByRaid()`**, is read by all five gates -- the send
  gate, the receive gate, the legacy queue, the guild-ranks cleanup and the status bar's paused line
  -- so the setting cannot free one door and leave another shut, which is exactly what five separate
  `IsInRaid()` tests would have allowed. It lives in `Constants` rather than on `Core` because that
  is the one module every caller and every spec already has (a first cut on `Core` broke two spec
  files that drive `Chat:OnCommReceived` against a stubbed `Core`), and it tolerates an Options table
  without the accessor, which reads as the default: paused. `Tests/raidvisibility_spec.lua` drives
  the REAL Options table and its AceConfig toggle, not a stub. Locations: `Modules/Constants.lua`,
  `Modules/Options.lua`, `Core.lua`, `Modules/Chat.lua`, `Modules/Events.lua`,
  `Modules/UI/StatusBar.lua`.

- **BRAND-001: the addon is "TOG Bank" on screen.** The operator: *"i've rebranded as TOG Bank and
  removed the classic, can you remove it from here?"* -- and *"you don't have to change the name in
  the files anywhere"*. Every window title now reads **TOG Bank v1.5.0 - Guild Bank**. Nothing else
  moved: the folder, both TOCs, every SavedVariable, the AceAddon name, the frame names and the
  options keys are all still `TOGBankClassic`, because those are wire, SavedVariable and
  other-addon contracts rather than text anyone reads. The version shown is the `d.d.d` taken out of
  the raw string, since a released client reports the packager's substitution of
  `@project-version@` -- the whole git tag -- which would otherwise render as
  `TOG Bank vTOGBankClassic-v1.5.0`; a dev build still shows its placeholder verbatim.
  `Tests/windowtitle_spec.lua`. Location: `Modules/UI.lua`.

- **LOG-TAB-001: a Log tab on the Guild Bank window.** The operator: *"for the bank log, lets add a
  bank log tab, perfect thing to add to our new window."* The fourth tab, appended so the three
  already in muscle memory keep their places, reads `TOGBankClassic_Log:GetEntries()` -- the same
  feed TOGTools consumes (LOGAPI-001) -- as sortable rows in the Bankers tab's style: When, Who,
  Action, Item, Qty, With. Deposits and withdrawals name the bank character; request events name
  the requester or banker; With is the other party when the banker's client knew it (the LOGAPI
  `to`/`from`). Money rows render as coin text with no quantity; an item row's text IS its link
  (`Log:ItemLinkFor`), so a hover shows the item tooltip, and a cancelled request's hover shows the
  reason. Newest first by default. The tab repaints itself from the log's own callback as entries
  land -- registered once on the module as owner, so a rebuilt window cannot stack a second one --
  and it does nothing click-gated there, because the log delivers from a timer. The status line and
  the help text both say "since you logged in": the log is session-scoped by the operator's own
  decision (nothing persisted; TOGTools keeps the history), so an empty tab on a fresh login is not
  "nothing ever happened". One example in `Tests/browse_spec.lua` against the REAL log module: two
  bank entries and a request recorded, opened, ordered, the item link and the With column checked,
  a later entry repainting the open tab through the callback. That example passed alone and failed
  in the full suite once -- two clocks can own `C_Timer` in a suite run and which one the log's
  coalescing timer landed on depended on file order; the example now drives both. **LOG-TAB-002,
  the operator's first look ("validated the log works when i filled an order. some issues"):** the
  Who and With columns are **From** and **To**, as they read -- a deposit from the member who
  mailed it (when known) to the bank character, everything else from the actor to the other party;
  Qty is left-justified under its header rather than right-justified into the next column; and
  the item is the CLIENT'S OWN LINK when it has one -- quality colour and suffix included --
  through `Log:ItemLinkFor`, so TOGTools' rows gain it too. That link is taken only when it
  carries the suffix asked for: the first cut took whatever `GetItemInfo` answered, and the
  TOGTools-bridge spec went red because a base-item answer would merge two variants. Locations:
  `Modules/UI/Browse.lua`, `Modules/Log.lua`.

- **DOUBLE-001: a banker's own counts were doubled -- a received copy of the record was stored
  beside the banker's own scan and both were summed.** The operator, on Toglowweap: *"i only have 3x
  archaic defenders. the ui is showing 6. most of the things on toglowweap are doubled"*. Traced with
  a new `/togbank dev sources <banker> [item]` (every bucket the store holds, visible and hidden,
  with when each was read and the item's count in each): the record held an `all` bucket -- 100
  rows, a whole-record snapshot, which only a wire delivery writes -- **beside** `bags` / `bank` /
  `mail`, and `GetAltRecords` sums every bucket. The path is ordinary and would recur: the V2 store
  is account-wide, so a viewer alt on the same account receives its banker's record and stores it
  wholesale; the banker's next scan then wrote its sources next to it, and the carry-forward
  (INV2-VAULT-001) kept `all` for every scan after. The v1.1.0 ITEM-004 class -- a source summed
  instead of replaced -- in the V2 store. Fix, in the store so no writer can recreate it: a named
  source arriving in `SetAltSources` drops the wholesale bucket (visible and hidden halves) -- the
  two never coexist; and `Store:Init` repairs any record already on disk in that state and reports
  the count once at login. No wipe: the named buckets are what this account's own scans read from
  the real containers; `all` was a copy. Known cost, stated precisely (Peer Review db06c629): the
  guild holds the doubled version published at 21:39, so VIEWERS log the phantom copies as
  withdrawals once, when the corrected snapshot lands on them; the banker's own mint diffs a record
  the login repair has already fixed and logs none. The
  PERF-022 spec had asserted the double-count (4 + 7 = 11) as expected; it reads 7 now. Three
  examples in `Tests/store_spec.lua`, one against the exact on-disk shape from the operator's
  client. Locations: `Modules/Inventory/Store.lua`, `Core.lua`, `Modules/Chat.lua`.
  **Retracted on the way:** a "walk away from the bank vs click Close" theory offered before the
  dump was read was wrong -- the operator called it, correctly -- and nothing was built on it.

- **HIDE-SYNC-001: a right-click hide (or any partial scan) waited the whole 180-second fallback
  before publishing, and the banker's own record could not be served meanwhile.** The operator:
  *"it's 'never' syncing"*. `/togbank dev trace` -- which now prints `consult: begun= settled=`,
  the fallback timer, the raid guard and stored-vs-current content hash -- read `begun=true
  settled=false` fifteen minutes into a session, a scan waiting, `CanServe: NO`. The own-bank check
  (`P2P:FinishVersionQuery`) refused to settle while any peer that offered our number had not
  answered the version query; a v1.4.1 peer offers numbers but cannot answer that query, so it sat
  queried-and-silent for ever and only Bank's fallback ever released a deferred scan. A queried
  peer the addon already knows cannot speak the data leg (`Guild:ClaimantCanServe`) now counts as
  answered -- being what it is IS its answer; a silent *capable* peer still holds the gate, as
  before. One example in `Tests/multipc_spec.lua` beside the capable-peer one. The trace's four
  new lines are in `Modules/Chat.lua`. Location: `Modules/P2PSession.lua`.

- **WIRE-SKEW-009: `OnOldWireSummary` raised "invalid key to 'next'" 15 times.** The tripwire
  released send slots inside the `pairs()` walk of the state-wait table, and `ReleaseSendSlot` can
  dispatch the next queued send, which adds a wait to that table -- inserting during traversal is
  undefined in Lua. The matches are collected first and released after. Location:
  `Modules/P2PSession.lua`.

- **CMD-002 again, the other way: `/togbank dev sources` answered "Unknown dev subcommand".** The
  registry and `DEV_COMMAND_NAMES` are two spellings of one fact; the handler was registered
  without the name. `Tests/chatcommand_spec.lua` now drives the typed string through to the handler.

- **LINK-AUDIT-001 (directive, not built): the item-identity / link layer is overhauled whole.**
  The operator, stopping a one-line fix for mail rows stored suffix-less (`Modules/Bank.lua`, a
  Dreadblade of the Bear read in the inbox shown as "Dreadblade"): *"this needs to be part of the
  overhaul ... it was generated when full links went across the wire, and we had link stripping ...
  we have ItemDB now that can fully reconstruct links. A LOT of the logic is probably outdated, bad
  or just wrong."* The map for that audit -- two item databases shipping (the addon's own 3.7 MB
  `Modules/Static/ItemDB.lua` beside the LibItemDB dependency), three link parsers, three link
  reconstructors, the cold-cache async loader, request identity, the fabricated legacy row shape --
  is bank entry #13641 and the LINK-AUDIT-001 todo. The mail-suffix line is marked KNOWN WRONG in
  place and left for that session.

- **LOG-PERSIST-001: the bank log keeps its last 250 entries across reloads.** The operator, on a
  Log tab empty after `/reload`: *"i think we do need some small amount of the bank log to persist
  in TOGBank, but not a lot. we need to ensure it's getting passed around."* The design rule had been
  no persistence at all (the operator's own, 2026-09-11 -- TOGTools stores). What already persisted
  was the delta chain (`Modules/Inventory/Chain.lua`, the last 25 versions per banker) -- the bank
  movements and how they are passed around -- but the log's own entry buffer was in memory, so the
  tab started empty every session and request events (`requested`, `mailed`, `handed`,
  `cancelled`, `reopened`) were gone for good. Now the buffer IS the V2 store's guild table
  (`<guild>.log`, beside the chain, account-wide), so an append is a save and a reload reads it
  back; `Log.MAX_ENTRIES` drops from 500 to 250 and bounds the cost (~25 KB per guild). "Passed
  around" needs no new wire: every client records the same entries from the same transitions.
  The tab's status line and help now name the cap instead of "since you logged in". One example
  in `Tests/logapi_spec.lua`: written to the store's table, read back after the cache is dropped,
  pruned in place. Locations: `Modules/Log.lua`, `Modules/UI/Browse.lua`.

- **LOGAPI-004 / LOGAPI-005: the other party on TOGTools rows, and request rows for TOGTools.** The
  operator, reading TOGTools' Guild Bank tab: *"the mail item didn't end up there either"* (it had,
  as the Withdraw row -- with nobody named on it) and *"the requests aren't showing up in the
  togtools logs"*. Both are the bridge's doing: it pushed bank movements only and dropped every
  request event on the reasoning that a `mailed` fill duplicates the next rescan's `withdraw` --
  true of `mailed` and of nothing else. Now every item row carries `to` / `from` when the log
  knows them (LOGAPI-004, shipping), and request events go as `kind = "request"` rows -- `type`
  requested / mailed / handed / cancelled / reopened, `name`, `to`, the link, `count`, `note`,
  `requestId`, `occ = ts:requestId` -- but ONLY when TOGTools declares `ACCEPTS_REQUEST_ROWS` on
  its log (LOGAPI-005, gated): its reader copies known fields only, so a row it does not know
  would be stored and never shown. Both raised to TOGTools' inbox as contract `f043d2415235`,
  with the render and dedupe asks. `Tests/togtoolsbridge_spec.lua` pins the fields, the row shape
  and the gate through the real feed. Location: `Modules/Log.lua`.

- **LOG-DEBUG-001: a LOG debug category, selectable on the Debug tab.** The operator, watching a
  banker's entries fail to reach a viewer: *"is there debugging for the new log sync? is it exposed
  as a type in the debug tab so i can select it so we can watch just it, or does it fall in with
  other debug types?"* -- there was not: the log's only lines were failures, filed under
  `SYNC`/`LOGAPI`. Every line the log emits is now under its own **LOG** category (the three
  registries -- `DEBUG_CATEGORY`, `Database:Init`'s defaults, `CATEGORY_META` -- all carry it, and
  `Tests/constants_spec.lua` holds them in step), tagged **RECORD** (an inventory diff: rows, money,
  from/to version, whether a `who` rode along; each entry as it lands; why a change was NOT diffed
  -- no earlier copy, no publish time; a request mutation that moved no logged field), **DELIVER**
  (the batch size and consumer count, and what TOGTools said: stored / duplicate / disabled) or
  **FAIL** (a consumer's callback or the TOGTools bridge threw -- was `SYNC`/`LOGAPI`, whose tag
  entry is kept so a saved opt-out does not become an unknown key). `Tests/logapi_spec.lua` pins the
  RECORD, DELIVER and FAIL lines and that `Modules/Log.lua` has exactly one `Output:Debug` call site,
  naming `LOG`. Locations: `Modules/Constants.lua`, `Modules/Database.lua`, `Modules/Options.lua`,
  `Modules/Log.lua`.

- **BROWSE-001: the Guild Bank window -- the whole bank as one list, bankers as a column.**
  crimsonmane (Discord, 2026-09-07): *"Browsing the guild bank tab-by-tab is only meaningful if
  the character names reflect the type of items being held ... a wall of icons which carry very
  little meaning"*. The operator: *"he clearly doesn't like the 'here is a list of bankers' as the
  view"*, *"make it look more like the FGI's scan tab in layout ... 'filter stuff' across the top,
  and rows of things across the bottom, then a banker tab"*, *"requests isn't a separate window,
  it's just another tab"*, *"follow the look and feel of FGI, with the zebra stripped rows ... the
  same font size/style"*, and: build it in parallel, ship it in v1.5.0.

  `Modules/UI/Browse.lua` (`TOGBankClassic_UI_Browse`), `/togbank browse` and a Browse button on
  the Inventory window. One window, tabs across the top:
  - **Browse** -- a filter strip (the one search box matching name, banker and type; Bank; Type ->
    Subtype -> Slot; Quality; min/max level; Usable by me -- Search's own lists, exposed as
    `TOGBankClassic_UI_Search.Filters` rather than copied) over sortable rows of every banker's
    stock: icon, name in quality colour, quantity, banker with the staleness dot the tab colour
    used to carry, type, required level. Filters apply as they change. Left click = the request
    dialog (Search's); a view-only bank's row says so instead; right-click on your own bank's row
    = hide/show (HIDE-001). Every row is `Guild:GetAltItems` -- the same accessor every window
    reads.
  - **Bankers** -- one row per banker: online, status in words and colour (Current / Behind /
    Update offered / Old format / No data), when last published, items, money. Click a banker =
    Browse filtered to that bank.
  - **Requests** -- opens the Requests window docked beside this one (it docks to the Guild Bank
    window when that is open, else to Inventory as before). KNOWN COST, stated when the tab was
    asked for: the Requests window is 3,500 lines bound to its own frame, so rendering its rows
    inside the tab is the next step, once the row list has been seen on screen.

  `Modules/UI/RowList.lua` (`TOGBankClassic_UI_RowList`) is FastGuildInvite's `GUI/RowList.lua`
  ported and trimmed, with its values taken from that file: 16px rows, every second row banded
  at 4% white, a 20px header at 8% with a gold rule, `GameFontNormalSmall` headers (in the
  addon's gold) over `GameFontHighlightSmall` cells, the Calendar MoreArrow sort indicator,
  virtual scrolling with Blizzard's scrollbar art on a plain Slider (FGI found the template
  crashes on a plain frame), mouse wheel. Trimmed of FGI's class colours, locale fonts and
  checkbox/expander cells; given an icon cell, the mouse button on a row click, and enter/leave.
  A candidate for LibAceGUIWidgets once a second addon wants it -- raised, not moved.

  Wired like every window: `ALPHA_WINDOWS` (its own transparency slider), the shared status bar,
  Escape through the controller frame, both TOCs after Search.lua. `Inventory:RefreshSoon` fans
  out to it, so every "data landed" repaint reaches it on the same debounce. Inventory, Search and
  the minimap entry are untouched -- the operator wants to play with it before it becomes the
  front door. Not built yet, by design: the grid view toggle, a My Bank tab, the Requests fold-in.

  `Tests/browse_spec.lua`, 18 examples: the row list's visual contract (heights, banding on even
  rows only, fonts, gold headers), the visible window and scrollbar, pool growth on resize, header
  sorting (asc/desc, numeric, case-blind, `_sort_` overrides, the arrow, opt-out), row click with
  offset and button, preserved scroll; the rows (one per banker per variant, columns, slot from the
  store's numeric equipId, every filter alone and together, the banker summary, "never"); the
  window built on the real AceGUI under the frame model (tabs, filter strip, status text, the
  Bankers click, the Requests tab, click semantics, reachability and TOC order). Two env fixes
  the spec forced: `env_togbank`'s `GetItemQualityColor` answered white for every quality (a
  legendary-is-orange assertion would have passed by construction), now the client's table; and
  Ace3's widget files capture `CreateFrame` at file scope, once per Lua state, so a spec that
  loads them under the hollow env breaks every later window spec -- this file loads them under the
  frame model in every describe, and says why. NOT RUN IN GAME. Locations: `Modules/UI/Browse.lua`,
  `Modules/UI/RowList.lua`, `Modules/UI/Search.lua` (Filters exposed), `Modules/UI/Inventory.lua`
  (button, fan-out), `Modules/UI/Requests.lua` (docking), `Modules/UI.lua`, `Modules/Chat.lua`,
  both TOCs, `.luacheckrc`, `.luarc.json`.

- **BROWSE-002: the Requests body INSIDE the Guild Bank window's tab, and the first screen
  round.** The operator, on the first cut: *"the requests still pops up the window, and it's not
  inside the new UI"* -- the KNOWN COST above, paid. `Modules/UI/Requests.lua` now renders its body
  into a HOST: `DrawWindow` builds the standalone frame and calls `BuildBody(host, chrome, anchor)`
  with itself; `Requests:Embed(host, chrome, anchor)` builds the same body as children of the Guild
  Bank window's tab group, hangs the bottom icon cluster (pagination, broom, envelope) on that
  window's frame left of its help icon, and routes every status message to its bar
  (`Requests:SetStatusText`, which every dialog and `Events`/`Mail` now call instead of reaching
  for `.Window`). One rendering at a time: embedding releases a standalone window that is up, and
  `Requests:Open()` while the Guild Bank window is open goes to its tab. `Requests:Detach()` (the
  tab changing, the window closing) unregisters the bag listener, hides the cluster and the
  settings overlay, bumps the draw generation so a queued row batch cannot touch released widgets,
  and forgets every widget reference; the tab group releases the widgets. Two leaks the split
  surfaced and closed, in both modes: the cluster and the officer settings overlay were re-created
  on a frame AceGUI had pooled and handed back (a banker-status rebuild; every tab visit), stacking
  a second set under the first -- both are now cached on the chrome frame and rebuilt only when the
  roles they depend on change. The frame-level scripts (resize follow-through, Escape closing an
  open dropdown) are installed once per frame against the module, not a closure.
  `Browse:ShowTab` detaches BEFORE releasing children; `Browse`'s OnClose detaches too.
  - **The help icon**, *"like in all the other addons, explaining how the page works"*: a "?" at
    the same spot as every window's, with per-tab text (Browse, Bankers, or the Requests body's
    own). It BREATHES -- *"can you make it 'breath' like you did the old request rows?"* -- the
    request glow's pulse (1 -> 0.35 over a second, BOUNCE, eased) until the first mouseover, then
    stops and stays stopped: *"when someone mouses over it for the first time, it stops? i want to
    draw their attention to it, ONCE"*. Remembered account-wide in `Options.db.global.helpSeen`.
  - **The filter strip**, *"the stuff at the top needs to align vertically, and the search bar is
    too close to the border"*: a two-row, five-column AceGUI Table (220/150/130/140/110) on a group
    inset 8px from the tab border, cells bottom-aligned so the label-less search box, the labelled
    dropdowns and edit boxes, the checkbox and the button sit on one line per row; the second row's
    widgets start at the first row's column edges.
  - **Clear**, *"we also need a clear filters button on the browse page"*: a button on the second
    row; `Browse:ClearFilters` puts every filter back to `DefaultFilters()`, rebuilds the strip so
    the widgets show it, redraws. `Browse:FiltersActive()` says whether anything is narrowing.
  - **Usable by me works**, *"i don't think the usable by me is working on the browse tab"*: it
    compared the required level alone, which at level 60 filters nothing. It now reads what the
    item's tooltip shows in RED -- class, race, armour or weapon proficiency, level -- off a hidden
    scanning tooltip (`Browse.TooltipLines`, the seam a spec replaces), once per item per session,
    the cache dropped on a level change; the level gate runs first so no tooltip is read for an
    item the level already excludes. The checkbox's tooltip says so.
  `Tests/browse_spec.lua` (+8, 26): the embed/detach contract against a stub body (host, chrome,
  anchor; detach BEFORE the release; detach on close); the help icon (position, breathing, the
  first hover stops it and marks the account, the next window is still, the Requests tab's text);
  the strip's table, alignment, inset, ten cells and Clear resetting everything and redrawing; usable
  through the tooltip (a red line hides an item the level allows, one read per item, cached across
  draws, the cache dropped on a level change, no read for a level-excluded item) and the default
  reader against a scan tooltip; and four examples driving the REAL Requests body: embedded as the
  tab's five children with the cluster on the Guild Bank window's frame off its help icon and its
  status text on that bar; `Requests:Open()` going to the tab; leaving the tab forgetting every
  widget and hiding the cluster, returning without a second cluster; the standalone window still
  opening when the Guild Bank window is closed, moving into the tab when it opens, and opening
  standalone again after. 1402/0; luacheck clean. NOT RUN IN GAME. Locations: `Modules/UI/Requests.lua`
  (BuildBody/Embed/Detach/ForgetBody/BuildBottomCluster/ShowCluster/SetStatusText/AddHelpLines),
  `Modules/UI/Browse.lua`, `Modules/Options.lua` (helpSeen default), `Modules/Events.lua`,
  `Modules/Mail.lua`.
  **Second screen round, same day:** (1) *"as a hunter i can't use hammers, you may want to use
  some of what dibs did"* -- the red-line tooltip scan is gone; `Modules/Usable.lua`
  (`TOGBankClassic_Usable`, both TOCs) is Dibs' `Items:CanUse` ported: level, LibItemDB
  `ClassUsable` (feature-detected), the armour/shield/weapon proficiency tables (a COPY of Dibs';
  `Tests/usable_spec.lua` pins every value, home should be LibItemDB; the GATE is re-derived: a
  level-aware armour cap, no faction layer), and the tooltip's Classes:/Races: tags -- via
  `C_TooltipInfo` where it exists, else a hidden scanning tooltip, because Blizzard's own
  `Blizzard_SharedXMLGame.toc` loads TooltipUtil/TooltipComparisonManager for mainline only and
  excludes TooltipDataHandler on vanilla (Peer Review, correcting an earlier claim here that Era's
  UI reads it) -- cached per character then per item. Rows carry `equipLoc`. Why the red-line
  scan missed maces, most likely: slot and type are one DOUBLE line and the red is on the RIGHT
  text; that scan read TextLeft only. (2) *"the 'stuff' isn't fitting into the request
  tab page"* -- AceGUI's TabGroup resizes itself to its content when a Flow layout finishes;
  `SetAutoAdjustHeight(false)` keeps the size the window gives it, and `Embed` lays out once
  before the first draw so the column widths and table height measure real sizes. (3) *"settings
  is still popping up another window"* -- the officer panel is anchored to the tab body, not the
  window frame, and `ShowSettings` hides the search box, dropdowns, header and table while it is
  up. (4) *"bug with the requests"* (an empty Requester pullout the height of the window, an empty
  Bank value) -- `UpdateFilters` sends a dropdown its list only when it changed against a cache on
  the module; `ForgetBody` clears the four caches so rebuilt dropdowns get their lists.
  `SetupClickOutsideHandler` wraps a pooled dropdown's pullout once, not per rebuild. (5) *"the
  stuff at the top disappearing sometimes"* -- POOL HYGIENE: `setWidgetShown` neuters a hidden
  widget's `frame.Show` so AceGUI's Flow cannot re-show it; released like that, the frame came back
  from the shared pool as the Browse strip's group or its Clear button and could never be shown.
  One `restoreWidgetOnRelease` handler (registered by every marking site: the hidden Show, the
  fulfil button's dimmed alpha and tooltip hook, the cancel glow) undoes every mark on release;
  the fulfil tooltip hook is gated on `togFulfillActive` so a reused Button does not carry it.
  Also: `SetAutoAdjustHeight(false)` on the strip BEFORE its height -- AceGUI re-lays a container
  out when its content resizes, and an empty layout finishing first sized it to nothing.
  `browse_spec` (+4: the tab group's fixed size, Settings in-tab hiding the list and reusing one
  panel, the strip whole after Requests/Bankers/Settings visits with alpha 1, the hunter/mage
  usable join), `usable_spec` (new, 15). Proven red: the strip hidden after the Settings visit
  without the release handler. NOT RUN IN GAME beyond the operator's screenshots.
  **Third round + Peer Review 93aa3a0a:** the GEAR icon left of the "?" ("like in the legacy
  version to open settings"; `Browse:EnsureSettingsIcon`, the main window's geometry), and it is
  now the leftmost own icon the status bar and the Requests cluster hang from
  (`Browse:BottomAnchor`); the row list starts 12px under the strip (`STRIP_H` 100, `FILTER_H`
  112 -- "the bottom row is too close to the column header row"); re-selecting the Requests tab
  while its body is still embedded no longer rebuilds it (F4 -- AceGUI fires OnGroupSelected for
  the selected tab too; the guard is "still embedded", not the tab name, because Close detaches
  without releasing); `ShowCluster(false)` re-registers the chrome's own icons with the hitbox
  lift (F3); the fulfil OnLeave hook is gated like OnEnter (F8); `TagsAllow` caches per
  character then per item, no string key per row (F1). 1420/0; luacheck + markdownlint clean.

- **COLLECT-002: the bank-collect click swaps into a full bag.** Discord (NanaTheBanana,
  2026-08-29): *"could a button be added to the requests window to pull all missing items from the
  bank into your bag. Then, if the bag is full, it will swap items in the inventory for the missing
  items"*; the operator narrowed it to the existing button -- *"the only thing you should have to
  change is the logic to put things into the bank when the bags are full that aren't needed to
  fill an order"*. So: no new button, no loop; `Mail:BankCollectStep` (the v1.4.1 BANKFILL-001
  click) no longer stops at "Bags are full -- make room". It picks the wanted bank stack exactly as
  before, then picks up the first carried stack that NO open order of this banker needs
  (`Bank:FindUnneededBagStack`, fed by `Mail:ItemsOpenOrdersNeed` -- by id and by lowercased name so
  a legacy request's item is protected too; the hearthstone is never offered) and drops it onto the
  wanted bank slot. The client exchanges the two, so the order's stack lands in that bag slot and
  the spare goes to the bank -- no free slot needed on either side, which a plain move-out with a
  full bank could not manage. The surplus handling is unchanged: an overshooting swap arms the same
  return phase a plain pull does. When every carried stack is needed the click says so and moves
  nothing. `Tests/bankcollect_spec.lua` (53): the fixture now models the client's swap (a drop on
  an occupied slot exchanges the stacks; a same-item drop is refused as a merge the addon must not
  rely on); the old "refuses with full bags" case became "swaps an unneeded stack", plus
  swap-then-return, every-stack-needed, name-protected legacy request and hearthstone, and
  first-unneeded-slot order. NOT RUN IN GAME -- the swap is two `PickupContainerItem` calls 0.1 s
  apart, the same cadence the return phase already uses. Locations: `Modules/Mail.lua`,
  `Modules/Bank.lua`, `Modules/UI/Requests.lua` (tooltip).

- **HIDE-001: a banker hides items from the guild by right-clicking them.** Discord (Vishiswaz,
  2026-08-25): *"right click and hide or unhide items in this interface while on a gbank toon,
  which will change whether or not the item is transmitted as being in the inventory when syncing
  ... indicated in this interface either with a red glow or by being turned grey scale or a red
  dot"* -- the hearthstone, stock bought to resell, the soulbound leftovers of a main repurposed as
  a bank. The operator's constraint from the same thread: the indication lives in TOGBank's own
  window, never in the bags, because bag addons interfere.

  On the banker's OWN tab of the Inventory window, right-click any item to hide it; it stays on
  that tab greyed out with a red badge (`Interface\RaidFrame\ReadyCheck-NotReady`, verified in the
  Era tree) and the tooltip says *"Hidden from the guild -- right-click to show it"*; right-click
  again to show it. Everywhere else -- every other guildmate's copy, Search, the tooltips, the
  fulfil path, TOGProfessionMaster -- the addon acts as if the banker does not have it.

  WHERE THE SPLIT HAPPENS is the design: at the store write, not on the wire. The banker's list
  (`Options.db.char.hiddenItems`, `Record.key -> true`, per character) rides every
  `Store:SetAltSources` call from `Bank:Scan`; the store splits EVERY bucket on it -- the ones
  supplied and the ones carried forward -- into `sources` (what `GetAltRecords`, the view and the
  totals read) and a local `hidden` table beside them. So a hidden row is absent from the content
  hash, the canon, the chain, the log, the snapshot and every viewer with no second code path that
  could forget to filter, and the kept rows are what let a banker hide or show a VAULT item while
  away from the bank (the carried-forward bucket is re-split) and what the own tab draws greyed
  (`Store:GetAltHiddenRecords` / `GetAltHiddenView`, read by that tab alone). `Bank:SetHidden`
  flips the key, marks the scan dirty and re-scans, so the guild is told now rather than at the
  next vault visit; the received-delivery path (`SetAltRecords`) never carries a hidden bucket.
  `DrawItem` registers both mouse buttons (AceGUI's Icon registers none); the default click handler
  ignores a right click rather than picking the item up; `ShowItemTooltip` takes extra lines.
  Toggling reloads the tab explicitly (`UI_Inventory:ReloadTab`) because `DrawContent` deliberately
  does not re-select the current tab (UI-004).

  KNOWN COST, by construction: to the guild's bank log a hide reads as a withdrawal and a show as a
  deposit, because that is exactly what the published record did.

- **HIDE-002: "Hide soulbound items from the guild" -- a banker checkbox.** Vishiswaz's second
  ask in the same thread (*"auto-hide all soulbound items should be a thing ... a no-longer-active
  character ... repurposed as a guild bank"*); the operator: *"a setting for bankers in settings in
  the banker only settings, a check box"*. On the banker-only Bank panel, OFF by default (ticking
  it changes what the banker publishes, and an upgrade must not do that unasked). The scan reads
  `ContainerItemInfo.isBound` per slot (in Era's ContainerDocumentation.lua) and reports the bound
  keys PER SOURCE; `Bank:RememberBoundKeys` keeps them in `Options.db.char.boundKeys` per source,
  because the vault is readable only at a banker and a scan away from it must keep the vault's
  bound keys rather than lose them. While the box is ticked `Bank:EffectiveHiddenKeys` unions the
  remembered bound keys with the right-clicked list into the store split HIDE-001 built -- so
  nothing downstream changed at all. The two lists stay apart: unticking shows every bound item
  again and leaves the manual list alone. Ticking or unticking rescans and republishes at once.
  On the banker's own tab a bound-hidden row's tooltip says *"soulbound (Bank settings: Hide
  soulbound items)"* and a right click on it explains rather than looking like it did nothing
  (`Bank:HiddenReason`). KNOWN COST: bound-ness is per item VARIANT (the store aggregates by key),
  so a bound and an unbound copy of the same item hide together. `Tests/hideitems_spec.lua` +5
  (21): off by default with the keys still remembered; hides every bound slot and reports the
  reason, manual still wins; the vault's keys survive a scan away from the bank; unticking shows
  them and leaves the manual list; the checkbox is on the banker-only panel, default off, and its
  setter rescans. `Tests/env_togbank.lua`: `setBag` takes `bound = true` per slot and
  `GetContainerItemInfo` reports `isBound`. NOT RUN IN GAME. Locations:
  `Modules/Inventory/Scan.lua`, `Modules/Bank.lua`, `Modules/Options.lua`, `Modules/UI/Inventory.lua`.

  SELF-AUDIT 2026-09-12 (three defects, all the same class, all fixed before release): (a) the
  right button now reaches every slot's OnClick, and the Search window's handler did not look at
  it -- a right click on a result opened the request dialog; it returns on `RightButton` now, and
  Mail/Mailbox use DrawItem's default handler, which already drops it. (b) AceGUI's widget pool is
  shared with every addon: a Requests date Label released with the glow ON (the window is Released
  whole when banker status changes, ALPHA-001's path) would surface in another addon's UI with our
  date pulsing under its text; `SetCancelGlow(true)` now registers `OnRelease` to switch it off --
  on EVERY switch-on, because AceGUI wipes a widget's callbacks on release and hands back the same
  object (a once-per-widget flag, the first fix, would have leaked on the second acquire). (c) the
  same for a hidden-row Icon: released grey with the badge up by the Inventory tab's per-reload
  `ReleaseChildren`, it would come out that way for whoever acquired it next, our own Search
  included; `DrawItem` registers a per-acquire `OnRelease` that undoes both. All three pinned:
  `searchbox_spec` (release and re-acquire of the Label), `hideitems_spec` (release and second
  release of the Icon; Search's handler as a source property). Also added on the audit: the fleet
  scenario `a banker HIDES an item: the viewer's copy drops it as one link; showing it brings it
  back` in `fullsync_spec` -- the hide travelling the real mint -> link -> apply path.

  `Tests/hideitems_spec.lua`, 16 examples: the split keeps a hidden key out of every viewer read
  and in the hidden set; nil/empty lists write no hidden table; a carried-forward vault bucket is
  re-split both ways away from the bank; two suffix variants split independently; the receive path
  is untouched; the caches drop on a hide-only write; `Bank:SetHidden` re-scans and the content
  hash changes and changes back, no-op and malformed toggles do nothing, the dirty mark beats the
  hasUpdated gate; a hidden row is greyed and badged and a pooled slot loses both on reuse; both
  buttons registered; a right click never picks up; the tooltip lines; the Inventory toggle and
  reload. The own-tab merge and the "nobody else reads the hidden view" property are pinned as
  source properties. NOT RUN IN GAME. Locations: `Modules/Inventory/Store.lua`, `Modules/Bank.lua`,
  `Modules/UI.lua`, `Modules/UI/Inventory.lua`, `Modules/Options.lua`, `Modules/Constants.lua`
  (the BANK/HIDE tag), `Tests/env_togbank.lua` (`tooltipAdded`: lines the addon adds to the
  tooltip, the other direction from `tooltipLines`).

- **REQUESTS-ROWLIST-001: the Requests tab on the same rows as Browse.** The operator, with a
  screenshot of the two tabs side by side: *"we need to make the request tab look and feel like the
  browse and bankers tab looks. right now it's different. we need the same zebra striping/spaceing
  etc."* The body is a `TOGBankClassic_UI_RowList` now -- 16px banded rows, the small fonts, the
  gold header rule and the gutter scrollbar the other three tabs have -- on a plain frame hung under
  the filter strip, one per host frame and found again on every tab visit. Three columns paint their
  own cells (the RowList grew `col.build`, `onRowRender`, `onSortChanged` for it): the date (status
  glyph, the cancelled glow, the timeline tooltip), the item (the invisible copy overlay and the item
  tooltip, kept verbatim for LINK-AUDIT-001) and the actions (five fixed icon slots whose clicks read
  the request off the cell, since the RowList pools rows by position). The AceGUI label grid, its
  column arithmetic, the per-request row pool and the batched row builder are gone. **KNOWN COST:**
  no page buttons -- the list scrolls the whole set; the action buttons are icon glyphs with a hover
  name; the window's floor is computed from the columns (~784, was 972 -- REQUESTS-LAYOUT-001 by its
  candidate (a)). **REQUESTS-ROWLIST-002, the operator's first open of the tab:** *"integer overflow
  attempting to store 8210744788"* -- the sort tie-break formatted the inverted date with `%d`, which
  the client refuses past 32 bits and the offline Lua casts silently; `%.0f` now. `Tests/browse_spec.lua`
  (+6): same RowList class, banding, fonts and gutter as Browse; glyph, colour, glow and icons
  following a scroll with the click acting on the request the row shows NOW; the bag-update refresh
  on rows in view; the three owned cells' hovers (timeline, item link, icon name, each locking the row
  highlight) and the copy overlay's focus, Escape and 5 s auto-clear; a header click moving the body's
  sort through a redraw and a tab revisit; the tie-break's shape; all-fixed-width columns on the
  RowList. RowList.lua at 100% lines. Locations: `Modules/UI/Requests.lua`, `Modules/UI/RowList.lua`.
  **Seen in game 2026-09-13** ("much better ... requests-rowlist- working, see screenshot"): banded
  rows, glyphs, icons and the sort arrow all as built.

- **ENTRY-001: the minimap click opens the Guild Bank window; `/togbank legacy` opens the old
  Inventory window; `/togbank browse` is gone.** The operator: *"can you make the MMB open the new
  UI and browse open the legacy ui?"*, then *"can you rename it from togbank browse to togbank
  legacy?"* -- swapped from BROWSE-001's first cut and renamed. Bare `/togbank` still opens the old
  window; shift-click is still the options; the minimap tooltip says "Guild Bank". The old window
  goes when BROWSE-002 follow-on (d) retires it. The `browse_spec` reachability example now DRIVES
  the real LDB object's `OnClick`, the real `/togbank legacy` and a `browse` that falls through to
  the help, all through `Chat:ChatCommand`, rather than grepping for the call. README and the
  CurseForge text updated. Locations: `Modules/UI/Minimap.lua`, `Modules/Chat.lua`.

- **HIDE-SHARE-001: a hide or show announces its version at once.** The operator, on restoring a
  hidden item: *"the status bar doesn't update ... can we have the game do a /togbank share when we
  do the hide/unhide?"* The hide already minted a new version (HIDE-001's rescan); nothing
  broadcast it until the 10-minute timer, so the "bank update" line had nothing to move on.
  `Bank:SetHidden` sets `shareOnMint`; `MintVersion` -- the one place a canon is born -- spends it
  with `Events:SyncDeltaVersion("NORMAL")`, so a hide the publish gate defers (MULTIPC-001) shares
  when the deferred publish mints, and a hide of something the bank does not hold (no content
  change) shares nothing. This is NOT the post-scan broadcast ruled out on 2026-09-11 (a vault scan
  can be half the data): a hide re-partitions sources already held, so its version is whole. The
  raid and collision guards are `SyncDeltaVersion`'s own. One example in `Tests/hideitems_spec.lua`
  (plain scan does not share; hide and show each share once; a no-change hide does not; a deferred
  hide shares on `PublishIfDeferred`). NOT RUN IN GAME. Location: `Modules/Bank.lua`.

- **MULTIFILL-001: one requester's orders on one mail.** The operator: *"if 1 person has 4
  requests for a banker, we can fill all the requests in one mail?"* Two paths. The row's Fulfill
  icon used to refuse a mail with anything attached; it now appends to a mail the addon opened for
  the SAME requester, from the first free slot, up to the twelve -- click Fulfill on each of their
  rows, Send once. Anyone else's mail is still refused, naming whose it is; a hand-built mail (no
  pending send) is nobody's to append to. Fulfill Oldest used to send one order per mail; after
  choosing the oldest order it now takes that requester's other open orders that whole stacks in
  the bags cover with no split, oldest first, into the slots left (`Mail:FindMoreOrdersFor`), each
  planned against stacks the earlier orders have not claimed, so two orders for one item never
  share a stack; an extra that would not fit is dropped whole, never half. On send, `pendingSend`
  carries one entry per order with ITS id and `ApplyPendingSend` credits each by that id (the
  envelope's `requestId` stays the first order's for older readers). Split orders keep their own
  mail: the stepped split is one per click. `Tests/multifill_spec.lua` (7): a send-slot model the
  harness lacks (`GetSendMailItem`, `ClickSendMailItemButton`; contract f9ceb03474df filed) lives in
  the spec. **Self-audit, two defects fixed before it was seen:** (a) "is the mail loaded" read
  slot 1 alone, so a banker who detached slot 1 by hand left slots 2+ loaded and the next Fulfill
  would have started a fresh pending send over them -- every slot is read now, the gap is filled,
  and the send hook cuts each pending entry to what is REALLY attached under its name, so a
  detached order is not credited (this half was latent in the single-order path too); (b) Fulfill
  Oldest's extras could plan the full count of the stack the first order was about to SPLIT and be
  credited for a remainder -- the split's source stack is claimed first. NOT RUN IN GAME. Location:
  `Modules/Mail.lua`.

- **MULTIFILL-002: split orders ride the same mail.** The operator, with a screenshot of four 1x
  Elemental orders for one person sent as FOUR mails: *"because each of these required a split, it
  went split, create mail, attach, send mail, split, create mail blah blah blah and send 4 mails, it
  should do all the splitting first for ONE recipient, create the mail, attach everything to one
  mail, then send it."* MULTIFILL-001 left any order needing a split for its own mail, so four
  orders that each needed one were four mails. Now `FindMoreOrdersFor` accepts a split plan for an
  extra -- it takes one attachment slot and claims its SOURCE stack, as IDLE already claims the
  first order's, so a second order wanting to split the same stack finds nothing unclaimed and waits
  for the next mail. IDLE collects every split (the first order's and each extra's) into
  `batchState.splits`; the SPLIT click performs them ALL: the empty slots are enumerated up front
  (`tog_emptyBagSlots` -- a split not yet picked up is invisible to the container API, so a
  per-split search would hand every split the same slot), and the click refuses with "Need N free
  bag slots" touching nothing when there are fewer; then split *i* runs at (i-1) x 0.25s with its
  pickup 0.1s later, every timer scheduled flat from the click, so each pickup has cleared the
  cursor before the next split loads it. ATTACH waits until every split slot holds an item, then
  attaches the first order's split stack and whole stacks, then each extra's the same way; SEND is
  unchanged. The old `splitBag`/`splitSlot` pair on the batch is gone. `Tests/multifill_spec.lua`
  +4 (11): four 1x orders from four 5-stacks -> one SPLIT click, four split stacks in four distinct
  slots, one ATTACH of four, one mail crediting four; whole + split + whole mixed on one mail; the
  up-front refusal with two free slots and three splits, then the same click going through once
  room is made; two orders splitting from ONE stack -> the second waits and fills on the next mail.
  The earlier example that pinned "a split order is left for its own mail" now pins an order the
  bags cannot cover at all. NOT RUN IN GAME. Location: `Modules/Mail.lua`.

- **MAILCOLLECT-001: Take Needed on the Mailbox window.** The operator: *"can you do the grabbing
  from the mail like we do with the bank to fill orders? so we can grab items out of the 'mail bank'
  that we need?"* -- the mailbox's Fulfill-at-the-bank. `Mailbox:OwedByOpenOrders` sums what this
  banker's open orders still ask for per item, less the bags; `NeededAttachments` walks the inbox
  oldest mail first, skips COD, and takes stacks of an owed item only until the shortfall is covered
  (a mail stack cannot be split, so the last one may overshoot; none is taken once covered); the
  button runs them through the same take sequencer as Take Shown. Bankers only. Three examples in
  `Tests/mailbox_spec.lua`. NOT RUN IN GAME. Location: `Modules/UI/Mailbox.lua`.

- **MAILBTN-001: the "TOG Bank" button is on the mail frame's title bar, beside TSM4's.** The
  operator, screenshot of it floating under the title: *"it needs to be on line in the top with TSM
  but on the left side of that box."* TSM's own placement, read from
  `TradeSkillMaster/Core/UI/MailingUI/Core.lua:163-173` (60x16, MailFrame TOPRIGHT -26,-3, level
  +3, small font), shifted one width and a gap left when TSM is loaded (`C_AddOns.IsAddOnLoaded`,
  feature-detected), in TSM's own spot when it is not. Second round, in game: *"it is the right
  height, perfectly centered ... BUT, i want it in the left corner of that 'bar area'"* -- beside
  TSM4 it covered the "Inbox" title. So the LEFT end of the title bar, right of the portrait ring,
  TSM-independent (the detection went). Third and fourth rounds moved it left by screenshot, 74 ->
  60 -> 52 (`MAILBTN_X`, the one number). `mailbox_spec` pins the anchor. Location:
  `Modules/UI/Mailbox.lua`.

- **PROP-PERSIST-001: the "bank update not received" line survives a relog.** The operator, having
  logged out to test the hide/show share: *"it doesn't [live through SV]. we should have this live
  through so they know no one synced the data if they are disconnected or any other reason."* The
  tracker was session-scoped by design ("republished at the next login anyway") -- and a disconnect
  is exactly when the banker never saw it. `Propagation:Save` writes the tracker to `db.char` on
  every change; `Restore`, at login before the broadcast, brings it back while the held canon is
  still the one it describes and nobody has confirmed it (a confirmed one, or one for a canon the
  record no longer holds, is dropped), with the wait measured from the publish. Three examples in
  `Tests/propagation_spec.lua`. **Failed its first in-game test** (*"it is not, the timer is
  gone"*): the roster-init hook called `Restore` BEFORE `Guild:Init` had loaded the record, so it
  judged the save against no held canon and threw it away. `Restore` now leaves the save alone
  while the record is not loaded, and `Guild:Init` calls it again right after `Database:Load`.
  Locations: `Modules/Propagation.lua`, `Modules/Events.lua`, `Modules/Guild.lua`.

- **REQUESTS-STRIP-001: the Requests tab's controls in the Browse tab's strip.** The operator,
  screenshot of a non-banker's tab: *"the request dropdowns overlap the column header row. we need
  to move the dropdowns up 5 or so px. we also need to do the left hand alignment we did on the
  browse tab here."* One Table strip inset 8px like Browse's (the search box spanning the first row,
  the dropdowns on the second, the banker's checkbox on a third, cells bottom-aligned) and the list
  10px under it rather than 4 -- the dropdown's textures sit under its frame's bottom edge, which is
  what ran into the header. LibAceGUIWidgets has no alignment helper (its function list read); the
  Table layout's own `alignV` / `colspan` are what both tabs use. Second round (screenshot: the
  dropdowns' box art sat ~12px right of the search box above them): search and the two dropdowns
  are ONE row -- Browse's exact row, columns 220/200/200 -- with the banker's checkbox on the
  second. **REQUESTS-STRIP-002**, the operator's next look (*"there is a lot of dead space between
  that strip and the subtabs"*): the Requests/Archive/Settings sub-tab row was set to 30px but never
  held it -- a full-width child is laid out by the host's Flow, and an AceGUI TabGroup with no
  children then sets its OWN height to `3 + borderoffset + 23 = 56`, leaving ~25px of nothing under
  the tabs. Auto-height is off and the row is `SUBTAB_H = 39` (24px tabs at y=-7 plus 8 of
  clearance); `browse_spec` pins both. Location: `Modules/UI/Requests.lua`.

- **BANKERS-FILTER-001 / LOG-FILTER-001: filter strips on the Bankers and Log tabs.** The operator:
  *"add some filters to the top of the bankers tab like the browse tab? at a minimum we need the
  search filter ... it might be nice to be able to provide metadata for each banker, on the types of
  stuff they store"* and *"the filter search bar add it to the top of the logs as well, we'll need
  to search, and filter by start/stop date, filter by from, by to as well."* Bankers: a search box
  over name, status and a new **Stores** column -- `Guild:BankerStores`, the banker's guild note
  with the `gbank` / view-only markers and the punctuation around them stripped ("gbank: herbs &
  potions" reads "herbs & potions"), so an officer sets it where the banker identity already lives
  and nothing new travels the wire; the note is now kept on `memberRoster` for bankers. Log: search
  (From, Action, Item, To), Since and Until as `YYYY-MM-DD` (`Browse:ParseDate`, day-inclusive,
  nonsense ignored), From and To dropdowns listing every name in the log. Both strips are
  `Browse:BuildSimpleStrip`, the Browse strip's shape at one row; the lists start under them.
  `guild_spec` (+2) and `browse_spec` (+2). NOT RUN IN GAME. Locations: `Modules/UI/Browse.lua`,
  `Modules/Guild.lua`.

- **LOG-FILTER-004: the Log tab's From / To dropdowns are removed.** The operator, in game with the
  From list forty names long: *"the from and to filters on the log tab are going to be too
  unweildly. as long as the name is searchable and filters through the search bar, we can probably
  get rid of these two dropdown filters."* The search box already matched the row's From and To
  names, so a name typed there was the filter all along; the dropdowns, `Browse:LogNames`,
  `Browse:FillLogNameDropdown` (LOG-FILTER-003b's re-fill on every draw) and the `from` / `to`
  fields of `logFilter` are deleted, the strip is search (wider, 260) + Since + Until, and the search
  box's placeholder and tooltip say a name goes there. `browse_spec`'s Log-strip example now filters
  by a requester's name, by two names together, by a banker's name matching on either side, and
  finds a name whose first entry landed after the tab opened -- with no list to keep in step.
  Location: `Modules/UI/Browse.lua`. (The ID skips 003: LOG-FILTER-003 is the calendar-click fix
  and 003b the dropdown re-fill this removes.)

- **RETENTION-001: requests are kept 14 days, not 30.** The operator: *"keep 14 days, should be
  enough to get it over to togtools for longer retention."* `REQUEST_LOG.EXPIRY_SECONDS` in
  `Modules/Constants.lua`. The Active/Archive split (`archiveDays`) is unchanged.

- **MAILUI-001: the Mailbox window -- the inbox as inventory.** The operator, from a Discord ask of
  2026-08-17 ("add a reskin of the mail box to work for bankers like TSM") and on 2026-09-11: *"the
  ability to open the mailbox, see all the attachments on the mail and handle them like inventory.
  TSM does a good job of that, providing rows for all the attachments to an email, and a search
  filter allowing you to narrow it down."*

  `Modules/UI/Mailbox.lua` (`TOGBankClassic_UI_Mailbox`): when a banker opens a mailbox, a window
  opens beside Blizzard's with ONE ROW PER ATTACHMENT across every mail (plus a row per mail that
  carries money) -- icon and name drawn by the same `DrawItem` the Inventory window uses (tooltip,
  quality border, shift-click link), count, sender, days left, a green `needed` when an open order
  to this banker still wants the item, red `COD` on cash-on-delivery rows. A filter box narrows the
  rows by item name or sender. `Take` on a row takes it; `Take Shown` takes every filtered row,
  highest mail index first (a taken mail renumbers those above it) with a pause between takes
  until `C_Mail.IsCommandPending` clears -- the same cadence as Blizzard's own Open All -- stopping
  at the first row it cannot take (COD, full bags) and saying why. `/togbank mailbox` opens it for
  anyone while a mailbox is open. Blizzard's frame is NOT replaced: no Send composer, no COD
  taking, no hiding `MailFrame` -- those stay Blizzard's, per the settled scope. `MAIL_INBOX_UPDATE`
  rebuilds the rows; `MAIL_CLOSED` closes the window and abandons a take in progress.

  Research that shaped it (bank #12321): TSM's Mailing UI was read from the installed addon,
  and its Send thread plus Era's own `OpenAllMailMixin` established that taking and sending from a
  timer is permitted (`SendMail` is `noscript`, not hardware-gated -- Peer Review round 19
  corrected). Not used yet: a timer-driven fulfil loop is the natural next step now that the
  premise is settled, but it was not asked for.

  `Tests/mailbox_spec.lua`: 14 examples on the harness's inbox model -- rows per attachment and
  per money mail, the `needed` mark (this banker's open orders only, not another banker's, not
  fully sent, not cancelled), COD carried and GM mail skipped, the filter, single takes, the
  take-all order and pacing (one per delay, waits on a pending command, stops on the first refusal
  with the count), re-entry refused, `StopTaking`, auto-open for bankers only, close-with-mailbox,
  both TOCs and the transparency-slider registration. **The window's AceGUI rendering
  (`DrawWindow` / `DrawContent`) is NOT specced** -- the offline env loads no AceGUI widgets -- and
  is stated as such in the spec header. NOT RUN IN GAME. Locations: `Modules/UI/Mailbox.lua`,
  `Modules/Events.lua`, `Modules/Chat.lua`, `Modules/UI.lua`, both TOCs, `.luacheckrc`
  (`C_Mail` and four `UI.lua` client globals that had been reported as undefined for as long as
  the file existed).

- **MAILUI-002: the Mailbox window rebuilt as mails, in the Guild Bank window's style.** The
  operator, 2026-09-12: *"we need some way to open this window. it pops open once the first time i
  open a mailbox, but then i can't get to it again. i want this to look more like our browse ui in
  look and feel, same zebra stripes, font, and one mail per row with however many items attached.
  i'd like to be able to click into the mail to see everything attached to the one mail ... the
  filter needs to update the rows and filter out the items so we only see the items on the rows that
  match the filter. last, the item needs to show the icon, name, hover over full game tooltip and
  the quantity."*

  `Modules/UI/Mailbox.lua` is now a `TOGBankClassic_UI_RowList` (the Browse window's zebra rows and
  fonts) under the same search box and Take Shown button. ONE ROW PER MAIL -- its first attachment's
  icon (the coin for a money-only mail), `> subject`, how many attachments, the sender, days left,
  `needed` when an open order to this banker wants something on it, `COD`. A left-click expands the
  mail (`v subject`) into one indented row per attachment: icon, the item's link, its count (the
  money row shows the coin text), and on hover the REAL inbox tooltip --
  `GameTooltip:SetInboxItem(mailIndex, attachmentIndex)`, the call Blizzard's own inbox makes
  (`MailFrame.xml:235`). A mail row's tooltip lists every attachment on it. `Mailbox:BuildMails`
  groups `BuildRows` by mail (a mail's money rides as its last attachment, so the take sequencer and
  Take Shown work on either view); `FilterMails` keeps every attachment of a mail whose sender or
  subject matches and ONLY the matching attachments otherwise, on copies -- never the inbox rows;
  `ViewRows` renders mails plus the expanded ones' attachments; no column is sortable, because a
  header sort would separate a mail from its rows. Right-click takes: an attachment row takes that
  one, a mail row takes everything on it, Take Shown takes what the filter left. Reopenable at any
  time the mailbox is open: a `TOG Bank` button (`UIPanelButtonTemplate`, 80x22) on Blizzard's
  `InboxFrame` at TOPRIGHT -14,-46 -- the free band under the panel's close button and above
  `MailItem1` (TOPLEFT 13,-70); Open All at CENTER BOTTOM -21,114 has the page arrows either side of
  it -- created once at the first MAIL_SHOW for everyone (the auto-open stays bankers-only), plus
  `/togbank mailbox`. Expansion is forgotten when the window closes. Both TOCs now load
  `Mailbox.lua` after `RowList.lua`.

  `Tests/mailbox_spec.lua`: +16 examples. The data half on the harness's inbox model (mails and their
  attachments, text-only and GM mails skipped, a sender/subject match keeps everything, an item
  match keeps only it -- proven red first -- nothing mutated, view rows collapsed and expanded, the
  flags); the window half on the REAL AceGUI widgets and `env.frames` (the list under the strip,
  expand and collapse by click, the filter narrowing both levels live, right-click takes on an item
  and on a mail in the sequencer's order, Take Shown on the filtered set, `SetInboxItem` asked with
  the right indices and the money and mail tooltips, the inbox button placed once and toggling,
  refusals reported, the empty inbox, expansion cleared on close). `Modules/UI/Mailbox.lua` at 100 %
  line coverage. NOT RUN IN GAME. Locations: `Modules/UI/Mailbox.lua`, both TOCs.

- **SEARCH-005: search boxes under the Requests columns, and ONE search box for the addon, built on
  LibAceGUIWidgets.** The operator, from a Discord ask of 2026-08-19 ("add search on requestors to
  find someone easily") and on 2026-09-11: *"we need to add a search bar to each column in the
  request tab. we should use the search bar look with the icon from libaceGUIwidgets for it, maybe
  even plumb the library in now ... now might be a good time to centralize the layout/look."*

  **The library is plumbed in.** `LibAceGUIWidgets-1.0` -- the TOG suite's shared toolkit (Dibs,
  FastGuildInvite) -- is a declared dependency in both TOCs and `.pkgmeta` (`libaceguiwidgets`),
  the same shape as ItemDB and DeltaSync. Its `CreateSearchBox` is Blizzard's own
  `SearchBoxTemplate` (magnifier, greyed placeholder, clear-X; the template is in Era's
  `Blizzard_SharedXML/Shared/InputBox/InputBoxTemplates.xml`), and its `SearchMatch` is the
  tokenised, case-insensitive "every word appears somewhere" rule.

  **One widget, three windows.** `Modules/UI.lua` registers `TOGBankSearchBox`, an AceGUI widget
  type wrapping the library's raw box so it drops into a Table or Flow layout like any other
  widget, with AceGUI's EditBox contract: `SetText` is silent, the user's typing fires
  `OnTextChanged` with the text, and the clear-X reports its clear from the button's own click
  (Era's `SearchBoxTemplate_ClearText` is a programmatic `SetText("")`, which the text hook rightly
  ignores -- Peer Review on the self-audit), `OnEnterPressed`, `SetPlaceholder`, focus passthrough.
  `TOGBankClassic_UI:SearchMatch` fronts the library's matcher. Both are feature-detected against
  an older library copy (the two are MINOR 9): the box is then built from the same template
  directly and the matcher degrades to a substring test -- never to no filter. The Search window's
  "Item Name" EditBox-with-a-label and the Mailbox window's filter box are now this widget; the
  Search window's placeholder carries the 3-letter rule its old label tooltip did.

  **Requests: a box under Date, Requester, Bank and Item.** A second header row in the column
  table, filling the `FilterWidgets` slot that `DrawHeader` had sized per column since the window
  was written and nothing had ever populated. Each box searches the text ITS column shows (the
  formatted date, the names, the item's display name -- `Requests:ColumnText`), every box must
  match for a row to show (`Requests:ColumnSearchMatches`, a pure function over a request and the
  column queries), and they narrow on top of the Requester / Bank dropdowns, which keep their
  me / open / history sections and counts. The queries survive a window rebuild (banker status
  change) and are written back into the new boxes. An empty list behind a search or filter now
  says "No requests match the search or filters." rather than "No requests yet." **Not under `#`,
  `Sent` or `Actions`:** at 50-70 px a box cannot show its magnifier, and a number or a button row
  is not something to search -- the operator said "each column"; this is the deliberate reading,
  stated so it can be overruled.

  `Tests/searchbox_spec.lua`: 17 examples against the REAL library and the REAL AceGUI-3.0 on the
  harness's rich widget layer -- the type registers; the box is the template's (magnifier,
  placeholder); placeholder set and reset; SetText silent, typing fires, the clear-X fires with
  "", a non-user change that leaves text does not; OnEnterPressed and focus; acquire/release
  reset; SearchMatch through the library and its fallback; the Requests column text, the
  every-column-must-match rule, `SetColumnSearch` trimming/clearing/paging, `ApplyFilters` on top
  of the bank filter, and exactly four columns carrying a box. NOT COVERED: the rendering of the
  boxes inside the three windows (no AceGUI widget files load offline). NOT RUN IN GAME. Also
  `SEARCH` (the template's instruction-text global) added to `.luacheckrc` and `.luarc.json`.
  Locations: `Modules/UI.lua`, `Modules/UI/Requests.lua`, `Modules/UI/Search.lua`,
  `Modules/UI/Mailbox.lua`, both TOCs, `.pkgmeta`.

- **LOGAPI-002: bank movements are pushed into TOGTools' Guild Bank Log.** TOGTools' contract
  (its `docs/DEPENDENCY_CONTRACTS.md` section 1, raised 2026-08-18, delivered to this inbox
  2026-09-11): Classic Era has no guild bank, so TOGTools' Guild Bank sub-tab is empty there by
  construction, and the operator decided on the TOGTools side that *"TOGBankClassic PUSHES into
  GuildBankLog:InjectEntry"* -- this addon owns its schema, TOGTools stays a passive receiver that
  stores. Which is LOGAPI-001's own shape from the other end.

  `Modules/Log.lua`'s delivery now also pushes every bank-CONTENTS entry -- `deposit` / `withdraw`
  as `kind = "item"` with an item link (the client's when cached, else a synthetic one carrying the
  id and random suffix so TOGTools' derived `itemSig` tells variants apart), the two money types as
  `kind = "money"` -- to `TOGTools.addon.logCategories["guildbank"]:InjectEntry(guildKey, row)`,
  under TOGTools' own guild key (`GetCurrentGuildKey`, or the same `Guild-Realm` shape built here),
  stamped with the author's absolute publish time. **`occ` is passed, and it is that publish time**
  -- TOGTools' correction on the thread: its dedupe is (base tuple + occ) with `ts` and `name`
  outside the tuple, and with `occ` omitted it assigns the next ordinal BEFORE the check, so a
  viewer alt on the same account re-injecting the banker's identical row would have been stored
  twice. Every client records the same entry from the same version transition with the author's
  time, so that time is identical everywhere and different per version: the same row again comes
  back `"duplicate"` (logged at debug -- it is the expected answer for a viewer), a same-tuple row
  in a later version is stored. Stated caveat: TOGTools' `itemSig` is derived from the link, so two
  suffix variants of one item moved by the same count in one version share a tuple and an occ.
  **Every row carries `source = "TOGB"`** (`Log.SOURCE_TAG`) -- the operator, 2026-09-11:
  TOGTools' log *"needs to do native AND addon bank, we just need to tag TOGBANK transactions
  appropriately. TBH, we should do that regardless, so it's apparent"*, and on the length: *"thats
  a lot of text per line, maybe something like [TOGB]"*. TOGTools copies every field, so the tag
  rides with the row; rendering it as `[TOGB]` is asked of TOGTools. Request entries are not pushed: a `mailed`
  fulfilment is already the `withdraw` the banker's next version records. Guarded on exactly what
  the contract names; `"disabled"` (the user switched that log off) stops the batch and is not an
  error; the push runs in its own `pcall` so TOGTools raising cannot silence another consumer.
  TOGTools is `## OptionalDeps` in both TOCs -- never required. Pushed on BOTH flavours: the
  contract's "only where the native bank does not exist" guards against a transaction both sides
  see, and this addon never sees a real guild-bank transaction (it scans bank CHARACTERS), so on TBC
  its rows are movements the native capture cannot see, not duplicates -- said in the contract
  reply so TOGTools can object.

  `Tests/togtoolsbridge_spec.lua`: 12 examples against a fake receiver built to the documented
  contract (the codes, the copy, and the ordinal-before-dedupe rule TOGTools described) -- stated
  as a fake, because TOGTools is an addon, not a library the harness loads: the lookup path and its
  three wrong spellings, the guild key and its fallback, the item/money mapping with `occ` and the
  `source` tag, request types not pushed, the suffix in the link, a batch pushed under the key, the
  identical row stored once and a later version stored again, `disabled` stopping the batch,
  absence and no-key without a call, the real feed landing
  after the coalescing timer, a raising receiver not taking the other consumers down, and both
  TOCs listing TOGTools as optional only. NOT RUN IN GAME: the verification is the contract's own
  -- one row, then Logs > Guild Bank on an Era character. Location: `Modules/Log.lua`, both TOCs.

- **LOGAPI-001: the bank log -- a transaction feed for other addons.** The operator, 2026-08-17:
  *"create a 'log' API to allow TOGTools to pull data for the bank log"*; on the shape, 2026-09-11:
  *"it should work like the in game bank log"*, and on storage: *"the log can't persist, i don't
  want to use SV space on it, why it needs to integrate with TOGTools, who will persist it."*

  `TOGBankClassic_Log` (`Modules/Log.lua`, loaded after `RequestLog.lua` in both TOCs) is a
  read-only, versioned surface (`API_VERSION = 1`) shaped like `GetGuildBankTransaction`: one
  entry per thing that happened, newest first -- `deposit` / `withdraw` / `money-deposit` /
  `money-withdraw` per banker, and `requested` / `mailed` / `handed` / `cancelled` / `reopened`
  per request. **Nothing is persisted.** Entries are pushed to consumers registered with
  `Log:RegisterCallback(owner, fn)` in coalesced batches (0.2 s, each consumer gets its own
  copies, each callback runs under `pcall` so one consumer's bug cannot silence another), and
  also fired as the AceEvent message `TOGBANK_LOG_CHANGED`; a capped (500) in-memory buffer
  (`Log:GetEntries{ since, limit, types, bank, player }`) lets a consumer that registers late catch
  up on the session. `Log:GetBankers()` lists the bankers with number, last-scan time and tab
  state. The consumer is the one that stores.

  **Where entries come from** -- every client records the same entries from the same transitions,
  so the log agrees across the guild with no wire change. Bank contents: every new VERSION of a
  bank (the banker's own scan in `Bank.lua`, or a delivery a viewer receives in `Chat.lua`) is
  diffed against the version held before it, stamped with the author's publish time; the first
  version held records nothing (a fresh install is not a deposit of everything), and an unchanged
  rescan records nothing. Requests: every mutation in `RequestLog.lua`, local or received, is a
  transition from the record held before to the record after, so a mutation applied twice (our own
  broadcast echoed back) records nothing the second time; `reopened` is decided on the state
  transition (done -> open), not on a timestamp rising, so a reopen inside the same server second
  as the cancel it undoes still logs.

  **Span fields (self-audit F4/F5, Peer Review's shape).** Every bank-contents entry carries
  `fromCanon` / `toCanon` -- the versions diffed from and to -- so a reader can tell a span from a
  step: a delivery that decoded with dropped rows is stored but never logged (a possibly-wrong diff
  is worse than none), and the next clean entry's `fromCanon` then differs from the previous
  `toCanon`, which says "net change across a missed version" without fabricating the intermediate.
  The first diff for a banker since login carries `firstThisSession = true`: its "before" is the
  copy held when this client last looked, so a consumer renders it as "since you last looked"
  rather than a deposit at that instant. Two examples pin the chaining and the once-per-banker mark.

  **Consumer contract worth reading before registering:** callbacks run from a timer, never from a
  hardware event -- anything the client gates on a click (`SendMail`, chat, taking mail) is
  `ADDON_ACTION_BLOCKED` inside one (peer review round 19).

  `Tests/logapi_spec.lua`: 24 examples across request transactions (placed, every fill its own
  transaction, by-name mail path, cancel with reason and reopen, received-once/echo-never,
  placeholder names resolved per NAME-001), bank transactions (diff, first-version silence, suffix
  variants in both row shapes, the RECEIVED path through a real `togbank-d4` delivery, the banker's
  OWN scan through `Bank:Scan`), reading and filtering, persistence (asserts no SavedVariables
  field carries it), the feed (coalescing, per-consumer copies, AceEvent message, a throwing
  consumer, re-registration) and shipping (both TOCs, after RequestLog). Whole-client examples
  needed `env.now` set -- the harness's `GetServerTime()` is 0 until it is, and a scan stamps that
  as its publish time -- and `env_togbank.lua`'s Options stub gained `GetAutoTombstoneDays`, which
  `mergeRequest` reads once the clock is non-zero. NOT RUN IN GAME.

- **`/togbank dev trace <banker>` -- one banker through every P2P gate.** Peer Review's P2P-035
  follow-up: `sendqueue`'s sibling. Serving side, in the order `HandleSyncRequest` asks: on the
  roster (and its number), record held with legacy-row and V2-tuple counts and `HasAltContent`,
  `CanServe`, `ServableCanon` with the held canon and publish time, the send-slot count and any
  queue entry for the alt, and any open state-wait -- stopping with `STOP:` and the reason at the
  first gate that says no (legacy-only content names the remedy: only the banker's rescan fills
  the V2 store). Fetching side: `GetAltStaleness`, the newest advertised canon with the
  `AdvertisedImproves` verdict and reason, `IsAltSyncPending`, and the live session with the
  version its request names. Every line calls the production predicate itself, never a copy
  (the HASH-REV-002 / DOC-005 class). Five examples in `Tests/trace_spec.lua` on a whole client;
  documented in `docs/DEV_COMMANDS.md`. Location: `Modules/Chat.lua`.

### Bug Fixes

<!-- MOVED-TO-ARCHIVE 2026-09-13 (later): the next oldest Bug Fixes (WIRE-SKEW-001/002,
     CANON-TIME-001, MULTIPC-003, RAID-VISIBILITY-001, DOC-007, CLAIM-TRACE-001, WIRE-SKEW-008,
     WIRE-SKEW-007, WIRE-SKEW-006, WIRE-SKEW-005) moved byte for byte to the same archive heading,
     ahead of the five that went this morning: the live file was 588 characters from the 120k
     working ceiling after today's entries, and the rule is to keep real headroom. -->

<!-- MOVED-TO-ARCHIVE 2026-09-13 (evening): the next seven oldest Bug Fixes (RAID-CONSULT-001,
     HIDDEN-TEXT-001, LOG-HYGIENE-002 F3, STALE-REQ-001, LOG-WIPE-001, MAILUI-003, STATUSBAR-005)
     moved byte for byte to the same archive heading, ahead of the ten above: the live file was at
     107.6k with five entries written that session. -->

- **DEFERRED-LINE-001: a bank scan the publish gate holds is now visible on the status bar.** The
  operator, testing the hide/show share after a relog: *"hiding/unhiding and now it doesn't show up
  immediately like it did before."* Read: the propagation line only starts at the MINT
  (`MintVersion` -> `Propagation:OnPublished`), and a scan the MULTIPC-001 gate defers -- inside the
  login consult window (~65 s after a login or /reload), while another PC's publish is newer and a
  source is not re-read, or while the newer copy is fetched as the diff base -- mints nothing until
  the gate opens or the 180-second fallback fires. For that whole wait the bar was empty, so a
  deferred hide read as a hide that did nothing. Now `Bank:DeferPublish` (the one place a hold is
  recorded, replacing three inline sites) stamps `since` and `why`, and the bar's centre shows an
  amber **"Bank update stored, not published yet -- waiting for the guild to answer, stay online
  (0:12)"** (or *"open your bank and a mailbox to publish it"* for a stale-source hold) from the
  first tick of the hold, ahead of the tracker's line, counted as urgent for the narrow-bar rule,
  gone the moment the mint clears it. Whether the operator's hide was inside the consult window or
  the consult never settled (HIDE-SYNC-002, open) is what the line now tells them without a trace
  command. `Tests/propagation_spec.lua` (the line, both reasons, precedence, clearing) and
  `Tests/multipc_spec.lua` (the real deferred scan carries `why` and `since`). Locations:
  `Modules/Bank.lua`, `Modules/UI/StatusBar.lua`.

- **DEFER-PERSIST-001: a held bank update survives a reload.** The operator, with the amber
  "stored, not published yet" line up and a /reload: *"still not living through reload, you need
  to save it to SV when you 'start' it and record if someone answers it ... you can clear it and
  remove it from sv when it's filled."* PROP-PERSIST-001 saved only a MINTED update; a scan the
  publish gate was holding was session state, so a reload during the wait lost the before-images
  (the log diff and the chain link for that version) and the wait itself -- and the next login's
  scan, finding the store already holding the hidden state, had nothing to publish until the bags
  changed again. Now `Bank:DeferPublish` writes the hold to `db.char.deferredPublish` the moment
  it starts (who, when, why, the parent canon and a copy of its records), `Bank:RestoreDeferred`
  brings it back at `Guild:Init` after the record loads -- only while the held canon is still the
  parent it was diffing from, otherwise dropped -- re-arms the 180 s net, and the mint clears the
  save. The amber line therefore comes back after a reload with its original clock, and the
  restored hold publishes the moment the new session's consult settles. `Tests/multipc_spec.lua`
  x2 (the round trip, the stale-parent drop and the not-yet-loaded leave-alone). In game: *"defer
  persist- works through reload now"*. Two more found on the way: a later scan minting over a
  waiting hold used ITS OWN before-images and threw the hold's away (the held change would have
  missed the log and the chain link) -- the hold's win now; and **DEFER-CLOCK-001**, the operator's
  next ask (*"if i do a hide, and wait 10 secs, then do an UNHIDE it should be a new hash so ensure
  it is a new hash and start the timer over on the NEW HASH"*): every change landing on a hold
  restarts its clock, including the unhide that puts the contents back where the published version
  had them (Scan's "no changes" branch -- which also used to drop the share the hide had asked for,
  so the eventual mint went out unannounced); the mint that ends the hold is a new canon either way.
  `Tests/multipc_spec.lua`. Locations: `Modules/Bank.lua`, `Modules/Guild.lua`.

- **BREATH-001: the "stay online" line breathes.** The operator: *"it's in the status bar, but can
  you make it 'breath' as well? Also, open a request with the aceGUIwidgets library to add the
  breath function to it so it's available for any addon that uses it."* The centre text now sits
  on a frame of its own whose alpha breathes while the line is urgent (pending, alone, or a held
  publish) and is on the bar; a green or empty centre, and hover content, sit still at full alpha.
  The breath is **LibAceGUIWidgets' `W:Breathe` / `W:StopBreathing`** (MINOR 28, built for this
  ask on inbox thread 370504bb -- defaults 0.35 over 1.0 s, BOUNCE, eased), and the addon's other
  two copies of the same animation -- the cancelled date's glow (`Requests.lua`) and the Guild Bank
  window's help icon (`Browse.lua`) -- are lifted onto the same call, so the three hand-built
  AnimationGroups and their duplicated constants are gone. `Tests/statusbaryield_spec.lua`,
  `browse_spec`, `searchbox_spec`. NOT RUN IN GAME. Locations: `Modules/UI/StatusBar.lua`,
  `Modules/UI/Requests.lua`, `Modules/UI/Browse.lua`.

- **LOG-FILTER-002: Since / Until are date pickers.** The operator, on the typed boxes: *"we need
  the since and until to be date pickers."* LibAceGUIWidgets had none (its widget registrations
  read); per the standing rule the widget was requested there (thread 3ecad6a6) and delivered the
  same hour as `LAGW-DatePicker` (MINOR 28): a field that opens a month calendar, typing still
  accepted, value a local-midnight timestamp or nil. The Log strip builds it when the library
  registers the type and keeps the typed box otherwise; the filter holds the timestamp;
  `Browse:ParseDate` passes numbers through and hands text to the library's own `DatePicker.parse`
  -- one spelling of "what is a date" -- with the addon's rule kept only behind the no-parser
  fallback. A typed time is dropped: the filter is by day. `browse_spec` loads the widget's satellite
  file after `libs.load` until the harness manifest carries it (WoWAPITesting thread 1a7caf76).
  NOT RUN IN GAME (the calendar glyph's Era fallback branch is the operator's check). Location:
  `Modules/UI/Browse.lua`.

- **LOG-FILTER-003: a click in the Since / Until field opens the calendar.** The operator, with a
  screenshot of the strip (glyph and arrow rendering): *"the date pickers look good, but they don't
  actually have a date picker dropdown."* The library's widget opens its calendar from the 20px
  arrow BUTTON only; a click in the 110px field takes focus for typing and shows nothing -- and this
  addon's tooltip said "click the field for a calendar". Asked of LibAceGUIWidgets (thread
  bb9c59be4d68) and delivered within the minute, still under MINOR 28: a mouse-down in the field
  opens the calendar (opens only, never toggles, so a second click does not close it under the
  caret; the arrow keeps its toggle; typing still works with it open). A one-line stand-in hook
  here lived for a few minutes and came out with the delivery. The tooltip says "field or its
  arrow"; `browse_spec` drives the field's script and the arrow's from the consumer's side, because
  the tooltip promises it. NOT SEEN IN GAME -- and whether the ARROW opens anything on Era is
  unmeasured either way; the in-game item says what to report. Location: `Modules/UI/Browse.lua`.

- **LOG-FILTER-003b (self-audit 9bce8d86 F2): the Log tab's From / To lists follow the log.** They
  were filled once when the strip was built, so a name whose first entry landed after the tab
  opened was absent until the tab was rebuilt. One filler (`Browse:FillLogNameDropdown`) at build
  and on every draw, re-setting the list only when the name set moved and keeping the pick.
  `browse_spec`. Location: `Modules/UI/Browse.lua`.

- **HIDDEN-MERGE-001 (self-audit 5476e257 F2, Peer Review db06c629): the banker's own hidden rows
  are merged in ONE place.** The Inventory window's own tab (HIDE-001) and the Browse tab (HIDE-003)
  each spelled the same twelve lines -- own bank only, `GetAltHiddenView` appended to the visible
  view -- and nothing asserted they agreed. `Guild:GetAltItemsWithOwnHidden(alt)` is the one site:
  `GetAltItems` plus the hidden rows when the alt is the player's own bank, a fresh array when it
  merges (the store's cached view is never appended to in place), the same table otherwise. Both
  windows read it; `hideitems_spec` pins that neither window, nor Search, tooltips or Mail, reads
  the hidden view itself, and drives the accessor on the real module (own bank, another banker, a
  non-banker's own name); `browse_spec` lifts the real method onto its steerable Guild stub so the
  merge under test is the shipped one. Half (a) of the same finding, the words, shipped earlier as
  HIDDEN-TEXT-001. Locations: `Modules/Guild.lua`, `Modules/UI/Inventory.lua`, `Modules/UI/Browse.lua`.

- **WINDOW-PERSIST-002: every window persists through one spelling.** The Inventory, Search,
  Requests and Browse windows each carried their own status-table setup and a `SetResizeBounds`
  beside it (Requests with a `SetMinResize` fallback, Browse with the BROWSE-007 floor clamp, the
  other two with none); the Mailbox window alone went through `UI:PersistWindow` -> the library's
  `W:PersistWindow`. All five do now, one call each: position, size, the default, the floor applied
  to a saved size and to the drag. Behaviour change, stated: Inventory, Search and Requests gain the
  saved-size-under-the-floor clamp Browse and Mailbox already had. `mailbox_spec` pins the source
  property (every window file calls it; none spells `SetStatusTable` or `SetResizeBounds`);
  `browsepersist_spec`'s thirteen examples pass unchanged on the library path. Locations:
  `Modules/UI/Inventory.lua`, `Modules/UI/Search.lua`, `Modules/UI/Requests.lua`,
  `Modules/UI/Browse.lua`, `Modules/UI.lua`.

- **LOG-MAIL-001: a mail sitting in the banker's inbox is nobody's deposit; taking it is.** The
  operator, with the Log tab beside the Mailbox window: *"the log should only show the 'deposit'
  when it's taken from the mail, not when it's scanned in the inbox. it may sit there and be sent
  back."* The log was a diff of two full record sets -- bags + bank + the inbox rows -- on every
  client, so an attachment that arrived logged "deposited ... from Meguck" the moment the banker
  opened the mailbox, on the banker and on every viewer, and a mail returned unopened then logged a
  withdrawal. Three things changed, each the smallest that satisfies the rule on EVERY client:
  (1) THE LOG IS THE AUTHOR'S STATEMENT. `Bank:MintVersion` computes the entries once, over what the
  banker HOLDS (`Store:GetAltHeldRecords`: bags + bank, never mail -- `Log:DiffEntries`), packs them
  (`Log:PackEntries`, one letter per field) into the chain link (`delta.log`) and into the snapshot
  (Wire field 9, `Chain:WireLogs`: the window's links' entries), and every receiver appends them
  verbatim (`Log:RecordEntries` per link in `ReceiveChain`; `Log:ApplyWireLogs` for a snapshot,
  every link published after the version held). No receiver diffs record sets any more -- "viewers
  never derive" (docs/DELTA_RELEASE.md step 4) is now literally true; a snapshot with no log window
  logs nothing, which is coarser and never a deposit that did not happen -- and that is the ORDINARY
  case behind a relay, not an edge: a relay that itself took a snapshot cleared its chain
  (`ReceiveSnapshot`), so it serves NO log rows for that bank to anyone it snapshots until it next
  receives a chain (Peer Review on 6f421e806c84). Likewise every link written before v1.5.0 carries
  no `log`, so a viewer applying one of those logs nothing for that version -- one-time, at upgrade.
  Remedy for the relay case when it matters: keep a received snapshot's log window as chain
  metadata so it re-serves; not built. (2) A TAKE IS A VERSION.
  Mail -> bags leaves the merged set, and so the content hash, exactly as it was, so the scan's change
  gate also hashes the held set (`alt.heldContentHash`, local metadata): the take mints a new canon --
  same content half, new publish time -- whose link carries the deposit and no row changes, and every
  viewer applies it. One version bump on the first scan after this update (the held hash is nil until
  then). (3) THE SENDER IS KNOWN FROM THE READ BEFORE THE TAKE. `MailInventory:NoteInbox` runs on every
  `MAIL_INBOX_UPDATE` and records what LEFT the inbox since the previous read (`TakenSenders`, spent by
  the mint); a returned or expired mail while the mailbox is closed is not observed and not a take.
  KNOWN COSTS, stated: a MULTIPC-002 publish diffs full sets (the fetched base has no source split);
  an attachment returned to its sender while the mailbox was open is a take candidate, capped by the
  held rise (Log.lua says so); the held hash is a second hash per scan. Pinned: `fullsync_spec` (the
  arrival is a version and no deposit on banker or viewer; the take is one deposit naming the sender
  on both, through the link -- and, read off the bytes the bus delivered, that link's body decodes to
  an EMPTY `changes` table, not nil, which is the difference between DeltaSync's no-op and its
  refusal at `DeltaOperations.lua:518`; the viewer applied it with no snapshot fallback), `logapi_spec` (pack/unpack with garbage dropped, the snapshot window
  against the held version, the taken-sender memory across reads, COD and a close; a delivery with a
  log window logs the author's rows and one without logs nothing), `store_spec` (the held set).
  Locations: `Modules/Log.lua`, `Modules/Bank.lua`, `Modules/MailInventory.lua`, `Modules/Events.lua`,
  `Modules/Inventory/Store.lua`, `Modules/Inventory/Chain.lua`, `Modules/Inventory/Wire.lua`,
  `Modules/Inventory/Sync.lua`.

- **TAB-STATE-003 (Peer Review 498a84f3 F3): a third, GREY state -- "Newer copy unreachable".**
  WIRE-SKEW-008 drops every claim from a peer that cannot complete the data leg, so a bank whose
  ONLY newer holder is an old-release client read "Current" -- true of what could be fetched,
  false of what exists. `Guild:NoteRefusedNewer` (called where NoteAdvertisedPublishTime drops
  the claim) keeps the newest such claim per banker (peer, version, publish time), session-scoped
  beside `newerOfferedBy`; `GetAltStaleness` answers `"refused"` LAST, so red (a capable claim of
  the same or newer -- which also drops the record) and yellow-on-delivery (the compare retires it
  once the held canon catches up) both win over it; never for our own name or a non-banker. Bankers
  tab: grey "Newer copy unreachable" with a hover; Inventory window: grey tab text and a tooltip --
  one sentence, `Browse.RefusedText`, naming the peer and its version. No wire. Pinned in
  `wireskew_spec` (grey with peer+version; capable claim -> red, record gone; older refused claim
  ignored; newest kept; catches up -> current; own name / non-banker never) and `browse_spec` (the
  row, the hover on the grey row only). Locations: `Modules/Guild.lua`, `Modules/UI/Browse.lua`,
  `Modules/UI/Inventory.lua`.

- **ONLINE-COL-001 (Peer Review bee7f23f F1): a connected-realm banker going offline repaints the
  Online column.** An offline update matches by BASE name across realm variants (the system message
  carries no realm), so the name it normalises to can be a realm the banker is not on -- and the
  BROWSE-008 gate (`IsBank(normalized)`) skipped the before/after snapshot, so "yes" stayed. Offline
  updates always take the snapshot now (rare, one per system message); the per-message online path
  keeps its banker-only gate. Location: `Modules/Guild.lua`.

- **HANDSHAKE-001 (Peer Review c6819531 F2): every handshake message goes out through one function,
  at one priority.** The `togbank-rr` prefix and the ALERT priority were twelve literals across
  `P2PSession.lua` plus two in `Inventory/Sync.lua`, and two of them had drifted to NORMAL -- the
  queue-drain "content went away" busy and the queued-elsewhere cancel -- so one path in six ran at
  a different priority than P2P-031 set, which is exactly the kind of thing a sync investigation
  cannot see. `P2P:SendHandshake(to, message)` serialises and sends; no call site names a prefix or
  a priority, and the P2P-031 comment that counted "the eight sites" (it was twelve) is gone with the
  count. Sync's CHAIN-004 refusal and SYNCED-001 receipt go through it too. `Chat.lua`'s protocol
  table now says ALERT for the prefix, lists every message on it, and carries the CHAIN-004
  capacity-refusal exception beside the "capacity queues, never refuses" rule it excepts. Locations:
  `Modules/P2PSession.lua`, `Modules/Inventory/Sync.lua`, `Modules/Chat.lua`.

- **DEV-VERSION-001 (Peer Review c6819531 F3): only a dev build reads as a dev build.**
  `EncodeVersion` answers 0 for `@project-version@` and for garbage alike, and every 0 was read as
  "dev, capable": an unparseable claim ("?", "unknown") from VersionCheck or a broadcast outranked a
  real v1.4.1 claim from the other source in `ObservedAddonVersion` and passed the data-leg gate --
  and in `RememberPeerAddonVersion` it skipped the newer-wins guard and overwrote a remembered real
  version. `Guild.IsDevVersion(raw)` is the one predicate (`@project-version@`, `dev`); a claim that
  is neither dev nor a version is dropped, not ranked, not remembered, and a peer whose only claim
  is garbage reads as unknown -- capable, but not "dev". Three examples in `Tests/wireskew_spec.lua`.
  Location: `Modules/Guild.lua`.

- **GLYPH-001: no glyph the game font cannot draw.** The operator, with a screenshot of the Fulfill
  Oldest tooltip: *"the emoji fonts you're using aren't in game, you either need to remove them, or
  you need to add the fonts"* -- its `select -> split -> attach -> send` arrows rendered as empty
  boxes. Removed rather than bundled: the arrows (tooltip), the check mark / warning sign / `>=`
  in the delta-sync status line, and the `->` in the memory line and a dispatch debug line are
  ASCII now. Em dashes, bullets and the ellipsis stay: the bullet is Blizzard's own range dot
  (`Blizzard_ActionBar/Shared/Localization.lua`, `RANGE_INDICATOR`); the dash and ellipsis are
  unproven -- if one ever renders as a box, it goes ASCII too. Locations: `Modules/UI/Requests.lua`,
  `Modules/Chat.lua`, `Modules/Performance.lua`, `Modules/P2PSession.lua`. The fleet-wide half
  (contract b7f9981a) landed the same day: LibAceGUIWidgets MINOR 28 ships `Fonts/DejaVuSans.ttf`,
  `W.SymbolFont` / `W.SymbolFontSmall` and `W:Symbol(name)` (nil for an unknown name, so
  `W:Symbol("check") or "[OK]"` is the feature-detect). Nothing in this addon uses it yet: all four
  GLYPH-001 sites are tooltip or chat lines, which the client draws with its own font, and the
  library confirms neither can carry a second font per line. The first owned FontString that wants
  a symbol uses the library's font object rather than a bundled one.

- **MAILBOX-PERSIST-001: the Mailbox window remembers its place and size.** The operator: *"ensure
  the mail inbox window saves size/position and persists through reload and open/close like the
  main window. use the same helper from the GUI library, and if ... there isn't one, we need to
  ... open a contract with the library."* The library had none (ApplyResizeBounds / MakeResizable
  cover the bounds, nothing the save); requested (thread 3ba9f0f7) and delivered the same hour as
  `W:PersistWindow(widget, table, opts)` (MINOR 28). `TOGBankClassic_UI:PersistWindow(window, key,
  defW, defH, minW, minH)` is the addon's one wrapper -- it resolves `db.char.framePositions[key]`,
  which the library cannot know, and hands it over; the Mailbox window is the first call site
  (560x480, floor 420x300). The Inventory, Search, Requests and Browse windows still carry their
  own `SetStatusTable` lines and move to this next. `Tests/mailbox_spec.lua`. NOT RUN IN GAME.
  Locations: `Modules/UI.lua`, `Modules/UI/Mailbox.lua`.

- **HARNESS: WoWAPITesting `1211a3a` adopted (own commit `241609f`).** `string.format("%d")` now
  raises past 2^31 offline as the client does -- 1607 examples green on the new pin, so no
  REQUESTS-ROWLIST-002-class site remains in production code; `EditBox:SetHighlightColor` is real,
  so the copy overlay's guard in `Requests.lua` is gone and `browse_spec` asserts the colour. Still
  to lift: the private send-slot and cursor models in `multifill_spec` / `bankcollect_spec` onto
  the harness's `wow.cursor` (field names `count`/`link`/`slots`).

- **HARNESS: WoWAPITesting `ea9ad8d` (own commit `79208b1`) and `55b0c88` (own commit `b135a38`)
  adopted.** `ea9ad8d`: the offline anchor solver keeps `SetHeight` on a `TOPLEFT + RIGHT` child --
  every AceGUI full-width strip used to stretch to the anchor's centre offline (336px for a 70px
  strip), and two `browse_spec` examples that pinned a height around that came out; the contract was
  filed from here with the probe numbers. `55b0c88`: `C_Container.UseContainerItem` on a bank slot
  with the bank open (`wow.bankOpen`, `wow.bankAutoStack`), the move `bankcollect_spec`'s private
  container model exists for -- and `multifill_spec` was lifted onto the harness's real send slots
  and cursor in the same round (`env.useHarnessBags()` hands the harness's `C_Container` back, since
  `env_togbank` replaces it with its own bag readers). `bankcollect_spec` keeps its model on ONE
  condition now: the harness's drop-onto-a-different-item swap leaves the displaced stack on the
  cursor, COLLECT-002's code and our fixture have it return to the origin slot, and neither side has
  measured the client (the harness's comment now says so, after we caught it citing our fixture for
  the opposite rule). The operator's in-game BANKFILL swap reading settles it.

- **REQUESTS-TIDY (self-audits 1ebe87b4 F2/F6, 9bce8d86 F3, 7043ef4b F3): four "same thing, two
  spellings" items in the Requests tab and the Guild Bank strips, all offline.** (1) The Requests
  body sorted its rows (`SortedRequests`, by `sortColumn`/`sortDirection`) and the RowList then
  sorted the same rows again by its own key -- one redundant `table.sort` of up to ~1,700 entries on
  every draw. `AllRequests` hands them over unordered; `GetTabFiltered` (was
  `GetSortedTabFiltered`) caches on the tab alone; `valueForSort` is gone. The body still remembers
  the clicked sort for the list's `SetSort` on a rebuild. (2) `lockRowHighlight` was defined after
  `newActionIcon`, which carried the same four lines inline; the helper moved above and the icons
  call it. (3) `isComplete` already reads the cancelled/complete/fulfilled statuses, and
  `staleRequesterVersion` re-spelled them beside it; one predicate now. (4) `Browse:BuildFilterStrip`
  set up the same `SimpleGroup` `BuildSimpleStrip` does, by hand; it calls
  `BuildSimpleStrip(columns, STRIP_H)` now (the height is the parameter). `FILTER_INSET = 8` lived
  in Browse.lua AND Requests.lua with a comment saying they matched: it is `UI.FILTER_INSET`, one
  number, and `browse_spec` measures both strips' insets equal and refuses either file its own
  literal. Locations: `Modules/UI.lua`, `Modules/UI/Browse.lua`, `Modules/UI/Requests.lua`.

- **REQUESTS-COVERAGE (self-audit 1ebe87b4 F3): the Requests body's dialogs, cluster buttons,
  listeners and officer Settings panel are driven offline for the first time.** `Requests.lua`
  stood at 70% line coverage; the uncovered ~600 lines were the cancel-reason dialog, the delete /
  re-open / mark-hand-off popups, the Cancel Stale and Fulfill Oldest buttons, the bag listener,
  the dropdown click-outside catcher and Escape, the help and tab tooltips, the Settings fields and
  the custom cancel-reason editor -- shipped, never driven. `Tests/requestsactions_spec.lua` (38
  examples, on the standalone window against the real AceGUI and the harness's frame model) drives
  all of it: 98.4% now (1960/1992 lines; what is left is early-return guards). Two things it found: (1) **the broom's "Cancelled N stale requests." status never
  showed** -- `OnAccept` set it and then called `DrawContent`, whose own "Showing N requests" landed
  on top the same instant; the redraw comes first now. (2) The banker's "Highlight needed items"
  checkbox was built in two places -- `BuildBody` (with REQUESTS-STRIP-001's own-row colspan) and a
  "delayed" copy in `UpdateFilters` (without it), so a checkbox created after the roster loaded
  landed as a bare fourth Table cell. One `Requests:EnsureHighlightCheckbox()` for both. The dialog
  is reachable as `Requests.CancelDialog` / `.CancelDropdown` for the spec. Locations:
  `Modules/UI/Requests.lua`, `Tests/requestsactions_spec.lua`.

- **SUFFIX-NAME-002: a request for a random-suffix item names the VARIANT.** The operator, with the
  Requests tab reading "Warmonger's Greaves" for a suffixed order: *"it's still a problem, the item
  in the requests HAS to show the link or i'm not able to fill the order properly ... aka, the
  suffixes."* This reopens SUFFIX-NAME-001 (held for LINK-AUDIT-001) the other way, and is the fix
  docs/LINK_AUDIT.md 3.4 step 1 recorded: `Resolve.describe` took the NAME from `lib:GetInfo`,
  which is the base name, while the LINK beside it was suffixed -- so "Spiked Club of the Bear"
  and "of Spirit" were two rows both reading "Spiked Club" to the requester, and the request that
  came of it named the base item to the banker (the 2026-09-13 field report: the order was
  `4564:1180`, the bank held `4564:28`). The name now comes from `lib:ResolveSuffix(id, suffix)`,
  the link's own source (`LibItemDB-1.0.lua:1255-1269`: base .. " " .. family; the base alone for
  an unknown property; feature-detected, base name on an older library). Every row that prints
  `Info.name` -- Browse, Search's corpus, the Log -- and every request minted from it carry the
  suffix. And `Item:RequestDisplayName` resolves id + `suffixID` whenever a request carries one,
  so the requests already stored with the base name read the variant too; the stored record is
  untouched. KNOWN COST: the Log's `item` and the Search corpus change for suffixed rows -- display
  only. TOGTools is NOT affected (Peer Review on 2a82f9ad, verified in its
  `GuildBankLog.lua:141-197`): its dedupe key strips a link to the itemID and excludes the name, so
  a suffixed link and its base link have the same `itemSig`; `docs/LINK_AUDIT.md` section 5 said
  the opposite in two rows and is corrected. The one place the family name now MISLEADS is the
  Search corpus's id-keyed `itemNames[v.ID] = v.Info.name` (LINK_AUDIT 3.6, already filed): the
  first suffix variant seen names every variant of that id there -- not a regression of this
  change, and fixed with LINK-AUDIT step 6. Also from that review: a base the library has in
  `core` but not in `names` answers no name (GetInfo nil, ResolveSuffix ""); `Resolve.describe`
  used to return an itemdb descriptor with `name = nil` for it, and now falls through to the
  client's data. Pinned: `resolve_spec` (family name from the same source as the link; unknown
  property; old library; the nameless base falls through), `requestname_spec` (stored base name +
  suffixID -> the variant; suffix 0 / absent -> stored; unknown id -> stored). Locations:
  `Modules/Inventory/Resolve.lua`, `Modules/Item.lua`.

- **MAILRETURN-001: return to sender from the Mailbox window.** The operator, having confirmed
  MAILCLICK-002 in game: *"can we add a return to sender option on this with a mail icon to the
  right of the Left column?"* A `ret` column after Left carries an envelope button
  (`Interface\Icons\INV_Letter_15`, the Fulfill Oldest icon) on every MAIL row that can be
  returned; hover says "Return to <sender>"; the click calls `ReturnInboxItem(mailIndex)` and the
  status line says "Returned to <sender>." The gate is Blizzard's own (Era
  `MailFrame.lua:786-800`, OpenMail_Delete): a mail is returnable when `InboxItemCanDelete` is
  FALSE -- a player's mail; a system/auction mail is deletable instead and shows no envelope.
  Attachment rows never do. The expansion set shifts past the returned mail exactly as after a
  take that empties one (MAILUI-003's rule), and MAIL_INBOX_UPDATE redraws. A return is refused
  with a message while a take-all is running, and is a no-op on a client without the API.
  HARNESS: env/wow.lua has no `ReturnInboxItem`, and its `InboxItemCanDelete` means "exists"
  rather than "system mail"; both are staged as stand-ins in `mailbox_spec` and contracted to
  WoWAPITesting (thread 38ea1e6a). `.luacheckrc` / `.luarc.json` learn the two globals. Pinned in
  `Tests/mailbox_spec.lua`. Location: `Modules/UI/Mailbox.lua`.

- **MULTIPC-004, the other half (Peer Review 7b7efb1f): the second holder of a newer version of our
  own bank is now actually asked.** Two holders name two versions -- A names X, B names a newer Y --
  and A answers first. MULTIPC-004 made the refusal of X release `awaitingDiffBase` and re-ask, but
  the re-ask ran INSIDE A's delivery, while A's session for our own name was still live, and
  `RequestDiffBase` refuses to ask while one is (`HasActiveSession(me)`, the peer-review-F5
  assumption that the only session for our own name IS the fetch). So B was still never asked and
  the publish waited out the 180-second fallback with no link and nothing logged -- the same
  symptom, one guard further along. `ReceiveDiffBase` no longer re-asks; it answers `false, "moved"`,
  and `Sync:ReceiveSnapshot` completes A's session first (A delivered what it had: slot released, no
  catch-up broadcast) and THEN calls `RequestDiffBase`, which now reaches B. Held since 2026-09-12 as
  "after the tag"; built under NO-PARKING-001. The multipc_spec example that pinned the flag release
  now drives the whole sequence on the real P2PSession: the re-ask goes to B for Y, Y is taken as the
  base, the publish links from it, no slot is left reserved. Locations: `Modules/Bank.lua`,
  `Modules/Inventory/Sync.lua`.

- **MAILCLICK-001: the Mailbox window's clicks are the real inbox's.** The operator, with the
  window open: *"when i left click on an item it needs to move into my bag. when i shift+left click
  it needs to move all attachments from the mail to the bags. Just like the 'real' mailbox."* It
  was right-click to take and left-click to open. Now: left-click on an attachment row takes it;
  shift+left-click on any row takes everything on that mail, money included; a left-click on a
  mail row opens and closes it; right-click on a mail row takes everything on it (as before);
  right-click on an attachment row takes it. **MAILCLICK-002, minutes later:** the first cut took a
  one-attachment mail's item on a click of the MAIL row (the row reads as the item) -- *"the left
  click to loot needs to only work when i click on the item, not the mail, i need the expand to
  work."* A mail row always opens on a click now, one attachment or ten. The hover hints and the
  status line say the gestures. `Mailbox:OnRowClick` is the one place; `TakeOne` is the
  one-attachment take with its status text. Pinned in `mailbox_spec`. Location:
  `Modules/UI/Mailbox.lua`.

- **WINDOW-CHROME-001: the bottom row every window shares is spelled once.** SYNCED-001's
  follow-up (*"make the requests window 'look' like the main window"*): the title and the status
  bar were already shared, but the help "?" block was still written out in Inventory, Requests,
  Search and Browse, the settings gear in Inventory and Browse, and two of the four pinned the
  status bar's right edge with a hand-summed constant (`-195`, `-210`) that had to be re-summed
  whenever an icon moved. Two of the copies cached their icons on the frame (AceGUI pools frames; a
  window that comes back would otherwise grow a second set under the first) and two had not learned
  that. One helper, `UI:DressWindow(window, { help, onHelpEnter, settings, extra })`: builds the "?"
  (24px at -133,15) and, for a window that asks, the gear (20px at -165,17, centres aligned), caches
  both on the frame, takes the window's own extra icons (Search's page arrows), ends the status bar
  at the leftmost icon BY ANCHOR through `UI:AnchorStatusBar` (the Requests cluster moves that edge
  and hands it back through the same call), and lifts the row above the resize sizers. Only each
  window's help text stays its own. Behaviour change, stated: the standalone Requests window's "?"
  is 24px like the other three (was 22); the Inventory and Search bars end 4px and 3px further left
  than the old constants put them. Also caught: the Log tab's help still described the From / To
  dropdowns LOG-FILTER-004 removed; it now says a name in the search box finds that person's entries
  on either side. `Tests/windowchrome_spec.lua` pins the geometry, the caching, the tooltip order,
  the gear's reopen-on-the-next-frame, the edge rule, and the source property that none of the four
  window files draws its own "?", gear or bar edge. Locations: `Modules/UI.lua`,
  `Modules/UI/Inventory.lua`, `Modules/UI/Requests.lua`, `Modules/UI/Search.lua`,
  `Modules/UI/Browse.lua`.

- **DOC-008: the player-facing docs brought up to v1.5.0, whole.** The operator, preparing the
  release: *"ensure the .html and readme are fully updated with the new features for v1.5.0, the
  slash commands we added are documented etc, fully updated."* Read against the changelog's every
  v1.5.0 entry (live and archived) and Chat.lua's command registry, three kinds of thing were wrong.
  (1) CLAIMS THE CODE DISPROVES: the CurseForge page's "Seconds, not minutes" bullet, its Setup step
  3 and its `/togbank share` line, README.txt's setup step 8, and the in-game setup instructions'
  step 6 (`HELP_INSTRUCTIONS` in `Modules/Chat.lua` -- a third copy DOC-006 missed) all said a bank
  close is shared with the guild straight away; nothing calls `SyncDeltaVersion` from `Bank:Scan`
  (`Events.lua`'s docblock says so and why), only `shareOnMint` for a hide/show does. All five now
  say the check-in, `/togbank share`, the Inventory window and a hide/show. The Mailbox "New" bullet
  described the first cut's right-click-to-take and a button "at the top right of the inbox" while
  the Changed list said the opposite (MAILCLICK-001/002, MAILBTN-001). The Required list omitted
  ItemDB, DeltaSync and LibAceGUIWidgets (both TOCs declare them); "TOG Tools -- planned, not
  available yet" described LOGAPI-002, which shipped. (2) MISSING: no bullet for DOUBLE-001 (the
  doubled counts), HIDE-SYNC-001 (the three-minute hide) or WIRE-SKEW-009 (the repeated Lua error);
  no "everyone should update" paragraph, though `DATA_LEG_MIN_ADDON_VERSION = 1.5.0` means a v1.4.1
  client is neither asked for nor served bank contents (`Guild:PeerSpeaksDataLeg`) -- v1.4.1's notes
  carried one and v1.5.0's is the larger break; `/togbank legacy`, `/togbank mailbox` and
  `/togbank helpreset` absent from both command lists; README.txt's version line still 1.4.1, its
  KEY FEATURES, BASIC USAGE (the Requests window, four per-column search boxes SEARCH-006 replaced,
  Fulfill Oldest "whole stacks" only), settings list, transparency window list and CHANGELOG
  HIGHLIGHTS all pre-v1.5.0; the evergreen Core Features described the old windows only. (3) THE
  GROUPING: the v1.5.0 block carried Changed and Fixed bullets about intermediate states of features
  that never shipped -- the Mailbox window's take gestures, envelope, Take Needed, button position
  and persistence; the Log tab's filters; the Bankers tab's search and Stores column; the "?"
  breathing per tab; the stay-online line's amber state, breath and logout survival; the connected-
  realm Online column; the expanded-mail take; the narrow-bar centre line; `/togbank wipe` and the
  log; the mail-arrival deposit; the hidden-row left-click. A reader on v1.4.1 has no "before" for
  any of those, so each is folded into the New bullet for the feature it belongs to, and the one
  genuine change among them (the Send Mail tab opening the Guild Bank window) moved from Fixed to
  Changed. Nothing about a thing that existed in v1.4.1 was removed. Also: the Bankers tab's five
  statuses replace README.txt's two tab colours; a troubleshooting entry for the doubled counts
  names `/togbank dev sources`. Locations: `docs/Curseforge_Description.html`, `README.txt`,
  `Modules/Chat.lua`.

<!-- MOVED-TO-ARCHIVE 2026-09-13: the next five oldest Bug Fixes (FULFIL-003, BROWSE-005,
     STATUSBAR-002, STATUSBAR-003, MULTIPC-001) moved byte for byte to the same archive heading
     ("Bug Fixes - the oldest of v1.5.0"), ahead of the nine that went on the 12th, for the same
     reason: 3,700 characters of headroom with MULTIFILL-001 just written up. -->

<!-- MOVED-TO-ARCHIVE 2026-09-12: v1.5.0's two `### Internal` sections stood here -- the
     dev-facing engineering detail behind the features and fixes above. They moved WHOLE to
     `CHANGELOG_ARCHIVE.md` under "[v1.5.0] extended engineering detail", byte for byte, because
     this file is published verbatim as the GitHub release body and had run to within 52 characters
     of the 125,000-character hard limit with no version boundary left to split at (v1.4.1 was
     already archived). Nothing was deleted. Same remedy as the v1.4.0 split of 2026-09-10.
     Later the same day the OLDEST nine Bug Fixes (OUTPUT-002, TABCOLOUR-003, P2P-037, NAME-001,
     RESOLVE-002, ROSTER-005, HIGHLIGHT-003, DB-003, PERF-023) followed them, byte for byte, under
     the same archive heading, for the same reason. -->

> Releases **v1.4.1 and older** have been moved to
> [`CHANGELOG_ARCHIVE.md`](CHANGELOG_ARCHIVE.md) to keep this file under GitHub's 125,000-character
> release-body limit. Nothing was deleted; each section moved whole, at a version boundary.
