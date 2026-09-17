# TOGBankClassic Changelog

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

### Internal

- **v1.6.0 release docs.** The CurseForge page's feature sections (Core Features, Advanced
  Features, Key Settings) now describe this release, not v1.5.0: the Shop tab, shop orders and the
  officer controls, donation points and the Donations window, the one price list, the sister-guild
  bank, who runs each bank character, the size slider, the share button, request limits enforced
  everywhere, instant fills. `README.txt` likewise: version 1.6.0, key features, a who-runs section,
  the share button, the officer options, a full 1.6.0 highlights block and the compatibility note.
  The page had reached 85,161 characters (the largest CurseForge is known to have accepted is
  85,514), so the v1.5.0 "Recent Updates" block -- 29,648 bytes -- moved byte for byte to
  `docs/Curseforge_Description_Archive.html` (new, unpublished) and the page is 55,524; the
  trailing pointer says v1.5.0 and earlier are in the changelog. `CLAUDE.md`'s docs checklist now
  says where a block goes and that the feature sections are half of a release.
- **FILL-ALERT-001: an end-to-end test of a banker's fill reaching a guildmate on the ALERT, and
  one spelling of the guild channel.** The operator, testing two whole clients of this tree: *"i
  filled a request, and the instant path didn't work ... the alert should cut through [the normal
  sync]"* -- *"do you have end to end tests in the test harness for the alert sync path?"* There
  were none: `requestchain_spec` crossed an ADD, `xguildfleet_spec` a sister-guild completion by
  whisper, `logapi_spec` applied a fulfill entry by hand. `fillalert_spec` (new) drives the mail
  leaving (`Mail:ApplyPendingSend`), the `fulfill` mutation at ALERT and two other clients' rows on
  both of env_fleet's wires, and under the banker's own login burst (hard clamp, hlb2 queued,
  another addon on the channel) with a 20 s bound. On the throttled wire it failed at once for a
  reason older than this release: every request-channel send (`togbank-rm`, `-r`, `-ri`, `-rd2`,
  two `togbank-hl` commands) spelled the distribution `"Guild"` while every other send says
  `"GUILD"`; the live client accepts either (measured 2026-09-17: a fill sent as `"Guild"` was
  delivered and applied on the far client), but the harness's wire routes group messages by an
  uppercase table and dropped every one silently -- so the request channel was the one channel the
  real-stack fleet could never carry. All ten now say `"GUILD"`; `xguild_spec`, `xguildfleet_spec`
  and `sendresult_spec` pinned the old spelling and follow. `RefreshRequestsUI`'s debug line is
  categorised (REQUESTS/RECEIVE) so a received-mutation log says whether the tab was there to
  redraw. Harness contract filed: a non-uppercase chat type should be carried like the client
  carries it, or refused loudly, never dropped. **The live failure on the Togcook session is NOT
  explained by this** -- the same client, relogged as Lowerherbs, delivered three fills instantly
  (log + screenshots on both sides); what held that one session's mutation channel is unmeasured,
  and the in-game item on the todo list says what to capture if it recurs. Locations:
  `Tests/fillalert_spec.lua`, `Modules/RequestLog.lua`, `Modules/Guild.lua`.
