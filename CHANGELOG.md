# TOGBankClassic Changelog

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

## [v1.6.0] (2026-09-17) - The Shop Tab

**Numbered v1.6.0, not v1.5.2 (VERSION-160-001).** The operator, 2026-09-16: *"then this isn't a .2
change, it's a v1.6.0 change. that wasn't clear to me. we need to update docs accordingly"*. This
release breaks the bank-contents sync with v1.5.1 (LIBREQ-DS-008, below: the P2P moved onto
DeltaSync's prefixes, `DATA_LEG_MIN_ADDON_VERSION` is now `1.6.0`), and a break is a MINOR bump, not
a patch. The break was a choice this work made rather than a requirement of the move -- the old
handshake could have been kept for v1.5.1 peers -- and it was recorded as a KNOWN COST without that
being made plain. It also needs DeltaSync v4.2.0 (LIBREQ-DS-008 asks 1-3; released 2026-09-16 at
`2e5b226`, library MINOR 19) and, for the sister-guild bank, Guild Roster's same-realm fix
(GR-SAMEREALM-001, 0.8.2 / MINOR 21, in its working tree as this is written). Earlier entries below
say "v1.5.2" where they meant this release; they are this one.

### Bug Fixes

- **LINK-AUDIT-001 steps 4-6: a random-suffix item is ONE item everywhere it appears.** The
  operator's Dreadblade (`docs/LINK_AUDIT.md` 3.3): a "Dreadblade of the Bear" read in a bank
  character's inbox was stored as `{ 17240, 1 }` -- suffix thrown away at the inbox edge -- while
  the same weapon taken into the bags was `{ 17240, 1, 1196 }`, so the viewer showed two rows, the
  take logged a withdrawal of one and a deposit of the other, and the log's `from` (keyed `id:0`)
  could never name the sender. The inbox is now parsed by the one parser (`Scan.parseLink`) into
  records that keep suffix and enchant (`MailInventory`), the store's mail source is those records
  (`Bank:Scan`), and the sender table is keyed the way the log diffs (`Record.key`). Three more
  id-only identities went with it: `ItemHighlight` lit EVERY Dreadblade in the bags for a request
  naming one variant, and the Search window's corpus was keyed by id so the first variant seen
  named every variant ("of the Tiger" filed under "of the Bear", unfindable by its own name) --
  `Record.requestKey` and the row's own name respectively. The fulfil matchers (`Bank.lua`,
  `Mail.lua`) read a slot's suffix through `Scan.parseLink` instead of a second parser with a
  different pattern. Offline: `logwho_spec` (inbox records keep the variant, merge across mails,
  senders keyed by variant), `search_spec` (new: two variants are two names), `itemhighlight_spec`,
  `mailbox_spec`, `bank_spec`. **KNOWN COST, once per bank character:** the first mail-inclusive
  scan on this version moves the content hash and the mail hash wherever a suffixed attachment sits
  in the inbox -- one version bump, and every viewer fetches that version once. Self-correcting, the
  same class as the content hash's own introduction. 1800/0 both orders. Locations:
  `Modules/MailInventory.lua`, `Modules/Bank.lua`, `Modules/Log.lua`, `Modules/ItemHighlight.lua`,
  `Modules/UI/Search.lua`, `Modules/Inventory/Scan.lua`, `Modules/Inventory/Record.lua`.
- **XGUILD-INVENTORY-001: sister guilds' bank contents never arrived ("No data").** Operator:
  *"now we need to get the inventory sync working ;)"*. Three defects, found by `xguilde2e_spec`:
  (1) `Guild:IsPlayerOnline` read a sister member from `memberRoster`, which copies Guild Roster's
  presence only on rebuild, so `SendWhisper` refused the peer `FederationPeer` had just picked; it now
  reads `GetOnlineMembersScoped`. (2) `FederationPeer` took the first sighted member whatever it ran
  (XGUILD-PEER-001); it now skips a release `PeerSpeaksDataLeg` refuses and prefers a TOGBank speaker,
  then a VersionCheck-known current one, then an unknown. A member proven current asks its guild at
  once (`OnFederationPeerProven`, once per 600 s per guild), and the cycle leaves an ask younger than
  120 s pending instead of marking it silent. (3) Guild Roster dropped every same-realm roster
  (GR-SAMEREALM-001, bare AceComm sender vs `Name-Realm`), fixed by Guild Roster 0.8.2. KNOWN LIMIT:
  first contact still needs Guild Roster's "Pull from" or its click-sent /who.
- **XGUILD-OWNERS-001: bank-character owners were overwritten across sister guilds.** Operator: *"we
  also need to sync the right click who owns banker metadata between sister guilds"*. One field with
  one stamp let the last guild to write replace the other's table. Each entry now has its own stamp
  (`bankerOwnerStamps`, not in the canon) and `Guild:MergeBankerOwners` merges entry by entry: newer
  wins, a stamped absence clears, an older copy never resurrects. A sister member may only set its own
  guild's bank characters; an officer cannot set a sister guild's (`BankerOwnerWritable`; the Bankers
  tab says whose officers do). A pre-stamp sender is adopted whole, as before.
- **DS-MINOR-CHECK-001: an out-of-date DeltaSync synced worse, silently** (Peer Review 2c807551 F2).
  With the stand-ins deleted, DeltaSync v4.1.0 never offers unlisted bankers. `P2P:WarnIfLibraryBehind`
  feature-detects `OnNumbersChanged` and warns the player once per session.