- **LINK-AUDIT-001 steps 6 and 7: the item layer is one pipeline, and a spec says so.** Step 6
  (`docs/LINK_AUDIT.md` 3.5, 3.6): `Item:GetItems` (the 280-line async loader with its 10 s
  watchdog), `Item:GetInfo` (the second `Info` builder, which on a cold client overwrote a LibItemDB
  name with "Item N"), `Item:Aggregate` (a link-keyed merge of rows the store had already merged by
  `Record.key`), `Item:GetItemKey` and `Item:GetItemString` are deleted; `Item:Sort`'s pre-pass that
  fabricated `Info` from a link's brackets is gone and the comparators stay. `Item.lua` is down to
  `RowSuffixID`, `IsPlaceholderName`, `RequestDisplayName`, `Sort` and `IsUnique`. The Inventory tab
  draws its view rows synchronously (a placeholder row draws at once with its question-mark icon
  rather than after the watchdog). `item_spec`'s blocks for the deleted functions and
  `aggregate_mail_spec` are retired; `search_spec` is new. Step 7 (section 4): three class guards in
  `wiring_spec` read the shipped files -- exactly one `|Hitem:` parse (`Scan.parseLink`; the held
  `Log:ItemLinkFor` is named with its contract), exactly five hand-typed base-id item strings each
  with its reason, and no inline `id:suffix` key anywhere. Browse's row id was the last one
  (`Record.keyFor` now); `TooltipBankerInfo`'s private `|Hitem:(%d+):` read is `Scan.parseLink`'s
  third return. `INVENTORY_V2.md` section 8's "kept" table now says what happened to each row.
  **Still held:** `Log:ItemLinkFor`, on TOGTools contract `55e84c617342` (a plain item's LibItemDB
  link has no colon after the id, and TOGTools' `linkSig` needs one). The identity guard was
  red-checked (Browse's inline key put back: that guard alone failed). Also fixed: `wiring_spec`
  loaded Bank before Constants and died at `Bank.lua:9` whenever it ran first -- masked in both
  full-suite orders by earlier files' leftover globals. 1800/0 both orders (forward as two halves
  under the desk's cap). Locations: `Modules/Item.lua`, `Modules/UI/Inventory.lua`,
  `Modules/UI/Search.lua`, `Modules/UI/Browse.lua`, `Modules/TooltipBankerInfo.lua`,
  `Tests/wiring_spec.lua`, `Tests/tooltipbankerinfo_spec.lua`.
- **LINK-AUDIT-001 step 3 (part): the Mail window and the Mailbox go through the edge.** The
  Donation window's attachment rows are `Scan.parseLink` -> `Record.new` -> `Store.ViewRowFor` (the
  view-row builder, now public), drawn synchronously -- a suffixed weapon in the mail drew as its
  base item, and these rows were `Item:GetItems`' last reason to exist. The Mailbox's "needed" and
  Take Needed's "owed" are keyed by `Mailbox.OrderKey` (`Record.keyFor(id, suffix, 0)`): an order
  for "of the Bear" lit every Spiked Club in the inbox, and the bags are now counted for the
  requested variant (`CountItemInBags`' third argument). Also fixed in passing: three unused
  header locals and an undeclared `GetInboxText` (verified in Era's `MailFrame.lua:373`).
  `mailwindow_spec` new (+2, red with the suffix dropped at the edge); `mailbox_spec` +1 and the
  owed example keyed by variant. 1829/0 both orders.
- **LINK-AUDIT-001 step 3 (part): the Requests item hover asks Resolve.** A request with an itemID
  takes its tooltip link from `Resolve.link(Record.new(id, 1, suffix))`: no walk of every banker's
  rows on hover, no hand-typed `item:%d:0:0:0:0:0:%d`, and the name line (not an empty tooltip) when
  nothing can name it. `requestsactions_spec` example rewritten, red with the suffix dropped.
  `Log:ItemLinkFor` is HELD: TOGTools' `linkSig` needs a colon after the id and LibItemDB's plain
  link has none, so the swap would re-key TOGTools rows (contract `55e84c617342`). 1826/0 both orders.
- **LINK-AUDIT-001 step 2: Resolve's client step keeps the suffix and enchant** (`LINK_AUDIT.md`
  3.4). For an id LibItemDB lacks, `Resolve.describe` asked `GetItemInfo` for the BASE id and, cold,
  linked `item:<id>`. A variant is now asked for by its own item string (`lib:BuildItemString`), a
  cold cache links that string, and a base-only cache names the base but links the variant.
  `resolve_spec` +3, red first. 1826/0 both orders. Not measured in a client: what `GetItemInfo`
  answers for a suffixed item string (LINK_AUDIT section 8).
- **LINK-AUDIT-001 step 1: the static item databases are deleted** (`docs/LINK_AUDIT.md` 3.1).
  `Modules/Static/ItemDB.lua` (3.7 MB) and `SuffixDB.lua` left both TOCs; `Item:GetClass` (their only
  reader) and `Item:ItemClassNeedsLink` went with `tools/build-itemdb.py`, the `.luarc.json` /
  `.luacheckrc` globals and three comments still claiming `PurgeLinklessGearGhosts` (gone since
  INV2-RETIRE-003) called it. Nothing read them: 3.7 MB less parsed at login, no behaviour change.
  `item_spec`: 4 examples out, 1 in (neither TOC loads `Modules/Static/`). Also: `Guild:ReconstructItemLink`
  deleted, `UI:DrawItem` asks `Resolve.link` on the row's id/suffix/enchant (it had answered the BASE
  link); the legacy `{ ID, Count, Link }` branches of `Log` `countsByKey` and the revision-2
  `hashInventoryItems` deleted (every caller passes records; revision 1 frozen, untouched);
  `Item:RowSuffixID` no longer parses the link. Specs moved to records where a legacy fixture would
  now hash or count nothing and pass vacuously (`inventoryhash`, `canonhash`, `database`, `logapi`,
  `browse`); +1 `hideitems` (red with the suffix dropped), legacy-row refusal pinned. 1823/0 both orders.
- **Harness pin 259485b -> 6181ba5** (thread c58cf6b3, delivered as `a9328c3`): EditBox font objects
  and InputBoxTemplate's `.Left/.Middle/.Right`. `requestsactions_spec`'s two stand-ins are deleted;
  it reads `GetFontObject` and the art directly. No `<name>Left` reads in TOGBank. 1824/0 both orders
  (forward run with `--quiet`; the verbose forward run hit the desk's 15-minute cap, cause unknown).
- **BANKFILL-SWAP-001: harness pin 06dc8b0 -> 259485b; `bankcollect_spec` on the harness's moves.**
  The operator: a swapped-out stack returns to the bank slot ("i believe the bank"; unmeasured). The
  harness adopted that at f463acd, so the spec's private Use/Split/Pickup copies are deleted; a
  recording wrapper keeps the call-order, swap and no-same-item-drop checks. 1825/0 both orders.
- **XGUILD-E2E-001: a two-guild fleet with nothing hand-fed** (`Tests/xguilde2e_spec.lua`). Officers
  list the guilds (`F.sisters`); rosters, `gbank` notes and presence cross on Guild Roster's own pull,
  with clicks sending its /who (`F.click`). Asserts the tagged Bankers tab rows and bank contents in
  both directions. `F.newClient` binds `InitRosterCallbacks` as Core does.
- **Harness pinned at `06dc8b0`** (FLEET-PORT-SPEED-001, FRIENDSFRAME-HIDDEN-001, and `c426723`: a
  reset client's frames never dispatch). Both `F.new` loops are gone. SPEC-ALONE-001: `bank_spec`,
  `database_spec`, `deltahost_spec`, `guildroster_integration_spec` and `windowchrome_spec` now load
  (or clear) what they read, so each passes alone. Both orders 1810/0.
- **SETTINGS-AHEAD-001** (Peer Review F3): `OnSettingsAdvertised` and `OnSettingsRequest` call
  `settingsAhead` instead of open-coding it. No behaviour change.
- **CONGESTION-001: the fleet has a SECOND WIRE -- the real transport stack, congested -- and the
  sync is proven over it.** The operator: *"can you simulate congestion in the harness? we should
  have some congestion tests"* and *"don't forget we have acecommqueue on top of ace3"*. Every fleet
  spec until now ran on an ordered bus: whole messages, delivered the instant they were sent, in
  send order. A live client is three layers away from that, and each layer is code this addon
  actually ships beside -- AceCommQueue admits ONE message per (prefix, distribution, target) into
  AceComm at a time (ALERT before NORMAL before BULK *between* messages); AceComm cuts a message
  into 255-byte chunks on ONE ChatThrottleLib pipe per prefix; CTL round-robins the pipes a chunk at
  a time under 800 bytes/s shared with every other addon on the client, a 4000-byte burst it BANKS
  while idle, and a five-second clamp to a tenth of that after `PLAYER_ENTERING_WORLD` -- which is
  exactly when the login cycle runs. `F.new(members, { wire = "throttled" })` puts all three between
  TOGBank and the bus, per client: an own `C_ChatInfo` per client (so each client's CTL hooks its
  own table and the harness's group echo does not double-deliver), `G.ChatThrottleLib = false`
  before load (CTL's version guard would otherwise hand the second client the first one's instance,
  gauge and all), CTL's `OnUpdate` driven by the harness clock and wrapped to run AS its client
  (a despool fires the chunk callback up through AceComm and AceCommQueue into whatever the addon
  chained on it). What reaches the bus is a CHUNK; the recipient's REAL AceComm reassembles it from
  a `CHAT_MSG_ADDON` on its own frame, so the registration is the routing and no prefix table is
  invented. Plus `F.enterWorld(c)` (the post-login clamp), `F.background(c, bytesPerSecond)` (other
  addons' traffic, charged against the same gauge through CTL's own hook), `F.chunks` in leave order
  and `sentAt` / `leftAt` / `verdict` per message. NOT modelled, and said in the header: server
  latency, and client refusals (the seam always accepts, so CTL's blocked ring never fills).
  `Tests/congestion_spec.lua`, 9 examples: a send held by the clamp and leaving later as chunks; the
  plain sync converging under it; the table-vs-offer race and the parking fix above; a five-viewer
  login storm two seconds apart, every one converging in its own first window; a viewer whose other
  addons spend 600 of the 800 bytes/s; a client below CTL's `MIN_FPS`; and P2P-031 on a real wire --
  a 200-row BULK snapshot draining over tens of chunks while the ALERT handshake to a second
  requester is answered without waiting for it. **Filed to WoWAPITesting as contract
  `12c111893504`** so it becomes the harness's and every addon gets it (the operator: *"why are you
  doing this instead of building it into the harness with a contract?"*); they ACCEPTED all nine
  points, have not built it, and measured CTL's shape in reply -- correcting one claim of ours: the
  send function is resolved per send (`ChatThrottleLib.lua:640`), so a per-client `C_ChatInfo`
  swapped by their client bag suffices and `setfenv` is not required for that half. The copy here is
  the staged reference until they deliver, then it goes.
- **Harness pin `830dab2` -> `922c892`, two deliveries, both adopted.** (1) Contract `d66615e6`:
  `env/libs.lua`'s `DeltaSync-1.0` entry listed the six files of MINOR 17, so `libs.load` handed
  back a host with no `InitNumbers` and no numbered P2P class -- which TOGBank's adapters read as
  "library too old", the version query went quiet, and nine examples failed for a reason that looked
  like a TOGBank bug. `pathsOf` now returns all EIGHT in TOC order; `env_togbank.DELTASYNC_EXTRA_FILES`
  and the per-client extra-file loop in `env_fleet` are both DELETED, and `loadDeltaSync()` is one
  line. They also hardened what let it hide: four library entries now declare `tocOmits = 0`, so the
  next file any of them gains fails the run instead of printing. (2) Contract `eb3a431d70c2`, filed
  after the operator objected to this session shelling out for the third time in an hour
  (*"this again should be part of the test harness, did you open a contract for this?"*): `run.lua`
  gains `--quiet` (failures, the `Failures:` block and the counts line only) and `--filter` (a plain
  substring over the full `describe -> it` name -- deliberately NOT a Lua pattern, because example
  names here are full of pattern syntax), a named file that does not exist exits 2 with the path it
  looked for rather than silently widening to discovery, and `tools/verify-runner-flags.lua` gates
  all of it. They declined the `{"tool":"test","files":...}` field itself, correctly: the desk is
  writ's, not the harness's. The route that works today is a declared suite carrying the argv, and
  this project now has one -- a single spec file, failures only, three lines and no shell.
- **LIBREQ-DS-008 PART 1 ADOPTED: the banker-number table is DeltaSync's (`host.numbers`), on
  TOGBank's own channel for one more release.** DeltaSync shipped `DeltaSyncNumbers.lua` on
  2026-09-15 (thread `c20eb5b527e1`, reply ea0e5f57; its working tree, "will be MINOR 19") --
  `Modules/BankerNumbers.lua`'s table, mint, adopt and 24-character codec generalised to any string
  key, per host via `host:InitNumbers(config)`, 35 of TOGBank's own examples lifted to its side.
  Adopted from the working tree under LIB-RELEASE-ORDER. `Modules/BankerNumbers.lua` (319 lines)
  is now the CONFIGURATION over the library instance -- `BN:Lib()` initialises `host.numbers` on
  first use with the table on `Guild.Info.roster` (the SavedVariables shape is unchanged), the
  keys = `Guild:GetBanks()`, `canMint` = this account owns a banker (`inventoryContentHash` on a
  banker record, the same rule as before), `normalize` = `Guild:NormalizeName`, `me` =
  `GetNormalizedPlayer`, `canonTime` = `DeltaComms:CanonPublishTime`, `onChanged` = repaint the
  Bankers tab, `onExhausted` = the Warn line -- plus one forwarder per method the ~30 call sites in
  Chat / Events / P2PSession / Bank / Guild / Log read (`NumberOf`, `NameOf` -> `KeyOf`,
  `EntriesToAlts` -> `EntriesToItems`, ...), each answering "nothing numbered" against a DeltaSync
  without the module. **THE ONE DELIBERATE DEPARTURE:** the library's `numbers-request` /
  `numbers-reply` ride DeltaSync's HANDSHAKE whisper, and every shipped TOGBank client (v1.5.1 and
  earlier) asks and answers on `togbank-hl`; a guild mid-upgrade has both, so this release keeps
  TOGBank's `OnAdvertisedVersion` / `HandleRequest` / `HandleReply` on `togbank-hl` with the
  library's Snapshot as the payload, and never calls the library's transport. Part 2 (the numbered
  session protocol) moves the whole wire at once; these three go with `P2PSession.lua` then.
  Specs: `bankernumbers_spec` runs its four light describes on the real Core + host now (the old
  stub Core had no host to reach), gains "is the LIBRARY's table" (forwarders and the no-module
  fallback) and "the library's own HANDSHAKE transport is NOT used" (a spy on `host.SendHandshake`
  counts zero across an ask and an answer); the H6 two-client convergence runs through the library
  unchanged. `p2psession_spec`'s P2P-032 fixture carries a real host over a silent transport for
  the same reason. HARNESS GAP, worked around: `env/libs.lua`'s `DeltaSync-1.0` entry lists the six
  files of MINOR 17 and not `DeltaSyncNumbers.lua`, so `env_togbank.loadDeltaSync()` (every spec
  that stood the host up through `env.libs` calls it now) and `env_fleet`'s per-client loader load
  it by path from `env.DELTASYNC_EXTRA_FILES`; contract to WoWAPITesting to carry the seventh file,
  and the list empties then. **Part 2 is not built**; DeltaSync's two design questions were answered
  on the thread from the code (which observers, with what payload; `peerCapable` as a callback) --
  `docs/DELTA_RELEASE.md` 2b records both and the wire break part 2 will bring. Locations:
  `Modules/BankerNumbers.lua`, `Tests/bankernumbers_spec.lua`, `Tests/p2psession_spec.lua`,
  `Tests/env_togbank.lua`, `Tests/env_fleet.lua`, nine spec files' `loadStack`.
- **LIBREQ-DS-008 PART 2 ADOPTED: the numbered P2P is DeltaSync's (`host.p2p`); `P2PSession.lua`
  is deleted.** DeltaSync shipped `DeltaSyncP2PNumbered.lua` on 2026-09-15 (thread `c20eb5b527e1`,
  reply a7d91c11; its working tree, then pushed that evening as v4.1.0 `934f12b`, MINOR 18 -- the
  operator folded both parts into the DS-009 release, so the "MINOR 19" the thread had promised
  never existed; reply 26eae54e), TOGBank's P2P-035 protocol generalised --
  the broadcast / collect / dispatch loop, the version query, the send slots and queue, the
  state-wait, catch-up, MULTIPC's self-consult -- selected with `host:InitP2P({ mode = "numbered" })`.
  Adopted from the working tree under LIB-RELEASE-ORDER (directive #12702: *"use deltasync ... strip
  the chaff out of TOGBank"*). `Modules/P2PSession.lua` (1,545 lines) is gone; the new
  `Modules/P2P.lua` is the CONFIGURATION -- every hook resolving at call time to the production
  predicate it names (`Guild:ServableCanon` / `CanServe` / `AdvertisedImproves` gated on a current
  banker / `IsInCurrentGuildRoster` / `PeerSpeaksDataLeg` as `peerCapable` / `HasMissingContent`;
  `Inventory/Sync:RequestFrom` as `onDeliver`; the two caches and the self-holder from
  `onAdvertised`; `NoteNewerOffered` / `ClearNewerOffered`; `Bank:PublishIfDeferred` from
  `onSelfConsulted`) -- and THREE STAND-INS for seams the library has not got, each with its removal
  condition in the header: `OfferUnmentioned` (the library offers back only the keys a broadcast
  LISTED; a banker absent from it is the wipe-recovery / fresh-install signal, so TOGBank whispers
  those in the library's own `hash-offer2` shape -- and sends the numbers table FIRST to a
  broadcaster behind on it, because the library drops a bare offer it cannot resolve and the
  fleet's first round only converged on the catch-up cycle otherwise), `SendOwn` (the `sync-done`
  receipt and the `query-refused` answer, two types the library's HANDSHAKE router has no hook for,
  on `togbank-hl` at ALERT), and `NoteVersionFirst` (below). The instance is stood up WITH the host
  in `Core:DeltaHost()`, not on the first broadcast: the library routes an OFFER or HANDSHAKE to
  `host.p2p` only when it exists, and a receiver at login has received before it has sent -- the
  fleet found a receiver dropping every peer's OFFER. Every call site reads the library directly
  through `P2P:Lib()` (Sync's `QueryArrived` / `ReleaseSendSlot` / `ReplyNoChange` /
  `OnItemCompleted` / `OnItemFailed`, Bank's `IsSelfConsulted` / `DispatchList` /
  `MarkSelfConsulted`, the status bar's `GetActiveSendTotal` / `activeSessions`, the dev
  `sendqueue` / `trace` on `sessionsByKey`). GONE WITH IT, the whole pull path: `Guild:BroadcastP2PRequest`,
  `ClearPendingP2PRequest`, `ArmAltTimeout`, the dead `QueryAltPullBased`, `FastFillMissingAlts`,
  the per-alt fallback timers, `NotePeerOldWire` / `peerOldWire` and the `togbank-state` tripwire
  (a v1.4.1 peer is refused by its version, which VersionCheck names at login), the `togbank-rr`
  and `togbank-hlr` prefixes and every hlb2 / hash-offer2 / ver-query / ver-reply / sync-* branch
  of `Chat.lua`; `Chat:ReceiveHashListReply` hands a reply to the library as the replier's
  broadcast. **KNOWN COST, one wire break:** hlb2 and the bare offer move to the host's OFFER
  prefix and the handshake to its HANDSHAKE prefix, so a v1.5.1 client and this build never P2P
  with each other -- `DATA_LEG_MIN_ADDON_VERSION` is `1.6.0`, a v1.5.1 peer's `togbank-hl` hlb2 is
  read for its addon version and its numbers-table version and nothing else (the table is still
  asked for and answered on `togbank-hl` for that release, `BankerNumbers.lua`'s transport
  section), and a guild mid-upgrade is split until everyone updates. THREE DEFECTS THE LIFTED
  SPECS FOUND IN THE ADOPTION, fixed before it landed: (1) DeltaSync's `OnComm_OFFER` runs
  `host.p2p:OnBroadcast` BEFORE the host's `onOfferReceived`, so the `addon` version an hlb2
  carries was read AFTER `peerCapable` had judged its sender -- a peer VersionCheck had not
  answered for passed the gate on its first broadcast: tab red, cache written, DISPATCHED to a
  v1.4.1 release (the WIRE-SKEW-004 hours again; proven red with the hook removed). `P2P:Lib()`
  installs `NoteVersionFirst` as an instance-level `OnBroadcast` pre-hook; library ask filed. (2)
  The federation pull (XGUILD-SYNC-001) was broken by the numbering: a sister client never hears
  the home guild's hlb2, held no number for the home banker, and the reply named only NUMBERED
  entries -- nothing requested. `Guild:SendHashList` now carries `numbers = BN:Snapshot()`, adopted
  on receipt under the library's rules (D5's "the numbers pair fills the table", folded into the
  reply), and an alt the table STILL cannot name feeds the caches through `P2P:OnAdvertised` and
  is dispatched BY NAME through `p2p:DispatchOrQuery` -- the library's session names its key; only
  the collect-phase encodings are numbered. (3) `OnOfferReceived` and Sync's `normSender` marked a
  host-prefix sender online as `host-message-received`, a source `UpdateOnlineMember` does not
  stamp as a TOGBank speaker, so the federation peer picker never preferred a host-prefix
  broadcaster; both are `addon-message-received` now (the host's prefixes are TOGBank's own
  namespace). TAB-STATE-003 now reaches the broadcast path too: the old handler dropped a refused
  peer's claim before any `Note*` saw it (tab yellow, false of what exists); the library reports
  every claim and `NoteAdvertisedPublishTime` files it GREY -- one rule for every path. Specs: 13
  files lifted onto the library (chainwire, statesummary, multipc, tabstaleness, hashcache,
  syncwire, wireskew, bankernumbers, statusbar, xguild, xguildfleet, sendresult, deltahost;
  `pullpath_e2e_spec` and `p2ptimeout_spec` deleted with their subject; `p2psession_spec` rewritten
  as the `P2P.lua` spec -- the protocol's 63 examples are the library's `numbered_p2p_spec` and
  TOGBank's `fullsync_spec`, 24/24 end to end on the library); `coresurface` / `timers` floors
  lowered deliberately; four spec files' `TOGBankClassic_P2P` doubles handed back in `after_each`
  (a module global leaking across files is what killed `Bank:CanPublish` in a file that never
  loads `P2P.lua`); `propagation_spec`'s 75-second advance moved off the whole-second boundary the
  harness's 0.1 s ticks drift across (reverse-only red). Suite 1756/0 forward and reverse; coverage
  `Modules/P2P.lua` 103/103, `Modules/Inventory/Sync.lua` 316/316. NOT SEEN IN GAME. Locations:
  `Modules/P2P.lua` (new), `Modules/P2PSession.lua` (deleted), `Core.lua`, `Modules/Events.lua`,
  `Modules/Chat.lua`, `Modules/Guild.lua`, `Modules/Inventory/Sync.lua`, `Modules/Bank.lua`,
  `Modules/DeltaComms.lua`, `Modules/BankerNumbers.lua`, `Modules/Constants.lua`,
  `Modules/UI/StatusBar.lua`, both TOCs, `.luacheckrc`, `.luarc.json`, `Tests/env_togbank.lua`,
  `Tests/env_fleet.lua`.
- **LIBREQ-GR-002 ADOPTED: the public note on the sister roster, from LibGuildRoster MINOR 19.**
  GuildRoster shipped it on 2026-09-15 (thread `e2ec2c27e46a`, 0.8.0 / MINOR 19 in its working
  tree): `serveRoster` sends `pn` (omitted when empty), `takeServedRoster` keeps it as
  `member.note`, the persisted snapshot and the GUILD relay carry it, the officer note never
  travels and the membership hash is untouched by a note edit. TOGBank read `member.note` already
  (feature-detected), so no production change; the adoption is that `xguild_spec`'s `feedSister`
  and `env_fleet`'s `F.federate` pass the note IN the `SetSisterRoster` feed entry -- the shape the
  library's own receive path produces -- instead of writing it onto the roster by hand after the
  feed, and both assert the library kept it, so a LibGuildRoster before MINOR 19 fails loudly
  instead of passing on a planted note. Two stale "once LIBREQ-GR-002 lands" comments in
  `Guild.lua` corrected; the README's sister-guild section now also names the officer switch
  (XGUILD-SWITCH-001 had left "nothing to set here" standing) and both player texts say the field
  requirement plainly: the client that serves each guild's roster needs Guild Roster 0.8.0. KNOWN
  from GuildRoster's reply, not TOGBank's to fix: the same release fixes a provider serving a
  PARTIAL roster all session, so a roster from an older provider can be short and missing its
  `gbank` members. Locations: `Tests/xguild_spec.lua`, `Tests/env_fleet.lua`, `Modules/Guild.lua`
  (comments), `README.txt`, `docs/Curseforge_Description.html`, `docs/XGUILD_SYNC.md`,
  `docs/LIBRARY_CONTRACTS.md` 2.5.
- **LIBREQ-DS-009: the SHA, and a receive-side change that rides it.** DeltaSync committed the
  per-send completion as `ffbfb2d1ebebfb976b0d0621e81ca02899f1d187` (v4.1.0, MINOR 18; the push
  waits on the operator, so the sibling install IS that SHA). **Superseded the same evening:** the
  operator folded DS-008 parts 1 and 2 into v4.1.0 before pushing, so the tag is
  `934f12b83a0856749e5565048b3e6ed4f73bcc7e` on origin/master, still MINOR 18 (reply 26eae54e).
  The adoption of 2026-09-15 15:30 stands as built. The same commit carries DeltaSync's deletion tombstones -- a field deleted on
  the sender arrives on the receiver as a removal through `host.RequestData` / `SendData` rather
  than lingering -- with no call-site change here; the whole suite was re-run against that tree
  after the SHA landed (1822/0 forward and reverse before the part-1 work above, then again after
  it). Recorded under `docs/LIBRARY_CONTRACTS.md` 3.13.
- **LIBREQ-PRICE-011 ADOPTED: the guild price list is pinned against the REAL LibItemDB, and the
  consult-first shim stays -- measured, not assumed.** ItemDB delivered the fed source (MINOR 26,
  `StoreExternalPrices` / `ClearExternalPrices`) on 2026-09-15 in its working tree; under the
  operator's LIB-RELEASE-ORDER rule (*"you shouldn't look at the date of the release, i'll release
  DS Library AFTER YOU ARE DONE"* -- the same order for every library of theirs) the adoption no
  longer waits for a commit SHA. `Tests/pricelist_spec.lua` gains a describe that loads the
  installed `LibItemDB-1.0.lua` through `env.libs` and `Price/Sources.lua` by its installed path
  (the harness manifest loads only the core file, as its comment says), delivers the authority's
  real `togbank-pl` chunks to a member, and reads back through the library's own API: the fed
  source is first in `GetPriceSources()` (external, detected, enabled, three entries), each
  statistic the wire carried answers under `source = "guildpricelist"` with the entry's own `at`,
  one the wire did not carry is nil, `GetPrices` agrees, the data sits in
  `LibItemDB_PriceDB.realms[<realm - faction>].external`, and clearing the authority (or becoming
  it) empties the source and leaves its row not-detected. The library is evicted after each example
  so no later spec file can feature-detect a real ItemDB by accident (SPEC-ORDER-001's class).
  **The plan in `docs/GUILD_STORE.md` 4.2.1 said TOGBank's own consult-first order would go once
  the feed existed; it does not go**, on three counts read from `Price/Sources.lua` against the
  pin: the library's `best` walks a fed source `minBuyout -> market -> historical`, so the Shop's
  sell figure (the authority's default statistic, 150) comes back as the value figure (120); the
  ladder is per statistic, so an item the guild list prices only by history is answered by the
  banker's own scan's min buyout first -- two bankers valuing one gift differently, the fault
  DONATION-VALUE-001 exists to stop; and a banker can switch the fed source off in `/itemdb`. So
  `Browse:PriceRows` / `PriceOne` and `Donations:Value` keep reading the list first; the feed serves
  the other ItemDB consumers on the machine and the `/itemdb` window. Corrections stated in
  `GUILD_STORE.md` 4.2.1, `LIBRARY_CONTRACTS.md` 7.14 and the `Modules/PriceList.lua` header.
  Locations: `Tests/pricelist_spec.lua`, `Modules/PriceList.lua` (comment only).
> Releases **v1.5.1 and older** have been moved to
> [`CHANGELOG_ARCHIVE.md`](CHANGELOG_ARCHIVE.md) to keep this file under GitHub's 125,000-character
> release-body limit. Nothing was deleted; each section moved whole, at a version boundary. The three
> oldest v1.6.0 Internal entries (the XGUILD-SYNC-001 design, N6, ENV MIGRATION) are there too, under
> v1.6.0's extended detail.