- **SETTINGS-CANON-001: the maximum request % is ENFORCED, and the officer settings ride EVERY sync
  with a canon -- a client holding older settings is corrected on its own sync.** The operator: *"we
  need to ensure the the request % is being synced and enforced. people are still allowed to request
  more than what was set. the officer setting needs to be part of EVERY sync. they should have a
  canon has as well and if someones is older, they need to pull the new settings as part of their
  sync"*. Three defects, each traced in code, any one of which let a member order past the limit:
  **(1) nothing enforced it but the request dialog.** `Guild:AddRequest` checked view-only, the shop
  sign, not-for-sale and shop orders, and never the percent -- and TOGProfessionMaster's [Bank]
  button (`Compat.lua:675`), Dibs (`Modules/Bank.lua:182`) and PersonalShopper
  (`GUI/ShoppingListTab.lua:1228`) all call `AddRequest` directly. **(2) the dialog measured each
  order ALONE**: its "available" is the row's raw count (`Modules/UI/Search.lua`), so a member could
  place the maximum, then the maximum again. **(3) the settings were a PUSH only** -- the officer's
  ALERT write and an authorized client's ten-minute re-announcement -- so a member offline through
  the write logged in holding the old limit with no way to learn it was behind. The fixes:
  `Guild:RequestAllowance(requester, bank, itemID[, count])` is the one number -- the percent of the
  bank's stock (at least 1 when it holds any), less this requester's OPEN orders of that item from
  that bank (`Guild:OpenRequestedQuantity`: quantity less what was mailed, open status only) --
  and `AddRequest` refuses past it with a sentence saying how many more are allowed; the dialog
  reads the same function (`Search:RequestLimit`, passing the row's count, never looser than the
  gate) and says how many are already on order. `Options:GetMaxRequestPercent` now returns
  `Guild:MaxRequestPercent` (REQUEST-LIMIT-ONE-RULE-001, self-audit): it had returned the raw stored
  value, so a stored 33.7 or 0 displayed 33.7 / 0 while the gate enforced 33 / 1, and
  TOGProfessionMaster's fallback reads that getter. On the wire, `Guild:SettingsFields()` is now the one
  list the settings broadcast sends and `Guild:SettingsCanon()` hashes (sorted keys, values only,
  through `Core:Checksum`, over the values AS A RECEIVER STORES THEM -- cancel reasons and help
  notes sanitized, the two numbers floored -- because the self-audit found that hashing the writer's
  raw copy left an officer and every member who applied their settings disagreeing forever and
  re-sending on every sync); every client's hlb2 carries `sv` (the held version) and `sh` (the canon),
  and so does the hash-list reply. `Guild:OnSettingsAdvertised` runs both sides of the handshake on
  the sync that carried it: BEHIND an authorized home guildmate (newer version, or the same version
  with different values) it whispers `settings-request`; AHEAD of any home guildmate while holding
  standing itself, it answers at once with the settings payload by whisper
  (`Guild:OnSettingsRequest`, also the receiver of `settings-request`). So a member logging in with
  yesterday's limit is corrected by its own login broadcast, not by somebody's next cycle
  (HANDSHAKE-OVER-TIMERS-001). One ask per (peer, version, canon) per 60 s and one answer per asker
  per 30 s are dedupes, not waits. **KNOWN COSTS:** an order placed before this build is not
  cancelled for being over the limit; an order with no `itemID` (a pre-REQ-001 client) cannot be
  counted and passes, as it always has; the cap counts the bank's whole stock of the item id, so
  for suffixed gear the gate is looser than the dialog (which counts the variant's row); equal
  versions with values neither side's stamps can settle may be re-sent once per sync per pair; and
  the enforcement runs on the requester's client, like every gate in `AddRequest` -- a client
  older than this build does not have it. Specs: `Tests/settings_spec.lua` (+9: the canon, the ask,
  the answer, the end-to-end dispatch, the gate, open orders, filled/cancelled/complete, single items
  and 100%, the clamp) and `Tests/settingssync_spec.lua` (NEW, the field case on both wires: a
  member offline through the write is corrected by its own login sync and refused past the limit).
  Locations: `Modules/Guild.lua`, `Modules/RequestLog.lua`, `Modules/Events.lua`, `Modules/P2P.lua`,
  `Modules/Chat.lua`, `Modules/UI/Search.lua`, `Modules/Options.lua`, `Modules/UI/Requests.lua`,
  `README.txt`.

- **LIBREQ-DS-008 asks 1-3 ADOPTED: three TOGBank stand-ins deleted, DeltaSync does the work.**
  DeltaSync built all three asks in its working tree on 2026-09-16 (thread c20eb5b527e1), adopted the
  same day under LIB-RELEASE-ORDER: the library now offers back the keys a broadcast did not list
  (its numbers table first to a broadcaster behind on it), parks an offer naming a number its table
  cannot resolve and replays it on mint/adopt, and fires `onOfferReceived` before it judges a
  message. Found the moment the library landed, because the harness loads the live library: with
  both copies running a banker offered every unlisted key TWICE (`congestion_spec`, reverse order).
  Deleted from `Modules/P2P.lua`: `OfferUnmentioned`, `ParkUnresolved` / `ReplayParkedOffers`
  (and BankerNumbers' call to it), `NoteVersionFirst` and its wrapper over the instance's
  `OnBroadcast`. New: `P2P:BroadcastExtra()`, the one builder of TOGBank's hlb2 fields, used by
  `Events:SyncDeltaVersion` and handed to the library as `broadcastExtra` so its catch-up broadcast
  names the addon version, price list and settings too (it named none before). **KNOWN COST:** this
  build needs that DeltaSync release; against DeltaSync v4.1.0 an unlisted banker is never offered
  and an early offer is dropped until the catch-up. Specs: `p2psession_spec` (the stand-ins'
  describes replaced by examples through the real host's OFFER receive), `congestion_spec` (the
  library's park), `deltahost_spec`. Locations: `Modules/P2P.lua`, `Modules/BankerNumbers.lua`,
  `Modules/Events.lua`.

- **CONGESTION-HARNESS-001: the fleet runs on the harness's own clients; env_fleet's hand-built
  clients and throttled bus are gone.** `Tests/env_fleet.lua` stands each client up with
  `wow.client()` / `client:loadFile` (per-client env, LibStub, ChatThrottleLib, bags, money, guild,
  presence, timers) and the throttled wire is `wow.wire` with queued delivery pumped each tick (a
  synchronous echo let an offer arrive before DeltaSync opened its collect window). Three things the
  port found: clients read host `TOGBankClassic_*` globals left by earlier spec files (now hidden --
  the full suite hung without it); a finished fleet's frames kept sending as ghosts (`F.teardown` on
  every reset); and ~37,000 live frame objects left by UI specs made every tick walk them all (the
  full suite exceeded fifteen minutes; `F.new` drops them from dispatch, harness contract
  FLEET-PORT-SPEED-001). `congestion_spec`'s P2P-031 example rested on a drain the old bus happened to
  give; it now uses a 400-row snapshot. Full suite in one run again.

- **XGUILD-BANKERS-001: a sister guild's bank characters now appear when its roster arrives, not
  only after a relog.** The operator, with the sister guild listed, its 290-member roster held and
  the switch on: *"should i not have the list of their bankers, and should they not be populating in
  the bankers tab?"*. Their saved roster did carry the `gbank` notes; TOGBank never looked again.
  A sister guild's bankers enter `memberRoster` (and so `GetBanks`, the Bankers tab and every banker
  list) only on a rebuild, and nothing rebuilt when a sister roster landed: LibGuildRoster files the
  FIRST copy of a sister roster as a baseline with no per-member `OnMemberJoined`, a pull that only
  changes notes fires no join either, and TOGBank listened to joins alone. `Guild:InitRosterCallbacks`
  now also listens to `OnSisterRosterUpdated`, `OnRosterHashChanged` (sister keys) and
  `OnSisterConfigChanged`, and rebuilds the member cache, the banker roster and the open windows when
  the sister bankers they name changed. Spec: `Tests/xguild_spec.lua` (+1: a roster arriving after
  the cache was built, a note-only pull, the switch off -- red without the listeners). Location:
  `Modules/Guild.lua`.

- **SETTINGS-FANOUT-001: a member behind on the settings is answered by ONE bank character or officer,
  not all of them** (self-audit 4777d14a F2). Every client with standing that heard the member's login
  hlb2 answered it: eight online meant eight identical whispers. No timer picks the responder: each
  client records what every authorized guildmate SAID it holds (`sv`/`sh` on its hlb2 or hash-list
  reply, and its own guild-settings payload, via `Guild:NoteSettingsHeld` / `NoteSettingsBroadcast`)
  and defers when an online home guildmate that sorts first -- byte by byte, since Lua 5.1 compares
  strings by locale -- is recorded ahead of the asker (`Guild:SettingsResponderBefore`). A record
  only under-states what a guildmate holds, so the bottom of that chain is really ahead and answers.
  A hash-list reply reached us alone and is always answered (`private`). Deliberately NOT inferred:
  that everyone who heard a GUILD payload now holds it -- a receiver ranked below an officer drops
  that officer's write before the GM publishes the floor (SETTINGS-003), and deferring to it would
  miss. **KNOWN COST:** records refresh on each guildmate's own ten-minute sync, so a member who logs
  in within ten minutes of a write may still get several answers; a missed answer (a guildmate gone
  offline before the roster said so) is recovered by the member's ask on the next authorized hlb2.
  Specs: `Tests/settingssync_spec.lua` (+2 per wire: three bank characters, one answer; the
  lowest offline, the next answers -- red with the deferral removed, 3 and 2 answers),
  `Tests/settings_spec.lua` (+1). Locations: `Modules/Guild.lua`, `Modules/Chat.lua`.

- **SETTINGS-CANON-002: two more ways the settings canon could never agree** (Peer Review on the
  4777d14a self-audit, finding 1). **(1) the officer rank floor** is adopted from the GM alone, but the
  payload's version from any authorized sender, so a member answered by a bank character held its
  version with the old floor and asked every bank character it heard, every sync, until a GM
  broadcast reached it. `Guild:CanonOfSettingsFields` now leaves the floor out; the GM's publish and
  re-announcement still carry it, and `ApplyRemoteSettings` says why its version line is deliberate.
  **(2) a legacy stored 0%** (or 0 tombstone days) went out raw and every receiver refused it;
  `Guild:SettingsFields` now sends the percent clamped to 1..100 and the days to at least 1, the form
  a receiver stores. Specs: `Tests/settings_spec.lua` (+2; the floor example red without the fix).
  Location: `Modules/Guild.lua`.

- **CONGESTION-001 / P2P-036: a bare offer whose banker-number table has not landed yet is PARKED and
  replayed when it does, instead of being dropped -- a cold client now holds the bank at the end of
  its first cycle rather than two minutes later.** Found by the new congested wire (below), in the
  ordering the operator's own guild produces every login: a viewer that holds no numbers table
  broadcasts; the banker, inside ChatThrottleLib's five-second post-login clamp (~80 bytes/s),
  answers with the 38-banker table -- 1165 bytes, FIVE chunks on the host's HANDSHAKE prefix -- and
  then the one-chunk `hash-offer2` on its OFFER prefix. CTL keeps one pipe per prefix and
  round-robins them a chunk at a time, so **the offer arrives before the table's last chunk however
  the sender ordered them** (measured: table +10 s..+13 s, offer +11 s). DeltaSync's `NP:OnOffer`
  cannot resolve a number the table does not name yet and drops it; the viewer's 60-second collect
  window closes having learnt nothing; the sync runs on the 45-second catch-up broadcast at +111 s.
  `P2P:OfferUnmentioned` already sent the table first (P2P-035) and that is simply not sufficient on
  a real wire -- the fix is not ordering but memory. `Modules/P2P.lua` now keeps each sender's
  unresolved numbers (`parkedOffers`, ONE park per sender -- a later offer from that peer is its
  current word and replaces it, so a chatty peer cannot grow it) and replays the ones a new table
  resolves into the library's own `OnOffer`, in the library's own `hash-offer2` shape, from
  `BankerNumbers`' `onChanged` (mint and adopt). Inside the collect window the replay is recorded
  with the rest; after it, the library's late-offer path acts at once. **HANDSHAKE-OVER-TIMERS-001 in
  one line** (the operator: *"why i HATE timers. i would rather have handshake comms instead of
  timers whenever possible"*) -- the thing that completes the offer is the table ARRIVING, not a
  timer expiring; the catch-up timer stays as the fallback for a peer that never answers. Raised to
  DeltaSync as ask 2 on thread `c20eb5b527e1` with the measurement; the stand-in is deleted the day
  the library parks them itself. Watched go red with the replay removed: 0 requests in the first
  window, the catch-up doing the work, two broadcasts and two offers for one sync. Locations:
  `Modules/P2P.lua`, `Modules/BankerNumbers.lua`.

### New Features

- **SHOP-ORDER-API-001: `Guild:ShopOrderFields(itemID)` -- the shop-order fields for another addon's
  request button.** While the shop is on, `Guild:AddRequest` refuses any request without the shop
  mark (SHOP-NOFREE-001), and only the request dialog could build one, inline -- so
  TOGProfessionMaster's [Bank] orders were all refused while the shop sold (its question on thread
  `17a1f2c9`). `Browse:ShopOrderFields` is now the one builder (`shopOrder`, `estimate`,
  `estimateBase`, `discount`, `estimateSource`, and the `prompt` line), the dialog reads it, and
  `Guild:ShopOrderFields` is the public entry (nil while the shop is off, or without the Guild Bank
  window's module). Specs: `Tests/browse_spec.lua` (the builder agrees with the dialog field for
  field; nil on a plain bank), `Tests/settings_spec.lua` (the Guild entry delegates, nil without the
  builder). Locations: `Modules/UI/Browse.lua`, `Modules/UI/Search.lua`, `Modules/RequestLog.lua`.

- **SHARE-BTN-001: a `/togbank share` button on the bottom row, for bank characters.** The operator:
  *"for the bankers, we need to add a button to the right of the gear wheel settings icon that is the
  /togbank share button. shorten the status bar to make up for the space."* `UI:DressWindow` takes
  `share = true` (the Guild Bank window and the legacy Inventory window ask for it) and builds a 20px
  button cached on the frame like the gear. On a bank character it sits at the gear's old place
  (-165) and the gear moves one slot left (`GEAR_X_BESIDE_SHARE` = -193, the same 8px gap the gear
  keeps from the `?`). **The gear stays the leftmost icon either way**, so the anchor the status bar
  and the Requests cluster hang from never changes identity: moving the gear IS the shorter status
  bar, with no re-anchoring. The click runs `Chat:ChatCommand("share")` -- the slash command's own
  handler, zone-in deferral and rescan included, not a copy. Visibility is `UI:SyncShareButton`, asked
  on every dress AND on the frame's `OnShow`, because a window drawn before the roster knows the
  player is a banker (`Guild:IsBank` reads a cache that is empty for the first moments of a session)
  would otherwise never show it; a pooled frame dressed without the ask hides it and puts the gear
  back. Icon: the client's own `Interface\Buttons\UI-RefreshButton` circling-arrows glyph, chosen
  because both flavours are known to ship it (the Era and Anniversary LFG browse panels draw it), so
  it cannot render blank the way many Era icon files do. The `?` help on the Browse tab and the
  legacy window says what it is (HELP-CURRENT-001). Specs: `Tests/windowchrome_spec.lua` (+6 --
  placement and gaps, the non-banker case, the OnShow re-check both ways, the click and hover, the
  pooled-frame and no-gear cases, and both windows asking). SHARE-BTN-LIVE-001 (self-audit): the
  visibility was re-decided only on a dress and on OnShow, so a banker whose status arrived with the
  window open saw no button until a reopen; `UI:SyncShareButtons` now runs from both return paths of
  `Guild:RefreshOnlineCache` (+1 spec). Not seen in game. Locations:
  `Modules/UI.lua`, `Modules/UI/Browse.lua`, `Modules/UI/Inventory.lua`.

- **VISIBILITY-001 part 4: the officer Settings panel.** `Requests:LayoutSettingsPanel` sets every
  size/anchor at the scale on build, find-again and show (a rebuild finds the overlay again, so the
  build alone never re-sized it); numeric fields wrap when too wide; pooled reason rows re-laid each
  refresh; InputBoxTemplate art grown with the box; `UI:UIScaledButtonFonts`. Harness gaps filed
  (thread c58cf6b3, EditBox font + parentKey art), spec stand-ins. Re-laid on OnSizeChanged. +2 specs
  (standalone, embedded), both red with scale off. 1827/0 both orders.
- **VISIBILITY-001 part 3: the stock AceGUI filter controls.** `UI:ScaleStockWidget` puts a stock
  Dropdown/EditBox/CheckBox/Button on the scaled base fonts, grows their FontString heights, the
  label-to-box offset (DropDown.lua:515, EditBox.lua:172), the checkbox box and button height, and
  undoes it on release (pooled frames; `RestoreStockWidget`, folded into Requests' one OnRelease
  handler). Art and EditBox typed text stay 1x. Browse strips and the Requests strip use it; the
  Requests body rebuilds on the signal. `env_togbank.reset` drops orphaned Browse/Requests module
  listeners (they failed forward-order). Specs +1; browse red with it off. 1825/0 both orders.
- **VISIBILITY-001 part 2: TOGBank's own regions follow the scale.** Part 1 said the lists scaled;
  they did not -- every list tab is `Modules/UI/RowList.lua`, not the library's RowList. Now:
  RowList derives row/header height, pads, gaps, column widths (`col.width` stays 1x, so COL-FIT-001
  never compounds), icon and arrow sizes from the scale and re-lays header and pooled rows on
  `OnScaleChanged`; fonts are the library's scaled copies. `UI:UIScaled` / `UIScaledFont` /
  `OnUIScaleChanged` are the one lookup. Also scaled: Requests' action icons (size, spacing, and the
  `|T:14:14|t` markup re-derived from the 1x text), cell fonts, empty-list offset and bottom cluster;
  the status bar's three fonts (AceGUI's pooled `statustext` restored on release); the `?`/share/gear
  row, now one chain (`UI:LayoutChrome`, `CHROME.ICON_GAP`); Browse's strips, search boxes and list
  offsets, rebuilt on the signal; the Mailbox envelope. Tab art and the scrollbar lane are not
  scaled; stock controls are part 3.
  Specs +6 in browse, windowchrome, requestsactions, plus mailbox_spec; RowList red with the scale off.
  1824/0 forward and reverse. NOT SEEN IN GAME.
- **VISIBILITY-001: one accessibility scale, on a slider.** The operator: *"can we add a visibility
  feature that makes the font/icons/rows larger on a slider for the visually impared?"* **Window and
  Text Size** (General, 80%-200%) drives LibAceGUIWidgets MINOR 29's `W:SetScale`. Bounds read off
  the library (`W.SCALE_*`); per character (`db.char.uiScale`); `Options:SetUIScale` the one writer,
  `ApplyUIScale` the one caller (slider and `Init`); out-of-range clamps, junk reads 1.0, an older
  library saves and no-ops. `optionslayout_spec` +5 on the real library. The fixture clears the
  `TOGBankClassicOptionDB` SavedVariable between files: a saved scale leaked into later window
  specs, caught only in reverse order. NOT SEEN IN GAME. `Modules/Options.lua`.
- **SHOP-TAB-001: the shop is its own tab of the Guild Bank window, behind a switch that is OFF by
  default.** The operator, the moment STORE-001's estimate column appeared on the Browse tab:
  *"i think it should be a new tab, with a setting to turn it on/off, so folks can shut it off if
  their bank doesn't 'sell' items. it should be off by default as I don't think most guilds will use
  it this way."* So: **Shop** under Requests in the Blizzard options (officer-only, guild-synced,
  `Guild.Info.settings.shopEnabled`, `Guild:IsShopEnabled()` / `Guild:SetShopEnabled()` the one
  writer, sent as a real boolean and applied only when carried). Off -- the default, and a missing
  value -- the Guild Bank window has its four tabs and every shop rule is inert: `IsStoreOpen()`
  answers open and `IsNotForSale()` answers no whatever the stored sign and list say, so a guild that
  never turns the shop on never sees a gate. On, a fifth **Shop** tab appears (appended, so Browse /
  Bankers / Requests / Log keep their places; `Browse:TabList()` is the one list `SetTabs` and the
  remembered-tab validation both read, so a saved "shop" from a session when the shop was on falls
  back to Browse rather than opening blank). The tab is the catalogue: icon, item, quantity, banker
  and the **Est.** column (STORE-001, moved here from Browse); a search box; and, for an officer, the
  **Ordering open** box on the strip (STORE-006 step 1, moved here from the Requests tab's Settings
  panel -- the sign is the shop's, not the requests'). The status line is the sign and the count:
  "ORDERING CLOSED -- 41 items, 12 with an estimate", or "no price data yet: type /itemdb ..." when
  ItemDB has no source that can answer, or "no price library" against an ItemDB without MINOR 25.
  The Browse tab keeps the not-for-sale tag and the click refusals while the shop is on, because a
  blocked item cannot be ordered from anywhere; it never prices. Flipping the switch under an open
  window re-renders the tab strip on every client (`Browse:OnShopSettingChanged`, from the writer and
  from the settings receipt) and moves a viewer off a Shop tab that no longer exists. Offline:
  `requestchain_spec` (off by default; the stored sign and list inert while off; the one writer;
  the broadcast carries the STORED sign, not the shop-gated read; the peer receive; an old client's
  broadcast leaves the switch alone), `browse_spec` (four tabs off, five on, the remembered "shop"
  falling back, the strip re-rendering both ways under an open window, the Shop tab's catalogue,
  status lines and Ordering open box, the Browse rows unpriced), `requestsactions_spec` refuses the
  box returning to the Requests panel. Suite 1718/0. NOT SEEN IN GAME. Assumption stated: the switch
  is guild-synced and officer-set because "their bank doesn't sell items" is a property of the guild;
  a per-viewer preference would be one line to move. Locations: `Modules/Guild.lua`,
  `Modules/Options.lua`, `Modules/UI/Browse.lua`, `Modules/UI/Requests.lua`.
- **STORE-001: the estimate, banker-local, on the Shop tab.** Build-order step 5 of
  `docs/GUILD_STORE.md`, over ItemDB's delivery of LIBREQ-PRICE-001..010 the same day (LibItemDB-1.0
  MINOR 25; the response block is under `docs/LIBRARY_CONTRACTS.md` 7.13). `Browse:PriceLibrary()`
  feature-detects `GetPrices` on the METHOD, never a MINOR compare, so an older ItemDB prices nothing
  and breaks nothing (a library that raises is pcall-wrapped to the same end); `Browse:PriceRows`
  prices the whole catalogue in ONE bulk call over the set of item ids -- the shape a bank inventory
  has -- with the account's default statistic, and hangs `value`, `_sort_value` and the provenance
  on the row; nil, never 0, for an unpriced row (LIBREQ-PRICE-003). GUILD_STORE.md 3 governs the
  wording: the header is **Est.**, every figure wears a `~`, the header tip says ESTIMATE and that
  the bank character sets the real price at fill, and the hover says where the number came from --
  "Estimated ~12g 34s -- min buyout, Auctionator, 2h 14m old", with "age unknown" for a source that
  gives no age (Auctioneer, TSM) rather than anything that reads as fresh. Locations:
  `Modules/UI/Browse.lua`.
- **STORE-006: ordering can be closed guild-wide -- the shop's open/closed sign.** Build-order step 1
  of `docs/GUILD_STORE.md` (4.6), un-deferred by the operator on 2026-09-14 (*"can we not do this work
  now?"*). One officer-set boolean on the guild-synced settings, `Guild.Info.settings.storeOpen`:
  `Guild:IsStoreOpen()` reads a missing value as OPEN (every guild ran without the sign, and a
  pre-STORE client never sends the field); `Guild:SetStoreOpen(open)` is the ONE writer -- it writes,
  broadcasts on `togbank-hl` at ALERT and prints the chat line, and reports whether anything changed,
  so the two controls cannot drift: an **Ordering open** box on the Shop tab's strip for an officer
  (first built at the end of the Requests tab's Settings row; SHOP-TAB-001 above moved it the same
  afternoon) and an officer-only **Ordering open** toggle under Requests in the Blizzard options
  (`Modules/Options.lua`, greyed while the shop is off). `BroadcastSettings` sends the
  sign as a real boolean; `ApplyRemoteSettings` applies it only when the sender carried it, so an
  older client's broadcast cannot reopen a shop an officer closed, and anything but `true` closes.
  The gate is in `Guild:AddRequest` beside the view-only one (`Modules/RequestLog.lua`): closed,
  nothing is minted and nothing goes on the wire. The friendly refusals share one sentence,
  `Guild.STORE_CLOSED_TEXT` -- the Browse tab's status line on a row click (`Modules/UI/Browse.lua`)
  and a chat warning from the request dialog before it builds anything (`Modules/UI/Search.lua`), so
  the old Inventory window's rows say the same thing. Local-only, like every gate here (4.8): it runs
  on the requester's client. No free-text reason and no per-item block yet -- the not-for-sale list is
  step 2. Offline: `requestchain_spec` runs the real Guild + RequestLog + Chat dispatch with the wire
  captured (default open; closed mints nothing and broadcasts `false`; the broadcast reaches a peer
  and reopens the same way; a pre-STORE payload does not reopen; the no-Info no-op);
  `browse_spec` drives the Shop tab's box through the one writer and pins the status line and the
  real dialog's refusal. Suite 1711/0 when first built.
- **STORE-006, step 2: the not-for-sale list.** Build-order step 2 of `docs/GUILD_STORE.md` (4.6):
  an officer takes an item off the shop list and it stays in the Guild Bank window (the guild still
  holds it) wearing a red **(not for sale)** tag, but nobody can order it. KEYED BY `itemID`, never by
  name -- same-name variants are REQ-001's solved problem and a name-keyed list would undo it -- so a
  request from a client too old to carry an id (pre-REQ-001) passes the gate as it always has.
  `Guild.Info.settings.notForSale = { [itemID] = true }`, synced with the other guild settings:
  `BroadcastSettings` always sends it as a table (empty means "nothing blocked"), and
  `ApplyRemoteSettings` REPLACES the held list with the sender's only when the sender carried one,
  sanitized (`Guild.SanitizeNotForSale`: integer ids 1 and up, at most 500), so an older client's
  broadcast cannot put everything back on sale. `Guild:IsNotForSale(itemID)` reads (string or number
  id); `Guild:SetNotForSale(itemID, blocked, name)` is the ONE writer -- validates the id, refuses a
  501st, writes, broadcasts at ALERT, prints the chat line, and reports whether anything changed. The
  gate is in `Guild:AddRequest` beside the open/closed sign. The officer's control is a gesture on the
  Browse tab rather than a list to type into: **Ctrl+right-click** any row toggles it (Ctrl, because
  a plain right-click on an officer's own bank already hides); a member who tries is told "Only an
  officer can change what is for sale". `Browse:CanEditShopList` is `CanViewOfficerNote()`, the same
  officer test the Requests Settings panel and the help notes use. A left-click on a blocked row
  writes `Guild.NOT_FOR_SALE_TEXT` (with the item named) to the status line; the request dialog
  warns with the same sentence before building anything; the hover carries "Not for sale" for
  everyone and the Ctrl+right-click hint for an officer -- on a NEW lines table when anything is
  added, because the `HIDDEN_TEXT` tooltip entries are shared by identity with the Inventory window
  and are never appended to. Offline: `requestchain_spec` on the real Guild + RequestLog + Chat
  dispatch (the writer, the wire shape, the gate, the id-less pass, the peer receive, the sanitizer
  on string / zero / fractional / false keys, the 500 cap on receive and on write, an old client's
  broadcast clearing nothing -- with the delivering sender NOT the local player, which the fixture's
  self-message rule silently drops); `browse_spec` (the tag, the click, the member refusal, the
  officer toggle through the one writer with a redraw, the hover for member and officer, the
  HIDDEN_TEXT identity preserved on an own row); the real dialog's refusal names the item. Suite
  1714/0. Not built: a not-for-sale REASON, and the rank floors (4.6's third control, step 10 of the
  build order). Locations: `Modules/Guild.lua`, `Modules/RequestLog.lua`, `Modules/UI/Browse.lua`,
  `Modules/UI/Search.lua`.
- **STORE-007: donation credit -- points for what a member gives the bank, valued once, when it
  arrives.** Build-order step 6 of `docs/GUILD_STORE.md` (4.7). The design note's premise was that
  donations were "tracked but not valued"; reading `Mail:Open` showed they were valued -- at the
  vendor sell price plus one copper, in gold, summed into a per-banker `alt.ledger[sender]` that
  never left the banker's own SavedVariables, so the Donations window showed a banker their own
  scores and a member nothing. What changes, each rule the design's answer to an argument:
  **valued at ingest and locked** -- the banker's client asks ItemDB (`GetPrice`, feature-detected
  on the method) for a CONSERVATIVE statistic, minimum buyout then historical, never market value
  (a thin market can be pushed up and donated into), with the vendor sell price as the FLOOR
  (nobody lists below what a vendor pays), and writes copper, points, source, statistic and age into
  an entry that is never re-priced; **the rate** is an officer setting, `donationRate` on the synced
  settings, points per gold of value, default 1, `Guild:SetDonationRate` the one writer, sent as a
  real number and applied only when carried and within bounds; **written by bankers and officers,
  never the member** -- each writer keeps ITS OWN ledger (`Info.donationLedger[writer]`, written
  only by this account's characters: `opening` balance, capped `entries`, a version) and publishes
  only its own totals (`donation-points` on `togbank-hl`, on change debounced to one broadcast per
  mail and on the periodic settings cycle); a receiver stores a bucket only from a banker, officer
  or GM, only for the SENDER's own name (a relay cannot speak for another writer), never for one of
  its own characters (the ledger is the source), only when newer, sanitized and capped at 500
  donors; a balance anywhere is the sum across writers; **adjustments carry a reason** --
  `/togbank donations adjust <name> <points> <reason>` for an officer (`CanViewOfficerNote`, the
  same test as the shop list), negative allowed, refused without a reason; **no retroactive
  valuation** -- the old vendor-valued scores are carried into each banker's opening balance the
  first time that character runs the build (`Donations:MigrateOwnLedger`, own character only, once)
  and are never re-valued; a not-yet-migrated character's `alt.ledger` still counts on the board
  until then. Q7 of the design's open questions (the donation half) is settled here rather than
  asked: an item no source can price is credited at the vendor floor, never refused, and an item
  with no value at all is logged at 0 points so the receipt exists. The log is capped at 300 entries
  per writer; what falls off rolls into the opening balance first, so a total never moves because
  the log was trimmed. One hazard the old code had and this build closes: `Mail:Open` takes one
  thing per call and re-enters itself a second later so the server can act; when the server had not
  cleared the money by then the header still showed it and the score was added AGAIN -- with a
  permanent ledger entry that matters, so the money of one mail is credited once (same sender and
  amount inside a 10 s window is the same mail; the repeat take is harmless and still happens). The
  **Donations** window reads the summed balances, says "Points" instead of
  "Score", and its status line carries your own balance and the rate -- and it has a way in again:
  its button on the old Inventory window was removed on 2025-12-22 ("causes confusion") and NOTHING
  has opened it since, which the self-audit of this build found (`UI_Donations:Toggle` / `:Open` had
  no call site in the shipped modules); `/togbank donations window` is the one entry point now, the
  button stays gone, and `donations_spec` counts the call sites so the window cannot go dead again
  unnoticed. `/togbank donations` prints the board and your balance; `donations <name>` one member;
  `donations log [<name>]` your own entries, newest first, with source and statistic. "Donation points per gold" sits with the shop
  settings in the options (officer-only) but is NOT gated by the shop switch: the board existed for
  plain banks before the store did. Not built (design 4.7, first version): spending points, a
  not-accepted-for-points list, an officer review threshold. Offline: `donations_spec` -- the
  ladder (conservative order, market never asked, the floor, a throwing library, nothing values
  it), the rate and its bounds, the ledger (once, locked against a rate change, the cap rolling
  into opening, the migration once and own-character-only), balances across the three kinds of
  bucket with the own ledger winning, the wire on the real Guild + Chat dispatch + Core envelope
  (publish, receive, version order, writer == sender, a member's publication refused, an officer's
  accepted, own-character buckets never overwritten, sanitizing, the cap, the rate riding the
  settings), the real `Mail:Open` against the harness inbox (money then item on the retry, a slow
  server's retry crediting once, the vendor floor with no library, "Add to score" off and a
  banker's own mail credit nothing), and the command. 100% line coverage on the module; suite
  1742/0. NOT SEEN IN GAME. Locations:
  `Modules/Donations.lua` (new, in both TOCs after RequestLog), `Modules/Mail.lua`,
  `Modules/Guild.lua`, `Modules/Chat.lua`, `Modules/Events.lua`, `Modules/Options.lua`,
  `Modules/UI/Donations.lua`, `Modules/Constants.lua`.
- **STORE-003: the shop discount.** The operator, on seeing the Shop tab in game (the first
  sighting of SHOP-TAB-001): *"now we need to set a % discount for the items. like if you want to
  sell all the items at 50% off, we need to apply that to the pricing that is displayed on the shop
  tab."* Build-order step 8 of `docs/GUILD_STORE.md` (4.3), pulled forward because it is a number
  applied at display, not a published list. **Shop discount** is a 0-100 slider under the shop
  settings in the options (officer-only, greyed while the shop is off); `Guild:SetStoreDiscount` is
  the ONE writer (floors to a whole percent, refuses out-of-range, broadcasts at ALERT, prints the
  chat line, repaints an open Shop tab); `Guild:GetStoreDiscount` reads 0 with the shop off and
  keeps the stored number; the settings broadcast carries `storeDiscountPercent` as the STORED
  number and a receiver applies it only when carried and in range, repainting its own open Shop
  tab. On the tab: the **Est.** column shows the DISCOUNTED figure (`Browse:Discounted`, floored),
  the market figure rides on the row for the hover -- "Estimated ~6g 17s (50% off ~12g 34s) -- min
  buyout, Auctionator, 2h 14m old" -- the status line wears the sign ("50% OFF -- 41 items, 12 with
  an estimate") so nobody reads a halved figure as the market, and 100% off reads **free** on a
  priced row while an unpriced row stays blank (`priced` marks a library answer independently of
  the value, so the count and the sort still treat a free row as priced). Never stored into a
  price and never charged: the banker's price at fill is the price (3). No rank tiers (4.3's
  extrapolation, open question 4). Offline: `requestchain_spec` (the writer's bounds and flooring,
  the wire, the peer, garbage and an old client leaving it, the shop off reading 0 with the number
  kept, the removal line); `browse_spec` (the halved column, the market figure and sort, the hover
  with the discount, the status sign, 100% off reading free, the redraw under an open tab).
  Locations: `Modules/Guild.lua`, `Modules/UI/Browse.lua`, `Modules/Options.lua`.
- **BANKER-OWNER-001: officers say who runs each bank character; the Bankers tab hover shows
  it.** The operator, 2026-09-14: *"the ability for officers to right click on a banker in the
  bankers tab to assign who 'owns' the banker, that info would show on the mouseover tooltip.
  this should be autocomplete for the names on the roster in guild roster but it can be free text
  entry as some guilds like ours have a 'shared' account for the banker."* `Guild:SetBankerOwner
  (norm, text)` is the ONE writer (normalises the banker, trims, caps the text at 40, "" clears,
  refuses a 101st entry, broadcasts at ALERT with the SETTINGS-002 stamp, prints the line,
  repaints an open Bankers tab); `Guild:GetBankerOwner(norm)`; `Info.settings.bankerOwners`
  rides the guild-settings broadcast always as a table (empty = nobody listed, so a receiver can
  tell "cleared" from "predates the field"), applied only when carried and sanitized on the way
  in (`sanitizeBankerOwners`: string keys, trimmed non-empty strings, capped). On the Bankers
  tab a right click on a row is the officer's dialog (a member gets a status-line word): one box
  holding the current value, Save / Clear / Cancel, Enter saves, Escape closes. The box is the
  client's own `AutoCompleteEditBoxTemplate` fed by `Browse:OwnerNameSource` -- every roster the
  guild-roster library holds (home and sister guilds), same-realm names bare, prefix-matched,
  sorted, capped, in the client's `{ name, priority }` source shape with `Enum.AutoCompletePriority`
  (the LE_* globals are deprecation fallbacks, and a priority the colour table lacks raises inside
  Blizzard's own code) -- so Tab/arrows/Enter complete a guildmate's name exactly as the mail
  frame's recipient box does, and anything else is accepted as typed. Feature-detected: a client
  or harness without the template gets a plain box. The hover: *"Run by X"*, the grey state's
  sentence, and the officer's gesture. The dialog reads the LIVE value, not the row's snapshot
  (the first cut showed the old owner on a second open after a save). Offline:
  `requestchain_spec` (the writer's trim/cap/clear/no-change/101st, the broadcast table, a peer
  applying it sanitized, the cap on receive, an old client's broadcast leaving it); `browse_spec`
  (the row's owner, the hover lines for a member and an officer, a member's right click refused,
  the dialog's box and prompt, Save and Clear through the writer, a refusal keeping the dialog
  open, a peer's change repainting; the name source's bare/realm rule, sister rosters, the cap,
  no library). Locations: `Modules/Guild.lua`, `Modules/UI/Browse.lua`, `.luacheckrc`,
  `.luarc.json`.
- **SHOP-NOFREE-001 / STORE-004: while the bank is selling, every request is a shop order that
  carries the estimate the member was shown.** The operator, 2026-09-14: *"when the shop tab is
  shown and ordering is enabled, there should be no 'free' item requests."* Until this, the Browse
  tab, the Search window and the old Inventory window all opened the same request dialog and
  minted the same record whether or not the shop was on -- a request placed from the Browse tab
  while the shop sold was a plain-bank request past the price, and nothing on the record said
  what the member had been shown. Now: `Guild:IsShopSelling()` is the ONE spelling of "shop on
  AND ordering open"; the request dialog, with the shop on, marks every order it builds
  `shopOrder = true` wherever the row came from, prices the item through the Shop tab's own call
  (`Browse:PriceOne`, the same library lookup and discount as the rows, so the dialog cannot show
  a figure the tab did not) and writes what it showed onto the record -- `estimate` (copper,
  after the discount), `estimateBase` (the market figure), `discount` (the percent),
  `estimateSource` ("min buyout, Auctionator") -- with a line under the prompt: *"Shop order --
  estimated ~6g 17s each (50% off ~12g 34s) (min buyout, Auctionator). The bank character sets
  the final price when your order is filled."* An unpriced item is still a shop order, says *"no
  estimate for this item yet"*, and is priced at fill as every order is (GUILD_STORE.md 3: the
  banker's price is THE price; the fields are a record of what was shown, never a price, 4.4).
  `Guild:AddRequest` is the gate: selling and no mark, refused, nothing on the wire -- so no
  surface, present or future, mints a free request past the shop. The gate is the MINTING side
  only: a plain request arriving on the wire from an older client is merged as before. Both
  wires carry the fields -- the `togbank-rm` mutation (the whole record) and the positional
  `togbank-rd2` record as five appended optional slots `arr[15]..arr[19]`, absent or `false` from
  an older client and read as unmarked; one `sanitizeEstimate` normalises both (a non-boolean
  mark is no mark, garbage numbers drop, an empty source drops, a source is capped at 64 bytes).
  The Requests tab's timeline tooltip on the date grows a line for a shop order: *"Shop order:
  estimated ~6g 17s (50% off ~12g 34s) each -- min buyout, Auctionator, at order time"*, or
  *"no estimate at order time -- priced by the bank character at fill"*. Shop off, or ordering
  closed: the plain bank's free requests are unchanged. KNOWN COST, stated: the estimate is the
  REQUESTER'S client's price data (STORE-001 prices on the viewer's own ItemDB sources), so two
  members with different sources record different estimates for the same item -- the published
  guild price list (STORE-002, now DONATION-VALUE-001) is what makes it one figure. Offline:
  `requestchain_spec` (IsShopSelling's truth table; the gate refusing a plain and a non-boolean
  mark with nothing on the wire; a shop order minted with its fields; the sanitizer; the rm wire
  to a peer; the rd2 round trip -- the FIRST example ever to drive the positional record end to
  end, REOPEN-001's `arr[14]` included -- and an older client's 14-slot record reading as
  unmarked; a wire-received plain request not refused); `browse_spec` (the REAL dialog built and
  submitted -- the first example to drive `Search:SubmitRequest` at all -- with the marked and
  priced order, the unpriced order, no discount, the shop off adding nothing, a refused submit
  keeping the dialog open; `Browse:PriceOne`; the timeline tooltip's shop line and its absence on
  a plain request). Locations: `Modules/Guild.lua`, `Modules/RequestLog.lua`,
  `Modules/UI/Search.lua`, `Modules/UI/Browse.lua`, `Modules/UI/Requests.lua`.
- **STORE-002 / DONATION-VALUE-001 (b): ONE guild price list, published by an officer-named price
  authority, so every banker values a gift the same and every member sees the same estimate.** The
  operator, 2026-09-14, on two bankers valuing one donation differently: *"we need a way to
  determine what the value is so any banker applies the same value. need some way for me with TSM
  to sync my TSM values with other folks that don't sync up. especially the bankers, so we're all
  using the same value."* Until this, STORE-001 and STORE-007 priced on each VIEWER'S OWN ItemDB
  sources -- a banker without TSM valued a gift at its own scan or the vendor floor while the
  operator's client would have said something else, and the ledger is permanent, so the
  disagreement was forever. Now, to `docs/GUILD_STORE.md` 4.2.1 (decided the same day): **Price
  authority** is an officer setting under the shop settings (`Guild.Info.settings.priceAuthority`,
  `Guild:SetPriceAuthority` the ONE writer, a bare name normalised, "" clears; on the settings wire
  always as a string so a receiver can tell "cleared" from "predates the field", SETTINGS-002
  stamped, applied only when carried). ONLY that character's client publishes;
  `Modules/PriceList.lua` (new, `TOGBankClassic_PriceList`, both TOCs after Donations) builds the
  list from the store's union of item ids -- `sell` from ONE bulk `GetPrices` at the account's
  default statistic (what the Est. column shows), `value` from the donation ladder
  (`Donations:OwnValue`, min buyout then historical, never market; the same ladder the ingest used,
  lifted out so it is one function) -- with each figure's statistic and the source's observation
  time. The wire is `togbank-pl` (registered in `COMM_PREFIXES` and `COMM_PREFIX_DESCRIPTIONS`),
  GUILD at BULK, positional chunks of 100 items: `{ 1, version, publisher, i, n, count, then id /
  sell / stat / value / stat / age x6 per item }`, `false` for an absent figure, the version the
  authority's server time. A receiver applies a chunk only from the NAMED authority naming itself
  as publisher (a relay cannot speak for it), only a version newer than the held one, sanitized
  (integer ids, positive integer figures, statistic codes it knows, capped at 5,000), assembles all
  n chunks before installing `Guild.Info.priceList` (SavedVariables, so a member who logs in while
  the authority is away still has the last list), and treats a list left by a FORMER authority as
  no list. **Nothing unchanged is ever re-sent:** the authority's hlb2 broadcast names the version
  it holds (`pl`), a client behind it asks by whisper (`togbank-plq`, once per announced version per
  five minutes) and is answered by whisper (at most once a minute per asker); a CHANGED list
  publishes at login, when ItemDB fires `LibItemDB_ScanComplete` / `_PriceSettingsChanged`
  (debounced 10 s), when the setting names this client, and on the ten-minute cycle at most once
  an hour. **Who reads it:** `Browse:PriceRows` / `PriceOne` (the Shop tab, the request dialog's
  estimate) take the guild's sell figure FIRST and ask their own library only for the rows the
  list lacks; `Donations:Value` credits at the guild's value figure first, the vendor floor still
  applying; provenance `{ source = "guild", sourceName = "guild list (Name)", statistic, age }`
  so the hover and the ledger entry read *"min buyout, guild list (Pimptasty), 3h old"*, and the
  Shop tab's status line names whose list and how old. **ItemDB's fed source** (LIBREQ-PRICE-011,
  `StoreExternalPrices` / `ClearExternalPrices`, feature-detected -- not yet delivered by ItemDB) is
  filled with a received list and cleared when the authority is cleared, NEVER on the authority
  itself (its sources are the list; a fed copy ranked first would have the next build read
  yesterday's figures back). KNOWN COST, stated: the authority's absence freezes the list at its
  last publish and the hover says the age. Offline: `pricelist_spec` (19, on the real Guild + Chat
  dispatch + Core envelope: the writer and the settings wire, the build, the chunks' exact slots,
  the unchanged / hourly / at-once publish rules, ItemDB's events through the debounce, assembly,
  every refusal, garbage slots, a repeated and a superseding chunk, a former authority's list, the
  announce and the ask both ways with their cooldowns, both consumers consult-first, the ItemDB
  feed); `Modules/PriceList.lua` at 100% lines. Suite 1784/0. NOT SEEN IN GAME. Locations:
  `Modules/PriceList.lua`, `Modules/Guild.lua`, `Modules/Donations.lua`, `Modules/UI/Browse.lua`,
  `Modules/Chat.lua`, `Modules/Events.lua`, `Modules/Options.lua`, `Modules/Constants.lua`,
  `Core.lua`, both TOCs, `.luacheckrc`, `docs/GUILD_STORE.md`.

### Improvements

- **MAIL-SPLIT-MERGE-001: a split lands on the order's own partial stack (one attachment, one
  postage).** `CalculateFulfillmentPlan` records `splitStack.onto` (an attached stack of the same
  itemID with room under GetItemInfo's max stack); Fulfill Oldest and the row popup drop the split
  there, ATTACH waits for the merged count and (any split) an unlocked slot, a merged split takes no slot (`tog_planSlots`), and a
  changed stack restarts the batch / falls back to a free slot. `multifill_spec` +7 (5 red with the
  merge off). NOT SEEN IN GAME. `Modules/Mail.lua`.
- **DONATION-VALUE-001 (a): the gold behind the points is on the board.** The operator,
  2026-09-14: *"we need to flesh out the donation points = to gold value now that we have the
  monetary tie in to ItemDB."* Each writer's published bucket now carries `values`
  (`{ [donor] = copper }`, `Donations:LedgerValues`) beside `totals`, summed from every credit's
  locked copper; an adjustment (points by an officer) and a carried-over score have no value and
  contribute none; a credit that rolls off the 300-entry log moves its copper into
  `openingValue` with its points, so neither total moves. Received buckets keep `values`
  sanitized (`SanitizeValues`: non-negative integers, capped); a pre-VALUE sender's bucket is
  valueless, never zero-valued. `Donations:Values()` / `ValueOf(name)` sum across writers as the
  points do; the scoreboard rows carry `copper`. The Donations window gains a **Value** column
  ("2g 55s", `Donations:FormatGold`, gold to the copper) and its status line says what you gave;
  `/togbank donations` and `donations <name>` print "(3g given)" beside the points. **A defect
  fell out:** the window showed points through `math.ceil`, so a member with 0.05 points read as
  1 -- it shows the figure to two decimals now. (b) -- ONE guild price list so every banker values
  a gift the same -- is designed in `docs/GUILD_STORE.md` 4.2.1 and contracted to ItemDB
  (`LIBRARY_CONTRACTS.md` 7.14, thread `a22a217cba3e`); its build is the next session's. Offline:
  `donations_spec` (values per credit, the roll-off, the wire, a member summing a banker's values,
  a pre-VALUE bucket, sanitizing, the gold figure, the command's "(3g given)"). Locations:
  `Modules/Donations.lua`, `Modules/UI/Donations.lua`, `Modules/Chat.lua`, `docs/GUILD_STORE.md`,
  `docs/LIBRARY_CONTRACTS.md`.
- **SHOP-FILTERS-001: the Shop tab carries the Browse tab's filters.** The operator, 2026-09-14:
  *"the shop needs the same filters as the browse tab, to allow folks to find stuff."* The Shop
  tab's strip was a lone search box over a 1,500-item catalogue. Now it is the Browse strip --
  search, Bank, Type, Subtype, Slot, Quality, Min/Max level, Usable by me, Clear -- from ONE
  builder (`Browse:BuildCatalogueStrip(filters, redraw, placeholder)`; `BuildFilterStrip` and
  `BuildShopStrip` are one-line callers), on the shop's OWN filter table (`shopFilter`, a full
  `BrowseFilters`), so narrowing the shop leaves Browse alone, a bank picked on the Bankers tab
  still lands on Browse, and each tab's Clear clears its own (`ClearFilters(f)`). The shop list
  hangs under the two-row strip at Browse's height. The status line says "N of M items" whenever
  the filters narrow, whatever the price library's state -- a narrowed shop with no library used
  to read as the whole shop. Offline: `browse_spec` (the two strips are the same widgets in the
  same order, at the two-row height; type, level and text narrow the shop through the same
  `FilterRows`; each tab's Clear resets only its own table). Locations: `Modules/UI/Browse.lua`.
- **UX-WATERFALL-001: the Browse and Shop tabs read as a waterfall -- Type, Qty, Lvl, Item, the
  sync dot, Banker.** crimsonmane, on Discord, the day after v1.5.1: *"Everyone loves the new
  togbank UX, they say it's very CLEAN ... I noticed I'm looking from the far left (item name) to
  the middle (qty) and far right (level) zig-zagging my eyes constantly ... If the meaty parts of
  the line were LEFT of the Item Name, the eyes would not need to dart around so much ... Columns
  could be (left to right) Type - Qty - Level - Item Name - Sync'd Bulb - Banker"*; the operator:
  *"lets implement it if we can."* The fixed, narrow facts now sit left of the name, the name is
  the one auto-width column mid-row (RowList already chains fixed columns on both sides of it),
  and the bank's status dot is its OWN 14px column beside the banker -- `sync`, sortable, worst
  first -- rather than a prefix on the banker's name. The Shop tab is the same waterfall with
  **Est.** last. The six column specs are shared tables between the two lists (RowList never
  writes to a spec). Offline: `browse_spec` (the exact key order of both lists, one auto column,
  the dot rendered in its own cell and absent from the banker's, the sync sort rank). Locations:
  `Modules/UI/Browse.lua`.

- **STRIP-SIGN-001: the Ordering open box is gone from the Shop tab's strip.** The operator, on a
  screenshot of the strip the same afternoon: *"we can remove the ordering open check box here,
  the one in settings is enough."* The strip is the search box; the officer's three shop controls
  (the switch, the sign, the discount) are all under the shop settings in the options and only
  there. `Guild:SetStoreOpen` stays the one writer; `browse_spec` now refuses the box's return and
  pins the strip at one child. Locations: `Modules/UI/Browse.lua`.
- **QTY-CENTER-001 / HEADER-ALIGN-001: every list heading sits over its column's numbers.** The
  operator, with three screenshots in a row: *"both in the shop and browse tabs, the qty is WAY to
  the right, can you have it centered UNDER the Qty header?"*, then *"qty aligns, but the Lvl
  doesn't, align those as well"*, then on the Bankers tab *"the same with the items and money
  column data and headers, they don't align"*. One cause: the RowList always left-justified a
  heading while the cell honoured the column's `justify`, so every right-aligned number sat a
  column's width from its heading. A heading now takes its column's `justify` (`headerJustify`
  overrides it when a column wants otherwise), and the sort arrow sits beside the text wherever
  the text is -- after it for LEFT, past the centred text for CENTER, before it for RIGHT. So Lvl,
  Est., Items, Money and the Requests tab's numeric columns right-align over their figures, and
  Qty is centred on the Browse and Shop tabs. Offline: `browse_spec` (heading and cell alignment
  per column, the override, the arrow's anchor for all three, the Qty specs). Locations:
  `Modules/UI/RowList.lua`, `Modules/UI/Browse.lua`.

### Bug Fixes

- **VER-REPLY-001: a version reply about one bank no longer settles an open query about another
  bank to the same peer.** Found by DeltaSync's self-audit of its port of this code (thread
  `c20eb5b527e1`, reply 41b1dd7a, 2026-09-15) -- the shape was TOGBank's. `P2PSession:OnVersionReply`
  marked EVERY outstanding query to the replying peer as answered, so with two queries open to one
  peer (bank X from the collect round, bank Y from a late offer) the reply about X marked Y's
  candidate "answered, holds nothing": Y's holder was dropped, the query was judged on nothing, and
  the fetch went round a retry cycle for a bank the peer held all along. Now `HandleVersionQuery`
  echoes the numbers it was asked (`n`) beside the entries, and `OnVersionReply` settles only those
  banks; a reply without `n` -- a pre-1.6.0 client's -- is read the old way, so a mixed guild loses
  nothing it had and gains the fix as clients update. Pinned in `p2psession_spec` (the two-query
  case, watched go red with the fix removed; the old-client case; the echo). Locations:
  `Modules/P2PSession.lua`, `Modules/Chat.lua`.
- **Peer Review f5e52bcf (2026-09-15), ten findings on the v1.6.0 tree, acted on.** Each fix
  carries the review's number in its comment; the reviewer's failure scenarios are the ones
  pinned.
  - **SETTINGS-003 (F1, HIGH): an officer's settings write, and its donation bucket, were DROPPED
    by every receiver ranked below the writer -- the GM's client and every member included.**
    `memberRoster.isOfficer` was built from a threshold equal to the LOCAL player's own rank (nil
    when it cannot view officer notes), so a receiver trusted only ranks at or above its own: the
    GM trusted rankIndex 0 alone, a member trusted nobody but the GM. An officer closing
    ordering saw "syncing to guild..." and nothing reached anyone. The client's rank permissions
    ARE readable -- `C_GuildInfo.GuildControlGetRankFlags` exists in the Era client
    (`GuildInfoDocumentation.lua`; REQSYNC-008's "Retail-only" was true of the bare global) --
    but Blizzard's own Era code reads it only from the Guild Control UI (the GM's) and nothing
    documents what a non-GM's client gets, so ONLY the GM's client reads it:
    `Guild:ReadOfficerRankFloor` derives the highest rank whose flags say View Officer Note
    (index 11) and `PublishOfficerRankFloor`, after every roster build, broadcasts it as
    `officerRankFloor` on the synced settings when it differs; `ApplyRemoteSettings` adopts that
    field from a GM sender ALONE (rankIndex 0 is the one rank every client can judge);
    `SenderIsOfficer` unions the published floor with the cache-time threshold, which stays as a
    lower bound. KNOWN COST: until the GM has logged in once on this build, nothing changes --
    the old threshold rule stands. The spec runs the REAL roster and predicates (the review's
    point: every earlier wire example ran on a stub of the predicate that was wrong):
    `Tests/settings_spec.lua`. Locations: `Modules/Guild.lua`, `.luacheckrc`, `.luarc.json`.
  - **LEDGER-PC-001 (F2, HIGH): a shared banker account on several PCs -- the operator's own
    guild (MULTIPC-001) -- had each PC's donation publish ERASE the other PCs' credits from every
    board, for ever.** The ledger lives in one PC's SavedVariables and the writer key was the
    character alone: PC2's first credit published a bucket at a newer version under the same
    key, every client replaced PC1's bucket with it, and PC2 could never learn PC1's entries
    (the same account is never online twice; a relay may not speak for another writer). The
    writer is now the character ON A MACHINE, `Name-Realm@<machine id>` (`Donations:Writer`; the
    id minted once into the account-wide db as `donationMachineID`), each PC its own bucket,
    balances the sum across writers as they already were; `Receive` checks the CHARACTER half
    against the sender and keeps the machine half; a ledger this PC wrote under the bare key
    (this unreleased build) moves under its writer key once (`MigrateOwnLedger`). KNOWN COST: a
    PC's own board lacks the other PCs' credits for its character -- nothing can hand them to it
    -- while members hold every PC's bucket. `Modules/Donations.lua`, `Tests/donations_spec.lua`.
  - **F3 (HIGH): the popup's Scan compared the header's BARE sender against the `Name-Realm`
    banker set, so a bank-to-bank transfer opened the Donation popup** (the CREDIT was already
    kept out by `IsDonation`, which normalises -- found and fixed 2026-09-14). The Scan filter
    normalises too. `Modules/Mail.lua`.
  - **F4 (HIGH): the retry double-credit closed for money was open for items.** `Mail:Open`
    credits, takes, and re-enters a second later; a slow server still showed the attachment and
    it was credited AGAIN -- the harness's `TakeInboxItem` only records the take and never
    removes the item, so the suite could not see it (every ingest example used one attachment).
    `CreditItem` now takes the mail slot and refuses the same sender + slot + link + count inside
    the ten-second window, mirroring `CreditMoney`; the two-attachment example drives the retry
    against a stack still in the mail. KNOWN COST, the money guard's: two identical gifts in two
    mails taken inside ten seconds credit once. `Modules/Mail.lua`, `Tests/donations_spec.lua`.
  - **SETTINGS-004 (F5, MEDIUM): SETTINGS-002 stopped a stale re-announcement, not a stale
    WRITER.** An officer who missed Monday's "ordering closed" and set the discount on Tuesday
    stamped the whole payload fresh, and every client adopted the stale `storeOpen = true` it
    carried with the new discount. Each field now carries the server time of the write that
    last changed IT (`settings.stamps[key]`): an ALERT broadcast diffs the payload against the
    last one this client sent or applied (`lastSettingsPayload`, a deep copy -- Requests.lua
    mutates `cancelReasons` in place) and stamps only the keys that moved, so none of the
    fifteen writer sites change; a receiver adopts field by field (`adopt(key)` in
    `ApplyRemoteSettings`), and a field the payload carries no stamp for is of unknown age (0)
    -- it can seed an empty client and displaces nothing. A pre-004 sender (no `stamps`) is
    still judged whole on its version, as before. `Modules/Guild.lua`, `Tests/settings_spec.lua`.
  - **F6 (MEDIUM): the Shop tab was not repainted when data landed, and the two row handlers
    the lists share (hide, not-for-sale) repainted the hidden Browse list from it** -- an
    officer's Ctrl+right-click on the Shop tab said "off sale" in chat and the row did not
    change until a tab switch. One `Browse:RedrawCurrent` (Browse or Shop, whichever shows),
    called by `Refresh` and both handlers. `Modules/UI/Browse.lua`, `Tests/browse_spec.lua`.
  - **DONOR-KEY-001 (F7, MEDIUM): three spellings of one donor split the board.** The header's
    bare name, a cross-realm `Name-Realm`, and an officer's typed `alice` each made their own
    row, and an adjustment landed under a name nobody searched for. `Donations:DonorKey`: the
    bare name; a name differing from a donor on the board only in case IS that donor (matched
    against the held keys, not folded -- Lua's `lower` is byte-wise); a new name is written as
    WoW spells names. Applied in the two writers (`Credit`, `Adjust`) and the two lookups.
    `Modules/Donations.lua`, `Tests/donations_spec.lua`.
  - **F8 (LOW): the Donations window walked the SORTED board with `pairs`**; `ipairs`, so the
    rank numbers mean what the sort meant. (The `math.ceil` half of F8 was fixed 2026-09-14.)
    `Modules/UI/Donations.lua`.
  - **F9 (LOW): the request gate's refusal lost its sentence.** `Guild:AddRequest` now returns
    `false, <reason>` at every gate (view-only, ordering closed, not for sale, shop order
    required) and the request dialog shows it -- the race the gate exists for (an officer closes
    ordering between the dialog opening and the Send) used to read "Unable to send request."
    `Modules/RequestLog.lua`, `Modules/UI/Search.lua`, `Tests/browse_spec.lua`,
    `Tests/requestchain_spec.lua`.
  - **F10 (LOW): two comments corrected** -- `Browse:Discounted` floors at 0 (it never held to
    "1 copper"); `RowList`'s `headerJustify` defaults to the column's `justify`, not LEFT.
  - **SUITE-TIME-001 (the reviewer's "the full suite hung, twice"): 10 min 48 s -> 3 min 57 s.**
    Measured by bracketing the run with file mtimes (the runner prints no duration), then
    bisected: every batch took seconds alone and the same files minutes together. The cause was
    `Tests/output_spec.lua`'s two seven-day `env.advance(persistentLogMaxAge + 1)` calls -- my
    ENV-MIGRATION rewrite of 2026-09-14 -- which the harness slices at 0.05 s, running every live
    frame's `OnUpdate` per slice: 12 million slices times every load-time library frame earlier
    files left alive (`wow.frames` is weak-valued and those persist for the session). ~10 s
    alone, ~7 min at its place in the full run. The clock is SET now (`env.now = env.now + ...`);
    two smaller advances (`output_spec`, `canontime_spec`) likewise. Found on the way:
    `xguild_spec`'s Guild-only fixture passed in the full suite on a `TOGBankClassic_Bank` an
    earlier file left behind (the SETTINGS-003 roster hook reaches `GetPlayer`); it stubs the two
    accessors now. `Tests/output_spec.lua`, `Tests/canontime_spec.lua`, `Tests/xguild_spec.lua`.
  - **Sideways, from this session's own audit: "a stub does not count" was spelled four times**
    (`IsInCurrentGuildRoster`, `GuildOf`, `IsHomeMember`, `SenderIsOfficer`), each its own chance
    to forget the rule that stopped a sender becoming one of us by sending. One
    `Guild:RosterEntry(norm)` -- the memberRoster entry, or nil for a stub -- read by all four.
  - **SPEC-ORDER-001: the suite was green by accident of the alphabet.** Run in REVERSE file
    order, 36 examples in eight files failed; every one passes alone. Four order dependencies, all
    fixed, both orders now 1811/0. (1) AceGUI's files capture `CreateFrame`/`UIParent` at load and
    Ace3 loads once per run, so the FIRST file to load it decides the frame model every widget in
    the run is built on -- forwards that was `browse_spec` (rich model); backwards a hollow-model
    file, and every later `Release()` died in `frames.lua:692`. `env_togbank` now requires
    `env.frames` and loads AceGUI at its own load, before any spec, and `env.loadUI` goes through
    the harness loader instead of loadfile-ing the core alone (ACEGUI-BIND-001). (2) `scan_spec`
    never loaded `Modules/Constants.lua`, which `Scan.lua` reads at load; 22/22 red alone. (3)
    `multifill_spec` replaced `MailFrame` with a bare table and never handed it back; `Mailbox.lua`
    reads its frame level. (4) The Blizzard-options hand-back after `Options:Init` was spelled in
    two files and missing from `searchbox_spec` -- one `env.releaseBlizOptions()` now, called from
    all three. Also `propagation_spec` asserted `GetTime()` arithmetic exactly; `assert.near`, since
    the harness clock never rewinds across files. `Tests/env_togbank.lua`, `Tests/scan_spec.lua`,
    `Tests/multifill_spec.lua`, `Tests/searchbox_spec.lua`, `Tests/raidvisibility_spec.lua`,
    `Tests/mailbox_spec.lua`, `Tests/propagation_spec.lua`.
  - **Harness pin 557390a -> 830dab2 (WoWAPITesting delivered the six ENV-MIGRATION gaps, inbox
    `91731fa6`).** The six stand-ins `Tests/env_togbank.lua` carried for them are deleted: item
    links to `GetItemInfo`/`GetItemInfoInstant`, `C_Item.GetItemNameByID` /
    `GetItemInventoryTypeByID`, `GetMoney` (`env.money` now proxies `wow.money`), `GetClassColor`,
    `C_CurrencyInfo.GetCoinTextureString` + `ITEM_UNIQUE`, and the scanning `GameTooltip`
    (`env.tooltipLines/Link/Added` are gone; `SetHyperlink` fills from the item's `tooltipLines`,
    the addon's `AddLine` lands below and `GetLines` counts both). What went red and why: the coin
    string is now the client's SPLIT figure (`1g 23s 45c` with icon escapes), so three assertions
    that looked for `12345` look for the three parts; `Item:IsUnique` on the hollow frame is the
    `'for' limit must be a number` the harness warned of, so its examples and the tooltip-hint
    example load `env.frames` -- and **IsUnique gets its first positive example** (a `Unique` line
    found, a plain item not, an uncached link not, a non-English `ITEM_UNIQUE` honoured). Also
    `mailbox_spec` pins `TOGBankClassic_Mail = nil`: `TakeRow` feature-detects it for the credit,
    and the examples were taking whichever an earlier file left. Both orders 1812/0.
    `Tests/env_togbank.lua`, `Tests/item_spec.lua`, `Tests/hideitems_spec.lua`,
    `Tests/mailbox_spec.lua`, `Tests/browse_spec.lua`.
  - **SHOP-SECTION-001 (the operator, 2026-09-15, a screenshot of "Ordering open" under Maximum
    Request Amount: "this is for shop orders correct, not for non-shop orders? if so, we need to
    clarify that, as it could be confusing. maybe we make a seperate shop section in the officers
    tab").** Traced before answering: `Guild:IsStoreOpen` answers open whenever the shop is off,
    and with the shop on every order is a shop order (SHOP-NOFREE-001) -- so the sign governs shop
    orders and nothing else, and the confusion was placement and wording, not behaviour. The
    Officer tab is now three sections by `order`: the request settings end with their example box
    (moved from order 4 to 3.1); a **Shop** header + description (3.2, 3.3) carries the switch,
    the sign (renamed **Shop ordering open**, its tooltip saying SHOP orders and that a plain
    bank's requests never see it) and the discount; a **Donations and pricing** header (3.58) sets
    the rate and the price authority apart, since neither is gated by the shop. The closed-ordering
    sentence and the chat lines say "shop ordering" too. Pinned by `Tests/optionslayout_spec.lua`
    on the real options table. `Modules/Options.lua`, `Modules/Guild.lua`, `Tests/browse_spec.lua`,
    `docs/Curseforge_Description.html`.
  - **COL-FIT-001 (the operator, 2026-09-15, a screenshot of "Armor / Miscellaneous" ending a
    third of the way across the Type column: "could we get rid of some of the white space between
    the type/qty/lvl columns? i don't want to get rid of it completely, there is just a lot of
    'wasted' space. look at the longest entries, and make it a little longer").** The Type and Qty
    columns on the Browse and Shop tabs are sized to the LONGEST text in the whole catalogue (every
    bank, before the filters, so a narrowing filter does not move them) plus 10 px, floored at what
    the heading and its sort arrow need (60 / 40) and capped at the old fixed widths (150 / 44) --
    a locale or a guild whose longest type is "Consumable / Item Enhancement" is exactly where it
    was. Measured in the cells' own font (`Browse:TextWidth`, one hidden FontString). RowList gained
    `SetColumnWidths`, which re-anchors the header and every row cell through the one placement
    walk, and each list now holds its OWN copy of the column specs -- Browse and Shop share `TYPE_COL`,
    and a width written on the shared table by one list would have become the other's next layout.
    Lvl stays 34 (two digits fit it); the gaps stay 4 px. `Browse:TextWidth` memoises per text:
    the fit runs on every redraw, a keystroke in the search box being one, over every catalogue row,
    and the type texts are a few dozen distinct strings across thousands of rows.
    `Modules/UI/Browse.lua`, `Modules/UI/RowList.lua`, `Tests/browse_spec.lua`.
  - **LIBREQ-DS-009 ADOPTED (DeltaSync MINOR 18, from its working tree -- LIB-RELEASE-ORDER, the
    operator: "i'll release DS Library AFTER YOU ARE DONE").** The P2P send slot's release rides
    `SendData`'s trailing `onComplete(info)`: one completion per send, `verdict` delivered /
    refused / not-attempted, the not-attempted case covering both Core's raid guard and the
    library's own pre-transport declines (the requester logged off). Nothing reads `SendData`'s
    return any more -- the library reports every way out through the callback, so a release on
    `false` too would give the slot back twice. **The DS-HOST-002 proxy watcher is deleted**
    (`Core:WatchHostSend` / `UnwatchHostSend` and the chained `onResult`); the transport object
    forwards the two methods and nothing else. `Tests/statesummary_spec.lua`'s "host refuses
    before the transport" example, which drove a `false` return with no completion -- the very
    contract shape DS-009 forbids -- now drives the real library's not-attempted path and a
    contract-honouring double of its decline, asserting ONE release each. `Core.lua`,
    `Modules/Inventory/Sync.lua`, `Tests/statesummary_spec.lua`, `Tests/chainwire_spec.lua`,
    `docs/LIBRARY_CONTRACTS.md` 3.13.
  - **UNIQUE-EQUIPPED-001 (the operator, 2026-09-15, on the audit's F4: "we need to handle the
    unique differently, because they are donated but going to sit in the mail ... the unique items
    need to be counted in the mail, but only those").** `Item:IsUnique` matched the WORD anywhere
    on the tooltip, so "Unique-Equipped" -- a limit on what you wear, not what a bank can hold --
    was treated like "Unique": skipped by the mail scan's take, by bank collection, and never
    credited as a donation. It matches the WHOLE line now: `ITEM_UNIQUE` or the
    `ITEM_UNIQUE_MULTIPLE` shape ("Unique (n)"), plain-text either side of the number so a
    locale's magic characters cannot break it. A truly Unique gift still sits in the mail and is
    counted from there (unchanged); a Unique-Equipped one is taken, collected and credited like
    anything else. `Modules/Item.lua`, `Tests/item_spec.lua` (English and a non-English shape),
    `.luacheckrc`, `.luarc.json`.
  - **XGUILD-SWITCH-001 (the operator, 2026-09-15: "shouldn't there be some officer configuration
    to turn it on or make it work? we have the sister guilds in the guildroster library").** The
    sister-guild bank is an OFFICER SWITCH now -- **Sister-guild bank**, its own section on the
    Officer tab, off by default, guild-synced like the shop switch (`Guild:IsSisterBankEnabled` /
    `SetSisterBankEnabled`, the field `sisterBank` on the settings broadcast, adopted field-wise).
    Guild Roster's list says WHICH guilds are sisters; this says whether this bank crosses to them.
    ONE gate, `Guild:SisterGuildKeys`, read by every sister-facing walk (the member union, the
    banker union, the cycle's pull) and by `GuildOf`, so with it off a sister member is a stranger
    to every receive path and the Bankers tab shows the home guild alone; flipping it rebuilds the
    rosters at once. Each guild opens its own side. KNOWN COST: an existing federation goes dark on
    this build until an officer ticks the box -- there was no switch before, so nothing was on.
    `Modules/Guild.lua`, `Modules/Options.lua`, `Modules/UI/Browse.lua` (help), `Tests/xguild_spec.lua`,
    `Tests/optionslayout_spec.lua`, `Tests/env_fleet.lua` (fleet clients start with it on).
  - **Audit a228508b F3 closed: the Mailbox window's take through the REAL `Item:IsUnique` on the
    real scanning tooltip** -- a Unique item is taken and not credited, a stack is, and the same
    item without the Unique line IS credited, so it is the tooltip that decided. `env.reset({
    frames = true })` is the new spelling for a rich-model example that keeps this addon's fixture
    (the other order, `env.reset()` then `frames.reset()`, puts the harness defaults back over it).
    `Tests/donations_spec.lua`, `Tests/env_togbank.lua`.
  - **HELP-CURRENT-001 (the operator, 2026-09-15, the Bankers tab's "?": "it doesn't talk about the
    tooltip on banker names showing who owns the banker, lets get all the i tooltips updated on all
    the pages to be current").** Every "?" read against what its window now has. Bankers: the owner
    hover and the officer's right-click to set it, the Online / Items / Money columns, the sister-
    guild tag. Browse: the waterfall columns and the status dot's own column, the guild tag, the
    shop order and the (not for sale) mark, donation points. **Shop: its own text at last** -- it
    showed the Browse tab's -- the estimate and its sources, the discount, ordering closed, an
    officer's Ctrl+right-click, the shared filters. Requests: the Requests / Archive / Settings
    sub-tabs, the search and the two dropdowns, the guild tag, the estimate on a shop order's date
    hover, the amber old-version mark, the envelope and the broom. Search: the Slot dropdown, the
    tag, the shop order, and a pointer to the Guild Bank window. The old Inventory window says it
    is the old one (/togbank legacy) and where the new one is. Pinned by phrase in
    `Tests/browse_spec.lua` (all four Browse tabs, the Shop's text distinct from the Browse's) and
    `Tests/searchbox_spec.lua` (Requests). `Modules/UI/Browse.lua`, `Modules/UI/Requests.lua`,
    `Modules/UI/Search.lua`, `Modules/UI/Inventory.lua`.
  - **Sideways, from the review, NOT done here and why:** S1 (one `Guild:SetSetting` for the
    fifteen mutate-then-`BroadcastSettings("ALERT")` sites) -- SETTINGS-004 removed the reason it
    mattered most (the stamps are minted by diffing, not by the call), and a fifteen-site
    refactor of the settings writers on release eve is the wrong risk; filed. S2 (writers gate
    on the `IsBank` cache, receivers on a live `SenderHasGbankNote` scan) -- named, not new, not
    changed. S4 (100 markdownlint violations in 20 docs this round did not touch) -- the desk
    has no markdown fixer and the operator's rule is the desk; they are fixed as each file is
    next opened, as the reviewer put it. S3 (the changelog ceiling) was done before the review
    arrived (the archive move of 2026-09-14).
- **UX-WATERFALL-001 (b) / MAILBOX-CREDIT-001: two windows popped at the mailbox from two
  settings, and the Mailbox window's takes earned no donation points.** crimsonmane: *"on all my
  bankers I disabled 'donations' to avoid getting the window shown here. i never got around to it
  on this banker, and we see the original plus the new window pops up. the two windows are two
  separate settings. possibly disable and/or remove the original setting?"* Reading it found the
  worse half: STORE-007's credit lived only in the per-mail Donation popup's `Mail:Open`, and the
  Mailbox window (open by default for every banker since v1.5.0) took mail through
  `TakeInboxItem` / `TakeInboxMoney` directly -- so a gift taken through the window that every
  banker now uses earned nothing. Now: ONE rule, `Mail:IsDonation` (this character is a bank
  character, the sender is not, the mail was not returned, the popup's "Add to score" box when
  there is one), and two credit helpers `Mail:CreditMoney` (the once-per-mail window) and
  `Mail:CreditItem` (valued now, vendor floor, uniques skipped), called from BOTH takers -- the
  popup's Open and the Mailbox window's `TakeRow`. Rows carry `wasReturned`. The popup stands
  aside whenever the Mailbox window auto-opens (`Mail:Scan` returns when `Mailbox:AutoOpens()`),
  so the Mailbox window's General setting "Open the Mailbox window at a mailbox" is the one
  control; untick it and the popup is the mailbox again. The per-character "Enable donations"
  box is REMOVED with its accessor and default (the saved value is left and read by nothing). A
  second defect fell out of lifting the rule: the "not from another bank character" check
  compared the inbox header's BARE sender name against the `Name-Realm`-keyed banker set, so in
  game a banker-to-banker transfer WAS credited as a donation (the spec passed by handing it a
  normalised sender the client never sends); IsDonation normalises first. KNOWN COST, stated: the
  popup also AUTO-TOOK each donation mail as it opened; with the Mailbox window on (the default
  for a banker) taking is through that window -- Take Shown, Take Needed, a click -- and a banker
  who wants the old one-at-a-time auto-take unticks the Mailbox window's setting and has the popup
  back. Both takers credit; credit precedes the take in both (as Open always did), so a take the
  client refuses for a reason neither checks first is a credit for a stack still in the mail.
  Offline: `donations_spec` (the bare banker sender refused, a returned mail refused, a non-banker
  character refused; the Mailbox window's take crediting item and money exactly as Open does,
  COD refused before any credit, returned and banker-to-banker taken but not credited; the popup
  standing aside for an auto-opening Mailbox window and returning when it is off; the retired
  setting absent from Options). Locations: `Modules/Mail.lua`, `Modules/UI/Mailbox.lua`,
  `Modules/Options.lua`.
- **SETTINGS-002: a stale client could revert an officer's settings, and every shop setting rode
  it.** Found in this build's sideways read while wiring the donation rate onto the guild-settings
  broadcast. The periodic piggyback (`Events.lua` SyncDeltaVersion) has every banker and officer
  re-broadcast the settings it HOLDS so new joiners receive values -- and `ApplyRemoteSettings`
  was last-writer-wins. So a banker who logged in holding yesterday's settings re-announced them on
  its first ten-minute cycle and reopened ordering, switched the shop off, put items back on sale
  and reset the rate on every client. The settings now carry a **version**: `Guild:StampSettings`
  writes the server time (or held+1) whenever `BroadcastSettings("ALERT")` runs -- every writer in
  the addon calls it with ALERT after mutating, and the piggyback calls it with no priority, so
  ALERT is the one signal that says "I changed something" rather than "I am re-announcing" -- and
  `ApplyRemoteSettings` drops a broadcast older than the held version WHOLE and adopts the version
  of one it applies, so a later local write stamps above it. A pre-002 client carries no version
  and reads as 0: it can still seed a client that has never held a stamped copy, and nothing else.
  The donation-points bucket never had this problem (a version per writer). Offline:
  `requestchain_spec` (the stamp is the write's server time and orders two writes in one second;
  the re-announcement bumps nothing; newer-then-stale dropped whole across three fields;
  stale-then-newer applied and adopted, a later local write stamping above it; a versionless
  client seeding an empty peer and ignored by a stamped one); the existing STORE-006 examples that
  hand-build payloads now carry a version to be heard, which is the fix working. Locations:
  `Modules/Guild.lua`.

> Releases **v1.5.1 and older** have been moved to
> [`CHANGELOG_ARCHIVE.md`](CHANGELOG_ARCHIVE.md) to keep this file under GitHub's 125,000-character
> release-body limit. Nothing was deleted; each section moved whole, at a version boundary. All
> twenty-three of v1.6.0's Internal entries (from the release docs down to ENV MIGRATION) are there
> too, under v1.6.0's extended detail.
